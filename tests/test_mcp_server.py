"""server/mcp_server.py: tool-level tests driven in-process via call_tool()."""
import asyncio
import base64
import json

from zxspectrum.engine.actor import Engine
from zxspectrum.server.mcp_server import create_server


def _run(coro):
    return asyncio.run(coro)


def _json(result):
    assert not result.is_error, result.content
    return json.loads(result.content[0].text)


def test_get_registers_returns_json():
    async def scenario():
        engine = Engine()
        engine.start()
        try:
            server = create_server(engine)
            result = await server.call_tool("get_registers", {})
            regs = _json(result)
            # a freshly-constructed machine has already primed its fetch
            # pipeline (see Spectrum48K._prime_fetch()), so PC may already
            # read 1 rather than 0 -- just check the shape is sane.
            assert regs["pc"] in (0, 1)
            assert set(regs) >= {"pc", "sp", "af", "bc", "de", "hl", "im", "iff1", "iff2"}
        finally:
            await engine.stop()

    _run(scenario())


def test_load_rom_set_registers_and_step():
    async def scenario():
        engine = Engine()
        engine.start()
        try:
            server = create_server(engine)

            rom = bytes(0x4000)
            r = await server.call_tool("load_rom", {"rom_base64": base64.b64encode(rom).decode()})
            assert not r.is_error

            engine.machine.write_memory(0x8000, bytes([0x3E, 0x42]))  # LD A,0x42
            r = await server.call_tool("set_registers", {"pc": 0x8000})
            assert not r.is_error

            r = await server.call_tool("step", {})
            regs = _json(r)
            assert regs["registers"]["af"] >> 8 == 0x42
        finally:
            await engine.stop()

    _run(scenario())


def test_memory_round_trip():
    async def scenario():
        engine = Engine()
        engine.start()
        try:
            server = create_server(engine)
            r = await server.call_tool("write_memory", {"addr": 0x8000, "data_hex": "deadbeef"})
            assert not r.is_error

            r = await server.call_tool("read_memory", {"addr": 0x8000, "length": 4})
            data = _json(r)
            assert data["hex"] == "deadbeef"
        finally:
            await engine.stop()

    _run(scenario())


def test_breakpoint_stops_run():
    async def scenario():
        engine = Engine()
        engine.start()
        try:
            server = create_server(engine)
            engine.machine.write_memory(0x8000, bytes([0x00, 0x00, 0x76]))  # NOP NOP HALT
            await server.call_tool("set_registers", {"pc": 0x8000})
            await server.call_tool("set_breakpoint", {"addr": 0x8002})

            r = await server.call_tool("run", {})
            state = _json(r)
            assert state["pc"] == 0x8002
            assert state["running"] is False
        finally:
            await engine.stop()

    _run(scenario())


def test_get_screen_returns_an_image():
    async def scenario():
        engine = Engine()
        engine.start()
        try:
            server = create_server(engine)
            r = await server.call_tool("get_screen", {})
            assert not r.is_error
            assert len(r.content) == 1
            assert r.content[0].type == "image"
            assert r.content[0].mime_type == "image/png"
        finally:
            await engine.stop()

    _run(scenario())
