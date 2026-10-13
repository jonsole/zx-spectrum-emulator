; Stage 1: the view, flown along a recorded flight.
;
; There is no flight model yet, so the plane's position and rotation come
; from flight_table, a stretch of the tour flight as the Python port flies
; it (build.py records it), one entry an iteration. Each iteration does what
; the main loop does for the picture -- the matrices from the rotation, the
; line lists, three rounds of hidden lines, the projection, the clipping and
; drawing, and the copy to the screen -- and nothing else.

HIDDEN_ROUNDS   equ 3           ; ProcessLinesToHide three at a time, this often
RELATED_BUSY    equ 35
FLIGHT_ENTRY    equ 15          ; bytes an iteration in flight_table

; The keyboard isn't read yet: no key is ever down. Carry set if key A (a
; BBC key code) is pressed.
key_pressed:
    or a
    ret

; One iteration of the view, the plane being where flight_table's entry puts
; it (view_iteration doesn't move it).
view_iteration:
    ld a,(linesToHideEnd)
    ld (previousListEnd),a
    ld a,2
    ld (matrixAxis),a
    call project_axis_angle
    ld a,1
    ld (matrixAxis),a
    call project_axis_angle
    xor a
    ld (matrixAxis),a
    call project_axis_angle
    xor a
    ld (matrixNumber),a
    ld (matrixAxis),a
    call set_matrices
    ; Every object as not yet looked at.
    xor a
    ld (showRunwayDashes),a
    ld (relatedPoints),a
    ld hl,objectStatus
    ld b,40
.clear:
    ld (hl),a
    inc hl
    djnz .clear
    call update_lines_to_show
    ld hl,mainLoopCounter
    inc (hl)
    ld b,HIDDEN_ROUNDS
.hidden:
    push bc
    ld a,(relatedPoints)
    cp RELATED_BUSY
    jr nc,.busy
    call process_lines_to_hide
    call process_lines_to_hide
    call process_lines_to_hide
.busy:
    pop bc
    djnz .hidden
    call process_lines_to_show
    call draw_canopy_view
    ; The points of lines newly hidden need working out again.
.newly_hidden:
    ld a,(linesToHideEnd)
    ld b,a
    ld a,(previousListEnd)
    cp b
    ret z
    inc a
    ld (previousListEnd),a
    ld l,a
    ld h,high linesToHide
    ld a,(hl)
    ld c,a
    AT lineStartPointId
    ld l,a
    ld h,high pointStatus
    ld (hl),0
    ld l,c
    ld h,high lineEndPointId
    ld l,(hl)
    ld h,high pointStatus
    ld (hl),0
    jr .newly_hidden

; Put flight_table's entry HL in place: the plane's position (x, y and z,
; low, high and top bytes) and rotation (x, y and z, low and high).
place_plane:
    ld de,xPlaneLo
    ldi
    ld de,xPlaneHi
    ldi
    ld de,xPlaneTop
    ldi
    ld de,yPlaneLo
    ldi
    ld de,yPlaneHi
    ldi
    ld de,yPlaneTop
    ldi
    ld de,zPlaneLo
    ldi
    ld de,zPlaneHi
    ldi
    ld de,zPlaneTop
    ldi
    ld de,xRotationLo
    ldi
    ld de,xRotationHi
    ldi
    ld de,yRotationLo
    ldi
    ld de,yRotationHi
    ldi
    ld de,zRotationLo
    ldi
    ld de,zRotationHi
    ldi
    ret

; The demo: fly the recorded flight round and round, an iteration starting
; at a frame (the profiler times from the HALT).
fly_recorded:
    ld hl,flight_table
.next:
    push hl
.wait:
    halt
    call place_plane
    call view_iteration
    pop hl
    ld de,FLIGHT_ENTRY
    add hl,de
    ld de,flight_table_end
    or a
    sbc hl,de
    add hl,de
    jr c,.next
    jr fly_recorded
