; isoblocks: Tom Harte's tile drawer, from his Isometric-Ray-Cast
; (github.com/TomHarte/Isometric-Ray-Cast, src/drawtiles.asm at 6d48476), used
; as public domain. To fit: the screen-address table and the buffers are where
; the program lays them out, his REPT blocks are DUPs, the EQUs they redefine
; are =, and the labels inside them are sjasmplus's temporary ones.
;
; Changed for isoblocks, to be quicker:
; - Only columns 1-30. The view's columns 0 and 31 are black on black, so
;   nothing drawn there shows.
; - triangle_map's rows are a page apart, and each tile row's output_map
;   entries sit on its bottom triangles' page, TRI_OUTPUT on (build.py, the
;   ray layout). So a tile's three triangles are INC H apart, and the tile it
;   shows is SET 5,L from its bottom one: 76 T-states a tile left as it was,
;   against 96 with rows 32 bytes apart and output_map through IX.
; - The tiles are compiled (build.py, write_ray_data): each is code storing
;   its 8 bytes down the screen, reached through a table of JPs by its
;   number. The row's screen address stays put, its low byte in IYH, its high
;   in D'; the three commonest tile bytes are held in B', C' and E'.

;
;	Outputs the current state of the triangle map, columns 1 to 30.
;

draw_tiles:
	ld iyl, num_rows-1			; Row counter: there'll be `num_rows` of them.

	ld de, triangle_map + 1		; Seed pointer into triangle map, at column 1.

	exx
		ld bc, TILE_B * 256 + TILE_C	; The compiled tiles' common bytes.
		ld e, TILE_E
	exx

draw_row:
	;
	; D' = the high byte of the video address for the start of the line;
	; IYH its low byte.
	;

	ld a, iyl
	exx
		add a, a
		add a, low video_pointers
		ld l, a
		ld h, high video_pointers
		ld a, (hl)
		inc l
		ld d, (hl)
	exx
	ld iyh, a

	; Columns 1 to 30: odd then even, fifteen times.
	DUP 15, pair

		DUP 2, second
_column = (pair * 2) + 1 + second
			; Get and increment the base triangle address;
			ld h, d
			ld l, e
			inc e

			; Carry is guaranteed reset here -- by the add a, a above, the
			; cp below when it found the tile unchanged, or the tile's code.

			; Assemble tile index in a.
			ld a, (hl)
			rra

			inc h
			or (hl)
			rra

			inc h
			or (hl)

			; Compare with previously-output tile and skip if possible.
			set 5, l
			cp (hl)
			jr z, 2F

			ld (hl), a

			; Its code, through the table for this way round.
			ld l, a
			IF (_column & 1)
				ld h, high TILE_JUMPS_1
			ELSE
				ld h, high TILE_JUMPS_0
			ENDIF

			; The cell's top line: the row's, and this column.
			exx
				ld a, iyh
				add a, _column
				ld l, a
				ld h, d
			exx
			call jump_hl
2:
		EDUP
	EDUP

	;
	;	On to the next row of tiles: two rows of triangles down, column 1.
	;
	inc d
	inc d
	ld e, 1

	; Continue row loop. IYl is valid from num_rows - 1 to 0.
	dec iyl
	jp p, draw_row

	ret

; JP (HL), for a CALL to it: the compiled tiles return.
jump_hl:
	jp (hl)
