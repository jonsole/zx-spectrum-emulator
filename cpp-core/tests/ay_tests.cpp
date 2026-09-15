// The AY-3-8912: driven through the Beeper's integrator the way the machine
// drives it, so what is checked is the audio that comes out rather than the
// chip's internal counters.

#include "ay.h"
#include "beeper.h"
#include "test_main.h"
#include "ula.h"

#include <cmath>
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

RUN_TESTS()
