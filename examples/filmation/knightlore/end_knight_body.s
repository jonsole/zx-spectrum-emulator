; The knight's body on the game-over screen -- see end_knight.s.
; Corrupts everything.
end_knight_body:    ld      a,40
                    ld      c,END_KNIGHT_X
                    ld      de,END_KNIGHT_FEET - 8
                    call    screen_sprite
                    jp      end_rating
