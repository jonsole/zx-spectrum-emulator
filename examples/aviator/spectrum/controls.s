; The controls, after model/controls.py: the key logger, and the stick,
; rudder and throttle moved by the keys (UpdateFlightModel parts 1 to 3).

KEY_PAIRS       equ 6
HELD_FOR        equ 6           ; iterations before an axis key moves at full rate
FULL_RATE_EXTRA equ 3
AXIS_MIN        equ 140         ; -116
AXIS_MAX        equ 118
THROTTLE        equ 3           ; the throttle's key pair
THRUST_MAX_HI   equ 5           ; thrust saturates at (5 0) = 1,280
FIRE_BUTTON     equ 8           ; the key logger's value for fire
KEY_7           equ $DB         ; the volume keys' BBC codes
KEY_8           equ $EA

; The key logger: for each key pair, the value from the key tables for
; whichever key is down, the first winning (UpdateKeyLogger).
update_key_logger:
    ld b,KEY_PAIRS
.pair:
    ld e,b
    dec e
    ld d,0                      ; DE = the pair, 5 to 0
    ld hl,keyTable1
    add hl,de
    ld a,(hl)
    push de
    call key_pressed
    pop de
    jr nc,.second
    ld hl,keyTable1Lo
    add hl,de
    ld c,(hl)
    ld hl,keyTable1Hi
    add hl,de
    ld a,(hl)
    jr .log
.second:
    ld hl,keyTable2
    add hl,de
    ld a,(hl)
    push de
    call key_pressed
    pop de
    ld c,0
    ld a,0
    jr nc,.log
    ld hl,keyTable2Lo
    add hl,de
    ld c,(hl)
    ld hl,keyTable2Hi
    add hl,de
    ld a,(hl)
.log:
    ld hl,keyLoggerHi
    add hl,de
    ld (hl),a
    ld hl,keyLoggerLo
    add hl,de
    ld (hl),c
    djnz .pair
    ret

; UpdateFlightModel part 1: the elevator, rudder and ailerons, a step a
; press, four once held for six iterations, within -116 to +118.
move_axes:
    MACRO MOVE_AXIS axis
    ld a,(keyLoggerLo + axis)
    or a
    jr nz,.pressed
    ld a,HELD_FOR
    ld (axisChangeRate + axis),a
    jr .done
.pressed:
    ld b,a
    ld hl,axisKeyUsage + axis
    add a,(hl)
    ld (hl),a                   ; the carry: whether the usage wrapped
    ld a,(keyLoggerHi + axis)
    ld c,a                      ; the direction
    ld hl,elevatorPosition + axis
    adc a,(hl)                  ; direction + position + carry
    ld b,a
    ld a,(axisChangeRate + axis)
    or a
    jr z,.rate
    dec a
    ld (axisChangeRate + axis),a
.rate:
    ld a,(axisChangeRate + axis)
    or a
    ld a,b
    jr nz,.limit
    add a,FULL_RATE_EXTRA       ; held long enough
    bit 7,c
    jr z,.limit
    adc a,250                   ; going down: three more less six
.limit:
    bit 7,a
    jr z,.positive
    cp AXIS_MIN
    jr nc,.store
    ld a,AXIS_MIN
    jr .store
.positive:
    cp AXIS_MAX + 1
    jr c,.store
    ld a,AXIS_MAX
.store:
    ld (elevatorPosition + axis),a
.done:
    ENDM
    MOVE_AXIS 2
    MOVE_AXIS 1
    MOVE_AXIS 0
    ret

; With the joystick switched on, the stick sets the elevator and ailerons
; directly and its button fires (ReadJoystick). The Spectrum has no
; analogue joystick: its readings are the BBC's centred ones, and nothing
; switches it on.
read_joystick:
    ld a,(joystick_switch)
    or a
    ret z
    ld a,JOYSTICK_CENTRE
    call adc_position
    ld (aileronPosition),a
    ld a,JOYSTICK_CENTRE
    call adc_position
    ld (elevatorPosition),a
    ret

JOYSTICK_CENTRE equ $7F         ; the high byte of a centred reading, $7FF0

; A = the position an ADC reading's high byte A gives: clipped to 12-246
; and taken from 128 the other way round (ReadADCChannel).
adc_position:
    cp 247
    jr c,.not_high
    ld a,246
.not_high:
    cp 12
    jr nc,.not_low
    ld a,12
.not_low:
    sub 128
    neg
    ret

; UpdateFlightModel part 2: the throttle, from 0 to 1,280. Carry set if it
; moved, as the thrust indicator then needs redrawing.
move_throttle:
    ld a,(keyLoggerLo + THROTTLE)
    or a
    ret z                       ; (carry clear)
    ld hl,thrustLo
    add a,(hl)
    ld c,a
    ld a,(keyLoggerHi + THROTTLE)
    ld hl,thrustHi
    adc a,(hl)
    ld b,a
    bit 7,a
    jr z,.not_negative
    ld bc,0
    jr .set
.not_negative:
    cp THRUST_MAX_HI
    jr c,.set
    ld bc,THRUST_MAX_HI << 8
.set:
    ld a,c
    ld (thrustLo),a
    ld a,b
    ld (thrustHi),a
    scf
    ret

; 7 makes the sounds quieter and 8 louder (ProcessVolumeKeys): the
; amplitude in sound 1's block, from -1 to -15, and a nudge to a byte of the
; engine sound's.
process_volume_keys:
    ld a,KEY_7
    call key_pressed
    ld b,1
    jr c,.step
    ld a,KEY_8
    call key_pressed
    ret nc
    ld b,$FF
.step:
    ld a,(soundData + 10)
    add a,b
    bit 7,a
    ret z
    cp 241
    ret c
    ld (soundData + 10),a
    ld hl,soundData + 60
    inc (hl)
    ret
