; ---------------------------------------------------------------------------
; What Pentagram gives engine/busy.s, which decides when a room's monsters
; take turns -- see there for how.
;
; The line is the original's pace, not turn_pace's: its quiet rooms run about
; 20 turns a second, and turn_pace's budget is 35, which nearly every room with
; anything moving in it is over -- measured against that, room 92 with two
; flyers in it was busy all the time, though it runs faster than the original
; does there. At 20 itself, rooms that play fine went busy too, so it is 15:
; only a room that is plainly slow takes turns.
;
; All that is for monsters that keep their speed, MONSTER_KEEP_SPEED, going
; twice as far every other turn: that is jerkier, so it is kept for rooms that
; need it, and switching back and forth shows. Monsters that slow down instead
; move as smoothly as ever, only slower, and a step is hard to see: so then the
; room slows them by steps -- each sitting out one turn in four, then three,
; then two -- one step for every two turns it is over the line, and back one
; for every sixteen a little under it. The busier the room, the slower its
; monsters, but gradually.
;
; Which of them take turns is movers.s's monster_sits_out. Every room starts
; quiet: flyer_room_enter calls busy_set with 0 as one is built.
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

; room_busy's steps: the one in how many turns a monster sits out.
BUSY_MOST           EQU     2
                IF      MONSTER_KEEP_SPEED
BUSY_LEAST          EQU     2               ; doubling only works for two
                ELSE
BUSY_LEAST          EQU     4
                ENDIF
