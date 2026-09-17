; Unit tests for knightlore/knight.s, in Z80, run on the C++ core by
; engine/tests/run_tests.py.
;
; character_steer is the knight's nudge towards the middle of an arch as he
; walks past it. It is assembled on its own: the room's doorway table is here,
; and character_door_find.abs, the one thing it borrows from the engine's
; walker, is a copy.
;
; Every test starts from the knight at U 128, V 128 on a floor at 128, in a
; room with no arches, and changes only what it is about.

					ORG		$0100
					INCLUDE	"../../engine/tests/harness.s"

					INCLUDE	"../../engine/object_struct.s"

REC					EQU		$C000		; the legs; the body follows, then the tail

; The walker's own offset into the tail, as engine/walker.s has it.
CHARACTER_FACING	EQU		ROOM_STRIDE * 2 + 2


; Run a routine with IX -> the legs, and keep what came back.
					MACRO	RUN routine
					ld		ix,REC
					call	routine
					call	snap
					ENDM

; Set a field of the legs, or of the tail.
					MACRO	SET field, value
					ld		a,(value) & $FF
					ld		(REC + field),a
					ENDM

; A step in D (U) and E (V).
					MACRO	STEP du, dv
					ld		de,(((du) & $FF) << 8) | ((dv) & $FF)
					ENDM


start:				ld		sp,$FE00

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

					TEST	"steer: along the east wall, past the middle"
					call	fresh
					ld		a,128
					ld		(room_door_z + 1),a
					ld		a,196
					ld		(room_door_at + 1),a
					SET		CHARACTER_FACING, 1
					SET		OBJ.U, 185
					SET		OBJ.V, 136
					STEP	0, 3
					RUN		character_steer
					EXPECT_WORD	s_de, $0002, "the step"

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

					call	finish
					DB		"knight_tests", 0


; ---------------------------------------------------------------------------
; Fixtures.

; The knight at the middle of the floor, and no arches.
fresh:				ld		hl,REC
					ld		bc,2 * ROOM_STRIDE + 16
					call	zero
					ld		hl,room_door_z
					ld		bc,8
					call	zero
					ld		a,128
					ld		(REC + OBJ.U),a
					ld		(REC + OBJ.V),a
					ld		(REC + OBJ.Z),a
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
; The engine around knight.s.

room_door_z:		DS		4
room_door_at:		DS		4

; The two sprites knight.s names for the walker. Only their addresses matter.
sprite_030:			DB		0
sprite_092:			DB		0

; As engine/walker.s has it: A, made positive. B is kept.
character_door_find:
.abs:				or		a
					ret		p
					neg
					ret


					INCLUDE	"../knight.s"
