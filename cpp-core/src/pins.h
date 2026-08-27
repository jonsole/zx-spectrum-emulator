#pragma once
// Z80 bus pin encoding: address bits 0-15, data bits 16-23, control lines from
// bit 24. Ported from rust-core/zx-core/src/pins.rs, and deliberately kept
// bit-for-bit identical to it -- vendor/chips/z80.h's own shim uses this exact
// layout, so the differential tests depend on it.
//
// All control lines are represented ACTIVE HIGH here (bit set == asserted),
// the opposite of the real chip's active-low wires but matching the vendored
// z80.h reference's internal convention.
//
// IMPORTANT, and the one real divergence from the Rust version: control lines
// are NOT auto-cleared each clock. rust-core's tick() began with
// `pins &= !CTRL_PIN_MASK`, forcing every T-state to re-assert whatever it
// wanted held -- workable at whole-T-state resolution, but wrong at half-T
// resolution, where a line held across a full T-state would have to be
// re-asserted on both halves. Here a line stays asserted until something
// explicitly releases it (see release_ctrl), the same convention real hardware
// and SpecIde both use. Each machine cycle's final half-state is responsible
// for releasing what it asserted.

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

// Masks.
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

/// Every line a machine cycle may assert and must therefore release. Unlike
/// rust-core's constant of the same name this is never applied automatically;
/// it exists for release_ctrl() call sites that end a whole machine cycle.
/// Deliberately excludes WAIT (driven by the bus, not the CPU) and
/// HALT/INT/NMI/RESET (levels, not per-cycle pulses).
constexpr uint64_t CTRL_PIN_MASK = M1 | MREQ | IORQ | RD | WR | RFSH;

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

/// Sets the address bus plus extra control lines in one go (z80.h's `_sax`).
constexpr uint64_t set_addr_ctrl(uint64_t pins, uint16_t addr, uint64_t ctrl) {
    return set_addr(pins, addr) | ctrl;
}

/// Sets address, data, and extra control lines in one go (z80.h's `_sadx`).
constexpr uint64_t set_addr_data_ctrl(uint64_t pins, uint16_t addr, uint8_t data, uint64_t ctrl) {
    return set_data(set_addr(pins, addr), data) | ctrl;
}

/// Deasserts the given control lines. The counterpart to set_*_ctrl's OR,
/// and the reason control lines can persist across half-clocks safely.
constexpr uint64_t release_ctrl(uint64_t pins, uint64_t ctrl) {
    return pins & ~ctrl;
}

} // namespace zx
