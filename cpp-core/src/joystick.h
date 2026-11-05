#pragma once
// The joysticks: two ports, each plugged into one of the interfaces a
// Spectrum had, or into nothing (docs/joystick.md).
//
//   Kempston    its own port, read with A5 low: 000FUDLR, 1 = pressed.
//   Sinclair 1  Interface II's first port: keys 6 7 8 9 0.
//   Sinclair 2  Interface II's second port: keys 1 2 3 4 5.
//   Cursor      the cursor keys: 5 6 7 8, and 0 to fire.
//
// The last three are nothing but keys held down, so they are read through
// port 0xFE like the keyboard, ORed with it. The modes are the hardware
// plugged in rather than the machine's state: a reset keeps them, and so does
// loading something. The numbering is retro-spectrum's JOY setting, whose
// board follows this emulator (its docs/spec/joystick.md).

#include <cstdint>
#include <string>

namespace zx {

enum class JoystickMode : uint8_t {
    None = 0,
    Kempston = 1,
    Sinclair1 = 2,
    Sinclair2 = 3,
    Cursor = 4,
};

/// The stick's bits, in the Kempston interface's order -- which is also the
/// order every other mode's table below is kept in.
constexpr uint8_t JOY_RIGHT = 0x01;
constexpr uint8_t JOY_LEFT = 0x02;
constexpr uint8_t JOY_DOWN = 0x04;
constexpr uint8_t JOY_UP = 0x08;
constexpr uint8_t JOY_FIRE = 0x10;
constexpr uint8_t JOY_ALL = 0x1F;

/// The two ports. Left is port 1, the one a single-joystick game reads.
constexpr int JOY_LEFT_PORT = 0;
constexpr int JOY_RIGHT_PORT = 1;
constexpr int JOY_PORTS = 2;

struct Joystick {
    /// What each port is plugged into. The board's power-on setting, JOY =
    /// 0x11: a Kempston on the left, Interface II's first port on the right.
    JoystickMode mode[JOY_PORTS] = {JoystickMode::Kempston, JoystickMode::Sinclair1};
    /// What each stick is doing: JOY_* bits, 1 = pushed or pressed.
    uint8_t stick[JOY_PORTS] = {0, 0};

    /// Whether a Kempston interface is plugged in at all. Without one its
    /// ports are nothing's, and read the floating bus as on a bare machine.
    bool kempston_present() const;
    /// The Kempston port's byte: 000FUDLR, both ports ORed when both are
    /// Kempston. Bits 7-5 are 0.
    uint8_t kempston() const;
    /// The keys the Interface II and cursor sticks are holding, on the
    /// half-rows `row_select` picks (the port's high byte, active low, as
    /// Keyboard::read_port takes it): bits 0-4, 1 = held.
    uint8_t keys_held(uint8_t row_select) const;

    /// The setting as one byte, the board's JOY: bits 2-0 the left port's
    /// mode, 5-3 the right's.
    uint8_t modes_byte() const;
    void set_modes_byte(uint8_t joy);
    /// Everything, for a rewind input: the modes byte, then the two sticks.
    uint32_t packed() const;
    void set_packed(uint32_t value);

    static const char* mode_name(JoystickMode m);
    /// "none", "kempston", "sinclair1", "sinclair2" or "cursor". False for
    /// anything else.
    static bool parse_mode(const std::string& text, JoystickMode& out);
    /// A stick as letters, "UDLRF" in any order and either case: "UF" is up
    /// and fire, "" nothing. False if anything else is in it.
    static bool parse_directions(const std::string& text, uint8_t& out);
    static std::string directions_text(uint8_t stick);
    /// "left" or "right" to a port number. False for anything else.
    static bool parse_port(const std::string& text, int& out);
};

} // namespace zx
