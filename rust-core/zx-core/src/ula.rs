//! ULA: screen rendering, border color, contention tracking, and frame
//! interrupt timing.
//!
//! Screen rendering is genuinely T-state-synced -- `on_tstate()` is called
//! once per real T-state (from `Spectrum48K::advance_tstate()`) and reads
//! the bitmap/attribute bytes for whichever character cell the real ULA
//! would be fetching at that exact moment, writing decoded pixels into a
//! live, persistent framebuffer as the frame progresses, rather than
//! decoding the whole display file from a memory snapshot after the fact.
//! This means a mid-frame write to screen memory produces real tearing
//! (part of the picture reflects the byte as it was when the ULA passed
//! over it, part reflects the new value) -- something a snapshot decode
//! can't represent. `screen()` returns the last FULLY COMPLETED frame (not
//! the in-progress one), since `screen_stream`/MCP's `get_screen` poll far
//! slower than the ~50Hz frame rate and want one stable, whole picture.
//!
//! Contention tracking (which scanlines' contended windows a real
//! CPU access actually landed in, and how much delay it cost) is recorded
//! here too and can be rendered as a tint overlay -- see
//! `contention_overlay_enabled` and [`crate::contention`], which has the
//! actual timing tables and their sources. This module owns none of the
//! delay *application* (that's `Spectrum48K::tick()`'s job, since only it
//! can halt the CPU's own clock); it only tracks what happened, for
//! rendering.

use crate::contention::{self, CONTENDED_TSTATES_PER_LINE};
use crate::memory::{Memory, Spectrum48KMemory};

pub const SCREEN_WIDTH: usize = 256;
pub const SCREEN_HEIGHT: usize = 192;
const BITMAP_BASE: u16 = 0x4000;
const ATTR_BASE: u16 = 0x5800;
const FRAME_BYTES: usize = SCREEN_HEIGHT * SCREEN_WIDTH * 3;

/// 48K Spectrum: one interrupt per frame at ~50Hz.
pub const FRAME_TSTATES: u32 = 69888;

/// Per-line contention total (mem or IO) at which the overlay tint
/// saturates -- the pattern's own worst case if EVERY one of a line's 16
/// contended 8-T-state groups incurred the maximum delay (6): `16 * 6`.
/// Real programs essentially never hit this consistently for a whole
/// line, so it's a reasonable "fully lit" reference rather than an
/// empirically-tuned magic number.
const MAX_LINE_CONTENTION: u16 = 16 * 6;

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

pub struct Ula {
    pub border: u8,
    pub flash_state: bool,
    pub contention_overlay_enabled: bool,

    /// Being built up as the current frame's T-states advance.
    framebuffer: Vec<u8>,
    /// The last FULLY completed frame -- what `screen()` returns.
    last_frame: Vec<u8>,
    /// Bytes fetched so far within the current 8-T-state group: pixel(N),
    /// attr(N), pixel(N+1), attr(N+1) -- see the module doc comment and
    /// `on_tstate`'s own doc comment for the fetch order this mirrors.
    fetch: [u8; 4],

    mem_contention: [u16; SCREEN_HEIGHT],
    io_contention: [u16; SCREEN_HEIGHT],
    mem_contention_last: [u16; SCREEN_HEIGHT],
    io_contention_last: [u16; SCREEN_HEIGHT],
}

impl Default for Ula {
    fn default() -> Self {
        Ula {
            border: 0,
            flash_state: false,
            contention_overlay_enabled: false,
            framebuffer: vec![0u8; FRAME_BYTES],
            last_frame: vec![0u8; FRAME_BYTES],
            fetch: [0; 4],
            mem_contention: [0; SCREEN_HEIGHT],
            io_contention: [0; SCREEN_HEIGHT],
            mem_contention_last: [0; SCREEN_HEIGHT],
            io_contention_last: [0; SCREEN_HEIGHT],
        }
    }
}

impl Ula {
    /// Clears rendering/contention state for a fresh reset or snapshot
    /// load. Deliberately leaves `border`/`flash_state` untouched (neither
    /// was touched by `Spectrum48K::reset()` before this feature existed)
    /// and `contention_overlay_enabled` untouched -- a debug preference
    /// set independently via MCP, not part of the emulated machine's own
    /// state, so resetting the machine shouldn't silently turn it off.
    pub fn clear_frame_state(&mut self) {
        self.framebuffer.fill(0);
        self.last_frame.fill(0);
        self.fetch = [0; 4];
        self.mem_contention = [0; SCREEN_HEIGHT];
        self.io_contention = [0; SCREEN_HEIGHT];
        self.mem_contention_last = [0; SCREEN_HEIGHT];
        self.io_contention_last = [0; SCREEN_HEIGHT];
    }

    /// Called once per real T-state (never for a contention "phantom"
    /// tick -- those don't move the ULA's own read schedule forward any
    /// differently than a real one would, since `tstate` already reflects
    /// every T-state, phantom or not). Mirrors the fetch order confirmed
    /// against <https://github.com/r-lyeh/Spectral>'s `src/zx_ula.h`
    /// during this feature's research: within each 8-T-state group (16 of
    /// which make up a line's 128-T-state contended window), offset 0
    /// fetches this group's first cell's pixel byte, offset 1 its
    /// attribute byte, offset 2 the second cell's pixel byte, offset 3
    /// its attribute byte -- and immediately draws both cells' 16 pixels
    /// using the four just-fetched bytes. Offsets 4-7 are idle.
    pub fn on_tstate(&mut self, tstate: u32, mem: &mut Spectrum48KMemory) {
        let Some((line, offset)) = contention::scanline_and_offset(tstate) else {
            return;
        };
        if offset >= CONTENDED_TSTATES_PER_LINE {
            return;
        }
        let group = offset / 8;
        let k = offset % 8;
        let cell0 = (group * 2) as u16;
        let y = line as u16;
        match k {
            0 => self.fetch[0] = mem.read(pixel_addr(cell0 * 8, y)),
            1 => self.fetch[1] = mem.read(attr_addr(cell0 * 8, y)),
            2 => self.fetch[2] = mem.read(pixel_addr((cell0 + 1) * 8, y)),
            3 => {
                self.fetch[3] = mem.read(attr_addr((cell0 + 1) * 8, y));
                let (p0, a0, p1, a1) = (self.fetch[0], self.fetch[1], self.fetch[2], self.fetch[3]);
                self.draw_cell(line, cell0, p0, a0);
                self.draw_cell(line, cell0 + 1, p1, a1);
            }
            _ => {}
        }
    }

    fn draw_cell(&mut self, line: usize, cell: u16, pixel_byte: u8, attr: u8) {
        let mut ink = attr & 0x07;
        let mut paper = (attr >> 3) & 0x07;
        let bright = attr & 0x40 != 0;
        let flash = attr & 0x80 != 0;
        if flash && self.flash_state {
            std::mem::swap(&mut ink, &mut paper);
        }
        let ink_rgb = color(ink, bright);
        let paper_rgb = color(paper, bright);
        let x0 = (cell * 8) as usize;
        for bit in 0..8usize {
            let on = pixel_byte & (0x80 >> bit) != 0;
            let rgb = if on { ink_rgb } else { paper_rgb };
            let idx = (line * SCREEN_WIDTH + x0 + bit) * 3;
            self.framebuffer[idx] = rgb.0;
            self.framebuffer[idx + 1] = rgb.1;
            self.framebuffer[idx + 2] = rgb.2;
        }
    }

    /// Swaps the in-progress framebuffer into `last_frame` (zero-alloc --
    /// reuses the two existing buffers) and starts a fresh contention
    /// tally. Called from `Spectrum48K::advance_tstate()`'s existing
    /// frame-wraparound branch.
    pub fn on_frame_boundary(&mut self) {
        std::mem::swap(&mut self.framebuffer, &mut self.last_frame);
        self.framebuffer.fill(0);
        self.mem_contention_last = self.mem_contention;
        self.io_contention_last = self.io_contention;
        self.mem_contention = [0; SCREEN_HEIGHT];
        self.io_contention = [0; SCREEN_HEIGHT];
    }

    /// Records that a real CPU memory (`is_io=false`) or I/O (`is_io=true`)
    /// access incurred `delay` T-states of contention at `tstate` --
    /// called by `Spectrum48K::tick()` right after it applies that delay.
    /// A no-op for `delay == 0` or a `tstate` outside the visible window
    /// (I/O contention can, in principle, land there too, but has nothing
    /// to attribute to a scanline).
    pub fn record_contention(&mut self, tstate: u32, is_io: bool, delay: u32) {
        if delay == 0 {
            return;
        }
        let Some((line, _)) = contention::scanline_and_offset(tstate) else {
            return;
        };
        let delay = delay.min(u16::MAX as u32) as u16;
        let bucket = if is_io { &mut self.io_contention } else { &mut self.mem_contention };
        bucket[line] = bucket[line].saturating_add(delay);
    }

    /// Sum of memory + IO contention delay T-states over the last fully
    /// completed frame -- a numeric readout even without the visual
    /// overlay (`screen()`).
    pub fn contended_tstates_last_frame(&self) -> u32 {
        let mem: u32 = self.mem_contention_last.iter().map(|&v| v as u32).sum();
        let io: u32 = self.io_contention_last.iter().map(|&v| v as u32).sum();
        mem + io
    }

    /// The last fully completed frame as a flat RGB buffer
    /// (`SCREEN_HEIGHT * SCREEN_WIDTH * 3` bytes, row-major). When
    /// `contention_overlay_enabled`, additively tints each scanline
    /// toward red by how much memory contention it cost and toward
    /// blue by I/O contention, both scaled against [`MAX_LINE_CONTENTION`].
    pub fn screen(&self) -> Vec<u8> {
        if !self.contention_overlay_enabled {
            return self.last_frame.clone();
        }
        let mut out = self.last_frame.clone();
        for y in 0..SCREEN_HEIGHT {
            let mem_boost = tint_boost(self.mem_contention_last[y]);
            let io_boost = tint_boost(self.io_contention_last[y]);
            if mem_boost == 0 && io_boost == 0 {
                continue;
            }
            for x in 0..SCREEN_WIDTH {
                let idx = (y * SCREEN_WIDTH + x) * 3;
                out[idx] = out[idx].saturating_add(mem_boost);
                out[idx + 2] = out[idx + 2].saturating_add(io_boost);
            }
        }
        out
    }
}

fn tint_boost(line_contention: u16) -> u8 {
    let scaled = (line_contention as u32 * 200) / MAX_LINE_CONTENTION as u32;
    scaled.min(200) as u8
}
