; The dashboard, after model/dashboard.py: the dials, the artificial
; horizon, the joystick display, the rudder and thrust bars, the radar, the
; fuel gauge and the lamps. The game's arithmetic -- each indicator's value,
; the hand vectors, the radar's positions, the line buffers -- is the
; original's, on its own variables; the drawing is model/zx.py's.
;
; The original draws every hand, bar and blip with DrawVectorLine, from a
; first pixel (I, J) along lengths T and U in direction V (bit 7 leftwards,
; bit 6 down J), J counting up the screen from the bottom of the canopy.
; The Spectrum draws, set or cleared on the screen, the line between the
; mapped ends of the BBC's first and last pixels, the last found by stepping
; along it as the original does (dash_line). The marks the original rewrites
; whole bytes of, and the lamps, are lists of screen bytes made by build.py
; (dash_bytes).

DASH_ROWS       equ $F500       ; the screen address of Spectrum row L: low bytes, then a page on, high
DASH_Y          equ DASH_ROWS + $200 ; the Spectrum row of BBC row L
DASH_MARKS      equ $F800       ; the marks' and lamps' screen bytes (gen_dash.s)
UPSIDE_DOWN_PATTERN equ %00001110

HORIZON_X       equ 53          ; where the horizon, the bars and the joystick cross
HORIZON_J       equ 227         ; sit, in the original's (I, J)
RUDDER_X        equ 80
RUDDER_TOP_J    equ 163
RUDDER_HEIGHT   equ 11
THRUST_X        equ 125
THRUST_TOP_J    equ 243
THRUST_HEIGHT   equ 7
JOYSTICK_X      equ 80
JOYSTICK_J      equ 216
RADAR_X         equ 140
RADAR_J         equ 208
RADAR_HALF_WIDTH equ 13
RADAR_HALF_HEIGHT equ 26
ALIEN_OBJECT    equ 33
FUEL_X          equ 2
FUEL_BOTTOM_J   equ 184
LAMP_U          equ 0           ; draw_indicator's lamps
LAMP_F          equ 1
LAMP_B          equ 2
LAMP_T          equ 3

    ASSERT low DASH_ROWS == 0

; ---- drawing ------------------------------------------------------------------

; Apply the list of screen bytes at HL: (address, keep, OR), ending with an
; address of 0. Uses A, DE, HL.
dash_bytes:
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,d
    or a
    ret z
    ld a,(de)
    and (hl)
    inc hl
    or (hl)
    inc hl
    ld (de),a
    jr dash_bytes

; Draw (dash_draw) or erase (dash_erase) DrawVectorLine's line from (B, C) =
; (I, J), lengths D = T and E = U, direction A = V. Uses everything but IX
; and IY.
dash_erase:
    push af
    ld a,1
    jr dash_line
dash_draw:
    push af
    xor a
dash_line:
    ld (dl_erase),a
    pop af
    ld (dl_v),a
    ld a,b
    ld (dl_i0),a
    ld a,c
    ld (dl_j0),a
    ; The last pixel: max(T, U) pixels, the shorter axis stepping as its
    ; remainder reaches the longer length (vector_line_pixels).
    ld a,d
    cp e
    jr c,.steep
    ld l,d                      ; the count
    ld h,0                      ; the remainder
.shallow:
    dec l
    jr z,.last
    ld a,h
    add a,e
    cp d
    jr c,.shallow_stay
    sub d
    call .step_j
.shallow_stay:
    ld h,a
    call .step_i
    jr .shallow
.steep:
    ld l,e
    ld h,0
.steep_loop:
    dec l
    jr z,.last
    ld a,h
    add a,d
    cp e
    jr c,.steep_stay
    sub e
    call .step_i
.steep_stay:
    ld h,a
    call .step_j
    jr .steep_loop
.step_i:
    push af
    ld a,(dl_v)
    rla
    jr c,.left
    inc b
    pop af
    ret
.left:
    dec b
    pop af
    ret
.step_j:
    push af
    ld a,(dl_v)
    bit 6,a
    jr nz,.down
    inc c
    pop af
    ret
.down:
    dec c
    pop af
    ret
.last:
    ; The two ends on the Spectrum: x by view_x, the screen row 159 - J by
    ; DASH_Y.
    ld h,high view_x
    ld l,b
    ld a,(hl)
    ld (vl_xe),a                ; (borrowing the view's)
    ld a,159
    sub c
    ld l,a
    ld h,high DASH_Y
    ld a,(hl)
    ld (vl_ye),a
    ld a,(dl_i0)
    ld l,a
    ld h,high view_x
    ld b,(hl)
    ld a,(dl_j0)
    ld c,a
    ld a,159
    sub c
    ld l,a
    ld h,high DASH_Y
    ld c,(hl)
    ; fall through: from (B, C) to (vl_xe, vl_ye)

; Draw or erase (dl_erase) the line from Spectrum pixel (B, C) to (vl_xe,
; vl_ye) on the screen, both ends included: model/zx.py's bresenham.
screen_line:
    ld a,(vl_xe)
    sub b
    ld d,1
    jr nc,.dx
    neg
    ld d,-1
.dx:
    ld (sl_dx),a
    ld a,d
    ld (sl_step_x),a
    ld a,(vl_ye)
    sub c
    ld d,1
    jr nc,.dy
    neg
    ld d,-1
.dy:
    ld (sl_dy),a
    ld a,d
    ld (sl_step_y),a
    ld a,(sl_dx)
    ld d,a
    ld a,(sl_dy)
    ld e,a                      ; D = dx, E = dy
    ld a,d
    cp e
    jr c,.steep
    srl a
    ld (sl_err),a
    ld a,d
    inc a
    ld (sl_count),a             ; dx + 1 (256 counts as 0)
.shallow:
    call screen_plot
    ld a,(sl_err)
    sub e
    jr nc,.shallow_x
    add a,d
    push af
    ld a,(sl_step_y)
    add a,c
    ld c,a
    pop af
.shallow_x:
    ld (sl_err),a
    ld a,(sl_step_x)
    add a,b
    ld b,a
    ld hl,sl_count
    dec (hl)
    jr nz,.shallow
    ret
.steep:
    ld a,e
    srl a
    ld (sl_err),a
    ld a,e
    inc a
    ld (sl_count),a
.steep_loop:
    call screen_plot
    ld a,(sl_err)
    sub d
    jr nc,.steep_y
    add a,e
    push af
    ld a,(sl_step_x)
    add a,b
    ld b,a
    pop af
.steep_y:
    ld (sl_err),a
    ld a,(sl_step_y)
    add a,c
    ld c,a
    ld hl,sl_count
    dec (hl)
    jr nz,.steep_loop
    ret

; Set (or, with dl_erase, clear) the screen's pixel (B, C), if it is on the
; screen. Uses A, HL, and keeps the rest.
screen_plot:
    ld a,c
    cp 192
    ret nc
    push de
    ld l,c
    ld h,high DASH_ROWS
    ld e,(hl)
    inc h
    ld d,(hl)
    ld a,b
    rrca
    rrca
    rrca
    and $1F
    or e
    ld e,a                      ; D E -> the byte
    ld a,b
    and 7
    ld l,a
    ld h,high bit_masks
    ld a,(dl_erase)
    or a
    ld a,(de)
    jr nz,.clear
    or (hl)
    ld (de),a
    pop de
    ret
.clear:
    ld l,(hl)
    ld h,a
    ld a,l
    cpl
    and h
    ld (de),a
    pop de
    ret

dl_erase:   db 0
dl_v:       db 0
dl_i0:      db 0
dl_j0:      db 0
sl_dx:      db 0
sl_dy:      db 0
sl_step_x:  db 0
sl_step_y:  db 0
sl_err:     db 0
sl_count:   db 0

; DrawOrthoLine: a line going right and up from (along, joy), A = along,
; joyCoord the other coordinate: S (in E) bit 7 clear puts joy across and
; along up, set the other way round. B = T, C = U; dl_ortho_erase set to
; erase. Uses everything but IX and IY.
draw_ortho_line:
    ld d,b                      ; T
    ld l,c                      ; U
    ld b,a                      ; I = along
    ld a,(joyCoord)
    ld c,a                      ; J = joy
    bit 7,e
    jr nz,.ends
    ld a,b
    ld b,c
    ld c,a                      ; I = joy, J = along
.ends:
    ld e,l
    ld a,(dl_ortho_erase)
    or a
    ld a,0
    jp nz,dash_erase
    jp dash_draw

dl_ortho_erase: db 0

; ---- the dials ------------------------------------------------------------

; The vector of dial C's hand for value A, as D = W, E = G, A = R
; (GetHandVector): the quadrant and the position in it, then the edge of a
; diamond, capped. Uses B, C, HL.
get_hand_vector:
    ld b,a
    ld a,c
    ld (ghv_dial),a
    ld hl,dialQuadrant
    call .entry
    ld c,a                      ; the quarter
    ld d,a
    inc d                       ; and one more
    ld a,b
    ld b,0                      ; R
.quadrant:
    sub d
    jr c,.first
    sub c
    jr c,.second
    sub d
    jr c,.third
    sub c
    jr nc,.quadrant
    ld b,$80                    ; 9 to 12 o'clock, counted back
    cpl
    jr .position
.first:
    add a,d                     ; 12 to 3 o'clock
    jr .position
.second:
    ld b,$40                    ; 3 to 6 o'clock, counted back: having taken
    cpl                         ; off one more than the quarter, inverting negates
    jr .position
.third:
    add a,d                     ; 6 to 9 o'clock
    ld b,$C0
.position:
    ld e,a                      ; the position
    ld a,c
    sub e                       ; dy = quarter - position
    ld hl,yDeltaMax
    call .cap
    inc a
    ld c,a                      ; G
    ld a,e
    inc a
    srl a                       ; dx = (position + 1) / 2
    ld hl,xDeltaMax
    call .cap
    inc a
    ld d,a                      ; W
    ld e,c
    ld a,b
    ret
.cap:
    ; A = min(A, the dial's entry in the table at HL).
    push af
    call .entry
    ld l,a
    pop af
    cp l
    ret c
    ld a,l
    ret
.entry:
    ; A = the dial's entry in the table at HL (a page holds them all).
    ld a,(ghv_dial)
    add a,l
    ld l,a
    ld a,(hl)
    ret

ghv_dial:   db 0

    ASSERT high dialQuadrant == high (yDeltaMax + 6) && high xDeltaMax == high dialQuadrant

; Replace indicator A's line (a hand, or the horizon for 7) with lengths D,
; E and direction C (DrawIndicatorLine): erase the old one from the line
; buffers and remember and draw the new one. For the horizon, B and L are
; its new start (S, H), and the horizon's centre marks are rewritten.
draw_indicator_line:
    ld (dil_x),a
    ld (dil_new),de
    ld a,c
    ld (dil_r),a
    ld a,b
    ld (dil_s),a
    ld a,l
    ld (dil_h),a
    ; Erase the old line.
    ld a,(dil_x)
    ld e,a
    ld d,0
    ld hl,indicatorLineI
    add hl,de
    ld b,(hl)
    ld hl,indicatorLineJ
    add hl,de
    ld c,(hl)
    ld hl,indicatorLineV
    add hl,de
    ld a,(hl)
    push af
    ld hl,indicatorLineT
    add hl,de
    ld a,(hl)
    ld hl,indicatorLineU
    add hl,de
    ld e,(hl)
    ld d,a
    pop af
    call dash_erase
    ld a,(dil_x)
    cp 7
    jr nz,.not_horizon
    ld hl,horizon_centre_ops
    call dash_bytes
    ld a,(dil_s)
    ld (indicatorLineI + 7),a
    ld a,(dil_h)
    ld (indicatorLineJ + 7),a
.not_horizon:
    ld a,(dil_x)
    ld e,a
    ld d,0
    ld hl,indicatorLineT
    add hl,de
    ld a,(dil_new + 1)
    ld (hl),a
    ld hl,indicatorLineU
    add hl,de
    ld a,(dil_new)
    ld (hl),a
    ld hl,indicatorLineV
    add hl,de
    ld a,(dil_r)
    ld (hl),a
    ld hl,indicatorLineI
    add hl,de
    ld b,(hl)
    ld hl,indicatorLineJ
    add hl,de
    ld c,(hl)
    ld de,(dil_new)
    ld a,(dil_r)
    jp dash_draw

dil_x:      db 0
dil_new:    dw 0                ; E = G, D = W
dil_r:      db 0
dil_s:      db 0
dil_h:      db 0

; Show value A on dial C (0 to 6) (DrawIndicatorHand): plus the dial's
; base, clipped to its range, as its hand.
draw_indicator_hand:
    ld b,a
    ld a,c
    ld (dih_x),a
    ld e,a
    ld d,0
    ld hl,indicatorBase
    add hl,de
    ld a,b
    add a,(hl)
    ld b,a
    ld hl,indicatorMin
    add hl,de
    cp (hl)
    jr nc,.not_low
    ld b,(hl)
    jr .clipped
.not_low:
    ld hl,indicatorMax
    add hl,de
    cp (hl)
    jr c,.clipped
    ld b,(hl)
.clipped:
    ld a,(dih_x)
    ld c,a
    ld a,b
    call get_hand_vector
    ld c,a
    ld a,(dih_x)
    jp draw_indicator_line

dih_x:      db 0

; The unrolled multiplications of UpdateIndicator: for each step, 0 halves
; the running value, 1 adds the value and halves the nine-bit sum. A = the
; value; uses B.
    MACRO TIMES_HALF
    srl a
    ENDM
    MACRO TIMES_ADD
    add a,b
    rra
    ENDM

times_compass:                  ; 37/128: 0, 0, 1, 0, 0, 1, 0
    ld b,a
    TIMES_HALF
    TIMES_HALF
    TIMES_ADD
    TIMES_HALF
    TIMES_HALF
    TIMES_ADD
    TIMES_HALF
    ret

times_altitude:                 ; 53/128: 0, 0, 1, 0, 1, 1, 0
    ld b,a
    TIMES_HALF
    TIMES_HALF
    TIMES_ADD
    TIMES_HALF
    TIMES_ADD
    TIMES_ADD
    TIMES_HALF
    ret

times_vertical_speed:           ; 35/128: 0, 1, 0, 0, 0, 1, 0
    ld b,a
    TIMES_HALF
    TIMES_ADD
    TIMES_HALF
    TIMES_HALF
    TIMES_HALF
    TIMES_ADD
    TIMES_HALF
    ret

times_turn:                     ; 19/128: 0, 1, 0, 0, 1, 0, 0
    ld b,a
    TIMES_HALF
    TIMES_ADD
    TIMES_HALF
    TIMES_HALF
    TIMES_ADD
    TIMES_HALF
    TIMES_HALF
    ret

; A scaled down by 4 (C = 0) or by 16 (C non-zero), keeping its sign and
; rounding up, 4 to 7 turning to 1 when dividing by 16 (ScaleSigned).
scale_signed:
    ld b,a
    bit 7,a
    jr z,.positive
    neg
.positive:
    srl a
    inc c
    dec c
    jr z,.by_4
    srl a
    cp 1
    jr nz,.not_one
    inc a
.not_one:
    srl a
.by_4:
    srl a
    adc a,0                     ; (a >> 1) + (a & 1)
    bit 7,b
    ret z
    neg
    ret

; Redraw indicator A (0 to 11) from the game's values (UpdateIndicator).
update_indicator:
    or a
    jr nz,.not_compass
    ld a,(yRotationHi)
    call times_compass
    ld c,0
    jp draw_indicator_hand
.not_compass:
    dec a
    jr nz,.not_airspeed
    ld a,(zVelocityPHi)
    bit 7,a
    ld b,0
    jr nz,.airspeed
    ld b,a
    ld a,(zVelocityPLo)
    rla
    rl b
.airspeed:
    ld a,b
    ld c,1
    jp draw_indicator_hand
.not_airspeed:
    dec a
    jr nz,.not_hours
    call altimeter_hours
    ld c,2
    jp draw_indicator_hand
.not_hours:
    dec a
    jr nz,.not_minutes
    ld a,(altitudeMinutes)
    ld c,3
    jp draw_indicator_hand
.not_minutes:
    dec a
    jr nz,.not_vertical
    call vertical_speed
    ld c,4
    jp draw_indicator_hand
.not_vertical:
    dec a
    jr nz,.not_turn
    call turn_value
    ld c,5
    jp draw_indicator_hand
.not_turn:
    dec a
    jr nz,.not_slip
    ld a,(slipRate)
    ld c,6
    jp draw_indicator_hand
.not_slip:
    dec a
    jp z,horizon
    dec a
    jp z,joystick_display
    dec a
    jr nz,.not_rudder
    ld a,(rudderPosition)
    ld c,1
    call scale_signed
    ld h,a
    ld a,RUDDER_HEIGHT
    ld b,1
    ld c,RUDDER_X
    ld d,RUDDER_TOP_J
    jp draw_indicator_bar
.not_rudder:
    dec a
    jp z,joystick_display
    ; 11: the thrust, * 3/64, as (thrust / 16) * 1.5, rounded, then / 4.
    LD16 thrustLo, thrustHi
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld a,l
    srl a
    adc a,l                     ; (a >> 1) + a + (a & 1), eight bits
    srl a
    srl a
    ld h,a
    ld a,THRUST_HEIGHT
    ld b,3
    ld c,THRUST_X
    ld d,THRUST_TOP_J
    jp draw_indicator_bar

; Part 4: the hour hand's value, the minute hand's kept in
; altitudeMinutes: (yPlane / 4) * 53/128, the low byte alone for the
; minutes, and all of it / 16 for the hours, with the high byte's product's
; fraction caught below it.
altimeter_hours:
    LD16 yPlaneLo, yPlaneHi
    srl h
    rr l
    srl h
    rr l                        ; the altitude, (S R)
    ld a,l
    push hl
    call times_altitude
    ld (altitudeMinutes),a
    pop hl
    ld c,h                      ; S
    ld l,0                      ; (U T) = S << 8
    MACRO AH_HALF
    srl h
    rr l
    ENDM
    MACRO AH_ADD
    ld a,h
    add a,c
    ld h,a
    rr h
    rr l
    ENDM
    AH_HALF
    AH_HALF
    AH_ADD
    AH_HALF
    AH_ADD
    AH_ADD
    AH_HALF
    ld a,(altitudeMinutes)
    ld e,a
    ld d,0
    add hl,de
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ret

; Part 7: |yVelocity| / 8, at most 255, scaled and at most 40, with
; yVelocity's sign.
vertical_speed:
    LD16 yVelocityHi, yVelocityTop
    bit 7,h
    jr z,.magnitude
    NEG_HL
.magnitude:
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld a,h
    or a
    ld a,l
    jr z,.small
    ld a,255
.small:
    call times_vertical_speed
    cp 40
    jr c,.signed
    ld a,40
.signed:
    ld b,a
    ld a,(yVelocityTop)
    rla
    ld a,b
    ret nc
    neg
    ret

; Part 9: |yTurn|, at most 140, scaled, with the opposite sign to yTurn.
turn_value:
    LD16 yTurnHi, yTurnTop
    bit 7,h
    jr z,.magnitude
    NEG_HL
.magnitude:
    ld a,140
    inc h
    dec h
    jr nz,.capped
    ld a,l
    cp 140
    jr c,.capped
    ld a,140
.capped:
    call times_turn
    ld b,a
    ld a,(yTurnTop)
    rla
    ld a,b
    ret c
    neg
    ret

; Part 11: the artificial horizon's new line, from four calls of
; ArtificialHorizon.
horizon:
    ld bc,0
    call artificial_horizon
    ld (hz_s),a
    ld bc,3
    call artificial_horizon
    ld (hz_h),a
    ld bc,$0100
    call artificial_horizon
    ld hl,hz_s
    sub (hl)
    ld c,0
    bit 7,a
    jr z,.dx
    ld c,$80
    neg
.dx:
    inc a
    ld (hz_w),a
    push bc
    ld bc,$0103
    call artificial_horizon
    pop bc
    ld hl,hz_h
    sub (hl)
    bit 7,a
    jr z,.dy
    set 6,c
    neg
.dy:
    inc a
    ld e,a
    ld a,(hz_w)
    ld d,a
    ld a,(hz_s)
    add a,HORIZON_X
    ld b,a
    ld a,(hz_h)
    add a,HORIZON_J
    ld l,a
    ld a,7
    jp draw_indicator_line

hz_s:   db 0
hz_h:   db 0
hz_w:   db 0

; A = one coordinate of the horizon line's ends relative to the dial's
; centre (ArtificialHorizon): C = 0 for x, 3 for y; B = 0 for the start, 1
; for the end. From matrix 4's entries C and C + 2, their high bytes / 8
; (x) or / 4 (y), signed by bit 0 of their low bytes, the start's first
; term and x's second flipped; the sum / 8, signed, rounded.
artificial_horizon:
    ld e,c
    ld d,0
    ld hl,matrix4Hi
    add hl,de
    ld a,(hl)
    call .shift
    ld l,a                      ; t
    push hl
    ld hl,matrix4Lo
    add hl,de
    ld a,(hl)
    xor b
    pop hl
    rra
    ld a,l
    jr nc,.t
    neg
.t:
    ld (ah_t),a
    ld hl,matrix4Hi + 2
    add hl,de
    ld a,(hl)
    call .shift
    ld (ah_u),a
    ld hl,matrix4Lo + 2
    add hl,de
    ld a,(hl)
    inc c
    dec c
    jr nz,.y
    xor 1
.y:
    rra
    ld a,(ah_u)
    jr nc,.u
    neg
.u:
    ld hl,ah_t
    add a,(hl)
    ld b,a                      ; a
    srl a
    srl a
    and 1
    ld e,a                      ; the rounding: the last bit shifted out
    ld a,b
    sra a
    sra a
    sra a
    add a,e
    ret
.shift:
    srl a
    srl a
    inc c
    dec c
    ret nz
    srl a
    ret

ah_t:   db 0
ah_u:   db 0

; Part 14: move the joystick display's cross.
joystick_display:
    ld a,1
    call draw_joystick_cross
    ld hl,joystick_axes_ops
    call dash_bytes
    ld a,(aileronPosition)
    ld c,1
    call scale_signed
    ld (xJoyCoord),a
    ld a,(elevatorPosition)
    ld c,0
    call scale_signed
    neg
    ld (yJoyCoord),a
    xor a
    ; fall through

; The joystick display's cross, drawn (A = 0) or erased (1)
; (DrawJoystickCross): three pixels across starting one to the left, then
; five up starting two below.
draw_joystick_cross:
    ld (dl_ortho_erase),a
    ld a,(xJoyCoord)
    add a,JOYSTICK_X - 1
    ld (joyCoord),a
    ld a,(yJoyCoord)
    add a,JOYSTICK_J
    ld e,0
    ld b,3
    ld c,1
    call draw_ortho_line
    ld a,(yJoyCoord)
    add a,JOYSTICK_J - 2
    ld (joyCoord),a
    ld a,(xJoyCoord)
    add a,JOYSTICK_X
    ld e,$80
    ld b,1
    ld c,5
    jp draw_ortho_line

; Move the bar of height A, its top at J = D, to H + C across, erasing it
; from where yJoyCoord + B says it was (DrawIndicatorBar).
draw_indicator_bar:
    ld (dib_height),a
    ld a,d
    ld (joyCoord),a
    ld a,c
    ld (dib_w),a
    ld a,b
    ld e,a
    ld d,0
    ld a,h
    ld hl,yJoyCoord
    add hl,de
    ld b,(hl)                   ; the old position
    ld (hl),a
    ld (dib_h),a
    ld a,1
    ld (dl_ortho_erase),a
    ld a,(dib_w)
    add a,b
    ld e,$80
    ld b,1
    ld hl,dib_height
    ld c,(hl)
    call draw_ortho_line
    xor a
    ld (dl_ortho_erase),a
    ld a,(dib_h)
    ld hl,dib_w
    add a,(hl)
    ld e,$80
    ld b,1
    ld hl,dib_height
    ld c,(hl)
    jp draw_ortho_line

dib_height: db 0
dib_w:      db 0
dib_h:      db 0

; UpdateDashboard: the next of indicators 0 to 6, then UpdateDash7To11.
update_dashboard:
    ld a,(indicator0To6)
    inc a
    cp 7
    jr c,.x
    xor a
.x:
    ld (indicator0To6),a
    call update_indicator
    ; fall through

; UpdateDash7To11: the next of indicators 7 to 10, and the slip-and-turn
; indicator's centre.
update_dash_7_to_11:
    ld a,(indicator7To11)
    inc a
    cp 11
    jr c,.x
    ld a,7
.x:
    ld (indicator7To11),a
    call update_indicator
    ld hl,slip_centre_ops
    jp dash_bytes

; The bar under the artificial horizon while the plane is upside down
; (ShowUpsideDownBar); upside_down_bar is the game's record of it.
show_upside_down_bar:
    ld a,(zRotationHi)
    bit 7,a
    jr z,.half
    xor $C0
.half:
    and $C0
    ld hl,upside_down_off_ops
    ld a,0
    jr z,.bar
    ld hl,upside_down_on_ops
    ld a,UPSIDE_DOWN_PATTERN
.bar:
    ld (upside_down_bar),a
    jp dash_bytes

; ---- the radar ------------------------------------------------------------

; The radar line's lengths and direction for heading A, as D = T, E = U,
; A = V: the runway for alien 0, the alien's dot otherwise (GetRadarVector).
; Uses B, C.
get_radar_vector:
    ld b,a
    ld a,(alien)
    or a
    jr z,.runway
    ld de,$0101
    xor a
    ret
.runway:
    ld a,b
    ld (previousCompass),a
    add a,16
    ld c,a                      ; a1
    sub 64
    srl a
    ld b,a
    ld a,c
    and $80
    or b
    xor $C0
    ld b,a                      ; V
    ld a,c
    add a,a                     ; p
    bit 6,a
    ld de,$0204
    jr nz,.done
    rla
    ld de,$0104
    jr nc,.done
    ld de,$0201
.done:
    ld a,b
    ret

; Where object A (the runway, 1, or the alien, 33) is on the radar, redrawn
; there (UpdateRadarBlip).
update_radar_blip:
    ld b,0
    cp ALIEN_OBJECT
    jr nz,.which
    inc b
.which:
    ld c,a
    ld a,b
    ld (alien),a
    MACRO URB_AXIS axis
    ld a,c
    add a,axis * nextAxis
    ld e,a
    ld d,0
    ld hl,xObjectHi
    add hl,de
    ld a,(xPlaneHi + axis)
    ld b,a
    ld a,(hl)
    sub b
    ld (xTemp2Lo + axis),a
    ld a,(xPlaneTop + axis)
    ld b,a
    ld a,0
    sbc a,b
    ld (xTemp2Hi + axis),a
    ENDM
    URB_AXIS 0
    URB_AXIS 1
    URB_AXIS 2
    xor a
    ld c,xTemp2Lo - xTurnHi
    call copy_work_to_point
    xor a
    ld (matrixNumber),a
    ld c,a
    call set_point_coords
    ld a,(zPointHi)
    ld h,a
    ld a,(zPointLo)
    ld l,a
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ld (zPointLo),a
    ld a,(xPointHi)
    ld h,a
    ld a,(xPointLo)
    ld l,a
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l                        ; x16 >> 1, the bit shifted out in the carry
    ld a,l
    adc a,0
    ld (xPointLo),a
    ; fall through

; Erase the runway or the alien from where the radar buffers say, and draw
; it at point 0's low bytes if they are on the radar (DrawRadarBlip).
draw_radar_blip:
    ld a,(previousCompass)
    call get_radar_vector
    ld (drb_v),a
    ld a,(alien)
    ld hl,xRadarBuffer
    add a,l
    ld l,a
    ld b,(hl)
    ld a,(alien)
    ld hl,yRadarBuffer
    add a,l
    ld l,a
    ld c,(hl)
    ld a,(drb_v)
    call dash_erase
    ld a,(alien)
    or a
    jr nz,.not_runway
    ld hl,radar_cross_ops
    call dash_bytes
.not_runway:
    ld a,(xPointHi)
    ld b,a
    ld a,(xPointLo)
    ld c,RADAR_HALF_WIDTH
    call on_radar
    ret nc
    ld a,(zPointHi)
    ld b,a
    ld a,(zPointLo)
    ld c,RADAR_HALF_HEIGHT
    call on_radar
    ret nc
    ld a,(alien)
    ld e,a
    ld d,0
    ld a,(xPointLo)
    add a,RADAR_X
    ld hl,xRadarBuffer
    add hl,de
    ld (hl),a
    ld b,a
    ld a,(zPointLo)
    add a,RADAR_J
    ld hl,yRadarBuffer
    add hl,de
    ld (hl),a
    ld c,a
    push bc
    ld a,(yRotationHi)
    call get_radar_vector
    pop bc
    jp dash_draw

drb_v:  db 0

    ASSERT high xRadarBuffer == high (yRadarBuffer + 1)

; Carry set if radar coordinate A (low byte), with the sign in bit 7 of B,
; is within C either way.
on_radar:
    bit 7,b
    jr z,.magnitude
    neg
.magnitude:
    cp c
    ret

; ResetRadar: the alien off the radar, and object 33 to the origin.
reset_radar:
    ld a,80
    ld (xPointLo),a
    ld a,1
    ld (alien),a
    ld (xPointHi),a
    call draw_radar_blip
    ld c,ALIEN_OBJECT
    jp set_object_to_origin

; ---- the fuel gauge and the lamps ----------------------------------------------

; Every 16th iteration, erase the fuel gauge's pixel at the fuel level
; (UpdateFuelGauge).
update_fuel_gauge:
    ld a,(mainLoopCounter)
    and 15
    ret nz
    ld a,(fuelLevel)
    ld c,$80
    ; fall through

; Draw (bit 7 of C clear) or erase (set) the fuel gauge's pixel for level A
; (DrawFuelPixel).
draw_fuel_pixel:
    add a,FUEL_BOTTOM_J
    ld b,FUEL_X
    ld de,$0101
    bit 7,c
    ld c,a
    ld a,0
    jp nz,dash_erase
    jp dash_draw

; Light (C = 1) or dim (0) lamp A: LAMP_U, LAMP_F, LAMP_B or LAMP_T.
draw_indicator:
    add a,a
    add a,c
    add a,a
    ld e,a
    ld d,0
    ld hl,lamp_ops
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    jp dash_bytes
