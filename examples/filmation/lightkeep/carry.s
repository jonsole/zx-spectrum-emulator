; ---------------------------------------------------------------------------
; Carrying: five places and a load limit of 7, worked as Knight Lore works its
; three (handle_pickup_drop, $C00E) -- one key.
;
; Each press of N (or down, on a stick not steering by direction) moves what he
; carries along by one place. Whatever falls off the end is put down, and if
; there is something next to him that can be carried, it is picked up into the
; first place:
;
;   something next to him   it goes into place 1, the rest move along, and
;                           what was in place 5 is put down where it stood
;   nothing next to him     the rest move along, and what was in place 5 is put
;                           down beside him, on the side he faces
;
; So pressing with nothing near brings each thing in turn to the end and puts
; it down. Nothing is ever "used" by a key: food is eaten by being picked up,
; a key opens a door by being carried, and the rest work by being put down
; next to where they are wanted -- stages 5, 6 and 8.
;
; Which things can be carried is templates.json's "pickup" (pickup_tbl), and
; what each weighs is the weight a push already loses (OBJ.DATA_1): the whole
; load may not come to more than 7, counting what drops off the end.
;
; Carried, a thing has no record in any room: its entry in the thing table says
; THING_CARRIED, and its place keeps what its record is made of -- graphic,
; box, flags, behaviour, weight, and the offsets its template places it with --
; so that putting it down rebuilds the record without the template, in a room
; that may never have placed one. Its sprite is resident (sprite_source.py)
; for the same reason.
;
; This is in bank 0, beside the menu, which is paged in for the whole of play.
; Nothing here pages another bank in: what writes the thing table in bank 4 is
; thing_record, in bank 5.
; ---------------------------------------------------------------------------

CARRY_SLOTS         EQU     5
CARRY_LOAD_MOST     EQU     7           ; Fairlight's: a load of 8 is too heavy
PICKUP_REACH        EQU     4           ; how much further than he walks he reaches
CARRY_SAY_TURNS     EQU     25          ; how long a refusal stays up

; A place: what the thing's record is made of while it has none.
SLOT_AT             EQU     0           ; 2: its entry's address in bank 4, or 0
SLOT_GFX            EQU     2
SLOT_SIZE_U         EQU     3
SLOT_SIZE_V         EQU     4
SLOT_SIZE_Z         EQU     5
SLOT_FLAGS          EQU     6
SLOT_MOVE           EQU     7           ; its behaviour
SLOT_WEIGHT         EQU     8
SLOT_OFFSETS        EQU     9           ; its template's first sprite's
SLOT_TEMPLATE       EQU     10
SLOT_STRIDE         EQU     11
SLOT_LAST           EQU     carry_slots + (CARRY_SLOTS - 1) * SLOT_STRIDE

; The flags a record's template gave it, as against the ones drawing sets.
CARRY_FLAGS         EQU     ROOM_FLAG_FLIP | ROOM_FLAG_PASSABLE | ROOM_FLAG_SHARED_SHIFT | ROOM_FLAG_CACHE | ROOM_FLAG_BACKGROUND

; The panel: the five places along the bottom, clear of the scroll -- two
; under the lives, one in the middle, two on the right -- each four characters
; wide and three high, what is in it standing on the bottom row. The refusals
; go above the middle one, between the scroll's two lines.
CARRY_ROWS          EQU     24
CARRY_TOP           EQU     SCREEN_ROWS - CARRY_ROWS
CARRY_SAY_AT        EQU     $4000 + 2 * 2048 + 4 * 32 + 11  ; row 20, column 11
CARRY_SAY_WIDE      EQU     10
FONT_SPACE          EQU     38

carry_slots:        DS      CARRY_SLOTS * SLOT_STRIDE
carry_new:          DS      SLOT_STRIDE ; what is being picked up, on its way in
carry_key_held:     DB      0           ; N, or down, has had its turn
carry_said:         DB      0           ; turns the refusal has left
carry_saying:       DW      0           ; -> it
carry_record:       DW      0           ; putting down: the record it gets,
carry_here:         DW      0           ; its things_here entry,
carry_reused:       DB      0           ; and whether that record was an empty one
carry_skip:         DW      0           ; a record carry_clear leaves out
carry_take_record:  DW      0           ; picking up: its record,
carry_take_here:    DW      0           ; and its things_here entry

; The five places' columns, in pixels.
carry_places:       DB      2 * 8, 6 * 8, 14 * 8, 22 * 8, 26 * 8


; A new game: nothing carried.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
carry_reset:        ld      hl,carry_slots
                    ld      de,carry_slots + 1
                    ld      bc,CARRY_SLOTS * SLOT_STRIDE - 1
                    ld      (hl),0
                    ldir
                    xor     a
                    ld      (carry_key_held),a
                    ld      (carry_said),a
                    ret


; Once a turn, while he is about: N, or down.
;
; One press does one thing, and only while he stands inside the room's edges --
; held down in the air, it waits for him to land -- as Knight Lore's does.
;
; In:  nothing
; Out: nothing
; Corrupts: everything
carry_turn:         ld      a,(carry_said)
                    or      a
                    jr      z,.pick
                    dec     a
                    ld      (carry_said),a
                    push    af
                    ld      hl,(carry_saying)
                    call    nz,carry_print      ; again: a region may have wiped it
                    pop     af
                    call    z,carry_unsay

                    ; N whatever is steering; down on a stick as well, unless the
                    ; stick is steering by direction, when down is a way to go.
.pick:              ld      a,(input_now)
                    ld      b,a
                    and     INPUT_PICKUP_DIR
                    jr      nz,.asked
                    ld      a,(menu_mode)
                    and     $08
                    jr      nz,.let_go
                    ld      a,b
                    and     INPUT_PICKUP
                    jr      nz,.asked
.let_go:            xor     a
                    ld      (carry_key_held),a
                    ret

.asked:             ld      a,(carry_key_held)
                    or      a
                    ret     nz                  ; this press has had its turn

                    ; Inside the room's edges -- chk_plyr_OOB, which keeps a knight
                    ; in a doorway from leaving something in it.
                    ld      ix,player
                    ld      a,(ix+OBJ.U)
                    sub     128
                    jp      p,.u
                    neg
.u:                 add     a,(ix+OBJ.SIZE_U)
                    ld      hl,room_half_u
                    cp      (hl)
                    ret     nc
                    ld      a,(ix+OBJ.V)
                    sub     128
                    jp      p,.v
                    neg
.v:                 add     a,(ix+OBJ.SIZE_V)
                    inc     hl                  ; room_half_v
                    cp      (hl)
                    ret     nc

                    ; And standing, not jumping or falling.
                    bit     0,(ix+CHARACTER_STATE)
                    ret     nz
                    ld      a,(ix+CHARACTER_DZ)
                    or      a
                    ret     nz

                    ld      a,1
                    ld      (carry_key_held),a

                    ;; NB: fall through into carry_press


; One press: see the top of the file.
;
; Everything is checked before anything is done, so a refusal leaves the room
; and the places as they were.
;
; In:  nothing
; Out: nothing
; Corrupts: everything
carry_press:        call    carry_find
                    jr      nc,.nothing

                    ; Something to pick up. The load it makes, with what drops off
                    ; the end taken away.
                    ld      (carry_take_record),ix
                    ld      (carry_take_here),iy
                    call    carry_load
                    ld      hl,SLOT_LAST
                    call    carry_weight_of
                    sub     c
                    add     a,(ix+OBJ.DATA_1)   ; its weight, from room_add
                    cp      CARRY_LOAD_MOST + 1
                    ld      hl,carry_too_heavy
                    jp      nc,carry_say

                    ; What drops off the end goes where the new one stands --
                    ; Knight Lore's pickup_object puts the oldest down in the same
                    ; place -- if it fits there, which the new one's own record,
                    ; going, does not count against.
                    call    carry_last
                    jr      z,.take
                    ld      ix,(carry_take_record)
                    ld      a,(ix+OBJ.U)
                    ld      (room_stage + 1),a
                    ld      a,(ix+OBJ.V)
                    ld      (room_stage + 2),a
                    ld      a,(ix+OBJ.Z)
                    ld      (room_stage + 3),a
                    ld      (carry_skip),ix
                    ld      iy,SLOT_LAST
                    call    carry_fits
                    jp      c,carry_blocked

.take:              ld      ix,(carry_take_record)
                    ld      iy,(carry_take_here)
                    call    carry_take
                    call    carry_last
                    jr      z,.shift
                    ld      iy,SLOT_LAST
                    call    carry_put           ; room_stage is still the place
.shift:             call    carry_shift
                    call    sound_pickup
                    jp      carry_show

                    ; Nothing to pick up: what is on the end goes down beside him,
                    ; if it fits, and the rest move along.
.nothing:           ld      hl,carry_new        ; nothing comes in
                    ld      de,carry_new + 1
                    ld      bc,SLOT_STRIDE - 1
                    ld      (hl),0
                    ldir
                    call    carry_last
                    jr      z,.turn
                    ld      iy,SLOT_LAST
                    call    carry_beside
                    ld      hl,0
                    ld      (carry_skip),hl
                    call    carry_fits
                    jp      c,carry_blocked
                    ld      iy,SLOT_LAST
                    call    carry_put
.turn:              call    carry_shift
                    call    sound_pickup
                    jp      carry_show

carry_blocked:      ld      hl,carry_blocked_text
                    jp      carry_say


; Is there something in the last place?
;
; In:  nothing
; Out: NZ if there is
; Corrupts: AF
carry_last:         ld      a,(SLOT_LAST + SLOT_AT)
                    push    hl
                    ld      hl,SLOT_LAST + SLOT_AT + 1
                    or      (hl)
                    pop     hl
                    ret


; Everything moves along a place -- the last, already put down or empty, is
; written over -- and carry_new comes into the first. adjust_carried, $C12B.
;
; In:  carry_new = what comes in, or all 0 for nothing
; Out: nothing
; Corrupts: BC, DE, HL
carry_shift:        ld      hl,SLOT_LAST - 1
                    ld      de,SLOT_LAST + SLOT_STRIDE - 1
                    ld      bc,(CARRY_SLOTS - 1) * SLOT_STRIDE
                    lddr
                    ld      hl,carry_new
                    ld      de,carry_slots
                    ld      bc,SLOT_STRIDE
                    ldir
                    ret


; The first thing next to him that can be carried.
;
; In:  nothing
; Out: carry set, IX -> its driving record and IY -> its things_here entry;
;        carry clear if there is none
; Corrupts: AF, BC, DE, HL
carry_find:         ld      a,(things_here_count)
                    or      a
                    ret     z
                    ld      b,a
                    ld      iy,things_here
.thing:             ld      l,(iy+HERE_RECORD)
                    ld      h,(iy+HERE_RECORD+1)
                    ld      a,h
                    or      l
                    jr      z,.next             ; gone from the room
                    push    hl
                    pop     ix
                    ld      a,(iy+HERE_ENTRY+THING_TEMPLATE)
                    call    carry_pickable
                    jr      nc,.next
                    push    bc                  ; carry_near takes B, the count
                    ld      de,PICKUP_REACH * 257
                    call    carry_near
                    pop     bc
                    ret     c
.next:              ld      de,HERE_STRIDE
                    add     iy,de
                    djnz    .thing
                    or      a
                    ret


; Pick a thing up into carry_new: what its record is made of, its entry
; written as carried, and every record of it out of the room.
;
; In:  IX -> its driving record; IY -> its things_here entry
; Out: nothing
; Corrupts: everything
carry_take:         ld      hl,carry_new
                    ld      a,(iy+HERE_AT)
                    ld      (hl),a
                    inc     hl
                    ld      a,(iy+HERE_AT+1)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.GFX)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.SIZE_U)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.SIZE_V)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.SIZE_Z)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.FLAGS)
                    and     CARRY_FLAGS
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.BEHAVIOUR)
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.DATA_1)
                    ld      (hl),a
                    inc     hl
                    ld      a,(iy+HERE_OFFSETS)
                    ld      (hl),a
                    inc     hl
                    ld      a,(iy+HERE_ENTRY+THING_TEMPLATE)
                    ld      (hl),a

                    ld      a,THING_CARRIED
                    call    thing_record

                    ld      b,(iy+HERE_COUNT)
                    xor     a
                    ld      (iy+HERE_RECORD),a
                    ld      (iy+HERE_RECORD+1),a
.hide:              push    bc
                    push    ix
                    call    object_hide
                    pop     ix
                    ld      de,ROOM_STRIDE
                    add     ix,de
                    pop     bc
                    djnz    .hide
                    ret


; Where beside him a thing would go down: his own place, moved out along the
; way he faces by his half, its half and one to spare. Facing 0 is -U, 1 +V,
; 2 +U and 3 -V (player.s). At his feet's height, to fall from there.
;
; In:  IY -> the place
; Out: room_stage + 1 to 3 = U, V and Z
; Corrupts: AF, BC, HL, IX
carry_beside:       ld      ix,player
                    ld      a,(ix+OBJ.U)
                    ld      (room_stage + 1),a
                    ld      a,(ix+OBJ.V)
                    ld      (room_stage + 2),a
                    ld      a,(ix+OBJ.Z)
                    ld      (room_stage + 3),a
                    ld      a,(ix+CHARACTER_FACING)
                    and     3
                    ld      c,a
                    ld      hl,room_stage + 1   ; U for 0 and 2,
                    ld      b,(iy+SLOT_SIZE_U)
                    bit     0,c
                    jr      z,.axis
                    inc     hl                  ; V for 1 and 3
                    ld      b,(iy+SLOT_SIZE_V)
.axis:              ld      a,b
                    add     a,CHARACTER_HALF_U + 1
                    ld      b,a                 ; how far out
                    ld      a,c
                    dec     a                   ; 1 and 2 go up the axis,
                    cp      2                   ; 0 and 3 down it
                    ld      a,(hl)
                    jr      c,.up
                    sub     b
                    jr      .placed
.up:                add     a,b
.placed:            ld      (hl),a
                    ret


; Would the thing in a place fit at room_stage's U, V and Z: inside the room's
; edges, all of it, and clear of everything solid but carry_skip? Fills in the
; rest of room_stage from the place as it goes, for carry_put.
;
; In:  IY -> the place; room_stage + 1 to 3 = where
; Out: carry set if it would not
; Corrupts: AF, BC, DE, HL, IX
carry_fits:         ld      a,(iy+SLOT_GFX)
                    ld      (room_stage + 0),a
                    ld      a,(iy+SLOT_SIZE_U)
                    ld      (room_stage + 4),a
                    ld      a,(iy+SLOT_SIZE_V)
                    ld      (room_stage + 5),a
                    ld      a,(iy+SLOT_SIZE_Z)
                    ld      (room_stage + 6),a
                    ld      a,(iy+SLOT_FLAGS)
                    ld      (room_stage + 7),a

                    ld      a,(room_stage + 1)
                    sub     128
                    jp      p,.eu
                    neg
.eu:                add     a,(iy+SLOT_SIZE_U)
                    ld      hl,room_half_u
                    cp      (hl)
                    jr      z,.inside_u
                    ccf
                    ret     c                   ; past the edge
.inside_u:          ld      a,(room_stage + 2)
                    sub     128
                    jp      p,.ev
                    neg
.ev:                add     a,(iy+SLOT_SIZE_V)
                    inc     hl
                    cp      (hl)
                    jr      z,carry_clear
                    ccf
                    ret     c

                    ;; NB: fall through into carry_clear


; Is room_stage's box clear of everything solid in the room but carry_skip?
; Boxes that only touch are apart, as the collision has them.
;
; In:  room_stage = graphic, U, V, Z, half U, half V, height, flags
; Out: carry set if something is in the way
; Corrupts: AF, BC, DE, HL, IX
carry_clear:        ld      a,(room_object_count)
                    or      a
                    ret     z
                    ld      b,a
                    ld      ix,room_objects
.record:            ld      a,(ix+OBJ.GFX)
                    or      a
                    jr      z,.next
                    ld      a,(ix+OBJ.FLAGS)
                    and     OBJ_PASSABLE
                    jr      nz,.next
                    push    ix
                    pop     hl
                    ld      de,(carry_skip)
                    or      a
                    sbc     hl,de
                    jr      z,.next             ; the one being picked up
                    ld      a,(room_stage + 4)  ; along U: the halves together,
                    add     a,(ix+OBJ.SIZE_U)   ; and the difference within them
                    ld      d,a
                    ld      a,(room_stage + 1)
                    add     a,d
                    sub     (ix+OBJ.U)
                    jr      z,.next
                    sla     d
                    cp      d
                    jr      nc,.next
                    ld      a,(room_stage + 5)  ; along V
                    add     a,(ix+OBJ.SIZE_V)
                    ld      d,a
                    ld      a,(room_stage + 2)
                    add     a,d
                    sub     (ix+OBJ.V)
                    jr      z,.next
                    sla     d
                    cp      d
                    jr      nc,.next
                    ld      a,(ix+OBJ.Z)        ; and in height
                    add     a,(ix+OBJ.SIZE_Z)
                    ld      d,a
                    ld      a,(room_stage + 3)
                    cp      d
                    jr      nc,.next            ; at its top or above
                    ld      e,a
                    ld      a,(room_stage + 6)
                    add     a,e
                    cp      (ix+OBJ.Z)
                    jr      z,.next
                    jr      c,.next             ; at its base or below
                    scf
                    ret
.next:              ld      de,ROOM_STRIDE
                    add     ix,de
                    djnz    .record
                    or      a
                    ret


; Put the thing in a place into the room, at room_stage, which carry_fits has
; filled in and found clear: a record for it -- an empty one, of something
; picked up in this room, or one more at the end of the pool -- and a
; things_here entry, found the same way; its entry in the table given this
; room; and it placed, sorted and drawn. The place is emptied. Refused, with
; BLOCKED, only if the pool or things_here is full.
;
; In:  IY -> the place
; Out: nothing
; Corrupts: everything
carry_put:          push    iy
                    call    carry_free_record
                    jr      nc,.full
                    ld      (carry_record),ix
                    call    carry_free_here
                    ld      (carry_here),iy
                    jr      c,.room
.full:              pop     iy
                    jp      carry_blocked

                    ; room_add counts it, and refuses a full pool -- so a record
                    ; that is counted already, an empty one, is uncounted first.
.room:              pop     iy
                    ld      a,(carry_reused)
                    or      a
                    jr      z,.add
                    ld      hl,room_object_count
                    dec     (hl)
.add:               ld      a,(iy+SLOT_MOVE)
                    ld      (room_behaviour),a
                    ld      a,(iy+SLOT_WEIGHT)
                    ld      (room_weight),a
                    ld      ix,(carry_record)
                    ld      hl,room_stage
                    call    room_add            ; and nudges it
                    ld      ix,(carry_record)

                    ; Its own rotation buffer for the rest of the room, as
                    ; special_fill gave a collectable one, sized for its sprite;
                    ; shift_alloc rotates it at draw time if there is no room.
                    ld      l,(ix+OBJ.GFX)
                    ld      h,(high sprite_table) / 2
                    add     hl,hl
                    ld      a,(hl)
                    inc     l
                    ld      h,(hl)
                    ld      l,a
                    call    shift_alloc

                    ; Its things_here entry, which things_save, things_fall and the
                    ; next pick-up go by.
                    push    iy
                    pop     hl                  ; HL -> the place
                    ld      iy,(carry_here)
                    ld      a,(hl)
                    ld      (iy+HERE_AT),a
                    inc     hl
                    ld      a,(hl)
                    ld      (iy+HERE_AT+1),a
                    ld      de,(carry_record)
                    ld      (iy+HERE_RECORD),e
                    ld      (iy+HERE_RECORD+1),d
                    ld      (iy+HERE_COUNT),1
                    ld      de,SLOT_OFFSETS - 1
                    add     hl,de
                    ld      a,(hl)
                    ld      (iy+HERE_OFFSETS),a
                    inc     hl
                    ld      a,(hl)
                    ld      (iy+HERE_ENTRY+THING_TEMPLATE),a
                    ld      de,-SLOT_TEMPLATE
                    add     hl,de
                    push    hl                  ; the place, to empty

                    ; Its entry in the table: this room, and here.
                    ld      a,(room_shown)
                    call    thing_record

                    ; Into the room: placed, sorted and drawn.
                    ld      ix,(carry_record)
                    call    object_place
                    ld      ix,(carry_record)
                    call    depth_insert
                    ld      ix,(carry_record)
                    call    redraw_object

                    pop     hl                  ; and the place is empty
                    ld      d,h
                    ld      e,l
                    inc     de
                    ld      bc,SLOT_STRIDE - 1
                    ld      (hl),0
                    ldir
                    ret


; A record to put a thing down into: the first empty one in the pool, of
; something picked up in this room, or else one more at the end.
;
; In:  nothing
; Out: carry set and IX -> the record, carry_reused saying which; carry clear
;        if the pool is full
; Corrupts: AF, BC, DE
carry_free_record:  ld      ix,room_objects
                    ld      a,(room_object_count)
                    or      a
                    jr      z,.end
                    ld      b,a
                    ld      de,ROOM_STRIDE
.look:              ld      a,(ix+OBJ.GFX)
                    or      a
                    jr      z,.empty
                    add     ix,de
                    djnz    .look
.end:               ld      a,(room_object_count)
                    cp      ROOM_SLOTS
                    ret     nc                  ; full
                    xor     a
                    ld      (carry_reused),a
                    scf
                    ret
.empty:             ld      a,1
                    ld      (carry_reused),a
                    scf
                    ret


; A things_here entry for something put down: an empty one -- of something
; picked up or fallen through, or that the pool had no room for when the room
; was built, whose own entry in the table is untouched by this -- or one more
; at the end, counted.
;
; In:  nothing
; Out: carry set and IY -> the entry; carry clear if all of them are in use
; Corrupts: AF, B, DE
carry_free_here:    ld      iy,things_here
                    ld      de,HERE_STRIDE
                    ld      a,(things_here_count)
                    or      a
                    jr      z,.end
                    ld      b,a
.look:              ld      a,(iy+HERE_RECORD)
                    or      (iy+HERE_RECORD+1)
                    scf
                    ret     z                   ; empty: this one
                    add     iy,de
                    djnz    .look
.end:               ld      a,(things_here_count)
                    cp      THINGS_HERE_MOST
                    ret     nc                  ; all in use
                    inc     a
                    ld      (things_here_count),a
                    scf
                    ret


; Can a thing of this template be picked up?
;
; In:  A = the object template
; Out: carry set if it can
; Corrupts: F, C, HL
carry_pickable:     ld      hl,pickup_tbl
                    ld      c,a
.next:              ld      a,(hl)
                    cp      $FF
                    jr      z,.no
                    inc     hl
                    cp      c
                    jr      nz,.next
                    ld      a,c
                    scf
                    ret
.no:                ld      a,c
                    or      a
                    ret


; Is the record in IX next to him? Within his box and its, and E further, along
; the floor; and in height, within D of overlapping -- special_near, Knight
; Lore's is_on_or_near_obj ($C17A).
;
; In:  IX -> the record; E = the reach along the floor, D = in height
; Out: carry set if it is near
; Corrupts: AF, BC
carry_near:         ld      a,(player + OBJ.U)
                    sub     (ix+OBJ.U)
                    call    .abs
                    ld      c,a
                    ld      a,(player + OBJ.SIZE_U)
                    add     a,(ix+OBJ.SIZE_U)
                    add     a,e
                    ld      b,a
                    ld      a,c
                    cp      b
                    ret     nc
                    ld      a,(player + OBJ.V)
                    sub     (ix+OBJ.V)
                    call    .abs
                    ld      c,a
                    ld      a,(player + OBJ.SIZE_V)
                    add     a,(ix+OBJ.SIZE_V)
                    add     a,e
                    ld      b,a
                    ld      a,c
                    cp      b
                    ret     nc
                    ; Z is a base and a height: whichever is lower, the other's
                    ; base has to be under its top.
                    ld      a,(player + OBJ.Z)
                    sub     d
                    sub     (ix+OBJ.Z)
                    jp      p,.above
                    neg
                    ld      c,a
                    ld      a,COLLIDE_HEIGHT
                    add     a,d
                    ld      b,a
                    ld      a,c
                    cp      b
                    ret
.above:             cp      (ix+OBJ.SIZE_Z)
                    ret
.abs:               ret     p
                    neg
                    ret


; What all five places weigh together.
;
; In:  nothing
; Out: A = the load
; Corrupts: F, BC, DE, HL
carry_load:         ld      hl,carry_slots
                    ld      b,CARRY_SLOTS
                    ld      e,0
.slot:              call    carry_weight_of
                    ld      a,e
                    add     a,c
                    ld      e,a
                    push    de
                    ld      de,SLOT_STRIDE
                    add     hl,de
                    pop     de
                    djnz    .slot
                    ld      a,e
                    ret


; What the thing in one place weighs: 0 for an empty one.
;
; In:  HL -> the place
; Out: C = its weight
; Corrupts: nothing else
carry_weight_of:    push    af
                    push    hl
                    ld      a,(hl)
                    inc     hl
                    or      (hl)
                    ld      c,0
                    jr      z,.done
                    push    de
                    ld      de,SLOT_WEIGHT - 1
                    add     hl,de
                    ld      c,(hl)
                    pop     de
.done:              pop     hl
                    pop     af
                    ret


; The five places on the panel, in white, each emptied and with what is in it
; standing on the bottom row.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF'
carry_show:         ld      hl,carry_slots
                    ld      de,carry_places
                    ld      b,CARRY_SLOTS
.place:             push    bc
                    push    de
                    push    hl
                    ld      a,(de)
                    ld      c,a                 ; its x
                    call    carry_show_one
                    pop     hl
                    ld      de,SLOT_STRIDE
                    add     hl,de
                    pop     de
                    inc     de
                    pop     bc
                    djnz    .place
                    ret

; One place.
;
; In:  HL -> it; C = its x in pixels
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF'
carry_show_one:     push    hl
                    push    bc
                    ld      a,c                 ; its colour: white, four cells by
                    rrca                        ; three
                    rrca
                    rrca
                    and     $1F
                    ld      e,a
                    ld      d,0
                    ld      hl,$5800 + 21 * 32
                    add     hl,de
                    ld      a,$47
                    ld      bc,4 << 8 | 3
                    call    attr_fill
                    pop     bc
                    ld      b,CARRY_TOP         ; emptied
.blank:             call    pixelAddress
                    xor     a
                    ld      (hl),a
                    inc     hl
                    ld      (hl),a
                    inc     hl
                    ld      (hl),a
                    inc     hl
                    ld      (hl),a
                    inc     b
                    ld      a,b
                    cp      SCREEN_ROWS
                    jr      c,.blank
                    pop     hl
                    ld      a,(hl)
                    inc     hl
                    or      (hl)
                    ret     z
                    inc     hl
                    ld      a,(hl)              ; SLOT_GFX
                    ld      de,SCREEN_ROWS      ; D = 0: the right way round
                    jp      screen_sprite


; The panel has just been drawn, or a region reaching it has: put the places
; back if the region reached their rows.
;
; In:  A = 0 for the whole panel, 1 for a region (view_y_extent)
; Out: nothing
; Corrupts: AF, BC, DE, HL, AF'
carry_panel:        or      a
                    jr      z,carry_show
                    ld      a,(view_y_extent + 1)   ; the row after it
                    cp      CARRY_TOP + 1
                    ret     c
                    jr      carry_show


; A refusal on the panel, for CARRY_SAY_TURNS turns.
;
; In:  HL -> the words, in the font's codes, ended by $FF
; Out: nothing
; Corrupts: AF, B, DE, HL
carry_say:          ld      (carry_saying),hl
                    ld      a,CARRY_SAY_TURNS
                    ld      (carry_said),a

                    ;; NB: fall through into carry_print


; Print the words, padded out with spaces to CARRY_SAY_WIDE.
;
; In:  HL -> the words, ended by $FF
; Out: nothing
; Corrupts: AF, B, DE, HL
carry_print:        ld      de,CARRY_SAY_AT
                    ld      b,CARRY_SAY_WIDE
.char:              ld      a,(hl)
                    cp      $FF
                    jr      z,.pad
                    inc     hl
                    call    .one
                    djnz    .char
                    ret
.pad:               ld      a,FONT_SPACE
                    call    .one
                    djnz    .pad
                    ret
.one:               push    bc
                    push    hl
                    push    de
                    ex      de,hl
                    call    print_char
                    pop     de
                    inc     de
                    pop     hl
                    pop     bc
                    ret

carry_unsay:        ld      hl,carry_nothing
                    jr      carry_print

carry_too_heavy:    DB      'T'-55, 'O'-55, 'O'-55, FONT_SPACE, 'H'-55, 'E'-55, 'A'-55, 'V'-55, 'Y'-55, $FF
carry_blocked_text: DB      'B'-55, 'L'-55, 'O'-55, 'C'-55, 'K'-55, 'E'-55, 'D'-55, $FF
carry_nothing:      DB      $FF
