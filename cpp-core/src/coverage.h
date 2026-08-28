#pragma once
// Per-address record of what a running program did with each byte: which
// bytes it executed, which it read as data, and which it wrote.
//
// WHAT THIS IS FOR. A disassembler given a raw memory image has no way to
// tell an instruction from a byte of sprite data, and guesses -- badly, for
// anything with graphics in it, because plausible-looking opcodes are dense.
// Watching the program run answers it instead: a byte the CPU fetched as an
// opcode IS code, with no false positives possible. The map that comes out of
// this feeds SkoolKit's sna2ctl, which turns it into a control file, which is
// what makes sna2skool produce a real disassembly rather than a wall of
// misread DEFBs. See README.md's "Reverse engineering".
//
// The map is necessarily INCOMPLETE -- it only knows what actually ran, so a
// session that never left the title screen classifies most of the image as
// untouched. That is the safe direction to be wrong in: code that was never
// reached comes out as data (DEFBs, which reassemble correctly) rather than
// as invented instructions.
//
// BIT 0 IS LOAD-BEARING. SkoolKit reads a 65536-byte code map as one byte per
// address and tests `data[address] & 1` (skoolkit/snactl.py, read_map). Bit 0
// here is "an instruction started at this address", so the file write() emits
// is simultaneously our own four-bit record AND a valid SkoolKit code map --
// one file, no second export format to keep in step, and `sna2ctl -m` reads
// it directly.
//
// WHEN TO START RECORDING. Loading a program is itself memory traffic: a real
// pulse-level tape load has the ROM loader write every byte of the game, so
// coverage started beforehand marks the whole image as written data. Start
// recording once the program is loaded and about to run -- which is what
// Engine::start_coverage does by clearing the map as it starts.

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace zx {

/// An instruction began at this address -- the first opcode byte of one, as
/// opposed to a prefix's second byte or an operand. This is the bit SkoolKit
/// reads; see the note above before moving it.
constexpr uint8_t COV_INSTRUCTION = 1 << 0;
/// Fetched as an opcode byte (M1). Set on instruction starts and also on the
/// second opcode byte of a CB/ED/DD/FD-prefixed instruction, which is code
/// but is not somewhere a disassembler may start.
constexpr uint8_t COV_CODE = 1 << 1;
/// Read as data -- an operand, a table lookup, a POP. Not an opcode fetch.
constexpr uint8_t COV_READ = 1 << 2;
/// Written to. Distinguishes a variable from a constant table, which is the
/// difference between SkoolKit's `g` (game status buffer) and `b` (data).
constexpr uint8_t COV_WRITTEN = 1 << 3;

/// How many addresses in a range fall into each class. `untouched` counts
/// addresses with no flags at all -- neither executed, read nor written.
struct CoverageCounts {
    size_t instructions = 0;
    size_t code = 0;
    size_t read = 0;
    size_t written = 0;
    size_t untouched = 0;
};

class Coverage {
public:
    /// Notes one half-clock's bus activity. Called from Spectrum48K::clock()
    /// with the pins the CPU has just driven, and `instruction_boundary` from
    /// Z80::fetch_began_instruction() -- see record()'s body for why that flag
    /// has to come from the CPU rather than from the pins.
    ///
    /// Deliberately NOT inline, for the same reason TraceLog::record is not:
    /// clock() is the emulator's hot loop, and a dozen instructions of
    /// rarely-taken flag setting inlined into it costs several percent of
    /// throughput even when nothing is recording. A call per access is
    /// nothing next to that, and only recorded runs pay it.
    void record(uint64_t pins, bool instruction_boundary);

    void clear() { flags_.fill(0); }

    uint8_t at(uint16_t addr) const { return flags_[addr]; }
    const std::array<uint8_t, 0x10000>& flags() const { return flags_; }

    /// Counts over [start, end), where end may be 0x10000.
    CoverageCounts counts(uint32_t start, uint32_t end) const;

    /// Writes the 65536-byte map: one flag byte per address, which is also a
    /// SkoolKit code map (see the note at the top). Addresses outside
    /// [start, end) are written as zero, so a map can be narrowed to the
    /// region a program was loaded into without the ROM's own coverage
    /// leaking into the disassembly. Returns "" on success, else the error.
    std::string write(const std::string& path, uint32_t start, uint32_t end) const;

private:
    std::array<uint8_t, 0x10000> flags_{};
};

} // namespace zx
