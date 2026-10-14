; Points in 3D space, after model/points.py: rotating them by the matrices,
; adding vectors, and the copies between the point tables and the variable
; workspace.
;
; The point tables are a page each (xPointLo, xPointHi and so on), indexed by
; point ID, so H = the table's page and L = the point. Coordinates there are
; 16-bit two's complement. A sum that overflows 16 bits means the point is
; outside the world, and sets showLine to HIDDEN so its line isn't drawn.

HIDDEN equ $40

    ASSERT low xPointLo == 0 && low yPointLo == 0 && low zPointLo == 0
    ASSERT low xPointHi == 0 && low yPointHi == 0 && low zPointHi == 0
    ASSERT yTemp1Lo == xTemp1Lo + 1 && zTemp1Lo == xTemp1Lo + 2
    ASSERT xTemp1Hi == xTemp1Lo + 3

; D E = one coordinate of point L, from its two tables.
    MACRO POINT_DE lo_table, hi_table
    ld h,high lo_table
    ld e,(hl)
    ld h,high hi_table
    ld d,(hl)
    ENDM

    MACRO POINT_PUT_DE lo_table, hi_table
    ld h,high lo_table
    ld (hl),e
    ld h,high hi_table
    ld (hl),d
    ENDM

MATRIX_HI equ matrix1Hi - matrix1Lo ; from an entry's low byte to its high byte

; A coordinate of point L for set_point_coords: its magnitude to spc_mag +
; 2 k (-32768 stays $8000) and its high byte, for the sign in bit 7, to
; spc_sign + k. Uses A, DE.
    MACRO SPC_COORD lo_table, hi_table, k
    ld h,high lo_table
    ld e,(hl)
    ld h,high hi_table
    ld d,(hl)
    ld a,d
    ld (spc_sign + k),a
    or a
    jp p,.positive
    xor a
    sub e
    ld e,a
    sbc a,a
    sub d
    ld d,a
.positive:
    ld (spc_mag + 2 * k),de
    ENDM

; One term of a row's sum in set_point_coords: the coordinate in column
; times the row's entry there, as mul16_mix works it out -- the magnitude
; times the entry as it is, sign bit and all, by Multiply16x16 -- with the
; sign of the two together, added to spc_sum; an overflow hides the line.
; An entry whose high byte is 0 and low byte below 5 is taken as zero.
    MACRO SPC_TERM column
    ld c,(iy + column)          ; R
    ld a,(iy + column + MATRIX_HI)
    or a                        ; S
    jr nz,.multiply
    ld a,c
    cp 5
    jp c,.skip
    xor a
.multiply:
    ld (spc_s),a
    ld a,(spc_mag + 2 * column + 1)
    ld e,c
    MUL8                        ; J * R
    ld a,(mult1_round)
    add a,l
    ld l,a
    jr nc,.rounded
    inc h
.rounded:
    push hl
    ld a,(spc_s)
    ld e,a
    ld a,(spc_mag + 2 * column)
    MUL8                        ; S * I
    pop bc
    add hl,bc                   ; J * R + S * I + rounding, 17 bits
    ld c,h
    push af                     ; the top nine of them: the carry and C
    ld a,(spc_mag + 2 * column + 1)
    MUL8                        ; S * J
    pop af
    ld a,c
    jr nc,.no_carry
    inc h
.no_carry:
    add a,l
    ld l,a
    jr nc,.signed
    inc h
.signed:
    ld a,(iy + column)
    rrca                        ; the entry's sign, in bit 7...
    ld b,a
    ld a,(spc_sign + column)
    xor b                       ; ...against the coordinate's
    rla
    jr nc,.add
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
.add:
    ex de,hl
    ld hl,(spc_sum)
    or a
    adc hl,de
    jp po,.no_overflow
    ld a,HIDDEN
    ld (showLine),a
.no_overflow:
    ld (spc_sum),hl
.skip:
    ENDM

; Rotate point A by matrix C (0, 9, 18 or 27 for matrices 1 to 4), in place:
; each new coordinate is the dot product of a matrix row with the old
; (x, y, z). The result is also left in xTemp1 (and y, z), which other
; routines read (SetPointCoords).
;
; Each row is summed from the last column to the first, as the original
; does, since the order decides which addition, if any, is seen to
; overflow. Uses everything but IX.
set_point_coords:
    ld (spc_pid),a
    ld l,a
    SPC_COORD xPointLo, xPointHi, 0
    SPC_COORD yPointLo, yPointHi, 1
    SPC_COORD zPointLo, zPointHi, 2
    ld b,0
    ld iy,matrix1Lo
    add iy,bc                   ; IY -> the matrix's first row
    ld hl,xTemp1Lo
    ld (spc_dest),hl
.row:
    ld hl,0
    ld (spc_sum),hl
    SPC_TERM 2
    SPC_TERM 1
    SPC_TERM 0
    ; The row's sum is the new coordinate, to xTemp1 + row.
    ld de,(spc_sum)
    ld hl,(spc_dest)
    ld (hl),e
    inc hl
    inc hl
    inc hl
    ld (hl),d
    dec hl
    dec hl
    ld (spc_dest),hl
    inc iy
    inc iy
    inc iy
    ld a,l
    cp low (xTemp1Lo + 3)
    jp nz,.row
    ld a,(spc_pid)
    jp copy_temp_to_point

spc_pid:    db 0
spc_dest:   dw 0
spc_sum:    dw 0
spc_s:      db 0
spc_mag:    ds 6                ; each coordinate's magnitude, x, y, z
spc_sign:   ds 3                ; and its high byte

; Point A = (xTemp1, yTemp1, zTemp1) (CopyTempToPoint). Uses A, DE, HL.
copy_temp_to_point:
    ld l,a
    ld a,(xTemp1Lo)
    ld e,a
    ld a,(xTemp1Hi)
    ld d,a
    POINT_PUT_DE xPointLo, xPointHi
    ld a,(yTemp1Lo)
    ld e,a
    ld a,(yTemp1Hi)
    ld d,a
    POINT_PUT_DE yPointLo, yPointHi
    ld a,(zTemp1Lo)
    ld e,a
    ld a,(zTemp1Hi)
    ld d,a
    POINT_PUT_DE zPointLo, zPointHi
    ret

; One term of a row's sum in set_obj_point_coords: offset v times the
; matrix entry at offset entry from IY, with the entry's sign, added to IX.
; The offsets are positive, so the sign is the entry's.
    MACRO SOPC_TERM v, entry
    ld de,(v)                   ; E = V << 4, D = V
    ld a,d
    or a
    jr z,.skip                  ; a zero offset adds nothing
    ld c,(iy + entry)
    ld b,(iy + entry + MATRIX_HI)
    call sopc_product
    bit 0,(iy + entry)
    jr z,.add
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a                      ; HL = -HL
.add:
    ex de,hl
    add ix,de
.skip:
    ENDM

; A row of set_obj_point_coords: its sum, scaled, to xTemp1 + row.
    MACRO SOPC_ROW row
    ld ix,0
    SOPC_TERM sopc_vx, 3 * row
    SOPC_TERM sopc_vy, 3 * row + 1
    SOPC_TERM sopc_vz, 3 * row + 2
    push ix
    pop hl
    call sopc_shift
    ld a,l
    ld (xTemp1Lo + row),a
    ld a,h
    ld (xTemp1Hi + row),a
    ENDM

; Work out where point A of an object is (SetObjPointCoords): rotate its
; offset from the object's anchor (the xObjectPoint tables) by matrix C,
; scale it, and add the anchor, point objectAnchorPoint.
;
; The offsets are 4-bit and all positive, and the top nibble of the z offset
; is a scale, a power of two from 2^0 to 2^9. Each product with a matrix
; entry is V * entry / 256, or / 128 when the scale is 9 or more; each sum is
; then shifted left by the scale and its bottom byte dropped (or left as it
; is for a scale of 8 or more, the doubled products having seen to the rest).
set_obj_point_coords:
    ld (sopc_pid),a
    ld e,a
    ld d,0
    ld hl,xObjectPoint
    add hl,de
    ld a,(hl)
    and $0F
    ld (sopc_vx + 1),a
    add a,a
    add a,a
    add a,a
    add a,a
    ld (sopc_vx),a
    ld hl,yObjectPoint
    add hl,de
    ld a,(hl)
    and $0F
    ld (sopc_vy + 1),a
    add a,a
    add a,a
    add a,a
    add a,a
    ld (sopc_vy),a
    ld hl,zObjectPoint
    add hl,de
    ld a,(hl)
    ld b,a
    and $0F
    ld (sopc_vz + 1),a
    add a,a
    add a,a
    add a,a
    add a,a
    ld (sopc_vz),a
    ; The scale picks the multiply, patched into the jump at sopc_product,
    ; and the shift, patched into the one at sopc_shift.
    ld a,b
    rrca
    rrca
    rrca
    rrca
    and $0F
    ld hl,product_plain
    cp 9
    jr c,.multiply
    ld hl,product_doubled
.multiply:
    ld (sopc_product + 1),hl
    ld hl,sopc_done
    cp 8
    jr nc,.shift_set            ; 8 or more: as it is
    ld hl,sopc_high_byte
    or a
    jr z,.shift_set             ; 0: the high byte, sign-extended
    ; Shifting the 24-bit sum left by the scale and dropping its bottom byte
    ; is shifting it right by 8 - scale: into the chain of seven shifts at
    ; sopc_chain, (scale - 1) shifts in.
    dec a
    add a,a
    add a,a
    ld e,a                      ; (D is 0)
    ld hl,sopc_chain
    add hl,de
.shift_set:
    ld (sopc_shift + 1),hl
    ; IY -> the matrix; a row's sum is kept in IX.
    ld b,0
    ld iy,matrix1Lo
    add iy,bc
    SOPC_ROW 0
    SOPC_ROW 1
    SOPC_ROW 2
    ld a,(objectAnchorPoint)
    ld c,a
    ld a,(sopc_pid)
    jp add_temp_to_point

; The product for set_obj_point_coords's scale.
sopc_product:
    jp product_plain

; H L, a row's sum, scaled: patched to one of the three below.
sopc_shift:
    jp sopc_done
sopc_high_byte:
    ld l,h
    ld a,h
    rla
    sbc a,a
    ld h,a
    ret
sopc_chain:
    REPT 7
    sra h
    rr l
    ENDR
sopc_done:
    ret

sopc_pid:   db 0
sopc_vx:    dw 0                ; each offset as V << 4, then V
sopc_vy:    dw 0
sopc_vz:    dw 0

; Point A = (xTemp1, yTemp1, zTemp1) + point C (AddTempToPoint), hiding the
; line if any axis overflows. Uses A, BC, DE, HL.
add_temp_to_point:
    ld b,a                      ; the destination
    MACRO ATP_AXIS lo_table, hi_table, temp
    ld l,c
    POINT_DE lo_table, hi_table
    ld a,(temp)
    ld l,a
    ld a,(temp + 3)
    ld h,a
    or a
    adc hl,de
    jp po,.ok@
    ld a,HIDDEN
    ld (showLine),a
.ok@:
    ex de,hl
    ld l,b
    POINT_PUT_DE lo_table, hi_table
    ENDM
    ATP_AXIS xPointLo, xPointHi, xTemp1Lo
    ATP_AXIS yPointLo, yPointHi, yTemp1Lo
    ATP_AXIS zPointLo, zPointHi, zTemp1Lo
    ret

; The variable workspace keeps its 16-bit vectors with the low bytes from
; xTurnHi + offset and the high bytes from xTurnTop + offset, x, y and z one
; after another (the original passes the offset in X).

; Point A = the workspace vector at offset C (CopyWorkToPoint).
copy_work_to_point:
    ld b,a
    ld hl,xTurnHi
    ld e,c
    ld d,0
    add hl,de
    push hl
    pop ix                      ; IX = xTurnHi + offset
    ld l,b
    ld e,(ix + 0)
    ld d,(ix + xTurnTop - xTurnHi)
    POINT_PUT_DE xPointLo, xPointHi
    ld e,(ix + 1)
    ld d,(ix + xTurnTop - xTurnHi + 1)
    POINT_PUT_DE yPointLo, yPointHi
    ld e,(ix + 2)
    ld d,(ix + xTurnTop - xTurnHi + 2)
    POINT_PUT_DE zPointLo, zPointHi
    ret

; The workspace vector at offset C = point A (CopyPointToWork).
copy_point_to_work:
    ld b,a
    ld hl,xTurnHi
    ld e,c
    ld d,0
    add hl,de
    push hl
    pop ix
    ld l,b
    POINT_DE xPointLo, xPointHi
    ld (ix + 0),e
    ld (ix + xTurnTop - xTurnHi),d
    POINT_DE yPointLo, yPointHi
    ld (ix + 1),e
    ld (ix + xTurnTop - xTurnHi + 1),d
    POINT_DE zPointLo, zPointHi
    ld (ix + 2),e
    ld (ix + xTurnTop - xTurnHi + 2),d
    ret

; Every byte of point L's coordinates = A (SetPoint; 0 is SetPointToOrigin).
set_point_to:
    ld h,high xPointLo
    ld (hl),a
    ld h,high xPointHi
    ld (hl),a
    ld h,high yPointLo
    ld (hl),a
    ld h,high yPointHi
    ld (hl),a
    ld h,high zPointLo
    ld (hl),a
    ld h,high zPointHi
    ld (hl),a
    ret

; Move object C by the vector in point A (AddPointToObject).
add_point_to_object:
    ld l,a
    ld b,0
    MACRO APO_AXIS lo_table, hi_table, obj_lo, obj_hi
    POINT_DE lo_table, hi_table
    push hl
    ld hl,obj_hi
    add hl,bc
    push hl                     ; (found first: ADD HL would lose the carry)
    ld hl,obj_lo
    add hl,bc
    ld a,(hl)
    add a,e
    ld (hl),a
    pop hl
    ld a,(hl)
    adc a,d
    ld (hl),a
    pop hl
    ENDM
    APO_AXIS xPointLo, xPointHi, xObjectLo, xObjectHi
    APO_AXIS yPointLo, yPointHi, yObjectLo, yObjectHi
    APO_AXIS zPointLo, zPointHi, zObjectLo, zObjectHi
    ret

; Object C to (0, 0, 0) (SetObjectToOrigin).
set_object_to_origin:
    ld b,0
    xor a
    ld hl,xObjectLo
    add hl,bc
    ld (hl),a
    ld hl,xObjectHi
    add hl,bc
    ld (hl),a
    ld hl,yObjectLo
    add hl,bc
    ld (hl),a
    ld hl,yObjectHi
    add hl,bc
    ld (hl),a
    ld hl,zObjectLo
    add hl,bc
    ld (hl),a
    ld hl,zObjectHi
    add hl,bc
    ld (hl),a
    ret
