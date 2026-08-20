"""The shared live emulator instance.

Engine owns the single Spectrum48K and is the only thing allowed to touch
it. Front-ends (MCP tools, the DAP server) never call core/machine.py
directly -- they call the async methods below, which enqueue a Command and
await its reply. Because every mutation is funneled through one asyncio
task (`_loop`), this needs no locks: it's just cooperative scheduling, but
it guarantees two front-ends driving the same machine concurrently always
see consistent state, and each is notified (via the event fan-out) of
changes the other one made.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any

from zxspectrum.core.machine import Spectrum48K
from zxspectrum.core.z80 import Registers
from zxspectrum.engine import commands as cmd

# How many instructions a Run executes between checks for an incoming Pause
# (or any other queued command) -- keeps a long-running program from
# starving the event loop.
_RUN_YIELD_EVERY = 2000


@dataclass
class _Envelope:
    command: Any
    future: asyncio.Future


class Engine:
    def __init__(self) -> None:
        self.machine = Spectrum48K()
        self._queue: asyncio.Queue[_Envelope] = asyncio.Queue()
        self._subscribers: list[asyncio.Queue[Any]] = []
        self._running = False
        self._pause_requested = False
        self._task: asyncio.Task | None = None

    def start(self) -> None:
        self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None

    # -- subscriptions ---------------------------------------------------

    def subscribe(self) -> asyncio.Queue[Any]:
        q: asyncio.Queue[Any] = asyncio.Queue()
        self._subscribers.append(q)
        return q

    def unsubscribe(self, q: asyncio.Queue[Any]) -> None:
        self._subscribers.remove(q)

    async def _publish(self, event: Any) -> None:
        for q in self._subscribers:
            await q.put(event)

    # -- request/reply -----------------------------------------------------

    async def submit(self, command: Any) -> Any:
        future: asyncio.Future = asyncio.get_running_loop().create_future()
        await self._queue.put(_Envelope(command, future))
        return await future

    # -- convenience wrappers (what front-ends actually call) ----------------

    async def step(self, instructions: int = 1, ticks: int | None = None) -> None:
        return await self.submit(cmd.Step(instructions=instructions, ticks=ticks))

    async def run(self) -> None:
        return await self.submit(cmd.Run())

    async def pause(self) -> None:
        # Deliberately NOT a queued command: Run()'s handler monopolizes the
        # actor loop until it yields, so a Pause sent through the same queue
        # could never be dequeued while Run() is in flight -- it would
        # deadlock waiting for the very thing it's supposed to interrupt.
        # Setting the flag directly lets it take effect on Run()'s next
        # cooperative `asyncio.sleep(0)` regardless of queue backlog.
        self._pause_requested = True

    async def reset(self) -> None:
        return await self.submit(cmd.Reset())

    async def set_breakpoint(self, addr: int) -> None:
        return await self.submit(cmd.SetBreakpoint(addr))

    async def clear_breakpoint(self, addr: int) -> None:
        return await self.submit(cmd.ClearBreakpoint(addr))

    async def read_memory(self, addr: int, length: int = 1) -> bytes:
        return await self.submit(cmd.ReadMemory(addr, length))

    async def write_memory(self, addr: int, data: bytes) -> None:
        return await self.submit(cmd.WriteMemory(addr, data))

    async def get_registers(self) -> Registers:
        return await self.submit(cmd.GetRegisters())

    async def set_registers(self, regs: Registers) -> None:
        return await self.submit(cmd.SetRegisters(regs))

    async def key_down(self, key: str) -> None:
        return await self.submit(cmd.KeyDown(key))

    async def key_up(self, key: str) -> None:
        return await self.submit(cmd.KeyUp(key))

    async def get_screen(self):
        return await self.submit(cmd.GetScreen())

    async def get_state(self) -> cmd.State:
        return await self.submit(cmd.GetState())

    async def load_rom(self, data: bytes) -> None:
        return await self.submit(cmd.LoadRom(data))

    async def load_snapshot(self, data: bytes) -> None:
        return await self.submit(cmd.LoadSnapshot(data))

    # -- the actor loop ----------------------------------------------------

    async def _loop(self) -> None:
        while True:
            envelope = await self._queue.get()
            try:
                result = await self._handle(envelope.command)
                if not envelope.future.done():
                    envelope.future.set_result(result)
            except Exception as exc:  # surface to the caller, don't die silently
                if not envelope.future.done():
                    envelope.future.set_exception(exc)

    async def _handle(self, command: Any) -> Any:
        m = self.machine

        if isinstance(command, cmd.Step):
            if command.ticks is not None:
                for _ in range(command.ticks):
                    m.tick()
            else:
                for _ in range(command.instructions):
                    m.step_instruction()
            await self._publish(cmd.Stopped(reason="step", pc=m.registers.pc))
            return None

        if isinstance(command, cmd.Run):
            self._pause_requested = False
            self._running = True
            await self._publish(cmd.Continued())
            reason = "breakpoint"
            count = 0
            while not self._pause_requested:
                m.step_instruction()
                count += 1
                if m.registers.pc in m.breakpoints:
                    break
                if count % _RUN_YIELD_EVERY == 0:
                    await asyncio.sleep(0)
            else:
                reason = "pause"
            self._running = False
            await self._publish(cmd.Stopped(reason=reason, pc=m.registers.pc))
            return None

        if isinstance(command, cmd.Reset):
            m.reset()
            await self._publish(cmd.ResetEvent())
            await self._publish(cmd.Stopped(reason="entry", pc=m.registers.pc))
            return None

        if isinstance(command, cmd.SetBreakpoint):
            m.breakpoints.add(command.addr)
            return None

        if isinstance(command, cmd.ClearBreakpoint):
            m.breakpoints.discard(command.addr)
            return None

        if isinstance(command, cmd.ReadMemory):
            return m.read_memory(command.addr, command.length)

        if isinstance(command, cmd.WriteMemory):
            m.write_memory(command.addr, command.data)
            return None

        if isinstance(command, cmd.GetRegisters):
            return m.registers

        if isinstance(command, cmd.SetRegisters):
            m.set_registers(command.regs)
            await self._publish(cmd.Stopped(reason="step", pc=m.registers.pc))
            return None

        if isinstance(command, cmd.KeyDown):
            m.keyboard.key_down(command.key)
            return None

        if isinstance(command, cmd.KeyUp):
            m.keyboard.key_up(command.key)
            return None

        if isinstance(command, cmd.GetScreen):
            return m.render_screen()

        if isinstance(command, cmd.GetState):
            return cmd.State(
                pc=m.registers.pc,
                registers=m.registers,
                breakpoints=frozenset(m.breakpoints),
                running=self._running,
                border=m.ula.border,
            )

        if isinstance(command, cmd.LoadRom):
            m.load_rom(command.data)
            return None

        if isinstance(command, cmd.LoadSnapshot):
            m.load_snapshot(command.data)
            await self._publish(cmd.Stopped(reason="entry", pc=m.registers.pc))
            return None

        raise TypeError(f"unknown command: {command!r}")
