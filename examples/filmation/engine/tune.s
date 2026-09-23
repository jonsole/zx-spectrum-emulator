; ---------------------------------------------------------------------------
; Tunes: a byte a note, $FF at the end. Both games' originals write them the
; same way, so this plays either.
;
;   bits 0 to 5   which note, which the game's own table turns into a pitch.
;                 Note 0 is a rest.
;   bits 6 and 7  how long to hold it: one to four times the note's own length.
;
; Nothing else happens while a tune plays -- the game is stopped for it, and
; the turn it stopped is not one to pace, so unlike the effects in sound.s
; these count nothing towards the turn.
;
; Two ways to play one. tune_play stops if a key is down, which is what a tune
; the player may be sick of wants; tune_play_all ignores the keyboard, which is
; what the start of a game wants, because the key that chose it from the menu
; may still be held.
;
; What the game supplies:
;
;   tune_note_at    A = the note, 1 to 63. Out: carry set and B, C the half
;                   period -- B DJNZs, then C - 1 runs of 256 more -- with E
;                   the cycles one length of it lasts. Carry clear for a note
;                   the game has no entry for, which is then skipped.
;                   Corrupts AF, HL, D.
;   tune_key        Out: NZ if a key is down. Corrupts AF, BC.
;
; The timing loops themselves are sound_long and sound_rest, in sound.s, up in
; uncontended memory where a DJNZ is always 13 T. This file only works out what
; to play, so it can live wherever the game has room.
; ---------------------------------------------------------------------------

; A tune, which a key cuts short.
;
; In:  DE -> the notes
; Out: nothing
; Corrupts: AF, BC, DE, HL
					IFUSED	tune_play
tune_play:			ld		a,(de)
					cp		$FF
					ret		z
					push	de
					call	tune_note
					pop		de
					inc		de
					call	tune_key
					jr		z,tune_play
					ret
					ENDIF


; The whole of a tune, whatever is held.
;
; In:  DE -> the notes
; Out: nothing
; Corrupts: AF, BC, DE, HL
					IFUSED	tune_play_all
tune_play_all:		ld		a,(de)
					cp		$FF
					ret		z
					push	de
					call	tune_note
					pop		de
					inc		de
					jr		tune_play_all
					ENDIF


; One note.
;
; In:  A = the note byte
; Out: nothing
; Corrupts: AF, BC, DE, HL
					IFUSED	tune_note
tune_note:			push	af
					and		$3F
					jr		z,.rest		; note 0: a rest as long
					call	tune_note_at
					jr		nc,.unknown

					; Its length, one to four of the note's own, counted out
					; into HL for sound_long.
					pop		af
					rlca
					rlca
					and		3
					inc		a
					ld		d,0		; E came back from the game's table
					ld		hl,0
.lengths:			add		hl,de
					dec		a
					jr		nz,.lengths
					jp		sound_long

.unknown:			pop		af		; no entry: nothing to play
					ret

.rest:				pop		af
					rlca
					rlca
					and		3
					inc		a
					ld		b,a
.wait:				call	sound_rest
					djnz	.wait
					ret
					ENDIF
