#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "common.h"
#include "adpcm.h"
#include "dswin.h"
#include "fmg_wrap.h"

static float lastLowPassCutoff;

void ADPCM_SetLowPassCutoff(float cutoffHz)
{
    lastLowPassCutoff = cutoffHz;
}

void FASTCALL ADPCM_Update(signed short *buffer,
                           DWORD length,
                           int rate,
                           BYTE *pbsp,
                           BYTE *pbep)
{
    (void)rate;
    (void)pbsp;
    (void)pbep;
    for (DWORD frame = 0; frame < length; ++frame) {
        buffer[frame * 2u] = 1000;
        buffer[frame * 2u + 1u] = 1000;
    }
}

void OPM_GenerateNative(int *buffer, int length)
{
    for (int frame = 0; frame < length; ++frame) {
        buffer[frame * 2] = 0;
        buffer[frame * 2 + 1] = 0;
    }
}

int OPM_GetNativeSampleRate(void)
{
    return 62500;
}

static void require(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(EXIT_FAILURE);
    }
    printf("PASS: %s\n", message);
}

int main(void)
{
    DSoundMonitorState before;
    DSoundMonitorState after;
    short output[256 * 2];

    // Bus gains are render-time parameters. They must affect audio that is
    // already queued, and the first sample after a change must not jump to
    // the new level.
    X68000_AudioRenderSetBusGains(0.0f, 0.0f);
    X68000_AudioRenderReset();
    X68000_AudioRenderSetHostRate(62500);
    X68000_AudioRenderProduce(1024);
    X68000_AudioRenderConsumeInt16(output, 64);
    const int levelBeforeChange = output[63 * 2];
    X68000_AudioRenderSetBusGains(-24.0f, 0.0f);
    X68000_AudioRenderConsumeInt16(output, 128);
    const int levelAfterChange = output[0];
    const int levelAtEndOfRamp = output[127 * 2];
    require(abs(levelAfterChange - levelBeforeChange) < 128,
            "a live trim ramps from the current rendered level");
    require(levelAtEndOfRamp > 0 && levelAtEndOfRamp < levelAfterChange,
            "a live trim reaches the new level without a discontinuity");

    X68000_AudioRenderSetBusGains(0.0f, 0.0f);
    X68000_AudioRenderReset();
    X68000_AudioRenderSetHostRate(48000);
    X68000_AudioRenderSetADPCMLowPassCutoff(12345.0f);
    X68000_AudioRenderProduce(2048);
    DSound_GetMonitorState(&before);

    require(before.dataBytes > 0, "render queue contains produced frames");

    X68000_AudioRenderSetBusGains(-6.0f, 6.0f);
    X68000_AudioRenderSetADPCMLowPassCutoff(20000.0f);
    DSound_GetMonitorState(&after);

    require(after.dataBytes == before.dataBytes,
            "live gain and low-pass changes preserve queued audio");
    require(fabsf(lastLowPassCutoff - 20000.0f) < 0.01f,
            "low-pass change reaches the audio core");

    X68000_AudioRenderConsumeInt16(output, 128);
    require(output[0] != 0 || output[1] != 0,
            "audio remains audible after live setting changes");

    // A brief producer stall must not turn into a hard zero at the device
    // boundary. The callback holds and fades the last rendered sample.
    X68000_AudioRenderReset();
    X68000_AudioRenderSetHostRate(62500);
    X68000_AudioRenderProduce(4);
    X68000_AudioRenderConsumeInt16(output, 2);
    X68000_AudioRenderConsumeInt16(output, 4);
    require(output[0] != 0 || output[1] != 0,
            "a short producer stall is concealed at the output boundary");

    puts("all tests passed");
    return EXIT_SUCCESS;
}
