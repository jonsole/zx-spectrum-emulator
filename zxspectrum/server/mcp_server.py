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
from pathlib import Path

from PIL import Image as PILImage

from mcp.server.mcpserver import Image, MCPServer

from zxspectrum.core.rom_source import RomSource, get_rom_source
from zxspectrum.engine.actor import Engine


def _regs_to_dict(regs) -> dict:
    return dataclasses.asdict(regs)


def _debug_sources(engine: Engine) -> list[RomSource]:
    # Whatever program is currently loaded takes priority over the ROM's
    # own (always-available) debug info -- e.g. a symbol name defined in
    # both would resolve to the loaded program's, and a call from that
    # program into the ROM still resolves once neither has a hit here.
    return [s for s in (engine.debug_info, get_rom_source()) if s is not None]


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
    async def load_debug_info(sld_path: str, asm_path: str) -> dict:
        """Attach source-level debug info for whatever program is
        currently loaded (e.g. your own assembled .sna): an sjasmplus SLD
        file plus the source it was generated from, both as local paths.
        Enables resolve_symbol/resolve_address and DAP source-level
        debugging (stack frames, gutter breakpoints) for this program's
        addresses, alongside the ROM's own (always available separately,
        so calls into the ROM still resolve). Cleared automatically the
        next time load_snapshot() loads a different program."""
        await engine.load_debug_info(Path(sld_path), Path(asm_path))
        debug_info = engine.debug_info
        return {"symbols": len(debug_info.symbols), "instructions": len(debug_info.line_to_addr)}

    @server.tool()
    async def reset() -> dict:
        """Reset the machine (does not reload ROM/RAM contents)."""
        await engine.reset()
        regs = await engine.get_registers()
        return {"pc": regs.pc}

    @server.tool()
    async def step(instructions: int = 1, ticks: int | None = None) -> dict:
        """Step the CPU. By default, executes one instruction; pass
        `instructions` to step several whole instructions, or `ticks` to
        step that many T-states instead (sub-instruction granularity --
        PC may land mid-instruction)."""
        await engine.step(instructions=instructions, ticks=ticks)
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
    async def resolve_symbol(name: str) -> dict:
        """Look up a routine/label's address by name (e.g. "KEY_INT"),
        checking the currently-loaded program's debug info (see
        load_debug_info) first, then the ROM's own (built by
        scripts/build_rom_source.py). Returns found=False if neither is
        available, or the name doesn't exist in either."""
        sources = _debug_sources(engine)
        for source in sources:
            addr = source.symbols.get(name)
            if addr is not None:
                return {"found": True, "address": addr}
        if not sources:
            return {"found": False, "reason": "no debug info loaded -- see load_debug_info / scripts/build_rom_source.py"}
        return {"found": False, "reason": f"no symbol named {name!r}"}

    @server.tool()
    async def resolve_address(addr: int) -> dict:
        """Find the nearest named routine at or before a 16-bit address,
        with its offset -- e.g. 0x0005 -> {"symbol": "START", "offset":
        5}. Checks the currently-loaded program's debug info first, then
        the ROM's own -- same sources as resolve_symbol."""
        sources = _debug_sources(engine)
        for source in sources:
            result = source.symbol_at(addr)
            if result is not None:
                symbol, offset = result
                return {"found": True, "symbol": symbol, "offset": offset}
        if not sources:
            return {"found": False, "reason": "no debug info loaded -- see load_debug_info / scripts/build_rom_source.py"}
        return {"found": False, "reason": "address precedes every known symbol"}

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
            "debug_info_loaded": state.debug_info_loaded,
        }

    return server
