#include "video_recorder.h"

namespace zx {

VideoRecorder::~VideoRecorder() {
    stop();
}

void VideoRecorder::start(std::FILE* sink, int (*close)(std::FILE*), std::string path,
                          size_t frame_bytes, uint64_t limit) {
    std::lock_guard<std::mutex> lifecycle(lifecycle_mutex_);
    end_recording();
    finish();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        sink_ = sink;
        close_ = close;
        frame_bytes_ = frame_bytes;
        queue_.clear();
        finishing_ = false;
        status_ = VideoStatus{};
        status_.active = true;
        status_.path = std::move(path);
        status_.limit = limit;
        active_.store(true, std::memory_order_relaxed);
    }
    writer_ = std::thread([this] { writer_loop(); });
}

void VideoRecorder::push(const std::vector<uint8_t>& rgb) {
    if (!active_.load(std::memory_order_relaxed)) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!status_.active || finishing_) {
        return;
    }
    if (rgb.size() != frame_bytes_) {
        status_.dropped++;
        return;
    }
    if (queue_.size() >= MAX_QUEUED_FRAMES) {
        status_.dropped++;
        return;
    }
    queue_.push_back(rgb);
    status_.frames++;
    if (status_.limit != 0 && status_.frames >= status_.limit) {
        // Enough: nothing more is accepted, and the writer finishes once it
        // has written what is queued. The sink is closed -- which for ffmpeg
        // is what finalises the file -- by the next stop() or status().
        active_.store(false, std::memory_order_relaxed);
        status_.active = false;
    }
    cv_.notify_one();
}

void VideoRecorder::writer_loop() {
    for (;;) {
        std::vector<uint8_t> frame;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this] { return !queue_.empty() || !status_.active; });
            if (queue_.empty()) {
                return;
            }
            frame = std::move(queue_.front());
            queue_.pop_front();
        }
        if (sink_ != nullptr && std::fwrite(frame.data(), 1, frame.size(), sink_) != frame.size()) {
            // The far end has gone (ffmpeg died, or refused the stream).
            // Nothing more can be written; stop accepting and let the close
            // report whatever the encoder said about why.
            std::lock_guard<std::mutex> lock(mutex_);
            status_.error = "writing to the encoder failed part-way through";
            status_.active = false;
            active_.store(false, std::memory_order_relaxed);
            return;
        }
    }
}

void VideoRecorder::end_recording() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        finishing_ = true;
        status_.active = false;
        active_.store(false, std::memory_order_relaxed);
    }
    cv_.notify_all();
}

void VideoRecorder::finish() {
    if (writer_.joinable()) {
        writer_.join();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (sink_ != nullptr) {
        std::fflush(sink_);
        status_.exit_code = close_ != nullptr ? close_(sink_) : std::fclose(sink_);
        sink_ = nullptr;
        if (status_.exit_code != 0 && status_.error.empty()) {
            status_.error = "the encoder exited with status " + std::to_string(status_.exit_code);
        }
    }
    queue_.clear();
}

VideoStatus VideoRecorder::stop() {
    std::lock_guard<std::mutex> lifecycle(lifecycle_mutex_);
    end_recording();
    finish();
    std::lock_guard<std::mutex> lock(mutex_);
    return status_;
}

VideoStatus VideoRecorder::status() {
    std::lock_guard<std::mutex> lifecycle(lifecycle_mutex_);
    bool ended_by_itself = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ended_by_itself = !status_.active && sink_ != nullptr;
    }
    if (ended_by_itself) {
        // Reached its limit, or the writer gave up: the frames are all
        // queued or written, and closing the sink is what finishes the file.
        finish();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    return status_;
}

} // namespace zx
