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
; again. Every crossing is worked out from the line's own ends, as
;   a = a_p + round((a_q - a_p) * |edge - b_p| / |b_q - b_p|)
; and never from an end already moved: a moved end has been rounded, and on a
; shallow line the slope would multiply that. So each end of a clipped line
; is within half a pixel of the true line (model.clip_line, which check.py
; holds this to, and against exact geometry).

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
; them. Uses everything but IY and the alternate registers.

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
					ld		hl,(clip_px)		; x where the line has that y
					ld		(ip_ap),hl
					ld		hl,(clip_qx)
					ld		(ip_aq),hl
					ld		hl,(clip_py)
					ld		(ip_bp),hl
					ld		hl,(clip_qy)
					ld		(ip_bq),hl
					call	interpolate
					pop		de
					ex		de,hl				; DE = x, HL = y
					ex		(sp),hl				; HL -> the end, y on the stack
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					pop		de
					ld		(hl),e
					inc		hl
					ld		(hl),d
					jp		.again
.right:				ld		de,(outcode_right + 1)
					jr		.down
.left:				ld		de,(outcode_left + 1)
.down:				ld		d,0					; DE = the edge's x
					push	de
					ld		hl,(clip_py)		; y where the line has that x
					ld		(ip_ap),hl
					ld		hl,(clip_qy)
					ld		(ip_aq),hl
					ld		hl,(clip_px)
					ld		(ip_bp),hl
					ld		hl,(clip_qx)
					ld		(ip_bq),hl
					call	interpolate
					pop		de					; DE = x, HL = y
					ex		(sp),hl				; HL -> the end, y on the stack
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					pop		de
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
; interpolate: HL = a_p + round((a_q - a_p) * |edge - b_p| / |b_q - b_p|),
; rounded half away from a_p, for the edge in DE and a_p, a_q, b_p, b_q in
; ip_ap... The edge must lie between b_p and b_q (and they differ), and every
; difference within 32767. Uses everything but IY and the alternate registers.

interpolate:
					ld		hl,(ip_bp)
					ex		de,hl
					or		a
					sbc		hl,de				; edge - b_p
					call	abs_hl
					push	hl
					ld		hl,(ip_bq)
					or		a
					sbc		hl,de				; b_q - b_p
					call	abs_hl
					ld		(ip_d),hl
					ld		hl,(ip_aq)
					ld		de,(ip_ap)
					or		a
					sbc		hl,de				; a_q - a_p
					ld		a,h
					ld		(ip_sign),a
					call	abs_hl
					ld		b,h
					ld		c,l
					pop		de
					call	mul16				; DE:HL = |a_q - a_p| * |edge - b_p|
					ld		bc,(ip_d)
					push	bc					; + d / 2, to round
					srl		b
					rr		c
					add		hl,bc
					jr		nc,.halved
					inc		de
.halved:			pop		bc
					call	div32				; HL = that / d
					ld		a,(ip_sign)
					rla
					call	c,negate_hl
					ld		de,(ip_ap)
					add		hl,de
					ret

ip_ap:				DW		0
ip_aq:				DW		0
ip_bp:				DW		0
ip_bq:				DW		0
ip_d:				DW		0
ip_sign:			DB		0

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

; mul16: DE:HL = BC * DE, unsigned. Uses A.
mul16:
					ld		hl,0
					ld		a,16
.bit:				add		hl,hl
					rl		e
					rl		d
					jr		nc,.next
					add		hl,bc
					jr		nc,.next
					inc		de
.next:				dec		a
					jr		nz,.bit
					ret

; div32: HL = DE:HL / BC, unsigned, and DE the remainder; DE < BC <= 32767,
; so the quotient fits and the remainder never passes 16 bits. Uses A.
div32:
					ld		a,16
.bit:				add		hl,hl
					rl		e
					rl		d
					ex		de,hl
					or		a
					sbc		hl,bc
					jr		nc,.fits
					add		hl,bc
					ex		de,hl
					dec		a
					jr		nz,.bit
					ret
.fits:				ex		de,hl
					inc		l
					dec		a
					jr		nz,.bit
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
