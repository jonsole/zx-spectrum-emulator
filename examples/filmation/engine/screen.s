; A graphic straight onto the screen, masked and byte-aligned: the carried
; objects, and the status panel's pieces -- print_sprite as the panel uses it.
;
; In:  A = the graphic
;      C = x in pixels, a multiple of 8
;      D = 1 to draw it mirrored
;      E = the row below its bottom one
; Out: nothing
; Corrupts: AF, B, DE, HL, AF'
screen_sprite:		ld		l,a
					ld		h,(high sprite_table) / 2
					add		hl,hl
					ld		a,(hl)
					inc		l
					ld		h,(hl)
					ld		l,a
					ld		a,(hl)
					xor		d
					rra				; SPRITE_FLIPPED: carry if it is the
					jr		nc,.oriented		; other way round from the one wanted
					push	bc
					push	de
					call	sprite_flip_h		; which keeps HL
					pop		de
					pop		bc
.oriented:			ld		a,e
					ld		(.bottom+1),a
					ld		a,(hl)
					sprite_width_class
					add		a,2
					ld		(.columns+1),a
					inc		hl
					ld		a,e
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
.bottom:			cp		0		; patched: the row below the bottom
					jr		c,.rows
					ret
