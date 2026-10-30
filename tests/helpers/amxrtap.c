/* amxrtap - test helper: tap one amxr source port (e.g. ept.bind1 = what the
 * phone's DSP sends to the loudspeaker) into /dev/amxruser and dump N frames
 * (S16LE, 16 kHz mono, 80 samples each) to a file. Used by tests/restore.sh to
 * prove that the restarted media_daemon produces audio again, without having
 * to listen. Needs amxr_user_hook.ko loaded (char dev /dev/amxruser).
 *
 *   amxrtap SRCPORT FRAMES OUTFILE      e.g. amxrtap ept.bind1 400 /tmp/tap.raw
 *
 * Wires SRCPORT -> amxruser.bind0, captures, then disconnects again.
 * ioctls as documented in docs/sound.md (query 'M',48; connect 'M',53);
 * disconnect is 'M',54 (next entry in amxr's API table after amxrConnect).
 *
 * Freestanding (raw ARM EABI syscalls, no libc), so it builds with plain clang:
 *   clang --target=armv6-none-eabi -march=armv6 -marm -mfloat-abi=soft -O2 \
 *     -ffreestanding -fno-builtin -nostdlib -static -fuse-ld=lld \
 *     -Wl,-e,_start -o tests/helpers/amxrtap tests/helpers/amxrtap.c
 */
typedef unsigned long ul;

static long sys3(long n, long a, long b, long c) {
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    register long r7 __asm__("r7") = n;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory");
    return r0;
}
#define SYS_exit  1
#define SYS_write 4
#define SYS_open  5
#define SYS_close 6
#define SYS_ioctl 54

static void out(const char *s) { long n = 0; while (s[n]) n++; sys3(SYS_write, 2, (long)s, n); }
static void die(const char *s) { out("amxrtap: "); out(s); out("\n"); sys3(SYS_exit, 1, 0, 0); }

static void scpy(char *d, const char *s, int max) { int i = 0; for (; i < max - 1 && s[i]; i++) d[i] = s[i]; for (; i < max; i++) d[i] = 0; }

static int atoi_(const char *s) { int v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }

struct q { char name[32]; void **out; };
struct c { void *src, *dst; int desc; };
struct d { int port; void *buf; };

static int run(int argc, char **argv) {
    if (argc < 4) die("usage: amxrtap SRCPORT FRAMES OUTFILE");
    int frames = atoi_(argv[2]);
    int m = sys3(SYS_open, (long)"/dev/amxr", 2, 0);
    if (m < 0) die("open /dev/amxr");
    int u = sys3(SYS_open, (long)"/dev/amxruser", 2, 0);
    if (u < 0) die("open /dev/amxruser (insmod amxr_user_hook.ko)");
    int o = sys3(SYS_open, (long)argv[3], 01 | 0100 | 01000, 0644);
    if (o < 0) die("open outfile");

    void *ps = 0, *pd = 0;
    struct q q;
    scpy(q.name, argv[1], 32); q.out = &ps;
    if (sys3(SYS_ioctl, m, 0x80244d30, (long)&q) < 0 || !ps) die("no such source port");
    scpy(q.name, "amxruser.bind0", 32); q.out = &pd;
    if (sys3(SYS_ioctl, m, 0x80244d30, (long)&q) < 0 || !pd) die("no amxruser.bind0 port");
    struct c c = { ps, pd, 0x1010 };
    if (sys3(SYS_ioctl, m, 0x800c4d35, (long)&c) < 0) die("connect failed");

    short buf[80];
    int got = 0;
    for (int i = 0; i < frames; i++) {
        if (sys3(SYS_ioctl, u, 0xc0044502, 0) < 0) break;     /* wait for frame sync */
        struct d d = { 0, buf };
        if (sys3(SYS_ioctl, u, 0xc0044501, (long)&d) >= 0) { sys3(SYS_write, o, (long)buf, sizeof buf); got++; }
    }
    sys3(SYS_ioctl, m, 0x800c4d36, (long)&c);                  /* disconnect */
    sys3(SYS_close, o, 0, 0); sys3(SYS_close, u, 0, 0); sys3(SYS_close, m, 0, 0);
    if (!got) die("captured no frames");
    return 0;
}

__attribute__((naked, noreturn)) void _start(void) {
    __asm__ volatile(
        "ldr r0, [sp]\n"        /* argc */
        "add r1, sp, #4\n"      /* argv */
        "bl  start_c\n");
}
__attribute__((used, noreturn)) void start_c(int argc, char **argv) {
    sys3(SYS_exit, run(argc, argv), 0, 0);
    __builtin_unreachable();
}
