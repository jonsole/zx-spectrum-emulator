; ---------------------------------------------------------------------------
; Things: what the castle keeps where it was left.
;
; Knight Lore keeps no memory of a room. Every visit builds it afresh from its
; record, so a table pushed into a corner is back in the middle when the knight
; returns. Fairlight keeps one table of everything that can move -- each entry
; the room it is in and where -- and builds a room from that; this is the same
; table.
;
; A thing is a placement of a kept template: anything a push moves, and
; anything templates.json's meta.movers marks "kept", which is the soldiers.
; rooms_source.py takes every one out of its room's record and into
; things_start, in bank 4 with the rooms. A new game copies that over
; things_live, which is the one play reads and writes:
;
;   room_build     things_gather copies the entries for the room out of
;                  things_live, with their templates, and room_things_place
;                  puts them in the pool after the room's own objects
;   leaving        things_save writes where each one is back into its entry
;                  -- before the next room is built over the pool, since the
;                  pool is the only place its position is kept meanwhile
;
; Nothing else touches the table, so it costs nothing in play.
; ---------------------------------------------------------------------------

; An entry, as rooms_source.py writes them. U, V and Z are what room_unpack
; makes of a packed position before the template's offsets go on: a thing
; placed from them lands where the same position in the room's record would.
THING_ROOM          EQU     0           ; the room it is in
THING_TEMPLATE      EQU     1           ; its object template
THING_U             EQU     2
THING_V             EQU     3
THING_Z             EQU     4
THING_STATE         EQU     5           ; its driving record's MOVE_STATE
                    ASSERT  THING_STRIDE == 8   ; and two bytes for later stages
                    ASSERT  THING_COUNT <= 255  ; walked with a one-byte count

; One of the room's things, while the room is up: where its entry is in bank 4,
; the record that drives it, the offsets of its template's first sprite -- the
; ones that record was placed with, which things_save takes off again -- and a
; copy of the entry.
HERE_AT             EQU     0           ; 2 bytes
HERE_RECORD         EQU     2           ; 2 bytes
HERE_OFFSETS        EQU     4
HERE_ENTRY          EQU     5           ; THING_STRIDE bytes
HERE_STRIDE         EQU     HERE_ENTRY + THING_STRIDE

things_here_count:  DB      0
things_here:        DS      THINGS_HERE_MOST * HERE_STRIDE


; A new game: every thing back where the castle starts it, and no room up whose
; things want saving.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
things_new_game:    xor     a
                    ld      (things_here_count),a
                IF THING_COUNT
                    ld      a,ROOM_BANK
                    call    page_in
                    ld      hl,things_start
                    ld      de,things_live
                    ld      bc,THING_COUNT * THING_STRIDE
                    ldir
                    ld      a,PAGE_PLAY
                    jp      page_in
                ELSE
                    ret
                ENDIF


; The room being built's things: their entries copied out of things_live into
; things_here, and their templates after the ones room_find copied, with
; room_fg_at pointed at each copy, as room_templates_copy does for the record's.
; A thing's template is copied once a thing, so ROOM_TEMPLATES_MOST counts it
; that way.
;
; It is room_build's and not room_find's, because room_keys asks room_find
; whether rooms exist while the old room is still up, and things_here is what
; things_save will want of the old room.
;
; In:  C = the room
;      room_templates_free -> where the next template copy goes
; Out: things_here, things_here_count
; Corrupts: AF, B, DE, HL, IX
things_gather:      xor     a
                    ld      (things_here_count),a
                IF THING_COUNT
                    ld      a,ROOM_BANK
                    call    page_in
                    ld      de,(room_templates_free)
                    ld      ix,things_here
                    ld      hl,things_live
                    ld      b,THING_COUNT
.next:              ld      a,(hl)              ; THING_ROOM
                    cp      c
                    jr      nz,.skip
                    ld      a,(things_here_count)
                    cp      THINGS_HERE_MOST
                    jr      nc,.skip            ; no room for it: it waits
                    inc     a
                    ld      (things_here_count),a

                    ld      (ix+HERE_AT),l
                    ld      (ix+HERE_AT+1),h
                    push    bc
                    push    hl
                    push    de
                    push    ix
                    pop     de
                    ld      a,e
                    add     a,HERE_ENTRY
                    ld      e,a
                    jr      nc,.copy
                    inc     d
.copy:              ld      bc,THING_STRIDE
                    ldir
                    pop     de

                    ld      a,(ix+HERE_ENTRY+THING_TEMPLATE)
                    ld      hl,OBJECT_STRIDE
                    ld      (room_template_stride),hl
                    ld      hl,block_type_tbl
                    ld      bc,room_fg_at
                    call    room_template_one   ; DE on past the copy

                    ld      bc,HERE_STRIDE
                    add     ix,bc
                    pop     hl
                    pop     bc

.skip:              ld      a,l
                    add     a,THING_STRIDE
                    ld      l,a
                    jr      nc,.on
                    inc     h
.on:                djnz    .next
                    ld      a,PAGE_PLAY
                    jp      page_in
                ELSE
                    ret
                ENDIF


; Put the room's things in the pool, after the objects its record placed: each
; from its template at the place its entry says, exactly as room_objects_of
; would from a packed position, and then with the state it was left in.
;
; In:  IX -> the next free record
;      things_here, things_here_count = the room's things
; Out: IX -> the next free record
; Corrupts: AF, BC, DE, HL, IY
room_things_place:  ld      a,(things_here_count)
                    or      a
                    ret     z
                    ld      b,a
                    ld      iy,things_here
.thing:             push    bc
                    push    ix
                    pop     hl
                    ld      (iy+HERE_RECORD),l  ; the first record is the one
                    ld      (iy+HERE_RECORD+1),h ; that drives it

                    ld      a,(iy+HERE_ENTRY+THING_TEMPLATE)
                    push    af
                    call    mover_find          ; and room_weight
                    ld      (room_behaviour),a
                    pop     af
                    ld      l,a
                    ld      h,0
                    add     hl,hl
                    ld      de,room_fg_at
                    add     hl,de
                    ld      e,(hl)
                    inc     hl
                    ld      d,(hl)
                    ex      de,hl               ; HL -> its template
                    push    hl
                    ld      de,OBJECT_STRIDE - 1
                    add     hl,de
                    ld      a,(hl)              ; the first sprite's offsets
                    ld      (iy+HERE_OFFSETS),a
                    pop     hl

                    ld      a,(iy+HERE_ENTRY+THING_U)
                    ld      (room_base_u),a
                    ld      a,(iy+HERE_ENTRY+THING_V)
                    ld      (room_base_v),a
                    ld      a,(iy+HERE_ENTRY+THING_Z)
                    ld      (room_base_z),a

                    ; Every sprite of the template at this one place, as
                    ; room_objects_of does a group's.
.sprite:            ld      a,(hl)
                    or      a
                    jr      z,.placed
                    call    room_unpack_base
                    push    hl
                    ld      hl,room_stage
                    call    room_add
                    xor     a
                    ld      (room_behaviour),a  ; only the first sprite drives
                    pop     hl
                    ld      bc,OBJECT_STRIDE
                    add     hl,bc
                    jr      .sprite

.placed:            ld      l,(iy+HERE_RECORD)
                    ld      h,(iy+HERE_RECORD+1)
                    ld      de,OBJ.MOVE_STATE
                    add     hl,de
                    ld      a,(iy+HERE_ENTRY+THING_STATE)
                    ld      (hl),a              ; room_add cleared it

                    ld      bc,HERE_STRIDE
                    add     iy,bc
                    pop     bc
                    djnz    .thing
                    ret


; Where the room's things are, written back into their entries: the driving
; record's U, V and Z with its sprite's offsets taken off again, and its
; MOVE_STATE -- which way a soldier is walking, which leg of his round.
;
; Called before every room is built, which is the last moment the pool still
; holds the room being left. It leaves things_here as it is, so a room that
; turns out not to exist, and leaves the old one up, saves the same things
; again when it is really left.
;
; In:  things_here, things_here_count = the room being left's
; Out: nothing
; Corrupts: AF, BC, DE, HL, IX, IY
things_save:        ld      a,(things_here_count)
                    or      a
                    ret     z
                    ld      b,a
                    ld      a,ROOM_BANK
                    call    page_in
                    ld      iy,things_here
.thing:             ld      l,(iy+HERE_RECORD)
                    ld      h,(iy+HERE_RECORD+1)
                    push    hl
                    pop     ix
                    ld      l,(iy+HERE_AT)
                    ld      h,(iy+HERE_AT+1)
                    ld      c,(iy+HERE_OFFSETS)
                    ASSERT  THING_U == 2 && THING_V == 3 && THING_Z == 4 && THING_STATE == 5
                    inc     hl
                    inc     hl                  ; -> THING_U

                    ld      a,(ix+OBJ.U)        ; room_unpack_base's sums,
                    bit     0,c                 ; the other way
                    jr      z,.u
                    sub     8
.u:                 ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.V)
                    bit     1,c
                    jr      z,.v
                    sub     8
.v:                 ld      (hl),a
                    inc     hl
                    ld      a,c
                    and     $FC
                    ld      d,a
                    ld      a,(ix+OBJ.Z)
                    sub     d
                    ld      (hl),a
                    inc     hl
                    ld      a,(ix+OBJ.MOVE_STATE)
                    ld      (hl),a

                    ld      de,HERE_STRIDE
                    add     iy,de
                    djnz    .thing
                    ld      a,PAGE_PLAY
                    jp      page_in
