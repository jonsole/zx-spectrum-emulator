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

    ; Standing on something? The row under his feet.
    ld hl,(pos_x + 1)
    ld de,(pos_y + 1)
    inc de
    call foot_blocked
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
    ld hl,lead_right
    ld (lead_edge),hl
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
    ld hl,lead_left
    ld (lead_edge),hl
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
    call lead_blocked       ; only the column he moves into can be new rock
    jr nc,.go
    ld a,(on_ground)
    or a
    scf
    ret z
    ; A pixel up as well: the leading column there, and the row he rises
    ; into.
    dec de
    call lead_blocked
    jr c,.two_up
    call head_blocked
    jr nc,.climb
.two_up:
    ; Two up: the column, and both rows.
    dec de
    call lead_blocked
    ret c
    call head_blocked
    ret c
    inc de
    call head_blocked
    dec de
    ret c
.climb:
    ld (pos_y + 1),de
.go:
    ld (pos_x + 1),hl
    or a
    ret

; lead_blocked -- the leading column of his body, with him at (HL, DE), for
; the way move_x is going.
lead_blocked:
    push hl
    ld hl,(lead_edge)
    ex (sp),hl
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
    call foot_blocked       ; only the row he moves into can be new rock
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
    call head_blocked
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
BODY_WIDTH  equ 8
BODY_HEIGHT equ 15

; Whether a part of his body is in anything solid, with him at (HL = x,
; DE = y). Carry if it is. Preserve HL, DE, BC.
;
; A step of one pixel can only take him into rock through the row or column
; he steps into -- he was clear where he was -- so a step tests just that
; edge: foot_blocked or head_blocked a row, lead_blocked a column, each a
; handful of lookups. A climb, up and across at once, tests the column and
; the rows he rises into.
foot_blocked:
    push hl
    push de
    push bc
    ld a,BODY_TOP + BODY_HEIGHT - 1
    jr body_row
head_blocked:
    push hl
    push de
    push bc
    ld a,BODY_TOP
body_row:
    add a,e
    ld e,a
    jr nc,.no_carry
    inc d
.no_carry:
    ld bc,BODY_LEFT
    add hl,bc
    call row_blocked
    jr body_done
lead_right:
    push hl
    push de
    push bc
    ld bc,BODY_LEFT + BODY_WIDTH - 1
    jr body_column
lead_left:
    push hl
    push de
    push bc
    ld bc,BODY_LEFT
body_column:
    add hl,bc
    inc de                  ; BODY_TOP
    ld b,BODY_HEIGHT
    call column_blocked
body_done:
    pop bc
    pop de
    pop hl
    ret

; row_blocked -- whether any of the eight pixels from (HL, DE) across is
; solid. Carry if one is. Uses everything but IX, IY.
row_blocked:
    ld a,h
    cp MAP_W / 16
    ccf
    ret c
    ld a,d
    cp MAP_H / 16
    ccf
    ret c
    ; The row's offset in a block's mask, (y & 15) * 2, and its block row.
    ld a,e
    and 0x0F
    add a,a
    ld (rb_offset),a
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
    ; The eight pixels start x & 7 into mask byte x >> 3: that byte's right
    ; 8 - (x & 7) bits, then the left (x & 7) of the next.
    ld a,l
    and 7
    ld (rb_shift),a
    ld a,l
    srl h
    rra
    srl h
    rra
    srl h
    rra
    ld (rb_col),a
    call .mask_byte
    ld d,a
    ld a,(rb_shift)
    ld hl,right_bits
    add a,l
    ld l,a
    ld a,(hl)               ; 0xFF >> (x & 7): his pixels in the first byte
    ld e,a
    and d
    jr nz,.hit
    ld a,(rb_shift)
    or a
    ret z                   ; aligned: all in the one byte (carry is clear)
    ld a,(rb_col)
    inc a
    ld (rb_col),a
    call .mask_byte
    ld d,a
    ld a,e
    cpl                     ; the rest, in the next
    and d
    ret z
.hit:
    scf
    ret
; A = the mask byte for mask column rb_col in block row C. Preserves C.
.mask_byte:
    ld a,(rb_col)
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
    ld a,(rb_offset)
    or l
    ld l,a
    ld a,(hl)
    ret

; column_blocked -- whether any of B pixels (1..16) down from (HL, DE) is
; solid. Carry if one is. Uses everything but IX, IY.
;
; From block_cols: a block's solidity column by column, sixteen rows to a
; word -- so B rows are at most two blocks' words, each ANDed with the rows
; it covers.
column_blocked:
    ld a,h
    cp MAP_W / 16
    ccf
    ret c
    ld a,d
    cp MAP_H / 16
    ccf
    ret c
    ld a,l
    and 0x0F
    add a,a
    ld (cb_column),a        ; which word of a block's sixteen
    ld a,l
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    ld c,a
    ld a,h
    rlca
    rlca
    rlca
    rlca
    or c
    ld (cb_bx),a            ; its block column
    ld a,e
    and 0x0F
    ld c,a                  ; the first row within the block
    add a,b
    ld (cb_end),a           ; and one past the last: up to 31
    ld a,e
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    ld b,a
    ld a,d
    rlca
    rlca
    rlca
    rlca
    or b
    ld (cb_by),a            ; the block row

    ld a,(cb_end)
    cp BLOCK_ROWS + 1
    jr c,.in_one
    ld a,BLOCK_ROWS
.in_one:
    call .test              ; rows C .. A - 1 of the first block
    ret c
    ld a,(cb_end)
    sub BLOCK_ROWS
    jr z,.clear
    jr c,.clear             ; all in the first block
    ld c,0
    ld hl,cb_by
    inc (hl)                ; the rest in the block below
    jp .test
.clear:
    or a
    ret
; Carry if the block at (cb_bx, cb_by) is solid anywhere in column
; cb_column, rows C .. A - 1.
.test:
    ; DE = rows_from[C] & ~rows_from[A]
    add a,a
    ld l,a
    ld h,high rows_from
    ld a,l
    add a,low rows_from
    ld l,a
    ld a,(hl)
    cpl
    ld e,a
    inc l
    ld a,(hl)
    cpl
    ld d,a
    ld a,c
    add a,a
    add a,low rows_from
    ld l,a
    ld a,(hl)
    and e
    ld e,a
    inc l
    ld a,(hl)
    and d
    ld d,a
    ; HL = the block's word for this column.
    ld a,(cb_bx)
    ld b,a
    ld a,(cb_by)
    ld c,a
    call map_addr
    ld a,(hl)
    rrca
    rrca
    rrca
    ld l,a
    and 7
    add a,high block_cols
    ld h,a
    ld a,l
    and 0xE0
    ld l,a
    ld a,(cb_column)
    or l
    ld l,a
    ld a,(hl)
    and e
    jr nz,.solid
    inc l
    ld a,(hl)
    and d
    ret z
.solid:
    scf
    ret

BLOCK_ROWS  equ 16

; 0xFF >> n, n = 0..7, in one page.
    ALIGN 8
right_bits:     db 0xFF, 0x7F, 0x3F, 0x1F, 0x0F, 0x07, 0x03, 0x01

; ---- the view ----------------------------------------------------------------

; camera_target -- where the view should be for him: cam_th, in fours of
; pixels across, and cam_ty, in pixels down, with him in the middle, inside
; the planet. scroll_view moves the view there.
camera_target:
    ld hl,(pos_x + 1)
    ld de,VIEW_W * 4 - 4    ; half the view, less half of him
    or a
    sbc hl,de
    jr nc,.x_positive
    ld hl,0
.x_positive:
    srl h
    rr l
    srl h
    rr l
    ld de,(MAP_W * 16 - VIEW_W * 8) / 4
    call clamp_hl_to_de
    ld (cam_th),hl

    ld hl,(pos_y + 1)
    ld de,VIEW_LINES / 2 - 8
    or a
    sbc hl,de
    jr nc,.y_positive
    ld hl,0
.y_positive:
    ld de,MAP_H * 16 - VIEW_LINES
    call clamp_hl_to_de
    ld (cam_ty),hl
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

; screen_pos -- B, C = where he is in the view, in pixels; carry if his
; sprite is not wholly inside it (only for a moment, as when the view must
; catch him up). Uses DE, HL.
screen_pos:
    ld hl,(cam_h)
    add hl,hl
    add hl,hl
    ex de,hl
    ld hl,(pos_x + 1)
    or a
    sbc hl,de
    ld b,l
    ld a,h
    or a
    scf
    ret nz
    ld a,l
    cp VIEW_W * 8 - 23      ; his three bytes across
    ccf
    ret c
    ld de,(cam_y)
    ld hl,(pos_y + 1)
    or a
    sbc hl,de
    ld c,l
    ld a,h
    or a
    scf
    ret nz
    ld a,l
    cp VIEW_LINES - 15      ; his sixteen lines down
    ccf
    ret

; ---- variables ---------------------------------------------------------------

pos_x:          db 0        ; fraction
                dw 0        ; pixels
pos_y:          db 0
                dw 0
vel_x:          dw 0        ; 8.8, signed
vel_y:          dw 0
target_frac:    db 0
lead_edge:      dw lead_right ; which edge move_x is moving him into
rb_offset:      db 0        ; row_blocked's working
rb_shift:       db 0
rb_col:         db 0
cb_column:      db 0        ; column_blocked's
cb_bx:          db 0
cb_by:          db 0
cb_end:         db 0
keys:           db 0
on_ground:      db 0
facing:         db 0        ; 0 right, 1 left
thrusting:      db 0
