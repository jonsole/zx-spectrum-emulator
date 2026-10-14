; fast3d: clipping lines to a window, and projecting to 16-bit screen
; coordinates so that there is something to clip.
;
; project_wide is project without the edge of the screen: a vertex lands
; where it lands, up to WIDE_LIMIT pixels from the centre, as 16-bit x and y.
; Its divide takes the quick way (divide_unsigned) whenever the quotient fits
; a byte, as it does for anything on the screen or near it, and a 16-bit long
; division only for points far off it.
;
; clip_line is Cohen-Sutherland. Each end is given a code: which of the
; window's edges it is beyond. Both inside, the line is drawn as it is; both
; beyond the same edge, none of it is in the window; otherwise an end beyond
; an edge moves to where the line crosses that edge, and the ends are coded
; again. Every crossing is worked out from the line's own ends, never from
; an end already moved: a moved end has been rounded, and on a shallow line
; the slope would multiply that.
;
; A crossing is found by halving (crossing_x for a left or right edge,
; crossing_y for a top or bottom): from one end, a step toward the other is
; halved again and again, and taken whenever the line stays short of the
; edge. Each halving is one bit of how far along the line the edge is -- a
; step of a division -- and adds that much of the line's other coordinate --
; a step of a multiplication -- with everything in registers, and in 16
; bits once the numbers allow; and it stops once the step is under half a
; pixel, about 12 halvings on average. Each end of a clipped line is within 0.75 of a pixel
; of the true line (model.crossing; clip_geometry.py holds the model to
; exact geometry, check.py the Z80 to the model).

WIDE_LIMIT			EQU		16383				; model.WIDE_LIMIT
OFF_LEFT			EQU		1
OFF_RIGHT			EQU		2
OFF_TOP				EQU		4
OFF_BOTTOM			EQU		8


; ---------------------------------------------------------------------------
; set_window: lines are clipped to columns B..D and rows C..E, inclusive
; (D >= B, E >= C; E up to 191). Uses A. It writes them into outcode.

set_window:
					ld		a,b
					ld		(outcode_left + 1),a
					ld		a,c
					ld		(outcode_top + 1),a
					ld		a,d
					ld		(outcode_right + 1),a
					ld		a,e
					ld		(outcode_bottom + 1),a
					ret


; ---------------------------------------------------------------------------
; outcode: A = the edges (x, y) is beyond, x in HL and y in DE, signed. Uses C.

outcode:
					ld		c,0
					bit		7,h
					jr		nz,outcode_is_left	; x < 0
					ld		a,h
					or		a
					jr		nz,outcode_is_right	; x > 255
					ld		a,l
outcode_left:		cp		0
					jr		c,outcode_is_left
outcode_right:		ld		a,255
					cp		l
					jr		nc,outcode_y
outcode_is_right:	ld		c,OFF_RIGHT
					jr		outcode_y
outcode_is_left:	ld		c,OFF_LEFT
outcode_y:			bit		7,d
					jr		nz,outcode_is_top
					ld		a,d
					or		a
					jr		nz,outcode_is_bottom
					ld		a,e
outcode_top:		cp		0
					jr		c,outcode_is_top
outcode_bottom:		ld		a,191
					cp		e
					ld		a,c
					ret		nc
outcode_is_bottom:	ld		a,c
					or		OFF_BOTTOM
					ret
outcode_is_top:		ld		a,c
					or		OFF_TOP
					ret


; ---------------------------------------------------------------------------
; clip_line: the line from (clip_x0, clip_y0) to (clip_x1, clip_y1), 16-bit
; signed, cut to the window. Carry set if none of it is in the window; else
; carry clear and B, C = the first end, D, E = the second, as draw_line takes
; them. Uses everything but IY.

clip_line:
					call	.codes
					jp		z,.inside			; both ends in the window
					ld		a,b
					and		c
					scf
					ret		nz					; both beyond one edge
					push	bc					; the line's own ends, kept
					ld		hl,clip_x0			; for working out crossings
					ld		de,clip_px
					ld		bc,8
					ldir
					pop		bc
					ld		a,8
					ld		(.passes),a
					jr		.clip
.again:				call	.codes
					jp		z,.inside
					ld		a,b
					and		c
					scf
					ret		nz
					ld		hl,.passes
					dec		(hl)
					scf
					ret		z					; (never: see model.clip_line)
.clip:
					ld		a,b					; the first end, if it is out
					ld		hl,clip_x0
					or		a
					jr		nz,.move
					ld		a,c
					ld		hl,clip_x1
.move:				push	hl					; the end to move
					rrca
					jr		c,.left
					rrca
					jr		c,.right
					rrca
					jr		c,.top
					ld		de,(outcode_bottom + 1)
					jr		.across
.top:				ld		de,(outcode_top + 1)
.across:			ld		d,0					; DE = the edge's y
					push	de
					call	crossing_y			; HL = x there
					pop		de
					jr		.store
.right:				ld		de,(outcode_right + 1)
					jr		.down
.left:				ld		de,(outcode_left + 1)
.down:				ld		d,0					; DE = the edge's x
					push	de
					call	crossing_x			; HL = y there
					ex		de,hl
					pop		hl
.store:				ld		b,h					; HL = x, DE = y: into the end
					ld		c,l
					pop		hl
					ld		(hl),c
					inc		hl
					ld		(hl),b
					inc		hl
					ld		(hl),e
					inc		hl
					ld		(hl),d
					jp		.again
.inside:			ld		a,(clip_x0)
					ld		b,a
					ld		a,(clip_y0)
					ld		c,a
					ld		a,(clip_x1)
					ld		d,a
					ld		a,(clip_y1)
					ld		e,a					; (carry clear, from the OR)
					ret

; B, C = the ends' codes; Z if both are 0.
.codes:				ld		hl,(clip_x0)
					ld		de,(clip_y0)
					call	outcode
					ld		b,a
					ld		hl,(clip_x1)
					ld		de,(clip_y1)
					call	outcode
					ld		c,a
					or		b
					ret

.passes:			DB		0

clip_x0:			DW		0					; the line to clip
clip_y0:			DW		0
clip_x1:			DW		0
clip_y1:			DW		0
clip_px:			DW		0					; and its ends, as they were
clip_py:			DW		0
clip_qx:			DW		0
clip_qy:			DW		0

; draw_line_clipped: clip_line, then draw_line what is left. Carry set if
; there was nothing to draw.
draw_line_clipped:
					call	clip_line
					ret		c
					call	draw_line
					and		a
					ret


; ---------------------------------------------------------------------------
; crossing_x: HL = y where the line (clip_px, clip_py)-(clip_qx, clip_qy)
; crosses x = DE; crossing_y: HL = x where it crosses y = DE. The edge must
; lie between the ends (and the line must cross it, not run along it).
; model.crossing has the arithmetic. Uses everything but IY.

CHOP_BITS			EQU		7					; model.CHOP_BITS
CHOP_HALF			EQU		1 << (CHOP_BITS - 1)

crossing_x:
					ld		hl,(clip_px)		; along x to the edge,
					or		a					; working out y
					sbc		hl,de
					ex		de,hl				; DE = b_p - edge
					ld		hl,(clip_qx)
					ld		bc,(clip_px)
					or		a
					sbc		hl,bc				; HL = b_q - b_p
					exx
					ld		hl,(clip_qy)
					ld		de,(clip_py)
					jr		chop

crossing_y:
					ld		hl,(clip_py)		; along y to the edge,
					or		a					; working out x
					sbc		hl,de
					ex		de,hl
					ld		hl,(clip_qy)
					ld		bc,(clip_py)
					or		a
					sbc		hl,bc
					exx
					ld		hl,(clip_qx)
					ld		de,(clip_px)

; The halving: HL = b_q - b_p and DE = b_p - edge; HL' = a_q, DE' = a_p.
;
; The steps and the distance to the edge start as 24-bit numbers, CHOP_BITS
; of them fraction, and halve once a round. The halvings are one more than
; the bits in the larger step, so after all but the last 9 the steps are
; under 2^15, and the distance to the edge (never more than the step along
; b, and a unit) with them: those 9 (or all of them, on a short line) are
; done in 16 bits, about 100 T-states a halving rather than 170.
;
;   main: B = halvings, C:D:E = the step along b, IXH:H:L = b short of
;         the edge (from the edge's far side, so negative)
;   alt:  C':D':E' = the step along a, B':H':L' = how far along a, so far,
;         plus half a pixel for the rounding
chop:
					ld		(chop_ap),de
					or		a
					sbc		hl,de				; HL' = a_q - a_p
					ld		b,h					; B'C' = its size
					ld		c,l
					bit		7,h
					jr		z,.size
					xor		a
					sub		c
					ld		c,a
					sbc		a,a
					sub		b
					ld		b,a
.size:				exx
					bit		7,h					; toward the edge, positive: from
					jr		z,.toward			; Q's side, flip b
					call	negate_hl
					ex		de,hl
					call	negate_hl
					ex		de,hl
.toward:			exx							; B = the halvings: the bits in
					ld		a,b					; |b_q - b_p| | |a_q - a_p|,
					exx							; plus one
					or		h
					ld		b,17
					jr		nz,.length
					exx
					ld		a,c
					exx
					or		l
					ld		b,9
.length:			add		a,a
					jr		c,.counted
					djnz	.length
.counted:			ex		de,hl				; IXH:H:L = b short of the edge,
					ld		a,h					; << CHOP_BITS
					sra		a
					ld		ixh,a
					ld		a,l
					rra
					ld		h,a
					ld		a,0
					rra
					ld		l,a
					ld		a,d					; C:D:E = the step along b
					srl		a
					ld		c,a
					ld		a,e
					rra
					ld		d,a
					ld		a,0
					rra
					ld		e,a
					exx
					ld		a,h					; C':D':E' = the step along a
					sra		a
					ld		c,a
					ld		a,l
					rra
					ld		d,a
					ld		a,0
					rra
					ld		e,a
					ld		b,0					; B':H':L' = half a pixel
					ld		hl,CHOP_HALF
					exx
					ld		a,b					; more than 9 halvings: the
					sub		9					; first ones in 24 bits
					jr		c,.short_line
					jr		z,.last_nine
					ld		b,a

.halve24:			srl		c					; the steps halved
					rr		d
					rr		e
					exx
					sra		c
					rr		d
					rr		e
					exx
					ld		a,l					; still short of the edge, after
					add		a,e					; the step along b?
					ld		a,h
					adc		a,d
					ld		a,ixh
					adc		a,c
					jp		p,.stay24			; no: stay
					ld		a,l					; yes: take it, along b
					add		a,e
					ld		l,a
					ld		a,h
					adc		a,d
					ld		h,a
					ld		a,ixh
					adc		a,c
					ld		ixh,a
					exx							; and along a
					ld		a,l
					add		a,e
					ld		l,a
					ld		a,h
					adc		a,d
					ld		h,a
					ld		a,b
					adc		a,c
					ld		b,a
					exx
.stay24:			djnz	.halve24
.last_nine:			ld		b,9
					jr		.halve16
.short_line:		add		a,9
					ld		b,a

.halve16:			srl		d					; the same in 16 bits: C is 0,
					rr		e					; IXH all sign, C' all sign
					exx
					sra		d
					rr		e
					exx
					ld		a,l
					add		a,e
					ld		a,h
					adc		a,d
					jp		p,.stay16
					add		hl,de
					exx
					add		hl,de
					ld		a,b
					adc		a,c
					ld		b,a
					exx
.stay16:			djnz	.halve16

					exx							; a = a_p + (gone + half the
					sra		c					; last step) >> CHOP_BITS
					rr		d
					rr		e
					add		hl,de
					ld		a,b
					adc		a,c
					add		hl,hl				; A:H:L << 1: the top two bytes
					rla
					ld		l,h
					ld		h,a
					ld		de,(chop_ap)
					add		hl,de
					push	hl
					exx
					pop		hl
					ret

chop_ap:			DW		0

; HL = |HL|; and HL = -HL. Use A.
abs_hl:
					bit		7,h
					ret		z
negate_hl:
					xor		a
					sub		l
					ld		l,a
					sbc		a,a
					sub		h
					ld		h,a
					ret


; ---------------------------------------------------------------------------
; divide_wide: HL = HL / C, signed by unsigned, truncated toward zero, held to
; +-WIDE_LIMIT. In: C = 1..255. Uses A, B, DE, HL.

divide_wide:
					bit		7,h
					push	af					; NZ: negative
					call	abs_hl
					call	divide_unsigned		; the quotient fits a byte:
					jr		nc,.signed			; the quick way
					xor		a					; else 16 bits of quotient into
					ld		b,16				; HL, the remainder in A
.bit:				add		hl,hl
					rla
					jr		c,.subtract			; past 255: at least C
					cp		c
					jr		c,.next
.subtract:			sub		c
					inc		l
.next:				djnz	.bit
					ld		de,WIDE_LIMIT		; held to the limit
					or		a
					sbc		hl,de
					jr		c,.within
					ld		hl,0
.within:			add		hl,de
.signed:			pop		af
					ret		z
					jp		negate_hl


; ---------------------------------------------------------------------------
; project_wide: where the rotated vertex lands, on the screen or off it.
; In: rot_x, rot_y, rot_z, zoff. Out: HL = x, DE = y (16-bit signed, y
; downwards), carry clear -- or carry set if Z is 0. Uses everything but IX,
; IY and the alternate registers.

project_wide:
					ld		hl,(rot_z)
					ld		de,(zoff)
					add		hl,de
					ld		a,h
					or		a
					scf
					ret		z					; Z = 0: at or behind the eye
					ld		c,a
					ld		hl,(rot_y)
					call	divide_wide
					ex		de,hl
					ld		hl,SCREEN_CENTRE_Y
					or		a
					sbc		hl,de				; y = centre - rot_y / Z
					push	hl
					ld		hl,(rot_x)
					call	divide_wide
					ld		de,SCREEN_CENTRE_X
					add		hl,de				; x = centre + rot_x / Z
					pop		de
					and		a
					ret


; ---------------------------------------------------------------------------
; transform_wide: transform, to 16-bit points: x then y, four bytes a
; vertex; a vertex at or behind the eye gets x = WIDE_BEHIND.
; In: HL -> the vertices, DE -> the points, B = how many (1..255).
; Uses everything but IY and the alternate registers.

WIDE_BEHIND			EQU		$8000

transform_wide:
					ld		(.vertex),hl
					ld		(.point),de
					ld		a,b
.next:				ld		(.count),a
					ld		hl,(.vertex)
					call	rotate
					ld		hl,(.vertex)
					inc		hl
					inc		hl
					inc		hl
					ld		(.vertex),hl
					call	project_wide
					jr		nc,.store
					ld		hl,WIDE_BEHIND
.store:				ld		b,h
					ld		c,l
					ld		hl,(.point)
					ld		(hl),c
					inc		hl
					ld		(hl),b
					inc		hl
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(.point),hl
					ld		a,(.count)
					dec		a
					jr		nz,.next
					ret

.vertex:			DW		0
.point:				DW		0
.count:				DB		0
