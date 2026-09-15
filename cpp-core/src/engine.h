#pragma once
// Engine: owns the one live Spectrum and serialises access to it.
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

#include "snapshot.h"
#include "spectrum.h"
#include "video_recorder.h"

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
    /// Which Spectrum the machine is being.
    Model model = Model::Spectrum48;
    /// The 128K's paging register (the last OUT to 0x7FFD); 0 on a 48K.
    uint8_t paging = 0;
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

/// What a profile has counted so far -- see Engine::profile_snapshot. Only the
/// addresses that ran at all, so a caller never walks 64K of zeroes.
struct ProfileSnapshot {
    /// Still counting. A stopped profile keeps what it counted.
    bool active = false;
    /// Video frames that passed while it was counting, so a caller can quote
    /// a cost per frame -- what decides whether a game keeps its frame rate.
    uint64_t frames = 0;
    uint64_t instructions = 0;
    uint64_t interrupts = 0;
    uint64_t interrupt_half_clocks = 0;
    uint64_t total_half_clocks = 0;

    struct Entry {
        uint16_t addr = 0;
        uint64_t hits = 0;
        uint64_t half_clocks = 0;
    };
    /// In address order.
    std::vector<Entry> entries;
    /// The calling-context tree, root first, each node after its parent --
    /// see Profile::CallNode.
    std::vector<Profile::CallNode> call_nodes;
};

/// One completed frame picked out of a run -- see Engine::capture_frames.
struct CapturedFrame {
    /// The ULA's frame counter when this frame was completed, so a caller
    /// can tell how far apart two captures are in emulated time.
    uint64_t frame_number = 0;
    /// RGB, FULL_WIDTH x FULL_HEIGHT, border included -- what screen() gives.
    std::vector<uint8_t> rgb;
};

/// How a video is to be recorded -- see Engine::start_video.
struct VideoOptions {
    std::string path = "screen.mp4";
    /// Emulated frames to record before the recording stops itself, or 0 to
    /// record until stop_video.
    uint64_t frames = 0;
    /// Integer pixel scaling. 2 (the default) doubles the 352x312 canvas to
    /// 704x624, which plays crisply where a 352-wide video would be smeared
    /// by every player's own upscaler.
    uint32_t scale = 2;
};

/// How a STOPPED machine's screen is drawn. None of it applies while running:
/// a run moves the beam faster than anything can look at it, and what a viewer
/// wants there is one whole stable frame.
///
/// The three are one view of the same thing -- where the beam is and what it
/// has left to do -- which is why they are set together rather than through
/// three unrelated switches.
struct RasterView {
    /// A dashed line across the raster line the beam is on, and a tick at the
    /// dot itself.
    bool marker = true;
    /// Compose the picture the way a CRT has it at this instant: this frame's
    /// drawing down to the beam, the previous frame beyond it. Off means the
    /// last COMPLETED frame, which is what a running machine always shows.
    bool in_progress = true;
    /// Pick out the display bytes written since the beam last passed them --
    /// the changes that are in memory but not yet on the picture -- by dimming
    /// everything else. Off by default, being a specialised view rather than a
    /// costly one: the map behind it is kept whether or not this is on.
    bool pending = false;
};

/// What the VS Code graphics panel is pointed at -- see docs/vscode-debugging.md.
///
/// Unlike RasterView, none of this changes anything the emulator draws. The
/// Engine holds it purely as the one place an MCP client and a DAP client can
/// both see: MCP sets it, the DAP server turns each change into an event, and
/// the extension moves its panel. It lives here rather than in the extension
/// because MCP and DAP are separate front-ends onto this object and have no
/// other way to reach each other.
///
/// The traffic is one-way. The panel's own controls are not reflected back
/// here, so after a hand edit this holds what was last ASKED for rather than
/// what is on screen. That is deliberate: a panel that wrote back would turn
/// every drag of the width box into a round trip, and there is nothing on this
/// side that wants to know.
///
/// `address` is passed through as text rather than resolved here. The panel
/// resolves what it is given the same way it resolves what is typed into it,
/// so "sprite_000+4" reaches the symbol table by the route that already
/// exists.
struct GraphicsView {
    /// memory | file | selection.
    std::string source = "memory";
    /// A number in any of the usual forms, or a symbol name, optionally
    /// displaced: "16384", "$4000", "0x4000", "4000h", "sprite_000+4".
    std::string address = "$4000";
    /// Read instead of memory when `source` is "file".
    std::string file;
    /// Bytes to skip at the start of a file or a parsed selection -- how a
    /// byte range inside a larger file is addressed, since only the memory
    /// source has an `address`. Ignored by source == "memory".
    uint32_t offset = 0;
    /// sprite | font | screen.
    std::string format = "screen";
    /// Bytes across, before any mask interleaving.
    uint32_t width = 2;
    /// Pixel rows per item.
    uint32_t height = 16;
    uint32_t count = 16;
    /// Items per row of the sheet.
    uint32_t columns = 8;
    /// Bytes to skip before EACH item, for data carrying a per-sprite
    /// width/height pair ahead of its bitmap.
    uint32_t header = 0;
    /// The character code of the first item, in "font" format.
    uint32_t first = 32;
    /// none | md (mask then data) | dm (data then mask), interleaved per byte
    /// across a row.
    std::string interleave = "none";
    /// Read a CLEAR mask bit as transparent rather than a set one.
    bool invert_mask = false;
    /// Row 0 of the data is the BOTTOM row of the picture.
    bool flip = false;
    /// 0-15, the ULA's palette with bright as the top bit. Ignored in "screen"
    /// format when the data carries its own attributes.
    uint32_t ink = 0;
    uint32_t paper = 15;
    uint32_t zoom = 3;
    bool grid = true;
    bool labels = true;
    /// Add this to the panel's sheet instead of replacing the sprite being
    /// dialled in -- how a set whose members are different sizes is shown, one
    /// call per sprite.
    ///
    /// An action rather than a setting, and the one field that does NOT merge:
    /// it is cleared on every set, so a pin cannot leak into the next call and
    /// silently turn a correction into another tile.
    bool pin = false;
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

/// Slowest and fastest the realtime multiplier may be set to.
///
/// The bottom end is a thousandth of real speed: one frame takes twenty
/// seconds and the beam creeps down about fifteen scanlines a second, which
/// is slow enough to watch an individual write land ahead of it. That is the
/// whole reason for going below 1x, and there is no point stopping at a
/// speed that is merely slow when the question is which of two things
/// happened first.
///
/// The top is where the host cannot keep up anyway and Uncapped is the honest
/// answer. Clamped rather than rejected: these come off a wire from a UI, and
/// the nearest sensible speed beats an error nobody sees.
constexpr double MIN_SPEED_MULTIPLIER = 0.001;
constexpr double MAX_SPEED_MULTIPLIER = 20.0;

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
    /// Called from whichever thread set the view -- an MCP request thread, in
    /// practice. Same rule as the two above: do not call back into the queue.
    using GraphicsViewHandler = std::function<void(const GraphicsView&, uint64_t version)>;

    Engine();
    ~Engine();

    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    void on_stopped(StoppedHandler h);
    void on_continued(ContinuedHandler h);
    void on_graphics_view(GraphicsViewHandler h);

    // ---- queued: these wait for the actor thread ---------------------------
    /// A 16K image is the 48K ROM, a 32K one the 128K pair. Either can be
    /// loaded whatever the model, ready for a switch to the other.
    std::string load_rom(std::vector<uint8_t> data);
    /// Whether a ROM for `m` has been loaded. What a launch checks before
    /// switching to a model that would otherwise boot into 16K of NOPs.
    bool has_rom(Model m);
    /// Makes the machine a 48K or a 128K, resetting it. RAM and ROMs stay.
    void set_model(Model m);
    Model model();
    /// Loads a .sna or .z80, told apart by the .sna's fixed sizes, and makes
    /// the machine whichever model the file was taken on.
    std::string load_snapshot(std::vector<uint8_t> data);
    /// Captures the machine into `out` as a .sna or .z80 of its current
    /// model. Runs on the emulator thread between instructions, so registers
    /// and RAM are from the same instant even mid-run. Returns "" on success,
    /// else why it could not.
    std::string save_snapshot(std::vector<uint8_t>& out,
                              SnapshotFormat format = SnapshotFormat::Sna);
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
    /// Reads a RAM bank directly, whatever is paged: `offset` is within the
    /// bank's 16K, and the read wraps at its end. How a 128K's other seven
    /// banks are reached from outside without paging them in, which would
    /// change the machine being looked at.
    std::vector<uint8_t> read_bank(uint8_t bank, uint16_t offset, size_t length);
    Registers registers();
    Registers set_registers(Registers r);
    MachineState state();

    /// Starts counting where execution time goes, from zero -- see profile.h.
    /// Queued like everything above, but serviced at a run's yields, so it
    /// starts and stops on a running game without stopping it: get to the
    /// part worth measuring, then start.
    void start_profile();
    /// Stops counting, keeping what was counted for profile_snapshot.
    void stop_profile();
    /// What has been counted, running or stopped. Empty (and inactive) if
    /// profiling has never been started.
    ProfileSnapshot profile_snapshot();

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

    /// How fast realtime runs, as a multiple of a real 48K: 0.5 is half
    /// speed, 2.0 is twice. Ignored while the speed is Uncapped, which is
    /// "as fast as the host manages" and has no rate to scale.
    ///
    /// Not folded into Speed as more enum values because the useful set is
    /// open-ended -- somebody debugging a raster effect wants a tenth, and
    /// somebody skipping a loading screen wants five times -- and because
    /// what pacing needs is the number itself.
    void set_speed_multiplier(double multiplier) {
        if (multiplier < MIN_SPEED_MULTIPLIER) {
            multiplier = MIN_SPEED_MULTIPLIER;
        } else if (multiplier > MAX_SPEED_MULTIPLIER) {
            multiplier = MAX_SPEED_MULTIPLIER;
        }
        speed_multiplier_.store(multiplier);
        // Pacing measures from an origin; leaving it alone would make the new
        // rate apply to time already spent and jump the machine forwards or
        // stall it while the debt is paid off.
        pace_dirty_.store(true);
    }
    double speed_multiplier() const { return speed_multiplier_.load(); }

    /// Running slowly enough that the beam can be watched sweeping the
    /// screen, rather than crossing it faster than a picture can be sent.
    ///
    /// This is what makes the raster annotations worth drawing on a RUNNING
    /// machine: at 1x the beam crosses the whole screen in 20ms and any
    /// picture of it is a smear, but at a tenth of that it sweeps visibly
    /// down the screen and answers the question the annotations exist for --
    /// where is the beam when this happens?
    bool slow_motion() const {
        return speed_.load() == Speed::Realtime && speed_multiplier_.load() < 1.0;
    }

    /// Instructions between the run loops' housekeeping yields -- the pause
    /// check, the key sync and the screen publish.
    ///
    /// Scaled by the speed so the picture is published at roughly the same
    /// WALL-clock rate whatever the machine runs at, which is what makes the
    /// raster marker sweep at a tenth speed instead of jumping between two
    /// positions a frame. Never scaled UP for fast speeds: yielding less
    /// often than the default would make the UI feel less live.
    uint64_t yield_interval() const;
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
    /// Dims the frame and lights each bitmap byte as it is written -- see
    /// Ula::set_write_overlay.
    /// Takes effect on the next completed frame, mid-run included; the flag is
    /// an atomic on the ULA itself, so this needs neither the queue nor a
    /// yield.
    void set_write_overlay(bool on) { machine_.ula.set_write_overlay(on); }
    bool write_overlay() const { return machine_.ula.write_overlay(); }
    /// How far a freshly written byte is lifted out of the dim, 0-100. 100
    /// (the default) is full brightness; lower values stand out less.
    void set_write_overlay_opacity(uint32_t percent) {
        machine_.ula.set_write_overlay_opacity(percent);
    }
    uint32_t write_overlay_opacity() const { return machine_.ula.write_overlay_opacity(); }
    /// How much of the overlay a frame boundary takes off, 0-100. 100 (the
    /// default) leaves only the frame just drawn; lower values trail.
    void set_write_overlay_fade(uint32_t percent) {
        machine_.ula.set_write_overlay_fade(percent);
    }
    uint32_t write_overlay_fade() const { return machine_.ula.write_overlay_fade(); }
    /// Where the VS Code graphics panel is pointed -- see GraphicsView. Sets
    /// nothing in the machine, so unlike every other setter here it neither
    /// queues nor waits: it stores the view and hands it straight to whoever
    /// is listening, which works mid-run as readily as at a breakpoint.
    ///
    /// `version` counts changes and starts at 0, so a panel opening later can
    /// tell "nobody has asked for anything" from "asked for the defaults" --
    /// without which every panel would open onto $4000 whatever its own last
    /// state was.
    void set_graphics_view(const GraphicsView& v);
    GraphicsView graphics_view(uint64_t* version = nullptr) const;

    /// How a stopped machine's screen is drawn -- see RasterView. Applies from
    /// the next publish, mid-session included; these are atomics, so it needs
    /// neither the queue nor a yield.
    void set_raster_view(const RasterView& v);
    RasterView raster_view() const;
    /// Latest rendered frame (RGB, border included). Never blocks on the CPU.
    std::vector<uint8_t> screen();

    // ---- frames: one completed picture per frame boundary ------------------
    /// Collects `count` completed frames, one every `every` frame boundaries,
    /// each exactly as the ULA finished it -- with the write overlay baked in
    /// if that is on, and without the stopped-machine annotations, which
    /// describe a beam position a completed frame does not have.
    ///
    /// On a RUNNING machine the frames are picked out of the run as it goes,
    /// which neither pauses nor disturbs it; the call returns once the last
    /// has been taken or `timeout` has passed, whichever is first, with
    /// whatever was collected. On a STOPPED one the machine is driven forward
    /// itself, frame by frame and as fast as the host manages, and left
    /// stopped where the last capture landed -- the same as stepping, and
    /// announced as a step so a debugger refreshes.
    std::vector<CapturedFrame> capture_frames(uint32_t count, uint32_t every,
                                              std::chrono::milliseconds timeout);
    /// Starts recording every completed frame to `options.path` through an
    /// ffmpeg process (see set_ffmpeg), replacing any recording in progress.
    /// Returns "" or why it could not start. Takes effect from the next
    /// frame boundary, mid-run included: the recorder's own flag is what the
    /// emulator thread checks, so this neither queues nor waits.
    std::string start_video(const VideoOptions& options);
    /// Finishes the recording -- drains what is queued and closes the pipe,
    /// which is what makes ffmpeg finalise the file -- and reports on it.
    /// Harmless when nothing is recording.
    VideoStatus stop_video();
    /// What the recording is doing, live. A recording that reached its own
    /// frame limit is finalised here if it has not been already.
    VideoStatus video_status();
    /// The ffmpeg to run: a bare name found on PATH (the default) or a full
    /// path. Only consulted by start_video.
    void set_ffmpeg(std::string command) { ffmpeg_ = std::move(command); }
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
    Spectrum machine_;
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
        std::function<void(Spectrum&)> fn;
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
    std::atomic<double> speed_multiplier_{1.0};
    /// Set when the multiplier changes, so the pacing origin is rebased on
    /// the emulator thread rather than from whichever thread turned the knob.
    std::atomic<bool> pace_dirty_{false};
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
    /// Set when something OTHER than emulation has changed what a publish
    /// would produce -- switching a raster-view option while stopped. Without
    /// it the frame-and-beam check below would see nothing moved and skip the
    /// republish that shows the change.
    std::atomic<bool> screen_dirty_{false};
    std::atomic<bool> raster_marker_{true};
    std::atomic<bool> raster_in_progress_{true};
    std::atomic<bool> raster_pending_{false};
    /// Where the raster marker in screen_snapshot_ was drawn, or ~0 for a
    /// snapshot published without one. Paired with published_frame_ below:
    /// between them they say whether what a re-publish would produce differs
    /// from what is already out there.
    uint32_t published_raster_ = ~uint32_t(0);
    /// Frame number currently in screen_snapshot_, so a re-publish of the same
    /// completed frame can be skipped. Touched only by the actor thread.
    uint64_t published_frame_ = ~uint64_t(0);
    /// When the RGB snapshot was last rebuilt, for the throttle in
    /// publish_screen. Emulator thread only, like the two above.
    std::chrono::steady_clock::time_point last_screen_publish_{};

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

    /// Frame counter as of the last note_frame, so a boundary is seen once.
    /// Emulator thread only.
    uint64_t last_frame_seen_ = 0;
    VideoRecorder video_;
    std::string ffmpeg_ = "ffmpeg";
    /// The frame-capture handover: capture_frames arms a request under the
    /// mutex, the emulator thread fills it at frame boundaries and clears
    /// the flag when it is complete, and the caller waits on the cv for that.
    /// `capture_active_` is checked per frame boundary without the lock, so
    /// an idle machine pays one relaxed load a frame.
    std::mutex capture_mutex_;
    std::condition_variable capture_cv_;
    std::atomic<bool> capture_active_{false};
    uint32_t capture_every_ = 1;
    uint32_t capture_wanted_ = 0;
    /// The earliest frame number the next capture may be taken at, so
    /// `every` is a spacing in frames rather than in boundaries seen.
    uint64_t capture_next_frame_ = 0;
    std::vector<CapturedFrame> capture_frames_;

    /// The profile's counts, kept after it stops so they can still be read,
    /// and the frame counter where counting began and (once stopped) ended.
    /// The machine's `profile` pointer is what says whether it is counting.
    /// Emulator thread only, like everything the queue serves.
    Profile profile_;
    uint64_t profile_start_frame_ = 0;
    uint64_t profile_end_frame_ = 0;

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
    GraphicsViewHandler on_graphics_view_;
    /// Guards graphics_view_ and its version. A mutex rather than atomics
    /// because the view is mostly strings, and it changes when a person asks
    /// for something rather than at emulation rates.
    mutable std::mutex graphics_mutex_;
    GraphicsView graphics_view_;
    uint64_t graphics_version_ = 0;

    void actor_loop();
    /// Runs `fn` on the actor thread and waits for it. `during_run` says
    /// whether the run loop may pick it up at a yield -- see Job.
    template <typename R>
    R submit(std::function<R(Spectrum&)> fn, bool during_run = true);
    void submit_void(std::function<void(Spectrum&)> fn, bool during_run = true);
    /// Queues `fn` without waiting for it -- used only to wake an idle actor
    /// thread, since a request that bypasses the queue still needs SOMETHING
    /// to reach a servicing point.
    void post(std::function<void(Spectrum&)> fn);

    void publish_screen();
    /// Called after every instruction (and T-state step) on the emulator
    /// thread: notices a frame boundary having passed and hands the completed
    /// frame to the video recorder and the frame capture, if either wants
    /// one. One load and a compare when nothing does.
    void note_frame(const Spectrum& m);
    /// Arms a frame capture for note_frame to fill. Any thread.
    void arm_capture(uint32_t count, uint32_t every);
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
