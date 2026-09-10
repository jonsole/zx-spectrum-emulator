



; Byte 0 of a sprite record is the blit index, (width - 2) * 32, so bits 5-7
; are the width class and bits 0-4 are spare. Bit 0 says which way round the
; bytes currently are -- see sprite_flip_h. Knight Lore keeps the same state
; in the same byte, but at bit 6, which is part of the width field for us.
;
; Anything that uses byte 0 as a jump-table index must mask it with
; BLIT_IDX_MASK first. The width unpack does not need to: it rotates the
; class down and masks with 7, which drops the spare bits on the way past.
SPRITE_FLIPPED		EQU		0x01
BLIT_IDX_MASK		EQU		0xE0

					align 256
byte_position_table:
					REPT 	256,x
						IF	((x & 7) == 0)					
							DB 		(x / 8) << 1 
						ELSE
							DB 		((x / 8) << 1) + 1
						ENDIF
					ENDR


				MACRO	jump_entry addr
					jp		addr
					DB		0
				ENDM
				
					ALIGN	256					
sprite_jump_table:	
					; 2 bytes
					add	a
					jp	objects_draw_all.x_adjust
					DB	0,0,0,0
					jump_entry sprite_blit_1_of_2
					jump_entry sprite_blit_2_of_2
					DB	0,0,0,0
					DB	0,0,0,0
					DB	0,0,0,0
					DB	0,0
					DW	object_update.shift_final - (18 * 1)

					; 3 bytes
					ld	l,a
					add	a
					add	l
					jp	objects_draw_all.x_adjust
					DB	0,0
					jump_entry sprite_blit_1_of_3
					jump_entry sprite_blit_2_of_3
					jump_entry sprite_blit_3_of_3
					DB	0,0,0,0
					DB	0,0,0,0
					DB	0,0
					DW	object_update.shift_final - (18 * 2)

					; 4 bytes
					add	a
					add	a
					jp	objects_draw_all.x_adjust
					DB	0,0,0
					jump_entry sprite_blit_1_of_4
					jump_entry sprite_blit_2_of_4
					jump_entry sprite_blit_3_of_4
					jump_entry sprite_blit_4_of_4
					DB	0,0,0,0
					DB	0,0
					DW	object_update.shift_final - (18 * 3)

					; 5 bytes
					ld	l,a
					add	a
					add	a
					add	l
					jp	objects_draw_all.x_adjust
					DB	0
					jump_entry sprite_blit_1_of_5
					jump_entry sprite_blit_2_of_5
					jump_entry sprite_blit_3_of_5
					jump_entry sprite_blit_4_of_5
					jump_entry sprite_blit_5_of_5
					DB	0,0
					DW	object_update.shift_final - (18 * 4)

					; 6 bytes. Nothing gets here from a sprite record -- the widest
					; bitmap in the set is 5 -- only from a 5-byte sprite that has been
					; rotated, which is one column wider than its own bitmap. So there
					; is no 6-byte sprite left to rotate in turn, this group needs no
					; shift_final entry, and its six blit entries fill the 32 bytes
					; exactly where the other groups have room to spare.
					add	a					; *2
					ld	l,a
					add	a					; *4
					add	l					; *6
					jp	objects_draw_all.x_adjust
					DB	0
					jump_entry sprite_blit_1_of_6
					jump_entry sprite_blit_2_of_6
					jump_entry sprite_blit_3_of_6
					jump_entry sprite_blit_4_of_6
					jump_entry sprite_blit_5_of_6
					jump_entry sprite_blit_6_of_6

					; The table is indexed by a single byte in L, so it has to stay
					; inside its page. Groups are 32 bytes at (width - 2) * 32, which
					; leaves room up to width 9 -- and note that width 1 wraps to 224,
					; where there is deliberately no group: no 1-byte sprite is drawn.
					ASSERT	($ - sprite_jump_table) <= 256


				; DE' - view buffer address
				; HL' - sprite mask/data address
				; B' - number of lines

				; macro to generate routine to blit num_bytes of a sprite
				;
				; The view buffer is 512 bytes, so DE cannot be walked with `inc e`
				; throughout -- E wrapping past 255 has to carry into D. It does not
				; have to carry often, though. Rows are VIEW_BUF_WIDTH bytes on a
				; VIEW_BUF_WIDTH boundary, so the only address in the buffer where E
				; wraps is a row start; every increment strictly inside a row is safe
				; as `inc e`, and only the ones that can land on a row start need the
				; 16-bit form. Those are the last column increment (which lands on the
				; next row when the sprite runs to the right edge of the region) and
				; the row advance.
				MACRO sprite_blit width,num_bytes
					exx
					ld 		(.restore_sp+1),sp	; save SP
					ld		sp,hl				; load SP with sprite data address
.loop:				REPT	width,x
						pop     hl				; pop mask+data.  Even if not needed pop is quicker than sp += 2
						IF (num_bytes > x)
							ld      a, (de)		; get byte from view buffer
							and		l
							xor     h			; or data
							ld      (de), a		; write back to view buffer
						ENDIF
						IF (x < width - 1)
							inc     e			; still inside this row: E cannot wrap
						ENDIF
					ENDR

					; The last column's step and the gap to the next row, in one
					; move. Nothing is read between them, so there is no reason to
					; land on the row's last byte at all -- which is what makes this
					; cheaper than the stride it walks. A is free here, the column
					; loop having finished with it.
					;
					; This is the one step that can cross the buffer's page break, so
					; it is also the only one that has to carry into D. Off the fast
					; path: one row per region at most, and only for a region tall
					; enough to reach row 32.
					IF (VIEW_BUF_WIDTH-width+1) <= 3
						REPT	VIEW_BUF_WIDTH-width+1
							inc		de			; the chain is cheaper when this short
						ENDR
					ELSE
						ld		a,e
						add		a,VIEW_BUF_WIDTH-width+1
						ld		e,a
						jr		nc,.same_page
						inc		d
.same_page:
					ENDIF
					djnz	.loop
.restore_sp:		ld		sp,0				; restore SP, value set before loop
					jp 		(ix)
				ENDM



sprite_blit_1_of_2:	sprite_blit 2,1
sprite_blit_2_of_2:	sprite_blit 2,2
sprite_blit_1_of_3:	sprite_blit 3,1
sprite_blit_2_of_3:	sprite_blit 3,2
sprite_blit_3_of_3:	sprite_blit 3,3
sprite_blit_1_of_4:	sprite_blit 4,1
sprite_blit_2_of_4:	sprite_blit 4,2
sprite_blit_3_of_4:	sprite_blit 4,3
sprite_blit_4_of_4:	sprite_blit 4,4
sprite_blit_1_of_5:	sprite_blit 5,1
sprite_blit_2_of_5:	sprite_blit 5,2
sprite_blit_3_of_5:	sprite_blit 5,3
sprite_blit_4_of_5:	sprite_blit 5,4
sprite_blit_5_of_5:	sprite_blit 5,5
sprite_blit_1_of_6:	sprite_blit 6,1
sprite_blit_2_of_6:	sprite_blit 6,2
sprite_blit_3_of_6:	sprite_blit 6,3
sprite_blit_4_of_6:	sprite_blit 6,4
sprite_blit_5_of_6:	sprite_blit 6,5
sprite_blit_6_of_6:	sprite_blit 6,6




	
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
					rlca
					rlca
					rlca			; the width class, back down into the low bits
					and		7
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

