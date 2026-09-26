---
name: zx-reverse-engineer
description: Reverse engineer a ZX Spectrum game into a byte-exact, fully described SkoolKit disassembly in the game-disassemblies submodule -- and keep written notes about the game as you go, not just the HTML. Use when asked to disassemble, reverse engineer, document or work out how a Spectrum game works (a new one, or more of The Hobbit, Atic Atac, Ant Attack, Knight Lore), to find what a variable or routine does, to test a claim about a game's behaviour in the emulator, or to write up findings about a game.
---

# Reverse engineering a Spectrum game

The work lives in the `game-disassemblies/` submodule. Every game there is
built the same way: a script takes the original tape, produces a commented
disassembly that reassembles byte-for-byte, and optionally a browsable HTML
version. `scripts/build_antattack.py` is the newest and cleanest example of the
whole pipeline -- copy its shape for a new game. `docs/game-examples.md` is the
long account of how the method was arrived at and the mistakes it made; read
its Atic Atac and Knight Lore sections before starting a new game.

The output is three things, and a game is not done until all three exist:

1. **The disassembly** -- `scripts/build_<game>.py`, `scripts/<game>_annotations.ctl`,
   `scripts/<game>.ref`. Every byte accounted for, every routine named and
   described, every address a label.
2. **The notes** -- `notes/<game>/`, written *while* you work. What the game
   is, how it works, how to drive it, what was measured, what is still open.
   See [Notes](#notes) below; this is not optional and not an afterthought.
3. **The published pages** -- when the user asks, `scripts/publish_pages.py`.

## Ground rules

- **No game bytes on master.** The game-disassemblies repo is public. Master
  holds addresses, structure and prose: control files, ref files, build
  scripts, notes. The game's code, text, pictures and anything built from them
  go in `game_disassembly/` (gitignored) and, when asked, on the `gh-pages`
  branch only. That covers the notes too: describe formats and name things,
  never paste byte dumps, message text or extracted graphics into them. Short
  names (a room, an object) are fine; the annotations already use them.
- **Room names and other game text in generated blocks** come from the game at
  build time (like `hobbit-rooms.ctl`), not typed into a committed file. The
  same goes for level data described record by record -- each room's contents,
  each piece's position: that is the level design again in words. Put the
  per-record lines in a generator the build runs on the snapshot
  (`scripts/knightlore_data.py`, passed to sna2skool between the map and the
  annotations, with `trim_overlaps` making room for its lines), and keep only
  the table's title, format and prose in the annotations.
- **`tapes/` is the user's originals, with no backup.** Read them; never write
  build output there. Downloads go to the scratchpad.
- **Other sessions share the tree.** Stage by name, apply only your own hunks
  (`git diff` > patch > drop others' hunks > `git apply --cached`), never stash
  or reset. Commit and publish only when asked; the emulator repo then needs
  its `game-disassemblies` pointer moved in a commit of its own.
- **Credit.** Using someone else's map or names (tcdev and Michael R. Cook for
  Knight Lore, pobtastic for Atic Atac): take the facts, credit the person,
  write your own words. Unlicensed prose is never copied.

## The pipeline

Each build script's steps, and the traps each has already cost someone:

1. **Load the tape by running it.** `tap2sna` with a simulated load
   (`--start <entry>`, the tape path as a `file:` URI) runs the game's own
   loader, so encryption, protection and headerless blocks resolve themselves
   (Atic Atac decrypts itself this way). Find the entry point from the BASIC
   loader and write down in the notes what the loader does.
2. **Map code by running it.** Play the game in SkoolKit's simulator and record
   every address executed; that map has no false positives. Stage the scenes a
   playthrough would not reach (a death, a win, a rare event) by poking game
   state between runs -- `build_antattack.py`'s `_scene()` helpers. Then extend
   the map by recursive descent from what ran (`scripts/codemap.py`), which
   follows edges and invents nothing. Never mark bytes as code because they
   decode plausibly: the round trip cannot catch data dressed as code.
3. **Map > control files > skool > asm.** `sna2ctl` gives the bare map;
   `<game>_annotations.ctl` (committed) is layered over it; big tables are
   *generated* from the game's own data into further control files, one record
   per line. `sna2skool -H -I ListRefs=2 -c ... -c ...` then `skool2asm -H -c`.
   `ListRefs=2` matters: without it every described routine loses its
   "Used by" line.
4. **Round trip.** Assemble with `tools/sjasmplus/sjasmplus.exe` and compare
   with the loaded bytes; the build fails unless every byte matches. Also check
   the snapshot it writes is the one it read (Knight Lore's second line).
5. **`--html`.** `skool2html -a` with `<game>.ref`: prose pages, generated
   pages (rooms, sprites, sounds) built from the game's own data by running
   its own code. `LinkOperands=CALL,DEFW,DJNZ,JP,JR,LD` in `[Game]`; the
   routines list carries names after addresses via the `[Template:memory_map]`
   override in the existing refs.

### Control-file traps (all real, all silent)

- `  $ADDR,N` with the wrong N cuts an instruction in half and shifts every
  address after it. **Don't count N at all:** write the draft with
  instruction ranges, `  $A-$B Comment` (or `  $A Comment` for one
  instruction), and let `scripts/ctl_tools.py ranges SKOOL DRAFT OUT` fill in
  N from the listing -- three of Knight Lore's agents invented this
  independently, which is why it is a tool now. `scripts/ctl_tools.py check
  SKOOL FRAGMENT START END` checks a fragment before merging (boundaries,
  titles, labels, range). `check_annotations()` / `check_alignment()` in the
  builds name a bad line if one gets through.
- An indented comment line under `W $ADDR,n,2` is a new sub-block **of the
  block's type** -- in a `b` block the words come out as DEFB pairs. Put the
  comment on the `W` line itself (`W $8299,2 Handler for LOAD`).
- A second control file can add block boundaries but never remove them; use
  `; span $ADDR,LEN` (Atic Atac) to keep a table whole.
- `@equ` also makes its value a label, so every operand equal to it is
  renamed (`LD DE,7` became `LD DE,LOC_TROLLS_CAVE`). Write EQU lines into the
  .asm from the build instead, and use `@isub` for the operands you mean.
- `@isub`/`@ssub` change only the .asm, not the HTML; `skool2asm -H` turns
  every number hex, substituted ones too.
- **Warnings.** skool2asm warns about any number in a comment that falls in
  the disassembly's address range and is not a label -- in hex *or decimal*
  (42010 was flagged). Write addresses as `#R$ADDR` links to entries, or name
  the instruction ("the operand of the ADD at #R$D800") for self-modified
  bytes; give a table's second half an entry of its own if prose needs to
  point at it. An instruction that loads a constant which only looks like an
  address (`LD HL,$FE00`, a -512 step) gets `@ $ADDR nowarn`. Knight Lore went
  from 65 warnings to none this way.
- A borrowed map's labels (Knight Lore's `knightlore_structure.ctl`) are
  renamed from the annotations file: `@ $ADDR label=new` in a later control
  file overrides the earlier one. Leave the borrowed file as it came.

### Describing a big range in parallel

When hundreds of entries need describing, split the code by subsystem into
ranges of about 1000-2500 listing lines and give each to an agent with a
shared brief (the template is [`agent-brief.md`](agent-brief.md) beside this file: inputs read-only, one control-file
fragment and one notes draft each, into the scratchpad, no builds, no
emulator). Have them draft with instruction ranges and run
`scripts/ctl_tools.py ranges`, then `scripts/ctl_tools.py check` on the result
before handing back -- instruction-comment lengths that land on instruction
boundaries, every entry in the range titled, no label ending in `_digit`, no
duplicate or clashing labels, nothing outside the range. Pass on anything one
agent finds about another's range (a wrong existing annotation, a table's
real layout) with SendMessage while they are still working. Then merge the fragments into the
annotations file, build, and check every claim that corrects earlier work
before accepting it: agents disagree with the existing annotations and with
each other.
- Spans are `(start, end)`, never `(start, length)`; `check_structure()`
  enforces it. The round trip is blind to structure: a sliced table, an
  unaccounted gap or two blocks claiming the same bytes all still verify.

## Investigating live, in the emulator

Static reading says what code *can* do; the running game says what it *does*.
Use both, and say in the notes which one a claim rests on.

**Which server.** For checks of your own, a private `zx_server` (ports
14711/18000, `--no-audio`, killed by PID afterwards -- see the `zx-live-verify`
skill). When the user asks for something on *their* emulator (port 8000),
drive that one and leave it as you found it: say what breakpoints and
watchpoints you left set. Always load the snapshot you mean (original or
patched) and check which one is loaded before drawing conclusions.

**Drive by breakpoint, never by sleeping.** Find the addresses where the game
waits -- for a key, for a command, after a picture -- and break there. Each
stop is the game telling you it is ready. Timed sleeps race the game and fail
unpredictably. For a text adventure, stop where the line reader has set its
buffer pointer and inject the command into the buffer; for an arcade game,
break at the frame loop and hold keys across a known number of frames. Record
the addresses in `notes/<game>/driving.md` the first time you find them.

- **Find the per-frame breakpoint by watching it hit twice.** The routine
  named `game_loop` may run once; the frame loop re-enters somewhere below it
  (Knight Lore: `game_loop` $AFBA runs once, each frame starts again at
  `onscreen_loop` $AFBD). Stop, run, and check the same address stops you again
  before building a script on it.
- **Every wait in a script is bounded.** Poll `get_state` with a time limit; on
  timeout, pause and report PC, its symbol and the call stack, then fail. Run
  scripts with `python -u`: a buffered script killed by a timeout prints
  nothing at all, which looks like a hang with no clue where.
- `load_debug_info` takes `sld_path` and `asm_path` (both); until it is loaded,
  `resolve_address` answers with ROM symbols (`CHINFO+22094`), which is wrong
  rather than missing.
- Release every key after loading a snapshot: keys stay held across loads.
- A key held into the game's "wait until keys are released" loop hangs it.
  Let go at a breakpoint just past where the key is read.
- Breakpoint-driven input is exactly repeatable, so the random number
  generator plays out the same every restart. To vary a run, change the input
  (an extra turn), not the restart.

**Ask the machine who did it.**
- `set_watchpoint` on a variable, `on_change` -- stops at the instruction after
  the write, with old and new values and the writer's address. The fastest
  way to answer "what changes X".
- `set_logpoint` at a routine with `{A}`, `{(HL)}`, `{(LABEL+n):w}` holes --
  a trace that does not stop the game. `get_log` reads it back.
- `run_back_to_write` -- rewind to whoever last wrote an address; then
  `return_to_live`. History is about 40 seconds; if it finds nothing, reproduce
  the event with a watchpoint instead of trusting the miss.
- `save_snapshot` to a `.z80` at a known point (the first prompt, a level
  start) so every experiment starts identically; `.sna` pushes PC onto the
  game's stack.

**Staging state by poking.** Fine for experiments, but read the game's
variables first, verify each write took, and remember what a shortcut skips:
teleporting the player by writing its location skips the arrival routine (and
any score or trigger in it) and leaves carried objects behind; giving an
object by its holder byte may also need its location; light, visibility and
reach checks may look at fields you did not write. When a staged test and a
real playthrough disagree, the playthrough wins -- and the user will want a
real playthrough when the claim is about how the game plays.

**A staged test can be spoiled by the game.** Record lives (or whatever death
changes) before and after, and clear hostile objects out of the room first:
Knight Lore's first push test "passed through" a block only because a ghost
killed the player and he respawned at the door. And a state a script leaves
the game in -- paused, dead, in a menu -- is still there for the next script:
start each experiment from a snapshot load, not from wherever the last one
stopped.

**Screenshots.** On a machine stopped at a breakpoint, `get_screen` shows the
CRT at that instant (this frame down to the beam, a dashed beam marker), so
text printed after the beam passed is missing or torn. Draw the picture from
screen memory instead: `read_memory` $4000, 6912 bytes, plus the border from
`get_state`, decoded with PIL. The user is often away from the machine: send
screenshots with SendUserFile at each step that matters.

## Static techniques that settle questions

- **Every access to a variable.** Search the whole snapshot for its address as
  the Z80 stores it, low byte first (`F7 B6` for `$B6F7`), and name the
  instruction each hit is in. Then rule out the other routes: the high byte's
  own address, the address built a byte at a time (`LD H,$B6` / `LD L,$F7`),
  pointers to a neighbour plus arithmetic, and block copies (`LDIR` whose range
  covers it -- save/load and restart-state copies usually do). Check each hit
  really is an operand: `F1 B6` in the Hobbit's picture code is `POP AF`,
  `OR (HL)`.
- **Indirect dispatch.** `JP (HL)` tables and handler words give their targets
  no "Used by" line. Show the table as `DEFW` with each entry linking to its
  routine, and describe in the target's heading which table reaches it.
- **Compare versions.** Load each release (`tap2sna` into the scratchpad) and
  compare byte ranges; find the moved equivalent of a routine by its
  instruction pattern (`2A nn nn 19 22 nn nn` was the score add). Settle "which
  version is this" from the code, and write what differs into the notes.
- **Use the game's own code as the instrument** -- to draw a room, render a
  sprite, record a sound -- on a fresh machine each time, and measure extents
  by logging which bytes it reads. Knight Lore's `knightlore_pages.py` is the
  worked example: it runs main's set-up routines in SkoolKit's simulator
  (skipping the menu), then `build_screen_objects` and one frame per room,
  and draws scenery and templates on their own by writing a one-off room
  record where the room finder looks first. What that took:
  - **Carry the registers from one call to the next.** A routine may find its
    data through a register an earlier one left set (IX on the player's
    record); calling each on a fresh simulator gave empty rooms with no error.
  - **Stop where the picture is actually complete, and read it from where it
    is.** The first stop point was before the new-room copy; the panel turned
    out to be drawn into the same buffer as the room. Read the code between
    the build and the display copy, then stop just before the panel and decode
    the buffer (its own layout: bottom line first) rather than the screen.
  - **A one-off scene inherits the game's state.** A borrowed room number
    brought its charm along; pick values nothing else refers to. And the
    game's own checks react to what you changed: emptying the player's
    records to keep him out of the pictures was fine for one frame, but a
    trace that ran on hit `next_frame_or_die`, which read it as a death and
    restarted in another room.
  - **To follow a frame through a pipeline,** stop at each stage's address in
    turn (the simulator runs at least one instruction before it checks the
    stop, so stopping at the same routine repeatedly catches every call), and
    read what the game left: rectangles off the stack where it pushed them,
    the object being drawn from IX.
  - Look at every generated picture before believing it: three of these four
    failures were black or wrong images from a build that reported success.
- **Look at the pages as a reader will.** Headless Edge screenshots a built
  page: `msedge.exe --headless --disable-gpu --window-size=1100,1600
  --user-data-dir=<scratch> --screenshot=<png> file:///<page>` (the old
  `--headless`, and its own profile directory, or it writes nothing).

## Rules of evidence

These each cost a published mistake (details in `docs/game-examples.md`):

- **Draw a thing before naming it.** A "title screen font" was the status
  panel with its dimensions transposed.
- **Measure, don't infer; get lengths from the data.** `range(149)` over a
  151-entry table hid two entries. A bound that is too small raises no error.
- **An instrument only measures inside its domain.** Feeding every code to one
  drawing routine measured that routine, not the data. Explain a residue
  before naming it.
- **A base address inside a table is not a trick** until the tables' lengths
  rule out simpler layouts.
- **A description is a claim.** When you find one wrong (the Hobbit's "Elrond
  has read the map" flag that nothing ever sets), fix the annotation, say how
  it was checked, and log the correction in the notes.
- **Claims from outside are hypotheses.** "Picking up the golden key scores
  points" was tested live, by watchpoint, by searching the binary and across
  every version before being answered -- and the answer was no. Report what
  was tested and how, not just the verdict.

## Notes

Keep a written record of the game in `game-disassemblies/notes/<game>/`,
**as you go**: a finding goes into the notes in the same session it is made,
before moving on, so the next session (or the user reading on their phone)
has it even if the HTML is never rebuilt. The HTML's prose pages are the
polished, published form; the notes are the working account the pages are
written from, and they keep what the pages leave out -- how things were found,
what was wrong, what is still open.

The model to follow is the `analysis/` folder of Ville Krumlinde's Fairlight
disassembly (<https://github.com/VilleKrumlinde/FairlightZ80>; a clone may be
at `game-disassemblies/.fairlight-disassembly-src/`): an overview that tours
the highlights and links to a deep dive per subject, and deep dives that each
answer one question, say how the answer was found, and separate what is
confirmed from what is inferred and what is still open.

Layout (create what the game needs; the first four always):

| File | What goes in it |
|---|---|
| `README.md` | What the game is (title, year, authors, the tape and version disassembled), current status and coverage, and an index of every note with a line on each |
| `overview.md` | **Start here.** A one-page tour of the most interesting findings: a short section per subject -- a paragraph or a small table -- ending in a link to its deep dive |
| `journal.md` | Dated entries, newest last: what was investigated, how, what was found, what turned out wrong. Short; it is the history, not the explanation |
| `driving.md` | How to drive the game in the emulator: snapshots to load, the breakpoints that mean "ready for input" and "waiting for a key", how to inject a command or hold a key, known hangs, how to stage common states, and the addresses of the key variables |
| `memory-map.md` | Where things are: code, tables, variables, buffers, the stack -- by address, with labels; what is code, what is data, and what is still unaccounted for |
| topic files | One per subject, named for it: `loading.md`, `main-loop.md`, `scoring.md`, `room-format.md`, `sprites.md`, `collision.md`, `versions.md` ... |

Each topic file follows the same shape, so a reader always knows where to
look:

```markdown
# Scoring

**Question this answers:** where the score comes from, and whether 100% is
reachable.

**Short answer:** ... (two or three sentences)

## How it works
The mechanism: the routines in call order (an ASCII call chain helps), record
layouts and opcode sets as tables (offset | field; value | meaning), the
variables involved, by label and address.

## How this was found
What was read, searched, traced or played, in the order it happened -- the
clue that cracked it, and the dead ends worth not repeating.

## Confidence
What is confirmed, and by what (read / watched / measured / played); what is
inferred and why it is believed; anything that rests on one observation.

## Renamed routines          (when names changed)
| New name | Old name | Address | Role |

## Disassembly corrections    (when the listing or a description was wrong)
What it said, what it says now, what showed it.

## Open questions
Seen but not understood, and what would settle each.
```

How to write them:

- **One question per file.** Name the question at the top; if a file starts
  answering two, split it. Link back to the file whose open question led here.
- **Say how each fact is known.** Tag claims *read* (from the code), *watched*
  (watchpoint, logpoint, rewind in a running game), *measured* (instrumented
  run over many cases), *played* (seen in a real playthrough) or *assumed*.
  Give the address and the label.
- **Pictures stay off master.** Fairlight's notes embed renders of the game's
  graphics; ours cannot, since they are the game's content. Describe the
  picture and link to the HTML page that shows it (the build generates those
  pages from the game's own bytes).
- **Record corrections, don't overwrite them silently.** When something turns
  out wrong, fix the topic file and add a journal line saying what it used to
  say and what showed it wrong.
- **Answer questions in the notes too.** When the user asks something about the
  game and it gets settled ("where does the score come from?"), the answer and
  the evidence go in the relevant topic file, not just the chat.
- **Prose, addresses and names only** -- the copyright rule above applies.
  Describe a message or picture; don't reproduce it.
- **Link, don't duplicate.** Point at the routine by label rather than
  re-describing what its annotation already says; the notes carry the
  cross-cutting explanation the per-routine comments can't.

At the end of a session of reverse engineering, check: every new finding is in
a topic file, the journal has the day's entry, `driving.md` has any new
addresses, `overview.md` has a section for anything new worth touring, the
README's index lists every file, and each topic's open questions are current.

## Finishing a game

- Coverage at 100%: every byte in a block, every routine named and described,
  every address a label, the round trip green, `check_structure` clean, no new
  build warnings.
- The README table and `docs/game-examples.md` describe the build; the notes
  describe the game.
- `--html` built and looked at (routines list, a few routine pages, every
  generated page). Publish with `scripts/publish_pages.py --game <game>` only
  when asked, then move the emulator repo's submodule pointer.
