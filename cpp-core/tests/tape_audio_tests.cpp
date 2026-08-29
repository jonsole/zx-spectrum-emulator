// Audio-as-tape tests: .wav and .csw decoding, the Schmitt trigger, and the
// .tzx blocks that carry a recording inline.
//
// Every fixture is SYNTHESISED, as in tape_tests.cpp -- but here that buys
// something extra. The strongest test available is a ROUND TRIP: take a tape
// this project already plays correctly, render its own pulses out to a .wav at
// a real sample rate, dirty that .wav the way a cassette and a sound card
// would, feed it back in, and require the real ROM to load it. Nothing about
// that test can pass by agreeing with a bug, because the two ends are the
// emulator's playback and Sinclair's loader, and only the code under test sits
// between them.

#include "beeper.h"
#include "spectrum.h"
#include "tape.h"
#include "tape_audio.h"
#include "test_main.h"

#include <cmath>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

namespace {

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

void push32(std::vector<uint8_t>& out, uint32_t v) {
    push16(out, v & 0xFFFF);
    push16(out, (v >> 16) & 0xFFFF);
}

void push_tag(std::vector<uint8_t>& out, const char* tag) {
    for (size_t i = 0; i < 4; i++) {
        out.push_back(uint8_t(tag[i]));
    }
}

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

void append_tap_block(std::vector<uint8_t>& tap, const std::vector<uint8_t>& block) {
    push16(tap, uint32_t(block.size()));
    for (uint8_t v : block) {
        tap.push_back(v);
    }
}

// ---- .wav writing ----------------------------------------------------------

/// Builds a RIFF/WAVE file around `mono`, in whatever format the caller asks
/// for. `channels` duplicates the signal, which is what a stereo rip of a mono
/// cassette actually contains.
std::vector<uint8_t> make_wav(const std::vector<float>& mono, uint32_t rate, uint32_t bits,
                              uint32_t format, uint32_t channels = 1) {
    std::vector<uint8_t> body;
    const uint32_t bytes = bits / 8;
    for (float v : mono) {
        for (uint32_t c = 0; c < channels; c++) {
            if (format == 3 && bits == 32) {
                uint8_t raw[4];
                std::memcpy(raw, &v, 4);
                for (uint8_t b : raw) {
                    body.push_back(b);
                }
            } else if (format == 3) {
                const double d = double(v);
                uint8_t raw[8];
                std::memcpy(raw, &d, 8);
                for (uint8_t b : raw) {
                    body.push_back(b);
                }
            } else if (bits == 8) {
                body.push_back(uint8_t(int(v * 127.0f) + 128));
            } else if (bits == 16) {
                push16(body, uint32_t(uint16_t(int16_t(v * 32767.0f))));
            } else if (bits == 24) {
                const int32_t s = int32_t(v * 8388607.0f);
                body.push_back(uint8_t(s & 0xFF));
                body.push_back(uint8_t((s >> 8) & 0xFF));
                body.push_back(uint8_t((s >> 16) & 0xFF));
            } else {
                push32(body, uint32_t(int32_t(v * 2147483000.0f)));
            }
        }
    }

    std::vector<uint8_t> wav;
    push_tag(wav, "RIFF");
    push32(wav, uint32_t(36 + body.size()));
    push_tag(wav, "WAVE");
    push_tag(wav, "fmt ");
    push32(wav, 16);
    push16(wav, format);
    push16(wav, channels);
    push32(wav, rate);
    push32(wav, rate * channels * bytes); // byte rate
    push16(wav, channels * bytes);        // block align
    push16(wav, bits);
    push_tag(wav, "data");
    push32(wav, uint32_t(body.size()));
    for (uint8_t b : body) {
        wav.push_back(b);
    }
    return wav;
}

/// A square wave of `pulses` alternating half-cycles, each `pulse_t` T-states
/// long, sampled at `rate`.
std::vector<float> square(uint32_t pulse_t, uint32_t pulses, uint32_t rate,
                          float amplitude = 1.0f) {
    std::vector<float> out;
    const double samples_per_pulse = double(pulse_t) * double(rate) / 3'500'000.0;
    bool level = false;
    for (uint32_t p = 0; p < pulses; p++) {
        const size_t want = size_t(double(p + 1) * samples_per_pulse);
        while (out.size() < want) {
            out.push_back(level ? amplitude : -amplitude);
        }
        level = !level;
    }
    return out;
}

/// Plays a tape through the emulator's own pulse engine and samples the EAR
/// line at `rate` -- the exact inverse of what tape_audio.cpp does.
std::vector<float> render(Tape& t, uint32_t rate) {
    const uint64_t total_hc = uint64_t(t.status(0).total_ms + 200) * (HC_PER_SEC / 1000);
    t.play(0);
    std::vector<float> out;
    out.reserve(size_t(total_hc * rate / HC_PER_SEC) + 1);
    for (uint64_t i = 0;; i++) {
        const uint64_t hc = i * HC_PER_SEC / rate;
        if (hc >= total_hc) {
            break;
        }
        out.push_back(t.ear_at(hc) ? 1.0f : -1.0f);
    }
    return out;
}

/// A deterministic pseudo-random sequence. A fixed LCG rather than <random>
/// so a failure is reproducible on every platform and every run -- a test that
/// only sometimes decodes is worse than no test.
struct Noise {
    uint32_t state = 12345;
    float next() {
        state = state * 1664525u + 1013904223u;
        return float(int32_t(state >> 8) % 2001 - 1000) / 1000.0f;
    }
};

/// What a real rip looks like: quieter than full scale, sitting off centre,
/// with hiss on it. Every one of these defeats a fixed comparator at zero,
/// which is the whole reason EdgeDetector adapts.
std::vector<float> dirty(const std::vector<float>& clean, float amplitude, float offset,
                         float hiss) {
    Noise rng;
    std::vector<float> out;
    out.reserve(clean.size());
    for (size_t i = 0; i < clean.size(); i++) {
        // A slow drift on the offset too, well below the tape band, so the
        // baseline follower has something to actually follow.
        const float drift = offset * float(std::sin(double(i) * 0.0001));
        out.push_back(clean[i] * amplitude + drift + rng.next() * hiss);
    }
    return out;
}

// ---- .csw writing ----------------------------------------------------------

void push_csw_signature(std::vector<uint8_t>& out) {
    const char* sig = "Compressed Square Wave";
    for (size_t i = 0; i < 22; i++) {
        out.push_back(uint8_t(sig[i]));
    }
    out.push_back(0x1A);
}

/// The RLE body both .csw versions share: one byte per pulse length in
/// samples, or a zero escape and four bytes for a long one.
std::vector<uint8_t> csw_rle(const std::vector<uint32_t>& samples) {
    std::vector<uint8_t> out;
    for (uint32_t n : samples) {
        if (n > 0 && n < 256) {
            out.push_back(uint8_t(n));
        } else {
            out.push_back(0);
            push32(out, n);
        }
    }
    return out;
}

std::vector<uint8_t> make_csw1(const std::vector<uint32_t>& samples, uint32_t rate) {
    std::vector<uint8_t> out;
    push_csw_signature(out);
    out.push_back(1); // major
    out.push_back(1); // minor
    push16(out, rate);
    out.push_back(1); // RLE
    out.push_back(0); // flags: initial polarity
    out.push_back(0); // reserved
    out.push_back(0);
    out.push_back(0);
    for (uint8_t b : csw_rle(samples)) {
        out.push_back(b);
    }
    return out;
}

/// Wraps `raw` as a zlib stream using DEFLATE's stored-block encoding.
///
/// Written by hand rather than reached for from a library because the project
/// vendors miniz's DECOMPRESSOR ONLY -- there is no deflate to call. A stored
/// block is a legal deflate stream, so this exercises the real tinfl path:
/// zlib header, block framing and adler32 all have to be right or nothing
/// comes back.
std::vector<uint8_t> zlib_stored(const std::vector<uint8_t>& raw) {
    std::vector<uint8_t> out;
    out.push_back(0x78); // CM = 8 (deflate), CINFO = 7 (32K window)
    out.push_back(0x01); // FCHECK, chosen so the pair is a multiple of 31
    size_t at = 0;
    while (at < raw.size() || at == 0) {
        const size_t n = raw.size() - at < 65535 ? raw.size() - at : size_t(65535);
        const bool last = at + n >= raw.size();
        out.push_back(last ? 1 : 0); // BFINAL, BTYPE = 00 (stored)
        push16(out, uint32_t(n));
        push16(out, uint32_t(~n & 0xFFFF));
        for (size_t i = 0; i < n; i++) {
            out.push_back(raw[at + i]);
        }
        at += n;
        if (last) {
            break;
        }
    }
    uint32_t a = 1;
    uint32_t b = 0;
    for (uint8_t v : raw) {
        a = (a + v) % 65521;
        b = (b + a) % 65521;
    }
    const uint32_t adler = (b << 16) | a;
    out.push_back(uint8_t((adler >> 24) & 0xFF)); // big-endian, unlike everything else
    out.push_back(uint8_t((adler >> 16) & 0xFF));
    out.push_back(uint8_t((adler >> 8) & 0xFF));
    out.push_back(uint8_t(adler & 0xFF));
    return out;
}

std::vector<uint8_t> make_csw2(const std::vector<uint32_t>& samples, uint32_t rate,
                               bool compressed) {
    std::vector<uint8_t> out;
    push_csw_signature(out);
    out.push_back(2); // major
    out.push_back(0); // minor
    push32(out, rate);
    push32(out, uint32_t(samples.size()));
    out.push_back(compressed ? 2 : 1);
    out.push_back(0); // flags
    out.push_back(0); // no header extension
    for (size_t i = 0; i < 16; i++) {
        out.push_back(uint8_t(i < 4 ? "test"[i] : 0)); // encoding application
    }
    const std::vector<uint8_t> rle = csw_rle(samples);
    const std::vector<uint8_t> body = compressed ? zlib_stored(rle) : rle;
    for (uint8_t b : body) {
        out.push_back(b);
    }
    return out;
}

/// Pulse lengths in T-states, from the edges the tape actually produces.
std::vector<uint64_t> pulse_tstates(Tape& t, uint64_t hc_len) {
    std::vector<uint64_t> out;
    bool prev = t.ear_at(0);
    uint64_t last_edge = 0;
    bool started = false;
    for (uint64_t hc = 1; hc < hc_len; hc++) {
        const bool now = t.ear_at(hc);
        if (now != prev) {
            if (started) {
                out.push_back((hc - last_edge) / HC_PER_TSTATE);
            }
            started = true;
            last_edge = hc;
            prev = now;
        }
    }
    return out;
}

/// The two-block .tap the round-trip tests load: a PROGRAM header and one
/// short BASIC line, which is the only shape LOAD "" accepts.
std::vector<uint8_t> program_tap(const std::vector<uint8_t>& program) {
    std::vector<uint8_t> header;
    header.push_back(0); // type 0 == Program
    for (size_t i = 0; i < 10; i++) {
        header.push_back(uint8_t(' '));
    }
    push16(header, uint32_t(program.size()));
    push16(header, 0x8000);                   // no autostart line
    push16(header, uint32_t(program.size())); // no variables follow

    std::vector<uint8_t> tap;
    append_tap_block(tap, tape_block(0x00, header));
    append_tap_block(tap, tape_block(0xFF, program));
    return tap;
}

} // namespace

// ---- the trigger -----------------------------------------------------------

TEST(wav_recovers_a_clean_square_wave) {
    // 200 pulses of the ROM's pilot length. What comes back should be that
    // same length, to within the sample period: at 44.1kHz one sample is 79
    // T-states, and the trigger cannot resolve better than the recording does.
    const std::vector<float> sig = square(TAPE_PILOT_T, 200, 44100);
    const std::vector<uint8_t> wav = make_wav(sig, 44100, 16, 1);

    EdgeList edges;
    CHECK_EQ(decode_wav(wav.data(), wav.size(), edges), std::string());
    CHECK_EQ(edges.sample_rate, uint32_t(44100));
    CHECK(edges.pulses.size() >= 195);
    if (edges.pulses.size() < 195) {
        return;
    }
    for (size_t i = 1; i + 1 < edges.pulses.size(); i++) {
        const int64_t error = int64_t(edges.pulses[i]) - int64_t(TAPE_PILOT_T);
        CHECK(error > -80 && error < 80);
    }
}

TEST(wav_recovers_a_quiet_offset_noisy_square_wave) {
    // The same signal as a real rip: a fifth of full scale, sitting off centre
    // and drifting, with hiss a third the size of the signal itself. A fixed
    // comparator at zero returns nothing useful from this.
    const std::vector<float> sig = dirty(square(TAPE_PILOT_T, 200, 44100), 0.2f, 0.35f, 0.06f);
    const std::vector<uint8_t> wav = make_wav(sig, 44100, 16, 1);

    EdgeList edges;
    CHECK_EQ(decode_wav(wav.data(), wav.size(), edges), std::string());
    CHECK(edges.pulses.size() >= 195);
    if (edges.pulses.size() < 195) {
        return;
    }
    for (size_t i = 1; i + 1 < edges.pulses.size(); i++) {
        const int64_t error = int64_t(edges.pulses[i]) - int64_t(TAPE_PILOT_T);
        CHECK(error > -120 && error < 120);
    }
}

TEST(wav_silence_produces_no_edges) {
    // The property the block splitting depends on: hiss with no signal under
    // it must read as nothing at all, or every gap between blocks fills with
    // spurious edges and the recording becomes one undivided lump.
    Noise rng;
    std::vector<float> hiss;
    for (size_t i = 0; i < 44100; i++) {
        hiss.push_back(rng.next() * 0.004f);
    }
    const std::vector<uint8_t> wav = make_wav(hiss, 44100, 16, 1);

    EdgeList edges;
    // No signal at all is an error rather than an empty success: a caller
    // handed a music file should be told, not given a silent tape.
    CHECK(!decode_wav(wav.data(), wav.size(), edges).empty());
    CHECK(edges.pulses.empty());
}

TEST(wav_reads_every_sample_format) {
    // 8/16/24/32-bit PCM and 32/64-bit float, mono and stereo, all carrying
    // one signal -- so all eight must agree on what that signal was.
    struct Variant {
        uint32_t bits;
        uint32_t format;
        uint32_t channels;
    };
    const Variant variants[] = {
        {8, 1, 1},  {16, 1, 1}, {24, 1, 1}, {32, 1, 1},
        {32, 3, 1}, {64, 3, 1}, {16, 1, 2}, {32, 3, 2},
    };
    const std::vector<float> sig = square(TAPE_PILOT_T, 100, 44100, 0.8f);

    for (const Variant& v : variants) {
        const std::vector<uint8_t> wav = make_wav(sig, 44100, v.bits, v.format, v.channels);
        EdgeList edges;
        const std::string error = decode_wav(wav.data(), wav.size(), edges);
        CHECK_EQ(error, std::string());
        CHECK(edges.pulses.size() >= 95);
        if (edges.pulses.size() < 95) {
            std::printf("      (was %u-bit format %u, %u channels)\n", v.bits, v.format,
                        v.channels);
            continue;
        }
        const int64_t error_t = int64_t(edges.pulses[10]) - int64_t(TAPE_PILOT_T);
        CHECK(error_t > -80 && error_t < 80);
    }
}

TEST(wav_skips_chunks_it_does_not_know) {
    // Rippers put LIST/INFO between "fmt " and "data" constantly. Reading the
    // header at a fixed offset would take the chunk tag for samples.
    const std::vector<float> sig = square(TAPE_PILOT_T, 60, 44100);
    std::vector<uint8_t> wav = make_wav(sig, 44100, 16, 1);

    std::vector<uint8_t> extra;
    push_tag(extra, "LIST");
    push32(extra, 10);
    for (size_t i = 0; i < 10; i++) {
        extra.push_back(uint8_t('x'));
    }
    // Spliced in after "WAVE", ahead of the format chunk.
    wav.insert(wav.begin() + 12, extra.begin(), extra.end());
    // And the RIFF size fixed up to match.
    const uint32_t size = uint32_t(wav.size() - 8);
    wav[4] = uint8_t(size & 0xFF);
    wav[5] = uint8_t((size >> 8) & 0xFF);
    wav[6] = uint8_t((size >> 16) & 0xFF);
    wav[7] = uint8_t((size >> 24) & 0xFF);

    EdgeList edges;
    CHECK_EQ(decode_wav(wav.data(), wav.size(), edges), std::string());
    CHECK(edges.pulses.size() >= 55);
}

TEST(wav_rejects_what_it_cannot_read) {
    const std::vector<float> sig = square(TAPE_PILOT_T, 20, 44100);

    // A compressed .wav.
    std::vector<uint8_t> adpcm = make_wav(sig, 44100, 16, 1);
    adpcm[20] = 0x11; // format 17, IMA ADPCM
    EdgeList edges;
    CHECK(!decode_wav(adpcm.data(), adpcm.size(), edges).empty());

    // A sample rate no tape pulse survives.
    const std::vector<uint8_t> slow = make_wav(sig, 2000, 16, 1);
    CHECK(!decode_wav(slow.data(), slow.size(), edges).empty());

    // Something that is not a .wav at all.
    const std::vector<uint8_t> junk(64, 0x42);
    CHECK(!looks_like_wav(junk.data(), junk.size()));
    CHECK(!decode_wav(junk.data(), junk.size(), edges).empty());
}

// ---- .csw ------------------------------------------------------------------

TEST(csw_v1_reads_its_pulse_list) {
    // 100 samples at 44100Hz is 7936 T-states; 44 is 3492.
    const std::vector<uint32_t> samples = {100, 44, 100, 44, 100, 44};
    const std::vector<uint8_t> csw = make_csw1(samples, 44100);

    CHECK(looks_like_csw(csw.data(), csw.size()));
    EdgeList edges;
    CHECK_EQ(decode_csw(csw.data(), csw.size(), edges), std::string());
    CHECK_EQ(edges.pulses.size(), size_t(6));
    if (edges.pulses.size() != 6) {
        return;
    }
    for (size_t i = 0; i < 6; i++) {
        const uint64_t want = uint64_t(samples[i]) * 3'500'000 / 44100;
        const int64_t error = int64_t(edges.pulses[i]) - int64_t(want);
        CHECK(error > -2 && error < 2);
    }
}

TEST(csw_v2_reads_both_uncompressed_and_z_rle) {
    const std::vector<uint32_t> samples = {100, 44, 100, 44, 100, 44, 300000, 100};

    EdgeList plain;
    const std::vector<uint8_t> a = make_csw2(samples, 44100, false);
    CHECK_EQ(decode_csw(a.data(), a.size(), plain), std::string());

    EdgeList packed;
    const std::vector<uint8_t> b = make_csw2(samples, 44100, true);
    CHECK_EQ(decode_csw(b.data(), b.size(), packed), std::string());

    // The compression is supposed to be lossless, so this is an equality and
    // not an approximation.
    CHECK(plain.pulses == packed.pulses);
    CHECK_EQ(plain.pulses.size(), samples.size());
    // The zero-escape path: 300000 samples will not fit in a byte. Within a
    // T-state rather than exact, because the length is the difference of two
    // absolute positions and neither lands on a whole T-state.
    if (plain.pulses.size() == samples.size()) {
        const int64_t error =
            int64_t(plain.pulses[6]) - int64_t(uint64_t(300000) * 3'500'000 / 44100);
        CHECK(error > -2 && error < 2);
    }
}

TEST(csw_pulse_positions_do_not_drift) {
    // 40,000 pulses whose sample lengths do not divide evenly into T-states.
    // Rounding each one on its own would put the end of the recording several
    // hundred T-states adrift; positions are differenced from an absolute
    // count precisely so they do not.
    std::vector<uint32_t> samples(40000, 37);
    const std::vector<uint8_t> csw = make_csw2(samples, 44100, false);

    EdgeList edges;
    CHECK_EQ(decode_csw(csw.data(), csw.size(), edges), std::string());
    CHECK_EQ(edges.pulses.size(), size_t(40000));

    uint64_t total = 0;
    for (uint32_t p : edges.pulses) {
        total += p;
    }
    const uint64_t want = uint64_t(40000) * 37 * 3'500'000 / 44100;
    const int64_t error = int64_t(total) - int64_t(want);
    CHECK(error > -2 && error < 2);
}

TEST(csw_rejects_what_it_cannot_read) {
    EdgeList edges;
    std::vector<uint8_t> csw = make_csw1({100, 44}, 44100);
    csw[0x17] = 9; // a major version that does not exist
    CHECK(!decode_csw(csw.data(), csw.size(), edges).empty());

    std::vector<uint8_t> bad_zlib = make_csw2({100, 44}, 44100, true);
    bad_zlib[bad_zlib.size() - 8] ^= 0xFF; // corrupt the stored-block framing
    CHECK(!decode_csw(bad_zlib.data(), bad_zlib.size(), edges).empty());
}

// ---- into the deck ---------------------------------------------------------

TEST(a_recording_is_cut_into_blocks_at_its_silences) {
    // Two bursts of signal a second apart, which is what a header, a gap and a
    // data block look like to a microphone.
    const uint32_t rate = 44100;
    std::vector<float> sig = square(TAPE_PILOT_T, 400, rate);
    for (size_t i = 0; i < rate; i++) { // one second of nothing
        sig.push_back(0.0f);
    }
    const std::vector<float> more = square(TAPE_PILOT_T, 400, rate);
    sig.insert(sig.end(), more.begin(), more.end());
    const std::vector<uint8_t> wav = make_wav(sig, rate, 16, 1);

    Tape t;
    CHECK_EQ(t.insert(wav.data(), wav.size(), "two.wav"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(2));
    CHECK_EQ(t.block_infos().size(), size_t(2));
    if (t.block_infos().size() != 2) {
        return;
    }
    CHECK_EQ(t.block_infos()[0].kind, std::string("Recording"));
    CHECK(!t.block_infos()[0].standard_speed);
    // The silence became the first block's pause, so it is still in the total.
    CHECK(t.block_infos()[0].pause_ms > 900 && t.block_infos()[0].pause_ms < 1100);
}

TEST(a_click_in_a_silence_does_not_split_a_block) {
    // One stray edge pair in the middle of a gap would otherwise cut a leader
    // into three "blocks". MIN_AUDIO_BLOCK_PULSES is what stops it, and it
    // must do so without changing how long the tape is.
    const uint32_t rate = 44100;
    std::vector<float> sig = square(TAPE_PILOT_T, 400, rate);
    for (size_t i = 0; i < rate; i++) {
        sig.push_back(0.0f);
    }
    // A four-pulse click, then the rest of the silence.
    const std::vector<float> click = square(TAPE_PILOT_T, 4, rate);
    sig.insert(sig.end(), click.begin(), click.end());
    for (size_t i = 0; i < rate; i++) {
        sig.push_back(0.0f);
    }
    const std::vector<float> more = square(TAPE_PILOT_T, 400, rate);
    sig.insert(sig.end(), more.begin(), more.end());
    const std::vector<uint8_t> wav = make_wav(sig, rate, 16, 1);

    Tape t;
    CHECK_EQ(t.insert(wav.data(), wav.size(), "click.wav"), std::string());
    // Two real blocks, not four: the click joins the block in front of it.
    CHECK_EQ(t.status(0).blocks, size_t(2));
    // And the tape is still as long as it was: two seconds of silence either
    // side of the click, plus two leaders of 400 pilot pulses (400 * 2168T is
    // a shade under a quarter of a second each).
    const uint64_t total = t.status(0).total_ms;
    CHECK(total > 2350 && total < 2700);
}

TEST(a_coarse_recording_still_loads_but_says_so) {
    const std::vector<float> sig = square(TAPE_PILOT_T, 200, 11025);
    const std::vector<uint8_t> wav = make_wav(sig, 11025, 16, 1);

    Tape t;
    CHECK_EQ(t.insert(wav.data(), wav.size(), "coarse.wav"), std::string());
    CHECK(t.inserted());
    CHECK(!t.status(0).warnings.empty());
}

TEST(a_failed_recording_leaves_the_previous_tape_alone) {
    const std::vector<float> sig = square(TAPE_PILOT_T, 100, 44100);
    const std::vector<uint8_t> good = make_wav(sig, 44100, 16, 1);

    Tape t;
    CHECK_EQ(t.insert(good.data(), good.size(), "good.wav"), std::string());
    const size_t blocks = t.status(0).blocks;

    std::vector<uint8_t> bad = make_wav(sig, 44100, 16, 1);
    bad[20] = 0x11; // ADPCM
    CHECK(!t.insert(bad.data(), bad.size(), "bad.wav").empty());
    CHECK(t.inserted());
    CHECK_EQ(t.status(0).blocks, blocks);
}

// ---- .tzx blocks that carry a recording ------------------------------------

TEST(tzx_direct_recording_replays_its_runs) {
    // 0x15: one bit per sample at 79 T-states, so 0b11110000 is a pulse of
    // four samples high then four low. Two bytes make four runs.
    std::vector<uint8_t> tzx = {'Z', 'X', 'T', 'a', 'p', 'e', '!', 0x1A, 1, 20};
    tzx.push_back(0x15);
    push16(tzx, 79);  // T-states per sample
    push16(tzx, 100); // pause
    tzx.push_back(8); // all bits of the last byte used
    tzx.push_back(2); // three-byte length
    tzx.push_back(0);
    tzx.push_back(0);
    tzx.push_back(0xF0);
    tzx.push_back(0x0F);

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "direct.tzx"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(1));
    CHECK_EQ(t.block_infos()[0].kind, std::string("Recording"));

    t.play(0);
    const std::vector<uint64_t> ts = pulse_tstates(t, 100000 * HC_PER_TSTATE);
    // 0xF0 0x0F is runs of four 1s, eight 0s, four 1s -- so pulses of 4, 8 and
    // 4 samples. As everywhere else in the suite the first pulse's LEADING
    // edge is not observable (there is nothing before it to measure from), so
    // what comes back is the last two: 8 samples then 4.
    CHECK(ts.size() >= 2);
    if (ts.size() < 2) {
        return;
    }
    CHECK_EQ(ts[0], uint64_t(8 * 79));
    CHECK_EQ(ts[1], uint64_t(4 * 79));
}

TEST(tzx_csw_block_replays_its_pulses) {
    const std::vector<uint32_t> samples = {100, 44, 100, 44};
    const std::vector<uint8_t> rle = csw_rle(samples);
    const std::vector<uint8_t> packed = zlib_stored(rle);

    std::vector<uint8_t> tzx = {'Z', 'X', 'T', 'a', 'p', 'e', '!', 0x1A, 1, 20};
    tzx.push_back(0x18);
    push32(tzx, uint32_t(10 + packed.size())); // length, excluding itself
    push16(tzx, 50);                           // pause
    tzx.push_back(uint8_t(44100 & 0xFF));      // sampling rate, three bytes
    tzx.push_back(uint8_t((44100 >> 8) & 0xFF));
    tzx.push_back(uint8_t((44100 >> 16) & 0xFF));
    tzx.push_back(2); // Z-RLE
    push32(tzx, uint32_t(samples.size()));
    for (uint8_t b : packed) {
        tzx.push_back(b);
    }

    Tape t;
    CHECK_EQ(t.insert(tzx.data(), tzx.size(), "csw.tzx"), std::string());
    CHECK_EQ(t.status(0).blocks, size_t(1));
    CHECK_EQ(t.block_infos()[0].kind, std::string("Recording"));

    t.play(0);
    const std::vector<uint64_t> ts = pulse_tstates(t, 200000 * HC_PER_TSTATE);
    CHECK(ts.size() >= 2);
    if (ts.size() >= 2) {
        // Within a T-state: the lengths are differences of absolute sample
        // positions, so neither is exactly the naive per-pulse rounding.
        const int64_t e0 = int64_t(ts[0]) - int64_t(uint64_t(44) * 3'500'000 / 44100);
        const int64_t e1 = int64_t(ts[1]) - int64_t(uint64_t(100) * 3'500'000 / 44100);
        CHECK(e0 > -2 && e0 < 2);
        CHECK(e1 > -2 && e1 < 2);
    }
}

TEST(tzx_still_refuses_the_blocks_it_cannot_size) {
    // 0x19's body length is only knowable by understanding the body, so it is
    // still a refusal rather than a skip -- guessing would desync everything
    // after it.
    std::vector<uint8_t> tzx = {'Z', 'X', 'T', 'a', 'p', 'e', '!', 0x1A, 1, 20};
    tzx.push_back(0x19);
    push32(tzx, 8);
    for (size_t i = 0; i < 8; i++) {
        tzx.push_back(0);
    }
    Tape t;
    CHECK(!t.insert(tzx.data(), tzx.size(), "gen.tzx").empty());
}

// ---- the round trip --------------------------------------------------------

TEST(a_tape_rendered_to_wav_reads_back_the_same_pulses) {
    // Render a .tap's pulses to 44.1kHz audio, decode that audio, and compare
    // against the pulses we started from. This is the tightest statement the
    // trigger can be held to: not "it found some edges" but "it found THESE
    // edges, at these lengths".
    const std::vector<uint8_t> tap = program_tap({0x00, 0x0A, 0x04, 0x00, 0xEA, 0x61, 0x62, 0x0D});

    Tape source;
    CHECK_EQ(source.insert(tap.data(), tap.size(), "src.tap"), std::string());
    const std::vector<float> audio = render(source, 44100);
    const std::vector<uint8_t> wav = make_wav(audio, 44100, 16, 1);

    Tape source_again;
    CHECK_EQ(source_again.insert(tap.data(), tap.size(), "src.tap"), std::string());
    source_again.play(0);
    // The same window render() used, to the half-clock. A shorter one here
    // would stop before the final pause's closing edge, and the two lists
    // would differ by a pulse for a reason that has nothing to do with the
    // decoder.
    const uint64_t window = uint64_t(source_again.status(0).total_ms + 200) * (HC_PER_SEC / 1000);
    const std::vector<uint64_t> want = pulse_tstates(source_again, window);

    // Compared against the DECODED edge list, not against a second tape built
    // from it and measured again. Both sides then discard exactly one edge --
    // the leading one, which has nothing before it to be measured from -- so
    // the two lists start at the same pulse. Playing the decoded tape back
    // would discard a second, and the whole comparison would sit one pulse out
    // of step: invisible through the pilot tone, where every pulse is the same
    // length as the last, and glaring the moment the data starts.
    EdgeList got;
    CHECK_EQ(decode_wav(wav.data(), wav.size(), got), std::string());

    CHECK(want.size() > 10000);
    CHECK(got.pulses.size() > 10000);
    CHECK_EQ(got.pulses.size(), want.size());

    size_t compared = 0;
    size_t close = 0;
    const size_t n = want.size() < got.pulses.size() ? want.size() : got.pulses.size();
    for (size_t i = 0; i < n; i++) {
        compared++;
        const int64_t error = int64_t(got.pulses[i]) - int64_t(want[i]);
        if (error > -100 && error < 100) {
            close++;
        }
    }
    // Every pulse, not merely most: at 44.1kHz the quantisation is 79
    // T-states, comfortably inside the tolerance, so a mismatch means a real
    // edge was invented or lost rather than merely rounded.
    CHECK_EQ(close, compared);
}

TEST(a_recording_is_audible_as_it_loads) {
    // tape_tests.cpp proves a .tap is audible as it loads, by way of the EAR
    // input being mixed into the audio output. This is the same statement for
    // a tape that arrived as audio, and it is worth making separately: a
    // recording reaches the beeper through the same set_ear() call but a
    // different parse path, and "loads perfectly, in total silence" is exactly
    // the kind of regression nothing else here would catch.
    // It has to be an actual LOAD, not merely a tape with its motor running.
    // The EAR level is resolved inside the port 0xFE READ branch, so what
    // makes the sound is the LOADER POLLING that port thousands of times a
    // second. Sitting at the BASIC prompt the ROM reads it only during the
    // interrupt's key scan -- a few hundred times a second, nowhere near
    // enough to reproduce an 800Hz tone -- so a tape playing to nothing is
    // very nearly silent. See the note in spectrum.cpp's port read.
    const std::vector<uint8_t> tap = program_tap({0x00, 0x0A, 0x04, 0x00, 0xEA, 0x61, 0x62, 0x0D});
    Tape source;
    CHECK_EQ(source.insert(tap.data(), tap.size(), "src.tap"), std::string());
    const std::vector<uint8_t> wav = make_wav(render(source, 44100), 44100, 16, 1);

    Spectrum48K m;
    if (!load_rom(m)) {
        return;
    }
    CHECK_EQ(m.tape.insert(wav.data(), wav.size(), "prog.wav"), std::string());
    CHECK_EQ(type_load_command(m), std::string());
    m.beeper.set_enabled(true, m.global_hc());

    // A second of loading, well inside the header's leader.
    for (uint32_t frame = 0; frame < 50; frame++) {
        m.run_frame();
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
}

TEST(the_real_rom_loads_a_wav_recording) {
    // The whole point, end to end. A .tap goes out as audio at 44.1kHz, gets
    // the treatment a real rip has had -- a fifth of full scale, a drifting DC
    // offset, and hiss -- and the ROM's own LD-BYTES has to read a BASIC
    // program back off it through LOAD "". Fast load is irrelevant here and
    // stays off: a recording is never a standard block.
    const std::vector<uint8_t> program = {0x00, 0x0A, 0x04, 0x00, 0xEA, 0x61, 0x62, 0x0D};
    const std::vector<uint8_t> tap = program_tap(program);

    Tape source;
    CHECK_EQ(source.insert(tap.data(), tap.size(), "src.tap"), std::string());
    const std::vector<float> clean = render(source, 44100);
    const std::vector<uint8_t> wav = make_wav(dirty(clean, 0.2f, 0.35f, 0.05f), 44100, 16, 1);

    Spectrum48K m;
    if (!load_rom(m)) {
        return;
    }
    CHECK_EQ(m.tape.insert(wav.data(), wav.size(), "prog.wav"), std::string());
    m.tape.set_fast_load(false);

    CHECK_EQ(type_load_command(m), std::string());
    CHECK(m.tape.playing());

    for (uint32_t frame = 0; frame < 50 * 30; frame++) {
        m.run_frame();
        if (!m.tape.playing()) {
            break;
        }
    }
    for (uint32_t frame = 0; frame < 50; frame++) {
        m.run_frame();
    }

    const uint16_t prog = uint16_t(uint16_t(m.memory.read(0x5C53))
                                   | uint16_t(m.memory.read(0x5C54) << 8));
    const std::vector<uint8_t> got = m.read_memory(prog, program.size());
    CHECK(got == program);
}

RUN_TESTS()
