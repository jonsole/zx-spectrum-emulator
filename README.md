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
- **Tape**: `.tap`, `.tzx`, `.wav` and `.csw` loading in the C++ core, at pulse
  level through the EAR line, with an optional fast-load trap on the ROM's
  LD-BYTES. The two audio formats are recordings, decoded back into pulses by a
  Schmitt trigger — see [Tape](docs/tape.md).
- **Disassembler**: the full documented Z80 instruction set (unprefixed, `CB`,
  `ED`, `DD`, `FD`, and `DD CB d`/`FD CB d`), including the well-known
  undocumented `IXH`/`IXL`/`IYH`/`IYL` register forms.

**Not emulated (yet):** 128K/+2 banking, the AY sound chip, memory contention /
cycle-exact ULA timing, and tape *saving*. See
[Status & roadmap](docs/status.md).

Beeper audio (port `0xFE` bits 4 and 3) *is* emulated by the C++ core — see
[Audio](docs/audio.md).

## Why this architecture

- **One process, one live emulator, four front-ends.** `cpp-core/src/engine.h`
  owns the single `Spectrum48K` instance and is the *only* thing allowed to
  touch it. The MCP and DAP servers never call the core directly — they queue
  a command and wait on a future for the reply; the
  [screen stream](docs/vscode-debugging.md#live-screen-viewer) and the
  [audio stream](docs/audio.md) read it the same way, just repeatedly. The machine runs on its own thread and the
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
  watchpoints and the [cycle-by-cycle bus trace](docs/tracing.md)
  straightforward — the trace is simply that bus, recorded.
- **Shared state, live.** Because both front-ends drive the same `Engine`,
  you can set a breakpoint in VS Code, have an MCP client `run()` past other
  breakpoints and hit yours, and watch VS Code's UI update on its own — no
  polling, no manual sync. This is the actual point of the project.

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
[screen stream](docs/vscode-debugging.md#live-screen-viewer) and the
[audio stream](docs/audio.md) — sharing the one live machine. Normally you don't run this by hand: the VS Code
`preLaunchTask` starts it (see [Connecting VS Code](docs/vscode-debugging.md)).

## Documentation

The detail lives in [docs/](docs/), one file per topic:

| Document | What's in it |
|---|---|
| [Connecting an MCP client](docs/mcp.md) | Pointing an agent at the running server, and the full tool list |
| [Debugging in VS Code](docs/vscode-debugging.md) | The DAP front end: launch configs, live screen viewer, call stack, source-level debugging of the ROM and of your own programs |
| [Game disassemblies](https://github.com/jonsole/zx-spectrum-disassemblies) | Manic Miner, Fairlight and Atic Atac &mdash; their own repository, checked out here as `game-disassemblies/` |
| [Cycle-by-cycle bus tracing](docs/tracing.md) | Recording the bus half-clock by half-clock, the trace viewer, and how it compares against real silicon |
| [Audio](docs/audio.md) | Beeper emulation, sound as the master clock, backends and latency, stream format |
| [Tape](docs/tape.md) | Loading `.tap`/`.tzx`/`.wav`/`.csw`, the fast-load trap, and the loading sound |
| [Testing and performance](docs/testing-and-performance.md) | The test suites, ZEXALL/ZEXDOC, and measured throughput |
| [Project layout](docs/project-layout.md) | What lives where in the tree |
| [Status & roadmap](docs/status.md) | What is done, what is next |
| [Rust core](docs/rust-core.md) | The deprecated from-scratch Rust implementation, kept for history |

Installing from scratch is a separate, checkable procedure: **[INSTALL.md](INSTALL.md)**.

## License

This project's own code has no license file yet. The vendored
`vendor/chips/z80.h` and `vendor/chips/z80_desc.yml` are
[floooh/chips](https://github.com/floooh/chips), zlib-licensed. No ROM image
is included or distributed — you must supply your own.
