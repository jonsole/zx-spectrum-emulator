; The screen address of a pixel. BC and DE are unchanged, so there is no need
; for expensive push and pop operations.
;
; In:  B = y, 0 to 191
;      C = x, 0 to 255
; Out: HL -> the byte holding the pixel
; Corrupts: AF
pixelAddress:   ld      a, b
                and     %00000111
                ld      h, a    ; h contains Y2-Y0
                ld      a, b
                rra
                scf             ; set bit 14
                rra
                rra
                ld      l, a    ; l contains Y5-Y3
                and     %01011000
                or      h
                ld      h, a    ; h is complete now
                ld      a, c    ; divide X by 8
                rr      l       ; and rotate Y5-Y3 in
                rra
                rr      l
                rra
                rr      l
                rra
                ld      l, a    ; l is complete now
                ret


; Copy a composited region out of the view buffer and onto the screen.
;
; One routine for every region width, not eight. A width decides two things --
; how many bytes of each row to move, and how far the buffer pointer steps to
; reach the next row -- and redraw_view knows both before the first row, so it
; writes them in: the DJNZ's displacement picks how far into the LDI chain each
; row starts, and the stride is an immediate. There is nothing left for a row
; to decide, which is what the eight copies of the routine used to buy.
;
; The routine is entered at its foot, vid_buff_copy, which sets a row up and
; goes round -- so the jump into the chain is the loop's own DJNZ, not a JR of
; its own that every row would pay for.
;
; The source is a plain buffer -- one byte per column, no mask interleaved --
; which is what view_buffer holds. (There was an interleaved-source variant,
; vid_buff_blit_5, for copying a shift buffer straight out; nothing ever called
; it, and its 48 bytes went to the menu.)

vid_buff_row:		; two bytes a column, from the wide end
					REPT	VIEW_BUF_WIDTH
					LDI
					ENDR
					POP		DE			; back to this screen row's first column

					; On to the next row of the buffer. It is 512 bytes, so
					; this is the one place the source pointer crosses a page
					; and the add has to carry into H -- once in thirty-two rows,
					; so it is the carry that jumps, and the other rows go
					; straight on.
					LD		A,L
.hstride:			ADD		A,0			; patched: VIEW_BUF_WIDTH - width
					LD		L,A
					JR		C,vid_buff_copy.page
.same_page:
					; Next screen row: down one pixel line, and every eighth
					; line on to the next character row.
					INC		D
					LD		A,D
					AND		$07
					JR		Z,vid_buff_copy.adjust

					;; NB: fall through into vid_buff_copy


; The way in: sets a row up and goes round the chain above. The width is
; patched in first -- the DJNZ's displacement and .hstride, which redraw_view
; writes.
;
; In:  HL -> the view buffer, at the region's top-left
;      DE -> the screen, at the same corner
;      B  = rows, plus one: the DJNZ takes one on the way in
; Out: nothing
; Corrupts: AF, BC, DE, HL
vid_buff_copy:
					; LDI counts BC down as it copies. B is the row counter, so
					; a borrow out of C would silently drop a row -- and rows *
					; width reaches 512 here, well past a byte. Reset C every
					; row rather than reason about the total -- from D, which
					; is the screen's high byte and so never below $40, far
					; more than the eight LDIs a row can take off it.
					LD		C,D
					PUSH	DE			; cheaper than unwinding DE afterwards
.loop:				DJNZ	vid_buff_row	; patched: into the chain for the width
					POP		DE			; the row set up for nobody
					RET

.adjust:			LD		A,E
					ADD		A,$20
					LD		E,A
					CCF
					SBC		A,A
					AND		$F8
					ADD		A,D
					LD		D,A
					JP		vid_buff_copy		; 2 T less than a JR, on one line in eight

.page:				INC		H
					JR		vid_buff_row.same_page

; What redraw_view adds to twice the columns left out, to aim the DJNZ.
VID_BUFF_LOOP_BASE	EQU		(vid_buff_row - (vid_buff_copy.loop + 2)) & $FF
