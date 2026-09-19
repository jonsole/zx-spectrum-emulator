; ---------------------------------------------------------------------------
; Is the room busy? Measured, not guessed.
;
; A room is busy when its turns cost more than a line -- when it is running
; below the pace the original keeps -- and then its monsters take turns (see monster_sits_out in movers.s). Counting objects
; made half the game busy, the start room among them, whose 36 are hedges and
; grass standing still; what makes a room slow is what its turns cost, and
; turn_work already adds that up for turn_pace, so this reads it just before.
;
; The line is set by the original's pace, not turn_pace's: its quiet rooms run
; about 20 turns a second, and turn_pace's budget is 35, which nearly every
; room with anything moving in it is over -- measured against that, room 92
; with two flyers in it was busy all the time, though it runs faster than the
; original does there. At 20 itself, rooms that play fine went busy too, so it
; is 15: only a room that is plainly slow takes turns.
;
; On after BUSY_HOT_TURNS turns in a row over the line, not at the first: a
; room's first turn draws all of it, and a quiet room went busy for it. Off
; only after BUSY_CALM_TURNS in a row well under it -- taking turns is
; what brought it down, and a room near the line otherwise flickers between
; the two every second or so. Every room starts quiet.
;
; All that is for monsters that keep their speed, MONSTER_KEEP_SPEED, going
; twice as far every other turn: that is jerkier, so it is kept for rooms that
; need it, and switching back and forth shows. Monsters that slow down
; instead move as smoothly as ever, only slower, and a step is hard to see: so
; then the room slows them by steps -- each sitting out one turn in four, then
; three, then two -- one step for every two turns it is over the original's
; 20, and back one for every sixteen a little under it. The busier the room,
; the slower its monsters, but gradually.
;
; In the room builder's page, which has room: the main one has almost none.
; ---------------------------------------------------------------------------

                IF      MONSTER_KEEP_SPEED
BUSY_TURNS_A_SECOND EQU     15
BUSY_OFF_EIGHTHS    EQU     6               ; off a quarter under the line
BUSY_HOT_TURNS      EQU     4
BUSY_CALM_TURNS     EQU     64
                ELSE
BUSY_TURNS_A_SECOND EQU     20
BUSY_OFF_EIGHTHS    EQU     7               ; off an eighth under it
BUSY_HOT_TURNS      EQU     2
BUSY_CALM_TURNS     EQU     16
                ENDIF
BUSY_LINE_T         EQU     3500000 / BUSY_TURNS_A_SECOND
BUSY_ON_UNITS       EQU     (BUSY_LINE_T - TURN_BASE_T) / TURN_UNIT_T
BUSY_OFF_UNITS      EQU     BUSY_ON_UNITS * BUSY_OFF_EIGHTHS / 8

; room_busy's steps: the one in how many turns a monster sits out.
BUSY_MOST           EQU     2
                IF      MONSTER_KEEP_SPEED
BUSY_LEAST          EQU     2               ; doubling only works for two
                ELSE
BUSY_LEAST          EQU     4
                ENDIF

busy_calm:          DB      0               ; turns in a row towards changing
busy_phase:         DB      1               ; where busy_count starts, this turn
busy_count:         DB      0               ; monster_sits_out counts it down

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
