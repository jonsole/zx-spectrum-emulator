#pragma once
// Engine: owns the one live Spectrum48K and serialises access to it.
//
// The machine runs on its own thread. Everything that touches it goes through
// a command queue, so DAP and MCP clients can share one machine without
// locking it against each other.
//
// A `run` is itself a queued job, and it does not return until a breakpoint
// or a pause -- for a game, never. So the run loop cannot simply hold the
// thread and ignore everything else, and two mechanisms stop it doing so.
//
// The first is the queue itself: at each yield (RUN_YIELD_EVERY instructions)
// the run loop services pending commands, so inserting a tape or setting a
// breakpoint reaches a machine that is already running, and the run then
// carries straight on. The exception is anything that drives emulation ITSELF
// -- run, and the step family -- which is marked not-during-run, since
// servicing one from inside the run loop would nest a second emulation loop
// inside the first. Those still wait for the run to end.
//
// The second is that five things BYPASS the queue entirely, because they must
// work even between yields or before one is reached: `pause`, key presses,
// reading the screen, trace control, and the tape transport. Pause would
// otherwise deadlock waiting for the very thing it is meant to interrupt;
// keys would reach a running game a yield late at best; the screen viewer
// would freeze exactly when there is something to watch; a trace could only
// be started and stopped around a run rather than across one; and Play would
// never reach the game sitting at "Start tape, then press any key", which is
// the only moment Play is ever wanted. Those five use atomics and a mutexed
// snapshot instead.

#include "spectrum.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace zx {

/// A state snapshot, everything a debugger front end needs in one go.
struct MachineState {
    Registers registers;
    uint16_t pc = 0;
    /// Whether the CPU is sitting in a HALT waiting for its interrupt.
    /// Needed alongside pc because Registers::pc reads the same either way
    /// (halt_addr+1), so PC alone cannot tell "still waiting" from "resumed"
    /// -- which is what a correct step-over of a HALT turns on.
    bool halted = false;
    bool running = false;
    uint8_t border = 0;
    uint32_t tstate = 0;
    uint64_t frame_count = 0;
    /// Interrupts accepted since power-on.
    uint64_t interrupt_count = 0;
    std::vector<uint16_t> breakpoints;
    std::vector<uint16_t> call_stack;
};

/// What a trace capture is currently doing. Reported back to whoever asked for
/// it, since a capture can also stop itself on reaching its row limit.
struct TraceStatus {
    bool active = false;
    /// Open, but holding nothing but its header: a capture gated on
    /// `start_pc` records nothing until execution arrives there. Distinct from
    /// `!active` (finished or never started) and from `active` with no rows
    /// yet, which a poller would otherwise have to tell apart by guessing.
    bool waiting = false;
    std::string path;
    uint64_t rows = 0;
    uint64_t limit = 0;
    /// False when the Watch column is the reference's inert "??".
    bool watching = false;
    uint16_t watch = 0;
    /// False when the capture began recording straight away.
    bool has_start_pc = false;
    uint16_t start_pc = 0;
    /// The other way a capture can be gated: a T-state within the frame,
    /// rather than an address. Never set at the same time as has_start_pc.
    bool has_start_tstate = false;
    uint32_t start_tstate = 0;
    /// False when only the row limit or an explicit stop will end it.
    bool has_stop_pc = false;
    uint16_t stop_pc = 0;
    bool extra = false;
    /// The ULA's own bus columns, the trace's other opt-in column group.
    bool ula = false;
};

/// Why execution stopped. Maps onto DAP's `stopped` event reasons.
enum class StopReason { Step, Breakpoint, Pause, Entry, Error, Interrupt };

/// How fast a `run` is allowed to go.
///
/// `Realtime` is the default because it is what the hardware does: a 48K
/// executes 3.5 million T-states a second and no more, and a game's speed IS
/// its frame rate -- games sync to the 50Hz interrupt, so an unpaced emulator
/// running at 6x plays them at 6x. `Uncapped` is for the exercisers (ZEXALL,
/// ZEXDOC, z80full), where wall-clock speed is the whole point and there is
/// no visual output to get wrong.
enum class Speed { Realtime, Uncapped };

const char* stop_reason_name(StopReason r);

class Engine {
public:
    /// Reports samples currently buffered ahead of the speaker. See
    /// set_pacing_clock.
    using PacingClock = std::function<size_t()>;

    /// Called from the emulator thread whenever it stops or resumes. Handlers
    /// must not call back into the Engine's queue (they would deadlock).
    using StoppedHandler = std::function<void(StopReason, uint16_t pc)>;
    using ContinuedHandler = std::function<void()>;

    Engine();
    ~Engine();

    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    void on_stopped(StoppedHandler h);
    void on_continued(ContinuedHandler h);

    // ---- queued: these wait for the actor thread ---------------------------
    std::string load_rom(std::vector<uint8_t> data);
    std::string load_snapshot(std::vector<uint8_t> data);
    /// Inserts a .tap or .tzx image. With `auto_start`, also resets, types
    /// LOAD "" and starts the tape, so the caller's next `run` is already
    /// loading. Returns "" on success, else why it could not be loaded.
    ///
    /// Queued rather than immediate, unlike the transport controls below,
    /// because auto-start runs a couple of seconds of emulation of its own and
    /// so has to own the machine while it does.
    std::string load_tape(std::vector<uint8_t> data, std::string name, bool auto_start);
    /// Resets and types LOAD "" without needing a tape, leaving the machine in
    /// the ROM loader waiting for one -- the state a real Spectrum is in once
    /// you have typed the command but not yet pressed Play.
    ///
    /// What load_tape's auto_start does, minus the tape. Useful as a starting
    /// point: insert an image later with auto_start off and press Play, and it
    /// loads into a machine that was already listening, exactly as a cassette
    /// would.
    std::string wait_for_tape();
    Registers reset();
    Registers step(uint32_t instructions);
    /// Steps whole T-states rather than instructions (sub-instruction stepping).
    Registers step_tstates(uint32_t tstates);
    /// Runs past a HALT and everything its interrupt handler does, stopping
    /// only once execution genuinely reaches `target_pc` NOT halted.
    Registers step_over_halt(uint16_t target_pc);
    /// Runs until a breakpoint or pause. Returns when stopped.
    MachineState run();
    /// Whether a `run` currently owns the emulator thread.
    ///
    /// A run is a queued job that does not return until it stops, so the run
    /// loop services the rest of the queue itself at its yields (see Job).
    /// This tells a command whether it is being serviced that way, which
    /// matters mainly for whether it should announce a stop.
    bool running() const { return running_.load(); }
    void set_breakpoint(uint16_t addr);
    void clear_breakpoint(uint16_t addr);
    std::vector<uint8_t> read_memory(uint16_t addr, size_t length);
    void write_memory(uint16_t addr, std::vector<uint8_t> data);
    Registers registers();
    Registers set_registers(Registers r);
    MachineState state();

    // ---- queue-bypassing: safe to call while `run` is in flight ------------
    void pause() { pause_requested_.store(true); }
    /// Starts recording every half-clock to `options.path`, replacing any
    /// capture already in progress.  Returns "" or the error message.
    ///
    /// The file is opened here, on the CALLING thread, so a bad path comes
    /// back as an error immediately; the open capture is then handed to the
    /// emulator thread, which from that moment is the only one allowed to
    /// write to or close it. The handover lands at the run loop's next yield
    /// rather than going through the command queue, which is what lets a
    /// capture be started and stopped WHILE a game runs -- a queued request
    /// would sit behind the run and take effect only once it had stopped,
    /// which is no use at all to anyone recording a running game.
    std::string start_trace(TraceOptions options);
    /// Closes the capture and reports what it collected. Waits for the
    /// emulator thread to reach its next yield, not for a run to finish. The
    /// closed capture stays on record, so its path and row count can still be
    /// read back afterwards.
    TraceStatus stop_trace();
    /// Arms the capture to close itself when execution ARRIVES at `pc`,
    /// instead of closing it now. Returns immediately -- it neither waits for
    /// the emulator thread nor for the address to be reached, so the status it
    /// returns is of a capture still running.
    ///
    /// Unlike every other trace command this needs no handover at all: the
    /// address is an atomic on the capture itself (see TraceLog::set_stop_pc),
    /// which is what lets a stop be aimed at a capture the emulator thread is
    /// in the middle of writing. Ignored, rather than an error, when no
    /// capture is running -- the returned status says so.
    TraceStatus stop_trace(uint16_t pc);
    /// What the capture is doing right now, its row count included as that
    /// climbs -- read straight off the running capture, not sampled at some
    /// checkpoint, so a poller sees it fill up in real time. Never blocks on
    /// the CPU, the same contract as screen().
    TraceStatus trace_status() const;
    /// Total half-T-states emulated since power-on, updated as a run
    /// progresses. Everything in `state()` is queued and so cannot be read at
    /// all while a run owns the actor thread -- this is the one progress
    /// signal an outside observer can sample mid-run.
    uint64_t emulated_half_clocks() const { return emulated_hc_.load(); }
    /// Takes effect at the next yield, so it can be changed mid-run.
    void set_speed(Speed s) { speed_.store(s); }
    Speed speed() const { return speed_.load(); }
    /// Stops a run as soon as an interrupt is accepted, at the first
    /// instruction of the handler. Checked per instruction, so it can be
    /// armed or cleared mid-run.
    void set_break_on_interrupt(bool on) { break_on_interrupt_.store(on); }
    bool break_on_interrupt() const { return break_on_interrupt_.load(); }
    /// Tape transport. All of these take effect at the emulator thread's next
    /// yield rather than going through the queue -- see the note at the top of
    /// this file for why Play in particular has to.
    void tape_play();
    void tape_stop();
    void tape_rewind();
    void tape_eject();
    /// Positions the tape at block `index`, motor stopped. Clamped by the
    /// tape, so an index past the end is the end rather than an error.
    void tape_seek(size_t index);
    /// Whether standard-speed blocks are satisfied by trapping the ROM's
    /// LD-BYTES instead of being played as pulses. On by default.
    void set_tape_fast_load(bool on);
    /// Where the tape is right now, from a snapshot the emulator thread
    /// republishes as it goes -- so a position readout climbs during a run
    /// instead of freezing, the same contract as trace_status().
    TapeStatus tape_status() const;
    /// What is on the inserted tape, one entry per block. Cached rather than
    /// republished per yield the way the status is: the list is fixed the
    /// moment a tape is parsed, so the emulator thread only rebuilds it when
    /// the tape itself changes.
    std::vector<TapeBlockInfo> tape_blocks() const;
    void key_down(const std::string& key);
    void key_up(const std::string& key);
    /// Latest rendered frame (RGB, border included). Never blocks on the CPU.
    std::vector<uint8_t> screen();
    /// Registers a sink to receive beeper samples as they are generated, and
    /// hands back the ring it will be fed through. Callable from any thread.
    ///
    /// A registry rather than one shared drain-and-clear accessor (the shape
    /// `screen()` uses) because audio has three independent consumers -- the
    /// TCP stream, the optional native device, and MCP capture -- and a single
    /// consuming accessor would have them stealing samples from each other.
    std::shared_ptr<AudioRing> add_audio_sink(size_t capacity);
    /// Unregisters a sink. Safe to call while a run is in flight.
    void remove_audio_sink(const std::shared_ptr<AudioRing>& ring);
    /// Makes `ring` the pacing clock: a realtime run then advances only as
    /// fast as that sink is actually drained, instead of against
    /// steady_clock.
    ///
    /// This is what keeps picture and sound locked together. A sound card
    /// consumes samples at its own rate, which is never exactly the rate a
    /// wall-clock timer thinks a 48K runs at; pacing against the timer lets
    /// the two drift apart, which shows up as audio backlog that never
    /// drains (latency) or a device that runs dry (gaps). Pacing against the
    /// sink instead makes the emulator produce exactly what the hardware
    /// consumes, and since frames come off the same emulation loop, the
    /// picture follows the sound rather than the two being timed apart.
    ///
    /// `buffered` reports how many samples are queued ahead of the speaker
    /// (at the device, plus whatever has not reached it yet); the run
    /// settles at `target_samples` of that. It is called from the emulator
    /// thread and must not block or call back into the Engine.
    void set_pacing_clock(PacingClock buffered, size_t target_samples);
    void clear_pacing_clock();
    /// Sets the rate the beeper generates at. A playback device calls this
    /// with its engine's mix rate, so no resampling is needed anywhere.
    /// Call before starting a run.
    void set_audio_sample_rate(uint32_t rate);
    /// The rate currently being generated -- what the stream preamble
    /// announces and what get_audio reports.
    uint32_t audio_sample_rate() const { return audio_sample_rate_.load(); }

private:
    Spectrum48K machine_;
    std::thread thread_;

    /// A queued command, and whether the run loop may execute it at one of its
    /// yields rather than only between commands.
    ///
    /// Everything that merely reads or edits the machine can be serviced
    /// mid-run, and should be: that is what lets a tape be inserted, or a
    /// breakpoint set, on a game that is already running. What cannot is
    /// anything that drives emulation ITSELF -- run, and the step family --
    /// since servicing one of those from inside the run loop would nest a
    /// second emulation loop inside the first.
    struct Job {
        std::function<void(Spectrum48K&)> fn;
        bool during_run = true;
    };

    std::mutex queue_mutex_;
    std::condition_variable queue_cv_;
    std::deque<Job> queue_;
    bool shutting_down_ = false;

    std::atomic<bool> pause_requested_{false};
    std::atomic<bool> running_{false};
    std::atomic<uint64_t> emulated_hc_{0};
    std::atomic<Speed> speed_{Speed::Realtime};
    std::atomic<bool> break_on_interrupt_{false};

    /// Wall-clock instant, and the emulated half-clock count, that the current
    /// run's pacing measures from. Held as a baseline rather than sleeping a
    /// fixed amount per yield so that pacing self-corrects instead of drifting.
    std::chrono::steady_clock::time_point pace_origin_;
    uint64_t pace_origin_hc_ = 0;

    /// Live key state, owned outside the machine so a keypress reaches a
    /// running game rather than waiting for it to stop.
    std::mutex key_mutex_;
    Keyboard keys_;

    std::mutex screen_mutex_;
    std::vector<uint8_t> screen_snapshot_;
    /// Frame number currently in screen_snapshot_, so a re-publish of the same
    /// completed frame can be skipped. Touched only by the actor thread.
    uint64_t published_frame_ = ~uint64_t(0);

    std::mutex audio_mutex_;
    /// How much audio is buffered ahead of the speaker, or empty for
    /// wall-clock pacing.
    PacingClock pacing_clock_;
    size_t pacing_target_ = 0;
    std::atomic<uint32_t> audio_sample_rate_{AUDIO_SAMPLE_RATE};
    /// Consecutive waits that timed out. A device that has stopped draining
    /// must not be able to freeze the emulator, so after a few of these the
    /// sink is dropped and pacing falls back to the clock.
    int pacing_timeouts_ = 0;
    std::vector<std::shared_ptr<AudioRing>> audio_sinks_;
    /// Reused across publishes so the audio path does not allocate per block.
    std::vector<int16_t> audio_scratch_;

    /// The current capture, or null if tracing has never been started. Owned
    /// here rather than by the machine because it holds a file handle that has
    /// to outlive any individual run or step command. Kept after it is closed
    /// so trace_status() can still report where it went. Emulator thread only.
    std::unique_ptr<TraceLog> trace_;

    /// The handover start_trace/stop_trace use. `pending_trace_` is a capture
    /// waiting to be installed, or null for a stop; `trace_requested_` counts
    /// requests made and `trace_applied_` those the emulator thread has taken
    /// up, so a caller can wait for its own and no other. The mutex also
    /// covers trace_status() reading `trace_`, which is the only thing keeping
    /// a capture alive underneath a reader on another thread.
    mutable std::mutex trace_mutex_;
    std::condition_variable trace_cv_;
    std::atomic<bool> trace_change_pending_{false};
    std::unique_ptr<TraceLog> pending_trace_;
    uint64_t trace_requested_ = 0;
    uint64_t trace_applied_ = 0;

    /// The tape transport handover, the same shape as the trace one above but
    /// simpler: there is nothing to hand over but an enum, and no caller needs
    /// to wait for it to land. `live_tape_status_` is the snapshot
    /// tape_status() reads.
    enum class TapeCommand { None, Play, Stop, Rewind, Eject, Seek };
    mutable std::mutex tape_mutex_;
    std::condition_variable tape_cv_;
    std::atomic<bool> tape_change_pending_{false};
    TapeCommand pending_tape_ = TapeCommand::None;
    /// The block Seek is for. Only meaningful alongside TapeCommand::Seek, and
    /// carried here rather than in the enum for the reason the comment above
    /// gives: an enum plus one field is still simpler than a command object.
    size_t pending_tape_block_ = 0;
    std::atomic<bool> tape_fast_load_{true};
    /// Requests made and requests the emulator thread has taken up, so a
    /// caller can wait for its own and no other -- the same counter pair the
    /// trace handover uses.
    uint64_t tape_requested_ = 0;
    uint64_t tape_applied_ = 0;
    TapeStatus live_tape_status_;
    /// The block list and the tape generation it was taken from. Compared
    /// against the tape's own generation at each yield, so the copy happens
    /// once per inserted tape rather than ~1700 times a second.
    std::vector<TapeBlockInfo> live_tape_blocks_;
    uint64_t live_tape_generation_ = 0;

    StoppedHandler on_stopped_;
    ContinuedHandler on_continued_;

    void actor_loop();
    /// Runs `fn` on the actor thread and waits for it. `during_run` says
    /// whether the run loop may pick it up at a yield -- see Job.
    template <typename R>
    R submit(std::function<R(Spectrum48K&)> fn, bool during_run = true);
    void submit_void(std::function<void(Spectrum48K&)> fn, bool during_run = true);
    /// Queues `fn` without waiting for it -- used only to wake an idle actor
    /// thread, since a request that bypasses the queue still needs SOMETHING
    /// to reach a servicing point.
    void post(std::function<void(Spectrum48K&)> fn);

    void publish_screen();
    /// Moves the beeper output into every registered sink, and keeps the
    /// beeper switched off while nothing is listening. Actor thread only.
    void publish_audio();
    void publish_progress();
    /// Restarts the pacing baseline at the current instant.
    void pace_reset();
    /// Sleeps until wall-clock time has caught up with emulated time. No-op
    /// when uncapped, or when the emulator is already behind.
    void pace_wait();
    void sync_keys();
    MachineState snapshot(bool running) const;
    TraceStatus trace_snapshot() const;
    /// Hands `log` (null to stop) to the emulator thread and waits for it to
    /// be taken up.
    void request_trace(std::unique_ptr<TraceLog> log);
    /// Installs or closes a pending capture and republishes the status
    /// snapshot. Emulator thread only: called between commands and at every
    /// run/step yield, which is what bounds how late a request lands.
    void service_trace();
    /// Applies a pending transport command, pushes the fast-load setting into
    /// the machine, walks the tape cursor up to the current instant and
    /// republishes the status snapshot. Emulator thread only: called between
    /// commands and at every run/step yield, which is what bounds how late a
    /// Play can land (a yield is ~2ms of emulated time).
    void service_tape();
    /// Runs any queued commands that are safe to service mid-run, oldest
    /// first. Called from the run and step loops at their yields, which is
    /// what stops a queued command from waiting behind a run that may never
    /// finish. Emulator thread only.
    void service_queue();
    /// Queues `what` for the emulator thread, wakes it, and waits for it to be
    /// taken up.
    ///
    /// It waits for the same reason stop_trace does: the caller reads the
    /// status straight afterwards, and a transport command that returned
    /// before it had been applied would answer "did it stop?" with the state
    /// from before the stop. The wait is bounded by the next run yield -- a
    /// couple of milliseconds -- not by the run finishing, which is what keeps
    /// this useful mid-run.
    void request_tape(TapeCommand what, size_t block = 0);
};

} // namespace zx
