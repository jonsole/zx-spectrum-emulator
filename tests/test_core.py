import numpy as np
import pytest

from zxspectrum.core.keyboard import Keyboard
from zxspectrum.core.machine import Spectrum48K
from zxspectrum.core.memory import Memory
from zxspectrum.core.snapshot import HEADER_SIZE, SNA_48K_SIZE, parse_sna
from zxspectrum.core.ula import ULA, attr_addr, pixel_addr
from zxspectrum.core.z80 import Registers


# -- memory --------------------------------------------------------------

def test_rom_is_write_protected():
    mem = Memory()
    mem.load_rom(bytes([0xAA]) * 0x4000)
    mem.write(0x0000, 0xFF)
    assert mem.read(0x0000) == 0xAA


def test_ram_read_write():
    mem = Memory()
    mem.write(0x8000, 0x42)
    assert mem.read(0x8000) == 0x42


# -- keyboard --------------------------------------------------------------

def test_keyboard_single_key():
    kb = Keyboard()
    kb.key_down("A")
    # row 1 (0xFDFE half-row) selected by address bit 1 low -> high byte 0xFD
    assert kb.read_port(0xFD) == 0b11110  # bit0 (A) held low
    assert kb.read_port(0xFE) == 0x1F     # row 0 unaffected


def test_keyboard_combined_rows_or_together():
    kb = Keyboard()
    kb.key_down("Z")   # row 0, bit 1
    kb.key_down("A")   # row 1, bit 0
    # selecting both rows 0 and 1 (high byte with bits 0 and 1 clear -> 0xFC)
    combined = kb.read_port(0xFC)
    assert combined == (kb.read_port(0xFE) & kb.read_port(0xFD))


def test_keyboard_up_clears():
    kb = Keyboard()
    kb.key_down("Q")
    kb.key_up("Q")
    assert kb.read_port(0xFB) == 0x1F


# -- ULA ---------------------------------------------------------------

def test_pixel_addr_known_positions():
    # top-left byte of the display file
    assert pixel_addr(0, 0) == 0x4000
    # first pixel row of the second "third" (y=64) starts at 0x4000 + 0x800
    assert pixel_addr(0, 64) == 0x4800
    # last pixel row (y=191) columns 0-7
    assert pixel_addr(0, 191) < 0x5800


def test_attr_addr_known_positions():
    assert attr_addr(0, 0) == 0x5800
    assert attr_addr(0, 8) == 0x5800 + 32


def test_decode_screen_solid_ink():
    mem = Memory()
    # set every pixel byte in the display file to 0xFF (all ink)
    for addr in range(0x4000, 0x5800):
        mem.write(addr, 0xFF)
    # attribute: ink=white(7), paper=black(0), not bright, not flash
    for addr in range(0x5800, 0x5B00):
        mem.write(addr, 0b00000111)

    ula = ULA()
    frame = ula.decode_screen(mem)
    assert frame.shape == (192, 256, 3)
    assert np.array_equal(frame[0, 0], [0xCD, 0xCD, 0xCD])  # white, normal brightness


# -- snapshot --------------------------------------------------------------

def _build_sna(pc: int, sp: int = 0x8000) -> bytes:
    header = bytearray(HEADER_SIZE)
    header[23] = sp & 0xFF
    header[24] = (sp >> 8) & 0xFF
    header[26] = 2  # border = red
    ram = bytearray(0xC000)
    # push `pc` onto the simulated stack at `sp`
    stack_off = sp - 0x4000
    ram[stack_off] = pc & 0xFF
    ram[stack_off + 1] = (pc >> 8) & 0xFF
    return bytes(header) + bytes(ram)


def test_parse_sna_pops_pc_from_stack():
    data = _build_sna(pc=0x9000, sp=0x8000)
    image = parse_sna(data)
    assert image.regs.pc == 0x9000
    assert image.regs.sp == 0x8002
    assert image.border == 2


def test_parse_sna_rejects_wrong_size():
    with pytest.raises(ValueError):
        parse_sna(b"\x00" * 10)


# -- machine (integration) ------------------------------------------------

def _load_program(m: Spectrum48K, addr: int, code: bytes) -> None:
    m.write_memory(addr, code)
    regs = m.registers
    regs.pc = addr
    m.set_registers(regs)


def test_step_instruction_runs_hand_assembled_program():
    m = Spectrum48K()
    _load_program(m, 0x8000, bytes([0x3E, 0x42, 0x47]))  # LD A,0x42 ; LD B,A
    m.step_instruction()
    m.step_instruction()
    regs = m.registers
    assert regs.af >> 8 == 0x42
    assert regs.bc >> 8 == 0x42


def test_keyboard_io_through_bus():
    m = Spectrum48K()
    m.keyboard.key_down("1")  # row 3, bit 0
    # LD A,0xF7 ; IN A,(0xFE)  -- port = (A<<8)|n = 0xF7FE, selects row 3
    _load_program(m, 0x8000, bytes([0x3E, 0xF7, 0xDB, 0xFE]))
    m.step_instruction()
    m.step_instruction()
    assert m.registers.af >> 8 == 0b11110


def test_border_out_through_bus():
    m = Spectrum48K()
    # LD A,4 ; OUT (0xFE),A
    _load_program(m, 0x8000, bytes([0x3E, 0x04, 0xD3, 0xFE]))
    m.step_instruction()
    m.step_instruction()
    assert m.ula.border == 4


def test_run_to_breakpoint():
    m = Spectrum48K()
    _load_program(m, 0x8000, bytes([0x00, 0x00, 0x76]))  # NOP; NOP; HALT
    m.breakpoints.add(0x8002)
    result = m.run(max_instructions=10)
    assert result == "breakpoint"
    assert m.registers.pc == 0x8002


def test_maskable_interrupt_fires_at_frame_boundary():
    m = Spectrum48K()
    # IM 1 ; EI ; NOP  (EI delays acceptance by one instruction, hence the NOP)
    _load_program(m, 0x8000, bytes([0xED, 0x56, 0xFB, 0x00]))
    # How many step_instruction() calls land exactly on a 4-byte boundary
    # varies right at a prefetch/reset boundary (an ED-prefixed opcode can
    # fuse with the following byte within a single call) -- run until PC
    # clears the program rather than assuming a fixed call count.
    for _ in range(10):
        if m.registers.pc >= 0x8004:
            break
        m.step_instruction()
    assert m.registers.pc == 0x8004
    assert m.registers.im == 1
    assert m.registers.iff1 is True

    # Run out the rest of the frame; since the following memory is all
    # zeroed (NOPs), the CPU just keeps free-running until tstates wraps,
    # at which point the pending interrupt should redirect execution to
    # the IM1 vector (0x0038) on the next instruction boundary.
    while m.tstates != 0:
        m.tick()
    sp_before = m.registers.sp
    pc_at_interrupt = m.registers.pc
    m.step_instruction()
    regs = m.registers
    # The interrupt response's own completion is itself overlapped with the
    # next opcode fetch (same overlapped-fetch pipeline as any other
    # instruction), so PC can already read one past the vector -- the
    # unambiguous check is the pushed return address and IFF1 having been
    # cleared (real IM1 hardware behavior: further maskable interrupts are
    # disabled until the handler re-enables them).
    assert regs.pc in (0x0038, 0x0039)
    assert regs.iff1 is False
    assert regs.sp == sp_before - 2
    pushed_return_addr = m.read_memory(regs.sp, 1)[0] | (m.read_memory(regs.sp + 1, 1)[0] << 8)
    # The hardware push uses the CPU's raw internal PC (matching real Z80
    # behavior: the pre-fetched-but-unused byte is discarded and refetched
    # after the handler returns), whereas Spectrum48K.registers.pc is the
    # externally-corrected "address of the pending instruction" (raw - 1,
    # see the docstring on the `registers` property) -- so the two are
    # always exactly one apart, not equal.
    assert pushed_return_addr == (pc_at_interrupt + 1) & 0xFFFF
    # The real hardware stack got a push here (SP -= 2, asserted above),
    # but call_stack tracking works at the opcode level (see
    # _classify_step()) and there's no CALL/RST opcode actually sitting at
    # pc_at_interrupt (it's a NOP -- the interrupt intercepts BEFORE that
    # NOP would have been fetched) -- so this must NOT have pushed a
    # call_stack frame. Deliberately untracked, not a bug: see
    # _classify_step()'s docstring on why this is symmetric with RETI/RETN
    # also being untracked.
    assert m.call_stack == []


def _set_sp(m: Spectrum48K, sp: int) -> None:
    regs = m.registers
    regs.sp = sp
    m.set_registers(regs)


def test_call_stack_tracks_a_call_and_its_return():
    m = Spectrum48K()
    _set_sp(m, 0xFF00)
    # 0x8000: CALL 0x9000 (3 bytes, returns to 0x8003) ; 0x9000: RET
    _load_program(m, 0x8000, bytes([0xCD, 0x00, 0x90]))
    m.write_memory(0x9000, bytes([0xC9]))  # RET

    m.step_instruction()  # CALL 0x9000
    assert m.call_stack == [0x8003]
    assert m.registers.pc == 0x9000

    m.step_instruction()  # RET
    assert m.call_stack == []
    assert m.registers.pc == 0x8003


def test_call_stack_tracks_nested_calls_in_order():
    m = Spectrum48K()
    _set_sp(m, 0xFF00)
    # 0x8000: CALL 0x9000 (-> 0x8003)
    # 0x9000: CALL 0x9100 (-> 0x9003)
    # 0x9003: RET
    # 0x9100: RET
    _load_program(m, 0x8000, bytes([0xCD, 0x00, 0x90]))
    m.write_memory(0x9000, bytes([0xCD, 0x00, 0x91]))
    m.write_memory(0x9003, bytes([0xC9]))
    m.write_memory(0x9100, bytes([0xC9]))

    m.step_instruction()  # CALL 0x9000
    assert m.call_stack == [0x8003]
    m.step_instruction()  # CALL 0x9100
    assert m.call_stack == [0x8003, 0x9003]
    m.step_instruction()  # RET (inside 0x9100) -> back to 0x9003
    assert m.call_stack == [0x8003]
    assert m.registers.pc == 0x9003
    m.step_instruction()  # RET (at 0x9003) -> back to 0x8003
    assert m.call_stack == []
    assert m.registers.pc == 0x8003


def test_call_stack_tracks_rst():
    m = Spectrum48K()
    _set_sp(m, 0xFF00)
    # RST 0x10 (0xD7, 1 byte, returns to 0x8001) ; the ROM's own
    # PRINT_A_1-equivalent doesn't need to be loaded -- RST just needs to
    # push+jump, whatever's at 0x0010 (unwritten ROM = 0x00 = NOP here).
    _load_program(m, 0x8000, bytes([0xD7]))

    m.step_instruction()
    assert m.call_stack == [0x8001]
    assert m.registers.pc == 0x0010


def test_call_stack_ignores_a_conditional_call_that_is_not_taken():
    m = Spectrum48K()
    _set_sp(m, 0xFF00)
    # XOR A (sets Z) ; CALL NZ,0x9000 -- NZ is false, so the call must not
    # be taken: no frame pushed, and SP/PC just fall through normally.
    _load_program(m, 0x8000, bytes([0xAF, 0xC4, 0x00, 0x90]))

    m.step_instruction()  # XOR A
    sp_before = m.registers.sp
    m.step_instruction()  # CALL NZ,0x9000 (not taken)
    assert m.call_stack == []
    assert m.registers.pc == 0x8004
    assert m.registers.sp == sp_before


def test_call_stack_ignores_a_conditional_ret_that_is_not_taken():
    m = Spectrum48K()
    _set_sp(m, 0xFF00)
    # CALL 0x9000 ; at 0x9000: XOR A (sets Z) ; RET NZ (not taken) ; RET
    _load_program(m, 0x8000, bytes([0xCD, 0x00, 0x90]))
    m.write_memory(0x9000, bytes([0xAF, 0xC0, 0xC9]))  # XOR A ; RET NZ ; RET

    m.step_instruction()  # CALL 0x9000
    assert m.call_stack == [0x8003]
    m.step_instruction()  # XOR A
    sp_before = m.registers.sp
    m.step_instruction()  # RET NZ (not taken)
    assert m.call_stack == [0x8003]  # unchanged -- still inside the call
    assert m.registers.pc == 0x9002
    assert m.registers.sp == sp_before

    m.step_instruction()  # RET (taken)
    assert m.call_stack == []
    assert m.registers.pc == 0x8003


def test_call_stack_is_cleared_by_reset_and_set_registers():
    m = Spectrum48K()
    _set_sp(m, 0xFF00)
    _load_program(m, 0x8000, bytes([0xCD, 0x00, 0x90]))
    m.write_memory(0x9000, bytes([0x76]))  # HALT -- stay put, don't return
    m.step_instruction()
    assert m.call_stack == [0x8003]

    m.reset()
    assert m.call_stack == []

    _set_sp(m, 0xFF00)
    _load_program(m, 0x8000, bytes([0xCD, 0x00, 0x90]))
    m.write_memory(0x9000, bytes([0x76]))
    m.step_instruction()
    assert m.call_stack == [0x8003]

    # A debugger redirecting PC directly (not via CALL/RET) also
    # invalidates whatever call chain was tracked before it.
    regs = m.registers
    regs.pc = 0x8000
    m.set_registers(regs)
    assert m.call_stack == []
