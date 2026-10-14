; Stage 1: the view, flown along a recorded flight.
;
; The view's part of the main loop on its own, for tests/test_zx_view.py and
; the profile of the view, which put the plane where a stretch of the tour
; flight has it each iteration: the matrices from the rotation, the line
; lists, three rounds of hidden lines, the projection, the clipping and
; drawing, and the copy to the screen -- and nothing else.

HIDDEN_ROUNDS   equ 3           ; ProcessLinesToHide three at a time, this often
RELATED_BUSY    equ 35

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
