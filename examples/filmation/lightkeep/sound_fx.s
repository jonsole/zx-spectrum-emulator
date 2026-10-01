; ---------------------------------------------------------------------------
; The sound effects -- see sound.s. Out of the hot code, in contended memory:
; each only works out a pitch and a count and hands them to sound_tone, which
; is up in the fast memory where the timing has to be.

; The continuous ones ask sound_take, in engine/sound.s, whether this is their
; turn: one of them a frame, where the game plays them all.

; A pitch from where something is, six cycles of it: higher the further along or
; up it is -- audio_B454 and the three that feed it. Continuous.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF
sound_z:            ld      a,(ix+OBJ.Z)        ; audio_B451: falling things
                    jr      sound_pitch

; See sound_z.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF
sound_u:            ld      a,(ix+OBJ.U)        ; audio_B45D: along U
                    jr      sound_pitch

; A sliding block's hum, along whichever axis it slides -- engine/movers.s's
; mover_slide calls it with L the offset of that axis's position in the
; record. upd_54 plays sound_u and upd_55 sound_v, both every frame.
;
; In:  IX -> the record
;      L  = OBJ.U or OBJ.V
; Out: nothing
; Corrupts: AF, BC
slide_sound:        ld      a,l
                    cp      OBJ.U
                    jr      z,sound_u
                    jr      sound_v

; A fire's hum, along whichever axis it paces -- engine/movers.s's mover_pacer
; calls it with L the axis's collide bit. upd_86_87 plays sound_u, and
; upd_180_181 sound_v.
;
; In:  IX -> the record
;      L  = COLLIDE_U or COLLIDE_V
; Out: nothing
; Corrupts: AF
fire_sound:         bit     1,l                 ; COLLIDE_V
                    jr      z,sound_u
                    ASSERT  COLLIDE_V == 2
                    ;; NB: fall through into sound_v

; See sound_z.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF
sound_v:            ld      a,(ix+OBJ.V)        ; audio_B462: along V
                    jr      sound_pitch

; See sound_z.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF
sound_uvz:          ld      a,(ix+OBJ.U)        ; audio_B467: ghosts, gates, things shoved
                    add     a,(ix+OBJ.V)
                    add     a,(ix+OBJ.Z)
                    ;; NB: fall through into sound_pitch

; What the four above come to: six cycles pitched by the position in A.
;
; In:  A = the position
; Out: nothing
; Corrupts: AF
sound_pitch:        push    bc
                    ld      b,a
                    call    sound_take
                    jr      z,.quiet
                    ld      a,b
                    cpl
                    rlca
                    rlca
                    ld      b,a
                    ld      c,6
                    call    sound_tone
.quiet:             pop     bc
                    ret


; The loose block's chirp, four cycles at a pitch picked by the turn --
; audio_B3E9. Continuous.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sound_chirp:        call    sound_take
                    ret     z
                    ld      a,(move_tick)
                    and     7
                    ld      e,a
                    ld      d,0
                    ld      hl,sound_chirps
                    add     hl,de
                    ld      b,(hl)
                    ld      c,4
                    jp      sound_tone

sound_chirps:       DB      $A0, $B0, $C0, $90, $A0, $E0, $80, $60


; A footstep -- audio_B4C1. As many cycles as the walker is far along U and back
; along V, and pitched at B, or by the walker's height on turns with bit 1 of A
; set. Continuous.
;
; In:  A  = the turn's bits: the knight's count, a guard's the other way up
;      B  = the pitch: $60 for the knight, $80 for a guard or the wizard
;      IX -> the legs
; Out: nothing
; Corrupts: AF, BC
sound_step:         ld      c,a
                    call    sound_take
                    ret     z
                    bit     1,c
                    jr      z,.pitched
                    ld      a,(ix+OBJ.Z)
                    cpl
                    srl     a
                    ld      b,a
.pitched:           ld      a,(ix+OBJ.U)
                    srl     a
                    ld      c,a
                    ld      a,(ix+OBJ.V)
                    neg
                    srl     a
                    add     a,c
                    rrca
                    rrca
                    rrca
                    rrca
                    and     $0F
                    ld      c,a
                    jp      sound_tone


; Noise: a run of bytes out of the ROM, each a pitch for C cycles.
;
; In:  HL -> the bytes
;      E  = how many, 0 for 256
;      C  = cycles each
;      D  = a mask
; Out: HL -> past the bytes
;      E  = 0
; Corrupts: AF, B
sound_noise:        ld      a,(hl)
                    inc     hl
                    and     d
                    ld      b,a
                    push    bc
                    call    sound_tone
                    pop     bc
                    dec     e
                    jr      nz,sound_noise
                    ret

; A sparkle -- audio_B403: fewer bytes the further on the graphic is, out of
; the ROM at $1234. The knight dying, a block crumbling, the wizard pleased.
;
; In:  A = the graphic
; Out: nothing
; Corrupts: AF, BC, DE, HL
sound_sparkle:      cpl
                    and     $1F
                    ld      e,a
                    ld      hl,$1234
                    ld      bc,$FF02
                    ld      d,b
                    jr      sound_noise

; Something paced has turned round -- engine/movers.s's mover_turn_if_hit
; calls it with A the axis's bit. A fire turning on V bounces off what stopped
; it, as upd_180_181 has it; nothing else here turns on V. Fires jammed
; against each other turn every turn, so it is a continuous sound here.
;
; In:  A  = the axis's bit
;      IX -> the record
; Out: nothing
; Corrupts: AF, BC, DE, HL
fire_turned:        cp      COLLIDE_V
                    ret     nz
                    call    sound_take
                    ret     z
                    ;; NB: fall through into sound_bounce

; His bolt going off -- Pentagram's $D65B: a falling sweep of thirty-two
; cycles.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC
sound_fire:         ld      c,32
.cycle:             ld      b,c
                    call    sound_cycle
                    dec     c
                    jr      nz,.cycle
                    ret

; A puff's crackle -- Pentagram's $D64E: four cycles, pitched by four bytes of
; the ROM in a row from somewhere random in its first 8K.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, B, E, HL
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

; A bounce -- audio_B42E: four bytes from the very start of the ROM, which
; are DI, XOR A and LD DE,$FFFF, with the top two bits set.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sound_bounce:       ld      hl,sound_bounces
                    ld      de,$FF04
                    ld      c,3
                    jr      sound_noise

sound_bounces:      DB      $F3 | $C0, $AF | $C0, $11 | $C0, $FF | $C0

; A portcullis coming down -- audio_B489: sixteen bytes from somewhere in the
; first 8K of the ROM, picked by the seed and the turn, below $80.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
sound_gate:         ld      a,(move_tick)
                    and     $1F
                    ld      h,a
                    ld      a,(mover_seed)
                    ld      l,a
                    ld      de,$7F10
                    ld      c,2
                    jr      sound_noise


; A pickup, a drop, a life, or a change on the menu -- toggle_audio_hw_x16:
; sixteen cycles at $80.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC
sound_pickup:       ld      bc,$8010
                    jp      sound_tone


; A jump -- audio_B441: one cycle each for C from 32 down to 1, pitched at C
; turned three bits left.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC
sound_jump:         ld      c,$20
.cycle:             ld      a,c
                    rlca
                    rlca
                    rlca
                    ld      b,a
                    call    sound_cycle
                    dec     c
                    jr      nz,.cycle
                    ret


; The knight coming back -- audio_B419: a falling run as long as the sparkle
; is late, each C turned two bits left.
;
; In:  A = the graphic
; Out: nothing
; Corrupts: AF, BC
sound_appear:       rlca
                    rlca
                    and     $1F
                    or      3
                    ld      c,a
.cycle:             ld      a,c
                    rlca
                    rlca
                    ld      b,a
                    call    sound_cycle
                    dec     c
                    jr      nz,.cycle
                    ret


; The knight changing -- audio_B472.
;
; In:  A = the graphic
; Out: nothing
; Corrupts: AF, BC
sound_change:       rlca
                    rlca
                    rlca
                    and     $18
                    add     a,$10
                    ld      c,a
.cycle:             ld      a,c
                    xor     $55
                    add     a,c
                    ld      b,a
                    call    sound_cycle
                    dec     c
                    jr      nz,.cycle
                    ret
