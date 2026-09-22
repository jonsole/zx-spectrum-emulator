; ---------------------------------------------------------------------------
; The menu -- do_menu_selection at $BD0C, and the tune it plays.
;
; Eight lines: the title, four input methods, the directional-control toggle,
; "0 START GAME", and a line of our own where the game puts its copyright.
; The chosen method flashes, and so does the toggle while it is on; 1 to 5
; change them and 0 starts.
;
; The tune plays once, on the way in, and any key cuts it short -- which is
; what play_audio_wait_key at $B2B6 does with the flag it keeps at $5BD1.
; Ours needs no flag: the tune is played before the loop rather than inside it.
;
; Everything here is cold. It draws with end_show and end_string, which the
; end screens already pay for, and prints through room.s's print_char.
; ---------------------------------------------------------------------------

MENU_LINES          EQU     8
MENU_DEVICES        EQU     4                   ; keyboard, Kempston, cursor, IF2

MENU_KEYS_1_5       EQU     $F7FE               ; 1 in bit 0 up to 5 in bit 4
MENU_KEY_0          EQU     $EFFE               ; 0 in bit 0

; The frame -- print_border at $D296 and the border_data it walks. Three
; graphics do all of it: the corner knot, one row of the side runs, and one
; byte of the top and bottom runs. A run is that slice repeated, which is how
; the game draws them too: 24 along the top and the bottom, 128 down each side.
MENU_FRAME_ATTR     EQU     $46                 ; bright yellow, under everything
MENU_CORNER_GFX     EQU     GFX_MENU_1                 ; four bytes by 32 rows
MENU_CORNER_X       EQU     224                 ; where the right-hand pair start
MENU_SIDE_X         EQU     232                 ; and the right-hand side run
MENU_SIDE_BITS      EQU     %00111100           ; a run's four pixels, graphic 138
MENU_BAR_ROWS       EQU     4                   ; and its thickness, graphic 139
MENU_RUN_FROM       EQU     32                  ; the runs, between the corners
MENU_RUNS           EQU     24                  ; bytes of top and bottom run
MENU_SIDE_FROM      EQU     32                  ; the first row of the side runs
MENU_SIDES          EQU     128

; The choice, in Knight Lore's own layout -- it keeps the same byte at $5BA4.
; Bits 1 and 2 are the input method: 00 keyboard, 01 Kempston, 10 cursor,
; 11 Interface II. Bit 3 is directional control: a stick names the way to
; walk rather than turning him. It means nothing on the keyboard.
;
; input_read takes the method from it, player_turn the directional control,
; and special_keys the directional control too, to know where a stick has put
; pick up.
menu_mode:          DB      0

; 5 is a toggle rather than a choice, so it only counts on the way down.
menu_held:          DB      0


; The lines, in end_show's shape: the attribute, the character row and column,
; then the characters with the last carrying bit 7. The positions are the
; game's own, converted out of its bottom-up pixel coordinates -- its
; ($58,$9F) is our row 4, column 11 -- and so are the colours, including the
; flash already on the keyboard line, which is what a fresh menu has chosen.
menu_lines:
menu_line_0:        DB      $43, 4, 11
                    DB      $14,$17,$12,$10,$11,$1D,$26,$15,$18,$1B,$8E  ; KNIGHT LORE
menu_line_1:        DB      $C4, 6, 6
                    DB      $01,$26,$14,$0E,$22,$0B,$18,$0A,$1B,$8D      ; 1 KEYBOARD
menu_line_2:        DB      $44, 8, 6
                    DB      $02,$26,$14,$0E,$16,$19,$1C,$1D,$18,$17,$26,$13,$18,$22
                    DB      $1C,$1D,$12,$0C,$94                          ; 2 KEMPSTON JOYSTICK
menu_line_3:        DB      $44, 10, 6
                    DB      $03,$26,$0C,$1E,$1B,$1C,$18,$1B,$26,$26,$26,$13,$18,$22
                    DB      $1C,$1D,$12,$0C,$94                          ; 3 CURSOR   JOYSTICK
menu_line_4:        DB      $44, 12, 6
                    DB      $04,$26,$12,$17,$1D,$0E,$1B,$0F,$0A,$0C,$0E,$26,$12,$92
                                                                         ; 4 INTERFACE II
menu_line_5:        DB      $45, 14, 6
                    DB      $05,$26,$0D,$12,$1B,$0E,$0C,$1D,$12,$18,$17,$0A,$15,$26
                    DB      $0C,$18,$17,$1D,$1B,$18,$95                  ; 5 DIRECTIONAL CONTROL
menu_line_6:        DB      $47, 16, 6
                    DB      $00,$26,$1C,$1D,$0A,$1B,$1D,$26,$10,$0A,$16,$8E
                                                                         ; 0 START GAME
menu_line_7:        DB      $47, 19, 8
                    DB      $0F,$12,$15,$16,$0A,$1D,$12,$18,$17,$26,$1B,$0E,$16,$0A
                    DB      $14,$8E                                      ; FILMATION REMAKE


; The menu tune -- menu_tune at $B253, the same note bytes the end screens'
; tunes are written in.
tune_menu:          DB      $1B,$27,$1B,$27,$1B,$2A,$2E,$1B,$27,$1B,$27,$1B,$2A,$1B
                    DB      $2E,$16,$25,$16,$24,$16,$22,$16,$22,$16,$25,$16,$24,$16
                    DB      $22,$16,$22,$16,$22,$1B,$27,$1B,$27,$1B,$2A,$2E,$1B,$27
                    DB      $1B,$27,$1B,$2A,$1B,$2E,$16,$25,$16,$24,$16,$22,$16,$22
                    DB      $16,$25,$16,$24,$16,$22,$16,$22,$16,$22,$17,$2E,$17,$2E
                    DB      $17,$2E,$17,$2E,$19,$2E,$19,$2E,$19,$2E,$19,$2E,$1B,$2E
                    DB      $1B,$2E,$1B,$2E,$1B,$2E,$1B,$2E,$1B,$2E,$1B,$2E,$1B,$2E
                    DB      $FF


; The tune a game starts to -- start_game_tune at $B20E, played through
; whatever is held, because 0 still is.
tune_start:         DB      $59,$5C,$5B,$54,$19,$17,$14,$17,$D9,$FF


; The menu, until 0 starts the game.
; Corrupts everything.
menu_run:           call    menu_draw
                    ld      de,tune_menu
                    call    tune_play           ; once, and any key cuts it short
.loop:              call    menu_pick
                    ld      bc,MENU_KEY_0
                    in      a,(c)
                    rra                         ; a key reads 0 while it is held
                    jr      c,.loop
                    ld      de,tune_start
                    jp      tune_play_all


; The whole menu: the frame's colour under everything, the lines, and then
; the frame itself.
; Corrupts everything.
menu_draw:          ld      hl,menu_lines
                    ld      b,MENU_LINES
                    ld      c,MENU_FRAME_ATTR
                    call    end_show

                    ;; NB: fall through into menu_border


; The frame -- print_border at $D296.
;
; The game draws all of it with print_sprite: four corner knots, then one
; graphic repeated 24 times along the top and the bottom and another 128 times
; down each side. Only the corners are drawn that way here. The two runs are a
; four-pixel bar and a gap, and a sprite one byte wide has no width class --
; the blit index would underflow -- so they are laid down as what they are.
;
; The two top corners are the bottom ones upside down, and nothing else in the
; game draws a sprite that way, so rather than teach screen_sprite to,
; menu_flip_v turns the corner over where it lies and back again.
; Corrupts everything.
menu_border:        ld      hl,menu_corners
                    ld      b,MENU_CORNERS
.corner:            push    bc
                    ld      c,(hl)              ; x
                    inc     hl
                    ld      e,(hl)              ; the row below its bottom
                    inc     hl
                    ld      d,(hl)              ; and whether it is mirrored
                    inc     hl
                    push    hl
                    ld      a,MENU_CORNER_GFX
                    call    screen_sprite
                    pop     hl
                    pop     bc
                    ld      a,b
                    cp      MENU_CORNERS / 2 + 1    ; the bottom pair as it lies,
                    push    bc                      ; then the top pair over --
                    push    hl                      ; and the flip keeps nothing,
                    call    z,menu_flip_v           ; the count included
                    pop     hl
                    pop     bc
                    djnz    .corner
                    call    menu_flip_v             ; and back as it was

                    ; The top and bottom runs: four rows of solid bar, from
                    ; the row each band starts at.
                    ld      hl,menu_bars
                    ld      b,MENU_BARS
.band:              push    bc
                    ld      a,(hl)
                    inc     hl
                    push    hl
                    ld      c,MENU_BAR_ROWS
.bar:               push    bc
                    push    af
                    ld      b,a
                    ld      c,MENU_RUN_FROM
                    call    pixelAddress
                    ld      b,MENU_RUNS
                    ld      a,$FF
.along:             ld      (hl),a
                    inc     l                   ; a row is 32 bytes on a
                    djnz    .along              ; 32-byte boundary
                    pop     af
                    inc     a
                    pop     bc
                    dec     c
                    jr      nz,.bar
                    pop     hl
                    pop     bc
                    djnz    .band

                    ; And the sides, a row at a time: the same four pixels and
                    ; a gap, at both ends of the row.
                    ld      b,MENU_SIDES
                    ld      c,MENU_SIDE_FROM
.down:              push    bc
                    ld      b,c
                    ld      c,0
                    call    pixelAddress
                    ld      (hl),MENU_SIDE_BITS
                    inc     l
                    inc     l
                    ld      (hl),MENU_SIDE_BITS
                    ld      a,l
                    add     a,MENU_SIDE_X / 8 - 2
                    ld      l,a
                    ld      (hl),MENU_SIDE_BITS
                    inc     l
                    inc     l
                    ld      (hl),MENU_SIDE_BITS
                    pop     bc
                    inc     c
                    djnz    .down
                    ret

; x, the row below its bottom, and whether it is mirrored. The bottom pair
; first: the flip above turns the corner over once, halfway through.
menu_corners:       DB      0, 192, 0
                    DB      MENU_CORNER_X, 192, 1
                    DB      0, 32, 0
                    DB      MENU_CORNER_X, 32, 1
MENU_CORNERS        EQU     ($ - menu_corners) / 3

; The row each bar of the top and bottom runs starts at.
menu_bars:          DB      2, 18, 170, 186
MENU_BARS           EQU     $ - menu_bars


; Turn the corner over where it lies, so that screen_sprite draws it upside
; down. It is turned back straight afterwards: the sprite table is shared with
; the game, and this is the only thing that ever wants it this way up.
; Corrupts everything.
menu_flip_v:        ld      a,MENU_CORNER_GFX
                    ld      l,a
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
                    ; would stay where it is.
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

                    ; HL is on the next row down; DE has just walked along the
                    ; row it swapped, so it goes back two of them -- in one
                    ; subtraction, because two would borrow twice and only the
                    ; second carry would be there to see it.
                    ld      a,e
.back:              sub     0                   ; patched: two rows
                    ld      e,a
                    jr      nc,.same
                    dec     d
.same:              djnz    .row
                    ret


; 1 to 5, and the flash moved if one of them changed something.
; Corrupts everything.
menu_pick:          ld      bc,MENU_KEYS_1_5
                    in      a,(c)
                    cpl                         ; held reads 0, and this is
                    and     $1F                 ; easier to read the other way
                    ld      e,a
                    ld      a,(menu_mode)
                    ld      d,a                 ; to notice a change

                    bit     0,e                 ; 1: the keyboard
                    jr      z,.kempston
                    and     $F9
.kempston:          bit     1,e
                    jr      z,.cursor
                    and     $F9
                    or      $02
.cursor:            bit     2,e
                    jr      z,.interface_ii
                    and     $F9
                    or      $04
.interface_ii:      bit     3,e
                    jr      z,.directional
                    or      $06

                    ; 5 turns directional control over rather than choosing
                    ; it, so it has to be let go of before it counts again.
.directional:       ld      hl,menu_held
                    bit     4,e
                    jr      z,.let_go
                    bit     0,(hl)
                    jr      nz,.settled
                    set     0,(hl)
                    xor     $08
                    jr      .settled
.let_go:            res     0,(hl)

.settled:           ld      (menu_mode),a
                    cp      d
                    ret     z                   ; nothing moved
                    call    sound_pickup        ; the game's own blip, at $BD70

                    ;; NB: fall through into menu_flash


; The flash where the choice is now. Only the colours change: the lines are
; already on the screen, so each of the five that can flash has its attribute
; set or cleared and laid back over its own characters -- the lines are
; consecutive, and painting one leaves DE on the next.
; Corrupts everything.
menu_flash:         ld      hl,menu_line_1
                    ld      a,(menu_mode)
                    rrca
                    and     3                   ; which method
                    ld      b,MENU_DEVICES
.device:            res     7,(hl)
                    or      a
                    jr      nz,.paint
                    set     7,(hl)              ; counted down to this one
.paint:             dec     a                   ; past zero, and never zero again
                    push    af
                    push    bc
                    call    menu_paint
                    pop     bc
                    pop     af
                    ex      de,hl               ; on to the next line
                    djnz    .device

                    res     7,(hl)              ; and the toggle, menu_line_5
                    ld      a,(menu_mode)
                    and     $08
                    jr      z,menu_paint
                    set     7,(hl)

                    ;; NB: fall through into menu_paint


; A line's attribute onto the cells its characters are in, and no others: a
; blank cell given FLASH would blink solid, paper and ink swapping.
;   HL -> the line: its attribute, row and column, then the characters
; Returns DE -> the line after it. Corrupts AF, BC, HL.
menu_paint:         ld      c,(hl)
                    inc     hl
                    ld      d,(hl)
                    inc     hl
                    ld      e,(hl)
                    inc     hl
                    push    hl
                    push    bc
                    call    end_attr_at         ; which takes BC
                    pop     bc
                    pop     de                  ; DE -> the characters
.cell:              ld      (hl),c
                    inc     hl
                    ld      a,(de)
                    inc     de
                    rla                         ; the last one carries bit 7
                    jr      nc,.cell
                    ret
