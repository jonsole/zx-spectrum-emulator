; Unit tests for knightlore/movers.s, in Z80, run on the C++ core by
; engine/tests/run_tests.py.
;
; movers.s is assembled with the engine's mover framework, engine/mover.s; the
; shared behaviours its mover_tbl points at, engine/movers.s -- so what is
; checked of those here is that Knight Lore's table reaches them, and the
; routines themselves are engine/tests/movers_tests.s's; and
; knightlore/monster_gate.s. That last one is here rather than stubbed because
; it is not something movers.s calls, it is where mover_tbl SENDS the monsters:
; every behaviour from MOVE_FIRE_U to MOVE_SPIKE_BALL is dispatched through it.
; Stubbing it would mean writing that dispatch a second time, and a table
; pointing at a stub proves nothing about where a monster's turn really goes.
; What is stubbed instead is busy.s's two bytes, which fresh zeroes -- so every
; test runs in a quiet room and the gate passes the monster straight on to its
; own mover.
;
; Everything else they call out to -- the collision clamp, the depth
; sort, placement, the redraw regions, the pair flip -- is a stub below that
; counts its calls and writes down what it was handed. So what is tested is
; each mover's own decision: the step it puts in the record, the graphic and
; MOVE_STATE it leaves, and what it asks the rest of the engine to do. The
; framework itself is engine/tests/mover_tests.s's business, and the clamp and
; the sort their own suites'.
;
; The stubs behave the way the real routines' contracts say, and no better:
; object_place and redraw_defer come back with IX pointing somewhere else, as
; the real ones are free to, so a mover that forgets to reload it writes into
; the wrong record and fails here.
;
; Anything decided by mover_rand -- the ghost's new heading, the gate's dice,
; which axis the hunting ball picks, a spiked ball letting go -- depends on R,
; so those tests check that the answer is one of the allowed ones rather than
; which.

					ORG		$0100
					INCLUDE	"../../engine/tests/harness.s"

					INCLUDE	"../../engine/object_struct.s"

REC					EQU		$C000		; the record under test; a guard's legs follow
ROOMS				EQU		$C100		; room_objects, for movers_step

; What the engine gives movers.s. The template numbers are rooms.json's to choose;
; these only have to be different from each other.
COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4
OBJ_PASSABLE		EQU		$04
OBJ_FLIP_BIT		EQU		0
CHARACTER_DOOR		EQU		ROOM_STRIDE * 2 + 6	; as engine/walker.s has it
room_objects		EQU		ROOMS

FG_BLOCK			EQU		$00
FG_FIRE				EQU		$01
FG_BALL_UD_Y		EQU		$02
FG_ROCK				EQU		$03
FG_GARGOYLE			EQU		$04
FG_SPIKE			EQU		$05
FG_CHEST			EQU		$06
FG_TABLE			EQU		$07
FG_GUARD_EW			EQU		$08
FG_GHOST			EQU		$09
FG_FIRE_NS			EQU		$0A
FG_BLOCK_HIGH		EQU		$0B
FG_BALL_UD_XY		EQU		$0C
FG_GUARD_SQUARE		EQU		$0D
FG_BLOCK_EW			EQU		$0E
FG_BLOCK_NS			EQU		$0F
FG_MOVEABLE_BLOCK	EQU		$10
FG_SPIKE_HIGH		EQU		$11
FG_SPIKE_BALL		EQU		$12
FG_SPIKE_BALL_FALLING	EQU	$13
FG_FIRE_EW			EQU		$14
FG_DROPPING_BLOCK	EQU		$15
FG_COLLAPSING_BLOCK	EQU		$16
FG_BALL_BOUNCE		EQU		$17
FG_BALL_UD			EQU		$18
FG_REPEL_SPELL		EQU		$19
FG_GATE_UD_1		EQU		$1A
FG_GATE_UD_2		EQU		$1B
FG_BALL_UD_X		EQU		$1C


; Run a routine with IX -> REC, as movers_step leaves it, and keep what came
; back: the registers in s_*, and IX in s_ix.
					MACRO	RUN routine
					ld		ix,REC
					call	routine
					ld		(s_ix),ix
					call	snap
					ENDM

; A field of the record under test, or of the legs after it.
					MACRO	EXPECT_FIELD field, value, what
					EXPECT_BYTE	REC + field, value, what
					ENDM

					MACRO	EXPECT_LEGS field, value, what
					EXPECT_BYTE	REC + ROOM_STRIDE + field, value, what
					ENDM

; Set a field of the record under test.
					MACRO	SET field, value
					ld		(ix+field),(value) & $FF
					ENDM


start:				ld		sp,$FE00

; --- mover_find --------------------------------------------------------------

					TEST	"find: a template that moves"
					call	fresh
					ld		de,$1234
					ld		a,FG_GHOST
					call	mover_find
					call	snap
					EXPECT_A	MOVE_GHOST, "the behaviour"
					EXPECT_WORD	s_de, $1234, "DE"

					TEST	"find: the last in the table"
					call	fresh
					ld		a,FG_SPIKE		; the entry before the $FF
					call	mover_find
					call	snap
					EXPECT_A	MOVE_STILL, "the behaviour"

					TEST	"find: one that does not move"
					call	fresh
					ld		a,FG_BLOCK
					call	mover_find
					call	snap
					EXPECT_A	MOVE_NONE, "the behaviour"

; --- mover_slide ---------------------------------------------------------------
; The wave is (move_tick + bit 5 of the record's address) folded into 0..15, and
; the block steps a unit towards it from (coordinate + 8) & 15.

					TEST	"slide U: below the wave, out along U"
					call	fresh
					ld		a,3
					ld		(move_tick),a		; REC's bit 5 is clear: the wave is 3
					SET		OBJ.U, 8		; (8 + 8) & 15 = 0
					SET		OBJ.DV, 5
					SET		OBJ.DZ, -4
					RUN		mover_slide_u
					EXPECT_FIELD	OBJ.DU, 1, "DU"
					EXPECT_FIELD	OBJ.DV, 0, "DV"
					EXPECT_BYTE	clamp_dz, 0, "DZ, held up against gravity"
					EXPECT_FIELD	OBJ.U, 9, "U"

					TEST	"slide U: on the wave, nothing to do"
					call	fresh
					ld		a,3
					ld		(move_tick),a
					SET		OBJ.U, 11		; (11 + 8) & 15 = 3
					RUN		mover_slide_u
					EXPECT_BYTE	clamp_calls, 0, "clamps"
					EXPECT_BYTE	reset_calls, 0, "region_reset"

					TEST	"slide V: above the wave, back along V"
					call	fresh
					ld		a,3
					ld		(move_tick),a
					SET		OBJ.V, 15		; (15 + 8) & 15 = 7
					RUN		mover_slide_v
					EXPECT_FIELD	OBJ.DU, 0, "DU"
					EXPECT_FIELD	OBJ.DV, -1 & $FF, "DV"
					EXPECT_FIELD	OBJ.V, 14, "V"

					TEST	"slide: the next record runs the other way"
					call	fresh
					ld		a,3
					ld		(move_tick),a		; bit 5 set: 3 + 16, the falling half: 12
					ld		ix,REC + ROOM_STRIDE
					ld		(mover_ix),ix
					SET		OBJ.U, 13		; (13 + 8) & 15 = 5
					call	mover_slide_u
					EXPECT_LEGS	OBJ.DU, 1, "DU at the next record"
					call	fresh
					ld		a,3
					ld		(move_tick),a
					SET		OBJ.U, 13
					RUN		mover_slide_u
					EXPECT_FIELD	OBJ.DU, -1 & $FF, "DU at this one"

; --- mover_pacer, the fires ---------------------------------------------------

; --- monster_gate --------------------------------------------------------------
; Where mover_tbl sends every behaviour from MOVE_FIRE_U to MOVE_SPIKE_BALL. In a
; quiet room it is a detour on the way to the monster's own mover; in a busy one
; it counts busy_count down and sits one monster out per turn -- see busy.s. The
; step is cleared when it does, because a ghost carries what is standing on it
; and a carried thing must not move without it.

					TEST	"gate: a quiet room goes straight on to the mover"
					call	fresh
					ld		ix,REC
					SET		OBJ.BEHAVIOUR, MOVE_FIRE_U
					SET		OBJ.MOVE_STATE, COLLIDE_U	; going forward, so the step is +1
					RUN		monster_gate
					EXPECT_FIELD	OBJ.DU, 1, "DU: mover_pacer_u ran"
					EXPECT_BYTE	busy_count, 0, "busy_count, untouched"

					TEST	"gate: a busy room sits the one that reaches nought out"
					call	fresh
					ld		a,4
					ld		(room_busy),a
					ld		a,1		; this one is its turn to sit out
					ld		(busy_count),a
					ld		ix,REC
					SET		OBJ.BEHAVIOUR, MOVE_FIRE_U
					SET		OBJ.DU, 7
					SET		OBJ.DV, 7
					RUN		monster_gate
					EXPECT_FIELD	OBJ.DU, 0, "DU: the step is cleared"
					EXPECT_FIELD	OBJ.DV, 0, "DV: and so is this one"
					EXPECT_BYTE	busy_count, 4, "busy_count, counting from room_busy again"

					TEST	"gate: a busy room lets the rest through"
					call	fresh
					ld		a,4
					ld		(room_busy),a
					ld		a,3		; not this one
					ld		(busy_count),a
					ld		ix,REC
					SET		OBJ.BEHAVIOUR, MOVE_FIRE_U
					SET		OBJ.MOVE_STATE, COLLIDE_U
					RUN		monster_gate
					EXPECT_FIELD	OBJ.DU, 1, "DU: mover_pacer_u ran anyway"
					EXPECT_BYTE	busy_count, 2, "busy_count, one nearer its turn"

					TEST	"fire U: one forward, flickering"
					call	fresh
					SET		OBJ.GFX, 87
					SET		OBJ.MOVE_STATE, COLLIDE_U
					SET		OBJ.DV, 7
					RUN		mover_pacer_u
					EXPECT_FIELD	OBJ.DU, 1, "DU"		; FIRE_STEP: one a turn, as the game moves one
					EXPECT_FIELD	OBJ.DV, 0, "DV"
					EXPECT_BYTE	clamp_dz, 0, "DZ, held up against gravity"
					EXPECT_FIELD	OBJ.GFX, 86, "the graphic"
					EXPECT_FIELD	OBJ.MOVE_STATE, COLLIDE_U, "MOVE_STATE"

					TEST	"fire U: back, and turns when stopped along U"
					call	fresh
					SET		OBJ.GFX, 86
					ld		a,COLLIDE_U | COLLIDE_Z
					ld		(stub_hit),a
					RUN		mover_pacer_u
					EXPECT_BYTE	clamp_de + 1, -1 & $FF, "D, the step clamped"
					EXPECT_FIELD	OBJ.GFX, 87, "the graphic"
					EXPECT_FIELD	OBJ.MOVE_STATE, COLLIDE_U, "MOVE_STATE, turned"

					TEST	"fire V: stopped along U does not turn it"
					call	fresh
					SET		OBJ.MOVE_STATE, COLLIDE_V
					ld		a,COLLIDE_U
					ld		(stub_hit),a
					RUN		mover_pacer_v
					EXPECT_FIELD	OBJ.DU, 0, "DU"
					EXPECT_FIELD	OBJ.DV, 1, "DV"
					EXPECT_FIELD	OBJ.MOVE_STATE, COLLIDE_V, "MOVE_STATE"

					TEST	"fire V: stopped along V turns it"
					call	fresh
					SET		OBJ.MOVE_STATE, COLLIDE_V | COLLIDE_U
					ld		a,COLLIDE_V
					ld		(stub_hit),a
					RUN		mover_pacer_v
					EXPECT_FIELD	OBJ.MOVE_STATE, COLLIDE_U, "MOVE_STATE, only V turned"

; --- mover_hopper_claim, the balls --------------------------------------------

					TEST	"ball: the first one sets the room's top"
					call	fresh
					SET		OBJ.Z, 128
					SET		OBJ.GFX, 178
					SET		OBJ.DU, 3
					SET		OBJ.DV, 3
					RUN		mover_hopper_claim
					EXPECT_BYTE	mover_ball_top, 128 + BALL_RISE_TO, "mover_ball_top"
					EXPECT_FIELD	OBJ.GFX, 179, "the graphic"
					EXPECT_WORD	clamp_de, 0, "the step clamped"

					TEST	"ball: the top is only set once"
					call	fresh
					ld		a,200
					ld		(mover_ball_top),a
					SET		OBJ.Z, 128
					RUN		mover_hopper_claim
					EXPECT_BYTE	mover_ball_top, 200, "mover_ball_top"

					TEST	"ball: falling, and nothing under it yet"
					call	fresh
					ld		a,200
					ld		(mover_ball_top),a
					SET		OBJ.DZ, -2
					RUN		mover_hopper_claim
					EXPECT_BYTE	clamp_dz, -3 & $FF, "DZ, gravity on top"
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE"

					TEST	"ball: lands and starts to rise"
					call	fresh
					ld		a,200
					ld		(mover_ball_top),a
					ld		a,COLLIDE_Z
					ld		(stub_hit),a
					RUN		mover_hopper_claim
					EXPECT_FIELD	OBJ.MOVE_STATE, MOVE_RISING, "MOVE_STATE"

					TEST	"ball: rises three, less gravity"
					call	fresh
					ld		a,200
					ld		(mover_ball_top),a
					SET		OBJ.Z, 128
					SET		OBJ.MOVE_STATE, MOVE_RISING | 1
					RUN		mover_hopper_claim
					EXPECT_BYTE	clamp_dz, BALL_RISE - 1, "DZ"
					EXPECT_FIELD	OBJ.Z, 128 + BALL_RISE - 1, "Z"
					EXPECT_FIELD	OBJ.MOVE_STATE, MOVE_RISING | 1, "MOVE_STATE"

					TEST	"ball: past the top, falls again"
					call	fresh
					ld		a,129
					ld		(mover_ball_top),a
					SET		OBJ.Z, 128
					SET		OBJ.MOVE_STATE, MOVE_RISING | 1
					RUN		mover_hopper_claim
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE, only RISING cleared"

; --- mover_guard_face ----------------------------------------------------------
; The torso shows its facing in bit 0 of its graphic, the legs in bit 3, and the
; carry into obj_pair_flip says mirrored.

					TEST	"face: +U"
					call	fresh
					call	guard_graphics
					SET		OBJ.DU, 2
					RUN		mover_guard_face
					EXPECT_FIELD	OBJ.GFX, 151, "the torso"
					EXPECT_LEGS	OBJ.GFX, 153, "the legs, the other block, a step on"
					EXPECT_BYTE	flip_carry, 0, "mirrored"
					EXPECT_WORD	flip_ix, REC, "the pair flipped"

					TEST	"face: -U"
					call	fresh
					call	guard_graphics
					SET		OBJ.DU, -2
					RUN		mover_guard_face
					EXPECT_FIELD	OBJ.GFX, 150, "the torso"
					EXPECT_LEGS	OBJ.GFX, 145, "the legs"
					EXPECT_BYTE	flip_carry, 0, "mirrored"

					TEST	"face: -V"
					call	fresh
					call	guard_graphics
					SET		OBJ.DV, -2
					RUN		mover_guard_face
					EXPECT_FIELD	OBJ.GFX, 151, "the torso"
					EXPECT_LEGS	OBJ.GFX, 153, "the legs, the other block"
					EXPECT_BYTE	flip_carry, 1, "mirrored"

					TEST	"face: +V"
					call	fresh
					call	guard_graphics
					SET		OBJ.DV, 2
					RUN		mover_guard_face
					EXPECT_FIELD	OBJ.GFX, 150, "the torso"
					EXPECT_LEGS	OBJ.GFX, 145, "the legs"
					EXPECT_BYTE	flip_carry, 1, "mirrored"

					TEST	"face: the walk cycle wraps after five"
					call	fresh
					SET		OBJ.GFX, 150
					ld		a,152 + 5
					ld		(REC + ROOM_STRIDE + OBJ.GFX),a
					SET		OBJ.DU, -2
					RUN		mover_guard_face
					EXPECT_LEGS	OBJ.GFX, 144, "the legs, back to 0 and this block"

					TEST	"face: standing still changes nothing"
					call	fresh
					call	guard_graphics
					RUN		mover_guard_face
					EXPECT_FIELD	OBJ.GFX, 150, "the torso"
					EXPECT_LEGS	OBJ.GFX, 144, "the legs"
					EXPECT_BYTE	flip_calls, 0, "flips"

; --- mover_guard_u, mover_guard_sq ---------------------------------------------

					TEST	"guard U: forward, the legs sorted, then the torso"
					call	fresh
					call	guard_graphics
					call	guard_at_100
					SET		OBJ.MOVE_STATE, 1
					SET		OBJ.DV, 9
					SET		OBJ.DZ, 9
					RUN		mover_guard_u
					EXPECT_BYTE	clamp_de + 1, GUARD_STEP, "D, the step along U"
					EXPECT_BYTE	clamp_dz, -1 & $FF, "DZ: it falls"
					EXPECT_LEGS	OBJ.U, 102, "the legs' U"
					EXPECT_LEGS	OBJ.V, 50, "the legs' V"
					EXPECT_BYTE	relink_calls, 1, "legs re-sorted"
					EXPECT_WORD	relink_ix, REC + ROOM_STRIDE, "...the legs"
					EXPECT_BYTE	upper_calls, 1, "torso re-sorted"
					EXPECT_WORD	upper_hl, REC + ROOM_STRIDE, "...after the legs"
					EXPECT_WORD	upper_de, $0200, "...by the step"
					EXPECT_FIELD	OBJ.U, 102, "the torso's U"
					EXPECT_BYTE	place_calls, 2, "both placed"
					EXPECT_BYTE	add_calls, 4, "region_add, both before and after"
					EXPECT_BYTE	defer_calls, 1, "one redraw"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE"
					EXPECT_WORD	s_ix, REC, "IX"

					TEST	"guard U: back, and turns when stopped along U"
					call	fresh
					call	guard_graphics
					call	guard_at_100
					ld		a,COLLIDE_U
					ld		(stub_hit),a
					RUN		mover_guard_u
					EXPECT_BYTE	clamp_de + 1, -2 & $FF, "D, the step along U"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE, turned"

					TEST	"square: north, and on to east when stopped along V"
					call	fresh
					call	guard_graphics
					call	guard_at_100
					SET		OBJ.MOVE_STATE, 1
					ld		a,COLLIDE_V
					ld		(stub_hit),a
					RUN		mover_guard_sq
					EXPECT_WORD	clamp_de, GUARD_STEP, "the step: north"
					EXPECT_FIELD	OBJ.MOVE_STATE, 2, "MOVE_STATE"

					TEST	"square: south, stopped along U, keeps going"
					call	fresh
					call	guard_graphics
					call	guard_at_100
					SET		OBJ.MOVE_STATE, 3
					ld		a,COLLIDE_U
					ld		(stub_hit),a
					RUN		mover_guard_sq
					EXPECT_WORD	clamp_de, -GUARD_STEP & $FF, "the step: south"
					EXPECT_FIELD	OBJ.MOVE_STATE, 3, "MOVE_STATE"

					TEST	"square: west wraps round from south"
					call	fresh
					call	guard_graphics
					call	guard_at_100
					SET		OBJ.MOVE_STATE, 3
					ld		a,COLLIDE_V
					ld		(stub_hit),a
					RUN		mover_guard_sq
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE"
					call	fresh
					call	guard_graphics
					call	guard_at_100
					RUN		mover_guard_sq
					EXPECT_WORD	clamp_de, (-GUARD_STEP & $FF) << 8, "the step: west"

; --- mover_gate ------------------------------------------------------------------

					TEST	"gate: still, while another has the room"
					call	fresh
					ld		a,1
					ld		(mover_gate_busy),a
					SET		OBJ.GFX, 8
					RUN		mover_gate
					EXPECT_BYTE	clamp_calls, 0, "clamps"
					EXPECT_FIELD	OBJ.GFX, 8, "the graphic"

					TEST	"gate: rising a unit a turn"
					call	fresh
					ld		a,128
					ld		(room_floor_z),a
					SET		OBJ.GFX, 9
					SET		OBJ.Z, 140
					SET		OBJ.DZ, 1
					SET		OBJ.DU, 4
					RUN		mover_gate
					EXPECT_BYTE	clamp_dz, 1, "DZ"
					EXPECT_WORD	clamp_de, 0, "the step along the floor"
					EXPECT_FIELD	OBJ.Z, 141, "Z"
					EXPECT_FIELD	OBJ.GFX, 9, "the graphic"

					TEST	"gate: up to the top, stops"
					call	fresh
					ld		a,128
					ld		(room_floor_z),a
					ld		a,1
					ld		(mover_gate_busy),a
					SET		OBJ.GFX, 9
					SET		OBJ.Z, 128 + GATE_RISE
					SET		OBJ.DZ, 1
					RUN		mover_gate
					EXPECT_FIELD	OBJ.GFX, 8, "the graphic"
					EXPECT_BYTE	mover_gate_busy, 0, "mover_gate_busy"

					TEST	"gate: one short of the top, keeps going"
					call	fresh
					ld		a,128
					ld		(room_floor_z),a
					ld		a,1
					ld		(mover_gate_busy),a
					SET		OBJ.GFX, 9
					SET		OBJ.Z, 128 + GATE_RISE - 1
					SET		OBJ.DZ, 1
					RUN		mover_gate
					EXPECT_FIELD	OBJ.GFX, 9, "the graphic"
					EXPECT_BYTE	mover_gate_busy, 1, "mover_gate_busy"

					TEST	"gate: falling gathers pace, and stops on landing"
					call	fresh
					ld		a,1
					ld		(mover_gate_busy),a
					SET		OBJ.GFX, 9
					SET		OBJ.DZ, -1
					ld		a,COLLIDE_Z
					ld		(stub_hit),a
					RUN		mover_gate
					EXPECT_BYTE	clamp_dz, -3 & $FF, "DZ, two more"
					EXPECT_FIELD	OBJ.GFX, 8, "the graphic"
					EXPECT_BYTE	mover_gate_busy, 0, "mover_gate_busy"

					TEST	"gate: falling, not landed yet"
					call	fresh
					ld		a,1
					ld		(mover_gate_busy),a
					SET		OBJ.GFX, 9
					SET		OBJ.DZ, -3
					RUN		mover_gate
					EXPECT_FIELD	OBJ.GFX, 9, "the graphic"
					EXPECT_BYTE	mover_gate_busy, 1, "mover_gate_busy"

; --- the loose ones ----------------------------------------------------------------

					TEST	"carried: its step goes before it moves"
					call	fresh
					SET		OBJ.DU, 3
					SET		OBJ.DV, 3
					RUN		mover_falls_noisy
					EXPECT_WORD	clamp_de, 0, "the step clamped"
					EXPECT_BYTE	clamp_dz, -1 & $FF, "DZ, gravity"

					TEST	"pushed: moves by its step, then loses it"
					call	fresh
					SET		OBJ.DU, 3
					SET		OBJ.DV, -1
					RUN		mover_pushed
					EXPECT_WORD	clamp_de, $03FF, "the step clamped"
					EXPECT_FIELD	OBJ.DU, 0, "DU after"
					EXPECT_FIELD	OBJ.DV, 0, "DV after"

					TEST	"sliding: keeps its step"
					call	fresh
					SET		OBJ.DU, 3
					RUN		mover_sliding
					EXPECT_WORD	clamp_de, $0300, "the step clamped"
					EXPECT_FIELD	OBJ.DU, 3, "DU after"

; --- mover_ghost -----------------------------------------------------------------

					TEST	"ghost: keeps going while nothing stops it"
					call	fresh
					SET		OBJ.GFX, 82
					SET		OBJ.DU, 3
					ld		a,COLLIDE_Z
					ld		(stub_hit),a
					RUN		mover_ghost
					EXPECT_WORD	clamp_de, $0300, "the step clamped"
					EXPECT_FIELD	OBJ.GFX, 82, "the graphic"
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE"

					TEST	"ghost: stopped last turn, a new way to go"
					call	fresh
					SET		OBJ.GFX, 82
					SET		OBJ.DU, 3
					SET		OBJ.MOVE_STATE, COLLIDE_U
					ld		a,COLLIDE_V | COLLIDE_Z
					ld		(stub_hit),a
					RUN		mover_ghost
					ld		a,(REC + OBJ.DU)
					call	ghost_speed
					call	snap
					EXPECT_A	1, "DU is a ghost's speed"
					ld		a,(REC + OBJ.DV)
					call	ghost_speed
					call	snap
					EXPECT_A	1, "DV is a ghost's speed"
					ld		a,(REC + OBJ.GFX)
					call	ghost_frame
					call	snap
					EXPECT_A	1, "the graphic is one of its four"
					EXPECT_FIELD	OBJ.MOVE_STATE, COLLIDE_V, "MOVE_STATE, what stopped it"

					TEST	"ghost: no step at all, a new way to go"
					call	fresh
					SET		OBJ.GFX, 83
					RUN		mover_ghost
					ld		a,(REC + OBJ.DU)
					call	ghost_speed
					call	snap
					EXPECT_A	1, "DU is a ghost's speed"
					ld		a,(REC + OBJ.GFX)
					call	ghost_frame
					call	snap
					EXPECT_A	1, "the graphic is one of its four"

; Which way it faces -- calc_ghost_sprite. The wider step picks the axis: along
; U it is mirrored, and the sign picks the pair, the other way round on V.

					TEST	"ghost face: along +U, the low pair, mirrored"
					call	fresh
					SET		OBJ.GFX, 83
					SET		OBJ.FLAGS, 0
					SET		OBJ.DU, 4
					SET		OBJ.DV, -3
					RUN		mover_ghost.face
					EXPECT_FIELD	OBJ.GFX, 81, "the graphic"
					EXPECT_FIELD	OBJ.FLAGS, 1, "mirrored"

					TEST	"ghost face: along -U, the high pair, mirrored"
					call	fresh
					SET		OBJ.GFX, 80
					SET		OBJ.FLAGS, 0
					SET		OBJ.DU, -4
					SET		OBJ.DV, 3
					RUN		mover_ghost.face
					EXPECT_FIELD	OBJ.GFX, 82, "the graphic"
					EXPECT_FIELD	OBJ.FLAGS, 1, "mirrored"

					TEST	"ghost face: along +V, the high pair, not mirrored"
					call	fresh
					SET		OBJ.GFX, 80
					SET		OBJ.FLAGS, 1
					SET		OBJ.DU, -3
					SET		OBJ.DV, 4
					RUN		mover_ghost.face
					EXPECT_FIELD	OBJ.GFX, 82, "the graphic"
					EXPECT_FIELD	OBJ.FLAGS, 0, "not mirrored"

					TEST	"ghost face: along -V, the low pair, not mirrored"
					call	fresh
					SET		OBJ.GFX, 83
					SET		OBJ.FLAGS, 1
					SET		OBJ.DU, 3
					SET		OBJ.DV, -4
					RUN		mover_ghost.face
					EXPECT_FIELD	OBJ.GFX, 81, "the graphic"
					EXPECT_FIELD	OBJ.FLAGS, 0, "not mirrored"

; --- mover_bounce ------------------------------------------------------------------

					TEST	"bounce: in the air, keeps its step"
					call	fresh
					SET		OBJ.GFX, 182
					SET		OBJ.DU, 2
					SET		OBJ.DV, -2
					ld		a,1
					ld		(stub_block),a
					RUN		mover_bounce
					EXPECT_FIELD	OBJ.DU, 2, "DU"
					EXPECT_FIELD	OBJ.DV, -2 & $FF, "DV"
					EXPECT_FIELD	OBJ.GFX, 182, "the graphic"

					TEST	"bounce: lands, and runs from the knight"
					call	fresh
					call	ball_beside_player
					ld		a,16		; the knight's legs
					ld		(player + OBJ.GFX),a
					RUN		mover_bounce
					EXPECT_FIELD	OBJ.DZ, BOUNCE_RISE, "DZ"
					EXPECT_FIELD	OBJ.GFX, 183, "the graphic"
					call	one_axis
					EXPECT_A	BOUNCE_STEP, "one axis, away from him"

					TEST	"bounce: lands, and comes for the werewolf"
					call	fresh
					call	ball_beside_player
					ld		a,48		; the werewolf's legs
					ld		(player + OBJ.GFX),a
					RUN		mover_bounce
					call	one_axis
					EXPECT_A	-BOUNCE_STEP & $FF, "one axis, towards him"

; --- mover_spell -------------------------------------------------------------------

					TEST	"spell: homes in at four"
					call	fresh
					call	spell_near_player
					SET		OBJ.GFX, 164
					RUN		mover_spell
					EXPECT_FIELD	OBJ.DU, SPELL_STEP, "DU"
					EXPECT_FIELD	OBJ.DV, -SPELL_STEP & $FF, "DV"
					EXPECT_FIELD	OBJ.GFX, 165, "the graphic"

					TEST	"spell: creeps while he is in an arch"
					call	fresh
					call	spell_near_player
					ld		a,1
					ld		(player + CHARACTER_DOOR),a
					SET		OBJ.GFX, 167
					RUN		mover_spell
					EXPECT_FIELD	OBJ.DU, SPELL_CREEP, "DU"
					EXPECT_FIELD	OBJ.DV, -SPELL_CREEP & $FF, "DV"
					EXPECT_FIELD	OBJ.GFX, 164, "the graphic, round to the first"

					TEST	"spell: never creeps in the wizard's room"
					call	fresh
					call	spell_near_player
					ld		a,1
					ld		(player + CHARACTER_DOOR),a
					ld		a,$88
					ld		(room_shown),a
					RUN		mover_spell
					EXPECT_FIELD	OBJ.DU, SPELL_STEP, "DU"

					TEST	"spell: level with him counts as past"
					call	fresh
					call	spell_near_player
					SET		OBJ.U, 100
					RUN		mover_spell
					EXPECT_FIELD	OBJ.DU, -SPELL_STEP & $FF, "DU"

; --- mover_spike_ball ------------------------------------------------------------

					TEST	"spike ball: the room holds it"
					call	fresh
					ld		a,1
					ld		(spike_ball_held),a
					SET		OBJ.MOVE_STATE, 4
					RUN		mover_spike_ball
					EXPECT_BYTE	clamp_calls, 0, "clamps"

					TEST	"spike ball: another is falling"
					call	fresh
					ld		a,1
					ld		(spike_ball_falling),a
					RUN		mover_spike_ball
					EXPECT_BYTE	clamp_calls, 0, "clamps"
					EXPECT_FIELD	OBJ.MOVE_STATE, 0, "MOVE_STATE"

					TEST	"spike ball: falling, not landed"
					call	fresh
					ld		a,1
					ld		(spike_ball_falling),a
					SET		OBJ.MOVE_STATE, 4
					SET		OBJ.DZ, -3
					RUN		mover_spike_ball
					EXPECT_BYTE	clamp_dz, -4 & $FF, "DZ"
					EXPECT_FIELD	OBJ.MOVE_STATE, 4, "MOVE_STATE"
					EXPECT_BYTE	spike_ball_falling, 1, "spike_ball_falling"

					TEST	"spike ball: lands, and lets the next one go"
					call	fresh
					ld		a,1
					ld		(spike_ball_falling),a
					SET		OBJ.MOVE_STATE, 4 | 1
					ld		a,COLLIDE_Z
					ld		(stub_hit),a
					RUN		mover_spike_ball
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE"
					EXPECT_BYTE	spike_ball_falling, 0, "spike_ball_falling"

; --- mover_sinks, mover_collapsing -----------------------------------------------

					TEST	"dropping: nothing on it, nothing"
					call	fresh
					RUN		mover_sinks
					EXPECT_BYTE	clamp_calls, 0, "clamps"

					TEST	"dropping: landed on, sinks a unit"
					call	fresh
					SET		OBJ.MOVE_STATE, 8 | 1
					SET		OBJ.DZ, 5
					RUN		mover_sinks
					EXPECT_BYTE	clamp_dz, -1 & $FF, "DZ"
					EXPECT_FIELD	OBJ.MOVE_STATE, 1, "MOVE_STATE, the mark taken"
					EXPECT_BYTE	step_calls, 1, "depth_step"

					TEST	"collapsing: nothing on it, nothing"
					call	fresh
					RUN		mover_collapsing
					EXPECT_BYTE	reset_calls, 0, "region_reset"
					EXPECT_BYTE	hide_calls, 0, "object_hide"

					TEST	"collapsing: landed on, crumbles"
					call	fresh
					SET		OBJ.MOVE_STATE, 8
					SET		OBJ.GFX, 143
					SET		OBJ.DU, 1
					SET		OBJ.DV, 1
					SET		OBJ.DZ, 1
					RUN		mover_collapsing
					EXPECT_FIELD	OBJ.MOVE_STATE, $10, "MOVE_STATE"
					EXPECT_FIELD	OBJ.GFX, 185, "the graphic"
					EXPECT_WORD	step_de, 0, "the step sorted by"
					EXPECT_BYTE	step_a, 0, "...and in Z"
					EXPECT_BYTE	clamp_calls, 0, "clamps"
					EXPECT_BYTE	defer_calls, 1, "redraw_defer"

					TEST	"collapsing: crumbled last turn, gone"
					call	fresh
					SET		OBJ.MOVE_STATE, $10
					RUN		mover_collapsing
					EXPECT_BYTE	hide_calls, 1, "object_hide"
					EXPECT_WORD	hide_ix, REC, "...of it"

					call	finish
					DB		"movers_tests (knightlore)", 0


; ---------------------------------------------------------------------------
; Fixtures.

; A clean record and legs, a clean knight, the stubs zeroed, mover.s's own
; state zeroed, and mover_ix -> REC.
fresh:				ld		hl,REC
					ld		bc,2 * ROOM_STRIDE
					call	zero
					ld		hl,player
					ld		bc,PLAYER_SIZE
					call	zero
					ld		hl,stubs
					ld		bc,STUBS_SIZE
					call	zero
					ld		a,$FF
					ld		(player + CHARACTER_DOOR),a
					xor		a
					ld		(move_tick),a
					ld		(mover_ball_top),a
					ld		(spike_ball_falling),a
					ld		(spike_ball_held),a
					ld		(mover_gate_busy),a
					ld		(mover_gate_drops),a
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

; A guard's torso and legs, facing -U, legs at phase 0.
guard_graphics:		ld		a,150
					ld		(REC + OBJ.GFX),a
					ld		a,144
					ld		(REC + ROOM_STRIDE + OBJ.GFX),a
					ret

; Both halves standing at U 100, V 50.
guard_at_100:		ld		a,100
					ld		(REC + OBJ.U),a
					ld		(REC + ROOM_STRIDE + OBJ.U),a
					ld		a,50
					ld		(REC + OBJ.V),a
					ld		(REC + ROOM_STRIDE + OBJ.V),a
					ret

; The hunting ball at U 110, V 110, landing, with the knight at 100, 100: so
; away from him is +2 on either axis, and towards him -2.
ball_beside_player:	ld		a,100
					ld		(player + OBJ.U),a
					ld		(player + OBJ.V),a
					ld		a,110
					ld		(REC + OBJ.U),a
					ld		(REC + OBJ.V),a
					ld		a,182
					ld		(REC + OBJ.GFX),a
					ld		a,COLLIDE_Z
					ld		(stub_hit),a
					ret

; The spell at U 90, V 110, the knight at 100, 100, in no doorway.
spell_near_player:	ld		a,100
					ld		(player + OBJ.U),a
					ld		(player + OBJ.V),a
					ld		a,90
					ld		(REC + OBJ.U),a
					ld		a,110
					ld		(REC + OBJ.V),a
					ld		a,$10
					ld		(room_shown),a
					ret

; A = 1 if A is one of a ghost's four speeds, 0 if not.
; A ghost's graphic: A = 1 if it is one of its four frames, else 0.
ghost_frame:		sub		80
					cp		4
					ld		a,0
					ret		nc
					inc		a
					ret


ghost_speed:		ld		hl,.speeds
					ld		bc,4
					cpir
					ld		a,0
					ret		nz
					inc		a
					ret
.speeds:			DB		-3 & $FF, 3, -4 & $FF, 4

; The hunting ball's step: A = the one axis that has one, or $EE if both or
; neither do.
one_axis:			ld		a,(REC + OBJ.DU)
					ld		b,a
					ld		a,(REC + OBJ.DV)
					ld		c,a
					or		b
					jr		z,.wrong
					ld		a,b
					and		a
					jr		z,.v
					ld		a,c
					and		a
					jr		nz,.wrong
					ld		a,b
					jr		.out
.v:					ld		a,c
					jr		.out
.wrong:				ld		a,$EE
.out:				ld		(s_af + 1),a
					ret


; ---------------------------------------------------------------------------
; The engine and the game around movers.s.

PLAYER_SIZE			EQU		3 * ROOM_STRIDE
player:				DS		PLAYER_SIZE
walker_player		EQU		player

stubs:
collide_hit:		DB		0
collide_other:		DW		0
room_floor_z:		DB		0
room_shown:			DB		0
room_object_count:	DB		0

; busy.s's, for monster_gate. Zeroed by fresh like the rest of this block, so
; a monster's turn is never sat out and the gate always reaches its mover.
room_busy:			DB		0
busy_count:			DB		0

stub_hit:			DB		0		; what the clamp says gave
stub_block:			DB		0		; non-zero: the clamp takes the whole step

clamp_calls:		DB		0
clamp_ix:			DW		0
clamp_de:			DW		0		; D, E as the clamp was handed them
clamp_flags:		DB		0		; FLAGS during the clamp
clamp_dz:			DB		0		; DZ as the clamp saw it, gravity taken
step_calls:			DB		0
step_de:			DW		0
step_a:				DB		0
relink_calls:		DB		0
relink_ix:			DW		0
upper_calls:		DB		0
upper_hl:			DW		0
upper_de:			DW		0
reset_calls:		DB		0
add_calls:			DB		0
place_calls:		DB		0
defer_calls:		DB		0
flip_calls:			DB		0
flip_carry:			DB		0
flip_ix:			DW		0
hide_calls:			DB		0
hide_ix:			DW		0
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

depth_relink:		ld		(relink_ix),ix
					ld		hl,relink_calls
					inc		(hl)
					ret

region_reset:		ld		hl,reset_calls
					inc		(hl)
					ret

region_add:			ld		hl,add_calls
					inc		(hl)
					ret

room_adjust:		ret

; As character.s has it: both records of a pair, IX kept.
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

obj_pair_flip:		ld		a,0
					rla
					ld		(flip_carry),a
					ld		(flip_ix),ix
					ld		hl,flip_calls
					inc		(hl)
					ret

; engine/movers.s's object_hide is the real one; this is what it unlinks with,
; which is where a hide is counted.
depth_unlink:		ld		(hide_ix),ix
					ld		hl,hide_calls
					inc		(hl)
					ret

redraw_view:		ret

mover_cauldron:		ret
mover_special:		ret

; character.s's, which the ghost's facing borrows: A, made positive.
character_door_find:
.abs:				or		a
					ret		p
					neg
					ret


; Silent: what the sounds play is not what these tests are about.
sound_u:
sound_v:
sound_z:
sound_uvz:
sound_chirp:
sound_step:
sound_bounce:
sound_gate:
sound_take:
sound_sparkle:
pacer_sound:
mover_turned:		ret		; sound_fx.s's, which only choose a sound


					INCLUDE	"../monster_gate.s"
					INCLUDE	"../movers.s"
					INCLUDE	"../../engine/mover.s"
					INCLUDE	"../shared_movers.s"
					INCLUDE	"../../engine/movers.s"
