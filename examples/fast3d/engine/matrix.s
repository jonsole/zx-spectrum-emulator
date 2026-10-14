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
; The entries go into `matrix` (row by row, signed bytes) and, as the two
; table addresses each product needs, into rotate's code.
;
; In: angle_x, angle_y, angle_z, 256 to the turn.
; Uses everything but IY and the alternate registers. 3,814 T-states.

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

; DE = the sum: round it to the entry, keep it in matrix + index, and write
; rotate's two addresses for it; DE = 0 and H = SINE's page again after.
					MACRO	ENTRY	SUM_AT, DIFF_AT, INDEX
					ld		hl,32
					add		hl,de
					add		hl,hl
					add		hl,hl				; H = (sum + 32) >> 6
					ld		a,h
					ld		(matrix + INDEX),a
					ld		e,a
					add		a,a
					sbc		a,a
					ld		d,a					; DE = m, sign-extended
					ld		hl,SQ_CENTRE - 128
					add		hl,de
					ld		(SUM_AT + 1),hl		; for f(v + m)
					ld		hl,SQ_CENTRE - 128
					or		a
					sbc		hl,de
					ld		(DIFF_AT + 1),hl		; for f(v - m)
					ld		h,high SINE_LO
					ld		de,0
					ENDM

make_matrix:
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
					ENTRY	m00_sum, m00_diff, 0

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
					ENTRY	m01_sum, m01_diff, 1

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
					ENTRY	m02_sum, m02_diff, 2

					; m10 = cy sz = 2 [s(z+y) + s(z-y)]
					ld		a,ixl
					add		a,c
					SINE_ADD
					ld		a,ixl
					sub		c
					SINE_ADD
					DOUBLE
					ENTRY	m10_sum, m10_diff, 3

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
					ENTRY	m11_sum, m11_diff, 4

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
					ENTRY	m12_sum, m12_diff, 5

					; m20 = -sy = -4 s(y)
					ld		a,c
					add		a,128
					SINE_ADD
					DOUBLE
					DOUBLE
					ENTRY	m20_sum, m20_diff, 6

					; m21 = sx cy = 2 [s(x+y) + s(x-y)]
					ld		a,b
					add		a,c
					SINE_ADD
					ld		a,b
					sub		c
					SINE_ADD
					DOUBLE
					ENTRY	m21_sum, m21_diff, 7

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
					ENTRY	m22_sum, m22_diff, 8
					ret

angle_x:			DB		0
angle_y:			DB		0
angle_z:			DB		0
matrix:				DS		9					; m00 m01 m02 m10 ... m22
