/* gpSP (libretro core, ARM dynarec) frontend for the snom D375:
 *   video : /dev/fb0 (480x272, 32bpp); GBA 240x160 scaled x1.7 to 408x272, centered
 *   input : /dev/input/event0 keypad (freed by snd_hal_init killing lid+media_daemon)
 *   sound : core audio (32768 Hz stereo) -> mono -> snd_hal (16 kHz loudspeaker);
 *           the codec clock paces the game, and gpSP's auto-frameskip watches
 *           the same queue
 * The core is linked statically (gpsp_libretro.a); this file is the whole
 * "RetroArch". ROM path is argv[1]; red hangup key quits. See docs/gba.md.
 */
#include "libretro.h"
#include "snd_hal.h"   /* copied next to this file at build time */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#define SYS_DIR   "/snom/cfw/gba"   /* optional gba_bios.bin; built-in BIOS otherwise */
#define SAVE_DIR  "/tmp"

/* snom D375 keypad scancodes (reverse-engineered on the device) */
#define PK_UP     84
#define PK_DOWN   67
#define PK_LEFT   101
#define PK_RIGHT  50
#define PK_OK     97    /* Start  */
#define PK_FIRE   120   /* A      */
#define PK_USE    116   /* B      */
#define PK_CANCEL 115   /* Select */
#define PK_HANGUP 114   /* quit   */

/* Audio-clocked pacing, as in the NES port: keep ~SND_LEAD samples queued. */
#define SND_LEAD  1600  /* 100 ms at 16 kHz */

#define GBA_W 240
#define GBA_H 160

static int16_t g_pad;          /* bitmask over RETRO_DEVICE_ID_JOYPAD_* */
static int     g_stats;        /* GBA_STATS=1: log fps/queue/underruns */
static int     g_srate = 32768;

/* ---- framebuffer ---- */
static uint8_t  *fbPtr;
static unsigned  fbStride, fbBpp, fbXres, fbYres;
static unsigned  outW, outH, offX, offY;
static uint16_t  xmap[480];    /* output column -> source column */
static uint16_t  ymap[272];    /* output row    -> source row    */
static uint32_t *lut565;       /* RGB565 -> fb pixel */

/* ---- input ---- */
static int inFd = -1;
struct ev16 { uint32_t sec, usec; uint16_t type, code; int32_t value; };

static void quit(void) {
    if (fbPtr) memset(fbPtr, 0, (long)fbStride * fbYres);
    exit(0);
}

static void mapKey(int code, int down) {
    int id;
    switch (code) {
        case PK_UP:     id = RETRO_DEVICE_ID_JOYPAD_UP;     break;
        case PK_DOWN:   id = RETRO_DEVICE_ID_JOYPAD_DOWN;   break;
        case PK_LEFT:   id = RETRO_DEVICE_ID_JOYPAD_LEFT;   break;
        case PK_RIGHT:  id = RETRO_DEVICE_ID_JOYPAD_RIGHT;  break;
        case PK_FIRE:   id = RETRO_DEVICE_ID_JOYPAD_A;      break;
        case PK_USE:    id = RETRO_DEVICE_ID_JOYPAD_B;      break;
        case PK_OK:     id = RETRO_DEVICE_ID_JOYPAD_START;  break;
        case PK_CANCEL: id = RETRO_DEVICE_ID_JOYPAD_SELECT; break;
        case PK_HANGUP: if (down) quit(); return;
        default:
            if (g_stats && down) fprintf(stderr, "gba: unmapped key %d\n", code);
            return;
    }
    if (down) g_pad |= 1 << id; else g_pad &= ~(1 << id);
}

static void input_poll(void) {
    struct ev16 ev;
    struct pollfd pfd; pfd.fd = inFd; pfd.events = POLLIN; pfd.revents = 0;
    while (inFd >= 0 && poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN)) {
        if (read(inFd, &ev, sizeof(ev)) != (int)sizeof(ev)) break;
        if (ev.type == 1 && ev.value != 2) mapKey(ev.code, ev.value);
    }
}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    (void)index;
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return g_pad;
    return id < 16 ? (g_pad >> id) & 1 : 0;
}

static void fbInit(void) {
    struct fb_var_screeninfo v; struct fb_fix_screeninfo f;
    int fd = open("/dev/fb0", O_RDWR);
    if (fd < 0) { perror("open fb0"); exit(1); }
    ioctl(fd, FBIOGET_VSCREENINFO, &v);
    ioctl(fd, FBIOGET_FSCREENINFO, &f);
    fbBpp = v.bits_per_pixel / 8;
    fbXres = v.xres; fbYres = v.yres;
    fbStride = f.line_length ? f.line_length : v.xres * fbBpp;
    int swapRB = (v.red.offset == 0 && v.blue.offset == 16);

    /* Largest 3:2 box that fits: on 480x272 that is 408x272 (x1.7). */
    outH = fbYres;
    outW = outH * GBA_W / GBA_H;
    if (outW > fbXres) { outW = fbXres; outH = outW * GBA_H / GBA_W; }
    if (outW > 480) outW = 480;
    if (outH > 272) outH = 272;
    offX = (fbXres - outW) / 2;
    offY = (fbYres - outH) / 2;
    for (unsigned x = 0; x < outW; x++) xmap[x] = x * GBA_W / outW;
    for (unsigned y = 0; y < outH; y++) ymap[y] = y * GBA_H / outH;

    lut565 = (uint32_t *)malloc(65536 * sizeof *lut565);
    for (unsigned c = 0; c < 65536; c++) {
        unsigned r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f;
        r = (r << 3) | (r >> 2); g = (g << 2) | (g >> 4); b = (b << 3) | (b >> 2);
        lut565[c] = fbBpp == 4 ? (swapRB ? (b << 16) | (g << 8) | r : (r << 16) | (g << 8) | b)
                               : (uint32_t)c;
    }

    fbPtr = (uint8_t *)mmap(NULL, (long)fbStride * fbYres, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (fbPtr == MAP_FAILED) { perror("mmap fb"); exit(1); }
    memset(fbPtr, 0, (long)fbStride * fbYres);
    inFd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
    if (inFd >= 0) ioctl(inFd, _IOW('E', 0x90, int), 1); /* EVIOCGRAB */
}

static void video_refresh(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!data || w != GBA_W || h != GBA_H) return;   /* NULL = frame skipped (dupe) */
    const uint8_t *src = (const uint8_t *)data;
    int lastsy = -1;
    for (unsigned y = 0; y < outH; y++) {
        uint8_t *d = fbPtr + (long)(offY + y) * fbStride + (long)offX * fbBpp;
        int sy = ymap[y];
        if (sy == lastsy) {                       /* repeated row: copy the one above */
            memcpy(d, d - fbStride, (size_t)outW * fbBpp);
            continue;
        }
        lastsy = sy;
        const uint16_t *s = (const uint16_t *)(src + (size_t)sy * pitch);
        if (fbBpp == 4) {
            uint32_t *dp = (uint32_t *)d;
            for (unsigned x = 0; x < outW; x++) dp[x] = lut565[s[xmap[x]]];
        } else {
            uint16_t *dp = (uint16_t *)d;
            for (unsigned x = 0; x < outW; x++) dp[x] = s[xmap[x]];
        }
    }
}

/* ---- audio ---- */
static size_t audio_batch(const int16_t *data, size_t frames) {
    static int16_t mono[2048];
    size_t done = 0;
    while (done < frames) {
        size_t n = frames - done;
        if (n > 2048) n = 2048;
        for (size_t i = 0; i < n; i++)
            mono[i] = (int16_t)((data[2 * (done + i)] + data[2 * (done + i) + 1]) >> 1);
        snd_hal_push_rate(mono, (int)n, g_srate);
        done += n;
    }
    return frames;
}

static void audio_sample(int16_t l, int16_t r) {
    int16_t s[2] = { l, r };
    audio_batch(s, 1);
}

/* ---- libretro environment ---- */
static retro_audio_buffer_status_callback_t g_buf_status;

static const char *core_option(const char *key) {
    if (!strcmp(key, "gpsp_drc"))          return "enabled";
    if (!strcmp(key, "gpsp_bios"))         return "auto";        /* SYS_DIR/gba_bios.bin, else built-in */
    if (!strcmp(key, "gpsp_boot_mode"))    return "game";
    if (!strcmp(key, "gpsp_frameskip"))    return "auto";
    if (!strcmp(key, "gpsp_sound_rate"))   return "32768";
    if (!strcmp(key, "gpsp_sprlim"))       return "disabled";
    if (!strcmp(key, "gpsp_frame_mixing")) return "disabled";
    if (!strcmp(key, "gpsp_color_correction")) return "disabled";
    return NULL;                                                 /* core default */
}

static void core_log(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_WARN && !g_stats) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static bool environment(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *(const char **)data = SYS_DIR;  return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *(const char **)data = SAVE_DIR; return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            return *(const enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_RGB565;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            struct retro_variable *v = (struct retro_variable *)data;
            v->value = core_option(v->key);
            return v->value != NULL;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            *(bool *)data = false; return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            ((struct retro_log_callback *)data)->log = core_log; return true;
        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
            return true;
        case RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK: {
            const struct retro_audio_buffer_status_callback *cb =
                (const struct retro_audio_buffer_status_callback *)data;
            g_buf_status = cb ? cb->callback : NULL;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
            const struct retro_system_av_info *av = (const struct retro_system_av_info *)data;
            g_srate = (int)av->timing.sample_rate;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_MESSAGE:
            fprintf(stderr, "gba: %s\n", ((const struct retro_message *)data)->msg);
            return true;
        default:
            return false;
    }
}

/* ---- pacing ---- */
static void pace(void) {
    if (snd_hal_ok()) {
        int q = snd_hal_queued();
        /* gpSP's auto-frameskip: occupancy is % of our target lead. */
        if (g_buf_status) {
            int occ = q * 100 / SND_LEAD;
            g_buf_status(true, occ > 100 ? 100 : occ, q < SND_LEAD / 4);
        }
        if (q > SND_LEAD) usleep((q - SND_LEAD) * 125 / 2);   /* 62.5 us/sample */
        return;
    }
    static struct timeval last;
    struct timeval now; gettimeofday(&now, NULL);
    long us = (now.tv_sec - last.tv_sec) * 1000000L + (now.tv_usec - last.tv_usec);
    long target = 16743;                                       /* GBA: 59.73 Hz */
    if (us > 0 && us < target) usleep(target - us);
    gettimeofday(&last, NULL);
}

static void logStats(void) {
    static int frames;
    static struct timeval t0;
    struct timeval now;
    if (frames++ == 0) { gettimeofday(&t0, NULL); return; }
    if (frames % 300) return;
    gettimeofday(&now, NULL);
    long ms = (now.tv_sec - t0.tv_sec) * 1000L + (now.tv_usec - t0.tv_usec) / 1000;
    fprintf(stderr, "gba: %ld.%ld fps, queued %d, underruns %d\n",
            300000L / ms, (3000000L / ms) % 10, snd_hal_queued(), snd_hal_underruns());
    t0 = now;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s game.gba\n", argv[0]); return 1; }
    g_stats = getenv("GBA_STATS") != NULL;

    /* Arm audio + hands-free, then take over (kill lid+media_daemon) while the
     * daemon is still alive. Must precede fbInit()/event0. */
    snd_hal_init();
    atexit(snd_hal_shutdown);
    fbInit();

    retro_set_environment(environment);
    retro_set_video_refresh(video_refresh);
    retro_set_audio_sample(audio_sample);
    retro_set_audio_sample_batch(audio_batch);
    retro_set_input_poll(input_poll);
    retro_set_input_state(input_state);
    retro_init();

    struct retro_game_info game;
    memset(&game, 0, sizeof game);
    game.path = argv[1];
    if (!retro_load_game(&game)) { fprintf(stderr, "gba: failed to load %s\n", argv[1]); return 1; }

    struct retro_system_av_info av;
    retro_get_system_av_info(&av);
    g_srate = (int)av.timing.sample_rate;
    fprintf(stderr, "gba: loaded %s, audio %d Hz\n", argv[1], g_srate);

    for (;;) {
        pace();
        retro_run();
        if (g_stats) logStats();
    }
}
