# Driving Knight Lore: the original and the remake

How to play both games, and how to put either one into a given state in the
emulator for testing. The remake's addresses are symbols, which move with every
build, so they're always read from `output/knightlore.sld`. The original's
addresses are the ones the remake's own comments cite, with the names from the
reference disassembly. Pentagram has a matching document, with more on the
emulator side: `../pentagram/driving.md`.

1. [Playing](#1-playing)
2. [Running either game in the emulator](#2-running-either-game-in-the-emulator)
3. [The original](#3-the-original)
4. [The remake](#4-the-remake)
5. [Setting things up in the remake](#5-setting-things-up-in-the-remake)
6. [Pitfalls](#6-pitfalls)

---

## 1. Playing

The remake reads the keys the way the original does ($D022, `read_input`).

**Menu**

| Key | Does |
|---|---|
| 1 | keyboard |
| 2 | Kempston joystick |
| 3 | cursor joystick |
| 4 | Interface II |
| 5 | directional control on or off |
| 0 | start the game |

The chosen way flashes, and so does 5 while it's on. The menu tune plays once
on the way in; any key cuts it short.

**Keyboard.** Whole half-rows, as the game reads them:

| Keys | Does |
|---|---|
| Z, C, M, B | turn left |
| X, V, SYMBOL SHIFT, N | turn right |
| A to ENTER, the whole middle row | walk the way he faces |
| Q to P, the whole top row | jump |
| 1 to 0 | pick up, or put down |

There's no firing in Knight Lore.

**Joysticks**

| Input | Rotational (the default) | Directional (menu key 5) |
|---|---|---|
| left, right | turn | walk that way |
| up | walk | walk that way |
| down | pick up, or put down | walk that way |
| fire | jump | jump |
| any letter key | — | pick up, or put down |

The cursor keys are 5 left, 8 right, 7 up, 6 down and 0 fire. Interface II is
6 to 0 for the first stick and 1 to 5 for the second.

**The game**
- You have 40 days (`DAYS_ALLOWED`, $40 in BCD). By night Sabreman is a
  werewolf, and he changes as the sun sets and rises.
- The wizard in room $88 wants 14 charms dropped into his cauldron, one at a
  time and in the order the bubbles show.
- There are 32 charms about the castle. Graphics 96–102 are the seven wanted
  kinds; 103 isn't carried, it's taken when he touches it and gives a life.
- A room holds at most two charms, so something can only be put down in a room
  with a slot free.

## 2. Running either game in the emulator

Everything in `../pentagram/driving.md` section 2 applies:
- Loading over DAP leaves the machine paused: start it with MCP `run`.
- Use `set_speed realtime` when handing over to a person.
- Wait on the game's own bytes, never on a guessed sleep.
- `get_screen_sequence` shows anything over in a moment.

## 3. The original

The snapshot is `snapshots/Knight Lore (1984)(Ultimate).sna`, with ROM
`roms/48.rom`. Its code is mapped from the tcdev/mrcook reference
disassembly (unlicensed: facts and credit only, nothing copied).

| Address | What |
|---|---|
| $D022 | `read_input` |
| $BD0C | `do_menu_selection`, the menu |
| $5BA4 | the menu's choice |
| $5BD1 | the tune's "already played" flag |
| $D296 | `print_border`, the menu's frame |
| $B253, $B20E | the menu and start-of-game tunes; $B2B6 plays and waits for a key, $B2CF plays |
| $D1E2 | `start_locations`, the four start rooms: $2F, $44, $B3, $8F |
| $D3CF | `find_screen`, which walks the room records by their own numbers |
| $6251 | the room list |
| $6BD1 | the object template table. Only the room builder reads it ($D3C6 and $D461), and only for a room's own entries. Templates 1 (a fire standing still) and 17 (raised spikes) are never named by any room. |
| $7112 | the graphic table: 256 pointers into sprite memory |
| $5C08 | the object table |
| $5C48, $5C68 | the room's two charm slots |
| $6FF2 | `special_objs_tbl`, the 32 charms' rows |
| $F100 | the bit-reversal table |
| $BA22 | `game_over` |
| $C82B | `upd_player_bottom` |
| $C9AB | `move_player` |
| $C89F | `handle_left_right` |
| $B25C | `jump_to_upd_object`, the per-object update |
| $CBAF | the clamp |
| $B85C | `set_both_deadly_flags` |
| $C983 | `animate_human_legs` |
| $C17A | `is_on_or_near_obj` |

For finding a routine: the remake's source cites the original's address beside
nearly every routine it reproduces. Grep for the address or the name.

## 4. The remake

Build with `python build.py` in this folder, which writes `output/knightlore.z80`
and `output/knightlore.sld`. `python build.py --debug-room` prints the room
number in the top-left corner, and the 1 and 2 keys step through the rooms
(`room_keys`).

Look symbols up in the SLD after every build:

```sh
grep -E "\|F\|room_number$" output/knightlore.sld | cut -d'|' -f6
```

### Symbols

| Symbol | What |
|---|---|
| `room_number` | Write a room here and the main loop builds it on its next turn. Poking it is the designed way to move the castle about. A number no record carries leaves the old room up. |
| `room_shown` | The room that's built. Don't write it: rooms left are written back under it. |
| `enter_dir` | The side he comes in by; $FF for none, which puts him in the middle. |
| `entered_by` | Kept for starting a room over after a death. |
| `player` | The legs record; the body is 32 bytes on. `player + 65` is his state, +66 his facing (0 to 3), +67 his step in the walk cycle. |
| `player_lives` | lives; 4 at the start (`PLAYER_LIVES`) |
| `player_touched` | 1 kills him on his next turn. The engine sets it as `deadly_touched`. |
| `player_state` | `PLAYER_ALIVE` 0, `DYING` 1, `APPEARING` 2, `CHANGING` 3 (between man and wolf) |
| `days` | days so far, in BCD. The game ends at `DAYS_ALLOWED`. |
| `night` | `PLAYER_WOLF` ($20) by night |
| `sun_x` | where the sun or moon is in its window, from `SUN_RISE` to `SUN_SET` |
| `special_count` | charms in the pot; 14 (`SPECIAL_WANTED`) wins |
| `special_where` | the 32 charms' rows, 4 bytes each. `special_init` copies them from the tape's table at every new game. |
| `special_carried` | what he carries |
| `end_rooms_seen` | a bit a room, for the percentage |
| `room_objects`, `room_object_count` | the object pool, 32 bytes a record, with the same layout as Pentagram's (see its driving.md) |
| `room_busy` | 0 when quiet, or the period monsters sit out: 4, 3 or 2 (busy.s) |
| `busy_calm`, `busy_phase`, `busy_count` | the busy rule's state |
| `move_tick`, `menu_mode`, `input_now` | the turn counter, the menu's choice, this turn's keys |

### What moves

The behaviours are in `movers.s`:

| Behaviour | Name | Note |
|---|---|---|
| 1 | still | deadly |
| 2 | ball | |
| 3, 4 | fires | |
| 5, 6 | guards | |
| 7 | ghost | |
| 8 | bouncing ball | |
| 9 | spiked ball | |
| 10 | gate | crushes |
| 11, 12 | sliding blocks | from 11 on, nothing kills |
| 13 | spell | |
| 14 | cauldron | |
| 15, 16 | dropping and collapsing blocks | |
| 17–19 | carried, pushed, sliding | |
| 20 | charm | |

Behaviours 3–9 are the monsters. They go through `monster_gate`, which sits
them out by turns when the room is busy.

## 5. Setting things up in the remake

Every recipe starts the same way:
1. Load the build.
2. Press 0.
3. **Wait until the game is really in a room.** Set a breakpoint at
   `start.entered` and run to it, or poll until `room_shown` equals
   `room_number`. Only then write anything.

**Another room.** Write `room_number`, and poll `room_shown` until it matches.
For a room that doesn't build, `room_shown` stays where it was: check it.

**Keeping him alive** while you watch. Each turn, write 0 to `player_touched`,
and keep `player_lives` up.

**Game over.** Write 0 to `player_lives` and 1 to `player_touched`. The tally
screen follows the dying.

**The win.** Set `special_count` to 13, then drop the charm the bubbles are
showing into the pot in room $88. The count is only checked as a charm goes
in, so writing 14 on its own does nothing.

**Every room, built in turn.** The comparison script in the scratch work, which
checks a change didn't alter any room, does this: break at `start.entered`,
write `room_number`, set PC to `start.enter`, run to the breakpoint, and read
`room_object_count` records from `room_objects`. All 127 rooms build this way.
The 128th record is the $FF end marker.

## 6. Pitfalls

- **Wait on the game, and check each write took.** Read it back, or take a
  screenshot.
- **Say which game is loaded**, the original or the remake, whenever you switch.
- **Keep him alive while sampling**, or a death in the middle of a
  measurement leaves the game on its end screen, with `room_busy` frozen at
  whatever it last was.
- **Memory is nearly full:** about 1 byte in the main area, 2 in the $5B00
  page, 20 in the pool area and 21 in the data area. The sprite table and the
  nudge index already stop at the last graphic (187).
