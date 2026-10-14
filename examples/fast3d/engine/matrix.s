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

; DE = the sum: round it to the entry and keep it in matrix + INDEX, and in
; its place in matrix_t, the transpose; DE = 0 and H = SINE's page again
; after.
					MACRO	ENTRY	INDEX
					ld		hl,32
					add		hl,de
					add		hl,hl
					add		hl,hl				; H = (sum + 32) >> 6
					ld		a,h
					ld		(matrix + INDEX),a
					ld		(matrix_t + (INDEX % 3) * 3 + INDEX / 3),a
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
matrix_t:			DS		9					; and by columns: m00 m10 m20 m01 ...
													; each a vector rotate can take


; ---------------------------------------------------------------------------
; install_matrix: the 9 signed bytes at HL, row by row (127 for 1.0), into
; rotate: for each entry m, SQ_CENTRE - 128 + m and SQ_CENTRE - 128 - m into
; the two LD HL,nn of its product. Unrolled, each operand written by its own
; LD (nn),HL: a picture installs a matrix ten times or so -- the camera's,
; and each object's -- and a loop through a list of where they go took 300
; T-states an entry to this's 111. Uses A, BC, DE, HL.

; The entry at DE into SUM and DIFF's operands; DE on to the next.
					MACRO	INSTALL	SUM, DIFF
					ld		a,(de)
					inc		de
					ld		c,a
					add		a,a
					sbc		a,a
					ld		b,a					; BC = m, sign-extended
					ld		hl,SQ_CENTRE - 128
					add		hl,bc
					ld		(SUM + 1),hl		; for f(v + m)
					ld		hl,SQ_CENTRE - 128
					or		a
					sbc		hl,bc
					ld		(DIFF + 1),hl		; for f(v - m)
					ENDM

install_matrix:
					ex		de,hl
					INSTALL	m00_sum, m00_diff
					INSTALL	m01_sum, m01_diff
					INSTALL	m02_sum, m02_diff
					INSTALL	m10_sum, m10_diff
					INSTALL	m11_sum, m11_diff
					INSTALL	m12_sum, m12_diff
					INSTALL	m20_sum, m20_diff
					INSTALL	m21_sum, m21_diff
					INSTALL	m22_sum, m22_diff
					ret

; install_into: the same, into the operands listed at IX, two an entry: the
; loop install_matrix was, for set_camera's rough rows, once a picture. Uses
; everything but IY and the alternate registers.
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
