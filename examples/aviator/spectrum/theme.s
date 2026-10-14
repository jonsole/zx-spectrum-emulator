; The Theme, after model/theme.py: the guns and their bullets, and the
; aliens -- spawning, feeding, taking off, flying to Acornsville, being hit
; and exploding.

FIRING          equ 9           ; firingStatus while bullets are in the air
EXPLOSION       equ 27          ; hitTimer's start
EXPLODED_SOUND  equ 2
FEEDING         equ 1           ; alien states
READY           equ 22
TAKING_OFF      equ 23
CLIMBING_OUT    equ 24
HEADING_FOR_TOWN equ 27
ATTACKING       equ 28
SLOT_EMPTY      equ $FE
DORMANT_SLOT    equ 30
FEED_SLOT_1     equ 31
FEED_SLOT_2     equ 32
FLYING_SLOT     equ 33
PLANE           equ xPlaneLo - xTurnHi ; the workspace offset of (xPlane ...)
GUN_OFFSET_POINT equ 95
PLANE_POINT     equ 96
BULLET_VELOCITY equ 228
TRAIL_LINE      equ 60
WAVE_START      equ 8

; Fire both guns, unless bullets are in the air or an alien has just been
; hit: the bullets start at the two guns, moving at the plane's speed plus
; 200 along its line of flight (FireGuns).
fire_guns:
    ld a,(firingStatus)
    ld b,a
    ld a,(hitTimer)
    or b
    ret nz
    ld l,BULLET_VELOCITY
    xor a
    call set_point_to
    ld a,(zVelocityPHi)
    add a,200
    ld (zPointLo + BULLET_VELOCITY),a
    ld l,GUN_OFFSET_POINT
    ld a,$FF
    call set_point_to
    ld a,$14
    ld (zPointLo + GUN_OFFSET_POINT),a
    ld a,$F6
    ld (xPointLo + GUN_OFFSET_POINT),a
    ld a,$FC
    ld (yPointLo + GUN_OFFSET_POINT),a  ; (-10, -4, -236)
    ld a,MATRIX_2
    ld (matrixNumber),a
    ld a,FIRING
    ld (firingStatus),a
    ld a,BULLET_VELOCITY
    ld c,MATRIX_2
    call set_point_coords
    ld a,BULLET_VELOCITY + 1
    call copy_temp_to_point
    ld a,BULLET_VELOCITY + 2
    call copy_temp_to_point
    ld a,BULLET_VELOCITY + 3
    call copy_temp_to_point
    ld a,GUN_OFFSET_POINT
    ld c,MATRIX_2
    call set_point_coords
    ld a,PLANE_POINT
    ld c,PLANE
    call copy_work_to_point
    ld c,12
.bullet:
    push bc
    call set_object_to_origin
    pop bc
    push bc
    ld a,PLANE_POINT
    call add_point_to_object
    pop bc
    inc c
    ld a,c
    cp 16
    jr c,.bullet
    ld a,GUN_OFFSET_POINT
    ld c,12
    call add_point_to_object
    ld a,GUN_OFFSET_POINT
    ld (objectAnchorPoint),a
    ld a,96
    ld c,MATRIX_2
    call set_obj_point_coords
    ld a,97
    ld c,MATRIX_2
    call set_obj_point_coords
    ld a,98
    ld c,96
    call add_temp_to_point
    ld a,98
    ld c,15
    call add_point_to_object
    ld a,97
    ld c,14
    call add_point_to_object
    ld a,96
    ld c,13
    jp add_point_to_object

; Move the four bullet objects on by their velocities; once any is out of
; sight, or beyond the trail's visible distance, the bullets are over
; (UpdateBullets).
update_bullets:
    ld a,98
    ld (ub_gg),a
    ld a,15
    ld (objectId),a
.bullet:
    ld c,a
    add a,216
    call add_point_to_object
    xor a
    ld (showLine),a
    ld a,(ub_gg)
    call set_object_coords
    rla
    jr nc,.over
    ld a,(ub_gg)
    ld c,TRAIL_LINE
    call check_line_distance
    or a
    jr z,.next
.over:
    xor a
    ld (firingStatus),a
.next:
    ld hl,ub_gg
    dec (hl)
    ld hl,objectId
    dec (hl)
    ld a,(hl)
    cp 12
    jr nc,.bullet
    ret

ub_gg:  db 0

; One axis of a thirty-second of a bullet trail (GetTrailVectorStep): the
; next axis after index A of the vector from the trail's back object to its
; front one, times 8 as a 24-bit number, which is / 32 of it times 256.
; Returns A = the new index, C H L = the step. Uses DE.
get_trail_vector_step:
    add a,nextAxis
    ld (tvs_index),a
    ld e,a
    ld d,0
    ld hl,xObjectLo
    add hl,de
    ld a,(hl)
    inc hl
    ld b,(hl)                   ; the front's low byte (index + 1)
    ld c,a                      ; the back's
    ld hl,xObjectHi
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)                   ; the front's high byte
    ld l,b
    ld b,a
    ; H L = front, B C = back
    or a
    sbc hl,bc
    ld a,h
    rla
    sbc a,a
    ld c,a                      ; the sign, to 24 bits
    add hl,hl
    rl c
    add hl,hl
    rl c
    add hl,hl
    rl c
    ld a,(tvs_index)
    ret

tvs_index:  db 0

; H L = the 16-bit object coordinate at index A (xObjectLo + A, xObjectHi +
; A). Uses DE.
object_at:
    ld e,a
    ld d,0
    ld hl,xObjectLo
    add hl,de
    ld a,(hl)
    ld hl,xObjectHi
    add hl,de
    ld h,(hl)
    ld l,a
    ret

; Carry set if the object at index A (216 for object 0, 228 or 230 for a
; trail's back object) is inside the alien's weak spot: its coordinate less
; cah_weak's must be from 0 to below cah_sizes's on every axis, x, y and z
; in turn. A hit records the alien and starts its explosion
; (CheckAlienWeakSpot).
weak_spot_hit:
    ld (cws_index),a
    ld ix,cah_weak
    ld a,3
    ld (cws_count),a
.axis:
    ld a,(cws_index)
    add a,nextAxis
    ld (cws_index),a
    call object_at
    ld e,(ix + 0)
    ld d,(ix + 1)
    or a
    sbc hl,de
    ld a,h
    or a
    ret nz                      ; (carry clear)
    ld a,l
    cp (ix + 6)
    ret nc
    inc ix
    inc ix
    ld hl,cws_count
    dec (hl)
    jr nz,.axis
    ld a,(objectId)
    ld (hitObjectId),a
    ld a,EXPLOSION
    ld (hitTimer),a
    scf
    ret

cws_index:  db 0
cws_count:  db 0
cah_weak:   ds 6                ; the weak spot's x, y, z, 16-bit
cah_sizes:  ds 6                ; and the box's, at the same offsets (low bytes only)

; Check whether either bullet trail passes through alien A's weak spot
; (30 to 33), stepping along each trail a thirty-second at a time
; (CheckIfAlienIsHit).
check_if_alien_is_hit:
    ld (cah_oid),a
    ; The box and its offset halve for each feeding stage below the
    ; biggest.
    ld c,4
    ld b,3
    cp FEED_SLOT_1
    jr c,.staged
    ld c,0
    ld b,0
    cp FLYING_SLOT
    jr z,.staged
    ld hl,zObjectPoint + 183
    cp FEED_SLOT_1
    jr z,.feeder
    ld hl,zObjectPoint + 188
.feeder:
    ld a,(hl)
    xor $70
    rrca
    rrca
    rrca
    rrca
    and $0F
    sub 2
    ld c,a
    ld b,a
.staged:
    ld a,c
    ld (feedingStage),a
    ld a,$A0
    ld (cah_sizes),a            ; x
    ld (cah_sizes + 4),a        ; z
    ld a,$7D
    ld (cah_sizes + 2),a        ; y
    ld a,$40
    ld (cah_q),a
    inc b
    dec b
    jr z,.sized
.halve:
    ld hl,cah_sizes
    srl (hl)
    ld hl,cah_sizes + 2
    srl (hl)
    ld hl,cah_sizes + 4
    srl (hl)
    ld hl,cah_q
    srl (hl)
    djnz .halve
.sized:
    xor a
    ld (hitTimer),a
    ; The weak spot: the anchor plus (5 q) on x and z, in the order the
    ; axes are checked: x first (index + 40 from 216 is object 0's x).
    ld a,(cah_q)
    ld c,a
    ld b,5
    ld a,(objectId)
    call object_at
    add hl,bc
    ld (cah_weak),hl            ; x
    ld a,(objectId)
    add a,nextAxis
    call object_at
    ld (cah_weak + 2),hl        ; y
    ld a,(objectId)
    add a,2 * nextAxis
    call object_at
    ld a,(cah_q)
    ld c,a
    ld b,5
    add hl,bc
    ld (cah_weak + 4),hl        ; z
    ld a,BULLET_VELOCITY
.trail:
    ld (cah_trail),a
    ; The trail's step vector, a thirty-second of it, into xTemp2 (top two
    ; bytes) and xTemp1Lo (the fraction), then to point 0.
    ld (cah_index),a
    xor a
.step_axis:
    ld (cah_axis),a
    ld a,(cah_index)
    call get_trail_vector_step
    ld (cah_index),a
    ld a,(cah_axis)
    ld e,a
    ld d,0
    push hl
    ld hl,xTemp2Hi
    add hl,de
    ld (hl),c
    ld hl,xTemp2Lo
    add hl,de
    pop bc
    ld (hl),b
    ld hl,xTemp1Lo
    add hl,de
    ld (hl),c
    ld a,(cah_axis)
    inc a
    cp 3
    jr c,.step_axis
    xor a
    ld c,TEMP2
    call copy_work_to_point
    ld a,(cah_trail)
    call weak_spot_hit
    ret c
    ; Object 0 starts at the trail's back object.
    ld a,(cah_trail)
    ld c,a
    ld b,216
.copy:
    ld a,c
    add a,nextAxis
    ld c,a
    ld a,b
    add a,nextAxis
    ld b,a
    ld e,c
    ld d,0
    ld hl,xObjectLo
    add hl,de
    ld a,(hl)
    ld e,b
    ld hl,xObjectLo
    add hl,de
    ld (hl),a
    ld a,b
    cp 200
    jr nz,.copy
    ld a,32
    ld (cah_steps),a
.walk:
    ; The steps' fractions build up in xTemp2Hi, carrying into object 0
    ; when they make a whole unit.
    MACRO CAH_FRACTION axis, index0
    ld a,(xTemp1Lo + axis)
    ld hl,xTemp2Hi + axis
    add a,(hl)
    ld (hl),a
    jr nc,.no_carry
    ld hl,xObjectLo + index0
    inc (hl)
    jr nz,.no_carry
    ld hl,xObjectHi + index0
    inc (hl)
.no_carry:
    ENDM
    CAH_FRACTION 2, 2 * nextAxis
    CAH_FRACTION 1, nextAxis
    CAH_FRACTION 0, 0
    xor a
    ld c,a
    call add_point_to_object
    ld a,216
    call weak_spot_hit
    ret c
    ld hl,cah_steps
    dec (hl)
    jr nz,.walk
    ld a,(cah_trail)
    cp BULLET_VELOCITY
    ret nz
    ld a,BULLET_VELOCITY + 2
    jp .trail

cah_oid:    db 0
cah_q:      db 0
cah_trail:  db 0
cah_index:  db 0
cah_axis:   db 0
cah_steps:  db 0

; A new random number from the timer into the list, and on (SetRandomNumber).
set_random_number:
    ld a,(randomNumbers)
    ld e,a
    ld d,0
    ld hl,randomNumbers + 1
    add hl,de
    call read_timer
    ld (hl),a
    jp next_random_number

; While an alien is exploding, throw its points apart by random amounts,
; and score it at the end; just after the hit, note how near the plane is
; (ExplodeAlien).
explode_alien:
    ld a,(hitTimer)
    or a
    jp z,.distance
    ld a,EXPLODED_SOUND
    call make_sound
    ld a,(hitObjectId)
    sub DORMANT_SLOT
    ld e,a
    ld d,0
    ld hl,explodeFrom
    add hl,de
    ld a,(hl)
    ld (ea_pid),a
    ld hl,explodeTo
    add hl,de
    ld a,(hl)
    ld (ea_last),a
    ld a,(feedingStage)
    cp 3
    jr nc,.shifts
    ld a,2
.shifts:
    inc a
    ld b,a
    ld a,$FF
.mask:
    srl a
    djnz .mask
    ld (ea_mask),a
.point:
    ld a,(ea_pid)
    ld c,TEMP2
    call copy_point_to_work
    MACRO EA_AXIS axis
    call next_random_number
    call random_entry
    ld b,0
    srl a                       ; bit 0, the carry, is the sign
    ld hl,ea_mask
    jr nc,.positive
    and (hl)
    cpl                         ; negative: the complement, plus the carry,
    ld b,$FF                    ; negates
    scf
    jr .add
.positive:
    and (hl)                    ; (carry clear)
.add:
    ld hl,xTemp2Lo + axis
    adc a,(hl)
    ld (hl),a
    ld a,b
    ld hl,xTemp2Hi + axis
    adc a,(hl)
    ld (hl),a
    ENDM
    EA_AXIS 2
    EA_AXIS 1
    EA_AXIS 0
    ld a,(ea_pid)
    ld c,TEMP2
    call copy_work_to_point
    ld a,(ea_pid)
    dec a
    ld (ea_pid),a
    ld hl,ea_last
    cp (hl)
    jp nc,.point
    ld hl,hitTimer
    dec (hl)
    call z,score_hit_points
.distance:
    ld a,(hitTimer)
    cp EXPLOSION - 1
    ret nz
    ld a,(zTemp2Hi)
    ld b,a
    ld a,(hitObjectId)
    cp FLYING_SLOT
    ld a,b
    jr nz,.near
    sub 8
    jp p,.near
    xor a
.near:
    ld (distanceFromHit),a
    ret

ea_pid:     db 0
ea_last:    db 0
ea_mask:    db 0

; Score a destroyed alien and take it out of the wave (ScoreHitPoints).
score_hit_points:
    ld a,(hitObjectId)
    cp DORMANT_SLOT
    jr nz,.slot
    ld a,(alienSlot)
    jr .alien
.slot:
    sub DORMANT_SLOT
    ld e,a
    ld d,0
    ld hl,alienSlot
    add hl,de
    ld a,(hl)
    ld (hl),$FF
.alien:
    ld e,a
    ld d,0
    ld hl,alienObjectId
    add hl,de
    ld (hl),$FF
    ld a,(hitObjectId)
    cp FLYING_SLOT
    jr nz,.not_flying
    call reset_radar
    ld de,3
    jp update_score
.not_flying:
    cp FEED_SLOT_1
    jr nc,.feeding
    ld a,(dormantAlienScore)
    jr .points
.feeding:
    ld a,(feedingStage)
    ld e,a
    ld d,0
    ld hl,alienScore
    add hl,de
    ld a,(hl)
.points:
    ld e,a
    ld d,0
    jp update_score

; While a wave is being spawned and the plane is airborne, perhaps add an
; alien at a random landing place no alien of the wave has (SpawnAlien).
spawn_alien:
    ld a,(themeStatus)
    or a
    ret z
    ret m
    ld b,a
    ld a,(onGround)
    or a
    ret nz
    ld a,b
    dec a
    ld e,a
    ld d,0
    ld hl,alienState
    add hl,de
    ld (hl),0
    call read_timer
    and 15
    cp 14
    ret nc
    or 16
    ld c,a                      ; the place
    ld hl,themeStatus
    dec (hl)
    ld b,8
.alien:
    dec b
    ld a,(themeStatus)
    cp b
    jr z,.place
    ld e,b
    ld d,0
    ld hl,alienObjectId
    add hl,de
    ld a,(hl)
    cp c
    jr nz,.alien
    ld hl,themeStatus
    inc (hl)
    ret
.place:
    ld e,b
    ld d,0
    ld hl,alienObjectId
    add hl,de
    ld (hl),c
    ret

; Double the alien in feeding slot C (31 or 32) by adding 1 to the scale in
; its four points' z values, or with bit 7 of A set put it back to the
; first feeding stage's 2^2 (ResizeFeedingAlien).
resize_feeding_alien:
    ld b,a
    ld hl,zObjectPoint + 186
    ld a,c
    cp FEED_SLOT_1
    jr z,.slot
    ld hl,zObjectPoint + 191
.slot:
    ld c,4
.point:
    ld a,(hl)
    add a,16
    bit 7,b
    jr z,.store
    and 15
    or 32
.store:
    ld (hl),a
    dec hl
    dec c
    jr nz,.point
    ret

; Move the aliens on through their lives (UpdateAliens).
update_aliens:
    ld a,(mainLoopCounter)
    and 127
    ld (ua_due),a               ; 0 when due
    jr nz,.slots
    ld b,8
.states:
    ld e,b
    dec e
    ld d,0
    ld hl,alienState
    add hl,de
    ld a,(hl)
    or a
    jr z,.next_state
    cp READY
    jr z,.next_state
    cp HEADING_FOR_TOWN
    jr nc,.next_state
    inc (hl)
.next_state:
    djnz .states

.slots:
    ; Fill the feeding slots from the dormant aliens, emptying them of the
    ; dead and the departed.
    ld a,FEED_SLOT_1
    call .feed
    ld a,FEED_SLOT_2
    call .feed

    ; A finished feeder takes off, unless an alien is flying.
    ld a,(alienSlot + 3)
    bit 7,a
    jr nz,.take_off
    ld e,a
    ld d,0
    ld hl,alienObjectId
    add hl,de
    ld a,(hl)
    bit 7,a
    jr z,.grow                  ; flying
    ld (alienSlot + 3),a
.take_off:
    ld a,FEED_SLOT_1
    call .ready
    jr c,.grow
    ld a,FEED_SLOT_2
    call .ready

.grow:
    ld a,(ua_due)
    or a
    ret nz
    ld a,FEED_SLOT_1
    call .resize
    ld a,FEED_SLOT_2
    call .resize
    ; A wave all destroyed scores 500 and starts the next, faster.
    ld b,8
.wave:
    ld e,b
    dec e
    ld d,0
    ld hl,alienObjectId
    add hl,de
    bit 7,(hl)
    ret z
    djnz .wave
    ld a,WAVE_START
    ld (themeStatus),a
    ld de,$0050
    call score_points
    ld a,(alienSpeed)
    add a,4
    cp 19
    ret nc
    ld (alienSpeed),a
    ret

.feed:
    ; Slot A: keep a live alien still feeding; otherwise empty it and fill
    ; it from the dormant aliens.
    ld (ua_slot),a
    call .slot_entry
    ld a,(hl)
    bit 7,a
    jr nz,.fill
    ld e,a
    ld d,0
    push hl
    ld hl,alienState
    add hl,de
    ld a,(hl)
    pop hl
    cp CLIMBING_OUT
    jr z,.empty
    push hl
    ld hl,alienObjectId
    add hl,de
    ld a,(hl)
    pop hl
    bit 7,a
    ret z
.empty:
    ld (hl),SLOT_EMPTY
.fill:
    ld a,(ua_slot)
    cp FEED_SLOT_1
    ld a,(alienSlot + 2)
    jr z,.other
    ld a,(alienSlot + 1)
.other:
    ld c,a                      ; the other feeding slot's alien
    ld b,8
.dormant:
    ld e,b
    dec e
    ld d,0
    ld hl,alienObjectId
    add hl,de
    bit 7,(hl)
    jr nz,.not_this
    ld hl,alienState
    add hl,de
    ld a,(hl)
    or a
    jr nz,.not_this
    ld a,e
    cp c
    jr z,.not_this
    call .slot_entry
    ld (hl),e
    push de
    ld a,(ua_slot)
    ld c,a
    ld a,$80
    call resize_feeding_alien
    pop de
    ld hl,alienState
    add hl,de
    ld (hl),FEEDING
    ret
.not_this:
    djnz .dormant
    ret

.ready:
    ; Carry set if the alien in slot A has finished feeding and takes off.
    ld (ua_slot),a
    call .slot_entry
    ld a,(hl)
    bit 7,a
    jr nz,.not_ready
    ld e,a
    ld d,0
    ld hl,alienState
    add hl,de
    ld a,(hl)
    cp READY
    jr nz,.not_ready
    ld (hl),TAKING_OFF
    ld a,e
    ld (alienToMove),a
    scf
    ret
.not_ready:
    or a
    ret

.resize:
    ld (ua_slot),a
    call .slot_entry
    ld a,(hl)
    bit 7,a
    ret nz
    ld e,a
    ld d,0
    ld hl,alienState
    add hl,de
    ld a,(hl)
    cp 5
    ret c
    cp 20
    ret nc
    ld b,a
    and 3
    ret nz
    ld a,(ua_slot)
    ld c,a
    ld a,b
    jp resize_feeding_alien

.slot_entry:
    ; HL -> alienSlot's entry for slot ua_slot.
    ld a,(ua_slot)
    sub DORMANT_SLOT
    ld l,a
    ld h,0
    push de
    ld de,alienSlot
    add hl,de
    pop de
    ret

ua_due:     db 0
ua_slot:    db 0

; Move the alien heading for Acornsville: up to height, then towards the
; town, then down on it; reaching it raises EVENT_TOO_LATE
; (AlienInAcornsville).
alien_in_acornsville:
    ld a,(alienToMove)
    bit 7,a
    ret nz
    ld e,a
    ld d,0
    ld hl,alienState
    add hl,de
    ld a,(hl)
    cp HEADING_FOR_TOWN
    jr nz,.attacking
    ld a,(yObjectHi + FLYING_SLOT)
    cp 12
    jr nc,.across
    ld a,(yObjectLo + FLYING_SLOT)
    add a,10
    ld (yObjectLo + FLYING_SLOT),a
    ret nc
    ld hl,yObjectHi + FLYING_SLOT
    inc (hl)
    ret
.across:
    ld c,0                      ; whether it moved
    MACRO AIA_AXIS axis
    ld a,(xObjectHi + axis * nextAxis + FLYING_SLOT)
    or a
    jr z,.still
    ld a,(alienSpeed)
    ld b,a
    ld a,(xObjectLo + axis * nextAxis + FLYING_SLOT)
    sub b
    ld (xObjectLo + axis * nextAxis + FLYING_SLOT),a
    jr nc,.moved
    push hl
    ld hl,xObjectHi + axis * nextAxis + FLYING_SLOT
    dec (hl)
    pop hl
.moved:
    ld c,1
.still:
    ENDM
    AIA_AXIS 0
    AIA_AXIS 2
    inc c
    dec c
    ret nz
    ld (hl),ATTACKING
    ld a,ATTACKING
.attacking:
    cp ATTACKING
    ret nz
    ld a,(hitTimer)
    or a
    ret nz
    ld a,(yObjectLo + FLYING_SLOT)
    sub 10
    ld (yObjectLo + FLYING_SLOT),a
    jr nc,.descended
    ld hl,yObjectHi + FLYING_SLOT
    dec (hl)
.descended:
    ld a,(yObjectHi + FLYING_SLOT)
    or a
    ret nz
    ld a,(yObjectLo + FLYING_SLOT)
    cp 10
    ret nc
    call print_too_late
    ld a,EVENT_TOO_LATE
    jp raise_event
