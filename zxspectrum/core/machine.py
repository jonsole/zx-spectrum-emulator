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

# Opcodes that push a return address and jump to a callee -- CALL nn, CALL
# cc,nn, and every RST. Whether a conditional CALL actually pushed anything
# is confirmed afterward by checking SP, not decided here.
_CALL_OPCODES = frozenset({0xCD, 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC})
_RST_OPCODES = frozenset({0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF})
# RET / RET cc -- pairs with a tracked _CALL_OPCODES/_RST_OPCODES push.
_RET_OPCODES = frozenset({0xC9, 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8})


def _classify_step(read_byte, addr: int) -> str | None:
    """Classify the opcode at `addr` for call_stack tracking purposes.
    Returns "call" (CALL/RST -- may push a return address), "ret" (RET/RET
    cc -- may pop one), or None (everything else). Skips redundant DD/FD
    prefixes the same way the real CPU does before classifying the
    underlying opcode.

    RETI/RETN (0xED 0x4D / 0xED 0x45) fall under the ED-prefixed None case
    deliberately, not "ret": they return from an interrupt, and this
    emulator doesn't push a call_stack frame for interrupt entry either
    (that happens inside z80.h's own microcode during tick(), invisible at
    the opcode level this classifier works at) -- treating both ends as an
    untracked no-op keeps call_stack correct for the CALL/RET pairs it DOES
    see instead of popping a real one that was never the interrupt's.
    """
    a = addr & 0xFFFF
    op = read_byte(a)
    while op in (0xDD, 0xFD):
        a = (a + 1) & 0xFFFF
        op = read_byte(a)
    if op == 0xED:
        return None
    if op in _CALL_OPCODES or op in _RST_OPCODES:
        return "call"
    if op in _RET_OPCODES:
        return "ret"
    return None


class Spectrum48K:
    def __init__(self) -> None:
        self.cpu = Z80()
        self.memory = Memory()
        self.keyboard = Keyboard()
        self.ula = ULA()
        self.tstates = 0
        self.frame_count = 0
        self.breakpoints: set[int] = set()
        # Return addresses for CALL/RST frames currently unwound below the
        # current PC, oldest first -- see _classify_step() for how it's
        # kept in sync with actual execution. Cleared on reset/snapshot
        # load/set_registers since any of those can redirect PC outside
        # normal call/return flow, making a stale call chain actively
        # misleading rather than just incomplete.
        self.call_stack: list[int] = []
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
        self.call_stack.clear()
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
        # An external PC write can redirect execution outside normal
        # call/return flow (a debugger jumping PC around, a fresh snapshot
        # load), so any tracked call chain is no longer meaningful.
        self.call_stack.clear()
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
        pc_before, sp_before = self.registers.pc, self.registers.sp
        category = _classify_step(self.memory.read, pc_before)

        self.tick()
        while not self.cpu.opdone:
            self.tick()

        if category is None:
            return
        sp_after = self.registers.sp
        if category == "call" and sp_after == (sp_before - 2) & 0xFFFF:
            return_addr = self.memory.read(sp_after) | (self.memory.read((sp_after + 1) & 0xFFFF) << 8)
            self.call_stack.append(return_addr)
        elif category == "ret" and sp_after == (sp_before + 2) & 0xFFFF and self.call_stack:
            self.call_stack.pop()

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
