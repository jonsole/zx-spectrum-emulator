; Unit tests for character.s, in Z80, run on the C++ core by run_tests.py.
;
; character.s is assembled on its own, and so is everything in it: the frames,
; walking, jumping and falling, the doorways, and the room-edge and floor half
; of the clamp that the movers share. What it calls out to is stubbed below.
; object_collide reports whatever the test says gave, and can cut the step or
; add to it the way a ride does; the depth sorts apply the step; placement,
; the redraw and shift_alloc count their calls and note what they were handed.
;
; The stubs keep the real routines' contracts: object_place, depth_insert and
; region_add keep IX, and redraw_view and redraw_defer, which end a routine,
; do not.
;
; Every test starts from the same knight: legs at U 128, V 128 on a floor at
; 128 with the body twelve above, facing 0 at phase 0, in no doorway, in a
; square room with no arches. Tests change only what they are about.

					ORG		$0100
					INCLUDE	"harness.s"

ROOM_STRIDE			EQU		32
					INCLUDE	"../engine/object_struct.s"

REC					EQU		$C000		; the legs; the body follows, then the tail

; What the engine gives character.s.
COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4
OBJ_MOVABLE			EQU		$80
OBJ_FLIP_BIT		EQU		0

LEGS_BASE			EQU		16
BODY_BASE			EQU		32


; Run a routine with IX -> the legs, and keep what came back.
					MACRO	RUN routine
					ld		ix,REC
					call	routine
					ld		(s_ix),ix
					call	snap
					ENDM

; A field of the legs, of the body, and of the character's tail (whose
; offsets already count from the legs).
					MACRO	EXPECT_LEGS field, value, what
					EXPECT_BYTE	REC + field, value, what
					ENDM

					MACRO	EXPECT_BODY field, value, what
					EXPECT_BYTE	REC + CHARACTER_BODY + field, value, what
					ENDM

					MACRO	EXPECT_TAIL field, value, what
					EXPECT_BYTE	REC + field, value, what
					ENDM

; Set a field of the legs, of the body, or of the tail.
					MACRO	SET field, value
					ld		a,(value) & $FF
					ld		(REC + field),a
					ENDM

					MACRO	SET_BODY field, value
					ld		a,(value) & $FF
					ld		(REC + CHARACTER_BODY + field),a
					ENDM

; A step in D (U) and E (V).
					MACRO	STEP du, dv
					ld		de,(((du) & $FF) << 8) | ((dv) & $FF)
					ENDM


start:				ld		sp,$FE00

; --- character_frame and obj_pair_flip -----------------------------------------

					TEST	"frame: facing away, not mirrored"
					call	fresh
					SET		CHARACTER_PHASE, 2
					SET		OBJ.FLAGS, OBJ_MOVABLE | 1 | $20
					SET_BODY	OBJ.FLAGS, OBJ_MOVABLE | 1
					RUN		character_frame
					EXPECT_LEGS	OBJ.GFX, LEGS_BASE + 2, "the legs"
					EXPECT_BODY	OBJ.GFX, BODY_BASE + 2, "the body"
					EXPECT_LEGS	OBJ.FLAGS, OBJ_MOVABLE | $20, "the legs' flags"
					EXPECT_BODY	OBJ.FLAGS, OBJ_MOVABLE, "the body's flags"

					TEST	"frame: facing towards, mirrored, B kept"
					call	fresh
					ld		b,$5A
					SET		CHARACTER_FACING, 3
					SET		CHARACTER_PHASE, 4
					RUN		character_frame
					EXPECT_LEGS	OBJ.GFX, LEGS_BASE + 8 + 4, "the legs"
					EXPECT_BODY	OBJ.GFX, BODY_BASE + 8 + 4, "the body"
					EXPECT_LEGS	OBJ.FLAGS, OBJ_MOVABLE | 1, "the legs' flags"
					EXPECT_BODY	OBJ.FLAGS, OBJ_MOVABLE | 1, "the body's flags"
					EXPECT_BYTE	s_bc + 1, $5A, "B"

					TEST	"pair flip: both records, nothing else"
					call	fresh
					SET		OBJ.FLAGS, $7E
					SET_BODY	OBJ.FLAGS, $FE
					ld		ix,REC
					scf
					call	obj_pair_flip
					EXPECT_LEGS	OBJ.FLAGS, $7F, "the first record"
					EXPECT_BODY	OBJ.FLAGS, $FF, "the second"
					ld		ix,REC
					and		a
					call	obj_pair_flip
					EXPECT_LEGS	OBJ.FLAGS, $7E, "the first, back"
					EXPECT_BODY	OBJ.FLAGS, $FE, "the second, back"

; --- character_add -------------------------------------------------------------

					TEST	"add: both halves placed, and everything reset"
					call	fresh
					SET		CHARACTER_FACING, 2
					SET		CHARACTER_PHASE, 4
					SET		CHARACTER_DZ, 5
					SET		CHARACTER_STATE, 1
					SET		CHARACTER_DOOR, 2
					SET		OBJ.FLAGS, $FF
					SET_BODY	OBJ.FLAGS, $FF
					SET		OBJ.BUF_H, $77
					ld		ix,REC
					ld		bc,100 << 8 | 110
					ld		a,136
					call	character_add
					ld		(s_ix),ix
					EXPECT_LEGS	OBJ.U, 100, "the legs' U"
					EXPECT_LEGS	OBJ.V, 110, "the legs' V"
					EXPECT_LEGS	OBJ.Z, 136, "the legs' Z"
					EXPECT_BODY	OBJ.U, 100, "the body's U"
					EXPECT_BODY	OBJ.V, 110, "the body's V"
					EXPECT_BODY	OBJ.Z, 136 + CHARACTER_BODY_UP, "the body's Z"
					EXPECT_TAIL	CHARACTER_DZ, 0, "DZ"
					EXPECT_TAIL	CHARACTER_STATE, 0, "the state"
					EXPECT_TAIL	CHARACTER_DOOR, $FF, "the doorway"
					EXPECT_TAIL	CHARACTER_PHASE, 0, "the phase"
					EXPECT_LEGS	OBJ.FLAGS, OBJ_MOVABLE, "the legs' flags"
					EXPECT_BODY	OBJ.FLAGS, OBJ_MOVABLE, "the body's flags"
					EXPECT_LEGS	OBJ.GFX, LEGS_BASE + 8, "the legs' graphic"
					EXPECT_BODY	OBJ.GFX, BODY_BASE + 8, "the body's graphic"
					EXPECT_BYTE	alloc_calls, 0, "no buffer asked for: character_keep has them"
					EXPECT_BYTE	insert_calls, 2, "both sorted in"
					EXPECT_WORD	insert_ix_1, REC, "the legs first"
					EXPECT_WORD	insert_ix_2, REC + CHARACTER_BODY, "then the body"
					EXPECT_BYTE	add_calls, 2, "region_add"
					EXPECT_BYTE	view_calls, 1, "redraw_view"

					TEST	"keep: both buffers, once, from an empty arena, kept back"
					call	fresh
					ld		hl,$9000		; where a last game's last room left it
					ld		(shift_arena_next),hl
					RUN		character_keep
					EXPECT_BYTE	alloc_calls, 2, "buffers asked for"
					EXPECT_WORD	alloc_hl_1, CHARACTER_LARGEST, "the legs', sized"
					EXPECT_WORD	alloc_hl_2, CHARACTER_TALLEST, "the walking body's, sized"
					EXPECT_WORD	alloc_next_1, shift_arena, "asked for from the start"
					EXPECT_WORD	shift_kept, shift_arena, "what the arena keeps back"
					EXPECT_WORD	s_ix, REC, "IX"

; --- character_walk, character_stand, character_move -------------------------

					TEST	"walk: a step along +V, a frame on"
					call	fresh
					SET		CHARACTER_PHASE, 2
					ld		a,1
					RUN		character_walk
					EXPECT_BYTE	coll_du, 0, "the clamp's DU"
					EXPECT_BYTE	coll_dv, CHARACTER_STEP, "the clamp's DV"
					EXPECT_LEGS	OBJ.V, 128 + CHARACTER_STEP, "the legs' V"
					EXPECT_BODY	OBJ.V, 128 + CHARACTER_STEP, "the body's V"
					EXPECT_TAIL	CHARACTER_FACING, 1, "the facing"
					EXPECT_TAIL	CHARACTER_PHASE, 3, "the phase"
					EXPECT_LEGS	OBJ.GFX, LEGS_BASE + 3, "the legs' graphic"
					EXPECT_LEGS	OBJ.FLAGS, OBJ_MOVABLE | 1, "mirrored"
					EXPECT_BYTE	defer_calls, 1, "redraw_defer"

					TEST	"walk: the cycle wraps after five"
					call	fresh
					SET		CHARACTER_PHASE, 5
					ld		a,2
					RUN		character_walk
					EXPECT_TAIL	CHARACTER_PHASE, 0, "the phase"
					EXPECT_BYTE	coll_du, CHARACTER_STEP, "the clamp's DU"
					EXPECT_LEGS	OBJ.U, 128 + CHARACTER_STEP, "the legs' U"

					TEST	"walk: into a wall, still turns and draws"
					call	fresh
					ld		a,1
					ld		(stub_block),a
					ld		a,3
					RUN		character_walk
					EXPECT_LEGS	OBJ.V, 128, "the legs' V"
					EXPECT_TAIL	CHARACTER_FACING, 3, "the facing"
					EXPECT_TAIL	CHARACTER_PHASE, 1, "the phase"
					EXPECT_BYTE	defer_calls, 1, "redraw_defer"

					TEST	"stand: falls, is clamped, and draws"
					call	fresh
					RUN		character_stand
					EXPECT_BYTE	coll_calls, 1, "clamps"
					EXPECT_BYTE	coll_du, 0, "the clamp's DU"
					EXPECT_BYTE	coll_dz, 0, "the clamp's DZ: the floor took it"
					EXPECT_BYTE	defer_calls, 1, "redraw_defer"

					TEST	"move: both halves by the step, legs sorted first"
					call	fresh
					SET		OBJ.DZ, -2
					STEP	1, 2
					RUN		character_move
					EXPECT_BODY	OBJ.DZ, -2 & $FF, "the body's DZ, copied"
					EXPECT_BYTE	step_calls, 1, "the legs sorted"
					EXPECT_WORD	step_de, $0102, "...by the step"
					EXPECT_BYTE	step_a, -2 & $FF, "...and DZ"
					EXPECT_BYTE	upper_calls, 1, "the body sorted"
					EXPECT_WORD	upper_hl, REC, "...after the legs"
					EXPECT_WORD	upper_de, $0102, "...by the step"
					EXPECT_LEGS	OBJ.U, 129, "the legs' U"
					EXPECT_LEGS	OBJ.Z, 126, "the legs' Z"
					EXPECT_BODY	OBJ.V, 130, "the body's V"
					EXPECT_BODY	OBJ.Z, 138, "the body's Z"
					EXPECT_BYTE	place_calls, 2, "both placed"
					EXPECT_BYTE	add_calls, 4, "region_add, both halves twice"
					EXPECT_BYTE	defer_calls, 1, "one redraw"

; --- character_settle, character_gravity, character_land, character_jump -----

					TEST	"settle: a shove adds to the step, and is spent"
					call	fresh
					SET		OBJ.DU, 1
					SET		OBJ.DV, -1
					STEP	3, 0
					RUN		character_settle
					EXPECT_BYTE	coll_du, 4, "the clamp's DU"
					EXPECT_BYTE	coll_dv, -1 & $FF, "the clamp's DV"
					EXPECT_LEGS	OBJ.DU, 0, "DU after"
					EXPECT_LEGS	OBJ.DV, 0, "DV after"

					TEST	"gravity: rising, key held, loses one"
					call	fresh
					ld		a,1
					ld		(character_jump_held),a
					SET		CHARACTER_DZ, 8
					RUN		character_gravity
					EXPECT_TAIL	CHARACTER_DZ, 7, "the velocity"
					EXPECT_LEGS	OBJ.DZ, 7, "the step asked for"

					TEST	"gravity: rising, key let go, loses two"
					call	fresh
					SET		CHARACTER_DZ, 8
					RUN		character_gravity
					EXPECT_TAIL	CHARACTER_DZ, 6, "the velocity"

					TEST	"gravity: falling, whatever the key"
					call	fresh
					ld		a,1
					ld		(character_jump_held),a
					SET		CHARACTER_DZ, -3
					RUN		character_gravity
					EXPECT_TAIL	CHARACTER_DZ, -5 & $FF, "the velocity"

					TEST	"gravity: no faster than terminal"
					call	fresh
					SET		CHARACTER_DZ, -7
					RUN		character_gravity
					EXPECT_TAIL	CHARACTER_DZ, CHARACTER_FALL_MAX, "the velocity"
					EXPECT_LEGS	OBJ.DZ, CHARACTER_FALL_MAX, "the step asked for"

					TEST	"land: nothing stopped it in Z"
					call	fresh
					SET		CHARACTER_DZ, -3
					SET		CHARACTER_STATE, 1
					ld		a,COLLIDE_U
					ld		(collide_hit),a
					RUN		character_land
					EXPECT_TAIL	CHARACTER_DZ, -3 & $FF, "the velocity"
					EXPECT_TAIL	CHARACTER_STATE, 1, "the state"

					TEST	"land: coming down, the jump is over"
					call	fresh
					SET		CHARACTER_DZ, -3
					SET		CHARACTER_STATE, 1
					ld		a,COLLIDE_Z
					ld		(collide_hit),a
					RUN		character_land
					EXPECT_TAIL	CHARACTER_DZ, 0, "the velocity"
					EXPECT_TAIL	CHARACTER_STATE, 0, "the state"

					TEST	"land: going up, a bumped head"
					call	fresh
					SET		CHARACTER_DZ, 5
					SET		CHARACTER_STATE, 1
					ld		a,COLLIDE_Z
					ld		(collide_hit),a
					RUN		character_land
					EXPECT_TAIL	CHARACTER_DZ, 0, "the velocity"
					EXPECT_TAIL	CHARACTER_STATE, 1, "the state, still jumping"

					TEST	"jump: from standing"
					call	fresh
					RUN		character_jump
					EXPECT_TAIL	CHARACTER_STATE, 1, "the state"
					EXPECT_TAIL	CHARACTER_DZ, CHARACTER_JUMP_DZ, "the velocity"

					TEST	"jump: not twice"
					call	fresh
					SET		CHARACTER_STATE, 1
					SET		CHARACTER_DZ, 3
					RUN		character_jump
					EXPECT_TAIL	CHARACTER_DZ, 3, "the velocity"

					TEST	"jump: not in a doorway, and A kept"
					call	fresh
					SET		CHARACTER_DOOR, 0
					ld		a,1
					RUN		character_jump
					EXPECT_TAIL	CHARACTER_STATE, 0, "the state"
					EXPECT_A	1, "A"

					TEST	"jump: too late, falling"
					call	fresh
					SET		CHARACTER_DZ, -2
					RUN		character_jump
					EXPECT_TAIL	CHARACTER_STATE, 0, "the state"
					call	fresh
					SET		CHARACTER_DZ, -1
					RUN		character_jump
					EXPECT_TAIL	CHARACTER_STATE, 1, "the state, at one a turn"

; --- character_door_find -------------------------------------------------------

					TEST	"door: in the north arch"
					call	fresh
					call	north_arch
					SET		OBJ.U, 130
					SET		OBJ.V, 190
					RUN		character_door_find
					EXPECT_TAIL	CHARACTER_DOOR, 0, "the doorway"

					TEST	"door: beside the opening"
					call	fresh
					call	north_arch
					SET		OBJ.U, 128 + DOOR_ACROSS
					SET		OBJ.V, 190
					RUN		character_door_find
					EXPECT_TAIL	CHARACTER_DOOR, $FF, "the doorway"

					TEST	"door: short of the wall"
					call	fresh
					call	north_arch
					SET		OBJ.V, 196 - DOOR_ALONG
					RUN		character_door_find
					EXPECT_TAIL	CHARACTER_DOOR, $FF, "the doorway"

					TEST	"door: its height, from three below to twelve above"
					call	fresh
					call	north_arch
					SET		OBJ.V, 190
					SET		OBJ.Z, 128 + DOOR_HEIGHT - 1
					RUN		character_door_find
					EXPECT_TAIL	CHARACTER_DOOR, 0, "twelve above"
					SET		OBJ.Z, 128 + DOOR_HEIGHT
					RUN		character_door_find
					EXPECT_TAIL	CHARACTER_DOOR, $FF, "thirteen above"
					SET		OBJ.Z, 128 - DOOR_LEVEL + 1
					RUN		character_door_find
					EXPECT_TAIL	CHARACTER_DOOR, 0, "three below"
					SET		OBJ.Z, 128 - DOOR_LEVEL
					RUN		character_door_find
					EXPECT_TAIL	CHARACTER_DOOR, $FF, "four below"

					TEST	"door: the east arch, across the other axis"
					call	fresh
					ld		a,128
					ld		(room_door_z + 1),a
					ld		a,196
					ld		(room_door_at + 1),a
					SET		OBJ.U, 190
					SET		OBJ.V, 126
					RUN		character_door_find
					EXPECT_TAIL	CHARACTER_DOOR, 1, "the doorway"

; --- character_steer -----------------------------------------------------------

					TEST	"steer: no arch, no nudge"
					call	fresh
					STEP	-3, 0
					RUN		character_steer
					EXPECT_WORD	s_de, $FD00, "the step"

					; A north arch nudges him along U towards the middle of its
					; opening, whichever way he walks -- the game chooses by the
					; arch's own mirroring. Along the wall that only lengthens or
					; shortens his step; it never takes him across into the arch.
					TEST	"steer: along the north wall, never across it"
					call	fresh
					call	north_arch
					SET		OBJ.U, 130
					SET		OBJ.V, 185
					STEP	-3, 0
					RUN		character_steer
					EXPECT_WORD	s_de, $FC00, "the step"

					TEST	"steer: along the north wall, past the middle"
					call	fresh
					call	north_arch
					SET		OBJ.U, 130
					SET		OBJ.V, 185
					STEP	3, 0
					RUN		character_steer
					EXPECT_WORD	s_de, $0200, "the step"

					TEST	"steer: into the north arch, towards its U"
					call	fresh
					call	north_arch
					SET		CHARACTER_FACING, 1
					SET		OBJ.U, 130
					SET		OBJ.V, 185
					STEP	0, 3
					RUN		character_steer
					EXPECT_WORD	s_de, $FF03, "the step"

					TEST	"steer: along the east wall, along V and not across"
					call	fresh
					ld		a,128
					ld		(room_door_z + 1),a
					ld		a,196
					ld		(room_door_at + 1),a
					SET		CHARACTER_FACING, 1
					SET		OBJ.U, 185
					SET		OBJ.V, 120
					STEP	0, 3
					RUN		character_steer
					EXPECT_WORD	s_de, $0004, "the step"

					TEST	"steer: already in the middle of the opening"
					call	fresh
					call	north_arch
					SET		OBJ.U, 128
					SET		OBJ.V, 185
					STEP	-3, 0
					RUN		character_steer
					EXPECT_WORD	s_de, $FD00, "the step"

					TEST	"steer: not on the arch's storey"
					call	fresh
					call	north_arch
					SET		OBJ.U, 130
					SET		OBJ.V, 185
					SET		OBJ.Z, 128 + DOOR_LEVEL
					STEP	-3, 0
					RUN		character_steer
					EXPECT_WORD	s_de, $FD00, "the step"

; --- the room's edges and floor ------------------------------------------------

					TEST	"bound: a step into the far wall cut to fit"
					call	fresh
					SET		OBJ.U, 185		; 186 is the last U inside
					STEP	3, 0
					RUN		object_bound_uv
					EXPECT_WORD	s_de, $0100, "the step"
					EXPECT_BYTE	collide_bound, COLLIDE_U, "collide_bound"

					TEST	"bound: and the near wall, along V"
					call	fresh
					SET		OBJ.V, 71		; 70 is the first V inside
					STEP	0, -3
					RUN		object_bound_uv
					EXPECT_WORD	s_de, $00FF, "the step"
					EXPECT_BYTE	collide_bound, COLLIDE_V, "collide_bound"

					TEST	"bound: a room narrow along V has its own V edge"
					call	fresh
					ld		a,32
					ld		(room_half_v),a		; 154 is the last V inside
					SET		OBJ.V, 153
					STEP	3, 3
					RUN		object_bound_uv
					EXPECT_WORD	s_de, $0301, "the step"
					EXPECT_BYTE	collide_bound, COLLIDE_V, "collide_bound"

					TEST	"bound: inside, untouched"
					call	fresh
					STEP	3, -3
					RUN		object_bound_uv
					EXPECT_WORD	s_de, $03FD, "the step"
					EXPECT_BYTE	collide_bound, 0, "collide_bound"

					TEST	"collide: in a doorway, the edges do not apply"
					call	fresh
					SET		CHARACTER_DOOR, 0
					SET		OBJ.V, 190
					STEP	0, 3
					RUN		character_collide
					EXPECT_BYTE	coll_dv, 3, "the clamp's DV"
					EXPECT_WORD	s_de, $0003, "the step back"

					TEST	"collide: out of one, they do"
					call	fresh
					SET		OBJ.V, 185
					STEP	0, 3
					RUN		character_collide
					EXPECT_BYTE	coll_dv, 1, "the clamp's DV"
					EXPECT_WORD	s_de, $0001, "the step back"
					EXPECT_BYTE	collide_hit, COLLIDE_V, "collide_hit"

					TEST	"collide: a ride through the wall is cut again"
					call	fresh
					SET		OBJ.U, 184
					ld		a,4
					ld		(stub_carry),a		; the clamp hands it four along U
					STEP	0, 0
					RUN		object_collide_room
					EXPECT_WORD	s_de, $0200, "the step back"
					EXPECT_LEGS	OBJ.DU, 2, "DU"

					TEST	"floor: a fall stops on it"
					call	fresh
					SET		OBJ.Z, 130
					SET		OBJ.DZ, -8
					ld		a,COLLIDE_U
					ld		(stub_hit),a
					STEP	0, 0
					RUN		object_collide_free
					EXPECT_BYTE	coll_dz, -2 & $FF, "the clamp's DZ"
					EXPECT_BYTE	collide_hit, COLLIDE_U | COLLIDE_Z, "collide_hit"

					TEST	"floor: above it, nothing to stop"
					call	fresh
					SET		OBJ.Z, 140
					SET		OBJ.DZ, -8
					ld		a,COLLIDE_V
					ld		(collide_bound),a		; an edge found before
					STEP	1, -1
					RUN		object_collide_free
					EXPECT_BYTE	coll_dz, -8 & $FF, "the clamp's DZ"
					EXPECT_BYTE	coll_du, 1, "the clamp's DU"
					EXPECT_BYTE	coll_dv, -1 & $FF, "the clamp's DV"
					EXPECT_BYTE	collide_hit, COLLIDE_V, "collide_hit, with the edge in it"

					call	finish
					DB		"character_tests", 0


; ---------------------------------------------------------------------------
; Fixtures.

; The knight described at the top, a bare square room, and the stubs zeroed.
fresh:				ld		hl,REC
					ld		bc,2 * ROOM_STRIDE + 16
					call	zero
					ld		hl,stubs
					ld		bc,STUBS_SIZE
					call	zero
					ld		ix,REC
					call	.half
					ld		ix,REC + CHARACTER_BODY
					call	.half
					ld		(ix+OBJ.Z),128 + CHARACTER_BODY_UP
					ld		ix,REC
					ld		(ix+CHARACTER_LEGS),LEGS_BASE
					ld		(ix+CHARACTER_BODY_G),BODY_BASE
					ld		(ix+CHARACTER_DOOR),$FF
					ld		a,64
					ld		(room_half_u),a
					ld		(room_half_v),a
					ld		a,128
					ld		(room_floor_z),a
					xor		a
					ld		(character_jump_held),a		; character.s's own, not a stub
					ret
.half:				ld		(ix+OBJ.FLAGS),OBJ_MOVABLE
					ld		(ix+OBJ.U),128
					ld		(ix+OBJ.V),128
					ld		(ix+OBJ.Z),128
					ld		(ix+OBJ.SIZE_U),CHARACTER_HALF_U
					ld		(ix+OBJ.SIZE_V),CHARACTER_HALF_V
					ld		(ix+OBJ.SIZE_Z),12
					ret

;   HL -> BC bytes to clear
zero:				ld		(hl),0
					inc		hl
					dec		bc
					ld		a,b
					or		c
					jr		nz,zero
					ret

; An arch on the floor in the north wall, standing at V 196 as the game's do.
north_arch:			ld		a,128
					ld		(room_door_z),a
					ld		a,196
					ld		(room_door_at),a
					ret


; ---------------------------------------------------------------------------
; The engine around character.s.

sprite_030:			DB		0		; CHARACTER_LARGEST and CHARACTER_TALLEST
sprite_092:			DB		0		; name these; only their addresses matter

stubs:
collide_hit:		DB		0
collide_bound:		DB		0
room_door_z:		DS		4
room_door_at:		DS		4
room_half_u:		DB		0
room_half_v:		DB		0
room_floor_z:		DB		0

stub_hit:			DB		0		; what object_collide says gave
stub_block:			DB		0		; non-zero: it takes the step along the floor
stub_carry:			DB		0		; added to DU, as a ride would

coll_calls:			DB		0
coll_du:			DB		0		; the step object_collide was handed
coll_dv:			DB		0
coll_dz:			DB		0
step_calls:			DB		0
step_de:			DW		0
step_a:				DB		0
upper_calls:		DB		0
upper_hl:			DW		0
upper_de:			DW		0
insert_calls:		DB		0
insert_ix_1:		DW		0
insert_ix_2:		DW		0
alloc_calls:		DB		0
alloc_hl_1:			DW		0
alloc_hl_2:			DW		0
alloc_next_1:		DW		0		; the arena, as the first ask found it
place_calls:		DB		0
add_calls:			DB		0
defer_calls:		DB		0
view_calls:			DB		0
s_ix:				DW		0
STUBS_SIZE			EQU		$ - stubs

object_collide:		ld		hl,coll_calls
					inc		(hl)
					ld		a,(ix+OBJ.DU)
					ld		(coll_du),a
					ld		a,(ix+OBJ.DV)
					ld		(coll_dv),a
					ld		a,(ix+OBJ.DZ)
					ld		(coll_dz),a
					ld		a,(stub_hit)
					ld		(collide_hit),a
					ld		a,(stub_carry)
					add		a,(ix+OBJ.DU)
					ld		(ix+OBJ.DU),a
					ld		a,(stub_block)
					or		a
					ret		z
					xor		a
					ld		(ix+OBJ.DU),a
					ld		(ix+OBJ.DV),a
					ret

; As depth_add_step: the step onto U, V and Z.
add_step:			ld		b,a
					ld		a,(ix+OBJ.U)
					add		a,d
					ld		(ix+OBJ.U),a
					ld		a,(ix+OBJ.V)
					add		a,e
					ld		(ix+OBJ.V),a
					ld		a,(ix+OBJ.Z)
					add		a,b
					ld		(ix+OBJ.Z),a
					ret

depth_step:			ld		(step_de),de
					ld		(step_a),a
					ld		hl,step_calls
					inc		(hl)
					jr		add_step

depth_step_upper:	ld		(upper_hl),hl
					ld		(upper_de),de
					ld		hl,upper_calls
					inc		(hl)
					jr		add_step

depth_insert:		ld		hl,insert_calls
					inc		(hl)
					ld		hl,insert_ix_1
					ld		a,(insert_calls)
					cp		1
					jr		z,.store
					ld		hl,insert_ix_2
.store:				push	ix
					pop		de
					ld		(hl),e
					inc		hl
					ld		(hl),d
					ret

shift_arena			EQU		$9800
shift_arena_next:	DW		0
shift_kept:			DW		0

shift_alloc:		ld		a,(alloc_calls)
					inc		a
					ld		(alloc_calls),a
					cp		1
					jr		nz,.second
					ld		(alloc_hl_1),hl
					ld		de,(shift_arena_next)
					ld		(alloc_next_1),de
					ret
.second:			ld		(alloc_hl_2),hl
					ret

room_adjust:		ret

object_place:		ld		hl,place_calls
					inc		(hl)
					ret

region_reset:		ret

region_add:			ld		hl,add_calls
					inc		(hl)
					ret

; These two end their callers, and are free to leave IX anywhere.
redraw_defer:		ld		hl,defer_calls
					inc		(hl)
					ld		ix,$BEEF
					ret

redraw_view:		ld		hl,view_calls
					inc		(hl)
					ld		ix,$BEEF
					ret

; The knight's glance is filmation.s's; here every body frame is the plain one.
player_glance_body:	ret

; Silent: what the sounds play is not what these tests are about.
sound_jump:
sound_z:			ret


					INCLUDE	"../engine/walker.s"
