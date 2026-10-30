/* snom_retro - a minimal libretro frontend for the snom D375 (one core linked
 * statically per binary; this file is the whole "RetroArch"):
 *
 *   video : /dev/fb0 (480x272, 32bpp). The core's frame (RGB565, 0RGB1555 or
 *           XRGB8888) is scaled to the largest box with the core's aspect ratio
 *           that fits (GBA 240x160 -> 408x272, GB 160x144 -> 302x272), centred.
 *   input : /dev/input/event0 keypad (freed by snd_hal_init killing
 *           lid + media_daemon; not grabbed, see fbInit). Red hangup quits.
 *   sound : core audio (stereo, any rate) -> mono -> snd_hal (16 kHz codec).
 *           The codec clock paces the game: we keep ~100 ms queued and sleep
 *           off any excess. When the queue runs low we skip our blit (and gpSP
 *           frameskips via the audio buffer status callback) to catch up.
 *
 * Built once per core by tools/build-retro.sh with -DCORE_GPSP or
 * -DCORE_GAMBATTE (or -DCORE_GEARBOY, measured but not shipped).
 * Usage: <engine> ROMFILE. Env: <TAG>_STATS=1 (GBA_STATS / GB_STATS: fps,
 * queue, underruns and unmapped scancodes on stderr), SND_VOL=<0..100>,
 * SND_DUMP=1 (see snd_hal.h).
 * Exit codes: 0 quit by the user, 1 usage, 2 the core refused the ROM (before
 * the screen takeover, so the phone UI is untouched).
 * See docs/gba.md and docs/gb.md.
 */
#include "libretro.h"
#include "snd_hal.h"   /* copied next to this file at build time */
#include "snom_save.h"  /* battery save helpers (snd/) */
#include <signal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

/* ---------------------------------------------------------------- per core */
struct opt { const char *key, *value; };

#if defined(CORE_GPSP)
#define TAG       "gba"
#define STATS_ENV "GBA_STATS"
#define SYS_DIR   "/snom/cfw/gba"   /* optional gba_bios.bin; built-in BIOS otherwise */
static const struct opt core_opts[] = {
    { "gpsp_drc",              "enabled"  },   /* ARM dynarec: the reason gpSP is fast here */
    { "gpsp_bios",             "auto"     },   /* SYS_DIR/gba_bios.bin if present, else built-in */
    { "gpsp_boot_mode",        "game"     },   /* skip the BIOS intro */
    { "gpsp_frameskip",        "auto"     },   /* driven by our audio buffer status callback */
    { "gpsp_sound_rate",       "32768"    },
    { "gpsp_sprlim",           "disabled" },
    { "gpsp_frame_mixing",     "disabled" },
    { "gpsp_color_correction", "disabled" },
    { NULL, NULL }
};
#elif defined(CORE_GAMBATTE)
#define TAG       "gb"
#define STATS_ENV "GB_STATS"
#define SYS_DIR   "/snom/cfw/gb"    /* optional gb_bios.bin / gbc_bios.bin */
static const struct opt core_opts[] = {
    { "gambatte_gb_hwmode",            "Auto"     },  /* GBC games in colour, DMG games as DMG */
    { "gambatte_gb_colorization",      "auto"     },  /* DMG games: built-in palettes */
    { "gambatte_gb_internal_palette",  "GB - DMG" },
    { "gambatte_gbc_color_correction", "disabled" },  /* saves a per-pixel pass */
    { "gambatte_mix_frames",           "disabled" },  /* ditto (LCD ghosting) */
    { "gambatte_dark_filter_level",    "0"        },
    { "gambatte_audio_resampler",      "cc"       },  /* cheaper than sinc */
    { "gambatte_gb_bootloader",        "disabled" },
    { "gambatte_up_down_allowed",      "disabled" },
    { "gambatte_gb_link_mode",         "Not Connected" },
    { NULL, NULL }
};
#elif defined(CORE_GEARBOY)
#define TAG       "gb"
#define STATS_ENV "GB_STATS"
#define SYS_DIR   "/snom/cfw/gb"
static const struct opt core_opts[] = {
    { "gearboy_model",            "Auto"     },
    { "gearboy_color_correction", "Disabled" },
    { "gearboy_sgb",              "Disabled" },
    { "gearboy_bootrom_dmg",      "Disabled" },
    { "gearboy_bootrom_gbc",      "Disabled" },
    { NULL, NULL }
};
#else
#error "define CORE_GPSP, CORE_GAMBATTE or CORE_GEARBOY"
#endif

#define SAVE_DIR  "/tmp"

/* ---------------------------------------------------------------- keys */
/* snom D375 keypad scancodes (evdev). Nav/OK/Fire/Use/Cancel/Hangup were
 * captured on the device for Doom; the digit codes come from the keyinject
 * table (Task J, docs/remote.md). */
#define PK_UP     84
#define PK_DOWN   67
#define PK_LEFT   101
#define PK_RIGHT  50
#define PK_OK     97    /* Start  */
#define PK_FIRE   120   /* A      */
#define PK_USE    116   /* B      */
#define PK_CANCEL 115   /* Select */
#define PK_HANGUP 114   /* quit   */
#define PK_DIGIT1 51    /* L      */
#define PK_DIGIT3 48    /* R      */

static const struct { int code, id; } keymap[] = {
    { PK_UP,     RETRO_DEVICE_ID_JOYPAD_UP     },
    { PK_DOWN,   RETRO_DEVICE_ID_JOYPAD_DOWN   },
    { PK_LEFT,   RETRO_DEVICE_ID_JOYPAD_LEFT   },
    { PK_RIGHT,  RETRO_DEVICE_ID_JOYPAD_RIGHT  },
    { PK_FIRE,   RETRO_DEVICE_ID_JOYPAD_A      },
    { PK_USE,    RETRO_DEVICE_ID_JOYPAD_B      },
    { PK_OK,     RETRO_DEVICE_ID_JOYPAD_START  },
    { PK_CANCEL, RETRO_DEVICE_ID_JOYPAD_SELECT },
    { PK_DIGIT1, RETRO_DEVICE_ID_JOYPAD_L      },
    { PK_DIGIT3, RETRO_DEVICE_ID_JOYPAD_R      },
};

/* Audio-clocked pacing, as in the NES port: keep ~SND_LEAD samples queued. */
#define SND_LEAD  1600  /* 100 ms at 16 kHz */

static unsigned g_pad;         /* bitmask over RETRO_DEVICE_ID_JOYPAD_* */
static int      g_stats;
static int      g_srate = 32768;
static double   g_fps = 60.0;  /* only used at start-up / no-audio (soft-float is fine) */
static int      g_skipblit;    /* behind the audio clock: drop this frame's blit */
static int      g_blits, g_skips;

/* ---------------------------------------------------------------- framebuffer */
static uint8_t  *fbPtr;
static unsigned  fbStride, fbBpp, fbXres, fbYres;
static int       swapRB;
static unsigned  srcW, srcH;   /* source size the maps were built for */
static float     g_aspect;
static unsigned  outW, outH, offX, offY;
static uint16_t  xmap[480];    /* output column -> source column */
static uint16_t  ymap[272];    /* output row    -> source row    */
static uint32_t *lut565;       /* RGB565 -> fb pixel */
static enum retro_pixel_format g_pixfmt = RETRO_PIXEL_FORMAT_0RGB1555;  /* libretro default */

/* ---------------------------------------------------------------- input */
static int inFd = -1;
struct ev16 { uint32_t sec, usec; uint16_t type, code; int32_t value; };

static void clearScreen(void) {
    if (fbPtr) memset(fbPtr, 0, (long)fbStride * fbYres);
}

/* ---------------------------------------------------------------- battery saves
 * RETRO_MEMORY_SAVE_RAM (GB/GBC cart RAM, GBA SRAM/Flash/EEPROM) lives in
 * CFW_SAVE_FILE: loaded before the takeover, written every SV_INTERVAL s if
 * changed, and on any exit (hangup key, SIGTERM). See docs/saves.md. */
static const char *g_savepath;
static uint8_t    *g_saved;      /* copy of what is on flash / last write attempt */
static size_t      g_savesize;
static volatile sig_atomic_t g_term;

static void saveLoad(void) {
    g_savepath = sv_path();
    if (!g_savepath) return;
    void *ram = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    g_savesize = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!ram || !g_savesize) { g_savepath = NULL; return; }   /* no battery in this cart */
    sv_load(g_savepath, ram, g_savesize);
    g_saved = (uint8_t *)malloc(g_savesize);
    if (g_saved) memcpy(g_saved, ram, g_savesize);
}

static void saveFlush(void) {
    if (!g_savepath || !g_saved) return;
    void *ram = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!ram || memcmp(ram, g_saved, g_savesize) == 0) return;
    memcpy(g_saved, ram, g_savesize);   /* a failure is logged once per change */
    sv_store(g_savepath, ram, g_savesize);
}

static void onTerm(int sig) { (void)sig; g_term = 1; }

static void saveTick(void) {
    static time_t next;
    time_t now = time(NULL);
    if (g_term) exit(0);               /* atexit flushes */
    if (now >= next) { next = now + SV_INTERVAL; saveFlush(); }
}

static void quit(void) {
    clearScreen();
    exit(0);   /* atexit: snd_hal_shutdown */
}

static void mapKey(int code, int down) {
    if (code == PK_HANGUP) { if (down) quit(); return; }
    for (unsigned i = 0; i < sizeof keymap / sizeof keymap[0]; i++)
        if (keymap[i].code == code) {
            if (down) g_pad |= 1u << keymap[i].id; else g_pad &= ~(1u << keymap[i].id);
            return;
        }
    if (g_stats && down) fprintf(stderr, TAG ": unmapped key %d\n", code);
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
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)g_pad;
    return id < 16 ? (g_pad >> id) & 1 : 0;
}

/* Fit w x h (display aspect g_aspect) into the screen and build the maps. */
static void layout(unsigned w, unsigned h) {
    srcW = w; srcH = h;
    float a = g_aspect > 0.1f ? g_aspect : (float)w / (float)h;
    outH = fbYres;
    outW = (unsigned)(outH * a + 0.5f);
    if (outW > fbXres) { outW = fbXres; outH = (unsigned)(outW / a + 0.5f); }
    if (outW > 480) outW = 480;
    if (outH > 272) outH = 272;
    offX = (fbXres - outW) / 2;
    offY = (fbYres - outH) / 2;
    for (unsigned x = 0; x < outW; x++) xmap[x] = x * w / outW;
    for (unsigned y = 0; y < outH; y++) ymap[y] = y * h / outH;
    clearScreen();
    fprintf(stderr, TAG ": %ux%u -> %ux%u at %u,%u\n", w, h, outW, outH, offX, offY);
}

/* Belt and braces: anything else that paints into fb0 (lcsD375 before it got
 * SIGSTOPped showed "MediaStack restarting") stays visible in the borders,
 * since we only redraw our box. Wipe them now and then (cheap). */
static void clearBorders(void) {
    for (unsigned y = 0; y < fbYres; y++) {
        uint8_t *row = fbPtr + (long)y * fbStride;
        if (y < offY || y >= offY + outH) {
            memset(row, 0, (size_t)fbXres * fbBpp);
        } else {
            memset(row, 0, (size_t)offX * fbBpp);
            memset(row + (size_t)(offX + outW) * fbBpp, 0, (size_t)(fbXres - offX - outW) * fbBpp);
        }
    }
}

static void fbInit(void) {
    struct fb_var_screeninfo v; struct fb_fix_screeninfo f;
    int fd = open("/dev/fb0", O_RDWR);
    if (fd < 0) { perror("open fb0"); exit(1); }
    ioctl(fd, FBIOGET_VSCREENINFO, &v);
    ioctl(fd, FBIOGET_FSCREENINFO, &f);
    fbBpp = v.bits_per_pixel / 8;
    fbXres = v.xres > 480 ? 480 : v.xres;
    fbYres = v.yres > 272 ? 272 : v.yres;
    fbStride = f.line_length ? f.line_length : v.xres * fbBpp;
    swapRB = (v.red.offset == 0 && v.blue.offset == 16);

    lut565 = (uint32_t *)malloc(65536 * sizeof *lut565);
    for (unsigned c = 0; c < 65536; c++) {
        unsigned r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f;
        r = (r << 3) | (r >> 2); g = (g << 2) | (g >> 4); b = (b << 3) | (b >> 2);
        lut565[c] = fbBpp == 4 ? (swapRB ? (b << 16) | (g << 8) | r : (r << 16) | (g << 8) | b)
                               : (uint32_t)c;
    }

    /* The phone UI (lcsD375) survives the takeover (only its parent lid is
     * killed) and would paint over us: freeze it, as Doom does. The phone
     * restore (or reboot) after we quit kills it anyway. */
    if (system("kill -STOP $(pidof lcsD375) 2>/dev/null") == -1)
        perror("stop lcsD375");

    fbPtr = (uint8_t *)mmap(NULL, (long)fbStride * v.yres, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (fbPtr == MAP_FAILED) { perror("mmap fb"); exit(1); }
    clearScreen();
    /* Deliberately NOT grabbed (EVIOCGRAB): nobody else reads the keypad once
     * lid/media_daemon are dead, and a grab makes the kernel drop events that
     * other processes inject by writing to event0 (input_inject_event ignores
     * non-grabbing handles) - which would break the remote keypad (Task J,
     * keyinject) and the key tests in tests/retro.sh. */
    inFd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
    if (inFd < 0) perror("open /dev/input/event0 (input disabled)");
}

static inline uint32_t px8888(uint32_t c) {
    return swapRB ? ((c & 0xff) << 16) | (c & 0xff00) | ((c >> 16) & 0xff) : (c & 0xffffff);
}

static void video_refresh(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!data || !w || !h) return;               /* NULL = duped frame */
    if (g_skipblit) { g_skips++; return; }
    if (w != srcW || h != srcH) layout(w, h);
    static unsigned n;
    if ((n++ & 63) == 0) clearBorders();
    g_blits++;
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
        const uint8_t *row = src + (size_t)sy * pitch;
        if (g_pixfmt == RETRO_PIXEL_FORMAT_XRGB8888) {
            const uint32_t *s = (const uint32_t *)row;
            if (fbBpp == 4) {
                uint32_t *dp = (uint32_t *)d;
                for (unsigned x = 0; x < outW; x++) dp[x] = px8888(s[xmap[x]]);
            } else {
                uint16_t *dp = (uint16_t *)d;
                for (unsigned x = 0; x < outW; x++) {
                    uint32_t c = s[xmap[x]];
                    dp[x] = (uint16_t)(((c >> 8) & 0xf800) | ((c >> 5) & 0x07e0) | ((c >> 3) & 0x1f));
                }
            }
        } else {
            const uint16_t *s = (const uint16_t *)row;
            int is555 = g_pixfmt == RETRO_PIXEL_FORMAT_0RGB1555;
            if (fbBpp == 4) {
                uint32_t *dp = (uint32_t *)d;
                if (is555)
                    for (unsigned x = 0; x < outW; x++) {
                        uint16_t c = s[xmap[x]];
                        dp[x] = lut565[((c & 0x7fe0) << 1) | (c & 0x1f)];
                    }
                else
                    for (unsigned x = 0; x < outW; x++) dp[x] = lut565[s[xmap[x]]];
            } else {
                uint16_t *dp = (uint16_t *)d;
                for (unsigned x = 0; x < outW; x++) {
                    uint16_t c = s[xmap[x]];
                    dp[x] = is555 ? (uint16_t)(((c & 0x7fe0) << 1) | (c & 0x1f)) : c;
                }
            }
        }
    }
}

/* ---------------------------------------------------------------- audio */
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

/* ---------------------------------------------------------------- environment */
static retro_audio_buffer_status_callback_t g_buf_status;

static const char *core_option(const char *key) {
    for (const struct opt *o = core_opts; o->key; o++)
        if (!strcmp(o->key, key)) return o->value;
    return NULL;                                 /* core default */
}

static void core_log(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_WARN && !g_stats) return;
    va_list ap; va_start(ap, fmt);
    fputs(TAG ": ", stderr);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static bool environment(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *(const char **)data = SYS_DIR;  return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *(const char **)data = SAVE_DIR; return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
            enum retro_pixel_format f = *(const enum retro_pixel_format *)data;
            if (f != RETRO_PIXEL_FORMAT_RGB565 && f != RETRO_PIXEL_FORMAT_XRGB8888 &&
                f != RETRO_PIXEL_FORMAT_0RGB1555) return false;
            g_pixfmt = f;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            struct retro_variable *v = (struct retro_variable *)data;
            v->value = v->key ? core_option(v->key) : NULL;
            return v->value != NULL;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            *(bool *)data = false; return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            *(bool *)data = true; return true;
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
        case RETRO_ENVIRONMENT_SET_GEOMETRY: {
            const struct retro_game_geometry *g = (const struct retro_game_geometry *)data;
            g_aspect = g->aspect_ratio;
            srcW = srcH = 0;                     /* re-layout on the next frame */
            return true;
        }
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
            const struct retro_system_av_info *av = (const struct retro_system_av_info *)data;
            g_srate = (int)av->timing.sample_rate;
            if (av->timing.fps > 1.0) g_fps = av->timing.fps;
            g_aspect = av->geometry.aspect_ratio;
            srcW = srcH = 0;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_MESSAGE:
            fprintf(stderr, TAG ": %s\n", ((const struct retro_message *)data)->msg);
            return true;
        default:
            return false;
    }
}

/* ---------------------------------------------------------------- pacing */
static void pace(void) {
    if (snd_hal_ok()) {
        int q = snd_hal_queued();
        if (g_buf_status) {                      /* gpSP's auto-frameskip */
            int occ = q * 100 / SND_LEAD;
            g_buf_status(true, occ > 100 ? 100 : occ, q < SND_LEAD / 4);
        }
        /* Behind: skip our blit for this frame (at most every other one). */
        g_skipblit = !g_skipblit && q < SND_LEAD / 2;
        if (q > SND_LEAD) usleep((q - SND_LEAD) * 125 / 2);   /* 62.5 us/sample */
        return;
    }
    static struct timeval last;
    struct timeval now; gettimeofday(&now, NULL);
    long us = (now.tv_sec - last.tv_sec) * 1000000L + (now.tv_usec - last.tv_usec);
    long target = (long)(1000000.0 / g_fps);
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
    if (ms <= 0) ms = 1;
    fprintf(stderr, TAG ": %ld.%ld fps, queued %d, underruns %d, blits %d, skipped %d\n",
            300000L / ms, (3000000L / ms) % 10, snd_hal_queued(), snd_hal_underruns(),
            g_blits, g_skips);
    g_blits = g_skips = 0;
    t0 = now;
}

/* ---------------------------------------------------------------- main */
static void *readFile(const char *path, size_t *size) {
    struct stat st;
    int fd = open(path, O_RDONLY);
    if (fd < 0 || fstat(fd, &st) < 0 || st.st_size <= 0 || st.st_size > 64 * 1024 * 1024) {
        if (fd >= 0) close(fd);
        return NULL;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)st.st_size);
    size_t got = 0;
    while (buf && got < (size_t)st.st_size) {
        ssize_t r = read(fd, buf + got, (size_t)st.st_size - got);
        if (r <= 0) { free(buf); buf = NULL; break; }
        got += (size_t)r;
    }
    close(fd);
    *size = got;
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s ROMFILE\n", argv[0]); return 1; }
    g_stats = getenv(STATS_ENV) != NULL;

    retro_set_environment(environment);
    retro_set_video_refresh(video_refresh);
    retro_set_audio_sample(audio_sample);
    retro_set_audio_sample_batch(audio_batch);
    retro_set_input_poll(input_poll);
    retro_set_input_state(input_state);
    retro_init();

    struct retro_system_info si;
    memset(&si, 0, sizeof si);
    retro_get_system_info(&si);

    /* Load the game BEFORE the takeover: a bad ROM must leave the phone UI alone. */
    struct retro_game_info game;
    memset(&game, 0, sizeof game);
    game.path = argv[1];
    if (!si.need_fullpath) {
        game.data = readFile(argv[1], &game.size);
        if (!game.data) { fprintf(stderr, TAG ": cannot read %s\n", argv[1]); return 2; }
    }
    if (!retro_load_game(&game)) {
        fprintf(stderr, TAG ": %s %s refused %s\n", si.library_name, si.library_version, argv[1]);
        return 2;
    }

    saveLoad();
    signal(SIGTERM, onTerm);

    struct retro_system_av_info av;
    memset(&av, 0, sizeof av);
    retro_get_system_av_info(&av);
    g_srate = (int)av.timing.sample_rate;
    if (av.timing.fps > 1.0) g_fps = av.timing.fps;
    g_aspect = av.geometry.aspect_ratio;
    fprintf(stderr, TAG ": %s %s loaded %s, %ux%u, audio %d Hz\n", si.library_name,
            si.library_version, argv[1], av.geometry.base_width, av.geometry.base_height, g_srate);

    /* Arm audio + hands-free, then take over (kill lid+media_daemon) while the
     * daemon is still alive. Must precede fbInit()/event0. */
    snd_hal_init();
    atexit(snd_hal_shutdown);
    atexit(saveFlush);   /* runs first on exit: the save must not wait for audio teardown */
    fbInit();

    for (;;) {
        pace();
        retro_run();
        saveTick();
        if (g_stats) logStats();
    }
}
