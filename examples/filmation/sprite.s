; Byte 0 of a sprite record is the blit index, (width - 2) * JUMP_GROUP, so
; bits 4-6 are the width class and the rest are spare. Bit 0 says which way
; round the bytes currently are -- see sprite_flip_h. Knight Lore keeps the
; same state in the same byte, but at bit 6, which is part of the width field
; for us.
;
; The class used to be scaled by 32, when a group held a jump entry for every
; column count as well. One blitter later there is nothing in a group but the
; index arithmetic for its width and, for the widths that can be rotated, the
; entry shift_sprite finishes on -- and sixteen is room enough for both.
;
; Anything that uses byte 0 as a jump-table index must mask it with
; BLIT_IDX_MASK first. The width unpack does not need to: it rotates the class
; down and masks with 7, which drops the spare bits on the way past.
SPRITE_FLIPPED		EQU		0x01
WIDTH_CLASS_SHIFT	EQU		4		; where the class sits in byte 0, and so
JUMP_GROUP			EQU		1 << WIDTH_CLASS_SHIFT		; the stride of a group
SHIFT_FINAL_AT		EQU		JUMP_GROUP - 2		; the shift entry ends a group
BLIT_IDX_MASK		EQU		7 * JUMP_GROUP		; the three class bits, in place


; The width class out of a sprite's byte 0 and down into the low bits.
;
; Four places want this, and they each used to spell it out. When the class
; moved down from bits 5-7 -- one blitter having emptied most of a group --
; three of them were changed and the fourth, shift_alloc, was not: every
; rotated object then got a buffer sized for the wrong width, and they wrote
; over each other in the arena. A macro cannot be changed in three places.
;
;   in  A - byte 0 of a sprite record
;   out A - width - 2, so add 2 for the width in bytes, or 3 for the width
;           of a rotated copy, which carries one more column
				MACRO	sprite_width_class
				REPT	8 - WIDTH_CLASS_SHIFT
					rlca
				ENDR
					and		7
				ENDM

					ALIGN	256					
; Indexed by BLIT_IDX. Each group starts with the arithmetic that turns a
; row count into a byte offset for that width -- rows * width, done as shifts
; and adds -- and ends, for the widths a sprite can still be rotated into, with
; the address shift_sprite's unrolled row finishes on.
sprite_jump_table:	
.w2:				add	a
					jp	objects_draw_all.x_adjust
					DS	SHIFT_FINAL_AT - ($ - .w2), 0
					DW	object_update.shift_final - (18 * 1)
					ASSERT	$ - .w2 == JUMP_GROUP

.w3:				ld	l,a
					add	a
					add	l
					jp	objects_draw_all.x_adjust
					DS	SHIFT_FINAL_AT - ($ - .w3), 0
					DW	object_update.shift_final - (18 * 2)
					ASSERT	$ - .w3 == JUMP_GROUP

.w4:				add	a
					add	a
					jp	objects_draw_all.x_adjust
					DS	SHIFT_FINAL_AT - ($ - .w4), 0
					DW	object_update.shift_final - (18 * 3)
					ASSERT	$ - .w4 == JUMP_GROUP

.w5:				ld	l,a
					add	a
					add	a
					add	l
					jp	objects_draw_all.x_adjust
					DS	SHIFT_FINAL_AT - ($ - .w5), 0
					DW	object_update.shift_final - (18 * 4)
					ASSERT	$ - .w5 == JUMP_GROUP

					; 6 bytes. Nothing gets here from a sprite record -- the widest
					; bitmap in the set is 5 -- only from a 5-byte sprite that has been
					; rotated, which is one column wider than its own bitmap. So there
					; is no 6-byte sprite left to rotate in turn, and this group needs
					; no shift_final entry.
.w6:				add	a					; *2
					ld	l,a
					add	a					; *4
					add	l					; *6
					jp	objects_draw_all.x_adjust
					DS	JUMP_GROUP - ($ - .w6), 0

					; The table is indexed by a single byte in L, so it has to stay
					; inside its page. Groups are JUMP_GROUP bytes at
					; (width - 2) * JUMP_GROUP, which leaves room up to width 17 --
					; and note that width 1 wraps to 240, where there is deliberately
					; no group: no 1-byte sprite is drawn.
					ASSERT	($ - sprite_jump_table) <= 256


				; DE' - view buffer address
				; HL' - sprite mask/data address
				; B'  - number of rows
				; IX  - where to go when the sprite is drawn
				;
				; One blitter, not twenty. A blit is two numbers: how many
				; columns of a row land inside the region, and how many more
				; the sprite has that do not. The clipped ones are always on
				; the right, and while nothing is composited from them their
				; source bytes still have to be stepped over, or the next row
				; would start in the wrong place. There used to be a fully
				; unrolled routine for every (columns, width) pair the sprite
				; set can produce -- twenty of them, 756 bytes.
				;
				; Both numbers are settled before the first row and hold for
				; all of them, so they are written into the code instead of
				; tested in it. The entry jump picks which column of the chain
				; to start at, and a DJNZ is laid over the run of POPs at the
				; point where the clipped columns end. Nothing is decided per
				; row, so a row costs what it always did.
				;
				; The two bytes that DJNZ covers are POPs again by the time the
				; next sprite is drawn, which is what `patched` is for.
; Point the one blitter at this sprite.
;
;   A - the columns of a row that land inside the region
;   D - BLIT_IDX, which matches however many columns a row of the sprite
;       actually has: shift_sprite bumps it by a width class when it rotates,
;       for the overflow column
;
; Once per object drawn, against that sprite's sixteen to sixty-four rows. B,
; C, E, H and L are all dead here -- the blit's own registers are in the other
; bank -- and A is finished with by the time it jumps.
sprite_blit_setup:
					ld		c,a					; c = columns to composite
					ld		a,d					; blit index back to a width
					sprite_width_class
					add		a,2
					sub		c
					ld		b,a					; b = columns to step over

					ld		a,VIEW_BUF_WIDTH + 1
					sub		c
					ld		(sprite_blit.vstride+1),a

					; How far into the column chain to start. The columns are
					; all one size bar the last, so this counts from the wide
					; end, and the answer is a displacement rather than an
					; address because .entry is a JR sitting right in front of
					; the chain.
					ld		a,BLIT_COLUMNS
					sub		c
					add		a					; * 2
					ld		e,a
					add		a					; * 4
					add		e					; * BLIT_COLUMN_SIZE
					ld		(sprite_blit.entry+1),a
					ld		e,a					; the DJNZ below wants it too

					; Put back the two bytes the last DJNZ covered...
					ld		hl,(sprite_blit.patched)
					ld		(hl),$F1			; POP AF
					inc		hl
					ld		(hl),$F1

					; ...and lay a new one over the POPs this sprite does not
					; need. Its own displacement is the entry's, less the POPs
					; it now sits in front of, and a constant for the distance
					; between the two runs.
					ld		a,low sprite_blit.pops
					add		a,b
					ld		l,a
					ld		h,high sprite_blit.pops
					ld		(sprite_blit.patched),hl
					ld		(hl),$10			; DJNZ
					inc		hl
					ld		a,e
					sub		b
					add		a,(sprite_blit.c6 - sprite_blit.pops - 2) & $FF
					ld		(hl),a
					jp		sprite_blit


BLIT_COLUMNS		EQU		6		; the widest a sprite gets: five bytes of
					; bitmap, and one more when it is rotated
BLIT_COLUMN_SIZE	EQU		6		; and what one column of the chain assembles
					; to. sprite_blit_setup multiplies by this
					; with a shift and an add, so it cannot
					; read the EQU -- the ASSERT below is what
					; keeps the two honest.

sprite_blit:		exx
					ld		(.restore_sp+1),sp	; save SP
					ld		sp,hl				; SP walks the sprite

.entry:				DB		$18, 0				; JR, with the displacement patched:
					; which column of the chain to enter at.
					; Zero is BLIT_COLUMNS of them, and
					; falls straight through to .c6.

					; One column: pop the interleaved mask/data pair and
					; composite it into the view buffer. The buffer is 512
					; bytes, so E wrapping has to carry into D -- but the only
					; address where that can happen is a row start, and every
					; increment here is strictly inside a row. The last column
					; has no increment at all: the row advance below does its
					; step as part of the stride, and carries properly.
.c6:
				REPT	BLIT_COLUMNS - 1
					pop		hl
					ld		a,(de)
					and		l
					xor		h
					ld		(de),a
					inc		e
				ENDR
.c1:				pop		hl
					ld		a,(de)
					and		l
					xor		h
					ld		(de),a

					; The same column of the next row.
					ld		a,e
.vstride:			add		a,0					; patched: VIEW_BUF_WIDTH + 1 - columns
					ld		e,a
					jr		nc,.same_page
					inc		d
.same_page:
					; Step over the columns clipped off the right-hand side.
					; The DJNZ sits just past however many of these this sprite
					; needs, so the rest are never reached -- and when none are
					; needed it sits at the front and this costs nothing.
.pops:			REPT	BLIT_COLUMNS - 1
					pop		af
				ENDR
					DB		0,0					; room for it past the lot

.restore_sp:		ld		sp,0				; restore SP, value set before loop
					jp		(ix)

; Where the DJNZ went last time, so those two bytes can be made POPs again.
.patched:			DW		.pops

					ASSERT	sprite_blit.c1 - sprite_blit.c6 == (BLIT_COLUMNS - 1) * BLIT_COLUMN_SIZE

					; The DJNZ is addressed as `low .pops + skip`, so the run
					; must not straddle a page.
					ASSERT	high sprite_blit.pops == high (sprite_blit.pops + BLIT_COLUMNS - 1)




	
						ALIGN	256
; Shift amounts 1..7. There is deliberately no table for shift 0:
; object_update only takes the shifting path when x & 7 is non-zero, so a
; shift-0 table could never be read. Knight Lore builds 1..7 for the same
; reason. Two pages per shift -- (x >> r) and the bits that fall out of it
; -- which is what the inc h / dec h in object_update.loop toggles between.
sprite_rotate_table:	REPT	7,r
				REPT	256,x
					DB		(x >> (r + 1))
				ENDR
				REPT	256,x
					DB		(((x << 8) >> (r + 1)) & 0xFF)
				ENDR
			ENDR

; Indexing base for the above. Shift s lives at page base + 2(s - 1), so
; the table is addressed as though it began two pages earlier and the
; "- 1" costs nothing at run time -- object_update just doubles the shift
; and adds this. 512, not 256: there are two pages per shift.
SPRITE_ROTATE_BASE	EQU		sprite_rotate_table - 512


; The graphic-number table goes here, in front of the bitmaps, because
; sprite_rotate_table happens to end on a 512 boundary and the table needs
; one. Behind them it needed a boundary of its own, and the padding to reach
; it was the last thing in the image -- so it rounded the whole image up, and
; anything saved anywhere else disappeared into it.
					INCLUDE "sprite_table.s"


					ALIGN	256
; Every byte with its bits the other way round, for mirroring a sprite.
; Knight Lore keeps the same table at $F100 and reaches it exactly this way,
; with the page in B and the byte in C.
bit_reverse_table:	REPT	256,x
					DB		((x & 0x01) << 7) | ((x & 0x02) << 5) | ((x & 0x04) << 3) | ((x & 0x08) << 1) | ((x & 0x10) >> 1) | ((x & 0x20) >> 3) | ((x & 0x40) >> 5) | ((x & 0x80) >> 7)
				ENDR


; ---------------------------------------------------------------------------
; Mirror a sprite about its vertical axis, IN PLACE, and record in the
; sprite's own header which way round it now is.
;
;   HL -> the sprite record
;
; A wall running along U and the same wall running along V are one graphic
; seen from two sides, and only one of them is stored -- which is most of
; why the artwork fits at all. So the bytes are shared, and an object that
; wants the other orientation mirrors them where they lie rather than
; keeping a second copy. Knight Lore does the same in flip_sprite ($D6EF).
;
; Two passes over each row. The first reverses the bits of every byte where
; it lies; the second swaps the columns end for end. Splitting them is what
; keeps the second free of a special case for an odd middle column -- widths
; 1, 3 and 5 all occur in this set -- because a column with no partner is
; simply never reached, and the first pass has already dealt with it.
;
; Row order is untouched: a horizontal mirror does not care which way up the
; rows are stored, which is why nothing here has to know that sprites.py
; already turned Ultimate's bottom-up rows the right way round.
;
; Clobbers AF, BC, DE, HL.
sprite_flip_h:		ld		a,(hl)
					xor		SPRITE_FLIPPED
					ld		(hl),a		; the header now says which way round it is
					sprite_width_class
					add		a,2		; width, in columns
					ld		(.columns),a
					add		a
					ld		(.stride),a		; and in bytes -- a mask and a data byte each
					inc		hl
					ld		a,(hl)
					ld		(.rows),a		; height
					inc		hl		; -> the first row

.next_row:			push	hl

					; Every byte of the row, bit-reversed where it lies.
					ld		b,high bit_reverse_table
					ld		a,(.stride)
					ld		d,a
.reverse:			ld		c,(hl)
					ld		a,(bc)
					ld		(hl),a
					inc		hl
					dec		d
					jr		nz,.reverse

					; Now the columns, swapped end for end. DE walks back from
					; the row's last pair while HL walks forward from its first.
					pop		hl
					push	hl
					ld		d,h
					ld		e,l
					ld		a,(.stride)
					add		a,e
					ld		e,a
					jr		nc,.last_pair
					inc		d
.last_pair:			dec		de
					dec		de		; de -> the last pair of the row

					ld		a,(.columns)
					srl		a		; pairs to swap; a one-column
					jr		z,.row_done		; sprite has none
					ld		b,a
.swap:				ld		a,(de)
					ld		c,a		; only A can reach (DE), so the
					ld		a,(hl)		; far byte goes via C
					ld		(de),a
					ld		(hl),c		; masks
					inc		hl
					inc		de
					ld		a,(de)
					ld		c,a
					ld		a,(hl)
					ld		(de),a
					ld		(hl),c		; and the data beside them
					inc		hl
					dec		de
					dec		de
					dec		de		; back to the previous pair
					djnz	.swap

.row_done:			pop		hl
					ld		a,(.stride)
					add		a,l
					ld		l,a
					jr		nc,.same_row_page
					inc		h
.same_row_page:		ld		a,(.rows)
					dec		a
					ld		(.rows),a
					jr		nz,.next_row
					ret

.columns:			DB		0
.stride:			DB		0
.rows:				DB		0



sprite_start:
					INCLUDE "sprite_data.s"
sprite_end:
					DISPLAY "sprite_data size ", sprite_end - sprite_start

