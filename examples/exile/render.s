; Drawing the landscape: a character cell at a time, straight to the screen.
;
; A block is 2 x 2 cells and the view moves in cells, so a cell is always one
; quarter of one block and drawing it is an eight-byte copy. There is no back
; buffer: the landscape only changes when the view jumps, and the astronaut
; is taken off by redrawing the cells he covered (draw_cell_at).
;
; Positions in cells fit a byte: the planet is 256 cells each way.

; render_view -- draws the whole view at (cam_x, cam_y) in the landscape's
; colour.
render_view:
    ld hl,0x5800
    ld de,0x5801
    ld bc,VIEW_W * VIEW_H - 1
    ld (hl),LAND_ATTR
    ldir

    xor a
    ld (row_cy),a
.row:
    ; The planet's cell row is cam_y + row: the block row is that >> 1, and
    ; its bit 0 picks the top or bottom pair of quarters -- 16 bytes in.
    ld a,(cam_y)
    ld b,a
    ld a,(row_cy)
    add a,b
    ld c,a
    and 1
    rlca
    rlca
    rlca
    rlca
    ld e,a
    srl c                   ; C = block row
    ld a,(cam_x)
    srl a
    ld b,a                  ; B = the view's first block column
    call map_addr
    push hl
    pop ix                  ; IX = this row's first block in the map
    ld c,e                  ; C = quarter offset: 0 or 16, plus 8 for a right half

    push bc
    ld a,(row_cy)
    ld c,a
    ld b,0
    call cell_addr
    pop bc

    ld b,VIEW_W
    ld a,(cam_x)
    and 1
    jr z,.pairs
    ; The view starts half way through a block: its right half first.
    set 3,c
    call draw_cell
    res 3,c
    inc ix
    dec b
.pairs:
    ; A whole block's width at a time: the left quarter down the screen, then
    ; the right quarter back up it, so the pair ends where it started and the
    ; block is looked up once for both.
    ld a,b
    cp 2
    jr c,.tail
    ld a,(ix + 0)
    rrca
    rrca
    rrca
    ld e,a
    and 7
    add a,high block_gfx
    ld d,a
    ld a,e
    and 0xE0
    or c
    ld e,a
    REPT 7
    ld a,(de)
    ld (hl),a
    inc e
    inc h
    ENDR
    ld a,(de)
    ld (hl),a
    inc l
    set 3,e                 ; the right quarter's last row
    REPT 7
    ld a,(de)
    ld (hl),a
    dec e
    dec h
    ENDR
    ld a,(de)
    ld (hl),a
    inc l
    inc ix
    dec b
    dec b
    jr .pairs
.tail:
    ld a,b
    or a
    call nz,draw_cell

    ld a,(row_cy)
    inc a
    ld (row_cy),a
    cp VIEW_H
    jp nz,.row
    ret

; draw_cell -- copies one quarter of a block to the screen.
; IX -> the block's number, C = which quarter (0, 8, 16 or 24 bytes in),
; HL = the cell's top line. Moves HL on a cell; preserves BC and IX.
draw_cell:
    ld a,(ix + 0)
    ; number * 32: block_gfx is 2K-aligned, so the low byte is the number's
    ; bottom three bits << 5 and the high byte adds the rest. Three right
    ; rotations put both where they go.
    rrca
    rrca
    rrca
    ld e,a
    and 7
    add a,high block_gfx
    ld d,a
    ld a,e
    and 0xE0
    or c
    ld e,a
    REPT 7
    ld a,(de)
    ld (hl),a
    inc e
    inc h
    ENDR
    ld a,(de)
    ld (hl),a
    ld a,h
    sub 7
    ld h,a
    inc l
    ret

; draw_cell_at -- redraws view cell (B = column, C = row) and gives it the
; landscape's colour back. Preserves BC.
draw_cell_at:
    push bc
    ld a,c
    rrca
    rrca
    rrca
    ld l,a
    and 3
    add a,0x58
    ld h,a
    ld a,l
    and 0xE0
    or b
    ld l,a
    ld (hl),LAND_ATTR

    call cell_addr
    push hl

    ; The planet's cell: (cam_x + column, cam_y + row). Its block is that
    ; halved, and its low bits pick the quarter.
    ld a,(cam_x)
    add a,b
    ld b,a
    ld a,(cam_y)
    add a,c
    ld c,a
    and 1
    add a,a
    ld e,a
    ld a,b
    and 1
    or e
    add a,a
    add a,a
    add a,a
    ld e,a                  ; E = quarter offset
    srl b
    srl c
    call map_addr
    push hl
    pop ix
    ld c,e
    pop hl
    call draw_cell
    pop bc
    ret

; cell_addr -- HL = the top line of character cell (B = column, C = row).
; Uses A.
cell_addr:
    ld a,c
    and 0x18
    or 0x40
    ld h,a
    ld a,c
    and 7
    rrca
    rrca
    rrca
    or b
    ld l,a
    ret

; pixel_addr -- HL = the screen byte holding pixel (B = x, C = y). Uses A.
pixel_addr:
    ld a,c
    and 7
    ld h,a
    ld a,c
    rra
    rra
    rra
    and 0x18
    or h
    or 0x40
    ld h,a
    ld a,c
    rla
    rla
    and 0xE0
    ld l,a
    ld a,b
    rrca
    rrca
    rrca
    and 0x1F
    or l
    ld l,a
    ret

; line_down -- moves HL, a screen address, down one pixel line. Uses A.
line_down:
    inc h
    ld a,h
    and 7
    ret nz
    ld a,l
    add a,32
    ld l,a
    ret c
    ld a,h
    sub 8
    ld h,a
    ret
