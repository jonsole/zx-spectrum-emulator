; ---------------------------------------------------------------------------
; The day's clock. It is cold -- it does nothing on seven turns in eight -- so it
; lives down here, in what the mirror table's ALIGN would otherwise leave empty.
; (The attribute fill the panel and the sun's window share used to be here too;
; it is at the end of pickup.s now, since the object pool grew by the twelve
; bytes its last record had been missing.)

; The clock's turn. It stops once the wizard has everything, as the game's does.
;
; In:  nothing
; Out: nothing -- except on the fortieth dawn, when it never returns:
;        game_over starts a new game
; Corrupts: AF, BC, DE, HL
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

