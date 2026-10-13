; Projecting points onto the screen, after model/project.py (see its
; docstring for the whole story): screen x = 80 + 256 x / z and screen
; y = 96 + 512 y / z, divided the way a floating-point unit would.
;
; ScaleUp splits |z| into an exponent and a mantissa, the mantissa's top byte
; picks a reciprocal from the division table, DivideScaled multiplies each
; numerator's mantissa by it -- by nibbles, adding up exactly what the
; original adds up, carries counted twice and all -- and ScaleDown puts the
; exponents back and rounds.

PROJECTED   equ $01             ; pointStatus bits ProjectPoint sets
Y_NEGATIVE  equ $04
X_NEGATIVE  equ $08
Y_WIDE      equ $10             ; 2 |y| >= |z|
X_WIDE      equ $20             ; |x| >= |z|
CENTRE_X    equ 80
CENTRE_Y    equ 96
SHIFT_LIMIT equ 7
LARGEST_OFFSET equ $3FFF

    ASSERT low timesTable == 0 && low divisionLo == 0 && low divisionHi == 0

; A = the product of A's two nibbles (the original's timesTable). Uses HL.
    MACRO NIBBLES
    ld h,high timesTable
    ld l,a
    ld a,(hl)
    ENDM

; A = A's top nibble, moved to the bottom.
    MACRO TOP_NIBBLE
    rrca
    rrca
    rrca
    rrca
    and $0F
    ENDM

; Split H L, not 0, into its mantissa and exponent (ScaleUp): H L shifted
; left until its leading 1 falls out of the top, and A such that A + 1 is
; the number of binary digits it had. Uses nothing else.
scale_up:
    ld a,15
    inc h
    dec h
    jr nz,.loop
    ld h,l                      ; a top byte of 0: eight places at once
    ld l,0
    ld a,7
.loop:
    add hl,hl
    ret c
    dec a
    jp .loop

; Divide H L, a 16-bit magnitude, by the denominator split into exponent
; dv_uu and a mantissa whose top byte gave the reciprocal (dv_tt dv_s) and
; whose low byte is dv_k (DivideScaled). Returns H L = the ratio of the
; mantissas, 32768 standing for 1, and A = the numerator's exponent, so the
; quotient is (H L) * 2^(A - uu - 15). A numerator of 0 gives 0, with
; uu - 1 as the exponent, so that ScaleDown leaves it at 0.
;
; The products of nibbles come from timesTable, at (a << 4) | b; the index
; is put together from two bytes as ((x ^ y) & $F0) ^ y, which is x's top
; nibble and y's bottom one. Uses everything but IX and IY, and AF'.
divide_scaled:
    ld a,h
    or l
    jr nz,.nonzero
    ld a,(dv_uu)
    dec a
    ret
.nonzero:
    call scale_up
    ld (dv_ww),a
    ld a,h
    ld (dv_j),a
    ld c,a                      ; C = J, the mantissa's top byte
    ld a,l
    ld (dv_i),a                 ; and I its low byte
    ld a,(dv_tt)
    ld b,a                      ; B = TT
    ld h,high timesTable
    ; The cross sum, TT's top * J's low + TT's low * J's top, in nine bits:
    ; D = its low byte, E = $FF if it carried.
    xor c
    and $F0
    xor c
    ld l,a
    ld d,(hl)
    ld a,c
    xor b
    and $F0
    xor b
    ld l,a
    ld a,(hl)
    add a,d
    ld d,a
    sbc a,a
    ld e,a
    ; With J's nibbles swapped, its top nibble is at the bottom.
    ld a,c
    rrca
    rrca
    rrca
    rrca
    ld c,a
    ld a,b
    xor c
    and $F0
    xor c
    ld l,a
    ld a,(hl)                   ; TT's top * J's top, for Q
    ex af,af'
    ld a,c
    xor b
    and $F0
    xor b
    ld l,a
    ld b,(hl)                   ; TT's low * J's low
    ld a,(dv_s)
    xor c
    and $F0
    xor c
    ld l,a
    ld a,b
    add a,(hl)                  ; + S's top * J's top: the low sum
    ld c,a                      ; C = P, its bottom byte
    sbc a,a
    ld b,a
    ex af,af'
    sub b                       ; + its carry
    inc a                       ; + 1, the 256 the table leaves out
    ld b,a                      ; B = Q (at most 227)
    ; The cross sum's low nibble (moved to the top), then J, then S, go into
    ; the low byte, each addition taking the last one's carry -- the first
    ; takes the cross sum's own -- and the first two also counting theirs
    ; in the high byte, L, which starts at 16 if the cross sum carried.
    ld a,e
    and 16
    ld l,a
    ld a,(dv_j)
    ld e,a
    ld a,d
    add a,a
    add a,a
    add a,a
    add a,a
    ld h,a
    ld a,l
    add a,$F0                   ; the cross sum's carry
    ld a,c
    adc a,h
    jr nc,.no_carry1
    inc l
.no_carry1:
    adc a,e                     ; + J
    jr nc,.no_carry2
    inc l
.no_carry2:
    ld h,a
    ld a,(dv_s)
    adc a,h                     ; + S
    ld c,a                      ; the low byte
    ; The high byte: L + Q + that carry (at most 246) + the cross sum's top
    ; nibble, which may pass 255.
    ld a,l
    adc a,b
    ld l,a
    ld a,d
    rrca
    rrca
    rrca
    rrca
    and $0F
    add a,l
    ld l,a
    ld a,(dv_tt)
    jr c,.overflow
    add a,l                     ; + TT, its carry the top bit
    ld h,a
    jr .halve
.overflow:
    ; Past 255: the overflow becomes the top bit, and a carry from adding
    ; TT is lost.
    add a,l
    ld h,a
    scf
.halve:
    rr h
    ld l,c
    rr l                        ; (top H low) / 2

    ; With I, the numerator mantissa's low byte, not 0: add TT * I / 256,
    ; from I's top nibble against both of TT's, halved to match. The
    ; products with I's low nibble are left out; in their place the low
    ; part of one product is added to I itself, and its carry rounds up.
    ld a,(dv_i)
    or a
    jr z,.quarters
    push hl
    ld h,high timesTable
    ld b,a                      ; B = I
    ld a,(dv_tt)
    ld c,a                      ; C = TT
    rrca
    rrca
    rrca
    rrca
    xor b
    and $0F
    xor b
    ld d,a                      ; (I's top, TT's top), for the second product
    ld a,c
    xor b
    and $0F
    xor b
    ld l,a
    ld a,(hl)                   ; I's top * TT's low
    rrca
    rrca
    rrca
    rrca
    ld c,a
    and $0F
    ld e,a                      ; its top nibble
    ld a,c
    and $F0
    add a,b                     ; its low nibble, at the top, + I: the carry rounds up
    ld l,d
    ld a,(hl)                   ; I's top * TT's top
    adc a,e                     ; (at most 241: no carry)
    rra                         ; halved
    pop hl
    add a,l
    ld l,a
    jr nc,.quarters
    inc h
    jr nz,.quarters
    ld hl,$FFFF

.quarters:
    ; The denominator mantissa's low byte: its top two bits step a quarter,
    ; a half or three-quarters of the way to the next table entry, taking
    ; Q * that fraction of TT / 256 off the result.
    ld a,(dv_k)
    and $C0
    jr z,.done
    ld b,a
    ld a,(dv_tt)
    add a,1
    rra                         ; w = (TT + 1) / 2
    ld c,a
    xor a
    bit 6,b
    jr z,.no_quarter
    ld a,c
    srl a
.no_quarter:
    bit 7,b
    jr z,.no_half
    add a,c
.no_half:
    ld e,a
    push hl
    ld a,h
    call mul8                   ; Q * step
    ld a,h
    pop hl
    ld b,a
    ld a,l
    sub b
    ld l,a
    jr nc,.done
    dec h
.done:
    ld a,(dv_ww)
    ret

; H L = quotient H L * 2^(A - 8), rounded to the nearest whole number: shifted
; left by A, or right by -A (A as a signed byte), its bottom byte the
; fraction; a round up that takes the top byte to $40 gives $3FFF.
shift_and_round:
    bit 7,a
    jr z,.left
    neg
    ld b,a
    ld a,h                      ; only the high byte is shifted right
    ld h,0
    ld c,0                      ; the bits shifted out
    ld l,a
    ld a,b
    cp 9
    jr c,.right
    ld hl,0                     ; more than 8 places: nothing left
    ret
.right:
    srl l
    rl c
    djnz .right
    ld a,c
    rrca
    jr .round
.left:
    ld e,0                      ; E H L, 24 bits
    or a
    jr z,.shifted
    ld b,a
.left_loop:
    add hl,hl
    rl e
    djnz .left_loop
.shifted:
    ld a,l                      ; bit 7 of the fraction rounds
    rla
    ld l,h
    ld h,e
.round:
    ret nc
    inc l
    ret nz
    inc h
    ld a,h
    cp $40
    ret c
    ld hl,LARGEST_OFFSET
    ret

; Turn the two quotients back into screen offsets (ScaleDown): sd_x and
; sd_y become 256 times the true quotients, rounded. sd_uu is the
; denominator's exponent, sd_vv and sd_ww the numerators'; the shifts are
; vv - uu + 1 and ww - uu + 1. When either is 7 or more -- or negative,
; which the original's unsigned comparison takes as large, harmlessly --
; both are first brought down together until neither is more than 6, or 7
; if the quotient with the larger shift is below $8000.
scale_down:
    ld a,(sd_uu)
    ld b,a
    ld a,(sd_vv)
    sub b
    inc a
    ld d,a                      ; D = x's shift
    ld a,(sd_ww)
    sub b
    inc a
    ld e,a                      ; E = y's shift
    ld c,SHIFT_LIMIT
    ld a,d
    cp c
    jr nc,.big
    ld a,e
    cp c
    jr c,.balanced
.big:
    ld a,(sd_ww)
    ld b,a
    ld a,(sd_vv)
    sub b
    jr nz,.unequal
    ld a,(sd_y + 1)
    ld b,a
    ld a,(sd_x + 1)
    or b
    jr .room
.unequal:
    cp $80
    ld a,(sd_x + 1)
    jr c,.room
    ld a,(sd_y + 1)
.room:
    rla
    jr c,.balanced_limit
    inc c                       ; room for 8
.balanced_limit:
    ; Bring both shifts down together until each is below the limit C.
    bit 7,e
    jr nz,.check_x
.reduce_y:
    ld a,e
    cp c
    jr c,.check_x
    dec e
    dec d
    jr .reduce_y
.check_x:
    bit 7,d
    jr nz,.balanced
.reduce_x:
    ld a,d
    cp c
    jr c,.balanced
    dec d
    dec e
    jr .reduce_x
.balanced:
    push de
    ld hl,(sd_x)
    ld a,d
    call shift_and_round
    ld (sd_x),hl
    pop de
    ld hl,(sd_y)
    ld a,e
    call shift_and_round
    ld (sd_y),hl
    ret

sd_uu:  db 0
sd_vv:  db 0
sd_ww:  db 0
sd_x:   dw 0
sd_y:   dw 0

; H L = |H L| as 16 bits (-32768 stays $8000), carry set if it was negative.
abs16:
    bit 7,h
    ret z
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    scf
    ret

; D E = |D E| (-32768 stays $8000). Uses A.
    MACRO ABS_DE
    bit 7,d
    jr z,.positive
    xor a
    sub e
    ld e,a
    sbc a,a
    sub d
    ld d,a
.positive:
    ENDM

; Project point A onto the screen (ProjectPoint): its x and y become the
; screen coordinates, and pointStatus gets the bits above. A point that has
; been projected already is left alone.
project_point:
    ld l,a
    ld h,high pointStatus
    ld a,(hl)
    rrca
    ret c                       ; projected already
    ld a,l
    ld (pp_pid),a
    ld b,PROJECTED              ; B = the status bits to set
    ; |z|, a z of 0 being taken as 1, and its sign.
    ld h,high zPointLo
    ld e,(hl)
    ld h,high zPointHi
    ld d,(hl)
    ld c,d                      ; C = z's sign, in bit 7
    ABS_DE
    ld a,d
    or e
    jr nz,.z_nonzero
    inc e
.z_nonzero:
    ld (pp_z),de
    ; |x|. Its offset from the centre is added when x and z have the same
    ; sign, and taken away when they differ.
    ld h,high xPointLo
    ld e,(hl)
    ld h,high xPointHi
    ld d,(hl)
    ld a,c
    xor d
    ld (pp_xsub),a              ; bit 7
    bit 7,d
    jr z,.x_positive
    ld b,PROJECTED | X_NEGATIVE
.x_positive:
    ABS_DE
    ld (pp_x),de
    ; 2 |y|, losing the top bit.
    ld h,high yPointLo
    ld e,(hl)
    ld h,high yPointHi
    ld d,(hl)
    ld a,c
    xor d
    ld (pp_ysub),a
    bit 7,d
    jr z,.y_positive
    ld a,b
    or Y_NEGATIVE
    ld b,a
.y_positive:
    ABS_DE
    sla e
    rl d
    ld (pp_y),de
    ; Wide: 2 |y| >= |z|, |x| >= |z|.
    ex de,hl
    ld de,(pp_z)
    or a
    sbc hl,de
    jr c,.y_narrow
    ld a,b
    or Y_WIDE
    ld b,a
.y_narrow:
    ld hl,(pp_x)
    or a
    sbc hl,de
    jr c,.x_narrow
    ld a,b
    or X_WIDE
    ld b,a
.x_narrow:
    ld a,b
    ld (pp_flags),a
    ; |z|'s exponent and mantissa, and its reciprocal.
    ex de,hl
    call scale_up
    ld (dv_uu),a
    ld (sd_uu),a
    ld a,l
    ld (dv_k),a
    ld l,h
    ld h,high divisionHi
    ld a,(hl)
    ld (dv_tt),a
    ld h,high divisionLo
    ld a,(hl)
    and $F8                     ; the bottom bits are a log2 table
    ld (dv_s),a
    ld hl,(pp_x)
    call divide_scaled
    ld (sd_vv),a
    ld (sd_x),hl
    ld hl,(pp_y)
    call divide_scaled
    ld (sd_ww),a
    ld (sd_y),hl
    call scale_down
    ; The screen coordinates, from the centre and the offsets.
    ld de,(sd_x)
    ld hl,CENTRE_X
    ld a,(pp_xsub)
    rla
    jr c,.x_away
    add hl,de
    jr .x_done
.x_away:
    or a
    sbc hl,de
.x_done:
    ex de,hl
    ld a,(pp_pid)
    ld l,a
    ld h,high xPointLo
    ld (hl),e
    ld h,high xPointHi
    ld (hl),d
    ld de,(sd_y)
    ld hl,CENTRE_Y
    ld a,(pp_ysub)
    rla
    jr c,.y_away
    add hl,de
    jr .y_done
.y_away:
    or a
    sbc hl,de
.y_done:
    ex de,hl
    ld a,(pp_pid)
    ld l,a
    ld h,high yPointLo
    ld (hl),e
    ld h,high yPointHi
    ld (hl),d
    ld h,high pointStatus
    ld a,(pp_flags)
    or (hl)
    ld (hl),a
    ret

pp_pid:     db 0
pp_flags:   db 0
pp_xsub:    db 0
pp_ysub:    db 0
pp_x:       dw 0
pp_y:       dw 0
pp_z:       dw 0

dv_uu:      db 0
dv_ww:      db 0
dv_tt:      db 0
dv_s:       db 0
dv_k:       db 0
dv_j:       db 0
dv_i:       db 0
