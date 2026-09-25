# The Spectrum ROM

A VS Code workspace for stepping through the ZX Spectrum's ROM in *The Complete
Spectrum ROM Disassembly* -- every routine named and commented -- on the
emulator in the **ZX Spectrum Debug** extension.

## Before you start

Install the extension: `zxspectrum-debug-<version>-win32-x64.vsix` from the
[releases page](https://github.com/jonsole/zx-spectrum-emulator/releases), with
**Extensions: Install from VSIX...**. It carries the emulator and the ROMs;
nothing else is needed.

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
| `rom_disassembly/rom.asm` | The disassembly, as assembly source |
| `rom_disassembly/rom.sld` | sjasmplus's map from each address to its line in `rom.asm` |
| `.vscode/launch.json` | The configurations above |

The disassembly is *The Complete Spectrum ROM Disassembly* by Dr Ian Logan and
Dr Frank O'Hara, in Richard Dymond's SkoolKit edition
([skoolkid/rom](https://github.com/skoolkid/rom)), converted with SkoolKit's
`skool2asm.py` and assembled with sjasmplus -- which reproduces the real ROM
byte for byte, or the build refuses to write it. The ROM is copyright Amstrad;
the disassembly's text is its authors'. See `THIRD_PARTY_NOTICES.md`.
