# AGENTS.md

Guidance for coding agents working in this repository. For what the project is
and how to use it, start with [README.md](README.md) and [docs/](docs/); this
file is about how to work on it without tripping over the things that have
tripped people before.

## The short version

- **`cpp-core/` is the emulator.** `zxspectrum/` (Python) and the pytest suite
  in `tests/` are deprecated -- don't build, fix or verify against them. The Python helpers in `scripts/` are still current.
- **Someone may be using the emulator while you work.** Their `zx_server.exe`
  holds the default ports and locks its own binary. Build and test beside it,
  not over it -- see [A live emulator](#a-live-emulator).
- **Other sessions may be editing the same working tree.** Never `git stash`,
  `git checkout -- <file>`, `git reset --hard` or `git clean`. Stage the files
  you changed by name; leave everything else as you found it.
- **Windows, PowerShell, MSVC.** `cpp-core/build.ps1` finds the Visual Studio
  Build Tools and imports their environment itself. Python is the repo's venv,
  `.venv-win\Scripts\python.exe`, not whatever `python` is on PATH.

## Build and test

```powershell
cd cpp-core
.\build.ps1                      # Debug, into build\Debug: the server, the tests and the tools
.\build.ps1 -Release             # RelWithDebInfo, into build\RelWithDebInfo
.\build.ps1 -Test                # build, then the fast CTest suite (label "slow" excluded)
.\build.ps1 -Release -Slow       # ZEXALL/ZEXDOC only: many minutes, Release or it takes hours
.\build.ps1 -Release -Target zx_server     # the server alone -- what VS Code's launch builds
.\build.ps1 -Target zx_tests               # the CTest suite alone; zx_tools for the rest
.\build.ps1 -Target profile_tests          # one target
.\build.ps1 -NoTests                       # a build that is only the server (ZX_BUILD_TESTS=OFF)
.\build.ps1 -Release -BuildDir <dir>       # somewhere else entirely (see below)
```

Run the whole fast suite (`-Test`) before calling a core change done; it takes
about a minute and a half. Each test is a plain executable built from
`cpp-core/tests/<name>.cpp` with the three-macro harness in
`tests/test_main.h` (`TEST`, `CHECK`, `CHECK_EQ`), registered in
`cpp-core/tests/CMakeLists.txt` with `zx_add_test`. The top-level
`cpp-core/CMakeLists.txt` is the core and the server only; everything in
`tests/` -- the suite, the benchmarks and the diagnostics -- hangs off the
`ZX_BUILD_TESTS` option, and every executable still lands at the top of the
build directory. A new tool goes in `tests/CMakeLists.txt` and into the
`zx_tests` or `zx_tools` group there. Tests that need the real ROM find
it through `ZX_PROJECT_ROOT` and skip themselves when `roms/48.rom` is absent.

Expected values in tests are worked out, not captured: costs from the Z80's
documented timings, addresses from the program under test. A number copied
from the code's own output can only confirm the code agrees with itself.

The VS Code extension has no build step and no dependencies. Its logic that
does not need VS Code lives in files with no `vscode` import, tested from plain
Node:

```powershell
node vscode-extension\tests\asm_index_test.js
node vscode-extension\tests\profile_model_test.js
```

There is one a topic; `vscode-extension\tests\` is the list.

The Filmation designer -- the room, templates and graphic-map editors -- is a
second extension, `examples\filmation\vscode\`, independent of the emulator's
and installed beside it the same way (see `examples\filmation\room-designer.md`).
Its tests are in its own `tests\`, run the same way. Three of them --
`room_page_test.js`, `templates_page_test.js` and `graphic_map_page_test.js` --
assemble a webview page the way its host does and run it against a fake DOM,
which is worth knowing before changing one: those pages are built by string
replacement, so a mistake is a syntax error in a file that exists only at
runtime. Its JSON schemas are checked from Python instead, because
`jsonschema` is in the venv:
`.venv-win\Scripts\python.exe examples\filmation\vscode\tests\schemas_test.py`.

No `node` on PATH? VS Code's own works:
`$env:ELECTRON_RUN_AS_NODE=1; & "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe" <script>`.
The extension is installed as a symlink to `vscode-extension/`, so a change
takes effect on **Developer: Reload Window**.

Throughput is `cpp-core/build/RelWithDebInfo/bench_machine.exe` (build it with
`-Release -Target bench_machine`). Only a Release build's numbers mean
anything, and they vary a few percent run to run -- run it twice.

## A live emulator

`zx_server.exe` serves DAP on **4711**, MCP on **8000**, the screen stream on
**8500** and audio on **8501**. VS Code's launch configurations stop every
running server, rebuild `build\RelWithDebInfo` and start a fresh one on those
ports; the MCP launcher in `tools/zxserver/` adopts whatever is already
listening.

- **Building while it runs.** Windows won't relink a running `.exe` (LNK1168).
  Build to a throwaway directory with `-BuildDir` rather than stopping someone's
  session to free the default one.
- **Checking a change live.** Use the `zx-live-verify` skill
  (`.claude/skills/zx-live-verify/SKILL.md`) or the `zx-verifier` agent: a second
  instance from a throwaway build, on ports **14711 / 18000 / 18500**, with
  `--no-audio`, driven through its bundled DAP and MCP clients, and killed by PID
  afterwards. Its gotchas section is real history -- read it before driving a
  server by hand.
- **Test through MCP, don't hand over.** When checking a change to a program
  (filmation, say), build it, load it, and drive the server yourself over MCP
  -- run it, press keys, take screenshots -- rather than loading it and asking
  someone else to try it.
- **Starting one for someone to use** means the default ports, with
  `--audio-device --no-audio` as `.vscode/tasks.json` does, so the screen panel
  and the sound card both work. Say what you stopped to get the ports.

## Where things are

[docs/project-layout.md](docs/project-layout.md) has the tree. The parts most
changes touch:

| Path | What |
|---|---|
| `cpp-core/src/z80.cpp`, `alu.cpp` | The CPU: clocked per half-T-state, pin-level |
| `cpp-core/src/spectrum.cpp` | The machine: bus decode, `step_instruction`, the tracked call stack |
| `cpp-core/src/engine.cpp` | The one live machine, its thread and command queue |
| `cpp-core/src/dap.cpp`, `mcp_server.cpp` | The two protocol front ends; MCP tools are declared in `mcp_server.cpp` only |
| `cpp-core/src/rom_source.cpp` | SLD debug info: address to source line, symbols |
| `cpp-core/src/profile.cpp`, `profile_report.cpp` | The execution profiler and its report |
| `cpp-core/src/rewind.cpp` | Stepping backwards: checkpoints, the input log, replay |
| `vscode-extension/` | Debugger registration, panels, profiler view, Z80 language support |
| `examples/filmation/` | A real multi-file sjasmplus program, built by its `knightlore/build.py` |
| `examples/filmation/vscode/` | The Filmation designer: a second VS Code extension, independent of the emulator's -- room, templates and graphic-map editors |
| `game-disassemblies/` | Submodule: Manic Miner, Fairlight, Atic Atac |
| `examples/zx-tape-loader/` | Submodule: a fast custom tape loader and the Python that renders its tapes to WAV |
| `vscode-extension/tape_*`, `screen_*` | The tape designer: editors for `*.tape.json` and `*.screen.json`, built by `scripts/build_tape.py` (docs/tape-designer.md) |

ROM images are not in the repository (`roms/` is gitignored); tests and
examples that need one skip or say so. `sjasmplus` is at
`tools/sjasmplus/sjasmplus.exe`.

## Things that bite

- **Everything goes through the Engine.** Nothing outside `engine.cpp` touches
  the `Spectrum`. A request is a queued job; jobs marked `during_run` are
  serviced at a run's yields (a couple of milliseconds apart), and run and the
  step family are not. Pause, keys, the screen, tracing and the tape transport
  bypass the queue on purpose -- `engine.h`'s header comment says why each one.
- **The overlapped fetch.** An instruction's last half-clock begins the next
  one's fetch, so `Z80::registers()` reports `pc - 1` -- except while halted,
  when it reports the address after the `HALT`. An interrupt is accepted at the
  end of an instruction and its acknowledge runs inside that same step.
- **SP is not only a stack pointer.** Spectrum code borrows it as a data
  pointer (`LD SP,HL`, then `PUSH` to fill or `POP` to walk memory). Anything
  deciding when a call has ended must look at the return address being read off
  or written over, not at SP moving -- see the rule in `profile.h`.
- **An SLD symbol can be an `EQU`** whose value happens to equal a code address
  (filmation's `KEY_ROOMS` sits inside `turn_pace`). `RomSource::equates` tells
  them apart; use `code_label_at`, not `symbol_at`, when you mean a place in the
  code.
- **Programs share label names.** The workspace holds the ROM disassembly,
  filmation and several game disassemblies, and nothing stops two of them
  naming a routine alike. Resolve against the loaded program's own debug info
  first, then the ROM's -- `Sources::active()` is in that order -- and in the
  editor, against the files the current one is `INCLUDE`d with.
- **`service_bus` is where the machine's accesses are seen.** The ULA's
  screen-write map, rewind's search and watchpoints all hook the same read and
  write in `spectrum.cpp`, and they are on the hottest path there is: a new
  check belongs behind a pointer that is null when the feature is off, the way
  `watch_` is. Debugger pokes go through `write_memory` instead and
  deliberately trip none of it.
- **Everything from outside the machine is a rewind input.** With rewind
  compiled in (the default), keys, pokes, register edits, tape commands and raw
  T-state clocking reach the `Spectrum` through `History::record` in the
  Engine, so a replay applies exactly what the live machine had. A new way of
  feeding the machine that bypasses it makes replays diverge -- and
  `rewind_tests`' determinism test is what notices. Anything that replaces the
  machine instead (a reset, a load) calls `restart_history`. A new member of a
  machine part needs adding to that part's `State` too. Check changes build with
  `build.ps1 -NoRewind -Target zx_server` as well.
- **Not emulated yet:** ULA memory contention, the +2A/+3, tape saving. Don't
  describe timing as contention-accurate.

## Style

**C++.** C++17, warnings as errors (`/W4 /WX`). Match the file you are in:
plain structs, `for` loops and `if`/`else` rather than clever templates or
algorithm chains; `///` on declarations saying what a thing is for; `//` prose
inside functions saying *why*, especially where the obvious alternative would
be wrong. Comments explain the reasoning and the history that forced it, in
full sentences -- read a few in `spectrum.cpp` or `engine.h` before writing new
ones. Constants get names and a comment on where the number comes from.

**JavaScript** (the extension). CommonJS, no build step, no npm dependencies.
Keep logic that can be tested without VS Code out of the files that import
`vscode`, and test it from Node.

**Docs.** A new facility isn't finished until [docs/](docs/) describes it --
one file per topic, linked from the README's table. The MCP tool list lives in
[docs/mcp.md](docs/mcp.md); the VS Code side in
[docs/vscode-debugging.md](docs/vscode-debugging.md). Say what is not done as
plainly as what is.

## Commits

Commit only when asked. The history is a linear `master`. A subject is one
sentence saying what the change does, in the project's voice ("Count idle time
apart, rank the worst frames, and follow calls through a borrowed stack
pointer"); the body says what changed and why, what it was checked against, and
anything left out. Add files by name -- the working tree often holds other
people's uncommitted work -- and say in your summary which changes you left
uncommitted.
