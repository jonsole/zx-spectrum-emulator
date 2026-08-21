//! Parses sjasmplus SLD debug data -- ported from `zxspectrum/core/
//! rom_source.py`. Both for the commented ROM disassembly (built by
//! `scripts/build_rom_source.py`, see [`get_rom_source`]) and for an
//! arbitrary user-assembled program's own SLD (see [`load_source`],
//! attached at runtime via the DAP `launch` request's `sld`/`asm` args or
//! the MCP `load_debug_info` tool).
//!
//! The ROM's own copy is gitignored since the disassembly is copyrighted,
//! and loading it is optional: [`load_rom_source`]/[`get_rom_source`]
//! return `None` if the build output doesn't exist -- callers fall back to
//! the addressless behavior they already have.
//!
//! SLD is sjasmplus's pipe-delimited format: one record per line,
//! `file|line|definition_file|definition_line|page|address|type|data`.
//! `type` is a single letter: `T` (an instruction -- address<->line,
//! unnamed), `F` (a global label: `data` is the name), `D` (an EQU'd
//! constant or system-variable address), `L` (display/scope flags for the
//! preceding D/F record), `Z` (device/page header). T, F, and D are used
//! here; L/Z carry no address<->line information of their own.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

pub struct RomSource {
    pub asm_path: PathBuf,
    pub line_to_addr: HashMap<u32, u16>,
    pub addr_to_line: HashMap<u16, u32>,
    pub symbols: HashMap<String, u16>,
    sorted_addrs: Vec<u16>,
    sorted_names: Vec<String>,
}

impl RomSource {
    fn new(
        asm_path: PathBuf,
        line_to_addr: HashMap<u32, u16>,
        addr_to_line: HashMap<u16, u32>,
        symbols: HashMap<String, u16>,
    ) -> Self {
        // Ties (two labels at the same address) break in whatever order
        // `HashMap`'s iteration happens to produce -- unlike Python's dict,
        // which preserves SLD-file insertion order for ties. Harmless here:
        // there's no "correct" choice between two co-located labels, and
        // real SLD files essentially never emit two F/D records for the
        // same address anyway.
        let mut pairs: Vec<(&str, u16)> = symbols.iter().map(|(n, &a)| (n.as_str(), a)).collect();
        pairs.sort_by_key(|&(_, addr)| addr);
        let sorted_addrs = pairs.iter().map(|&(_, a)| a).collect();
        let sorted_names = pairs.iter().map(|&(n, _)| n.to_string()).collect();
        RomSource { asm_path, line_to_addr, addr_to_line, symbols, sorted_addrs, sorted_names }
    }

    /// The nearest label at or before `addr`, with its offset -- e.g.
    /// `addr - 3` inside routine FOO returns `("FOO", 3)`. `None` if `addr`
    /// precedes every known label. `max_offset`, if given, also returns
    /// `None` once the offset is too large to plausibly still be "inside"
    /// that label -- without it, an address far past the highest known
    /// label (e.g. deep into RAM when only a 16K ROM source is loaded)
    /// still matches the last label with a huge, meaningless offset.
    pub fn symbol_at(&self, addr: u16, max_offset: Option<u16>) -> Option<(String, u16)> {
        // `partition_point` on a predicate that's true for a prefix of the
        // (ascending-sorted) slice and false after it: mirrors Python's
        // `bisect.bisect_right(sorted_addrs, addr) - 1` exactly (index of
        // the last element <= addr).
        let i = self.sorted_addrs.partition_point(|&a| a <= addr);
        if i == 0 {
            return None;
        }
        let idx = i - 1;
        let base = self.sorted_addrs[idx];
        let offset = addr - base;
        if let Some(max) = max_offset {
            if offset > max {
                return None;
            }
        }
        Some((self.sorted_names[idx].clone(), offset))
    }
}

/// Parsed decimal SLD address field. Values that don't fit a real 16-bit
/// address (SLD's own doc-comment-flagged case: a D record's address can
/// be "an arbitrary constant rather than a real address, e.g. a bitmask")
/// are treated as unparseable and skipped -- `symbol_at()`'s own `addr` is
/// always a real `u16`, so a constant outside that range could never match
/// a real lookup anyway.
fn parse_addr_field(s: &str) -> Option<u16> {
    s.parse::<i64>().ok().and_then(|v| u16::try_from(v).ok())
}

fn parse_sld(text: &str) -> (HashMap<u32, u16>, HashMap<u16, u32>, HashMap<String, u16>) {
    let mut line_to_addr = HashMap::new();
    let mut addr_to_line = HashMap::new();
    let mut symbols = HashMap::new();

    for raw_line in text.lines() {
        let fields: Vec<&str> = raw_line.split('|').collect();
        if fields.len() < 8 {
            continue;
        }
        let line_s = fields[1];
        let addr_s = fields[5];
        let rec_type = fields[6];
        let data = fields[7];

        if rec_type == "T" {
            let (Ok(line_no), Some(addr)) = (line_s.parse::<u32>(), parse_addr_field(addr_s)) else {
                continue;
            };
            // entry(...).or_insert(...): keep the first mapping if a
            // line/address ever repeats -- shouldn't happen for real T
            // records, but a first-wins rule is a safer default than
            // silently overwriting.
            line_to_addr.entry(line_no).or_insert(addr);
            addr_to_line.entry(addr).or_insert(line_no);
        } else if (rec_type == "F" || rec_type == "D") && !data.is_empty() {
            let Some(addr) = parse_addr_field(addr_s) else {
                continue;
            };
            symbols.insert(data.to_string(), addr);
        }
    }

    (line_to_addr, addr_to_line, symbols)
}

/// Parse an explicit sld/asm pair for an arbitrary assembled program.
/// Unlike [`load_rom_source`], this is an explicit user action (DAP
/// `launch`'s `sld`/`asm` args, or the MCP `load_debug_info` tool), not an
/// automatic optional check -- a missing file returns `Err` rather than
/// `None`, so the caller gets a clear error instead of debugging quietly
/// not working.
pub fn load_source(sld_path: &Path, asm_path: &Path) -> Result<RomSource, String> {
    let text = std::fs::read_to_string(sld_path)
        .map_err(|e| format!("couldn't read SLD {}: {e}", sld_path.display()))?;
    let (line_to_addr, addr_to_line, symbols) = parse_sld(&text);
    Ok(RomSource::new(asm_path.to_path_buf(), line_to_addr, addr_to_line, symbols))
}

pub fn load_rom_source(directory: &Path) -> Option<RomSource> {
    let asm_path = directory.join("rom.asm");
    let sld_path = directory.join("rom.sld");
    if !asm_path.exists() || !sld_path.exists() {
        return None;
    }
    load_source(&sld_path, &asm_path).ok()
}

type CacheKey = (SystemTime, SystemTime);

struct RomSourceCache {
    directory: PathBuf,
    key: CacheKey,
    source: Option<Arc<RomSource>>,
}

static ROM_SOURCE_CACHE: Mutex<Option<RomSourceCache>> = Mutex::new(None);

/// Cached wrapper around [`load_rom_source`], invalidated by rom.asm/
/// rom.sld's mtimes. Shared by both front-ends (DAP and MCP) so a rebuild
/// (e.g. picking up a skoolkid/rom update) while a long-running server
/// process is up is still picked up automatically, without re-parsing the
/// ~9000-record SLD file on every single request either front-end makes.
pub fn get_rom_source(directory: &Path) -> Option<Arc<RomSource>> {
    let asm_path = directory.join("rom.asm");
    let sld_path = directory.join("rom.sld");
    let key = match (std::fs::metadata(&asm_path), std::fs::metadata(&sld_path)) {
        (Ok(a), Ok(s)) => match (a.modified(), s.modified()) {
            (Ok(am), Ok(sm)) => (am, sm),
            _ => return None,
        },
        _ => return None,
    };

    let mut cache = ROM_SOURCE_CACHE.lock().unwrap();
    if let Some(entry) = cache.as_ref() {
        if entry.directory == directory && entry.key == key {
            return entry.source.clone();
        }
    }
    let source = load_rom_source(directory).map(Arc::new);
    *cache = Some(RomSourceCache { directory: directory.to_path_buf(), key, source: source.clone() });
    source
}

/// Shared handle for the currently-loaded program's own debug info (as
/// opposed to the ROM's, which is always available via [`get_rom_source`]
/// and never explicitly loaded/cleared). Mirrors `Engine.debug_info` in the
/// Python reference: deliberately NOT part of `zx_engine::Engine` itself
/// (source/symbol parsing is `std::fs`-based debug tooling, not core CPU/
/// machine state), so this is a small sibling handle `main.rs` constructs
/// once and clones into both the DAP and MCP servers.
#[derive(Clone, Default)]
pub struct DebugInfo(Arc<Mutex<Option<Arc<RomSource>>>>);

impl DebugInfo {
    pub fn load(&self, sld_path: &Path, asm_path: &Path) -> Result<(), String> {
        let source = load_source(sld_path, asm_path)?;
        *self.0.lock().unwrap() = Some(Arc::new(source));
        Ok(())
    }

    pub fn clear(&self) {
        *self.0.lock().unwrap() = None;
    }

    pub fn get(&self) -> Option<Arc<RomSource>> {
        self.0.lock().unwrap().clone()
    }
}

/// Bounds `symbol_at()`'s "nearest label at or before" match to a plausible
/// table/routine size -- without it, any address past the highest label in
/// a source (e.g. RAM addresses once only the 16K ROM source is loaded)
/// would still match that source's very last label with a huge, meaningless
/// offset (see `RomSource::symbol_at`'s doc comment).
pub const SYMBOL_MAX_OFFSET: u16 = 0xFF;

/// The currently-loaded program's own debug info plus the always-available
/// (once built) ROM disassembly, bundled with the resolution helpers both
/// `dap.rs` and `mcp.rs` need -- constructed once in `main.rs` and cloned
/// into both servers, mirroring `Engine.debug_info` plus `dap.py`'s own
/// `_active_sources`/`_resolve_symbol`/`_label_at`/`_source_for_path`.
#[derive(Clone)]
pub struct Sources {
    pub debug_info: DebugInfo,
    pub rom_dir: Arc<PathBuf>,
}

impl Sources {
    pub fn new(debug_info: DebugInfo, rom_dir: PathBuf) -> Self {
        Sources { debug_info, rom_dir: Arc::new(rom_dir) }
    }

    /// Whatever program is currently loaded takes priority over the ROM's
    /// own (always-available) debug info -- so a call from that program
    /// into a ROM routine still resolves once the program's own source has
    /// no mapping for the address.
    pub fn active(&self) -> Vec<Arc<RomSource>> {
        let mut sources = Vec::new();
        if let Some(s) = self.debug_info.get() {
            sources.push(s);
        }
        if let Some(s) = get_rom_source(&self.rom_dir) {
            sources.push(s);
        }
        sources
    }

    /// Same priority as `active()`/`build_frame()`: the loaded program's
    /// own debug info first, ROM as fallback. Unlike an exact-address
    /// lookup, this doesn't require landing exactly on a label -- a
    /// disassembled operand pointing partway into a routine or data table
    /// should still annotate with SYMBOL+offset.
    pub fn resolve_symbol(&self, addr: u16) -> Option<(String, u16)> {
        self.active().iter().find_map(|s| s.symbol_at(addr, Some(SYMBOL_MAX_OFFSET)))
    }

    /// Exact-address match only (`max_offset=0`) -- for the Disassembly
    /// View's "symbol" field, which headers a line with a label when an
    /// instruction IS the start of a named routine, not merely near one
    /// (that's what `resolve_symbol()`'s operand annotation is for).
    pub fn label_at(&self, addr: u16) -> Option<String> {
        self.active().iter().find_map(|s| s.symbol_at(addr, Some(0)).map(|(name, _)| name))
    }

    pub fn source_for_path(&self, path: &str) -> Option<Arc<RomSource>> {
        let target_name = Path::new(path).file_name();
        self.active()
            .into_iter()
            .find(|s| s.asm_path.to_string_lossy() == path || s.asm_path.file_name() == target_name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Same small synthetic SLD (a real excerpt's shape, not the actual
    // copyrighted ROM disassembly) as `tests/test_rom_source.py`'s own
    // fixture -- this module is a mechanical translation of
    // `rom_source.py`, so verifying it against the exact same cases the
    // Python version already proved correct is the right bar.
    const SLD: &str = "\
|SLD.data.version|1
rom.asm|1||0|-1|-1|Z|pages.size:16384,pages.count:4,slots.count:4,slots.adr:0,16384,32768,49152
rom.asm|11||0|-1|23552|D|KSTATE
rom.asm|11||0|-1|23552|L|,KSTATE,,+equ,+used
rom.asm|89||0|0|0|F|START
rom.asm|90||0|0|0|T|
rom.asm|91||0|0|1|T|
rom.asm|104||0|0|8|F|ERROR_1
rom.asm|105||0|0|8|T|
rom.asm|106||0|0|11|T|
";

    fn write_build(dir: &Path) {
        std::fs::write(dir.join("rom.asm"), "; fake asm\n").unwrap();
        std::fs::write(dir.join("rom.sld"), SLD).unwrap();
    }

    fn tmp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("zx-rom-source-test-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn load_rom_source_returns_none_when_build_output_is_missing() {
        let dir = tmp_dir("missing");
        assert!(load_rom_source(&dir).is_none());
    }

    #[test]
    fn load_rom_source_maps_instruction_lines_to_addresses() {
        let dir = tmp_dir("lines");
        write_build(&dir);
        let source = load_rom_source(&dir).unwrap();
        // Only T records (real instructions) contribute -- the D/L/Z
        // records for the KSTATE EQU and the device header must not leak
        // in here.
        let expected_line_to_addr: HashMap<u32, u16> =
            [(90, 0), (91, 1), (105, 8), (106, 11)].into_iter().collect();
        let expected_addr_to_line: HashMap<u16, u32> =
            [(0, 90), (1, 91), (8, 105), (11, 106)].into_iter().collect();
        assert_eq!(source.line_to_addr, expected_line_to_addr);
        assert_eq!(source.addr_to_line, expected_addr_to_line);
    }

    #[test]
    fn load_rom_source_collects_symbols_from_f_and_d_records() {
        let dir = tmp_dir("symbols");
        write_build(&dir);
        let source = load_rom_source(&dir).unwrap();
        let expected: HashMap<String, u16> =
            [("KSTATE".to_string(), 23552), ("START".to_string(), 0), ("ERROR_1".to_string(), 8)]
                .into_iter()
                .collect();
        assert_eq!(source.symbols, expected);
    }

    #[test]
    fn symbol_at_finds_nearest_label_at_or_before_address() {
        let dir = tmp_dir("nearest");
        write_build(&dir);
        let source = load_rom_source(&dir).unwrap();
        assert_eq!(source.symbol_at(0, None), Some(("START".to_string(), 0)));
        assert_eq!(source.symbol_at(1, None), Some(("START".to_string(), 1)));
        assert_eq!(source.symbol_at(8, None), Some(("ERROR_1".to_string(), 0)));
        assert_eq!(source.symbol_at(11, None), Some(("ERROR_1".to_string(), 3)));
    }

    #[test]
    fn symbol_at_max_offset_bounds_how_far_past_a_label_still_counts() {
        let dir = tmp_dir("max-offset");
        write_build(&dir);
        let source = load_rom_source(&dir).unwrap();
        assert_eq!(source.symbol_at(11, Some(3)), Some(("ERROR_1".to_string(), 3)));
        assert_eq!(source.symbol_at(12, Some(3)), None);
    }

    #[test]
    fn symbol_at_returns_none_before_the_first_known_label() {
        let dir = tmp_dir("before-first");
        std::fs::write(dir.join("rom.asm"), "; fake\n").unwrap();
        std::fs::write(dir.join("rom.sld"), "rom.asm|89||0|0|100|F|FOO\n").unwrap();
        let source = load_rom_source(&dir).unwrap();
        assert_eq!(source.symbol_at(50, None), None);
    }
}
