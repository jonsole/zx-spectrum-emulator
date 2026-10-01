; ---------------------------------------------------------------------------
; What Knight Lore draws straight on the screen, put back over a region.
;
; engine/redraw.s falls through into this at the end of every redraw_view, so
; it has to be included straight after it -- the ASSERT says so.
; ---------------------------------------------------------------------------

					ASSERT	$ == redraw_view_end

REDRAW_HOOK_ON		EQU		$3A		; LD A,(nn): what redraw_hook starts with

; The status panel, the carried objects in the bottom-left corner and the sun
; in the bottom-right are straight on the screen, and a region that reached
; any of them has just wiped it. The carried objects draw the whole panel
; after them, as the game does; otherwise the panel puts back the pieces the
; region touched. The sun goes on top of both.
;
; Not while a room is being drawn in the dark, though: this first byte is a
; RET until room_paper, and the panel, the carried objects and the sun are
; drawn once each after the room instead of once for every tile that reaches
; them.
;
; In:  view_x_extent, view_y_extent = the region
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF' -- nothing while it is a RET
redraw_hook:		ld		a,(view_y_extent+1)		; max, exclusive
					cp		PANEL_ROW + 1
					ret		c
					ld		hl,panel_redraw
					cp		SCREEN_ROWS - 24 + 1
					jr		c,.panel
					ld		a,(view_x_extent)
					cp		11		; their last column, plus one
					jr		nc,.panel
					ld		a,(view_x_extent+1)
					cp		3		; their first, plus one
					jr		c,.panel
					ld		hl,special_show
.panel:				call	.hl
					ld		a,(view_y_extent+1)
					cp		SUN_ROW + 1
					ret		c
					ld		a,(view_x_extent+1)
					cp		SUN_COLUMN + 1
					ret		c
					ld		a,(view_x_extent)
					cp		SUN_COLUMN + SUN_COLUMNS
					ret		nc
					jp		sun_show_all
.hl:				jp		(hl)
