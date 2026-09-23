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

; The gates only kill what they come down on. upd_9 sets bit 7 of $0D alone --
; "fatal if it hits the player" -- and not bit 5, "fatal if he hits it", so the
; clamp at $CBAF only passes it on when the gate is the one moving. Walking into
; a gate is safe; standing under one as it drops is not.
MOVE_CRUSHING	EQU		10
MOVE_GATE			EQU		10

MOVE_HARMLESS	EQU		11		; and from here on, nothing kills
MOVE_SLIDE_U		EQU		11
MOVE_SLIDE_V		EQU		12
MOVE_SPELL		EQU		13
MOVE_CAULDRON	EQU		14		; what rises out of the pot -- see special.s
MOVE_DROPPING	EQU		15		; these two give way under a weight: see
MOVE_COLLAPSING	EQU		16		; object_landed_on, which relies on the order

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
MOVE_LOOSE		EQU		17
MOVE_CARRIED		EQU		17
MOVE_PUSHED		EQU		18
MOVE_SLIDING		EQU		19
MOVE_SPECIAL		EQU		20		; a collectable -- see special.s

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
					DW		mover_gate			; MOVE_GATE
					DW		mover_slide_u		; MOVE_SLIDE_U
					DW		mover_slide_v		; MOVE_SLIDE_V
					DW		mover_spell		; MOVE_SPELL
					DW		mover_cauldron	; MOVE_CAULDRON
					DW		mover_sinks		; MOVE_DROPPING: engine/movers.s
					DW		mover_collapsing	; MOVE_COLLAPSING
					DW		mover_falls_noisy	; MOVE_CARRIED: engine/movers.s
					DW		mover_pushed		; MOVE_PUSHED
					DW		mover_move		; MOVE_SLIDING: see mover_sliding
					DW		mover_special	; MOVE_SPECIAL
					ASSERT	($ - mover_tbl) / 2 == MOVE_SPECIAL - MOVE_BALL + 1


; How high the balls in this room bounce. Zero until the first ball takes its
; turn, which sets it to its own Z plus BALL_RISE_TO -- so every ball in the
; room bounces to whatever height the first one happened to start at, however
; far up or down the others are. That is the game's, at $5BBD: one variable,
; zeroed when the room is built and claimed by whichever ball runs first.
mover_ball_top:	DB		0

; Whether a spiked ball in this room is on its way down, so that no other may
; start -- the game's $5BBF. And whether the room holds its balls up at all,
; which the game's $5BC0 says: bit 0 of the room number, taken when the room is
; built, so that only even rooms drop them -- until the knight picks something
; up there, which clears it.
spike_ball_falling:	DB		0
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
; A guard that paces along U, turning at whatever stops it -- upd_150_151.
;
; It does not cancel gravity the way a fire does: the game calls
; dec_dZ_and_update_XYZ without setting DZ first, so a guard falls if it walks
; off something, and the floor stops it where it stands.
;
; In:  IX -> the torso record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_guard_u:		xor		a
					ld		(ix+OBJ.DV),a
					ld		(ix+OBJ.DZ),a
					ld		a,GUARD_STEP
					bit		0,(ix+OBJ.MOVE_STATE)
					jr		nz,.forward
					neg
.forward:			ld		(ix+OBJ.DU),a

					call	mover_guard_face
					call	mover_move_pair
					ld		a,COLLIDE_U		; which is bit 0 of MOVE_STATE too
					jp		mover_turn_if_hit


; ---------------------------------------------------------------------------
; The four legs of mover_guard_sq's circuit, in order: the step in U and V, and
; the axis that has to give before the next leg starts.
GUARD_SQ_MASK		EQU		3

mover_guard_sq_tbl:	DB		-GUARD_STEP, 0, COLLIDE_U		; west
					DB		0, GUARD_STEP, COLLIDE_V		; north
					DB		GUARD_STEP, 0, COLLIDE_U		; east
					DB		0, -GUARD_STEP, COLLIDE_V		; south

; A guard that walks a circuit: west until something stops it, then north, then
; east, then south, and round again -- upd_30_31_158_159 through the four
; routines in guard_NSEW_tbl.
;
; Nothing measures the square out. Each leg simply runs until the clamp says
; that axis gave, and the next leg starts from wherever that was, so the shape
; of the walk is the shape of the room and whatever is standing in it. The two
; bits of MOVE_STATE are which leg it is on, and they are the game's own bits
; 0 and 1 of $0D.
;
; In:  IX -> the torso record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_guard_sq:		ld		a,(ix+OBJ.MOVE_STATE)
					and		GUARD_SQ_MASK
					ld		c,a
					ld		b,0
					ld		hl,mover_guard_sq_tbl
					add		hl,bc
					add		hl,bc
					add		hl,bc		; three bytes a leg

					ld		a,(hl)
					ld		(ix+OBJ.DU),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.DV),a
					inc		hl
					ld		a,(hl)
					ld		(.blocked + 1),a		; the axis this leg walks
					ld		(ix+OBJ.DZ),0

					call	mover_guard_face
					call	mover_move_pair

					ld		a,(collide_hit)
.blocked:			and		0		; patched just above
					ret		z		; the leg is not done yet

					ld		a,(ix+OBJ.MOVE_STATE)
					inc		a		; on to the next side
					and		GUARD_SQ_MASK
					ld		(ix+OBJ.MOVE_STATE),a
					ret		


; ---------------------------------------------------------------------------
; The portcullises: how high one rises, how many drops come without waiting,
; and what the room's gates share -- see mover_gate.
GATE_RISE			EQU		31
GATE_DROPS			EQU		4

mover_gate_busy:	DB		0		; a gate has the room
mover_gate_drops:	DB		0		; how many times one has fallen


; A portcullis: rises a unit a turn to GATE_RISE above the floor, waits, then
; drops under its own weight and waits again.
;
; Knight Lore splits it across two graphics and two routines. Graphic 8 is a
; gate standing still and upd_8 only decides whether to set off; graphic 9 is
; the same gate in motion and upd_9 does the moving. Setting bit 0 of the
; graphic is how it changes its own mind, which costs no state at all -- and
; the two frames are the same three bytes by 42 rows, so the rotation buffer
; one took from the arena fits the other.
;
; Two facts belong to the room rather than the gate, and both are the game's:
; only one gate moves at a time ($5BAF), and a gate drops to a schedule for
; its first four drops and on the dice after that ($5BB0). Room $87 has four
; of them and they take it in turns.
;
; Rising is a unit a turn. Falling is not: the game decrements dZ itself on
; top of the one dec_dZ_and_update_XYZ already does, so a dropping portcullis
; accelerates at two a turn and lands hard.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_gate:			call	mover_halt		; it only ever moves in Z

					bit		0,(ix+OBJ.GFX)
					jr		nz,.moving

					; Standing still, at one end of its travel or the other.
					ld		a,(mover_gate_busy)
					or		a
					ret		nz

					ld		a,(room_floor_z)
					cp		(ix+OBJ.Z)
					jr		z,.go_up		; fully down
					add		a,GATE_RISE
					cp		(ix+OBJ.Z)
					jr		nc,.go_up		; not up yet

					; Fully up. The first few drops come without waiting.
					ld		a,(mover_gate_drops)
					cp		GATE_DROPS
					jr		c,.drop
					call	mover_dice
					ret		nz
.drop:				ld		hl,mover_gate_drops
					inc		(hl)
					ld		(ix+OBJ.DZ),-1
					jr		.set_off

.go_up:				call	mover_dice
					ret		nz
					ld		(ix+OBJ.DZ),1
.set_off:			set		0,(ix+OBJ.GFX)		; the moving frame
					ld		a,1
					ld		(mover_gate_busy),a
					ret		

.moving:			ld		a,(ix+OBJ.DZ)
					or		a
					jp		p,.rising

					dec		(ix+OBJ.DZ)		; falling, and gathering pace
					call	mover_move_always
					ld		a,(collide_hit)
					and		COLLIDE_Z
					ret		z		; still on its way down
					call	sound_gate		; and down with a crash, upd_9
					jr		.stop

.rising:			ld		(ix+OBJ.DZ),2		; a unit a turn, after the DEC
					call	sound_uvz		; move_portcullis_up
					call	mover_move_always
					ld		a,(room_floor_z)
					add		a,GATE_RISE
					cp		(ix+OBJ.Z)
					ret		nc		; not at the top yet

.stop:				xor		a
					ld		(mover_gate_busy),a
					res		0,(ix+OBJ.GFX)
					ret		


; ---------------------------------------------------------------------------
; A ghost's speeds, -3, +3, -4 and +4 -- see mover_ghost.
ghost_deltas:		DB		-3, 3, -4, 4

; A ghost, which drifts until something stops it and then picks a new way to
; go -- upd_80_to_83.
;
; It keeps whatever step it has until it is blocked or has come to nothing, so
; it crosses a room in a straight line and then turns at random. The speeds are
; the game's: it indexes delta_tbl at (random & 3) + 4, and entries 4 to 7 of
; that table are -3, +3, -4 and +4.
;
; It takes its step first and decides afterwards, which is the order upd_80_to_83
; uses -- the clamp has to have had its say before there is anything to decide.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_ghost:		; Decide BEFORE moving, not after. Knight Lore moves first and
					; then picks, because the clamp has to have had its say -- but
					; anything riding on this ghost reads its step out of the record,
					; and if what is in there is the step it is ABOUT to take rather
					; than the one it just took, the passenger moves a turn early and
					; every turn the ghost is blocked leaves it further behind. This
					; way round the record holds the step actually achieved, clamped
					; and all, which is what object_carry wants to copy.
					;
					; What the move would have told us is carried over in MOVE_STATE
					; instead: it got nowhere last turn, so draw again.
					call	sound_uvz		; and it moans as it goes
					ld		a,(ix+OBJ.MOVE_STATE)
					or		a
					jr		nz,.turn
					ld		a,(ix+OBJ.DU)
					or		(ix+OBJ.DV)
					jr		nz,.go

					; A new way to go, and the two axes are drawn separately -- the
					; game takes one from its seed and the other from the frame
					; counter, so they are not the same number twice.
.turn:				call	mover_flicker		; it flickers as it goes
					call	mover_rand
					call	.pick
					ld		(ix+OBJ.DU),a
					ld		a,(move_tick)
					call	.pick
					ld		(ix+OBJ.DV),a
					call	.face

.go:				call	mover_move_always		; which leaves IX -> the record
					ld		a,(collide_hit)	; whether something stopped it, kept
					and		COLLIDE_U | COLLIDE_V	; for next turn to read -- which is
					ld		(ix+OBJ.MOVE_STATE),a	; the game's own test on (IX+$0C),
					ret				; a turn later than it asks it


.pick:				and		3
					ld		c,a
					ld		b,0
					ld		hl,ghost_deltas
					add		hl,bc
					ld		a,(hl)
					ret


					; And which way it faces, from the step it has just taken --
					; calc_ghost_sprite. The wider of the two says whether it
					; drifts along U or along V: along U it is drawn mirrored,
					; and the sign picks between its two pairs of frames, the
					; other way round on the two axes. It keeps the pair until
					; it turns again, and flickers between the two of them.
.face:				ld		a,(ix+OBJ.DU)
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
; A table, which goes where it is shoved and then stops -- upd_84. It clears
; its step AFTER moving, where a carried block clears before: the difference is
; that this one keeps what it was given long enough to spend it.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_pushed:		call	mover_sliding
					jp		mover_halt


; A chest, which never lets go of its step at all -- upd_85. Shove one and it
; slides on by itself until the clamp takes the step away.
;
; Either makes a noise while it is actually going somewhere: the game asks
; whether it moved (at $C1A1) and sounds audio_B467 if it did. What the clamp
; left of the step is what it moved.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_sliding:		call	mover_move
					ld		a,(ix+OBJ.DU)
					or		(ix+OBJ.DV)
					jp		nz,sound_uvz
					ret


; ---------------------------------------------------------------------------
BOUNCE_RISE			EQU		4
BOUNCE_STEP			EQU		2

; The ball that hunts -- upd_182_183. It bounces, and every time it lands it
; takes a new upward push and a new direction along ONE axis, chosen by which
; side of it the knight is on. Which axis is a coin toss.
;
; It keeps its horizontal step across the move: the routine saves dX and dY,
; lets dec_dZ_and_update_XYZ clamp them, and then puts the originals straight
; back. So touching something does not cost it its direction -- only landing
; changes that.
;
; And it runs FROM the knight and comes FOR the werewolf. upd_182_183 decides
; which by patching the opcode of the branch that picks the sign -- $38, JR C,
; if the player's graphic is 16 to 47, which is the knight; $30, JR NC, for
; anything else, which is the werewolf -- and so does this. The game also
; varies the bounce height by room number, which is not here.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_bounce:		ld		a,(ix+OBJ.DZ)		; before gravity has had it
					push	af
					ld		c,(ix+OBJ.DU)
					ld		b,(ix+OBJ.DV)
					push	bc
					call	mover_move_always		; which leaves IX -> the record
					pop		bc
					ld		(ix+OBJ.DU),c		; whatever the clamp made of them,
					ld		(ix+OBJ.DV),b		; it still wants to go that way
					pop		bc		; B - that DZ

					ld		a,(collide_hit)
					and		COLLIDE_Z
					ret		z		; still in the air

					; Stopped in Z either way, it springs up again -- but it
					; only makes a noise if it was coming down. The game keeps
					; the DZ it started the turn with at $B60C and asks it at
					; $B645: a ball with a block sitting on it is stopped on
					; its way UP every turn, and bounced silently in the game
					; where this clicked on every turn of room $A3.
					ld		(ix+OBJ.DZ),BOUNCE_RISE
					bit		7,b
					call	nz,sound_bounce
					call	mover_flicker		; and neither axis, until one is picked

					; Knight or werewolf. The game asks $5C08, the legs' graphic.
					ld		a,(player + OBJ.GFX)
					sub		16
					cp		32
					ld		a,$38		; JR C: away from the knight
					jr		c,.form
					ld		a,$30		; JR NC: towards the werewolf
.form:				ld		(.v_dir),a
					ld		(.u_dir),a

					call	mover_rand
					and		1
					jr		z,.along_u

					ld		a,(player + OBJ.V)
					cp		(ix+OBJ.V)
					ld		a,BOUNCE_STEP
.v_dir:				jr		nc,.go_v		; opcode patched above
					neg
.go_v:				ld		(ix+OBJ.DV),a
					ret

.along_u:			ld		a,(player + OBJ.U)
					cp		(ix+OBJ.U)
					ld		a,BOUNCE_STEP
.u_dir:				jr		nc,.go_u		; opcode patched above
					neg
.go_u:				ld		(ix+OBJ.DU),a
					ret


; ---------------------------------------------------------------------------
; The repel spell: a sparkle that homes in on the knight, four units a turn on
; each axis at once, and creeps at one while he stands in an arch -- which is
; what gives him the chance to get out of the room ahead of it.
;
; Knight Lore's, from upd_164_to_167 and move_towards_plyr. The game's "in an
; arch" is bit 0 of the knight's own byte, set by whichever arch finds him
; near it (chk_plyr_spec_near_arch); ours is CHARACTER_DOOR, which player_step
; works out from the same kind of box. In room $88 it never slows.
;
; The way to go is the SIGN of the difference, not its carry, as the game has
; it: level with him counts as past him, so it jitters about his position
; rather than settling on it. It does not set DZ, so it falls like anything
; else, and it runs through its four frames every turn.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_spell:		ld		c,SPELL_STEP
					ld		a,(room_shown)
					cp		$88
					jr		z,.speed
					ld		a,(player + CHARACTER_DOOR)
					inc		a		; $FF: in no doorway
					jr		z,.speed
					ld		c,SPELL_CREEP

.speed:				ld		hl,player + OBJ.U
					ld		a,(ix+OBJ.U)
					sub		(hl)
					ld		a,c
					jp		m,.u		; short of him: towards
					neg
.u:					ld		(ix+OBJ.DU),a

					inc		hl		; player + OBJ.V
					ld		a,(ix+OBJ.V)
					sub		(hl)
					ld		a,c
					jp		m,.v
					neg
.v:					ld		(ix+OBJ.DV),a

					call	mover_cycle4
					call	sound_uvz
					jp		mover_move_always


; ---------------------------------------------------------------------------
; A spiked ball, which hangs where the room put it until, one turn in sixteen,
; it lets go and drops until it lands -- upd_63. One at a time: while one is
; falling no other may start. The test is the game's own, the random seed below
; sixteen.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_spike_ball:	ld		a,(spike_ball_held)
					or		a
					ret		nz
					bit		2,(ix+OBJ.MOVE_STATE)
					jr		nz,.drop
					ld		a,(spike_ball_falling)
					or		a
					ret		nz
					call	mover_rand
					cp		16
					ret		nc
					set		2,(ix+OBJ.MOVE_STATE)
					ld		a,1
					ld		(spike_ball_falling),a
					ret

					; Falling: gravity has DZ, which it has been taking one off a turn
					; since the ball let go, so it gathers speed as it goes.
.drop:				call	mover_move		; which leaves IX -> the record
					ld		a,(collide_hit)
					and		COLLIDE_Z
					jp		z,sound_z		; whistling down, spiked_ball_drop
					res		2,(ix+OBJ.MOVE_STATE)
					xor		a
					ld		(spike_ball_falling),a
					ret


; ---------------------------------------------------------------------------
; A block that crumbles away when something lands on it -- upd_143. The game
; turns it into graphic 184 and steps it straight on to 185, draws that for a
; turn, and then takes it out of the room. The dropping block, which sinks
; under the same mark instead, is engine/movers.s's mover_sinks.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything -- IX only on the turn object_hide takes it away
mover_collapsing:	bit		4,(ix+OBJ.MOVE_STATE)
					jp		nz,object_hide		; crumbled last turn: gone
					bit		3,(ix+OBJ.MOVE_STATE)
					ret		z
					ld		(ix+OBJ.MOVE_STATE),$10
					ld		a,185		; crumbling with the sparkles' noise
					ld		(ix+OBJ.GFX),a
					call	sound_sparkle
					call	mover_halt
					ld		(ix+OBJ.DZ),a
					jp		mover_paint


; ---------------------------------------------------------------------------
; A block that slides to and fro along one axis, a unit a turn.
;
; This is Knight Lore's, from loc_B6BF, which upd_54 and upd_55 share by
; patching the two instructions that name the axis -- and it is patched here
; for the same reason, because (IX+d) takes its displacement as an immediate.
;
; The block does not remember which way it is going. Instead the turn counter
; is folded into a triangle: bit 4 says which way the ramp runs and the low
; four bits are how far along it is, so the wave climbs 0 to 15 and falls back
; over thirty-two turns. The block compares where it is against where the wave
; says it should be and steps one unit towards it.
;
; Bit 5 of the record's own address is added in first. Records are thirty-two
; bytes apart, so that bit alternates, and neighbouring blocks run in
; antiphase -- one going out as the other comes back.
;
; Position is taken as (coordinate + 8) & 15, so a block standing in the
; middle of its cell is in the middle of its travel and swings eight either
; way.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_slide_u:		call	sound_u		; upd_54's hum, every frame
					ld		hl,OBJ.DU * 256 + OBJ.U
					jr		mover_slide

; See mover_slide_u.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_slide_v:		call	sound_v
					ld		hl,OBJ.DV * 256 + OBJ.V
					;; NB: fall through into mover_slide

; See mover_slide_u. The axis comes in HL: H the offset of its step in the
; record, L of its position.
;
; In:  IX -> the record; mover_ix names it too
;      H  = OBJ.DU or OBJ.DV
;      L  = OBJ.U or OBJ.V
; Out: nothing
; Corrupts: everything but IX
mover_slide:		ld		a,l
					ld		(.here + 2),a		; LD A,(IX+d) is DD 7E d
					ld		a,h
					ld		(.step + 2),a		; LD (IX+d),A is DD 77 d

					call	mover_hover		; it moves along one axis and no other,
									; and does not fall

					; Where the wave says it should be.
					ld		a,ixl
					rrca
					and		$10		; half a cycle for every other record
					ld		c,a
					ld		a,(move_tick)
					add		a,c
					bit		4,a
					jr		z,.climbing
					cpl				; the falling half of the ramp
.climbing:			and		$0F
					ld		c,a

					; ...and where it is.
.here:				ld		a,(ix+OBJ.U)		; patched: U or V
					add		a,8
					and		$0F
					cp		c
					ret		z		; already there, and nothing to draw

					ld		a,1
					jr		c,.step		; below the wave: out
					neg				; above it: back
.step:				ld		(ix+OBJ.DU),a		; patched: DU or DV

					;; NB: fall through into mover_move
					;; ...which engine/mover.s starts with, and knightlore.s includes next
					ASSERT	$ == mover_move
