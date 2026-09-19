; A character's move against the real depth sort, in Z80, run on the C++ core
; by run_tests.py.
;
; walker_tests.s stubs the depth routines and counts their calls, which says
; what character_move asks for but not whether the list comes out right. This
; assembles walker.s and depth.s together, so each step goes through the real
; sort, the way it does in the game. Everything else walker.s reaches for --
; collision, placement, the repaint, sound -- is a stub that does nothing.
;
; The scene is a three-by-three platform of blocks with the knight standing on
; it, the same blocks and the same knight as Knight Lore's room $B4. He walks
; twelve steps across it in each of the four directions, over the joins between
; blocks, and after every step the whole list is checked for a CERTAIN
; inversion: an object before one it is certainly in front of. That is what
; went wrong in $B4 -- his legs stepped onto the next block, were certainly
; nearer than it, and stayed before it in the list -- and it is what any mistake
; of that kind would look like, whichever half and whichever way.
;
; Only certain relationships are checked. Where the axes disagree, depth_cmp
; guesses, and isometric boxes are not transitive, so the order a guess picks is
; not something a test can hold the sort to.
;
; Records: the legs at LEGS, the body a slot on, the character's tail a slot
; after that; the nine blocks from BLOCKS, a slot each, row by row along U.

					ORG		$0100
					INCLUDE	"harness.s"

					INCLUDE	"../object_struct.s"

LEGS				EQU		$C000
BODY				EQU		LEGS + ROOM_STRIDE
BLOCKS				EQU		$C100		; nine, ROOM_STRIDE apart

; What the rest of the engine gives walker.s.
COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4
OBJ_MOVABLE			EQU		$80
OBJ_FLIP_BIT		EQU		0

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

; The platform: blocks sixteen across and twelve high, as room $B4's are, so
; its top is at 140 and it runs from 112 to 160 along U and 96 to 144 along V.
BLOCK_Z				EQU		128
BLOCK_HALF			EQU		8
BLOCK_HIGH			EQU		12
TOP					EQU		BLOCK_Z + BLOCK_HIGH


; Put the knight on the platform at U, V and sort everything in, as a room is
; built: the blocks first, then his two halves, as character_add does.
					MACRO	SCENE u, v
					ld		hl,((u) << 8) | (v)
					call	scene
					ENDM

; Walk him a number of steps, checking the list after every one.
					MACRO	WALK du, dv, count
					ld		de,(((du) & $FF) << 8) | ((dv) & $FF)
					ld		b,count
					call	walk
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

					TEST	"platform: built with nothing out of order"
					SCENE	118, 107
					call	check
					NO_INVERSIONS	"inversions"

					; Along the front row, over both joins: this is the walk that
					; left his legs behind the next block in room $B4.
					TEST	"walk +U: towards, across the platform"
					SCENE	118, 107
					WALK	3, 0, 12
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	LEGS + OBJ.U, 118 + 36, "the legs' U, after"
					EXPECT_BYTE	BODY + OBJ.U, 118 + 36, "the body's U, after"

					TEST	"walk -U: away, back across it"
					SCENE	154, 107
					WALK	-3, 0, 12
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	LEGS + OBJ.U, 154 - 36, "the legs' U, after"

					; V grows away from the viewer, so +V walks away and -V towards.
					TEST	"walk +V: away, across it"
					SCENE	120, 102
					WALK	0, 3, 12
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	LEGS + OBJ.V, 102 + 36, "the legs' V, after"

					TEST	"walk -V: towards, back across it"
					SCENE	120, 138
					WALK	0, -3, 12
					NO_INVERSIONS	"inversions"
					EXPECT_BYTE	LEGS + OBJ.V, 138 - 36, "the legs' V, after"

					; And the other way round the platform, down its far column and
					; back along its far row, so every join is crossed both ways.
					TEST	"walk +V then -U: the far column and row"
					SCENE	152, 102
					WALK	0, 3, 12
					WALK	-3, 0, 11
					NO_INVERSIONS	"inversions"

					call	finish
					DB		"character_sort_tests", 0


; ---------------------------------------------------------------------------
; Fixtures.

; An empty list, the nine blocks and the knight at H = U, L = V, all sorted in
; by the real depth_insert. The checker's record of what it found is cleared.
scene:				push	hl
					ld		hl,LEGS		; the knight's two slots and his tail,
					ld		bc,3 * ROOM_STRIDE		; and the blocks' nine
					call	zero
					ld		hl,BLOCKS
					ld		bc,9 * ROOM_STRIDE
					call	zero
					ld		hl,found
					ld		bc,FOUND_SIZE
					call	zero
					ld		hl,0
					ld		(object_list),hl
					ld		hl,object_list
					ld		(sort_head),hl

					ld		ix,BLOCKS
					ld		hl,platform
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

					pop		hl		; where he stands
					ld		ix,LEGS
					ld		b,CHARACTER_BODY_UP		; the legs: from the top up to the body
					ld		c,TOP
					call	.half
					ld		ix,BODY
					ld		b,COLLIDE_HEIGHT - CHARACTER_BODY_UP
					ld		c,TOP + CHARACTER_BODY_UP
					; NB: fall through

.half:				ld		(ix+OBJ.U),h
					ld		(ix+OBJ.V),l
					ld		(ix+OBJ.Z),c
					ld		(ix+OBJ.SIZE_U),CHARACTER_HALF_U
					ld		(ix+OBJ.SIZE_V),CHARACTER_HALF_V
					ld		(ix+OBJ.SIZE_Z),b
					push	hl
					call	depth_insert
					pop		hl
					ret

; The blocks' centres, row by row along U: 120, 136 and 152 by 104, 120 and 136.
platform:			DB		120, 104,  136, 104,  152, 104
					DB		120, 120,  136, 120,  152, 120
					DB		120, 136,  136, 136,  152, 136

; B steps of D along U and E along V through character_move, with nothing in
; Z, and the list checked after each.
walk:				push	bc
					push	de
					ld		hl,step
					inc		(hl)
					ld		ix,LEGS
					ld		(ix+OBJ.DZ),0
					call	character_move
					call	check
					pop		de
					pop		bc
					djnz	walk
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
					or		a
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
; The engine and the game around walker.s, all doing nothing. What is under
; test is the order the list comes out in, and nothing here touches it.

CHARACTER_LARGEST:	DB		0
CHARACTER_TALLEST:	DB		0

collide_hit:		DB		0
collide_bound:		DB		0
room_door_z:		DS		4
room_door_at:		DS		4
room_half_u:		DB		64
room_half_v:		DB		64
room_floor_z:		DB		128

shift_arena			EQU		$9800
shift_arena_next:	DW		0
shift_kept:			DW		0

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
					INCLUDE	"../depth.s"
