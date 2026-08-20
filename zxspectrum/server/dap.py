"""DAP front-end: hand-rolled asyncio TCP server with Content-Length framing.

VS Code's launch.json points at this via "debugServer": <port> -- no
extension packaging needed. Every request is served against the same
Engine instance the MCP server drives: engine-broadcast events (Stopped,
Continued) are forwarded here as unsolicited DAP `stopped`/`continued`
events, so state changes made over MCP show up in VS Code's UI without
VS Code having requested them, and vice versa.

Stack traces are always a single synthetic frame at PC, labeled with the
disassembled instruction there. When debug info is available for the
address -- either the currently-loaded program's own (attached via `launch`
args or MCP's `load_debug_info`) or the ROM's own (built by
scripts/build_rom_source.py, always available once built -- see
rom_source.py) -- that frame also gets a `source`/`line`, and source-line
breakpoints (set by clicking the gutter in that file) are resolved to
addresses via the same SLD data. The loaded program's own debug info takes
priority; the ROM's is checked as a fallback so calling from a loaded
program into a ROM routine still resolves. Without either, only instruction
breakpoints (set from the Disassembly View) are available.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
from pathlib import Path
from typing import Any

from zxspectrum.core.disassembler import disassemble_one, disassemble_range
from zxspectrum.core.rom_source import RomSource, get_rom_source as _get_rom_source
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


_WINDOWS_DRIVE_PATH = re.compile(r"^([A-Za-z]):[\\/](.*)$")


def _normalize_incoming_path(path: str) -> str:
    """Adjust a client-supplied path to whatever this server process can
    actually open.

    This server can run either natively on Windows or inside WSL (see the
    README). A native-Windows VS Code process resolves
    `${workspaceFolder}`-style paths to Windows form (`C:\\...`) before
    sending them in launch requests -- when *this* process is also native
    Windows, that path is already directly usable and is returned
    unchanged. When this process is running inside WSL instead, that same
    Windows-style path needs translating to its /mnt/<drive> equivalent
    first. Anything that isn't a bare Windows drive path (WSL paths,
    relative paths, already-POSIX paths) is always passed through as-is.
    """
    m = _WINDOWS_DRIVE_PATH.match(path)
    if not m or os.name == "nt":
        return path
    drive, rest = m.groups()
    return f"/mnt/{drive.lower()}/{rest.replace('\\', '/')}"


class DapConnection:
    def __init__(self, engine: Engine, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.engine = engine
        self.reader = reader
        self.writer = writer
        self._seq = 0
        self._sub: asyncio.Queue | None = None
        self._forward_task: asyncio.Task | None = None
        # setBreakpoints (source-line) and setInstructionBreakpoints each
        # replace only their own category per the DAP spec, but the engine
        # itself just has one flat address set -- tracked per-category here
        # and reconciled by _sync_breakpoints() so setting one kind doesn't
        # wipe out the other within this connection.
        self._source_breakpoints: dict[str, set[int]] = {}
        self._instruction_breakpoints: set[int] = set()
        self._known_breakpoints: set[int] = set()

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
            with open(_normalize_incoming_path(rom_path), "rb") as f:
                await self.engine.load_rom(f.read())
        snapshot_path = args.get("snapshot")
        if snapshot_path:
            with open(_normalize_incoming_path(snapshot_path), "rb") as f:
                await self.engine.load_snapshot(f.read())
        else:
            await self.engine.reset()
        sld_path, asm_path = args.get("sld"), args.get("asm")
        if sld_path and asm_path:
            await self.engine.load_debug_info(
                Path(_normalize_incoming_path(sld_path)), Path(_normalize_incoming_path(asm_path))
            )
        return {}

    async def _cmd_attach(self, args: dict) -> dict:
        return {}

    async def _cmd_configurationDone(self, args: dict) -> dict:
        return {}

    async def _cmd_setInstructionBreakpoints(self, args: dict) -> dict:
        # DAP semantics: each call replaces this connection's full
        # instruction-breakpoint set -- but must not disturb any
        # source-line breakpoints also active on this connection, so the
        # actual engine writes go through _sync_breakpoints().
        addrs: set[int] = set()
        breakpoints = []
        for bp in args.get("breakpoints", []):
            addr = _as_addr(bp["instructionReference"], bp.get("offset", 0))
            addrs.add(addr)
            breakpoints.append({"verified": True, "instructionReference": f"0x{addr:04X}"})
        self._instruction_breakpoints = addrs
        await self._sync_breakpoints()
        return {"breakpoints": breakpoints}

    def _active_sources(self) -> list[RomSource]:
        # Whatever program is currently loaded takes priority over the
        # ROM's own (always-available) debug info -- so a call from that
        # program into a ROM routine still resolves once the program's own
        # source has no mapping for the address.
        sources = []
        if self.engine.debug_info is not None:
            sources.append(self.engine.debug_info)
        rom_source = _get_rom_source()
        if rom_source is not None:
            sources.append(rom_source)
        return sources

    def _source_for_path(self, path: str) -> RomSource | None:
        for source in self._active_sources():
            if str(source.asm_path) == path or source.asm_path.name == Path(path).name:
                return source
        return None

    async def _cmd_setBreakpoints(self, args: dict) -> dict:
        # Source-line breakpoints, set by clicking the gutter in whichever
        # file is currently open (the loaded program's own source, or
        # rom.asm once the ROM disassembly has been built). Resolved to
        # addresses via the matching source's SLD line<->address mapping;
        # a line with no mapped instruction (e.g. a comment or label-only
        # line) comes back unverified rather than silently dropped, so VS
        # Code shows it as such instead of pretending it's active.
        source_path = (args.get("source") or {}).get("path", "")
        rom_source = self._source_for_path(source_path)

        addrs: set[int] = set()
        results = []
        for bp in args.get("breakpoints", []):
            line = bp["line"]
            addr = rom_source.line_to_addr.get(line) if rom_source else None
            if addr is None:
                results.append({"verified": False, "line": line, "message": "no instruction at this line"})
            else:
                addrs.add(addr)
                results.append({"verified": True, "line": line, "instructionReference": f"0x{addr:04X}"})

        self._source_breakpoints[source_path] = addrs
        await self._sync_breakpoints()
        return {"breakpoints": results}

    async def _sync_breakpoints(self) -> None:
        desired = set(self._instruction_breakpoints)
        for addrs in self._source_breakpoints.values():
            desired |= addrs
        for addr in desired - self._known_breakpoints:
            await self.engine.set_breakpoint(addr)
        for addr in self._known_breakpoints - desired:
            await self.engine.clear_breakpoint(addr)
        self._known_breakpoints = desired

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
        # Frame 0 is the current PC; frame 1+ are call_stack's tracked
        # return addresses, innermost (most recently called) first --
        # call_stack itself is oldest-first (a plain append/pop stack), so
        # reversed() here is what puts them in that display order. See
        # machine.py's _classify_step()/step_instruction() for how it's
        # kept in sync with actual CALL/RST/RET execution, and its known
        # limitation (untracked interrupt frames, desyncable by direct SP
        # manipulation -- e.g. the ROM's own error-handler unwind idiom).
        regs = await self.engine.get_registers()
        addrs = [regs.pc, *reversed(self.engine.machine.call_stack)]
        frames = [self._build_frame(i + 1, addr) for i, addr in enumerate(addrs)]
        return {"stackFrames": frames, "totalFrames": len(frames)}

    def _build_frame(self, frame_id: int, addr: int) -> dict:
        inst = disassemble_one(self._read_memory_sync, addr)
        name = f"0x{addr:04X}: {inst.text}"

        frame = {
            "id": frame_id,
            "name": name,
            "instructionPointerReference": f"0x{addr:04X}",
            "line": 0,
            "column": 0,
        }
        # First source (loaded program, then ROM) with an exact address
        # match wins -- symbol_at() alone would find SOME nearest label
        # from a source that doesn't actually cover this address at all
        # (e.g. it only has entries far below PC), which would mislabel
        # the frame rather than just showing no source for it.
        for source in self._active_sources():
            line = source.addr_to_line.get(addr)
            if line is None:
                continue
            symbol = source.symbol_at(addr)
            if symbol is not None:
                sym_name, offset = symbol
                label = f"{sym_name}+{offset}" if offset else sym_name
                frame["name"] = f"{label}  {name}"
            frame["source"] = {"name": source.asm_path.name, "path": str(source.asm_path)}
            frame["line"] = line
            frame["column"] = 1
            break
        return frame

    def _read_memory_sync(self, addr: int) -> int:
        # Disassembly is read-only and doesn't mutate machine state, so it
        # doesn't need to go through the engine's command queue -- reading
        # directly avoids round-tripping every single byte through submit().
        return self.engine.machine.memory.read(addr)

    async def _cmd_disassemble(self, args: dict) -> dict:
        try:
            base_addr = _as_addr(args["memoryReference"], args.get("offset", 0))
        except (ValueError, TypeError):
            # VS Code's Disassembly View can internally generate a
            # "disassemblyNotAvailable" placeholder request with an empty
            # memoryReference (e.g. while a scroll event races session
            # setup) -- a known VS Code bug (microsoft/vscode#270361) means
            # a *failed* response to that specific request can permanently
            # wedge the view's internal loading lock, silently breaking all
            # future auto-scroll-to-PC behavior for the rest of that view's
            # lifetime. Returning a harmless empty result instead of an
            # error avoids ever triggering that, regardless of whether the
            # user's VS Code build already has the upstream fix.
            return {"instructions": []}
        instruction_offset = args.get("instructionOffset", 0)
        count = args["instructionCount"]

        if instruction_offset > 0:
            # Walk forward `instruction_offset` instructions from base_addr
            # -- unlike the backward case, this is unambiguous (variable-
            # length decoding only needs a direction, not a search).
            start = base_addr
            for _ in range(instruction_offset):
                start = (start + disassemble_one(self._read_memory_sync, start).length) & 0xFFFF
        elif instruction_offset < 0:
            # Z80 opcodes are variable-length, so there's no way to jump
            # straight to "N instructions before base_addr" -- search
            # backward for a start address that, decoded forward, lands
            # exactly on base_addr after `-instruction_offset`
            # instructions. Falls back to base_addr itself (no "before"
            # instructions) if no aligned start is found within range.
            start = self._find_aligned_backward_start(base_addr, -instruction_offset)
        else:
            start = base_addr

        instructions = disassemble_range(self._read_memory_sync, start, count)
        return {
            "instructions": [
                {"address": f"0x{i.addr:04X}", "instructionBytes": i.raw.hex(), "instruction": i.text}
                for i in instructions
            ]
        }

    def _find_aligned_backward_start(self, base_addr: int, needed_before: int) -> int:
        # Z80 instructions are 1-4 bytes; searching back needed_before * 4
        # bytes comfortably covers every real instruction stream (capped so
        # a huge request -- e.g. VS Code paging in hundreds of instructions
        # of context -- can't make this pathologically slow).
        #
        # The 64KB address space wraps (0xFFFF is immediately followed by
        # 0x0000), which a plain `addr < base_addr` comparison can't
        # express -- for base_addr near 0x0000 that condition is never
        # true for any candidate near the top of memory, so the search
        # always silently "found nothing" and fell back to no before-
        # context. Decoding a fixed `needed_before` instructions forward
        # with addresses masked to 16 bits throughout, then checking where
        # that lands, handles the wraparound correctly instead.
        max_search = min(needed_before * 4 + 16, 2048)
        for back in range(1, max_search + 1):
            candidate = (base_addr - back) & 0xFFFF
            addr = candidate
            for _ in range(needed_before):
                inst = disassemble_one(self._read_memory_sync, addr)
                addr = (addr + inst.length) & 0xFFFF
            if addr == base_addr:
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
