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
; The table holds the entries on the screen: columns 1 to 30 of lines 0 to
; 175 show (columns 0 and 31 and rows 22 and 23 are black on black). An entry
; is in it while some of its lines are 0 to 175 and its first column is
; 2 - width to 30. One partly off the left or right is drawn from a byte or
; two before or after: screen memory runs on along a pixel line from one
; character row to the next, so what falls off one side lands in a hidden
; column at the other. One partly off the top or bottom is clipped: it draws
; only its row pairs in lines 0 to 175 (store_entry, the moves). Each entry: the screen
; address of the first byte of its lowest line drawn, its blitter's way in
; for the pairs it draws, and its graphic from that pair at fine position 0
; (the others GFX_PAGES pages on), and, for the moves, its world column, its
; bottom line on the screen, its shape, its fills and its way in. The
; order does not matter (overlapping entries write the same bytes): an entry
; leaves by the last one being copied over it. draw_list walks the table
; with SP and jumps to each entry's blitter.
;
; Moving 2 pixels across changes only the fine position's offset; when it
; wraps, every entry moves a byte. Moving 2 lines up or down moves every
; entry 2 lines. Entries come and go at the edges, found through the tiles'
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
LAST_SHOWN  equ 175         ; the screen's last line that shows (rows 22 and 23 are hidden)
MAX_ROWS    equ 24          ; an entry's rows at most (build.py's)
FIRST_LINE  equ 1           ; the bottom lines an entry in the table can have:
LAST_LINE   equ LAST_SHOWN + MAX_ROWS - 2 ; its top 0 to LAST_SHOWN (odd: 197)
LAST_TOP    equ LAST_SHOWN - 1 ; the top line of entries arriving at the bottom

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
    xor a
    out (0xFE),a
; The border shows each stage of a pass: red the fills, green the list
; drawn, blue a move's bookkeeping, magenta the entries arriving, black idle.
; A pass is a frame, and makes one move of the world at most: the entries
; redraw what a single move changes, so the list must be drawn after each.
main:
    call wait_mark          ; the beam is past what shows: draw now, all the
                            ; way round to the top of the next frame
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
    ld a,(jet_on)
    or a
    jr z,.keys
    ld a,1                  ; blue: his move (every other pass) and the view's
    out (0xFE),a
    call jet_update
    xor a
    out (0xFE),a
    jr main
.keys:
    ENDIF
    ld a,1                  ; blue: the move
    out (0xFE),a
    call keys
    IF JETMAN
    call jet_update         ; (he starts once the world has scrolled in)
    ENDIF
    xor a
    out (0xFE),a
    jr main

; wait_mark: until the beam is in rows 22 and 23, past what shows. Port
; $00FF: a high byte of $40-$7F would be contended, held till the ULA's fetch
; is over, and read only the idle $FF. The floating bus: the attribute the
; ULA is fetching, rows 22 and 23's RASTER_MARK (a pixel byte of $40
; anywhere can start it early).
wait_mark:
    xor a
    in a,(0xFF)
    cp RASTER_MARK
    jr nz,wait_mark
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
; draw_list: every entry, by its blitter. The walker keeps the next entry in
; HL' and SP in the table; for each it pops the screen address, the blitter
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
    ld hl,table             ; HL': the next entry; BC': an entry's size
    ld bc,ENTRY
    exx
draw_next:
    exx
    ld sp,hl                ; SP at this entry, HL' at the next
    add hl,bc
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
; keys: P moves the world 2 pixels right, O 2 pixels left; if neither, Q
; moves it 2 lines up, A 2 lines down. One move a frame.

keys:
    ld hl,(view_y)          ; scrolling in at the start: up until the view is
    ld de,VIEW_Y_START      ; where the world starts
    or a
    sbc hl,de
    jr c,up
    ld a,0xDF               ; the half-row Y U I O P
    in a,(0xFE)
    bit 0,a                 ; P
    jp z,right
    bit 1,a                 ; O
    jp z,left
    ld a,0xFB               ; Q
    in a,(0xFE)
    rra
    jr nc,up
    ld a,0xFD               ; A
    in a,(0xFE)
    rra
    ret c
    ; fall into down

; down: the world 2 lines down (the view 2 lines up the map): every entry 2
; lines down, those whose top goes below LAST_SHOWN off; those whose bottom
; is now at FIRST_LINE on.
down:
    ld hl,(view_y)
    ld a,h
    or l
    ret z                   ; the map's top
    dec hl
    dec hl
    ld (view_y),hl
    call move_down
    ld de,FIRST_LINE
    jp add_line

; up: the world 2 lines up: every entry 2 lines up, those whose bottom goes
; above the screen off; those whose top is now at LAST_TOP on.
up:
    ld hl,(view_y)
    ld de,VIEW_Y_MAX
    or a
    sbc hl,de
    ret z                   ; the map's bottom
    add hl,de
    inc hl
    inc hl
    ld (view_y),hl
    call move_up
    ld de,LAST_TOP
    jp add_top

; move_down: every entry 2 lines down, in place: those whose top goes below
; LAST_SHOWN off the table; the rest's addresses 2 lines down, except where
; one is clipped. An entry clipped at the top before draws a pair more (its
; way in a pair earlier); one clipped at the bottom now draws a pair fewer,
; still from LAST_SHOWN, its graphic a pair on. Its bottom line is odd, so the
; first line down may cross into the next character row (told from L + 1, as
; in the blitters) and the second never does.
move_down:
    ld a,(count)
    or a
    ret z
    ld b,a
    ld hl,table
.entry:
    push hl
    ld de,E_LINE
    add hl,de
    ld a,(hl)               ; its bottom line, 2 down
    add a,2
    ld (hl),a
    ld e,a                  ; E: its bottom line
    inc hl
    ld c,(hl)               ; C: its shape (E_SHAPE)
    ld a,c
    and 31
    ld d,a                  ; D: its rows
    ld a,e
    sub d                   ; its top line less 1
    pop hl
    jr c,.top               ; top 0 or above: it was clipped at the top
    cp LAST_SHOWN
    jr nc,.off              ; top below LAST_SHOWN
    ld a,e
    cp LAST_SHOWN + 1
    jr nc,.bottom           ; bottom below LAST_SHOWN
.move:
    inc hl
    ld d,(hl)               ; H
    inc d
    ld a,d
    and 7
    jr nz,.second
    dec hl
    ld a,(hl)               ; into the next character row; a third's last row
    inc a                   ; carries into the next third
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
.next:
    ld de,ENTRY
    add hl,de
    djnz .entry
    ret
.off:
    call remove_entry       ; the last entry in its place, to move next
    djnz .entry
    ret
.top:
    ld a,2                  ; a pair more, its lowest line moving down with it
    call way_step
    jr .move
.bottom:
    ld a,c                  ; a pair fewer: still from LAST_SHOWN, a pair on
    call skip_pair          ; in its graphic
    ld a,-2
    call way_step
    jr .next

; move_up: every entry 2 lines up, in place: those whose bottom was at
; FIRST_LINE off the table; the rest's addresses 2 lines up, except where one
; is clipped. An entry clipped at the bottom before draws a pair more, still
; from LAST_SHOWN, its graphic a pair back; one clipped at the top now draws a
; pair fewer (its way in a pair later). The first line up never leaves the
; character row (the bottom line is odd); the second may.
move_up:
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
    cp FIRST_LINE
    jr z,.off
    sub 2                   ; its bottom line, 2 up
    ld (hl),a
    ld e,a                  ; E: its bottom line
    inc hl
    ld c,(hl)               ; C: its shape (E_SHAPE)
    ld a,c
    and 31
    ld d,a                  ; D: its rows
    pop hl
    ld a,e
    cp LAST_SHOWN
    jr nc,.bottom           ; bottom LAST_SHOWN or below: it was clipped at the bottom
    inc a
    sub d                   ; its top line
    jr c,.top               ; above the screen
.move:
    inc hl
    ld d,(hl)
    dec d
    dec d
    ld a,d
    inc a
    and 7
    jr nz,.done
    dec hl
    ld a,(hl)               ; into the character row above; a third's top row
    inc a                   ; borrows into the third above
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
.next:
    ld de,ENTRY
    add hl,de
    djnz .entry
    ret
.off:
    pop hl
    call remove_entry
    djnz .entry
    ret
.top:
    ld a,-2                 ; a pair fewer, its lowest line moving up with it
    call way_step
    jr .move
.bottom:
    ld a,c                  ; a pair more: still from LAST_SHOWN, a pair back
    call unskip_pair        ; in its graphic
    ld a,2
    call way_step
    jr .next

; way_step: the entry at HL's way in A bytes on in blit_entry (2 a pair
; more, -2 a pair fewer), and its blitter from there. All registers but A kept.
way_step:
    push de
    push hl
    ld de,E_WAY
    add hl,de
    add a,(hl)
    ld (hl),a
    ld e,a
    ld d,high blit_entry    ; (blit_entry is in one page)
    pop hl
    push hl
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
    ret

; skip_pair: the graphic of the entry at HL, whose shape is A, a pair of rows
; on (2 * width bytes); unskip_pair: a pair back. All registers but A kept.
skip_pair:
    rrca
    rrca
    rrca
    rrca
    and 0x0E                ; 2 * width
    push hl
    inc hl
    inc hl
    inc hl
    inc hl                  ; E_GRAPHIC
    add a,(hl)
    ld (hl),a
    inc hl
    jr nc,.done
    inc (hl)
.done:
    pop hl
    ret

unskip_pair:
    rrca
    rrca
    rrca
    rrca
    and 0x0E                ; 2 * width
    push bc
    push hl
    ld c,a
    inc hl
    inc hl
    inc hl
    inc hl                  ; E_GRAPHIC
    ld a,(hl)
    sub c
    ld (hl),a
    inc hl
    jr nc,.done
    dec (hl)
.done:
    pop hl
    pop bc
    ret

; ---------------------------------------------------------------------------
; Across.

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
    ld (scan_page.take + 1),hl
    ld hl,scan_page
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
    ld hl,scan_tops         ; (its records through the top list)
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

; scan_at: scan_page (or scan_tops, as add_top sets) on the page at row A,
; column C. C and E kept.
scan_at:
    add a,a
    add a,a
    add a,a
    add a,c
    ld b,a
.go:
    jp scan_page

; scan_tops: for add_top, the entries of page B whose tops are in the
; character row that its tile's TOP_INDEX entry E names, by take_on_top: the
; run of its top list there, each a number of one of its records. B, C and E
; kept.
scan_tops:
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
    add a,TOP_LIST
    ld l,a
    jr nc,.same2
    inc h
.same2:
    ld a,(hl)               ; HL: its top list, at the run
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
    call take_on_top
    pop hl
    dec d
    jr nz,.number
.done:
    pop de
    pop bc
    ret

; scan_page: the entries of page B that its tile's index entry E names (the
; run in a character row, or in a column) into the table if they touch what
; shows, by take_in_column or take_on_line. B, C and E kept.
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
    call take_in_column     ; or take_on_line (add_column, add_line set it)
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
    jr nc,.top
    xor a                   ; above the screen: from line 0
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
LINE_INDEX      equ 0       ; a tile: 33 bytes of index by bottom's character row,
COLUMN_INDEX    equ 33      ; 33 by column (each a record's number), 33 by top's
TOP_INDEX       equ 66      ; character row (each a place in its top list), its
TOP_LIST        equ 99      ; top list's address, then its records by bottom line
PIECES          equ 101     ; and by column (and after them its top list: its
                            ; records' numbers, by top line)

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
address_line:   db 0xFF     ; the last screen line store_entry looked up
address_at:     dw 0        ; and its address

    INCLUDE "output/data.s"
    IF JETMAN
    INCLUDE "jetman.s"
    INCLUDE "output/jetman_data.s"
    ENDIF

table:          ds ENTRY * MAX_TABLE

    SAVESNA "output/stepscroll.sna", start
