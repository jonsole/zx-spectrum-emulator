; isoblocks: Tom Harte's ray caster, from his Isometric-Ray-Cast
; (github.com/TomHarte/Isometric-Ray-Cast, src/cast.asm at 6d48476), used as
; public domain. For sjasmplus, his REPT blocks are DUPs and the EQUs they
; redefine are =. num_rows is the isoblocks view's.
;
; Changed for isoblocks, to be quicker:
; - His cast_diamond read four lines of sight and compared them to choose
;   each half's colour. That choice depends only on the map, so the build
;   makes it, with his rule (build.py, write_harte_maps), and his map now
;   holds its answers: each byte the colours of the diamond whose front line
;   it is, the left half's in bits 7 and 4 and the right half's in bits 6
;   and 3. A triangle is one read and a mask: AND $90 for a left half, ADD
;   A,A and AND $90 for a right. The heights, which the sprites need, are
;   a second map in another bank (ray_sprites.s pages it in).
; - So his rows and columns are one pass each, with no calls: a row steps
;   along the map by 127, a column by his inc_x and inc_y.
; - triangle_map's rows are a page apart (build.py, the ray layout), so a row
;   on is INC IXH.
;
; His rule, which build.py follows:
;
;	In this diagram:
;
;		      /\
;		     /  \
;		    / B  \
;		   /\    /\			B = back
;		  /  \  /  \		L = left
;		 / L  \/  R \		R = right
;		|\    /\    /|		F = front
;		| \  /  \  / |
;		|  \/ F  \/  |
;		\  |\    /|  /
;		 \ | \  / | /
;		  \|  \/  |/
;		   \  |   /
;		    \ |  /
;		     \| /
;		      \/
;
;	The objective is to pick the proper colour for the left and right
;	halves of the front cube.
;
;	The test is then pretty simple: if the F cube is present, both colours
;	will be that of the top of the cube.
;
;	If F is absent but L is present, the rightward face colour is visible
;	on the left half. If R is present, the rightward face colour is visible
;	in the right half.
;
;	If F and L are both absent but B is present then the leftward face colour
;	is visible on the left half. And similarly on the right.
;
;	If F, L, R and B are all absent, the search proceeds to the four cubes one
;	level down and one spot backward.
;
;	Note on axes in use here:
;
;	If B were at the origin then:
;
;		- R would be at (1, 0);
;		- L would be at (0, 1); and
;		- F would be at (1, 1).
;
; (In the triangle bytes, as his cast made them with a mask of $90: floor 0,
; the top $10, the left wall $80, the right wall $90.)

num_rows			EQU		RAY_CHAR_ROWS

; A left half: the colour byte in A to its triangle.
					MACRO	LEFT_HALF
					and		$90
					ENDM

; A right half.
					MACRO	RIGHT_HALF
					add		a,a
					and		$90
					ENDM


;
;	Current map location in the top left of the display.
;

map_location:	dw 0xc0ff

;
;	Casts an even row of tiles, i.e. one containing 16 complete diamonds.
;	So, an even row looks like:
;
;	<><><><><><><><><><><><><><><><>
;
;	(isoblocks: HL the first diamond's line of sight; each next is his
;	inc_x_dec_y on, 127 bytes.)
;

cast_even_row:
	ld bc, 127
	DUP 16, offset
		ld a, (hl)
		ld e, a
		LEFT_HALF
		ld (ix + offset*2), a
		ld a, e
		RIGHT_HALF
		ld (ix + offset*2 + 1), a
		IF offset != 15
			add hl, bc
		ENDIF
	EDUP

	; Advance IX a row, a page, and return.
	inc ixh
	ret

;
;	Casts an odd row of tiles, i.e. one containing 15 complete diamonds
;	and two halves. So, an odd row looks like:
;
;	><><><><><><><><><><><><><><><><
;

cast_odd_row:
	ld bc, 127

	; Fill the single triangle on the left.
	ld a, (hl)
	RIGHT_HALF
	ld (ix + 0), a
	add hl, bc

	; Fill all the intermediate diamonds.
	DUP 15, offset
		ld a, (hl)
		ld e, a
		LEFT_HALF
		ld (ix + offset*2 + 1), a
		ld a, e
		RIGHT_HALF
		ld (ix + offset*2 + 2), a
		add hl, bc
	EDUP

	; Populate the single triangle on the right.
	ld a, (hl)
	LEFT_HALF
	ld (ix + 31), a

	; Advance IX a row, a page, and return.
	inc ixh
	ret

;
;	Casts an even column of tiles, i.e. one containing 2 x num_rows + 1
;	triangles in which the top, truncated one is facing left.
;	i.e.
;
;	____
;	|\ |
;	| \|
;	| /|
;	|/ |
;	|\ |
;	| \|
;	| /|
;	|/ |
;	... etc ...
;
;	(isoblocks: a triangle a row, the rows a page apart. His column cast the
;	left half at HL, the right half at his inc_y on, and the next left at
;	his inc_x on from there: +1, then +128.)
;

cast_even_column:
	ld de, 128

	DUP num_rows
		ld a, (hl)
		LEFT_HALF
		ld (ix + 0), a
		inc ixh

		inc l				; his inc_y: the column never reaches the row's end
		ld a, (hl)
		RIGHT_HALF
		ld (ix + 0), a
		inc ixh

		add hl, de			; his inc_x
	EDUP

	ld a, (hl)
	LEFT_HALF
	ld (ix + 0), a

	ret

;
;	Casts an odd column of tiles, i.e. one containing 2 x num_rows + 1
;	triangles in which the top, truncated one is facing right.
;	i.e.
;
;	____
;	| /|
;	|/ |
;	|\ |
;	| \|
;	| /|
;	|/ |
;	|\ |
;	| \|
;	... etc ...
;
;	(isoblocks: the right half at HL, the left half at his inc_x on, and the
;	next right at his inc_y on from there: +128, then +1.)
;

cast_odd_column:
	ld de, 128

	DUP num_rows
		ld a, (hl)
		RIGHT_HALF
		ld (ix + 0), a
		inc ixh

		add hl, de			; his inc_x
		ld a, (hl)
		LEFT_HALF
		ld (ix + 0), a
		inc ixh

		inc l				; his inc_y
	EDUP

	ld a, (hl)
	RIGHT_HALF
	ld (ix + 0), a

	ret

;
;	Repopulates the entirety of triangle_map based on the current `map_location`.
;

cast_map:
	; Set the triangle destination pointer.
	ld ix, triangle_map

	; Seed the current casting location.
	ld hl, (map_location)

	; Cast the first 2n rows.
	DUP num_rows, index
		IF index != 0
			pop hl
		ENDIF
		inc_x
		push hl
		call cast_even_row

		pop hl
		inc_y
		push hl
		call cast_odd_row
	EDUP

	; Cast an additional row; an odd number is required.
	pop hl
	inc_x
	jp cast_even_row			; i.e. call cast_even_row; ret
