; ---------------------------------------------------------------------------
; Sound, Knight Lore's way: the speaker driven straight from the game loop.
;
; Every effect is a run of cycles, each some number of DJNZs with the speaker
; on and the same number with it off -- toggle_audio_hw at $B4ED. Nothing else
; happens while one plays, so each counts its own time towards the turn, and
; turn_pace waits that much less: in a room with time to spare a sound costs
; nothing, and only a room already over its budget is slowed by one.
;
; The pitches, counts and triggers are the game's, routine by routine, from
; audio_B3E9 to audio_B4C1. Two kinds of trigger, though:
;
; - Events -- a jump, a landing, a death, a pickup -- sound when they happen.
; - The continuous ones -- footsteps, a block's hum, a fire's crackle, the
;   loose block's chirp -- the game plays on every frame the thing moves, and it
;   ran at about fifteen frames a second where we run at up to thirty-five. So
;   they sound only on a turn that starts a new Knight Lore frame: turn_pace
;   adds up how long each turn took and raises sound_now once every
;   SOUND_FRAME_T of it, whatever the room's own pace. And only one of them
;   a frame, where the game plays them all -- see sound_take.

SOUND_FRAME_T       EQU     230000              ; a quiet frame of Knight Lore's
SOUND_EAR           EQU     $10                 ; the speaker, with the border black

; The effects themselves are in sound_fx.s, down with the castle's data in
; contended memory: they only work out what to play. The loops that play it are
; here, where the ULA never holds the CPU up and a DJNZ is always 13 T.

; Non-zero on a turn that starts a Knight Lore frame -- see turn_pace.
sound_now:          DB      0
sound_clock:        DW      0


; Whether a continuous sound may play: yes once a frame, and to the first
; thing that asks. The game plays every one of them each frame, but four fires
; at six cycles each are half of a turn, and a room full of them ran at half
; speed for it; one a frame keeps the room sounding and the cost to one
; sound's worth. A game with no continuous sounds never names it, and IFUSED
; leaves it out.
; Out: NZ to play, and the frame's sound is taken. Corrupts AF.
                    IFUSED  sound_take
sound_take:         ld      a,(sound_now)
                    or      a
                    ret     z
                    xor     a
                    ld      (sound_now),a
                    inc     a
                    ret
                    ENDIF


; One cycle: B DJNZs with the speaker on and B with it off -- toggle_audio_hw.
;   B - the half-period, 0 for 256
; Preserves BC, DE, HL. Counts itself towards the turn: a DJNZ is 13 T, so a
; cycle is about B * 26 T, which is B / 8 turn units and a little over.
sound_cycle:        ld      a,SOUND_EAR
                    out     ($FE),a
                    ld      a,b
.on:                djnz    .on
                    ld      b,a
                    xor     a
                    out     ($FE),a
                    ld      a,b
.off:               djnz    .off
                    ld      b,a
                    rrca
                    rrca
                    rrca
                    and     $1F
                    inc     a
                    jp      turn_add


; C cycles at B -- toggle_audio_hw_xC. C = 0 is 256.
; Preserves B, DE, HL. Leaves C = 0.
sound_tone:         call    sound_cycle
                    dec     c
                    jr      nz,sound_tone
                    ret

; ---------------------------------------------------------------------------
; A tune's note, which is too long for sound_cycle: that counts a half-period
; in one DJNZ run, and a low note wants more. B DJNZs and then C - 1 runs of
; 256, off first and then on, as both games' originals have it.
;
; It does not count itself towards the turn: a tune stops the game while it
; plays, and the turn it stopped is not one to pace. engine/tune.s works out
; what to play; this and sound_rest are here because a DJNZ has to be 13 T,
; which it only is in uncontended memory.
;   B, C - the half-period; B = 0 is 256
;   HL   - how many cycles
; Corrupts AF, HL.
                    IFUSED  sound_long
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
                    ENDIF


; A tune's rest: one wait of $430B counts, which is Pentagram's $D70A.
; Corrupts AF.
                    IFUSED  sound_rest
sound_rest:         push    bc
                    ld      bc,$430B
.count:             dec     bc
                    ld      a,b
                    or      c
                    jr      nz,.count
                    pop     bc
                    ret
                    ENDIF

