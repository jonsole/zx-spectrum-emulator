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

; The lists are built in two goes: verges_begin does the first VB_EARLY
; segments, straight after the frame interrupt while compose waits for the
; beam, and verges_finish the rest. Everything the loop needs between the
; two is in memory.
VB_EARLY    equ 6

verges_begin:
    ld a,VB_EARLY
    ld (verges_begin.stop+1),a
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
    ld a,e
    ld (vb_step),a
    ld hl,(vb_seg)
    ASSERT low TRACK_LEN == 0       ; the wrap below needs whole pages
    ld a,l                      ; back E segments, round the track
    sub e
    ld l,a
    jr nc,.stepped
    dec h
    jp p,.stepped
    ld h,high (TRACK_LEN - 1)
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
    ; red or black. But a point that ends a step of several segments --
    ; the far ones, 13, 6 and 3 segments apart -- colours a stretch with
    ; several marks in it, and by its own segment's parity it would swap
    ; between white and red every time the camera passed a segment. Those
    ; stretches take the red or black, so the distance holds still while
    ; the marks close enough to draw one by one go past.
    ld a,(vb_step)
    dec a
    jr nz,.solid
    ld a,(vb_seg)
    rrca
    ld bc,$0404
    jr c,.colours
.solid:
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
    ld (vb_py),de
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
    ret z
    ld a,(vb_i)
    inc a
    ld (vb_i),a
.stop:
    cp 0                        ; patched: VB_EARLY, then POINTS
    jp nz,.point
    ret

; The rest of the lists. If both ended early, .point steps on a segment
; and finds neither side live, which does no harm.
verges_finish:
    ld a,POINTS
    ld (verges_begin.stop+1),a
    jp verges_begin.point

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
    ld hl,(cam_z)
    ld a,c
    sub l
    ld c,a
    ld a,b
    sbc a,h
    ld b,a
    ld hl,(cam_x)
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
    ld (ya_logd),hl             ; the distance's log
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
    ld de,(cam_heading)
    or a
    sbc hl,de
    ld (vb_rel),hl
    ; The closest point so far, visible or not: beyond it the list is
    ; coming back towards the camera and must stay in the field of view.
    ; C is 1 if this is the closest yet, 0 if the list is past it.
    ld de,(ya_logd)
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
    jp nc,.hidden               ; T >= 128
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
    jp m,.hidden                ; below the view
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
    jp nc,.hidden
.in_view:
    ld hl,(vb_seg)
    ld (NAME_prev),hl
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
    ld a,(COLOUR)
    ld (vb_colour),a
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
    ld hl,(vb_off)              ; this point, which the main path kept in
    ld de,XARR                  ; registers
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
NAME_prev:      dw 0            ; the segment of the last point kept
    ENDM

    VB_POINT vr, SEG_XI, SEG_ZI, vb_colours, 0
    VB_POINT vl, SEG_XO, SEG_ZO, vb_colours+1, 1

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
vb_step:    db 0                ; the segments from the last point to this
vb_off:     dw 0
vb_flags:   db 0
vb_wlog:    dw 0
vb_colours: dw 0
vb_px:      dw 0
vb_py:      dw 0
vb_pz:      dw 0
vb_rel:     dw 0
vb_line:    db 0
vb_colour:  db 0
