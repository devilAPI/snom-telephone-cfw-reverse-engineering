/* snd_hal - see snd_hal.h for the design. Pure ioctl/evdev + one pump thread;
 * no glibc .so linkage, so it works from the static-musl game binaries. */
#include "snd_hal.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <pthread.h>

/* halaudio ioctl ABI, recovered from the unstripped /lib/libhalaudio.so.
 * Magic 'A' (0x41). Args marked &{a,b} pass a 2-int struct by pointer. */
#define HAL_SUPERUSER 0x00004139u   /* _IO ('A',57)      super-user on/off (by value) */
#define HAL_SETPOWER  0x00004135u   /* _IO ('A',53)      power level (by value); 2=FULL */
#define HAL_ENABLEIF  0x80084141u   /* _IOR('A',65,8)    &{iface, enable} */
#define HAL_SETFREQ   0x8008413au   /* _IOR('A',58,8)    &{codec, hz} */
#define HAL_WRITE     0x80084138u   /* _IOR('A',56,8)    &{codec, fmt}, then write(fd,buf,n) */

/* write() sample format, from the kernel's built-in halaudio_write (uImage
 * 10.1.64.17 @0xc0197630): 1 = native S16LE (passed through), 2/3 = 8-bit
 * companded (table-expanded), ANY other value (incl. 0) = S16BE: the kernel
 * byte-swaps every sample. Sending LE data as fmt 0 is what turned broadband
 * game audio into level-proportional noise while pure tones stayed pitched. */
#define HAL_FMT_S16LE 1

#define HAL_CID       1             /* APM CH1 -> loudspeaker in hands-free (confirmed by ear) */
#define HAL_RATE      16000         /* APM codec runs 16 kHz mono */
#define HAL_IFACE     0             /* APM interface id */

#define KEY_SPEAKER   17            /* evdev scancode of the speaker button (captured live) */
#define EVENT_NODE    "/dev/input/event0"

#define CHUNK         (HAL_RATE/100)    /* 160 samples = 10 ms */
#define RING_BITS     15
#define RING_SZ       (1u << RING_BITS) /* 32768 samples ~= 2 s */
#define RING_MASK     (RING_SZ - 1)

static int             g_fd = -1;
static volatile int    g_ok = 0;
static volatile int    g_run = 0;
static pthread_t       g_thread;
#define VOL_FILE "/snom/cfw-data/volume"
static int             g_volpct = 50;       /* percent shown/persisted */
static int             g_vol = 128;
static int             g_volpersist = 1;    /* 0 when SND_VOL overrides (bench tests) */         /* output gain, Q8 (256 = unity); SND_VOL=% */
static volatile int    g_underruns;

/* SPSC ring (producer = game thread, consumer = pump thread). */
static int16_t         g_ring[RING_SZ];
static volatile unsigned g_head, g_tail;   /* head = write index, tail = read index */

static unsigned ring_used(void) { return (g_head - g_tail) & RING_MASK; }

static void ring_put(int16_t v) {
    if (((g_head + 1) & RING_MASK) == (g_tail & RING_MASK))
        return;                            /* full: drop (overrun) */
    g_ring[g_head & RING_MASK] = v;
    __sync_synchronize();
    g_head++;
}

static int ring_get(int16_t *v) {
    if ((g_tail & RING_MASK) == (g_head & RING_MASK))
        return 0;                          /* empty (underrun) */
    *v = g_ring[g_tail & RING_MASK];
    __sync_synchronize();
    g_tail++;
    return 1;
}

/* 32-bit kernel input_event: tv_sec, tv_usec (int), type, code (u16), value (int). */
struct iev { int sec, usec; unsigned short type, code; int value; };

static void inject_speaker(void) {
    int fd = open(EVENT_NODE, O_WRONLY);
    if (fd < 0) { fprintf(stderr, "snd_hal: open %s wr: %s\n", EVENT_NODE, strerror(errno)); return; }
    struct iev e;
    memset(&e, 0, sizeof e); e.type = 1; e.code = KEY_SPEAKER; e.value = 1; (void)!write(fd, &e, sizeof e);
    memset(&e, 0, sizeof e); e.type = 0; e.code = 0;           e.value = 0; (void)!write(fd, &e, sizeof e);
    usleep(60000);
    memset(&e, 0, sizeof e); e.type = 1; e.code = KEY_SPEAKER; e.value = 0; (void)!write(fd, &e, sizeof e);
    memset(&e, 0, sizeof e); e.type = 0; e.code = 0;           e.value = 0; (void)!write(fd, &e, sizeof e);
    close(fd);
}

static void *pump(void *arg) {
    (void)arg;
    struct { int cid, fmt; } w = { HAL_CID, HAL_FMT_S16LE };
    int16_t chunk[CHUNK];
    int busy = 0;
    int dumpfd = -1;
    if (getenv("SND_DUMP"))
        dumpfd = open("/tmp/snd_dump.raw", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    while (g_run) {
        int dry = 0;
        for (int i = 0; i < CHUNK; i++) {
            int16_t v;
            if (!ring_get(&v)) { v = 0; dry = 1; }   /* underrun -> silence (keeps the amp/DMA alive) */
            chunk[i] = (int16_t)((v * g_vol) >> 8);
        }
        if (dry && g_head != 0) g_underruns++;   /* don't count the idle lead-in */
        /* Blocking write: the codec DMA paces this at real time (16 kHz), which
         * is also our audio clock -- no extra timing needed. */
        ioctl(g_fd, HAL_WRITE, &w);
        if (write(g_fd, chunk, sizeof chunk) < 0 && errno != EINTR) {
            /* EBUSY shows up transiently while the codec settles after the
             * takeover; retry for a while before giving up. */
            if (errno == EBUSY && ++busy < 300) { usleep(10000); continue; }
            fprintf(stderr, "snd_hal: write: %s\n", strerror(errno));
            break;
        }
        busy = 0;
        if (dumpfd >= 0) (void)!write(dumpfd, chunk, sizeof chunk);
    }
    if (dumpfd >= 0) close(dumpfd);
    g_ok = 0;   /* pump is gone: games stop pushing and fall back to wall-clock pacing */
    return NULL;
}

int snd_hal_volume(void) { return g_volpct; }

void snd_hal_volume_step(int delta_pct) {
    int p = g_volpct + delta_pct;
    if (p < 0) p = 0; else if (p > 100) p = 100;
    g_volpct = p;
    g_vol = p * 256 / 100;
    fprintf(stderr, "volume: %d%%\n", p);
    FILE *f = g_volpersist ? fopen(VOL_FILE ".tmp", "w") : NULL;     /* tmp+rename: never a torn file */
    if (f) {
        fprintf(f, "%d\n", p);
        if (fclose(f) == 0) rename(VOL_FILE ".tmp", VOL_FILE);
    }
}

int snd_hal_init(void) {
    struct { int a, b; } p;

    /* 1. Arm the codec while media_daemon is still alive (we co-exist as a
     *    second client holding FULL power). */
    g_fd = open("/dev/halaudio", O_RDWR);
    if (g_fd >= 0) {
        ioctl(g_fd, HAL_SUPERUSER, 1);
        ioctl(g_fd, HAL_SETPOWER, 2);                 /* FULL_POWER */
        p.a = HAL_IFACE; p.b = 1; ioctl(g_fd, HAL_ENABLEIF, &p);
        p.a = HAL_CID;   p.b = HAL_RATE; ioctl(g_fd, HAL_SETFREQ, &p);

        /* 2. Hands-free bring-up via media_daemon's own EPT path. */
        inject_speaker();
        usleep(700000);                               /* let the amp/route settle */
        g_ok = 1;
    } else {
        fprintf(stderr, "snd_hal: open /dev/halaudio: %s (no sound)\n", strerror(errno));
    }

    /* 3. Take over: always kill lid+media_daemon so the game owns fb0+keypad.
     *    /tmp/ssh_fast_update tells rcS not to reboot when the app dies. */
    if (system("touch /tmp/ssh_fast_update; kill -9 $(pidof lid) $(pidof media_daemon) 2>/dev/null") == -1)
        fprintf(stderr, "snd_hal: takeover system() failed: %s\n", strerror(errno));
    usleep(400000);

    /* 4. Start the pump (our client now holds the only FULL-power handle). */
    {   /* volume: /snom/cfw-data/volume (percent, default 50); SND_VOL overrides it */
        const char *vol = getenv("SND_VOL");
        FILE *vf = vol ? NULL : fopen(VOL_FILE, "r");
        int pct = 50;
        if (vf) { if (fscanf(vf, "%d", &pct) != 1) pct = 50; fclose(vf); }
        if (vol) { pct = atoi(vol); g_volpersist = 0; }
        if (pct < 0) pct = 0; else if (pct > 100) pct = 100;
        g_volpct = pct;
        g_vol = pct * 256 / 100;
    }
    if (g_ok) {
        g_head = g_tail = 0;
        g_run = 1;
        if (pthread_create(&g_thread, NULL, pump, NULL) != 0) {
            fprintf(stderr, "snd_hal: pthread_create failed (no sound)\n");
            g_run = 0; g_ok = 0;
        }
    }
    return g_ok ? 0 : -1;
}

void snd_hal_push16k(const short *s, int n) {
    if (!g_ok) return;
    for (int i = 0; i < n; i++) ring_put(s[i]);
}

void snd_hal_push_rate(const short *s, int n, int srcrate) {
    if (!g_ok || n <= 0 || srcrate <= 0) return;
    if (srcrate == HAL_RATE) { snd_hal_push16k(s, n); return; }

    /* All integer: the D375's ARM1176 has no VFP, so doubles are soft-float. */
    int16_t out[1024];
    int oi = 0;

    if (srcrate > HAL_RATE) {
        /* Downsample by area averaging: each input sample carries HAL_RATE
         * "ticks", each output sample spans srcrate ticks and is the mean of
         * the input it covers (split samples count proportionally). A box
         * filter, so far less aliasing than point/linear sampling. State
         * carries across calls. */
        static int64_t acc;
        static int     fill;
        for (int i = 0; i < n; i++) {
            int w = HAL_RATE;
            while (fill + w >= srcrate) {
                int take = srcrate - fill;
                acc += (int64_t)s[i] * take;
                out[oi++] = (int16_t)(acc / srcrate);
                if (oi == (int)(sizeof out / sizeof out[0])) { snd_hal_push16k(out, oi); oi = 0; }
                acc = 0; fill = 0; w -= take;
            }
            acc += (int64_t)s[i] * w;
            fill += w;
        }
    } else {
        /* Upsample by linear interpolation, position in 16.16 input samples,
         * where index -1 == prev (last sample of the previous buffer), so
         * joins are click-free. */
        static int   pos;         /* next output's position within this buffer */
        static short prev;        /* src[-1] for this buffer */
        int step = (int)(((int64_t)srcrate << 16) / HAL_RATE);
        while (pos < (n << 16)) {
            int i = pos >> 16;                    /* floor; may be -1 */
            int f = pos & 0xffff;
            int a = (i < 0) ? prev : s[i];
            int b = (i + 1 < n) ? s[i + 1] : s[n - 1];
            out[oi++] = (int16_t)(a + (((b - a) * (f >> 1)) >> 15));  /* no int32 overflow */
            if (oi == (int)(sizeof out / sizeof out[0])) { snd_hal_push16k(out, oi); oi = 0; }
            pos += step;
        }
        pos -= n << 16;                           /* carry into the next buffer */
        prev = s[n - 1];
    }
    if (oi) snd_hal_push16k(out, oi);
}

int snd_hal_queued(void) { return g_ok ? (int)ring_used() : 0; }

int snd_hal_underruns(void) { return g_underruns; }

int snd_hal_ok(void) { return g_ok; }

void snd_hal_shutdown(void) {
    if (g_run) {
        g_run = 0;
        pthread_join(g_thread, NULL);
    }
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
    g_ok = 0;
}
