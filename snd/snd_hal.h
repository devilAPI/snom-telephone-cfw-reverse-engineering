/* snd_hal - audio output for snom D375 games (Doom, NES).
 *
 * The D375 has no ALSA/OSS; real audio is the Broadcom "HAL Audio" codec at
 * /dev/halaudio, normally driven only by the closed media_daemon. This module
 * reproduces just enough of media_daemon's behaviour to get PCM out of the
 * loudspeaker while a takeover app owns the screen and keypad:
 *
 *   1. open /dev/halaudio and hold the codec at FULL power (so the APM
 *      interface / amp / DMA stay up after media_daemon dies),
 *   2. inject a SPEAKER keypress (evdev code 17) so the still-running
 *      media_daemon performs its own EPT hands-free bring-up (loudspeaker amp
 *      ON) -- the route then persists because we kill -9 with no cleanup,
 *   3. take over: kill lid + media_daemon (freeing /dev/fb0 and the keypad),
 *   4. run a background pump thread that streams 16 kHz mono S16 to the codec.
 *
 * See docs/sound.md for the full reverse-engineering writeup.
 */
#ifndef SND_HAL_H
#define SND_HAL_H

#ifdef __cplusplus
extern "C" {
#endif

/* Arm audio + hands-free, then take over (kill lid+media_daemon) and start the
 * pump. Call ONCE at startup, BEFORE opening /dev/fb0 or /dev/input/event0.
 * The daemon kill (the takeover) ALWAYS happens so the game gets the screen and
 * keypad; the return value only reports audio: 0 = audio running, -1 = no audio
 * (codec unavailable) but takeover still done. */
int  snd_hal_init(void);

/* Push mono signed-16-bit samples already at 16 kHz into the output ring. */
void snd_hal_push16k(const short *samples, int n);

/* Push mono signed-16-bit samples at an arbitrary rate; linearly resampled to
 * 16 kHz on the way in. State is carried across calls for click-free joins. */
void snd_hal_push_rate(const short *samples, int n, int srcrate);

/* 1 if the audio pump is running, 0 otherwise. */
int  snd_hal_ok(void);

/* Stop the pump and release the codec (best-effort; the phone reboots after a
 * game exits anyway). */
void snd_hal_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* SND_HAL_H */
