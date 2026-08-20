"""server/dap.py: exercised over a real asyncio TCP connection, DAP-framed."""
import asyncio

from zxspectrum.engine.actor import Engine
from zxspectrum.server.dap import _read_message, _write_message, create_dap_server


def _run(coro):
    return asyncio.run(coro)


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

            resp = await client.request("stackTrace", {"threadId": 1})
            name = resp["body"]["stackFrames"][0]["name"]
            assert name == f"0x{pc:04X}: LD A,0x42"
        finally:
            await client.close()
            server.close()
            await engine.stop()

    _run(scenario())
