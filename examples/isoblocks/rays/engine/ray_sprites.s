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
; The heights are his map's (build.py, write_maps): our shifted map
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
; onto the screen. Buffer i's screen address is at RAY_CELL_SCREENS + 2i, and
; its cell's output_map entry at RAY_CELL_ENTRIES + 2i: the same low byte, the
; next page.

RAY_SPRITE_MAX		EQU		4
					ASSERT	RAY_SPRITE_MAX == 4		; order_sprites sorts four
					ASSERT	low RAY_BUFFERS + RAY_CELLS_MAX <= 256
					ASSERT	low RAY_BUFFERS != 0		; 0 in a slot means none
					ASSERT	RAY_CELL_ENTRIES == RAY_CELL_SCREENS + 256

; Opcodes place_strip writes into its band tests for the way down a strip.
OP_ADD_HL_DE		EQU		$19
OP_INC_HL			EQU		$23

ray_sprites:		DS		RAY_SPRITE_MAX * 4, $FF
ray_order:			DS		RAY_SPRITE_MAX * 2	; farthest first: each its number, then key
ray_cell_count:		DB		0
ray_prev_count:		DB		0
ray_prev:			DS		RAY_CELLS_MAX * 2		; last frame's cells' output_map entries

; The sprite being placed.
spr_c:				DB		0			; its top's diamond: strip of the edge...
spr_r:				DB		0			; ...and band
spr_deep:			DB		0			; r_s + 3h + 3
spr_deep_first:		DB		0			; ...less the first band tested, 2j - 3
spr_first_row:		DB		0			; the character rows it covers in the view
spr_rows:			DB		0
spr_picture:		DW		0			; its left byte's rows, from the first row's
spr_screen:			DW		0			; the first row's screen address, column 0
spr_line:			DW		0			; band 2j - 3's line of sight, less 127 (s >> 1)
; The strip being drawn -- and IYH its character row, IYL the rows left.
strip_s:			DB		0
strip_picture:		DW		0			; the picture's rows for the row
strip_screen:		DW		0			; the row's cell's screen address
strip_visible:		DB		0			; the low byte of RAY_VISIBLE for its way round
strip_jumps:		DB		0			; the high byte of its tiles' jump table
strip_slot:			DB		0			; TRI_SLOTS + s, a cell's slot's low byte


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
					; The compiled tiles' common bytes, for start_cell.
					exx
					ld		bc,TILE_B * 256 + TILE_C
					ld		e,TILE_E
					exx
					; The sprites, farthest first (order_sprites).
					call	order_sprites
					ld		hl,ray_order
					ld		b,RAY_SPRITE_MAX
.next_sprite:		push	bc
					push	hl
					ld		a,(hl)				; its number
					add		a,a
					add		a,a
					ld		e,a
					ld		d,0
					ld		ix,ray_sprites
					add		ix,de
					ld		a,(ix+3)
					inc		a					; $FF: no sprite
					call	nz,place_sprite
					pop		hl
					inc		hl
					inc		hl
					pop		bc
					djnz	.next_sprite
					pop		iy
					pop		ix
					ret


; Put ray_order's entries at first_place and second_place in order: as
; words, the key high and the number low, the smaller first.
					MACRO	RAY_ORDER_PAIR first_place, second_place
					ld		hl,(ray_order + 2 * first_place)
					ld		de,(ray_order + 2 * second_place)
					or		a
					sbc		hl,de
					jr		c,.in_order			; already the farther first
					add		hl,de
					ld		(ray_order + 2 * first_place),de
					ld		(ray_order + 2 * second_place),hl
.in_order:
					ENDM

; The sprites in the order to place them, farthest first, into ray_order:
; each its number, then its key -- v - u + h, biased by $80 so that an
; unsigned compare orders it, $FF for no sprite. As a word the key is the
; high byte and the number the low, so no two are equal, and sprites of equal
; keys keep the table's order, as the model's sort does. Five compare-and-
; swaps sort four.
order_sprites:
					ld		ix,ray_sprites
					ld		hl,ray_order
					ld		b,0					; the sprite's number
.key:				ld		a,(ix+3)
					inc		a					; no picture: no sprite
					ld		a,$FF
					jr		z,.none
					ld		a,(ix+1)
					sub		(ix+0)
					add		a,(ix+2)
					xor		$80
.none:				ld		(hl),b
					inc		hl
					ld		(hl),a
					inc		hl
					ld		de,4
					add		ix,de
					inc		b
					ld		a,b
					cp		RAY_SPRITE_MAX
					jr		nz,.key
					RAY_ORDER_PAIR 0, 1
					RAY_ORDER_PAIR 2, 3
					RAY_ORDER_PAIR 0, 2
					RAY_ORDER_PAIR 1, 3
					RAY_ORDER_PAIR 1, 2
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
					; The first row's screen address, column 0: each strip adds s.
					ld		a,c
					dec		a
					add		a,a
					ld		e,a
					ld		d,0
					ld		hl,ray_screen_rows
					add		hl,de
					ld		a,(hl)
					inc		hl
					ld		h,(hl)
					ld		l,a
					ld		(spr_screen),hl
					; Band 2j - 3's line of sight in strip s -- the diamond (s | 1,
					; 2j - 3), U' = (s >> 1) + 2 - j and V' = (s >> 1) + j - 1 -- is
					; map_location + 129j - 130 + 127 (s >> 1): the sprite's part
					; here, the strip's in place_strip.
					ld		d,c
					ld		e,0
					srl		d
					rr		e					; 128j
					ld		hl,(map_location)
					add		hl,de
					ld		e,c
					ld		d,0
					add		hl,de				; 129j
					ld		de,-130
					add		hl,de
					ld		(spr_line),hl
					; The sprite's depth against band 2j - 3: deep - 2j + 3.
					ld		a,c
					add		a,a
					ld		b,a
					ld		a,(spr_deep)
					sub		b
					add		a,3
					ld		(spr_deep_first),a
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
; band before's own, and its line above the band before that's. A line whose
; height is v wins with nearness 3v as a band's own, 3v - 1 as the next
; band's side, and 3v - 2 as the one after's above; the sprite, n < deep - k,
; is three bands shallower by then as well -- so every line of sight has a
; single test, made when it is a band's own: v is 0, or 3v < deep - k. A band
; lets the sprite show if its own line and the two before pass. A character
; cell's triangles are bands 2j - 1, 2j and 2j + 1, so it needs the tests of
; bands 2j - 3 to 2j + 1.
place_strip:
					ld		b,a
					ld		a,(spr_c)
					dec		a
					add		a,b
					ld		(strip_s),a
					dec		a
					cp		RAY_STRIPS			; strips 1 to 30
					ret		nc
					inc		a
					ld		c,a					; s, for what follows
					add		a,TRI_SLOTS
					ld		(strip_slot),a
					; The picture: the right byte's rows 64 bytes on.
					ld		hl,(spr_picture)
					ld		a,b
					rrca
					rrca
					add		a,l
					ld		l,a
					ld		(strip_picture),hl
					; The screen: the first row's, and s.
					ld		hl,(spr_screen)
					ld		a,l
					add		a,c
					ld		l,a
					ld		(strip_screen),hl
					; Its way round: its triangles' pixels, its tiles' jump table,
					; and its steps. Band 2j - 3 is of the first kind in an odd
					; strip, so its bands go +128, +1, +128... and in an even strip
					; +1, +128, +1...
					ld		a,c
					and		1
					rrca
					rrca						; 64 x the way round
					add		a,low RAY_VISIBLE
					ld		(strip_visible),a
					ld		a,c
					rra
					ld		a,high TILE_JUMPS_1
					ld		de,OP_ADD_HL_DE + 256 * OP_INC_HL
					jr		c,.odd
					ld		a,high TILE_JUMPS_0
					ld		de,OP_INC_HL + 256 * OP_ADD_HL_DE
.odd:				ld		(strip_jumps),a
					ld		a,e
					ld		(.first_even),a
					ld		(.row_even),a
					ld		a,d
					ld		(.first_odd),a
					ld		(.row_odd),a
					; Band 2j - 3's line of sight: the sprite's part, and 127 (s >> 1).
					ld		a,c
					srl		a
					ld		e,a
					ld		d,0
					ld		h,a
					ld		l,d
					srl		h
					rr		l					; 128 (s >> 1)
					or		a
					sbc		hl,de				; 127 (s >> 1)
					ld		de,(spr_line)
					add		hl,de
					; The rows: IYH the character row, IYL how many are left.
					ld		a,(spr_first_row)
					ld		iyh,a
					ld		a,(spr_rows)
					ld		iyl,a
					ld		a,(spr_deep_first)
					ld		c,a					; the depth against band 2j - 3
					ld		de,128
					ld		b,0					; each band's test, the latest in bit 0
					RAY_BAND_TEST				; band 2j - 3
.first_even:		add		hl,de				; (these four steps as written above)
					RAY_BAND_TEST				; 2j - 2
.first_odd:			inc		hl
					RAY_BAND_TEST				; 2j - 1
.row:				ld		de,128
.row_even:			add		hl,de
					RAY_BAND_TEST				; 2j
.row_odd:			inc		hl
					RAY_BAND_TEST				; 2j + 1
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
					ld		a,(strip_screen)	; a character row down the screen...
					add		a,32
					ld		(strip_screen),a
					jr		nc,.same_third
					ld		a,(strip_screen + 1)
					add		a,8					; ...into the next third
					ld		(strip_screen + 1),a
.same_third:		inc		iyh
					dec		iyl
					jr		nz,.row
					ret


; The sprite's strip into the cell (IYH, strip_s), A its triangles that let
; it show (4 top, 2 middle, 1 bottom). Keeps IY.
draw_cell:
					; Those triangles' pixels, a byte a row: RAY_VISIBLE for the
					; strip's way round, 8 bytes a set.
					add		a,a
					add		a,a
					add		a,a
					ld		hl,strip_visible
					add		a,(hl)
					ld		ixl,a
					ld		ixh,high RAY_VISIBLE
					; The cell's slot: TRI_SLOTS + s on its tile row's bottom
					; triangles' page, row 2j of triangle_map.
					ld		a,iyh
					add		a,a
					add		a,high triangle_map
					ld		h,a
					ld		a,(strip_slot)
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
					; Its output_map entry, on the same page.
					ld		a,l
					sub		TRI_SLOTS - TRI_OUTPUT
					ld		l,a
					; Its tile, marked as shown: ray_tiles leaves it.
					call	cell_tile
					ld		(hl),a
					ex		de,hl				; DE the entry
					; The tile's code, as draw_tiles would call it, into the buffer
					; (ray_sprites_prepare put its common bytes in B', C', E').
					ld		l,a
					ld		a,(strip_jumps)
					ld		h,a
					ld		a,c
					add		a,low RAY_BUFFERS
					exx
					ld		l,a
					ld		h,high RAY_BUFFERS
					exx
					call	jump_hl				; keeps the main registers
					; The entry, to be put back next frame, and the screen address,
					; for ray_sprites_show: side by side, a page apart.
					ld		a,c
					add		a,a
					add		a,low RAY_CELL_SCREENS
					ld		l,a
					ld		h,high RAY_CELL_ENTRIES
					ld		(hl),e
					inc		l
					ld		(hl),d
					dec		l
					dec		h					; RAY_CELL_SCREENS
					ld		de,(strip_screen)
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
					; Their slots, empty for the next frame: each entry's page,
					; TRI_SLOTS - TRI_OUTPUT on.
					ld		a,(ray_cell_count)
					ld		b,a
					ld		hl,RAY_CELL_ENTRIES
.slot:				ld		a,(hl)
					inc		l
					add		a,TRI_SLOTS - TRI_OUTPUT
					ld		e,a
					ld		d,(hl)
					inc		l
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
					ld		hl,RAY_CELL_ENTRIES
					ld		de,ray_prev
					ldir
					ret
