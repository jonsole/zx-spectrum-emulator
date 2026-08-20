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

- **WSL** (Windows Subsystem for Linux) with a distro that has a C toolchain,
  or any Linux/macOS machine. There's no supported native-Windows build path:
  compiling the `cffi` extension needs a C compiler, and this project doesn't
  assume MSVC Build Tools are installed. Everything below is written for
  running inside WSL from a Windows checkout — if you're natively on
  Linux/macOS, skip the `wsl.exe -d ...` prefix.
- Python 3.10+ (a [`uv`](https://github.com/astral-sh/uv)-managed interpreter
  works well and sidesteps missing `pyconfig.h`/header issues some
  system Pythons have).
- A real 48K ZX Spectrum ROM image, 16384 bytes (16K) exactly. Not included —
  see [ROM](#rom).

## Setup

```bash
# from inside WSL, at the project root
uv venv .venv --python 3.12
source .venv/bin/activate
uv pip install -e ".[dev]"
```

This also compiles the native Z80 core extension as part of the install
(via the `cffi_modules` build hook in `setup.py`) — no separate build step
needed. Verified in a clean checkout: `pip install -e ".[dev]"` then
`pytest` passes all 42 tests with nothing else run in between.

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

This starts both servers on one asyncio event loop, sharing one `Engine`.

### Connecting an MCP client

Point any MCP client at `http://127.0.0.1:8000/sse` (SSE transport). For
Claude Code:

```bash
claude mcp add zx-spectrum --transport sse --url http://127.0.0.1:8000/sse
```

**Available tools:**

| Tool | Does |
|---|---|
| `load_rom(rom_base64)` | Load a 16K ROM image (base64) |
| `load_snapshot(sna_base64)` | Load a `.sna` snapshot (base64) |
| `reset()` | Reset the machine |
| `step()` | Execute exactly one Z80 instruction |
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
the emulator server inside WSL, and `launch.json`'s **"ZX Spectrum: Step
through ROM"** configuration points at it. Two one-time setup steps are
required first, on top of [Setup](#setup):

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

**What's actually been verified:** the complete
launch→disassemble→setInstructionBreakpoints→continue→stopped-at-breakpoint→inspect-registers
flow, run from a **native Windows** process against the DAP server running
inside WSL (confirming WSL2's localhost port-forwarding works for this
without extra configuration), using the exact Windows-style ROM path
`${workspaceFolder}` resolves to. That exercises everything VS Code itself
would do except VS Code's own UI rendering — the one remaining unconfirmed
step is actually pressing F5 in a live VS Code window.

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

42 tests across native-core smoke tests, the memory/ULA/keyboard/snapshot/
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
`launch.json`) is included and the full debug flow has been verified against
the DAP server from a real native-Windows process — the one remaining
unconfirmed step is pressing F5 in an actual VS Code window, since that
requires the one-time per-machine debugger-type registration described
there (deliberately not part of this repo — it's local setup, not project
code).

**Known limitation, not yet fixed:** if a client starts `run()` and
disconnects without ever `pause()`-ing (e.g. a crashed or killed client
mid-session), the engine's single actor loop stays stuck running that
program forever, blocking every other client too — there's currently no
auto-pause on disconnect or run-time cap. Fine for controlled testing;
worth fixing before this is used for anything more exposed.

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
