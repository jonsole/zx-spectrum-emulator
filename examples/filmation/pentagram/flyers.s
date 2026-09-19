; ---------------------------------------------------------------------------
; What falls out of the sky.
;
; No room places these. Stay in a room long enough and the original drops a
; creature into it from Z 216, somewhere near the middle, and then another --
; $CBAB, called every turn from the main loop at $AFDA. Found by watching
; the slot it fills for a write: it is always one of two records it keeps for
; the purpose, straight after the player's own.
;
; The timer is one byte, and it starts at nothing, so the first countdown
; wraps and runs 255 turns -- "after a while". The original never resets it on
; entering a room, so once it has run out every new room drops something
; almost at once; the remake starts it over in every room instead, so each
; one gives him the whole 255 turns first. Once it has run out it is held at one
; and every turn has a one-in-four chance; a drop sets it back to
; (2 + the quest items still to find) * 4, 24 at the start of a game. Two at
; once and it stops trying until one goes, which in practice is leaving the
; room. None falls in a room holding the well, a quest item or a piece of the
; pentagram ($CB89) -- of which only the well exists here yet.
;
; What falls is one of eight, picked at random from $CC09:
;
;   164, 160, 48  the homers -- $CC4B -- which fly at him; harmless
;   80            a faller that roams two frames -- $D1FD; deadly
;   168           a faller that roams four -- $D251; deadly
;
; and 160, 48 and 80 come up twice, so homers are the likelier.
; ---------------------------------------------------------------------------

; 1 to skip the wait altogether, so that things drop as soon as a room is up
; and again as soon as there is a slot: for testing, and for watching a busy
; screen. 0 is the original's wait.
FLYER_NOW           EQU     1

FLYER_SLOTS         EQU     2
BOLT_SLOTS          EQU     2               ; his two bolts' -- see player.s
EXTRA_SLOTS         EQU     FLYER_SLOTS + BOLT_SLOTS
FLYER_Z             EQU     216             ; where they drop from
FLYER_WAIT          EQU     (2 + 4) * 4     ; between drops, with all four
                                            ; quest items still out
FLYER_LARGEST       EQU     sprite_018      ; 4x24: the largest frame any
                                            ; flyer wears, which sizes the
                                            ; one buffer each slot keeps
FLYER_WELL_GFX      EQU     120

; What a drop can be, as the original's own table has it.
flyer_pick:         DB      164, 160, 48, 80, 168, 160, 48, 80

flyer_timer:        DB      0               ; $A73D, but started over each room
flyer_banned:       DB      0               ; this room drops nothing
flyer_slots:        DW      0               ; the first of the two records;
                                            ; the bolts' two follow them


; ---------------------------------------------------------------------------
; Make the records a room keeps for flyers and for his bolts: the next four
; after everything the room data made, blank until something falls or is
; fired into them. Knight Lore keeps its collectables' slots the same way --
; see special_room_enter.
;
; And whether this room drops anything at all, and the whole wait again
; before it does.
; Corrupts AF, BC, DE, HL, IX.
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

                    ; A room this full is busy: see ROOM_BUSY_OBJECTS.
                    ld      b,a
                    cp      ROOM_BUSY_OBJECTS
                    ld      a,0
                    jr      c,.quiet
                    inc     a
.quiet:             ld      (room_busy),a
                    ld      a,b

                    ; The room's own objects first: is the well among them?
                    xor     a
                    ld      (flyer_banned),a
                    ld      a,b
                    or      a
                    jr      z,.blank
                    ld      ix,room_objects
                    ld      de,ROOM_STRIDE
.look:              ld      a,(ix+OBJ.GFX)
                    cp      FLYER_WELL_GFX
                    jr      nz,.not_well
                    ld      (flyer_banned),a
.not_well:          add     ix,de
                    djnz    .look

.blank:             ld      ix,(flyer_slots)
                    ld      b,EXTRA_SLOTS
.slot:              call    flyer_blank
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

; A slot with nothing in it: no graphic, no behaviour, and nothing collides.
flyer_blank:        ld      (ix+OBJ.GFX),0
                    ld      (ix+OBJ.BEHAVIOUR),0
                    ld      (ix+OBJ.FLAGS),OBJ_PASSABLE
                    ret


; ---------------------------------------------------------------------------
; One turn of the sky. $CBAB, step for step.
; Corrupts AF, BC, DE, HL, IX.
flyer_step:         ld      a,(flyer_banned)
                    or      a
                    ret     nz
                    ld      hl,flyer_timer
                    dec     (hl)
                    ret     nz
                    ld      (hl),1              ; run out: from now, every turn
                    call    mover_rand          ; (which takes HL)
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
                    ld      d,0
                    ld      hl,flyer_pick
                    add     hl,de
                    ld      a,(hl)
                    ld      (ix+OBJ.GFX),a

                    ; Its behaviour, and its size: the homers are ten across,
                    ; which $CC4B sets every turn; everything else is eight.
                    ld      c,MOVE_HOMER
                    ld      e,10
                    cp      80
                    jr      c,.chosen           ; 48
                    ld      c,MOVE_FALLER
                    ld      e,8
                    jr      z,.chosen           ; 80
                    ld      c,MOVE_FALLER4
                    cp      168
                    jr      nc,.chosen          ; 168
                    ld      c,MOVE_HOMER        ; 160 and 164
                    ld      e,10
.chosen:            ld      (ix+OBJ.BEHAVIOUR),c
                    ld      (ix+OBJ.SIZE_U),e
                    ld      (ix+OBJ.SIZE_V),e
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
                    ; happened to show first.
                    ld      a,(ix+OBJ.BUF_H)
                    or      a
                    jr      nz,.buffered
                    ld      hl,FLYER_LARGEST
                    call    shift_alloc
.buffered:          call    room_adjust
                    call    object_place
                    call    depth_insert
                    jp      redraw_object
