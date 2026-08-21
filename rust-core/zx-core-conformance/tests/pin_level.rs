//! Pin-level differential tests: compare `zx_core::Cpu::tick()`'s
//! returned pins, call-by-call, against the real `z80.h` core's actual
//! `zx_tick()` pins. This is the real verification for the tick-based
//! rewrite (see rust-core's plan) -- proving genuine per-T-state bus
//! fidelity, not just whole-instruction register results, which
//! `differential.rs` already covers separately at the `step()` level.

use zx_core::pins::{get_addr, get_data, set_data, MREQ, RD, WR};
use zx_core::{Cpu, FlatMemory, Memory, Registers};
use zx_core_conformance::ReferenceCpu;

fn service(mem: &mut FlatMemory, pins: u64) -> u64 {
    if pins & MREQ != 0 {
        if pins & RD != 0 {
            return set_data(pins, mem.read(get_addr(pins)));
        } else if pins & WR != 0 {
            mem.write(get_addr(pins), get_data(pins));
        }
    }
    pins
}

#[test]
fn nop_tick_by_tick_pins_match_the_real_z80h_core() {
    let mem_bytes = [0u8; 0x10000]; // all zero == all NOPs

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    let mut new_pins = new_cpu.pins();
    let mut ref_pins = reference.pins();
    assert_eq!(new_pins, ref_pins, "priming tick's pins already diverged");

    for tick in 0..40 {
        new_pins = service(&mut new_mem, new_cpu.tick(new_pins));
        ref_pins = service(&mut reference_mem, reference.tick(ref_pins));
        assert_eq!(
            new_pins, ref_pins,
            "tick {tick}: pins diverged\nnew = {new_pins:#018x}\nref = {ref_pins:#018x}"
        );
    }
    // NOTE: deliberately not comparing `.registers()` here. That's a
    // meaningful comparison right after a `step()`-style boundary (which
    // `differential.rs` already covers extensively), but at an arbitrary
    // raw tick count mid-pipeline, `reference.registers()`'s "raw pc - 1"
    // convention and this core's raw pc don't have to agree pointwise --
    // the tick-by-tick PIN identity just proven above is the actual claim
    // this test exists to verify (genuine per-T-state bus fidelity), not
    // a specific register-reporting convention at an arbitrary sample
    // point.
}

#[test]
fn halt_tick_by_tick_pins_match_the_real_z80h_core() {
    let mut mem_bytes = [0u8; 0x10000];
    mem_bytes[0] = 0x76; // HALT

    let mut new_cpu = Cpu::new();
    let mut new_mem = FlatMemory(mem_bytes);
    new_cpu.set_registers(Registers::default(), &mut new_mem);

    let mut reference = ReferenceCpu::new();
    let mut reference_mem = FlatMemory(mem_bytes);
    reference.set_registers(&Registers::default(), &mut reference_mem);

    let mut new_pins = new_cpu.pins();
    let mut ref_pins = reference.pins();

    // Run well past the HALT (4 T-states to reach it, then several more
    // halted-idle cycles) to confirm the HALT pin stays asserted and both
    // cores freeze identically, not just on the first pass through.
    for tick in 0..24 {
        new_pins = service(&mut new_mem, new_cpu.tick(new_pins));
        ref_pins = service(&mut reference_mem, reference.tick(ref_pins));
        assert_eq!(
            new_pins, ref_pins,
            "tick {tick}: pins diverged\nnew = {new_pins:#018x}\nref = {ref_pins:#018x}"
        );
    }
    assert_eq!(new_cpu.registers(), reference.registers());
    assert!(new_cpu.halted);
    assert_eq!(new_cpu.registers().pc, 1);
}
