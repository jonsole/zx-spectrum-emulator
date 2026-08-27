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
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
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
    std::vector<uint16_t> breakpoints;
    std::vector<uint16_t> call_stack;
};

/// Why execution stopped. Maps onto DAP's `stopped` event reasons.
enum class StopReason { Step, Breakpoint, Pause, Entry, Error };

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

    // ---- queue-bypassing: safe to call while `run` is in flight ------------
    void pause() { pause_requested_.store(true); }
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

    /// Live key state, owned outside the machine so a keypress reaches a
    /// running game rather than waiting for it to stop.
    std::mutex key_mutex_;
    Keyboard keys_;

    std::mutex screen_mutex_;
    std::vector<uint8_t> screen_snapshot_;

    StoppedHandler on_stopped_;
    ContinuedHandler on_continued_;

    void actor_loop();
    /// Runs `fn` on the actor thread and waits for it.
    template <typename R>
    R submit(std::function<R(Spectrum48K&)> fn);
    void submit_void(std::function<void(Spectrum48K&)> fn);

    void publish_screen();
    void sync_keys();
    MachineState snapshot(bool running) const;
};

} // namespace zx
