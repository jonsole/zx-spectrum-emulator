#pragma once
// VideoRecorder: turns completed frames into a video file by feeding them,
// raw, to an ffmpeg process over a pipe.
//
// Frames arrive from the emulator thread at every frame boundary (see
// Engine::note_frame) and go out on a writer thread of this object's own.
// The two are decoupled by a bounded queue because ffmpeg's stdin can stall
// -- an encoder that falls behind, a disk that hiccups -- and a stall there
// must not stall the emulator: sound is being generated on that thread in
// real time and a pause in it is audible. A frame that arrives while the
// queue is full is dropped and counted, which the status reports, so a video
// with gaps says so rather than silently running short.
//
// Only the raw-frames-to-a-FILE* part lives here. Which ffmpeg to run and
// with what arguments is the caller's business (Engine::start_video builds
// the command line), and tests hand in an ordinary file instead of a pipe.

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace zx {

/// What a recording is doing, or did. Reported identically while it runs and
/// after it has stopped, so a caller only learns one shape.
struct VideoStatus {
    bool active = false;
    std::string path;
    /// Frames handed to the writer, i.e. what the file will hold.
    uint64_t frames = 0;
    /// Frames that arrived while the queue was full and were not written.
    uint64_t dropped = 0;
    /// Frames the recording was asked to stop itself at, or 0 for none.
    uint64_t limit = 0;
    /// Set once the writer has finished: what ffmpeg (or the file) said on
    /// close. 0 is success; anything else and the file is suspect.
    int exit_code = 0;
    /// Why a recording could not be started or did not finish cleanly, or
    /// empty.
    std::string error;
};

class VideoRecorder {
public:
    VideoRecorder() = default;
    ~VideoRecorder();
    VideoRecorder(const VideoRecorder&) = delete;
    VideoRecorder& operator=(const VideoRecorder&) = delete;

    /// Frames a queue may hold before new ones are dropped. Two seconds of
    /// video: enough to ride out any plausible encoder hiccup, and small
    /// enough (about 60MB at 352x312) not to matter.
    static constexpr size_t MAX_QUEUED_FRAMES = 100;

    /// Starts writing to `sink`, which from here on belongs to the recorder:
    /// `close` is what stop() calls on it once the last frame is out, and its
    /// return value becomes `exit_code`. For a popen'd ffmpeg that is pclose
    /// and the process's exit status; for a test it is fclose and 0.
    ///
    /// `limit` frames, if not 0, stops the recording by itself. Replaces any
    /// recording in progress, stopping that one first. `frame_bytes` is the
    /// size every pushed frame must be -- a frame of any other size is a bug
    /// upstream and is dropped rather than written to corrupt the stream.
    void start(std::FILE* sink, int (*close)(std::FILE*), std::string path, size_t frame_bytes,
               uint64_t limit);

    /// Queues one frame. Emulator thread; cheap when not recording (one
    /// relaxed load) so it can be called at every frame boundary.
    void push(const std::vector<uint8_t>& rgb);

    /// Whether frames are wanted right now. Relaxed: the caller only uses it
    /// to skip the copy, and push() re-checks under the lock.
    bool active() const { return active_.load(std::memory_order_relaxed); }

    /// Finishes: waits for the queue to drain, closes the sink and reports.
    /// Any thread but the writer's own. Harmless when nothing is recording.
    VideoStatus stop();

    /// What the recording is doing. Not const, because a recording that has
    /// ended by itself -- at its limit, or on a write failure -- still has
    /// its sink open, and closing it (which for ffmpeg is what finalises the
    /// file) is done here rather than left until an explicit stop.
    VideoStatus status();

private:
    /// Serialises start/stop/status against each other: each may join the
    /// writer thread, and two joins at once are undefined.
    std::mutex lifecycle_mutex_;
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::thread writer_;
    std::FILE* sink_ = nullptr;
    int (*close_)(std::FILE*) = nullptr;
    std::deque<std::vector<uint8_t>> queue_;
    /// Set while frames are wanted: cleared by stop() and by reaching the
    /// limit, both of which the writer then sees as "drain and finish".
    std::atomic<bool> active_{false};
    /// Set by stop() (and start(), which stops first) so push() refuses
    /// frames from then on; the writer still drains whatever was queued
    /// before it, so a stop loses nothing that had already been accepted.
    bool finishing_ = false;
    size_t frame_bytes_ = 0;
    VideoStatus status_;

    void writer_loop();
    /// Stops accepting frames and tells the writer to drain what it has.
    void end_recording();
    /// Waits for the writer thread and closes the sink. Caller holds
    /// lifecycle_mutex_ and nothing else.
    void finish();
};

} // namespace zx
