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

# --------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------

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
D $7C19 Runs the "ATICATAC GAME SELECTION" menu -- control method (1-3), character (4-6) and 0 to start. The current selection lives in the byte at $5E00 and is drawn inverted.
  $7C19,3 $5E00 is the base of the game-state block; the first 16 bytes are zeroed here.
  $7C23,6 Point the tile source at the text font, so the menu can be drawn with PRINT_STRING.
  $7C32,5 Select the half-row holding keys 1-5. The OUT to $FD is inert on a 48K; what matters is that A is left as the high address byte for the IN that follows.
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
  $9BE2,2 OR $58 rather than $40 -- the only real difference from PIXEL_TO_SCREEN.

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
  $A1E3,7 INC H walks down the eight scan lines of a character cell, which works because the cell never crosses a third boundary.
  $A1ED,4 Undo the eight INC Hs, then INC L to land on the next cell to the right.
E $A1D3 The tile source at $5E01 is deliberately biased by its callers. Initialised to the text font at $BE4C, where a tile code is simply an ASCII character, it is repointed during play -- while the score is on screen it holds $BFCC, which is $BE4C + 48 * 8, so that a raw digit 0-9 indexes the characters '0' to '9' directly with no adjustment at the call site.

@ $A1F3 label=PRINT_STRING
c $A1F3 Print a string of tiles in a single colour
D $A1F3 Draws consecutive tiles left to right, writing one attribute byte per cell as it goes. It keeps the display address and the attribute address live at the same time in the two register banks, swapping with EXX between the pixel write and the colour write rather than recomputing either.
R $A1F3 HL H = y (0-191), L = x -- where to start
R $A1F3 DE The string: one attribute byte, then the tile codes. Bit 7 set on a code marks it as the last one.
  $A1F4,3 Display address into the main bank...
  $A1FC,3 ...and the attribute address into the alternate one.
  $A1F7,3 The first byte is the colour, not a character; it is kept in A' for the whole run.
  $A201,2 Bit 7 is the end marker, not part of the code.
  $A20B,2 Colour the cell PLOT_TILE just drew into.
  $A210,2 Strip the end marker before drawing the final character.

# --------------------------------------------------------------------------
# Actors
# --------------------------------------------------------------------------

@ $9FFB label=ACTOR_TO_WORKSPACE
c $9FFB Copy the current actor's position and type into the workspace
D $9FFB IX points at a 16-byte actor record; the table lives at $EE90 (above the loaded game block, so it is runtime state and does not appear in this disassembly). Five records are in use during normal play. This lifts three fields out into fixed locations at $5E15-$5E17 so the drawing code can reach them without IX.
R $9FFB IX The actor record to read
  $9FFB,8 Fields +$03 and +$04 are the actor's position; they are the ones that change as things move.
  $A007,4 Field +$00 is the actor's type or sprite index.

@ $85F0 label=ACTOR_TICK_TIMER
c $85F0 Count down the actor's timer, and act when it expires
D $85F0 Field +$0F of the actor record is a countdown. Almost every call is a no-op that just decrements it; only on the tick where it reaches zero does control go to $81F0.
R $85F0 IX The actor record
