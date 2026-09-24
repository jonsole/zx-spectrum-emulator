; ---------------------------------------------------------------------------
; What Knight Lore gives engine/busy.s, which decides when a room's monsters
; take turns -- see there for how.
;
; The line is the original's own pace, about fifteen frames a second. Over it
; for two turns in a row and the room goes a step busier: each monster sitting
; out one turn in four, then in three, then in two. An eighth under it for
; sixteen turns in a row and it goes a step back.
;
; The monsters -- the fires, both guards, the ghosts and the bouncing and
; spiked balls -- come through monster_gate, in monster_gate.s, which counts
; busy_count down between them; whichever reaches nought sits the turn out.
; busy_check starts it one further on each turn, so each has its turn. They
; slow down rather than taking bigger steps when they do move, as Pentagram's
; do.
;
; Every room starts quiet: main.s calls busy_set with 0 as one is entered.
; ---------------------------------------------------------------------------

BUSY_TURNS_A_SECOND EQU     15
BUSY_OFF_EIGHTHS    EQU     7                   ; off an eighth under it
BUSY_HOT_TURNS      EQU     2
BUSY_CALM_TURNS     EQU     16

; room_busy's steps: the one in how many turns a monster sits out.
BUSY_MOST           EQU     2
BUSY_LEAST          EQU     4
