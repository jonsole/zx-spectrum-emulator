//! ULA memory/IO contention timing -- pure functions of a T-state number
//! (and, for I/O, a port address), no machine state. New work, not a port:
//! `zxspectrum/core/ula.py` explicitly leaves this unmodeled ("a
//! functionally-correct decode of the display file, not a cycle-perfect
//! raster model"), so there's no reference implementation here, only
//! primary sources (cited per constant below) plus one independent
//! cross-check.
//!
//! The ZX Spectrum's ULA contends the CPU by literally halting its clock
//! for a number of T-states, NOT via the Z80's WAIT pin -- confirmed both
//! by the Sinclair Wiki (link below) and directly by this project's user.
//! That's why these functions only return a *delay count*; the caller
//! (`Spectrum48K::tick()`) applies it by running extra per-T-state
//! bookkeeping without invoking the CPU core at all, never by touching the
//! CPU's own WAIT-pin protocol (which has no lookahead for this anyway --
//! see the doc comment on `Spectrum48K::tick()`).

use std::ops::RangeInclusive;

/// Physical RAM contended by the ULA on a 48K machine (the one page always
/// resident at 0x4000, shared with screen memory). Source:
/// <https://sinclair.wiki.zxnet.co.uk/wiki/Contended_memory>.
pub const CONTENDED_MEM: RangeInclusive<u16> = 0x4000..=0x7FFF;

pub fn is_contended_memory(addr: u16) -> bool {
    CONTENDED_MEM.contains(&addr)
}

/// T-state (relative to the start of the current frame, i.e. `Spectrum48K
/// ::tstates`) at which contention first begins after an interrupt.
/// Source: <https://sinclair.wiki.zxnet.co.uk/wiki/Contended_memory>.
pub const FIRST_CONTENDED_TSTATE: u32 = 14335;
/// T-states per scanline (48K).
pub const LINE_TSTATES: u32 = 224;
/// Of each line's 224 T-states, the first 128 are contended (the ULA's own
/// bitmap/attribute fetch window); the remaining 96 (border + horizontal
/// retrace) never are.
pub const CONTENDED_TSTATES_PER_LINE: u32 = 128;
/// Visible scanlines.
pub const VISIBLE_LINES: u32 = 192;

/// Repeats every 8 T-states across the contended portion of every visible
/// line. Independently cross-validated this session against
/// <https://github.com/r-lyeh/Spectral>'s `src/zx_ula.h`: its own
/// contention check (`Ys = Ts < 6`, stalling one real tick at a time and
/// re-checking) converges to exactly `6 - Ts` for `Ts<6` and `0` for
/// `Ts>=6` -- the same numbers as this table, via a different mechanism
/// (iterative re-check vs. this module's one-shot lookup).
pub const DELAY_PATTERN: [u8; 8] = [6, 5, 4, 3, 2, 1, 0, 0];

/// The contention delay (extra T-states the ULA halts the CPU's clock for)
/// if a memory access happens to land on T-state `tstate` of the current
/// frame -- 0 outside the visible-line window, and 0 during a line's
/// uncontended border/retrace portion. Applies once, on the first T-state
/// of an instruction fetch, memory read, or memory write.
pub fn memory_contention_delay(tstate: u32) -> u32 {
    match scanline_and_offset(tstate) {
        Some((_, offset)) if offset < CONTENDED_TSTATES_PER_LINE => {
            DELAY_PATTERN[(offset % 8) as usize] as u32
        }
        _ => 0,
    }
}

/// `(scanline 0..191, offset-within-line 0..223)` if `tstate` falls within
/// any of the 192 visible lines' full 224-T-state span (border and
/// retrace included, not just the contended sub-portion) -- `None`
/// outside that whole window (vertical border/retrace/interrupt-adjacent
/// T-states). Shared by the contention overlay's row mapping and the ULA
/// screen-fetch schedule, both of which only care "which line" (and, for
/// the fetch schedule, "which T-state within that line").
pub fn scanline_and_offset(tstate: u32) -> Option<(usize, u32)> {
    if tstate < FIRST_CONTENDED_TSTATE {
        return None;
    }
    let elapsed = tstate - FIRST_CONTENDED_TSTATE;
    let line = elapsed / LINE_TSTATES;
    if line >= VISIBLE_LINES as u32 {
        return None;
    }
    Some((line as usize, elapsed % LINE_TSTATES))
}

/// I/O port contention: <https://sinclair.wiki.zxnet.co.uk/wiki/Contended_I/O>,
/// cross-referenced against Spectral's `zx_ula.h` T3/T4 M-cycle table
/// (same four cases, different notation -- see the rust-core plan for the
/// reconciliation note). Each table cell is a sequence of `N:x`/`C:x`
/// segments (`N:x` = x T-states pass with no check; `C:x` = a delay is
/// computed via [`memory_contention_delay`] at the CURRENT running
/// T-state, then x T-states pass before the next segment, if any):
/// - high byte NOT in 0x40-0x7F, low bit set (ordinary port): `N:4`.
/// - high byte NOT in 0x40-0x7F, low bit clear (the classic `0xFE`-shaped
///   port): `N:1, C:3`.
/// - high byte in 0x40-0x7F, low bit clear: `C:1, C:3`.
/// - high byte in 0x40-0x7F, low bit set: `C:1, C:1, C:1, C:1`.
pub fn io_contention_delay(port: u16, tstate: u32) -> u32 {
    let high_contended = (port & 0xC000) == 0x4000;
    let low_clear = port & 1 == 0;

    // Walks the segments of whichever case applies, summing each `C`
    // segment's delay and advancing a running T-state counter by
    // `delay + segment_length` before evaluating the next segment.
    let mut t = tstate;
    let mut total = 0u32;
    let mut check_then_advance = |t: &mut u32, advance: u32| {
        let delay = memory_contention_delay(*t);
        total += delay;
        *t += delay + advance;
    };

    match (high_contended, low_clear) {
        (false, false) => {} // N:4 -- no check at all
        (false, true) => {
            t += 1; // N:1 -- one uncontended T-state passes first, THEN...
            check_then_advance(&mut t, 3); //                          ...C:3
        }
        (true, true) => {
            check_then_advance(&mut t, 1); // C:1, ...
            check_then_advance(&mut t, 3); //      C:3
        }
        (true, false) => {
            for _ in 0..4 {
                check_then_advance(&mut t, 1); // C:1 x4
            }
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_contention_matches_the_documented_pattern_at_the_first_line() {
        let expected = [6u32, 5, 4, 3, 2, 1, 0, 0];
        for (i, &want) in expected.iter().enumerate() {
            let t = FIRST_CONTENDED_TSTATE + i as u32;
            assert_eq!(memory_contention_delay(t), want, "tstate {t}");
        }
    }

    #[test]
    fn memory_contention_pattern_restarts_every_8_tstates() {
        // T=14343 is the 9th T-state of the window (offset 8) -- the
        // pattern's second repeat, back to a delay of 6.
        assert_eq!(memory_contention_delay(FIRST_CONTENDED_TSTATE + 8), 6);
        assert_eq!(memory_contention_delay(FIRST_CONTENDED_TSTATE + 15), 0);
    }

    #[test]
    fn memory_contention_is_zero_outside_the_visible_window() {
        assert_eq!(memory_contention_delay(0), 0);
        assert_eq!(memory_contention_delay(FIRST_CONTENDED_TSTATE - 1), 0);
        // Well past the last visible line (192 lines * 224 T-states).
        assert_eq!(
            memory_contention_delay(FIRST_CONTENDED_TSTATE + VISIBLE_LINES * LINE_TSTATES + 10),
            0
        );
    }

    #[test]
    fn memory_contention_is_zero_during_a_lines_uncontended_border_portion() {
        // Offset 128 is the first T-state of the line's uncontended
        // border/retrace tail (the contended window is only offsets 0-127).
        assert_eq!(memory_contention_delay(FIRST_CONTENDED_TSTATE + CONTENDED_TSTATES_PER_LINE), 0);
    }

    #[test]
    fn scanline_and_offset_finds_the_right_line() {
        assert_eq!(scanline_and_offset(FIRST_CONTENDED_TSTATE), Some((0, 0)));
        assert_eq!(scanline_and_offset(FIRST_CONTENDED_TSTATE + LINE_TSTATES), Some((1, 0)));
        assert_eq!(
            scanline_and_offset(FIRST_CONTENDED_TSTATE + LINE_TSTATES + 5),
            Some((1, 5))
        );
        assert_eq!(scanline_and_offset(0), None);
        assert_eq!(
            scanline_and_offset(FIRST_CONTENDED_TSTATE + VISIBLE_LINES * LINE_TSTATES),
            None
        );
    }

    #[test]
    fn io_contention_ordinary_port_has_no_delay() {
        // High byte 0xFF (not in 0x40-0x7F), low bit set -- e.g. a
        // hypothetical odd, non-ULA port.
        assert_eq!(io_contention_delay(0xFFFF, FIRST_CONTENDED_TSTATE), 0);
    }

    #[test]
    fn io_contention_classic_ula_port_gets_one_check_one_tstate_in() {
        // 0xFE-shaped port (low bit clear), high byte not contended --
        // N:1, C:3: the check happens at tstate+1.
        let delay = io_contention_delay(0xFFFE, FIRST_CONTENDED_TSTATE);
        assert_eq!(delay, memory_contention_delay(FIRST_CONTENDED_TSTATE + 1));
    }

    #[test]
    fn io_contention_high_byte_contended_low_bit_clear_gets_two_checks() {
        // Port 0x40xx, low bit clear -- C:1, C:3: checks at tstate and
        // tstate+delay1+1.
        let t0 = FIRST_CONTENDED_TSTATE;
        let d1 = memory_contention_delay(t0);
        let d2 = memory_contention_delay(t0 + d1 + 1);
        assert_eq!(io_contention_delay(0x40FE, t0), d1 + d2);
        assert!(io_contention_delay(0x40FE, t0) > 0, "should incur real delay at a contended tstate");
    }

    #[test]
    fn io_contention_high_byte_contended_low_bit_set_gets_four_checks() {
        // Port 0x41xx, low bit set -- C:1, C:1, C:1, C:1.
        let t0 = FIRST_CONTENDED_TSTATE;
        let d1 = memory_contention_delay(t0);
        let t1 = t0 + d1 + 1;
        let d2 = memory_contention_delay(t1);
        let t2 = t1 + d2 + 1;
        let d3 = memory_contention_delay(t2);
        let t3 = t2 + d3 + 1;
        let d4 = memory_contention_delay(t3);
        assert_eq!(io_contention_delay(0x41FF, t0), d1 + d2 + d3 + d4);
    }

    #[test]
    fn io_contention_is_zero_outside_the_contended_window_regardless_of_port() {
        assert_eq!(io_contention_delay(0x41FF, 0), 0);
        assert_eq!(io_contention_delay(0x40FE, 0), 0);
    }
}
