; Drawing the landscape: a back buffer that scrolls itself, copied to the
; screen with PUSH every frame.
;
; The buffer (BUF, 8K, uncontended) holds the view: 128 lines, each in a row
; of 64 bytes. Each of the view's 32 columns is held twice, at (column & 31)
; and 32 after that, so a screen line's 32 bytes run on unbroken from any
; starting column, cam_x & 31, however far the view has scrolled across. The
; rows are a ring, and ring_top is the one holding the view's top line. So
; moving the view a pixel down writes one new line into the row that has just
; scrolled off the top, and moving it a character across writes one new
; column; nothing else in the buffer is touched.
;
; blit_view, in output/blit.s (build.py writes it: it is the same few lines
; unrolled), copies the window to the screen sixteen bytes at a time: POP them
; off the buffer into all eight register pairs, point SP at the screen, PUSH
; them back. That is about 17 T-states a byte, all told, 69K for the view --
; most of a frame, so the copy has to be timed against the beam (wait_paper):
; it starts once the beam has drawn the top of this frame, and finishes before
; the beam gets to anything it has not yet written in the next.
;
; Across, the view moves a character at a time; down, a pixel at a time.
; Smooth across would mean shifting every byte of the view on every frame,
; which a 48K cannot afford on top of the copy.

BUF         equ 0xA000      ; the view's buffer: up to BUF_END
BUF_ROW     equ 64          ; bytes a row: 32 columns, twice
VIEW_LINES  equ VIEW_H * 8  ; 128
BUF_SIZE    equ BUF_ROW * VIEW_LINES
BUF_END     equ BUF + BUF_SIZE

MAX_LINES   equ 6           ; the most the view moves down or up in a pass: as
                            ; fast as he can fall, two frames at 3 pixels
COLUMN_LINES equ 4          ; or in a pass that also fills a column -- both
                            ; at once would not fit, and the view catches up

    ASSERT (VIEW_LINES & (VIEW_LINES - 1)) == 0, "the ring is wrapped with an AND"

; buffer_row -- HL = buffer row A (0..127), at column C (0..63). Uses A.
buffer_row:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld a,l
    or c
    ld l,a
    ld a,h
    add a,high BUF
    ld h,a
    ret

; build_view -- puts the view where it should be for him and fills the whole
; buffer, at the start. After that the view only ever scrolls.
build_view:
    call camera_target
    ld a,(cam_tx)
    ld (cam_x),a
    ld hl,(cam_ty)
    ld (cam_y),hl
    xor a
    ld (ring_top),a
    ld c,a
    ld b,VIEW_LINES
    ld de,(cam_y)
    call fill_lines

    ld hl,0x5800
    ld de,0x5801
    ld bc,VIEW_W * VIEW_H - 1
    ld (hl),LAND_ATTR
    ldir
    xor a
    ld (attr_rows),a        ; no colour of his to take off
    ret

; scroll_view -- moves the view toward (cam_tx, cam_ty), a character across
; and up to MAX_LINES lines up or down, filling in what comes into sight.
scroll_view:
    ld a,MAX_LINES
    ld (sv_lines),a
    ld a,(cam_tx)
    ld b,a
    ld a,(cam_x)
    cp b
    jr z,.down_or_up
    jr c,.right
    dec a
    ld (cam_x),a
    xor a                   ; the new column is on the left
    jr .column
.right:
    inc a
    ld (cam_x),a
    ld a,VIEW_W - 1         ; on the right
.column:
    call fill_column
    ld a,COLUMN_LINES
    ld (sv_lines),a

.down_or_up:
    ld hl,(cam_ty)
    ld de,(cam_y)
    or a
    sbc hl,de
    ret z
    jr c,.up
    ; Down: the rows scrolling off the top become the new bottom lines.
    call .lines             ; B = how many
    ld a,(ring_top)
    ld c,a                  ; into the top rows
    add a,b
    and VIEW_LINES - 1
    ld (ring_top),a
    ld hl,(cam_y)
    push hl
    ld e,b
    ld d,0
    add hl,de
    ld (cam_y),hl
    pop hl
    ld de,VIEW_LINES
    add hl,de
    ex de,hl                ; the planet rows below the old view
    jr fill_lines
.up:
    ; Up: the bottom rows become the new top lines.
    ex de,hl
    or a
    sbc hl,de               ; how far: cam_y - cam_ty
    call .lines
    ld a,(ring_top)
    sub b
    and VIEW_LINES - 1
    ld (ring_top),a
    ld c,a                  ; into the rows that end the ring
    ld hl,(cam_y)
    ld e,b
    ld d,0
    or a
    sbc hl,de
    ld (cam_y),hl
    ex de,hl                ; the planet rows above the old view
    jr fill_lines
; B = HL, at most sv_lines.
.lines:
    ld a,(sv_lines)
    ld b,a
    ld a,h
    or a
    ret nz
    ld a,l
    cp b
    ret nc
    ld b,a
    ret

; fill_lines -- writes B planet pixel rows from DE (0..2047) into buffer rows
; from C (0..127, round the ring), across the view's 32 columns from cam_x.
;
; A block row at a time: its blocks' addresses are looked up once into
; fl_blocks, and every line in it is then reads and writes. Uses everything.
fill_lines:
    ld (fl_y),de
    ld a,c
    ld (fl_row),a
    ld a,b
    ld (fl_count),a
.chunk:
    call block_row_lookup
    ld a,(fl_y)
    and 15
    neg
    add a,16
    ld b,a                  ; lines left in this block row
    ld a,(fl_count)
    cp b
    jr nc,.whole
    ld b,a
.whole:
    ld a,b
    ld (fl_chunk),a
.line:
    call fill_line
    ld hl,(fl_y)
    inc hl
    ld (fl_y),hl
    ld a,(fl_row)
    inc a
    and VIEW_LINES - 1
    ld (fl_row),a
    ld hl,fl_count
    dec (hl)
    ret z
    ld hl,fl_chunk
    dec (hl)
    jr nz,.line
    jr .chunk

; block_row_lookup -- fl_blocks: where each of the 17 blocks across the view's
; columns keeps its bytes, in block row fl_y >> 4 -- low byte then high, the
; low byte waiting for the row's offset. Uses everything but IX, IY.
block_row_lookup:
    ld de,(fl_y)
    ld a,e
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    ld c,a
    ld a,d
    rlca
    rlca
    rlca
    rlca
    or c
    ld c,a
    ld a,(cam_x)
    srl a
    ld b,a
    call map_addr
    ld de,fl_blocks
    ld b,17
.block:
    ld a,(hl)
    rrca
    rrca
    rrca
    ld c,a
    and 0xE0
    ld (de),a
    inc e
    ld a,c
    and 7
    add a,high block_gfx
    ld (de),a
    inc e
    inc l                   ; a 17th past the planet's edge is read, not drawn
    djnz .block
    ret

; fill_line -- writes planet pixel row fl_y into buffer row fl_row from
; fl_blocks. Uses everything but IX, IY.
fill_line:
    ; Which of a block's 32 bytes this row is: ((y >> 3) & 1) * 16 + (y & 7),
    ; into the ORs below; 8 more for a block's right half.
    ld a,(fl_y)
    ld e,a
    and 7
    ld b,a
    ld a,e
    and 8
    add a,a
    or b
    ld (.left + 1),a
    ld (.left_only + 1),a
    or 8
    ld (.right_only + 1),a

    ; HL = where in the row the view's first column goes.
    ld a,(cam_x)
    and 31
    ld c,a
    ld a,(fl_row)
    call buffer_row
    ld bc,fl_blocks
    ld a,(cam_x)
    and 1
    jr z,.pairs
    ; The view starts half way through a block: its right half alone.
    ld a,(bc)
    inc c
.right_only:
    or 0                    ; patched
    ld e,a
    ld a,(bc)
    inc c
    ld d,a
    ld a,(de)
    ld (hl),a
    set 5,l
    ld (hl),a
    res 5,l
    inc l
    res 5,l
.pairs:
.pair:
    ld a,(bc)
    inc c
.left:
    or 0                    ; patched
    ld e,a
    ld a,(bc)
    inc c
    ld d,a
    ld a,(de)
    ld (hl),a
    set 5,l
    ld (hl),a               ; and its twin, 32 along
    res 5,l
    inc l
    res 5,l                 ; past column 31 back to 0, not into the twins
    set 3,e
    ld a,(de)
    ld (hl),a
    set 5,l
    ld (hl),a
    res 5,l
    inc l
    res 5,l
    ld a,c
    cp low fl_blocks + 32   ; sixteen blocks, or a half, fifteen, and a half
    jr nz,.pair
    ld a,(cam_x)
    and 1
    ret z
    ; ...and ends half way through one: its left half alone.
    ld a,(bc)
    inc c
.left_only:
    or 0                    ; patched
    ld e,a
    ld a,(bc)
    ld d,a
    ld a,(de)
    ld (hl),a
    set 5,l
    ld (hl),a
    ret

; fill_column -- writes view column A (0..31), planet column cam_x + A, down
; all the view's lines in the buffer.
;
; A block at a time, through a copy of a block's sixteen lines unrolled and
; entered at the line the view's top cuts the block at -- a line is then four
; instructions and a twin. Where the block would run past the bottom of the
; view, or round the ring, a line at a time instead.
fill_column:
    ld b,a
    ld a,(cam_x)
    add a,b
    ld c,a                  ; C = planet column
    and 1
    add a,a
    add a,a
    add a,a
    ld (fc_half),a          ; 8 for a block's right half

    ; Where the view's top line is in the buffer, at this column.
    ld a,c
    and 31
    push bc
    ld c,a
    ld a,(ring_top)
    call buffer_row
    pop bc
    ld (fc_dest),hl
    ld a,(ring_top)
    neg
    add a,VIEW_LINES
    ld (fc_to_wrap),a       ; lines before the ring goes back to its start
    ld a,VIEW_LINES
    ld (fc_left),a

    ; IX = the map byte of the block at the view's top, in this column.
    ld de,(cam_y)
    ld a,e
    and 15
    ld (fc_line),a          ; the line within the block
    ld a,e
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    ld b,a
    ld a,d
    rlca
    rlca
    rlca
    rlca
    or b
    ld b,c
    ld c,a
    srl b
    call map_addr
    push hl
    pop ix

.run:
    ; DE = the run's first byte: block_gfx + number * 32, + 16 in the
    ; bottom half, + the line within the half, + 8 on the right.
    ld a,(ix + 0)
    rrca
    rrca
    rrca
    ld e,a
    and 7
    add a,high block_gfx
    ld d,a
    ld a,e
    and 0xE0
    ld e,a
    ld a,(fc_line)
    ld b,a
    and 8
    add a,a
    or e
    ld e,a
    ld a,b
    and 7
    or e
    ld e,a
    ld a,(fc_half)
    or e
    ld e,a

    ; The run: to the block's bottom, if neither the view nor the ring ends
    ; first.
    ld a,16
    sub b
    ld c,a
    ld a,(fc_left)
    cp c
    jp c,.slow
    ld a,(fc_to_wrap)
    cp c
    jp c,.slow
    ld a,c
    ld (fc_run),a
    ld a,b
    add a,a
    ld l,a
    ld h,0
    ld bc,fc_entries
    add hl,bc
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    push hl
    pop iy
    ld hl,(fc_dest)
    ld bc,BUF_ROW
    jp (iy)
.lines:
    REPT 8
    ld a,(de)
    inc e
    ld (hl),a
    set 5,l
    ld (hl),a               ; and its twin
    res 5,l
    add hl,bc
    ENDR
    ld a,e                  ; from the top half's last line to the bottom's first
    add a,8
    ld e,a
.lines_bottom:
    REPT 8
    ld a,(de)
    inc e
    ld (hl),a
    set 5,l
    ld (hl),a
    res 5,l
    add hl,bc
    ENDR
    jr .ran

.slow:
    ; The run is cut short: by what is left of the view or of the ring.
    ld a,(fc_left)
    cp c
    jr nc,.not_left
    ld c,a
.not_left:
    ld a,(fc_to_wrap)
    cp c
    jr nc,.not_wrap
    ld c,a
.not_wrap:
    ld a,c
    ld (fc_run),a
    ld a,b                  ; the line within the block
    ld b,c
    ld c,a
    ld hl,(fc_dest)
.slow_line:
    ld a,(de)
    inc e
    ld (hl),a
    set 5,l
    ld (hl),a
    res 5,l
    push bc
    ld bc,BUF_ROW
    add hl,bc
    pop bc
    inc c
    ld a,c
    cp 8
    jr nz,.same_half
    ld a,e
    add a,8
    ld e,a
.same_half:
    djnz .slow_line

.ran:
    ld (fc_dest),hl
    ld a,(fc_run)
    ld c,a
    ld a,(fc_left)
    sub c
    ret z
    ld (fc_left),a
    ld a,(fc_to_wrap)
    sub c
    ld (fc_to_wrap),a
    jr nz,.ring_ok
    ld de,-BUF_SIZE         ; round the ring to its first row
    add hl,de
    ld (fc_dest),hl
    ld a,0xFF               ; and it does not come round again
    ld (fc_to_wrap),a
.ring_ok:
    ld a,(fc_line)
    add a,c
    and 15
    ld (fc_line),a
    jp nz,.run
    ld de,MAP_W             ; down into the next block
    add ix,de
    jp .run

; Where a run starting at each line of a block enters the unrolled copy: 9
; bytes a line, and the 4 that move to the block's bottom half after line 7.
fc_entries:
    dw fill_column.lines + 0, fill_column.lines + 9, fill_column.lines + 18
    dw fill_column.lines + 27, fill_column.lines + 36, fill_column.lines + 45
    dw fill_column.lines + 54, fill_column.lines + 63
    dw fill_column.lines_bottom + 0, fill_column.lines_bottom + 9
    dw fill_column.lines_bottom + 18, fill_column.lines_bottom + 27
    dw fill_column.lines_bottom + 36, fill_column.lines_bottom + 45
    dw fill_column.lines_bottom + 54, fill_column.lines_bottom + 63

; ---- the astronaut, in the buffer --------------------------------------------

; sprite_to_buffer -- draws him into the buffer where he is in the view,
; keeping what was under him for sprite_from_buffer. Into the buffer rather
; than onto the screen, so the copy carries him and he never flickers.
sprite_to_buffer:
    call screen_pos
    sbc a,a
    ld (spr_hidden),a       ; off the view: nothing to draw, or to put back
    ret nz
    ld a,b
    ld (spr_sx),a
    ld a,c
    ld (spr_sy),a

    ; Image facing * 2 + thrusting, at shift x & 7: sprite_table's entry.
    ld a,(thrusting)
    or a
    jr z,.unlit
    ld a,1
.unlit:
    ld e,a
    ld a,(facing)
    add a,a
    or e
    add a,a
    add a,a
    add a,a
    ld e,a
    ld a,b
    and 7
    or e
    add a,a
    ld l,a
    ld h,0
    ld de,sprite_table
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    push de

    ; His top line's row, (ring_top + y) mod VIEW_LINES; his column,
    ; (cam_x & 31) + x / 8.
    ld a,(ring_top)
    add a,c
    jr c,.wrap              ; past 255: certainly past the ring
    cp VIEW_LINES
    jr c,.row
.wrap:
    sub VIEW_LINES
.row:
    ld e,a
    ld a,b
    rrca
    rrca
    rrca
    and 0x1F
    ld b,a
    ld a,(cam_x)
    and 31
    add a,b
    ld c,a
    ld a,e
    call buffer_row
    ld (spr_addr),hl
    pop de

    ld ix,spr_save
    ld b,16
.line:
    REPT 3
    ld a,(hl)
    ld (ix + 0),a
    inc ix
    ld a,(de)
    and (hl)
    inc de
    ex de,hl
    or (hl)
    ex de,hl
    inc de
    ld (hl),a
    inc l
    ENDR
    call next_sprite_row
    djnz .line
    ret

; sprite_from_buffer -- puts back what was under him.
sprite_from_buffer:
    ld a,(spr_hidden)
    or a
    ret nz
    ld hl,(spr_addr)
    ld ix,spr_save
    ld b,16
.line:
    REPT 3
    ld a,(ix + 0)
    ld (hl),a
    inc ix
    inc l
    ENDR
    call next_sprite_row
    djnz .line
    ret

; next_sprite_row -- HL, three bytes into a sprite's row in the buffer, to the
; start of the row below, round the ring. Uses A.
next_sprite_row:
    ld a,l
    add a,BUF_ROW - 3
    ld l,a
    jr nc,.same_page
    inc h
.same_page:
    ld a,h
    cp high BUF_END
    ret c
    ld h,high BUF
    ret

; player_attrs -- his colour on the cells his ink is in (x + 2 .. x + 12,
; y + 1 .. y + 14), and the landscape's back where it was last frame.
player_attrs:
    ld a,(attr_rows)
    or a
    jr z,.new
    ld d,a
    ld hl,(attr_at)
.clear_row:
    push hl
    ld a,(attr_cols)
    ld b,a
.clear:
    ld (hl),LAND_ATTR
    inc l
    djnz .clear
    pop hl
    ld bc,32
    add hl,bc
    dec d
    jr nz,.clear_row

.new:
    xor a
    ld (attr_rows),a
    ld a,(spr_hidden)
    or a
    ret nz
    ld a,(spr_sy)
    inc a
    rrca
    rrca
    rrca
    and 0x1F
    ld e,a                  ; first row
    ld a,(spr_sy)
    add a,14
    rrca
    rrca
    rrca
    and 0x1F
    sub e
    inc a
    ld (attr_rows),a
    ld d,a
    ld a,(spr_sx)
    add a,2
    rrca
    rrca
    rrca
    and 0x1F
    ld c,a                  ; first column
    ld a,(spr_sx)
    add a,12
    rrca
    rrca
    rrca
    and 0x1F
    sub c
    inc a
    ld (attr_cols),a
    ; 0x5800 + row * 32 + column
    ld l,e
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld b,0
    add hl,bc
    ld bc,0x5800
    add hl,bc
    ld (attr_at),hl
.set_row:
    push hl
    ld a,(attr_cols)
    ld b,a
.set:
    ld (hl),PLAYER_ATTR
    inc l
    djnz .set
    pop hl
    ld bc,32
    add hl,bc
    dec d
    jr nz,.set_row
    ret

; wait_paper -- returns once the beam is drawing the screen proper, not the
; top border: the earliest the copy may start without changing lines this
; frame has still to show. The floating bus says where the beam is -- port
; 0xFF reads 0xFF while the ULA is in the border and what it is fetching
; while it draws the paper. A Spectrum without one (the +2A and +3) times
; out instead, after about as long as the top border.
wait_paper:
    ld bc,PAPER_TIMEOUT
.poll:
    in a,(0xFF)
    cp 0xFF
    ret nz
    dec bc
    ld a,b
    or c
    jr nz,.poll
    ret

PAPER_TIMEOUT equ 300       ; polls of about 45 T-states: 13,500, the top border

; ---- screen addressing -------------------------------------------------------

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

; ---- variables ---------------------------------------------------------------

ring_top:       db 0        ; the buffer row holding the view's top line
spr_sx:         db 0        ; where he is drawn this frame, in the view
spr_sy:         db 0
spr_addr:       dw 0        ; his top-left byte in the buffer
spr_hidden:     db 0        ; 0xFF while he is outside the view
spr_save:       ds 16 * 3   ; what is under him there
sv_lines:       db 0        ; scroll_view: the most lines this pass
fl_y:           dw 0        ; fill_lines's working
fl_row:         db 0
fl_count:       db 0
fl_chunk:       db 0
    ALIGN 64
fl_blocks:      ds 17 * 2   ; block_row_lookup's: in one page
fc_half:        db 0        ; fill_column's working
fc_dest:        dw 0
fc_to_wrap:     db 0
fc_left:        db 0
fc_line:        db 0
fc_run:         db 0
attr_at:        dw 0        ; the cells his colour is on
attr_rows:      db 0
attr_cols:      db 0
