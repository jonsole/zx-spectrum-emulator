#pragma once
// Bit positions within the Z80 flags register (Registers::f).
// Ported from rust-core/zx-core/src/flags.rs.

#include <cstdint>

namespace zx {

constexpr uint8_t FLAG_C = 1 << 0;
constexpr uint8_t FLAG_N = 1 << 1;
constexpr uint8_t FLAG_PV = 1 << 2;
constexpr uint8_t FLAG_3 = 1 << 3;
constexpr uint8_t FLAG_H = 1 << 4;
constexpr uint8_t FLAG_5 = 1 << 5;
constexpr uint8_t FLAG_Z = 1 << 6;
constexpr uint8_t FLAG_S = 1 << 7;

} // namespace zx
