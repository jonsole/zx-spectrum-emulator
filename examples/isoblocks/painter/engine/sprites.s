; isoblocks: sprites for the painter.
;
; A sprite stands in a cell at a height, like a block, and its 16 x 16 picture
; goes where that block's would. So it is painted in that block's turn: in
; the painter's order -- lowest height first, and within a height, place by
; place -- at the place a block in its cell and height would be. Whatever is
; painted after it covers it, as it would the block, and it covers whatever
; was painted before, with no depth test. The blocks sort_places leaves out as
; covered whole stay rightly left out: what covers one is painted after it,
; and covers the sprite there too if the sprite came between.
; shared/isogeom.py's render does the same, and check.py compares.
;
; View 0 only, so far: sprite_key works a sprite's place out in view 0's
; terms (a cell's place is a + 16b + 32r, r its row and b its half-row).
;
; A sprite is four bytes in sprites: x, y, height and its picture's number,
; $FF for none. The pictures are sprite_pictures (build.py): 16 rows of the
; left byte's mask and ink, then the right's.
;
; A frame: order_sprites after view_update; then paint, which calls
; paint_next_sprite in each one's turn.

SPRITE_MAX			EQU		4
					ASSERT	SPRITE_MAX == 4		; order_sprites sorts four
SPRITE_NONE			EQU		64			; a list past the last: no sprite due

sprites:			DS		SPRITE_MAX * 4, $FF
; Their keys, sorted into painting order: the list (2 x height + the page of
; places) times 1024, the place's low byte times 4, and the sprite's number --
; $FFFF for one not in the view.
sprite_order:		DS		SPRITE_MAX * 2
sprite_next:		DB		0			; which of them is next
sprite_due:			DB		SPRITE_NONE	; its list...
sprite_due_place:	DB		0			; ...and its place's low byte


; Put sprite_order's entries at first_place and second_place in order.
					MACRO	SPRITE_ORDER_PAIR first_place, second_place
					ld		hl,(sprite_order + 2 * first_place)
					ld		de,(sprite_order + 2 * second_place)
					or		a
					sbc		hl,de
					jr		c,.in_order			; already the earlier first
					add		hl,de
					ld		(sprite_order + 2 * first_place),de
					ld		(sprite_order + 2 * second_place),hl
.in_order:
					ENDM


; ---------------------------------------------------------------------------
; order_sprites: after view_update. Each sprite's key, and the keys sorted --
; no two are equal, the number being in each, so sprites in the same turn go
; in the table's order, as the model's do. Five compare-and-swaps sort four.
; Uses everything but IY.

order_sprites:
					ld		ix,sprites
					ld		hl,sprite_order
					ld		b,0					; the sprite's number
.sprite:			push	hl
					call	sprite_key
					pop		hl
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					ld		de,4
					add		ix,de
					inc		b
					ld		a,b
					cp		SPRITE_MAX
					jr		nz,.sprite
					SPRITE_ORDER_PAIR 0, 1
					SPRITE_ORDER_PAIR 2, 3
					SPRITE_ORDER_PAIR 0, 2
					SPRITE_ORDER_PAIR 1, 3
					SPRITE_ORDER_PAIR 1, 2
					xor		a
					ld		(sprite_next),a
					jr		make_due


; The key of the sprite at IX, number B, into DE: $FFFF if it has no picture
; or its place is not in the view. Keeps B and IX.
sprite_key:
					ld		de,$FFFF
					ld		a,(ix+3)
					inc		a
					ret		z
					; From the view's first cell: du, dv, and dv - du = b + 2r.
					ld		a,(focus_x)
					add		a,SPRITE_START_X
					ld		c,a
					ld		a,(ix+0)
					sub		c
					ld		c,a					; du
					ld		a,(focus_y)
					add		a,SPRITE_START_Y
					ld		l,a
					ld		a,(ix+1)
					sub		l
					sub		c					; b + 2r
					ld		l,a
					and		1
					ld		h,a					; b
					ld		a,l
					sra		a
					ld		l,a					; r
					add		a,c					; a = du + r
					cp		16
					ret		nc					; not in a half-row of the view
					ld		c,a
					ld		a,l
					sub		(ix+2)				; its place's row: r - height
					cp		VIEW_ROWS
					ret		nc
					ld		l,a
					; Its list: 2 x height, and the row's page of places, row / 8.
					rrca
					rrca
					rrca
					and		1
					ld		e,a
					ld		a,(ix+2)
					add		a,a
					add		a,e
					ld		d,a
					; Its place's low byte: 32 (row & 7) + 16b + a.
					ld		a,l
					and		7
					rrca
					rrca
					rrca
					or		c
					ld		e,a
					ld		a,h
					add		a,a
					add		a,a
					add		a,a
					add		a,a
					or		e
					; The key: list << 10, low byte << 2, and the number.
					rlca
					rlca
					ld		e,a
					and		3
					sla		d
					sla		d
					or		d
					ld		d,a
					ld		a,e
					and		$FC
					or		b
					ld		e,a
					ret


; sprite_due and sprite_due_place from sprite_order[sprite_next], or no
; sprite due once all are painted.
make_due:
					ld		a,(sprite_next)
					cp		SPRITE_MAX
					jr		c,.one
					ld		a,SPRITE_NONE
					ld		(sprite_due),a
					ret
.one:				add		a,a
					ld		e,a
					ld		d,0
					ld		hl,sprite_order
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		a,d
					rrca
					rrca
					and		$3F
					ld		(sprite_due),a		; 63 for $FFFF: never due
					srl		d
					rr		e
					srl		d
					rr		e
					ld		a,e
					ld		(sprite_due_place),a
					ret


; ---------------------------------------------------------------------------
; paint_next_sprite: from paint, in the sprite's turn -- C the high byte of
; the screen third its list's page starts in, as paint_place has it. Paints
; it and makes the next one due. Uses everything but IX and IY.

paint_next_sprite:
					; Its picture: the number in its key, and 64 bytes a picture.
					ld		a,(sprite_next)
					ld		l,a
					inc		a
					ld		(sprite_next),a
					ld		a,l
					add		a,a
					ld		e,a
					ld		d,0
					ld		hl,sprite_order
					add		hl,de
					ld		a,(hl)
					and		3					; the number
					add		a,a
					add		a,a
					ld		e,a
					ld		hl,sprites + 3
					add		hl,de
					ld		a,(hl)				; the picture
					rrca
					rrca
					ld		e,a
					and		$C0
					ld		l,a
					ld		a,e
					and		$3F
					ld		h,a
					ld		de,sprite_pictures
					add		hl,de
					ex		de,hl				; DE the picture
					; Where: as paint_place finds a block's top left.
					ld		a,(sprite_due_place)
					ld		l,a
					ld		h,high PLACE_HIGH
					ld		a,(hl)
					add		a,c
					inc		h					; PLACE_LOW
					ld		l,(hl)
					ld		h,a
					; 16 rows: each byte of the screen ANDed with the mask and
					; ORed with the ink.
					ld		b,16
.row:				ld		a,(de)
					and		(hl)
					inc		de
					ex		de,hl
					or		(hl)
					ex		de,hl
					ld		(hl),a
					inc		de
					inc		l					; the right byte (a margin wraps, as
					ld		a,(de)				; for a block, and DEC L undoes it)
					and		(hl)
					inc		de
					ex		de,hl
					or		(hl)
					ex		de,hl
					ld		(hl),a
					inc		de
					dec		l
					; A pixel line down: INC H, and at a character row's end, L a
					; row on and H back -- or on into the next third.
					inc		h
					ld		a,h
					and		7
					jr		nz,.same_row
					ld		a,l
					add		a,32
					ld		l,a
					jr		c,.same_row			; the next third: H is right
					ld		a,h
					sub		8
					ld		h,a
.same_row:			djnz	.row
					jp		make_due
