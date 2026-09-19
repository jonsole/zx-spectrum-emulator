; ---------------------------------------------------------------------------
; Is the room busy? Measured, not guessed.
;
; A room is busy when its turns cost more than turn_pace's budget -- that is,
; when it is running below the pace the quiet rooms keep -- and then its
; monsters take turns (see monster_sits_out in movers.s). Counting objects
; made half the game busy, the start room among them, whose 36 are hedges and
; grass standing still; what makes a room slow is what its turns cost, and
; turn_work already adds that up for turn_pace, so this reads it just before.
;
; The line is the original's own pace, not turn_pace's: its quiet rooms run
; about 20 turns a second, and turn_pace's budget is 35, which nearly every
; room with anything moving in it is over -- measured against that, room 92
; with two flyers in it was busy all the time, though it runs faster than the
; original does there. Slower than the original is what taking turns is for.
;
; On after BUSY_HOT_TURNS turns in a row over the line, not at the first: a
; room's first turn draws all of it, and a quiet room went busy for it. Off
; only after BUSY_CALM_TURNS in a row a quarter under it -- taking turns is
; what brought it down, and a room near the line otherwise flickers between
; the two every second or so. Every room starts quiet.
;
; In the room builder's page, which has room: the main one has almost none.
; ---------------------------------------------------------------------------

BUSY_TURNS_A_SECOND EQU     20
BUSY_LINE_T         EQU     3500000 / BUSY_TURNS_A_SECOND
BUSY_ON_UNITS       EQU     (BUSY_LINE_T - TURN_BASE_T) / TURN_UNIT_T
BUSY_OFF_UNITS      EQU     BUSY_ON_UNITS * 3 / 4
BUSY_HOT_TURNS      EQU     4
BUSY_CALM_TURNS     EQU     64

busy_calm:          DB      0               ; turns in a row towards changing

; Once a turn, before turn_pace spends what is left of it.
; Corrupts AF, DE, HL.
busy_check:         ld      hl,(turn_work)
                    ld      de,BUSY_ON_UNITS + 1
                    or      a
                    sbc     hl,de
                    jr      c,.under
                    ld      a,(room_busy)       ; over the line
                    or      a
                    ld      hl,busy_calm
                    jr      nz,.not_calm        ; busy: no calmer
                    inc     (hl)                ; quiet: one more slow turn
                    ld      a,(hl)
                    cp      BUSY_HOT_TURNS
                    ret     c
                    ld      a,1                 ; slow long enough: busy
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
                    xor     a                   ; calm long enough: quiet
                    jr      busy_set
.not_calm:          ld      (hl),0
                    ret

; Busy (A = 1) or not (A = 0), starting the count of calm turns over, and the
; border to say so when BUSY_BORDER is set.
; Corrupts AF.
busy_set:           ld      (room_busy),a
                IF      BUSY_BORDER
                    add     a,a                 ; 1 to red, 0 to black
                    out     ($FE),a
                ENDIF
                    xor     a
                    ld      (busy_calm),a
                    ret
