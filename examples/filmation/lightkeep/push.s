; ---------------------------------------------------------------------------
; Pushing, Fairlight's way: PUSH_COAST, which lightkeep.s defines. Without it
; the rule is LOOSE_WEIGHT's alone: a push moves a thing the pusher's step less
; its weight, and only while the knight leans on it.
;
; Fairlight's knight weighs 2. He pushes anything no more than 5 heavier, and
; it goes his whole step a turn, coasting on for 6 turns plus his weight less
; its own -- 7 turns at weight 1, 1 at weight 7 -- whether he follows it or
; not. engine/object.s's object_shove does the pushing and leaves the count in
; MOVE_STATE; this spends it. A thing pushed into another pushes that one the
; same way, by its own weight.
;
; Something heavier than its pusher is ours, not Fairlight's: it does not
; coast, and gives only after a push for each unit of weight it has over the
; pusher's, and one more, on turns one after another -- then goes the pusher's
; step less that difference, at least a unit. To the knight, weight 3 goes 2
; every second turn, 4 one every third, and 7 one every sixth.
;
; Every loose thing -- the block, the table and the chest -- is pushed alike,
; where Knight Lore's three let go of a shove each its own way (movers.s).
;
; And a thing drawn with more than one sprite moves as one: every record its
; template made goes by the step the first was given -- see mover_move_all.
;
; This is in bank 0 with carrying: it pages nothing in, and bank 2 is kept for
; code that has to.
; ---------------------------------------------------------------------------

PUSH_WEIGHT         EQU     2           ; the knight's, and a monster's: Fairlight's +16 of 18
PUSH_COAST_TURNS    EQU     6           ; a thing as heavy as its pusher coasts this long

; MOVE_STATE, shared: the turns left to coast in its low four bits, the pushes
; leant on it so far, lying still, in the next three, and whether one came this
; turn in the top. object_shove counts the pushes; mover_coast forgets them the
; first turn nobody pushes.
PUSH_COASTING       EQU     $0F
PUSH_EFFORT         EQU     $10
PUSH_EFFORT_MASK    EQU     $70
PUSH_PUSHED         EQU     $80


; A loose thing's turn. Coasting, it keeps the step it was pushed with and
; counts a turn off; lying, it has no step of its own, and takes only what
; gravity and whatever it lies on give it -- object_carry, in the clamp.
;
; The step it was pushed with outlasts the clamp: object_shove keeps it in
; DATA_2, and each turn it goes back on whichever axis the clamp left moving.
; Cut short a turn by something it then pushes on, it goes its whole step
; again the next, rather than creeping on at whatever that turn left it. It
; goes back at the start of the turn, not the end, so that what rides on it
; takes what it really moved -- object_carry reads the step off the record.
; Stopped dead, it stops coasting, rather than spending its turns leaning on
; what stopped it.
;
; A count with no step at all is one the thing table kept from the last visit
; (things.s keeps MOVE_STATE, and room_add clears the step): that coast is
; over.
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_coast:        ld      a,(ix+OBJ.MOVE_STATE)
                    and     PUSH_COASTING
                    jr      z,.lying
                    dec     (ix+OBJ.MOVE_STATE)
                    ld      b,(ix+OBJ.DATA_2)   ; the whole step
                    ld      a,(ix+OBJ.DU)       ; the clamp never turns a step
                    or      a                   ; round, so whichever axis is
                    jr      z,.along_v          ; still moving is the one
                    ld      (ix+OBJ.DU),b
                    jr      .move
.along_v:           ld      a,(ix+OBJ.DV)
                    or      a
                    jr      z,.over
                    ld      (ix+OBJ.DV),b
.move:              call    mover_move_all
                    ld      a,(ix+OBJ.DU)       ; what the clamp left of the step
                    or      (ix+OBJ.DV)
                    jp      nz,shoved_sound
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret

.over:              ld      (ix+OBJ.MOVE_STATE),a   ; A is 0: lying, from now on
                    ; Lying still. Leant on this turn, the pushes so far count
                    ; on; not, and they are forgotten.
.lying:             bit     7,(ix+OBJ.MOVE_STATE)       ; PUSH_PUSHED
                    res     7,(ix+OBJ.MOVE_STATE)
                    jr      nz,.leant
                    ld      (ix+OBJ.MOVE_STATE),0
.leant:             call    mover_halt          ; DZ is left to gravity
                    ; NB: falls through


; Move a loose thing by the step the clamp leaves its record -- and, when its
; template drew it with more than one sprite, every other record of it by the
; same step, so that a table too wide for one sprite goes as one table. Only
; the first record is ever pushed, clamped or given a turn: the others come
; straight after it in the pool, as a soldier's legs do, and are made passable
; in the template so that nothing stops on them.
;
; How many records it has is its things_here entry's: every loose template is
; a thing (rooms_source.py's kept_templates), and room_things_place counted
; them when it placed it. That is asked only when there is a step to take, so
; a thing lying still costs what it did.
;
; In:  IX -> the record, with DU, DV and DZ set; mover_ix names it too
; Out: nothing
; Corrupts: everything but IX
mover_move_all:     call    mover_clamp
                    ld      a,(ix+OBJ.DU)
                    or      (ix+OBJ.DV)
                    or      (ix+OBJ.DZ)
                    ret     z                   ; the room took the whole step away
                    call    thing_records
                    djnz    .several
                    jp      mover_paint         ; one sprite: as any mover

.several:           inc     b                   ; B = all of them again
                    call    region_reset
                    push    bc
.was:               push    bc                  ; where each one was
                    call    region_add
                    ld      bc,ROOM_STRIDE
                    add     ix,bc
                    pop     bc
                    djnz    .was
                    pop     bc
                    ld      ix,(mover_ix)

                    ld      d,(ix+OBJ.DU)       ; the first's step, for all
                    ld      e,(ix+OBJ.DV)
                    ld      a,(ix+OBJ.DZ)
.each:              push    bc
                    push    de
                    push    af
                    call    depth_step          ; each re-sorted against the run
                    call    room_adjust
                    call    object_place
                    call    region_add          ; and where it is now
                    pop     af
                    pop     de
                    ld      bc,ROOM_STRIDE
                    add     ix,bc
                    pop     bc
                    djnz    .each
                    call    redraw_defer
                    ld      ix,(mover_ix)       ; the draw is free to corrupt it
                    ret


; How many records the thing whose first record is IX has: its things_here
; entry's count, or one if it has none.
;
; In:  IX -> the record
; Out: B = how many
; Corrupts: AF, C, DE, HL, IY
thing_records:      ld      b,1
                    ld      a,(things_here_count)
                    or      a
                    ret     z
                    ld      c,a
                    push    ix
                    pop     hl
                    ld      iy,things_here
                    ld      de,HERE_STRIDE
.look:              ld      a,(iy+HERE_RECORD)
                    cp      l
                    jr      nz,.next
                    ld      a,(iy+HERE_RECORD+1)
                    cp      h
                    jr      nz,.next
                    ld      b,(iy+HERE_COUNT)
                    ret
.next:              add     iy,de
                    dec     c
                    jr      nz,.look
                    ret
