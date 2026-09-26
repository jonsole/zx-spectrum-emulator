; isoblocks, the ray renderer: the demo (shared/demo.s) with the engine built
; on Tom Harte's caster, tile drawer and scrolling (engine/cast.s, tiles.s, scroll.s and map_steps.s) -- each
; triangle of a fixed grid from the colours worked out for its diamond, the
; triangles kept from frame to frame, and only the tiles that change drawn.
; One view: the map is shifted for view 0.
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
;   bank 0, $C000   his map (output/colours.bin, from shared/maps/test.json):
;                   each diamond's colours,
;                   paged in by ray_cast
;   bank 4, $C000   the heights (output/heights.bin), paged in by
;                   ray_sprites_prepare
					DEVICE	ZXSPECTRUM128

MAP					EQU		$C000
IM2_ROUTINE			EQU		$BBBB
STACK_TOP			EQU		$C000

					INCLUDE	"output/ray_layout.s"

DEMO_SPRITES		EQU		ray_sprites			; the engine's table (engine/ray_sprites.s)

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
					call	demo_start
					ei

frame:
					call	demo_keys
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

					INCLUDE	"../shared/demo.s"
					INCLUDE	"output/ray_tables.s"
					INCLUDE	"engine/map_steps.s"
					INCLUDE	"engine/cast.s"
					INCLUDE	"engine/tiles.s"
					INCLUDE	"engine/scroll.s"
					INCLUDE	"engine/ray_view.s"
					INCLUDE	"engine/ray_sprites.s"
code_end:
					ASSERT	code_end <= TILE_JUMPS_0
					DISPLAY	"code $8000-", /H, code_end, "  free to the jump tables: ", /D, TILE_JUMPS_0 - code_end

					INCLUDE	"output/ray_data.s"
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
					INCBIN	"output/heights.bin"
					MMU		$C000, RAY_COLOUR_BANK
					ORG		MAP
					INCBIN	"output/colours.bin"

					SAVEDEV	"output/rays.banks", 0, 0, $20000
					SAVEBIN	"output/rays.bin", $4000, $C000
