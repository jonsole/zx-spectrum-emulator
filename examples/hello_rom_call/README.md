# hello_rom_call

A minimal example for testing source-level debugging of your own program
(see the main README's "Source-level debugging of your own program"):
`test.asm` calls into a real ROM routine, so stepping through it in VS Code
shows the source view switching from `test.asm` to the ROM's own `rom.asm`
(once you've built it — see `scripts/build_rom_source.py`) and back.

`test.sna` and `test.sld` are `test.asm` assembled with `sjasmplus`; the
`SAVESNA` directive at the bottom of `test.asm` produces `test.sna` as part
of assembling, so both files are just checked in rather than regenerated on
every build (unlike the ROM's own disassembly, this is original content, not
copyrighted material). To rebuild after editing `test.asm`:

```sh
sjasmplus test.asm --sld=test.sld --fullpath
```

Launch **"ZX Spectrum: hello_rom_call example"** from the Run and Debug view
(`.vscode/launch.json`) and step through with F10/F11: `Start`/`PrintIt` show
`test.asm`, and once you step into the `CALL 0x0010`, the view switches to
`rom.asm` at `PRINT_A_1` — the ROM's real print-a-character routine.
