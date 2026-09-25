; isoblocks: the camera. A game says which of the four views it wants and
; which cell to centre on; view_update turns that into what read_view and
; paint need.

view_number:		DB		0			; 0-3, a quarter turn each
focus_x:			DB		64			; the cell the view is centred on
focus_y:			DB		64

; What view_update leaves for read_view.
view_map:			DW		MAP			; the map address of the first cell read
step_along:			DW		0			; one cell to the next along a half-row
step_second:		DW		0			; a row's start to its second half-row
step_next:			DW		0			; a row's start to the next row's


; ---------------------------------------------------------------------------
; view_update: set the view up for the frame from view_number and the focus.
;
; The focus is clamped to the view's limits first, and written back, so the
; view never reads a cell off the map -- that is what lets read_view read
; without testing anything. A map keeps an empty border for the view to show.
;
; Uses everything but IX and IY.

view_update:
					ld		a,(view_number)
					and		3
					add		a,a
					add		a,a
					add		a,a
					add		a,a
					ld		l,a
					ld		h,0
					ld		de,view_table
					add		hl,de				; HL = this view's entry
					ld		de,step_along
					ld		bc,6
					ldir						; the three steps
					ld		c,(hl)				; the first cell's x from the focus
					inc		hl
					ld		b,(hl)				; ...and y
					inc		hl
					ld		de,focus_x
					call	clamp				; x between the next two bytes
					inc		de					; focus_y
					call	clamp
					ld		e,(hl)				; the drawers for this view's block:
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		(paint_drawer_first + 1),de	; in a first half-row...
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		(paint_drawer_second + 1),de	; ...and in a second

					; view_map = MAP + 128 x (focus y + y offset) + focus x + x offset.
					; 128y + x is y / 2 in the high byte, and y's low bit on top of
					; x in the low byte -- x is under 128, so there is room.
					ld		a,(focus_x)
					add		a,c
					ld		l,a
					ld		a,(focus_y)
					add		a,b
					srl		a					; y / 2, and y's low bit in carry
					jr		nc,.even
					set		7,l
.even:				add		a,high MAP
					ld		h,a
					ld		(view_map),hl
					ret

; Clamp the byte at DE between (HL) and (HL + 1); HL is moved past both.
clamp:
					ld		a,(de)
					cp		(hl)
					jr		nc,.not_low
					ld		a,(hl)
.not_low:			inc		hl
					cp		(hl)
					jr		c,.not_high
					jr		z,.not_high
					ld		a,(hl)
.not_high:			inc		hl
					ld		(de),a
					ret
