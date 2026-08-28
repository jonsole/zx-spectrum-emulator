// Diagnostic, not a test: drives the audio path end to end and writes a WAV
// you can listen to.
//
// It exists because main.cpp is where the servers are normally started, and a
// diagnostic that can stand up the same pieces on its own is the difference
// between "it compiles" and "it makes the right noise".
//
//   beep tone   poke a known square-wave loop, capture a second, report pitch
//   beep rom    boot the real ROM, type BEEP 1,0, capture what BASIC plays
//   beep serve  run the stream server (and the native device) against a live
//               machine, so a client can connect and listen
//
// Writes beep.wav in the working directory for the first two.

#include "audio_device.h"
#include "audio_stream.h"
#include "beeper.h"
#include "engine.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

using namespace zx;

namespace {

constexpr size_t CAPTURE_RING = AUDIO_SAMPLE_RATE * 4;

bool load_rom(Engine& engine) {
    std::ifstream f(std::string(ZX_PROJECT_ROOT) + "/roms/48.rom", std::ios::binary);
    if (!f) {
        return false;
    }
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    return engine.load_rom(std::move(rom)).empty();
}

/// Steps in chunks, draining as it goes. Chunked because the Beeper drops its
/// oldest samples past half a second, and it only publishes between commands.
void run_for(Engine& engine, AudioRing& ring, std::vector<int16_t>& out, int chunks) {
    std::vector<int16_t> block(CAPTURE_RING);
    for (int i = 0; i < chunks; i++) {
        engine.step(20000);
        const size_t n = ring.read(block.data(), block.size());
        out.insert(out.end(), block.begin(), block.begin() + long(n));
    }
}

void write_wav_file(const std::vector<int16_t>& samples, const char* path) {
    const std::vector<uint8_t> wav = encode_wav(samples);
    std::ofstream f(path, std::ios::binary);
    f.write(reinterpret_cast<const char*>(wav.data()), std::streamsize(wav.size()));
    std::printf("wrote %s (%zu samples, %.2fs)\n", path, samples.size(),
                double(samples.size()) / double(AUDIO_SAMPLE_RATE));
}

void report(const std::vector<int16_t>& samples) {
    float rms = 0.0f;
    float peak = 0.0f;
    measure_level(samples, rms, peak);
    std::printf("  samples %zu  rms %.4f  peak %.4f  pitch %.1f Hz\n", samples.size(), rms,
                peak, estimate_frequency_hz(samples));
}

int run_tone() {
    Engine engine;
    std::shared_ptr<AudioRing> ring = engine.add_audio_sink(CAPTURE_RING);

    // The same loop beeper_tests uses: ~1001Hz square via OUT (0xFE),A.
    const std::vector<uint8_t> program = {0xF3, 0x3E, 0x10, 0xD3, 0xFE, 0x06, 0x84,
                                          0x10, 0xFE, 0xEE, 0x10, 0x18, 0xF6};
    engine.write_memory(0x8000, program);
    Registers r = engine.registers();
    r.pc = 0x8000;
    engine.set_registers(r);

    std::vector<int16_t> samples;
    run_for(engine, *ring, samples, 60);
    report(samples);
    write_wav_file(samples, "beep.wav");
    return samples.empty() ? 1 : 0;
}

int run_rom() {
    Engine engine;
    if (!load_rom(engine)) {
        std::printf("roms/48.rom not found -- skipping (it is gitignored)\n");
        return 0;
    }
    std::shared_ptr<AudioRing> ring = engine.add_audio_sink(CAPTURE_RING);

    std::vector<int16_t> warmup;
    run_for(engine, *ring, warmup, 200); // boot BASIC so the system vars exist

    // Call the ROM's own BEEPER routine at 0x03B5 rather than typing BEEP into
    // BASIC: this is the same ROM code a BEEP command ends up in, so it tests
    // the real thing, but without depending on key-repeat timing to get the
    // command typed. Per the ROM manual, DE is the number of complete cycles
    // (frequency x duration) and HL is 437500/frequency - 30.125.
    //
    //   8000  F3           DI
    //   8001  11 B8 01     LD DE,440      ; 440 cycles = 1 second at 440Hz
    //   8004  21 C4 03     LD HL,964      ; 437500/440 - 30.125
    //   8007  CD B5 03     CALL 03B5      ; BEEPER
    //   800A  18 FE        JR $
    const std::vector<uint8_t> program = {0xF3, 0x11, 0xB8, 0x01, 0x21, 0xC4,
                                          0x03, 0xCD, 0xB5, 0x03, 0x18, 0xFE};
    engine.write_memory(0x8000, program);
    Registers r = engine.registers();
    r.pc = 0x8000;
    engine.set_registers(r);

    std::vector<int16_t> samples;
    run_for(engine, *ring, samples, 400);
    write_wav_file(samples, "beep.wav");

    size_t first = samples.size();
    size_t last = 0;
    for (size_t i = 0; i < samples.size(); i++) {
        if (samples[i] > 2000 || samples[i] < -2000) {
            if (i < first) {
                first = i;
            }
            last = i;
        }
    }
    if (last > first) {
        std::printf("note runs %.3fs..%.3fs (%.3fs long)\n",
                    double(first) / double(AUDIO_SAMPLE_RATE),
                    double(last) / double(AUDIO_SAMPLE_RATE),
                    double(last - first) / double(AUDIO_SAMPLE_RATE));
        const std::vector<int16_t> note(samples.begin() + long(first),
                                        samples.begin() + long(last));
        std::printf("the note itself:\n");
        report(note);
    }
    return samples.empty() ? 1 : 0;
}

int run_serve() {
    Engine engine;
    if (!load_rom(engine)) {
        std::printf("roms/48.rom not found -- serving an empty machine\n");
    }
    std::string error;
    uint32_t actual_ms = 0;
    if (start_audio_device(engine, DEFAULT_AUDIO_LATENCY_MS, actual_ms, error)) {
        std::printf("Native audio device open\n");
    } else {
        std::printf("Native audio unavailable: %s\n", error.c_str());
    }
    std::thread([&] {
        serve_audio_stream(engine, "127.0.0.1", 8501, DEFAULT_AUDIO_LATENCY_MS);
    }).detach();

    // A machine that is not running makes no sound, so keep it going.
    std::printf("Running. Connect to 127.0.0.1:8501.\n");
    std::fflush(stdout);
    engine.run();
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    const std::string mode = argc > 1 ? argv[1] : "tone";
    if (mode == "tone") {
        return run_tone();
    }
    if (mode == "rom") {
        return run_rom();
    }
    if (mode == "serve") {
        return run_serve();
    }
    std::fprintf(stderr, "usage: beep [tone|rom|serve]\n");
    return 2;
}
