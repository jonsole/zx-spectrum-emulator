#pragma once
// Engine: owns the one live Spectrum48K and serialises access to it.
//
// The machine runs on its own thread. Everything that touches it goes through
// a command queue, so DAP and MCP clients can share one machine without
// locking it against each other.
//
// Three things deliberately BYPASS that queue, and it matters why: `pause`,
// key presses, and reading the screen. A `run` command monopolises the actor
// thread until it stops, so anything routed through the queue would sit behind
// it -- pause would deadlock waiting for the very thing it is meant to
// interrupt, keys would not reach a running game, and the screen viewer would
// freeze exactly when there is something to watch. Those three use atomics and
// a mutexed snapshot instead.

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
    std::string path;
    uint64_t rows = 0;
    uint64_t limit = 0;
    /// False when the Watch column is the reference's inert "??".
    bool watching = false;
    uint16_t watch = 0;
    bool extra = false;
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
    Registers reset();
    Registers step(uint32_t instructions);
    /// Steps whole T-states rather than instructions (sub-instruction stepping).
    Registers step_tstates(uint32_t tstates);
    /// Runs past a HALT and everything its interrupt handler does, stopping
    /// only once execution genuinely reaches `target_pc` NOT halted.
    Registers step_over_halt(uint16_t target_pc);
    /// Runs until a breakpoint or pause. Returns when stopped.
    MachineState run();
    void set_breakpoint(uint16_t addr);
    void clear_breakpoint(uint16_t addr);
    std::vector<uint8_t> read_memory(uint16_t addr, size_t length);
    void write_memory(uint16_t addr, std::vector<uint8_t> data);
    Registers registers();
    Registers set_registers(Registers r);
    MachineState state();
    /// Starts recording every half-clock to `options.path`. Replaces any
    /// capture already in progress. Returns "" or the error message.
    std::string start_trace(TraceOptions options);
    /// Closes the capture and reports what it collected.
    ///
    /// Queued like everything else here, which means it waits for an in-flight
    /// `run` to finish. That is the right trade: a capture stops itself at its
    /// row limit anyway, and anyone wanting to end one early can `pause`
    /// (which bypasses the queue) and then stop it.
    TraceStatus stop_trace();
    TraceStatus trace_status();

    // ---- queue-bypassing: safe to call while `run` is in flight ------------
    void pause() { pause_requested_.store(true); }
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
    void key_down(const std::string& key);
    void key_up(const std::string& key);
    /// Latest rendered frame (RGB, border included). Never blocks on the CPU.
    std::vector<uint8_t> screen();

private:
    Spectrum48K machine_;
    std::thread thread_;

    std::mutex queue_mutex_;
    std::condition_variable queue_cv_;
    std::deque<std::function<void(Spectrum48K&)>> queue_;
    bool shutting_down_ = false;

    std::atomic<bool> pause_requested_{false};
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

    /// The live capture, or null if tracing has never been started. Owned here
    /// rather than by the machine because it holds a file handle that has to
    /// outlive any individual run or step command.
    std::unique_ptr<TraceLog> trace_;

    StoppedHandler on_stopped_;
    ContinuedHandler on_continued_;

    void actor_loop();
    /// Runs `fn` on the actor thread and waits for it.
    template <typename R>
    R submit(std::function<R(Spectrum48K&)> fn);
    void submit_void(std::function<void(Spectrum48K&)> fn);

    void publish_screen();
    void publish_progress();
    /// Restarts the pacing baseline at the current instant.
    void pace_reset();
    /// Sleeps until wall-clock time has caught up with emulated time. No-op
    /// when uncapped, or when the emulator is already behind.
    void pace_wait();
    void sync_keys();
    MachineState snapshot(bool running) const;
    TraceStatus trace_snapshot() const;
};

} // namespace zx
