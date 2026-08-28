// Beeper-audio streaming TCP server, deliberately shaped like
// screen_stream.cpp: same length-prefixed framing, same thread-per-connection
// blocking sockets, same reason for existing (a webview cannot open a raw TCP
// socket, so the VS Code extension host relays for it).
//
// Two things differ from the screen, and both come from audio being a
// continuous stream rather than a series of independent stills:
//
//   * The screen server sends the LATEST frame and a dropped one is invisible.
//     Audio has to send EVERY sample in order, because a dropped block is an
//     audible click -- hence a per-connection ring drained in order rather
//     than a snapshot copied on a timer.
//
//   * A preamble announces the sample rate and the target latency, so the
//     client neither hardcodes what the emulator happens to use today nor
//     needs its own buffering setting to keep in step with the server's.

#include "audio_stream.h"

#include "beeper.h"
#include "net.h"

#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

namespace zx {
namespace {

/// How often to hand whatever has accumulated to the socket. Short enough
/// that it is never the dominant term in the latency budget -- this is
/// interactive audio, and the gap between pressing a key and hearing it is
/// the whole point.
constexpr auto POLL_INTERVAL = std::chrono::milliseconds(5);

/// Floor on the per-connection ring, whatever latency was asked for. It has
/// to cover the gap between the emulator's publishes (roughly twice per
/// frame) and this thread's poll; below about this the ring would start
/// dropping samples that the client could perfectly well have played.
constexpr uint32_t MIN_RING_MS = 50;

bool send_u32_be(net::Socket& sock, uint32_t v) {
    const uint8_t bytes[4] = {uint8_t(v >> 24), uint8_t(v >> 16), uint8_t(v >> 8), uint8_t(v)};
    return sock.send_all(reinterpret_cast<const char*>(bytes), sizeof bytes);
}

void handle_connection(net::Socket sock, Engine& engine, uint32_t latency_ms) {
    // The rate is whatever the beeper is actually generating at, which a
    // native device may have changed to its engine's mix rate.
    const uint32_t rate = engine.audio_sample_rate();
    if (!sock.send_all("ZXA2", 4) || !send_u32_be(sock, rate)
        || !send_u32_be(sock, latency_ms)) {
        return;
    }

    const uint32_t ring_ms = latency_ms > MIN_RING_MS ? latency_ms : MIN_RING_MS;
    const size_t ring_samples = size_t(rate) * ring_ms / 1000;

    std::shared_ptr<AudioRing> ring = engine.add_audio_sink(ring_samples);
    std::vector<int16_t> block(ring_samples);
    for (;;) {
        std::this_thread::sleep_for(POLL_INTERVAL);
        const size_t n = ring->read(block.data(), block.size());
        if (n == 0) {
            continue; // paused, stepping, or nothing written to the speaker
        }
        // int16 little-endian, which is both x86's native order and what Web
        // Audio and waveOut want -- so no byte swapping anywhere on the path.
        const uint32_t bytes = uint32_t(n * 2);
        if (!send_u32_be(sock, bytes)
            || !sock.send_all(reinterpret_cast<const char*>(block.data()), bytes)) {
            break;
        }
    }
    engine.remove_audio_sink(ring);
}

} // namespace

void serve_audio_stream(Engine& engine, const std::string& host, uint16_t port,
                        uint32_t latency_ms) {
    net::Listener listener;
    std::string error;
    if (!listener.listen(host, port, error)) {
        std::fprintf(stderr, "Audio stream server failed to start: %s\n", error.c_str());
        return;
    }
    std::printf("Audio stream server listening on %s:%u (%u Hz mono s16, %ums buffer)\n",
                host.c_str(), unsigned(port), unsigned(engine.audio_sample_rate()),
                unsigned(latency_ms));
    std::fflush(stdout);

    for (;;) {
        net::Socket sock = listener.accept();
        if (!sock.valid()) {
            continue;
        }
        std::thread([s = std::move(sock), &engine, latency_ms]() mutable {
            handle_connection(std::move(s), engine, latency_ms);
        }).detach();
    }
}

} // namespace zx
