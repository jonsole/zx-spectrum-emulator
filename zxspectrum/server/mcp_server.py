"""MCP front-end: exposes the shared Engine as MCP tools over HTTP/SSE.

Every tool here is a thin wrapper around an `Engine` async method -- the
engine (not this module) is what actually serializes access to the one
live Spectrum48K, so this front-end can run concurrently with the DAP
server against the same machine without either side stepping on the
other's state.
"""
from __future__ import annotations

import base64
import dataclasses
import io

from PIL import Image as PILImage

from mcp.server.mcpserver import Image, MCPServer

from zxspectrum.engine.actor import Engine


def _regs_to_dict(regs) -> dict:
    return dataclasses.asdict(regs)


def create_server(engine: Engine) -> MCPServer:
    server = MCPServer(
        "zx-spectrum-emulator",
        instructions=(
            "Tools for a headless 48K ZX Spectrum emulator. The same emulator "
            "instance may simultaneously be under manual control from VS Code "
            "over DAP -- read get_state to see the live picture before "
            "stepping or writing memory."
        ),
    )

    @server.tool()
    async def load_rom(rom_base64: str) -> str:
        """Load a 16K ZX Spectrum ROM image (base64-encoded raw bytes)."""
        await engine.load_rom(base64.b64decode(rom_base64))
        return "ROM loaded."

    @server.tool()
    async def load_snapshot(sna_base64: str) -> dict:
        """Load a .sna snapshot (base64-encoded) -- sets registers, memory and border."""
        await engine.load_snapshot(base64.b64decode(sna_base64))
        regs = await engine.get_registers()
        return {"pc": regs.pc, "registers": _regs_to_dict(regs)}

    @server.tool()
    async def reset() -> dict:
        """Reset the machine (does not reload ROM/RAM contents)."""
        await engine.reset()
        regs = await engine.get_registers()
        return {"pc": regs.pc}

    @server.tool()
    async def step() -> dict:
        """Execute exactly one Z80 instruction."""
        await engine.step()
        regs = await engine.get_registers()
        return {"pc": regs.pc, "registers": _regs_to_dict(regs)}

    @server.tool()
    async def run() -> dict:
        """Run until a breakpoint is hit or pause() is called."""
        await engine.run()
        state = await engine.get_state()
        return {"pc": state.pc, "running": state.running}

    @server.tool()
    async def pause() -> str:
        """Interrupt an in-flight run()."""
        await engine.pause()
        return "Pause requested."

    @server.tool()
    async def set_breakpoint(addr: int) -> str:
        """Set a PC breakpoint at a 16-bit address."""
        await engine.set_breakpoint(addr)
        return f"Breakpoint set at 0x{addr:04X}."

    @server.tool()
    async def clear_breakpoint(addr: int) -> str:
        """Clear a previously-set PC breakpoint."""
        await engine.clear_breakpoint(addr)
        return f"Breakpoint cleared at 0x{addr:04X}."

    @server.tool()
    async def read_memory(addr: int, length: int = 1) -> dict:
        """Read `length` bytes starting at a 16-bit address; returns hex."""
        data = await engine.read_memory(addr, length)
        return {"addr": addr, "hex": data.hex()}

    @server.tool()
    async def write_memory(addr: int, data_hex: str) -> str:
        """Write hex-encoded bytes starting at a 16-bit address (ROM writes are ignored)."""
        await engine.write_memory(addr, bytes.fromhex(data_hex))
        return f"Wrote {len(data_hex) // 2} byte(s) at 0x{addr:04X}."

    @server.tool()
    async def get_registers() -> dict:
        """Read all CPU registers (main + shadow set, IM, IFF1/IFF2)."""
        return _regs_to_dict(await engine.get_registers())

    @server.tool()
    async def set_registers(
        pc: int | None = None,
        sp: int | None = None,
        af: int | None = None,
        bc: int | None = None,
        de: int | None = None,
        hl: int | None = None,
        ix: int | None = None,
        iy: int | None = None,
        im: int | None = None,
        iff1: bool | None = None,
        iff2: bool | None = None,
    ) -> dict:
        """Set one or more CPU registers; unspecified registers are left unchanged."""
        regs = await engine.get_registers()
        for name, value in {
            "pc": pc, "sp": sp, "af": af, "bc": bc, "de": de, "hl": hl,
            "ix": ix, "iy": iy, "im": im, "iff1": iff1, "iff2": iff2,
        }.items():
            if value is not None:
                setattr(regs, name, value)
        await engine.set_registers(regs)
        return _regs_to_dict(await engine.get_registers())

    @server.tool()
    async def key_down(key: str) -> str:
        """Press a key (e.g. "A", "ENTER", "CAPS SHIFT", "1")."""
        await engine.key_down(key)
        return f"{key} down."

    @server.tool()
    async def key_up(key: str) -> str:
        """Release a key."""
        await engine.key_up(key)
        return f"{key} up."

    @server.tool()
    async def get_screen() -> Image:
        """Render the current display as a PNG screenshot."""
        rgb = await engine.get_screen()
        buf = io.BytesIO()
        PILImage.fromarray(rgb, mode="RGB").save(buf, format="PNG")
        return Image(data=buf.getvalue(), format="png")

    @server.tool()
    async def get_state() -> dict:
        """Full status snapshot: PC, registers, breakpoints, running flag, border color."""
        state = await engine.get_state()
        return {
            "pc": state.pc,
            "registers": _regs_to_dict(state.registers),
            "breakpoints": sorted(state.breakpoints),
            "running": state.running,
            "border": state.border,
        }

    return server
