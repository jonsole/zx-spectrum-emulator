; isoblocks: the demo both renderers run -- the same scene and the same keys.
;
; The test map; a figure that Q, A, O and P walk a cell along the map's y and
; x, with the view following it; and three more sprites standing about: a
; ball on a column, one on the bridge, and a figure in the courtyard of the
; house. One view. Nothing stops the figure walking into walls yet -- that
; wants the map itself, which is stage 2.
;
; A program defines DEMO_SPRITES, its engine's table of four sprites (four
; bytes each: x, y, height, picture), and the pictures PICTURE_FIGURE and
; PICTURE_BALL; calls demo_start once and demo_keys each frame, and centres
; its view on the first sprite, the figure.

; Put the sprites in the engine's table.
demo_start:
					ld		hl,demo_sprites
					ld		de,DEMO_SPRITES
					ld		bc,4 * 4
					ldir
					ret

; x, y, height, picture.
demo_sprites:		DB		64, 64, 0, PICTURE_FIGURE			; the one that walks
					DB		52, 70, 5, PICTURE_BALL				; on column 5
					DB		77, 60, 4, PICTURE_BALL				; on the bridge
					DB		75, 80, 0, PICTURE_FIGURE			; in the courtyard

; Q/A/O/P walk the figure a cell along the map's y and x, a cell a frame while
; a key is held.
demo_keys:
					ld		bc,$FBFE			; Q W E R T
					in		a,(c)
					rra
					jr		c,.not_q
					ld		hl,DEMO_SPRITES + 1
					dec		(hl)
.not_q:				ld		b,$FD				; A S D F G
					in		a,(c)
					rra
					jr		c,.not_a
					ld		hl,DEMO_SPRITES + 1
					inc		(hl)
.not_a:				ld		b,$DF				; P O I U Y
					in		a,(c)
					rra
					jr		c,.not_p
					ld		hl,DEMO_SPRITES + 0
					inc		(hl)
.not_p:				rra
					ret		c
					ld		hl,DEMO_SPRITES + 0
					dec		(hl)
					ret
