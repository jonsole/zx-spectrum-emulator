; An Exile-like for the 48K Spectrum: the first prototype.
;
; A planet of caves built from hand-placed blocks (map.s, from map.txt and
; blocks.png), drawn in one colour and scrolled smoothly with him in the
; middle -- four pixels at a time across, one down (render.s) -- and a jetpacked astronaut with momentum, gravity and
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
;   0x5B00     the stack, down from STACK_TOP (sjasmplus starts it at 0x5D58)
;   MAP_ADDR   the planet, 16K
;   BUF0       the view's two buffers, 6K each (render.s)
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

STACK_TOP   equ 0x5E00
MAP_ADDR    equ 0x5E00      ; map.txt, 16K: up to 0x9DFF
CODE_ADDR   equ 0xCE00      ; after the view's buffers

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
; -- the beam is still showing the last pass's picture. The copy may start
; any time from the beam reaching the top of the view (wait_paper) to about
; 44,000 T-states into the frame -- later, and the beam would catch it up on
; the next -- so the sprite, the panel and his physics all go before it,
; where the time would otherwise be spent waiting. What changes the buffers
; or the colours goes after: the view is scrolled for the next pass at the
; end of this one.
main_loop:
    halt
    call sprite_to_buffer   ; where he was: the physics moves him for next pass
    call hud_update
    call read_keys
    call physics            ; two frames' worth
    call physics
    call wait_paper
    call blit_view          ; into the next frame: interrupts off throughout
.copied:
    call player_attrs       ; before the beam reaches him: colour and pixels together
    call sprite_from_buffer
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

cam_h:          dw 0        ; the view's left edge, in fours of pixels
cam_y:          dw 0        ; its top line, in pixels
cam_th:         dw 0        ; where camera_target wants them
cam_ty:         dw 0
cam_s0:         db 0        ; the planet column each buffer's window starts at
cam_s4:         db 0

    INCLUDE "output/blit.s"

    INCLUDE "output/data.s"

code_end:
    ASSERT code_end <= IM2_JUMP, "the program runs into the interrupt's jump"

    ORG MAP_ADDR
map_data:
    INCBIN "output/map.bin"
map_end:
    ASSERT map_end <= BUF0, "the map runs into the view's buffers"
    ASSERT BUF_END <= CODE_ADDR, "the view's buffers run into the code"

    SAVESNA "output/exile.sna", start
