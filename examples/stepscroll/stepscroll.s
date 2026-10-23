; stepscroll: listscroll's display list over a world of Cyberun's own terrain
; steps, many screens wide and high, moved 2 pixels a frame by the keys: O and
; P left and right, round the world, Q and A up and down, as far as the map
; goes.
;
; The world is a map of pages, 8 across (256 columns: a world column is a
; byte and wraps by itself) and MAP_ROWS down, each 32 columns by 256 lines.
; Each page is a block (a "tile" in the data's labels), a list of entries,
; each a tile of world/tiles.json 1 to 3 bytes wide and up to MAX_ROWS rows,
; drawn by the blitter for its width. A block holds its entries twice,
; sorted by bottom line and by column, with an index of where each character
; row's or column's run starts, and a list of them by top line with its own
; index.
;
; The table holds the entries on the screen: columns 1 to 30 of lines 24 to
; 175 show the world (rows 0 to 2 are for the score; columns 0 and 31 and rows
; 22 and 23 are black on black). An entry is in it while some of its lines are
; 24 to 175 and its first column is
; 2 - width to 30. One partly off the left or right is drawn from a byte or
; two before or after: screen memory runs on along a pixel line from one
; character row to the next, so what falls off one side lands in a hidden
; column at the other. One partly off the top or bottom is clipped: it draws
; only its row pairs in lines 24 to 175 (store_entry, the moves). Each entry: the screen
; address of the first byte of its lowest line drawn, its blitter's way in
; for the pairs it draws, and its graphic from that pair at fine position 0
; (the others GFX_PAGES pages on), and, for the moves, its world column, its
; bottom line on the screen, its shape, its fills and its way in. The
; order does not matter (overlapping entries write the same bytes): an entry
; leaves by the last one being copied over it. draw_list walks the table
; with SP and jumps to each entry's blitter.
;
; A pass is two frames (25 a second) and draws the list once; between
; drawings the world moves up to 4 pixels across and up to 4 lines up or
; down, in one go -- the tiles cover every byte such a move changes
; (build.py). Moving across changes the fine position's offset; when it
; wraps, every entry moves a byte. Moving up or down moves every entry 2 or 4
; lines. Entries come and go at the edges, found through the tiles'
; indexes. What a move uncovers the entries redraw themselves: build.py gives
; them margins above and below, and their spare byte on the right holds only
; sky or ground. The left-column fill for a move right (FILLS) is off: the
; build makes each step's first 2 pixels match what lies to its left.
;
; build.py makes output/data.s: the graphics, the map (a tile number a page),
; tile_table and the tiles, line_table and the screen as the world starts.

    DEVICE ZXSPECTRUM48

    INCLUDE "output/jetman.inc" ; JETMAN: 1 with Lunar Jetman's frames to hand

RASTER_MARK equ 0x40        ; bright black: the hidden rows' attribute
PAPER       equ 0x47        ; white on black: the attribute of what shows
MAX_TABLE   equ 110         ; entries the table holds
ENTRY       equ 11          ; bytes an entry
FIRST_SHOWN equ 24          ; the play area's first line: rows 0 to 2 are the score's
LAST_SHOWN  equ 175         ; and its last (rows 22 and 23 are hidden)
MAX_ROWS    equ 24          ; an entry's rows at most (build.py's)
FIRST_LINE  equ FIRST_SHOWN + 1 ; the bottom lines an entry in the table can have:
LAST_LINE   equ LAST_SHOWN + MAX_ROWS - 2 ; its top FIRST_SHOWN to LAST_SHOWN (odd: 197)
LAST_TOP    equ LAST_SHOWN - 1 ; the top line of entries arriving at the bottom
STEP        equ 4           ; a pass's move, up or down: 4 lines (2 across, twice)

; An entry's bytes.
E_ADDRESS   equ 0           ; its lowest line drawn
E_BLITTER   equ 2           ; its blitter, entered for the pairs it draws
E_GRAPHIC   equ 4           ; its graphic from the lowest pair drawn
E_COLUMN    equ 6           ; its world column
E_LINE      equ 7           ; its bottom line on the screen (1 to LAST_LINE)
E_SHAPE     equ 8           ; width * 32 + rows (E_LINE + 1: the moves read both)
E_FILLS     equ 9           ; 2 bits each: above (down), below (up), left (right)
E_WAY       equ 10          ; its blitter's place in blit_entry (the low byte)

; A tile's entry record.
R_COLUMN    equ 0           ; its column in the page
R_BOTTOM    equ 1           ; its bottom line in the page
R_GRAPHIC   equ 2
R_SHAPE     equ 4
R_FILLS     equ 5
R_TOP       equ 6           ; its top line in the page
R_SIZE      equ 8

FILL_RIGHT  equ 1
FILLS       equ 0           ; 1: paint the column a move right leaves (fills); 0: don't, to see it
DRAW_UP     equ 1           ; the order the list is drawn in (build_order): 1 bottom to
                            ; top, against the beam, so that unsynced it crosses the
                            ; drawing once and quickly; 0 top to bottom, with it, for
                            ; drawing synced to the frame
ORDER_ROWS  equ 32          ; build_order's buckets: character rows of a line

    ORG 0x8000

start:
    di                      ; interrupts off for good: main waits on the
    ld sp,0x8000            ; floating bus, and draw_list borrows SP
    ld hl,0x4000            ; a blank screen, white ink on black: the world
    ld de,0x4001            ; scrolls in from the bottom (keys)
    ld bc,6144
    ld (hl),0
    ldir
    ld (hl),PAPER
    ld bc,768 - 1
    ldir
    ld hl,0x5AC0            ; rows 22 and 23 bright black: still black on
    ld de,0x5AC1            ; black, but an attribute main can see the ULA
    ld bc,63                ; fetch on the floating bus
    ld (hl),RASTER_MARK
    ldir
    ld hl,0x5800            ; columns 0 and 31 black on black, rows 22 and 23
    ld de,31                ; too
    ld b,24
.hide:
    ld (hl),0
    add hl,de
    ld (hl),0
    inc hl
    djnz .hide
    call fill_table
    call build_order
    xor a
    out (0xFE),a
; The border shows each stage of a pass: red the fills, green the list
; drawn, blue the moves' bookkeeping, magenta the entries arriving, black
; idle. A pass is two frames: the list is drawn once, after the mark, while
; the beam is out of the play area (the score's rows give it until line 24);
; the move is made in the rest of the next frame, then the order to draw the
; next pass in, and pace holds the next pass to the mark two frames after
; this one's.
main:
    call wait_mark          ; the beam is past what shows: draw now, all the
                            ; way round to the play area of the next frame
    ld a,2                  ; red: the fills
    out (0xFE),a
    call fills
    IF JETMAN
    call jet_erase          ; Jetman off, so the list never draws over him
    ENDIF
    ld a,4                  ; green: the list
    out (0xFE),a
    call draw_list
    IF JETMAN
    call jet_draw           ; and on again where he is now
    ENDIF
    xor a
    out (0xFE),a
    call wait_paper         ; into the next frame
    ld a,1                  ; blue: the move
    out (0xFE),a
    IF JETMAN
    ld a,(jet_on)
    or a
    jr z,.keys
    call jet_update         ; his move and the view's
    jr .moved
.keys:
    call keys
    call jet_update         ; (he starts once the world has scrolled in)
.moved:
    ELSE
    call keys
    ENDIF
    call build_order        ; the order to draw the next in
    xor a
    out (0xFE),a
    call pace
    jr main

; wait_mark: until the beam is in rows 22 and 23, past what shows. Port
; $00FF: a high byte of $40-$7F would be contended, held till the ULA's fetch
; is over, and read only the idle $FF. The floating bus: the attribute the
; ULA is fetching, rows 22 and 23's RASTER_MARK (a pixel byte of $40
; anywhere can start it early). The loop is 41 T-states, odd, so that its
; reads fall at every point of the ULA's 8 T-state fetch in turn: at 34 they
; fell at only every other point, and started on the wrong ones they never
; saw an attribute at all.
wait_mark:
    xor a
    in a,(0xFF)
    cp RASTER_MARK
    ld c,0                  ; (7 T-states: the loop's length, odd)
    jr nz,wait_mark
    ret

; wait_paper: until the beam is in rows 0 to 21 (their attribute, PAPER).
; 41 T-states a read, as wait_mark.
wait_paper:
    xor a
    in a,(0xFF)
    cp PAPER
    ld c,0
    jr nz,wait_paper
    ret

; beam_where: A = 1 if the beam is in rows 0 to 21, 2 if in rows 22 and 23,
; 0 if in the border, from the floating bus over about two lines. The loop
; is 63 T-states, so that its reads fall at every point of the ULA's 8
; T-state fetch: at 56 they all fell at one, between attributes, and saw
; only the border.
beam_where:
    ld b,32
.look:
    xor a
    in a,(0xFF)
    cp PAPER
    jr z,.paper
    cp RASTER_MARK
    jr z,.mark
    ld c,0                  ; (7 T-states: the loop's length, odd)
    djnz .look
    xor a
    ret
.paper:
    ld a,1
    ret
.mark:
    ld a,2
    ret

; pace: after a pass's move, begun in the frame after its drawing
; (wait_paper), so that the next pass starts at the mark two frames after
; this one's: still in that frame's rows 0 to 21, its mark is let go by; in
; its mark, that too; in the border, the next mark is the one. (A move that
; ran on into the frame after is taken for the first case, and that pass is
; three frames.)
pace:
    call beam_where
    or a
    ret z
    dec a
    jr nz,.mark
    call wait_mark
.mark:
    call beam_where
    cp 2
    jr z,.mark
    ret

; fill_table: the table as the world starts, the screen blank and the world
; to scroll in from below it: the entries reaching up onto the screen from
; below, those whose bottom is on each line from LAST_SHOWN + 2 to LAST_LINE.
fill_table:
    xor a
    ld (count),a
    ld hl,table
    ld (table_end),hl
    ld de,LAST_SHOWN + 2
.line:
    push de
    call add_line
    pop de
    inc de
    inc de
    ld a,e
    cp LAST_LINE + 2
    jr nz,.line
    ret

; ---------------------------------------------------------------------------
; draw_list: every entry, by its blitter, in build_order's order. The walker
; keeps its place in the order in HL' and SP in the table; for each entry it
; pops the screen address, the blitter
; and the graphic, adds the fine position's offset, points SP at the graphic
; and jumps to the blitter, which draws it bottom row first, two rows a pair
; (the lower left to right, the upper right to left), and jumps back. The
; fine positions' graphics are GFX_PAGES pages apart, so the offset is added
; to the high byte: a graphic can be any size and cross a page.

draw_list:
    ld a,(count)
    or a
    ret z
    ld b,a                  ; B counts the entries down
    ld (saved_sp),sp        ; SP will be in the graphics
    exx
    ld hl,order             ; HL': the next entry's place in the order
    exx
draw_next:
    exx
    ld e,(hl)               ; SP at this entry, HL' at the next one's place
    inc hl
    ld d,(hl)
    inc hl
    ex de,hl
    ld sp,hl
    ex de,hl
    exx
    pop de                  ; the screen address
    pop ix                  ; the blitter
    pop hl                  ; the graphic, at fine position 0
    ld a,h                  ; this fine position's version:
gfx_offset:
    add a,0                 ; fine / 2 * GFX_PAGES pages on (set_offset patches it)
    ld h,a
    ld sp,hl
    ex de,hl
    jp (ix)
draw_done:
    ld sp,(saved_sp)
    ret

; build_order: order, the table's entries' addresses in the order to draw
; them: by the character row of the bottom line, the lowest first (DRAW_UP),
; or of the top line, the highest first -- a counting sort, every pass, as
; the moves and arrivals leave the table in no order. Within a row any order.
build_order:
    ld a,(count)
    or a
    ret z
    ld hl,order_count       ; the buckets' counts, to 0
    ld b,ORDER_ROWS
.clear:
    ld (hl),0
    inc hl
    djnz .clear
    ld a,(count)            ; each entry's bucket into order_row, counted
    ld b,a
    ld hl,table + E_LINE
    ld de,order_row
.count:
    ld a,(hl)               ; its bottom line
    IF DRAW_UP
    cpl                     ; the lowest first: 255 less it
    ELSE
    inc hl
    ld c,(hl)               ; less its rows: its top line, less 1
    dec hl
    push af
    ld a,c
    and 31
    ld c,a
    pop af
    sub c
    ENDIF
    rrca                    ; its character row
    rrca
    rrca
    and ORDER_ROWS - 1
    ld (de),a
    inc de
    push hl
    ld hl,order_count
    add a,l
    ld l,a
    jr nc,.same
    inc h
.same:
    inc (hl)
    pop hl
    ld a,l
    add a,ENTRY
    ld l,a
    jr nc,.next
    inc h
.next:
    djnz .count
    ld hl,order_count       ; each bucket's first place: the counts before it
    ld b,ORDER_ROWS
    ld c,0
.sum:
    ld a,(hl)
    ld (hl),c
    add a,c
    ld c,a
    inc hl
    djnz .sum
    ld a,(count)            ; each entry's address into its bucket's next place
    ld b,a
    ld hl,table
    ld de,order_row
.place:
    push bc
    ld a,(de)
    inc de
    push de
    ld de,order_count
    add a,e
    ld e,a
    jr nc,.same2
    inc d
.same2:
    ld a,(de)               ; its place, and the bucket's next on
    inc a
    ld (de),a
    dec a
    push hl
    ld l,a
    ld h,0
    add hl,hl
    ld de,order
    add hl,de
    ex de,hl                ; DE: the place
    pop hl
    ld a,l
    ld (de),a
    inc de
    ld a,h
    ld (de),a
    ld de,ENTRY
    add hl,de
    pop de
    pop bc
    djnz .place
    ret

; Up a row after a pair, maybe into the character row above: back a
; character row, and if that was the third's top row H's own borrow was
; right, else H goes back into its third. The row is told from L + 1, not L:
; an entry whose first column is -1 starts on the byte before its row.
    MACRO CROSS back
    ld a,l
    inc a
    sub 32
    dec a                   ; (DEC leaves the carry)
    ld l,a
    jr c,back
    ld a,h
    add a,8
    ld h,a
    jp back                 ; JP: 10 T-states, a taken JR 12
    ENDM

    MACRO NEXT_PAIR cross   ; then the label to come back to
    ld a,h
    inc a
    and 7
    jr z,cross
    ENDM

; The same where a JR does not reach (build.py works out which): NEXT_PAIR's
; costs 3 T-states more a pair, CROSS's only when it is taken.
    MACRO CROSS_FAR back
    ld a,l
    inc a
    sub 32
    dec a
    ld l,a
    jp c,back
    ld a,h
    add a,8
    ld h,a
    jp back
    ENDM

    MACRO NEXT_PAIR_FAR cross
    ld a,h
    inc a
    and 7
    jp z,cross
    ENDM

    MACRO PAIR1             ; 1 byte wide
    pop de
    ld (hl),e
    dec h
    ld (hl),d
    dec h
    ENDM

    MACRO PAIR2             ; 2 bytes wide
    pop de
    ld (hl),e
    inc l
    ld (hl),d
    dec h
    pop de
    ld (hl),e
    dec l
    ld (hl),d
    dec h
    ENDM

    MACRO PAIR3             ; 3 bytes wide
    pop de
    ld (hl),e
    inc l
    ld (hl),d
    inc l
    pop de
    ld (hl),e
    dec h
    ld (hl),d
    dec l
    pop de
    ld (hl),e
    dec l
    ld (hl),d
    dec h
    ENDM

    MACRO DONE              ; DEC B and JP: the walker is out of DJNZ's reach
    dec b
    jp nz,draw_next
    jp draw_done
    ENDM

    INCLUDE "output/blitters.s"

; ---------------------------------------------------------------------------
; fills: the fills the last move asked for (fill_pending), before the list
; is drawn over them. After a move right, the entries it took to column 31
; were kept for their fills; now they go.

fills:
    ld a,(fill_pending)
    or a
    ret z
    xor a
    ld (fill_pending),a
    IF FILLS
    ld a,(count)
    or a
    jr z,.done
    ld b,a
    ld ix,table
.entry:
    ld a,(ix + E_FILLS)
    and 0x30                ; its left column's fill: none?
    jr z,.next
    cp 0x10                 ; sky or checker (LD leaves the flags)
    ld a,1
    jr z,.kind
    inc a
.kind:
    ld (fill_kind),a
    push bc
    call fill_left
    pop bc
.next:
    ld de,ENTRY
    add ix,de
    djnz .entry
.done:
    ENDIF
    ; fall into remove_right

; remove_right: the entries at column 31, off the right.
remove_right:
    ld a,(count)
    or a
    ret z
    ld b,a
    ld hl,table
.entry:
    call entry_x
    cp 31
    jr nz,.keep
    call remove_entry
    djnz .entry
    ret
.keep:
    ld de,ENTRY
    add hl,de
    djnz .entry
    ret

; entry_x: A = the screen column of the entry at HL (its world column less
; view_column). HL, BC, DE kept.
entry_x:
    push hl
    ld a,l
    add a,E_COLUMN
    ld l,a
    jr nc,.same
    inc h
.same:
    ld a,(view_column)
    neg
    add a,(hl)
    pop hl
    ret

; fill_left: the column to the left of the entry at IX, its rows. (Not
; clipped like the entries: with FILLS off it is unused, and would need
; clipping to lines 0 to 175 before it was used again.) Nothing
; for an entry starting at column -1: its column -2 is off the screen, and
; along the pixel line it would be the row above's column 30, which shows.
fill_left:
    ld a,(view_column)
    neg
    add a,(ix + E_COLUMN)
    inc a
    ret z
    ld a,(ix + E_SHAPE)
    and 31
    rrca
    ld b,a                  ; B: its pairs of rows
    ld d,0x55               ; its bottom line is odd: $55, then $AA, or sky
    ld c,0xAA
    ld a,(fill_kind)
    dec a
    jr nz,.checker
    ld d,a
    ld c,a
.checker:
    ld a,(ix + E_LINE)
    call line_address_x     ; HL: its bottom line (in the ROM for line -1)
    dec l                   ; the column to its left
.row:
    ld (hl),d               ; an odd line and the even one above it, in the
    dec h                   ; same character row; then up again, maybe into
    ld (hl),c               ; the row above. Rows above the screen are the
    dec h                   ; ROM, which ignores the writes.
    ld a,h
    inc a
    and 7
    jr nz,.same
    ld a,l                  ; into the character row above (told from L + 1,
    inc a                   ; as in the blitters)
    sub 32
    dec a
    ld l,a
    jr c,.same
    ld a,h
    add a,8
    ld h,a
.same:
    djnz .row
    ret

; fill_byte_for: D = fill_kind's byte for screen line E: 0 for sky, the
; checker ($55 on odd lines, $AA on even) for rock.
fill_byte_for:
    ld a,(fill_kind)
    ld d,0
    cp 1
    ret z
    ld d,0x55
    bit 0,e
    ret nz
    ld d,0xAA
    ret

; line_address_x: HL = screen line A's address at the column of the entry
; at IX (its world column less view_column; L wraps along the pixel line).
line_address_x:
    inc a                   ; line_table_m1 starts at line -1
    ld l,a
    ld h,0
    add hl,hl
    push de
    ld de,line_table_m1
    add hl,de
    ld a,(view_column)
    neg
    add a,(ix + E_COLUMN)
    add a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    pop de
    ret

; ---------------------------------------------------------------------------
; keys: P moves the world 4 pixels right, O 4 pixels left; if neither, Q 4
; lines up, A 4 lines down. Until the world has scrolled in, up by itself.

keys:
    ld hl,(view_y)          ; scrolling in at the start: up until the view is
    ld de,VIEW_Y_START      ; where the world starts
    or a
    sbc hl,de
    ld a,STEP
    jr c,up
    ld a,0xDF               ; the half-row Y U I O P
    in a,(0xFE)
    bit 0,a                 ; P
    jp z,right2
    bit 1,a                 ; O
    jp z,left2
    ld a,0xFB               ; Q
    in a,(0xFE)
    rra
    ld a,STEP
    jr nc,up
    ld a,0xFD               ; A
    in a,(0xFE)
    rra
    ret c
    ld a,STEP
    ; fall into down

; down: the view A lines (2 or 4) up the map, as far as its top: the world
; down -- every entry, those whose top goes below LAST_SHOWN off; then those
; whose bottom is now on the first line or two on.
down:
    ld c,a
    ld hl,(view_y)
    ld a,h
    or a
    jr nz,.room
    ld a,l
    cp c
    jr nc,.room
    ld c,l                  ; only as far as the map's top
    ld a,c
    or a
    ret z
.room:
    ld e,c
    ld d,0
    or a
    sbc hl,de
    ld (view_y),hl
    push bc
    ld a,c
    call move_lines
    ld de,FIRST_LINE
    call add_line
    pop bc
    ld a,c
    cp 4
    ret nz
    ld de,FIRST_LINE + 2
    jp add_line

; up: the view A lines (2 or 4) down the map, as far as its bottom: the
; world up -- every entry, those whose bottom goes above the play area off;
; then those whose top is now on the last line or two on.
up:
    ld c,a
    ld hl,VIEW_Y_MAX
    ld de,(view_y)
    or a
    sbc hl,de               ; how far there is to go
    ld a,h
    or a
    jr nz,.room
    ld a,l
    cp c
    jr nc,.room
    ld c,l                  ; only as far as the map's bottom
    ld a,c
    or a
    ret z
.room:
    ld hl,(view_y)
    ld e,c
    ld d,0
    add hl,de
    ld (view_y),hl
    push bc
    ld a,c
    neg
    call move_lines
    ld de,LAST_TOP
    call add_top
    pop bc
    ld a,c
    cp 4
    ret nz
    ld de,LAST_TOP - 2
    jp add_top

; move_lines: every entry A lines down the screen (2 or 4; -2 or -4 up), in
; place. Those gone off -- the top below LAST_SHOWN, or the bottom above
; FIRST_LINE -- leave the table. An entry wholly in the play area before and
; after only has its address moved, 2 lines at a time; one clipped before or
; after is clipped again (reclip).
move_lines:
    ld (.step + 1),a
    ld (move_step),a
    ld a,(count)
    or a
    ret z
    ld b,a
    ld hl,table
.entry:
    push hl
    ld de,E_LINE
    add hl,de
    ld a,(hl)
    ld (move_old),a         ; its bottom line before
.step:
    add a,0
    ld (hl),a               ; and after
    ld e,a                  ; E: its bottom line
    inc hl
    ld c,(hl)               ; C: its shape (E_SHAPE)
    ld a,c
    and 31
    ld d,a                  ; D: its rows
    pop hl
    ld a,e
    cp FIRST_LINE
    jr c,.off               ; above the play area
    sub d                   ; its top line less 1
    jr c,.clip              ; (top 0 or above)
    cp LAST_SHOWN
    jr nc,.off              ; top below LAST_SHOWN
    cp FIRST_SHOWN - 1
    jr c,.clip              ; top above the play area
    ld a,e
    cp LAST_SHOWN + 1
    jr nc,.clip             ; bottom below it
    ld a,(move_old)         ; and before?
    cp LAST_SHOWN + 1
    jr nc,.clip
    sub d
    jr c,.clip
    cp FIRST_SHOWN - 1
    jr c,.clip
    ld a,(move_step)        ; in the play area, before and after
    call move_address
.next:
    ld de,ENTRY
    add hl,de
    djnz .entry
    ret
.off:
    call remove_entry       ; the last entry in its place, to move next
    djnz .entry
    ret
.clip:
    call reclip
    jr .next

; move_address: the entry at HL's address A lines down the screen (2 or 4;
; -2 or -4 up), 2 at a time. All registers but A kept.
move_address:
    or a
    ret z
    bit 7,a
    jr nz,.up
    call address_down2
    sub 2
    jr move_address
.up:
    call address_up2
    add a,2
    jr move_address

; address_down2: the entry at HL's address (an odd line's) 2 lines down: the
; first may cross into the next character row (told from L + 1, as in the
; blitters), and a third's last row carries into the next third; the second
; never crosses. All registers kept.
address_down2:
    push af
    push de
    inc hl
    ld d,(hl)               ; H
    inc d
    ld a,d
    and 7
    jr nz,.second
    dec hl
    ld a,(hl)
    inc a
    add a,32
    dec a
    ld (hl),a
    inc hl
    jr c,.second
    ld a,d
    sub 8
    ld d,a
.second:
    inc d
    ld (hl),d
    dec hl
    pop de
    pop af
    ret

; address_up2: the entry at HL's address 2 lines up: the first never leaves
; the character row (the line is odd); the second may, and a third's top row
; borrows into the third above. All registers kept.
address_up2:
    push af
    push de
    inc hl
    ld d,(hl)
    dec d
    dec d
    ld a,d
    inc a
    and 7
    jr nz,.done
    dec hl
    ld a,(hl)
    inc a
    sub 32
    dec a
    ld (hl),a
    inc hl
    jr c,.done
    ld a,d
    add a,8
    ld d,a
.done:
    ld (hl),d
    dec hl
    pop de
    pop af
    ret

; reclip: the entry at HL, whose bottom line has moved from move_old to E
; (its shape C, its rows D), clipped to lines FIRST_SHOWN to LAST_SHOWN
; again: its address moves with its lowest line drawn (LAST_SHOWN or its
; bottom), its graphic by a row's bytes for each line more or less below the
; play area, and its way in is for the pairs from there up to FIRST_SHOWN or
; its top. All registers kept.
reclip:
    push bc
    push de
    push hl
    ld a,c
    ld (reclip_shape),a
    ld a,e
    cp LAST_SHOWN + 1
    jr c,.new
    ld a,LAST_SHOWN
.new:
    ld (reclip_lowest),a    ; the lowest line it draws now
    ld b,a
    ld a,(move_old)
    cp LAST_SHOWN + 1
    jr c,.old
    ld a,LAST_SHOWN
.old:
    ld c,a                  ; C: the lowest it drew
    ld a,b
    sub c
    call move_address       ; its address with it
    ld a,(move_old)         ; the lines below the play area, before less after:
    sub c                   ; the graphic a row's bytes on for each line more
    ld c,a
    ld a,e
    sub b
    sub c                   ; (lines more below, -4 to 4)
    jr z,.way
    ld c,a
    ld a,(reclip_shape)
    rlca
    rlca
    rlca
    and 7
    ld b,a                  ; B: its width
    xor a
.bytes:
    add a,c
    djnz .bytes
    ld c,a                  ; C: the bytes, -12 to 12
    rlca
    sbc a,a
    ld b,a                  ; B: their sign, for the high byte
    push hl
    inc hl
    inc hl
    inc hl
    inc hl                  ; E_GRAPHIC
    ld a,c
    add a,(hl)
    ld (hl),a
    inc hl
    ld a,b
    adc a,(hl)
    ld (hl),a
    pop hl
.way:
    ld a,(reclip_shape)     ; its top line, or FIRST_SHOWN if above it
    and 31
    ld b,a
    ld a,e
    sub b
    inc a                   ; (INC leaves the carry)
    jr c,.first
    cp FIRST_SHOWN
    jr nc,.top
.first:
    ld a,FIRST_SHOWN
.top:
    neg
    ld b,a
    ld a,(reclip_lowest)
    add a,b
    inc a                   ; the lines it draws: 2 a pair, a word a pair in
    ld b,a                  ; blit_entry
    ld a,(reclip_shape)
    and 0xE0                ; 32 bytes a width
    add a,b
    add a,low (blit_entry - 32)
    ld de,E_WAY
    push hl
    add hl,de
    ld (hl),a
    pop hl
    ld e,a
    ld d,high blit_entry    ; (blit_entry is in one page)
    inc hl
    inc hl                  ; E_BLITTER
    ld a,(de)
    ld (hl),a
    inc e
    inc hl
    ld a,(de)
    ld (hl),a
    pop hl
    pop de
    pop bc
    ret

; ---------------------------------------------------------------------------
; Across.

; right2: the world 4 pixels right, as two of right's 2 (no drawing between:
; the tiles cover the 4-pixel move, and the byte moves at most once).
; left2: 4 pixels left.
right2:
    call right
    jp right
left2:
    call left
    jp left

; right: the world 2 pixels right. From fine position 6 to 0 the screen's
; first column is a world column further left: every entry a byte right;
; those now at column 31 stay until their fills are made (fills); those
; arriving on: width 3 at column -1, 2 at 0, 1 at 1.
right:
    ld a,(fine)
    add a,2
    and 6
    ld (fine),a
    call set_offset
    ld a,(fine)
    or a
    ret nz
    ld hl,view_column       ; (round the world: 256 columns, a byte)
    dec (hl)
    ld c,1
    call move_entries
    IF FILLS
    ld a,FILL_RIGHT         ; those at column 31 go after their fills
    ld (fill_pending),a
    ELSE
    call remove_right       ; no fills: those at column 31 go now, as moving left
    ENDIF
    ld a,(view_column)
    dec a
    ld b,3
    call add_column
    ld a,(view_column)
    ld b,2
    call add_column
    ld a,(view_column)
    inc a
    ld b,1
    jp add_column

; left: the world 2 pixels left. From fine position 0 to 6 the screen's first
; column is a world column further right: every entry a byte left; those now
; wholly off the left (first column 1 - width) off; those arriving at column
; 30 on.
left:
    ld a,(fine)
    sub 2
    and 6
    ld (fine),a
    call set_offset
    ld a,(fine)
    cp 6
    ret nz
    ld hl,view_column
    inc (hl)
    ld c,-1
    call move_entries
    call remove_left
    ld a,(view_column)
    add a,30
    ld b,3
    call add_column
    ld a,(view_column)
    add a,30
    ld b,2
    call add_column
    ld a,(view_column)
    add a,30
    ld b,1
    jp add_column

; move_entries: every entry's screen address C bytes across (1 or -1), along
; its pixel line (L alone: a byte off a row's end is the next row's first).
move_entries:
    ld a,(count)
    or a
    ret z
    ld b,a
    ld hl,table
    ld de,ENTRY
.entry:
    ld a,(hl)
    add a,c
    ld (hl),a
    add hl,de
    djnz .entry
    ret

; remove_left: the entries wholly off the left: first column 1 - width.
remove_left:
    ld a,(count)
    or a
    ret z
    ld b,a
    ld hl,table
.entry:
    call entry_x
    ld c,a
    push hl
    ld a,l
    add a,E_SHAPE
    ld l,a
    jr nc,.same
    inc h
.same:
    ld a,(hl)
    pop hl
    rlca
    rlca
    rlca
    and 7                   ; its width
    add a,c                 ; column + width = 1: off
    cp 1
    jr nz,.keep
    call remove_entry
    djnz .entry
    ret
.keep:
    ld de,ENTRY
    add hl,de
    djnz .entry
    ret

; add_column: the entries B wide in world column A that touch what shows
; into the table: in its page column, in the page rows of screen lines
; FIRST_LINE and LAST_LINE (one or two, inside the map).
add_column:
    ld e,a
    ld a,3                  ; magenta: entries arriving
    out (0xFE),a
    ld a,b
    ld (take_in_column.width + 1),a
    ld hl,take_in_column
    ld (scan_listed.take + 1),hl
    ld a,COLUMN_LIST
    ld (scan_listed.list + 1),a
    ld hl,scan_listed
    ld (scan_at.go + 1),hl
    ld a,(view_column)
    neg
    add a,e
    ld (take_in_column.column + 1),a    ; its screen column
    ld a,e
    and PAGE_COLUMNS - 1
    add a,COLUMN_INDEX
    ld (column_entry),a     ; its column's entry in a tile's index
    ld a,e
    rlca
    rlca
    rlca
    and 7
    ld c,a                  ; C: its page column
    ld hl,(view_y)
    ld de,LAST_LINE
    add hl,de
    ld b,h                  ; B: the page row of the bottom line
    ld hl,(view_y)
    ld de,FIRST_LINE
    add hl,de
    ld a,(column_entry)
    ld e,a                  ; E: the index entry
    ld a,h                  ; A: the page row of the top line
    cp b
    jr z,.last
    push bc
    call column_at
    pop bc
.last:
    ld a,b
    jr column_at

; column_at: scan_page on the page at row A, column C, for add_column: first
; take_in_column's range for that page. The page's offset is view_y less its
; first world line; its lines on the screen run from offset + FIRST_LINE (or
; 0) to offset + LAST_LINE (or 255). Nothing for a row outside the map. B,
; C and E kept.
column_at:
    cp MAP_ROWS
    ret nc
    push bc
    push af
    ld b,a
    ld hl,(view_y)
    ld a,h
    sub b
    ld h,a                  ; HL: the page's offset
    push hl
    ld bc,FIRST_LINE
    add hl,bc
    ld a,l
    bit 7,h
    jr z,.first
    xor a                   ; the page starts below the screen's first line
.first:
    ld (take_in_column.first + 1),a
    ld d,a                  ; D: its first line on the screen
    pop hl
    sub l
    ld (take_in_column.base + 1),a      ; that line's screen line
    ld bc,LAST_LINE
    add hl,bc
    ld a,h
    or a
    ld a,l
    jr z,.last
    ld a,255                ; the screen goes on past the page's end
.last:
    sub d
    inc a
    ld (take_in_column.span + 1),a
    pop af
    pop bc
    jp scan_at

; ---------------------------------------------------------------------------
; The entries arriving.

; add_line: the entries whose bottom is on screen line DE that touch what
; shows into the table; add_top: those whose top is. Either from that line's
; page row (inside the map), in the page columns of screen columns -1 and 30
; (one or two), through the tiles' index by bottom or by top.
add_line:
    ld hl,take_on_line
    ld a,LINE_INDEX
    jr add_by
add_top:
    ld hl,take_on_top       ; (its records through the top list)
    ld (scan_listed.take + 1),hl
    ld a,TOP_LIST
    ld (scan_listed.list + 1),a
    ld hl,scan_listed
    ld (scan_at.go + 1),hl
    ld a,TOP_INDEX
    jr add_by.top
add_by:
    ld (scan_page.take + 1),hl
    ld hl,scan_page
    ld (scan_at.go + 1),hl
.top:
    ld (.index + 1),a
    ld a,3                  ; magenta: entries arriving
    out (0xFE),a
    ld a,e
    ld (screen_line),a
    ld hl,(view_y)
    add hl,de
    ld a,h
    cp MAP_ROWS
    ret nc                  ; below the map
    ld a,l
    ld (arriving_line),a
    rrca
    rrca
    rrca
    and 0x1F
.index:
    add a,0                 ; LINE_INDEX or TOP_INDEX
    ld e,a                  ; E: its character row's entry in a tile's index
    ld b,h                  ; B: the page row
    ld a,(view_column)
    ld l,a
    add a,30
    rlca
    rlca
    rlca
    and 7
    ld c,a                  ; C: the page column of screen column 30
    ld a,l
    dec a
    rlca
    rlca
    rlca
    and 7                   ; A: of screen column -1
    cp c
    jr z,.last
    push bc
    ld c,a
    ld a,b
    call scan_at
    pop bc
.last:
    ld a,b
    ; fall into scan_at

; scan_at: scan_page (or scan_listed, as add_top and add_column set) on the
; page at row A, column C. C and E kept.
scan_at:
    add a,a
    add a,a
    add a,a
    add a,c
    ld b,a
.go:
    jp scan_page

; scan_listed: the entries of page B that its tile's index entry E names
; through one of its lists of record numbers (the top list for add_top, by
; take_on_top; the column list for add_column, by take_in_column): the run of
; the list there, each the number of one of its records. B, C and E kept.
scan_listed:
    push bc
    push de
    ld a,b
    ld (.page + 1),a
    call tile_of            ; HL: the tile
    ld d,0
    push hl
    add hl,de               ; at the index entry
    ld c,(hl)               ; C: the run's first place in the top list
    inc hl
    ld a,(hl)               ; A: the next run's
    sub c
    pop hl
    jr z,.done
    ld d,a                  ; D: how many
    push hl
    ld a,l
    add a,PIECES
    ld l,a
    jr nc,.same
    inc h
.same:
    ld (.records + 1),hl    ; its records
    pop hl
    ld a,l
.list:
    add a,TOP_LIST          ; (or COLUMN_LIST)
    ld l,a
    jr nc,.same2
    inc h
.same2:
    ld a,(hl)               ; HL: the list, at the run
    inc hl
    ld h,(hl)
    add a,c
    ld l,a
    jr nc,.number
    inc h
.number:
    ld a,(hl)               ; a record's number
    inc hl
    push hl
    ld l,a
    ld h,0
    add hl,hl               ; 8 bytes a record
    add hl,hl
    add hl,hl
.records:
    ld bc,0
    add hl,bc               ; HL: the record
.page:
    ld b,0                  ; B: the page
.take:
    call take_on_top        ; (or take_in_column)
    pop hl
    dec d
    jr nz,.number
.done:
    pop de
    pop bc
    ret

; scan_page: the entries of page B that its tile's index entry E names (the
; run of its records whose bottom is in a character row) into the table if
; they touch what shows, by take_on_line. B, C and E kept.
scan_page:
    push bc
    push de
    call tile_of            ; HL: the tile
    ld d,0
    push hl
    add hl,de               ; at the index entry
    ld c,(hl)               ; C: the run's first record's number
    inc hl
    ld a,(hl)               ; A: the next run's
    pop hl
    sub c
    jr z,.done
    push af
    ld de,PIECES
    add hl,de
    ld e,c
    ld d,0
    ex de,hl
    add hl,hl               ; 8 bytes a record
    add hl,hl
    add hl,hl
    add hl,de               ; HL: the run's first record
    pop af
    ld d,a                  ; D: how many
.piece:
.take:
    call take_on_line       ; (add_line sets it)
    ld a,l
    add a,R_SIZE
    ld l,a
    jr nc,.same
    inc h
.same:
    dec d
    jr nz,.piece
.done:
    pop de
    pop bc
    ret

; take_on_line: the record at HL in page B, whose bottom is in the arriving
; line's character row, into the table if its bottom is on that line, its
; top is no lower than LAST_SHOWN and its first column is 2 - width to 30.
; take_on_top: the same for one whose top is in the row. B, D and HL kept.
take_on_line:
    inc hl                  ; R_BOTTOM
    ld a,(arriving_line)
    cp (hl)                 ; another line of the row?
    dec hl
    ret nz
    jr take_on
take_on_top:
    push hl
    ld a,l
    add a,R_TOP
    ld l,a
    jr nc,.same
    inc h
.same:
    ld a,(arriving_line)
    cp (hl)
    pop hl
    ret nz
take_on:
    inc hl                  ; its bottom on the screen: the arriving line's
    ld a,(hl)               ; screen line, and as far below it as its bottom
    dec hl                  ; is in the page
    ld c,a
    ld a,(arriving_line)
    neg
    add a,c
    ld c,a
    ld a,(screen_line)
    add a,c
    ld e,a                  ; E: its bottom line on the screen
    push hl
    ld a,l
    add a,R_SHAPE
    ld l,a
    jr nc,.same
    inc h
.same:
    ld c,(hl)               ; C: its shape
    pop hl
    ld a,c
    and 31
    neg
    add a,e                 ; its top less 1, if it is on the screen
    jr nc,.top              ; (no carry: the top is above it)
    cp LAST_SHOWN
    ret nc                  ; its top below LAST_SHOWN
.top:
    ld a,b                  ; its world column: page column * 32 + column
    rrca
    rrca
    rrca
    and 0xE0
    add a,(hl)
    ld (entry_column),a
    push bc
    ld b,a
    ld a,(view_column)
    neg
    add a,b                 ; its screen column, round the world
    inc a                   ; + 1: -1 to 30 are 0 to 31
    cp 32
    jr nc,.out
    ld b,a
    ld a,c                  ; first column >= 2 - width: + 1 >= 3 - width
    rlca
    rlca
    rlca
    and 7
    add a,b
    cp 3
    pop bc
    ret c
    ld a,e
    jr store_entry
.out:
    pop bc
    ret

; take_in_column: the record at HL, in the arriving column, into the table if
; it is as wide as add_column asks, its bottom is on the screen's lines
; FIRST_LINE to LAST_LINE and its top no lower than LAST_SHOWN. column_at
; patches in, for the page being scanned, the first of its lines on the
; screen, how many are, and that first line's screen line; add_column the
; width and the screen column. B, D and HL kept.
take_in_column:
    push hl
    ld a,l
    add a,R_SHAPE
    ld l,a
    jr nc,.same
    inc h
.same:
    ld c,(hl)               ; C: its shape
    pop hl
    ld a,c
    rlca
    rlca
    rlca
    and 7
.width:
    cp 0                    ; the width asked for?
    ret nz
    inc hl
    ld a,(hl)               ; its bottom line in the page
    dec hl
.first:
    sub 0                   ; less the page's first line on the screen
.span:
    cp 0                    ; past the page's lines on the screen (or before)?
    ret nc
.base:
    add a,0                 ; its bottom line on the screen
    ld e,a
    ld a,c
    and 31
    neg
    add a,e                 ; its top less 1, if it is on the screen
    jr nc,.top
    cp LAST_SHOWN
    ret nc                  ; its top below LAST_SHOWN
.top:
    ld a,(view_column)
    ld c,a
.column:
    ld a,0                  ; its screen column (add_column patches it)
    add a,c
    ld (entry_column),a     ; its world column
    ld a,e
    ; fall into store_entry

; store_entry: the record at HL into the table at table_end, its bottom on
; screen line A, its world column entry_column, clipped to lines 0 to
; LAST_SHOWN: its address at the lowest line it draws (LAST_SHOWN or its
; bottom), its graphic from there (a byte a column for each line below the
; screen), and its blitter entered for the pairs from there up to line 0 or
; its top. Its bottom line is odd and its top even, so the pairs split
; cleanly at both edges. The last line's address is kept (address_line):
; the entries arriving on a move are all on one line. Nothing if the table is
; full. All registers but A kept.
store_entry:
    ld c,a                  ; C: its bottom line on the screen
    ld a,(count)
    cp MAX_TABLE
    ret z
    inc a
    ld (count),a
    push bc
    push de
    push hl
    inc hl
    inc hl                  ; R_GRAPHIC
    ld e,(hl)
    inc hl
    ld d,(hl)               ; DE: its whole graphic
    inc hl
    ld b,(hl)               ; B: its shape (R_SHAPE)
    inc hl
    ld a,(hl)               ; R_FILLS
    ld (.fills + 1),a
    ld a,c
    cp LAST_SHOWN + 1
    jr c,.lowest
    ld a,LAST_SHOWN
.lowest:
    ld (.line + 1),a
    ld h,a                  ; H: the lowest line it draws
    ld a,c
    sub h                   ; its lines below the screen: a byte of graphic
    jr z,.pairs             ; each a column to skip
    ld l,a
    ld a,b
    cp 0x40                 ; (width 1: a shape below 2 * 32)
    ld a,l
    jr c,.skip
    add a,l
    bit 5,b                 ; width 3?
    jr z,.skip
    add a,l
.skip:
    add a,e
    ld e,a
    jr nc,.pairs
    inc d
.pairs:
    push de                 ; its graphic from the lowest pair it draws
    ld a,b
    and 31
    ld l,a
    ld a,c
    sub l
    inc a                   ; its top line (INC leaves the carry)
    jr c,.first
    cp FIRST_SHOWN
    jr nc,.top
.first:
    ld a,FIRST_SHOWN        ; above the play area: from its first line
.top:
    neg
    add a,h
    inc a                   ; the lines it draws: 2 a pair, a word a pair in
    ld l,a                  ; blit_entry
    ld a,b
    and 0xE0                ; 32 bytes a width
    add a,l
    add a,low (blit_entry - 32)
    ld (.way + 1),a
    ld l,a
    ld h,high blit_entry    ; (blit_entry is in one page)
    ld e,(hl)
    inc l
    ld d,(hl)
    push de                 ; its blitter's way in
.line:
    ld a,0                  ; the lowest line it draws
    ld hl,address_line
    cp (hl)
    jr z,.known
    ld (hl),a
    inc a                   ; line_table_m1 starts at line -1
    ld l,a
    ld h,0
    add hl,hl
    ld de,line_table_m1
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ld (address_at),hl
    jr .column
.known:
    ld hl,(address_at)
.column:
    ld a,(view_column)
    neg
    ld e,a
    ld a,(entry_column)
    add a,e                 ; its screen column (wrapping along the line)
    add a,l
    ld e,a
    ld d,h                  ; DE: its screen address
    ld hl,(table_end)
    ld (hl),e               ; E_ADDRESS
    inc hl
    ld (hl),d
    inc hl
    pop de
    ld (hl),e               ; E_BLITTER
    inc hl
    ld (hl),d
    inc hl
    pop de
    ld (hl),e               ; E_GRAPHIC
    inc hl
    ld (hl),d
    inc hl
    ld a,(entry_column)
    ld (hl),a               ; E_COLUMN
    inc hl
    ld (hl),c               ; E_LINE
    inc hl
    ld (hl),b               ; E_SHAPE
    inc hl
.fills:
    ld (hl),0               ; E_FILLS
    inc hl
.way:
    ld (hl),0               ; E_WAY
    inc hl
    ld (table_end),hl
    pop hl
    pop de
    pop bc
    ret

; ---------------------------------------------------------------------------
; The table.

; remove_entry: the entry at HL off the table, the last one copied over it.
; All registers but A kept.
remove_entry:
    push bc
    push de
    push hl
    ld hl,count
    dec (hl)
    ld hl,(table_end)       ; the last
    ld bc,-ENTRY
    add hl,bc
    ld (table_end),hl
    pop de
    push de
    ld bc,ENTRY
    ldir
    pop hl
    pop de
    pop bc
    ret

; tile_of: HL = the tile of page B (its indexes, then its records). BC, DE
; kept.
tile_of:
    ld hl,map
    ld a,l
    add a,b
    ld l,a
    jr nc,.same
    inc h
.same:
    ld a,(hl)               ; its tile number
    add a,a
    ld hl,tile_table
    add a,l
    ld l,a
    jr nc,.same2
    inc h
.same2:
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ret

; set_offset: the operand of draw_list's ADD at gfx_offset = fine / 2 *
; GFX_PAGES, the pages on to the fine position's version of each graphic.
set_offset:
    ld a,(fine)
    rrca                    ; fine / 2
    ld b,a
    xor a
    inc b
.page:
    dec b
    jr z,.set
    add a,GFX_PAGES
    jr .page
.set:
    ld (gfx_offset + 1),a
    ret

PAGE_COLUMNS    equ 32
LINE_INDEX      equ 0       ; a tile: 33 bytes of index by bottom's character row
COLUMN_INDEX    equ 33      ; (each a record's number), 33 by column and 33 by
TOP_INDEX       equ 66      ; top's character row (each a place in its column or
COLUMN_LIST     equ 99      ; top list), the two lists' addresses, then its
TOP_LIST        equ 101     ; records by bottom line, and after them the lists:
PIECES          equ 103     ; its records' numbers by column and by top line

saved_sp:       dw 0
fine:           db 0        ; the world's fine position: 0, 2, 4, 6
view_column:    db 0        ; the world column at screen column 0
view_y:         dw VIEW_Y_START - LAST_SHOWN - 1 ; the world line at screen line 0: the start
                            ; view a screen below, to scroll in
count:          db 0        ; the entries in the table
table_end:      dw table    ; and where the next one goes
fill_pending:   db 0        ; FILL_RIGHT after a move right to fine position 0
fill_kind:      db 0
screen_line:    db 0        ; the arriving line's screen line
arriving_line:  db 0        ; and its line in the page
entry_column:   db 0        ; the world column of the entry being stored
column_entry:   db 0        ; add_column's index entry
move_step:      db 0        ; move_lines' lines
move_old:       db 0        ; an entry's bottom line before the move
reclip_shape:   db 0
reclip_lowest:  db 0
address_line:   db 0xFF     ; the last screen line store_entry looked up
address_at:     dw 0        ; and its address

    INCLUDE "output/data.s"
    IF JETMAN
    INCLUDE "jetman.s"
    INCLUDE "output/jetman_data.s"
    ENDIF

table:          ds ENTRY * MAX_TABLE
order:          ds 2 * MAX_TABLE ; build_order's: the entries' addresses in drawing order
order_row:      ds MAX_TABLE    ; each entry's bucket
order_count:    ds ORDER_ROWS   ; each bucket's count, then its next place

; The map and the blocks' records, indexes and lists, below $8000: read only
; when entries arrive, where the contention costs little, and room above for
; the graphics. (The stack runs down from $8000.)
    ORG 0x5B00
    INCLUDE "output/blocks.s"
    ASSERT $ <= 0x7E00

    SAVESNA "output/stepscroll.sna", start
