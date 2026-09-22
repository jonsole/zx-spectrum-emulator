; ---------------------------------------------------------------------------
; Where the monsters' turns go first -- see busy.s. mover_tbl sends every
; behaviour from MOVE_FIRE_U to MOVE_SPIKE_BALL here. In a busy room each
; counts busy_count down, and whichever reaches nought sits the turn out and
; starts the count again from room_busy, its step cleared so that nothing
; riding it moves without it -- a ghost carries things. Everyone else, and
; every monster in a quiet room, goes on to its own mover through
; monster_movers.
;
; At the end of the castle's data, where the trimmed nudge index left room:
; contended memory, a few instructions a monster a turn.
;   IX -> the record
; ---------------------------------------------------------------------------

monster_gate:       ld      a,(room_busy)
                    or      a
                    jr      z,.go
                    ld      hl,busy_count
                    dec     (hl)
                    jr      nz,.go
                    ld      (hl),a              ; the count again
                    jp      mover_halt          ; and it sits this one out
.go:                ld      a,(ix+OBJ.BEHAVIOUR)
                    add     a,a
                    ld      l,a
                    ld      h,0
                    ld      de,monster_movers - MOVE_FIRE_U * 2
                    add     hl,de
                    ld      a,(hl)
                    inc     hl
                    ld      h,(hl)
                    ld      l,a
                    jp      (hl)

; What monster_gate goes on to, MOVE_FIRE_U to MOVE_SPIKE_BALL.
monster_movers:     DW      mover_pacer_u, mover_pacer_v, mover_guard_u
                    DW      mover_guard_sq, mover_ghost, mover_bounce
                    DW      mover_spike_ball
                    ASSERT  ($ - monster_movers) / 2 == MOVE_SPIKE_BALL - MOVE_FIRE_U + 1
