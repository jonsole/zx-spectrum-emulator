; An Exile-like for the 48K Spectrum: the first prototype.
;
; A planet of caves built from hand-placed blocks (map.s, from map.txt and
; blocks.png), drawn in one colour and scrolled smoothly with him in the
; middle (render.s), and a jetpacked astronaut with momentum, gravity and
; pixel-exact collisions against the rock (player.s), drawn in his own colour.
; It runs at 25 frames a second: the whole view is copied to the screen every
; other frame, and the physics runs twice for each, so he moves as he would at
; 50.
;
; Keys: Q thrust, A push down, O left, P right.
;
; Memory. What is read hardest -- the view's buffer, the code, the blocks --
; is above 0x8000, out of the memory the ULA contends for; the stack and half
; the map, read a few bytes at a time, are below it. (This emulator does not
; model contention yet, so its timings are a real machine's best case.)
;   0x5B00     the stack, down from STACK_TOP
;   MAP_ADDR   the planet, 16K
;   BUF        the view's buffer, 8K (render.s)
;   CODE_ADDR  code, variables, then data.s's tables, aligned to the pages the
;              code indexes them by
;   0xFDFD     the interrupt's JP
;   0xFE00     IM 2's vector table: 257 bytes of 0xFD
;
; The program never calls the ROM; the HUD borrows the ROM's character set
; and is blank without one.

    DEVICE ZXSPECTRUM48

LAND_ATTR   equ 0x05        ; cyan on black: all the landscape
PLAYER_ATTR equ 0x46        ; bright yellow: the cells the astronaut is in
HUD_ATTR    equ 0x0F        ; white on blue

VIEW_W      equ 32          ; the view, in character cells
VIEW_H      equ 16          ; a 160-line view's copy leaves too little of a pass

STACK_TOP   equ 0x6000
MAP_ADDR    equ 0x6000      ; map.txt, 16K: up to 0x9FFF
CODE_ADDR   equ 0xC000      ; after the view's buffer

IM2_TABLE   equ 0xFE00
IM2_JUMP    equ 0xFDFD

    ORG CODE_ADDR

start:
    di
    ld sp,STACK_TOP
    ; IM 2 with every vector pointing at 0xFDFD, whatever the data bus holds.
    ld hl,IM2_TABLE
    ld de,IM2_TABLE + 1
    ld bc,256
    ld (hl),high IM2_JUMP
    ldir
    ld a,0xC3               ; JP isr
    ld (IM2_JUMP),a
    ld hl,isr
    ld (IM2_JUMP + 1),hl
    ld a,high IM2_TABLE
    ld i,a
    im 2

    xor a
    out (0xFE),a
    ld hl,0x4000
    ld de,0x4001
    ld bc,0x1800 - 1
    ld (hl),a
    ldir

    call hud_init
    call player_init
    call build_view
    ei

; A pass is two frames. Up to the copy, nothing may touch the view's pixels
; -- the beam is still showing the last pass's picture -- and the copy waits
; for the beam to reach the top of the view anyway (wait_paper), so what
; happens before it is free: the sprite into the buffer, and the panel. The
; rest has the time from the copy's end to the next pass, and the view is
; scrolled for the next pass at the end of this one.
main_loop:
    halt
    call sprite_to_buffer
    call hud_update         ; the panel is below the copy, and this time is free
    call wait_paper
    call blit_view          ; into the next frame: interrupts off throughout
.copied:
    call player_attrs       ; before the beam reaches him: colour and pixels together
    call sprite_from_buffer
    call read_keys
    call physics            ; two frames' worth
    call physics
    call camera_target
    call scroll_view
    ; How many frames this pass took: 2 is 25 a second.
    ld hl,(frames)
    ld de,(last_frames)
    ld (last_frames),hl
    or a
    sbc hl,de
    ld a,l
    ld (loop_frames),a
    jr main_loop

isr:
    push af
    push hl
    ld hl,(frames)
    inc hl
    ld (frames),hl
    pop hl
    pop af
    ei
    reti

    INCLUDE "map.s"
    INCLUDE "render.s"
    INCLUDE "player.s"
    INCLUDE "hud.s"

; ---- variables ---------------------------------------------------------------

frames:         dw 0        ; interrupts since the start
last_frames:    dw 0
loop_frames:    db 0        ; frames the last pass of main_loop took

cam_x:          db 0        ; the view's left edge, in characters of the planet
cam_y:          dw 0        ; its top line, in pixels
cam_tx:         db 0        ; where camera_target wants them
cam_ty:         dw 0

    INCLUDE "output/blit.s"

    INCLUDE "output/data.s"

code_end:
    ASSERT code_end <= IM2_JUMP, "the program runs into the interrupt's jump"

    ORG MAP_ADDR
map_data:
    INCBIN "output/map.bin"
map_end:
    ASSERT map_end <= BUF, "the map runs into the view's buffer"
    ASSERT BUF_END <= CODE_ADDR, "the view's buffer runs into the code"

    SAVESNA "output/exile.sna", start
