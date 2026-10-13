; A camera that drives itself along the middle of the track, for testing the
; renderer before there is a driving model. It sits `cam_frac` of the way
; from segment `cam_seg` to the next, `EYE_HEIGHT` above the road, looking
; at the point the same fraction of the way from three segments ahead to
; four. (One segment ahead is not enough: a new section restarts from its
; own coordinates, which can skew a single step.) Both points move on
; smoothly as the fraction grows, so the view turns smoothly through a
; corner rather than once a segment.
;
; Until there is a driving model, the keys drive the camera: Q or a stick's
; up for faster, A or down for slower, O or left and P or right to move it
; sideways. The sticks are an Interface II's, both of them (6 to 0 and 1 to
; 5). Sideways is square to the way it looks, so it slides across the track
; without turning.

EYE_HEIGHT  equ 500
TRACK_LEN   equ 1024            ; Silverstone; the data's trackLength
LOOK_AHEAD  equ 3
SPEED_STEP  equ 4               ; cam_speed's change an update while a key is held
SIDE_MAX    equ 31              ; cam_side's limit either way: about the track's edge

camera_init:
    ld hl,0
    ld (cam_seg),hl
    xor a
    ld (cam_frac),a
; The four centres the camera works between: this segment's and the next's,
; and LOOK_AHEAD on, that one's and the next's.
camera_centres:
    ld hl,(cam_seg)
    ld (cam_cseg),hl
    ld de,cam_c0
    ld b,0
    call .centre
    ld de,cam_c1
    ld b,1
    call .centre
    ld de,cam_c3
    ld b,LOOK_AHEAD
    call .centre
    ld de,cam_c4
    ld b,LOOK_AHEAD+1
; The centre of segment cam_seg + B into the six bytes at DE.
.centre:
    push de
    ld e,b
    ld d,0
    ld hl,(cam_seg)
    call seg_add
    call seg_centre             ; DE = x, BC = y, HL = z
    ex (sp),hl                  ; HL = where, z on the stack
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (hl),c
    inc hl
    ld (hl),b
    inc hl
    pop de
    ld (hl),e
    inc hl
    ld (hl),d
    ret

camera_update:
    call camera_keys
    ld a,(cam_speed)
    ld b,a
    ld a,(cam_frac)
    add a,b
    ld (cam_frac),a
    jr nc,.moved
    ld hl,(cam_seg)
    ld de,1
    call seg_add
    ld (cam_seg),hl
.moved:
    ; The centres are for cam_cseg. Still there: they stand. One on: they
    ; move on one, and only the two new ones are worked out. Anywhere else
    ; (a test that moves the camera, say): all four afresh.
    ld hl,(cam_seg)
    ld de,(cam_cseg)
    or a
    sbc hl,de
    jr z,.same
    dec hl
    ld a,h
    or l
    jr z,.next
    call camera_centres
    jr .same
.next:
    ld hl,(cam_seg)
    ld (cam_cseg),hl
    ld hl,cam_c1
    ld de,cam_c0
    ld bc,6
    ldir
    ld hl,cam_c4
    ld de,cam_c3
    ld bc,6
    ldir
    ld de,cam_c1
    ld b,1
    call camera_centres.centre
    ld de,cam_c4
    ld b,LOOK_AHEAD+1
    call camera_centres.centre
.same:
    ; Where the camera is: between this segment's centre and the next's.
    ld ix,cam_c0
    call seg_lerp
    ld (cam_x),de
    ld (cam_z),bc
    ld ix,cam_c0+2
    call lerp_y
    ld de,EYE_HEIGHT
    add hl,de
    ld (cam_y),hl
    ; Where it looks: the same way between the two centres further on.
    ld ix,cam_c3
    call seg_lerp
    ld hl,(cam_x)
    ex de,hl
    or a
    sbc hl,de
    ex de,hl                    ; DE = dx
    ld h,b
    ld l,c
    ld bc,(cam_z)
    or a
    sbc hl,bc
    ld b,h
    ld c,l                      ; BC = dz
    ld a,(cam_side)
    or a
    jr z,.ahead
    push bc
    push de
    call yaw_angle
    ld (cam_heading),hl
    ; Sideways: the line of sight turned a quarter left, (-dz, dx), times
    ; cam_side / 128. Both are worked out from a quarter of the line of
    ; sight, so that each is below 256 and lerp needs one multiply, not two;
    ; it is about four segments long, and a segment's vector is a byte.
    pop hl                      ; dx
    call side_offset
    ld de,(cam_z)
    add hl,de
    ld (cam_z),hl               ; z += dx * side / 128
    pop hl                      ; dz
    call side_offset
    ex de,hl
    ld hl,(cam_x)
    or a
    sbc hl,de
    ld (cam_x),hl               ; x -= dz * side / 128
    jr .publish
.ahead:
    call yaw_angle
    ld (cam_heading),hl
.publish:
    ; The verge points take these as constants in their instructions
    ; (VB_POINT's NAME_cx, NAME_cz and NAME_hd), which saves a load from
    ; memory 25 times an update for three stores here.
    ld hl,(cam_x)
    ld (vr_cx+1),hl
    ld (vl_cx+1),hl
    ld hl,(cam_z)
    ld (vr_cz+1),hl
    ld (vl_cz+1),hl
    ld hl,(cam_heading)
    ld (vr_hd+1),hl
    ld (vl_hd+1),hl
    ret

; HL = HL * cam_side / 128, signed: a component of the sideways offset.
side_offset:
    sra h
    rr l
    sra h
    rr l                        ; a quarter
    ld a,(cam_side)
    ld b,a                      ; its sign, for the end
    or a
    jp p,.positive
    neg
.positive:
    add a,a
    add a,a
    add a,a                     ; |side| * 8 < 256: the quarter * |side| / 32
    ld c,a
    ld de,0
    push bc
    call lerp_c                 ; HL = HL * C / 256
    pop bc
    bit 7,b
    ret z
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    ret

; The keys: cam_speed up or down by SPEED_STEP, saturating, and cam_side
; one way or the other by one, up to SIDE_MAX. A key reads 0 while it is
; held, and each of these is a half-row of the keyboard, read through port
; $FE with its row in the high byte.
camera_keys:
    ld e,0                      ; bit 0 faster, 1 slower, 2 left, 3 right
    ld a,$FB                    ; T R E W Q
    in a,($FE)
    rra
    jr c,.no_q
    set 0,e
.no_q:
    ld a,$FD                    ; G F D S A
    in a,($FE)
    rra
    jr c,.no_a
    set 1,e
.no_a:
    ld a,$DF                    ; Y U I O P
    in a,($FE)
    rra
    jr c,.no_p
    set 3,e
.no_p:
    rra
    jr c,.no_o
    set 2,e
.no_o:
    ld a,$EF                    ; 6 7 8 9 0: the first stick
    in a,($FE)
    cpl
    bit 1,a                     ; 9 up
    jr z,.no_9
    set 0,e
.no_9:
    bit 2,a                     ; 8 down
    jr z,.no_8
    set 1,e
.no_8:
    bit 4,a                     ; 6 left
    jr z,.no_6
    set 2,e
.no_6:
    bit 3,a                     ; 7 right
    jr z,.no_7
    set 3,e
.no_7:
    ld a,$F7                    ; 5 4 3 2 1: the second stick
    in a,($FE)
    cpl
    bit 3,a                     ; 4 up
    jr z,.no_4
    set 0,e
.no_4:
    bit 2,a                     ; 3 down
    jr z,.no_3
    set 1,e
.no_3:
    bit 0,a                     ; 1 left
    jr z,.no_1
    set 2,e
.no_1:
    bit 1,a                     ; 2 right
    jr z,.no_2
    set 3,e
.no_2:
    ld a,e
    or a
    ret z
    ld a,(cam_speed)
    bit 0,e
    jr z,.not_faster
    add a,SPEED_STEP
    jr nc,.not_faster
    ld a,255
.not_faster:
    bit 1,e
    jr z,.not_slower
    sub SPEED_STEP
    jr nc,.not_slower
    xor a
.not_slower:
    ld (cam_speed),a
    ld a,(cam_side)
    bit 2,e
    jr z,.not_left
    cp SIDE_MAX
    jr z,.not_left
    inc a
.not_left:
    bit 3,e
    jr z,.not_right
    cp -SIDE_MAX & $FF
    jr z,.not_right
    dec a
.not_right:
    ld (cam_side),a
    ret

; DE = x, BC = z of the point cam_frac of the way from the centre at IX to
; the one 6 bytes on.
seg_lerp:
    ld l,(ix+6)
    ld h,(ix+7)
    ld e,(ix+0)
    ld d,(ix+1)
    call lerp
    push hl
    ld l,(ix+10)
    ld h,(ix+11)
    ld e,(ix+4)
    ld d,(ix+5)
    call lerp
    ld b,h
    ld c,l
    pop de
    ret

; HL = the y cam_frac of the way from the word at IX to the word 6 on.
lerp_y:
    ld l,(ix+6)
    ld h,(ix+7)
    ld e,(ix+0)
    ld d,(ix+1)
    ; fall into lerp

; HL = DE + (HL - DE) * cam_frac / 256, for any difference that fits 16
; bits: |d| * frac / 256 = high(|d|) * frac + low(|d|) * frac / 256.
lerp:
    ld a,(cam_frac)
    ld c,a
; The same with C for cam_frac.
lerp_c:
    or a
    sbc hl,de
    push de
    ld a,h
    push af                     ; the difference's sign
    bit 7,h
    jr z,.positive
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
.positive:
    ld a,h
    or a
    jr nz,.wide
    ld a,l                      ; below 256, as steps between centres are:
    call mul8                   ; low(|d|) * frac / 256
    ld l,h
    ld h,0
    jr .sum
.wide:
    push hl
    ld a,l
    call mul8                   ; low(|d|) * frac
    ld a,h                      ; / 256
    pop hl
    push af
    ld a,h
    call mul8                   ; high(|d|) * frac
    pop af
    add a,l
    ld l,a
    jr nc,.sum
    inc h
.sum:
    pop af
    bit 7,a
    jr z,.add
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
.add:
    pop de
    add hl,de
    ret

; HL = A * C, unsigned. Uses A, B, DE.
mul8:
    ld hl,0
    ld d,h
    ld e,c
    ld b,8
.bit:
    add hl,hl
    add a,a
    jr nc,.next
    add hl,de
.next:
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
cam_side:    db 0             ; sideways, -SIDE_MAX (right) to SIDE_MAX (left)
cam_x:       dw 0
cam_y:       dw 0
cam_z:       dw 0
cam_heading: dw 0
cam_cseg: dw $FFFF              ; the segment the centres are for
cam_c0: ds 6                    ; segment centres: x, y, z
cam_c1: ds 6
cam_c3: ds 6
cam_c4: ds 6
