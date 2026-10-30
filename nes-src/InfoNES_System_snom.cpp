/* InfoNES system port for the snom D375:
 *   video : /dev/fb0 (480x272, 32bpp), NES 256x240 centered, no scaling
 *   input : /dev/input/event0 keypad (freed by the launcher killing lid+media_daemon)
 *   sound : APU -> snd_hal (16 kHz loudspeaker); the codec clock paces the game
 * ROM path is argv[1]; red hangup key quits.
 */
#include "InfoNES.h"
#include "InfoNES_System.h"
#include "InfoNES_pAPU.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#include "snd_hal.h"   /* copied next to this file at build time */

/* NES 5-5-5 palette (from the InfoNES Linux port) */
WORD NesPalette[ 64 ] =
{
  0x39ce, 0x1071, 0x0015, 0x2013, 0x440e, 0x5402, 0x5000, 0x3c20,
  0x20a0, 0x0100, 0x0140, 0x00e2, 0x0ceb, 0x0000, 0x0000, 0x0000,
  0x5ef7, 0x01dd, 0x10fd, 0x401e, 0x5c17, 0x700b, 0x6ca0, 0x6521,
  0x45c0, 0x0240, 0x02a0, 0x0247, 0x0211, 0x0000, 0x0000, 0x0000,
  0x7fff, 0x1eff, 0x2e5f, 0x223f, 0x79ff, 0x7dd6, 0x7dcc, 0x7e67,
  0x7ae7, 0x4342, 0x2769, 0x2ff3, 0x03bb, 0x0000, 0x0000, 0x0000,
  0x7fff, 0x579f, 0x635f, 0x6b3f, 0x7f1f, 0x7f1b, 0x7ef6, 0x7f75,
  0x7f94, 0x73f4, 0x57d7, 0x5bf9, 0x4ffe, 0x0000, 0x0000, 0x0000
};

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

/* InfoNES pad bits: 0=A 1=B 2=Select 3=Start 4=Up 5=Down 6=Left 7=Right */
#define PAD_A      (1<<0)
#define PAD_B      (1<<1)
#define PAD_SELECT (1<<2)
#define PAD_START  (1<<3)
#define PAD_UP     (1<<4)
#define PAD_DOWN   (1<<5)
#define PAD_LEFT   (1<<6)
#define PAD_RIGHT  (1<<7)

#include <signal.h>
#include "snom_save.h"

static DWORD dwKeyPad1;
static const char *g_rompath;
static int g_loaded;   /* load the ROM once; quit when the game resets out */

/* ---- battery saves (docs/saves.md) ----
 * Cartridges with the battery flag keep their 8 KiB SRAM ($6000-$7FFF) in
 * CFW_SAVE_FILE. Loaded when the ROM is read; written every SV_INTERVAL s if
 * changed, on quit (hangup key, game reset-out, SIGTERM). */
static const char *g_savepath;
static BYTE g_saved[SRAM_SIZE];      /* what is on flash (or what we last tried to write) */
static int g_battery;
static volatile sig_atomic_t g_term;

static void saveFlush(void) {
    if (!g_battery || !g_savepath) return;
    if (memcmp(SRAM, g_saved, SRAM_SIZE) == 0) return;
    memcpy(g_saved, SRAM, SRAM_SIZE);   /* a failure is logged once per change, not every 30 s */
    sv_store(g_savepath, SRAM, SRAM_SIZE);
}

static void onTerm(int sig) { (void)sig; g_term = 1; }

static void saveTick(void) {
    static time_t next;
    time_t now = time(NULL);
    if (g_term) exit(0);                 /* atexit flushes the save */
    if (now >= next) { next = now + SV_INTERVAL; saveFlush(); }
}

/* ---- framebuffer ---- */
static uint8_t *fbPtr;
static int      fbFd = -1;
static unsigned fbStride, fbBpp, fbYres, offX, offY;
static int      swapRB;
static unsigned fbXres;
static uint32_t *lut555;   /* NES 5-5-5 -> framebuffer pixel, precomputed */

/* ---- input ---- */
static int inFd = -1;
struct ev16 { uint32_t sec, usec; uint16_t type, code; int32_t value; };

static void mapKey(int code, int down) {
    unsigned bit = 0;
    switch (code) {
        case PK_UP:    bit = PAD_UP;    break;
        case PK_DOWN:  bit = PAD_DOWN;  break;
        case PK_LEFT:  bit = PAD_LEFT;  break;
        case PK_RIGHT: bit = PAD_RIGHT; break;
        case PK_FIRE:  bit = PAD_A;     break;
        case PK_USE:   bit = PAD_B;     break;
        case PK_OK:    bit = PAD_START; break;
        case PK_CANCEL:bit = PAD_SELECT;break;
        case PK_HANGUP:
            if (down) { if (fbPtr) memset(fbPtr, 0, (long)fbStride * fbYres); exit(0); }
            return;
        default: return;
    }
    if (down) dwKeyPad1 |= bit; else dwKeyPad1 &= ~bit;
}

static void pumpInput(void) {
    struct ev16 ev;
    struct pollfd pfd; pfd.fd = inFd; pfd.events = POLLIN; pfd.revents = 0;
    while (inFd >= 0 && poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN)) {
        if (read(inFd, &ev, sizeof(ev)) != (int)sizeof(ev)) break;
        if (ev.type == 1 && ev.value != 2) mapKey(ev.code, ev.value);
    }
}

static void fbInit(void) {
    struct fb_var_screeninfo v; struct fb_fix_screeninfo f;
    fbFd = open("/dev/fb0", O_RDWR);
    if (fbFd < 0) { perror("open fb0"); exit(1); }
    ioctl(fbFd, FBIOGET_VSCREENINFO, &v);
    ioctl(fbFd, FBIOGET_FSCREENINFO, &f);
    fbBpp = v.bits_per_pixel / 8;
    fbYres = v.yres;
    fbStride = f.line_length ? f.line_length : v.xres * fbBpp;
    if (v.red.offset == 0 && v.blue.offset == 16) swapRB = 1;
    fbXres = v.xres;
    lut555 = (uint32_t *)malloc(32768 * sizeof *lut555);
    for (unsigned w = 0; w < 32768; w++) {
        unsigned r = (w >> 10) & 0x1f, g = (w >> 5) & 0x1f, b = w & 0x1f;
        if (fbBpp == 4) {
            r = (r << 3) | (r >> 2); g = (g << 3) | (g >> 2); b = (b << 3) | (b >> 2);
            lut555[w] = swapRB ? ((b << 16) | (g << 8) | r) : ((r << 16) | (g << 8) | b);
        } else {
            lut555[w] = (r << 11) | (g << 6) | b;   /* RGB565 */
        }
    }
    offX = ((v.xres - NES_DISP_WIDTH)  / 2) * fbBpp;
    offY = ((v.yres - NES_DISP_HEIGHT) / 2) * fbStride;
    /* The phone UI (lcsD375) survives the takeover (only its parent lid is
     * killed) and would paint over us: freeze it, as Doom does. The phone
     * restore (or reboot) after we quit kills it anyway. */
    if (system("kill -STOP $(pidof lcsD375) 2>/dev/null") == -1)
        perror("stop lcsD375");

    fbPtr = (uint8_t *)mmap(NULL, (long)fbStride * v.yres, PROT_READ|PROT_WRITE, MAP_SHARED, fbFd, 0);
    if (fbPtr == MAP_FAILED) { perror("mmap fb"); exit(1); }
    memset(fbPtr, 0, (long)fbStride * v.yres);
    inFd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
    if (inFd >= 0) ioctl(inFd, _IOW('E', 0x90, int), 1); /* EVIOCGRAB */
}

/* ---- InfoNES system interface ---- */

/* Audio-clocked pacing: keep ~SND_LEAD samples queued for the codec. The pump
 * drains the ring at exactly 16 kHz, so sleeping off the excess locks the game
 * to the audio clock (no drift -> no periodic underrun clicks or overflow).
 * Runs once per emulated frame from InfoNES_SoundOutput() (called every frame,
 * unlike InfoNES_LoadFrame(), which frameskip suppresses). When the queue runs
 * low the next frame is emulated without rendering (FrameSkip=1) to catch up. */
#define SND_LEAD 1600   /* 100 ms at 16 kHz */

static int g_skipped;    /* frames not rendered (stats) */

static void paceFrame(void) {
    if (snd_hal_ok()) {
        int q = snd_hal_queued();
        if (q > SND_LEAD) usleep((q - SND_LEAD) * 125 / 2);   /* 62.5 us/sample */
        /* Behind: skip rendering the next frame (at most every other one). */
        FrameSkip = (q < SND_LEAD / 2 && FrameCnt == 0) ? 1 : 0;
        if (FrameSkip) g_skipped++;
        return;
    }
    /* No audio: fall back to the wall clock. */
    static struct timeval last;
    struct timeval now; gettimeofday(&now, NULL);
    long us = (now.tv_sec - last.tv_sec) * 1000000L + (now.tv_usec - last.tv_usec);
    long target = 1000000L / 60;
    if (us > 0 && us < target) usleep(target - us);
    gettimeofday(&last, NULL);
}

/* Belt and braces: anything else that paints into fb0 (lcsD375 before it got
 * SIGSTOPped showed "MediaStack restarting") stays visible in the borders,
 * since the game only redraws its 256x240 box. Wipe them now and then. */
static void clearBorders(void) {
    unsigned w = NES_DISP_WIDTH * fbBpp;
    for (unsigned y = 0; y < fbYres; y++) {
        uint8_t *row = fbPtr + (long)y * fbStride;
        if ((long)y * fbStride < (long)offY || (long)y * fbStride >= (long)offY + NES_DISP_HEIGHT * (long)fbStride) {
            memset(row, 0, (size_t)fbXres * fbBpp);
        } else {
            memset(row, 0, offX);
            memset(row + offX + w, 0, (size_t)fbXres * fbBpp - offX - w);
        }
    }
}

void InfoNES_LoadFrame() {
    static int n;
    if ((n++ & 63) == 0) clearBorders();

    for (int y = 0; y < NES_DISP_HEIGHT; y++) {
        const WORD *s = &WorkFrame[y * NES_DISP_WIDTH];
        uint8_t *d = fbPtr + offY + (long)y * fbStride + offX;
        if (fbBpp == 4) {
            uint32_t *dp = (uint32_t *)d;
            for (int x = 0; x < NES_DISP_WIDTH; x++) dp[x] = lut555[s[x] & 0x7fff];
        } else {
            uint16_t *dp = (uint16_t *)d;
            for (int x = 0; x < NES_DISP_WIDTH; x++) dp[x] = (uint16_t)lut555[s[x] & 0x7fff];
        }
    }
}

void InfoNES_PadState( DWORD *pdwPad1, DWORD *pdwPad2, DWORD *pdwSystem ) {
    pumpInput();
    *pdwPad1 = dwKeyPad1;
    *pdwPad2 = 0;
    *pdwSystem = 0;
}

void InfoNES_Wait() {
    /* Called once per scanline; pacing is done per-frame in InfoNES_LoadFrame. */
}

int InfoNES_Menu() {
    /* Load the ROM the first time; if the game ever resets back to the menu,
       quit (-1) so the launcher reboots the phone. */
    if (g_loaded) return -1;
    g_loaded = 1;
    return (InfoNES_Load(g_rompath) == 0) ? 0 : -1;
}

int InfoNES_ReadRom( const char *pszFileName ) {
    FILE *fp = fopen( pszFileName, "rb" );
    if ( !fp ) return -1;
    fread( &NesHeader, sizeof NesHeader, 1, fp );
    if ( memcmp( NesHeader.byID, "NES\x1a", 4 ) != 0 ) { fclose(fp); return -1; }
    memset( SRAM, 0, SRAM_SIZE );
    if ( NesHeader.byInfo1 & 4 ) fread( &SRAM[ 0x1000 ], 512, 1, fp );
    g_battery = ( NesHeader.byInfo1 & 2 ) != 0;
    if ( g_battery && g_savepath ) {
        sv_load( g_savepath, SRAM, SRAM_SIZE );
        memcpy( g_saved, SRAM, SRAM_SIZE );
    }
    ROM = (BYTE *)malloc( NesHeader.byRomSize * 0x4000 );
    fread( ROM, 0x4000, NesHeader.byRomSize, fp );
    if ( NesHeader.byVRomSize > 0 ) {
        VROM = (BYTE *)malloc( NesHeader.byVRomSize * 0x2000 );
        fread( VROM, 0x2000, NesHeader.byVRomSize, fp );
    }
    fclose( fp );
    return 0;
}

void InfoNES_ReleaseRom() {
    if (ROM)  { free(ROM);  ROM  = NULL; }
    if (VROM) { free(VROM); VROM = NULL; }
}

void *InfoNES_MemoryCopy( void *dest, const void *src, int count ) { return memcpy(dest, src, count); }
void *InfoNES_MemorySet( void *dest, int c, int count ) { return memset(dest, c, count); }
void InfoNES_DebugPrint( char *pszMsg ) { fprintf(stderr, "%s\n", pszMsg); }
void InfoNES_MessageBox( char *pszMsg, ... ) { fprintf(stderr, "%s\n", pszMsg); }

/* ---- sound ----
 * InfoNES hands us 5 unsigned-8-bit channel buffers per video frame at the APU
 * rate (22050 Hz: tools/build-nes.sh sets pAPU_QUALITY=2, half the APU work of
 * 44.1 kHz and still above the codec's 16 kHz). Their scales differ: pulse = 0x11*vol
 * (0..255), triangle 0..255, noise 0..15, DPCM 0..127. We mix them with the
 * NES's own relative levels (linear approximation of the 2A03 mixer, Q4), run
 * a one-pole DC blocker to recentre the unsigned levels, and hand the result to
 * snd_hal, which box-filters it down to the codec's 16 kHz. Integer only: the
 * CPU has no FPU. One full-volume pulse comes out at about +-2000. */
#define W_PULSE  16
#define W_TRI    18
#define W_NOISE  179
#define W_DPCM   121
#define DC_R     32604   /* 0.995 in Q15: ~18 Hz high-pass at 22.05 kHz */

static int g_apu_rate = 22050;
static int g_stats;      /* NES_STATS=1: log fps/queue/underruns to stderr */

void InfoNES_SoundInit( void ) {}

int InfoNES_SoundOpen( int samples_per_sync, int sample_rate ) {
    (void)samples_per_sync;
    if (sample_rate > 0) g_apu_rate = sample_rate;
    return 0;
}

void InfoNES_SoundClose( void ) {}

static void logStats(void) {
    static int frames;
    static struct timeval t0;
    struct timeval now;
    if (frames++ == 0) { gettimeofday(&t0, NULL); return; }
    if (frames % 300) return;
    gettimeofday(&now, NULL);
    long ms = (now.tv_sec - t0.tv_sec) * 1000L + (now.tv_usec - t0.tv_usec) / 1000;
    fprintf(stderr, "nes: %ld.%ld fps, queued %d, underruns %d, skipped %d\n",
            300000L / ms, (3000000L / ms) % 10, snd_hal_queued(), snd_hal_underruns(), g_skipped);
    g_skipped = 0;
    t0 = now;
}

void InfoNES_SoundOutput(int s, BYTE *w1, BYTE *w2, BYTE *w3, BYTE *w4, BYTE *w5) {
    if (g_stats) logStats();
    saveTick();
    paceFrame();
    if (!snd_hal_ok() || s <= 0) return;
    static int dcx, dcy;                  /* DC blocker state */
    static short buf[1024];
    int n = s > 1024 ? 1024 : s;
    for (int i = 0; i < n; i++) {
        int x = (w1[i] + w2[i]) * W_PULSE + w3[i] * W_TRI + w4[i] * W_NOISE + w5[i] * W_DPCM;
        int y = x - dcx + ((dcy * DC_R) >> 15);   /* high-pass to kill the DC offset */
        dcx = x; dcy = y;
        if (y > 32767) y = 32767; else if (y < -32768) y = -32768;
        buf[i] = (short)y;
    }
    snd_hal_push_rate(buf, n, g_apu_rate);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s game.nes\n", argv[0]); return 1; }
    g_rompath = argv[1];
    g_stats = getenv("NES_STATS") != NULL;
    g_savepath = sv_path();
    signal(SIGTERM, onTerm);
    /* Arm audio + hands-free, then take over (kill lid+media_daemon) while the
     * daemon is still alive. Must precede fbInit()/event0. The boot script no
     * longer kills the daemon itself. */
    snd_hal_init();
    atexit(snd_hal_shutdown);
    atexit(saveFlush);                    /* runs first on exit: the save must not wait for audio teardown */
    fbInit();
    InfoNES_Main();   /* InfoNES_Menu() loads the ROM; InfoNES_Cycle() plays it */
    return 0;
}
