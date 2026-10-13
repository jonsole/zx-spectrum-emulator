; The rotation matrices, after model/matrices.py: ProjectAxisAngle turns each
; of the plane's three rotation angles into a sine and a cosine (mx1 to mz2),
; and SetMatrices builds matrices 1 to 4 from them. Every value is 16-bit
; with its sign in bit 0. The order of the multiplications, and which
; results are reused, are the original's: each product is rounded, so the
; same matrix worked out another way would differ slightly.

MX1 equ 0                       ; offsets from mx1Lo / mx1Hi
MY1 equ 1
MZ1 equ 2
MX2 equ 3
MY2 equ 4
MZ2 equ 5

    ASSERT mx1Hi - mx1Lo == 16  ; project_axis_angle reaches both with IX

; Load or store a 16-bit value kept as separate low and high bytes.
    MACRO GET_DE lo, hi
    ld a,(lo)
    ld e,a
    ld a,(hi)
    ld d,a
    ENDM
    MACRO GET_BC lo, hi
    ld a,(lo)
    ld c,a
    ld a,(hi)
    ld b,a
    ENDM
    MACRO GET_HL lo, hi
    ld a,(lo)
    ld l,a
    ld a,(hi)
    ld h,a
    ENDM
    MACRO PUT_HL lo, hi
    ld a,l
    ld (lo),a
    ld a,h
    ld (hi),a
    ENDM

; Axis values and matrix entries, by index.
    MACRO MV_DE i
    GET_DE mx1Lo + i, mx1Hi + i
    ENDM
    MACRO MV_BC i
    GET_BC mx1Lo + i, mx1Hi + i
    ENDM
    MACRO M1_DE i
    GET_DE matrix1Lo + i, matrix1Hi + i
    ENDM
    MACRO M1_HL i
    GET_HL matrix1Lo + i, matrix1Hi + i
    ENDM
    MACRO M1_PUT i
    PUT_HL matrix1Lo + i, matrix1Hi + i
    ENDM

; Set the sine and cosine for one axis from its rotation angle,
; xRotation (Hi Lo) + axis. In: A = the axis (0 x, 1 y, 2 z).
;
; A full circle is 0 to 65535: the top two bits pick the quadrant, and the
; rest, shifted up to fill 16 bits, is the angle within it, whose sine and
; -- by inverting it -- cosine come from sine16. The quadrant then decides
; which of the two goes where and with which signs.
project_axis_angle:
    ld (paa_axis),a
    ld e,a
    ld d,0
    ld hl,xRotationLo
    add hl,de
    ld c,(hl)
    ld hl,xRotationHi
    add hl,de
    ld b,(hl)
    ld a,b
    and $C0
    ld (paa_quadrant),a
    sla c
    rl b
    sla c
    rl b                        ; B C = the angle within its quadrant
    ld (paa_angle),bc
    ld h,b
    ld l,c
    call sine16
    ld (paa_sine),hl
    ld hl,(paa_angle)
    ld a,h
    cpl
    ld h,a
    ld a,l
    cpl
    ld l,a
    call sine16
    ex de,hl                    ; D E = cosine
    ld hl,(paa_sine)            ; H L = sine
    ld a,(paa_quadrant)
    or a
    jr z,.first
    cp $80
    jr z,.third
    cp $40
    jr z,.second
    ; $C0: v2 = cosine, negative; v1 = sine, positive.
    set 0,e
    res 0,l
    ex de,hl
    jr .store
.second:
    ; $40: v2 = cosine, positive; v1 = sine, negative.
    res 0,e
    set 0,l
    ex de,hl
    jr .store
.third:
    ; $80: v2 = sine, v1 = cosine, both negative.
    set 0,l
    set 0,e
    jr .store
.first:
    ; 0: v2 = sine, v1 = cosine, both positive.
    res 0,l
    res 0,e
.store:
    ; H L = v2, to mx2 + axis; D E = v1, to mx1 + axis.
    push hl
    ld a,(paa_axis)
    ld c,a
    ld b,0
    ld ix,mx1Lo
    add ix,bc
    pop hl
    ld (ix + MX1),e
    ld (ix + MX1 + 16),d
    ld (ix + MX2),l
    ld (ix + MX2 + 16),h
    ret

paa_axis:       db 0
paa_quadrant:   db 0
paa_angle:      dw 0
paa_sine:       dw 0

; Build matrices 1 to 4 from mx1 ... mz2 (SetMatrices).
set_matrices:
    MV_DE MX1
    ld a,e
    xor 1
    ld e,a
    MV_BC MZ2
    call mul16_bit0
    M1_PUT 1                    ; -mx1 * mz2
    MV_DE MY1
    MV_BC MZ2
    call mul16_bit0
    M1_PUT 3                    ; my1 * mz2, finished below
    MV_DE MX2
    MV_BC MZ2
    call mul16_bit0
    M1_PUT 2                    ; mx2 * mz2, used below
    MV_DE MY2
    MV_BC MZ2
    call mul16_bit0
    M1_PUT 0                    ; my2 * mz2, used below
    MV_DE MY2
    MV_BC MX1
    call mul16_bit0
    M1_PUT 6                    ; mx1 * my2
    MV_DE MY1
    MV_BC MX1
    call mul16_bit0
    M1_PUT 8                    ; mx1 * my1
    MV_DE MZ1
    MV_BC MX1
    call mul16_bit0
    M1_PUT 4                    ; mx1 * mz1
    MV_DE MZ1
    MV_BC MX2
    ld a,c
    xor 1
    ld c,a
    call mul16_bit0
    ld (sm_m5),hl
    M1_PUT 5                    ; -mx2 * mz1

    ; Matrices 3 and 4 take their simple entries straight from the values.
    GET_HL mx1Lo + MZ1, mx1Hi + MZ1
    PUT_HL matrix3Lo + 0, matrix3Hi + 0
    PUT_HL matrix3Lo + 4, matrix3Hi + 4
    PUT_HL matrix4Lo + 0, matrix4Hi + 0
    GET_HL mx1Lo + MZ2, mx1Hi + MZ2
    PUT_HL matrix3Lo + 3, matrix3Hi + 3
    PUT_HL matrix4Lo + 3, matrix4Hi + 3
    ld a,l
    xor 1
    ld l,a
    PUT_HL matrix3Lo + 1, matrix3Hi + 1
    GET_HL mx1Lo + MX1, mx1Hi + MX1
    PUT_HL matrix4Lo + 8, matrix4Hi + 8
    GET_HL mx1Lo + MX2, mx1Hi + MX2
    PUT_HL matrix4Lo + 7, matrix4Hi + 7
    ; Matrix 4's m1, m2, m4 and m5 are matrix 1's as they stand now, before
    ; the yaw is folded in.
    M1_HL 5
    PUT_HL matrix4Lo + 5, matrix4Hi + 5
    M1_HL 4
    PUT_HL matrix4Lo + 4, matrix4Hi + 4
    M1_HL 2
    PUT_HL matrix4Lo + 2, matrix4Hi + 2
    M1_HL 1
    PUT_HL matrix4Lo + 1, matrix4Hi + 1

    ld de,(sm_m5)
    MV_BC MY2
    call mul16_bit0             ; -(mx2 * mz1) * my2
    M1_DE 3
    call add16_bit0
    M1_PUT 3                    ; -(mx2 * my2 * mz1) + (my1 * mz2)

    M1_DE 5
    MV_BC MY1
    call mul16_bit0             ; -(mx2 * mz1) * my1
    M1_DE 0
    ld a,e
    xor 1
    ld e,a
    call add16_bit0
    M1_PUT 5                    ; -(mx2 * my1 * mz1) - (my2 * mz2)

    MV_DE MZ1
    MV_BC MY1
    call mul16_bit0
    M1_PUT 0                    ; my1 * mz1
    M1_HL 2
    ld (sm_m2),hl               ; mx2 * mz2, kept in xTemp1 as the original does
    PUT_HL xTemp1Lo, xTemp1Hi
    MV_DE MZ1
    MV_BC MY2
    ld a,c
    xor 1
    ld c,a
    call mul16_bit0
    M1_PUT 2                    ; -my2 * mz1
    ld de,(sm_m2)
    MV_BC MY2
    call mul16_bit0
    M1_DE 0
    call add16_bit0
    M1_PUT 0                    ; (mx2 * my2 * mz2) + (my1 * mz1)
    MV_DE MY1
    ld bc,(sm_m2)
    call mul16_bit0
    M1_DE 2
    call add16_bit0
    M1_PUT 2                    ; (mx2 * my1 * mz2) - (my2 * mz1)
    GET_HL mx1Lo + MX2, mx1Hi + MX2
    M1_PUT 7

    ; Matrix 2 is matrix 1 transposed.
    ld de,0                     ; D = row, E = column
.transpose:
    ld a,d
    add a,a
    add a,d
    add a,e                     ; row * 3 + column
    ld c,a
    ld b,0
    ld hl,matrix1Lo
    add hl,bc
    ld a,(hl)
    ld hl,matrix1Hi
    add hl,bc
    ld b,(hl)
    ld c,a                      ; B C = m1(row, column)
    ld a,e
    add a,a
    add a,e
    add a,d                     ; column * 3 + row
    push de
    ld e,a
    ld d,0
    ld hl,matrix2Lo
    add hl,de
    ld (hl),c
    ld hl,matrix2Hi
    add hl,de
    ld (hl),b
    pop de
    inc e
    ld a,e
    cp 3
    jr c,.transpose
    ld e,0
    inc d
    ld a,d
    cp 3
    jr c,.transpose
    ret

sm_m5:      dw 0
sm_m2:      dw 0
