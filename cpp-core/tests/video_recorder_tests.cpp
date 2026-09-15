// VideoRecorder fed through an ordinary file instead of an ffmpeg pipe: the
// bytes that reach the sink are the frames, in order, and nothing else.

#include "test_main.h"
#include "video_recorder.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace zx;

namespace {

constexpr size_t FRAME_BYTES = 64;

std::vector<uint8_t> frame_of(uint8_t fill, size_t size = FRAME_BYTES) {
    return std::vector<uint8_t>(size, fill);
}

/// fopen, spelt the way MSVC insists on: it deprecates the plain one and this
/// build treats warnings as errors.
std::FILE* open_file(const char* path, const char* mode) {
#ifdef _WIN32
    std::FILE* f = nullptr;
    return fopen_s(&f, path, mode) == 0 ? f : nullptr;
#else
    return std::fopen(path, mode);
#endif
}

std::vector<uint8_t> read_all(const std::string& path) {
    std::vector<uint8_t> out;
    std::FILE* f = open_file(path.c_str(), "rb");
    if (f == nullptr) {
        return out;
    }
    uint8_t buffer[256];
    size_t n;
    while ((n = std::fread(buffer, 1, sizeof buffer, f)) != 0) {
        out.insert(out.end(), buffer, buffer + n);
    }
    std::fclose(f);
    return out;
}

const char* PATH = "video_recorder_test.raw";

} // namespace

TEST(frames_reach_the_sink_in_order) {
    VideoRecorder rec;
    rec.start(open_file(PATH, "wb"), std::fclose, PATH, FRAME_BYTES, 0);
    CHECK(rec.active());
    rec.push(frame_of(1));
    rec.push(frame_of(2));
    rec.push(frame_of(3));
    const VideoStatus s = rec.stop();
    CHECK(!s.active);
    CHECK_EQ(s.frames, uint64_t(3));
    CHECK_EQ(s.dropped, uint64_t(0));
    CHECK_EQ(s.exit_code, 0);
    CHECK(s.error.empty());
    CHECK_EQ(s.path, std::string(PATH));

    const std::vector<uint8_t> bytes = read_all(PATH);
    CHECK_EQ(bytes.size(), FRAME_BYTES * 3);
    CHECK_EQ(int(bytes[0]), 1);
    CHECK_EQ(int(bytes[FRAME_BYTES]), 2);
    CHECK_EQ(int(bytes[FRAME_BYTES * 2]), 3);
    std::remove(PATH);
}

TEST(a_frame_of_the_wrong_size_is_dropped_not_written) {
    VideoRecorder rec;
    rec.start(open_file(PATH, "wb"), std::fclose, PATH, FRAME_BYTES, 0);
    rec.push(frame_of(1));
    rec.push(frame_of(2, FRAME_BYTES + 1));
    const VideoStatus s = rec.stop();
    CHECK_EQ(s.frames, uint64_t(1));
    CHECK_EQ(s.dropped, uint64_t(1));
    CHECK_EQ(read_all(PATH).size(), FRAME_BYTES);
    std::remove(PATH);
}

TEST(a_limit_stops_the_recording_by_itself_and_status_finalises_it) {
    VideoRecorder rec;
    rec.start(open_file(PATH, "wb"), std::fclose, PATH, FRAME_BYTES, 2);
    rec.push(frame_of(1));
    CHECK(rec.active());
    rec.push(frame_of(2));
    // Full: no longer wants frames, and a third is simply not taken.
    CHECK(!rec.active());
    rec.push(frame_of(3));

    // status() -- not stop() -- is enough to close the file.
    const VideoStatus s = rec.status();
    CHECK(!s.active);
    CHECK_EQ(s.frames, uint64_t(2));
    CHECK_EQ(s.dropped, uint64_t(0));
    CHECK_EQ(s.limit, uint64_t(2));
    CHECK_EQ(read_all(PATH).size(), FRAME_BYTES * 2);

    // ...and a stop afterwards reports the same, without disturbing it.
    const VideoStatus again = rec.stop();
    CHECK_EQ(again.frames, uint64_t(2));
    CHECK_EQ(again.exit_code, 0);
    std::remove(PATH);
}

TEST(nothing_recording_is_a_quiet_stop) {
    VideoRecorder rec;
    CHECK(!rec.active());
    rec.push(frame_of(1)); // ignored
    const VideoStatus s = rec.stop();
    CHECK(!s.active);
    CHECK_EQ(s.frames, uint64_t(0));
    CHECK(s.path.empty());
}

TEST(starting_again_replaces_the_recording_in_progress) {
    const char* second = "video_recorder_test_2.raw";
    VideoRecorder rec;
    rec.start(open_file(PATH, "wb"), std::fclose, PATH, FRAME_BYTES, 0);
    rec.push(frame_of(1));
    rec.start(open_file(second, "wb"), std::fclose, second, FRAME_BYTES, 0);
    rec.push(frame_of(2));
    rec.push(frame_of(3));
    const VideoStatus s = rec.stop();
    CHECK_EQ(s.path, std::string(second));
    CHECK_EQ(s.frames, uint64_t(2));
    CHECK_EQ(read_all(PATH).size(), FRAME_BYTES);
    CHECK_EQ(read_all(second).size(), FRAME_BYTES * 2);
    std::remove(PATH);
    std::remove(second);
}

RUN_TESTS()
