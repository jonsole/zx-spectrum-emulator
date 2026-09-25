; isoblocks demo, stage 1: the renderer on a still map.
;
; Q, A, O and P move the view a cell along the map's y and x; 1 to 4 pick the
; view. Nothing else moves yet -- objects and sprites are stage 2.
;
;   bank 2, $8000   this, the engine, and its work space (engine/layout.s)
;   bank 5, $4000   the first screen
;   bank 0, $C000   the map (output/map.bin, built from maps/test.json)
;   bank 7          the second screen, paged in at $C000 to be painted
					DEVICE	ZXSPECTRUM128

					INCLUDE	"../engine/layout.s"

					ORG		$8000

start:
					di
					ld		sp,STACK_TOP
					; Interrupt mode 2 through a table of $B9s, so wherever the
					; bus leaves the vector the routine is at $B9B9.
					ld		hl,IM2_TABLE
					ld		de,IM2_TABLE + 1
					ld		bc,256
					ld		(hl),high IM2_ROUTINE
					ldir
					ld		a,high IM2_TABLE
					ld		i,a
					im		2
					call	make_place_tables
					call	clear_screens
					ei

frame:
					call	read_keys
					call	view_update
					call	read_view
					call	sort_places
					call	clear_back
					call	paint
					call	show_back
					jr		frame


; Q/A/O/P move the focus, 1-4 choose the view. A key held moves a cell a
; frame; view_update keeps the focus on the map.
read_keys:
					ld		bc,$FBFE			; Q W E R T
					in		a,(c)
					rra
					jr		c,.not_q
					ld		hl,focus_y
					dec		(hl)
.not_q:				ld		b,$FD				; A S D F G
					in		a,(c)
					rra
					jr		c,.not_a
					ld		hl,focus_y
					inc		(hl)
.not_a:				ld		b,$DF				; P O I U Y
					in		a,(c)
					rra
					jr		c,.not_p
					ld		hl,focus_x
					inc		(hl)
.not_p:				rra
					jr		c,.not_o
					ld		hl,focus_x
					dec		(hl)
.not_o:				ld		b,$F7				; 1 2 3 4 5
					in		a,(c)
					ld		e,0
					ld		d,4
.view_key:			rra
					jr		nc,.pick
					inc		e
					dec		d
					jr		nz,.view_key
					ret
.pick:				ld		a,e
					ld		(view_number),a
					ret


; Both screens black everywhere but the view, which is black on white like
; the Spectrum's paper. Bank 7 is paged in at $C000 for it, and the map back.
clear_screens:
					ld		h,$40
					call	clear_screen
					ld		a,SCREEN_7_BANK
					ld		bc,$7FFD
					out		(c),a
					ld		h,$C0
					call	clear_screen
					ld		a,MAP_BANK
					ld		bc,$7FFD
					out		(c),a
					xor		a
					out		($FE),a
					ret

; The screen whose high byte is H.
clear_screen:
					ld		l,0
					push	hl
					ld		d,h
					ld		e,1
					ld		(hl),0				; the pixels clear, and all the
					ld		bc,$1B00 - 1		; attributes black on black
					ldir
					pop		hl
					ld		a,h
					add		a,$18
					ld		h,a
					ld		l,VIEW_FIRST_LINE / 8 * 32 + 1	; the view's first row, column 1
					ld		b,VIEW_CHAR_ROWS
.row:				push	bc
					ld		d,h
					ld		e,l
					inc		de
					ld		(hl),$38			; black on white
					ld		bc,29
					ldir
					ld		bc,32 - 29
					add		hl,bc
					pop		bc
					djnz	.row
					ret

					INCLUDE	"../engine/view.s"
					INCLUDE	"../engine/read_view.s"
					INCLUDE	"../engine/paint.s"
					INCLUDE	"../engine/present.s"
					INCLUDE	"../output/view_tables.s"
					INCLUDE	"../output/blocks_gen.s"
code_end:
					ASSERT	code_end <= LISTS
					DISPLAY	"code $8000-", /H, code_end, "  free to the lists: ", /D, LISTS - code_end

; The interrupt routine: switch screens if a frame is ready, and count frames,
; for pacing later. 10 bytes of stack, well inside what clear_back allows.
frames:				EQU		IM2_ROUTINE - 2
					ORG		frames
					DW		0
					ORG		IM2_ROUTINE
					push	af
					push	bc
					push	hl
					call	show_switch
					ld		hl,(frames)
					inc		hl
					ld		(frames),hl
					pop		hl
					pop		bc
					pop		af
					ei
					reti

; The map, in bank 0 at $C000: the device's own mapping at power-on.
					ORG		MAP
					INCBIN	"../output/map.bin"

					SAVEDEV	"../output/demo.banks", 0, 0, $20000
					SAVEBIN	"../output/demo.bin", $4000, $C000
