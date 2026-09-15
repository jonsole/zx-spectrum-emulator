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
; and the ghost. Not the repel spell, the gates or the cauldron's bubbles.
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

MOVE_HARMLESS	EQU		10		; and from here on, nothing kills
MOVE_SLIDE_U		EQU		10
MOVE_SLIDE_V		EQU		11
MOVE_GATE			EQU		12
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

; Bits of OBJ.MOVE_STATE. The direction bits are numbered by axis, so that the
; same mask both says which way a thing is going and tests collide_hit for
; whether it just ran into something -- which is how the game numbers them.
MOVE_RISING		EQU		4		; bit 2, as in the game's byte $0D

; How fast each of them goes, and how high a ball bounces.
FIRE_STEP			EQU		2
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
					DB		FG_SPIKE_HIGH, MOVE_STILL
					DB		$FF

mover_tbl:			DW		mover_ball			; MOVE_BALL
					DW		mover_fire_u		; MOVE_FIRE_U
					DW		mover_fire_v		; MOVE_FIRE_V
					DW		mover_guard_u		; MOVE_GUARD_U
					DW		mover_guard_sq	; MOVE_GUARD_SQ
					DW		mover_ghost		; MOVE_GHOST
					DW		mover_bounce		; MOVE_BOUNCE
					DW		mover_spike_ball	; MOVE_SPIKE_BALL
					DW		mover_slide_u		; MOVE_SLIDE_U
					DW		mover_slide_v		; MOVE_SLIDE_V
					DW		mover_gate			; MOVE_GATE
					DW		mover_spell		; MOVE_SPELL
					DW		mover_cauldron	; MOVE_CAULDRON
					DW		mover_dropping	; MOVE_DROPPING
					DW		mover_collapsing	; MOVE_COLLAPSING
					DW		mover_carried		; MOVE_CARRIED
					DW		mover_pushed		; MOVE_PUSHED
					DW		mover_move		; MOVE_SLIDING: see mover_sliding
					DW		mover_special	; MOVE_SPECIAL
					ASSERT	($ - mover_tbl) / 2 == MOVE_SPECIAL - MOVE_BALL + 1


; How many turns have gone by. Every mover in the castle is driven from this
; one number, which is what keeps them all in step with each other -- Knight
; Lore reads its frame counter at $5BA2 the same way.
move_tick:			DB		0

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

; The record being updated, kept because object_place and depth_relink are
; both free to corrupt IX.
mover_ix:			DW		0


; What drives a template, or MOVE_NONE.
;   A  - the template index
; Out: A - the behaviour. Preserves DE.
mover_find:			ld		hl,mover_of
.next:				ld		c,(hl)
					inc		c		; $FF ends the list
					jr		z,.none
					dec		c
					cp		c
					inc		hl
					jr		z,.found
					inc		hl
					jr		.next
.found:				ld		a,(hl)
					ret		
.none:				xor		a
					ret		


; ---------------------------------------------------------------------------
; Give every mover in the room its turn.
;
; The whole pool is walked and the behaviour byte read, rather than a list of
; movers being kept: a room holds at most a couple of dozen objects, and a
; walk that reads one byte and moves on costs less than the list would to
; maintain across a room change.
movers_step:		ld		hl,move_tick
					inc		(hl)

					ld		a,(room_object_count)
					or		a
					ret		z
					ld		b,a
					ld		ix,room_objects

.next:				ld		a,(ix+OBJ.BEHAVIOUR)
					sub		MOVE_BALL		; MOVE_NONE and MOVE_STILL have no turn,
					jr		c,.still		; and are not in the table

					push	bc
					ld		(mover_ix),ix
					add		a,a
					ld		l,a
					ld		h,0
					ld		de,mover_tbl
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ex		de,hl
					ld		de,.done
					push	de
					jp		(hl)
.done:				ld		ix,(mover_ix)
					pop		bc

					; Stir the refresh register into the seed after every record, which is
					; where Knight Lore does it -- ret_from_tbl_jp at $B27C, on the way
					; round its own object walk. Doing it only where a random number is
					; ASKED for is not the same thing and is not enough: the path between
					; two asks is the same code every time, so R advances by the same
					; amount and the seed walks in a fixed stride. Two bits of that stride
					; away, and a ghost drew -3 and -4 for ever -- pressed against the west
					; wall of room $58 with no draw left that could free it. Here the
					; stride is however much work the last object happened to do, which is
					; a different number for one that moved and one that did not.
.still:				call	mover_rand

					ld		de,ROOM_STRIDE
					add		ix,de
					djnz	.next

					; And the turn counter on top of it, once round. Knight Lore folds
					; the frame counter in at the end of its own walk, at loc_B000, and
					; the reason is the one above taken one step further: with a room
					; standing still, every turn runs the same instructions, so R lands
					; on the same number and the seed still walks in a fixed stride --
					; and a fixed stride is a short cycle in the low bits. Adding a
					; counter makes the stride itself change every turn, which is what
					; lets a ghost pressed against a wall eventually draw the step that
					; frees it.
					ld		a,(move_tick)
					jp		mover_stir


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
;   IX -> the record
mover_slide_u:		ld		hl,OBJ.DU * 256 + OBJ.U
					jr		mover_slide
mover_slide_v:		ld		hl,OBJ.DV * 256 + OBJ.V

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


; ---------------------------------------------------------------------------
; Move an object by the step its record now holds, and repaint what that
; disturbed. mover_move draws only when the step came to something; a mover
; whose graphic changes every turn wants mover_move_always instead, or it
; animates in the record and nowhere else.
;
; The DEC in mover_clamp is gravity, and it is gravity for everything. Knight
; Lore puts it in dec_dZ_and_update_XYZ, which every object's move goes
; through, and anything not meant to fall cancels it by setting DZ to one
; first. That is why a bouncing ball needs no gravity code of its own and a
; sliding block needs one instruction.
;   IX -> the record, with DU, DV and DZ set
mover_move:			call	mover_clamp
					ld		a,(ix+OBJ.DU)
					or		(ix+OBJ.DV)
					or		(ix+OBJ.DZ)
					ret		z		; the room took the whole step away
					jr		mover_paint

mover_move_always:	call	mover_clamp

mover_paint:		call	region_reset
					call	region_add		; where it was

					ld		d,(ix+OBJ.DU)
					ld		e,(ix+OBJ.DV)
					ld		a,(ix+OBJ.DZ)
					call	depth_step
					call	room_adjust
					call	object_place

					ld		ix,(mover_ix)
					call	region_add		; and where it is now
					call	redraw_defer
					ld		ix,(mover_ix)		; the draw is free to corrupt it
					ret		


; Gravity, then the room's edges, then its floor, then everything standing in
; it. Nothing may be clamped against itself, and a mover IS in the pool the
; clamp walks -- so it is made passable for the length of its own test. A
; character never needed this: neither of them is in the room's pool.
mover_clamp:		ld		hl,player		; the knight is not in the room's
					ld		(collide_other),hl	; pool, so a mover would sweep
									; straight through him without this
					dec		(ix+OBJ.DZ)
					ld		a,(ix+OBJ.FLAGS)
					push	af
					or		OBJ_PASSABLE
					ld		(ix+OBJ.FLAGS),a
					ld		d,(ix+OBJ.DU)
					ld		e,(ix+OBJ.DV)
					call	object_collide_room
					pop		af
					ld		(ix+OBJ.FLAGS),a
					ret		


; ---------------------------------------------------------------------------
; Most movers set their own step from nothing each turn, and these are the
; nothing.
;
; mover_hover holds the object up for the turn as well: mover_clamp's DEC takes
; a DZ of one back to nothing, which is how upd_54 stops a sliding block
; falling. mover_flicker turns it to the other of its two frames first -- bit 0
; of the graphic. Both go on through mover_halt, which takes the step along the
; floor away.
;   IX -> the record
; Out: A = 0.
mover_hover:		ld		(ix+OBJ.DZ),1
					jr		mover_halt

mover_flicker:		ld		a,(ix+OBJ.GFX)
					xor		1
					ld		(ix+OBJ.GFX),a

mover_halt:			xor		a
					ld		(ix+OBJ.DU),a
					ld		(ix+OBJ.DV),a
					ret


; The next of an object's four frames: the bottom two bits of its graphic count
; round and the rest stay put. The repel spell and the cauldron's bubbles.
;   IX -> the record
; Corrupts AF.
mover_cycle4:		ld		a,(ix+OBJ.GFX)
					inc		a
					xor		(ix+OBJ.GFX)
					and		3
					xor		(ix+OBJ.GFX)
					ld		(ix+OBJ.GFX),a
					ret


; ---------------------------------------------------------------------------
; A fire that paces to and fro along one axis, two units a turn, turning round
; whenever something stops it.
;
; Knight Lore's, from upd_86_87 and upd_180_181 -- two routines that are the
; same routine with the axis changed, which is why this is one with the axis
; patched. The neat part is theirs: the bit that says which way it is going is
; numbered by axis, and so is the bit that says which axis the clamp had to
; cut, so the same mask does both and the turn is an XOR.
;
; It animates as it goes, between its graphic and the one below it. The
; template names the taller of the two -- 181 of 180/181, 87 of 86/87 -- so
; the rotation buffer the first frame takes from the arena fits the second.
;   IX -> the record
mover_fire_u:		ld		hl,OBJ.DU * 256 + COLLIDE_U
					jr		mover_fire
mover_fire_v:		ld		hl,OBJ.DV * 256 + COLLIDE_V

mover_fire:			ld		a,h
					ld		(.step + 2),a		; LD (IX+d),A is DD 77 d
					ld		a,l
					ld		(.which + 1),a		; the axis, as a mask

					call	mover_hover		; it does not fall
					call	mover_flicker

					ld		a,(ix+OBJ.MOVE_STATE)
.which:				and		0		; patched: the axis bit
					ld		a,FIRE_STEP
					jr		nz,.forward
					neg
.forward:
.step:				ld		(ix+OBJ.DU),a		; patched: DU or DV

					call	mover_move_always
					ld		a,(.which + 1)		; the same bit again

					;; NB: fall through into mover_turn_if_hit


; Turn round if the move just made was stopped along the axis in A: flip that
; bit of MOVE_STATE, which is numbered by axis the same way collide_hit is.
;   A  - the axis's bit
;   IX -> the record
; Corrupts AF, C.
mover_turn_if_hit:	ld		c,a
					ld		a,(collide_hit)
					and		c
					ret		z		; nothing in the way
					ld		a,(ix+OBJ.MOVE_STATE)
					xor		c
					ld		(ix+OBJ.MOVE_STATE),a
					ret


; ---------------------------------------------------------------------------
; A ball that bounces on the spot: falls, and on landing climbs again until it
; is BALL_RISE_TO above where the room's first ball started.
;
; That last part is the game's and it is odd enough to be worth saying twice.
; upd_178_179 reads $5BBD, and if it is still zero -- which it is until the
; first ball of the room takes its turn -- fills it in from its own Z plus 32.
; Every other ball in the room then bounces to THAT height, wherever it sits
; itself. Whichever ball the object walk reaches first decides for all of them.
;
; Falling needs no code: mover_clamp's DEC is the gravity, and the clamp stops
; it on the floor or on whatever it lands on. Climbing sets DZ to three, which
; the same DEC turns into two.
;   IX -> the record
mover_ball:			ld		a,(mover_ball_top)
					or		a
					jr		nz,.have_top
					ld		a,(ix+OBJ.Z)
					add		a,BALL_RISE_TO
					ld		(mover_ball_top),a
.have_top:			call	mover_flicker		; and it bounces where it stands

					ASSERT	MOVE_RISING == 1 << 2
					bit		2,(ix+OBJ.MOVE_STATE)
					jr		nz,.rising

					call	mover_move_always		; DZ is whatever gravity left it
					ld		a,(collide_hit)
					and		COLLIDE_Z
					ret		z		; still in the air
					set		2,(ix+OBJ.MOVE_STATE)		; it has landed: up again
					ret

.rising:			ld		(ix+OBJ.DZ),BALL_RISE
					call	mover_move_always
					ld		a,(mover_ball_top)
					cp		(ix+OBJ.Z)
					ret		nc		; not up to it yet
					res		2,(ix+OBJ.MOVE_STATE)
					ret


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
GUARD_LEGS			EQU		ROOM_STRIDE		; the record after the torso
GUARD_STEP			EQU		2


; The frame both halves should wear, from the step they are about to take.
;
; Knight Lore decides this twice, in set_guard_wizard_sprite for the torso and
; at the head of the legs' routine, with the same four-way test each time and a
; different bit to show for it -- bit 0 of the torso's graphic, bit 3 of the
; legs'. The test is on the deltas, and it is the game's own: compare dU with
; dV unsigned, and then look at the sign of whichever won.
;
;   IX -> the torso record, DU and DV set
; Corrupts AF, BC.
mover_guard_face:	ld		a,(ix+OBJ.DU)
					or		(ix+OBJ.DV)
					ret		z		; going nowhere: leave it as it stands

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
; Move a two-record figure by the step in the first of them, and repaint both
; as one region.
;
; The LEGS are re-sorted first, and against the whole run; the torso then
; starts its own scan from wherever they landed. That order is not a detail.
; The two share U and V, and with the torso's box reaching 24 above the floor
; and the legs' reaching nothing at all, the torso is the nearer of the two --
; so it can never belong in front of the legs, which is exactly what lets it
; start from them. character_move sorts the knight the same way round, and
; doing it backwards here put the guard in front of scenery it should have
; been behind, because starting the legs at the torso pinned them later in the
; list than they belonged.
;
; The legs take the torso's new U and V and keep their own Z -- (IX+$01) and
; (IX+$02) into (IX+$21) and (IX+$22) is all the game copies. They are worked
; out from the torso's old position plus the step, because the torso has not
; moved yet when the legs need them.
;   IX -> the torso record, with DU, DV and DZ set
mover_move_pair:	call	mover_clamp

					call	region_reset
					call	region_add		; the torso, where it was
					ld		bc,GUARD_LEGS
					add		ix,bc
					call	region_add		; and the legs
					ld		ix,(mover_ix)

					ld		a,(ix+OBJ.U)
					add		a,(ix+OBJ.DU)
					ld		c,a
					ld		a,(ix+OBJ.V)
					add		a,(ix+OBJ.DV)
					ld		b,a

					ld		de,GUARD_LEGS
					add		ix,de
					; The legs have no step of their own to hand depth_step, and
					; are not always where the torso is -- the wizard's two
					; pieces start eight apart -- so whether they moved is where
					; they go against where they are.
					ld		a,(ix+OBJ.U)
					cp		c
					jr		nz,.legs_moved
					ld		a,(ix+OBJ.V)
					cp		b
.legs_moved:		ld		(ix+OBJ.U),c		; nothing from here to the call
					ld		(ix+OBJ.V),b		; touches the flags
					call	nz,depth_relink		; against the whole run
					call	room_adjust
					call	object_place

					ld		hl,(mover_ix)		; the legs, which the torso
					ld		bc,GUARD_LEGS		; sorts after
					add		hl,bc
					ld		ix,(mover_ix)
					ld		d,(ix+OBJ.DU)
					ld		e,(ix+OBJ.DV)
					ld		a,(ix+OBJ.DZ)
					call	depth_step_upper
					call	room_adjust
					call	object_place

					ld		ix,(mover_ix)
					ld		bc,GUARD_LEGS
					add		ix,bc
					call	region_add		; the legs, where they are now
					ld		ix,(mover_ix)
					call	region_add		; and the torso
					call	redraw_defer
					ld		ix,(mover_ix)
					ret		


; ---------------------------------------------------------------------------
; A guard that paces along U, turning at whatever stops it -- upd_150_151.
;
; It does not cancel gravity the way a fire does: the game calls
; dec_dZ_and_update_XYZ without setting DZ first, so a guard falls if it walks
; off something, and the floor stops it where it stands.
;   IX -> the torso record
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
; A guard that walks a circuit: west until something stops it, then north, then
; east, then south, and round again -- upd_30_31_158_159 through the four
; routines in guard_NSEW_tbl.
;
; Nothing measures the square out. Each leg simply runs until the clamp says
; that axis gave, and the next leg starts from wherever that was, so the shape
; of the walk is the shape of the room and whatever is standing in it. The two
; bits of MOVE_STATE are which leg it is on, and they are the game's own bits
; 0 and 1 of $0D.
;   IX -> the torso record
GUARD_SQ_MASK		EQU		3

mover_guard_sq_tbl:	DB		-GUARD_STEP, 0, COLLIDE_U		; west
					DB		0, GUARD_STEP, COLLIDE_V		; north
					DB		GUARD_STEP, 0, COLLIDE_U		; east
					DB		0, -GUARD_STEP, COLLIDE_V		; south

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
GATE_RISE			EQU		31
GATE_DROPS			EQU		4

mover_gate_busy:	DB		0		; a gate has the room
mover_gate_drops:	DB		0		; how many times one has fallen
mover_seed:			DB		0

; One turn in thirty-two, near enough. The game stirs the refresh register into
; a seed on every object it updates -- ret_from_tbl_jp at $B27C -- and then
; looks at five bits of it; this stirs it where it is asked instead.
; Out: zf set when the dice come up.
mover_dice:			call	mover_rand
					and		$1F
					ret		


; The seed itself, stirred wherever it is asked for.
mover_rand:			ld		a,r
mover_stir:			ld		hl,mover_seed		; A into the seed
					add		a,(hl)
					ld		(hl),a
					ret		


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
					jr		.stop

.rising:			ld		(ix+OBJ.DZ),2		; a unit a turn, after the DEC
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
; A block that goes wherever whatever it is standing on goes.
;
; upd_62, and it is barely anything: clear the step, then fall. Everything else
; happens inside the clamp, where object_carry hands it the step of whatever
; stopped its fall. Clearing DU and DV every turn is what makes that safe --
; the ride is the only thing that ever writes them, so it can never accumulate.
;
; It is worth noticing that this needs no notion of "standing on" at all. The
; block is always falling a little and always landing, and landing is where the
; question gets asked.
;   IX -> the record
mover_carried:		call	mover_halt
					jp		mover_move		; DZ is left to gravity


; ---------------------------------------------------------------------------
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
;   IX -> the record
ghost_deltas:		DB		-3, 3, -4, 4

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


; ---------------------------------------------------------------------------
; A table, which goes where it is shoved and then stops -- upd_84. It clears
; its step AFTER moving, where a carried block clears before: the difference is
; that this one keeps what it was given long enough to spend it.
mover_pushed:		call	mover_move
					jp		mover_halt


; A chest, which never lets go of its step at all -- upd_85. Shove one and it
; slides on by itself until the clamp takes the step away, which is all
; mover_move does: mover_tbl points straight at it.
mover_sliding		EQU		mover_move


; ---------------------------------------------------------------------------
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
;   IX -> the record
BOUNCE_RISE			EQU		4
BOUNCE_STEP			EQU		2

mover_bounce:		ld		c,(ix+OBJ.DU)
					ld		b,(ix+OBJ.DV)
					push	bc
					call	mover_move_always		; which leaves IX -> the record
					pop		bc
					ld		(ix+OBJ.DU),c		; whatever the clamp made of them,
					ld		(ix+OBJ.DV),b		; it still wants to go that way

					ld		a,(collide_hit)
					and		COLLIDE_Z
					ret		z		; still in the air

					ld		(ix+OBJ.DZ),BOUNCE_RISE
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
;   IX -> the record
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
					jp		mover_move_always


; ---------------------------------------------------------------------------
; A spiked ball, which hangs where the room put it until, one turn in sixteen,
; it lets go and drops until it lands -- upd_63. One at a time: while one is
; falling no other may start. The test is the game's own, the random seed below
; sixteen.
;   IX -> the record
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
					ret		z
					res		2,(ix+OBJ.MOVE_STATE)
					xor		a
					ld		(spike_ball_falling),a
					ret


; ---------------------------------------------------------------------------
; A block that sinks a unit every turn something is standing on it -- upd_91.
; object_landed_on leaves the mark, when whatever is on top comes down on it in
; its own clamp; the game does the same at $CC6C.
;   IX -> the record
mover_dropping:		bit		3,(ix+OBJ.MOVE_STATE)
					ret		z
					res		3,(ix+OBJ.MOVE_STATE)
					ld		(ix+OBJ.DZ),0		; one unit, not a fall
					jp		mover_move


; A block that crumbles away when something lands on it -- upd_143. The game
; turns it into graphic 184 and steps it straight on to 185, draws that for a
; turn, and then takes it out of the room.
;   IX -> the record
mover_collapsing:	bit		4,(ix+OBJ.MOVE_STATE)
					jp		nz,special_hide		; crumbled last turn: gone
					bit		3,(ix+OBJ.MOVE_STATE)
					ret		z
					ld		(ix+OBJ.MOVE_STATE),$10
					ld		(ix+OBJ.GFX),185
					call	mover_halt
					ld		(ix+OBJ.DZ),a
					jp		mover_paint
