; Drawing the landscape: a character cell at a time, straight to the screen.
;
; A tile is 2 x 2 cells and the view moves in cells, so a cell is always one
; quarter of one tile and drawing it is an eight-byte copy. There is no back
; buffer: the landscape only changes when the view jumps, and the astronaut
; is taken off by redrawing the cells he covered (draw_cell_at).

; render_view -- works the windows out for (cam_x, cam_y) and draws the
; whole view in the landscape's colour.
render_view:
    call build_window

    ld hl,0x5800
    ld de,0x5801
    ld bc,VIEW_W * VIEW_H - 1
    ld (hl),LAND_ATTR
    ldir

    xor a
    ld (row_cy),a
.row:
    ; Half-tile row t = (cam_y & 1) + row: the tile row is t >> 1, and t & 1
    ; picks the top or bottom pair of quarters -- 16 bytes into the tile.
    ld a,(cam_y)
    and 1
    ld b,a
    ld a,(row_cy)
    add a,b
    ld b,a
    and 1
    rlca
    rlca
    rlca
    rlca
    ld c,a                  ; C = quarter offset: 0 or 16, plus 8 for a right half
    ld a,b
    srl a
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,shape_win
    add hl,de
    push hl
    pop ix                  ; IX = this row's first tile in the shape window

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
    ; The view starts half way through a tile: its right half first.
    set 3,c
    call draw_cell
    res 3,c
    inc ix
    dec b
.pairs:
    ; A whole tile's width at a time: the left quarter down the screen, then
    ; the right quarter back up it, so the pair ends where it started and the
    ; shape is looked up once for both.
    ld a,b
    cp 2
    jr c,.tail
    ld a,(ix + 0)
    rrca
    rrca
    rrca
    ld e,a
    and 1
    add a,high tile_gfx
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

; draw_cell -- copies one quarter of a tile to the screen.
; IX -> the tile's shape, C = which quarter (0, 8, 16 or 24 bytes in),
; HL = the cell's top line. Moves HL on a cell; preserves BC and IX.
draw_cell:
    ld a,(ix + 0)
    ; shape * 32: tile_gfx is 512-aligned, so the low byte is the shape's
    ; bottom three bits << 5 and the high byte takes its top bit.
    rrca
    rrca
    rrca
    ld e,a
    and 1
    add a,high tile_gfx
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

    ; Where the cell is in the windows: half-tile column and row, from the
    ; view's own half-tile offset.
    ld a,(cam_x)
    and 1
    add a,b
    ld b,a
    ld a,(cam_y)
    and 1
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

    ld a,c
    srl a
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld a,b
    srl a
    or l
    ld l,a
    ld bc,shape_win
    add hl,bc
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
