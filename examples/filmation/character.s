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
CHARACTER_TICKS		EQU		3		; frames each frame of it is held for
					; A walking body rides twelve above the legs, the same
					; twelve Knight Lore uses -- see walking_character. They
					; meet because the game nudges the two by different amounts
					; as well: sprite_adj has -6 for the legs and -8 for the
					; body and calc_screen_xy subtracts that, so the body lands
					; two pixels lower than its Z alone would put it.
CHARACTER_BODY_UP	EQU		12		; how far every body rides above its legs,
					; the same twelve Knight Lore gives the
					; knight. Z is what the depth sort reads, so
					; the height belongs here and not in the
					; pixel nudge -- see ADJ_LIFT.
CHARACTER_Z			EQU		128		; the floor

; How far a character may walk before the wall stops it.
;
; Provisional. The right answer is room_size_tbl, which gives each room shape
; its floor in U and V -- room_shape reads that table already but keeps only
; the Z. Until the two are wired through, these are the numbers the room looks
; right at: the blocks stand at 88 to 168 and the walls at 59 and 196, so the
; floor between them is about this.
;
; Something has to stop it, though. Walk out of the room and the projection
; puts the object at screen coordinates that wrap, so a repaint region wraps
; with it and scribbles down the far edge of the screen. The upper bound is
; not a matter of taste: the worst case is U and V both at it, where
; x = U + V - 128 is largest, and a 3-byte sprite from there has to stay under
; 256 or the repaint region wraps to the far side of the screen. That puts the
; ceiling at 180. The floor is where x would go negative, 64, with a little to
; spare.
FLOOR_LO			EQU		72
FLOOR_HI			EQU		180


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
				MACRO	character_record legs_base, body_base, body_block, body_phase, body_lift, facing
					object_record	OBJ_MOVABLE, 0, 6, 6, 12
					DS		OBJ.FACING - OBJ.ADJ_X, 0		; ADJ_X, ADJ_Y, GFX
					DB		facing, 0, CHARACTER_TICKS
					DB		legs_base, body_base
					DB		body_block, body_phase, 0		; the legs' nudge stands as it is
					DS		ROOM_STRIDE - OBJ, 0		; out to a whole slot
					object_record	OBJ_MOVABLE, 0, 6, 6, 12
					DS		OBJ.ADJ_LIFT - OBJ.ADJ_X, 0
					DB		body_lift		; ...and the body's may not
					DS		ROOM_STRIDE - OBJ, 0
				ENDM


				; One whose body walks with its legs: the knight, and the
				; werewolf he turns into at night. Six body graphics to a
				; facing, the two blocks eight apart, riding twelve above.
				MACRO	walking_character legs_base, body_base, facing
					character_record legs_base, body_base, CHARACTER_BLOCK, $FF, 0, facing
				ENDM

				; And one whose body is a single frame each way round, held
				; still over the same walking legs -- the castle's soldier and
				; its wizard, who share the knight's boots and bring their own
				; top half. Their body sits at the legs' own Z and is lifted
				; by its pixel nudge instead of by Z, which is why it rides
				; nothing: the game gives graphic 30 a nudge of +3 against the
				; legs' -6, and calc_screen_xy subtracts both.
				MACRO	standing_character legs_base, body_base, facing
					character_record legs_base, body_base, 1, $00, -CHARACTER_BODY_UP, facing
				ENDM

					; A character's state has to fit in the slack of a slot.
					ASSERT	OBJ <= ROOM_STRIDE

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
character_steps:	DB		-1, 0		; 0  -U  away, up and left
					DB		0, 1		; 1  +V  away, up and right
					DB		1, 0		; 2  +U  towards, down and right
					DB		0, -1		; 3  -V  towards, down and left


; Give both halves the graphics this character's facing and phase call for,
; and turn them the way it is facing.
;   IX -> the legs record
; Corrupts AF, B and C.
character_frame:	ld		a,(ix+OBJ.FACING)
					and		2		; the block: away from the viewer, or
					rrca			; towards it, as 0 or 1
					ld		b,a

					add		a		; legs are always eight graphics a block
					add		a
					add		a		; * CHARACTER_BLOCK
					add		a,(ix+OBJ.PHASE)
					add		a,(ix+OBJ.LEGS_BASE)
					ld		(ix+OBJ.GFX),a

					; The body's block is its own -- eight for a body that
					; walks, one for a body that is a single frame each way
					; round -- and the phase reaches it through a mask, so a
					; still body simply never moves off its first frame.
					ld		c,0
					bit		0,b
					jr		z,.first_block
					ld		c,(ix+OBJ.BODY_BLOCK)
.first_block:		ld		a,(ix+OBJ.PHASE)
					and		(ix+OBJ.BODY_PHASE)
					add		a,c
					add		a,(ix+OBJ.BODY_BASE)
					ld		(ix+CHARACTER_BODY+OBJ.GFX),a

					; Bit 0 of the facing is the mirror, in both halves.
					bit		0,(ix+OBJ.FACING)
					jr		nz,.mirrored
					res		OBJ_FLIP_BIT,(ix+OBJ.FLAGS)
					res		OBJ_FLIP_BIT,(ix+CHARACTER_BODY+OBJ.FLAGS)
					ret
.mirrored:			set		OBJ_FLIP_BIT,(ix+OBJ.FLAGS)
					set		OBJ_FLIP_BIT,(ix+CHARACTER_BODY+OBJ.FLAGS)
					ret


; Put a character in the room that has just been built.
;   IX -> its legs record
;   B  - U, C - V
character_add:		ld		(ix+OBJ.PHASE),0
					ld		(ix+OBJ.TICK),CHARACTER_TICKS
					ld		(ix+OBJ.U),b
					ld		(ix+OBJ.V),c
					ld		(ix+OBJ.Z),CHARACTER_Z
					ld		(ix+CHARACTER_BODY+OBJ.U),b
					ld		(ix+CHARACTER_BODY+OBJ.V),c
					ld		(ix+CHARACTER_BODY+OBJ.Z),CHARACTER_Z + CHARACTER_BODY_UP

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
					ret

.half:				ld		(ix+OBJ.BUF_L),0
					ld		(ix+OBJ.BUF_H),0
					call	room_adjust
					call	character_lift
					ld		a,(ix+OBJ.GFX)
					call	object_place
					jp		depth_insert


; Walk a character one step in facing A, and repaint what that disturbed.
;   IX -> the legs record
;   A  - the facing, 0 to 3
character_walk:		ld		(ix+OBJ.FACING),a

					; The walk cycle, a frame every CHARACTER_TICKS. Tying it
					; to steps rather than to the clock is what keeps the feet
					; on the ground: the knight covers the same distance per
					; frame of the cycle however often he is asked to move.
					dec		(ix+OBJ.TICK)
					jr		nz,.same_frame
					ld		(ix+OBJ.TICK),CHARACTER_TICKS
					inc		(ix+OBJ.PHASE)
					ld		a,(ix+OBJ.PHASE)
					cp		CHARACTER_PHASES
					jr		c,.same_frame
					ld		(ix+OBJ.PHASE),0
.same_frame:		call	character_frame

					; The step for this facing.
					ld		a,(ix+OBJ.FACING)
					add		a		; two bytes an entry
					ld		c,a
					ld		b,0
					ld		hl,character_steps
					add		hl,bc
					ld		d,(hl)
					inc		hl
					ld		e,(hl)
		;; NB: fall through


; Move both halves by D in U and E in V, and repaint the one region.
;   IX -> the legs record
;
; A character is one thing in two records, so he repaints as one region. Doing
; a half at a time flickered along his waist: the legs and the body overlap by
; six rows, and repainting the legs composites the body wherever it is at that
; moment -- which, halfway through a step, is still where it was. The body's
; own repaint put it right, but not before the raster had had a chance to show
; the wrong one.
character_move:		call	region_reset
					call	region_add		; where he was
					ld		bc,CHARACTER_BODY
					add		ix,bc
					call	region_add
					ld		bc,-CHARACTER_BODY
					add		ix,bc

					; The lower half is re-sorted against the whole run. The upper
					; one starts from wherever the lower ended up, which Head Over
					; Heels does too, in EnlistAux, and for the same reason: the two
					; share U and V and the upper is the nearer, so it can never
					; belong in front of the lower. Everything the scan would compare
					; on its way down to the lower half it answers the same way for
					; the upper -- so this is not a shortcut past the walk, it is the
					; rest of it.
					push	de
					ld		hl,0
					ld		(relink_from),hl
					call	character_half
					push	ix
					pop		hl		; the lower half is its own NEXT field
					ld		(relink_from),hl
					ld		bc,CHARACTER_BODY
					add		ix,bc
					pop		de
					call	character_half

					call	region_add		; and where he is now
					ld		bc,-CHARACTER_BODY
					add		ix,bc
					call	region_add
					jp		redraw_view


; One half: step it, work out where that puts it on the screen, and re-thread
; it in the sorted list. The caller repaints.
;   IX -> the record
;   D  - the step in U, E the step in V
character_half:		push	de
					call	extent_save
					pop		de
		; Work the step out, and only keep it if it lands between the walls.
		; Simpler than moving and undoing, and it does not need to know which
		; of the two axes this step was along.
					ld		a,(ix+OBJ.U)
					add		a,d
					cp		FLOOR_LO
					jr		c,.keep_u
					cp		FLOOR_HI + 1
					jr		nc,.keep_u
					ld		(ix+OBJ.U),a
.keep_u:			ld		a,(ix+OBJ.V)
					add		a,e
					cp		FLOOR_LO
					jr		c,.keep_v
					cp		FLOOR_HI + 1
					jr		nc,.keep_v
					ld		(ix+OBJ.V),a
.keep_v:
		; The graphic changed with the phase, so the nudge that lines its
		; artwork up may have changed with it -- and it certainly has if the
		; character has just turned round.
					call	room_adjust
					call	character_lift
					ld		a,(ix+OBJ.GFX)
					call	object_place
					jp		depth_relink


; Take the height back out of the nudge, for a body whose graphic was drawn
; assuming it sits at its legs' Z. See ADJ_LIFT.
;   IX -> the record, its nudge fresh from room_adjust
character_lift:		ld		a,(ix+OBJ.ADJ_LIFT)
					and		a
					ret		z
					add		a,(ix+OBJ.ADJ_Y)
					ld		(ix+OBJ.ADJ_Y),a
					ret
