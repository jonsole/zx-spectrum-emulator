; isoblocks: Tom Harte's map-address macros, from his Isometric-Ray-Cast
; (github.com/TomHarte/Isometric-Ray-Cast, src/addressmanipulation.asm at
; 6d48476), used as public domain.
;
; In isoblocks' terms, his map is our shifted map with U mirrored: his x is
; our V, his y is 127 - U (build.py, write_harte_map). So his x + 1 is a row
; of the map on, 128 bytes, and his y + 1 a byte on along the row.
;
; Changed for isoblocks: his macros keep x and y wrapping round within the
; map, at 24-54 T-states a step. Ours never reads off the map -- ray_update
; holds the focus back from the edges (build.py's limits cover every cell a
; cast reads) -- so no step ever wraps, and each is the plain arithmetic:
; 6 T-states for y, about 26 for x. All but add_xy, which is his and rare.
;
;	Map addresses are in the form:
;
;		11 xxxxxxx yyyyyyy
;
;	[inc_dec]_[x/y] then increment or decrement the x or y fields,
;	without altering the others.
;
;	All macros affect the flags. The x macros also clobber `a`.
;

dec_y MACRO
	dec hl			; 6
ENDM

inc_y MACRO
	inc hl			; 6
ENDM

inc_x MACRO
	ld a, l			; 4
	add a, 128		; 7
	ld l, a			; 4
	jr nc, $+3		; 12 / 7
	inc h			; 4		= 26-27
ENDM

dec_x MACRO
	ld a, l
	sub 128
	ld l, a
	jr nc, $+3
	dec h			; = 26-27
ENDM

inc_x_dec_y MACRO
	ld a, l
	add a, 127
	ld l, a
	jr nc, $+3
	inc h			; = 26-27
ENDM

add_xy MACRO x, y
	add hl, hl

	ld a, l
	add a, y
	add a, y
	ld l, a

	ld a, h
	add a, x
	or 0x80
	ld h, a

	sra h
	rr l
ENDM
