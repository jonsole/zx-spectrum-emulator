; Unit tests for pentagram/movers.s, in Z80, run on the C++ core by
; engine/tests/run_tests.py.
;
; movers.s is assembled with the engine's mover framework, engine/mover.s, and
; the behaviours it shares with Knight Lore, engine/movers.s -- both real,
; because what is checked here is that Pentagram's own table and its own
; movers reach the shared routines and use them the way they mean to. The
; shared routines themselves are engine/tests/movers_tests.s's.
;
; What movers.s calls outside the engine -- quest.s, flyers.s, the score and
; the sounds -- is a stub, and so is the engine below the framework: the
; clamp, the sort, placement and the redraw regions, stubbed the way
; knightlore/tests/movers_tests.s stubs them. Every test runs in a quiet room:
; fresh zeroes room_busy.
;
; This covers what moved into the library -- the table's entries, the pacers
; and the bobbing head as Pentagram sets them up -- and the two of Pentagram's
; own movers built on it: the crumbling block and the lift.

					ORG		$0100
					INCLUDE	"../../engine/tests/harness.s"

					INCLUDE	"../../engine/object_struct.s"

REC					EQU		$C000		; the record under test
ROOMS				EQU		$C100		; room_objects, for movers_step

; What the rest of the engine gives movers.s.
COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4
OBJ_PASSABLE		EQU		$04
OBJ_FLIP_H			EQU		1
CHARACTER_BODY		EQU		ROOM_STRIDE		; as engine/walker.s has them
CHARACTER_DZ		EQU		ROOM_STRIDE * 2
room_objects		EQU		ROOMS

; Sabreman's, from sabreman.s.
CHARACTER_HALF_U	EQU		5
CHARACTER_HALF_V	EQU		5

FLYER_SLOTS			EQU		2


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

; The table's entry for a behaviour.
					MACRO	EXPECT_TBL behaviour, routine, what
					EXPECT_WORD	mover_tbl + ((behaviour) - BEHAVIOUR_FIRST_TURN) * 2, routine, what
					ENDM


start:				ld		sp,$FE00

; --- mover_of, mover_tbl ---------------------------------------------------------
; The template numbers are the room data's: object_10 is index 20, and so on.

					TEST	"find: the sinking platform"
					call	fresh
					ld		a,20		; object_10, graphic 78
					call	mover_find
					call	snap
					EXPECT_A	MOVE_SINKS, "the behaviour"

					TEST	"find: what falls, and the last in the list"
					call	fresh
					ld		a,44		; object_22, graphic 91
					call	mover_find
					call	snap
					EXPECT_A	MOVE_FALLS, "object_22"
					ld		a,56		; object_28, the entry before the $FF
					call	mover_find
					call	snap
					EXPECT_A	MOVE_CONVEYOR, "object_28"

					TEST	"find: a wall does nothing"
					call	fresh
					ld		a,2
					call	mover_find
					call	snap
					EXPECT_A	MOVE_NONE, "the behaviour"

					TEST	"table: the shared ones"
					EXPECT_TBL	MOVE_FALLS, mover_falls, "MOVE_FALLS"
					EXPECT_TBL	MOVE_SINKS, mover_sinks, "MOVE_SINKS"

					TEST	"step: a platform stood on sinks a unit"
					call	fresh
					call	one_in_the_room
					ld		a,MOVE_SINKS
					ld		(ROOMS + OBJ.BEHAVIOUR),a
					ld		a,8
					ld		(ROOMS + OBJ.MOVE_STATE),a
					ld		a,128
					ld		(ROOMS + OBJ.Z),a
					call	movers_step
					EXPECT_BYTE	ROOMS + OBJ.MOVE_STATE, 0, "MOVE_STATE, the mark taken"
					EXPECT_BYTE	ROOMS + OBJ.Z, 127, "Z"
					EXPECT_BYTE	z_calls, 1, "sound_z, which is Pentagram's silence"

					TEST	"step: what falls loses its step"
					call	fresh
					call	one_in_the_room
					ld		a,MOVE_FALLS
					ld		(ROOMS + OBJ.BEHAVIOUR),a
					ld		a,3
					ld		(ROOMS + OBJ.DU),a
					call	movers_step
					EXPECT_WORD	clamp_de, 0, "the step clamped"
					EXPECT_BYTE	ROOMS + OBJ.DU, 0, "DU after"

; --- the pacers ---------------------------------------------------------------
; Two a turn. A platform goes straight to the library and never sits out; a
; dragon's head goes through monster_sits_out first. busy_count at one is the
; turn a monster would sit out.

					TEST	"table: the pacers and the hopper"
					EXPECT_TBL	MOVE_PACE_U, mover_pacer_u, "MOVE_PACE_U"
					EXPECT_TBL	MOVE_PACE_V, mover_pacer_v, "MOVE_PACE_V"
					EXPECT_TBL	MOVE_PACE_U_DEADLY, mover_pace_u_deadly, "MOVE_PACE_U_DEADLY"
					EXPECT_TBL	MOVE_PACE_V_DEADLY, mover_pace_v_deadly, "MOVE_PACE_V_DEADLY"
					EXPECT_TBL	MOVE_HOPPER, mover_hopper, "MOVE_HOPPER"

					TEST	"platform: two a turn, and never sits out"
					call	fresh
					call	busy_and_due
					SET		OBJ.BEHAVIOUR, MOVE_PACE_U
					SET		OBJ.MOVE_STATE, COLLIDE_U
					RUN		mover_pacer_u
					EXPECT_WORD	clamp_de, $0200, "the step clamped"
					EXPECT_BYTE	busy_count, 1, "busy_count, untouched"

					TEST	"platform: from rest along V, back two"
					call	fresh
					SET		OBJ.BEHAVIOUR, MOVE_PACE_V
					RUN		mover_pacer_v
					EXPECT_WORD	clamp_de, $00FE, "the step clamped"

					TEST	"platform: stopped along its axis, turns"
					call	fresh
					SET		OBJ.BEHAVIOUR, MOVE_PACE_U
					SET		OBJ.MOVE_STATE, COLLIDE_U
					ld		a,COLLIDE_U
					ld		(stub_hit),a
					RUN		mover_pacer_u
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE, turned"

					TEST	"dragon's head: sits its turn out in a busy room"
					call	fresh
					call	busy_and_due
					SET		OBJ.BEHAVIOUR, MOVE_PACE_U_DEADLY
					RUN		mover_pace_u_deadly
					EXPECT_BYTE	clamp_calls, 0, "clamps"
					EXPECT_BYTE	busy_count, 4, "busy_count, from room_busy again"

					TEST	"dragon's head: paces in a quiet room"
					call	fresh
					SET		OBJ.BEHAVIOUR, MOVE_PACE_V_DEADLY
					SET		OBJ.MOVE_STATE, COLLIDE_V
					RUN		mover_pace_v_deadly
					EXPECT_WORD	clamp_de, $0002, "the step clamped"

; --- the bobbing head ------------------------------------------------------------
; It climbs a unit a turn, net of gravity, and comes down once it is at 176.

					TEST	"bobbing head: its top is one below 176"
					EXPECT_BYTE	hopper_top, 175, "hopper_top"

					TEST	"bobbing head: lands, and is to rise"
					call	fresh
					ld		a,COLLIDE_Z
					ld		(stub_hit),a
					SET		OBJ.DU, 3
					RUN		mover_hopper
					EXPECT_WORD	clamp_de, 0, "the step, never along the floor"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1 << HOPPER_RISING, "MOVE_STATE"

					TEST	"bobbing head: 174 to 175, still rising"
					call	fresh
					SET		OBJ.Z, 174
					SET		OBJ.MOVE_STATE, 1 << HOPPER_RISING
					RUN		mover_hopper
					EXPECT_FIELD	OBJ.Z, 175, "Z"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1 << HOPPER_RISING, "MOVE_STATE"

					TEST	"bobbing head: 175 to 176, down again"
					call	fresh
					SET		OBJ.Z, 175
					SET		OBJ.MOVE_STATE, 1 << HOPPER_RISING
					RUN		mover_hopper
					EXPECT_FIELD	OBJ.Z, 176, "Z"
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE"

; --- mover_crumbles ----------------------------------------------------------------
; The block stands at Z 128 and is 8 high, so he is on it at Z 136. It steps a
; frame on turns that are a multiple of CRUMBLE_EVERY, which is four.

					TEST	"crumbles: nobody on it, nothing"
					call	fresh
					call	block_under_him
					ld		a,128		; beside it, not on it
					ld		(player + OBJ.Z),a
					RUN		mover_crumbles
					EXPECT_FIELD	OBJ.GFX, 136, "the graphic"
					EXPECT_BYTE	defer_calls, 0, "redraw_defer"

					TEST	"crumbles: on it, but not its turn"
					call	fresh
					call	block_under_him
					ld		a,5
					ld		(move_tick),a
					RUN		mover_crumbles
					EXPECT_FIELD	OBJ.GFX, 136, "the graphic"

					TEST	"crumbles: on it, a frame on"
					call	fresh
					call	block_under_him
					ld		a,4
					ld		(move_tick),a
					RUN		mover_crumbles
					EXPECT_FIELD	OBJ.GFX, 137, "the graphic"
					EXPECT_BYTE	clamp_dz, 0, "DZ, held up"
					EXPECT_BYTE	defer_calls, 1, "redraw_defer"

					TEST	"crumbles: after the last frame, gone"
					call	fresh
					call	block_under_him
					SET		OBJ.GFX, CRUMBLE_LAST
					RUN		mover_crumbles
					EXPECT_BYTE	unlink_calls, 1, "depth_unlink"
					EXPECT_FIELD	OBJ.GFX, 0, "GFX"
					EXPECT_FIELD	OBJ.BEHAVIOUR, 0, "BEHAVIOUR"
					EXPECT_FIELD	OBJ.FLAGS, OBJ_PASSABLE, "FLAGS"

; --- mover_lift ------------------------------------------------------------------

					TEST	"lift: waiting, and he is not on it"
					call	fresh
					call	block_under_him
					ld		a,128
					ld		(player + OBJ.Z),a
					RUN		mover_lift
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE"
					EXPECT_BYTE	clamp_calls, 0, "clamps"

					TEST	"lift: he steps on, and up they go"
					call	fresh
					call	block_under_him
					RUN		mover_lift
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE, going"
					EXPECT_BYTE	player + CHARACTER_DZ, LIFT_GIVES_HIM, "his DZ"
					EXPECT_BYTE	clamp_dz, LIFT_RISE, "DZ, net of gravity"
					EXPECT_FIELD	OBJ.Z, 128 + LIFT_RISE, "Z"

					call	finish
					DB		"movers_tests (pentagram)", 0


; ---------------------------------------------------------------------------
; Fixtures.

; A clean record, a clean Sabreman, the stubs and busy.s's bytes zeroed, and
; mover_ix -> REC.
fresh:				ld		hl,REC
					ld		bc,ROOM_STRIDE
					call	zero
					ld		hl,ROOMS
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
					ld		(room_busy),a
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

; A busy room, and this monster the one due to sit out.
busy_and_due:		ld		a,4
					ld		(room_busy),a
					ld		a,1
					ld		(busy_count),a
					ret

one_in_the_room:	ld		a,1
					ld		(room_object_count),a
					ret

; A crumbling block at U 80, V 90, Z 128, 8 high, with him standing on it.
block_under_him:	ld		ix,REC
					SET		OBJ.GFX, 136
					SET		OBJ.BEHAVIOUR, MOVE_CRUMBLES
					SET		OBJ.U, 80
					SET		OBJ.V, 90
					SET		OBJ.Z, 128
					SET		OBJ.SIZE_U, 4
					SET		OBJ.SIZE_V, 4
					SET		OBJ.SIZE_Z, 8
					ld		a,80
					ld		(player + OBJ.U),a
					ld		a,90
					ld		(player + OBJ.V),a
					ld		a,136
					ld		(player + OBJ.Z),a
					ret


; ---------------------------------------------------------------------------
; The game around movers.s.

PLAYER_SIZE			EQU		3 * ROOM_STRIDE
player:				DS		PLAYER_SIZE
walker_player		EQU		player

flyer_slots:		DW		0
busy_count:			DB		0
room_busy:			DB		0		; engine/busy.s's, which this suite does not include

mover_quest:
mover_well:
mover_collectable:
mover_water:
score_add:
sound_poof:			ret

sound_z:			ld		hl,z_calls
					inc		(hl)
					ret


; ---------------------------------------------------------------------------
; The engine around them.

stubs:
collide_hit:		DB		0
collide_other:		DW		0
room_object_count:	DB		0

z_calls:			DB		0
stub_hit:			DB		0		; what the clamp says gave
clamp_calls:		DB		0
clamp_de:			DW		0		; D, E as the clamp was handed them
clamp_dz:			DB		0		; DZ as the clamp saw it, gravity taken
defer_calls:		DB		0
unlink_calls:		DB		0
s_ix:				DW		0
STUBS_SIZE			EQU		$ - stubs

; Nothing in the way, unless stub_hit says so; the step is never cut.
object_collide_room:
					ld		(clamp_de),de
					ld		a,(ix+OBJ.DZ)
					ld		(clamp_dz),a
					ld		hl,clamp_calls
					inc		(hl)
					ld		a,(stub_hit)
					ld		(collide_hit),a
					ret

; As depth_add_step: the step onto U, V and Z.
depth_step:			ld		b,a
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

depth_unlink:		ld		hl,unlink_calls
					inc		(hl)
					ret

; These are free to leave IX anywhere, and so they do.
object_place:		ld		ix,$DEAD
					ret

redraw_defer:		ld		hl,defer_calls
					inc		(hl)
					ld		ix,$BEEF
					ret

redraw_view:		ld		ix,$DEAD
					ret

region_reset:
region_add:
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


					INCLUDE	"../movers.s"
					INCLUDE	"../../engine/mover.s"
					INCLUDE	"../shared_movers.s"
					INCLUDE	"../../engine/movers.s"
