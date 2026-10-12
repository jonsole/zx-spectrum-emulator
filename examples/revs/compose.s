; Composes the view straight onto the screen from the edge markers, a track
; line at a time: sort the line's markers by x, then fill left to right,
; each span in the pattern the marker at its left end set. This is the
; BBC's trick of filling as it copies (DrawTrackBytes), except that the
; Spectrum has no buffer to copy: the fill is the only write.
;
; It runs from the top line (79) down, starting once the beam has drawn the
; view's top row, and it is slower than the beam (224 T-states a row), so it
; never catches it up: every row is rewritten after the beam has shown it
; and long before it comes round again, and no frame shows two views.
;
; A span is whole bytes, written by jumping into an unrolled run of stores,
; up to and including the byte the next marker falls in; then that byte gets
; the next pattern from the marker's pixel rightwards. Several markers can
; share a byte, and each just mixes the byte again.
;
; In the line loop: BC = the next marker (records are 32-byte aligned, so
; only C moves), DE = the next byte of the screen row (rows are too),
; H = the page of tbl_mask, IXL = the current pattern, IY = where to jump
; into the run of stores. Odd lines' patterns are rotated right two places
; (patterns.s), so there is a copy of the line code for each.

compose_screen:
    ld a,high fill_runs
    ld iyh,a
    ; Unrolled, so each line's record and screen row are constants.
.y = VIEW_LINES - 1
    DUP VIEW_LINES
    ld hl,MARKERS + .y * MARK_LINE
.r = VIEW_TOP + VIEW_LINES - 1 - .y
    ld de,$4000 | ((.r & $C0) << 5) | ((.r & 7) << 8) | ((.r & $38) << 2)
    ld bc,cs_last + .y
    IF .y & 1
    call cs_line_odd
    ELSE
    call cs_line_even
    ENDIF
.y = .y - 1
    EDUP
    ret

; One line, from the record at HL to the screen row at DE. BC is the
; line's byte in cs_last: the pattern it was filled with if it had no
; markers last time, so a line that is still empty and still the same
; (most of the sky, often the grass) is left alone; NOT_EMPTY otherwise.
    MACRO CS_LINE ROT, NAME, RUNMIX
    ld a,e
    inc a
    ld (.row_plus_1+1),a
    add a,31
    ld (.row_end+1),a
    ld a,(hl)
    cp 4
    jp z,.empty
    ld a,NOT_EMPTY
    ld (bc),a
    ld a,(hl)
    add a,l
    ld (.end+1),a               ; just past the last marker
.restart:
    inc l
    ld a,(hl)                   ; the pattern the line starts with
    IF ROT
    rrca
    rrca
    ENDIF
    ld ixl,a
    inc l
    inc l
    inc l
    ld b,h
    ld c,l
    ld hl,tbl_mask              ; L: the last marker's x
.marker:
    ld a,c
.end:
    cp 0                        ; patched
    jr z,.last
    ld a,(bc)                   ; x
    cp l
    jr c,.unsorted
    inc c
    ld l,a
    rrca
    rrca
    rrca
    and 31
    sub e
.row_plus_1:
    add a,0                     ; patched: bytes up to and including x's
    jr z,NAME_mix               ; none: an earlier marker shares the byte
    add a,a
    neg
    add a,low RUNMIX
    ld iyl,a
    ld a,ixl
    jp (iy)
NAME_mix:
    dec e                       ; back onto x's byte
    ld a,(bc)                   ; the pattern from x rightwards
    inc c
    IF ROT
    rrca
    rrca
    ENDIF
    ld ixl,a
    ld a,(de)                   ; byte = old ^ ((old ^ new) & mask)
    xor ixl
    and (hl)
    ex de,hl
    xor (hl)
    ld (hl),a
    ex de,hl
    inc e
    jr .marker
.unsorted:
    ; Out of order, which only edges crossing each other do: sort the
    ; line's markers and start it again.
    ld h,b
    ld a,c
    and $E0
    ld l,a
    push de
    push hl
    call sort_line
    pop hl
    pop de
    ld a,(.row_plus_1+1)
    dec a
    ld e,a                      ; back to the row's start
    jr .restart
.empty:
    ; No markers: one pattern across the row, mostly pushed. An interrupt
    ; pushes four bytes below SP, so the pushes stop four bytes short of the
    ; row's start, where that could reach into another screen row; those
    ; four are stored.
    inc l
    ld a,(bc)
    cp (hl)
    ret z                       ; the same as last time
    ld a,(hl)
    ld (bc),a
    IF ROT
    rrca
    rrca
    ENDIF
    ld h,a
    ld l,a
    ex de,hl                    ; DE = the pattern twice, HL = the row
    ld (hl),e
    inc l
    ld (hl),e
    inc l
    ld (hl),e
    inc l
    ld (hl),e
    ld bc,32-3
    add hl,bc
    ld (.sp+1),sp
    ld sp,hl
    REPT 14
    push de
    ENDR
.sp:
    ld sp,0                     ; patched
    ret
.last:
.row_end:
    ld a,0                      ; patched: just past the row
    sub e
    ret z
    add a,a
    neg
    add a,low fill_runs_last
    ld iyl,a
    ld a,ixl
    jp (iy)                     ; which returns
    ENDM

cs_line_odd:
    CS_LINE 1, cs_odd, fill_odd_end
cs_line_even:
    CS_LINE 0, cs_even, fill_even_end

; Sorts the markers of the record at HL by x: an insertion sort, which
; keeps markers at the same x in the order they were made. Records are
; 32-byte aligned, so only L moves. Uses A, BC, DE.
sort_line:
    ld a,(hl)
    cp 4+2*2
    ret c                       ; fewer than two
    add a,l
    ld (.end+1),a
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

NOT_EMPTY   equ 1               ; not a pattern (patterns.s)

; What each line held last time (see CS_LINE), line 0 first.
cs_last:
    ds VIEW_LINES, NOT_EMPTY

; The runs of stores, all in one page so IYH stays put: A into the next n
; bytes from DE, entered n stores from the end. Each run goes back to where
; its caller continues.
    MACRO FILL_RUN CONTINUE
    REPT 32
    ld (de),a
    inc e
    ENDR
    jp CONTINUE
    ENDM

    ALIGN 256
fill_runs:
    FILL_RUN cs_odd_mix
fill_odd_end equ $ - 3
    FILL_RUN cs_even_mix
fill_even_end equ $ - 3
    REPT 32
    ld (de),a
    inc e
    ENDR
fill_runs_last:
    ret
    ASSERT high fill_runs_last == high fill_runs

