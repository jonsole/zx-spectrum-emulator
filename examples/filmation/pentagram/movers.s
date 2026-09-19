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


; What drives a template, or MOVE_NONE.
;   A  - the template index
; Out: A - the behaviour. Preserves DE.
mover_find:         ld      hl,mover_of
.next:              ld      c,(hl)
                    inc     c                   ; $FF ends the list
                    jr      z,.none
                    dec     c
                    cp      c
                    inc     hl
                    jr      z,.found
                    inc     hl
                    jr      .next
.found:             ld      a,(hl)
                    ret
.none:              xor     a
                    ret


; One DW per behaviour from BEHAVIOUR_FIRST_TURN up. Each gets IX pointing at
; its record, may corrupt anything, must leave the stack balanced, and returns.
mover_tbl:          DW      mover_pace_u        ; MOVE_PACE_U
                    DW      mover_pace_v        ; MOVE_PACE_V
                    DW      mover_falls         ; MOVE_FALLS
                    DW      mover_homer         ; MOVE_HOMER
                    DW      mover_bolt          ; MOVE_BOLT
                    DW      mover_poof          ; MOVE_POOF
                    DW      mover_quest         ; MOVE_QUEST
                    DW      mover_well          ; MOVE_WELL
                    DW      mover_sinks         ; MOVE_SINKS
                    DW      mover_crumbles      ; MOVE_CRUMBLES
                    DW      mover_lift          ; MOVE_LIFT
                    DW      mover_conveyor      ; MOVE_CONVEYOR
                    DW      mover_still         ; MOVE_STILL
                    DW      mover_spider        ; MOVE_SPIDER
                    DW      mover_pace_u        ; MOVE_PACE_U_DEADLY
                    DW      mover_pace_v        ; MOVE_PACE_V_DEADLY
                    DW      mover_hopper        ; MOVE_HOPPER
                    DW      mover_creature      ; MOVE_CREATURE
                    DW      mover_faller        ; MOVE_FALLER
                    DW      mover_faller4       ; MOVE_FALLER4
                    DW      mover_pushed        ; MOVE_PUSHED_DEADLY
                    DW      mover_pushed        ; MOVE_PUSHED
                    DW      mover_collectable   ; MOVE_COLLECTABLE
                    DW      mover_water         ; MOVE_WATER
                    ASSERT  ($ - mover_tbl) / 2 == MOVE_WATER - MOVE_PACE_U + 1


; ---------------------------------------------------------------------------
; Animation at half the turn rate. The original flips and steps its creatures'
; frames every turn -- $A715, which it bumps once round its main loop, is a
; turn counter like move_tick -- but it manages only 5 to 20 turns a second,
; and the remake 16 to 33. Every other turn keeps the flicker nearer what the
; original looks like, and each frame not changed is a sprite not re-mirrored
; and re-rotated: a mover that did not move, and did not change, is not
; repainted at all.
;
; mover_move_anim repaints if this was an animating turn, and only if the
; thing moved otherwise.
;   IX -> the record
mover_move_anim:    ld      a,(room_busy)       ; taking turns, it animates
                    or      a                   ; every time it moves
                    jp      nz,mover_move_always
                    ld      a,(move_tick)
                    rra
                    jp      nc,mover_move_always ; an even turn: it changed
                    jp      mover_move

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

room_busy:          DB      0               ; 0, or 4, 3 or 2: busy.s sets it

; Out: carry set if this monster sits this turn out. The monsters count
; busy_count down between them, and whichever reaches nought sits out;
; busy_check starts it one further on each turn, so each has its turn.
;   IX -> the record
; Corrupts AF.
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

; Twice the step for the move, and back to what it keeps afterwards.
;   IX -> the record
; Corrupts AF.
monster_double:
                IF      MONSTER_KEEP_SPEED
                    ld      a,(room_busy)
                    or      a
                    ret     z
                    sla     (ix+OBJ.DU)
                    sla     (ix+OBJ.DV)
                ENDIF
                    ret
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
; kills; the turn has nothing to do.
mover_still:        ret


; ---------------------------------------------------------------------------
; Pacing to and fro along one axis, two units a turn, turning round whenever
; something stops it -- $CEA3 for U and $CEDD for V. It does not fall: the
; original moves it with $B97C, which skips the gravity $B979 applies, and
; mover_hover is the engine's way of saying the same. Which way it is going is
; MOVE_STATE's axis bit, numbered as collide_hit numbers the axes, so the turn
; is one XOR. From rest it goes the negative way first, as the original does.
;   IX -> the record
PACE_STEP           EQU     2

mover_pace_u:       ld      hl,OBJ.DU * 256 + COLLIDE_U
                    jr      mover_pace
mover_pace_v:       ld      hl,OBJ.DV * 256 + COLLIDE_V

mover_pace:         ld      a,(ix+OBJ.BEHAVIOUR)
                    cp      BEHAVIOUR_DEADLY
                    jr      c,.rides            ; a platform: never sits out
                    call    monster_sits_out
                    ret     c
.rides:             ld      a,h
                    ld      (.step + 2),a       ; LD (IX+d),A is DD 77 d
                    ld      a,l
                    ld      (.which + 1),a      ; the axis, as a mask
                    call    mover_hover         ; it does not fall

                    ld      a,(ix+OBJ.MOVE_STATE)
.which:             and     0                   ; patched: the axis bit
                    ld      a,PACE_STEP
                    jr      nz,.forward
                    neg
.forward:
.step:              ld      (ix+OBJ.DU),a       ; patched: DU or DV

                    ld      a,(ix+OBJ.BEHAVIOUR)
                    cp      BEHAVIOUR_DEADLY
                    call    nc,monster_double
                    call    mover_move
                    ld      a,(.which + 1)      ; the same bit again
                    ld      c,a
                    ld      a,(collide_hit)
                    and     c
                    ret     z                   ; nothing in the way
                    ld      a,(ix+OBJ.MOVE_STATE)
                    xor     c
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret


; ---------------------------------------------------------------------------
; Something that drops and cannot be shoved -- $CD75 clears its own U and V
; step before it moves, so all that is left to it is gravity.
;   IX -> the record
mover_falls:        call    mover_halt
                    jp      mover_move


; ---------------------------------------------------------------------------
; Moved by a shove, once, and then still -- $CD81 and $CD87. The engine's
; object_shove gives a LOOSE object the shover's step; this spends it, with
; gravity, and then forgets it, which is the original clearing +9 to +11
; after the move.
;
; Whatever is stacked on it goes too: shoot the bottom log of a pile and the
; original moves the pile. The engine does carry a rider -- object_carry, in
; the rider's own clamp -- but only if the thing under it still has its step
; when the rider's turn comes, and this clears its step the moment it has
; moved; a rider later in the pool found nothing to take. So the step is
; handed up here instead, before it is forgotten, to anything loose sitting
; on top. That rider spends it on its own turn and hands it up again, so a
; stack of any height moves as one.
;   IX -> the record
;
; At rest it looks to itself only every fourth turn. A pushable's turn is
; mostly its clamp -- gravity against everything under it -- and a busy room
; is busy with pushables, not monsters: room 13 has six stumps and two
; spiders, 9 and 133 eight stumps and one. The original clamps every one of
; them every turn, which is why it runs room 13 at under five turns a second.
; A shove is acted on at once, and once it is falling it moves every turn
; until it lands; only standing still is checked less often -- staggered by
; slot, so a room's pushables share the turns. A support taken away is
; noticed within four turns. MOVE_STATE bit 7 is "was falling".
PUSHED_REST_EVERY   EQU     4                   ; a power of two

mover_pushed:       ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    jr      nz,.moves           ; shoved: now
                    bit     7,(ix+OBJ.MOVE_STATE)
                    jr      nz,.moves           ; falling: every turn
                    ld      a,ixl               ; standing: its slot's turn
                    rlca                        ; of four -- records are 32
                    rlca                        ; apart, so bits 5 and 6
                    rlca
                    ld      c,a
                    ld      a,(move_tick)
                    add     a,c
                    and     PUSHED_REST_EVERY - 1
                    ret     nz

.moves:             call    mover_move
                    ld      a,(collide_hit)     ; landed, or still going down?
                    and     COLLIDE_Z
                    res     7,(ix+OBJ.MOVE_STATE)
                    jr      nz,.landed
                    set     7,(ix+OBJ.MOVE_STATE)
.landed:            ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    call    nz,pushed_carry     ; it moved: take the pile with it
                    jp      mover_halt


; Give this object's step to everything loose standing on it that has none of
; its own: the same thing object_carry does, from underneath.
;   IX -> the record that has just moved, DU and DV what it moved by
; Corrupts AF, BC, DE, IY.
pushed_carry:       ld      a,(room_object_count)
                    ld      b,a
                    ld      iy,room_objects
                    ld      a,(ix+OBJ.Z)
                    add     a,(ix+OBJ.SIZE_Z)
                    ld      c,a                 ; C - its top
.next:              ld      a,(iy+OBJ.BEHAVIOUR)
                    cp      BEHAVIOUR_LOOSE
                    jr      c,.skip             ; not the sort that rides
                    ld      a,(iy+OBJ.Z)
                    cp      c
                    jr      nz,.skip            ; not sitting on our top
                    ld      a,(iy+OBJ.DU)
                    or      (iy+OBJ.DV)
                    jr      nz,.skip            ; going somewhere already

                    ld      a,(iy+OBJ.U)        ; over us along U?
                    sub     (ix+OBJ.U)
                    call    character_door_find.abs
                    ld      e,a
                    ld      a,(iy+OBJ.SIZE_U)
                    add     a,(ix+OBJ.SIZE_U)
                    cp      e
                    jr      c,.skip
                    jr      z,.skip
                    ld      a,(iy+OBJ.V)        ; ...and along V?
                    sub     (ix+OBJ.V)
                    call    character_door_find.abs
                    ld      e,a
                    ld      a,(iy+OBJ.SIZE_V)
                    add     a,(ix+OBJ.SIZE_V)
                    cp      e
                    jr      c,.skip
                    jr      z,.skip

                    ld      a,(ix+OBJ.DU)
                    ld      (iy+OBJ.DU),a
                    ld      a,(ix+OBJ.DV)
                    ld      (iy+OBJ.DV),a
.skip:              ld      de,ROOM_STRIDE
                    add     iy,de
                    djnz    .next
                    ret


; ---------------------------------------------------------------------------
; The spider -- $CF22. It walks diagonally, four units a turn on both axes,
; and whenever anything stops it on either axis, or it has no step at all, it
; picks a new diagonal at random. It is drawn mirrored every other turn, which
; is the whole of its animation: one sprite, flipped.
;
; It falls a unit a turn if there is nothing under it: the original zeroes its
; Z step and then applies gravity, every turn.
;
; MOVE_STATE keeps which axes stopped it last turn.
;   IX -> the record
SPIDER_STEP         EQU     4

mover_spider:       call    monster_sits_out
                    ret     c
                    ld      (ix+OBJ.DZ),0

                    ld      a,(ix+OBJ.MOVE_STATE)
                    and     COLLIDE_U | COLLIDE_V
                    jr      nz,.new             ; stopped: somewhere else
                    ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    jr      nz,.go
.new:               call    mover_rand
                    and     SPIDER_STEP * 2     ; 0 or 8, less 4: -4 or +4
                    sub     SPIDER_STEP
                    ld      (ix+OBJ.DU),a
                    call    mover_rand
                    and     SPIDER_STEP * 2
                    sub     SPIDER_STEP
                    ld      (ix+OBJ.DV),a

.go:                ; Mirrored for two turns, then not for two -- see
                    ; mover_move_anim for why two.
                    ld      a,(move_tick)
                    rrca
                    and     1
                    ld      c,a
                    ld      a,(ix+OBJ.FLAGS)
                    ld      b,a
                    and     ~OBJ_FLIP_H & $FF
                    or      c
                    ld      (ix+OBJ.FLAGS),a
                    ASSERT  OBJ_FLIP_H == 1
                    xor     b                   ; did the mirror change?
                    ld      b,a
                    call    monster_double
                    ld      a,b
                    or      a
                    jr      z,.same
                    call    mover_move_always
                    jr      .moved
.same:              call    mover_move          ; only if it went anywhere
.moved:             call    monster_halve
                    ld      a,(collide_hit)
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret


; ---------------------------------------------------------------------------
; A dragon's head that bobs -- $CE31, which graphic 86 reaches through $CE9A.
; On the ground it waits for gravity to settle it; the turn it lands it
; launches, rising a unit a turn -- with no gravity, as $B97C moves it -- until
; it is up at Z 176, and then it falls again under gravity.
;
; MOVE_STATE bit 0 says it is on the way up, the original's bit 2 of +$0D.
;   IX -> the record
HOPPER_TOP          EQU     176

mover_hopper:       call    mover_halt          ; never along the floor
                    bit     0,(ix+OBJ.MOVE_STATE)
                    jr      z,.falling

                    ; Up a unit. mover_clamp takes one off DZ for gravity, so
                    ; two is one.
                    ld      (ix+OBJ.DZ),2
                    call    mover_move_always
                    ld      a,(ix+OBJ.Z)
                    cp      HOPPER_TOP
                    ret     c
                    res     0,(ix+OBJ.MOVE_STATE)   ; high enough: come down
                    ret

.falling:           call    mover_move
                    ld      a,(collide_hit)
                    and     COLLIDE_Z
                    ret     z                   ; still in the air
                    set     0,(ix+OBJ.MOVE_STATE)   ; landed: up again
                    ret


; ---------------------------------------------------------------------------
; A creature that walks one axis at a time -- $D1F5, graphics 16 and 17. It
; flips its mirror every turn, which is its animation. When it has no step
; left -- something stopped it -- it picks four units either way at random,
; along U if the last thing that stopped it was across V and along V
; otherwise, and wears 16 for U and 17 for V.
;   IX -> the record
CREATURE_STEP       EQU     4

mover_creature:     call    monster_sits_out
                    ret     c
                    ld      a,(move_tick)
                    rra
                    jr      c,.kept             ; flips on even turns only
                    ld      a,(ix+OBJ.FLAGS)
                    xor     OBJ_FLIP_H
                    ld      (ix+OBJ.FLAGS),a
.kept:

                    ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    jr      nz,.go

                    call    mover_rand
                    and     CREATURE_STEP * 2
                    sub     CREATURE_STEP
                    ld      c,a
                    ld      a,(ix+OBJ.MOVE_STATE)
                    and     COLLIDE_V
                    jr      nz,.along_u
                    ld      (ix+OBJ.DV),c
                    set     0,(ix+OBJ.GFX)      ; 17: along V
                    jr      .go
.along_u:           ld      (ix+OBJ.DU),c
                    res     0,(ix+OBJ.GFX)      ; 16: along U

.go:                call    monster_double
                    call    mover_move_anim
                    call    monster_halve
                    ld      a,(collide_hit)
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret


; ---------------------------------------------------------------------------
; What falls out of the sky and flies at him -- $CC4B, for 48-51 and 160-167.
; flyers.s drops it.
;
; It steers on all three axes at once: each turn it adds three towards him to
; a velocity it keeps in sixteenths -- towards his legs' U and V and his body's
; Z -- held between -72 and +56, and moves by that sixteenth, rounded: four a
; turn at most. Anything that stops it along U or V turns that velocity round,
; so it bounces off walls rather than sticking to them. It animates through
; the four graphics of its block, a frame a turn.
;
; It is not deadly: $CC4B never calls $C291, and its record carries neither
; bit. Harmless it may be, but it gets in the way.
;
; The original moves it first, with last turn's velocity, and then steers for
; the next; so does this. The sixteenths live in the two bytes past the end of
; the record and in MOVE_STATE.
;   IX -> the record
HOMER_ACC_U         EQU     30              ; past OBJ, inside the slot
HOMER_ACC_V         EQU     31
HOMER_ACC_Z         EQU     OBJ.MOVE_STATE
                    ASSERT  OBJ <= HOMER_ACC_U && HOMER_ACC_V < ROOM_STRIDE
HOMER_PULL          EQU     3
HOMER_MOST          EQU     $38             ; +56
HOMER_LEAST         EQU     $B8             ; -72

mover_homer:        call    monster_sits_out
                    ret     c
                    call    monster_double
                    call    mover_move_always
                    call    monster_halve

                    ; Bounce: what stopped it along an axis turns it round there.
                    ld      a,(collide_hit)
                    and     COLLIDE_U
                    jr      z,.u_free
                    ld      a,(ix+HOMER_ACC_U)
                    neg
                    ld      (ix+HOMER_ACC_U),a
.u_free:            ld      a,(collide_hit)
                    and     COLLIDE_V
                    jr      z,.v_free
                    ld      a,(ix+HOMER_ACC_V)
                    neg
                    ld      (ix+HOMER_ACC_V),a
.v_free:
                    ; Steer: towards him on each axis.
                    ld      a,(player + OBJ.U)
                    sub     (ix+OBJ.U)
                    ld      a,(ix+HOMER_ACC_U)
                    call    homer_pull
                    ld      (ix+HOMER_ACC_U),a
                    ld      a,(player + OBJ.V)
                    sub     (ix+OBJ.V)
                    ld      a,(ix+HOMER_ACC_V)
                    call    homer_pull
                    ld      (ix+HOMER_ACC_V),a
                    ld      a,(player + CHARACTER_BODY + OBJ.Z)
                    sub     (ix+OBJ.Z)
                    ld      a,(ix+HOMER_ACC_Z)
                    call    homer_pull
                    ld      (ix+HOMER_ACC_Z),a

                    ; ...and the step for next turn, in whole units.
                    ld      a,(ix+HOMER_ACC_U)
                    call    homer_whole
                    ld      (ix+OBJ.DU),a
                    ld      a,(ix+HOMER_ACC_V)
                    call    homer_whole
                    ld      (ix+OBJ.DV),a
                    ld      a,(ix+HOMER_ACC_Z)
                    call    homer_whole
                    ld      (ix+OBJ.DZ),a

                    ; The next frame of its four, every other turn.
                    ld      a,(move_tick)
                    rrca
                    and     3
                    ld      c,a
                    ld      a,(ix+OBJ.GFX)
                    and     $FC
                    or      c
                    ld      (ix+OBJ.GFX),a
                    ret

; Three more towards him, held to the range: carry from the SUB before this
; means he is below us on that axis. $CD04 and $CD0D.
;   A - the velocity, in sixteenths
homer_pull:         jr      c,.down
                    add     a,HOMER_PULL
                    ret     m
                    cp      HOMER_MOST
                    ret     c
                    ld      a,HOMER_MOST
                    ret
.down:              sub     HOMER_PULL
                    ret     p
                    cp      HOMER_LEAST
                    ret     nc
                    ld      a,HOMER_LEAST
                    ret

; Sixteenths to whole units, rounded, sign kept.
homer_whole:        add     a,8
                    sra     a
                    sra     a
                    sra     a
                    sra     a
                    ret


; ---------------------------------------------------------------------------
; What falls out of the sky and then roams -- $D1FD for 80 and 81, $D251 for
; 168 to 171. Deadly both. It falls under gravity like anything else; along
; the floor it goes four units a turn along one axis, and when something
; stops it -- or before it has ever moved -- picks four either way at random,
; along U if the thing that stopped it was across V, along V otherwise.
;
; Its graphic says which way. For 80 and 81, bit 0 is the axis and the mirror
; tells the two directions on it apart; 168-171 do the same with bit 1, and
; flip bit 0 every turn besides, which is their animation. Going the negative
; way flips the axis bit as well -- the original's own sums.
;   IX -> the record
FALLER_STEP         EQU     4

mover_faller4:      call    monster_sits_out
                    ret     c
                    ld      a,(move_tick)
                    rra
                    jr      c,.kept             ; the frame, on even turns
                    ld      a,(ix+OBJ.GFX)
                    xor     1
                    ld      (ix+OBJ.GFX),a
.kept:
                    ld      c,2                 ; the axis is bit 1
                    jr      mover_faller_c
mover_faller:       call    monster_sits_out
                    ret     c
                    ld      c,1                 ; ...and bit 0 here

mover_faller_c:     ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    jr      nz,.go

                    call    mover_rand
                    and     FALLER_STEP * 2
                    sub     FALLER_STEP
                    ld      b,a
                    ld      a,(ix+OBJ.MOVE_STATE)
                    and     COLLIDE_V
                    jr      nz,.along_u

                    ld      (ix+OBJ.DV),b       ; along V: the axis bit set,
                    ld      a,(ix+OBJ.GFX)      ; unmirrored
                    or      c
                    ld      (ix+OBJ.GFX),a
                    res     0,(ix+OBJ.FLAGS)
                    jr      .facing
.along_u:           ld      (ix+OBJ.DU),b       ; along U: clear, mirrored
                    ld      a,c
                    cpl
                    and     (ix+OBJ.GFX)
                    ld      (ix+OBJ.GFX),a
                    set     0,(ix+OBJ.FLAGS)
                    ASSERT  OBJ_FLIP_H == 1
.facing:            bit     7,b
                    jr      z,.go
                    ld      a,(ix+OBJ.GFX)      ; the negative way
                    xor     c
                    ld      (ix+OBJ.GFX),a

.go:                call    monster_double
                    call    mover_move_anim
                    call    monster_halve
                    ld      a,(collide_hit)
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret


; ---------------------------------------------------------------------------
; His bolt -- $C1C5. It flies straight on at the velocity it was fired with,
; eight a turn, a little above the floor -- the original stops it falling
; below Z 132 -- cycling 151, 150, 149. The only things it hurts are what fell
; from the sky: it tests the two flyer slots, and not the room ($C206). Hit
; one and that one goes out in a puff and the bolt is simply gone ($C264);
; hit anything else across its path and the bolt puffs out itself ($C107).
;   IX -> the record
BOLT_DU             EQU     30              ; the velocity it was fired with,
BOLT_DV             EQU     31              ; past OBJ inside the slot
BOLT_LOW            EQU     132
BOLT_FIRST          EQU     149
BOLT_LAST           EQU     151

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
;   IX -> the bolt, IY -> the slot
; Out: carry set for a hit. Corrupts AF, C.
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


; ---------------------------------------------------------------------------
; A puff -- $C107 starts one, $C111 runs it. Graphics 64 to 70, a frame a
; turn, and then nothing: the slot is emptied. While it plays it neither falls
; nor blocks nor harms.
;   IX -> the record
POOF_FIRST          EQU     64
POOF_LAST           EQU     70

; Only the passable bit is set: the rest of FLAGS is the engine's own
; bookkeeping, and OBJ_SHIFTED in particular says the record's sprite pointer
; is into its rotation buffer. Writing the whole byte cleared that while the
; pointer still pointed there, and the next draw took what lay before the
; copy for a sprite header and mirrored it forever.
mover_poof_start:   ld      (ix+OBJ.GFX),POOF_FIRST
                    ld      (ix+OBJ.BEHAVIOUR),MOVE_POOF
                    set     2,(ix+OBJ.FLAGS)
                    ASSERT  OBJ_PASSABLE == 1 << 2
                    ret

mover_poof:         ld      a,(ix+OBJ.GFX)
                    cp      POOF_LAST
                    jp      nc,object_hide
                    inc     a
                    ld      (ix+OBJ.GFX),a
                    call    mover_hover
                    jp      mover_move_always


; Take a record out of the room: repaint where it was, without it, and leave
; the slot empty for the next. Knight Lore's special_hide.
;   IX -> the record
; Corrupts everything, IX included.
object_hide:        call    region_reset
                    call    region_add
                    call    depth_unlink
                    call    flyer_blank
                    jp      redraw_view


; ---------------------------------------------------------------------------
; Is he standing on this record? His feet on its top or a little above it --
; a lift gives him his rise before it takes its own, so the two leapfrog --
; and over it along both floor axes.
;   IX -> the record
; Out: zf set if he is. Corrupts AF, C.
ON_TOP_SLACK        EQU     6

player_on_top:      ld      a,(ix+OBJ.Z)
                    add     a,(ix+OBJ.SIZE_Z)
                    ld      c,a
                    ld      a,(player + OBJ.Z)
                    sub     c
                    cp      ON_TOP_SLACK + 1
                    jr      nc,.off             ; below its top, or well above
                    ld      a,(player + OBJ.U)
                    sub     (ix+OBJ.U)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(ix+OBJ.SIZE_U)
                    add     a,CHARACTER_HALF_U
                    cp      c
                    jr      c,.off
                    jr      z,.off
                    ld      a,(player + OBJ.V)
                    sub     (ix+OBJ.V)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(ix+OBJ.SIZE_V)
                    add     a,CHARACTER_HALF_V
                    cp      c
                    jr      c,.off
                    jr      z,.off
                    xor     a                   ; zf: on it
                    ret
.off:               or      1                   ; nz: not
                    ret


; ---------------------------------------------------------------------------
; A platform that sinks while something stands on it, a unit a turn -- $CDA0,
; which has no gravity of its own and only ever moves by the step whatever
; lands on it hands it ($B838). Knight Lore's dropping block is the same
; thing, and the engine's landed-on mark is how it knows.
;   IX -> the record
mover_sinks:        bit     3,(ix+OBJ.MOVE_STATE)
                    ret     z
                    res     3,(ix+OBJ.MOVE_STATE)
                    ld      (ix+OBJ.DZ),0       ; one unit, not a fall
                    jp      mover_move


; ---------------------------------------------------------------------------
; A block that cracks under him and goes -- $D2AD. While he is on it, it
; becomes the next graphic of its four, 136 to 139, and on the step after the
; last it is gone. Only he cracks it: $B890 marks what his legs land on, and
; nothing else's.
;
; The original takes a step every turn, but at its own 5 to 20 turns a second
; that is a quarter to most of a second; at the remake's pace it was an eighth,
; too quick to see. A step every CRUMBLE_EVERY turns puts it back to about half.
;   IX -> the record
CRUMBLE_LAST        EQU     139
CRUMBLE_EVERY       EQU     4                   ; a power of two

mover_crumbles:     call    player_on_top
                    ret     nz
                    ld      a,(move_tick)
                    and     CRUMBLE_EVERY - 1
                    ret     nz
                    ld      a,(ix+OBJ.GFX)
                    cp      CRUMBLE_LAST
                    jp      z,object_hide
                    inc     a
                    ld      (ix+OBJ.GFX),a
                    call    mover_hover
                    jp      mover_move_always


; ---------------------------------------------------------------------------
; A lift -- $CDBB. It carries him up: while he stands on it it rises two a turn
; and gives him three ($A77A), up to Z 176, where it holds; when he is off it,
; it sinks a unit a turn back to where it stands, and waits for him again. It
; has no gravity of its own.
;
; MOVE_STATE bit 0 is going; bit 1 is on its way back down.
;   IX -> the record
LIFT_TOP            EQU     176
LIFT_RISE           EQU     2
LIFT_GIVES_HIM      EQU     4                   ; three, and his own gravity's

mover_lift:         bit     0,(ix+OBJ.MOVE_STATE)
                    jr      nz,.going
                    call    player_on_top       ; waiting: until he is on it
                    ret     nz
                    set     0,(ix+OBJ.MOVE_STATE)

.going:             bit     1,(ix+OBJ.MOVE_STATE)
                    jr      nz,.down
                    call    player_on_top
                    jr      nz,.back            ; he has got off: back down
                    ld      a,(ix+OBJ.Z)
                    cp      LIFT_TOP
                    jr      nc,.hold            ; up: it stays while he does
                    ld      a,LIFT_GIVES_HIM    ; and he goes up with it
                    ld      (player + CHARACTER_DZ),a
                    call    mover_halt
                    ld      (ix+OBJ.DZ),LIFT_RISE + 1   ; net of gravity
                    jp      mover_move_always
.hold:              call    mover_hover
                    ret

.back:              set     1,(ix+OBJ.MOVE_STATE)
.down:              call    mover_halt
                    ld      (ix+OBJ.DZ),0       ; a unit a turn, not a fall
                    call    mover_move
                    ld      a,(collide_hit)
                    and     COLLIDE_Z
                    ret     z
                    ld      (ix+OBJ.MOVE_STATE),0   ; down: waiting again
                    ret


; ---------------------------------------------------------------------------
; A conveyor -- $B866, which pushes whatever stands on it two units every other
; turn, along the way the bottom two bits of its graphic say ($D30A). The
; engine already hands a thing standing on a record that record's step
; (object_carry), so a conveyor simply holds a step of its own -- one a turn,
; the same pace -- and never moves by it.
;   IX -> the record
mover_conveyor:     ld      a,(ix+OBJ.GFX)
                    and     3
                    add     a,a
                    ld      e,a
                    ld      d,0
                    ld      hl,conveyor_steps
                    add     hl,de
                    ld      a,(hl)
                    ld      (ix+OBJ.DU),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.DV),a
                    ret

conveyor_steps:     DB      1, 0
                    DB      -1, 0
                    DB      0, 1
                    DB      0, -1
