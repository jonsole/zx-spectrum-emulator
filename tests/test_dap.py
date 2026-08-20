"""server/dap.py: exercised over a real asyncio TCP connection, DAP-framed."""
import asyncio
from pathlib import Path
from unittest.mock import patch

from zxspectrum.core.rom_source import RomSource
from zxspectrum.engine.actor import Engine
from zxspectrum.server.dap import _normalize_incoming_path, _read_message, _write_message, create_dap_server


def _run(coro):
    return asyncio.run(coro)


def test_normalize_incoming_path_translates_windows_drive_paths_under_wsl():
    # This server can run natively on Windows or inside WSL (see the
    # README). A native-Windows VS Code process resolves ${workspaceFolder}
    # to a Windows path before sending it -- when *this* process is itself
    # running inside WSL (not "nt"), that needs translating to /mnt/<drive>.
    # Mocked rather than relying on the actual host platform so both
    # branches are tested regardless of where this suite runs.
    with patch("zxspectrum.server.dap.os.name", "posix"):
        assert _normalize_incoming_path(r"C:\Users\jonso\zx-spectrum-emulator\roms\48.rom") == \
            "/mnt/c/Users/jonso/zx-spectrum-emulator/roms/48.rom"
        assert _normalize_incoming_path("C:/Users/jonso/roms/48.rom") == "/mnt/c/Users/jonso/roms/48.rom"
        assert _normalize_incoming_path(r"d:\roms\48.rom") == "/mnt/d/roms/48.rom"


def test_normalize_incoming_path_passes_through_unchanged_natively_on_windows():
    with patch("zxspectrum.server.dap.os.name", "nt"):
        assert _normalize_incoming_path(r"C:\Users\jonso\roms\48.rom") == r"C:\Users\jonso\roms\48.rom"


def test_normalize_incoming_path_leaves_non_windows_paths_unchanged():
    assert _normalize_incoming_path("/mnt/c/Users/jonso/roms/48.rom") == "/mnt/c/Users/jonso/roms/48.rom"
    assert _normalize_incoming_path("roms/48.rom") == "roms/48.rom"


class _Client:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader = reader
        self.writer = writer
        self._seq = 0
        self._queue: asyncio.Queue = asyncio.Queue()
        self._backlog: list[dict] = []
        self._pump_task = asyncio.create_task(self._pump())

    async def _pump(self) -> None:
        while True:
            msg = await _read_message(self.reader)
            if msg is None:
                return
            await self._queue.put(msg)

    async def close(self) -> None:
        self._pump_task.cancel()
        self.writer.close()

    async def _recv_matching(self, predicate):
        # Events and responses are written by independent tasks on the
        # server (the request handler and the event-forwarding loop), so
        # they can arrive in either order over the wire -- e.g. a Stopped
        # event published as a side effect of handling `launch` can beat
        # `launch`'s own response across the socket. Messages that don't
        # match what THIS call is waiting for are stashed rather than
        # dropped, so a later call waiting for them still finds them.
        for i, msg in enumerate(self._backlog):
            if predicate(msg):
                return self._backlog.pop(i)
        while True:
            msg = await self._queue.get()
            if predicate(msg):
                return msg
            self._backlog.append(msg)

    async def request(self, command: str, arguments: dict | None = None, timeout: float = 2) -> dict:
        self._seq += 1
        msg = {"seq": self._seq, "type": "request", "command": command}
        if arguments is not None:
            msg["arguments"] = arguments
        _write_message(self.writer, msg)
        await self.writer.drain()
        return await asyncio.wait_for(
            self._recv_matching(lambda m: m.get("type") == "response" and m.get("command") == command),
            timeout,
        )

    async def event(self, name: str, timeout: float = 2) -> dict:
        return await asyncio.wait_for(
            self._recv_matching(lambda m: m.get("type") == "event" and m.get("event") == name),
            timeout,
        )


async def _connect(server: asyncio.base_events.Server) -> _Client:
    port = server.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    return _Client(reader, writer)


def test_initialize_handshake():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            resp = await client.request("initialize", {"adapterID": "zx"})
            assert resp["success"] is True
            assert resp["body"]["supportsInstructionBreakpoints"] is True
            await client.event("initialized")
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_launch_sets_breakpoint_and_continues_to_it():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")

            # launch() with no rom/snapshot falls back to reset(), which
            # always publishes a Stopped(reason="entry") event.
            await client.request("launch", {})
            await client.event("stopped")

            engine.machine.write_memory(0x8000, bytes([0x00, 0x00, 0x76]))  # NOP NOP HALT
            resp = await client.request("configurationDone", {})
            assert resp["success"]

            resp = await client.request(
                "setInstructionBreakpoints",
                {"breakpoints": [{"instructionReference": "0x8002"}]},
            )
            assert resp["body"]["breakpoints"][0]["verified"] is True

            regs = await engine.get_registers()
            regs.pc = 0x8000
            await engine.set_registers(regs)
            await client.event("stopped")  # from the set_registers above

            resp = await client.request("continue", {"threadId": 1})
            assert resp["success"]
            await client.event("continued")
            stopped = await client.event("stopped")
            assert stopped["body"]["reason"] == "breakpoint"

            trace = await client.request("stackTrace", {"threadId": 1})
            assert trace["body"]["stackFrames"][0]["instructionPointerReference"] == "0x8002"
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_scopes_and_variables_report_registers_and_flags():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            scopes = await client.request("scopes", {"frameId": 1})
            names = {s["name"] for s in scopes["body"]["scopes"]}
            assert names == {"Registers", "Flags"}
            registers_ref = next(s["variablesReference"] for s in scopes["body"]["scopes"] if s["name"] == "Registers")
            flags_ref = next(s["variablesReference"] for s in scopes["body"]["scopes"] if s["name"] == "Flags")

            reg_vars = await client.request("variables", {"variablesReference": registers_ref})
            var_names = {v["name"] for v in reg_vars["body"]["variables"]}
            assert {"PC", "SP", "AF", "BC", "DE", "HL", "IX", "IY", "IM", "IFF1", "IFF2"} <= var_names

            flag_vars = await client.request("variables", {"variablesReference": flags_ref})
            flag_names = {v["name"] for v in flag_vars["body"]["variables"]}
            assert flag_names == {"S", "Z", "H", "P/V", "N", "C"}
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_read_write_memory():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            import base64
            resp = await client.request(
                "writeMemory",
                {"memoryReference": "0x8000", "data": base64.b64encode(b"\xde\xad\xbe\xef").decode()},
            )
            assert resp["body"]["bytesWritten"] == 4

            resp = await client.request("readMemory", {"memoryReference": "0x8000", "count": 4})
            assert base64.b64decode(resp["body"]["data"]) == b"\xde\xad\xbe\xef"
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_disassemble_with_empty_memory_reference_does_not_error():
    # VS Code's Disassembly View can internally send a request with an
    # empty memoryReference (a "disassemblyNotAvailable" placeholder --
    # see microsoft/vscode#270361). A *failed* response to that specific
    # request is known to permanently wedge the view's internal loading
    # lock in some VS Code versions, silently breaking future auto-scroll-
    # to-PC behavior -- so this must always succeed, never error.
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            resp = await client.request(
                "disassemble", {"memoryReference": "", "instructionCount": 10}
            )
            assert resp["success"] is True
            assert resp["body"]["instructions"] == []
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_disassemble_forward_from_pc():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            resp = await client.request("initialize", {})
            assert resp["body"]["supportsDisassembleRequest"] is True
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            engine.machine.write_memory(0x8000, bytes([0x00, 0x3E, 0x42, 0xC3, 0x00, 0x80]))
            resp = await client.request(
                "disassemble",
                {"memoryReference": "0x8000", "instructionCount": 3},
            )
            instructions = resp["body"]["instructions"]
            assert [i["instruction"] for i in instructions] == ["NOP", "LD A,0x42", "JP 0x8000"]
            assert instructions[0]["address"] == "0x8000"
            assert instructions[2]["address"] == "0x8003"
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_disassemble_positive_instruction_offset_skips_forward():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            # NOP(1); LD A,0x42(2); JP 0x8000(3) -- skip the first two
            # instructions (offset=2) and read starting at the JP.
            engine.machine.write_memory(0x8000, bytes([0x00, 0x3E, 0x42, 0xC3, 0x00, 0x80]))
            resp = await client.request(
                "disassemble",
                {"memoryReference": "0x8000", "instructionOffset": 2, "instructionCount": 1},
            )
            instructions = resp["body"]["instructions"]
            assert instructions[0]["address"] == "0x8003"
            assert instructions[0]["instruction"] == "JP 0x8000"
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_disassemble_backward_from_an_aligned_instruction_boundary():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            # NOP(1); LD A,0x42(2); JP 0x8000(3) -- ask for 2 instructions
            # before the JP at 0x8003 plus the JP itself.
            engine.machine.write_memory(0x8000, bytes([0x00, 0x3E, 0x42, 0xC3, 0x00, 0x80]))
            resp = await client.request(
                "disassemble",
                {"memoryReference": "0x8003", "instructionOffset": -2, "instructionCount": 3},
            )
            instructions = resp["body"]["instructions"]
            assert [i["instruction"] for i in instructions] == ["NOP", "LD A,0x42", "JP 0x8000"]
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_disassemble_backward_beyond_a_small_fixed_search_window():
    # Regression test: the backward-alignment search's byte budget must
    # scale with how many instructions are requested, not be a small fixed
    # constant -- a real DAP session against the 48K ROM found the marker
    # missing from VS Code's Disassembly View because a realistic request
    # (50 instructions of "before" context, ~100 bytes for 2-byte
    # instructions) exceeded a since-fixed max_search=64 and silently fell
    # back to "no before context", shifting every address by 50 slots.
    #
    # Deliberately varied instruction lengths/content here, NOT a single
    # repeated instruction: a uniformly-repeating byte pattern is a
    # degenerate case where shifting by one unit can coincidentally
    # realign and produce an equally "valid-looking" but wrong alignment
    # (an inherent ambiguity of backward-scanning variable-length opcodes,
    # not something the search budget can fix) -- real code doesn't
    # exhibit this, as already confirmed against the actual 48K ROM.
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            unit = bytes([0x3C, 0x06, 0x11, 0x0D, 0x11, 0x22, 0x22, 0xAF])
            # INC A(1); LD B,0x11(2); DEC C(1); LD DE,0x2222(3); XOR A(1) = 8 bytes, 5 instructions
            n_units = 12  # 12 * 8 = 96 bytes of lookback, past any small fixed budget
            n_instructions = 5 * n_units
            program = unit * n_units + bytes([0x76])  # ...; HALT
            engine.machine.write_memory(0x8000, program)
            halt_addr = 0x8000 + len(unit) * n_units

            resp = await client.request(
                "disassemble",
                {
                    "memoryReference": f"0x{halt_addr:04X}",
                    "instructionOffset": -n_instructions,
                    "instructionCount": n_instructions + 1,
                },
            )
            instructions = resp["body"]["instructions"]
            addrs = [i["address"] for i in instructions]
            assert addrs[0] == "0x8000"
            assert addrs[n_instructions] == f"0x{halt_addr:04X}"
            assert instructions[n_instructions]["instruction"] == "HALT"
            assert instructions[0]["instruction"] == "INC A"
            assert instructions[1]["instruction"] == "LD B,0x11"
            assert instructions[3]["instruction"] == "LD DE,0x2222"
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_disassemble_backward_context_wraps_around_address_zero():
    # Regression test: a real VS Code session opening the Disassembly View
    # right at the reset entry point (PC=0x0000) asks for
    # instructionOffset=-50 -- there's no memory "before" 0x0000 in a
    # linear sense, but the Z80's 16-bit address space wraps (0xFFFF is
    # immediately followed by 0x0000), so this is answerable. The original
    # implementation compared addresses with a plain `<`, which can never
    # be satisfied wrapping from high memory back down to 0x0000, so it
    # silently returned 0 bytes of "before" context -- shifting every
    # returned address by 50 slots relative to what VS Code expected and
    # making its current-position marker land on the wrong instruction
    # every time (a different wrong one depending on the request shape).
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            resp = await client.request(
                "disassemble",
                {"memoryReference": "0x0000", "instructionOffset": -50, "instructionCount": 100},
            )
            instructions = resp["body"]["instructions"]
            assert instructions[50]["address"] == "0x0000"
            # everything before the wrap point is unwritten RAM (0x00 = NOP)
            assert instructions[49]["address"] == "0xFFFF"
            assert instructions[49]["instruction"] == "NOP"
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_stack_trace_labels_frame_with_disassembled_instruction():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            regs = await engine.get_registers()
            regs.pc = 0x8000
            await engine.set_registers(regs)
            await client.event("stopped")

            # set_registers()/_prime_fetch() already consumes the first
            # opcode byte as part of redirecting execution (see the
            # z80_prefetch() gotcha noted in machine.py), so PC may not be
            # exactly 0x8000 here -- write the test instruction at wherever
            # it actually landed instead of assuming.
            pc = (await engine.get_registers()).pc
            engine.machine.write_memory(pc, bytes([0x3E, 0x42]))

            # Pinned to "no ROM source" regardless of whether
            # rom_disassembly/ happens to be built in this environment --
            # that case is covered separately by
            # test_stack_trace_includes_source_when_rom_source_available.
            with patch("zxspectrum.server.dap._get_rom_source", return_value=None):
                resp = await client.request("stackTrace", {"threadId": 1})
            name = resp["body"]["stackFrames"][0]["name"]
            assert name == f"0x{pc:04X}: LD A,0x42"
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_stack_trace_includes_source_when_rom_source_available():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            regs = await engine.get_registers()
            regs.pc = 0x8000
            await engine.set_registers(regs)
            await client.event("stopped")
            pc = (await engine.get_registers()).pc
            engine.machine.write_memory(pc, bytes([0x00]))  # NOP

            rom_source = RomSource(
                asm_path=Path("rom.asm"),
                line_to_addr={42: pc},
                addr_to_line={pc: 42},
                symbols={"ENTRY": pc},
            )
            with patch("zxspectrum.server.dap._get_rom_source", return_value=rom_source):
                resp = await client.request("stackTrace", {"threadId": 1})

            frame = resp["body"]["stackFrames"][0]
            assert frame["name"] == f"ENTRY  0x{pc:04X}: NOP"
            assert frame["line"] == 42
            assert frame["source"] == {"name": "rom.asm", "path": "rom.asm"}
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_set_breakpoints_resolves_source_line_and_stops_there():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            engine.machine.write_memory(0x8000, bytes([0x00, 0x00, 0x76]))  # NOP NOP HALT

            rom_source = RomSource(
                asm_path=Path("rom.asm"), line_to_addr={10: 0x8002}, addr_to_line={0x8002: 10}, symbols={}
            )
            with patch("zxspectrum.server.dap._get_rom_source", return_value=rom_source):
                resp = await client.request(
                    "setBreakpoints", {"source": {"path": "rom.asm"}, "breakpoints": [{"line": 10}]}
                )
            bp = resp["body"]["breakpoints"][0]
            assert bp["verified"] is True
            assert bp["instructionReference"] == "0x8002"

            regs = await engine.get_registers()
            regs.pc = 0x8000
            await engine.set_registers(regs)
            await client.event("stopped")

            resp = await client.request("continue", {"threadId": 1})
            assert resp["success"]
            await client.event("continued")
            stopped = await client.event("stopped")
            assert stopped["body"]["reason"] == "breakpoint"
            assert (await engine.get_registers()).pc == 0x8002
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_set_breakpoints_line_with_no_instruction_is_unverified():
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            # Pinned to "no ROM source" regardless of whether
            # rom_disassembly/ happens to be built in this environment --
            # must degrade to "unverified", not raise.
            with patch("zxspectrum.server.dap._get_rom_source", return_value=None):
                resp = await client.request(
                    "setBreakpoints", {"source": {"path": "rom.asm"}, "breakpoints": [{"line": 100}]}
                )
            assert resp["body"]["breakpoints"][0]["verified"] is False
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_launch_with_sld_and_asm_args_loads_program_debug_info(tmp_path):
    async def scenario():
        sld_path = tmp_path / "prog.sld"
        asm_path = tmp_path / "prog.asm"
        sld_path.write_text("prog.asm|7||0|0|32768|F|MYROUTINE\n", encoding="utf-8")
        asm_path.write_text("; fake\n", encoding="utf-8")

        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {"sld": str(sld_path), "asm": str(asm_path)})
            await client.event("stopped")

            assert engine.debug_info is not None
            assert engine.debug_info.symbols == {"MYROUTINE": 0x8000}
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_stack_trace_prefers_loaded_program_source_and_falls_back_to_rom():
    # This is the concrete scenario the user asked for: debugging your own
    # assembled program (its own .sna/.sld) while it calls into ROM
    # routines should show YOUR source for your own code, and still show
    # the ROM's source once execution is inside a ROM routine -- neither
    # source should have to be sacrificed for the other.
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            engine.debug_info = RomSource(
                asm_path=Path("prog.asm"),
                line_to_addr={7: 0x8000},
                addr_to_line={0x8000: 7},
                symbols={"MYROUTINE": 0x8000},
            )
            rom_source = RomSource(
                asm_path=Path("rom.asm"), line_to_addr={90: 0}, addr_to_line={0: 90}, symbols={"START": 0}
            )

            # PC inside the loaded program -> program's own source.
            regs = await engine.get_registers()
            regs.pc = 0x8000
            await engine.set_registers(regs)
            await client.event("stopped")
            with patch("zxspectrum.server.dap._get_rom_source", return_value=rom_source):
                trace = await client.request("stackTrace", {"threadId": 1})
            frame = trace["body"]["stackFrames"][0]
            assert frame["source"]["path"] == "prog.asm"
            assert frame["line"] == 7
            assert frame["name"].startswith("MYROUTINE  ")

            # PC inside the ROM (no mapping in the program's own debug
            # info) -> falls back to the ROM's source instead of showing
            # nothing.
            regs = await engine.get_registers()
            regs.pc = 0x0000
            await engine.set_registers(regs)
            await client.event("stopped")
            with patch("zxspectrum.server.dap._get_rom_source", return_value=rom_source):
                trace = await client.request("stackTrace", {"threadId": 1})
            frame = trace["body"]["stackFrames"][0]
            assert frame["source"]["path"] == "rom.asm"
            assert frame["line"] == 90
            assert frame["name"].startswith("START  ")
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())


def test_source_and_instruction_breakpoints_do_not_clobber_each_other():
    # Regression test: setInstructionBreakpoints previously cleared every
    # breakpoint on the engine (not just the instruction-category ones it
    # owns) before re-adding its own set -- so setting one kind wiped out
    # the other kind on the same connection. Both categories must coexist,
    # and dropping one (an empty setBreakpoints call) must leave the other
    # untouched.
    async def scenario():
        engine = Engine()
        engine.start()
        server = await create_dap_server(engine, port=0)
        client = await _connect(server)
        try:
            await client.request("initialize", {})
            await client.event("initialized")
            await client.request("launch", {})
            await client.event("stopped")

            engine.machine.write_memory(0x8000, bytes([0x00, 0x00, 0x00, 0x76]))  # NOP NOP NOP HALT

            resp = await client.request(
                "setInstructionBreakpoints", {"breakpoints": [{"instructionReference": "0x8003"}]}
            )
            assert resp["body"]["breakpoints"][0]["verified"] is True

            rom_source = RomSource(
                asm_path=Path("rom.asm"), line_to_addr={5: 0x8001}, addr_to_line={0x8001: 5}, symbols={}
            )
            with patch("zxspectrum.server.dap._get_rom_source", return_value=rom_source):
                await client.request(
                    "setBreakpoints", {"source": {"path": "rom.asm"}, "breakpoints": [{"line": 5}]}
                )
                state = await engine.get_state()
                assert {0x8001, 0x8003} <= state.breakpoints

                # Drop the source breakpoint -- the instruction breakpoint
                # set earlier must survive this.
                await client.request(
                    "setBreakpoints", {"source": {"path": "rom.asm"}, "breakpoints": []}
                )

            state = await engine.get_state()
            assert 0x8003 in state.breakpoints
            assert 0x8001 not in state.breakpoints

            regs = await engine.get_registers()
            regs.pc = 0x8000
            await engine.set_registers(regs)
            await client.event("stopped")

            resp = await client.request("continue", {"threadId": 1})
            assert resp["success"]
            await client.event("continued")
            stopped = await client.event("stopped")
            assert stopped["body"]["reason"] == "breakpoint"
            assert (await engine.get_registers()).pc == 0x8003
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())
