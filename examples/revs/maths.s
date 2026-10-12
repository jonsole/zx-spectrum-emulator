; The projection maths: yaw and pitch angles and verge widths, after the
; BBC's GetObjYawAngle, GetObjectDistance, GetObjPitchAngle and
; GetVergeAndMarkers.
;
; The BBC gets its ratios (256 * small / large) by shifting both values left
; until the larger has its top bit set and dividing by its high byte. Here
; every ratio and product is done with logarithms instead: log16 gives
; 256 * log2 of a 16-bit value from an 8-bit table, and the antilogarithm
; table turns a difference of logs back into a ratio. No division loops,
; and the verge width -- 2^23 / (distance * 2^vergeScale) yaw units --
; comes from the same distance log as the pitch.
;
; Logs are good to about one part in 256, so a ratio can be a unit out in
; its last bit: half a pixel or so on screen. Nothing here feeds physics.

; HL = 256 * log2(DE), for DE >= 1: 0 to 4095, 8.8 fixed point. The top eight
; significant bits, rounded, index the table. Uses A, B, DE.
log16:
    ld a,d
    or a
    jr nz,.wide
    ld l,e
    ld h,high tbl_log_lo
    ld a,(hl)
    inc h                       ; tbl_log_hi is the next page
    ld h,(hl)
    ld l,a
    ret
.wide:
    ld b,8                      ; the whole part still to add: 8 - shifts
    bit 7,d
    jr nz,.top
.shift:
    dec b
    sla e
    rl d
    jp p,.shift
.top:
    bit 7,e                     ; round to the nearer table entry
    jr z,.look
    inc d
    jr nz,.look
    dec d
.look:
    ld l,d
    ld h,high tbl_log_lo
    ld a,(hl)
    inc h
    ld h,(hl)
    ld l,a
    ld a,h
    add a,b
    ld h,a
    ret

; A = 2 ^ (HL / 256), for HL below 8 * 256: 0 if HL is negative.
exp8:
    bit 7,h
    jr nz,.zero
    ld a,h
    cp 8
    jr nc,.max
    neg
    add a,8
    ld b,a                      ; shifts: 8 - the whole part, 1..8
    ld h,high tbl_exp
    ld a,(hl)                   ; 2 ^ fraction = 1.f, f in A
    scf
    rra                         ; the implied 1 comes in on the first shift
    dec b
    ret z
.shift:
    srl a
    djnz .shift
    ret
.zero:
    xor a
    ret
.max:
    ld a,255
    ret

; HL = 2 ^ (HL / 256): 0 if HL is negative, $7FFF from 2 ^ 15 up.
exp16:
    bit 7,h
    jr nz,.zero
    ld a,h
    cp 15
    jr nc,.max
    ld h,high tbl_exp
    ld l,(hl)
    ld h,1                      ; HL = 256 * 2 ^ fraction
    sub 8
    jr c,.right
    ret z
    ld b,a
.left:
    add hl,hl
    djnz .left
    ret
.right:
    neg
    ld b,a
.down:
    srl h
    rr l
    djnz .down
    ret
.zero:
    ld hl,0
    ret
.max:
    ld hl,$7FFF
    ret

; The yaw angle of the vector (DE = dx, BC = dz) from the +z axis, as the BBC
; measures it: a 16-bit angle with 256 units a turn in the high byte,
; positive to the right. Returns HL = the angle, and leaves the octant's
; smaller angle and the two magnitudes in ya_m, ya_large and ya_small for
; distance. Uses everything but IX and IY.
yaw_angle:
    ld a,d
    ld (ya_sx),a
    ld a,b
    ld (ya_sz),a
    bit 7,d                     ; DE = |dx|
    jr z,.ax
    xor a
    sub e
    ld e,a
    sbc a,a
    sub d
    ld d,a
.ax:
    bit 7,b                     ; BC = |dz|
    jr z,.az
    xor a
    sub c
    ld c,a
    sbc a,a
    sub b
    ld b,a
.az:
    ld h,d
    ld l,e
    or a
    sbc hl,bc
    jr z,.equal
    jr c,.zbig
    ; |dx| > |dz|: the angle is measured from the x axis.
    ld (ya_large),de
    ld (ya_small),bc
    call .ratio
    ld a,(ya_sx)
    ld c,a
    ld a,(ya_sz)
    xor c
    jp m,.xsame                 ; signs differ: keep
    call .negate
.xsame:
    ld a,(ya_sx)
    or a
    ld a,64
    jp p,.xpos
    ld a,-64
.xpos:
    add a,h
    ld h,a
    ret
.zbig:
    ; |dz| > |dx|: measured from the z axis.
    ld (ya_large),bc
    ld (ya_small),de
    call .ratio
    ld a,(ya_sx)
    ld c,a
    ld a,(ya_sz)
    xor c
    call m,.negate              ; signs differ: negate
    ld a,(ya_sz)
    or a
    ret p
    ld a,h
    add a,128
    ld h,a
    ret
.equal:
    ld (ya_large),de            ; exactly diagonal
    ld (ya_small),de
    ld a,255
    ld (ya_m),a
    ld a,(ya_sx)
    rlca
    and 1
    ld c,a
    ld a,(ya_sz)
    rlca
    rlca
    and 2
    or c                        ; bit 0 = dx < 0, bit 1 = dz < 0
    ld hl,.diagonals
    add a,l
    ld l,a
    jr nc,.nc
    inc h
.nc:
    ld h,(hl)
    ld l,0
    ret
.diagonals:
    db $20, $E0, $60, $A0
; HL = 32 * arctanY(256 * small / large), and ya_m = the arctanY.
.ratio:
    ld de,(ya_small)
    ld a,d
    or e
    jr z,.flat
    call log16
    push hl
    ld de,(ya_large)
    call log16
    ex de,hl
    pop hl
    or a
    sbc hl,de
    ld de,8*256
    add hl,de
    call exp8                   ; 256 * small / large
    ld l,a
    ld h,high tbl_arctan
    ld a,(hl)
.flat:
    ld (ya_m),a
    ld l,a                      ; HL = A * 32
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ret
.negate:
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    ret

ya_sx:    db 0
ya_sz:    db 0
ya_m:     db 0
ya_large: dw 0
ya_small: dw 0

; The distance from the last yaw_angle, by alpha max plus beta min as
; GetObjectDistance does it: max + min / 8 below about 18 degrees, else
; max * 7/8 + min / 2. Returns HL.
distance:
    ld hl,(ya_large)
    ld bc,(ya_small)
    ld a,(ya_m)
    cp 103
    jr nc,.wide
    srl b
    rr c
    srl b
    rr c
    srl b
    rr c
    add hl,bc
    ret
.wide:
    srl b
    rr c
    add hl,bc                   ; max + min / 2
    ld bc,(ya_large)
    srl b
    rr c
    srl b
    rr c
    srl b
    rr c
    or a
    sbc hl,bc                   ; - max / 8
    ret

; The track line of a point HL = dy above the eye at distance DE, as
; GetObjPitchAngle: T = 256 * (|dy| / 8) / distance, line = 60 +/- T.
; Returns A = the line (a signed byte, -67..127; negative is below the view)
; with carry clear, or carry set if the point is out of sight (T >= 128).
; Leaves the distance's log in pa_log for verge_width.
pitch_line:
    ld a,h
    ld (pa_sign),a
    bit 7,h
    jr z,.pos
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
.pos:
    ld a,d
    or e
    jr z,.hidden                ; on top of the eye
    push hl
    call log16
    ld (pa_log),hl
    pop de
    ld a,d
    or e
    ld a,60
    ret z                       ; level with the eye: carry is clear
    call log16
    ld de,(pa_log)
    or a
    sbc hl,de
    ld de,5*256                 ; 256 / 8 = 2 ^ 5
    add hl,de
    bit 7,h
    jr nz,.level                ; T below 1
    ld a,h
    cp 7
    jr nc,.hidden               ; T >= 128
.level:
    call exp8
    ld b,a
    ld a,(pa_sign)
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

pa_sign:   db 0
pa_log:    dw 0

; The screen width of a verge mark at the distance pitch_line last saw:
; 2^23 / (distance * 2^vergeScale) yaw units, the BBC's scaleUp *
; 2^(scaleDown - vergeScale), over 40 yaw units a pixel. A = vergeScale
; (3..5). Returns HL = the width in pixels.
LOG2_WIDTH  equ 23*256 - 1362   ; 256 * (23 - log2 40)

verge_width:
    ld de,(pa_log)
    ld hl,LOG2_WIDTH
    or a
    sbc hl,de
    ld e,0
    ld d,a
    sbc hl,de                   ; carry is clear: no borrow above
    jp exp16

; HL = 128 + the screen x of the relative yaw angle in HL: yaw / 40, the
; BBC's 40-unit field of view across 256 pixels. A signed 16-bit result.
yaw_to_x:
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
    ld bc,128
    add hl,bc
    ret
