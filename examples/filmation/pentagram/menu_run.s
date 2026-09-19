; ---------------------------------------------------------------------------
; The menu's running -- see menu.s. Here in the bytes in front of the pixel
; adjustments' index, which its page alignment would otherwise waste.
; ---------------------------------------------------------------------------

; The menu, until 0 starts a game.
; Corrupts everything.
menu_run:           ld      a,MENU_INK
                    call    frame_screen
                    call    menu_show
                    ld      hl,menu_tuned
                    ld      a,(hl)
                    or      a
                    jr      nz,.loop
                    inc     (hl)
                    call    sound_tune_title    ; once, and a key cuts it short
.loop:              call    menu_pick
                    ld      bc,MENU_KEY_0
                    in      a,(c)
                    rra                         ; a key reads 0 while it is held
                    jr      c,.loop
                    ret


; Every line, with the way chosen flashing. A line is printed over itself, so
; only its colour changes.
; Corrupts everything.
menu_show:          ld      a,(menu_mode)
                    rrca
                    and     3
                    inc     a                   ; lines 1 to 4 are the ways
                    ld      b,a
                    ld      a,1
.shift:             add     a,a
                    djnz    .shift
                    ld      (print_flash),a
                    ld      hl,menu_text
                    jp      print_lines
