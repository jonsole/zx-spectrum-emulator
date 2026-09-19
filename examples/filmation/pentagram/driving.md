# Driving Pentagram: the original and the remake

How to play both games, and how to put either one into a given state in the
emulator for testing: which bytes to write, and in what order. The addresses
for the original come from its own code. The remake's are symbols, which move
with every build, so they're always read from `output/pentagram.sld`.

1. [Playing](#1-playing)
2. [Running either game in the emulator](#2-running-either-game-in-the-emulator)
3. [The original](#3-the-original)
4. [The remake](#4-the-remake)
5. [Setting things up in the remake](#5-setting-things-up-in-the-remake)
6. [Rooms worth knowing](#6-rooms-worth-knowing)
7. [Pitfalls](#7-pitfalls)

---

## 1. Playing

The remake reads the keys the way the original does, so these are the same in
both.

**Menu**

| Key | Does |
|---|---|
| 1 | keyboard |
| 2 | Kempston joystick |
| 3 | cursor joystick |
| 4 | Interface II |
| 0 | start the game |

The way you chose flashes. The title tune plays the first time the menu is
shown, and any key cuts it short.

**Keyboard.** Control is rotational only: turn, then walk.

| Keys | Does |
|---|---|
| Z, C, M, B | turn left a quarter |
| X, V, SYMBOL SHIFT, N | turn right a quarter |
| A to ENTER, the whole middle row | walk the way he faces |
| Q, E, T, U, O | jump, always forwards |
| W, R, Y, I, P | fire |
| 1 to 0 | pick up, or put down |
| SPACE, on its own | pause; SPACE again to go on |

The top row takes the keys one by one, jump and fire in turn, because the
original reads each half of it separately ($BEC8, $BEE7).

**Joysticks**

| Input | Does |
|---|---|
| left, right | turn |
| up | walk |
| down | jump |
| fire | fire |
| bottom-row keys (Z to V, B to SYMBOL SHIFT) | pick up, or put down |

The cursor keys are 5 left, 8 right, 7 up, 6 down and 0 fire. Interface II is
6 to 0 for the first stick and 1 to 5 for the second.

**Picking up and putting down.** One press does whichever fits:
- It picks up something beside or under him: the bucket, or a collectable.
- If there's nothing to pick up, it puts down the oldest thing he's carrying,
  under himself, and he ends up standing on it, if there's headroom.
- It only works while he's standing on something, not in the air, and not in a
  doorway.
- He carries up to three things. They show on the panel, bottom left.
- Every press plays the take jingle, as in the original.

## 2. Running either game in the emulator

- **Load over DAP.** Send `launch` with the ROM and a snapshot, then
  `configurationDone`. The machine is left paused, so start it with the MCP
  `run` tool (`wait: false`) or a DAP `continue`. Forgetting this is why a
  "loaded" game sits still, and why the screen shows whatever was there before.
- **Speed.** Use `set_speed realtime` when handing over to a person, and
  uncapped for your own scripted runs. A slowed machine makes timed scripts miss.
- **Writes.** Write memory over DAP (`writeMemory`) or MCP (`write_memory`).
  Pause first if the write has to land between two particular turns.
- **Breakpoints.** A breakpoint at $80A3 has turned up in the server more than
  once without being set by any script, possibly left from a VS Code session.
  Check `get_state().breakpoints` if the game stops for no reason.
- **Watching.** `get_screen_sequence` on a paused machine steps it forward and
  returns the frames: the way to see something that's over in half a second.

---

## 3. The original

The snapshot is `snapshots/Pentagram-clean.sna`, which starts at the menu. Press
0 to start. The ROM is `roms/48.rom`.

### The player

The player's record starts at **$A76F**; his body is the next record, $A78F.
Each record is 32 bytes:

| Offset | Holds |
|---|---|
| +0 | graphic |
| +1, +2, +3 | U, V, Z |
| +4, +5, +6 | size in U, V, Z |
| +7 | flags |
| +8 | the room; **$A777** for him |
| +9, +A, +B | the step in U, V, Z |
| +C | collision bits |
| +D | deadly bits: 7 kills what it moves into, 5 kills what touches it, 6 means killed |
| +12, +13 | drawing nudge, X then Y |

Setting bit 6 of +D ($A77C) kills him.

### State

| Address | Holds |
|---|---|
| $A721 | lives, in BCD |
| $A744–$A746 | score, in BCD |
| $A715 | the turn counter |
| $A70D | the random word |
| $A73D | the drop timer: set it to 1 and something drops within a turn or two; it resets after a drop |
| $A742 | 1 bans drops in this room; $CB89 sets it for the well (120), a quest item (112–119) or a pentagram piece (128–135) |
| $CC09 | what a drop can be: 8 graphics, one picked at random |
| $A7EF, $A80F | the two flyer slots |
| $A70E | the bucket is out, so the well won't give another |
| $A70F | the pentagram is in room 82 |
| $A74C | quest items done |
| $A74B | collectables placed |
| $A722–$A731 | carried things: four entries of graphic, flags and a 2-byte link to the persistent record; $A72E is the one put down next |

The persistent records are at **$D432**, 18 of 16 bytes each: graphic, U, V,
Z, sizes, flags at +7 and the room at +8. They're copied from $D312 at every
new game. Numbers 0–3 are the quest items, 4–8 the collectables, 9–16 the
pentagram's pieces, and 17 the bucket, which makes its link $D542. The
collectables start at 5 of the 20 spots at $D1A5 and fly to the targets at
$D562.

### Getting into a room

This is the reliable way:
1. Write the room to both **$A777** and **$C407**. $C407 is the room byte of
   the 64-byte player template at $C3FF, which $C2EC copies back over him
   whenever he restarts a room.
2. Kill him by setting bit 6 of $A77C.

He comes back in that room, built by the game itself. It costs a life, so put
some back at $A721.

Don't rely on writing the room at the builder, $C92F. It matches rooms against
(IX+8), and doing that has built the start room anyway. After any setup, check
that the scenery on screen is the room you wanted.

The start rooms are the table at $C2E8: 51, 92, 100 and 12. The snapshot
usually starts in 92.

### Handing him the bucket

Before a room is entered, write `5A 14 42 D5` at $A72E (graphic 90, the flags
the well gives it, and the link to record 17) and 1 at $A70E. He's then
carrying it, and a number key puts it down.

### Where things are in the code

| Address | What |
|---|---|
| $AFB6–$B00C | the main loop |
| $AE2F | the update routine for each graphic, a word each, called from $B001 |
| $BB74 | the menu |
| $C302, $C323 | the win, then the game over |
| $B4E0 | the pause |
| $B952 | reads a half-row of the keyboard |
| $C74B–$C77F | the drawing-nudge routines: $C75F gives -16, -8; $C775 -12, -6; $C77A -12, -4 |
| $D5D7–$D718 | the sounds |
| $D718 | the note table |
| $D7CF | the tunes |

## 4. The remake

Build with `python build.py` in this folder. That writes `output/pentagram.z80`
and `output/pentagram.sld`. Every address below is a symbol, so look it up in
the SLD after each build:

```sh
grep -E "\|F\|room_number$" output/pentagram.sld | cut -d'|' -f6
```

### Symbols

| Symbol | What |
|---|---|
| `room_number` | Write a room here and the main loop builds it on its next turn. |
| `room_shown` | The room that's built. **Don't write it**: on leaving a room, the quest records are filed under this number, so a wrong value loses them. |
| `enter_dir` | The side he comes in by: 0 N, 1 E, 2 S, 3 W. $FF puts him at the start position in the middle. Use a side the room has a doorway on; otherwise he's put on the wall line, half outside the room. |
| `player` | The legs record; the body is 32 bytes on. `player + 65` is his state (bit 0: in the air), +66 his facing, 0 to 3, +67 his step in the walk cycle. |
| `player_lives` | lives, in BCD |
| `player_touched` | 1 kills him on his next turn |
| `score` | three bytes, BCD |
| `quest_table` | 18 records of 8 bytes: graphic, U, V, Z, size U, V, Z, room. Room $FF means he's carrying it. Numbers as in the original: 0–3 the quest items, 4–8 the collectables, 9–16 the pieces, 17 the bucket. |
| `quest_carry` | three record numbers, newest first, $FF for none; +2 is put down next |
| `quest_done`, `quest_placed` | quest items done, collectables placed |
| `quest_pieces_on`, `quest_water_out`, `quest_won` | flags; `quest_won` = 1 shows the win screen next turn |
| `rooms_seen` | a bit for each room, 32 bytes, for the percentage. More than 255 bits set wraps the count. |
| `flyer_slots` | points at the two flyer records, which the two bolt records follow |
| `flyer_timer`, `flyer_banned` | the drop wait, and whether this room drops anything |
| `room_objects`, `room_object_count` | the object pool, 32 bytes a record |
| `quest_first`, `quest_slots` | the first quest record in the pool, and how many (spares included) |
| `room_busy` | 0 when quiet, or the period monsters sit out: 4, 3 or 2 |
| `move_tick`, `menu_mode`, `input_now` | the turn counter, the menu's choice, the keys this turn |

### A record in the pool

| Offset | Field |
|---|---|
| 2–5 | its box on screen: MIN_Y, MAX_Y, MIN_X, MAX_X |
| 6 | FLAGS |
| 10, 11 | its rotation buffer |
| 12, 13, 14 | U, V, Z |
| 17, 18, 19 | half-sizes |
| 20, 21 | drawing nudge |
| 22 | GFX |
| 23, 24, 25 | DU, DV, DZ |
| 27 | BEHAVIOUR (see `movers.s`) |
| 28 | MOVE_STATE |
| 30, 31 | a mover's own: the homer's sixteenths, the bucket's target; 31 is also a quest record's number, `QUEST_INDEX` |

### Test switches

| Switch | Where | Does |
|---|---|---|
| `FLYER_NOW` | `flyers.s` | 1 drops things at once. For testing only; commit it at 0. |
| `BUSY_BORDER` | `flyers.s` | 1 colours the border by `room_busy`. Every sound resets it to black. Turn it off for a release. |
| `MONSTER_KEEP_SPEED` | `movers.s` | 1: busy monsters take double steps. 0: they slow down in stages. |

For timing, make it deterministic: patch `mover_rand`'s `ld a,r` and the `ld
a,r` in `new_game` to constants, and reset `mover_seed` and `move_tick` when a
game starts.

## 5. Setting things up in the remake

Every recipe starts the same way:
1. Load the build.
2. Press 0.
3. **Wait until the game is really in a room**, that is until `room_shown`
   equals `room_number` and the player's graphic is non-zero, and only then
   write anything. Writes made during the start tune are wiped when the game
   starts.

**Another room.** Write `enter_dir`, then `room_number`, then poll `room_shown`
until it matches.

**Carrying the bucket.** Write record 17 of `quest_table` as `90, U, V, Z, 8,
8, 12, $FF`, `quest_carry` as `$FF, $FF, 17`, and 1 to `quest_water_out`. Then
go to room 122, where quest item 0 is. A number key puts the bucket down.

**The ending.**
1. Set `quest_done` to 4 and `quest_pieces_on` to 1.
2. Put records 4–8 in room 82 (+7), each on a clear straight line to its
   target: the settled ones block the others in both games. Keep
   |U−128| + 8 and |V−128| + 8 under 64, or it's past the edge and stuck.
3. `enter_dir` 0 (room 82's only doorway is on the north side), then
   `room_number` 82.

The fifth one to settle wins.

**Game over at a given percentage.** Set `rooms_seen`: 18 bytes of $FF counts
144 rooms, which caps at 54%. Set `quest_done` (4% each) and `quest_placed` (6%
each). Then write 0 to `player_lives` and 1 to `player_touched`.

**A live record.** Writing U or V of a record in the pool is safe: the mover
repaints from the box saved in the record. Its behaviour doesn't change, so a
homer's slot given a faller's graphic still flies like a homer, and puts its
own graphic back.

## 6. Rooms worth knowing

| Room | Why |
|---|---|
| 92 | the usual start room; cluttered |
| 30 | full-size floor, nothing in it, one doorway (east), no collectable spot: things drop here, and nothing stops them reaching the south-west edge |
| 17, 23, 25, 32, 39 | also empty, but 17 has quest item 2, so nothing drops there |
| 13, 107, 2, 59 | the busiest; they switch the busy rule on |
| 122, 128, 17, 33 | the quest items' rooms |
| 82 | the pentagram's room |

Nothing drops in a room with the well, a quest item or a pentagram piece, in
either game.

## 7. Pitfalls

- **Wait on the game, not on a timer.** Poll the game's own bytes; a fixed sleep
  lands too early on one run and too late on the next.
- **Check each step took.** Read it back, or take a screenshot.
- **Say which game is loaded**, the original or the remake, whenever you switch.
- **Don't guess positions.** Keep a staged object's box inside the floor, and
  away from the doorway and from Sabreman, or it starts stuck and looks like a
  bug.
- **Pentagram is rotational only.** The remake once offered directional
  control, and took it out: a joystick has five inputs and the game needs six.
