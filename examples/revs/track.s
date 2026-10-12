; Expands the track data file into every segment's coordinates.
;
; The BBC builds segments one at a time into a 40-entry wraparound buffer as
; the car moves (GetTrackSegment), because a 32K machine has no room for the
; whole track. The Spectrum does: 1024 segments of five 16-bit coordinates is
; 10K, built once here, so the per-frame code just indexes them.
;
; The rules are GetTrackSegment's and GetSectionCoords': a section's first
; segment takes both verges from the section's own coordinates; each later
; segment adds the current segment vector to the inner verge, and the outer
; verge is the inner one plus four times the outer vector. Curved sections
; step to their next vector after each segment, straights keep one vector.
; A straight shows black-and-white verges except on its segments 1 to 9.

; Offsets into the track data file (see track_data.py).
TRK_SECTION_DATA    equ $000    ; 8 bytes per section: part 1
TRK_SEG_XI          equ $100    ; the five 256-entry segment vector tables
TRK_SEG_YI          equ $200
TRK_SEG_ZI          equ $300
TRK_SEG_XO          equ $400
TRK_SEG_ZO          equ $500
TRK_SECTION_FLAG    equ $600    ; 8 bytes per section: part 2
TRK_SECTION_COUNT   equ $6FA    ; sections * 8

build_track:
    ld ix,track+TRK_SECTION_DATA
    ld iy,track+TRK_SECTION_FLAG
    ld hl,0
    ld (bt_out),hl              ; output offset: segment number * 2
    ld a,(track+TRK_SECTION_COUNT)
    rrca
    rrca
    rrca
    and $1F
    ld (bt_sections),a
.section:
    ; The section's starting coordinates: high bytes in part 1, low in part 2.
    ld a,(iy+1)
    ld (bt_xi),a
    ld a,(ix+1)
    ld (bt_xi+1),a
    ld a,(iy+2)
    ld (bt_yi),a
    ld a,(ix+2)
    ld (bt_yi+1),a
    ld a,(iy+3)
    ld (bt_zi),a
    ld a,(ix+3)
    ld (bt_zi+1),a
    ld a,(iy+4)
    ld (bt_xo),a
    ld a,(ix+4)
    ld (bt_xo+1),a
    ld a,(iy+6)
    ld (bt_zo),a
    ld a,(ix+6)
    ld (bt_zo+1),a
    ld a,(iy+5)                 ; trackSectionFrom: the first segment vector
    ld (bt_vector),a
    xor a
    ld (bt_k),a                 ; segment number within the section
.segment:
    ld a,(bt_k)
    or a
    jr z,.store                 ; the first segment is the section's own point
    ; inner += the inner segment vector
    ld a,(bt_vector)
    ld l,a
    ld h,high (track+TRK_SEG_XI)
    ld de,bt_xi
    call bt_add_s8
    ld h,high (track+TRK_SEG_YI)
    ld de,bt_yi
    call bt_add_s8
    ld h,high (track+TRK_SEG_ZI)
    ld de,bt_zi
    call bt_add_s8
    ; outer = inner + 4 * the outer segment vector
    ld h,high (track+TRK_SEG_XO)
    ld de,(bt_xi)
    call bt_add_4s8
    ld (bt_xo),de
    ld h,high (track+TRK_SEG_ZO)
    ld de,(bt_zi)
    call bt_add_4s8
    ld (bt_zo),de
    ld a,(iy+0)                 ; curved sections move on to the next vector
    rrca
    jr nc,.store
    ld hl,bt_vector
    inc (hl)
.store:
    ld de,(bt_out)
    ld hl,SEG_XI
    add hl,de
    ld bc,(bt_xi)
    ld (hl),c
    inc hl
    ld (hl),b
    ld hl,SEG_YI
    add hl,de
    ld bc,(bt_yi)
    ld (hl),c
    inc hl
    ld (hl),b
    ld hl,SEG_ZI
    add hl,de
    ld bc,(bt_zi)
    ld (hl),c
    inc hl
    ld (hl),b
    ld hl,SEG_XO
    add hl,de
    ld bc,(bt_xo)
    ld (hl),c
    inc hl
    ld (hl),b
    ld hl,SEG_ZO
    add hl,de
    ld bc,(bt_zo)
    ld (hl),c
    inc hl
    ld (hl),b
    ; Flags: a straight's verges are black-and-white except segments 1-9.
    ld a,(iy+0)
    bit 0,a
    jr nz,.flags
    ld c,a
    ld a,(bt_k)
    dec a
    cp 9
    ld a,c
    jr c,.flags
    and %11111001
.flags:
    srl d                       ; the flags are one byte per segment
    rr e
    ld hl,SEG_FLAGS
    add hl,de
    ld (hl),a
    ld hl,(bt_out)
    inc hl
    inc hl
    ld (bt_out),hl
    ld hl,bt_k
    inc (hl)
    ld a,(hl)
    cp (iy+7)                   ; trackSectionSize
    jp c,.segment
    ld de,8
    add ix,de
    add iy,de
    ld hl,bt_sections
    dec (hl)
    jp nz,.section
    ret

; The 16-bit value at (DE) += the signed byte at (HL). HL is kept (L is the
; vector number, H the table's page).
bt_add_s8:
    push hl
    ld c,(hl)
    ld a,c
    rlca
    sbc a,a
    ld b,a                      ; BC = the vector, sign extended
    ex de,hl
    ld e,(hl)
    inc hl
    ld d,(hl)                   ; DE = the value, HL = its high byte
    ex de,hl
    add hl,bc
    ex de,hl                    ; DE = the sum
    ld (hl),d
    dec hl
    ld (hl),e
    pop hl
    ret

; DE += 4 * the signed byte at (HL).
bt_add_4s8:
    ld a,(hl)
    push hl
    ld l,a
    rlca
    sbc a,a
    ld h,a
    add hl,hl
    add hl,hl
    add hl,de
    ex de,hl
    pop hl
    ret

bt_out:      dw 0
bt_sections: db 0
bt_k:        db 0
bt_vector:   db 0
bt_xi:       dw 0
bt_yi:       dw 0
bt_zi:       dw 0
bt_xo:       dw 0
bt_zo:       dw 0
