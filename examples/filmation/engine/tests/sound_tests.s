; Unit tests for engine/turn.s and the beeper loops in engine/sound.s, in Z80,
; run on the C++ core by run_tests.py.
;
; What is checked is what the callers lean on. A sound counts its own time
; towards the turn, and a noise walks HL through the ROM for its pitches with a
; cycle played at each -- so turn_add, and everything that ends in it, has to
; hand HL back. It did not: sound_cycle ended in a JP to turn_add, which left
; HL on turn_work, and every pitch of a noise after the first came from there.
;
; The counts are worked out from sound_cycle's own rule: B / 8 units and one
; more, B being the half-period. The speaker writes go to port $FE, which the
; runner ignores.

					ORG		$0100
					INCLUDE	"harness.s"


start:				ld		sp,$FE00

; --- turn_add --------------------------------------------------------------------

					TEST	"turn_add: counts, carries into the high byte, keeps HL"
					ld		hl,$00FE
					ld		(turn_work),hl
					ld		hl,$1234
					ld		bc,$5678
					ld		de,$9ABC
					ld		a,3
					call	turn_add
					call	snap
					EXPECT_WORD	turn_work, $0101, "turn_work"
					EXPECT_WORD	s_hl, $1234, "HL"
					EXPECT_WORD	s_bc, $5678, "BC"
					EXPECT_WORD	s_de, $9ABC, "DE"

					TEST	"turn_add: no carry, HL kept all the same"
					ld		hl,$0010
					ld		(turn_work),hl
					ld		hl,$4321
					ld		a,5
					call	turn_add
					call	snap
					EXPECT_WORD	turn_work, $0015, "turn_work"
					EXPECT_WORD	s_hl, $4321, "HL"

; --- sound_cycle, sound_tone -------------------------------------------------------

					; $40 / 8 = 8, and one more.
					TEST	"sound_cycle: counts B / 8 + 1 units, keeps BC, DE, HL"
					ld		hl,0
					ld		(turn_work),hl
					ld		hl,$1234
					ld		bc,$4055
					ld		de,$6677
					call	sound_cycle
					call	snap
					EXPECT_WORD	turn_work, 9, "turn_work"
					EXPECT_WORD	s_hl, $1234, "HL"
					EXPECT_WORD	s_bc, $4055, "BC"
					EXPECT_WORD	s_de, $6677, "DE"

					; $08 / 8 = 1, and one more, three times.
					TEST	"sound_tone: C cycles, C back at 0, B, DE and HL kept"
					ld		hl,0
					ld		(turn_work),hl
					ld		hl,$1234
					ld		bc,$0803
					ld		de,$6677
					call	sound_tone
					call	snap
					EXPECT_WORD	turn_work, 6, "turn_work"
					EXPECT_WORD	s_hl, $1234, "HL"
					EXPECT_WORD	s_bc, $0800, "BC"
					EXPECT_WORD	s_de, $6677, "DE"

					; A noise as the games play one: a pitch from (HL) a cycle,
					; HL on to the next. Each pitch is $10, $18 and $20 in turn:
					; 3, 4 and 5 units, so 12 if every one came from the table.
					TEST	"a noise reads each pitch from where HL has got to"
					ld		hl,0
					ld		(turn_work),hl
					ld		hl,noise
					ld		e,3
.noise:				ld		a,(hl)
					inc		hl
					ld		b,a
					call	sound_cycle
					dec		e
					jr		nz,.noise
					ld		(noise_end),hl
					EXPECT_WORD	turn_work, 12, "turn_work"
					EXPECT_WORD	noise_end, noise + 3, "HL, past the pitches"

					call	finish
					DB		"sound_tests", 0

noise:				DB		$10, $18, $20
noise_end:			DW		0

; What turn.s reads of the rest of the engine.
					INCLUDE	"../turn.s"
					INCLUDE	"../sound.s"
