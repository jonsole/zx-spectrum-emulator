; Objects beside the track, drawn into the view as compose paints it. So far
; one sign, at SIGN_SEG, to prove the way of it; cars come the same way.
;
; There is no back buffer: compose paints the screen the viewer is looking
; at, a track line at a time. Drawing objects over the finished view, as the
; BBC draws them into its screen buffer, would show a frame of road where a
; car should be. So before compose an object is turned into parts on the
; screen -- each a block of one pattern, with its lines, its bytes and the
; masks of its end bytes (obj_parts) -- and compose paints a line's parts
; over the road it has just filled, before it goes on to the next. The lines
; from the lowest part to the highest have their calls in compose_lines
; pointed at cs_obj_odd or cs_obj_even, which do that; each such line is
; drawn whether or not its road changed and marked NOT_EMPTY in cs_last, so
; that it is drawn again next update, to take the object away if it has
; moved; and the top one is marked before compose, so compose_skip starts no
; lower than it.
;
; Objects are the BBC's kind: parts of one colour on a scaffold scaled by
; distance, not bitmaps -- a scaled bitmap would want a copy for every size.
; The sign is two parts, a post and a board above it.

SIGN_SEG    equ 12              ; the segment it stands beside, on the right

; A part's half-width W, in track units, is 2 ^ ((LOGW - the distance's
; log) / 256) pixels, as a verge mark's width is: LOGW = LOG2_WIDTH + 256 *
; log2(W / 800). Its heights are in track units above the sign's foot.
; Heights look about eight times smaller than widths: a track line is a
; pitch of 1/32 of the distance, and a pixel a yaw of about 1/262 of it.
POST_LOGW   equ LOG2_WIDTH - 1551   ; W = 12: 256 * log2(800 / 12) = 1551
BOARD_LOGW  equ LOG2_WIDTH - 799    ; W = 92: 256 * log2(800 / 92) = 799
POST_TOP    equ 500                 ; the eye's height: its top on the horizon
BOARD_TOP   equ 875

; At startup, after build_track: no parts, and the sign's foot, beyond the
; right verge by half the track's width at SIGN_SEG.
objects_init:
    ld a,VIEW_LINES
    ld (obj_lo),a               ; no lines with parts: obj_lo > obj_hi
    xor a
    ld (obj_hi),a
    ld (obj_count),a
    ld hl,(SEG_XI + SIGN_SEG * 2)
    ld de,(SEG_XO + SIGN_SEG * 2)
    call .beyond
    ld (sign_x),hl
    ld hl,(SEG_ZI + SIGN_SEG * 2)
    ld de,(SEG_ZO + SIGN_SEG * 2)
    call .beyond
    ld (sign_z),hl
    ld hl,(SEG_YI + SIGN_SEG * 2)
    ld (sign_y),hl
    ret
; HL = HL + (HL - DE) / 2: from the outer verge (DE) through the inner one
; (HL) and half as far again.
.beyond:
    push hl
    or a
    sbc hl,de
    sra h
    rr l
    pop de
    add hl,de
    ret

; The parts for the view compose will paint next, from the camera that made
; its markers: after edges_build, before the HALT.
objects_build:
    call obj_clear
    ; Only in the stretch that is drawn: 1 to 31 segments ahead.
    ld hl,SIGN_SEG
    ld de,(cam_seg)
    call seg_sub
    ld a,h
    or a
    ret nz
    ld a,l
    or a
    ret z
    cp SEG_AHEAD
    ret nc
    ; Its yaw and distance from the camera, as a verge point's.
    ld hl,(sign_x)
    ld de,(cam_x)
    or a
    sbc hl,de
    push hl
    ld hl,(sign_z)
    ld de,(cam_z)
    or a
    sbc hl,de
    ld b,h
    ld c,l
    pop de
    call yaw_angle              ; HL = the yaw, ya_logd = the distance's log
    ld de,(cam_heading)
    or a
    sbc hl,de
    ld a,h
    bit 7,a
    jr z,.right
    neg
.right:
    cp 2 * FOV_YAW              ; well outside the view: nothing of it shows
    ret nc
    YAW_TO_X
    ld (obj_x),hl               ; its centre's screen x
    ; The lines of its foot, the post's top and the board's.
    ld hl,0
    call obj_line_at
    ld (obj_l0),a
    ld hl,POST_TOP
    call obj_line_at
    ld (obj_l1),a
    ld hl,BOARD_TOP
    call obj_line_at
    ld (obj_l2),a
    ; The post, from its foot to the board, in black.
    ld hl,POST_LOGW
    ld a,(obj_l0)
    ld b,a
    ld a,(obj_l1)
    ld c,a
    ld a,(patterns+COLOUR_ROAD)
    call obj_part
    ; The board, in red.
    ld hl,BOARD_LOGW
    ld a,(obj_l1)
    ld b,a
    ld a,(obj_l2)
    ld c,a
    ld a,(patterns+3)           ; verge red: a half tone
    call obj_part
    ; Compose's calls for the lines they cover, and the top one marked for
    ; compose_skip.
    ld hl,cs_obj_even
    ld de,cs_obj_odd
    call obj_calls
    ld a,(obj_hi)
    ld hl,obj_lo
    cp (hl)
    ret c
    ld e,a
    ld d,0
    ld hl,cs_last
    add hl,de
    ld (hl),NOT_EMPTY
    ret

; A = the track line (a signed byte) of the point HL above the sign's foot,
; at its distance (ya_logd): -128 or 127 if it is too steep to have one.
obj_line_at:
    ld de,(sign_y)
    add hl,de
    ld de,(cam_y)
    or a
    sbc hl,de
    call pitch_height
    ld hl,(ya_logd)
    call pitch_line
    ret nc
    ld a,(pa_dysign)
    or a
    ld a,127
    ret p
    ld a,-128
    ret

; One part, half-width log HL, from line B up to (not including) line C, in
; pattern A: appended to obj_parts as compose will paint it, held to the
; view, if any of it is in view.
obj_part:
    ld (.pattern+1),a
    push bc
    ld de,(ya_logd)
    or a
    sbc hl,de
    call exp16                  ; HL = the half-width in pixels (uses B)
    pop bc
    ld a,h
    or l
    ret z                       ; under half a pixel: nothing to draw
    ex de,hl
    ld hl,(obj_x)
    or a
    sbc hl,de                   ; the first x
    push hl
    ld hl,(obj_x)
    add hl,de
    dec hl                      ; the last x
    pop de
    ; Off the right or the left altogether: nothing.
    bit 7,h
    ret nz                      ; last x < 0
    ld a,d
    or a
    jp p,.first_on
    ld de,0                     ; first x < 0: from the left edge
.first_on:
    ld a,d
    or a
    ret nz                      ; first x > 255
    ld a,h
    or a
    jr z,.last_on
    ld l,255                    ; last x > 255: to the right edge
.last_on:
    ; Its lines, held to the view: B (signed) up from 0, C to VIEW_LINES.
    bit 7,b
    jr z,.bottom_on
    ld b,0
.bottom_on:
    bit 7,c
    ret nz                      ; its top is under the view
    ld a,c
    cp VIEW_LINES
    jr c,.top_on
    ld c,VIEW_LINES
.top_on:
    ld a,b
    cp c
    ret nc                      ; no lines
    ld a,(obj_count)
    cp OBJ_PARTS
    ret nc                      ; no room for it
    inc a
    ld (obj_count),a
    ; The part's record.
    push de
    push hl
    dec a
    add a,a
    add a,a
    add a,a                     ; PART_SIZE = 8
    ASSERT PART_SIZE == 8
    ld e,a
    ld d,0
    ld ix,obj_parts
    add ix,de
    pop hl
    pop de
    ld (ix+PART_LO),b
    dec c
    ld (ix+PART_HI),c
    ; The lines with parts on, for the calls in compose_lines.
    ld a,(obj_lo)
    cp b
    jr c,.lo_kept
    ld a,b
    ld (obj_lo),a
.lo_kept:
    ld a,(obj_hi)
    cp c
    jr nc,.hi_kept
    ld a,c
    ld (obj_hi),a
.hi_kept:
    ; Its bytes and the masks of its end bytes: the first byte's bits from
    ; the first x on, and the last byte's up to the last x.
    ld h,high tbl_mask
    ld a,(hl)                   ; L = the last x
    srl a
    cpl
    ld (ix+PART_LMASK),a
    ld a,l
    rrca
    rrca
    rrca
    and 31
    ld b,a                      ; the last byte
    ld l,e                      ; the first x
    ld c,(hl)                   ; its mask
    ld a,e
    rrca
    rrca
    rrca
    and 31
    ld (ix+PART_FIRST),a
    neg
    add a,b                     ; the bytes after the first
    ld (ix+PART_MORE),a
    jr nz,.wide
    ld a,c
    and (ix+PART_LMASK)         ; all in one byte: both ends' bits
    ld c,a
.wide:
    ld (ix+PART_FMASK),c
.pattern:
    ld a,0                      ; patched: the pattern
    ld (ix+PART_EVEN),a
    rrca                        ; odd lines' patterns are turned two places
    rrca
    ld (ix+PART_ODD),a
    ret

; Points the calls in compose_lines of the lines obj_lo to obj_hi at HL (on
; an even line) and DE (on an odd one).
obj_calls:
    ld (.even+1),hl
    ld (.odd+1),de
    ld a,(obj_hi)
    ld hl,obj_lo
    sub (hl)
    ret c                       ; no lines
    inc a
    ld b,a
    ld c,(hl)                   ; the line
    ld a,VIEW_LINES - 1
    sub c
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    ld d,h
    ld e,l
    add hl,hl
    add hl,de                   ; (VIEW_LINES - 1 - line) * 12
    ASSERT CS_CALL == 12
    ld de,compose_lines + 10    ; the call's address bytes
    add hl,de
.line:
    bit 0,c
.even:
    ld de,0                     ; patched
    jr z,.store
.odd:
    ld de,0                     ; patched
.store:
    ld (hl),e
    inc hl
    ld (hl),d
    ld de,-CS_CALL - 1          ; the line above's
    add hl,de
    inc c
    djnz .line
    ret

; Takes last update's parts away: their lines' calls back to the plain ones.
; cs_obj left NOT_EMPTY in cs_last for them, so they are drawn again, without.
obj_clear:
    ld hl,cs_line_even
    ld de,cs_line_odd
    call obj_calls
    ld a,VIEW_LINES
    ld (obj_lo),a               ; no lines: obj_lo > obj_hi
    xor a
    ld (obj_hi),a
    ld (obj_count),a
    ret

; Compose's line, then the parts on it: the calls in compose_lines for the
; lines obj_lo to obj_hi, with cs_line_odd's and cs_line_even's arguments.
; The line is left NOT_EMPTY in cs_last, so that it is drawn again next
; update, to take this one's object away. Its road needs no forcing now: if
; an object was on it last update, cs_last already says NOT_EMPTY, and if
; not, the road the screen shows there is the road it would draw.
cs_obj_odd:
    push de
    push bc
    call cs_line_odd
    ld a,PART_ODD - PART_EVEN
    jr cs_obj
cs_obj_even:
    push de
    push bc
    call cs_line_even
    xor a
cs_obj:
    ld (.odd+1),a               ; 1 on an odd line: its pattern is the next
    pop bc
    ld a,NOT_EMPTY
    ld (bc),a
    ld a,c
    sub low cs_last
    ASSERT high cs_last == high (cs_last + VIEW_LINES - 1)
    ld c,a                      ; the line
    pop de                      ; the row
    ld hl,obj_parts
    ld a,(obj_count)
    or a
    ret z
    ld b,a
.part:
    ; HL = the part's PART_LO. Parts sit in one page, 8-aligned, so only L
    ; moves.
    ld a,c
    cp (hl)
    jr c,.below
    inc l
    ld a,(hl)                   ; PART_HI
    cp c
    jr c,.above
    inc l
    push bc
    push de
    ld a,(hl)                   ; PART_FIRST
    add a,e
    ld e,a                      ; DE = its first byte
    inc l
    ld a,(hl)                   ; PART_MORE
    ex af,af'
    inc l
    ld c,(hl)                   ; PART_FMASK
    inc l
    ld a,(hl)                   ; PART_LMASK
    ld (.lmask+1),a
    inc l                       ; PART_EVEN
.odd:
    ld a,0                      ; patched: 1 on an odd line
    add a,l
    ld l,a
    ld b,(hl)                   ; the pattern for this line
    ex af,af'
    or a
    jr z,.one                   ; one byte: its mask has both ends
    ; The first byte: old ^ ((old ^ B) & C), pattern B where mask C has bits.
    ex af,af'
    ld a,(de)
    xor b
    and c
    ex de,hl
    xor (hl)
    ld (hl),a
    inc l
    ex af,af'
    dec a
    jr z,.last
    ; The whole bytes between, by calling that many stores from the end of
    ; obj_fill: 11 T-states a byte.
    add a,a
    neg
    add a,low obj_fill_end
    ld (.into+1),a
.into:
    call obj_fill_end           ; patched: the low byte
.last:
    ex de,hl
.lmask:
    ld c,0                      ; patched: the last byte's mask
.one:
    ld a,(de)
    xor b
    and c
    ex de,hl
    xor (hl)
    ld (hl),a
    ex de,hl
    pop de
    pop bc
    ld a,l
    and $F8                     ; back to the part's start
    add a,PART_SIZE
    ld l,a
    djnz .part
    ret
.above:
    dec l
.below:
    ld a,l
    add a,PART_SIZE
    ld l,a
    djnz .part
    ret

; B into as many bytes from HL as calls it that many stores from the end.
obj_fill:
    REPT 32
    ld (hl),b
    inc l
    ENDR
obj_fill_end:
    ret
    ASSERT high obj_fill == high obj_fill_end

; A part: its lines, its bytes and their masks, and its pattern both ways.
PART_LO     equ 0               ; the lowest line it covers
PART_HI     equ 1               ; and the highest
PART_FIRST  equ 2               ; its first byte in the row
PART_MORE   equ 3               ; the bytes after that, to its last
PART_FMASK  equ 4               ; the first byte's bits it covers
PART_LMASK  equ 5               ; the last byte's
PART_EVEN   equ 6               ; its pattern on an even line
PART_ODD    equ 7               ; and on an odd one, turned two places
PART_SIZE   equ 8
OBJ_PARTS   equ 8               ; parts an update can have

obj_count:  db 0                ; the parts this update
    ALIGN 8
obj_parts:  ds OBJ_PARTS * PART_SIZE
    ASSERT high obj_parts == high (obj_parts + OBJ_PARTS * PART_SIZE - 1)
obj_lo:     db 0                ; the lines with parts: obj_lo to obj_hi
obj_hi:     db 0
obj_x:      dw 0                ; the sign's centre's screen x
obj_l0:     db 0                ; the lines of its foot, post top, board top
obj_l1:     db 0
obj_l2:     db 0
sign_x:     dw 0                ; its foot
sign_y:     dw 0
sign_z:     dw 0
