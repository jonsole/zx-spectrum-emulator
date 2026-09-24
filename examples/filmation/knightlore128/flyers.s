; ---------------------------------------------------------------------------
; What falls out of the sky -- Pentagram's, from ../pentagram/flyers.s.
;
; No room places these. Stay in a room with a sky long enough and something
; drops into it from Z 216, somewhere near the middle, and then another --
; Pentagram's $CBAB, every turn. It is one of eight, picked at random:
;
;   the homers, which fly at him and do no harm -- mover_homer, $CC4B
;   a faller that roams in two frames, and kills -- mover_faller, $D1FD
;   a faller that roams in four, and kills -- mover_faller4, $D251
;
; Which rooms have a sky is rooms.json's to say, a room at a time ("sky":
; true), and rooms_source.py makes room_sky from it. Only a sky room loads the
; flyers' sprites into the room page (SKY_GROUPS, in sprite_sheet.py), so only
; a sky room may drop one. Pentagram drops into any room but the one with the
; well, or a quest item, or a piece of the pentagram; here that is a room
; without "sky".
;
; The wait is Pentagram's: the timer starts at nothing, so the first countdown
; runs 255 turns; after that a turn has a one-in-four chance, and a drop sets
; it back to FLYER_WAIT. Pentagram's wait grows with the quest items still to
; find, from 8 to 24; there is no such quest here, so it is always the longest.
; Two at once and it stops trying until one goes.
;
; The records are the next four after everything the room holds: two for
; flyers, then two for his bolts -- see player_fire.
; ---------------------------------------------------------------------------

FLYER_NOW           EQU     0               ; 1: drop at once, for testing
FLYER_SLOTS         EQU     2
BOLT_SLOTS          EQU     2
EXTRA_SLOTS         EQU     FLYER_SLOTS + BOLT_SLOTS
FLYER_Z             EQU     216             ; where they drop from
FLYER_WAIT          EQU     (2 + 4) * 4     ; turns between drops

; What a drop can be, as Pentagram's own table at $CC09 has it -- 164, 160,
; 48, 80, 168, 160, 48, 80 -- with what each is: its graphic, its behaviour,
; and its size across. The homers are ten across, which mover_homer keeps
; setting; everything else is eight.
flyer_pick:         DB      GFX_PENTAGRAM_HOMER_2_G196, MOVE_HOMER, 10     ; 164
                    DB      GFX_PENTAGRAM_HOMER_4_G192, MOVE_HOMER, 10     ; 160
                    DB      GFX_PENTAGRAM_HOMER_7_G188, MOVE_HOMER, 10     ; 48
                    DB      GFX_PENTAGRAM_FALLER_5, MOVE_FALLER, 8         ; 80
                    DB      GFX_PENTAGRAM_FALLER_1, MOVE_FALLER4, 8        ; 168
                    DB      GFX_PENTAGRAM_HOMER_4_G192, MOVE_HOMER, 10     ; 160
                    DB      GFX_PENTAGRAM_HOMER_7_G188, MOVE_HOMER, 10     ; 48
                    DB      GFX_PENTAGRAM_FALLER_5, MOVE_FALLER, 8         ; 80

flyer_timer:        DB      0               ; started over in each room
flyer_banned:       DB      0               ; this room drops nothing
flyer_slots:        DW      0               ; the first of the two records;
                                            ; the bolts' two follow them


; Make the records a room keeps for flyers and for his bolts: the next four
; after everything else, blank until something falls or is fired into them.
; And whether this room has a sky at all, and the whole wait again before it
; drops anything.
;
; In:  nothing
; Out: flyer_slots -> the first of the four, now counted in room_object_count
; Corrupts: AF, B, DE, HL, IX
flyer_room_enter:   ld      a,FLYER_NOW         ; 0 wraps to 255 on the first
                    ld      (flyer_timer),a     ; turn; 1 runs out on it
                    ld      a,(room_object_count)
                    ld      l,a
                    ld      h,0
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl               ; * ROOM_STRIDE
                    ld      de,room_objects
                    add     hl,de
                    ld      (flyer_slots),hl

                    ; This room's bit of room_sky: set, it has a sky.
                    ld      a,(room_shown)
                    ld      b,a
                    rrca
                    rrca
                    rrca
                    and     $1F
                    ld      e,a
                    ld      d,0
                    ld      hl,room_sky
                    add     hl,de
                    ld      a,b
                    and     7
                    inc     a
                    ld      b,a
                    ld      a,(hl)
.bit:               rrca
                    djnz    .bit                ; carry: the room's bit
                    sbc     a,a
                    cpl                         ; $FF: banned, 0: a sky
                    ld      (flyer_banned),a

                    ld      ix,(flyer_slots)
                    ld      b,EXTRA_SLOTS
.slot:              call    object_blank
                    ld      (ix+OBJ.BUF_L),0    ; no buffer yet: the first drop
                    ld      (ix+OBJ.BUF_H),0    ; into it takes one
                    ld      (ix+OBJ.NEXT),0     ; and in no list
                    ld      (ix+OBJ.NEXT+1),0
                    ld      de,ROOM_STRIDE
                    add     ix,de
                    djnz    .slot
                    ld      a,(room_object_count)
                    add     a,EXTRA_SLOTS
                    ld      (room_object_count),a
                    ret


; One turn of the sky -- $CBAB.
;
; In:  nothing
; Out: nothing
; Corrupts: everything
flyer_step:         ld      a,(flyer_banned)
                    or      a
                    ret     nz
                    ld      hl,flyer_timer
                    dec     (hl)
                    ret     nz
                    ld      (hl),1              ; run out: from now, every turn
                    call    mover_rand
                    and     3
                    ret     nz                  ; ...a one in four chance
                    ld      a,FLYER_WAIT - FLYER_NOW * (FLYER_WAIT - 1)   ; 1 if now
                    ld      (flyer_timer),a

                    ld      ix,(flyer_slots)
                    ld      a,(ix+OBJ.GFX)
                    or      a
                    jr      z,.free
                    ld      de,ROOM_STRIDE
                    add     ix,de
                    ld      a,(ix+OBJ.GFX)
                    or      a
                    ret     nz                  ; both taken

.free:              call    mover_rand          ; which of the eight
                    rrca
                    rrca
                    rrca
                    and     7
                    ld      e,a
                    add     a,a
                    add     a,e                 ; three bytes a pick
                    ld      e,a
                    ld      d,0
                    ld      hl,flyer_pick
                    add     hl,de
                    ld      a,(hl)
                    ld      (ix+OBJ.GFX),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.BEHAVIOUR),a
                    inc     hl
                    ld      a,(hl)
                    ld      (ix+OBJ.SIZE_U),a
                    ld      (ix+OBJ.SIZE_V),a
                    ld      (ix+OBJ.SIZE_Z),8

                    ; Somewhere near the middle, high up: 104 to 151 each way.
                    call    mover_rand
                    and     $2F
                    add     a,$68
                    ld      (ix+OBJ.U),a
                    call    mover_rand
                    and     $2F
                    add     a,$68
                    ld      (ix+OBJ.V),a
                    ld      (ix+OBJ.Z),FLYER_Z

                    xor     a
                    ld      (ix+OBJ.FLAGS),a
                    ld      (ix+OBJ.DU),a
                    ld      (ix+OBJ.DV),a
                    ld      (ix+OBJ.DZ),a
                    ld      (ix+OBJ.MOVE_STATE),a
                    ld      (ix+HOMER_ACC_U),a
                    ld      (ix+HOMER_ACC_V),a

                    ; One buffer for the slot's life in the room, big enough for
                    ; any flyer, because a slot changes graphic every turn and
                    ; object_update would otherwise size one for whatever it
                    ; happened to show first. The flyers' sprites are in the room
                    ; page only while a sky room is up, so the size comes from
                    ; sprite_sky_largest, which sprite_source.py makes the size of
                    ; the largest of them.
                    ld      a,(ix+OBJ.BUF_H)
                    or      a
                    jr      nz,.buffered
                    ld      hl,sprite_sky_largest
                    call    shift_alloc
.buffered:          call    room_adjust
                    call    object_place
                    call    depth_insert
                    jp      redraw_object
