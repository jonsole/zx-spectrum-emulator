; ---------------------------------------------------------------------------
; What the game keeps straight on the screen over the room, put back after a
; repaint has wiped it: the panel's pieces, and its word and numbers.
;
; redraw_view falls into this -- see ../engine/redraw.s -- so it has to begin
; exactly where that ends.
;
; Not while a room is being drawn, though: room_build makes the first byte a
; RET, or every tile of a new room that reached the bottom of the screen would
; draw the panel again, and main.s puts it back with panel_on once the room is
; up, drawing the whole panel once.
; ---------------------------------------------------------------------------

                    ASSERT  $ == redraw_view_end
REDRAW_HOOK_ON      EQU     $3A                 ; LD A,(nn): what it starts with
redraw_hook:        ld      a,(view_y_extent+1) ; max, exclusive
                    cp      PANEL_ROW + 1
                    ret     c                   ; nowhere near the panel
                    call    panel_redraw
                    ld      a,(view_y_extent+1)
                    cp      LIVES_ROW + 1
                    ret     c                   ; above the words and numbers
                    call    panel_word
                    call    panel_lives
                    jp      panel_score


; The room is up: the panel on again, and all of it drawn.
; Corrupts everything but IX and IY.
panel_on:           ld      a,REDRAW_HOOK_ON
                    ld      (redraw_hook),a
                    jp      panel_show

; And off while the next is drawn.
; Corrupts AF.
panel_off:          ld      a,$C9               ; RET
                    ld      (redraw_hook),a
                    ret
