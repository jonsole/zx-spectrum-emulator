#pragma once
// The bus the CPU reads/writes through. Ported from
// rust-core/zx-core/src/memory.rs.

#include <array>
#include <cstdint>
#include <string>

namespace zx {

/// Abstract bus. `read` is non-const because a real (contended or
/// side-effecting) bus may change state on access.
class Memory {
public:
    virtual ~Memory() = default;
    virtual uint8_t read(uint16_t addr) = 0;
    virtual void write(uint16_t addr, uint8_t value) = 0;
};

/// Unguarded flat 64K -- just enough to exercise the CPU in isolation
/// (differential/pin-level tests, the ZEXALL harness). No write protection.
class FlatMemory : public Memory {
public:
    std::array<uint8_t, 0x10000> bytes{};

    uint8_t read(uint16_t addr) override { return bytes[addr]; }
    void write(uint16_t addr, uint8_t value) override { bytes[addr] = value; }
};

constexpr size_t ROM_SIZE = 0x4000;
constexpr size_t RAM_SIZE = 0xC000;

/// The 48K Spectrum's real memory map: 16K write-protected ROM + 48K RAM.
/// No banking of any kind (that's a 128K feature).
class Spectrum48KMemory : public Memory {
public:
    std::array<uint8_t, ROM_SIZE> rom{};
    std::array<uint8_t, RAM_SIZE> ram{};

    /// Returns an empty string on success, or the error message on failure.
    std::string load_rom(const uint8_t* data, size_t len);

    uint8_t read(uint16_t addr) override {
        return addr < ROM_SIZE ? rom[addr] : ram[addr - ROM_SIZE];
    }

    /// Writes below ROM_SIZE are silently discarded -- that IS the hardware
    /// behavior (there's nothing to write to), not an error worth reporting.
    void write(uint16_t addr, uint8_t value) override {
        if (addr >= ROM_SIZE) {
            ram[addr - ROM_SIZE] = value;
        }
    }
};

} // namespace zx
