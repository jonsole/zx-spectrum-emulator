; The astronaut's sprite: masked, with what lies under it saved (ADR 0004).
;
; The screen is never cleared, so what the sprite covers is kept in
; sprite_saved -- three bytes a row for its 24 rows -- and put back before
; the next pass's landscape is drawn. The frames are built by sprites.py at
; all eight shifts: per row, mask and ink for each of three bytes; the
; screen becomes (screen AND mask) OR ink.

; sprite_screen: the sprite's place on the screen from its world place and
; the view, to even pixels: B = screen x, C = screen y. The view keeps it at
; the centre, on character cells (game.py's CENTRE_X, CENTRE_Y).
sprite_screen:
    ld hl,(ax + 1)
    ld de,(view_x)
    or a
    sbc hl,de
    jr nc,.no_wrap          ; px < view_x: the view straddles the seam
    ld de,WORLD_W
    add hl,de
.no_wrap:
    ld a,l
    and 0xFE
    add a,PLAY_LEFT
    ld b,a
    ld hl,(ay + 1)
    ld de,(view_y)
    or a
    sbc hl,de
    ld a,l
    and 0xFE
    add a,PLAY_TOP
    ld c,a
    ret

; sprite_attrs: HL = the attribute of the cell at the sprite's drawn top-left.
sprite_attrs:
    ld a,(drawn_y)
    and 0xF8                ; row * 32 = (y / 8) * 32 = (y AND $F8) * 4
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    ld a,(drawn_x)
    rra
    rra
    rra
    and 0x1F
    or l
    ld l,a
    ld de,0x5800
    add hl,de
    ret

; screen_address: DE = the screen address of column A, row C.
screen_address:
    push bc
    ld b,a
    ld a,c
    and 7
    or 0x40
    ld d,a
    ld a,c
    rra
    rra
    rra
    and 0x18
    or d
    ld d,a
    ld a,c
    rla
    rla
    and 0xE0
    or b
    ld e,a
    pop bc
    ret

; next_row: DE one pixel row down the screen.
next_row:
    inc d
    ld a,d
    and 7
    ret nz
    ld a,e
    add a,0x20
    ld e,a
    ret c
    ld a,d
    sub 8
    ld d,a
    ret

; restore_sprite: put back what was under the sprite where it was drawn.
restore_sprite:
    ld a,(drawn_y)
    ld c,a
    ld a,(drawn_x)
    rra
    rra
    rra
    and 0x1F
    call screen_address
    ld hl,sprite_saved
    ld b,SPRITE_H
.row:
    push de
    ld a,(hl)
    ld (de),a
    inc hl
    inc e
    ld a,(hl)
    ld (de),a
    inc hl
    inc e
    ld a,(hl)
    ld (de),a
    inc hl
    pop de
    call next_row
    djnz .row
    call sprite_attrs       ; and its cells' colours
    ld de,sprite_saved_attrs
    ld c,4
.attr_row:
    ld b,3
.attr_cell:
    ld a,(de)
    ld (hl),a
    inc de
    inc hl
    djnz .attr_cell
    push de
    ld de,32 - 3
    add hl,de
    pop de
    dec c
    jr nz,.attr_row
    ret

; place_sprite: save what lies under the sprite at its place for this view,
; and draw the frame there.
place_sprite:
    call sprite_screen
    ld a,b
    ld (drawn_x),a
    ld a,c
    ld (drawn_y),a
    ; the frame's bytes at this shift: sprite_frames[frame * 8 + (x & 7)]
    ld a,(frame)
    add a,a
    add a,a
    add a,a
    ld l,a
    ld a,b
    and 7
    or l
    ld l,a
    ld h,0
    add hl,hl
    ld de,sprite_frames
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    push hl
    ld a,b
    rra
    rra
    rra
    and 0x1F
    call screen_address
    pop hl
    ld ix,sprite_saved
    ld b,SPRITE_H
.row:
    push bc
    push de
    ld b,3
.byte:
    ld a,(de)
    ld (ix+0),a
    inc ix
    and (hl)                ; mask
    inc hl
    or (hl)                 ; ink
    inc hl
    ld (de),a
    inc e
    djnz .byte
    pop de
    call next_row
    pop bc
    djnz .row
    ; its cells: the 3 x 4 from its top-left kept, those it covers white
    call sprite_attrs
    push hl
    ld de,sprite_saved_attrs
    ld c,4
.save_row:
    ld b,3
.save_cell:
    ld a,(hl)
    ld (de),a
    inc de
    inc hl
    djnz .save_cell
    push de
    ld de,32 - 3
    add hl,de
    pop de
    dec c
    jr nz,.save_row
    pop hl
    ld a,(drawn_y)          ; rows covered: 3 on a cell boundary, else 4
    and 7
    ld c,3
    jr z,.rows
    inc c
.rows:
    ld a,(drawn_x)          ; columns covered: 2 on a byte boundary, else 3
    and 7
    ld a,2
    jr z,.columns
    inc a
.columns:
    ld (.width + 1),a
.paint_row:
    push hl
.width:
    ld b,2
.paint_cell:
    ld (hl),ASTRONAUT_ATTR
    inc hl
    djnz .paint_cell
    pop hl
    ld de,32
    add hl,de
    dec c
    jr nz,.paint_row
    ret
