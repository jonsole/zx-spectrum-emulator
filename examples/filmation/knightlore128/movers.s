; ---------------------------------------------------------------------------
; The things in a room that move.
;
; Knight Lore gives every object an update routine and dispatches on its
; GRAPHIC: jump_to_upd_object at $B25C takes byte 0 of the record and indexes
; upd_sprite_jmp_tbl with it. That works there because a graphic number is a
; type -- the four arch leaves are 2 to 5, the sliding blocks 54 and 55 -- and
; it costs 512 bytes of addresses, most of them saying nothing happens.
;
; We dispatch on the TEMPLATE instead. Our rooms are built from templates and
; the template is what carries the behaviour, so the answer is worked out once
; when the room is built and kept in the record. Two graphics that look the
; same but behave differently are then two templates rather than a problem --
; which is just as well, because ball_ud_y and ball_ud_xy are both graphic 178.
; ---------------------------------------------------------------------------

MOVE_NONE			EQU		0

; The ones that kill, first, so that one compare says whether a thing is
; deadly -- see object_touched. Knight Lore marks them with a flag it sets from
; each object's own update routine, set_both_deadly_flags at $B85C: gargoyles,
; spikes, spiked balls, bouncing balls of both kinds, fires, guards, the wizard
; and the ghost. Not the repel spell or the cauldron's bubbles.
;
; MOVE_STILL is deadly and does nothing else. Spikes and gargoyles have no
; update of their own beyond the flag, and movers_step steps straight over it.
MOVE_STILL		EQU		1
MOVE_BALL			EQU		2		; the first that has a turn -- movers_step
MOVE_FIRE_U		EQU		3
MOVE_FIRE_V		EQU		4
MOVE_GUARD_U		EQU		5
MOVE_GUARD_SQ	EQU		6
MOVE_GHOST		EQU		7
MOVE_BOUNCE		EQU		8
MOVE_SPIKE_BALL	EQU		9
; Pentagram's monsters, which go through monster_gate as Knight Lore's do: the
; spider (engine/movers.s's mover_scuttler, $CF22), the creature (mover_roamer,
; $D1F5) and the dragon's heads that pace (mover_pacer_u and _v, $CEA0).
MOVE_SPIDER		EQU		10
MOVE_CREATURE		EQU		11
MOVE_DRAGON_U		EQU		12
MOVE_DRAGON_V		EQU		13
MOVE_MONSTER_LAST	EQU		13		; monster_gate's range ends here
; ...and the dragon's head that bobs, which Pentagram does not count as a
; monster: engine/movers.s's mover_hopper, $CE31. See mover_dragon_hops.
MOVE_DRAGON_HOPS	EQU		14

; The gates only kill what they come down on. upd_9 sets bit 7 of $0D alone --
; "fatal if it hits the player" -- and not bit 5, "fatal if he hits it", so the
; clamp at $CBAF only passes it on when the gate is the one moving. Walking into
; a gate is safe; standing under one as it drops is not.
MOVE_CRUSHING	EQU		15
MOVE_GATE			EQU		15

MOVE_HARMLESS	EQU		16		; and from here on, nothing kills
MOVE_SLIDE_U		EQU		16
MOVE_SLIDE_V		EQU		17
MOVE_SPELL		EQU		18
MOVE_CAULDRON	EQU		19		; what rises out of the pot -- see special.s
; Pentagram's things that move and do no harm: the platforms that pace (the
; same mover_pacer_u and _v as the fires and the dragons, $CEA3), the lift
; ($CDBB), the conveyors ($B866), the block that drops and cannot be pushed
; ($CD75) and the one that cracks under him and goes ($D2AD).
MOVE_PLATFORM_U	EQU		20
MOVE_PLATFORM_V	EQU		21
MOVE_LIFT			EQU		22
MOVE_CONVEYOR		EQU		23
MOVE_FALLS		EQU		24
MOVE_CRUMBLES		EQU		25
MOVE_DROPPING	EQU		26		; these two give way under a weight: see
MOVE_COLLAPSING	EQU		27		; object_landed_on, which relies on the order.
									; Pentagram's block that sinks is the first

; Everything from here up is loose: it can be carried by whatever it is
; standing on and shoved by whatever runs into it. The game says the same
; thing with one flag, bit 2 of an object's own byte, which sits on the
; moveable block, the chest, the table and the knight alike. The three
; differ only in WHEN they let go of the step they were given:
;
;   MOVE_CARRIED   clears it before moving, so it only ever goes where
;                  something took it this turn -- upd_62
;   MOVE_PUSHED    clears it after, so a shove moves it once -- upd_84
;   MOVE_SLIDING   never clears it, so a shove sends it on until
;                  something stops it -- upd_85
;
; MOVE_LOOSE has to stay the LAST of these and everything loose above it,
; because that is the whole test -- object_carry and object_shove both ask
; whether a behaviour is at or past it. Putting the hunting ball above it by
; accident made the ball itself carriable and shoveable, and it spent its
; time being flung about by whatever it touched.
MOVE_LOOSE		EQU		28
MOVE_CARRIED		EQU		28
MOVE_PUSHED		EQU		29
MOVE_SLIDING		EQU		30
MOVE_SPECIAL		EQU		31		; a collectable -- see special.s
; Pentagram's stumps, cubes, tables and stones: shoved, and taking whatever is
; piled on them along -- engine/movers.s's mover_shoved_pile, $CD81. Its
; thorny bush is shoved the same way there AND kills, but a behaviour here is
; either loose or deadly -- the loose band runs to the top and the deadly one
; ends where the harmless one starts -- so here the bush is deadly and stays
; where it grew.
MOVE_PUSHED_PILE	EQU		32

; What the engine's contact rules need to know about these numbers. It never
; names a behaviour, only the bands above -- see engine/object.s.
BEHAVIOUR_FIRST_TURN	EQU		MOVE_BALL		; the first with a turn, and mover_tbl's first
BEHAVIOUR_DEADLY	EQU		MOVE_STILL		; the first that kills
BEHAVIOUR_CRUSHING	EQU		MOVE_CRUSHING	; the first that kills only when it moves
BEHAVIOUR_HARMLESS	EQU		MOVE_HARMLESS	; the first that does not
BEHAVIOUR_GIVES		EQU		MOVE_DROPPING	; the first that gives way under a weight
BEHAVIOUR_GIVES_LAST	EQU		MOVE_COLLAPSING	; and the last
BEHAVIOUR_LOOSE		EQU		MOVE_LOOSE		; this and everything above: carried and shoved

; Bits of OBJ.MOVE_STATE. The direction bits are numbered by axis, so that the
; same mask both says which way a thing is going and tests collide_hit for
; whether it just ran into something -- which is how the game numbers them.
MOVE_RISING		EQU		4		; bit 2, as in the game's byte $0D

; How fast each of them goes, and how high a ball bounces.
; The game moves a fire two a frame at about fifteen frames a second; the
; remake takes a turn at up to thirty-five, so two a turn crossed a room twice
; as fast. One a turn is the game's speed again.
FIRE_STEP			EQU		1
BALL_RISE			EQU		3		; before gravity takes one back
BALL_RISE_TO		EQU		32
SPELL_STEP		EQU		4
SPELL_CREEP		EQU		1		; while the knight is in an arch


; Which templates move, and how. Room-build time only, so a walk will do.
; Ends with $FF, which is not a template.
mover_of:			DB		FG_BLOCK_EW, MOVE_SLIDE_U
					DB		FG_BLOCK_NS, MOVE_SLIDE_V
					DB		FG_FIRE_EW, MOVE_FIRE_U
					DB		FG_FIRE_NS, MOVE_FIRE_V
					; All four of these are graphic 178 and all four bounce. They are
					; four templates because of where they SIT, not what they do: the
					; names are about which axes get a half-cell offset, and the last
					; byte of each is $00, $01, $02 or $03 accordingly.
					DB		FG_BALL_UD, MOVE_BALL
					DB		FG_BALL_UD_X, MOVE_BALL
					DB		FG_BALL_UD_Y, MOVE_BALL
					DB		FG_BALL_UD_XY, MOVE_BALL
					DB		FG_GUARD_EW, MOVE_GUARD_U
					DB		FG_GUARD_SQUARE, MOVE_GUARD_SQ
					DB		FG_GATE_UD_1, MOVE_GATE
					DB		FG_GATE_UD_2, MOVE_GATE
					DB		FG_MOVEABLE_BLOCK, MOVE_CARRIED
					DB		FG_GHOST, MOVE_GHOST
					DB		FG_TABLE, MOVE_PUSHED
					DB		FG_CHEST, MOVE_SLIDING
					DB		FG_BALL_BOUNCE, MOVE_BOUNCE
					DB		FG_REPEL_SPELL, MOVE_SPELL
					DB		FG_SPIKE_BALL, MOVE_SPIKE_BALL
					DB		FG_SPIKE_BALL_FALLING, MOVE_SPIKE_BALL
					DB		FG_DROPPING_BLOCK, MOVE_DROPPING
					DB		FG_COLLAPSING_BLOCK, MOVE_COLLAPSING
					DB		FG_GARGOYLE, MOVE_STILL
					DB		FG_SPIKE, MOVE_STILL
					; Pentagram's, as its own movers.s's mover_of has them.
					DB		FG_PENTAGRAM_GRASS, MOVE_STILL
					DB		FG_PENTAGRAM_THORNS, MOVE_STILL
					DB		FG_PENTAGRAM_WATER, MOVE_STILL
					DB		FG_PENTAGRAM_WATER_DEEP, MOVE_STILL
					DB		FG_PENTAGRAM_THORNY_BUSH, MOVE_STILL	; see MOVE_PUSHED_PILE
					DB		FG_PENTAGRAM_SPIDER, MOVE_SPIDER
					DB		FG_PENTAGRAM_CREATURE, MOVE_CREATURE
					DB		FG_PENTAGRAM_DRAGON_PACES_U, MOVE_DRAGON_U
					DB		FG_PENTAGRAM_DRAGON_PACES_V, MOVE_DRAGON_V
					DB		FG_PENTAGRAM_DRAGON_HOPS, MOVE_DRAGON_HOPS
					DB		FG_PENTAGRAM_PLATFORM_U, MOVE_PLATFORM_U
					DB		FG_PENTAGRAM_PLATFORM_V, MOVE_PLATFORM_V
					DB		FG_PENTAGRAM_LIFT, MOVE_LIFT
					DB		FG_PENTAGRAM_CONVEYOR_1, MOVE_CONVEYOR
					DB		FG_PENTAGRAM_CONVEYOR_3, MOVE_CONVEYOR
					DB		FG_PENTAGRAM_CONVEYOR_4, MOVE_CONVEYOR
					DB		FG_PENTAGRAM_BLOCK_FALLS, MOVE_FALLS
					DB		FG_PENTAGRAM_BLOCK_CRUMBLES, MOVE_CRUMBLES
					DB		FG_PENTAGRAM_BLOCK_SINKS, MOVE_DROPPING
					DB		FG_PENTAGRAM_STUMP_PUSHED, MOVE_PUSHED_PILE
					DB		FG_PENTAGRAM_CUBE_PUSHED, MOVE_PUSHED_PILE
					DB		FG_PENTAGRAM_TABLE_PUSHED, MOVE_PUSHED_PILE
					DB		FG_PENTAGRAM_STONE_PUSHED, MOVE_PUSHED_PILE
					DB		$FF

; The monsters, MOVE_FIRE_U to MOVE_SPIKE_BALL, go through monster_gate, which
; sits them out by turns in a busy room -- see busy.s -- and otherwise goes on
; to their own movers.
mover_tbl:			DW		mover_hopper_claim	; MOVE_BALL: engine/movers.s
					DW		monster_gate		; MOVE_FIRE_U
					DW		monster_gate		; MOVE_FIRE_V
					DW		monster_gate		; MOVE_GUARD_U
					DW		monster_gate		; MOVE_GUARD_SQ
					DW		monster_gate		; MOVE_GHOST
					DW		monster_gate		; MOVE_BOUNCE
					DW		monster_gate		; MOVE_SPIKE_BALL
					DW		monster_gate		; MOVE_SPIDER
					DW		monster_gate		; MOVE_CREATURE
					DW		monster_gate		; MOVE_DRAGON_U
					DW		monster_gate		; MOVE_DRAGON_V
					DW		mover_dragon_hops	; MOVE_DRAGON_HOPS
					DW		mover_gate			; MOVE_GATE
					DW		mover_slide_u		; MOVE_SLIDE_U
					DW		mover_slide_v		; MOVE_SLIDE_V
					DW		mover_stalker		; MOVE_SPELL: engine/movers.s
					DW		mover_cauldron	; MOVE_CAULDRON
					DW		mover_pacer_u		; MOVE_PLATFORM_U: engine/movers.s
					DW		mover_pacer_v		; MOVE_PLATFORM_V
					DW		mover_lift		; MOVE_LIFT: engine/movers.s
					DW		mover_conveyor	; MOVE_CONVEYOR: engine/movers.s
					DW		mover_falls		; MOVE_FALLS: engine/movers.s
					DW		mover_crumbles	; MOVE_CRUMBLES: engine/movers.s
					DW		mover_sinks		; MOVE_DROPPING: engine/movers.s
					DW		mover_collapsing	; MOVE_COLLAPSING
					DW		mover_falls_noisy	; MOVE_CARRIED: engine/movers.s
					DW		mover_shoved		; MOVE_PUSHED: engine/movers.s
					DW		mover_move		; MOVE_SLIDING: see mover_sliding
					DW		mover_special	; MOVE_SPECIAL
					DW		mover_shoved_pile	; MOVE_PUSHED_PILE: engine/movers.s
					ASSERT	($ - mover_tbl) / 2 == MOVE_PUSHED_PILE - MOVE_BALL + 1


; How high the balls in this room bounce. Zero until the first ball takes its
; turn, which sets it to its own Z plus BALL_RISE_TO -- so every ball in the
; room bounces to whatever height the first one happened to start at, however
; far up or down the others are. That is the game's, at $5BBD: one variable,
; zeroed when the room is built and claimed by whichever ball runs first.
mover_ball_top:	DB		0

; Whether this room holds its spiked balls up at all, which the game's $5BC0
; says: bit 0 of the room number, taken when the room is built, so that only
; even rooms drop them -- until the knight picks something up there, which
; clears it. engine/movers.s's mover_spike_ball asks; whether one is on its
; way down is its own business.
spike_ball_held:	DB		0


; ---------------------------------------------------------------------------
; A guard: two records that walk as one figure.
;
; The template gives it two sprites, and they are two records in the pool, one
; after the other -- a torso carrying the height, and legs that are passable
; and carry none. That is how the knight is built too, and for the same reason:
; the sort has to be free to put the two halves in different places.
;
; Knight Lore drives them as two objects with two update routines. The torso's,
; upd_150_151, works out the step, writes it into BOTH records, moves itself,
; and then copies its own X and Y down to the legs; the legs' own routine,
; upd_144_to_149_152_to_157, sees a step in its record and animates. Ours is
; one routine because our movers are dispatched per object rather than per
; record, and the legs record carries no behaviour at all.
GUARD_LEGS			EQU		MOVER_PAIR		; the record after the torso
GUARD_STEP			EQU		2


; The frame both halves should wear, from the step they are about to take.
;
; Knight Lore decides this twice, in set_guard_wizard_sprite for the torso and
; at the head of the legs' routine, with the same four-way test each time and a
; different bit to show for it -- bit 0 of the torso's graphic, bit 3 of the
; legs'. The test is on the deltas, and it is the game's own: compare dU with
; dV unsigned, and then look at the sign of whichever won.
;
; In:  IX -> the torso record, DU and DV set
; Out: nothing
; Corrupts: AF, BC, DE
mover_guard_face:	ld		a,(ix+OBJ.DU)
					or		(ix+OBJ.DV)
					ret		z		; going nowhere: leave it as it stands

					; A footstep on every other frame of the walk -- audio_guard_wizard,
					; which takes its count the other way up from the knight's.
					bit		0,(ix+GUARD_LEGS+OBJ.GFX)
					ld		a,(move_tick)
					cpl				; CPL and LD leave Z alone
					ld		b,$80
					call	z,sound_step

					; +U and -V face away, and show the far frame; -U and +V the
					; near one. Along V it is drawn mirrored. So the far frame is
					; the sign bit of the step along V, and the sign bit of the
					; step along U turned over.
					ld		c,0		; along U: not mirrored
					ld		a,(ix+OBJ.DU)
					cp		(ix+OBJ.DV)
					jr		nc,.along_u
					inc		c		; along V: mirrored
					ld		a,(ix+OBJ.DV)
					cpl				; ...and undone below
.along_u:			cpl
					rlca
					and		1
					ld		b,a		; 1: the far frame

					; B says which way the figure faces, C whether it is drawn
					; mirrored. The torso shows the first in bit 0 of its
					; graphic and the legs in bit 3, which is their facing
					; block -- 144 one way and 152 the other.
					ld		a,(ix+OBJ.GFX)
					and		~1 & $FF
					or		b
					ld		(ix+OBJ.GFX),a

					ld		a,(ix+GUARD_LEGS+OBJ.GFX)
					and		~8 & $FF
					bit		0,b
					jr		z,.legs_block
					or		8
.legs_block:		ld		e,a		; and now the walk cycle, which is the
					inc		a		; bottom three bits counting 0 to 5 --
					and		7		; animate_human_legs at $C983
					cp		6
					jr		nz,.phase
					xor		a
.phase:				ld		d,a
					ld		a,e
					and		$F8
					or		d
					ld		(ix+GUARD_LEGS+OBJ.GFX),a

					ASSERT	GUARD_LEGS == ROOM_STRIDE
					rrc		c		; carry: mirrored
					jp		obj_pair_flip	; and turn both records that way


; ---------------------------------------------------------------------------
; ---------------------------------------------------------------------------
; A ghost's speeds, -3, +3, -4 and +4: engine/movers.s's mover_drifter picks
; one of them an axis, and the game indexes delta_tbl at (random & 3) + 4 for
; the same four.
ghost_deltas:		DB		-3, 3, -4, 4


; The frames a ghost wears, which mover_drifter calls once it has picked a new
; way to go -- calc_ghost_sprite, and the flicker between its two.
;
; The wider of the two steps says whether it drifts along U or along V: along
; U it is drawn mirrored, and the sign picks between its two pairs of frames,
; the other way round on the two axes. It keeps the pair until it turns again.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF, BC, DE, HL
ghost_face:			ld		a,(ix+OBJ.DU)
					call	character_door_find.abs
					ld		c,a
					ld		a,(ix+OBJ.DV)
					call	character_door_find.abs
					cp		c
					jr		nc,.face_v

					set		OBJ_FLIP_BIT,(ix+OBJ.FLAGS)
					ld		a,(ix+OBJ.DU)
					or		a
					jr		.face_pair

.face_v:			res		OBJ_FLIP_BIT,(ix+OBJ.FLAGS)
					ld		a,(ix+OBJ.DV)
					cpl				; along V the pairs swap over
					or		a

.face_pair:			jp		m,.face_high
					res		1,(ix+OBJ.GFX)		; graphics 80 and 81
					ret
.face_high:			set		1,(ix+OBJ.GFX)		; ...or 82 and 83
					ret


; ---------------------------------------------------------------------------
; What the hunting ball asks, every time it lands -- engine/movers.s's
; mover_hunter.
;
; It runs FROM the knight and comes FOR the werewolf, which upd_182_183
; decides by the player's own graphic: 16 to 47 is the knight. The game asks
; $5C08, the legs' graphic, and so does this.
;
; In:  nothing
; Out: A = $FF to run from him, 0 to come for him
; Corrupts: AF
hunter_flees:		ld		a,(player + OBJ.GFX)
					sub		16
					cp		32
					ld		a,$FF		; the knight: away
					ret		c
					inc		a		; anything else: towards
					ret


; And what it does on the turn it lands: a click if it was coming down, and
; the other of its two frames either way. The game keeps the DZ it started the
; turn with at $B60C and asks it at $B645 -- a ball with a block sitting on it
; is stopped on its way UP every turn, and clicked every turn of room $A3
; before that was asked.
;
; In:  B  = the DZ it had before gravity
;      IX -> the record
; Out: nothing
; Corrupts: AF, BC, DE, HL
hunter_landed:		bit		7,b
					call	nz,sound_bounce
					jp		mover_flicker


; ---------------------------------------------------------------------------
; How fast the repel spell comes after him this turn -- engine/movers.s's
; mover_stalker asks before it steps.
;
; The game's "in an arch" is bit 0 of the knight's own byte, set by whichever
; arch finds him near it (chk_plyr_spec_near_arch); ours is CHARACTER_DOOR,
; which player_step works out from the same kind of box. In room $88 it never
; slows.
;
; In:  nothing
; Out: C = the step, on each axis
; Corrupts: AF, C
stalker_speed:		ld		c,SPELL_STEP
					ld		a,(room_shown)
					cp		$88
					ret		z
					ld		a,(player + CHARACTER_DOOR)
					inc		a		; $FF: in no doorway
					ret		z
					ld		c,SPELL_CREEP
					ret


; ...and what it wears while it does: the next of its four frames, and the
; moan that goes with it.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF, BC, DE, HL
stalker_frame:		call	mover_cycle4
					jp		sound_uvz


; ---------------------------------------------------------------------------
; Where Knight Lore's movers and Pentagram's share one of engine/movers.s's.
;
; The library takes its constants and hooks by name, one of each for the whole
; game, and the two games gave them different ones: a fire flickers, hums and
; steps one a turn, and bounces off what turns it; a platform or a dragon's
; head is still in its frame, silent and steps two. So each hook the two
; share is a routine here that looks at the behaviour, and Knight Lore's own is
; what everything that is not Pentagram's gets -- the guards reach
; mover_turned as well, and must go on reaching Knight Lore's.

; Whether the record at IX is one of Pentagram's pacers: a platform or a
; pacing dragon's head.
;
; In:  IX -> the record
; Out: Z set if it is
; Corrupts: AF
pentagram_pacer:	ld		a,(ix+OBJ.BEHAVIOUR)
					cp		MOVE_DRAGON_U
					ret		z
					cp		MOVE_DRAGON_V
					ret		z
					cp		MOVE_PLATFORM_U
					ret		z
					cp		MOVE_PLATFORM_V
					ret

; engine/movers.s's pacer_sound: a fire hums along its axis -- fire_sound, in
; sound_fx.s -- and Pentagram's pacers make no sound.
;
; In:  IX -> the record
;      L  = COLLIDE_U or COLLIDE_V
; Out: nothing
; Corrupts: AF
pacer_sound:		call	pentagram_pacer
					ret		z
					jp		fire_sound

; ...pacer_frame: a fire flickers between its two frames, and Pentagram's
; pacers keep theirs.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF
pacer_frame:		call	pentagram_pacer
					ret		z
					jp		mover_flicker

; ...pacer_move: a fire changes every turn, so it is drawn every turn; a
; platform or a dragon goes PENTAGRAM_PACER_STEP, twice the fire's step, and is
; drawn only if it went somewhere.
;
; In:  IX -> the record, its step in DU or DV
; Out: nothing
; Corrupts: everything but IX
PENTAGRAM_PACER_STEP	EQU		2
					ASSERT	PENTAGRAM_PACER_STEP == 2 * PACER_STEP
pacer_move:			call	pentagram_pacer
					jp		nz,mover_move_always
					sla		(ix+OBJ.DU)
					sla		(ix+OBJ.DV)
					jp		mover_move

; ...mover_turned: a fire turning on V bounces off what stopped it -- see
; fire_turned, in sound_fx.s -- and Pentagram's pacers turn in silence.
;
; In:  A  = the axis's bit
;      IX -> the record
; Out: nothing
; Corrupts: AF, BC, DE, HL
mover_turned:		ld		c,a
					call	pentagram_pacer
					ret		z
					ld		a,c
					jp		fire_turned


; A dragon's head that bobs: engine/movers.s's mover_hopper, as a ball bounces,
; but up to a height of its own -- Z 176, where Pentagram's stops -- where a
; ball bounces to the height the room's first ball claimed. The library keeps
; the one top, mover_ball_top, so the dragon puts its own there for its turn
; and the balls' back afterwards. It rises at HOPPER_RISE, the ball's three a
; turn, where Pentagram's rose two: the one constant the two cannot both have.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
DRAGON_HOP_TOP		EQU		176
mover_dragon_hops:	ld		a,(mover_ball_top)
					push	af
					ld		a,DRAGON_HOP_TOP - 1
					ld		(mover_ball_top),a
					call	mover_hopper
					pop		af
					ld		(mover_ball_top),a
					ret

; engine/movers.s's hopper_frame: a ball flickers, a dragon keeps its frame.
; Either way the step along U and V is cleared.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF
hopper_frame:		ld		a,(ix+OBJ.BEHAVIOUR)
					cp		MOVE_DRAGON_HOPS
					jp		z,mover_halt
					jp		mover_flicker

; ...hopper_sound: a ball hums as it goes, a dragon is silent.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF, and what sound_z does
hopper_sound:		ld		a,(ix+OBJ.BEHAVIOUR)
					cp		MOVE_DRAGON_HOPS
					ret		z
					jp		sound_z

; ...hopper_landed: a ball clicks as it lands, a dragon does not.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF, BC, DE, HL
hopper_landed:		ld		a,(ix+OBJ.BEHAVIOUR)
					cp		MOVE_DRAGON_HOPS
					ret		z
					jp		sound_bounce


; Pentagram's monsters ask engine/movers.s whether to sit a turn out, and to
; double and halve their step when they do move in a busy room. Here
; monster_gate has already decided before any of them is reached, so none of
; them sits out a second time, and none goes twice as far.
;
; In:  nothing
; Out: carry clear: it takes its turn
; Corrupts: F
monster_sits_out:	or		a
monster_double:
monster_halve:		ret


; Which way each conveyor carries what stands on it, by the bottom two bits of
; its graphic -- Pentagram's $D30A, kept by pentagram_merge.py numbering the
; four conveyors in order from a multiple of four. engine/movers.s's
; mover_conveyor reads it.
conveyor_steps:		DB		1, 0
					DB		-1, 0
					DB		0, 1
					DB		0, -1

