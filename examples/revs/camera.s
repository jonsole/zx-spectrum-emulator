; A camera that drives itself along the middle of the track, for testing the
; renderer before there is a driving model. It sits `cam_frac` of the way
; from segment `cam_seg` to the next, `EYE_HEIGHT` above the road, looking
; along the track three segments ahead (one step can be skewed where a new
; section restarts from its own coordinates).

EYE_HEIGHT  equ 500
TRACK_LEN   equ 1024            ; Silverstone; the data's trackLength

camera_init:
    ld hl,0
    ld (cam_seg),hl
    xor a
    ld (cam_frac),a
    ret

camera_update:
    ld a,(cam_speed)
    ld b,a
    ld a,(cam_frac)
    add a,b
    ld (cam_frac),a
    jr nc,.same
    ld hl,(cam_seg)
    ld de,1
    call seg_add
    ld (cam_seg),hl
.same:
    ; c0 = this segment's centre, c1 the next one's, c3 three ahead.
    ld hl,(cam_seg)
    call seg_centre
    ld (c0x),de
    ld (c0y),bc
    ld (c0z),hl
    ld hl,(cam_seg)
    ld de,1
    call seg_add
    call seg_centre
    ld (c1x),de
    ld (c1y),bc
    ld (c1z),hl
    ld hl,(cam_seg)
    ld de,3
    call seg_add
    call seg_centre
    ; heading = the yaw of c3 - c0
    ld bc,(c0z)
    or a
    sbc hl,bc
    push hl                     ; dz
    ex de,hl
    ld bc,(c0x)
    or a
    sbc hl,bc
    ex de,hl                    ; DE = dx
    pop bc                      ; BC = dz
    call yaw_angle
    ld (cam_heading),hl
    ; position = c0 + (c1 - c0) * frac / 256
    ld hl,(c1x)
    ld de,(c0x)
    call lerp
    ld (cam_x),hl
    ld hl,(c1y)
    ld de,(c0y)
    call lerp
    ld de,EYE_HEIGHT
    add hl,de
    ld (cam_y),hl
    ld hl,(c1z)
    ld de,(c0z)
    call lerp
    ld (cam_z),hl
    ret

; HL = DE + (HL - DE) * cam_frac / 256, for a small difference (-128..127).
lerp:
    or a
    sbc hl,de
    ld a,(cam_frac)
    ld b,a
    ld a,l                      ; the difference, signed 8-bit
    push de
    call mul_s8_u8              ; HL = A * B, signed
    ld l,h                      ; / 256
    ld a,h
    rlca
    sbc a,a
    ld h,a
    pop de
    add hl,de
    ret

; HL = A (signed) * B (unsigned). Uses C, DE.
mul_s8_u8:
    ld c,a
    ld e,a
    rlca
    sbc a,a
    ld d,a                      ; DE = A sign extended
    ld hl,0
    ld a,b
    ld b,8
.bit:
    add hl,hl
    rla
    jr nc,.skip
    add hl,de
.skip:
    djnz .bit
    ret

; HL = (HL + DE) mod TRACK_LEN, for 0 <= DE < TRACK_LEN.
seg_add:
    add hl,de
    ld de,TRACK_LEN
    or a
    sbc hl,de
    ret nc
    add hl,de
    ret

; HL = (HL - DE) mod TRACK_LEN.
seg_sub:
    or a
    sbc hl,de
    ret nc
    ld de,TRACK_LEN
    add hl,de
    ret

; The centre of segment HL: DE = x, BC = y, HL = z.
seg_centre:
    add hl,hl
    push hl
    ld de,SEG_XI
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    pop hl
    push hl
    ld bc,SEG_XO
    add hl,bc
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    call midpoint
    ex (sp),hl                  ; stack = x, HL = offset
    push hl
    ld de,SEG_YI
    add hl,de
    ld c,(hl)
    inc hl
    ld b,(hl)
    pop hl
    push hl
    ld de,SEG_ZI
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    pop hl
    push bc
    ld bc,SEG_ZO
    add hl,bc
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    call midpoint
    pop bc
    pop de
    ret

; HL = halfway from DE to HL. Not (DE + HL) / 2: the sum of two coordinates
; can overflow 16 bits where their difference, a track's width, cannot.
midpoint:
    or a
    sbc hl,de
    sra h
    rr l
    add hl,de
    ret

cam_seg:     dw 0
cam_frac:    db 0
cam_speed:   db 160           ; a 256th of a segment per update
cam_x:       dw 0
cam_y:       dw 0
cam_z:       dw 0
cam_heading: dw 0
c0x: dw 0
c0y: dw 0
c0z: dw 0
c1x: dw 0
c1y: dw 0
c1z: dw 0
