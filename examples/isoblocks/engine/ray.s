; isoblocks: the second renderer -- a ray per pair of triangles, no overdraw.
;
; After Tom Harte's Isometric-Ray-Cast (github.com/TomHarte/Isometric-Ray-
; Cast), whose README describes the method; his repository has no licence and
; none of its code is used. raycast.py is the model: it says how the screen is
; a grid of triangles, how the map is shifted so that one byte holds a whole
; line of sight, and why three lines of sight decide a triangle. check_ray.py
; compares this with the model, and the model with the painter.
;
; The map paged in at $C000 is the RAY map: for each shifted cell, the height
; of the nearest cube along that line of sight plus one, or 0. The build makes
; it (build.py, from raycast.shift_map), so the cast compares heights straight
; out of memory.
;
; A frame is ray_update, ray_cast and ray_tiles:
;
; - ray_cast works along the rows of the shifted map. Along a row, each
;   diamond's own line of sight is the last one's right-hand neighbour, and
;   its left-hand neighbour is the last one's line above, so a diamond reads
;   two cells, not four. It writes each triangle's colour into TRIANGLES,
;   a byte per triangle by band (32 bytes a band) and strip.
; - ray_tiles makes each character cell's tile number from its three
;   triangles, and copies the tile only if it differs from what is there.
;
; A triangle's byte: in an odd band, the colour times $11 -- it is the top
; triangle of one character row and the bottom of the next, and the tile
; number wants it in bits 4-5 for one and 0-1 for the other. In an even band,
; the colour times 4 (bits 2-3), plus 64 if its strip is odd: which way round
; the cell's triangles lie. Tiles are stored a byte per page, TILES + 256 x
; row + number, so copying one is INC H and INC D. RAY_SHOWN, the tile number
; each cell shows, sits at its middle band's place in TRIANGLES plus $800 --
; one SET 3,H away.

FLOOR				EQU		0
TOP					EQU		1
LEFT_FACE			EQU		2
RIGHT_FACE			EQU		3

ray_focus_x:		DB		64
ray_focus_y:		DB		64
ray_base:			DW		0			; map address of the view's (U0, V0)


; ---------------------------------------------------------------------------
; ray_update: the focus, clamped to what the ray view can read, to ray_base.

ray_update:
					ld		hl,ray_focus_x
					ld		a,(hl)
					cp		RAY_MIN_X
					jr		nc,.x_low_ok
					ld		a,RAY_MIN_X
.x_low_ok:			cp		RAY_MAX_X + 1
					jr		c,.x_ok
					ld		a,RAY_MAX_X
.x_ok:				ld		(hl),a
					inc		hl
					ld		a,(hl)
					cp		RAY_MIN_Y
					jr		nc,.y_low_ok
					ld		a,RAY_MIN_Y
.y_low_ok:			cp		RAY_MAX_Y + 1
					jr		c,.y_ok
					ld		a,RAY_MAX_Y
.y_ok:				ld		(hl),a
					; U0 = focus x + RAY_U_OFFSET, V0 = focus y + RAY_V_OFFSET, and
					; the address is MAP + 128 V0 + U0: V0 / 2 in the high byte,
					; V0's low bit on top of U0 in the low.
					ld		a,(ray_focus_x)
					add		a,RAY_U_OFFSET
					ld		l,a
					ld		a,(ray_focus_y)
					add		a,RAY_V_OFFSET
					srl		a
					jr		nc,.even
					set		7,l
.even:				add		a,high MAP
					ld		h,a
					ld		(ray_base),hl
					ret


; ---------------------------------------------------------------------------
; ray_cast: every diamond in view, into TRIANGLES. Uses everything but IX
; and IY.
;
; A diamond decides its left triangle from three heights: F its own line of
; sight, A the one a diamond above it on the screen, and L the one up and to
; its left -- and its right triangle from F, A and R, up and to its right.
; Along a row of the shifted map, F is the last diamond's R, and L the last
; diamond's A. Main set: BC points at R's cell, DE at A's, H holds F and L
; holds L. The other set: HL' the diamond's right triangle in TRIANGLES,
; DE' -30 (from its left triangle to the next diamond's right), B' the
; diamonds left in the row.
;
; Which triangle shows is raycast.py's rule, with heights: a triangle shows
; its diamond's top if F is at least A and at least the side; otherwise the
; side's face toward it if the side is at least A; otherwise the face of the
; line above; and with nothing on any of the three, the floor.

; One diamond. L_* and R_* are the forms its band stores the left and right
; triangles' colours in. It splits three ways on F against A -- in front of
; the line above, behind it, or level -- since most of the answer follows
; from that one comparison, and open floor, the commonest case, is the level
; one with nothing in either.
					MACRO	RAY_DIAMOND L_TOP, L_LEFT, L_RIGHT, L_FLOOR, R_TOP, R_LEFT, R_RIGHT, R_FLOOR
					; Open floor: nothing on any of the four lines. Both triangles
					; are floor, and the next diamond's F and L -- this one's R and
					; A -- are nothing too, which H and L already say.
					ld		a,(de)				; A
					or		h
					or		l
					jr		nz,.decide
					ld		a,(bc)				; R
					or		a
					jr		nz,.decide
					inc		c
					inc		e
					exx
					ld		(hl),R_FLOOR
					dec		l
					ld		(hl),L_FLOOR
					add		hl,de				; DE' = -30: the next diamond's
					dec		b
					exx
					jp		.done
.decide:			ld		a,(de)				; A
					cp		h
					jr		c,.front			; F above A
					jr		z,.level
					; Behind the line above: its faces, unless a side is as near.
					cp		l					; A - L
					ld		a,L_RIGHT
					jr		z,.behind_left
					jr		c,.behind_left		; L at least A: L's right face
					ld		a,L_LEFT			; the left face of the line above
.behind_left:		ex		af,af'
					ld		a,(bc)				; R
					ld		l,a
					ld		a,(de)
					cp		l					; A - R
					ld		a,R_LEFT
					jr		z,.step
					jr		c,.step				; R at least A: R's left face
					ld		a,R_RIGHT			; the right face of the line above
					jr		.step
.level:				or		a
					jr		nz,.front			; level and not empty: F's top wins
					; Nothing on this line or the one above: floor, or a side.
					ld		a,l
					or		a
					ld		a,L_FLOOR
					jr		z,.floor_left
					ld		a,L_RIGHT
.floor_left:		ex		af,af'
					ld		a,(bc)
					ld		l,a
					or		a
					ld		a,R_FLOOR
					jr		z,.step
					ld		a,R_LEFT
					jr		.step
.front:				; F's top, unless a side is nearer.
					ld		a,h
					cp		l					; F - L
					ld		a,L_TOP
					jr		nc,.front_left
					ld		a,L_RIGHT
.front_left:		ex		af,af'
					ld		a,(bc)
					ld		l,a
					ld		a,h
					cp		l					; F - R
					ld		a,R_TOP
					jr		nc,.step
					ld		a,R_LEFT
.step:				; A the right triangle, A' the left: both into TRIANGLES, the
					; pointer on to the next diamond's, and the count down.
					exx
					ld		(hl),a				; the right triangle
					dec		l
					ex		af,af'
					ld		(hl),a				; the left
					add		hl,de				; DE' = -30: the next diamond's
					dec		b
					exx
					; The next diamond: F is this one's R, L this one's A. None of
					; this touches the flags DEC B left.
					ld		h,l
					ld		a,(de)
					ld		l,a
					inc		bc
					inc		de
.done:
					ENDM

ray_cast:
					exx
					ld		de,-30
					exx
					push	ix					; saved and restored: IX is the game's
					ld		ix,ray_rows
					ld		b,RAY_ROWS
.row:				push	bc
					; F's cell: ray_base + the row's offset.
					ld		hl,(ray_base)
					ld		e,(ix+0)
					ld		d,(ix+1)
					add		hl,de
					ld		a,(ix+2)			; diamonds in the row
					exx
					ld		b,a
					ld		l,(ix+3)			; its first right triangle
					ld		h,(ix+4)
					exx
					ld		de,6
					add		ix,de
					; F, L, and the pointers to the first R and A.
					ld		d,h
					ld		e,l
					inc		de					; R: one on along the row
					ld		b,d
					ld		c,e
					ld		d,(hl)				; F
					ld		a,l
					sub		128					; the row above
					ld		l,a
					jr		nc,.same_page
					dec		h
.same_page:			ld		e,(hl)				; L
					inc		hl
					push	hl					; A's cell
					ld		h,d
					ld		l,e
					pop		de
					ld		a,(ix-1)			; the first band's parity
					or		a
					jr		nz,.odd
.even:				RAY_DIAMOND 64 + 4 * TOP, 64 + 4 * LEFT_FACE, 64 + 4 * RIGHT_FACE, 64, 4 * TOP, 4 * LEFT_FACE, 4 * RIGHT_FACE, 0
					jr		z,.row_done
.odd:				RAY_DIAMOND $11 * TOP, $11 * LEFT_FACE, $11 * RIGHT_FACE, 0, $11 * TOP, $11 * LEFT_FACE, $11 * RIGHT_FACE, 0
					jp		nz,.even
.row_done:			pop		bc
					dec		b
					jp		nz,.row
					pop		ix
					ret


; ---------------------------------------------------------------------------
; ray_tiles: TRIANGLES to the screen, a character cell at a time, copying a
; tile only where it has changed. Uses everything but IX and IY.
;
; A cell's tile number is its top triangle's colour in bits 4-5, the middle's
; in bits 2-3 (with the cell's way round in bit 6), the bottom's in bits 0-1.
; The top and bottom are odd bands, stored as colour x $11; T xor ((T xor B)
; and $0F) takes the high nibble from T and the low from B. A row of cells is
; unrolled; BC points at the bottom band, DE the top and HL the middle, and
; the other set's BC' holds the row's screen address for ray_copy.

ray_tiles:
					ld		a,RAY_FIRST_ROW
.char_row:			ld		(ray_row),a
					; The row's screen address, for ray_copy.
					sub		RAY_FIRST_ROW
					add		a,a
					ld		l,a
					ld		h,0
					ld		de,ray_screen_rows
					add		hl,de
					ld		a,(hl)
					inc		hl
					ld		h,(hl)
					ld		l,a
					push	hl
					exx
					pop		bc					; BC' = the row's screen address
					exx
					; The three bands: 2j - 1, 2j and 2j + 1, from the first strip.
					ld		a,(ray_row)
					ld		l,a
					ld		h,0
					add		hl,hl
					add		hl,hl
					add		hl,hl
					add		hl,hl
					add		hl,hl
					add		hl,hl				; 64 j
					ld		de,TRIANGLES + RAY_FIRST_STRIP
					add		hl,de				; the middle band
					ld		de,-32
					ex		de,hl
					add		hl,de
					ex		de,hl				; DE the top band
					ld		bc,32
					push	hl
					add		hl,bc
					ld		b,h
					ld		c,l					; BC the bottom band
					pop		hl
					DUP		RAY_STRIPS
					ld		a,(bc)				; B
					ex		de,hl
					xor		(hl)				; T xor B
					and		$0F
					xor		(hl)				; T's top nibble, B's bottom
					ex		de,hl
					or		(hl)				; the middle, and the way round
					set		3,h					; RAY_SHOWN
					cp		(hl)
					call	nz,ray_copy
					res		3,h
					inc		c
					inc		e
					inc		l
					EDUP
					ld		a,(ray_row)
					inc		a
					cp		RAY_FIRST_ROW + RAY_CHAR_ROWS
					jp		nz,.char_row
					ret

ray_row:			DB		0

; Show tile A at the cell whose RAY_SHOWN entry is at HL, and note it there.
; Keeps the main registers.
ray_copy:
					ld		(hl),a
					ex		af,af'
					ld		a,l
					and		31					; the strip
					exx
					add		a,c
					ld		e,a
					ld		d,b					; the cell's top line
					ex		af,af'
					ld		l,a
					ld		h,high TILES
					DUP		7
					ld		a,(hl)
					ld		(de),a
					inc		h
					inc		d
					EDUP
					ld		a,(hl)
					ld		(de),a
					exx
					ret

; Forget what is on the screen, so the next ray_tiles draws every cell.
ray_forget:
					ld		hl,RAY_SHOWN
					ld		de,RAY_SHOWN + 1
					ld		bc,RAY_SHOWN_SIZE - 1
					ld		(hl),$FF
					ldir
					ret
