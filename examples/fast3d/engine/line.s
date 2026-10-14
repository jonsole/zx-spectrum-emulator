; fast3d: draw_line, a line of pixels by Bresenham, and clear_box.
;
; The line is drawn downwards (its ends swapped if need be), stepping along
; whichever of x and y it is longer in. Each of the four ways it can go --
; along x or along y, to the right or the left -- is a set of blocks, one
; for each bit of a screen byte (and along y, for each row of the character
; cell too), so a pixel is one SET b,(HL); moving to the next bit is falling
; into the next block, and to the next byte, INC L or DEC L once in eight
; pixels. draw_line works out where the line starts and RETs into the block
; for its first pixel; the last pixel's block RETs to the caller. build.py
; writes the blocks (output/lines_gen.s).
;
; About 60 T-states a pixel along x (40 when it stays on a row), and 46
; along y, where each pixel steps down a row: that takes working out on the
; Spectrum's screen, but only once in eight rows, when the block knows it
; has reached the cell's last.

; The rows' addresses, for the screen at $4000: ROW_TABLE + y is the low
; byte, ROW_TABLE + 256 + y the high. Page-aligned; build.py fills it.
					ALIGN	256
ROW_TABLE:
					INCLUDE	"output/rows_gen.s"

; ---------------------------------------------------------------------------
; draw_line: from (B, C) to (D, E), x 0..255 and y 0..191, on the screen
; screen_high says: $00 for the one at $4000, $80 for $C000. The blocks are
; in output/lines_gen.s, from build.py: along x, one a bit, 40 T-states a
; pixel that stays on its row and 77 for one that steps down; along y, one
; a bit and row of the character cell, so that the seven rows in eight
; that step down with INC H alone cost 42 a pixel, and the eighth, which
; works out the next cell, 75 (a loop that worked it out every pixel cost
; 75 for all of them). Uses everything but IY and the alternate registers.

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
.ordered:			ld		e,a					; E = dy
					ld		a,d
					sub		b
					ld		l,0					; L = 0 to the right, 16 to the
					jr		nc,.right			; left
					neg
					ld		l,16
.right:				ld		d,a					; D = |dx|
					cp		e
					jr		c,.along_y
					ld		a,b					; along x: the entry by the side
					and		7					; and x0's bit
					add		a,a
					add		a,l
					add		a,low x_entries
					ld		l,a
					ld		h,high x_entries
					ld		a,(hl)
					inc		l
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
					ld		a,d					; D = dx, E = dy, B = dx + 1
					ld		b,a					; pixels, the error dx / 2
					inc		b
					srl		a
					ret
.along_y:			ld		a,l					; the entry by the side (0 or
					add		a,a					; 128), x0's bit (16 each) and
					add		a,a					; y0's row (2 each)
					add		a,a
					ld		l,a
					ld		a,b
					and		7
					add		a,a
					add		a,a
					add		a,a
					add		a,a
					add		a,l
					ld		l,a
					ld		a,c
					and		7
					add		a,a
					add		a,l
					ld		l,a
					ld		h,high y_entries
					ld		a,(hl)
					inc		l
					ld		h,(hl)
					ld		l,a
					push	hl
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
					ld		a,e					; D = dy, E = dx, B = dy + 1
					ld		b,a					; pixels, the error dy / 2
					inc		b
					ld		e,d
					ld		d,a
					srl		a
					ret

screen_high:		DB		0

					INCLUDE	"output/lines_gen.s"


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
