; The score and the two tests of flying skill, after model/scoring.py.
; Scores are four BCD digits counting tens of points; the 6502's decimal
; mode and the Z80's DAA agree on BCD digits, which is all the game adds.

BEEP            equ 3
BRIDGE          equ 2           ; check_flying_skills' targets: the bridge's object
TOWN            equ 34          ; and the town's
NEAR            equ 5

; Add the points in D E (four BCD digits) to the score (UpdateScore); a
; high byte of $99 with no carry out resets it, as the original's code
; does, though nothing adds that much. Uses A.
update_score:
    ld a,(scoreLo)
    add a,e
    daa
    ld (scoreLo),a
    ld a,(scoreHi)
    adc a,d
    daa
    ld (scoreHi),a
    ret c
    ld a,d
    cp $99
    ret nz
    xor a
    ld (scoreLo),a
    ld (scoreHi),a
    ret

; The same, and a beep (ScorePoints).
score_points:
    call update_score
    ld a,BEEP
    jp make_sound

; The high score up to the score if it is no lower (UpdateHighScore).
update_high_score:
    LD16 highScoreLo, highScoreHi
    ex de,hl
    LD16 scoreLo, scoreHi
    or a
    sbc hl,de
    ret c
    ld a,(scoreLo)
    ld (highScoreLo),a
    ld a,(scoreHi)
    ld (highScoreHi),a
    ret

; Carry set if the plane is inside skill zone C (0, 3, ... 18): a box from
; the zone's corner, four times its skillZoneSize along each axis
; (CheckBridgeAndTown).
check_bridge_and_town:
    MACRO CBT_AXIS axis
    ld a,c
    add a,axis
    ld e,a
    ld d,0
    ld hl,skillZoneLo
    add hl,de
    ld b,(hl)
    ld hl,skillZoneHi
    add hl,de
    ld h,(hl)
    ld l,b                      ; H L = the corner
    ld a,(xPlaneLo + axis)
    sub l
    ld b,a
    ld a,(xPlaneHi + axis)
    sbc a,h
    bit 7,a
    jp nz,cbt_outside           ; behind the corner
    srl a
    rr b
    srl a
    rr b                        ; / 4
    or a
    ret nz
    ld hl,skillZoneSize
    add hl,de
    ld a,b
    cp (hl)
    ret nc
    ENDM
    CBT_AXIS 2
    CBT_AXIS 1
    CBT_AXIS 0
    scf
    ret
cbt_outside:
    or a
    ret

; Check the bridge (A = BRIDGE) or the town (TOWN) test of skill
; (CheckFlyingSkills). Raises EVENT_CRASH on hitting the bridge's deck or a
; building.
check_flying_skills:
    ld (cfs_target),a
    ld e,a
    ld d,0
    ld hl,xObjectHi
    add hl,de
    ld a,(xPlaneHi)
    sub (hl)
    call .near
    ret nc
    ld hl,zObjectHi
    add hl,de
    ld a,(zPlaneHi)
    sub (hl)
    call .near
    ret nc
    ld a,(cfs_target)
    cp BRIDGE
    jr nz,.town
    ld c,6
    call check_bridge_and_town
    jr nc,pay_out
    ld c,3
    call check_bridge_and_town
    jr c,pay_out
    ld c,0
    call check_bridge_and_town
    jp nc,raise_crash           ; hit the bridge
    ld b,$05
    ld c,$10
    jr .award
.town:
    ld c,12
    call check_bridge_and_town
    jp c,raise_crash            ; hit a building
    ld c,15
    call check_bridge_and_town
    jp c,raise_crash
    ld c,9
    call check_bridge_and_town
    jp c,raise_crash
    ld c,18
    call check_bridge_and_town
    jr nc,pay_out
    ld b,$10
    ld c,$20
.award:
    ld a,(upside_down_bar)
    or a
    ld a,b
    jr z,.upright
    ld a,c
.upright:
    ld (pointsToAward),a
    ret
.near:
    ; Carry set if A, a high byte difference, is within NEAR either way.
    bit 7,a
    jr z,.near_positive
    cpl
.near_positive:
    cp NEAR
    ret

cfs_target: db 0

; Outside the zone: pay any points banked on the way in (skil9).
pay_out:
    ld a,(pointsToAward)
    or a
    ret z
    ld e,a
    ld d,0
    call score_points
    xor a
    ld (pointsToAward),a
    ret

; The scores, or TOO LATE!, put up (DisplayScore, PrintTooLate) or taken
; down (RemoveScore). The BBC prints straight onto its screen, so they are
; drawn there at once, and into every view while they are up (canopy.s).
display_score:
    ld a,1
    ld (score_shown),a
    ld hl,screen_plot_text
    jp draw_messages

remove_score:
    xor a
    ld (score_shown),a
    ret

print_too_late:
    ld a,1
    ld (too_late_shown),a
    ld hl,screen_plot_text
    jp draw_messages

score_shown:    db 0
too_late_shown: db 0
