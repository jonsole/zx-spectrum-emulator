



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



sprite_start:
					INCLUDE "sprite_data.s"
sprite_end:
					DISPLAY "sprite_data size ", sprite_end - sprite_start

