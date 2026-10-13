; Objects on and beside the track, drawn into the view as compose paints
; it: so far a sign, and a car parked on the track.
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
; Objects are the BBC's kind: parts of one colour on a grid scaled by
; distance, not bitmaps -- a scaled bitmap would want a copy for every size.
; Their types are in object_types.py, which build.py writes out as
; output/objects.s.gen: each part's heights and offsets as logs of their
; sizes on screen at a distance of one, so that scaling one is a
; subtraction and an antilogarithm. Each instance, below, is a type at a
; place on the track. Objects are drawn far to near, so that a nearer one is
; painted over a farther one.

OBJ_SIGN_SEG equ 12             ; the sign stands beside the right verge here
OBJ_CAR_SEG equ 24              ; and the car is parked on the track here

; An instance: its type, its foot, its segment, and from objects_build
; whether it is shown, its distance's log, its centre's screen x and the
; track line of its foot.
INST_TYPE   equ 0
INST_X      equ 2
INST_Y      equ 4
INST_Z      equ 6
INST_SEG    equ 8
INST_SHOWN  equ 10
INST_LOGD   equ 11
INST_SX     equ 13
INST_LINE   equ 15
INST_SIZE   equ 16
OBJECTS     equ 2

; Part records in object_types.py's output: four logs, then flags and colour.
TP_BOTTOM   equ 0
TP_TOP      equ 2
TP_LEFT     equ 4
TP_RIGHT    equ 6
TP_FLAGS    equ 8               ; bit 0: the left is left of the centre line;
TP_COLOUR   equ 9               ; bit 1: the right is
TP_EDGE     equ 10              ; the edges' colour, or NO_EDGE for none
TP_SIZE     equ 11
NO_EDGE     equ 255

; At startup, after build_track: no parts, and the instances' feet.
objects_init:
    ld a,VIEW_LINES
    ld (obj_lo),a               ; no lines with parts: obj_lo > obj_hi
    xor a
    ld (obj_hi),a
    ld (obj_count),a
    ; The sign: beyond the right verge by half the track's width.
    ld hl,(SEG_XI + OBJ_SIGN_SEG * 2)
    ld de,(SEG_XO + OBJ_SIGN_SEG * 2)
    call .beyond
    ld (obj_instances + INST_X),hl
    ld hl,(SEG_ZI + OBJ_SIGN_SEG * 2)
    ld de,(SEG_ZO + OBJ_SIGN_SEG * 2)
    call .beyond
    ld (obj_instances + INST_Z),hl
    ld hl,(SEG_YI + OBJ_SIGN_SEG * 2)
    ld (obj_instances + INST_Y),hl
    ; The car: five eighths of the way from the right verge to the left,
    ; just left of the middle.
    ld hl,(SEG_XI + OBJ_CAR_SEG * 2)
    ld de,(SEG_XO + OBJ_CAR_SEG * 2)
    call .across
    ld (obj_instances + INST_SIZE + INST_X),hl
    ld hl,(SEG_ZI + OBJ_CAR_SEG * 2)
    ld de,(SEG_ZO + OBJ_CAR_SEG * 2)
    call .across
    ld (obj_instances + INST_SIZE + INST_Z),hl
    ld hl,(SEG_YI + OBJ_CAR_SEG * 2)
    ld (obj_instances + INST_SIZE + INST_Y),hl
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
; HL = HL + (DE - HL) * 5 / 8: from the inner verge (HL) towards the outer.
.across:
    push hl
    ex de,hl
    or a
    sbc hl,de                   ; outer - inner
    sra h
    rr l                        ; a half
    ld d,h
    ld e,l
    sra d
    rr e
    sra d
    rr e                        ; an eighth
    add hl,de
    pop de
    add hl,de
    ret

; The parts for the view compose will paint next, from the camera that made
; its markers: after edges_build, before the HALT.
objects_build:
    call obj_clear
    ld ix,obj_instances
    ld b,OBJECTS
.project:
    push bc
    call obj_project
    pop bc
    ld de,INST_SIZE
    add ix,de
    djnz .project
    ; Far to near: the shown instance with the greatest distance, until
    ; none is left.
.farthest:
    ld iy,0                     ; none yet
    ld hl,0                     ; the greatest log so far
    ld ix,obj_instances
    ld b,OBJECTS
.look:
    ld a,(ix+INST_SHOWN)
    or a
    jr z,.next
    ld e,(ix+INST_LOGD)
    ld d,(ix+INST_LOGD+1)
    push hl
    or a
    sbc hl,de                   ; logs are positive: an unsigned compare
    pop hl
    jr nc,.next
    ex de,hl                    ; the farthest so far
    push ix
    pop iy
.next:
    ld de,INST_SIZE
    add ix,de
    djnz .look
    ld a,iyh
    or iyl
    jr z,.drawn
    push iy
    pop ix
    ld (ix+INST_SHOWN),0
    call obj_draw
    jr .farthest
.drawn:
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

; The instance at IX, worked out from the camera: shown or not, and if so
; its distance's log, its centre's screen x and its foot's track line.
obj_project:
    ld (ix+INST_SHOWN),0
    ; Only in the stretch that is drawn: 1 to 31 segments ahead.
    ld l,(ix+INST_SEG)
    ld h,(ix+INST_SEG+1)
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
    ld l,(ix+INST_X)
    ld h,(ix+INST_X+1)
    ld de,(cam_x)
    or a
    sbc hl,de
    push hl
    ld l,(ix+INST_Z)
    ld h,(ix+INST_Z+1)
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
    ld (ix+INST_SX),l
    ld (ix+INST_SX+1),h
    ld hl,(ya_logd)
    ld (ix+INST_LOGD),l
    ld (ix+INST_LOGD+1),h
    ; Its foot's track line: -128 or 127 if too steep to have one.
    ld l,(ix+INST_Y)
    ld h,(ix+INST_Y+1)
    ld de,(cam_y)
    or a
    sbc hl,de
    call pitch_height
    ld hl,(ya_logd)
    call pitch_line
    jr nc,.line
    ld a,(pa_dysign)
    or a
    ld a,127
    jp p,.line
    ld a,-128
.line:
    ld (ix+INST_LINE),a
    ld (ix+INST_SHOWN),1
    ret

; The parts of the instance at IX, scaled to its distance and stored for
; compose.
obj_draw:
    ld l,(ix+INST_TYPE)
    ld h,(ix+INST_TYPE+1)
    ld b,(hl)                   ; the parts
    inc hl
.part:
    push bc
    ld (obj_tp),hl
    ; Its bottom and top, as lines: the foot's plus each height's size.
    ld e,(hl)
    inc hl
    ld d,(hl)
    call obj_line
    ld (.bottom+1),a
    ld hl,(obj_tp)
    inc hl
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    call obj_line
    ld (.top+1),a
    ; Its left and right, as x: the centre's plus or minus each offset's
    ; size, the right less one to be its last pixel.
    ld hl,(obj_tp)
    ld de,TP_LEFT
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld hl,(obj_tp)
    ld bc,TP_FLAGS
    add hl,bc
    ld a,(hl)
    call obj_x                  ; HL = the first x
    push hl
    ld hl,(obj_tp)
    ld de,TP_RIGHT
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld hl,(obj_tp)
    ld bc,TP_FLAGS
    add hl,bc
    ld a,(hl)
    rrca                        ; bit 1, the right's side, into bit 0
    call obj_x
    dec hl                      ; the last x
    pop de
    ; Its colours, as patterns: its edges' for obj_store, and its fill's.
    push hl
    ld hl,(obj_tp)
    ld bc,TP_EDGE
    add hl,bc
    ld a,(hl)
    cp NO_EDGE
    ld a,0
    jr z,.edge_set
    ld a,(hl)
    add a,low patterns
    ld c,a
    ld b,high patterns
    ld a,(bc)
    ld (obj_edge),a
    ld a,1
.edge_set:
    ld (obj_edge_on),a
    dec hl                      ; TP_COLOUR
    ld a,(hl)
    add a,low patterns
    ld l,a
    ld h,high patterns
    ASSERT high patterns == high (patterns + 5)
    ld a,(hl)
    pop hl
.bottom:
    ld b,0                      ; patched
.top:
    ld c,0                      ; patched
    push ix
    call obj_store              ; which uses IX
    pop ix
    ld hl,(obj_tp)
    ld de,TP_SIZE
    add hl,de
    pop bc
    dec b
    jp nz,.part
    ret

; A = the instance's foot line (IX) plus the size of the height whose log is
; DE, held to a signed byte.
obj_line:
    call obj_size
    ld a,(ix+INST_LINE)
    ld e,a
    rlca
    sbc a,a
    ld d,a                      ; DE = the foot's line
    add hl,de
    ; Held to -128..127: past the top of the view or under the bottom.
    ld a,h
    or a
    jr z,.low_byte
    inc a
    jr z,.negative
    ld a,127                    ; far above
    ret
.negative:
    ld a,l
    or a
    ret m
    ld a,-128                   ; far below
    ret
.low_byte:
    ld a,l
    or a
    ret p
    ld a,127
    ret

; HL = the instance's centre x (IX) plus the size of the offset whose log is
; DE, or minus it if bit 0 of A is set.
obj_x:
    push af
    call obj_size
    pop af
    ex de,hl
    ld l,(ix+INST_SX)
    ld h,(ix+INST_SX+1)
    rrca
    jr c,.left
    add hl,de
    ret
.left:
    or a
    sbc hl,de
    ret

; HL = the size on screen of the measurement whose log is DE, at the
; instance's distance (IX): 2 ^ ((DE - the distance's log) / 256).
obj_size:
    ld l,(ix+INST_LOGD)
    ld h,(ix+INST_LOGD+1)
    ex de,hl
    or a
    sbc hl,de
    jp exp16

; A part from x DE to x HL (inclusive, signed), from line B up to (not
; including) line C (signed bytes), in pattern A, with edges in pattern
; obj_edge if obj_edge_on: appended to obj_parts as compose will paint it,
; held to the view, if any of it is in view. An edge held to the screen's
; side is not drawn there: it is off the screen.
obj_store:
    ld (.pattern+1),a
    ld a,(obj_edge_on)
    ld (.ledge+1),a
    ld (.redge+1),a
    ld a,(obj_edge)
    ld (.edge+1),a
    ; Nothing across: its last x before its first.
    push hl
    or a
    sbc hl,de
    pop hl
    ret m
    ; Off the right or the left altogether: nothing.
    bit 7,h
    ret nz                      ; last x < 0
    ld a,d
    or a
    jp p,.first_on
    ld de,0                     ; first x < 0: from the left edge
    xor a
    ld (.ledge+1),a
.first_on:
    ld a,d
    or a
    ret nz                      ; first x > 255
    ld a,h
    or a
    jr z,.last_on
    ld l,255                    ; last x > 255: to the right edge
    xor a
    ld (.redge+1),a
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
    add a,a
    add a,a                     ; PART_SIZE = 16
    ASSERT PART_SIZE == 16
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
    ; Its edges: the last and the first x's own pixels, a mask's bit less
    ; the next one's.
    ld h,high tbl_mask
.redge:
    ld a,0                      ; patched: 1 to draw its right edge
    or a
    jr z,.no_redge
    ld a,(hl)                   ; L = the last x
    srl a
    xor (hl)
.no_redge:
    ld (ix+PART_LEDGE),a
    ; Its bytes and the masks of its end bytes: the first byte's bits from
    ; the first x on, and the last byte's up to the last x.
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
.ledge:
    ld a,0                      ; patched: 1 to draw its left edge
    or a
    jr z,.no_ledge
    ld a,c
    srl a
    xor c
.no_ledge:
    ld (ix+PART_FEDGE),a
    or (ix+PART_LEDGE)
    ld (ix+PART_EDGES),a        ; none: nothing to paint
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
.edge:
    ld a,0                      ; patched: the edges' pattern
    ld (ix+PART_EEVEN),a
    rrca
    rrca
    ld (ix+PART_EODD),a
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
    ; HL = the part's PART_LO. Parts sit in one page, 16-aligned, so only
    ; L moves.
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
    ld (.first_byte+1),a
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
    ; Its edges: a pixel at each end in the edges' pattern. DE is at its
    ; last byte.
    ld a,l
    and $F0
    or PART_EDGES
    ld l,a
    ld a,(hl)
    or a
    jr z,.edged
    dec l                       ; PART_LEDGE
    ld c,(hl)
    dec l                       ; PART_FEDGE
    ld a,(hl)
    ld (.fedge+1),a
    ld a,l
    and $F0
    or PART_EEVEN
    ld l,a
    ld a,(.odd+1)
    add a,l
    ld l,a
    ld b,(hl)                   ; the edges' pattern for this line
    ld a,(de)                   ; the last byte: B where mask C has its bit
    xor b
    and c
    ex de,hl
    xor (hl)
    ld (hl),a
.first_byte:
    ld l,0                      ; patched: the first byte
.fedge:
    ld c,0                      ; patched: its edge's bit
    ld a,(hl)
    xor b
    and c
    xor (hl)
    ld (hl),a
    ex de,hl
.edged:
    pop de
    pop bc
    ld a,l
    and $F0                     ; back to the part's start
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
    dec b
    jp nz,.part
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
PART_EEVEN  equ 8               ; its edges' pattern, both ways
PART_EODD   equ 9
PART_FEDGE  equ 10              ; its left edge's bit in its first byte
PART_LEDGE  equ 11              ; its right edge's in its last
PART_EDGES  equ 12              ; non-zero if it has either
PART_SIZE   equ 16
OBJ_PARTS   equ 16              ; parts an update can have

obj_count:  db 0                ; the parts this update
obj_parts   equ $BC00           ; free memory, a page of its own
    ASSERT high obj_parts == high (obj_parts + OBJ_PARTS * PART_SIZE - 1)
    ASSERT (obj_parts & 15) == 0
obj_lo:     db 0                ; the lines with parts: obj_lo to obj_hi
obj_hi:     db 0
obj_tp:     dw 0                ; the part being drawn, in its type
obj_edge:   db 0                ; its edges' pattern
obj_edge_on: db 0               ; 1 if it has edges
obj_instances:
    dw obj_type_sign, 0, 0, 0, OBJ_SIGN_SEG
    db 0
    dw 0, 0
    db 0
    dw obj_type_car, 0, 0, 0, OBJ_CAR_SEG
    db 0
    dw 0, 0
    db 0
    ASSERT $ - obj_instances == OBJECTS * INST_SIZE
