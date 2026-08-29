#pragma once
// Recorded audio turned back into tape pulses.
//
// tape.cpp deals in formats that already say what the signal IS -- .tap's
// implied ROM timings, .tzx's explicit ones. This file deals in formats that
// only say what the signal SOUNDED LIKE: a .wav ripped off a real cassette, a
// .csw pulse capture, or the two .tzx blocks (0x15 direct recording, 0x18 CSW)
// that carry the same thing inline.
//
// Everything here reduces to ONE output, an EdgeList: the instants the level
// flipped, as gaps in T-states. That is all a loader can see -- LD-EDGE counts
// time between transitions and never looks at a level in isolation -- so once
// a recording is an edge list it is indistinguishable from a parsed .tzx, and
// tape.cpp's existing pulse playback replays it with no idea it came from
// audio. The alternative, teaching the playback state machine about samples,
// would put a resampler in the path of every tape.
//
// THE HARD PART IS THE TRIGGER, not the file parsing. A .csw is already an
// edge list. A .wav is a noisy analogue waveform with DC offset, azimuth
// droop, and 40 years of tape hiss on it, and turning that into edges without
// inventing or dropping any is what decides whether a rip loads. See
// EdgeDetector for what it does about that.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace zx {

/// A recorded waveform reduced to the only thing a loader can see: the gaps
/// between level transitions, in T-states.
///
/// Deliberately NOT a TapeBlock: nothing here knows about pilot tones, sync
/// pulses or headers, and a recording has no structure beyond its edges.
/// Cutting the list into blocks is tape.cpp's job.
struct EdgeList {
    std::vector<uint32_t> pulses;
    /// The recording's sample rate, kept only so a caller can say so in an
    /// error or a description. Playback is in T-states and never wants it.
    uint32_t sample_rate = 0;
    /// Edges the detector found but had to drop against MAX_AUDIO_PULSES.
    /// Non-zero means the answer is truncated, not merely long.
    uint64_t dropped = 0;
};

/// A ceiling on edges taken from one recording, and the reason there is one:
/// a Schmitt trigger can in principle fire on every sample, so a file that is
/// hiss rather than tape would otherwise turn 40MB of .wav into a pulse list
/// bounded only by the sample count. Four million is far past any real tape --
/// a 48K game is roughly 800,000 -- and costs 16MB if it is ever reached.
constexpr size_t MAX_AUDIO_PULSES = 4'000'000;

/// True if `data` opens with a RIFF/WAVE or CSW signature. Content, not file
/// name -- the same rule Tape::insert already applies to .tap and .tzx.
bool looks_like_wav(const uint8_t* data, size_t len);
bool looks_like_csw(const uint8_t* data, size_t len);

/// Decodes a RIFF/WAVE file and triggers it into edges. Handles PCM 8-bit
/// unsigned, 16/24/32-bit signed and 32/64-bit float, at any sample rate, with
/// any channel count (channels are averaged -- a stereo rip of a mono cassette
/// is the same signal twice, and averaging is the cheapest way to say so).
/// Returns "" on success, else why it could not be read.
std::string decode_wav(const uint8_t* data, size_t len, EdgeList& out);

/// Decodes a .csw file, v1 (RLE) or v2 (RLE or Z-RLE). No trigger involved:
/// the format IS an edge list, and all this does is rescale sample counts into
/// T-states.
std::string decode_csw(const uint8_t* data, size_t len, EdgeList& out);

/// The body of a .tzx 0x18 block, which is a headerless .csw stream: the same
/// RLE/Z-RLE data with the rate and compression given by the enclosing block.
std::string decode_csw_stream(const uint8_t* data, size_t len, uint32_t sample_rate,
                              uint8_t compression, EdgeList& out);

/// The body of a .tzx 0x15 block: one bit per sample, MSB first, at a fixed
/// `t_per_sample`. A run of equal bits is one pulse, so this is a run-length
/// pass rather than a trigger -- the signal is already square.
std::string decode_direct_recording(const uint8_t* data, size_t len, uint32_t t_per_sample,
                                    uint8_t last_byte_bits, EdgeList& out);

/// Turns samples into edges, one sample at a time.
///
/// A fixed threshold at zero does not work on real recordings. They arrive
/// with a DC offset that is rarely zero and drifts, at a level that varies
/// between rips by 30dB, and with hiss that a bare comparator turns into
/// thousands of spurious edges per second. So this is a Schmitt trigger whose
/// centre and hysteresis are both derived from the signal, by tracking its two
/// RAILS: a decaying maximum and a decaying minimum. The midpoint between them
/// is the comparison point, and a quarter of the distance between them is the
/// hysteresis.
///
/// Rails rather than the more obvious pairing of a low-pass follower for the
/// centre and a peak envelope for the hysteresis. That arrangement has a flaw
/// that took a round-trip test to see: after any long stretch at a constant
/// level -- the silence between two blocks, or simply the start of the file --
/// a low-pass follower has settled ONTO that level rather than onto the
/// midpoint of the signal either side of it. The first swing out of the
/// silence is then measured from a rail instead of from the centre, so it
/// reads as twice the real amplitude, and since the hysteresis is a fraction
/// of the peak that one bogus reading doubles the threshold and holds it there
/// while the envelope decays. The next two or three genuine edges fall under
/// it and are lost. Inside a pilot tone that is invisible -- every pulse is
/// the same length as the one before it -- right up until the tone ends and
/// the block turns out to be two edges out of step.
///
/// Rails have no such transient. Through a constant stretch both converge on
/// that level, so the gap between them closes, the hysteresis drops to
/// NOISE_FLOOR, and the first sample of the returning signal is already past
/// it. They re-open to the true amplitude within one pulse.
///
/// NOISE_FLOOR is the floor under the hysteresis, and it is what makes silence
/// read as silence rather than as hiss -- which in turn is what lets tape.cpp
/// find the gaps between blocks at all.
///
/// Streaming, one sample per push(), rather than taking a buffer: a 4-minute
/// stereo 44.1kHz .wav is 42MB of float if materialised, for a result that is
/// a few megabytes at worst.
class EdgeDetector {
public:
    explicit EdgeDetector(uint32_t sample_rate);

    /// Opens the rails at `lo` and `hi` before the first push(), for a caller
    /// that can see the recording's range in advance.
    ///
    /// Worth doing wherever it is possible. Started from a single sample the
    /// rails are zero apart, so the hysteresis sits at NOISE_FLOOR for the
    /// first millisecond or so -- and on a quiet rip that is under the hiss,
    /// which chatters out a handful of edges that are not in the recording
    /// before the rails open far enough to reject it. Handing them the range
    /// up front skips the warm-up entirely.
    void prime(float lo, float hi);

    /// One sample, nominally in [-1, 1]; out-of-range values are harmless
    /// since every threshold here is relative.
    void push(float x);

    /// Finishes the recording and moves the edges into `out`.
    void finish(EdgeList& out);

private:
    uint32_t sample_rate_ = 0;
    uint64_t index_ = 0;     // samples seen
    uint64_t last_edge_ = 0; // sample index of the last transition
    bool started_ = false;   // has any edge been emitted yet
    /// Whether `level_` means anything yet. Until the signal has crossed the
    /// threshold once there is no way to know which side of it the recording
    /// began on, and ASSUMING one costs the first pulse whenever the guess is
    /// wrong: the opening transition then fails the test for the level it is
    /// already at, and goes unrecorded. So the first crossing in EITHER
    /// direction fixes the level -- without counting as an edge, since nothing
    /// changed at it.
    bool have_level_ = false;
    bool primed_ = false; // has prime() opened the rails
    bool level_ = false;
    float peak_max_ = 0.0f;
    float peak_min_ = 0.0f;
    float peak_decay_ = 0.0f;
    EdgeList edges_;

    /// Sample index -> absolute T-state, in 64-bit so a long recording cannot
    /// drift. Differencing two of these is what gives a pulse length; summing
    /// rounded per-pulse lengths instead would accumulate error over the
    /// hundreds of thousands of pulses in one side of a cassette.
    uint64_t tstate_at(uint64_t sample_index) const;
    void emit_edge();
};

} // namespace zx
