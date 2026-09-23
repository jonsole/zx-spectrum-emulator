; ---------------------------------------------------------------------------
; The sticks: what the player is asking for, from whichever thing the menu
; chose. The keyboard is the game's own -- its keys are part of how it plays --
; and everything else is here, because a Kempston is a Kempston.
;
; Every reader builds the answer in E and leaves through the game's
; input_stick_done, which adds whatever else that game reads while a stick is
; steering and ends at input_store.
;
; What the game supplies:
;
;   menu_mode            bits 1 and 2: 00 keyboard, 01 Kempston, 10 cursor,
;                        11 Interface II -- see the game's menu
;   input_keyboard       its own keys, ending the same way
;   input_stick_done     the tail above
;   INPUT_LEFT_B, INPUT_RIGHT_B, INPUT_FORWARD_B, INPUT_DOWN_B,
;   INPUT_STICK_FIRE_B   which bit each of a stick's five inputs sets. They
;                        are bit NUMBERS, so that a reader can SET them.
;                        Knight Lore points a stick's fire at its jump bit and
;                        its down at pick-up; Pentagram has a fire of its own
;                        and jumps with down, as both originals do.
;
; A stick has five inputs and no more, so what the fifth one means is the one
; thing the two games disagree about. Nothing here decides anything: the games
; read input_now and work out what to do with it.
; ---------------------------------------------------------------------------

; The two half-rows both keyboard sticks live on, and the Kempston's port.
KEY_STICK_1_5		EQU		$F7FE		; 1 to 5: the cursor keys' 5, and
										; Interface II's second stick
KEY_STICK_0_6		EQU		$EFFE		; 0, 9, 8, 7, 6: the rest of the
										; cursor keys, and its first stick
KEMPSTON_PORT		EQU		$1F

input_now:			DB		0


; Read whichever the menu chose.
; Corrupts AF, BC, DE.
input_read:			ld		a,(menu_mode)
					rrca
					and		3		; 00 keyboard, 01 Kempston,
					jp		z,input_keyboard	; 10 cursor, 11 Interface II
					dec		a
					jp		z,input_kempston
					dec		a
					jp		z,input_cursor
					;; NB: fall through into input_interface_ii


; Both of the Interface II's sticks at once, as the games read them. The first
; is keys 6 to 0 -- 6 left, 7 right, 8 down, 9 up, 0 to fire -- and the second
; is 1 to 5, the same five in the same order. They sit at opposite ends of
; their half-rows, so one is read from bit 0 up and the other from bit 4 down.
input_interface_ii:	ld		e,0
					ld		bc,KEY_STICK_1_5	; the second stick
					in		a,(c)
					cpl		; a key reads 0 while it is held
					bit		0,a		; 1 left
					jr		z,.r2
					set		INPUT_LEFT_B,e
.r2:				bit		1,a		; 2 right
					jr		z,.d2
					set		INPUT_RIGHT_B,e
.d2:				bit		2,a		; 3 down
					jr		z,.u2
					set		INPUT_DOWN_B,e
.u2:				bit		3,a		; 4 up
					jr		z,.f2
					set		INPUT_FORWARD_B,e
.f2:				bit		4,a		; 5 fire
					jr		z,.first
					set		INPUT_STICK_FIRE_B,e

.first:				ld		bc,KEY_STICK_0_6	; the first stick
					in		a,(c)
					cpl
					bit		4,a		; 6 left
					jr		z,.r1
					set		INPUT_LEFT_B,e
.r1:				bit		3,a		; 7 right
					jr		z,.d1
					set		INPUT_RIGHT_B,e
.d1:				bit		2,a		; 8 down
					jr		z,.u1
					set		INPUT_DOWN_B,e
.u1:				bit		1,a		; 9 up
					jr		z,.f1
					set		INPUT_FORWARD_B,e
.f1:				bit		0,a		; 0 fire
					jp		z,input_stick_done
					set		INPUT_STICK_FIRE_B,e
					jp		input_stick_done


; The Kempston's own port, where a bit is set while it is held -- the other
; way round from the keyboard.
input_kempston:		ld		e,0
					in		a,(KEMPSTON_PORT)
					rra		; right
					jr		nc,.left
					set		INPUT_RIGHT_B,e
.left:				rra
					jr		nc,.down
					set		INPUT_LEFT_B,e
.down:				rra
					jr		nc,.up
					set		INPUT_DOWN_B,e
.up:				rra
					jr		nc,.fire
					set		INPUT_FORWARD_B,e
.fire:				rra
					jp		nc,input_stick_done
					set		INPUT_STICK_FIRE_B,e
					jp		input_stick_done


; The cursor keys: 5 left, 8 right, 7 up, 6 down and 0 to fire.
input_cursor:		ld		e,0
					ld		bc,KEY_STICK_1_5
					in		a,(c)
					cpl
					bit		4,a		; 5
					jr		z,.rest
					set		INPUT_LEFT_B,e
.rest:				ld		bc,KEY_STICK_0_6
					in		a,(c)
					cpl
					bit		0,a		; 0
					jr		z,.up
					set		INPUT_STICK_FIRE_B,e
.up:				bit		3,a		; 7
					jr		z,.right
					set		INPUT_FORWARD_B,e
.right:				bit		2,a		; 8
					jr		z,.down
					set		INPUT_RIGHT_B,e
.down:				bit		4,a		; 6
					jp		z,input_stick_done
					set		INPUT_DOWN_B,e
					jp		input_stick_done


; What every reader ends at, the game's input_stick_done included.
;   E - what the reader made of it
input_store:		ld		a,e
					ld		(input_now),a
					ret
