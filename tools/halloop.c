/* tools/halloop.c - audio path test for the snom D375 (see docs/sound.md).
 * Build: arm-linux-musleabi-gcc -march=armv4t -static -O2 -o halloop halloop.c -lpthread
 * Run on phone: insmod .../BROADCOM/amxr_user_hook.ko; CAP=1 NOREC=1 ./halloop feed.raw x <wfmt> 1
 * -> /tmp/cap0.raw, /tmp/cap1.raw (S16LE 16k mono). Analyze with tools/halloop_fir.py. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/ioctl.h>

struct iev { int sec, usec; unsigned short type, code; int value; };
static volatile int run = 1;
static int rcid, rfmt = 1;
static const char *outp;

static void key(int v) {
    int fd = open("/dev/input/event0", O_WRONLY); if (fd < 0) return;
    struct iev e; memset(&e, 0, sizeof e); e.type = 1; e.code = 17; e.value = v;
    write(fd, &e, sizeof e); memset(&e, 0, sizeof e); write(fd, &e, sizeof e); close(fd);
}

static void *rd(void *a) {
    (void)a;
    int fd = open("/dev/halaudio", O_RDWR), o = open(outp, O_WRONLY|O_CREAT|O_TRUNC, 0644);
    struct { int c, f; } r = { rcid, rfmt };
    short b[160]; long tot = 0; int rs = getenv("RDSZ") ? atoi(getenv("RDSZ")) : 320;
    while (run) {
        if (ioctl(fd, 0x80084137u, &r) < 0) { perror("rd ioctl"); break; }
        int n = read(fd, b, rs);
        if (n <= 0) { fprintf(stderr, "read %d %s\n", n, strerror(errno)); break; }
        write(o, b, n); tot += n;
    }
    fprintf(stderr, "recorded %ld bytes\n", tot);
    close(o); close(fd); return NULL;
}


/* amxr mic tap: halaudio.apmN -> amxruser.bindN, read 160B frames from /dev/amxruser */
static int capfd[2] = {-1, -1};
static void *cap(void *a) {
    (void)a;
    int u = open("/dev/amxruser", O_RDWR);
    if (u < 0) { perror("amxruser"); return NULL; }
    int o0 = open("/tmp/cap0.raw", O_WRONLY|O_CREAT|O_TRUNC, 0644);
    int o1 = open("/tmp/cap1.raw", O_WRONLY|O_CREAT|O_TRUNC, 0644);
    short b[80]; long n = 0;
    while (run) {
        if (ioctl(u, 0xc0044502u, 0) < 0) { perror("wait"); break; }
        struct { int port; void *buf; } d = { 0, b };
        if (ioctl(u, 0xc0044501u, &d) >= 0) write(o0, b, 160);
        d.port = 1;
        if (ioctl(u, 0xc0044501u, &d) >= 0) write(o1, b, 160);
        n++;
    }
    fprintf(stderr, "captured %ld frames\n", n);
    close(o0); close(o1); close(u); return NULL;
}
static void capwire(void) {
    int m = open("/dev/amxr", O_RDWR); if (m < 0) { perror("amxr"); return; }
    const char *src[2] = {"halaudio.apm0", "halaudio.apm1"}, *dst[2] = {"amxruser.bind0", "amxruser.bind1"};
    for (int i = 0; i < 2; i++) {
        struct { char name[32]; void *out; } q; void *ps = 0, *pd = 0;
        memset(&q, 0, sizeof q); strncpy(q.name, src[i], 31); q.out = &ps; int r1 = ioctl(m, 0x80244d30u, &q);
        memset(&q, 0, sizeof q); strncpy(q.name, dst[i], 31); q.out = &pd; int r2 = ioctl(m, 0x80244d30u, &q);
        struct { void *s, *d; int desc; } c = { ps, pd, 0x1010 };
        int r3 = ioctl(m, 0x800c4d35u, &c);
        fprintf(stderr, "wire %s->%s q=%d,%d conn=%d\n", src[i], dst[i], r1, r2, r3);
    }
    capfd[0] = m;
}

int main(int argc, char **argv) {
    if (argc < 5) return 1;
    outp = argv[2]; int wfmt = atoi(argv[3]); rcid = atoi(argv[4]);
    if (argc > 5) rfmt = atoi(argv[5]);
    int fd = open("/dev/halaudio", O_RDWR); if (fd < 0) { perror("open"); return 1; }
    struct { int a, b; } p;
    ioctl(fd, 0x4139, 1); ioctl(fd, 0x4135, 2);
    p.a = 0; p.b = 1; ioctl(fd, 0x80084141u, &p);
    p.a = 1; p.b = 16000; ioctl(fd, 0x8008413au, &p);
    if (!getenv("NOINJECT")) { key(1); usleep(60000); key(0); }
    sleep(2);
    if (!getenv("NOKILL"))
        system("touch /tmp/ssh_fast_update; kill -9 $(pidof lid) $(pidof media_daemon) 2>/dev/null");
    usleep(400000);
    pthread_t t, t2; int dorec = !getenv("NOREC"), docap = !!getenv("CAP");
    if (dorec) pthread_create(&t, NULL, rd, NULL);
    if (docap) { capwire(); pthread_create(&t2, NULL, cap, NULL); }
    int in = open(argv[1], O_RDONLY); short b[160]; int n;
    struct { int c, f; } w = { 1, wfmt };
    while ((n = read(in, b, sizeof b)) > 0) {
        ioctl(fd, 0x80084138u, &w);
        if (write(fd, b, n) < 0) { perror("write"); break; }
    }
    memset(b, 0, sizeof b);
    for (int i = 0; i < 50; i++) { ioctl(fd, 0x80084138u, &w); write(fd, b, sizeof b); }
    run = 0; if (dorec) pthread_join(t, NULL); if (docap) pthread_join(t2, NULL);
    return 0;
}
