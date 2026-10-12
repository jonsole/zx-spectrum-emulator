; Fills the view buffer from the edge markers, a track line at a time: sort
; the line's markers by x, then fill left to right, each span in the pattern
; the marker at its left end set. Track line 0 is the bottom of the view, so
; it is buffer row 79.
;
; A span is whole bytes, written by jumping into an unrolled run of stores,
; up to and including the byte the next marker falls in; then that byte gets
; the next pattern from the marker's pixel rightwards. Several markers can
; share a byte, and each just mixes the byte again.
;
; Even lines are composed first, then odd ones, whose patterns are rotated
; right two places (see patterns.s).
;
; In the line loop: BC = the next marker, DE = the next byte of the row,
; IXL = the current pattern, IXH = the low byte of the row's start (rows are
; 32-byte aligned, so the byte's index is E minus that).

compose_view:
    ld a,high fill_end
    ld iyh,a                    ; fill_bytes jumps into the page at IY
    ld hl,0                     ; NOP, NOP: even lines' patterns as they are
    ld de,MARKERS
    ld bc,VIEWBUF+(VIEW_LINES-1)*32
    call .pass
    ld hl,$0F0F                 ; RRCA, RRCA: odd lines' rotated
    ld de,MARKERS+MARK_LINE
    ld bc,VIEWBUF+(VIEW_LINES-2)*32
    ; Every other line, so the rotation is patched in once a pass.
.pass:
    ld (.rotate1),hl
    ld (.rotate2),hl
    ld (.rotate3),hl
    ld (cv_rec),de
    ld (cv_row),bc
    ld a,VIEW_LINES/2
    ld (cv_lines),a
.line:
    ld hl,(cv_rec)
    ld a,(hl)
    cp 4
    jp z,.empty
    call sort_line
    ld hl,(cv_rec)
    ld a,(hl)
    add a,l
    ld (.end+1),a               ; just past the last marker
    inc l
    ld a,(hl)
.rotate1:
    nop                         ; patched
    nop
    ld ixl,a                    ; the pattern the line starts with
    inc l
    inc l
    inc l
    ld b,h
    ld c,l
    ld de,(cv_row)
    ld a,e
    ld ixh,a
.marker:
    ld a,c
.end:
    cp 0                        ; patched
    jr z,.last
    ld a,(bc)
    inc c
    ld l,a                      ; the marker's x
    rrca
    rrca
    rrca
    and 31
    ld h,a                      ; its byte
    ld a,ixh
    sub e
    add a,h
    inc a                       ; bytes up to and including it
    call nz,fill_bytes          ; none if an earlier marker shares it
    dec e
    ld a,l
    and 7
    or low lmask
    ld l,a
    ld h,high lmask
    ld a,(bc)                   ; the new pattern
.rotate2:
    nop                         ; patched
    nop
    inc c
    ld ixl,a
    ex de,hl                    ; byte = old ^ ((old ^ new) & mask)
    xor (hl)
    ex de,hl
    and (hl)
    ex de,hl
    xor (hl)
    ld (hl),a
    ex de,hl
    inc e
    jr .marker
.last:
    ld a,ixh
    sub e
    add a,32                    ; the rest of the row
    call nz,fill_bytes
.next:
    ld hl,(cv_rec)
    ld de,2*MARK_LINE
    add hl,de
    ld (cv_rec),hl
    ld hl,(cv_row)
    ld de,-2*32
    add hl,de
    ld (cv_row),hl
    ld hl,cv_lines
    dec (hl)
    jp nz,.line
    ret
.empty:
    ; No markers: one pattern across the row, mostly pushed. An interrupt
    ; pushes four bytes below SP, so the pushes stop four bytes short of the
    ; row's start, where they could reach the row above, already composed
    ; if this is the second pass; those four are stored.
    inc l
    ld a,(hl)
.rotate3:
    nop                         ; patched
    nop
    ld d,a
    ld e,a
    ld hl,(cv_row)
    ld bc,32
    add hl,bc
    ld (.sp+1),sp
    ld sp,hl
    REPT 14
    push de
    ENDR
.sp:
    ld sp,0                     ; patched
    ld hl,(cv_row)
    ld (hl),e
    inc l
    ld (hl),e
    inc l
    ld (hl),e
    inc l
    ld (hl),e
    jr .next

; Sorts the markers of the record at HL by x: an insertion sort, which
; keeps markers at the same x in the order they were made, and which is
; quick here because the edges are drawn left to right and mostly arrive
; in order. Records are 32-byte aligned, so only L moves.
sort_line:
    ld a,(hl)
    cp 4+2*2
    ret c                       ; fewer than two
    add a,l
    ld (.end+1),a
    ; Usually they are in order already, which is quick to see.
    ld b,a
    ld a,l
    add a,4
    ld l,a
    ld a,(hl)
.check:
    inc l
    inc l
    ld c,a
    ld a,l
    cp b
    ret z                       ; all in order
    ld a,c
    cp (hl)
    ld a,(hl)
    jr c,.check
    jr z,.check
    ld a,l                      ; out of order: back to the record's start
    and $E0
    ld l,a
    ld a,l
    add a,4
    ld b,a                      ; the front
    add a,2
    ld c,a                      ; the next to insert
.outer:
    ld a,c
.end:
    cp 0                        ; patched
    ret z
    ld l,c
    ld d,(hl)                   ; its x
    inc l
    ld e,(hl)                   ; and pattern
    dec l
.inner:
    ld a,l
    cp b
    jr z,.insert
    dec l
    dec l
    ld a,(hl)
    cp d
    jr c,.after
    jr z,.after
    inc l                       ; move it up a place
    inc l
    ld (hl),a
    dec l
    ld a,(hl)
    inc l
    inc l
    ld (hl),a
    dec l
    dec l
    dec l
    jr .inner
.after:
    inc l
    inc l
.insert:
    ld (hl),d
    inc l
    ld (hl),e
    inc c
    inc c
    jr .outer

; Stores IXL into A (1..32) bytes from DE onwards, advancing E. IY is
; free: only build_track uses it, at startup.
fill_bytes:
    add a,a
    neg
    add a,low fill_end
    ld iyl,a                    ; IYH is set up by compose_view
    ld a,ixl
    jp (iy)

    ALIGN 256
fill_run:
    REPT 32
    ld (de),a
    inc e
    ENDR
fill_end:
    ASSERT low fill_end == 64   ; so fill_bytes needs no borrow
    ret

; The bits of a byte from pixel k rightwards.
    ALIGN 8
lmask:  db $FF,$7F,$3F,$1F,$0F,$07,$03,$01

cv_rec:     dw 0
cv_row:     dw 0
cv_lines:   db 0
