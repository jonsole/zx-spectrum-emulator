; Drawing the landscape: back buffers that scroll themselves, copied to the
; screen with PUSH every frame.
;
; There are two buffers, each holding the whole view, the second shifted four
; pixels left of the first: BUF0's bytes are the planet's character columns
; as they are, BUF4's are each column's right half and the next one's left.
; The view's left edge moves four pixels at a time, cam_h; on a whole
; character it shows BUF0, half way through one it shows BUF4. Steps of two
; pixels would take four buffers, which a 48K holding a 16K map cannot fit.
;
; A buffer is 128 rows -- the view's lines -- of 48 bytes, kept as a ring both
; ways. Across: each row holds 32 of the planet's columns, a column at
; (column & 31), and the first 16 again after them, so the copy's two
; sixteen-byte halves of a line each run on unbroken from wherever the view
; starts. Down: ring_top is the row holding the view's top line. So moving
; the view a pixel down writes one new line into the row that has just
; scrolled off the top of each buffer, and moving it four pixels across
; writes one new column into the buffer that is not being shown; nothing
; else is touched.
;
; blit_view, in output/blit.s (build.py writes it: the same few lines
; unrolled), copies the shown buffer's window to the screen sixteen bytes at a
; time: POP them into all eight register pairs, point SP at the screen, PUSH
; them back. About 69K T-states for the view -- most of a frame -- so it
; races the beam (wait_paper): it starts once the beam has drawn the top of
; this frame, and finishes before the beam gets to anything it has not yet
; written in the next.

BUF_ROW     equ 48          ; bytes a row: 32 columns, then the first 16 again
VIEW_LINES  equ VIEW_H * 8  ; 128
BUF_SIZE    equ BUF_ROW * VIEW_LINES
BUF0        equ 0x9E00      ; the view on whole characters
BUF4        equ BUF0 + BUF_SIZE ; and four pixels on
BUF_END     equ BUF4 + BUF_SIZE

    ASSERT low BUF0 == 0 && low BUF_SIZE == 0, "a buffer's end is tested by its page"
    ASSERT (VIEW_LINES & (VIEW_LINES - 1)) == 0, "the ring is wrapped with an AND"

MAX_LINES   equ 6           ; the most the view moves down or up in a pass: as
                            ; fast as he can fall, two frames at 3 pixels
COLUMN_LINES equ 3          ; or in a pass that also fills a column -- both at
                            ; once would not fit, and the view catches up
FAR_BEHIND  equ 10          ; four-pixel steps behind him, or
FAR_BELOW   equ 24          ; lines, before the view is far behind: then each
                            ; pass catches up one way only, as fast as a pass
                            ; allows -- two steps, or MAX_LINES lines

; buffer_row -- HL = buffer page B's row A (0..127), at column C (0..47).
; Uses A; preserves BC, DE.
buffer_row:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl               ; row * 16
    push de
    ld e,l
    ld d,h
    add hl,hl
    add hl,de               ; row * 48
    pop de
    ld a,l
    add a,c
    ld l,a
    ld a,h
    adc a,b
    ld h,a
    ret

; set_windows -- where each buffer's 32 columns start, from cam_h: BUF4's at
; cam_h >> 1, BUF0's at (cam_h + 1) >> 1. The two are the same on a whole
; character; half way through one, BUF0's -- not shown -- has gone on a
; column, ready for the next step.
set_windows:
    ld hl,(cam_h)
    srl h
    rr l
    ld a,l
    ld (cam_s4),a
    ld hl,(cam_h)
    inc hl
    srl h
    rr l
    ld a,l
    ld (cam_s0),a
    ret

; shown_buffer -- B = the page of the buffer the view shows, C = the page it
; ends at. Uses A.
shown_buffer:
    ld a,(cam_h)
    and 1
    ld b,high BUF0
    ld c,high BUF4
    ret z
    ld b,high BUF4
    ld c,high BUF_END
    ret

; build_view -- puts the view where it should be for him and fills both
; buffers, at the start. After that the view only ever scrolls.
build_view:
    call camera_target
    ld hl,(cam_th)
    ld (cam_h),hl
    call set_windows
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

; scroll_view -- moves the view toward (cam_th, cam_ty): four pixels across,
; or eight when it is far behind him, and up to MAX_LINES lines up or down,
; filling in what comes into sight.
scroll_view:
    ; How far behind him the view is, each way, in pixels.
    ld hl,(cam_th)
    ld de,(cam_h)
    call .distance
    add hl,hl
    add hl,hl
    ld (sv_across),hl
    ld hl,(cam_ty)
    ld de,(cam_y)
    call .distance
    ld (sv_down),hl
    ; Far behind: this pass catches up the way it is further behind, and only
    ; that way -- two columns, or MAX_LINES lines, each fit a pass alone.
    ld de,FAR_BELOW
    or a
    sbc hl,de
    jr nc,.far
    ld hl,(sv_across)
    ld de,FAR_BEHIND * 4
    or a
    sbc hl,de
    jr c,.near
.far:
    ld hl,(sv_down)
    ld de,(sv_across)
    or a
    sbc hl,de
    jr nc,.far_down
    xor a
    ld (sv_lines),a
    call step_across
    jp step_across
.far_down:
    ld a,MAX_LINES
    ld (sv_lines),a
    jr .down_or_up
.near:
    ; A step across if he has moved on one, and fewer lines with it.
    ld a,MAX_LINES
    ld (sv_lines),a
    call step_across
    jr z,.down_or_up
    ld a,COLUMN_LINES
    ld (sv_lines),a

.down_or_up:
    ld a,(sv_lines)
    or a
    ret z
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
    jp fill_lines
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
    jp fill_lines
; HL = |HL - DE|.
.distance:
    or a
    sbc hl,de
    ret nc
    ex de,hl
    ld hl,0
    or a
    sbc hl,de
    ret
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

; step_across -- four pixels toward cam_th, filling the one column that
; brings into the buffer that is not being shown. NZ if it stepped.
;
; Right onto half way through a character, BUF0's window moves on a column --
; BUF4 is shown -- and right onto a whole one, BUF4's does. Left, the same
; the other way round.
step_across:
    ld hl,(cam_th)
    ld de,(cam_h)
    or a
    sbc hl,de
    ret z
    ex de,hl
    jr c,.left
    inc hl
    ld (cam_h),hl
    call set_windows
    ld a,(cam_h)
    and 1
    jr z,.right_buf4
    ld a,(cam_s0)
    add a,VIEW_W - 1
    call fill_column0
    or 1
    ret
.right_buf4:
    ld a,(cam_s4)
    add a,VIEW_W - 1
    call fill_column4
    or 1
    ret
.left:
    dec hl
    ld (cam_h),hl
    call set_windows
    ld a,(cam_h)
    and 1
    jr z,.left_buf0
    ld a,(cam_s4)
    call fill_column4
    or 1
    ret
.left_buf0:
    ld a,(cam_s0)
    call fill_column0
    or 1
    ret

; ---- lines --------------------------------------------------------------------

; fill_lines -- writes B planet pixel rows from DE (0..2047) into buffer rows
; from C (0..127, round the ring), in both buffers.
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

; block_row_lookup -- fl_blocks: where each of the 17 blocks from BUF4's
; first column keeps its bytes, in block row fl_y >> 4 -- low byte then high,
; the low byte waiting for the row's offset. Uses everything but IX, IY.
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
    ld a,(cam_s4)
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
    inc l                   ; a block past the planet's edge is read, not drawn
    djnz .block
    ret

; fill_line -- planet pixel row fl_y into buffer row fl_row, in both
; buffers, from fl_blocks. Uses everything but IX, IY.
;
; The row's 33 bytes from BUF4's first column go into fl_line_bytes; BUF0
; takes 32 of them as they are. Then one RLD a byte, right to left, moves
; every byte's low half up and the next byte's high half in -- four pixels
; left -- and BUF4 takes those.
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

    ld hl,fl_line_bytes
    ld bc,fl_blocks
    ld a,low fl_blocks + 32
    ld (.end + 1),a
    ld a,(cam_s4)
    and 1
    jr z,.pair
    ; Starting half way through a block: its right half alone.
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
    inc l
    ld a,low fl_blocks + 34
    ld (.end + 1),a
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
    inc l
    set 3,e
    ld a,(de)
    ld (hl),a
    inc l
    ld a,c
.end:
    cp 0                    ; patched: sixteen blocks on
    jr nz,.pair
    ld a,(cam_s4)
    and 1
    jr nz,.gathered
    ; ...and the 33rd byte, the left half of the next.
    ld a,(bc)
    inc c
.left_only:
    or 0                    ; patched
    ld e,a
    ld a,(bc)
    ld d,a
    ld a,(de)
    ld (hl),a
.gathered:
    ; BUF0: from its own first column, which is BUF4's or the one after.
    ld a,(cam_s4)
    ld b,a
    ld a,(cam_s0)
    sub b
    add a,low fl_line_bytes
    ld l,a
    ld h,high fl_line_bytes
    ld a,(cam_s0)
    and 31
    ld c,a
    ld b,high BUF0
    ld a,(fl_row)
    call store_row

    ; BUF4: four pixels on.
    ld hl,fl_line_bytes + 32
    REPT 33
    rld
    dec l
    ENDR
    ld hl,fl_line_bytes
    ld a,(cam_s4)
    and 31
    ld c,a
    ld b,high BUF4
    ld a,(fl_row)
    ; fall through

; store_row -- the 32 bytes at HL into buffer page B's row A, the first at
; column C (0..31) and round the row from there, and the first 16 columns
; again after the 32. Uses everything but IX, IY.
store_row:
    push hl
    call buffer_row         ; HL = where column C goes
    ld a,l
    sub c
    ld (sr_row),a
    ld a,h
    sbc a,0
    ld (sr_row + 1),a       ; the row's start
    ex de,hl
    pop hl
    ld a,VIEW_W
    sub c
    ld b,0
    push bc
    ld c,a
    ldir                    ; columns C..31
    pop bc
    ld a,c
    or a
    jr z,.twins
    ld de,(sr_row)
    ldir                    ; columns 0..C-1
.twins:
    ld hl,(sr_row)
    ld de,VIEW_W
    ex de,hl
    add hl,de
    ex de,hl                ; DE = column 32
    ld bc,16
    ldir
    ret

; ---- columns ------------------------------------------------------------------

; fill_column0 -- BUF0's column for planet column A, down every line.
; fill_column4 -- BUF4's: the column's right half and the next one's left,
; ORed out of block_hi (the blocks moved four pixels left) and block_lo
; (four pixels right).
;
; Through the unrolled copies in output/columns.s, a line four or five
; instructions, running on from block to block: the column's blocks are
; looked up once into fc_blocks, and the whole column is at most four runs --
; two either side of where the ring wraps, each a run to a block's end and
; a run part way down the last block.
fill_column0:
    ld c,a
    ld b,high BUF0
    call column_setup
    ld a,(fc_twin)          ; 0 or 1: col0_once or col0_twice
    ld (fc_variant),a
    ld b,high block_gfx
    call column_blocks
    jr fill_column

fill_column4:
    ld c,a
    ld b,high BUF4
    call column_setup
    ld a,(fc_twin)
    add a,2                 ; col4_once or col4_twice
    ld (fc_variant),a
    ld b,high block_hi
    call column_blocks
    ; fall through

fill_column:
    ; Down to where the ring wraps, then on from its first row.
    ld a,(fc_to_wrap)
    ld b,a
    xor a
    call fc_segment
    ld a,(fc_to_wrap)
    cp VIEW_LINES
    ret z
    ld hl,(fc_dest0)
    ld (fc_dest),hl
    ld b,a
    ld a,VIEW_LINES
    sub b
    ld c,b
    ld b,a                  ; the lines after the wrap
    ld a,c                  ; from the view's line fc_to_wrap
    jp fc_segment

; column_setup -- for a column fill of buffer page B, planet column C:
; fc_dest where it starts, at the view's top line, and fc_dest0 at the
; ring's first row; fc_twin; fc_to_wrap; and fc_map, the map byte of the
; block at the view's top. Uses everything but IX, IY.
column_setup:
    ld a,c
    ld (fc_column),a
    and 1
    add a,a
    add a,a
    add a,a
    ld (fc_half),a          ; 8 for a block's right half
    ld a,c
    and 31
    ld c,a
    cp 16
    ld a,1                  ; columns 0..15 are held twice
    jr c,.twin
    xor a
.twin:
    ld (fc_twin),a
    xor a
    call buffer_row
    ld (fc_dest0),hl
    ld a,(ring_top)
    call buffer_row
    ld (fc_dest),hl
    ld a,(ring_top)
    neg
    add a,VIEW_LINES
    ld (fc_to_wrap),a       ; lines before the ring goes back to its start
    ld de,(cam_y)
    ld a,e
    and 15
    ld (fc_top_line),a
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
    ld c,a
    ld a,(fc_column)
    srl a
    ld b,a
    call map_addr
    ld (fc_map),hl
    ret

; column_blocks -- fc_blocks: for each block down the column from fc_map,
; where its bytes for this column are at its first line, in the table at
; page B (block_gfx or block_hi), then BUF4's other bytes -- the same
; block's right half or the next block's left, in block_lo. Uses everything
; but IX, IY.
column_blocks:
    ld a,b
    ld (.page + 1),a
    ld hl,(fc_map)
    ld de,fc_blocks
    ld b,COLUMN_BLOCKS
.block:
    push bc
    ld a,(hl)
    rrca
    rrca
    rrca
    ld c,a
    and 0xE0
    ld b,a
    ld a,(fc_half)
    or b
    ld (de),a               ; this column's bytes...
    inc e
    ld a,c
    and 7
    ld c,a
.page:
    add a,0                 ; patched: the table's page
    ld (de),a
    inc e
    ; ...and the next column's, in block_lo.
    ld a,(fc_half)
    or a
    jr nz,.next
    ld a,b
    or 8
    ld (de),a
    inc e
    ld a,c
    jr .lo_page
.next:
    inc l
    ld a,(hl)
    dec l
    rrca
    rrca
    rrca
    ld c,a
    and 0xE0
    ld (de),a
    inc e
    ld a,c
    and 7
.lo_page:
    add a,high block_lo
    ld (de),a
    inc e
    ld bc,MAP_W
    add hl,bc
    pop bc
    djnz .block
    ret

; fc_segment -- B lines (1..128) of the column, from the view's line A, into
; the buffer from fc_dest on: a run to the end of a block -- of as many
; blocks as it covers -- and a run part way down the last. Uses everything.
fc_segment:
    ld c,a
    ld a,(fc_top_line)
    add a,c                 ; lines down from the top block's first
    ld c,a
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    ld (fc_block),a
    ld a,c
    and 15
    ld (fc_line),a
    ld c,a
    ld a,16
    sub c                   ; what is left of the first block
    cp b
    jr z,.to_end
    jr c,.to_end
    ; All in the one block: stop part way.
    ld a,c
    add a,b
    ld (fc_stop_line),a
    ld a,1
    ld (fc_count),a
    jp fc_run
.to_end:
    ld c,a
    ld a,b
    sub c                   ; lines after the first block
    ld b,a
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    inc a
    ld (fc_count),a         ; blocks to the end of a block
    ld a,b
    and 15
    push af
    xor a
    ld (fc_stop_line),a
    call fc_run
    pop af
    ret z                   ; ended on a block's end
    ; The rest, part way down the next block.
    ld (fc_stop_line),a
    ld a,(fc_count)
    ld b,a
    ld a,(fc_block)
    add a,b
    ld (fc_block),a
    xor a
    ld (fc_line),a
    inc a
    ld (fc_count),a
    ; fall through

; fc_run -- the unrolled copy from line fc_line of fc_block, for fc_count
; blocks' ends, or to a RET at fc_stop_line if that is not 0. Uses
; everything.
fc_run:
    ; DE = the block's bytes at the line; IY = its other bytes; HL' = the
    ; next block's pointers; B' = the count.
    ld a,(fc_block)
    add a,a
    add a,a
    ld l,a
    ld h,0
    ld de,fc_blocks
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl
    push hl
    push bc
    pop iy
    ld a,(fc_line)
    ld c,a
    and 8
    add a,a
    ld b,a
    ld a,c
    and 7
    or b
    or e
    ld e,a
    ld a,(fc_count)
    exx
    pop hl
    ld b,a
    exx

    ; Where it enters: col_entries[variant * 16 + line].
    ld a,(fc_variant)
    add a,a
    add a,a
    add a,a
    add a,a
    ld b,a                  ; variant * 16
    add a,c
    add a,a
    ld l,a
    ld h,0
    push de
    ld de,col_entries
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (.run + 1),de
    ; Where it stops, if part way: a RET at col_stops[variant * 16 + line].
    ld hl,0
    ld (fc_stop),hl
    ld a,(fc_stop_line)
    or a
    jr z,.registers
    add a,b
    add a,a
    ld l,a
    ld h,0
    ld de,col_stops
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (fc_stop),de
    ld a,(de)
    ld (fc_saved),a
    ld a,0xC9               ; RET
    ld (de),a
.registers:
    pop de
    ld hl,(fc_dest)
    push hl
    pop ix
    ld bc,BUF_ROW
.run:
    call 0                  ; patched
    ld a,(fc_variant)
    and 1
    jr z,.once
    push ix                 ; a twice-held column's copy moved IX, not HL
    pop hl
.once:
    ld (fc_dest),hl
    ld hl,(fc_stop)
    ld a,h
    or l
    ret z
    ld a,(fc_saved)
    ld (hl),a
    ret

COLUMN_BLOCKS equ VIEW_LINES / 16 + 1 ; the most blocks a column of the view crosses

    INCLUDE "output/columns.s"

; ---- the astronaut, in the buffer ---------------------------------------------

; sprite_to_buffer -- draws him into the shown buffer where he is in the
; view, keeping what was under him for sprite_from_buffer. Into the buffer
; rather than onto the screen, so the copy carries him and he never flickers.
sprite_to_buffer:
    call screen_pos
    sbc a,a
    ld (spr_hidden),a       ; off the view: nothing to draw, or to put back
    ret nz
    ld a,b
    ld (spr_sx),a
    ld a,c
    ld (spr_sy),a

    ; Where his three bytes are in a row: view column k is at the window's
    ; start + k in the view's first half, and at the second half's start +
    ; k - 16 after -- wherever the copy reads it.
    ld a,b
    rrca
    rrca
    rrca
    and 0x1F
    ld e,a                  ; his first view column
    ld d,0
.column:
    ld a,(cam_s4)
    and 31
    ld b,a
    ld a,e
    cp 16
    jr c,.first_half
    ld a,b
    add a,16
    and 31
    ld b,a
    ld a,e
    sub 16
.first_half:
    add a,b
    ld hl,spr_offsets
    ld b,0
    ld c,d
    add hl,bc
    ld (hl),a
    inc e
    inc d
    ld a,d
    cp 3
    jr nz,.column
    ld a,(spr_offsets)
    ld (.d0a + 2),a
    ld (.d0b + 2),a
    ld (sprite_from_buffer.d0 + 2),a
    ld a,(spr_offsets + 1)
    ld (.d1a + 2),a
    ld (.d1b + 2),a
    ld (sprite_from_buffer.d1 + 2),a
    ld a,(spr_offsets + 2)
    ld (.d2a + 2),a
    ld (.d2b + 2),a
    ld (sprite_from_buffer.d2 + 2),a

    ; IX = his top line's row, (ring_top + y) mod 128, in the shown buffer.
    call shown_buffer
    ld a,c
    ld (spr_end),a
    ld a,(ring_top)
    ld c,a
    ld a,(spr_sy)
    add a,c
    and VIEW_LINES - 1
    ld c,0
    call buffer_row
    ld (spr_row),hl
    push hl
    pop ix

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
    ld a,(spr_sx)
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

    ld hl,spr_save
    ld b,16
.line:
.d0a:
    ld a,(ix + 0)           ; patched: his first byte's column
    ld (hl),a
    inc hl
    ld c,a
    ld a,(de)
    and c
    inc de
    ld c,a
    ld a,(de)
    or c
    inc de
.d0b:
    ld (ix + 0),a
.d1a:
    ld a,(ix + 0)
    ld (hl),a
    inc hl
    ld c,a
    ld a,(de)
    and c
    inc de
    ld c,a
    ld a,(de)
    or c
    inc de
.d1b:
    ld (ix + 0),a
.d2a:
    ld a,(ix + 0)
    ld (hl),a
    inc hl
    ld c,a
    ld a,(de)
    and c
    inc de
    ld c,a
    ld a,(de)
    or c
    inc de
.d2b:
    ld (ix + 0),a
    call next_sprite_row
    djnz .line
    ret

; sprite_from_buffer -- puts back what was under him.
sprite_from_buffer:
    ld a,(spr_hidden)
    or a
    ret nz
    ld ix,(spr_row)
    ld hl,spr_save
    ld b,16
.line:
    ld a,(hl)
    inc hl
.d0:
    ld (ix + 0),a           ; patched by sprite_to_buffer
    ld a,(hl)
    inc hl
.d1:
    ld (ix + 0),a
    ld a,(hl)
    inc hl
.d2:
    ld (ix + 0),a
    call next_sprite_row
    djnz .line
    ret

; next_sprite_row -- IX on a row, round the ring of the buffer that ends at
; page spr_end. Uses A.
next_sprite_row:
    push de
    ld de,BUF_ROW
    add ix,de
    ld a,(spr_end)
    ld e,a
    ld a,ixh
    cp e
    jr c,.in_ring
    ld de,-BUF_SIZE
    add ix,de
.in_ring:
    pop de
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
spr_row:        dw 0        ; his top line's row in the buffer
spr_end:        db 0        ; the page that buffer ends at
spr_offsets:    ds 3        ; his three bytes' columns in a row
spr_hidden:     db 0        ; 0xFF while he is outside the view
spr_save:       ds 16 * 3   ; what is under him
sv_lines:       db 0        ; scroll_view: the most lines this pass
sv_across:      dw 0        ; how far behind him the view is, in pixels
sv_down:        dw 0
sr_row:         dw 0        ; store_row's
fl_y:           dw 0        ; fill_lines's working
fl_row:         db 0
fl_count:       db 0
fl_chunk:       db 0
    ALIGN 64
fl_blocks:      ds 17 * 2   ; block_row_lookup's: in one page
    ALIGN 64
fl_line_bytes:  ds 33       ; fill_line's: in one page
fc_column:      db 0        ; the column fills' working
fc_half:        db 0
fc_twin:        db 0
fc_variant:     db 0
fc_map:         dw 0
fc_dest:        dw 0
fc_dest0:       dw 0
fc_to_wrap:     db 0
fc_top_line:    db 0
fc_block:       db 0
fc_line:        db 0
fc_count:       db 0
fc_stop_line:   db 0
fc_stop:        dw 0
fc_saved:       db 0
fc_blocks:      ds COLUMN_BLOCKS * 4
attr_at:        dw 0        ; the cells his colour is on
attr_rows:      db 0
attr_cols:      db 0
