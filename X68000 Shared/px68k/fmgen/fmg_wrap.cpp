// YM2151 wrapper used by the X68000 core.
//
// The emulator historically used the old FMGen OPM implementation. The
// actual X68000 sound chip is a YM2151 clocked at 4 MHz, so the ymfm OPM core
// is used here and produces its native 62,500 Hz stream. The audio renderer
// performs the host-rate conversion after the emulator has mixed its native
// audio frames.

#include <cmath>
#include <cstdint>
#include <memory>

// Keep the ymfm implementation in the source list that already builds this
// wrapper. This avoids making the generated Xcode project depend on a source
// file inside the submodule while still keeping ymfm itself as a submodule.
#include "../../../third_party/ymfm/src/ymfm_opm.cpp"

extern "C" {

#include "common.h"
#include "winx68k.h"
#include "dswin.h"
#include "prop.h"
#include "mfp.h"
#include "adpcm.h"
#include "fdc.h"
#include "fmg_wrap.h"

}

namespace {

class MPX68KYM2151 final : public ymfm::ymfm_interface {
public:
    explicit MPX68KYM2151(uint32_t clock)
        : m_chip(*this), m_nativeRate(m_chip.sample_rate(clock)) {
        m_chip.reset();
    }

    ymfm::ym2151& chip() { return m_chip; }
    const ymfm::ym2151& chip() const { return m_chip; }

    uint32_t nativeRate() const { return m_nativeRate; }

    void reset() {
        m_timerClocks[0] = -1;
        m_timerClocks[1] = -1;
        m_busyClocks = 0;
        m_chip.reset();
    }

    void setVolume(BYTE volume) {
        // Config.OPM_VOL uses the original 0..16 FMGen scale. FMGen's
        // SetVolume() converts its dB value with 10^(dB/40), so keep that
        // curve when applying the setting to ymfm's 16-bit DAC output.
        if (volume == 0) {
            m_volume = 0.0;
            return;
        }
        const int attenuationDB = (16 - static_cast<int>(volume)) * 4;
        m_volume = std::pow(10.0, -static_cast<double>(attenuationDB) / 40.0);
    }

    void generate(int* buffer, int length) {
        if (!buffer || length <= 0) {
            return;
        }

        for (int index = 0; index < length; ++index) {
            ymfm::ym2151::output_data output;
            m_chip.generate(&output, 1);
            clockCallbacks();

            buffer[index * 2] = static_cast<int>(std::lround(
                static_cast<double>(output.data[0]) * m_volume));
            buffer[index * 2 + 1] = static_cast<int>(std::lround(
                static_cast<double>(output.data[1]) * m_volume));
        }
    }

    void ymfm_external_write(ymfm::access_class type,
                             uint32_t address,
                             uint8_t data) override {
        if (type != ymfm::ACCESS_IO || address != 0) {
            return;
        }

        // YM2151 register 0x1B exposes CT1/CT2 on its two external output
        // pins. ymfm passes those two bits as a compact value (data >> 6).
        // CT1 controls the X68000 ADPCM clock and CT2 controls FDC ready.
        ADPCM_SetClock(((data >> 1) & 1) << 2);
        FDC_SetForceReady(data & 1);
    }

    void ymfm_set_timer(uint32_t timer,
                        int32_t durationInClocks) override {
        if (timer < 2) {
            m_timerClocks[timer] = durationInClocks;
        }
    }

    void ymfm_set_busy_end(uint32_t clocks) override {
        m_busyClocks = clocks;
    }

    bool ymfm_is_busy() override {
        return m_busyClocks > 0;
    }

    void ymfm_update_irq(bool asserted) override {
        if (asserted) {
            MFP_Int(12);
        }
    }

private:
    void clockCallbacks() {
        // One generated sample advances the OPM core by prescale*operators
        // clocks: 2*32 = 64 for YM2151. Timers are serviced on the same
        // timeline as the native audio stream.
        constexpr int32_t clocksPerSample = 64;

        if (m_busyClocks > 0) {
            m_busyClocks = (m_busyClocks > clocksPerSample)
                ? m_busyClocks - clocksPerSample
                : 0;
        }

        for (uint32_t timer = 0; timer < 2; ++timer) {
            if (m_timerClocks[timer] < 0) {
                continue;
            }

            m_timerClocks[timer] -= clocksPerSample;
            if (m_timerClocks[timer] <= 0) {
                // fm_engine_base schedules the next period when the timer
                // expires. Calling its public callback keeps YM2151 status,
                // CSM, and IRQ handling inside ymfm's state machine.
                m_engine->engine_timer_expired(timer);
            }
        }
    }

    ymfm::ym2151 m_chip;
    uint32_t m_nativeRate;
    int32_t m_timerClocks[2] = {-1, -1};
    uint32_t m_busyClocks = 0;
    double m_volume = 1.0;
};

std::unique_ptr<MPX68KYM2151> s_opm;
int s_defaultNativeRate = 62500;

static int clampSample(int value) {
    if (value > 32767) {
        return 32767;
    }
    if (value < -32768) {
        return -32768;
    }
    return value;
}

} // namespace

extern "C" {

int OPM_Init(int clock, int rate) {
    (void)rate;

    const uint32_t chipClock = (clock > 0) ? static_cast<uint32_t>(clock) : 4000000;
    std::unique_ptr<MPX68KYM2151> candidate(new MPX68KYM2151(chipClock));
    if (!candidate) {
        return FALSE;
    }

    s_defaultNativeRate = static_cast<int>(candidate->nativeRate());
    s_opm = std::move(candidate);
    return TRUE;
}

void OPM_Cleanup(void) {
    s_opm.reset();
}

void OPM_SetRate(int clock, int rate) {
    // ymfm's OPM rate is determined by the physical chip clock. The host
    // output rate is configured by X68000_AudioRenderSetHostRate().
    (void)clock;
    (void)rate;
}

void OPM_Reset(void) {
    if (s_opm) {
        s_opm->reset();
    }
}

BYTE FASTCALL OPM_Read(WORD adr) {
    (void)adr;
    return s_opm ? s_opm->chip().read_status() : 0;
}

void FASTCALL OPM_Write(DWORD adr, BYTE data) {
    if (s_opm) {
        s_opm->chip().write(adr, data);
    }
}

void OPM_GenerateNative(int* buffer, int length) {
    if (s_opm) {
        s_opm->generate(buffer, length);
    } else if (buffer && length > 0) {
        for (int index = 0; index < length * 2; ++index) {
            buffer[index] = 0;
        }
    }
}

void OPM_Update(short* buffer,
                int length,
                int rate,
                BYTE* pbsp,
                BYTE* pbep) {
    (void)rate;
    if (!buffer || length <= 0) {
        return;
    }

    // Compatibility entry point for callers outside the new macOS renderer.
    // The macOS path uses OPM_GenerateNative() and performs rate conversion
    // after the complete native mix.
    static int nativeBuffer[4096 * 2];
    int remaining = length;
    short* output = buffer;
    while (remaining > 0) {
        const int frames = (remaining > 4096) ? 4096 : remaining;
        OPM_GenerateNative(nativeBuffer, frames);
        const bool hasRingBounds = pbsp && pbep && (pbep > pbsp);
        short* ringStart = reinterpret_cast<short*>(pbsp);
        short* ringEnd = reinterpret_cast<short*>(pbep);
        for (int frame = 0; frame < frames; ++frame) {
            if (hasRingBounds && output + 2 > ringEnd) {
                output = ringStart;
            }
            output[0] = static_cast<short>(clampSample(nativeBuffer[frame * 2]));
            output[1] = static_cast<short>(clampSample(nativeBuffer[frame * 2 + 1]));
            output += 2;
        }
        remaining -= frames;
    }
}

void FASTCALL OPM_Timer(DWORD step) {
    // YMFM timers are advanced with the native sample clock in generate().
    // The legacy hsync callback remains as a compatibility no-op.
    (void)step;
}

void OPM_SetVolume(BYTE vol) {
    if (s_opm) {
        s_opm->setVolume(vol);
    }
}

int OPM_GetNativeSampleRate(void) {
    return s_opm ? static_cast<int>(s_opm->nativeRate()) : s_defaultNativeRate;
}

} // extern "C"
