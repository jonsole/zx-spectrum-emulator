; An Exile-like for the 48K Spectrum: the first prototype.
;
; A planet of caves worked out as you fly through it (world.s), drawn in one
; colour (render.s), and a jetpacked astronaut with momentum, gravity and
; pixel-exact collisions against the rock (player.s), drawn in his own colour.
; The view jumps to recentre him when he nears its edge, the way Exile's did.
;
; Keys: Q thrust, A push down, O left, P right.
;
; Memory, from 0x8000 (uncontended, though this emulator does not model
; contention yet):
;   code, then the variables
;   data.s's tables, aligned to the pages the code indexes them by
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

; The view's corner and shape windows: the tiles under the view, plus one
; across in case the view starts half way through a tile (it moves in
; character steps, a tile is two), and the corners round those.
WIN_TILES_W equ 17
WIN_TILES_H equ 11
WIN_CORN_W  equ WIN_TILES_W + 1
WIN_CORN_H  equ WIN_TILES_H + 1
SHAPE_STRIDE equ 32         ; a shape window row, padded for a cheap multiply

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

    INCLUDE "world.s"
    INCLUDE "render.s"
    INCLUDE "player.s"
    INCLUDE "hud.s"

; ---- variables ---------------------------------------------------------------

frames:         dw 0        ; interrupts since the start
last_frames:    dw 0
loop_frames:    db 0        ; frames the last pass of main_loop took

cam_x:          dw 0        ; the view's top-left, in character cells of the planet
cam_y:          dw 0
win_tx:         db 0        ; the windows' top-left tile
win_ty:         db 0
row_cy:         db 0        ; render_view's row
rows_left:      db 0        ; build_window's rows still to do
row_perm:       db 0        ; build_window: this row's place in the down-nudge
row_region:     dw 0        ; build_window: this row's start in world_map

; build_window, per column: the across-nudge's place in the wave, then (at
; COL_REGION on) the column's region. Aligned so the end test is on one byte.
COL_REGION      equ 32
    ALIGN 64
col_perm:       ds 64

corner_win:     ds WIN_CORN_W * WIN_CORN_H
shape_win:      ds SHAPE_STRIDE * WIN_TILES_H

    INCLUDE "output/data.s"

code_end:
    ASSERT code_end <= IM2_JUMP - 0x100, "program runs into the stack"

    SAVESNA "output/exile.sna", start
