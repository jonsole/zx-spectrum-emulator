#pragma once
// sjasmplus SLD debug data: address <-> source line, and named symbols.
// Ported from rust-core/zx-server/src/rom_source.rs.
//
// Used for both the commented ROM disassembly (built by
// scripts/build_rom_source.py) and for an arbitrary user-assembled program's
// own SLD, attached at runtime via the DAP `launch` request's sld/asm args or
// the MCP load_debug_info tool.
//
// The ROM's own copy is gitignored (the disassembly is copyrighted), so
// loading it is optional -- everything here degrades to "no symbols" rather
// than failing when it is absent.
//
// SLD is sjasmplus's pipe-delimited format, one record per line:
//   file|line|definition_file|definition_line|page|address|type|data
// `type` is a single letter: T (an instruction -- address<->line, unnamed),
// F (a global label, with `data` as the name), D (an EQU'd constant or
// system-variable address), L (display/scope flags for the preceding D/F),
// Z (device/page header). T, F and D are used here; L and Z carry no
// address<->line information of their own.

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace zx {

/// Bounds symbol_at()'s "nearest label at or before" match to a plausible
/// routine/table size. Without it, any address past the highest label in a
/// source (say a RAM address when only the 16K ROM source is loaded) would
/// still match that source's very last label with a huge, meaningless offset.
constexpr uint16_t SYMBOL_MAX_OFFSET = 0xFF;

/// One parsed SLD file, plus the .asm it describes.
class RomSource {
public:
    std::string asm_path;
    std::unordered_map<uint32_t, uint16_t> line_to_addr;
    std::unordered_map<uint16_t, uint32_t> addr_to_line;
    std::map<std::string, uint16_t> symbols;

    /// How far below a requested line to look for a real instruction. A
    /// clicked line often has no code of its own -- a label ("START:"), a
    /// blank, or a routine's header comment block -- and the instruction it
    /// evidently means is the next one down. Bounded so a click in open space
    /// near the end of a file cannot teleport a breakpoint somewhere
    /// unrelated; past this the line is simply reported unverified.
    static constexpr uint32_t MAX_BREAKPOINT_NUDGE = 50;

    /// Address for a source line, nudging forward past lines with no
    /// instruction of their own. `actual_line` comes back as the line the
    /// address really belongs to, which DAP expects a client to move its
    /// marker to. False if nothing within MAX_BREAKPOINT_NUDGE has code.
    bool addr_for_line(uint32_t line, uint16_t& addr, uint32_t& actual_line) const;

    /// The nearest label at or before `addr`, with its offset -- three bytes
    /// into routine FOO gives ("FOO", 3). False if `addr` precedes every
    /// known label, or if `max_offset` is exceeded (pass NO_MAX for an
    /// unbounded search).
    static constexpr int32_t NO_MAX = -1;
    bool symbol_at(uint16_t addr, int32_t max_offset, std::string& name, uint16_t& offset) const;

    /// Rebuilds the address-sorted index. Call after filling the maps.
    void index();

private:
    // Parallel arrays sorted by address, for the binary search symbol_at does.
    std::vector<uint16_t> sorted_addrs_;
    std::vector<std::string> sorted_names_;
};

using RomSourcePtr = std::shared_ptr<const RomSource>;

/// Parses an explicit sld/asm pair. Unlike the ROM source, this is an
/// explicit user action, so a missing file is an error rather than silence.
/// Returns null and fills `error` on failure.
RomSourcePtr load_source(const std::string& sld_path, const std::string& asm_path,
                         std::string& error);

/// The ROM disassembly in `directory` (rom.asm + rom.sld), or null if it has
/// not been built. Cached and re-parsed only when either file's modification
/// time changes, so a rebuild is picked up by a long-running server without
/// re-parsing ~9000 records on every request.
RomSourcePtr get_rom_source(const std::string& directory);

/// One candidate for a partly-typed symbol name. Enough to offer it and to
/// show what it would resolve to, which is the difference between a list of
/// names and a useful one.
struct SymbolMatch {
    std::string name;
    uint16_t addr = 0;
};

/// The currently-loaded program's own debug info, plus the always-available
/// ROM disassembly, with the resolution helpers the DAP and MCP servers both
/// need. Deliberately NOT part of Engine: source and symbol parsing is
/// file-based debug tooling, not machine state.
class Sources {
public:
    explicit Sources(std::string rom_dir) : rom_dir_(std::move(rom_dir)) {}

    /// Attaches a program's own debug info. False and fills `error` if the
    /// files cannot be read.
    bool load_debug_info(const std::string& sld_path, const std::string& asm_path,
                         std::string& error);
    void clear_debug_info();
    RomSourcePtr debug_info() const;

    /// Sources in priority order: whatever program is loaded first, then the
    /// ROM's own -- so a call from that program into a ROM routine still
    /// resolves once the program's source has no mapping for the address.
    std::vector<RomSourcePtr> active() const;

    /// Nearest label at or before `addr`, bounded by SYMBOL_MAX_OFFSET.
    /// Unlike an exact lookup this does not require landing on a label, so a
    /// disassembled operand pointing partway into a routine still annotates.
    bool resolve_symbol(uint16_t addr, std::string& name, uint16_t& offset) const;

    /// Exact-address match only -- for the Disassembly View's label column,
    /// which should head a line only when the instruction IS the start of a
    /// named routine, not merely near one.
    bool label_at(uint16_t addr, std::string& name) const;

    /// A named symbol's address, searching the loaded program's own symbols
    /// before the ROM's. Exact match first, then case-insensitively -- a
    /// caller typing `key_scan` for `KEY_SCAN` has not made an interesting
    /// mistake, and no source here defines two labels differing only in case.
    bool symbol_value(const std::string& name, uint16_t& addr) const;

    /// An address written the way a person says one, rather than as a number:
    ///
    ///     KEY_INT          the label's own address
    ///     KEY_INT+9        9 bytes into it
    ///     MASK_INT-2       ...and backwards, wrapping at 64K
    ///     0x0038  $0038  0038      hex, however you like to write it
    ///
    /// The two radix rules are the two the tools already PRINT, so anything
    /// this codebase shows can be pasted straight back in: a bare address is
    /// HEX (the trace's AB column, `--trace-watch`, the disassembly), and an
    /// offset after a symbol is DECIMAL (the trace's Symbol column, which
    /// writes "KEY_INT+9"). Write an offset as 0x.. or $.. for hex.
    ///
    /// A token is looked up as a symbol before being read as a number, so a
    /// label that happens to be spelled in hex digits (BED, FACE) still wins;
    /// write 0xBED for the number. Terms can be chained (A+8-2), which is
    /// mostly a side effect of the parser being a loop, but SYM_B-SYM_A does
    /// give the distance between two labels.
    ///
    /// False and fills `error` with something worth showing a user: an
    /// unknown symbol, a malformed number, or nothing loaded to resolve
    /// against.
    bool parse_address(const std::string& text, uint16_t& addr, std::string& error) const;

    /// Symbols whose name begins with `prefix`, case-insensitively, for a
    /// caller offering completions on a half-typed one. Ordered the way they
    /// should be offered: the loaded program's own symbols before the ROM's,
    /// alphabetically within each, at most `limit` of them. `more` comes back
    /// true when there were others past that, which a caller can say out loud
    /// rather than leaving a truncated list looking complete.
    ///
    /// An empty prefix matches everything, so a field that has just been
    /// focused has somewhere to start. A name already offered by an earlier
    /// source is not offered again: that is the same shadowing symbol_value()
    /// does, and a list holding one name twice would be a list of two
    /// different addresses with nothing to tell them apart.
    std::vector<SymbolMatch> match_symbols(const std::string& prefix, size_t limit,
                                           bool& more) const;

    /// The source describing `path`, matched on the full path or just the
    /// file name (DAP clients are inconsistent about which they send).
    RomSourcePtr source_for_path(const std::string& path) const;

private:
    std::string rom_dir_;
    mutable std::mutex mutex_;
    RomSourcePtr debug_info_;
};

/// Bridges this symbol layer to the trace writer, which lives in zx_core and
/// so cannot see this header -- TraceOptions takes exactly this callback and
/// nothing else from here. Returns "MOVE_WILLY+3", or an empty string when the
/// address resolves to nothing.
///
/// Captures `sources` by reference: it outlives every trace (both are owned by
/// main), and copying it is not possible anyway -- it holds a mutex.
std::function<std::string(uint16_t)> symbol_resolver(Sources& sources);

/// Appends a resolved symbol after every 4-hex-digit address in `text`:
/// "CALL 0x8000" -> "CALL 0x8000 (START)", "LD HL,(0x5C0E)" ->
/// "LD HL,(0x5C0E) (TVDATA)". 8-bit immediates, I/O ports and RST vectors use
/// two digits and so never match, which is what stops this misfiring on them.
std::string annotate_symbols(const std::string& text, const Sources& sources);

} // namespace zx
