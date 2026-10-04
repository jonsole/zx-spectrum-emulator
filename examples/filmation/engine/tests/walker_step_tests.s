; walker_tests.s again, with stairs: CHARACTER_STEP_UP defined as a game that
; has them defines it (Lightkeep). Every walker test runs a second time
; against the code that climbs, and the climb's own tests are assembled in.

					DEFINE	CHARACTER_STEP_UP 6

					INCLUDE	"walker_tests.s"
