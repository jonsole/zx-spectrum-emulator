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

; The choice, in Knight Lore's own layout -- it keeps the same byte at $5BA4.
; Bits 1 and 2 are the input method: 00 keyboard, 01 Kempston, 10 cursor,
; 11 Interface II. Bit 3 is directional control, which turns the left and
; right keys from turning the knight into walking him that way.
;
; NOTHING READS IT YET. player_step still has Q, A, O, P and SPACE wired
; straight in, which is what directional control on the keyboard amounts to.
; The menu is what sets this byte; reading it is the input pass, still to do.
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

; The four lines a method can flash, so the flash does not have to walk the
; strings to find where their attributes are.
menu_device_lines:  DW      menu_line_1, menu_line_2, menu_line_3, menu_line_4


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
                    ret


; The whole menu, over a black screen.
; Corrupts everything.
menu_draw:          ld      hl,menu_lines
                    ld      b,MENU_LINES
                    jp      end_show


; 1 to 5, and the menu drawn again if one of them changed something.
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
                    ;; NB: fall through into menu_flash


; The flash where the choice is now, and the menu drawn again to show it.
; Corrupts everything.
menu_flash:         ld      a,(menu_mode)
                    rrca
                    and     3                   ; which method
                    ld      hl,menu_device_lines
                    ld      b,MENU_DEVICES
.device:            ld      e,(hl)
                    inc     hl
                    ld      d,(hl)
                    inc     hl
                    push    hl
                    ex      de,hl               ; -> that line's attribute
                    res     7,(hl)
                    or      a
                    jr      nz,.next
                    set     7,(hl)              ; counted down to this one
.next:              dec     a                   ; past zero, and never zero again
                    pop     hl
                    djnz    .device

                    ld      hl,menu_line_5
                    res     7,(hl)
                    ld      a,(menu_mode)
                    and     $08
                    jr      z,menu_draw
                    set     7,(hl)
                    jr      menu_draw
