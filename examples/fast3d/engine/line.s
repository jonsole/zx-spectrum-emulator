; fast3d: draw_line, a line of pixels by Bresenham, and clear_box.
;
; The line is drawn downwards (its ends swapped if need be), stepping along
; whichever of x and y it is longer in. Each of the four ways it can go --
; along x or along y, to the right or the left -- is a loop of eight blocks,
; one for each bit of a screen byte, so a pixel is one SET b,(HL); moving to
; the next bit is falling into the next block, and to the next byte, INC L or
; DEC L once in eight pixels. draw_line works out where the line starts and
; RETs into the block for its first pixel; the last pixel's block RETs to the
; caller.
;
; About 60 T-states a pixel along x (40 when it stays on a row), and 82 along
; y, where each pixel steps down a row: that takes working out on the
; Spectrum's screen.

; The rows' addresses, for the screen at $4000: ROW_TABLE + y is the low
; byte, ROW_TABLE + 256 + y the high. Page-aligned; build.py fills it.
					ALIGN	256
ROW_TABLE:
					INCLUDE	"output/rows_gen.s"

; Down a row, from HL: A is kept (in C).
					MACRO	DOWN_ROW
					ld		c,a
					inc		h
					ld		a,h
					and		7
					jr		nz,.done			; still in the character row
					ld		a,l
					add		a,32
					ld		l,a
					jr		c,.done				; into the next third
					ld		a,h
					sub		8
					ld		h,a
.done:				ld		a,c
					ENDM

; A pixel of a line longer along x: A is the error, D the length along x, E
; along y, B the pixels left.
					MACRO	ALONG_X	BIT, NEXT
					set		BIT,(hl)
					dec		b
					ret		z
					sub		e
					jr		nc,NEXT
					add		a,d
					DOWN_ROW
					ENDM

; A pixel of a line longer along y: every pixel moves down a row, and when the
; error runs out, one along x -- into the next block. SELF is the block itself.
					MACRO	ALONG_Y	BIT, SELF
					set		BIT,(hl)
					dec		b
					ret		z
					DOWN_ROW
					sub		e
					jr		nc,SELF
					add		a,d
					ENDM

; ---------------------------------------------------------------------------
; draw_line: from (B, C) to (D, E), x 0..255 and y 0..191, on the screen
; screen_high says: $00 for the one at $4000, $80 for $C000.
; Uses everything but IY and the alternate registers.

draw_line:
					ld		a,e
					sub		c
					jr		nc,.ordered
					ld		a,b					; upwards: swap the ends
					ld		b,d
					ld		d,a
					ld		a,c
					ld		c,e
					ld		e,a
					sub		c
.ordered:			ld		ixl,a				; IXL = dy
					ld		e,0					; E = which loop, x 16
					ld		a,d
					sub		b
					jr		nc,.right
					neg
					ld		e,16
.right:				ld		ixh,a				; IXH = |dx|
					cp		ixl
					jr		nc,.along_x
					ld		a,e
					add		a,32
					ld		e,a
.along_x:			ld		a,b					; and which block: x0's bit
					and		7
					add		a,a
					add		a,e
					ld		e,a
					ld		d,0
					ld		hl,line_entries
					add		hl,de
					ld		a,(hl)
					inc		hl
					ld		h,(hl)
					ld		l,a
					push	hl					; where the RET below goes
					ld		l,c					; HL = (x0, y0)'s byte
					ld		h,high ROW_TABLE
					ld		a,b
					rrca
					rrca
					rrca
					and		31
					or		(hl)
					inc		h
					ld		h,(hl)
					ld		l,a
					ld		a,(screen_high)
					or		h
					ld		h,a
					ld		a,ixh
					cp		ixl
					jr		c,.setup_y
					ld		d,a					; along x: D = dx, E = dy
					ld		b,a
					inc		b					; dx + 1 pixels
					ld		e,ixl
					srl		a					; the error starts at dx / 2
					ret
.setup_y:			ld		e,a					; along y: D = dy, E = dx
					ld		a,ixl
					ld		d,a
					ld		b,a
					inc		b
					srl		a
					ret

screen_high:		DB		0

line_entries:		DW		right_x7, right_x6, right_x5, right_x4, right_x3, right_x2, right_x1, right_x0
					DW		left_x7, left_x6, left_x5, left_x4, left_x3, left_x2, left_x1, left_x0
					DW		right_y7, right_y6, right_y5, right_y4, right_y3, right_y2, right_y1, right_y0
					DW		left_y7, left_y6, left_y5, left_y4, left_y3, left_y2, left_y1, left_y0

right_x7:			ALONG_X	7, right_x6
right_x6:			ALONG_X	6, right_x5
right_x5:			ALONG_X	5, right_x4
right_x4:			ALONG_X	4, right_x3
right_x3:			ALONG_X	3, right_x2
right_x2:			ALONG_X	2, right_x1
right_x1:			ALONG_X	1, right_x0
right_x0:			ALONG_X	0, right_x_byte
right_x_byte:		inc		l
					jp		right_x7

left_x0:			ALONG_X	0, left_x1
left_x1:			ALONG_X	1, left_x2
left_x2:			ALONG_X	2, left_x3
left_x3:			ALONG_X	3, left_x4
left_x4:			ALONG_X	4, left_x5
left_x5:			ALONG_X	5, left_x6
left_x6:			ALONG_X	6, left_x7
left_x7:			ALONG_X	7, left_x_byte
left_x_byte:		dec		l
					jp		left_x0

right_y7:			ALONG_Y	7, right_y7
right_y6:			ALONG_Y	6, right_y6
right_y5:			ALONG_Y	5, right_y5
right_y4:			ALONG_Y	4, right_y4
right_y3:			ALONG_Y	3, right_y3
right_y2:			ALONG_Y	2, right_y2
right_y1:			ALONG_Y	1, right_y1
right_y0:			ALONG_Y	0, right_y0
					inc		l
					jp		right_y7

left_y0:			ALONG_Y	0, left_y0
left_y1:			ALONG_Y	1, left_y1
left_y2:			ALONG_Y	2, left_y2
left_y3:			ALONG_Y	3, left_y3
left_y4:			ALONG_Y	4, left_y4
left_y5:			ALONG_Y	5, left_y5
left_y6:			ALONG_Y	6, left_y6
left_y7:			ALONG_Y	7, left_y7
					dec		l
					jp		left_y0


; ---------------------------------------------------------------------------
; clear_box: blank the bytes of rows C..C+B-1, columns D..D+E-1 (E 1..32),
; on the screen screen_high says. Uses A, BC, HL.

clear_box:
					ld		a,e					; jump E stores from the end
					add		a,a
					neg
					ld		l,a
					ld		h,$FF
					push	de
					ld		de,.stores_end
					add		hl,de
					pop		de
					ld		(.into + 1),hl
.row:				ld		l,c
					ld		h,high ROW_TABLE
					ld		a,(hl)
					or		d
					inc		h
					ld		h,(hl)
					ld		l,a
					ld		a,(screen_high)
					or		h
					ld		h,a
					xor		a
.into:				jp		0
.stores:
					DUP		32
					ld		(hl),a
					inc		l
					EDUP
.stores_end:		inc		c
					djnz	.row
					ret
