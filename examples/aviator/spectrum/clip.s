; Clipping lines to the canopy, after model/clip.py (whose docstring has the
; whole method): each visible line is clipped by the original's rules,
; recorded in the line buffer for the current colour exactly as the original
; records it, and then drawn on the Spectrum: its two ends are where the
; BBC's line drawer would finish (pass_end, model/zx.py), and draw_view_line
; draws between them.

CANOPY_LEFT     equ 4
CANOPY_RIGHT    equ 155
CANOPY_BOTTOM   equ 0
CANOPY_TOP      equ 151
OFF_BOTTOM      equ $10         ; an end's clipping code
OFF_TOP         equ $20
OFF_LEFT        equ $40
OFF_RIGHT       equ $80
LEFTWARDS       equ $80         ; the direction byte V
DOWNWARDS       equ $40
REVERSE         equ $C0
HORIZON         equ $02
CLIPPED         equ $01
Y_RAISE         equ 4
ANTI_DIAGONAL   equ 159
BUFFER1_FULL    equ 47
BUFFER2_FULL    equ 95

; A = the clipping code of (H L, D E), 16-bit signed: which sides of the
; canopy it is off. Uses A, C.
classify:
    ld c,0
    bit 7,d
    jr z,.y_positive
    ld c,OFF_BOTTOM
    jr .x
.y_positive:
    ld a,d
    or a
    jr nz,.top
    ld a,e
    cp CANOPY_TOP + 1
    jr c,.x
.top:
    ld c,OFF_TOP
.x:
    bit 7,h
    jr nz,.left
    ld a,h
    or a
    jr nz,.right
    ld a,l
    cp CANOPY_LEFT
    jr c,.left
    cp CANOPY_RIGHT + 1
    jr c,.done
.right:
    ld a,c
    or OFF_RIGHT
    ret
.left:
    ld a,c
    or OFF_LEFT
    ret
.done:
    ld a,c
    ret

; The line being clipped: its start, its end (with their codes), the
; magnitudes of its deltas and its direction byte.
ln_x0:  dw 0
ln_y0:  dw 0
ln_c0:  db 0
ln_x1:  dw 0
ln_y1:  dw 0
ln_c1:  db 0
ln_dx:  dw 0
ln_dy:  dw 0
ln_v:   db 0

; Make the end the start (SwapLinePoints).
swap_line_points:
    ld hl,(ln_x1)
    ld (ln_x0),hl
    ld hl,(ln_y1)
    ld (ln_y0),hl
    ld a,(ln_c1)
    ld (ln_c0),a
    ret

; Move the line's start along it to where it crosses the canopy's diagonal
; (ClipStartOfLine). Carry set if the line can't be on the screen.
; Otherwise the start is the clipped point, V gains CLIPPED, and the point
; is copied to xTemp1Lo and yTemp1Lo, as the original does.
clip_start_of_line:
    ld a,(ln_v)
    ld b,a
    ld a,(ln_c0)
    ld c,a
    ; A start off one side, heading away from it, can't reach the canopy.
    ld a,OFF_RIGHT
    bit 7,b
    jr z,.side
    ld a,OFF_LEFT
.side:
    and c
    jp nz,.abort
    ld a,OFF_TOP
    bit 6,b
    jr z,.end_side
    ld a,OFF_BOTTOM
.end_side:
    and c
    jp nz,.abort
    ; y raised by 4 makes the canopy a square, 4 to 155 on both axes.
    ld hl,(ln_y0)
    ld de,Y_RAISE
    add hl,de
    ld (cs_y),hl
    ; The distance from the diagonal across the line's slope: y - x for a
    ; line whose x and y run opposite ways, x + y - 159 for one whose run
    ; the same way.
    ld a,b
    rla
    xor b                       ; bit 7: bits 6 and 7 differ
    and $80
    ld (cs_falling),a
    ld de,(ln_x0)
    jr z,.rising
    or a
    sbc hl,de                   ; y - x
    jr .distance
.rising:
    add hl,de
    ld de,ANTI_DIAGONAL
    or a
    sbc hl,de                   ; x + y - 159
.distance:
    call abs16
    ld (cs_distance),hl
    ld hl,(ln_dx)
    ld de,(ln_dy)
    add hl,de
    inc hl
    inc hl
    ld (cs_span),hl
    ; The point moves along the axis the line changes fastest on.
    ld hl,(ln_dx)
    or a
    sbc hl,de
    jr nc,.shallow
    ; Steep: y.
    ld a,1
    ld (cs_steep),a
    ld hl,(ln_dy)
    inc hl
    ld (cs_run),hl
    ld a,(ln_v)
    and DOWNWARDS
    ld (cs_backwards),a
    ld hl,(cs_y)
    ld (cs_x),hl
    jr .scale
.shallow:
    xor a
    ld (cs_steep),a
    ld hl,(ln_dx)
    inc hl
    ld (cs_run),hl
    ld a,(ln_v)
    and LEFTWARDS
    ld (cs_backwards),a
    ld hl,(ln_x0)
    ld (cs_x),hl
.scale:
    call clip_scale             ; H L = distance * run / span
    ex de,hl
    ld hl,(cs_x)
    ld a,(cs_backwards)
    or a
    jr z,.forwards
    or a
    sbc hl,de
    jr .moved
.forwards:
    add hl,de
.moved:
    ; The other coordinate comes from the diagonal.
    ld a,(cs_falling)
    or a
    jr z,.not_falling
    ld (cs_x),hl
    ld (cs_y),hl
    jr .check
.not_falling:
    ex de,hl
    ld hl,ANTI_DIAGONAL
    or a
    sbc hl,de                   ; 159 - moved
    ld a,(cs_steep)
    or a
    jr z,.shallow_point
    ld (cs_x),hl
    ld (cs_y),de
    jr .check
.shallow_point:
    ld (cs_y),hl
    ld (cs_x),de
.check:
    ; x must be on the canopy; only y's low byte is checked, as on the
    ; diagonal an x inside the canopy puts y inside too.
    ld hl,(cs_x)
    ld a,h
    or a
    jr nz,.abort
    ld a,l
    cp CANOPY_LEFT
    jr c,.abort
    cp CANOPY_RIGHT + 1
    jr nc,.abort
    ld a,(cs_y)
    sub Y_RAISE
    jr c,.abort
    cp CANOPY_TOP + 1
    jr nc,.abort
    ld (yTemp1Lo),a
    ld e,a
    ld d,0
    ld (ln_y0),de
    ld a,l
    ld (xTemp1Lo),a
    ld (ln_x0),hl
    ld a,(ln_v)
    or CLIPPED
    ld (ln_v),a
    or a
    ret
.abort:
    scf
    ret

cs_y:           dw 0
cs_x:           dw 0
cs_distance:    dw 0
cs_span:        dw 0
cs_run:         dw 0
cs_falling:     db 0
cs_steep:       db 0
cs_backwards:   db 0

; H L = cs_distance * cs_run / cs_span to the nearest whole number, by the
; original's long division (ClipStartOfLine part 4), to 1/256 and with its
; registers' overflows: the divisor and the multiplier are doubled together
; until the divisor reaches the distance, then halved together a step at a
; time, the divisor taken from the remainder (and the multiplier added to
; the total) as often as it goes; the total starts at a half, to round, and
; the division stops when the remainder is under 2/256. The values are 24
; bits, kept low byte first.
clip_scale:
    ld hl,(cs_span)
    ld de,(cs_run)
    ld bc,(cs_distance)
.double:
    or a
    sbc hl,bc
    add hl,bc
    jr nc,.doubled              ; divisor >= distance
    add hl,hl
    ex de,hl
    add hl,hl
    ex de,hl
    jr .double
.doubled:
    xor a
    ld (sc_rem),a
    ld (sc_rem + 1),bc          ; remainder = distance << 8
    ld (sc_div),a
    ld (sc_div + 1),hl          ; divisor << 8
    ld (sc_mul),a
    ld (sc_mul + 1),de          ; multiplier << 8
    ld hl,$0080
    ld (sc_total),hl
    ld (sc_total + 2),a         ; total = $80
.halve:
    ld hl,sc_div + 2
    srl (hl)
    dec hl
    rr (hl)
    dec hl
    rr (hl)
    ld hl,sc_mul + 2
    srl (hl)
    dec hl
    rr (hl)
    dec hl
    rr (hl)
    call .div_above_rem
    jr c,.halve                 ; divisor > remainder
.subtract:
    ; total += multiplier, remainder -= divisor
    ld hl,(sc_total)
    ld de,(sc_mul)
    add hl,de
    ld (sc_total),hl
    ld a,(sc_total + 2)
    ld hl,sc_mul + 2
    adc a,(hl)
    ld (sc_total + 2),a
    ld hl,(sc_rem)
    ld de,(sc_div)
    or a
    sbc hl,de
    ld (sc_rem),hl
    ld a,(sc_rem + 2)
    ld hl,sc_div + 2
    sbc a,(hl)
    ld (sc_rem + 2),a
    ; remainder < 2?
    ld hl,(sc_rem + 1)
    ld a,h
    or l
    jr nz,.not_done
    ld a,(sc_rem)
    cp 2
    jr c,.result
.not_done:
    call .div_above_rem
    jr c,.halve
    jr .subtract
.result:
    ; (total >> 8) + bit 7 of total
    ld hl,(sc_total + 1)
    ld a,(sc_total)
    rla
    ret nc
    inc hl
    ret
.div_above_rem:
    ; Carry set if the divisor > the remainder.
    ld hl,(sc_rem + 1)
    ld de,(sc_div + 1)
    or a
    sbc hl,de
    ret nz                      ; the high parts differ: carry says which
    ld a,(sc_rem)
    ld hl,sc_div
    cp (hl)
    ret                         ; carry if rem's low byte < div's

sc_rem:     ds 3
sc_div:     ds 3
sc_mul:     ds 3
sc_total:   ds 3

; For a line with both ends off the screen (ClipBestEndOfLine): drop it if
; both are off the same side, and otherwise clip the end nearer the canopy,
; judged by the coordinates' high bytes, swapping the ends and reversing
; the direction if that is the end. maxCoord keeps the larger of the
; start's. Carry set if the line can't be on the screen.
clip_best_end_of_line:
    ld a,(ln_c0)
    ld b,a
    ld a,(ln_c1)
    and b
    scf
    ret nz
    ld a,(ln_y0 + 1)
    call .size
    ld b,a
    ld a,(ln_x0 + 1)
    call .size
    cp b
    jr nc,.biggest
    ld a,b
.biggest:
    ld (maxCoord),a
    ld b,a
    ld a,(ln_x1 + 1)
    call .size
    cp b
    jp nc,clip_start_of_line
    ld a,(ln_y1 + 1)
    call .size
    cp b
    jp nc,clip_start_of_line
    call swap_line_points
    ld a,(ln_v)
    xor REVERSE
    ld (ln_v),a
    jp clip_start_of_line
.size:
    ; A high byte's magnitude, near enough: inverted if negative.
    bit 7,a
    ret z
    cpl
    ret

; Clip the line from point A to point C to the canopy, record it in the
; line buffer for the current colour, and draw it (DrawClippedLine; with
; dcl_horizon set, DrawClippedHorizon).
draw_clipped_line:
    ld (dcl_start),a
    ld a,c
    ld (dcl_end),a
    ld a,(dcl_horizon)
    ld (ln_v),a
    ; The ends, and the line's deltas as magnitudes with their directions.
    ld a,(dcl_start)
    ld l,a
    ld h,high xPointLo
    ld e,(hl)
    ld h,high xPointHi
    ld d,(hl)
    ld (ln_x0),de
    ld h,high yPointLo
    ld e,(hl)
    ld h,high yPointHi
    ld d,(hl)
    ld (ln_y0),de
    ld a,(dcl_end)
    ld l,a
    ld h,high xPointLo
    ld e,(hl)
    ld h,high xPointHi
    ld d,(hl)
    ld (ln_x1),de
    ld h,high yPointLo
    ld e,(hl)
    ld h,high yPointHi
    ld d,(hl)
    ld (ln_y1),de
    ld hl,(ln_x1)
    ld de,(ln_x0)
    or a
    sbc hl,de                   ; the coordinates are signed: bit 15 is the sign
    bit 7,h
    jr z,.dx
    call negate_hl
    ld a,(ln_v)
    or LEFTWARDS
    ld (ln_v),a
.dx:
    ld (ln_dx),hl
    ld hl,(ln_y1)
    ld de,(ln_y0)
    or a
    sbc hl,de
    bit 7,h
    jr z,.dy
    call negate_hl
    ld a,(ln_v)
    or DOWNWARDS
    ld (ln_v),a
.dy:
    ld (ln_dy),hl
    ld hl,(ln_x0)
    ld de,(ln_y0)
    call classify
    ld (ln_c0),a
    ld hl,(ln_x1)
    ld de,(ln_y1)
    call classify
    ld (ln_c1),a

    ; Which point to draw from, and how far.
    ld a,1
    ld (dcl_to_edge),a
    ld a,(dcl_end)
    ld l,a
    ld h,high zPointHi
    bit 7,(hl)
    jr z,.end_ahead
    ; The end is behind: draw from the start, away from its projection.
    ld a,(ln_v)
    xor REVERSE
    ld (ln_v),a
    ld a,(ln_c0)
    or a
    jr z,.limits
    call clip_start_of_line
    ret c
    jr .limits
.end_ahead:
    ld a,(dcl_start)
    ld l,a
    bit 7,(hl)
    jr z,.both_ahead
    ; The start is behind: draw from the end, onwards.
    call swap_line_points
    ld a,(ln_c0)
    or a
    jr z,.limits
    call clip_start_of_line
    ret c
    jr .limits
.both_ahead:
    ld a,(ln_c0)
    or a
    jr z,.start_on
    ld a,(ln_c1)
    or a
    jr z,.from_end
    call clip_best_end_of_line
    ret c
    jr .limits
.from_end:
    ; Draw from the end, which is on the screen, back towards the start.
    ld a,(ln_v)
    xor REVERSE
    ld (ln_v),a
    ld hl,(ln_x1)
    ld (ln_x0),hl
    ld hl,(ln_y1)
    ld (ln_y0),hl
    jr .limits
.start_on:
    ld a,(ln_c1)
    or a
    jr nz,.limits
    xor a
    ld (dcl_to_edge),a

.limits:
    ; The line's limits and slope. One wholly on the screen runs to its
    ; end; the rest run to the canopy's edge, their deltas halved together
    ; until they fit in a byte (and once more for 255).
    ld a,(ln_x0)
    ld (dcl_r),a
    ld a,(ln_y0)
    ld (dcl_s),a
    ld a,(dcl_to_edge)
    or a
    jr z,.to_end
    ld a,(ln_v)
    call edges
    ld (dcl_w),bc
    ld hl,(ln_dx)
    ld de,(ln_dy)
.fit:
    ld a,h
    or d
    jr z,.fits
    srl h
    rr l
    srl d
    rr e
    jr .fit
.fits:
    ld a,l
    inc a
    jr nz,.dx_ok
    srl l
    srl e
.dx_ok:
    ld a,e
    inc a
    jr nz,.slope
    srl l
    srl e
    jr .slope
.to_end:
    ld a,(ln_x1)
    ld (dcl_w),a
    ld a,(ln_y1)
    ld (dcl_g),a
    ld a,(ln_dx)
    ld l,a
    ld a,(ln_dy)
    ld e,a
.slope:
    ld a,l
    inc a
    ld (dcl_t),a
    ld a,e
    inc a
    ld (dcl_u),a

    ; Record it in the line buffer for this colour, if there is room.
    ld hl,lineBuffer1Count
    ld b,BUFFER1_FULL
    ld a,(colourCycle)
    rla
    jr c,.buffer
    ld hl,lineBuffer2Count
    ld b,BUFFER2_FULL
.buffer:
    ld a,(hl)
    cp b
    ret z
    inc a
    ld (hl),a
    ld e,a
    ld d,0
    MACRO RECORD table, value
    ld hl,table
    add hl,de
    ld a,(value)
    ld (hl),a
    ENDM
    RECORD lineBufferR, dcl_r
    RECORD lineBufferW, dcl_w
    RECORD lineBufferS, dcl_s
    RECORD lineBufferG, dcl_g
    RECORD lineBufferT, dcl_t
    RECORD lineBufferU, dcl_u
    RECORD lineBufferV, ln_v

    ; Draw it on the Spectrum, between where the BBC's drawer would end.
    jp draw_buffered_line

dcl_start:      db 0
dcl_end:        db 0
dcl_horizon:    db 0
dcl_to_edge:    db 0
dcl_r:          db 0
dcl_s:          db 0
dcl_w:          db 0            ; dcl_w and dcl_g together, for edges
dcl_g:          db 0
dcl_t:          db 0
dcl_u:          db 0

; C = the canopy's edge in x and B in y in direction A (the limits for
; drawing a line to the edge), as dcl_w, dcl_g.
edges:
    ld c,CANOPY_RIGHT
    bit 7,a
    jr z,.x
    ld c,CANOPY_LEFT
.x:
    ld b,CANOPY_TOP
    bit 6,a
    ret z
    ld b,CANOPY_BOTTOM
    ret

; H L = -H L.
negate_hl:
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    ret

; Draw the line just recorded (dcl_r ... dcl_u, ln_v) between its two ends:
; the start (or a clipped line's second half's end) and its first run's end,
; each found by pass_end.
draw_buffered_line:
    ld a,(dcl_r)
    ld (pe_x),a
    ld a,(dcl_s)
    ld (pe_y),a
    ld a,(dcl_w)
    ld (pe_w),a
    ld a,(dcl_g)
    ld (pe_g),a
    ld a,(ln_v)
    ld (pe_v),a
    call pass_end
    ld a,(pe_x)
    ld (vl_x1),a
    ld a,(pe_y)
    ld (vl_y1),a
    ld a,(dcl_r)
    ld (vl_x0),a
    ld a,(dcl_s)
    ld (vl_y0),a
    ld a,(ln_v)
    and CLIPPED
    jp z,draw_view_line
    ; A clipped line's second half runs from the same point the other way,
    ; without CLIPPED, to the edge.
    ld a,(ln_v)
    xor REVERSE
    and ~CLIPPED
    ld (pe_v),a
    call edges
    ld a,c
    ld (pe_w),a
    ld a,b
    ld (pe_g),a
    ld a,(dcl_r)
    ld (pe_x),a
    ld a,(dcl_s)
    ld (pe_y),a
    call pass_end
    ld a,(pe_x)
    ld (vl_x0),a
    ld a,(pe_y)
    ld (vl_y0),a
    jp draw_view_line

; Where one run of the BBC's line drawer from (pe_x, pe_y) ends, with limits
; (pe_w, pe_g), slope dcl_t : dcl_u and direction pe_v; the end is left in
; (pe_x, pe_y). See model/zx.py's pass_end: a shallow line has stepped y
; floor((e0 + n u) / t) times by pixel n, the k-th step comes after pixel
; ceil((k t - e0) / u) - 1, and it ends at whichever stop comes first.
pass_end:
    ld a,(dcl_u)
    ld b,a
    ld a,(dcl_t)
    cp b
    jp z,.steep
    jp c,.steep
    ; Shallow: x every pixel. e0 = t - 1 where the drawer steps at once.
    ld c,0
    ld a,(pe_v)
    and HORIZON | CLIPPED
    jr z,.shallow_e0
    ld a,b
    cp 2
    jr c,.shallow_e0
    ld a,(dcl_t)
    dec a
    ld c,a
.shallow_e0:
    ld a,c
    ld (pe_e0),a
    ; n = pixels to the canopy's side.
    ld a,(pe_v)
    bit 7,a
    ld a,(pe_x)
    jr nz,.shallow_left
    neg
    add a,CANOPY_RIGHT
    jr .shallow_n
.shallow_left:
    sub CANOPY_LEFT
.shallow_n:
    ld (pe_n),a
    ; The stop at row g, if the line heads towards it: rows = g - y going
    ; up, y - g going down (0 to 151, so compared unsigned).
    ld a,(pe_g)
    ld b,a
    ld a,(pe_y)
    ld c,a
    ld a,(pe_v)
    bit 6,a
    jr nz,.shallow_down
    ld a,b
    sub c
    jr c,.shallow_end
    jr .shallow_k
.shallow_down:
    ld a,c
    sub b
    jr c,.shallow_end
.shallow_k:
    inc a                       ; k = rows + 1
    ld e,a
    ld a,(dcl_t)
    call mul8                   ; k t
    ld a,(pe_e0)
    ld e,a
    ld d,0
    or a
    sbc hl,de
    dec hl                      ; k t - e0 - 1
    ld a,(dcl_u)
    ld c,a
    call div16_8                ; floor((k t - e0 - 1) / u) = ceil(...) - 1
    ld a,h
    or a
    jr nz,.shallow_end
    ld a,(pe_n)
    cp l
    jr c,.shallow_end
    ld a,l
    ld (pe_n),a
.shallow_end:
    ; x += n * step; y += floor((e0 + n u) / t) * step.
    ld a,(pe_v)
    bit 7,a
    ld a,(pe_n)
    ld b,a
    ld a,(pe_x)
    jr nz,.shallow_xl
    add a,b
    jr .shallow_x
.shallow_xl:
    sub b
.shallow_x:
    ld (pe_x),a
    ld a,(dcl_u)
    ld e,a
    ld a,(pe_n)
    call mul8
    ld a,(pe_e0)
    ld e,a
    ld d,0
    add hl,de
    ld a,(dcl_t)
    ld c,a
    call div16_8
    ld b,l
    ld a,(pe_v)
    bit 6,a
    ld a,(pe_y)
    jr nz,.shallow_yd
    add a,b
    jr .shallow_y
.shallow_yd:
    sub b
.shallow_y:
    ld (pe_y),a
    ret

.steep:
    ; Steep: y every pixel. e0 = u - 1 where the drawer steps at once.
    ld c,0
    ld a,(pe_v)
    and HORIZON | CLIPPED
    jr z,.steep_e0
    ld a,(dcl_t)
    cp 2
    jr c,.steep_e0
    ld a,(dcl_u)
    dec a
    ld c,a
.steep_e0:
    ld a,c
    ld (pe_e0),a
    ld a,(pe_v)
    bit 6,a
    ld a,(pe_y)
    jr nz,.steep_down
    neg
    add a,CANOPY_TOP
    jr .steep_n
.steep_down:
    sub CANOPY_BOTTOM
.steep_n:
    ld (pe_n),a
    ; The stop at column w, if the line heads towards it.
    ld a,(pe_w)
    ld b,a
    ld a,(pe_x)
    ld c,a
    ld a,(pe_v)
    bit 7,a
    jr nz,.steep_left_columns
    ld a,b
    sub c
    jr c,.steep_end
    jr .steep_k
.steep_left_columns:
    ld a,c
    sub b
    jr c,.steep_end
.steep_k:
    inc a
    ld e,a
    ld a,(dcl_u)
    call mul8                   ; k u
    ld a,(pe_e0)
    ld e,a
    ld d,0
    or a
    sbc hl,de
    dec hl
    ld a,(dcl_t)
    ld c,a
    call div16_8
    ld a,h
    or a
    jr nz,.steep_end
    ld a,(pe_n)
    cp l
    jr c,.steep_end
    ld a,l
    ld (pe_n),a
.steep_end:
    ld a,(pe_v)
    bit 6,a
    ld a,(pe_n)
    ld b,a
    ld a,(pe_y)
    jr nz,.steep_yd
    add a,b
    jr .steep_y
.steep_yd:
    sub b
.steep_y:
    ld (pe_y),a
    ld a,(dcl_t)
    ld e,a
    ld a,(pe_n)
    call mul8
    ld a,(pe_e0)
    ld e,a
    ld d,0
    add hl,de
    ld a,(dcl_u)
    ld c,a
    call div16_8
    ld b,l
    ld a,(pe_v)
    bit 7,a
    ld a,(pe_x)
    jr nz,.steep_xl
    add a,b
    jr .steep_x
.steep_xl:
    sub b
.steep_x:
    ld (pe_x),a
    ret

pe_x:   db 0
pe_y:   db 0
pe_w:   db 0
pe_g:   db 0
pe_v:   db 0
pe_e0:  db 0
pe_n:   db 0

; One step of div16_8: the next bit of L into the remainder A, and the
; quotient's bit into L. A remainder of 128 or more can pass 255 when
; doubled, which the carry catches.
    MACRO DIV_STEP
    sla l
    rla
    jr c,.subtract
    cp c
    jr c,.next
.subtract:
    sub c
    inc l
.next:
    ENDM

; L = H L / C and A = the remainder, when the quotient is below 256 (H is
; below C), with H = 0; when it isn't (or C is 0), H = $FF. Uses A.
div16_8:
    ld a,h
    cp c
    jr nc,.large
    DIV_STEP
    DIV_STEP
    DIV_STEP
    DIV_STEP
    DIV_STEP
    DIV_STEP
    DIV_STEP
    DIV_STEP
    ld h,0
    ret
.large:
    ld h,$FF
    ret
