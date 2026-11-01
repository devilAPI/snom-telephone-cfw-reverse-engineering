/*
 * Lets a 24 bpp phone app run on a 32 bpp framebuffer. See docs/backport.md.
 *
 * lcsD815 draws 24-bit pixels and maps /dev/fb0 itself. This library, loaded with
 * LD_PRELOAD, gives it a 24 bpp shadow of the screen and copies changed lines to
 * the real framebuffer from a background thread.
 *
 * Build: tools/build-fb24shim.sh
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "backport/keymap.h"

#define SRC_BYTES       3
#define EV_KEY_TYPE     1
#define KEY_SETTINGS_375 65     /* the D815 has no such key */
#define FRAME_NS        50000000    /* 20 Hz */

static int fb_fd = -1, kbd_fd = -1;
static uint8_t *shadow, *copy;
static uint32_t *real;
static unsigned width, height, vheight, src_stride, dst_stride;
static volatile unsigned yoffset;
static size_t real_len, shadow_len;

static int (*real_open)(const char *, int, ...);
static int (*real_ioctl)(int, unsigned long, ...);
static ssize_t (*real_read)(int, void *, size_t);
static void *(*real_mmap)(void *, size_t, int, int, int, off_t);

static void resolve(void)
{
    if (!real_open) {
        real_open = dlsym(RTLD_NEXT, "open");
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
        real_read = dlsym(RTLD_NEXT, "read");
        real_mmap = dlsym(RTLD_NEXT, "mmap");
    }
}

static void convert_line(const uint8_t *src, uint32_t *dst)
{
    unsigned x;

    for (x = 0; x < width; x++, src += SRC_BYTES) {
        dst[x] = src[2] | (src[1] << 8) | ((uint32_t)src[0] << 16);
    }
}

/*
 * The app writes brightness 0 to 64 to the D815's backlight, from a 32-entry
 * table. It goes to a file, and sync_backlight() scales it for the D375's 0 to 32.
 */
#define D815_BACKLIGHT "/sys/class/backlight/dvf9a-bl/brightness"
#define D375_BACKLIGHT "/sys/class/backlight/lcdfb-bl/brightness"
#define BACKLIGHT_FILE "/tmp/backlight"
#define D815_BL_MAX 64
#define D375_BL_MAX 32

static void sync_backlight(void)
{
    static int last = -1;
    char text[16];
    ssize_t n;
    int fd, value;

    fd = real_open(BACKLIGHT_FILE, O_RDONLY, 0);
    if (fd < 0) {
        return;
    }
    n = real_read(fd, text, sizeof(text) - 1);
    close(fd);
    if (n <= 0) {
        return;
    }
    text[n] = 0;
    value = atoi(text);
    if (value == last) {
        return;
    }
    last = value;
    if (value > D815_BL_MAX) {
        value = D815_BL_MAX;
    }
    fd = real_open(D375_BACKLIGHT, O_WRONLY, 0);
    if (fd >= 0) {
        n = snprintf(text, sizeof(text), "%d\n", value * D375_BL_MAX / D815_BL_MAX);
        if (write(fd, text, n) < 0) {
            /* nothing useful to do from the copier */
        }
        close(fd);
    }
}

/*
 * lcsD815 keeps "SIP stack enabled" in byte 0 of the object that *0x10eac80
 * points to. Nothing sets it on a D375 and the phone will not register, so this
 * sets it. The address fits only this build of the app. See docs/backport.md.
 */
static void enable_sip_stack(void)
{
    static int is_lcs = -1;
    char exe[64];
    ssize_t n;

    if (is_lcs < 0) {
        n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
        exe[n > 0 ? n : 0] = 0;
        is_lcs = strstr(exe, "lcsD815") != NULL;
    }
    if (is_lcs) {
        char **stack = (char **)0x10eac80;
        static unsigned ticks;

        if (++ticks % 5 == 0) {     /* four times a second */
            sync_backlight();
        }

        if (*stack && !**stack) {
            **stack = 1;
        }
    }
}

static void *copier(void *unused)
{
    static const struct timespec frame = { 0, FRAME_NS };
    unsigned y;

    (void)unused;
    for (;;) {
        unsigned top = yoffset;

        for (y = 0; y < height; y++) {
            size_t off = (size_t)(top + y) * src_stride;

            if (memcmp(shadow + off, copy + off, width * SRC_BYTES)) {
                memcpy(copy + off, shadow + off, width * SRC_BYTES);
                convert_line(shadow + off, real + (size_t)y * dst_stride / 4);
            }
        }
        enable_sip_stack();
        nanosleep(&frame, NULL);
    }
    return NULL;
}

/*
 * The D815 app reads its Ethernet switch from sysfs and keeps the SIP stack off
 * while that fails. The D375 has no such switch. The link state uses the same
 * "%d\n" format as eth0's carrier, so the app sees the real cable state. The
 * other attributes are files that run-d8.sh creates.
 */
#define GSW_DIR "/sys/devices/gsw120.9/gsw120/"

static const char *redirect(const char *path, char *buf, size_t len)
{
    if (path && !strcmp(path, D815_BACKLIGHT))
        return BACKLIGHT_FILE;
    if (!path || strncmp(path, GSW_DIR, sizeof(GSW_DIR) - 1))
        return path;
    path += sizeof(GSW_DIR) - 1;
    if (!strcmp(path, "net_port_link_status"))
        return "/sys/class/net/eth0/carrier";
    snprintf(buf, len, "/tmp/gsw120/%s", path);
    return buf;
}

FILE *fopen(const char *path, const char *mode)
{
    static FILE *(*real)(const char *, const char *);
    char buf[80];

    if (!real)
        real = dlsym(RTLD_NEXT, "fopen");
    return real(redirect(path, buf, sizeof(buf)), mode);
}

FILE *fopen64(const char *path, const char *mode)
{
    static FILE *(*real)(const char *, const char *);
    char buf[80];

    if (!real)
        real = dlsym(RTLD_NEXT, "fopen64");
    return real(redirect(path, buf, sizeof(buf)), mode);
}

/* The app checks that the backlight exists before it writes to it. */
int __xstat(int ver, const char *path, struct stat *st)
{
    static int (*real)(int, const char *, struct stat *);
    char buf[80];

    if (!real)
        real = dlsym(RTLD_NEXT, "__xstat");
    return real(ver, redirect(path, buf, sizeof(buf)), st);
}

int open(const char *path, int flags, ...)
{
    va_list ap;
    int mode, fd;
    char buf[80];

    resolve();
    va_start(ap, flags);
    mode = va_arg(ap, int);
    va_end(ap);
    fd = real_open(redirect(path, buf, sizeof(buf)), flags, mode);
    if (fd >= 0 && !strcmp(path, "/dev/fb0")) {
        fb_fd = fd;
    } else if (fd >= 0 && !strcmp(path, "/dev/input/event0")) {
        kbd_fd = fd;
    }
    return fd;
}

int open64(const char *path, int flags, ...)
{
    va_list ap;
    int mode;

    va_start(ap, flags);
    mode = va_arg(ap, int);
    va_end(ap);
    return open(path, flags | O_LARGEFILE, mode);
}

/*
 * The D375's hook switch reads as held down while the handset rests on the
 * cradle. The D815 app expects the opposite, in events and in EVIOCGKEY.
 */
#define KEY_HOOK 102
#define EVIOCGKEY_NR 0x18

/* Input events are 16 bytes: a timeval, then type, code and value. */
struct key_event {
    uint32_t sec, usec;
    uint16_t type, code;
    int32_t value;
};

static void press_settings(void)
{
    if (fork() == 0) {
        static char *const argv[] = {
            "/bin/phone-key", "SETTINGS", NULL
        };

        setenv("LD_PRELOAD", "", 1);
        execv(argv[0], argv);
        _exit(1);
    }
}

/* D375 keys with no D815 code, for working out what is still missing. */
static void log_unmapped(unsigned code, int value)
{
    if (value == 1) {
        FILE *f = fopen("/tmp/unmapped-keys", "a");

        if (f) {
            fprintf(f, "%u\n", code);
            fclose(f);
        }
    }
}

/* lid reads D375 key codes here and gets the D815 code of the same key. */
ssize_t read(int fd, void *buf, size_t len)
{
    ssize_t ret;
    size_t i;
    unsigned original;

    resolve();
    ret = real_read(fd, buf, len);
    if (fd != kbd_fd || ret <= 0) {
        return ret;
    }
    for (i = 0; i + sizeof(struct key_event) <= (size_t)ret;
         i += sizeof(struct key_event)) {
        struct key_event *e = (struct key_event *)((char *)buf + i);

        if (e->type == EV_KEY_TYPE) {
            if (e->code == KEY_SETTINGS_375 && e->value == 1) {
                press_settings();
            }
            if (e->code == KEY_HOOK && e->value <= 1) {
                e->value = !e->value;
            }
            original = e->code;
            e->code = e->code < 256 ? key_map[e->code] : 0;
            if (!e->code) {
                log_unmapped(original, e->value);
                e->type = 0;    /* no equivalent: harmless sync event */
            }
        }
    }
    return ret;
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    void *arg;
    int ret;

    resolve();
    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);
    if (fd == kbd_fd && ((req >> 8) & 0xff) == 'E' && (req & 0xff) == EVIOCGKEY_NR) {
        ret = real_ioctl(fd, req, arg);
        if (ret >= 0 && ((req >> 16) & 0x3fff) > KEY_HOOK / 8) {
            ((unsigned char *)arg)[KEY_HOOK / 8] ^= 1 << (KEY_HOOK % 8);
        }
        return ret;
    }
    /*
     * Panning selects a page of the shadow. The real framebuffer stays on its
     * first page, which is where the copier draws, and keeps its own mode.
     */
    if (fd == fb_fd && (req == FBIOPAN_DISPLAY || req == FBIOPUT_VSCREENINFO)) {
        yoffset = ((struct fb_var_screeninfo *)arg)->yoffset;
        return 0;
    }
    ret = real_ioctl(fd, req, arg);
    if (fd != fb_fd || ret < 0) {
        return ret;
    }
    if (req == FBIOGET_VSCREENINFO) {
        struct fb_var_screeninfo *v = arg;

        width = v->xres;
        height = v->yres;
        vheight = v->yres_virtual;
        v->bits_per_pixel = SRC_BYTES * 8;
        v->red.offset = 0;
        v->green.offset = 8;
        v->blue.offset = 16;
        v->transp.length = 0;
        v->transp.offset = 0;
    } else if (req == FBIOGET_FSCREENINFO) {
        struct fb_fix_screeninfo *f = arg;

        dst_stride = f->line_length;
        real_len = f->smem_len;
        f->line_length = width * SRC_BYTES;
        f->smem_len = (uint32_t)(width * SRC_BYTES * vheight);
    }
    return ret;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    pthread_t t;
    struct fb_var_screeninfo v;
    struct fb_fix_screeninfo f;

    resolve();
    if (fd != fb_fd || fd < 0) {
        return real_mmap(addr, len, prot, flags, fd, off);
    }
    if (real) {
        return shadow;
    }
    /* The app may map before asking, so ask here as well. */
    ioctl(fd, FBIOGET_VSCREENINFO, &v);
    ioctl(fd, FBIOGET_FSCREENINFO, &f);
    /* Screen height is enough only without panning; keep the whole virtual area. */
    src_stride = width * SRC_BYTES;
    shadow_len = (size_t)src_stride * vheight;
    if (len > shadow_len) {
        shadow_len = len;
    }
    real = real_mmap(NULL, real_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    shadow = real_mmap(NULL, shadow_len, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    copy = real_mmap(NULL, shadow_len, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (real == MAP_FAILED || shadow == MAP_FAILED || copy == MAP_FAILED) {
        return MAP_FAILED;
    }
    memset(copy, 0xff, shadow_len);
    pthread_create(&t, NULL, copier, NULL);
    return shadow;
}
