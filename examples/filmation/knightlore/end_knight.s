; ---------------------------------------------------------------------------
; The knight on the game-over screen, standing and facing out under the words
; -- the remake's own, as Sabreman is on Pentagram's; the original's screen
; has only the words. His two halves are graphics 24 and 40, the standing
; frame of the block that walks towards the viewer, unmirrored: facing 2. The
; body's bottom is eight rows above the legs', as the game draws them, and his
; feet are on the screen's last row, centred as its lines are.
;
; He is white because end_show lays END_KNIGHT_INK under the whole screen
; before the lines put their own colours over their characters.
;
; Two halves in two places, each where there was room: the legs here in the
; pool's page, the body with the castle's data. game_over calls end_knight
; where it called end_rating, and the body goes on to it.
; ---------------------------------------------------------------------------

END_KNIGHT_INK      EQU     $47                 ; bright white on black
END_KNIGHT_X        EQU     112                 ; three bytes across, from 14
END_KNIGHT_FEET     EQU     192                 ; the row below his feet

; Corrupts everything.
end_knight:         ld      a,24                ; legs
                    ld      c,END_KNIGHT_X
                    ld      de,END_KNIGHT_FEET
                    call    screen_sprite
                    jp      end_knight_body
