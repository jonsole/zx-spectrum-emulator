; The flight model, after model/flight.py, whose docstrings explain the
; physics: the forces on the plane in its own frame, scaled by the aircraft's
; coefficients, turned back into the world's frame to move and turn it, the
; ground and landing, and the engine and fuel. Each routine gives exactly
; the Python port's results.
;
; The variable workspace (page $8C) keeps each 16-bit variable's low byte at
; xTurnHi + offset and its high byte at xTurnTop + offset, which is how
; ResetVariable and AddScaled name them.

LINEAR_POINT    equ 252         ; the working vectors in the point tables
GRAVITY_POINT   equ 253
TURN_POINT      equ 254
VELOCITY_POINT  equ 255
MATRIX_2        equ 9
MATRIX_3        equ 18
WORK_HI         equ xTurnTop - xTurnHi ; from a workspace variable's low byte to its high

X_TURN          equ 0           ; workspace offsets
Z_TURN          equ zTurnHi - xTurnHi
DX_TURN         equ dxTurnHi - xTurnHi
DZ_TURN         equ dzTurnHi - xTurnHi
Y_VELOCITY      equ yVelocityHi - xTurnHi
X_CONTROLS_SC   equ xControlsScHi - xTurnHi
X_ROTATION      equ xRotationLo - xTurnHi
Z_ROTATION      equ zRotationLo - xTurnHi
Y_PLANE         equ yPlaneLo - xTurnHi

Y_LIFT_DRAG     equ 4           ; indexes into the eleven-force tables
Z_LIFT_DRAG     equ 5
Y_FLAPS_LIFT    equ 7
LIFT_NORMAL     equ 156
LIFT_STALLED    equ 39
LANDING_STOPPED equ $40
ENGINE_PITCH    equ soundData + 7 * 8 + 4
ENGINE_PITCH_RESET equ 255
FUEL_FULL       equ 65
RUNWAY_OBJECT   equ 1
RUNWAY_LENGTH_HI equ 24

SOUND_ENGINE_OFF equ 0          ; the original's sound numbers
SOUND_ENGINE_AMPLITUDE equ 1
SOUND_STRAIN    equ 3
SOUND_STALL     equ 4
SOUND_ENGINE_PITCH equ 7
SOUND_TOUCHDOWN equ 26

ADD_INVERT      equ $80         ; add_scaled's E: invert A first
ADD_SUBTRACT    equ $01         ; take the amount away

    ASSERT low xTurnHi == 0 && WORK_HI == $10

; Zero the workspace variable at offset (ResetVariable).
    MACRO RESET_VARIABLE offset
    xor a
    ld (xTurnHi + offset),a
    ld (xTurnTop + offset),a
    ENDM

; H L = the 16-bit value at lo, hi; and the other way.
    MACRO LD16 lo, hi
    ld a,(lo)
    ld l,a
    ld a,(hi)
    ld h,a
    ENDM

    MACRO ST16 lo, hi
    ld a,l
    ld (lo),a
    ld a,h
    ld (hi),a
    ENDM

; H L = -H L. Uses A.
    MACRO NEG_HL
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    ENDM

; ---- arithmetic ---------------------------------------------------------------

; A H L = H L * A, H L signed and A unsigned, a 24-bit two's complement
; result (Multiply8x16). Uses B, C, D, E.
mul8x16:
    ld e,a
    ld c,h                      ; the sign, in bit 7
    bit 7,h
    jr z,.positive
    NEG_HL
.positive:
    ld a,h
    ld (m816_high),a
    ld a,l
    MUL8                        ; the low byte's product (C and E kept)
    push hl
    ld a,(m816_high)
    MUL8                        ; and the high byte's
    pop de
    ld a,d
    add a,l
    ld d,a
    ld a,h
    adc a,0
    ld h,d
    ld l,e                      ; A H L, the magnitude's product
    bit 7,c
    ret z
    ld b,a
    xor a
    sub l
    ld l,a
    ld a,0
    sbc a,h
    ld h,a
    ld a,0
    sbc a,b
    ret

m816_high:  db 0

; Add (A 0) >> (B + 1) to the workspace variable at offset C, or take it
; away (AddScaled). E: ADD_INVERT to invert A first, ADD_SUBTRACT to take
; it away. Uses A, B, D, E, H, L.
add_scaled:
    bit 7,e
    jr z,.as_is
    cpl
.as_is:
    ld h,a
    ld l,0
    inc b
.shift:
    srl h
    rr l
    djnz .shift
    bit 0,e
    jr z,.add
    NEG_HL
.add:
    ex de,hl
    ld a,c
    add a,WORK_HI
    ld b,a                      ; (found first: an ADD later would lose the carry)
    ld l,c
    ld h,high xTurnHi
    ld a,(hl)
    add a,e
    ld (hl),a
    ld l,b
    ld a,(hl)
    adc a,d
    ld (hl),a
    ret

; Move the randomNumbers pointer on to the next of its eleven entries,
; wrapping round; A = the pointer (NextRandomNumber). Uses nothing else.
next_random_number:
    ld a,(randomNumbers)
    inc a
    cp 11
    jr c,.pointer
    xor a
.pointer:
    ld (randomNumbers),a
    ret

; A = the random number the pointer A points at. Uses DE, HL.
random_entry:
    ld e,a
    ld d,0
    ld hl,randomNumbers + 1
    add hl,de
    ld a,(hl)
    ret

; A H L = H L * (255 - yPlaneHi), H L signed: the air density
; (ScaleByAltitude). Uses B, C, D, E.
scale_by_altitude:
    ld a,(yPlaneHi)
    cpl
    jp mul8x16

; ---- ApplyFlightModel -----------------------------------------------------

; One iteration of the flight model (ApplyFlightModel). A crash raises
; EVENT_CRASH from process_landing.
apply_flight_model:
    ld a,(onGround)
    ld (afm_on_ground),a

    ; Part 1: gravity in the plane's frame, (0, -512, 0) in the world, or
    ; with the undercarriage's springs taking off half a downward
    ; acceleration on the ground.
    ld l,GRAVITY_POINT
    xor a
    call set_point_to
    ld b,$FE
    ld a,(afm_on_ground)
    or a
    jr z,.gravity
    ld a,(ucStatus)
    or a
    jr z,.gravity
    ld a,(dyVelocityHi)
    bit 7,a
    jr z,.gravity
    ld h,a
    ld a,(dyVelocityLo)
    ld l,a
    srl h
    rr l
    set 7,h                     ; half, as the original shifts a negative number
    ld a,l
    cpl
    ld (yGravityLo),a
    ld a,253
    sub h
    ld b,a                      ; -513 - dyVelocity / 2
.gravity:
    ld a,b
    ld (yGravityHi),a
    ld a,MATRIX_4
    ld (matrixNumber),a
    ld c,a
    ld a,GRAVITY_POINT
    call set_point_coords

    ; Part 2: the airflow, and the forces it makes.
    ld a,VELOCITY_POINT
    ld c,xVelocityHi - xTurnHi
    call copy_work_to_point
    xor a
    ld (matrixNumber),a
    ld c,a
    ld a,VELOCITY_POINT
    call set_point_coords
    ld a,VELOCITY_POINT
    ld c,xVelocityPLo - xTurnHi
    call copy_point_to_work
    call apply_aerodynamics
    call apply_flight_control
    call scale_flight_forces

    ; Part 3: turbulence near an exploding alien.
    ld a,(hitTimer)
    or a
    jr z,.part4
    xor a
.turbulence:
    ld (afm_axis),a
    call next_random_number
    call random_entry
    ld (afm_random),a
    ld a,(distanceFromHit)
    cp 16
    jr nc,.part4
    xor $0F
    add a,a                     ; the kick: 30 when close, 0 at 15
    ld b,a
    ld a,(afm_axis)
    add a,X_CONTROLS_SC
    ld c,a
    ld a,(afm_random)
    and ADD_SUBTRACT
    ld e,a
    ld a,b
    ld b,1
    call add_scaled
    ld a,(afm_axis)
    inc a
    cp 3
    jr c,.turbulence

.part4:
    ; Part 4: the accelerations; the slip indicator gets the sideways one,
    ; rounded.
    call apply_turn_and_thrust
    ld a,(xLinearLo)
    xor $80
    rlca
    and 1
    ld b,a
    ld a,(xLinearHi)
    cpl
    add a,b
    ld (slipRate),a

    ; Part 5: on the ground the wheels take over.
    ld a,(afm_on_ground)
    or a
    call nz,apply_ground_forces

    ; Part 6: from accelerations to motion.
    ld a,MATRIX_2
    ld (matrixNumber),a
    ld c,a
    ld a,LINEAR_POINT
    call set_point_coords
    ld a,(yLinearHi)
    sub 16                      ; the plane's weight
    ld (yLinearHi),a
    ld a,LINEAR_POINT
    ld c,dxVelocityLo - xTurnHi
    call copy_point_to_work
    call adjust_velocity
    call adjust_turn
    ld a,TURN_POINT
    ld c,X_TURN
    call copy_work_to_point
    ld a,MATRIX_3
    ld (matrixNumber),a
    ld c,a
    ld a,TURN_POINT
    call set_point_coords
    ld a,TURN_POINT
    ld c,dxRotationLo - xTurnHi
    call copy_point_to_work
    call adjust_rotation
    ld a,7
    call toggle_engine_sound
    call process_landing
    call show_upside_down_bar

    ; Part 7: burn fuel in proportion to the throttle.
    ld a,(fuelLevel)
    or a
    jr z,.engine_off
    ld a,(engineStatus)
    or a
    ret z
    LD16 thrustLo, thrustHi
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld a,(fuelUsedLo)
    add a,l
    ld (fuelUsedLo),a
    ret nc
    ld a,(fuelUsedHi)
    add a,4
    ld (fuelUsedHi),a
    ret nc
    ld a,(fuelLevel)
    or a
    jr z,.engine_off
    dec a
    ld (fuelLevel),a
    ret nz
.engine_off:
    xor a
    jp set_engine

afm_on_ground:  db 0
afm_axis:       db 0
afm_random:     db 0

; ApplyFlightModel part 5: what the ground does to a plane on it.
apply_ground_forces:
    ; Ground steering: yTurn = four times the rudder, if rolling forwards
    ; at 20 or more.
    ld hl,0
    ld a,(zVelocityPHi)
    bit 7,a
    jr nz,.steering
    or a
    jr nz,.steer
    ld a,(zVelocityPLo)
    cp 20
    jr c,.steering
.steer:
    ld a,(rudderPosition)
    ld l,a
    rla
    sbc a,a
    ld h,a
.steering:
    add hl,hl
    add hl,hl
    ST16 yTurnHi, yTurnTop
    RESET_VARIABLE DZ_TURN
    ld (dzTurnLo),a

    ; How much to take off zLinearHi (B), or nothing (free rolling).
    ld a,(ucStatus)
    or a
    jr nz,.wheels
    ld a,(xRotationHi)
    ld b,a
    ld a,(dxTurnTop)
    and b
    rla
    jr nc,.belly
    RESET_VARIABLE DX_TURN       ; nose down and pitching down: the ground stops it
    ld (dxTurnLo),a
.belly:
    call check_plane_on_runway
    ld b,11
    jr nc,.slow
    ld b,50
    jr .slow
.wheels:
    ld a,(brakesStatus)
    or a
    jr z,.rolling
    call check_plane_on_runway
    ld b,11
    jr nc,.slow
    ld b,50
    jr .slow
.rolling:
    ld c,0
    call check_plane_on_runway
    jr nc,.status               ; on the runway, the wheels roll freely
    ld b,7
.slow:
    ld c,0
    ld a,(zVelocityPHi)
    bit 7,a
    jr z,.forwards
    ld a,(zLinearHi)
    sub 248                     ; rolling backwards: pushed forwards hard
    ld (zLinearHi),a
    jr .status
.forwards:
    or a
    jr nz,.moving
    ld a,(zVelocityPLo)
    or a
    jr nz,.crawling
    ld c,LANDING_STOPPED
    jr .status
.crawling:
    cp 11
    jr nc,.moving
    xor a
    ld (zLinearLo),a
    dec a
    ld (zLinearHi),a            ; zLinear = -256
    ld c,LANDING_STOPPED
    jr .status
.moving:
    ld a,(zLinearHi)
    sub b
    ld (zLinearHi),a
.status:
    ld a,c
    ld (landingStatus),a

    ; Sideways friction: xLinear = -xVelocityPLo * 128, the sign from the
    ; high byte.
    xor a
    ld (slipRate),a
    ld a,(xVelocityPLo)
    ld e,a
    rrca
    and $80
    ld l,a
    ld a,e
    srl a
    ld d,a
    ld a,(xVelocityPHi)
    and $80
    or d
    ld h,a
    NEG_HL
    ST16 xLinearLo, xLinearHi
    ret

; xTurn += dxTurn, and likewise y and z, 24-bit (AdjustTurn).
adjust_turn:
    MACRO ADD24 dst_lo, dst_hi, dst_top, src_lo, src_hi, src_top, axis
    ld a,(src_lo + axis)
    ld hl,dst_lo + axis
    add a,(hl)
    ld (hl),a
    ld a,(src_hi + axis)
    ld hl,dst_hi + axis
    adc a,(hl)
    ld (hl),a
    ld a,(src_top + axis)
    ld hl,dst_top + axis
    adc a,(hl)
    ld (hl),a
    ENDM
    ADD24 xTurnLo, xTurnHi, xTurnTop, dxTurnLo, dxTurnHi, dxTurnTop, 2
    ADD24 xTurnLo, xTurnHi, xTurnTop, dxTurnLo, dxTurnHi, dxTurnTop, 1
    ADD24 xTurnLo, xTurnHi, xTurnTop, dxTurnLo, dxTurnHi, dxTurnTop, 0
    ret

; xVelocity (24-bit) += dxVelocity (16-bit, signed) * 2, and likewise y and z
; (AdjustVelocity).
adjust_velocity:
    MACRO ADJUST_VELOCITY axis
    LD16 dxVelocityLo + axis, dxVelocityHi + axis
    ld a,h
    rla
    sbc a,a
    ld c,a                      ; the sign, the top byte
    add hl,hl
    ld a,(xVelocityLo + axis)
    add a,l
    ld (xVelocityLo + axis),a
    ld a,(xVelocityHi + axis)
    adc a,h
    ld (xVelocityHi + axis),a
    ld a,(xVelocityTop + axis)
    adc a,c
    ld (xVelocityTop + axis),a
    ENDM
    ADJUST_VELOCITY 2
    ADJUST_VELOCITY 1
    ADJUST_VELOCITY 0
    ret

; Move the plane by its velocity and turn it by its rates (AdjustRotation):
; the 32-bit position gains the velocity's top two bytes, sign-extended, and
; the angles their rates; a pitch gone past the vertical is reflected back,
; with yaw and roll turned half a circle.
adjust_rotation:
    MACRO ADJUST_POSITION axis
    LD16 xVelocityHi + axis, xVelocityTop + axis
    ld a,h
    rla
    sbc a,a
    ld c,a
    ld a,(xPlaneBot + axis)
    add a,l
    ld (xPlaneBot + axis),a
    ld a,(xPlaneLo + axis)
    adc a,h
    ld (xPlaneLo + axis),a
    ld a,(xPlaneHi + axis)
    adc a,c
    ld (xPlaneHi + axis),a
    ld a,(xPlaneTop + axis)
    adc a,c
    ld (xPlaneTop + axis),a
    ld a,(dxRotationLo + axis)
    ld hl,xRotationLo + axis
    add a,(hl)
    ld (hl),a
    ld a,(dxRotationHi + axis)
    ld hl,xRotationHi + axis
    adc a,(hl)
    ld (hl),a
    ENDM
    ADJUST_POSITION 2
    ADJUST_POSITION 1
    ADJUST_POSITION 0
    ld a,(xRotationHi)
    ld b,a
    add a,a
    xor b
    rla
    ret nc
    ld hl,yRotationHi
    ld a,(hl)
    xor $80
    ld (hl),a
    ld hl,zRotationHi
    ld a,(hl)
    xor $80
    ld (hl),a
    LD16 xRotationLo, xRotationHi
    ex de,hl
    ld hl,$8000
    or a
    sbc hl,de
    ST16 xRotationLo, xRotationHi
    ret

; ---- ApplyAerodynamics ----------------------------------------------------

; Multiply16x16Mix with its fraction byte: A H L = (H L) * (B C) >> 8,
; 24-bit two's complement, H L with its sign in bit 7 and B C in bit 0 of C.
; Uses everything but IX and IY.
mul16_mix_full:
    ld a,c
    rrca
    xor h
    ld (mmf_sign),a             ; bit 7: the result is negative
    bit 7,h
    jr z,.positive
    NEG_HL
.positive:
    ex de,hl                    ; D E = (J I)
    call mul16                  ; H L = the top 16 bits, mul16_w the fraction
    ld a,(mmf_sign)
    rla
    ld a,h
    ld b,a
    ld a,(mul16_w)
    jr c,.negative
    ld c,a
    ld a,b
    ld b,l
    ld l,c
    ld h,b                      ; A H L = H G W
    ret
.negative:
    ; -(H G) as 16 bits, then W taken from it, borrowing.
    ld c,a                      ; W
    NEG_HL
    xor a
    sub c
    ld c,a
    ld a,l
    sbc a,0
    ld b,a
    ld a,h
    sbc a,0
    ld h,b
    ld l,c
    ret

mmf_sign:   db 0

; The forces of the air on the plane (ApplyAerodynamics): lift and drag as
; each component of the airflow times the largest, times the air density;
; the moments; the stall.
apply_aerodynamics:
    ; Part 1: xLiftDrag = xVelocityP * 2, the vertical speed's magnitude * 4,
    ; and maxv, the largest magnitude.
    ld hl,0
    ld (aa_maxv),hl
    MACRO AA_AXIS axis
    LD16 xVelocityPLo + axis, xVelocityPHi + axis
    push hl
    add hl,hl
    ST16 xLiftDragLo + axis, xLiftDragHi + axis
    pop hl
    bit 7,h
    jr z,.magnitude
    NEG_HL
.magnitude:
    IF axis == 1
    push hl
    add hl,hl
    add hl,hl
    ld (aa_vertical),hl
    pop hl
    ENDIF
    ex de,hl
    ld hl,(aa_maxv)
    or a
    sbc hl,de
    jr z,.larger
    jr nc,.smaller
.larger:
    ld (aa_maxv),de
.smaller:
    ENDM
    AA_AXIS 2
    AA_AXIS 1
    AA_AXIS 0
    ld hl,(aa_maxv)
    add hl,hl
    call scale_by_altitude      ; A H L; (S R) is the top two bytes
    ld l,h
    ld h,a
    ld (aa_scale),hl

    ; Part 2: the stall.
    ld a,(forceFactor + Y_LIFT_DRAG)
    cp LIFT_STALLED
    jr nz,.not_already
    ld a,(zVelocityPHi)
    cp 11
    jr c,.stalling              ; still too slow to recover
.not_already:
    LD16 zVelocityPLo, zVelocityPHi
    ex de,hl
    ld hl,(aa_vertical)
    or a
    sbc hl,de
    jr c,.flying                ; vertical < zVelocityP
    ; Stalling: at the moment it starts, high enough, a wing drops.
    ld a,(yPlaneHi)
    or a
    jr nz,.high_enough
    ld a,(yPlaneLo)
    cp 20
    jr c,.stalling
.high_enough:
    ld a,(forceFactor + Y_LIFT_DRAG)
    cp LIFT_STALLED
    jr z,.stalling
    ld a,(xTurnTop)
    xor $3F
    ld e,0
    bit 7,a
    jr z,.no_invert
    ld e,ADD_INVERT
.no_invert:
    ld b,a
    ld a,(yTurnTop)
    rlca
    and ADD_SUBTRACT
    or e
    ld e,a
    ld a,b
    ld b,4
    ld c,Z_TURN
    call add_scaled
.stalling:
    ld a,(afm_on_ground)
    or a
    jr nz,.flying
    ld a,SOUND_STALL
    call make_sound
    ld a,LIFT_STALLED
    jr .lift
.flying:
    ld a,LIFT_NORMAL
.lift:
    ld (forceFactor + Y_LIFT_DRAG),a

    ; Part 3: the moments and the lift and drag, each times maxv and the
    ; air density, truncated rather than rounded.
    call get_moments
    xor a
    ld (mult1_round),a
    ld a,5
.force:
    ld (aa_index),a
    ld e,a
    ld d,0
    ld hl,xMomentsLo
    cp 3
    jr nc,.moment
    ld hl,xTemp3Lo
.moment:
    add hl,de
    ld a,(hl)
    push af
    ld a,l
    add a,WORK_HI
    ld l,a
    ld h,(hl)
    pop af
    ld l,a                      ; H L = the force
    ld bc,(aa_scale)
    res 0,c                     ; positive, with its sign in bit 0
    call mul16_mix_full         ; A H L
    ld b,a
    ld a,(aa_index)
    cp 3
    jr z,.times8
    cp 4
    jr z,.times8
    add hl,hl
    rl b
    jr .shifted
.times8:
    add hl,hl
    rl b
    add hl,hl
    rl b
    add hl,hl
    rl b
.shifted:
    ld l,h
    ld h,b                      ; the top two bytes
    ld a,(aa_index)
    ld e,a
    ld d,0
    ex de,hl
    ld bc,xMomentsLo
    add hl,bc
    ld (hl),e
    ld bc,xMomentsHi - xMomentsLo
    add hl,bc
    ld (hl),d
    ld a,(aa_index)
    sub 1
    jr nc,.force
    ld a,128
    ld (mult1_round),a

    ; The slip moment is the side force; flying forwards, the flaps' lift
    ; goes with the drag, and the drag pitches the nose.
    ld a,(xLiftDragLo)
    ld (zSlipMomentLo),a
    ld a,(xLiftDragHi)
    ld (zSlipMomentHi),a
    ld a,(zLiftDragHi)
    bit 7,a
    ret nz
    ld (yFlapsLiftHi),a
    ld h,a
    ld a,(zLiftDragLo)
    ld (yFlapsLiftLo),a
    ld a,(flapsStatus)
    ld l,a                      ; (zLiftDragHi flapsStatus), as the original shifts it
    ld b,0
    or a
    jr z,.flaps_in
    ; -((H L) << 2 >> 8)
    add hl,hl
    rl b
    add hl,hl
    rl b
    ld l,h
    ld h,b
    NEG_HL
    jr .pitching
.flaps_in:
    add hl,hl
    rl b
    add hl,hl
    rl b
    add hl,hl
    rl b
    ld l,h
    ld h,b
.pitching:
    ex de,hl
    LD16 xMomentsLo, xMomentsHi
    add hl,de
    ST16 xMomentsLo, xMomentsHi
    ret

aa_maxv:        dw 0
aa_vertical:    dw 0
aa_scale:       dw 0
aa_index:       db 0

; The moments before scaling, into xTemp3 (GetMoments): the lift-drag
; figures less the turn rates times 250/256, and -zTurn * 2.
get_moments:
    MACRO GM_AXIS axis
    LD16 xTurnHi + axis, xTurnTop + axis
    add hl,hl
    ld a,125
    call mul8x16                ; A H L
    ld l,h
    ld h,a                      ; the damping
    ex de,hl
    LD16 xLiftDragLo + (axis ^ 1), xLiftDragHi + (axis ^ 1)
    or a
    sbc hl,de
    ST16 xTemp3Lo + axis, xTemp3Hi + axis
    ENDM
    GM_AXIS 1
    GM_AXIS 0
    LD16 zTurnHi, zTurnTop
    NEG_HL
    add hl,hl
    ST16 zTemp3Lo, zTemp3Hi
    ret

; The controls' moments: each position times zLiftDrag, so the controls
; bite with the airflow; the ailerons and rudder snap to the centre near it
; or against a key (ApplyFlightControl).
apply_flight_control:
    MACRO AFC_AXIS axis
    ld a,(elevatorPosition + axis)
    IF axis != 0
    or a
    jr z,.position
    ld b,a
    ld a,(keyLoggerLo + axis)
    or a
    jr nz,.key
    ld a,b
    bit 7,a
    jr z,.positive
    cp $FD
    jr c,.position
    jr .centre
.positive:
    cp 4
    jr nc,.position
    jr .centre
.key:
    IF axis == 1
    ld a,(afm_on_ground)
    or a
    jr z,.position
    ENDIF
    ld a,(keyLoggerHi + axis)
    xor b
    rla
    jr nc,.position
.centre:
    xor a
    ld (elevatorPosition + axis),a
.position:
    ld a,(elevatorPosition + axis)
    ENDIF
    ld (afc_position),a
    bit 7,a
    jr z,.magnitude
    neg
.magnitude:
    ld b,a
    LD16 zLiftDragLo, zLiftDragHi
    ld a,b
    call mul8x16
    ld l,h
    ld h,a
    ld a,(afc_position)
    rla
    jr nc,.store
    NEG_HL
.store:
    ST16 xControlsLo + axis, xControlsHi + axis
    ENDM
    AFC_AXIS 2
    AFC_AXIS 1
    AFC_AXIS 0
    ret

afc_position:   db 0

; Each force times its coefficients (ScaleFlightForces): force * forceFactor
; * 2 ^ scaleFactor into the 24-bit scaled tables, with the wing's strain
; checked.
scale_flight_forces:
    ld hl,sff_indexes
.next:
    ld a,(hl)
    cp $FF
    ret z
    inc hl
    push hl
    ld (sff_index),a
    ld e,a
    ld d,0
    ld hl,forceFactor
    add hl,de
    ld c,(hl)                   ; the force factor
    ld hl,xMomentsLo
    add hl,de
    ld a,(hl)
    ld b,a
    ld a,l
    add a,WORK_HI
    ld l,a
    ld h,(hl)
    ld l,b
    ld a,c
    call mul8x16                ; A H L
    ld c,a
    ld a,(sff_index)
    cp Y_LIFT_DRAG
    jr nz,.no_strain
    ld a,c
    bit 7,a
    jr z,.top
    cpl
.top:
    cp 8
    jr c,.no_strain
    push bc
    push hl
    ld a,SOUND_STRAIN
    call make_sound
    pop hl
    pop bc
.no_strain:
    ld a,(sff_index)
    ld e,a
    ld d,0
    push hl
    ld hl,scaleFactor
    add hl,de
    ld a,(hl)
    pop hl
    or a
    jr z,.store
    bit 7,a
    jr z,.left
    neg
    ld b,a
.right:
    sra c
    rr h
    rr l
    djnz .right
    jr .store
.left:
    ld b,a
.left_loop:
    add hl,hl
    rl c
    djnz .left_loop
.store:
    ex de,hl
    ld a,(sff_index)
    ld l,a
    ld h,high xMomentsScLo
    ld a,l
    add a,low xMomentsScLo
    ld l,a
    ld (hl),e
    ld a,l
    add a,xMomentsScHi - xMomentsScLo
    ld l,a
    ld (hl),d
    ld a,l
    add a,xMomentsScTop - xMomentsScHi
    ld l,a
    ld (hl),c
    pop hl
    jr .next

sff_indexes:    db 12, 11, 10, 7, 6, 5, 4, 3, 2, 1, 0, $FF
sff_index:      db 0

    ASSERT high xMomentsScLo == high (xMomentsScTop + 12)

; ---- ApplyTurnAndThrust ---------------------------------------------------

; The scaled forces into the plane's accelerations (ApplyTurnAndThrust).
apply_turn_and_thrust:
    ; Part 1: dxTurn = the moments and the controls; gravity pitches,
    ; the slip moment rolls.
    MACRO ATT_AXIS axis
    ld a,(xMomentsScLo + axis)
    ld hl,xControlsScLo + axis
    add a,(hl)
    ld (dxTurnLo + axis),a
    ld a,(xMomentsScHi + axis)
    ld hl,xControlsScHi + axis
    adc a,(hl)
    ld (dxTurnHi + axis),a
    ld a,(xMomentsScTop + axis)
    ld hl,xControlsScTop + axis
    adc a,(hl)
    ld (dxTurnTop + axis),a
    ENDM
    ATT_AXIS 2
    ATT_AXIS 1
    ATT_AXIS 0
    LD16 yGravityLo, yGravityHi
    ld a,h
    rla
    sbc a,a
    ld c,a
    ld a,(dxTurnLo)
    add a,l
    ld (dxTurnLo),a
    ld a,(dxTurnHi)
    adc a,h
    ld (dxTurnHi),a
    ld a,(dxTurnTop)
    adc a,c
    ld (dxTurnTop),a
    ld a,(zSlipMomentScLo)
    ld b,a
    ld a,(dzTurnLo)
    sub b
    ld (dzTurnLo),a
    ld a,(zSlipMomentScHi)
    ld b,a
    ld a,(dzTurnHi)
    sbc a,b
    ld (dzTurnHi),a
    ld a,(zSlipMomentScTop)
    ld b,a
    ld a,(dzTurnTop)
    sbc a,b
    ld (dzTurnTop),a

    ; Part 2: the linear accelerations.
    LD16 xLiftDragScHi, xLiftDragScTop
    NEG_HL
    ST16 xLinearLo, xLinearHi
    LD16 yLiftDragScHi, yLiftDragScTop
    ex de,hl
    LD16 yFlapsLiftScHi, yFlapsLiftScTop
    or a
    sbc hl,de
    ST16 yLinearLo, yLinearHi
    ld a,(zVelocityPHi)
    bit 7,a
    jr z,.forwards
    xor a
    jr .speed
.forwards:
    push af
    call retract_flaps_if_fast
    pop af
    cp 48
    jr c,.speed
    ld a,$EA                    ; 500 mph: the maximum speed
    ld (zLinearHi),a
    ret
.speed:
    ld (att_forward),a
    ld hl,0
    ld a,(engineStatus)
    or a
    jr z,.thrust
    ld a,(att_forward)
    ld h,a
    ld a,(zVelocityPLo)
    ld l,a
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ex de,hl                    ; D E = the slowing
    LD16 thrustLo, thrustHi
    ld a,(afm_on_ground)
    or a
    jr z,.airborne
    ld a,(thrustHi)
    cp 4
    jr c,.not_high
    add hl,hl
.not_high:
    ld a,(att_forward)
    or a
    jr z,.airborne
    cp 4
    jr nc,.airborne
    add hl,hl
.airborne:
    or a
    sbc hl,de
    bit 7,h
    jr z,.thrust
    ld hl,0
.thrust:
    call scale_by_altitude      ; A H L
    ld l,h
    ld h,a
    ex de,hl
    LD16 zLiftDragScHi, zLiftDragScTop
    ex de,hl
    or a
    sbc hl,de
    ST16 zLinearLo, zLinearHi
    ret

att_forward:    db 0

; Retract the flaps at an airspeed's high byte (A) of 14 or more
; (RetractFlapsIfFast).
retract_flaps_if_fast:
    cp 14
    ret c
    ld a,(flapsStatus)
    or a
    ret z
    xor a
    ld (flapsStatus),a
    jp indicator_f

; ---- landing --------------------------------------------------------------

; Carry clear if the plane is over the runway: within 256 east of its
; south-west corner and between 0 and 24 * 256 north (CheckPlaneOnRunway).
; Uses A, DE, HL.
check_plane_on_runway:
    LD16 xObjectLo + RUNWAY_OBJECT, xObjectHi + RUNWAY_OBJECT
    ex de,hl
    LD16 xPlaneLo, xPlaneHi
    or a
    sbc hl,de
    ld a,h
    or a
    jr nz,.off
    LD16 zObjectLo + RUNWAY_OBJECT, zObjectHi + RUNWAY_OBJECT
    ex de,hl
    LD16 zPlaneLo, zPlaneHi
    or a
    sbc hl,de
    ld a,h
    bit 7,a
    jr nz,.off
    cp RUNWAY_LENGTH_HI
    ccf
    ret
.off:
    scf
    ret

; Keep the plane out of the ground, and decide what touching it means
; (ProcessLanding). Raises EVENT_CRASH.
process_landing:
    ; Part 1: a bumpy ride off the runway.
    ld a,(afm_on_ground)
    or a
    jr z,.height
    call check_plane_on_runway
    jr nc,.height
    ld hl,landingStatus
    sla (hl)
    ld c,Y_PLANE
    ld b,8
    ld e,0
    call apply_bumpy_ride
    call read_timer
    and 1
    ld e,a
    ld c,Z_ROTATION
    ld b,4
    call apply_bumpy_ride

.height:
    ; Part 2: still in the air?
    ld a,(yPlaneHi)
    bit 7,a
    jr z,.not_below
    RESET_VARIABLE Y_PLANE
    jr .low
.not_below:
    or a
    jr z,.low
    cp 2
    jr c,.airborne
    ld (reached512ft),a
.airborne:
    xor a
    ld (onGround),a
    ret
.low:
    ld a,(yPlaneLo)
    ld b,a
    ld a,(yLandingGear)
    cp b
    jr c,.airborne

    ld c,a                      ; C = the gear's height
    ld a,(afm_on_ground)
    or a
    jr z,.touchdown
    ; Part 3: taxiing.
    ld a,c
    ld (yPlaneLo),a
    ld a,(yVelocityTop)
    rla
    jr nc,.not_sinking
    RESET_VARIABLE Y_VELOCITY
.not_sinking:
    RESET_VARIABLE Z_ROTATION
    RESET_VARIABLE Z_TURN
    ld a,(ucStatus)
    or a
    jr nz,.wheels
    ; Part 4: on its belly the nose cannot go down.
    ld a,(landingStatus)
    rla
    jr c,.belly
    ld hl,landingStatus
    sla (hl)
.belly:
    ld a,(xRotationHi)
    rla
    ret nc
    RESET_VARIABLE X_ROTATION
    RESET_VARIABLE X_TURN
    ret
.wheels:
    ; Part 5: on its wheels the nose cannot rise past the tail wheel.
    ld a,(xRotationHi)
    bit 7,a
    ret nz
    cp 7
    ret c
    ld a,7
    ld (xRotationHi),a
    xor a
    ld (xRotationLo),a
    ld a,(xTurnTop)
    rla
    ret c
    RESET_VARIABLE X_TURN
    ret

.touchdown:
    ; Part 6: lift the plane out of the ground by half the depth it
    ; reached, and bounce the descent into a climb.
    ld a,(yPlaneLo)
    ld b,a
    ld a,c
    sub b
    srl a
    add a,c
    ld (yPlaneLo),a
    ld a,(yVelocityTop)
    bit 7,a
    jr z,.climbing
    LD16 yVelocityHi, yVelocityTop
    NEG_HL
    ST16 yVelocityHi, yVelocityTop
.climbing:
    ld a,(yVelocityTop)
    cp 2
    jp nc,raise_crash           ; 512 or more
    rra                         ; its bit 0...
    ld a,(yVelocityHi)
    rra                         ; ...on top of the high byte halved
    ld (pl_half),a
    ld b,a
    ld a,(ucStatus)
    or a
    jr nz,.on_wheels
    ld a,$FF
    ld (propellorStatus),a      ; the propeller hits the ground
    ld a,b
    cp 160
    jr nc,.hard
    xor a
    call set_engine
    jr .landed
.hard:
    cp 110
    jp nc,raise_crash
    jr .landed
.on_wheels:
    ld a,b
    cp 110
    jp nc,raise_crash
.landed:
    call check_plane_on_runway
    jr nc,.touchdown_sound
    ld a,(pl_half)
    ld (yVelocityHi),a
    ld a,(ucStatus)
    or a
    jr z,.touchdown_sound
    ld a,(pl_half)
    cp 80
    jp nc,raise_crash
    jr .roll
.touchdown_sound:
    ld a,SOUND_TOUCHDOWN
    call make_sound
    call reset_engine_sound

.roll:
    ; Part 7: the roll on touchdown, against the roll angle, and the wings
    ; levelled.
    LD16 zRotationLo, zRotationHi
    ld a,(pl_half)
    call mul8x16
    ld l,h
    ld h,a
    NEG_HL
    sra h
    rr l
    sra h
    rr l
    ld a,h
    ld (zTurnTop),a
    ld a,l
    ld (zTurnHi),a
    RESET_VARIABLE Z_ROTATION
    ld a,(xRotationHi)
    rla
    jr nc,.level
    ld a,(ucStatus)
    or a
    jr nz,.level
    RESET_VARIABLE X_ROTATION    ; a belly flop
.level:
    ld a,(pl_half)
    cp 12
    ret nc
    ld a,(yLandingGear)
    ld b,a
    ld a,(yPlaneLo)
    cp b
    ret nz
    ld a,1
    ld (onGround),a
    ret

pl_half:    db 0

; Add (A 0) >> (B + 1) to the workspace variable at offset C, or take it
; away (E), where A is a random number from 0 up to zVelocityPHi
; (ApplyBumpyRide); nothing if going backwards.
apply_bumpy_ride:
    ld a,(zVelocityPHi)
    bit 7,a
    ret nz
    ld d,a
    call read_timer
    and d
    jp add_scaled

; ---- the engine and fuel --------------------------------------------------

; Switch the engine on (A = 1) or off (0), if it isn't already (SetEngine).
set_engine:
    ld hl,engineStatus
    cp (hl)
    ret z
    ld (hl),a
    call toggle_engine_sound
    ld a,(forceFactor + Z_LIFT_DRAG)
    ld b,a
    ld a,(engineStatus)
    or a
    ld a,b
    jr nz,.on
    add a,20                    ; a stopped propeller is a brake
    jr nz,.done
.on:
    sub 20
.done:
    ld (forceFactor + Z_LIFT_DRAG),a
    ret

; Start or update the engine sound (A non-zero) or stop it
; (ToggleEngineSound).
toggle_engine_sound:
    or a
    jr nz,make_engine_sound
    ld a,SOUND_ENGINE_OFF
    call make_sound
    ; fall through

; The engine's pitch back to its resting value (ResetEngineSound).
reset_engine_sound:
    ld a,ENGINE_PITCH_RESET
    ld (ENGINE_PITCH),a
    ret

; The engine sound from the throttle and the airspeed (MakeEngineSound).
make_engine_sound:
    ld a,(engineStatus)
    or a
    ret z
    LD16 thrustLo, thrustHi
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld a,(zVelocityPHi)
    add a,l
    ld b,a                      ; K
    ld a,50
    sub b
    jr z,.smoothest
    jp p,.roughness
.smoothest:
    ld a,1
.roughness:
    ld (envelopeData + 2),a
    ld (envelopeData + 4),a
    cpl
    ld (envelopeData + 3),a
    ld a,b
    add a,80
    ld hl,ENGINE_PITCH
    cp (hl)
    ret z
    ld (hl),a
    xor a
    call define_envelope
    ld a,SOUND_ENGINE_PITCH
    call make_sound
    ld a,SOUND_ENGINE_AMPLITUDE
    jp make_sound

; Refuelling, while the engine is off: a unit every fourth iteration, until
; the tank is full (FillUpFuelTank).
fill_up_fuel_tank:
    ld a,(mainLoopCounter)
    and 3
    ret nz
    ld a,(fuelLevel)
    cp FUEL_FULL
    jr c,.fill
    xor a
    ld (landingStatus),a
    ret
.fill:
    ld b,a
    inc a
    ld (fuelLevel),a
    ld a,b
    ld c,0
    jp draw_fuel_pixel

; ---- the undercarriage, flaps and brakes ---------------------------------

; A toggle key's press, for key pair A (4: U or B, 5: F or SHIFT): flip the
; status byte its key logger value picks, once a press. A = 1 for U or F,
; 128 for B or SHIFT, 0 if nothing happened (ProcessOtherKeys).
process_other_keys:
    ld e,a
    ld d,0
    ld hl,keyLoggerLo
    add hl,de
    ld a,(hl)
    or a
    jr nz,.pressed
    ld hl,pressingUFBS - 4
    add hl,de
    ld (hl),a
    inc hl
    inc hl
    inc hl
    ld (hl),a
    ret
.pressed:
    ld e,a                      ; the key: 4, 5, 7 or 8
    ld hl,pressingUFBS - 4
    add hl,de
    ld a,(hl)
    or a
    ld a,0
    ret nz
    ld (hl),1
    ld hl,ucStatus - 4
    add hl,de
    ld a,(hl)
    xor 1
    ld (hl),a
    ld a,e
    cp 7
    ld a,1
    ret c
    ld a,128
    ret

; Follow a change of ucStatus (IndicatorU): the drag, the height of the
; cockpit over the lowest part of the plane, and the lamp. It can't be
; lowered on the ground.
indicator_u:
    ld a,(ucStatus)
    or a
    jr nz,.down
    ld a,(forceFactor + Z_LIFT_DRAG)
    sub 10
    ld (forceFactor + Z_LIFT_DRAG),a
    ld a,5
    ld (yLandingGear),a
    ld c,0
    jr .lamp
.down:
    ld a,(onGround)
    or a
    jr z,.lowered
    xor a
    ld (ucStatus),a
    ret
.lowered:
    ld a,(forceFactor + Z_LIFT_DRAG)
    add a,10
    ld (forceFactor + Z_LIFT_DRAG),a
    ld a,10
    ld (yLandingGear),a
    ld c,1
.lamp:
    ld a,LAMP_U
    jp draw_indicator

; Follow a change of flapsStatus (IndicatorF): the drag, the flaps' lift and
; the lamp.
indicator_f:
    ld a,(flapsStatus)
    or a
    jr nz,.out
    ld a,(forceFactor + Z_LIFT_DRAG)
    sub 200
    ld (forceFactor + Z_LIFT_DRAG),a
    xor a
    ld (forceFactor + Y_FLAPS_LIFT),a
    ld c,0
    jr .lamp
.out:
    ld a,(forceFactor + Z_LIFT_DRAG)
    add a,200
    ld (forceFactor + Z_LIFT_DRAG),a
    ld a,152
    ld (forceFactor + Y_FLAPS_LIFT),a
    ld c,1
.lamp:
    ld a,LAMP_F
    jp draw_indicator

; Show whether the brakes are on (IndicatorB).
indicator_b:
    ld a,(brakesStatus)
    or a
    ld c,0
    jr z,.lamp
    inc c
.lamp:
    ld a,LAMP_B
    jp draw_indicator

; Show whether the Theme is on: themeStatus positive (IndicatorT).
indicator_t:
    ld a,(themeStatus)
    rla
    ccf
    ld c,0
    rl c
    ld a,LAMP_T
    jp draw_indicator
