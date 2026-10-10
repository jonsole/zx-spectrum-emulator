; The panel under the view: where he is, and how hard the machine is working.
;
; Characters come from the ROM's set at 0x3D00, so the panel is blank on a
; machine with no ROM -- the game itself never needs one.

ROM_CHARS   equ 0x3C00      ; the ROM's set, less its first 32 (unprinted) codes

HUD_ROW     equ VIEW_H      ; the panel's first character row

hud_init:
    ld hl,0x5800 + HUD_ROW * 32
    ld de,0x5800 + HUD_ROW * 32 + 1
    ld bc,(24 - HUD_ROW) * 32 - 1
    ld (hl),HUD_ATTR
    ldir
    ld bc,(HUD_ROW + 1) * 256 + 1   ; B = row, C = column, swapped below
    ld de,title_text
    call print_at
    ld bc,(HUD_ROW + 2) * 256 + 1
    ld de,status_text
    jp print_at

; hud_update -- the position and the frames the last pass took.
hud_update:
    ld bc,(HUD_ROW + 2) * 256 + 3
    call hud_cursor
    ld de,(pos_x + 1)
    call print_hex16
    ld bc,(HUD_ROW + 2) * 256 + 11
    call hud_cursor
    ld de,(pos_y + 1)
    call print_hex16
    ld bc,(HUD_ROW + 2) * 256 + 19
    call hud_cursor
    ld a,(loop_frames)
    jp print_hex8

; hud_cursor -- HL = the screen address of row B, column C.
hud_cursor:
    ld a,b
    ld b,c
    ld c,a
    jp cell_addr

; print_at -- prints the zero-terminated string at DE at row B, column C.
print_at:
    call hud_cursor
.next:
    ld a,(de)
    or a
    ret z
    call print_char
    inc de
    jr .next

; print_hex16 -- DE in four hex digits at HL.
print_hex16:
    ld a,d
    call print_hex8
    ld a,e
print_hex8:
    push af
    rrca
    rrca
    rrca
    rrca
    call print_digit
    pop af
print_digit:
    and 0x0F
    add a,'0'
    cp '9' + 1
    jr c,print_char
    add a,'A' - '9' - 1
    ; fall through

; print_char -- character A at HL, which moves on a cell. Preserves BC, DE.
print_char:
    push bc
    push de
    push hl
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,ROM_CHARS
    add hl,de
    ex de,hl
    pop hl
    push hl
    ld b,8
.line:
    ld a,(de)
    ld (hl),a
    inc de
    inc h
    djnz .line
    pop hl
    inc l
    pop de
    pop bc
    ret

title_text:     db "EXILE-LIKE  Q/A/O/P", 0
status_text:    db "X ....  Y ....  F ..", 0
