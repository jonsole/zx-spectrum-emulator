; fast3d: make_matrix, the rotation Rz Ry Rx for three angles, without a
; single multiplication.
;
; Every entry of Rz(z) Ry(y) Rx(x) is a product of two or three sines and
; cosines, and each such product is a sum of sines of sums of the angles:
; cos A cos B = (cos(A-B) + cos(A+B)) / 2, and its relatives. So each entry
; is at most four sines of sums plus twice two more (model.matrix_sums has
; them), every one a lookup in a table of 2032 sin(a) -- a minus sign is half
; a turn more, a cosine a quarter. The sum is 4 * 2032 times the entry, and
; (sum + 32) >> 6 is the entry with 127 for 1.0, rounded once, never past 127.
;
; compute_matrix leaves the entries in `matrix` (row by row, signed bytes);
; make_matrix also installs them into rotate's code, as the two table
; addresses each product needs (install_matrix).
;
; In: angle_x, angle_y, angle_z, 256 to the turn.
; Uses everything but IY and the alternate registers.

; DE += SINE(A).
					MACRO	SINE_ADD
					ld		l,a
					ld		a,(hl)
					add		a,e
					ld		e,a
					inc		h
					ld		a,(hl)
					adc		a,d
					ld		d,a
					dec		h
					ENDM

; DE *= 2.
					MACRO	DOUBLE
					sla		e
					rl		d
					ENDM

; DE = the sum: round it to the entry and keep it in matrix + INDEX; DE = 0
; and H = SINE's page again after.
					MACRO	ENTRY	INDEX
					ld		hl,32
					add		hl,de
					add		hl,hl
					add		hl,hl				; H = (sum + 32) >> 6
					ld		a,h
					ld		(matrix + INDEX),a
					ld		h,high SINE_LO
					ld		de,0
					ENDM

; make_matrix: compute_matrix, then install_matrix it into rotate.
make_matrix:
					call	compute_matrix
					ld		hl,matrix
					jp		install_matrix

compute_matrix:
					ld		a,(angle_z)
					ld		ixl,a				; IXL = z
					ld		a,(angle_y)
					ld		c,a					; C = y
					ld		a,(angle_x)
					ld		b,a					; B = x
					ld		h,high SINE_LO
					ld		de,0

					; m00 = cy cz = 2 [c(y-z) + c(y+z)]
					ld		a,c
					sub		ixl
					add		a,64
					SINE_ADD
					ld		a,c
					add		a,ixl
					add		a,64
					SINE_ADD
					DOUBLE
					ENTRY	0

					; m01 = sx sy cz - cx sz
					;     = -2 [s(z+x) + s(z-x)]
					;       + c(x-y-z) + c(x-y+z) - c(x+y-z) - c(x+y+z)
					ld		a,ixl
					add		a,b
					add		a,128
					SINE_ADD
					ld		a,ixl
					sub		b
					add		a,128
					SINE_ADD
					DOUBLE
					ld		a,b
					sub		c
					sub		ixl
					add		a,64
					SINE_ADD
					ld		a,b
					sub		c
					add		a,ixl
					add		a,64
					SINE_ADD
					ld		a,b
					add		a,c
					sub		ixl
					add		a,192
					SINE_ADD
					ld		a,b
					add		a,c
					add		a,ixl
					add		a,192
					SINE_ADD
					ENTRY	1

					; m02 = cx sy cz + sx sz
					;     = 2 [c(x-z) - c(x+z)]
					;       + s(x+y+z) + s(x+y-z) - s(x-y+z) - s(x-y-z)
					ld		a,b
					sub		ixl
					add		a,64
					SINE_ADD
					ld		a,b
					add		a,ixl
					add		a,192
					SINE_ADD
					DOUBLE
					ld		a,b
					add		a,c
					add		a,ixl
					SINE_ADD
					ld		a,b
					add		a,c
					sub		ixl
					SINE_ADD
					ld		a,b
					sub		c
					add		a,ixl
					add		a,128
					SINE_ADD
					ld		a,b
					sub		c
					sub		ixl
					add		a,128
					SINE_ADD
					ENTRY	2

					; m10 = cy sz = 2 [s(z+y) + s(z-y)]
					ld		a,ixl
					add		a,c
					SINE_ADD
					ld		a,ixl
					sub		c
					SINE_ADD
					DOUBLE
					ENTRY	3

					; m11 = sx sy sz + cx cz
					;     = 2 [c(x-z) + c(x+z)]
					;       + s(z+x-y) + s(z-x+y) - s(z+x+y) - s(z-x-y)
					ld		a,b
					sub		ixl
					add		a,64
					SINE_ADD
					ld		a,b
					add		a,ixl
					add		a,64
					SINE_ADD
					DOUBLE
					ld		a,b
					sub		c
					add		a,ixl
					SINE_ADD
					ld		a,c
					sub		b
					add		a,ixl
					SINE_ADD
					ld		a,b
					add		a,c
					add		a,ixl
					add		a,128
					SINE_ADD
					ld		a,ixl
					sub		b
					sub		c
					add		a,128
					SINE_ADD
					ENTRY	4

					; m12 = cx sy sz - sx cz
					;     = -2 [s(x+z) + s(x-z)]
					;       + c(x+y-z) - c(x+y+z) - c(x-y-z) + c(x-y+z)
					ld		a,b
					add		a,ixl
					add		a,128
					SINE_ADD
					ld		a,b
					sub		ixl
					add		a,128
					SINE_ADD
					DOUBLE
					ld		a,b
					add		a,c
					sub		ixl
					add		a,64
					SINE_ADD
					ld		a,b
					add		a,c
					add		a,ixl
					add		a,192
					SINE_ADD
					ld		a,b
					sub		c
					sub		ixl
					add		a,192
					SINE_ADD
					ld		a,b
					sub		c
					add		a,ixl
					add		a,64
					SINE_ADD
					ENTRY	5

					; m20 = -sy = -4 s(y)
					ld		a,c
					add		a,128
					SINE_ADD
					DOUBLE
					DOUBLE
					ENTRY	6

					; m21 = sx cy = 2 [s(x+y) + s(x-y)]
					ld		a,b
					add		a,c
					SINE_ADD
					ld		a,b
					sub		c
					SINE_ADD
					DOUBLE
					ENTRY	7

					; m22 = cx cy = 2 [c(x-y) + c(x+y)]
					ld		a,b
					sub		c
					add		a,64
					SINE_ADD
					ld		a,b
					add		a,c
					add		a,64
					SINE_ADD
					DOUBLE
					ENTRY	8
					ret

angle_x:			DB		0
angle_y:			DB		0
angle_z:			DB		0
matrix:				DS		9					; m00 m01 m02 m10 ... m22


; ---------------------------------------------------------------------------
; install_matrix: the 9 signed bytes at HL, row by row (127 for 1.0), into
; rotate: for each entry m, SQ_CENTRE - 128 + m and SQ_CENTRE - 128 - m into
; the two LD HL,nn of its product. Uses everything but IY and the alternate
; registers.

install_matrix:
					ld		ix,install_targets
; install_into: the same, into the operands listed at IX (two a entry, as
; install_targets).
install_into:
					ld		b,9
.entry:				ld		a,(hl)
					inc		hl
					push	hl
					ld		e,a
					add		a,a
					sbc		a,a
					ld		d,a					; DE = m, sign-extended
					ld		hl,SQ_CENTRE - 128
					add		hl,de
					ld		c,l					; for f(v + m)
					ld		a,h
					ld		l,(ix + 0)
					ld		h,(ix + 1)
					ld		(hl),c
					inc		hl
					ld		(hl),a
					ld		hl,SQ_CENTRE - 128
					or		a
					sbc		hl,de
					ld		c,l					; for f(v - m)
					ld		a,h
					ld		l,(ix + 2)
					ld		h,(ix + 3)
					ld		(hl),c
					inc		hl
					ld		(hl),a
					ld		de,4
					add		ix,de
					pop		hl
					djnz	.entry
					ret

; Where each entry's two addresses go: the operands of rotate's LD HL,nn.
install_targets:	DW		m00_sum + 1, m00_diff + 1, m01_sum + 1, m01_diff + 1, m02_sum + 1, m02_diff + 1
					DW		m10_sum + 1, m10_diff + 1, m11_sum + 1, m11_diff + 1, m12_sum + 1, m12_diff + 1
					DW		m20_sum + 1, m20_diff + 1, m21_sum + 1, m21_diff + 1, m22_sum + 1, m22_diff + 1
