# Plan: a shared library of movers

Status: **decided; stage 1 committed (69d7d6e), stage 2 done and
uncommitted** (2026-09-22). This file is the brief
for the session that does the work. It records what was found, what is
proposed, and what the user decided.

## Decided (2026-09-22)

1. **Scope:** stages 1 and 2. Stage 3 is not part of this work.
2. **Hooks:** constants and hook labels supplied by the game are acceptable
   under the no-per-game-options rule. They have no defaults, and there are no
   `IFDEF` switches inside the library.
3. **Style:** engine/movers.s uses tabs. Pentagram's movers.s keeps its spaces,
   and only its calls change.

## Stage 1: done, uncommitted (2026-09-22)

- **engine/movers.s** holds `mover_find`, `mover_falls`, `mover_falls_noisy`,
  `mover_sinks`, `player_on_top`, `object_hide` and `object_blank`, each in
  `IFUSED`. It is included after engine/mover.s, so Knight Lore's
  `mover_slide` still falls into `mover_move` and needs no `jp`.
- **No new hooks, one new name.** `mover_sinks` sounds the game's `sound_z`,
  which walker.s already asks for; Pentagram's is a bare `ret`.
  `mover_falls_noisy` calls the game's `sound_falls`, which Knight Lore equates
  to `sound_chirp`, and falls into `mover_falls`. An `ASSERT $ == mover_falls`
  keeps the two together and, because it names the label, makes `IFUSED`
  keep `mover_falls` for a game that names only the noisy one. Pentagram never
  names it, so it needs no `sound_falls`.
- **Merged:** Knight Lore's `special_hide`/`special_blank` and Pentagram's
  `object_hide`/`flyer_blank` were the same code. Both games now call
  `object_hide`/`object_blank`.
- **Bytes.** The moved routines assemble to the same opcodes as before, and
  only address operands differ, apart from Pentagram's `mover_sinks`: it gained
  the 9-byte "sound while going down" test. Knight Lore's code size is
  unchanged (4 free below the stack). Pentagram's code is 9 bytes larger. That
  also pushes the player's record, which is `ALIGN 32`, 10 bytes further, so
  the pad in front of the page-aligned `sprite_adj_index` went from 92 bytes
  to 73. "Free below the stack" still prints 9, because that pad absorbs the
  growth. **That pad is Pentagram's real headroom in the code region, not the
  printed figure.**
- **Tests.** engine/tests/movers_tests.s (17 tests) covers the library.
  pentagram/tests/movers_tests.s (12) is new. It checks Pentagram's
  `mover_of`/`mover_tbl` reach the shared routines, through `movers_step` too,
  and covers the crumbling block and the lift. run_tests.py now writes each
  suite's output to its own folder under output/tests, because two suites
  share the name `movers_tests`; `movers` runs all three, and
  `pentagram/movers` runs one.
- **Not done in stage 1:** `mover_collapsing`/`mover_crumbles` (stood-on-then-
  gone) is a stage 2 family, and both still sit in their games.

## Stage 2: done, uncommitted (2026-09-22)

- **The pacer.** `mover_pacer_u`/`_v` fall into `mover_pacer`, which falls
  into `mover_turn_if_hit`. Those are Knight Lore's fires and Pentagram's
  platforms and pacing dragon's heads. The axis is still patched in, as both
  games had it. The game supplies `PACER_STEP`, `pacer_sound` (called with L
  the axis), `pacer_frame`, `pacer_move` and `mover_turned` (A the axis).
  Knight Lore's guard still uses `mover_turn_if_hit` from its own movers.
  Pentagram's dragon's heads go through `mover_pace_u_deadly`/`_v_deadly`,
  which sit a turn out in a busy room and then jump to the pacer, so the
  platforms no longer test their behaviour on every turn.
- **The hopper.** `mover_hopper_claim` falls into `mover_hopper`. Those are
  Knight Lore's balls and Pentagram's bobbing dragon's head. The claim is
  Knight Lore's "first ball sets the room's top" rule, and Pentagram never
  names it. The game supplies `hopper_top` (a byte), `HOPPER_RISE`,
  `HOPPER_ABOVE` (claim only), `hopper_frame`, `hopper_sound`, `hopper_move`
  and `hopper_landed`. The two games tested the top the other way round:
  Knight Lore rises while Z is at most the top, and Pentagram stops at Z 176
  or more. So Pentagram's `hopper_top` is 175, which gives the same stopping
  point. Pentagram's rising bit moved from MOVE_STATE bit 0 to bit 2,
  `HOPPER_RISING`, which is Knight Lore's and the originals'. Nothing else
  reads it.
- **Each game's names are in its own `shared_movers.s`,** included between
  engine/mover.s and engine/movers.s. An EQU of a label still to come takes
  the previous pass's value, and IFUSED moves code between the early passes,
  so sjasmplus warned (4 warnings) until they moved after mover.s. Most are
  EQUs to a routine the game already has (`mover_flicker`,
  `mover_move_always`, `sound_z`, `sound_bounce`) or to Pentagram's
  `mover_still`, a RET. Knight Lore's two pieces of real glue, `pacer_sound`
  and `mover_turned`, are in sound_fx.s and fall into `sound_v` and
  `sound_bounce`.
- **Bytes.** Knight Lore's code region went from 4 free to 14. Its `$6000`
  region, where sound_fx.s is, went from 21 to 10. Pentagram's code grew 22
  bytes, from the dragon's heads' wrappers, `pacer_move` and hook calls that
  reach a RET. The player's `ALIGN 32` record moved another 10, so the pad
  before `sprite_adj_index` went from 73 to 41.
- **Tests.** The engine suite has 11 new tests (28 in all): the pacer's step,
  sound, frame, turn and "no turn", and the hopper's claim, fall, landing and
  both edges of the top. Pentagram's suite has 10 new ones (22): table entries,
  a platform never sitting out, a dragon's head sitting out and pacing, and
  the bobbing head at 174 to 175 and 175 to 176. Knight Lore's 63 run through
  the shared routines unchanged. All 226 pass, and both games build with no
  warnings.
- **Left in the games, on purpose:**
  - **Stood-on-then-gone.** Knight Lore's collapsing block is set off by
    anything landing on it, goes on once started, jumps straight to its last
    graphic, sparkles and is gone the next turn. Pentagram's crumbling block
    is set off only by the player standing on it, steps 136 to 139 every
    fourth turn only while he stays, and is silent. Only the "gone" is shared,
    and that is `object_hide` already. One routine would be all hooks, and it
    would cost Knight Lore about 11 bytes it does not have.
  - **Straight until blocked, then re-pick** (the ghost, spider, creature and
    faller). Each re-picks differently: both axes or one, how far, which way it
    faces, and its frames. The shared part is "if stopped or still, pick; then
    move", which is a few instructions. As the brief allowed, they stay.

## The goal

Give the engine the set of object behaviours ("movers") that Knight Lore and
Pentagram use between them, as one library the games include. A game should
pick behaviours from the library rather than write its own copy. That means a
third game gets the union for free, and a fix lands in one place.

## The questions that were put to the user

1. **Scope.** Are all three stages below in the scope, or stages 1 and 2 only?
2. **Hooks.** The library would need things from each game: named constants
   such as `PACE_STEP` and `HOPPER_TOP`, and hook labels such as a sound to play
   on a turn. That is how the engine already asks games for things (see "What a
   game supplies" in [README.md](README.md)), and it adds no per-game switch
   inside the engine. But it is a new requirement on every game.

   The standing rule is that the engine has no per-game options, and games
   adapt in their own code and data. Confirm that constants plus hooks are
   acceptable under it. Note that `walker.s` already bends the rule, with
   `IFDEF CHARACTER_SHORT_WALK` and `IFDEF CHARACTER_MIRRORED_ART`.
3. **Style.** The library follows the engine's own formatting, which is tabs
   (as in Knight Lore). Pentagram's movers are written with spaces. Its calls
   change, and its own movers.s can stay as it is.

## How movers work today

Every reference below is relative to `examples/filmation/`.

- **Behaviour is chosen per template, when the room is built.**
  - `mover_find` looks the template up in the game's `mover_of` table: pairs of
    (template, behaviour), ended by `$FF`.
  - The code is the same in both games (knightlore/movers.s:177,
    pentagram/movers.s:124). Only the indentation differs.
  - The result goes into `OBJ.BEHAVIOUR` through `room_behaviour`
    ([README.md](README.md), under "What a game supplies").
- **The behaviour number is an ordered enum.**
  - The engine only compares it against band edges. The bands, in order, are
    `BEHAVIOUR_FIRST_TURN`, `DEADLY`, `CRUSHING`, `HARMLESS`, `GIVES`,
    `GIVES_LAST` and `LOOSE`.
  - Each game numbers its behaviours to fit those bands, and the two orders
    differ (knightlore/movers.s:17-83, pentagram/movers.s:38-86).
  - **`mover_tbl` and `mover_of` therefore stay per game.** Only the routines
    they point at move into the library.
- **Dispatch.**
  - `movers_step` (engine/mover.s) jumps through `mover_tbl[behaviour - FIRST]`
    with IX pointing at the record.
  - A mover may corrupt any register, must leave the stack balanced, and
    returns normally.
  - After anything that can lose IX, reload it from `mover_ix`.
- **What the engine already provides (engine/mover.s):**
  - moving: `mover_move`, `mover_move_always`, `mover_paint`, `mover_clamp`;
  - steps: `mover_hover`, `mover_halt`, `mover_flicker`, `mover_cycle4`;
  - two-record figures: `mover_move_pair`;
  - randomness: `mover_rand`, `mover_dice`, `mover_stir`;
  - state: `move_tick`, `mover_ix`.
  - From walker.s, movers use only `obj_pair_flip` and
    `character_door_find.abs`.
- **Include order.** Each game includes its movers.s immediately before
  engine/mover.s (knightlore/knightlore.s:119-120, pentagram/pentagram.s:135-136).
  - Knight Lore's `mover_slide` falls through into `mover_move`, and an
    `ASSERT $ == mover_move` enforces it (knightlore/movers.s:924-926). Moving
    either routine breaks that. Replace the fall-through with a `jp`.
  - The comment at pentagram.s:136 said its movers fall into mover.s. They no
    longer do, because the file ends in data, and stage 1 took the comment off.

## The behaviours, and how they overlap

| | Knight Lore (knightlore/movers.s) | Pentagram (pentagram/movers.s) |
|---|---|---|
| Identical | `mover_find` | `mover_find` |
| Same except KL's sound | `mover_dropping` 836 (`sound_z`) | `mover_sinks` 927 |
| Same except KL's sound | `mover_carried` 558 (`sound_chirp`) | `mover_falls` 308 |
| Pacer, axis patched into the code | `mover_fire_u/_v` 207: step 1, flickers, u/v sounds, `move_always`, turns via `mover_turn_if_hit` (bounce sound) | `mover_pace_u/_v` 264: step 2, no animation, `move`, turns inline, busy-room sit-out |
| Vertical bounce | `mover_ball` 269: top is the room's first ball Z + 32, DZ 3 | `mover_hopper` 482: top is Z 176, rises 1 |
| Stood on, then gone | `mover_collapsing` 851: landed-on bit, straight to graphic 185, then `special_hide` | `mover_crumbles` 944: `player_on_top`, frames 136-139 every 4 turns, then `object_hide` |
| Straight until blocked, then re-pick | `mover_ghost` 575: both axes ±3/±4 | `mover_spider` 426, `mover_creature` 513, `mover_faller` 673: one axis, their own facing rules |
| Homes on the player | `mover_spell` 767: moves by sign, 4 frames | `mover_homer` 568: velocity in 1/16ths, bounces off walls |
| Pushed | `mover_pushed` 659 | `mover_pushed` 337: also rests every 4th turn, and carries what stands on it |
| Busy-room sit-out | `monster_gate` (monster_gate.s), a second dispatch | `monster_sits_out` inline, `MONSTER_KEEP_SPEED` |
| Only this game | guards (paired figures) 326-455, portcullis 477, `mover_bounce` 692 (werewolf-aware), spike ball 803, sliding block 885, collectables and cauldron (special.s) | lift 969, conveyor 1012, bolt 737, puff 847, `player_on_top` 888, `object_hide` 875; well, water and quest items (quest.s); flyers (flyers.s) |

## What stands in the way of simply moving code

- **Sounds.** Knight Lore's movers call about ten effects: `sound_u`, `_v`,
  `_uvz`, `_z`, `_bounce`, `_take`, `_chirp`, `_gate`, `_step` and `_sparkle`.
  Pentagram's `sound_z` is a bare `ret`, and it has none of the others.
- **Game state read inside movers.**
  - Knight Lore: room `$88` and the player's `CHARACTER_DOOR` in the spell; the
    werewolf test in the bounce; `spike_ball_held`; the gate's busy and drop
    state; `mover_ball_top`.
  - Pentagram: `room_busy`, the flyer slots, the player's `CHARACTER_DZ` in the
    lift, `score_add`, and quest state.
- **Hard-coded graphics.** Knight Lore's 185; Pentagram's crumble frames
  136-139, the puff 64-70 and the bolt 149-151.
- **The record's spare bytes and bits.**
  - The two games use `MOVE_STATE` bits differently: the bounce is bit 2 in
    Knight Lore and bit 0 in Pentagram; Pentagram's bit 7 means "falling".
  - Pentagram also keeps state in bytes 30-31, past the end of OBJ.
  - A library routine must name which bits and bytes it owns.
- **Self-modifying code.** Knight Lore's pacers patch their own axis and step,
  and the bounce patches an opcode. That is fine, since movers run from RAM,
  but a shared routine that patches itself can be shared by only one set of
  constants.

## Proposed design

- **One file, engine/movers.s**, with the library routines. Include it beside
  engine/mover.s.
- **Wrap every routine in sjasmplus `IFUSED label` ... `ENDIF`.** A game then
  assembles only the movers its `mover_tbl` names. There are no per-game
  switches, and an unused mover costs no bytes.
  - Checked on the repo's sjasmplus (v1.23.1): an unused routine drops out and
    a used one stays.
  - Watch for routines reached only by `jp` from another library routine:
    `IFUSED` counts that as a use, which is what we want.
- **Game-specific values come from the game:**
  - constants the game defines, with no defaults in the library, so a missing
    one is an assembler error rather than a silent guess;
  - hook labels the game supplies, for example `on_pacer_turn` and
    `on_sink_step`. A game that wants nothing points them at a `ret`.
  - Document every constant and hook in engine/README.md, under "What a game
    supplies".
- **Behaviours bound to one game stay in that game:** collectables, cauldron,
  quest, well, water, bolt scoring, flyers, and the werewolf-aware bounce. They
  keep calling the engine's building blocks.

## Stages

Each stage is finished before the next starts: built, tested, checked live, and
committed on the user's say-so.

1. **Identical and near-identical.**
   - `mover_find`.
   - Sink/drop, with a hook for Knight Lore's `sound_z`.
   - Fall/carried, with a hook for `sound_chirp`.
   - `player_on_top`.
   - A generic `object_hide`. Pentagram's also calls `flyer_blank`, so that
     becomes a hook; compare it with Knight Lore's `special_hide`.
2. **The families, parameterised.**
   - The pacer: its step is a game constant, and its animate/sound turn is a
     hook. Decide how to keep the axis patching, or replace it with an axis
     carried in `MOVE_STATE`.
   - The vertical bounce: the top rule is a hook or constant.
   - Stood-on-then-gone: the frames and the rate are constants.
   - Possibly one "straight until blocked, re-pick" core for the ghost, spider,
     creature and faller, with the re-pick rule as the game's own. Only do this
     if it really simplifies things; otherwise leave them where they are.
3. **The single-game behaviours that are plainly generic,** so any game can use
   them: lift, conveyor, portcullis, the paired-figure guards, spike ball and
   sliding block.

## How to check each stage

- **Unit tests.**
  - `.\.venv-win\Scripts\python.exe examples\filmation\engine\tests\run_tests.py`
    runs the engine's tests (engine/tests/mover_tests.s among them) and Knight
    Lore's (knightlore/tests/movers_tests.s: 63 tests).
  - Pentagram has no tests folder. Add pentagram/tests/movers_tests.s for
    whatever of Pentagram's moves, following knightlore/tests, and register it
    in run_tests.py.
  - Test the library routines themselves in engine/tests.
  - Work expected values out from the code and the original's behaviour; never
    capture them from the output (AGENTS.md).
- **Builds.** `knightlore/build.py` and `pentagram/build.py`, with no new
  warnings.
  - The images will not stay byte-identical, because code moves.
  - For stage 1 it is worth showing that the *moved* routines assemble to the
    same bytes. Compare the routine's bytes in the two listings (`output/*.lst`).
- **Live.** Load each game in zx_server and drive it over MCP. Visit rooms with
  each moved behaviour, watch and take screenshots, uncapped while scripting.
  - Room numbers and keys are in knightlore/driving.md and
    pentagram/driving.md.
  - Stage state by polling the game's own variables (see those files).
- **Memory.** Both games are tight, Pentagram especially: a busy room already
  sheds work. Report each region's `DISPLAY` of space left before and after.
  `IFUSED` should keep the cost at or below today's.

## Not in this plan

- Showing animated objects in the room designer. It was discussed and left for
  now.
- Show Graphics' Import of the new sprites.json. That is parked.
- engine/memory-128k.md, the 128K layout, belongs to other work.
