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
| `pause()` | Interrupt an in-flight `run()`, or cancel a long search back through the history |
| `step_back(mode="over", count=1)` / `reverse_continue()` | Go back through what the program did: `"into"` the previous instruction, `"over"` the previous one in this routine, `"out"` the `CALL` that entered it; or back to the last breakpoint hit (see [stepping backwards](#stepping-backwards)) |
| `run_back_to(address)` / `run_back_to_write(address)` | Back to the last time execution reached an address, or to the instruction that last wrote one |
| `return_to_live()` / `history_status()` | From the past, replay to the newest instant; how much history there is and where the machine is in it |
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
| `get_state()` | Full snapshot: PC, registers, breakpoints, running flag, border, call stack, and `rewind` (built with it), `in_past` and `behind_tstates` |
| `resolve_symbol(name)` | Symbol name → address (loaded program's own debug info first, then the ROM's) |
| `resolve_address(addr)` | Address → nearest symbol + offset (same sources as `resolve_symbol`) |
| `profile(action, lines, routines, tree_min_percent, idle, period)` | Measure where execution time goes, on a running machine without pausing it: the most expensive source lines and routines, the call tree by call path, and the worst frames (see [execution profile](#execution-profile)) | (see [execution profile](vscode-debugging.md#execution-profile)) |

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

## Stepping backwards

The same history as VS Code's [stepping backwards](vscode-debugging.md#stepping-backwards):
about the last minute of emulated time, ended by a reset or a load. Every tool
here needs a stopped machine and blocks until it lands, answering with `moved`,
`cancelled`, `pc`, `registers`, `call_stack`, `in_past` and `behind_tstates`;
`step_back` adds `steps`, how many of `count` it managed. When nothing earlier
matches, the machine stays where it was, `moved` is false and `note` says why.

- **`step_back {mode, count}`** -- `"into"`: the previous instruction executed;
  `"over"` (the default): the previous one in this routine, passing over a call
  just returned from; `"out"`: the `CALL` that entered this routine.
- **`reverse_continue`** -- the most recent earlier breakpoint hit, or the start
  of the history.
- **`run_back_to {address}`**, **`run_back_to_write {address}`** -- an address
  or a symbol expression. The write is found before it happens, so one `step`
  shows it.
- **`return_to_live`** -- replay to the newest instant recorded.
- **`history_status`** -- `live`, `tstates_behind`, `frames_behind`,
  `frames_available`, `checkpoints` and `bytes`.

Forward from the past, `step` and `run` replay what happened. A `key_down`,
`write_memory`, `set_registers`, `tape_control` or a `step` by `ticks` there
starts a new timeline, discarding what came after.

A question this answers well: *who wrote that?* Stop where a value is wrong,
then `run_back_to_write {address: "player_x"}` lands on the instruction that
wrote it, with the call stack of the routine that did.

A server built without rewind (`build.ps1 -NoRewind`) does not list these tools,
and `get_state` reports `rewind: false`.

## Execution profile

`profile` is the numbers behind VS Code's
[execution profile](vscode-debugging.md#execution-profile) -- the heat map, the
call tree and the worst frames -- for a client that wants to measure rather
than look. Every call returns the same report; `action` says what to do first:

| `action` | Does |
|---|---|
| `start` | Count from zero, from the next instruction. Idle routines and the period are kept from before |
| `stop` | Stop counting; the counts stay readable |
| `get` | Just report |

The report, trimmed to the `lines` and `routines` most expensive (20 each by
default; 0 for all):

- **Totals:** `frames`, `instructions`, `interrupts`, `tstates`, `idle_tstates`,
  `busy_tstates`, `tstates_per_frame` and `busy_tstates_per_frame`, and
  `frame_tstates` -- the length of a frame on this machine, the budget a game
  works to.
- **`lines`:** per source line, `path`, `line`, `symbol` (`sprite_blit+12`),
  `hits`, `tstates` and `idle_tstates`. A `CALL` line also has `calls_tstates`
  and `calls_idle_tstates`: the time the calls made from it took, on top of its
  own.
- **`routines`:** the same per routine; a local label counts as part of the
  routine above it, and code with no source is grouped by 256-byte page
  (`$9000-$90FF`).
- **`call_tree`:** the calling-context tree nested from `(outside any call)`,
  children most expensive first, each with `calls`, `tstates` (itself and its
  children) and `self_tstates`. Cut to the calls holding at least
  `tree_min_percent` of the time (default 2); the time in calls cut is given as
  `other_calls_tstates`.
- **`periods`:** `count`, `busy_tstates_average`, `busiest_tstates`,
  `without_idle` (periods with no idle time at all), a `strip` of busy time per
  period (each entry the busiest of `bucket` periods), and `worst`: the ten
  busiest, each with `start_frame`, `tstates`, `idle_tstates`, `busy_tstates`,
  `frames` (its length in frames) and its own `lines` and `routines`.

Two settings shape the counting. Both are kept by the server across calls and
starts, apply from the moment they are set, and are shared with VS Code's
profile view:

- **`idle`:** routine names whose time is waiting, not work -- the busy-wait
  that paces a game. Their time is reported as idle and left out of busy time;
  a `HALT` waiting is always idle. The list replaces the previous one, and
  names that match nothing come back in `unresolved`.
- **`period`:** `"frame"` (the default), or a routine whose arrival starts each
  period -- a game loop that takes more than a frame a turn. Changing it
  restarts the periods.

The measuring loop this is for:

```
profile {action: "start", idle: ["turn_pace"], period: "frame"}
run                                        # play the part worth measuring
profile {action: "get", lines: 10}         # note busy_tstates_per_frame and the worst
... change the code, rebuild, load the same snapshot ...
profile {action: "start"}                  # the idle list and period carry over
run
profile {action: "get", lines: 10}         # compare
```

Costs are timed off the emulated clock. ULA memory contention is not emulated
yet, so code in contended memory costs what it would uncontended.
