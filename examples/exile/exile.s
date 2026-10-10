; An Exile-like for the 48K Spectrum: the first prototype.
;
; A planet of caves built from hand-placed blocks (map.s, from map.txt and
; blocks.png), drawn in one colour (render.s), and a jetpacked astronaut with
; momentum, gravity and pixel-exact collisions against the rock (player.s),
; drawn in his own colour.
; The view jumps to recentre him when he nears its edge, the way Exile's did.
;
; Keys: Q thrust, A push down, O left, P right.
;
; Memory, from 0x8000 (uncontended, though this emulator does not model
; contention yet):
;   code, then the variables
;   data.s's tables, aligned to the pages the code indexes them by
;   MAP_ADDR   the planet, 16K
;   0xFDFD     the interrupt's JP, with the stack below it
;   0xFE00     IM 2's vector table: 257 bytes of 0xFD
;
; The program never calls the ROM; the HUD borrows the ROM's character set
; and is blank without one.

    DEVICE ZXSPECTRUM48

LAND_ATTR   equ 0x05        ; cyan on black: all the landscape
PLAYER_ATTR equ 0x46        ; bright yellow: the cells the astronaut is in
HUD_ATTR    equ 0x0F        ; white on blue

VIEW_W      equ 32          ; the view, in character cells
VIEW_H      equ 20

MAP_ADDR    equ 0xB800      ; map.txt, 16K: up to 0xF7FF, then the stack

IM2_TABLE   equ 0xFE00
IM2_JUMP    equ 0xFDFD

    ORG 0x8000

start:
    di
    ld sp,IM2_JUMP
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
    call centre_camera
    call render_view
    ei

main_loop:
    halt
    ; Draw first, while the beam is still in the top border.
    call restore_player
    call draw_player
    call read_keys
    call physics
    call follow_camera
    call hud_update
    ; How many frames this pass took: 1 is 50 a second.
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

cam_x:          dw 0        ; the view's top-left, in character cells of the planet
cam_y:          dw 0
row_cy:         db 0        ; render_view's row

    INCLUDE "output/data.s"

code_end:
    ASSERT code_end <= MAP_ADDR, "program runs into the map"

    ORG MAP_ADDR
map_data:
    INCBIN "output/map.bin"
map_end:
    ASSERT map_end <= IM2_JUMP - 0x400, "the map leaves the stack too little room"

    SAVESNA "output/exile.sna", start
