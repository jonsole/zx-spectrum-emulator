// Beeper tests: sample-clock exactness, pitch, silence, and -- the one that
// actually guards a subtle bug -- that driving the speaker through a real
// `OUT (0xFE),A` gives the same pitch as toggling the latch directly.

#include "beeper.h"
#include "spectrum.h"
#include "test_main.h"

#include <vector>

using namespace zx;

namespace {

void poke(Spectrum48K& m, uint16_t addr, std::initializer_list<uint8_t> bytes) {
    std::vector<uint8_t> v(bytes);
    m.write_memory(addr, v.data(), v.size());
}

/// Clocks `hc` half-clocks of emulated time, starting at level `initial` and
/// toggling bit 4 every `period_hc`, and returns every sample produced.
/// `period_hc` of 0 leaves the level alone.
///
/// Advances in DRAIN_EVERY_HC steps rather than one jump: the Beeper drops its
/// oldest samples past BEEPER_MAX_PENDING, so a test that generated a whole
/// second and drained only at the end would measure the cap, not the sample
/// clock. The Engine drains roughly twice per frame; this is the same idea.
constexpr uint64_t DRAIN_EVERY_HC = 65536;

std::vector<int16_t> generate(uint64_t hc, uint64_t period_hc, uint8_t initial = 0) {
    Beeper beeper;
    beeper.set_enabled(true, 0);
    beeper.write_port_fe(initial, 0);

    std::vector<int16_t> out;
    uint8_t level = initial;
    uint64_t next_toggle = period_hc;
    uint64_t now = 0;
    while (now < hc) {
        uint64_t next = now + DRAIN_EVERY_HC;
        if (next > hc) {
            next = hc;
        }
        while (period_hc != 0 && next_toggle <= next) {
            level = uint8_t(level ^ 0x10);
            beeper.write_port_fe(level, next_toggle);
            next_toggle += period_hc;
        }
        beeper.advance_to(next);
        beeper.drain(out);
        now = next;
    }
    return out;
}

} // namespace

TEST(sample_clock_is_exact_over_one_second) {
    // 7,000,000 half-clocks is exactly one second of emulated time, so it must
    // produce exactly one second of audio -- no rounding slack.
    const std::vector<int16_t> samples = generate(HC_PER_SEC, 0);
    CHECK_EQ(samples.size(), size_t(AUDIO_SAMPLE_RATE));
}

TEST(sample_clock_does_not_drift_over_ten_seconds) {
    // The integer accumulator is the whole point: a repeated
    // `hc * 44100.0 / 7000000.0` would be off by a handful of samples by here.
    const std::vector<int16_t> samples = generate(HC_PER_SEC * 10, 0);
    CHECK_EQ(samples.size(), size_t(AUDIO_SAMPLE_RATE) * 10);
}

TEST(silence_when_nothing_touches_the_speaker) {
    const std::vector<int16_t> samples = generate(HC_PER_SEC / 10, 0);
    CHECK(!samples.empty());
    bool all_zero = true;
    for (size_t i = 0; i < samples.size(); i++) {
        if (samples[i] != 0) {
            all_zero = false;
        }
    }
    CHECK(all_zero);
}

TEST(a_held_speaker_level_decays_to_silence) {
    // The DC blocker's job: holding the bit high is not a tone, so after the
    // initial step the output must settle back to zero rather than sitting at
    // full scale.
    const std::vector<int16_t> samples = generate(HC_PER_SEC / 2, 0, 0x10);
    CHECK(!samples.empty());
    CHECK(samples[0] != 0);           // the step itself is audible
    CHECK(samples.back() == 0);       // ...and then it is gone
}

TEST(toggling_produces_the_expected_pitch) {
    // Toggle every 7955 half-clocks: a full cycle is 15910, so 7000000/15910
    // is just under 440Hz.
    const std::vector<int16_t> samples = generate(HC_PER_SEC, 7955);
    const float hz = estimate_frequency_hz(samples);
    CHECK(hz > 431.0f);
    CHECK(hz < 449.0f);
}

TEST(out_to_port_fe_drives_the_beeper_at_the_right_pitch) {
    // The five-times trap: a single OUT presents IORQ|WR on five consecutive
    // half-clocks, so service_bus() runs this write five times over. Because
    // the speaker is stored as a LATCH that is harmless -- but an edge-driven
    // implementation would emit five events per OUT and land on the wrong
    // frequency. This test is what would catch that.
    //
    //   8000  F3        DI
    //   8001  3E 10     LD A,0x10
    //   8003  D3 FE     OUT (0xFE),A     ; 11T
    //   8005  06 84     LD B,132         ;  7T
    //   8007  10 FE     DJNZ $           ; 131*13 + 8 = 1711T
    //   8009  EE 10     XOR 0x10         ;  7T
    //   800B  18 F6     JR 8003          ; 12T
    //
    // Half a cycle is 1748T, so a full one is 3496T = 6992 half-clocks:
    // 7000000/6992 = 1001.1Hz.
    Spectrum48K m;
    m.beeper.set_enabled(true, m.global_hc());
    poke(m, 0x8000,
         {0xF3, 0x3E, 0x10, 0xD3, 0xFE, 0x06, 0x84, 0x10, 0xFE, 0xEE, 0x10, 0x18, 0xF6});
    Registers r = m.registers();
    r.pc = 0x8000;
    m.set_registers(r);

    // Half a second, which is ~500 cycles of the tone -- plenty to measure.
    const uint64_t target = m.global_hc() + HC_PER_SEC / 2;
    std::vector<int16_t> samples;
    uint64_t drained = 0;
    while (m.global_hc() < target) {
        m.clock();
        if (++drained % DRAIN_EVERY_HC == 0) {
            m.beeper.advance_to(m.global_hc());
            m.beeper.drain(samples);
        }
    }
    m.beeper.advance_to(m.global_hc());
    m.beeper.drain(samples);
    const float hz = estimate_frequency_hz(samples);
    CHECK(hz > 981.0f);
    CHECK(hz < 1021.0f);
}

TEST(re_enabling_an_already_enabled_beeper_does_not_lose_time) {
    // Regression: Engine::publish_audio calls set_enabled on EVERY publish, so
    // a set_enabled that moved the integration origin when already enabled
    // threw away the whole interval it was about to be asked for. Silent
    // programs went completely silent; only the noisy ones (whose port writes
    // drive advance_to themselves) still worked, which is exactly the way
    // round to survive a unit test and fail on the real ROM.
    Beeper beeper;
    beeper.set_enabled(true, 0);
    beeper.write_port_fe(0x10, 0);

    std::vector<int16_t> out;
    for (uint64_t hc = DRAIN_EVERY_HC; hc <= HC_PER_SEC; hc += DRAIN_EVERY_HC) {
        beeper.set_enabled(true, hc); // the publish-time no-op
        beeper.advance_to(hc);
        beeper.drain(out);
    }
    // One second of emulated time in, one second of audio out.
    const size_t expected = size_t(double(AUDIO_SAMPLE_RATE)
                                   * double(HC_PER_SEC / DRAIN_EVERY_HC * DRAIN_EVERY_HC)
                                   / double(HC_PER_SEC));
    CHECK(out.size() >= expected - 2);
    CHECK(out.size() <= expected + 2);
}

TEST(audio_ring_drops_oldest_on_overrun) {
    AudioRing ring(4);
    const int16_t first[4] = {1, 2, 3, 4};
    ring.write(first, 4);
    const int16_t second[2] = {5, 6};
    ring.write(second, 2);
    CHECK_EQ(ring.available(), size_t(4));

    int16_t out[4] = {0, 0, 0, 0};
    CHECK_EQ(ring.read(out, 4), size_t(4));
    CHECK_EQ(int(out[0]), 3); // 1 and 2 were pushed out
    CHECK_EQ(int(out[3]), 6);
    CHECK_EQ(ring.available(), size_t(0));
}

TEST(audio_ring_peek_returns_the_newest_without_consuming) {
    AudioRing ring(8);
    const int16_t data[5] = {1, 2, 3, 4, 5};
    ring.write(data, 5);

    std::vector<int16_t> latest;
    ring.peek_latest(latest, 3);
    CHECK_EQ(latest.size(), size_t(3));
    CHECK_EQ(int(latest[0]), 3);
    CHECK_EQ(int(latest[2]), 5);
    // A peek must not starve a playback sink reading the same ring.
    CHECK_EQ(ring.available(), size_t(5));
}

TEST(audio_ring_write_larger_than_capacity_keeps_the_newest) {
    AudioRing ring(3);
    const int16_t data[5] = {1, 2, 3, 4, 5};
    ring.write(data, 5);
    CHECK_EQ(ring.available(), size_t(3));
    int16_t out[3] = {0, 0, 0};
    ring.read(out, 3);
    CHECK_EQ(int(out[0]), 3);
    CHECK_EQ(int(out[2]), 5);
}

RUN_TESTS()
