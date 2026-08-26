use zx_core::spectrum::Spectrum48K;
use zx_core::ula::FIRST_CONTENDED_TSTATE;

fn load_program(m: &mut Spectrum48K, addr: u16, code: &[u8]) {
    m.write_memory(addr, code);
    let mut regs = m.registers();
    regs.pc = addr;
    m.set_registers(regs);
}

#[test]
fn out_c_a_to_a_contended_port_costs_the_plain_12_tstates_while_io_contention_is_disabled() {
    let mut machine = Spectrum48K::new();
    load_program(&mut machine, 0x8000, &[0xED, 0x79]); // OUT (C),A
    let mut regs = machine.registers();
    regs.b = 0x40; // high byte in the contended page (0x40-0x7F)
    regs.c = 0xFE; // low bit clear -- classic ULA-port shape
    machine.set_registers(regs);

    machine.tstates = FIRST_CONTENDED_TSTATE - 3;
    let start = machine.tstates;

    machine.step_instruction();

    let actual_cost = machine.tstates - start;
    println!("actual_cost = {actual_cost}");
    assert_eq!(actual_cost, 12, "IO contention is documented as disabled -- OUT (C),A should cost the plain, uncontended 12 T-states");
}

#[test]
fn in_a_c_from_a_contended_port_costs_the_plain_12_tstates_while_io_contention_is_disabled() {
    let mut machine = Spectrum48K::new();
    load_program(&mut machine, 0x8000, &[0xED, 0x78]); // IN A,(C)
    let mut regs = machine.registers();
    regs.b = 0x40; // high byte in the contended page (0x40-0x7F)
    regs.c = 0xFE; // low bit clear -- classic ULA-port shape
    machine.set_registers(regs);

    machine.tstates = FIRST_CONTENDED_TSTATE - 3;
    let start = machine.tstates;

    machine.step_instruction();

    let actual_cost = machine.tstates - start;
    println!("actual_cost = {actual_cost}");
    assert_eq!(actual_cost, 12, "IO contention is documented as disabled -- IN A,(C) should cost the plain, uncontended 12 T-states");
}
