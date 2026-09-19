; ---------------------------------------------------------------------------
; Pentagram's sounds, routine by routine from $D5D7 to $D718.
;
; All of them are the beeper driven straight from the game, as Knight Lore's
; are: nothing else happens while one plays. Most go through engine/sound.s,
; whose cycles count themselves towards the turn, so a sound slows only a room
; that was already over its budget. What each is, and what sets it off:
;
;   sound_jump    $D5E4, from $C588 as a jump starts -- the engine calls it
;   sound_step    $D635, from $C5AE on each step of the walk
;   sound_fire    $D629, from $C1B5 as a bolt leaves his hand
;   sound_poof    $D64E, from $C114 on every turn of a poof
;   sound_jingle  $D5F2, from $B084 every turn: a note of whichever jingle is
;                 playing, one a turn -- the four notes $B07E starts when he
;                 comes into a room, or the five $C007 starts whenever the
;                 take key goes down, whether or not there is anything to take
;   sound_tune    $D6B5: a whole tune, the game stopped while it plays -- at
;                 the start of a game ($AFBC), when the water reaches a quest
;                 item ($D0F1), at the game over ($C34A) and the win ($C320)
;
; The original makes no sound as he falls, so sound_z, which the engine calls
; for that, is a plain RET. Its space bar pauses the game with a click in and
; out ($B4E0, $D5D7), and its title screen plays a tune once ($BB91): the
; remake has neither yet.
;
; The code is here in the room builder's page, but for sound_tune, which is
; in sound_tune.s beside the notes and tunes of sound_data.s: the page had no
; room for it. All of that is contended memory, which is fine for working out
; what to play. Only the loops that play it, or time it, have to be where the ULA
; leaves the CPU alone: sound_cycle in engine/sound.s, and sound_long.s for the
; tunes' notes, which are longer than sound_cycle can count, and their rests.
; ---------------------------------------------------------------------------

sound_z:            ret

; A jump -- $D5E4: one cycle each for C from 16 down to 1, pitched at C
; exclusive-or $A5, plus C.
; Corrupts AF, BC.
sound_jump:         ld      c,16
.cycle:             ld      a,c
                    xor     $A5
                    add     a,c
                    ld      b,a
                    call    sound_cycle
                    dec     c
                    jr      nz,.cycle
                    ret

; A step -- $D635: every fourth, two cycles, at $60 and $40 by turns.
; Corrupts AF, BC, HL.
sound_step:         ld      hl,sound_steps
                    inc     (hl)
                    ld      a,(hl)
                    ld      b,$60
                    bit     2,a
                    jr      z,.pitched
                    ld      b,$40
.pitched:           and     3
                    ret     nz
                    ld      c,2
                    jp      sound_tone

sound_steps:        DB      0

; A bolt away -- $D629: a cycle each for C from 32 down to 1, pitched at C.
; ($D629 pitches at C less B, and B is always 0 there: the LDIR at $C150 has
; just run it out.)
; Corrupts AF, BC.
sound_fire:         ld      c,32
.cycle:             ld      b,c
                    call    sound_cycle
                    dec     c
                    jr      nz,.cycle
                    ret

; A poof's crackle -- $D64E: four cycles, pitched by four bytes of the ROM in
; a row from somewhere random in its first 8K.
; Corrupts AF, BC, E, HL.
sound_poof:         call    mover_rand
                    ld      e,a
                    call    mover_rand
                    and     $1F
                    ld      h,a
                    ld      l,e
                    ld      e,4
.cycle:             ld      a,(hl)
                    inc     hl
                    and     $7F
                    ld      b,a
                    call    sound_cycle
                    dec     e
                    jr      nz,.cycle
                    ret


; ---------------------------------------------------------------------------
; The jingles -- $D5F2. A jingle is a count and a place in sound_jingles: each
; turn, while the count lasts, the note that many past the place plays for
; twelve cycles, and the count goes down one. So a jingle plays backwards
; from its end, a note a turn.
; Corrupts AF, BC, DE, HL.
sound_jingle:       ld      hl,sound_jingle_left
                    ld      a,(hl)
                    or      a
                    ret     z
                    dec     (hl)
                    ld      e,a
                    ld      d,0
                    ld      hl,(sound_jingle_at)
                    add     hl,de
                    ld      b,(hl)
                    ld      c,12
                    jp      sound_tone

; He comes into a room -- $B07E: four notes.
; Corrupts AF, HL.
sound_jingle_room:  ld      hl,sound_jingles
                    ld      a,4
                    jr      sound_jingle_start

; The take key goes down -- $C007: five notes, from four on.
; Corrupts AF, HL.
sound_jingle_take:  ld      hl,sound_jingles + 4
                    ld      a,5
sound_jingle_start: ld      (sound_jingle_at),hl
                    ld      (sound_jingle_left),a
                    ret

sound_jingle_left:  DB      0
sound_jingle_at:    DW      sound_jingles
