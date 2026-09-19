; ---------------------------------------------------------------------------
; Sabreman on the game-over screen, standing and facing out, in white -- the
; remake's own; the original's screen has only the words. His two halves are
; graphics 36 and 44, the standing frame of the block that walks towards the
; viewer, unmirrored: facing 3. The body sits nine rows higher than the legs,
; as the game draws them, and he is centred under GAME OVER.
;
; Here past the pixel adjustments' index, where there was room; gameover.s
; only calls it.
; ---------------------------------------------------------------------------

GAME_OVER_SAB_X     EQU     112                 ; three bytes across, from 14
GAME_OVER_SAB_FEET  EQU     160                 ; the row below his feet
GAME_OVER_SAB_INK   EQU     $47                 ; bright white

game_over_sab_pieces:
                    DB      36, GAME_OVER_SAB_X, GAME_OVER_SAB_FEET, 0      ; legs
                    DB      44, GAME_OVER_SAB_X, GAME_OVER_SAB_FEET - 9, 0  ; body

; Corrupts everything.
game_over_sabreman: ld      hl,game_over_sab_pieces
                    ld      b,2
                    call    frame_draw
                    ; White, over the five rows of cells from his head (row
                    ; 120) to his feet, three across.
                    ld      hl,$5800 + 15 * 32 + GAME_OVER_SAB_X / 8
                    ld      c,5
.row:               ld      b,3
                    push    hl
.cell:              ld      (hl),GAME_OVER_SAB_INK
                    inc     hl
                    djnz    .cell
                    pop     hl
                    ld      de,32
                    add     hl,de
                    dec     c
                    jr      nz,.row
                    ret
