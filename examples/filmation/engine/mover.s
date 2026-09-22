; ---------------------------------------------------------------------------
; The mover framework. Every object in the room's pool whose behaviour is
; BEHAVIOUR_FIRST_TURN or above gets a turn, through the game's mover_tbl --
; one address a behaviour -- and these are the routines a turn is built from.
; The behaviours themselves are the game's own movers.s, and those more than
; one game has are in movers.s beside this file.
;
; mover_move comes first on purpose. The game's movers.s ends with a behaviour
; that falls through into it, and knightlore.s includes this file straight
; after that one.
; ---------------------------------------------------------------------------

MOVER_PAIR			EQU		ROOM_STRIDE		; a two-record figure's second record

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
mover_clamp:		ld		hl,walker_player	; the character is not in the room's
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

					ASSERT	MOVER_PAIR == ROOM_STRIDE
					call	region_reset
					call	pair_region_add		; the torso and the legs, where they were

					ld		a,(ix+OBJ.U)
					add		a,(ix+OBJ.DU)
					ld		c,a
					ld		a,(ix+OBJ.V)
					add		a,(ix+OBJ.DV)
					ld		b,a

					ld		de,MOVER_PAIR
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
					ld		bc,MOVER_PAIR		; sorts after
					add		hl,bc
					ld		ix,(mover_ix)
					ld		d,(ix+OBJ.DU)
					ld		e,(ix+OBJ.DV)
					ld		a,(ix+OBJ.DZ)
					call	depth_step_upper
					call	room_adjust
					call	object_place

					ld		ix,(mover_ix)
					call	pair_region_add		; and where they are now
					call	redraw_defer
					ld		ix,(mover_ix)
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
					sub		BEHAVIOUR_FIRST_TURN	; the ones below it have no turn,
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


; How many turns have gone by. Every mover in the castle is driven from this
; one number, which is what keeps them all in step with each other -- Knight
; Lore reads its frame counter at $5BA2 the same way.
move_tick:			DB		0


; The record being updated, kept because object_place and depth_relink are
; both free to corrupt IX.
mover_ix:			DW		0


; The seed mover_rand stirs.
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
