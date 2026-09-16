; Characters -- the knight now, the castle's other walkers later.
;
; A character is two objects that move as one: legs on the floor and a body a
; dozen units above them. Knight Lore keeps them as two records for the same
; reason we do -- the body passes in front of scenery the legs pass behind, so
; the depth sort has to be free to put them in different places.
;
; The two records are adjacent slots, legs first, which is what pairs them: the
; body is CHARACTER_BODY along from whatever IX points at. The state that
; steers them both -- facing, walk phase, graphic bases -- lives in the tail of
; the legs record, which is free space inside its ROOM_STRIDE slot.
;
; --- the graphics ----------------------------------------------------------
;
; Frames come in blocks of eight per facing: six of walk cycle and two spare.
; A character names two bases, one for its legs and one for its body, because
; the castle's walkers share leg artwork and each bring their own top half.
; Graphics 16-21 and 144-149 are the same four leg sprites under two numbers,
; as are 24-29 and 152-157, which is how they can carry different pixel
; adjustments while drawing the same boots.
;
;   legs = LEGS_BASE + block + phase
;   body = BODY_BASE + block + phase
;
; The knight's bases are 16 and 32. Block 0 is walking away from the viewer
; and block 8 towards it -- 16-21 draw him from behind, 24-29 face on -- and
; left is right mirrored, which is why there are two blocks and not four.

CHARACTER_BODY		EQU		ROOM_STRIDE		; the body is the slot above the legs
CHARACTER_BLOCK		EQU		8		; graphics per facing block
CHARACTER_PHASES	EQU		6		; ...of which this many are the walk
					; A frame of the cycle every step, because Knight
					; Lore animates the legs every turn it is walking
					; -- $C969 falls into animate_human_legs whenever
					; the forward key is down. Three units a turn over
					; six frames of cycle is the same ground per frame
					; as one unit over three turns; what changes is
					; that he covers it in six turns instead of
					; eighteen.
					; A walking body rides twelve above the legs, the same
					; twelve Knight Lore uses -- see walking_character. They
					; meet because the game nudges the two by different amounts
					; as well: sprite_adj has -6 for the legs and -8 for the
					; body and object_place subtracts that, so the body lands
					; two pixels lower than its Z alone would put it.
; What the two kept rotation buffers are sized from -- the biggest frame each
; half can wear, once sprites.py has taken the blank rows off. That is a fact
; about the trimmed set, not the game's artwork, so sprites.py checks it on
; every build: a buffer too small gets rotated past its end, into the other.
CHARACTER_LARGEST	EQU		sprite_030		; 3x24: the sparkle the legs die and
					; come back as, which is bigger than any walking frame
CHARACTER_TALLEST	EQU		sprite_092		; 3x29: the werewolf's body, which only a
					; walking character's top half ever wears
CHARACTER_BODY_UP	EQU		12		; how far every body rides above its legs,
					; the same twelve Knight Lore gives the
					; knight. Z is what the depth sort reads, so
					; the height belongs here and not in the
					; pixel nudge.
CHARACTER_Z			EQU		128		; the floor

; How wide a character is, as a half-extent about U and V -- see COLLIDE_HEIGHT
; for why that is the convention. Knight Lore gives the knight five each way.
CHARACTER_HALF_U	EQU		5
CHARACTER_HALF_V	EQU		5

; Vertical state, two bytes past the pair of slots. It cannot live in either
; record: an object record is exactly a ROOM_STRIDE slot now, with nothing
; spare. It does not have to, either -- a character is not in the room's pool,
; so its records can be followed by whatever it needs.
CHARACTER_DZ		EQU		ROOM_STRIDE * 2		; velocity, signed
CHARACTER_STATE		EQU		ROOM_STRIDE * 2 + 1

; And the ones that used to be fields of the object record. They are a
; character's business only -- a wall has no facing and no walk cycle -- and
; every one of the room's thirty-six slots was carrying them unused.
CHARACTER_FACING	EQU		ROOM_STRIDE * 2 + 2	; 0 to 3, see character_walk
CHARACTER_PHASE		EQU		ROOM_STRIDE * 2 + 3	; where in the six-frame cycle
CHARACTER_LEGS		EQU		ROOM_STRIDE * 2 + 4	; first graphic of the legs
CHARACTER_BODY_G	EQU		ROOM_STRIDE * 2 + 5	; ...and of the body
; Which of the room's doorways this character is standing in, or $FF. Only
; the player ever has it set: it is what lifts the room's edge so he can walk
; out, and nothing else in the castle is allowed through. Knight Lore draws
; the same line with bit 3 of an object's flags, which says whether an arch
; should bother looking at it -- see chk_plyr_spec_near_arch at $C7DB.
CHARACTER_DOOR		EQU		ROOM_STRIDE * 2 + 6

; How close to an arch counts as standing in it: six units across the opening,
; fifteen along it, and in height from just below the arch's floor to one
; object's height above it. Across and along are Knight Lore's own numbers,
; from the box its arches test against ($06/$0F either way round). Its height
; is four either way ($04 in Z), and steering still uses that; standing in the
; doorway does not. A room's edge is behind the knight once he is in the arch,
; and with only four units of height, standing on something there -- a spell,
; a collectable, a block, all twelve tall -- turned the edge back on with him
; already past it, and every step he took was cut to nothing.
;
; No higher than that, though: the doorway lifting the edge is also what would
; let a jump that started in the room carry him into the arch through its top.
; He cannot jump in a doorway (character_jump), and above this height the edge
; holds him back. On something twelve tall his head is at 164, under the
; pillars' 168. A walkway's arch is 48 above the floor's and no side of any
; room has more than one arch, so neither storey reaches the other.
DOOR_ACROSS		EQU		6
DOOR_ALONG		EQU		15
DOOR_LEVEL		EQU		4
DOOR_HEIGHT		EQU		13		; Z up to twelve above the arch's floor
CHARACTER_JUMPING	EQU		1		; bit 0 of the above

; Knight Lore gives the knight an impulse of eight and then takes one a turn
; off it while the jump key is still down and two once it is let go, so how
; long you hold the key is how high he goes. That is the whole of a
; variable-height jump and it costs one test a turn. Head Over Heels has no
; velocity at all -- a counter of rising steps, four or eight or ten of them,
; at one unit each -- so its jump is the same height however it is asked for.
CHARACTER_JUMP_DZ	EQU		8
CHARACTER_FALL_MAX	EQU		-8 & $FF		; terminal velocity, so that the
					; clamp never has far to walk back

; Where the floor ends is the room's business, not a constant here -- see
; room_half_u and character_collide. It used to be a pair of hand-picked
; limits, 72 and 180, which were not even symmetric about the room's centre at
; 128: 56 one way and 52 the other, so a character could walk four units
; further north-west than north-east.
;
; The worry they were guarding was real, though. Walk out of a room and the
; projection puts the object at screen coordinates that wrap, so a repaint
; region wraps with it and scribbles down the far edge of the screen. The
; room's own bounds turn out to be safe: swept over all 900 positions of a
; square room's floor, MIN_X never goes below 0 and MAX_X never past 32, which
; is the edge exactly. The far corner puts the centre at x = 244 and a
; three-byte sprite reaches 255 and stops.


; One character: two records, with the state that steers them in the tail of
; the first.
;
; object_record stops at SIZE_Z and leaves the rest of the slot to whatever
; comes next; the room's pool relies on the following record's ALIGN for that.
; Here the padding is written out instead, so that the pair is exactly two
; slots however it is placed. An ALIGN would not do: a label on the same line
; as a macro call takes the address BEFORE the macro's first line, so an ALIGN
; inside would leave the name pointing short of the record it names -- which
; it did, by eight bytes, and every field read came back as its neighbour.
;
; The two depth boxes stack to exactly the figure collision uses: the legs from
; his feet to CHARACTER_BODY_UP, the body from there to COLLIDE_HEIGHT. The body
; used to be twelve as well, which reached a unit above the top collision
; stops him at -- so a jump into the underside of a block left his head's box a
; unit inside it for that turn, all three axes overlapped, the sort had nothing
; to go on, and his head came out in front of the block.
				MACRO	character_record legs_base, body_base, facing
					object_record	OBJ_MOVABLE, 0, CHARACTER_HALF_U, CHARACTER_HALF_V, CHARACTER_BODY_UP
					DS		ROOM_STRIDE - OBJ.ADJ_X, 0		; the rest of the legs' slot
					object_record	OBJ_MOVABLE, 0, CHARACTER_HALF_U, CHARACTER_HALF_V, COLLIDE_HEIGHT - CHARACTER_BODY_UP
					DS		ROOM_STRIDE - OBJ.ADJ_X, 0		; ...and of the body's

					; ...and then the character's own, in the order the EQUs give
					DB		0, 0			; CHARACTER_DZ, CHARACTER_STATE
					DB		facing, 0		; CHARACTER_FACING, CHARACTER_PHASE
					DB		legs_base, body_base
					DB		$FF		; CHARACTER_DOOR: in no doorway
				ENDM


				; One whose body walks with its legs: the knight, and the
				; werewolf he turns into at night. Six body graphics to a
				; facing, the two blocks eight apart, riding twelve above.
				; The castle's soldiers and its wizard are not characters but
				; movers -- see mover_move_pair -- so this is the only kind.
				MACRO	walking_character legs_base, body_base, facing
					character_record legs_base, body_base, facing
				ENDM

					; A character's state has to fit in the slack of a slot,
					; and the record itself in a slot. Moving the
					; character-only fields out left room for the three deltas
					; the game gives every object, with bytes still spare.
					ASSERT	OBJ <= ROOM_STRIDE
					DISPLAY "object record: ", /D, OBJ, " of ", /D, ROOM_STRIDE

					; character_frame works the block out by doubling bit 1 of
					; the facing twice, so it cannot read this EQU -- which is
					; what the ASSERT is for.
					ASSERT	CHARACTER_BLOCK == 8


; Which way each facing goes, as a step in U and V.
;
; The two bits do double duty. Bit 1 picks the graphic block: clear for the
; two that walk away from the viewer, set for the two that walk towards it.
; Bit 0 says mirrored. So the order here is not free -- it has to keep the
; pairs that mirror each other next to one another.
;
; Note that the towards pair runs the other way round from the away pair. The
; two blocks are not drawn facing the same way: unmirrored, 16-21 walk to the
; left of the screen and 24-29 to the right, so the same mirror bit means the
; opposite direction in each.
;
; With screenX = U + V - 128 and the base hung off (V - U) >> 1, a step along
; +U goes down and right, +V up and right, and their negatives the other two.
; Three units a turn, which is what the game walks: move_plyr_W at $CA3A
; is ADD A,$FD and its three siblings match. The clamp still stops him
; exactly on a face, because it walks the step back a unit at a time --
; three only changes how fast the ground goes by, not where he ends up.
CHARACTER_STEP		EQU		3

character_steps:	DB		-CHARACTER_STEP, 0		; 0  -U  away, up and left
					DB		0, CHARACTER_STEP		; 1  +V  away, up and right
					DB		CHARACTER_STEP, 0		; 2  +U  towards, down and right
					DB		0, -CHARACTER_STEP		; 3  -V  towards, down and left


; Give both halves the graphics this character's facing and phase call for,
; and turn them the way it is facing.
;
; Both halves are eight graphics a block, so the block and the phase are the
; same number for each, from its own base.
;   IX -> the legs record
; Corrupts AF and C.
character_frame:	ld		a,(ix+CHARACTER_FACING)
					and		2		; the block: away from the viewer, or
					add		a		; towards it, as 0 or 2...
					add		a		; ...* 4, as 0 or CHARACTER_BLOCK
					add		a,(ix+CHARACTER_PHASE)
					ld		c,a
					add		a,(ix+CHARACTER_LEGS)
					ld		(ix+OBJ.GFX),a
					ld		a,c
					call	player_glance_body		; the knight's may be aside
					add		a,(ix+CHARACTER_BODY_G)
					ld		(ix+CHARACTER_BODY+OBJ.GFX),a

					; Bit 0 of the facing is the mirror, in both halves.
					ld		a,(ix+CHARACTER_FACING)
					rrca			; carry: mirrored, and fall into...


; Turn a pair of records -- IX and the one ROOM_STRIDE above it -- to face
; the way the carry says: set for mirrored, clear for not. Every other flag
; bit is kept: RRA parks the carry in bit 7 and RLCA brings it round into bit
; 0, which is where the flip bit lives, and leaves it in the carry again for
; the second record. mover_guard_face jumps in here too.
;   IX -> the first record, carry = the flip wanted
; Corrupts AF.
					ASSERT	OBJ_FLIP_BIT == 0 && CHARACTER_BODY == ROOM_STRIDE
obj_pair_flip:		ld		a,(ix+OBJ.FLAGS)
					rra
					rlca
					ld		(ix+OBJ.FLAGS),a
					ld		a,(ix+ROOM_STRIDE+OBJ.FLAGS)
					rra
					rlca
					ld		(ix+ROOM_STRIDE+OBJ.FLAGS),a
					ret


; Put a character in the room that has just been built.
;   IX -> its legs record
;   B  - U, C - V, A - the Z its legs stand at
character_add:		ld		(ix+OBJ.U),b
					ld		(ix+OBJ.V),c
					ld		(ix+OBJ.Z),a
					ld		(ix+CHARACTER_BODY+OBJ.U),b
					ld		(ix+CHARACTER_BODY+OBJ.V),c
					add		a,CHARACTER_BODY_UP
					ld		(ix+CHARACTER_BODY+OBJ.Z),a
					xor		a
					ld		(ix+CHARACTER_PHASE),a
					ld		(ix+CHARACTER_DZ),a		; on the floor, and staying
					ld		(ix+CHARACTER_STATE),a		; there until asked
					dec		a
					ld		(ix+CHARACTER_DOOR),a		; and in no doorway

					; A fresh start: the rotation buffers went back with the
					; old room's arena, and OBJ_SHIFTED with them.
					ld		(ix+OBJ.FLAGS),OBJ_MOVABLE
					ld		(ix+CHARACTER_BODY+OBJ.FLAGS),OBJ_MOVABLE
					call	character_frame		; which puts the mirror bit back

					call	.half
					ld		bc,CHARACTER_BODY
					add		ix,bc
					call	.half
					ld		bc,-CHARACTER_BODY
					add		ix,bc

					; And paint him. room_show drew the room before he was put
					; in it -- the characters join the list after room_build,
					; because nothing may go into a room that was not built --
					; so without this he is in the sort and on nobody's screen,
					; and stays invisible until something repaints over him: his
					; own first step, or anything else moving past and dragging
					; a region across half of him.
					call	region_reset
					call	pair_region_add
					jp		redraw_view

					; One half: placed where it stands and threaded into the sort.
					; Its rotation buffer is character_keep's, taken once at the
					; start of the game and kept, so there is none to ask for here.
.half:				call	character_place
					jp		depth_insert


; The knight's two rotation buffers, taken once at the start of the game and
; kept for good -- see shift_kept. Sized for the largest frame either half will
; ever show rather than whatever it shows first: the legs walk in frames no
; taller than 3x21 but die and come back as sparkles of 3x24, and his top half
; is at most 3x21 as a knight and 3x29 as a wolf. (Those are the trimmed
; heights. This was sprite_048 for the legs, 3x25 until its blank rows came
; off -- and 3x21 is three rows short of a sparkle, which then spilled into the
; body's buffer as a smear under every death and every arrival.)
;   IX -> the legs record
; Corrupts AF, BC, DE, HL.
character_keep:		ld		(ix+OBJ.BUF_L),0
					ld		(ix+OBJ.BUF_H),0
					ld		hl,CHARACTER_LARGEST
					call	shift_alloc
					ld		bc,CHARACTER_BODY
					add		ix,bc
					ld		(ix+OBJ.BUF_L),0
					ld		(ix+OBJ.BUF_H),0
					ld		hl,CHARACTER_TALLEST		; he may be a wolf by the time
					call	shift_alloc		; this one is wanted
					ld		bc,-CHARACTER_BODY
					add		ix,bc
					ld		hl,(shift_arena_next)
					ld		(shift_kept),hl
					ret


; Walk a character one step in facing A, and repaint what that disturbed.
;   IX -> the legs record
;   A  - the facing, 0 to 3
character_walk:		ld		(ix+CHARACTER_FACING),a

					; The step for this facing, found while A still holds it:
					; nothing from here to the load touches HL.
					add		a		; two bytes an entry
					ld		c,a
					ld		b,0
					ld		hl,character_steps
					add		hl,bc

					; The walk cycle, a frame a step. Tying it to steps rather
					; than to the clock is what keeps the feet on the ground: the
					; knight covers the same distance per frame of the cycle
					; however often he is asked to move.
					ld		a,(ix+CHARACTER_PHASE)
					inc		a
					cp		CHARACTER_PHASES
					jr		c,.phase
					xor		a
.phase:				ld		(ix+CHARACTER_PHASE),a
					call	character_frame		; which keeps HL

					ld		d,(hl)
					inc		hl
					ld		e,(hl)
					call	character_steer

					;; NB: fall through into character_walk_on


; A character that is walking always repaints, whether or not the step got
; anywhere. It has turned to face the way it was asked, and its legs have
; moved on a frame, so there is something new to draw even when a wall takes
; the whole step away -- which is what walking on the spot against a wall
; looks like, and what the game does: handle_forward at $C969 animates and
; print_sprite draws, neither of them caring whether the move came off.
character_walk_on:	call	character_settle
					jp		character_move


; And one that is only standing there repaints every turn all the same. It
; used to give up when nothing had moved it, which is what the rest of the
; engine does -- but a turn with no knight to draw is a turn that costs next
; to nothing, so the game ran at one speed walking and at a sprint standing
; still, and everything else in the room with it.
character_stand:	call	character_frame		; only the knight stands still, and
					ld		de,0		; his top half looks about while he does
					call	character_settle
					jp		character_move


; What a turn does to a character before anything is drawn: gravity proposes a
; step in Z, the clamp cuts the whole step down to what fits, and the landing
; is settled against what had to give.
;   IX -> the legs record
;   D  - the step it would like in U, E the step in V
character_settle:	; Anything that ran into us since our last turn left its step
					; in our record, and it ADDS to what we meant to do rather than
					; replacing it -- calc_plyr_dXY combines them the same way, and
					; so a knight walking east while a block shoves him north goes
					; north-east. It is good for this one turn.
					ld		a,(ix+OBJ.DU)
					add		a,d
					ld		d,a
					ld		a,(ix+OBJ.DV)
					add		a,e
					ld		e,a

					call	character_gravity
					call	character_collide
					ld		(ix+OBJ.DU),0	; spent, so the next turn starts clean
					ld		(ix+OBJ.DV),0
					jp		character_land


; Everything a character does in a turn once the step along the floor is known.
;
;   IX -> the legs record
;   D  - the step it would like in U, E the step in V
;   (character_jump_held) - whether the jump key is down, which is what makes
;                           the difference between a short hop and a long one
;
; Falling is not a special case here: gravity proposes a step in Z every turn
; and the clamp cuts it to nothing while there is ground under the feet.
; Move both halves by D in U and E in V, and repaint the one region.
;   IX -> the legs record
;
; A character is one thing in two records, so he repaints as one region. Doing
; a half at a time flickered along his waist: the legs and the body overlap by
; six rows, and repainting the legs composites the body wherever it is at that
; moment -- which, halfway through a step, is still where it was. The body's
; own repaint put it right, but not before the raster had had a chance to show
; the wrong one.
character_move:		ld		a,(ix+OBJ.DZ)		; the body rides with the legs, and
					ld		(ix+CHARACTER_BODY+OBJ.DZ),a		; reads its own copy

character_move_go:	call	region_reset
					call	pair_region_add		; where he was

					; Both halves take the same step. It is already everything it is
					; allowed to be -- the room's walls and everything standing in it
					; were taken out of it by character_collide -- and it is D and E,
					; not the records' DU and DV, which character_settle has spent.
					; The body shares the legs' DZ: character_move copies it across.
					;
					; The legs are re-sorted against the whole run, and the body after
					; them, which depth_step_upper explains.
					push	de
					ld		a,(ix+OBJ.DZ)
					call	depth_step
					call	character_place
					push	ix
					pop		hl		; the legs
					ld		bc,CHARACTER_BODY
					add		ix,bc
					pop		de
					ld		a,(ix+OBJ.DZ)
					call	depth_step_upper
					call	character_place

					ld		bc,-CHARACTER_BODY
					add		ix,bc
					call	pair_region_add		; and where he is now
					jp		redraw_defer


; Add both records of a pair -- IX and the one ROOM_STRIDE above it -- to the
; region, and come back with IX where it was. A character's legs and body are a
; pair, and so are a guard's torso and legs.
;   IX -> the first record
; Corrupts AF, BC, HL.
					ASSERT	CHARACTER_BODY == ROOM_STRIDE
pair_region_add:	call	region_add
					ld		bc,ROOM_STRIDE
					add		ix,bc
					call	region_add
					ld		bc,-ROOM_STRIDE
					add		ix,bc
					ret


; Whether the jump key is down this turn. Gravity asks, because how long it is
; held is how high the jump goes.
character_jump_held:	DB		0


; Start a jump, if this is a moment one may be started. Not in a doorway: the
; arch's top is only a little above his head, and a jump carried him up through
; it. CHARACTER_DOOR is 0 to 3 for a doorway and $FF for none, so bit 7 is the
; test, which leaves A alone. Only the knight ever has one set, so this costs
; nobody else anything; player_step finds it before it reads the keys.
;   IX -> the legs record
; Corrupts AF.
character_jump:		bit		0,(ix+CHARACTER_STATE)
					ret		nz		; already in the air
					bit		7,(ix+CHARACTER_DOOR)
					ret		z		; standing in a doorway
					ld		a,(ix+CHARACTER_DZ)
					inc		a
					ret		m		; falling faster than a unit a turn: too
					; late to call it a jump. Knight Lore
					; makes the same test at $C956.
					set		0,(ix+CHARACTER_STATE)
					ld		(ix+CHARACTER_DZ),CHARACTER_JUMP_DZ
					push	af		; player_step reads A back as the key
					call	sound_jump		; handle_jump's audio_B441
					pop		af
					ret


; Turn the character's velocity into this turn's proposed step in Z.
;   IX -> the legs record
; Corrupts AF and B.
character_gravity:	ld		a,(character_jump_held)
					ld		b,a
					ld		a,(ix+CHARACTER_DZ)
					or		a
					jp		m,.heavy		; on the way down already
					inc		b
					dec		b
					jr		z,.heavy		; on the way up, but let go of
					dec		a		; ...still held: half as much
					jr		.limit
.heavy:				dec		a
					dec		a
.limit:				jp		p,.store		; only a fall needs limiting
					cp		CHARACTER_FALL_MAX
					jr		nc,.store
					ld		a,CHARACTER_FALL_MAX
.store:				ld		(ix+CHARACTER_DZ),a
					ld		(ix+OBJ.DZ),a		; what it would like to do; the
					add		a,2		; clamp says what it may -- and falling
					ret		p		; faster than two a turn whistles, as
					jp		sound_z		; it does at $C9D6


; Settle the vertical state against what the clamp had to do.
;   IX -> the legs record
; Corrupts AF.
character_land:		ld		a,(collide_hit)
					and		COLLIDE_Z
					ret		z		; nothing stopped us in Z

					; Coming down, that is the ground and the jump is over.
					; Going up it is the underside of something, and all that
					; happens is that the rise stops -- the jump flag stays
					; set, so letting go of the key still does what it would
					; have done. Knight Lore ends a jump on the same pair of
					; conditions, at $C9E2.
					ld		a,(ix+CHARACTER_DZ)
					or		a
					ld		(ix+CHARACTER_DZ),0		; LD leaves the flags alone
					ret		p		; was on the way up: a bumped head
					res		0,(ix+CHARACTER_STATE)
					ret


; Is this character standing in one of the room's doorways, and which?
;   IX -> the legs record
; Corrupts AF, BC, DE, HL.
;
; An arch's opening is a box around a point on the wall: six units either side
; of the room's middle, fifteen either side of the arch, and from three below
; its floor to twelve above it. The height is what keeps a knight on the
; floor of a tall room out of the high arch on its walkway, and a knight on the
; walkway out of the floor.
character_door_find:
					ld		(ix+CHARACTER_DOOR),$FF
					ld		c,0

.side:				ld		b,0
					ld		hl,room_door_z
					add		hl,bc
					ld		a,(hl)
					or		a
					jr		z,.next		; no door on this side

					ld		a,(ix+OBJ.Z)
					sub		(hl)
					add		a,DOOR_LEVEL - 1
					cp		DOOR_LEVEL - 1 + DOOR_HEIGHT
					jr		nc,.next		; below it or above it: the wrong storey

					; North and south face along V, east and west along U; the
					; other axis is the one across the opening.
					ld		e,(ix+OBJ.U)
					ld		a,(ix+OBJ.V)
					bit		0,c
					jr		z,.along
					ld		e,(ix+OBJ.V)
					ld		a,(ix+OBJ.U)
.along:				ld		hl,room_door_at
					add		hl,bc
					sub		(hl)
					call	.abs
					cp		DOOR_ALONG
					jr		nc,.next		; not up to the wall yet

					ld		a,e
					sub		128		; the opening is centred on the room
					call	.abs
					cp		DOOR_ACROSS
					jr		nc,.next		; beside it, not in it

					ld		(ix+CHARACTER_DOOR),c
					ret		

.next:				inc		c
					ld		a,c
					cp		4
					jr		c,.side
					ret		

					; B has to survive this -- it is the top of the index.
.abs:				or		a
					ret		p
					neg		
					ret		


; Walking near an arch lines him up with it. Every arch in Knight Lore looks for
; the knight inside a box fifteen units either way of its centre and four in
; height, and nudges him one unit a turn along its wall, towards the middle of
; the opening: along U for an arch in the north or south wall, along V for one
; in the east or west. adj_ew and adj_ns at $C7A6, and the choice between them
; goes through adj_arch_tbl by the ARCH's graphic and mirror bit -- IX is still
; the arch when get_sprite_dir reads them -- which is what a north or south
; arch's mirroring selects. It is never across the wall, whichever way he
; faces: walking along the north wall past its arch, the game only lengthens
; his step towards the middle and shortens it after, and he walks straight on.
; Taking the axis from his facing instead pulled him into the doorway.
; calc_plyr_dXY adds the nudge to his step, which is why it only happens while
; he walks.
;
; An arch's centre is the room's doorway table all over again: the wall it
; stands in on its own axis, and the middle of the room on the other.
;   IX -> the legs record
;   D, E - the step for his facing, which this may add a unit to
; Corrupts AF, BC, HL.
character_steer:	ld		c,0
.side:				ld		b,0
					ld		hl,room_door_z
					add		hl,bc
					ld		a,(hl)
					or		a
					jr		z,.next		; no arch this side
					sub		(ix+OBJ.Z)
					call	character_door_find.abs
					cp		DOOR_LEVEL
					jr		nc,.next

					ld		hl,room_door_at
					add		hl,bc
					ld		l,(hl)
					ld		h,128		; H = its centre U, L = its centre V, for
					bit		0,c		; north and south, which stand in a wall
					jr		z,.centred		; across V
					ld		a,h
					ld		h,l
					ld		l,a		; ...and the other way round for east and west

.centred:			ld		a,(ix+OBJ.U)
					sub		h
					call	character_door_find.abs
					cp		DOOR_ALONG
					jr		nc,.next
					ld		a,(ix+OBJ.V)
					sub		l
					call	character_door_find.abs
					cp		DOOR_ALONG
					jr		nc,.next

					bit		0,c
					jr		z,.along_u
					ld		a,l		; east or west: V towards its centre
					cp		(ix+OBJ.V)
					ret		z
					ld		a,1
					jr		nc,.v
					neg
.v:					add		a,e
					ld		e,a
					ret
.along_u:			ld		a,h		; north or south: U towards its centre
					cp		(ix+OBJ.U)
					ret		z
					ld		a,1
					jr		nc,.u
					neg
.u:					add		a,d
					ld		d,a
					ret

.next:				inc		c
					ld		a,c
					cp		4
					jr		c,.side
					ret


; Cut a character's step down to what the room allows.
;
;   IX -> the legs record
;   D  - the step it would like in U, E the step in V
; Returns them cut to what fits, and collide_hit saying which axes gave.
;
; Two things stop a character. The room's own edges are a plain range test:
; walk out of one and the projection puts the figure at screen coordinates
; that wrap, and a repaint region wraps with them and scribbles down the far
; side of the screen. Then everything standing in the room, which is
; object_collide's business.
;
; Corrupts AF, BC, HL, IY.
					; The room first. Knight Lore's test, at $CCEC: a room is
					; centred on 128 and room_half_u says how far its floor
					; reaches, so the distance from that centre plus our own half
					; has to stay inside it. Symmetric by construction, which a
					; pair of hand-picked limits was not -- the old ones sat 56
					; below the centre and 52 above, which is why he could walk
					; further one way than the other.
					;
					; And the step is walked back a unit at a time rather than
					; thrown away, so he ends up against the wall rather than
					; wherever the last whole step left him -- which with a step
					; of three could be two units short.
character_collide:	; Unless he is in a doorway, in which case neither edge
					; applies and he can walk straight out. Knight Lore opens
					; both of its bound checks with the same test and the same
					; bit -- $CCE3 for X and $CD0E for Y -- and it is the whole
					; of how the knight ever leaves a room.
					ld		a,(ix+CHARACTER_DOOR)
					inc		a
					jr		z,object_collide_room
					xor		a		; in a doorway: no edge cut anything
					ld		(collide_bound),a
					jr		object_collide_free


; The same, for anything at all: the room's edges, then its floor, then
; everything standing in it. A mover comes straight in here -- Knight Lore's
; adj_for_out_of_bounds at $CB45 is one routine for every object too.
;   IX -> the record
;   D  - the step it would like in U, E the step in V
object_collide_room:	xor		a
					ld		(collide_bound),a
					call	object_bound_uv
					call	object_collide_free

					; And the edges again, on what came back. The clamp can ADD a step
					; that the first pass never saw: object_carry hands a passenger the
					; step of whatever it is standing on, during the Z pass, which is
					; after the edges have had their say. Knight Lore does not need this
					; because it checks each axis's edge after the Z pass rather than all
					; of them up front -- but it needs checking somewhere, or a ghost six
					; units wide carries a block eight units wide clean through the wall.
					ld		d,(ix+OBJ.DU)
					ld		e,(ix+OBJ.DV)
					call	object_bound_uv
					ld		(ix+OBJ.DU),d
					ld		(ix+OBJ.DV),e
					ret		


; Cut a step down to what the room's own edges allow.
;   IX -> the record, D the step in U, E the step in V
;
; Both axes go through one piece of code: IY on the record for U and one byte
; along for V, where the U fields name the V ones, HL on room_half_u and then
; room_half_v, C the bit, and the step in D -- E is swapped into D for V and back.
; Corrupts AF, C, HL, IY.
					ASSERT	OBJ.V == OBJ.U + 1 && OBJ.SIZE_V == OBJ.SIZE_U + 1
					ASSERT	room_half_v == room_half_u + 1 && COLLIDE_V == COLLIDE_U << 1
object_bound_uv:	push	ix
					pop		iy
					ld		hl,room_half_u
					ld		c,COLLIDE_U
					call	.axis		; U, in D
					inc		iy
					inc		hl
					sla		c
					ld		a,d
					ld		d,e
					ld		e,a
					call	.axis		; V, in D for now
					ld		a,d
					ld		d,e
					ld		e,a
					ret

.axis:				ld		a,(iy+OBJ.U)
					add		a,d
					sub		128		; distance from the room's centre
					jp		p,.abs
					neg
.abs:				add		a,(iy+OBJ.SIZE_U)
					cp		(hl)
					ret		c		; still inside
					ld		a,(collide_bound)		; the wall is in the way, and whatever
					or		c		; walked into it may want to know
					ld		(collide_bound),a
					ld		a,d
					or		a
					ret		z		; nothing left to give
					jp		m,.back
					dec		d
					jr		.axis
.back:				inc		d
					jr		.axis


; The floor and everything standing in the room, with the edges already
; settled or deliberately not applied.
object_collide_free:
					; And the floor, which is not an object -- nothing in a room
					; stands for the ground, so a fall has to be stopped here or
					; it never ends. Knight Lore does exactly this at $CA5A,
					; against the room's own floor at $5BAE -- which is what
					; room_shape has been working out into room_floor_z all
					; along and nothing was reading.
					ld		a,(room_floor_z)
					ld		b,a
					ld		a,(ix+OBJ.DZ)
					add		a,(ix+OBJ.Z)
					cp		b
					jr		nc,.above_floor
					ld		a,b
					sub		(ix+OBJ.Z)		; only as far as the floor
					ld		(ix+OBJ.DZ),a
					ld		a,COLLIDE_Z
					jr		.floor_done
.above_floor:		xor		a
.floor_done:		ld		hl,collide_bound
					or		(hl)
					ld		(hl),a

					ld		(ix+OBJ.DU),d
					ld		(ix+OBJ.DV),e

					call	object_collide

					; The floor counts as something having stopped us, the same
					; as a block would, so that character_land sees it.
					ld		a,(collide_bound)
					ld		hl,collide_hit
					or		(hl)
					ld		(hl),a

					ld		d,(ix+OBJ.DU)
					ld		e,(ix+OBJ.DV)
					ret


; One half, moved: work out where it now lands on the screen. The caller
; repaints.
;
; The graphic changed with the phase, so the nudge that lines its artwork up may
; have changed with it -- and it certainly has if the character has just turned
; round.
;   IX -> the record
character_place:	call	room_adjust
					jp		object_place
