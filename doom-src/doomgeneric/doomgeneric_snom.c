// doomgeneric port for the snom D375:
//   video : /dev/fb0  (480x272, 32bpp) -- Doom's 320x200 is scaled up as far as
//           it fits without changing its aspect ratio (435x272), centered
//   input : /dev/input/event0  ("keypad" evdev device)
// snd_hal_init() kills lid + media_daemon; the orphaned UI (lcsD375) is
// SIGSTOP'd in DG_Init so it stops drawing over us. The phone reboots when Doom
// quits, so nothing needs to be resumed. No VT/console handling is needed.
#include "doomkeys.h"
#include "doomgeneric.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#include "snd_hal.h"   /* copied next to this file at build time */

// snom D375 keypad scancodes (from /dev/input/event0), reverse-engineered live.
// The physical keys only reach evdev once lid + media_daemon release the device.
#define PK_UP      84
#define PK_DOWN    67
#define PK_LEFT    101
#define PK_RIGHT   50
#define PK_OK      97
#define PK_FIRE    120
#define PK_USE     116
#define PK_CANCEL  115
#define PK_HANGUP  114   // quits Doom (launcher then restores the phone)

// --- framebuffer ---------------------------------------------------------
static uint8_t *fbPtr;
static int      fbFd = -1;
static unsigned fbW, fbH, fbStride, fbBpp;
static unsigned outW, outH;          // scaled picture size on the fb
static uint8_t *outOrigin;           // top-left of the scaled picture
static uint16_t *srcCol;             // fb column -> Doom column
static uint16_t *srcRow;             // fb row    -> Doom row
static int      swapRB = 0;          // set if fb is BGR instead of RGB

// --- input ---------------------------------------------------------------
static int inFd = -1;

#define KEYQ 32
static unsigned short keyq[KEYQ];
static int keyqHead, keyqTail;

static unsigned char convertToDoomKey(unsigned int code) {
    switch (code) {
        case PK_UP:      return KEY_UPARROW;     // forward
        case PK_DOWN:    return KEY_DOWNARROW;   // back
        case PK_LEFT:    return KEY_LEFTARROW;   // turn left
        case PK_RIGHT:   return KEY_RIGHTARROW;  // turn right
        case PK_OK:      return KEY_ENTER;       // menu select
        case PK_FIRE:    return KEY_FIRE;        // shoot
        case PK_USE:     return KEY_USE;         // open doors / use
        case PK_CANCEL:  return KEY_ESCAPE;      // menu / back
        default:         return 0;
    }
}

static void enqueueKey(int pressed, unsigned int code) {
    unsigned char k = convertToDoomKey(code);
    if (!k) return;
    unsigned short packed = ((pressed ? 1 : 0) << 8) | k;
    keyq[keyqHead] = packed;
    keyqHead = (keyqHead + 1) % KEYQ;
}

// struct input_event on 32-bit: timeval(8) type(2) code(2) value(4) = 16 bytes
struct ev16 { uint32_t sec, usec; uint16_t type, code; int32_t value; };

static void pumpInput(void) {
    struct ev16 ev;
    struct pollfd pfd = { .fd = inFd, .events = POLLIN };
    while (inFd >= 0 && poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN)) {
        if (read(inFd, &ev, sizeof(ev)) != (int)sizeof(ev)) break;
        if (ev.type == 1 /*EV_KEY*/) {           // value: 1 press, 0 release, 2 repeat
            if (ev.code == PK_HANGUP && ev.value == 1) {   // red hangup -> quit Doom
                if (fbPtr) memset(fbPtr, 0, (long)fbStride * fbH);
                exit(0);
            }
            if (ev.value != 2) enqueueKey(ev.value, ev.code);
        }
    }
}

void DG_Init(void) {
    struct fb_var_screeninfo v;
    struct fb_fix_screeninfo f;

    fbFd = open("/dev/fb0", O_RDWR);
    if (fbFd < 0) { perror("open /dev/fb0"); exit(1); }
    if (ioctl(fbFd, FBIOGET_VSCREENINFO, &v) < 0) { perror("VSCREENINFO"); exit(1); }
    if (ioctl(fbFd, FBIOGET_FSCREENINFO, &f) < 0) { perror("FSCREENINFO"); exit(1); }

    fbW = v.xres; fbH = v.yres; fbBpp = v.bits_per_pixel / 8;
    fbStride = f.line_length ? f.line_length : fbW * fbBpp;

    // DG_ScreenBuffer is 0x00RRGGBB; on a little-endian fb that is bytes B,G,R,X,
    // i.e. the red channel lands at bit offset 16. If the panel reports red at a
    // different offset (BGR), swap R and B when blitting.
    if (v.red.offset == 0 && v.blue.offset == 16) swapRB = 1;
    if (getenv("DOOM_BGR")) swapRB = 1;   // manual override for testing

    // Largest uniform scale that fits: limited by whichever axis runs out first.
    if ((unsigned long)fbW * DOOMGENERIC_RESY <= (unsigned long)fbH * DOOMGENERIC_RESX) {
        outW = fbW; outH = fbW * DOOMGENERIC_RESY / DOOMGENERIC_RESX;
    } else {
        outH = fbH; outW = fbH * DOOMGENERIC_RESX / DOOMGENERIC_RESY;
    }
    srcCol = malloc(outW * sizeof *srcCol);
    srcRow = malloc(outH * sizeof *srcRow);
    if (!srcCol || !srcRow) { perror("malloc scale tables"); exit(1); }
    for (unsigned x = 0; x < outW; x++) srcCol[x] = x * DOOMGENERIC_RESX / outW;
    for (unsigned y = 0; y < outH; y++) srcRow[y] = y * DOOMGENERIC_RESY / outH;

    long mapLen = (long)fbStride * fbH;
    fbPtr = mmap(NULL, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fbFd, 0);
    if (fbPtr == MAP_FAILED) { perror("mmap fb"); exit(1); }
    memset(fbPtr, 0, mapLen);
    outOrigin = fbPtr + (long)((fbH - outH) / 2) * fbStride + ((fbW - outW) / 2) * fbBpp;

    // The phone UI survives the takeover (only its parent lid is killed) and
    // would keep painting status bars over the game: freeze it.
    if (system("kill -STOP $(pidof lcsD375) 2>/dev/null") == -1)
        perror("stop lcsD375");

    inFd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
    if (inFd < 0) perror("open /dev/input/event0 (input disabled)");
    else ioctl(inFd, _IOW('E', 0x90, int), 1); // EVIOCGRAB: try exclusive access
}

void DG_DrawFrame(void) {
    pumpInput();
    if (!fbPtr) return;
    // Nearest-neighbour upscale. Consecutive fb rows that map to the same Doom
    // row are copied from the previous fb row instead of being rescaled.
    int lastRow = -1;
    uint8_t *prev = NULL;
    for (unsigned y = 0; y < outH; y++) {
        uint8_t *dst = outOrigin + (long)y * fbStride;
        if (srcRow[y] == lastRow) {
            memcpy(dst, prev, outW * fbBpp);
            prev = dst;
            continue;
        }
        lastRow = srcRow[y];
        prev = dst;
        const uint32_t *src = DG_ScreenBuffer + (long)lastRow * DOOMGENERIC_RESX;
        if (fbBpp == 4 && !swapRB) {
            uint32_t *d = (uint32_t *)dst;
            for (unsigned x = 0; x < outW; x++) d[x] = src[srcCol[x]];
        } else if (fbBpp == 4) {               // swap R/B
            uint32_t *d = (uint32_t *)dst;
            for (unsigned x = 0; x < outW; x++) {
                uint32_t p = src[srcCol[x]];
                d[x] = (p & 0xff00ff00) | ((p & 0xff) << 16) | ((p >> 16) & 0xff);
            }
        } else {                               // 16bpp RGB565 fallback
            uint16_t *d = (uint16_t *)dst;
            for (unsigned x = 0; x < outW; x++) {
                uint32_t p = src[srcCol[x]];
                d[x] = ((p >> 8) & 0xf800) | ((p >> 5) & 0x07e0) | ((p >> 3) & 0x001f);
            }
        }
    }
}

void DG_SleepMs(uint32_t ms) { usleep(ms * 1000); }

uint32_t DG_GetTicksMs(void) {
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return tp.tv_sec * 1000 + tp.tv_usec / 1000;
}

int DG_GetKey(int *pressed, unsigned char *doomKey) {
    if (keyqHead == keyqTail) return 0;
    unsigned short packed = keyq[keyqTail];
    keyqTail = (keyqTail + 1) % KEYQ;
    *pressed = (packed >> 8) & 1;
    *doomKey = packed & 0xff;
    return 1;
}

void DG_SetWindowTitle(const char *title) { (void)title; }

int main(int argc, char **argv) {
    // Arm audio + hands-free, then take over (kill lid+media_daemon). Must run
    // while media_daemon is still alive, so it happens here before any fb/input
    // setup -- the boot script no longer kills the daemon itself.
    snd_hal_init();
    atexit(snd_hal_shutdown);

    doomgeneric_Create(argc, argv);
    for (;;) doomgeneric_Tick();
    return 0;
}
