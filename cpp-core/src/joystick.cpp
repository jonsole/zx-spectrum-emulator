#include "joystick.h"

#include <cctype>

namespace zx {
namespace {

/// A key on the keyboard matrix: the half-row (as keyboard.cpp's ROWS
/// numbers them, the address line that selects it) and its bit.
struct KeyPos {
    uint8_t row;
    uint8_t bit;
};

/// Each keyed mode's five keys, in JOY_* bit order: right, left, down, up,
/// fire. Row 3 is 1 2 3 4 5 from bit 0, row 4 is 0 9 8 7 6.
struct KeyedMode {
    KeyPos keys[5];
};

/// Interface II's first port, 6 left, 7 right, 8 down, 9 up, 0 fire.
constexpr KeyedMode SINCLAIR1 = {{{4, 3}, {4, 4}, {4, 2}, {4, 1}, {4, 0}}};
/// Its second, 1 left, 2 right, 3 down, 4 up, 5 fire.
constexpr KeyedMode SINCLAIR2 = {{{3, 1}, {3, 0}, {3, 2}, {3, 3}, {3, 4}}};
/// The cursor keys, 5 left, 8 right, 6 down, 7 up, and 0 to fire. Only the
/// digits: a cursor joystick interface never pressed CAPS SHIFT, which is
/// why games offering "cursor" read the digits alone.
constexpr KeyedMode CURSOR = {{{4, 2}, {3, 4}, {4, 4}, {4, 3}, {4, 0}}};

const KeyedMode* keyed(JoystickMode m) {
    switch (m) {
        case JoystickMode::Sinclair1: return &SINCLAIR1;
        case JoystickMode::Sinclair2: return &SINCLAIR2;
        case JoystickMode::Cursor: return &CURSOR;
        default: return nullptr;
    }
}

/// The modes byte's three-bit fields hold 0-4; 5-7 mean none, as on the
/// board.
JoystickMode mode_from_bits(uint8_t bits) {
    return bits <= uint8_t(JoystickMode::Cursor) ? JoystickMode(bits) : JoystickMode::None;
}

constexpr const char* MODE_NAMES[] = {"none", "kempston", "sinclair1", "sinclair2", "cursor"};

/// The letters for JOY_* bits 0-4.
constexpr char DIRECTION_LETTERS[] = {'R', 'L', 'D', 'U', 'F'};

} // namespace

bool Joystick::kempston_present() const {
    for (int p = 0; p < JOY_PORTS; p++) {
        if (mode[p] == JoystickMode::Kempston) {
            return true;
        }
    }
    return false;
}

uint8_t Joystick::kempston() const {
    uint8_t value = 0;
    for (int p = 0; p < JOY_PORTS; p++) {
        if (mode[p] == JoystickMode::Kempston) {
            value = uint8_t(value | (stick[p] & JOY_ALL));
        }
    }
    return value;
}

uint8_t Joystick::keys_held(uint8_t row_select) const {
    uint8_t held = 0;
    for (int p = 0; p < JOY_PORTS; p++) {
        const KeyedMode* k = keyed(mode[p]);
        if (k == nullptr || stick[p] == 0) {
            continue;
        }
        for (int d = 0; d < 5; d++) {
            const KeyPos pos = k->keys[d];
            // The row is read when its address line is low.
            if ((stick[p] & (1 << d)) != 0 && (row_select & (1 << pos.row)) == 0) {
                held = uint8_t(held | (1 << pos.bit));
            }
        }
    }
    return held;
}

uint8_t Joystick::modes_byte() const {
    return uint8_t(uint8_t(mode[JOY_LEFT_PORT]) | (uint8_t(mode[JOY_RIGHT_PORT]) << 3));
}

void Joystick::set_modes_byte(uint8_t joy) {
    mode[JOY_LEFT_PORT] = mode_from_bits(joy & 7);
    mode[JOY_RIGHT_PORT] = mode_from_bits((joy >> 3) & 7);
}

uint32_t Joystick::packed() const {
    return uint32_t(modes_byte()) | (uint32_t(stick[0]) << 8) | (uint32_t(stick[1]) << 16);
}

void Joystick::set_packed(uint32_t value) {
    set_modes_byte(uint8_t(value));
    stick[0] = uint8_t((value >> 8) & JOY_ALL);
    stick[1] = uint8_t((value >> 16) & JOY_ALL);
}

const char* Joystick::mode_name(JoystickMode m) {
    const uint8_t i = uint8_t(m);
    return i < sizeof MODE_NAMES / sizeof MODE_NAMES[0] ? MODE_NAMES[i] : "none";
}

bool Joystick::parse_mode(const std::string& text, JoystickMode& out) {
    std::string lower;
    for (char c : text) {
        lower += char(std::tolower(static_cast<unsigned char>(c)));
    }
    for (uint8_t i = 0; i < sizeof MODE_NAMES / sizeof MODE_NAMES[0]; i++) {
        if (lower == MODE_NAMES[i]) {
            out = JoystickMode(i);
            return true;
        }
    }
    return false;
}

bool Joystick::parse_directions(const std::string& text, uint8_t& out) {
    uint8_t bits = 0;
    for (char c : text) {
        const char upper = char(std::toupper(static_cast<unsigned char>(c)));
        bool known = false;
        for (int d = 0; d < 5; d++) {
            if (upper == DIRECTION_LETTERS[d]) {
                bits = uint8_t(bits | (1 << d));
                known = true;
            }
        }
        if (!known) {
            return false;
        }
    }
    out = bits;
    return true;
}

std::string Joystick::directions_text(uint8_t s) {
    // Written in the order people say them, up/down before left/right.
    std::string text;
    if (s & JOY_UP) text += 'U';
    if (s & JOY_DOWN) text += 'D';
    if (s & JOY_LEFT) text += 'L';
    if (s & JOY_RIGHT) text += 'R';
    if (s & JOY_FIRE) text += 'F';
    return text;
}

bool Joystick::parse_port(const std::string& text, int& out) {
    if (text == "left") {
        out = JOY_LEFT_PORT;
        return true;
    }
    if (text == "right") {
        out = JOY_RIGHT_PORT;
        return true;
    }
    return false;
}

} // namespace zx
