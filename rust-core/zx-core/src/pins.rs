//! Z80 bus pin encoding. Same bit layout as the Python project's
//! `zxspectrum/core/z80.py` (address bits 0-15, data bits 16-23, control
//! lines from bit 24) -- not shared code, just a convention kept
//! consistent across the two independent projects, and already proven
//! correct: `zx-core-conformance`'s `ReferenceCpu` uses this exact layout
//! today to drive the real `z80.h` via FFI.

pub const PIN_M1: u32 = 24;
pub const PIN_MREQ: u32 = 25;
pub const PIN_IORQ: u32 = 26;
pub const PIN_RD: u32 = 27;
pub const PIN_WR: u32 = 28;
pub const PIN_HALT: u32 = 29;
pub const PIN_INT: u32 = 30;
pub const PIN_RESET: u32 = 31;
pub const PIN_NMI: u32 = 32;
pub const PIN_WAIT: u32 = 33;
pub const PIN_RFSH: u32 = 34;

pub const M1: u64 = 1 << PIN_M1;
pub const MREQ: u64 = 1 << PIN_MREQ;
pub const IORQ: u64 = 1 << PIN_IORQ;
pub const RD: u64 = 1 << PIN_RD;
pub const WR: u64 = 1 << PIN_WR;
pub const HALT: u64 = 1 << PIN_HALT;
pub const INT: u64 = 1 << PIN_INT;
pub const RESET: u64 = 1 << PIN_RESET;
pub const NMI: u64 = 1 << PIN_NMI;
pub const WAIT: u64 = 1 << PIN_WAIT;
pub const RFSH: u64 = 1 << PIN_RFSH;

/// Cleared at the start of every `tick()` call so a T-state's control
/// lines never leak into the next one unless that T-state explicitly
/// re-asserts them -- mirrors z80.h's `Z80_CTRL_PIN_MASK`. Deliberately
/// excludes `WAIT` (an external signal the caller controls, must survive
/// untouched) and `HALT`/`INT`/`NMI`/`RESET` (levels, not per-T-state
/// pulses).
pub const CTRL_PIN_MASK: u64 = M1 | MREQ | IORQ | RD | WR | RFSH;

pub fn get_addr(pins: u64) -> u16 {
    (pins & 0xFFFF) as u16
}

pub fn set_addr(pins: u64, addr: u16) -> u64 {
    (pins & !0xFFFF) | addr as u64
}

pub fn get_data(pins: u64) -> u8 {
    ((pins >> 16) & 0xFF) as u8
}

pub fn set_data(pins: u64, data: u8) -> u64 {
    (pins & !0xFF_0000) | ((data as u64) << 16)
}

/// Sets the address bus plus arbitrary extra control-line bits in one go
/// (mirrors z80.h's `_sax` helper).
pub fn set_addr_ctrl(pins: u64, addr: u16, ctrl: u64) -> u64 {
    set_addr(pins, addr) | ctrl
}

/// Sets the address bus, data bus, and extra control-line bits in one go
/// (mirrors z80.h's `_sadx` helper).
pub fn set_addr_data_ctrl(pins: u64, addr: u16, data: u8, ctrl: u64) -> u64 {
    set_data(set_addr(pins, addr), data) | ctrl
}
