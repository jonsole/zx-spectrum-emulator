"""DAP front-end: hand-rolled asyncio TCP server with Content-Length framing.

VS Code's launch.json points at this via "debugServer": <port> -- no
extension packaging needed. Every request is served against the same
Engine instance the MCP server drives: engine-broadcast events (Stopped,
Continued) are forwarded here as unsolicited DAP `stopped`/`continued`
events, so state changes made over MCP show up in VS Code's UI without
VS Code having requested them, and vice versa.

No source file exists in v1 (there's no assembler listing/map), so
breakpoints are instruction breakpoints (set from the Disassembly View),
not source-line breakpoints, and stack traces are a single synthetic
frame at PC, labeled with the disassembled instruction at PC.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
from typing import Any

from zxspectrum.core.disassembler import disassemble_one, disassemble_range
from zxspectrum.engine import commands as cmd
from zxspectrum.engine.actor import Engine

logger = logging.getLogger(__name__)

_THREAD_ID = 1  # one synthetic thread -- the Z80 has no concept of threads
_REGISTERS_VAR_REF = 1000
_FLAGS_VAR_REF = 1001

# (name, bitmask) for the Z80 F register, S Z . H . P/V N C
_FLAG_BITS = [
    ("S", 0x80), ("Z", 0x40), ("H", 0x10), ("P/V", 0x04), ("N", 0x02), ("C", 0x01),
]


async def _read_message(reader: asyncio.StreamReader) -> dict[str, Any] | None:
    headers: dict[str, str] = {}
    while True:
        line = await reader.readline()
        if not line:
            return None  # EOF
        line_str = line.decode("ascii").strip()
        if line_str == "":
            break
        name, _, value = line_str.partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    body = await reader.readexactly(length)
    return json.loads(body.decode("utf-8"))


def _write_message(writer: asyncio.StreamWriter, message: dict[str, Any]) -> None:
    body = json.dumps(message).encode("utf-8")
    writer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)


def _as_addr(value: Any, offset: int = 0) -> int:
    addr = int(value, 16) if isinstance(value, str) else int(value)
    return (addr + offset) & 0xFFFF


class DapConnection:
    def __init__(self, engine: Engine, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.engine = engine
        self.reader = reader
        self.writer = writer
        self._seq = 0
        self._sub: asyncio.Queue | None = None
        self._forward_task: asyncio.Task | None = None

    def _next_seq(self) -> int:
        self._seq += 1
        return self._seq

    async def send_response(
        self, request: dict, success: bool = True, body: dict | None = None, message: str | None = None
    ) -> None:
        msg: dict[str, Any] = {
            "seq": self._next_seq(),
            "type": "response",
            "request_seq": request["seq"],
            "success": success,
            "command": request["command"],
        }
        if body is not None:
            msg["body"] = body
        if message is not None:
            msg["message"] = message
        _write_message(self.writer, msg)
        await self.writer.drain()

    async def send_event(self, event: str, body: dict | None = None) -> None:
        msg: dict[str, Any] = {"seq": self._next_seq(), "type": "event", "event": event}
        if body is not None:
            msg["body"] = body
        _write_message(self.writer, msg)
        await self.writer.drain()

    async def run(self) -> None:
        # Subscribe before handling any request so events published by our
        # own launch()/reset() (or by a concurrent MCP client) are never
        # missed between connecting and the first request.
        self._sub = self.engine.subscribe()
        self._forward_task = asyncio.create_task(self._forward_events())
        try:
            while True:
                message = await _read_message(self.reader)
                if message is None:
                    break
                if message.get("type") == "request":
                    await self._handle_request(message)
        finally:
            if self._forward_task is not None:
                self._forward_task.cancel()
            if self._sub is not None:
                self.engine.unsubscribe(self._sub)
            self.writer.close()

    async def _forward_events(self) -> None:
        assert self._sub is not None
        while True:
            event = await self._sub.get()
            if isinstance(event, cmd.Stopped):
                await self.send_event(
                    "stopped",
                    {"reason": event.reason, "threadId": _THREAD_ID, "allThreadsStopped": True},
                )
            elif isinstance(event, cmd.Continued):
                await self.send_event("continued", {"threadId": _THREAD_ID, "allThreadsContinued": True})
            # ResetEvent has no direct DAP equivalent; the Stopped(reason="entry")
            # that reset()/load_snapshot() always publish alongside it covers it.

    async def _handle_request(self, request: dict) -> None:
        command = request["command"]
        args = request.get("arguments") or {}
        handler = getattr(self, f"_cmd_{command}", None)
        if handler is None:
            await self.send_response(request, success=False, message=f"unsupported request: {command}")
            return
        try:
            body = await handler(args)
            await self.send_response(request, success=True, body=body)
            if command == "initialize":
                # Per spec: `initialized` follows the initialize response,
                # signaling the adapter is ready for setBreakpoints etc.
                await self.send_event("initialized")
        except Exception as exc:
            logger.exception("DAP request %s failed", command)
            await self.send_response(request, success=False, message=str(exc))

    # -- requests ------------------------------------------------------

    async def _cmd_initialize(self, args: dict) -> dict:
        return {
            "supportsConfigurationDoneRequest": True,
            "supportsInstructionBreakpoints": True,
            "supportsReadMemoryRequest": True,
            "supportsWriteMemoryRequest": True,
            "supportsDisassembleRequest": True,
            "supportsSteppingGranularity": False,
        }

    async def _cmd_launch(self, args: dict) -> dict:
        rom_path = args.get("rom")
        if rom_path:
            with open(rom_path, "rb") as f:
                await self.engine.load_rom(f.read())
        snapshot_path = args.get("snapshot")
        if snapshot_path:
            with open(snapshot_path, "rb") as f:
                await self.engine.load_snapshot(f.read())
        else:
            await self.engine.reset()
        return {}

    async def _cmd_attach(self, args: dict) -> dict:
        return {}

    async def _cmd_configurationDone(self, args: dict) -> dict:
        return {}

    async def _cmd_setInstructionBreakpoints(self, args: dict) -> dict:
        # DAP semantics: each call replaces the full breakpoint set.
        state = await self.engine.get_state()
        for addr in list(state.breakpoints):
            await self.engine.clear_breakpoint(addr)
        breakpoints = []
        for bp in args.get("breakpoints", []):
            addr = _as_addr(bp["instructionReference"], bp.get("offset", 0))
            await self.engine.set_breakpoint(addr)
            breakpoints.append({"verified": True, "instructionReference": f"0x{addr:04X}"})
        return {"breakpoints": breakpoints}

    async def _cmd_continue(self, args: dict) -> dict:
        # Must not block the response on run() completing -- it may run
        # until a breakpoint fires arbitrarily far in the future. The
        # eventual stop is reported via the forwarded Stopped event.
        asyncio.create_task(self.engine.run())
        return {"allThreadsContinued": True}

    async def _cmd_next(self, args: dict) -> dict:
        await self.engine.step()
        return {}

    async def _cmd_stepIn(self, args: dict) -> dict:
        await self.engine.step()
        return {}

    async def _cmd_stepOut(self, args: dict) -> dict:
        await self.engine.step()
        return {}

    async def _cmd_pause(self, args: dict) -> dict:
        await self.engine.pause()
        return {}

    async def _cmd_threads(self, args: dict) -> dict:
        return {"threads": [{"id": _THREAD_ID, "name": "Z80"}]}

    async def _cmd_stackTrace(self, args: dict) -> dict:
        regs = await self.engine.get_registers()
        inst = disassemble_one(self._read_memory_sync, regs.pc)
        frame = {
            "id": 1,
            "name": f"0x{regs.pc:04X}: {inst.text}",
            "instructionPointerReference": f"0x{regs.pc:04X}",
            "line": 0,
            "column": 0,
        }
        return {"stackFrames": [frame], "totalFrames": 1}

    def _read_memory_sync(self, addr: int) -> int:
        # Disassembly is read-only and doesn't mutate machine state, so it
        # doesn't need to go through the engine's command queue -- reading
        # directly avoids round-tripping every single byte through submit().
        return self.engine.machine.memory.read(addr)

    async def _cmd_disassemble(self, args: dict) -> dict:
        base_addr = _as_addr(args["memoryReference"], args.get("offset", 0))
        instruction_offset = args.get("instructionOffset", 0)
        count = args["instructionCount"]

        if instruction_offset >= 0:
            start = base_addr
        else:
            # Z80 opcodes are variable-length, so there's no way to jump
            # straight to "N instructions before base_addr" -- search
            # backward for a start address that, decoded forward, lands
            # exactly on base_addr after `-instruction_offset`
            # instructions. Falls back to base_addr itself (no "before"
            # instructions) if no aligned start is found within range.
            start = self._find_aligned_backward_start(base_addr, -instruction_offset)

        instructions = disassemble_range(self._read_memory_sync, start, count)
        return {
            "instructions": [
                {"address": f"0x{i.addr:04X}", "instructionBytes": i.raw.hex(), "instruction": i.text}
                for i in instructions
            ]
        }

    def _find_aligned_backward_start(self, base_addr: int, needed_before: int, max_search: int = 64) -> int:
        for back in range(1, max_search + 1):
            candidate = (base_addr - back) & 0xFFFF
            addr = candidate
            count = 0
            while addr < base_addr:
                inst = disassemble_one(self._read_memory_sync, addr)
                addr += inst.length
                count += 1
                if addr > base_addr:
                    break
            if addr == base_addr and count == needed_before:
                return candidate
        return base_addr

    async def _cmd_scopes(self, args: dict) -> dict:
        return {
            "scopes": [
                {"name": "Registers", "variablesReference": _REGISTERS_VAR_REF, "expensive": False},
                {"name": "Flags", "variablesReference": _FLAGS_VAR_REF, "expensive": False},
            ]
        }

    async def _cmd_variables(self, args: dict) -> dict:
        ref = args["variablesReference"]
        regs = await self.engine.get_registers()

        if ref == _REGISTERS_VAR_REF:
            def reg(name: str, value: int) -> dict:
                return {
                    "name": name,
                    "value": f"0x{value:04X}",
                    "variablesReference": 0,
                    "memoryReference": f"0x{value:04X}",
                }

            return {
                "variables": [
                    reg("PC", regs.pc), reg("SP", regs.sp),
                    reg("AF", regs.af), reg("BC", regs.bc),
                    reg("DE", regs.de), reg("HL", regs.hl),
                    reg("IX", regs.ix), reg("IY", regs.iy),
                    reg("AF'", regs.af2), reg("BC'", regs.bc2),
                    reg("DE'", regs.de2), reg("HL'", regs.hl2),
                    {"name": "IM", "value": str(regs.im), "variablesReference": 0},
                    {"name": "IFF1", "value": str(regs.iff1), "variablesReference": 0},
                    {"name": "IFF2", "value": str(regs.iff2), "variablesReference": 0},
                ]
            }

        if ref == _FLAGS_VAR_REF:
            f = regs.af & 0xFF
            return {
                "variables": [
                    {"name": name, "value": str(bool(f & bit)), "variablesReference": 0}
                    for name, bit in _FLAG_BITS
                ]
            }

        return {"variables": []}

    async def _cmd_readMemory(self, args: dict) -> dict:
        addr = _as_addr(args["memoryReference"], args.get("offset", 0))
        data = await self.engine.read_memory(addr, args["count"])
        return {"address": f"0x{addr:04X}", "data": base64.b64encode(data).decode()}

    async def _cmd_writeMemory(self, args: dict) -> dict:
        addr = _as_addr(args["memoryReference"], args.get("offset", 0))
        data = base64.b64decode(args["data"])
        await self.engine.write_memory(addr, data)
        return {"bytesWritten": len(data)}

    async def _cmd_disconnect(self, args: dict) -> dict:
        return {}


async def create_dap_server(engine: Engine, host: str = "127.0.0.1", port: int = 4711):
    async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await DapConnection(engine, reader, writer).run()

    return await asyncio.start_server(handle_client, host, port)
