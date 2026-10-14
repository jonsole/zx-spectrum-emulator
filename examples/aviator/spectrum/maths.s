; The arithmetic, after model/maths.py, giving exactly the original's results:
; the flight model and the 3D maths are built on these, and a difference of
; one in a low byte grows.
;
; Products come from a table of quarter squares, x * y = (x + y)^2 / 4 -
; (x - y)^2 / 4, which is exact: x + y and x - y are both odd or both even,
; so the two quarters drop the same remainder. The table (SQ_LO and SQ_HI,
; two pages each, for 0 to 510) is built by build.py.
;
; Numbers are kept as the original keeps them. Coordinates are 16-bit two's
; complement; matrix entries and the m values have their sign in bit 0 of
; the low byte, the magnitude being the whole 16-bit value with that bit
; taken as part of it (the "multi-byte variables" deep dive).

; HL = A * E, unsigned, inline. Uses A, B, D; C and E are kept.
    MACRO MUL8
    ld d,a
    sub e
    jr nc,.diff
    neg
.diff:
    ld b,a                      ; |x - y|
    ld a,d
    add a,e                     ; x + y, its ninth bit in the carry
    ld l,a
    ld a,high SQ_LO
    adc a,0
    ld h,a
    ld d,(hl)                   ; low byte of (x + y)^2 / 4
    inc h
    inc h
    ld a,(hl)                   ; and the high byte
    ld l,b
    ld b,a
    ld h,high SQ_LO
    ld a,d
    sub (hl)
    ld d,a
    inc h
    inc h
    ld a,b
    sbc a,(hl)
    ld h,a
    ld l,d
    ENDM

; HL = A * E, unsigned. Uses A, B, D; C and E are kept.
mul8:
    MUL8
    ret

; HL = (D E) * (B C) / 256, unsigned, the way the original's Multiply16x16
; does it, with its carry folded back into the high byte as all its callers
; do: (S * J) * 256 + J * R + S * I, plus the rounding constant that
; ApplyAerodynamics can change (mult1_round, the original's mult1+1), and
; the result is that sum's top 16 bits. I * R is never worked out.
; D = J, E = I, B = S, C = R. Uses everything but IX and IY.
mul16:
    ld (mul16_ji),de
    ld a,b
    ld (mul16_s),a
    ld a,d
    ld e,c
    MUL8                        ; J * R
    ld a,(mult1_round)
    add a,l
    ld l,a
    jr nc,.rounded
    inc h
.rounded:
    push hl
    ld a,(mul16_s)
    ld e,a
    ld a,(mul16_ji)
    MUL8                        ; S * I
    pop bc
    add hl,bc                   ; J * R + S * I + rounding, 17 bits
    ld a,l
    ld (mul16_w),a              ; the fraction, which ApplyAerodynamics keeps
    ld c,h
    push af                     ; the top nine of them: the carry and C
    ld a,(mul16_ji + 1)
    MUL8                        ; S * J
    pop af
    ld a,c
    jr nc,.add
    inc h
.add:
    add a,l
    ld l,a
    ret nc
    inc h
    ret

mul16_ji:   dw 0
mul16_s:    db 0
mul16_w:    db 0

; The rounding constant inside Multiply16x16, which the original keeps as
; the operand of its ADC at mult1 and ApplyAerodynamics rewrites: 128 to
; round to nearest, 0 to round down.
mult1_round:
    db 128

; HL = (D E) * (B C) / 65536 for two numbers with their signs in bit 0
; (Multiply16x16Bit0); the result has its sign in bit 0 of L, which is also
; returned in A (the original's K). Uses everything but IX and IY.
mul16_bit0:
    ld a,c
    xor e
    and 1
    ld (mul16_sign),a
    call mul16
    ld a,l
    and $FE
    ld l,a
    ld a,(mul16_sign)
    or l
    ld l,a
    ld a,(mul16_sign)
    ret

mul16_sign: db 0

; HL = (D E) * (B C) / 65536 where D E is two's complement and B C has its
; sign in bit 0 (Multiply16x16Mix, with K = 0); the result is two's
; complement. Only D E's sign is taken off before multiplying: B C goes in
; as it is, sign bit and all. Uses everything but IX and IY.
mul16_mix:
    ld a,c
    rrca                        ; B C's sign, to bit 7
    xor d                       ; and D E's
    ld (mul16_sign),a
    bit 7,d
    jr z,.positive
    xor a
    sub e
    ld e,a
    sbc a,a
    sub d
    ld d,a                      ; D E = -(D E)
.positive:
    call mul16
    ld a,(mul16_sign)
    rla
    ret nc
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a                      ; HL = -HL
    ret

; HL = (H L) + (D E) for two numbers with their signs in bit 0
; (Add16x16Bit0): the same signs add and saturate at the largest magnitude,
; different signs subtract the magnitudes and take the sign of the larger.
; The sign bits take part in the low bytes' arithmetic as ordinary bits, as
; they do in the original. Returns the sign of H L, the original's K, in C.
; Uses A, B, C.
add16_bit0:
    ld a,l
    and 1
    ld c,a
    xor e
    rrca
    jr c,.different
    ld a,l
    add a,e
    ld b,a
    ld a,h
    adc a,d
    ld h,a
    jr c,.saturate
    ld a,b
    and $FE
    or c
    ld l,a
    ret
.saturate:
    ld h,$FF
    ld a,$FE
    or c
    ld l,a
    ret
.different:
    ld a,l
    sub e
    ld b,a
    ld a,h
    sbc a,d
    ld h,a
    jr c,.larger_second
    ld a,b
    and $FE
    or c
    ld l,a
    ret
.larger_second:
    ; D E had the bigger magnitude: negate, and take the other sign.
    xor a
    sub b
    ld b,a
    ld a,0
    sbc a,h
    ld h,a
    ld a,b
    and $FE
    or c
    xor 1
    ld l,a
    ret

; HL = sin(H L), where 0 to 65535 is a quarter circle (Sine16Bit): the
; table entry for H, plus L / 256 of the way to the next one, with the step
; halved to fit a byte first, so the interpolation loses its bottom bit.
; Uses everything but IX and IY.
sine16:
    ld a,l
    ld (sine16_w),a
    ld e,h
    ld d,0
    ld hl,sinLo
    add hl,de
    ld c,(hl)                   ; sinLo[X]
    inc hl
    ld a,(hl)                   ; sinLo[X + 1]
    ld de,sinHi - sinLo - 1
    add hl,de
    ld b,(hl)                   ; B C = sin(X)
    inc hl
    ld h,(hl)
    ld l,a                      ; H L = sin(X + 1)
    or a
    sbc hl,bc                   ; the step to the next entry
    srl h
    rr l                        ; halved; only its low byte is kept
    ld a,(sine16_w)
    ld e,a
    ld a,l
    push bc
    call mul8                   ; step * W
    pop bc
    add hl,hl                   ; (step * W) >> 7 is now the carry and H
    ld a,h
    ld h,0
    rl h
    ld l,a
    add hl,bc
    ret

sine16_w:   db 0

; The two halves of the original's Multiply4x16, without the sign: H L =
; V * (S R) / 256 (product_plain) or / 128 (product_doubled), V being a
; 4-bit magnitude. In: B = S, C = R, D = V, E = V << 4.
;
; The original multiplies V by each nibble of (S R) and keeps only what
; lands above the bottom byte, which comes to V * S + (V * R's high nibble)
; / 16, truncated; when doubling, the bottom byte (the rest of that product
; and V * R's low nibble) is worked out after all, to carry its overflow and
; its top bit into the result, which is then exactly V * (S R) / 128. Each
; product of V with a nibble is a lookup in the original's timesTable at
; (a << 4) | b, which holds a * b either way round -- so the nibble that is
; already in the top half can go there as it is. Uses A, B, C, H, L.
product_plain:
    ld h,high timesTable
    ld a,c
    and $F0
    or d
    ld l,a
    ld a,(hl)                   ; t = V * R's high nibble
    rrca
    rrca
    rrca
    rrca
    and $0F
    ld c,a                      ; t / 16
    ld a,b
    and $0F
    or e
    ld l,a
    ld a,(hl)                   ; V * S's low nibble
    add a,c                     ; (at most 225 + 14: no carry)
    ld c,a
    ld a,b
    and $F0
    or d
    ld l,a
    ld a,(hl)                   ; q = V * S's high nibble
    rrca
    rrca
    rrca
    rrca
    ld b,a
    and $0F
    ld h,a
    ld a,b
    and $F0                     ; H A = 16 q
    add a,c
    ld l,a
    ret nc
    inc h
    ret

; As product_plain, doubled. Also uses AF'.
product_doubled:
    ld h,high timesTable
    ld a,c
    and $0F
    or e
    ld l,a
    ld a,(hl)
    ld (pd_w),a                 ; w = V * R's low nibble
    ld a,c
    and $F0
    or d
    ld l,a
    ld a,(hl)                   ; t = V * R's high nibble
    rrca
    rrca
    rrca
    rrca
    ld c,a                      ; t with its nibbles swapped
    and $F0
    ld l,a                      ; (t << 4) & $FF
    ld a,(pd_w)
    add a,l                     ; the bottom byte, and its overflow
    rla
    rla
    and 3                       ; the overflow, then the bottom byte's top bit
    ex af,af'
    ld a,c
    and $0F
    ld c,a                      ; t / 16
    ld a,b
    and $0F
    or e
    ld l,a
    ld a,(hl)                   ; V * S's low nibble
    add a,c
    ld c,a
    ld a,b
    and $F0
    or d
    ld l,a
    ld l,(hl)                   ; q = V * S's high nibble
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld b,0
    add hl,bc                   ; X, product_plain's result
    add hl,hl
    ex af,af'
    add a,l                     ; 2 X + 2 * overflow + top bit
    ld l,a
    ret nc
    inc h
    ret

pd_w:       db 0
