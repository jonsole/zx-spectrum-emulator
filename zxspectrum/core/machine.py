"""Spectrum48K: wires the Z80 core, memory, ULA and keyboard into one machine.

Owns the tick loop that interprets z80.h's pin mask each T-state to service
memory and IO requests, and exposes the debug primitives (step, breakpoints,
register/memory access, screen render) that the engine drives.
"""
from __future__ import annotations

from zxspectrum.core import z80
from zxspectrum.core.keyboard import Keyboard
from zxspectrum.core.memory import Memory
from zxspectrum.core.snapshot import parse_sna
from zxspectrum.core.ula import FRAME_TSTATES, ULA
from zxspectrum.core.z80 import Registers, Z80

# Interrupt vector byte for IM1 -- IM1 always executes RST 38h regardless of
# what's on the data bus during the ack cycle, but z80.h still reads a byte.
_INT_ACK_BYTE = 0xFF


class Spectrum48K:
    def __init__(self) -> None:
        self.cpu = Z80()
        self.memory = Memory()
        self.keyboard = Keyboard()
        self.ula = ULA()
        self.tstates = 0
        self.frame_count = 0
        self.breakpoints: set[int] = set()
        self._int_pending = False
        self._prime_fetch()

    # -- loading -----------------------------------------------------------

    def load_rom(self, data: bytes) -> None:
        self.memory.load_rom(data)

    def load_snapshot(self, data: bytes) -> None:
        image = parse_sna(data)
        self.memory.ram[:] = image.ram
        self.set_registers(image.regs)
        self.ula.border = image.border
        self.tstates = 0
        self._int_pending = False

    # -- reset / registers / memory -----------------------------------------

    def reset(self) -> None:
        self.cpu.pins = self.cpu.reset()
        self.tstates = 0
        self.frame_count = 0
        self._int_pending = False
        self._prime_fetch()

    @property
    def registers(self) -> Registers:
        # z80_opdone() fires exactly when the overlapped fetch has already
        # consumed the first byte of the NEXT instruction, so the raw PC
        # register always reads one byte past the address that instruction
        # actually starts at -- for sequential code this is invisible
        # (address+1 IS the next instruction anyway), but it's a real,
        # user-visible bug for anything reached via a jump/call/RST: e.g.
        # after `JP 0x11CB` the raw register reads 0x11CC, so a breakpoint
        # at 0x11CB (or a disassembly/stack-trace label at PC) would silently
        # never match. Every external caller (breakpoints, DAP stackTrace/
        # variables, MCP get_registers) wants "the address of the
        # instruction about to execute", so that's what's reported here;
        # verified empirically to hold across sequential, jump, and HALT
        # cases (get_addr(cpu.pins) == raw_pc - 1 in all three).
        #
        # Known narrow limitation: if set_registers()/load_snapshot() points
        # PC at a prefix byte (CB/ED/DD/FD) and registers is read before any
        # step_instruction() call, the single priming tick hasn't reached an
        # opdone-equivalent boundary yet (prefix decode suppresses it), so
        # the "-1" correction doesn't apply cleanly. Rare in practice --
        # normal use always steps before inspecting state.
        regs = self.cpu.get_regs()
        regs.pc = (regs.pc - 1) & 0xFFFF
        return regs

    def set_registers(self, regs: Registers) -> None:
        # z80.h's z80_set_regs() only overwrites the register struct -- it
        # doesn't touch the CPU's internal fetch/decode pipeline, so a plain
        # PC write is silently ignored on the next tick. z80_prefetch() is
        # the documented way to actually redirect execution.
        self.cpu.set_regs(regs)
        self.cpu.prefetch(regs.pc)
        self._prime_fetch()

    def _prime_fetch(self) -> None:
        # z80_prefetch()/z80_reset() leave cpu->step reset to the start of an
        # overlapped fetch, but z80_opdone() reports true on the very next
        # tick regardless -- an artifact of the overlapped-fetch pipeline
        # (M1|RD already set), not a completed instruction. Consuming that
        # tick here means step_instruction()/run() always see one real
        # instruction boundary per call, immediately after any PC change.
        self.tick()

    def read_memory(self, addr: int, length: int = 1) -> bytes:
        return self.memory.read_block(addr, length)

    def write_memory(self, addr: int, data: bytes) -> None:
        self.memory.write_block(addr, data)

    def render_screen(self):
        return self.ula.decode_screen(self.memory)

    # -- tick loop -----------------------------------------------------------

    def tick(self) -> None:
        """Advance exactly one T-state, servicing whatever the bus asks for."""
        pins = self.cpu.pins
        if self._int_pending:
            pins |= z80.INT
        else:
            pins &= ~z80.INT
        self.cpu.pins = pins

        pins = self.cpu.tick()

        if pins & z80.MREQ:
            addr = z80.get_addr(pins)
            if pins & z80.RD:
                pins = z80.set_data(pins, self.memory.read(addr))
                self.cpu.pins = pins
            elif pins & z80.WR:
                self.memory.write(addr, z80.get_data(pins))
        elif pins & z80.IORQ:
            addr = z80.get_addr(pins)
            if pins & z80.M1:
                # interrupt acknowledge cycle
                self.cpu.pins = z80.set_data(pins, _INT_ACK_BYTE)
                self._int_pending = False
            elif pins & z80.RD:
                if (addr & 0x01) == 0:
                    value = self.keyboard.read_port(addr >> 8)
                else:
                    value = 0xFF  # unmapped port; floating-bus behavior not modeled
                self.cpu.pins = z80.set_data(pins, value)
            elif pins & z80.WR:
                if (addr & 0x01) == 0:
                    self.ula.border = z80.get_data(pins) & 0x07
                    # bits 3/4 (MIC/speaker) tracked nowhere yet -- no audio in v1

        self.tstates += 1
        if self.tstates >= FRAME_TSTATES:
            self.tstates -= FRAME_TSTATES
            self._int_pending = True
            self.frame_count += 1
            if self.frame_count % 16 == 0:  # ~1.56Hz, matching real hardware
                self.ula.flash_state = not self.ula.flash_state

    def step_instruction(self) -> None:
        """Run T-states until the current instruction completes."""
        self.tick()
        while not self.cpu.opdone:
            self.tick()

    def run_frame(self) -> None:
        """Run exactly one video frame's worth of T-states (~69888)."""
        for _ in range(FRAME_TSTATES):
            self.tick()

    def run(self, max_instructions: int = 10_000_000) -> str:
        """Run until a breakpoint is hit; returns 'breakpoint' or 'limit'."""
        for _ in range(max_instructions):
            self.step_instruction()
            if self.registers.pc in self.breakpoints:
                return "breakpoint"
        return "limit"
