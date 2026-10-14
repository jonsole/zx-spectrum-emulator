; fast3d: objects and the camera -- what is in view, and drawing it.
;
; A model is a list of vertices (signed bytes) that its faces share: a face
; is a loop of indices into the list, so each vertex is transformed once a
; frame however many faces use it, and the edges (build.py works them out
; from the faces) take each shared edge once. An object is a model at a
; 16-bit world position, turned by three angles; so is the camera. Camera
; space has x right, y up and z forward. model.py has all the arithmetic.
;
; With Rc the camera's matrix and Ro an object's, a vertex v of an object at
; P, from a camera at C, is at  Rc^T (P - C) + (Rc^T Ro) v  in camera space:
; one translation T and one matrix M an object, and both come from rotate,
; with Rc^T installed in it:
;
; - T = Rc^T (P - C), 16-bit by 8-bit, is two rotates: of P - C's high bytes
;   (times 256) and of its low bytes (less 128, so that they are signed), and
;   128 Rc^T (1, 1, 1), set_camera's, to put the 128s back. Exact, 24 bits.
; - Each column of M is Rc^T times a column of Ro -- a vector of signed bytes:
;   three rotates, not 27 multiplications.
;
; cull_object needs only T: an object is left out when its bounding sphere
; is wholly nearer than NEAR, farther than FAR, or beyond one of the planes
; |x| = z / 2, |y| = z / 2 -- a 90-degree view, as wide as the screen and a
; little taller, so that it never leaves out what the screen would show; the
; lines clip what it lets through. It goes in three steps, each quicker than
; the next and settling most of what is left:
;
; 1. More than VIEW_BOX from the camera on any axis: out, at once.
; 2. A rough T, from the high bytes alone, a row at a time -- depth first,
;    then x, then y, each a few quarter squares (rough_row_z and so on, which
;    set_camera writes Rc^T into) -- and tested as it comes: behind the eye
;    or too far, out after one row; beside the view, after two. Leaving out
;    the low bytes' rotation -- of a vector each of whose parts is within 128 -- is at
;    most 128 sqrt 3 times the length of a column of Rc out on each axis;
;    a column, rounding and all, is never longer than 128, so ROUGH = 128 *
;    128 sqrt 3 will do. The tests are made with the sphere that much bigger
;    (three times, for the side planes, whose 2x - z can be out by 3 ROUGH). Out even so: out. Most of what is out of view goes
;    here, after one rotate.
; 3. The exact T (the low bytes' rotate too), and the tests again: what is
;    left, near a plane or in view. In view, T is what transform_object
;    draws with.
;
; So the answer is always the exact test's (model.culled), and only reached
; quicker.

NEAR				EQU		8					; model.NEAR, FAR, VIEW_BOX
FAR					EQU		8191
VIEW_BOX			EQU		10400
ROUGH				EQU		28380				; >= 128 * 128 sqrt 3 (see step 2)

; An object, OBJECT_SIZE bytes: x, y, z (16-bit), three angles, and its model.
OBJECT_X			EQU		0
OBJECT_ANGLES		EQU		6
OBJECT_MODEL		EQU		9
OBJECT_SIZE			EQU		11

; A model: how many vertices and where, edges, faces; and its bounding
; radius, as 128 r and 128 r sqrt 5 (rounded up) -- what culling compares.
MODEL_VERTICES		EQU		0					; DB count, DW -> x, y, z bytes
MODEL_EDGES			EQU		3					; DB count, DW -> pairs of indices
MODEL_FACES			EQU		6					; DB count, DW -> each a DB n and n indices
MODEL_R_VIEW		EQU		9					; DW 128 r
MODEL_R5			EQU		11					; DW 128 r sqrt 5

; 24-bit numbers in C:H:L, from and to three bytes in memory, low first.
					MACRO	LOAD24	AT
					ld		hl,(AT)
					ld		a,(AT + 2)
					ld		c,a
					ENDM
					MACRO	STORE24	AT
					ld		(AT),hl
					ld		a,c
					ld		(AT + 2),a
					ENDM
					MACRO	ADD24	AT
					ld		de,(AT)
					add		hl,de
					ld		a,(AT + 2)
					adc		a,c
					ld		c,a
					ENDM
					MACRO	SUB24	AT
					ld		de,(AT)
					or		a
					sbc		hl,de
					ld		a,(AT + 2)
					ld		b,a
					ld		a,c
					sbc		a,b
					ld		c,a
					ENDM
					MACRO	ADD16	AT					; an unsigned 16-bit number
					ld		de,(AT)
					add		hl,de
					ld		a,c
					adc		a,0
					ld		c,a
					ENDM
					MACRO	SUB16	AT
					ld		de,(AT)
					or		a
					sbc		hl,de
					ld		a,c
					sbc		a,0
					ld		c,a
					ENDM
					MACRO	DOUBLE24
					add		hl,hl
					rl		c
					ENDM
; Jump to WHERE if C:H:L > 0.
					MACRO	IF_POSITIVE	WHERE
					bit		7,c
					jr		nz,.not_positive
					ld		a,c
					or		h
					or		l
					jp		nz,WHERE
.not_positive:
					ENDM


; ---------------------------------------------------------------------------
; set_camera: the camera at camera_x, camera_y, camera_z, turned by
; camera_angles. Works out its matrix, installs its transpose in rotate,
; and 128 Rc^T (1, 1, 1). Once a frame, before cull_object. Uses everything
; but IY and the alternate registers.

set_camera:
					ld		hl,camera_angles
					ld		de,angle_x
					ld		bc,3
					ldir
					call	compute_matrix
					ld		hl,matrix			; Rc^T: the rows of Rc^T are
					ld		de,camera_seen		; Rc's columns
					ld		b,3
.column:			push	hl
					ld		a,(hl)
					ld		(de),a
					inc		de
					inc		hl
					inc		hl
					inc		hl
					ld		a,(hl)
					ld		(de),a
					inc		de
					inc		hl
					inc		hl
					inc		hl
					ld		a,(hl)
					ld		(de),a
					inc		de
					pop		hl
					inc		hl
					djnz	.column
					ld		hl,camera_seen		; the rough rows
					ld		ix,rough_targets
					call	install_into
					xor		a
					ld		(rotate_holds_camera),a
					call	hold_camera
					ld		hl,ones				; 128 Rc^T (1, 1, 1), each
					call	rotate				; 24 bits
					ld		hl,rot_x
					ld		de,camera_k
					ld		b,3
.constant:			push	bc
					ld		c,(hl)
					inc		hl
					ld		a,(hl)
					inc		hl
					push	hl
					ld		l,c
					ld		h,a
					add		a,a
					sbc		a,a
					ld		c,a					; C:H:L = the rotation
					ld		b,7
.times128:			add		hl,hl
					rl		c
					djnz	.times128
					ex		de,hl
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(hl),c
					inc		hl
					ex		de,hl
					pop		hl
					pop		bc
					djnz	.constant
					ret

ones:				DB		1, 1, 1

; hold_camera: Rc^T in rotate, if something else is. Uses what install_matrix
; does.
hold_camera:
					ld		a,(rotate_holds_camera)
					or		a
					ret		nz
					ld		hl,camera_seen
					call	install_matrix
					ld		a,1
					ld		(rotate_holds_camera),a
					ret

camera_x:			DW		0
camera_y:			DW		0
camera_z:			DW		0
camera_angles:		DS		3
camera_seen:		DS		9					; Rc^T, row by row
camera_k:			DS		9					; 128 Rc^T (1, 1, 1), three 24-bit
rotate_holds_camera: DB		0


; ---------------------------------------------------------------------------
; cull_object: is the object at IX in view? Carry set if not; else carry
; clear and view_t its centre in camera space (three 24-bit numbers, 127 to
; the unit). Uses everything but IY and the alternate registers.

; P - C on one axis, into the high and low vectors; out of the box: culled.
					MACRO	AXIS_APART	OFFSET
					ld		l,(ix + OBJECT_X + OFFSET)
					ld		h,(ix + OBJECT_X + OFFSET + 1)
					ld		de,(camera_x + OFFSET)
					or		a
					sbc		hl,de
					jp		pe,cull_box_out			; P - C will not fit 16 bits
					bit		7,h
					jr		nz,.negative
					ld		de,-(VIEW_BOX + 1)
					push	hl
					add		hl,de
					pop		hl
					jp		c,cull_box_out			; more than VIEW_BOX
					jr		.in_box
.negative:			ld		de,VIEW_BOX
					push	hl
					add		hl,de
					pop		hl
					jp		nc,cull_box_out			; less than -VIEW_BOX
.in_box:			ld		a,h
					ld		(cull_high + OFFSET / 2),a
					xor		$80
					ld		(cull_biased + OFFSET / 2),a
					ld		a,l
					xor		$80
					ld		(cull_low + OFFSET / 2),a
					ENDM

; T on one axis: 256 the high rotation + the low + 128 Rc^T (1, 1, 1).
					MACRO	AXIS_T	INDEX
					ld		hl,(rot_x + 2 * INDEX)
					ld		a,h
					add		a,a
					sbc		a,a
					ld		c,a					; the low rotation, 24 bits
					ADD24	camera_k + 3 * INDEX
					ld		a,(cull_rotated + 2 * INDEX)
					add		a,h					; + 256 the high rotation
					ld		h,a
					ld		a,(cull_rotated + 2 * INDEX + 1)
					adc		a,c
					ld		c,a
					STORE24	view_t + 3 * INDEX
					ENDM

cull_object:
					ld		(cull_at),ix
					AXIS_APART	0
					AXIS_APART	2
					AXIS_APART	4
					ld		l,(ix + OBJECT_MODEL)	; the model's radii, 24 bits
					ld		h,(ix + OBJECT_MODEL + 1)
					ld		de,MODEL_R_VIEW
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		(cull_r_view),de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		(cull_r5),de
					xor		a
					ld		(cull_r_view + 2),a
					ld		(cull_r5 + 2),a
					ld		hl,(cull_r_view)	; first, the radii with the
					ld		de,ROUGH & $FFFF	; rough T's margin
					add		hl,de
					ld		(cull_radius),hl
					adc		a,ROUGH >> 16
					ld		(cull_radius + 2),a
					ld		hl,(cull_r5)
					ld		de,(3 * ROUGH) & $FFFF
					add		hl,de
					ld		(cull_radius5),hl
					ld		a,0
					adc		a,(3 * ROUGH) >> 16
					ld		(cull_radius5 + 2),a

					call	rough_row_z			; the rough depth
					ld		de,view_t + 6
					ld		hl,camera_k + 6
					call	rough_t
					call	test_depth
					jp		c,cull_out
					call	rough_row_x			; across
					ld		de,view_t
					ld		hl,camera_k
					call	rough_t
					ld		hl,view_t
					call	test_side
					jp		c,cull_out
					call	rough_row_y			; and up and down
					ld		de,view_t + 3
					ld		hl,camera_k + 3
					call	rough_t
					ld		hl,view_t + 3
					call	test_side
					jp		c,cull_out

					call	hold_camera			; the exact T
					ld		hl,cull_high
					call	rotate
					ld		hl,rot_x
					ld		de,cull_rotated
					ld		bc,6
					ldir
					ld		hl,cull_low
					call	rotate
					AXIS_T	0
					AXIS_T	1
					AXIS_T	2
					ld		hl,cull_r_view		; and the radii exactly
					ld		de,cull_radius
					ld		bc,6
					ldir
					call	test_depth
					jp		c,cull_out
					ld		hl,view_t
					call	test_side
					jp		c,cull_out
					ld		hl,view_t + 3
					call	test_side
cull_out:			ld		ix,(cull_at)		; (carry: out)
					ret
cull_box_out:		ld		ix,(cull_at)
					scf
					ret

; rough_t: the 24 bits at DE = 256 BC + the 24 bits at HL (camera_k's).
rough_t:
					ld		a,(hl)
					ld		(de),a
					inc		hl
					inc		de
					ld		a,(hl)
					add		a,c
					ld		(de),a
					inc		hl
					inc		de
					ld		a,(hl)
					adc		a,b
					ld		(de),a
					ret

; test_depth: carry set if the sphere at view_t, of the radii at cull_radius,
; is wholly nearer than NEAR or farther than FAR; and cull_b = its z +
; cull_radius5, for test_side.
test_depth:
					LOAD24	view_t + 6			; nearer than NEAR?
					ADD24	cull_radius
					ld		de,NEAR * 127
					or		a
					sbc		hl,de
					ld		a,c
					sbc		a,0
					jp		m,.out
					LOAD24	view_t + 6			; farther than FAR?
					SUB24	cull_radius
					ld		de,(FAR * 128) & $FFFF
					or		a
					sbc		hl,de
					ld		a,c
					sbc		a,(FAR * 128) >> 16
					ld		c,a
					IF_POSITIVE	.out
					LOAD24	view_t + 6
					ADD24	cull_radius5
					STORE24	cull_b
					and		a
					ret
.out:				scf
					ret

; test_side: carry set if the sphere is wholly beyond either plane of a pair:
; for t the 24 bits at HL (its x or y), 2 t - z > r sqrt 5 or 2 t + z +
; r sqrt 5 < 0, with z + r sqrt 5 already in cull_b.
test_side:
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		c,(hl)
					ex		de,hl
					DOUBLE24
					STORE24	cull_2t
					SUB24	cull_b
					IF_POSITIVE	.out
					LOAD24	cull_2t
					ADD24	cull_b
					bit		7,c
					jr		nz,.out
					and		a
					ret
.out:				scf
					ret

; The rough rows: BC = a row of Rc^T times P - C's high bytes, by quarter
; squares as in rotate; set_camera writes the entries in.
					MACRO	ROUGH_ROW	S0, D0, S1, D1, S2, D2
					ld		d,0
					ld		a,(cull_biased)
					ld		e,a
S0:					ld		hl,0
					add		hl,de
					SQ_LOAD
D0:					ld		hl,0
					add		hl,de
					SQ_SUB
					ld		a,(cull_biased + 1)
					ld		e,a
S1:					ld		hl,0
					add		hl,de
					SQ_ADD
D1:					ld		hl,0
					add		hl,de
					SQ_SUB
					ld		a,(cull_biased + 2)
					ld		e,a
S2:					ld		hl,0
					add		hl,de
					SQ_ADD
D2:					ld		hl,0
					add		hl,de
					SQ_SUB
					ret
					ENDM

rough_row_x:		ROUGH_ROW	rx0s, rx0d, rx1s, rx1d, rx2s, rx2d
rough_row_y:		ROUGH_ROW	ry0s, ry0d, ry1s, ry1d, ry2s, ry2d
rough_row_z:		ROUGH_ROW	rz0s, rz0d, rz1s, rz1d, rz2s, rz2d

rough_targets:		DW		rx0s + 1, rx0d + 1, rx1s + 1, rx1d + 1, rx2s + 1, rx2d + 1
					DW		ry0s + 1, ry0d + 1, ry1s + 1, ry1d + 1, ry2s + 1, ry2d + 1
					DW		rz0s + 1, rz0d + 1, rz1s + 1, rz1d + 1, rz2s + 1, rz2d + 1

cull_radius:		DS		3					; the radii being tested with
cull_radius5:		DS		3
cull_b:				DS		3					; z + r sqrt 5
cull_2t:			DS		3					; 2 x, or 2 y

cull_at:			DW		0
cull_high:			DS		3					; P - C's high bytes
cull_biased:		DS		3					; and + 128, for the rough rows
cull_low:			DS		3					; and low, less 128
cull_rotated:		DS		6					; the high bytes' rotation
cull_r_view:		DS		3					; 128 r, 24 bits
cull_r5:			DS		3					; 128 r sqrt 5
view_t:				DS		9					; the object's centre in camera
												; space: three 24-bit numbers


; ---------------------------------------------------------------------------
; object_matrix: view_m = Rc^T Ro for the object at IX, 127 for 1.0: each
; column a rotate (Rc^T in it) of a column of the object's own matrix, q
; rounded to q / 127 as (q + (q >> 7) + 64) >> 7 and held to +-127. Uses
; everything but IY and the alternate registers.

object_matrix:
					ld		(cull_at),ix
					ld		a,(ix + OBJECT_ANGLES)
					ld		(angle_x),a
					ld		a,(ix + OBJECT_ANGLES + 1)
					ld		(angle_y),a
					ld		a,(ix + OBJECT_ANGLES + 2)
					ld		(angle_z),a
					call	compute_matrix		; Ro, in matrix
					call	hold_camera
					ld		b,0					; B = the column
.column:			push	bc
					ld		c,b
					ld		b,0
					ld		hl,matrix
					add		hl,bc
					ld		de,om_column
					ld		a,(hl)				; Ro's column B
					ld		(de),a
					inc		de
					inc		hl
					inc		hl
					inc		hl
					ld		a,(hl)
					ld		(de),a
					inc		de
					inc		hl
					inc		hl
					inc		hl
					ld		a,(hl)
					ld		(de),a
					ld		hl,om_column
					call	rotate				; Rc^T times it
					pop		bc
					push	bc
					ld		c,b
					ld		b,0
					ld		hl,view_m			; into M's column B
					add		hl,bc
					ld		de,rot_x
					ld		b,3
.entry:				push	bc
					push	hl
					ex		de,hl
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					push	hl
					ex		de,hl				; HL = q
					call	.round
					pop		de
					pop		hl
					ld		(hl),a
					inc		hl
					inc		hl
					inc		hl
					pop		bc
					djnz	.entry
					pop		bc
					inc		b
					ld		a,b
					cp		3
					jr		nz,.column
					ld		ix,(cull_at)
					ret

; A = (HL + (HL >> 7) + 64) >> 7, held to +-127. Uses DE.
.round:				call	.shift7
					add		hl,de
					ld		de,64
					add		hl,de
					call	.shift7				; DE = the entry, 9 bits
					ld		a,d
					or		a
					ld		a,e
					jr		nz,.negative
					cp		128
					ret		c
					ld		a,127
					ret
.negative:			cp		129
					ret		nc
					ld		a,-127
					ret
; DE = HL >> 7 (HL signed).
.shift7:			ld		a,l
					add		a,a
					ld		a,h
					adc		a,a
					ld		e,a
					sbc		a,a
					ld		d,a
					ret

om_column:			DS		3
view_m:				DS		9					; M, row by row


; ---------------------------------------------------------------------------
; transform_object: the vertices of the object at IX to the screen, by
; view_m and view_t (cull_object's and object_matrix's), into the points at
; DE: x, y, 16-bit, four bytes a vertex; one at or behind the eye gets x =
; WIDE_BEHIND. Each vertex's position in camera space is shifted right just
; enough to bring its depth into a byte (model.project_far), so the quick
; divide does at any distance. Uses everything but IY and the alternate
; registers.

transform_object:
					ld		(to_point),de
					ld		l,(ix + OBJECT_MODEL)
					ld		h,(ix + OBJECT_MODEL + 1)
					ld		a,(hl)				; MODEL_VERTICES
					ld		(to_count),a
					inc		hl
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		(to_vertex),de
					xor		a
					ld		(rotate_holds_camera),a
					ld		hl,view_m
					call	install_matrix
.vertex:			ld		hl,(to_vertex)
					call	rotate
					ld		hl,(to_vertex)
					inc		hl
					inc		hl
					inc		hl
					ld		(to_vertex),hl
					ld		hl,(rot_x)			; c = the rotation + T, 24 bits
					ld		a,h
					add		a,a
					sbc		a,a
					ld		c,a
					ADD24	view_t
					STORE24	to_c
					ld		hl,(rot_y)
					ld		a,h
					add		a,a
					sbc		a,a
					ld		c,a
					ADD24	view_t + 3
					STORE24	to_c + 3
					ld		hl,(rot_z)
					ld		a,h
					add		a,a
					sbc		a,a
					ld		c,a
					ADD24	view_t + 6
					STORE24	to_c + 6
					call	project_far
					jr		nc,.store
					ld		hl,WIDE_BEHIND
.store:				ld		b,h
					ld		c,l
					ld		hl,(to_point)
					ld		(hl),c
					inc		hl
					ld		(hl),b
					inc		hl
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(to_point),hl
					ld		hl,to_count
					dec		(hl)
					jr		nz,.vertex
					ret

to_point:			DW		0
to_vertex:			DW		0
to_count:			DB		0
to_c:				DS		9					; the vertex in camera space


; project_far: to_c to the screen: HL = x, DE = y, carry clear; or carry set
; if at or behind the eye (c_z < 256). Uses everything but IX, IY and the
; alternate registers.
project_far:
					ld		a,(to_c + 8)		; c_z's high byte
					bit		7,a
					scf
					ret		nz					; behind the eye
					or		a
					jr		nz,.far
					ld		a,(to_c + 7)
					or		a
					scf
					ret		z					; c_z < 256: at the eye
					jr		.divide
.far:				ld		b,0					; B = the bits in c_z's high
.bits:				inc		b					; byte: the shift
					srl		a
					jr		nz,.bits
.shift:				ld		hl,to_c + 2			; c >>= 1, each, B times
					call	.halve
					ld		hl,to_c + 5
					call	.halve
					ld		hl,to_c + 8
					call	.halve
					djnz	.shift
.divide:			ld		a,(to_c + 7)		; Z, a byte now
					ld		c,a
					ld		de,to_c + 3
					call	divide24
					ex		de,hl
					ld		hl,SCREEN_CENTRE_Y
					or		a
					sbc		hl,de				; y = centre - c_y / Z
					push	hl
					ld		de,to_c
					call	divide24
					ld		de,SCREEN_CENTRE_X
					add		hl,de				; x = centre + c_x / Z
					pop		de
					and		a
					ret
; (HL) - 2 .. (HL), a 24-bit number, >> 1, arithmetically.
.halve:				sra		(hl)
					dec		hl
					rr		(hl)
					dec		hl
					rr		(hl)
					ret


; ---------------------------------------------------------------------------
; divide24: HL = the 24-bit signed number at DE (low byte first) / C,
; truncated toward zero and held to +-WIDE_LIMIT. In: C = 1..255. Uses A,
; B, DE, HL.

divide24:
					ex		de,hl
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		a,(hl)
					ex		de,hl				; A:H:L
					ld		b,a
					push	bc					; B: the sign
					bit		7,a
					jr		z,.positive
					ld		d,a					; negate A:H:L
					xor		a
					sub		l
					ld		l,a
					ld		a,0
					sbc		a,h
					ld		h,a
					ld		a,0
					sbc		a,d
.positive:			or		a
					jr		nz,.wide
					call	divide_unsigned		; under 65536: the quotient fits
					jr		nc,.signed			; a byte, the quick way
					xor		a
.wide:				cp		c
					jr		nc,.limit			; 65536 C or more: past the limit
					ld		b,16				; 16 bits of quotient into HL,
.bit:				add		hl,hl				; the remainder in A
					rla
					jr		c,.subtract
					cp		c
					jr		c,.next
.subtract:			sub		c
					inc		l
.next:				djnz	.bit
					ld		de,WIDE_LIMIT
					or		a
					sbc		hl,de
					jr		c,.within
.limit:				ld		hl,0
					ld		de,WIDE_LIMIT
.within:			add		hl,de
.signed:			pop		bc
					bit		7,b
					ret		z
					jp		negate_hl
