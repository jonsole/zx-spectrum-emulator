# Game examples

Part of the [zx-spectrum-emulator README](../README.md).

## Example: Manic Miner

A bigger example than [`hello_rom_call`](../examples/hello_rom_call/README.md) —
[SkoolKit's Manic Miner
disassembly](https://github.com/skoolkid/manicminer), source-level debuggable
end to end. `scripts/build_manicminer.py` fetches it, assembles it with
`sjasmplus`, and wraps the result into a `.sna` (`snapshot.cpp`'s
`write_sna()`, the write-side counterpart of the `.sna` loader):

```sh
.venv-win\Scripts\python.exe scripts\build_manicminer.py
```

Unlike `hello_rom_call` (original, trivial, safe to commit), the output here
**must never be committed** — a full game disassembly necessarily reproduces
the actual copyrighted game code and data in full, same treatment as the ROM
itself: `game_disassembly/` and `.manicminer-disassembly-src/` are gitignored,
built locally, and there's no reference binary to verify against (unlike the
ROM), so a clean `sjasmplus` assembly with zero errors is the correctness
signal instead. Launch **"ZX Spectrum: Manic Miner"** once built, or load
`game_disassembly/manicminer/mm.sna` + `mm.sld` over MCP the same way as any
other program.

## Example: Fairlight

A second, larger game disassembly — [VilleKrumlinde/FairlightZ80](https://github.com/VilleKrumlinde/FairlightZ80),
a hand-annotated reconstruction of the 1985 isometric adventure, complete
with a written analysis of its render pipeline, room bytecode format and
textured flood fill. `scripts/build_fairlight.py` fetches it, assembles it
with `sjasmplus`, and wraps the result into a `.sna`:

```sh
.venv-win\Scripts\python.exe scripts\build_fairlight.py
```

Two differences from Manic Miner. The upstream repo ships assembler source
directly (no `skool2asm` step), and because it was reconstructed from a
snapshot rather than a tape image it assembles to the *entire* 48K RAM
image — screen, sysvars and runtime buffers included — so the `.sna`'s RAM
is the assembler's output verbatim. That also means the startup register
state isn't in the source anywhere and has to be reconstructed — PC
`0xF065` (the title-screen loop), SP `0x6392` (recovered from the original
snapshot's header), and IY `0xFF80` (the game-state block, which the code
assumes is already in IY on entry; leaving it at 0 hangs the first room
draw and gives a permanently black screen). Each is derived in a comment
in the script.

Same copyright treatment as Manic Miner: `game_disassembly/` and
`.fairlight-disassembly-src/` are gitignored and never committed. Launch
**"ZX Spectrum: Fairlight"** — its `preLaunchTask` reassembles
before starting the server, so editing the fetched `.asm` and relaunching
picks the change up.

## Example: Atic Atac

Unlike the other two, this one has no published disassembly to fetch:
`scripts/build_aticatac.py` produces it from a `.tap` of the 1983 Ultimate
game itself.

```sh
.venv-win\Scripts\python.exe scripts\build_aticatac.py --tape "Atic Atac.tap"
```

Two problems have to be solved that the other two don't have. First, the
tape is *encrypted*: the BASIC loader's `PRINT USR 23424` enters an 18-byte
stub in the printer buffer that `RRD`s a nibble through all 31744 bytes of
the game before jumping to `0x6000`, so the plaintext only ever exists in
RAM. The script runs the tape's own decryptor via `tap2sna`'s simulated
load and disassembles the result. (A second piece of the same protection
pokes `0x255E` into `FRAMES`, which the decrypted entry point checks and
drops back to BASIC if absent — so the tiny tape blocks matter.)

Second, telling code from data. Atic Atac is mostly graphics, and a static
pass mis-reads a lot of sprite data as plausible instructions. So the script
*plays the game* in SkoolKit's simulator — mashing keys through the title
screen and around the castle, once per character and control method — and
records every address actually executed. That map drives the code/data
split, so unreached bytes stay `DEFB`s rather than becoming invented
instructions. The whole build takes about a minute.

There's no reference binary to diff against, so the check is a round trip:
the generated `.asm` is fed back through `sjasmplus` and compared against
the decrypted memory it came from. The build fails unless all 30208 bytes
match byte-for-byte.

**Annotating it.** Everything in `game_disassembly/aticatac/` is output and is
rebuilt from scratch on every run, so hand-editing the `.asm` or `.ctl` there
loses the work. Comments go in `scripts/aticatac_annotations.ctl` instead — a
SkoolKit control file of routine names, titles and per-instruction comments
that the build layers over the generated code/data map (`sna2skool` takes `-c`
more than once and merges them). Titles and the two prose pages for the HTML
build live in `scripts/aticatac.ref`. Both are committed: addresses and prose,
no game bytes.

One trap: an instruction comment written `  $ADDR,N` whose `N` doesn't land on
an instruction boundary makes `sna2skool` cut an instruction in half and
re-decode from the middle, silently shifting every address after it. The
round-trip check catches the damage, and the build also prints the offending
annotation line and the length it should have been.

**HTML.** Pass `--html` to also render a browsable disassembly under
`game_disassembly/aticatac/html/` — every routine on its own page with its
comments and register tables, memory maps, and two written-up pages covering
the tape protection and how the game is put together. It's built with
`--asm-labels`, so the pages read `CALL PLOT_TILE` rather than `CALL $A1D3`,
and the `#R` macros in the ref file's prose link to the routines by those
same names.

Same copyright treatment as the others — `game_disassembly/` is gitignored
and never committed. Load `game_disassembly/aticatac/aticatac.sna` +
`aticatac.sld` over MCP or DAP for source-level debugging, same as Manic
Miner.
