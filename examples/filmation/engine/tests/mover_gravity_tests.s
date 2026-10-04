; mover_tests.s again, built with PAIR_GRAVITY as a game with raised floors
; is (Lightkeep): every pair test runs a second time against the code that
; brings the legs down with a falling torso, and the tests of that are
; assembled in.

					DEFINE	PAIR_GRAVITY
CHARACTER_FALL_MAX	EQU		-8 & $FF		; the knight's, as knight.s has it

					INCLUDE	"mover_tests.s"
