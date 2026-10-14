; fast3d: rotate, a vertex by the matrix make_matrix last made.
;
; Each of the nine products m*v is f(v+m) - f(v-m), as in mul8s, but the
; matrix only changes once a frame, so make_matrix writes SQ_CENTRE - 128 + m
; and SQ_CENTRE - 128 - m into the LD HL,nn below. Then with DE = v + 128,
; one ADD HL,DE points at f(v+m), and another at f(v-m): nine bits each, the
; carry taken care of by the 16-bit add.
;
; In: HL -> the vertex, three signed bytes x, y, z.
; Out: rot_x, rot_y, rot_z, the 16-bit sums M v -- 128 times the rotated
;      vertex (times 127/128: a matrix entry of 127 is 1.0).
; Uses everything but IY and the alternate registers.
; 1,241 T-states, with the RET.

; HL -> f(v+m)'s low byte: load f into BC.
					MACRO	SQ_LOAD
					ld		c,(hl)
					inc		h
					inc		h
					ld		b,(hl)
					ENDM

; HL -> f(v+m)'s low byte: BC += f.
					MACRO	SQ_ADD
					ld		a,(hl)
					add		a,c
					ld		c,a
					inc		h
					inc		h
					ld		a,(hl)
					adc		a,b
					ld		b,a
					ENDM

; HL -> f(v-m)'s low byte: BC -= f.
					MACRO	SQ_SUB
					ld		a,c
					sub		(hl)
					ld		c,a
					inc		h
					inc		h
					ld		a,b
					sbc		a,(hl)
					ld		b,a
					ENDM

rotate:
					ld		a,(hl)				; the vertex, biased by 128
					xor		$80
					ld		ixl,a				; IXL = x + 128
					inc		hl
					ld		a,(hl)
					xor		$80
					ld		ixh,a				; IXH = y + 128
					inc		hl
					ld		a,(hl)
					xor		$80
					ld		(rotate_z1 + 1),a			; and z + 128, three times
					ld		(rotate_z2 + 1),a
					ld		d,0

					; rot_x = m00 x + m01 y + m02 z
					ld		e,ixl
m00_sum:			ld		hl,0
					add		hl,de
					SQ_LOAD
m00_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
					ld		e,ixh
m01_sum:			ld		hl,0
					add		hl,de
					SQ_ADD
m01_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
rotate_z1:				ld		e,0
m02_sum:			ld		hl,0
					add		hl,de
					SQ_ADD
m02_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
					ld		(rot_x),bc

					; rot_y = m12 z + m11 y + m10 x: z is still in E
m12_sum:			ld		hl,0
					add		hl,de
					SQ_LOAD
m12_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
					ld		e,ixh
m11_sum:			ld		hl,0
					add		hl,de
					SQ_ADD
m11_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
					ld		e,ixl
m10_sum:			ld		hl,0
					add		hl,de
					SQ_ADD
m10_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
					ld		(rot_y),bc

					; rot_z = m20 x + m21 y + m22 z: x is still in E
m20_sum:			ld		hl,0
					add		hl,de
					SQ_LOAD
m20_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
					ld		e,ixh
m21_sum:			ld		hl,0
					add		hl,de
					SQ_ADD
m21_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
rotate_z2:				ld		e,0
m22_sum:			ld		hl,0
					add		hl,de
					SQ_ADD
m22_diff:			ld		hl,0
					add		hl,de
					SQ_SUB
					ld		(rot_z),bc
					ret

rot_x:				DW		0
rot_y:				DW		0
rot_z:				DW		0
