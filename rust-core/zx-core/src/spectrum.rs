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
use crate::ula::{Ula, FRAME_TSTATES};
use crate::Cpu;
use std::collections::HashSet;

/// Interrupt vector byte for IM1 -- IM1 always executes RST 38h regardless
/// of what's on the data bus during the ack cycle, but the real hardware
/// (and this core, once interrupt acknowledgment exists) still reads a
/// byte during that cycle. Matches `machine.py`'s `_INT_ACK_BYTE`.
const INT_ACK_BYTE: u8 = 0xFF;

pub struct Spectrum48K {
    pub cpu: Cpu,
    pub memory: Spectrum48KMemory,
    pub keyboard: Keyboard,
    pub ula: Ula,
    pub tstates: u32,
    pub frame_count: u64,
    pub breakpoints: HashSet<u16>,
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
        self.set_registers(image.regs);
        self.ula.border = image.border;
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
        self.set_registers(Registers::default());
        self.tstates = 0;
        self.frame_count = 0;
        self.int_pending = false;
    }

    pub fn registers(&self) -> Registers {
        self.cpu.registers()
    }

    pub fn set_registers(&mut self, regs: Registers) {
        self.cpu.set_registers(regs, &mut self.memory);
        self.pins = self.cpu.pins();
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

    pub fn render_screen(&mut self) -> Vec<u8> {
        self.ula.decode_screen(&mut self.memory)
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
    /// Mirrors `machine.py::tick()`.
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
                pins = set_data(pins, self.memory.read(addr));
            } else if pins & WR != 0 {
                self.memory.write(addr, get_data(pins));
            }
        } else if pins & IORQ != 0 {
            let addr = get_addr(pins);
            if pins & M1 != 0 {
                // interrupt acknowledge cycle
                pins = set_data(pins, INT_ACK_BYTE);
                self.int_pending = false;
            } else if pins & RD != 0 {
                let value = if addr & 0x01 == 0 {
                    self.keyboard.read_port((addr >> 8) as u8)
                } else {
                    0xFF // unmapped port; floating-bus behavior not modeled
                };
                pins = set_data(pins, value);
            } else if pins & WR != 0 {
                if addr & 0x01 == 0 {
                    self.ula.border = get_data(pins) & 0x07;
                    // bits 3/4 (MIC/speaker) tracked nowhere yet -- no audio
                }
            }
        }

        self.pins = pins;

        self.tstates += 1;
        if self.tstates >= FRAME_TSTATES {
            self.tstates -= FRAME_TSTATES;
            self.int_pending = true;
            self.frame_count += 1;
            if self.frame_count % 16 == 0 {
                // ~1.56Hz, matching real hardware
                self.ula.flash_state = !self.ula.flash_state;
            }
        }
    }

    /// Runs T-states until the current instruction completes.
    pub fn step_instruction(&mut self) {
        self.tick();
        while !self.cpu.is_instruction_boundary(self.pins) {
            self.tick();
        }
    }

    /// Runs exactly one video frame's worth of T-states (~69888).
    pub fn run_frame(&mut self) {
        for _ in 0..FRAME_TSTATES {
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
