// The RF look (src/rf_filter.h): its tables and constants against
// retro-spectrum's docs/spec/rf.md, worked values on plain lines, the frame
// wrapper, and -- when retro-spectrum is checked out beside this repository --
// every setting against that repository's own C++ model, sample for sample,
// which is the diff the spec exists for (its test 3).

#include "rf_filter.h"
#include "ula.h"

#include "test_main.h"

#include <cmath>
#include <cstring>
#include <random>
#include <vector>

#ifdef ZX_RF_MODEL
#ifdef _MSC_VER
#pragma warning(push, 0)
#endif
#include ZX_RF_MODEL
#ifdef _MSC_VER
#pragma warning(pop)
#endif
#endif

using namespace zx;

namespace {

// rf_filter.cpp keeps its tables to itself; these are the same file.
#include "generated/rf_tables.inc"

constexpr double PI = 3.14159265358979323846;

/// The spec's floor(x + 0.5).
int round_half_up(double x) {
    return int(std::floor(x + 0.5));
}

/// One line of a single colour index.
std::vector<uint8_t> solid_line(uint8_t index) {
    return std::vector<uint8_t>(FULL_WIDTH, index);
}

/// A plain picture of one palette colour, as the ULA draws it.
std::vector<uint8_t> solid_frame(uint8_t r, uint8_t g, uint8_t b) {
    std::vector<uint8_t> rgb(size_t(FULL_WIDTH) * FULL_HEIGHT * 3);
    for (size_t i = 0; i < rgb.size(); i += 3) {
        rgb[i] = r;
        rgb[i + 1] = g;
        rgb[i + 2] = b;
    }
    return rgb;
}

/// A line memory with nothing in it, as at the top of a frame.
RfLineMemory& cleared_memory() {
    static RfLineMemory memory;
    memory = RfLineMemory{};
    return memory;
}

/// Settings with the composite on and nothing else to disturb a worked value:
/// no ghost, no noise, no scanlines.
RfSettings clean_composite() {
    RfSettings s;
    s.flags = RfSettings::ON | RfSettings::COMPOSITE;
    return s;
}

} // namespace

// The encoder table is the spec's formula, rounded as it says: R, G and B
// each 0, 205/255 or 1, Y = 0.299R + 0.587G + 0.114B, U = 0.492(B - Y),
// V = 0.877(R - Y), and ENC = floor(255(Y + U sin a + sw V cos a) + 0.5).
TEST(encoder_table_is_the_spec_formula) {
    int mismatches = 0;
    for (int neg = 0; neg < 2; neg++) {
        const double sw = neg ? -1.0 : 1.0;
        for (int c = 0; c < 16; c++) {
            const double level = (c & 8) ? 1.0 : 205.0 / 255.0;
            const double r = level * ((c >> 1) & 1);
            const double g = level * ((c >> 2) & 1);
            const double b = level * (c & 1);
            const double y = 0.299 * r + 0.587 * g + 0.114 * b;
            const double u = 0.492 * (b - y);
            const double v = 0.877 * (r - y);
            for (int p = 0; p < 256; p++) {
                const double a = 2 * PI * p / 256;
                const int want = round_half_up(255 * (y + u * std::sin(a) + sw * v * std::cos(a)));
                if (RF_ENC[(neg << 12) | (c << 8) | p] != want) {
                    mismatches++;
                }
            }
        }
    }
    CHECK_EQ(mismatches, 0);
    // White is the white level at every phase; black is 0.
    CHECK_EQ(int(RF_ENC[(15 << 8) | 37]), 255);
    CHECK_EQ(int(RF_ENC[(0 << 8) | 37]), 0);
}

TEST(demodulator_tables_are_127_sin_and_cos) {
    for (int p = 0; p < 256; p++) {
        CHECK_EQ(int(RF_SIN[p]), round_half_up(127 * std::sin(2 * PI * p / 256)));
        CHECK_EQ(int(RF_COS[p]), round_half_up(127 * std::cos(2 * PI * p / 256)));
    }
}

// rf.md section 3, from exact fractions: a sample is 4.43361875 / 14 of a
// turn on the 48K, a line 896 samples and a frame 312 lines.
TEST(phase_constants_come_from_the_crystals) {
    const uint64_t num = 443361875ull << 32;          // 4.43361875 MHz x 100, in 2^32ths
    const uint64_t den = 1400000000ull;               // 14 MHz x 100
    CHECK_EQ(uint64_t(RF_K_48K), (num + den / 2) / den);
    CHECK_EQ(RF_M_48K, uint32_t(896u * RF_K_48K));
    CHECK_EQ(RF_FRAME_48K, uint32_t(312u * RF_M_48K));
    // The 128K: 17.7345 MHz / 4 against two samples of 17.7345 x 2/5: 5/16.
    CHECK_EQ(RF_K_128K, uint32_t((5ull << 32) / 16));
    CHECK_EQ(uint32_t(912u * RF_K_128K), 0u);
}

// 0xB400 is a maximal-length tap set: every non-zero state once, so the
// generator comes back to its seed after exactly 65,535 steps.
TEST(noise_generator_has_the_full_period) {
    uint16_t l = 0xACE1;
    uint32_t steps = 0;
    do {
        l = rf_lfsr_step(l);
        steps++;
    } while (l != 0xACE1 && steps < 70000);
    CHECK_EQ(steps, 65535u);
}

TEST(noise_generator_position_is_steps_from_the_seed) {
    const struct {
        uint64_t frame;
        uint32_t line;
    } cases[] = {{0, 0}, {0, 1}, {1, 0}, {3, 200}, {1000, 311}};
    for (const auto& c : cases) {
        uint16_t l = 0xACE1;
        const uint64_t steps = (c.frame * 312 + c.line) * 704;
        for (uint64_t i = 0; i < steps; i++) {
            l = rf_lfsr_step(l);
        }
        CHECK_EQ(int(rf_lfsr_at(c.frame, c.line)), int(l));
    }
}

// White (7, not bright) encodes as 205 at every phase. The trap passes a
// steady level at a gain of one, so the luma is 205 and the chroma -- the
// composite less the trap -- is 0: no colour at all, away from the line's
// ends where the zeros outside it reach in. Bright white is the same at 255.
TEST(white_stays_white_in_the_middle_of_a_line) {
    uint8_t out[RF_WIDTH * 3];
    for (const uint8_t index : {uint8_t(7), uint8_t(15)}) {
        const int level = index == 15 ? 255 : 205;
        const std::vector<uint8_t> white = solid_line(index);
        rf_filter_line(white.data(), clean_composite(), 0x12345678u, RF_K_48K, index == 15 ? 1u : 0u, false,
                       0xACE1, cleared_memory(), out);
        for (uint32_t s = 16; s < RF_WIDTH - 16; s++) {
            CHECK_EQ(int(out[s * 3]), level);
            CHECK_EQ(int(out[s * 3 + 1]), level);
            CHECK_EQ(int(out[s * 3 + 2]), level);
        }
    }
}

// Black encodes as 0 at every phase, so with no ghost and no noise nothing
// anywhere in the decode has anything to work on: 0 throughout, ends
// included.
TEST(black_stays_black) {
    uint8_t out[RF_WIDTH * 3];
    const std::vector<uint8_t> black = solid_line(0);
    rf_filter_line(black.data(), clean_composite(), 0, RF_K_48K, 1, false, 0xACE1, cleared_memory(), out);
    for (uint32_t i = 0; i < RF_WIDTH * 3; i++) {
        CHECK_EQ(int(out[i]), 0);
    }
}

// The master switch on and the composite off: the RGB picture, each dot two
// samples, and the scanlines on the second copy only -- 205 less 205 x 6 / 16
// (76) is 129.
TEST(composite_off_is_the_plain_picture_with_scanlines) {
    RfSettings s;
    s.flags = RfSettings::ON | RfSettings::SCANLINES;
    s.scan = 6;
    const std::vector<uint8_t> out = rf_filter_frame(solid_frame(0xCD, 0, 0), s, 7, false);
    CHECK_EQ(out.size(), size_t(RF_WIDTH) * RF_HEIGHT * 3);
    const size_t row = size_t(RF_WIDTH) * 3;
    CHECK_EQ(int(out[0]), 0xCD);
    CHECK_EQ(int(out[row - 3]), 0xCD);
    CHECK_EQ(int(out[row]), 129);
    CHECK_EQ(int(out[row + 1]), 0);
    CHECK_EQ(int(out[2 * row]), 0xCD);
}

// Off is no filter at all: the same picture back, at its own size.
TEST(off_is_the_picture_untouched) {
    RfSettings s;
    s.flags = 0xFE;   // every effect ready, the jail bars too, the switch off
    const std::vector<uint8_t> in = solid_frame(0, 0xCD, 0xCD);
    CHECK(rf_filter_frame(in, s, 3, false) == in);
}

// 0.1 ppm of the 48K's frame in 2^32 a turn: a frame is 69,888 T-states of
// 3.5 MHz, so 88,530.4992 cycles of the 4.43361875 MHz subcarrier.
TEST(crystal_step_is_a_tenth_of_a_ppm_of_a_frame) {
    const double cycles = 69888.0 / 3500000.0 * 4433618.75;
    const double tenth = cycles * 1e-7 * 4294967296.0;
    CHECK(std::fabs(tenth - double(RF_FRAME_PER_TENTH_PPM)) < 1.0);
    // The spec's own figures: 1 ppm is 0.0885 of a turn, 11.3 ppm a whole one.
    CHECK(std::fabs(10.0 * RF_FRAME_PER_TENTH_PPM / 4294967296.0 - 0.0885) < 0.0005);
}

// The 48K's dots move from one frame to the next, the 128K's stand still:
// the same picture filtered at two frames differs on one and not the other,
// whatever the crystal offset. A red field, so the chroma has something to
// show.
TEST(the_48k_crawls_and_the_128k_does_not) {
    RfSettings s = clean_composite();
    s.flags |= RfSettings::NOISE;   // and the noise stays out of it by being 0
    s.noise = 0;
    s.band = 0x00;                  // no trap: the dots at their strongest
    const std::vector<uint8_t> red = solid_frame(0xCD, 0, 0);
    CHECK(rf_filter_frame(red, s, 10, false) != rf_filter_frame(red, s, 11, false));
    CHECK(rf_filter_frame(red, s, 10, true) == rf_filter_frame(red, s, 11, true));
    s.crystal = 0;
    CHECK(rf_filter_frame(red, s, 10, false) != rf_filter_frame(red, s, 11, false));
    CHECK(rf_filter_frame(red, s, 10, true) == rf_filter_frame(red, s, 11, true));
    // Frame 0 has phase 0 whatever the offset; frame 1's is the offset's step.
    s.crystal = 127;
    const std::vector<uint8_t> first = rf_filter_frame(red, s, 0, false);
    const std::vector<uint8_t> fast = rf_filter_frame(red, s, 1, false);
    s.crystal = -128;
    CHECK(rf_filter_frame(red, s, 0, false) == first);
    CHECK(rf_filter_frame(red, s, 1, false) != fast);
}

// The jail bars on the RGB with the composite off: three pairs of samples
// in every 32, from sample 96 (dot 48, the paper's left edge), each
// component 10 lower at level 3. The border has none, nor the lines above
// and below the paper.
TEST(jail_bars_on_the_rgb_are_on_the_paper_only) {
    RfSettings s;
    s.flags = uint8_t(RfSettings::ON | (3u << RfSettings::JAIL_SHIFT));
    const std::vector<uint8_t> white = solid_line(7);
    uint8_t out[RF_WIDTH * 3];
    rf_filter_line(white.data(), s, 0, RF_K_48K, 64, false, 0xACE1, cleared_memory(), out);
    const int bars[] = {96, 97, 104, 105, 112, 113, 128, 129, 136, 137, 144, 145, 576, 577, 584, 585,
                        592, 593};
    for (int b : bars) {
        CHECK_EQ(int(out[b * 3]), 0xCD - 10);
        CHECK_EQ(int(out[b * 3 + 1]), 0xCD - 10);
        CHECK_EQ(int(out[b * 3 + 2]), 0xCD - 10);
    }
    const int clear[] = {0, 95, 98, 103, 106, 114, 127, 594, 607, 608, 703};
    for (int c : clear) {
        CHECK_EQ(int(out[c * 3]), 0xCD);
    }
    rf_filter_line(white.data(), s, 0, RF_K_48K, 63, false, 0xACE1, cleared_memory(), out);
    CHECK_EQ(int(out[96 * 3]), 0xCD);
    rf_filter_line(white.data(), s, 0, RF_K_48K, 255, false, 0xACE1, cleared_memory(), out);
    CHECK_EQ(int(out[96 * 3]), 0xCD - 10);
    rf_filter_line(white.data(), s, 0, RF_K_48K, 256, false, 0xACE1, cleared_memory(), out);
    CHECK_EQ(int(out[96 * 3]), 0xCD);
    // Black can't go lower; level 1 is 3 down.
    const std::vector<uint8_t> black = solid_line(0);
    rf_filter_line(black.data(), s, 0, RF_K_48K, 100, false, 0xACE1, cleared_memory(), out);
    CHECK_EQ(int(out[96 * 3]), 0);
    s.flags = uint8_t(RfSettings::ON | (1u << RfSettings::JAIL_SHIFT));
    rf_filter_line(white.data(), s, 0, RF_K_48K, 100, false, 0xACE1, cleared_memory(), out);
    CHECK_EQ(int(out[96 * 3]), 0xCD - 3);
    // The switch off: no bars.
    s.flags = uint8_t(3u << RfSettings::JAIL_SHIFT);
    rf_filter_line(white.data(), s, 0, RF_K_48K, 100, false, 0xACE1, cleared_memory(), out);
    CHECK_EQ(int(out[96 * 3]), 0xCD);
}

#ifdef ZX_RF_MODEL
// retro-spectrum's model of the spec, on the same lines with the same
// settings: random lines, single dots, every setting in turn, several phases
// and noise states. Each trial is four lines running down the screen, each
// filtered twice as the board does, so that the PAL delay line sees real
// lines above it; the line memories carry on from trial to trial
// on both sides. The FPGA is diffed against the same model, so agreeing with
// it is agreeing with the board.
TEST(matches_retro_spectrums_model) {
    static RfTables tables;
    if (!tables.load(ZX_RF_TABLES)) {
        std::printf("    (retro-spectrum's tables did not load; skipped)\n");
        return;
    }
    std::mt19937 rng(1234);
    std::vector<uint8_t> line(FULL_WIDTH);
    uint8_t ours[RF_WIDTH * 3];
    Rgb theirs[RF_WIDTH];
    static RfLineMemory our_memory;
    static RfLineMem their_memory;
    constexpr int TRIALS = 400;
    constexpr uint32_t LINES = 4;
    int compared = 0;
    int mismatches = 0;
    for (int trial = 0; trial < TRIALS; trial++) {
        RfSettings s;
        s.flags = uint8_t(rng() & 0xFF);
        s.band = uint8_t(rng() & 0xFF);
        s.ghost_d = uint8_t(rng() & 63);
        // The high nibbles are the two dials, 9-15 included.
        s.ghost_g = uint8_t(rng() & 0xFF);
        s.noise = uint8_t(rng() & 0xFF);
        s.scan = uint8_t(rng() & 15);
        RfCfg cfg;
        cfg.flags = s.flags;
        cfg.band = s.band;
        cfg.ghost_d = s.ghost_d;
        cfg.ghost_g = s.ghost_g;
        cfg.noise = s.noise;
        cfg.scan = s.scan;
        // The crystal offset is not in a line's arguments: the caller turns
        // it into the phase. The line number is, for the jail bars, the PAL
        // switch and where the delay line starts.
        const uint32_t first_line = uint32_t(rng() % (FULL_HEIGHT - LINES + 1));
        const uint32_t step = (trial & 8) ? RF_K_128K : RF_K_48K;
        for (uint32_t n = 0; n < LINES; n++) {
            // A line: random dots, runs, a single dot on black, or solid.
            const int kind = int((uint32_t(trial) + n) % 4);
            for (uint32_t x = 0; x < FULL_WIDTH; x++) {
                if (kind == 0) {
                    line[x] = uint8_t(rng() & 15);
                } else if (kind == 1) {
                    line[x] = uint8_t((x / 8 + uint32_t(trial)) & 15);
                } else if (kind == 2) {
                    line[x] = x == 100 + uint32_t(trial) % 100 ? uint8_t(15) : uint8_t(0);
                } else {
                    line[x] = uint8_t((uint32_t(trial) + n) & 15);
                }
            }
            const uint32_t canvas_line = first_line + n;
            const bool odd = (canvas_line & 1) != 0;
            const uint32_t phase = uint32_t(rng());
            const uint16_t lfsr = uint16_t(rng() | 1);
            for (const bool second : {false, true}) {
                uint16_t their_lfsr = lfsr;
                rf_filter_line(line.data(), s, phase, step, canvas_line, second, lfsr, our_memory, ours);
                rf_line(tables, cfg, int(canvas_line), phase, step, odd, second, line.data(), their_lfsr,
                        theirs, their_memory);
                for (uint32_t i = 0; i < RF_WIDTH; i++) {
                    compared++;
                    if (ours[i * 3] != theirs[i].r || ours[i * 3 + 1] != theirs[i].g
                        || ours[i * 3 + 2] != theirs[i].b) {
                        if (mismatches < 5) {
                            std::printf("    trial %d line %u copy %d sample %u band %02X: ours %d,%d,%d "
                                        "model %d,%d,%d\n",
                                        trial, canvas_line, second ? 2 : 1, i, s.band, ours[i * 3],
                                        ours[i * 3 + 1], ours[i * 3 + 2], theirs[i].r, theirs[i].g,
                                        theirs[i].b);
                        }
                        mismatches++;
                    }
                }
            }
        }
    }
    CHECK_EQ(compared, TRIALS * int(LINES) * 2 * int(RF_WIDTH));
    CHECK_EQ(mismatches, 0);
}
#endif

RUN_TESTS()
