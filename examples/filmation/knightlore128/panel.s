; ---------------------------------------------------------------------------
; The status panel -- display_panel, display_day, print_lives_gfx and
; colour_panel, which the game draws every time it shows a room.
;
; It is a scroll along the bottom of the screen: a chain of links running down
; from each side to the middle, a bar up each edge, and a piece at the bottom
; either side of the day; the knight's head beside the lives; a word over the
; day number, in the room's colour turned round. The pieces are ordinary
; graphics drawn straight onto the screen, as the carried objects are, and
; their table is down with the room builder in panel_pieces. The two numbers
; are print_room's, which prints them every turn.
;
; The room is drawn over the same rows, so a repaint that reaches a piece wipes
; it: redraw_view calls panel_redraw, which puts back only the pieces the
; region touched. Anything that redraws the carried objects draws the whole
; panel after them, because the chain crosses the third of their places.

PANEL_ROW           EQU     SCREEN_ROWS - 64    ; the highest any piece reaches

; A character cell's top pixel row is at $4000 + third * 2048 + row within the
; third * 32 + column -- the screen's own arrangement, see pixelAddress.
DAYS_WORD_ROW       EQU     22                  ; four cells, over the day
DAYS_WORD_COLUMN    EQU     14


; The whole panel.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF'
panel_show:         xor     a
                    jr      panel_draw

; The pieces the last region reached, going by view_x_extent and view_y_extent.
;
; In:  view_x_extent, view_y_extent = the region
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF'
panel_redraw:       ld      a,1

; What both come to.
;
; In:  A = 0 for every piece, or 1 for those the region reached
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF'
panel_draw:         ld      (.region + 1),a
                    ld      hl,panel_pieces
                    ld      b,PANEL_PIECES
.piece:             push    bc
                    ld      a,(hl)              ; the graphic
                    inc     hl
                    ld      c,(hl)              ; x, plus one if mirrored
                    inc     hl
                    ld      e,(hl)              ; the row below its bottom
                    inc     hl
                    push    hl
                    push    af

.region:            ld      a,0                 ; patched: 0 for everything
                    or      a
                    jr      z,.draw
                    ; Rows: none of them is taller than 64, so a region ending
                    ; above bottom - 64 misses it, and one starting at or below
                    ; its bottom does too. Columns: it is two bytes wide.
                    ld      hl,(view_y_extent)  ; L the first row, H the row after
                    ld      a,l
                    cp      e
                    jr      nc,.skip
                    ld      a,e
                    sub     64
                    cp      h
                    jr      nc,.skip
                    ld      hl,(view_x_extent)
                    ld      a,c
                    rrca
                    rrca
                    rrca
                    and     $1F                 ; its first byte
                    cp      h
                    jr      nc,.skip
                    inc     a                   ; and its second
                    cp      l
                    jr      c,.skip

.draw:              ld      a,c
                    and     1
                    ld      d,a
                    xor     c
                    ld      c,a
                    pop     af
                    call    screen_sprite
                    jr      .next
.skip:              pop     af
.next:              pop     hl
                    pop     bc
                    djnz    .piece

                    ; The word over the day, in the room's colour turned round:
                    ; display_day works it out as (2 - the colour) and 7.
                    ld      a,(room_attr)
                    cpl
                    add     a,2
                    and     7
                    or      $40
                    ld      hl,$5800 + DAYS_WORD_ROW * 32 + DAYS_WORD_COLUMN
                    ld      bc,4 << 8 | 1
                    call    sun_fill
                    ld      hl,$4000 + (DAYS_WORD_ROW / 8) * 2048 + (DAYS_WORD_ROW % 8) * 32 + DAYS_WORD_COLUMN
                    ld      de,panel_word
                    ld      c,4
.letter:            push    hl
                    call    print_glyph
                    pop     hl
                    inc     hl
                    dec     c
                    jr      nz,.letter

                    ; White for the day's number (print_days) and for the knight's
                    ; head and the lives (print_lives_gfx). colour_panel's black
                    ; either side of the sun is left out: nothing is drawn there.
                    ld      a,$47
                    ld      hl,$5800 + 23 * 32 + 15
                    ld      bc,2 << 8 | 1
                    call    sun_fill
                    ld      hl,$5800 + 18 * 32 + 2
                    ld      bc,2 << 8 | 1
                    call    sun_fill
                    ld      hl,$5800 + 19 * 32 + 2
                    ld      bc,4 << 8 | 1
                    jp      sun_fill
