; ---------------------------------------------------------------------------
; Mirror a sprite about its vertical axis, IN PLACE, and record in the
; sprite's own header which way round it now is.
;
; A wall running along U and the same wall running along V are one graphic
; seen from two sides, and only one of them is stored -- which is most of
; why the artwork fits at all. So the bytes are shared, and an object that
; wants the other orientation mirrors them where they lie rather than
; keeping a second copy. Knight Lore does the same in flip_sprite ($D6EF).
;
; One pass over each row, from both ends at once. The near column takes the far
; one's bytes reversed and the far column takes the near one's, a pair at a
; time, until the two meet. An odd middle column needs nothing of its own: when
; the ends reach it they are the same column, and swapping a byte with itself,
; reversed both ways, leaves it reversed in place.
;
; All three pairs are pointers here -- HL at the near column, DE at the far one,
; BC into the table -- so there is no register left to count with. The loop
; runs until the far pointer drops below the near one instead, and the first
; reversed byte waits in A' while the second is read -- 8 T against 21 for a
; PUSH and POP, four times a column. objects_draw_all holds the x overlap in A'
; across sprite_orient, which calls this, so the caller's A' goes on the stack
; for the length of the flip and comes back at the end. The row count is kept
; in IYL for the same reason there is no register for it, and IY is saved
; around the flip too: the draw loop holds its next object there.
;
; Row order is untouched: a horizontal mirror does not care which way up the
; rows are stored, which is why nothing here has to know that sprite_source.py
; already turned Ultimate's bottom-up rows the right way round.
;
; Records are ALIGN 4, so every row starts on an even address: masks are even
; and data bytes odd. A step from even to odd cannot carry out of the low byte,
; nor one from odd to even borrow, so those move L or E alone; only the steps
; that could cross a page move the whole pair.
;
; In:  HL -> the sprite record
; Out: nothing
; Corrupts: AF, BC, DE
sprite_flip_h:		push	hl
					push	iy
					ex		af,af'
					push	af		; the caller's AF', back at the end
					ld		a,(hl)
					xor		SPRITE_FLIPPED
					ld		(hl),a		; the header now says which way round it is
					sprite_width_class
					add		a,2		; width, in columns
					add		a		; and in bytes -- a mask and a data byte each
					ld		(.stride+1),a		; into E below
					inc		l		; even to odd, so no carry
					ld		a,(hl)
					ld		iyl,a		; height, and the rows left to do
					inc		hl		; -> the first row
					ld		b,high bit_reverse_table		; C alone moves from here

.next_row:
.stride:			ld		de,0		; imm: E = the row's length in bytes
					ex		de,hl		; DE = the row's start
					add		hl,de		; -> the next row
					push	hl		; kept for the end of the row
					ex		de,hl		; HL = the row's start, DE = the next row
					dec		de		; even to odd, which can borrow
					dec		e		; DE -> this row's last column

.column:			ld		c,(hl)		; the near mask, reversed...
					ld		a,(bc)
					ex		af,af'
					ld		a,(de)		; ...the far one, reversed...
					ld		c,a
					ld		a,(bc)
					ld		(hl),a		; ...and each into the other's place
					ex		af,af'
					ld		(de),a
					inc		l		; mask to data: even to odd, so no carry
					inc		e
					ld		c,(hl)		; and the same for the data bytes
					ld		a,(bc)
					ex		af,af'
					ld		a,(de)
					ld		c,a
					ld		a,(bc)
					ld		(hl),a
					ex		af,af'
					ld		(de),a
					inc		hl		; the next column in
					dec		e		; data to mask: odd to even
					dec		de		; even to odd, which can borrow
					dec		e		; and the one before it at the far end
					ld		a,e
					sub		l
					ld		a,d
					sbc		a,h
					jr		nc,.column		; until the far end is behind the near one

					pop		hl		; the next row
					dec		iyl
					jr		nz,.next_row
					pop		af
					ex		af,af'		; the caller's AF' back
					pop		iy
					pop		hl
					ret


; Every byte with its bits the other way round: the table sprite_flip_h mirrors
; through, one page long. knightlore/knightlore.s places it, on a page boundary.
					MACRO	bit_reverse_bytes
					REPT	256,x
					DB		((x & 0x01) << 7) | ((x & 0x02) << 5) | ((x & 0x04) << 3) | ((x & 0x08) << 1) | ((x & 0x10) >> 1) | ((x & 0x20) >> 3) | ((x & 0x40) >> 5) | ((x & 0x80) >> 7)
					ENDR
					ENDM
