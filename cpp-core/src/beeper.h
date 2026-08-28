#pragma once
// The 48K beeper: port 0xFE bits 4 (speaker) and 3 (MIC) turned into PCM.
//
// The speaker level changes only when a program writes port 0xFE -- a few
// thousand times a second at most. Reconstructing that by sampling the level
// seven million times a second would be three orders of magnitude of wasted
// work in the emulator's hottest loop, so nothing here is clocked at all:
// `write_port_fe` records each change against the half-clock it happened on,
// and `advance_to` integrates the piecewise-constant level forward whenever
// somebody asks for the audio. The cost lands per SAMPLE (44100/s) instead of
// per half-clock (7,000,000/s), and `Spectrum48K::clock()` is untouched.
//
// Decimation is a BOX FILTER, not a point sample. A beeper tone's edges land
// on arbitrary T-states, so picking one level every ~159 half-clocks would
// alias that jitter straight into the audible band and sound gritty.
// Averaging the level across each sample period is both cheap here (the level
// is constant between edges, so it is a multiply) and the right filter.
//
// The sample clock itself is an exact integer accumulator rather than a
// division or a float phase: 44100 added per half-clock, emitting whenever it
// crosses 7000000. That fires every 158 or 159 half-clocks and, crucially,
// never drifts -- over an hour it is still sample-exact, which a repeated
// `hc * 44100.0 / 7000000.0` would not be.

#include <cstdint>
#include <mutex>
#include <vector>

namespace zx {

/// Mono, and the rate used unless a playback device asks for another one.
///
/// It is not fixed, because WASAPI shared mode will only run at the audio
/// engine's own mix rate -- and matching that exactly is far better than
/// resampling onto it, since the decimator below can be told to produce any
/// rate at no cost or loss. Everything downstream learns the real rate from
/// the stream preamble or from Engine::audio_sample_rate().
constexpr uint32_t AUDIO_SAMPLE_RATE = 44100;

/// A real 48K issues 7,000,000 half-T-states per second (3.5MHz, 2 halves).
constexpr uint64_t HC_PER_SEC = 7'000'000;

/// Relative weights of the two output bits. The speaker (bit 4) does nearly
/// all the work; MIC (bit 3) contributes the small step that gives a real 48K
/// its four distinguishable output levels -- which the multi-level beeper
/// engines and every tape-save tone depend on.
constexpr int32_t SPEAKER_LEVEL = 100;
constexpr int32_t MIC_LEVEL = 10;
constexpr int32_t FULL_LEVEL = SPEAKER_LEVEL + MIC_LEVEL;

/// Weight of the EAR input (port 0xFE bit 6) in the mix.
///
/// The ULA feeds the EAR socket into the same audio output as the speaker, so
/// a tape is audible as it loads. That is the ONLY reason loading makes a
/// noise, and it is worth being precise about because the obvious guess is
/// wrong: the ROM's loader never touches the speaker bit at all. LD_SAMPLE
/// ends `AND $07 / OR $08 / OUT ($FE),A` -- border bits plus a MIC bit that
/// never changes -- so the stripes are the CPU's doing and the screech is
/// not. Without this term a tape loads in complete silence.
///
/// Deliberately well under SPEAKER_LEVEL: on real hardware the tape is
/// background noise behind a game's beeper, not louder than it. Left out of
/// FULL_LEVEL so that adding it cannot quieten every existing sound by
/// changing what full scale means; the sum is clamped in emit() instead.
constexpr int32_t EAR_LEVEL = 25;

/// Peak amplitude of a full-scale square wave. Well below INT16_MAX on
/// purpose: the beeper is a harsh sound and this is somebody's headphones.
constexpr int32_t AUDIO_PEAK = 9000;

/// One-pole DC blocker coefficient (~35Hz corner at 44.1kHz). Without it a
/// machine idling with the speaker bit high is a constant full-scale DC
/// offset: inaudible in itself, but it eats headroom and puts a click on the
/// first toggle after it.
constexpr float DC_BLOCK_R = 0.995f;

/// How much generated-but-undrained audio the beeper will hold before it
/// starts dropping the oldest. Only reached when nothing is consuming.
constexpr size_t BEEPER_MAX_PENDING = AUDIO_SAMPLE_RATE / 2; // ~0.5s

class Beeper {
public:
    /// Whether to generate anything at all. Off until a consumer attaches, so
    /// that a run with nothing listening (ZEXALL and friends) does no work.
    bool enabled() const { return enabled_; }

    /// Turns generation on or off. `now_hc` is the machine's global half-clock
    /// count, which becomes the new integration origin -- so switching on does
    /// not suddenly emit however many hours of silence went by while it was
    /// off, and switching off does not leave a stale origin behind.
    void set_enabled(bool on, uint64_t now_hc);

    /// Output rate. Changing it resets the sample clock, so do it before a
    /// run rather than part-way through one.
    void set_sample_rate(uint32_t rate);
    uint32_t sample_rate() const { return rate_; }

    /// Latches a port 0xFE write at half-clock `now_hc`: bit 4 is the speaker,
    /// bit 3 the MIC.
    ///
    /// A LATCH, deliberately, not an edge count. Control lines are not
    /// auto-cleared, so `service_bus()` sees a single OUT assert IORQ/WR on
    /// five consecutive half-clocks and calls this five times over. All five
    /// carry the same `now_hc` and the same value, so integrating up to that
    /// instant and then assigning a level is exactly idempotent -- whereas
    /// anything that counted edges would count five.
    void write_port_fe(uint8_t value, uint64_t now_hc);

    /// Latches the EAR input level at half-clock `now_hc`.
    ///
    /// A latch on exactly the same terms as write_port_fe, and for the same
    /// reason: it is driven from the READ branch of Spectrum48K::service_bus,
    /// where one IN asserts IORQ/RD on five consecutive half-clocks and calls
    /// this five times with the same instant and the same value.
    ///
    /// Only moves while something is actually reading the port. That is not
    /// quite the hardware -- a real deck is audible whether or not the CPU is
    /// listening -- but a loader polls port 0xFE every few dozen T-states,
    /// which is orders of magnitude finer than the tone being reproduced, so
    /// the load itself sounds right. Sampling it on any coarser schedule (a
    /// run-loop yield, say) would alias the pilot tone into something that
    /// never came off a tape.
    void set_ear(bool high, uint64_t now_hc);

    /// Integrates the level forward to `now_hc`, producing samples. Cheap to
    /// call often and a no-op if no time has passed.
    void advance_to(uint64_t now_hc);

    /// Moves everything generated so far into `out` (appending).
    void drain(std::vector<int16_t>& out);
    /// Throws away everything generated so far.
    void discard() { pending_.clear(); }
    /// Clears the filter and the pending samples. Leaves the latched level
    /// alone, matching `Ula::reset()` leaving `border` alone.
    void reset();

private:
    bool enabled_ = false;
    uint32_t rate_ = AUDIO_SAMPLE_RATE;
    /// Latched output level, 0..FULL_LEVEL. Resolved on write, not per sample.
    int32_t level_ = 0;
    /// EAR's contribution, kept apart from level_ so the two latch
    /// independently -- they are driven by different bus cycles.
    int32_t ear_level_ = 0;
    /// What the integrator actually sums: everything driving the speaker.
    int32_t mixed_level() const { return level_ + ear_level_; }
    /// Half-clock the integration has reached.
    uint64_t last_hc_ = 0;

    // Box-filter accumulator over the sample period in progress.
    int32_t sum_ = 0;
    uint32_t count_ = 0;
    // Sample clock: += AUDIO_SAMPLE_RATE per half-clock, crossing HC_PER_SEC.
    uint32_t acc_ = 0;
    // DC blocker state.
    float dc_in_ = 0.0f;
    float dc_out_ = 0.0f;

    std::vector<int16_t> pending_;

    void emit();
};

/// A bounded single-producer/single-consumer sample queue, one per audio
/// consumer.
///
/// There are three consumers (the TCP stream, the optional native device, and
/// MCP's capture window) and they must not steal from each other, so the
/// Engine fans out into one of these per sink rather than exposing a single
/// drain-and-clear accessor the way `Engine::screen()` does.
///
/// Overrun drops the OLDEST samples. For live playback the freshest audio is
/// the only audio worth having, and a consumer that has stopped draining is
/// already not listening.
class AudioRing {
public:
    explicit AudioRing(size_t capacity) : buf_(capacity, 0) {}

    void write(const int16_t* data, size_t n);
    /// Oldest-first, consuming. What the playback sinks use.
    size_t read(int16_t* out, size_t max);
    /// The most recent `max` samples, in order, WITHOUT consuming -- so an
    /// MCP capture can look at the audio without starving playback.
    void peek_latest(std::vector<int16_t>& out, size_t max);
    size_t available();

private:
    std::mutex mutex_;
    std::vector<int16_t> buf_;
    size_t head_ = 0; // index of the oldest valid sample
    size_t size_ = 0; // valid samples held
};

/// Rough pitch of a captured window, by counting sign changes with hysteresis.
/// Zero if there is nothing periodic to measure.
///
/// Deliberately crude: it exists so a test (and an agent through MCP) can tell
/// a 440Hz BEEP from a 261Hz one without a human listening, not to analyse
/// timbre. The hysteresis band matters because the DC blocker makes a held
/// level droop back towards zero, which a bare sign test would count as extra
/// crossings on low notes.
float estimate_frequency_hz(const std::vector<int16_t>& samples);

/// RMS and absolute peak of a window, both normalised to 0..1.
void measure_level(const std::vector<int16_t>& samples, float& rms, float& peak);

/// Wraps mono 16-bit samples in a RIFF/WAVE container.
///
/// Lives here rather than beside the stream server (the way `encode_png` sits
/// in screen_stream.cpp) because a WAV header is 44 bytes of arithmetic with
/// no dependency to speak of, and both the server and the core-only `beep`
/// diagnostic want it. Duplicating it would be sillier than the asymmetry.
std::vector<uint8_t> encode_wav(const std::vector<int16_t>& samples,
                                uint32_t sample_rate = AUDIO_SAMPLE_RATE);

} // namespace zx
