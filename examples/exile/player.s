; The astronaut: his jetpack, his momentum, and the rock he bumps into.
;
; Position is in pixels of the planet (0..2047 each way) with a byte of
; fraction below; velocity is signed 8.8 pixels a frame. Every frame adds the
; forces to the velocity, then moves him one pixel at a time along each axis,
; testing his whole body against the rock at each pixel -- he never moves more
; than a few a frame, and stepping is what lets him stop exactly against a
; wall, and walk up a gentle slope, rather than sink into it.
;
; The rock he tests is the blocks' collision masks -- blocks.png's white and
; grey: what is drawn as rock is solid, to the pixel.

; Forces, in 8.8 pixels per frame per frame.
GRAVITY     equ 0x0010
THRUST      equ 0x0028      ; Q: more than gravity, so he rises
PUSH_DOWN   equ 0x0010      ; A
SIDE_AIR    equ 0x0014      ; O/P in flight
SIDE_GROUND equ 0x0020      ; O/P with his feet down: he can run
MAX_SPEED   equ 0x0300      ; 3 pixels a frame, either way: no step skips a wall
BOUNCE      equ 0x0180      ; landing faster than this bounces

; Keys, as read_keys leaves them.
KEY_UP      equ 0
KEY_DOWN    equ 1
KEY_LEFT    equ 2
KEY_RIGHT   equ 3

; Where he starts: above the brick landing pad, in map.txt's sky.
START_X     equ 758
START_Y     equ 600

player_init:
    ld hl,START_X
    ld (pos_x + 1),hl
    ld hl,START_Y
    ld (pos_y + 1),hl
    ld a,0x80
    ld (pos_x),a
    ld (pos_y),a
    ld hl,0
    ld (vel_x),hl
    ld (vel_y),hl
    xor a
    ld (on_ground),a
    ld (facing),a
    ld (thrusting),a
    ld (have_old),a
    ret

read_keys:
    ld c,0
    ld a,0xFB               ; Q W E R T
    in a,(0xFE)
    bit 0,a
    jr nz,.not_q
    set KEY_UP,c
.not_q:
    ld a,0xFD               ; A S D F G
    in a,(0xFE)
    bit 0,a
    jr nz,.not_a
    set KEY_DOWN,c
.not_a:
    ld a,0xDF               ; P O I U Y
    in a,(0xFE)
    bit 1,a
    jr nz,.not_o
    set KEY_LEFT,c
.not_o:
    bit 0,a
    jr nz,.not_p
    set KEY_RIGHT,c
.not_p:
    ld a,c
    ld (keys),a
    ret

physics:
    ; Up and down.
    ld hl,(vel_y)
    ld de,GRAVITY
    add hl,de
    ld a,(keys)
    bit KEY_UP,a
    jr z,.no_thrust
    ld de,-THRUST
    add hl,de
.no_thrust:
    bit KEY_DOWN,a
    jr z,.no_push
    ld de,PUSH_DOWN
    add hl,de
.no_push:
    call drag
    call clamp_speed
    ld (vel_y),hl

    ; Across.
    ld hl,(vel_x)
    ld de,SIDE_AIR
    ld a,(on_ground)
    or a
    jr z,.side
    ld de,SIDE_GROUND
.side:
    ld a,(keys)
    bit KEY_LEFT,a
    jr z,.no_left
    or a
    sbc hl,de
    ld a,1
    ld (facing),a
    ld a,(keys)
.no_left:
    bit KEY_RIGHT,a
    jr z,.no_right
    add hl,de
    xor a
    ld (facing),a
    ld a,(keys)
.no_right:
    ; Feet down and no key across: he skids to a stop.
    and (1 << KEY_LEFT) | (1 << KEY_RIGHT)
    jr nz,.no_friction
    ld a,(on_ground)
    or a
    jr z,.no_friction
    push hl
    sra h
    rr l
    sra h
    rr l
    ex de,hl
    pop hl
    or a
    sbc hl,de
.no_friction:
    call drag
    call clamp_speed
    ld (vel_x),hl

    ld a,(keys)
    and 1 << KEY_UP
    ld (thrusting),a

    call move_x
    call move_y

    ; Standing on something?
    ld hl,(pos_x + 1)
    ld de,(pos_y + 1)
    inc de
    call body_blocked
    sbc a,a
    and 1
    ld (on_ground),a
    ret

; drag -- HL -= HL >> 5, signed: air resistance, so speed tops out. Uses DE.
drag:
    push hl
    sra h
    rr l
    sra h
    rr l
    sra h
    rr l
    sra h
    rr l
    sra h
    rr l
    ex de,hl
    pop hl
    or a
    sbc hl,de
    ret

; clamp_speed -- HL, signed, held to +-MAX_SPEED. Uses DE.
clamp_speed:
    bit 7,h
    jr nz,.negative
    push hl
    ld de,MAX_SPEED
    or a
    sbc hl,de
    pop hl
    ret c
    ld hl,MAX_SPEED
    ret
.negative:
    push hl
    ld de,MAX_SPEED
    add hl,de               ; carries out if HL >= -MAX_SPEED
    pop hl
    ret c
    ld hl,-MAX_SPEED
    ret

; move_x -- moves him across by vel_x, a pixel at a time.
move_x:
    ld a,(vel_x + 1)
    ld e,a
    ld d,0
    rla
    jr nc,.forward
    ld d,0xFF               ; DE = the velocity's whole pixels, sign-extended
.forward:
    ld a,(pos_x)
    ld b,a
    ld a,(vel_x)
    add a,b
    ld (target_frac),a
    ld hl,(pos_x + 1)
    adc hl,de
    ld de,(pos_x + 1)
    or a
    sbc hl,de               ; the whole pixels to move: a few, either way
    ld a,l
    or a
    jr z,.arrived
    bit 7,a
    jr nz,.left
    ld b,a
.right_step:
    push bc
    ld hl,(pos_x + 1)
    inc hl
    call step_x
    pop bc
    jr c,.hit
    djnz .right_step
    jr .arrived
.left:
    neg
    ld b,a
.left_step:
    push bc
    ld hl,(pos_x + 1)
    dec hl
    call step_x
    pop bc
    jr c,.hit
    djnz .left_step
.arrived:
    ld a,(target_frac)
    ld (pos_x),a
    ret
.hit:
    ; A wall: he rebounds off it at a quarter of the speed.
    ld hl,(vel_x)
    call rebound
    ld (vel_x),hl
    ld a,0x80
    ld (pos_x),a
    ret

; step_x -- tries moving him across to x = HL. Carry if the rock stops him.
; If his feet are down and only a low step is in the way, he goes up it.
step_x:
    ld de,(pos_y + 1)
    call body_blocked
    jr nc,.go
    ld a,(on_ground)
    or a
    scf
    ret z
    dec de
    call body_blocked
    jr nc,.climb
    dec de
    call body_blocked
    ret c
.climb:
    ld (pos_y + 1),de
.go:
    ld (pos_x + 1),hl
    or a
    ret

; move_y -- moves him up or down by vel_y, a pixel at a time.
move_y:
    ld a,(vel_y + 1)
    ld e,a
    ld d,0
    rla
    jr nc,.down_vel
    ld d,0xFF
.down_vel:
    ld a,(pos_y)
    ld b,a
    ld a,(vel_y)
    add a,b
    ld (target_frac),a
    ld hl,(pos_y + 1)
    adc hl,de
    ld de,(pos_y + 1)
    or a
    sbc hl,de
    ld a,l
    or a
    jr z,.arrived
    bit 7,a
    jr nz,.up
    ld b,a
.down_step:
    push bc
    ld hl,(pos_x + 1)
    ld de,(pos_y + 1)
    inc de
    call body_blocked
    pop bc
    jr c,.landed
    ld (pos_y + 1),de
    djnz .down_step
    jr .arrived
.up:
    neg
    ld b,a
.up_step:
    push bc
    ld hl,(pos_x + 1)
    ld de,(pos_y + 1)
    dec de
    call body_blocked
    pop bc
    jr c,.bumped
    ld (pos_y + 1),de
    djnz .up_step
.arrived:
    ld a,(target_frac)
    ld (pos_y),a
    ret
.landed:
    ; Hard enough and he bounces; otherwise he stops.
    ld hl,(vel_y)
    ld de,BOUNCE
    or a
    sbc hl,de
    ld hl,0
    jr c,.stop
    ld hl,(vel_y)
    call rebound
.stop:
    ld (vel_y),hl
    ld a,0x80
    ld (pos_y),a
    ret
.bumped:
    ld hl,(vel_y)
    call rebound
    ld (vel_y),hl
    ld a,0x80
    ld (pos_y),a
    ret

; rebound -- HL = -HL / 4, signed. Uses DE.
rebound:
    ex de,hl
    ld hl,0
    or a
    sbc hl,de
    sra h
    rr l
    sra h
    rr l
    ret

; His body, from the sprite's top-left: x 4..11, y 1..15 (sprites.py's art).
BODY_LEFT   equ 4
BODY_TOP    equ 1
BODY_HEIGHT equ 15          ; and 8 wide: one byte's worth of mask

; body_blocked -- whether any pixel of his body is solid, with him at
; (HL = x, DE = y). Carry if any is. Preserves HL, DE; uses BC.
;
; Every pixel, a row at a time: the body's eight pixels across fall in at most
; two bytes of the blocks' masks, and those bytes' addresses only change when
; the row crosses into another block -- so a row is two loads and two ANDs.
; Testing a few points round his edge instead let the tip of a slope slide in
; between them.
body_blocked:
    push hl
    push de
    ld bc,BODY_LEFT
    add hl,bc
    ex de,hl
    ld bc,BODY_TOP
    add hl,bc
    ex de,hl                ; HL, DE = the body's top-left pixel
    ; Off the planet is solid. (The planet's edge is rock, so he never gets
    ; near enough for the body's far side to matter.)
    ld a,h
    cp MAP_W / 16
    jr nc,.hit
    ld a,d
    cp MAP_H / 16
    jr nc,.hit

    ; The body starts x & 7 pixels into its first mask byte: that byte's
    ; mask keeps its right-hand 8 - (x & 7) bits, the next byte the rest.
    ld a,l
    and 7
    ld b,a
    ld a,0xFF
    jr z,.masked
.shift:
    srl a
    djnz .shift
.masked:
    ld (body_mask0),a
    cpl
    ld (body_mask1),a

    ; The first mask byte's column, x >> 3: 0..255.
    ld a,l
    srl h
    rra
    srl h
    rra
    srl h
    rra
    ld (body_col),a

    call body_row_ptrs
    ld b,BODY_HEIGHT
.row:
    ld a,e
    and 0x0F
    add a,a
    ld c,a                  ; this row's offset into a block's mask
    ld hl,(body_ptr0)
    ld a,l
    or c
    ld l,a
    ld a,(body_mask0)
    and (hl)
    jr nz,.hit
    ld hl,(body_ptr1)
    ld a,l
    or c
    ld l,a
    ld a,(body_mask1)
    and (hl)
    jr nz,.hit
    inc de
    ld a,e
    and 0x0F
    call z,body_row_ptrs    ; into the next row of blocks
    djnz .row
    pop de
    pop hl
    or a
    ret
.hit:
    pop de
    pop hl
    scf
    ret

; body_row_ptrs -- body_ptr0 and body_ptr1: where the masks of the blocks
; under body_col and the column after it start, in the block row of pixel
; y = DE, each already pointing at its half of the row (the column's bit 0).
; Preserves B, DE.
body_row_ptrs:
    push bc
    ; Block row y >> 4.
    ld a,e
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    ld c,a
    ld a,d
    rlca
    rlca
    rlca
    rlca
    or c
    ld c,a
    ld a,(body_col)
    call .one
    ld (body_ptr0),hl
    ld a,(body_col)
    inc a
    call .one
    ld (body_ptr1),hl
    pop bc
    ret
; HL = block_mask + (block under mask column A, row C) * 32 + (A & 1).
.one:
    push af
    srl a
    ld b,a
    call map_addr
    ld a,(hl)
    rrca
    rrca
    rrca
    ld l,a
    and 7
    add a,high block_mask
    ld h,a
    ld a,l
    and 0xE0
    ld l,a
    pop af
    and 1
    or l
    ld l,a
    ret

; ---- the view ----------------------------------------------------------------

; centre_camera -- puts the view's top-left where he is in the middle of it,
; inside the planet.
centre_camera:
    ld hl,(pos_x + 1)
    ld de,120
    or a
    sbc hl,de
    jr nc,.x_positive
    ld hl,0
.x_positive:
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld de,MAP_W * 2 - VIEW_W
    call clamp_hl_to_de
    ld (cam_x),hl

    ld hl,(pos_y + 1)
    ld de,72
    or a
    sbc hl,de
    jr nc,.y_positive
    ld hl,0
.y_positive:
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld de,MAP_H * 2 - VIEW_H
    call clamp_hl_to_de
    ld (cam_y),hl
    ret

; clamp_hl_to_de -- HL = min(HL, DE), unsigned.
clamp_hl_to_de:
    push hl
    or a
    sbc hl,de
    pop hl
    ret c
    ex de,hl
    ret

; screen_pos -- B, C = where he is on the screen, in pixels. Uses DE, HL.
screen_pos:
    ld hl,(cam_x)
    add hl,hl
    add hl,hl
    add hl,hl
    ex de,hl
    ld hl,(pos_x + 1)
    or a
    sbc hl,de
    ld b,l
    ld hl,(cam_y)
    add hl,hl
    add hl,hl
    add hl,hl
    ex de,hl
    ld hl,(pos_y + 1)
    or a
    sbc hl,de
    ld c,l
    ret

; follow_camera -- recentres the view, and redraws it, when he gets within
; a margin of its edge. Exile's view jumped too.
follow_camera:
    ld hl,(cam_x)
    add hl,hl
    add hl,hl
    add hl,hl
    ex de,hl
    ld hl,(pos_x + 1)
    or a
    sbc hl,de
    ld a,h
    or a
    jr nz,.recentre
    ld a,l
    cp 48
    jr c,.recentre
    cp 192
    jr nc,.recentre

    ld hl,(cam_y)
    add hl,hl
    add hl,hl
    add hl,hl
    ex de,hl
    ld hl,(pos_y + 1)
    or a
    sbc hl,de
    ld a,h
    or a
    jr nz,.recentre
    ld a,l
    cp 32
    jr c,.recentre
    cp 112
    ret c
.recentre:
    call centre_camera
    call render_view
    xor a
    ld (have_old),a         ; the whole view is fresh: nothing to take off
    ret

; ---- the sprite --------------------------------------------------------------

; restore_player -- takes him off the screen: redraws the 3 x 3 cells his
; sprite last covered, in the landscape's colour.
restore_player:
    ld a,(have_old)
    or a
    ret z
    ld a,(old_sy)
    rrca
    rrca
    rrca
    and 0x1F
    ld c,a
    ld e,3
.row:
    ld a,c
    cp VIEW_H
    ret nc
    ld a,(old_sx)
    rrca
    rrca
    rrca
    and 0x1F
    ld b,a
    ld d,3
.cell:
    ld a,b
    cp VIEW_W
    jr nc,.next_row
    push de
    call draw_cell_at
    pop de
    inc b
    dec d
    jr nz,.cell
.next_row:
    inc c
    dec e
    jr nz,.row
    ret

; draw_player -- draws him where he is now, and colours the cells he is in.
draw_player:
    call screen_pos
    ld a,b
    ld (old_sx),a
    ld a,c
    ld (old_sy),a
    ld a,1
    ld (have_old),a

    ; Image facing * 2 + thrusting, at shift x & 7: sprite_table's entry.
    ld a,(thrusting)
    or a
    jr z,.unlit
    ld a,1
.unlit:
    ld e,a
    ld a,(facing)
    add a,a
    or e
    add a,a
    add a,a
    add a,a
    ld e,a
    ld a,b
    and 7
    or e
    add a,a
    ld l,a
    ld h,0
    ld de,sprite_table
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)

    push bc
    call pixel_addr
    ld b,16
.line:
    push hl
    REPT 3
    ld a,(de)
    and (hl)
    inc de
    ex de,hl
    or (hl)
    ex de,hl
    inc de
    ld (hl),a
    inc l
    ENDR
    pop hl
    call line_down
    djnz .line
    pop bc

    ; His colour, on the cells his ink is in: x + 2 .. x + 12, y + 1 .. y + 14.
    ld a,c
    inc a
    rrca
    rrca
    rrca
    and 0x1F
    ld e,a                  ; first row
    ld a,c
    add a,14
    rrca
    rrca
    rrca
    and 0x1F
    sub e
    inc a
    ld d,a                  ; rows
.attr_row:
    ld a,e
    rrca
    rrca
    rrca
    ld l,a
    and 3
    add a,0x58
    ld h,a
    ld a,l
    and 0xE0
    ld l,a
    ld a,b
    add a,2
    rrca
    rrca
    rrca
    and 0x1F
    or l
    ld l,a
    ld a,b
    add a,12
    rrca
    rrca
    rrca
    and 0x1F
    ld c,a
    ld a,b
    add a,2
    rrca
    rrca
    rrca
    and 0x1F
    neg
    add a,c
    inc a                   ; columns
.attr:
    ld (hl),PLAYER_ATTR
    inc l
    dec a
    jr nz,.attr
    inc e
    dec d
    jr nz,.attr_row
    ret

; ---- variables ---------------------------------------------------------------

pos_x:          db 0        ; fraction
                dw 0        ; pixels
pos_y:          db 0
                dw 0
vel_x:          dw 0        ; 8.8, signed
vel_y:          dw 0
target_frac:    db 0
body_col:       db 0        ; body_blocked's first mask column
body_mask0:     db 0        ; and which bits of it, and of the next, are body
body_mask1:     db 0
body_ptr0:      dw 0        ; the two columns' masks in the current block row
body_ptr1:      dw 0
keys:           db 0
on_ground:      db 0
facing:         db 0        ; 0 right, 1 left
thrusting:      db 0
have_old:       db 0        ; whether old_sx/old_sy are on the screen
old_sx:         db 0
old_sy:         db 0
