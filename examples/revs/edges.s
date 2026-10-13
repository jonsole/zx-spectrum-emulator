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
    call edges_left
    call edges_far_end
    jp edges_right

; The far end of the road. Each verge's list starts 32 segments ahead, and
; where the left one's first point is higher on the screen than the right
; one's -- on a bend, or by a line of rounding on a straight -- the lines
; between have the left verge's road edge and nothing to end the road: it
; ran on to the right of the screen, a streak along the horizon. The road
; ends at the line between the two first points, so that is an edge too,
; with grass to its right, on the lines above the right verge's first one.
; With the right higher, those lines start as grass and have no road to end.
edges_far_end:
    ld a,(vl_count)
    or a
    ret z
    ld a,(vr_count)
    or a
    ret z
    ld a,(VERGE_R+4)
    ld e,a                      ; the right's first line
    ld a,(VERGE_L+4)
    bit 7,a
    ret nz                      ; the left's is under the view
    sub e
    ret z
    ret c                       ; the right's is higher (or under the view)
    ld (raster.n+1),a
    ld (raster_r_n+1),a
    ld (raster_l_n+1),a
    ld b,a                      ; lines: from the left's first, not the right's
    dec a
    srl a
    ld c,a                      ; the error's start
    ld (rs_lines),bc
    ld a,(VERGE_L+4)
    call rs_record
    push hl
    exx
    pop hl
    ld bc,-MARK_LINE
    exx
    ld hl,(VERGE_L)             ; from the left's road edge
    ld de,(VERGE_R)             ; to the right's
    ld a,(patterns+COLOUR_GRASS)
    jp raster

; One side's two edges through its points, far to near: the verge's outside
; edge and its track edge go through the same points on the same lines, so
; a segment is set up once for both, and only each edge's own division and
; lines are done twice. A copy for each side, so its list and fields are
; constants and its state lives in its own instructions, patched as it goes.
; A is the edge drawn first (the further left), B the second: FA and FB are
; the x each takes from a point (0 for the verge's track edge, 2 for its
; outside), and CB the colour to the right of B; to the right of A is each
; point's own verge colour. LEFT is 1 on the left. Each line segment
; between two points takes the nearer point's colour.
;
; A side's last point can be below the view (see verges.s): its line is
; then negative, and the stretch to it is stepped as any other but stops at
; line 0 (.below), so the verge reaches the bottom of the view at the slope
; it really has there.
;
; A segment's last line is the next one's first, so the marker record
; pointer (HL') runs on from one segment into the next, and each edge's x
; where the last segment ended is kept in the instruction that loads it
; (.pxa, .pxb), so a point's x is read from the list only once.
;
; This is where most of the edge stage's time went before the lines
; themselves: segments are short (about four lines on average), so their
; set-up costs as much as the lines do.
    MACRO SIDE SNAME, SLIST, SCOUNT, FA, FB, CB, SLEFT
SNAME:
    ld a,(SCOUNT)
    or a
    ret z
    ld (.left+1),a
    ld a,(SLIST+4)              ; the first point's line
    ld (.low+1),a
    ld a,(SLIST+5)
    ld (eg_low_colour),a
    ld hl,(SLIST+FA)
    ld (.pxa+1),hl
    ld hl,(SLIST+FB)
    ld (.pxb+1),hl
    ld a,(.low+1)
    call rs_record
    push hl
    exx
    pop hl                      ; HL' = the first line's record
    exx
    ld hl,SLIST
    ld (.ptr+1),hl
.next:
.left:
    ld a,0                      ; patched: the points still to come, plus one
    dec a
    jp z,.end
    ld (.left+1),a
    ld d,a                      ; 1 for the side's last segment
.ptr:
    ld hl,0                     ; patched: the last point's entry
    ld a,l
    add a,ENTRY
    ld l,a
    ld (.ptr+1),hl              ; this point's
    or 4
    ld l,a
    ld b,(hl)                   ; its line
    inc l
    ld a,(hl)                   ; its colour
    add a,low patterns
    ld c,a
    ld a,b
.low:
    cp 0                        ; patched: the lowest line so far
    jr nc,.not_lower            ; ties keep the first
    ld (.low+1),a
    ld a,c
    sub low patterns
    ld (eg_low_colour),a
    ld a,b
.not_lower:
    ld b,high patterns
    ld e,a
    ld a,(bc)
    ld (.pat_a+1),a             ; the segment's colour, as a pattern
    ld a,l
    sub ENTRY + 1
    ld l,a                      ; the last point's line
    bit 7,e
    jp nz,.below                ; this one is under the view
    ld a,e
    sub (hl)                    ; lines, up or down
    jp z,.level
    exx
    ld bc,MARK_LINE
    jr nc,.up
    ld bc,-MARK_LINE
    exx
    neg
    jr .count
.up:
    exx
.count:
    ld (raster.n+1),a
    ld (raster_r_n+1),a
    ld (raster_l_n+1),a
    ld b,a                      ; lines: n
    dec a
    srl a
    ld c,a                      ; the error's start: (n - 1) / 2, as raster
    dec d
    jr nz,.not_last
    inc b                       ; the last segment's last line too
.not_last:
.lines:
    ld (rs_lines),bc
    exx
    ld (.rec+1),hl              ; both edges start from this record
    exx
    ld a,l
    add a,ENTRY - 4 + FA
    ld l,a
    ld e,(hl)
    inc l
    ld d,(hl)                   ; edge A's x at this point
.pxa:
    ld hl,0                     ; patched: and at the last
    ld (.pxa+1),de
.pat_a:
    ld a,0                      ; patched: the segment's pattern
    call raster
    exx
.rec:
    ld hl,0                     ; patched: back to the segment's first line
    exx
    ld hl,(.ptr+1)
    ld a,l
    or FB
    ld l,a
    ld e,(hl)
    inc l
    ld d,(hl)                   ; edge B's x at this point
.pxb:
    ld hl,0                     ; patched: and at the last
    ld (.pxb+1),de
    ld a,(patterns+CB)
    call raster
    jp .next
.below:
    ; The side's last point, under the view: n is the lines down to it, but
    ; only those down to line 0 are marked.
    ld a,(hl)
    ld b,a
    inc b                       ; lines: the last point's, down to line 0
    sub e                       ; n, at most 127 (verges.s sees to that)
    exx
    ld bc,-MARK_LINE
    exx
    ld (raster.n+1),a
    ld (raster_r_n+1),a
    ld (raster_l_n+1),a
    dec a
    srl a
    ld c,a                      ; the error's start
    xor a
    ld (.low+1),a               ; the edges reach the bottom
    jp .lines
.level:
    ; Level: this point becomes the last one, and if it ends the side, one
    ; marker for each edge at it, on the line HL' is already on.
    ld a,l
    add a,ENTRY - 4 + FA
    ld l,a
    ld e,(hl)
    inc l
    ld d,(hl)
    ld (.pxa+1),de
    ld a,l
    add a,FB - FA - 1
    ld l,a
    ld e,(hl)
    inc l
    ld d,(hl)
    ld (.pxb+1),de
    ld a,(.left+1)
    dec a
    jp nz,.next
    exx
    ld (.rec_level+1),hl
    exx
    ld hl,(.pxa+1)
    ld a,(.pat_a+1)
    call raster_mark
    exx
.rec_level:
    ld hl,0                     ; patched
    exx
    ld hl,(.pxb+1)
    ld a,(patterns+CB)
    call raster_mark
    jp .next
.end:
    IF SLEFT
    ; Below its lowest point an edge on the left has gone off the left of
    ; the screen, where it still decides the colour those lines start with.
    ld a,(eg_low_colour)
    call rs_pattern
    ld c,a
    ld a,(.low+1)
    call raster_far_left
    ld a,(patterns+CB)
    ld c,a
    ld a,(.low+1)
    jp raster_far_left
    ELSE
    ret
    ENDIF
    ENDM

edges_left:                     ; the left verge: outside edge (verge colours
                                ; to its right), then track edge (road)
    SIDE edges_l, VERGE_L, vl_count, 2, 0, COLOUR_ROAD, 1
edges_right:                    ; the right verge: track edge (verge
                                ; colours), then outside edge (grass)
    SIDE edges_r, VERGE_R, vr_count, 0, 2, COLOUR_GRASS, 0

; Marks the lines from x = HL to x = DE in pattern A, from the record at
; HL': rs_lines of them (B) with the error starting at C, and n, the lines
; the segment crosses, patched in by SIDE. One marker per line, at the
; line's x rounded to the nearest pixel, stepped Bresenham-fashion from a
; single division. Rightwards and leftwards have a loop each, so that
; neither the direction nor the test for going off the right is patched in.
raster:
    ex af,af'                   ; the pattern, until the direction is known
    ex de,hl
    or a
    sbc hl,de                   ; dx, and DE = the start x, which
.n:                             ; div16_8 leaves alone
    ld c,0                      ; patched: n
    bit 7,h
    jr nz,.leftwards
    call div16_8                ; dx = q * n + r
    ld (raster_r_r+1),a
    ex af,af'
    ld (raster_r_p1+1),a
    ld (raster_r_p2+1),a
    ex de,hl                    ; DE = q, HL = the start x
    ld bc,(rs_lines)
    jp raster_r
.leftwards:
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    call div16_8                ; -dx = q * n + r
    ld (raster_l_r+1),a
    ex af,af'
    ld (raster_l_p1+1),a
    ld (raster_l_p2+1),a
    ex de,hl                    ; HL = the start x
    xor a
    sub e
    ld e,a
    sbc a,a
    sub d
    ld d,a                      ; DE = -q
    ld bc,(rs_lines)
    jp raster_l

; One marker in pattern A at x = HL, on the line of the record at HL'.
raster_mark:
    ld (raster_r_p1+1),a
    ld (raster_r_p2+1),a
    ld b,1
    ld de,0
    jp raster_r

; The loop is the hottest code in the edge stage, so it runs in registers
; with its constants patched into its instructions: main set HL = x,
; DE = the whole-pixel step per line (negative going left), C = the error
; term, B = lines left; alternate set HL' = the line's marker record,
; BC' = +-32 to the next record, DE' for the marker.
;
; The error counts down: it starts at (n - 1) / 2 and loses r a line, and
; when it would go below zero it gains n back and x moves one more pixel.
; That is the usual error that starts at n / 2 and gains r, carrying at n,
; counted from the other end: n - 1 less it. Down, the carry is the SUB's
; own borrow, with no compare.
    MACRO RASTER_LOOP RNAME, RIGHTWARD
RNAME:
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
RNAME_p1:
    ld (hl),0                   ; patched: the colour's pattern
    dec l
    ld (hl),d
    ld l,e
.next:
    add hl,bc
    exx
    ld a,c
RNAME_r:
    sub 0                       ; patched: r, the remainder
    jr nc,.no_carry
RNAME_n:
    add a,0                     ; patched: n
    IF RIGHTWARD
    inc hl
    ELSE
    dec hl
    ENDIF
.no_carry:
    ld c,a
    add hl,de
    djnz .line
    ret
.off_screen:
    jp m,.left
    IF RIGHTWARD
    ; Off the right: nothing to the right of it. Heading right, it stays off
    ; for the rest of the stretch, so only the record pointer goes on, to
    ; where the next stretch starts.
.gone_right:
    exx
    add hl,bc
    exx
    djnz .gone_right
    ret
    ELSE
    exx
    jr .next
    ENDIF
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
RNAME_p2:
    ld (hl),0                   ; patched: the colour's pattern
.restore:
    ld l,0                      ; patched: back to the record's start
    jr .next
    ENDM

    RASTER_LOOP raster_r, 1
    RASTER_LOOP raster_l, 0

; Lines 0 to A - 1 start with pattern C: they lie below an edge that has
; gone off the left of the screen. As a marker that far left (FAR_LEFT) it
; beats only no marker at all, or another like it -- a real one off the left
; is nearer -- so a line takes it if its starting x's high byte is still
; $80.
raster_far_left:
    cp VIEW_LINES
    jr c,.some
    ld a,VIEW_LINES
.some:
    or a
    ret z
    ld b,a
    ld hl,MARKERS+3             ; line 0's starting x, high byte
    ld de,MARK_LINE
.line:
    ld a,(hl)
    cp high FAR_LEFT
    jr nz,.taken
    dec l
    ld (hl),low FAR_LEFT
    dec l
    ld (hl),c
    inc l
    inc l
.taken:
    add hl,de
    djnz .line
    ret

; A = colour A's pattern.
rs_pattern:
    ld hl,patterns
    add a,l
    ld l,a
    ld a,(hl)
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

; HL = HL / C, A = the remainder, for C below 128. Most segments cross two
; to four lines, so those divisors have short cuts: shifts for 2 and 4, a
; table for 3. The rest are unrolled a bit at a time, eight bits for an x
; that moves less than 256 pixels. Uses B, and leaves DE alone: raster
; keeps the start x there.
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
    cp 5
    jr nc,.general
    dec a
    ret z                       ; n = 1: q = |dx|, r = 0 (A is 0)
    dec a
    jr z,.two
    dec a
    jr z,.three
    ld a,l                      ; four
    and 3
    srl h
    rr l
    srl h
    rr l
    ret
.two:
    ld a,l
    and 1
    srl h
    rr l
    ret
.three:
    or h
    jr nz,.general
    ld b,l
    ld h,high tbl_div3
    ld l,(hl)                   ; q
    ld h,a                      ; 0
    ld a,b
    sub l
    sub l
    sub l                       ; r = x - 3q
    ret
.general:
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

rs_lines:   dw 0                ; the lines to mark, then the error's start
eg_low_colour:  db 0            ; the colour at a side's lowest point
