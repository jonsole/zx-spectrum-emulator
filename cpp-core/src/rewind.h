#pragma once
// Rewind: a history of the machine, for stepping backwards.
//
// Only built with ZX_REWIND (see CMakeLists.txt); docs/rewind-design.md has
// the design and the reasons for it.
//
// The emulator is deterministic -- from a given state and the same inputs it
// runs the same way, half-clock for half-clock -- so a history needs no record
// of individual instructions. It is two things:
//
//   checkpoints  the whole machine (Spectrum::State), taken every few video
//                frames while the program runs
//   an input log every change that reached the machine from outside it, each
//                stamped with the half-clock it was applied at
//
// Any earlier instant is reached by restoring the checkpoint before it and
// replaying: stepping the machine forward exactly as the run loop did,
// applying each logged input at its stamp. Going back an instruction, out of
// a routine or to the last write of an address is a SEARCH -- replay an
// interval noting every instruction boundary, newest interval first, until
// one matches -- followed by a LAND: restore and replay to exactly that
// boundary.
//
// Positions are global half-clocks (Spectrum::global_hc()).
//
// The history has a head: the newest instant recorded. While the machine is
// at the head it is LIVE, and runs record as they go. After going back it is
// in the past: running or stepping forward applies logged inputs rather than
// recording new ones, and on reaching the head it is live again. A new input
// while in the past BRANCHES -- everything after the present is discarded and
// recording carries on from here.
//
// Not thread-safe: the Engine owns one and uses it on the emulator thread.

#if ZX_REWIND

#include "registers.h"
#include "spectrum.h"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <string>
#include <vector>

namespace zx {

/// The kinds of input that reach the machine from outside it.
enum class RewindInputKind : uint8_t {
    Keys,         // the eight keyboard rows
    Registers,    // a debugger's register write (Spectrum::set_registers)
    Memory,       // a debugger's memory write (Spectrum::write_memory)
    TapePlay,
    TapeStop,
    TapeRewind,
    TapeSeek,     // `value` is the block
    TapeFastLoad, // `value` is 0 or 1
    // The machine clocked `value` half-clocks directly rather than through
    // step_instruction -- sub-instruction stepping, or a frame run on a
    // stopped machine. Replayed the same way, because the two differ: only
    // step_instruction tracks the call stack and springs the tape trap.
    RawClocks,
};

struct RewindInput {
    uint64_t hc = 0;
    RewindInputKind kind = RewindInputKind::Keys;
    uint8_t keys[8] = {};
    Registers regs{};
    uint16_t addr = 0;
    std::vector<uint8_t> bytes;
    uint64_t value = 0;
};

enum class RewindOp : uint8_t {
    StepBackInto,     // the previous instruction executed
    StepBackOver,     // the previous instruction in this routine
    StepBackOut,      // the CALL that entered this routine
    ReverseContinue,  // the previous breakpoint hit, or the start of the history
    RunBackToAddress, // the previous time execution reached an address
    RunBackToWrite,   // the instruction that last wrote an address
};

struct RewindSettings {
    /// A checkpoint every this many video frames.
    uint32_t checkpoint_frames = 10;
    /// The history keeps at least this much emulated time, when it can...
    uint32_t max_seconds = 60;
    /// ...within this many bytes of checkpoints.
    size_t max_bytes = size_t(256) * 1024 * 1024;
};

/// One instruction boundary a search saw, before that instruction ran.
struct RewindMark {
    uint64_t hc = 0;
    uint16_t pc = 0;
    uint32_t depth = 0;
    bool halted = false;
    /// The instruction starting here wrote the watched address.
    bool wrote = false;
};

class History {
public:
    struct Checkpoint {
        uint64_t hc = 0;
        /// The first input logged after this checkpoint was taken, as an
        /// absolute index into the log (see log_base_).
        uint64_t log_index = 0;
        Spectrum::State state;
        size_t bytes = 0;
    };

    struct Result {
        /// Whether the machine is somewhere other than where it started.
        bool moved = false;
        /// A search stopped by its cancel check; the machine is back where it
        /// started.
        bool cancelled = false;
    };

    explicit History(RewindSettings settings = RewindSettings());

    /// Starts a new history at the machine's present, dropping everything
    /// before it. For power-on, and after anything that replaces the machine
    /// rather than feeding it: a reset, loading a snapshot, ROM or tape.
    void start(Spectrum& m);

    bool live() const { return live_; }
    /// The newest instant recorded: the present while live.
    uint64_t head_hc(const Spectrum& m) const { return live_ ? m.global_hc() : head_hc_; }
    /// The oldest instant the history can reach.
    uint64_t oldest_hc() const { return checkpoints_.empty() ? 0 : checkpoints_.front().hc; }
    size_t checkpoint_count() const { return checkpoints_.size(); }
    size_t bytes() const { return bytes_; }
    const std::deque<Checkpoint>& checkpoints() const { return checkpoints_; }
    const RewindSettings& settings() const { return settings_; }

    // ---- recording ----------------------------------------------------------

    /// After each instruction a run or step executes. Live, takes a
    /// checkpoint at each checkpoint frame and trims the window; in the past,
    /// applies the inputs now due and notices reaching the head.
    void on_instruction(Spectrum& m) {
        if (!live_) {
            catch_up(m);
        } else if (m.ula.frame_count() != last_frame_) {
            on_frame(m);
        }
    }

    /// An input reaching the machine from outside: logs it at the present and
    /// applies it. Every input goes through here, so what a replay applies is
    /// exactly what the live machine had. In the past, branches first: the
    /// new input starts a new timeline.
    void record(Spectrum& m, RewindInput input);

    /// Makes the present the head, discarding every checkpoint and input
    /// after it.
    void branch(Spectrum& m);

    // ---- forward in the past ------------------------------------------------

    /// Replays to the head and becomes live.
    void return_to_live(Spectrum& m);

    // ---- going back ------------------------------------------------------------

    /// Performs `op` from the machine's present and lands on its target.
    /// `address` is for RunBackToAddress and RunBackToWrite. `cancelled` is
    /// polled between intervals of a long search. When nothing earlier matches,
    /// ReverseContinue lands at the start of the history and the others leave
    /// the machine where it was.
    Result go_back(Spectrum& m, RewindOp op, uint16_t address,
                   const std::function<bool()>& cancelled);

    // ---- replay ----------------------------------------------------------------

    /// Restores checkpoint `index` and replays to `target_hc`, applying logged
    /// inputs. `before_instruction`, if given, is called at each instruction
    /// the replay executes, before it runs. Nothing leaves the machine while it
    /// does: the profile and trace are detached and the beeper restarted
    /// after. Leaves the log cursor after the inputs it applied.
    void replay(Spectrum& m, size_t index, uint64_t target_hc,
                const std::function<void(Spectrum&)>& before_instruction);

private:
    void on_frame(Spectrum& m);
    void take_checkpoint(Spectrum& m);
    void trim(const Spectrum& m);
    void apply(Spectrum& m, const RewindInput& input);
    /// Applies inputs due at or before the present, and runs a raw-clock span
    /// that is due -- but not past `limit`. True if it clocked the machine.
    bool apply_due(Spectrum& m, uint64_t limit);
    void catch_up(Spectrum& m);
    /// Lands on `target_hc`: restores a checkpoint at least a frame before it
    /// (so the picture is redrawn) and replays to it.
    void land(Spectrum& m, uint64_t target_hc);
    /// The last checkpoint strictly before `hc`, or checkpoints_.size().
    size_t checkpoint_before(uint64_t hc) const;

    const RewindInput& log_at(uint64_t index) const { return log_[size_t(index - log_base_)]; }
    uint64_t log_end() const { return log_base_ + log_.size(); }

    RewindSettings settings_;
    std::deque<Checkpoint> checkpoints_;
    std::deque<RewindInput> log_;
    /// Absolute index of log_.front(): entries trimmed away still count, so a
    /// checkpoint's log_index stays valid.
    uint64_t log_base_ = 0;
    size_t bytes_ = 0;
    uint64_t last_frame_ = 0;

    bool live_ = true;
    /// The head while in the past.
    uint64_t head_hc_ = 0;
    /// The next input to apply while in the past, as an absolute log index.
    uint64_t cursor_ = 0;
    /// A search's per-boundary callback while it replays, so boundaries inside
    /// a raw-clock span are noted too. Null otherwise.
    const std::function<void(Spectrum&)>* noting_ = nullptr;
};

} // namespace zx

#endif // ZX_REWIND
