; ---------------------------------------------------------------------------
; The status panel -- display_panel, print_lives_gfx and colour_panel, which
; Knight Lore draws every time it shows a room.
;
; It is a scroll along the bottom of the screen: a chain of links running down
; from each side to the middle, a bar up each edge, and a piece at the bottom
; either side of the middle; the knight's head beside the lives. Knight Lore
; has the word DAYS and the day's number in the middle, and the sun and moon
; in a window to the right; this game has no clock, and leaves both empty.
; The pieces are ordinary graphics drawn straight onto the screen, and
; their table is down with the room builder in
; panel_pieces. The lives are print_room's, which prints them every turn.
;
; The room is drawn over the same rows, so a repaint that reaches a piece wipes
; it: redraw_view calls panel_redraw, which puts back only the pieces the
; region touched.

PANEL_ROW           EQU     SCREEN_ROWS - 64    ; the highest any piece reaches

ATTR_FILL_ON         EQU     $11                 ; LD DE,nn: what attr_fill starts with

; Fill a block of attributes -- fill_window, at $C515. While a room is being
; drawn in the dark its first byte is a RET, so nothing is coloured in before the
; room is: see room_build and room_paper.
;
; In:  A  = the attribute
;      HL -> the top-left cell
;      B  = columns
;      C  = rows
; Out: nothing
; Corrupts: F, C, DE, HL -- nothing while it is a RET
attr_fill:           ld      de,32
.row:               push    bc
                    push    hl
.cell:              ld      (hl),a
                    inc     hl
                    djnz    .cell
                    pop     hl
                    add     hl,de
                    pop     bc
                    dec     c
                    jr      nz,.row
                    ret



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

                    ; White for the knight's head and the lives
                    ; (print_lives_gfx). colour_panel's black either side of the
                    ; sun is left out: nothing is drawn there.
                    ld      a,$47
                    ld      hl,$5800 + 18 * 32 + 2
                    ld      bc,2 << 8 | 1
                    call    attr_fill
                    ld      hl,$5800 + 19 * 32 + 2
                    ld      bc,4 << 8 | 1
                    call    attr_fill
                    ; And what is carried, which a region reaching it has wiped.
                    ld      a,(panel_draw.region + 1)
                    jp      carry_panel
