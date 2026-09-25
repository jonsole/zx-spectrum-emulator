; isoblocks: the ray view -- the focus, and what Tom Harte's caster
; (harte_cast.s, harte_scroll.s) and tile drawer (harte_tiles.s) are asked to
; do each frame.
;
; His caster keeps its triangles from frame to frame. When the view moves a
; cell, one of his eight moves slides them along and casts only what has come
; into view; when it has not moved, nothing is cast; anything else -- the
; first frame, a jump -- casts the whole view. His map is our shifted map
; with U mirrored (harte_macros.s), so his x is the focus's y and his y goes
; the other way to its x. It holds each diamond's colours, worked out by the
; build (harte_cast.s); the heights are a second map, in another bank, for
; the sprites. ray_cast pages the colours in.
;
; A frame is ray_update, ray_cast and ray_tiles.

ray_focus_x:		DB		64
ray_focus_y:		DB		64
ray_base:			DW		0			; map address of the view's (U0, V0), unmirrored
ray_cast_x:			DB		$FF			; the focus the triangles are for; $FF none
ray_cast_y:			DB		0


; ---------------------------------------------------------------------------
; ray_update: the focus, clamped to what the view reads.

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
; ray_cast: bring the triangles up to the focus. Uses everything but IX and
; IY.

ray_cast:
					ld		bc,$7FFD
					ld		a,RAY_COLOUR_PAGE	; the colours at $C000
					out		(c),a
					push	ix
					call	.cast
					pop		ix
					ret
.cast:				ld		a,(ray_cast_x)
					inc		a
					jr		z,.whole			; nothing cast yet
					; The move, dx and dy, each -1 to 1, or cast the whole view.
					ld		hl,ray_cast_x
					ld		a,(ray_focus_x)
					sub		(hl)
					inc		a
					cp		3
					jr		nc,.whole
					ld		c,a					; dx + 1
					inc		hl
					ld		a,(ray_focus_y)
					sub		(hl)
					inc		a
					cp		3
					jr		nc,.whole
					ld		b,a					; dy + 1
					add		a,a
					add		a,b
					add		a,c
					add		a,a
					ld		l,a
					ld		h,0
					ld		de,ray_moves
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		a,d
					or		e
					ret		z					; not moved
					call	.note
					ex		de,hl
					jp		(hl)				; his move for it
.whole:				call	.note
					; His map_location: x the row, V0; y the mirrored column,
					; 127 - U0.
					ld		a,(ray_focus_y)
					add		a,RAY_V_OFFSET
					ld		b,a
					srl		a
					add		a,high MAP
					ld		h,a
					ld		a,b
					rrca
					and		$80
					ld		l,a					; V0's low bit on top
					ld		a,(ray_focus_x)
					ld		c,a
					ld		a,127 - RAY_U_OFFSET
					sub		c					; 127 - U0
					or		l
					ld		l,a
					ld		(map_location),hl
					jp		cast_map
.note:				ld		a,(ray_focus_x)
					ld		(ray_cast_x),a
					ld		a,(ray_focus_y)
					ld		(ray_cast_y),a
					ret

; His moves, by (dy + 1) x 3 + (dx + 1). His x is the focus's y, his y the
; focus's x the other way: left is y - 1, down is x - 1.
ray_moves:			DW		move_view_left_down, move_view_left, move_view_left_up
					DW		move_view_down, 0, move_view_up
					DW		move_view_right_down, move_view_right, move_view_right_up


; ---------------------------------------------------------------------------
; ray_tiles: the triangles to the screen, the tiles that have changed. Keeps
; IX and IY. It checks every tile every frame, moved or not, so that a frame
; costs much the same whatever happens (a game's pace follows it).

ray_tiles:
					push	ix
					push	iy
					call	draw_tiles
					pop		iy
					pop		ix
					ret


; Forget what is on the screen, and what was cast: the next frame casts the
; whole view and draws every tile.
ray_forget:
					ld		hl,triangle_map + 512 + TRI_OUTPUT	; tile row 0's, on row 2
					ld		b,num_rows
.row:				push	bc
					ld		d,h
					ld		e,l
					inc		de
					ld		(hl),$FF
					ld		bc,31
					ldir
					pop		bc
					ld		l,TRI_OUTPUT
					inc		h
					inc		h					; two rows of triangles a row of tiles
					djnz	.row
					ld		a,$FF
					ld		(ray_cast_x),a
					ret
