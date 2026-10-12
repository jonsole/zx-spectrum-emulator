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
    ld (hl),$38                 ; black ink on white paper
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

; Waits until the beam has fetched the view's top row, by reading the
; floating bus: on a 48K, reading a port the ULA doesn't answer gives
; whatever the ULA is fetching from the screen, or $FF while it fetches
; nothing (the border and the end of each line). Rows 0-15, above the view,
; hold nothing but zero bytes under SYNC_ATTR attributes, so anything else
; -- a view row's attributes or pattern bytes, or anything lower down -- is
; the beam at row 16 or below. Called after the frame interrupt's work,
; which must not run into the bottom border (57,000 T-states), or this
; waits for the next frame. The +2A and +3 have no floating bus.
SYNC_ATTR   equ $3A             ; red ink: there is none to see

wait_for_beam:
    in a,($FF)
    cp $FF
    jr z,wait_for_beam
    or a
    jr z,wait_for_beam
    cp SYNC_ATTR
    jr z,wait_for_beam
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
