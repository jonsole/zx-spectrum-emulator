# VS Code settings reference

Part of the [zx-spectrum-emulator README](../README.md).

Everything the ZX Spectrum extension can be configured with, in the three JSON
files it is configured through:

| File | What goes in it |
|---|---|
| `settings.json` (user or workspace) | How the emulator is started, how the screen panel draws the picture, and what opening a snapshot does |
| `.vscode/launch.json` | What a debug session loads and how it connects |
| `.vscode/tasks.json` | How this repo's own configurations build and start the server |

The repo's own `.vscode/` folder has all three set up; this page is for
changing them, or for setting up another workspace. How the pieces fit
together is in [Debugging in VS Code](vscode-debugging.md).

## settings.json

All the extension's settings are under **ZX Spectrum** in the Settings editor.

### Starting the emulator

A launch configuration without a `debugServer` (see [launch.json](#launchjson))
connects to `zxspectrum.server.dapPort`, and the extension starts the emulator
first if nothing is listening there. These settings say where it is and how it
is started. A server that was already running -- from a task, a terminal, an
MCP client or another window -- is joined as it is, whatever they say.

| Setting | Values | Default | What it does |
|---|---|---|---|
| `zxspectrum.server.autoStart` | boolean | `true` | Start the emulator when a session needs it and nothing is listening. Off, such a session fails with a message instead |
| `zxspectrum.server.path` | path | `""` | Where `zx_server` is. `${workspaceFolder}`, `${userHome}` and `~` are expanded. Empty: each workspace folder's `cpp-core/build/RelWithDebInfo/`, then the one an installed release carries, then `PATH` |
| `zxspectrum.server.roms` | list of paths | `[]` | ROMs to load at start (`--rom`). Empty: `roms/48.rom` and `roms/128.rom` in the emulator's checkout, each when it is there, and otherwise the ones an installed release carries. A launch configuration's `rom` still applies to its own session |
| `zxspectrum.server.sound` | `"device"`, `"panel"`, `"off"` | `"device"` | Sound out of the computer's sound card, through the screen panel, or not at all |
| `zxspectrum.server.args` | list of strings | `[]` | More command-line flags, after the ones the settings make -- `["--ffmpeg", "C:/tools/ffmpeg.exe"]`, say |
| `zxspectrum.server.stopOnExit` | boolean | `true` | Stop the emulator this window started when the window closes. Either way it keeps running between debug sessions |
| `zxspectrum.server.dapPort` | port | `4711` | The debug adapter port (`--dap-port`) |
| `zxspectrum.server.mcpPort` | port | `8000` | The MCP port (`--mcp-port`) |
| `zxspectrum.server.screenPort` | port | `8500` | The screen stream (`--screen-port`), which the screen panel reads until a session says which server it is on |
| `zxspectrum.server.audioPort` | port | `8501` | The audio stream (`--audio-port`), which the screen panel plays with `"panel"` sound |

```jsonc
{
  // A build somewhere else, on spare ports, with the sound in the panel.
  "zxspectrum.server.path": "~/zx-spectrum-emulator/cpp-core/build/RelWithDebInfo/zx_server.exe",
  "zxspectrum.server.dapPort": 4799,
  "zxspectrum.server.mcpPort": 8099,
  "zxspectrum.server.screenPort": 8599,
  "zxspectrum.server.audioPort": 8598,
  "zxspectrum.server.sound": "panel"
}
```

The server runs in the root of the checkout it was built in (where
`rom_disassembly/` is found), or else the first workspace folder. Its output is
in the **ZX Spectrum Emulator** output channel, and the **Spectrum** item in the
status bar -- shown while an emulator is running -- has Stop, Restart and the
log. The ports apply to the server the extension starts and to what the screen
panel connects to, so a server started some other way on other ports needs
them set to match.

### Opening programs

| Setting | Values | Default | What it does |
|---|---|---|---|
| `zxspectrum.program.runOnOpen` | boolean | `false` | Run a `.sna`, `.z80`, `.tap` or `.tzx` as soon as it is opened, instead of showing it with **Run** and **Debug** buttons. The box on that page sets it too |

### The screen panel

Four settings say how the panel draws the picture. The magnifier in the screen
panel's title bar (**ZX Spectrum: Screen Scaling...**) sets them too -- as user
settings, so they hold in every workspace. The open panel follows any change at
once, however it was made.

| Setting | Values | Default | What it does |
|---|---|---|---|
| `zxspectrum.screen.filter` | `"nearest"`, `"sharp-bilinear"`, `"bilinear"` | `"nearest"` | How the 352x312 picture is scaled: hard-edged pixels; hard-edged pixels kept evenly sized at any size; or smoothed |
| `zxspectrum.screen.scale` | `"fit-integer"`, `"fit"`, `"1"`, `"2"`, `"3"`, `"4"` | `"fit-integer"` | How large it is drawn: as large as the panel allows in whole multiples; filling the panel; or a fixed size, scrolling if the panel is smaller |
| `zxspectrum.screen.border` | whole number, `0`-`100` | `100` | How much of the border to show, as a percentage of the 48 pixels each side, 64 lines above and 56 below that the emulator draws: `100` is all of it, `0` the 256x192 paper alone. The picture is scaled to fit what is left |
| `zxspectrum.screen.scanlines` | whole number, `0`-`100` | `0` | How dark the gap in the lower half of each line is, as a percentage: `0` is off, `100` black |

```jsonc
{
  // Crisp pixels that fill the panel, a narrow border, and a light CRT texture.
  "zxspectrum.screen.filter": "sharp-bilinear",
  "zxspectrum.screen.scale": "fit",
  "zxspectrum.screen.border": 25,
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
- **The border crops before anything is scaled.** Sizes, whole multiples and
  scanlines are all of the cropped picture, and each side is cropped in whole
  pixels, so nearest neighbour and the scanline gaps stay aligned with the
  Spectrum's own lines.
- **Anything unrecognised falls back to the default** rather than breaking the
  panel.

What each option looks like is in [Scaling and
filtering](vscode-debugging.md#scaling-and-filtering).

## launch.json

Every configuration is a `zxspectrum` debug session connected to the
emulator's DAP port. There are two ways to get it there:

- **Leave `debugServer` out.** The extension connects to
  `zxspectrum.server.dapPort`, starting the emulator first if nothing is
  running (see [Starting the emulator](#starting-the-emulator)). This is all a
  project of your own needs.
- **Give `debugServer`, with a `preLaunchTask` that starts the server.** VS
  Code then connects to that port itself and the extension starts nothing.
  One configuration in this repo does that -- "Step through ROM (rebuild the
  emulator)", for when the emulator itself is what you are changing -- see
  [tasks.json](#tasksjson).

| Attribute | Value | Why |
|---|---|---|
| `type` | `"zxspectrum"` | Selects this extension's debugger |
| `request` | `"launch"` or `"attach"` | Launch sets the machine up from scratch; attach joins it as it is |
| `debugServer` | a port, e.g. `4711` | Optional. Connect to this port directly and start nothing |
| `preLaunchTask` | e.g. `"zxspectrum-cpp.start-server"` | Optional. A task to run first -- with `debugServer`, the one that starts the server |

Paths are best written with `${workspaceFolder}`: the server resolves a
relative path against its own working directory, which is not necessarily the
workspace folder.

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
| 8 | `stopOnEntry` | boolean | `true` | Stop at the first instruction once everything is loaded. `false` carries straight on running |

Two behaviours that are easy to trip over:

- **Debug info outlives the launch that loaded it.** A later launch without
  `sld` and `asm` keeps the previous program's, rather than clearing it; one
  that has them replaces it.
- **The session starts stopped** unless `stopOnEntry` is `false`. Nothing runs
  until Continue, whatever was loaded.

### Attach attributes

An attach never touches the machine: no reset, no ROM, no snapshot, no tape.
It only takes the program's debug info, so a session joining a running game
can still step its source.

| Attribute | Type | What it does |
|---|---|---|
| `sld` | path | As for launch. Needs `asm` |
| `asm` | path | As for launch. Needs `sld` |

### Examples

The ROM on its own, with the emulator started by the extension:

```jsonc
{
  "name": "ZX Spectrum",
  "type": "zxspectrum",
  "request": "launch",
  "rom": "${workspaceFolder}/roms/48.rom"
}
```

The same, but rebuilding the emulator first -- what this repo's "Step through
ROM (rebuild the emulator)" is for:

```jsonc
{
  "name": "ZX Spectrum: Step through ROM (rebuild the emulator)",
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
  "rom": "${workspaceFolder}/roms/128.rom",
  "machine": "128"
}
```

Your own program, with its source:

```jsonc
{
  "name": "My game",
  "type": "zxspectrum",
  "request": "launch",
  "rom": "${workspaceFolder}/roms/48.rom",
  "snapshot": "${workspaceFolder}/game/output/game.sna",
  "sld": "${workspaceFolder}/game/output/game.sld",
  "asm": "${workspaceFolder}/game/main.s"
}
```

A tape, loading as it would on the real machine:

```jsonc
{
  "name": "Load a tape at tape speed",
  "type": "zxspectrum",
  "request": "launch",
  "rom": "${workspaceFolder}/roms/48.rom",
  "tape": "${workspaceFolder}/tapes/game.tzx",
  "tapeFastLoad": false
}
```

Joining the emulator that is already running, without resetting it -- or
starting it, if nothing is. **Add Configuration...** offers this as the
*Attach to a running emulator* snippet:

```jsonc
{
  "name": "ZX Spectrum: Attach",
  "type": "zxspectrum",
  "request": "attach"
}
```

## tasks.json

Only needed for a configuration that gives a `debugServer`, or one that has
something to build first. Otherwise the extension starts the server, with the
flags the [settings](#starting-the-emulator) make. The repo's
`.vscode/tasks.json` has:

| Task | Does |
|---|---|
| `zxspectrum-cpp.start-server` | Stops any running server (Windows will not relink an executable in use), builds `zx_server` in Release -- the server alone, not the tests and tools -- and starts it. One configuration uses it: "Step through ROM (rebuild the emulator)" |
| `zxspectrum-cpp.build`, `zxspectrum-cpp.stop-stale-server` | The two steps the first task depends on |
| `filmation.build`, `fairlight.build`, `knightlore.build` | Assemble those three programs from source. Their configurations name these directly -- the server is the extension's business |

To start a server only when nothing is listening, leave the `preLaunchTask`
out: a configuration without a `debugServer` has the extension do exactly
that.

`start-server` passes these flags:

```jsonc
"args": [
  "--dap-port", "4711",     // must match launch.json's debugServer
  "--mcp-port", "8000",     // where MCP clients connect
  "--screen-port", "8500",  // must match zxspectrum.server.screenPort
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

- **The host.** Everything is on `127.0.0.1`.
- **The volume.** The screen panel's speaker and slider set it, and the
  extension remembers it across reloads on its own rather than in
  `settings.json` -- a slider being dragged is not something to write to a
  settings file at every step. See [Volume](audio.md#volume).
- **Anything about the running machine.** Speed, the display-write overlay, the
  raster view, watchpoints and profiling are commands, not settings: their state
  lives in the server and starts afresh with it.
