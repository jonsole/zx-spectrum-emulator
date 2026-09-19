; ---------------------------------------------------------------------------
; A tune's note -- $D6E6. Too long for sound_cycle, which counts a half-period
; in one DJNZ run: a low note here is B DJNZs and then C less one runs of 256,
; up to 2,500 of them. Off first, then on, as the original has it.
;
; Here, not with the rest of the sound in the room builder's page, because
; that is contended memory and a DJNZ there is not always 13 T: the notes would
; be out of tune. It does not count itself towards the turn -- a tune stops
; the game while it plays, and the turn it stopped is not one to pace.
;   B, C - the half-period; B = 0 is 256
;   HL   - how many cycles
; Corrupts AF, HL.
sound_long:         push    bc
                    xor     a
                    out     ($FE),a
.off:               djnz    .off
                    dec     c
                    jr      nz,.off
                    pop     bc
                    push    bc
                    ld      a,SOUND_EAR
                    out     ($FE),a
.on:                djnz    .on
                    dec     c
                    jr      nz,.on
                    pop     bc
                    dec     hl
                    ld      a,h
                    or      l
                    jr      nz,sound_long
                    ret

; A tune's rest -- $D70A: one wait of $430B counts.
; Corrupts AF.
sound_rest:         push    bc
                    ld      bc,$430B
.count:             dec     bc
                    ld      a,b
                    or      c
                    jr      nz,.count
                    pop     bc
                    ret
