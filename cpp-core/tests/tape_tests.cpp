// Tape tests: .tap/.tzx parsing, the pulse state machine, and the fast-load
// trap against the real ROM.
//
// Every fixture here is SYNTHESISED. A .tap block is a length and some bytes
// and a .tzx block is barely more, so building them in the test costs a few
// lines, commits no copyrighted image, needs no data file on disk -- and lets
// the tests construct the malformed and pathological blocks that no real tape
// contains but the parser still has to survive.

#include "beeper.h"
#include "spectrum.h"
#include "tape.h"
#include "test_main.h"

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

namespace {

/// The real ROM is copyrighted and gitignored, so tests that need it skip
/// gracefully when it is absent rather than failing.
bool load_rom(Spectrum48K& m) {
    std::ifstream f(std::string(ZX_PROJECT_ROOT) + "/roms/48.rom", std::ios::binary);
    if (!f) {
        return false;
    }
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    return m.load_rom(rom.data(), rom.size()).empty();
}

void push16(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(uint8_t(v & 0xFF));
    out.push_back(uint8_t((v >> 8) & 0xFF));
}

void push24(std::vector<uint8_t>& out, uint32_t v) {
    push16(out, v & 0xFFFF);
    out.push_back(uint8_t((v >> 16) & 0xFF));
}

/// Flag byte + payload + XOR checksum, exactly as the ROM reads a block.
std::vector<uint8_t> tape_block(uint8_t flag, const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> b;
    b.push_back(flag);
    for (uint8_t v : payload) {
        b.push_back(v);
    }
    uint8_t parity = 0;
    for (uint8_t v : b) {
        parity = uint8_t(parity ^ v);
    }
    b.push_back(parity);
    return b;
}

/// A 17-byte CODE header body, as the ROM's LD_BYTES expects behind flag 0x00.
std::vector<uint8_t> code_header(const std::string& name, uint16_t start, uint16_t length) {
    std::vector<uint8_t> h;
    h.push_back(3); // type 3 == CODE
    for (size_t i = 0; i < 10; i++) {
        h.push_back(i < name.size() ? uint8_t(name[i]) : uint8_t(' '));
    }
    push16(h, length);
    push16(h, start);
    push16(h, 0x8000); // unused for CODE
    return h;
}

void append_tap_block(std::vector<uint8_t>& tap, const std::vector<uint8_t>& block) {
    push16(tap, uint32_t(block.size()));
    for (uint8_t v : block) {
        tap.push_back(v);
    }
}

/// A complete two-block .tap: a CODE header and its data.
std::vector<uint8_t> make_tap(const std::vector<uint8_t>& code, uint16_t start) {
    std::vector<uint8_t> tap;
    append_tap_block(tap, tape_block(0x00, code_header("test", start, uint16_t(code.size()))));
    append_tap_block(tap, tape_block(0xFF, code));
    return tap;
}

std::vector<uint8_t> tzx_header() {
    std::vector<uint8_t> t = {'Z', 'X', 'T', 'a', 'p', 'e', '!', 0x1A, 1, 20};
    return t;
}

/// A .tzx ID 0x10 standard-speed block wrapping `block`.
void append_tzx_standard(std::vector<uint8_t>& tzx, const std::vector<uint8_t>& block,
                         uint32_t pause_ms) {
    tzx.push_back(0x10);
    push16(tzx, pause_ms);
    push16(tzx, uint32_t(block.size()));
    for (uint8_t v : block) {
        tzx.push_back(v);
    }
}

/// A .tzx ID 0x11 turbo block with timings of the caller's choosing.
void append_tzx_turbo(std::vector<uint8_t>& tzx, const std::vector<uint8_t>& block,
                      uint32_t pilot_t, uint32_t pilot_count, uint32_t zero_t, uint32_t one_t) {
    tzx.push_back(0x11);
    push16(tzx, pilot_t);
    push16(tzx, TAPE_SYNC1_T);
    push16(tzx, TAPE_SYNC2_T);
    push16(tzx, zero_t);
    push16(tzx, one_t);
    push16(tzx, pilot_count);
    tzx.push_back(8); // used bits in the last byte
    push16(tzx, 100); // pause, ms
    push24(tzx, uint32_t(block.size()));
    for (uint8_t v : block) {
        tzx.push_back(v);
    }
}

/// Half-clocks at which EAR changed, walking `hc` one at a time.
///
/// One half-clock at a time on purpose: the pulse lengths ARE the thing under
/// test, and sampling at any coarser interval would alias them into looking
/// correct.
std::vector<uint64_t> edges(Tape& t, uint64_t from_hc, uint64_t to_hc) {
    std::vector<uint64_t> out;
    bool last = t.ear_at(from_hc);
    for (uint64_t hc = from_hc + 1; hc <= to_hc; hc++) {
        const bool now = t.ear_at(hc);
        if (now != last) {
            out.push_back(hc);
            last = now;
        }
    }
    return out;
}

/// Gaps between successive edges, i.e. the pulse lengths actually produced,
/// converted back to T-states.
std::vector<uint64_t> pulse_tstates(const std::vector<uint64_t>& e) {
    std::vector<uint64_t> out;
    for (size_t i = 1; i < e.size(); i++) {
        out.push_back((e[i] - e[i - 1]) / HC_PER_TSTATE);
    }
    return out;
}

Tape play_tap(const std::vector<uint8_t>& image) {
    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "test.tap"), std::string());
    t.play(0);
    return t;
}

} // namespace

// ---- .tap parsing ----------------------------------------------------------

TEST(tap_parses_header_and_data_blocks) {
    const std::vector<uint8_t> code = {0xAF, 0xC9}; // XOR A / RET
    Tape t;
    const std::vector<uint8_t> image = make_tap(code, 0x8000);
    CHECK_EQ(t.insert(image.data(), image.size(), "test.tap"), std::string());
    CHECK(t.inserted());

    const TapeStatus s = t.status(0);
    CHECK_EQ(s.blocks, size_t(2));
    CHECK_EQ(s.name, std::string("test.tap"));
    CHECK(!s.playing);
    CHECK(!s.at_end);
}

TEST(tap_rejects_a_truncated_block) {
    // Claims 100 bytes, supplies four.
    std::vector<uint8_t> image = {100, 0, 1, 2, 3, 4};
    Tape t;
    const std::string error = t.insert(image.data(), image.size(), "bad.tap");
    CHECK(!error.empty());
    CHECK(error.find("truncated") != std::string::npos);
    CHECK(!t.inserted());
}

TEST(tap_rejects_a_block_too_short_to_be_one) {
    std::vector<uint8_t> image = {1, 0, 0xFF}; // one byte: no room for a checksum
    Tape t;
    CHECK(!t.insert(image.data(), image.size(), "bad.tap").empty());
}

TEST(tap_accepts_trailing_padding) {
    std::vector<uint8_t> image = make_tap({0xAF}, 0x8000);
    push16(image, 0); // a trailing zero length, as some tools emit
    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "padded.tap"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(2));
}

TEST(tap_accepts_a_long_run_of_trailing_padding) {
    // What real images actually look like: a commercial .tap is routinely
    // padded out to a boundary with hundreds of zero bytes. Accepting only a
    // single trailing 0x0000 rejected the lot.
    std::vector<uint8_t> image = make_tap({0xAF, 0xC9}, 0x8000);
    for (int i = 0; i < 211; i++) {
        image.push_back(0);
    }
    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "padded.tap"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(2));
}

TEST(tap_still_rejects_an_empty_block_followed_by_data) {
    // The other half of the padding rule: zeros are padding only when nothing
    // but zeros follows. A zero length with a real block after it is broken.
    std::vector<uint8_t> image;
    push16(image, 0); // a block claiming no bytes at all
    append_tap_block(image, tape_block(0xFF, {0x01}));
    Tape t;
    const std::string error = t.insert(image.data(), image.size(), "broken.tap");
    CHECK(!error.empty());
    CHECK(error.find("empty") != std::string::npos);
}

TEST(tap_drops_a_final_block_that_runs_past_the_end) {
    // An image truncated in transit still loads everything before the cut --
    // far more use than refusing all of it.
    std::vector<uint8_t> image = make_tap({0xAF}, 0x8000);
    push16(image, 500); // claims 500 bytes, supplies three
    image.push_back(0xFF);
    image.push_back(0x01);
    image.push_back(0x02);

    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "cut.tap"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(2));
    CHECK_EQ(t.status(0).warnings.size(), size_t(1));
}

TEST(tzx_accepts_trailing_padding) {
    const std::vector<uint8_t> block = tape_block(0xFF, {0x42});
    std::vector<uint8_t> tzx = tzx_header();
    append_tzx_standard(tzx, block, TAPE_TAP_PAUSE_MS);
    for (int i = 0; i < 64; i++) {
        tzx.push_back(0);
    }
    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "padded.tzx"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(1));
}

TEST(a_failed_insert_leaves_the_previous_tape_alone) {
    const std::vector<uint8_t> good = make_tap({0xAF}, 0x8000);
    Tape t;
    CHECK_EQ(t.insert(good.data(), good.size(), "good.tap"), std::string());

    const std::vector<uint8_t> bad = {100, 0, 1, 2};
    CHECK(!t.insert(bad.data(), bad.size(), "bad.tap").empty());
    CHECK(t.inserted());
    CHECK_EQ(t.status(0).blocks, size_t(2));
    CHECK_EQ(t.status(0).name, std::string("good.tap"));
}

// ---- standard-speed pulse timings ------------------------------------------

TEST(standard_pulse_timings_match_the_rom) {
    // One-byte payload, so the whole block is short enough to walk edge by
    // edge: flag 0xFF, data 0xA5, checksum.
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0xA5}));

    Tape t = play_tap(image);
    // Long enough for the ~2s data-block leader plus the bits.
    const std::vector<uint64_t> e = edges(t, 0, uint64_t(TAPE_PILOT_DATA_PULSES + 200)
                                                    * TAPE_PILOT_T * HC_PER_TSTATE);
    const std::vector<uint64_t> t_states = pulse_tstates(e);
    CHECK(t_states.size() > TAPE_PILOT_DATA_PULSES + 34);
    if (t_states.size() <= TAPE_PILOT_DATA_PULSES + 34) {
        return;
    }

    // A data block gets the short leader, every pulse of it 2168T.
    for (uint32_t i = 0; i + 1 < TAPE_PILOT_DATA_PULSES; i++) {
        CHECK_EQ(t_states[i], uint64_t(TAPE_PILOT_T));
    }
    // Then the two sync pulses, then the data bits, MSB first.
    size_t i = TAPE_PILOT_DATA_PULSES - 1;
    CHECK_EQ(t_states[i++], uint64_t(TAPE_SYNC1_T));
    CHECK_EQ(t_states[i++], uint64_t(TAPE_SYNC2_T));

    // Flag byte 0xFF: eight 1 bits, two 1710T pulses each.
    for (uint32_t bit = 0; bit < 8; bit++) {
        CHECK_EQ(t_states[i++], uint64_t(TAPE_BIT1_T));
        CHECK_EQ(t_states[i++], uint64_t(TAPE_BIT1_T));
    }
    // Payload 0xA5 == 1010 0101, most significant bit first.
    const uint8_t bits[8] = {1, 0, 1, 0, 0, 1, 0, 1};
    for (uint32_t bit = 0; bit < 8; bit++) {
        const uint64_t want = bits[bit] != 0 ? TAPE_BIT1_T : TAPE_BIT0_T;
        CHECK_EQ(t_states[i++], want);
        CHECK_EQ(t_states[i++], want);
    }
}

TEST(a_header_block_gets_the_long_leader) {
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0x00, code_header("hdr", 0x8000, 1)));

    Tape t = play_tap(image);
    const std::vector<uint64_t> e =
        edges(t, 0, uint64_t(TAPE_PILOT_HEADER_PULSES + 4) * TAPE_PILOT_T * HC_PER_TSTATE);
    const std::vector<uint64_t> t_states = pulse_tstates(e);

    // The pilot runs until the first pulse that is not 2168T.
    size_t pilot = 0;
    while (pilot < t_states.size() && t_states[pilot] == TAPE_PILOT_T) {
        pilot++;
    }
    // The walk starts inside the first pulse, so its leading edge -- and with
    // it one gap -- is unobservable.
    CHECK_EQ(pilot, size_t(TAPE_PILOT_HEADER_PULSES - 1));
    if (pilot >= t_states.size()) {
        return;
    }
    CHECK_EQ(t_states[pilot], uint64_t(TAPE_SYNC1_T));
}

TEST(ear_at_is_idempotent_across_one_in) {
    // The five-times-per-IN contract. Control lines are not auto-cleared, so
    // service_bus() calls ear_at() five times for a single IN, all with the
    // same half-clock -- and all five must agree. Anything that consumed tape
    // state on read would fail here and nowhere else.
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0x5A}));

    Tape a = play_tap(image);
    Tape b = play_tap(image);

    const uint64_t window = uint64_t(TAPE_PILOT_T) * HC_PER_TSTATE * 20;
    for (uint64_t hc = 0; hc < window; hc++) {
        const bool once = a.ear_at(hc);
        for (int i = 0; i < 5; i++) {
            CHECK_EQ(b.ear_at(hc), once);
        }
    }
}

TEST(ear_at_stops_on_a_backwards_clock) {
    // Ula::reset() zeroes the frame counter, so global_hc() restarts at 0 and
    // every timestamp the cursor holds is suddenly in the future.
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0x5A}));

    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "t.tap"), std::string());
    t.play(1'000'000);
    CHECK(t.playing());
    t.ear_at(1'000'500);
    CHECK(t.playing());

    CHECK_EQ(t.ear_at(10), TAPE_IDLE_EAR);
    CHECK(!t.playing());
    CHECK(!t.at_end()); // stopped, not finished
}

TEST(a_stopped_tape_reads_idle_high) {
    Tape t;
    CHECK_EQ(t.ear_at(0), TAPE_IDLE_EAR);
    CHECK_EQ(t.ear_at(1'000'000), TAPE_IDLE_EAR);
    CHECK(!t.inserted());
}

TEST(the_pause_emits_a_trailing_edge_then_holds_low) {
    // A one-block tape, walked past its end.
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0x00}));

    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "t.tap"), std::string());
    t.play(0);

    // Walk to the end of the data, then check the block's lead-out.
    const TapeStatus total = t.status(0);
    const uint64_t end_hc = total.total_ms * (HC_PER_SEC / 1000);
    // Just inside the pause, well past the 1ms lead-out edge, the line is low.
    CHECK_EQ(t.ear_at(end_hc - (HC_PER_SEC / 1000) * 100), false);
    // And past the very end the tape has stopped and the line idles high.
    CHECK_EQ(t.ear_at(end_hc + HC_PER_SEC), TAPE_IDLE_EAR);
    CHECK(!t.playing());
    CHECK(t.at_end());
}

// ---- .tzx ------------------------------------------------------------------

TEST(tzx_standard_block_matches_the_same_tap) {
    // The strongest statement we can make about ID 0x10: it is not merely
    // similar to a .tap block, it is the same signal down to the half-clock.
    const std::vector<uint8_t> block = tape_block(0xFF, {0x3C, 0x81});

    std::vector<uint8_t> tap;
    append_tap_block(tap, block);
    std::vector<uint8_t> tzx = tzx_header();
    append_tzx_standard(tzx, block, TAPE_TAP_PAUSE_MS);

    Tape a;
    Tape b;
    CHECK_EQ(a.insert(tap.data(), tap.size(), "a"), std::string());
    CHECK_EQ(b.insert(tzx.data(), tzx.size(), "b"), std::string());
    a.play(0);
    b.play(0);

    const uint64_t window = uint64_t(TAPE_PILOT_DATA_PULSES + 200) * TAPE_PILOT_T * HC_PER_TSTATE;
    CHECK(edges(a, 0, window) == edges(b, 0, window));
}

TEST(tzx_turbo_block_uses_its_own_timings) {
    std::vector<uint8_t> tzx = tzx_header();
    append_tzx_turbo(tzx, tape_block(0xFF, {0xFF}), 1000, 50, 400, 800);

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "turbo.tzx"), std::string());
    t.play(0);
    const std::vector<uint64_t> ts =
        pulse_tstates(edges(t, 0, uint64_t(1000) * 200 * HC_PER_TSTATE));

    CHECK(ts.size() > 60);
    if (ts.size() <= 60) {
        return;
    }
    for (size_t i = 0; i + 1 < 50; i++) {
        CHECK_EQ(ts[i], uint64_t(1000));
    }
    size_t i = 49;
    CHECK_EQ(ts[i++], uint64_t(TAPE_SYNC1_T));
    CHECK_EQ(ts[i++], uint64_t(TAPE_SYNC2_T));
    // Flag 0xFF, so eight 1 bits at the block's own 800T.
    CHECK_EQ(ts[i], uint64_t(800));
}

TEST(tzx_pure_tone_and_pulse_sequence) {
    std::vector<uint8_t> tzx = tzx_header();
    tzx.push_back(0x12); // pure tone: 5 pulses of 1000T
    push16(tzx, 1000);
    push16(tzx, 5);
    tzx.push_back(0x13); // pulse sequence: three explicit lengths
    tzx.push_back(3);
    push16(tzx, 200);
    push16(tzx, 300);
    push16(tzx, 400);

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "tones.tzx"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(2));
    t.play(0);

    const std::vector<uint64_t> ts = pulse_tstates(edges(t, 0, 20000 * HC_PER_TSTATE));
    // A gap is only observable between two edges, so the first pulse's leading
    // edge and the last one's trailing edge are both invisible: five tone
    // pulses and three sequence pulses give six measurable gaps. Note there is
    // no pause between the two blocks -- neither carries one, so the sequence
    // runs straight on out of the tone.
    CHECK_EQ(ts.size(), size_t(6));
    if (ts.size() != 6) {
        return;
    }
    for (size_t i = 0; i < 4; i++) {
        CHECK_EQ(ts[i], uint64_t(1000));
    }
    CHECK_EQ(ts[4], uint64_t(200));
    CHECK_EQ(ts[5], uint64_t(300));
}

TEST(tzx_loop_repeats_its_body) {
    // The Speedlock leader shape: a short tone plus a marker pair, looped.
    // Skipping the loop instead of running it leaves a leader a fraction of
    // its real length, which is exactly why such a tape would not load.
    std::vector<uint8_t> tzx = tzx_header();
    tzx.push_back(0x24); // loop start
    push16(tzx, 4);
    tzx.push_back(0x12); // pure tone: 3 pulses of 1000T
    push16(tzx, 1000);
    push16(tzx, 3);
    tzx.push_back(0x13); // pulse sequence: one 500T marker
    tzx.push_back(1);
    push16(tzx, 500);
    tzx.push_back(0x25); // loop end

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "loop.tzx"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(8)); // two blocks, four times over
    t.play(0);

    // Four repetitions of (1000, 1000, 1000, 500) is sixteen pulses. As in
    // tzx_pure_tone_and_pulse_sequence, the very first leading edge and the
    // very last trailing edge are not observable, so what comes back is
    // fourteen gaps starting from the SECOND pulse.
    std::vector<uint64_t> want;
    for (size_t rep = 0; rep < 4; rep++) {
        want.push_back(1000);
        want.push_back(1000);
        want.push_back(1000);
        want.push_back(500);
    }
    want.erase(want.begin());
    want.pop_back();

    const std::vector<uint64_t> ts = pulse_tstates(edges(t, 0, 60000 * HC_PER_TSTATE));
    CHECK_EQ(ts.size(), want.size());
    if (ts.size() != want.size()) {
        return;
    }
    for (size_t i = 0; i < want.size(); i++) {
        CHECK_EQ(ts[i], want[i]);
    }
}

TEST(tzx_loop_with_a_count_of_one_plays_its_body_once) {
    std::vector<uint8_t> tzx = tzx_header();
    tzx.push_back(0x24);
    push16(tzx, 1);
    append_tzx_standard(tzx, tape_block(0xFF, {0x42}), TAPE_TAP_PAUSE_MS);
    tzx.push_back(0x25);

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "once.tzx"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(1));
}

TEST(tzx_an_unclosed_loop_still_loads) {
    // A malformed image is worth a warning, not a refusal: everything in it
    // is still perfectly playable, just without the repetitions.
    std::vector<uint8_t> tzx = tzx_header();
    tzx.push_back(0x24);
    push16(tzx, 10);
    append_tzx_standard(tzx, tape_block(0xFF, {0x42}), TAPE_TAP_PAUSE_MS);

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "unclosed.tzx"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(1));
    CHECK(!t.status(0).warnings.empty());
}

TEST(tzx_refuses_a_loop_that_would_expand_without_bound) {
    std::vector<uint8_t> tzx = tzx_header();
    tzx.push_back(0x24);
    push16(tzx, 65535);
    for (int i = 0; i < 8; i++) {
        append_tzx_standard(tzx, tape_block(0xFF, {0x42}), TAPE_TAP_PAUSE_MS);
    }
    tzx.push_back(0x25);

    Tape t;
    CHECK(!t.insert(tzx.data(), tzx.size(), "huge.tzx").empty());
    CHECK(!t.inserted());
}

TEST(tzx_metadata_does_not_shift_the_data) {
    const std::vector<uint8_t> block = tape_block(0xFF, {0x42});

    std::vector<uint8_t> plain = tzx_header();
    append_tzx_standard(plain, block, TAPE_TAP_PAUSE_MS);

    std::vector<uint8_t> noisy = tzx_header();
    noisy.push_back(0x30); // text description
    const std::string text = "Made by a test";
    noisy.push_back(uint8_t(text.size()));
    for (char c : text) {
        noisy.push_back(uint8_t(c));
    }
    noisy.push_back(0x21); // group start
    noisy.push_back(3);
    noisy.push_back('a');
    noisy.push_back('b');
    noisy.push_back('c');
    append_tzx_standard(noisy, block, TAPE_TAP_PAUSE_MS);
    noisy.push_back(0x22); // group end

    Tape a;
    Tape b;
    CHECK_EQ(a.insert(plain.data(), plain.size(), "a"), std::string());
    CHECK_EQ(b.insert(noisy.data(), noisy.size(), "b"), std::string());
    CHECK_EQ(a.status(0).blocks, b.status(0).blocks);
    CHECK_EQ(b.status(0).description, text);

    a.play(0);
    b.play(0);
    const uint64_t window = uint64_t(TAPE_PILOT_DATA_PULSES + 100) * TAPE_PILOT_T * HC_PER_TSTATE;
    CHECK(edges(a, 0, window) == edges(b, 0, window));
}

TEST(tzx_rejects_an_unsupported_block_by_id) {
    std::vector<uint8_t> tzx = tzx_header();
    tzx.push_back(0x19); // generalized data -- length is not knowable up front
    push16(tzx, 0);

    Tape t;
    const std::string error = t.insert(tzx.data(), tzx.size(), "gen.tzx");
    CHECK(!error.empty());
    CHECK(error.find("0x19") != std::string::npos);
}

TEST(tzx_rejects_a_future_major_version) {
    std::vector<uint8_t> tzx = tzx_header();
    tzx[8] = 2;
    Tape t;
    const std::string error = t.insert(tzx.data(), tzx.size(), "v2.tzx");
    CHECK(!error.empty());
    CHECK(error.find("version") != std::string::npos);
}

TEST(tzx_stop_block_halts_between_blocks) {
    const std::vector<uint8_t> block = tape_block(0xFF, {0x01});
    std::vector<uint8_t> tzx = tzx_header();
    tzx.push_back(0x20); // pause of zero == stop the tape
    push16(tzx, 0);
    append_tzx_standard(tzx, block, TAPE_TAP_PAUSE_MS);

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "stop.tzx"), std::string());
    t.play(0);
    // The stop block is instantaneous, so the very first read ends playback.
    t.ear_at(0);
    t.ear_at(1);
    CHECK(!t.playing());
    CHECK(!t.at_end()); // stopped at a marker, not finished

    // And Play resumes with the block that followed it.
    t.play(1000);
    CHECK(t.playing());
    CHECK(!edges(t, 1000, 1000 + uint64_t(TAPE_PILOT_T) * HC_PER_TSTATE * 10).empty());
}

// ---- the block listing -----------------------------------------------------

TEST(block_infos_name_a_tap_from_its_header) {
    const std::vector<uint8_t> code = {0xAF, 0xC9};
    const std::vector<uint8_t> image = make_tap(code, 0x8000);
    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "test.tap"), std::string());

    const std::vector<TapeBlockInfo>& infos = t.block_infos();
    CHECK_EQ(infos.size(), size_t(2));
    // code_header() writes type 3, which is CODE -- "Bytes" to a person.
    CHECK_EQ(infos[0].kind, std::string("Bytes"));
    CHECK_EQ(infos[0].name, std::string("test")); // padded to 10, trimmed back
    CHECK_EQ(infos[0].data_bytes, size_t(19));
    CHECK(infos[0].standard_speed);

    // The data block inherits the header's name, which is the only thing that
    // tells a reader of the list which file this three-megabyte block belongs
    // to.
    CHECK_EQ(infos[1].kind, std::string("Data"));
    CHECK_EQ(infos[1].name, std::string("test"));
    CHECK_EQ(infos[1].data_bytes, code.size() + 2); // flag and checksum
}

TEST(block_infos_report_a_program_header_as_one) {
    std::vector<uint8_t> header;
    header.push_back(0); // type 0 == PROGRAM
    const std::string name = "manic     ";
    for (char c : name) {
        header.push_back(uint8_t(c));
    }
    push16(header, 100);   // program length
    push16(header, 10);    // autostart line
    push16(header, 100);   // start of the variables
    std::vector<uint8_t> tap;
    append_tap_block(tap, tape_block(0x00, header));

    Tape t;
    CHECK_EQ(t.insert(tap.data(), tap.size(), "manic.tap"), std::string());
    CHECK_EQ(t.block_infos()[0].kind, std::string("Program"));
    CHECK_EQ(t.block_infos()[0].name, std::string("manic"));
}

TEST(block_infos_filter_an_unprintable_name) {
    // A header saved by a machine-code loader routinely carries whatever was
    // in memory here, including ZX keyword bytes above 0xA5.
    std::vector<uint8_t> header;
    header.push_back(3);
    const uint8_t raw[10] = {'o', 'k', 0x00, 0xF5, 0x9C, ' ', ' ', ' ', ' ', ' '};
    for (uint8_t c : raw) {
        header.push_back(c);
    }
    push16(header, 1);
    push16(header, 0x8000);
    push16(header, 0x8000);
    std::vector<uint8_t> tap;
    append_tap_block(tap, tape_block(0x00, header));

    Tape t;
    CHECK_EQ(t.insert(tap.data(), tap.size(), "odd.tap"), std::string());
    CHECK_EQ(t.block_infos()[0].name, std::string("ok???"));
}

TEST(block_info_durations_sum_to_the_total) {
    const std::vector<uint8_t> image = make_tap({0xAF, 0xC9}, 0x8000);
    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "test.tap"), std::string());

    uint64_t total = 0;
    for (const TapeBlockInfo& info : t.block_infos()) {
        total += info.duration_ms;
    }
    // Per-block millisecond truncation can lose up to 1ms a block against the
    // total, which is computed from the undivided half-clocks.
    const uint64_t reported = t.status(0).total_ms;
    CHECK(total <= reported);
    CHECK(reported - total <= t.block_infos().size());
}

TEST(block_infos_mark_a_turbo_block) {
    std::vector<uint8_t> tzx = tzx_header();
    append_tzx_standard(tzx, tape_block(0x00, code_header("fast", 0x8000, 2)), 100);
    append_tzx_turbo(tzx, tape_block(0xFF, {0x01, 0x02}), 1000, 50, 400, 800);

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "turbo.tzx"), std::string());
    const std::vector<TapeBlockInfo>& infos = t.block_infos();
    CHECK_EQ(infos.size(), size_t(2));
    CHECK(infos[0].standard_speed);
    CHECK_EQ(infos[0].id, uint8_t(0x10));
    CHECK(!infos[1].standard_speed); // why fast load will decline this one
    CHECK_EQ(infos[1].id, uint8_t(0x11));
}

TEST(block_infos_describe_the_blocks_with_no_data) {
    std::vector<uint8_t> tzx = tzx_header();
    tzx.push_back(0x12); // pure tone
    push16(tzx, 500);
    push16(tzx, 10);
    tzx.push_back(0x20); // pause of zero, i.e. stop the tape
    push16(tzx, 0);

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "signal.tzx"), std::string());
    const std::vector<TapeBlockInfo>& infos = t.block_infos();
    CHECK_EQ(infos.size(), size_t(2));
    CHECK_EQ(infos[0].kind, std::string("Pure tone"));
    CHECK_EQ(infos[0].data_bytes, size_t(0));
    CHECK_EQ(infos[1].kind, std::string("Stop the tape"));
    CHECK(infos[1].stop_tape);
}

TEST(ejecting_empties_the_listing_and_bumps_the_generation) {
    const std::vector<uint8_t> image = make_tap({0xAF, 0xC9}, 0x8000);
    Tape t;
    const uint64_t before = t.generation();
    CHECK_EQ(t.insert(image.data(), image.size(), "test.tap"), std::string());
    const uint64_t inserted = t.generation();
    CHECK(inserted != before);

    t.eject();
    CHECK(t.block_infos().empty());
    // The Engine's cache is keyed on this, so an eject that did not move it
    // would leave a viewer listing a tape that is no longer in the deck.
    CHECK(t.generation() != inserted);
}

// ---- seek ------------------------------------------------------------------

TEST(seek_starts_playback_at_the_chosen_block) {
    std::vector<uint8_t> tap;
    append_tap_block(tap, tape_block(0x00, code_header("one", 0x8000, 1)));
    append_tap_block(tap, tape_block(0xFF, {0x01}));
    append_tap_block(tap, tape_block(0x00, code_header("two", 0x9000, 1)));
    Tape t;
    CHECK_EQ(t.insert(tap.data(), tap.size(), "two-part.tap"), std::string());

    t.seek(2);
    CHECK_EQ(t.status(0).block, size_t(2));
    CHECK(!t.playing()); // seeking leaves the motor stopped
    CHECK(!t.at_end());

    // And playing from there produces block 2's leader -- the long one, since
    // block 2 is a header -- rather than block 0's.
    t.play(0);
    const std::vector<uint64_t> e =
        edges(t, 0, uint64_t(TAPE_PILOT_T) * HC_PER_TSTATE * 4);
    const std::vector<uint64_t> lengths = pulse_tstates(e);
    CHECK(!lengths.empty());
    CHECK_EQ(lengths[0], uint64_t(TAPE_PILOT_T));
}

TEST(seek_past_the_end_clamps) {
    const std::vector<uint8_t> image = make_tap({0xAF, 0xC9}, 0x8000);
    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "test.tap"), std::string());

    t.seek(99);
    CHECK_EQ(t.status(0).block, size_t(2)); // the block count, i.e. the end
    CHECK(t.at_end());
    // Nothing to play from there, and asking must not read off the array.
    t.play(0);
    CHECK(!t.playing());
}

TEST(seek_back_from_the_end_makes_the_tape_playable_again) {
    const std::vector<uint8_t> image = make_tap({0xAF, 0xC9}, 0x8000);
    Tape t;
    CHECK_EQ(t.insert(image.data(), image.size(), "test.tap"), std::string());
    t.seek(99);
    CHECK(t.at_end());

    t.seek(1);
    CHECK(!t.at_end());
    t.play(0);
    CHECK(t.playing());
    CHECK(!edges(t, 0, uint64_t(TAPE_PILOT_T) * HC_PER_TSTATE * 4).empty());
}

// ---- the fast-load trap ----------------------------------------------------

namespace {

/// Points the machine at LD-BYTES with the ROM's documented entry contract:
/// A = expected flag byte, carry set to load (clear to verify), DE = length,
/// IX = destination. The return address is pushed by hand, since a real caller
/// would have got there with a CALL.
void arm_ld_bytes(Spectrum48K& m, uint8_t flag, uint16_t dest, uint16_t len, bool loading,
                  uint16_t return_to) {
    Registers r = m.registers();
    r.sp = 0xFF00;
    const uint8_t ret[2] = {uint8_t(return_to & 0xFF), uint8_t(return_to >> 8)};
    m.write_memory(r.sp, ret, 2);
    r.a = flag;
    r.f = loading ? uint8_t(r.f | 0x01) : uint8_t(r.f & ~0x01);
    r.set_de(len);
    r.ix = dest;
    r.pc = 0x0556;
    m.set_registers(r);
}

/// A machine with the real ROM and a tape inserted and playing. Returns false
/// if the ROM is missing, so the caller can skip.
bool armed_machine(Spectrum48K& m, const std::vector<uint8_t>& image) {
    if (!load_rom(m)) {
        return false;
    }
    CHECK_EQ(m.tape.insert(image.data(), image.size(), "t.tap"), std::string());
    m.tape.set_fast_load(true);
    m.tape.play(m.global_hc());
    return true;
}

} // namespace

TEST(fast_load_satisfies_a_standard_block) {
    const std::vector<uint8_t> code = {0x11, 0x22, 0x33, 0x44};
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, code));

    Spectrum48K m;
    if (!armed_machine(m, image)) {
        return;
    }
    const uint64_t hc_before = m.global_hc();
    arm_ld_bytes(m, 0xFF, 0x8000, uint16_t(code.size()), true, 0x9000);
    m.step_instruction();

    const Registers r = m.registers();
    CHECK_EQ(r.pc, uint16_t(0x9000));            // returned to the caller
    CHECK_EQ(r.sp, uint16_t(0xFF02));            // and popped its address
    CHECK((r.f & 0x01) != 0);                    // carry set: loaded cleanly
    CHECK_EQ(r.de(), uint16_t(0));                 // all bytes consumed
    CHECK_EQ(r.ix, uint16_t(0x8000 + code.size()));
    CHECK_EQ(m.global_hc(), hc_before);          // and it cost no emulated time

    const std::vector<uint8_t> got = m.read_memory(0x8000, code.size());
    CHECK(got == code);
}

TEST(fast_load_reports_a_flag_mismatch) {
    // A data block on the tape, but the ROM is looking for a header. This is
    // how LD_LOOK_H walks forward to the block it wants, so the block must be
    // consumed even though the load "failed".
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0x01, 0x02}));
    append_tap_block(image, tape_block(0x00, code_header("x", 0x8000, 2)));

    Spectrum48K m;
    if (!armed_machine(m, image)) {
        return;
    }
    arm_ld_bytes(m, 0x00, 0x8000, 2, true, 0x9000);
    m.step_instruction();

    const Registers r = m.registers();
    CHECK_EQ(r.pc, uint16_t(0x9000));
    CHECK((r.f & 0x01) == 0); // carry clear: not the block we wanted
    CHECK_EQ(m.tape.status(m.global_hc()).block, size_t(1));
}

TEST(fast_load_detects_a_bad_checksum) {
    std::vector<uint8_t> block = tape_block(0xFF, {0xAA, 0xBB});
    block.back() = uint8_t(block.back() ^ 0xFF); // corrupt the checksum
    std::vector<uint8_t> image;
    append_tap_block(image, block);

    Spectrum48K m;
    if (!armed_machine(m, image)) {
        return;
    }
    arm_ld_bytes(m, 0xFF, 0x8000, 2, true, 0x9000);
    m.step_instruction();

    CHECK((m.registers().f & 0x01) == 0);
}

TEST(fast_load_verify_does_not_write_memory) {
    const std::vector<uint8_t> code = {0x11, 0x22};
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, code));

    Spectrum48K m;
    if (!armed_machine(m, image)) {
        return;
    }
    const uint8_t fill[2] = {0xEE, 0xEE};
    m.write_memory(0x8000, fill, 2);
    arm_ld_bytes(m, 0xFF, 0x8000, 2, /*loading=*/false, 0x9000);
    m.step_instruction();

    const std::vector<uint8_t> got = m.read_memory(0x8000, 2);
    CHECK_EQ(got[0], uint8_t(0xEE)); // untouched
    CHECK_EQ(got[1], uint8_t(0xEE));
    CHECK((m.registers().f & 0x01) == 0); // and the mismatch was reported
}

TEST(fast_load_declines_a_turbo_block) {
    std::vector<uint8_t> tzx = tzx_header();
    append_tzx_turbo(tzx, tape_block(0xFF, {0x01, 0x02}), 1000, 50, 400, 800);

    Spectrum48K m;
    if (!load_rom(m)) {
        return;
    }
    CHECK_EQ(m.tape.insert(tzx.data(), tzx.size(), "turbo.tzx"), std::string());
    m.tape.set_fast_load(true);
    m.tape.play(m.global_hc());

    arm_ld_bytes(m, 0xFF, 0x8000, 2, true, 0x9000);
    m.step_instruction();

    // The trap declined, so the real ROM ran its first instruction instead and
    // the tape is still spinning for it.
    CHECK(m.registers().pc != 0x9000);
    CHECK(m.tape.playing());
    CHECK_EQ(m.tape.status(m.global_hc()).block, size_t(0));
}

TEST(fast_load_declines_when_the_tape_is_stopped) {
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0x01, 0x02}));

    Spectrum48K m;
    if (!armed_machine(m, image)) {
        return;
    }
    m.tape.stop();
    arm_ld_bytes(m, 0xFF, 0x8000, 2, true, 0x9000);
    m.step_instruction();
    CHECK(m.registers().pc != 0x9000);
}

TEST(fast_load_ignores_a_non_stock_rom) {
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0x01, 0x02}));

    Spectrum48K m;
    if (!armed_machine(m, image)) {
        return;
    }
    // A "ROM" whose 0x0556 is not LD-BYTES. Loaded wholesale, since ROM is
    // write-protected through the bus.
    std::vector<uint8_t> rom(ROM_SIZE, 0x00); // NOPs everywhere
    CHECK_EQ(m.load_rom(rom.data(), rom.size()), std::string());

    arm_ld_bytes(m, 0xFF, 0x8000, 2, true, 0x9000);
    m.step_instruction();
    CHECK_EQ(m.registers().pc, uint16_t(0x0557)); // it just ran the NOP
}

TEST(fast_load_pops_exactly_one_call_stack_frame) {
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0x01, 0x02}));

    Spectrum48K m;
    if (!armed_machine(m, image)) {
        return;
    }
    arm_ld_bytes(m, 0xFF, 0x8000, 2, true, 0x9000);
    // set_registers() cleared the chain, so seed it as a real CALL would have.
    m.call_stack.push_back(0x1234);
    m.call_stack.push_back(0x9000);
    m.step_instruction();

    CHECK_EQ(m.call_stack.size(), size_t(1));
    CHECK_EQ(m.call_stack[0], uint16_t(0x1234));
}

// ---- the loading sound -------------------------------------------------------

TEST(a_pulse_load_is_audible_at_the_pilot_frequency) {
    // The ROM's loader never writes the speaker bit -- LD_SAMPLE ends
    // `AND $07 / OR $08 / OUT ($FE),A`, which is border bits plus an
    // unchanging MIC bit -- so if the EAR input were not mixed into the audio
    // output, loading a tape would be silent. This is the test that says it is
    // not, and that what comes out is the right note.
    //
    // A pilot pulse is 2168T, so a full cycle is 4336T and the tone is
    // 3.5e6/4336 = 807Hz -- 54.6 samples at 44.1kHz, 27.3 per half-cycle.
    // Measured from the waveform itself rather than through
    // estimate_frequency_hz(), which thresholds at a quarter of the buffer's
    // peak and so under-reads a signal whose loudest moment is a transient.
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, {0x00}));

    Spectrum48K m;
    if (!load_rom(m)) {
        return;
    }
    CHECK_EQ(m.tape.insert(image.data(), image.size(), "t.tap"), std::string());
    m.tape.set_fast_load(false);
    m.beeper.set_enabled(true, m.global_hc());

    arm_ld_bytes(m, 0xFF, 0x8000, 1, true, 0x9000);
    m.tape.play(m.global_hc());
    // Well inside the ~2s leader, so what is captured is pure pilot tone.
    for (uint32_t i = 0; i < 400'000 && m.registers().pc != 0x9000; i++) {
        m.step_instruction();
    }

    std::vector<int16_t> samples;
    m.beeper.drain(samples);
    CHECK(samples.size() > 2000);
    if (samples.size() <= 2000) {
        return;
    }

    float rms = 0.0f;
    float peak = 0.0f;
    measure_level(samples, rms, peak);
    CHECK(rms > 0.01f); // not silence -- the whole point

    // Half-cycle lengths over the tail, where the tone is established.
    std::vector<size_t> runs;
    size_t from = samples.size() - 2000;
    int sign = samples[from] > 0 ? 1 : -1;
    size_t run = 1;
    for (size_t i = from + 1; i < samples.size(); i++) {
        const int now = samples[i] > 0 ? 1 : -1;
        if (now == sign) {
            run++;
            continue;
        }
        runs.push_back(run);
        sign = now;
        run = 1;
    }
    CHECK(runs.size() > 20);
    if (runs.size() <= 20) {
        return;
    }
    // Median, so one clipped run at either end cannot move it.
    std::sort(runs.begin(), runs.end());
    const size_t median = runs[runs.size() / 2];
    CHECK(median >= 25 && median <= 30);
    if (median < 25 || median > 30) {
        std::printf("      half-cycle %zu samples, expected ~27 (807Hz)\n", median);
    }
}

TEST(no_tape_means_no_ear_contribution) {
    // The EAR term must not leave a DC offset sitting under everything when
    // there is no tape -- silence has to stay silent.
    Spectrum48K m;
    if (!load_rom(m)) {
        return;
    }
    m.beeper.set_enabled(true, m.global_hc());
    for (uint32_t i = 0; i < 50'000; i++) {
        m.step_instruction();
    }
    std::vector<int16_t> samples;
    m.beeper.drain(samples);
    float rms = 0.0f;
    float peak = 0.0f;
    measure_level(samples, rms, peak);
    CHECK(peak < 0.02f);
}

// ---- end to end ------------------------------------------------------------

TEST(auto_typed_load_reaches_the_edit_line) {
    Spectrum48K m;
    if (!load_rom(m)) {
        return;
    }
    CHECK_EQ(type_load_command(m), std::string());
}

TEST(the_real_rom_loads_a_block_through_pulses) {
    // The money test: fast load OFF, so the ROM's own LD-EDGE / LD-8-BITS code
    // reads the pulses this file generates, exactly as it would a cassette.
    // Nothing else exercises the timings end to end -- the parser tests only
    // prove we emit what we meant to, not that a real loader can read it.
    std::vector<uint8_t> code;
    for (uint32_t i = 0; i < 32; i++) {
        code.push_back(uint8_t(i * 7 + 1));
    }
    const uint16_t start = 0x8000;
    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0xFF, code));

    Spectrum48K m;
    if (!load_rom(m)) {
        return;
    }
    CHECK_EQ(m.tape.insert(image.data(), image.size(), "t.tap"), std::string());
    m.tape.set_fast_load(false);
    m.tape.play(m.global_hc());

    arm_ld_bytes(m, 0xFF, start, uint16_t(code.size()), true, 0x9000);
    // The ~2s leader plus the data is comfortably inside this; the loop exits
    // as soon as LD-BYTES returns, so the bound is only a backstop.
    for (uint32_t i = 0; i < 4'000'000 && m.registers().pc != 0x9000; i++) {
        m.step_instruction();
    }

    CHECK_EQ(m.registers().pc, uint16_t(0x9000));
    CHECK((m.registers().f & 0x01) != 0); // carry set: the ROM is happy
    const std::vector<uint8_t> got = m.read_memory(start, code.size());
    CHECK(got == code);
}

TEST(auto_typed_load_reads_a_whole_tape_through_pulses) {
    // The same again one level up: type LOAD "" and let the BASIC interpreter
    // find its own header and data block off the pulses. LOAD "" looks for a
    // PROGRAM header specifically, so this is the only shape of tape it will
    // accept.
    //
    // One BASIC line -- 10 REM ab -- as the interpreter stores it: line number
    // big-endian (the one big-endian field in the whole machine), then the
    // body length little-endian, then the tokens.
    const std::vector<uint8_t> program = {0x00, 0x0A, 0x04, 0x00, 0xEA, 0x61, 0x62, 0x0D};

    std::vector<uint8_t> header;
    header.push_back(0); // type 0 == Program
    for (size_t i = 0; i < 10; i++) {
        header.push_back(uint8_t(' '));
    }
    push16(header, uint32_t(program.size()));
    push16(header, 0x8000); // no autostart line
    push16(header, uint32_t(program.size())); // no variables follow

    std::vector<uint8_t> image;
    append_tap_block(image, tape_block(0x00, header));
    append_tap_block(image, tape_block(0xFF, program));

    Spectrum48K m;
    if (!load_rom(m)) {
        return;
    }
    CHECK_EQ(m.tape.insert(image.data(), image.size(), "prog.tap"), std::string());
    m.tape.set_fast_load(false);

    // type_load_command presses Play for us, just before it commits the line.
    CHECK_EQ(type_load_command(m), std::string());
    CHECK(m.tape.playing());

    // Both leaders, both blocks and the gap between them, with room to spare.
    for (uint32_t frame = 0; frame < 50 * 30; frame++) {
        m.run_frame();
        if (!m.tape.playing()) {
            break;
        }
    }
    // A few more frames for the interpreter to finish up after the last pulse.
    for (uint32_t frame = 0; frame < 50; frame++) {
        m.run_frame();
    }

    // PROG points at the start of the BASIC program area.
    const uint16_t prog = uint16_t(uint16_t(m.memory.read(0x5C53))
                                   | uint16_t(m.memory.read(0x5C54) << 8));
    const std::vector<uint8_t> got = m.read_memory(prog, program.size());
    CHECK(got == program);
}

RUN_TESTS()
