; ---------------------------------------------------------------------------
; The sound effects -- see sound.s. Out of the hot code, in contended memory:
; each only works out a pitch and a count and hands them to sound_tone, which
; is up in the fast memory where the timing has to be.


; Whether a continuous sound may play: yes once a Knight Lore frame, and to
; the first thing that asks. The game plays every one of them each frame, but
; four fires at six cycles each are half of a turn, and a room full of them ran
; at half speed for it; one a frame keeps the room sounding and the cost to one
; sound's worth.
; Out: NZ to play, and the frame's sound is taken. Corrupts AF.
sound_take:         ld      a,(sound_now)
                    or      a
                    ret     z
                    xor     a
                    ld      (sound_now),a
                    inc     a
                    ret

; A pitch from where something is, six cycles of it: higher the further along or
; up it is -- audio_B454 and the three that feed it. Continuous.
;   IX -> the record
; Preserves BC, DE, HL.
sound_z:            ld      a,(ix+OBJ.Z)        ; audio_B451: falling things
                    jr      sound_pitch
sound_u:            ld      a,(ix+OBJ.U)        ; audio_B45D: along U
                    jr      sound_pitch
sound_v:            ld      a,(ix+OBJ.V)        ; audio_B462: along V
                    jr      sound_pitch
sound_uvz:          ld      a,(ix+OBJ.U)        ; audio_B467: ghosts, gates, things shoved
                    add     a,(ix+OBJ.V)
                    add     a,(ix+OBJ.Z)
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
;   A  - the turn's bits: the knight's count, a guard's the other way up
;   B  - the pitch: $60 for the knight, $80 for a guard or the wizard
;   IX -> the legs
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
;   HL -> the bytes, E - how many (0 for 256), C - cycles each, D - a mask
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
;   A - the graphic
sound_sparkle:      cpl
                    and     $1F
                    ld      e,a
                    ld      hl,$1234
                    ld      bc,$FF02
                    ld      d,b
                    jr      sound_noise

; A bounce -- audio_B42E: four bytes from the very start of the ROM, which
; are DI, XOR A and LD DE,$FFFF, with the top two bits set.
sound_bounce:       ld      hl,sound_bounces
                    ld      de,$FF04
                    ld      c,3
                    jr      sound_noise

sound_bounces:      DB      $F3 | $C0, $AF | $C0, $11 | $C0, $FF | $C0

; A portcullis coming down -- audio_B489: sixteen bytes from somewhere in the
; first 8K of the ROM, picked by the seed and the turn, below $80.
sound_gate:         ld      a,(move_tick)
                    and     $1F
                    ld      h,a
                    ld      a,(mover_seed)
                    ld      l,a
                    ld      de,$7F10
                    ld      c,2
                    jr      sound_noise


; A pickup, a drop or a life -- toggle_audio_hw_x16: sixteen cycles at $80.
sound_pickup:       ld      bc,$8010
                    jp      sound_tone


; A jump -- audio_B441: one cycle each for C from 32 down to 1, pitched at C
; turned three bits left.
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
;   A - the graphic
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
;   A - the graphic
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
