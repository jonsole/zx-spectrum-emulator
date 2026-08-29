# Connecting an MCP client

Part of the [zx-spectrum-emulator README](../README.md).

> **`zx_server.exe` has to be running first.** There is no separate MCP
> server process and nothing starts one on demand — the MCP endpoint is
> served *by the emulator process itself*, alongside DAP and the screen
> stream. No server, no endpoint. Start it either by launching a VS Code
> debug session (its `preLaunchTask` builds and starts the server — see
> [Connecting VS Code](vscode-debugging.md)) or by running it by hand as
> shown under [Running](../README.md#running).

Point any MCP client at `http://127.0.0.1:8000/mcp` (streamable HTTP).

The repo includes `.mcp.json`, so opening this workspace in Claude Code
picks up the server automatically (you'll be prompted to approve it once).
To add it manually instead (e.g. a different client, or without opening
the workspace), for Claude Code:

```bash
claude mcp add zx-spectrum --transport http --url http://127.0.0.1:8000/mcp
```

Either way, registering the server does not launch it: `.mcp.json` and
`claude mcp add` only tell the client *where to look*.

**If the emulator isn't up**, the client shows `zx-spectrum` as failed or
disconnected and every tool call fails to reach `127.0.0.1:8000`
(connection refused) — rather than returning an emulator error. The fix is
always the same: start `zx_server.exe`, then reconnect the client (in Claude
Code, `/mcp` → reconnect, or restart it). A quick way to tell the two apart
is the raw probe in [INSTALL.md step 8](../INSTALL.md#step-8--connect-an-mcp-client);
if that gets no answer, the problem is the server, not the client.

The lifetime runs the other way round too: the server is deliberately *not*
started with `--exit-on-disconnect`, so ending the VS Code debug session
leaves it running and MCP clients connected. Killing the server (or the
`stop-stale-server` task doing it before a rebuild) drops them.

**Available tools:**

| Tool | Does |
|---|---|
| `load_rom(rom_base64)` | Load a 16K ROM image (base64) |
| `load_snapshot(sna_base64)` | Load a `.sna` snapshot (base64) |
| `load_debug_info(sld_path, asm_path)` | Attach source-level debug info for the loaded program (see [source-level debugging](vscode-debugging.md#source-level-debugging-of-your-own-program)) |
| `reset()` | Reset the machine |
| `step(instructions=1, ticks=None)` | Step N instructions (default 1), or N T-states if `ticks` is given |
| `run()` | Run until a breakpoint or `pause()` |
| `pause()` | Interrupt an in-flight `run()` |
| `set_breakpoint(addr)` / `clear_breakpoint(addr)` | PC breakpoints |
| `read_memory(addr, length)` / `write_memory(addr, data_hex)` | Memory access (hex-encoded) |
| `get_registers()` / `set_registers(pc=…, af=…, …)` | CPU register access |
| `key_down(key)` / `key_up(key)` | Keyboard input (e.g. `"A"`, `"ENTER"`, `"CAPS SHIFT"`) |
| `get_screen()` | Render the display as a PNG screenshot |
| `get_audio(duration_ms, include_wav)` | Measure the beeper: sample count, RMS, peak and pitch in Hz (C++ core only) |
| `get_state()` | Full snapshot: PC, registers, breakpoints, running flag, border |
| `resolve_symbol(name)` | Symbol name → address (loaded program's own debug info first, then the ROM's) |
| `resolve_address(addr)` | Address → nearest symbol + offset (same sources as `resolve_symbol`) |
