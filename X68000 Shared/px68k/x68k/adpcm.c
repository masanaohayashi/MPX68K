// ---------------------------------------------------------------------------------------
//  ADPCM.C - ADPCM (OKI MSM6258V)
//    な〜んか、X68Sound.dllに比べてカシャカシャした音になるんだよなぁ……
//    DSoundのクセってのもあるけど、それだけじゃなさそうな気もする
// ---------------------------------------------------------------------------------------

#include <math.h>
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>

#include "common.h"
#include "prop.h"
#include "pia.h"
#include "adpcm.h"
#include "dmac.h"
#include "adpcm_optimized.h"

// Forward declarations for optimized functions
#if ADPCM_ENABLE_OPTIMIZATIONS
static void ADPCM_InitTable_Optimized(void);
static void ADPCM_WriteOne_Optimized(int val);
#endif

#define ADPCM_BufSize      96000
#define ADPCMMAX           2047
#define ADPCMMIN          -2048
#define FM_IPSCALE         256L

#define OVERSAMPLEMUL      2

// X68000 hardware has a deliberately dark analog ADPCM output stage. The
// macOS setting keeps that character by default while allowing the cutoff to
// be opened up for modern audio devices.
#define ADPCM_LOWPASS_MIN_CUTOFF_HZ 3300.0f
#define ADPCM_LOWPASS_MAX_CUTOFF_HZ 20000.0f
#define ADPCM_LOWPASS_RAMP_FRAMES 256u

#define INTERPOLATE(y, x)	\
	(((((((-y[0]+3*y[1]-3*y[2]+y[3]) * x + FM_IPSCALE/2) / FM_IPSCALE \
	+ 3 * (y[0]-2*y[1]+y[2])) * x + FM_IPSCALE/2) / FM_IPSCALE \
	- 2*y[0]-3*y[1]+6*y[2]-y[3]) * x + 3*FM_IPSCALE) / (6*FM_IPSCALE) + y[1])

static int ADPCM_VolumeShift = 65536;
static const int index_shift[16] = {
	-1*16, -1*16, -1*16, -1*16, 2*16, 4*16, 6*16, 8*16,
	-1*16, -1*16, -1*16, -1*16, 2*16, 4*16, 6*16, 8*16 };
static const int ADPCM_Clocks[8] = {
	93750, 125000, 187500, 125000, 46875, 62500, 93750, 62500 };
static int dif_table[49*16];
static signed short ADPCM_BufR[ADPCM_BufSize];
static signed short ADPCM_BufL[ADPCM_BufSize];

static long ADPCM_WrPtr = 0;
static long ADPCM_RdPtr = 0;
static DWORD ADPCM_SampleRate = 44100*12;
       DWORD ADPCM_ClockRate = 7800*12;
static DWORD ADPCM_Count = 0;
static int ADPCM_Step = 0;
static int ADPCM_Out = 0;
static BYTE ADPCM_Playing = 0;
       BYTE ADPCM_Clock = 0;
static long long ADPCM_PreCounter = 0;
static int ADPCM_DmaReady = 0;
static int ADPCM_DifBuf = 0;


static int ADPCM_Pan = 0x00;
static int OldR = 0, OldL = 0;
static int OutsIp[4];
static int OutsIpR[4];
static int OutsIpL[4];

typedef struct {
    float x1;
    float x2;
    float y1;
    float y2;
} ADPCMFilterState;

typedef struct {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
} ADPCMFilterCoefficients;

// The settings thread calculates and publishes coefficients. The emulator
// thread only loads them and ramps between coefficient sets; it never performs
// trigonometry while producing audio and never takes a lock.
static _Atomic uint32_t ADPCM_LowPassCutoffBits;
static _Atomic uint32_t ADPCM_LowPassB0Bits;
static _Atomic uint32_t ADPCM_LowPassB1Bits;
static _Atomic uint32_t ADPCM_LowPassB2Bits;
static _Atomic uint32_t ADPCM_LowPassA1Bits;
static _Atomic uint32_t ADPCM_LowPassA2Bits;
static _Atomic uint32_t ADPCM_LowPassSampleRate = 62500u;
static uint32_t ADPCM_LowPassTargetBits = 0;
static uint32_t ADPCM_LowPassRampRemaining = 0;
static ADPCMFilterCoefficients ADPCM_LowPassCurrent;
static ADPCMFilterCoefficients ADPCM_LowPassTarget;
static ADPCMFilterState ADPCM_LowPassRight;
static ADPCMFilterState ADPCM_LowPassLeft;

// DC blocking filter state (1st order high-pass)
static double dc_filter_x1 = 0.0;  // Previous input
static double dc_filter_y1 = 0.0;  // Previous output
static const double DC_FILTER_ALPHA = 0.995;  // High-pass cutoff ~3.5Hz at 22kHz

static uint32_t ADPCM_FloatToBits(float value)
{
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float ADPCM_BitsToFloat(uint32_t bits)
{
    float value = ADPCM_LOWPASS_MIN_CUTOFF_HZ;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static float ADPCM_NormalizeLowPassCutoff(float cutoffHz)
{
    if (!isfinite(cutoffHz)) {
        return ADPCM_LOWPASS_MIN_CUTOFF_HZ;
    }
    if (cutoffHz < ADPCM_LOWPASS_MIN_CUTOFF_HZ) {
        return ADPCM_LOWPASS_MIN_CUTOFF_HZ;
    }
    if (cutoffHz > ADPCM_LOWPASS_MAX_CUTOFF_HZ) {
        return ADPCM_LOWPASS_MAX_CUTOFF_HZ;
    }
    return cutoffHz;
}

static void ADPCM_CalculateLowPassCoefficients(
    float cutoffHz,
    ADPCMFilterCoefficients *coefficients)
{
    if (!coefficients) {
        return;
    }

    const uint32_t configuredSampleRate = atomic_load_explicit(
        &ADPCM_LowPassSampleRate, memory_order_relaxed);
    const double sampleRate = (configuredSampleRate > 0)
        ? (double)configuredSampleRate
        : 62500.0;
    const double requestedCutoff =
        (double)ADPCM_NormalizeLowPassCutoff(cutoffHz);
    const double maximumCutoff = fmin((double)ADPCM_LOWPASS_MAX_CUTOFF_HZ,
                                      sampleRate * 0.49);
    const double minimumCutoff = fmin((double)ADPCM_LOWPASS_MIN_CUTOFF_HZ,
                                      maximumCutoff);
    const double cutoff = fmin(fmax(minimumCutoff, requestedCutoff),
                               maximumCutoff);
    const double angularFrequency = 2.0 * acos(-1.0) * cutoff / sampleRate;
    const double cosine = cos(angularFrequency);
    const double alpha = sin(angularFrequency) /
        (2.0 * 0.70710678118654752440);
    const double a0 = 1.0 + alpha;

    // A 2-pole Butterworth low-pass gives a smooth, continuously adjustable
    // approximation of the X68000's external analog ADPCM filter.
    coefficients->b0 = (float)(((1.0 - cosine) * 0.5) / a0);
    coefficients->b1 = (float)((1.0 - cosine) / a0);
    coefficients->b2 = coefficients->b0;
    coefficients->a1 = (float)((-2.0 * cosine) / a0);
    coefficients->a2 = (float)((1.0 - alpha) / a0);
}

void ADPCM_SetLowPassCutoff(float cutoffHz)
{
    cutoffHz = ADPCM_NormalizeLowPassCutoff(cutoffHz);

    ADPCMFilterCoefficients coefficients;
    ADPCM_CalculateLowPassCoefficients(cutoffHz, &coefficients);
    // Publish the complete coefficient set before publishing the cutoff key.
    // The acquire load of the key in the producer makes this one coherent
    // configuration visible without a mutex.
    atomic_store_explicit(&ADPCM_LowPassB0Bits,
                          ADPCM_FloatToBits(coefficients.b0),
                          memory_order_relaxed);
    atomic_store_explicit(&ADPCM_LowPassB1Bits,
                          ADPCM_FloatToBits(coefficients.b1),
                          memory_order_relaxed);
    atomic_store_explicit(&ADPCM_LowPassB2Bits,
                          ADPCM_FloatToBits(coefficients.b2),
                          memory_order_relaxed);
    atomic_store_explicit(&ADPCM_LowPassA1Bits,
                          ADPCM_FloatToBits(coefficients.a1),
                          memory_order_relaxed);
    atomic_store_explicit(&ADPCM_LowPassA2Bits,
                          ADPCM_FloatToBits(coefficients.a2),
                          memory_order_relaxed);
    atomic_store_explicit(&ADPCM_LowPassCutoffBits,
                          ADPCM_FloatToBits(cutoffHz),
                          memory_order_release);
}

static void ADPCM_UpdateLowPassCoefficients(void)
{
    uint32_t cutoffBits = atomic_load_explicit(&ADPCM_LowPassCutoffBits,
                                               memory_order_acquire);
    if (cutoffBits == 0) {
        cutoffBits = ADPCM_FloatToBits(ADPCM_LOWPASS_MIN_CUTOFF_HZ);
    }
    if (cutoffBits == ADPCM_LowPassTargetBits) {
        return;
    }

    ADPCM_LowPassTarget.b0 = ADPCM_BitsToFloat(atomic_load_explicit(
        &ADPCM_LowPassB0Bits, memory_order_relaxed));
    ADPCM_LowPassTarget.b1 = ADPCM_BitsToFloat(atomic_load_explicit(
        &ADPCM_LowPassB1Bits, memory_order_relaxed));
    ADPCM_LowPassTarget.b2 = ADPCM_BitsToFloat(atomic_load_explicit(
        &ADPCM_LowPassB2Bits, memory_order_relaxed));
    ADPCM_LowPassTarget.a1 = ADPCM_BitsToFloat(atomic_load_explicit(
        &ADPCM_LowPassA1Bits, memory_order_relaxed));
    ADPCM_LowPassTarget.a2 = ADPCM_BitsToFloat(atomic_load_explicit(
        &ADPCM_LowPassA2Bits, memory_order_relaxed));

    if (ADPCM_LowPassTargetBits == 0) {
        ADPCM_LowPassCurrent = ADPCM_LowPassTarget;
        ADPCM_LowPassRampRemaining = 0;
    } else {
        ADPCM_LowPassRampRemaining = ADPCM_LOWPASS_RAMP_FRAMES;
    }
    ADPCM_LowPassTargetBits = cutoffBits;
}

static void ADPCM_AdvanceLowPassCoefficients(void)
{
    if (ADPCM_LowPassRampRemaining == 0) {
        return;
    }

    const float fraction = 1.0f / (float)ADPCM_LowPassRampRemaining;
    ADPCM_LowPassCurrent.b0 +=
        (ADPCM_LowPassTarget.b0 - ADPCM_LowPassCurrent.b0) * fraction;
    ADPCM_LowPassCurrent.b1 +=
        (ADPCM_LowPassTarget.b1 - ADPCM_LowPassCurrent.b1) * fraction;
    ADPCM_LowPassCurrent.b2 +=
        (ADPCM_LowPassTarget.b2 - ADPCM_LowPassCurrent.b2) * fraction;
    ADPCM_LowPassCurrent.a1 +=
        (ADPCM_LowPassTarget.a1 - ADPCM_LowPassCurrent.a1) * fraction;
    ADPCM_LowPassCurrent.a2 +=
        (ADPCM_LowPassTarget.a2 - ADPCM_LowPassCurrent.a2) * fraction;
    --ADPCM_LowPassRampRemaining;
    if (ADPCM_LowPassRampRemaining == 0) {
        ADPCM_LowPassCurrent = ADPCM_LowPassTarget;
    }
}

static int ADPCM_ApplyLowPass(int sample, ADPCMFilterState *state)
{
    const float input = (float)sample;
    const float output = ADPCM_LowPassCurrent.b0 * input
        + ADPCM_LowPassCurrent.b1 * state->x1
        + ADPCM_LowPassCurrent.b2 * state->x2
        - ADPCM_LowPassCurrent.a1 * state->y1
        - ADPCM_LowPassCurrent.a2 * state->y2;

    state->x2 = state->x1;
    state->x1 = input;
    state->y2 = state->y1;
    state->y1 = output;
    return (int)lrintf(output);
}

int ADPCM_IsReady(void)
{
	// 常にREADYを返し、DMA側でデータ要求を止めない（旧来動作）
	return 1;
}


// -----------------------------------------------------------------------
//   てーぶる初期化
// -----------------------------------------------------------------------
void ADPCM_GetMonitorState(ADPCMMonitorState* state)
{
	if (!state) return;
	state->writePtr = ADPCM_WrPtr;
	state->readPtr = ADPCM_RdPtr;
	state->bufferSize = ADPCM_BufSize;
	state->sampleRate = ADPCM_SampleRate;
	state->clockRate = ADPCM_ClockRate;
	state->count = ADPCM_Count;
	state->preCounter = ADPCM_PreCounter;
	state->step = ADPCM_Step;
	state->output = ADPCM_Out;
	state->playing = ADPCM_Playing;
	state->dmaReady = ADPCM_DmaReady;
	state->diffBuffer = ADPCM_DifBuf;
	state->pan = ADPCM_Pan;
	state->volumeShift = ADPCM_VolumeShift;
	state->oldLeft = OldL;
	state->oldRight = OldR;
}

static void ADPCM_InitTable(void)
{
#if ADPCM_ENABLE_OPTIMIZATIONS && ADPCM_OPTIMIZATION_LEVEL >= 1
	ADPCM_InitTable_Optimized();
#endif

	int step, n;
	double val;
	static int bit[16][4] =
	{
		{ 1, 0, 0, 0}, { 1, 0, 0, 1}, { 1, 0, 1, 0}, { 1, 0, 1, 1},
		{ 1, 1, 0, 0}, { 1, 1, 0, 1}, { 1, 1, 1, 0}, { 1, 1, 1, 1},
		{-1, 0, 0, 0}, {-1, 0, 0, 1}, {-1, 0, 1, 0}, {-1, 0, 1, 1},
		{-1, 1, 0, 0}, {-1, 1, 0, 1}, {-1, 1, 1, 0}, {-1, 1, 1, 1}
	};

	for (step=0; step<=48; step++) {
		val = floor(16.0 * pow ((double)1.1, (double)step));
		for (n=0; n<16; n++) {
			dif_table[step*16+n] = bit[n][0] *
			   (int)(val   * bit[n][1] +
				 val/2 * bit[n][2] +
				 val/4 * bit[n][3] +
				 val/8);
		}
	}
}


#define LimitMix(val) { \
	if ( val > 0x7fff )      val = 0x7fff; \
	else if ( val < -0x8000 ) val = -0x8000; \
}

// -----------------------------------------------------------------------
//   MPUクロック経過分だけバッファにデータを溜めておく
// -----------------------------------------------------------------------
void FASTCALL ADPCM_PreUpdate(DWORD clock)
{
	/*if (!ADPCM_Playing) return;*/
	ADPCM_PreCounter += ((ADPCM_ClockRate/24)*clock);
	while ( ADPCM_PreCounter>=10000000L ) {		// ↓ データの送りすぎ防止（A-JAX）。200サンプリングくらいまでは許そう…。
		ADPCM_DifBuf -= ( (ADPCM_SampleRate*400)/ADPCM_ClockRate );
		if ( ADPCM_DifBuf<=0 ) {
			ADPCM_DifBuf = 0;
			DMA_Exec(3);
		}
		ADPCM_PreCounter -= 10000000L;
	}
}


// -----------------------------------------------------------------------
//   DSoundが指定してくる分だけバッファにデータを書き出す
// -----------------------------------------------------------------------
void FASTCALL ADPCM_Update(signed short *buffer, DWORD length, int rate, BYTE *pbsp, BYTE *pbep)
{
	int outs;
	signed int outl, outr;

	if ( length<=0 ) return;
    ADPCM_UpdateLowPassCoefficients();

	while ( length ) {
		ADPCM_AdvanceLowPassCoefficients();
		if (buffer >= (signed short *)pbep) {
			buffer = (signed short *)pbsp;
		}
		int tmpl, tmpr;

	if ( (ADPCM_WrPtr==ADPCM_RdPtr)&&(!(DMA[3].CCR&0x40)) ) DMA_Exec(3);
		if ( ADPCM_WrPtr!=ADPCM_RdPtr ) {
			OldR = outr = ADPCM_BufL[ADPCM_RdPtr];
			OldL = outl = ADPCM_BufR[ADPCM_RdPtr];
			ADPCM_RdPtr++;
			if ( ADPCM_RdPtr>=ADPCM_BufSize ) ADPCM_RdPtr = 0;
		} else {
			// Fix: Output silence when no audio data is available
			// to prevent periodic noise from old audio data
			if ( !ADPCM_Playing ) {
				outr = 0;
				outl = 0;
				OldR = 0;
				OldL = 0;
			} else {
				outr = OldR;
				outl = OldL;
			}
		}

        outs = ADPCM_ApplyLowPass((int)(outr*ADPCM_VolumeShift),
                                   &ADPCM_LowPassRight);

		OutsIpR[0] = OutsIpR[1];
		OutsIpR[1] = OutsIpR[2];
		OutsIpR[2] = OutsIpR[3];
		OutsIpR[3] = outs;

        outs = ADPCM_ApplyLowPass((int)(outl*ADPCM_VolumeShift),
                                   &ADPCM_LowPassLeft);

		OutsIpL[0] = OutsIpL[1];
		OutsIpL[1] = OutsIpL[2];
		OutsIpL[2] = OutsIpL[3];
		OutsIpL[3] = outs;

#if 1
		tmpr = INTERPOLATE(OutsIpR, 0);
		if ( tmpr>32767 ) tmpr = 32767; else if ( tmpr<(-32768) ) tmpr = -32768;
		*(buffer++) = (short)tmpr;
		tmpl = INTERPOLATE(OutsIpL, 0);
		if ( tmpl>32767 ) tmpl = 32767; else if ( tmpl<(-32768) ) tmpl = -32768;
		*(buffer++) = (short)tmpl;
		// PSP以外はrateは0
		if (rate == 22050) {
			if (buffer >= (signed short *)pbep) {
				buffer = (signed short *)pbsp;
			}
			*(buffer++) = (short)tmpr;
			*(buffer++) = (short)tmpl;
		} else if (rate == 11025) {
			if (buffer >= (signed short *)pbep) {
				buffer = (signed short *)pbsp;
			}
			*(buffer++) = (short)tmpr;
			*(buffer++) = (short)tmpl;
			if (buffer >= (signed short *)pbep) {
				buffer = (signed short *)pbsp;
			}
			*(buffer++) = (short)tmpr;
			*(buffer++) = (short)tmpl;
			if (buffer >= (signed short *)pbep) {
				buffer = (signed short *)pbsp;
			}
			*(buffer++) = (short)tmpr;
			*(buffer++) = (short)tmpl;
		}
#else
		*(buffer++) = (short)OutsIpR[3];
		*(buffer++) = (short)OutsIpL[3];
#endif

		length--;
	}

	ADPCM_DifBuf = (int)(ADPCM_WrPtr-ADPCM_RdPtr);
	if ( ADPCM_DifBuf<0 ) ADPCM_DifBuf += ADPCM_BufSize;

}


// -----------------------------------------------------------------------
//   1nibble（4bit）をデコード
// -----------------------------------------------------------------------
INLINE void ADPCM_WriteOne(int val)
{
#if ADPCM_ENABLE_OPTIMIZATIONS && ADPCM_OPTIMIZATION_LEVEL >= 1
	ADPCM_WriteOne_Optimized(val);
	return;
#endif

	ADPCM_Out += dif_table[ADPCM_Step+val];
	if ( ADPCM_Out>ADPCMMAX ) ADPCM_Out = ADPCMMAX; else if ( ADPCM_Out<ADPCMMIN ) ADPCM_Out = ADPCMMIN;
	
	ADPCM_Step += index_shift[val];
	if ( ADPCM_Step>(48*16) ) ADPCM_Step = (48*16); else if ( ADPCM_Step<0 ) ADPCM_Step = 0;

	if ( OutsIp[0]==-1 ) {
		OutsIp[0] =
		OutsIp[1] =
		OutsIp[2] =
		OutsIp[3] = ADPCM_Out;
	} else {
		OutsIp[0] = OutsIp[1];
		OutsIp[1] = OutsIp[2];
		OutsIp[2] = OutsIp[3];
		OutsIp[3] = ADPCM_Out;
	}

	while ( ADPCM_SampleRate>ADPCM_Count ) {
		if ( ADPCM_Playing ) {
			int ratio = (((ADPCM_Count/100)*FM_IPSCALE)/(ADPCM_SampleRate/100));
			int tmp = INTERPOLATE(OutsIp, ratio);
			if ( tmp>ADPCMMAX ) tmp = ADPCMMAX; else if ( tmp<ADPCMMIN ) tmp = ADPCMMIN;
			if ( !(ADPCM_Pan&1) )
				ADPCM_BufR[ADPCM_WrPtr] = (short)tmp;
			else
				ADPCM_BufR[ADPCM_WrPtr] = 0;
			if ( !(ADPCM_Pan&2) )
				ADPCM_BufL[ADPCM_WrPtr++] = (short)tmp;
			else
				ADPCM_BufL[ADPCM_WrPtr++] = 0;
			if ( ADPCM_WrPtr>=ADPCM_BufSize ) ADPCM_WrPtr = 0;
		}
		ADPCM_Count += ADPCM_ClockRate;
	}
	ADPCM_Count -= ADPCM_SampleRate;
}


// -----------------------------------------------------------------------
//   I/O Write
// -----------------------------------------------------------------------
void FASTCALL ADPCM_Write(DWORD adr, BYTE data)
{
	if ( adr==0xe92001 ) {
		if ( data&1 ) {
			ADPCM_Playing = 0;
			// Original behavior: only clear last outputs to avoid clicks
			OldL = OldR = 0;
			ADPCM_DmaReady = 0;
			ADPCM_PreCounter = 0;
			ADPCM_DifBuf = 0;
			ADPCM_RdPtr = ADPCM_WrPtr;
		} else if ( data&2 ) {
			if ( !ADPCM_Playing ) {
				ADPCM_Step = 0;
				ADPCM_Out = 0;
				// Fix: Initialize with silence instead of -2 to prevent startup noise
				OldL = OldR = 0;
				ADPCM_Playing = 1;
				ADPCM_Count = 0;
				ADPCM_PreCounter = 0;
				ADPCM_DmaReady = 64;		// 初期バーストを控えめに
				ADPCM_DifBuf = 0;
				ADPCM_RdPtr = ADPCM_WrPtr;
			}
			OutsIp[0] = OutsIp[1] = OutsIp[2] = OutsIp[3] = -1;
		}
	} else if ( adr==0xe92003 ) {
		if ( ADPCM_Playing ) {
			ADPCM_WriteOne((int)(data&15));
			ADPCM_WriteOne((int)((data>>4)&15));
		}
	}
}


// -----------------------------------------------------------------------
//   I/O Read（ステータスチェック）
// -----------------------------------------------------------------------
BYTE FASTCALL ADPCM_Read(DWORD adr)
{
	if ( adr==0xe92001 )
		return ((ADPCM_Playing)?0xc0:0x40);
	else
		return 0x00;
}


// -----------------------------------------------------------------------
//   ぼりゅーむ
// -----------------------------------------------------------------------
void ADPCM_SetVolume(BYTE vol)
{
	if ( vol>16 ) vol=16;
//	if ( vol<0  ) vol=0;

	if ( vol )
		ADPCM_VolumeShift = (int)((double)16/pow(1.189207115, (16-vol)));
	else
		ADPCM_VolumeShift = 0;		// Mute
}


// -----------------------------------------------------------------------
//   Panning
// -----------------------------------------------------------------------
void ADPCM_SetPan(int n)
{
	if ( (ADPCM_Pan&0x0c)!=(n&0x0c) ) {
		ADPCM_Count = 0;
		ADPCM_Clock = (ADPCM_Clock&4)|((n>>2)&3);
		ADPCM_ClockRate = ADPCM_Clocks[ADPCM_Clock];
		ADPCM_PreCounter = 0;
		ADPCM_DmaReady = 0;
	}
	ADPCM_Pan = n;
}


// -----------------------------------------------------------------------
//   Clock
// -----------------------------------------------------------------------
void ADPCM_SetClock(int n)
{
	if ( (ADPCM_Clock&4)!=n ) {
		ADPCM_Count = 0;
		ADPCM_Clock = n|((ADPCM_Pan>>2)&3);
		ADPCM_ClockRate = ADPCM_Clocks[ADPCM_Clock];
		ADPCM_PreCounter = 0;
		ADPCM_DmaReady = 0;
	}
}


// -----------------------------------------------------------------------
//   初期化
// -----------------------------------------------------------------------
void ADPCM_Init(DWORD samplerate)
{
	ADPCM_WrPtr = 0;
	ADPCM_RdPtr = 0;
	ADPCM_Out = 0;
	ADPCM_Step = 0;
	ADPCM_Playing = 0;
	ADPCM_Count = 0;
	ADPCM_SampleRate = (samplerate*12);
	atomic_store_explicit(&ADPCM_LowPassSampleRate,
	                      (samplerate > 0) ? samplerate : 62500,
	                      memory_order_relaxed);
	ADPCM_PreCounter = 0;
	ADPCM_DmaReady = 0;
	ADPCM_DifBuf = 0;
    memset(&ADPCM_LowPassRight, 0, sizeof(ADPCM_LowPassRight));
    memset(&ADPCM_LowPassLeft, 0, sizeof(ADPCM_LowPassLeft));
	ADPCM_LowPassTargetBits = 0;
	ADPCM_LowPassRampRemaining = 0;
	uint32_t cutoffBits = atomic_load_explicit(&ADPCM_LowPassCutoffBits,
	                                           memory_order_relaxed);
	if (cutoffBits == 0) {
		cutoffBits = ADPCM_FloatToBits(ADPCM_LOWPASS_MIN_CUTOFF_HZ);
	}
	ADPCM_SetLowPassCutoff(ADPCM_BitsToFloat(cutoffBits));
	ADPCM_UpdateLowPassCoefficients();
	ADPCM_LowPassCurrent = ADPCM_LowPassTarget;
	ADPCM_LowPassRampRemaining = 0;
	OutsIp[0] = OutsIp[1] = OutsIp[2] = OutsIp[3] = -1;
	OutsIpR[0] = OutsIpR[1] = OutsIpR[2] = OutsIpR[3] = 0;
	OutsIpL[0] = OutsIpL[1] = OutsIpL[2] = OutsIpL[3] = 0;
	OldL = OldR = 0;

	ADPCM_SetPan(0x0b);
	ADPCM_InitTable();
}

// Include optimized implementations
#if ADPCM_ENABLE_OPTIMIZATIONS
#include "adpcm_optimized_safe.c"
#endif
