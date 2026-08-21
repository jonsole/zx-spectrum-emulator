//! ULA: screen decode, border color, and frame interrupt timing. Ported
//! directly from `zxspectrum/core/ula.py` -- same "functionally-correct
//! decode of the display file, not a cycle-perfect raster model" scope
//! (memory contention / T-state-accurate ULA racing isn't modeled here
//! either).

use crate::memory::{Memory, Spectrum48KMemory};

pub const SCREEN_WIDTH: usize = 256;
pub const SCREEN_HEIGHT: usize = 192;
const BITMAP_BASE: u16 = 0x4000;
const ATTR_BASE: u16 = 0x5800;

/// 48K Spectrum: one interrupt per frame at ~50Hz.
pub const FRAME_TSTATES: u32 = 69888;

fn color(index: u8, bright: bool) -> (u8, u8, u8) {
    let level: u8 = if bright { 0xFF } else { 0xCD };
    let r = if index & 0b010 != 0 { level } else { 0 };
    let g = if index & 0b100 != 0 { level } else { 0 };
    let b = if index & 0b001 != 0 { level } else { 0 };
    (r, g, b)
}

/// Address of the byte holding column `x` (rounded to its 8-pixel group),
/// row `y`. Ported directly from `ula.py`'s `pixel_addr`.
pub fn pixel_addr(x: u16, y: u16) -> u16 {
    BITMAP_BASE
        | ((y & 0b11000000) << 5)
        | ((y & 0b00000111) << 8)
        | ((y & 0b00111000) << 2)
        | (x >> 3)
}

pub fn attr_addr(x: u16, y: u16) -> u16 {
    let col = x >> 3;
    let row = y >> 3;
    ATTR_BASE + row * 32 + col
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Ula {
    pub border: u8,
    pub flash_state: bool,
}

impl Ula {
    /// Decodes the display file into a flat RGB buffer
    /// (`SCREEN_HEIGHT * SCREEN_WIDTH * 3` bytes, row-major).
    pub fn decode_screen(&self, mem: &mut Spectrum48KMemory) -> Vec<u8> {
        let mut out = vec![0u8; SCREEN_HEIGHT * SCREEN_WIDTH * 3];
        for y in 0..SCREEN_HEIGHT as u16 {
            for cx in 0..32u16 {
                let x = cx * 8;
                let pixel_byte = mem.read(pixel_addr(x, y));
                let attr = mem.read(attr_addr(x, y));
                let mut ink = attr & 0x07;
                let mut paper = (attr >> 3) & 0x07;
                let bright = attr & 0x40 != 0;
                let flash = attr & 0x80 != 0;
                if flash && self.flash_state {
                    std::mem::swap(&mut ink, &mut paper);
                }
                let ink_rgb = color(ink, bright);
                let paper_rgb = color(paper, bright);
                for bit in 0..8u16 {
                    let on = pixel_byte & (0x80 >> bit) != 0;
                    let rgb = if on { ink_rgb } else { paper_rgb };
                    let px = (x + bit) as usize;
                    let idx = (y as usize * SCREEN_WIDTH + px) * 3;
                    out[idx] = rgb.0;
                    out[idx + 1] = rgb.1;
                    out[idx + 2] = rgb.2;
                }
            }
        }
        out
    }
}
