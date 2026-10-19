; stepscroll: listscroll's display list over a world of Cyberun's own terrain
; steps, many screens wide and high, moved 2 pixels a frame by the keys: O and
; P left and right, round the world, Q and A up and down, as far as the map
; goes.
;
; The world is a map of pages, 8 across (256 columns: a world column is a
; byte and wraps by itself) and MAP_ROWS down, each 32 columns by 256 lines.
; Each page is a tile, and a tile is a list of entries, each part of one of
; Cyberun's steps drawn by the blitter for its shape (3x4 a flat step, 1x4 the
; byte after a flat run, 2x8 a 45-degree slope, 3x8 a gentle one, 2x16 a
; steep slope or a wall: bytes by rows). A tile holds its entries twice,
; sorted by bottom line and by column, with an index of where each character
; row's or column's run starts.
;
; The table holds the entries on the screen: columns 1 to 30 of rows 0 to 21
; show (columns 0 and 31 and rows 22 and 23 are black on black). An entry is
; in it while its bottom line is -1 to 191 and its first column is 2 - width
; to 30. One partly off the left or right is drawn from a byte or two before
; or after: screen memory runs on along a pixel line from one character row
; to the next, so what falls off one side lands in a hidden column at the
; other. One partly off the top draws into the ROM, which ignores it. Each
; entry: the screen address of its bottom line's first byte, its blitter and
; its graphic at fine position 0 (the others 64, 128 and 192 bytes on), and,
; for the moves, its world column, its bottom line on the screen, its shape
; and its fills. The order does not matter (overlapping entries write the
; same bytes): an entry leaves by the last one being copied over it.
; draw_list walks the table with SP and jumps to each entry's blitter.
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

RASTER_MARK equ 0x40        ; bright black: the hidden rows' attribute
MAX_TABLE   equ 110         ; entries the table holds
ENTRY       equ 10          ; bytes an entry
FIRST_LINE  equ -1          ; the bottom lines an entry in the table has
LAST_LINE   equ 191

; An entry's bytes.
E_ADDRESS   equ 0
E_BLITTER   equ 2
E_GRAPHIC   equ 4
E_COLUMN    equ 6           ; its world column
E_LINE      equ 7           ; its bottom line on the screen (-1 to 191)
E_SHAPE     equ 8           ; width * 32 + rows
E_FILLS     equ 9           ; 2 bits each: above (down), below (up), left (right)

; A tile's entry record: column and bottom line in the page, graphic,
; blitter, shape, fills.
R_SIZE      equ 8

FILL_RIGHT  equ 1
FILLS       equ 0           ; 1: paint the column a move right leaves (fills); 0: don't, to see it

    ORG 0x8000

start:
    di                      ; interrupts off for good: main waits on the
    ld sp,0x8000            ; floating bus, and draw_list borrows SP
    ld hl,screen_start      ; the world, white ink on black
    ld de,0x4000
    ld bc,6144
    ldir
    ld h,d
    ld l,e
    inc de
    ld (hl),0x47
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
main:
.raster:
    xor a                   ; port $00FF: a high byte of $40-$7F would be
    in a,(0xFF)             ; contended, held till the ULA's fetch is over, and
                            ; read only the idle $FF. The floating bus: the
                            ; attribute the ULA is fetching
    cp RASTER_MARK          ; rows 22 and 23's attribute: the beam is past
    jr nz,.raster           ; what shows, so draw now, all the way round to
                            ; the top of the next frame (a pixel byte of $40
                            ; anywhere can start it early)
    ld a,2                  ; red: the fills
    out (0xFE),a
    call fills
    ld a,4                  ; green: the list
    out (0xFE),a
    call draw_list
    ld a,1                  ; blue: the move
    out (0xFE),a
    call keys
    xor a
    out (0xFE),a
    jr main

; fill_table: the table as the world starts: the entries whose bottom is on
; each line from FIRST_LINE to LAST_LINE.
fill_table:
    xor a
    ld (count),a
    ld hl,table
    ld (table_end),hl
    ld de,FIRST_LINE
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
; (the lower left to right, the upper right to left), and jumps back.

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
    ld a,l                  ; this fine position's version, in the same page:
gfx_offset:
    add a,0                 ; 0, 32, 64 or 96 (set_offset patches it)
    ld l,a
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

; fill_left: the column to the left of the entry at IX, its rows. Nothing
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
; lines down, those at line 191 off; those now at FIRST_LINE on.
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

; up: the world 2 lines up: every entry 2 lines up, those at FIRST_LINE off;
; those now at LAST_LINE on.
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
    ld de,LAST_LINE
    jp add_line

; move_down: every entry's address 2 lines down, in place, and those at
; LAST_LINE off the table. Its bottom line is odd, so the first line down may
; cross into the next character row (told from L + 1, as in the blitters)
; and the second never does. An entry coming down from line -1, whose
; address was in the ROM, is looked up afresh.
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
    ld a,(hl)               ; its bottom line
    cp LAST_LINE
    jr z,.off
    inc a
    inc a
    ld (hl),a
    pop hl
    cp 1
    jr z,.fresh
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
    pop hl
    call remove_entry       ; the last entry in its place, to move next
    djnz .entry
    ret
.fresh:
    push hl
    pop ix
    call line_address_x     ; line 1 (A)
    ld (ix + E_ADDRESS),l
    ld (ix + E_ADDRESS + 1),h
    push ix
    pop hl
    jr .next

; move_up: every entry's address 2 lines up, in place, and those at
; FIRST_LINE off the table. The first line up never leaves the character row
; (the bottom line is odd); the second may. Going up from line 1 to -1 lands
; in the ROM, where draw_list's writes do nothing.
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
    cp FIRST_LINE & 0xFF
    jr z,.off
    dec a
    dec a
    ld (hl),a
    pop hl
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
    ld de,ENTRY
    add hl,de
    djnz .entry
    ret
.off:
    pop hl
    call remove_entry
    djnz .entry
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

; add_line: the entries whose bottom is on screen line DE (signed) that
; touch what shows into the table: in that line's page row (inside the
; map), in the page columns of screen columns -1 and 30 (one or two).
add_line:
    ld a,3                  ; magenta: entries arriving
    out (0xFE),a
    ld hl,line_table_m1     ; the line's screen address, for take_on_line
    inc de
    add hl,de
    add hl,de
    dec de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ld (line_address),hl
    ld a,e
    ld (screen_line),a
    ld hl,take_on_line
    ld (scan_page.take + 1),hl
    ld hl,(view_y)
    add hl,de
    ld a,h
    cp MAP_ROWS
    ret nc                  ; above or below the map
    ld a,l
    ld (arriving_line),a
    rrca
    rrca
    rrca
    and 0x1F
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

; scan_at: scan_page on the page at row A, column C. C and E kept.
scan_at:
    add a,a
    add a,a
    add a,a
    add a,c
    ld b,a
    ; fall into scan_page

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
; line's character row, into the table if its bottom is on that line and its
; first column is 2 - width to 30. B, D and HL kept.
take_on_line:
    inc hl
    ld a,(arriving_line)
    cp (hl)                 ; another line of the row?
    dec hl
    ret nz
    ld a,b                  ; its world column: page column * 32 + column
    rrca
    rrca
    rrca
    and 0xE0
    add a,(hl)
    ld (entry_column),a
    ld c,a
    ld a,(view_column)
    neg
    add a,c                 ; its screen column, round the world
    inc a                   ; + 1: -1 to 30 are 0 to 31
    cp 32
    ret nc
    ld c,a
    push hl                 ; first column >= 2 - width: + 1 >= 3 - width
    ld a,l
    add a,6
    ld l,a
    jr nc,.same
    inc h
.same:
    ld a,(hl)
    pop hl
    rlca
    rlca
    rlca
    and 7
    add a,c
    cp 3
    ret c
    dec c                   ; C: its screen column
    push de
    ld a,(line_address)
    add a,c
    ld e,a
    ld a,(line_address + 1)
    ld d,a                  ; DE: its screen address
    ld a,(screen_line)
    jr store_entry

; take_in_column: the record at HL, in the arriving column, into the table if
; it is as wide as add_column asks and its bottom is on the screen's lines
; FIRST_LINE to LAST_LINE. column_at patches in, for the page being
; scanned, the first of its lines on the screen, how many are, and that
; first line's screen line; add_column the width and the screen column.
; B, D and HL kept.
take_in_column:
    push hl
    ld a,l
    add a,6
    ld l,a
    jr nc,.same
    inc h
.same:
    ld a,(hl)
    pop hl
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
    add a,0                 ; its screen line
    ld c,a
    push de
    push hl
    push bc
    inc a                   ; line_table_m1 starts at line -1
    ld l,a
    ld h,0
    add hl,hl
    ld de,line_table_m1
    add hl,de
    ld a,(hl)
.column:
    add a,0                 ; its screen column (wrapping along the line)
    ld e,a
    inc hl
    ld d,(hl)               ; DE: its screen address
    pop bc
    pop hl
    ld a,(view_column)
    push bc
    ld c,a
    ld a,(take_in_column.column + 1)
    add a,c
    ld (entry_column),a     ; its world column
    pop bc
    ld a,c                  ; its screen line
    ; fall into store_entry

; store_entry: the record at HL into the table at table_end: screen address
; DE, screen line A, world column entry_column; the DE pushed by its caller
; restored. HL kept. Nothing if the table is full.
store_entry:
    ld (.line + 1),a
    ld a,(count)
    cp MAX_TABLE
    jr z,.full
    push hl
    push bc
    inc hl
    inc hl
    ld c,(hl)               ; the graphic
    inc hl
    ld b,(hl)
    inc hl
    push bc
    ld c,(hl)               ; the blitter
    inc hl
    ld b,(hl)
    inc hl
    push hl                 ; at its shape
    ld hl,(table_end)
    ld (hl),e               ; E_ADDRESS
    inc hl
    ld (hl),d
    inc hl
    ld (hl),c               ; E_BLITTER
    inc hl
    ld (hl),b
    inc hl
    pop de                  ; DE: at its shape
    pop bc
    ld (hl),c               ; E_GRAPHIC
    inc hl
    ld (hl),b
    inc hl
    ld a,(entry_column)     ; E_COLUMN
    ld (hl),a
    inc hl
.line:
    ld (hl),0               ; E_LINE
    inc hl
    ld a,(de)               ; E_SHAPE
    ld (hl),a
    inc hl
    inc de
    ld a,(de)               ; E_FILLS
    ld (hl),a
    inc hl
    ld (table_end),hl
    ld hl,count
    inc (hl)
    pop bc
    pop hl
.full:
    pop de
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

; set_offset: the operand of draw_list's ADD at gfx_offset = fine / 2 * 64,
; where the fine position's version of each graphic is.
set_offset:
    ld a,(fine)
    add a,a
    add a,a
    add a,a
    add a,a
    add a,a                 ; (fine / 2 * GFX_SLOT: 64 bytes a slot)
    ld (gfx_offset + 1),a
    ret

PAGE_COLUMNS    equ 32
LINE_INDEX      equ 0       ; a tile: 33 bytes of index by character row,
COLUMN_INDEX    equ 33      ; 33 by column (each a record's number),
PIECES          equ 66      ; then its records by line, then by column

saved_sp:       dw 0
fine:           db 0        ; the world's fine position: 0, 2, 4, 6
view_column:    db 0        ; the world column at screen column 0
view_y:         dw VIEW_Y_START ; the world line at screen line 0
count:          db 0        ; the entries in the table
table_end:      dw table    ; and where the next one goes
fill_pending:   db 0        ; FILL_RIGHT after a move right to fine position 0
fill_kind:      db 0
line_address:   dw 0        ; the arriving line's screen address, at column 0
screen_line:    db 0        ; and its screen line
arriving_line:  db 0        ; and its line in the page
entry_column:   db 0        ; the world column of the entry being stored
column_entry:   db 0        ; add_column's index entry

    INCLUDE "output/data.s"

table:          ds ENTRY * MAX_TABLE

    SAVESNA "output/stepscroll.sna", start
