/*
 * Copyright (c) 2003 NONAKA Kimihiro
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */

#include "windows.h"
#include "common.h"
#include "dswin.h"
#include "prop.h"
#include "adpcm.h"
#include "fmg_wrap.h"

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

// A native frame is one stereo sample generated at the YM2151 rate.  The
// power-of-two ring gives the AudioUnit callback a lock-free SPSC hand-off
// from the emulator thread without imposing a large fixed output latency.
#define X68_AUDIO_RING_CAPACITY 16384u
#define X68_AUDIO_RING_MASK (X68_AUDIO_RING_CAPACITY - 1u)
#define X68_AUDIO_DEFAULT_HOST_RATE 48000u
#define X68_AUDIO_MAX_FRAMES 4096u
#define X68_AUDIO_CAPTURE_RING_CAPACITY 32768u
#define X68_AUDIO_GAIN_Q16_ONE 65536
#define X68_AUDIO_BUS_GAIN_MIN_DB (-24.0f)
#define X68_AUDIO_BUS_GAIN_MAX_DB (24.0f)
#define X68_AUDIO_GAIN_RAMP_FRAMES 128u
#define X68_AUDIO_UNDERRUN_FADE_FRAMES 256u
#define X68_AUDIO_RECOVERY_RAMP_FRAMES 64u

// The producer owns the native-rate bus queue.  Keep FM and ADPCM separate
// until the consumer so a live trim is a render-time parameter and never
// requires the emulator to regenerate or rewrite queued audio.
static int16_t s_audioAdpcmRing[X68_AUDIO_RING_CAPACITY * 2u];
static int16_t s_audioOpmRing[X68_AUDIO_RING_CAPACITY * 2u];
static _Atomic uint64_t s_audioWriteFrame;
static _Atomic uint64_t s_audioReadFrame;
static _Atomic uint64_t s_audioUnderruns;
static _Atomic uint64_t s_audioOverruns;
static uint32_t s_audioNativeRate = 62500u;
static uint32_t s_audioHostRate = X68_AUDIO_DEFAULT_HOST_RATE;
static uint64_t s_audioPhaseStep = 0;
static uint64_t s_audioPhase = 0;
static int s_audioPhaseValid = FALSE;
static int16_t s_audioCaptureRing[X68_AUDIO_CAPTURE_RING_CAPACITY * 2u];
static _Atomic uint64_t s_audioCaptureWriteFrame;
static _Atomic uint64_t s_audioCaptureReadFrame;
static _Atomic int s_audioCaptureEnabled;
static _Atomic int32_t s_audioAdpcmGainQ16 = X68_AUDIO_GAIN_Q16_ONE;
static _Atomic int32_t s_audioOpmGainQ16 = X68_AUDIO_GAIN_Q16_ONE;
// These belong exclusively to the platform audio callback.  The UI only
// publishes atomic targets; the callback ramps to them while rendering.
static int32_t s_audioAdpcmGainCurrentQ16 = X68_AUDIO_GAIN_Q16_ONE;
static int32_t s_audioOpmGainCurrentQ16 = X68_AUDIO_GAIN_Q16_ONE;
static int32_t s_audioAdpcmGainTargetQ16 = X68_AUDIO_GAIN_Q16_ONE;
static int32_t s_audioOpmGainTargetQ16 = X68_AUDIO_GAIN_Q16_ONE;
static uint32_t s_audioAdpcmGainRampRemaining = 0;
static uint32_t s_audioOpmGainRampRemaining = 0;

// Output-side concealment for a short producer stall.  The old path wrote a
// hard zero as soon as the emulator thread missed one device period, which
// turned a scheduling hiccup into an audible click.  Hold and fade the last
// rendered sample, then crossfade back when queued audio resumes.
static float s_audioLastOutputLeft = 0.0f;
static float s_audioLastOutputRight = 0.0f;
static uint32_t s_audioUnderrunRun = 0;
static uint32_t s_audioRecoveryRampRemaining = 0;

static int16_t clamp16(int value);

DWORD ratebase = 62500;
long DSound_PreCounter = 0;
static volatile unsigned int s_dsound_last_callback_bytes = 0;
static volatile unsigned int s_dsound_refill_count = 0;

static uint32_t normalizeHostRate(unsigned int rate)
{
    if (rate < 8000u || rate > 192000u) {
        return X68_AUDIO_DEFAULT_HOST_RATE;
    }
    return (uint32_t)rate;
}

static void updatePhaseStep(void)
{
    s_audioPhaseStep = ((uint64_t)s_audioNativeRate << 32) / s_audioHostRate;
    if (s_audioPhaseStep == 0) {
        s_audioPhaseStep = 1;
    }
}

void X68000_AudioRenderReset(void)
{
    atomic_store_explicit(&s_audioWriteFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&s_audioReadFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&s_audioUnderruns, 0, memory_order_relaxed);
    atomic_store_explicit(&s_audioOverruns, 0, memory_order_relaxed);
    s_audioPhase = 0;
    s_audioPhaseValid = FALSE;
    s_audioAdpcmGainCurrentQ16 = atomic_load_explicit(&s_audioAdpcmGainQ16,
                                                      memory_order_relaxed);
    s_audioOpmGainCurrentQ16 = atomic_load_explicit(&s_audioOpmGainQ16,
                                                    memory_order_relaxed);
    s_audioAdpcmGainTargetQ16 = s_audioAdpcmGainCurrentQ16;
    s_audioOpmGainTargetQ16 = s_audioOpmGainCurrentQ16;
    s_audioAdpcmGainRampRemaining = 0;
    s_audioOpmGainRampRemaining = 0;
    s_audioLastOutputLeft = 0.0f;
    s_audioLastOutputRight = 0.0f;
    s_audioUnderrunRun = 0;
    s_audioRecoveryRampRemaining = 0;
}

void X68000_AudioRenderCaptureEnable(int enabled)
{
    // Recording is enabled only between callbacks. Reset the capture cursor
    // while disabled so the realtime callback never observes a half-reset
    // ring and never has to synchronize with Swift state.
    atomic_store_explicit(&s_audioCaptureEnabled, 0, memory_order_release);
    if (enabled) {
        const uint64_t writeFrame = atomic_load_explicit(&s_audioCaptureWriteFrame,
                                                          memory_order_acquire);
        atomic_store_explicit(&s_audioCaptureReadFrame, writeFrame,
                              memory_order_release);
    }
    atomic_store_explicit(&s_audioCaptureEnabled, enabled ? 1 : 0,
                          memory_order_release);
}

void X68000_AudioRenderCapture(const int16_t *buffer, unsigned int frames)
{
    if (!buffer || frames == 0
        || atomic_load_explicit(&s_audioCaptureEnabled, memory_order_acquire) == 0) {
        return;
    }

    uint64_t writeFrame = atomic_load_explicit(&s_audioCaptureWriteFrame,
                                                memory_order_relaxed);
    const uint64_t readFrame = atomic_load_explicit(&s_audioCaptureReadFrame,
                                                     memory_order_acquire);
    const uint64_t queuedFrames = writeFrame - readFrame;
    if (queuedFrames >= X68_AUDIO_CAPTURE_RING_CAPACITY) {
        return;
    }

    const uint32_t writableFrames =
        (uint32_t)(X68_AUDIO_CAPTURE_RING_CAPACITY - queuedFrames);
    const uint32_t framesToWrite = (frames < writableFrames) ? frames : writableFrames;
    for (uint32_t frame = 0; frame < framesToWrite; ++frame) {
        const uint32_t sourceIndex = frame * 2u;
        const uint32_t ringIndex = (uint32_t)(writeFrame + frame)
            & (X68_AUDIO_CAPTURE_RING_CAPACITY - 1u);
        s_audioCaptureRing[ringIndex * 2u] = buffer[sourceIndex];
        s_audioCaptureRing[ringIndex * 2u + 1u] = buffer[sourceIndex + 1u];
    }
    writeFrame += framesToWrite;
    atomic_store_explicit(&s_audioCaptureWriteFrame, writeFrame,
                          memory_order_release);
}

void X68000_AudioRenderCaptureFloat32(const float *buffer, unsigned int frames)
{
    if (!buffer || frames == 0
        || atomic_load_explicit(&s_audioCaptureEnabled, memory_order_acquire) == 0) {
        return;
    }

    uint64_t writeFrame = atomic_load_explicit(&s_audioCaptureWriteFrame,
                                                memory_order_relaxed);
    const uint64_t readFrame = atomic_load_explicit(&s_audioCaptureReadFrame,
                                                     memory_order_acquire);
    const uint64_t queuedFrames = writeFrame - readFrame;
    if (queuedFrames >= X68_AUDIO_CAPTURE_RING_CAPACITY) {
        return;
    }

    const uint32_t writableFrames =
        (uint32_t)(X68_AUDIO_CAPTURE_RING_CAPACITY - queuedFrames);
    const uint32_t framesToWrite = (frames < writableFrames) ? frames : writableFrames;
    for (uint32_t frame = 0; frame < framesToWrite; ++frame) {
        const uint32_t sourceIndex = frame * 2u;
        const uint32_t ringIndex = (uint32_t)(writeFrame + frame)
            & (X68_AUDIO_CAPTURE_RING_CAPACITY - 1u);
        s_audioCaptureRing[ringIndex * 2u] = clamp16(
            (int)lrintf(buffer[sourceIndex] * 32767.0f));
        s_audioCaptureRing[ringIndex * 2u + 1u] = clamp16(
            (int)lrintf(buffer[sourceIndex + 1u] * 32767.0f));
    }
    writeFrame += framesToWrite;
    atomic_store_explicit(&s_audioCaptureWriteFrame, writeFrame,
                          memory_order_release);
}

unsigned int X68000_AudioRenderCaptureRead(int16_t *buffer,
                                           unsigned int maximumFrames)
{
    if (!buffer || maximumFrames == 0) {
        return 0;
    }

    const uint64_t readFrame = atomic_load_explicit(&s_audioCaptureReadFrame,
                                                     memory_order_relaxed);
    const uint64_t writeFrame = atomic_load_explicit(&s_audioCaptureWriteFrame,
                                                      memory_order_acquire);
    const uint64_t queuedFrames = writeFrame - readFrame;
    const uint32_t framesToRead =
        (queuedFrames < maximumFrames) ? (uint32_t)queuedFrames : maximumFrames;
    for (uint32_t frame = 0; frame < framesToRead; ++frame) {
        const uint32_t ringIndex = (uint32_t)(readFrame + frame)
            & (X68_AUDIO_CAPTURE_RING_CAPACITY - 1u);
        buffer[frame * 2u] = s_audioCaptureRing[ringIndex * 2u];
        buffer[frame * 2u + 1u] = s_audioCaptureRing[ringIndex * 2u + 1u];
    }
    atomic_store_explicit(&s_audioCaptureReadFrame, readFrame + framesToRead,
                          memory_order_release);
    return framesToRead;
}

void X68000_AudioRenderSetHostRate(unsigned int rate)
{
    s_audioHostRate = normalizeHostRate(rate);
    updatePhaseStep();

    // Changing the device rate changes the interpolation phase. Discard the
    // old queue so a reconfiguration cannot replay frames at the wrong rate.
    const uint64_t writeFrame = atomic_load_explicit(&s_audioWriteFrame,
                                                      memory_order_acquire);
    atomic_store_explicit(&s_audioReadFrame, writeFrame, memory_order_release);
    s_audioPhase = writeFrame << 32;
    s_audioPhaseValid = TRUE;
}

unsigned int X68000_AudioRenderNativeSampleRate(void)
{
    return s_audioNativeRate;
}

static int32_t audioGainQ16(float gainDB)
{
    if (!isfinite(gainDB)) {
        gainDB = 0.0f;
    }
    if (gainDB < X68_AUDIO_BUS_GAIN_MIN_DB) {
        gainDB = X68_AUDIO_BUS_GAIN_MIN_DB;
    } else if (gainDB > X68_AUDIO_BUS_GAIN_MAX_DB) {
        gainDB = X68_AUDIO_BUS_GAIN_MAX_DB;
    }

    const double linearGain = pow(10.0, (double)gainDB / 20.0);
    return (int32_t)llround(linearGain * (double)X68_AUDIO_GAIN_Q16_ONE);
}

void X68000_AudioRenderSetBusGains(float adpcmGainDB, float opmGainDB)
{
    atomic_store_explicit(&s_audioAdpcmGainQ16,
                          audioGainQ16(adpcmGainDB),
                          memory_order_release);
    atomic_store_explicit(&s_audioOpmGainQ16,
                          audioGainQ16(opmGainDB),
                          memory_order_release);
}

void X68000_AudioRenderSetADPCMLowPassCutoff(float cutoffHz)
{
    ADPCM_SetLowPassCutoff(cutoffHz);
}

static int16_t clamp16(int value)
{
    if (value > 32767) {
        return 32767;
    }
    if (value < -32768) {
        return -32768;
    }
    return (int16_t)value;
}

static int32_t rampAudioGain(int32_t *currentQ16,
                             int32_t targetQ16,
                             uint32_t *remainingFrames)
{
    if (*remainingFrames == 0) {
        *currentQ16 = targetQ16;
        return *currentQ16;
    }

    const int64_t difference = (int64_t)targetQ16 - *currentQ16;
    int64_t step = difference / (int64_t)*remainingFrames;
    if (step == 0) {
        step = (difference > 0) ? 1 : -1;
    }
    *currentQ16 += (int32_t)step;
    --*remainingFrames;
    if (*remainingFrames == 0) {
        *currentQ16 = targetQ16;
    }
    return *currentQ16;
}

static void enqueueNativeFrames(const int16_t *adpcm,
                                const int *opm,
                                uint32_t frames)
{
    uint64_t writeFrame = atomic_load_explicit(&s_audioWriteFrame,
                                                memory_order_relaxed);
    const uint64_t readFrame = atomic_load_explicit(&s_audioReadFrame,
                                                     memory_order_acquire);
    const uint64_t queuedFrames = writeFrame - readFrame;
    if (queuedFrames >= X68_AUDIO_RING_CAPACITY) {
        atomic_fetch_add_explicit(&s_audioOverruns, 1, memory_order_relaxed);
        return;
    }

    const uint32_t writableFrames = (uint32_t)(X68_AUDIO_RING_CAPACITY - queuedFrames);
    const uint32_t framesToWrite = (frames < writableFrames) ? frames : writableFrames;

    for (uint32_t frame = 0; frame < framesToWrite; ++frame) {
        const int sampleIndex = (int)(frame * 2u);
        const uint32_t ringIndex = (uint32_t)(writeFrame + frame) & X68_AUDIO_RING_MASK;
        s_audioAdpcmRing[ringIndex * 2u] = adpcm[sampleIndex];
        s_audioAdpcmRing[ringIndex * 2u + 1u] = adpcm[sampleIndex + 1];
        s_audioOpmRing[ringIndex * 2u] = clamp16(opm[sampleIndex]);
        s_audioOpmRing[ringIndex * 2u + 1u] = clamp16(opm[sampleIndex + 1]);
    }

    writeFrame += framesToWrite;
    atomic_store_explicit(&s_audioWriteFrame, writeFrame, memory_order_release);

    if (framesToWrite != frames) {
        atomic_fetch_add_explicit(&s_audioOverruns, 1, memory_order_relaxed);
    }
}

void X68000_AudioRenderProduce(unsigned int frames)
{
    static int16_t adpcmBuffer[X68_AUDIO_MAX_FRAMES * 2u];
    static int opmBuffer[X68_AUDIO_MAX_FRAMES * 2u];

    while (frames > 0) {
        const uint32_t chunk = (frames > X68_AUDIO_MAX_FRAMES)
            ? X68_AUDIO_MAX_FRAMES
            : frames;
        const unsigned int bytes = chunk * sizeof(int16_t) * 2u;

        ADPCM_Update(adpcmBuffer,
                     chunk,
                     0,
                     (BYTE *)adpcmBuffer,
                     (BYTE *)adpcmBuffer + bytes);
        OPM_GenerateNative(opmBuffer, (int)chunk);
        enqueueNativeFrames(adpcmBuffer, opmBuffer, chunk);
        frames -= chunk;
    }
}

static void updateAudioGainTargets(void)
{
    const int32_t adpcmGainTargetQ16 = atomic_load_explicit(
        &s_audioAdpcmGainQ16, memory_order_acquire);
    const int32_t opmGainTargetQ16 = atomic_load_explicit(
        &s_audioOpmGainQ16, memory_order_acquire);

    if (adpcmGainTargetQ16 != s_audioAdpcmGainTargetQ16) {
        s_audioAdpcmGainTargetQ16 = adpcmGainTargetQ16;
        s_audioAdpcmGainRampRemaining = X68_AUDIO_GAIN_RAMP_FRAMES;
    }
    if (opmGainTargetQ16 != s_audioOpmGainTargetQ16) {
        s_audioOpmGainTargetQ16 = opmGainTargetQ16;
        s_audioOpmGainRampRemaining = X68_AUDIO_GAIN_RAMP_FRAMES;
    }
}

static int audioRenderNext(float *left, float *right)
{
    updateAudioGainTargets();
    const int32_t adpcmGainQ16 = rampAudioGain(
        &s_audioAdpcmGainCurrentQ16,
        s_audioAdpcmGainTargetQ16,
        &s_audioAdpcmGainRampRemaining);
    const int32_t opmGainQ16 = rampAudioGain(
        &s_audioOpmGainCurrentQ16,
        s_audioOpmGainTargetQ16,
        &s_audioOpmGainRampRemaining);

    uint64_t readFrame = atomic_load_explicit(&s_audioReadFrame,
                                               memory_order_acquire);
    if (!s_audioPhaseValid) {
        s_audioPhase = readFrame << 32;
        s_audioPhaseValid = TRUE;
    }

    uint64_t baseFrame = s_audioPhase >> 32;
    if (baseFrame < readFrame) {
        baseFrame = readFrame;
        s_audioPhase = readFrame << 32;
    }

    const uint64_t writeFrame = atomic_load_explicit(&s_audioWriteFrame,
                                                      memory_order_acquire);
    if (baseFrame + 1u >= writeFrame) {
        if (s_audioUnderrunRun < X68_AUDIO_UNDERRUN_FADE_FRAMES) {
            ++s_audioUnderrunRun;
        }
        const float fade = 1.0f -
            (float)s_audioUnderrunRun / (float)X68_AUDIO_UNDERRUN_FADE_FRAMES;
        *left = s_audioLastOutputLeft * fade;
        *right = s_audioLastOutputRight * fade;
        s_audioLastOutputLeft = *left;
        s_audioLastOutputRight = *right;
        s_audioRecoveryRampRemaining = 0;
        s_audioPhase = writeFrame << 32;
        atomic_store_explicit(&s_audioReadFrame, writeFrame, memory_order_release);
        return FALSE;
    }

    const uint32_t currentIndex = (uint32_t)baseFrame & X68_AUDIO_RING_MASK;
    const uint32_t nextIndex = (currentIndex + 1u) & X68_AUDIO_RING_MASK;
    const float fraction = (float)(s_audioPhase & UINT64_C(0xffffffff))
        / 4294967296.0f;
    const float adpcmLeft0 = (float)s_audioAdpcmRing[currentIndex * 2u];
    const float adpcmLeft1 = (float)s_audioAdpcmRing[nextIndex * 2u];
    const float adpcmRight0 = (float)s_audioAdpcmRing[currentIndex * 2u + 1u];
    const float adpcmRight1 = (float)s_audioAdpcmRing[nextIndex * 2u + 1u];
    const float opmLeft0 = (float)s_audioOpmRing[currentIndex * 2u];
    const float opmLeft1 = (float)s_audioOpmRing[nextIndex * 2u];
    const float opmRight0 = (float)s_audioOpmRing[currentIndex * 2u + 1u];
    const float opmRight1 = (float)s_audioOpmRing[nextIndex * 2u + 1u];

    const float adpcmLeft = (adpcmLeft0 + (adpcmLeft1 - adpcmLeft0) * fraction)
        / 32768.0f;
    const float adpcmRight = (adpcmRight0
        + (adpcmRight1 - adpcmRight0) * fraction) / 32768.0f;
    const float opmLeft = (opmLeft0 + (opmLeft1 - opmLeft0) * fraction)
        / 32768.0f;
    const float opmRight = (opmRight0 + (opmRight1 - opmRight0) * fraction)
        / 32768.0f;
    float renderedLeft = adpcmLeft * ((float)adpcmGainQ16 / X68_AUDIO_GAIN_Q16_ONE)
        + opmLeft * ((float)opmGainQ16 / X68_AUDIO_GAIN_Q16_ONE);
    float renderedRight = adpcmRight * ((float)adpcmGainQ16 / X68_AUDIO_GAIN_Q16_ONE)
        + opmRight * ((float)opmGainQ16 / X68_AUDIO_GAIN_Q16_ONE);

    if (s_audioUnderrunRun != 0) {
        s_audioRecoveryRampRemaining = X68_AUDIO_RECOVERY_RAMP_FRAMES;
        s_audioUnderrunRun = 0;
    }
    if (s_audioRecoveryRampRemaining != 0) {
        const float fraction = 1.0f /
            (float)s_audioRecoveryRampRemaining;
        renderedLeft = s_audioLastOutputLeft
            + (renderedLeft - s_audioLastOutputLeft) * fraction;
        renderedRight = s_audioLastOutputRight
            + (renderedRight - s_audioLastOutputRight) * fraction;
        --s_audioRecoveryRampRemaining;
    }

    *left = renderedLeft;
    *right = renderedRight;
    s_audioLastOutputLeft = renderedLeft;
    s_audioLastOutputRight = renderedRight;

    s_audioPhase += s_audioPhaseStep;
    const uint64_t consumedFrame = s_audioPhase >> 32;
    const uint64_t safeReadFrame = (consumedFrame > writeFrame)
        ? writeFrame
        : consumedFrame;
    if (safeReadFrame > readFrame) {
        atomic_store_explicit(&s_audioReadFrame, safeReadFrame, memory_order_release);
    }
    if (consumedFrame > writeFrame) {
        // At very low host rates one interpolation step can jump past the
        // currently available source. Keep the absolute phase from advancing
        // beyond the producer so the next callback can recover cleanly.
        s_audioPhase = writeFrame << 32;
    }
    return TRUE;
}

void X68000_AudioRenderConsumeFloat32(float *left,
                                      float *right,
                                      unsigned int frames)
{
    if (!left || !right) {
        return;
    }

    unsigned int underruns = 0;
    for (unsigned int frame = 0; frame < frames; ++frame) {
        if (!audioRenderNext(&left[frame], &right[frame])) {
            ++underruns;
        }
    }
    if (underruns != 0) {
        atomic_fetch_add_explicit(&s_audioUnderruns, 1, memory_order_relaxed);
    }
}

void X68000_AudioRenderConsumeInterleavedFloat32(float *buffer,
                                                 unsigned int frames)
{
    if (!buffer) {
        return;
    }

    unsigned int underruns = 0;
    for (unsigned int frame = 0; frame < frames; ++frame) {
        float left;
        float right;
        if (!audioRenderNext(&left, &right)) {
            ++underruns;
        }
        buffer[frame * 2u] = left;
        buffer[frame * 2u + 1u] = right;
    }
    if (underruns != 0) {
        atomic_fetch_add_explicit(&s_audioUnderruns, 1, memory_order_relaxed);
    }
}

void X68000_AudioRenderConsumeInt16(int16_t *buffer, unsigned int frames)
{
    if (!buffer) {
        return;
    }

    unsigned int underruns = 0;
    for (unsigned int frame = 0; frame < frames; ++frame) {
        float left;
        float right;
        if (!audioRenderNext(&left, &right)) {
            ++underruns;
        }
        buffer[frame * 2u] = clamp16((int)lrintf(left * 32767.0f));
        buffer[frame * 2u + 1u] = clamp16((int)lrintf(right * 32767.0f));
    }
    if (underruns != 0) {
        atomic_fetch_add_explicit(&s_audioUnderruns, 1, memory_order_relaxed);
    }
}

int DSound_Init(unsigned long rate, unsigned long buflen)
{
    (void)buflen;

    const int nativeRate = OPM_GetNativeSampleRate();
    s_audioNativeRate = (nativeRate > 0) ? (uint32_t)nativeRate : 62500u;
    ratebase = s_audioNativeRate;
    DSound_PreCounter = 0;
    s_dsound_last_callback_bytes = 0;
    s_dsound_refill_count = 0;

    X68000_AudioRenderReset();
    X68000_AudioRenderSetHostRate((unsigned int)rate);
    return TRUE;
}

void DSound_Play(void)
{
    ADPCM_SetVolume((BYTE)Config.PCM_VOL);
    OPM_SetVolume((BYTE)Config.OPM_VOL);
}

void DSound_Stop(void)
{
    ADPCM_SetVolume(0);
    OPM_SetVolume(0);
}

int DSound_Cleanup(void)
{
    X68000_AudioRenderReset();
    return TRUE;
}

void DSound_GetMonitorState(DSoundMonitorState *state)
{
    if (!state) {
        return;
    }

    const uint64_t writeFrame = atomic_load_explicit(&s_audioWriteFrame,
                                                      memory_order_acquire);
    const uint64_t readFrame = atomic_load_explicit(&s_audioReadFrame,
                                                     memory_order_acquire);
    const uint64_t queuedFrames = (writeFrame >= readFrame)
        ? (writeFrame - readFrame)
        : 0;
    const long bufferBytes = (long)(X68_AUDIO_RING_CAPACITY * sizeof(int16_t) * 2u);
    const long dataBytes = (long)((queuedFrames > X68_AUDIO_RING_CAPACITY
        ? X68_AUDIO_RING_CAPACITY
        : queuedFrames) * sizeof(int16_t) * 2u);

    state->ratebase = ratebase;
    state->preCounter = DSound_PreCounter;
    state->bufferBytes = bufferBytes;
    state->dataBytes = dataBytes;
    state->freeBytes = bufferBytes - dataBytes;
    state->readOffset = (long)((readFrame & X68_AUDIO_RING_MASK)
        * sizeof(int16_t) * 2u);
    state->writeOffset = (long)((writeFrame & X68_AUDIO_RING_MASK)
        * sizeof(int16_t) * 2u);
    state->lastCallbackBytes = s_dsound_last_callback_bytes;
    state->refillCount = s_dsound_refill_count;
    state->directCallback = 1;
}

void FASTCALL DSound_Send0(long clock)
{
    int length = 0;
    DSound_PreCounter += (long)(ratebase * clock);
    while (DSound_PreCounter >= 10000000L) {
        ++length;
        DSound_PreCounter -= 10000000L;
    }

    if (length > 0) {
        X68000_AudioRenderProduce((unsigned int)length);
    }
}

void X68000_AudioCallBack(void *buffer, const unsigned int sample)
{
    s_dsound_last_callback_bytes = sample * sizeof(int16_t) * 2u;
    X68000_AudioRenderConsumeInt16((int16_t *)buffer, sample);
}
