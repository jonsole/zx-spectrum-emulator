; ---------------------------------------------------------------------------
; Pushing, Fairlight's way -- built only with PUSH_COAST (build.py
; --push-coast), to try against Lightkeep's own rule, which is LOOSE_WEIGHT's
; alone: a push moves a thing the pusher's step less its weight, and only while
; the knight leans on it.
;
; Fairlight's knight weighs 2. He pushes anything no more than 5 heavier, and
; it goes his whole step a turn, coasting on for 6 turns plus his weight less
; its own -- 7 turns at weight 1, 1 at weight 7 -- whether he follows it or
; not. engine/object.s's object_shove does the pushing and leaves the count in
; MOVE_STATE; this spends it. A thing pushed into another pushes that one the
; same way, by its own weight.
;
; Every loose thing -- the block, the table and the chest -- is pushed alike,
; where Knight Lore's three let go of a shove each its own way (movers.s).
;
; This is in bank 0 with carrying: it pages nothing in, and bank 2 is kept for
; code that has to.
; ---------------------------------------------------------------------------

PUSH_WEIGHT         EQU     2           ; the knight's, and a monster's: Fairlight's +16 of 18
PUSH_COAST_TURNS    EQU     6           ; a thing as heavy as its pusher coasts this long


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
                    or      a
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
.move:              call    mover_move
                    ld      a,(ix+OBJ.DU)       ; what the clamp left of the step
                    or      (ix+OBJ.DV)
                    jp      nz,shoved_sound
                    ld      (ix+OBJ.MOVE_STATE),a
                    ret

.over:              ld      (ix+OBJ.MOVE_STATE),a   ; A is 0: lying, from now on
.lying:             call    mover_halt
                    jp      mover_move          ; DZ is left to gravity
