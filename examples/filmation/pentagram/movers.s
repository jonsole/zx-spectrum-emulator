; ---------------------------------------------------------------------------
; What Pentagram's objects do.
;
; The engine reads behaviours as an ORDERED enum, not as a set of flags: it
; asks whether a value falls in a range, so the order below is the meaning and
; cannot be shuffled. See "What the game supplies" in ../engine/README.md.
;
;   BEHAVIOUR_FIRST_TURN and up               gets a turn, through mover_tbl
;   BEHAVIOUR_DEADLY .. BEHAVIOUR_CRUSHING    kills whatever touches it
;   BEHAVIOUR_CRUSHING .. BEHAVIOUR_HARMLESS  kills only when it moves into you
;   BEHAVIOUR_GIVES .. BEHAVIOUR_GIVES_LAST   gives way under a weight
;   BEHAVIOUR_LOOSE and up                    shoved by what hits it, and
;                                             carried by what it stands on
;
; -- WHERE THIS COMES FROM ----------------------------------------------------
;
; The original picks each object's update routine by its GRAPHIC, through a
; table of 172 routine addresses at $AE2F; the main loop's dispatch is at
; $B001. Everything here was read out of those routines, not guessed:
;
;   * Deadliness is two bits of a record's +$0D. On every contact the collision
;     code ($B760, $B7AF, $B819) hands each side's bit 7 ("kills what I move
;     into") and bit 5 ("kills what touches me") to the other as bit 6 ("I
;     have been killed"). $C291 sets both, and it is called by the routines for
;     graphics 23, 30, 74, 75 (spikes, thorns, water), 28, 86, 89, 92, 93, and
;     the creatures -- so every deadly thing kills both ways, which is the
;     engine's [DEADLY, CRUSHING). Nothing in Pentagram kills only one way.
;
;   * Shoving is the same collision code: a record whose flags carry $04 takes
;     the mover's velocity ($B775, $B7C4). That is the five templates the data
;     marks mobile -- and the engine's BEHAVIOUR_LOOSE.
;
; Harmless movers sit BELOW the deadly ones rather than above, so that they
; are not also LOOSE: the engine shoves and carries everything from
; BEHAVIOUR_LOOSE up, and a moving platform must not be shoved.
; ---------------------------------------------------------------------------

MOVE_NONE           EQU     0       ; stands there: blocks, walls, trees

MOVE_PACE_U         EQU     1       ; a platform pacing along U -- graphic 87,
                                    ; $CEA3. The first with a turn.
MOVE_PACE_V         EQU     2       ; ...and along V -- graphic 88, $CEDD
MOVE_FALLS          EQU     3       ; drops, and cannot be pushed -- graphic 91,
                                    ; $CD75, which zeroes its own U and V step
MOVE_HOMER          EQU     4       ; what falls from the sky and flies at him --
                                    ; 48-51 and 160-167, $CC4B. See flyers.s.

MOVE_BOLT           EQU     5       ; his bolt -- 149-151, $C1C5. See player.s.
MOVE_POOF           EQU     6       ; the puff a bolt or a flyer goes out in --
                                    ; 64-70, $C111

MOVE_QUEST          EQU     7       ; a quest item -- 112-119, $CF68. See quest.s.
MOVE_WELL           EQU     8       ; the well -- 120, $CFD2

MOVE_SINKS          EQU     9       ; sinks while stood on -- 78, $CDA0. The one
                                    ; that gives way.
MOVE_CRUMBLES       EQU     10      ; cracks under him and goes -- 136-139, $D2AD
MOVE_LIFT           EQU     11      ; carries him up -- 84, $CDBB
MOVE_CONVEYOR       EQU     12      ; carries what stands on it along -- 140-143,
                                    ; $B866

MOVE_STILL          EQU     13       ; the first that kills: spiky grass, thorns
                                    ; and water -- $C285 -- which do nothing else
MOVE_SPIDER         EQU     14       ; graphic 89, $CF22
MOVE_PACE_U_DEADLY  EQU     15       ; a dragon's head pacing -- 92, $CEA0
MOVE_PACE_V_DEADLY  EQU     16      ; ...and along V -- 93, $CEDA
MOVE_HOPPER         EQU     17      ; a dragon's head bobbing -- 86, $CE9A
MOVE_CREATURE       EQU     18      ; graphics 16 and 17, $D1F5
MOVE_FALLER         EQU     19      ; what falls from the sky and roams -- 80
                                    ; and 81, $D1FD
MOVE_FALLER4        EQU     20      ; ...in four frames -- 168-171, $D251
MOVE_PUSHED_DEADLY  EQU     21      ; the thorny bush, which can be shoved and
                                    ; kills -- 28, $CD70. The first LOOSE.
MOVE_PUSHED         EQU     22      ; stump, cube, table and stone -- 63, 72,
                                    ; 73, 79, $CD7C/$CD81. The first harmless.
MOVE_COLLECTABLE    EQU     23      ; the five to bring to room 82 -- 144-148,
                                    ; $CD16. Shoved about like a stump.
MOVE_WATER          EQU     24      ; what comes out of the well -- 90, $D0AC

BEHAVIOUR_FIRST_TURN    EQU     MOVE_PACE_U
BEHAVIOUR_DEADLY        EQU     MOVE_STILL
BEHAVIOUR_CRUSHING      EQU     MOVE_PUSHED     ; nothing kills one way only,
BEHAVIOUR_HARMLESS      EQU     MOVE_PUSHED     ; so this range is empty
BEHAVIOUR_GIVES         EQU     MOVE_SINKS      ; the sinking platform, and
BEHAVIOUR_GIVES_LAST    EQU     MOVE_SINKS      ; nothing else
BEHAVIOUR_LOOSE         EQU     MOVE_PUSHED_DEADLY


; Which behaviour each object template gets, by its index in object_type_tbl
; -- the even number the room's group byte names. A template not listed is
; MOVE_NONE. Template index, behaviour; $FF ends it.
mover_of:           DB      6, MOVE_STILL           ; object_03, spiky grass (23)
                    DB      10, MOVE_STILL          ; object_05, thorns (30)
                    DB      26, MOVE_STILL          ; object_13, water (74)
                    DB      42, MOVE_STILL          ; object_21, water (75)
                    DB      28, MOVE_PUSHED_DEADLY  ; object_14, the thorny bush (28)
                    DB      8, MOVE_PUSHED          ; object_04, a stump (72)
                    DB      12, MOVE_PUSHED         ; object_06, a cube (63)
                    DB      14, MOVE_PUSHED         ; object_07, a table (73)
                    DB      22, MOVE_PUSHED         ; object_11, a stone (79)
                    DB      18, MOVE_FALLS          ; object_09 (91)
                    DB      44, MOVE_FALLS          ; object_22 (91)
                    DB      30, MOVE_HOPPER         ; object_15, a dragon's head (86)
                    DB      58, MOVE_PACE_U_DEADLY  ; object_29, a dragon's head (92)
                    DB      60, MOVE_PACE_V_DEADLY  ; object_30, a dragon's head (93)
                    DB      32, MOVE_PACE_U         ; object_16, a platform (87)
                    DB      34, MOVE_PACE_V         ; object_17, a platform (88)
                    DB      36, MOVE_SPIDER         ; object_18, the spider (89)
                    DB      40, MOVE_CREATURE       ; object_20 (16)
                    DB      38, MOVE_WELL           ; object_19, the well (120)
                    DB      20, MOVE_SINKS          ; object_10 (78)
                    DB      24, MOVE_LIFT           ; object_12, the lift (84)
                    DB      48, MOVE_CRUMBLES       ; object_24 (136-139)
                    DB      50, MOVE_CONVEYOR       ; object_25 (140)
                    DB      52, MOVE_CONVEYOR       ; object_26 (141)
                    DB      54, MOVE_CONVEYOR       ; object_27 (142)
                    DB      56, MOVE_CONVEYOR       ; object_28 (143)
                    DB      $FF


; One DW per behaviour from BEHAVIOUR_FIRST_TURN up. Each gets IX pointing at
; its record, may corrupt anything, must leave the stack balanced, and returns.
; The pacers, mover_falls, mover_sinks and mover_hopper are the engine's,
; shared with Knight Lore: see ../engine/movers.s, which has mover_find,
; player_on_top and object_hide too, and shared_movers.s for what Pentagram
; gives them.
mover_tbl:          DW      mover_pacer_u       ; MOVE_PACE_U: engine/movers.s
                    DW      mover_pacer_v       ; MOVE_PACE_V: engine/movers.s
                    DW      mover_falls         ; MOVE_FALLS: $CD75
                    DW      mover_homer         ; MOVE_HOMER
                    DW      mover_bolt          ; MOVE_BOLT
                    DW      mover_poof          ; MOVE_POOF
                    DW      mover_quest         ; MOVE_QUEST
                    DW      mover_well          ; MOVE_WELL
                    DW      mover_sinks         ; MOVE_SINKS: $CDA0
                    DW      mover_crumbles      ; MOVE_CRUMBLES
                    DW      mover_lift          ; MOVE_LIFT
                    DW      mover_conveyor      ; MOVE_CONVEYOR
                    DW      mover_still         ; MOVE_STILL
                    DW      mover_scuttler      ; MOVE_SPIDER: engine/movers.s
                    DW      mover_pace_u_deadly ; MOVE_PACE_U_DEADLY
                    DW      mover_pace_v_deadly ; MOVE_PACE_V_DEADLY
                    DW      mover_hopper        ; MOVE_HOPPER: engine/movers.s
                    DW      mover_roamer        ; MOVE_CREATURE: engine/movers.s
                    DW      mover_faller        ; MOVE_FALLER
                    DW      mover_faller4       ; MOVE_FALLER4
                    DW      mover_shoved_pile   ; MOVE_PUSHED_DEADLY: engine/movers.s
                    DW      mover_shoved_pile   ; MOVE_PUSHED
                    DW      mover_collectable   ; MOVE_COLLECTABLE
                    DW      mover_water         ; MOVE_WATER
                    ASSERT  ($ - mover_tbl) / 2 == MOVE_WATER - MOVE_PACE_U + 1


; ---------------------------------------------------------------------------
; ---------------------------------------------------------------------------
; Busy rooms: the monsters take turns.
;
; While the room is busy -- see busy.s -- each monster sits out one turn in
; room_busy: one in four, three or two, however busy the room has got, and
; not all on the same turn, so the work is split evenly. With
; MONSTER_KEEP_SPEED it is always one in two, and a monster goes twice as far
; when it does move, so a busy room is no easier than a quiet one; without,
; monsters just slow down, more the busier the room. That is what the room's turns
; mostly go on: in room 13, the movers were 63% of a turn, and most of that
; repainting what they had moved through -- and a mover's repaint costs what
; is around it, so it is clutter that makes a room busy, not how many monsters
; it has: no room has more than two.
;
; Which count as monsters: the spider, the creature and the deadly pacers
; from the room data, and whatever drops from the sky. Not the platforms and
; lifts, which he rides and which would throw him off; not the bolts, the
; hopper, the pushed things or anything of the quest's.
MONSTER_KEEP_SPEED  EQU     0               ; 1: twice as far, one turn in two


; Whether this monster sits this turn out. The monsters count busy_count down
; between them, and whichever reaches nought sits out; busy_check starts it one
; further on each turn, so each has its turn.
;
; In:  nothing
; Out: carry set if it sits this turn out
; Corrupts: A
monster_sits_out:   ld      a,(room_busy)
                    or      a
                    ret     z                   ; carry is clear
                    ld      a,(busy_count)
                    dec     a                   ; carry is still clear
                    jr      nz,.moves
                    ld      a,(room_busy)
                    scf
.moves:             ld      (busy_count),a
                    ret

; Twice the step for the move, and back to what it keeps afterwards -- in a
; busy room, and only with MONSTER_KEEP_SPEED: without it both are a RET.
;
; In:  IX -> the record
; Out: DU and DV in the record doubled
; Corrupts: AF
monster_double:
                IF      MONSTER_KEEP_SPEED
                    ld      a,(room_busy)
                    or      a
                    ret     z
                    sla     (ix+OBJ.DU)
                    sla     (ix+OBJ.DV)
                ENDIF
                    ret

; See monster_double.
;
; In:  IX -> the record
; Out: DU and DV in the record halved again
; Corrupts: AF
monster_halve:
                IF      MONSTER_KEEP_SPEED
                    ld      a,(room_busy)
                    or      a
                    ret     z
                    sra     (ix+OBJ.DU)
                    sra     (ix+OBJ.DV)
                ENDIF
                    ret


; ---------------------------------------------------------------------------
; Spikes, thorns and water: deadly, and nothing more. Their behaviour is what
; kills; the turn has nothing to do. shared_movers.s names it, too, for each
; of the engine's hooks Pentagram wants nothing from.
;
; In:  IX -> the record
; Out: nothing
; Corrupts: nothing
mover_still:        ret


; ---------------------------------------------------------------------------
; Pacing to and fro along one axis, two units a turn, turning round whenever
; something stops it -- $CEA3 for U and $CEDD for V: engine/movers.s's
; mover_pacer_u and _v, shared with Knight Lore's fires. It does not fall: the
; original moves it with $B97C, which skips the gravity $B979 applies, and
; mover_hover is the engine's way of saying the same. A platform goes to them
; straight from mover_tbl; what Pentagram gives them is in shared_movers.s.
;
; A dragon's head paces the same way, but it is a monster: in a busy room it
; sits turns out, and with MONSTER_KEEP_SPEED goes twice as far when it does
; move. A platform never sits out -- he rides it, and it would throw him off.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_pace_u_deadly: call   monster_sits_out
                    ret     c
                    jp      mover_pacer_u

; See mover_pace_u_deadly.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_pace_v_deadly: call   monster_sits_out
                    ret     c
                    jp      mover_pacer_v

; mover_pacer's move, with its step now in the record.
;
; In:  IX -> the record, with DU, DV and DZ set; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
pacer_move:         ld      a,(ix+OBJ.BEHAVIOUR)
                    cp      BEHAVIOUR_DEADLY
                    call    nc,monster_double
                    jp      mover_move


PUSHED_REST_EVERY   EQU     4                   ; a power of two -- see mover_pushed

; ---------------------------------------------------------------------------
; A dragon's head that bobs -- $CE31, which graphic 86 reaches through $CE9A:
; engine/movers.s's mover_hopper, shared with Knight Lore's balls. On the
; ground it waits for gravity to settle it; the turn it lands it launches,
; rising a unit a turn -- with no gravity, as $B97C moves it -- until it is up
; at Z 176, and then it falls again under gravity.
;
; The library rises until its Z is past hopper_top, and the original until it
; is at 176 or above, so the top is one below. It never changes: Pentagram's
; hopper starts at mover_hopper, not mover_hopper_claim.
HOPPER_TOP          EQU     176
hopper_top:         DB      HOPPER_TOP - 1


CREATURE_STEP       EQU     4                   ; see mover_creature

; ---------------------------------------------------------------------------
; His bolt -- $C1C5. It flies straight on at the velocity it was fired with,
; eight a turn, a little above the floor -- the original stops it falling
; below Z 132 -- cycling 151, 150, 149. The only things it hurts are what fell
; from the sky: it tests the two flyer slots, and not the room ($C206). Hit
; one and that one goes out in a puff and the bolt is simply gone ($C264);
; hit anything else across its path and the bolt puffs out itself ($C107).
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything
mover_bolt:         ld      a,(ix+OBJ.GFX)
                    dec     a
                    cp      BOLT_FIRST
                    jr      nc,.frame
                    ld      a,BOLT_LAST
.frame:             ld      (ix+OBJ.GFX),a

                    ld      a,(ix+BOLT_DU)
                    ld      (ix+OBJ.DU),a
                    ld      a,(ix+BOLT_DV)
                    ld      (ix+OBJ.DV),a
                    ld      a,(ix+OBJ.Z)
                    cp      BOLT_LOW + 1
                    jr      nc,.moving          ; above it: let it fall
                    ld      (ix+OBJ.DZ),1       ; ...down to it: hold it there
.moving:            call    mover_move_always

                    ; Has it reached something that fell from the sky?
                    ld      iy,(flyer_slots)
                    ld      b,FLYER_SLOTS
.flyer:             call    bolt_hits
                    jr      c,.hit
                    ld      de,ROOM_STRIDE
                    add     iy,de
                    djnz    .flyer

                    ld      a,(collide_hit)
                    and     COLLIDE_U | COLLIDE_V
                    ret     z
                    jp      mover_poof_start    ; stopped by anything else

.hit:               ; The points, from the flyer's graphic, as $C264 works
                    ; them: its bits turned round two places for the last byte,
                    ; three for the one before -- 502 for graphic 160.
                    ld      a,(iy+OBJ.GFX)
                    rlca
                    rlca
                    ld      c,a
                    rlca
                    and     7
                    ld      b,a
                    ld      a,c
                    and     $77
                    ld      c,a
                    push    ix
                    push    iy
                    call    score_add
                    pop     ix                  ; the flyer
                    call    mover_poof_start    ; goes out in a puff
                    pop     ix
                    jp      object_hide         ; and the bolt is gone


; Whether the bolt at IX overlaps the flyer at IY: centres closer on each
; axis than their two sizes and a little -- $C216. An empty slot, or one
; already going out, is not hit.
;
; In:  IX -> the bolt
;      IY -> the slot
; Out: carry set for a hit
; Corrupts: A, C
bolt_hits:          ld      a,(iy+OBJ.GFX)
                    or      a
                    ret     z                   ; carry clear
                    ld      a,(iy+OBJ.BEHAVIOUR)
                    cp      MOVE_POOF
                    jr      z,.miss
                    ld      a,(iy+OBJ.U)
                    sub     (ix+OBJ.U)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(iy+OBJ.SIZE_U)
                    add     a,(ix+OBJ.SIZE_U)
                    add     a,2
                    cp      c
                    jr      c,.miss             ; too far apart along U
                    jr      z,.miss
                    ld      a,(iy+OBJ.V)
                    sub     (ix+OBJ.V)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(iy+OBJ.SIZE_V)
                    add     a,(ix+OBJ.SIZE_V)
                    add     a,2
                    cp      c
                    jr      c,.miss
                    jr      z,.miss
                    ld      a,(iy+OBJ.Z)
                    sub     (ix+OBJ.Z)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(iy+OBJ.SIZE_Z)
                    add     a,(ix+OBJ.SIZE_Z)
                    cp      c
                    jr      c,.miss
                    jr      z,.miss
                    scf
                    ret
.miss:              or      a
                    ret


POOF_FIRST          EQU     64                  ; see mover_poof_start
POOF_LAST           EQU     70

; What the lift is given: it stops at Z 176, climbs two a turn, and hands him
; four -- three of his own and the one his gravity takes back ($A77A). The
; engine's mover_lift does the rest.
LIFT_TOP            EQU     176
LIFT_RISE           EQU     2
LIFT_GIVES_HIM      EQU     4                   ; three, and his own gravity's

; ---------------------------------------------------------------------------
; Which way each conveyor pushes, by the bottom two bits of its graphic
; ($D30A). engine/movers.s's mover_conveyor reads it; the engine hands whatever
; stands on a record that record's step, so a conveyor holds one and never
; moves by it.
conveyor_steps:     DB      1, 0
                    DB      -1, 0
                    DB      0, 1
                    DB      0, -1
