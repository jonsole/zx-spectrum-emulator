; The landscape: which corners are rock, and the tile shapes between them.
;
; world.py is the reference for all of it -- the same integer arithmetic,
; step for step -- and says why the rule is what it is. Only the view's
; corners are ever worked out: build_window does the lot whenever the view
; jumps, and everything else reads the windows it leaves.

; build_window -- works out the corners and tile shapes under the view at
; (cam_x, cam_y). The windows start at tile (cam_x >> 1, cam_y >> 1).
;
; The corner rule is world.corner_solid, inlined: a call per corner, and
; working out again for every corner what is the same all along its row or
; down its column, cost half as much again as the rule itself.
build_window:
    ld hl,(cam_x)
    srl h
    rr l
    ld a,l
    ld (win_tx),a
    ld hl,(cam_y)
    srl h
    rr l
    ld a,l
    ld (win_ty),a

    ; Down each column, the across-nudge is read from the same place in the
    ; wave: perm[(x + 4) >> 3]. And the column's region is x >> 3.
    ld a,(win_tx)
    ld b,a
    ld ix,col_perm
    ld h,high perm
.column:
    ld a,b
    add a,4
    rrca
    rrca
    rrca
    and 0x1F
    ld l,a
    ld a,(hl)
    ld (ix + 0),a
    ld a,b
    rrca
    rrca
    rrca
    and 0x1F
    ld (ix + COL_REGION),a
    inc b
    inc ix
    ld a,ixl
    cp low (col_perm + WIN_CORN_W)
    jr nz,.column

    ld iy,corner_win
    ld a,(win_ty)
    ld c,a                  ; C = corner y
    ld a,WIN_CORN_H
    ld (rows_left),a
.corner_row:
    ; Along the row: the down-nudge's place in the wave,
    ; perm[((y + 4) >> 3) + 0x80], and the row's part of a region's address.
    ld a,c
    add a,4
    rrca
    rrca
    rrca
    and 0x1F
    or 0x80
    ld l,a
    ld h,high perm
    ld a,(hl)
    ld (row_perm),a
    call region_row
    ld (row_region),hl

    ld a,(win_tx)
    ld b,a                  ; B = corner x
    ld ix,col_perm
.corner:
    ; Our own region first: built regions are what they say.
    ld hl,(row_region)
    ld a,(ix + COL_REGION)
    or l
    ld l,a
    ld a,(hl)
    cp KIND_MASONRY
    jr nc,.built
    ex af,af'               ; keep our own kind, for a nudge into a built region

    ; Across: x + wave[y + perm[(x + 4) >> 3]].
    ld a,(ix + 0)
    add a,c
    ld l,a
    ld h,high wave
    ld a,(hl)
    add a,b
    ld d,a
    ; Down: y + wave[x + perm[((y + 4) >> 3) + 0x80]].
    ld a,(row_perm)
    add a,b
    ld l,a
    ld a,(hl)
    add a,c
    ld e,a

    ; The region the nudge lands in: world_map + (y >> 3) * 32 + (x >> 3).
    and 0x38
    add a,a
    add a,a
    ld l,a
    ld a,d
    rrca
    rrca
    rrca
    and 0x1F
    or l
    ld l,a
    ld a,e
    rlca
    rlca
    and 3
    add a,high world_map
    ld h,a
    ld a,(hl)
    cp KIND_MASONRY
    jr c,.kind
    ex af,af'               ; built: go by our own region instead
.kind:
    cp KIND_ROCK
    ld a,0
    jr nz,.store
    inc a
    jr .store
.built:
    cp KIND_CHAMBER         ; masonry is rock, a chamber is open
    ld a,1
    jr nz,.store
    xor a
.store:
    ld (iy + 0),a
    inc iy
    inc b
    inc ix
    ld a,ixl
    cp low (col_perm + WIN_CORN_W)
    jr nz,.corner

    inc c
    ld a,(rows_left)
    dec a
    ld (rows_left),a
    jp nz,.corner_row

    ; Each tile's shape from its four corners: top-left 8, top-right 4,
    ; bottom-right 2, bottom-left 1 -- world.tile_shape.
    ld ix,corner_win
    ld hl,shape_win
    ld c,WIN_TILES_H
.shape_row:
    push hl
    ld b,WIN_TILES_W
.shape:
    ld a,(ix + 0)
    add a,a
    or (ix + 1)
    add a,a
    or (ix + WIN_CORN_W + 1)
    add a,a
    or (ix + WIN_CORN_W)
    ld (hl),a
    inc hl
    inc ix
    djnz .shape
    inc ix                  ; past the row's last corner
    pop hl
    ld de,SHAPE_STRIDE
    add hl,de
    dec c
    jr nz,.shape_row
    ret

; region_row -- HL = where corner row C's regions start in the coarse map:
; world_map + (C >> 3) * 32. Uses A.
region_row:
    ld a,c
    and 0x38
    add a,a
    add a,a                 ; (y & 0x38) << 2: the row within its page
    ld l,a
    ld a,c
    rlca
    rlca
    and 3                   ; y >> 6: which of the map's four pages
    add a,high world_map
    ld h,a
    ret
