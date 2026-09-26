; isoblocks, the painter: the demo (shared/demo.s) with the painter's engine
; -- the view read and sorted by height, painted lowest first onto the hidden
; one of the 128K's two screens, the sprites in their turns, and the screens
; switched at the interrupt.
;
;   bank 2, $8000   this, the engine, and its work space (engine/layout.s)
;   bank 5, $4000   the first screen
;   bank 0, $C000   the map (output/map.bin, from shared/maps/test.json)
;   bank 7          the second screen, paged in at $C000 to be painted
					DEVICE	ZXSPECTRUM128

					INCLUDE	"engine/layout.s"

DEMO_SPRITES		EQU		sprites				; the engine's table (engine/sprites.s)

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
					call	demo_start
					ei

frame:
					call	demo_keys
					; The view follows the figure.
					ld		a,(sprites + 0)
					ld		(focus_x),a
					ld		a,(sprites + 1)
					ld		(focus_y),a
					call	view_update
					call	read_view
					call	sort_places
					call	order_sprites
					call	clear_back
					call	paint
					call	show_back
					jr		frame


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

					INCLUDE	"../shared/demo.s"
					INCLUDE	"engine/view.s"
					INCLUDE	"engine/read_view.s"
					INCLUDE	"engine/paint.s"
					INCLUDE	"engine/sprites.s"
					INCLUDE	"engine/present.s"
					INCLUDE	"output/view_tables.s"
					INCLUDE	"output/blocks_gen.s"
					INCLUDE	"output/sprite_pictures.s"
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
					INCBIN	"output/map.bin"

					SAVEDEV	"output/painter.banks", 0, 0, $20000
					SAVEBIN	"output/painter.bin", $4000, $C000
