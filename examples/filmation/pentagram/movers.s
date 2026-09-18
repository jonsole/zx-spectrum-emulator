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

MOVE_STILL          EQU     4       ; the first that kills: spiky grass, thorns
                                    ; and water -- $C285 -- which do nothing else
MOVE_SPIDER         EQU     5       ; graphic 89, $CF22
MOVE_PACE_U_DEADLY  EQU     6       ; a dragon's head pacing -- 92, $CEA0
MOVE_PACE_V_DEADLY  EQU     7       ; ...and along V -- 93, $CEDA
MOVE_HOPPER         EQU     8       ; a dragon's head bobbing -- 86, $CE9A
MOVE_CREATURE       EQU     9       ; graphics 16 and 17, $D1F5
MOVE_PUSHED_DEADLY  EQU     10      ; the thorny bush, which can be shoved and
                                    ; kills -- 28, $CD70. The first LOOSE.
MOVE_PUSHED         EQU     11      ; stump, cube, table and stone -- 63, 72,
                                    ; 73, 79, $CD7C/$CD81. The first harmless.

BEHAVIOUR_FIRST_TURN    EQU     MOVE_PACE_U
BEHAVIOUR_DEADLY        EQU     MOVE_STILL
BEHAVIOUR_CRUSHING      EQU     MOVE_PUSHED     ; nothing kills one way only,
BEHAVIOUR_HARMLESS      EQU     MOVE_PUSHED     ; so this range is empty
BEHAVIOUR_GIVES         EQU     MOVE_PUSHED + 1 ; nothing gives way either:
BEHAVIOUR_GIVES_LAST    EQU     MOVE_PUSHED     ; last below first, so empty
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
                    DW      mover_still         ; MOVE_STILL
                    DW      mover_spider        ; MOVE_SPIDER
                    DW      mover_pace_u        ; MOVE_PACE_U_DEADLY
                    DW      mover_pace_v        ; MOVE_PACE_V_DEADLY
                    DW      mover_hopper        ; MOVE_HOPPER
                    DW      mover_creature      ; MOVE_CREATURE
                    DW      mover_pushed        ; MOVE_PUSHED_DEADLY
                    DW      mover_pushed        ; MOVE_PUSHED
                    ASSERT  ($ - mover_tbl) / 2 == MOVE_PUSHED - MOVE_PACE_U + 1


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

mover_pace:         ld      a,h
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
;   IX -> the record
mover_pushed:       call    mover_move
                    jp      mover_halt


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

mover_spider:       ld      (ix+OBJ.DZ),0

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

.go:                ; Mirrored on one turn, not on the next.
                    ld      a,(move_tick)
                    and     1
                    ld      c,a
                    ld      a,(ix+OBJ.FLAGS)
                    and     ~OBJ_FLIP_H & $FF
                    or      c
                    ld      (ix+OBJ.FLAGS),a
                    ASSERT  OBJ_FLIP_H == 1

                    call    mover_move_always   ; it changes every turn
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

mover_creature:     ld      a,(ix+OBJ.FLAGS)
                    xor     OBJ_FLIP_H
                    ld      (ix+OBJ.FLAGS),a

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

.go:                call    mover_move_always
                    ld      a,(collide_hit)
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret
