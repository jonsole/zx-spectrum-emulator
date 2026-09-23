; ---------------------------------------------------------------------------
; The status panel, and the two numbers on it.
;
; Pentagram's is Knight Lore's shape -- $BCE5 draws it from a table at $BD31
; of the same kind as Knight Lore's panel_data: a graphic, whether it is
; mirrored, an X and a Y counted up from the bottom of the screen, some of
; them repeated along a step. Unrolled, that is the list below: two diagonal
; runs of five, stepping 16 across and 8 down; a bar up each edge; a piece at
; the bottom either side of the middle; one at each top corner -- and the
; little Sabreman by the lives, graphic 22, which $C29A draws where Knight
; Lore draws the knight's head.
;
; The pieces are ordinary graphics drawn straight onto the screen, so a repaint
; of the room that reaches one wipes it: redraw_hook in overlay.s puts back the
; pieces a region touched, and the numbers.
;
; The words and numbers, all measured from the original's own print calls,
; where a position is Y * 256 + X counted from the bottom and $B37F turns it
; into an address:
;
;   lives   two digits of $A721, BCD, at row 152 from column 4   ($C2C3)
;   SCORE   the word, at row 160 from column 24                   ($BB14)
;   score   six digits of $A744-$A746, BCD, row 175 from col 23   ($BB3B)
;
; white on black, $47, as $B514 and $A736 colour them.
; ---------------------------------------------------------------------------

PANEL_ROW           EQU     SCREEN_ROWS - 64    ; above every piece

LIVES_ROW           EQU     152
LIVES_COLUMN        EQU     4
SCORE_WORD_ROW      EQU     160
SCORE_WORD_COLUMN   EQU     24
SCORE_ROW           EQU     175
SCORE_COLUMN        EQU     23
PANEL_INK           EQU     $47                 ; bright white on black

; The panel's pieces: the graphic, X plus one if it is drawn mirrored, and the
; row below its bottom one, which is 192 - Y. In the order the game draws
; them, which matters where two overlap at the top corners.
panel_pieces:       DB      62,  16 + 1, 192 - 52   ; the left run, mirrored
                    DB      62,  32 + 1, 192 - 44
                    DB      62,  48 + 1, 192 - 36
                    DB      62,  64 + 1, 192 - 28
                    DB      62,  80 + 1, 192 - 20
                    DB      62, 224,     192 - 52   ; the right
                    DB      62, 208,     192 - 44
                    DB      62, 192,     192 - 36
                    DB      62, 176,     192 - 28
                    DB      62, 160,     192 - 20
                    DB      61,   0 + 1, 192 - 4    ; the edges
                    DB      61,   0 + 1, 192 - 36
                    DB      61, 240,     192 - 4
                    DB      61, 240,     192 - 36
                    DB      60,   0 + 1, 192 - 20
                    DB      60,   0 + 1, 192 - 52
                    DB      60, 240,     192 - 20
                    DB      60, 240,     192 - 52
                    DB      58,  96 + 1, 192 - 4    ; by the middle
                    DB      58, 144,     192 - 4
                    DB      59,   0 + 1, 192 - 52   ; the top corners
                    DB      59, 240,     192 - 52
                    DB      22,  16,     192 - 32   ; Sabreman, by the lives
PANEL_PIECES        EQU     ($ - panel_pieces) / 3

; "SCORE", in the font's own codes: a character's code less $30.
score_word:         DB      'S' - $30, 'C' - $30, 'O' - $30, 'R' - $30, 'E' - $30
SCORE_WORD_LENGTH   EQU     $ - score_word

; The lives, and the score, as the original keeps them: BCD, most significant
; first.
player_lives:       DB      $04
score:              DS      3


; ---------------------------------------------------------------------------
; The whole panel: every piece, the colours, the word and both numbers.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF'
panel_show:         xor     a
                    call    panel_draw
                    call    panel_colour
                    call    panel_word
                    call    panel_lives
                    jp      panel_score

; The pieces the last region reached, going by view_x_extent and view_y_extent.
;
; In:  view_y_extent, view_x_extent = the region
; Out: nothing
; Corrupts: AF, B, DE, HL, AF'
panel_redraw:       ld      a,1

; See panel_redraw: the pieces it reached, or with A = 0 all of them.
;
; In:  A = 0 for every piece, 1 for only those the region reached
;      view_y_extent, view_x_extent = the region, for 1
; Out: nothing
; Corrupts: AF, B, DE, HL, AF'
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
                    ; Rows: a region starting at or below its bottom misses it,
                    ; and so does one ending at or above its top, which its own
                    ; height gives -- the header's second byte. Assuming the
                    ; tallest any piece could be redrew pieces nowhere near the
                    ; region, 3% of a busy room's turn. Columns: none is wider
                    ; than three.
                    pop     af
                    push    af
                    ld      l,a
                    ld      h,(high sprite_table) / 2
                    add     hl,hl
                    ld      a,(hl)
                    inc     l                   ; the low byte is even
                    ld      h,(hl)
                    ld      l,a
                    inc     hl
                    ld      d,(hl)              ; D - its height
                    ld      hl,(view_y_extent)  ; L the first row, H the row after
                    ld      a,l
                    cp      e
                    jr      nc,.skip
                    ld      a,e
                    sub     d                   ; its top
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
                    add     a,3                 ; and past its last
                    cp      l
                    jr      c,.skip
                    jr      z,.skip

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
                    ret


; White for the lives and Sabreman by them, and for the score and its word:
; $B514 colours the lives' cells, and the word and the digits print in $47.
;
; In:  nothing
; Out: nothing
; Corrupts: A, B, HL
panel_colour:       ld      a,PANEL_INK
                    ld      hl,$5800 + 18 * 32 + 2
                    ld      b,2
                    call    .fill
                    ld      hl,$5800 + 19 * 32 + 2
                    ld      b,4
                    call    .fill
                    ld      hl,$5800 + (SCORE_WORD_ROW / 8) * 32 + SCORE_WORD_COLUMN
                    ld      b,SCORE_WORD_LENGTH
                    call    .fill
                    ld      hl,$5800 + (SCORE_ROW / 8) * 32 + SCORE_COLUMN
                    ld      b,6
                    call    .fill
                    ld      hl,$5800 + (SCORE_ROW / 8 + 1) * 32 + SCORE_COLUMN
                    ld      b,6
.fill:              ld      (hl),a
                    inc     hl
                    djnz    .fill
                    ret


; The word.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, E, HL
panel_word:         ld      hl,score_word
                    ld      c,SCORE_WORD_COLUMN * 8
                    ld      e,SCORE_WORD_LENGTH
.letter:            ld      a,(hl)
                    inc     hl
                    push    hl
                    push    de
                    ld      b,SCORE_WORD_ROW
                    call    panel_char
                    pop     de
                    pop     hl
                    ld      a,c
                    add     a,8
                    ld      c,a
                    dec     e
                    jr      nz,.letter
                    ret


; The lives, two digits.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, E, HL
panel_lives:        ld      hl,player_lives
                    ld      b,LIVES_ROW
                    ld      c,LIVES_COLUMN * 8
                    ld      e,1
                    jr      panel_bcd

; The score, six digits.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, E, HL
panel_score:        ld      hl,score
                    ld      b,SCORE_ROW
                    ld      c,SCORE_COLUMN * 8
                    ld      e,3

; E bytes of BCD from HL, two digits each, at row B and pixel column C.
;
; In:  HL -> the first byte
;      E  = how many bytes
;      B  = the row
;      C  = the pixel column
; Out: HL -> past the last byte
;      C  = the pixel column after the last digit
; Corrupts: AF, E
panel_bcd:          ld      a,(hl)
                    rrca
                    rrca
                    rrca
                    rrca
                    and     $0F
                    call    .digit
                    ld      a,(hl)
                    and     $0F
                    call    .digit
                    inc     hl
                    dec     e
                    jr      nz,panel_bcd
                    ret
.digit:             push    hl
                    push    de
                    push    bc
                    call    panel_char
                    pop     bc
                    pop     de
                    pop     hl
                    ld      a,c
                    add     a,8
                    ld      c,a
                    ret


; One character of the font, top row at row B, at pixel column C -- any row,
; since the score's is not on a character boundary.
;
; In:  A = the character's index in the font
;      B = the row of its top
;      C = the pixel column
; Out: nothing
; Corrupts: AF, B, DE, HL
panel_char:         ld      l,a
                    ld      h,0
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    ld      de,font
                    add     hl,de
                    ex      de,hl               ; DE -> the glyph
                    ld      a,8
.row:               push    af
                    call    pixelAddress        ; HL from B and C; keeps BC, DE
                    ld      a,(de)
                    ld      (hl),a
                    inc     de
                    inc     b
                    pop     af
                    dec     a
                    jr      nz,.row
                    ret


; ---------------------------------------------------------------------------
; Score, as the original adds it -- $BB29, BCD: C into the last byte and B
; into the one before, carrying up. Then shown.
;
; In:  B, C = the points, BCD
; Out: nothing
; Corrupts: AF, BC, E, HL
score_add:          ld      hl,score + 2
                    ld      a,(hl)
                    add     a,c
                    daa
                    ld      (hl),a
                    dec     hl
                    ld      a,(hl)
                    adc     a,b
                    daa
                    ld      (hl),a
                    dec     hl
                    ld      a,(hl)
                    adc     a,0
                    daa
                    ld      (hl),a
                    jp      panel_score
