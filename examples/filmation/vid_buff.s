; Copy a composited region out of the view buffer and onto the screen.
;
;   HL - view buffer, at the region's top-left
;   DE - screen address of the same corner
;   B  - rows
;
; One routine per region width, 1 to VIEW_BUF_WIDTH, picked through
; copy_routines. The source is a plain buffer -- one byte per column, with no
; mask interleaved -- which is what view_buffer holds. vid_buff_blit_5 at the
; bottom is the interleaved-source variant, and is not in copy_routines.

				MACRO vid_buff_copy n
					; LDI counts BC down as it copies. B is the row counter, so a
					; borrow out of C would silently drop a row -- and rows * width
					; reaches 512 here, well past a byte. Reset C every row rather
					; than reason about the total.
.row:				LD		C,255

					IF n >= 5
						PUSH	DE			; cheaper than unwinding DE below
					ENDIF
				REPT	n
					LDI
				ENDR
					; Back to the first column of this screen row. LDI ran DE forward
					; n times, and if the region touches the right-hand edge on the
					; last character row of a third that will have carried into D --
					; so the first step back has to be the 16-bit one.
					IF n >= 5
						POP		DE
					ELSE
						DEC		DE
						REPT	n - 1
							DEC		E
						ENDR
					ENDIF

					; On to the next row of the buffer. It is 512 bytes, so this is
					; the one place the source pointer crosses a page and the add has
					; to carry into H. At the full width LDI has already walked the
					; whole stride and there is nothing left to add.
					IF (VIEW_BUF_WIDTH-n) > 0 && (VIEW_BUF_WIDTH-n) <= 3
						REPT	VIEW_BUF_WIDTH-n
							INC		HL
						ENDR
					ENDIF
					IF (VIEW_BUF_WIDTH-n) > 3
						LD		A,L
						ADD		A,VIEW_BUF_WIDTH-n
						LD		L,A
						JR		NC,.same_page
						INC		H
.same_page:
					ENDIF

					; Next screen row: down one pixel line, and every eighth line on
					; to the next character row.
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
				ENDM


vid_buff_copy_1:	vid_buff_copy 1
vid_buff_copy_2:	vid_buff_copy 2
vid_buff_copy_3:	vid_buff_copy 3
vid_buff_copy_4:	vid_buff_copy 4
vid_buff_copy_5:	vid_buff_copy 5
vid_buff_copy_6:	vid_buff_copy 6
vid_buff_copy_7:	vid_buff_copy 7
vid_buff_copy_8:	vid_buff_copy 8


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
