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
VIEW_BOX_HIGH		EQU		VIEW_BOX >> 8		; (its low byte is not 0, which
					ASSERT	(VIEW_BOX & $FF) != 0	; AXIS_APART relies on)
ROUGH				EQU		28380				; >= 128 * 128 sqrt 3 (see step 2)

; An object, OBJECT_SIZE bytes: x, y, z (16-bit), three angles, its model,
; and how much it turns a frame about each axis (the engine never reads
; the spin; it is here so that a program walks one record an object).
OBJECT_X			EQU		0
OBJECT_ANGLES		EQU		6
OBJECT_MODEL		EQU		9
OBJECT_SPIN			EQU		11
OBJECT_SIZE			EQU		14

; A model: how many vertices and where, edges, faces; and its bounding
; radius, as 128 r and 128 r sqrt 5 (rounded up) -- what culling compares --
; each 24-bit, first with the rough step's margins added (ROUGH and 3 ROUGH),
; then as they are: cull_object copies each pair as it stands, rather than
; working them out for every object every picture.
MODEL_VERTICES		EQU		0					; DB count, DW -> x, y, z bytes
MODEL_EDGES			EQU		3					; DB count, DW -> pairs of indices
MODEL_FACES			EQU		6					; DB count, DW -> each a DB n and n indices
MODEL_RADII			EQU		9					; D24 128 r + ROUGH, 128 r sqrt 5 +
												; 3 ROUGH, 128 r, 128 r sqrt 5
MODEL_PAIRS			EQU		21					; DB how many of the vertices, from
												; the first, are v, -v pairs

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
					ld		hl,matrix_t			; Rc^T: the rows of Rc^T are
					ld		de,camera_seen		; Rc's columns
					ld		bc,9
					ldir
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
; The box is tested on the high byte alone but for the two values of it
; that VIEW_BOX falls within, whose low byte settles it: a 16-bit compare
; each way cost three times as much.
					MACRO	AXIS_APART	OFFSET
					ld		l,(ix + OBJECT_X + OFFSET)
					ld		h,(ix + OBJECT_X + OFFSET + 1)
					ld		de,(camera_x + OFFSET)
					or		a
					sbc		hl,de
					jp		pe,cull_box_out			; P - C will not fit 16 bits
					ld		a,h
					add		a,VIEW_BOX_HIGH			; -VIEW_BOX_HIGH..VIEW_BOX_HIGH - 1:
					cp		2 * VIEW_BOX_HIGH		; within
					jr		c,.in_box
					jr		z,.top					; = VIEW_BOX_HIGH: its low byte
					inc		a						; = -VIEW_BOX_HIGH - 1: the same
					jp		nz,cull_box_out
					ld		a,l
					cp		-VIEW_BOX & $FF
					jp		c,cull_box_out			; less than -VIEW_BOX
					jr		.in_box
.top:				ld		a,l
					cp		(VIEW_BOX & $FF) + 1
					jp		nc,cull_box_out			; more than VIEW_BOX
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
					AXIS_APART	0
					AXIS_APART	2
					AXIS_APART	4
					ld		l,(ix + OBJECT_MODEL)	; first, the model's radii with
					ld		h,(ix + OBJECT_MODEL + 1)	; the rough T's margins
					ld		de,MODEL_RADII
					add		hl,de
					ld		de,cull_radius
					ldi
					ldi
					ldi
					ldi
					ldi
					ldi
					ld		(cull_exact),hl		; and where the exact ones are

					call	rough_row_z			; the rough depth
					call	test_depth
					ret		c
					call	rough_row_x			; across
					ld		hl,view_t
					call	test_side
					ret		c
					call	rough_row_y			; and up and down
					ld		hl,view_t + 3
					call	test_side
					ret		c

					ld		(cull_at),ix		; the exact T (rotate uses IX)
					call	hold_camera
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
					ld		hl,(cull_exact)		; and the radii exactly
					ld		de,cull_radius
					ldi
					ldi
					ldi
					ldi
					ldi
					ldi
					call	test_depth
					jp		c,cull_out
					ld		hl,view_t
					call	test_side
					jp		c,cull_out
					ld		hl,view_t + 3
					call	test_side
cull_out:			ld		ix,(cull_at)		; (carry: out)
					ret
cull_box_out:		scf
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

; The rough rows: a row of Rc^T times P - C's high bytes, by quarter squares
; as in rotate, into BC; set_camera writes the entries in. Then the rough T
; on that axis, into view_t + AXIS: 256 BC + camera_k's 24 bits.
					MACRO	ROUGH_ROW	S0, D0, S1, D1, S2, D2, AXIS
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
					ld		a,(camera_k + AXIS)
					ld		(view_t + AXIS),a
					ld		a,(camera_k + AXIS + 1)
					add		a,c
					ld		(view_t + AXIS + 1),a
					ld		a,(camera_k + AXIS + 2)
					adc		a,b
					ld		(view_t + AXIS + 2),a
					ret
					ENDM

rough_row_x:		ROUGH_ROW	rx0s, rx0d, rx1s, rx1d, rx2s, rx2d, 0
rough_row_y:		ROUGH_ROW	ry0s, ry0d, ry1s, ry1d, ry2s, ry2d, 3
rough_row_z:		ROUGH_ROW	rz0s, rz0d, rz1s, rz1d, rz2s, rz2d, 6

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
cull_exact:			DW		0					; -> the model's radii, exactly
view_t:				DS		9					; the object's centre in camera
												; space: three 24-bit numbers


; ---------------------------------------------------------------------------
; object_matrix: view_m = Rc^T Ro for the object at IX, 127 for 1.0: each
; column a rotate (Rc^T in it) of a column of the object's own matrix --
; compute_matrix leaves them in matrix_t, ready to rotate -- q rounded to
; q / 127 as (q + (q >> 7) + 64) >> 7 and held to +-127. Unrolled, the
; nine entries' rounding inline: a loop with the rounding as calls cost an
; object 2,400 T-states more. Uses everything but IY and the alternate
; registers; IX is not kept.

; view_m's entry at TO = the 16-bit q at FROM, rounded and held.
					MACRO	ROUND_ENTRY	FROM, TO
					ld		hl,(FROM)
					ld		a,l					; DE = q >> 7
					add		a,a
					ld		a,h
					adc		a,a
					ld		e,a
					sbc		a,a
					ld		d,a
					add		hl,de
					ld		de,64
					add		hl,de
					ld		a,l					; DE = (q + (q >> 7) + 64) >> 7,
					add		a,a					; 9 bits
					ld		a,h
					adc		a,a
					ld		e,a
					sbc		a,a
					jr		nz,.negative
					ld		a,e
					cp		128
					jr		c,.held
					ld		a,127
					jr		.held
.negative:			ld		a,e
					cp		129
					jr		nc,.held
					ld		a,-127
.held:				ld		(TO),a
					ENDM

object_matrix:
					ld		a,(ix + OBJECT_ANGLES)
					ld		(angle_x),a
					ld		a,(ix + OBJECT_ANGLES + 1)
					ld		(angle_y),a
					ld		a,(ix + OBJECT_ANGLES + 2)
					ld		(angle_z),a
					call	compute_matrix		; Ro, in matrix and matrix_t
					call	hold_camera
					ld		hl,matrix_t			; Rc^T times Ro's column 0: M's
					call	rotate
					ROUND_ENTRY	rot_x, view_m
					ROUND_ENTRY	rot_y, view_m + 3
					ROUND_ENTRY	rot_z, view_m + 6
					ld		hl,matrix_t + 3		; column 1
					call	rotate
					ROUND_ENTRY	rot_x, view_m + 1
					ROUND_ENTRY	rot_y, view_m + 4
					ROUND_ENTRY	rot_z, view_m + 7
					ld		hl,matrix_t + 6		; column 2
					call	rotate
					ROUND_ENTRY	rot_x, view_m + 2
					ROUND_ENTRY	rot_y, view_m + 5
					ROUND_ENTRY	rot_z, view_m + 8
					ret

view_m:				DS		9					; M, row by row


; ---------------------------------------------------------------------------
; transform_object: the vertices of the object at IX to the screen, by
; view_m and view_t (cull_object's and object_matrix's), into the points on
; page D from E on (E + the vertices no more than 64): x and y, 16-bit, a
; byte each in four tables of 64 (POINTS_X_LO and so on), so that a vertex's
; number in L finds all four by setting bits 6 and 7, and a page can hold
; several objects' points; one at or behind the eye gets x = WIDE_BEHIND,
; the only x with $80 in its high byte. Each vertex's position in camera
; space is shifted right just enough to bring its depth into a byte
; (model.project_far), so the quick divide does at any distance.
;
; The model's first MODEL_PAIRS pairs of vertices are each a vertex and its
; mirror, -v (build.py puts them so): M (-v) is -M v exactly, so the second
; of a pair is T - M v, from the first's rotation, and costs no rotate --
; half the rotates of a cube or an icosahedron.
;
; Nothing goes through memory that need not: the loop keeps its vertex,
; count, pairs, mirror flag and the point it writes in the alternate
; registers (IX would do for the point, but rotate uses it), and each
; coordinate of c = T +- M v is made in registers and shifted and divided
; there -- z first, since the shift and Z come from it, then y, then x. The
; depth's shift is the one thing kept (to_shift). A vertex that went through
; memory and a call cost 190 T-states more. Uses everything but IY, the
; alternate registers too.

; A:H:L = T + the rotation (SIGN 0) or T - it (SIGN 1), 24 bits, on one
; axis; the flags are the high byte's. Keeps C.
					MACRO	COMBINE	SIGN, ROTATION, T
					IF SIGN
					ld		de,(ROTATION)
					ld		a,d
					add		a,a
					sbc		a,a
					ld		b,a					; B:D:E = the rotation
					ld		hl,(T)
					or		a
					sbc		hl,de
					ld		a,(T + 2)
					sbc		a,b
					ELSE
					ld		hl,(ROTATION)
					ld		a,h
					add		a,a
					sbc		a,a
					ld		b,a					; B:H:L = the rotation
					ld		de,(T)
					add		hl,de
					ld		a,(T + 2)
					adc		a,b
					ENDIF
					ENDM

; The vertex whose rotation rot_x, rot_y, rot_z holds (or whose mirror's it
; is, SIGN 1) to the screen, and on to transform_object's .store with HL =
; x, DE = y -- or to .behind if it is at or behind the eye (c_z < 256).
					MACRO	PROJECT	SIGN
					COMBINE	SIGN, rot_z, view_t + 6
					ld		c,a					; C:H:L = c_z
					jp		m,transform_object.behind
					jp		nz,.far
					ld		a,h
					or		a
					jp		z,transform_object.behind
					ld		c,h					; Z = c_z >> 8, as it is
					COMBINE	SIGN, rot_y, view_t + 3
					call	divide24
					ex		de,hl
					ld		hl,SCREEN_CENTRE_Y
					or		a
					sbc		hl,de				; y = centre - c_y / Z
					push	hl
					COMBINE	SIGN, rot_x, view_t
					call	divide24
					jp		transform_object.x_on_screen

.far:				ld		b,0					; B = the bits in c_z's high
.bits:				inc		b					; byte: the shift
					srl		a
					jr		nz,.bits
					ld		a,b
					ld		(to_shift),a
.z:					srl		c					; Z = c_z >> (8 + the shift)
					rr		h
					djnz	.z
					ld		c,h
					COMBINE	SIGN, rot_y, view_t + 3
					ld		e,a					; y >> the shift, E:H:L
					ld		a,(to_shift)
					ld		b,a
.y:					sra		e
					rr		h
					rr		l
					djnz	.y
					ld		a,e
					call	divide24
					ex		de,hl
					ld		hl,SCREEN_CENTRE_Y
					or		a
					sbc		hl,de				; y = centre - c_y / Z
					push	hl
					COMBINE	SIGN, rot_x, view_t
					ld		e,a					; x the same
					ld		a,(to_shift)
					ld		b,a
.x:					sra		e
					rr		h
					rr		l
					djnz	.x
					ld		a,e
					call	divide24
					jp		transform_object.x_on_screen
					ENDM

transform_object:
					ld		a,d					; the points' page, into .store
					ld		(.page + 1),a
					push	de					; and E, the first
					ld		l,(ix + OBJECT_MODEL)
					ld		h,(ix + OBJECT_MODEL + 1)
					push	hl
					ld		de,MODEL_PAIRS
					add		hl,de
					ld		c,(hl)				; C = the pairs
					pop		hl
					ld		b,(hl)				; B = MODEL_VERTICES
					inc		hl
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ex		de,hl				; HL -> the vertices
					pop		de					; E = the point
					ld		d,0					; D = 1 when a mirror is next
					exx							; all kept in the alternates
					xor		a
					ld		(rotate_holds_camera),a
					ld		hl,view_m
					call	install_matrix
					exx
.vertex:			ld		a,d					; (the alternates in: HL the
					or		a					; vertex, B left, C pairs, D)
					jp		nz,.mirror			; the last one's mirror?
					push	hl
					inc		hl
					inc		hl
					inc		hl
					ld		a,c					; one of a pair?
					or		a
					jr		z,.single
					dec		c
					inc		d					; then its mirror is next
.single:			exx
					pop		hl
					call	rotate
					PROJECT	0

.mirror:			ld		d,0					; HL -> its own x, y, z, unread
					inc		hl
					inc		hl
					inc		hl
					exx
					PROJECT	1

.behind:			ld		hl,WIDE_BEHIND		; (DE: whatever)
					jr		.store
.x_on_screen:		ld		de,SCREEN_CENTRE_X
					add		hl,de				; x = centre + c_x / Z
					pop		de					; y
.store:				ld		b,h					; BC = x
					ld		c,l
					exx
					ld		a,e					; the point, and on to the next
					inc		e
					exx
					ld		l,a
.page:				ld		h,0					; (the page, written in above)
					ld		(hl),c				; POINTS_X_LO
					set		6,l
					ld		(hl),b				; POINTS_X_HI
					set		7,l
					ld		(hl),d				; POINTS_Y_HI
					res		6,l
					ld		(hl),e				; POINTS_Y_LO
					exx
					dec		b
					jp		nz,.vertex
					exx
					ret

; Where a vertex's x and y are, from the start of the points' page.
POINTS_X_LO			EQU		0
POINTS_X_HI			EQU		64
POINTS_Y_LO			EQU		128
POINTS_Y_HI			EQU		192
to_shift:			DB		0					; the depth's shift, for x and y


; ---------------------------------------------------------------------------
; divide24: HL = the 24-bit signed number A:H:L / C, truncated toward zero
; and held to +-WIDE_LIMIT. In: C = 1..255. Uses A, B, DE, HL; the sign
; is kept in B, which divide_unsigned leaves alone.

divide24:
					ld		b,a					; B: the sign
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
					push	bc
					ld		b,16				; 16 bits of quotient into HL,
.bit:				add		hl,hl				; the remainder in A
					rla
					jr		c,.subtract
					cp		c
					jr		c,.next
.subtract:			sub		c
					inc		l
.next:				djnz	.bit
					pop		bc
					ld		de,WIDE_LIMIT
					or		a
					sbc		hl,de
					jr		c,.within
.limit:				ld		hl,0
					ld		de,WIDE_LIMIT
.within:			add		hl,de
.signed:			bit		7,b
					ret		z
					jp		negate_hl
