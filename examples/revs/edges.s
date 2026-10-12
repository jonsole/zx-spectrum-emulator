; The edge markers, after the BBC's DrawTrack: each of the four verge edges
; is a line through its side's points, far to near, and wherever it crosses
; a track line it leaves a marker saying "from this x rightwards, this
; colour". compose_view then sorts each line's markers and fills between
; them.
;
; Every track line has a MARK_LINE-byte record:
;   +0  the offset of its next free marker: 4 + 2 * markers
;   +1  the fill pattern it starts with at x = 0
;   +2  the x (signed 16-bit) that pattern was set from: the rightmost
;       marker left of the screen so far, $8000 for none
;   +4  up to MAX_MARKS pairs of x (0..255), fill pattern
;
; Markers hold the colour's fill pattern (patterns.s) rather than the
; colour, so compose_view has nothing to look up; it rotates them on odd
; lines.
;
; An edge on screen leaves one marker per line, at its x in the middle of
; the line; one off the right leaves nothing, and one off the left competes
; to set the line's starting colour. The edges are drawn left to right, as
; DrawTrack does -- the left verge, the road, the right verge, the grass --
; so where two land on the same x the later one, further right in the
; picture, wins.

MARK_LINE   equ 32
MAX_MARKS   equ 14
HORIZON     equ 60
NO_MARK_X   equ $8000           ; left of everything
FAR_LEFT    equ $8001           ; an edge that has left the bottom of the view
MARK_LINES  equ 128             ; records for lines up to 127, the highest
COLOUR_GRASS equ 0
COLOUR_ROAD equ 1

edges_build:
    ; Every record's header, unrolled through the stack pointer: two pushes
    ; a line. An interrupt meanwhile pushes below SP, onto the header about
    ; to be pushed over or onto the last marker slots of the record before,
    ; which hold nothing yet, so this needs no DI.
    ld (.sp+1),sp
    ld de,NO_MARK_X
    ld bc,(GRASS << 8) | 4
.y = 0
    DUP VIEW_LINES
    IF .y == HORIZON
    ld bc,(SKY << 8) | 4
    ENDIF
    ld sp,MARKERS + .y * MARK_LINE + 4
    push de
    push bc
.y = .y + 1
    EDUP
.sp:
    ld sp,0                     ; patched
    ; The left verge's outside edge, in the verge's colours.
    ld a,1
    ld (eg_left_side),a
    ld a,2
    ld (eg_field),a
    ld a,$FF
    ld (eg_colour),a
    ld ix,VERGE_L
    ld a,(vl_count)
    call edge
    ; The left verge's track edge: road from here.
    xor a
    ld (eg_field),a
    ld a,COLOUR_ROAD
    ld (eg_colour),a
    ld ix,VERGE_L
    ld a,(vl_count)
    call edge
    ; The right verge's track edge, in the verge's colours.
    xor a
    ld (eg_left_side),a
    ld a,$FF
    ld (eg_colour),a
    ld ix,VERGE_R
    ld a,(vr_count)
    call edge
    ; The right verge's outside edge: grass from here.
    ld a,2
    ld (eg_field),a
    ld a,COLOUR_GRASS
    ld (eg_colour),a
    ld ix,VERGE_R
    ld a,(vr_count)
    jp edge

; One edge through the A points of the list at IX, taking x from field
; eg_field (0 or 2) and the colour from eg_colour, or from each point's
; own colour if that is $FF. Each line segment between two points takes
; the nearer point's colour.
edge:
    or a
    ret z
    ld (eg_points),a
    call eg_point
    ld (rs_bx),hl
    ld (rs_bl),a
    ld (eg_low),a
    ld a,(eg_pc)
    ld (eg_low_colour),a
.next:
    ld hl,eg_points
    dec (hl)
    jr z,.bottom
    ld hl,(rs_bx)
    ld (rs_ax),hl
    ld a,(rs_bl)
    ld (rs_al),a
    ld de,ENTRY
    add ix,de
    call eg_point
    ld (rs_bx),hl
    ld (rs_bl),a
    ld b,a
    ld a,(eg_low)
    cp b
    jr c,.not_lower
    jr z,.not_lower
    ld a,b
    ld (eg_low),a
    ld a,(eg_pc)
    ld (eg_low_colour),a
.not_lower:
    ld a,(eg_pc)
    ld (rs_c),a
    ld a,(eg_points)
    dec a
    ld (rs_more),a              ; zero for the edge's last line segment
    call raster
    jp .next
.bottom:
    ; Below its lowest point an edge on the left has gone off the left of
    ; the screen, where it still decides the colour those lines start with.
    ld a,(eg_left_side)
    or a
    ret z
    ld a,(eg_low_colour)
    ld (rs_c),a
    ld a,(eg_low)
    jp raster_far_left

; The point at IX: HL = its x on this edge, A = its line, eg_pc = colour.
eg_point:
    ld a,(eg_field)
    or a
    jr nz,.outside
    ld l,(ix+0)
    ld h,(ix+1)
    jr .colour
.outside:
    ld l,(ix+2)
    ld h,(ix+3)
.colour:
    ld a,(eg_colour)
    cp $FF
    jr nz,.fixed
    ld a,(ix+5)
.fixed:
    ld (eg_pc),a
    ld a,(ix+4)
    ret

; Marks the lines from (rs_ax, rs_al) to (rs_bx, rs_bl) in colour rs_c: one
; marker per line, at the line's x rounded to the nearest pixel, stepped
; Bresenham-fashion from a single division. The last line is left to the
; next line segment, which starts there at the same x and whose colour
; would win anyway, unless rs_more is zero: this is the edge's last.
;
; The loop is the hottest code in the edge stage, so it runs in registers
; with its constants patched into its instructions: main set HL = x,
; DE = the whole-pixel step per line (negative going left), C = the error
; term, B = lines left; alternate set HL' = the line's marker record,
; BC' = +-32 to the next record, DE' for the marker.
raster:
    ld a,(rs_al)
    ld c,a
    ld a,(rs_bl)
    sub c
    jr nz,.slope
    ; Level: one marker, for the nearer point, if this is the last segment.
    ld a,(rs_more)
    or a
    ret nz
    ld hl,(rs_bx)
    ld (rs_ax),hl
    ld a,(rs_bl)
    ld (rs_al),a
    ld b,1
    ld de,0
    ld c,e
    ld a,1
    jr .go
.slope:
    ld de,MARK_LINE
    jr nc,.up
    neg
    ld de,-MARK_LINE
.up:
    ld (rs_n),a
    ld (rs_step),de
    ld hl,(rs_bx)
    ld de,(rs_ax)
    or a
    sbc hl,de
    ld b,$23                    ; INC HL
    bit 7,h
    jr z,.right
    ex de,hl
    ld hl,0
    or a
    sbc hl,de
    ld b,$2B                    ; DEC HL
.right:
    ld a,b
    ld (.carry),a
    ld a,(rs_n)
    ld c,a
    call div16_8                ; |dx| = q * n + r
    ld (.r+1),a
    ex de,hl                    ; DE = q
    ld a,(.carry)
    cp $23
    jr z,.forwards
    ld hl,0
    or a
    sbc hl,de
    ex de,hl                    ; DE = -q
.forwards:
    ld a,(rs_more)
    or a
    ld a,(rs_n)
    ld b,a
    jr nz,.lines
    inc b                       ; the last segment's last line too
.lines:
    ld c,a
    srl c                       ; the error starts at n / 2: rounding
.go:
    ld (.n1+1),a
    ld (.n2+1),a
    push de
    push bc
    call rs_pattern
    ld a,(rs_al)
    call rs_record
    ld bc,(rs_step)
    exx                         ; the record and its step to the alternates
    pop bc
    pop de
    ld hl,(rs_ax)
.line:
    ld a,h
    or a
    jr nz,.off_screen
    ld a,l
    exx
    ld d,a                      ; x
    ld a,(hl)
    cp MARK_LINE
    jr nc,.next                 ; full: a crowded line loses its last edges
    ld e,l
    add a,2
    ld (hl),a
    add a,l
    ld l,a                      ; just past the new marker
    dec l
.pattern1:
    ld (hl),0                   ; patched: the colour's pattern
    dec l
    ld (hl),d
    ld l,e
.next:
    add hl,bc
    exx
.r:
    ld a,0                      ; patched: r, the remainder
    add a,c
.n1:
    cp 0                        ; patched: n
    jr c,.no_carry
.n2:
    sub 0                       ; patched: n
.carry:
    inc hl                      ; patched: INC HL or DEC HL
.no_carry:
    ld c,a
    add hl,de
    djnz .line
    ret
.off_screen:
    jp m,.left
    exx                         ; off the right: nothing to the right of it
    jr .next
.left:
    ; Off the left: it sets the line's starting pattern if it is the
    ; rightmost so far. Both x are negative, so an unsigned compare works.
    push hl
    exx
    pop de
    ld a,l
    ld (.restore+1),a
    inc l
    inc l
    ld a,e
    sub (hl)
    inc l
    ld a,d
    sbc a,(hl)
    jr c,.restore
    ld (hl),d
    dec l
    ld (hl),e
    dec l
.pattern2:
    ld (hl),0                   ; patched: the colour's pattern
.restore:
    ld l,0                      ; patched: back to the record's start
    jr .next

; Lines 0 to A - 1 start with colour rs_c: they lie below an edge that has
; gone off the left of the screen.
raster_far_left:
    cp VIEW_LINES
    jr c,.some
    ld a,VIEW_LINES
.some:
    or a
    ret z
    ld hl,FAR_LEFT
    ld (rs_ax),hl
    ld b,a
    xor a
    ld (rs_al),a
    ld (raster.r+1),a           ; no slope: r = 0 ...
    inc a
    ld (raster.n1+1),a          ; ... against n = 1
    ld (raster.n2+1),a
    ld hl,MARK_LINE
    ld (rs_step),hl
    ld de,0
    ld c,e
    push de
    push bc
    call rs_pattern
    xor a
    call rs_record
    ld bc,(rs_step)
    exx
    pop bc
    pop de
    ld hl,(rs_ax)
    jp raster.line

; Patches colour rs_c's pattern into the raster loop.
rs_pattern:
    ld a,(rs_c)
    ld hl,patterns
    add a,l
    ld l,a
    ld a,(hl)
    ld (raster.pattern1+1),a
    ld (raster.pattern2+1),a
    ret

; Lines 80 to 127 are above the view, but an edge running off the top still
; writes their records: that saves the raster loop a test. They are marked
; full once, here, and never cleared.
markers_init:
    ld hl,MARKERS + VIEW_LINES * MARK_LINE
    ld de,MARK_LINE
    ld b,MARK_LINES - VIEW_LINES
.full:
    ld (hl),MARK_LINE
    add hl,de
    djnz .full
    ret

; HL = the marker record of line A. Uses DE.
rs_record:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,MARKERS
    add hl,de
    ret

; HL = HL / C, A = the remainder, for C below 128. Most edges cross a line
; or two and move less than 256 pixels, so those take short cuts.
div16_8:
    ld a,c
    dec a
    jr nz,.divide
    ret                         ; n = 1: q = |dx|, r = 0 (A is 0)
.divide:
    ld b,16
    ld a,h
    or a
    jr nz,.wide
    ld h,l                      ; below 256: eight bits are enough
    ld l,a
    ld b,8
.wide:
    xor a
.bit:
    add hl,hl
    rla
    cp c
    jr c,.zero
    sub c
    inc l
.zero:
    djnz .bit
    ret

eg_left_side:   db 0
eg_field:       db 0
eg_colour:      db 0
eg_points:      db 0
eg_pc:          db 0
eg_low:         db 0
eg_low_colour:  db 0
rs_ax:      dw 0
rs_al:      db 0
rs_bx:      dw 0
rs_bl:      db 0
rs_c:       db 0
rs_n:       db 0
rs_more:    db 0
rs_step:    dw 0
