// The RF look -- see rf_filter.h, and retro-spectrum's docs/spec/rf.md, whose
// section 4 this follows step by step.

#include "rf_filter.h"

#include "ula.h"

#include <array>
#include <cstring>

namespace zx {
namespace {

#include "generated/rf_tables.inc"

constexpr int SAMPLES = int(RF_WIDTH);
/// Zeros either side of a line's samples. The filters reach past its ends --
/// the luma's three stages by three samples, the 16-sample chroma box by
/// eight -- and the spec defines the composite as 0 out there.
constexpr int PAD = 8;
constexpr int PADDED = SAMPLES + 2 * PAD;

/// One step of the 48K's frame phase: the nominal 0.4992 of a turn, moved
/// by the crystal offset. The arithmetic wraps modulo 2^32, as the spec's does.
uint32_t frame_step(int8_t crystal) {
    return RF_FRAME_48K + uint32_t(int32_t(crystal)) * RF_FRAME_PER_TENTH_PPM;
}

/// The jail bars (steps 1b and 6b): the depth of the levels, about 1, 2 and
/// 4 % of white.
constexpr int JAIL_DEPTH[4] = {0, 3, 5, 10};
/// They are on the paper only, where the ULA fetches: canvas lines 64-255,
/// samples 96-607.
constexpr uint32_t JAIL_FIRST_LINE = 64;
constexpr uint32_t JAIL_LAST_LINE = 255;
constexpr int JAIL_FIRST_SAMPLE = 96;
constexpr int JAIL_LAST_SAMPLE = 607;
/// The bars repeat every 32 samples (16 pixels, the ULA's 8-T-state fetch).
constexpr int JAIL_PERIOD = 32;

/// The jail bars' depth at sample s of canvas line `line`: the 48K's shape,
/// three thin dark lines 4 pixels apart and then quiet, read from a photo of
/// a 48K before its fix (W[k] = 1 for k = 0, 1, 8, 9, 16, 17).
int jail_at(int depth, uint32_t line, int s) {
    if (depth == 0 || line < JAIL_FIRST_LINE || line > JAIL_LAST_LINE || s < JAIL_FIRST_SAMPLE ||
        s > JAIL_LAST_SAMPLE) {
        return 0;
    }
    const int k = (s - JAIL_FIRST_SAMPLE) % JAIL_PERIOD;
    const bool bar = k == 0 || k == 1 || k == 8 || k == 9 || k == 16 || k == 17;
    return bar ? depth : 0;
}

/// The LFSR's period: 0xB400's taps make it a maximal-length one, every
/// state but zero once (rf_filter_tests checks it).
constexpr uint32_t LFSR_PERIOD = 65535;

/// Every state of the noise generator from 0xACE1 on, so that where it is at
/// any line of any frame is a lookup rather than up to 65,534 steps.
const std::vector<uint16_t>& lfsr_states() {
    static const std::vector<uint16_t> states = [] {
        std::vector<uint16_t> s(LFSR_PERIOD);
        uint16_t l = 0xACE1;
        for (uint32_t i = 0; i < LFSR_PERIOD; i++) {
            s[i] = l;
            l = rf_lfsr_step(l);
        }
        return s;
    }();
    return states;
}

/// The colour index (bit 0 blue, 1 red, 2 green, 3 bright) of one pixel of
/// the plain picture. Exact for the palette, which is 0, 0xCD or 0xFF a
/// component; anything else -- the write overlay's dimming, the raster
/// marker -- is taken to the nearest it can be, a component lit from a
/// quarter up and bright when one is past halfway from 0xCD to 0xFF.
uint8_t colour_index(const uint8_t* p) {
    constexpr uint8_t LIT_FROM = 0x40;
    constexpr uint8_t BRIGHT_FROM = 0xE6;
    uint8_t index = 0;
    if (p[2] >= LIT_FROM) {
        index |= 1;
    }
    if (p[0] >= LIT_FROM) {
        index |= 2;
    }
    if (p[1] >= LIT_FROM) {
        index |= 4;
    }
    if (p[0] >= BRIGHT_FROM || p[1] >= BRIGHT_FROM || p[2] >= BRIGHT_FROM) {
        index |= 8;
    }
    return index;
}

uint8_t clamp_byte(int x) {
    return uint8_t(x < 0 ? 0 : x > 255 ? 255 : x);
}

/// Step 7, the scanlines: X - (X x d) / 16 for each of R, G and B.
void darken(uint8_t* rgb, size_t bytes, uint32_t depth) {
    for (size_t i = 0; i < bytes; i++) {
        rgb[i] = uint8_t(rgb[i] - ((rgb[i] * depth) >> 4));
    }
}

} // namespace

uint16_t rf_lfsr_step(uint16_t l) {
    const bool lsb = (l & 1) != 0;
    l = uint16_t(l >> 1);
    if (lsb) {
        l ^= 0xB400;
    }
    return l;
}

uint16_t rf_lfsr_at(uint64_t frame, uint32_t line) {
    // (frame x 312 + line) x 704 steps, taken modulo the period first so
    // that nothing overflows however long the machine has run.
    const uint64_t per_frame = uint64_t(FULL_HEIGHT) * RF_WIDTH % LFSR_PERIOD;
    const uint64_t steps = ((frame % LFSR_PERIOD) * per_frame + uint64_t(line) * RF_WIDTH) % LFSR_PERIOD;
    return lfsr_states()[size_t(steps)];
}

void rf_filter_line(const uint8_t index[352], const RfSettings& settings, uint32_t phase,
                    uint32_t step, uint32_t line, bool second_copy, uint16_t lfsr,
                    uint8_t out[RF_WIDTH * 3]) {
    const bool composite = settings.on() && (settings.flags & RfSettings::COMPOSITE) != 0;
    const bool odd_line = (line & 1) != 0;
    // The bars go on the composite unless they are asked for on the RGB, or
    // there is no composite to put them on.
    const int jail_depth = settings.on() ? JAIL_DEPTH[settings.jail()] : 0;
    const bool jail_rgb = !composite || (settings.flags & RfSettings::JAIL_RGB) != 0;
    if (!composite) {
        // The RGB picture, each dot two samples wide.
        for (int s = 0; s < SAMPLES; s++) {
            const uint8_t i = index[s >> 1];
            const uint8_t level = (i & 8) ? 0xFF : 0xCD;
            out[s * 3] = (i & 2) ? level : 0;
            out[s * 3 + 1] = (i & 4) ? level : 0;
            out[s * 3 + 2] = (i & 1) ? level : 0;
        }
    } else {
        // Indices into the padded arrays are sample + PAD; everything outside
        // the line's own samples stays 0.
        std::array<int, PADDED> e{};
        std::array<int, PADDED> c{};
        std::array<uint8_t, SAMPLES> ph{};
        const int sw_base = odd_line ? 4096 : 0;
        for (int s = 0; s < SAMPLES; s++) {
            ph[size_t(s)] = uint8_t((phase + uint32_t(s) * step) >> 24);
            e[size_t(s + PAD)] = RF_ENC[sw_base | (index[s >> 1] << 8) | ph[size_t(s)]];
            if (!jail_rgb) {
                // 1b, the jail bars on the composite, where the TV's
                // filters soften them.
                e[size_t(s + PAD)] -= jail_at(jail_depth, line, s);
            }
        }
        // 2 and 3, the ghost and the noise. The generator steps for every
        // sample whether the noise is on or not, which the caller has
        // already allowed for by handing in this line's own starting state.
        const bool ghost = (settings.flags & RfSettings::GHOST) != 0;
        const bool noisy = (settings.flags & RfSettings::NOISE) != 0;
        const int delay = settings.ghost_d & 63;
        const int strength = settings.ghost_g & 15;
        const int level = settings.noise & 15;
        for (int s = 0; s < SAMPLES; s++) {
            int v = e[size_t(s + PAD)];
            if (ghost && delay != 0) {
                v += (e[size_t(s + PAD - delay < 0 ? 0 : s + PAD - delay)] * strength) >> 5;
            }
            if (noisy) {
                v += (int(int8_t(lfsr & 0xFF)) * level) >> 4;
            }
            lfsr = rf_lfsr_step(lfsr);
            c[size_t(s + PAD)] = v;
        }
        // The trap, a notch at the subcarrier with a gain of one at DC
        // (91 + 74 + 91 = 256). The chroma is what it takes out, whatever the
        // luma setting, and the luma from 1 up is what it leaves. Worked out
        // over the padding too, since the [1,2,1] stages reach into it.
        std::array<int, PADDED> trap{};
        for (int i = 1; i < PADDED - 1; i++) {
            trap[size_t(i)] = (91 * c[size_t(i - 1)] + 74 * c[size_t(i)] + 91 * c[size_t(i + 1)]) >> 8;
        }
        // 4, the luma: no trap, or the trap and up to two [1,2,1] stages.
        std::array<int, PADDED> y{};
        std::array<int, PADDED> y2{};
        const uint32_t luma = settings.luma();
        if (luma == 0) {
            y = c;
        } else {
            y = trap;
            for (uint32_t stage = 1; stage < luma; stage++) {
                for (int i = 1; i < PADDED - 1; i++) {
                    y2[size_t(i)] = (y[size_t(i - 1)] + 2 * y[size_t(i)] + y[size_t(i + 1)]) >> 2;
                }
                y.swap(y2);
            }
        }
        // 5, the chroma: the composite less the trap's output, demodulated
        // with the encoder's own phase, then a box of n samples, s - n/2 to
        // s + n/2 - 1, kept as a running sum. Demodulating the whole
        // composite instead -- the spec's first version -- left a flat bright
        // area full of false colour, since the box is not a whole number of
        // subcarrier cycles long and so does not cancel a steady level. Only
        // the line's own samples are demodulated: c - trap is not quite 0
        // just outside it, and the spec says 0 there.
        std::array<int, PADDED> du{};
        std::array<int, PADDED> dv{};
        const int sw = odd_line ? -1 : 1;
        for (int s = 0; s < SAMPLES; s++) {
            const int v = c[size_t(s + PAD)] - trap[size_t(s + PAD)];
            du[size_t(s + PAD)] = v * RF_SIN[ph[size_t(s)]];
            dv[size_t(s + PAD)] = v * RF_COS[ph[size_t(s)]] * sw;
        }
        const uint32_t m = settings.chroma();
        const int n = 2 << m;
        int64_t su = 0;
        int64_t sv = 0;
        for (int j = -n / 2; j <= n / 2 - 1; j++) {
            su += du[size_t(j + PAD)];
            sv += dv[size_t(j + PAD)];
        }
        for (int s = 0; s < SAMPLES; s++) {
            if (s > 0) {
                // The window moves on one: s + n/2 - 1 comes in, s - n/2 - 1 goes.
                su += du[size_t(s + n / 2 - 1 + PAD)] - du[size_t(s - n / 2 - 1 + PAD)];
                sv += dv[size_t(s + n / 2 - 1 + PAD)] - dv[size_t(s - n / 2 - 1 + PAD)];
            }
            // 129 / 2^14 is about 1/127; the box's 1/n and the
            // demodulator's gain of 2 make the rest of the shift.
            const int u = int((su * 129) >> (14 + m));
            const int v = int((sv * 129) >> (14 + m));
            // 6, back to RGB.
            const int luma_s = y[size_t(s + PAD)];
            out[s * 3] = clamp_byte(luma_s + ((292 * v) >> 8));
            out[s * 3 + 1] = clamp_byte(luma_s - ((101 * u + 149 * v) >> 8));
            out[s * 3 + 2] = clamp_byte(luma_s + ((520 * u) >> 8));
        }
    }
    if (jail_rgb && jail_depth != 0) {
        // 6b, the jail bars on the RGB, sharp: each component less the
        // bar's depth, down to 0.
        for (int s = JAIL_FIRST_SAMPLE; s <= JAIL_LAST_SAMPLE; s++) {
            const int d = jail_at(jail_depth, line, s);
            for (int i = 0; i < 3; i++) {
                out[s * 3 + i] = clamp_byte(out[s * 3 + i] - d);
            }
        }
    }
    if (second_copy && settings.on() && (settings.flags & RfSettings::SCANLINES) != 0) {
        darken(out, size_t(RF_WIDTH) * 3, settings.scan & 15u);
    }
}

std::vector<uint8_t> rf_filter_frame(const std::vector<uint8_t>& rgb, const RfSettings& settings,
                                     uint64_t frame, bool locked_subcarrier) {
    if (!settings.on() || rgb.size() != size_t(FULL_WIDTH) * FULL_HEIGHT * 3) {
        return rgb;
    }
    // P(F) is the frame times the step, rather than a running sum, so it
    // comes out the same for a frame however it was reached. On a 128K a line
    // is whole turns and so is a frame, whatever the crystal offset (it has
    // the one crystal): only the sample step moves it.
    const uint32_t frame_phase = locked_subcarrier ? 0 : uint32_t(frame) * frame_step(settings.crystal);
    const uint32_t line_step = locked_subcarrier ? 0 : RF_M_48K;
    const uint32_t sample_step = locked_subcarrier ? RF_K_128K : RF_K_48K;
    const bool scanlines = (settings.flags & RfSettings::SCANLINES) != 0;
    const size_t row = size_t(RF_WIDTH) * 3;

    std::vector<uint8_t> out(row * RF_HEIGHT);
    uint8_t index[FULL_WIDTH];
    for (uint32_t line = 0; line < FULL_HEIGHT; line++) {
        const uint8_t* src = rgb.data() + size_t(line) * FULL_WIDTH * 3;
        for (uint32_t dot = 0; dot < FULL_WIDTH; dot++) {
            index[dot] = colour_index(src + dot * 3);
        }
        uint8_t* first = out.data() + size_t(line) * 2 * row;
        rf_filter_line(index, settings, frame_phase + line * line_step, sample_step, line, false,
                       rf_lfsr_at(frame, line), first);
        // The second copy is the same samples, the same noise included, with
        // only the scanlines to add -- so it is copied rather than filtered
        // again.
        std::memcpy(first + row, first, row);
        if (scanlines) {
            darken(first + row, row, settings.scan & 15u);
        }
    }
    return out;
}

} // namespace zx
