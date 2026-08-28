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
  (breakpoints,      │   Engine (asyncio actor)     │◀──MCP─── Claude / any
   stepping,         │   owns the ONE live           │           MCP client
   registers)        │   Spectrum48K instance        │
                     └─────────────────────────────┘
                                   │
                     command queue + event fan-out
                     (both sides see every state
                      change, however it happened)
```

## What's actually emulated

- **CPU**: full Z80 core, via a vendored, cycle-stepped, pin-level C core
  ([floooh/chips](https://github.com/floooh/chips) `z80.h`) wrapped with
  [`cffi`](https://cffi.readthedocs.io/).
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

- **One process, one live emulator, three front-ends.** `engine/actor.py`
  owns the single `Spectrum48K` instance and is the *only* thing allowed to
  touch it. The MCP server and the DAP server never call the core directly —
  they submit a `Command` to the engine's `asyncio.Queue` and await a
  per-request future for the reply; the [screen stream](#live-screen-viewer)
  reads it the same way, just repeatedly. Because everything runs on one
  event loop, this needs no locks, but it does guarantee every front-end
  always sees consistent state.
- **Events, not polling.** The engine also fans out state-change events
  (`Stopped`, `Continued`) to every subscriber. If you tell it to `run` or
  `step` over MCP, your VS Code session gets an unsolicited `stopped` DAP
  event even though VS Code didn't ask for the change — and vice versa when
  you set a breakpoint by clicking the gutter.
- **The Z80 core is pin-level and cycle-stepped, not instruction-level.**
  `z80_tick()` is called once per T-state with a 64-bit pin mask encoding the
  address/data/control lines; every memory and I/O access passes through
  Python code you control. That's what makes T-state-accurate stepping and
  memory/IO watchpoints straightforward, at some cost to raw execution speed
  (see [Performance](#performance) below).

## Requirements

- A C compiler, to build the `cffi` extension. Either:
  - **Native Windows**: [MSVC Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/)
    (the "Desktop development with C++" workload). This is the primary,
    recommended path on Windows — no WSL needed, and it's noticeably faster
    (the full test suite runs in ~2s natively vs ~7s under WSL, since every
    filesystem access avoids the WSL/DrvFs boundary).
  - **WSL** (Windows Subsystem for Linux) or any Linux/macOS machine, if you'd
    rather not install MSVC. Still fully supported — see
    [WSL / Linux / macOS](#wsl--linux--macos) below.
- Python 3.10+.
- A real 48K ZX Spectrum ROM image, 16384 bytes (16K) exactly. Not included —
  see [ROM](#rom).

## Setup

**Native Windows** (with MSVC Build Tools installed):

```powershell
python -m venv .venv-win
.\.venv-win\Scripts\pip.exe install -e ".[dev]"
```

The `pip install` needs to run inside the MSVC developer environment so
`cl.exe` is on `PATH` for the `cffi` build step — either run it from a
"Developer PowerShell for VS" / "x64 Native Tools Command Prompt", or from a
plain shell via:

```powershell
cmd /c '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" && .venv-win\Scripts\pip.exe install -e ".[dev]"'
```

(adjust the path if Build Tools installed somewhere else, or if using the
full Visual Studio IDE rather than just Build Tools).

This also compiles the native Z80 core extension as part of the install (via
the `cffi_modules` build hook in `setup.py`) — no separate build step needed.
Verified in a clean checkout: the install command above, then `pytest`,
passes all 78 tests with nothing else run in between.

### WSL / Linux / macOS

```bash
# from inside WSL, at the project root
uv venv .venv --python 3.12
source .venv/bin/activate
uv pip install -e ".[dev]"
```

Same `cffi_modules` build-on-install behavior as above. On WSL specifically,
system Python can be missing `pyconfig.h`/dev headers; a
[`uv`](https://github.com/astral-sh/uv)-managed interpreter (`uv venv
--python 3.12`, as above) sidesteps that.

## ROM

The emulator needs a genuine 48K Spectrum ROM to boot into BASIC — it isn't
included (it's Sinclair/Amstrad-copyrighted). Drop a 16384-byte ROM image at
`roms/48.rom` (the whole `roms/` directory except `.gitkeep` is gitignored,
so it never gets committed). You can verify a candidate file is the real
thing by checking its first byte is `0xF3` (`DI`, the first instruction of
every genuine Spectrum ROM).

## Running

```bash
python -m zxspectrum.server.main \
  --mcp-host 127.0.0.1 --mcp-port 8000 \
  --dap-host 127.0.0.1 --dap-port 4711 \
  --screen-host 127.0.0.1 --screen-port 8500
```

(`.venv-win\Scripts\python.exe` natively, or the activated WSL venv's
`python` — see [Setup](#setup).) This starts all three servers — MCP, DAP,
and the [screen stream](#live-screen-viewer) — on one asyncio event loop,
sharing one `Engine`.

### Connecting an MCP client

Point any MCP client at `http://127.0.0.1:8000/sse` (SSE transport).

The repo includes `.mcp.json`, so opening this workspace in Claude Code
picks up the server automatically (you'll be prompted to approve it once).
To add it manually instead (e.g. a different client, or without opening
the workspace), for Claude Code:

```bash
claude mcp add zx-spectrum --transport sse --url http://127.0.0.1:8000/sse
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

The repo's `.vscode/` folder is a ready-to-use workspace: `tasks.json` starts
the emulator server (natively, via `.venv-win`), and `launch.json`'s **"ZX
Spectrum: Step through ROM"** configuration points at it. Two one-time setup
steps are required first, on top of [Setup](#setup):

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
as the connection stays open) — see `zxspectrum/server/screen_stream.py`.

Frames are read via `engine.machine.render_screen()` directly rather than
through the engine's normal command queue — a `run()` in progress occupies
the actor loop for its entire duration, so a queued read would sit unserved
(and the view would visibly freeze) until it stopped. Same queue-bypass
pattern DAP's own memory reads already use, for the same reason.

#### Call stack

`stackTrace` shows a real, multiple-frame call stack, not just the current
PC: `Spectrum48K` tracks `CALL`/`RST` and their matching `RET` as they
execute (`machine.py`'s `call_stack`), so stepping into a routine adds a
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

Run it once (needs `pip install skoolkit`, plus `sjasmplus` on PATH — see the
script's `--help` for where to get a build per platform):

```sh
.venv-win\Scripts\python.exe scripts\build_rom_source.py   # native Windows
.venv/bin/python scripts/build_rom_source.py                 # WSL/Linux/macOS
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
  "preLaunchTask": "zxspectrum.start-server"
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
`sjasmplus`, and wraps the result into a `.sna` (`core/snapshot.py`'s
`write_sna()`, the write-side counterpart of the `.sna` loader):

```sh
.venv-win\Scripts\python.exe scripts\build_manicminer.py   # native Windows
.venv/bin/python scripts/build_manicminer.py                 # WSL/Linux/macOS
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
.venv-win\Scripts\python.exe scriptsuild_fairlight.py   # native Windows
.venv/bin/python scripts/build_fairlight.py                 # WSL/Linux/macOS
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
**"ZX Spectrum (C++ core): Fairlight"** — its `preLaunchTask` reassembles
before starting the server, so editing the fetched `.asm` and relaunching
picks the change up.

#### Example: Atic Atac

Unlike the other two, this one has no published disassembly to fetch:
`scripts/build_aticatac.py` produces it from a `.tap` of the 1983 Ultimate
game itself.

```sh
.venv-win\Scripts\python.exe scripts\build_aticatac.py --tape "Atic Atac.tap"
.venv/bin/python scripts/build_aticatac.py --tape "Atic Atac.tap"
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

### Code/data coverage, for disassembly

The Atic Atac build above needs a map of which addresses are code and which
are data, and gets it by replaying the game in SkoolKit's own simulator. The
emulator can now produce that map itself, from a real run — including one you
drove by hand, or an agent drove over MCP while looking at the screen.

Recording is a flag per address, set straight off the bus: an opcode fetch
(`M1` with `MREQ|RD`) marks code, any other read marks data, a write marks a
variable. Nothing is inferred, so there are no false positives — a byte marked
code *was executed*.

```
start_coverage                       # clears the map and starts recording
run / step / play the game
coverage_status                      # instructions, code, read, written, untouched
save_coverage  path=game.map         # 65536 bytes, one flag byte per address
```

Then hand the file to SkoolKit, which reads bit 0 of each byte as "an
instruction started here":

```sh
sna2ctl.py -m game.map -s 0x6000 -e 0xD600 game.z80 > game.ctl
sna2skool.py -c game.ctl game.z80 > game.skool
```

**Start recording after the program has loaded, not before.** A pulse-level
tape load has the ROM's loader write every byte of the game, so a map that
spans the load describes the loader as much as the program. `start_coverage`
clears the map as it starts, which is what makes "load, then start" the
natural order.

What it buys, on eight bytes of sprite data sitting between two routines:

```
; without a map                     ; with the emulator's map
c32774 LD A,0                       b32774 DEFB 62,0,205,91,33,255,0,201
 32776 CALL 8539
 32779 RST 56
 32780 NOP
 32781 RET
```

A static pass has to guess, and graphics data is dense in plausible opcodes,
so it invents a routine. The map says those bytes were only ever read, never
fetched, and they come out as `DEFB`s.

The map is necessarily incomplete — it only knows what actually ran, so a
session that never leaves the title screen classifies most of the image as
untouched. That is the safe direction to be wrong in: unreached code becomes
`DEFB`s, which still reassemble correctly, rather than invented instructions.
Watch `coverage_status` as you play; when the counts stop climbing, more
playing is not buying more map.

Two flags go beyond what `sna2ctl -m` can express, and are recorded ready for
a control-file generator that can use them: bit 1 marks the *second* opcode
byte of a `CB`/`ED`/`DD`/`FD`-prefixed instruction (code, but not a place a
disassembler may start), and bit 3 marks bytes that were written — the
difference between a constant table (SkoolKit's `b`) and a variable (`g`).

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
the actual point of the project; see `tests/test_dap.py` and
`tests/test_engine.py` for it exercised directly.

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

```bash
python -m pytest tests/ -v
```

78 tests across native-core smoke tests, the memory/ULA/keyboard/snapshot/
machine layer, the disassembler (including a full pass over a real ROM's
16384 bytes with zero decode errors), the ROM SLD parser (`rom_source.py`),
the engine actor's concurrency guarantees, and both front-ends driven over
real sockets (an actual `asyncio` TCP connection for DAP, a real `mcp` SSE
client for MCP).

## Performance

Because every T-state crosses the Python↔native-C boundary (by design — see
[Why this architecture](#why-this-architecture)), bulk execution runs at
roughly **0.5× real hardware speed** (~1.7 MHz effective vs. 3.5MHz real).
This is a deliberate tradeoff: the design target is debugger-driven
single-stepping, not real-time gameplay, and a faster bulk-tick path would
require duplicating the bus-servicing logic outside the single code path
that per-T-state watchpoints depend on.

## Project layout

```
zx-spectrum-emulator/
  vendor/chips/z80.h          # vendored floooh/chips Z80 core (zlib license)
  zxspectrum/
    _native/                  # cffi shim + build script wrapping z80.h
    core/
      z80.py                  # pythonic wrapper over the native core
      memory.py                # 48K map (16K ROM + 48K RAM)
      ula.py                    # screen decode, border, frame interrupt
      keyboard.py                # 8x5 matrix, port 0xFE
      snapshot.py                 # .sna loader + writer
      disassembler.py               # full documented Z80 disassembler
      rom_source.py                   # ROM SLD parser (source-level debug)
      machine.py                        # Spectrum48K: wires it all together
    engine/
      actor.py                # the shared live instance (asyncio actor)
      commands.py               # Command/Event dataclasses
    server/
      mcp_server.py            # MCP tools
      dap.py                     # DAP TCP server
      screen_stream.py             # screen-frame TCP stream
      main.py                        # entrypoint: starts engine + all three servers
  scripts/
    build_rom_source.py         # builds rom_disassembly/ (see below)
    build_manicminer.py           # builds game_disassembly/manicminer/ (see below)
    build_aticatac.py             # builds game_disassembly/aticatac/ from a .tap (see below)
  examples/
    hello_rom_call/              # tiny original demo, committed
  tools/
    trace_viewer.html          # standalone viewer for cycle-by-cycle bus traces
  vscode-extension/            # debugger type registration + live screen viewer
  roms/                        # gitignored; drop your 48K ROM here
  rom_disassembly/             # gitignored; scripts/build_rom_source.py output
  game_disassembly/            # gitignored; scripts/build_manicminer.py output
  tests/
  rust-core/                  # separate Rust Z80 core -- see below, own section
```

## Status & roadmap

The full core build order is complete and verified end-to-end (native core →
memory/ULA/keyboard/snapshot/machine → disassembler → async engine → MCP
server → DAP server), including a live concurrent-session check: a real DAP
client and a real MCP client connected simultaneously, each observing the
other's changes as unsolicited events.

A [VS Code workspace](#connecting-vs-code-dap) (`.vscode/tasks.json` +
`launch.json`) is included and confirmed working end to end in a real,
interactive VS Code session (see the note there about one VS Code UI rough
edge that isn't fixable from the adapter side).

Native Windows builds are fully supported (`.venv-win`, MSVC Build Tools) —
this is now the primary path on Windows; WSL/Linux/macOS remain supported
alternatives. `DapConnection`'s incoming-path handling adapts automatically
to whichever platform the server process is actually running on.

**Known limitation, not yet fixed:** if a client starts `run()` and
disconnects without ever `pause()`-ing (e.g. a crashed or killed client
mid-session), the engine's single actor loop stays stuck running that
program forever, blocking every other client too — there's currently no
auto-pause on disconnect or run-time cap. Fine for controlled testing;
worth fixing before this is used for anything more exposed.

Source-level debugging against a real, commented disassembly (not just raw
instructions) is done, for both
[the ROM](#source-level-debugging-of-the-rom) and
[your own assembled programs](#source-level-debugging-of-your-own-program):
`scripts/build_rom_source.py` reproduces the ROM **byte-for-byte** via
`skool2asm.py` + `sjasmplus --sld`; `load_debug_info` attaches the same kind
of map for any `sjasmplus`-assembled program, layered on top of (not
replacing) the ROM's own, so a call from your program into a ROM routine
still resolves. `dap.py` uses whichever map applies for `source`-annotated
stack frames and source-line breakpoints; `resolve_symbol`/`resolve_address`
expose the same lookup over MCP. Verified end-to-end (build → `stackTrace` →
`setBreakpoints` → hit → correct PC, and separately, own-program address →
ROM address → correct source switches for both).

A [live screen viewer](#live-screen-viewer) is done too: a third server port
(`screen_stream.py`) streams the display as a continuous sequence of PNG
frames to any client, and the `vscode-extension/` extension bridges that into
a webview panel — the project's first extension with real code (previously
just a declarative debugger-type stub). Explicitly designed to keep working
standalone, independent of VS Code: the streaming port has no VS-Code-specific
code in it, same as DAP/MCP.

Stretch goals, not blocking normal use:
- `.z80` snapshot format (versioned, compressed — `.sna` works today)
- Tape loading — **done** in the C++ core for `.tap`/`.tzx` (see [Tape](#tape));
  `.pzx` and tape *saving* are still open, as are the `.tzx` sampled-data block
  types (`0x15` direct recording, `0x18` CSW, `0x19` generalized)
- Beeper audio synthesis — **done** in the C++ core (see [Audio](#audio));
  the Python and Rust cores still only track the port writes

## Rust core (`rust-core/`)

A from-scratch, hand-written Z80 interpreter in Rust — not an FFI wrapper
around `z80.h` — being built alongside the Python project above, for two
reasons: a genuine path to WebAssembly (a browser-playable target has no
good story via the Python/`cffi` stack), and a deliberate Rust-learning
exercise. The eventual goal is for `rust-core/` to grow into a full
replacement for the Python DAP/MCP/screen-stream server above, reusing one
core for both a native server and a wasm browser player; today it's
CPU-only, with the memory/ULA/keyboard/snapshot layer and both front-ends
still ahead of it.

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
