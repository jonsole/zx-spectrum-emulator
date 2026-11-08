// The AY-3-8912: driven through the Beeper's integrator the way the machine
// drives it, so what is checked is the audio that comes out rather than the
// chip's internal counters.

#include "ay.h"
#include "beeper.h"
#include "test_main.h"
#include "ula.h"

#include <cmath>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

using namespace zx;

namespace {

/// The AY's own clock, for working out what a period register means.
constexpr double AY_CLOCK_HZ = double(TIMING_128K.hc_per_sec) / 2.0 / 2.0;

void set(Ay& ay, uint8_t reg, uint8_t value) {
    ay.select(reg);
    ay.write(value);
}

/// Runs the chip for `seconds` through a Beeper and returns the samples.
std::vector<int16_t> render(Ay& ay, double seconds) {
    Beeper b;
    b.set_clock(TIMING_128K.hc_per_sec);
    b.attach_ay(&ay);
    b.set_enabled(true, 0);
    b.advance_to(uint64_t(seconds * double(TIMING_128K.hc_per_sec)));
    std::vector<int16_t> out;
    b.drain(out);
    return out;
}

/// Steps the chip `n` generator steps with nothing else going on.
void step(Ay& ay, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        ay.advance(AY_HC_PER_STEP);
    }
}

} // namespace

TEST(tone_channel_plays_the_programmed_pitch) {
    Ay ay;
    // Tone A only: register 7's bits are active-low disables, so 0x3E leaves
    // just tone A enabled.
    set(ay, 7, 0x3E);
    set(ay, 8, 15);
    // f = AY / (16 * P): P = 111 is a shade under 1kHz.
    set(ay, 0, 111);
    set(ay, 1, 0);
    const std::vector<int16_t> samples = render(ay, 1.0);
    const float expected = float(AY_CLOCK_HZ / (16.0 * 111.0));
    const float measured = estimate_frequency_hz(samples);
    CHECK(std::fabs(measured - expected) < expected * 0.03f);
    float rms = 0, peak = 0;
    measure_level(samples, rms, peak);
    CHECK(peak > 0.05f);
}

TEST(silent_until_a_channel_is_given_a_volume) {
    Ay ay;
    step(ay, 1000);
    CHECK_EQ(ay.level(), 0);
    // Every channel disabled but at full volume: a disabled channel's tone
    // and noise both read as "on", so it holds at its volume rather than
    // going quiet -- as the chip does, and as programs rely on for sample
    // playback through the volume registers.
    set(ay, 7, 0x3F);
    set(ay, 8, 15);
    CHECK_EQ(ay.level(), AY_CHANNEL_LEVEL);
    set(ay, 8, 0);
    CHECK_EQ(ay.level(), 0);
}

TEST(registers_read_back_with_only_the_bits_they_have) {
    Ay ay;
    set(ay, 1, 0xFF);
    CHECK_EQ(int(ay.read()), 0x0F);
    set(ay, 6, 0xFF);
    CHECK_EQ(int(ay.read()), 0x1F);
    set(ay, 13, 0xFF);
    CHECK_EQ(int(ay.read()), 0x0F);
    set(ay, 0, 0xA5);
    CHECK_EQ(int(ay.read()), 0xA5);
    // Nothing beyond register 15 on an 8912: selecting one reads as an
    // undriven bus and writes go nowhere.
    ay.select(16);
    ay.write(0x12);
    CHECK_EQ(int(ay.read()), 0xFF);
    CHECK_EQ(int(ay.reg(0)), 0xA5);
}

TEST(envelope_ramps_down_and_holds_at_zero) {
    Ay ay;
    set(ay, 7, 0x3F); // no tone, no noise: the channel sits at its volume
    set(ay, 8, 0x10); // ...which is the envelope's
    set(ay, 11, 1);   // shortest period: one envelope step every two chip steps
    set(ay, 12, 0);
    set(ay, 13, 0);   // shape 0: \___
    CHECK_EQ(ay.level(), AY_CHANNEL_LEVEL); // starts at the top
    step(ay, 2);
    CHECK(ay.level() < AY_CHANNEL_LEVEL);
    CHECK(ay.level() > 0);
    step(ay, 40);
    CHECK_EQ(ay.level(), 0); // ...and stays there
    step(ay, 40);
    CHECK_EQ(ay.level(), 0);
    // Writing the shape again restarts it, even with the same shape.
    set(ay, 13, 0);
    CHECK_EQ(ay.level(), AY_CHANNEL_LEVEL);
}

TEST(continuing_envelope_repeats) {
    Ay ay;
    set(ay, 7, 0x3F);
    set(ay, 8, 0x10);
    set(ay, 11, 1);
    set(ay, 12, 0);
    set(ay, 13, 0x08); // continue, no attack, no alternate, no hold: sawtooth down
    step(ay, 32);      // one full ramp: 16 steps of 2
    CHECK_EQ(ay.level(), AY_CHANNEL_LEVEL); // back at the top for the next
    set(ay, 13, 0x0C); // continue + attack: ////
    CHECK_EQ(ay.level(), 0);
    step(ay, 30);
    CHECK_EQ(ay.level(), AY_CHANNEL_LEVEL);
    step(ay, 2);
    CHECK_EQ(ay.level(), 0);
}

TEST(noise_channel_is_not_a_constant) {
    Ay ay;
    set(ay, 7, 0x37); // noise on A only
    set(ay, 6, 1);
    set(ay, 8, 15);
    int32_t highs = 0;
    int32_t lows = 0;
    for (int i = 0; i < 2000; i++) {
        step(ay, 1);
        if (ay.level() == AY_CHANNEL_LEVEL) {
            highs++;
        } else if (ay.level() == 0) {
            lows++;
        }
    }
    CHECK(highs > 200);
    CHECK(lows > 200);
    CHECK_EQ(highs + lows, 2000);
}

TEST(beeper_and_ay_mix_without_one_silencing_the_other) {
    Ay ay;
    set(ay, 7, 0x3E);
    set(ay, 8, 15);
    set(ay, 0, 50);
    Beeper b;
    b.set_clock(TIMING_128K.hc_per_sec);
    b.attach_ay(&ay);
    b.set_enabled(true, 0);
    // A beeper edge part-way through, on an arbitrary half-clock.
    b.advance_to(1'000'003);
    b.write_port_fe(0x10, 1'000'003);
    b.advance_to(2'000'000);
    std::vector<int16_t> out;
    b.drain(out);
    float rms = 0, peak = 0;
    measure_level(out, rms, peak);
    CHECK(peak > 0.1f);
    // A drained 0.28s at 44.1kHz is about 12,500 samples; the exact count
    // follows the sample clock, which the AY chunking must not disturb.
    const size_t expected = size_t(2'000'000.0 * 44100.0 / double(TIMING_128K.hc_per_sec));
    CHECK(out.size() >= expected - 1 && out.size() <= expected + 1);
}

namespace {

/// A third of a second of the chip -- under the Beeper's half second of
/// undrained audio, so nothing is dropped -- set up by `regs` (register, value pairs) from
/// power-on, with the beeper's speaker bit at `speaker`, through a Beeper in
/// `mix`. A fresh chip each time, so two mixes hear the same signal.
std::vector<int16_t> render_mix(const std::vector<std::pair<uint8_t, uint8_t>>& regs,
                                bool speaker, StereoMix mix) {
    Ay ay;
    for (const auto& r : regs) {
        set(ay, r.first, r.second);
    }
    Beeper b;
    b.set_clock(TIMING_128K.hc_per_sec);
    b.attach_ay(&ay);
    b.set_stereo_mix(mix);
    b.set_enabled(true, 0);
    // The speaker goes high a little way in, so that the DC blocker has an
    // edge to pass rather than a level it takes out.
    b.advance_to(100'003);
    b.write_port_fe(speaker ? 0x10 : 0x00, 100'003);
    b.advance_to(uint64_t(TIMING_128K.hc_per_sec / 3));
    std::vector<int16_t> out;
    b.drain(out);
    return out;
}

/// The left or right samples of interleaved stereo.
std::vector<int16_t> side(const std::vector<int16_t>& stereo, size_t which) {
    std::vector<int16_t> out;
    for (size_t i = which; i < stereo.size(); i += 2) {
        out.push_back(stereo[i]);
    }
    return out;
}

/// A ~1 kHz tone at full volume on channel `ch` (0 A, 1 B, 2 C) alone.
std::vector<std::pair<uint8_t, uint8_t>> tone_on(int ch) {
    // Register 7's bits are active-low disables: clear only this tone's.
    const uint8_t enable = uint8_t(0x3F & ~(1u << ch));
    return {{7, enable}, {uint8_t(8 + ch), 15}, {uint8_t(2 * ch), 111}, {uint8_t(2 * ch + 1), 0}};
}

} // namespace

TEST(stereo_is_two_samples_a_period_and_mono_one) {
    const std::vector<int16_t> mono = render_mix(tone_on(0), false, StereoMix::Mono);
    const std::vector<int16_t> stereo = render_mix(tone_on(0), false, StereoMix::Abc);
    CHECK(!mono.empty());
    CHECK_EQ(stereo.size(), 2 * mono.size());
}

// Each side is 2 x its own channel + the middle channel + the beeper. So
// the middle channel alone, and the beeper alone, are the mono signal on
// both sides, sample for sample: the sums are the same integers.
TEST(the_middle_channel_and_the_beeper_are_mono_on_both_sides) {
    const std::vector<int16_t> b_mono = render_mix(tone_on(1), false, StereoMix::Mono);
    const std::vector<int16_t> b_abc = render_mix(tone_on(1), false, StereoMix::Abc);
    CHECK(side(b_abc, 0) == b_mono);
    CHECK(side(b_abc, 1) == b_mono);
    const std::vector<int16_t> c_mono = render_mix(tone_on(2), false, StereoMix::Mono);
    const std::vector<int16_t> c_acb = render_mix(tone_on(2), false, StereoMix::Acb);
    CHECK(side(c_acb, 0) == c_mono);
    CHECK(side(c_acb, 1) == c_mono);
    const std::vector<int16_t> beep_mono = render_mix({}, true, StereoMix::Mono);
    const std::vector<int16_t> beep_acb = render_mix({}, true, StereoMix::Acb);
    float rms = 0, peak = 0;
    measure_level(beep_mono, rms, peak);
    CHECK(peak > 0.1f);
    CHECK(side(beep_acb, 0) == beep_mono);
    CHECK(side(beep_acb, 1) == beep_mono);
}

// A side channel is on its own side only, at twice its mono level: within
// one count, since the scaling to 16 bits truncates.
TEST(a_side_channel_is_on_its_side_alone_at_twice_mono) {
    const struct {
        int ch;
        StereoMix mix;
        size_t loud;
    } cases[] = {{0, StereoMix::Abc, 0}, {2, StereoMix::Abc, 1},
                 {0, StereoMix::Acb, 0}, {1, StereoMix::Acb, 1}};
    for (const auto& c : cases) {
        const std::vector<int16_t> mono = render_mix(tone_on(c.ch), false, StereoMix::Mono);
        const std::vector<int16_t> stereo = render_mix(tone_on(c.ch), false, c.mix);
        const std::vector<int16_t> loud = side(stereo, c.loud);
        const std::vector<int16_t> quiet = side(stereo, 1 - c.loud);
        CHECK_EQ(loud.size(), mono.size());
        CHECK_EQ(quiet.size(), mono.size());
        const size_t n = loud.size() < mono.size() ? loud.size() : mono.size();
        int worst = 0;
        int quietest = 0;
        for (size_t i = 0; i < n; i++) {
            const int off = std::abs(int(loud[i]) - 2 * int(mono[i]));
            worst = off > worst ? off : worst;
            quietest = std::abs(int(quiet[i])) > quietest ? std::abs(int(quiet[i])) : quietest;
        }
        CHECK(worst <= 1);
        CHECK_EQ(quietest, 0);
    }
}

// All three channels the same tone, in step from power-on, with the beeper:
// the loudest the chip can be. Each side (2 x 80 + 80) is then mono's
// (3 x 80) exactly, so stereo is never louder than mono at its loudest.
TEST(a_side_at_its_loudest_is_mono_at_its_loudest) {
    const std::vector<std::pair<uint8_t, uint8_t>> all = {
        {7, 0x38}, {8, 15}, {9, 15}, {10, 15}, {0, 111}, {2, 111}, {4, 111}};
    const std::vector<int16_t> mono = render_mix(all, true, StereoMix::Mono);
    for (const StereoMix mix : {StereoMix::Abc, StereoMix::Acb}) {
        const std::vector<int16_t> stereo = render_mix(all, true, mix);
        CHECK(side(stereo, 0) == mono);
        CHECK(side(stereo, 1) == mono);
    }
}

TEST(the_mixes_have_names) {
    StereoMix mix = StereoMix::Mono;
    CHECK(parse_stereo_mix("acb", mix));
    CHECK(mix == StereoMix::Acb);
    CHECK_EQ(std::string(stereo_mix_name(mix)), std::string("acb"));
    CHECK(parse_stereo_mix("abc", mix));
    CHECK(mix == StereoMix::Abc);
    CHECK(parse_stereo_mix("mono", mix));
    CHECK(mix == StereoMix::Mono);
    CHECK(!parse_stereo_mix("ACB", mix));
    CHECK(!parse_stereo_mix("", mix));
}

RUN_TESTS()
