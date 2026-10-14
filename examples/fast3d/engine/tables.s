; fast3d: the tables. output/tables_gen.s holds their contents, written by
; build.py from model.py, so the tables and the model cannot disagree.
;
; SQ_LO, SQ_HI   floor(n*n/4) for n = -256..255, the quarter squares: a*b is
;                f(a+b) - f(a-b). SQ_CENTRE is n = 0, so f(n) is at
;                SQ_CENTRE + n and its high byte two pages above. 1K, on a
;                512-byte boundary (mul8s needs SQ_LO's page to be even).
; SINE_LO, SINE_HI   round(2032 * sin(2 pi a / 256)) for a = 0..255, the
;                sines make_matrix sums. 512 bytes, on a page boundary.

					ALIGN	512
SQ_LO:
SQ_CENTRE			EQU		SQ_LO + 256
SQ_HI				EQU		SQ_LO + 512
SINE_LO				EQU		SQ_LO + 1024
SINE_HI				EQU		SQ_LO + 1280
					INCLUDE	"output/tables_gen.s"
