/* navidrome-src/navplay.c - decode an MP3 stream and play it through spkstream.
 *
 * Part of the CFW Navidrome player (docs/navidrome.md). The phone's busybox wget
 * downloads the track (Navidrome transcodes it to MP3 with ffmpeg) and pipes it in:
 *
 *   wget -q -O - "http://server/rest/stream.view?...&format=mp3" | navplay -k TOKEN [-v VOL] [-P POSFILE]
 *
 * The CPU (ARM1176, no VFP enabled by the kernel) has no hardware floating point, so
 * the decoder is libmad: fixed-point, with ARM multiply-accumulate asm (FPM_ARM).
 * MAD_OPTION_HALFSAMPLERATE halves the synthesis work (44.1 kHz -> 22.05 kHz), and the
 * two channels are averaged to mono: the speaker path is 16 kHz mono anyway.
 *
 * Output: an HTTP POST to spkstream on 127.0.0.1:8091 (/play?k=TOKEN&vol=VOL), as a WAV
 * stream (header with the decoded rate, mono, 16 bit; no length). spkstream resamples
 * to 16 kHz and slows us down through TCP when its 2 s buffer is full.
 *
 * -P FILE: writes the seconds decoded so far, once a second (the player script uses it
 *          for pause/resume; spkstream's buffered_ms tells how much is still queued).
 * Exit: 0 = played to the end, 2 = stopped or replaced (spkstream answered "stopped"),
 *       1 = error (no MP3 data, spkstream not reachable, ...).
 * Build: tools/build-navplay.sh (static musl, armv6 soft-float, libmad 0.15.1b). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#include "stream.h"
#include "frame.h"
#include "synth.h"

#define INBUF  16384

static int sock = -1;

static int send_all(const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t k = send(sock, c, n, MSG_NOSIGNAL);
        if (k < 0) { if (errno == EINTR) continue; return -1; }
        c += k; n -= (size_t)k;
    }
    return 0;
}

static void le32(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void le16(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }

/* connect to spkstream and send the request + WAV header */
static int open_out(int port, const char *tok, int vol, unsigned rate) {
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0 || connect(sock, (struct sockaddr *)&a, sizeof a) < 0) {
        fprintf(stderr, "navplay: speaker (127.0.0.1:%d): %s\n", port, strerror(errno));
        return -1;
    }
    char req[256];
    int n = vol >= 0 ? snprintf(req, sizeof req, "POST /play?k=%s&vol=%d HTTP/1.0\r\n\r\n", tok, vol)
                     : snprintf(req, sizeof req, "POST /play?k=%s HTTP/1.0\r\n\r\n", tok);
    unsigned char h[44];
    memcpy(h, "RIFF", 4); le32(h + 4, 0xffffffffu); memcpy(h + 8, "WAVEfmt ", 8);
    le32(h + 16, 16); le16(h + 20, 1); le16(h + 22, 1); le32(h + 24, rate);
    le32(h + 28, rate * 2); le16(h + 32, 2); le16(h + 34, 16);
    memcpy(h + 36, "data", 4); le32(h + 40, 0xffffffffu);
    if (send_all(req, (size_t)n) < 0 || send_all(h, sizeof h) < 0) return -1;
    return 0;
}

/* libmad's 28-bit fixed point to 16 bit, rounded and clipped */
static inline int to16(mad_fixed_t x) {
    x += 1L << (MAD_F_FRACBITS - 16);
    if (x >= MAD_F_ONE) x = MAD_F_ONE - 1;
    else if (x < -MAD_F_ONE) x = -MAD_F_ONE;
    return x >> (MAD_F_FRACBITS + 1 - 16);
}

static void usage(void) {
    fprintf(stderr, "usage: navplay -k TOKEN [-p PORT] [-v VOL] [-P POSFILE] < file.mp3\n");
    exit(1);
}

int main(int argc, char **argv) {
    const char *tok = NULL, *posf = NULL;
    int port = 8091, vol = -1, opt;
    while ((opt = getopt(argc, argv, "k:p:v:P:")) != -1) {
        switch (opt) {
        case 'k': tok = optarg; break;
        case 'p': port = atoi(optarg); break;
        case 'v': vol = atoi(optarg); if (vol < 0 || vol > 100) usage(); break;
        case 'P': posf = optarg; break;
        default: usage();
        }
    }
    if (!tok || strspn(tok, "0123456789abcdefABCDEF") != strlen(tok)) usage();
    signal(SIGPIPE, SIG_IGN);

    static unsigned char in[INBUF + MAD_BUFFER_GUARD];
    static short out[1152];
    struct mad_stream st; struct mad_frame fr; struct mad_synth sy;
    mad_stream_init(&st); mad_frame_init(&fr); mad_synth_init(&sy);
    mad_stream_options(&st, MAD_OPTION_HALFSAMPLERATE);

    unsigned rate = 0;
    unsigned long long samples = 0, next_pos = 0;
    int eof = 0, rc = 0;
    for (;;) {
        /* refill: keep the undecoded rest, then read */
        if (st.buffer == NULL || st.error == MAD_ERROR_BUFLEN) {
            size_t keep = 0;
            if (st.next_frame) { keep = (size_t)(st.bufend - st.next_frame); memmove(in, st.next_frame, keep); }
            if (eof) break;
            size_t got = keep;
            while (got < INBUF) {
                ssize_t k = read(0, in + got, INBUF - got);
                if (k < 0) { if (errno == EINTR) continue; break; }
                if (k == 0) { eof = 1; break; }
                got += (size_t)k;
            }
            if (eof) { memset(in + got, 0, MAD_BUFFER_GUARD); got += MAD_BUFFER_GUARD; }
            if (got == 0) break;
            mad_stream_buffer(&st, in, got);
            st.error = MAD_ERROR_NONE;
        }
        if (mad_frame_decode(&fr, &st) == -1) {
            if (st.error == MAD_ERROR_BUFLEN) continue;
            if (MAD_RECOVERABLE(st.error)) continue;   /* ID3 tags, a damaged frame */
            fprintf(stderr, "navplay: decode error 0x%04x\n", st.error);
            rc = 1; break;
        }
        mad_synth_frame(&sy, &fr);
        if (!rate) {
            rate = sy.pcm.samplerate;
            if (open_out(port, tok, vol, rate) < 0) { rc = 1; break; }
        }
        unsigned n = sy.pcm.length, i;
        if (sy.pcm.channels == 2)
            for (i = 0; i < n; i++) out[i] = (short)((to16(sy.pcm.samples[0][i]) + to16(sy.pcm.samples[1][i])) / 2);
        else
            for (i = 0; i < n; i++) out[i] = (short)to16(sy.pcm.samples[0][i]);
        if (send_all(out, n * 2) < 0) { rc = 2; break; }   /* spkstream closed: replaced or stopped */
        samples += n;
        if (posf && samples >= next_pos) {
            FILE *f = fopen(posf, "w");
            if (f) { fprintf(f, "%llu\n", samples / rate); fclose(f); }
            next_pos = samples + rate;
        }
    }
    mad_synth_finish(&sy); mad_frame_finish(&fr); mad_stream_finish(&st);
    if (!rate) { fprintf(stderr, "navplay: no MP3 data\n"); return 1; }
    if (rc) return rc;
    /* done sending: spkstream answers once the sound has played */
    shutdown(sock, SHUT_WR);
    char r[256]; int got = 0;
    for (;;) {
        ssize_t k = recv(sock, r + got, sizeof r - 1 - (size_t)got, 0);
        if (k <= 0) break;
        got += (int)k;
        if (got >= (int)sizeof r - 1) break;
    }
    r[got] = 0;
    return strstr(r, "played") ? 0 : 2;
}
