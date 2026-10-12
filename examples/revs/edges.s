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
    jp edges_right

; One side's two edges through its points, far to near: the verge's outside
; edge and its track edge go through the same points on the same lines, so
; a point is read and a segment set up once for both, and only each edge's
; own division and lines are done twice. A copy for each side, so its list
; and fields are constants. A is the edge drawn first (the further left),
; B the second: FA and FB are the x each takes from a point (0 for the
; verge's track edge, 2 for its outside), CA and CB the colour to the
; right of each, -1 for each point's own verge colour. LEFT is 1 on the
; left. Each line segment between two points takes the nearer point's
; colour.
;
; A segment's last line is the next one's first, so the marker record
; pointer (HL') runs on from one segment into the next.
    MACRO SIDE SNAME, SLIST, SCOUNT, FA, CA, FB, CB, SLEFT
SNAME:
    ld a,(SCOUNT)
    or a
    ret z
    ld b,a
    ld hl,SLIST
    call .read
    ld (rs_axa),de
    ld de,(rs_bxb)
    ld (rs_axb),de
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
    ld l,a
    ld a,c
    add a,low patterns
    ld c,a
    ld b,high patterns
    ld a,(bc)
    ld (rs_pat_a),a
    ld a,l
    pop bc
    push bc
    call raster2
    pop bc
    pop hl
    jr .next
.end:
    IF SLEFT
    ; Below its lowest point an edge on the left has gone off the left of
    ; the screen, where it still decides the colour those lines start with.
    ld a,(eg_low_colour)
    call rs_pattern
    ld a,(eg_low)
    call raster_far_left
    ld a,CB
    call rs_pattern
    ld a,(eg_low)
    jp raster_far_left
    ELSE
    ret
    ENDIF
; The point at HL: DE = edge A's x, rs_bxb = edge B's, A = the line, C =
; edge A's colour. Entries are 8-byte aligned, so only L moves, and HL is
; put back.
.read:
    ld a,l
    or FB
    ld l,a
    ld e,(hl)
    inc l
    ld d,(hl)
    ld (rs_bxb),de
    xor FB ^ FA                 ; from edge B's x to edge A's
    ld l,a
    ld e,(hl)
    inc l
    ld d,(hl)
    and $F8
    or 4
    ld l,a
    IF CA < 0
    inc l
    ld c,(hl)
    dec l
    ELSE
    ld c,CA
    ENDIF
    ld a,(hl)
    dec l
    dec l
    dec l
    dec l
    ret
    ENDM

edges_left:                     ; the left verge: outside edge (verge colours
                                ; to its right), then track edge (road)
    ld a,(patterns+COLOUR_ROAD)
    ld (rs_pat_b),a
    SIDE edges_l, VERGE_L, vl_count, 2, -1, 0, COLOUR_ROAD, 1
edges_right:                    ; the right verge: track edge (verge
                                ; colours), then outside edge (grass)
    ld a,(patterns+COLOUR_GRASS)
    ld (rs_pat_b),a
    SIDE edges_r, VERGE_R, vr_count, 0, -1, 2, COLOUR_GRASS, 0

; Both of a side's edges from (rs_axa, rs_axb, rs_al) to (DE, rs_bxb, A),
; the next point, then that point as the start of the next segment. B is
; the points left: 1 for the side's last segment, whose last line is
; marked too (otherwise the next segment's first line is the same line).
raster2:
    dec b
    ld ixl,b                    ; zero for the side's last segment
    ld c,a
    ld hl,rs_al
    sub (hl)                    ; lines, up or down
    ld (hl),c                   ; the next segment starts at this one's end
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
    ld (raster.n1+1),a
    ld (raster.n2+1),a
    ld c,a                      ; n
    ld b,a
    ld a,ixl
    or a
    jr nz,.lines
    inc b                       ; the last segment's last line too
.lines:
    ld (rs_lines),bc
    exx
    ld (rs_rec),hl              ; both edges start from this record
    exx
    ld hl,(rs_axa)
    ld (rs_axa),de
    ld a,(rs_pat_a)
    call raster
    ld hl,(rs_rec)
    push hl
    exx
    pop hl
    exx
    ld hl,(rs_axb)
    ld de,(rs_bxb)
    ld (rs_axb),de
    ld a,(rs_pat_b)
    jp raster
.level:
    ; Level: one marker for each edge at the nearer point, if this is the
    ; last segment.
    ld (rs_axa),de
    ld hl,(rs_bxb)
    ld (rs_axb),hl
    ld a,ixl
    or a
    ret nz
    inc a
    ld (raster.n1+1),a
    ld (raster.n2+1),a
    ld (raster.r+1),a           ; the step can't matter: one line
    exx
    ld (rs_rec),hl
    exx
    ld a,(rs_pat_a)
    call rs_set_pattern
    ex de,hl
    ld b,1
    ld de,0
    ld c,e
    call raster.line
    ld hl,(rs_rec)
    push hl
    exx
    pop hl
    exx
    ld a,(rs_pat_b)
    call rs_set_pattern
    ld hl,(rs_bxb)
    ld b,1
    ld de,0
    ld c,e
    jp raster.line

; Marks the lines from x = HL to x = DE, rs_lines (B lines, n = C) of them,
; in pattern A, from the record at HL': one marker per line, at the line's x
; rounded to the nearest pixel, stepped Bresenham-fashion from a single
; division.
;
; The loop is the hottest code in the edge stage, so it runs in registers
; with its constants patched into its instructions: main set HL = x,
; DE = the whole-pixel step per line (negative going left), C = the error
; term, B = lines left; alternate set HL' = the line's marker record,
; BC' = +-32 to the next record, DE' for the marker.
raster:
    ld (.pattern1+1),a          ; as rs_set_pattern, without the call
    ld (.pattern2+1),a
    ex de,hl
    push de                     ; the start x
    or a
    sbc hl,de                   ; dx
    ld a,(rs_lines)
    ld c,a                      ; n
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
    ld bc,(rs_lines)
    srl c                       ; the error starts at n / 2: rounding
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
    ; Off the right: nothing to the right of it. Heading right, it stays off
    ; for the rest of the stretch, so only the record pointer goes on, to
    ; where the next stretch starts.
    ld a,(.carry)
    cp $23                      ; INC HL: heading right
    jr z,.gone_right
    exx
    jr .next
.gone_right:
    exx
    add hl,bc
    exx
    djnz .gone_right
    ret
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
; lie below an edge that has gone off the left of the screen. As a marker
; that far left (FAR_LEFT) it beats only no marker at all, or another like
; it -- a real one off the left is nearer -- so a line takes it if its
; starting x's high byte is still $80.
raster_far_left:
    cp VIEW_LINES
    jr c,.some
    ld a,VIEW_LINES
.some:
    or a
    ret z
    ld b,a
    ld a,(raster.pattern2+1)
    ld c,a
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

; Patches colour A's pattern into the raster loop.
rs_pattern:
    ld hl,patterns
    add a,l
    ld l,a
    ld a,(hl)
; Patches pattern A into the raster loop.
rs_set_pattern:
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

; HL = HL / C, A = the remainder, for C below 128. Most segments cross two
; to four lines, so those divisors have short cuts: shifts for 2 and 4, a
; table for 3. The rest are unrolled a bit at a time, eight bits for an x
; that moves less than 256 pixels. Uses DE.
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
    ld e,l
    ld d,high tbl_div3
    ld a,(de)
    ld l,a                      ; q, and H is 0
    ld a,e
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

eg_low:         db 0
rs_axa:     dw 0                ; where the side's two edges are
rs_axb:     dw 0
rs_bxb:     dw 0                ; where edge B goes next
rs_pat_a:   db 0
rs_pat_b:   db 0
rs_lines:   dw 0                ; n, then the lines to mark
rs_rec:     dw 0
eg_low_colour:  db 0
rs_al:      db 0
