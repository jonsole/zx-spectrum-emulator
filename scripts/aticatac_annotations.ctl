# Hand-written annotations for the Atic Atac disassembly.
#
# scripts/build_aticatac.py generates a control file from a code-execution map
# (which addresses are code, which are data) and then layers THIS file on top
# of it. Keeping the two apart is what makes the annotations survive: the
# generated one is thrown away and rebuilt on every run, this one is not.
#
# So: never edit game_disassembly/aticatac/*.asm or *.ctl by hand -- the next
# build overwrites both. Add what you learn here instead.
#
# Everything below was checked against the running game rather than guessed:
# routines were broken on in the emulator and their inputs and outputs read
# back. Anything still uncertain says so.
#
# Format (SkoolKit control file):
#   @ $ADDR label=NAME     give the routine a name
#   c $ADDR Title          one-line title for the routine
#   D $ADDR Paragraph.     description under the title
#   R $ADDR HL What it is  an input/output register
#     $ADDR,N Comment      comment on the instruction(s) at $ADDR
#   E $ADDR Paragraph.     closing note under the routine
#
# One rule about names: never end one with an underscore and a digit.
# skool2asm invents NAME_0, NAME_1, NAME_2 and so on for the jump targets
# inside a routine called NAME, and an explicit label of that shape collides
# with one of them and stops the assembly. Use _ALT or a real word instead.

# --------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------

# Sprite images are built from the game's own bytes by SkoolKit rather than
# drawn by a simulator and pasted in, so a picture and the DEFBs beside it can
# never disagree. The approach is taken from pobtastic's Atic Atac disassembly
# at skoolkit.arcadegeek.co.uk.
#
# A sprite is one byte of row count, then that many rows of two bytes. So: two
# UDGs across, stepping 2 within a UDG and 1 between them, 16 bytes on to the
# next row of UDGs, and cropped to the real height because it is rarely a
# multiple of 8.

@ $6000 label=ENTRY
c $6000 Entry point, and the second half of the tape protection
D $6000 The 18-byte decryptor at $5B80 (in the printer buffer, entered by the loader's PRINT USR 23424) RRDs a nibble through the whole game block and then jumps here.
D $6000 This is where the tape's third trick pays off. One of the tiny CODE blocks pokes $255E into FRAMES at $5C78 for no reason a normal loader would have; the check below is the reason. A cracked loader that drops the little blocks, or anything that lets an interrupt tick FRAMES on before arriving here, fails the compare and falls straight back to BASIC with no error -- the game simply does not start.
R $6000 A FRAMES+1, which must still hold $25
  $6001,3 Well below the game block at $5FFF, so the stack cannot walk into the code.
  $6004,3 FRAMES+1. Interrupts are off from the DI above, so this still holds what the tape poked.
  $6009,1 Not a failure path with a message -- just RET, straight back to the BASIC that called USR.
  $600A,3 The real entry point.

# --------------------------------------------------------------------------
# Title screen
# --------------------------------------------------------------------------

@ $7C19 label=TITLE_SCREEN
c $7C19 Title screen: draw the menu and poll for a selection
D $7C19 Runs the "ATICATAC GAME SELECTION" menu -- control method (1-3), character (4-6) and 0 to start. Both answers are packed into the one byte at $5E00: bits 1 and 2 are the control method, which READ_CONTROLS picks out with AND $06, and bits 3 and 4 the character, which DRAW_LIVES turns back into a sprite number. Reading it after choosing each character in turn gives $00, $08 and $10.
  $7C19,3 $5E00 is the base of the game-state block; the first 16 bytes are zeroed here.
  $7C23,9 Point the tile source at the text font, so the menu can be drawn with PRINT_STRING.
  $7C32,6 Select the half-row holding keys 1-5. The OUT to $FD is inert on a 48K; what matters is that A is left as the high address byte for the IN that follows.
  $7C38,1 Keyboard bits are active-low, so CPL makes a set bit mean "pressed".

# --------------------------------------------------------------------------
# Screen address arithmetic
# --------------------------------------------------------------------------

@ $9BA2 label=PIXEL_TO_SCREEN
c $9BA2 Convert pixel coordinates to a display file address
D $9BA2 The standard 48K display address computation, done in place on HL. Builds $4000 + ((y AND $C0) << 5) + ((y AND $07) << 8) + ((y AND $38) << 2) + (x >> 3).
R $9BA2 HL On entry H = y (0-191), L = x. On exit, the display file address of that pixel's character cell.
  $9BA2,7 x >> 3 gives the character column; (y AND $38) << 2 the row within the third.
  $9BB4,1 Stash the low three bits of y -- the scan line within the cell.
  $9BBC,2 Bits 6-7 of y select which third of the screen; OR $40 puts it in the display file.

@ $9BD2 label=PIXEL_TO_ATTR
c $9BD2 Convert pixel coordinates to an attribute file address
D $9BD2 The same conversion as PIXEL_TO_SCREEN, but landing in the attribute file: $5800 + (y >> 3) * 32 + (x >> 3). Preserves BC.
R $9BD2 HL On entry H = y (0-191), L = x. On exit, the attribute address of that character cell.
  $9BE2,3 OR $58 rather than $40 -- the only real difference from PIXEL_TO_SCREEN.

# --------------------------------------------------------------------------
# Drawing
# --------------------------------------------------------------------------

@ $A1D3 label=PLOT_TILE
c $A1D3 Plot one 8x8 tile and step right
D $A1D3 Copies eight bytes from the current tile source to a character cell. The source base is the pointer at $5E01, so the meaning of the tile code depends on what that currently points at -- see PLOT_TILE's note below.
R $A1D3 A Tile code; the source is ($5E01) + A * 8
R $A1D3 HL Display file address of the cell to draw into. On exit, advanced to the next cell to the right.
  $A1D6,6 A * 8 -- eight bytes per tile.
  $A1DC,4 The current tile source. Not a fixed font: callers repoint it.
  $A1E3,8 INC H walks down the eight scan lines of a character cell, which works because the cell never crosses a third boundary.
  $A1ED,4 Undo the eight INC Hs, then INC L to land on the next cell to the right.
E $A1D3 The tile source at $5E01 is deliberately biased by its callers. Initialised to the text font at $BE4C, where a tile code is simply an ASCII character, it is repointed during play -- while the score is on screen it holds $BFCC, which is $BE4C + 48 * 8, so that a raw digit 0-9 indexes the characters '0' to '9' directly with no adjustment at the call site.

@ $A1F3 label=PRINT_STRING
c $A1F3 Print a string of tiles in a single colour
D $A1F3 Draws consecutive tiles left to right, writing one attribute byte per cell as it goes. It keeps the display address and the attribute address live at the same time in the two register banks, swapping with EXX between the pixel write and the colour write rather than recomputing either.
R $A1F3 HL H = y (0-191), L = x -- where to start
R $A1F3 DE The string: one attribute byte, then the tile codes. Bit 7 set on a code marks it as the last one.
  $A1F4,3 Display address into the main bank...
  $A1FC,4 ...and the attribute address into the alternate one.
  $A1F7,3 The first byte is the colour, not a character; it is kept in A' for the whole run.
  $A201,2 Bit 7 is the end marker, not part of the code.
  $A20B,2 Colour the cell PLOT_TILE just drew into.
  $A210,2 Strip the end marker before drawing the final character.

# --------------------------------------------------------------------------
# Actors
# --------------------------------------------------------------------------

@ $9FFB label=ACTOR_TO_WORKSPACE
c $9FFB Copy an actor's position and sprite into the drawing workspace
D $9FFB Lifts three fields out of the record IX points at into fixed locations at $5E15-$5E17, so the drawing code can reach them without IX.
D $9FFB Called for the player and for every monster alike, which is how the two were shown to share one record layout: breaking here and collecting IX gives $EA90 -- the player -- alongside the eight monster records at $EE60, $EE70, $EE80, $EE90, $EEA0, $EEB0, $EEC0 and $EED0.
R $9FFB IX The record to read
  $9FFB,12 +$03 and +$04 are the position.
  $A007,6 +$00 is the sprite.
E $9FFB The record is 16 bytes. The lower half describes the thing itself -- +$00 sprite, +$01 room, +$03 x, +$04 y -- and in the player's copy the upper half describes the weapon it has in flight: +$08 type ($00 when nothing is in the air), +$09 room, +$0B x, +$0C y, +$0E signed velocity. Watched live: firing fills +$08 onwards, +$0B walks across the room while +$0C holds steady, and +$0E flips between $04 and $FC as the shot turns round off a wall.

@ $85F0 label=ACTOR_TICK_TIMER
c $85F0 Count down the actor's timer, and act when it expires
D $85F0 Field +$0F of the actor record is a countdown. Almost every call is a no-op that just decrements it; only on the tick where it reaches zero does control go to $81F0.
R $85F0 IX The actor record

# --------------------------------------------------------------------------
# Screen clearing
# --------------------------------------------------------------------------

@ $8093 label=CLEAR_PLAY_AREA
c $8093 Clear the play area, leaving the status panel alone
D $8093 Blanks the 24 character columns the castle is drawn in and stops there, so the parchment scroll down the right-hand side -- score, time, lives and the inventory -- survives untouched and does not have to be redrawn on every room change.
D $8093 Verified by running it against a live room and reading the display file back: columns 0-23 came back all zero, columns 24-31 unchanged.
  $8093,6 24 bytes across, 192 display-file rows -- the whole height of the screen, but only three quarters of its width.
  $8099,1 The fill byte. Blank here, but the shared entry below takes whatever is in A.

@ $809A label=FILL_BLOCK
c $809A Fill a rectangular block of the display file
D $809A The general form of CLEAR_PLAY_AREA above, which falls into it. Because it steps by a fixed 32 bytes per row rather than doing any display-file address arithmetic, "rows" here means consecutive 32-byte rows of the display file, not screen lines -- walking $4000 upwards covers the interleaved thirds in the order they are stored.
R $809A HL Top-left corner, as a display file address
R $809A B Width in bytes (character columns)
R $809A C Number of rows
R $809A A The byte to fill with
  $809A,2 Both are needed again on the next row, so they are saved rather than recomputed.
  $809C,3 One display-file row is 32 bytes.
  $809F,4 Fill B bytes across.
  $80A4,1 Step down to the next row.

# --------------------------------------------------------------------------
# Collision
# --------------------------------------------------------------------------

@ $85B2 label=CHECK_HIT
c $85B2 Has this monster caught the player?
D $85B2 Compares the monster IX points at against the player's record at $EA90: same room, and within 12 pixels on both axes. Confirmed by breaking here and collecting IX -- it is only ever one of the eight monster records at $EE60-$EED0, tested against the fixed player address.
R $85B2 IX The monster to test
R $85B2 E 1 if it has the player, 0 if not
  $85B2,8 Cheapest rejection first: a monster in another room cannot touch anything.
  $85BB,8 $31 is not an arbitrary threshold: sprite codes $01-$30 are the three playable characters, sixteen codes each (see ACTOR_HANDLERS), so "non-zero and below $31" means "$EA90 currently holds a player". It reads $66 while the game is still bringing the player into the room, which is what stops them being killed before they exist.
  $85C3,11 |dx|, via negate-if-negative rather than a signed compare.
  $85CE,3 Within 12 pixels horizontally, or no hit.
  $85D1,13 The same for |dy|.
  $85DF,5 Record the hit where the caller can find it...
  $85E4,3 ...and make a noise about it.

# --------------------------------------------------------------------------
# Sound
# --------------------------------------------------------------------------

@ $A3A8 label=BEEP
c $A3A8 Square wave on the beeper
D $A3A8 Toggles bit 4 of port $FE with a busy-wait either side, which is the only way a 48K makes a sound. Every sound effect in the game is a call here, or a short sequence of them with different pitches.
R $A3A8 B Half-period: the delay between edges, so smaller is higher pitched
R $A3A8 C Number of complete cycles, i.e. how long the note lasts
  $A3A8,2 The plain entry point plays exactly one cycle; callers wanting a longer note enter below with C already set.
  $A3AA,4 Speaker bit high.
  $A3AF,2 The pitch: burn B iterations doing nothing.
  $A3B3,3 Speaker bit low again. This also writes 0 to the border bits, which is why the border stays black through every effect.
  $A3B9,3 Repeat for C cycles.

@ $A3E5 label=PLAY_SOUND
c $A3E5 Start a sound effect
D $A3E5 A sound is not played here and it is not played by a scheduler either: it is spawned as an actor. This writes a sprite and a count into the record at $EAA0, and from the next frame on the dispatcher finds it there like any other creature and calls its handler, which beeps once, counts down, and frees the slot when it reaches zero.
D $A3E5 So the second byte is a duration in frames rather than the room number the same field holds in every other record, and the sprite is one of the codes that draws nothing -- $64, $65 and $A0 are sounds wearing an actor's clothes.
D $A3E5 Three routines share the tail with different values: $6410 here, $650A from $A403 and $A010 from $A485. Watched live, writing $64 and $10 into the two bytes by hand makes the count fall 0C, 07, 03 over the following frames and then the slot empties itself.
R $A3E5 BC B = which sound, C = how many frames it lasts
  $A3E5,3 This entry's sound and length.
  $A3E8,6 Sprite first, then the count -- the field an ordinary record uses for its room.

@ $A3EF label=SOUND_64
c $A3EF Sound $64, one frame of it
D $A3EF Called once a frame while the sound lasts. The pitch is taken from however much of the countdown is left, so the note slides as it plays rather than holding steady, and the same handler gives a different sweep for a different starting count.
R $A3EF IX The sound's record
  $A3EF,5 One frame less to go; at zero the sound is over.
  $A3F4,4 What is left of the count is how many cycles to sound.
  $A3F8,3 And, folded about $43, the pitch -- so it glides.
  $A3FB,3 Into BEEP, entered below its own first instruction so the cycle count survives.

@ $A408 label=SOUND_65
c $A408 Sound $65, one frame of it
D $A408 The same shape as SOUND_64 with the pitch derived differently -- three rotations, complemented, folded about $40 -- which is what makes it a different effect rather than the same one at another speed.
  $A408,5 Counting down.
  $A40D,4 Cycles from the count.
  $A411,7 Pitch from the count as well, but along a different curve.

@ $A3FE label=END_SOUND
c $A3FE Free the slot when a sound finishes
D $A3FE Zeroing the sprite is all it takes: the dispatcher skips a record with sprite $00, so the sound simply stops being found. Shared by all three sound handlers.

# --------------------------------------------------------------------------
# Collision: monster vs player, and player vs monster
# --------------------------------------------------------------------------

@ $8566 label=CHECK_SHOT_HIT
c $8566 Has the player's shot hit this monster?
D $8566 The mirror image of CHECK_HIT. Same test, same 12-pixel box, but reading $EA98 onwards -- the upper half of the player's record, where a weapon in flight lives -- so this asks whether the player has hit the monster rather than the other way round. The two are called back to back from the same place.
D $8566 This pair was previously written up as two entries of an 8-byte "object table". That was wrong. $EA90 is one 16-byte record laid out exactly like a monster's, and $EA98 is its second half, not a neighbouring record; the giveaway is that ACTOR_TO_WORKSPACE is called with $EA90 and with the monster records but never with $EA98.
R $8566 IX The monster to test
R $8566 E 1 if the shot has hit it, 0 if not
  $8566,8 +$09 is the weapon's room, +$08 its type, +$0B and +$0C its position.

# --------------------------------------------------------------------------
# Actor movement
# --------------------------------------------------------------------------

@ $845F label=MOVE_ACTOR
c $845F Move one actor, bounce it off the walls, animate it
D $845F The per-actor update. Actors drift in a direction until they hit the edge of the room, then reverse; the direction is re-rolled at intervals from the refresh register, which is the game's random number source.
D $845F Velocity lives in +$08 (x) and +$09 (y) and is nudged one step per call toward +2 or -2 rather than being set outright, so things accelerate and turn smoothly instead of snapping.
R $845F IX The actor to move
  $845F,9 An actor in another room is not drawn or moved...
  $8468,3 ...it only gets its timer ticked.
  $846B,4 Count of actors present in this room.
  $846F,3 Two proximity tests: has the player shot this monster, and has this monster caught the player.
  $847D,4 The room's half-width and half-height -- how far from the centre an actor may stray.
  $8490,4 The refresh register as a source of randomness: whatever R happens to hold, masked to two direction bits.
  $84C2,8 Flip the bottom bit of the sprite index every other tick, which is the walk animation.
  $84CD,6 Provisional new x = x + x-velocity.
  $84D4,5 Distance from the room's centre column ($58)...
  $84DB,8 ...and if that is outside the half-width, stay put and reverse.
  $84F8,6 The same again for y, about centre row $68.
  $8523,6 Commit the new position.
  $8530,7 Two kinds are exempt from the check below: the humpback, whose codes are $9C-$9F, and the four big monsters at $70-$7F -- the mummy, Frankenstein's monster, the devil and Dracula. Masking with $FC and $F0 tests a whole run of codes in one compare, without caring which frame is showing.
E $845F Nothing in the disassembly jumps here, which is not because the routine is dead: it is entry $5C/$5D of the table at ACTOR_HANDLERS, and DISPATCH_ACTOR reaches it through a JP (HL). Breaking here does catch it, 16 times in 20, always with IX = $EE80 -- the monster whose sprite byte is currently $5C. Two earlier rounds of sampling reported zero hits and concluded it was unused; both were taken before the player had finished spawning, when no monster was in the room yet.
E $845F $84CD is also entered directly by eight other routines, which is why the position update is written as a separate stretch: they supply their own velocity in +$08/+$09 and reuse the bounce logic. Verified against the running game -- ($5E1D) reads 56 by 56, and sampled actor positions stay inside $58 +/- 56 by $68 +/- 56.

# --------------------------------------------------------------------------
# Animation
# --------------------------------------------------------------------------

@ $8E26 label=UPDATE_KNIGHT
c $8E26 Per-frame update for the knight
D $8E26 One of three near-identical routines, one per playable character: this is the knight, UPDATE_WIZARD and UPDATE_SERF are the other two. Which one runs is decided by the sprite byte alone -- see ACTOR_HANDLERS.
D $8E26 Treats +$06 and +$07 as a signed dx/dy, compares their magnitudes to decide whether the movement is mostly horizontal or mostly vertical, and picks a sprite accordingly -- base + 4 or base + 8, with the low two bits cycling to give the walk cycle.
D $8E26 This looked at first like it contradicted MOVE_ACTOR, which treats +$06 as a pair of direction bits rather than a signed value. It does not: the two routines work on different records. Breaking on each and reading IX shows UPDATE_KNIGHT is only ever called with IX = $EA90, the player, while MOVE_ACTOR is called with the 16-byte monster records at $EE90. Both readings stand; the field simply means different things in the two layouts.
R $8E26 IX The actor to animate
  $8E32,6 dx and dy. If both are zero the thing is standing still and keeps its sprite.
  $8E3C,5 FRAMES, so the walk cycle advances every fourth frame rather than every call. Interrupts are enabled during play (checked live: IFF1 set, IM 1), so the ROM's interrupt handler is what keeps this ticking.
  $8E43,6 Cycle the low two bits: the four frames of the walk.
  $8E5E,10 Mostly-vertical movement takes one sprite group, mostly-horizontal another.
  $8E6D,3 A footstep.
  $8E7B,7 Only every sixteenth tick.
  $8E82,6 The life force runs down on its own, a unit at a time. Reaching zero is death -- there is no way to stand still and survive.
  $8E88,6 Store it and redraw the roast, which only actually redraws once an eighth has gone.

# --------------------------------------------------------------------------
# Input
# --------------------------------------------------------------------------

@ $93BE label=READ_CONTROLS
c $93BE Read the player's controls, whichever kind they chose
D $93BE Returns one byte for all three control methods, in Kempston's bit order: bit 0 right, bit 1 left, bit 2 down, bit 3 up, bit 4 fire. A bit is 0 when that direction is being asked for.
D $93BE Kempston reads the other way round, so its byte is inverted; the keyboard needs no inversion but does need its bits shuffled, because Q and W sit in the opposite order to left and right. That swap is the whole reason this routine looks fiddly -- it is what lets the movement code downstream be written once instead of three times.
D $93BE This is what pins down the key map: the half-row selected is $FBFE, which is Q W E R T, and after the swap Q lands on the "left" bit and W on the "right" bit. So the keyboard controls are Q left, W right, E down, R up, T fire. Confirmed live -- holding W drives the player's x up to the room's right-hand limit and E drives y down to the bottom one.
R $93BE A The direction/fire mask, 0 bits meaning pressed
  $93BE,5 The control method chosen on the title screen, kept in $5E00.
  $93C3,6 0 is keyboard, 4 is the cursor keys, anything else Kempston.
  $93C9,3 Kempston is active high, so invert it to match the other two.
  $93CD,4 Select the half-row holding Q, W, E, R and T.
  $93D1,3 Bits 0-4 are Q, W, E, R, T in that order.
  $93D4,9 Exchange bits 0 and 1, so that W becomes "right" and Q "left".
  $93DE,4 E, R and T are already in the right places for down, up and fire.

# --------------------------------------------------------------------------
# Actor dispatch
# --------------------------------------------------------------------------

@ $7E7E label=DISPATCH_ACTOR
c $7E7E Jump to the handler for whatever this actor is
D $7E7E Looks the actor's +$00 byte up in ACTOR_HANDLERS and jumps to the address it finds. This is why so many of the per-creature routines have nothing referencing them anywhere in the disassembly -- they are only ever reached from that table, which to a disassembler is just data.
D $7E7E The jump itself is worth a look. Rather than an equivalent sequence ending in JP (HL), the routine jumps to $5CB0 -- an address in the system variables, well outside the game. What lives there is a single $E9 byte, which is the opcode for JP (HL), and it got there because one of the five blocks on the tape is one byte long and loads to exactly that address. So the dispatch runs through an instruction the loader poked into spare ROM-variable space, and a loader that skips that block leaves the game jumping into whatever happened to be at $5CB0.
R $7E7E IX The actor
  $7E7E,1 The caller left the address to come back to in HL, and this puts it on the stack -- so the handler's own RET returns into MAIN_LOOP, and the dispatch itself costs a jump rather than a call.
  $7E7F,3 The table.
  $7E82,3 The actor's sprite byte doubles as its type.
  $7E85,6 Two bytes per entry, so double the index -- through B as well, since types run past $7F.
  $7E8C,4 Fetch the handler address into HL.
  $7E90,3 The poked JP (HL).

@ $7EE6 label=ACTOR_HANDLERS
w $7EE6 Handler address for each actor type
D $7EE6 202 addresses, indexed by an actor's +$00 byte, used by DISPATCH_ACTOR. Entries come in runs of two or four because the low bits of +$00 are the animation frame rather than part of the identity -- $5C and $5D are the two frames of one creature and share a handler, as do $58 to $5B.
D $7EE6 The first three runs are the playable characters -- $01-$10 knight, $11-$20 wizard, $21-$30 serf -- sixteen sprite codes each, which is what makes "below $31" mean "is a player" in CHECK_HIT. Confirmed by starting a game as each of the three in turn and reading the player's sprite byte back: $08, $18 and $28, the same offset into each band.
D $7EE6 Checked against the running game: the monster at $EE80 had sprite byte $5C, the table entry two bytes into $7EE6 + $5C * 2 reads $845F, and a breakpoint at $845F does fire with IX pointing at that monster.

@ $80D2 label=UPDATE_WIZARD
c $80D2 Per-frame update for the wizard
D $80D2 The wizard's equivalent of UPDATE_KNIGHT, reached from ACTOR_HANDLERS for sprite codes $11-$20.

@ $8DC4 label=UPDATE_SERF
c $8DC4 Per-frame update for the serf
D $8DC4 The serf's equivalent of UPDATE_KNIGHT, reached from ACTOR_HANDLERS for sprite codes $21-$30.


# --------------------------------------------------------------------------
# Rooms visited
# --------------------------------------------------------------------------

@ $96AF label=MARK_ROOM_VISITED
c $96AF Mark a room as seen, by writing the instruction that does it
D $96AF Sets one bit in the 19-byte map at $5E40, one bit per room, 152 rooms in all. The bit number is not known until run time, and rather than shift a mask into place the routine assembles the instruction it needs and stores it over the one below.
D $96AF SET b,(HL) is $CB followed by $C6 + b * 8, so ORing the room's low three bits (already shifted up by the three RLCAs) with $C6 gives exactly the operand byte required, and it is written into $96C7 -- the second byte of the SET at $96C6.
D $96AF Checked by calling it directly with a series of room numbers and reading both the map and the patched bytes back: $2A set bit 42 and left SET 2,(HL) in place, $07 set bit 7 as SET 7, $08 set bit 8 as SET 0, $4B set bit 75 as SET 3, and $97 set bit 151 as SET 7 -- the last bit the map has room for.
R $96AF A The room number
  $96AF,7 Room / 8 -- which byte of the map.
  $96B8,4 The map itself. It sits below $6000, so it is not part of this disassembly.
  $96BC,7 Room AND 7, shifted into the bit-number field of a SET opcode.
  $96C3,3 Overwrite the operand of the instruction on the next line.
  $96C6,2 Reads as SET 0 here, but by the time it runs it is SET (room AND 7).

@ $96C9 label=COUNT_ROOMS_EXPLORED
c $96C9 Work out how much of the castle has been seen
D $96C9 Counts the bits set in the room map and turns the total into a two-digit BCD figure at $5E54. It is not shown while playing -- DRAW_SUMMARY prints it on the GAME OVER screen, as the last of the three figures under the heading. Every third room seen is worth 2, and 1 is added at the end, so the value is (rooms / 3) * 2 + 1.
D $96C9 Measured by setting the map by hand and running it: 6, 7 and 8 rooms all give $05, 11 gives $07, 144 gives $97, and none at all gives $01.
D $96C9 The map holds 152 bits but the castle does not have 152 rooms. ROOM_TABLE runs from $A854 to $A981, 151 entries, and of those the last two are black -- colour $00, so nothing they draw can be seen. That leaves 149 real rooms, 0 to 148, and (149 / 3) * 2 + 1 is exactly 99. The figure is scaled so that seeing everything reads 99 and it never has to carry into a third digit, which a single byte of BCD could not hold: setting all 152 bits by hand does overflow it, and $5E54 comes back $01, but no game can get there.
  $96C9,6 19 bytes, 8 bits each.
  $96D5,4 Walk the bits of one byte.
  $96D9,7 Two per three rooms, in BCD -- hence the DAA.
  $96E0,1 Keeps the running total in BCD so it can be printed a digit at a time.
  $96E7,4 The finished figure, read back by the status panel.

# --------------------------------------------------------------------------
# Score
# --------------------------------------------------------------------------

@ $A19C label=ADD_SCORE
c $A19C Add to the score and redraw it
D $A19C The score is three bytes of BCD at $5E2A-$5E2C, printed as six digits. The three DAAs carry across the whole of it, so a caller only has to hand over the amount in BC.
D $A19C Confirmed against a running game: with the panel reading SCORE 000310 the three bytes held $00 $03 $10.
R $A19C BC The amount to add, in BCD
  $A19C,3 The least significant byte, working backwards from there.
  $A19F,4 DAA after each addition is what keeps it decimal.
  $A1A3,9 Carry up through the middle and top bytes.
  $A1AE,6 Point the tile source at the digits before drawing -- this is the biased pointer PLOT_TILE's note describes, $BE4C + 48 * 8, so a digit value indexes its own character.
  $A1BA,5 Three bytes, two digits in each.
  $A1BF,7 High nibble first, then the low one.
E $A19C $A1AE and $A1B7 are entered on their own to redraw the score without changing it, and $A1BF is the general digit printer: B bytes of BCD from DE, drawn at the screen address in HL. The status panel uses that last entry to print the rooms-explored figure from COUNT_ROOMS_EXPLORED as well.

# --------------------------------------------------------------------------
# Rooms: drawing and geometry
# --------------------------------------------------------------------------

@ $9BEA label=DRAW_ROOM
c $9BEA Draw the room the player is in
D $9BEA Looks the room up twice. Its own entry in ROOM_TABLE gives a colour and a shape number; the shape number then selects an entry in ROOM_SHAPES, which carries how far the player may walk and where the outline's geometry lives. Rooms therefore share outlines freely -- only the colour and the shape number are per-room.
D $9BEA Verified against a running game: in room $00 the table gives colour $42 and shape $00, shape $00 gives 56 by 56 and the two pointers $A9DF and $A9EF, and the machine's own $5E1A, $5E1D and $5E1E read back $42, 56 and 56 with the attribute file filled with $42.
  $9BEE,3 The room the player is in.
  $9BF1,3 Two bytes per room...
  $9BF4,5 ...so double the room number to index it.
  $9BF9,5 First byte: the colour the whole room is drawn in.
  $9BFF,9 24 by 24 character cells -- the play area, the same extent CLEAR_PLAY_AREA blanks.
  $9C08,3 Flood the attribute file with the room's colour in one go.
  $9C0C,11 Second byte is the shape number; six bytes per shape, so multiply by 6 the cheap way, as x2 + x4.
  $9C18,5 How far from the centre the player may walk -- MOVE_ACTOR reads these back out of $5E1D.
  $9C1D,5 The vertical limit.
  $9C22,4 Where the shape's vertices are.
  $9C26,4 Where its edge list is.
  $9C2A,3 The vertices are indexed through IX.

@ $9C2F label=DRAW_OUTLINE
c $9C2F Walk the edge list and draw the room's outline
D $9C2F The edge list is a run of vertex numbers. The first begins a group, each one after it draws a line from that vertex to this one, and $FF ends the group; a second $FF ends the list. Writing it as groups rather than as pairs means a corner shared by three lines is only named once.
D $9C2F The vertex number cannot be known in advance, so as with MARK_ROOM_VISITED the routine writes the instruction that will use it: the displacement in each LD r,(IX+$00) below is overwritten just before it runs.
D $9C2F For room shape $00 the vertices are two nested squares -- (4,187) (4,4) (187,4) (187,187) and (31,160) (31,31) (160,31) (160,160) -- and the groups are 0 to 1,3,4; 2 to 1,3,6; 5 to 1,4,6; 7 to 3,4,6. That is the four outer walls, the four inner ones and the four corner diagonals, each drawn exactly once, which is the "looking into a box" outline every room is built from.
  $9C2F,4 $FF ends the whole list.
  $9C34,9 Double the vertex number and patch it into both halves of the 16-bit fetch below.
  $9C3D,6 Reads as (IX+$00) but the displacements were just rewritten.
  $9C5A,3 Draw one line, corner to corner.

@ $9C79 label=DRAW_LINE
c $9C79 Draw a line between two points
D $9C79 Takes the difference along each axis, remembers which way each one runs in a pair of bits, and picks whichever axis is longer to step along -- the ordinary way of drawing a line one pixel at a time on a machine with no multiply. $5E23 and $5E24 hold the working values.
R $9C79 BC One end
R $9C79 DE The other
  $9C79,2 Keep one end in HL to walk along.
  $9C7D,8 |dx|, with bit 0 of C remembering the direction.
  $9C86,8 |dy|, in bit 1.
  $9C8E,1 Whichever is longer becomes the axis stepped along...
  $9C95,3 ...and the steep case is handled separately.

@ $A854 label=ROOM_TABLE
; span $A854,302
b $A854 Colour and shape of each room
D $A854 Two bytes per room, indexed by room number: the first is the attribute the whole play area is filled with, the second is an index into ROOM_SHAPES. With 152 rooms sharing a much smaller set of outlines, this is most of what makes the castle fit in memory.

@ $A982 label=ROOM_SHAPES
; span $A982,78
b $A982 Geometry of each room shape
D $A982 Six bytes per shape: how far the player may walk from the centre horizontally and vertically, then a pointer to the shape's vertex table, then a pointer to its edge list. Shape $00 reads 56, 56, $A9DF, $A9EF.
D $A982 A vertex table is two bytes per point, x then y; an edge list is the $FF-separated groups DRAW_OUTLINE walks.

# --------------------------------------------------------------------------
# The status panel
# --------------------------------------------------------------------------

@ $A240 label=PAINT_PANEL
c $A240 Colour the status panel to go with the room
D $A240 The third and last step of a room change, after CLEAR_PLAY_AREA and DRAW_ROOM. It writes attributes only -- the scroll, the timer and the score are drawn elsewhere and simply take whatever colour is underneath them, which is why walking into a differently-coloured room recolours the whole panel without anything being redrawn.
D $A240 The colour is the room's own ink complemented: CPL then AND $07 keeps just the three ink bits and inverts them, so a red room gives a cyan panel, green gives magenta and so on. Complementing also throws away the bright and paper bits, which is why the panel comes out one shade darker than the room outline.
D $A240 Inks 0 and 1 -- black and blue -- would be unreadable against black paper, so anything below 2 is replaced outright by $44, bright green. Measured by writing each room colour into $5E1A in turn and re-running: $42 gives $05, $43 gives $04, $44 gives $03, $45 gives $02, and $46 and $47 both give $44.
  $A240,6 x = 192, the first character column past the play area.
  $A246,3 8 columns wide, 24 rows deep -- the rest of the screen.
  $A249,6 The room's colour, inverted.
  $A24F,4 Too dark to read against black...
  $A253,2 ...so use bright green instead.
  $A259,4 Fill one row of the panel.
  $A25E,4 32 bytes to the row below.
  $A266,6 The little blocks below the scroll are coloured separately...
  $A26C,9 ...in the room's own colour rather than the complement.
  $A27E,3 One cell on its own.
  $A28C,5 Bright white, for the part that never changes.

# --------------------------------------------------------------------------
# Doors and room changes
# --------------------------------------------------------------------------

@ $90CC label=PLAYER_AT_DOOR
c $90CC Is the player standing in this doorway?
D $90CC Unlike CHECK_HIT this box is deliberately lopsided. Both comparisons are unsigned against a subtraction that is not made absolute, so the player only registers from one side of the doorway -- walking into a door from behind does nothing.
D $90CC Bit 6 of +$05 says which way the doorway faces, and it halves the tolerance across the door rather than along it: a door in a side wall is generous vertically and tight horizontally, and the other way round for one in the top or bottom wall. The caller passes $1111 as the starting tolerance in BC.
R $90CC IX The door
R $90CC BC Tolerance across and along the doorway
R $90CC F Carry set if the player is in it
  $90CC,6 Suppressed while the low nibble of $EA92 is set -- the flag ENTER_ROOM leaves behind, so one doorway cannot fire twice.
  $90D2,7 And only while the player is actually in play, the same $01-$30 test CHECK_HIT makes.
  $90D9,8 Halve the tolerance across the door, unless it faces the other way.
  $90E1,8 One-sided: unsigned, so a negative difference fails the compare outright.
  $90F1,9 The same again for the other axis, negated because this one is measured the opposite way.

@ $90FB label=NEAR_PLAYER
c $90FB Is the player within 12 pixels of this thing?
D $90FB The symmetric version of the test PLAYER_AT_DOOR makes -- absolute difference on both axes against the same 12-pixel box CHECK_HIT uses, with no room check and no one-sidedness.
R $90FB IX The thing to measure from
  $90FB,9 |dx|, by negating if it came out negative.

@ $9117 label=ENTER_ROOM
c $9117 Move the player through a door and redraw everything
D $9117 Takes the door record in IX, copies its destination into the player's room and position, and then rebuilds the screen: mark the room seen, blank the play area, draw the new room, recolour the panel.
D $9117 The arrival position is not stored outright. +$02 packs both offsets into one byte, unpacked by rotating it in opposite directions and masking to $1E -- an even number 0 to 30 each way, the vertical one negated. Every door checked holds $34, which comes out as 8 to the right and 6 up, so the player lands just inside the room rather than on top of the doorway they arrived through.
D $9117 Confirmed by setting IX to four different door records and running from $911A: doors to rooms $07, $19, $01 and $00 produced exactly the destination and the offset position predicted from their bytes.
R $9117 IX The door being entered
  $9117,3 Swap to the door's other side. The record the player touched describes this room; the one eight bytes away describes where they come out. That reassignment of IX is also why anything testing this routine has to enter below it.
  $911A,6 +$01 is the destination room.
  $9120,12 Rotate left and mask: the horizontal offset, added to the door's own x.
  $912C,16 Rotate right three times for the vertical one, which is subtracted rather than added.
  $913F,8 Set the flag that stops PLAYER_AT_DOOR firing again on the way out.
  $9147,6 Record the new room as seen.
  $914D,9 Blank the play area, draw the new room, colour the panel to match.
E $9117 The doors themselves are 8-byte records in a table above the monsters, around $EEE0: +$00 a sprite, +$01 the destination room, +$02 the packed arrival offset, +$03 and +$04 the doorway's own position, +$05 flags with bit 6 giving its facing. Only the ones whose +$01 matches the room the player is in get tested.

# --------------------------------------------------------------------------
# Sprites
# --------------------------------------------------------------------------

@ $9962 label=DRAW_SPRITE_PIXELS
c $9962 Draw a sprite, choosing the routine from the drawing mode
D $9962 Neither this nor DRAW_SPRITE_COLOURS does any drawing. Each loads the address of its own table of eight routines and falls into the tail of DISPATCH_ACTOR, which indexes the table and jumps through the JP (HL) the tape left at $5CB0 -- the same machinery that picks an actor's handler, reused for picking how a sprite gets put on the screen.
D $9962 The mode is the top three bits of the actor's +$05, so the low five bits are free for other flags -- PLAYER_AT_DOOR reads bit 6 of the same byte as a door's facing.
R $9962 C Sprite number
R $9962 B Drawing mode in its top three bits
R $9962 DE Where to draw, as pixel coordinates
  $9962,3 One table of eight...
  $9966,7 ...indexed by the top three bits of B.
  $996D,3 Into the dispatcher's tail, which does the lookup and the jump.

@ $9970 label=PIXEL_DRAWERS
w $9970 Eight ways of putting a sprite's pixels on the screen
D $9970 Chosen by DRAW_SPRITE_PIXELS from the drawing mode.

@ $9980 label=DRAW_SPRITE_COLOURS
c $9980 Draw a sprite from the other set of eight routines
D $9980 As DRAW_SPRITE_PIXELS, but pointing at COLOUR_DRAWERS. Actor handlers call this one to put a sprite down and the masked one to take it away again, a row above -- which is why $91F2 does the two with the same coordinates but a DEC D between them.
  $9980,3 The other table.

@ $9985 label=COLOUR_DRAWERS
w $9985 Eight ways of putting a sprite's colours on the screen
D $9985 Chosen by DRAW_SPRITE_COLOURS from the drawing mode.

@ $9995 label=FETCH_SPRITE
c $9995 Look up a sprite's bitmap and work out where it goes
D $9995 Sprite numbers are 1-based, so the number is decremented before being doubled into the table of addresses at $A600. The first two bytes of the data are its size, and the pointer is left just past them.
R $9995 C Sprite number
R $9995 DE On exit, the first row of bitmap data
R $9995 B On exit, width in bytes
R $9995 C On exit, height in rows
R $9995 HL On exit, where the top-left corner lands in the display file
  $9995,3 The table of sprite addresses.
  $9998,7 Numbered from 1, two bytes each.
  $99A0,5 The address of the bitmap itself.
  $99A5,3 Turn the pixel coordinates into a display file address.
  $99A8,6 Width then height, and step past them to the first row.
E $9995 Watched live, the sizes coming back are 4 by 24 for the characters and 6 by 5 or 6 by 6 for smaller pieces -- so width really is in bytes, eight pixels at a time.
E $9995 $A600 is not a table of its own. It is the 161st entry of SPRITE_TABLE, and this routine does the same arithmetic SPRITE_ADDRESS does, so asking it for sprite 1 fetches entry 161. The base is what says which family of sprites is wanted. An earlier reading of this routine took the 39 entries between $A600 and $A64E for the whole table and concluded it held the knight, the wizard and seven frames of the serf; that was an accident of where the next base happens to fall.

@ $99AF label=FETCH_SPRITE_ATTRS
c $99AF Look up a sprite's colours
D $99AF The same routine as FETCH_SPRITE but based at $A64E -- the 200th entry of SPRITE_TABLE rather than the 161st -- and ending in PIXEL_TO_ATTR rather than PIXEL_TO_SCREEN, so what it fetches is a sprite's colours rather than its shape.
R $99AF C Sprite number
  $99AF,3 The colour tables, one per sprite.
  $99BF,3 The attribute address rather than the display one.

@ $99C9 label=BLIT_SPRITE
c $99C9 Copy a sprite to the screen, combining it however the caller asked
D $99C9 The inner loop of everything that moves. A sprite is width bytes by height rows, and the row-to-row step is left to SCREEN_ROW_UP rather than being computed here, because the display file's thirds make it anything but a simple addition.
D $99C9 It works upwards. The first row of a sprite's data is its bottom row, so an actor's +$03 and +$04 are the point its feet stand on rather than a top-left corner. Rendering the data top-down produces nothing recognisable; reversed, it comes out as a picture.
D $99C9 How each byte meets what is already on the screen is not decided by a branch. $9D19 hands back an opcode and it is written over the NOP in the middle of the loop, so the same six instructions become a plain copy, an OR, an XOR or an AND with nothing tested per byte. Read live during play the byte is $00 -- a NOP, so a plain copy.
  $99CA,6 Fetch the combining opcode and write it into the loop below.
  $99D0,3 Bitmap, size and destination.
  $99D5,2 One byte of the sprite.
  $99D7,1 Assembled at run time: NOP, OR (HL), XOR (HL) or AND (HL).
  $99D8,4 Store it and move one cell right, width times.
  $99DD,3 Up one pixel row -- see SCREEN_ROW_UP. Sprites are stored and drawn from the bottom.
  $99E0,4 Repeat for every row.

@ $9D19 label=SPRITE_COMBINE_OPCODE
c $9D19 Choose the instruction that puts a sprite byte on the screen
D $9D19 Returns an opcode rather than a flag, for BLIT_SPRITE to write into the middle of its own loop. The drawing mode is packed into B: the low two bits pick the combining operation here, the top three pick which of the eight drawing routines runs.
R $9D19 B Drawing mode
R $9D19 A $00 for NOP, $B6 for OR (HL), $AE for XOR (HL)
  $9D19,4 Mode 0 leaves A zero -- a NOP, so the sprite byte is stored as it is.
  $9D1D,4 $AE is XOR (HL), which is how a sprite is drawn and then rubbed out again by drawing it a second time.
  $9D21,1 Modes 2 and 3 both take it.
  $9D22,2 $AE + 8 is $B6, OR (HL) -- the sprite laid over what is already there.

@ $9F03 label=SCREEN_ROW_UP
c $9F03 Move a display file address up one pixel row
D $9F03 The counterpart to PIXEL_TO_SCREEN's arithmetic, done as cheaply as possible because BLIT_SPRITE calls it once per row of every sprite on the screen. Within a character cell the row is the low three bits of H, so most calls are a DEC H and a test; only one in eight has to step back a whole character row, and only one in sixty-four crosses between the display's thirds.
R $9F03 HL A display file address; on exit, the same column one pixel higher
  $9F03,1 The common case, and usually the only instruction that runs.
  $9F04,5 Did that take us out of the top of the character cell? If not, done.
  $9F09,5 It did: back one character row. A borrow here means we also crossed into the third above, where H is already right.
  $9F0E,4 No borrow, so undo the DEC H's effect on the cell row.

# --------------------------------------------------------------------------
# The clock
# --------------------------------------------------------------------------

@ $95DA label=TICK_CLOCK
c $95DA Advance the elapsed-time clock
D $95DA The clock counts up rather than down -- Atic Atac's TIME is how long you have been in the castle, not how long is left. Three bytes of BCD at $5E3D, $5E3E and $5E3F hold it, and the panel prints them as one digit, then two, a colon, then two: 000:09.
D $95DA Its time base is the ROM's own FRAMES counter, which ticks 50 times a second on the interrupt the game leaves enabled. Rather than remember when the last second was, it subtracts 50 from FRAMES whenever there are at least 50 there, so the remainder carries the fraction of a second forward and nothing drifts.
D $95DA Confirmed against a running game: with the three bytes reading $00 $00 $09 the panel showed TIME 000:09.
  $95DA,6 Fewer than fifty frames since the last tick, so there is nothing to do yet.
  $95E0,5 Take a whole second out and leave the remainder for next time.
  $95E5,3 The seconds, the last of the three bytes.
  $95E8,4 INC then DAA -- adding 1 in BCD, so the digits stay printable.
  $95EC,4 Sixty, in BCD, is $60.
  $95F0,3 Round the seconds and carry into the minutes.
  $95FD,4 And the minutes into the hours.
  $9601,2 Hours are kept to a single digit, which is what makes the display 000:09 rather than 00:00:09.

# --------------------------------------------------------------------------
# Game over
# --------------------------------------------------------------------------

@ $8C35 label=GAME_OVER
c $8C35 Clear the castle away and show how it went
D $8C35 Reached from UPDATE_KNIGHT when the player's last life goes. It blanks the play area, prints GAME OVER across it, and hands over to DRAW_SUMMARY for the three figures underneath, then sits in a counting loop long enough to read them.
D $8C35 Note the second and third instructions: the tile source has to be pointed back at the text font first. During play it holds $BFCC, the copy biased so that digits index themselves, and anything printed through PLOT_TILE while it is still there comes out as the wrong glyphs entirely.
  $8C35,3 The castle goes; the status panel down the side stays.
  $8C38,6 Back to the text font, or the words below would be gibberish.
  $8C3E,6 "GAME OVER", centred above the figures.
  $8C47,3 TIME, SCORE and the proportion of the castle seen.
  $8C4A,5 A delay, and a long one: twenty times round a full 16-bit count.
  $8C4F,7 About four seconds in all, with nothing else running.

@ $9641 label=DRAW_SUMMARY
c $9641 Print the three end-of-game figures
D $9641 Three labels and three numbers, stacked at the left of the cleared play area. The labels carry their own colour in their first byte and their own punctuation: the one for the clock ends with the font's colon glyph, so TIME's digits print either side of a colon that was drawn with the word.
D $9641 It assumes the text font is already selected, which is why GAME_OVER repoints $5E01 before calling. Halfway through it switches to the digit-biased copy for the numbers.
  $9641,3 Work out the proportion of the castle seen before printing it.
  $9644,9 "TIME", with the colon.
  $965F,6 From here on the numbers, so bias the tile source to the digits.
  $9665,6 The clock, then the score.
  $9671,3 And the rooms-explored figure.
  $9674,8 One byte, two digits.

# --------------------------------------------------------------------------
# The scroll, and the title screen's pictures
# --------------------------------------------------------------------------

@ $A17D label=UI_RECORD
s $A17D A spare record for drawing things that are not actors
D $A17D Eight bytes of scratch. The sprite routines only know how to draw from a record, so anything that has to appear without being a creature -- the lives on the scroll, the pictures on the title screen -- is written in here first and drawn from here.
D $A17D That it is eight bytes and not sixteen is the useful part. A monster's record is sixteen, but only its first eight describe the thing itself: sprite, room, a flag, x, y, drawing mode. The doors above $EEE0 are eight bytes too. So the short form is the common one, and an actor is that plus another eight for how it moves and what it has in the air.

@ $A2CE label=DRAW_LIVES
c $A2CE Draw the remaining lives on the scroll
D $A2CE Draws up to three small figures at the foot of the panel, sixteen pixels apart, in whichever character the player chose. The count comes from $5E21, and the loop always runs three times: the slots past the count are drawn over rather than skipped, so a life that has just been lost is erased.
D $A2CE The sprite is worked out from the menu selection rather than stored. $5E00 holds the character in bits 3 and 4, so shifting it up one and masking to $30 gives $00, $10 or $20, and setting bit 0 makes it $01, $11 or $21 -- the first sprite of the knight, the wizard and the serf. Checked by starting a game as each: $5E00 reads $00, $08 and $10 and the player's own sprite byte comes out $08, $18 and $28, seven along from those bases.
  $A2D0,4 Not an actor, so borrow UI_RECORD to draw from.
  $A2D4,8 Turn the menu selection into the chosen character's first sprite.
  $A2DC,3 Bright white.
  $A2E3,3 The foot of the scroll: x = 200, y = 141.
  $A2E6,6 The record wants x then y, and HL holds them the other way round.
  $A2EC,6 Lives remaining, but three slots regardless.
  $A2FD,8 Sixteen pixels along for the next one.
  $A306,4 Once the count runs out it stays at zero, and the rest are blanks.

@ $A311 label=DRAW_TITLE_ICONS
c $A311 Draw the nine pictures on the title screen
D $A311 Works through TITLE_ICONS, copying each eight-byte record into UI_RECORD and drawing it. Nine records, but only six pictures: the three control methods are each too wide for one sprite and are drawn as two halves side by side, while the three characters below are one sprite each.
  $A311,4 Everything is drawn from the same scratch record...
  $A315,5 ...one copy of it at a time.
  $A31B,8 Eight bytes: the whole record.
  $A325,6 Put it on the screen, then its colours.

; span $A331,72
@ $A331 label=TITLE_ICONS
b $A331 The nine pictures on the title screen
D $A331 Nine records of eight bytes, in the ordinary short form -- sprite, room, flag, x, y, drawing mode. Read out of the game: sprites $48 and $49 make the keyboard at the top, $4A and $4B the joystick, $32 and $33 the cursor keys, and then $01, $11 and $21 draw the knight, the wizard and the serf down the left, at the very sprite numbers DRAW_LIVES computes from the menu selection.

# --------------------------------------------------------------------------
# Life force
# --------------------------------------------------------------------------

@ $8C2D label=FOOD_RECORD
s $8C2D A second scratch record, for redrawing the food
D $8C2D The disassembler calls this unused because nothing reaches it as code and nothing loads it as data through an obvious address. It is neither: DRAW_FOOD puts it in IX and draws from it, and writes a screen address into $8C30 in the middle of it.

@ $8A15 label=LOSE_FOOD_16
c $8A15 Take sixteen off the life force
D $8A15 The heavier of the two penalties. If it would go below zero the stack is dropped and control goes straight to the death routine, so the caller never returns.
  $8A15,5 Sixteen, against the eight LOSE_FOOD_8 takes.

@ $8A1E label=LOSE_FOOD_8
c $8A1E Take eight off the life force
D $8A1E What touching most monsters costs -- four of the creature handlers call this one. Both penalties share the tail: store the new level, redraw the indicator, and on underflow die instead.
R $8A1E A The new level
  $8A1E,5 Eight.
  $8A25,6 Store it, then redraw the roast on the scroll.

@ $8B8A label=DRAW_FOOD
c $8B8A Redraw the roast on the scroll
D $8B8A The life force in $5E28 is drawn as the roast down the right-hand side, eaten away as it falls. $5E29 remembers the level the picture was last drawn at, and both are shifted right three times before being compared, so nothing happens until a whole eighth of the roast has gone -- most calls return at the third instruction.
D $8B8A It does not have its own copy of the picture. It reaches into the sprite tables, moves the roast's entry at $A626 forward by however many rows have been eaten and shortens the height bytes at $C48D and $C543 to match, draws, and then puts all three back from the stack. The tables are only wrong for the few hundred T-states it takes to draw.
D $8B8A Watched live: at rest $A626 holds $C48C and $C48D holds $1E, and breaking just before the restore catches $A626 reading $C522 and then $C51C as the roast goes down -- the same entry, advanced past the rows that have been eaten.
R $8B8A None; it reads the level out of $5E28
  $8B8A,9 The level, in eighths.
  $8B94,10 What was drawn last time, also in eighths.
  $8B9E,2 The same, so the picture is still right.
  $8BA0,8 Keep the roast's real height to put back afterwards.
  $8BAA,4 Not an actor, so borrow FOOD_RECORD.
  $8BBD,6 The roast's entry in the sprite pointer table.
  $8BC3,3 Moved past the eaten rows, and put back before returning.

# --------------------------------------------------------------------------
# Objects lying in rooms
# --------------------------------------------------------------------------

@ $8C63 label=EAT_FOOD
c $8C63 The handler for a piece of food
D $8C63 Sprites $50 to $57 are food, and ACTOR_HANDLERS sends all eight of them here. Every frame it asks whether the player is standing on it; if not, it just draws itself and that is the whole of its behaviour.
D $8C63 Eating is worth $40 -- a quarter of the bar -- and the total is held at $F0 rather than being allowed to wrap, so arriving at a roast with almost full health wastes most of it. The two branches before the cap catch the carry as well as the compare, because $5E28 plus $40 can pass $FF.
R $8C63 IX The food
  $8C63,6 Is the player on it?
  $8C69,5 No -- draw it and do nothing else.
  $8C6E,7 Rub it out and free its slot: eaten food does not come back.
  $8C75,3 A noise.
  $8C78,6 Sixty-four units of life force.
  $8C7E,6 Cap it, catching both the carry and the limit...
  $8C84,2 ...at $F0, just short of a full bar.
  $8C86,3 Store it and redraw the roast on the scroll.

@ $95A9 label=DROP_OBJECT
c $95A9 Leave an object where the player is standing
D $95A9 Four slots of eight bytes at $EAE8. The first with a zero sprite is taken, given sprite $8F, and the seven bytes after it are copied straight out of the player's own record -- room, flag, position and all -- so the thing appears exactly where the player is. With all four in use the routine simply returns and nothing is dropped.
D $95A9 The copy is what makes it cheap: because an object and an actor share the same eight-byte header, placing one is one LDIR rather than half a dozen assignments.
  $95A9,8 Four slots, eight bytes apart.
  $95B1,4 A zero sprite means the slot is free.
  $95B5,4 All four taken, so give up.
  $95BF,2 The sprite the dropped thing is drawn as.
  $95C3,8 Room, flag and position, straight from the player's record.

@ $8C8C label=FLASH_SCORE
c $8C8C Flash the score line while a countdown runs
D $8C8C Counts $5E3C down and, while it lasts, sets bit 7 of the six attribute cells the score sits in -- the flash bit, so the ULA does the work and nothing has to be redrawn. A beep every sixteenth step goes with it.
  $8C8C,4 The countdown.
  $8C92,5 A beep once every sixteen.
  $8C97,6 The attributes under the score, not the pixels.
  $8C9F,4 Bit 7 is FLASH; the hardware alternates ink and paper from there on.

# --------------------------------------------------------------------------
# Dying and coming back
# --------------------------------------------------------------------------

@ $8EA0 label=LOSE_LIFE
c $8EA0 Take a life and start the player sinking
D $8EA0 The single way out of the game. Both food penalties and the steady drain arrive here when the life force reaches zero, and with no lives left it goes straight to GAME_OVER.
D $8EA0 Otherwise the player is not moved or hidden -- their sprite is changed to $67, which ACTOR_HANDLERS sends to DYING, and the character they were is put in +$07 for MATERIALISING to restore. Nothing else has to know a death has happened; the sprite byte carries the whole state.
D $8EA0 Watched live by starving the player: lives went 3 to 2, the sprite went $08 to $67 to $66, the life force came back as $F0, and an object appeared in the first of the four drop slots reading 8F 00 68 60 68 45 FF 08 -- sprite $8F at the exact spot the player fell.
  $8EA0,4 No lives left...
  $8EA4,3 ...so that is the end of the game.
  $8EA7,4 Otherwise pay one.
  $8EAB,8 Was the thing that died a player at all? Sprites $01 to $30 are.
  $8EB6,3 Remember what to come back as.
  $8EC0,5 $67 -- the sinking animation, which the dispatcher will find on the next pass.
  $8EC6,12 A non-player dies where the workspace says it was, not where the player is.

@ $8ED7 label=LOSE_FOOD_32
c $8ED7 Take thirty-two off the life force
D $8ED7 The heaviest of the three penalties, and the one MOVE_ACTOR's hit path uses. Unlike the other two this one clamps to zero rather than underflowing, then dies anyway -- the roast is redrawn empty before the life is taken, so the bar is seen to run out.
  $8ED7,5 Thirty-two, against sixteen and eight elsewhere.
  $8EDC,5 Exactly zero, or past it: either way the player is dead.
  $8EE1,6 Show the empty bar first, then lose the life.

@ $8D45 label=DYING
c $8D45 Sink the player into the floor
D $8D45 The handler for sprite $67. Every fourth frame it counts +$06 down and shifts the sprite further down the screen by that much, so the character appears to sink. When the count passes zero it drops an object where the body was and hands over to $9443.
  $8D45,5 One step in four frames.
  $8D4C,6 Down a little further, until it goes negative.
  $8D5B,6 Leave something behind, then carry on.

@ $8CB7 label=MATERIALISING
c $8CB7 Raise the player back out of the floor
D $8CB7 The handler for sprite $66, and the mirror of DYING: +$06 counts up instead of down and the sprite rises. It is what runs at the start of a game as well as after a death, which is why the player's sprite byte reads $66 for several seconds before a new game is really under way -- and why CHECK_HIT, which only counts sprites below $31 as a player, cannot register a hit during it.
  $8CB7,4 A bonus flashing on the scroll takes priority over rising.
  $8CBD,5 One step in four frames.
  $8CC5,3 Up a little further.
  $8CCF,5 At the top, so become a player again.

@ $8D32 label=FINISH_MATERIALISING
c $8D32 Turn back into the character and clear the animation
D $8D32 +$07 has been carrying the character's sprite since LOSE_LIFE put it there. Restoring it is all it takes to be alive again: the dispatcher will send the next frame to UPDATE_KNIGHT, and CHECK_HIT will start counting the player as hittable.
  $8D32,6 Back to the knight, the wizard or the serf.
  $8D38,12 Clear the counter, the saved sprite and the offset.

# --------------------------------------------------------------------------
# What the sprites depict
#
# These `; sprite` lines are read by scripts/build_aticatac.py to title the
# sections of the generated sprite catalogue. They are kept separate from the
# routine labels because the two do not line up: one handler often drives
# several creatures (MOVE_ACTOR is both the pumpkin and the spider), and one
# run of codes can hold more than one picture (the keyboard and the joystick
# share a handler and sit next to each other).
# --------------------------------------------------------------------------

; sprite $01-$10 The knight
; sprite $11-$20 The wizard
; sprite $21-$30 The serf
; sprite $32-$33 Cursor keys icon, in two halves

# Runs that are one picture cut into pieces rather than frames of an
# animation. A sprite is only ever sixteen pixels wide, so anything wider
# is drawn as two side by side; showing them as an animation flicks
# between the halves of one icon.
; joined $32-$33
; joined $48-$49
; joined $4A-$4B

; sprite $6C-$6F Burst, expanding
; sprite $34-$37 Spell, thrown by the wizard
; sprite $38-$3F Sword, spinning, thrown by the serf
; sprite $40-$47 Axe, spinning, thrown by the knight
; sprite $48-$49 Keyboard icon, in two halves
; sprite $4A-$4B Joystick icon, in two halves
; sprite $4C-$4D Pumpkin
; sprite $4E-$4F Bat
; sprite $50-$57 Food
; sprite $58-$5B Monster, spawning
; sprite $5C-$5D Spider
; sprite $5E-$5F Monster, not yet identified
; sprite $60-$61 Monster, not yet identified
; sprite $62-$63 Ghost
; sprite $68-$69 Ghost, a second kind
; sprite $6A-$6B Bat, a second kind
; sprite $70-$73 Mummy
; sprite $74-$77 Frankenstein's monster
; sprite $78-$7B Devil
; sprite $7C-$7F Dracula
; sprite $80-$8E Collectables: keys, and the objects that kill the mummy, Dracula, the devil and Frankenstein's monster
; sprite $8F Gravestone, left where the player died
; sprite $90-$93 Witch
; sprite $98-$9B Bat, a third kind
; sprite $9C-$9F Humpback
# $AE-$B1, $B2, $B9 and $BC were named here as doors. They are not: drawn at
# their real size they are a cave door, a grandfather clock, a framed picture,
# a trapdoor and a rug. The mistake came of reading them in the sprite format,
# nine bytes instead of a hundred and thirty, and naming the fragment. The
# names further down are pobtastic's and are what the pictures actually show.
; sprite $A1 Mushroom, which drains the player's life force

@ $807A label=INERT_SPRITE
c $807A A sprite that does nothing at all
D $807A The handler for everything that is drawn but never acts -- the three control-method pictures on the title screen among them. It checks whether IX is one of the first three monster records and, if it is, burns a couple of hundred cycles doing nothing; otherwise it returns at once.
D $807A The delay looks pointless but is not: those three slots are drawn every frame whatever occupies them, and an inert occupant that returned instantly would make the frame shorter than one holding a creature. Spending the time keeps the pace even.
  $807A,6 IX, as a number, against the base of the monster table.
  $8080,6 Not in the table at all -- nothing to do.
  $8086,4 Only the first three slots get the delay.
  $808A,3 192, counted down and thrown away.
  $808D,5 The delay itself.

@ $82F1 label=SPIN_SWORD
c $82F1 Drive the spinning sword
D $82F1 Sprites $38 to $3F are one sword drawn at eight angles, a compass point apart, and cycling through them is what makes it appear to spin.
D $82F1 This is the serf's weapon. Each character throws its own: firing as each in turn and reading the type out of the player record's upper half gives $3E for the serf, $41 to $47 for the knight's axe and $36 for the wizard's spell.

@ $81DB label=SPIN_AXE
c $81DB Drive the spinning axe
D $81DB The axe's equivalent of SPIN_SWORD, over sprites $40 to $47 -- again eight frames, one per compass point. It is the knight's weapon.

@ $862E label=MOVE_BAT
c $862E Drive a bat
D $862E Sprites $4E and $4F. A second kind of bat, sprites $6A and $6B, is driven by MOVE_BAT_ALT instead; the two look alike but are not the same creature and do not share a routine.

@ $8301 label=MOVE_BAT_ALT
c $8301 Drive the other kind of bat
D $8301 Sprites $6A and $6B. What it does differently from MOVE_BAT has not been established -- only that the game keeps them apart.

@ $87A6 label=MOVE_GHOST
c $87A6 Drive a ghost
D $87A6 Sprites $62 and $63. As with the bats there is a second ghost, sprites $68 and $69, with its own routine in MOVE_GHOST_ALT.

@ $8672 label=MOVE_GHOST_ALT
c $8672 Drive the other kind of ghost
D $8672 Drives two separate runs of codes, $5E-$5F as well as $68-$69, so one routine is behind two different-looking things. Only the second is known to be a ghost.

@ $8862 label=MOVE_MUMMY
c $8862 Drive the mummy
D $8862 Sprites $70 to $73 -- four frames rather than the two most creatures get.

@ $8988 label=MOVE_FRANKENSTEIN
c $8988 Drive Frankenstein's monster
D $8988 Sprites $74 to $77, four frames. One of the four creatures whose touch costs eight units of life force through LOSE_FOOD_8.

@ $89ED label=MOVE_DEVIL
c $89ED Drive the devil
D $89ED Sprites $78 to $7B. One of the four whose touch costs eight units through LOSE_FOOD_8.

@ $8906 label=MOVE_DRACULA
c $8906 Drive Dracula
D $8906 Sprites $7C to $7F, four frames.

@ $8A2F label=MOVE_WITCH
c $8A2F Drive the witch
D $8A2F Sprites $90 to $93. The countdown at +$0D and the arithmetic shift of +$09 give her flight its rise and fall: SRA halves the vertical speed while keeping its sign, so she coasts upward, slows and drops rather than moving at a constant rate.

@ $95D7 label=GRAVESTONE
c $95D7 The gravestone left where the player died
D $95D7 Sprite $8F, and nothing more than a jump into the routine that draws a thing and leaves it alone. DROP_OBJECT is what puts one down: on dying, seven bytes of the player's record are copied into a free slot and given this sprite, so the stone stands exactly where the body fell.
D $95D7 Confirmed live by starving the player -- the first of the four slots came back reading 8F 00 68 60 68 45 FF 08, sprite $8F at the player's own position.

@ $8AFF label=MOVE_HUMPBACK
c $8AFF Drive the humpback
D $8AFF Sprites $9C to $9F. MOVE_ACTOR singles this creature out by name: masking a sprite code with $FC and comparing against $9C matches all four of its frames at once, and those are let past a test the ordinary wanderers have to make.

@ $8A80 label=MOVE_8A80
c $8A80 Drive two unrelated creatures
D $8A80 Covers sprites $94 to $9B, which are not one creature in eight frames but two in four each: $94-$97 is a running figure, $98-$9B a bat -- the third distinct bat in the game, after those driven by MOVE_BAT and MOVE_BAT_ALT. What the two have in common that lets them share a routine has not been established, so the routine is left with a name that claims nothing.

@ $85F7 label=SPAWN_MONSTER
c $85F7 The sprite a monster arrives as
D $85F7 Sprites $58 to $5B, four frames of a monster appearing. Nothing wanders in from another room: a creature is spawned into the one the player is in, and this is what is drawn while it does.

@ $871A label=MOVE_871A
c $871A Drive the creature at $60-$61
D $871A Two frames of a small squat monster, nine pixels tall, whose limbs pull in and stretch out again -- eleven pixels wide in the first frame and fifteen in the second. Which creature it is has not been established.

@ $81F0 label=SPIN_SPELL
c $81F0 Drive the wizard's spell
D $81F0 Sprites $34 to $37, and the odd one of the three weapons: where the sword and the axe are solid shapes redrawn at eight angles, this is a scatter of loose pixels that changes shape rather than turning, which is what makes it read as magic rather than as a thrown object. Two of its four frames are identical.
D $81F0 Confirmed by firing as each character and reading the weapon type out of the player record: the wizard's shots come back as $36, inside this range, while the knight's are $41-$47 and the serf's $3E.

# --------------------------------------------------------------------------
# Where a sprite's graphics live
# --------------------------------------------------------------------------

@ $9E89 label=SPRITE_ADDRESS
c $9E89 Find a sprite's graphics
D $9E89 Sprite numbers are 1-based, so one is taken off before doubling into SPRITE_TABLE. This is the lookup the general drawing path uses, and it is the one that covers every sprite in the game -- the catalogue of pictures is built by driving this path, which is why it can draw codes right across the range.
R $9E89 A The sprite number
R $9E89 DE On exit, that sprite's graphics
  $9E89,5 Numbered from 1, two bytes an entry.
  $9E8E,4 The table.
  $9E92,3 The address it holds.

; span $A4BE,478
@ $A4BE label=SPRITE_TABLE
b $A4BE The address of every sprite's graphics
D $A4BE 239 addresses, two bytes each, indexed by sprite number less one, running from $A4BE to $A69B. The graphics themselves start immediately after it.
D $A4BE It is three tables end to end, which is why the count is 239. The first 161 entries, to $A5FF, are the creatures and objects -- two bytes wide, one byte of row count. The next 39, from $A600, are the pieces the rooms are furnished with, which carry a width as well. The last 39, from $A64E, are not pictures at all: they are those same pieces' attribute tables, one colour per character cell in the same width-and-height format.
D $A4BE Entry N of the third table belongs to entry N of the second, which is how one picture serves four doors: $A9 to $AC all point at the graphic at $A69C and differ only in their colours -- $43 $42 for red, $44 green, $45 cyan, $46 yellow. The three bases the code uses, $A4BE, $A600 and $A64E, are not a bias trick after all; they are simply where each table starts.
D $A4BE The count is measured rather than assumed: every code was drawn on a machine of its own with its reads logged, and 239 is the highest whose entry points at something the drawing code can read. Entries beyond that hold values like $1804 and $33F8, which are not addresses in this game at all.
D $A4BE FETCH_SPRITE and FETCH_SPRITE_ATTRS were read here as biased views of a single table, on the grounds that $A600 is its 161st entry and $A64E its 200th. That is arithmetically true and the wrong way round: they are separate tables, and the arithmetic works because they follow each other.

# --------------------------------------------------------------------------
# Drawing a sprite at any x
# --------------------------------------------------------------------------

@ $9F9F label=SETUP_SPRITE_DRAW
c $9F9F Work out where a sprite goes, and how far to shift it
D $9F9F Sprites in this family are two bytes wide in the data and land on the screen straddling two or three, because x is a pixel position and not a character column. Rather than keep eight pre-shifted copies of every sprite, the game shifts at draw time -- and rather than loop, it computes where to jump into an unrolled chain of shifts and writes that into the jump itself.
D $9F9F The displacement is 2 * ((x - 1) AND 7), which SHIFT_AND_PLOT's JR turns into "skip this many bytes of the chain". More shifts for a small offset, fewer for a large one. The one case that would need none is redirected to a plot routine that does not shift at all.
R $9F9F IX The thing being drawn
  $9F9F,3 Its graphics, through SPRITE_TABLE.
  $9FA2,6 Its position.
  $9FA8,5 The low three bits of x, doubled: how far into the shift chain to start.
  $9FAD,4 A shift of none is a special case...
  $9FB1,2 ...redirected right out of the chain to a plot with no shifting at all.
  $9FB3,3 Write it into the JR at $9F29.
  $9FB6,5 Two bytes of sprite cover three columns unless it lands square.
  $9FBB,3 How wide to erase and redraw.
  $9FC1,7 The first byte of a sprite's data is its height in rows.

@ $9F21 label=SHIFT_AND_PLOT
c $9F21 Shift one row of a sprite into place and draw it
D $9F21 Reads two bytes of the row into HL and then jumps into the chain below at whatever depth SETUP_SPRITE_DRAW patched in. Each step there is ADD HL,HL with ADC A,A behind it, so the pair behaves as a 17-bit shift left: the bit falling off HL is caught in A, which becomes the third byte on screen.
  $9F21,2 The row.
  $9F23,4 Two bytes of it, and step past them.
  $9F27,2 A starts empty and collects the bits pushed out of HL.
  $9F29,2 Reads as a jump to itself; by the time it runs the displacement has been overwritten, and it lands part-way down the chain.

@ $9F2B label=SHIFT_CHAIN
c $9F2B Seven shifts, entered part-way down
D $9F2B Not a loop: seven copies of the same two instructions, one after another, so that jumping in n pairs from the top performs 7 - n shifts with no counter and no branch. The whole cost of positioning a sprite to the pixel is one patched jump.
  $9F2B,14 Seven ADD HL,HL / ADC A,A pairs. Entering at the top shifts seven times, two bytes in six, and so on.
  $9F39,5 Whatever the shift, the row ends up here to be XORed onto the screen.

# --------------------------------------------------------------------------
# Sound effects played directly
# --------------------------------------------------------------------------

@ $A3C7 label=SOUND_FOOTSTEP
c $A3C7 The footstep, two tones alternating
D $A3C7 Called every frame by all three characters' handlers -- UPDATE_KNIGHT, UPDATE_WIZARD and UPDATE_SERF -- so walking sounds the same whoever is doing it. A counter at $5E2F advances on every call and its bottom two bits do all the work: bit 0 decides whether to make a sound at all, so only every other call does, and bit 1 chooses which of two notes.
D $A3C7 The two are $6004 and $4004 -- four cycles each, of half-period $60 and $40 -- which measure at about 1360 Hz and 2005 Hz. They alternate, so a walking character produces low, high, low, high rather than one repeated click. That is the whole footstep: two tones and a counter.
R $A3C7 None; it reads and advances $5E2F itself
  $A3C7,5 The step counter, advanced on every call.
  $A3CC,4 Bit 1 picks the note.
  $A3D0,3 Bit 0 silences every other call, which is what sets the pace.
  $A3D3,5 The higher of the two, about 2005 Hz.
  $A3D8,3 The same gate on the other branch.
  $A3DB,5 The lower, about 1360 Hz.

@ $A3E0 label=SOUND_BONUS
c $A3E0 The note that goes with the flashing score
D $A3E0 One call from FLASH_SCORE, once every sixteen steps of its countdown. BC is $8060 -- half-period $80, and $60 is 96 cycles of it -- which measures as 96 milliseconds at about 1030 Hz: a clear steady pip rather than a sweep, and long enough to be heard over everything else.

@ $A427 label=SOUND_SWEEP_UP
c $A427 A rising sweep
D $A427 Sixteen calls to BEEP with the pitch walked from one end to the other, so the note climbs. Measured at roughly 16 milliseconds, sweeping from about 500 Hz upwards. Reached from the serf's handler by way of $8283.
  $A427,2 Sixteen steps.
  $A429,7 The pitch for this step, derived from the step number.
  $A431,3 One short note.

@ $A438 label=SOUND_SWEEP_DOWN
c $A438 A short falling sweep
D $A438 Eight steps rather than sixteen, and the pitch complemented so it falls where SOUND_SWEEP_UP rises. About 14 milliseconds, and barely moving -- 520 to 556 Hz -- so it lands as a blip rather than a slide.
  $A438,2 Eight steps.
  $A43A,3 Complemented, so the pitch falls.
  $A43E,3 One short note.

@ $A445 label=SOUND_SPELL
c $A445 The wizard's spell
D $A445 Called from SPIN_SPELL, along with $A4B0. Unlike the fixed sweeps this one takes its starting pitch from $5E25, the count of actors in the room, so the spell does not sound quite the same twice. Measured at about 6 milliseconds across 1900 to 3700 Hz.

@ $A46E label=SOUND_NOISE_BURST
c $A46E A short burst of noise
D $A46E Run from a cold machine it lasts about 8 milliseconds and puts out 119 speaker edges with the gaps between them swinging wildly -- 843 Hz at the widest and far above hearing at the narrowest. That is not a note; it is a rasp.
D $A46E Reached from FLASH_AND_RASP, and by JP rather than CALL, so it returns to whoever called that rather than to the jump. That also makes it awkward to capture on its own during play: there is no return address on the stack to stop at. An earlier note put the caller at $917D, which was wrong -- the call site sits inside a block the automatic pass had left as data, so it was attributed to the nearest entry above it.
D $A46E An earlier note here claimed this was a full second of sound sweeping the audible range, which was wrong. The measurement behind it came from running several sound routines in turn on one machine, so this one inherited the state the others left and took a longer path than it ever does in the game.

# --------------------------------------------------------------------------
# Collectables
# --------------------------------------------------------------------------

c $92F5 The handler for a collectable
D $92F5 The playthroughs that build the code map never reach this, so the automatic pass leaves it as data. It is not: the bytes decode cleanly as code from the first byte, and forcing it here costs nothing -- the round-trip check still reassembles the whole game byte for byte, which it could not do if the split were wrong.

@ $92F5 label=PICK_UP
c $92F5 Pick a collectable up
D $92F5 The handler for sprites $80 to $8E -- the keys and the objects that kill the four big monsters. Like the food it does nothing but wait: every frame it asks whether the player is standing on it, and only then acts.
D $92F5 Picking something up is not free. The player can hold three things, and taking a fourth pushes the oldest out, so the three calls at the end run in the order they have to: DROP_CARRIED first, while the item about to be lost can still be read, then SHIFT_CARRIED to make room, then REMEMBER_CARRIED to put the new one at the front.
R $92F5 IX The collectable
  $92F5,3 Position and sprite into the workspace.
  $92F8,13 Two gates before anything else is considered.
  $9305,6 And the player has to actually be in play, the same $01-$30 test CHECK_HIT makes.
  $930D,5 Standing on it?
  $9312,8 Mark that something is being carried.
  $931A,3 Put the oldest of the three back into the world...
  $931D,3 ...shift the other two along...
  $9320,3 ...and record the new one at the front.

@ $9326 label=REMEMBER_CARRIED
c $9326 Record what has just been picked up
D $9326 Writes four bytes into the first slot at $5E30: the address of the object's own record, then its sprite and its drawing mode. Keeping the address rather than a copy is what lets DROP_CARRIED put the thing back exactly as it was.

@ $934C label=SHIFT_CARRIED
c $934C Move the carried items along one slot
D $934C Three slots of four bytes at $5E30, $5E34 and $5E38. LDDR copies the eight bytes at $5E30 up to $5E34, so the newest slot is freed and whatever was in the third is overwritten -- which is why DROP_CARRIED has to run first.

@ $9358 label=DROP_CARRIED
c $9358 Put the oldest carried thing back in the room
D $9358 Reads the third slot at $5E38 and returns at once if it is empty, so nothing happens until the player is already carrying three. Otherwise it builds a record where the player is standing -- the sprite it had, the player's room from $EA91, then $80, then the player's x and y from $EA93 and $EA94 -- so a dropped object lands at your feet and can be picked straight back up.
  $9358,7 The slot about to be lost.
  $9361,2 Nothing there: the player is not carrying three yet.

# --------------------------------------------------------------------------
# Routines the code map never reached
#
# Each of these is the target of an entry in ACTOR_HANDLERS or one of the two
# sprite-drawer tables, so it is certainly code; the playthroughs that build
# the map simply never took the path that runs it. Left alone, the automatic
# pass renders them as DEFBs. Forcing them costs nothing and is checked: if
# any one of them were not code, the round-trip would stop reassembling the
# game byte for byte.
# --------------------------------------------------------------------------

c $91BC
c $9252
c $9421
c $988B
c $99E5
c $9AEF
c $9D47
c $9DF8

@ $988B label=MUSHROOM
c $988B The mushroom that drains you
D $988B Sprite $A1. Standing on it is not fatal at once -- it takes a unit of life force per pass and loops, so the drain continues for as long as the player stays on it and stops the moment they step off. Reaching zero there kills as surely as anything else.
D $988B When nobody is on it, it cycles its colour rather than its shape: the low two bits of a counter index four attribute bytes at $98C4, and only the drawing mode in +$05 changes. The sprite itself never moves.
R $988B IX The mushroom
  $988B,6 Is the player standing on it?
  $9891,2 Yes -- start draining.
  $9893,11 Otherwise advance the colour, every fourth frame.
  $989E,11 Four colours, cycled by the low two bits.
  $98AB,6 Only the drawing mode changes; the shape is the same every time.

; span $98B1,19
c $98B1 Drain a unit of life force and go round again
  $98B1,7 A unit of life force, every pass round the loop.
  $98B8,3 It has run out: die.
  $98BB,6 Otherwise redraw the roast and make a noise about it...
  $98C1,3 ...and go round again while the player is still on it.

; span $98C4,4
b $98C4 The mushroom's four colours
D $98C4 Indexed by the low two bits of its counter, and written straight into +$05 as the drawing mode.

c $98C8

# --------------------------------------------------------------------------
# Doors only one character can use
# --------------------------------------------------------------------------

@ $9421 label=DOOR_SERF
c $9421 A door the serf can use
D $9421 Three doors, three entry points, one test. Each subtracts a character's first sprite from the player's current one and asks whether what is left is under $10 -- which is exactly "is the player this character", since each character owns sixteen consecutive sprite codes. $9421 takes $21 for the serf, $9428 takes $11 for the wizard and $942F takes 1 for the knight, and the three sprites that reach them are $BC, $B9 and $B2.
D $9421 Pass the test and the thing behaves as an ordinary door, through the same $91F2 that every other door goes through. Fail it and control goes to $91FE instead, which draws it and nothing more: the door is there, visible, and will not open.
R $9421 IX The door
  $9421,5 The serf's sprites start at $21.
  $9428,5 The wizard's at $11.
  $942F,4 The knight's at 1.
  $9433,4 Sixteen codes per character, so anything under $10 is a match.
  $9437,6 The right character: let them through.
  $943D,6 The wrong one: draw it and leave it shut.

# --------------------------------------------------------------------------
# Why there are eight ways to draw a sprite
# --------------------------------------------------------------------------

@ $9A92 label=REVERSE_BITS
c $9A92 Turn a byte back to front
D $9A92 Eight rotations: each one shifts a bit off the top of A into the carry and back into the bottom of C, so C ends up holding A's bits in the opposite order. That is a sprite byte mirrored, and mirroring every byte of a row while reading the row's bytes backwards mirrors the whole sprite.
D $9A92 It is what saves the game from storing anything twice. A creature facing left and the same creature facing right are one set of bytes and a different drawing routine.
R $9A92 A The byte
R $9A92 A On exit, the same bits in reverse
  $9A92,3 Eight bits to move.
  $9A95,5 Off the top of A, into the bottom of C.
  $9A9A,3 C now holds it reversed.

@ $9A9D label=NEXT_SPRITE_ROW
c $9A9D Step the sprite pointer on by one row
D $9A9D DE += B, where B is the width in bytes. The counterpart at $9AA5 subtracts instead, for the routines that read a sprite from the bottom up.

@ $99E5 label=BLIT_SPRITE_MIRRORED
c $99E5 Copy a sprite to the screen, back to front
D $99E5 BLIT_SPRITE with two changes: the row is walked with DEC DE rather than INC DE, and every byte goes through REVERSE_BITS on the way out. Between them those mirror the sprite horizontally without a second copy of the data.
D $99E5 It patches its own combining instruction the same way BLIT_SPRITE does -- $9D19 hands back an opcode and it is written over the NOP in the loop.
  $99E5,7 The combining opcode, into the loop below.
  $99EF,5 Start of a row.
  $99F4,5 Backwards through the row, reversing each byte.
  $99F9,1 Assembled at run time: NOP, OR, XOR or AND.

@ $9AEF label=BLIT_SPRITE_FLIPPED
c $9AEF Copy a sprite mirrored and upside down
D $9AEF Mirrored like BLIT_SPRITE_MIRRORED, and turned over as well: the call to $9ABA moves the data pointer to the last row before anything is drawn, so the rows come out in the opposite order.
D $9AEF This is why there are eight drawing routines in each family rather than one. Four are the four orientations a sprite can be put on the screen in -- as stored, mirrored, upside down, or both -- and the drawing mode in the top three bits of an actor's +$05 picks between them. A creature that walks in four directions is one set of bytes.
  $9AEF,7 The combining opcode.
  $9AF9,3 Move to the last row: this one draws bottom to top.

# --------------------------------------------------------------------------
# Locked doors and the keys that open them
# --------------------------------------------------------------------------

@ $9273 label=FIND_CARRIED
c $9273 Is the player carrying this?
D $9273 Walks the three slots of the inventory looking for one that matches on both bytes: the sprite in E and the drawing mode -- which for a key is its colour -- in D. It starts at $5E32 rather than $5E30 because the first two bytes of a slot are the object's address; the sprite and the mode are the third and fourth, which is exactly what REMEMBER_CARRIED put there.
R $9273 E The sprite to look for
R $9273 D The colour it has to be
R $9273 F Zero flag set if it is being carried
  $9273,5 Three slots, four bytes each, starting at the sprite byte of the first.
  $9278,5 Wrong sprite: on to the next slot.
  $927D,3 Right sprite, right colour: found.
  $9280,5 Step over the rest of the slot.

@ $9222 label=DOOR_NEEDS_KEY
c $9222 Will this locked door open?
D $9222 The coloured doors. Each carries its colour in the low two bits of its own sprite, which index four attribute bytes at DOOR_COLOURS, and the door opens only if the player is carrying a key -- sprite $81 -- of that same colour.
D $9222 So the lock is not a flag anywhere. The door's colour is part of its sprite number, the key's colour is the drawing mode stored with it when it was picked up, and opening the door is a comparison of the two.
R $9222 IX The door
R $9222 F Carry set if it opens
  $9222,5 The low two bits of the sprite are the colour.
  $9227,6 Look it up.
  $922D,3 $81 is a key; D is the colour it has to be.
  $9230,6 Not carrying it: the door stays shut.
  $9236,6 Carrying it: behave as an ordinary doorway from here on.
  $923F,5 Draw it shut and report no.

; span $925C,4
@ $925C label=DOOR_COLOURS
b $925C The four door colours
D $925C Indexed by the low two bits of a door's sprite. The same four values are what a key carries as its drawing mode, so the comparison in FIND_CARRIED is between a door's colour and a key's colour with no translation in between.

@ $91BC label=FLASH_AND_RASP
c $91BC Draw something twice over and make a noise
D $91BC Draws the thing with the low bits of its drawing mode forced on, then again with the bottom bit of its sprite flipped -- the other animation frame -- then puts the mode back and draws it properly, and finishes by jumping into SOUND_NOISE_BURST. Three overlapping draws and a rasp, which is what a thing being destroyed looks and sounds like.
  $91BC,7 One gate before any of it.
  $91CC,9 Force the low bits of the drawing mode on, and draw.
  $91D8,11 The other frame, over the top.
  $91E3,7 Put the mode back and draw it properly.
  $91EA,3 And the rasp.

# --------------------------------------------------------------------------
# The main loop
# --------------------------------------------------------------------------

@ $7DC3 label=MAIN_LOOP
c $7DC3 The loop the whole game runs in
D $7DC3 Everything the game does happens here. It walks three tables of records and hands each one to DISPATCH_ACTOR, which finds its handler from its sprite byte; there is no other structure above this. Monsters, doors, objects, the player and even the sound effects are all just records this loop reaches.
D $7DC3 The three tables have different shapes and are treated differently. From $EAA8 to $EE60 are eight-byte records -- objects, collectables, sounds -- and those are only dispatched if their room matches the player's. From $EE60 to $EEE0 are the sixteen-byte monster records, dispatched every pass whatever room they are in, which is how creatures keep moving around a castle you cannot see. From $EEE0 up are the doors, eight bytes again.
D $7DC3 Two details in the first three instructions are worth more than they look. The stack pointer is reset at the top of every pass, so no handler has to leave the stack as it found it -- which is what lets LOSE_FOOD_16 abandon its caller and jump straight to the death routine. And the EI here is where the DI at the entry point is finally lifted: everything before this runs with interrupts off.
  $7DC3,3 Reset the stack every pass; handlers need not balance it.
  $7DC6,1 Interrupts on. This is where the DI at ENTRY is undone.
  $7DC7,4 Count of actors in the player's room, recounted each pass.
  $7DCB,4 The first table: objects and sounds, eight bytes each.
  $7DE7,6 Only things in the player's room are dispatched from this one.
  $7DED,6 The return address goes in HL, and the dispatch is a jump rather than a call.
  $7DF3,5 Eight bytes to the next record.
  $7DF8,9 Until the monster table is reached.

@ $7E13 label=MAIN_LOOP_MONSTERS
c $7E13 The second pass: the monsters
D $7E13 Sixteen bytes a record rather than eight, and no room test -- every monster is dispatched every pass wherever it is. That is what keeps the castle alive behind the player rather than freezing rooms they have left.
  $7E13,5 Sixteen bytes to the next monster.
  $7E18,9 Until the door table is reached.

@ $7EB2 label=FRAME_TICK
c $7EB2 The work that happens once per frame
D $7EB2 MAIN_LOOP runs as fast as it can and calls this only when the ROM's frame counter has moved on, so what happens here is tied to the 50Hz interrupt rather than to how much there is to do.
D $7EB2 It dispatches three records the main loop deliberately skips -- $EA90, $EA98 and $EAA0, the player, the weapon it has in flight, and the sound effect slot -- and then ticks the clock. That is why the player moves at a steady speed however crowded a room is, while the monsters are dispatched on every pass of the outer loop.
D $7EB2 It runs with interrupts off, so a frame's work is never interrupted half way.
  $7EB2,1 Nothing may interrupt a frame's work.
  $7EB5,5 A flag saying a frame is in progress.
  $7EBA,4 The player, first of the three.
  $7EBE,4 Push the return address, then enter DISPATCH_ACTOR below its own PUSH HL -- it has already been done here.
  $7EC2,3 Dispatch.

@ $7EC5 label=FRAME_TICK_NEXT
c $7EC5 On to the next of the three, then the clock
D $7EC5 Eight bytes at a time from the player up to $EAA8, which is where MAIN_LOOP's own first table begins -- so between them the two loops cover every record exactly once, at two different rates.
  $7EC5,5 Eight bytes on.
  $7ECA,9 Until the main loop's first table is reached.
  $7ED5,3 Then advance the clock.

# --------------------------------------------------------------------------
# A door has two sides
# --------------------------------------------------------------------------

@ $9286 label=DOOR_OTHER_SIDE
c $9286 Swap IX to the far side of a door
D $9286 A door is two records, one for each room it joins, and they are deliberately put eight bytes apart so that the other side is found by flipping one bit of the address. No pointer, no table, no search: XOR the low byte with $08 and IX is looking at the other half.
D $9286 That pairing is why the door records read out of a running game sit at $EEE0 and $EEE8, $EEF0 and $EEF8. Each side carries the destination and arrival position for going that way, so walking through is a matter of reading the record you did not touch.
R $9286 IX A door; on exit, its other side
  $9286,3 IX into HL, where its low byte can be got at.
  $9289,4 One bit is the whole of it.
  $928D,3 And back into IX.

c $954D Open a door, both halves at once
D $954D Clear bit 3 of the drawing mode -- the bit that says a door is shut -- and clear it on the far side too, so the two halves never disagree about whether the door is open. DOOR_NEEDS_KEY calls it when the player is carrying the right key, and the character doors when the right character walks up.
  $954D,8 Bit 3 off: open.
  $9555,5 Now the other side.
  $955A,8 The same there.

c $9565 Shut a door, both halves at once
D $9565 The opposite of the routine above: set bit 3 on both halves, so the door is drawn shut and stays that way. This is what runs when the key is missing or the wrong character is standing there -- the door is still drawn, it simply does not open.
  $9565,8 Bit 3 on: shut.
  $956D,5 And the far side.
  $9572,8 The same there.

# --------------------------------------------------------------------------
# What is in each room
# --------------------------------------------------------------------------

@ $902B label=POPULATE_ROOM
c $902B Set up the records that belong to a room
D $902B Every room has a list of the things in it -- its doors, and whatever else is fixed there. ROOM_CONTENTS holds one pointer per room, and this walks the list it finds, stopping at the $0000 that ends it.
D $902B The addresses in the lists are not runtime addresses -- they point into the template at $600D that LOAD_INITIAL_STATE copies to $EA90, and taking $757D off one relocates it. That is not an arbitrary bias: $EA90 minus $600D is $8A83, and subtracting $757D is the same as adding $8A83 in sixteen bits. Room $00's list holds $645D, which is $0450 into the template and therefore $EEE0 once copied -- the door record a running game really has there.
D $902B So the lists can be written once, against the template, and go on being correct after it has been moved.
D $902B The check part-way down is the door pairing again. A door is two records eight bytes apart, one per room; if the one named in the list belongs to the other room, eight is added to reach the half that belongs to this one.
R $902B IX A record whose +$01 is the room to set up
  $902B,5 The room number.
  $9030,8 Two bytes per room, into the table.
  $9038,3 The start of this room's list.
  $903B,8 The next entry, and $0000 ends the list.
  $9044,7 Take the bias off to get the record's real address.
  $904B,4 Is this the half that belongs to the room being set up?
  $904F,5 No -- the other half is eight bytes along.

; span $757D,300
@ $757D label=ROOM_CONTENTS
b $757D What is in each room
D $757D One pointer per room, 150 of them, each to a $0000-terminated list of the records that belong to that room. Read out of the game, room $00's list names $EEE0, $EEF0 and $EF00 -- which are exactly the door records found in the running game when the player starts there.
D $757D The lists themselves follow immediately, from $76A9 on. Their entries are addresses into the initial-state template at $600D rather than into the runtime tables, and subtracting $757D is exactly the relocation from one to the other. See POPULATE_ROOM.

# --------------------------------------------------------------------------
# Firing, spawning, and steering
# --------------------------------------------------------------------------

@ $817C label=FIRE_WEAPON
c $817C Launch the player's weapon
D $817C Sets the weapon's velocity from the direction the player is facing: +4, -4 or nothing on each axis, taken from the sign of +$06 and +$07. A shot therefore travels four pixels a frame along whichever axes the player was moving on, and a diagonal shot moves on both.
D $817C Confirmed live -- firing and reading the weapon's velocity field back gives exactly $04 and $FC, and the shot's x walks across the room four pixels at a time.
R $817C IX The player
  $817C,3 The weapon's velocity field, +$0E of the player's record.
  $817F,5 Mark the weapon as in flight.
  $8184,5 And clear its contact flag.
  $8189,8 Standing still: nothing to fire along.
  $8191,6 Which way on this axis?
  $819A,4 Right or down.
  $819E,2 Left or up: $FC is minus four.
  $81A0,2 Store it and do the other axis the same way.

@ $83EA label=SPAWN_MONSTER_INTO_ROOM
c $83EA Put a new monster into the room
D $83EA Monsters are not placed once and left. When the player is in the room named by $5E26, a countdown at $5E27 runs down and a new creature is dropped into the room when it expires -- which is why standing still in one place does not make you safe.
D $83EA It looks for a free slot among only the first three of the eight monster records, and gives up if all three are taken. Those three are also the ones INERT_SPRITE bothers to burn time for, so the spawning slots and the timed slots are the same three.
D $83EA A new monster is a straight sixteen-byte copy of a template at $8B6A -- one LDIR, and the record is complete.
  $83EA,8 Only in the room the spawner is watching.
  $83F2,2 Wrong room: nothing to do.
  $83F4,5 The countdown to the next one.
  $83FB,2 Not yet.
  $83FD,8 Three slots, sixteen bytes apart.
  $8405,4 A zero sprite means the slot is free.
  $840E,6 The template.
  $8415,2 Sixteen bytes, and the monster exists.

@ $8EEF label=STEER
c $8EEF Move a heading towards a target, within limits
D $8EEF Adds E and D to the pair at +$06 and +$07 and clamps the result to L and H, handling the negative side by negating, comparing and negating back. The two fields are a signed heading, so this is how a creature turns towards something gradually rather than snapping round to face it.
  $8EEF,5 Not every call: the low nibble of +$02 gates it.
  $8EF6,4 Add the change to the horizontal part...
  $8EFA,3 ...taking the negative side separately.
  $8EFD,4 Clamp to the limit in L.
  $8F01,3 Store it.
  $8F04,4 And the vertical part the same way.
  $8F12,6 Both parts through the same conversion on the way out.

; span $8B6A,16
@ $8B6A label=MONSTER_TEMPLATE
b $8B6A A new monster, ready to copy
D $8B6A The sixteen bytes SPAWN_MONSTER_INTO_ROOM copies into a free slot. Read out of the game they are 58 00 5C 68 68 44 00 00 02 02 00 00 00 10 20 00, and every one of them means something already documented elsewhere.
D $8B6A The sprite is $58 -- not a creature but the arrival animation, so a new monster appears by materialising rather than blinking into existence. +$03 and +$04 are $68 and $68, the centre of the room. +$08 and +$09 are its starting velocities. And +$02 holds $5C, the spider: the same trick the player uses when dying, where the sprite to turn into when the animation finishes is parked in a spare field until it is needed.

# ------------------------------------------------------------------
# The sixteen drawing routines
# ------------------------------------------------------------------

@ $9A0A label=DRAW_PIXELS_2
c $9A0A Drawing mode 2: a sprite's pixels, the right way up
D $9A0A Entry 2 of PIXEL_DRAWERS. It fetches through FETCH_SPRITE, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9A50 label=DRAW_PIXELS_3
c $9A50 Drawing mode 3: a sprite's pixels, the right way up
D $9A50 Entry 3 of PIXEL_DRAWERS. It fetches through FETCH_SPRITE, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9ACB label=DRAW_PIXELS_4
c $9ACB Drawing mode 4: a sprite's pixels, upside down
D $9ACB Entry 4 of PIXEL_DRAWERS. It fetches through FETCH_SPRITE, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

; span $9B14,73
@ $9B14 label=DRAW_PIXELS_6
c $9B14 Drawing mode 6: a sprite's pixels, upside down
D $9B14 Entry 6 of PIXEL_DRAWERS. It fetches through FETCH_SPRITE, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9B5D label=DRAW_PIXELS_7
c $9B5D Drawing mode 7: a sprite's pixels, upside down
D $9B5D Entry 7 of PIXEL_DRAWERS. It fetches through FETCH_SPRITE, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9D25 label=DRAW_COLOURS_0
c $9D25 Drawing mode 0: a sprite's colours, the right way up
D $9D25 Entry 0 of COLOUR_DRAWERS. It fetches through FETCH_SPRITE_ATTRS, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9D47 label=DRAW_COLOURS_1
c $9D47 Drawing mode 1: a sprite's colours, the right way up
D $9D47 Entry 1 of COLOUR_DRAWERS. It fetches through FETCH_SPRITE_ATTRS, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9D6F label=DRAW_COLOURS_2
c $9D6F Drawing mode 2: a sprite's colours, the right way up
D $9D6F Entry 2 of COLOUR_DRAWERS. It fetches through FETCH_SPRITE_ATTRS, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9DA0 label=DRAW_COLOURS_3
c $9DA0 Drawing mode 3: a sprite's colours, the right way up
D $9DA0 Entry 3 of COLOUR_DRAWERS. It fetches through FETCH_SPRITE_ATTRS, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9DCE label=DRAW_COLOURS_4
c $9DCE Drawing mode 4: a sprite's colours, upside down
D $9DCE Entry 4 of COLOUR_DRAWERS. It fetches through FETCH_SPRITE_ATTRS, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9DF8 label=DRAW_COLOURS_5
c $9DF8 Drawing mode 5: a sprite's colours, upside down
D $9DF8 Entry 5 of COLOUR_DRAWERS. It fetches through FETCH_SPRITE_ATTRS, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9E21 label=DRAW_COLOURS_6
c $9E21 Drawing mode 6: a sprite's colours, upside down
D $9E21 Entry 6 of COLOUR_DRAWERS. It fetches through FETCH_SPRITE_ATTRS, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

@ $9E55 label=DRAW_COLOURS_7
c $9E55 Drawing mode 7: a sprite's colours, upside down
D $9E55 Entry 7 of COLOUR_DRAWERS. It fetches through FETCH_SPRITE_ATTRS, then copies row by row with the combining instruction patched in by SPRITE_COMBINE_OPCODE, the same as every other routine in the two tables.

# --------------------------------------------------------------------------
# How the drawing mode is laid out
# --------------------------------------------------------------------------

@ $9ABA label=START_AT_LAST_ROW
c $9ABA Point at the bottom row of a sprite
D $9ABA Multiplies the width by the height less one and adds it to the data pointer, so drawing can start from the far end. Called by every drawing routine whose mode number has bit 2 set -- which is how the eight modes divide: the low two bits choose the horizontal treatment and bit 2 turns the sprite over.
D $9ABA Checking all sixteen routines in the two tables bears that out exactly. Modes 0 to 3 leave the pointer where it is; modes 4 to 7 all begin by calling this.

# --------------------------------------------------------------------------
# Moving the player, and redrawing what is on screen
# --------------------------------------------------------------------------

@ $8D77 label=MOVE_PLAYER
c $8D77 Turn the controls into movement
D $8D77 The other end of READ_CONTROLS. It takes the byte that routine returns and turns it into a signed step on each axis: bit 0 right, bit 1 left, bit 2 down, bit 3 up, each tested for being clear because a zero bit is a pressed one. B holds the distance, so left is B negated and right is B as it stands.
D $8D77 The result goes through STEER rather than straight into the position, so the player accelerates into a direction and coasts out of it instead of starting and stopping dead.
R $8D77 IX The player
  $8D77,6 Remember which room this is happening in.
  $8D83,8 Mark the record as being worked on.
  $8D8B,6 Position into the workspace, then read the controls.
  $8D96,8 Left: the step, negated.
  $8D9E,5 Right: the step as it is.
  $8DA3,5 Down.
  $8DA8,8 Up: negated again.
  $8DB1,3 Apply it...
  $8DB5,6 ...through STEER, so the change is gradual.

@ $A00E label=WORKSPACE_AND_DRAW
c $A00E Note where a thing is, then draw it
D $A00E Copies the position out of the record into $5E16 and $5E17 before falling into the drawing proper. Those two are what the erase pass reads to find where something was last frame, so recording them here is what lets the next pass rub it out cleanly.
R $A00E IX The thing to draw
  $A00E,6 Where it is now...
  $A014,6 ...kept for the pass that will erase it.

@ $9291 label=DRAW_ROOM_CONTENTS
c $9291 Draw everything in the player's room
D $9291 Walks the eight-byte records from the player up to the monster table, drawing each one whose room matches the player's and skipping any whose sprite is zero. It is the sweep that puts the room's objects, doors and the player back on the screen after the play area has been cleared.
  $9291,4 From the player upwards.
  $9295,6 A zero sprite is an empty slot.
  $929B,8 And only things in this room.
  $92A3,3 Draw it.
  $92A6,5 Eight bytes to the next.

@ $94F5 label=SCAN_DOORS
c $94F5 Walk the doors, sixteen bytes at a time
D $94F5 Steps through the door table in pairs -- $EEE0 and $EEE8 together, then the next pair -- with the frame counter's low bits in H, and tests each sprite against $70. Doors in Atic Atac open and close of their own accord, and this is the sweep that decides which are which.
  $94F5,4 The frame counter drives it.
  $94F9,7 Low bits of the frame, with bit 4 forced on.
  $9502,9 The two halves of the first door, sixteen bytes to the next pair.

# --------------------------------------------------------------------------
# Firing, placing the player, and the menu
# --------------------------------------------------------------------------

@ $8283 label=TRY_FIRE
c $8283 Fire, if there is nothing already in the air
D $8283 Refuses outright if the weapon slot at $EA98 is occupied, so only one shot exists at a time -- that single test is the whole of the game's rate of fire. With the way clear it makes the sweep noise and calls FIRE_WEAPON to launch one.

@ $9443 label=PLACE_PLAYER
c $9443 Build the player's record from scratch
D $9443 Copies the eight-byte template at PLAYER_TEMPLATE over $EA90, having patched two things into it first: the room, from $EA91, and -- into the template's last byte, not its first -- the character's sprite, worked out from the menu selection the way DRAW_LIVES does it: shift $5E00 up, mask to $30, add 8.
D $9443 The first byte of the template is $66, and that is the point. A game does not begin with the player standing there; it begins with them rising out of the floor, because $66 is what MATERIALISING answers to. The character's own sprite goes into +$07, which is where FINISH_MATERIALISING looks when the animation ends.
D $9443 This is the answer to something that looked like a bug early on: reading the player's sprite byte a second after starting a game gives $66, not $08, and nothing responds to the controls. Nothing is wrong -- the player has not finished arriving.

@ $93E3 label=PUT_DOWN
c $93E3 Put a carried object down
D $93E3 The counterpart to PICK_UP, and gated the same way: the player has to be in play, and the flags at $5E20 and $5E1F have to agree that something is being carried. Where PICK_UP takes an object out of the room and into the three slots, this takes one back out of the slots and leaves it where the player is standing.

@ $7CAF label=DRAW_MENU
c $7CAF Draw the title screen's list of options
D $7CAF Points the tile source at the text font and then walks seven entries, each with its own string and position, writing the current one into $5E22 as it goes. Those seven are the six choices -- three control methods and three characters -- and the line that starts the game.

@ $917D label=WAIT_THEN_ACT
c $917D Count a delay down before doing anything
D $917D Runs on alternate frames only, and while the counter at $5E2E is above zero it does nothing but decrement it and draw. When it finally reaches zero the routine below it runs. Reached from the handlers for sprites $C2 and $C4.

@ $9924 label=ADVANCE_CURSOR
c $9924 Step a cursor on by one record
D $9924 Adds eight to the pointer kept at $5E55, but only on frames where the low bits of $5E12 and $5E13 are both clear -- so it creeps through a table a record at a time over many frames rather than sweeping it in one go.

; span $9481,8
@ $9481 label=PLAYER_TEMPLATE
b $9481 A player, ready to copy
D $9481 66 00 00 60 68 47 FF 00. Sprite $66 is the materialising animation, $60 and $68 the position, and the last byte is patched by PLACE_PLAYER with the sprite to turn into once the player has finished rising.

# --------------------------------------------------------------------------
# The long tail
# --------------------------------------------------------------------------

@ $814B label=TRY_FIRE_ALT
c $814B Fire, for one of the other characters
D $814B Instruction for instruction the same as TRY_FIRE -- refuse if a shot is already in the air, refuse if $5E2D says not now, make a noise, launch -- but it calls SOUND_SWEEP_DOWN where the other calls SOUND_SWEEP_UP. Each character has its own copy of this so that each can have its own firing sound, rather than one routine taking a parameter.

@ $882D label=HOME_IN
c $882D Set a heading towards the player
D $882D Compares the target's position with its own on each axis and sets the velocity fields to $FF or $01 accordingly -- the crudest possible pursuit, one pixel a frame towards wherever the player is, with no smoothing and no memory. It is what makes some creatures follow you rather than drift.

@ $8F96 label=DECAY_HEADING
c $8F96 Let a heading fall back towards nothing
D $8F96 The counterpart to STEER. Where that adds to the pair at +$06 and +$07, this subtracts from them towards zero, so a creature that stops being pushed coasts to a halt instead of stopping dead. Gated on the low nibble of +$02, so it only bites every so often.

@ $9E9B label=CLIP_ROWS
c $9E9B Draw only the rows that fit
D $9E9B Part of the drawing path that deals with a sprite hanging off an edge: it counts rows down in C and drops out early rather than letting the blitter run past the end of the play area. The alternate register set holds the second of the two counts, which is why it is full of EXX.

@ $98D2 label=CYCLE_ROOM_COLOUR
c $98D2 Work a value out of the frame counter and write it into the code
D $98D2 Takes the frame counter, looks it up in a small table at $990C, and stores the result at $603E -- an address inside the game's own code, not a variable. Another of the places where the game writes to itself rather than keeping state somewhere and testing it.

@ $A14D label=DRAW_LIST
c $A14D Draw a list of things through the scratch record
D $A14D Walks a list whose entries are drawn one at a time by loading each into UI_RECORD and using the ordinary sprite path, stopping at a zero pair. The same idea as DRAW_TITLE_ICONS, generalised: anything that has to be drawn without being an actor goes through here.

@ $9FCA label=DRAW_CLIPPED
c $9FCA Draw a sprite that may not fit
D $9FCA Sets the drawing up through SETUP_SPRITE_DRAW, then compares the thing's position against the workspace to work out how much of it is off the edge, handing the whole-sprite case and the two clipped cases to different routines. Called from the character handlers, which are the sprites most likely to be walking off the edge of the play area.

# --------------------------------------------------------------------------
# Clearing, starting, and the menu highlight
# --------------------------------------------------------------------------

@ $80B4 label=CLEAR_DISPLAY
c $80B4 Blank the display file
D $80B4 Writes $00 over $4000 for $58 pages -- the whole bitmap, all three thirds. The two routines below it share the same inner loop with a different address and length, which is why they are three entry points rather than three routines.

@ $80C2 label=CLEAR_ATTRIBUTES
c $80C2 Blank the attribute file
D $80C2 $5800 for $5B pages, through the same loop as CLEAR_DISPLAY.

@ $80CB label=CLEAR_VARIABLES
c $80CB Blank the game's variables
D $80CB $5E10 for $60 bytes -- the block holding the score, the clock, the inventory and everything else the game keeps about a session. Called when a new game starts.

@ $80AA label=CLEAR_SCREEN
c $80AA Blank everything and black the border
D $80AA Bitmap, attributes, and then an OUT to port $FE with zero, which sets the border black. The whole screen gone in three calls.

@ $7D9A label=START_GAME
c $7D9A Set a new game up
D $7D9A Clears the variables, sets the lives to three, points the cursor at $EB58, blanks the screen and goes on to build the castle. Everything a game needs to be true at its first frame is made true here.

@ $7CA4 label=UNHIGHLIGHT
c $7CA4 Take the highlight off a menu cell
D $7CA4 Clears bit 7 of an attribute -- the FLASH bit -- and steps on. The title screen shows the current choice by flashing it, so selecting is a matter of turning this bit off one line and on another.

@ $7CAB label=HIGHLIGHT
c $7CAB Put the highlight on a menu cell
D $7CAB Sets the bit UNHIGHLIGHT clears.

@ $7C90 label=HIGHLIGHT_LINE
c $7C90 Flash or unflash a whole menu line
D $7C90 Walks a line of attributes calling one or other of the two routines above, so a whole option lights up rather than a single character.

@ $7D8A label=PRINT_MENU_LINE
c $7D8A Print one line of the menu
D $7D8A Works out the display address and the attribute address for the same point -- one in each register bank, the trick PRINT_STRING uses -- and draws the line with the colour held at $5E22.

@ $8134 label=TRY_FIRE_THIRD
c $8134 Fire, for the third character
D $8134 The third of the three per-character fire routines, alongside TRY_FIRE and TRY_FIRE_ALT. Same three tests, same call to FIRE_WEAPON, and its own sound.

@ $7E93 label=DISPATCH_FROM_LIST
c $7E93 Dispatch a record named in a room's list
D $7E93 Takes an entry as ROOM_CONTENTS stores it, subtracts the $757D bias to get the real address, puts it in IX and dispatches it -- pushing a return address first, the same convention MAIN_LOOP uses.

@ $83BA label=VELOCITY_LOOKUP
c $83BA Index a table by a creature's vertical speed
D $83BA Doubles +$09 and adds it to a table at $83CA, then tests bit 2 of +$08. The pair of them are the velocity fields, so this is picking something -- a sprite or an offset -- out of a table according to how fast and which way a creature is moving.

# --------------------------------------------------------------------------
# Setting the castle up, and the small helpers
# --------------------------------------------------------------------------

@ $8D61 label=LOAD_INITIAL_STATE
c $8D61 Put the castle back the way it started
D $8D61 One LDIR of $1570 bytes from $600D to $EA90. Everything the game keeps at run time -- the player's record, the objects, the monsters, the doors, all of it -- exists as a template inside the loaded block and is copied wholesale into the working area.
D $8D61 So the runtime tables that do not appear in this disassembly, because they live above $D600, do appear in it after all: as five and a half kilobytes of data starting at $600D, waiting to be copied. Starting a new game is a single block move.

@ $86F2 label=RANDOM_VERTICAL
c $86F2 Give a creature a random up or down
D $86F2 Reads the refresh register, takes one bit to decide whether to act and two more to make plus or minus two, and drops the result into the vertical velocity. The same trick MOVE_ACTOR uses for direction, applied to one axis.

@ $8598 label=RANDOM_CHANCE
c $8598 Take a chance on the refresh register
D $8598 Compares R against a threshold in B, so a caller gets a yes or no with roughly known odds and no state to keep. R is not random, but it advances on every instruction fetch, and against a threshold it is unpredictable enough for a monster's whim.

@ $897D label=ROOM_SHAPE_OF
c $897D Find a room's shape number
D $897D Doubles the room number into ROOM_TABLE and steps one byte on, which lands on the shape rather than the colour.

@ $8F80 label=SCALE_SIGNED
c $8F80 Divide a signed value by eight
D $8F80 Negates a negative, shifts three times, and puts the sign back. It is how a heading in +$06 and +$07 becomes a movement of a pixel or two rather than tens of them.

@ $8D6D label=TICK_LOW_NIBBLE
c $8D6D Count down the low nibble of +$02
D $8D6D Does nothing once it reaches zero, so a creature that uses it gets a delay that expires and then stays expired until something sets it again.

@ $8F66 label=APPLY_HEADING
c $8F66 Move a creature, on the axes it is allowed to move on
D $8F66 Bits 4 and 5 of +$02 say whether the horizontal and vertical parts of a heading are to be applied. A creature pinned to one axis is not a special case in the movement code: it is the ordinary code with one of those bits clear.

@ $8FCA label=STEP_AND_TEST
c $8FCA Step a position and check what is there
D $8FCA Adds the step to +$03 and +$04 and then runs a sixteen-iteration loop over the result -- the check that stops a creature walking through a wall.

@ $8787 label=COUNTDOWN_ACTOR
c $8787 A creature on a timer
D $8787 Skips everything if it is in another room, then counts +$0E down and hands over when it reaches zero. Sprites $6C to $6F, the expanding burst, which is exactly what a thing on a fuse looks like.

@ $85EA label=MONSTER_CAUGHT_PLAYER
c $85EA Cost the player thirty-two and carry on
D $85EA The two-instruction path taken when a monster's proximity test succeeds: LOSE_FOOD_32, then back into the creature's movement. Being caught is expensive but not, on its own, fatal.

@ $82C3 label=SIGN_TO_DIRECTION
c $82C3 Turn a signed value into a direction code
D $82C3 Zero, positive or negative becomes 0 or 4 in C, which is then used to pick a sprite or a table entry. The game's usual way of turning "which way is it going" into "which picture".

@ $8ADB label=SCAN_EB18
c $8ADB Walk the eight records at $EB18
D $8ADB Eight records, eight bytes apart, skipping any whose first byte is zero -- the same shape as every other table walk in the game.

# --------------------------------------------------------------------------
# Doors, cursor keys, and more helpers
# --------------------------------------------------------------------------

@ $91F2 label=DOOR
c $91F2 An ordinary door
D $91F2 The plain doorway, and the routine every other kind falls back on once it has decided to let the player through. It offers $1111 as the tolerance, asks PLAYER_AT_DOOR whether anyone is standing in it, and calls ENTER_ROOM if so -- then draws itself either way.

@ $9244 label=DOOR_LOCKED_A
c $9244 A locked door of the first sort
D $9244 Asks DOOR_NEEDS_KEY whether the player has the matching key. With one it sets the sprite on both halves to $02 through SET_BOTH_HALVES and goes through to ENTER_ROOM; without one it just draws itself shut.

@ $9252 label=DOOR_LOCKED_B
c $9252 A locked door of the second sort
D $9252 The same as DOOR_LOCKED_A but setting $01 rather than $02, so the two look different once open. They share everything from the third instruction on.

@ $9260 label=SET_BOTH_HALVES
c $9260 Give both halves of a door the same sprite
D $9260 Writes the sprite into the record IX points at, then flips bit 3 of the address -- the DOOR_OTHER_SIDE trick -- and writes it into the far half too. An open door has to look open from both rooms.

@ $926C label=ADD_A_TO_HL
c $926C Add an unsigned byte to HL
D $926C Four instructions to do what the Z80 has no single instruction for. Used wherever a table is indexed by a byte, which is most places.

@ $9398 label=READ_CURSOR_KEYS
c $9398 Read the cursor keys
D $9398 The branch READ_CONTROLS takes when the cursor option was chosen. The cursor keys are not adjacent in the matrix the way Q, W, E, R and T are, so this reads a different half-row and assembles the same five bits by hand rather than swapping two of them.

@ $938B label=READ_FIRE_ROW
c $938B Read one key and remember whether it is down
D $938B Selects the half-row holding B, N, M, symbol shift and space, keeps one bit of it and leaves the answer at $5E20 for other routines to look at rather than reading the keyboard again.

@ $9489 label=CHECK_KEY_HELD
c $9489 Look at a key with interrupts off
D $9489 Turns interrupts off before reading the keyboard directly, so the answer cannot be disturbed half way. Returns at once unless the key is down.

@ $8FE9 label=DISTANCE_FROM_CENTRE
c $8FE9 How far from the middle of the room is this?
D $8FE9 Takes the distance from the room's centre column at $58, makes it positive, and compares it with the half-width in $5E1D. The same test MOVE_ACTOR makes inline, kept as a routine for the callers that need it separately.

@ $900A label=STEP_AND_TEST_2
c $900A Step a position and check it, the other way round
D $900A The companion to STEP_AND_TEST, differing in which axis leads.

@ $915F label=WAIT_THEN_DOOR
c $915F Count down, then behave as a door
D $915F The same delay WAIT_THEN_ACT runs, but ending in DOOR rather than a draw -- a doorway that will not work until its counter has run out.

@ $92E0 label=DRAW_AT_POSITION
c $92E0 Draw a thing where its record says it is
D $92E0 Sets the width, works out where the sprite lands from +$03, and draws. The plain "put it on the screen" ending that most creature handlers jump to when they have nothing else to do.

# --------------------------------------------------------------------------
# Arithmetic the Z80 does not have, and a few more
# --------------------------------------------------------------------------

@ $9AAD label=MULTIPLY
c $9AAD Multiply DE by A
D $9AAD Shift and add, eight times: the only multiply the game has, and the Z80's excuse for not having one. START_AT_LAST_ROW uses it to find the bottom of a sprite, and DRAW_ROOM to index the six-byte shape entries.

@ $9C61 label=PIXEL_MASK
c $9C61 Build a mask for one pixel in a byte
D $9C61 Takes the low three bits of an x coordinate and rotates a single set bit into that position. DRAW_LINE needs it for every point it plots, since a pixel is one bit of a byte the rest of which must survive.

@ $9AA5 label=PREVIOUS_SPRITE_ROW
c $9AA5 Step the sprite pointer back one row
D $9AA5 DE -= B. The mirror of NEXT_SPRITE_ROW, for the drawing modes that read a sprite from the bottom up.

@ $9904 label=TABLE_LOOKUP_3BIT
c $9904 Pick one of eight from a table
D $9904 Masks to three bits, adds to HL, reads the byte. Small enough to inline, kept as a routine because several callers want exactly this.

@ $9E96 label=SPRITE_OF_ACTOR
c $9E96 Find this actor's graphics
D $9E96 Takes the sprite number out of the record and falls into SPRITE_ADDRESS. The two-instruction convenience that most of the drawing path actually calls.

@ $9E86 label=SPRITE_OF_WORKSPACE
c $9E86 Find the graphics for what is in the workspace
D $9E86 The same as SPRITE_OF_ACTOR but reading the sprite from $5E15 rather than from a record -- for the paths that have already lifted it out.

@ $986A label=MODE_TO_INDEX
c $986A Turn a drawing mode into a table index
D $986A Rotates +$05 down and masks to $06, which turns the top bits of the drawing mode into an even number -- an index into a table of word-sized entries.

@ $98C8 label=MUSHROOM_KILLED_PLAYER
c $98C8 Rub the mushroom out and take the life
D $98C8 Erases it, frees its slot, and jumps into LOSE_LIFE. The mushroom is consumed by killing you.

@ $961B label=CARRYING_8C
c $961B Is the player carrying object $8C?
D $961B Walks the three inventory slots four bytes at a time looking for one particular sprite. Unlike FIND_CARRIED, which is given what to look for, this one has the answer built in, so $8C is an object the game asks about by name.

@ $96EC label=SHOW_END_SCREEN
c $96EC Draw the screen shown when a game ends
D $96EC Draws the player, points the tile source back at the text font and prints a line at $2040 from a string at $9710 -- the same shape as GAME_OVER, for a different ending.

@ $94B6 label=ROTATING_INDEX
c $94B6 A number that changes every frame
D $94B6 Adds the frame counter to $5E12 and keeps three bits, so callers get a value that walks 0 to 7 over time without anyone having to keep a counter for it.

@ $957D label=WITHIN_ROOM_BOUNDS
c $957D Is this position inside the room?
D $957D Compares a record's position against the room's half-extents at $5E1D, one more than the limit on each axis so that the boundary itself counts as inside.

# --------------------------------------------------------------------------
# The colour-writing family, and the last of the sounds
# --------------------------------------------------------------------------

@ $A07A label=FILL_ATTRS
c $A07A Write a sprite's colours into the attribute file
D $A07A The colour family's inner loop: a row of attribute cells written from D, stepping along with INC L. The seven routines that follow are the same loop with the direction reversed, the row stepped by $20 instead, or the second colour in E used -- one per drawing mode, exactly as the pixel family has one per mode.

@ $A08D label=FILL_ATTRS_BACK
c $A08D The same, written backwards
D $A08D DEC L rather than INC L, for the mirrored drawing modes.

@ $A0A3 label=FILL_ATTRS_2
c $A0A3 Another of the eight colour writers
D $A0A3 As FILL_ATTRS, for a different drawing mode.

@ $A0B7 label=FILL_ATTRS_3
c $A0B7 Another of the eight colour writers
D $A0B7 As FILL_ATTRS, for a different drawing mode.

@ $A0D2 label=FILL_ATTRS_ALT
c $A0D2 A colour writer using the second colour
D $A0D2 Writes from E rather than D, so a sprite drawn through this mode comes out in its alternate colour.

@ $A0EC label=FILL_ATTRS_ROW
c $A0EC A colour writer that steps a whole row
D $A0EC Adds $20 between cells -- one attribute row -- so it fills a column rather than a line.

@ $A0FE label=FILL_ATTRS_ROW_2
c $A0FE Another column-wise colour writer
D $A0FE As FILL_ATTRS_ROW, for a different mode.

@ $A110 label=FILL_ATTRS_4
c $A110 The last of the eight colour writers
D $A110 As FILL_ATTRS, for the remaining mode.

@ $A127 label=FILL_ATTRS_ROW_3
c $A127 A column-wise colour writer for the mirrored modes
D $A127 The $20 step of FILL_ATTRS_ROW with the reversal of FILL_ATTRS_BACK.

@ $A13B label=DRAW_INVENTORY
c $A13B Draw the three carried objects on the scroll
D $A13B Walks the three inventory slots at $5E30 and draws each through DRAW_LIST, starting at $2CC8 -- so what the player is carrying is shown by drawing the objects themselves rather than by any separate icon. An empty slot draws nothing.

@ $A185 label=ERASE_STRIP
c $A185 Blank twenty bytes where something was
D $A185 Works out the display address from a record's position and writes zero across twenty bytes -- the fastest way to rub out something that is about to be redrawn somewhere else.

@ $A219 label=DRAW_SCROLL
c $A219 Draw the scroll down the side of the screen
D $A219 Points the tile source at $B03A -- a set of tiles of its own, not the text font -- and lays out an eight by twenty-four block of them from $B32A at x $C0. The parchment border, drawn once when a game starts and left alone after that.

@ $9546 label=DOOR_OPEN_OR_SHUT
c $9546 Open or shut a door, according to its sprite
D $9546 Bit 0 of the sprite says which, so a door's own number carries whether it is currently open, and the two routines below do the work on both halves.

@ $9F4A label=DRAW_THING
c $9F4A Draw a record's sprite
D $9F4A Sets the drawing up through SETUP_SPRITE_DRAW, clears the working count at $5E18, and draws. The entry most handlers use when they simply want something on the screen.

@ $9F56 label=ERASE_THING
c $9F56 Rub a record's sprite out
D $9F56 The counterpart to DRAW_THING, working from the position saved in the workspace rather than the record's current one -- which is how something is erased from where it was rather than where it has just moved to.

@ $9F80 label=SETUP_ERASE
c $9F80 Work out where a thing used to be
D $9F80 Looks the sprite up from the workspace and computes the display address of the position saved in $5E16, so ERASE_THING can blank exactly the cells the last frame filled.

@ $9EE6 label=SHIFT_CHAIN_2
c $9EE6 The second unrolled shift chain
D $9EE6 Seven more ADD HL,HL and ADC A,A pairs, entered part-way down by a patched jump exactly as SHIFT_CHAIN is. There are two because the two plot endings -- one XORing, one storing -- each need their own chain to fall into.

@ $9ECE label=PLOT_XOR
c $9ECE Put two bytes on the screen with XOR
D $9ECE The ending both shift chains fall into: XOR the shifted bytes onto what is already there, which both draws a sprite and rubs it out again on a second pass.

@ $9F13 label=PLOT_XOR_2
c $9F13 The other XOR ending
D $9F13 As PLOT_XOR, reached from the other chain.

@ $9EDC label=FETCH_ROW
c $9EDC Read two bytes of a sprite row
D $9EDC Loads a row into DE ready for shifting, and steps the pointer on.

@ $A379 label=MULTIPLY_2
c $A379 Another multiply
D $A379 The same shift-and-add as MULTIPLY, kept separately for the sound routines so that they do not disturb the registers the drawing code is using.

@ $A39E label=NEGATE_HL
c $A39E Negate HL
D $A39E Subtracts HL from zero, which is the shortest way the Z80 has of negating a sixteen-bit value.

@ $A403 label=PLAY_SOUND_65
c $A403 Start sound $65
D $A403 Hands $650A to PLAY_SOUND's tail: sound $65, lasting ten frames.

@ $A485 label=PLAY_SOUND_A0
c $A485 Start sound $A0
D $A485 Hands $A010 to the same tail: sound $A0, sixteen frames.

@ $A48B label=SOUND_A0
c $A48B Sound $A0, one frame of it
D $A48B The third of the sound handlers, alongside SOUND_64 and SOUND_65. It takes its pitch from a table at $A4A0 rather than computing it, so its sweep is a shape someone chose rather than an arithmetic accident.

@ $A41B label=SOUND_SWEEP_A41B
c $A41B A short sweep
D $A41B Twelve steps of BEEP with the pitch walked down, about nine milliseconds. Reached from TRY_FIRE_THIRD, so it is one of the three firing noises.

@ $A45F label=SOUND_FROM_HEADING
c $A45F A sound whose pitch comes from a creature's heading
D $A45F Takes +$06, complements and masks it, and uses the result as the half-period -- so the noise a thing makes depends on which way it is going.

@ $A4B0 label=SOUND_SPELL_2
c $A4B0 The spell's second noise
D $A4B0 The other of the two sounds SPIN_SPELL makes, alongside SOUND_SPELL.

# --------------------------------------------------------------------------
# The castle, as it starts
# --------------------------------------------------------------------------

; span $600D,5488
@ $600D label=INITIAL_STATE
b $600D Every record in the game, before anything has happened
D $600D The 5488 bytes LOAD_INITIAL_STATE copies to $EA90 -- which is to say the whole of the runtime area, $EA90 to the top of memory, written out in full and moved into place with one LDIR. Nothing is built at run time; the castle is simply copied.
D $600D It is laid out exactly as the running game reads it, in the four regions MAIN_LOOP and FRAME_TICK walk. The bytes below are grouped one record to a line.
D $600D What is in it, read out of the data: three empty records for the player, the weapon and the sound slot, which are filled in when a game starts rather than here; 115 objects of the 119 slots, among them sixteen mushrooms and ten each of the six kinds of food; five monsters, one each of the mummy, Dracula, the devil, Frankenstein's monster and the humpback; and 274 doors.
D $600D The doors are the surprise. Every one is sixteen bytes, not eight -- one record holding both of its sides -- and the room lists confirm it: of the 274, exactly 272 are named by two different rooms, which is what a door joining two rooms looks like from the data. The remaining two are named once each. That is also why DOOR_OTHER_SIDE flips bit 3 of an address: it is moving between the two halves of a single record.
B $600D,24,8
B $6025,952,8
B $63DD,128,16
B $645D,4384,16

# --------------------------------------------------------------------------
# The two character sets
# --------------------------------------------------------------------------

; span $B03A,752
@ $B03A label=PANEL_TILES
b $B03A The character set the status panel is drawn from
D $B03A 94 characters, eight bytes each, top row first. DRAW_PANEL points the tile source at this and then draws 8 columns by 24 rows from PANEL_LAYOUT, so the parchment scroll down the right of the screen is not a bitmap at all -- it is a little character set, and a 192-byte map naming which piece goes in each cell.
D $B03A Running DRAW_PANEL and photographing the screen settles what it draws: the scroll, with the words TIME and SCORE on it and the compass at its foot. An earlier note here called it the title picture, which it is not.
D $B03A That the count is exactly 94 is confirmed by the map: the highest value in it is $5D, which is 93, the last character here.
B $B03A,752,8

; span $B32A,192
@ $B32A label=PANEL_LAYOUT
b $B32A The status panel, as tile numbers
D $B32A 24 rows of 8, each byte an index into PANEL_TILES. The loop at $A228 walks it a row at a time, calling PLOT_TILE for each cell and colouring it as it goes. The eight columns start at x=192, which is the first character column past the play area -- the same place PAINT_PANEL colours.
B $B32A,192,24

; span $BF4C,472
@ $BF4C label=TEXT_FONT
b $BF4C The text font
D $BF4C 59 characters, eight bytes each, for the codes $20 (space) to $5A ("Z") -- so the game can print spaces, digits, punctuation and capitals, and nothing else.
D $BF4C The code never names this address. It loads $BE4C into the tile source instead, which is this block less $20 characters, so that a character's own ASCII code indexes it. $965F and $A1AE load $BFCC for the same reason one bias further on: that is where "0" lives, so a digit's value indexes its own glyph with no adjustment at all. Drawing the two glyphs out confirms it -- $BFCC is a nought, $BE4C plus $41 characters is an A, and plus $5A is a Z.
B $BF4C,472,8

# --------------------------------------------------------------------------
# The screens either side of the game
# --------------------------------------------------------------------------

; span $7CEA,160
@ $7CEA label=MENU_DATA
b $7CEA The title screen's menu
D $7CEA Three tables and then the words. The seven lines are drawn by DRAW_MENU, which walks the colours and the row positions in step and takes each string in turn; a character with bit 7 set ends a string, which is why there are no lengths anywhere.
D $7CEA The last two strings are not part of the seven and carry their own colour byte in front, so they can be printed on their own.
B $7CEA,7,7 The colour of each line -- six in $45 and the last in $47, which is what makes START GAME brighter than the choices above it.
B $7CF1,7,7 The row each is drawn at, 24 pixels apart.
T $7CF8,89,11,20,20,9,9,7,13
T $7D51,33 The copyright line. "%" is the copyright sign in this font, not a per cent.
T $7D72,24

; span $967F,48
@ $967F label=END_LABELS
b $967F The three words on the end-of-game screen
D $967F Sixteen bytes each: a colour, then the word padded out with spaces to the width of the field, with bit 7 set on the last one. PRINT_END_FIGURES draws the numbers into the gap the padding leaves.
T $967F,48,16

; span $9710,33
@ $9710 label=END_MESSAGES
b $9710 What it says when you escape
D $9710 Two strings, each a colour byte then the text, with bit 7 on the last character. The first is misspelt: the bytes read CONGRATULATION and then $D4, which is "T" with the end marker set, so the screen says CONGRATULATIONT. Drawing the screen confirms it -- this is what the game shipped with, not a mistake in reading it.
T $9710,33,16,17

; span $9731,120
@ $9731 label=ESCAPE_SEQUENCE
c $9731 The sequence played when the player gets out
D $9731 Runs 128 times: each pass beeps a note whose pitch comes from the frame counter at $5C78, picks black or white from bit 3 of it, writes that into two cells of the attribute file and then floods the rest outwards with SPIRAL_FILL. So the screen flashes in and out from the middle while the note climbs. It ends by jumping straight back into the main loop at $9117.
D $9731 Never reached in any of the recorded playthroughs, which is why the code map left it as data until it was disassembled by hand.
  $9748,3 The frame counter, so the pitch follows real time rather than a count of its own.
  $9750,3 One cycle of BEEP with B complemented, which is what walks the pitch down as the loop counts up.
  $975A,8 Bit 3 of the counter picks $00 or $47 -- black or white.
  $976B,3 Flood the change outwards from the middle.
  $9771,3 Straight back into the main loop; there is no return.

@ $9774 label=SPIRAL_FILL
D $9774 Fills the attribute file from the centre outwards in a rectangular spiral: right along a row, down the far column, back along the bottom and up the near column, then in by one and round again. It reads the colour to write from the cell one row above the start, so it spreads whatever ESCAPE_SEQUENCE just put there.
  $9777,6 $5AE0 is the last row of the attribute file; the spiral is walked backwards from there.
  $97A3,3 Two rows and one column shorter each time round.

# --------------------------------------------------------------------------
# Bytes nothing reads
# --------------------------------------------------------------------------

; span $D505,251
@ $D505 label=TAIL_PADDING
b $D505 The tail of the game image
D $D505 251 bytes, of which three are not zero: a $01 seven bytes in, and $3A $85 at the very end. Nothing points here and nothing reads it -- it is the space between the last of the graphics and the end of what the tape loads.
B $D505,251,16








# --------------------------------------------------------------------------
# Two routines nothing calls
# --------------------------------------------------------------------------

; span $9BC1,17
@ $9BC1 label=NEXT_PIXEL_ROW
c $9BC1 Step a screen address down one pixel row
D $9BC1 The standard Spectrum move: bump the row within the character cell, and only when that carries out of three bits step L on by 32 and take 8 off H to get back into the right third of the screen.
D $9BC1 Nothing calls it. There is no CALL or JP to $9BC1 anywhere in the game, and it is not in any of the jump tables; the drawing routines all compute a fresh address through PIXEL_TO_SCREEN instead. It disassembles cleanly and ends in a RET, so it is a routine, just not one that runs.
  $9BC2,3 Still inside the cell -- nothing else to do.
  $9BC6,4 Down to the next character row...
  $9BCA,2 ...and if that did not wrap, the third is unchanged.

; span $9F74,12
@ $9F74 label=SETUP_BOTH_BANKS
c $9F74 Set up the drawing address in both register banks
D $9F74 Runs the same setup twice, once per bank, keeping DE across the first call so the second gets the same argument, and then joins the erase path at $9FD1.
D $9F74 Like NEXT_PIXEL_ROW, nothing reaches it: no call, no jump, no table entry. SETUP_ERASE immediately after it is the version the game actually uses.
  $9F74,4 DE is wanted twice, so it is kept over the first call.
  $9F78,5 The second bank gets the same argument.

# --------------------------------------------------------------------------
# The small tables
# --------------------------------------------------------------------------

; span $83CA,32
@ $83CA label=STEP_VECTORS
b $83CA How far to move, for each of sixteen headings
D $83CA Sixteen pairs, x then y, indexed by an actor's +$09 doubled. They run (3,0), (3,0), (3,1), (3,1), (3,1), then six of (2,2), then (1,3) three times and (0,3) twice -- a quarter turn walked round in sixteen steps, with the total distance kept roughly the same so a diagonal is not faster than a straight line.
B $83CA,32,2

; span $8C59,10
@ $8C59 label=GAME_OVER_TEXT
b $8C59 "GAME OVER"
D $8C59 A colour byte and nine characters, the last with bit 7 set. $8C41 hands it to PRINT_STRING, then the three figures are printed under it, then a two-level counted delay runs and the game jumps back to the title screen.
T $8C59,10

; span $94DD,24
@ $94DD label=KEY_ROOM_SETS
b $94DD Eight sets of three rooms, for hiding the key
D $94DD The routine above picks a set with (A + C) AND $07, multiplies by three, and copies the three bytes into $6026 stepping by eight -- which is +$01 of three consecutive object records in INITIAL_STATE, the field that says which room the object is in. So this chooses where the three pieces are hidden, and it does it by editing the template before LOAD_INITIAL_STATE copies it.
D $94DD Every one of the 24 values is a valid room number, 149 or less, which is what a table of rooms should look like and what a table of anything else almost certainly would not.
B $94DD,24,3

; span $990C,8
@ $990C label=RANDOM_ROOMS_ONE
b $990C Eight rooms to choose between
D $990C Read by the helper at $9904, which takes A AND $07 as the index. The result is written to $603E -- inside INITIAL_STATE again, so this is another thing placed differently each game.
B $990C,8,8

; span $9914,8
@ $9914 label=RANDOM_ROOMS_TWO
b $9914 Eight more
D $9914 Chosen with the frame counter added to $5E12, and written to two places at once, $6046 and $640E.
B $9914,8,8

; span $991C,8
@ $991C label=RANDOM_ROOMS_THREE
b $991C Eight more again
D $991C Chosen with the other half of the frame counter added to $5E13, and written to $604E.
B $991C,8,8

; span $A064,22
@ $A064 label=FILL_HANDLERS
b $A064 Where to go for each way of filling a run
D $A064 Eleven addresses, picked up two at a time and entered with JP (HL). Two of the eleven are $807A rather than a routine in this group, which is the same trick the actor table uses: an entry that does nothing useful points at something harmless instead of being left out.
W $A064,22,2

; span $A4A0,16
@ $A4A0 label=SWEEP_PITCHES
b $A4A0 The pitches the sweep steps through
D $A4A0 $80 and $90 alternating four times, then $80 walked down to $10 in steps of $10. So the sound wavers on one note and then climbs away from it, which is cheaper than computing a curve and is why the sweep sounds the way it does rather than gliding smoothly.
B $A4A0,16,16

# --------------------------------------------------------------------------
# The last of it
# --------------------------------------------------------------------------

; span $A3BD,10
@ $A3BD label=BEEP_ENTRIES
c $A3BD Two more ways into BEEP
D $A3BD Each loads a pitch and a length and drops into BEEP a few bytes above, the same shape as the two footstep branches. $4040 is one long note; $2080 is a shorter, higher one. Reached from $934A.
  $A3BD,5 One long note.
  $A3C2,5 Shorter and higher.

; span $9F40,10
@ $9F40 label=SETUP_ALT_ENTRIES
c $9F40 Two short entries into the drawing setup
D $9F40 Each calls one half of the setup and jumps into the middle of the routine below, so a caller that already has half of what it needs can skip the rest.

; span $92D8,8
@ $92D8 label=CLEAR_DRAW_FLAG
c $92D8 Clear bit 1 of the drawing flags
D $92D8 Reads $5E1F, ANDs out bit 1 and writes it back. Three instructions on their own, with no return -- it is fallen into rather than called.

; span $7CA1,3
@ $7CA1 label=SET_HIGHLIGHT
c $7CA1 Mark the menu line under the cursor
D $7CA1 SET 7,(HL) then INC HL. Setting bit 7 of a character is the end marker everywhere else, but here it is being used on the menu's attribute bytes to pick a line out.

; span $7CA8,3
@ $7CA8 label=CLEAR_HIGHLIGHT
c $7CA8 Unmark it again
D $7CA8 The other half of SET_HIGHLIGHT: RES 7,(HL) then INC HL.

; span $9883,8
@ $9883 label=DRIFT_OFFSETS
b $9883 Eight small steps
D $9883 $00 $20 $E0 $00 $00 $E0 $20 $00 -- read by $9876. As signed bytes they are 0, +32, -32, 0, 0, -32, +32, 0: a pair of nudges one way and then the other, which is what the mushroom's wander looks like on screen.
B $9883,8,8

; span $8B85,5
@ $8B85 label=SPAWNABLE_SPRITES
b $8B85 Five creatures
D $8B85 $62, $4C, $4E, $68, $6A -- a ghost, the pumpkin, a bat, another ghost and another bat. Five sprite codes in a row immediately before the routine that both $9340 and the mushroom handler call.
B $8B85,5,5





# --------------------------------------------------------------------------
# What the rooms are furnished with
#
# Names for the wide graphics, codes $A2 upwards. These are from pobtastic's
# Atic Atac disassembly at skoolkit.arcadegeek.co.uk, whose graphics pages
# name all of them. Its own index counts from a base of $A600, which is entry
# 162 of SPRITE_TABLE, so its id $0F is this disassembly's code $B1; the two
# tables agree address for address.
#
# Reading these as sprites rather than furniture is what made their tails look
# like unreferenced artwork -- see the note beside GFX_FIRST.
# --------------------------------------------------------------------------

; sprite $A2 Cave door frame
; sprite $A3 Door frame
; sprite $A4 Big door frame
; sprite $A9 Door, locked, red
; sprite $AA Door, locked, green
; sprite $AB Door, locked, cyan
; sprite $AC Door, locked, yellow
; sprite $AD Cave door, locked, red
; sprite $AE Cave door, locked, green
; sprite $AF Cave door, locked, cyan
; sprite $B0 Cave door, locked, yellow
; sprite $B1 Clock
; sprite $B2 Ghost picture
; sprite $B3 Table
; sprite $B6 Wall antlers
; sprite $B7 Wall trophy
; sprite $B8 Bookcase
; sprite $B9 Trapdoor, closed
; sprite $BA Trapdoor, open
; sprite $BB Barrel
; sprite $BC Rug
; sprite $BD A.C.G. shield
; sprite $BE Wall shield
; sprite $BF Suit of armour
; sprite $C1 Door, shut
; sprite $C3 Cave door, shut
; sprite $C5 A.C.G. door
; sprite $C6 Pumpkin picture
; sprite $C7 Skeleton
; sprite $C8 Barrel stack
