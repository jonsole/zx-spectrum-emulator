; listscroll: a world of rock (the $55/$AA checker) and sky, many screens
; wide and high, whose edges are a display list, walked every frame and moved
; 2 pixels a frame by the keys: O and P left and right, round the world, Q
; and A up and down, as far as the map goes.
;
; The world is a map of pages, MAP_COLUMNS across and MAP_ROWS down, each 32
; columns by 256 lines. Across it wraps round: 8 pages are 256 columns, so a
; world column is a byte and wraps by itself. Down it does not: a world line
; is the page row in its high byte and the line in the page in its low. Each
; page is a tile, and a tile is a list of pieces: column in the page, bottom
; line in the page, graphic. It holds them twice, sorted by bottom line and
; by column, each with an index of where each line's or column's run starts,
; so that the pieces arriving on a line or in a column are read and no
; others.
;
; The table holds the pieces that touch what shows: columns 1 to 30 of rows 1
; to 22 (columns 0 and 31 and rows 0 and 23 are black on black). That is
; every piece whose window is at screen column 0 to 30 and whose bottom line
; is 9 to 189, all on the bitmap. Each entry is the screen address of the
; bottom line of its 2-byte window and its graphic at fine position 0 (its
; versions for 2, 4 and 6 follow, 16 bytes apart in the same page). The order
; does not matter, since overlapping pieces write the same bytes: an entry
; leaves by the last one being copied over it. draw_list walks the table with
; SP and draws each entry 8 lines high.
;
; Moving 2 pixels across changes only the fine position's offset. When it
; wraps, every entry moves a byte; those it takes to column 31 (from 30, or
; from 0 round to -1) leave, and the pieces in the column arriving at 0 or 30
; come on, found in the one or two pages that column holds on the screen.
; Moving 2 lines up or down moves every entry 2 lines; those it takes to line
; 7 or 191 leave, and the pieces whose bottom arrives at line 189 or 9 come
; on, found in the one or two pages across that line. Nothing is cleared: sky
; and the checker look the same after a move.
;
; build.py makes output/data.s: the graphics (gfx), the map (a tile number a
; page), tile_table (each tile's address) and the tiles (a count, then the
; pieces), line_table and the screen as the world starts (screen_start).

    DEVICE ZXSPECTRUM48

IM2_TABLE   equ 0xFE00
IM2_JUMP    equ 0xFDFD
MAX_TABLE   equ 64          ; entries the table holds (a screen has about 30)
FIRST_LINE  equ 9           ; the bottom lines a piece in the table has: those
LAST_LINE   equ 189         ; touching rows 1 to 22, all of it on the bitmap

    ORG 0x8000

start:
    di
    ld sp,0x8000
    ld hl,IM2_TABLE         ; IM 2, every vector at IM2_JUMP: JP isr
    ld de,IM2_TABLE + 1
    ld bc,256
    ld (hl),high IM2_JUMP
    ldir
    ld a,0xC3
    ld (IM2_JUMP),a
    ld hl,isr
    ld (IM2_JUMP + 1),hl
    ld a,high IM2_TABLE
    ld i,a
    im 2
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
    ld hl,0x5800            ; columns 0 and 31 black on black
    ld de,31
    ld b,24
.hide:
    ld (hl),0
    add hl,de
    ld (hl),0
    inc hl
    djnz .hide
    ld hl,0x5800            ; and rows 0 and 23
    ld de,0x5801
    ld bc,31
    ld (hl),0
    ldir
    ld hl,0x5AE0
    ld de,0x5AE1
    ld bc,31
    ld (hl),0
    ldir
    call fill_table
    xor a
    out (0xFE),a
    ei
main:
    halt
    ld a,4                  ; green border while the list is drawn
    out (0xFE),a
    call draw_list
    xor a
    out (0xFE),a
    call keys
    jr main

isr:
    ei
    ret

; fill_table: the table as the world starts: the pieces whose bottom is on
; each line from FIRST_LINE to LAST_LINE.
fill_table:
    xor a
    ld (count),a
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
; draw_list: the count entries, each a graphic 2 bytes wide and 8 lines high,
; its bottom line's first byte at the entry's address (an odd line). Each
; pair of lines is the lower left to right, the upper right to left. The blit
; is unrolled: four pairs, the character-row fix-up out of line, jumped to
; only on the rarer crossing, and none after the last pair.

    MACRO BLIT2_PAIR
    pop de
    ld (hl),e
    inc l
    ld (hl),d
    dec h                   ; up a line: never out of the character row (odd line)
    pop de
    ld (hl),e
    dec l
    ld (hl),d
    dec h                   ; up again: maybe into the character row above
    ENDM

    MACRO BLIT2_CROSS back  ; HL went from line 0 of a character row to line 7
    ld a,l                  ; of the one above: back a character row; if that
    sub 32                  ; borrowed it was the third's top row and H's own
    ld l,a                  ; borrow was right, else put H back in its third
    jr c,back
    ld a,h
    add a,8
    ld h,a
    jp back                 ; JP: 10 T-states, a taken JR 12
    ENDM

draw_list:
    ld a,(count)
    or a
    ret z
    ld b,a                  ; B counts the entries down
    di                      ; SP will be in the graphics (and the other
    ld (saved_sp),sp        ; registers are the walk's)
    exx
    ld hl,table             ; HL': the next entry; BC': an entry's size
    ld bc,4
    exx
draw_next:
    exx
    ld sp,hl                ; SP at this entry, HL' at the next
    add hl,bc
    exx
    pop de                  ; the screen address
    pop hl                  ; the graphic, at fine position 0
    ld a,l                  ; this fine position's version, in the same page:
gfx_offset:
    add a,0                 ; 0, 16, 32 or 48 (set_offset patches it)
    ld l,a
    ld sp,hl
    ex de,hl
    BLIT2_PAIR
    ld a,h
    inc a
    and 7
    jr z,.cross1
.back1:
    BLIT2_PAIR
    ld a,h
    inc a
    and 7
    jr z,.cross2
.back2:
    BLIT2_PAIR
    ld a,h
    inc a
    and 7
    jr z,.cross3
.back3:
    BLIT2_PAIR
    djnz draw_next
    ld sp,(saved_sp)
    ei
    ret
.cross1:
    BLIT2_CROSS .back1
.cross2:
    BLIT2_CROSS .back2
.cross3:
    BLIT2_CROSS .back3

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
; lines down, those now at line 191 off, those now at FIRST_LINE on.
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

; up: the world 2 lines up: every entry 2 lines up, those now at line 7 off,
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

; move_down: every entry's screen address 2 lines down, and those it takes to
; line 191 off the table. An entry is on an odd line, so 2 lines down stays
; in its character row except from line 7, to line 1 of the row below: then
; H's low bits carried into the third's, which is right only if the row
; crossed into the next third too (L carried), else H goes back 8.
move_down:
    ld a,(count)
    or a
    ret z
    ld b,a                  ; B: the entries still to move
    ld hl,table
.entry:
    inc hl
    ld a,(hl)
    add a,2
    ld (hl),a
    cp 0x57                 ; line 7 of a row in the bottom third: maybe 191
    jr z,.bottom
    and 7
    cp 1
    jr z,.row
.next:
    inc hl
    inc hl
    inc hl
    djnz .entry
    ret
.row:
    dec hl
    ld a,(hl)
    add a,32
    ld (hl),a
    inc hl
    jr c,.next
    ld a,(hl)
    sub 8
    ld (hl),a
    jr .next
.bottom:
    dec hl
    ld a,(hl)
    inc hl
    cp 0xE0                 ; row 23?
    jr c,.next
    dec hl
    call remove_entry       ; the last entry in its place, to move next
    djnz .entry
    ret

; move_up: every entry's screen address 2 lines up, and those it takes to
; line 7 off the table. As move_down: from line 1 to line 7 of the row above,
; H borrowed from the third's bits, right only if L borrowed too, else H
; goes on 8.
move_up:
    ld a,(count)
    or a
    ret z
    ld b,a
    ld hl,table
.entry:
    inc hl
    ld a,(hl)
    sub 2
    ld (hl),a
    and 7
    cp 7
    jr z,.row
.next:
    inc hl
    inc hl
    inc hl
    djnz .entry
    ret
.row:
    dec hl
    ld a,(hl)
    sub 32
    ld (hl),a
    inc hl
    jr c,.next
    ld a,(hl)
    add a,8
    ld (hl),a
    cp 0x47                 ; line 7 of a row in the top third: maybe line 7
    jr nz,.next
    dec hl
    ld a,(hl)
    inc hl
    cp 0x20                 ; row 0?
    jr nc,.next
    dec hl
    call remove_entry
    djnz .entry
    ret

; ---------------------------------------------------------------------------
; Across.

; right: the world 2 pixels right. From fine position 6 to 0 the screen's
; first column is a world column further left: every entry a byte right,
; those at column 31 off, and those of the world column now at column 0 on.
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
    ld a,(view_column)
    jr add_column

; left: the world 2 pixels left. From fine position 0 to 6 the screen's
; first column is a world column further right: every entry a byte left,
; those off at column -1 off, and those of the world column now at column 30
; on.
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
    ld a,(view_column)
    add a,30
    ; fall into add_column

; add_column: the pieces in world column A that touch what shows into the
; table: in its page column, in the page rows of screen lines FIRST_LINE and
; LAST_LINE (one or two).
add_column:
    ld hl,take
    ld (scan_page.take + 1),hl
    ld c,a
    and PAGE_COLUMNS - 1
    add a,COLUMN_INDEX
    ld e,a                  ; E: its column's entry in a tile's index
    ld a,c
    rlca
    rlca
    rlca
    and 7
    ld c,a                  ; C: its page column
    ld hl,(view_y)
    ld a,l
    add a,LAST_LINE
    ld a,h
    adc a,0
    ld b,a                  ; B: the page row of the bottom line
    ld a,l
    add a,FIRST_LINE
    ld a,h
    adc a,0                 ; A: of the top
    cp b
    jr z,.last
    push bc
    call scan_at
    pop bc
.last:
    ld a,b
    jr scan_at

; move_entries: every entry's screen address C bytes across (1 or -1), in its
; column's 5 bits (a column stays in its character row); those that come to
; column 31 (from 30, or from 0 round) off the table.
move_entries:
    ld a,(count)
    or a
    ret z
    ld b,a                  ; B: the entries still to move
    ld hl,table
.entry:
    ld a,(hl)
    and 0xE0
    ld e,a
    ld a,(hl)
    add a,c
    and 0x1F
    cp 31
    jr z,.off
    or e
    ld (hl),a
    inc hl
    inc hl
    inc hl
    inc hl
    djnz .entry
    ret
.off:
    call remove_entry       ; the last entry in its place, to move next
    djnz .entry
    ret

; ---------------------------------------------------------------------------
; The pieces arriving.

; add_line: the pieces whose bottom is on screen line DE that touch what
; shows into the table: in that line's page row, in the page columns of
; screen columns 0 and 30 (one or two).
add_line:
    ld hl,line_table        ; the line's screen address, for take_on_line
    add hl,de
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ld (line_address),hl
    ld hl,take_on_line
    ld (scan_page.take + 1),hl
    ld hl,(view_y)
    add hl,de
    ld a,l
    srl a
    ld e,a                  ; E: the line's entry in a tile's index (odd: line / 2)
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
    rlca
    rlca
    rlca
    and 7                   ; A: of screen column 0
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

; scan_page: the pieces of page B that its tile's index entry E names (the
; run on a line, or in a column) into the table if they touch what shows, by
; take or take_on_line. B, C and E kept.
scan_page:
    push bc
    push de
    call tile_of            ; HL: the tile
    ld d,0
    push hl
    add hl,de               ; at the index entry
    ld c,(hl)               ; C: the run's first piece, as an offset from PIECES
    inc hl
    ld a,(hl)               ; A: the next run's
    pop hl
    sub c                   ; 4 bytes a piece
    jr z,.done
    rrca
    rrca
    push af
    ld de,PIECES
    add hl,de
    ld e,c
    ld d,0
    add hl,de               ; HL: the run's first piece
    pop af
    ld d,a                  ; D: how many
.piece:
.take:
    call take               ; or take_on_line (add_column, add_line set it)
    inc hl
    inc hl
    inc hl
    inc hl
    dec d
    jr nz,.piece
.done:
    pop de
    pop bc
    ret

; take_on_line: the piece at HL in page B, whose bottom is on the arriving
; line (line_address: its screen address at column 0), into the table if its
; window is at screen column 0 to 30. B, D and HL kept.
take_on_line:
    ld a,(count)
    cp MAX_TABLE
    ret z
    ld a,(view_column)
    ld c,a
    ld a,b                  ; its world column: page column * 32 + column
    rrca
    rrca
    rrca
    and 0xE0
    add a,(hl)
    sub c                   ; its screen column, round the world
    cp 31
    ret nc
    push de
    push hl
    ld c,a
    ld hl,(line_address)
    ld a,l
    add a,c
    ld e,a
    ld d,h                  ; DE: its screen address
    pop hl
    push hl
    inc hl
    inc hl
    ld c,(hl)
    inc hl
    ld a,(hl)
    push af                 ; A, C: its graphic
    ld a,(count)
    inc a
    ld (count),a
    dec a
    call entry_at
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (hl),c
    inc hl
    pop af
    ld (hl),a
    pop hl
    pop de
    ret

; take: the piece at HL in page B into the table if it touches what shows:
; its window at screen column 0 to 30 and its bottom at line FIRST_LINE to
; LAST_LINE. Its entry: line_table at its bottom line, plus its column; its
; graphic. All registers but A kept.
take:
    push bc
    push de
    push hl
    ld a,(count)
    cp MAX_TABLE
    jr z,.done
    ld a,b                  ; its world column: page column * 32 + column
    rrca
    rrca
    rrca
    and 0xE0
    add a,(hl)
    ld c,a
    ld a,(view_column)
    ld e,a
    ld a,c
    sub e                   ; its screen column, round the world
    cp 31
    jr nc,.done
    ld c,a                  ; C: its screen column
    inc hl
    ld e,(hl)               ; DE: its world line: page row, line in the page
    ld a,b
    rrca
    rrca
    rrca
    and 0x1F
    ld d,a
    inc hl
    push hl                 ; at its graphic
    ld hl,(view_y)
    ex de,hl
    or a
    sbc hl,de               ; HL: its screen line
    ld a,h
    or a
    jr nz,.off
    ld a,l
    cp FIRST_LINE
    jr c,.off
    cp LAST_LINE + 1
    jr nc,.off
    add hl,hl
    ld de,line_table
    add hl,de
    ld a,(hl)
    add a,c
    ld e,a
    inc hl
    ld d,(hl)               ; DE: its screen address
    pop hl
    ld c,(hl)
    inc hl
    ld b,(hl)               ; BC: its graphic
    ld a,(count)
    call entry_at
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (hl),c
    inc hl
    ld (hl),b
    ld hl,count
    inc (hl)
    jr .done
.off:
    pop hl
.done:
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
    ld a,(hl)
    call entry_at           ; the last
    pop de
    push de
    ld bc,4
    ldir
    pop hl
    pop de
    pop bc
    ret

; entry_at: HL = table entry A. DE kept.
entry_at:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    push de
    ld de,table
    add hl,de
    pop de
    ret

; tile_of: HL = the tile of page B (its count, then its pieces). BC, DE kept.
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

; set_offset: the operand of draw_list's ADD at gfx_offset = fine / 2 * 16,
; where the fine position's version of each graphic is.
set_offset:
    ld a,(fine)
    add a,a
    add a,a
    add a,a
    ld (gfx_offset + 1),a
    ret

PAGE_COLUMNS    equ 32
LINE_INDEX      equ 0       ; a tile: 129 bytes of index by line,
COLUMN_INDEX    equ 129     ; 33 by column,
PIECES          equ 162     ; then its pieces by line, then by column

saved_sp:       dw 0
fine:           db 0        ; the world's fine position: 0, 2, 4, 6
view_column:    db 0        ; the world column at screen column 0
view_y:         dw VIEW_Y_START ; the world line at screen line 0
count:          db 0        ; the entries in the table
line_address:   dw 0        ; the arriving line's screen address, at column 0

    INCLUDE "output/data.s"

table:          ds 4 * MAX_TABLE

    SAVESNA "output/listscroll.sna", start
