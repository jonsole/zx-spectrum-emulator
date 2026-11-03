// Screen-frame streaming TCP server, ported from
// the project's former Rust server: on each connection, loops forever
// pushing the live display as a length-prefixed PNG frame (4-byte big-endian
// length + PNG bytes) until the client disconnects.
//
// Reads the screen via `Engine::screen()`, which bypasses the command queue
// for exactly this reason -- streaming must not stall behind a live `run()`,
// which is precisely when there is something worth watching.

#include "screen_stream.h"

#include "log.h"
#include "net.h"
#include "ula.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <stb_image_write.h>

#include <miniz/miniz.h>

#include <chrono>
#include <cstdio>
#include <thread>
#include <utility>

namespace zx {
namespace {

constexpr auto FRAME_INTERVAL = std::chrono::milliseconds(20);

void collect_png(void* context, void* data, int size) {
    auto* out = static_cast<std::vector<uint8_t>*>(context);
    const auto* bytes = static_cast<const uint8_t*>(data);
    out->insert(out->end(), bytes, bytes + size);
}

void handle_connection(net::Socket sock, Engine& engine) {
    for (;;) {
        std::this_thread::sleep_for(FRAME_INTERVAL);
        const std::vector<uint8_t> rgb = engine.screen();
        if (!screen_size(rgb.size(), nullptr, nullptr)) {
            continue; // not primed yet
        }
        // The plain picture compresses to a few kilobytes in a few
        // milliseconds. The RF look's, four times the pixels and noisy,
        // took about 100 ms to compress to 1.3 MB -- which held the panel
        // to ten frames a second -- so it goes stored instead.
        const bool rf = rgb.size() == size_t(RF_WIDTH) * RF_HEIGHT * 3;
        const std::vector<uint8_t> png = rf ? encode_png_stored(rgb) : encode_png(rgb);
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

bool screen_size(size_t bytes, uint32_t* width, uint32_t* height) {
    uint32_t w = 0;
    uint32_t h = 0;
    if (bytes == size_t(FULL_WIDTH) * FULL_HEIGHT * 3) {
        w = FULL_WIDTH;
        h = FULL_HEIGHT;
    } else if (bytes == size_t(RF_WIDTH) * RF_HEIGHT * 3) {
        w = RF_WIDTH;
        h = RF_HEIGHT;
    } else {
        return false;
    }
    if (width) {
        *width = w;
    }
    if (height) {
        *height = h;
    }
    return true;
}

std::vector<uint8_t> encode_png(const std::vector<uint8_t>& rgb) {
    std::vector<uint8_t> out;
    uint32_t width = 0;
    uint32_t height = 0;
    if (!screen_size(rgb.size(), &width, &height)) {
        return out;
    }
    stbi_write_png_to_func(collect_png, &out, int(width), int(height), 3, rgb.data(),
                           int(width) * 3);
    return out;
}

namespace {

void put_u32(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(uint8_t(v >> 24));
    out.push_back(uint8_t(v >> 16));
    out.push_back(uint8_t(v >> 8));
    out.push_back(uint8_t(v));
}

/// Appends a PNG chunk: its length, type and data, then the CRC of the type
/// and data.
void put_chunk(std::vector<uint8_t>& out, const char type[4], const uint8_t* data, size_t size) {
    put_u32(out, uint32_t(size));
    const size_t start = out.size();
    out.insert(out.end(), type, type + 4);
    out.insert(out.end(), data, data + size);
    put_u32(out, uint32_t(mz_crc32(MZ_CRC32_INIT, out.data() + start, size + 4)));
}

} // namespace

std::vector<uint8_t> encode_png_stored(const std::vector<uint8_t>& rgb) {
    std::vector<uint8_t> out;
    uint32_t width = 0;
    uint32_t height = 0;
    if (!screen_size(rgb.size(), &width, &height)) {
        return out;
    }
    // The image data PNG compresses: each row its filter byte (0, none) and
    // its pixels.
    const size_t row = size_t(width) * 3;
    std::vector<uint8_t> raw;
    raw.reserve((row + 1) * height);
    for (uint32_t y = 0; y < height; y++) {
        raw.push_back(0);
        raw.insert(raw.end(), rgb.begin() + std::ptrdiff_t(y * row),
                   rgb.begin() + std::ptrdiff_t((y + 1) * row));
    }
    // A zlib stream of stored deflate blocks (RFC 1950/1951): the header,
    // blocks of at most 65,535 bytes each with its length and that length's
    // complement, then the Adler-32 of the data.
    constexpr size_t STORED_MAX = 65535;
    std::vector<uint8_t> z;
    z.reserve(raw.size() + raw.size() / STORED_MAX * 5 + 16);
    z.push_back(0x78);   // deflate, a 32K window
    z.push_back(0x01);   // no dictionary, fastest; makes the header a multiple of 31
    for (size_t at = 0; at < raw.size(); at += STORED_MAX) {
        const size_t n = raw.size() - at < STORED_MAX ? raw.size() - at : STORED_MAX;
        z.push_back(at + n == raw.size() ? 1 : 0);   // BFINAL on the last; BTYPE 00, stored
        z.push_back(uint8_t(n));
        z.push_back(uint8_t(n >> 8));
        z.push_back(uint8_t(~n));
        z.push_back(uint8_t(~n >> 8));
        z.insert(z.end(), raw.begin() + std::ptrdiff_t(at), raw.begin() + std::ptrdiff_t(at + n));
    }
    put_u32(z, uint32_t(mz_adler32(MZ_ADLER32_INIT, raw.data(), raw.size())));

    static const uint8_t SIGNATURE[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    out.reserve(z.size() + 64);
    out.insert(out.end(), SIGNATURE, SIGNATURE + 8);
    std::vector<uint8_t> ihdr;
    put_u32(ihdr, width);
    put_u32(ihdr, height);
    ihdr.push_back(8);   // 8 bits a component
    ihdr.push_back(2);   // RGB
    ihdr.push_back(0);   // deflate
    ihdr.push_back(0);   // the standard filters
    ihdr.push_back(0);   // not interlaced
    put_chunk(out, "IHDR", ihdr.data(), ihdr.size());
    put_chunk(out, "IDAT", z.data(), z.size());
    put_chunk(out, "IEND", nullptr, 0);
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
    serve_screen_stream(engine, std::move(listener));
}

void serve_screen_stream(Engine& engine, net::Listener listener) {
    for (;;) {
        net::Socket sock = listener.accept();
        if (!sock.valid()) {
            continue;
        }
        std::thread([s = std::move(sock), &engine]() mutable {
            log("Screen viewer connected");
            handle_connection(std::move(s), engine);
            log("Screen viewer disconnected");
        }).detach();
    }
}

} // namespace zx
