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

; Waits, after a HALT and the camera's update, until the beam has drawn the
; view's top row and a couple more, so compose_screen can follow it down:
; 64 lines of top border and VIEW_TOP rows at 224 T-states each, less what
; the interrupt and the HALT took, less the camera's update. That takes
; 4,485 to 4,763 T-states (measured over 300 random places on the track),
; so the shortest is taken off: compose can start late, never early.
BEAM_WAIT   equ (64 + VIEW_TOP + 2) * 224 - 200
CAMERA_MIN  equ 4485

wait_for_beam:
    ld bc,(BEAM_WAIT - CAMERA_MIN) / 26
.wait:
    dec bc                      ; 26 T-states a turn
    ld a,b
    or c
    jr nz,.wait
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
