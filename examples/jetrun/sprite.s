; The astronaut's sprite: masked, with what lies under it saved (ADR 0004).
;
; The screen is never cleared, so what the sprite covers is kept in
; sprite_saved -- three bytes a row for its 24 rows -- and put back at the
; start of the next pass. The frames are built by sprites.py: per row, mask
; and ink for each of three bytes; the screen becomes (screen AND mask) OR
; ink.
;
; A pass puts the sprite back and draws it at its new place straight away,
; before the landscape, and mends it afterwards where the landscape drew
; over it (mend_sprite). Drawn after the landscape instead, the sprite was
; off the screen for most of a frame, and the beam went past where it
; belonged while it was gone: it showed only every other frame.

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

; frame_bytes: HL = the frame's bytes at the drawn place's shift,
; sprite_frames[frame * 8 + (x AND 7)]; DE = its screen address.
frame_bytes:
    ld a,(frame)
    add a,a
    add a,a
    add a,a
    ld l,a
    ld a,(drawn_x)
    ld b,a
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
    ld a,(drawn_y)
    ld c,a
    ld a,b
    rra
    rra
    rra
    and 0x1F
    jp screen_address

; place_sprite: save what lies under the sprite at its place for this view,
; and draw the frame there.
place_sprite:
    call sprite_screen
    ld a,b
    ld (drawn_x),a
    ld a,c
    ld (drawn_y),a
    call frame_bytes
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

; mend_sprite: the sprite drawn again where the landscape drew over it since
; place_sprite. Cyberun's renderer writes whole bytes and never reads the
; screen, so a byte that is no longer what place_sprite left there is the
; landscape's: what now lies under the sprite. It is saved, and the sprite
; drawn over it again. A landscape byte that happens to equal what the
; sprite left cannot be told from no write at all, and the old byte is kept
; as what lies under it: about one pass in six has one such byte, nearly
; always where the landscape draws it again (check.py counts them). A cell's
; colour that is not the astronaut's is
; likewise the landscape's (colour_piece): saved, and the cells the sprite
; covers made the astronaut's again.
mend_sprite:
    call frame_bytes
    ld ix,sprite_saved
    ld b,SPRITE_H
.row:
    push bc
    push de
    ld b,3
.byte:
    ld a,(ix+0)             ; what place_sprite left: (saved AND mask) OR ink
    and (hl)
    inc hl
    or (hl)
    dec hl
    ld c,a
    ld a,(de)
    cp c
    jr z,.same
    ld (ix+0),a             ; the landscape's: under the sprite now
    and (hl)
    inc hl
    or (hl)
    dec hl
    ld (de),a
.same:
    inc hl
    inc hl
    inc ix
    inc e
    djnz .byte
    pop de
    call next_row
    pop bc
    djnz .row
    ld a,(drawn_y)          ; rows covered: 3 on a cell boundary, else 4
    and 7
    ld a,3
    jr z,.rows
    inc a
.rows:
    ld (.row_limit + 1),a
    ld a,(drawn_x)          ; columns covered: 2 on a byte boundary, else 3
    and 7
    ld a,2
    jr z,.columns
    inc a
.columns:
    ld (.column_limit + 1),a
    call sprite_attrs
    ld de,sprite_saved_attrs
    ld c,0
.attr_row:
    ld b,0
.attr_cell:
    ld a,(hl)
    cp ASTRONAUT_ATTR
    jr z,.kept
    ld (de),a
.kept:
    ld a,c
.row_limit:
    cp 3
    jr nc,.uncovered
    ld a,b
.column_limit:
    cp 2
    jr nc,.uncovered
    ld (hl),ASTRONAUT_ATTR
.uncovered:
    inc de
    inc hl
    inc b
    ld a,b
    cp 3
    jr nz,.attr_cell
    push de
    ld de,32 - 3
    add hl,de
    pop de
    inc c
    ld a,c
    cp 4
    jr nz,.attr_row
    ret
