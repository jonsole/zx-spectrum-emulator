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

; The bobbing dragon's head -- see movers.s for hopper_top. It climbs a unit a
; turn, net of gravity, and is silent and still in its frame; falling, it is
; only redrawn if it moved.
HOPPER_RISE         EQU     2
hopper_frame        EQU     mover_halt
hopper_sound        EQU     mover_still
hopper_move         EQU     mover_move
hopper_landed       EQU     mover_still
