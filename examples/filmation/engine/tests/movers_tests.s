; Unit tests for engine/movers.s, the behaviours the games share, in Z80, run
; on the C++ core by run_tests.py.
;
; The library is assembled with the real mover framework, engine/mover.s,
; because that is what its routines are built from, and with a game of
; nothing but the names the library asks for: a four-entry mover_of, a
; character, and sound_z and sound_falls as counting stubs. The rest of the
; engine -- the clamp, the sort, placement, the redraw regions -- is stubbed
; the way engine/tests/mover_tests.s stubs it. Each game's own suite checks
; that its mover_tbl reaches these; this one checks what they do.
;
; Every routine here is used by this suite, so IFUSED keeps them all. The
; names the pacer and the hopper call are counting stubs, and the three that
; name mover.s routines follow its INCLUDE.

					ORG		$0100
					INCLUDE	"harness.s"

					INCLUDE	"../object_struct.s"

REC					EQU		$C000		; the record under test
ROOMS				EQU		$C100		; room_objects, for movers_step

; What the rest of the engine gives mover.s and movers.s.
COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4
OBJ_PASSABLE		EQU		$04
room_objects		EQU		ROOMS

; What a game gives them. The character's half-widths are this suite's own,
; chosen apart from the record's sizes so that a sum taken the wrong way
; round shows.
BEHAVIOUR_FIRST_TURN	EQU		2
CHARACTER_HALF_U	EQU		5
CHARACTER_HALF_V	EQU		3


; Run a routine with IX -> REC, as movers_step leaves it, and keep what came
; back: the registers in s_*, and IX in s_ix.
					MACRO	RUN routine
					ld		ix,REC
					call	routine
					ld		(s_ix),ix
					call	snap
					ENDM

					MACRO	EXPECT_FIELD field, value, what
					EXPECT_BYTE	REC + field, value, what
					ENDM

					MACRO	SET field, value
					ld		(ix+field),(value) & $FF
					ENDM

; The zero flag snap took: 1 for set.
					MACRO	EXPECT_ZF value, what
					ld		a,(s_af)
					and		$40
					ld		l,a
					ld		h,0
					ld		de,(value) * $40
					call	expect_hl_de
					DB		what, 0
					ENDM

; The character standing at U, V, Z.
					MACRO	PLAYER_AT u, v, z
					ld		a,u
					ld		(player + OBJ.U),a
					ld		a,v
					ld		(player + OBJ.V),a
					ld		a,z
					ld		(player + OBJ.Z),a
					ENDM


start:				ld		sp,$FE00

; --- mover_find ----------------------------------------------------------------

					TEST	"find: a template in the middle of the list"
					call	fresh
					ld		de,$1234
					ld		a,9
					call	mover_find
					call	snap
					EXPECT_A	3, "the behaviour"
					EXPECT_WORD	s_de, $1234, "DE"

					TEST	"find: the first"
					call	fresh
					ld		a,4
					call	mover_find
					call	snap
					EXPECT_A	7, "the behaviour"

					TEST	"find: the last before the end"
					call	fresh
					ld		a,0		; a template 0 is as good as any other
					call	mover_find
					call	snap
					EXPECT_A	12, "the behaviour"

					TEST	"find: one that is not listed"
					call	fresh
					ld		a,5
					call	mover_find
					call	snap
					EXPECT_A	0, "the behaviour"

; --- mover_falls, mover_falls_noisy -------------------------------------------

					TEST	"falls: its step goes before it moves"
					call	fresh
					SET		OBJ.DU, 3
					SET		OBJ.DV, -2
					SET		OBJ.DZ, 5
					RUN		mover_falls
					EXPECT_WORD	clamp_de, 0, "the step clamped"
					EXPECT_BYTE	clamp_dz, 4, "DZ, left to gravity"
					EXPECT_BYTE	falls_calls, 0, "sound_falls"
					EXPECT_WORD	s_ix, REC, "IX"

					TEST	"falls noisy: the game's sound, then the same"
					call	fresh
					SET		OBJ.DU, 3
					RUN		mover_falls_noisy
					EXPECT_BYTE	falls_calls, 1, "sound_falls"
					EXPECT_WORD	clamp_de, 0, "the step clamped"
					EXPECT_BYTE	clamp_dz, -1 & $FF, "DZ, gravity"

; --- mover_sinks ---------------------------------------------------------------

					TEST	"sinks: nothing on it, nothing"
					call	fresh
					SET		OBJ.MOVE_STATE, 1
					RUN		mover_sinks
					EXPECT_BYTE	clamp_calls, 0, "clamps"
					EXPECT_BYTE	z_calls, 0, "sound_z"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE"

					TEST	"sinks: landed on, down a unit and sounding"
					call	fresh
					SET		OBJ.MOVE_STATE, 8 | 1
					SET		OBJ.DZ, 5
					SET		OBJ.Z, 100
					RUN		mover_sinks
					EXPECT_BYTE	clamp_dz, -1 & $FF, "DZ: nought, less gravity"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE, the mark taken"
					EXPECT_FIELD	OBJ.Z, 99, "Z"
					EXPECT_BYTE	z_calls, 1, "sound_z"

					TEST	"sinks: landed on but on the floor, silent"
					call	fresh
					SET		OBJ.MOVE_STATE, 8
					ld		a,COLLIDE_Z
					ld		(stub_hit),a
					ld		a,1
					ld		(stub_block),a
					RUN		mover_sinks
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE, the mark taken"
					EXPECT_BYTE	step_calls, 0, "depth_step"
					EXPECT_BYTE	z_calls, 0, "sound_z"

; --- player_on_top ---------------------------------------------------------------
; The record stands at U 50, V 60, Z 100, sized 4 by 6 by 10: its top is 110.
; He is over it along U while the centres are closer than 4 + 5 = 9, and along
; V closer than 6 + 3 = 9 too. The edge is the same on both axes, but a sum
; that took the other axis's size or half-width would come to 7 or 11 and
; move it. He is on it while his feet are from 0 to 6 above its top.

					TEST	"on top: feet on its top"
					call	fresh
					call	block_at_50
					PLAYER_AT	50, 60, 110
					RUN		player_on_top
					EXPECT_ZF	1, "zf"

					TEST	"on top: six above still counts"
					call	fresh
					call	block_at_50
					PLAYER_AT	50, 60, 116
					RUN		player_on_top
					EXPECT_ZF	1, "zf"

					TEST	"on top: seven above does not"
					call	fresh
					call	block_at_50
					PLAYER_AT	50, 60, 117
					RUN		player_on_top
					EXPECT_ZF	0, "zf"

					TEST	"on top: below its top is not on it"
					call	fresh
					call	block_at_50
					PLAYER_AT	50, 60, 109
					RUN		player_on_top
					EXPECT_ZF	0, "zf"

					TEST	"on top: eight along U, either way, is over it"
					call	fresh
					call	block_at_50
					PLAYER_AT	58, 60, 110
					RUN		player_on_top
					EXPECT_ZF	1, "zf, +8"
					PLAYER_AT	42, 60, 110
					RUN		player_on_top
					EXPECT_ZF	1, "zf, -8"

					TEST	"on top: nine along U only touches"
					call	fresh
					call	block_at_50
					PLAYER_AT	59, 60, 110
					RUN		player_on_top
					EXPECT_ZF	0, "zf"

					TEST	"on top: eight along V is over it, nine is not"
					call	fresh
					call	block_at_50
					PLAYER_AT	50, 52, 110
					RUN		player_on_top
					EXPECT_ZF	1, "zf, -8"
					PLAYER_AT	50, 69, 110
					RUN		player_on_top
					EXPECT_ZF	0, "zf, +9"

; --- mover_pacer_u, mover_pacer_v, mover_turn_if_hit ------------------------------
; PACER_STEP is three here, so a step of one or two is somebody else's.

					TEST	"pacer U: its bit set, forward along U"
					call	fresh
					SET		OBJ.U, 100
					SET		OBJ.MOVE_STATE, COLLIDE_U
					SET		OBJ.DV, 7
					SET		OBJ.DZ, -4
					RUN		mover_pacer_u
					EXPECT_BYTE	sound_calls, 1, "pacer_sound"
					EXPECT_BYTE	sound_l, COLLIDE_U, "...with L the axis"
					EXPECT_BYTE	frame_calls, 1, "pacer_frame"
					EXPECT_WORD	frame_duv, 0, "...with the step cleared"
					EXPECT_BYTE	frame_dz, 1, "...and held up"
					EXPECT_WORD	clamp_de, $0300, "the step clamped"
					EXPECT_BYTE	clamp_dz, 0, "DZ, held up against gravity"
					EXPECT_FIELD	OBJ.U, 103, "U"
					EXPECT_FIELD	OBJ.MOVE_STATE, COLLIDE_U, "MOVE_STATE"
					EXPECT_BYTE	turned_calls, 0, "mover_turned"

					TEST	"pacer U: from rest, the negative way"
					call	fresh
					RUN		mover_pacer_u
					EXPECT_WORD	clamp_de, $FD00, "the step clamped"

					TEST	"pacer V: stopped along V turns, and says so"
					call	fresh
					SET		OBJ.MOVE_STATE, COLLIDE_V | COLLIDE_U
					ld		a,COLLIDE_V
					ld		(stub_hit),a
					RUN		mover_pacer_v
					EXPECT_BYTE	sound_l, COLLIDE_V, "pacer_sound's L"
					EXPECT_WORD	clamp_de, $0003, "the step clamped"
					EXPECT_FIELD	OBJ.MOVE_STATE, COLLIDE_U, "MOVE_STATE, only V turned"
					EXPECT_BYTE	turned_calls, 1, "mover_turned"
					EXPECT_BYTE	turned_a, COLLIDE_V, "...with A the axis"

					TEST	"pacer V: stopped along U does not turn it"
					call	fresh
					SET		OBJ.MOVE_STATE, COLLIDE_V
					ld		a,COLLIDE_U
					ld		(stub_hit),a
					RUN		mover_pacer_v
					EXPECT_FIELD	OBJ.MOVE_STATE, COLLIDE_V, "MOVE_STATE"
					EXPECT_BYTE	turned_calls, 0, "mover_turned"

; --- mover_hopper_claim, mover_hopper -------------------------------------------
; HOPPER_RISE is four and HOPPER_ABOVE twenty. It climbs while its Z after the
; move is no more than hopper_top.

					TEST	"hopper claim: the first sets the top"
					call	fresh
					SET		OBJ.Z, 100
					SET		OBJ.DU, 3
					RUN		mover_hopper_claim
					EXPECT_BYTE	hopper_top, 120, "hopper_top"
					EXPECT_WORD	clamp_de, 0, "the step, cleared by hopper_frame"
					EXPECT_BYTE	hsound_calls, 1, "hopper_sound"

					TEST	"hopper claim: a top already claimed stays"
					call	fresh
					ld		a,50
					ld		(hopper_top),a
					SET		OBJ.Z, 100
					RUN		mover_hopper_claim
					EXPECT_BYTE	hopper_top, 50, "hopper_top"

					TEST	"hopper: falling, nothing under it yet"
					call	fresh
					SET		OBJ.DZ, -2
					RUN		mover_hopper
					EXPECT_BYTE	clamp_dz, -3 & $FF, "DZ, gravity on top"
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE"
					EXPECT_BYTE	landed_calls, 0, "hopper_landed"
					EXPECT_BYTE	hopper_top, 0, "hopper_top, unclaimed"

					TEST	"hopper: lands, and is to rise"
					call	fresh
					SET		OBJ.MOVE_STATE, 1
					ld		a,COLLIDE_Z
					ld		(stub_hit),a
					RUN		mover_hopper
					EXPECT_FIELD	OBJ.MOVE_STATE, 1 | (1 << HOPPER_RISING), "MOVE_STATE"
					EXPECT_BYTE	landed_calls, 1, "hopper_landed"

					TEST	"hopper: rising, four less gravity"
					call	fresh
					ld		a,110
					ld		(hopper_top),a
					SET		OBJ.Z, 100
					SET		OBJ.MOVE_STATE, 1 << HOPPER_RISING
					RUN		mover_hopper
					EXPECT_BYTE	clamp_dz, 3, "DZ"
					EXPECT_FIELD	OBJ.Z, 103, "Z"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1 << HOPPER_RISING, "MOVE_STATE"

					TEST	"hopper: up to the top exactly, still rising"
					call	fresh
					ld		a,110
					ld		(hopper_top),a
					SET		OBJ.Z, 107
					SET		OBJ.MOVE_STATE, 1 << HOPPER_RISING
					RUN		mover_hopper
					EXPECT_FIELD	OBJ.Z, 110, "Z"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1 << HOPPER_RISING, "MOVE_STATE"

					TEST	"hopper: past the top, falls again"
					call	fresh
					ld		a,110
					ld		(hopper_top),a
					SET		OBJ.Z, 108
					SET		OBJ.MOVE_STATE, 1 | (1 << HOPPER_RISING)
					RUN		mover_hopper
					EXPECT_FIELD	OBJ.Z, 111, "Z"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE, only its bit cleared"

; --- mover_conveyor -------------------------------------------------------------
; It never moves by its step: object_carry hands that to whatever stands on it,
; and the bottom two bits of the graphic say which way. The table is the game's,
; and this one's is the four ways round in a different order from Pentagram's,
; so a routine that knew the directions itself rather than reading them would
; show here.

					TEST	"conveyor: the way its graphic names"
					call	fresh
					SET		OBJ.GFX, 140 + 2		; the third pair
					SET		OBJ.U, 100
					SET		OBJ.V, 100
					RUN		mover_conveyor
					EXPECT_FIELD	OBJ.DU, 0, "DU"
					EXPECT_FIELD	OBJ.DV, 3, "DV"
					EXPECT_FIELD	OBJ.U, 100, "U: it does not move itself"
					EXPECT_FIELD	OBJ.V, 100, "V"
					EXPECT_BYTE	clamp_calls, 0, "clamps"

					TEST	"conveyor: only the bottom two bits count"
					call	fresh
					SET		OBJ.GFX, 143		; ...which is the fourth pair
					RUN		mover_conveyor
					EXPECT_FIELD	OBJ.DU, -4 & $FF, "DU"
					EXPECT_FIELD	OBJ.DV, 0, "DV"

; --- object_hide ---------------------------------------------------------------

					TEST	"hide: repainted, unlinked, and the slot emptied"
					call	fresh
					SET		OBJ.GFX, 77
					SET		OBJ.BEHAVIOUR, 5
					SET		OBJ.FLAGS, $80
					RUN		object_hide
					EXPECT_BYTE	reset_calls, 1, "region_reset"
					EXPECT_BYTE	add_calls, 1, "region_add, where it was"
					EXPECT_BYTE	unlink_calls, 1, "depth_unlink"
					EXPECT_WORD	unlink_ix, REC, "...of it"
					EXPECT_BYTE	unlink_gfx, 77, "...before it was blanked"
					EXPECT_BYTE	view_calls, 1, "redraw_view"
					EXPECT_FIELD	OBJ.GFX, 0, "GFX"
					EXPECT_FIELD	OBJ.BEHAVIOUR, 0, "BEHAVIOUR"
					EXPECT_FIELD	OBJ.FLAGS, OBJ_PASSABLE, "FLAGS"

					call	finish
					DB		"movers_tests (engine)", 0


; ---------------------------------------------------------------------------
; Fixtures.

; A clean record, a clean character, the stubs zeroed, and mover_ix -> REC.
fresh:				ld		hl,REC
					ld		bc,ROOM_STRIDE
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

block_at_50:		ld		ix,REC
					SET		OBJ.U, 50
					SET		OBJ.V, 60
					SET		OBJ.Z, 100
					SET		OBJ.SIZE_U, 4
					SET		OBJ.SIZE_V, 6
					SET		OBJ.SIZE_Z, 10
					ret


; ---------------------------------------------------------------------------
; The game: only what movers.s names.

; Which way each conveyor pushes, by the bottom two bits of its graphic.
conveyor_steps:		DB		1, 0
					DB		0, -2
					DB		0, 3
					DB		-4, 0

mover_of:			DB		4, 7
					DB		9, 3
					DB		6, 2
					DB		0, 12
					DB		$FF

mover_tbl:			DW		mover_falls		; behaviour 2, for movers_step

PLAYER_SIZE			EQU		3 * ROOM_STRIDE
player:				DS		PLAYER_SIZE
walker_player		EQU		player

sound_z:			ld		hl,z_calls
					inc		(hl)
					ret

sound_falls:		ld		hl,falls_calls
					inc		(hl)
					ret

; The pacer's and the hopper's. The ones that are routines count their calls
; and write down what they were handed.
PACER_STEP			EQU		3
HOPPER_RISE			EQU		4
HOPPER_ABOVE		EQU		20

pacer_sound:		ld		a,l
					ld		(sound_l),a
					ld		hl,sound_calls
					inc		(hl)
					ret

pacer_frame:		ld		a,(ix+OBJ.DU)
					ld		(frame_duv),a
					ld		a,(ix+OBJ.DV)
					ld		(frame_duv + 1),a
					ld		a,(ix+OBJ.DZ)
					ld		(frame_dz),a
					ld		hl,frame_calls
					inc		(hl)
					ret

mover_turned:		ld		(turned_a),a
					ld		hl,turned_calls
					inc		(hl)
					ret

hopper_sound:		ld		hl,hsound_calls
					inc		(hl)
					ret

hopper_landed:		ld		hl,landed_calls
					inc		(hl)
					ret


; ---------------------------------------------------------------------------
; The engine around them.

stubs:
collide_hit:		DB		0
collide_other:		DW		0
room_object_count:	DB		0

stub_hit:			DB		0		; what the clamp says gave
stub_block:			DB		0		; non-zero: the clamp takes the whole step

z_calls:			DB		0
falls_calls:		DB		0
clamp_calls:		DB		0
clamp_de:			DW		0		; D, E as the clamp was handed them
clamp_dz:			DB		0		; DZ as the clamp saw it, gravity taken
step_calls:			DB		0
reset_calls:		DB		0
add_calls:			DB		0
unlink_calls:		DB		0
unlink_ix:			DW		0
unlink_gfx:			DB		0
view_calls:			DB		0
sound_calls:		DB		0
sound_l:			DB		0
frame_calls:		DB		0
frame_duv:			DW		0		; DU, DV as pacer_frame saw them
frame_dz:			DB		0
turned_calls:		DB		0
turned_a:			DB		0
hsound_calls:		DB		0
landed_calls:		DB		0
hopper_top:			DB		0
s_ix:				DW		0
STUBS_SIZE			EQU		$ - stubs

object_collide_room:
					ld		(clamp_de),de
					ld		a,(ix+OBJ.DZ)
					ld		(clamp_dz),a
					ld		hl,clamp_calls
					inc		(hl)
					ld		a,(stub_hit)
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
depth_step:			ld		hl,step_calls
					inc		(hl)
					ld		b,a
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

region_reset:		ld		hl,reset_calls
					inc		(hl)
					ret

region_add:			ld		hl,add_calls
					inc		(hl)
					ret

depth_unlink:		ld		(unlink_ix),ix
					ld		a,(ix+OBJ.GFX)
					ld		(unlink_gfx),a
					ld		hl,unlink_calls
					inc		(hl)
					ret

; Free to leave IX anywhere, as the real one is.
redraw_view:		ld		hl,view_calls
					inc		(hl)
					ld		ix,$DEAD
					ret

; These two are free to leave IX anywhere, and so they do.
object_place:		ld		ix,$DEAD
					ret

redraw_defer:		ld		ix,$BEEF
					ret

room_adjust:
depth_step_upper:
depth_relink:
pair_region_add:	ret

; walker.s's: A, made positive.
character_door_find:
.abs:				or		a
					ret		p
					neg
					ret


					INCLUDE	"../mover.s"
; Named after mover.s, so that each is the value its label has in this pass.
pacer_move			EQU		mover_move
hopper_frame		EQU		mover_halt
hopper_move			EQU		mover_move
					INCLUDE	"../movers.s"
