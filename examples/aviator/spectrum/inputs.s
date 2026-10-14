; What the game reads from outside its memory, after model/hardware.py: the
; keys, the clock, the random timer and the joystick.
;
; The original asks the BBC's OS about one key at a time, by its BBC key
; code; here every key the game uses is read once a pass of the main loop
; (scan_keys) into KEYS_DOWN, a page with a byte for each BBC code, which
; key_pressed looks up. The Spectrum's keys stand in for the BBC's ones by
; key_map: the same letters where the Spectrum has them, SYMBOL SHIFT for <
; (below L, as < is on the BBC), ENTER for + (right of L) and for RETURN,
; SPACE for SHIFT (fire), X for the right arrow, and an Interface II
; joystick (keys 6 to 0) for the stick and the fire button. The BBC's TAB
; (its analogue joystick on and off) and 7 and 8 (the volume) have no keys:
; there is no analogue joystick, and the beeper has no volume.
;
; With TEST_INPUTS set in input_mode the tests drive the game instead, as
; they drive the Python port: they write KEYS_DOWN themselves, the clock
; goes up 3 centiseconds each time it is read, and the timer gives a fixed
; sequence, (n * 97 + 13) & 255 for the n-th read. With SCRIPTED set
; instead, the keys come from demo_script, a key script like the tests'
; (gen_demo.s, from build.py), a pass of the main loop at a time, and the
; clock and the timer are the real ones: the game flies itself, as it would
; for a player, which is what profiling it wants.

KEYS_DOWN       equ $D000       ; a page: non-zero where BBC key code L is down
LIVE_INPUTS     equ 0
TEST_INPUTS     equ 1           ; input_mode's bits
SCRIPTED        equ 2
CLOCK_STEP      equ 3           ; the tests' centiseconds a clock read
TIMER_STEP      equ 97          ; and the timer sequence's step

    ASSERT low KEYS_DOWN == 0

; Carry set if BBC key code A is down. Uses A, HL.
key_pressed:
    ld l,a
    ld h,high KEYS_DOWN
    ld a,(hl)
    add a,$FF                   ; carry set if it was non-zero
    ret

; Read the keyboard and the Interface II into KEYS_DOWN (or, under test,
; leave it as the tests wrote it). Uses A, BC, DE, HL.
scan_keys:
    ld a,(input_mode)
    and TEST_INPUTS
    ret nz
    ; Every BBC code a key stands for is up, to start with...
    ld hl,key_map
    ld d,high KEYS_DOWN
.clear:
    ld a,(hl)
    or a
    jr z,.scan
    inc hl
    inc hl
    ld e,(hl)
    inc hl
    xor a
    ld (de),a
    jr .clear
    ; ...then down for each key that is.
.scan:
    ld a,(input_mode)
    and SCRIPTED
    jr nz,scan_script
    ld hl,key_map
.key:
    ld b,(hl)                   ; the half-row's port, high byte
    inc b
    dec b
    ret z
    inc hl
    ld c,$FE
    in a,(c)
    and (hl)                    ; the key's bit, 0 when down
    inc hl
    ld e,(hl)
    inc hl
    jr nz,.key
    ld a,1
    ld (de),a
    jr .key

; The keys down this pass of the main loop by demo_script: (first pass,
; pass after the last, BBC code), 16-bit, 16-bit and 8-bit, ending with a
; code of 0. Uses A, BC, DE, HL.
scan_script:
    ld hl,demo_script
.entry:
    ld e,(hl)
    inc hl
    ld d,(hl)                   ; the first pass
    inc hl
    ld c,(hl)
    inc hl
    ld b,(hl)                   ; the one after the last
    inc hl
    ld a,(hl)                   ; the code
    inc hl
    or a
    jr z,.next_pass
    push hl
    push af
    ld hl,(demo_pass)
    or a
    sbc hl,de
    jr c,.up                    ; not yet
    ld hl,(demo_pass)
    or a
    sbc hl,bc
    jr nc,.up                   ; over
    pop af
    ld l,a
    ld h,high KEYS_DOWN
    ld (hl),1
    pop hl
    jr .entry
.up:
    pop af
    pop hl
    jr .entry
.next_pass:
    ld hl,(demo_pass)
    inc hl
    ld (demo_pass),hl
    ret

demo_pass:  dw 0

; (half-row port, bit, BBC code) for each key, ending with 0.
key_map:
    db $BF, $02, $A9            ; L          elevator: dive
    db $7F, $02, $99            ; SYM SHIFT  <, elevator: climb
    db $FD, $01, $BE            ; A          rudder left
    db $BF, $01, $A8            ; ENTER      +, rudder right
    db $BF, $01, $B6            ; ENTER      RETURN, a new game
    db $FD, $02, $AE            ; S          ailerons: bank left
    db $FD, $04, $CD            ; D          ailerons: bank right
    db $FB, $02, $DE            ; W          throttle down
    db $FB, $04, $DD            ; E          throttle up
    db $DF, $08, $CA            ; U          undercarriage
    db $7F, $10, $9B            ; B          brakes
    db $FD, $08, $BC            ; F          flaps
    db $7F, $01, $FF            ; SPACE      SHIFT, fire
    db $FB, $10, $DC            ; T          engine
    db $DF, $01, $C8            ; P          scores
    db $DF, $04, $DA            ; I          gun sights
    db $FE, $04, $86            ; X          right arrow, end the flight on the ground
    db $EF, $10, $AE            ; 6          Interface II left: bank left
    db $EF, $08, $CD            ; 7          right: bank right
    db $EF, $02, $A9            ; 9          up (stick forward): dive
    db $EF, $04, $99            ; 8          down (stick back): climb
    db $EF, $01, $FF            ; 0          fire
    db 0

; A = the low byte of the BBC's centisecond clock: the frame count, at 50
; a second, doubled. Uses nothing else.
read_clock:
    ld a,(input_mode)
    and TEST_INPUTS
    jr nz,.test
    ld a,(frames)
    add a,a
    ret
.test:
    ld a,(test_clock)
    add a,CLOCK_STEP
    ld (test_clock),a
    ret

; A = a random byte, where the original reads the User VIA's timer 1 low
; byte (via_timer_low): here the refresh register and the frame count.
; Uses nothing else.
read_timer:
    ld a,(input_mode)
    and TEST_INPUTS
    jr nz,.test
    ld a,(frames)
    push bc
    ld b,a
    ld a,r
    xor b
    pop bc
    ret
.test:
    ld a,(test_timer)
    add a,TIMER_STEP
    ld (test_timer),a
    ret

input_mode: db LIVE_INPUTS
test_clock: db 0
test_timer: db 13

    INCLUDE "gen_demo.s"
