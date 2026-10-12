; The verge point lists, after the BBC's GetSegmentAngles and
; GetVergeAndMarkers: for each side of the track, the points the edges are
; drawn through, far to near.
;
; Each side starts 32 segments ahead of the camera and steps back by 13, 6
; and 3 segments, then one at a time, sixteen points in all -- big steps far
; away, where segments are a pixel or two apart, and small ones close up.
; A side's list stops at the first point that cannot be seen: below the
; bottom of the view, too close to have a pitch angle, or -- once the points
; have started coming back towards the camera, past the closest one --
; outside the field of view. Then it tries once more a quarter of the way
; from the last point it kept, so the edge reaches the bottom of the view.
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

verges_build:
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
    ld (vr_close_i),a
    ld (vl_close_i),a
    ld (vb_i),a
    inc a
    ld (vr_live),a
    ld (vl_live),a
    ld hl,(cam_seg)
    ld de,SEG_AHEAD
    call seg_add
    ld (vb_seg),hl
.point:
    ld a,(vb_i)
    ld e,a
    ld d,0
    ld hl,vb_steps
    add hl,de
    ld e,(hl)
    ld hl,(vb_seg)
    call seg_sub
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
    ld a,b
    ld (vb_scale),a
    ; Its height, which both verges share, and its log above the eye.
    ld hl,(vb_seg)
    add hl,hl
    ld (vb_off),hl
    ld de,SEG_YI
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (vb_py),de
    ex de,hl
    ld de,(cam_y)
    or a
    sbc hl,de
    call pitch_height
    ld a,(vr_live)
    or a
    call nz,vr_point
    ld a,(vl_live)
    or a
    call nz,vl_point
    ld a,(vr_live)
    ld hl,vl_live
    or (hl)
    ret z
    ld a,(vb_i)
    inc a
    ld (vb_i),a
    cp POINTS
    jr nz,.point
    ret

; The point at segment vb_seg on one side: appended to the side's list, or
; the end of the list. There is a copy for each side, so that its state has
; fixed addresses and its constants are in the instructions: NAME is the
; side's prefix, XARR and ZARR its coordinate arrays, RED the section flag
; for a red verge on it, and LEFT is 1 where the verge's width is
; subtracted.
    MACRO VB_POINT NAME, XARR, ZARR, RED, LEFT
NAME_point:
    ld hl,(vb_off)
    ld de,XARR
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (vb_px),de
    ld hl,(vb_off)
    ld de,ZARR
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (vb_pz),de
    call vb_project
    ; The closest point so far, visible or not: beyond it the list is
    ; coming back towards the camera and must stay in the field of view.
    ld hl,(NAME_close)
    ld de,(ya_logd)
    or a
    sbc hl,de
    jr c,.farther
    ld (NAME_close),de
    ld a,(vb_i)
    ld (NAME_close_i),a
.farther:
    ex de,hl
    call pitch_line
    jp c,.hidden
    or a
    jp m,.hidden                ; below the view
    ld (vb_line),a
    ld a,(NAME_close_i)
    ld b,a
    ld a,(vb_i)
    cp b
    jr z,.in_view
    ld a,(vb_rel+1)
    or a
    jp p,.abs
    neg
.abs:
    cp FOV_YAW
    jp nc,.hidden
.in_view:
    ld hl,(vb_seg)
    ld (NAME_prev),hl
    ; The marks alternate a segment at a time: odd ones white, even ones
    ; red or black.
    ld a,l
    rrca
    ld a,4
    jr c,.colour
    ld a,(vb_flags)
    and RED
    ld a,3
    jr nz,.colour
    ld a,2
.colour:
    ld (vb_colour),a
    ld hl,(ya_logd)
    ld a,(vb_scale)
    call verge_width            ; in pixels: adding it to the point's x
    push hl                     ; can't wrap the way adding yaw angles can
    ld hl,(vb_rel)
    call yaw_to_x
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
    ; BC = x, DE = the outside x, then vb_line and vb_colour.
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
    ld a,(vb_colour)
    ld (hl),a
    ld a,l
    add a,ENTRY-5
    ld l,a
    ld (NAME_list),hl
    ld hl,NAME_count
    inc (hl)
    ret
.hidden:
    ; The last try: a quarter of the way from the last point kept towards
    ; this one, with the last point's width and colour.
    xor a
    ld (NAME_live),a
    ld a,(NAME_count)
    or a
    ret z
    ld hl,(pa_logdy)            ; the other side still needs this segment's
    push hl
    ld a,(pa_dysign)
    push af
    ld hl,(NAME_prev)
    add hl,hl
    push hl
    push hl
    ld de,XARR
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld hl,(vb_px)
    call quarter
    ld (vb_px),hl
    pop hl
    ld de,ZARR
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld hl,(vb_pz)
    call quarter
    ld (vb_pz),hl
    pop hl
    ld de,SEG_YI
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld hl,(vb_py)
    call quarter
    ld de,(cam_y)
    or a
    sbc hl,de
    call pitch_height
    call vb_project
    ld hl,(ya_logd)
    call pitch_line
    jr c,.none
    or a
    jp m,.none
    ld (vb_line),a
    ld hl,(NAME_list)
    ld a,l
    sub ENTRY
    ld l,a                      ; the last entry
    ld c,(hl)
    inc l
    ld b,(hl)
    inc l
    ld e,(hl)
    inc l
    ld d,(hl)
    inc l
    inc l
    ld a,(hl)
    ld (vb_colour),a
    ex de,hl
    or a
    sbc hl,bc                   ; its width on screen
    push hl
    ld hl,(vb_rel)
    call yaw_to_x
    pop de
    ld b,h
    ld c,l
    add hl,de
    ex de,hl
    call .store
.none:
    pop af
    ld (pa_dysign),a
    pop hl
    ld (pa_logdy),hl
    ret

NAME_list:      dw 0
NAME_count:     db 0
NAME_live:      db 0
NAME_close:     dw 0            ; the log of the closest point's distance
NAME_close_i:   db 0            ; and which point that was
NAME_prev:      dw 0            ; the segment of the last point kept
    ENDM

    VB_POINT vr, SEG_XI, SEG_ZI, %100, 0
    VB_POINT vl, SEG_XO, SEG_ZO, %010, 1

; The yaw of (vb_px, vb_pz) relative to the camera's heading into vb_rel,
; and the log of its distance in ya_logd.
vb_project:
    ld hl,(vb_px)
    ld de,(cam_x)
    or a
    sbc hl,de
    push hl
    ld hl,(vb_pz)
    ld de,(cam_z)
    or a
    sbc hl,de
    ld b,h
    ld c,l
    pop de
    call yaw_angle
    ld de,(cam_heading)
    or a
    sbc hl,de
    ld (vb_rel),hl
    ret

; HL = DE + (HL - DE) / 4, rounding down as the BBC's shifts do.
quarter:
    or a
    sbc hl,de
    sra h
    rr l
    sra h
    rr l
    add hl,de
    ret

vb_steps:   db 0,13,6,3,1,1,1,1,1,1,1,1,1,1,1,1
vb_i:       db 0
vb_seg:     dw 0
vb_off:     dw 0
vb_flags:   db 0
vb_scale:   db 0
vb_px:      dw 0
vb_py:      dw 0
vb_pz:      dw 0
vb_rel:     dw 0
vb_line:    db 0
vb_colour:  db 0
