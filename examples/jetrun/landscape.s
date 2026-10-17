; The landscape: Cyberun's renderer each pass, and the full render at a
; life's start.
;
; The world is a grid of pages, PAGE_W x PAGE_H pixels; the view is the world
; point at the play area's top-left pixel (view_x, view_y), both even. A
; world pixel is drawn at screen x = wx - view_x + 8, y = wy - view_y + 24.
; The screen is never cleared (ADR 0002). Each pass, Cyberun's own renderer
; (ADR 0007: cyberun.s, from the Cyberun disassembly) moves its
; view by however far Jetrun's moved and draws every step it can see, filling
; the strips moving edges uncover. A new life, where the view jumps, gets a
; full render from the world's crossings first, worked out in model.py and
; compared with it byte for byte by check.py.
;
; Cyberun's view is kept beside Jetrun's: cyberun.view_column and cyberun.view_row are
; the page holding the view's top-left (its rows counted from 1, row 0 being
; the sky above the map), cyberun.view_x is 8 + the view's x in that page and
; cyberun.view_y 23 + its y, and the origins turn page points into screen points.

; ---------------------------------------------------------------------------
; landscape_pass: Cyberun's renderer, scrolled by the view's move since it
; last drew (at most MOVE each way).

landscape_pass:
    ld hl,(view_x)
    ld de,(drawn_view_x)
    ld (drawn_view_x),hl
    or a
    sbc hl,de               ; the move across, -2 to 2, unless it wrapped
    ld a,h
    or a
    jr z,.across
    inc a
    jr z,.across
    ld de,WORLD_W           ; wrapped round the world: bring it back
    bit 7,h
    jr nz,.add_world
    or a
    sbc hl,de
    jr .across
.add_world:
    add hl,de
.across:
    ld a,l
    neg                     ; the view moving right moves the landscape left
    ld (cyberun.scroll_across),a
    ld hl,(view_y)
    ld de,(drawn_view_y)
    ld (drawn_view_y),hl
    ld a,l
    sub e
    neg                     ; the view moving down moves the landscape up
    ld (cyberun.scroll_down),a
    ; fall into cyberun_scroll

; cyberun_scroll: one pass of Cyberun's scroll_landscape with this pass's
; scroll. Its blitters borrow SP to read the step graphics; Cyberun ran with
; interrupts off for that, Jetrun leaves them on and the interrupt routine
; mends what its push writes over (isr, in jetrun.s).
cyberun_scroll:
    jp cyberun.scroll_landscape

; cyberun_view: Cyberun's view put where Jetrun's is, its four pages loaded,
; and its collision boxes made on the next pass (cyberun.map_rebuild).
cyberun_view:
    call view_split
    ld a,(vpc)
    ld (cyberun.view_column),a
    ld a,(vpr)
    inc a
    ld (cyberun.view_row),a
    ld a,(vpx)
    ld b,a
    add a,8
    ld (cyberun.view_x),a
    xor a
    sub b
    ld (cyberun.origin_x),a      ; 8 - cyberun.view_x
    ld a,(vpy)
    ld b,a
    add a,23
    ld (cyberun.view_y),a
    ld a,PAGE_H
    sub b
    ld (cyberun.origin_y),a      ; $B7 - cyberun.view_y
    xor a
    ld (cyberun.scroll_down),a
    ld (cyberun.scroll_across),a
    ld a,3
    ld (cyberun.map_rebuild),a
    ld hl,(cyberun.view_column)  ; L column, H row
    jp cyberun.load_map_window

; ---------------------------------------------------------------------------
; landscape_full: the play area drawn for the view from nothing. The full
; render draws it as the world's crossings say, from a view up to a page
; above; then Cyberun's renderer scrolls down to the view, 2 rows a pass, so
; that every surface on the screen has been drawn and filled behind by the
; renderer itself, as it would have been had the view travelled there.

landscape_full:
    ld hl,(view_y)
    push hl
    ld de,PAGE_H            ; start min(PAGE_H, view_y) rows above
    or a
    sbc hl,de
    jr nc,.above
    ld hl,0
.above:
    ld (view_y),hl
    ld (drawn_view_y),hl
    ld hl,(view_x)
    ld (drawn_view_x),hl
    call full_render
    call cyberun_view       ; map_rebuild set: boxes made, nothing coloured
    call cyberun_scroll     ; the first pass: every step drawn
    pop hl
    ld (view_y),hl
.descend:
    ld hl,(view_y)
    ld de,(drawn_view_y)
    or a
    sbc hl,de
    jr z,.colour
    ld hl,(drawn_view_y)
    inc hl
    inc hl
    ld (drawn_view_y),hl
    ld a,-MOVE
    ld (cyberun.scroll_down),a
    xor a
    ld (cyberun.scroll_across),a
    call cyberun_scroll
    jr .descend
.colour:
    ; Then a pass in which colour_piece colours the cells along every
    ; piece (map_rebuild, set till now, stops it colouring). Attributes are
    ; only ever written there and under the astronaut; the rest of the play
    ; area keeps the colour power_on_colour gave it.
    xor a
    ld (cyberun.map_rebuild),a
    ld (cyberun.scroll_down),a
    ld (cyberun.scroll_across),a
    jp cyberun_scroll

; power_on_colour: every cell of the play area in the surface's colour,
; once, when the game starts.
power_on_colour:
    ld a,GROUND_ABOVE
    ; fall into fill_play_attrs

; fill_play_attrs: every cell of the play area to A.
fill_play_attrs:
    ld hl,0x5800 + (PLAY_TOP / 8) * 32 + FIRST_COLUMN
    ld c,PLAY_H / 8
.row:
    ld b,PLAY_W / 8
.cell:
    ld (hl),a
    inc hl
    djnz .cell
    ld de,32 - PLAY_W / 8
    add hl,de
    dec c
    jr nz,.row
    ret

; ---------------------------------------------------------------------------
; view_split: view_x, view_y -> the view's page (vpc, vpr) and its place in
; that page (vpx, vpy). At most MAP_W and MAP_H subtractions.

view_split:
    ld hl,(view_x)
    ld de,PAGE_W
    ld b,0
.columns:
    or a
    sbc hl,de
    jr c,.column_done
    inc b
    jr .columns
.column_done:
    add hl,de
    ld a,l
    ld (vpx),a
    ld a,b
    ld (vpc),a
    ld hl,(view_y)
    ld de,PAGE_H
    ld b,0
.rows:
    or a
    sbc hl,de
    jr c,.row_done
    inc b
    jr .rows
.row_done:
    add hl,de
    ld a,l
    ld (vpy),a
    ld a,b
    ld (vpr),a
    ret

; ---------------------------------------------------------------------------
; full_render: every pixel of the play area from the world's crossings.
; Floors and ceilings toggle sky and rock down each pixel column, from sky
; above the world. The play area is cleared; then for every page from the top
; row of the world to the one below the view's, in the two page columns the
; view spans, each column a surface crosses is toggled -- in full_state if it
; crosses above the view, or in the play area itself at the row it crosses.
; Then the rows are drawn top down: the state toggled by the row's toggles,
; and rock drawn as the checker.

full_render:
    call view_split
    ld c,PLAY_TOP           ; clear the play area
.clear_row:
    ld a,FIRST_COLUMN
    call screen_address
    ld h,d
    ld l,e
    inc de
    ld (hl),0
    push bc
    ld bc,PLAY_W / 8 - 1
    ldir
    pop bc
    inc c
    ld a,c
    cp PLAY_TOP + PLAY_H
    jr nz,.clear_row
    ld hl,full_state
    ld b,PLAY_W / 8
.clear_state:
    ld (hl),0
    inc hl
    djnz .clear_state
    ; oy for row 0: -vpr * PAGE_H - vpy, kept in page_oy and stepped by PAGE_H
    ld hl,0
    ld a,(vpr)
    or a
    jr z,.oy_rows
    ld b,a
    ld de,PAGE_H
.oy_minus:
    or a
    sbc hl,de
    djnz .oy_minus
.oy_rows:
    ld a,(vpy)
    ld e,a
    ld d,0
    or a
    sbc hl,de
    ld (page_oy),hl
    xor a
    ld (lp_row),a           ; here, the page row in the world
.page_row:
    xor a
    ld (lp_col),a           ; 0 or 1: the view's page column and the next
.page:
    ld a,(lp_row)           ; the tile at (vpc + lp_col, lp_row)
    add a,a
    ld l,a
    ld h,0
    ld de,map_rows
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a                  ; HL = the row's start in world_map
    ld a,(vpc)
    ld b,a
    ld a,(lp_col)
    add a,b
    cp MAP_W
    jr c,.col_ok
    sub MAP_W
.col_ok:
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    ld l,a
    ld h,0
    add hl,hl
    ld de,toggle_table
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    push hl
    ; page_ox = lp_col * PAGE_W - vpx (play-area pixels)
    ld a,(lp_col)
    ld hl,0
    or a
    jr z,.ox_zero
    ld hl,PAGE_W
.ox_zero:
    ld a,(vpx)
    ld e,a
    ld d,0
    or a
    sbc hl,de
    ld (page_ox),hl
    pop hl
    call toggle_tile
    ld hl,lp_col
    inc (hl)
    ld a,(hl)
    cp 2
    jr nz,.page
    ; the next row of pages, until the one below the view's lowest
    ld hl,(page_oy)
    ld de,PAGE_H
    add hl,de
    ld (page_oy),hl
    ld hl,lp_row
    inc (hl)
    ld a,(hl)
    cp MAP_H
    jr z,.draw
    ld b,a
    ld a,(vpr)
    add a,2
    cp b
    jr nz,.page_row

.draw:
    ; Row by row: state ^= the row's toggles; the checker where rock,
    ; Cyberun's: 0x55 on odd screen lines, 0xAA on even.
    ld c,PLAY_TOP
.draw_row:
    ld a,FIRST_COLUMN
    call screen_address
    ld a,c
    and 1
    ld a,0xAA
    jr z,.pattern
    ld a,0x55
.pattern:
    ld (.checker + 1),a
    ld hl,full_state
    ld b,PLAY_W / 8
.draw_byte:
    ld a,(de)
    xor (hl)
    ld (hl),a
.checker:
    and 0x55
    ld (de),a
    inc hl
    inc e
    djnz .draw_byte
    inc c
    ld a,c
    cp PLAY_TOP + PLAY_H
    jr nz,.draw_row
    ret

; toggle_tile: the crossings of a tile's floors and ceilings, at page_ox,
; page_oy (play-area pixels). HL = the tile's toggle record: a count, then
; per piece x and y (words, signed: a piece may start outside its page),
; direction (TOGGLE_DIRECTIONS) and steps.
toggle_tile:
    ld a,(hl)
    inc hl
    or a
    ret z
    ld b,a
.piece:
    push bc
    ld e,(hl)               ; x
    inc hl
    ld d,(hl)
    inc hl
    push hl
    ld hl,(page_ox)
    add hl,de
    ld (step_x),hl
    pop hl
    ld e,(hl)               ; y
    inc hl
    ld d,(hl)
    inc hl
    push hl
    ld hl,(page_oy)
    add hl,de
    ld (step_y),hl
    pop hl
    ld a,(hl)
    inc hl
    ld (step_dir),a
    ld a,(hl)
    inc hl
    ld (step_count),a
    push hl
    call toggle_piece
    pop hl
    pop bc
    djnz .piece
    ret

; toggle_piece: every column of every step of a floor or ceiling piece.
toggle_piece:
    ld a,(step_dir)
    ld l,a
    ld h,0
    push hl
    add hl,hl
    ld de,toggle_steps
    add hl,de
    ld a,(hl)
    ld (step_dx),a
    inc hl
    ld a,(hl)
    ld (step_dy),a
    pop hl
    add hl,hl               ; the direction's surface offsets: 16 each
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,surface_offsets
    add hl,de
    ld (tg_offsets),hl
.step:
    ld a,(step_dx)
    ld b,a                  ; the step's columns
    ld hl,(tg_offsets)
    ld (tg_offset),hl
    ld hl,(step_x)
    ld (tg_column),hl
.column:
    push bc
    ld hl,(tg_column)       ; 0 <= column < PLAY_W?
    ld a,h
    or a
    jr nz,.next_column
    ld a,l
    cp PLAY_W
    jr nc,.next_column
    ld (tg_c),a
    ld hl,(tg_offset)       ; row = step_y + offset
    ld a,(hl)
    ld e,a
    add a,a
    sbc a,a
    ld d,a
    ld hl,(step_y)
    add hl,de
    bit 7,h
    jr nz,.above            ; above the view: toggles the state
    ld de,PLAY_H
    or a
    sbc hl,de
    jr nc,.next_column      ; below the view: nothing
    add hl,de
    ld a,l
    add a,PLAY_TOP
    ld c,a
    ld a,(tg_c)
    rra
    rra
    rra
    and 0x1F
    add a,FIRST_COLUMN
    call screen_address
    ex de,hl
    jr .toggle
.above:
    ld a,(tg_c)
    rra
    rra
    rra
    and 0x1F
    ld e,a
    ld d,0
    ld hl,full_state
    add hl,de
.toggle:
    ld a,(tg_c)
    and 7
    ld e,a
    ld d,0
    push hl
    ld hl,bit_masks
    add hl,de
    ld a,(hl)
    pop hl
    xor (hl)
    ld (hl),a
.next_column:
    ld hl,(tg_column)
    inc hl
    ld (tg_column),hl
    ld hl,(tg_offset)
    inc hl
    ld (tg_offset),hl
    pop bc
    djnz .column
    ; the next step
    ld a,(step_dx)
    ld e,a
    ld d,0
    ld hl,(step_x)
    add hl,de
    ld (step_x),hl
    ld a,(step_dy)
    ld e,a
    add a,a
    sbc a,a
    ld d,a
    ld hl,(step_y)
    add hl,de
    ld (step_y),hl
    ld hl,step_count
    dec (hl)
    jp nz,.step
    ret

bit_masks:
    db 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01
