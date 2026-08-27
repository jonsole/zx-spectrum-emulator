#pragma once
// Z80 disassembler -- decodes bytes into mnemonic text. Ported from
// rust-core/zx-core/src/disassembler.rs. Implements the documented Z80
// instruction set via the standard bit-field decomposition of the opcode byte
// (x/y/z/p/q -- see http://www.z80.info/decoding.htm), covering unprefixed,
// CB, ED, DD, FD, and the DD CB d / FD CB d double-prefixed forms.
// Undocumented opcodes that don't correspond to a documented instruction
// decode as a raw `DEFB` byte.
//
// This only decodes bytes into text -- it knows nothing about breakpoints, PC
// or the running machine. Callers pass a `read(addr) -> uint8_t` callable
// (typically bound to a memory snapshot) and a start address.

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace zx {

using ReadFn = std::function<uint8_t(uint16_t)>;

struct Instruction {
    uint16_t addr = 0;
    uint8_t length = 0;
    std::string text;
    std::vector<uint8_t> raw;
};

Instruction disassemble_one(const ReadFn& read, uint16_t addr);

/// Decodes `count` consecutive instructions starting at `addr`.
std::vector<Instruction> disassemble_range(const ReadFn& read, uint16_t addr, size_t count);

} // namespace zx
