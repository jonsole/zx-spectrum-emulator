; The game as a whole, after model/game.py: starting it, the main loop, and
; a flight's end.
;
; The original leaves a routine several calls deep when a flight ends,
; adjusting the stack to jump to Crash; here raise_event unwinds to the
; caller of the try that ran the main loop, with A the event, and game_step
; finishes the flight the way model/game.Game.iterate does.

EVENT_NONE      equ 0
EVENT_CRASH     equ 1           ; hit something, or landed too hard
EVENT_TOO_LATE  equ 2           ; an alien reached Acornsville
EVENT_TERMINATED equ 3          ; the flight ended on the ground
GUN_SOUND       equ 6
CRASH_SOUND     equ 5
TIME_SLICE      equ 9           ; centiseconds spent on hidden lines an iteration
RELATED_POINTS_BUSY equ 35
SCORE_SHOWN_FOR equ 220
LANDING_POINTS  equ $15         ; 150 points
THRUST          equ 11          ; the thrust indicator
KEY_T           equ $DC
KEY_P           equ $C8
KEY_RETURN      equ $B6
KEY_RIGHT       equ $86

; ---- events ---------------------------------------------------------------

; Run the main loop, catching a flight's end: A = the event, or EVENT_NONE.
try_main_loop:
    ld (catch_sp),sp
    call main_loop
    xor a
    ret

; Call HL the same way (for the tests).
try_call:
    ld (catch_sp),sp
    call .go
    xor a
    ret
.go:
    jp (hl)

; End the flight with event A (raise_crash: a crash), from however deep.
raise_crash:
    ld a,EVENT_CRASH
raise_event:
    ld sp,(catch_sp)
    ret

catch_sp:   dw 0

; One step of the game (Game.iterate): a main-loop iteration, or, while a
; flight is over, a look for RETURN, which starts a new one.
game_step:
    ld a,(game_over)
    or a
    jr z,.fly
    ld a,KEY_RETURN
    call key_pressed
    ret nc
    xor a
    ld (game_over),a
    jp new_game
.fly:
    call try_main_loop
    or a
    ret z
    ld (game_over),a
    cp EVENT_CRASH
    jp z,crash
    cp EVENT_TOO_LATE
    jp z,terminate_game
    ret

game_over:  db 0

; ---- starting -------------------------------------------------------------

; UpdateFlightModel: the controls, the matrices from the plane's rotation,
; the flight model, and the dashboard.
update_flight_model:
    call move_axes
    call read_joystick
    call move_throttle
    ld a,THRUST
    call c,update_indicator
    ld a,4
    call process_other_keys
    bit 7,a
    jr z,.not_b
    call indicator_b
    jr .pair5
.not_b:
    or a
    call nz,indicator_u
.pair5:
    ld a,5
    call process_other_keys
    bit 7,a
    jr z,.not_fire
    call fire_guns
    jr .matrices
.not_fire:
    or a
    call nz,indicator_f
.matrices:
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
    call apply_flight_model
    call update_dashboard
    jp update_dash_7_to_11

; ResetVariables: a new flight, on the runway with the engine off and an
; empty tank.
reset_variables:
    xor a
    ld (alienSlot),a
    ld (forceFactor + 7),a
    ld (hitTimer),a
    ld (randomNumbers),a
    ld (scoreLo),a
    ld (scoreHi),a
    ld hl,pointStatus
    ld b,0
.points:
    ld (hl),a
    inc l
    djnz .points
    ld (relatedPoints),a
    ld (mainLoopCounter),a
    ld hl,xTurnHi
    ld b,255
.workspace:
    ld (hl),a
    inc l
    djnz .workspace
    ld hl,alienState
    ld b,8
.states:
    ld (hl),a
    inc hl
    djnz .states
    ld a,$48
    ld (zPlaneHi),a
    ld a,$5C
    ld (zPlaneLo),a
    ld a,$C6
    ld (xPlaneHi),a
    ld a,$E5
    ld (xPlaneLo),a
    ld a,$0A
    ld (yPlaneLo),a
    ld (alienSpeed),a
    ld a,242
    ld (forceFactor + Z_LIFT_DRAG),a
    ld a,1
    ld (ucStatus),a
    ld (brakesStatus),a
    ld (landingStatus),a
    call indicator_u
    ld a,1
    ld (onGround),a
    ld a,BUFFER2_EMPTY
    ld (lineBuffer2Count),a
    ld a,$FF
    ld (themeStatus),a
    ld (lineBuffer1Count),a
    ld a,7
    ld (xRotationHi),a
    ld hl,alienObjectId
    ld b,8
.aliens:
    ld (hl),$FF
    inc hl
    djnz .aliens
    ld a,$FF
    ld (alienSlot + 1),a
    ld (alienSlot + 2),a
    ld (alienSlot + 3),a
    call indicator_t
    ld a,THRUST
    call update_indicator
    ld a,FUEL_FULL
    ld (fuelLevel),a
.drain:
    ld hl,fuelLevel
    dec (hl)
    call update_fuel_gauge
    ld a,(fuelLevel)
    or a
    jr nz,.drain
    jp reset_radar              ; (the original falls through into ResetRadar)

    ASSERT low pointStatus == 0

; ResetLineLists: sort every line of the world into linesToShow or
; linesToHide afresh, then FlipColours.
reset_line_lists:
    ld a,DRAW_1
    ld (colourLogic),a
    ld a,SHOW_1
    ld (colourCycle),a
    xor a
    ld (lineId),a
    ld (linesToShowEnd),a
    ld a,$FF
    ld (linesToHideEnd),a
    ld (linesToShowPointer),a
    ld (linesToHidePointer),a
.line:
    ld a,(lineId)
    call show_or_hide_line
    ld hl,lineId
    inc (hl)
    ld a,(numberOfLines)
    ld b,a
    ld a,(hl)
    cp b
    jr c,.line
    jp flip_colours

new_game:
    call clear_canopy
    call reset_variables
    call update_key_logger
    call update_flight_model
    call reset_line_lists
    call indicator_f
    jp indicator_b

start_game:
    xor a
    ld (highScoreHi),a
    ld (highScoreLo),a
    ld a,14
    call define_envelope
    jp new_game

; Carry set if 9 centiseconds have gone since the last time this said so,
; by the clock's low byte either way round (CheckTimePassed).
check_time_passed:
    call read_clock
    ld b,a
    ld hl,previousTime
    sub (hl)
    bit 7,a
    jr z,.elapsed
    neg
.elapsed:
    cp TIME_SLICE
    ccf
    ret nc
    ld (hl),b
    ret

; ---- a flight's end ----------------------------------------------------------

; TerminateGame, up to waiting for RETURN: the engine quiet, the high score
; and the scores shown.
terminate_game:
    xor a
    call toggle_engine_sound
    call update_high_score
    jp display_score

; Crash, up to waiting for RETURN: the crash sound, a flash of the canopy,
; and the scores.
crash:
    xor a
    call toggle_engine_sound
    ld a,CRASH_SOUND
    call make_sound
    ld a,$FF
    call fill_canopy
    call crash_pause
    call clear_canopy
    jp terminate_game

; ---- the main loop --------------------------------------------------------

; One iteration of the main loop (see model/game.py's main_loop for the
; steps). Raises the flight's end.
main_loop:
    ld a,(linesToHideEnd)
    ld (previousListEnd),a
    call spawn_alien
    call update_key_logger
    ld a,(firingStatus)
    ld (ml_firing),a
    call update_flight_model
    ; Just fired: the gun sound, the aliens' statuses noted, and the two
    ; bullet trail lines shown.
    ld a,(ml_firing)
    or a
    jr nz,.not_fired
    ld a,(firingStatus)
    or a
    jr z,.not_fired
    ld a,2
    ld (gunSoundCounter),a
    ld hl,objectStatus + 30
    ld de,alienStatus
    ld bc,4
    ldir
    ld a,(linesToShowEnd)
    ld l,a
    ld h,high linesToShow
    ld (hl),TRAIL_LINE_1
    inc l
    ld (hl),TRAIL_LINE_2
    inc l
    ld a,l
    ld (linesToShowEnd),a
.not_fired:
    xor a
    ld (showRunwayDashes),a
    ld (relatedPoints),a
    ld hl,objectStatus
    ld b,40
.objects:
    ld (hl),a
    inc hl
    djnz .objects

    ld a,(firingStatus)
    or a
    jr z,.no_bullets
    call update_bullets
    ld hl,gunSoundCounter
    ld a,(hl)
    or a
    jr z,.no_bullets
    dec (hl)
    ld a,GUN_SOUND
    call make_sound
.no_bullets:
    ld a,(themeStatus)
    rla
    call nc,alien_in_acornsville

    call update_lines_to_show
    call explode_alien
    ld a,BRIDGE
    call check_flying_skills
    ld a,TOWN
    call check_flying_skills
    ld hl,mainLoopCounter
    inc (hl)
    ld a,(hl)
    add a,4
    and 7
    jr nz,.no_radar
    ld a,RUNWAY_OBJECT
    call update_radar_blip
    ld a,(alienToMove)
    bit 7,a
    jr nz,.no_radar
    ld e,a
    ld d,0
    ld hl,alienState
    add hl,de
    ld a,(hl)
    cp HEADING_FOR_TOWN
    jr c,.no_radar
    ld a,ALIEN_OBJECT
    call update_radar_blip
.no_radar:

    ld a,(themeStatus)
    or a
    jr nz,.no_theme
    ld a,(firingStatus)
    or a
    jr z,.aliens
    ld a,FLYING_SLOT
    ld (objectId),a
.hit:
    ld a,(objectId)
    ld e,a
    ld d,0
    ld hl,alienStatus - 30
    add hl,de
    bit 7,(hl)
    jr z,.next_alien
    call check_if_alien_is_hit
    ld a,(hitTimer)
    or a
    jr z,.next_alien
    ld (distanceFromHit),a
    xor a
    ld (firingStatus),a
    jr .aliens
.next_alien:
    ld hl,objectId
    dec (hl)
    ld a,(hl)
    cp DORMANT_SLOT
    jr nc,.hit
.aliens:
    call update_aliens
.no_theme:

    ; The right arrow, on the ground, ends the flight.
    ld a,(onGround)
    or a
    jr z,.flying
    ld a,KEY_RIGHT
    call key_pressed
    jr nc,.flying
    call terminate_game
    ld a,EVENT_TERMINATED
    jp raise_event
.flying:

    ld a,(landingStatus)
    or a
    jr z,.landed
    bit 7,a
    jr nz,.points
    ; Firing on the runway starts the Theme; with the engine off the tank
    ; fills; the volume keys.
    ld a,(firingStatus)
    or a
    jr z,.no_start
    ld a,(themeStatus)
    rla
    jr nc,.no_start
    ld a,WAVE_START
    ld (themeStatus),a
    call indicator_t
.no_start:
    ld a,(engineStatus)
    or a
    call z,fill_up_fuel_tank
    call process_volume_keys
.points:
    ld a,(reached512ft)
    or a
    jr z,.landed
    xor a
    ld (reached512ft),a
    ld de,LANDING_POINTS
    call score_points
.landed:
    call update_fuel_gauge

    ; T starts and stops the engine, once a press, unless the propeller
    ; is broken.
    ld a,KEY_T
    call key_pressed
    ld a,0
    jr nc,.pressing
    ld a,(pressingT)
    or a
    jr nz,.pressing
    ld a,(propellorStatus)
    or a
    jr nz,.hidden
    ld a,(engineStatus)
    xor 1
    call set_engine
    ld a,1
.pressing:
    ld (pressingT),a
.hidden:
    ; Hidden lines, three at a time, until 9 centiseconds have gone.
    ld a,(relatedPoints)
    cp RELATED_POINTS_BUSY
    jr nc,.time
    call process_lines_to_hide
    call process_lines_to_hide
    call process_lines_to_hide
.time:
    call check_time_passed
    jr nc,.hidden

    call process_lines_to_show
    call draw_canopy_view
    call set_random_number

    ; P shows the scores for a while.
    ld a,(scoreDisplayTimer)
    cp SCORE_SHOWN_FOR
    jr nz,.not_shown
    call remove_score
    xor a
    ld (scoreDisplayTimer),a
    jr .newly_hidden
.not_shown:
    or a
    jr nz,.show
    ld a,KEY_P
    call key_pressed
    jr nc,.newly_hidden
    ld a,(scoreDisplayTimer)
.show:
    dec a
    ld (scoreDisplayTimer),a
    call display_score

.newly_hidden:
    ; The points of lines newly hidden need working out again.
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

ml_firing:  db 0

    ASSERT low linesToHide == 0 && low lineEndPointId == 0
