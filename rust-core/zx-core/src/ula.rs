//! ULA: screen rendering, border color, and frame interrupt timing.
//!
//! Screen rendering is genuinely T-state-synced -- `tick()` is called once
//! per real T-state (from `Spectrum48K::tick()`) and reads
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
//! The rendered output also includes the border, tracked at the SAME
//! per-8-pixel-group granularity real hardware actually updates it at: the
//! border output register can be written by software at any T-state, but
//! the ULA only latches a new value at 8-pixel (4-T-state) boundaries --
//! the group of 8 pixels already being drawn finishes in whatever color
//! was latched at ITS OWN start, and a write mid-group doesn't take visual
//! effect until the next one. So this is tracked per PIXEL, not per line
//! or per T-state, in a full-canvas bitmap alongside the paper framebuffer
//! (see `border_pixels`/`tick`'s latch-and-mark logic). Geometry is
//! sourced from the classic World of Spectrum 48K technical reference
//! (<https://worldofspectrum.org/faq/reference/48kreference.htm>): a frame
//! is 312 scanlines (64 top border, 192 paper, 56 bottom border); each
//! 224-T-state line is 24 T-states left border, 128 paper (256px @ 2
//! px/T-state), 24 T-states right border, 48 T-states horizontal retrace
//! (not rendered) -- so the visible border is 48px on every side.

use crate::memory::{Memory, Spectrum48KMemory};
use crate::pins::INT;

// ---- screen/border rendering + frame geometry -----------------------------

/// T-state (relative to the start of the current frame, i.e. `Spectrum48K
/// ::tstates`) of the first paper pixel of the first visible line --
/// 64 lines (the top border) * 224 T-states/line.
pub const FIRST_PAPER_TSTATE: u32 = 224 * 64;
/// T-states per scanline (48K).
pub const LINE_TSTATES: u32 = 224;
/// Of each line's 224 T-states, the first 128 are the ULA's own
/// bitmap/attribute fetch window; the remaining 96 (border + horizontal
/// retrace) aren't fetched.
pub const PAPER_TSTATES_PER_LINE: u32 = 128;
/// Visible scanlines.
pub const VISIBLE_LINES: u32 = 192;

pub const SCREEN_WIDTH: usize = 256;
pub const SCREEN_HEIGHT: usize = 192;
const BITMAP_BASE: u16 = 0x4000;
const ATTR_BASE: u16 = 0x5800;
const FRAME_BYTES: usize = SCREEN_HEIGHT * SCREEN_WIDTH * 3;

/// 48K Spectrum: one interrupt per frame at ~50Hz.
pub const FRAME_TSTATES: u32 = 69888;

/// Visible border width/height, each side -- see the module doc comment
/// for the source. `BORDER_LEFT_PX`/`BORDER_RIGHT_PX` are in pixels (24
/// T-states * 2px/T-state each); `BORDER_TOP_LINES`/`BORDER_BOTTOM_LINES`
/// are whole scanlines.
pub const BORDER_LEFT_PX: usize = 48;
pub const BORDER_RIGHT_PX: usize = 48;
pub const BORDER_TOP_LINES: usize = 64;
pub const BORDER_BOTTOM_LINES: usize = 56;
/// Total scanlines/frame (48K): 64 + 192 + 56.
pub const TOTAL_LINES: usize = BORDER_TOP_LINES + SCREEN_HEIGHT + BORDER_BOTTOM_LINES;
/// `screen()`'s actual output width/height, border included.
pub const FULL_SCREEN_WIDTH: usize = BORDER_LEFT_PX + SCREEN_WIDTH + BORDER_RIGHT_PX;
pub const FULL_SCREEN_HEIGHT: usize = TOTAL_LINES;
const FULL_PIXEL_COUNT: usize = FULL_SCREEN_WIDTH * FULL_SCREEN_HEIGHT;
const FULL_FRAME_BYTES: usize = FULL_PIXEL_COUNT * 3;

const LEFT_BORDER_TSTATES: u32 = (BORDER_LEFT_PX / 2) as u32;
const RIGHT_BORDER_TSTATES: u32 = (BORDER_RIGHT_PX / 2) as u32;
/// T-states/line actually rendered (left border + paper/border-content +
/// right border) -- the remaining T-states of each 224-T-state line are
/// horizontal retrace, never rendered.
const VISIBLE_LINE_TSTATES: u32 = LEFT_BORDER_TSTATES + (SCREEN_WIDTH as u32) / 2 + RIGHT_BORDER_TSTATES;
/// How many T-states the ULA latches a border-output write for before a
/// newer one can take visual effect -- 8 pixels @ 2px/T-state.
const BORDER_LATCH_TSTATES: u32 = 4;

/// The T-state (mod `FRAME_TSTATES`) of the top-left corner pixel of the
/// FULL rendered canvas (start of the first top-border line's own left
/// border) -- `FIRST_PAPER_TSTATE` is the first PAPER
/// pixel specifically; this is that same reference shifted back by one
/// left-border-width and `BORDER_TOP_LINES` whole lines, wrapped mod
/// `FRAME_TSTATES` since that lands before T-state 0 (the interrupt point
/// isn't defined to coincide with a raster line boundary -- it doesn't
/// need to, they're both just measured against the same master clock).
/// Adding `FRAME_TSTATES` before subtracting keeps every intermediate
/// value non-negative for unsigned arithmetic.
///
/// Note this lands late within a given `Spectrum48K::tstates` sweep (close
/// to `FRAME_TSTATES`, not close to 0) -- the interrupt (`tstates == 0`)
/// fires partway through vertical blanking, not at the top-left of the
/// picture, so raster position and interrupt-relative T-state count are
/// two different phase references over the same clock. Concretely: as
/// `tstates` counts 0..=FRAME_TSTATES-1 once, the raster (canvas-relative,
/// "shifted") position it corresponds to starts partway through row 0,
/// climbs to the bottom-right corner, and only wraps back to the actual
/// top-left corner (shifted == 0) in the last ~25 T-states of that same
/// sweep. Code reasoning about "when in the picture" something happens
/// (e.g. tests) should convert through this constant rather than assuming
/// `tstates` itself counts up from the top-left.
pub const FRAME_TOP_LEFT_TSTATE: u32 = (FIRST_PAPER_TSTATE + FRAME_TSTATES
    - LEFT_BORDER_TSTATES
    - (BORDER_TOP_LINES as u32) * LINE_TSTATES)
    % FRAME_TSTATES;

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

/// How long the 48K ULA pulls INT low, once per frame -- purely a
/// function of raster position, not CPU behavior: the ULA doesn't know or
/// care whether the CPU ever accepts it, so the line isn't extended,
/// re-armed, or suppressed for any reason (including how recently the
/// machine itself was constructed -- a fresh instance's `tstate == 0` is
/// just as much "within the pulse window" as any other frame's, matching
/// real hardware, where interrupt timing isn't synced to CPU reset at all
/// -- the 48K ROM's own first instruction is `DI` specifically because an
/// interrupt can arrive before software is ready for one).
const INT_PULSE_TSTATES: u32 = 32;
/// One entry per 8-T-state group in a frame (`FRAME_TSTATES / 8`).
const GROUPS_PER_FRAME: usize = (FRAME_TSTATES / 8) as usize;

/// What the ULA is doing during one 8-T-state group: whether the INT line
/// is held low, and whether the raster beam is over the border/retrace
/// area or actively fetching paper -- precomputed once (the geometry is
/// the same every frame) instead of re-deriving `scan_line`/`scan_offset`
/// bounds checks and `pixel_addr`/`attr_addr`'s bit-shuffling on every
/// single `tick()` call. A plain struct with an `is_paper` flag rather
/// than an enum: `line`/`cell0`/`pixel_base`/`attr_base` are simply
/// unused (left zeroed) when `is_paper` is false.
struct GroupAction {
    int: bool,
    is_paper: bool,
    line: usize,
    cell0: u16,
    /// Cell0's own fetch addresses -- cell1's are `+1` (both
    /// `pixel_addr`/`attr_addr` are contiguous across two
    /// horizontally-adjacent cells on the same row, so the second cell's
    /// bytes never need their own call).
    pixel_base: u16,
    attr_base: u16,
}

/// `GROUPS_PER_FRAME` is fixed at compile time, so this returns a
/// fixed-size array, not a `Vec` -- but heap-allocated (`Box<[T; N]>`),
/// not a plain `[T; N]`: at ~140KB (`GroupAction` * 8736 entries), building
/// that as a stack value first (as a bare array would) risks overflowing
/// a constrained stack, e.g. the tokio task this ends up running under in
/// `zx-engine`. Built via a `Vec` (heap-allocated from the start) and
/// converted at the end, so the full array is never a stack value.
fn build_group_actions() -> Box<[GroupAction; GROUPS_PER_FRAME]> {
    let mut actions = Vec::with_capacity(GROUPS_PER_FRAME);
    for group in 0..GROUPS_PER_FRAME as u32 {
        let tstate = group * 8;
        let int = tstate < INT_PULSE_TSTATES;

        let scan_line = tstate / LINE_TSTATES;
        let scan_offset = tstate % LINE_TSTATES;
        let is_paper = scan_line >= BORDER_TOP_LINES as u32
            && scan_line < (BORDER_TOP_LINES + SCREEN_HEIGHT) as u32
            && scan_offset < PAPER_TSTATES_PER_LINE;

        let mut line = 0usize;
        let mut cell0 = 0u16;
        let mut pixel_base = 0u16;
        let mut attr_base = 0u16;
        if is_paper {
            line = (scan_line - BORDER_TOP_LINES as u32) as usize;
            cell0 = ((scan_offset / 8) * 2) as u16;
            let y = line as u16;
            pixel_base = pixel_addr(cell0 * 8, y);
            attr_base = attr_addr(cell0 * 8, y);
        }

        actions.push(GroupAction { int, is_paper, line, cell0, pixel_base, attr_base });
    }
    match actions.into_boxed_slice().try_into() {
        Ok(array) => array,
        Err(_) => panic!("built {GROUPS_PER_FRAME} group actions but the array conversion length didn't match"),
    }
}

pub struct Ula {
    pub border: u8,
    pub flash_state: bool,

    /// Being built up as the current frame's T-states advance.
    framebuffer: Vec<u8>,
    /// The last FULLY completed frame -- what `screen()` returns.
    last_frame: Vec<u8>,
    /// Bytes fetched so far within the current 8-T-state group: pixel(N),
    /// attr(N), pixel(N+1), attr(N+1) -- see the module doc comment and
    /// `tick`'s own doc comment for the fetch order this mirrors.
    fetch: [u8; 4],

    /// Border color latched in for each pixel of the FULL canvas (border
    /// region only meaningfully; paper-region entries are written too but
    /// always overwritten by the paper paste in `screen()`) -- see
    /// `tick`'s doc comment for the latch-every-8-pixels behavior
    /// this mirrors. Row-major over the FULL canvas
    /// (`y * FULL_SCREEN_WIDTH + x`).
    border_pixels: Vec<u8>,
    border_pixels_last: Vec<u8>,
    /// The border value latched at the start of the 8-pixel group
    /// currently being drawn -- refreshed every `BORDER_LATCH_TSTATES`
    /// T-states, held steady in between regardless of how many times
    /// software writes `border` mid-group.
    border_latch: u8,

    /// `GROUPS_PER_FRAME`-entry lookup table, indexed by `tstate / 8` --
    /// see `GroupAction`'s own doc comment.
    group_actions: Box<[GroupAction; GROUPS_PER_FRAME]>,
}

impl Default for Ula {
    fn default() -> Self {
        Ula {
            border: 0,
            flash_state: false,
            framebuffer: vec![0u8; FRAME_BYTES],
            last_frame: vec![0u8; FRAME_BYTES],
            fetch: [0; 4],
            border_pixels: vec![0; FULL_PIXEL_COUNT],
            border_pixels_last: vec![0; FULL_PIXEL_COUNT],
            border_latch: 0,
            group_actions: build_group_actions(),
        }
    }
}

impl Ula {
    /// Clears rendering state for a fresh reset or snapshot load.
    /// Deliberately leaves `border`/`flash_state` untouched -- neither was
    /// touched by `Spectrum48K::reset()` before this feature existed.
    pub fn clear_frame_state(&mut self) {
        self.framebuffer.fill(0);
        self.last_frame.fill(0);
        self.fetch = [0; 4];
        self.border_pixels.fill(0);
        self.border_pixels_last.fill(0);
        self.border_latch = 0;
    }

    /// Called once per real T-state slot from `Spectrum48K::tick()` -- the
    /// per-T-state screen-fetch/border hook. Also sets/clears `pins`' own
    /// INT bit directly (the real ULA is what drives that line, not the
    /// CPU), from the same `group_actions` lookup as the border/paper
    /// decision.
    ///
    /// Mirrors the fetch order confirmed against
    /// <https://github.com/r-lyeh/Spectral>'s `src/zx_ula.h` during this
    /// feature's research: within each 8-T-state group (16 of which make
    /// up a line's 128-T-state paper window), offset 0 fetches this
    /// group's first cell's pixel byte, offset 1 its attribute byte,
    /// offset 2 the second cell's pixel byte, offset 3 its attribute byte
    /// -- and immediately draws both cells' 16 pixels using the four
    /// just-fetched bytes. Offsets 4-7 are idle.
    pub fn tick(&mut self, tstate: u32, pins: &mut u64, mem: &mut Spectrum48KMemory) {
        let action = &self.group_actions[(tstate / 8) as usize];
        if action.int {
            *pins |= INT;
        } else {
            *pins &= !INT;
        }

        if !action.is_paper {
            // Border/retrace: latch and mark a border pixel (or no-op
            // during horizontal retrace, which isn't rendered at all --
            // see `mark_border_tstate`'s own doc comment).
            self.mark_border_tstate(tstate);
            return;
        }
        let line = action.line;
        let cell0 = action.cell0;
        let pixel_base = action.pixel_base;
        let attr_base = action.attr_base;

        // Active display: work out where in this 8-T-state group we are
        // and handle that one cycle (fetch and, on the 4th, render both
        // cells' pixels -- see the fetch-order doc above).
        match tstate % 8 {
            0 => self.fetch[0] = mem.read(pixel_base),
            1 => self.fetch[1] = mem.read(attr_base),
            2 => self.fetch[2] = mem.read(pixel_base + 1),
            3 => {
                self.fetch[3] = mem.read(attr_base + 1);
                let (p0, a0, p1, a1) = (self.fetch[0], self.fetch[1], self.fetch[2], self.fetch[3]);
                self.draw_cell(line, cell0, p0, a0);
                self.draw_cell(line, cell0 + 1, p1, a1);
            }
            _ => {}
        }
    }

    /// Latches `border` into `border_latch` at the start of every 8-pixel
    /// (`BORDER_LATCH_TSTATES`-T-state) group, then records that latched
    /// value for whichever pixel(s) of the FULL canvas the raster beam is
    /// at during `tstate` -- covering every rendered T-state of every one
    /// of the frame's 312 lines (top/bottom border-only lines included,
    /// not just the 192 paper ones), using `FRAME_TOP_LEFT_TSTATE` as the
    /// shared reference point so this lines up exactly with where
    /// `tick`'s own paper-fetch logic (above) puts the paper
    /// rectangle. A no-op during horizontal retrace (not rendered).
    fn mark_border_tstate(&mut self, tstate: u32) {
        let shifted = (tstate + FRAME_TSTATES - FRAME_TOP_LEFT_TSTATE) % FRAME_TSTATES;
        let shifted_line = (shifted / LINE_TSTATES) as usize;
        let shifted_offset = shifted % LINE_TSTATES;

        if shifted_offset % BORDER_LATCH_TSTATES == 0 {
            self.border_latch = self.border;
        }
        if shifted_offset >= VISIBLE_LINE_TSTATES {
            return; // horizontal retrace -- not rendered
        }
        let x0 = (shifted_offset * 2) as usize;
        for dx in 0..2usize {
            if let Some(slot) = self.border_pixels.get_mut(shifted_line * FULL_SCREEN_WIDTH + x0 + dx) {
                *slot = self.border_latch;
            }
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

    /// Swaps the in-progress framebuffer into the "last complete frame"
    /// slot (zero-alloc -- reuses the existing buffer) and starts a fresh
    /// one for the next frame. Called from `Spectrum48K::tick()`'s
    /// frame-wraparound branch.
    pub fn on_frame_boundary(&mut self) {
        std::mem::swap(&mut self.framebuffer, &mut self.last_frame);
        self.framebuffer.fill(0);
        std::mem::swap(&mut self.border_pixels, &mut self.border_pixels_last);
    }

    /// The last fully completed frame, WITH the border, as a flat RGB
    /// buffer (`FULL_SCREEN_HEIGHT * FULL_SCREEN_WIDTH * 3` bytes,
    /// row-major) -- the border filled per-pixel from `border_pixels_last`
    /// (see `mark_border_tstate`), with the paper (`paper_screen()`)
    /// pasted on top in the middle (overwriting whatever `border_pixels`
    /// happened to record for that same rectangle, which doesn't matter --
    /// the paper fetch always owns those pixels).
    pub fn screen(&self) -> Vec<u8> {
        let paper = self.paper_screen();
        let mut out = vec![0u8; FULL_FRAME_BYTES];
        for i in 0..FULL_PIXEL_COUNT {
            let (r, g, b) = color(self.border_pixels_last[i] & 0x07, false);
            let idx = i * 3;
            out[idx] = r;
            out[idx + 1] = g;
            out[idx + 2] = b;
        }
        for y in 0..SCREEN_HEIGHT {
            let full_y = BORDER_TOP_LINES + y;
            let src_row = y * SCREEN_WIDTH * 3;
            let dst_row = (full_y * FULL_SCREEN_WIDTH + BORDER_LEFT_PX) * 3;
            out[dst_row..dst_row + SCREEN_WIDTH * 3]
                .copy_from_slice(&paper[src_row..src_row + SCREEN_WIDTH * 3]);
        }
        out
    }

    /// The last fully completed frame's PAPER area only (no border) as a
    /// flat RGB buffer (`SCREEN_HEIGHT * SCREEN_WIDTH * 3` bytes,
    /// row-major) -- `screen()`'s own building block.
    fn paper_screen(&self) -> Vec<u8> {
        self.last_frame.clone()
    }
}
