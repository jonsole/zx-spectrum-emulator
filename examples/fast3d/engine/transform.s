; fast3d: transform, a list of vertices from the object to the screen:
; rotate, then project, for each.
;
; In: HL -> the vertices, three signed bytes each; DE -> where the points go,
;     two bytes each, x then y; B = how many (1..255).
; A vertex off the screen gets y = $FF. Uses everything but IY and the
; alternate registers.

transform:
					ld		(.vertex),hl
					ld		(.point),de
					ld		a,b
.next:				ld		(.count),a
					ld		hl,(.vertex)
					call	rotate
					ld		hl,(.vertex)
					inc		hl
					inc		hl
					inc		hl
					ld		(.vertex),hl
					call	project
					jr		nc,.store
					ld		c,$FF				; off the screen
.store:				ld		hl,(.point)
					ld		(hl),b
					inc		hl
					ld		(hl),c
					inc		hl
					ld		(.point),hl
					ld		a,(.count)
					dec		a
					jr		nz,.next
					ret

.vertex:			DW		0
.point:				DW		0
.count:				DB		0
