// The screen stream's stored PNG (screen_stream.cpp): a well-formed PNG whose
// pixels come back exactly, read the way a decoder reads it -- chunk by
// chunk, each CRC checked, the IDAT inflated by miniz rather than taken
// apart by hand.

#include "rf_filter.h"
#include "screen_stream.h"
#include "ula.h"

#include "test_main.h"

#include <miniz/miniz.h>

#include <cstring>
#include <string>
#include <vector>

using namespace zx;

namespace {

uint32_t be32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}

/// A picture of the given size whose every byte depends on where it is, so a
/// row out of place or a byte dropped shows.
std::vector<uint8_t> pattern(uint32_t width, uint32_t height) {
    std::vector<uint8_t> rgb(size_t(width) * height * 3);
    for (size_t i = 0; i < rgb.size(); i++) {
        rgb[i] = uint8_t(i * 7 + i / 1000);
    }
    return rgb;
}

/// Reads `png` as a decoder would: the signature, then chunks with their
/// CRCs. Returns the inflated IDAT and sets the IHDR fields; empty on any
/// fault.
std::vector<uint8_t> read_png(const std::vector<uint8_t>& png, uint32_t& width, uint32_t& height,
                              std::string& order) {
    static const uint8_t SIGNATURE[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    if (png.size() < 8 || std::memcmp(png.data(), SIGNATURE, 8) != 0) {
        return {};
    }
    std::vector<uint8_t> idat;
    size_t at = 8;
    while (at + 12 <= png.size()) {
        const uint32_t len = be32(&png[at]);
        if (at + 12 + len > png.size()) {
            return {};
        }
        const std::string type(reinterpret_cast<const char*>(&png[at + 4]), 4);
        const uint32_t crc = uint32_t(mz_crc32(MZ_CRC32_INIT, &png[at + 4], len + 4));
        if (crc != be32(&png[at + 8 + len])) {
            return {};
        }
        order += type + " ";
        if (type == "IHDR") {
            width = be32(&png[at + 8]);
            height = be32(&png[at + 12]);
            if (png[at + 16] != 8 || png[at + 17] != 2) {
                return {};
            }
        } else if (type == "IDAT") {
            idat.insert(idat.end(), png.begin() + std::ptrdiff_t(at + 8),
                        png.begin() + std::ptrdiff_t(at + 8 + len));
        }
        at += 12 + len;
    }
    size_t out_len = 0;
    void* raw = tinfl_decompress_mem_to_heap(idat.data(), idat.size(), &out_len,
                                             TINFL_FLAG_PARSE_ZLIB_HEADER);
    if (!raw) {
        return {};
    }
    std::vector<uint8_t> out(static_cast<uint8_t*>(raw), static_cast<uint8_t*>(raw) + out_len);
    mz_free(raw);
    return out;
}

void check_round_trip(uint32_t width, uint32_t height) {
    const std::vector<uint8_t> rgb = pattern(width, height);
    const std::vector<uint8_t> png = encode_png_stored(rgb);
    uint32_t w = 0;
    uint32_t h = 0;
    std::string order;
    const std::vector<uint8_t> raw = read_png(png, w, h, order);
    CHECK_EQ(w, width);
    CHECK_EQ(h, height);
    CHECK_EQ(order, std::string("IHDR IDAT IEND "));
    // Each row is its filter byte, 0, then the pixels as they were.
    const size_t row = size_t(width) * 3;
    CHECK_EQ(raw.size(), (row + 1) * height);
    bool same = raw.size() == (row + 1) * height;
    for (uint32_t y = 0; same && y < height; y++) {
        same = raw[y * (row + 1)] == 0 &&
               std::memcmp(&raw[y * (row + 1) + 1], &rgb[y * row], row) == 0;
    }
    CHECK(same);
}

} // namespace

TEST(stored_png_of_the_rf_picture_reads_back_exactly) {
    // 704 x 3 + 1 bytes a row, 624 rows: 1.3 MB, about twenty stored blocks,
    // the last one short.
    check_round_trip(RF_WIDTH, RF_HEIGHT);
}

TEST(stored_png_of_the_plain_picture_reads_back_exactly) {
    check_round_trip(FULL_WIDTH, FULL_HEIGHT);
}

TEST(stored_png_refuses_a_size_it_does_not_know) {
    CHECK(encode_png_stored(std::vector<uint8_t>(30)).empty());
}

RUN_TESTS()
