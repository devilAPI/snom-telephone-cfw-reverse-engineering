/* intercom-src/spkstream.c - play audio from the network on the snom D375 loudspeaker.
 *
 * Reverse intercom / network speaker for the CFW (see docs/speaker.md). The phone UI
 * keeps running; nothing is taken over. The counterpart of micstream.c.
 *
 * Output path (found 2026-11-04, see docs/speaker.md):
 *   - the stock kernel module amxr_user_hook.ko gives /dev/amxruser and the amxr ports
 *     amxruser.bind0..2. We add the connection  amxruser.bind0 -> halaudio.apm1
 *     (APM channel 1 = the speakerphone). amxr sums every source of a destination, so
 *     the phone's own ept.bind1 -> halaudio.apm1 stays untouched and both are heard.
 *     Also halaudio.apm1 -> amxruser.bind0, never read: it drives the frame clock;
 *   - ioctl(0xc0044502) blocks until the next 5 ms frame sync, ioctl(0xc0044500,
 *     {int port; void *buf}) puts one frame (80 samples S16LE, 16 kHz mono) into the port.
 *     The module has one semaphore and wakes one waiter per frame: with the intercom
 *     (micstream) waiting too, each would get every other frame. So while micstream runs
 *     we don't wait: we keep 8 frames queued in its FIFO /tmp/amxr-play.fifo, and it
 *     writes one per frame to our port;
 *   - the idle phone has the CH1 output muted: gain blocks 0x109 (digital) and 0x121
 *     (analog output stage, which also powers the amp) read -1000. While audio plays we
 *     set 0x109 = +1 dB and 0x121 = 0 dB, but only on blocks that read muted. The +1 dB
 *     marks the unmute as ours: afterwards we put -1000 back only if 0x109 still reads
 *     +1, so a gain the phone app set for a call is never muted by us.
 *
 * Network, HTTP on -p PORT (default 8091). With -k TOKEN every request needs k=TOKEN:
 *   POST|PUT /play?k=T[&vol=0..100][&live=1][&rate=HZ][&ch=1|2]
 *        Body: a WAV file (16-bit PCM, any rate, mono or stereo) or raw S16LE
 *        (default 16000 Hz mono, or rate=/ch=). Content-Length, chunked transfer
 *        encoding (curl -T -) or "read until the sender closes" all work.
 *        A new /play replaces the one that is playing. live=1 keeps the delay low
 *        (for streams from a PC's sound card: starts after 250 ms, and trims what stays
 *        buffered for 2 s to 100 ms, because the PC's clock drifts against the phone's);
 *        without it a file is played completely, the sender is slowed down by TCP.
 *   GET /stop?k=T        stop the current sound
 *   GET /vol?k=T&v=N     set the volume 0..100 (also for what is playing)
 *   GET /status?k=T      JSON: playing, buffered_ms, underruns, dropped_ms, vol, sessions
 * Answers carry Access-Control-Allow-Origin: * so the web panel (port 8080) can send.
 *
 * Stops on SIGTERM/SIGINT, removes its amxr connection and mutes again.
 * -x only removes a left-over connection and exits (after a kill -9).
 * Build: tools/build-intercom.sh (static musl, armv6 soft-float, with pthreads). */
#include <stdio.h>
#include <stdarg.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <pthread.h>
#include <sched.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define AMXR_QUERY_PORT   0x80244d30u /* _IOR('M',48,36) {char name[32]; void **out} */
#define AMXR_CONNECT      0x800c4d35u /* _IOR('M',53,12) {src, dst, desc} */
#define AMXR_DISCONNECT   0x80084d36u /* _IOR('M',54,8)  {src, dst} */
#define AMXRUSER_WRITE    0xc0044500u /* {int port; void *buf} <- 160 bytes */
#define AMXRUSER_WAIT     0xc0044502u /* block until next frame sync */
#define AMXR_DESC_MONO    0x1010
#define HAL_GET_GAIN      0x80084132u /* _IOR('A',50,8) {int block; int *info} info[0] = current dB */
#define HAL_SET_GAIN      0x80084133u /* _IOR('A',51,8) {int block; int db} */
#define GAIN_MUTE         (-1000)
#define BLK_DIG           0x109       /* CH1 digital output gain, -50..18 dB, 1 dB steps */
#define BLK_ANA           0x121       /* CH1 analog output stage, -21..0 dB, powers the amp */
#define OUR_DIG           1           /* +1 dB: marks the unmute as ours */
#define OUR_ANA           0

#define RATE      16000
#define FRAME     80                  /* samples per 5 ms frame */
#define RB        32768               /* ring buffer, samples (2 s); power of two */
#define PREBUF    (RATE / 10)         /* start after 100 ms */
#define LIVE_PRE  (RATE / 10)         /* live: start at the kept level + 100 ms */
#define LIVE_KEEP (RATE * 3 / 20)     /* live: kept level at the start, 150 ms */
#define LIVE_STEP (RATE / 20)         /* + 50 ms after every underrun */
#define LIVE_MAXK (RATE * 6 / 10)     /*   up to 600 ms */
#define RT_PRIO   40                  /* SCHED_FIFO priority of the pump */
#define HDRMAX    2048
#define PLAY_FIFO "/tmp/amxr-play.fifo"   /* see micstream.c */
#define FIFO_FILL 8                   /* frames kept queued in it (40 ms) */
#define SILENT    4                   /* |sample| at or below this, after the volume, is silence */

static volatile sig_atomic_t g_run = 1;
static void on_sig(int s) { (void)s; g_run = 0; }

static const char *g_token;
static FILE *g_log;
static int g_amxr = -1, g_user = -1, g_hal = -1;
static void *g_src, *g_dst;

/* shared state, under g_mx. Two channels, mixed: one for the player (files, the
   Navidrome player, the panel) and one for live streams (a PC's sound output). A new
   /play replaces only the session in its own channel, so a PC that streams all the
   time (mostly silence) doesn't cut off the music player, and both can be heard. */
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_space = PTHREAD_COND_INITIALIZER;
struct chan {
    const char *name;
    short rb[RB];
    unsigned wr, rd;          /* free-running sample counters */
    int started;              /* prebuffer reached, samples flow */
    unsigned gen;             /* session generation: a new /play or /stop bumps it */
    int active;               /* a /play body is being received */
    int live, vol;            /* vol -1: the default g_vol */
    unsigned keep, skip;      /* live: level kept; frames still to play 1.25 % faster */
    unsigned minav, win;      /* live: lowest level in the current 2 s window */
    unsigned underruns, dropped;
};
#define CH_PLAYER 0
#define CH_LIVE   1
static struct chan g_ch[2];          /* set up in main(): an initializer here would put
                                         the 2 x 64 kB rings into the binary (.data) */
static int g_vol = 30;                /* default volume 0..100, for senders that set none */
static unsigned g_sessions;
static unsigned g_missed, g_maxgap;   /* frames the frame clock skipped; longest gap, ms */
/* under g_mx: the buffer ran dry while a sender is active */
static void underrun(struct chan *c) {
    c->started = 0; c->underruns++;
    if (c->live && c->keep < LIVE_MAXK) c->keep += LIVE_STEP;
}
static long long g_last_audio;        /* monotonic us: last time real samples went out */

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    if (!g_log) return;
    char ts[32]; time_t t = time(NULL); strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
    fprintf(g_log, "%s spkstream: ", ts);
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log); fflush(g_log);
}

/* ---------- amxr / halaudio ---------- */
static void *port_by_name(const char *n) {
    struct { char name[32]; void **out; } q; void *p = NULL;
    memset(&q, 0, sizeof q); strncpy(q.name, n, sizeof q.name - 1); q.out = &p;
    if (ioctl(g_amxr, AMXR_QUERY_PORT, &q) < 0) return NULL;
    return p;
}
/* the output, plus the frame clock: amxr_user_hook wakes AMXRUSER_WAIT only while some
   connection leads *into* an amxruser port, so we also connect apm1 -> amxruser.bind0
   (never read). Without it the pump waits forever unless the intercom happens to run. */
static int amxr_link(int on) {
    void *pairs[2][2] = { { g_src, g_dst }, { g_dst, g_src } };
    int rc = 0;
    for (int i = 0; i < 2; i++) {
        if (on) {
            struct { void *s, *d; int desc; } c = { pairs[i][0], pairs[i][1], AMXR_DESC_MONO };
            if (ioctl(g_amxr, AMXR_CONNECT, &c) < 0) rc = -1;
        } else {
            struct { void *s, *d; } c = { pairs[i][0], pairs[i][1] };
            ioctl(g_amxr, AMXR_DISCONNECT, &c);
        }
    }
    return rc;
}
static int gain_get(int blk) {
    static int info[512];   /* the kernel writes a whole table: >= 1 kB (docs/intercom.md) */
    struct { int b; int *i; } q = { blk, info };
    info[0] = -9999;
    if (ioctl(g_hal, HAL_GET_GAIN, &q) < 0) return -9999;
    return info[0];
}
static void gain_set(int blk, int db) { struct { int b, d; } s = { blk, db }; ioctl(g_hal, HAL_SET_GAIN, &s); }

static int g_unmuted;   /* we unmuted (0x109 holds OUR_DIG) */
static void gains_on(void) {
    int d = gain_get(BLK_DIG), a = gain_get(BLK_ANA);
    if (d == GAIN_MUTE) { gain_set(BLK_DIG, OUR_DIG); d = OUR_DIG; }
    if (a == GAIN_MUTE) gain_set(BLK_ANA, OUR_ANA);
    if (d == OUR_DIG && !g_unmuted) { g_unmuted = 1; logf_("speaker unmuted"); }
}
static void gains_off(void) {
    if (!g_unmuted) return;
    g_unmuted = 0;
    if (gain_get(BLK_DIG) != OUR_DIG) { logf_("gains changed by the phone app, left alone"); return; }
    gain_set(BLK_ANA, GAIN_MUTE);
    gain_set(BLK_DIG, GAIN_MUTE);
    logf_("speaker muted again");
}

/* monotonic clock: the phone's wall clock jumps (it was seen going back 6 h and forward
   again), which must not decide when the speaker mutes */
static long long now_us(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}

/* SIGTERM must reach the main thread, so that accept() returns */
static void block_signals(void) {
    sigset_t m; sigemptyset(&m); sigaddset(&m, SIGTERM); sigaddset(&m, SIGINT);
    pthread_sigmask(SIG_BLOCK, &m, NULL);
}

/* ---------- pump: one frame every 5 ms ---------- */

/* Real-time priority. The module wakes a waiter only if it already waits when the frame
 * comes; a pump that is late (the phone app keeps the CPU busy) misses the frame. Then
 * the module plays the last frame again (a crack), and the audio of the missed frame
 * piles up in the buffer (later trimmed: a skip). SCHED_FIFO keeps the pump on time. */
static int g_nort;   /* -N: no real-time priority (to compare) */
static void go_realtime(const char *who) {
    if (g_nort) return;
    struct sched_param sp; memset(&sp, 0, sizeof sp); sp.sched_priority = RT_PRIO;
    int e = pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
    if (e) logf_("%s: no real-time priority: %s", who, strerror(e));
}

/* under g_mx: add channel c's next frame to acc */
static void chan_frame(struct chan *c, int *acc) {
    unsigned avail = c->wr - c->rd;
    /* live: the buffer must ride out WiFi bursts and the sender's clock drift. Every
       underrun raises the kept level by 50 ms (up to 600 ms). Every 2 s the lowest
       level seen is compared with it: the surplus is played away 1.25 % faster
       (81 samples into 80, not audible), or skipped at once if it is over 1 s. */
    if (c->live && c->started) {
        if (avail < c->minav) c->minav = avail;
        if (++c->win >= 400) {
            unsigned ex = c->minav > c->keep ? c->minav - c->keep : 0;
            if (ex > RATE) { c->rd += ex; c->dropped += ex; avail -= ex; c->skip = 0; }
            else c->skip = ex > RATE / 50 ? ex : 0;
            c->win = 0; c->minav = ~0u;
        }
    } else { c->win = 0; c->minav = ~0u; c->skip = 0; }
    if (!c->started && (avail >= (c->live ? c->keep + LIVE_PRE : PREBUF) || (!c->active && avail))) c->started = 1;
    if (!c->started || !avail) {
        if (c->started) { c->started = 0; if (c->active) underrun(c); }
        return;
    }
    int vv = c->vol >= 0 ? c->vol : g_vol;
    int v = vv * vv * 32768 / 10000;   /* Q15, roughly even steps by ear */
    unsigned i, n;
    if (c->skip && avail >= FRAME + 1) {
        /* 81 samples into 80, linear */
        for (i = 0; i < FRAME; i++) {
            unsigned pos = i * FRAME * 256 / (FRAME - 1);   /* 0 .. 80 in 1/256 */
            unsigned k = pos >> 8, fr = pos & 255;
            int a = c->rb[(c->rd + k) & (RB - 1)], b = k < FRAME ? c->rb[(c->rd + k + 1) & (RB - 1)] : a;
            acc[i] += (((a * 256 + (b - a) * (int)fr) >> 8) * v) >> 15;
        }
        c->rd += FRAME + 1; c->skip--; c->dropped++;
    } else {
        n = avail < FRAME ? avail : FRAME;
        for (i = 0; i < n; i++) acc[i] += (c->rb[(c->rd + i) & (RB - 1)] * v) >> 15;
        c->rd += n;
        if (n < FRAME && c->active) underrun(c);
    }
}

static void *pump(void *arg) {
    (void)arg;
    short f[FRAME];
    unsigned tick = 0;
    int was_real = 0;
    int fifo = -1;
    long long last = 0, sec0 = now_us(), fifo_try = 0;
    unsigned in_sec = 0;
    block_signals();
    go_realtime("pump");
    while (g_run) {
        /* micstream running? Then it owns the frame clock (see PLAY_FIFO). Look every
           100 ms: until we switch, both wait and each gets every other frame. */
        if (fifo < 0 && now_us() - fifo_try >= 100000) {
            fifo_try = now_us();
            if ((fifo = open(PLAY_FIFO, O_WRONLY | O_NONBLOCK)) >= 0)
                logf_("intercom is on: frames go through %s", PLAY_FIFO);
        }
        if (fifo >= 0) {
            int q = 0;
            if (ioctl(fifo, FIONREAD, &q) == 0 && q >= FIFO_FILL * FRAME * 2) { usleep(5000); continue; }
            last = 0;
        } else {
            if (ioctl(g_user, AMXRUSER_WAIT, 0) < 0) {
                if (errno == EINTR) continue;
                logf_("frame wait failed: %s", strerror(errno)); g_run = 0; break;
            }
            /* missed frames: a gap of more than 1.5 frames since the last wake */
            long long t = now_us();
            if (last) {
                long gap = (long)(t - last);
                if (gap > 7500) g_missed += (unsigned)((gap + 2500) / 5000) - 1;
                if (gap / 1000 > (long)g_maxgap) g_maxgap = (unsigned)(gap / 1000);
                /* a long stop is the frame clock itself (the phone app reconfiguring the
                   audio), not us being late: note when, to match it with phone events */
                if (gap > 100000) logf_("frame clock stopped for %ld ms", gap / 1000);
            }
            last = t;
            /* guard: a real-time thread must never spin. More than 300 wakes in a second
               means the wait returns without frames: slow down. */
            if (t - sec0 >= 1000000) { sec0 = t; in_sec = 0; }
            else if (++in_sec > 300) usleep(4000);
        }
        int acc[FRAME] = { 0 };
        pthread_mutex_lock(&g_mx);
        for (int k = 0; k < 2; k++) chan_frame(&g_ch[k], acc);
        pthread_cond_broadcast(&g_space);
        pthread_mutex_unlock(&g_mx);
        int real = 0;
        for (int i = 0; i < FRAME; i++) {
            int x = acc[i];
            if (x > 32767) x = 32767; else if (x < -32768) x = -32768;
            f[i] = (short)x;
            if (x > SILENT || x < -SILENT) real = 1;
        }
        tick++;
        /* unmute when sound starts, and once a second while it plays (a call that ended has
           muted again); mute after 2 s of silence, also while a PC streams silence */
        if (real) {
            g_last_audio = now_us();
            if (!was_real || tick % 200 == 0) gains_on();
        } else if (g_unmuted && tick % 200 == 0 && now_us() - g_last_audio >= 2000000) gains_off();
        was_real = real;
        if (fifo >= 0) {
            if (write(fifo, f, sizeof f) != (ssize_t)sizeof f) {   /* micstream stopped */
                close(fifo); fifo = -1; fifo_try = now_us();
                logf_("intercom is off: back to the frame clock");
            }
        } else {
            struct { int p; void *b; } d = { 0, f };
            ioctl(g_user, AMXRUSER_WRITE, &d);
        }
    }
    return NULL;
}

/* ---------- HTTP ---------- */
static int token_ok(const char *q) {
    if (!g_token || !*g_token) return 1;
    size_t tl = strlen(g_token);
    for (const char *p = q; p && *p; p = strchr(p, '&') ? strchr(p, '&') + 1 : NULL)
        if (!strncmp(p, "k=", 2) && !strncmp(p + 2, g_token, tl) && (p[2 + tl] == '&' || !p[2 + tl])) return 1;
    return 0;
}
/* numeric query parameter, or def */
static long qnum(const char *q, const char *name, long def) {
    size_t nl = strlen(name);
    for (const char *p = q; p && *p; p = strchr(p, '&') ? strchr(p, '&') + 1 : NULL)
        if (!strncmp(p, name, nl) && p[nl] == '=') { char *e; long v = strtol(p + nl + 1, &e, 10); return e == p + nl + 1 ? def : v; }
    return def;
}
static void reply(int c, const char *st, const char *type, const char *body) {
    char h[512];
    int n = snprintf(h, sizeof h, "HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %u\r\n"
        "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        st, type, (unsigned)strlen(body));
    send(c, h, n, MSG_NOSIGNAL); send(c, body, strlen(body), MSG_NOSIGNAL);
}

/* body reader: Content-Length, chunked, or until EOF; buffered */
struct rd {
    int fd, chunked, eof;
    long left;          /* bytes left: of the body (length) or of the current chunk; -1 = unknown */
    unsigned gen;
    char buf[4096]; int pos, len;
};
static int rd_fill(struct rd *r) {
    if (r->pos < r->len) return 1;
    for (;;) {
        int n = recv(r->fd, r->buf, sizeof r->buf, 0);
        if (n > 0) { r->pos = 0; r->len = n; return 1; }
        if (n < 0 && errno == EINTR) continue;
        return 0;   /* EOF, error or 10 s timeout */
    }
}
static int rd_byte(struct rd *r) { return rd_fill(r) ? (unsigned char)r->buf[r->pos++] : -1; }
/* raw bytes of the body, after transfer decoding; returns count, 0 at the end */
static int rd_body(struct rd *r, char *out, int max) {
    if (r->eof) return 0;
    if (r->chunked && r->left == 0) {
        char line[32]; int i = 0, ch;
        if (r->gen) { while ((ch = rd_byte(r)) >= 0 && ch != '\n') ; }   /* CRLF after the previous chunk */
        r->gen = 1;
        while ((ch = rd_byte(r)) >= 0 && ch != '\n') if (i < 31) line[i++] = (char)ch;
        if (ch < 0) { r->eof = 1; return 0; }
        line[i] = 0;
        r->left = strtol(line, NULL, 16);
        if (r->left <= 0) { r->eof = 1; return 0; }
    }
    if (!r->chunked && r->left == 0) { r->eof = 1; return 0; }
    if (!rd_fill(r)) { r->eof = 1; return 0; }
    int n = r->len - r->pos;
    if (n > max) n = max;
    if (r->left >= 0 && n > r->left) n = (int)r->left;
    memcpy(out, r->buf + r->pos, n); r->pos += n;
    if (r->left > 0) r->left -= n;
    return n;
}
static int rd_exact(struct rd *r, char *out, int n) {
    int got = 0;
    while (got < n) { int k = rd_body(r, out + got, n - got); if (k <= 0) return got; got += k; }
    return got;
}

/* put samples into channel ch's ring; waits for space; 0 when the session was replaced */
static int push(struct chan *ch, const short *s, int n, unsigned gen) {
    pthread_mutex_lock(&g_mx);
    while (n > 0) {
        if (gen != ch->gen || !g_run) { pthread_mutex_unlock(&g_mx); return 0; }
        unsigned space = RB - (ch->wr - ch->rd);
        if (!space) {
            struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 1;
            pthread_cond_timedwait(&g_space, &g_mx, &ts);
            continue;
        }
        int k = n < (int)space ? n : (int)space;
        for (int i = 0; i < k; i++) ch->rb[(ch->wr + i) & (RB - 1)] = s[i];
        ch->wr += k; s += k; n -= k;
    }
    pthread_mutex_unlock(&g_mx);
    return 1;
}

/* a new session in channel ch (or none: active 0 = stop); returns its generation */
static unsigned new_session(struct chan *ch, int active, int vol) {
    pthread_mutex_lock(&g_mx);
    unsigned gen = ++ch->gen;
    ch->rd = ch->wr; ch->started = 0; ch->active = active; ch->keep = LIVE_KEEP; ch->skip = 0;
    ch->minav = ~0u; ch->win = 0; ch->vol = vol;
    pthread_cond_broadcast(&g_space);
    pthread_mutex_unlock(&g_mx);
    return gen;
}

static void play(int c, const char *q, struct rd *r) {
    int replied = 0;
    long vol = qnum(q, "vol", -1), rate = qnum(q, "rate", RATE), ch = qnum(q, "ch", 1);
    int live = qnum(q, "live", 0) == 1;
    struct chan *chn = &g_ch[live ? CH_LIVE : CH_PLAYER];
    unsigned gen = new_session(chn, 1, vol >= 0 && vol <= 100 ? (int)vol : -1);
    g_sessions++;
    struct timeval tv = { 10, 0 };   /* a live sender that goes quiet for 10 s is dropped */
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

    /* WAV header? */
    char hd[12]; int hn = rd_exact(r, hd, 12), pre = 0;
    if (hn == 12 && !memcmp(hd, "RIFF", 4) && !memcmp(hd + 8, "WAVE", 4)) {
        for (;;) {
            unsigned char ck[8];
            if (rd_exact(r, (char *)ck, 8) != 8) { reply(c, "400 Bad Request", "text/plain", "bad WAV\n"); replied = 1; goto out; }
            unsigned len = ck[4] | ck[5] << 8 | ck[6] << 16 | (unsigned)ck[7] << 24;
            if (!memcmp(ck, "data", 4)) break;
            if (!memcmp(ck, "fmt ", 4) && len >= 16 && len < 256) {
                unsigned char fm[256];
                if (rd_exact(r, (char *)fm, (int)(len + (len & 1))) != (int)(len + (len & 1))) { reply(c, "400 Bad Request", "text/plain", "bad WAV\n"); replied = 1; goto out; }
                int fmt = fm[0] | fm[1] << 8, bits = fm[14] | fm[15] << 8;
                ch = fm[2] | fm[3] << 8; rate = fm[4] | fm[5] << 8 | fm[6] << 16 | (long)fm[7] << 24;
                if (fmt == 0xfffe && len >= 26) fmt = fm[24] | fm[25] << 8;   /* WAVE_FORMAT_EXTENSIBLE */
                if (fmt != 1 || bits != 16) { reply(c, "415 Unsupported Media Type", "text/plain", "WAV must be 16-bit PCM\n"); replied = 1; goto out; }
            } else {
                char sk[512]; long left = len + (len & 1);
                while (left > 0) { int k = rd_exact(r, sk, left > 512 ? 512 : (int)left); if (k <= 0) break; left -= k; }
            }
        }
    } else pre = hn;   /* raw: the 12 bytes are audio */
    if (rate < 4000 || rate > 96000 || ch < 1 || ch > 2) { reply(c, "400 Bad Request", "text/plain", "rate 4000..96000, ch 1..2\n"); replied = 1; goto out; }
    logf_("play (%s): %ld Hz, %ld ch, vol %d", chn->name, rate, ch, chn->vol >= 0 ? chn->vol : g_vol);

    /* convert: downmix, linear resample to 16 kHz (16.16 fixed point step) */
    {
        char in[4096 + 4]; int carry = 0;
        short out[4096];
        unsigned step = (unsigned)(((unsigned long long)rate << 16) / RATE), pos = 0;
        int prev = 0, have_prev = 0;
        long total = 0;
        if (pre) { memcpy(in, hd, pre); carry = pre; }
        for (;;) {
            int n = rd_body(r, in + carry, 4096);
            if (n <= 0 && !carry) break;
            if (n < 0) n = 0;
            n += carry;
            int fsz = 2 * (int)ch, nf = n / fsz;
            carry = n - nf * fsz;
            int o = 0;
            for (int i = 0; i < nf; i++) {
                const unsigned char *p = (unsigned char *)in + i * fsz;
                int s = (short)(p[0] | p[1] << 8);
                if (ch == 2) s = (s + (short)(p[2] | p[3] << 8)) / 2;
                if (rate == RATE) { out[o++] = (short)s; continue; }
                if (!have_prev) { prev = s; have_prev = 1; }
                /* emit every output sample that falls between prev (0) and s (1) */
                while (pos < 0x10000) {
                    out[o++] = (short)(prev + (((s - prev) * (int)(pos >> 1)) >> 15));
                    pos += step;
                    if (o == (int)(sizeof out / sizeof *out)) { if (!push(chn, out, o, gen)) goto out; total += o; o = 0; }
                }
                pos -= 0x10000; prev = s;
            }
            if (o && !push(chn, out, o, gen)) goto out;
            total += o;
            if (carry) memmove(in, in + nf * fsz, carry);
            if (n - carry == 0 && carry) break;   /* stream ended mid-frame */
        }
        /* answer when it has been played, so that one /play after another doesn't cut the end */
        pthread_mutex_lock(&g_mx);
        if (gen == chn->gen) chn->active = 0;
        while (gen == chn->gen && chn->wr != chn->rd && g_run) {
            struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 1;
            pthread_cond_timedwait(&g_space, &g_mx, &ts);
        }
        int cut = gen != chn->gen;
        pthread_mutex_unlock(&g_mx);
        if (cut) goto out;
        char msg[64]; snprintf(msg, sizeof msg, "played %ld ms\n", total * 1000 / RATE);
        logf_("play (%s) ended: %ld ms", chn->name, total * 1000 / RATE);
        reply(c, "200 OK", "text/plain", msg); replied = 1;
    }
out:
    if (!replied) reply(c, "200 OK", "text/plain", "stopped\n");   /* replaced by /stop or a new /play */
    pthread_mutex_lock(&g_mx);
    if (gen == chn->gen) chn->active = 0;    /* what is buffered still plays out */
    pthread_mutex_unlock(&g_mx);
}

/* case-insensitive: does the header contain s (s in lower case)? */
static int hdr_has(const char *h, const char *s) {
    size_t n = strlen(s);
    for (; *h; h++) {
        size_t i = 0;
        while (i < n && h[i] && tolower((unsigned char)h[i]) == s[i]) i++;
        if (i == n) return 1;
    }
    return 0;
}

static int g_conns;     /* open connections, at most MAXCONN */
#define MAXCONN 8

static void *conn(void *arg) {
    int c = (int)(long)arg;
    block_signals();
    struct timeval tv = { 5, 0 };
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct rd *r = calloc(1, sizeof *r);
    char h[HDRMAX + 1]; int hl = 0;
    if (!r) goto done;
    r->fd = c; r->left = -1;
    /* header, byte by byte from the buffered reader, up to the blank line */
    for (;;) {
        int ch = rd_byte(r);
        if (ch < 0 || hl >= HDRMAX) goto done;
        h[hl++] = (char)ch;
        if (hl >= 4 && !memcmp(h + hl - 4, "\r\n\r\n", 4)) break;
        if (hl >= 2 && !memcmp(h + hl - 2, "\n\n", 2)) break;
    }
    h[hl] = 0;
    char meth[8] = "", path[256] = "";
    if (sscanf(h, "%7s %255s", meth, path) != 2) goto done;
    char *q = strchr(path, '?'); if (q) *q++ = 0; else q = path + strlen(path);
    for (char *l = strchr(h, '\n'); l; l = strchr(l + 1, '\n')) {
        if (!strncasecmp(l + 1, "Content-Length:", 15)) r->left = strtol(l + 16, NULL, 10);
        if (!strncasecmp(l + 1, "Transfer-Encoding:", 18) && strstr(l, "chunked")) { r->chunked = 1; r->left = 0; }
    }
    if (!strcmp(meth, "OPTIONS")) { reply(c, "204 No Content", "text/plain", ""); goto done; }
    if (!token_ok(q)) { reply(c, "403 Forbidden", "text/plain", "token required\n"); goto done; }
    if (!strcmp(path, "/play") && (!strcmp(meth, "POST") || !strcmp(meth, "PUT"))) {
        if (hdr_has(h, "expect: 100-continue"))
            send(c, "HTTP/1.1 100 Continue\r\n\r\n", 25, MSG_NOSIGNAL);
        play(c, q, r);
    } else if (!strcmp(meth, "GET") && !strcmp(path, "/stop")) {
        /* ?ch=player|live, default both */
        int which = strstr(q, "ch=player") ? 1 : strstr(q, "ch=live") ? 2 : 3;
        if (which & 1) new_session(&g_ch[CH_PLAYER], 0, -1);
        if (which & 2) new_session(&g_ch[CH_LIVE], 0, -1);
        logf_("stop (%s)", which == 1 ? "player" : which == 2 ? "live" : "all");
        reply(c, "200 OK", "text/plain", "stopped\n");
    } else if (!strcmp(meth, "GET") && !strcmp(path, "/vol")) {
        long v = qnum(q, "v", -1);
        if (v < 0 || v > 100) reply(c, "400 Bad Request", "text/plain", "v must be 0..100\n");
        else {
            /* ?ch=player|live sets that channel, default all */
            pthread_mutex_lock(&g_mx);
            if (strstr(q, "ch=player")) g_ch[CH_PLAYER].vol = (int)v;
            else if (strstr(q, "ch=live")) g_ch[CH_LIVE].vol = (int)v;
            else { g_vol = (int)v; g_ch[0].vol = g_ch[1].vol = -1; }
            pthread_mutex_unlock(&g_mx);
            reply(c, "200 OK", "text/plain", "ok\n");
        }
    } else if (!strcmp(meth, "GET") && !strcmp(path, "/status")) {
        char b[640], cj[2][160];
        pthread_mutex_lock(&g_mx);
        struct chan *P = &g_ch[CH_PLAYER], *L = &g_ch[CH_LIVE];
        for (int k = 0; k < 2; k++) {
            struct chan *x = &g_ch[k];
            snprintf(cj[k], sizeof cj[k], "{\"playing\":%d,\"buffered_ms\":%u,\"underruns\":%u,\"dropped_ms\":%u,\"vol\":%d}",
                     x->active || x->wr != x->rd, (x->wr - x->rd) * 1000 / RATE, x->underruns,
                     x->dropped * 1000 / RATE, x->vol >= 0 ? x->vol : g_vol);
        }
        /* top level: both channels together (the fields of the first version), then each */
        unsigned bp = P->wr - P->rd, bl = L->wr - L->rd;
        snprintf(b, sizeof b, "{\"playing\":%d,\"buffered_ms\":%u,\"keep_ms\":%u,\"underruns\":%u,\"dropped_ms\":%u,"
                 "\"missed_frames\":%u,\"max_gap_ms\":%u,\"vol\":%d,\"sessions\":%u,\"player\":%s,\"live\":%s}\n",
                 P->active || bp || L->active || bl, (bp > bl ? bp : bl) * 1000 / RATE,
                 L->keep * 1000 / RATE, P->underruns + L->underruns, (P->dropped + L->dropped) * 1000 / RATE,
                 g_missed, g_maxgap, g_vol, g_sessions, cj[0], cj[1]);
        pthread_mutex_unlock(&g_mx);
        reply(c, "200 OK", "application/json", b);
    } else reply(c, "404 Not Found", "text/plain", "not found\n");
done:
    free(r);
    close(c);
    pthread_mutex_lock(&g_mx); g_conns--; pthread_mutex_unlock(&g_mx);
    return NULL;
}

static void usage(void) {
    fprintf(stderr, "usage: spkstream [-p PORT] [-k TOKEN] [-v VOL] [-l LOGFILE] [-N] | -x\n");
    exit(2);
}

int main(int argc, char **argv) {
    int port = 8091, opt, cleanup = 0;
    const char *logp = NULL;
    while ((opt = getopt(argc, argv, "p:k:v:l:xN")) != -1) {
        switch (opt) {
        case 'p': port = atoi(optarg); break;
        case 'k': g_token = optarg; break;
        case 'v': g_vol = atoi(optarg); if (g_vol < 0 || g_vol > 100) usage(); break;
        case 'l': logp = optarg; break;
        case 'x': cleanup = 1; break;
        case 'N': g_nort = 1; break;
        default: usage();
        }
    }
    g_log = logp ? fopen(logp, "a") : stderr;
    for (int k = 0; k < 2; k++) {
        g_ch[k].name = k == CH_LIVE ? "live" : "player"; g_ch[k].live = k == CH_LIVE;
        g_ch[k].keep = LIVE_KEEP; g_ch[k].minav = ~0u; g_ch[k].vol = -1;
    }
    g_amxr = open("/dev/amxr", O_RDWR);
    if (g_amxr < 0) { logf_("open /dev/amxr: %s", strerror(errno)); return 1; }
    g_src = port_by_name("amxruser.bind0");
    g_dst = port_by_name("halaudio.apm1");
    if (!g_src || !g_dst) { logf_("amxr ports missing (is amxr_user_hook loaded?)"); return 1; }
    if (cleanup) { amxr_link(0); return 0; }
    g_user = open("/dev/amxruser", O_RDWR);
    g_hal = open("/dev/halaudio", O_RDWR);
    if (g_user < 0 || g_hal < 0) { logf_("open /dev/amxruser or /dev/halaudio: %s", strerror(errno)); return 1; }

    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 4) < 0) { logf_("port %d: %s", port, strerror(errno)); return 1; }
    if (amxr_link(1) < 0) { logf_("amxrConnect: %s", strerror(errno)); return 1; }

    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig;
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    pthread_t pt; pthread_create(&pt, NULL, pump, NULL);
    logf_("serving on port %d", port);

    while (g_run) {
        int c = accept(s, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; break; }
        pthread_mutex_lock(&g_mx);
        int full = g_conns >= MAXCONN; if (!full) g_conns++;
        pthread_mutex_unlock(&g_mx);
        if (full) { close(c); continue; }
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        pthread_t t; pthread_attr_t at; pthread_attr_init(&at);
        pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        pthread_attr_setstacksize(&at, 128 * 1024);
        if (pthread_create(&t, &at, conn, (void *)(long)c)) {
            close(c); pthread_mutex_lock(&g_mx); g_conns--; pthread_mutex_unlock(&g_mx);
        }
    }
    g_run = 0;
    new_session(&g_ch[CH_PLAYER], 0, -1);
    new_session(&g_ch[CH_LIVE], 0, -1);
    pthread_join(pt, NULL);
    amxr_link(0);
    gains_off();
    logf_("stopped");
    return 0;
}
