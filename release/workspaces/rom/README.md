# The Spectrum ROM

A VS Code workspace for stepping through the ZX Spectrum's ROM in *The Complete
Spectrum ROM Disassembly* -- every routine named and commented -- on the
emulator in the **ZX Spectrum Debug** extension.

## Before you start

- **ZX Spectrum Debug** (`zxspectrum-debug-<version>-win32-x64.vsix`) from the
  [releases page](https://github.com/jonsole/zx-spectrum-emulator/releases),
  installed with **Extensions: Install from VSIX...** -- the emulator, the ROMs
  and the debugger.
- **Python 3** on the PATH, with **SkoolKit**: `pip install skoolkit==10.1`, the
  version the build is checked with.

The disassembly itself is not in this zip: it is published with no licence to
pass it on, so the workspace builds it on your machine instead. The first
launch fetches its source from [skoolkid/rom](https://github.com/skoolkid/rom),
at a pinned commit, converts it with SkoolKit and assembles it with sjasmplus
(fetched by the extension if there is none on the PATH) into
`rom_disassembly/`. That needs an internet connection and takes a few seconds;
every launch after it finds the disassembly built and goes straight on. The
build keeps the result only if it reassembles the 48K ROM byte for byte, so
every line of it is at the address it says.

## Using it

Open this folder in VS Code (**File > Open Folder...**, the folder this README
is in), then **Run > Start Debugging** (F5) and pick a configuration:

- **Step through the 48K ROM** -- the machine from power-on, stopped at `$0000`.
  Step with F10/F11, or open `rom_disassembly/rom.asm`, set a breakpoint on any
  line and continue (F5).
- **Step through the 128K ROM** -- the 128K; 48 BASIC is ROM 1, which is the
  48K's code, so the disassembly follows it there.
- **Attach to the running emulator** -- join the machine as it is.

The **ZX Spectrum Screen** panel opens with the session; click it and type to
use the keyboard. The emulator must be started from this folder to find
`rom_disassembly/`: if one is already running from somewhere else, stop it
first (the **Spectrum** item in the status bar has Stop).

More: the [user guide](https://github.com/jonsole/zx-spectrum-emulator/blob/master/docs/vscode-user-guide.md).

## What is here

| | |
|---|---|
| `scripts/build_rom_source.py` | Builds the disassembly into `rom_disassembly/` |
| `rom_disassembly/rom.asm` | The disassembly, as assembly source, once built |
| `rom_disassembly/rom.sld` | sjasmplus's map from each address to its line in `rom.asm`, once built |
| `.vscode/launch.json` | The configurations above |
| `.vscode/tasks.json` | The build, which they run first (**Terminal > Run Build Task...** runs it alone) |

The disassembly is *The Complete Spectrum ROM Disassembly* by Dr Ian Logan and
Dr Frank O'Hara, in Richard Dymond's SkoolKit edition
([skoolkid/rom](https://github.com/skoolkid/rom)), converted with SkoolKit's
`skool2asm` and assembled with sjasmplus. The ROM is copyright Amstrad; the
disassembly's text is its authors'. See `THIRD_PARTY_NOTICES.md`.
