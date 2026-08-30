#ifndef dswin_h__
#define dswin_h__

#include "common.h"

typedef struct {
	unsigned long ratebase;
	long preCounter;
	long bufferBytes;
	long dataBytes;
	long freeBytes;
	long readOffset;
	long writeOffset;
	unsigned int lastCallbackBytes;
	unsigned int refillCount;
	unsigned int directCallback;
} DSoundMonitorState;

int DSound_Init(unsigned long rate, unsigned long length);
int DSound_Cleanup(void);

void DSound_Play(void);
void DSound_Stop(void);
void FASTCALL DSound_Send0(long clock);

void DS_SetVolumeOPM(long vol);
void DS_SetVolumeADPCM(long vol);
void DS_SetVolumeMercury(long vol);
void DSound_GetMonitorState(DSoundMonitorState* state);

// Native YM2151 and ADPCM buses are handed to the platform callback through a
// lock-free queue. Runtime gains are applied and ramped by that callback, so a
// settings change never asks the emulator producer to rebuild queued audio.
void X68000_AudioRenderReset(void);
void X68000_AudioRenderSetHostRate(unsigned int rate);
void X68000_AudioRenderSetBusGains(float adpcmGainDB, float opmGainDB);
void X68000_AudioRenderSetADPCMLowPassCutoff(float cutoffHz);
unsigned int X68000_AudioRenderNativeSampleRate(void);
void X68000_AudioRenderProduce(unsigned int frames);
void X68000_AudioRenderConsumeFloat32(float* left, float* right, unsigned int frames);
void X68000_AudioRenderConsumeInterleavedFloat32(float* buffer, unsigned int frames);
void X68000_AudioRenderConsumeInt16(short* buffer, unsigned int frames);
void X68000_AudioRenderCaptureEnable(int enabled);
void X68000_AudioRenderCapture(const short* buffer, unsigned int frames);
unsigned int X68000_AudioRenderCaptureRead(short* buffer, unsigned int maximumFrames);

#endif /* dswin_h__ */
