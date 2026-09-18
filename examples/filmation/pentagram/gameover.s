; ---------------------------------------------------------------------------
; The end of a game -- $C323.
;
; The screen goes to bright yellow on black ($46), a frame is drawn round it
; ($BD59, from a table at $BD98), and three lines are printed over it, each in
; its own colour, with the percentage of the quest done beside the last:
;
;   GAME OVER               row 32, from x 88    bright red      $42
;   PERCENTAGE OF QUEST     row 80, from x 48    bright magenta  $43
;   COMPLETED  nn           row 96, from x 64    bright green    $44
;
; Then a pause and back to the start. The original plays a tune over the pause
; ($D6B5) and goes back to its menu; the remake has neither yet, so it is
; silent, and a new game starts.
;
; The percentage is $C6EA's: half the rooms seen, up to 54, and four for each
; quest item and six for each piece of the pentagram -- 54 + 16 + 30, a
; hundred. The remake has the rooms but not the other two yet.
; ---------------------------------------------------------------------------

GAME_OVER_INK       EQU     $46                 ; bright yellow on black
GAME_OVER_WAIT      EQU     64                  ; the pause: 64 * 8K loops, as
                                                ; $C34D counts it
ROOMS_PERCENT_MOST  EQU     $36                 ; 54

; The frame, unrolled from $BD59: the graphic, X plus one if it is mirrored,
; the row below its bottom one (192 - Y) and whether it is upside down --
; bit 7 of the original's flags, which the bottom corners and edge have.
; Corners, the top and bottom edges eight long a piece apart, the ends of
; those, and the sides six long.
frame_pieces:
                    DB      5,   0,  24, 0
                    DB      5, 233,  24, 0
                    DB      5, 233, 192, 1
                    DB      5,   0, 192, 1
                    DB      4,  24,  24, 0
                    DB      4,  48,  24, 0
                    DB      4,  72,  24, 0
                    DB      4,  96,  24, 0
                    DB      4, 120,  24, 0
                    DB      4, 144,  24, 0
                    DB      4, 168,  24, 0
                    DB      4, 192,  24, 0
                    DB      4,  24, 192, 1
                    DB      4,  48, 192, 1
                    DB      4,  72, 192, 1
                    DB      4,  96, 192, 1
                    DB      4, 120, 192, 1
                    DB      4, 144, 192, 1
                    DB      4, 168, 192, 1
                    DB      4, 192, 192, 1
                    DB      3, 216,  24, 0
                    DB      3, 216, 192, 1
                    DB      2,   0, 168, 0
                    DB      2, 233, 168, 0
                    DB      2,   0, 144, 0
                    DB      2, 233, 144, 0
                    DB      2,   0, 120, 0
                    DB      2, 233, 120, 0
                    DB      2,   0,  96, 0
                    DB      2, 233,  96, 0
                    DB      2,   0,  72, 0
                    DB      2, 233,  72, 0
                    DB      2,   0,  48, 0
                    DB      2, 233,  48, 0
FRAME_PIECES        EQU     ($ - frame_pieces) / 4

; The lines: the row, the column, the colour, then the characters in the
; font's own codes -- a character less $30, and a space the blank at 13 --
; ending with $FF.
SPACE_CHAR          EQU     13
                    MACRO   game_over_line row, column, ink
                    DB      row, column, ink
                    ENDM
game_over_text:     game_over_line 32, 11, $42
                    DB      'G'-$30,'A'-$30,'M'-$30,'E'-$30,SPACE_CHAR
                    DB      'O'-$30,'V'-$30,'E'-$30,'R'-$30,$FF
                    game_over_line 80, 6, $43
                    DB      'P'-$30,'E'-$30,'R'-$30,'C'-$30,'E'-$30,'N'-$30
                    DB      'T'-$30,'A'-$30,'G'-$30,'E'-$30,SPACE_CHAR
                    DB      'O'-$30,'F'-$30,SPACE_CHAR
                    DB      'Q'-$30,'U'-$30,'E'-$30,'S'-$30,'T'-$30,$FF
                    game_over_line 96, 8, $44
                    DB      'C'-$30,'O'-$30,'M'-$30,'P'-$30,'L'-$30,'E'-$30
                    DB      'T'-$30,'E'-$30,'D'-$30,$FF
                    DB      0                   ; no more lines
PERCENT_ROW         EQU     96
PERCENT_COLUMN      EQU     18                  ; x 144

; rooms_seen, a bit a room -- the original's 31 bytes at $A74F -- is in
; quest_ram.s, in the room builder's page.


; ---------------------------------------------------------------------------
; Mark the room just entered as seen.
;   A - the room
; Corrupts AF, BC, HL.
room_seen:          ld      c,a
                    rrca
                    rrca
                    rrca
                    and     $1F
                    ld      hl,rooms_seen
                    add     a,l
                    ld      l,a
                    jr      nc,.byte
                    inc     h
.byte:              ld      a,c
                    and     7
                    ld      b,a
                    ld      a,1
                    jr      z,.bit
.shift:             add     a,a
                    djnz    .shift
.bit:               or      (hl)
                    ld      (hl),a
                    ret


; ---------------------------------------------------------------------------
; The whole screen, then the pause, then a new game.
game_over:          call    panel_off           ; nothing puts the panel back

                    ld      hl,$4000            ; the screen cleared
                    ld      de,$4001
                    ld      bc,6144 - 1
                    ld      (hl),0
                    ldir
                    ld      hl,$5800            ; and all one colour
                    ld      de,$5801
                    ld      bc,768 - 1
                    ld      (hl),GAME_OVER_INK
                    ldir

                    ; The frame. An upside-down piece is turned over where it
                    ; lies in the sprite table, drawn, and turned back.
                    ld      hl,frame_pieces
                    ld      b,FRAME_PIECES
.piece:             push    bc
                    ld      a,(hl)              ; the graphic
                    ld      (.gfx + 1),a
                    inc     hl
                    ld      c,(hl)              ; x, plus one if mirrored
                    inc     hl
                    ld      e,(hl)              ; the row below its bottom
                    inc     hl
                    ld      a,(hl)              ; upside down?
                    ld      (game_over_upside + 1),a
                    inc     hl
                    push    hl
                    push    bc
                    push    de
                    call    game_over_turn      ; over, if it is to be
                    pop     de
                    pop     bc
                    ld      a,c
                    and     1
                    ld      d,a                 ; mirrored
                    xor     c
                    ld      c,a                 ; and x without the flag
.gfx:               ld      a,0                 ; patched: the graphic
                    call    screen_sprite
                    call    game_over_turn      ; and back
                    pop     hl
                    pop     bc
                    djnz    .piece

                    ; The lines.
                    ld      hl,game_over_text
.line:              ld      a,(hl)
                    or      a
                    jr      z,.lines_done
                    ld      b,a                 ; the row
                    inc     hl
                    ld      c,(hl)              ; the column
                    inc     hl
                    ld      a,(hl)              ; the colour
                    inc     hl
                    call    game_over_print
                    jr      .line
.lines_done:
                    ; The percentage: half the rooms seen, and no more than 54.
                    ld      hl,rooms_seen
                    ld      c,32
                    ld      e,0
.count_byte:        ld      a,(hl)
                    ld      b,8
.count_bit:         rra
                    jr      nc,.not_seen
                    inc     e
.not_seen:          djnz    .count_bit
                    inc     hl
                    dec     c
                    jr      nz,.count_byte
                    srl     e
                    ld      a,e
                    cp      ROOMS_PERCENT_MOST
                    jr      c,.capped
                    ld      a,ROOMS_PERCENT_MOST
.capped:            ld      e,a                 ; and four a quest item done,
                    ld      a,(quest_done)      ; six a collectable in place
                    add     a,a
                    add     a,a
                    add     a,e
                    ld      e,a
                    ld      a,(quest_placed)
                    add     a,a
                    ld      d,a
                    add     a,a
                    add     a,d
                    add     a,e
                    ld      b,a                 ; to BCD, a unit at a time, as
                    xor     a                   ; $C718 does it, carrying into
                    ld      c,a                 ; the hundreds
                    inc     b
                    dec     b
                    jr      z,.bcd
.to_bcd:            add     a,1
                    daa
                    jr      nc,.no_carry
                    inc     c
.no_carry:          djnz    .to_bcd
.bcd:               ld      (game_over_percent),a
                    ld      a,c                 ; a hundred: the 1 first, and the
                    or      a                   ; two digits after it ($C739)
                    ld      c,PERCENT_COLUMN * 8
                    jr      z,.tens
                    ld      a,1
                    ld      b,PERCENT_ROW
                    call    panel_char
                    ld      c,(PERCENT_COLUMN + 1) * 8
.tens:              ld      hl,game_over_percent
                    ld      b,PERCENT_ROW
                    ld      e,1
                    call    panel_bcd
                    ld      a,$44               ; in the last line's colour
                    ld      hl,$5800 + (PERCENT_ROW / 8) * 32 + PERCENT_COLUMN
                    ld      (hl),a
                    inc     hl
                    ld      (hl),a
                    inc     hl
                    ld      (hl),a              ; and a third, for a hundred

                    ; The pause the original's tune would fill.
                    ld      b,GAME_OVER_WAIT
.wait:              ld      hl,$2000
.spin:              dec     hl
                    ld      a,h
                    or      l
                    jr      nz,.spin
                    djnz    .wait

                    ld      hl,rooms_seen       ; a new game has seen nothing
                    ld      de,rooms_seen + 1
                    ld      bc,32 - 1
                    ld      (hl),0
                    ldir
                    jp      new_game

; Turn the frame piece in hand over, if it is an upside-down one.
; Corrupts everything.
game_over_turn:
game_over_upside:   ld      a,0                 ; patched: upside down?
                    or      a
                    ret     z
                    ld      a,(game_over.gfx + 1)
                    jp      sprite_flip_v

game_over_percent:  DB      0


; One line: the characters from HL to an $FF, at row B from column C, and
; their cells coloured A.
; Out: HL past the $FF. Corrupts AF, BC, DE.
game_over_print:    ld      (.ink + 1),a
                    push    hl
                    ld      a,b                 ; the attribute row: rows are
                    rrca                        ; on character boundaries here
                    rrca
                    rrca
                    and     $1F
                    ld      l,a
                    ld      h,0
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    ld      a,c
                    add     a,l
                    ld      l,a
                    ld      de,$5800
                    add     hl,de
                    ex      de,hl               ; DE -> the first cell
                    pop     hl
.char:              ld      a,(hl)
                    inc     hl
                    cp      $FF
                    ret     z
                    push    hl
                    push    de
                    push    bc
                    push    af
                    ld      a,c                 ; column to pixels
                    add     a,a
                    add     a,a
                    add     a,a
                    ld      c,a
                    pop     af
                    call    panel_char
                    pop     bc
                    pop     de
                    pop     hl
.ink:               ld      a,0                 ; patched: the colour
                    ld      (de),a
                    inc     de
                    inc     c
                    jr      .char


; ---------------------------------------------------------------------------
; Turn a sprite upside down where it lies in the table: Knight Lore's
; menu_flip_v, for any graphic. Twice puts it back. Its rows swap end for end,
; mask and data together.
;   A - the graphic
; Corrupts everything.
sprite_flip_v:      ld      l,a
                    ld      h,(high sprite_table) / 2
                    add     hl,hl
                    ld      a,(hl)
                    inc     l                   ; the low byte is even
                    ld      h,(hl)
                    ld      l,a

                    ld      a,(hl)              ; the blit index, which says
                    sprite_width_class          ; how wide it is
                    add     a,2
                    add     a,a                 ; a mask and a data byte a column
                    ld      c,a
                    add     a,a                 ; and two rows' worth, which is
                    ld      (.back + 1),a       ; what walks the far end back
                    inc     l
                    ld      b,(hl)              ; how many rows
                    inc     hl                  ; -> the first of them

                    ; DE -> the last row, B - 1 rows along.
                    push    hl
                    ld      d,0
                    ld      e,c
                    ld      a,b
.last:              dec     a
                    jr      z,.ends
                    add     hl,de
                    jr      .last
.ends:              ex      de,hl
                    pop     hl

                    ; Swap them, working inwards. An odd row in the middle
                    ; stays where it is.
                    srl     b
                    ret     z
.row:               push    bc
.byte:              ld      a,(de)
                    ld      b,a
                    ld      a,(hl)
                    ld      (de),a
                    ld      a,b
                    ld      (hl),a
                    inc     hl
                    inc     de
                    dec     c
                    jr      nz,.byte
                    pop     bc
                    ld      a,e
.back:              sub     0                   ; patched: two rows
                    ld      e,a
                    jr      nc,.same
                    dec     d
.same:              djnz    .row
                    ret
