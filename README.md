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

- **One process, one live emulator, two front-ends.** `engine/actor.py` owns
  the single `Spectrum48K` instance and is the *only* thing allowed to touch
  it. The MCP server and the DAP server never call the core directly — they
  submit a `Command` to the engine's `asyncio.Queue` and await a per-request
  future for the reply. Because everything runs on one event loop, this needs
  no locks, but it does guarantee both sides always see consistent state.
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
passes all 49 tests with nothing else run in between.

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
  --dap-host 127.0.0.1 --dap-port 4711
```

(`.venv-win\Scripts\python.exe` natively, or the activated WSL venv's
`python` — see [Setup](#setup).) This starts both servers on one asyncio
event loop, sharing one `Engine`.

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

### Connecting VS Code (DAP)

The repo's `.vscode/` folder is a ready-to-use workspace: `tasks.json` starts
the emulator server (natively, via `.venv-win`), and `launch.json`'s **"ZX
Spectrum: Step through ROM"** configuration points at it. Two one-time setup
steps are required first, on top of [Setup](#setup):

1. **A real 48K ROM** — see [ROM](#rom) above. `launch.json` expects it at
   `roms/48.rom`.
2. **Register the `zxspectrum` debugger type.** VS Code requires
   `launch.json`'s `type` to match a registered `contributes.debuggers`
   entry before it will even attempt a `debugServer` connection — this is
   true even though no actual adapter code is needed, since `debugServer`
   overrides which process VS Code talks to (see the [extension
   guide](https://code.visualstudio.com/api/extension-guides/debugger-extension)).
   Create a minimal declarative extension — no code required — at
   `<VS Code extensions folder>/<publisher>.zxspectrum-debug-0.0.1/package.json`:

   ```json
   {
     "name": "zxspectrum-debug",
     "publisher": "<your-name>",
     "version": "0.0.1",
     "engines": { "vscode": "^1.85.0" },
     "categories": ["Debuggers"],
     "contributes": {
       "debuggers": [{ "type": "zxspectrum", "label": "ZX Spectrum" }]
     }
   }
   ```

   Then reload VS Code ("Developer: Reload Window") to pick it up.

With both in place, open the Run and Debug view and launch **"ZX Spectrum:
Step through ROM"**. The `preLaunchTask` starts the server automatically
(watch its output in the dedicated terminal panel) and waits for it to be
ready before connecting.

There's no source file in v1 (no assembler listing/map), so this drives VS
Code's **Disassembly View** rather than a source view: breakpoints are
instruction breakpoints set from there, stepping is `next`
(one Z80 instruction), and the single synthetic stack frame is labeled with
the disassembled instruction at PC. Supported requests: `initialize`,
`launch`/`attach`, `configurationDone`, `setInstructionBreakpoints`,
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

One current UI rough edge, not fixable from the adapter side: VS Code
doesn't reliably auto-populate the Registers panel or auto-focus the
Disassembly View on every stop for a source**less** frame (there's no
listing/map file in v1) — clicking the Call Stack entry once after a stop
refreshes it. Tracked upstream as
[microsoft/vscode#131253](https://github.com/microsoft/vscode/issues/131253).

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

49 tests across native-core smoke tests, the memory/ULA/keyboard/snapshot/
machine layer, the disassembler (including a full pass over a real ROM's
16384 bytes with zero decode errors), the engine actor's concurrency
guarantees, and both front-ends driven over real sockets (an actual
`asyncio` TCP connection for DAP, a real `mcp` SSE client for MCP).

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
      snapshot.py                 # .sna loader
      disassembler.py               # full documented Z80 disassembler
      machine.py                     # Spectrum48K: wires it all together
    engine/
      actor.py                # the shared live instance (asyncio actor)
      commands.py               # Command/Event dataclasses
    server/
      mcp_server.py            # MCP tools
      dap.py                     # DAP TCP server
      main.py                      # entrypoint: starts engine + both servers
  roms/                        # gitignored; drop your 48K ROM here
  tests/
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

**In progress:** source-level debugging against a real, commented
disassembly (not just raw instructions) — validated the pipeline
(`skoolkid/rom`'s SkoolKit source → `skool2asm.py` → `sjasmplus` assembly,
reproducing the ROM **byte-for-byte**, with `--sld` giving a proper
address↔source-line map) but haven't wired it into `dap.py`/the MCP surface
yet. The copyrighted disassembly source is fetched locally, never committed
(same treatment as the ROM itself).

Stretch goals, not blocking normal use:
- `.z80` snapshot format (versioned, compressed — `.sna` works today)
- Tape loading (`.tap`/`.tzx`/`.pzx`)
- Beeper audio synthesis (port writes are tracked, not turned into sound)
- An optional live viewer (today, screenshots are on-demand via `get_screen`)

## License

This project's own code has no license file yet. The vendored
`vendor/chips/z80.h` is [floooh/chips](https://github.com/floooh/chips),
zlib-licensed. No ROM image is included or distributed — you must supply
your own.
