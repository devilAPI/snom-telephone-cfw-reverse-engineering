/* fbshot: dump the visible framebuffer page as raw RGB565 for the remote page.
 *
 *   fbshot [1|2|4]    scale divisor (1 = full 480x272, 2 = box-averaged 240x136, ...)
 *
 * Output: 8-byte header { 'S','F', scale, 0, w_lo, w_hi, h_lo, h_hi } followed by
 * w*h little-endian RGB565 pixels, top-down. The fb is 32bpp BGRX; stride and the
 * visible page (pan y offset) come from sysfs, same as cgi-bin/screenshot.
 * Why a native tool: the shell BMP path needs ~0.85 s a frame (520 KB, dd+printf on
 * an ARM1176); RGB565 at half size is 65 KB and the page expands it in JavaScript.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static int rd_int(const char *path, int idx, int def) {
    FILE *f = fopen(path, "r"); char b[64]; int v = def;
    if (!f) return def;
    if (fgets(b, sizeof b, f)) { char *p = b; while (idx-- > 0 && (p = strchr(p, ','))) p++; if (p) v = atoi(p); }
    fclose(f); return v;
}

int main(int argc, char **argv) {
    int sc = argc > 1 ? atoi(argv[1]) : 1;
    if (sc != 1 && sc != 2 && sc != 4) sc = 1;
    int W = 480, H = 272;
    FILE *f = fopen("/sys/class/graphics/fb0/modes", "r");
    if (f) { char b[64]; int w, h; if (fgets(b, sizeof b, f) && sscanf(b, "%*[^:]:%dx%d", &w, &h) == 2 && w > 0 && h > 0) { W = w; H = h; } fclose(f); }
    int stride = rd_int("/sys/class/graphics/fb0/stride", 0, W * 4);
    int pany = rd_int("/sys/class/graphics/fb0/pan", 1, 0);
    int fd = open("/dev/fb0", O_RDONLY);
    if (fd < 0) { perror("fbshot: /dev/fb0"); return 2; }
    unsigned char *buf = malloc((size_t)stride * H);
    if (!buf) return 2;
    size_t got = 0, want = (size_t)stride * H;
    while (got < want) { ssize_t n = pread(fd, buf + got, want - got, (off_t)pany * stride + got); if (n <= 0) break; got += n; }
    if (got < want) { fprintf(stderr, "fbshot: short read %zu/%zu\n", got, want); return 2; }
    int ow = W / sc, oh = H / sc;
    unsigned char hdr[8] = { 'S', 'F', sc, 0, ow & 255, ow >> 8, oh & 255, oh >> 8 };
    unsigned char *out = malloc((size_t)ow * oh * 2 + 8);
    memcpy(out, hdr, 8);
    unsigned char *o = out + 8;
    for (int y = 0; y < oh; y++)
        for (int x = 0; x < ow; x++) {
            unsigned r = 0, g = 0, b = 0;
            for (int dy = 0; dy < sc; dy++) for (int dx = 0; dx < sc; dx++) {
                unsigned char *p = buf + (size_t)(y * sc + dy) * stride + (x * sc + dx) * 4;
                b += p[0]; g += p[1]; r += p[2];
            }
            int n = sc * sc; r /= n; g /= n; b /= n;
            unsigned v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            *o++ = v & 255; *o++ = v >> 8;
        }
    fwrite(out, 1, o - out, stdout);
    return 0;
}
