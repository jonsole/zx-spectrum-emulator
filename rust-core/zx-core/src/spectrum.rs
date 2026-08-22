//! `Spectrum48K`: wires the Z80 core, memory, ULA and keyboard into one
//! machine. Ported directly from `zxspectrum/core/machine.py`'s own
//! `Spectrum48K` -- owns the tick loop that interprets `Cpu::tick()`'s pin
//! mask each T-state to service memory and IO requests, and exposes the
//! debug primitives (step, breakpoints, register/memory access, screen
//! render) a future front-end will drive.
//!
//! Unlike the Python wrapper (whose underlying `z80.h` binding tracks pins
//! as an internal stateful attribute), `Cpu::tick(pins) -> u64` is a pure
//! function of its argument -- so `Spectrum48K` owns the `pins: u64` that
//! persists across calls itself, the same role `self.cpu.pins` plays in
//! `machine.py::tick()`.

use crate::contention;
use crate::keyboard::Keyboard;
use crate::memory::{Memory, Spectrum48KMemory};
use crate::pins::{get_addr, get_data, set_data, INT, IORQ, M1, MREQ, RD, WR};
use crate::registers::Registers;
use crate::ula::{Ula, FRAME_TSTATES};
use crate::Cpu;
use std::collections::HashSet;

/// Interrupt vector byte for IM1 -- IM1 always executes RST 38h regardless
/// of what's on the data bus during the ack cycle, but the real hardware
/// (and this core, once interrupt acknowledgment exists) still reads a
/// byte during that cycle. Matches `machine.py`'s `_INT_ACK_BYTE`.
const INT_ACK_BYTE: u8 = 0xFF;

// Opcodes that push a return address and jump to a callee -- CALL nn, CALL
// cc,nn, and every RST. Whether a conditional CALL actually pushed anything
// is confirmed afterward by checking SP, not decided here. Matches
// `machine.py`'s `_CALL_OPCODES`/`_RST_OPCODES`.
const CALL_OPCODES: [u8; 9] = [0xCD, 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC];
const RST_OPCODES: [u8; 8] = [0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF];
/// RET / RET cc -- pairs with a tracked `CALL_OPCODES`/`RST_OPCODES` push.
const RET_OPCODES: [u8; 9] = [0xC9, 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8];

#[derive(Clone, Copy, PartialEq, Eq)]
enum StepCategory {
    Call,
    Ret,
}

/// Classifies the opcode at `addr` for `call_stack` tracking purposes.
/// Returns `Call` (CALL/RST -- may push a return address), `Ret` (RET/RET
/// cc -- may pop one), or `None` (everything else). Skips redundant DD/FD
/// prefixes the same way the real CPU does before classifying the
/// underlying opcode. Ported directly from `machine.py`'s
/// `_classify_step`, including its own documented deliberate choice:
/// RETI/RETN (0xED 0x4D / 0xED 0x45) fall under the ED-prefixed `None`
/// case, not `Ret` -- they return from an interrupt, and this emulator
/// doesn't push a `call_stack` frame for interrupt entry either (that
/// would happen inside `Cpu::tick()`'s own dispatch during the interrupt
/// acknowledge cycle, invisible at the opcode level this classifier works
/// at) -- treating both ends as an untracked no-op keeps `call_stack`
/// correct for the CALL/RET pairs it DOES see instead of popping a real
/// one that was never the interrupt's.
fn classify_step(mem: &mut Spectrum48KMemory, addr: u16) -> Option<StepCategory> {
    let mut a = addr;
    let mut op = mem.read(a);
    while op == 0xDD || op == 0xFD {
        a = a.wrapping_add(1);
        op = mem.read(a);
    }
    if op == 0xED {
        return None;
    }
    if CALL_OPCODES.contains(&op) || RST_OPCODES.contains(&op) {
        return Some(StepCategory::Call);
    }
    if RET_OPCODES.contains(&op) {
        return Some(StepCategory::Ret);
    }
    None
}

pub struct Spectrum48K {
    pub cpu: Cpu,
    pub memory: Spectrum48KMemory,
    pub keyboard: Keyboard,
    pub ula: Ula,
    pub tstates: u32,
    pub frame_count: u64,
    pub breakpoints: HashSet<u16>,
    /// Return addresses for CALL/RST frames currently unwound below the
    /// current PC, oldest first -- see `classify_step()` for how it's kept
    /// in sync with actual execution. Cleared on reset/snapshot load/
    /// `set_registers()` since any of those can redirect PC outside normal
    /// call/return flow, making a stale call chain actively misleading
    /// rather than just incomplete. Matches `machine.py`'s `call_stack`.
    pub call_stack: Vec<u16>,
    pins: u64,
    int_pending: bool,
}

impl Default for Spectrum48K {
    fn default() -> Self {
        let mut machine = Spectrum48K {
            cpu: Cpu::new(),
            memory: Spectrum48KMemory::new(),
            keyboard: Keyboard::new(),
            ula: Ula::default(),
            tstates: 0,
            frame_count: 0,
            breakpoints: HashSet::new(),
            call_stack: Vec::new(),
            pins: 0,
            int_pending: false,
        };
        machine.prime_fetch();
        machine
    }
}

impl Spectrum48K {
    pub fn new() -> Self {
        Self::default()
    }

    // ---- loading ---------------------------------------------------------

    pub fn load_rom(&mut self, data: &[u8]) -> Result<(), String> {
        self.memory.load_rom(data)
    }

    /// Loads a `.sna` snapshot: RAM contents, registers, and border.
    /// Mirrors `machine.py::load_snapshot()`.
    pub fn load_snapshot(&mut self, data: &[u8]) -> Result<(), String> {
        let image = crate::snapshot::parse_sna(data)?;
        self.memory.ram.copy_from_slice(&image.ram);
        self.set_registers(image.regs); // also clears call_stack
        self.ula.border = image.border;
        self.ula.clear_frame_state();
        self.tstates = 0;
        self.int_pending = false;
        Ok(())
    }

    // ---- reset / registers / memory ---------------------------------------

    /// Real Z80 RESET semantics (PC/I/R/IFF/IM cleared, other registers
    /// left as-is) aren't implemented in `Cpu` yet -- same deferred
    /// category as interrupt acknowledgment and I/O opcodes (see the
    /// rust-core plan). Zeroing every register is a close-enough
    /// approximation for now, revisit if/when `Cpu` grows real RESET pin
    /// handling.
    pub fn reset(&mut self) {
        self.set_registers(Registers::default()); // also clears call_stack
        self.ula.clear_frame_state();
        self.tstates = 0;
        self.frame_count = 0;
        self.int_pending = false;
    }

    pub fn registers(&self) -> Registers {
        self.cpu.registers()
    }

    /// An external register write (a debugger jumping PC around, a fresh
    /// snapshot/reset) can redirect execution outside normal call/return
    /// flow, so any tracked `call_stack` is no longer meaningful --
    /// cleared unconditionally here, matching `machine.py`'s own
    /// `set_registers()`, rather than trying to detect whether PC
    /// specifically changed.
    pub fn set_registers(&mut self, regs: Registers) {
        self.cpu.set_registers(regs, &mut self.memory);
        self.pins = self.cpu.pins();
        self.call_stack.clear();
    }

    fn prime_fetch(&mut self) {
        // `Cpu::set_registers()` already does its own priming tick against
        // whatever registers it's given -- reuse it with the all-zero
        // default so `pins` starts primed the same way `machine.py`'s own
        // `_prime_fetch()` does after construction.
        self.set_registers(Registers::default());
    }

    pub fn read_memory(&mut self, addr: u16, length: usize) -> Vec<u8> {
        (0..length)
            .map(|i| self.memory.read(addr.wrapping_add(i as u16)))
            .collect()
    }

    pub fn write_memory(&mut self, addr: u16, data: &[u8]) {
        for (i, &b) in data.iter().enumerate() {
            self.memory.write(addr.wrapping_add(i as u16), b);
        }
    }

    /// The last fully completed frame -- see `Ula::screen()`'s own doc
    /// comment for why it's "last complete" rather than "decoded right
    /// now": rendering is genuinely T-state-synced (built up during
    /// `tick()`/`advance_tstate()` as the frame progresses), not a
    /// snapshot decode, so there's no meaningful "decode it now" moment
    /// mid-frame.
    pub fn render_screen(&self) -> Vec<u8> {
        self.ula.screen()
    }

    // ---- breakpoints -------------------------------------------------------

    pub fn set_breakpoint(&mut self, addr: u16) {
        self.breakpoints.insert(addr);
    }

    pub fn clear_breakpoint(&mut self, addr: u16) {
        self.breakpoints.remove(&addr);
    }

    // ---- tick loop -----------------------------------------------------------

    /// Advances exactly one T-state, servicing whatever the bus asks for.
    /// Mirrors `machine.py::tick()`, extended with ULA contention: the
    /// 48K ULA halts the CPU's own clock (not the Z80's WAIT pin -- there
    /// is no lookahead available for that here, see `advance_tstate()`'s
    /// doc comment) for a data-sheet-documented number of extra T-states
    /// when a real memory/IO access lands in its contended window. A
    /// SINGLE call to this method can therefore silently advance
    /// `self.tstates` by more than 1 -- see `run_frame()`'s own doc
    /// comment for the one place in this codebase that had to change
    /// because of that.
    pub fn tick(&mut self) {
        let mut pins = self.pins;
        if self.int_pending {
            pins |= INT;
        } else {
            pins &= !INT;
        }

        let mut pins = self.cpu.tick(pins);

        if pins & MREQ != 0 {
            let addr = get_addr(pins);
            if pins & RD != 0 {
                self.apply_memory_contention(addr);
                pins = set_data(pins, self.memory.read(addr));
            } else if pins & WR != 0 {
                self.apply_memory_contention(addr);
                self.memory.write(addr, get_data(pins));
            }
            // A bare MREQ with neither RD nor WR is a refresh cycle --
            // not contended (the refresh address, derived from I/R, isn't
            // "an instruction fetch, memory read, or memory write" in the
            // documented sense, and in practice essentially never lands
            // in screen memory anyway).
        } else if pins & IORQ != 0 {
            let addr = get_addr(pins);
            if pins & M1 != 0 {
                // Interrupt acknowledge cycle -- deliberately NOT
                // contended (see the rust-core plan's explicit
                // out-of-scope note: real-hardware behavior here is
                // murkier, and this core doesn't model IM2 vectored
                // interrupts yet either).
                pins = set_data(pins, INT_ACK_BYTE);
                self.int_pending = false;
            } else {
                self.apply_io_contention(addr);
                if pins & RD != 0 {
                    let value = if addr & 0x01 == 0 {
                        self.keyboard.read_port((addr >> 8) as u8)
                    } else {
                        0xFF // unmapped port; floating-bus behavior not modeled
                    };
                    pins = set_data(pins, value);
                } else if pins & WR != 0 && addr & 0x01 == 0 {
                    self.ula.border = get_data(pins) & 0x07;
                    // bits 3/4 (MIC/speaker) tracked nowhere yet -- no audio
                }
            }
        }

        self.pins = pins;
        self.advance_tstate();
    }

    /// The single per-real-T-state hook: advances the frame clock, drives
    /// the ULA's own T-state-synced screen fetch (`Ula::on_tstate()`), and
    /// handles the frame-boundary interrupt/flash/framebuffer-swap
    /// bookkeeping. Called once for the real T-state `tick()` drives via
    /// `Cpu::tick()`, and reused -- WITHOUT any `Cpu::tick()` call --
    /// for every contention "phantom" T-state `apply_memory_contention()`/
    /// `apply_io_contention()` insert: the CPU's own state machine only
    /// ever sees its own T-states advance by exactly one per real
    /// `Cpu::tick()` call (matching real hardware, where the CPU is
    /// unaware its clock was ever stopped), while `self.tstates` -- and
    /// hence the ULA's own raster position -- advances by the true,
    /// contended amount. This only works because this core's WAIT-pin
    /// protocol has no lookahead for contention: by the time `tick()`
    /// observes a newly-asserted MREQ/IORQ, `Cpu`'s internal step has
    /// already advanced past the one T-state that would check WAIT, so
    /// asserting WAIT reactively here would not actually hold anything.
    /// Real 48K hardware doesn't use WAIT for this either -- the ULA
    /// halts the clock oscillator directly.
    fn advance_tstate(&mut self) {
        let current = self.tstates;
        self.ula.on_tstate(current, &mut self.memory);

        self.tstates += 1;
        if self.tstates >= FRAME_TSTATES {
            self.tstates -= FRAME_TSTATES;
            self.int_pending = true;
            self.frame_count += 1;
            self.ula.on_frame_boundary();
            if self.frame_count % 16 == 0 {
                // ~1.56Hz, matching real hardware
                self.ula.flash_state = !self.ula.flash_state;
            }
        }
    }

    /// Applies real ULA memory contention (see `advance_tstate()`'s doc
    /// comment for the mechanism) if `addr` is in the contended page.
    /// Marks each halted T-state's pixels for the overlay as it goes (see
    /// `Ula::mark_contention_tstate`) -- one mark per real T-state actually
    /// spent halted, not one mark per contention event.
    fn apply_memory_contention(&mut self, addr: u16) {
        if !contention::is_contended_memory(addr) {
            return;
        }
        let delay = contention::memory_contention_delay(self.tstates);
        for _ in 0..delay {
            self.ula.mark_contention_tstate(self.tstates, false);
            self.advance_tstate();
        }
    }

    /// Same, for I/O port contention -- see `contention::io_contention_delay`
    /// for the 4-case table this implements.
    fn apply_io_contention(&mut self, addr: u16) {
        let delay = contention::io_contention_delay(addr, self.tstates);
        for _ in 0..delay {
            self.ula.mark_contention_tstate(self.tstates, true);
            self.advance_tstate();
        }
    }

    /// Runs T-states until the current instruction completes. Tracks
    /// `call_stack`: classifies the opcode at the pre-step PC (before
    /// anything executes, since by the time the instruction completes the
    /// bytes at the OLD PC may no longer be what ran, e.g. self-modifying
    /// code), then afterward confirms via the SP delta that a push/pop
    /// actually happened -- so a conditional CALL/RET that wasn't taken
    /// (SP unchanged) doesn't touch `call_stack`. Matches `machine.py`'s
    /// `step_instruction()`.
    pub fn step_instruction(&mut self) {
        let pc_before = self.registers().pc;
        let sp_before = self.registers().sp;
        let category = classify_step(&mut self.memory, pc_before);

        self.tick();
        while !self.cpu.is_instruction_boundary(self.pins) {
            self.tick();
        }

        let Some(category) = category else { return };
        let sp_after = self.registers().sp;
        match category {
            StepCategory::Call if sp_after == sp_before.wrapping_sub(2) => {
                let lo = self.memory.read(sp_after);
                let hi = self.memory.read(sp_after.wrapping_add(1));
                self.call_stack.push((lo as u16) | ((hi as u16) << 8));
            }
            StepCategory::Ret if sp_after == sp_before.wrapping_add(2) && !self.call_stack.is_empty() => {
                self.call_stack.pop();
            }
            _ => {}
        }
    }

    /// Runs exactly one video frame's worth of T-states (~69888). Loops
    /// on `frame_count` rather than a fixed T-state count: since
    /// contention lets a single `tick()` call silently consume more than
    /// one real T-state (see `advance_tstate()`'s doc comment), a
    /// `for _ in 0..FRAME_TSTATES { self.tick() }`-style loop would call
    /// `tick()` too few times to actually cover a full frame whenever any
    /// contention occurred. `frame_count` is incremented exactly once per
    /// real frame boundary regardless of how many `tick()` calls it took
    /// to get there, so looping on it is correct either way.
    pub fn run_frame(&mut self) {
        let target = self.frame_count + 1;
        while self.frame_count < target {
            self.tick();
        }
    }

    /// Runs until a breakpoint is hit; returns "breakpoint" or "limit".
    pub fn run(&mut self, max_instructions: u64) -> &'static str {
        for _ in 0..max_instructions {
            self.step_instruction();
            if self.breakpoints.contains(&self.registers().pc) {
                return "breakpoint";
            }
        }
        "limit"
    }
}
