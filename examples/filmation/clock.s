; ---------------------------------------------------------------------------
; The day's clock and the attribute fill the panel and the sun's window share.
; Both are cold -- the clock does nothing on seven turns in eight, and the fill
; only when something is redrawn -- so they live down here, in what the mirror
; table's ALIGN would otherwise leave empty.

; The clock's turn. It stops once the wizard has everything, as the game's does.
day_step:           ld      a,(move_tick)
                    and     SUN_TURNS - 1
                    ret     nz
                    ld      a,(special_count)
                    cp      SPECIAL_WANTED
                    ret     nc
                    ld      hl,sun_x
                    inc     (hl)
                    ld      a,(hl)
                    cp      SUN_SET
                    jp      nz,sun_show

                    ; The light changes, and so should he.
                    ld      (hl),SUN_RISE
                    ld      a,1
                    ld      (player_change),a
                    ld      hl,night
                    ld      a,(hl)
                    xor     PLAYER_WOLF
                    ld      (hl),a
                    jp      nz,sun_show_all     ; nightfall

                    ; Dawn: inc_days, and at forty the end. There is no screen
                    ; for that yet, so it is the same new game losing the last
                    ; life is.
                    ld      hl,days
                    ld      a,(hl)
                    add     a,1                 ; INC leaves the half-carry DAA wants
                    daa
                    ld      (hl),a
                    cp      DAYS_ALLOWED
                    jp      nz,sun_show_all
                    jp      game_over           ; the forty days are up


; Fill a block of attributes -- fill_window, at $C515.
;   A - the attribute, HL -> the top-left cell, B - columns, C - rows
; Corrupts BC, DE, HL.
sun_fill:           ld      de,32
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
