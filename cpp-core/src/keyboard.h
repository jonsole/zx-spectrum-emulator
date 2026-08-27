#pragma once
// The 48K keyboard: 8 half-rows of 5 keys, read through port 0xFE.
//
// A read drives the port's HIGH address byte as a row selector, one bit per
// half-row, ACTIVE LOW -- and any number of rows can be selected at once, in
// which case their key states are combined. Returned bits are active low too:
// 0 means pressed.

#include <cstdint>
#include <string>

namespace zx {

class Keyboard {
public:
    void key_down(const std::string& key);
    void key_up(const std::string& key);
    void clear();

    /// `row_select` is the port address's high byte. Returns bits 0-4 for the
    /// selected half-rows OR'd together, plus the usual high bits set.
    uint8_t read_port(uint8_t row_select) const;

    /// Raw half-row state, for mirroring one Keyboard's state into another
    /// (e.g. live key state owned by a server thread) without going back
    /// through key name lookup.
    const uint8_t* rows() const { return rows_; }
    void set_rows(const uint8_t* r);

private:
    /// One byte per half-row, bit SET == released -- the hardware's idle-high
    /// convention, so no inversion is needed on read.
    uint8_t rows_[8] = {0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F};
};

} // namespace zx
