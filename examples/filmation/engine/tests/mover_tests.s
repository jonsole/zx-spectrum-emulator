; Unit tests for engine/mover.s, in Z80, run on the C++ core by run_tests.py.
;
; The mover framework is assembled on its own, with a game of one behaviour:
; test_mover, standing in for the game's mover_tbl. Everything the framework
; calls out to -- the collision clamp, the depth sort, placement, the redraw
; regions -- is a stub below that counts its calls and writes down what it was
; handed. The behaviours of a real game are its own suites' business:
; knightlore/tests/movers_tests.s.
;
; The stubs behave the way the real routines' contracts say, and no better:
; object_place and redraw_defer come back with IX pointing somewhere else, as
; the real ones are free to, so a routine that forgets to reload it writes into
; the wrong record and fails here.

					ORG		$0100
					INCLUDE	"harness.s"

					INCLUDE	"../object_struct.s"

REC					EQU		$C000		; the record under test; a pair's second follows
ROOMS				EQU		$C100		; room_objects, for movers_step

; What the rest of the engine gives mover.s.
COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4
OBJ_PASSABLE		EQU		$04
room_objects		EQU		ROOMS

; What a game gives it: behaviour 2 and up get a turn, through mover_tbl.
BEHAVIOUR_FIRST_TURN	EQU		2
TEST_BEHAVIOUR		EQU		2


; Run a routine with IX -> REC, as movers_step leaves it, and keep what came
; back: the registers in s_*, and IX in s_ix.
					MACRO	RUN routine
					ld		ix,REC
					call	routine
					ld		(s_ix),ix
					call	snap
					ENDM

; A field of the record under test, or of the second of its pair.
					MACRO	EXPECT_FIELD field, value, what
					EXPECT_BYTE	REC + field, value, what
					ENDM

					MACRO	EXPECT_PAIR field, value, what
					EXPECT_BYTE	REC + MOVER_PAIR + field, value, what
					ENDM

; Set a field of the record under test.
					MACRO	SET field, value
					ld		(ix+field),(value) & $FF
					ENDM


start:				ld		sp,$FE00

; --- movers_step -------------------------------------------------------------

					TEST	"step: only a mover gets a turn"
					call	fresh
					call	three_records
					ld		a,0
					ld		(ROOMS + OBJ.BEHAVIOUR),a
					ld		a,BEHAVIOUR_FIRST_TURN - 1
					ld		(ROOMS + ROOM_STRIDE + OBJ.BEHAVIOUR),a
					ld		a,TEST_BEHAVIOUR
					ld		(ROOMS + 2 * ROOM_STRIDE + OBJ.BEHAVIOUR),a
					ld		a,1
					ld		(ROOMS + 2 * ROOM_STRIDE + OBJ.DU),a
					ld		a,3
					ld		(room_object_count),a
					call	movers_step
					EXPECT_BYTE	turn_calls, 1, "turns"
					EXPECT_WORD	turn_ix, ROOMS + 2 * ROOM_STRIDE, "the record given its turn"
					EXPECT_BYTE	clamp_calls, 1, "clamps"
					EXPECT_WORD	clamp_ix, ROOMS + 2 * ROOM_STRIDE, "the record clamped"
					EXPECT_BYTE	move_tick, 1, "move_tick"
					EXPECT_BYTE	ROOMS + 2 * ROOM_STRIDE + OBJ.DU, 0, "the table's DU, spent"

					TEST	"step: an empty room still counts the turn"
					call	fresh
					ld		a,41
					ld		(move_tick),a
					call	movers_step
					EXPECT_BYTE	move_tick, 42, "move_tick"
					EXPECT_BYTE	turn_calls, 0, "turns"

; --- mover_clamp, mover_move, mover_paint --------------------------------------

					TEST	"clamp: gravity, and passable for its own test"
					call	fresh
					SET		OBJ.FLAGS, $81
					SET		OBJ.DU, 2
					SET		OBJ.DV, -3
					SET		OBJ.DZ, 1
					RUN		mover_clamp
					EXPECT_BYTE	clamp_calls, 1, "clamps"
					EXPECT_BYTE	clamp_flags, $81 | OBJ_PASSABLE, "FLAGS during the clamp"
					EXPECT_FIELD	OBJ.FLAGS, $81, "FLAGS after"
					EXPECT_BYTE	clamp_dz, 0, "DZ, one taken off"
					EXPECT_WORD	clamp_de, $02FD, "D and E, the step"
					EXPECT_WORD	collide_other, walker_player, "collide_other"

					TEST	"move: nothing left of the step, nothing drawn"
					call	fresh
					SET		OBJ.DU, 2
					ld		a,1
					ld		(stub_block),a
					RUN		mover_move
					EXPECT_BYTE	clamp_calls, 1, "clamps"
					EXPECT_BYTE	reset_calls, 0, "region_reset"
					EXPECT_BYTE	step_calls, 0, "depth_step"
					EXPECT_WORD	s_ix, REC, "IX"

					TEST	"move: a step is sorted, placed and drawn"
					call	fresh
					SET		OBJ.U, 100
					SET		OBJ.DU, 2
					RUN		mover_move
					EXPECT_BYTE	reset_calls, 1, "region_reset"
					EXPECT_BYTE	add_calls, 2, "region_add, before and after"
					EXPECT_BYTE	step_calls, 1, "depth_step"
					EXPECT_WORD	step_de, $0200, "the step sorted by"
					EXPECT_BYTE	place_calls, 1, "object_place"
					EXPECT_BYTE	defer_calls, 1, "redraw_defer"
					EXPECT_FIELD	OBJ.U, 102, "U"
					EXPECT_WORD	s_ix, REC, "IX"

					TEST	"move always: drawn even with nothing left"
					call	fresh
					ld		a,1
					ld		(stub_block),a
					RUN		mover_move_always
					EXPECT_BYTE	defer_calls, 1, "redraw_defer"
					EXPECT_WORD	s_ix, REC, "IX"

; --- mover_move_pair -----------------------------------------------------------

					TEST	"pair: a second that stays put is not re-sorted"
					call	fresh
					call	pair_at_100
					RUN		mover_move_pair
					EXPECT_BYTE	relink_calls, 0, "second re-sorted"
					EXPECT_BYTE	upper_calls, 1, "first asked"

					TEST	"pair: a second out of step is brought back and sorted"
					call	fresh
					call	pair_at_100
					ld		a,108		; a wizard's two pieces start eight apart
					ld		(REC + MOVER_PAIR + OBJ.U),a
					RUN		mover_move_pair
					EXPECT_PAIR	OBJ.U, 100, "the second's U"
					EXPECT_BYTE	relink_calls, 1, "second re-sorted"

					call	finish
					DB		"mover_tests", 0


; ---------------------------------------------------------------------------
; Fixtures.

; A clean record and its pair, a clean character, the stubs zeroed, mover.s's
; own state zeroed, and mover_ix -> REC.
fresh:				ld		hl,REC
					ld		bc,2 * ROOM_STRIDE
					call	zero
					ld		hl,player
					ld		bc,PLAYER_SIZE
					call	zero
					ld		hl,stubs
					ld		bc,STUBS_SIZE
					call	zero
					xor		a
					ld		(move_tick),a
					ld		ix,REC
					ld		(mover_ix),ix
					ret

;   HL -> BC bytes to clear
zero:				ld		(hl),0
					inc		hl
					dec		bc
					ld		a,b
					or		c
					jr		nz,zero
					ret

three_records:		ld		hl,ROOMS
					ld		bc,3 * ROOM_STRIDE
					jr		zero

; Both records of the pair standing at U 100, V 50.
pair_at_100:		ld		a,100
					ld		(REC + OBJ.U),a
					ld		(REC + MOVER_PAIR + OBJ.U),a
					ld		a,50
					ld		(REC + OBJ.V),a
					ld		(REC + MOVER_PAIR + OBJ.V),a
					ret


; ---------------------------------------------------------------------------
; The game: one behaviour, which moves by its step and then spends it -- the
; way a pushed block does -- and a character outside the pool.

mover_tbl:			DW		test_mover		; TEST_BEHAVIOUR
					ASSERT	TEST_BEHAVIOUR == BEHAVIOUR_FIRST_TURN

test_mover:			ld		(turn_ix),ix
					ld		hl,turn_calls
					inc		(hl)
					call	mover_move
					ld		(ix+OBJ.DU),0
					ret

PLAYER_SIZE			EQU		3 * ROOM_STRIDE
player:				DS		PLAYER_SIZE
walker_player		EQU		player


; ---------------------------------------------------------------------------
; The engine around mover.s.

stubs:
collide_hit:		DB		0
collide_other:		DW		0
room_object_count:	DB		0

stub_block:			DB		0		; non-zero: the clamp takes the whole step

turn_calls:			DB		0
turn_ix:			DW		0
clamp_calls:		DB		0
clamp_ix:			DW		0
clamp_de:			DW		0		; D, E as the clamp was handed them
clamp_flags:		DB		0		; FLAGS during the clamp
clamp_dz:			DB		0		; DZ as the clamp saw it, gravity taken
step_calls:			DB		0
step_de:			DW		0
relink_calls:		DB		0
upper_calls:		DB		0
reset_calls:		DB		0
add_calls:			DB		0
place_calls:		DB		0
defer_calls:		DB		0
s_ix:				DW		0
STUBS_SIZE			EQU		$ - stubs

object_collide_room:
					ld		(clamp_ix),ix
					ld		(clamp_de),de
					ld		a,(ix+OBJ.FLAGS)
					ld		(clamp_flags),a
					ld		a,(ix+OBJ.DZ)
					ld		(clamp_dz),a
					ld		hl,clamp_calls
					inc		(hl)
					xor		a
					ld		(collide_hit),a
					ld		a,(stub_block)
					or		a
					ret		z
					xor		a
					ld		(ix+OBJ.DU),a
					ld		(ix+OBJ.DV),a
					ld		(ix+OBJ.DZ),a
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
					ld		hl,step_calls
					inc		(hl)
					jr		add_step

depth_step_upper:	ld		hl,upper_calls
					inc		(hl)
					jr		add_step

depth_relink:		ld		hl,relink_calls
					inc		(hl)
					ret

region_reset:		ld		hl,reset_calls
					inc		(hl)
					ret

region_add:			ld		hl,add_calls
					inc		(hl)
					ret

room_adjust:		ret

; As engine/walker.s has it: both records of a pair, IX kept.
pair_region_add:	call	region_add
					ld		bc,ROOM_STRIDE
					add		ix,bc
					call	region_add
					ld		bc,-ROOM_STRIDE
					add		ix,bc
					ret

; These two are free to leave IX anywhere, and so they do.
object_place:		ld		hl,place_calls
					inc		(hl)
					ld		ix,$DEAD
					ret

redraw_defer:		ld		hl,defer_calls
					inc		(hl)
					ld		ix,$BEEF
					ret


					INCLUDE	"../mover.s"
