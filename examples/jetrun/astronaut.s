; The astronaut: controls, physics and the view that follows.
;
; Exactly game.py's move(): positions in 256ths of a pixel (ax, ay: the
; fraction, then the pixel as a word), speeds in 256ths of a pixel a pass.
; The rock is probed where the screen shows it: a pair of pixels with either
; set is rock (the checker), black is sky; inside the sprite's own box the
; probe reads what was saved from under it instead. check.py compares every
; pass with the model.

; ---------------------------------------------------------------------------
; read_controls: Interface II (player 1: 6 left, 7 right, 8 down, 9 up, 0
; fire) and the keys Q up, A down, O left, P right, SPACE fire, into
; controls: RIGHT, LEFT, DOWN, UP, FIRE as bits 0-4.

read_controls:
    ld c,0
    ld a,0xEF               ; 6 7 8 9 0, active low
    in a,(0xFE)
    cpl
    rra
    jr nc,.no_0
    set 4,c                 ; 0: fire
.no_0:
    rra
    jr nc,.no_9
    set 3,c                 ; 9: up
.no_9:
    rra
    jr nc,.no_8
    set 2,c                 ; 8: down
.no_8:
    rra
    jr nc,.no_7
    set 0,c                 ; 7: right
.no_7:
    rra
    jr nc,.no_6
    set 1,c                 ; 6: left
.no_6:
    ld a,0xFB               ; Q
    in a,(0xFE)
    rra
    jr c,.no_q
    set 3,c
.no_q:
    ld a,0xFD               ; A
    in a,(0xFE)
    rra
    jr c,.no_a
    set 2,c
.no_a:
    ld a,0xDF               ; P, O
    in a,(0xFE)
    rra
    jr c,.no_p
    set 0,c
.no_p:
    rra
    jr c,.no_o
    set 1,c
.no_o:
    ld a,0x7F               ; SPACE
    in a,(0xFE)
    rra
    jr c,.no_space
    set 4,c
.no_space:
    ld a,c
    ld (controls),a
    ret

; ---------------------------------------------------------------------------
; rock: whether world pixel HL, DE (x, y; 16-bit) is rock. NZ if it is.

rock:
    bit 7,d
    jp nz,.above            ; nothing flies above CEILING
    ld a,d
    or a
    jr nz,.below_ceiling
    ld a,e
    cp CEILING
    jp c,.above
.below_ceiling:
    push de
    ld de,(view_x)
    or a
    sbc hl,de
    bit 7,h
    jr z,.not_west
    ld de,WORLD_W           ; behind the view across the seam
    add hl,de
.not_west:
    ld de,WORLD_W
    or a
    sbc hl,de
    jr nc,.east
    add hl,de
.east:
    ld a,l
    add a,PLAY_LEFT
    ld (rk_sx),a
    pop hl
    ld de,(view_y)
    or a
    sbc hl,de
    ld a,l
    add a,PLAY_TOP
    ld (rk_sy),a
    ld c,a
    ; Inside the sprite's box: the saved bytes.
    ld a,(drawn_x)
    rra
    rra
    rra
    and 0x1F
    ld b,a                  ; the sprite's first column
    ld a,(rk_sx)
    rra
    rra
    rra
    and 0x1F
    ld (rk_col),a
    sub b
    cp 3
    jr nc,.screen
    ld e,a                  ; the column within the sprite: 0-2
    ld a,(drawn_y)
    ld b,a
    ld a,c
    sub b
    cp SPRITE_H
    jr nc,.screen
    ld l,a                  ; saved[row * 3 + column]
    ld h,0
    ld d,h
    add hl,hl
    add a,l
    ld l,a
    add hl,de
    ld de,sprite_saved
    add hl,de
    ld a,(hl)
    jr .test
.screen:
    ld a,(rk_col)
    call screen_address
    ld a,(de)
.test:
    ld b,a
    ld a,(rk_sx)
    and 6
    rra
    ld e,a
    ld d,0
    ld hl,pair_masks
    add hl,de
    ld a,(hl)
    and b
    ret
.above:
    or 1
    ret

pair_masks:
    db 0xC0, 0x30, 0x0C, 0x03

; row_rock: any rock in world row DE across the body, the sprite's left at
; HL: x from HL + BODY_LEFT to HL + BODY_RIGHT. NZ if any.
row_rock:
    ld bc,BODY_LEFT
    add hl,bc
    ld b,BODY_RIGHT - BODY_LEFT + 1
.pixel:
    push bc
    push hl
    push de
    call rock
    pop de
    pop hl
    pop bc
    ret nz
    inc hl
    djnz .pixel
    ret                     ; Z: none

; column_rock: any rock in world column HL from row DE + B to DE + C. NZ if
; any.
column_rock:
    push hl
    ld l,b
    ld h,0
    add hl,de
    ex de,hl                ; DE = the first row
    pop hl
    ld a,c
    sub b
    inc a
    ld b,a
.pixel:
    push bc
    push hl
    push de
    call rock
    pop de
    pop hl
    pop bc
    ret nz
    inc de
    djnz .pixel
    ret

; ---------------------------------------------------------------------------
; clamp_speed: HL kept within -MAX_SPEED to MAX_SPEED.
clamp_speed:
    bit 7,h
    jr nz,.negative
    push hl
    ld de,MAX_SPEED + 1
    or a
    sbc hl,de
    pop hl
    ret c
    ld hl,MAX_SPEED
    ret
.negative:
    push hl
    ld de,MAX_SPEED
    add hl,de
    bit 7,h
    pop hl
    ret z
    ld hl,-MAX_SPEED
    ret

; wrap_x: HL brought into 0 to WORLD_W - 1, from a step either side.
wrap_x:
    bit 7,h
    jr z,.not_negative
    ld de,WORLD_W
    add hl,de
    ret
.not_negative:
    ld de,WORLD_W
    or a
    sbc hl,de
    ret nc
    add hl,de
    ret

; ---------------------------------------------------------------------------
; move: a pass of the astronaut, from controls; then the view follows.

move:
    ld a,(controls)
    ld (keys),a
    bit 3,a                 ; UP: thrust
    jr z,.no_thrust
    ld hl,(vy)
    ld de,THRUST
    or a
    sbc hl,de
    ld (vy),hl
    xor a
    ld (on_ground),a
.no_thrust:
    ld hl,(vy)
    ld de,GRAVITY
    add hl,de
    ld (vy),hl

    ld a,(on_ground)
    or a
    jr z,.air
    ld a,(keys)             ; on the ground: walk or stand
    ld hl,WALK
    bit 0,a
    jr nz,.set_vx
    ld hl,-WALK
    bit 1,a
    jr nz,.set_vx
    ld hl,0
.set_vx:
    ld (vx),hl
    jr .clamp
.air:
    ld a,(keys)
    ld hl,(vx)
    bit 0,a
    jr z,.not_right
    ld de,ACCEL
    add hl,de
    jr .vx_done
.not_right:
    bit 1,a
    jr z,.drag
    ld de,ACCEL
    or a
    sbc hl,de
    jr .vx_done
.drag:
    ld d,h                  ; vx -= vx >> 4, arithmetic
    ld e,l
    sra d
    rr e
    sra d
    rr e
    sra d
    rr e
    sra d
    rr e
    or a
    sbc hl,de
.vx_done:
    ld (vx),hl
.clamp:
    ld hl,(vx)
    call clamp_speed
    ld (vx),hl
    ld hl,(vy)
    call clamp_speed
    ld (vy),hl
    ld a,(keys)
    bit 0,a
    jr z,.not_facing_right
    xor a
    ld (facing),a
    jr .faced
.not_facing_right:
    bit 1,a
    jr z,.faced
    ld a,1
    ld (facing),a
.faced:

    ; ---- across, a pixel at a time ----
    ld hl,(vx)              ; target = ax + vx, 24-bit
    ld a,h
    ld e,a
    add a,a
    sbc a,a
    ld d,a
    ld a,(ax)
    add a,l
    ld (target),a
    ld hl,(ax + 1)
    adc hl,de
    ld (target + 1),hl
    ld de,(ax + 1)          ; steps = target pixel - pixel
    ld (mv_px),de
    ld de,(ay + 1)
    ld (mv_py),de
    ld de,(ax + 1)
    or a
    sbc hl,de
    ld a,l                  ; small: -2 to 2
    ld (mv_steps),a
    xor a
    ld (mv_blocked),a
    ld (mv_climbed),a
    ld a,(mv_steps)
    or a
    jp z,.across_done
.across:
    ld a,(mv_steps)
    or a
    jp z,.across_done
    ; the column just beyond the body on the leading side
    ld hl,(mv_px)
    bit 7,a
    ld de,BODY_RIGHT + 1
    jr z,.lead
    ld de,BODY_LEFT - 1
.lead:
    add hl,de
    ld (mv_lead),hl
    ld de,(mv_py)
    ld b,BODY_TOP
    ld c,BODY_BOTTOM
    call column_rock
    jr z,.step_across
    ; blocked: on the ground, try climbing up to CLIMB pixels (a slope,
    ; the ground's texture)
    ld a,(on_ground)
    or a
    jr z,.blocked_across
    ld a,1
.climb:
    ld (mv_up),a
    ld hl,(mv_py)           ; DE = py - up
    ld e,a
    ld d,0
    or a
    sbc hl,de
    ld (mv_high),hl
    ld de,BODY_TOP          ; head room: the row above the head, that high
    add hl,de
    ex de,hl
    ld hl,(mv_px)
    call row_rock
    jr nz,.blocked_across
    ld hl,(mv_lead)         ; the lead column, the body that high
    ld de,(mv_high)
    ld b,BODY_TOP
    ld c,BODY_BOTTOM
    call column_rock
    jr z,.climbed
    ld a,(mv_up)
    inc a
    cp CLIMB + 1
    jr c,.climb
    jr .blocked_across
.climbed:
    ld a,(mv_climbed)       ; no more than CLIMB in all, in a pass
    ld b,a
    ld a,(mv_up)
    add a,b
    cp CLIMB + 1
    jr nc,.blocked_across
    ld (mv_climbed),a
    ld hl,(mv_high)
    ld (mv_py),hl
.step_across:
    ld hl,(mv_px)
    ld a,(mv_steps)
    bit 7,a
    jr nz,.step_left
    inc hl
    dec a
    jr .stepped
.step_left:
    dec hl
    inc a
.stepped:
    ld (mv_px),hl
    ld (mv_steps),a
    jp .across
.blocked_across:
    ld a,1
    ld (mv_blocked),a
.across_done:
    ld a,(mv_blocked)
    or a
    jr z,.free_across
    ld hl,0
    ld (vx),hl
    ld hl,(mv_px)
    call wrap_x
    ld (ax + 1),hl
    ld a,0x80
    ld (ax),a
    jr .across_set
.free_across:
    ld a,(target)
    ld (ax),a
    ld hl,(target + 1)
    call wrap_x
    ld (ax + 1),hl
.across_set:
    ld hl,(mv_py)
    ld (ay + 1),hl

    ; ---- down or up, a pixel at a time ----
    ld hl,(vy)
    ld a,h
    ld e,a
    add a,a
    sbc a,a
    ld d,a
    ld a,(ay)
    add a,l
    ld (target),a
    ld hl,(ay + 1)
    adc hl,de
    ld (target + 1),hl
    ld de,(ay + 1)
    or a
    sbc hl,de
    ld a,l
    ld (mv_steps),a
    xor a
    ld (mv_blocked),a
.vertical:
    ld a,(mv_steps)
    or a
    jr z,.vertical_done
    ld hl,(mv_py)
    bit 7,a
    ld de,BODY_BOTTOM + 1
    jr z,.edge
    ld de,BODY_TOP - 1
.edge:
    add hl,de
    ex de,hl
    ld hl,(ax + 1)
    call row_rock
    jr nz,.blocked_vertical
    ld hl,(mv_py)
    ld a,(mv_steps)
    bit 7,a
    jr nz,.step_up
    inc hl
    dec a
    jr .stepped_vertical
.step_up:
    dec hl
    inc a
.stepped_vertical:
    ld (mv_py),hl
    ld (mv_steps),a
    jr .vertical
.blocked_vertical:
    ld a,1
    ld (mv_blocked),a
.vertical_done:
    ld a,(mv_blocked)
    or a
    jr z,.free_vertical
    ld hl,0
    ld (vy),hl
    ld hl,(mv_py)
    ld (ay + 1),hl
    ld a,0x80
    ld (ay),a
    ld a,(mv_steps)         ; blocked going down: landed
    bit 7,a
    jr nz,.standing
    ld a,1
    ld (on_ground),a
    jr .standing
.free_vertical:
    ld a,(target)
    ld (ay),a
    ld hl,(target + 1)
    ld (ay + 1),hl

    ; ---- standing, walking down a slope, or falling ----
.standing:
    ld a,(keys)
    bit 3,a
    jr nz,.pose
    ld hl,(ay + 1)
    ld de,BODY_BOTTOM + 1
    add hl,de
    ex de,hl
    ld hl,(ax + 1)
    call row_rock
    jr z,.not_on_rock
    ld a,1
    ld (on_ground),a
    ld hl,0
    ld (vy),hl
    jr .pose
.not_on_rock:
    ld a,(on_ground)
    or a
    jr z,.falling
    ld b,1                  ; rock up to CLIMB below the feet: walk down to it
.drop:
    push bc
    ld hl,(ay + 1)
    ld de,BODY_BOTTOM + 1
    add hl,de
    ld e,b
    ld d,0
    add hl,de
    ex de,hl
    ld hl,(ax + 1)
    call row_rock
    pop bc
    jr nz,.dropped
    inc b
    ld a,b
    cp CLIMB + 1
    jr c,.drop
    jr .falling
.dropped:
    ld hl,(ay + 1)          ; down the slope
    ld e,b
    ld d,0
    add hl,de
    ld (ay + 1),hl
    ld hl,0
    ld (vy),hl
    jr .pose
.falling:
    xor a
    ld (on_ground),a

    ; ---- the frame: standing, walking, or flying ----
.pose:
    ld a,(on_ground)
    or a
    ld b,3                  ; flying
    jr z,.posed
    ld a,(keys)
    and 3
    ld b,0                  ; standing
    jr z,.posed
    ld a,(passes)
    rra
    rra
    and 1
    inc a
    ld b,a                  ; walking: 1 or 2, a frame every four passes
.posed:
    ld a,(facing)
    add a,a
    add a,a
    add a,b
    ld (frame),a

    ; ---- the view follows: the sprite at the centre, as far as Cyberun's
    ; renderer can scroll in a pass (2 across; 2 or 4 down, 4 only from a
    ; view_y that is a multiple of 4) ----
    ld hl,(ax + 1)          ; dx = (px AND -2) - CENTRE_X - view_x, wrapped
    res 0,l
    ld de,CENTRE_X
    or a
    sbc hl,de
    call wrap_x             ; the view the sprite wants, 0 .. WORLD_W - 1
    ld de,(view_x)
    or a
    sbc hl,de               ; -WORLD_W .. WORLD_W: the short way round
    bit 7,h
    jr nz,.dx_negative
    ld de,WORLD_W / 2
    or a
    sbc hl,de
    jr c,.dx_near
    ld de,WORLD_W / 2 - WORLD_W
.dx_near:
    add hl,de
    jr .dx_clamp
.dx_negative:
    ld de,WORLD_W / 2
    add hl,de
    bit 7,h
    jr nz,.dx_near_negative
    ld de,-WORLD_W / 2
.dx_near_negative:
    add hl,de
.dx_clamp:
    ld a,h                  ; clamp to -MOVE .. MOVE
    bit 7,a
    jr nz,.dx_minus
    or a
    jr nz,.dx_plus_max
    ld a,l
    cp MOVE + 1
    jr c,.dx_set
.dx_plus_max:
    ld a,MOVE
    jr .dx_set
.dx_minus:
    inc a
    jr nz,.dx_minus_max
    ld a,l
    cp -MOVE
    jr nc,.dx_set
.dx_minus_max:
    ld a,-MOVE
.dx_set:
    ld e,a
    add a,a
    sbc a,a
    ld d,a
    ld hl,(view_x)
    add hl,de
    call wrap_x
    ld (view_x),hl
    ld hl,(ay + 1)          ; dy = (py AND -2) - CENTRE_Y - view_y
    res 0,l
    ld de,CENTRE_Y
    or a
    sbc hl,de
    ld de,(view_y)
    or a
    sbc hl,de
    ld a,h                  ; clamp to -VIEW_STEP_Y .. VIEW_STEP_Y
    bit 7,a
    jr nz,.dy_minus
    or a
    jr nz,.dy_plus_max
    ld a,l
    cp VIEW_STEP_Y + 1
    jr c,.dy_halve
.dy_plus_max:
    ld a,VIEW_STEP_Y
    jr .dy_halve
.dy_minus:
    inc a
    jr nz,.dy_minus_max
    ld a,l
    cp -VIEW_STEP_Y
    jr nc,.dy_halve
.dy_minus_max:
    ld a,-VIEW_STEP_Y
.dy_halve:
    ld b,a                  ; a step of 4 from view_y AND 2: only 2
    cp VIEW_STEP_Y
    jr z,.dy_four
    cp -VIEW_STEP_Y
    jr nz,.dy_set
.dy_four:
    ld a,(view_y)
    and 2
    ld a,b
    jr z,.dy_set
    sra a
.dy_set:
    ld e,a
    add a,a
    sbc a,a
    ld d,a
    ld hl,(view_y)
    add hl,de
    ld (view_y),hl
.viewed:
    ld hl,passes
    inc (hl)
    ret
