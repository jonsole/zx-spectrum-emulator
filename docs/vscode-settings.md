# VS Code settings reference

Part of the [zx-spectrum-emulator README](../README.md).

Everything the ZX Spectrum extension can be configured with, in the three JSON
files it is configured through:

| File | What goes in it |
|---|---|
| `settings.json` (user or workspace) | How the screen panel draws the picture |
| `.vscode/launch.json` | What a debug session loads and how it connects |
| `.vscode/tasks.json` | How the server is started, and with which flags |

The repo's own `.vscode/` folder has all three set up; this page is for
changing them, or for setting up another workspace. How the pieces fit
together is in [Debugging in VS Code](vscode-debugging.md).

## settings.json

The extension contributes three settings, all about the screen panel. They are
under **ZX Spectrum** in the Settings editor, and the magnifier in the screen
panel's title bar (**ZX Spectrum: Screen Scaling...**) sets them too -- as user
settings, so they hold in every workspace. The open panel follows any change at
once, however it was made.

| Setting | Values | Default | What it does |
|---|---|---|---|
| `zxspectrum.screen.filter` | `"nearest"`, `"sharp-bilinear"`, `"bilinear"` | `"nearest"` | How the 352x312 picture is scaled: hard-edged pixels; hard-edged pixels kept evenly sized at any size; or smoothed |
| `zxspectrum.screen.scale` | `"fit-integer"`, `"fit"`, `"1"`, `"2"`, `"3"`, `"4"` | `"fit-integer"` | How large it is drawn: as large as the panel allows in whole multiples; filling the panel; or a fixed size, scrolling if the panel is smaller |
| `zxspectrum.screen.scanlines` | whole number, `0`-`100` | `0` | How dark the gap in the lower half of each line is, as a percentage: `0` is off, `100` black |

```jsonc
{
  // Crisp pixels that fill the panel, with a light CRT texture.
  "zxspectrum.screen.filter": "sharp-bilinear",
  "zxspectrum.screen.scale": "fit",
  "zxspectrum.screen.scanlines": 40
}
```

Things worth knowing:

- **Sharp bilinear and nearest neighbour only differ at in-between sizes.** At
  a whole-multiple size they draw the same picture, so the filter matters most
  with `"fit"`.
- **Scanlines need two device pixels a line.** At `"1"` on an unscaled display
  there is no room for a gap, and the setting has no effect.
- **Sizes are in device pixels.** On a 125% or 150% display, `"fit-integer"`
  picks whole multiples of *physical* pixels, which is what keeps nearest
  neighbour exact there.
- **Anything unrecognised falls back to the default** rather than breaking the
  panel.

What each option looks like is in [Scaling and
filtering](vscode-debugging.md#scaling-and-filtering).

## launch.json

Every configuration is a `zxspectrum` debug session that connects to a server
which is already running -- the extension has no debug adapter of its own.
Four attributes make that work, and they are VS Code's rather than this
extension's:

| Attribute | Value | Why |
|---|---|---|
| `type` | `"zxspectrum"` | Selects this extension's debugger |
| `request` | `"launch"` or `"attach"` | Launch sets the machine up from scratch; attach joins it as it is |
| `debugServer` | `4711` | The server's DAP port, which VS Code connects to directly. Must match the server's `--dap-port` |
| `preLaunchTask` | `"zxspectrum-cpp.start-server"` (launch) or `"zxspectrum-cpp.start-server-if-absent"` (attach) | Starts the server first -- see [tasks.json](#tasksjson) |

Paths are best written with `${workspaceFolder}`: the server resolves a
relative path against its own working directory, which is only the workspace
folder when the task started it.

### Launch attributes

All optional. They are applied in this order, which is what makes them combine
sensibly -- a tape auto-start, for instance, resets the machine, so it has to
come after the snapshot and the reset it replaces:

| # | Attribute | Type | Default | What it does |
|---|---|---|---|---|
| 1 | `uncapped` | boolean | speed left as it was | `true` runs as fast as the host allows instead of at a real Spectrum's speed -- for the Z80 exercisers, which have nothing to watch. The beeper is silent while uncapped |
| 2 | `rom` | path | none | A ROM image: 16K for the 48K, or the 32K pair (ROM 0 then ROM 1, the usual `128.rom`) for the 128K. Either can be loaded whatever the machine is |
| 3 | `machine` | `"48"` or `"128"` | `"48"` | Which Spectrum to be. `"128"` needs a 32K `rom` already loaded, and says so if there isn't one |
| 4 | `snapshot` | path | none | A `.sna` or `.z80` (48K or 128K) to load; the machine becomes the model it was taken on, whatever `machine` said. Without one, the machine is reset |
| 5 | `tape` | path | none | A `.tap`, `.tzx`, `.wav` or `.csw` to insert. The format is taken from the contents, not the extension; recordings (`.wav`, `.csw`) always load at tape speed |
| | `tapeAutoStart` | boolean | `true` | With `tape`: reset, type `LOAD ""` and start the tape, so the session is already loading |
| | `tapeFastLoad` | boolean | `true` | With `tape`: satisfy standard-speed blocks instantly by trapping the ROM's loader. Turbo and custom loaders always play as real pulses |
| 6 | `waitForTape` | boolean | `false` | Boot and type `LOAD ""` with no tape, leaving the ROM loader waiting for one inserted later. Ignored when a tape is auto-starting, which has already done it |
| 7 | `sld` | path | none | An sjasmplus SLD file, for source-level debugging of the loaded program. Needs `asm`; either one alone is ignored |
| | `asm` | path | none | The **entry** source the SLD was assembled from. Files it `INCLUDE`s are found through the SLD |

Two behaviours that are easy to trip over:

- **Debug info outlives the launch that loaded it.** A later launch without
  `sld` and `asm` keeps the previous program's, rather than clearing it; one
  that has them replaces it.
- **The session starts stopped.** Nothing runs until Continue, whatever was
  loaded.

### Attach attributes

An attach never touches the machine: no reset, no ROM, no snapshot, no tape.
It only takes the program's debug info, so a session joining a running game
can still step its source.

| Attribute | Type | What it does |
|---|---|---|
| `sld` | path | As for launch. Needs `asm` |
| `asm` | path | As for launch. Needs `sld` |

### Examples

The ROM on its own:

```jsonc
{
  "name": "ZX Spectrum: Step through ROM",
  "type": "zxspectrum",
  "request": "launch",
  "debugServer": 4711,
  "rom": "${workspaceFolder}/roms/48.rom",
  "preLaunchTask": "zxspectrum-cpp.start-server"
}
```

A 128K, booting to its menu:

```jsonc
{
  "name": "ZX Spectrum 128",
  "type": "zxspectrum",
  "request": "launch",
  "debugServer": 4711,
  "rom": "${workspaceFolder}/roms/128.rom",
  "machine": "128",
  "preLaunchTask": "zxspectrum-cpp.start-server"
}
```

Your own program, with its source:

```jsonc
{
  "name": "My game",
  "type": "zxspectrum",
  "request": "launch",
  "debugServer": 4711,
  "rom": "${workspaceFolder}/roms/48.rom",
  "snapshot": "${workspaceFolder}/game/output/game.sna",
  "sld": "${workspaceFolder}/game/output/game.sld",
  "asm": "${workspaceFolder}/game/main.s",
  "preLaunchTask": "zxspectrum-cpp.start-server"
}
```

A tape, loading as it would on the real machine:

```jsonc
{
  "name": "Load a tape at tape speed",
  "type": "zxspectrum",
  "request": "launch",
  "debugServer": 4711,
  "rom": "${workspaceFolder}/roms/48.rom",
  "tape": "${workspaceFolder}/tapes/game.tzx",
  "tapeFastLoad": false,
  "preLaunchTask": "zxspectrum-cpp.start-server"
}
```

Joining a server that is already running, without resetting it. **Add
Configuration...** offers this as the *Attach to a running emulator* snippet,
without the task line -- add it, or start the server yourself first:

```jsonc
{
  "name": "ZX Spectrum: Attach",
  "type": "zxspectrum",
  "request": "attach",
  "debugServer": 4711,
  "preLaunchTask": "zxspectrum-cpp.start-server-if-absent"
}
```

## tasks.json

The server's own options are command-line flags, so they live in the task that
starts it rather than in any setting. The repo's `.vscode/tasks.json` has:

| Task | Does |
|---|---|
| `zxspectrum-cpp.start-server` | Stops any running server (Windows will not relink an executable in use), builds `cpp-core` in Release, and starts `zx_server.exe` |
| `zxspectrum-cpp.start-server-if-absent` | Starts a server only if nothing is listening on the DAP port, and never stops or rebuilds one -- the task for attaching |
| `zxspectrum-cpp.build`, `zxspectrum-cpp.stop-stale-server` | The two steps the first task depends on |

`start-server` passes these flags:

```jsonc
"args": [
  "--dap-port", "4711",     // must match launch.json's debugServer
  "--mcp-port", "8000",     // where MCP clients connect
  "--screen-port", "8500",  // must stay 8500: the screen panel only looks there
  "--audio-device",         // sound out of the host's speakers...
  "--no-audio"              // ...and not a second time through the panel
]
```

To hear the sound through the screen panel instead, drop both `--audio-device`
and `--no-audio`. Every flag the server takes is listed under
[Running](../README.md#running).

## The workspace's own settings

The repo's `.vscode/settings.json` sets these for this workspace. None are
needed for the extension to work elsewhere:

| Setting | Value | Why |
|---|---|---|
| `debug.allowBreakpointsEverywhere` | `true` | Breakpoints in any file. The extension now declares Z80 assembly as a breakpoint language itself, so `.asm`, `.s` and `.a80` files take breakpoints without this; it stays for files in other languages |
| `debug.focusEditorOnBreak` | `false` | A stop moves the debugger's selection without taking the keyboard -- see [where the focus goes](vscode-debugging.md#where-the-focus-goes-when-it-stops) |
| `debug.focusWindowOnBreak` | `false` | ...nor raising the window |
| `files.associations` | `*.asm`, `*.s` to `z80-asm` | So another installed assembly extension does not claim them first |

## What is not a setting

- **The screen and audio ports.** The panel always connects to `127.0.0.1`,
  port 8500 for the picture and 8501 for sound. A server started on other
  ports runs fine, but its panel stays blank. The DAP port is `debugServer`
  above, and the MCP port is whatever the MCP client is pointed at (see
  [Connecting an MCP client](mcp.md)).
- **Anything about the running machine.** Speed, the display-write overlay, the
  raster view, watchpoints and profiling are commands, not settings: their state
  lives in the server and starts afresh with it.
