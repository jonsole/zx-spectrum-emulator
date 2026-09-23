; ---------------------------------------------------------------------------
; What Pentagram gives engine/movers.s, the behaviours it shares with Knight
; Lore: the constants and routine names the library asks for, and which of
; Pentagram's own things they are. Where Pentagram wants nothing done, the name
; is mover_still, which is a RET.
;
; Included after engine/mover.s and before engine/movers.s. Most of these name
; a routine in mover.s, and an EQU of a label still to come takes the value
; that label had in the pass before -- which sjasmplus warns about, because
; IFUSED moves code about between the first passes. Here the labels are
; already known.
; ---------------------------------------------------------------------------

; The platforms and the pacing dragon's heads -- see movers.s. They go two a
; turn, make no sound, do not animate and turn in silence; pacer_move, in
; movers.s, is the one thing of their own.
PACER_STEP          EQU     2
pacer_sound         EQU     mover_still
pacer_frame         EQU     mover_still
mover_turned        EQU     mover_still

; The spider and the creature, which roam until something stops them and
; then pick a new way -- engine/movers.s's mover_scuttler ($CF22, both axes at
; once) and mover_roamer ($D1F5, one at a time). Both are monsters, so they
; sit turns out in a busy room and go twice as far when MONSTER_KEEP_SPEED
; says to; monster_sits_out, monster_double and monster_halve are movers.s's.
SCUTTLE_STEP        EQU     4
ROAM_STEP           EQU     4

; What falls out of the sky: the homer that flies at him ($CC4B) and the two
; fallers that roam ($D1FD and $D251) -- engine/movers.s's mover_homer,
; mover_faller and mover_faller4. flyers.s drops them.
HOMER_ACC_U         EQU     30              ; past OBJ, inside the slot
HOMER_ACC_V         EQU     31
HOMER_ACC_Z         EQU     OBJ.MOVE_STATE
                    ASSERT  OBJ <= HOMER_ACC_U && HOMER_ACC_V < ROOM_STRIDE
HOMER_PULL          EQU     3
HOMER_MOST          EQU     $38             ; +56
HOMER_LEAST         EQU     $B8             ; -72
FALLER_STEP         EQU     4

; The puff a bolt or a flyer goes out in -- engine/movers.s's mover_poof,
; $C111, which plays POOF_FIRST to POOF_LAST a frame a turn, in movers.s
; with the bolt that starts one, and then empties the slot.
POOF_BEHAVIOUR      EQU     MOVE_POOF
poof_sound          EQU     sound_poof

; A stump, cube, table or stone, shoved and taking the pile on top with it --
; engine/movers.s's mover_shoved_pile, $CD81. At rest it looks to itself every
; fourth turn, staggered by slot.
SHOVED_REST_EVERY   EQU     4               ; a power of two

; The block that cracks under him -- engine/movers.s's mover_crumbles, $D2AD.
; A step every fourth turn puts it back to about the original's half-second at
; the pace this runs at.
CRUMBLE_LAST        EQU     139
CRUMBLE_EVERY       EQU     4               ; a power of two

; The bobbing dragon's head -- see movers.s for hopper_top. It climbs a unit a
; turn, net of gravity, and is silent and still in its frame; falling, it is
; only redrawn if it moved.
HOPPER_RISE         EQU     2
hopper_frame        EQU     mover_halt
hopper_sound        EQU     mover_still
hopper_move         EQU     mover_move
hopper_landed       EQU     mover_still
