/* tools/rtcap.c - digital capture of what the phone plays (ringtone tests), snom D375.
 * See docs/ringtones.md and docs/sound.md (amxr / amxr_user_hook ABI).
 *
 * Fans the given amxr SOURCE ports out to amxruser.bind0/bind1 (an extra edge next to the
 * stock ept.bindN -> halaudio.apmN routes, which stay untouched), records SECONDS of
 * 160-byte frames (5 ms, 80 samples S16LE @16 kHz mono) per port, then removes only the
 * edges it added. lid / media_daemon keep running; nothing is played by this tool.
 *
 * Needs /dev/amxruser: insmod /lib/modules/2.6.27.47/BROADCOM/amxr_user_hook.ko (major 236,
 * mknod /dev/amxruser c 236 0 if the node is missing).
 *
 * Usage: rtcap SECONDS [SRC0 [SRC1]]   (default SRC0=ept.bind0 SRC1=ept.bind1)
 *        -> /tmp/rtcap0.raw, /tmp/rtcap1.raw
 * Build: tools/build-rtcap.sh (static musl, armv6, no FPU use). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

struct q { char name[32]; void *out; };
struct conn { void *s, *d; int desc; };
struct disc { void *s, *d; };

static void *port(int m, const char *n) {
    struct q q; void *p = 0;
    memset(&q, 0, sizeof q); strncpy(q.name, n, 31); q.out = &p;
    if (ioctl(m, 0x80244d30u, &q) < 0) { fprintf(stderr, "no amxr port %s\n", n); return 0; }
    return p;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: rtcap SECONDS [SRC0 [SRC1]]\n"); return 2; }
    int secs = atoi(argv[1]);
    if (secs < 1 || secs > 120) { fprintf(stderr, "SECONDS must be 1..120\n"); return 2; }
    const char *src[2] = { argc > 2 ? argv[2] : "ept.bind0", argc > 3 ? argv[3] : "ept.bind1" };
    const char *dst[2] = { "amxruser.bind0", "amxruser.bind1" };
    int m = open("/dev/amxr", O_RDWR);
    if (m < 0) { perror("/dev/amxr"); return 1; }
    int u = open("/dev/amxruser", O_RDWR);
    if (u < 0) { perror("/dev/amxruser (insmod amxr_user_hook.ko?)"); return 1; }
    void *ps[2], *pd[2]; int ok[2] = {0, 0};
    for (int i = 0; i < 2; i++) {
        ps[i] = port(m, src[i]); pd[i] = port(m, dst[i]);
        if (!ps[i] || !pd[i]) continue;
        struct conn c = { ps[i], pd[i], 0x1010 };   /* mono -> mono, as media_daemon uses */
        int r = ioctl(m, 0x800c4d35u, &c);
        fprintf(stderr, "wire %s -> %s: %d\n", src[i], dst[i], r);
        ok[i] = r >= 0;
    }
    int o[2] = { open("/tmp/rtcap0.raw", O_WRONLY | O_CREAT | O_TRUNC, 0644),
                 open("/tmp/rtcap1.raw", O_WRONLY | O_CREAT | O_TRUNC, 0644) };
    short b[80]; long frames = (long)secs * 200, n;
    for (n = 0; n < frames; n++) {
        if (ioctl(u, 0xc0044502u, 0) < 0) { perror("frame wait"); break; }
        for (int i = 0; i < 2; i++) {
            struct { int port; void *buf; } d = { i, b };
            if (ok[i] && ioctl(u, 0xc0044501u, &d) >= 0) write(o[i], b, 160);
        }
    }
    for (int i = 0; i < 2; i++) {
        if (!ok[i]) continue;
        struct disc d = { ps[i], pd[i] };
        fprintf(stderr, "unwire %s: %d\n", src[i], ioctl(m, 0x4d36u, &d));
    }
    fprintf(stderr, "captured %ld frames\n", n);
    close(o[0]); close(o[1]); close(u); close(m);
    return 0;
}
