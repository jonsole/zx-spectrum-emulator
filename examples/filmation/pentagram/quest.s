; ---------------------------------------------------------------------------
; The quest: what persists between rooms, carrying it, and what it is for.
;
; All read out of the original, whose pieces are these:
;
;   $D432  eighteen records of everything that persists between rooms --
;          four quest items (112-115), five collectables (144-148), the eight
;          pieces of the pentagram in room 82 (128-135), and one the well's
;          bucket (90) takes when it comes out. Copied from $D312 at the
;          start of a game; $D16F deals the collectables out to five of the
;          spots at $D1A5, at random. quest_data.s has all three tables.
;   $B097  entering a room puts its records into the object pool; $B115
;          leaving one writes them back.
;   $BF79  picking up and putting down, on the number keys.
;   $CFD2  the well: shoot it -- thirty-two turns of a bolt touching it -- and
;          a bucket of water comes out, if it is not out already.
;   $D0AC  the bucket sinks until it finds a quest item in the room, then
;          flies up over it, Z 176, and marks it done.
;   $CF68  a quest item marked done becomes the next graphic up by four, gives
;          a life, and counts; when all four are done ($D13A) the pentagram's
;          pieces come to room 82.
;   $CD16  a collectable in room 82 once the pieces are there flies to its
;          place in the pentagram, becomes graphic + 8, and counts; five, and
;          the game is won ($C302).
;
; In the pool, the room's own objects come first, then its records, added with
; them before the room is drawn; then, once it is drawn, up to three empty
; slots -- as many as he can carry -- for putting things down into; then the
; flyers' and the bolts'. A record's slot carries its index at QUEST_INDEX, a
; byte past the end of an object record that nothing else uses there.
; ---------------------------------------------------------------------------

QR_GFX              EQU     0
QR_U                EQU     1
QR_V                EQU     2
QR_Z                EQU     3
QR_SIZE_U           EQU     4
QR_SIZE_V           EQU     5
QR_SIZE_Z           EQU     6
QR_ROOM             EQU     7
QR_LEN              EQU     8

QUEST_INDEX         EQU     31              ; in a slot: which record, or $FF
QUEST_WATER         EQU     17              ; the record the bucket takes
QUEST_CARRIED       EQU     $FF             ; a record's room while he has it
QUEST_SPARES        EQU     3               ; he carries three
QUEST_ITEMS         EQU     4
QUEST_PIECES_ROOM   EQU     82
QUEST_TO_WIN        EQU     5

QUEST_GFX_ITEM      EQU     112             ; 112-115, and 116-119 done
QUEST_GFX_PIECE     EQU     128             ; 128-135
QUEST_GFX_THING     EQU     144             ; the collectables, 144-148...
QUEST_GFX_PLACED    EQU     152             ; ...and 152-156 in place
QUEST_GFX_WATER     EQU     90
QUEST_GFX_WELL      EQU     120

; Dropped, or swapped out, a thing is the size $C061 makes it: his own
; footprint, twelve high.
QUEST_DROP_SIZE_UV  EQU     5
QUEST_DROP_SIZE_Z   EQU     12

; The largest frame an empty slot can be given -- what he carries, what comes
; out of the well, the settled collectables, and the puff -- which sizes the one
; rotation buffer the slot keeps. The quest items never go into one: they are
; never carried.
QUEST_LARGEST       EQU     sprite_055     ; 3x24

; quest_table itself is in quest_ram.s, in the room builder's page.
quest_carry:        DS      QUEST_SPARES    ; records, newest first; $FF none
quest_done:         DB      0               ; $A74C: quest items done
quest_placed:       DB      0               ; $A74B: collectables in place
quest_pieces_on:    DB      0               ; $A70F: the pentagram is there
quest_water_out:    DB      0               ; $A70E: the bucket is out
quest_won:          DB      0
quest_first:        DW      0               ; the room's first record's slot
quest_slots:        DB      0               ; how many, spares included
quest_take_held:    DB      0


; ---------------------------------------------------------------------------
; A new game: the records as they start, the collectables dealt, nothing
; carried and nothing done. $D16F.
; Corrupts AF, BC, DE, HL.
quest_new_game:     ld      hl,quest_start
                    ld      de,quest_table
                    ld      bc,QUEST_RECORDS * QR_LEN
                    ldir
                    ld      a,$FF
                    ld      (quest_carry),a
                    ld      (quest_carry + 1),a
                    ld      (quest_carry + 2),a
                    xor     a
                    ld      (quest_done),a
                    ld      (quest_placed),a
                    ld      (quest_pieces_on),a
                    ld      (quest_water_out),a
                    ld      (quest_won),a

                    ; Five spots in a row, from one of the first sixteen.
                    call    mover_rand
                    and     $3C                 ; the spot, four bytes a spot
                    ld      e,a
                    ld      d,0
                    ld      hl,quest_spots
                    add     hl,de
                    ld      de,quest_table + 4 * QR_LEN   ; the collectables
                    ld      b,5
.deal:              ld      a,(hl)              ; room
                    inc     hl
                    push    hl
                    ld      hl,QR_ROOM
                    add     hl,de
                    ld      (hl),a
                    pop     hl
                    inc     de                  ; -> U
                    ld      a,(hl)
                    ld      (de),a
                    inc     hl
                    inc     de
                    ld      a,(hl)
                    ld      (de),a
                    inc     hl
                    inc     de
                    ld      a,(hl)
                    ld      (de),a
                    inc     hl
                    ld      a,e                 ; on to the next record
                    add     a,QR_LEN - 3
                    ld      e,a
                    jr      nc,.next
                    inc     d
.next:              djnz    .deal
                    ret


; HL -> record A.
; Corrupts AF, DE.
quest_record:       ld      l,a
                    ld      h,0
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl               ; * QR_LEN
                    ld      de,quest_table
                    add     hl,de
                    ret
                    ASSERT  QR_LEN == 8


; What a record's graphic does, as the original's dispatch at $AE2F would.
;   A - the graphic
; Out: A - the behaviour. Corrupts nothing else.
quest_behaviour:    cp      QUEST_GFX_WATER
                    jr      z,.water
                    cp      QUEST_GFX_ITEM
                    jr      c,.none
                    cp      QUEST_GFX_ITEM + 8
                    jr      c,.item
                    cp      QUEST_GFX_THING
                    jr      c,.none
                    cp      QUEST_GFX_THING + 5
                    jr      c,.thing
.none:              xor     a
                    ret
.water:             ld      a,MOVE_WATER
                    ret
.item:              ld      a,MOVE_QUEST
                    ret
.thing:             ld      a,MOVE_COLLECTABLE
                    ret


; ---------------------------------------------------------------------------
; Put this room's records into the pool, after its own objects and before it
; is drawn, so that room_show places and sorts them with everything else --
; $B097. The pentagram's pieces only once all four quest items are done, and as
; background: they lie flat on the floor, under everything.
;
; room_add fills through IX, which is where room_objects_of left it.
; Corrupts AF, BC, DE, HL; IX moves on past what it added.
quest_room_enter:   ld      (quest_first),ix
                    xor     a
                    ld      (quest_slots),a
                    ld      b,QUEST_RECORDS
                    ld      c,0                 ; the record
.record:            push    bc
                    ld      a,c
                    call    quest_record
                    ld      a,(hl)
                    or      a
                    jr      z,.skip             ; an empty record
                    ld      e,a
                    push    hl
                    ld      de,QR_ROOM
                    add     hl,de
                    ld      a,(room_number)
                    cp      (hl)
                    pop     hl
                    jr      nz,.skip            ; not here
                    ld      a,(hl)
                    and     $F8
                    cp      QUEST_GFX_PIECE
                    ld      a,0                 ; no flags
                    jr      nz,.add
                    ld      a,(quest_pieces_on)
                    or      a
                    jr      z,.skip             ; the pentagram is not there yet
                    ld      a,ROOM_FLAG_BACKGROUND ; flat on the floor: under
                                                ; everything, and never sorted

.add:               ld      (room_stage + 7),a  ; the flags
                    ld      a,(room_object_count)
                    cp      ROOM_SLOTS
                    jr      nc,.skip            ; no room in the pool
                    push    hl
                    ld      de,room_stage       ; graphic, U, V, Z, sizes
                    ld      bc,7
                    ldir
                    pop     hl
                    ld      a,(hl)
                    call    quest_behaviour
                    ld      (room_behaviour),a
                    ld      hl,room_stage
                    call    room_add
                    pop     bc
                    push    bc
                    ld      (ix - ROOM_STRIDE + QUEST_INDEX),c
                    ld      hl,quest_slots
                    inc     (hl)
.skip:              pop     bc
                    inc     c
                    djnz    .record
                    xor     a
                    ld      (room_behaviour),a
                    ret


; And, once the room is up, the empty slots to put things down into: as many
; as he can carry, if the pool has them. flyer_room_enter follows, so these
; come before the flyers' and bolts'.
; Corrupts AF, BC, DE, HL, IX.
quest_room_spares:  ld      b,QUEST_SPARES
.spare:             ld      a,(room_object_count)
                    cp      ROOM_SLOTS
                    ret     nc                  ; the pool is full
                    ld      l,a
                    ld      h,0
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl               ; * ROOM_STRIDE
                    ld      de,room_objects
                    add     hl,de
                    push    hl
                    pop     ix
                    call    flyer_blank
                    ld      (ix+OBJ.BUF_L),0
                    ld      (ix+OBJ.BUF_H),0
                    ld      (ix+OBJ.NEXT),0
                    ld      (ix+OBJ.NEXT+1),0
                    ld      (ix+QUEST_INDEX),$FF
                    ld      hl,room_object_count
                    inc     (hl)
                    ld      hl,quest_slots
                    inc     (hl)
                    djnz    .spare
                    ret


; ---------------------------------------------------------------------------
; Leaving a room, or starting it over: every record still lying in it has
; where it now is, and what it has become, written back -- $B115. A slot
; emptied by picking up has already been.
; Corrupts AF, BC, DE, HL, IX.
quest_room_leave:   ld      a,(quest_slots)
                    or      a
                    ret     z
                    ld      b,a
                    ld      ix,(quest_first)
.slot:              push    bc
                    ld      a,(ix+OBJ.GFX)
                    or      a
                    jr      z,.next
                    ld      a,(ix+QUEST_INDEX)
                    inc     a
                    jr      z,.next
                    dec     a
                    call    quest_record
                    ld      a,(ix+OBJ.GFX)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.U)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.V)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.Z)
                    ld      (hl),a
                    ld      de,QR_ROOM - QR_Z
                    add     hl,de
                    ld      a,(room_shown)
                    ld      (hl),a
.next:              ld      de,ROOM_STRIDE
                    add     ix,de
                    pop     bc
                    djnz    .slot
                    xor     a
                    ld      (quest_slots),a
                    ret


; ---------------------------------------------------------------------------
; Put record A into the empty slot IX, at the U, V and Z already in the
; record, and draw it: the way a thing is put down, swapped out, or comes out
; of the well.
;   A - the record, IX -> an empty slot of the room's
; Corrupts everything but IX.
quest_place:        ld      (ix+QUEST_INDEX),a
                    call    quest_record
                    ld      a,(hl)
                    ld      (ix+OBJ.GFX),a
                    call    quest_behaviour
                    ld      (ix+OBJ.BEHAVIOUR),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.U),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.V),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.Z),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.SIZE_U),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.SIZE_V),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.SIZE_Z),a
                    inc     hl
                    ld      a,(room_shown)
                    ld      (hl),a              ; and it is in this room
                    xor     a
                    ld      (ix+OBJ.FLAGS),a
                    ld      (ix+OBJ.DU),a
                    ld      (ix+OBJ.DV),a
                    ld      (ix+OBJ.DZ),a
                    ld      (ix+OBJ.MOVE_STATE),a
                    ld      a,(ix+OBJ.BUF_H)
                    or      a
                    jr      nz,.buffered
                    ld      hl,QUEST_LARGEST
                    call    shift_alloc
.buffered:          push    ix
                    call    room_adjust
                    call    object_place
                    call    depth_insert
                    call    redraw_object
                    pop     ix
                    ret


; An empty slot of the room's, for putting something into.
; Out: IX -> it and carry clear, or carry set for none.
; Corrupts AF, BC, DE.
quest_free_slot:    ld      a,(quest_slots)
                    or      a
                    scf
                    ret     z
                    ld      b,a
                    ld      ix,(quest_first)
                    ld      de,ROOM_STRIDE
.look:              ld      a,(ix+OBJ.GFX)
                    or      a
                    ret     z                   ; carry is clear
                    add     ix,de
                    djnz    .look
                    scf
                    ret


; Take the thing in slot IX out of the room: repainted without it, and the slot
; left empty.
; Corrupts everything but IX.
quest_lift:         push    ix
                    call    object_hide
                    pop     ix
                    ld      (ix+QUEST_INDEX),$FF
                    ret


; ---------------------------------------------------------------------------
; Picking up and putting down -- $BF79, on the number keys, a press at a
; time.
;
; Only standing on something, and not in a doorway. With something he can
; take at his feet -- the well's bucket or a collectable, which is all $C0D4
; allows -- he takes it, and it goes to the front of what he carries; if he
; already had three, the oldest is left where the new one was. With nothing
; there, he puts the oldest down under himself and stands on it, if there is
; the headroom; if he has no oldest, what he carries moves up one.
;   IX -> the legs record
; Corrupts AF, BC, DE, HL, IY. IX comes back as it was.
quest_take:         ld      a,(input_now)
                    and     INPUT_TAKE
                    ld      hl,quest_take_held
                    jr      nz,.pressed
                    ld      (hl),a
                    ret
.pressed:           ld      a,(hl)
                    or      a
                    ret     nz
                    ld      (hl),1

                    bit     0,(ix+CHARACTER_STATE)
                    ret     nz                  ; in the air
                    ld      a,(ix+CHARACTER_DZ)
                    or      a
                    ret     nz                  ; falling
                    bit     7,(ix+CHARACTER_DOOR)
                    ret     z                   ; in a doorway
                    call    sound_jingle_take   ; something to take or not

                    push    ix
                    call    quest_at_feet
                    jr      c,.none_here
                    call    quest_pick_up
                    jr      .done
.none_here:         call    quest_put_down
.done:              pop     ix
                    jp      quest_carry_show


; Something he can take, beside or under him: the well's bucket or a
; collectable not yet in its place. Near enough is his own footprint and four
; more each way, overlapping him in height with his feet four lower -- $C0D4.
;   IX -> the legs record
; Out: IY -> its slot and carry clear, or carry set for nothing.
; Corrupts AF, BC, DE.
quest_at_feet:      ld      a,(quest_slots)
                    or      a
                    scf
                    ret     z
                    ld      b,a
                    ld      iy,(quest_first)
.look:              ld      a,(iy+OBJ.GFX)
                    cp      QUEST_GFX_WATER
                    jr      z,.takeable
                    sub     QUEST_GFX_THING
                    cp      5
                    jr      nc,.next
.takeable:          ld      a,(iy+OBJ.U)
                    sub     (ix+OBJ.U)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(iy+OBJ.SIZE_U)
                    add     a,(ix+OBJ.SIZE_U)
                    add     a,4
                    cp      c
                    jr      c,.next
                    ld      a,(iy+OBJ.V)
                    sub     (ix+OBJ.V)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(iy+OBJ.SIZE_V)
                    add     a,(ix+OBJ.SIZE_V)
                    add     a,4
                    cp      c
                    jr      c,.next
                    ; Along Z the two spans overlap, his lowered by four --
                    ; $C0F0 takes four off his Z for $B8CC's test.
                    ld      a,(ix+OBJ.Z)
                    sub     4
                    ld      c,a                 ; his lowered feet
                    ld      a,(iy+OBJ.Z)
                    add     a,(iy+OBJ.SIZE_Z)
                    cp      c
                    jr      c,.next             ; wholly below him
                    jr      z,.next
                    ld      a,c
                    add     a,COLLIDE_HEIGHT
                    cp      (iy+OBJ.Z)
                    jr      c,.next             ; wholly above him
                    jr      z,.next
                    or      a                   ; found: carry clear
                    ret
.next:              ld      de,ROOM_STRIDE
                    add     iy,de
                    djnz    .look
                    scf
                    ret


; Take the thing in slot IY. If three were carried already, the oldest is left
; where it was, in its slot.
; Corrupts everything.
quest_pick_up:      ld      a,(iy+QUEST_INDEX)
                    ld      c,a
                    call    quest_record        ; it is carried now
                    ld      a,(iy+OBJ.GFX)
                    ld      (hl),a
                    ld      de,QR_ROOM
                    add     hl,de
                    ld      (hl),QUEST_CARRIED
                    push    iy
                    pop     ix
                    push    bc
                    ld      a,(ix+OBJ.U)        ; where the oldest would go
                    ld      (quest_spot),a
                    ld      a,(ix+OBJ.V)
                    ld      (quest_spot + 1),a
                    ld      a,(ix+OBJ.Z)
                    ld      (quest_spot + 2),a
                    call    quest_lift
                    pop     bc
                    ld      a,(quest_carry + 2) ; the oldest, if there is one,
                    inc     a                   ; goes down where this was
                    jr      z,.shuffle
                    dec     a
                    push    bc
                    push    ix
                    call    quest_set_down      ; A: the record, at quest_spot
                    pop     ix
                    call    quest_place
                    pop     bc
.shuffle:           ld      a,(quest_carry + 1)
                    ld      (quest_carry + 2),a
                    ld      a,(quest_carry)
                    ld      (quest_carry + 1),a
                    ld      a,c
                    ld      (quest_carry),a
                    ret


; Put the oldest thing down under him, and stand him on it -- $C017. With no
; oldest, what he carries moves up one ($C091).
;   IX -> the legs record
; Corrupts everything but IX.
quest_put_down:     ld      a,(quest_carry + 2)
                    inc     a
                    jr      z,.shuffle          ; nothing oldest: just move up

                    call    quest_free_slot     ; IX -> somewhere to put it
                    ret     c
                    push    ix
                    ld      ix,player
                    call    quest_headroom
                    pop     iy                  ; IY -> the slot
                    ret     c                   ; nowhere to stand him

                    ld      a,(player + OBJ.U)  ; where he stands now
                    ld      (quest_spot),a
                    ld      a,(player + OBJ.V)
                    ld      (quest_spot + 1),a
                    ld      a,(player + OBJ.Z)
                    ld      (quest_spot + 2),a

                    push    iy                  ; up onto it
                    ld      ix,player
                    ld      (ix+OBJ.DZ),QUEST_DROP_SIZE_Z
                    ld      de,0
                    call    character_move
                    pop     ix                  ; IX -> the slot

                    ld      a,(quest_carry + 2)
                    call    quest_set_down
                    call    quest_place
.shuffle:           ld      a,(quest_carry + 1)
                    ld      (quest_carry + 2),a
                    ld      a,(quest_carry)
                    ld      (quest_carry + 1),a
                    ld      a,$FF
                    ld      (quest_carry),a
                    ret

quest_spot:         DS      3                   ; U, V, Z


; Record A to go down at quest_spot, at a thing's dropped size -- $C061.
;   A - the record
; Out: A - the record still. Corrupts DE, HL.
quest_set_down:     push    af
                    call    quest_record
                    inc     hl
                    ld      a,(quest_spot)
                    ld      (hl),a
                    inc     hl
                    ld      a,(quest_spot + 1)
                    ld      (hl),a
                    inc     hl
                    ld      a,(quest_spot + 2)
                    ld      (hl),a
                    inc     hl
                    ld      (hl),QUEST_DROP_SIZE_UV
                    inc     hl
                    ld      (hl),QUEST_DROP_SIZE_UV
                    inc     hl
                    ld      (hl),QUEST_DROP_SIZE_Z
                    pop     af
                    ret


; Is there room for him twelve higher? Whether his raised box would meet
; anything solid in the room -- $BF1B, with him lifted by twelve first.
;   IX -> the legs record
; Out: carry set if it would.
; Corrupts AF, BC, DE, IY.
quest_headroom:     ld      a,(room_object_count)
                    ld      b,a
                    ld      iy,room_objects
.look:              ld      a,(iy+OBJ.GFX)
                    or      a
                    jr      z,.next
                    bit     2,(iy+OBJ.FLAGS)    ; OBJ_PASSABLE
                    jr      nz,.next
                    ld      a,(iy+OBJ.U)
                    sub     (ix+OBJ.U)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(iy+OBJ.SIZE_U)
                    add     a,(ix+OBJ.SIZE_U)
                    cp      c
                    jr      c,.next
                    jr      z,.next
                    ld      a,(iy+OBJ.V)
                    sub     (ix+OBJ.V)
                    call    character_door_find.abs
                    ld      c,a
                    ld      a,(iy+OBJ.SIZE_V)
                    add     a,(ix+OBJ.SIZE_V)
                    cp      c
                    jr      c,.next
                    jr      z,.next
                    ; Along Z: his raised box runs from Z + 12 to Z + 12 + the
                    ; height of him; it meets anything whose own span overlaps.
                    ld      a,(ix+OBJ.Z)
                    add     a,QUEST_DROP_SIZE_Z
                    ld      c,a                 ; his raised feet
                    ld      a,(iy+OBJ.Z)
                    add     a,(iy+OBJ.SIZE_Z)
                    cp      c
                    jr      c,.next             ; wholly under his feet
                    jr      z,.next
                    ld      a,c
                    add     a,COLLIDE_HEIGHT
                    cp      (iy+OBJ.Z)
                    jr      c,.next             ; wholly above his head
                    jr      z,.next
                    scf
                    ret
.next:              ld      de,ROOM_STRIDE
                    add     iy,de
                    djnz    .look
                    or      a
                    ret


; ---------------------------------------------------------------------------
; What he carries, drawn on the panel: three places along the bottom left, the
; newest first -- $BA3D, which blanks each three bytes by 24 rows and draws
; the graphic in it.
; Corrupts everything but IX and IY.
CARRY_ROW           EQU     SCREEN_ROWS - 24
CARRY_X             EQU     16
CARRY_STEP          EQU     24

quest_carry_show:   ld      hl,quest_carry
                    ld      c,CARRY_X
                    ld      b,QUEST_SPARES
.item:              push    bc
                    push    hl
                    ld      b,CARRY_ROW         ; blank the place
                    ld      e,24
.blank:             push    bc
                    call    pixelAddress
                    xor     a
                    ld      (hl),a
                    inc     hl
                    ld      (hl),a
                    inc     hl
                    ld      (hl),a
                    pop     bc
                    inc     b
                    dec     e
                    jr      nz,.blank
                    pop     hl
                    pop     bc
                    ld      a,(hl)
                    inc     hl
                    push    bc
                    push    hl
                    inc     a
                    jr      z,.empty
                    dec     a
                    call    quest_record
                    ld      a,(hl)              ; its graphic
                    ld      d,0
                    ld      e,SCREEN_ROWS
                    call    screen_sprite
.empty:             pop     hl
                    pop     bc
                    ld      a,c
                    add     a,CARRY_STEP
                    ld      c,a
                    djnz    .item
                    ret


; ---------------------------------------------------------------------------
; The well -- $CFD2. Nothing comes out while the bucket is out. Otherwise
; every turn one of his bolts is touching it counts, and on the thirty-second
; the bucket comes out beside it, eight along V and at Z 141, into a slot
; of the room's -- record QUEST_WATER.
;   IX -> the well
WELL_SHOTS          EQU     32

mover_well:         ld      a,(quest_water_out)
                    or      a
                    ret     nz
                    push    ix
                    pop     iy                  ; IY: the well, for bolt_hits
                    ld      ix,(flyer_slots)
                    ld      de,FLYER_SLOTS * ROOM_STRIDE
                    add     ix,de               ; the first bolt
                    ld      b,BOLT_SLOTS
.bolt:              ld      a,(ix+OBJ.BEHAVIOUR)
                    cp      MOVE_BOLT
                    jr      nz,.not
                    call    bolt_hits
                    jr      c,.hit
.not:               ld      de,ROOM_STRIDE
                    add     ix,de
                    djnz    .bolt
                    push    iy
                    pop     ix
                    ret

.hit:               push    iy
                    pop     ix                  ; the well again
                    inc     (ix+OBJ.MOVE_STATE)
                    ld      a,(ix+OBJ.MOVE_STATE)
                    cp      WELL_SHOTS
                    ret     c
                    ld      (ix+OBJ.MOVE_STATE),0

                    ld      a,(ix+OBJ.U)
                    ld      (quest_spot),a
                    ld      a,(ix+OBJ.V)
                    add     a,8
                    ld      (quest_spot + 1),a
                    ld      a,141
                    ld      (quest_spot + 2),a
                    push    ix
                    call    quest_free_slot
                    jr      c,.no_slot
                    ld      a,QUEST_WATER
                    call    quest_record
                    ld      (hl),QUEST_GFX_WATER
                    inc     hl
                    ld      a,(quest_spot)
                    ld      (hl),a
                    inc     hl
                    ld      a,(quest_spot + 1)
                    ld      (hl),a
                    inc     hl
                    ld      a,(quest_spot + 2)
                    ld      (hl),a
                    inc     hl
                    ld      (hl),8
                    inc     hl
                    ld      (hl),8
                    inc     hl
                    ld      (hl),12
                    ld      a,1
                    ld      (quest_water_out),a
                    ld      a,QUEST_WATER
                    call    quest_place
.no_slot:           pop     ix
                    ret


; ---------------------------------------------------------------------------
; The well's bucket of water -- $D0AC. Until it has a quest item to go to it sinks a
; unit a turn, looking for one in the room; then it flies to it, a unit a turn
; along each floor axis and up to Z 176, and when it has nowhere further to
; go it marks the item done and goes out in a puff. The item it is making for
; is the slot index at WATER_TARGET.
;   IX -> the record
WATER_TARGET        EQU     30
WATER_HIGH          EQU     176

mover_water:        bit     0,(ix+OBJ.MOVE_STATE)
                    jr      nz,.flying

                    ; Sinking, and looking.
                    ld      (ix+OBJ.DZ),0       ; one down, net of gravity
                    call    mover_halt
                    call    mover_move
                    call    water_find_item
                    ret     c
                    ld      (ix+WATER_TARGET),a
                    set     0,(ix+OBJ.MOVE_STATE)
                    ret

.flying:            ld      a,(ix+WATER_TARGET)
                    call    quest_slot_iy       ; IY -> the item
                    ld      a,(iy+OBJ.U)
                    sub     (ix+OBJ.U)
                    call    water_sign
                    ld      (ix+OBJ.DU),a
                    ld      b,a
                    ld      a,(iy+OBJ.V)
                    sub     (ix+OBJ.V)
                    call    water_sign
                    ld      (ix+OBJ.DV),a
                    or      b
                    ld      b,a
                    ld      a,(ix+OBJ.Z)
                    cp      WATER_HIGH
                    ld      a,2                 ; up one, net of gravity
                    jr      c,.rise
                    dec     a                   ; held where it is
.rise:              ld      (ix+OBJ.DZ),a
                    dec     a
                    or      b
                    jr      z,.there
                    jp      mover_move_always

                    ; Over it and up: it is done, to a tune ($D0EE).
.there:             set     0,(iy+OBJ.MOVE_STATE)
                    call    sound_tune_water
                    xor     a
                    ld      (quest_water_out),a
                    ld      a,QUEST_WATER       ; the bucket is spent
                    call    quest_record
                    ld      (hl),0
                    ld      de,QR_ROOM
                    add     hl,de
                    ld      (hl),0
                    ld      (ix+QUEST_INDEX),$FF
                    jp      mover_poof_start

; +1, -1 or 0, the way A says.
water_sign:         or      a
                    ret     z
                    ld      a,1
                    ret     p
                    ld      a,-1
                    ret

; A quest item not yet done, in the room's slots.
; Out: A - its slot index from the first, and carry clear; carry set for none.
; Corrupts BC, DE, IY.
water_find_item:    ld      a,(quest_slots)
                    or      a
                    scf
                    ret     z
                    ld      b,a
                    ld      c,0
                    ld      iy,(quest_first)
                    ld      de,ROOM_STRIDE
.look:              ld      a,(iy+OBJ.GFX)
                    and     $FC
                    cp      QUEST_GFX_ITEM
                    ld      a,c
                    ret     z                   ; carry clear
                    inc     c
                    add     iy,de
                    djnz    .look
                    scf
                    ret

; IY -> the room's slot A, counting from the first record's.
; Corrupts AF, DE.
quest_slot_iy:      ld      iy,(quest_first)
                    or      a
                    ret     z
                    ld      de,ROOM_STRIDE
.step:              add     iy,de
                    dec     a
                    jr      nz,.step
                    ret


; ---------------------------------------------------------------------------
; A quest item -- $CF68. It stands where it is; when the bucket has marked it
; done, it becomes the graphic four on, gives a life and counts, and if that
; makes all four the pentagram comes to room 82 ($D13A).
;   IX -> the record
mover_quest:        call    mover_hover
                    bit     0,(ix+OBJ.MOVE_STATE)
                    ret     z
                    res     0,(ix+OBJ.MOVE_STATE)
                    ld      hl,quest_done
                    inc     (hl)
                    ld      a,(player_lives)    ; a life
                    add     a,1
                    daa
                    ld      (player_lives),a
                    push    ix
                    call    panel_lives
                    pop     ix
                    ld      a,(ix+OBJ.GFX)
                    add     a,4
                    ld      (ix+OBJ.GFX),a
                    ld      c,a

                    ; Its new graphic is taller than its old -- 116-119 rotate
                    ; into 512 bytes where 112-115 took 392 -- and its buffer
                    ; was sized for the old. A new one, sized for this.
                    push    bc
                    ld      l,a
                    ld      h,(high sprite_table) / 2
                    add     hl,hl
                    ld      a,(hl)
                    inc     l
                    ld      h,(hl)
                    ld      l,a
                    call    shift_alloc
                    pop     bc
                    ld      a,(ix+QUEST_INDEX)  ; and in its record, now
                    call    quest_record
                    ld      (hl),c

                    ; All four?
                    ld      a,(quest_done)
                    cp      QUEST_ITEMS
                    jr      c,.drawn
                    ld      a,1
                    ld      (quest_pieces_on),a
.drawn:             jp      mover_move_always


; ---------------------------------------------------------------------------
; A collectable -- $CD16. Anywhere else it is a thing to shove about, like a
; stump. In room 82 with the pentagram there, it flies to its own place in it,
; a unit a turn, and settles as the graphic eight on; five settled and the
; game is won.
;   IX -> the record
mover_collectable:  ld      a,(room_shown)
                    cp      QUEST_PIECES_ROOM
                    jp      nz,mover_pushed
                    ld      a,(quest_pieces_on)
                    or      a
                    jp      z,mover_pushed

                    ld      a,(ix+OBJ.GFX)      ; its place: $D562 by graphic
                    and     7
                    add     a,a
                    ld      e,a
                    ld      d,0
                    ld      hl,quest_targets
                    add     hl,de
                    ld      a,(hl)
                    sub     (ix+OBJ.U)
                    call    water_sign
                    ld      (ix+OBJ.DU),a
                    ld      b,a
                    inc     hl
                    ld      a,(hl)
                    sub     (ix+OBJ.V)
                    call    water_sign
                    ld      (ix+OBJ.DV),a
                    ld      (ix+OBJ.DZ),1       ; it flies, as $B97C moves it
                    or      b
                    jp      nz,mover_move_always

                    ; There: it settles, eight on, and counts.
                    ld      a,(ix+OBJ.GFX)
                    add     a,QUEST_GFX_PLACED - QUEST_GFX_THING
                    ld      (ix+OBJ.GFX),a
                    ld      c,a
                    ld      (ix+OBJ.BEHAVIOUR),MOVE_NONE
                    ld      a,(ix+QUEST_INDEX)
                    call    quest_record
                    ld      (hl),c
                    ld      hl,quest_placed
                    inc     (hl)
                    ld      a,(hl)
                    cp      QUEST_TO_WIN
                    jr      c,.shown
                    ld      a,1
                    ld      (quest_won),a
.shown:             jp      mover_move_always


; ---------------------------------------------------------------------------
; The end of the quest -- $C302: the screen to bright cyan on black, six lines,
; and then the game-over screen with the percentage, as the original falls
; through into it.
WON_INK             EQU     $45

won_text:           game_over_line 48, 9, $46
                    DB      'C'-$30,'O'-$30,'N'-$30,'G'-$30,'R'-$30,'A'-$30,'T'-$30,'U'-$30
                    DB      'L'-$30,'A'-$30,'T'-$30,'I'-$30,'O'-$30,'N'-$30,'S'-$30,$FF
                    game_over_line 80, 7, $45
                    DB      'Y'-$30,'O'-$30,'U'-$30,SPACE_CHAR,'H'-$30,'A'-$30,'V'-$30,'E'-$30
                    DB      SPACE_CHAR,'C'-$30,'O'-$30,'M'-$30,'P'-$30,'L'-$30,'E'-$30,'A'-$30
                    DB      'T'-$30,'E'-$30,'D'-$30,$FF
                    game_over_line 96, 10, $45
                    DB      'T'-$30,'H'-$30,'E'-$30,SPACE_CHAR,'P'-$30,'E'-$30,'N'-$30,'T'-$30
                    DB      'A'-$30,'G'-$30,'R'-$30,'A'-$30,'M'-$30,$FF
                    game_over_line 112, 9, $42
                    DB      'Y'-$30,'O'-$30,'U'-$30,'R'-$30,SPACE_CHAR,'A'-$30,'D'-$30,'V'-$30
                    DB      'E'-$30,'N'-$30,'T'-$30,'U'-$30,'R'-$30,'E'-$30,$FF
                    game_over_line 128, 10, $42
                    DB      'C'-$30,'O'-$30,'N'-$30,'T'-$30,'I'-$30,'N'-$30,'U'-$30,'E'-$30
                    DB      'S'-$30,SPACE_CHAR,'I'-$30,'N'-$30,$FF
                    game_over_line 160, 12, $43
                    DB      'M'-$30,'I'-$30,'R'-$30,'E'-$30,SPACE_CHAR,'M'-$30,'A'-$30,'R'-$30
                    DB      'E'-$30,$FF
                    DB      0

quest_win:          ld      a,WON_INK
                    call    screen_wipe
                    xor     a
                    ld      (print_flash),a
                    ld      hl,won_text
                    call    print_lines
                    call    sound_tune_win      ; $C320
                    ld      b,GAME_OVER_WAIT
.wait:              ld      hl,$2000
.spin:              dec     hl
                    ld      a,h
                    or      l
                    jr      nz,.spin
                    djnz    .wait
                    jp      game_over
