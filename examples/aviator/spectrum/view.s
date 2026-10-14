; The canopy view on the Spectrum's screen, after model/zx.py: lines are
; drawn into CANOPY_BUFFER (one row of 32 bytes for each of the canopy's 114
; screen rows, 6 to 119), and present copies the view to the screen with
; the frame laid over it, where the BBC would swap colours in its palette.
;
; A line's ends are mapped from the BBC's canopy coordinates (x 4-155 from
; the left, y 0-151 up from the bottom) by the tables view_x and view_y, and
; the line drawn between them is model/zx.py's bresenham, pixel for pixel.
;
; A view is only a few hundred pixels, so present doesn't copy the whole
; buffer. The line drawer keeps, for each buffer row, the first and last
; columns it has drawn in (ext_lo and ext_hi), and present copies, row by
; row, the columns this view or the last drew in -- the last view's must be
; rubbed out -- and clears this view's. Every other byte of the screen is as
; the last view left it, which is what copying the whole buffer would have
; put there anyway. An extent that takes in a byte more than was drawn in
; costs a byte's copying and changes nothing.

VIEW_TOP    equ 6               ; the screen row of buffer row 0
EXT_HI      equ 120             ; ext_hi (and prev_hi) are this far after ext_lo (prev_lo)
EMPTY_LO    equ $FF             ; an extent with nothing in it
EMPTY_HI    equ $00

    ASSERT low CANOPY_BUFFER == 0

; Draw a line in the canopy buffer from BBC canopy point (vl_x0, vl_y0) to
; (vl_x1, vl_y1), both ends included: the longer axis steps every pixel, the
; other when the error, starting at half the longer length, runs out.
;
; Most of the view's lines are shallow, and most of their pixels are steps
; along a row, so those have runs of their own, shallow_right and
; shallow_left: eight copies of a pixel's step, one for each bit of a byte,
; entered at the first pixel's, which gather the byte's pixels in D and
; write it when the line leaves it. A step to the next row is shallow_row's.
; Steep lines step a row every pixel, and keep to one loop with its
; directions patched in.
draw_view_line:
    ld h,high view_x
    ld a,(vl_x0)
    ld l,a
    ld b,(hl)                   ; X0
    ld a,(vl_x1)
    ld l,a
    ld a,(hl)
    ld (vl_xe),a                ; X1
    ld d,a
    ld h,high view_y
    ld a,(vl_y0)
    ld l,a
    ld c,(hl)                   ; Y0, a buffer row
    ld a,(vl_y1)
    ld l,a
    ld a,(hl)
    ld (vl_ye),a                ; Y1
    ld e,a
    ; The direction on each axis: x's picks the shallow run and is patched
    ; into the steep loop, y's is patched into both.
    ld a,d
    sub b
    jr c,.left
    ld (vl_dx),a
    ld a,$09                    ; RRC C
    ld (.st_x + 1),a
    ld a,$2C                    ; INC L
    ld (.st_xinc),a
    ld hl,shallow_right
    xor a                       ; entered at bit position X0 & 7
    jr .y_direction
.left:
    neg
    ld (vl_dx),a
    ld a,$01                    ; RLC C
    ld (.st_x + 1),a
    ld a,$2D                    ; DEC L
    ld (.st_xinc),a
    ld hl,shallow_left
    ld a,7                      ; at 7 - (X0 & 7)
.y_direction:
    ld (vl_run),hl
    ld (vl_flip),a
    ld a,e
    sub c
    jr c,.up
    ld (vl_dy),a
    ld a,$C6                    ; ADD A,n
    ld (sr_y),a
    ld (.st_y),a
    ld a,$24                    ; INC H
    ld (sr_yh),a
    ld (.st_yh),a
    ld a,$23                    ; INC IX
    ld (sr_ix + 1),a
    ld (.st_ix + 1),a
    jr .start
.up:
    neg
    ld (vl_dy),a
    ld a,$D6                    ; SUB n
    ld (sr_y),a
    ld (.st_y),a
    ld a,$25                    ; DEC H
    ld (sr_yh),a
    ld (.st_yh),a
    ld a,$2B                    ; DEC IX
    ld (sr_ix + 1),a
    ld (.st_ix + 1),a
.start:
    ; Where the shallow run is entered: SHALLOW_STEP bytes a bit.
    ld a,b
    and 7
    ld e,a
    ld a,(vl_flip)
    xor e
    ld e,a
    add a,a
    add a,a
    add a,e
    add a,a
    ld e,a
    ld d,0
    ld hl,(vl_run)
    add hl,de
    ld (.enter + 1),hl
    ; IX -> the first row's extent, H L -> the first pixel's byte, C its mask.
    ld ix,ext_lo
    ld e,c
    add ix,de                   ; (D is 0)
    ld l,c
    ld h,d
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl                   ; row * 32
    ld a,b
    rrca
    rrca
    rrca
    and $1F
    ld e,a
    ld d,high CANOPY_BUFFER
    add hl,de
    ld a,b
    and 7
    ld e,a
    ld d,high bit_masks
    ld a,(de)
    ld c,a                      ; the mask
    ld a,(vl_dy)
    ld (.st_dy_add + 1),a
    ld d,a
    ld a,(vl_dx)
    ld (.st_dx + 1),a
    cp d
    jp c,.steep

    ; x is the longer axis: the error loses dy a pixel, and on running out
    ; gains dx and the line moves a row.
    ld (sr_dx + 1),a
    call view_extent            ; the first row starts here
    ld a,(vl_dx)
    ld b,a
    srl a
    ld e,a                      ; the error, dx / 2
    inc b                       ; dx + 1 pixels (dx is below 255)
    ld a,(vl_dy)
    ld c,a                      ; C = dy
    ld d,0                      ; D = the pixels so far in this byte
.enter:
    jp 0

.steep:
    ; y is the longer axis: every pixel is a row of its own.
    ld a,d
    ld b,a
    srl a
    ld e,a                      ; the error, dy / 2
    inc b
.st_loop:
    ld a,(hl)
    or c
    ld (hl),a
    ld a,l                      ; this row's extent
    and $1F
    cp (ix + 0)
    jr nc,.st_not_lower
    ld (ix + 0),a
.st_not_lower:
    cp (ix + EXT_HI)
    jr c,.st_not_higher
    ld (ix + EXT_HI),a
.st_not_higher:
    ld a,e
.st_dx:
    sub 0
    jr nc,.st_no_x
.st_dy_add:
    add a,0
    ld e,a
.st_x:
    rrc c
    jr nc,.st_y_step
.st_xinc:
    inc l
    jr .st_y_step
.st_no_x:
    ld e,a
.st_y_step:
.st_ix:
    inc ix
    ld a,l
.st_y:
    add a,32
    ld l,a
    jr nc,.st_next
.st_yh:
    inc h
.st_next:
    djnz .st_loop
    ret

SHALLOW_STEP equ 10             ; the bytes of each pixel's step in the shallow runs

; The shallow runs: in, B = the pixels left, C = dy, D = this byte's pixels
; so far, E = the error, H L -> the byte, IX -> the row's extent.
shallow_right:
.p0:
    set 7,d
    ld a,e
    sub c
    jr c,.row0
    ld e,a
.next0:
    dec b
    jr z,.end
.p1:
    set 6,d
    ld a,e
    sub c
    jr c,.row1
    ld e,a
.next1:
    dec b
    jr z,.end
.p2:
    set 5,d
    ld a,e
    sub c
    jr c,.row2
    ld e,a
.next2:
    dec b
    jr z,.end
.p3:
    set 4,d
    ld a,e
    sub c
    jr c,.row3
    ld e,a
.next3:
    dec b
    jr z,.end
.p4:
    set 3,d
    ld a,e
    sub c
    jr c,.row4
    ld e,a
.next4:
    dec b
    jr z,.end
.p5:
    set 2,d
    ld a,e
    sub c
    jr c,.row5
    ld e,a
.next5:
    dec b
    jr z,.end
.p6:
    set 1,d
    ld a,e
    sub c
    jr c,.row6
    ld e,a
.next6:
    dec b
    jr z,.end
.p7:
    set 0,d
    ld a,e
    sub c
    jr c,.row7
    ld e,a
.next7:
    dec b
    jr z,.end
    ld a,(hl)                   ; the byte is done
    or d
    ld (hl),a
    ld d,0
    inc l
    jp .p0
.end:
    jp shallow_end
.row0:
    call shallow_row
    jp .next0
.row1:
    call shallow_row
    jp .next1
.row2:
    call shallow_row
    jp .next2
.row3:
    call shallow_row
    jp .next3
.row4:
    call shallow_row
    jp .next4
.row5:
    call shallow_row
    jp .next5
.row6:
    call shallow_row
    jp .next6
.row7:
    call shallow_row
    jp .next7

shallow_left:
.p0:
    set 0,d
    ld a,e
    sub c
    jr c,.row0
    ld e,a
.next0:
    dec b
    jr z,.end
.p1:
    set 1,d
    ld a,e
    sub c
    jr c,.row1
    ld e,a
.next1:
    dec b
    jr z,.end
.p2:
    set 2,d
    ld a,e
    sub c
    jr c,.row2
    ld e,a
.next2:
    dec b
    jr z,.end
.p3:
    set 3,d
    ld a,e
    sub c
    jr c,.row3
    ld e,a
.next3:
    dec b
    jr z,.end
.p4:
    set 4,d
    ld a,e
    sub c
    jr c,.row4
    ld e,a
.next4:
    dec b
    jr z,.end
.p5:
    set 5,d
    ld a,e
    sub c
    jr c,.row5
    ld e,a
.next5:
    dec b
    jr z,.end
.p6:
    set 6,d
    ld a,e
    sub c
    jr c,.row6
    ld e,a
.next6:
    dec b
    jr z,.end
.p7:
    set 7,d
    ld a,e
    sub c
    jr c,.row7
    ld e,a
.next7:
    dec b
    jr z,.end
    ld a,(hl)                   ; the byte is done
    or d
    ld (hl),a
    ld d,0
    dec l
    jp .p0
.end:
    jp shallow_end
.row0:
    call shallow_row
    jp .next0
.row1:
    call shallow_row
    jp .next1
.row2:
    call shallow_row
    jp .next2
.row3:
    call shallow_row
    jp .next3
.row4:
    call shallow_row
    jp .next4
.row5:
    call shallow_row
    jp .next5
.row6:
    call shallow_row
    jp .next6
.row7:
    call shallow_row
    jp .next7

    ASSERT shallow_right.p1 - shallow_right.p0 == SHALLOW_STEP
    ASSERT shallow_left.p7 - shallow_left.p0 == 7 * SHALLOW_STEP

; A shallow line's step to the next row, with A the error that ran out:
; write this byte, and record where the line leaves the row and enters the
; next. The next pixel may be in the next byte, which the run moves to
; afterwards; the extent taking in the byte before it is harmless.
shallow_row:
sr_dx:
    add a,0
    ld e,a
    ld a,(hl)
    or d
    ld (hl),a
    ld d,0
    call view_extent            ; the row ends here
sr_ix:
    inc ix
    ld a,l
sr_y:
    add a,32
    ld l,a
    jr nc,sr_y_done
sr_yh:
    inc h
sr_y_done:
    jp view_extent              ; and the next starts here

; The end of a shallow line: write the last byte, and the last row ends at
; the line's end, (X1, Y1). (A step to a row after the last may have
; recorded an extent past the line; that, too, is harmless.)
shallow_end:
    ld a,(hl)
    or d
    ld (hl),a
    ld a,(vl_ye)
    ld e,a
    ld d,0
    ld ix,ext_lo
    add ix,de
    ld a,(vl_xe)
    rrca
    rrca
    rrca
    and $1F
    ld l,a
    ; fall through, with L's column

; Widen row IX's extent to take in the column of L. Uses A.
view_extent:
    ld a,l
    and $1F
    cp (ix + 0)
    jr nc,.not_lower
    ld (ix + 0),a
.not_lower:
    cp (ix + EXT_HI)
    ret c
    ld (ix + EXT_HI),a
    ret

vl_x0:  db 0
vl_y0:  db 0
vl_x1:  db 0
vl_y1:  db 0
vl_xe:  db 0
vl_ye:  db 0
vl_dx:  db 0
vl_dy:  db 0
vl_run: dw 0
vl_flip: db 0

; Copy to the screen, row by row, the columns this view or the last drew in,
; laying the frame over the four edge bytes (keep mask, then OR pattern, from
; canopy_overlay); clear them in the buffer, which clears this view's, the
; rest being clear already; and make this view's extents the last view's. A
; row neither view drew in costs only the test that finds it empty.
present:
    ld a,(score_shown)
    ld b,a
    ld a,(too_late_shown)
    or b
    ld hl,buffer_plot_text
    call nz,draw_messages       ; the messages that are up, into this view
    ld hl,ext_lo                ; H = this view's page (the last's is next), L = the row
.scan:
    ld a,(hl)
    inc h
    and (hl)                    ; both lows are $FF only if both rows are empty
    dec h
    inc a
    jr nz,.row
    inc l
    ld a,(hl)
    inc h
    and (hl)
    dec h
    inc a
    jr nz,.row
    inc l
    jr .scan
.row:
    ld a,l
    cp CANOPY_ROWS
    ret z                       ; the row after the last, which is never empty
    ld (pr_row),a
    ; C = the lower low, B = the higher high; this view's pass to the last.
    ld c,(hl)
    ld (hl),EMPTY_LO
    inc h
    ld a,(hl)
    ld (hl),c
    cp c
    jr nc,.lo
    ld c,a
.lo:
    ld a,l
    add a,EXT_HI
    ld l,a
    ld b,(hl)
    dec h
    ld a,(hl)
    ld (hl),EMPTY_HI
    inc h
    ld (hl),a
    cp b
    jr c,.hi
    ld b,a
.hi:
    ; D E -> the row on the screen, H L -> in the buffer (CANOPY_BUFFER + 32 row).
    ld a,(pr_row)
    add a,a
    add a,low view_rows
    ld l,a
    ld h,high view_rows
    ld e,(hl)
    inc l
    ld d,(hl)
    ld a,(pr_row)
    rrca
    rrca
    rrca
    ld h,a
    and $E0
    ld l,a
    xor h
    add a,high CANOPY_BUFFER
    ld h,a
    ; Columns 0 and 1, and 30 and 31, have the frame laid over them.
    ld a,c
    cp 2
    jr c,.left
.no_left:
    ld a,b
    cp 30
    jr nc,.right
.middle:
    ld a,b
    sub c
    jr c,.done                  ; nothing between the edges
    inc a
    ld b,a                      ; the number of columns
    ld a,e
    add a,c
    ld e,a
    ld a,l
    add a,c
    ld l,a
    ld c,0
.copy:
    ld a,(hl)
    ld (de),a
    ld (hl),c
    inc l
    inc e
    djnz .copy
.done:
    ld a,(pr_row)
    inc a
    ld l,a
    ld h,high ext_lo
    jp .scan
.left:
    ld (pr_buffer),hl
    ld (pr_screen),de
    push bc
    ld a,c
    or a
    jr nz,.left_1
    call pr_edge                ; column 0
.left_1:
    ld a,1
    call pr_edge
    pop bc
    ld c,2
    ld hl,(pr_buffer)
    ld de,(pr_screen)
    jr .no_left
.right:
    ld (pr_buffer),hl
    ld (pr_screen),de
    push bc
    ld a,30
    call pr_edge
    pop bc
    push bc
    ld a,b
    cp 31
    jr nz,.right_30
    call pr_edge                ; column 31
.right_30:
    pop bc
    ld b,29
    ld hl,(pr_buffer)
    ld de,(pr_screen)
    jr .middle

; Copy edge column A (0, 1, 30 or 31) of row pr_row from the buffer row at
; pr_buffer to the screen row at pr_screen, with the frame laid over it, and
; clear it in the buffer. Uses everything but IX and IY.
pr_edge:
    ld c,a                      ; the column
    cp 2
    jr c,.index
    sub 28                      ; 30, 31 -> 2, 3
.index:
    add a,a
    ld e,a
    ld d,0
    ld a,(pr_row)
    ld l,a
    ld h,d
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,de
    ld de,canopy_overlay
    add hl,de                   ; -> (keep, frame)
    ex de,hl
    ld hl,(pr_buffer)
    ld a,l
    add a,c
    ld l,a
    ld a,(de)
    and (hl)                    ; keep
    ld (hl),0
    inc de
    ex de,hl
    or (hl)                     ; frame
    ld b,a
    ld hl,(pr_screen)
    ld a,l
    add a,c
    ld l,a
    ld (hl),b
    ret

pr_row:     db 0
pr_buffer:  dw 0
pr_screen:  dw 0
