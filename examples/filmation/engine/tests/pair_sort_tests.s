; Two-part figures moving against the real depth sort, in Z80, run on the C++
; core by run_tests.py: a character through character_move, and a guard through
; mover_move_pair.
;
; walker_tests.s and mover_tests.s stub the depth routines and count their
; calls, which says what a move asks for but not whether the list comes out
; right. This assembles walker.s, mover.s and depth.s together, so each step
; goes through the real sort, the way it does in the game. Everything else they
; reach for -- collision, placement, the repaint, sound -- is a stub that does
; nothing.
;
; The scene is a three-by-three platform of Knight Lore's blocks, the same as
; room $B4's, with the knight or a guard standing on it. Each walks across it
; in the four directions, over the joins between blocks, and after every step
; the whole list is checked for a CERTAIN inversion: an object before one it is
; certainly in front of. That is what went wrong in $B4 -- the knight's legs
; stepped onto the next block, were certainly nearer than it, and stayed before
; it in the list -- and it is what any mistake of that kind would look like,
; whichever half and whichever way.
;
; Only certain relationships are checked. Where the axes disagree, depth_cmp
; guesses, and isometric boxes are not transitive, so the order a guess picks is
; not something a test can hold the sort to.
;
; And room $A3's corner, where the knight stands still and something else moves:
; the moveable block, carried in under his feet by the hunting ball. That tests
; depth_relink's walk past the neighbours it can only guess about.
;
; Records: the knight's legs at LEGS, his body a slot on and his tail a slot
; after that; a guard's torso at TORSO and its legs a slot on; the nine blocks
; from BLOCKS, a slot each, row by row along U.

					ORG		$0100
					INCLUDE	"harness.s"

					INCLUDE	"../object_struct.s"

					; Before anything else: platform_empty expands depth.s's depth_reset,
					; and sjasmplus wants a macro defined before it is used.
					INCLUDE	"../depth.s"

LEGS				EQU		$C000		; the knight: legs, body, tail
BODY				EQU		LEGS + ROOM_STRIDE
TORSO				EQU		$C060		; a guard: torso, then legs
GUARD_LEGS			EQU		TORSO + ROOM_STRIDE
BLOCKS				EQU		$C100		; nine, ROOM_STRIDE apart

; What the rest of the engine gives walker.s and mover.s.
COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4
OBJ_MOVABLE			EQU		$80
OBJ_PASSABLE		EQU		$04
OBJ_FLIP_BIT		EQU		0
room_objects		EQU		BLOCKS
BEHAVIOUR_FIRST_TURN	EQU		2

LEGS_BASE			EQU		16
BODY_BASE			EQU		32

; What a game gives walker.s -- Knight Lore's numbers.
COLLIDE_HEIGHT		EQU		23
CHARACTER_BODY_UP	EQU		12
CHARACTER_HALF_U	EQU		5
CHARACTER_HALF_V	EQU		5
CHARACTER_STEP		EQU		3
CHARACTER_JUMP_DZ	EQU		8
CHARACTER_FALL_MAX	EQU		-8 & $FF
DOOR_ACROSS			EQU		6
DOOR_ALONG			EQU		15
DOOR_LEVEL			EQU		4
DOOR_HEIGHT			EQU		13

; A guard, as Knight Lore's fg_guard_ew has it: a torso six by six and 24 high,
; over legs as wide and with no height at all, at the torso's own Z.
GUARD_HALF			EQU		6
GUARD_HIGH			EQU		24
GUARD_STEP			EQU		2

; The platform: blocks sixteen across and twelve high, as room $B4's are, so
; its top is at 140 and it runs from 112 to 160 along U and 96 to 144 along V.
BLOCK_Z				EQU		128
BLOCK_HALF			EQU		8
BLOCK_HIGH			EQU		12
TOP					EQU		BLOCK_Z + BLOCK_HIGH


; The platform, and the knight or a guard on it at U, V, all sorted in as a
; room is built.
					MACRO	KNIGHT_AT u, v
					ld		hl,((u) << 8) | (v)
					call	knight_scene
					ENDM

					MACRO	GUARD_AT u, v
					ld		hl,((u) << 8) | (v)
					call	guard_scene
					ENDM

; Walk him, or it, a number of steps, checking the list after every one.
					MACRO	WALK du, dv, count
					ld		de,(((du) & $FF) << 8) | ((dv) & $FF)
					ld		b,count
					call	knight_walk
					ENDM

					MACRO	MARCH du, dv, count
					ld		de,(((du) & $FF) << 8) | ((dv) & $FF)
					ld		b,count
					call	guard_walk
					ENDM

; No certain inversion anywhere in the walk -- or, if there was, the first one:
; which step, and the two records the wrong way round.
					MACRO	NO_INVERSIONS what
					EXPECT_BYTE	inversions, 0, what
					EXPECT_BYTE	inversion_step, 0, "...first at step"
					EXPECT_WORD	inversion_nearer, 0, "...this one, before..."
					EXPECT_WORD	inversion_further, 0, "...this one, which is behind it"
					ENDM


start:				ld		sp,$FE00

; --- the knight, through character_move -----------------------------------------

					TEST	"knight: built with nothing out of order"
					KNIGHT_AT	118, 107
					call	check
					NO_INVERSIONS	"inversions"

					; Along the front row, over both joins: this is the walk that
					; left his legs behind the next block in room $B4.
					TEST	"knight +U: towards, across the platform"
					KNIGHT_AT	118, 107
					WALK	3, 0, 12
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	LEGS + OBJ.U, 118 + 36, "the legs' U, after"
					EXPECT_BYTE	BODY + OBJ.U, 118 + 36, "the body's U, after"

					TEST	"knight -U: away, back across it"
					KNIGHT_AT	154, 107
					WALK	-3, 0, 12
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	LEGS + OBJ.U, 154 - 36, "the legs' U, after"

					; V grows away from the viewer, so +V walks away and -V towards.
					TEST	"knight +V: away, across it"
					KNIGHT_AT	120, 102
					WALK	0, 3, 12
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	LEGS + OBJ.V, 102 + 36, "the legs' V, after"

					TEST	"knight -V: towards, back across it"
					KNIGHT_AT	120, 138
					WALK	0, -3, 12
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	LEGS + OBJ.V, 138 - 36, "the legs' V, after"

					; And the other way round the platform, down its far column and
					; back along its far row, so every join is crossed both ways.
					TEST	"knight +V then -U: the far column and row"
					KNIGHT_AT	152, 102
					WALK	0, 3, 12
					WALK	-3, 0, 11
					NO_INVERSIONS	"inversions"

; --- a guard, through mover_move_pair ---------------------------------------------
; Its legs are snapped onto where the torso goes and re-sorted, and then the
; torso is -- the same two halves as the knight's, the other way up in memory.

					TEST	"guard: built with nothing out of order"
					GUARD_AT	118, 107
					call	check
					NO_INVERSIONS	"inversions"

					TEST	"guard +U: towards, across the platform"
					GUARD_AT	118, 107
					MARCH	2, 0, 18
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	TORSO + OBJ.U, 118 + 36, "the torso's U, after"
					EXPECT_BYTE	GUARD_LEGS + OBJ.U, 118 + 36, "the legs' U, after"

					TEST	"guard -U: away, back across it"
					GUARD_AT	154, 107
					MARCH	-2, 0, 18
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	GUARD_LEGS + OBJ.U, 154 - 36, "the legs' U, after"

					TEST	"guard +V: away, across it"
					GUARD_AT	120, 102
					MARCH	0, 2, 18
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	GUARD_LEGS + OBJ.V, 102 + 36, "the legs' V, after"

					TEST	"guard -V: towards, back across it"
					GUARD_AT	120, 138
					MARCH	0, -2, 18
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	GUARD_LEGS + OBJ.V, 138 - 36, "the legs' V, after"

; --- something sliding under a knight who is standing still --------------------
; Room $A3: the moveable block rides the hunting ball, and the knight stands
; half on a stack beside it. The block is sorted in after him, rightly -- beside
; him it is only guessed nearer or further -- and then the ball carries it in
; under his feet, where he is certainly nearer. He takes no step, so he is
; never re-sorted, and the block's own re-sort looks only at its neighbours.

					TEST	"$A3: a block carried in under a knight standing still"
					call	a3_scene
					call	check
					NO_INVERSIONS	"inversions, before"
					ld		b,6
.a3_step:			push	bc
					ld		hl,step
					inc		(hl)
					ld		ix,A3_BLOCK
					ld		de,$0002		; +2 along V, as the ball goes
					xor		a
					call	depth_step
					call	check
					pop		bc
					djnz	.a3_step
					NO_INVERSIONS	"inversions"

					call	finish
					DB		"pair_sort_tests", 0


; ---------------------------------------------------------------------------
; Fixtures.

; The platform: every record cleared, an empty list, the checker's findings
; cleared, and the nine blocks sorted in by the real depth_insert.
platform:			call	platform_empty
					ld		ix,BLOCKS
					ld		hl,blocks
					ld		b,9
.block:				ld		a,(hl)
					ld		(ix+OBJ.U),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.V),a
					inc		hl
					ld		(ix+OBJ.Z),BLOCK_Z
					ld		(ix+OBJ.SIZE_U),BLOCK_HALF
					ld		(ix+OBJ.SIZE_V),BLOCK_HALF
					ld		(ix+OBJ.SIZE_Z),BLOCK_HIGH
					push	bc
					push	hl
					call	depth_insert		; keeps IX
					pop		hl
					pop		bc
					ld		de,ROOM_STRIDE
					add		ix,de
					djnz	.block
					ret

; Every record cleared, an empty list, and the checker's findings cleared.
platform_empty:		ld		hl,LEGS		; the knight, the guard and the blocks
					ld		bc,BLOCKS + 9 * ROOM_STRIDE - LEGS
					call	zero
					ld		hl,found
					ld		bc,FOUND_SIZE
					call	zero
					depth_reset			
					ret

; Room $A3's corner, as the game has it: two blocks stacked, a spike and a
; spiked ball on it, the moveable block beside the knight's feet, and the knight
; on the stack -- in the order the room builds them, the knight last.
A3_STACK			EQU		BLOCKS
A3_SPIKE			EQU		BLOCKS + 2 * ROOM_STRIDE
A3_BALL				EQU		BLOCKS + 3 * ROOM_STRIDE
A3_BLOCK			EQU		BLOCKS + 4 * ROOM_STRIDE

a3_scene:			call	platform_empty
					ld		ix,A3_STACK
					ld		hl,(136 << 8) | 168
					ld		d,8
					ld		bc,(12 << 8) | 128
					call	place
					ld		ix,A3_STACK + ROOM_STRIDE
					ld		bc,(12 << 8) | 140
					call	place
					ld		ix,A3_SPIKE
					ld		hl,(120 << 8) | 136
					ld		d,6
					ld		bc,(12 << 8) | 128
					call	place
					ld		ix,A3_BALL
					ld		bc,(12 << 8) | 140
					call	place
					ld		ix,A3_BLOCK		; beside him along V: 148 to 164
					ld		hl,(152 << 8) | 156
					ld		d,8
					ld		bc,(12 << 8) | 140
					call	place
					ld		hl,(144 << 8) | 169		; on the stack, at its top
					ld		d,CHARACTER_HALF_U
					ld		ix,LEGS
					ld		bc,(CHARACTER_BODY_UP << 8) | 152
					call	place
					ld		ix,BODY
					ld		bc,((COLLIDE_HEIGHT - CHARACTER_BODY_UP) << 8) | (152 + CHARACTER_BODY_UP)
					jr		place

; The blocks' centres, row by row along U: 120, 136 and 152 by 104, 120 and 136.
blocks:				DB		120, 104,  136, 104,  152, 104
					DB		120, 120,  136, 120,  152, 120
					DB		120, 136,  136, 136,  152, 136

; One record at H = U, L = V: Z in C, the half-width in D and the height in B,
; sorted in. HL, DE and IX come back; BC does not, so each record sets its own.
place:				ld		(ix+OBJ.U),h
					ld		(ix+OBJ.V),l
					ld		(ix+OBJ.Z),c
					ld		(ix+OBJ.SIZE_U),d
					ld		(ix+OBJ.SIZE_V),d
					ld		(ix+OBJ.SIZE_Z),b
					push	hl
					push	de
					call	depth_insert
					pop		de
					pop		hl
					ret

; The platform with the knight on it at H = U, L = V: his legs and then his
; body, as character_add puts them in.
knight_scene:		push	hl
					call	platform
					pop		hl
					ld		d,CHARACTER_HALF_U
					ld		ix,LEGS
					ld		b,CHARACTER_BODY_UP		; the legs: from the top up to the body
					ld		c,TOP
					call	place
					ld		ix,BODY
					ld		b,COLLIDE_HEIGHT - CHARACTER_BODY_UP
					ld		c,TOP + CHARACTER_BODY_UP
					jr		place

; The platform with a guard on it at H = U, L = V: its torso and then its legs,
; in the order fg_guard_ew lists them and the room inserts them.
guard_scene:		push	hl
					call	platform
					pop		hl
					ld		d,GUARD_HALF
					ld		ix,TORSO
					ld		b,GUARD_HIGH
					ld		c,TOP
					call	place
					ld		ix,GUARD_LEGS
					ld		b,0
					ld		c,TOP		; again: depth_insert took BC
					jr		place

; B steps of D along U and E along V through character_move, with nothing in
; Z, and the list checked after each.
knight_walk:		push	bc
					push	de
					ld		hl,step
					inc		(hl)
					ld		ix,LEGS
					ld		(ix+OBJ.DZ),0
					call	character_move
					call	check
					pop		de
					pop		bc
					djnz	knight_walk
					ret

; The same through mover_move_pair, as movers_step would call it for a guard:
; the step in the torso's DU and DV, and a DZ of one, which mover_clamp's
; gravity takes back to nothing -- the stubbed clamp stops nothing, so without
; that it would sink through the platform.
guard_walk:			push	bc
					push	de
					ld		hl,step
					inc		(hl)
					ld		ix,TORSO
					ld		(mover_ix),ix
					ld		(ix+OBJ.DU),d
					ld		(ix+OBJ.DV),e
					ld		(ix+OBJ.DZ),1
					call	mover_move_pair
					call	check
					pop		de
					pop		bc
					djnz	guard_walk
					ret

; Every sorted object against every one after it. One that is CERTAINLY nearer
; than something it comes before is an inversion: counted, and the first kept
; with the step it turned up on.
check:				ld		hl,(sort_head)
					ld		a,(hl)
					inc		hl
					ld		h,(hl)
					ld		l,a		; the first sorted object
.outer:				ld		a,h
					or		l
					ret		z
					push	hl
					pop		ix		; this one...
					call	depth_cmp_setup
					ld		l,(ix+OBJ.NEXT)
					ld		h,(ix+OBJ.NEXT+1)
.inner:				ld		a,h
					or		l
					jr		z,.next
					call	depth_cmp_hl		; ...against each after it, in IY
					jr		c,.fine		; further than it: as it should be
					jr		nz,.fine		; nearer, but only a guess
					ld		hl,inversions
					inc		(hl)
					ld		a,(hl)
					dec		a
					jr		nz,.fine		; not the first
					ld		a,(step)
					ld		(inversion_step),a
					ld		(inversion_nearer),ix
					ld		(inversion_further),iy
.fine:				ld		l,(iy+OBJ.NEXT)
					ld		h,(iy+OBJ.NEXT+1)
					jr		.inner
.next:				ld		l,(ix+OBJ.NEXT)
					ld		h,(ix+OBJ.NEXT+1)
					jr		.outer

zero:				ld		(hl),0
					inc		hl
					dec		bc
					ld		a,b
					or		c
					jr		nz,zero
					ret

found:
inversions:			DB		0
inversion_step:		DB		0
inversion_nearer:	DW		0
inversion_further:	DW		0
step:				DB		0		; steps taken since the scene was set
FOUND_SIZE			EQU		$ - found


; ---------------------------------------------------------------------------
; The engine and the game around walker.s and mover.s, all doing nothing. What
; is under test is the order the list comes out in, and nothing here touches it.
; object_collide_room is walker.s's own, the room's edges and floor, which the
; platform is well inside; the objects-in-the-room half after it is a stub.

CHARACTER_LARGEST:	DB		0
CHARACTER_TALLEST:	DB		0

collide_hit:		DB		0
collide_bound:		DB		0
collide_other:		DW		0
room_door_z:		DS		4
room_door_at:		DS		4
room_half_u:		DB		64
room_half_v:		DB		64
room_floor_z:		DB		128
room_object_count:	DB		0

shift_arena			EQU		$9800
shift_arena_next:	DW		0
shift_kept:			DW		0

; No behaviours: movers_step is never run here, but mover.s names the table.
mover_tbl:
walker_player		EQU		LEGS

object_collide:
shift_alloc:
room_adjust:
object_place:
region_reset:
region_add:
redraw_defer:
redraw_view:
walker_glance:
character_steer:
sound_jump:
sound_z:			ret


					INCLUDE	"../walker.s"
					INCLUDE	"../mover.s"
