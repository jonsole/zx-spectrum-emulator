; The astronaut: his jetpack, his momentum, and the rock he bumps into.
;
; Position is in pixels of the planet (0..4095 each way) with a byte of
; fraction below; velocity is signed 8.8 pixels a frame. Every frame adds the
; forces to the velocity, then moves him one pixel at a time along each axis,
; testing the rock at each pixel -- he never moves more than a few a frame,
; and stepping is what lets him stop exactly against a wall, and walk up a
; gentle slope, rather than sink into it.
;
; The rock he tests is the tiles' collision masks (tiles.py): what is drawn is
; what is solid, to the pixel.

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

; Where he starts: on the landing pad, in world.txt's sky.
START_X     equ 1270
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
    ld iy,points_down
    call blocked
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
    ld hl,points_right
    ld (points_ahead),hl
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
    ld hl,points_left
    ld (points_ahead),hl
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
    call clear_ahead
    jr nc,.go
    ld a,(on_ground)
    or a
    scf
    ret z
    dec de
    call clear_ahead_and_up
    jr nc,.climb
    dec de
    call clear_ahead_and_up
    ret c
.climb:
    ld (pos_y + 1),de
.go:
    ld (pos_x + 1),hl
    or a
    ret

clear_ahead:
    ld iy,(points_ahead)
    jp blocked

clear_ahead_and_up:
    call clear_ahead
    ret c
    ld iy,points_up
    jp blocked

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
    ld iy,points_down
    call blocked
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
    ld iy,points_up
    call blocked
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

; blocked -- whether any of a list of points on his body is in rock, with
; him at (HL = x, DE = y). IY -> the list: (dx, dy) byte pairs, 0xFF ends it.
; Carry if any is. Preserves HL, DE, IY.
blocked:
    push iy
.point:
    ld a,(iy + 0)
    cp 0xFF
    jr z,.clear
    push hl
    push de
    ld c,a
    ld b,0
    add hl,bc
    ld a,(iy + 1)
    ex de,hl
    ld c,a
    add hl,bc
    ex de,hl
    call rock_at
    pop de
    pop hl
    jr c,.done
    inc iy
    inc iy
    jr .point
.clear:
    or a
.done:
    pop iy
    ret

; His body's edges, as points from the sprite's top-left: the body is x 4..11,
; y 1..15 (sprites.py's art). The points run out to its corners -- a slope
; pokes into a corner first -- and are no more than three pixels apart, so a
; spike of rock needs to be thinner than that to slip between them.
points_right:   db 11, 1,  11, 5,  11, 8,  11, 12,  11, 15,  0xFF
points_left:    db 4, 1,   4, 5,   4, 8,   4, 12,   4, 15,   0xFF
points_down:    db 4, 15,  7, 15,  8, 15,  11, 15,  0xFF
points_up:      db 4, 1,   7, 1,   8, 1,   11, 1,   0xFF

; rock_at -- whether pixel (HL = x, DE = y) of the planet is rock: its tile's
; collision mask, out of the windows. Anything outside the windows counts as
; rock -- he never gets there, since the view recentres first. Carry if rock.
; Preserves HL, DE; uses BC.
rock_at:
    ; Tile x = x >> 4, as a byte: the planet is 256 tiles across.
    ld a,l
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    ld b,a
    ld a,h
    rlca
    rlca
    rlca
    rlca
    and 0xF0
    or b
    ld b,a
    ld a,(win_tx)
    ld c,a
    ld a,b
    sub c
    cp WIN_TILES_W
    ccf
    ret c
    ld b,a                  ; B = column in the window

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
    and 0xF0
    or c
    ld c,a
    ld a,(win_ty)
    neg
    add a,c
    cp WIN_TILES_H
    ccf
    ret c                   ; A = row in the window

    push hl
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld a,b
    or l
    ld l,a
    ld bc,shape_win
    add hl,bc
    ld a,(hl)               ; the tile's shape
    pop hl

    ; Its mask row: tile_mask + shape * 32 + (y & 15) * 2 + which half.
    rrca
    rrca
    rrca
    ld b,a
    and 0xE0
    ld c,a
    ld a,e
    and 0x0F
    add a,a
    or c
    ld c,a
    bit 3,l
    jr z,.left_half
    inc c
.left_half:
    ld a,b
    and 1
    add a,high tile_mask
    ld b,a
    ld a,(bc)

    ; The pixel's bit, shifted out into carry.
    ld c,a
    ld a,l
    and 7
    ld b,a
    ld a,c
    jr z,.test
.shift:
    add a,a
    djnz .shift
.test:
    add a,a
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
    ld de,512 - VIEW_W
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
    ld de,512 - VIEW_H
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
points_ahead:   dw points_right
keys:           db 0
on_ground:      db 0
facing:         db 0        ; 0 right, 1 left
thrusting:      db 0
have_old:       db 0        ; whether old_sx/old_sy are on the screen
old_sx:         db 0
old_sy:         db 0
