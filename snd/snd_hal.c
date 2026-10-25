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
static int             g_ok = 0;
static volatile int    g_run = 0;
static pthread_t       g_thread;

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
    struct { int cid, fmt; } w = { HAL_CID, 0 };
    int16_t chunk[CHUNK];
    int dumpfd = -1;
    if (getenv("SND_DUMP"))
        dumpfd = open("/tmp/snd_dump.raw", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    while (g_run) {
        for (int i = 0; i < CHUNK; i++) {
            int16_t v;
            chunk[i] = ring_get(&v) ? v : 0;   /* underrun -> silence (keeps the amp/DMA alive) */
        }
        /* Blocking write: the codec DMA paces this at real time (16 kHz), which
         * is also our audio clock -- no extra timing needed. */
        ioctl(g_fd, HAL_WRITE, &w);
        if (write(g_fd, chunk, sizeof chunk) < 0 && errno != EINTR) {
            fprintf(stderr, "snd_hal: write: %s\n", strerror(errno));
            break;
        }
        if (dumpfd >= 0) (void)!write(dumpfd, chunk, sizeof chunk);
    }
    if (dumpfd >= 0) close(dumpfd);
    return NULL;
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
    if (!g_ok || n <= 0) return;
    if (srcrate == HAL_RATE) { snd_hal_push16k(s, n); return; }

    /* Linear resample to 16 kHz, carrying position + last input sample across
     * calls. Position is measured in input samples, where index -1 == prev
     * (the last sample of the previous buffer), so joins are click-free. */
    static double pos = 0.0;      /* next output's position within this buffer */
    static short  prev = 0;       /* src[-1] for this buffer */
    double step = (double)srcrate / (double)HAL_RATE;

    int16_t out[1024];
    int oi = 0;
    while (pos < n) {
        int i = (int)pos;                 /* floor; may be -1 */
        double f = pos - (double)i;
        short a = (i < 0)      ? prev : s[i];
        short b = (i + 1 < n)  ? s[i + 1] : s[n - 1];
        if (i + 1 < 0) b = prev;
        int v = (int)(a + (b - a) * f);
        if (v >  32767) v =  32767;
        if (v < -32768) v = -32768;
        out[oi++] = (int16_t)v;
        if (oi == (int)(sizeof out / sizeof out[0])) { snd_hal_push16k(out, oi); oi = 0; }
        pos += step;
    }
    if (oi) snd_hal_push16k(out, oi);

    pos -= n;                              /* carry into the next buffer */
    prev = s[n - 1];
}

int snd_hal_ok(void) { return g_ok; }

void snd_hal_shutdown(void) {
    if (g_run) {
        g_run = 0;
        pthread_join(g_thread, NULL);
    }
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
    g_ok = 0;
}
