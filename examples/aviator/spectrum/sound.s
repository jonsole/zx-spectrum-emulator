; The sound, after model/sound.py: the game asks for sounds by the
; original's numbers (soundData), and the Spectrum plays them on the
; beeper, from the frame interrupt (sound_frame), so the game loses only the
; little time each frame's share of a sound takes.
;
; The BBC's engine is periodic noise, a buzz of about 26 to 109 Hz that
; rises with the throttle and the airspeed; here it is a train of clicks,
; one a frame at most, whose rate follows the original's engine pitch. The
; rest are short bursts each frame while they last, of a tone near the
; original's or of noise:
;
;   0   the engine stops            5   a crash (noise, in its pause)
;   1   the engine's amplitude      6   the guns (noise)
;   2   an alien destroyed          7   the engine's pitch
;   3   points scored, or the wings' strain (a beep)
;   4   the stall warning           26  touching down (a thud of noise)

SPEAKER         equ $10         ; port $FE's speaker bit (the border stays black)
CLICK_LOOPS     equ 20          ; the engine click's length, in DJNZ loops

; Make sound A. Uses nothing. (Under test, the sound is logged instead.)
make_sound:
    push af
    ld a,(input_mode)
    and TEST_INPUTS
    jp nz,log_sound
    pop af
    push af
    push hl
    push de
    cp 2
    jr c,.engine
    cp 7
    jr z,.engine
    ; An effect from the table, unless one is playing that matters more
    ; (a lower number in the table's order).
    ld hl,effects
    ld e,0
.find:
    ld d,(hl)
    inc d
    jr z,.done                  ; not one the Spectrum plays
    dec d
    cp d
    jr z,.found
    inc hl
    inc hl
    inc hl
    inc hl
    inc hl
    inc e
    jr .find
.found:
    ld a,(effect_frames)
    or a
    jr z,.start
    ld a,(effect_rank)
    cp e
    jr c,.done                  ; the one playing matters more
.start:
    ld a,e
    ld (effect_rank),a
    inc hl
    ld a,(hl)
    ld (effect_period),a
    inc hl
    ld a,(hl)
    ld (effect_cycles),a
    inc hl
    ld a,(hl)
    ld (effect_noise),a
    inc hl
    ld a,(hl)
    di                          ; (the interrupt reads them)
    ld (effect_frames),a
    ei
    jr .done
.engine:
    ; 0 stops the engine; 1 and 7 set its rate from its pitch.
    or a
    jr z,.engine_rate
    ld a,(ENGINE_PITCH)
    srl a
    add a,48                    ; 88 to 138 for pitches 80 to 180: 17 to 27 clicks a second
.engine_rate:
    ld (engine_rate),a
.done:
    pop de
    pop hl
    pop af
    ret

; (sound, half period in DJNZ loops, cycles a frame, noise, frames), in
; the order the effects matter, ending with $FF.
effects:
    db 3, 190, 2, 0, 17         ; a beep, near 690 Hz, 0.35 s
    db 2, 46, 8, 0, 5           ; an alien destroyed, near 2.9 kHz
    db 6, 0, 120, 1, 5          ; the guns
    db 26, 0, 200, 1, 3         ; touching down
    db 4, 255, 1, 0, 2          ; the stall warning, as low as a burst allows
    db $FF

effect_rank:    db 0
effect_period:  db 0
effect_cycles:  db 0
effect_noise:   db 0
effect_frames:  db 0
engine_rate:    db 0
engine_phase:   db 0
noise_seed:     dw $ACE1

; A frame's share of the sound, from the frame interrupt: the engine's
; click when its phase passes 256, and a burst of the effect playing.
; Uses A, B, C, D, E, H, L.
sound_frame:
    ld a,(engine_rate)
    or a
    jr z,.effect
    ld hl,engine_phase
    add a,(hl)
    ld (hl),a
    jr nc,.effect
    ld a,SPEAKER
    out ($FE),a
    ld b,CLICK_LOOPS
.click:
    djnz .click
    xor a
    out ($FE),a
.effect:
    ld a,(effect_frames)
    or a
    ret z
    dec a
    ld (effect_frames),a
    ld a,(effect_cycles)
    ld c,a
    ld a,(effect_noise)
    or a
    jr nz,.noise
    ld a,(effect_period)
    ld d,a
    xor a
.tone:
    xor SPEAKER
    out ($FE),a
    ld b,d
.wait:
    djnz .wait
    xor SPEAKER
    out ($FE),a
    ld b,d
.wait2:
    djnz .wait2
    dec c
    jr nz,.tone
    xor a
    out ($FE),a
    ret
.noise:
    ; C steps of a 16-bit shift register, its top bit to the speaker.
    ld hl,(noise_seed)
.step:
    add hl,hl
    jr nc,.bit
    ld a,l
    xor $2D
    ld l,a
.bit:
    ld a,h
    and SPEAKER
    out ($FE),a
    ld b,4
.hold:
    djnz .hold
    dec c
    jr nz,.step
    ld (noise_seed),hl
    xor a
    out ($FE),a
    ret

; Redefine the envelope at envelopeData + A (DefineEnvelope): the engine's
; roughness is in the first, which the beeper's engine doesn't use. Uses
; nothing. (Under test, logged as A + 128.)
define_envelope:
    push af
    ld a,(input_mode)
    and TEST_INPUTS
    jr nz,.log
    pop af
    ret
.log:
    pop af
    push af
    or $80
    jr log_entry

; Add the sound on the stack to sound_log, while there is room.
log_sound:
    pop af
    push af
log_entry:
    push hl
    push de
    ld hl,sound_log_count
    ld e,(hl)
    inc (hl)
    ld d,0
    ld hl,sound_log
    add hl,de
    ld (hl),a
    ld a,e
    cp SOUND_LOG_SIZE - 1
    jr c,.room
    ld hl,sound_log_count
    ld (hl),SOUND_LOG_SIZE - 1
.room:
    pop de
    pop hl
    pop af
    ret

SOUND_LOG_SIZE  equ 16
sound_log_count: db 0
sound_log:      ds SOUND_LOG_SIZE

; The crash's pause, with the canopy lit, before it is cleared: a second,
; the first part of it the crash's noise.
crash_pause:
    ld a,(input_mode)
    and TEST_INPUTS
    ret nz                      ; (the tests don't wait)
    xor a
    ld (engine_rate),a
    ld (effect_frames),a
    ld b,30
.noise:
    push bc
    ld c,250
    ld hl,(noise_seed)
.step:
    add hl,hl
    jr nc,.bit
    ld a,l
    xor $2D
    ld l,a
.bit:
    ld a,h
    and SPEAKER
    out ($FE),a
    ld b,30
.hold:
    djnz .hold
    dec c
    jr nz,.step
    ld (noise_seed),hl
    pop bc
    djnz .noise
    xor a
    out ($FE),a
    ld b,25
.frame:
    halt
    djnz .frame
    ret
