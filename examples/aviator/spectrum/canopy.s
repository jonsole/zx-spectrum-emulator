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
SIGHTS_ROW      equ 6           ; the gun sights fill BBC character rows 6 to 8
SIGHTS_ROWS     equ 3

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
    bit 7,a
    jr nz,.switched
    push af                     ; switched off: clear their rows
    xor a
    ld bc,(SIGHTS_ROW << 8) | SIGHTS_ROWS
    call fill_canopy_rows
    pop af
.switched:
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

; ---- what the BBC prints in the canopy, and filling it -------------------------

; Fill BBC character rows B to B + C - 1 of the canopy, inside the frame,
; set (A non-zero) or cleared, on the screen (FillCanopyRows, as model/zx.py
; draws it): Spectrum rows sy(8 B) to sy(8 (B + C)) - 1 within the canopy,
; x from sx(4) to sx(156) - 1, which is bit 0 of byte 0 to bit 6 of byte 31.
; The next view is then copied whole over those rows, as copying the whole
; buffer would. Clearing the whole canopy also takes down the scores and
; TOO LATE!, which the BBC printed there.
fill_canopy_rows:
    ld (fc_colour),a
    ld a,b
    add a,a
    add a,a
    add a,a
    ld l,a
    ld h,high DASH_Y
    ld d,(hl)                   ; the first row
    ld a,b
    add a,c
    add a,a
    add a,a
    add a,a
    ld l,a
    ld e,(hl)                   ; one past the last
    ld a,d
    cp VIEW_TOP
    jr nc,.top
    ld d,VIEW_TOP
.top:
    ld a,e
    cp VIEW_TOP + CANOPY_ROWS
    jr c,.bottom
    ld e,VIEW_TOP + CANOPY_ROWS
.bottom:
    ld a,b
    cp 1
    jr nz,.row
    ld a,c
    cp 19
    jr nz,.row
    ld a,(fc_colour)
    or a
    jr nz,.row
    ld (score_shown),a
    ld (too_late_shown),a
.row:
    ld a,d
    cp e
    ret nc
    ld l,d
    ld h,high DASH_ROWS
    ld c,(hl)
    inc h
    ld b,(hl)                   ; B C -> the row on the screen
    ld a,(fc_colour)
    or a
    ld a,(bc)
    jr z,.clear_first
    or $01
    jr .first
.clear_first:
    and $FE
.first:
    ld (bc),a
    inc c
    ld a,(fc_colour)
    or a
    jr z,.middle
    ld a,$FF
.middle:
    ld h,30
.byte:
    ld (bc),a
    inc c
    dec h
    jr nz,.byte
    ld a,(fc_colour)
    or a
    ld a,(bc)
    jr z,.clear_last
    or $C0
    jr .last
.clear_last:
    and $3F
.last:
    ld (bc),a
    ; The next view is copied whole over this row.
    ld a,d
    sub VIEW_TOP
    ld l,a
    ld h,high prev_lo
    ld (hl),0
    add a,EXT_HI
    ld l,a
    ld (hl),31
    inc d
    jr .row

fc_colour:  db 0

; FillCanopy and ClearCanopy: all of the canopy, rows 1 to 19.
fill_canopy:
    ld bc,$0113
    jp fill_canopy_rows

clear_canopy:
    xor a
    jr fill_canopy

; Draw the messages that are up -- the scores (score_shown) and TOO LATE!
; (too_late_shown) -- where the BBC prints them, in the Spectrum ROM's
; characters, through the text plotter HL: screen_plot_text onto the
; screen, buffer_plot_text into the canopy buffer.
draw_messages:
    ld (dm_plotter + 1),hl
    ld a,(score_shown)
    or a
    jr z,.too_late
    ld hl,high_score_text + 13
    ld a,(highScoreHi)
    ld b,a
    ld a,(highScoreLo)
    ld c,a
    call .digits
    ld hl,score_text + 8
    ld a,(scoreHi)
    ld b,a
    ld a,(scoreLo)
    ld c,a
    call .digits
    ld hl,high_score_text
    ld bc,HIGH_SCORE_AT
    call print_text
    ld hl,score_text
    ld bc,SCORE_AT
    call print_text
.too_late:
    ld a,(too_late_shown)
    or a
    ret z
    ld hl,too_late_text
    ld bc,TOO_LATE_AT
    jp print_text
.digits:
    ; The four BCD digits of B C, as characters, at HL.
    ld a,b
    call .pair
    ld a,c
.pair:
    push af
    rrca
    rrca
    rrca
    rrca
    call .digit
    pop af
.digit:
    and $0F
    add a,'0'
    ld (hl),a
    inc hl
    ret

HIGH_SCORE_AT   equ (13 << 8) | 18 ; (sx(8), sy(24)): BBC character (1, 3)
SCORE_AT        equ (39 << 8) | 60 ; (sx(24), sy(80)): (3, 10)
TOO_LATE_AT     equ (77 << 8) | 42 ; (sx(48), sy(56)): (6, 7)

high_score_text:    db "HIGH SCORE:  00000", 0
score_text:         db "SCORE:  00000", 0
too_late_text:      db "TOO LATE!", 0

; Print the string at HL (ending with 0) from Spectrum pixel (B, C), each
; character's rows through dm_plotter. Uses everything but IX and IY.
print_text:
    ld a,(hl)
    or a
    ret z
    push hl
    push bc
    sub ' '
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,ROM_FONT
    add hl,de                   ; HL -> the glyph
    ld e,8
.row:
    ld a,(hl)
    push hl
    push de
    push bc
    or a
    call nz,dm_plotter
    pop bc
    pop de
    pop hl
    inc hl
    inc c
    dec e
    jr nz,.row
    pop bc
    ld a,b
    add a,8
    ld b,a
    pop hl
    inc hl
    jr print_text

ROM_FONT        equ $3D00       ; the ROM's characters, from space

dm_plotter:
    jp 0                        ; (patched: the text plotter)

; OR glyph row A onto the screen at pixel (B, C). Uses A, B, D, E, H, L.
screen_plot_text:
    ld l,c
    ld h,high DASH_ROWS
    ld e,(hl)
    inc h
    ld d,(hl)
    call text_bytes
    ld a,(de)
    or h
    ld (de),a
    ld a,e
    and $1F
    cp $1F
    ret z
    inc e
    ld a,(de)
    or l
    ld (de),a
    ret

; A's bits shifted to pixel B's place in its byte and the next: H, L; D E
; moved on to B's byte. Uses A, B.
text_bytes:
    ld h,a
    ld l,0
    ld a,b
    and 7
    jr z,.shifted
.shift:
    srl h
    rr l
    dec a
    jr nz,.shift
.shifted:
    ld a,b
    rrca
    rrca
    rrca
    and $1F
    or e
    ld e,a
    ret

; OR glyph row A into the canopy buffer at screen pixel (B, C), widening
; the row's extent to take in both bytes. Uses A, B, D, E, H, L.
buffer_plot_text:
    push af
    ld a,c
    sub VIEW_TOP
    ld e,a
    ld d,0
    ld ix,ext_lo
    add ix,de                   ; IX -> the row's extent
    ex de,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,CANOPY_BUFFER
    add hl,de
    ex de,hl                    ; D E -> the row in the buffer
    pop af
    call text_bytes
    ld a,(de)
    or h
    ld (de),a
    ld a,l
    ld l,e
    push af
    call view_extent
    pop af
    ld l,e
    ld h,a
    ld a,e
    and $1F
    cp $1F
    ret z
    inc e
    ld a,(de)
    or h
    ld (de),a
    ld l,e
    jp view_extent
