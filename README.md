# zx-spectrum-emulator

A headless ZX Spectrum 48K emulator whose primary interface isn't a keyboard and a
CRT — it's two debugging APIs sharing one live machine. You can set a breakpoint
and single-step in VS Code (over the [Debug Adapter Protocol][dap]) while an
LLM agent inspects and drives the *same running emulator* over
[MCP][mcp], both seeing consistent state in real time.

[dap]: https://microsoft.github.io/debug-adapter-protocol/
[mcp]: https://modelcontextprotocol.io/

```
                     ┌─────────────────────────────┐
   VS Code  ───DAP──▶│                              │
  (breakpoints,      │   Engine (command queue +    │◀──MCP─── Claude / any
   stepping,         │   emulation thread) owns the  │           MCP client
   registers)        │   ONE live Spectrum48K        │
                     └─────────────────────────────┘
                                   │
                     command queue + event fan-out
                     (both sides see every state
                      change, however it happened)
```

> ## The C++ core is the project
>
> `cpp-core/` is the only supported implementation. The original Python core
> (`zxspectrum/`, `cffi` around `z80.h`) and the from-scratch Rust core
> (`rust-core/`) are both **deprecated**: still in the repo, but no longer
> developed, no longer verified, and no longer wired into `.vscode/` — every
> launch configuration now targets the C++ server. Tape loading, beeper audio
> and cycle-by-cycle bus tracing only ever existed in the C++ core.
>
> The `scripts/` helpers are still Python and still current — only the Python
> *emulator* is deprecated. For a clean install, follow
> **[INSTALL.md](INSTALL.md)**, which is C++-only throughout.

## What's actually emulated

- **CPU**: full Z80 core, cycle-stepped and pin-level, written in C++
  (`cpp-core/src/z80.cpp`) and diffed instruction-for-instruction against the
  vendored [floooh/chips](https://github.com/floooh/chips) `z80.h` reference,
  plus a full ZEXALL/ZEXDOC pass.
- **Memory**: the standard 48K map — 16K ROM (write-protected) + 48K RAM.
- **Display**: the ULA's screen decode (the classic interleaved-thirds bitmap +
  attribute layout), border color, and the ~50Hz frame interrupt.
- **Keyboard**: the full 8×5 matrix on port `0xFE`.
- **Snapshots**: `.sna` loading (registers + memory + border, including the
  format's PC-on-the-stack quirk).
- **Tape**: `.tap` and `.tzx` loading in the C++ core, at pulse level through
  the EAR line, with an optional fast-load trap on the ROM's LD-BYTES — see
  [Tape](#tape).
- **Disassembler**: the full documented Z80 instruction set (unprefixed, `CB`,
  `ED`, `DD`, `FD`, and `DD CB d`/`FD CB d`), including the well-known
  undocumented `IXH`/`IXL`/`IYH`/`IYL` register forms.

**Not emulated (yet):** 128K/+2 banking, the AY sound chip, memory contention /
cycle-exact ULA timing, and tape *saving*. See
[Status & roadmap](#status--roadmap).

Beeper audio (port `0xFE` bits 4 and 3) *is* emulated by the C++ core — see
[Audio](#audio).

## Why this architecture

- **One process, one live emulator, four front-ends.** `cpp-core/src/engine.h`
  owns the single `Spectrum48K` instance and is the *only* thing allowed to
  touch it. The MCP and DAP servers never call the core directly — they queue
  a command and wait on a future for the reply; the
  [screen stream](#live-screen-viewer) and the [audio stream](#audio) read it
  the same way, just repeatedly. The machine runs on its own thread and the
  queue serialises access to it, so every front-end always sees consistent
  state. Five things deliberately *bypass* the queue, because they have to
  work mid-run rather than at the next yield: pause, key presses, screen
  reads, trace control and the tape transport — see `engine.h`'s header
  comment for why each one.
- **Events, not polling.** The engine also fans out state-change events
  (`Stopped`, `Continued`) to every subscriber. If you tell it to `run` or
  `step` over MCP, your VS Code session gets an unsolicited `stopped` DAP
  event even though VS Code didn't ask for the change — and vice versa when
  you set a breakpoint by clicking the gutter.
- **The Z80 core is pin-level and cycle-stepped, not instruction-level.**
  The core is clocked once per half-T-state with a pin mask encoding the
  address/data/control lines, and every memory and I/O access passes through
  a bus you control. That's what makes T-state-accurate stepping, memory/IO
  watchpoints and the [cycle-by-cycle bus trace](#cycle-by-cycle-bus-tracing)
  straightforward — the trace is simply that bus, recorded.

## Requirements

- **Windows 11** with [Build Tools for Visual Studio 2022](https://visualstudio.microsoft.com/visual-cpp-build-tools/)
  and its "Desktop development with C++" workload. CMake and Ninja come with
  that workload; `cpp-core/build.ps1` locates them and imports the MSVC
  environment itself, so no developer prompt is needed.
- **VS Code 1.85+**, for the debugging front end.
- A real 48K ZX Spectrum ROM image, 16384 bytes (16K) exactly. Not included —
  see [ROM](#rom).
- **Python 3.10+ — optional**, and only for the helpers in `scripts/` (ROM and
  game disassemblies, tape generation). The emulator itself needs no Python.

Other platforms: `cpp-core` is portable C++17 with its platform-specific audio
and socket code `_WIN32`-guarded, so a Linux/macOS build is plausible — but it
is unverified, and `build.ps1`, the `.vscode/tasks.json` paths and the WASAPI
audio backend are all Windows-only.

## Setup

```powershell
cd cpp-core
.\build.ps1 -Release -Test     # RelWithDebInfo, then the fast test suite
```

That produces `cpp-core/build/RelWithDebInfo/zx_server.exe`, which is what the
VS Code tasks launch. A `Debug` build (plain `.\build.ps1`) lands elsewhere and
those tasks won't find it. `-Slow` runs the ZEXALL/ZEXDOC exercisers instead of
the fast suite — billions of emulated instructions, so pair it with `-Release`.

For the whole install end to end — ROM, build, the VS Code extension, first
launch and MCP — follow **[INSTALL.md](INSTALL.md)**, written as a checkable
step-by-step procedure.

## ROM

The emulator needs a genuine 48K Spectrum ROM to boot into BASIC — it isn't
included (it's Sinclair/Amstrad-copyrighted). Drop a 16384-byte ROM image at
`roms/48.rom` (the whole `roms/` directory except `.gitkeep` is gitignored,
so it never gets committed). You can verify a candidate file is the real
thing by checking its first byte is `0xF3` (`DI`, the first instruction of
every genuine Spectrum ROM).

## Running

```powershell
.\cpp-core\build\RelWithDebInfo\zx_server.exe `
  --mcp-host 127.0.0.1 --mcp-port 8000 `
  --dap-host 127.0.0.1 --dap-port 4711 `
  --screen-host 127.0.0.1 --screen-port 8500 `
  --rom roms\48.rom
```

One process, one `Engine`, every server — MCP, DAP, the
[screen stream](#live-screen-viewer) and the [audio stream](#audio) — sharing
the one live machine. Normally you don't run this by hand: the VS Code
`preLaunchTask` starts it (see [Connecting VS Code](#connecting-vs-code-dap)).

### Connecting an MCP client

Point any MCP client at `http://127.0.0.1:8000/mcp` (streamable HTTP).

The repo includes `.mcp.json`, so opening this workspace in Claude Code
picks up the server automatically (you'll be prompted to approve it once).
To add it manually instead (e.g. a different client, or without opening
the workspace), for Claude Code:

```bash
claude mcp add zx-spectrum --transport http --url http://127.0.0.1:8000/mcp
```

Either way, the server itself needs to actually be running first (see
[Running](#running) above) — `.mcp.json` only tells the client where to
look, it doesn't start it.

**Available tools:**

| Tool | Does |
|---|---|
| `load_rom(rom_base64)` | Load a 16K ROM image (base64) |
| `load_snapshot(sna_base64)` | Load a `.sna` snapshot (base64) |
| `load_debug_info(sld_path, asm_path)` | Attach source-level debug info for the loaded program (see [source-level debugging](#source-level-debugging-of-your-own-program)) |
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

### Connecting VS Code (DAP)

The repo's `.vscode/` folder is a ready-to-use workspace: `tasks.json` builds
`cpp-core` and starts `zx_server.exe`, and `launch.json`'s **"ZX Spectrum:
Step through ROM"** configuration points at it. Two one-time setup steps are
required first, on top of [Setup](#setup):

1. **A real 48K ROM** — see [ROM](#rom) above. `launch.json` expects it at
   `roms/48.rom`.
2. **Install the `vscode-extension/` extension.** VS Code requires
   `launch.json`'s `type` to match a registered `contributes.debuggers`
   entry before it will even attempt a `debugServer` connection — this is
   true even though no actual adapter code is needed for that part, since
   `debugServer` overrides which process VS Code talks to (see the [extension
   guide](https://code.visualstudio.com/api/extension-guides/debugger-extension)).
   The repo's `vscode-extension/` directory is a small real extension (it
   also provides the live screen viewer — see below) — copy or symlink it
   into your VS Code extensions folder:

   ```powershell
   # PowerShell, from the repo root
   Copy-Item -Recurse .\vscode-extension "$env:USERPROFILE\.vscode\extensions\jonsole.zxspectrum-debug-0.0.2"
   ```

   Then reload VS Code ("Developer: Reload Window") to pick it up. See
   `vscode-extension/README.md` for details and re-install instructions after
   editing it.

With both in place, open the Run and Debug view and launch **"ZX Spectrum:
Step through ROM"**. The `preLaunchTask` starts the server automatically
(watch its output in the dedicated terminal panel) and waits for it to be
ready before connecting.

Without the ROM disassembly built (see below), this drives VS Code's
**Disassembly View** rather than a source view: breakpoints are instruction
breakpoints set from there, and each stack frame is labeled with just the
disassembled instruction at its address (no symbol name). Stepping is `next`
(one Z80 instruction) regardless. Supported requests: `initialize`, `launch`/`attach`,
`configurationDone`, `setInstructionBreakpoints`, `setBreakpoints`,
`continue`/`next`/`stepIn`/`stepOut`/`pause`, `threads`, `stackTrace`,
`disassemble`, `scopes`/`variables` (a **Registers** scope — including the
shadow set `AF'`/`BC'`/`DE'`/`HL'` — and a **Flags** scope breaking `F` out
into `S`/`Z`/`H`/`P·V`/`N`/`C` booleans), `readMemory`/`writeMemory`, and
`disconnect`.

**Verified working in an actual live VS Code session**, not just
protocol-level: launch, breakpoints, continue-to-breakpoint, disassembly-view
navigation (forward and backward from an arbitrary PC, including across the
0xFFFF/0x0000 address wrap), and register inspection all confirmed by hand
against the real ROM. A couple of real bugs turned up exactly this way and
are already fixed — see [Status & roadmap](#status--roadmap) and the git
history for details.

One current UI rough edge, not fixable from the adapter side: for a
source**less** frame (i.e. without the ROM disassembly built), VS Code
doesn't reliably auto-populate the Registers panel or auto-focus the
Disassembly View on every stop — clicking the Call Stack entry once after a
stop refreshes it. Tracked upstream as
[microsoft/vscode#131253](https://github.com/microsoft/vscode/issues/131253).

#### Live screen viewer

Run **"ZX Spectrum: Show Screen"** from the Command Palette (or just launch a
debug session — it opens automatically) for a live view of the display
alongside your code, fed by a third server port (`--screen-port`, default
`8500`) that streams the screen as a continuous sequence of PNG frames (10fps)
to any connected client. The extension bridges that stream into a webview
panel; watch it update in real time as you step, run, or drive the machine
over MCP.

This port is a plain, independent front-end onto the shared `Engine` — the
same standalone-server design as DAP and MCP, not something that only works
through VS Code. Any client can connect directly and read the same frames
(4-byte big-endian length prefix + that many PNG bytes, repeated for as long
as the connection stays open) — see `cpp-core/src/screen_stream.cpp`.

Frames are read via `engine.machine.render_screen()` directly rather than
through the engine's normal command queue — a `run()` in progress occupies
the actor loop for its entire duration, so a queued read would sit unserved
(and the view would visibly freeze) until it stopped. Same queue-bypass
pattern DAP's own memory reads already use, for the same reason.

#### Call stack

`stackTrace` shows a real, multiple-frame call stack, not just the current
PC: `Spectrum48K` tracks `CALL`/`RST` and their matching `RET` as they
execute (`spectrum.cpp`'s call-stack tracking), so stepping into a routine adds a
frame for it, each labeled and sourced exactly like the top frame (using
whichever debug info covers that address — the loaded program's own, or the
ROM's). It's a live opcode-level watch, not stack-memory guesswork — the Z80
has no frame-pointer convention, so there's no reliable way to tell a return
address from ordinary pushed data by inspection alone.

Two things it deliberately doesn't track, both rare in practice: interrupt
handler entry/exit (`RETI`/`RETN`) is invisible to it on purpose, so it
can't desync the frames it *does* track; and code that unwinds the stack by
resetting SP directly instead of matching `RET`s one-for-one (an idiom the
ROM itself uses for error handling) can leave stale frames until the next
real `CALL`/`RET` resyncs things. Cleared automatically on reset, a new
snapshot, or any direct PC/register write, since a stale call chain would
be actively misleading rather than just incomplete.

#### Source-level debugging of the ROM

The 48K ROM's disassembly has been reverse-engineered and fully commented by
others — [SkoolKit's `skoolkid/rom`](https://github.com/skoolkid/rom)
reproduces *The Complete Spectrum ROM Disassembly* (Logan & O'Hara) as a
`.skool` file. `scripts/build_rom_source.py` turns that into a real source
view for the DAP session:

```
skoolkid/rom (.skool)  →  skool2asm.py  →  sjasmplus --sld  →  rom_disassembly/
                                                                  rom.asm  (readable, labeled source)
                                                                  rom.sld  (address <-> source-line map)
```

Run it once. The `scripts/` helpers are Python — the only part of the project
that still is — and want their own venv: `python -m venv .venv-win` then
`.\.venv-win\Scripts\pip.exe install skoolkit`, plus `sjasmplus` on PATH (see
the script's `--help` for where to get a build per platform):

```sh
.venv-win\Scripts\python.exe scripts\build_rom_source.py
```

It clones `skoolkid/rom` into `.rom-disassembly-src/` and writes
`rom_disassembly/rom.asm` + `rom.sld` — both gitignored, since the
disassembly (like the ROM binary itself) is copyrighted material fetched
locally, never committed. The script **refuses to write output** unless the
freshly assembled binary is byte-for-byte identical to `roms/48.rom` — a
mismatch would mean the address↔source-line map can't be trusted for
debugging, which is worse than not having one.

Once built, the DAP server picks it up automatically (no config needed) the
next time it starts: stack frames get a real `source`/`line` into
`rom.asm` (VS Code opens it and highlights the current line on every stop,
labeled with its nearest routine — e.g. `KEY_INT+3`), and breakpoints can be
set by clicking the gutter in that file directly, resolved to addresses via
the SLD map. Instruction breakpoints (from the Disassembly View) still work
and can be mixed freely with source breakpoints in the same session.

#### Source-level debugging of your own program

Assembled your own program with `sjasmplus --sld`? Attach its `.sld` plus
the source it was built from, and get everything above for your own code
too — real `source`/`line` in stack frames, gutter breakpoints, and
`resolve_symbol`/`resolve_address`. It's layered on top of the ROM's own
source (not a replacement for it): your program's debug info is checked
first, and a `CALL` into a ROM routine still resolves to `rom.asm` once
execution is inside it, so you don't lose one to get the other.

Over MCP:

```
load_snapshot(sna_base64=...)
load_debug_info(sld_path="C:/path/to/yourprogram.sld", asm_path="C:/path/to/yourprogram.asm")
```

Over DAP, add `sld`/`asm` to the launch config alongside `snapshot`:

```json
{
  "name": "My program",
  "type": "zxspectrum",
  "request": "launch",
  "debugServer": 4711,
  "rom": "${workspaceFolder}/roms/48.rom",
  "snapshot": "${workspaceFolder}/yourprogram.sna",
  "sld": "${workspaceFolder}/yourprogram.sld",
  "asm": "${workspaceFolder}/yourprogram.asm",
  "preLaunchTask": "zxspectrum-cpp.start-server"
}
```

Loading a *new* snapshot always clears the previously-attached debug info
(it almost certainly doesn't match the new program's addresses) — reattach
with `load_debug_info`/relaunch for whatever program you loaded next. The
ROM's own source is unaffected either way; it's always available
independently once built.

#### Example: Manic Miner

A bigger example than `hello_rom_call` — [SkoolKit's Manic Miner
disassembly](https://github.com/skoolkid/manicminer), source-level debuggable
end to end. `scripts/build_manicminer.py` fetches it, assembles it with
`sjasmplus`, and wraps the result into a `.sna` (`snapshot.cpp`'s
`write_sna()`, the write-side counterpart of the `.sna` loader):

```sh
.venv-win\Scripts\python.exe scripts\build_manicminer.py
```

Unlike `hello_rom_call` (original, trivial, safe to commit), the output here
**must never be committed** — a full game disassembly necessarily reproduces
the actual copyrighted game code and data in full, same treatment as the ROM
itself: `game_disassembly/` and `.manicminer-disassembly-src/` are gitignored,
built locally, and there's no reference binary to verify against (unlike the
ROM), so a clean `sjasmplus` assembly with zero errors is the correctness
signal instead. Launch **"ZX Spectrum: Manic Miner"** once built, or load
`game_disassembly/manicminer/mm.sna` + `mm.sld` over MCP the same way as any
other program.

#### Example: Fairlight

A second, larger game disassembly — [VilleKrumlinde/FairlightZ80](https://github.com/VilleKrumlinde/FairlightZ80),
a hand-annotated reconstruction of the 1985 isometric adventure, complete
with a written analysis of its render pipeline, room bytecode format and
textured flood fill. `scripts/build_fairlight.py` fetches it, assembles it
with `sjasmplus`, and wraps the result into a `.sna`:

```sh
.venv-win\Scripts\python.exe scripts\build_fairlight.py
```

Two differences from Manic Miner. The upstream repo ships assembler source
directly (no `skool2asm` step), and because it was reconstructed from a
snapshot rather than a tape image it assembles to the *entire* 48K RAM
image — screen, sysvars and runtime buffers included — so the `.sna`'s RAM
is the assembler's output verbatim. That also means the startup register
state isn't in the source anywhere and has to be reconstructed — PC
`0xF065` (the title-screen loop), SP `0x6392` (recovered from the original
snapshot's header), and IY `0xFF80` (the game-state block, which the code
assumes is already in IY on entry; leaving it at 0 hangs the first room
draw and gives a permanently black screen). Each is derived in a comment
in the script.

Same copyright treatment as Manic Miner: `game_disassembly/` and
`.fairlight-disassembly-src/` are gitignored and never committed. Launch
**"ZX Spectrum: Fairlight"** — its `preLaunchTask` reassembles
before starting the server, so editing the fetched `.asm` and relaunching
picks the change up.

#### Example: Atic Atac

Unlike the other two, this one has no published disassembly to fetch:
`scripts/build_aticatac.py` produces it from a `.tap` of the 1983 Ultimate
game itself.

```sh
.venv-win\Scripts\python.exe scripts\build_aticatac.py --tape "Atic Atac.tap"
```

Two problems have to be solved that the other two don't have. First, the
tape is *encrypted*: the BASIC loader's `PRINT USR 23424` enters an 18-byte
stub in the printer buffer that `RRD`s a nibble through all 31744 bytes of
the game before jumping to `0x6000`, so the plaintext only ever exists in
RAM. The script runs the tape's own decryptor via `tap2sna`'s simulated
load and disassembles the result. (A second piece of the same protection
pokes `0x255E` into `FRAMES`, which the decrypted entry point checks and
drops back to BASIC if absent — so the tiny tape blocks matter.)

Second, telling code from data. Atic Atac is mostly graphics, and a static
pass mis-reads a lot of sprite data as plausible instructions. So the script
*plays the game* in SkoolKit's simulator — mashing keys through the title
screen and around the castle, once per character and control method — and
records every address actually executed. That map drives the code/data
split, so unreached bytes stay `DEFB`s rather than becoming invented
instructions. The whole build takes about a minute.

There's no reference binary to diff against, so the check is a round trip:
the generated `.asm` is fed back through `sjasmplus` and compared against
the decrypted memory it came from. The build fails unless all 30208 bytes
match byte-for-byte.

Same copyright treatment as the others — `game_disassembly/` is gitignored
and never committed. Load `game_disassembly/aticatac/aticatac.sna` +
`aticatac.sld` over MCP or DAP for source-level debugging, same as Manic
Miner.

### Cycle-by-cycle bus tracing

The C++ core runs at half-T-state resolution, so it can record what every
signal on the bus was doing in each half of each T-state. The trace is written
as the same box-drawn table
[visualz80remix](https://floooh.github.io/visualz80remix/) produces, which is
deliberate: a capture from here and a capture from there can be put side by
side and diffed, and that comparison is a test in its own right (see below).

```
┌─────────┬────┬──────┬──────┬──────┬────┬────┬──────┬────┬──────┬───────┬─────
│ Cycle/h │ M1 │ MREQ │ IORQ │ RFSH │ RD │ WR │ AB   │ DB │ PC   │ Watch │ Asm
├─────────┼────┼──────┼──────┼──────┼────┼────┼──────┼────┼──────┼───────┼─────
│     1/1 │ M1 │ MREQ │      │      │ RD │    │ 0000 │ 00 │ 0001 │ ??    │ DI
│     2/0 │ M1 │ MREQ │      │      │ RD │    │ 0000 │ F3 │ 0001 │ ??    │ DI
│     3/0 │    │      │      │ RFSH │    │    │ 0000 │ F3 │ 0001 │ ??    │ DI
```

Start one from the command line, which is the only way to catch the machine's
first few thousand half-clocks:

```bash
zx_server --rom roms/48.rom --trace-log boot.zxtrace --trace-limit 25000
```

| flag | meaning |
| --- | --- |
| `--trace-log PATH` | where to write; enables tracing at boot |
| `--trace-limit N` | half-T-states to record before the capture closes itself (default 25000, `0` = unlimited). One frame is 139,776 |
| `--trace-watch HEX` | a memory address to sample into the Watch column each half-clock |
| `--trace-extra` | add the 48K-specific columns: HALT, WAIT, INT, NMI, frame, T-state |

Or drive it live — with the trace viewer's own **Record** button in VS Code
(see below), or over MCP with `start_trace` / `stop_trace` / `trace_status`.
That is the usual way: capture a window around a breakpoint rather than from
power-on. All three bypass the emulator's command queue, so a capture can be
opened and closed across a run in flight rather than only around one — you can
record a game as it plays, and stop when you have seen the thing you were
after.

Tracing costs nothing when it is off (one predictable branch per half-clock)
and is slow when it is on, which is why every capture is bounded.

#### Viewing a trace

`tools/trace_viewer.html` is a self-contained page — no build step, no
dependencies, no network. Open it in a browser and drop a `.zxtrace` on it, or
run **ZX Spectrum: Show Trace** from the VS Code extension, which loads that
same file into a webview and reloads it whenever the capture is rewritten.

In the VS Code panel it also takes the capture. **Record** starts a trace on
whatever the current debug session is running — running or stopped, it makes no
difference — with the same `limit`, `watch` and 48K-column options the flags
above have; the header counts the half-T-states as they land. **Stop** ends it,
and so does the capture reaching its own limit; either way the finished file is
loaded into the panel straight away. It is written as `live.zxtrace` in the
workspace folder, so it is an ordinary file afterwards: keep it, diff it,
reopen it later.

It has two views over the same data:

* **Trace Log** — the table, banded per instruction and searchable (`$4000`
  jumps to the next row whose address bus holds it).
* **Timing Diagram** — CLK plus a waveform per signal, drawn active-low as a
  datasheet would, with the address/data/PC buses as labelled value segments
  and each instruction shaded behind them.

Clicking in either view moves the selection in the other, and the arrow keys
step half-clock by half-clock.

The viewer reads the header row to discover the columns, so it opens captures
made with or without `--trace-extra`, and visualz80remix's own exports too.

#### What the comparison found

`cpp-core/tests/tracelog_tests.cpp` replays visualz80remix's own demo program
and diffs the two tables cell by cell. **M1, MREQ, IORQ, RD, WR, the address
bus and the T-state numbering agree everywhere** — the machine-cycle structure
is identical. Three sub-T-state differences remain, none of them observable to
a running program, all recorded in that test's `KNOWN_DIFFERENCES` so a new
one cannot creep in unnoticed:

* **RFSH** — the real chip holds refresh asserted through T4L; this core
  releases it half a T-state early, at T4H. The one that is a genuine
  inaccuracy: it shortens the window a refresh address is live on the bus,
  which is exactly where 48K "snow" comes from, so it will matter once
  contention lands.
* **Data bus on a write** — the die drives the byte at T1L, this core at T2H.
  Zilog's own timing diagram says the start of T2, so the datasheet agrees
  with us here and the die with neither.
* **PC** — incremented on the H phase here, on the L phase in the real chip.
  Purely internal; PC is not a pin, and the address it produces reaches the
  bus at the same instant either way, which is why AB matches everywhere.

### Shared state, live

Because both front-ends drive the same `Engine`, you can set a breakpoint in
VS Code, have an MCP client `run()` past other breakpoints and hit yours, and
watch VS Code's UI update on its own — no polling, no manual sync. This is
the actual point of the project.

## Audio

The C++ core emulates the 48K beeper: writes to port `0xFE` latch the speaker
(bit 4) and MIC (bit 3) levels, and those become mono 16-bit PCM.

**Nothing is sampled per clock cycle.** The level only changes when a program
writes the port -- a few thousand times a second at most -- so each write is
recorded against the half-T-state it happened on, and the level is integrated
forward when somebody asks for the audio. The cost lands per *sample* rather
than per *half-clock*, which keeps it out of the emulator's hot loop
entirely: `bench_machine` measures the same throughput with the feature as
without it.

The write is stored as a *latch*, not an edge. Control lines are not
auto-cleared, so `service_bus()` sees a single `OUT` assert IORQ/WR on five
consecutive half-clocks and applies it five times over; assigning a level is
idempotent under that, whereas counting edges would count five.

### Sound as the master clock

With a native output device, the emulator paces against the **sound card**
rather than against `steady_clock`. This is what keeps picture and sound
locked together, and it is worth understanding before changing anything here.

A card consumes samples at its own rate, which is never exactly the rate a
timer believes a 48K runs at. Pacing against the timer lets the two drift
apart, and the drift has to go somewhere: either audio piles up ahead of the
speaker (latency that never drains) or the device runs dry (gaps). Pacing
against the device instead makes the emulator produce exactly what the
hardware consumes -- and since frames come off the same emulation loop, the
picture follows the sound rather than being timed separately from it.
Measured at 50.09fps against a nominal 50.08.

Two corollaries, both learned the hard way and both commented in the source:

- A partially-filled buffer is **never** padded out and queued. Padding hands
  the device samples the emulator never produced, and because pacing counts
  them, the machine gets throttled by audio that was never real -- measured at
  40.1fps, a game running in visible slow motion with no indication anything
  was wrong. A gap is the honest failure: it costs a click, timing stays
  correct, and the fix is a larger `--audio-latency-ms`.
- The emulator needs production headroom *above* the device queue. With a
  target equal to the queue itself, any chunk at all puts it over, so it
  produces one chunk per buffer completion and runs at a fraction of speed
  (measured 23.5fps).

Without a native device -- panel playback only -- pacing stays on the wall
clock, since a network client should not be able to stall the emulator.

### Hearing and inspecting it

- **In VS Code.** The screen panel plays it. The extension host connects to
  the audio stream port and forwards blocks to the webview, which schedules
  them through the Web Audio API. There is a mute button in the top-right
  corner. Browsers will not start audio until you have interacted with the
  panel, so the first keypress or click is what gets it going.
- **Out of the server process.** `--audio-device` opens the default output
  directly. Never fatal: no sound card, or a device held exclusively by
  something else, prints a warning and carries on.
- **Over MCP.** `get_audio` reports sample count, RMS, peak and an estimated
  pitch over a rolling window, optionally with the window as a base64 WAV. It
  is a non-consuming read, so it can be called while something is playing.
  Handy for asserting that a BEEP came out at the frequency it should have --
  driving the ROM's own BEEPER routine at 440Hz measures 440.0.

```
zx_server.exe --rom roms/48.rom --audio-device --audio-latency-ms 80
```

`--no-audio` stops the stream server binding at all; pair it with
`--audio-device` for native-only output, which is what the Manic Miner and
Aquaplane launch configurations do (otherwise the panel plays the same audio
a second time, slightly out of phase). Audio is dropped entirely while the
emulator runs uncapped (`--uncapped`) -- samples generated hundreds of times
faster than real time are not playable.

### Backends and latency

Native playback prefers **WASAPI shared mode via `IAudioClient3`**, falling
back to waveOut if that is unavailable (pre-Windows-10, or a device that
refuses the low-latency path). `InitializeSharedAudioStream` asks the audio
engine for its *smallest* supported period and drives rendering from an event
rather than a poll; the render thread registers as `Pro Audio` through MMCSS
so it is not descheduled by the emulator thread. Measured 21ms of device
buffer, against 80ms for waveOut, whose 20ms blocks are its floor.

Shared mode runs at the engine's mix format and nothing else, so rather than
resampling onto it, **the beeper is told to generate at the mix rate
directly** -- its decimator is an integer accumulator that is exact at any
rate, so this costs nothing and loses nothing. That is why the sample rate is
not a constant, and why everything downstream learns it from the stream
preamble or `Engine::audio_sample_rate()` rather than assuming 44100.

`--audio-latency-ms` (default 80) behaves differently per backend, which is
worth knowing when tuning:

| | waveOut | WASAPI |
|---|---|---|
| What the flag sets | device queue depth, in 20ms blocks | how much is held *ahead* of the device |
| Why | buffers are ours to size | the engine caps the period it will grant |

So on WASAPI, raising the flag cannot deepen the device buffer, but it still
adds slack in front of it -- which is the lever to reach for if the smallest
period turns out too tight to stay glitch-free.

**Remote Desktop:** RDP redirects audio as a compressed stream with its own
buffering, typically adding 100-250ms plus jitter, all of it downstream of
anything measurable here. If audio seems far more delayed than the configured
buffer, or glitches under network load, check whether you are on RDP before
looking anywhere else -- and raise `--audio-latency-ms` hard (200+) to ride
out the jitter, since the delay itself cannot be recovered from this side.

### Stream format

Served on `--audio-port`, default `8501`, alongside the screen stream on
8500. A 12-byte preamble -- `ZXA2`, a big-endian `u32` sample rate, and a
big-endian `u32` target latency in milliseconds -- followed by
`[big-endian u32 byte length][mono int16 little-endian]` blocks, the same
framing the screen stream uses for PNGs. The latency travels with the stream
so one `--audio-latency-ms` sets both the server's buffering and the depth of
the client's own jitter buffer, rather than two settings that can disagree.

`cpp-core/build/…/beep.exe` is a diagnostic that drives the whole path and
writes a WAV you can listen to: `beep tone` for a known square wave, `beep
rom` to call the ROM's own BEEPER routine, `beep serve` to stand the servers
up on their own without `main.cpp`.

## Tape

`.tap` and `.tzx` images load in the C++ core. Both formats are detected from
the file's contents rather than its extension.

```bash
zx_server --rom roms/48.rom --tape games/manic.tzx
```

That inserts the tape, resets, types `LOAD ""` for you, and starts it — so the
machine is already loading by the time a client connects.
`--no-tape-autostart` inserts it stopped instead, which is what you want for a
program that loads its own next part.

There is no tape in the repo (games are copyrighted), so
`scripts/make_test_tape.py` generates one: a tiny autostarting BASIC program
that turns the border yellow and prints `TAPE LOADED OK`, written to
`tapes/loading-test.tap` and `.tzx`. Two launch configs point at it —
**Tape (fast load)** and **Tape (real pulse load)** — which is the quickest way
to see both paths working.

A third, **Tape (waiting for LOAD)**, takes no tape at all: it boots, types
`LOAD ""` and stops in the ROM loader, where a real Spectrum sits once you have
typed the command and not yet pressed Play. Insert whatever you like afterwards
and press Play:

```jsonc
load_tape    { "path": "...", "auto_start": false }
tape_control { "action": "play" }
```

That always loads at real tape speed even with fast load on, and it is not a
bug — the trap fires on *arriving* at `LD-BYTES`, and the ROM is already inside
it by then. Insert with `auto_start` left on (what the VS Code command does) and
it resets and retypes, so the trap gets its moment.

Either way the machine does not have to be stopped first: the emulator's run
loop services queued commands at its yields, so a tape dropped into a running
machine is picked up and the run carries straight on into loading it.

The same thing on the command line is `--wait-for-tape`.

The same thing from the other three directions:

- **launch.json**: `"tape": "${workspaceFolder}/games/manic.tzx"`, alongside
  `"tapeAutoStart"` and `"tapeFastLoad"`.
- **VS Code**: *ZX Spectrum: Load Tape…*, which puts a tape into a session that
  is already running, and the **ZX Spectrum Tape** pane in the debug sidebar —
  the block list, alongside Call Stack and Breakpoints, with the transport on
  its title bar. See [the extension's README](vscode-extension/README.md).
- **MCP**: `load_tape {path}` and `tape_control {action}` — play, stop, rewind,
  seek, eject, status. Every reply lists the blocks, so `tape_control {}` on
  its own is how to find out what an image contains. The transport bypasses the
  emulator's command queue, so Play reaches a game that is already running and
  asking for its next part; that is the only moment Play is any use.

### How it loads

Two mechanisms, and the fast one falls back to the slow one on its own.

The foundation is **pulse-level playback**: the tape resolves to a one-bit EAR
level on port `0xFE` bit 6, pulse by pulse, in the machine's own half-clock
time base. That is what a real cassette does, so it works with any loader at
all — turbo, custom `.tzx` block timings, whatever the publisher wrote. It is
also as slow as a real cassette, which for a whole game is minutes. `set_speed
uncapped` (MCP) or `"uncapped": true` (launch.json) is the way to hurry it up.

On top of that sits a **fast-load trap**. When the CPU reaches the ROM's
`LD-BYTES` at `0x0556` — and the bytes there really are the stock ROM's, which
is checked — a standard-speed block is copied straight into memory, the flags
and registers are set the way the routine would have left them, and the trap
returns as if from its final `RET`. It costs zero emulated T-states. Anything
that is *not* a standard-speed block (a turbo block, a pure-tone or pure-data
block, a tape that has run out) makes the trap decline, and the real ROM
routine then runs against real pulses. So a `.tzx` with a stock header and a
turbo body fast-loads the header and pulse-loads the body, which is exactly
right.

Fast load is on by default; `--no-tape-fast-load`, `"tapeFastLoad": false`, or
`load_tape {fast_load: false}` turns it off. Two differences when it is on:
there are no loading stripes in the border, because the trap never runs the ROM
code that draws them, and no loading screech, because the tape never plays.

### The loading sound

Worth being precise about, because the obvious guess is wrong. The ROM's loader
never touches the speaker bit at all — `LD_SAMPLE` ends `AND $07 / OR $08 /
OUT ($FE),A`, which is border bits plus a MIC bit that never changes. The
stripes are the CPU's doing; the screech is not.

What makes the noise is the EAR input itself: the ULA feeds the tape signal
into the same audio output as the speaker. So the emulator mixes EAR into the
beeper (`EAR_LEVEL` in `beeper.h`), sampled from the port reads the loader is
already making — thousands a second, far finer than the tone being reproduced.
A pilot pulse is 2168 T-states, so the leader comes out at 3.5e6/4336 ≈ 807 Hz,
which is what `get_audio` reports while one is playing.

Resetting the machine stops the motor but leaves the tape in the deck at the
block it had reached — a reset zeroes the frame counter, and with it the clock
every pulse timestamp is measured against.

## Testing

```powershell
cd cpp-core
.\build.ps1 -Release -Test     # the fast suite, via CTest
.\build.ps1 -Release -Slow     # ZEXALL + ZEXDOC only -- many minutes each
```

109 assertions across nine executables: the ALU and a pin-level check diffed
against the vendored `z80.h` reference (`alu_tests`, `pin_level`, and
`differential`, which runs both cores in lockstep), the 48K memory map, the
beeper's decimator, interrupt timing, the machine layer against a real ROM
(`spectrum_tests`), `.tap`/`.tzx` parsing and the fast-load trap
(`tape_tests`, 49 of them), and the bus trace against a captured
visualz80remix reference (`tracelog_tests`). Tests that need the real ROM skip
themselves rather than fail when `roms/48.rom` is absent.

Above those sits the full [ZEXALL/ZEXDOC](https://github.com/agn453/ZEXALL)
exerciser, labelled `slow` and excluded from the routine run: over a billion
emulated instructions per pass.

## Performance

Measured by `tests/bench_machine.cpp` (`bench_machine.exe`, RelWithDebInfo) —
the machine and Engine layers, i.e. what a connected client actually
experiences, rather than bare CPU throughput:

```
  machine (CPU+ULA, direct clock)        50.7 M half-clocks/s     7.25x realtime
  engine run(), uncapped                 40.5 M half-clocks/s     5.79x realtime
  engine run(), realtime (default)        7.0 M half-clocks/s     1.00x realtime
```

So the core runs a 48K at **~7× real hardware speed** with headroom to spare,
and paces itself down to 1.00× for normal use — games run at the right speed,
and `--uncapped` hands the rest back to the exercisers. Link-time optimisation
is worth ~23% of that on its own (41.5 → 51.2 M half-clocks/s when it was
turned on), because the hot loop crosses a translation-unit boundary on every
half-clock; see the comment in `cpp-core/CMakeLists.txt`.

<details>
<summary>Historical: the deprecated Python core's performance</summary>

Because every T-state crossed the Python↔native-C boundary, bulk execution ran
at roughly **0.5× real hardware speed** (~1.7 MHz effective vs. 3.5MHz real).
That was a deliberate tradeoff: the design target is debugger-driven
single-stepping, not real-time gameplay, and a faster bulk-tick path would
have required duplicating the bus-servicing logic outside the single code path
that per-T-state watchpoints depend on. The C++ core keeps that same single
code path and is fast enough anyway, which is what removed the tradeoff.

</details>

## Project layout

```
zx-spectrum-emulator/
  vendor/chips/z80.h          # vendored floooh/chips Z80 core -- the tests'
                              #   reference only, not the emulator (zlib license)
  cpp-core/                   # THE emulator
    build.ps1                 # configure + build + test (finds MSVC itself)
    src/
      z80.cpp                 # the Z80: cycle-stepped, pin-level
      alu.cpp                  # flags and arithmetic
      memory.cpp                # 48K map (16K ROM + 48K RAM)
      ula.cpp                    # screen decode, border, frame interrupt
      keyboard.cpp                # 8x5 matrix, port 0xFE
      beeper.cpp                   # port 0xFE bits 4/3 -> samples
      tape.cpp                      # .tap/.tzx, pulse level + fast-load trap
      snapshot.cpp                   # .sna loader + writer
      disassembler.cpp                # full documented Z80 disassembler
      tracelog.cpp                     # cycle-by-cycle bus capture
      rom_source.cpp                    # SLD parser (source-level debug)
      spectrum.cpp                       # Spectrum48K: wires it all together
      engine.cpp                # the shared live instance + command queue
      dap.cpp                    # DAP TCP server
      mcp_server.cpp              # MCP tools (streamable HTTP)
      screen_stream.cpp            # screen-frame TCP stream
      audio_stream.cpp              # audio TCP stream
      audio_wasapi.cpp               # native playback (Windows)
      main.cpp                        # entrypoint: engine + every server
    tests/                    # CTest executables, benchmarks, diagnostics
  scripts/                    # Python helpers -- still current
    build_rom_source.py         # builds rom_disassembly/ (see below)
    build_manicminer.py           # builds game_disassembly/manicminer/ (see below)
    build_aticatac.py             # builds game_disassembly/aticatac/ from a .tap (see below)
    make_test_tape.py             # generates tapes/
  examples/
    hello_rom_call/              # tiny original demo, committed
  tools/
    trace_viewer.html          # standalone viewer for cycle-by-cycle bus traces
  vscode-extension/            # debugger type registration + screen/trace/tape panels
  roms/                        # gitignored; drop your 48K ROM here
  rom_disassembly/             # gitignored; scripts/build_rom_source.py output
  game_disassembly/            # gitignored; scripts/build_manicminer.py output
  tapes/                       # scripts/make_test_tape.py output, committed
  snapshots/                   # the Z80 exercisers, committed; games gitignored

  # deprecated, kept for history -- see the note at the top
  zxspectrum/ + tests/*.py     # the original Python core and its pytest suite
  rust-core/                   # the from-scratch Rust Z80 core
```

## Status & roadmap

The full core build order is complete and verified end-to-end (Z80 →
memory/ULA/keyboard/snapshot/machine → disassembler → engine → MCP
server → DAP server), including a live concurrent-session check: a real DAP
client and a real MCP client connected simultaneously, each observing the
other's changes as unsolicited events.

A [VS Code workspace](#connecting-vs-code-dap) (`.vscode/tasks.json` +
`launch.json`) is included and confirmed working end to end in a real,
interactive VS Code session (see the note there about one VS Code UI rough
edge that isn't fixable from the adapter side).

Windows is the supported platform: MSVC Build Tools 2022, built through
`cpp-core/build.ps1`. Linux/macOS is plausible but unverified — see
[Requirements](#requirements).

**Known limitation, not yet fixed:** if a client starts `run()` and
disconnects without ever `pause()`-ing (e.g. a crashed or killed client
mid-session), the machine keeps running that program forever. Commands that
tolerate it are still serviced at each run-loop yield, and pause, keys, the
screen, tracing and the tape transport bypass the queue entirely — but
anything that drives emulation itself still waits for the run to end, and
there is no auto-pause on disconnect or run-time cap.

Source-level debugging against a real, commented disassembly (not just raw
instructions) is done, for both
[the ROM](#source-level-debugging-of-the-rom) and
[your own assembled programs](#source-level-debugging-of-your-own-program):
`scripts/build_rom_source.py` reproduces the ROM **byte-for-byte** via
`skool2asm.py` + `sjasmplus --sld`; `load_debug_info` attaches the same kind
of map for any `sjasmplus`-assembled program, layered on top of (not
replacing) the ROM's own, so a call from your program into a ROM routine
still resolves. `dap.cpp` uses whichever map applies for `source`-annotated
stack frames and source-line breakpoints; `resolve_symbol`/`resolve_address`
expose the same lookup over MCP. Verified end-to-end (build → `stackTrace` →
`setBreakpoints` → hit → correct PC, and separately, own-program address →
ROM address → correct source switches for both).

A [live screen viewer](#live-screen-viewer) is done too: a third server port
(`screen_stream.cpp`) streams the display as a continuous sequence of PNG
frames to any client, and the `vscode-extension/` extension bridges that into
a webview panel — the project's first extension with real code (previously
just a declarative debugger-type stub). Explicitly designed to keep working
standalone, independent of VS Code: the streaming port has no VS-Code-specific
code in it, same as DAP/MCP.

Stretch goals, not blocking normal use:
- `.z80` snapshot format (versioned, compressed — `.sna` works today)
- Tape loading — **done** for `.tap`/`.tzx` (see [Tape](#tape));
  `.pzx` and tape *saving* are still open, as are the `.tzx` sampled-data block
  types (`0x15` direct recording, `0x18` CSW, `0x19` generalized)
- Beeper audio synthesis — **done** (see [Audio](#audio)); the AY chip is not

## Rust core (`rust-core/`) — deprecated

> **Deprecated, kept for the record.** The C++ core took over the role this was
> being built for, and `rust-core/` is no longer developed. What follows
> describes where it got to, not what to use. The same goes for the Python core
> it refers to.

A from-scratch, hand-written Z80 interpreter in Rust — not an FFI wrapper
around `z80.h` — built alongside the Python project for two reasons: a genuine
path to WebAssembly (a browser-playable target had no good story via the
Python/`cffi` stack), and a deliberate Rust-learning exercise. The goal was for
`rust-core/` to grow into a full replacement for the Python
DAP/MCP/screen-stream server, reusing one core for both a native server and a
wasm browser player. It stopped at CPU-only, with the memory/ULA/keyboard/
snapshot layer and both front-ends never built.

**Status: the CPU core is complete and independently verified two ways.**
- **Tick/pin-level, not instruction-level** (mirroring the Python project's
  own `z80.h` wrapper, and for the same reason): `Cpu::tick()` advances
  exactly one T-state with real address/data/control pins, including the
  real overlapped-fetch pipeline — needed later for cycle-accurate ULA
  memory contention, which depends on genuine per-T-state bus visibility,
  not "this instruction took N T-states" as a lump sum.
- **Every opcode is generated, not hand-transcribed.**
  `scripts/generate_z80_dispatch.py` ports
  [floooh/chips](https://github.com/floooh/chips)' own `z80_gen.py` codegen
  algorithm (Python, already) to emit Rust instead of C, reading the same
  `vendor/chips/z80_desc.yml` instruction-cycle description that generates
  the real `z80.h` — literal fidelity to the authoritative source, and a
  generator that asserts no two opcode descriptors ever claim the same byte
  catches transposition bugs a human eyeballing an opcode table can miss.
  The `(IX+d)`/`(IY+d)` displacement-addressing sequence and the `DD CB
  d`/`FD CB d` double-prefix machine cycle are hand-written in `cpu.rs`
  instead (small, fixed sequences that mix bus-pin-issuing steps with plain
  idle ones, a shape the generator's per-machine-cycle templates don't
  cleanly express) — everything else is generated output, regenerated via
  `python scripts/generate_z80_dispatch.py` whenever the mapping changes.
- **Verified two independent ways:**
  1. A differential test harness (the `zx-core-conformance` crate, dev-only)
     links the real `vendor/chips/z80.h` via FFI and runs both cores in
     lockstep — fuzzed random instruction streams plus hand-written
     programs for anything unsafe to fuzz (control flow, the stack) —
     checked register-for-register after every instruction, and separately,
     pin-for-pin on every single T-state.
  2. The real [ZEXALL/ZEXDOC](https://github.com/agn453/ZEXALL) Z80
     exerciser (fetched at test time, not vendored — see
     `scripts/fetch_zexall.py`) runs against the core through a minimal
     CP/M BDOS shim. **Both zexdoc.z80 and its stricter sibling zexall.z80
     (which checks the undocumented flag bits fully instead of masking them
     out) pass in full: every test group in both suites reports `OK`, zero
     errors.** This checks agreement with known-correct Z80 semantics
     directly, independent of z80.h — the stronger of the two claims, since
     it would catch a bug the two cores happened to share.
- Covers the full documented instruction set plus the well-known
  undocumented forms: unprefixed, `ED`, `CB`, `DD`/`FD` (register
  substitution including `IXH`/`IXL`/`IYH`/`IYL`, and `(IX+d)`/`(IY+d)`
  addressing), and `DD CB d`/`FD CB d` (including the undocumented "also
  store to register" behavior). I/O opcodes and interrupt handling are
  deferred, same as the Python core's own priorities — see
  `rust-core/zx-core-conformance/tests/zexall.rs`'s doc comment for the
  full detail on what's verified and how.

```bash
cd rust-core
cargo test                                                            # fast suite, seconds
cargo test --test zexall zexdoc_reports_no_errors -- --ignored --nocapture  # full ZEXDOC run, ~18 min
cargo test --test zexall zexall_reports_no_errors -- --ignored --nocapture  # stricter sibling, ~18 min
```

## License

This project's own code has no license file yet. The vendored
`vendor/chips/z80.h` and `vendor/chips/z80_desc.yml` are
[floooh/chips](https://github.com/floooh/chips), zlib-licensed. No ROM image
is included or distributed — you must supply your own.
