; Copy a composited region out of the view buffer and onto the screen.
;
;   HL - view buffer, at the region's top-left
;   DE - screen address of the same corner
;   B  - rows
;
; One routine for every region width, not eight. A width decides two things --
; how many bytes of each row to move, and how far the buffer pointer steps to
; reach the next row -- and redraw_view knows both before the first row, so it
; writes them in: the entry jump picks how far into the LDI chain to start, and
; the stride is an immediate. There is nothing left for a row to decide, which
; is what the eight copies of the routine used to buy.
;
; The source is a plain buffer -- one byte per column, no mask interleaved --
; which is what view_buffer holds. vid_buff_blit_5 at the bottom is the
; interleaved-source variant, and nothing calls it.

vid_buff_copy:
					; LDI counts BC down as it copies. B is the row counter, so
					; a borrow out of C would silently drop a row -- and rows *
					; width reaches 512 here, well past a byte. Reset C every
					; row rather than reason about the total.
.row:				LD		C,255
					PUSH	DE			; cheaper than unwinding DE afterwards
					; at any width worth having a routine for

.entry:				DB		$18, 0		; JR, with the displacement patched:
					; two bytes a column, from the wide end
					REPT	VIEW_BUF_WIDTH
					LDI
					ENDR
					POP		DE			; back to this screen row's first column

					; On to the next row of the buffer. It is 512 bytes, so
					; this is the one place the source pointer crosses a page
					; and the add has to carry into H.
					LD		A,L
.hstride:			ADD		A,0			; patched: VIEW_BUF_WIDTH - width
					LD		L,A
					JR		NC,.same_page
					INC		H
.same_page:
					; Next screen row: down one pixel line, and every eighth
					; line on to the next character row.
					INC		D
					LD		A,D
					AND		$07
					JR		Z,.adjust
					DJNZ	.row
					RET
.adjust:			LD		A,E
					ADD		A,$20
					LD		E,A
					CCF
					SBC		A,A
					AND		$F8
					ADD		A,D
					LD		D,A
					DJNZ	.row
					RET


; As above, but for a source that interleaves a mask byte with every data
; byte -- a shift buffer rather than the view buffer. Nothing copies one of
; those to the screen today, so this is not in copy_routines.
vid_buff_blit_5:	LD		C,255
					PUSH    DE
                	LDI
					inc		hl
                	LDI
					inc		hl
                	LDI
					inc		hl
               		LDI
					inc		hl
                	LDI
					inc		hl
					LD		A,VIEW_BUF_WIDTH-5
					ADD		L
					LD		L,A
					ADC		A,H
					SUB		L
					LD		H,A
                	POP     DE

					INC     D
                	LD      A,D
                	AND     $07
                	JR      Z,.adjust
                	DJNZ    vid_buff_blit_5
                	RET
.adjust: 			LD      A,E
                	ADD     A,$20
                	LD      E,A
                	CCF
                	SBC     A,A
                	AND     $F8
                	ADD     A,D
                	LD      D,A
                	DJNZ    vid_buff_blit_5
                	RET
