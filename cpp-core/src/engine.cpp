#include "engine.h"

#include "snapshot.h"
#include "ula.h"

#include <cstdio>
#include <cstring>

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

/// The fewest instructions between yields, at any speed. Only a guard
/// against zero: the interval is otherwise scaled strictly in proportion to
/// the speed, which keeps the number of yields PER WALL SECOND the same
/// however slowly the machine is running -- so the housekeeping costs the
/// same per second at 1/1000 as at 1x, and the beam is sampled just as often.
///
/// A larger floor is what made slow motion jerky: at 1/1000 a floor of 100
/// instructions worked out at nine yields a second, against the fifty frames
/// a second the viewer sends, so the picture stood still for five frames and
/// then jumped a couple of scanlines.
constexpr uint64_t MIN_RUN_YIELD_EVERY = 1;

/// How often the RGB snapshot is rebuilt while running.
///
/// Matches screen_stream's own send interval: rebuilding faster than the
/// viewer transmits is pure copying (330KB a time), and no eye can see it
/// either. Frequent yields decide how finely the beam is sampled; this
/// decides how often that sampling turns into a picture.
constexpr auto SCREEN_PUBLISH_INTERVAL = std::chrono::milliseconds(20);

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

/// How many entries a profile snapshot's strip of periods is reduced to:
/// enough to see a spike, few enough to send every second.
constexpr size_t PROFILE_STRIP_ENTRIES = 400;

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
        // DAP's own name for a watchpoint stop.
        case StopReason::DataBreakpoint: return "data breakpoint";
        default: return "error";
    }
}

Engine::Engine() {
#ifdef _WIN32
    timeBeginPeriod(1); // see the note on the include above
#endif
#if ZX_REWIND
    // Before the thread starts, which is the only other thing that touches it.
    restart_history(machine_);
    // Running backwards stops where running forwards would, value tests and
    // all -- so a search asks the same question of a hit that the run loop
    // does, minus the bookkeeping.
    history_.set_watch_filter([this](const WatchHit& hit) { return watch_wanted(hit) != nullptr; });
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
void Engine::on_graphics_view(GraphicsViewHandler h) { on_graphics_view_ = std::move(h); }
void Engine::add_log_handler(LogHandler h) {
    std::lock_guard<std::mutex> lock(log_handlers_mutex_);
    log_handlers_.push_back(std::move(h));
}

void Engine::set_graphics_view(const GraphicsView& v) {
    GraphicsViewHandler handler;
    uint64_t version = 0;
    {
        std::lock_guard<std::mutex> lock(graphics_mutex_);
        graphics_view_ = v;
        version = ++graphics_version_;
        handler = on_graphics_view_;
    }
    // Outside the lock: the handler writes to every open DAP socket, and a
    // slow client must not hold up the next caller of this.
    if (handler) {
        handler(v, version);
    }
}

GraphicsView Engine::graphics_view(uint64_t* version) const {
    std::lock_guard<std::mutex> lock(graphics_mutex_);
    if (version != nullptr) {
        *version = graphics_version_;
    }
    return graphics_view_;
}

void Engine::actor_loop() {
    for (;;) {
        std::function<void(Spectrum&)> job;
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

void Engine::submit_void(std::function<void(Spectrum&)> fn, bool during_run) {
    std::promise<void> done;
    std::future<void> fut = done.get_future();
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        // The log is flushed before the caller is released, because the
        // caller is what announces a stop: reports from a run have to reach
        // a client before the stop that ended it does.
        queue_.push_back(Job{[this, fn = std::move(fn), &done](Spectrum& m) {
                                 fn(m);
                                 flush_log(true);
                                 done.set_value();
                             },
                             during_run});
    }
    queue_cv_.notify_one();
    fut.wait();
}

void Engine::post(std::function<void(Spectrum&)> fn) {
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        queue_.push_back(Job{std::move(fn), true});
    }
    queue_cv_.notify_one();
}

template <typename R>
R Engine::submit(std::function<R(Spectrum&)> fn, bool during_run) {
    std::promise<R> result;
    std::future<R> fut = result.get_future();
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        queue_.push_back(
            Job{[this, fn = std::move(fn), &result](Spectrum& m) {
                    R value = fn(m);
                    flush_log(true); // before the caller announces a stop: see submit_void
                    result.set_value(std::move(value));
                },
                during_run});
    }
    queue_cv_.notify_one();
    return fut.get();
}

void Engine::set_raster_view(const RasterView& v) {
    raster_marker_.store(v.marker);
    raster_in_progress_.store(v.in_progress);
    raster_pending_.store(v.pending);
    // A stopped machine is not about to publish anything by itself, and none
    // of the above moves the beam -- so without these two the picture would go
    // on showing the old view until some unrelated command arrived, which is
    // no use at all to someone toggling one of these to see what it looks
    // like. The flag says "republish even though nothing moved".
    //
    // The publish is done INSIDE the job rather than left to the one
    // actor_loop does after it. submit_void hands back the moment the job body
    // ends, which is before that -- so a caller who sets a view and reads the
    // screen straight afterwards would otherwise race the republish and get
    // the old view back, and win that race often enough to be baffling.
    screen_dirty_.store(true);
    submit_void([this](Spectrum&) { publish_screen(); }, /*during_run=*/true);
}

RasterView Engine::raster_view() const {
    RasterView v;
    v.marker = raster_marker_.load();
    v.in_progress = raster_in_progress_.load();
    v.pending = raster_pending_.load();
    return v;
}

void Engine::publish_screen() {
    // The annotations answer where-is-the-beam, and for a machine running at
    // full speed there is no useful answer: the beam crosses the screen in
    // 20ms, far faster than frames are published, so a marker would be a
    // smear at an arbitrary position. Hence the original rule -- annotate
    // only while stopped.
    //
    // Slow motion breaks that assumption in the useful direction. At a tenth
    // speed a frame lasts 200ms and the beam sweeps down the screen slowly
    // enough to follow, which is exactly what someone debugging a raster
    // effect wants to see happening rather than reconstruct from stills. The
    // flags still decide WHETHER to draw; this only decides whether drawing
    // them could mean anything.
    const bool watchable = !running_.load() || slow_motion();
    const bool marker = watchable && raster_marker_.load();
    const bool in_progress = watchable && raster_in_progress_.load();
    const bool pending = watchable && raster_pending_.load();
    const bool annotated = marker || in_progress || pending;
    // machine_.screen() is the last COMPLETED frame, so it only changes at a
    // frame boundary. A run yields roughly twice per frame, so without this
    // check about half the 330KB copies re-published a frame the viewer
    // already had. Measured as a wash on bench_machine -- kept because it is
    // strictly less work, not because it showed up as a win.
    //
    // The marker's position is part of what was published, though, and it
    // moves WITHIN a frame: a single stepped instruction changes the picture
    // without touching the frame counter. So the check is against both, and
    // NO_RASTER stands for "published without a marker" -- which is also what
    // makes the marker disappear on the first publish after a run starts.
    constexpr uint32_t NO_RASTER = ~uint32_t(0);
    const uint64_t frame = machine_.ula.frame_count();
    const uint32_t raster = annotated ? machine_.ula.frame_hc() : NO_RASTER;
    // exchange, not load: the request to republish is consumed by doing it.
    const bool requested = screen_dirty_.exchange(false);
    if (!requested) {
        if (frame == published_frame_ && raster == published_raster_) {
            return;
        }
        // Something changed, but perhaps sooner than anyone can look at it.
        // Only while RUNNING: a stopped machine publishes whenever its
        // picture changes, because there every change is a deliberate step
        // somebody is waiting to see.
        if (running_.load()) {
            const auto now = std::chrono::steady_clock::now();
            if (now - last_screen_publish_ < SCREEN_PUBLISH_INTERVAL) {
                return;
            }
            last_screen_publish_ = now;
        }
    }
    published_frame_ = frame;
    published_raster_ = raster;
    std::vector<uint8_t> rgb =
        in_progress ? machine_.ula.screen_in_progress() : machine_.screen();
    // Pending first, the marker over it: the beam's own line is the thing you
    // are reading the pending tint against, so it must not be tinted away.
    if (pending) {
        machine_.ula.draw_pending_writes(rgb);
    }
    if (marker) {
        machine_.ula.draw_raster_marker(rgb);
    }
    std::lock_guard<std::mutex> lock(screen_mutex_);
    screen_snapshot_ = std::move(rgb);
}

void Engine::note_frame(const Spectrum& m) {
    const uint64_t frame = m.ula.frame_count();
    if (frame == last_frame_seen_) {
        return;
    }
    last_frame_seen_ = frame;
    if (video_.active()) {
        video_.push(m.screen());
    }
    if (!capture_active_.load(std::memory_order_relaxed)) {
        return;
    }
    std::lock_guard<std::mutex> lock(capture_mutex_);
    if (!capture_active_.load(std::memory_order_relaxed) || frame < capture_next_frame_) {
        return;
    }
    CapturedFrame captured;
    captured.frame_number = frame;
    captured.rgb = m.screen();
    capture_frames_.push_back(std::move(captured));
    capture_next_frame_ = frame + capture_every_;
    if (capture_frames_.size() >= capture_wanted_) {
        capture_active_.store(false, std::memory_order_relaxed);
        capture_cv_.notify_all();
    }
}

void Engine::arm_capture(uint32_t count, uint32_t every) {
    std::lock_guard<std::mutex> lock(capture_mutex_);
    capture_frames_.clear();
    capture_wanted_ = count;
    capture_every_ = every == 0 ? 1 : every;
    capture_next_frame_ = 0;
    capture_active_.store(count != 0, std::memory_order_relaxed);
}

std::vector<CapturedFrame> Engine::capture_frames(uint32_t count, uint32_t every,
                                                  std::chrono::milliseconds timeout) {
    arm_capture(count, every);
    if (!running_.load()) {
        // Nothing is turning the frames over, so turn them over here: a
        // queued job, like a step, that runs the machine a frame at a time
        // until the capture is full. Should a run have started in between,
        // the job waits behind it and finds the capture already filled by
        // the run's own tap -- and then has nothing to do.
        //
        // Bounded by the frames the capture can possibly want, so a capture
        // that is somehow never satisfied cannot run the machine forever.
        const uint64_t at_most = uint64_t(count) * (every == 0 ? 1 : every) + 1;
        //
        // A frame's worth of whole instructions rather than run_frame's raw
        // clocking, so the machine is left at an instruction boundary, the
        // call stack and tape trap work as in a run, and rewind has nothing
        // to do but record it as a run.
        Registers r = submit<Registers>([this, at_most](Spectrum& m) {
            sync_keys();
            for (uint64_t i = 0; i < at_most && capture_active_.load(std::memory_order_relaxed);
                 i++) {
                const uint64_t frame = m.ula.frame_count();
                while (m.ula.frame_count() == frame) {
                    m.step_instruction();
                    after_instruction(m);
                }
            }
            return m.registers();
        }, /*during_run=*/false);
        if (on_stopped_) {
            on_stopped_(StopReason::Step, r.pc);
        }
    }
    std::unique_lock<std::mutex> lock(capture_mutex_);
    capture_cv_.wait_for(lock, timeout, [this] {
        return !capture_active_.load(std::memory_order_relaxed);
    });
    // Whatever was collected, complete or not; and disarmed either way, so a
    // frame boundary after a timeout does not push into a vector nobody is
    // waiting on.
    capture_active_.store(false, std::memory_order_relaxed);
    std::vector<CapturedFrame> out;
    out.swap(capture_frames_);
    return out;
}

namespace {

/// popen/pclose under their portable names. On Windows the whole command is
/// wrapped in one more pair of quotes: cmd.exe strips the first and last
/// quote of a command that begins with one, which is exactly what a quoted
/// executable path followed by a quoted output path looks like.
std::FILE* open_pipe(const std::string& command, const char* mode) {
#ifdef _WIN32
    return _popen(("\"" + command + "\"").c_str(), mode);
#else
    return popen(command.c_str(), mode);
#endif
}

int close_pipe(std::FILE* pipe) {
#ifdef _WIN32
    return _pclose(pipe);
#else
    return pclose(pipe);
#endif
}

/// Whether `ffmpeg` runs at all. popen cannot say -- a missing executable is
/// a shell error on a pipe that then simply closes -- so it is asked for its
/// version and expected to answer.
bool ffmpeg_runs(const std::string& ffmpeg) {
    std::FILE* pipe = open_pipe("\"" + ffmpeg + "\" -version", "r");
    if (pipe == nullptr) {
        return false;
    }
    char buffer[256];
    bool answered = false;
    while (std::fgets(buffer, sizeof buffer, pipe) != nullptr) {
        answered = true;
    }
    return close_pipe(pipe) == 0 && answered;
}

bool ends_with(const std::string& s, const char* suffix) {
    const size_t n = std::strlen(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

} // namespace

std::string Engine::start_video(const VideoOptions& options) {
    if (options.path.empty()) {
        return "a path is needed";
    }
    if (options.scale < 1 || options.scale > 4) {
        return "scale must be between 1 and 4";
    }
    if (!ffmpeg_runs(ffmpeg_)) {
        return "couldn't run '" + ffmpeg_
               + "': install ffmpeg (winget install Gyan.FFmpeg on Windows) or start "
                 "zx_server with --ffmpeg <path>";
    }
    // Raw RGB frames in on stdin at the Spectrum's own rate, scaled up
    // with nearest-neighbour so pixels stay square-edged, and the encoder
    // chosen by ffmpeg from the extension. yuv420p is what every player
    // decodes; ffmpeg would otherwise pick 4:4:4 for RGB input and produce
    // an .mp4 that several of them refuse. A .gif has its own palette
    // machinery and wants no pixel format forced on it.
    std::string command = "\"" + ffmpeg_ + "\" -hide_banner -loglevel error -nostats -y"
                          " -f rawvideo -pix_fmt rgb24 -s " + std::to_string(FULL_WIDTH) + "x"
                          + std::to_string(FULL_HEIGHT) + " -r 50 -i -";
    if (options.scale > 1) {
        command += " -vf scale=iw*" + std::to_string(options.scale) + ":ih*"
                   + std::to_string(options.scale) + ":flags=neighbor";
    }
    if (!ends_with(options.path, ".gif")) {
        command += " -pix_fmt yuv420p";
    }
    command += " \"" + options.path + "\"";
    std::FILE* pipe = open_pipe(command, "wb");
    if (pipe == nullptr) {
        return "couldn't start ffmpeg";
    }
    video_.start(pipe, close_pipe, options.path, size_t(FULL_WIDTH) * FULL_HEIGHT * 3,
                 options.frames);
    return "";
}

VideoStatus Engine::stop_video() {
    return video_.stop();
}

VideoStatus Engine::video_status() {
    return video_.status();
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
    // A speed multiplier silences the beeper for the same reason uncapped
    // does: samples are produced at a rate no sound device consumes them at,
    // so what comes out is not a slower or faster tune but a broken one. Half
    // speed and double speed are therefore silent, and 1x is not.
    const bool wanted = !audio_sinks_.empty() && speed_.load() != Speed::Uncapped
                        && speed_multiplier_.load() == 1.0;
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
    submit_void([rate](Spectrum& m) { m.beeper.set_sample_rate(rate); });
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

uint64_t Engine::yield_interval() const {
    if (!slow_motion()) {
        return RUN_YIELD_EVERY;
    }
    const double scaled = double(RUN_YIELD_EVERY) * speed_multiplier_.load();
    return scaled < double(MIN_RUN_YIELD_EVERY) ? MIN_RUN_YIELD_EVERY : uint64_t(scaled);
}

void Engine::pace_reset() {
    pace_origin_ = std::chrono::steady_clock::now();
    pace_origin_hc_ = machine_.global_hc();
}

void Engine::pace_wait() {
    if (speed_.load() == Speed::Uncapped) {
        return;
    }

    // At 1x the sound device is the better clock -- emulated time then
    // advances at exactly the rate samples are actually consumed. At any
    // other multiplier it is the wrong clock entirely: it paces to real time
    // by construction, and this branch returns without consulting the wall
    // clock at all, so leaving it in charge would silently ignore the
    // multiplier.
    const double multiplier = speed_multiplier_.load();
    PacingClock clock;
    size_t target_samples = 0;
    if (multiplier == 1.0) {
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

    if (pace_dirty_.exchange(false)) {
        // The multiplier changed since the last wait. Rebase first, so the
        // new rate governs from here rather than being applied retroactively
        // to time already elapsed.
        pace_reset();
    }

    const uint64_t hc = machine_.global_hc();
    // Divided by the multiplier: at 2x the same emulated time is allowed half
    // the wall-clock seconds, at 0.5x twice as many.
    const double emulated_seconds = double(hc - pace_origin_hc_)
                                    / (double(machine_.ula.timing().hc_per_sec) * multiplier);
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
    flush_log(false);
}

void Engine::sync_keys() {
    std::lock_guard<std::mutex> lock(key_mutex_);
#if ZX_REWIND
    const uint8_t* rows = keys_.rows();
    if (history_.live()) {
        std::memcpy(synced_keys_, rows, sizeof synced_keys_);
        if (std::memcmp(rows, machine_.keyboard.rows(), sizeof synced_keys_) == 0) {
            return;
        }
    } else {
        // In the past the machine holds the past's keys. Only a key pressed
        // or released since is new -- and it starts a new timeline.
        if (std::memcmp(rows, synced_keys_, sizeof synced_keys_) == 0) {
            return;
        }
        std::memcpy(synced_keys_, rows, sizeof synced_keys_);
    }
    RewindInput input;
    input.kind = RewindInputKind::Keys;
    std::memcpy(input.keys, rows, sizeof input.keys);
    history_.record(machine_, std::move(input));
#else
    machine_.keyboard.set_rows(keys_.rows());
#endif
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
#if ZX_REWIND
    s.in_past = !history_.live();
    s.behind_hc = history_.head_hc(machine_) - machine_.global_hc();
#endif
    s.registers = machine_.registers();
    s.pc = s.registers.pc;
    s.halted = machine_.cpu.halted;
    s.running = running;
    s.model = machine_.model();
    s.paging = machine_.memory.paging();
    s.border = machine_.ula.border;
    s.tstate = machine_.ula.tstate();
    s.frame_count = machine_.ula.frame_count();
    s.interrupt_count = machine_.cpu.interrupt_count;
    for (uint16_t bp : machine_.breakpoints) {
        s.breakpoints.push_back(bp);
    }
    s.call_stack = machine_.call_stack;
    s.watch_stop = watch_stop_;
    return s;
}

// ---- queued operations -----------------------------------------------------

std::string Engine::load_rom(std::vector<uint8_t> data) {
    return submit<std::string>([this, data = std::move(data)](Spectrum& m) {
        std::string error = m.load_rom(data.data(), data.size());
#if ZX_REWIND
        // Replay would run the new ROM over the old one's history.
        if (error.empty()) {
            restart_history(m);
        }
#else
        (void)this;
#endif
        return error;
    });
}

bool Engine::has_rom(Model model) {
    return submit<bool>([model](Spectrum& m) { return m.memory.has_rom(model); });
}

void Engine::set_model(Model model) {
    submit_void([this, model](Spectrum& m) {
        m.set_model(model);
#if ZX_REWIND
        restart_history(m);
#else
        (void)this;
#endif
    });
    // A model switch is a reset, and announced as one so a debugger refreshes
    // -- unless a run is in flight, which simply carries on in the new model.
    if (!running_.load() && on_stopped_) {
        on_stopped_(StopReason::Entry, registers().pc);
    }
}

Model Engine::model() {
    return submit<Model>([](Spectrum& m) { return m.model(); });
}

std::string Engine::load_snapshot(std::vector<uint8_t> data) {
    std::string err = submit<std::string>([this, data = std::move(data)](Spectrum& m) {
        std::string error = zx::load_snapshot(m, data.data(), data.size());
#if ZX_REWIND
        // Even on failure: a loader can have got part-way into the machine.
        restart_history(m);
#else
        (void)this;
#endif
        return error;
    });
    if (err.empty() && on_stopped_) {
        on_stopped_(StopReason::Entry, registers().pc);
    }
    return err;
}

std::string Engine::save_snapshot(std::vector<uint8_t>& out, SnapshotFormat format) {
    return submit<std::string>([&out, format](Spectrum& m) {
        if (format == SnapshotFormat::Z80) {
            save_z80(m, out);
            return std::string();
        }
        return save_sna(m, out);
    });
}

std::vector<uint8_t> Engine::read_bank(uint8_t bank, uint16_t offset, size_t length) {
    return submit<std::vector<uint8_t>>([bank, offset, length](Spectrum& m) {
        std::vector<uint8_t> out;
        if (bank >= RAM_BANKS) {
            return out;
        }
        out.reserve(length);
        for (size_t i = 0; i < length; i++) {
            out.push_back(m.memory.bank[bank][(offset + i) % BANK_SIZE]);
        }
        return out;
    });
}

std::string Engine::load_tape(std::vector<uint8_t> data, std::string name, bool auto_start) {
    std::string err = submit<std::string>(
        [this, data = std::move(data), name = std::move(name), auto_start](Spectrum& m) {
            std::string error = m.tape.insert(data.data(), data.size(), name);
            if (!error.empty()) {
                return error;
            }
            m.tape.set_fast_load(tape_fast_load_.load());
            if (!auto_start) {
#if ZX_REWIND
                // The history's checkpoints hold where the tape was, not what
                // is on it, so a different tape ends it.
                restart_history(m);
#endif
                return error;
            }
            // Typing runs a couple of seconds of emulation, which is exactly
            // why this is a queued command: it owns the machine while it does.
            // It also resets, and a reset zeroes global_hc(), so the tape can
            // only be started once the typing is done.
            // type_load_command starts the motor itself, at the right
            // moment relative to the ENTER keypress -- which is a moment this
            // function has no way to reach from outside it.
            error = type_load_command(m);
#if ZX_REWIND
            restart_history(m);
#endif
            return error;
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
    std::string err = submit<std::string>([this](Spectrum& m) {
        std::string error = type_load_command(m);
#if ZX_REWIND
        restart_history(m);
#else
        (void)this;
#endif
        return error;
    });
    // Only when the machine was not already running: serviced at a run's
    // yield the run simply carries on, and announcing a stop it never made
    // would leave a debugger showing a stopped machine that is still going.
    if (err.empty() && !running_.load() && on_stopped_) {
        on_stopped_(StopReason::Entry, registers().pc);
    }
    return err;
}

Registers Engine::reset() {
    Registers r = submit<Registers>([this](Spectrum& m) {
        m.reset();
#if ZX_REWIND
        restart_history(m);
#else
        (void)this;
#endif
        return m.registers();
    });
    if (on_stopped_) {
        on_stopped_(StopReason::Entry, r.pc);
    }
    return r;
}

Registers Engine::step(uint32_t instructions) {
    Registers r = submit<Registers>([this, instructions](Spectrum& m) {
        // A hit left unread by whatever stopped last must not stop this
        // before it has run anything.
        m.watch_hit = WatchHit();
        watch_stop_ = WatchStop();
        for (uint32_t i = 0; i < instructions; i++) {
            m.step_instruction();
            after_instruction(m);
            // Stepping a thousand instructions past the write you are hunting
            // would be no better than running past it.
            if (m.watch_hit.hit && watch_stop_wanted(m)) {
                break;
            }
        }
        return m.registers();
    }, /*during_run=*/false);
    if (on_stopped_) {
        on_stopped_(StopReason::Step, r.pc);
    }
    return r;
}

Registers Engine::step_tstates(uint32_t tstates) {
    Registers r = submit<Registers>([this, tstates](Spectrum& m) {
#if ZX_REWIND
        // Clocked raw, which a replay must do too (see RewindInputKind). In
        // the past, that makes it a new timeline.
        RewindInput input;
        input.kind = RewindInputKind::RawClocks;
        input.value = uint64_t(tstates) * HC_PER_TSTATE;
        history_.record(m, std::move(input));
#endif
        for (uint32_t i = 0; i < tstates; i++) {
            m.tick();
            note_frame(m);
        }
#if ZX_REWIND
        history_.on_instruction(m);
#endif
        return m.registers();
    }, /*during_run=*/false);
    if (on_stopped_) {
        on_stopped_(StopReason::Step, r.pc);
    }
    return r;
}

Registers Engine::step_over_halt(uint16_t target_pc) {
    pause_requested_.store(false);
    Registers r = submit<Registers>([this, target_pc](Spectrum& m) {
        m.watch_hit = WatchHit();
        watch_stop_ = WatchStop();
        const uint64_t yield_every = yield_interval();
        uint64_t count = 0;
        for (;;) {
            if (pause_requested_.load()) {
                break;
            }
            m.step_instruction();
            after_instruction(m);
            if (m.watch_hit.hit && watch_stop_wanted(m)) {
                break;
            }
            // NOT just pc == target_pc. That is also exactly what a HALT
            // still waiting displays, and what a `HALT; ...; JP` loop shows
            // every time it comes back round -- so an address-only check
            // fires long before any real return. The !halted qualifier is
            // what makes this correct.
            if (!m.cpu.halted && m.registers().pc == target_pc) {
                break;
            }
            if (++count % yield_every == 0) {
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
    MachineState s = submit<MachineState>([this, &reason](Spectrum& m) {
        // Neither a hit left unread by the last stop nor the last stop itself
        // belongs to this run.
        m.watch_hit = WatchHit();
        watch_stop_ = WatchStop();
        pace_reset();
        const uint64_t yield_every = yield_interval();
        uint64_t count = 0;
        for (;;) {
            if (pause_requested_.load()) {
                reason = StopReason::Pause;
                break;
            }
            const uint64_t interrupts_before = m.cpu.interrupt_count;
            m.step_instruction();
            after_instruction(m);
            if (m.watch_hit.hit && watch_stop_wanted(m)) {
                // PC is the instruction after the one that made the access;
                // the stop itself says which instruction that was.
                reason = StopReason::DataBreakpoint;
                break;
            }
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
            if (++count % yield_every == 0) {
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
        // Cleared here, inside the job, rather than only on the calling thread
        // once submit() returns: the publish that actor_loop does at the end of
        // this job is the one the screen viewer sees when a breakpoint is hit,
        // and it has to know the machine has stopped or it will draw the frame
        // without the raster marker and leave it that way until the next
        // command arrives.
        running_.store(false);
        return snapshot(false);
    }, /*during_run=*/false);
    running_.store(false);
    if (on_stopped_) {
        on_stopped_(reason, s.pc);
    }
    return s;
}

namespace {

/// Reports held for the handler before more are dropped: a logpoint in a
/// tight loop can report millions of times a second, and nothing downstream
/// wants them all.
constexpr size_t MAX_PENDING_LOG = 20000;
/// How long a run's reports may wait for the next batch. Short enough to read
/// as live, long enough that a busy logpoint is a few events a second rather
/// than one per yield.
constexpr std::chrono::milliseconds LOG_FLUSH_INTERVAL{50};

} // namespace

uint32_t Engine::set_logpoint(Logpoint lp) {
    uint32_t id = 0;
    submit_void([this, &lp, &id](Spectrum&) {
        if (lp.id == 0) {
            lp.id = next_logpoint_id_++;
        }
        id = lp.id;
        bool replaced = false;
        for (Logpoint& existing : logpoints_) {
            if (existing.id == lp.id) {
                // An edit keeps the count, as a watchpoint's does.
                lp.hits = existing.hits;
                existing = lp;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            logpoints_.push_back(lp);
        }
        arm_logpoints();
    });
    return id;
}

bool Engine::clear_logpoint(uint32_t id) {
    bool any = false;
    submit_void([this, id, &any](Spectrum&) {
        for (size_t i = logpoints_.size(); i-- > 0;) {
            if (id == 0 || logpoints_[i].id == id) {
                logpoints_.erase(logpoints_.begin() + std::ptrdiff_t(i));
                any = true;
            }
        }
        arm_logpoints();
    });
    return any;
}

std::vector<Logpoint> Engine::logpoints() {
    return submit<std::vector<Logpoint>>([this](Spectrum&) { return logpoints_; });
}

void Engine::arm_logpoints() {
    if (logpoints_.empty()) {
        logpoint_at_.reset();
        return;
    }
    logpoint_at_ = std::make_unique<uint8_t[]>(0x10000);
    for (const Logpoint& lp : logpoints_) {
        logpoint_at_[lp.addr] = 1;
    }
}

void Engine::note_logpoints(Spectrum& m) {
    const uint16_t pc = m.registers().pc;
    for (Logpoint& lp : logpoints_) {
        if (lp.addr != pc) {
            continue;
        }
        lp.hits++;
        if (pending_log_.size() >= MAX_PENDING_LOG) {
            log_dropped_++;
            continue;
        }
        LogLine line;
        line.id = lp.id;
        line.pc = pc;
        line.text = format_log_message(lp.message, m);
        pending_log_.push_back(std::move(line));
    }
}

void Engine::flush_log(bool now) {
    if (pending_log_.empty() && log_dropped_ == 0) {
        return;
    }
    const auto t = std::chrono::steady_clock::now();
    if (!now && t - last_log_flush_ < LOG_FLUSH_INTERVAL) {
        return;
    }
    last_log_flush_ = t;
    std::vector<LogLine> lines;
    lines.swap(pending_log_);
    const uint64_t dropped = log_dropped_;
    log_dropped_ = 0;
    std::vector<LogHandler> handlers;
    {
        std::lock_guard<std::mutex> lock(log_handlers_mutex_);
        handlers = log_handlers_;
    }
    for (const LogHandler& handler : handlers) {
        handler(lines, dropped);
    }
}

uint32_t Engine::set_watchpoint(Watchpoint w) {
    if (w.length == 0) {
        w.length = 1;
    }
    w.hits = 0;
    uint32_t id = 0;
    submit_void([this, w, &id](Spectrum& m) {
        Watchpoint copy = w;
        if (copy.id == 0) {
            copy.id = next_watchpoint_id_++;
        }
        bool replaced = false;
        for (Watchpoint& existing : watchpoints_) {
            if (existing.id == copy.id) {
                // An edit keeps the hit count: it is the same watchpoint
                // being adjusted, not a new one.
                copy.hits = existing.hits;
                existing = copy;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            watchpoints_.push_back(copy);
            if (copy.id >= next_watchpoint_id_) {
                next_watchpoint_id_ = copy.id + 1;
            }
        }
        id = copy.id;
        arm_watchpoints(m);
    });
    return id;
}

bool Engine::clear_watchpoint(uint32_t id) {
    bool removed = false;
    submit_void([this, id, &removed](Spectrum& m) {
        if (id == 0) {
            removed = !watchpoints_.empty();
            watchpoints_.clear();
        } else {
            for (size_t i = 0; i < watchpoints_.size(); i++) {
                if (watchpoints_[i].id == id) {
                    watchpoints_.erase(watchpoints_.begin() + long(i));
                    removed = true;
                    break;
                }
            }
        }
        arm_watchpoints(m);
    });
    return removed;
}

std::vector<Watchpoint> Engine::watchpoints() {
    return submit<std::vector<Watchpoint>>([this](Spectrum& m) {
        (void)m;
        return watchpoints_;
    });
}

void Engine::arm_watchpoints(Spectrum& m) {
    std::vector<uint8_t> flags;
    for (const Watchpoint& w : watchpoints_) {
        if (!w.enabled || (!w.on_write && !w.on_read)) {
            continue;
        }
        if (flags.empty()) {
            flags.assign(WATCH_ADDRESSES, 0);
        }
        uint8_t bits = 0;
        if (w.on_write) {
            bits |= WATCH_WRITE;
            if (w.on_change) {
                bits |= WATCH_ON_CHANGE;
            }
        }
        if (w.on_read) {
            bits |= WATCH_READ;
        }
        for (uint32_t i = 0; i < w.length; i++) {
            flags[uint16_t(w.addr + i)] |= bits;
        }
    }
    // A second pass for the watchpoints that want EVERY write, not only the
    // ones that change something: where two watchpoints overlap, the machine
    // has one flag byte to answer both, and it has to be the one that reports
    // more. The stricter of the two then filters its own hits in
    // watch_stop_wanted.
    for (const Watchpoint& w : watchpoints_) {
        if (!w.enabled || !w.on_write || w.on_change) {
            continue;
        }
        for (uint32_t i = 0; i < w.length; i++) {
            flags[uint16_t(w.addr + i)] &= uint8_t(~WATCH_ON_CHANGE);
        }
    }
    m.set_watch_flags(std::move(flags));
}

Watchpoint* Engine::watch_wanted(const WatchHit& hit) {
    for (Watchpoint& w : watchpoints_) {
        if (!w.enabled || hit.addr < w.addr || hit.addr >= uint32_t(w.addr) + w.length) {
            continue;
        }
        if (hit.write ? !w.on_write : !w.on_read) {
            continue;
        }
        // Checked here as well as on the bus: two watchpoints over one byte
        // share a flag, so the machine reports what the laxer of them wants
        // and the stricter filters its own hits out again.
        if (hit.write && w.on_change && hit.old_value == hit.new_value) {
            continue;
        }
        if (w.test == Watchpoint::Test::Equals && hit.new_value != w.value) {
            continue;
        }
        if (w.test == Watchpoint::Test::NotEquals && hit.new_value == w.value) {
            continue;
        }
        return &w;
    }
    return nullptr;
}

bool Engine::watch_stop_wanted(Spectrum& m) {
    const WatchHit hit = m.watch_hit;
    m.watch_hit = WatchHit(); // consumed, whatever is decided about it
    Watchpoint* w = watch_wanted(hit);
    if (w == nullptr) {
        return false;
    }
    w->hits++;
    watch_stop_ = WatchStop{true,          w->id,          hit.write, hit.addr,
                            hit.old_value, hit.new_value,  hit.pc};
    return true;
}

void Engine::set_breakpoint(uint16_t addr) {
    submit_void([addr](Spectrum& m) { m.breakpoints.insert(addr); });
}

void Engine::clear_breakpoint(uint16_t addr) {
    submit_void([addr](Spectrum& m) { m.breakpoints.erase(addr); });
}

std::vector<uint8_t> Engine::read_memory(uint16_t addr, size_t length) {
    return submit<std::vector<uint8_t>>(
        [addr, length](Spectrum& m) { return m.read_memory(addr, length); });
}

void Engine::write_memory(uint16_t addr, std::vector<uint8_t> data) {
    // A poke into the display file changes the picture without moving the
    // beam, and on a stopped machine nothing else is going to move it either
    // -- so without the flag the publish would decide nothing had changed and
    // leave the old frame out there. Set before the write, since the publish
    // that shows it is part of the same job.
    screen_dirty_.store(true);
    submit_void([this, addr, data = std::move(data)](Spectrum& m) {
#if ZX_REWIND
        RewindInput input;
        input.kind = RewindInputKind::Memory;
        input.addr = addr;
        input.bytes = data;
        history_.record(m, std::move(input));
#else
        m.write_memory(addr, data.data(), data.size());
#endif
        // In the job, so that a caller who pokes and then reads the screen is
        // guaranteed to see the poke -- see set_raster_view for why the
        // publish actor_loop does after the job is not enough.
        publish_screen();
    });
}

Registers Engine::registers() {
    return submit<Registers>([](Spectrum& m) { return m.registers(); });
}

Registers Engine::set_registers(Registers r) {
    Registers out = submit<Registers>([this, r](Spectrum& m) {
#if ZX_REWIND
        RewindInput input;
        input.kind = RewindInputKind::Registers;
        input.regs = r;
        history_.record(m, std::move(input));
#else
        (void)this;
        m.set_registers(r);
#endif
        return m.registers();
    });
    if (on_stopped_) {
        on_stopped_(StopReason::Step, out.pc);
    }
    return out;
}

MachineState Engine::state() {
    return submit<MachineState>([this](Spectrum& m) {
        (void)m;
        // Serviced at a run's yields when one is in flight, so this can be
        // asked mid-run and has to say so.
        return snapshot(running_.load());
    });
}

#if ZX_REWIND
void Engine::restart_history(Spectrum& m) {
    history_.start(m);
    std::memcpy(synced_keys_, m.keyboard.rows(), sizeof synced_keys_);
    synced_fast_load_ = m.tape.fast_load();
}

void Engine::after_history_jump(Spectrum& m) {
    // The frame the machine is now in has been seen, whichever way it jumped:
    // otherwise the video recorder and a frame capture would take the replay's
    // last frame as a new one.
    last_frame_seen_ = m.ula.frame_count();
    publish_progress();
    // Published here, in the job, for the reason write_memory gives.
    screen_dirty_.store(true);
    publish_screen();
}

RewindOutcome Engine::rewind(RewindOp op, uint16_t address) {
    RewindOutcome out;
    if (running_.load()) {
        out.error = "the machine is running: pause it before stepping back";
        return out;
    }
    // Pause is how a long search is cancelled, so an old one must not cancel
    // this before it starts.
    pause_requested_.store(false);
    out = submit<RewindOutcome>([this, op, address](Spectrum& m) {
        RewindOutcome o;
        const History::Result r = history_.go_back(m, op, address, [this] {
            return pause_requested_.load();
        });
        o.moved = r.moved;
        o.cancelled = r.cancelled;
        after_history_jump(m);
        o.state = snapshot(false);
        return o;
    }, /*during_run=*/false);
    // Reverse Continue landing on a breakpoint is a breakpoint stop, as its
    // forward twin's would be; everything else is a step.
    StopReason reason = StopReason::Step;
    if (op == RewindOp::ReverseContinue && out.moved) {
        for (uint16_t bp : out.state.breakpoints) {
            if (bp == out.state.pc) {
                reason = StopReason::Breakpoint;
            }
        }
    }
    if (on_stopped_) {
        on_stopped_(reason, out.state.pc);
    }
    return out;
}

RewindOutcome Engine::return_to_live() {
    RewindOutcome out;
    if (running_.load()) {
        out.error = "the machine is running, and a running machine is live";
        return out;
    }
    out = submit<RewindOutcome>([this](Spectrum& m) {
        RewindOutcome o;
        o.moved = !history_.live();
        history_.return_to_live(m);
        after_history_jump(m);
        o.state = snapshot(false);
        return o;
    }, /*during_run=*/false);
    if (on_stopped_) {
        on_stopped_(StopReason::Step, out.state.pc);
    }
    return out;
}

RewindStatus Engine::rewind_status() {
    return submit<RewindStatus>([this](Spectrum& m) {
        RewindStatus s;
        s.live = history_.live();
        s.oldest_hc = history_.oldest_hc();
        s.head_hc = history_.head_hc(m);
        s.position_hc = m.global_hc();
        s.hc_per_frame = m.ula.timing().hc_per_frame();
        s.checkpoints = history_.checkpoint_count();
        s.bytes = history_.bytes();
        return s;
    });
}
#endif

void Engine::start_profile() {
    submit_void([this](Spectrum& m) {
        profile_.clear();
        profile_start_frame_ = m.ula.frame_count();
        profile_end_frame_ = profile_start_frame_;
        m.profile = &profile_;
    });
}

void Engine::stop_profile() {
    submit_void([this](Spectrum& m) {
        if (m.profile != nullptr) {
            profile_end_frame_ = m.ula.frame_count();
            m.profile = nullptr;
        }
    });
}

ProfileSnapshot Engine::profile_snapshot() {
    return submit<ProfileSnapshot>([this](Spectrum& m) {
        ProfileSnapshot s;
        s.active = m.profile != nullptr;
        const uint64_t end = s.active ? m.ula.frame_count() : profile_end_frame_;
        s.frames = end - profile_start_frame_;
        s.instructions = profile_.instructions();
        s.interrupts = profile_.interrupts();
        s.interrupt_half_clocks = profile_.interrupt_half_clocks();
        s.total_half_clocks = profile_.total_half_clocks();
        s.idle_half_clocks = profile_.idle_total_half_clocks();
        s.frame_half_clocks = m.ula.timing().hc_per_frame();
        for (size_t i = 0; i < Profile::ADDRESSES; i++) {
            const uint16_t addr = uint16_t(i);
            if (profile_.hits(addr) == 0) {
                continue;
            }
            ProfileSnapshot::Entry e;
            e.addr = addr;
            e.hits = profile_.hits(addr);
            e.half_clocks = profile_.half_clocks(addr);
            e.idle_half_clocks = profile_.idle_half_clocks(addr);
            s.entries.push_back(e);
        }
        s.call_nodes = profile_.call_nodes();
        s.periods = profile_.summarize(PROFILE_STRIP_ENTRIES);
        return s;
    });
}

void Engine::set_profile_options(ProfileOptions options) {
    submit_void([this, options = std::move(options)](Spectrum& m) {
        (void)m;
        profile_.set_idle_map(options.idle_map);
        profile_.set_period_marker(options.period_marker);
    });
}

TraceStatus Engine::trace_snapshot() const {
    TraceStatus s;
    if (!trace_) {
        return s;
    }
    s.active = trace_->active();
    s.waiting = trace_->waiting();
    s.path = trace_->path();
    s.rows = trace_->rows();
    s.limit = trace_->options().limit;
    s.watching = trace_->options().watch != TRACE_NO_WATCH;
    s.watch = uint16_t(trace_->options().watch);
    s.has_start_pc = trace_->options().start_pc != TRACE_NO_PC;
    s.start_pc = uint16_t(trace_->options().start_pc);
    s.has_start_tstate = trace_->options().start_tstate != TRACE_NO_TSTATE;
    s.start_tstate = trace_->options().start_tstate;
    // From the capture rather than from its options: a stop_trace(pc) aimed at
    // an already-running capture changes this and nothing else.
    const uint32_t stop_pc = trace_->stop_pc();
    s.has_stop_pc = stop_pc != TRACE_NO_PC;
    s.stop_pc = uint16_t(stop_pc);
    s.extra = trace_->options().extra;
    s.ula = trace_->options().ula;
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

TraceStatus Engine::stop_trace(uint16_t pc) {
    // No handover and no wait: the lock is only what keeps the capture alive
    // across the call, exactly as trace_status()' is, and the address itself
    // goes into an atomic the recording thread reads each half-clock.
    std::lock_guard<std::mutex> lock(trace_mutex_);
    if (trace_ && trace_->active()) {
        trace_->set_stop_pc(pc);
    }
    return trace_snapshot();
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
    post([](Spectrum&) {});
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
    post([](Spectrum&) {});
    std::unique_lock<std::mutex> lock(tape_mutex_);
    tape_cv_.wait(lock, [this, wanted] { return tape_applied_ >= wanted; });
}

void Engine::service_queue() {
    for (;;) {
        std::function<void(Spectrum&)> job;
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
#if ZX_REWIND
        // Each one an input, so a replay plays the tape as the run did.
        RewindInput input;
        const bool fast_load = tape_fast_load_.load();
        if (fast_load != synced_fast_load_) {
            synced_fast_load_ = fast_load;
            input.kind = RewindInputKind::TapeFastLoad;
            input.value = fast_load ? 1 : 0;
            history_.record(machine_, input);
        }
        input.value = 0;
        if (pending_tape_ == TapeCommand::Play) {
            input.kind = RewindInputKind::TapePlay;
            history_.record(machine_, input);
        } else if (pending_tape_ == TapeCommand::Stop) {
            input.kind = RewindInputKind::TapeStop;
            history_.record(machine_, input);
        } else if (pending_tape_ == TapeCommand::Rewind) {
            input.kind = RewindInputKind::TapeRewind;
            history_.record(machine_, input);
        } else if (pending_tape_ == TapeCommand::Eject) {
            machine_.tape.eject();
            restart_history(machine_);
        } else if (pending_tape_ == TapeCommand::Seek) {
            input.kind = RewindInputKind::TapeSeek;
            input.value = pending_tape_block_;
            history_.record(machine_, input);
        }
#else
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
#endif
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
