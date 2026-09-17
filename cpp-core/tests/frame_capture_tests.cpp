// Engine::capture_frames: frames picked out of a run, and out of a stopped
// machine driven forward for the purpose. No ROM is loaded, so the CPU
// executes a memory full of NOPs -- which is all it takes to turn frames over.

#include "engine.h"
#include "test_main.h"
#include "ula.h"

#include <chrono>
#include <thread>

using namespace zx;

namespace {

constexpr size_t FRAME_BYTES = size_t(FULL_WIDTH) * FULL_HEIGHT * 3;
constexpr auto PLENTY = std::chrono::seconds(20);

} // namespace

TEST(a_stopped_machine_is_driven_forward_and_left_stopped) {
    Engine engine;
    engine.set_speed(Speed::Uncapped);
    const uint64_t before = engine.state().frame_count;

    const std::vector<CapturedFrame> frames = engine.capture_frames(3, 2, PLENTY);
    CHECK_EQ(frames.size(), size_t(3));
    for (const CapturedFrame& f : frames) {
        CHECK_EQ(f.rgb.size(), FRAME_BYTES);
    }
    // The first capture is the first boundary passed, then every second one.
    CHECK_EQ(frames[0].frame_number, before + 1);
    CHECK_EQ(frames[1].frame_number, before + 3);
    CHECK_EQ(frames[2].frame_number, before + 5);
    // Stopped where the last capture landed: no further than it had to go.
    CHECK(!engine.running());
    CHECK_EQ(engine.state().frame_count, before + 5);
}

TEST(a_running_machine_is_sampled_without_being_stopped) {
    Engine engine;
    engine.set_speed(Speed::Uncapped);
    std::thread runner([&engine] { engine.run(); });
    // Give the run a moment to actually be running.
    for (int i = 0; i < 200 && !engine.running(); i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(engine.running());
    // And a state asked for mid-run says so -- it is what get_state reports.
    CHECK(engine.state().running);

    const std::vector<CapturedFrame> frames = engine.capture_frames(4, 1, PLENTY);
    CHECK_EQ(frames.size(), size_t(4));
    for (size_t i = 1; i < frames.size(); i++) {
        CHECK_EQ(frames[i].frame_number, frames[i - 1].frame_number + 1);
    }
    CHECK(engine.running());

    engine.pause();
    runner.join();
    CHECK(!engine.running());
    CHECK(!engine.state().running);
}

TEST(a_capture_nobody_fills_times_out_with_nothing) {
    Engine engine;
    // Stopped, and asked for zero frames: nothing to drive, nothing to wait
    // for -- the degenerate case must not hang.
    const std::vector<CapturedFrame> none = engine.capture_frames(0, 1, PLENTY);
    CHECK_EQ(none.size(), size_t(0));
}

RUN_TESTS()
