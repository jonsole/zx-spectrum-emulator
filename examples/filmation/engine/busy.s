; ---------------------------------------------------------------------------
; Busy rooms: when a room's turns cost more than the game they come from took,
; its monsters take turns instead of all moving every turn.
;
; Measured, not guessed. Counting objects made half a castle busy -- Pentagram's
; start room has 36 of them and they are hedges and grass, standing still --
; and what makes a room slow is what its turns cost. turn_pace already adds
; that up, in turn_work, so this reads it just before.
;
; The line is the original's own pace, not turn_pace's budget: a room may be
; well under the budget and still slower than the game it is copying. Over the
; line for BUSY_HOT_TURNS turns in a row and the room goes a step busier: each
; monster sitting out one turn in BUSY_LEAST, then one fewer, down to
; BUSY_MOST. Under it by BUSY_OFF_EIGHTHS for BUSY_CALM_TURNS in a row and it
; goes a step back.
;
; Neither edge is at the line itself. A room's first turn draws all of it, so
; one turn over the line means nothing; and taking turns is what brings a room
; back under, so a room near the line would flicker between the two every
; second or so if going back were as easy as going busy.
;
; What the game supplies, and how the two do it differently:
;
;   BUSY_TURNS_A_SECOND   the original's pace: 15 for Knight Lore, 20 for
;                         Pentagram, which runs quiet rooms faster
;   BUSY_OFF_EIGHTHS      how far under the line counts as calm
;   BUSY_HOT_TURNS        turns over the line before it goes busier
;   BUSY_CALM_TURNS       ...and under it before it goes back
;   BUSY_MOST, BUSY_LEAST the ends of room_busy's range
;
; And what the game does with room_busy is its own: Knight Lore sends its
; monsters through monster_gate, Pentagram asks monster_sits_out, and both
; count busy_count down between them so that the turns are shared out rather
; than every monster sitting out the same one.
;
; This file goes in whatever page the game has room in -- contended memory is
; fine for a few instructions a turn -- and after the game's own constants.
; ---------------------------------------------------------------------------

BUSY_LINE_T			EQU		3500000 / BUSY_TURNS_A_SECOND
BUSY_ON_UNITS		EQU		(BUSY_LINE_T - TURN_BASE_T) / TURN_UNIT_T
BUSY_OFF_UNITS		EQU		BUSY_ON_UNITS * BUSY_OFF_EIGHTHS / 8

; How busy the room is: 0 for quiet, or BUSY_LEAST down to BUSY_MOST, which is
; the one turn in however many that a monster sits out.
room_busy:			DB		0
busy_calm:			DB		0		; turns in a row towards changing
busy_phase:			DB		1		; where busy_count starts, this turn
busy_count:			DB		0		; the game's monsters count it down


; Once a turn, before turn_pace spends what is left of it.
; Corrupts AF, DE, HL.
busy_check:			ld		a,(room_busy)		; next turn, the next monster
					or		a		; sits out first
					jr		z,.measure
					ld		hl,busy_phase
					dec		(hl)
					jr		nz,.phased
					ld		(hl),a
.phased:			ld		a,(hl)
					ld		(busy_count),a

.measure:			ld		hl,(turn_work)
					ld		de,BUSY_ON_UNITS + 1
					or		a
					sbc		hl,de
					jr		c,.under
					ld		a,(room_busy)		; over the line
					cp		BUSY_MOST
					ld		hl,busy_calm
					jr		z,.not_calm		; as busy as it gets
					inc		(hl)		; one more slow turn
					ld		a,(hl)
					cp		BUSY_HOT_TURNS
					ret		c
					ld		a,(room_busy)		; slow long enough: a step on
					or		a
					ld		a,BUSY_LEAST
					jr		z,busy_set
					ld		a,(room_busy)
					dec		a
					jr		busy_set

.under:				ld		a,(room_busy)
					or		a
					ld		hl,busy_calm
					jr		z,.not_calm		; quiet: the slow run is over
					ld		hl,(turn_work)
					ld		de,BUSY_OFF_UNITS
					or		a
					sbc		hl,de
					ld		hl,busy_calm
					jr		nc,.not_calm
					inc		(hl)		; well under: one more calm turn
					ld		a,(hl)
					cp		BUSY_CALM_TURNS
					ret		c
					ld		a,(room_busy)		; calm long enough: a step back
					cp		BUSY_LEAST
					ld		a,0
					jr		z,busy_set
					ld		a,(room_busy)
					inc		a
					jr		busy_set
.not_calm:			ld		(hl),0
					ret


; How busy: 0 for quiet, or BUSY_LEAST down to BUSY_MOST. Starts the count of
; turns towards the next change over, and the monsters' turns.
; Corrupts AF.
busy_set:			ld		(room_busy),a
					ld		a,1
					ld		(busy_phase),a
					xor		a
					ld		(busy_calm),a
					ret
