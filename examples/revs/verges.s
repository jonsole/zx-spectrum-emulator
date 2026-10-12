; The verge point lists, after the BBC's GetSegmentAngles and
; GetVergeAndMarkers: for each side of the track, the points the edges are
; drawn through, far to near.
;
; Each side starts 32 segments ahead of the camera and steps back by 13, 6
; and 3 segments, then one at a time, sixteen points in all -- big steps far
; away, where segments are a pixel or two apart, and small ones close up.
; The list stops at the first point that cannot be seen: below the bottom of
; the view, too close to have a pitch angle, or -- once the points have
; started coming back towards the camera, past the closest one -- outside
; the field of view. Then it tries once more a quarter of the way from the
; last point it kept, so the edge reaches the bottom of the view.
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

verges_build:
    ld ix,VERGE_R
    ld hl,SEG_XI
    ld (vb_xarr),hl
    ld hl,SEG_ZI
    ld (vb_zarr),hl
    ld a,%100                   ; the section flag for a red right verge
    ld (vb_red),a
    xor a
    ld (vb_left),a
    call vb_side
    ld (vr_count),a
    ld ix,VERGE_L
    ld hl,SEG_XO
    ld (vb_xarr),hl
    ld hl,SEG_ZO
    ld (vb_zarr),hl
    ld a,%010
    ld (vb_red),a
    ld a,1
    ld (vb_left),a
    call vb_side
    ld (vl_count),a
    ret

; One side's list into IX. Returns A = the number of entries.
vb_side:
    xor a
    ld (vb_count),a
    ld (vb_i),a
    ld (vb_closest_i),a
    ld hl,$FFFF
    ld (vb_closest),hl
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
    add hl,hl
    ld b,h
    ld c,l                      ; BC = the segment's word offset
    ld hl,(vb_xarr)
    add hl,bc
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (vb_px),de
    ld hl,SEG_YI
    add hl,bc
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (vb_py),de
    ld hl,(vb_zarr)
    add hl,bc
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (vb_pz),de
    call project
    push af
    ; The closest point so far, visible or not: beyond it the list is
    ; coming back towards the camera and must stay in the field of view.
    ld hl,(vb_closest)
    ld de,(vb_dist)
    or a
    sbc hl,de
    jr c,.farther
    ld (vb_closest),de
    ld a,(vb_i)
    ld (vb_closest_i),a
.farther:
    pop af
    jp c,.hidden
    ld a,(vb_closest_i)
    ld b,a
    ld a,(vb_i)
    cp b
    jr z,.in_view
    ld a,(vb_rel+1)
    bit 7,a
    jr z,.abs
    neg
.abs:
    cp FOV_YAW
    jp nc,.hidden
.in_view:
    ld hl,(vb_px)
    ld (vb_prevx),hl
    ld hl,(vb_py)
    ld (vb_prevy),hl
    ld hl,(vb_pz)
    ld (vb_prevz),hl
    ; vergeScale: 5 for black verges (25 units wide), 4 for red ones on a
    ; curve or on both sides (50), 3 for a straight's red verge (100).
    ld hl,(vb_seg)
    ld de,SEG_FLAGS
    add hl,de
    ld c,(hl)
    ld b,5
    ld a,c
    and %110
    jr z,.scale
    ld b,4
    cp %110
    jr z,.scale
    bit 0,c
    jr nz,.scale
    ld b,3
.scale:
    ; The marks alternate a segment at a time: odd ones white, even ones
    ; red or black.
    ld a,(vb_seg)
    rrca
    ld a,4
    jr c,.colour
    ld a,(vb_red)
    and c
    ld a,3
    jr nz,.colour
    ld a,2
.colour:
    ld (ix+5),a
    ld a,(vb_line)
    ld (ix+4),a
    ld a,b
    call verge_width            ; in pixels: adding it to the point's x
    ld (vb_wx),hl               ; can't wrap the way adding yaw angles can
    ld hl,(vb_rel)
    call yaw_to_x
    ld (ix+0),l
    ld (ix+1),h
    ld de,(vb_wx)
    ld a,(vb_left)
    or a
    jr z,.right
    sbc hl,de                   ; carry is clear from the OR
    jr .outside
.right:
    add hl,de
.outside:
    ld (ix+2),l
    ld (ix+3),h
    ld de,ENTRY
    add ix,de
    ld hl,vb_count
    inc (hl)
    ld a,(vb_i)
    inc a
    ld (vb_i),a
    cp 16
    jp nz,.point
    ld a,(vb_count)
    ret
.hidden:
    ; The last try: a quarter of the way from the last point kept towards
    ; this one, with the last point's width and colour.
    ld a,(vb_count)
    or a
    ret z
    ld hl,(vb_px)
    ld de,(vb_prevx)
    call quarter
    ld (vb_px),hl
    ld hl,(vb_py)
    ld de,(vb_prevy)
    call quarter
    ld (vb_py),hl
    ld hl,(vb_pz)
    ld de,(vb_prevz)
    call quarter
    ld (vb_pz),hl
    call project
    jr c,.done
    ld (ix+4),a
    ld a,(ix+5-ENTRY)
    ld (ix+5),a
    ld hl,(vb_rel)
    call yaw_to_x
    ld (ix+0),l
    ld (ix+1),h
    ex de,hl                    ; DE = x
    ld l,(ix+2-ENTRY)
    ld h,(ix+3-ENTRY)
    ld c,(ix+0-ENTRY)
    ld b,(ix+1-ENTRY)
    or a
    sbc hl,bc                   ; the last entry's width on screen
    add hl,de
    ld (ix+2),l
    ld (ix+3),h
    ld hl,vb_count
    inc (hl)
.done:
    ld a,(vb_count)
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

; Projects the point (vb_px, vb_py, vb_pz): vb_rel = its yaw relative to
; the camera's heading, vb_dist = its distance, A = its track line, with
; carry set if it cannot be seen (no pitch angle, or below the view).
project:
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
    call distance
    ld (vb_dist),hl
    ex de,hl
    ld hl,(vb_py)
    ld bc,(cam_y)
    or a
    sbc hl,bc
    call pitch_line
    ret c
    ld (vb_line),a
    rlca                        ; carry if the line is negative
    ld a,(vb_line)
    ret

vb_steps:   db 0,13,6,3,1,1,1,1,1,1,1,1,1,1,1,1
vr_count:   db 0
vl_count:   db 0
vb_xarr:    dw 0
vb_zarr:    dw 0
vb_red:     db 0
vb_left:    db 0
vb_count:   db 0
vb_i:       db 0
vb_closest_i: db 0
vb_closest: dw 0
vb_seg:     dw 0
vb_px:      dw 0
vb_py:      dw 0
vb_pz:      dw 0
vb_prevx:   dw 0
vb_prevy:   dw 0
vb_prevz:   dw 0
vb_rel:     dw 0
vb_dist:    dw 0
vb_line:    db 0
vb_wx:      dw 0
