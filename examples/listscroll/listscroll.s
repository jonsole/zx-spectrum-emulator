; listscroll: a world of rock (the $55/$AA checker) and sky, wider than the
; screen and wrapping round, whose edges are a display list, walked every
; frame and moved 2 pixels a frame by the keys: O and P left and right, as
; far as you like, Q and A up and down (at most MAX_VMOVE lines).
;
; The world's pieces are in world_pieces, sorted by world column: column,
; bottom line, graphic. The table holds the run of them that is on the screen
; (window at screen column 0 to 30), in the same order: each entry the screen
; address of the bottom line of its 2-byte window and its graphic at fine
; position 0 (its versions for 2, 4 and 6 follow, 16 bytes apart in the same
; page). draw_list walks the table with SP and draws each entry 8 lines high.
;
; Moving 2 pixels across changes only the fine position's offset. When it
; wraps, every entry moves a byte, and at the ends of the table pieces come
; and go: moving the world right, the last pieces come off at screen column
; 31 and those arriving at column 0 are added in front; moving it left, the
; first come off at column -1 and those arriving at 30 are added behind.
; Columns 0 and 31 are black on black, so only 1 to 30 show. Moving 2 lines
; up or down moves every entry's address 2 lines. Nothing is cleared: sky and
; the checker look the same after a move.
;
; build.py makes output/data.s: the graphics (gfx), world_pieces
; (WORLD_PIECES of them; FIRST_ON and ON_COUNT those on the screen at the
; start), line_table and the screen as the world starts (screen_start).

    DEVICE ZXSPECTRUM48

IM2_TABLE   equ 0xFE00
IM2_JUMP    equ 0xFDFD
TABLE_SIZE  equ 256         ; entries the table's buffer holds
MIDDLE      equ 128         ; where the table starts in it

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

; fill_table: the table as the world starts: world_pieces from FIRST_ON,
; ON_COUNT of them, at the middle of the buffer.
fill_table:
    ld a,MIDDLE
    ld (front),a
    ld a,FIRST_ON
    ld (left_piece),a
    ld (right_piece),a
    xor a
    ld (count),a
    ld b,ON_COUNT
.add:
    push bc
    call add_behind
    pop bc
    djnz .add
    ret

; ---------------------------------------------------------------------------
; draw_list: the count entries from front, each a graphic 2 bytes wide and 8
; lines high, its bottom line's first byte at the entry's address (an odd
; line). Each pair of lines is the lower left to right, the upper right to
; left. The blit is unrolled: four pairs, the character-row fix-up out of
; line, jumped to only on the rarer crossing, and none after the last pair.

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
    ld a,(front)
    call entry_at
    di                      ; SP will be in the graphics (and the other
    ld (saved_sp),sp        ; registers are the walk's)
    push hl
    exx
    pop hl                  ; HL': the next entry; BC': an entry's size
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
down:
    ld a,(vmoved)
    cp MAX_VMOVE
    ret z
    add a,2
    ld (vmoved),a
    ld hl,line_down
    jr move_lines
up:
    ld a,(vmoved)
    cp -MAX_VMOVE
    ret z
    sub 2
    ld (vmoved),a
    ld hl,line_up
    ; fall into move_lines

; move_lines: every entry's screen address 2 lines on, by the routine at HL
; (line_down or line_up), done twice.
move_lines:
    ld (.step + 1),hl
    ld (.step2 + 1),hl
    ld a,(count)
    or a
    ret z
    ld b,a
    ld a,(front)
    call entry_at
.entry:
    ld e,(hl)
    inc hl
    ld d,(hl)
    push hl
    ex de,hl
.step:
    call 0
.step2:
    call 0
    ex de,hl
    pop hl
    ld (hl),d
    dec hl
    ld (hl),e
    ld de,4
    add hl,de
    djnz .entry
    ret

; line_down: HL a line down the screen.
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

; line_up: HL a line up the screen.
line_up:
    dec h
    ld a,h
    inc a
    and 7
    ret nz
    ld a,l
    sub 32
    ld l,a
    ret c
    ld a,h
    add a,8
    ld h,a
    ret

; right: the world 2 pixels right. From fine position 6 to 0 the screen's
; first column is a world column further left: every entry a byte right,
; the pieces now at column 31 off the back, those at column 0 on the front.
right:
    ld a,(fine)
    add a,2
    and 6
    ld (fine),a
    call set_offset
    ld a,(fine)
    or a
    ret nz
    ld a,(view_column)
    dec a
    cp -1
    jr nz,.column
    ld a,COLUMNS - 1
.column:
    ld (view_column),a
    ld c,1
    call move_entries
.off:
    ld a,(count)            ; off the back while at column 31
    or a
    jr z,.on
    ld a,(right_piece)
    call previous_piece
    call piece_column
    cp 31
    jr nz,.on
    ld a,(right_piece)
    call previous_piece
    ld (right_piece),a
    ld hl,count
    dec (hl)
    jr .off
.on:
    ld a,(count)            ; on the front while at column 0
    cp WORLD_PIECES
    ret z
    ld a,(left_piece)
    call previous_piece
    call piece_column
    or a
    ret nz
    call add_in_front
    jr .on

; left: the world 2 pixels left. From fine position 0 to 6 the screen's
; first column is a world column further right: every entry a byte left,
; the pieces now at column -1 off the front, those at column 30 on the back.
left:
    ld a,(fine)
    sub 2
    and 6
    ld (fine),a
    call set_offset
    ld a,(fine)
    cp 6
    ret nz
    ld a,(view_column)
    inc a
    cp COLUMNS
    jr nz,.column
    xor a
.column:
    ld (view_column),a
    ld c,-1
    call move_entries
.off:
    ld a,(count)            ; off the front while at column -1
    or a
    jr z,.on
    ld a,(left_piece)
    call piece_column
    cp COLUMNS - 1
    jr nz,.on
    ld a,(left_piece)
    call next_piece
    ld (left_piece),a
    ld hl,front
    inc (hl)
    ld hl,count
    dec (hl)
    jr .off
.on:
    ld a,(count)            ; on the back while at column 30
    cp WORLD_PIECES
    ret z
    ld a,(right_piece)
    call piece_column
    cp 30
    ret nz
    call add_behind
    jr .on

; move_entries: every entry's screen address C bytes across (1 or -1), in
; its column's 5 bits (a column stays in its character row).
move_entries:
    ld a,(count)
    or a
    ret z
    ld b,a
    ld a,(front)
    call entry_at
.entry:
    ld a,(hl)
    and 0xE0
    ld e,a
    ld a,(hl)
    add a,c
    and 0x1F
    or e
    ld (hl),a
    inc hl
    inc hl
    inc hl
    inc hl
    djnz .entry
    ret

; ---------------------------------------------------------------------------
; The table's ends.

; add_in_front: the piece before left_piece into the table in front.
add_in_front:
    ld a,(front)
    or a
    call z,recentre
    ld hl,front
    dec (hl)
    ld a,(left_piece)
    call previous_piece
    ld (left_piece),a
    ld b,a
    ld a,(front)
    jr add_entry

; add_behind: right_piece into the table behind.
add_behind:
    ld a,(front)
    ld b,a
    ld a,(count)
    add a,b
    call c,recentre         ; the buffer's end
    ld a,(right_piece)
    ld b,a
    call next_piece
    ld (right_piece),a
    ld a,(front)
    ld c,a
    ld a,(count)
    add a,c
    ; fall into add_entry

; add_entry: world piece B into table entry A, counted: its screen address
; (line_table at its bottom line + vmoved, at its column) and its graphic.
add_entry:
    call entry_at
    push hl
    ld a,b
    call world_piece        ; HL at the piece: column, bottom line, graphic
    ld a,(hl)
    call column_of
    ld c,a                  ; C: its screen column
    inc hl
    ld a,(vmoved)
    add a,(hl)              ; its bottom line now
    inc hl
    ld e,(hl)               ; DE: its graphic
    inc hl
    ld d,(hl)
    push de
    ld l,a
    ld h,0
    add hl,hl
    ld de,line_table
    add hl,de
    ld a,(hl)
    add a,c
    ld e,a
    inc hl
    ld d,(hl)               ; DE: its screen address
    pop bc
    pop hl
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (hl),c
    inc hl
    ld (hl),b
    ld hl,count
    inc (hl)
    ret

; recentre: the table moved back to the middle of its buffer.
recentre:
    ld a,(count)
    srl a
    ld b,a
    ld a,MIDDLE
    sub b
    ld c,a                  ; C: where it starts now
    ld a,(front)
    call entry_at
    push hl
    ld a,c
    ld (front),a
    call entry_at
    ex de,hl
    pop hl
    ld a,(count)
    or a
    ret z
    push hl                 ; BC = count * 4 bytes
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    ld b,h
    ld c,l
    pop hl
    ld a,d                  ; moving up the buffer: from the top down
    cp h
    jr nz,.which
    ld a,e
    cp l
.which:
    jr c,.down
    ret z
    add hl,bc
    dec hl
    ex de,hl
    add hl,bc
    dec hl
    ex de,hl
    lddr
    ret
.down:
    ldir
    ret

; entry_at: HL = table entry A.
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

; world_piece: HL = world piece A.
world_piece:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    push de
    ld de,world_pieces
    add hl,de
    pop de
    ret

; piece_column: A = world piece A's screen column (0 to COLUMNS - 1, round
; the world).
piece_column:
    call world_piece
    ld a,(hl)
    ; fall into column_of

; column_of: A = world column A's screen column, round the world.
column_of:
    push bc
    ld b,a
    ld a,(view_column)
    ld c,a
    ld a,b
    sub c
    jr nc,.done
    add a,COLUMNS
.done:
    pop bc
    ret

; next_piece, previous_piece: A = the world piece after or before A, round
; the world.
next_piece:
    inc a
    cp WORLD_PIECES
    ret nz
    xor a
    ret
previous_piece:
    or a
    jr nz,.back
    ld a,WORLD_PIECES
.back:
    dec a
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

saved_sp:       dw 0
fine:           db 0        ; the world's fine position: 0, 2, 4, 6
view_column:    db 0        ; the world column at screen column 0
vmoved:         db 0        ; how far the world has moved down, in lines (signed)
front:          db 0        ; the table's first entry in its buffer
count:          db 0        ; and how many it holds
left_piece:     db 0        ; the world piece in the table's first entry
right_piece:    db 0        ; the one after its last

    INCLUDE "output/data.s"

table:          ds 4 * TABLE_SIZE

    SAVESNA "output/listscroll.sna", start
