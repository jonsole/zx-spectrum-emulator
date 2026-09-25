; isoblocks ray demo: the second renderer on the test map, built on Tom
; Harte's caster, tile drawer and scrolling (engine/harte_*.s).
;
; Q, A, O and P walk a figure a cell along the map's y and x, and the view
; follows it. Three more sprites stand about: a ball on a column, one on the
; bridge, and a figure in the courtyard of the house. One view only, so far:
; the map is shifted for view 0. Nothing stops the figure walking into walls
; yet -- that wants the map itself, which is stage 2.
;
;   bank 2, $8000   this and the engine
;           $9A00   the compiled tiles' jump tables, one a way round
;           $9C00   the interrupt vectors
;           $9F00   triangle_map: row r of triangles at $9F00 + 256r, rows
;                   0-32; beside them the tiles shown (output_map) and the
;                   sprite slots, and in the rest of the pages the compiled
;                   tiles, the sprite buffers and tables, the routine at
;                   $BBBB, and the stack (build.py, the ray layout)
;   bank 5, $4000   the screen
;   bank 0, $C000   his map (output/harte_map.bin): each diamond's colours,
;                   paged in by ray_cast
;   bank 4, $C000   the heights (output/harte_heights.bin), paged in by
;                   ray_sprites_prepare
					DEVICE	ZXSPECTRUM128

MAP					EQU		$C000
IM2_ROUTINE			EQU		$BBBB
STACK_TOP			EQU		$C000

					INCLUDE	"../output/ray_layout.s"

					ORG		$8000

start:
					di
					ld		sp,STACK_TOP
					ld		hl,IM2_TABLE
					ld		de,IM2_TABLE + 1
					ld		bc,256
					ld		(hl),high IM2_ROUTINE
					ldir
					ld		a,high IM2_TABLE
					ld		i,a
					im		2
					call	clear_screen
					call	ray_forget
					call	ray_sprites_forget
					ld		hl,demo_sprites
					ld		de,ray_sprites
					ld		bc,4 * 4
					ldir
					ei

frame:
					call	read_keys
					; The view follows the figure.
					ld		a,(ray_sprites + 0)
					ld		(ray_focus_x),a
					ld		a,(ray_sprites + 1)
					ld		(ray_focus_y),a
					call	ray_update
					call	ray_cast
					call	ray_sprites_prepare
					call	ray_tiles
					call	ray_sprites_show
					jr		frame

; x, y, height, picture.
demo_sprites:		DB		64, 64, 0, RAY_PICTURE_FIGURE		; the one that walks
					DB		52, 70, 5, RAY_PICTURE_BALL			; on column 5
					DB		77, 60, 4, RAY_PICTURE_BALL			; on the bridge
					DB		75, 80, 0, RAY_PICTURE_FIGURE		; in the courtyard


read_keys:
					ld		bc,$FBFE			; Q W E R T
					in		a,(c)
					rra
					jr		c,.not_q
					ld		hl,ray_sprites + 1
					dec		(hl)
.not_q:				ld		b,$FD				; A S D F G
					in		a,(c)
					rra
					jr		c,.not_a
					ld		hl,ray_sprites + 1
					inc		(hl)
.not_a:				ld		b,$DF				; P O I U Y
					in		a,(c)
					rra
					jr		c,.not_p
					ld		hl,ray_sprites + 0
					inc		(hl)
.not_p:				rra
					ret		c
					ld		hl,ray_sprites + 0
					dec		(hl)
					ret


; Black everywhere but the view, which is black on white.
clear_screen:
					ld		hl,$4000
					ld		de,$4001
					ld		bc,$1800
					ld		(hl),0
					ldir
					ld		(hl),0
					ld		bc,$0300
					ldir
					ld		hl,$5821
					ld		b,16
.row:				push	bc
					ld		d,h
					ld		e,l
					inc		de
					ld		(hl),$38
					ld		bc,29
					ldir
					ld		bc,3
					add		hl,bc
					pop		bc
					djnz	.row
					xor		a
					out		($FE),a
					ret

					INCLUDE	"../output/ray_tables.s"
					INCLUDE	"../engine/harte_macros.s"
					INCLUDE	"../engine/harte_cast.s"
					INCLUDE	"../engine/harte_tiles.s"
					INCLUDE	"../engine/harte_scroll.s"
					INCLUDE	"../engine/ray_view.s"
					INCLUDE	"../engine/ray_sprites.s"
code_end:
					ASSERT	code_end <= TILE_JUMPS_0
					DISPLAY	"code $8000-", /H, code_end, "  free to the jump tables: ", /D, TILE_JUMPS_0 - code_end

					INCLUDE	"../output/ray_data.s"
					ASSERT	IM2_TABLE + 257 <= triangle_map
					ASSERT	triangle_map + 256 * triangle_rows <= STACK_TOP

frames:				EQU		IM2_ROUTINE - 2
					ORG		frames
					DW		0
					ORG		IM2_ROUTINE
					push	hl
					ld		hl,(frames)
					inc		hl
					ld		(frames),hl
					pop		hl
					ei
					reti

					MMU		$C000, RAY_HEIGHT_BANK
					ORG		MAP
					INCBIN	"../output/harte_heights.bin"
					MMU		$C000, RAY_COLOUR_BANK
					ORG		MAP
					INCBIN	"../output/harte_map.bin"

					SAVEDEV	"../output/ray_demo.banks", 0, 0, $20000
					SAVEBIN	"../output/ray_demo.bin", $4000, $C000
