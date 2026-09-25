; isoblocks: sprites for the ray renderer.
;
; A sprite stands in a cell at a height, like a cube, and its 16 x 16 picture
; goes where that cube's would. Its pixels show in a triangle if the sprite is
; nearer than the face the rays found there, or the triangle is floor --
; raycast.py's rule, which check_ray.py proves exact: a sprite whose picture
; is a block looks exactly like a block put in the map.
;
; In diamond terms: a sprite whose top is diamond (c_s, r_s), at height h, is
; r_s + 3h deep; the face in a triangle of band k whose winning nearness is n
; is k + n - 3 deep. It shows where n is 0, or n < r_s + 3h + 3 - k.
;
; Each frame, between ray_cast and ray_tiles, ray_sprites_prepare builds every
; character cell a sprite touches in a buffer -- its tile, then the sprites,
; farthest first -- and marks the cell's tile as already shown in Tom
; Harte's output_map, so ray_tiles leaves it alone. After ray_tiles,
; ray_sprites_show writes the buffers out. A cell is written once a frame, so a
; sprite does not flicker. A cell that had a sprite last frame and has none
; now is marked for ray_tiles to redraw.
;
; The heights are his map's (build.py, write_harte_maps): our shifted map
; with U mirrored, each byte the nearest height on its line of sight plus
; one, and map_location the view's (U0, V0) in it. They are in their own
; bank, which ray_sprites_prepare pages in at $C000 in place of the colours.
;
; A sprite is four bytes in ray_sprites: x, y, height, and its picture's
; number, $FF for none. Pictures and the triangles' pixels are RAY_PICTURES
; and RAY_VISIBLE, from build.py.
;
; The ray layout (build.py) keeps, on each tile row's bottom triangles' page:
;   TRI_OUTPUT + s  the tile the cell in strip s shows (Tom Harte's output_map)
;   TRI_SLOTS + s   its sprite slot: the low byte of its buffer this frame, or
;                   0. All 0 between frames.
; and the buffers at RAY_BUFFERS: buffer i's 8 rows at + i of 8 pages, a page
; apart, like the screen's -- so the compiled tiles draw into them as they do
; onto the screen. Buffer i's screen address is at RAY_CELL_SCREENS + 2i.

RAY_SPRITE_MAX		EQU		4
					ASSERT	low RAY_BUFFERS + RAY_CELLS_MAX <= 256
					ASSERT	low RAY_BUFFERS != 0		; 0 in a slot means none

; Opcodes place_strip writes into ray_band_pair for the way down a strip.
OP_ADD_HL_DE		EQU		$19
OP_INC_HL			EQU		$23

ray_sprites:		DS		RAY_SPRITE_MAX * 4, $FF
ray_cell_count:		DB		0
ray_prev_count:		DB		0
ray_prev:			DS		RAY_CELLS_MAX * 2		; last frame's cells' output_map entries
ray_now_end:		DW		0
ray_now:			DS		RAY_CELLS_MAX * 2		; this frame's

; The sprite being placed.
spr_c:				DB		0			; its top's diamond: strip of the edge...
spr_r:				DB		0			; ...and band
spr_deep:			DB		0			; r_s + 3h + 3
spr_first_row:		DB		0			; the character rows it covers in the view
spr_rows:			DB		0
spr_picture:		DW		0			; its left byte's rows, from the first row's
spr_done:			DB		0			; a bit for each sprite placed already
; The strip being drawn.
strip_s:			DB		0
strip_row:			DB		0
strip_rows:			DB		0			; rows left
strip_picture:		DW		0			; the picture's rows for strip_row
strip_visible:		DW		0			; RAY_VISIBLE for the strip's way round


; One band's test: HL its line of sight, C deep - k (1 at least), B the tests
; so far. Carry into B if the line is empty or 3v < deep - k.
					MACRO	RAY_BAND_TEST
					ld		a,(hl)
					add		a,a
					add		a,(hl)				; 3v
					cp		c
					rl		b
					dec		c					; the next band is one deeper...
					jr		nz,.deep_ok
					inc		c					; ...but kept at 1, so empty passes
.deep_ok:
					ENDM

; One row of a cell: DE the picture's row, IX the triangles' pixels, HL the
; buffer's row.
					MACRO	RAY_BLEND_ROW row
					ld		a,(de)				; the sprite's pixels
					and		(ix+row)			; where its triangles let it show
					ld		c,a
					inc		e
					ld		a,(de)				; its ink
					inc		e
					xor		(hl)
					and		c
					xor		(hl)
					ld		(hl),a
					inc		h					; the buffer's next row, a page on
					ENDM

; ---------------------------------------------------------------------------
; ray_sprites_forget: at the start, before any frame.

ray_sprites_forget:
					ld		hl,triangle_map + 512 + TRI_SLOTS	; tile row 0's, on row 2
					ld		b,num_rows
.row:				push	bc
					ld		d,h
					ld		e,l
					inc		de
					ld		(hl),0
					ld		bc,31
					ldir
					pop		bc
					ld		l,TRI_SLOTS
					inc		h
					inc		h					; two rows of triangles a row of tiles
					djnz	.row
					xor		a
					ld		(ray_prev_count),a
					ret


; ---------------------------------------------------------------------------
; ray_sprites_prepare: after ray_cast, before ray_tiles. Uses everything; keeps
; IX and IY.

ray_sprites_prepare:
					ld		bc,$7FFD
					ld		a,RAY_HEIGHT_PAGE	; the heights at $C000
					out		(c),a
					push	ix
					push	iy
					; Last frame's cells: to be redrawn, unless a sprite is on them
					; again, which marks them shown once more below.
					ld		a,(ray_prev_count)
					or		a
					jr		z,.restored
					ld		b,a
					ld		hl,ray_prev
.restore:			ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		a,$FF
					ld		(de),a
					djnz	.restore
.restored:			xor		a
					ld		(ray_cell_count),a
					ld		(spr_done),a
					ld		hl,ray_now
					ld		(ray_now_end),hl
					; The sprites, farthest first: each time, the one not yet placed
					; with the least v - u + h.
					ld		b,RAY_SPRITE_MAX
.next_sprite:		push	bc
					call	farthest_left
					jr		c,.all_placed
					call	place_sprite
					pop		bc
					djnz	.next_sprite
					jr		.done
.all_placed:		pop		bc
.done:				pop		iy
					pop		ix
					ret


; The sprite not yet placed that is farthest away: IX its entry, and its bit
; set in spr_done. Carry set if there is none.
farthest_left:
					ld		iy,0				; none found yet
					ld		hl,ray_sprites
					ld		b,RAY_SPRITE_MAX
					ld		c,1					; this sprite's bit
					ld		e,$FF				; the least depth so far, biased
.sprite:			ld		a,(spr_done)
					and		c
					jr		nz,.skip
					push	hl
					inc		hl
					inc		hl
					inc		hl
					ld		a,(hl)				; its picture: $FF, none
					pop		hl
					inc		a
					jr		z,.skip
					; v - u + h, biased by $80 so an unsigned compare orders it.
					inc		hl
					ld		a,(hl)				; v
					dec		hl
					sub		(hl)				; - u
					inc		hl
					inc		hl
					add		a,(hl)				; + h
					dec		hl
					dec		hl
					xor		$80
					cp		e
					jr		nc,.skip			; no nearer than the farthest so far
					ld		e,a
					push	hl
					pop		iy
					ld		d,c
.skip:				inc		hl
					inc		hl
					inc		hl
					inc		hl
					sla		c
					djnz	.sprite
					push	iy
					pop		hl
					ld		a,h
					or		l
					scf
					ret		z
					push	iy
					pop		ix
					ld		a,(spr_done)
					or		d
					ld		(spr_done),a
					or		a					; carry clear
					ret


; Place the sprite at IX: build each cell it touches.
place_sprite:
					; U' = x + h - U0, V' = y - h - V0.
					ld		a,(ray_focus_x)
					add		a,RAY_U_OFFSET
					ld		e,a					; U0
					ld		a,(ix+0)
					add		a,(ix+2)
					sub		e
					ld		e,a					; U'
					ld		a,(ray_focus_y)
					add		a,RAY_V_OFFSET
					ld		d,a					; V0
					ld		a,(ix+1)
					sub		(ix+2)
					sub		d
					ld		d,a					; V'
					add		a,e
					ld		(spr_c),a			; c = U' + V'
					ld		a,d
					sub		e
					ld		(spr_r),a			; r = V' - U'
					; Seen at all? Its picture is lines 4r to 4r + 15, and the view
					; lines 8 to 135: r from -1 to 33. Its strips are c - 1 and c,
					; and the view's 1 to 30: c from 1 to 31.
					inc		a
					cp		35
					ret		nc
					ld		a,(spr_c)
					dec		a
					cp		31
					ret		nc
					; Its depth, r + 3h, plus 3.
					ld		a,(ix+2)
					ld		b,a
					add		a,a
					add		a,b
					ld		b,a
					ld		a,(spr_r)
					add		a,b
					add		a,3
					ld		(spr_deep),a
					; The character rows it covers: from 4r / 8 -- r / 2, rounded
					; down -- while a row's first line, 8j, is within the picture:
					; 2j <= r + 3. Only rows 1 to 16 are the view's.
					ld		a,(spr_r)
					add		a,3
					sra		a
					cp		RAY_CHAR_ROWS + 1
					jr		c,.last_ok
					ld		a,RAY_CHAR_ROWS
.last_ok:			ld		b,a					; the last row
					ld		a,(spr_r)
					sra		a
					dec		a
					jp		p,.first_ok			; row 1 or below
					xor		a
.first_ok:			inc		a
					ld		(spr_first_row),a
					ld		c,a
					ld		a,b
					sub		c
					inc		a
					ld		(spr_rows),a
					; The picture's row for the first row's top line, 8j - 4r, is
					; -4 to 12; with the 8 empty rows before it, 4 to 20. Two bytes
					; a row.
					ld		a,c
					add		a,a
					ld		hl,spr_r
					sub		(hl)				; 2j - r
					add		a,a
					add		a,a					; 8j - 4r
					add		a,RAY_PICTURE_PAD
					add		a,a					; its byte
					ld		e,a
					ld		d,0
					ld		a,(ix+3)			; a picture a page
					add		a,high RAY_PICTURES
					ld		h,a
					ld		l,low RAY_PICTURES
					add		hl,de
					ld		(spr_picture),hl
					; Its two strips: c - 1 has the picture's left byte, c its right.
					xor		a
					call	place_strip
					ld		a,1
					; fall into place_strip for the right byte


; One strip of the sprite: A 0 for its picture's left byte, 1 for its right.
;
; Which triangles of the strip let the sprite show, all in one pass down it.
; Band k of strip s is the right half of diamond (s, k) when s + k is even,
; with its side's line of sight to the right; otherwise it is the left half of
; diamond (s + 1, k), its side to the left. Diamond (c, r)'s line of sight is
; map_location + 128 (c + r) / 2 - (c - r) / 2 in the map, U being mirrored.
; So going down the strip a band at a time, a band's line of sight is one row
; of the map on (+128) from a band of the first kind, one cell back along U
; (+1, mirrored) from one of the second; and each band's side line is the
; band before's own, and its line
; above the band before that's. A line whose height is v wins with nearness
; 3v as a band's own, 3v - 1 as the next band's side, and 3v - 2 as the one
; after's above; the sprite, n < deep - k, is three bands shallower by then as
; well -- so every line of sight has a single test, made when it is a band's
; own: v is 0, or 3v < deep - k. A band lets the sprite show if its own line
; and the two before pass. A character cell's triangles are bands 2j - 1, 2j
; and 2j + 1, so it needs the tests of bands 2j - 3 to 2j + 1.
place_strip:
					ld		b,a
					ld		a,(spr_c)
					dec		a
					add		a,b
					ld		(strip_s),a
					dec		a
					cp		RAY_STRIPS			; strips 1 to 30
					ret		nc
					; The picture: the right byte's rows 64 bytes on.
					ld		hl,(spr_picture)
					ld		a,b
					rrca
					rrca
					ld		e,a
					ld		d,0
					add		hl,de
					ld		(strip_picture),hl
					ld		a,(spr_first_row)
					ld		(strip_row),a
					ld		a,(spr_rows)
					ld		(strip_rows),a
					; The strip's way round: its triangles' pixels, and its steps.
					; Band 2j - 3 is of the first kind in an odd strip, so its bands
					; go +128, +1, +128... and in an even strip +1, +128, +1...
					ld		a,(strip_s)
					and		1
					rrca
					rrca						; 64 x the way round
					ld		l,a
					ld		h,0
					ld		de,RAY_VISIBLE
					add		hl,de
					ld		(strip_visible),hl
					ld		a,(strip_s)
					rra
					ld		a,OP_ADD_HL_DE
					ld		b,OP_INC_HL
					jr		c,.odd
					ld		a,OP_INC_HL
					ld		b,OP_ADD_HL_DE
.odd:				ld		(ray_band_pair.step_even),a
					ld		a,b
					ld		(ray_band_pair.step_odd),a
					; Band 2j - 3's line of sight, j the first row: the diamond is
					; (s | 1, 2j - 3), which is U' = (s >> 1) + 2 - j and V' =
					; (s >> 1) + j - 1, at 127 (s >> 1) + 129j - 130.
					ld		a,(strip_s)
					srl		a
					ld		e,a
					ld		d,0
					ld		h,a
					ld		l,d
					srl		h
					rr		l					; 128 (s >> 1)
					or		a
					sbc		hl,de				; 127 (s >> 1)
					ld		de,-130
					add		hl,de
					ld		a,(spr_first_row)
					ld		d,a
					ld		e,0
					srl		d
					rr		e					; 128j
					add		hl,de
					ld		e,a
					ld		d,0
					add		hl,de				; 129j
					ld		de,(map_location)
					add		hl,de
					; The sprite's depth against band 2j - 3: deep - 2j + 3.
					add		a,a
					ld		c,a
					ld		a,(spr_deep)
					sub		c
					add		a,3
					ld		c,a
					ld		de,128
					ld		b,0					; each band's test, the latest in bit 0
					RAY_BAND_TEST				; band 2j - 3
					call	ray_band_pair		; 2j - 2 and 2j - 1
.row:				ld		de,128
					call	ray_band_pair		; 2j and 2j + 1
					; The cell's triangles: a band shows if it and the two before it
					; passed. Bits 4 to 0 are bands 2j - 3 to 2j + 1, so this leaves
					; 4 the top, 2 the middle and 1 the bottom.
					ld		a,b
					rrca
					and		b
					ld		e,a
					rrca
					and		e
					and		7
					jr		z,.next_row			; none of the sprite shows here
					push	bc
					push	hl
					call	draw_cell
					pop		hl
					pop		bc
.next_row:			ld		a,(strip_picture)
					add		a,16				; 8 rows on, in its 64-byte block
					ld		(strip_picture),a
					ld		a,(strip_row)		; (HL is the line of sight)
					inc		a
					ld		(strip_row),a
					ld		a,(strip_rows)
					dec		a
					ld		(strip_rows),a
					jr		nz,.row
					ret



; The next two bands down a strip: one of each kind, the steps between them
; written by place_strip. DE is 128.
ray_band_pair:
.step_even:			add		hl,de
					RAY_BAND_TEST
.step_odd:			inc		hl
					RAY_BAND_TEST
					ret


; The sprite's strip into the cell (strip_row, strip_s), A its triangles that
; let it show (4 top, 2 middle, 1 bottom). Keeps nothing.
draw_cell:
					; Those triangles' pixels, a byte a row.
					add		a,a
					add		a,a
					add		a,a
					ld		hl,(strip_visible)
					add		a,l
					ld		l,a
					push	hl
					pop		ix
					; The cell's slot: TRI_SLOTS + s on its tile row's bottom
					; triangles' page, row 2j of triangle_map.
					ld		a,(strip_row)
					add		a,a
					add		a,high triangle_map
					ld		h,a
					ld		a,(strip_s)
					add		a,TRI_SLOTS
					ld		l,a
					ld		a,(hl)
					or		a
					jr		nz,.started
					call	start_cell
					ret		c					; no room: this cell goes without
.started:			ld		l,a
					ld		h,high RAY_BUFFERS	; the buffer's first row
					ld		de,(strip_picture)
					; Each row: buffer ^ ((buffer ^ ink) & sprite & showing).
					RAY_BLEND_ROW 0
					RAY_BLEND_ROW 1
					RAY_BLEND_ROW 2
					RAY_BLEND_ROW 3
					RAY_BLEND_ROW 4
					RAY_BLEND_ROW 5
					RAY_BLEND_ROW 6
					RAY_BLEND_ROW 7
					ret



; Start a buffer for the cell whose slot is HL: its tile drawn into it, the
; tile marked as shown, and its screen address noted. A the buffer's low
; byte; carry set if there is no room.
start_cell:
					ld		a,(ray_cell_count)
					cp		RAY_CELLS_MAX
					ccf
					ret		c
					ld		c,a					; the buffer's number
					inc		a
					ld		(ray_cell_count),a
					ld		a,c
					add		a,low RAY_BUFFERS
					ld		(hl),a				; the slot: the buffer
					; Its output_map entry, on the same page, remembered to be put
					; back next frame.
					ld		a,l
					sub		TRI_SLOTS - TRI_OUTPUT
					ld		l,a
					ex		de,hl
					ld		hl,(ray_now_end)
					ld		(hl),e
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(ray_now_end),hl
					ex		de,hl
					; Its tile, marked as shown: ray_tiles leaves it.
					call	cell_tile
					ld		(hl),a
					; The tile's code, as draw_tiles would call it, into the buffer.
					ld		l,a
					ld		a,(strip_s)
					rra
					ld		h,high TILE_JUMPS_0
					jr		nc,.way
					ld		h,high TILE_JUMPS_1
.way:				ld		a,c
					add		a,low RAY_BUFFERS
					exx
					ld		l,a
					ld		h,high RAY_BUFFERS
					ld		bc,TILE_B * 256 + TILE_C
					ld		e,TILE_E
					exx
					call	jump_hl				; keeps the main registers
					; The cell's screen address, for ray_sprites_show.
					ld		a,(strip_row)
					dec		a
					add		a,a
					ld		e,a
					ld		d,0
					ld		hl,ray_screen_rows
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		a,(strip_s)
					add		a,e
					ld		e,a					; DE the screen address
					ld		a,c
					add		a,a
					add		a,low RAY_CELL_SCREENS
					ld		l,a
					ld		h,high RAY_CELL_SCREENS
					ld		(hl),e
					inc		l
					ld		(hl),d
					ld		a,c
					add		a,low RAY_BUFFERS
					or		a					; carry clear
					ret


; The tile a cell shows, as Tom Harte's draw_tiles makes it. In: HL the
; cell's output_map entry, TRI_OUTPUT + s on the page of its bottom
; triangles. Out: A the tile number, HL the entry. Keeps BC and DE.
;
; Its triangles are strip s of the two pages before and this one; the number
; is the top's colour shifted right twice, or the middle's shifted once, or
; the bottom's.
cell_tile:
					ld		a,l
					sub		TRI_OUTPUT			; s -- and no borrow, so carry clear
					ld		l,a
					dec		h
					dec		h					; the top triangle
					ld		a,(hl)
					rra
					inc		h
					or		(hl)
					rra
					inc		h
					or		(hl)				; the tile number
					set		5,l					; the entry again
					ret


; ---------------------------------------------------------------------------
; ray_sprites_show: after ray_tiles, the cells' buffers to the screen, and
; their slots emptied for the next frame.

ray_sprites_show:
					ld		a,(ray_cell_count)
					or		a
					jr		z,.shown
					ld		b,a
					ld		c,low RAY_BUFFERS
					ld		hl,RAY_CELL_SCREENS
.cell:				ld		e,(hl)
					inc		l
					ld		d,(hl)
					inc		l
					push	hl
					ld		l,c
					ld		h,high RAY_BUFFERS
					DUP		8
					ld		a,(hl)
					ld		(de),a
					inc		h
					inc		d
					EDUP
					pop		hl
					inc		c
					djnz	.cell
					; Their slots, empty for the next frame.
					ld		a,(ray_cell_count)
					ld		b,a
					ld		hl,ray_now
.slot:				ld		a,(hl)
					inc		hl
					add		a,TRI_SLOTS - TRI_OUTPUT
					ld		e,a
					ld		d,(hl)
					inc		hl
					xor		a
					ld		(de),a
					djnz	.slot
.shown:				; This frame's cells are next frame's last.
					ld		a,(ray_cell_count)
					ld		(ray_prev_count),a
					add		a,a
					ret		z
					ld		c,a
					ld		b,0
					ld		hl,ray_now
					ld		de,ray_prev
					ldir
					ret
