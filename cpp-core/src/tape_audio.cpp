#include "tape_audio.h"

#include "ula.h" // HC_PER_TSTATE

#include <cmath>
#include <cstring>
#include <string>

// Only tinfl is compiled in -- see third_party/miniz/README.zx.md for the
// defines that strip the rest. Included as a system header by CMake, so its
// own warnings do not fail our /WX build.
#include "miniz/miniz.h"

namespace zx {
namespace {

/// The Spectrum's CPU clock. Every duration in a tape image is in these, and
/// every duration in a recording arrives in samples, so this is the constant
/// that joins the two worlds.
constexpr uint64_t T_PER_SEC = 3'500'000;

/// A recording slower than this cannot resolve a tape pulse at all -- the
/// shortest a turbo loader uses is around 250 T-states, or 70 microseconds --
/// so a file claiming one is a misparse rather than a hard-to-read rip.
constexpr uint32_t MIN_SAMPLE_RATE = 4'000;
/// And one faster than this is a misparse in the other direction.
constexpr uint32_t MAX_SAMPLE_RATE = 768'000;

// ---- the Schmitt trigger's constants ---------------------------------------

/// Time constant over which the two rails fall back toward each other. Chosen
/// relative to the SIGNAL, not to anything about audio in general: it has to
/// be long enough to hold both rails open across a whole pulse of the slowest
/// thing a tape carries -- a pilot tone at ~808Hz, so 1.2ms a cycle -- and
/// short enough to follow a rip whose level changes over the side.
constexpr float PEAK_DECAY_MS = 20.0f;
/// Hysteresis, as a fraction of the distance between the rails. A quarter is
/// wide enough to reject tape hiss riding on a full-amplitude signal, narrow
/// enough not to miss the shortest turbo pulse.
constexpr float TRIGGER_FRACTION = 0.25f;
/// The floor under the hysteresis, as a fraction of full scale. This is what
/// makes silence read as silence: without it the rails close in on the noise,
/// the threshold follows them down, and hiss becomes tens of thousands of
/// edges a second -- which is both nonsense and the fastest way to hit
/// MAX_AUDIO_PULSES. It is also what lets tape.cpp find the gaps BETWEEN
/// blocks, since those are exactly the stretches with no edges in them.
///
/// Two percent of full scale, which is comfortably above the hiss on any rip
/// worth loading and comfortably below the signal on a badly quiet one. A rip
/// whose noise is louder than this will chatter through its silences; the cost
/// of that is a listing that does not split into blocks, not a tape that fails
/// to load.
constexpr float NOISE_FLOOR = 0.02f;

uint32_t read_u16(const uint8_t* p) { return uint32_t(p[0]) | (uint32_t(p[1]) << 8); }

uint32_t read_u24(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16);
}

uint32_t read_u32(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16)
           | (uint32_t(p[3]) << 24);
}

bool tag_is(const uint8_t* p, const char* tag) { return std::memcmp(p, tag, 4) == 0; }

/// Appends one pulse, clamped into range, and says whether the list is still
/// accepting. A zero-length pulse is rounded up rather than dropped: dropping
/// it would silently merge two edges into one and change the bit either side.
bool append_pulse(EdgeList& out, uint64_t t) {
    if (out.pulses.size() >= MAX_AUDIO_PULSES) {
        out.dropped++;
        return false;
    }
    if (t < 1) {
        t = 1;
    }
    if (t > 0xFFFFFFFFull) {
        t = 0xFFFFFFFFull;
    }
    out.pulses.push_back(uint32_t(t));
    return true;
}

std::string bad_rate(uint32_t rate) {
    return "a sample rate of " + std::to_string(rate) + "Hz cannot hold tape pulses";
}

} // namespace

// ---- EdgeDetector ----------------------------------------------------------

EdgeDetector::EdgeDetector(uint32_t sample_rate) : sample_rate_(sample_rate) {
    const float fs = float(sample_rate > 0 ? sample_rate : 1);
    peak_decay_ = std::exp(-1.0f / (fs * (PEAK_DECAY_MS / 1000.0f)));
}

uint64_t EdgeDetector::tstate_at(uint64_t sample_index) const {
    return sample_index * T_PER_SEC / (sample_rate_ > 0 ? sample_rate_ : 1);
}

void EdgeDetector::emit_edge() {
    if (!started_) {
        // The first transition only STARTS the clock. Whatever came before it
        // is a partial segment whose true length is unknowable -- the file
        // began part-way through it -- and inventing one would put a bogus
        // first pulse in front of every recording.
        started_ = true;
        last_edge_ = index_;
        return;
    }
    if (append_pulse(edges_, tstate_at(index_) - tstate_at(last_edge_))) {
        last_edge_ = index_;
    }
}

void EdgeDetector::prime(float lo, float hi) {
    peak_min_ = lo;
    peak_max_ = hi;
    primed_ = true;
}

void EdgeDetector::push(float x) {
    if (index_ == 0 && !primed_) {
        // Nothing was offered, so both rails start on the first sample -- zero
        // apart, hysteresis at its floor, and open only as the signal moves
        // them. See prime() for what that costs.
        peak_max_ = x;
        peak_min_ = x;
    } else {
        // Each rail falls back toward where the other one is, so a stretch at
        // a constant level closes the gap between them rather than leaving one
        // of them stranded out at an old peak.
        const float mid = (peak_max_ + peak_min_) * 0.5f;
        peak_max_ = mid + (peak_max_ - mid) * peak_decay_;
        peak_min_ = mid + (peak_min_ - mid) * peak_decay_;
    }
    if (x > peak_max_) {
        peak_max_ = x;
    }
    if (x < peak_min_) {
        peak_min_ = x;
    }

    const float centre = (peak_max_ + peak_min_) * 0.5f;
    float threshold = (peak_max_ - peak_min_) * 0.5f * TRIGGER_FRACTION;
    if (threshold < NOISE_FLOOR) {
        threshold = NOISE_FLOOR;
    }

    const float d = x - centre;
    if (!have_level_) {
        // The first crossing either way settles which side the recording
        // started on. It is NOT an edge: nothing changed, we merely found out
        // where we already were. Counting it as one would start the clock
        // here and hand the leading partial segment out as if it were a whole
        // pulse -- and its true length is unknowable, the file having begun
        // part-way through it.
        if (d > threshold || d < -threshold) {
            level_ = d > 0.0f;
            have_level_ = true;
        }
    } else if (!level_ && d > threshold) {
        level_ = true;
        emit_edge();
    } else if (level_ && d < -threshold) {
        level_ = false;
        emit_edge();
    }
    index_++;
}

void EdgeDetector::finish(EdgeList& out) {
    // The trailing segment is dropped for the same reason as the leading one:
    // the recording stops part-way through it.
    edges_.sample_rate = sample_rate_;
    out = std::move(edges_);
    edges_ = EdgeList();
}

// ---- .wav ------------------------------------------------------------------

bool looks_like_wav(const uint8_t* data, size_t len) {
    return len >= 12 && tag_is(data, "RIFF") && tag_is(data + 8, "WAVE");
}

namespace {

/// What a "fmt " chunk said.
struct WavFormat {
    uint32_t format = 0; // 1 = integer PCM, 3 = IEEE float
    uint32_t channels = 0;
    uint32_t sample_rate = 0;
    uint32_t bits = 0;
};

/// One frame's worth of channels, averaged, as a float in [-1, 1].
///
/// Averaging rather than taking channel 0: a stereo rip of a mono cassette is
/// the same signal twice and averaging cancels some of the hiss, while a rip
/// with the tape on one channel and silence on the other still triggers fine
/// at half amplitude, since every threshold here is relative.
float frame_to_float(const uint8_t* p, const WavFormat& fmt) {
    const uint32_t bytes = fmt.bits / 8;
    float sum = 0.0f;
    for (uint32_t c = 0; c < fmt.channels; c++) {
        const uint8_t* s = p + size_t(c) * bytes;
        float v = 0.0f;
        if (fmt.format == 3) {
            if (fmt.bits == 32) {
                float f = 0.0f;
                std::memcpy(&f, s, 4);
                v = f;
            } else {
                double f = 0.0;
                std::memcpy(&f, s, 8);
                v = float(f);
            }
        } else if (fmt.bits == 8) {
            // The one unsigned case in the format, for no reason anyone
            // remembers: 8-bit .wav is offset binary, everything wider is not.
            v = (float(s[0]) - 128.0f) / 128.0f;
        } else if (fmt.bits == 16) {
            v = float(int16_t(read_u16(s))) / 32768.0f;
        } else if (fmt.bits == 24) {
            int32_t raw = int32_t(read_u24(s));
            if ((raw & 0x800000) != 0) {
                raw -= 0x1000000;
            }
            v = float(raw) / 8388608.0f;
        } else {
            v = float(int32_t(read_u32(s))) / 2147483648.0f;
        }
        sum += v;
    }
    return sum / float(fmt.channels);
}

} // namespace

std::string decode_wav(const uint8_t* data, size_t len, EdgeList& out) {
    if (!looks_like_wav(data, len)) {
        return "not a RIFF/WAVE file";
    }

    WavFormat fmt;
    bool have_fmt = false;
    const uint8_t* samples = nullptr;
    size_t samples_len = 0;

    // A chunk walk, not a fixed offset: real .wav files carry LIST/INFO, fact,
    // and cue chunks in front of the data, and plenty of rippers put them
    // between "fmt " and "data".
    size_t at = 12;
    while (at + 8 <= len) {
        const uint32_t size = read_u32(data + at + 4);
        const size_t body = at + 8;
        if (size > len - body) {
            // A truncated final chunk. If it is the data, keep what is there:
            // a recording cut short still loads everything before the cut,
            // which is far more use than refusing it.
            if (tag_is(data + at, "data") && have_fmt) {
                samples = data + body;
                samples_len = len - body;
            }
            break;
        }
        if (tag_is(data + at, "fmt ") && size >= 16) {
            fmt.format = read_u16(data + body);
            fmt.channels = read_u16(data + body + 2);
            fmt.sample_rate = read_u32(data + body + 4);
            fmt.bits = read_u16(data + body + 14);
            // WAVE_FORMAT_EXTENSIBLE says nothing itself; the real format is
            // the first two bytes of the subformat GUID that follows.
            if (fmt.format == 0xFFFE && size >= 40) {
                fmt.format = read_u16(data + body + 24);
            }
            have_fmt = true;
        } else if (tag_is(data + at, "data")) {
            samples = data + body;
            samples_len = size;
        }
        at = body + size + (size & 1); // chunks are padded to even lengths
    }

    if (!have_fmt) {
        return ".wav has no format chunk";
    }
    if (fmt.format != 1 && fmt.format != 3) {
        return ".wav is compressed (format " + std::to_string(fmt.format)
               + "); only uncompressed PCM and float are understood";
    }
    if (fmt.channels == 0 || fmt.channels > 32) {
        return ".wav claims " + std::to_string(fmt.channels) + " channels";
    }
    if (fmt.format == 1 && fmt.bits != 8 && fmt.bits != 16 && fmt.bits != 24 && fmt.bits != 32) {
        return ".wav is " + std::to_string(fmt.bits) + "-bit PCM, which is not a size PCM has";
    }
    if (fmt.format == 3 && fmt.bits != 32 && fmt.bits != 64) {
        return ".wav claims " + std::to_string(fmt.bits) + "-bit float";
    }
    if (fmt.sample_rate < MIN_SAMPLE_RATE || fmt.sample_rate > MAX_SAMPLE_RATE) {
        return bad_rate(fmt.sample_rate);
    }
    if (samples == nullptr) {
        return ".wav has no data chunk";
    }

    const size_t frame = size_t(fmt.channels) * (fmt.bits / 8);
    const size_t frames = samples_len / frame;
    if (frames == 0) {
        return ".wav contains no samples";
    }

    // The range over the first PEAK_DECAY_MS, measured before triggering
    // rather than discovered during it -- which is possible here and only
    // here, the whole file already being in memory. Twenty milliseconds is
    // some thirty cycles of anything a tape carries, so it sees the real
    // rails. See EdgeDetector::prime for why that matters.
    size_t look = size_t(double(fmt.sample_rate) * (PEAK_DECAY_MS / 1000.0));
    if (look > frames) {
        look = frames;
    }
    float lo = 0.0f;
    float hi = 0.0f;
    for (size_t i = 0; i < look; i++) {
        const float v = frame_to_float(samples + i * frame, fmt);
        if (i == 0 || v < lo) {
            lo = v;
        }
        if (i == 0 || v > hi) {
            hi = v;
        }
    }

    EdgeDetector det(fmt.sample_rate);
    det.prime(lo, hi);
    for (size_t i = 0; i < frames; i++) {
        det.push(frame_to_float(samples + i * frame, fmt));
    }
    det.finish(out);
    if (out.pulses.empty()) {
        return ".wav has no signal in it: no level transitions were found";
    }
    return {};
}

// ---- .csw ------------------------------------------------------------------

namespace {

constexpr char CSW_SIGNATURE[] = "Compressed Square Wave";
constexpr size_t CSW_SIGNATURE_LEN = 22;

/// A .csw's uncompressed pulse stream is one byte per pulse, or five for a
/// long one, so this bounds the inflate output at the largest thing that could
/// still be within MAX_AUDIO_PULSES. Checked after the fact rather than during
/// -- tinfl's heap entry point has no ceiling of its own -- which is a
/// deliberate trade: the file is one the user chose to open, and the
/// alternative is reimplementing the streaming decompressor around a cap.
constexpr size_t MAX_CSW_UNPACKED = MAX_AUDIO_PULSES * 5;

} // namespace

bool looks_like_csw(const uint8_t* data, size_t len) {
    return len >= 0x20 && std::memcmp(data, CSW_SIGNATURE, CSW_SIGNATURE_LEN) == 0
           && data[0x16] == 0x1A;
}

std::string decode_csw_stream(const uint8_t* data, size_t len, uint32_t sample_rate,
                              uint8_t compression, EdgeList& out) {
    if (sample_rate < MIN_SAMPLE_RATE || sample_rate > MAX_SAMPLE_RATE) {
        return bad_rate(sample_rate);
    }
    if (compression != 1 && compression != 2) {
        return ".csw compression type " + std::to_string(compression) + " is not RLE or Z-RLE";
    }

    std::vector<uint8_t> unpacked;
    if (compression == 2) {
        size_t n = 0;
        void* raw = tinfl_decompress_mem_to_heap(data, len, &n, TINFL_FLAG_PARSE_ZLIB_HEADER);
        if (raw == nullptr) {
            return ".csw Z-RLE data could not be decompressed";
        }
        if (n > MAX_CSW_UNPACKED) {
            mz_free(raw);
            return ".csw expands to " + std::to_string(n) + " bytes of pulse data";
        }
        unpacked.assign(static_cast<uint8_t*>(raw), static_cast<uint8_t*>(raw) + n);
        mz_free(raw);
        data = unpacked.data();
        len = unpacked.size();
    }

    // Absolute sample position, differenced -- the same reason EdgeDetector
    // works that way. Rounding each pulse independently would be within a
    // T-state per pulse, but the positions would drift by the accumulated
    // error over the several hundred thousand pulses on one side of a tape.
    out.pulses.clear();
    out.sample_rate = sample_rate;
    out.dropped = 0;
    uint64_t at_sample = 0;
    uint64_t at_t = 0;
    size_t i = 0;
    while (i < len) {
        uint64_t run = data[i++];
        if (run == 0) {
            // A zero byte is the escape: the real length is the next four.
            if (i + 4 > len) {
                break; // a stream cut short mid-escape; keep what decoded
            }
            run = read_u32(data + i);
            i += 4;
        }
        at_sample += run;
        const uint64_t t = at_sample * T_PER_SEC / sample_rate;
        if (!append_pulse(out, t - at_t)) {
            break;
        }
        at_t = t;
    }

    if (out.pulses.empty()) {
        return ".csw contains no pulses";
    }
    return {};
}

std::string decode_csw(const uint8_t* data, size_t len, EdgeList& out) {
    if (!looks_like_csw(data, len)) {
        return "not a .csw file";
    }
    const uint8_t major = data[0x17];

    uint32_t sample_rate = 0;
    uint8_t compression = 0;
    size_t body = 0;
    if (major == 1) {
        sample_rate = read_u16(data + 0x19);
        compression = data[0x1B];
        body = 0x20;
        // v1 predates Z-RLE and has a 16-bit rate; both are why v2 exists.
        if (compression != 1) {
            return ".csw v1 compression type " + std::to_string(compression) + " is not RLE";
        }
    } else if (major == 2) {
        if (len < 0x34) {
            return "truncated .csw v2 header";
        }
        sample_rate = read_u32(data + 0x19);
        // 0x1D is the total pulse count and 0x22 the initial polarity. Neither
        // is read: the count is only a hint, and playback normalises polarity
        // anyway, since a loader times edges and never samples a level.
        compression = data[0x21];
        body = 0x34 + size_t(data[0x23]); // a header extension, if any
        if (body > len) {
            return "truncated .csw v2 header extension";
        }
    } else {
        return "unsupported .csw major version " + std::to_string(major);
    }

    return decode_csw_stream(data + body, len - body, sample_rate, compression, out);
}

// ---- .tzx 0x15, direct recording -------------------------------------------

std::string decode_direct_recording(const uint8_t* data, size_t len, uint32_t t_per_sample,
                                    uint8_t last_byte_bits, EdgeList& out) {
    if (t_per_sample == 0) {
        return "a direct recording sampled every 0 T-states";
    }
    if (len == 0) {
        return "an empty direct recording";
    }
    if (last_byte_bits < 1 || last_byte_bits > 8) {
        return "a direct recording claims " + std::to_string(last_byte_bits)
               + " used bits in its last byte";
    }

    out.pulses.clear();
    out.sample_rate = uint32_t(T_PER_SEC / t_per_sample);
    out.dropped = 0;

    // No trigger: the signal is already one bit wide, so a run of equal bits
    // IS a pulse and this is a run-length pass. Every run is emitted, the
    // first and last included -- unlike a .wav, a block states exactly where
    // it starts and stops, so neither end is a partial segment.
    const uint64_t total_bits = uint64_t(len - 1) * 8 + last_byte_bits;
    bool level = (data[0] & 0x80) != 0;
    uint64_t run = 0;
    for (uint64_t i = 0; i < total_bits; i++) {
        const bool bit = (data[i / 8] & (0x80u >> (i % 8))) != 0;
        if (bit != level) {
            if (!append_pulse(out, run * t_per_sample)) {
                break;
            }
            level = bit;
            run = 0;
        }
        run++;
    }
    if (run > 0) {
        append_pulse(out, run * t_per_sample);
    }

    if (out.pulses.empty()) {
        return "a direct recording with no signal in it";
    }
    return {};
}

} // namespace zx
