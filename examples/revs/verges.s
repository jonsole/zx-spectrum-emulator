; The verge point lists, after the BBC's GetSegmentAngles and
; GetVergeAndMarkers: for each side of the track, the points the edges are
; drawn through, far to near.
;
; Each side starts 32 segments ahead of the camera and steps back by 13
; and 7 segments, then one at a time, sixteen points in all -- big steps far
; away, where segments are a pixel or two apart, and small ones close up.
; The kerb's stripes, a segment each, can only be drawn where the points are
; a segment apart, so the single steps start 12 segments out, about as far
; as a stripe is still a line tall. The BBC steps 13, 6 and 3 and starts
; them at 9, with two more points in the middle distance and four behind the
; camera, where the view hardly ever reaches.
; A side's list stops at the first point that cannot be seen: below the
; bottom of the view, too close to have a pitch angle, or -- once the points
; have started coming back towards the camera, past the closest one --
; outside the field of view. That point is kept all the same, as the side's
; last, with its own x, width and colour and its line even when that is
; below the view: the last stretch heads for it, and edges.s stops it at
; the bottom of the view. The BBC instead tries a point a quarter of the way
; there with the last point's width and colour, and hides what that leaves
; behind its dashboard; here that guess changed from one update to the next
; as points came and went, and the kerb's stripes, width and edge jumped
; close to the camera. A point's line can be negative only for a side's
; last point.
;
; Both sides walk the same segments, so they are done together, a segment
; at a time: the segment's flags, its height and the log of its height
; above the eye are worked out once for the two.
;
; Each entry is ENTRY bytes:
;   +0  x of the verge's track edge (signed 16-bit screen x, 128 = ahead)
;   +2  x of the verge's outside edge, where the grass starts
;   +4  the track line, 0..127 (79 is the top of the view)
;   +5  the verge mark's colour: 2 black, 3 red, 4 white
;
; Driving clockwise, the right verge is the inner one (SEG_XI, SEG_ZI) and
; the left the outer.

VERGE_R     equ $BA00
VERGE_L     equ $BB00
ENTRY       equ 8
SEG_AHEAD   equ 32              ; the BBC's first point, 32 segments ahead
FOV_YAW     equ 20              ; half the field of view, in yaw high bytes
POINTS      equ 16

; The lists are built in two goes: verges_begin does the first VB_EARLY
; segments, straight after the frame interrupt while compose waits for the
; beam, and verges_finish the rest. Everything the loop needs between the
; two is in memory.
VB_EARLY    equ 4

; One segment's points on both sides: its flags, verge width, colours,
; height and the log of its height above the eye, worked out once for the
; two, then each live side's point. UNIT is 1 for the near points, a
; segment apart, and 0 for the far ones, E segments back from the last.
; Leaves Z set when both lists have ended. A macro rather than a routine
; with the step in a register, so that the near points, which are most of
; them, have no step to look up or test.
    MACRO VB_SEGMENT UNIT
    ld hl,(vb_seg)
    IF UNIT
    dec hl                      ; back a segment, round the track
    bit 7,h
    jr z,.stepped
    ld h,high (TRACK_LEN - 1)
    ELSE
    ld a,l                      ; back E segments, round the track
    sub e
    ld l,a
    jr nc,.stepped
    dec h
    jp p,.stepped
    ld h,high (TRACK_LEN - 1)
    ENDIF
.stepped:
    ld (vb_seg),hl
    ; The segment's flags: vergeScale is 5 for black verges (25 units
    ; wide), 4 for red ones on a curve or on both sides (50), 3 for a
    ; straight's red verge (100).
    ld de,SEG_FLAGS
    add hl,de
    ld a,(hl)
    ld (vb_flags),a
    ld c,a
    ld b,5
    and %110
    jr z,.scale
    ld b,4
    cp %110
    jr z,.scale
    bit 0,c
    jr nz,.scale
    ld b,3
.scale:
    ld a,high LOG2_WIDTH        ; the width's log, less the distance's to come:
    sub b                       ; 256 * (23 - log2 40 - vergeScale)
    ld h,a
    ld l,low LOG2_WIDTH
    ld (vb_wlog),hl
    ; The marks alternate a segment at a time: odd ones white, even ones
    ; red or black. But a far point -- 13 and 7 segments apart -- colours
    ; a stretch with several marks in it, and by its own segment's parity
    ; it would swap between white and red every time the camera passed a
    ; segment. Those stretches take the red or black, so the distance
    ; holds still while the marks close enough to draw one by one go past.
    IF UNIT
    ld a,(vb_seg)
    rrca
    ld bc,$0404
    jr c,.colours
    ENDIF
    ld a,(vb_flags)
    ld bc,$0202
    bit 2,a
    jr z,.right_black
    inc c
.right_black:
    bit 1,a
    jr z,.colours
    inc b
.colours:
    ld (vb_colours),bc          ; C for the right, B for the left
    ; Its height, which both verges share, and its log above the eye.
    ld hl,(vb_seg)
    add hl,hl
    ld (vb_off),hl
    ld de,SEG_YI
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ex de,hl
    ld de,(cam_y)
    or a
    sbc hl,de
    ; As pitch_height, written out.
    ld a,h
    ld (pa_dysign),a
    bit 7,h
    jr z,.above
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
.above:
    ld a,h
    or l
    jr z,.level
    ex de,hl
    LOG16
    ld a,h
    add a,5                     ; 256 / 8 = 2 ^ 5
    ld h,a
    jr .height
.level:
    ld hl,LOG_ZERO
.height:
    ld (pa_logdy),hl
    ld a,(vr_live)
    or a
    call nz,vr_point
    ld a,(vl_live)
    or a
    call nz,vl_point
    ld a,(vr_live)
    ld hl,vl_live
    or (hl)
    ENDM

; The far points, 32, 19 and 12 segments ahead, then the first near ones
; up to VB_EARLY in all; verges_finish does the rest after compose. The
; steps -- 0, 13, 7, then one at a time, POINTS in all -- are view_model.py's
; SEGMENT_STEPS.
    ASSERT VB_EARLY > 3
verges_begin:
    ld hl,VERGE_R
    ld (vr_list),hl
    ld hl,VERGE_L
    ld (vl_list),hl
    ld hl,$7FFF
    ld (vr_close),hl
    ld (vl_close),hl
    xor a
    ld (vr_count),a
    ld (vl_count),a
    inc a
    ld (vr_live),a
    ld (vl_live),a
    ld hl,(cam_seg)
    ld de,SEG_AHEAD
    call seg_add
    ld (vb_seg),hl
    ld e,0
    call vb_far
    ret z
    ld e,13
    call vb_far
    ret z
    ld e,7
    call vb_far
    ret z
    ld a,VB_EARLY - 3
    jr vb_near

; The rest of the lists, after compose: the near points still to come.
verges_finish:
    ld a,(vr_live)
    ld hl,vl_live
    or (hl)
    ret z
    ld a,POINTS - VB_EARLY

; A near points, a segment apart each, while either list goes on.
vb_near:
    ld (vb_left),a
.point:
    VB_SEGMENT 1
    ret z
    ld hl,vb_left
    dec (hl)
    jp nz,.point
    ret

; A far point, E segments back from the last.
vb_far:
    VB_SEGMENT 0
    ret

; The point at segment vb_seg on one side: appended to the side's list, or
; the end of the list. There is a copy for each side, so that its state has
; fixed addresses and its constants are in the instructions: NAME is the
; side's prefix, XARR and ZARR its coordinate arrays, COLOUR where the
; segment's verge colour for this side is, and LEFT is 1 where the verge's
; width is subtracted. The maths of yaw_angle, pitch_line and verge_width is
; written out in it rather than called: this runs 27 times a frame.
    MACRO VB_POINT NAME, XARR, ZARR, COLOUR, LEFT
NAME_point:
    ; The deltas from the camera: DE = dx, BC = dz.
    ld hl,(vb_off)
    ld de,XARR
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld bc,ZARR-XARR-1
    add hl,bc
    ld c,(hl)
    inc hl
    ld b,(hl)
NAME_cz:
    ld hl,0                     ; patched: cam_z (camera_update)
    ld a,c
    sub l
    ld c,a
    ld a,b
    sbc a,h
    ld b,a
NAME_cx:
    ld hl,0                     ; patched: cam_x
    ld a,e
    sub l
    ld e,a
    ld a,d
    sbc a,h
    ld d,a
    ; The yaw, as yaw_angle (which see), and the distance's log.
    ld h,0
    bit 7,d
    jr z,.xpos
    xor a
    sub e
    ld e,a
    sbc a,a
    sub d
    ld d,a
    inc h
.xpos:
    bit 7,b
    jr z,.zpos
    xor a
    sub c
    ld c,a
    sbc a,a
    sub b
    ld b,a
    inc h
    inc h
.zpos:
    ld a,e
    sub c
    ld a,d
    sbc a,b
    jr c,.zlarger
    set 2,h
    jr .larger_in_de
.zlarger:
    ld a,b
    ld b,d
    ld d,a
    ld a,c
    ld c,e
    ld e,a
.larger_in_de:
    ld a,h
    ex af,af'                   ; the octant
    LOG16
    push hl                     ; the larger delta's log
    ld a,b
    or c
    jr z,.t                     ; A = 0: on an axis
    ld d,b
    ld e,c
    LOG16
    pop de
    push de
    or a
    sbc hl,de
    ld a,h
    add a,8
    cp 8
    jr nc,.t_out
    add a,high tbl_exp8
    ld h,a
    ld a,(hl)
    jr .t
.t_out:
    rlca
    sbc a,a
    cpl
.t:
    ld l,a
    ld h,high tbl_logft
    ld e,(hl)
    ld d,0
    inc h
    ld c,(hl)
    inc h
    ld b,(hl)                   ; BC = the angle within the octant
    pop hl
    add hl,de
    push hl                     ; the distance's log, for after the yaw
    ex af,af'
    ld hl,yaw_angle.octants
    add a,l
    ld l,a
    ld a,(hl)
    ld h,b
    ld l,c
    bit 0,a
    jr z,.keep
    ld c,a
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    ld a,c
.keep:
    and $C0
    add a,h
    ld h,a
NAME_hd:
    ld de,0                     ; patched: cam_heading
    or a
    sbc hl,de
    ld (vb_rel),hl
    ; The closest point so far, visible or not: beyond it the list is
    ; coming back towards the camera and must stay in the field of view.
    ; C is 1 if this is the closest yet, 0 if the list is past it.
    pop de                      ; the distance's log
    ld hl,(NAME_close)
    or a
    sbc hl,de
    ld c,0
    jr c,.farther
    ld (NAME_close),de
    inc c
.farther:
    ; The pitch, as pitch_line: T = 256 * (|dy| / 8) / distance.
    ld hl,(pa_logdy)
    or a
    sbc hl,de
    bit 7,h
    jr nz,.level                ; T below 1
    ld a,h
    cp 7
    jp nc,.too_close            ; T >= 128
    add a,high tbl_exp8
    ld h,a
    ld b,(hl)
    jr .line
.level:
    ld b,0
.line:
    ld a,(pa_dysign)
    or a
    ld a,60
    jp m,.below
    add a,b
    jp p,.in_sight
    ld a,127                    ; above line 127: see pitch_line
    jr .in_sight
.below:
    sub b
    jp m,.last                  ; below the view
.in_sight:
    ld (vb_line),a
    dec c
    jr z,.in_view
    ld a,(vb_rel+1)
    or a
    jp p,.abs
    neg
.abs:
    cp FOV_YAW
    jp nc,.aside
.in_view:
    ; The verge's width on screen: 2 ^ (vb_wlog - the distance's log).
    ld hl,(vb_wlog)
    or a
    sbc hl,de
    ld a,h
    cp 8
    jr nc,.wide
    add a,high tbl_exp8
    ld h,a
    ld l,(hl)
    ld h,0
    jr .width
.wide:
    sub 7                       ; never negative here: the nearest point
    ld b,a                      ; can't be that far
    ld h,high tbl_exp8 + 7
    ld l,(hl)
    ld h,0
.double:
    add hl,hl
    djnz .double
.width:
    push hl
    ld hl,(vb_rel)
    YAW_TO_X
    pop de
    ld b,h
    ld c,l
    IF LEFT
    or a
    sbc hl,de
    ELSE
    add hl,de
    ENDIF
    ex de,hl
.store:
    ; BC = x, DE = the outside x, then vb_line and the colour.
    ld hl,(NAME_list)
    ld (hl),c
    inc l
    ld (hl),b
    inc l
    ld (hl),e
    inc l
    ld (hl),d
    inc l
    ld a,(vb_line)
    ld (hl),a
    inc l
    ld a,(COLOUR)
    ld (hl),a
    ld a,l
    add a,ENTRY-5
    ld l,a
    ld (NAME_list),hl
    ld hl,NAME_count
    inc (hl)
    ret
.aside:
    ld a,(vb_line)              ; in sight, but outside the field of view
    jr .last
.too_close:
    ; T >= 128: closer than the eye is high. Above the eye that is a cliff
    ; face, and the list just stops; below it, the line is far under the
    ; view: 60 - T, with T read from the antilogarithms' last page, or 255
    ; once it is past them, and held at -128 to fit a byte.
    ld a,(pa_dysign)
    or a
    jp p,.stop
    ld a,h
    cp 7
    ld a,255
    jr nz,.far_below
    ld h,high tbl_exp8 + 7
    ld a,(hl)
.far_below:
    cp 60 + 128
    ld b,a
    ld a,-128
    jr nc,.last
    ld a,60
    sub b
.last:
    ; This point ends the list, at line A, signed. It is kept all the same,
    ; with no more points after it, if there is a point before it to draw
    ; from. Its line is held to within 127 of that one's, so that the
    ; stretch between them is one edges.s can step.
    ld c,a
    xor a
    ld (NAME_live),a
    ld a,(NAME_count)
    or a
    ret z
    ld hl,(NAME_list)
    ld a,l
    sub ENTRY - 4
    ld l,a
    ld a,(hl)                   ; the last point's line
    sub 127
    xor $80
    ld b,a                      ; the lowest it may be, biased to compare
    ld a,c
    xor $80
    cp b
    jr nc,.line_ok
    ld a,b
.line_ok:
    xor $80
    ld (vb_line),a
    jp .in_view                 ; DE is still the distance's log
.stop:
    xor a
    ld (NAME_live),a
    ret

NAME_list:      dw 0
NAME_count:     db 0
NAME_live:      db 0
NAME_close:     dw 0            ; the log of the closest point's distance
    ENDM

    VB_POINT vr, SEG_XI, SEG_ZI, vb_colours, 0
    VB_POINT vl, SEG_XO, SEG_ZO, vb_colours+1, 1

vb_left:    db 0                ; near points still to do
vb_seg:     dw 0
vb_off:     dw 0
vb_flags:   db 0
vb_wlog:    dw 0
vb_colours: dw 0
vb_rel:     dw 0
vb_line:    db 0
