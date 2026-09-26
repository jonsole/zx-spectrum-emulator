; isoblocks: Tom Harte's scrolling, from his Isometric-Ray-Cast
; (github.com/TomHarte/Isometric-Ray-Cast, src/scroll.asm at 6d48476), used as
; public domain. His dispatcher from the keyboard is left out, because
; isoblocks moves the view by its focus (ray_view.s picks the move).
;
; Changed for isoblocks: triangle_map's rows are a page apart (build.py, the
; ray layout), so his one LDIR or LDDR over the whole map, sliding it by a
; number of bytes, is SLIDE, which slides it by rows and strips: a row at a
; time, the bytes of a row unrolled. What slides in from outside the map is
; left as it was -- his moves cast those rows and columns again, as they did
; the bytes his LDIR wrapped round.

triangle_rows		equ num_rows*2 + 1

; Slide triangle_map down by_rows rows and right by_strips strips (either may
; be negative): each row's 32 - |by_strips| triangles that stay in the map,
; from the row that many above. Rows go bottom first when sliding down, so
; none is overwritten before it is read; within a row, a slide right goes
; right to left (LDD) for the same reason when by_rows is 0. (The names are
; long because sjasmplus puts a macro's arguments into any name containing
; them.)
	MACRO SLIDE by_rows, by_strips
	IF by_strips < 0
_count = 32 + by_strips
	ELSE
_count = 32 - by_strips
	ENDIF
	IF by_rows < 0
_rows = triangle_rows + by_rows
	ELSE
_rows = triangle_rows - by_rows
	ENDIF
	IF by_rows > 0
_to_row = triangle_rows - 1
	ELSE
_to_row = 0
	ENDIF
	IF by_strips > 0
_to_strip = 31
	ELSE
_to_strip = 0
	ENDIF
	ld hl, triangle_map + 256 * (_to_row - by_rows) + _to_strip - by_strips
	ld de, triangle_map + 256 * _to_row + _to_strip
	ld a, _rows
.row:
	DUP _count
		IF by_strips > 0
			ldd
		ELSE
			ldi
		ENDIF
	EDUP
	ld l, _to_strip - by_strips
	ld e, _to_strip
	IF by_strips > 0
		inc h			; LDD's last step, past column 0, took one off H
	ENDIF
	IF by_rows > 0
		dec h
		dec d
	ELSE
		inc h
		inc d
	ENDIF
	dec a
	jp nz, .row
	ENDM

;
;	Moves the view left one position and down one position
;	in isometric space, which means straight leftward in 2d terms.
;
move_view_left_down:
	SLIDE 0, 2

	; Update the map location.
	ld hl, (map_location)
	dec_x
	inc_y
	ld (map_location), hl

	; Recast the left column.
	ld ix, triangle_map
	inc_x
	push hl
	call cast_even_column

	; Recast the one-from-left column.
	ld ix, triangle_map+1
	pop hl
	jp cast_odd_column

;
;	Moves the view left one position in isometric space,
;	which means diagonally to the left and upward in 2d terms.
;
move_view_left:
	SLIDE 1, 1

	; Update the map location.
	ld hl, (map_location)
	dec_x
	ld (map_location), hl

	; Cast top row.
	ld ix, triangle_map
	inc_x
	push hl
	call cast_even_row

	; Cast left column.
	ld ix, triangle_map
	pop hl
	jp cast_even_column

;
;	Moves the view left one position and up one position in isometric space,
;	which means straight upward in 2d terms.
;
move_view_left_up:
	SLIDE 2, 0

	; Update the map location.
	ld hl, (map_location)
	dec_x
	dec_y
	ld (map_location), hl

	; Set the triangle destination pointer.
	ld ix, triangle_map

	; Seed the current casting location.
	inc_x
	push hl
	call cast_even_row

	pop hl
	inc_y
	jp cast_odd_row

;
;	Moves the view down one position in isometric space,
;	which means diagonally to the left and downward in 2d terms.
;
move_view_down:
	SLIDE -1, 1

	; Update the map location.
	ld hl, (map_location)
	inc_y
	ld (map_location), hl

	; Cast left column.
	ld ix, triangle_map
	inc_x
	push hl
	call cast_even_column

	; Cast bottom row.
	pop hl
	add_xy num_rows, num_rows
	ld ix, triangle_map + 256 * num_rows * 2
	jp cast_even_row

;
;	Moves the view right one position and up one position
;	in isometric space, which means straight downward in 2d terms.
;
move_view_right_down:
	SLIDE -2, 0

	; Update the map location.
	ld hl, (map_location)
	inc_x
	inc_y
	ld (map_location), hl

	; Set the triangle destination pointer.
	ld ix, triangle_map + 256 * (num_rows * 2 - 1)

	; Seed the current casting location.
	add_xy num_rows, num_rows
	push hl
	call cast_odd_row

	pop hl
	inc_x
	jp cast_even_row

;
;	Moves the view right one position in isometric space,
;	which means diagonally to the right and downward in 2d terms.
;
move_view_right:
	SLIDE -1, -1

	; Update the map location.
	ld hl, (map_location)
	inc_x
	ld (map_location), hl

	; Cast bottom row.
	ld ix, triangle_map + 256 * num_rows * 2
	add_xy num_rows+1, num_rows
	call cast_even_row

	; Cast right column.
	ld ix, triangle_map+31
	ld hl, (map_location)
	add_xy 16, -15
	jp cast_odd_column

;
;	Moves the view right one position and up one position in isometric space,
;	which means straight right in 2d terms.
;
move_view_right_up:
	SLIDE 0, -2

	; Update the map location.
	ld hl, (map_location)
	inc_x
	dec_y
	ld (map_location), hl

	; Cast one-from-right column.
	ld ix, triangle_map+30
	add_xy 16, -15
	push hl
	call cast_even_column

	; Cast right column.
	ld ix, triangle_map+31
	pop hl
	jp cast_odd_column

;
;	Moves the view up one position in isometric space,
;	which means diagonally to the right and upward in 2d terms.
;
move_view_up:
	SLIDE 1, -1

	; Update the map location.
	ld hl, (map_location)
	dec_y
	ld (map_location), hl

	; Cast right column.
	ld ix, triangle_map+31
	add_xy 16, -15
	call cast_odd_column

	; Cast top row.
	ld hl, (map_location)
	inc_x
	ld ix, triangle_map
	jp cast_even_row
