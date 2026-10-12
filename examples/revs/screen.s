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

; Copies the view buffer to the screen, straight after a HALT: unrolled,
; sixteen bytes at a time through the registers and the stack pointer, about
; 410 T-states a row. That outruns the beam, which spends 224 T-states on a
; row but starts this one VIEW_TOP rows and the top border later, so every
; row is written before the beam reaches it and no frame shows parts of two
; views. (An LDI copy, at 16 T-states a byte, could not stay ahead.)
;
; It runs with interrupts off, as the stack pointer is busy, which costs
; nothing: the next interrupt is a whole frame away.
view_copy:
    di
    ld (.sp+1),sp
.row = 0
    DUP VIEW_LINES
.scr = $4000 | (((VIEW_TOP + .row) & $C0) << 5) | (((VIEW_TOP + .row) & 7) << 8) | (((VIEW_TOP + .row) & $38) << 2)
.half = 0
    DUP 2
    ld sp,VIEWBUF + .row * 32 + .half
    pop af
    pop bc
    pop de
    pop hl
    exx
    ex af,af'
    pop af
    pop bc
    pop de
    pop hl
    ld sp,.scr + .half + 16
    push hl
    push de
    push bc
    push af
    exx
    ex af,af'
    push hl
    push de
    push bc
    push af
.half = .half + 16
    EDUP
.row = .row + 1
    EDUP
.sp:
    ld sp,0                     ; patched
    ei
    ret

; Shows how many frames the last update took, top left, from the ROM font.
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
    ld de,$4000
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
