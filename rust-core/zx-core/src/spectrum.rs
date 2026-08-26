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

use crate::keyboard::Keyboard;
use crate::memory::{Memory, Spectrum48KMemory};
use crate::pins::{get_addr, get_data, set_data, INT, IORQ, M1, MREQ, RD, WR};
use crate::registers::Registers;
use crate::ula::{io_contention_delay, Ula, FRAME_TSTATES};
use crate::Cpu;
use std::collections::HashSet;

/// Interrupt vector byte for IM1 -- IM1 always executes RST 38h regardless
/// of what's on the data bus during the ack cycle, but the real hardware
/// (and this core, once interrupt acknowledgment exists) still reads a
/// byte during that cycle. Matches `machine.py`'s `_INT_ACK_BYTE`.
const INT_ACK_BYTE: u8 = 0xFF;

/// How long the 48K ULA pulls INT low, once per frame -- purely a function
/// of raster position (`tstates < INT_PULSE_TSTATES`), not CPU behavior:
/// the ULA doesn't know or care whether the CPU ever accepts it, so the
/// line isn't extended, re-armed, or suppressed for any reason (including
/// how recently the machine itself was constructed -- a fresh instance's
/// `tstates == 0` is just as much "within the pulse window" as any other
/// frame's, matching real hardware, where interrupt timing isn't synced to
/// CPU reset at all -- the 48K ROM's own first instruction is `DI`
/// specifically because an interrupt can arrive before software is ready
/// for one).
const INT_PULSE_TSTATES: u32 = 32;

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

    /// Advances exactly one real T-state -- one call, one clock cycle,
    /// always. `Ula::tick()` is asked FIRST, using whatever's currently on
    /// the bus (`self.pins`, unchanged since the last call if that was
    /// itself a stall): if it says the ULA needs this cycle for itself
    /// (contention), `Cpu::tick()` is never called at all this time --
    /// only the frame clock/screen-fetch bookkeeping advances, and the CPU
    /// genuinely does not progress. Only once `Ula::tick()` says the CPU
    /// may proceed does this call `Cpu::tick()` and service whatever
    /// MREQ/IORQ/RD/WR it asks for. This means a single `Cpu::tick()`-worth
    /// of real CPU progress can take MULTIPLE calls to this method (one
    /// per T-state actually spent, contended or not) -- callers that loop
    /// until some condition (`step_instruction()`, `run_frame()`) are
    /// unaffected by this since they already loop on `tick()` regardless;
    /// callers that count a fixed number of `tick()` calls now get true
    /// T-state-level granularity rather than "N real CPU steps," which is
    /// what per-T-state debugging tools actually want.
    pub fn tick(&mut self) {
        let current_tstate = self.tstates;

        if current_tstate < INT_PULSE_TSTATES {
            self.pins |= INT;
        } else {
            self.pins &= !INT;
        }

        if self.ula.tick(current_tstate, self.pins, &mut self.memory) {
            self.pins = self.cpu.tick(self.pins);
        }

        let addr = get_addr(self.pins);
        if self.pins & MREQ != 0 {
            if self.pins & RD != 0 {
                self.pins = set_data(self.pins, self.memory.read(addr));
            } else if self.pins & WR != 0 {
                self.memory.write(addr, get_data(self.pins));
            }
        } else if self.pins & IORQ != 0 {
            if self.pins & M1 != 0 {
                // Interrupt acknowledge cycle -- deliberately NOT
                // contended (see the rust-core plan's explicit
                // out-of-scope note: real-hardware behavior here is
                // murkier.
                self.pins = set_data(self.pins, INT_ACK_BYTE);
            } else {
                // Disabled for now -- double-counts with the unconditional
                // memory-contention check above, which now ALSO fires on
                // an IO cycle's own T-states (the port address persists on
                // the bus same as any other) and stacks on top of this
                // table's own delay for the same access. Confirmed via a
                // live Aquaplane regression: border-timing code that uses
                // `OUT (C),r` with a contended port (B in 0x40-0x7F) for
                // precise timing was getting delayed twice.
                // self.apply_io_contention(addr);
                if self.pins & RD != 0 {
                    let value = if addr & 0x01 == 0 {
                        self.keyboard.read_port((addr >> 8) as u8)
                    } else {
                        0xFF // unmapped port; floating-bus behavior not modeled
                    };
                    self.pins = set_data(self.pins, value);
                } else if self.pins & WR != 0 && addr & 0x01 == 0 {
                    self.ula.border = get_data(self.pins) & 0x07;
                    // bits 3/4 (MIC/speaker) tracked nowhere yet -- no audio
                }
            }
        }

        self.tstates += 1;
        if self.tstates >= FRAME_TSTATES {
            self.tstates -= FRAME_TSTATES;
            self.frame_count += 1;
            self.ula.on_frame_boundary();
            if self.frame_count % 16 == 0 {
                // ~1.56Hz, matching real hardware
                self.ula.flash_state = !self.ula.flash_state;
            }
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

    /// Steps over a HALT and everything the resulting interrupt triggers
    /// (the ISR), stopping only once execution has genuinely reached
    /// `target_pc` (normally `halt_addr + 1`, the instruction right after
    /// HALT) with the CPU no longer halted. A plain address check on `pc`
    /// alone is NOT enough here, and using one is a real bug this replaced:
    /// while halted, `Cpu::registers().pc` reads as `halt_addr + 1`
    /// continuously (see its doc comment) -- the SAME value `target_pc`
    /// normally holds -- so an address-only breakpoint fires the instant
    /// this exact HALT is (re-)entered and starts waiting, not only once
    /// a real return has happened. That's not a hypothetical: a loop
    /// shaped `HALT; <body>; JP` (extremely common -- an interrupt-driven
    /// main loop) re-enters the very same HALT every pass, so the false
    /// match was hit on effectively every real program, not just this
    /// project's own test fixture.
    ///
    /// Checking `!halted` alongside the address fixes it, and for free
    /// handles the other case an address-only check also got wrong: a
    /// SECOND interrupt firing before the first ISR's own RET completes
    /// (real hardware can absolutely do this if the ISR runs long) just
    /// detours through another ISR pass -- `pc` sits elsewhere throughout,
    /// the condition stays unmet, and this keeps looping through it
    /// automatically rather than exiting on a return address it never
    /// actually reached yet.
    ///
    /// Bounded by roughly one frame's worth of instructions in the
    /// ordinary case (an interrupt is guaranteed within `FRAME_TSTATES`),
    /// but genuinely unbounded if interrupts are disabled or `target_pc`
    /// is never actually reached -- matching real hardware, where a HALT
    /// with interrupts disabled hangs forever too.
    pub fn step_over_halt(&mut self, target_pc: u16) {
        loop {
            self.step_instruction();
            if !self.cpu.halted && self.registers().pc == target_pc {
                break;
            }
        }
    }

    /// Runs exactly one video frame's worth of T-states (~69888). `tick()`
    /// itself now advances exactly one real T-state per call (see its own
    /// doc comment), so a fixed `for _ in 0..FRAME_TSTATES` loop would
    /// technically also work -- looping on `frame_count` instead is just
    /// the more robust/obviously-correct expression of "until the frame
    /// boundary fires," independent of the exact T-state count.
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
