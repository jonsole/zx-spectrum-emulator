#pragma once
// Logpoints: places in the code that report rather than stop. When the
// instruction at a logpoint's address is about to run, its message is filled
// in from the machine -- registers, bytes in memory -- and handed on, and the
// run carries on as if nothing had happened.
//
// A message is text with holes in braces, parsed once when the logpoint is
// set so that a hit only has to look values up:
//
//   {A}          a register, by any name register_names knows (A, HL, IX, AF')
//   {(HL)}       the byte at the address in a register pair
//   {(0x5C00)}   the byte at an address: 0x.., $.. or decimal
//   {(LABEL)}    the byte at a symbol's address, resolved when it is set
//   {(IX+5)}     either of the last three, with an offset
//   {...:d}      decimal rather than hex; :c a character; :w (memory only)
//                the little-endian word there rather than the byte, and :wd
//                that word in decimal
//   {{ and }}    a brace
//
// Hex is written 0x5A or 0x805A, the width of what was read. A character is
// itself if printable, a newline for 0x0D, and \xNN otherwise.

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace zx {

class Spectrum;

/// One piece of a parsed message: literal text, or a value to look up.
struct LogSegment {
    enum class Kind : uint8_t { Text, Register, Memory };
    Kind kind = Kind::Text;
    /// Text: the literal. Register: the register's name. Memory: the register
    /// pair holding the address, or empty for a fixed one.
    std::string text;
    /// Memory: the fixed address, or the offset added to the register's value.
    uint16_t addr = 0;
    /// Memory: a little-endian word rather than a byte.
    bool word = false;
    /// 'x' hex, 'd' decimal, 'c' a character.
    char format = 'x';
};

/// Turns a symbol into an address, or says it cannot.
using SymbolResolver = std::function<bool(const std::string& name, uint16_t& addr)>;

/// Parses `text` into `out`. False, with `error` saying why, for a message
/// with an unclosed brace, a register that does not exist, or a symbol
/// `resolve` does not know.
bool parse_log_message(const std::string& text, const SymbolResolver& resolve,
                       std::vector<LogSegment>& out, std::string& error);

/// The message as the machine now makes it. Reads memory without touching the
/// bus, the way a debugger does, so a logpoint trips no watchpoint.
std::string format_log_message(const std::vector<LogSegment>& message, Spectrum& m);

} // namespace zx
