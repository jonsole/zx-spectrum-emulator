; --- redrawing ------------------------------------------------------
;
; Nothing draws the whole screen. Each moving object repaints only the
; area it disturbed -- the union of where it was and where it now is --
; and objects_draw_all composites every object that intersects that area,
; so whatever it passed over is put back in the same pass.
;
; An area is bounded by what the view buffer holds: VIEW_BUF_WIDTH bytes
; across and VIEW_BUF_ROWS rows down, which is 8 x 64. A one-pixel step
; widens an object's extent by at most one byte -- a byte-aligned sprite
; spans w bytes and a shifted one w+1, and the union of two adjacent
; positions is never more than w+1 -- so with the widest sprite at 5 bytes
; the union peaks at 6 columns, and the tallest at 64 rows. Both fit.

region_rows:		DB		0
region_width:		DB		0


; redraw_orient used to live here: one pass per region, settling every
; shared graphic before objects_draw_all ran. That is one decision too few
; -- two objects in a region wanting opposite orientations leave whichever
; the pass reached last holding the graphic. sprite_orient asks per object
; instead, at the point of drawing, so this is gone.


; Start a region that several objects will be folded into. The bounds begin
; impossible -- a minimum nothing can be above, a maximum nothing can be below
; -- so the first region_add sets both. Adding nothing at all leaves them that
; way, which redraw_view would read as a region and try to draw, so every
; region_reset must be followed by at least one region_add.
region_reset:       ld      hl,$00FF            ; l = min, h = max
                    ld      (view_y_extent),hl
                    ld      (view_x_extent),hl
                    ret


; Widen the pending region to take in one object's extent.
;   IX -> the object
; Corrupts A and HL. DE, BC and IX are untouched, so a caller can hold a step
; in DE across it.
region_add:         ld      hl,view_y_extent
                    ld      a,(ix+OBJ.MIN_Y)
                    cp      (hl)
                    jr      nc,.max_y           ; keep whichever is smaller
                    ld      (hl),a
.max_y:             inc     hl
                    ld      a,(ix+OBJ.MAX_Y)
                    cp      (hl)
                    jr      c,.min_x            ; keep whichever is larger
                    ld      (hl),a
.min_x:             ld      hl,view_x_extent
                    ld      a,(ix+OBJ.MIN_X)
                    cp      (hl)
                    jr      nc,.max_x
                    ld      (hl),a
.max_x:             inc     hl
                    ld      a,(ix+OBJ.MAX_X)
                    cp      (hl)
                    ret     c
                    ld      (hl),a
                    ret


; A region that is waiting to be drawn, or a max of zero for none.
pend_y_extent:		dw		0
pend_x_extent:		dw		0


; Repaint a region -- but not yet, if it overlaps one already waiting.
;
; A ghost carrying two blocks is three movers, and each repainted its own area
; in turn: the ghost drew the stack, then each block drew very nearly the same
; patch again, walls behind it and all. Room $BB spent more than half its turn
; on the two repaints that changed nothing the first had not already drawn.
; Knight Lore never has the problem because it composes everything that moved
; into one frame.
;
; So a region joins the one waiting when the two overlap and the union still
; fits the view buffer, and otherwise the waiting one is drawn and this one
; waits in its place. Nothing is drawn wrong by waiting: a draw composites the
; objects as they are when it happens, never as they were when the region was
; made -- so a region drawn late shows the same thing a region drawn at once
; would, plus whatever has moved since. It is only ever a question of how many
; times the same pixels are drawn. redraw_flush draws what is left at the end
; of the turn.
;
; Regions that do not overlap are not merged even when they would fit: the
; rows between them would be composited for nothing.
;   view_y_extent, view_x_extent - the region
; Corrupts AF, BC, DE, HL; and IX, when it draws.
redraw_defer:		ld		a,(pend_y_extent+1)
					or		a
					jr		z,.adopt		; nothing waiting

					ld		hl,(view_y_extent)		; l = min, h = max
					ld		de,(pend_y_extent)		; e = min, d = max
					ld		a,l
					cp		d
					jr		nc,.apart		; starts below the waiting one's end
					ld		a,e
					cp		h
					jr		nc,.apart		; ...or ends above its start
					ld		a,e
					cp		l
					jr		c,.y_min
					ld		e,l
.y_min:				ld		a,d
					cp		h
					jr		nc,.y_max
					ld		d,h
.y_max:				ld		a,d
					sub		e
					cp		VIEW_BUF_ROWS + 1
					jr		nc,.apart		; together too tall for the buffer
					ld		b,d
					ld		c,e		; the union in Y, for if X agrees

					ld		hl,(view_x_extent)
					ld		de,(pend_x_extent)
					ld		a,l
					cp		d
					jr		nc,.apart
					ld		a,e
					cp		h
					jr		nc,.apart
					ld		a,e
					cp		l
					jr		c,.x_min
					ld		e,l
.x_min:				ld		a,d
					cp		h
					jr		nc,.x_max
					ld		d,h
.x_max:				ld		a,d
					sub		e
					cp		VIEW_BUF_WIDTH + 1
					jr		nc,.apart		; together too wide
					ld		(pend_x_extent),de
					ld		(pend_y_extent),bc
					ret

					; Draw the one waiting, and this one waits instead.
.apart:				ld		hl,(view_y_extent)
					ld		de,(pend_y_extent)
					ld		(pend_y_extent),hl
					ld		(view_y_extent),de
					ld		hl,(view_x_extent)
					ld		de,(pend_x_extent)
					ld		(pend_x_extent),hl
					ld		(view_x_extent),de
					jp		redraw_view

.adopt:				ld		hl,(view_y_extent)
					ld		(pend_y_extent),hl
					ld		hl,(view_x_extent)
					ld		(pend_x_extent),hl
					ret


; Draw the region still waiting, if there is one.
; Corrupts everything.
redraw_flush:		ld		a,(pend_y_extent+1)
					or		a
					ret		z
					ld		hl,(pend_y_extent)
					ld		(view_y_extent),hl
					ld		hl,(pend_x_extent)
					ld		(view_x_extent),hl
					ld		hl,0
					ld		(pend_y_extent),hl
					jp		redraw_view


; The whole screen, composited in tiles the size of the view buffer: left to
; right along a row of them, and the rows top to bottom. This is how a new room
; is drawn. An object at a time drags each object's neighbours through the blit
; again for every one of them, and mirrors the shared graphics back and forth as
; it goes; a tile composites everything that reaches it once. The tiles meet
; edge to edge and cover every pixel, so nothing has to be wiped first.
; Corrupts everything.
					ASSERT	32 % VIEW_BUF_WIDTH == 0 && SCREEN_ROWS % VIEW_BUF_ROWS == 0
redraw_screen:		ld		de,0		; D - the tile's top row, E - its left column
.tile:				push	de
					ld		l,d
					ld		a,d
					add		a,VIEW_BUF_ROWS
					ld		h,a
					ld		(view_y_extent),hl		; l = min, h = max
					ld		l,e
					ld		a,e
					add		a,VIEW_BUF_WIDTH
					ld		h,a
					ld		(view_x_extent),hl
					call	redraw_view
					pop		de
					ld		a,e
					add		a,VIEW_BUF_WIDTH
					and		31		; off the right-hand edge is column 0
					ld		e,a
					jr		nz,.tile
					ld		a,d
					add		a,VIEW_BUF_ROWS
					ld		d,a
					cp		SCREEN_ROWS
					jr		c,.tile
					ret


; Repaint one object's own area, with no previous position to take in.
;   IX -> the object
redraw_object:		ld		a,(ix+OBJ.MIN_Y)
					ld		(view_y_extent),a
					ld		a,(ix+OBJ.MAX_Y)
					ld		(view_y_extent+1),a
					ld		a,(ix+OBJ.MIN_X)
					ld		(view_x_extent),a
					ld		a,(ix+OBJ.MAX_X)
					ld		(view_x_extent+1),a


; Clear the view buffer, composite everything that intersects the view
; extent into it, and copy the result to its place on the screen. Both
; extents are (min, max) with max exclusive, so max - min is a size.
; No object in the sprite set is taller than VIEW_BUF_ROWS, so there is no
; height case to handle here: the tallest is the 64-row castle arch and the
; buffer holds exactly 64. That is the whole reason the buffer went to
; 8 x 64 -- a region that does not fit has nowhere to go but wrap.
redraw_view:		ld		hl,(view_y_extent)	; l = min, h = max
					ld		a,h
					sub		l
					ret		z		; nothing to draw -- and the copy's
					; DJNZ would take a zero as 256 rows
					cp		VIEW_BUF_ROWS + 1		; taller than the buffer holds cannot
					ret		nc		; be drawn, and must not be tried:
					; the row address has one carry bit and
					; would land outside the buffer
					ld		(region_rows),a

					ld		hl,(view_x_extent)
					ld		a,h
					sub		l
					cp		VIEW_BUF_WIDTH + 1		; a region wider than the buffer
					jr		c,.width_ok		; would aim the copy's DJNZ before the
					ld		a,VIEW_BUF_WIDTH		; start of its LDI chain, so clamp
.width_ok:			ld		(region_width),a
					ld		a,TURN_PER_REGION
					call	turn_add

					; Clear the rows this region uses, by pushing zeroes down through
					; them. PUSH writes two bytes for 11T against LDIR's 21T per byte,
					; so even blanking the lot this way beats LDIR over one region.
					;
					; It no longer blanks the lot, though. At 512 bytes that would be
					; 2816T every region, twice what the old 256-byte buffer cost, and
					; the rows past the region are never read: only the region's own
					; rows are cleared, four pushes to each of its eight-byte rows.
					;
					; The four used to be one entry point into a straight run of 256
					; `push de`, which cost nothing per row but 256 bytes of image.
					; A DJNZ round them costs 13T a row -- 390T on a 30-row region,
					; under half a percent of a turn -- and gives those bytes back.
					; region_rows cannot be zero: redraw_view returned above if it was.
					ld		(.restore_sp+1),sp		; save the real stack
					ld		a,(region_rows)
					ld		b,a		; a row an iteration
					ld		l,a
					ld		h,0
					add		hl,hl
					add		hl,hl
					add		hl,hl		; hl = rows * 8, the bytes they cover
					ld		de,view_buffer
					add		hl,de
					ld		sp,hl		; PUSH pre-decrements, so this fills downwards
					ld		de,0		; and this is what every push writes
.clear:				push	de
					push	de
					push	de
					push	de
					djnz	.clear
.restore_sp:		ld		sp,0		; operand set just above

					; No orientation pass here any more. It settled the shared
					; graphics once for the whole region, which is one decision
					; too few: objects_draw_all now asks per object, in
					; sprite_orient, at the point it is about to draw one.
					call	objects_draw_all

					; Set the copy routine up for this width. There is one
					; of it: how many bytes of a row to move, and the step from
					; the end of one row of the buffer to the start of the
					; next, both go in as immediates.
					ld		a,(region_width)
					ld		b,a		; B is not wanted until pixelAddress
					ld		a,VIEW_BUF_WIDTH
					sub		b
					ld		(vid_buff_row.hstride+1),a
					add		a		; the LDI chain is two bytes a column
					add		a,VID_BUFF_LOOP_BASE
					ld		(vid_buff_copy.loop+1),a

					; ...and where on the screen it goes
					ld		a,(view_x_extent)		; min x, in bytes
					add		a
					add		a
					add		a		; -> pixels
					ld		c,a
					ld		a,(view_y_extent)
					ld		b,a
					call	pixelAddress		; hl = screen address; bc kept
					ex		de,hl		; de = destination
					ld		hl,view_buffer
					ld		a,(region_rows)
					inc		a		; and one for the DJNZ on the way in
					ld		b,a		; row counter, for the DJNZ. C is the copy
					; routine's own -- it resets it from D every
					; row so that LDI's countdown can never
					; borrow into B and lose a row.
					call	vid_buff_copy

					;; NB: falls through into redraw_hook, the game's -- which
					;; knightlore.s includes straight after this file. It draws
					;; whatever the game keeps straight on the screen over a
					;; region that has just wiped it, and returns.
redraw_view_end		EQU		$
