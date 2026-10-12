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
    call edge_left_outside
    call edge_left_track
    call edge_right_track
    jp edge_right_outside

; One edge through its side's points, far to near: a copy for each of the
; four, so its list, field and colour are constants. LIST and COUNT are the
; side's list and its length, FIELD the x to take from each point (0 for
; the verge's track edge, 2 for its outside), COLOUR the colour to the
; right of the edge or -1 for each point's own verge colour, and LEFT is 1
; for an edge on the left. Each line segment between two points takes the
; nearer point's colour.
;
; A segment's last line is the next one's first, so the marker record
; pointer (HL') runs on from one segment into the next.
    MACRO EDGE ENAME, ELIST, ECOUNT, EFIELD, ECOL, ELEFT
ENAME:
    ld a,(ECOUNT)
    or a
    ret z
    ld b,a
    ld hl,ELIST
    call .read
    ld (rs_ax),de
    ld (rs_al),a
    ld (eg_low),a
    ld e,a
    ld a,c
    ld (eg_low_colour),a
    ld a,e
    push hl
    call rs_record
    push hl
    exx
    pop hl                      ; HL' = the first line's record
    exx
    pop hl
.next:
    dec b
    jr z,.end
    ld a,l
    add a,ENTRY
    ld l,a
    push hl
    push bc
    call .read
    ld hl,eg_low
    cp (hl)
    jr nc,.not_lower            ; ties keep the first
    ld (hl),a
    ld l,a
    ld a,c
    ld (eg_low_colour),a
    ld a,l
.not_lower:
    IF ECOL < 0
    ld l,a                      ; this segment's colour: the nearer point's
    ld a,c
    add a,low patterns
    ld c,a
    ld b,high patterns
    ld a,(bc)
    ld (raster.pattern1+1),a
    ld (raster.pattern2+1),a
    ld a,l
    ENDIF
    pop bc
    push bc
    call raster
    pop bc
    pop hl
    jr .next
.end:
    IF ELEFT
    ; Below its lowest point an edge on the left has gone off the left of
    ; the screen, where it still decides the colour those lines start with.
    ld a,(eg_low_colour)
    call rs_pattern
    ld a,(eg_low)
    jp raster_far_left
    ELSE
    ret
    ENDIF
; The point at HL: DE = its x on this edge, A = its line, C = the colour.
; Entries are 8-byte aligned, so only L moves, and HL is put back.
.read:
    ld a,l
    or EFIELD
    ld l,a
    ld e,(hl)
    inc l
    ld d,(hl)
    and $F8
    or 4
    ld l,a
    IF ECOL < 0
    inc l
    ld c,(hl)
    dec l
    ELSE
    ld c,ECOL
    ENDIF
    ld a,(hl)
    dec l
    dec l
    dec l
    dec l
    ret
    ENDM

edge_left_outside:              ; the left verge's outside edge: verge
                                ; colours to its right
    EDGE edge_lo, VERGE_L, vl_count, 2, -1, 1
edge_left_track:                ; the left verge's track edge: road
    ld a,COLOUR_ROAD
    call rs_pattern
    EDGE edge_lt, VERGE_L, vl_count, 0, COLOUR_ROAD, 1
edge_right_track:               ; the right verge's track edge: verge
    EDGE edge_rt, VERGE_R, vr_count, 0, -1, 0
edge_right_outside:             ; the right verge's outside edge: grass
    ld a,COLOUR_GRASS
    call rs_pattern
    EDGE edge_ro, VERGE_R, vr_count, 2, COLOUR_GRASS, 0

; Marks the lines from (rs_ax, rs_al) to (DE, A), the next point, then makes
; that point the start of the next segment: one marker per line, at the
; line's x rounded to the nearest pixel, stepped Bresenham-fashion from a
; single division, in the pattern last patched in. HL' is the first line's
; record. The last line is left to the next segment, which starts there at
; the same x and whose colour would win anyway, unless B is 1: this is the
; edge's last segment.
;
; The loop is the hottest code in the edge stage, so it runs in registers
; with its constants patched into its instructions: main set HL = x,
; DE = the whole-pixel step per line (negative going left), C = the error
; term, B = lines left; alternate set HL' = the line's marker record,
; BC' = +-32 to the next record, DE' for the marker.
raster:
    dec b
    ld ixl,b                    ; zero for the edge's last segment
    ld c,a
    ld hl,rs_al
    sub (hl)                    ; lines, up or down
    ld (hl),c                   ; the next segment starts at this one's end
    ld hl,(rs_ax)
    ld (rs_ax),de
    jr z,.level
    exx
    ld bc,MARK_LINE
    exx
    jr nc,.up
    neg
    exx
    ld bc,-MARK_LINE
    exx
.up:
    ld c,a                      ; n
    ld (.n1+1),a
    ld (.n2+1),a
    ex de,hl
    push de                     ; the start x
    or a
    sbc hl,de                   ; dx
    bit 7,h
    jr nz,.leftwards
    call div16_8                ; dx = q * n + r
    ld (.r+1),a
    ld a,$23                    ; INC HL
    ld (.carry),a
    ex de,hl                    ; DE = q
    jr .count
.leftwards:
    ex de,hl
    ld hl,0
    or a
    sbc hl,de
    call div16_8                ; -dx = q * n + r
    ld (.r+1),a
    ld a,$2B                    ; DEC HL
    ld (.carry),a
    ex de,hl
    ld hl,0
    or a
    sbc hl,de
    ex de,hl                    ; DE = -q
.count:
    pop hl                      ; the start x
    ld b,c
    ld a,ixl
    or a
    jr nz,.lines
    inc b                       ; the last segment's last line too
.lines:
    srl c                       ; the error starts at n / 2: rounding
    jr .line
.level:
    ; Level: one marker, for the nearer point, if this is the last segment.
    ld a,ixl
    or a
    ret nz
    ex de,hl
    ld b,1
    ld de,0
    ld c,e
    inc a
    ld (.n1+1),a
    ld (.n2+1),a
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

; Lines 0 to A - 1 start with the pattern rs_pattern last patched in: they
; lie below an edge that has gone off the left of the screen.
raster_far_left:
    cp VIEW_LINES
    jr c,.some
    ld a,VIEW_LINES
.some:
    or a
    ret z
    ld b,a
    xor a
    ld (raster.r+1),a           ; no slope: r = 0 ...
    inc a
    ld (raster.n1+1),a          ; ... against n = 1
    ld (raster.n2+1),a
    exx
    ld hl,MARKERS
    ld bc,MARK_LINE
    exx
    ld hl,FAR_LEFT
    ld de,0
    ld c,e
    jp raster.line

; Patches colour A's pattern into the raster loop.
rs_pattern:
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

; HL = HL / C, A = the remainder, for C below 128: unrolled, a bit at a
; time. Most edges cross a line or two and move less than 256 pixels, so
; those take short cuts.
    MACRO DIV_BIT
    add hl,hl
    rla
    cp c
    jr c,.zero@
    sub c
    inc l
.zero@:
    ENDM

div16_8:
    ld a,c
    dec a
    ret z                       ; n = 1: q = |dx|, r = 0 (A is 0)
    xor a
    or h
    jr z,.narrow
    xor a
    REPT 8
    DIV_BIT
    ENDR
    jr .low
.narrow:
    ld h,l                      ; below 256: eight bits are enough
    ld l,a
.low:
    REPT 8
    DIV_BIT
    ENDR
    ret

eg_low:         db 0
eg_low_colour:  db 0
rs_ax:      dw 0
rs_al:      db 0
