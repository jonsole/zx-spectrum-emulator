//! Step-1 smoke test, mirroring the Python project's `tests/test_z80_smoke.py`:
//! does this hand-written core actually run Z80 code end to end?
//!
//! Both tests call `set_registers()` before stepping, even with defaults --
//! establishing the convention the rest of this project uses. `Cpu::new()`
//! alone leaves the fetch pipeline genuinely unprimed (it can't safely
//! pre-service the first opcode read without a `Memory` reference, which
//! the constructor doesn't have), so the very first `step()` call from a
//! truly fresh, unprimed `Cpu` is inherently partial -- it can only issue
//! the T1 read request, not complete a whole instruction. That's not a bug
//! in `step()`; it's why priming (which DOES have `mem`) exists.

use zx_core::{Cpu, FlatMemory, Registers};

#[test]
fn zeroed_memory_free_runs_as_nops() {
    let mut mem = FlatMemory::default();
    let mut cpu = Cpu::new();
    cpu.set_registers(Registers::default(), &mut mem);
    for _ in 0..4 {
        cpu.step(&mut mem);
    }
    assert_eq!(cpu.registers().pc, 4);
}

#[test]
fn hand_assembled_program_runs_correctly() {
    // LD A,0x42 ; LD B,A ; HALT
    let mut mem = FlatMemory::default();
    mem.0[0..4].copy_from_slice(&[0x3E, 0x42, 0x47, 0x76]);

    let mut cpu = Cpu::new();
    cpu.set_registers(Registers::default(), &mut mem);
    for _ in 0..4 {
        cpu.step(&mut mem);
    }

    let regs = cpu.registers();
    assert_eq!(regs.a, 0x42);
    assert_eq!(regs.b, 0x42);
    assert_eq!(regs.pc, 4); // HALT keeps re-executing itself at PC=4
    assert!(cpu.halted);
}
