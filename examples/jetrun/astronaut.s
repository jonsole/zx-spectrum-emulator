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
; The rock probes. Rock is read from the screen a byte at a time: a pair of
; pixels with either set is rock (the checker), so a byte answers for four
; pairs at once under a mask, and a column is walked down the screen rather
; than worked out again for every row. Inside the sprite's box the bytes come
; from what was saved from under it, so the astronaut never collides with
; itself. game.py's rock() asks the same question a pixel at a time; the
; answers are the same.

; above: carry if world row DE is above CEILING: nothing flies there.
above:
    bit 7,d
    scf
    ret nz
    ld a,d
    or a
    ret nz                  ; carry clear
    ld a,e
    cp CEILING
    ret

; to_screen: world pixel HL, DE (x, y; 16-bit) on the screen: rk_sx, and
; rk_sy in C.
to_screen:
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
    ret

; mask_of: A = the mask from table HL for the pair at screen x A.
mask_of:
    and 6
    rra
    add a,l
    ld l,a
    jr nc,.same_page
    inc h
.same_page:
    ld a,(hl)
    ret

; probe_byte: A = the byte rock is read from at screen column B, row C: what
; was saved from under the sprite inside its box, else the screen's.
probe_byte:
    ld a,(drawn_y)
    ld e,a
    ld a,c
    sub e
    cp SPRITE_H
    jr nc,.screen
    ld e,a                  ; the row within the box
    ld a,(drawn_x)
    rra
    rra
    rra
    and 0x1F
    ld d,a
    ld a,b
    sub d
    cp 3
    jr nc,.screen
    ld d,a                  ; saved[row * 3 + column]
    ld a,e
    add a,a
    add a,e
    add a,d
    ld e,a
    ld d,0
    ld hl,sprite_saved
    add hl,de
    ld a,(hl)
    ret
.screen:
    ld a,b
    call screen_address
    ld a,(de)
    ret

pair_masks:                 ; one pair
    db 0xC0, 0x30, 0x0C, 0x03
first_masks:                ; a pair and those right of it in the byte
    db 0xFF, 0x3F, 0x0F, 0x03
last_masks:                 ; a pair and those left of it
    db 0xC0, 0xF0, 0xFC, 0xFF

; row_rock: any rock in world row DE across the body, the sprite's left at
; HL: x from HL + BODY_LEFT to HL + BODY_RIGHT. NZ if any. Two or three
; bytes: the first and last masked down to the body's pairs.
row_rock:
    call above
    jr nc,.below
    or 1
    ret
.below:
    ld bc,BODY_LEFT
    add hl,bc
    call to_screen          ; C = the screen row
    ld a,(rk_sx)
    ld hl,first_masks
    call mask_of
    ld (rr_mask),a
    ld a,(rk_sx)
    add a,BODY_RIGHT - BODY_LEFT
    ld d,a                  ; the last pixel's x
    ld hl,last_masks
    call mask_of
    ld (rr_last),a
    ld a,(rk_sx)
    rra
    rra
    rra
    and 0x1F
    ld b,a                  ; the first column
    ld a,d
    rra
    rra
    rra
    and 0x1F
    sub b
    ld (rr_count),a         ; columns after the first: 1 or 2
.byte:
    push bc
    call probe_byte
    pop bc
    ld e,a
    ld a,(rr_count)
    or a
    ld a,(rr_mask)
    jr nz,.not_last
    ld d,a
    ld a,(rr_last)
    and d
.not_last:
    and e
    ret nz
    ld a,(rr_count)
    sub 1
    jr c,.none
    ld (rr_count),a
    ld a,0xFF
    ld (rr_mask),a
    inc b
    jr .byte
.none:
    xor a                   ; Z: none
    ret

; column_rock: any rock in world column HL from row DE + B to DE + C. NZ if
; any. The rows above the sprite's box, in it and below it are each walked
; in a run.
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
    ld (cr_count),a
    call above              ; the first row is the highest
    jr nc,.below
    or 1
    ret
.below:
    call to_screen          ; C = the first screen row
    ld a,(rk_sx)
    ld hl,pair_masks
    call mask_of
    ld (cr_mask),a
    ld a,(rk_sx)
    rra
    rra
    rra
    and 0x1F
    ld (rk_col),a
    ld b,a
    ld a,(drawn_x)
    rra
    rra
    rra
    and 0x1F
    ld d,a
    ld a,b
    sub d
    cp 3
    jr nc,.rest             ; outside the box's columns: all from the screen
    ld (cr_offset),a
    ld a,(drawn_y)          ; the rows above the box
    sub c
    jr c,.box
    jr z,.box
    ld b,a
    ld a,(cr_count)
    cp b
    jr nc,.above_box
    ld b,a
.above_box:
    call column_screen
    ret nz
    ld a,(cr_count)
    or a
    ret z
.box:
    ld a,(drawn_y)          ; the rows in the box
    ld b,a
    ld a,c
    sub b
    cp SPRITE_H
    jr nc,.rest
    ld e,a                  ; the row within the box
    ld a,SPRITE_H
    sub e
    ld b,a                  ; its rows from there
    ld a,(cr_count)
    cp b
    jr nc,.in_box
    ld b,a
.in_box:
    sub b
    ld (cr_count),a
    ld a,c
    add a,b
    ld (cr_row),a           ; the row after them
    ld a,e                  ; saved[row * 3 + column]
    add a,a
    add a,e
    ld e,a
    ld a,(cr_offset)
    add a,e
    ld e,a
    ld d,0
    ld hl,sprite_saved
    add hl,de
    ld de,3
    ld a,(cr_mask)
    ld c,a
.saved:
    ld a,(hl)
    and c
    ret nz
    add hl,de
    djnz .saved
    ld a,(cr_count)
    or a
    ret z
    ld a,(cr_row)
    ld c,a
.rest:
    ld a,(cr_count)         ; the rest, from the screen
    ld b,a
    ; on into column_screen

; column_screen: B rows down the screen from row C in column rk_col, under
; cr_mask. NZ at rock; C moves past them and cr_count goes down by B.
column_screen:
    ld a,(cr_count)
    sub b
    ld (cr_count),a
    ld a,c
    add a,b
    push af                 ; the row after them
    ld a,(rk_col)
    call screen_address
    ex de,hl
    ld a,(cr_mask)
    ld c,a
.row:
    ld a,(hl)
    and c
    jr nz,.rock
    inc h                   ; next_row's step down a line
    ld a,h
    and 7
    jr nz,.next
    ld a,l
    add a,0x20
    ld l,a
    jr c,.next
    ld a,h
    sub 8
    ld h,a
.next:
    djnz .row
    pop af
    ld c,a
    xor a                   ; Z: none
    ret
.rock:
    pop af
    ld c,a
    or 1
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
