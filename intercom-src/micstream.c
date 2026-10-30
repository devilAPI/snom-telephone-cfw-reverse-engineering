/* intercom-src/micstream.c - stream the snom D375 microphone to the network.
 *
 * Intercom / baby monitor for the CFW (see docs/intercom.md).
 *
 * Capture path (recovered in docs/sound.md, test tool tools/halloop.c):
 *   - the stock kernel module amxr_user_hook.ko provides /dev/amxruser (major 236)
 *     with three amxr ports "amxruser.bind0..2";
 *   - we add amxr connections  halaudio.apm0/1 -> amxruser.bind2  (descriptor
 *     0x1010 = mono->mono, the one media_daemon uses itself; bind2 because other
 *     test tools use bind0/1 and amxr would mix their sources in). The existing
 *     halaudio.apm<ch> -> ept.bind<ch> connection of the phone stays untouched; amxr
 *     fans a source port out to several destinations;
 *   - the idle phone has the codec gains muted (-1000 dB -> exact zeros); we unmute
 *     the channel's ADC + mic preamp blocks while they read muted (see adc_check);
 *   - ioctl(0xc0044502) blocks until the next 5 ms frame sync, ioctl(0xc0044501,
 *     {port, buf}) copies one frame = 80 samples S16LE, 16 kHz mono (160 bytes).
 *
 * Output:
 *   HTTP on -p PORT (default 8090):
 *     GET /stream.wav[?k=TOKEN]  audio/wav, 16 kHz mono S16LE, endless-length header
 *     GET /raw[?k=TOKEN]         application/octet-stream, bare S16LE samples
 *   With -k TOKEN every request must carry k=TOKEN (else 403).
 *   File mode for tests: -o FILE -t SECS writes raw S16LE and exits.
 *
 * Stops on SIGTERM/SIGINT and removes its amxr connection (amxrDisconnect) so the
 * device is free again. The module itself is left to the caller (cgi-bin/intercom).
 *
 * Build: tools/build-intercom.sh (static musl, armv6 soft-float). Integer only. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define AMXR_QUERY_PORT   0x80244d30u /* _IOR('M',48,36) {char name[32]; void **out} */
#define AMXR_CONNECT      0x800c4d35u /* _IOR('M',53,12) {src, dst, desc} */
#define AMXR_DISCONNECT   0x80084d36u /* _IOR('M',54,8)  {src, dst} */
#define AMXRUSER_READ     0xc0044501u /* {int port; void *buf} -> 160 bytes */
#define AMXRUSER_WAIT     0xc0044502u /* block until next frame sync */
#define AMXR_DESC_MONO    0x1010
#define HAL_GET_GAIN      0x80084132u /* _IOR('A',50,8) {int block; int *info} info[0] = current dB */
#define HAL_SET_GAIN      0x80084133u /* _IOR('A',51,8) {int block; int db} */
#define GAIN_MUTE         (-1000)     /* what media_daemon writes while idle */

#define RATE      16000
#define FRAME     80                  /* samples per 5 ms frame */
#define BATCH     4                   /* frames per network write (20 ms) */
#define MAXCLI    4
#define HDRMAX    1024

static volatile sig_atomic_t g_run = 1;
static void on_sig(int s) { (void)s; g_run = 0; }

/* sources: halaudio.apm0 and/or apm1, both into amxruser.bind<g_uport>; amxr sums
 * all sources connected to one destination, so "-c 2" (default) mixes both mic paths.
 * Which APM channel carries the live mic depends on media_daemon's last route
 * (fresh boot: CH1; after a call / off-hook: CH0); the muted one adds exact zeros. */
static void *g_src[2], *g_dst;
static int g_amxr = -1, g_wired[2];
static int g_uport = 2; /* amxruser.bind2: bind0/1 are used by other test tools */

static int amxr_port(int m, const char *name, void **out) {
    struct { char name[32]; void **out; } q;
    memset(&q, 0, sizeof q);
    strncpy(q.name, name, 31);
    q.out = out;
    return ioctl(m, AMXR_QUERY_PORT, &q);
}
/* look the ports up; connect them too unless lookup_only */
static int wire(int chmask, int lookup_only) {
    char s[32], d[32];
    snprintf(d, sizeof d, "amxruser.bind%d", g_uport);
    g_amxr = open("/dev/amxr", O_RDWR);
    if (g_amxr < 0) { perror("micstream: /dev/amxr"); return -1; }
    if (amxr_port(g_amxr, d, &g_dst) < 0 || !g_dst) {
        fprintf(stderr, "micstream: amxr port %s not found (amxr_user_hook.ko loaded?)\n", d);
        return -1;
    }
    for (int ch = 0; ch < 2; ch++) {
        if (!(chmask & (1 << ch))) continue;
        snprintf(s, sizeof s, "halaudio.apm%d", ch);
        if (amxr_port(g_amxr, s, &g_src[ch]) < 0 || !g_src[ch]) {
            fprintf(stderr, "micstream: amxr port %s not found\n", s); return -1;
        }
        if (lookup_only) { g_wired[ch] = 1; continue; }
        struct { void *s, *d; int desc; } c = { g_src[ch], g_dst, AMXR_DESC_MONO };
        if (ioctl(g_amxr, AMXR_CONNECT, &c) < 0) { perror("micstream: amxrConnect"); return -1; }
        g_wired[ch] = 1;
        fprintf(stderr, "micstream: connected %s -> %s\n", s, d);
    }
    return 0;
}

static void unwire(void) {
    if (g_amxr < 0) return;
    for (int ch = 0; ch < 2; ch++) {
        if (!g_wired[ch]) continue;
        struct { void *s, *d; } c = { g_src[ch], g_dst };
        if (ioctl(g_amxr, AMXR_DISCONNECT, &c) < 0) perror("micstream: amxrDisconnect");
        else fprintf(stderr, "micstream: disconnected apm%d\n", ch);
        g_wired[ch] = 0;
    }
    close(g_amxr);
    g_amxr = -1;
}

/* ---- codec gains ----
 * While the phone is idle media_daemon mutes the codec gain blocks (-1000 dB); the
 * mic samples arriving at the amxr tap are then exact zeros. Block id = (cid << 8) |
 * type; for an APM channel: 0x04 = digital ADC gain (-50..0 dB), 0x10 / 0x20 = analog
 * mic preamps (0..42 dB). Every block that reads "muted" is set to our value
 * (re-checked once a second, media_daemon mutes again after every call), and on exit
 * put back to mute if it still holds our value. During a call media_daemon owns them. */
static int g_hal = -1, g_adc_db = 0, g_pre_db = 24;
static int g_blk[6], g_val[6], g_mine[6], g_nblk;

static int gain_get(int blk) {
    /* the kernel copies a whole HALAUDIO_GAIN_INFO incl. its dB table (several hundred
     * bytes; a 64-byte buffer overflowed the stack) - give it plenty of room */
    static int info[1024];
    struct { int b; int *p; } q = { blk, info };
    if (g_hal < 0 || ioctl(g_hal, HAL_GET_GAIN, &q) < 0) return -9999;
    return info[0];
}
static int gain_set(int blk, int db) {
    struct { int b, db; } s = { blk, db };
    return g_hal < 0 ? -1 : ioctl(g_hal, HAL_SET_GAIN, &s);
}
static void adc_open(int chmask) {
    g_nblk = 0;
    for (int ch = 0; ch < 2; ch++) {
        if (!(chmask & (1 << ch))) continue;
        g_blk[g_nblk] = (ch << 8) | 0x04; g_val[g_nblk++] = g_adc_db;
        g_blk[g_nblk] = (ch << 8) | 0x10; g_val[g_nblk++] = g_pre_db;
        g_blk[g_nblk] = (ch << 8) | 0x20; g_val[g_nblk++] = g_pre_db;
    }
    g_hal = open("/dev/halaudio", O_RDWR);
    if (g_hal < 0) perror("micstream: /dev/halaudio (gain control disabled)");
}
static void adc_check(void) {
    for (int i = 0; i < g_nblk; i++)
        if (gain_get(g_blk[i]) == GAIN_MUTE && gain_set(g_blk[i], g_val[i]) == 0) {
            if (!g_mine[i]) fprintf(stderr, "micstream: unmuted gain block %#x -> %d dB\n", g_blk[i], g_val[i]);
            g_mine[i] = 1;
        }
}
static void adc_restore(int force) {
    if (g_hal < 0) return;
    for (int i = 0; i < g_nblk; i++)
        if ((g_mine[i] || force) && gain_get(g_blk[i]) == g_val[i]) {
            gain_set(g_blk[i], GAIN_MUTE);
            fprintf(stderr, "micstream: re-muted gain block %#x\n", g_blk[i]);
        }
    close(g_hal);
    g_hal = -1;
}

/* ---- clients ---- */
enum { C_FREE, C_HDR, C_WAV, C_RAW };
struct cli { int fd, st, n; time_t t0; char hdr[HDRMAX]; };
static struct cli g_cli[MAXCLI];
static const char *g_token;

static void cli_close(struct cli *c) { if (c->fd >= 0) close(c->fd); c->fd = -1; c->st = C_FREE; c->n = 0; }

static int sendall(int fd, const void *p, int n) {
    /* blocking-ish: socket is non-blocking; a client that can't take a 20 ms batch
     * plus its kernel buffer (SO_SNDBUF) is too slow and gets dropped. */
    const char *b = p;
    while (n > 0) {
        int w = send(fd, b, n, MSG_NOSIGNAL);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        b += w; n -= w;
    }
    return 0;
}

static void le32(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void le16(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }

/* WAV header with "endless" sizes (0xFFFFFFFF), understood by browsers, ffplay, aplay. */
static void wav_header(unsigned char h[44]) {
    memcpy(h, "RIFF", 4); le32(h + 4, 0xFFFFFFFFu); memcpy(h + 8, "WAVEfmt ", 8);
    le32(h + 16, 16); le16(h + 20, 1); le16(h + 22, 1); le32(h + 24, RATE);
    le32(h + 28, RATE * 2); le16(h + 32, 2); le16(h + 34, 16);
    memcpy(h + 36, "data", 4); le32(h + 40, 0xFFFFFFFFu);
}

/* token check: query string must contain k=<token> as a whole parameter */
static int token_ok(const char *q) {
    if (!g_token || !*g_token) return 1;
    size_t tl = strlen(g_token);
    while (q && *q) {
        if (!strncmp(q, "k=", 2) && !strncmp(q + 2, g_token, tl) && (q[2 + tl] == '&' || q[2 + tl] == 0))
            return 1;
        q = strchr(q, '&');
        if (q) q++;
    }
    return 0;
}

static void reply(struct cli *c, const char *status, const char *body) {
    char b[256];
    int n = snprintf(b, sizeof b, "HTTP/1.0 %s\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n%s\n", status, body);
    sendall(c->fd, b, n);
    cli_close(c);
}

static void handle_request(struct cli *c) {
    char path[256] = "", *q;
    if (sscanf(c->hdr, "GET %255s", path) != 1) { reply(c, "400 Bad Request", "bad request"); return; }
    q = strchr(path, '?');
    if (q) *q++ = 0;
    if (!token_ok(q)) { reply(c, "403 Forbidden", "token required"); return; }
    int wav;
    if (!strcmp(path, "/") || !strcmp(path, "/stream.wav")) wav = 1;
    else if (!strcmp(path, "/raw")) wav = 0;
    else { reply(c, "404 Not Found", "use /stream.wav or /raw"); return; }
    char h[320];
    int n = snprintf(h, sizeof h,
        "HTTP/1.0 200 OK\r\nContent-Type: %s\r\nCache-Control: no-cache, no-store\r\n"
        "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        wav ? "audio/wav" : "application/octet-stream");
    if (sendall(c->fd, h, n) < 0) { cli_close(c); return; }
    if (wav) {
        unsigned char w[44]; wav_header(w);
        if (sendall(c->fd, w, 44) < 0) { cli_close(c); return; }
    }
    c->st = wav ? C_WAV : C_RAW;
    fprintf(stderr, "micstream: client %d streaming %s\n", c->fd, wav ? "wav" : "raw");
}

static void poll_net(int lfd) {
    if (lfd < 0) return;
    for (;;) {
        int fd = accept(lfd, NULL, NULL);
        if (fd < 0) break;
        int i;
        for (i = 0; i < MAXCLI && g_cli[i].st != C_FREE; i++) ;
        if (i == MAXCLI) {
            static const char busy[] = "HTTP/1.0 503 Busy\r\nConnection: close\r\n\r\ntoo many listeners\n";
            send(fd, busy, sizeof busy - 1, MSG_NOSIGNAL | MSG_DONTWAIT);
            close(fd); continue;
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        int sb = 64 * 1024; setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sb, sizeof sb);
        g_cli[i].fd = fd; g_cli[i].st = C_HDR; g_cli[i].n = 0; g_cli[i].t0 = time(NULL);
    }
    for (int i = 0; i < MAXCLI; i++) {
        struct cli *c = &g_cli[i];
        if (c->st == C_HDR) {
            int r = recv(c->fd, c->hdr + c->n, HDRMAX - 1 - c->n, 0);
            if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR)) { cli_close(c); continue; }
            if (r > 0) { c->n += r; c->hdr[c->n] = 0; }
            if (strstr(c->hdr, "\r\n\r\n") || strstr(c->hdr, "\n\n")) handle_request(c);
            else if (c->n >= HDRMAX - 1) reply(c, "431 Too Large", "header too large");
            else if (time(NULL) - c->t0 > 5) cli_close(c);
        } else if (c->st == C_WAV || c->st == C_RAW) {
            /* drain anything the client sends; detect hangup */
            char junk[256];
            int r = recv(c->fd, junk, sizeof junk, 0);
            if (r == 0) { fprintf(stderr, "micstream: client %d left\n", c->fd); cli_close(c); }
        }
    }
}

static void send_audio(const void *buf, int n) {
    for (int i = 0; i < MAXCLI; i++) {
        struct cli *c = &g_cli[i];
        if (c->st != C_WAV && c->st != C_RAW) continue;
        int w = send(c->fd, buf, n, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (w != n) { fprintf(stderr, "micstream: client %d dropped (slow or gone)\n", c->fd); cli_close(c); }
    }
}

static int listen_on(const char *addr, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(port);
    if (inet_pton(AF_INET, addr, &a.sin_addr) != 1) { fprintf(stderr, "bad address %s\n", addr); close(fd); return -1; }
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 4) < 0) { perror("micstream: bind"); close(fd); return -1; }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    return fd;
}

static void usage(void) {
    fprintf(stderr,
        "usage: micstream [-c CH] [-g SHIFT] [-p PORT] [-b ADDR] [-k TOKEN] [-L LEVELFILE]\n"
        "       micstream [-c CH] [-g SHIFT] -o FILE -t SECS     (raw capture for tests)\n"
        "  -c CH      APM channel 0, 1 or 2 = both mixed (default 2)\n"
        "  -u N       amxruser port 0..2 to use (default 2)\n"
        "  -P DB      analog mic preamp used while muted (0..42, default 24)\n"
        "  -g SHIFT   digital gain, left shift 0..6 with saturation (default 0)\n"
        "  -A DB      ADC digital gain used while the phone has it muted (-50..0, default 0)\n"
        "  -L FILE    write 'rms peak' of the last second to FILE once per second\n"
        "  -l FILE    append log messages to FILE (stderr otherwise)\n"
        "  -x         cleanup only: remove leftover amxr connections, then exit\n");
}

int main(int argc, char **argv) {
    int ch = 2, gain = 0, port = 8090, secs = 0, opt, cleanup = 0;
    const char *bindaddr = "0.0.0.0", *outfile = NULL, *levelfile = NULL;
    while ((opt = getopt(argc, argv, "c:g:p:b:k:o:t:L:l:A:P:u:xh")) != -1) {
        switch (opt) {
        case 'c': ch = atoi(optarg); break;
        case 'g': gain = atoi(optarg); break;
        case 'p': port = atoi(optarg); break;
        case 'b': bindaddr = optarg; break;
        case 'k': g_token = optarg; break;
        case 'o': outfile = optarg; break;
        case 't': secs = atoi(optarg); break;
        case 'L': levelfile = optarg; break;
        case 'A': g_adc_db = atoi(optarg); break;
        case 'x': cleanup = 1; break;
        case 'P': g_pre_db = atoi(optarg); break;
        case 'u': g_uport = atoi(optarg); break;
        case 'l': {
            int lf = open(optarg, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (lf >= 0) { dup2(lf, 2); close(lf); }
            break;
        }
        default: usage(); return 2;
        }
    }
    if (ch < 0 || ch > 2 || gain < 0 || gain > 6 || g_adc_db < -50 || g_adc_db > 0 || g_pre_db < 0 || g_pre_db > 42 || g_uport < 0 || g_uport > 2 || port <= 0 || port > 65535) { usage(); return 2; }

    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig;
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    for (int i = 0; i < MAXCLI; i++) g_cli[i].fd = -1;
    setvbuf(stderr, NULL, _IONBF, 0);

    int mask = ch == 2 ? 3 : 1 << ch;
    if (cleanup) {
        /* after a kill -9: remove the amxr connections. The gains are left as they are
         * (we cannot tell ours from media_daemon's any more; an unmuted ADC on an idle
         * phone is harmless and media_daemon resets it on the next call). */
        if (wire(mask, 1) == 0) unwire();
        return 0;
    }

    int ofd = -1, lfd = -1;
    if (outfile) {
        ofd = !strcmp(outfile, "-") ? 1 : open(outfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (ofd < 0) { perror(outfile); return 1; }
    } else if ((lfd = listen_on(bindaddr, port)) < 0) return 1;

    int u = open("/dev/amxruser", O_RDWR);
    if (u < 0) { perror("micstream: /dev/amxruser (insmod amxr_user_hook.ko)"); return 1; }
    if (wire(mask, 0) < 0) { unwire(); return 1; }
    adc_open(mask);
    adc_check();
    if (lfd >= 0) fprintf(stderr, "micstream: serving http://%s:%d/stream.wav\n", bindaddr, port);

    short buf[FRAME * BATCH];
    int nb = 0, rc = 0;
    long frames = 0, limit = secs > 0 ? (long)secs * (RATE / FRAME) : -1;
    unsigned long long sq = 0; int peak = 0, lvn = 0, hp_x1 = 0; long long hp_y = 0;
    while (g_run && (limit < 0 || frames < limit)) {
        if (ioctl(u, AMXRUSER_WAIT, 0) < 0) {
            if (errno == EINTR) continue;
            perror("micstream: wait"); rc = 1; break;
        }
        struct { int port; void *buf; } d = { g_uport, buf + nb * FRAME };
        if (ioctl(u, AMXRUSER_READ, &d) < 0) {
            if (errno == EINTR) continue;
            perror("micstream: read"); rc = 1; break;
        }
        short *s = buf + nb * FRAME;
        for (int i = 0; i < FRAME; i++) {
            /* DC blocker (the unmuted ADC has an offset of ~900 LSB): one-pole
             * high-pass y = x - x1 + 0.995 * y1, Q15 fixed point, ~13 Hz corner */
            int x = s[i];
            hp_y = (long long)(x - hp_x1) * 32768 + ((hp_y * 32604) >> 15);
            hp_x1 = x;
            int v = (int)(hp_y >> 15) << gain;
            if (v > 32767) v = 32767; else if (v < -32768) v = -32768;
            s[i] = v;
            int a = v < 0 ? -v : v;
            if (a > peak) peak = a;
            sq += (unsigned)(v * v);
        }
        frames++;
        if (frames % (RATE / FRAME) == 0) adc_check();
        if (levelfile && ++lvn == RATE / FRAME) {
            /* integer sqrt of mean square over the last second */
            unsigned long long ms = sq / (RATE);
            unsigned r = 0, b = 1u << 15;
            while (b) { unsigned t = r | b; if ((unsigned long long)t * t <= ms) r = t; b >>= 1; }
            FILE *f = fopen(levelfile, "w");
            if (f) { fprintf(f, "%u %d\n", r, peak); fclose(f); }
            sq = 0; peak = 0; lvn = 0;
        }
        if (++nb == BATCH) {
            if (ofd >= 0) { if (write(ofd, buf, sizeof buf) < 0) { perror("write"); rc = 1; break; } }
            else send_audio(buf, sizeof buf);
            nb = 0;
            poll_net(lfd);
        }
    }
    if (ofd >= 0 && nb && write(ofd, buf, nb * FRAME * 2) < 0) rc = 1;
    unwire();
    adc_restore(0);
    close(u);
    for (int i = 0; i < MAXCLI; i++) cli_close(&g_cli[i]);
    if (lfd >= 0) close(lfd);
    if (ofd > 1) close(ofd);
    if (levelfile) unlink(levelfile);
    fprintf(stderr, "micstream: %ld frames, exit %d\n", frames, rc);
    return rc;
}
