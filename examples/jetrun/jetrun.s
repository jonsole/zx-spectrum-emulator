; Jetrun: stage 1 -- the landscape engine and the astronaut.
;
; A jetpack astronaut on a cavern planet whose landscape is drawn by
; Ultimate's own Cyberun renderer, its source taken from the Cyberun
; disassembly (cyberun.s, ADR 0007): never cleared, every visible step drawn each pass and the
; strips moving edges uncover filled (ADR 0002), at a steady 25 passes a
; second (ADR 0003), with a masked sprite (ADR 0004).
;
; Keys: 9 or Q thrust, 6 or O left, 7 or P right (Interface II or keyboard).
;
; Memory:
;   0x4000      the screen
;   0x8000      code, Cyberun's renderer (cyberun.s), variables, then
;               output/data.s's tables and the bit-reversal table; the stack
;               grows down from here
;   0xFDFD      the interrupt's JP
;   0xFE00      IM 2's vector table, 257 bytes of 0xFD

    DEVICE ZXSPECTRUM48

IM2_TABLE   equ 0xFE00
IM2_JUMP    equ 0xFDFD

; build.py --border-timing: the border shows which stage of a pass is
; running, so its timing against the beam can be watched.
BORDER_IDLE      equ 0      ; black: waiting for the frame
BORDER_RESTORE   equ 1      ; blue: restore_sprite
BORDER_PLACE     equ 2      ; red: place_sprite
BORDER_LANDSCAPE equ 4      ; green: landscape_pass, Cyberun's renderer
BORDER_MEND      equ 3      ; magenta: mend_sprite
BORDER_MOVE      equ 6      ; yellow: read_controls and move

    MACRO BORDER colour
    IFDEF BORDER_TIMING
    ld a,colour
    out (0xFE),a
    ENDIF
    ENDM

    ORG 0x8000

start:
    di
    ld sp,STACK_TOP
    ld hl,IM2_TABLE         ; IM 2 with every vector at 0xFDFD
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
    out (0xFE),a            ; a black border
    ld hl,0x4000            ; a black screen
    ld de,0x4001
    ld bc,6912 - 1
    ld (hl),0
    ldir
    ld hl,cyberun.graphics  ; the graphics' spare copy, for isr
    ld de,graphics_copy
    ld bc,cyberun.graphics_end - cyberun.graphics
    ldir
    call power_on_colour
    call start_life
    xor a
    ld (frames),a
    ei

main_loop:
    IFNDEF FREE_RUN
.wait:
    halt                    ; a pass is two frames (ADR 0003)
    ld a,(frames)
    cp 2
    jr c,.wait
    xor a
    ld (frames),a
    ELSE
free_run    equ 1           ; build.py --free-run: each pass as soon as the last
    ENDIF                   ; is done, however long it took
    call draw_pass
    BORDER BORDER_MOVE
    call read_controls
    call move
    BORDER BORDER_IDLE
    jr main_loop

; isr: count the frame. The interrupt can come while one of Cyberun's
; blitters has SP in the step graphics, reading them with POP; then the
; return address the Z80 pushed has landed on the two graphic bytes just read,
; which the next step may read again. So the routine takes the return address
; off, puts those two bytes back from graphics_copy, and goes back with SP
; where the blitter had it. (Cyberun ran with interrupts off instead; Jetrun
; needs them, to keep a pass to two frames: ADR 0003.)
isr:
    ld (isr_sp),sp          ; SP points at the return address
    ld sp,isr_stack
    push af
    push hl
    push de
    ld hl,frames
    inc (hl)
    ld hl,(isr_sp)          ; inside the graphics?
    ld de,cyberun.graphics
    or a
    sbc hl,de
    jr c,.stack
    ld de,cyberun.graphics_end - cyberun.graphics
    or a
    sbc hl,de
    jr nc,.stack
    add hl,de               ; HL = the offset into the graphics
    ld de,graphics_copy
    add hl,de
    ld e,(hl)               ; the two bytes the push wrote over
    inc hl
    ld d,(hl)
    ld hl,(isr_sp)
    ld a,(hl)               ; the return address, to the JP below
    ld (.back + 1),a
    inc hl
    ld a,(hl)
    ld (.back + 2),a
    ld (hl),d               ; the graphic mended
    dec hl
    ld (hl),e
    pop de
    pop hl
    pop af
    ld sp,(isr_sp)
    inc sp
    inc sp
    ei
.back:
    jp 0
.stack:
    pop de
    pop hl
    pop af
    ld sp,(isr_sp)
    ei
    ret

; start_life: the astronaut where the world says, the view round them, and
; the whole play area drawn.
start_life:
    call life_state
    call landscape_full
    jp place_sprite

; life_state: the astronaut's and the view's state for a new life.
life_state:
    ld hl,start_state
    ld de,ax
    ld bc,6
    ldir
    ld de,(start_state + 6)
    ld (view_x),de
    ld de,(start_state + 8)
    ld (view_y),de
    ld hl,0
    ld (vx),hl
    ld (vy),hl
    ld a,1
    ld (on_ground),a
    xor a
    ld (facing),a
    ld (frame),a
    ld (passes),a
    ld a,GROUND_ABOVE       ; the planet's colours, for Cyberun's colour_piece
    ld (cyberun.ground_attr_above),a
    ld a,GROUND_BELOW
    ld (cyberun.ground_attr_below),a
    ret

; draw_pass: what the last pass worked out, put on the screen. The sprite
; first, so that it is back on the screen long before the beam reaches it
; (sprite.s).
draw_pass:
    BORDER BORDER_RESTORE
    call restore_sprite
    BORDER BORDER_PLACE
    call place_sprite
    BORDER BORDER_LANDSCAPE
    call landscape_pass
    BORDER BORDER_MEND
    jp mend_sprite

    INCLUDE "landscape.s"
    INCLUDE "sprite.s"
    INCLUDE "astronaut.s"
    INCLUDE "cyberun.s"

; ---------------------------------------------------------------------------
; Variables.

frames:         db 0        ; frames since the pass began (the interrupt counts)
isr_sp:         dw 0        ; SP when the interrupt came
                ds 8        ; the interrupt routine's own stack
isr_stack:
controls:       db 0        ; read_controls' bits: RIGHT LEFT DOWN UP FIRE
keys:           db 0        ; move's copy of them
ax:             ds 3        ; the sprite's top-left: fraction, then the pixel (word)
ay:             ds 3
vx:             dw 0        ; 256ths of a pixel a pass, signed
vy:             dw 0
on_ground:      db 0
facing:         db 0        ; 0 right, 1 left
frame:          db 0        ; facing * 4 + pose
passes:         db 0
view_x:         dw 0        ; the world point at the play area's top-left
view_y:         dw 0
vpc:            db 0        ; view_split's: the view's page and place in it
vpx:            db 0
vpr:            db 0
vpy:            db 0
drawn_x:        db 0        ; where the sprite was drawn, on the screen
drawn_y:        db 0
sprite_saved:   ds 3 * 24   ; what lies under it
sprite_saved_attrs: ds 3 * 4    ; and the colours of the cells it may cover

; the landscape's working
drawn_view_x:   dw 0        ; where Cyberun's renderer last drew the view
drawn_view_y:   dw 0
full_state:     ds PLAY_W / 8   ; the full render's state, a bit a column
lp_row:         db 0
lp_col:         db 0
page_ox:        dw 0
page_oy:        dw 0
step_x:         dw 0
step_y:         dw 0
step_dir:       db 0
step_count:     db 0
step_dx:        db 0
step_dy:        db 0
tg_offsets:     dw 0
tg_offset:      dw 0
tg_column:      dw 0
tg_c:           db 0
pa_row:         db 0
pa_y:           db 0
rk_sx:          db 0
rk_sy:          db 0
rk_col:         db 0
rr_mask:        db 0        ; row_rock's
rr_last:        db 0
rr_count:       db 0
cr_mask:        db 0        ; column_rock's
cr_count:       db 0
cr_offset:      db 0
cr_row:         db 0
target:         ds 3
mv_px:          dw 0
mv_py:          dw 0
mv_lead:        dw 0
mv_steps:       db 0
mv_blocked:     db 0
mv_up:          db 0
mv_climbed:     db 0
mv_high:        dw 0

    INCLUDE "output/data.s"

graphics_copy:              ; Cyberun's step graphics again, for isr to mend from
    ds cyberun.graphics_end - cyberun.graphics

; Byte n with its bits the other way round, for Cyberun's blitters that draw
; a step mirrored: they read it with the page in B, so it is page-aligned.
    ALIGN 256
bit_reverse_table:
.n = 0
    DUP 256
        db ((.n & 1) << 7) | ((.n & 2) << 5) | ((.n & 4) << 3) | ((.n & 8) << 1) | ((.n & 16) >> 1) | ((.n & 32) >> 3) | ((.n & 64) >> 5) | ((.n & 128) >> 7)
.n = .n + 1
    EDUP

end_of_game:
    ASSERT end_of_game <= IM2_JUMP, the game runs into the interrupt's jump

    SAVESNA "output/jetrun.sna", start
    SAVEBIN "output/jetrun.bin", 0x4000, 0xC000
