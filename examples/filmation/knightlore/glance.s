; ---------------------------------------------------------------------------
; The knight's glance, down with the room builder: it is a few instructions a
; turn and nothing here is in a hurry, so it costs only what the ULA takes.

; He looks about him while he goes -- upd_player_top. One turn in 128 he turns
; his head one way, one in 128 the other, and holds it for eight turns; the
; rest of the time his top half follows his legs.
;
; The two frames he looks with are the last of each block of eight, which the
; six-frame walk never reaches. character_frame works his body out as its base
; plus the block plus the phase through a mask, so the glance is that base
; moved on to the glance frame with the mask taken away -- and his legs walk
; on underneath it, as they do in the game.
;   IX -> the player's legs
PLAYER_GLANCE_TURNS EQU     8
PLAYER_GLANCE_GFX   EQU     6                   ; and 7, the other way

player_glance_left: DB      0                   ; turns of it still to go
player_glance_gfx:  DB      0                   ; and which way he is looking

player_glance:      ld      hl,player_glance_left
                    ld      a,(hl)
                    or      a
                    jr      z,.roll
                    dec     (hl)
                    ret

.roll:              call    mover_rand
                    cp      2
                    ld      a,PLAYER_GLANCE_GFX
                    jr      c,.look
                    ld      a,(mover_seed)      ; the same throw, read again
                    cp      $FE
                    ret     c
                    ld      a,PLAYER_GLANCE_GFX + 1
.look:              ld      (player_glance_gfx),a
                    ld      a,PLAYER_GLANCE_TURNS
                    ld      (player_glance_left),a
                    ret


; The body frame character_frame has worked out, or the glance instead. Every
; character comes through here and only the knight is ever changed: the others
; are in the room's pool, a long way below him.
;   A - the block plus the phase, IX -> the legs
; Out: A - the frame to show. Corrupts C.
player_glance_body: ld      c,a
                    ld      a,ixh
                    cp      high player
                    ld      a,c
                    ret     nz
                    ld      a,(player_glance_left)
                    or      a
                    ld      a,c
                    ret     z
                    ld      a,(ix+CHARACTER_FACING)     ; his block again, and the
                    and     2                           ; glance frame in it
                    add     a
                    add     a
                    ld      c,a
                    ld      a,(player_glance_gfx)
                    add     a,c
                    ret
