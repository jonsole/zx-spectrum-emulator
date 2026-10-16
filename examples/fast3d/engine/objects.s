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

; CULL_SKIP: cull_object also says how far out an object was, and
; cull_skip_bounds how far T can have moved since the last picture, so that
; a program can skip culling what cannot have come into view (the demo
; does; see the section below). Off unless the program defines it.
					IFNDEF	CULL_SKIP
CULL_SKIP			EQU		0
					ENDIF

; An object, OBJECT_SIZE bytes: x, y, z (16-bit), three angles, its model,
; and how much it turns a frame about each axis (the engine never reads
; the spin; it is here so that a program walks one record an object).
OBJECT_X			EQU		0
OBJECT_ANGLES		EQU		6
OBJECT_MODEL		EQU		9
OBJECT_SPIN			EQU		11
OBJECT_SKIP			EQU		14					; CULL_SKIP: DW the margin left (0:
OBJECT_DIST			EQU		16					; test it), DB its size's place in
OBJECT_LIMIT		EQU		17					; skip_bounds, DW its odometer limit
OBJECT_SIZE			EQU		19

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
cull_box_out:
					IF CULL_SKIP
					ld		hl,0				; no margin to skip on
					ld		(cull_skip),hl
					ENDIF
					scf
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
					IF CULL_SKIP
					ld		c,a					; (C:H:L: how far, for the margin)
					ENDIF
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
					IF CULL_SKIP
.out:				jp		skip_depth_out
					ELSE
.out:				scf
					ret
					ENDIF

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
					IF CULL_SKIP
.out:				jp		skip_side_out
					ELSE
.out:				scf
					ret
					ENDIF

; ---------------------------------------------------------------------------
; Skipping the cull (CULL_SKIP): model.py has the reasoning. T can move on an
; axis by at most E D + 127 m a picture, E the largest row sum of the change
; in the camera's matrix, D the object's largest |P - C| on an axis, m the
; camera's move summed over the axes: arithmetic on the matrices as they
; are, whatever the camera did. cull_skip_bounds measures the camera's
; change since its last call and leaves skip_bounds, that bound in units of
; 256 for each size Q = q 2^k that D is held as, and adds m to the odometer.
; cull_object leaves for an object it culls cull_skip, its margin past the
; plane that culled it in units of 256 (a quarter of it for a side plane),
; cull_dist, where in skip_bounds the size above its D is, and cull_limit,
; the odometer at which the camera could have travelled the room between.
; A program cuts each skipping object's margin by its bound each picture
; and tests it again when nothing is left, or the odometer reaches its
; limit, or cull_skip_bounds returns carry (a jump: every margin is void);
; and clears the margin of one tested and found in view.

					IF CULL_SKIP

JUMP				EQU		16384				; model.JUMP, SKIP_K_LEAST, SKIP_K_COUNT
SKIP_K_LEAST		EQU		5
SKIP_K_COUNT		EQU		7

; BC = the sum of |the change| over a row: three entries at DE against HL.
; Each pair is biased by 128 first, so that the borrow is the true sign:
; the entries are signed, and 0 - (-127) borrows.
					MACRO	ROW_CHANGE
					ld		c,0
					ld		ixh,0
					DUP		3
					ld		a,(de)
					xor		$80
					ld		b,a
					ld		a,(hl)
					xor		$80
					sub		b
					jr		nc,$ + 4
					neg
					add		a,c
					ld		c,a
					jr		nc,$ + 4
					inc		ixh
					inc		hl
					inc		de
					EDUP
					ld		b,ixh
					ENDM

; skip_e = the larger of it and BC. Keeps HL, DE.
					MACRO	ROW_MOST
					push	hl
					push	de
					ld		hl,(skip_e)
					or		a
					sbc		hl,bc
					jr		nc,.kept
					ld		(skip_e),bc
.kept:				pop		de
					pop		hl
					ENDM

; DE += |how camera_x + N has changed|; IXL = 1 if that will not fit.
					MACRO	MOVE_AXIS	N
					ld		hl,(camera_x + N)
					push	de
					ld		de,(camera_last + N)
					or		a
					sbc		hl,de
					pop		de
					jp		pe,.too_far			; the move does not fit 16 bits
					jp		p,.moved
					xor		a					; |the move|
					sub		l
					ld		l,a
					sbc		a,a
					sub		h
					ld		h,a
.moved:				add		hl,de
					ex		de,hl
					jr		nc,.summed
.too_far:			ld		ixl,1
.summed:
					ENDM

; skip_bounds' entry for k = _K, q = _Q: E q 2^_K / 256 (floor, saturated) + DE
; (m / 2 + 2), saturated; E q is at skip_eq + 2 (_Q - 4).
					MACRO	BOUND_ENTRY	_K, _Q
					ld		hl,(skip_eq + 2 * (_Q - 4))
					IF _K < 8
					DUP		8 - _K
					srl		h
					rr		l
					EDUP
					ELSEIF _K > 8
					DUP		_K - 8
					add		hl,hl
					jr		nc,$ + 5
					ld		hl,$FFFF
					EDUP
					ENDIF
					add		hl,de
					jr		nc,$ + 5
					ld		hl,$FFFF
					ld		(skip_bounds + 2 * ((_K - SKIP_K_LEAST) * 4 + _Q - 4)),hl
					ENDM

; cull_skip_bounds: skip_bounds from how camera_x, _y, _z and camera_seen
; have changed since the last call (camera_last), and the odometer moved on.
; Carry set if the move was too big to sum, or JUMP or more: every margin is
; void. Uses everything but IY.
cull_skip_bounds:
					ld		hl,0				; E: the largest row sum of the
					ld		(skip_e),hl			; matrix's change
					ld		hl,camera_seen
					ld		de,camera_last + 9
					ROW_CHANGE
					ROW_MOST
					ROW_CHANGE
					ROW_MOST
					ROW_CHANGE
					ROW_MOST
					ld		hl,(skip_e)			; E q, for q = 4..7
					add		hl,hl
					add		hl,hl
					ld		(skip_eq),hl
					ld		de,(skip_e)
					add		hl,de
					ld		(skip_eq + 2),hl
					add		hl,de
					ld		(skip_eq + 4),hl
					add		hl,de
					ld		(skip_eq + 6),hl
					ld		de,0				; DE = m, the move summed
					ld		ixl,d				; IXL: too big to
					MOVE_AXIS	0
					MOVE_AXIS	2
					MOVE_AXIS	4
					ld		hl,(skip_odometer)
					add		hl,de
					ld		(skip_odometer),hl
					push	de
					ld		hl,camera_x			; what the next call compares
					ld		de,camera_last		; with: position, angles, matrix
					ld		bc,18
					ldir
					pop		de
					ld		a,d					; JUMP or more?
					cp		high JUMP
					jp		nc,.jump
					ld		a,ixl
					or		a
					jp		nz,.jump
					srl		d					; DE = m / 2 + 2: the move's
					rr		e					; part, and the two floors
					inc		de
					inc		de
					BOUND_ENTRY	5, 4
					BOUND_ENTRY	5, 5
					BOUND_ENTRY	5, 6
					BOUND_ENTRY	5, 7
					BOUND_ENTRY	6, 4
					BOUND_ENTRY	6, 5
					BOUND_ENTRY	6, 6
					BOUND_ENTRY	6, 7
					BOUND_ENTRY	7, 4
					BOUND_ENTRY	7, 5
					BOUND_ENTRY	7, 6
					BOUND_ENTRY	7, 7
					BOUND_ENTRY	8, 4
					BOUND_ENTRY	8, 5
					BOUND_ENTRY	8, 6
					BOUND_ENTRY	8, 7
					BOUND_ENTRY	9, 4
					BOUND_ENTRY	9, 5
					BOUND_ENTRY	9, 6
					BOUND_ENTRY	9, 7
					BOUND_ENTRY	10, 4
					BOUND_ENTRY	10, 5
					BOUND_ENTRY	10, 6
					BOUND_ENTRY	10, 7
					BOUND_ENTRY	11, 4
					BOUND_ENTRY	11, 5
					BOUND_ENTRY	11, 6
					BOUND_ENTRY	11, 7
					and		a					; carry clear
					ret
.jump:				scf
					ret

; HL = the larger of it and |P - C| on axis N, from cull_high and cull_low.
					MACRO	DIST_AXIS	N
					ld		a,(cull_low + N)
					xor		$80
					ld		e,a
					ld		a,(cull_high + N)
					ld		d,a
					bit		7,d
					jr		z,.sized
					xor		a
					sub		e
					ld		e,a
					sbc		a,a
					sub		d
					ld		d,a
.sized:				or		a
					sbc		hl,de
					add		hl,de				; (carry: HL < DE)
					jr		nc,.kept
					ex		de,hl
.kept:
					ENDM

; A test's quantity in C:H:L, either sign, is how far past the plane the
; sphere was: skip_depth_out keeps it, in units of 256, as cull_skip;
; skip_side_out a quarter of it, since 2t -+ z can move three times as far
; as T. Then the size and the limit. Both return with carry set, as the
; tests do for out.
skip_side_out:
					call	skip_size
					srl		c
					rr		h
					rr		l
					srl		c
					rr		h
					rr		l
					jr		skip_margin
skip_depth_out:
					call	skip_size
skip_margin:
					ld		l,h					; the margin >> 8
					ld		h,c
					ld		(cull_skip),hl
					ld		hl,0				; D, the largest |P - C| on an
					DIST_AXIS	0				; axis
					DIST_AXIS	1
					DIST_AXIS	2
					push	hl
					ld		d,h					; HL = D + D / 4 + 1, what the
					ld		e,l					; size must reach (model.
					srl		d					; SKIP_ROOM_SHIFT)
					rr		e
					srl		d
					rr		e
					add		hl,de
					inc		hl
					ld		b,SKIP_K_LEAST		; B = k = that + the bits of H
					ld		a,h
.bits:				or		a
					jr		z,.k
					srl		a
					inc		b
					jr		.bits
.k:					dec		hl					; q = that >> k, rounded up: (that
					ld		a,b					; - 1) >> k, + 1. With k under 8,
					cp		8					; << (8 - k) and take H
					jr		nc,.wide
					ld		a,8
					sub		b
.up:				add		hl,hl
					dec		a
					jr		nz,.up
					ld		a,h
					jr		.q
.wide:				sub		8					; else H >> (k - 8)
					ld		c,a
					ld		a,h
					jr		z,.q
.down:				srl		a
					dec		c
					jr		nz,.down
.q:					inc		a
					cp		4					; q 4..7: under 4 is 4, and 8 is
					jr		nc,.least			; 4 of the next k
					ld		a,4
.least:				cp		8
					jr		nz,.sized
					ld		a,4
					inc		b
.sized:				ld		c,a					; cull_dist = skip_bounds' low
					ld		a,b					; byte + 2 (4 (k - 5) + q - 4)
					add		a,a
					add		a,a
					add		a,a
					add		a,c
					add		a,c
					add		a,low skip_bounds - 48
					ld		(cull_dist),a
					ld		a,b					; Q = q << k: q << 5 is a byte,
					sub		SKIP_K_LEAST		; then the rest in 16 bits
					ld		b,a
					ld		a,c
					add		a,a
					add		a,a
					add		a,a
					add		a,a
					add		a,a
					ld		h,0
					ld		l,a
					inc		b
.size:				dec		b
					jr		z,.room
					add		hl,hl
					jr		.size
.room:
					pop		de					; the room: Q - D
					or		a
					sbc		hl,de
					ld		de,(skip_odometer)	; and the odometer when it could
					add		hl,de				; have been travelled
					ld		(cull_limit),hl
					scf
					ret
; C:H:L = |C:H:L|.
skip_size:
					bit		7,c
					ret		z
					xor		a
					sub		l
					ld		l,a
					ld		a,0
					sbc		a,h
					ld		h,a
					ld		a,0
					sbc		a,c
					ld		c,a
					ret

skip_e:				DW		0					; E, and E q for q = 4..7
skip_eq:			DS		8
skip_odometer:		DW		0					; the camera's moves summed
camera_last:		DS		18					; camera_x, _y, _z, camera_angles
													; and camera_seen at the last
													; cull_skip_bounds
					ALIGN	64					; (on one page: a byte indexes it)
skip_bounds:		DS		2 * 4 * SKIP_K_COUNT	; by q 4..7 within k 5..11
cull_skip:			DW		0					; the last culled object's margin,
cull_dist:			DB		0					; its size's place in skip_bounds,
cull_limit:			DW		0					; and its limit on the odometer

					ENDIF

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
; several objects' points; one behind the near plane gets x = WIDE_BEHIND,
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

; y = centre - c_y / Z, onto the stack: HL the quotient's size, B the
; sign of c_y.
					MACRO	Y_ON_SCREEN
					ex		de,hl
					ld		hl,SCREEN_CENTRE_Y
					bit		7,b
					jr		nz,.below
					or		a
					sbc		hl,de
					jr		.y
.below:				add		hl,de
.y:					push	hl
					ENDM

; The vertex whose rotation rot_x, rot_y, rot_z holds (or whose mirror's it
; is, SIGN 1) to the screen, and on to transform_object's .store with HL =
; x, DE = y -- or to .behind if it is behind the near plane (c_z <
; NEAR_PLANE, which is 4 << 8: one compare of the middle byte).
					MACRO	PROJECT	SIGN
					COMBINE	SIGN, rot_z, view_t + 6
					ld		c,a					; C:H:L = c_z
					jp		m,transform_object.behind
					jp		nz,.far
					ld		a,h
					cp		high NEAR_PLANE
					jp		c,transform_object.behind
					ld		c,h					; Z = c_z >> 8, as it is
					COMBINE	SIGN, rot_y, view_t + 3
					call	divide24
					Y_ON_SCREEN
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
					Y_ON_SCREEN
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
					ld		(transform_behind),a
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
					ld		a,h					; (for cut_edges)
					ld		(transform_behind),a
					jr		.store
.x_on_screen:		ex		de,hl				; x = centre + c_x / Z: HL the
					ld		hl,SCREEN_CENTRE_X	; quotient's size, B the sign
					bit		7,b
					jr		nz,.left
					add		hl,de
					pop		de					; y
					jr		.store
.left:				or		a
					sbc		hl,de
					pop		de
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
transform_behind:	DB		0					; non-zero: a vertex was behind
													; the near plane


; ---------------------------------------------------------------------------
; cut_edges: the edges of an object that cross the near plane, cut there
; (model.object_lines). An edge with one end in front of the plane and the
; other behind it becomes a line from its front end, as transform_object
; put it, to where the edge crosses the plane: four words, x0, y0, x1, y1,
; as clip_x0 to clip_y1 take them. An edge wholly behind the plane is left
; out, and one wholly in front is the program's to draw from the points,
; as ever.
;
; In: IX -> the object, straight after transform_object (its matrix still
; in rotate, view_t its T); HL -> its points as transform_object was given
; them (H the page, L its first vertex); DE -> where the lines go, with
; room for as many as the model has edges. Out: DE -> past the last line,
; A = how many. Quick when transform_object found nothing behind the plane.
; Uses everything but IY, the alternate registers too.
;
; The plane is at c_z = NEAR_PLANE, where Z is 4, so a point on it lands
; c_x / 4, c_y / 4 from the centre. Both ends are taken back into camera
; space -- rotated again, plus T -- and into units of c / 4, pixels across
; at the plane; and then cut_crossing finds where the edge crosses z =
; NEAR_PLANE / 4. model.py says why the numbers fit 16 bits.

NEAR_PLANE			EQU		NEAR * 128			; model.NEAR_PLANE, NEAR_SHIFT: Z = 4
NEAR_SHIFT			EQU		2					; there, so c >> 2 is in pixels
					ASSERT	(NEAR_PLANE & $FF) == 0	; (PROJECT tests its high byte)

; A:H:L >> NEAR_SHIFT into H:L: units of c / 4.
					ASSERT	NEAR_SHIFT == 2		; (QUARTER is written out for it)
					MACRO	QUARTER
					sra		a
					rr		h
					rr		l
					sra		a
					rr		h
					rr		l
					ENDM

cut_edges:
					xor		a
					ld		(cut_count),a
					ld		a,(transform_behind)
					or		a
					ret		z					; nothing behind: none, DE as it was
					ld		(cut_out),de
					ld		(cut_points),hl
					ld		a,$FF				; no last cut's ends to keep
					ld		(cut_front_vertex),a
					ld		(cut_behind_vertex),a
					ld		a,l					; C = the first vertex's x, high
					add		a,POINTS_X_HI		; byte: an end's place, added
					ld		c,a
					ld		l,(ix + OBJECT_MODEL)
					ld		h,(ix + OBJECT_MODEL + 1)
					inc		hl
					ld		e,(hl)				; MODEL_VERTICES
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		(cut_vertices),de
					ld		b,(hl)				; B = MODEL_EDGES
					inc		hl
					ld		e,(hl)
					inc		hl
					ld		d,(hl)				; DE -> the edges
					ld		a,(cut_points + 1)
					ld		h,a					; H = the points' page

; The walk, in registers: most edges are drawn as ever or left out, and
; cost no more than reading their ends' x.
.edge:				ld		a,(de)				; the first end behind?
					add		a,c
					ld		l,a
					ld		a,(hl)
					inc		de
					cp		high WIDE_BEHIND
					ld		a,(de)
					inc		de
					jr		z,.first_behind
					add		a,c					; no: the second?
					ld		l,a
					ld		a,(hl)
					cp		high WIDE_BEHIND
					jr		z,.second_behind
.next:				djnz	.edge				; neither: drawn as ever
					ld		de,(cut_out)
					ld		a,(cut_count)
					ret
.first_behind:		add		a,c
					ld		l,a
					ld		a,(hl)
					cp		high WIDE_BEHIND
					jr		z,.next				; both: left out
					push	bc					; the second in front
					push	de
					dec		de
					dec		de
					ld		a,(de)
					inc		de
					jr		.cut
.second_behind:		push	bc					; the first in front
					push	de
					dec		de
					ld		a,(de)
					dec		de
; Each end into camera space, unless it was the same end of the last edge
; cut, still in cut_front or cut_behind: a quarter of a solid's are.
.cut:				ld		hl,cut_behind_vertex
					cp		(hl)
					jr		z,.behind_kept
					ld		(hl),a
					push	de
					ld		de,cut_behind
					call	.camera_space
					pop		de
.behind_kept:		ld		a,(de)
					ld		hl,cut_front_vertex
					cp		(hl)
					jr		z,.front_kept
					ld		(hl),a
					ld		de,cut_front
					call	.camera_space
.front_kept:		ld		a,(cut_points)		; the front end's point, as the
					ld		hl,cut_front_vertex	; line's first end
					add		a,(hl)
					ld		l,a
					ld		a,(cut_points + 1)
					ld		h,a
					ld		de,(cut_out)
					ld		a,(hl)				; POINTS_X_LO
					ld		(de),a
					inc		de
					set		6,l
					ld		a,(hl)				; POINTS_X_HI
					ld		(de),a
					inc		de
					set		7,l
					res		6,l
					ld		a,(hl)				; POINTS_Y_LO
					ld		(de),a
					inc		de
					set		6,l
					ld		a,(hl)				; POINTS_Y_HI
					ld		(de),a
					inc		de
					ld		(cut_out),de
					call	cut_crossing		; and where it crosses the plane
					push	de
					call	.store				; x
					pop		hl
					call	.store				; y
					ld		hl,cut_count
					inc		(hl)
					pop		de					; and on to the next edge
					pop		bc
					ld		a,(cut_points + 1)
					ld		h,a
					jr		.next

; HL to the line at cut_out, and on.
.store:				ex		de,hl
					ld		hl,(cut_out)
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(cut_out),hl
					ret

; Vertex A of the model, in camera space and units of c / 4, into the three
; words at DE: rotated by M, plus T.
.camera_space:		push	de
					ld		l,a
					ld		h,0
					ld		e,l
					ld		d,h
					add		hl,hl
					add		hl,de
					ld		de,(cut_vertices)
					add		hl,de
					call	rotate
					pop		ix
					COMBINE	0, rot_x, view_t
					QUARTER
					ld		(ix + 0),l
					ld		(ix + 1),h
					COMBINE	0, rot_y, view_t + 3
					QUARTER
					ld		(ix + 2),l
					ld		(ix + 3),h
					COMBINE	0, rot_z, view_t + 6
					QUARTER
					ld		(ix + 4),l
					ld		(ix + 5),h
					ret

cut_points:			DW		0					; L the first vertex, H the page
cut_vertices:		DW		0					; -> the model's vertices
cut_out:			DW		0					; -> where the next line goes
cut_count:			DB		0					; lines so far
cut_front_vertex:	DB		0					; the last edge cut's ends
cut_behind_vertex:	DB		0					; ($FF: none yet)
cut_front:			DS		6					; and where they are, x, y, z,
													; in units of c / 4
cut_behind:			DS		6
cut_t:				DW		0					; how far along the plane is

; hold_wide: HL held to +-WIDE_LIMIT, as a projected point is. Uses A.
hold_wide:
					bit		7,h
					jr		nz,.negative
					ld		a,h					; up to WIDE_LIMIT: $3FFF
					cp		high (WIDE_LIMIT + 1)
					ret		c
					ld		hl,WIDE_LIMIT
					ret
.negative:			ld		a,l					; HL + WIDE_LIMIT carries
					add		a,low WIDE_LIMIT	; unless HL is beyond it
					ld		a,h
					adc		a,high WIDE_LIMIT
					ret		c
					ld		hl,-WIDE_LIMIT
					ret


; cut_crossing: where the edge from cut_behind to cut_front crosses the
; near plane, on the screen (model.near_crossing): HL = x, DE = y. Uses
; everything but IX and IY, the alternate registers too.
;
; First t = (the plane - a_z) / (b_z - a_z), to 16 bits, by a restoring
; division written out a bit at a time. Then x and y together, a + d t
; with d = b - a, from t's bits the least first: each adds d or not and
; halves, an offset in H:L with a byte of fraction in C, y here and x in
; the alternates. It never needs more than 16 bits and a byte: the offset
; stays within d, and with d added within 2 d. That replaced two of
; clip_line's halvings, one for x and one for y, each working out t again,
; in 24 bits until the steps fitted 16: about 2,900 T-states for 4,600.

; A bit of t: what is left, HL, doubled, less DE if DE will go; the bit,
; inverted, into A. Doubling never carries -- what is left is never more
; than DE, under 32768 -- so SBC takes DE alone; and when DE will not go,
; adding it back carries, which is the inverted bit.
					MACRO	T_BIT
					add		hl,hl
					sbc		hl,de
					jr		nc,$ + 3
					add		hl,de
					rla
					ENDM

; The offset on both axes for each of the bits of A, the least first:
; added to if the bit is set, then halved.
					MACRO	ALONG
					ld		b,8
.bit:				rra
					jr		nc,.zero
					add		hl,de				; y
					sra		h
					rr		l
					rr		c
					exx
					add		hl,de				; x
					sra		h
					rr		l
					rr		c
					exx
					djnz	.bit
					jr		.done
.zero:				sra		h
					rr		l
					rr		c
					exx
					sra		h
					rr		l
					rr		c
					exx
					djnz	.bit
.done:
					ENDM

; HL = d on AXIS, b - a, into DE too; and H:L.C, the offset, half of it --
; half t's last bit, to centre its truncation.
					MACRO	HALF_D	AXIS
					ld		hl,(cut_front + AXIS)
					ld		de,(cut_behind + AXIS)
					or		a
					sbc		hl,de
					ld		d,h
					ld		e,l
					ld		c,0
					sra		h
					rr		l
					rr		c
					ENDM

cut_crossing:
					ld		de,(cut_behind + 4)	; t: what is left, the plane - a_z
					ld		hl,NEAR_PLANE >> NEAR_SHIFT
					or		a
					sbc		hl,de
					ld		b,h
					ld		c,l
					ld		hl,(cut_front + 4)
					or		a
					sbc		hl,de
					ex		de,hl				; DE = b_z - a_z
					ld		h,b
					ld		l,c
					DUP		8
					T_BIT
					EDUP
					cpl
					ld		(cut_t + 1),a
					DUP		8
					T_BIT
					EDUP
					cpl
					ld		(cut_t),a
					HALF_D	2					; y here
					exx
					HALF_D	0					; x in the alternates
					exx
					ld		a,(cut_t)
					ALONG
					ld		a,(cut_t + 1)
					ALONG
					sla		c					; y = centre - (a_y + the offset,
					ld		de,(cut_behind + 2)	; rounded)
					adc		hl,de
					call	hold_wide
					ex		de,hl
					ld		hl,SCREEN_CENTRE_Y
					or		a
					sbc		hl,de
					push	hl
					exx
					sla		c					; x = centre + (a_x + ...)
					ld		de,(cut_behind)
					adc		hl,de
					call	hold_wide
					ld		de,SCREEN_CENTRE_X
					add		hl,de
					pop		de
					ret


; ---------------------------------------------------------------------------
; divide24: HL = |A:H:L| / C, truncated and held to WIDE_LIMIT, with B =
; A:H:L's high byte, whose sign the caller gives the quotient (adding or
; subtracting its size from the screen's centre costs less than negating it
; here). In: C = 1..255. Uses A, B, DE, HL. One OR tests both the sign and
; whether the number is under 65536, and the quick divide, a quotient that
; fits a byte, is divide_unsigned written in rather than called.

divide24:
					ld		b,a					; B: the sign
					or		a
					jp		m,.negative
					jr		nz,.wide
.fits:				ld		a,h					; under 65536: the quotient fits
					cp		c					; a byte unless H >= C
					jr		nc,.wide0
					DIVIDE_BIT					; (project.s)
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					rl		l
					ld		a,l
					cpl
					ld		l,a
					ld		h,0
					ret
.negative:			ld		d,a					; |A:H:L|
					xor		a
					sub		l
					ld		l,a
					ld		a,0
					sbc		a,h
					ld		h,a
					ld		a,0
					sbc		a,d
					jr		z,.fits
					jr		.wide
.wide0:				xor		a
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
					ret
