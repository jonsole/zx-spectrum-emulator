# border_rainbow

A minimal diagnostic program: `test.asm` tight-loops writing 0-7 to I/O port
0xFE (the border color register), producing the classic ZX Spectrum
"rainbow border" torture test. Useful for confirming the emulator's
per-pixel border-latching actually shows *any* variation at all, isolated
from a real game's own logic/timing.

```
Start:
    XOR A               ; A = 0
Loop:
    OUT (0xFE), A        ; border = A & 7
    INC A
    AND 7
    JR Loop
```

`test.sna` was hand-assembled (no `sjasmplus` available in this environment)
via a small Python script rather than following `hello_rom_call`'s normal
`SAVESNA`-based build -- see the program bytes and `.sna` header layout
spelled out in the script if you need to regenerate it. No `.sld` file, so
no source-level stepping for this one (matches "Step through ROM"'s scope,
not `hello_rom_call`'s).

Launch **"ZX Spectrum: Border rainbow example"** from the Run and
Debug view and hit continue -- the border should immediately show 8 rapidly
cycling colored bands.
