// Screen-frame streaming TCP server, ported from
// rust-core/zx-server/src/screen_stream.rs: on each connection, loops forever
// pushing the live display as a length-prefixed PNG frame (4-byte big-endian
// length + PNG bytes) until the client disconnects.
//
// Reads the screen via `Engine::screen()`, which bypasses the command queue
// for exactly this reason -- streaming must not stall behind a live `run()`,
// which is precisely when there is something worth watching.

#include "screen_stream.h"

#include "net.h"
#include "ula.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <stb_image_write.h>

#include <chrono>
#include <cstdio>
#include <thread>

namespace zx {
namespace {

constexpr auto FRAME_INTERVAL = std::chrono::milliseconds(20);

void collect_png(void* context, void* data, int size) {
    auto* out = static_cast<std::vector<uint8_t>*>(context);
    const auto* bytes = static_cast<const uint8_t*>(data);
    out->insert(out->end(), bytes, bytes + size);
}

void handle_connection(net::Socket sock, Engine& engine) {
    constexpr size_t EXPECTED = size_t(FULL_WIDTH) * FULL_HEIGHT * 3;
    for (;;) {
        std::this_thread::sleep_for(FRAME_INTERVAL);
        const std::vector<uint8_t> rgb = engine.screen();
        if (rgb.size() != EXPECTED) {
            continue; // not primed yet
        }
        const std::vector<uint8_t> png = encode_png(rgb);
        const uint32_t len = uint32_t(png.size());
        const uint8_t header[4] = {uint8_t(len >> 24), uint8_t(len >> 16), uint8_t(len >> 8),
                                   uint8_t(len)};
        if (!sock.send_all(reinterpret_cast<const char*>(header), sizeof header)) {
            break;
        }
        if (!sock.send_all(reinterpret_cast<const char*>(png.data()), png.size())) {
            break;
        }
    }
}

} // namespace

std::vector<uint8_t> encode_png(const std::vector<uint8_t>& rgb) {
    std::vector<uint8_t> out;
    stbi_write_png_to_func(collect_png, &out, int(FULL_WIDTH), int(FULL_HEIGHT), 3, rgb.data(),
                           int(FULL_WIDTH) * 3);
    return out;
}

void serve_screen_stream(Engine& engine, const std::string& host, uint16_t port) {
    net::Listener listener;
    std::string error;
    if (!listener.listen(host, port, error)) {
        std::fprintf(stderr, "Screen stream server failed to start: %s\n", error.c_str());
        return;
    }
    std::printf("Screen stream server listening on %s:%u\n", host.c_str(), unsigned(port));
    std::fflush(stdout);

    for (;;) {
        net::Socket sock = listener.accept();
        if (!sock.valid()) {
            continue;
        }
        std::thread([s = std::move(sock), &engine]() mutable { handle_connection(std::move(s), engine); })
            .detach();
    }
}

} // namespace zx
