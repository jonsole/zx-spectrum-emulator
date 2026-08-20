"""Step-1 smoke test: does the native shim actually run Z80 code end to end?"""
from zxspectrum.core import z80


def step_instruction(cpu: z80.Z80, mem: bytearray) -> None:
    """Tick until the current instruction completes, servicing memory pins."""
    cpu.tick()
    while not cpu.opdone:
        service_memory(cpu, mem)
        cpu.tick()
    service_memory(cpu, mem)


def service_memory(cpu: z80.Z80, mem: bytearray) -> None:
    pins = cpu.pins
    if pins & z80.MREQ:
        addr = z80.get_addr(pins)
        if pins & z80.RD:
            pins = z80.set_data(pins, mem[addr])
        elif pins & z80.WR:
            mem[addr] = z80.get_data(pins)
        cpu.pins = pins


def test_no_memory_attached_free_runs_nops():
    # With the data bus floating at zero, every fetched opcode is a NOP, so
    # PC should simply free-run through the address space (chips z80.h's own
    # documented behavior for "no memory attached").
    cpu = z80.Z80()
    for _ in range(4):
        step_instruction(cpu, bytearray(0x10000))
    regs = cpu.get_regs()
    assert regs.pc == 4


def test_hand_assembled_program():
    # LD A,0x42 ; LD B,A ; HALT
    mem = bytearray(0x10000)
    mem[0:5] = bytes([0x3E, 0x42, 0x47, 0x76, 0x00])

    cpu = z80.Z80()
    for _ in range(4):
        step_instruction(cpu, mem)

    regs = cpu.get_regs()
    assert regs.af >> 8 == 0x42       # A
    assert regs.bc >> 8 == 0x42       # B
    assert regs.pc == 4               # HALT keeps re-fetching itself at PC=4
    assert cpu.pins & z80.HALT
