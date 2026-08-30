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

For data tables there's a second wrinkle. `sna2ctl`'s heuristics will happily
start a new block in the middle of one, and a second control file can *add*
block boundaries but never remove them — so a table gets sliced up no matter
what the annotations say. Declaring `; span $ADDR,LENGTH` above the block
directive makes the build drop the generated boundaries inside that range
before merging, which is what keeps `ROOM_TABLE` and `ROOM_SHAPES` whole.

**HTML.** Pass `--html` to also render a browsable disassembly under
`game_disassembly/aticatac/html/` — every routine on its own page with its
comments and register tables, memory maps, and two written-up pages covering
the tape protection and how the game is put together. It's built with
`--asm-labels`, so the pages read `CALL PLOT_TILE` rather than `CALL $A1D3`,
and the `#R` macros in the ref file's prose link to the routines by those
same names.

The HTML build also documents **the room types**. All 149 rooms are one of
only ten outlines in one of six colours — a room's entry in `ROOM_TABLE` is
just those two bytes — so the shape is the unit worth documenting, not the
room. The generated page gives each outline its extents, vertex and edge table
addresses, point and line counts, and the rooms that use it, with a picture.

The pictures are the game's own work: rather than reimplementing the vector
format, the build puts a room number in `$EA91`, runs the redraw entry at
`$9147` in SkoolKit's simulator, and captures the 24×24 cells of the play area
— so the status panel is excluded by construction rather than cropped off. The
page is generated into `game_disassembly/aticatac/` at build time (every number
on it is read out of the game's tables) and passed to `skool2html` alongside
the committed ref.

There's a **sprite catalogue** on the same principle. An actor's `+$00` byte is
both what it looks like and what it does — it indexes the handler table *and*
selects the picture — so the sprites are grouped by the routine that drives
them, which puts the frames of one creature together. Of the 201 codes the
handler table covers, 190 draw something; the rest are entries whose handler is
a sound effect, plus the two the player uses while sinking and rising on death,
which have no picture of their own.

Each picture is drawn by putting the code into `UI_RECORD` and running the two
calls `DRAW_TITLE_ICONS` makes, so nothing on the page depends on having
decoded the sprite format correctly — the same reasoning as the room pictures.

And a **sound page**, on the same principle again: each effect is captured by
running its routine on a machine of its own and recording the writes to bit 4
of port `$FE`, which is the only sound hardware a 48K has. The WAVs go into
SkoolKit's `audio/` path with a player beside each one.

Capture each routine on a *fresh* machine. Running them one after another on a
shared one lets each inherit whatever state the last left behind, which is how
an eight-millisecond rasp once got measured — and written up — as a full second
of sweep.

**The data.** Two thirds of the game is not code, and all of it is now
documented — 30208 of 30208 bytes, 631 named entries. Three things made that
tractable.

The first is that the biggest tables are *generated*, not hand-written.
`build_aticatac.py` reads the sprite pointer table, the room-contents index and
the shape table out of the snapshot and emits a control file of 194 sprite
graphics, 150 room lists and 20 outline tables, each with a label, a title and
sub-block directives that put one record — or one row of pixels — on a line.
Nobody maintains 5000 bytes of `DEFB` by hand, and the blocks stay correct when
the extents are re-derived.

The second is measuring extents rather than inferring them. To find out how
long a sprite is, run the game's own drawing code for every sprite code on a
machine of its own with a memory wrapper logging reads, and see which bytes it
touches. All 235 that draw read exactly `1 + 2 × rowcount` bytes, contiguously,
from the address the table holds — so the format is one header byte and rows of
two bytes, and that is measured rather than guessed. The same trick, applied to
the room redraw, separates the room vector data from the sprites around it.

The third is that this game tiles. The template is exactly the runtime area;
the room lists fill everything up to the byte before the entry point; the
wide graphics end on the first byte of `ROOM_TABLE`; a vertex table ends where
its edge list begins. So "does this length leave a gap?" is a real test, and it
caught two shapes that no room uses (`$06` and `$07`) purely because their
vertex tables were sitting in gaps the used shapes left behind.

Get the table lengths from the data, not from what the game appears to have.
Atic Atac has 149 rooms, so `range(149)` over `ROOM_TABLE` looks obviously
right — and quietly hides two entries, because the table has 151. Entry 150 is
shape `$0C`, the concentric squares drawn while the player falls through a
trapdoor: a room to the drawing code, but not one anybody walks into. Scanning
149 made a shape that the game draws every time you hit a trapdoor look like
unused artwork. The contents index alongside it is 150 long, and the rooms
themselves 149, so three lengths that differ by one are all in play at once and
none should be derived from another. `ROOM_TABLE_ENTRIES`, `ROOM_LIST_ENTRIES`
and `ROOM_COUNT` are separate constants for that reason.

The general trap: a bound that is too small produces no error, no gap and no
failed check. It just silently narrows what you are looking at, and everything
downstream agrees with it.

The round-trip check cannot see any of this, which is worth being explicit
about. A table sliced into pieces, a block whose sub-blocks stop short of its
span, two blocks claiming the same bytes — all of them still reassemble
byte-for-byte, because the bytes are all there and in order. The only symptom
is that the disassembly quietly describes less than it did before. A span
returned as `(start, length)` rather than `(start, end)` matched nothing, undid
about 7% of the coverage, and the build stayed green throughout.

So `check_structure()` runs before the control files are merged and fails the
build on overlapping spans, a sub-block that doesn't start where the last one
ended, or a block whose sub-blocks don't sum to its span. On a good build it
prints one line — `412 spans, no overlaps, every sub-block accounted for`. If
you add a generator, have it return `(start, end)`; the `Span` alias says so
and this check is what enforces it.

The same reasoning applies to anything the disassembly asserts but doesn't
assemble. `render_sprites()` refuses to finish if the pages link a sprite image
it didn't draw, because `graphics_blocks` decides a graphic is blank from its
bytes while the renderer decides by running the game — two rules for one
question, and a disagreement would only show up as a broken image in a browser.

Three things worth knowing about the game itself came out of this. Two sprites
overlap: `$C219` is eighteen rows but `$C23A`, another sprite's first byte,
falls four bytes inside it, and the traces confirm the game reads both ranges
in full. The generator stops a block where the next one starts and says so, so
the description and the listing agree. The victory
message is misspelt — the bytes read `CONGRATULATION` then `$D4`, which is "T"
with the end marker set, and drawing the screen confirms the game says
`CONGRATULATIONT`. And the sequence that plays it is never reached by a machine
playing at random, which is exactly why a code map built from playthroughs left
it classified as data.

Same copyright treatment as the others — `game_disassembly/` is gitignored
and never committed. Load `game_disassembly/aticatac/aticatac.sna` +
`aticatac.sld` over MCP or DAP for source-level debugging, same as Manic
Miner.
