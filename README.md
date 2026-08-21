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
- **Disassembler**: the full documented Z80 instruction set (unprefixed, `CB`,
  `ED`, `DD`, `FD`, and `DD CB d`/`FD CB d`), including the well-known
  undocumented `IXH`/`IXL`/`IYH`/`IYL` register forms.

**Not emulated (yet):** 128K/+2 banking, the AY sound chip, memory contention /
cycle-exact ULA timing, beeper audio output, and tape loading. See
[Status & roadmap](#status--roadmap).

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

### Shared state, live

Because both front-ends drive the same `Engine`, you can set a breakpoint in
VS Code, have an MCP client `run()` past other breakpoints and hit yours, and
watch VS Code's UI update on its own — no polling, no manual sync. This is
the actual point of the project; see `tests/test_dap.py` and
`tests/test_engine.py` for it exercised directly.

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
  examples/
    hello_rom_call/              # tiny original demo, committed
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
- Tape loading (`.tap`/`.tzx`/`.pzx`)
- Beeper audio synthesis (port writes are tracked, not turned into sound)

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
     CP/M BDOS shim. **zexdoc.z80 passes in full: every test group reports
     `OK`, zero errors, across the entire suite.** This checks agreement
     with known-correct Z80 semantics directly, independent of z80.h — the
     stronger of the two claims, since it would catch a bug the two cores
     happened to share.
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
cargo test                                                # fast suite, seconds
cargo test --test zexall -- --ignored --nocapture         # full ZEXDOC run, ~18 min
```

## License

This project's own code has no license file yet. The vendored
`vendor/chips/z80.h` and `vendor/chips/z80_desc.yml` are
[floooh/chips](https://github.com/floooh/chips), zlib-licensed. No ROM image
is included or distributed — you must supply your own.
