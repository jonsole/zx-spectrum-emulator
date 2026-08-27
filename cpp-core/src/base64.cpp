#include "base64.h"

namespace zx {
namespace {

const char ALPHABET[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Value of a base64 character, or -1 if it isn't one. Padding and
/// whitespace both come back as -1 and are simply skipped by the decoder.
int value_of(char c) {
    if (c >= 'A' && c <= 'Z') {
        return c - 'A';
    }
    if (c >= 'a' && c <= 'z') {
        return c - 'a' + 26;
    }
    if (c >= '0' && c <= '9') {
        return c - '0' + 52;
    }
    if (c == '+') {
        return 62;
    }
    if (c == '/') {
        return 63;
    }
    return -1;
}

} // namespace

std::string base64_encode(const std::vector<uint8_t>& data) {
    std::string out;
    out.reserve(((data.size() + 2) / 3) * 4);
    size_t i = 0;
    while (i + 2 < data.size()) {
        uint32_t v = uint32_t(data[i] << 16) | uint32_t(data[i + 1] << 8) | data[i + 2];
        out += ALPHABET[(v >> 18) & 0x3F];
        out += ALPHABET[(v >> 12) & 0x3F];
        out += ALPHABET[(v >> 6) & 0x3F];
        out += ALPHABET[v & 0x3F];
        i += 3;
    }
    const size_t remaining = data.size() - i;
    if (remaining == 1) {
        uint32_t v = uint32_t(data[i] << 16);
        out += ALPHABET[(v >> 18) & 0x3F];
        out += ALPHABET[(v >> 12) & 0x3F];
        out += "==";
    } else if (remaining == 2) {
        uint32_t v = uint32_t(data[i] << 16) | uint32_t(data[i + 1] << 8);
        out += ALPHABET[(v >> 18) & 0x3F];
        out += ALPHABET[(v >> 12) & 0x3F];
        out += ALPHABET[(v >> 6) & 0x3F];
        out += '=';
    }
    return out;
}

std::vector<uint8_t> base64_decode(const std::string& text) {
    std::vector<uint8_t> out;
    out.reserve(text.size() * 3 / 4);
    uint32_t accumulator = 0;
    int bits = 0;
    for (char c : text) {
        int v = value_of(c);
        if (v < 0) {
            continue;
        }
        accumulator = (accumulator << 6) | uint32_t(v);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back(uint8_t((accumulator >> bits) & 0xFF));
        }
    }
    return out;
}

} // namespace zx
