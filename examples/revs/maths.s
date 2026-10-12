; The projection maths: yaw and pitch angles and verge widths, after the
; BBC's GetObjYawAngle, GetObjectDistance, GetObjPitchAngle and
; GetVergeAndMarkers.
;
; The BBC gets its ratios (256 * small / large) by shifting both values left
; until the larger has its top bit set and dividing by its high byte. Here
; every ratio and product is done with logarithms instead, all by table:
; log16 looks a 16-bit value's logarithm up in a 12-bit table, exp8 turns a
; difference of logs back into a ratio, and the distance is the larger
; delta's log plus a correction for the angle (tbl_logft). No division and
; no multiplication anywhere, and the verge width -- 2^23 / (distance *
; 2^vergeScale) yaw units -- comes from the same distance log as the pitch.
;
; Logs are good to about one part in 256, so a ratio can be a unit out in
; its last bit: half a pixel or so on screen. Nothing here feeds physics.

; HL = 256 * log2(DE), for DE >= 1 (0 for 0): 0 to 4095, 8.8 fixed point.
; Below 4096 it is a lookup; above, DE's top twelve bits are, plus 4. The
; table holds only the fraction, the low byte: the whole part, the high
; byte, is floor(log2), the position of the value's top bit, so it comes
; from D (or from E when D is 0) through a small table. That is 3.8K less
; than a second 4K of high bytes, and the shifted case is no slower: its 4
; is in tbl_log_hl. Uses A, DE. A macro, for the code that can't spare a
; call, and a routine.
    MACRO LOG16
    ld a,d
    cp 16
    jr c,.small@
    srl d
    rr e
    srl d
    rr e
    srl d
    rr e
    srl d
    rr e
    ld hl,tbl_log12_lo
    add hl,de
    ld a,(hl)
    ld h,high tbl_log_hl        ; 12 + floor(log2 D): D is 1..15 here
    ld l,d
    ld h,(hl)
    ld l,a
    jr .done@
.small@:
    ld hl,tbl_log12_lo
    add hl,de
    or a                        ; A is still D
    ld a,(hl)
    jr z,.byte@
    ld h,high tbl_log_hs        ; 8 + floor(log2 D)
    ld l,d
    ld h,(hl)
    ld l,a
    jr .done@
.byte@:
    ld h,high tbl_log_he        ; floor(log2 E)
    ld l,e
    ld h,(hl)
    ld l,a
.done@:
    ENDM

log16:
    LOG16
    ret

; A = floor(2 ^ (HL / 256)): 0 if HL is negative, 255 from 8 * 256 up.
exp8:
    ld a,h
    cp 8
    jr nc,.out
    add a,high tbl_exp8
    ld h,a
    ld a,(hl)
    ret
.out:
    rlca                        ; carry if negative
    sbc a,a
    cpl
    ret

; HL = 2 ^ (HL / 256): 0 if HL is negative, $7FFF from 2 ^ 15 up.
exp16:
    ld a,h
    cp 8
    jr nc,.wide
    add a,high tbl_exp8
    ld h,a
    ld l,(hl)
    ld h,0
    ret
.wide:
    bit 7,a
    jr nz,.zero
    cp 15
    jr nc,.max
    sub 7
    ld b,a
    ld h,high tbl_exp8 + 7      ; 128 * 2 ^ fraction, then doubled
    ld l,(hl)
    ld h,0
.left:
    add hl,hl
    djnz .left
    ret
.zero:
    ld hl,0
    ret
.max:
    ld hl,$7FFF
    ret

; The yaw angle of the vector (DE = dx, BC = dz) from the +z axis, as the BBC
; measures it: a 16-bit angle with 256 units a turn in the high byte,
; positive to the right. Returns HL = the angle and leaves the log of the
; distance in ya_logd. Uses everything but IX and IY.
;
; As GetObjYawAngle: the angle within the octant is the arctangent of
; smaller / larger delta, and the octant -- which delta is larger, and the
; two signs -- says whether to negate it and which quarter turn to add. The
; BBC's exact diagonal, where the two deltas are equal, comes out of the
; tables a fraction of a pixel off 45 degrees rather than as a special case.
yaw_angle:
    ld h,0                      ; the octant: bit 0 dx < 0, bit 1 dz < 0,
    bit 7,d                     ; bit 2 if |dx| is the larger
    jr z,.xpos
    xor a
    sub e
    ld e,a
    sbc a,a
    sub d
    ld d,a
    inc h
.xpos:
    bit 7,b
    jr z,.zpos
    xor a
    sub c
    ld c,a
    sbc a,a
    sub b
    ld b,a
    inc h
    inc h
.zpos:
    ld a,e
    sub c
    ld a,d
    sbc a,b
    jr c,.zlarger
    set 2,h
    jr .larger_in_de
.zlarger:
    ld a,b                      ; swap: the larger in DE, the smaller in BC
    ld b,d
    ld d,a
    ld a,c
    ld c,e
    ld e,a
.larger_in_de:
    ld a,h
    push af
    push bc
    call log16
    ld (ya_logd),hl             ; the larger delta's log, for now
    pop de
    ld a,d
    or e
    jr z,.t                     ; A = 0: on an axis
    call log16
    ld de,(ya_logd)
    or a
    sbc hl,de
    ld a,h
    add a,8                     ; T = 256 * smaller / larger = 2 ^ (8 + difference)
    cp 8
    jr nc,.t_out
    add a,high tbl_exp8
    ld h,a
    ld a,(hl)
    jr .t
.t_out:
    rlca                        ; negative: T below 1
    sbc a,a
    cpl
.t:
    ld l,a
    ld h,high tbl_logft
    ld e,(hl)
    ld d,0
    inc h                       ; tbl_a32_lo
    ld c,(hl)
    inc h                       ; tbl_a32_hi
    ld b,(hl)                   ; BC = the angle within the octant
    ld hl,(ya_logd)
    add hl,de
    ld (ya_logd),hl
    pop af
    ld hl,.octants
    add a,l
    ld l,a
    ld a,(hl)
    ld h,b
    ld l,c
    bit 0,a
    jr z,.keep
    ld c,a
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    ld a,c
.keep:
    and $C0
    add a,h
    ld h,a
    ret
; By octant: the quarter turn to add in the top two bits, bit 0 to negate.
    ALIGN 8
.octants:
    db 0, 1, 128+1, 128         ; |dz| larger: by the signs of dx, dz
    db 64+1, 192, 64, 192+1     ; |dx| larger

ya_logd:  dw 0

; The track line of a point at distance log HL whose height above the eye
; has sign pa_dysign (and pa_logdy, from pitch_height), as GetObjPitchAngle:
; T = 256 * (|dy| / 8) / distance, line = 60 +/- T. Returns A = the line (a
; signed byte, -67..127; negative is below the view) with carry clear, or
; carry set if the point is out of sight (T >= 128).
pitch_line:
    ex de,hl
    ld hl,(pa_logdy)
    or a
    sbc hl,de
    bit 7,h
    jr nz,.level                ; T below 1
    ld a,h
    cp 7
    jr nc,.hidden               ; T >= 128
.level:
    call exp8
    ld b,a
    ld a,(pa_dysign)
    or a
    ld a,60
    jp m,.below
    add a,b                     ; 60..187: no carry
    ret p
    ; Above line 127, which is well above the view, a line no longer fits a
    ; signed byte. Clamping it bends an edge that runs off the top, which
    ; only a crest close ahead could show.
    ld a,127
    or a
    ret
.below:
    sub b
    or a
    ret
.hidden:
    scf
    ret

; pa_logdy and pa_dysign for a height difference HL: pa_logdy is the log of
; 256 * |dy| / 8, ready to have the distance's log taken off it for T.
; Uses A, DE.
LOG_ZERO    equ -64*256         ; the log of nothing: far below any other

pitch_height:
    ld a,h
    ld (pa_dysign),a
    bit 7,h
    jr z,.pos
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
.pos:
    ld a,h
    or l
    jr z,.zero
    ex de,hl
    call log16
    ld de,5*256                 ; 256 / 8 = 2 ^ 5
    add hl,de
    ld (pa_logdy),hl
    ret
.zero:
    ld hl,LOG_ZERO
    ld (pa_logdy),hl
    ret

pa_dysign: db 0
pa_logdy:  dw 0

; The screen width of a verge mark at distance log HL: 2^23 / (distance *
; 2^vergeScale) yaw units, the BBC's scaleUp * 2^(scaleDown - vergeScale),
; over 40 yaw units a pixel. A = vergeScale (3..5). Returns HL = the width
; in pixels.
LOG2_WIDTH  equ 23*256 - 1362   ; 256 * (23 - log2 40)

verge_width:
    ex de,hl
    ld hl,LOG2_WIDTH
    or a
    sbc hl,de
    ld e,0
    ld d,a
    sbc hl,de                   ; carry is clear: no borrow above
    jp exp16

; HL = 128 + the screen x of the relative yaw angle in HL: yaw / 40, the
; BBC's 40-unit field of view across 256 pixels (the 128 is in tbl_xhi). A
; signed 16-bit result. Uses BC, E. A macro and a routine.
    MACRO YAW_TO_X
    ld e,l
    ld l,h
    ld h,high tbl_xhi_lo
    ld c,(hl)
    inc h                       ; tbl_xhi_hi
    ld b,(hl)
    ld l,e
    inc h                       ; tbl_xfrac
    ld l,(hl)
    ld h,0
    add hl,bc
    ENDM

yaw_to_x:
    YAW_TO_X
    ret
