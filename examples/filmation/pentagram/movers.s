; ---------------------------------------------------------------------------
; What Pentagram's objects do.
;
; The engine reads behaviours as an ORDERED enum, not as a set of flags: it
; asks whether a value falls in a range, so the order below is the meaning and
; cannot be shuffled. See "What the game supplies" in ../engine/README.md.
;
;   BEHAVIOUR_DEADLY .. BEHAVIOUR_CRUSHING    kills whatever touches it
;   BEHAVIOUR_CRUSHING .. BEHAVIOUR_HARMLESS  kills only when it moves into you
;   BEHAVIOUR_HARMLESS and up                 kills nothing
;   BEHAVIOUR_GIVES .. BEHAVIOUR_GIVES_LAST   gives way under a weight
;   BEHAVIOUR_LOOSE and up                    carried by what it stands on,
;                                             shoved by what hits it
;   BEHAVIOUR_FIRST_TURN and up               gets a turn, and has a mover_tbl
;                                             entry
;
; -- WHAT IS AND IS NOT KNOWN ------------------------------------------------
;
; The ORDERING here is sound: it satisfies every range the engine tests, so
; the machinery works. The ASSIGNMENT is not -- nothing yet says which of
; Pentagram's thirty-one object templates is deadly, which crushes, or which
; can be pushed.
;
; One real fact does exist. Five templates -- 04, 06, 07, 11 and 14 -- carry
; flag $04 in the game's own data, which marks an object MOBILE: fields
; +$09..+$0B are a movement vector, $CD87 clears them to stop it, and $B775
; and $B832 pass a vector from one record to another on contact. So those five
; move under their own steam and everything else stands still. That is a real
; head start on mover_tbl, and it is the only thing here that was not chosen.
;
; The rest wants watching the original: which things kill him, which give way,
; which can be shoved. Until then everything defaults to MOVE_STILL and the
; movers do nothing, which is wrong but is wrong in a safe direction -- a room
; builds and draws, and nothing moves or kills.
; ---------------------------------------------------------------------------

MOVE_NONE           EQU     0       ; no behaviour at all

MOVE_STILL          EQU     1       ; the first that kills: stands there and is
                                    ; fatal to touch, like a spike
MOVE_MOBILE         EQU     2       ; the first with a turn: the five templates
                                    ; the game's own $04 flag marks as moving
MOVE_CRUSHING       EQU     3       ; kills only when it moves into you
MOVE_HARMLESS       EQU     4       ; and from here on, nothing kills
MOVE_GIVES          EQU     5       ; gives way under a weight
MOVE_GIVES_LAST     EQU     5       ; ...and the last that does
MOVE_LOOSE          EQU     6       ; this and above: carried and shoved

BEHAVIOUR_FIRST_TURN    EQU     MOVE_MOBILE     ; mover_tbl's first entry
BEHAVIOUR_DEADLY        EQU     MOVE_STILL
BEHAVIOUR_CRUSHING      EQU     MOVE_CRUSHING
BEHAVIOUR_HARMLESS      EQU     MOVE_HARMLESS
BEHAVIOUR_GIVES         EQU     MOVE_GIVES
BEHAVIOUR_GIVES_LAST    EQU     MOVE_GIVES_LAST
BEHAVIOUR_LOOSE         EQU     MOVE_LOOSE


; One DW per behaviour from BEHAVIOUR_FIRST_TURN up. Each gets IX pointing at
; its record, may corrupt anything, must leave the stack balanced, and returns.
;
; Both are RETs for now. That is not a stub standing in for something: nothing
; is yet known about how Pentagram's five mobile templates actually move, and a
; mover that guessed would be worse than one that does nothing, because a wrong
; movement looks like an engine fault.
mover_tbl:          DW      mover_mobile        ; MOVE_MOBILE
                    DW      mover_crushing      ; MOVE_CRUSHING

mover_mobile:       ret
mover_crushing:     ret
