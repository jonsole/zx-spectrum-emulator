; ---------------------------------------------------------------------------
; The space bar pauses -- $B4E0, which the original calls every turn from its
; main loop. SPACE on its own in its half-row, not with SYMBOL SHIFT, M, N or
; B, which turn him: a click, then the game waits for SPACE to be let go,
; pressed and let go again, and clicks again.
;
; The original turns interrupts on while it waits; the remake keeps them off,
; as it always does, and reads the key straight from the port.
;
; Here past the pixel adjustments' index, where there was room.
; ---------------------------------------------------------------------------

; A pause, if SPACE and only SPACE is down.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, HL
game_pause:         ld      a,$7F               ; SPACE, SYMBOL SHIFT, M, N, B
                    in      a,($FE)
                    cpl
                    and     $1F
                    dec     a                   ; SPACE, and only SPACE
                    ret     nz
                    call    sound_click
                    ld      b,3                 ; up, down, up: SPACE's bit
.edge:              ld      a,$7F               ; wanted is bit 0 of B
                    in      a,($FE)
                    xor     b
                    rra
                    jr      c,.edge
                    djnz    .edge
                    jp      sound_click
