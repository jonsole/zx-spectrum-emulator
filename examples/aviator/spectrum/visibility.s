; Which lines of the world are visible, and where their points are: after
; model/visibility.py, which explains the lists (linesToShow, linesToHide),
; the three kinds of point (the horizon's, the runway's, the objects'), the
; status bytes and the object groups.

NOT_VISIBLE     equ $80         ; showLine, and status bit 7
WORKED_OUT      equ $80         ; pointStatus bit 7
LOOKED_AT       equ $40         ; objectStatus bit 6
VISIBLE_OBJECT  equ $C0
FIRST_ANCHOR    equ 216         ; object n's anchor is point 216 + n
RUNWAY          equ 1
RUNWAY_ANCHOR   equ 217
LINK            equ 40          ; objectPoints entries from 40 link to point n - 40
RELATED_MAX     equ 49
GROUP_SIZE      equ 8
MATRIX_1        equ 0
MATRIX_4        equ 27
TRAIL_LINE_1    equ 60          ; the bullet trails' lines, which
TRAIL_LINE_2    equ 61          ; ProcessLinesToHide skips
TEMP2           equ xTemp2Lo - xTurnHi ; the workspace offset of (xTemp2 ...)

    ASSERT low pointStatus == 0 && low linesToShow == 0 && low linesToHide == 0
    ASSERT low maxLineDistance == 0 && low lineEndPointId == 0 && low objectPoints == 0
    ASSERT low xTurnHi == 0

; A = the byte at table + A. Uses DE, HL; HL is left pointing at it.
    MACRO AT table
    ld e,a
    ld d,0
    ld hl,table
    add hl,de
    ld a,(hl)
    ENDM

; Move group object A (6 to 9) on to its next copy (NextObjectGroup); carry
; set if it was one, clear if not. Uses A, B, DE, HL.
next_object_group:
    cp 6
    jr c,.not_group
    cp 10
    jr nc,.not_group
    sub 6
    ld e,a
    ld d,0
    ld hl,groupStart
    add hl,de
    ld b,(hl)
    ld hl,objectGroup
    add hl,de
    ld a,(hl)
    inc a
    and 7
    or b
    ld (hl),a
    scf
    ret
.not_group:
    or a
    ret

; Whether a point is too far for line C to be seen (CheckLineDistance):
; A = 1 if any coordinate of point A has a high byte whose magnitude (ones'
; complement for a negative one) is at or beyond the line's
; maxLineDistance, otherwise A = showLine. Uses A, B, HL.
check_line_distance:
    ld l,c
    ld h,high maxLineDistance
    ld b,(hl)                   ; the limit
    ld l,a
    ld h,high xPointHi
    ld a,(hl)
    bit 7,a
    jr z,.x
    cpl
.x:
    cp b
    jr nc,.far
    ld h,high yPointHi
    ld a,(hl)
    bit 7,a
    jr z,.y
    cpl
.y:
    cp b
    jr nc,.far
    ld h,high zPointHi
    ld a,(hl)
    bit 7,a
    jr z,.z
    cpl
.z:
    cp b
    jr nc,.far
    ld a,(showLine)
    ret
.far:
    ld a,1
    ret

; Mark points A down to 1 as worked out (SetPointVisibility).
set_point_visibility:
    ld l,a
    ld h,high pointStatus
.loop:
    set 7,(hl)
    dec l
    jr nz,.loop
    ret

; ---- objects ---------------------------------------------------------------

; Work out where object objectId is relative to the plane, put its anchor in
; point 216 + id (A, for the bullets 12 to 15), and mark its status: bit 6
; looked at, bit 7 visible (SetObjectCoords). Returns the new status in A.
;
; Group objects and the dormant aliens try each of their eight copies in
; turn and stop at the first in range. A bullet's trail ends below the
; ground aren't shown, and bullets are always near enough.
set_object_coords:
    ld (soc_gg),a               ; the bullets' anchor, if this is one
    ld a,(objectId)
    ld (isObject),a
    ld (soc_oid),a
    ld b,a
    ld a,1
    ld (soc_k),a
    ld a,b
    cp 12
    jr c,.not_bullet
    cp 16
    jr nc,.not_bullet
    xor a
    ld (soc_k),a
    ld a,b
    AT yObjectHi
    rla
    jr nc,.objc3                ; above the ground
    ld a,b
    rra
    jr c,.objc3                 ; a trail's front end
    jp .objc10
.not_bullet:
    ld a,b
    add a,FIRST_ANCHOR
    ld (soc_gg),a
    ld a,b
    cp 6
    jr c,.objc3
    cp 10
    jr nc,.objc3
    ld a,GROUP_SIZE
    ld (objCount),a
.objc2:
    ; The next copy of a group object: its x and z from the group's tables.
    ld a,(soc_oid)
    sub 6
    AT objectGroup
    ld c,a
    ld b,0
    ld hl,xGroupObjectHi
    add hl,bc
    ld d,(hl)
    ld hl,zGroupObjectHi
    add hl,bc
    ld e,(hl)
    jr .place
.objc3:
    ld a,(soc_oid)
    cp 34
    jp nc,.objc9
    cp 30
    jp c,.objc9
    jr nz,.flying_slots
    ld a,(themeStatus)
    or a
    jp nz,.objc12
    ld a,GROUP_SIZE
    ld (objCount),a
    jr .objc4
.flying_slots:
    sub 30
    AT alienSlot
    bit 7,a
    jp nz,.objc11
    ld b,a
    AT alienState
    cp 27
    jp nc,.objc9                ; heading for Acornsville: where it is
    ld a,b
    AT alienObjectId
    bit 7,a
    jp nz,.objc11
    jr .objc5
.objc4:
    ld a,(alienSlot)
    ld b,a
    AT alienState
    or a
    jp nz,.objc11
    ld a,b
    AT alienObjectId
.objc5:
    ; Take that alien's place: its x and z.
    ld c,a
    ld b,0
    ld hl,xObjectHi
    add hl,bc
    ld d,(hl)
    ld hl,zObjectHi
    add hl,bc
    ld e,(hl)
.place:
    ld a,(soc_oid)
    ld c,a
    ld b,0
    ld hl,xObjectHi
    add hl,bc
    ld (hl),d
    ld hl,zObjectHi
    add hl,bc
    ld (hl),e
.objc9:
    call relative_to_plane
    jr c,.objc10                ; too far
    ld a,(showLine)
    or a
    jr nz,.objc12               ; outside the world
    ld b,VISIBLE_OBJECT
    jr .mark
.objc10:
    ld a,(soc_oid)
    call next_object_group
    jr nc,.objc11
    ld hl,objCount
    dec (hl)
    jr z,.objc12
    jp .objc2
.objc11:
    ld a,(soc_oid)
    cp 30
    jr nz,.objc12
    ld a,(alienSlot)
    inc a
    and 7
    ld (alienSlot),a
    ld hl,objCount
    dec (hl)
    jr z,.objc12
    jp .objc4
.objc12:
    ld b,LOOKED_AT
.mark:
    ld a,(soc_oid)
    AT objectStatus
    or b
    ld (hl),a
    ret

soc_oid:    db 0
soc_gg:     db 0
soc_k:      db 0

; SetObjectCoords part 8: object soc_oid's position minus the plane's, into
; point soc_gg, then rotated by matrix 1. Carry set if any axis is beyond
; the object's visible distance (the axes are done in turn, and the point
; keeps what was written before the axis that failed).
relative_to_plane:
    MACRO RTP_AXIS obj_lo, obj_hi, plane_lo, plane_hi, plane_top, pt_lo, pt_hi
    ld a,(soc_oid)
    ld c,a
    ld b,0
    ld hl,obj_hi
    add hl,bc
    ld d,(hl)
    ld hl,obj_lo
    add hl,bc
    ld a,(plane_lo)
    ld e,a
    ld a,(hl)
    sub e
    ld e,a                      ; the low byte of object - plane
    ld a,(plane_hi)
    ld l,a
    ld a,d
    sbc a,l
    ld d,a                      ; the high byte
    ld a,(plane_top)
    ld l,a
    ld a,0
    sbc a,l                     ; the top byte
    ld b,a
    ld a,(soc_gg)
    ld l,a
    ld h,high pt_lo
    ld (hl),e
    ld h,high pt_hi
    ld (hl),d
    ld a,b
    call obj_far
    ret c
    ENDM
    RTP_AXIS xObjectLo, xObjectHi, xPlaneLo, xPlaneHi, xPlaneTop, xPointLo, xPointHi
    RTP_AXIS yObjectLo, yObjectHi, yPlaneLo, yPlaneHi, yPlaneTop, yPointLo, yPointHi
    RTP_AXIS zObjectLo, zObjectHi, zPlaneLo, zPlaneHi, zPlaneTop, zPointLo, zPointHi
    xor a
    ld (matrixNumber),a
    ld c,a
    ld a,(soc_gg)
    call set_point_coords
    or a                        ; not far
    ret

; Carry set if object soc_oid is too far to see along one axis
; (CheckObjDistance, with soc_k for K: 0 makes everything near). A is the top
; byte of the 24-bit distance and D its high byte: only distances whose top
; byte is 0 or -1 can be near, and then the high byte's magnitude (ones'
; complement for a negative one) must be below maxObjDistance.
obj_far:
    ld b,a
    ld a,(soc_k)
    or a
    ret z
    ld a,b
    bit 7,a
    jr z,.positive
    inc a
    jr nz,.far
    ld a,d
    cpl
    jr .compare
.positive:
    or a
    jr nz,.far
    ld a,d
.compare:
    ld b,a
    ld a,(soc_oid)
    AT maxObjDistance
    ld c,a
    ld a,b
    cp c
    ccf
    ret
.far:
    scf
    ret

; ---- the horizon -------------------------------------------------------------

; The horizon (ProcessHorizonLine): start point L at (-4096, 0, z), end
; point H at (0, 0, z), with z = +10240 when the plane's pitch is within a
; quarter turn of level and -10240 beyond, rotated by matrix 4 (roll and
; pitch, no yaw).
process_horizon_line:
    ld (phl_ends),hl
    ld a,h
    ld l,a
    xor a
    call set_point_to
    ld a,(phl_ends)
    ld l,a
    xor a
    call set_point_to
    ld a,(phl_ends)
    ld l,a
    ld h,high xPointHi
    ld (hl),$F0
.point:
    ld a,(xRotationHi)
    ld b,a
    rla
    xor b                       ; bit 7: whether the top two bits differ
    ld a,40
    jp p,.same
    ld a,216
.same:
    ld h,high zPointHi
    ld (hl),a
    ld h,high pointStatus
    set 7,(hl)
    ld a,MATRIX_4
    ld (matrixNumber),a
    ld c,a
    ld a,l
    push hl
    call set_point_coords
    pop hl
    ld a,(phl_ends + 1)
    cp l
    ret z
    ld l,a
    jr .point

phl_ends:   dw 0

; ---- the runway --------------------------------------------------------------

; The runway (ProcessRunwayLine): lines 1 to 4 are its outline, 5 to 11 the
; dashes. The first runway line looked at in an iteration works out the
; whole runway; the rest read the verdict from the runway object's status.
; See model/visibility.py.
process_runway_line:
    ld a,(objectStatus + RUNWAY)
    or a
    jr z,.work_out
    bit 7,a
    jr z,.hidden
    ld a,(lineId)
    cp 5
    ret c
    ld a,(showRunwayDashes)
    ld (showLine),a
    ret
.hidden:
    ld a,NOT_VISIBLE
    ld (showLine),a
    ret
.work_out:
    xor a
    ld (matrixNumber),a
    ld a,RUNWAY
    ld (objectId),a
    call set_object_coords
    bit 7,a
    jr z,.hidden
    ld hl,0
    ld (xTemp1Lo),hl
    ld (xTemp1Lo + 2),hl
    ld (xTemp1Lo + 4),hl
    ld a,RUNWAY_ANCHOR
    ld (objectAnchorPoint),a
    ld c,a
    ld a,1
    call add_temp_to_point
    ld a,(matrixNumber)
    ld c,a
    ld a,2
    call set_obj_point_coords
    ; Keep corner 2's vector from the anchor as the top two bytes of a
    ; 24-bit vector, (xTemp2Top xTemp2Hi).
    ld hl,xTemp1Lo
    ld de,xTemp2Hi
    ld bc,6
    ldir
    ld a,(matrixNumber)
    ld c,a
    ld a,4
    call set_obj_point_coords
    ld c,2
    ld a,3
    call add_temp_to_point
    ld a,(showLine)
    or a
    jr z,.inside
    ld a,LOOKED_AT
    ld (objectStatus + RUNWAY),a
    ret
.inside:
    ld a,4
    call set_point_visibility
    ld c,10
    ld a,1
    call check_line_distance
    ld (showLine),a
    or a
    jr nz,.far
    ld c,10
    ld a,3
    call check_line_distance
    ld (showLine),a
    or a
    jr z,.dashes
.far:
    ld a,NOT_VISIBLE
    ld (showRunwayDashes),a
    ld a,(lineId)
    cp 5
    ld a,0
    jr c,.verdict
    ld a,NOT_VISIBLE
.verdict:
    ld (showLine),a
    ret

.dashes:
    ; Half the width vector gives the middle of each end: point 21 off
    ; corner 2 and point 5 off corner 1.
    MACRO HALVE axis
    ld hl,xTemp1Hi + axis
    sra (hl)
    ld hl,xTemp1Lo + axis
    rr (hl)
    ENDM
    HALVE 2
    HALVE 1
    HALVE 0
    ld c,2
    ld a,21
    call add_temp_to_point
    ld c,1
    ld a,5
    call add_temp_to_point
    ld hl,xTemp1Lo
    ld de,xDashesVectorLo
    ld bc,6
    ldir
    ; A sixteenth of the length vector, as a 24-bit step (xTemp1Hi xTemp1Lo
    ; and a low byte), so the fifteen steps don't gather rounding.
    MACRO STEP axis
    ld a,(xTemp2Hi + axis)
    ld e,a
    ld a,(xTemp2Hi + 3 + axis)  ; xTemp2Top
    ld d,a
    xor a
    ld b,4
.shift@:
    sra d
    rr e
    rra
    djnz .shift@
    ld (prw_low + axis),a
    ld a,e
    ld (xTemp1Lo + axis),a
    ld a,d
    ld (xTemp1Hi + axis),a
    ENDM
    STEP 0
    STEP 1
    STEP 2
    ld c,TEMP2
    ld a,5
    call copy_point_to_work
    xor a
    ld (prw_acc),a
    ld (prw_acc + 1),a
    ld (prw_acc + 2),a
    ld a,5
    ld (prw_pid),a
.walk:
    MACRO WALK axis
    ld a,(prw_acc + axis)
    ld hl,prw_low + axis
    add a,(hl)
    ld (prw_acc + axis),a
    ld a,(xTemp2Lo + axis)
    ld hl,xTemp1Lo + axis
    adc a,(hl)
    ld (xTemp2Lo + axis),a
    ld a,(xTemp2Hi + axis)
    ld hl,xTemp1Hi + axis
    adc a,(hl)
    ld (xTemp2Hi + axis),a
    ENDM
    WALK 2
    WALK 1
    WALK 0
    ld a,(prw_pid)
    inc a
    ld (prw_pid),a
    ld c,TEMP2
    call copy_work_to_point
    ld a,(prw_pid)
    cp 19
    jr nz,.walk
    ld a,19
    call set_point_visibility

    ; If the middle line crosses the plane's z = 0, pull the outline's end
    ; that is behind the plane in to the first point ahead.
    ld hl,xDashesVectorLo
    ld de,xTemp1Lo
    ld bc,6
    ldir
    ld a,(zPointHi + 6)
    ld b,a                      ; the sign to compare with
    ld l,6
    ld h,high zPointHi
.cross:
    ld a,(hl)
    xor b
    jp m,.crossed
    inc l
    ld a,l
    cp 20
    jr c,.cross
    ret
.crossed:
    ld a,l
    ld (prw_pid),a
    bit 7,b
    jr nz,.behind_first
    ld a,2
    ld (prw_second),a
    ld a,3
    jr .pull
.behind_first:
    ld a,(prw_pid)
    dec a
    ld (prw_pid),a
    ld a,1
    ld (prw_second),a
    ld a,4
.pull:
    ld b,a
    ld a,(prw_pid)
    ld c,a
    ld a,b
    call add_temp_to_point
    MACRO NEGATE axis
    ld a,(xTemp1Lo + axis)
    neg
    ld (xTemp1Lo + axis),a
    ld a,(xTemp1Hi + axis)
    ld b,a
    ld a,0
    sbc a,b
    ld (xTemp1Hi + axis),a
    ENDM
    NEGATE 0
    NEGATE 1
    NEGATE 2
    ld a,(prw_pid)
    ld c,a
    ld a,(prw_second)
    jp add_temp_to_point

prw_low:    ds 3
prw_acc:    ds 3
prw_pid:    db 0
prw_second: db 0

; ---- lines -------------------------------------------------------------------

; Work out whether line A is visible, setting showLine (0 if so), and work
; out its points' coordinates relative to the plane on the way
; (ProcessLine). C non-zero checks the line against its maximum visible
; distance (the original's HH = 0), which lines already on show don't need.
process_line:
    ld (pl_line),a
    ld a,c
    ld (pl_check),a
    xor a
    ld (showLine),a
    ld (isObject),a
    ld a,(pl_line)
    ld l,a
    ld h,high lineEndPointId
    ld a,(hl)
    ld (pl_end),a
    ld a,(pl_line)
    AT lineStartPointId
    ld (pl_start),a
    ld a,(pl_line)
    cp 12
    jr nc,.objects
    or a
    jr nz,.runway
    ld a,(pl_start)
    ld l,a
    ld a,(pl_end)
    ld h,a
    jp process_horizon_line
.runway:
    call process_runway_line
    jr .behind
.objects:
    ld a,2
    ld (pointCount),a
    ld a,(pl_start)
.point:
    call work_out_point
    ret c                       ; not visible
    ld (pl_pid),a
    ld a,(pl_check)
    or a
    jr z,.mark
    ld a,(pl_line)
    ld c,a
    ld a,(pl_pid)
    call check_line_distance
    ld (showLine),a
    or a
    ret nz
.mark:
    ld a,(pl_pid)
    ld l,a
    ld h,high pointStatus
    set 7,(hl)
    ld hl,pointCount
    dec (hl)
    jr z,.behind
    ld a,(pl_end)
    jr .point
.behind:
    ; A line with both ends behind the plane isn't shown, and a group
    ; object it belongs to moves on to its next copy.
    ld a,(pl_end)
    ld l,a
    ld h,high zPointHi
    bit 7,(hl)
    ret z
    ld a,(pl_start)
    ld l,a
    bit 7,(hl)
    ret z
    ld a,(showLine)
    or NOT_VISIBLE
    ld (showLine),a
    ld a,(isObject)
    jp next_object_group

pl_line:    db 0
pl_check:   db 0
pl_start:   db 0
pl_end:     db 0
pl_pid:     db 0

; Make sure point A's coordinates are worked out, following its chain of
; linked points to the object it belongs to (ProcessLine parts 3 to 6).
; Returns A = the point to go on with, or carry set if the line has been
; found not visible (showLine set). The chain is kept in wp_stack, where the
; original keeps it on the 6502's stack.
work_out_point:
    ld b,a
    ld l,a
    ld h,high pointStatus
    ld a,(hl)
    and WORKED_OUT              ; clears the carry
    ld a,b
    ret nz
    ld (wp_stack),a
    ld a,1
    ld (wp_depth),a
    ld a,b
    ld (pointId),a
.follow:
    ld l,a
    ld h,high objectPoints
    ld a,(hl)
    cp LINK
    jr c,.object
    sub LINK
    ld (objectAnchorPoint),a
    ld b,a
    ld l,a
    ld h,high pointStatus
    bit 7,(hl)
    jr nz,.rotate
    ld a,(wp_depth)             ; push it
    ld e,a
    ld d,0
    ld hl,wp_stack
    add hl,de
    ld (hl),b
    inc a
    ld (wp_depth),a
    ld a,(relatedPoints)
    cp RELATED_MAX
    jp nc,.not_visible
    inc a
    ld (relatedPoints),a
    ld e,a
    ld d,0
    ld hl,relatedPoints
    add hl,de
    ld (hl),b
    ld a,b
    jr .follow
.object:
    ld (objectId),a
    cp 12
    jr c,.not_bullet
    cp 16
    jr nc,.not_bullet
    ; A bullet's point: the object must already be visible.
    ld b,a
    ld a,(wp_depth)
    dec a
    ld (wp_depth),a
    ld e,a
    ld d,0
    ld hl,wp_stack
    add hl,de
    ld c,(hl)                   ; popped
    ld a,b
    AT objectStatus
    bit 7,a
    jr z,.not_visible
    ld a,c
    and a                       ; clear the carry
    ret
.not_bullet:
    AT objectStatus
    bit 6,a
    jr nz,.looked_at
    xor a
    call set_object_coords
.looked_at:
    ld a,(objectId)
    AT objectStatus
    bit 7,a
    jr z,.not_visible
    ld a,(objectId)
    add a,FIRST_ANCHOR
    ld (objectAnchorPoint),a
.rotate:
    ; Work out the points on the chain, nearest the anchor first, each from
    ; the one before; the line's own point, the first pushed, last.
    ld a,(wp_depth)
    cp 2
    jr c,.first
    dec a
    ld (wp_depth),a
    ld e,a
    ld d,0
    ld hl,wp_stack
    add hl,de
    ld a,(hl)
    ld (wp_gg),a
    xor a
    ld (matrixAxis),a
    ld (matrixNumber),a
    ld c,a
    ld a,(wp_gg)
    call set_obj_point_coords
    ld a,(showLine)
    or a
    jr nz,.failed
    ld a,(wp_gg)
    ld (objectAnchorPoint),a
    ld l,a
    ld h,high pointStatus
    set 7,(hl)
    jr .rotate
.first:
    xor a
    ld (matrixAxis),a
    ld (matrixNumber),a
    ld c,a
    ld a,(wp_stack)
    call set_obj_point_coords
    ld a,(showLine)
    or a
    jr nz,.failed
    ld a,(wp_stack)             ; carry is clear after the OR
    ret
.not_visible:
    ld a,NOT_VISIBLE
    ld (showLine),a
.failed:
    ; A point outside the world leaves showLine as SetObjPointCoords set
    ; it, which is how the original leaves it too.
    scf
    ret

wp_depth:   db 0
wp_gg:      db 0
wp_stack:   ds 64

; Check line A and add it to linesToShow or linesToHide (ShowOrHideLine).
show_or_hide_line:
    ld (sh_line),a
    ld c,1
    call process_line
    ld a,(showLine)
    or a
    jr z,.show
    ld hl,linesToHideEnd
    inc (hl)
    ld l,(hl)
    ld h,high linesToHide
    ld a,(sh_line)
    ld (hl),a
    ret
.show:
    ld hl,linesToShowEnd
    inc (hl)
    ld hl,linesToShowPointer
    inc (hl)
    ld l,(hl)
    ld h,high linesToShow
    ld a,(sh_line)
    ld (hl),a
    ret

sh_line:    db 0

; Check every line on linesToShow again, keeping the visible ones (and the
; horizon, always) and moving the rest to linesToHide (UpdateLinesToShow).
update_lines_to_show:
    ld a,(linesToShowEnd)
    or a
    ret z
    ld a,$FF
    ld (linesToShowPointer),a
    xor a
    ld (lineCounter),a
.loop:
    ld a,(lineCounter)
    ld l,a
    ld h,high linesToShow
    ld a,(hl)
    ld (lineId),a
    ld (sh_line),a
    ld c,0
    call process_line
    ld a,(sh_line)
    or a
    jr z,.keep
    ld a,(showLine)
    or a
    jr nz,.hide
.keep:
    ld hl,linesToShowPointer
    inc (hl)
    ld l,(hl)
    ld h,high linesToShow
    ld a,(sh_line)
    ld (hl),a
    jr .next
.hide:
    ld hl,linesToHideEnd
    inc (hl)
    ld l,(hl)
    ld h,high linesToHide
    ld a,(sh_line)
    ld (hl),a
.next:
    ld hl,lineCounter
    inc (hl)
    ld a,(linesToShowEnd)
    cp (hl)
    jr z,.done
    jr nc,.loop
.done:
    ld a,(linesToShowPointer)
    inc a
    ld (linesToShowEnd),a
    ret

; Take the next unchecked line from linesToHide and check it again, skipping
; the bullet trails' lines (ProcessLinesToHide).
process_lines_to_hide:
    ld a,(linesToHideEnd)
    ld b,a
    ld a,(linesToHidePointer)
    cp b
    ret z
    inc a
    ld (linesToHidePointer),a
    ld l,a
    ld h,high linesToHide
    ld a,(hl)
    ld (lineId),a
    cp TRAIL_LINE_1
    jr z,process_lines_to_hide
    cp TRAIL_LINE_2
    jr z,process_lines_to_hide
    jp show_or_hide_line

; Project both points of every line on linesToShow, and move to linesToHide
; any line (not the horizon) whose points are both off the same side of the
; screen; then clear the "worked out" marks of the points on relatedPoints
; (ProcessLinesToShow).
process_lines_to_show:
    ld a,(linesToShowEnd)
    or a
    jp z,.related
    ld a,$FF
    ld (linesToShowPointer),a
    xor a
    ld (lineCounter),a
.loop:
    ld a,(lineCounter)
    ld l,a
    ld h,high linesToShow
    ld a,(hl)
    ld (lineId),a
    ld (sh_line),a
    AT lineStartPointId
    ld (pls_start),a
    ld a,(sh_line)
    ld l,a
    ld h,high lineEndPointId
    ld a,(hl)
    ld (pls_end),a
    ld a,(pls_start)
    call project_point
    ld a,(pls_end)
    call project_point
    ld a,(pls_start)
    ld l,a
    ld h,high pointStatus
    ld a,(hl)
    ld (startStatus),a
    ld b,a
    ld a,(pls_end)
    ld l,a
    ld c,(hl)                   ; the end's status
    ld a,b
    and c
    and $30
    jr z,.keep                  ; not both off the screen
    rrca
    rrca
    ld d,a
    ld a,b
    xor c
    cpl
    and d
    jr z,.keep                  ; off different sides
    ld a,(sh_line)
    or a
    jr z,.keep
    ld hl,linesToHideEnd
    inc (hl)
    ld l,(hl)
    ld h,high linesToHide
    ld (hl),a
    jr .next
.keep:
    ld hl,linesToShowPointer
    inc (hl)
    ld l,(hl)
    ld h,high linesToShow
    ld a,(sh_line)
    ld (hl),a
.next:
    ld hl,lineCounter
    inc (hl)
    ld a,(linesToShowEnd)
    cp (hl)
    jr z,.done
    jr nc,.loop
.done:
    ld a,(linesToShowPointer)
    inc a
    ld (linesToShowEnd),a
.related:
    ld a,(relatedPoints)
    or a
    ret z
    ld b,a
.clear:
    ld e,b
    ld d,0
    ld hl,relatedPoints
    add hl,de
    ld l,(hl)
    ld h,high pointStatus
    ld (hl),0
    djnz .clear
    ret

pls_start:  db 0
pls_end:    db 0
