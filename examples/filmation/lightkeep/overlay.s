; ---------------------------------------------------------------------------
; What Knight Lore draws straight on the screen, put back over a region.
;
; engine/redraw.s falls through into this at the end of every redraw_view, so
; it has to be included straight after it -- the ASSERT says so.
; ---------------------------------------------------------------------------

					ASSERT	$ == redraw_view_end

REDRAW_HOOK_ON		EQU		$3A		; LD A,(nn): what redraw_hook starts with

; The status panel is straight on the screen, and a region that reached it
; has just wiped it: the panel puts back the pieces the region touched.
;
; Not while a room is being drawn in the dark, though: this first byte is a
; RET until room_paper, and the panel is drawn once after the room instead
; of once for every tile that reaches it.
;
; In:  view_x_extent, view_y_extent = the region
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF' -- nothing while it is a RET
redraw_hook:		ld		a,(view_y_extent+1)		; max, exclusive
					cp		PANEL_ROW + 1
					ret		c
					jp		panel_redraw
