; ---------------------------------------------------------------------------
; What Pentagram gives engine/tune.s, and the four tunes that go through it --
; $D6B5; sound_fx.s says where each plays. The notes themselves are
; sound_data.s's, generated from the original.
;
; Only the title's stops for a key, as $D69C's does, and it is in
; sound_title.s with its own notes; the rest play out, as $D6B5's do.
;
; The code is here in the room builder's page, as the rest of the sound is:
; all of it is contended memory, which is fine for working out what to play.
; Only the loops that play it have to be where the ULA leaves the CPU alone,
; and those are sound_cycle, sound_long and sound_rest in ../engine/sound.s.
; ---------------------------------------------------------------------------

; A game starting -- $AFBC.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sound_tune_start:   ld      de,sound_tune_start_data
                    jp      tune_play_all
; The water reaching a quest item -- $D0F1.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sound_tune_water:   ld      de,sound_tune_water_data
                    jp      tune_play_all
; The game over -- $C34A.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sound_tune_over:    ld      de,sound_tune_over_data
                    jp      tune_play_all
; The quest won -- $C320.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sound_tune_win:     ld      de,sound_tune_win_data
                    jp      tune_play_all


; A note's pitch and length -- $D6C0's table, three bytes a note from note 1:
; the DJNZs, then the 256s plus one, then the cycles in one length of it.
;
; In:  A = the note, 1 to 63
; Out: carry set
;      B, C = the half-period
;      E    = the cycles in one length
; Corrupts: D, HL
tune_note_at:       ld      e,a
                    ld      d,0
                    ld      hl,sound_notes - 3
                    add     hl,de
                    add     hl,de
                    add     hl,de
                    ld      b,(hl)
                    inc     hl
                    ld      c,(hl)
                    inc     hl
                    ld      e,(hl)
                    scf                         ; every note has an entry
                    ret

