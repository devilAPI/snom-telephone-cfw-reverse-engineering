// i_snom_sound.c - Doom sound (I_* interface) for the snom D375.
//
// Replaces doomgeneric's stub i_sound.o. SFX only: DMX sound lumps are decoded,
// resampled once to 16 kHz mono S16, cached per sfxinfo, then software-mixed in
// I_UpdateSound (driven per tic from S_UpdateSounds) and streamed to the
// loudspeaker via snd_hal. Music is stubbed (the MUS/MIDI synth is future work).
//
// snd_hal_init() is called from main() (doomgeneric_snom.c) before this runs, so
// the codec + hands-free + daemon takeover are already set up by the time Doom
// initialises sound.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#include "doomtype.h"
#include "i_sound.h"
#include "m_config.h"
#include "m_misc.h"
#include "w_wad.h"
#include "z_zone.h"

#include "snd_hal.h"   /* copied next to this file at build time */

#define OUT_RATE     16000
#define NUM_CHANNELS 16

// Config variables that live in i_sound.c upstream; other TUs link against them.
int   snd_samplerate     = OUT_RATE;
int   snd_cachesize      = 16 * 1024 * 1024;
int   snd_maxslicetime_ms = 28;
char *snd_musiccmd       = "";
int   snd_musicdevice    = SNDDEVICE_GENMIDI;
int   snd_sfxdevice      = SNDDEVICE_SB;

static boolean use_sfx_prefix = true;
static boolean sound_on = false;

// One decoded sound effect (16 kHz mono S16), cached on sfxinfo->driver_data.
typedef struct {
    int      len;        // samples
    int16_t *data;
} cached_sfx_t;

// A playing channel.
typedef struct {
    const int16_t *data;
    int            len;
    int            pos;   // sample index
    int            vol;   // 0..127
    boolean        playing;
} channel_t;

static channel_t channels[NUM_CHANNELS];

// ---- DMX lump decode + resample to 16 kHz -------------------------------

// Decode a DMX sound lump into a freshly malloc'd 16 kHz mono S16 buffer.
// Returns NULL on any invalid lump. DMX layout: 8-byte header
// {u16 format=3, u16 rate, u32 length}, then 16 bytes pad, the 8-bit unsigned
// PCM, and 16 bytes trailing pad; `length` counts the samples plus both pads.
static cached_sfx_t *decode_sfx(int lumpnum)
{
    byte *lump;
    unsigned int lumplen, length;
    int samplerate;

    if (lumpnum < 0)
        return NULL;

    lump = W_CacheLumpNum(lumpnum, PU_STATIC);
    lumplen = W_LumpLength(lumpnum);

    if (lumplen < 8 || lump[0] != 0x03 || lump[1] != 0x00) {
        W_ReleaseLumpNum(lumpnum);
        return NULL;
    }

    samplerate = (lump[3] << 8) | lump[2];
    length = (lump[7] << 24) | (lump[6] << 16) | (lump[5] << 8) | lump[4];

    if (length > lumplen - 8 || length <= 48 || samplerate <= 0) {
        W_ReleaseLumpNum(lumpnum);
        return NULL;
    }

    // Skip the 8-byte header + 16-byte leading pad; drop both 16-byte pads.
    byte *pcm = lump + 24;
    int   n8  = (int)length - 32;
    if (n8 <= 0) { W_ReleaseLumpNum(lumpnum); return NULL; }

    // Resample n8 unsigned-8-bit samples @ samplerate -> 16 kHz S16 (linear).
    long outcap = (long)n8 * OUT_RATE / samplerate + 2;
    int16_t *out = malloc(sizeof(int16_t) * outcap);
    cached_sfx_t *c = malloc(sizeof(cached_sfx_t));
    if (!out || !c) { free(out); free(c); W_ReleaseLumpNum(lumpnum); return NULL; }

    double step = (double)samplerate / (double)OUT_RATE;
    double pos = 0.0;
    int oi = 0;
    while (pos < n8 && oi < outcap) {
        int i = (int)pos;
        double f = pos - i;
        int a = (int)pcm[i] - 128;
        int b = (i + 1 < n8) ? (int)pcm[i + 1] - 128 : a;
        // 8-bit (+-128) -> 16-bit at half scale (+-16384), leaving headroom so
        // several overlapping effects can sum in the mixer without clipping.
        int v = (int)((a + (b - a) * f) * 128.0);
        if (v > 32767) v = 32767; else if (v < -32768) v = -32768;
        out[oi++] = (int16_t)v;
        pos += step;
    }

    c->data = out;
    c->len = oi;
    W_ReleaseLumpNum(lumpnum);
    return c;
}

static cached_sfx_t *get_sfx(sfxinfo_t *sfxinfo)
{
    if (sfxinfo->driver_data == NULL) {
        cached_sfx_t *c = decode_sfx(sfxinfo->lumpnum);
        if (c == NULL)
            return NULL;
        sfxinfo->driver_data = c;
    }
    return (cached_sfx_t *)sfxinfo->driver_data;
}

// ---- I_* sound interface -------------------------------------------------

static void GetSfxLumpName(sfxinfo_t *sfx, char *buf, size_t buf_len)
{
    if (sfx->link != NULL)
        sfx = sfx->link;
    if (use_sfx_prefix)
        M_snprintf(buf, buf_len, "ds%s", sfx->name);
    else
        M_snprintf(buf, buf_len, "%s", sfx->name);
}

int I_GetSfxLumpNum(sfxinfo_t *sfx)
{
    char namebuf[9];
    GetSfxLumpName(sfx, namebuf, sizeof(namebuf));
    return W_CheckNumForName(namebuf);
}

void I_InitSound(boolean use_prefix)
{
    use_sfx_prefix = use_prefix;
    sound_on = snd_hal_ok();
    memset(channels, 0, sizeof(channels));
    printf("I_InitSound: snom halaudio, sfx %s\n", sound_on ? "on" : "off (no codec)");
}

void I_ShutdownSound(void)
{
    sound_on = false;
}

int I_StartSound(sfxinfo_t *sfxinfo, int channel, int vol, int sep)
{
    (void)sep;   // mono loudspeaker: stereo separation is ignored
    if (!sound_on || channel < 0 || channel >= NUM_CHANNELS)
        return -1;

    cached_sfx_t *c = get_sfx(sfxinfo);
    if (c == NULL || c->len == 0)
        return -1;

    channels[channel].data = c->data;
    channels[channel].len = c->len;
    channels[channel].pos = 0;
    channels[channel].vol = vol;
    channels[channel].playing = true;
    return channel;
}

void I_StopSound(int handle)
{
    if (handle >= 0 && handle < NUM_CHANNELS)
        channels[handle].playing = false;
}

boolean I_SoundIsPlaying(int handle)
{
    if (handle < 0 || handle >= NUM_CHANNELS)
        return false;
    return channels[handle].playing;
}

void I_UpdateSoundParams(int handle, int vol, int sep)
{
    (void)sep;
    if (handle >= 0 && handle < NUM_CHANNELS)
        channels[handle].vol = vol;
}

// Mix and stream however many 16 kHz samples have elapsed since the last call.
// Called per game tic (~35 Hz) from S_UpdateSounds; the snd_hal ring absorbs
// the coarse granularity and the pump thread provides the real audio clock.
void I_UpdateSound(void)
{
    static struct timeval prev;
    static int have_prev = 0;
    static double carry = 0.0;

    if (!sound_on)
        return;

    struct timeval now;
    gettimeofday(&now, NULL);
    if (!have_prev) { prev = now; have_prev = 1; return; }

    double dt = (now.tv_sec - prev.tv_sec) + (now.tv_usec - prev.tv_usec) / 1e6;
    prev = now;
    carry += dt * OUT_RATE;

    int nsamp = (int)carry;
    carry -= nsamp;
    if (nsamp <= 0)
        return;
    if (nsamp > 8000)          // cap a long stall at 0.5 s of catch-up
        nsamp = 8000;

    int16_t mixbuf[8000];
    for (int i = 0; i < nsamp; i++) {
        int acc = 0;
        for (int ch = 0; ch < NUM_CHANNELS; ch++) {
            channel_t *c = &channels[ch];
            if (!c->playing)
                continue;
            acc += (c->data[c->pos] * c->vol) >> 8;   // vol 0..127, extra -6 dB headroom
            if (++c->pos >= c->len)
                c->playing = false;
        }
        if (acc > 32767) acc = 32767; else if (acc < -32768) acc = -32768;
        mixbuf[i] = (int16_t)acc;
    }
    snd_hal_push16k(mixbuf, nsamp);
}

void I_PrecacheSounds(sfxinfo_t *sounds, int num_sounds)
{
    (void)sounds; (void)num_sounds;   // decoded lazily on first play
}

void I_BindSoundVariables(void)
{
    M_BindVariable("snd_sfxdevice",      &snd_sfxdevice);
    M_BindVariable("snd_musicdevice",    &snd_musicdevice);
    M_BindVariable("snd_samplerate",     &snd_samplerate);
    M_BindVariable("snd_cachesize",      &snd_cachesize);
    M_BindVariable("snd_maxslicetime_ms", &snd_maxslicetime_ms);
    M_BindVariable("snd_musiccmd",       &snd_musiccmd);
}

// ---- music: stubbed ------------------------------------------------------

void  I_InitMusic(void)                         {}
void  I_ShutdownMusic(void)                     {}
void  I_SetMusicVolume(int volume)              { (void)volume; }
void  I_PauseSong(void)                         {}
void  I_ResumeSong(void)                        {}
void *I_RegisterSong(void *data, int len)       { (void)data; (void)len; return NULL; }
void  I_UnRegisterSong(void *handle)            { (void)handle; }
void  I_PlaySong(void *handle, boolean looping) { (void)handle; (void)looping; }
void  I_StopSong(void)                          {}
boolean I_MusicIsPlaying(void)                  { return false; }
// I_InitTimidityConfig is provided by dummy.c when FEATURE_SOUND is off.
