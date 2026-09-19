; ---------------------------------------------------------------------------
; A whole tune -- $D6B5; sound_fx.s says where each plays. A byte a note:
; the note in bits 0-5, from sound_notes, and its length in bits 6-7, one to
; four times the note's own. Note 0 is a rest of that many $430B-long waits.
; $FF ends it. Only the title's stops for a key, as $D69C's does; the rest play
; out, as $D6B5's do. The title's is in sound_title.s.
; Corrupts AF, BC, DE, HL.
sound_tune_start:   ld      de,sound_tune_start_data
                    jr      sound_tune
sound_tune_water:   ld      de,sound_tune_water_data
                    jr      sound_tune
sound_tune_over:    ld      de,sound_tune_over_data
                    jr      sound_tune
sound_tune_win:     ld      de,sound_tune_win_data

sound_tune:         xor     a                   ; plays out
sound_tune_keys:    ld      (.cut + 1),a        ; A = 1: a key stops it
.note:              ld      a,(de)
                    cp      $FF
                    ret     z
.cut:               ld      a,0                 ; patched
                    or      a
                    jr      z,.play
                    xor     a                   ; every half-row
                    in      a,($FE)
                    cpl
                    and     $1F
                    ret     nz
.play:              ld      a,(de)
                    inc     de
                    ld      c,a
                    rlca
                    rlca
                    and     3
                    inc     a
                    ld      b,a                 ; B - how many lengths
                    ld      a,c
                    and     $3F
                    jr      z,.rest

                    push    de
                    ld      e,a
                    ld      d,0
                    ld      hl,sound_notes - 3
                    add     hl,de
                    add     hl,de
                    add     hl,de
                    ld      d,(hl)              ; the DJNZs
                    inc     hl
                    ld      e,(hl)              ; the 256s, plus one
                    inc     hl
                    ld      a,(hl)              ; the cycles in one length
                    push    de
                    ld      e,a
                    ld      d,0
                    ld      hl,0
.length:            add     hl,de
                    djnz    .length
                    pop     bc                  ; B the DJNZs, C the 256s
                    call    sound_long
                    pop     de
                    jr      .note

.rest:              call    sound_rest          ; $D702
                    djnz    .rest
                    jr      .note
