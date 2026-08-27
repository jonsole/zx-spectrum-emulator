#include "engine.h"

#include "snapshot.h"
#include "ula.h"

#ifdef _WIN32
// Pacing sleeps for a few milliseconds at a time. Windows' default timer
// granularity is ~15.6ms, which would overshoot every one of them and pace the
// emulator to roughly 30% of real speed; timeBeginPeriod(1) is the documented
// way to ask for 1ms, and is what every emulator on this platform does.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <timeapi.h>
#pragma comment(lib, "winmm.lib")
#endif

namespace zx {
namespace {

/// How many instructions `run` executes between checks for a pause request,
/// keyboard updates and a screen refresh. Small enough that the UI feels
/// live, large enough that the checks cost nothing. It is also how often
/// pacing gets to sleep, which works out at roughly twice per emulated frame
/// -- fine enough that the picture does not visibly lurch.
constexpr uint64_t RUN_YIELD_EVERY = 2000;

/// A real 48K issues 7,000,000 half-T-states per second (3.5MHz, 2 halves).
constexpr double REALTIME_HC_PER_SEC = 7'000'000.0;

/// How far behind real time the emulator may fall before pacing gives up on
/// catching up and simply restarts its baseline. Without this, any stall (a
/// breakpoint, the host being busy, a laptop resuming from sleep) would leave
/// a debt that pacing pays back by running flat out -- the emulator would
/// visibly sprint to "catch up", which is worse than quietly losing the time.
constexpr auto MAX_PACING_DEBT = std::chrono::milliseconds(250);

} // namespace

const char* stop_reason_name(StopReason r) {
    switch (r) {
        case StopReason::Step: return "step";
        case StopReason::Breakpoint: return "breakpoint";
        case StopReason::Pause: return "pause";
        case StopReason::Entry: return "entry";
        // DAP vocabulary, which is what these names are for: an
        // interrupt stop is surfaced through the exception-breakpoint
        // filter, and "exception" is the reason that pairs with it.
        // Nothing here treats an interrupt as an error.
        case StopReason::Interrupt: return "exception";
        default: return "error";
    }
}

Engine::Engine() {
#ifdef _WIN32
    timeBeginPeriod(1); // see the note on the include above
#endif
    publish_screen();
    thread_ = std::thread([this] { actor_loop(); });
}

Engine::~Engine() {
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        shutting_down_ = true;
    }
    pause_requested_.store(true); // break any in-flight run
    queue_cv_.notify_all();
    if (thread_.joinable()) {
        thread_.join();
    }
#ifdef _WIN32
    timeEndPeriod(1);
#endif
}

void Engine::on_stopped(StoppedHandler h) { on_stopped_ = std::move(h); }
void Engine::on_continued(ContinuedHandler h) { on_continued_ = std::move(h); }

void Engine::actor_loop() {
    for (;;) {
        std::function<void(Spectrum48K&)> job;
        {
            std::unique_lock<std::mutex> lock(queue_mutex_);
            queue_cv_.wait(lock, [this] { return shutting_down_ || !queue_.empty(); });
            if (shutting_down_ && queue_.empty()) {
                return;
            }
            job = std::move(queue_.front());
            queue_.pop_front();
        }
        sync_keys();
        job(machine_);
        // Refresh after every command, not just after a run: a debugger that
        // single-steps still wants the screen to track what it is doing.
        publish_screen();
    }
}

void Engine::submit_void(std::function<void(Spectrum48K&)> fn) {
    std::promise<void> done;
    std::future<void> fut = done.get_future();
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        queue_.push_back([fn = std::move(fn), &done](Spectrum48K& m) {
            fn(m);
            done.set_value();
        });
    }
    queue_cv_.notify_one();
    fut.wait();
}

template <typename R>
R Engine::submit(std::function<R(Spectrum48K&)> fn) {
    std::promise<R> result;
    std::future<R> fut = result.get_future();
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        queue_.push_back([fn = std::move(fn), &result](Spectrum48K& m) {
            result.set_value(fn(m));
        });
    }
    queue_cv_.notify_one();
    return fut.get();
}

void Engine::publish_screen() {
    // machine_.screen() is the last COMPLETED frame, so it only changes at a
    // frame boundary. A run yields roughly twice per frame, so without this
    // check about half the 330KB copies re-published a frame the viewer
    // already had. Measured as a wash on bench_machine -- kept because it is
    // strictly less work, not because it showed up as a win.
    const uint64_t frame = machine_.ula.frame_count();
    if (frame == published_frame_) {
        return;
    }
    published_frame_ = frame;
    std::lock_guard<std::mutex> lock(screen_mutex_);
    screen_snapshot_ = machine_.screen();
}

void Engine::pace_reset() {
    pace_origin_ = std::chrono::steady_clock::now();
    pace_origin_hc_ = machine_.ula.frame_count() * uint64_t(HC_PER_FRAME)
                      + machine_.ula.frame_hc();
}

void Engine::pace_wait() {
    if (speed_.load() == Speed::Uncapped) {
        return;
    }
    const uint64_t hc = machine_.ula.frame_count() * uint64_t(HC_PER_FRAME)
                        + machine_.ula.frame_hc();
    const double emulated_seconds = double(hc - pace_origin_hc_) / REALTIME_HC_PER_SEC;
    const auto target =
        pace_origin_ + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                           std::chrono::duration<double>(emulated_seconds));
    const auto now = std::chrono::steady_clock::now();

    if (now >= target) {
        // Running behind rather than ahead: nothing to wait for. If we have
        // fallen a long way behind, forget the debt (see MAX_PACING_DEBT).
        if (now - target > MAX_PACING_DEBT) {
            pace_reset();
        }
        return;
    }
    std::this_thread::sleep_for(target - now);
}

void Engine::publish_progress() {
    emulated_hc_.store(machine_.ula.frame_count() * uint64_t(HC_PER_FRAME)
                       + machine_.ula.frame_hc());
}

void Engine::sync_keys() {
    std::lock_guard<std::mutex> lock(key_mutex_);
    machine_.keyboard.set_rows(keys_.rows());
}

std::vector<uint8_t> Engine::screen() {
    std::lock_guard<std::mutex> lock(screen_mutex_);
    return screen_snapshot_;
}

void Engine::key_down(const std::string& key) {
    std::lock_guard<std::mutex> lock(key_mutex_);
    keys_.key_down(key);
}

void Engine::key_up(const std::string& key) {
    std::lock_guard<std::mutex> lock(key_mutex_);
    keys_.key_up(key);
}

MachineState Engine::snapshot(bool running) const {
    MachineState s;
    s.registers = machine_.registers();
    s.pc = s.registers.pc;
    s.halted = machine_.cpu.halted;
    s.running = running;
    s.border = machine_.ula.border;
    s.tstate = machine_.ula.tstate();
    s.frame_count = machine_.ula.frame_count();
    s.interrupt_count = machine_.cpu.interrupt_count;
    for (uint16_t bp : machine_.breakpoints) {
        s.breakpoints.push_back(bp);
    }
    s.call_stack = machine_.call_stack;
    return s;
}

// ---- queued operations -----------------------------------------------------

std::string Engine::load_rom(std::vector<uint8_t> data) {
    return submit<std::string>([data = std::move(data)](Spectrum48K& m) {
        return m.load_rom(data.data(), data.size());
    });
}

std::string Engine::load_snapshot(std::vector<uint8_t> data) {
    std::string err = submit<std::string>([data = std::move(data)](Spectrum48K& m) {
        return load_sna(m, data.data(), data.size());
    });
    if (err.empty() && on_stopped_) {
        on_stopped_(StopReason::Entry, registers().pc);
    }
    return err;
}

Registers Engine::reset() {
    Registers r = submit<Registers>([](Spectrum48K& m) {
        m.reset();
        return m.registers();
    });
    if (on_stopped_) {
        on_stopped_(StopReason::Entry, r.pc);
    }
    return r;
}

Registers Engine::step(uint32_t instructions) {
    Registers r = submit<Registers>([instructions](Spectrum48K& m) {
        for (uint32_t i = 0; i < instructions; i++) {
            m.step_instruction();
        }
        return m.registers();
    });
    if (on_stopped_) {
        on_stopped_(StopReason::Step, r.pc);
    }
    return r;
}

Registers Engine::step_tstates(uint32_t tstates) {
    Registers r = submit<Registers>([tstates](Spectrum48K& m) {
        for (uint32_t i = 0; i < tstates; i++) {
            m.tick();
        }
        return m.registers();
    });
    if (on_stopped_) {
        on_stopped_(StopReason::Step, r.pc);
    }
    return r;
}

Registers Engine::step_over_halt(uint16_t target_pc) {
    pause_requested_.store(false);
    Registers r = submit<Registers>([this, target_pc](Spectrum48K& m) {
        uint64_t count = 0;
        for (;;) {
            if (pause_requested_.load()) {
                break;
            }
            m.step_instruction();
            // NOT just pc == target_pc. That is also exactly what a HALT
            // still waiting displays, and what a `HALT; ...; JP` loop shows
            // every time it comes back round -- so an address-only check
            // fires long before any real return. The !halted qualifier is
            // what makes this correct.
            if (!m.cpu.halted && m.registers().pc == target_pc) {
                break;
            }
            if (++count % RUN_YIELD_EVERY == 0) {
                sync_keys();
                publish_screen();
                publish_progress();
            }
        }
        return m.registers();
    });
    if (on_stopped_) {
        on_stopped_(StopReason::Step, r.pc);
    }
    return r;
}

MachineState Engine::run() {
    pause_requested_.store(false);
    if (on_continued_) {
        on_continued_();
    }
    StopReason reason = StopReason::Breakpoint;
    MachineState s = submit<MachineState>([this, &reason](Spectrum48K& m) {
        pace_reset();
        uint64_t count = 0;
        for (;;) {
            if (pause_requested_.load()) {
                reason = StopReason::Pause;
                break;
            }
            const uint64_t interrupts_before = m.cpu.interrupt_count;
            m.step_instruction();
            if (break_on_interrupt_.load() && m.cpu.interrupt_count != interrupts_before) {
                // PC is now the handler's first instruction, which is
                // where someone asking to break on an interrupt wants to
                // land.
                reason = StopReason::Interrupt;
                break;
            }
            if (m.breakpoints.count(m.registers().pc) != 0) {
                reason = StopReason::Breakpoint;
                break;
            }
            if (++count % RUN_YIELD_EVERY == 0) {
                sync_keys();
                publish_screen();
                publish_progress();
                pace_wait();
            }
        }
        return snapshot(false);
    });
    if (on_stopped_) {
        on_stopped_(reason, s.pc);
    }
    return s;
}

void Engine::set_breakpoint(uint16_t addr) {
    submit_void([addr](Spectrum48K& m) { m.breakpoints.insert(addr); });
}

void Engine::clear_breakpoint(uint16_t addr) {
    submit_void([addr](Spectrum48K& m) { m.breakpoints.erase(addr); });
}

std::vector<uint8_t> Engine::read_memory(uint16_t addr, size_t length) {
    return submit<std::vector<uint8_t>>(
        [addr, length](Spectrum48K& m) { return m.read_memory(addr, length); });
}

void Engine::write_memory(uint16_t addr, std::vector<uint8_t> data) {
    submit_void([addr, data = std::move(data)](Spectrum48K& m) {
        m.write_memory(addr, data.data(), data.size());
    });
}

Registers Engine::registers() {
    return submit<Registers>([](Spectrum48K& m) { return m.registers(); });
}

Registers Engine::set_registers(Registers r) {
    Registers out = submit<Registers>([r](Spectrum48K& m) {
        m.set_registers(r);
        return m.registers();
    });
    if (on_stopped_) {
        on_stopped_(StopReason::Step, out.pc);
    }
    return out;
}

MachineState Engine::state() {
    return submit<MachineState>([this](Spectrum48K& m) {
        (void)m;
        return snapshot(false);
    });
}

} // namespace zx
