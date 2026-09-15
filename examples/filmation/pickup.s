; ---------------------------------------------------------------------------
; Picking the collectables up, putting them down, and showing what is carried
; -- see special.s for the rest of them.
;
; None of this runs unless the pick-up key is down, so it lives with the view
; buffer and the object pool in contended memory rather than taking room from
; the code that runs every turn: the one test that does run every turn is a
; port read and a compare.
; ---------------------------------------------------------------------------

; ---------------------------------------------------------------------------
; The pick-up key. handle_pickup_drop, at $C00E.
;
; One press does one thing, and only once the knight is standing on something
; and inside the room's edges -- held down in the air, it waits for him to
; land. Then, if he is next to a collectable, he picks it up; if not, he puts
; one down.
;   IX -> the knight's legs
; Corrupts everything.
special_keys:		ld		bc,KEY_PICKUP
					in		a,(c)
					cpl
					and		$1F
					ld		hl,special_key_held
					jr		nz,.down
					ld		(hl),a		; let go: the next press counts
					ret
.down:				ld		a,(hl)
					or		a
					ret		nz		; this press has had its turn

					; Inside the room's edges -- chk_plyr_OOB, which keeps a knight
					; in a doorway from leaving something in it.
					ld		a,(ix+OBJ.U)
					sub		128
					jp		p,.u
					neg
.u:					add		a,(ix+OBJ.SIZE_U)
					ld		hl,room_half_u
					cp		(hl)
					ret		nc
					ld		a,(ix+OBJ.V)
					sub		128
					jp		p,.v
					neg
.v:					add		a,(ix+OBJ.SIZE_V)
					inc		hl		; room_half_v
					cp		(hl)
					ret		nc

					; And standing, not jumping or falling.
					bit		0,(ix+CHARACTER_STATE)
					ret		nz
					ld		a,(ix+CHARACTER_DZ)
					or		a
					ret		nz

					; Would he fit a box's height further up? Asked of the whole
					; room with his box moved up by twelve.
					xor		a
					ld		(special_head),a
					ld		(collide_eff_u),a
					ld		(collide_eff_v),a
					ld		a,SPECIAL_SIZE_Z
					ld		(collide_eff_z),a
					call	collide_box
					ld		iy,room_objects
					ld		a,(room_object_count)
					ld		b,a
					ld		de,ROOM_STRIDE
.head:				call	object_overlaps
					jr		c,.no_room
					ld		de,ROOM_STRIDE
					add		iy,de
					djnz	.head
					jr		.pressed
.no_room:			ld		a,1
					ld		(special_head),a

.pressed:			ld		a,1
					ld		(special_key_held),a
					call	sound_pickup		; toggle_audio_hw_x16, at pickup or drop

					; Next to one? He reaches four further than he walks, and four
					; lower.
					ld		ix,(special_slots)
					ld		b,SPECIAL_SLOTS
.look:				ld		a,(ix+OBJ.GFX)
					sub		SPECIAL_FIRST
					cp		SPECIAL_LIFE - SPECIAL_FIRST
					jr		nc,.not
					push	bc
					ld		de,SPECIAL_REACH * 257
					call	special_near
					pop		bc
					jr		c,special_pickup
.not:				ld		de,ROOM_STRIDE
					add		ix,de
					djnz	.look

					;; NB: fall through into special_drop


; Put down the oldest thing he is carrying, under his own feet, and stand him
; on it. room_to_drop, at $C0B2.
;
; It needs a free slot -- only the first, in the pot's room -- and nothing
; above his head. And if the last slot is empty there is nothing to put down,
; and the press turns the others round instead, which is how you choose what
; to drop.
special_drop:		ld		ix,(special_slots)
					ld		a,(ix+OBJ.GFX)
					or		a
					jr		z,.free
					ld		a,(room_shown)
					cp		SPECIAL_POT_ROOM
					ret		z
					ld		de,ROOM_STRIDE
					add		ix,de
					ld		a,(ix+OBJ.GFX)
					or		a
					ret		nz

.free:				ld		a,(special_carried + 6)
					or		a
					jp		z,special_shift
					ld		a,(special_head)
					or		a
					ret		nz

					; Standing on the pot in its own room, it goes in.
					ld		a,(room_shown)
					cp		SPECIAL_POT_ROOM
					jr		nz,.lift
					ld		a,(player + OBJ.Z)
					cp		SPECIAL_POT_TOP
					jr		c,.lift
					ld		a,1
					ld		(special_busy),a

					; Up with him first and in with it after, so that when it is
					; sorted he is already clear of it.
.lift:				push	ix
					ld		hl,player + OBJ.U
					ld		de,special_where_at
					ld		bc,3
					ldir
					ld		ix,player
					ld		(ix+OBJ.DZ),SPECIAL_SIZE_Z
					ld		de,0
					call	character_move
					pop		ix

					ld		a,(special_busy)
					or		a
					ld		a,(special_carried + 6)
					jr		z,.plain
					add		a,SPECIAL_FLIGHT
.plain:				ld		hl,special_carried + 7
					ld		c,(hl)
					ld		b,MOVE_SPECIAL
					ld		hl,special_where_at
					call	special_fill
					jp		special_shift

special_where_at:	DS		3


; Pick up the one in IX. pickup_object, at $C141.
;
; If all three places are full, the oldest is put down where the new one was
; -- the same record, redrawn with the other graphic.
special_pickup:		xor		a		; and a room's spiked balls may drop now,
					ld		(spike_ball_held),a	; as pickup_object says
					ld		a,(ix+OBJ.GFX)
					ld		(special_carried),a
					ld		a,(ix+OBJ.MOVE_STATE)
					ld		(special_carried + 1),a
					call	special_row_gone
					ld		a,(special_carried + 6)
					or		a
					jr		z,.gone
					ld		(ix+OBJ.GFX),a
					ld		a,(special_carried + 7)
					ld		(ix+OBJ.MOVE_STATE),a
					call	region_reset
					call	region_add
					call	room_adjust
					call	object_place
					call	region_add
					call	redraw_view
					jr		special_shift
.gone:				call	special_hide

					;; NB: fall through into special_shift


; Move everything carried on a place, the last one dropping off the end, and
; show the result. adjust_carried, at $C12B.
special_shift:		ld		hl,special_carried + 5
					ld		de,special_carried + 7
					ld		bc,6
					lddr
					xor		a
					ld		(special_carried),a
					ld		(special_carried + 1),a

					;; NB: fall through into special_show


; Draw what the knight is carrying in the bottom-left corner: three places of
; three characters by three, each in its own colour. display_objects, at $BF4E.
;
; Straight to the screen, as the room number is. A region reaching the corner
; wipes them, so redraw_view calls back in here when one does.
special_show:		ld		hl,special_carried + 2
					ld		bc,3 << 8 | 2	; three slots, and the character column
.slot:				push	bc
					push	hl
					ld		a,(hl)
					call	special_show_one
					pop		hl
					pop		bc
					inc		hl
					inc		hl
					ld		a,c
					add		a,3
					ld		c,a
					djnz	.slot
					ret

;   A - the graphic, or 0 for none
;   C - the character column
special_show_one:	push	af

					; Its colour, three by three.
					and		15
					ld		e,a
					ld		d,0
					ld		hl,special_colours
					add		hl,de
					ld		e,(hl)
					ld		hl,$5800 + 21 * 32
					ld		a,l
					add		a,c
					ld		l,a
					ld		b,3
.attr:				ld		(hl),e
					inc		hl
					ld		(hl),e
					inc		hl
					ld		(hl),e
					ld		a,l
					add		a,30
					ld		l,a
					jr		nc,.attr_on
					inc		h
.attr_on:			djnz	.attr

					; Blank the place: the bottom 24 rows, three bytes across. A row at
					; a time through pixelAddress, which hands back the screen's own
					; arrangement of rows rather than one row every 32 bytes.
					ld		a,c
					add		a,a
					add		a,a
					add		a,a
					ld		c,a		; x, in pixels
					ld		b,SCREEN_ROWS - 24
.blank:				call	pixelAddress
					xor		a
					ld		(hl),a
					inc		hl
					ld		(hl),a
					inc		hl
					ld		(hl),a
					inc		b
					ld		a,b
					cp		SCREEN_ROWS
					jr		c,.blank
					pop		af
					or		a
					ret		z

					; The graphic, the right way round and standing on the bottom row.
					push	bc
					ld		l,a
					ld		h,(high sprite_table) / 2
					add		hl,hl
					ld		a,(hl)
					inc		l
					ld		h,(hl)
					ld		l,a
					bit		0,(hl)		; SPRITE_FLIPPED
					jr		z,.oriented
					call	sprite_flip_h		; which keeps HL
.oriented:			pop		bc
					ld		a,(hl)
					sprite_width_class
					add		a,2
					ld		(.columns+1),a
					inc		hl
					ld		a,SCREEN_ROWS
					sub		(hl)		; its top row
					ld		b,a
					inc		hl

.rows:				ex		de,hl		; DE -> the bitmap
					call	pixelAddress
					push	bc
.columns:			ld		b,0		; patched: the width
.column:			ld		a,(de)		; mask
					inc		de
					and		(hl)
					ld		c,a
					ld		a,(de)		; and bitmap
					inc		de
					xor		c
					ld		(hl),a
					inc		hl
					djnz	.column
					pop		bc
					ex		de,hl
					inc		b
					ld		a,b
					cp		SCREEN_ROWS
					jr		c,.rows
					ret
