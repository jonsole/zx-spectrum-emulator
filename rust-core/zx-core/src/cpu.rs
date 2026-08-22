use crate::alu;
use crate::flags::*;
use crate::generated_dispatch;
use crate::memory::Memory;
use crate::pins::*;
use crate::registers::Registers;

/// Sentinel `step` values for the shared fetch/refresh machine cycle --
/// picked far outside the 0..512 opcode-dispatch range (0..256 unprefixed,
/// 256..512 ED-prefixed) and the 512+ range the code generator allocates
/// for multi-mcycle instructions' extra steps, so they can never collide
/// regardless of how many extra steps get generated.
const STEP_M1_T2: u16 = 0xFFFC;
const STEP_M1_T3: u16 = 0xFFFD;
const STEP_M1_T4: u16 = 0xFFFE;
const STEP_ED_M1_T2: u16 = 0xFFF9;
const STEP_ED_M1_T3: u16 = 0xFFFA;
const STEP_ED_M1_T4: u16 = 0xFFFB;
const STEP_CB_M1_T2: u16 = 0xFFF8;
const STEP_CB_M1_T3: u16 = 0xFFF7;
const STEP_CB_M1_T4: u16 = 0xFFF6;
const STEP_DDFD_M1_T2: u16 = 0xFFF5;
const STEP_DDFD_M1_T3: u16 = 0xFFF4;
const STEP_DDFD_M1_T4: u16 = 0xFFF3;
const STEP_DDFD_D_T1: u16 = 0xFFF2;
const STEP_DDFD_D_T2: u16 = 0xFFF1;
const STEP_DDFD_D_T3: u16 = 0xFFF0;
const STEP_DDFD_D_T4: u16 = 0xFFEF;
const STEP_DDFD_D_T5: u16 = 0xFFEE;
const STEP_DDFD_D_T6: u16 = 0xFFED;
const STEP_DDFD_D_T7: u16 = 0xFFEC;
const STEP_DDFD_D_T8: u16 = 0xFFEB;
const STEP_DDFD_LDHLN_WR_T1: u16 = 0xFFEA;
const STEP_DDFD_LDHLN_WR_T2: u16 = 0xFFE9;
const STEP_DDFD_LDHLN_WR_T3: u16 = 0xFFE8;
// The DD+CB/FD+CB ("DDCB") double-prefix bit-operations form: `DD CB dd
// oo` (displacement byte, then the actual rotate/shift/BIT/RES/SET
// opcode). Numbered sequentially to mirror `Z80_DDFDCB_STEP` (z80.h case
// 1621) through its own 15 T-states (case 1635) exactly.
const STEP_DDFDCB_1: u16 = 0xFFE7;
const STEP_DDFDCB_2: u16 = 0xFFE6;
const STEP_DDFDCB_3: u16 = 0xFFE5;
const STEP_DDFDCB_4: u16 = 0xFFE4;
const STEP_DDFDCB_5: u16 = 0xFFE3;
const STEP_DDFDCB_6: u16 = 0xFFE2;
const STEP_DDFDCB_7: u16 = 0xFFE1;
const STEP_DDFDCB_8: u16 = 0xFFE0;
const STEP_DDFDCB_9: u16 = 0xFFDF;
const STEP_DDFDCB_10: u16 = 0xFFDE;
const STEP_DDFDCB_11: u16 = 0xFFDD;
const STEP_DDFDCB_12: u16 = 0xFFDC;
const STEP_DDFDCB_13: u16 = 0xFFDB;
const STEP_DDFDCB_14: u16 = 0xFFDA;
const STEP_DDFDCB_15: u16 = 0xFFD9;

// Maskable-interrupt acceptance (IM 0/1/2), hand-written the same way as
// the shared fetch/refresh machine cycle above -- not generated, since
// `scripts/generate_z80_dispatch.py` only processes `z80_desc.yml`'s
// unprefixed/ED opcode tables (see its own doc comment), and interrupt
// acceptance is a separate, non-opcode-indexed entry point there
// (`int_im0`/`int_im1`/`int_im2`). Ported directly from those three
// blocks, T-state for T-state -- see `begin_fetch()`'s doc comment for
// where this gets entered, and the individual STEP_INT_* arms below for
// the per-mcycle citations.
const STEP_INT_1: u16 = 0xFFC0;
const STEP_INT_2: u16 = 0xFFC1;
const STEP_INT_3: u16 = 0xFFC2;
const STEP_INT_4: u16 = 0xFFC3;
const STEP_INT_5: u16 = 0xFFC4;
const STEP_INT_6: u16 = 0xFFC5;
const STEP_INT_PUSH_HI_1: u16 = 0xFFC6;
const STEP_INT_PUSH_HI_2: u16 = 0xFFC7;
const STEP_INT_PUSH_HI_3: u16 = 0xFFC8;
const STEP_INT_PUSH_LO_1: u16 = 0xFFC9;
const STEP_INT_PUSH_LO_2: u16 = 0xFFCA;
const STEP_INT_PUSH_LO_3: u16 = 0xFFCB;
const STEP_INT_DONE_IM1: u16 = 0xFFCC;
const STEP_INT_DONE_IM2: u16 = 0xFFCD;
const STEP_INT_VEC_LO_2: u16 = 0xFFCF;
const STEP_INT_VEC_LO_3: u16 = 0xFFD0;
const STEP_INT_VEC_HI_1: u16 = 0xFFD1;
const STEP_INT_VEC_HI_2: u16 = 0xFFD2;
const STEP_INT_VEC_HI_3: u16 = 0xFFD3;
const STEP_INT_VEC_HI_4: u16 = 0xFFD4;

const ED_STEP_BASE: u16 = 256;

/// 256-entry table marking which unprefixed opcodes touch `(HL)` and
/// therefore need the DD/FD displacement-reading sequence
/// (`STEP_DDFD_D_T1..T8`) when prefixed, instead of dispatching straight
/// into the shared 0..256 table. Hand-transcribed directly from
/// `vendor/chips/z80.h`'s own `_z80_indirect_table` (verified there against
/// `z80_desc.yml`'s `flags: {indirect: true}` markings: `LD (HL),r` / `LD
/// r,(HL)` / the ALU-(HL) group / `INC (HL)` / `DEC (HL)` / `LD (HL),n`) --
/// not generator output, since it's a small, fixed, easily-diffed table and
/// the differential tests below verify it directly anyway.
#[rustfmt::skip]
const DDFD_INDIRECT_TABLE: [bool; 256] = {
    const F: bool = false;
    const T: bool = true;
    [
        F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,
        F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,
        F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,
        F,F,F,F,T,T,T,F,F,F,F,F,F,F,F,F,
        F,F,F,F,F,F,T,F,F,F,F,F,F,F,T,F,
        F,F,F,F,F,F,T,F,F,F,F,F,F,F,T,F,
        F,F,F,F,F,F,T,F,F,F,F,F,F,F,T,F,
        T,T,T,T,T,T,F,T,F,F,F,F,F,F,T,F,
        F,F,F,F,F,F,T,F,F,F,F,F,F,F,T,F,
        F,F,F,F,F,F,T,F,F,F,F,F,F,F,T,F,
        F,F,F,F,F,F,T,F,F,F,F,F,F,F,T,F,
        F,F,F,F,F,F,T,F,F,F,F,F,F,F,T,F,
        F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,
        F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,
        F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,
        F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,F,
    ]
};

/// A from-scratch Z80 interpreter, tick-driven: `tick()` advances exactly
/// one T-state and exposes real address/data/control pins each call,
/// mirroring `vendor/chips/z80.h`'s own `z80_tick()` -- including its
/// "overlapped fetch" design, where the next instruction's opcode fetch
/// begins during the current instruction's last T-state. That's a
/// deliberate fidelity choice (needed later for accurate ULA memory-
/// contention timing, which depends on real per-T-state bus activity, not
/// "this instruction took N T-states" as a lump sum) -- see this
/// project's rust-core plan for the full rationale. `step()` remains as a
/// convenience wrapper for callers that just want whole-instruction
/// execution (loops `tick()` + memory-pin servicing internally), so
/// existing call sites don't need to change shape.
#[derive(Debug, Clone, Copy)]
pub struct Cpu {
    pub regs: Registers,
    pub halted: bool,
    /// Position within the current instruction's machine-cycle sequence.
    /// Mirrors `z80.h`'s `cpu->step`: for unprefixed opcodes this equals
    /// the opcode byte itself once dispatched (0 happens to coincide with
    /// NOP, which is also z80.h's own bootstrap convention -- a fresh
    /// `Cpu` or a `set_registers()` reset both start here, and immediately
    /// re-triggers a real fetch since NOP's only action IS "fetch next").
    pub(crate) step: u16,
    pub(crate) opcode: u8,
    pub(crate) dlatch: u8,
    pub(crate) addr: u16,
    pub(crate) prefix_active: bool,
    /// Which register pair `$RY`/`$RZ`/`$HL`/`$RP`-style tokens currently
    /// mean: 0 = HL, 1 = IX, 2 = IY. Mirrors z80.h's `cpu->hlx_idx` /
    /// `cpu->hlx[cpu->hlx_idx]` array-of-three-structs trick exactly, just
    /// via runtime-dispatched accessor methods (`hlx()`/`hlx_h()`/etc,
    /// below) instead of an actual union/array, since Rust's `Registers`
    /// keeps h/l/ix/iy as ordinary separate fields. Reset to 0 by every
    /// plain opcode fetch (mirrors `_z80_fetch()`'s own `hlx_idx = 0`) --
    /// DD/FD prefixes set it to 1/2 for the ONE instruction they prefix;
    /// it does not persist across instruction boundaries.
    pub(crate) hlx_idx: u8,
    /// Pins returned by the most recent `tick()` call, persisted here
    /// purely for `step()`'s own bookkeeping across separate calls (NOT
    /// consulted by `tick()` itself, which stays a pure function of its
    /// `pins` parameter and `self.step`). Needed because of the
    /// overlapped-fetch design: an instruction's last tick already queued
    /// the NEXT opcode's read request, so a later `step()` call must
    /// resume from those exact pins (data bus / WAIT), not a fresh 0 --
    /// otherwise the next opcode fetch would silently read a fake 0x00.
    pins: u64,
}

impl Default for Cpu {
    fn default() -> Self {
        Self {
            regs: Registers::default(),
            halted: false,
            step: 0,
            opcode: 0,
            dlatch: 0,
            addr: 0,
            prefix_active: false,
            hlx_idx: 0,
            pins: 0,
        }
    }
}

impl Cpu {
    pub fn new() -> Self {
        Self::default()
    }

    /// A snapshot of the register file, with `pc` corrected for the
    /// overlapped-fetch pipeline: by the time execution reaches a fresh
    /// instruction boundary, the trailing `overlapped` step has already
    /// fetched the NEXT opcode's first byte (incrementing the raw `pc`
    /// for it), so the raw value reads one past the address this project's
    /// established convention (and every caller -- tests, a future
    /// debugger) expects "the next instruction to execute" to mean.
    /// EXCEPT while halted: real hardware (and this core, deliberately
    /// mirroring it) freezes the visible PC at `halt_addr+1` with no
    /// further look-ahead, so raw pc there already IS the corrected value.
    /// Same rule `zx-core-conformance`'s `ReferenceCpu::registers()`
    /// already applies against the real z80.h, found empirically there
    /// first (see this project's rust-core plan) -- now genuinely needed
    /// here too, since the tick-based rewrite gave this core the same
    /// real pipeline the reference always had.
    pub fn registers(&self) -> Registers {
        let mut regs = self.regs;
        if !self.halted {
            regs.pc = regs.pc.wrapping_sub(1);
        }
        regs
    }

    /// The pins as of the most recent `tick()`/`set_registers()` call --
    /// for callers (like pin-level differential tests) that need to
    /// resume ticking from exactly where a previous call left off.
    pub fn pins(&self) -> u64 {
        self.pins
    }

    /// Sets the register file and redirects the fetch pipeline to the new
    /// `pc`, mirroring `z80_prefetch()` + the one required throwaway
    /// "priming" tick documented on the Python project's own core (the
    /// same overlapped-fetch artifact -- reintroduced here deliberately,
    /// see the struct doc comment). Callers see no pipeline: the next
    /// `tick()`/`step()` call behaves as a clean instruction boundary.
    pub fn set_registers(&mut self, regs: Registers, mem: &mut impl Memory) {
        self.regs = regs;
        self.step = 0;
        self.prefix_active = false;
        // Priming tick -- its T1 request (opcode read at the new pc) MUST
        // be serviced here, not left pending: the next real tick() call
        // processes M1_T2, which reads data straight off the pins this
        // call returns, so an unserviced read would silently hand back
        // whatever data bits happened to be lying around (garbage) as the
        // "opcode" instead of the real byte at the new pc.
        self.pins = Self::service_memory(mem, self.tick(0));
    }

    /// Advances exactly one T-state. `pins` carries the caller's response
    /// to the PREVIOUS tick's bus request (data read onto the bus, or a
    /// WAIT line held for contended memory) and returns the pins for
    /// *this* T-state's transaction.
    pub fn tick(&mut self, pins: u64) -> u64 {
        let result = self.tick_inner(pins);
        if self.halted {
            result | HALT
        } else {
            result
        }
    }

    fn tick_inner(&mut self, pins: u64) -> u64 {
        // Control lines never leak from one T-state into the next unless
        // this T-state explicitly re-asserts them -- see CTRL_PIN_MASK's
        // doc comment.
        let pins = pins & !CTRL_PIN_MASK;
        match self.step {
            STEP_M1_T2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                self.opcode = get_data(pins);
                self.step = STEP_M1_T3;
                pins
            }
            STEP_M1_T3 => {
                let pins = self.refresh(pins);
                self.step = STEP_M1_T4;
                pins
            }
            STEP_M1_T4 => {
                self.addr = self.regs.hl();
                self.prefix_active = false;
                self.step = self.opcode as u16;
                pins
            }
            STEP_ED_M1_T2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                self.opcode = get_data(pins);
                self.step = STEP_ED_M1_T3;
                pins
            }
            STEP_ED_M1_T3 => {
                let pins = self.refresh(pins);
                self.step = STEP_ED_M1_T4;
                pins
            }
            STEP_ED_M1_T4 => {
                self.addr = self.regs.hl();
                self.prefix_active = false;
                self.step = ED_STEP_BASE + self.opcode as u16;
                pins
            }
            STEP_CB_M1_T2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                self.opcode = get_data(pins);
                self.step = STEP_CB_M1_T3;
                pins
            }
            STEP_CB_M1_T3 => {
                let pins = self.refresh(pins);
                self.step = STEP_CB_M1_T4;
                pins
            }
            STEP_CB_M1_T4 => {
                // Real hardware (and z80.h) branches here, before any
                // further ticking, between the register-direct "cb" form
                // (1 T-state, no memory access) and the "(HL)" form
                // (needs a real mread+conditional-mwrite sequence) --
                // decided by the just-fetched CB-suffix opcode's own z
                // field. Both destinations are GENERATED (from the YAML's
                // `cb`/`cbhl` special entries, processed the same way as
                // every other multi-step instruction, not hand-numbered)
                // so they get the same validated step-numbering/
                // `$NEXTSTEP` handling as everything else.
                //
                // `prefix_active` MUST be cleared here, same as the other
                // two T4 handlers -- found missing via a real differential
                // test failure: leaving it stuck true meant
                // `is_instruction_boundary()` never recognized THIS
                // instruction's own completion, so `step()`'s loop
                // silently ran straight through into the NEXT instruction
                // too, merging two instructions into one `step()` call
                // (only "fixed" by the FOLLOWING instruction's own T4
                // resetting the flag, which is why this didn't hang --
                // just quietly executed one instruction too many).
                self.prefix_active = false;
                if self.opcode & 7 == 6 {
                    self.addr = self.regs.hl();
                    self.step = generated_dispatch::CBHL_STEP;
                } else {
                    self.step = generated_dispatch::CB_STEP;
                }
                pins
            }
            STEP_DDFD_M1_T2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                self.opcode = get_data(pins);
                self.step = STEP_DDFD_M1_T3;
                pins
            }
            STEP_DDFD_M1_T3 => {
                let pins = self.refresh(pins);
                self.step = STEP_DDFD_M1_T4;
                pins
            }
            STEP_DDFD_M1_T4 => {
                // Mirrors `Z80_DDFD_M1_T4`: unconditionally point `addr` at
                // IX/IY (even for opcodes that don't use it -- harmless),
                // then either dispatch straight into the shared 0..256
                // table (same table unprefixed opcodes use -- `hlx_idx`
                // alone is what makes it mean IX/IY instead of HL) or, for
                // opcodes touching `(HL)`, detour through the displacement
                // read first.
                self.addr = self.hlx();
                self.prefix_active = false;
                self.step = if DDFD_INDIRECT_TABLE[self.opcode as usize] {
                    STEP_DDFD_D_T1
                } else {
                    self.opcode as u16
                };
                pins
            }
            STEP_DDFD_D_T1 => {
                self.step = STEP_DDFD_D_T2;
                pins
            }
            STEP_DDFD_D_T2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let addr = self.pc_post_inc();
                self.step = STEP_DDFD_D_T3;
                set_addr_ctrl(pins, addr, MREQ | RD)
            }
            STEP_DDFD_D_T3 => {
                let d = get_data(pins) as i8;
                self.addr = self.addr.wrapping_add(d as u16);
                self.regs.wz = self.addr;
                self.step = STEP_DDFD_D_T4;
                pins
            }
            STEP_DDFD_D_T4 => {
                self.step = STEP_DDFD_D_T5;
                pins
            }
            STEP_DDFD_D_T5 => {
                // Only opcode 0x36 (LD (HL),n -> LD (IX/IY+d),n) needs a
                // THIRD immediate byte here; every other indirect opcode
                // just idles this T-state, matching `Z80_DDFD_D_T5`.
                if self.opcode == 0x36 {
                    if pins & WAIT != 0 {
                        return pins;
                    }
                    let addr = self.pc_post_inc();
                    self.step = STEP_DDFD_D_T6;
                    return set_addr_ctrl(pins, addr, MREQ | RD);
                }
                self.step = STEP_DDFD_D_T6;
                pins
            }
            STEP_DDFD_D_T6 => {
                if self.opcode == 0x36 {
                    self.dlatch = get_data(pins);
                }
                self.step = STEP_DDFD_D_T7;
                pins
            }
            STEP_DDFD_D_T7 => {
                self.step = STEP_DDFD_D_T8;
                pins
            }
            STEP_DDFD_D_T8 => {
                self.step = if self.opcode == 0x36 {
                    STEP_DDFD_LDHLN_WR_T1
                } else {
                    self.opcode as u16
                };
                pins
            }
            STEP_DDFD_LDHLN_WR_T1 => {
                self.step = STEP_DDFD_LDHLN_WR_T2;
                pins
            }
            STEP_DDFD_LDHLN_WR_T2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let pins = set_addr_data_ctrl(pins, self.addr, self.dlatch, MREQ | WR);
                self.step = STEP_DDFD_LDHLN_WR_T3;
                pins
            }
            STEP_DDFD_LDHLN_WR_T3 => self.begin_fetch(pins),
            STEP_DDFDCB_1 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let addr = self.pc_post_inc();
                self.step = STEP_DDFDCB_2;
                set_addr_ctrl(pins, addr, MREQ | RD)
            }
            STEP_DDFDCB_2 => {
                let d = get_data(pins) as i8;
                self.addr = self.hlx().wrapping_add(d as u16);
                self.regs.wz = self.addr;
                self.step = STEP_DDFDCB_3;
                pins
            }
            STEP_DDFDCB_3 => {
                self.step = STEP_DDFDCB_4;
                pins
            }
            STEP_DDFDCB_4 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let addr = self.pc_post_inc();
                self.step = STEP_DDFDCB_5;
                set_addr_ctrl(pins, addr, MREQ | RD)
            }
            STEP_DDFDCB_5 => {
                self.opcode = get_data(pins);
                self.step = STEP_DDFDCB_6;
                pins
            }
            STEP_DDFDCB_6 => {
                self.step = STEP_DDFDCB_7;
                pins
            }
            STEP_DDFDCB_7 => {
                self.step = STEP_DDFDCB_8;
                pins
            }
            STEP_DDFDCB_8 => {
                self.step = STEP_DDFDCB_9;
                pins
            }
            STEP_DDFDCB_9 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                self.step = STEP_DDFDCB_10;
                set_addr_ctrl(pins, self.addr, MREQ | RD)
            }
            STEP_DDFDCB_10 => {
                // Mirrors `_z80_cb_action(cpu,6,cpu->opcode&7)`: the
                // operand always comes from memory (dlatch, `z0==6`), and
                // for every op except BIT (which returns `None` here, same
                // as the plain CB/CBHL forms) the result is written back to
                // memory AND -- the DDCB-specific "undocumented" behavior --
                // ALSO stored into the register the opcode's own low 3 bits
                // select, unless that's 6 (meaning "no extra register").
                self.dlatch = get_data(pins);
                if let Some(new_val) = self.cb_action(self.dlatch, true) {
                    self.dlatch = new_val;
                    let z1 = self.opcode & 7;
                    if z1 != 6 {
                        self.set_reg8_plain(z1, new_val);
                    }
                    self.step = STEP_DDFDCB_11;
                } else {
                    self.step = STEP_DDFDCB_14;
                }
                pins
            }
            STEP_DDFDCB_11 => {
                self.step = STEP_DDFDCB_12;
                pins
            }
            STEP_DDFDCB_12 => {
                self.step = STEP_DDFDCB_13;
                pins
            }
            STEP_DDFDCB_13 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let pins = set_addr_data_ctrl(pins, self.addr, self.dlatch, MREQ | WR);
                self.step = STEP_DDFDCB_14;
                pins
            }
            STEP_DDFDCB_14 => {
                self.step = STEP_DDFDCB_15;
                pins
            }
            STEP_DDFDCB_15 => self.begin_fetch(pins),
            // `int_im0`/`int_im1`/`int_im2`'s shared first 3 mcycles
            // (`z80_desc.yml`): disable interrupts, assert M1|IORQ, then
            // wait-check and latch whatever byte the ULA puts on the data
            // bus during that cycle (`Spectrum48K::tick()`'s int-ack
            // branch, unconditionally 0xFF -- the ZX Spectrum's floating
            // bus during an unrecognized IORQ). Only IM2 actually uses
            // that byte (as the vector's low byte); IM0's own spec says
            // it should be executed as an opcode, but since it's always
            // 0xFF here -- which VLA decodes as `RST 38h` -- IM0
            // and IM1 are bit-for-bit identical on this specific
            // hardware, so both are handled by the IM1 path below.
            STEP_INT_1 => {
                self.regs.iff1 = false;
                self.regs.iff2 = false;
                self.halted = false;
                self.step = STEP_INT_2;
                pins
            }
            STEP_INT_2 => {
                let pins = pins | M1 | IORQ;
                self.step = STEP_INT_3;
                pins
            }
            STEP_INT_3 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                self.dlatch = get_data(pins);
                self.step = STEP_INT_4;
                pins
            }
            // A regular refresh cycle (R increments the same as any other
            // M1) plus one extra idle T-state -- `z80_desc.yml`'s `generic
            // tcycles: 3` on this mcycle.
            STEP_INT_4 => {
                let pins = self.refresh(pins);
                self.step = STEP_INT_5;
                pins
            }
            STEP_INT_5 => {
                self.step = STEP_INT_6;
                pins
            }
            STEP_INT_6 => {
                self.step = STEP_INT_PUSH_HI_1;
                pins
            }
            // Two regular write machine cycles, pushing PC -- identical
            // shape to CALL nn's own PC push (same helper, same pin
            // sequence), just reached from here instead of a CALL operand
            // read.
            STEP_INT_PUSH_HI_1 => {
                self.step = STEP_INT_PUSH_HI_2;
                pins
            }
            STEP_INT_PUSH_HI_2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = STEP_INT_PUSH_HI_3;
                pins
            }
            STEP_INT_PUSH_HI_3 => {
                self.step = STEP_INT_PUSH_LO_1;
                pins
            }
            STEP_INT_PUSH_LO_1 => {
                self.step = STEP_INT_PUSH_LO_2;
                pins
            }
            STEP_INT_PUSH_LO_2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                if self.regs.im == 2 {
                    // Vector address = (I<<8)|ack_byte -- `dlatch` still
                    // holds the ack byte latched back in STEP_INT_3.
                    self.regs.set_wzl(self.dlatch);
                    self.regs.set_wzh(self.regs.i);
                } else {
                    // IM 0/1: RST 38h, unconditionally -- see this match
                    // arm's own leading comment for why IM0 collapses into
                    // this same path on this hardware.
                    self.regs.wz = 0x0038;
                    self.regs.pc = 0x0038;
                }
                self.step = STEP_INT_PUSH_LO_3;
                pins
            }
            // Real hardware (and `vendor/chips/z80.h`'s own generated
            // `int_im1`/`int_im2` case lists -- cross-checked directly
            // against those exact case numbers, not re-derived) has one
            // more idle T-state here before the IM1 path's fetch, or
            // before IM2's own vector-address read begins. Missing this
            // exact T-state doesn't break correctness (PC still ends up
            // right), but does shift every subsequent T-state -- and
            // hence every interrupt-timed effect a game calibrates
            // against real hardware, e.g. Aquaplane's per-frame border
            // write -- by however many T-states this whole sequence runs
            // short, one real T-state at a time.
            STEP_INT_PUSH_LO_3 => {
                self.step = if self.regs.im == 2 { STEP_INT_DONE_IM2 } else { STEP_INT_DONE_IM1 };
                pins
            }
            STEP_INT_DONE_IM1 => self.begin_fetch(pins),
            // Two regular read machine cycles, fetching the ISR address
            // the vector points at -- mirrors `IN A,(n)`'s own `$WZ++`
            // read exactly (same `wz_post_inc()` helper). This one plain
            // T-state is the first mread's own T1 (`STEP_INT_PUSH_LO_3`
            // was the interrupt sequence's own shared extra T-state, not
            // this one -- see z80.h's case 1667 vs 1666).
            STEP_INT_DONE_IM2 => {
                self.step = STEP_INT_VEC_LO_2;
                pins
            }
            STEP_INT_VEC_LO_2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let pins = set_addr_ctrl(pins, self.wz_post_inc(), MREQ | RD);
                self.step = STEP_INT_VEC_LO_3;
                pins
            }
            STEP_INT_VEC_LO_3 => {
                self.dlatch = get_data(pins);
                self.step = STEP_INT_VEC_HI_1;
                pins
            }
            STEP_INT_VEC_HI_1 => {
                self.step = STEP_INT_VEC_HI_2;
                pins
            }
            STEP_INT_VEC_HI_2 => {
                if pins & WAIT != 0 {
                    return pins;
                }
                let pins = set_addr_ctrl(pins, self.regs.wz, MREQ | RD);
                self.step = STEP_INT_VEC_HI_3;
                pins
            }
            STEP_INT_VEC_HI_3 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.set_wzl(self.dlatch);
                self.regs.pc = self.regs.wz;
                self.step = STEP_INT_VEC_HI_4;
                pins
            }
            STEP_INT_VEC_HI_4 => self.begin_fetch(pins),
            0 => self.begin_fetch(pins), // NOP dispatch == bootstrap convention, see struct doc
            0x76 => self.op_halt(pins),
            0xCB => self.begin_fetch_cb(pins),
            0xDD => self.begin_fetch_dd(pins),
            0xFD => self.begin_fetch_fd(pins),
            0xED => self.begin_fetch_ed(pins),
            _ => self.dispatch(pins),
        }
    }

    /// Sets up an opcode-fetch (M1) machine cycle's T1 transaction:
    /// address=PC (post-incremented), M1|MREQ|RD asserted. Mirrors
    /// `_z80_fetch()`.
    pub(crate) fn begin_fetch(&mut self, pins: u64) -> u64 {
        self.hlx_idx = 0;
        // Mirrors `_z80_fetch()`'s own unconditional `prefix_active =
        // false` -- redundant with every OTHER path here (their own M1_T4
        // handler already cleared it earlier in the same instruction), but
        // load-bearing for the DDCB/FDCB chain specifically: nothing along
        // that chain clears it before reaching this call, so without this,
        // the M1|RD pins this returns still read as "mid-prefix" and
        // `step()` silently runs one extra instruction before stopping.
        // Found via a real fuzzer failure, not anticipated in advance.
        self.prefix_active = false;
        // Every complete-instruction boundary funnels through here
        // (including HALT's own repeated re-fetch of itself, which is
        // exactly how HALT "wakes up" below) -- the one place real
        // hardware samples the INT line. `iff1` gates it (DI/EI's own
        // generated code already handles the "not immediately after EI"
        // one-instruction delay for free: EI's `action`/`post_action`
        // pair briefly clears `iff1` around its OWN `begin_fetch()` call,
        // so this check simply can't see it as enabled on that boundary --
        // see `z80_desc.yml`'s EI entry). NMI isn't modeled: this project
        // doesn't emulate any hardware that raises it.
        if pins & INT != 0 && self.regs.iff1 {
            self.step = STEP_INT_1;
            return pins;
        }
        let addr = self.regs.pc;
        self.regs.pc = self.regs.pc.wrapping_add(1);
        self.step = STEP_M1_T2;
        set_addr_ctrl(pins, addr, M1 | MREQ | RD)
    }

    /// Same as `begin_fetch`, but for the byte AFTER an 0xED prefix --
    /// `prefix_active` stays true through this second fetch so
    /// `is_instruction_boundary()` doesn't report "done" between the
    /// prefix byte and its suffix, mirroring `z80_opdone()`'s own
    /// `!prefix_active` check.
    pub(crate) fn begin_fetch_ed(&mut self, pins: u64) -> u64 {
        let addr = self.regs.pc;
        self.regs.pc = self.regs.pc.wrapping_add(1);
        self.step = STEP_ED_M1_T2;
        self.prefix_active = true;
        // Mirrors `_z80_fetch_ed()`'s own `hlx_idx = 0` -- so a (pathological,
        // never emitted by any real assembler) "DD ED xx" sequence doesn't
        // leave IX/IY substitution active for an ED-prefixed instruction,
        // which never has any hlx-substitutable operand anyway.
        self.hlx_idx = 0;
        set_addr_ctrl(pins, addr, M1 | MREQ | RD)
    }

    /// Same shared-fetch shape again, but for the byte after a CB prefix.
    /// Mirrors `_z80_fetch_cb()`'s non-DD/FD branch -- the DD+CB/FD+CB
    /// branch doesn't apply here since IX/IY substitution doesn't exist
    /// yet (deferred along with the rest of DD/FD).
    pub(crate) fn begin_fetch_cb(&mut self, pins: u64) -> u64 {
        self.prefix_active = true;
        if self.hlx_idx > 0 {
            // DD+CB / FD+CB: continue on the DDCB decoder chain instead of
            // a regular CB fetch -- its own first T-state (STEP_DDFDCB_1)
            // issues the displacement-byte read, so nothing needs doing to
            // pins here. Mirrors `_z80_fetch_cb()`'s own `hlx_idx > 0`
            // branch exactly (down to the comment: the first mread T-state
            // is "overlapped" from this fetch, i.e. free).
            self.step = STEP_DDFDCB_1;
            return pins;
        }
        let addr = self.regs.pc;
        self.regs.pc = self.regs.pc.wrapping_add(1);
        self.step = STEP_CB_M1_T2;
        set_addr_ctrl(pins, addr, M1 | MREQ | RD)
    }

    /// Same shared-fetch shape again, but for the byte after a DD prefix --
    /// mirrors `_z80_fetch_dd()`. `hlx_idx` is set here (not reset by this
    /// fetch, unlike the other three -- it must persist for the REST of
    /// this one instruction, until the eventual trailing plain `_fetch()`
    /// resets it back to 0).
    pub(crate) fn begin_fetch_dd(&mut self, pins: u64) -> u64 {
        let addr = self.regs.pc;
        self.regs.pc = self.regs.pc.wrapping_add(1);
        self.step = STEP_DDFD_M1_T2;
        self.hlx_idx = 1;
        self.prefix_active = true;
        set_addr_ctrl(pins, addr, M1 | MREQ | RD)
    }

    /// Same as `begin_fetch_dd`, for FD -- mirrors `_z80_fetch_fd()`.
    pub(crate) fn begin_fetch_fd(&mut self, pins: u64) -> u64 {
        let addr = self.regs.pc;
        self.regs.pc = self.regs.pc.wrapping_add(1);
        self.step = STEP_DDFD_M1_T2;
        self.hlx_idx = 2;
        self.prefix_active = true;
        set_addr_ctrl(pins, addr, M1 | MREQ | RD)
    }

    /// The refresh (RFSH) machine cycle: address=IR, MREQ|RFSH asserted,
    /// R incremented (7-bit counter, bit 7 preserved). Mirrors
    /// `_z80_refresh()`.
    fn refresh(&mut self, pins: u64) -> u64 {
        let ir = ((self.regs.i as u16) << 8) | self.regs.r as u16;
        self.regs.r = (self.regs.r & 0x80) | (self.regs.r.wrapping_add(1) & 0x7F);
        set_addr_ctrl(pins, ir, MREQ | RFSH)
    }

    /// HALT: sets the HALT flag/pin and rewinds PC back onto the HALT
    /// opcode's own address, then immediately queues another fetch --
    /// since that re-fetch reads the SAME HALT byte again, this naturally
    /// "freezes" execution (PC oscillates internally but always nets back
    /// to the HALT address at rest) without any special-cased branch
    /// anywhere else in `tick()`. Mirrors `_z80_halt()`.
    fn op_halt(&mut self, pins: u64) -> u64 {
        self.halted = true;
        self.regs.pc = self.regs.pc.wrapping_sub(1);
        self.begin_fetch(pins)
    }

    /// Per-opcode continuations beyond the shared fetch/refresh/HALT
    /// machinery above. Generated from `vendor/chips/z80_desc.yml` by
    /// `scripts/generate_z80_dispatch.py` (unprefixed + ED tables only,
    /// see that script's docs for scope) -- an unimplemented step panics
    /// loudly with the opcode/address rather than doing something
    /// silently wrong.
    fn dispatch(&mut self, pins: u64) -> u64 {
        if let Some(result) = self.dispatch_generated(pins) {
            return result;
        }
        panic!(
            "unimplemented step {:#06x} (opcode {:#04x}) at PC {:#06x}",
            self.step,
            self.opcode,
            self.regs.pc.wrapping_sub(1)
        );
    }

    /// The 3-bit ALU "op" field (0x80-0xBF / 0xC6-0xFE, and the ED-prefix
    /// group): ADD, ADC, SUB, SBC, AND, XOR, OR, CP against A, in that
    /// order. Kept as a runtime-indexed dispatcher (rather than 8 named
    /// methods) since the generated dispatch code always knows `op` as a
    /// compile-time-known literal per opcode anyway.
    pub(crate) fn alu_op(&mut self, op: u8, val: u8) {
        let acc = self.regs.a;
        let carry_in = self.regs.f & FLAG_C;
        let (new_a, flags) = match op {
            0 => {
                let r = alu::add8(acc, val);
                (Some(r.value), r.flags)
            }
            1 => {
                let r = alu::adc8(acc, val, carry_in);
                (Some(r.value), r.flags)
            }
            2 => {
                let r = alu::sub8(acc, val);
                (Some(r.value), r.flags)
            }
            3 => {
                let r = alu::sbc8(acc, val, carry_in);
                (Some(r.value), r.flags)
            }
            4 => {
                let r = alu::and8(acc, val);
                (Some(r.value), r.flags)
            }
            5 => {
                let r = alu::xor8(acc, val);
                (Some(r.value), r.flags)
            }
            6 => {
                let r = alu::or8(acc, val);
                (Some(r.value), r.flags)
            }
            7 => (None, alu::cp8(acc, val)), // CP leaves A unchanged
            _ => unreachable!("op is a 3-bit field"),
        };
        if let Some(value) = new_a {
            self.regs.a = value;
        }
        self.regs.f = flags;
    }

    /// The CB-prefix rotate/shift/BIT/RES/SET group, ported from z80.h's
    /// `_z80_cb_action`: `x`/`y` (operation/bit-number selectors) are read
    /// from `self.opcode` (the CB-suffix byte, already latched) rather
    /// than passed in, matching the reference exactly. Returns `Some(new
    /// value)` for every operation except `BIT` (which only sets flags,
    /// never writes anything back) -- callers use this to decide whether
    /// a register/memory write-back is needed, same as the reference's
    /// `bool` return value.
    pub(crate) fn cb_action(&mut self, val: u8, is_indirect: bool) -> Option<u8> {
        let x = self.opcode >> 6;
        let y = (self.opcode >> 3) & 7;
        match x {
            0 => {
                let r = match y {
                    0 => alu::rlc(val),
                    1 => alu::rrc(val),
                    2 => alu::rl(val, self.regs.f),
                    3 => alu::rr(val, self.regs.f),
                    4 => alu::sla(val),
                    5 => alu::sra(val),
                    6 => alu::sll(val),
                    7 => alu::srl(val),
                    _ => unreachable!("y is a 3-bit field"),
                };
                self.regs.f = r.flags;
                Some(r.value)
            }
            1 => {
                self.regs.f = alu::bit(val, y, is_indirect, self.regs.wz, self.regs.f);
                None
            }
            2 => Some(alu::res(val, y)),
            3 => Some(alu::set(val, y)),
            _ => unreachable!("x is a 2-bit field"),
        }
    }

    /// The CB-suffix opcode's own `z` field, for the register-direct form
    /// only -- `z == 6` ((HL)) is routed through the generated `cbhl`
    /// step instead (see `STEP_CB_M1_T4`), so this never sees it.
    pub(crate) fn get_reg8_plain(&self, idx: u8) -> u8 {
        match idx {
            0 => self.regs.b,
            1 => self.regs.c,
            2 => self.regs.d,
            3 => self.regs.e,
            4 => self.regs.h,
            5 => self.regs.l,
            7 => self.regs.a,
            _ => unreachable!("CB register-direct form never sees idx 6 ((HL))"),
        }
    }

    pub(crate) fn set_reg8_plain(&mut self, idx: u8, value: u8) {
        match idx {
            0 => self.regs.b = value,
            1 => self.regs.c = value,
            2 => self.regs.d = value,
            3 => self.regs.e = value,
            4 => self.regs.h = value,
            5 => self.regs.l = value,
            7 => self.regs.a = value,
            _ => unreachable!("CB register-direct form never sees idx 6 ((HL))"),
        }
    }

    // ---- $RY/$RZ/$HL/$RP-style "hlx" accessors: read/write whichever of
    // HL/IX/IY `self.hlx_idx` currently selects. Mirrors z80.h's
    // `cpu->hlx[cpu->hlx_idx]` exactly -- the generator routes every
    // SUBSTITUTABLE token through these (never the plain `self.regs.h`/
    // `self.regs.hl()` etc, which stay correct only for the explicitly
    // non-substitutable `$RRY`/`$RRZ`/`$RRP`/literal-`cpu->hl` tokens).
    pub(crate) fn hlx_h(&self) -> u8 {
        match self.hlx_idx {
            0 => self.regs.h,
            1 => self.regs.ixh(),
            2 => self.regs.iyh(),
            _ => unreachable!("hlx_idx is 0/1/2"),
        }
    }

    pub(crate) fn set_hlx_h(&mut self, value: u8) {
        match self.hlx_idx {
            0 => self.regs.h = value,
            1 => self.regs.set_ixh(value),
            2 => self.regs.set_iyh(value),
            _ => unreachable!("hlx_idx is 0/1/2"),
        }
    }

    pub(crate) fn hlx_l(&self) -> u8 {
        match self.hlx_idx {
            0 => self.regs.l,
            1 => self.regs.ixl(),
            2 => self.regs.iyl(),
            _ => unreachable!("hlx_idx is 0/1/2"),
        }
    }

    pub(crate) fn set_hlx_l(&mut self, value: u8) {
        match self.hlx_idx {
            0 => self.regs.l = value,
            1 => self.regs.set_ixl(value),
            2 => self.regs.set_iyl(value),
            _ => unreachable!("hlx_idx is 0/1/2"),
        }
    }

    pub(crate) fn hlx(&self) -> u16 {
        match self.hlx_idx {
            0 => self.regs.hl(),
            1 => self.regs.ix,
            2 => self.regs.iy,
            _ => unreachable!("hlx_idx is 0/1/2"),
        }
    }

    pub(crate) fn set_hlx(&mut self, value: u16) {
        match self.hlx_idx {
            0 => self.regs.set_hl(value),
            1 => self.regs.ix = value,
            2 => self.regs.iy = value,
            _ => unreachable!("hlx_idx is 0/1/2"),
        }
    }

    // ---- small post-increment/pre-decrement address helpers, matching
    // the handful of `$PC++`/`$SP++`/`--$SP`/`$WZ++`/`cpu->hl++` etc
    // tokens the generated dispatch code uses (Rust has no in-expression
    // `x++` the way the C action strings this was ported from do, so
    // these exist purely to keep the generator's substitutions simple).
    pub(crate) fn pc_post_inc(&mut self) -> u16 {
        let v = self.regs.pc;
        self.regs.pc = self.regs.pc.wrapping_add(1);
        v
    }

    pub(crate) fn sp_post_inc(&mut self) -> u16 {
        let v = self.regs.sp;
        self.regs.sp = self.regs.sp.wrapping_add(1);
        v
    }

    pub(crate) fn sp_pre_dec(&mut self) -> u16 {
        self.regs.sp = self.regs.sp.wrapping_sub(1);
        self.regs.sp
    }

    pub(crate) fn wz_post_inc(&mut self) -> u16 {
        let v = self.regs.wz;
        self.regs.wz = self.regs.wz.wrapping_add(1);
        v
    }

    pub(crate) fn hl_post_inc(&mut self) -> u16 {
        let v = self.regs.hl();
        self.regs.set_hl(v.wrapping_add(1));
        v
    }

    pub(crate) fn hl_post_dec(&mut self) -> u16 {
        let v = self.regs.hl();
        self.regs.set_hl(v.wrapping_sub(1));
        v
    }

    pub(crate) fn de_post_inc(&mut self) -> u16 {
        let v = self.regs.de();
        self.regs.set_de(v.wrapping_add(1));
        v
    }

    pub(crate) fn de_post_dec(&mut self) -> u16 {
        let v = self.regs.de();
        self.regs.set_de(v.wrapping_sub(1));
        v
    }

    /// True exactly when the CPU has just returned to a fresh opcode
    /// fetch's T1 (M1|RD both asserted) and isn't mid-prefix. Mirrors
    /// `z80_opdone()` -- checked against the PINS returned by the most
    /// recent `tick()` call, not against any internal step number. Public
    /// so a machine-level caller driving `tick()` directly (to intercept
    /// IORQ as well as MREQ, which `step()`'s own internal loop doesn't)
    /// can detect instruction completion the same way `step()` does,
    /// without duplicating this check.
    pub fn is_instruction_boundary(&self, pins: u64) -> bool {
        (pins & (M1 | RD)) == (M1 | RD) && !self.prefix_active
    }

    fn service_memory(mem: &mut impl Memory, pins: u64) -> u64 {
        if pins & MREQ != 0 {
            if pins & RD != 0 {
                return set_data(pins, mem.read(get_addr(pins)));
            } else if pins & WR != 0 {
                mem.write(get_addr(pins), get_data(pins));
            }
        }
        pins
    }

    /// Executes exactly one whole instruction (servicing memory pins
    /// internally) and returns the T-states it took. Convenience wrapper
    /// around `tick()` for callers that don't need per-T-state control --
    /// existing tests and the ZEXALL harness use this, unchanged in shape
    /// from the pre-tick-based design.
    pub fn step(&mut self, mem: &mut impl Memory) -> u8 {
        let mut pins = Self::service_memory(mem, self.tick(self.pins));
        let mut t_states: u8 = 1;
        while !self.is_instruction_boundary(pins) {
            pins = Self::service_memory(mem, self.tick(pins));
            t_states += 1;
        }
        self.pins = pins;
        t_states
    }
}
