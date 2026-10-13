; The view out of the canopy each iteration, after model/canopy.py: the
; visible lines, the horizon's second half, and the gun sights, drawn into
; the canopy buffer and presented; the BBC's colour-cycling state (colourCycle,
; colourLogic and the two line buffers) is kept exactly as the original keeps
; it, since the tests compare it, though the Spectrum draws each view afresh
; and never needs to erase.

SHOW_1          equ $0F         ; colourCycle: colour 1 showing
SHOW_2          equ $F0
DRAW_1          equ $80         ; colourLogic
DRAW_2          equ $40
ERASE           equ $00
HORIZON_MIDDLE  equ 30          ; the horizon is 31 -> 30 -> 32; line 0 is 31 to 30
HORIZON_START   equ 31
HORIZON_END     equ 32
BUFFER1_EMPTY   equ $FF
BUFFER2_EMPTY   equ 47
KEY_I           equ $DA         ; the BBC key codes the view reads
KEY_TAB         equ $9F

; Swap which colour shows and which is drawn in (FlipColours); from an
; erase (colourLogic 0) this also sets colourLogic back to drawing.
flip_colours:
    ld a,(colourCycle)
    rla
    jr nc,.to_2
    ld a,SHOW_1
    ld (colourCycle),a
    ld a,DRAW_1
    ld (colourLogic),a
    ret
.to_2:
    ld a,SHOW_2
    ld (colourCycle),a
    ld a,DRAW_2
    ld (colourLogic),a
    ret

; The horizon's second half (DrawHalfHorizon): point 32 is point 30 doubled
; less point 31, so line 31-30 carries on as far again, drawn from 30 to 32.
draw_half_horizon:
    MACRO MIRROR lo_table, hi_table
    ld l,HORIZON_MIDDLE
    ld h,high lo_table
    ld e,(hl)
    ld h,high hi_table
    ld d,(hl)
    ex de,hl
    add hl,hl
    ex de,hl                    ; D E = 2 * point 30
    ld l,HORIZON_START
    ld h,high lo_table
    ld a,e
    sub (hl)
    ld e,a
    ld h,high hi_table
    ld a,d
    sbc a,(hl)
    ld l,HORIZON_END
    ld (hl),a
    ld h,high lo_table
    ld (hl),e
    ENDM
    MIRROR xPointLo, xPointHi
    MIRROR yPointLo, yPointHi
    ld a,HORIZON
    ld (dcl_horizon),a
    ld a,HORIZON_MIDDLE
    ld c,HORIZON_END
    call draw_clipped_line
    xor a
    ld (dcl_horizon),a
    ret

; Rub out the hidden colour's lines, emptying its line buffer
; (EraseCanopyLines). The Spectrum has nothing to rub out, but the original
; leaves the last line it erased -- the buffer's first slot -- in xTemp1Lo
; and yTemp1Lo, and the buffer empty.
erase_canopy_lines:
    xor a
    ld (colourLogic),a
    ld a,(colourCycle)
    rla
    jr nc,.buffer1
    ld a,(lineBuffer2Count)
    cp BUFFER2_EMPTY
    ret z
    ld a,BUFFER2_EMPTY
    ld (lineBuffer2Count),a
    ld a,(lineBufferR + BUFFER2_EMPTY + 1)
    ld (xTemp1Lo),a
    ld a,(lineBufferS + BUFFER2_EMPTY + 1)
    ld (yTemp1Lo),a
    ret
.buffer1:
    ld a,(lineBuffer1Count)
    cp BUFFER1_EMPTY
    ret z
    ld a,BUFFER1_EMPTY
    ld (lineBuffer1Count),a
    ld a,(lineBufferR)
    ld (xTemp1Lo),a
    ld a,(lineBufferS)
    ld (yTemp1Lo),a
    ret

; The gun sights, if they are on (DrawGunSights): I switches them on and
; off, once a press (bit 7 of gunSights is on, bit 6 that I is held). Then,
; as the original falls through to it, ToggleJoystick. The canopy's corners
; are in the frame overlay.
draw_gun_sights:
    ld a,KEY_I
    call key_pressed
    jr nc,.released
    ld a,(gunSights)
    bit 6,a
    jr nz,.drawn
    xor $C0
    ld (gunSights),a
    jr .drawn
.released:
    ld a,(gunSights)
    and $80
    ld (gunSights),a
.drawn:
    ld a,(gunSights)
    rla
    jr nc,toggle_joystick
    ; A vertical bar at x 80 from BBC rows 48 to 63, and a horizontal one
    ; along row 64 from x 45 to 115 (canopy y = 159 - row).
    ld a,80
    ld (vl_x0),a
    ld (vl_x1),a
    ld a,159 - 48
    ld (vl_y0),a
    ld a,159 - 63
    ld (vl_y1),a
    call draw_view_line
    ld a,45
    ld (vl_x0),a
    ld a,115
    ld (vl_x1),a
    ld a,159 - 64
    ld (vl_y0),a
    ld (vl_y1),a
    call draw_view_line
    ; fall through

; TAB switches the joystick on and off, once a press (ToggleJoystick); the
; original keeps the setting in a pixel of its dashboard, joystick_switch
; here.
toggle_joystick:
    ld a,KEY_TAB
    call key_pressed
    jr c,.pressed
    xor a
    ld (pressingTab),a
    ret
.pressed:
    ld a,(pressingTab)
    or a
    ret nz
    ld a,(joystick_switch)
    xor $88
    ld (joystick_switch),a
    ld a,$80
    ld (pressingTab),a
    ret

; The original's two pieces of game state kept in its screen: the joystick
; switch (row29_char20_4) and the upside-down bar (row25_char13_1).
joystick_switch:    db 0
upside_down_bar:    db 0

; Draw every line on linesToShow (the horizon's other half with line 0),
; marking each line's points as needing working out again, then the sights;
; present the view, rub out the old one, and flip colourCycle and
; colourLogic for next time (DrawCanopyView). With nothing to show, only the
; flip happens.
draw_canopy_view:
    ld a,(linesToShowEnd)
    or a
    jp z,flip_colours
    xor a
    ld (lineCounter),a
.line:
    ld a,(lineCounter)
    ld l,a
    ld h,high linesToShow
    ld a,(hl)
    ld (lineId),a
    or a
    jr nz,.not_horizon
    call draw_half_horizon
    ld a,(lineId)
.not_horizon:
    ld l,a
    ld h,high lineEndPointId
    ld c,(hl)
    ld l,c
    ld h,high pointStatus
    ld (hl),0
    push bc
    ld a,(lineId)
    AT lineStartPointId
    ld l,a
    ld h,high pointStatus
    ld (hl),0
    pop bc
    call draw_clipped_line
    ld hl,lineCounter
    inc (hl)
    ld a,(linesToShowEnd)
    cp (hl)
    jr z,.drawn
    jr nc,.line
.drawn:
    call draw_gun_sights
    call present
    call erase_canopy_lines
    jp flip_colours
