; ---------------------------------------------------------------------------
; Busy rooms: when a room runs slower than Knight Lore itself did, its
; monsters take turns. The remake's own, and the same rule as Pentagram's
; busy.s, read from turn_work -- what the turn cost, which turn_pace adds up.
;
; The line is the original's own pace, about fifteen frames a second. Over it
; for BUSY_HOT_TURNS turns in a row and the room goes a step busier: each
; monster sitting out one turn in four, then in three, then in two. Under it
; by an eighth for BUSY_CALM_TURNS in a row and it goes a step back. So a room
; that is only a little slow is only a little slowed, its first turn -- which
; draws all of it -- does not count, and the change comes and goes gradually.
; Every room starts quiet: main.s calls busy_set with 0 as one is entered.
;
; The monsters -- the fires, both guards, the ghosts and the bouncing and
; spiked balls -- come through monster_gate, in monster_gate.s, which counts
; busy_count down between them; whichever reaches nought sits the turn out.
; busy_check starts it one further on each turn, so each has its turn. They
; slow down rather than taking bigger steps when they do move, as Pentagram's
; do.
;
; In the pool's page, in what the sprite table left: contended memory, which
; a few instructions a turn do not notice.
; ---------------------------------------------------------------------------

BUSY_TURNS_A_SECOND EQU     15
BUSY_OFF_EIGHTHS    EQU     7                   ; off an eighth under it
BUSY_HOT_TURNS      EQU     2
BUSY_CALM_TURNS     EQU     16
BUSY_LINE_T         EQU     3500000 / BUSY_TURNS_A_SECOND
BUSY_ON_UNITS       EQU     (BUSY_LINE_T - TURN_BASE_T) / TURN_UNIT_T
BUSY_OFF_UNITS      EQU     BUSY_ON_UNITS * BUSY_OFF_EIGHTHS / 8

; room_busy's steps: the one in how many turns a monster sits out.
BUSY_MOST           EQU     2
BUSY_LEAST          EQU     4

room_busy:          DB      0                   ; 0, or 4, 3 or 2
busy_calm:          DB      0                   ; turns in a row towards changing
busy_phase:         DB      1                   ; where busy_count starts, this turn
busy_count:         DB      0                   ; monster_gate counts it down

; Once a turn, before turn_pace spends what is left of it.
; Corrupts AF, DE, HL.
busy_check:         ld      a,(room_busy)       ; next turn, the next monster
                    or      a                   ; sits out first
                    jr      z,.measure
                    ld      hl,busy_phase
                    dec     (hl)
                    jr      nz,.phased
                    ld      (hl),a
.phased:            ld      a,(hl)
                    ld      (busy_count),a

.measure:           ld      hl,(turn_work)
                    ld      de,BUSY_ON_UNITS + 1
                    or      a
                    sbc     hl,de
                    jr      c,.under
                    ld      a,(room_busy)       ; over the line
                    cp      BUSY_MOST
                    ld      hl,busy_calm
                    jr      z,.not_calm         ; as busy as it gets
                    inc     (hl)                ; one more slow turn
                    ld      a,(hl)
                    cp      BUSY_HOT_TURNS
                    ret     c
                    ld      a,(room_busy)       ; slow long enough: a step on
                    or      a
                    ld      a,BUSY_LEAST
                    jr      z,busy_set
                    ld      a,(room_busy)
                    dec     a
                    jr      busy_set

.under:             ld      a,(room_busy)
                    or      a
                    ld      hl,busy_calm
                    jr      z,.not_calm         ; quiet: the slow run is over
                    ld      hl,(turn_work)
                    ld      de,BUSY_OFF_UNITS
                    or      a
                    sbc     hl,de
                    ld      hl,busy_calm
                    jr      nc,.not_calm
                    inc     (hl)                ; well under: one more calm turn
                    ld      a,(hl)
                    cp      BUSY_CALM_TURNS
                    ret     c
                    ld      a,(room_busy)       ; calm long enough: a step back
                    cp      BUSY_LEAST
                    ld      a,0
                    jr      z,busy_set
                    ld      a,(room_busy)
                    inc     a
                    jr      busy_set
.not_calm:          ld      (hl),0
                    ret

; How busy: 0 for quiet, or BUSY_LEAST down to BUSY_MOST. Starts the count
; of turns towards the next change over, and the monsters' turns.
; Corrupts AF.
busy_set:           ld      (room_busy),a
                    ld      a,1
                    ld      (busy_phase),a
                    xor     a
                    ld      (busy_calm),a
                    ret
