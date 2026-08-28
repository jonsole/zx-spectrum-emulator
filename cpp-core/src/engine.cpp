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

/// How long a single audio-paced yield may wait for the device to drain
/// before giving up on it. Comfortably longer than the few milliseconds a
/// healthy device takes, short enough that a stalled one does not hang the
/// emulator for a noticeable time.
constexpr auto AUDIO_PACING_TIMEOUT = std::chrono::milliseconds(120);

/// Consecutive timeouts before the audio clock is abandoned for the wall
/// clock. One is a hiccup (a device switch, a laptop resuming); several in a
/// row means nothing is draining and never will be.
constexpr int MAX_PACING_TIMEOUTS = 3;

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
            job = std::move(queue_.front().fn);
            queue_.pop_front();
        }
        sync_keys();
        job(machine_);
        // Refresh after every command, not just after a run: a debugger that
        // single-steps still wants the screen to track what it is doing.
        publish_screen();
        publish_audio();
        // The servicing point for a trace request made while nothing was
        // running -- there is no yield to catch it in that case, which is why
        // request_trace posts a command purely to get here.
        service_trace();
        service_tape();
    }
}

void Engine::submit_void(std::function<void(Spectrum48K&)> fn, bool during_run) {
    std::promise<void> done;
    std::future<void> fut = done.get_future();
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        queue_.push_back(Job{[fn = std::move(fn), &done](Spectrum48K& m) {
                                 fn(m);
                                 done.set_value();
                             },
                             during_run});
    }
    queue_cv_.notify_one();
    fut.wait();
}

void Engine::post(std::function<void(Spectrum48K&)> fn) {
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        queue_.push_back(Job{std::move(fn), true});
    }
    queue_cv_.notify_one();
}

template <typename R>
R Engine::submit(std::function<R(Spectrum48K&)> fn, bool during_run) {
    std::promise<R> result;
    std::future<R> fut = result.get_future();
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        queue_.push_back(
            Job{[fn = std::move(fn), &result](Spectrum48K& m) { result.set_value(fn(m)); },
                during_run});
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

void Engine::publish_audio() {
    // The beeper is switched on only while something is listening. ZEXALL runs
    // for over a billion instructions with no sink attached, and generating
    // audio nobody will hear is measurable at 7MHz.
    //
    // Realtime pacing is also what makes a sample stream line up with the wall
    // clock: an uncapped run produces the same audio hundreds of times too
    // fast, so there is nothing sensible to play there either.
    std::lock_guard<std::mutex> lock(audio_mutex_);
    const uint64_t now_hc = machine_.global_hc();
    const bool wanted = !audio_sinks_.empty() && speed_.load() != Speed::Uncapped;
    machine_.beeper.set_enabled(wanted, now_hc);
    if (!wanted) {
        machine_.beeper.discard();
        return;
    }
    // Catch the integration up to now, so a sample period left open by the
    // last port write is closed and this block ends where the next begins.
    machine_.beeper.advance_to(now_hc);
    audio_scratch_.clear();
    machine_.beeper.drain(audio_scratch_);
    if (audio_scratch_.empty()) {
        return;
    }
    for (const std::shared_ptr<AudioRing>& sink : audio_sinks_) {
        sink->write(audio_scratch_.data(), audio_scratch_.size());
    }
}

std::shared_ptr<AudioRing> Engine::add_audio_sink(size_t capacity) {
    std::shared_ptr<AudioRing> ring = std::make_shared<AudioRing>(capacity);
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio_sinks_.push_back(ring);
    return ring;
}

void Engine::set_pacing_clock(PacingClock buffered, size_t target_samples) {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    pacing_clock_ = std::move(buffered);
    pacing_target_ = target_samples;
    pacing_timeouts_ = 0;
}

void Engine::set_audio_sample_rate(uint32_t rate) {
    if (rate == 0) {
        return;
    }
    audio_sample_rate_.store(rate);
    // Queued, because the Beeper belongs to the machine and only the actor
    // thread may touch it.
    submit_void([rate](Spectrum48K& m) { m.beeper.set_sample_rate(rate); });
}

void Engine::clear_pacing_clock() {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    pacing_clock_ = nullptr;
    pacing_target_ = 0;
}

void Engine::remove_audio_sink(const std::shared_ptr<AudioRing>& ring) {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    for (size_t i = 0; i < audio_sinks_.size(); i++) {
        if (audio_sinks_[i] == ring) {
            audio_sinks_.erase(audio_sinks_.begin() + long(i));
            return;
        }
    }
}

void Engine::pace_reset() {
    pace_origin_ = std::chrono::steady_clock::now();
    pace_origin_hc_ = machine_.global_hc();
}

void Engine::pace_wait() {
    if (speed_.load() == Speed::Uncapped) {
        return;
    }

    PacingClock clock;
    size_t target_samples = 0;
    {
        std::lock_guard<std::mutex> lock(audio_mutex_);
        clock = pacing_clock_;
        target_samples = pacing_target_;
    }
    if (clock) {
        // Audio-driven pacing: hold here until the device has drained back to
        // the target backlog, so emulated time advances at exactly the rate
        // real samples are consumed. See Engine::set_pacing_sink.
        const auto deadline = std::chrono::steady_clock::now() + AUDIO_PACING_TIMEOUT;
        bool timed_out = false;
        while (clock() > target_samples) {
            if (std::chrono::steady_clock::now() >= deadline) {
                timed_out = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        std::lock_guard<std::mutex> lock(audio_mutex_);
        if (timed_out) {
            if (++pacing_timeouts_ >= MAX_PACING_TIMEOUTS) {
                pacing_clock_ = nullptr;
                pacing_target_ = 0;
            }
        } else {
            pacing_timeouts_ = 0;
        }
        // Keep the wall-clock baseline current, so that dropping back to it
        // (above, or when the device goes away) does not start life owing a
        // debt for however long audio pacing was in charge.
        pace_origin_ = std::chrono::steady_clock::now();
        pace_origin_hc_ = machine_.global_hc();
        return;
    }

    const uint64_t hc = machine_.global_hc();
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
    emulated_hc_.store(machine_.global_hc());
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

std::string Engine::load_tape(std::vector<uint8_t> data, std::string name, bool auto_start) {
    std::string err = submit<std::string>(
        [this, data = std::move(data), name = std::move(name), auto_start](Spectrum48K& m) {
            std::string error = m.tape.insert(data.data(), data.size(), name);
            if (!error.empty()) {
                return error;
            }
            m.tape.set_fast_load(tape_fast_load_.load());
            if (!auto_start) {
                return error;
            }
            // Typing runs a couple of seconds of emulation, which is exactly
            // why this is a queued command: it owns the machine while it does.
            // It also resets, and a reset zeroes global_hc(), so the tape can
            // only be started once the typing is done.
            // type_load_command starts the motor itself, at the right
            // moment relative to the ENTER keypress -- which is a moment this
            // function has no way to reach from outside it.
            return type_load_command(m);
        });
    // Waits for the emulator thread to republish the tape snapshot before
    // returning. submit() comes back the instant the job's promise is set,
    // which is BEFORE the actor loop reaches service_tape() -- so without this
    // the caller's very next tape_status()/tape_blocks() can still describe
    // the deck as it was before the insert. An empty command is all it takes;
    // request_tape waits for the republish, which is the point.
    if (err.empty()) {
        request_tape(TapeCommand::None);
    }
    if (err.empty() && !running_.load() && on_stopped_) {
        on_stopped_(StopReason::Entry, registers().pc);
    }
    return err;
}

std::string Engine::wait_for_tape() {
    std::string err =
        submit<std::string>([](Spectrum48K& m) { return type_load_command(m); });
    // Only when the machine was not already running: serviced at a run's
    // yield the run simply carries on, and announcing a stop it never made
    // would leave a debugger showing a stopped machine that is still going.
    if (err.empty() && !running_.load() && on_stopped_) {
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
    }, /*during_run=*/false);
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
    }, /*during_run=*/false);
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
                publish_audio();
                publish_progress();
                service_trace();
                // Queued commands BEFORE service_tape, so the tape status it
                // republishes already reflects them -- otherwise a load_tape
                // serviced here would return the snapshot from before its own
                // insert, and report an empty tape.
                service_queue();
                service_tape();
            }
        }
        return m.registers();
    }, /*during_run=*/false);
    if (on_stopped_) {
        on_stopped_(StopReason::Step, r.pc);
    }
    return r;
}

MachineState Engine::run() {
    pause_requested_.store(false);
    running_.store(true);
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
                publish_audio();
                publish_progress();
                service_trace();
                // Queued commands BEFORE service_tape, so the tape status it
                // republishes already reflects them -- otherwise a load_tape
                // serviced here would return the snapshot from before its own
                // insert, and report an empty tape.
                service_queue();
                service_tape();
                pace_wait();
            }
        }
        return snapshot(false);
    }, /*during_run=*/false);
    running_.store(false);
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

TraceStatus Engine::trace_snapshot() const {
    TraceStatus s;
    if (!trace_) {
        return s;
    }
    s.active = trace_->active();
    s.path = trace_->path();
    s.rows = trace_->rows();
    s.limit = trace_->options().limit;
    s.watching = trace_->options().watch != TRACE_NO_WATCH;
    s.watch = uint16_t(trace_->options().watch);
    s.extra = trace_->options().extra;
    return s;
}

std::string Engine::start_trace(TraceOptions options) {
    // Opened here rather than on the emulator thread so that a path that
    // cannot be written is an error the caller sees, instead of a capture that
    // silently records nothing. Nothing else touches this TraceLog until
    // service_trace() installs it.
    std::unique_ptr<TraceLog> log(new TraceLog());
    const std::string error = log->open(options);
    if (!error.empty()) {
        return error;
    }
    // Starting a second capture supersedes the first rather than failing --
    // the alternative (an error the caller has to clear with an explicit stop)
    // is friction with no upside when the usual reason to restart is "that
    // window was wrong".
    request_trace(std::move(log));
    return std::string();
}

TraceStatus Engine::stop_trace() {
    request_trace(nullptr);
    return trace_status();
}

TraceStatus Engine::trace_status() const {
    // The mutex is only what keeps the capture alive across the read -- the
    // row count and the active flag are atomics the emulator thread updates as
    // it writes, so this is genuinely live rather than a snapshot from the
    // last yield. That matters more than it sounds: tracing is slow enough
    // that yields are seconds apart, and a counter that only moved then would
    // sit at zero through most of a capture.
    std::lock_guard<std::mutex> lock(trace_mutex_);
    return trace_snapshot();
}

void Engine::request_trace(std::unique_ptr<TraceLog> log) {
    uint64_t wanted;
    {
        std::lock_guard<std::mutex> lock(trace_mutex_);
        // Replacing a request the emulator thread has not picked up yet closes
        // its file as it goes (nothing was ever written to it) -- the later
        // request is the one that meant it.
        pending_trace_ = std::move(log);
        wanted = ++trace_requested_;
        trace_change_pending_.store(true, std::memory_order_release);
    }
    // A run reaches service_trace() at its own yields, but a machine sitting
    // at a breakpoint never will: an empty command wakes the actor thread so
    // it services the request between jobs like any other.
    post([](Spectrum48K&) {});
    std::unique_lock<std::mutex> lock(trace_mutex_);
    trace_cv_.wait(lock, [this, wanted] { return trace_applied_ >= wanted; });
}

void Engine::tape_play() { request_tape(TapeCommand::Play); }
void Engine::tape_stop() { request_tape(TapeCommand::Stop); }
void Engine::tape_rewind() { request_tape(TapeCommand::Rewind); }
void Engine::tape_eject() { request_tape(TapeCommand::Eject); }

void Engine::tape_seek(size_t index) { request_tape(TapeCommand::Seek, index); }

void Engine::set_tape_fast_load(bool on) {
    tape_fast_load_.store(on);
    // Nothing to apply by hand: service_tape() pushes the flag into the
    // machine at the next yield, which is also the only thread allowed to
    // touch it.
    request_tape(TapeCommand::None);
}

TapeStatus Engine::tape_status() const {
    std::lock_guard<std::mutex> lock(tape_mutex_);
    return live_tape_status_;
}

std::vector<TapeBlockInfo> Engine::tape_blocks() const {
    std::lock_guard<std::mutex> lock(tape_mutex_);
    return live_tape_blocks_;
}

void Engine::request_tape(TapeCommand what, size_t block) {
    uint64_t wanted;
    {
        std::lock_guard<std::mutex> lock(tape_mutex_);
        // A command the emulator thread has not picked up yet is simply
        // replaced. Two Plays in a row mean one Play, and Play-then-Stop
        // arriving inside one yield means Stop -- the later request is the one
        // that meant it.
        if (what != TapeCommand::None) {
            pending_tape_ = what;
            pending_tape_block_ = block;
        }
        wanted = ++tape_requested_;
        tape_change_pending_.store(true, std::memory_order_release);
    }
    // A run reaches service_tape() at its own yields, but a machine sitting at
    // a breakpoint never will, so an empty command wakes the actor thread to
    // service this between jobs.
    post([](Spectrum48K&) {});
    std::unique_lock<std::mutex> lock(tape_mutex_);
    tape_cv_.wait(lock, [this, wanted] { return tape_applied_ >= wanted; });
}

void Engine::service_queue() {
    for (;;) {
        std::function<void(Spectrum48K&)> job;
        {
            std::lock_guard<std::mutex> lock(queue_mutex_);
            // Oldest servicable command first, stepping over any that must
            // wait for the run to end. Reordering only ever moves an ordinary
            // command ahead of a queued run or step, and a second run issued
            // while one is already in flight has no defined order anyway.
            auto it = queue_.begin();
            while (it != queue_.end() && !it->during_run) {
                ++it;
            }
            if (it == queue_.end()) {
                return;
            }
            job = std::move(it->fn);
            queue_.erase(it);
        }
        job(machine_);
    }
}

void Engine::service_tape() {
    if (tape_change_pending_.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lock(tape_mutex_);
        machine_.tape.set_fast_load(tape_fast_load_.load());
        if (pending_tape_ == TapeCommand::Play) {
            machine_.tape.play(machine_.global_hc());
        } else if (pending_tape_ == TapeCommand::Stop) {
            machine_.tape.stop();
        } else if (pending_tape_ == TapeCommand::Rewind) {
            machine_.tape.rewind();
        } else if (pending_tape_ == TapeCommand::Eject) {
            machine_.tape.eject();
        } else if (pending_tape_ == TapeCommand::Seek) {
            machine_.tape.seek(pending_tape_block_);
        }
        pending_tape_ = TapeCommand::None;
        tape_change_pending_.store(false, std::memory_order_release);
    }
    // Walked even when nothing was requested. Without this the cursor only
    // moves when the CPU reads port 0xFE, so a program that stops polling --
    // or a run with no tape reader in it at all -- would leave the next read
    // to skip the whole tape in one call, and would freeze the position
    // readout meanwhile.
    machine_.tape.advance_to(machine_.global_hc());
    {
        std::lock_guard<std::mutex> lock(tape_mutex_);
        live_tape_status_ = machine_.tape.status(machine_.global_hc());
        // Only when the deck itself changed. The list is parse-time data, and
        // this runs every RUN_YIELD_EVERY instructions -- copying a hundred
        // blocks' worth of strings at that rate to say the same thing each
        // time is the one cost this whole path cannot afford.
        if (live_tape_generation_ != machine_.tape.generation()) {
            live_tape_blocks_ = machine_.tape.block_infos();
            live_tape_generation_ = machine_.tape.generation();
        }
        // Republished BEFORE the waiters are released, so a caller woken by
        // its own command reads a snapshot that already reflects it.
        tape_applied_ = tape_requested_;
    }
    tape_cv_.notify_all();
}

void Engine::service_trace() {
    if (trace_change_pending_.load(std::memory_order_acquire)) {
        std::unique_lock<std::mutex> lock(trace_mutex_);
        // Closing the outgoing capture HERE is what makes the handover safe:
        // an open TraceLog is only ever written to and closed by this thread.
        if (trace_) {
            trace_->close();
        }
        // A stop (null request) deliberately leaves the closed capture in
        // place, so stop_trace can still report where it went and how much it
        // caught.
        if (pending_trace_) {
            trace_ = std::move(pending_trace_);
        }
        machine_.trace = trace_ && trace_->active() ? trace_.get() : nullptr;
        trace_change_pending_.store(false, std::memory_order_release);
        trace_applied_ = trace_requested_;
        lock.unlock();
        trace_cv_.notify_all();
        return;
    }
    // A capture closes itself on reaching its row limit. Unhooking it once it
    // has keeps the machine's hot loop out of a finished trace for the rest of
    // the session. Nothing to publish: trace_status() reads the capture
    // directly.
    if (machine_.trace != nullptr && !trace_->active()) {
        machine_.trace = nullptr;
    }
}

} // namespace zx
