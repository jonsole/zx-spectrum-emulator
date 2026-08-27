#pragma once
// Z80 bus pin encoding: address bits 0-15, data bits 16-23, control lines from
// bit 24. Bit POSITIONS match rust-core/zx-core/src/pins.rs and z80.h.
//
// POLARITY DOES NOT. Every Z80 control signal is ACTIVE LOW on the real chip,
// and that is what this models: a bit that is CLEAR means the line is being
// driven (asserted); a bit that is SET means it is idle. So the resting state
// of the bus is PINS_IDLE -- all control bits high -- not zero.
//
// rust-core and z80.h both represent control lines active-high (bit set ==
// asserted). That is easier to write and fine for a core that only ever asks
// "is this line requesting something". It stops being fine here: the ULA work
// this core exists for reasons entirely in terms of real signal levels ("the
// ULA halts the CPU while MREQ is low", "it watches MREQ but not RFSH, which
// is why refresh cycles cause snow"), and an inverted convention makes every
// one of those statements need mental translation at each call site. Since we
// deliberately do not diff pins against z80.h (see differential.cpp), nothing
// forces us to share its polarity.
//
// The accessors below are named for the action, not the bit operation, and
// are deliberately NOT the same names the active-high version used -- a call
// site that was missed in the conversion fails to compile rather than
// silently inverting a signal.
//
// Control lines are not auto-cleared each clock either: a line stays asserted
// until something releases it, as on real hardware. Each machine cycle's
// final half-state releases what that cycle asserted.

#include <cstdint>

namespace zx {

// Bit indices.
constexpr uint32_t PIN_M1 = 24;
constexpr uint32_t PIN_MREQ = 25;
constexpr uint32_t PIN_IORQ = 26;
constexpr uint32_t PIN_RD = 27;
constexpr uint32_t PIN_WR = 28;
constexpr uint32_t PIN_HALT = 29;
constexpr uint32_t PIN_INT = 30;
constexpr uint32_t PIN_RESET = 31;
constexpr uint32_t PIN_NMI = 32;
constexpr uint32_t PIN_WAIT = 33;
constexpr uint32_t PIN_RFSH = 34;

// Masks. Every one of these is an active-LOW line.
constexpr uint64_t M1 = 1ULL << PIN_M1;
constexpr uint64_t MREQ = 1ULL << PIN_MREQ;
constexpr uint64_t IORQ = 1ULL << PIN_IORQ;
constexpr uint64_t RD = 1ULL << PIN_RD;
constexpr uint64_t WR = 1ULL << PIN_WR;
constexpr uint64_t HALT = 1ULL << PIN_HALT;
constexpr uint64_t INT = 1ULL << PIN_INT;
constexpr uint64_t RESET = 1ULL << PIN_RESET;
constexpr uint64_t NMI = 1ULL << PIN_NMI;
constexpr uint64_t WAIT = 1ULL << PIN_WAIT;
constexpr uint64_t RFSH = 1ULL << PIN_RFSH;

/// Every control line, whoever drives it. The CPU drives M1/MREQ/IORQ/RD/WR/
/// RFSH/HALT; the machine drives INT/NMI/WAIT/RESET.
constexpr uint64_t ALL_SIGNALS =
    M1 | MREQ | IORQ | RD | WR | HALT | INT | RESET | NMI | WAIT | RFSH;

/// The resting bus: every control line released (high), address and data
/// zero. Anything that starts a CPU from scratch must start from this, NOT
/// from 0 -- zero would mean every signal simultaneously asserted, including
/// RESET and INT.
constexpr uint64_t PINS_IDLE = ALL_SIGNALS;

constexpr uint16_t get_addr(uint64_t pins) {
    return static_cast<uint16_t>(pins & 0xFFFF);
}

constexpr uint64_t set_addr(uint64_t pins, uint16_t addr) {
    return (pins & ~0xFFFFULL) | addr;
}

constexpr uint8_t get_data(uint64_t pins) {
    return static_cast<uint8_t>((pins >> 16) & 0xFF);
}

constexpr uint64_t set_data(uint64_t pins, uint8_t data) {
    return (pins & ~0xFF0000ULL) | (static_cast<uint64_t>(data) << 16);
}

/// True when EVERY line in `mask` is being driven. Active low, so "asserted"
/// is "bit clear".
constexpr bool asserted(uint64_t pins, uint64_t mask) {
    return (pins & mask) == 0;
}

/// True when ANY line in `mask` is being driven.
constexpr bool any_asserted(uint64_t pins, uint64_t mask) {
    return (pins & mask) != mask;
}

/// Drives the given lines low.
constexpr uint64_t assert_pins(uint64_t pins, uint64_t mask) {
    return pins & ~mask;
}

/// Releases the given lines back high.
constexpr uint64_t release_pins(uint64_t pins, uint64_t mask) {
    return pins | mask;
}

/// Puts an address on the bus and asserts the given control lines.
constexpr uint64_t set_addr_assert(uint64_t pins, uint16_t addr, uint64_t ctrl) {
    return assert_pins(set_addr(pins, addr), ctrl);
}

/// Puts an address and a data byte on the bus and asserts the given lines.
constexpr uint64_t set_addr_data_assert(uint64_t pins, uint16_t addr, uint8_t data,
                                        uint64_t ctrl) {
    return assert_pins(set_data(set_addr(pins, addr), data), ctrl);
}

} // namespace zx
