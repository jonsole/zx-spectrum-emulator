// Throughput benchmark for the layers ABOVE the Z80 core.
//
// tests/bench.cpp measures the CPU on flat memory with no ULA and no engine,
// which is the right number for judging the dispatch loop but says nothing
// about what a client actually experiences. This measures the same thing the
// user does: emulated Spectrum seconds per wall-clock second, through the
// full machine and then through the Engine's run loop.
//
// Reported as a realtime multiple. 1.00x means the emulator keeps up with a
// real 48K exactly; below that it runs slow.
//
// Build RelWithDebInfo or Release. A Debug number here is meaningless.

#include "engine.h"
#include "spectrum.h"
#include "ula.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

using namespace zx;

namespace {

/// Half-clocks a real 48K Spectrum issues per second (3.5MHz Z80, 2 halves).
constexpr double REALTIME_HC_PER_SEC = 7'000'000.0;

bool load_rom_into(Spectrum48K& m) {
    std::ifstream f(std::string(ZX_PROJECT_ROOT) + "/roms/48.rom", std::ios::binary);
    if (!f) {
        return false;
    }
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
    return m.load_rom(data.data(), data.size()).empty();
}

void report(const char* name, double half_clocks, double seconds) {
    const double per_sec = half_clocks / seconds;
    std::printf("  %-34s %8.1f M half-clocks/s   %6.2fx realtime\n", name, per_sec / 1e6,
                per_sec / REALTIME_HC_PER_SEC);
}

/// The bare machine: CPU + ULA + bus decode, clocked directly, no engine.
void bench_machine(bool have_rom) {
    Spectrum48K m;
    if (have_rom) {
        load_rom_into(m);
    }
    // Boot far enough in that the ROM is doing real work (past the RAM check)
    // rather than sitting in its startup loop.
    for (int i = 0; i < 200; i++) {
        m.run_frame();
    }

    constexpr uint64_t FRAMES = 500; // 10 emulated seconds
    auto t0 = std::chrono::steady_clock::now();
    for (uint64_t i = 0; i < FRAMES; i++) {
        m.run_frame();
    }
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    report("machine (CPU+ULA, direct clock)", double(FRAMES) * HC_PER_FRAME, seconds);
}

/// Through Engine::run() -- the path a DAP `continue` actually takes,
/// including its per-yield key sync and screen publish.
void bench_engine(bool have_rom, Speed speed, const char* label) {
    Engine engine;
    if (have_rom) {
        std::ifstream f(std::string(ZX_PROJECT_ROOT) + "/roms/48.rom", std::ios::binary);
        std::vector<uint8_t> data((std::istreambuf_iterator<char>(f)),
                                  std::istreambuf_iterator<char>());
        engine.load_rom(std::move(data));
    }
    engine.set_speed(speed);
    engine.reset();

    std::thread runner([&engine] { engine.run(); });
    std::this_thread::sleep_for(std::chrono::seconds(2)); // let it get going

    // NOT engine.state(): that is queued, and a run owns the actor thread
    // until it stops, so it would block here forever.
    const uint64_t start_hc = engine.emulated_half_clocks();
    auto t0 = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::seconds(3));
    const uint64_t end_hc = engine.emulated_half_clocks();
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    engine.pause();
    runner.join();
    report(label, double(end_hc - start_hc), seconds);
}

} // namespace

int main() {
    Spectrum48K probe;
    const bool have_rom = load_rom_into(probe);
    std::printf("Machine + engine throughput (1.00x realtime == keeps up with a real 48K)\n");
    if (!have_rom) {
        std::printf("  (roms/48.rom not present -- running an empty machine, numbers are\n"
                    "   still meaningful for the emulation loop itself)\n");
    }
    std::printf("\n");

    bench_machine(have_rom);
    bench_engine(have_rom, Speed::Uncapped, "engine run(), uncapped");
    // The default. Should land on 1.00x -- that IS the pass condition.
    bench_engine(have_rom, Speed::Realtime, "engine run(), realtime (default)");
    return 0;
}
