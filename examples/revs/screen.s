; The screen, the frame interrupt and the frame-rate counter.

screen_init:
    ld a,7
    out ($FE),a
    ld hl,$4000
    ld de,$4001
    ld bc,6144-1
    ld (hl),0
    ldir
    ld hl,$5800
    ld de,$5801
    ld bc,768-1
    ld (hl),VIEW_ATTR
    ldir
    ld hl,$5800                 ; above the view: see wait_for_beam
    ld de,$5801
    ld bc,64-1
    ld (hl),SYNC_ATTR
    ldir
    ret

; IM 2 through a 257-byte table of $FD at $FE00, so whatever the bus holds
; the vector is $FDFD, which jumps to the handler.
im2_init:
    ld hl,$FE00
    ld de,$FE01
    ld bc,256
    ld (hl),$FD
    ldir
    ld a,$C3
    ld ($FDFD),a
    ld hl,im2_handler
    ld ($FDFE),hl
    ld a,$FE
    ld i,a
    im 2
    ret

im2_handler:
    push af
    ld a,(frames)
    inc a
    ld (frames),a
    pop af
    ei
    reti

; Waits until the beam has fetched the first row compose will draw: BC is
; where compose_from starts, from compose_skip. It reads the floating bus:
; on a 48K, reading a port the ULA doesn't answer gives whatever the ULA is
; fetching from the screen, or $FF while it fetches nothing (the border and
; the end of each line). The +2A and +3 have no floating bus.
;
; First the view's top row. Rows 0-15, above the view, hold nothing but zero
; bytes under SYNC_ATTR attributes, so anything else -- a view row's
; attributes or pattern bytes, or anything lower down -- is the beam at row
; 16 or below. This is called after the frame interrupt's work, which must
; not run into the bottom border (57,000 T-states), or it waits for the next
; frame.
;
; Then, if compose_skip left the sky alone, the first row below it. Those
; rows are blank -- zero bytes under VIEW_ATTR -- so a byte that is neither
; is the beam on a row with something drawn on it, at or below the first
; one compose will draw. But nothing need be drawn there yet (on the first
; update the whole screen is blank), and a row of solid black reads as $FF
; like no row at all, so this gives up after the time the beam takes to
; cross as many rows as compose_skip can skip: by then it is past them
; whatever they hold.
SYNC_ATTR   equ $3A             ; red ink: there is none to see
VIEW_ATTR   equ $38             ; black ink on white paper
SKY_TRY_T   equ 43              ; the quickest time round .sky
SKY_TRIES   equ ((VIEW_LINES - HORIZON) * 224 + SKY_TRY_T - 1) / SKY_TRY_T
    ASSERT SKY_TRIES < 256

wait_for_beam:
    in a,($FF)
    cp $FF
    jr z,wait_for_beam
    or a
    jr z,wait_for_beam
    cp SYNC_ATTR
    jr z,wait_for_beam
    ; Each line skipped adds CS_CALL to BC, and twenty of them can't take
    ; its low byte back round to compose_lines', so that alone says none were.
    ld a,c
    cp low compose_lines
    ret z
    ld e,SKY_TRIES
.sky:
    in a,($FF)
    or a
    jr z,.blank
    cp $FF
    jr z,.blank
    cp VIEW_ATTR
    ret nz
.blank:
    dec e
    jr nz,.sky
    ret

; Shows how many frames the last update took, bottom left, from the ROM font
; (the top rows must stay empty for wait_for_beam).
fps_show:
    ld a,(fps_last)
    ld c,a
    ld a,(frames)
    ld (fps_last),a
    sub c
    cp 10
    jr c,.digit
    ld a,9
.digit:
    add a,a
    add a,a
    add a,a
    ld l,a
    ld h,0
    ld de,$3D00+('0'-' ')*8
    add hl,de
    ld de,$50E0                 ; row 184, the bottom character row
    ld b,8
.copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc d
    djnz .copy
    ret

frames:     db 0
fps_last:   db 0
