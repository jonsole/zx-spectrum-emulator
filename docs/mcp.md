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
| `load_rom(rom_base64)` | Load a ROM image (base64): 16K for the 48K, or the 32K 128K pair (ROM 0 then ROM 1) |
| `load_snapshot(sna_base64)` | Load a `.sna` (48K or 128K) or `.z80` (v1-v3) snapshot (base64); the machine becomes the model the snapshot was taken on |
| `save_snapshot(path)` | Save the machine as a `.sna` or `.z80` file (by extension), consistent even mid-run; a 128K's paging and AY state included |
| `load_debug_info(sld_path, asm_path)` | Attach source-level debug info for the loaded program (see [source-level debugging](vscode-debugging.md#source-level-debugging-of-your-own-program)) |
| `reset(machine=None)` | Reset the machine, optionally switching it to `"48"` or `"128"` first (the model's ROM must be loaded) |
| `step(instructions=1, ticks=None)` | Step N instructions (default 1), or N T-states if `ticks` is given |
| `run()` | Run until a breakpoint or `pause()` |
| `pause()` | Interrupt an in-flight `run()` |
| `set_breakpoint(addr)` / `clear_breakpoint(addr)` | PC breakpoints |
| `read_memory(addr, length, bank=None)` / `write_memory(addr, data_hex)` | Memory access (hex-encoded), as the CPU sees it -- or with `bank`, straight out of one of a 128K's eight RAM banks whether or not it is paged in |
| `get_registers()` / `set_registers(pc=…, hl=…, l=…, af_=…, …)` | CPU register access. Every register by name, the shadow set as `af_`/`a_`…, index halves as `ixh`/`ixl`; a 16-bit value can be a symbol expression like `"MAIN_LOOP"` |
| `key_down(key)` / `key_up(key)` | Keyboard input (e.g. `"A"`, `"ENTER"`, `"CAPS SHIFT"`) |
| `get_screen()` | Render the display as a PNG screenshot |
| `get_screen_sequence(frames, every)` | Several consecutive frames as separate images, each tagged with its frame number: motion, flicker and animation as still pictures (see [video](#video)) |
| `start_video(path, seconds, frames, scale)` / `stop_video()` / `video_status()` | Record every completed frame to a video file through ffmpeg, until stopped or for a set span (see [video](#video)) |
| `set_raster_view(marker, in_progress, pending)` | How a stopped machine's screen is drawn: beam position, frame-in-progress, and writes the beam has not reached (see [raster position](vscode-debugging.md#raster-position)) |
| `set_write_overlay(enabled, opacity_percent, fade_percent)` | Dim the picture and show every byte written to the screen bitmap at full brightness, lifted a chosen amount, cleared each frame or faded across several (see [display-write overlay](vscode-debugging.md#display-write-overlay)) |
| `set_graphics_view(source, address, format, width, height, count, pin, …)` | Point VS Code's graphics panel at some bytes and say how to draw them, or with `pin` add them to its sheet (see [graphics viewer](vscode-debugging.md#graphics-viewer)). The only tool that moves something in the editor rather than in the machine |
| `get_audio(duration_ms, include_wav)` | Measure the beeper: sample count, RMS, peak and pitch in Hz (C++ core only) |
| `get_state()` | Full snapshot: PC, registers, breakpoints, running flag, border |
| `resolve_symbol(name)` | Symbol name → address (loaded program's own debug info first, then the ROM's) |
| `resolve_address(addr)` | Address → nearest symbol + offset (same sources as `resolve_symbol`) |
| `profile(action, lines, routines)` | Measure where execution time goes: `start` counts from zero, `stop` freezes, `get` reports the most expensive source lines and routines with T-states per frame, and the call tree by call path -- on a running machine, without pausing it (see [execution profile](vscode-debugging.md#execution-profile)) |

## Video

An MCP tool result can carry text, images and audio, but not video -- and a
model cannot watch one anyway. So "a video of the display" comes in two
forms, for two audiences.

**For the model: `get_screen_sequence`.** Several consecutive completed
frames, returned as separate PNG images in the order the machine drew them,
each preceded by a line giving its frame number and its offset in emulated
milliseconds from the first. `frames` (1-16, default 8) is how many, and
`every` (1-250, default 1) how far apart: consecutive frames are 20ms apart,
`every: 5` is one every 100ms, `every: 50` one a second. On a running machine
the frames are picked out of the run as it goes; on a stopped one the machine
is stepped forward frame by frame and left stopped where the last capture
landed, announced as a step so a debugger refreshes. Each frame is exactly as
the ULA completed it, with the [write overlay](vscode-debugging.md#display-write-overlay)
baked in if that is on.

**For a person: `start_video` / `stop_video`.** Records every completed frame,
at the Spectrum's own 50 a second, into a file that ffmpeg encodes -- the
extension picks the format, and `.mp4` is the one everything plays. The shape
is start, drive the machine (run, press keys, step), stop; both ends take
effect immediately, mid-run included, so a recording can be opened and closed
around part of a run. `seconds` or `frames` makes it stop itself; `scale`
(default 2) is integer pixel scaling, since a 352-wide video is smeared by
every player's own upscaler. `video_status` reports the frame count as it
climbs, and finalises a recording that reached its own limit.

Frames go to ffmpeg over a pipe from a writer thread, so an encoder that
stalls cannot stall the emulator: a frame that arrives while the queue is
full (two seconds' worth) is dropped and counted, and the status reports
`dropped` so a video with gaps says so. ffmpeg is found on `PATH`, or named
with `zx_server --ffmpeg <path>`; without one, `start_video` says so and
nothing else changes.
