#include "keyboard.h"

#include <algorithm>
#include <cctype>

namespace zx {
namespace {

/// Each half-row: the address line that selects it (bit within the port's
/// high byte), and its five keys in bit 0..4 order.
struct Row {
    uint8_t addr_bit;
    const char* keys[5];
};

constexpr Row ROWS[8] = {
    {0, {"CAPS SHIFT", "Z", "X", "C", "V"}},
    {1, {"A", "S", "D", "F", "G"}},
    {2, {"Q", "W", "E", "R", "T"}},
    {3, {"1", "2", "3", "4", "5"}},
    {4, {"0", "9", "8", "7", "6"}},
    {5, {"P", "O", "I", "U", "Y"}},
    {6, {"ENTER", "L", "K", "J", "H"}},
    {7, {"SPACE", "SYM SHIFT", "M", "N", "B"}},
};

/// Returns true and fills row/bit if `key` names a real key.
bool key_pos(const std::string& key, size_t& row, uint8_t& bit) {
    std::string upper = key;
    std::transform(upper.begin(), upper.end(), upper.begin(),
                   [](unsigned char c) { return char(std::toupper(c)); });
    for (size_t r = 0; r < 8; r++) {
        for (uint8_t b = 0; b < 5; b++) {
            if (upper == ROWS[r].keys[b]) {
                row = r;
                bit = b;
                return true;
            }
        }
    }
    return false; // unknown key names are ignored, not an error
}

} // namespace

void Keyboard::key_down(const std::string& key) {
    size_t row;
    uint8_t bit;
    if (key_pos(key, row, bit)) {
        rows_[row] = uint8_t(rows_[row] & ~(1 << bit) & 0x1F);
    }
}

void Keyboard::key_up(const std::string& key) {
    size_t row;
    uint8_t bit;
    if (key_pos(key, row, bit)) {
        rows_[row] = uint8_t(rows_[row] | (1 << bit));
    }
}

void Keyboard::clear() {
    for (uint8_t& r : rows_) {
        r = 0x1F;
    }
}

uint8_t Keyboard::read_port(uint8_t row_select) const {
    uint8_t bits = 0x1F;
    for (size_t r = 0; r < 8; r++) {
        // Address line held LOW selects the row. Several may be low at once,
        // in which case the rows combine -- real hardware behaviour, and the
        // reason a program can scan several rows in one read.
        if ((row_select & (1 << ROWS[r].addr_bit)) == 0) {
            bits &= rows_[r];
        }
    }
    // Bits 5-7 all float high on an unloaded bus. Bit 6 is the EAR input, and
    // is pulled down from here by a playing tape -- see the read branch of
    // Spectrum48K::service_bus(), which owns that line because it belongs to
    // the tape rather than to any key.
    return uint8_t(bits | 0xE0);
}

void Keyboard::set_rows(const uint8_t* r) {
    for (size_t i = 0; i < 8; i++) {
        rows_[i] = r[i];
    }
}

} // namespace zx
