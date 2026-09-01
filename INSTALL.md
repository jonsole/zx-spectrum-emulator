# Installing the ZX Spectrum emulator under VS Code

A step-by-step install procedure, written to be executed by an agent (or a
person) on a fresh machine. Every step has a **check** that either passes or
tells you exactly what went wrong — do not move on from a failed check, and do
not substitute a different toolchain or path when one is missing. Ask instead.

Host assumed: **Windows 11 + VS Code + Visual Studio 2022 Build Tools**. That is
the verified path. See [Other platforms](#other-platforms) before attempting
anything else.

## What you are installing

Three separate things, in this order. They are independent — a mistake in one
does not corrupt the others, so a failed step can be redone on its own.

| # | Piece | Where it ends up |
|---|---|---|
| 1 | `zx_server.exe` — the emulator, plus its DAP, MCP, screen and audio servers, all in one process | `cpp-core/build/RelWithDebInfo/zx_server.exe` |
| 2 | The **ZX Spectrum Debug** VS Code extension — registers the `zxspectrum` debug type and provides the screen, trace and tape panels | `%USERPROFILE%\.vscode\extensions\jonsole.zxspectrum-debug-0.0.2` |
| 3 | The workspace config — `.vscode/tasks.json` starts the server, `.vscode/launch.json` connects to it | already in the repo; nothing to install |

Plus one thing that is **not** in the repo and cannot be: a real 48K ROM image
(step 2 below).

## Prerequisites

Check all four before starting. Run each command; a missing tool is a stop, not
something to work around.

```powershell
# 1. Visual Studio 2022 Build Tools with the "Desktop development with C++"
#    workload. cl.exe, cmake.exe and ninja.exe are NOT on PATH and are not
#    expected to be -- build.ps1 locates them itself via vswhere. So check for
#    vswhere and the install it reports, not for the compilers:
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath

# 2. VS Code 1.85 or newer
code --version

# 3. git
git --version

# 4. Python 3.10+ -- OPTIONAL. Only the scripts/ helpers need it (ROM
#    disassembly, game disassemblies, tape generation). The emulator itself
#    does not.
python --version
```

If vswhere is absent or reports nothing, install
[Build Tools for Visual Studio 2022](https://visualstudio.microsoft.com/visual-cpp-build-tools/)
and select the **Desktop development with C++** workload. CMake and Ninja come
with that workload — do not install them separately.

## Step 1 — Get the repo

```powershell
git clone <repo-url> zx-spectrum-emulator
cd zx-spectrum-emulator
```

**Check:** `cpp-core\CMakeLists.txt`, `vscode-extension\package.json` and
`.vscode\launch.json` all exist.

## Step 2 — Supply a 48K ROM

The emulator boots a genuine Sinclair 48K ROM, which is Amstrad-copyrighted and
therefore **not** in the repo (all of `roms/` except `.gitkeep` is gitignored).
Obtain a `48.rom` image and put it at `roms/48.rom`.

```powershell
# Verify it is the real thing: exactly 16384 bytes, first byte 0xF3 (DI, the
# first instruction of every genuine Spectrum ROM).
(Get-Item roms\48.rom).Length            # must be 16384
'{0:X2}' -f (Get-Content roms\48.rom -Encoding Byte -TotalCount 1)[0]   # must be F3
```

**Check:** both values as stated. A ROM of the wrong size or with a different
first byte produces a machine that appears to run but never reaches BASIC —
diagnose it here, not later.

Do not download a ROM from an arbitrary source without asking the user; that is
their call, not the installer's.

## Step 3 — Build the emulator

```powershell
cd cpp-core
.\build.ps1 -Release -Test
cd ..
```

`build.ps1` imports the MSVC environment itself (via `vcvars64.bat`) and uses
the CMake and Ninja that ship inside the Build Tools install, so it works from a
plain PowerShell prompt — a "Developer PowerShell" is not required.

- `-Release` builds `RelWithDebInfo`, which is what `.vscode/tasks.json`
  launches. A `Debug` build lands in a different directory and the tasks will
  not find it.
- `-Test` runs the fast test suite through CTest afterwards. The long Z80
  exercisers (ZEXALL/ZEXDOC, billions of instructions) are excluded; run them
  separately with `.\build.ps1 -Release -Slow` if wanted.

**Check:** the script prints `OK: RelWithDebInfo build in ...`, CTest reports
all tests passing, and this file exists:

```
cpp-core\build\RelWithDebInfo\zx_server.exe
```

Two tests (`spectrum_tests`, `tape_tests`) skip parts of themselves without a
real ROM at `roms/48.rom` rather than failing — if you see skip messages, step 2
did not actually take effect.

### Check the server runs

Before involving VS Code, confirm the binary works on its own. Use **spare
ports**, so it cannot collide with a server the user already has running:

```powershell
.\cpp-core\build\RelWithDebInfo\zx_server.exe --dap-port 4799 --mcp-port 8099 --screen-port 8599 --no-audio --rom roms\48.rom
```

**Check:** it prints, in order:

```
Starting ZX Spectrum server...
Loaded ROM roms/48.rom
ROM disassembly: N symbols, M mapped instructions      <- absent until step 7; fine
MCP server listening on 127.0.0.1:8099 (streamable-HTTP, /mcp)
DAP server listening on 127.0.0.1:4799
Screen stream server listening on 127.0.0.1:8599
```

Then Ctrl-C it. Leave the real ports (4711 / 8000 / 8500) alone until VS Code
claims them itself in step 6.

## Step 4 — Install the VS Code extension

VS Code will not attempt a `debugServer` connection unless `launch.json`'s
`type` matches a registered `contributes.debuggers` entry, so this extension is
mandatory even though no debug-adapter code of its own is involved. It also
provides the screen viewer, the trace viewer and the tape pane.

The destination folder name must be `<publisher>.<name>-<version>` taken from
`vscode-extension/package.json` — currently **`jonsole.zxspectrum-debug-0.0.2`**.
Read those three fields rather than trusting this line, in case the version has
moved on.

```powershell
# from the repo root
$dest = "$env:USERPROFILE\.vscode\extensions\jonsole.zxspectrum-debug-0.0.2"
Copy-Item -Recurse .\vscode-extension $dest
# The trace viewer lives in tools/, outside the extension directory -- copy it
# in, or "Show Trace" falls back to hunting for it in the open workspace.
Copy-Item .\tools\trace_viewer.html $dest
```

If you expect to edit the extension, symlink instead of copying, so changes take
effect on a window reload rather than needing the copy re-run (needs an elevated
shell or Developer Mode):

```powershell
New-Item -ItemType SymbolicLink -Path $dest -Target (Resolve-Path .\vscode-extension)
```

Then in VS Code run **Developer: Reload Window** from the Command Palette.

**Check:** `code --list-extensions` includes `jonsole.zxspectrum-debug`, and the
Command Palette offers **ZX Spectrum: Show Screen**.

## Step 5 — Open the workspace

Open the repo folder itself in VS Code (`code .` from the repo root). The
`.vscode/` folder is already configured and needs no edits:

- `tasks.json` — builds `cpp-core` and starts `zx_server.exe` on 4711 (DAP) /
  8000 (MCP) / 8500 (screen); a variant also opens the host's sound card. Its
  `zxspectrum-cpp.stop-stale-server` task kills a leftover `zx_server.exe`
  first, because a running one holds the `.exe` open and the next link fails
  with LNK1168.
- `launch.json` — the debug configurations.
- `settings.json` — sets `debug.allowBreakpointsEverywhere`, needed to place
  breakpoints in `.asm` files.

Opening a parent directory or a different folder means `${workspaceFolder}`
resolves elsewhere and every path in these files breaks. Open the repo root.

## Step 6 — First launch

Run and Debug (Ctrl+Shift+D) → pick **"ZX Spectrum: Step through ROM"** → F5.

What should happen, in order:

1. A dedicated terminal panel appears, running the build, then the server; it
   ends on `DAP server listening on 127.0.0.1:4711`.
2. VS Code connects and the machine stops at the ROM's first instruction.
3. The **live screen panel** opens by itself, showing the display.
4. The Disassembly View shows Z80 at the current PC; the Variables pane shows
   **Registers** and **Flags** scopes.

**Check:** press Continue (F5) and the screen panel shows the `© 1982 Sinclair
Research Ltd` line — the 48K BASIC boot screen. That single result proves the
whole chain: ROM, core, DAP, extension and screen stream.

These configurations work from a clean checkout, no extra assets needed:

| Configuration | Needs |
|---|---|
| Step through ROM | `roms/48.rom` only |
| hello_rom_call example | committed in `examples/` |
| Border rainbow example | committed in `examples/` |
| Tape (fast load) / Tape (real pulse load) / Tape (waiting for LOAD) | committed in `tapes/` |
| ZEXALL / ZEXDOC / ZEXCCFB / Z80 full test suite | committed in `snapshots/` |

The Manic Miner, Fairlight, Aquaplane and Chronos configurations point into
`game_disassembly/` and `snapshots/`, which are gitignored copyrighted content —
they fail until those are built or supplied (step 7).

## Step 7 — Optional extras

None of these are needed for a working install; do them only if asked.

**Source-level ROM debugging.** Builds `rom_disassembly/` (a commented ROM
disassembly plus an SLD address map) so ROM frames show real source lines and
symbol names instead of raw disassembly. `zx_server` picks the directory up
automatically at startup — that is the `ROM disassembly: N symbols` line.

```powershell
python -m venv .venv-win
.\.venv-win\Scripts\pip.exe install skoolkit
.\.venv-win\Scripts\python.exe scripts\build_rom_source.py
```

Also needs `sjasmplus` on PATH (https://github.com/z00m128/sjasmplus). The
script assembles the disassembly and compares it byte-for-byte against
`roms/48.rom`, refusing to write output if they differ — so a pass is also a
second confirmation the ROM is genuine.

**Game disassemblies.** These live in their own repository now,
[zx-spectrum-disassemblies](https://github.com/jonsole/zx-spectrum-disassemblies),
and are checked out here as the `game-disassemblies/` submodule:

```
git clone --recurse-submodules https://github.com/jonsole/zx-spectrum-emulator.git
```

or, in a clone that predates it, `git submodule update --init`. The build
scripts are `game-disassemblies/scripts/build_*.py`; they need the same venv
and `sjasmplus`, plus a game image and a `roms/48.rom` of their own. They write
into `game-disassemblies/game_disassembly/`. Copyrighted; never committed.

**Tape images.** `tapes/loading-test.tap` / `.tzx` are already committed.
`python scripts\make_test_tape.py` regenerates them.

**Sound out of the speakers.** Every launch configuration starts the one
`zxspectrum-cpp.start-server` task, and it passes `--audio-device --no-audio`:
the emulator opens the host sound card directly and the audio *stream* server is
suppressed, so the screen panel does not play the same samples a second time
slightly out of phase. Native device or panel — one or the other, never both.

## Step 8 — Connect an MCP client

> **Prerequisite: `zx_server.exe` must already be running.** The MCP endpoint
> is not a separate program — it is served by the emulator process itself, so
> until step 6 (or a manual `zx_server.exe` run) has started that process,
> there is nothing listening on port 8000 and no MCP tool can work. Nothing in
> the client launches it for you.

The same running server exposes the machine over MCP, so an agent can inspect
and drive the *same* emulator VS Code is stepping. Transport is **streamable
HTTP** at `http://127.0.0.1:8000/mcp` (not SSE).

The repo ships `.mcp.json`, so opening this workspace in Claude Code offers the
server automatically — approve it once. To register it manually:

```bash
claude mcp add zx-spectrum --transport http --url http://127.0.0.1:8000/mcp
```

Registering is not starting: `.mcp.json` and `claude mcp add` only record where
to look. With the emulator down, the client lists `zx-spectrum` as failed and
tool calls fail to connect to `127.0.0.1:8000` instead of returning emulator
errors — start the server, then reconnect the client (in Claude Code, `/mcp`,
or restart it).

The dependency is one-way, though: the server deliberately outlives the debug
session — it is not started with `--exit-on-disconnect` — so stopping the
debugger leaves MCP clients connected and working. What does drop them is the
server process ending, including the `stop-stale-server` task killing it before
a rebuild.

**Check:** with a session running, a raw probe answers:

```powershell
Invoke-WebRequest -Uri http://127.0.0.1:8000/mcp -Method Post `
  -ContentType application/json `
  -Headers @{Accept="application/json, text/event-stream"} `
  -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' `
  -UseBasicParsing | Select-Object -ExpandProperty Content
```

Expect `"serverInfo":{"name":"zx-spectrum",...}`. From an MCP client, the
equivalent check is `get_screen` returning a PNG of the boot screen.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `vswhere.exe not found` from `build.ps1` | No Visual Studio / Build Tools install | Install Build Tools 2022 + "Desktop development with C++" |
| Build fails with `LNK1168: cannot open zx_server.exe` | A previous server still holds the binary | `Get-Process zx_server \| Stop-Process -Force` — but if it is the user's own live session, **ask first** |
| `Configured debug type 'zxspectrum' is not supported` | Extension not installed, or the folder name does not match `publisher.name-version` | Redo step 4, then Developer: Reload Window |
| Launch hangs on the preLaunchTask | The task waits for `DAP server listening`; the server never got there | Read the dedicated terminal — usually a build failure or a port already bound |
| `bind: address already in use` on 4711/8000/8500 | An old server is still up | Stop it (see above), or run yours on spare ports |
| MCP client shows `zx-spectrum` failed/disconnected, or tools error with connection refused on 127.0.0.1:8000 | `zx_server.exe` is not running — the MCP endpoint lives inside it | Start the server (step 6, or run it by hand), then reconnect the client |
| MCP tools worked, then all stopped at once | The server exited — often the rebuild's `stop-stale-server` task killed it | Relaunch the server and reconnect; DAP disconnecting alone does *not* do this |
| Screen panel stays black | Server started without a ROM, or `--screen-port` differs from the extension's hardcoded 8500 | Check `roms/48.rom`; keep the screen port at 8500 — both sides are hardcoded (`SCREEN_HOST`/`SCREEN_PORT` in `extension.js`) |
| Screen panel shows nothing and no error | Webview-side failure | Focus the panel, run **Developer: Open Webview Developer Tools**, read its console |
| Machine runs but never reaches BASIC | Wrong or truncated ROM | Re-verify size 16384 and first byte `F3` |
| Sound doubles or phases | Both the native device and the panel are playing | Use a `-audio` task (`--audio-device --no-audio`) or neither, not a mix |
| **Show Trace** says it cannot find the viewer | `trace_viewer.html` was not copied beside `extension.js` | Copy it (step 4), or keep the repo open as a workspace folder so the fallback path works |
| Breakpoints in `.asm` files are ignored | `debug.allowBreakpointsEverywhere` off | It is set in the repo's `.vscode/settings.json` — confirm you opened the repo root |
| A game launch config fails on a missing `.sna`/`.sld` | Gitignored copyrighted content | Build it via `scripts/`, or pick a configuration from the clean-checkout table |

## Other platforms

`cpp-core` is portable C++17 (CMake plus a C++17 compiler; the platform-specific
audio and socket code is `_WIN32`-guarded), so a Linux/macOS build via
`cmake -S cpp-core -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build build`
is plausible — but it is **not verified**, and `build.ps1`, every path in
`.vscode/tasks.json`, and the native audio backend (WASAPI) are Windows-only.
Treat a non-Windows install as a porting job, and say so rather than reporting a
successful install.

## Other cores

The repo also contains the original Python implementation (`zxspectrum/`,
`pyproject.toml`, `tests/*.py`) and a from-scratch Rust one (`rust-core/`).
**Both are deprecated** — kept for history, no longer developed or verified, and
no longer referenced from `.vscode/`. Install and use the C++ core; do not build
the others, and do not add Rust or Python variants of new work.

The Python helpers under `scripts/` are a different thing and are *not*
deprecated — see step 7.

## Installed-successfully checklist

- [ ] `roms/48.rom` is 16384 bytes and starts `F3`
- [ ] `cpp-core\build\RelWithDebInfo\zx_server.exe` exists and `build.ps1 -Release -Test` passes
- [ ] `code --list-extensions` lists `jonsole.zxspectrum-debug`
- [ ] **"ZX Spectrum: Step through ROM"** launches, stops at the ROM's first instruction, and after Continue the screen panel shows the 1982 Sinclair copyright line
- [ ] The MCP endpoint at `http://127.0.0.1:8000/mcp` answers `initialize`

Report the install as complete only when every box is ticked — and say which
step failed if one did, rather than reporting partial success as success.
