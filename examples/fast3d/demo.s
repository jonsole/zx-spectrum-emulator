; fast3d's demo: a wireframe cube or icosahedron, turning about all three
; axes and swinging in towards the eye and out again, drawn by the routines
; in fast3d.s through a window: whatever of it is beyond the window's frame
; is clipped away. SPACE changes the object.
;
; A 128K program: each frame is drawn on the screen not being shown, then
; shown at the next interrupt, so nothing ever flickers. Only the box the
; object took on that screen last time is cleared first.
;
;   bank 2, $8000   this and fast3d
;   bank 5, $4000   the first screen
;   bank 7, $C000   the second, paged in all the time
					DEVICE	ZXSPECTRUM128

IM2_TABLE			EQU		$BE00				; 257 bytes of $BD: wherever the
IM2_ROUTINE			EQU		$BDBD				; bus leaves the vector, $BDBD
ATTRIBUTES			EQU		%01000111			; bright white on black
NEAREST				EQU		110					; the eye from the object's centre,
FARTHEST			EQU		400					; at its closest and farthest
WINDOW_LEFT			EQU		24					; the window lines are clipped to
WINDOW_TOP			EQU		16
WINDOW_RIGHT		EQU		231
WINDOW_BOTTOM		EQU		175

					ORG		$8000

start:
					di
					ld		sp,$8000
					ld		hl,IM2_TABLE
					ld		de,IM2_TABLE + 1
					ld		bc,256
					ld		(hl),high IM2_ROUTINE
					ldir
					ld		a,high IM2_TABLE
					ld		i,a
					im		2
					ld		a,$07				; bank 7 at $C000, bank 5 shown
					ld		bc,$7FFD
					out		(c),a
					xor		a
					out		($FE),a				; a black border
					ld		hl,$4000
					call	clear_screen
					ld		hl,$C000
					call	clear_screen
					ld		hl,FARTHEST * 128
					ld		(zoff),hl
					ld		b,WINDOW_LEFT
					ld		c,WINDOW_TOP
					ld		d,WINDOW_RIGHT
					ld		e,WINDOW_BOTTOM
					call	set_window
					xor		a					; the window's frame, on both
					call	draw_frame_lines	; screens
					ld		a,$80
					call	draw_frame_lines
					ld		(screen_high),a		; draw on bank 7 first
					ei

frame:
					call	draw_frame
					halt
					ld		a,(screen_high)		; show what was drawn; draw on
					or		a					; the other next
					ld		a,$0F
					ld		c,$00
					jr		nz,.show
					ld		a,$07
					ld		c,$80
.show:				ld		b,$7F				; port $7FFD
					out		(c),a
					ld		a,c
					ld		(screen_high),a
					call	read_space
					jr		frame


; ---------------------------------------------------------------------------
; draw_frame: turn the object on, and draw it on the screen screen_high says,
; clearing what it drew there last time.

draw_frame:
					ld		hl,angle_x			; turn a little about each axis
					inc		(hl)
					inc		hl
					inc		(hl)
					inc		(hl)
					inc		hl
					inc		(hl)
					call	make_matrix

					ld		hl,(zoff)			; and swing in or out: 2 units a
					ld		de,(.swing)			; frame, turning at the ends
					add		hl,de
					ld		(zoff),hl
					ld		de,NEAREST * 128
					or		a
					sbc		hl,de
					jr		z,.turn
					ld		hl,(zoff)
					ld		de,FARTHEST * 128
					or		a
					sbc		hl,de
					jr		nz,.swung
.turn:				ld		hl,(.swing)
					call	negate_hl
					ld		(.swing),hl
.swung:
					ld		ix,(object)			; the vertices to the screen,
					ld		l,(ix + 0)			; on it or off it
					ld		h,(ix + 1)
					ld		b,(ix + 2)
					ld		de,points
					call	transform_wide

					call	box_of_screen		; clear the last box here
					ld		a,(hl)
					or		a
					jr		z,.cleared
					ld		b,a
					inc		hl
					ld		c,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		e,(hl)
					call	clear_box
.cleared:
					ld		a,255				; this screen's box, for next
					ld		(.least_x),a		; time: round every end drawn
					ld		(.least_y),a
					xor		a
					ld		(.most_x),a
					ld		(.most_y),a

					ld		ix,(object)			; the edges, clipped
					ld		l,(ix + 3)
					ld		h,(ix + 4)
					ld		a,(ix + 5)
.edge:				ld		(.edges_left),a
					ld		a,(hl)				; the first end
					inc		hl
					ld		de,clip_x0
					call	.end
					jr		c,.skip_second
					ld		a,(hl)				; the second
					inc		hl
					ld		de,clip_x1
					call	.end
					jr		c,.next
					ld		(.edge_at),hl
					call	clip_line
					jr		c,.drawn			; none of it in the window
					ld		hl,.least_x			; round its ends
					ld		a,b
					call	.least
					ld		a,d
					call	.least
					inc		hl
					ld		a,c
					call	.least
					ld		a,e
					call	.least
					call	draw_line
.drawn:				ld		hl,(.edge_at)
					jr		.next
.skip_second:		inc		hl
.next:				ld		a,(.edges_left)
					dec		a
					jr		nz,.edge

					ld		a,(.least_y)		; the box, in rows and columns
					cp		255
					jr		z,.no_box			; nothing drawn
					ld		c,a
					ld		a,(.most_y)
					sub		c
					inc		a
					ld		b,a					; rows
					ld		a,(.least_x)
					rrca
					rrca
					rrca
					and		31
					ld		d,a					; first column
					ld		a,(.most_x)
					rrca
					rrca
					rrca
					and		31
					sub		d
					inc		a
					ld		e,a					; columns
					push	bc
					push	de
					call	box_of_screen
					pop		de
					pop		bc
					ld		(hl),b
					inc		hl
					ld		(hl),c
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(hl),e
					ret
.no_box:			call	box_of_screen
					ld		(hl),0
					ret

; Point A's x and y into (DE), (DE+2), as clip_line takes them: carry set
; if the point is at or behind the eye. Keeps HL.
.end:				push	hl
					ld		l,a
					ld		h,0
					add		hl,hl
					add		hl,hl
					ld		bc,points
					add		hl,bc
					ld		a,(hl)
					ld		(de),a
					inc		hl
					inc		de
					ld		a,(hl)
					ld		(de),a
					inc		hl
					inc		de
					cp		high WIDE_BEHIND
					jr		nz,.in_front
					dec		hl
					dec		hl
					ld		a,(hl)
					inc		hl
					inc		hl
					or		a
					jr		nz,.in_front
					pop		hl
					scf
					ret
.in_front:			ldi
					ldi
					pop		hl
					and		a
					ret

; (HL) = the least of it and A, (HL+2) the most.
.least:				cp		(hl)
					jr		nc,.not_least
					ld		(hl),a
.not_least:			inc		hl
					inc		hl
					cp		(hl)
					jr		c,.not_most
					ld		(hl),a
.not_most:			dec		hl
					dec		hl
					ret

.swing:				DW		-256				; 2 units a frame, inwards first
.edges_left:		DB		0
.edge_at:			DW		0
.least_x:			DB		0
.least_y:			DB		0
.most_x:			DB		0
.most_y:			DB		0

; draw_frame_lines: the window's frame, a pixel outside it, on the screen A
; says ($00 or $80, as screen_high). Keeps A.
draw_frame_lines:
					push	af
					ld		(screen_high),a
					ld		hl,frame_lines
					ld		b,4
.line:				push	bc
					ld		b,(hl)
					inc		hl
					ld		c,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		e,(hl)
					inc		hl
					push	hl
					call	draw_line
					pop		hl
					pop		bc
					djnz	.line
					pop		af
					ret

frame_lines:		DB		WINDOW_LEFT - 1, WINDOW_TOP - 1, WINDOW_RIGHT + 1, WINDOW_TOP - 1
					DB		WINDOW_RIGHT + 1, WINDOW_TOP - 1, WINDOW_RIGHT + 1, WINDOW_BOTTOM + 1
					DB		WINDOW_RIGHT + 1, WINDOW_BOTTOM + 1, WINDOW_LEFT - 1, WINDOW_BOTTOM + 1
					DB		WINDOW_LEFT - 1, WINDOW_BOTTOM + 1, WINDOW_LEFT - 1, WINDOW_TOP - 1

; HL -> the box (rows, top, left column, columns) for the screen screen_high
; says. Uses A.
box_of_screen:
					ld		hl,boxes
					ld		a,(screen_high)
					or		a
					ret		z
					ld		hl,boxes + 4
					ret

boxes:				DB		0, 0, 0, 0			; the screen at $4000
					DB		0, 0, 0, 0			; at $C000


; ---------------------------------------------------------------------------
; read_space: SPACE, newly down, changes the object.

read_space:
					ld		a,$7F
					in		a,($FE)
					cpl
					and		1					; 1: SPACE is down
					ld		hl,.was
					ld		c,(hl)
					ld		(hl),a
					cp		c
					ret		z
					or		a
					ret		z					; it has come up
					ld		hl,(object)
					ld		de,OBJECT_SIZE
					add		hl,de
					ld		de,objects_end
					or		a
					sbc		hl,de
					add		hl,de
					jr		nz,.set
					ld		hl,objects
.set:				ld		(object),hl
					ret
.was:				DB		0

; clear_screen: the screen at HL blank, its attributes ATTRIBUTES.
clear_screen:
					ld		d,h
					ld		e,l
					inc		de
					ld		(hl),0
					ld		bc,6143
					ldir
					inc		hl
					inc		de
					ld		(hl),ATTRIBUTES
					ld		bc,767
					ldir
					ret

; Each object: its vertices and how many, its edges and how many.
OBJECT_SIZE			EQU		6
objects:			DW		cube_vertices
					DB		CUBE_VERTICES
					DW		cube_edges
					DB		CUBE_EDGES
					DW		icosahedron_vertices
					DB		ICOSAHEDRON_VERTICES
					DW		icosahedron_edges
					DB		ICOSAHEDRON_EDGES
objects_end:
object:				DW		objects

					INCLUDE	"output/objects_gen.s"
					INCLUDE	"fast3d.s"

					ALIGN	256
points:				DS		4 * 128				; x, y (16-bit) for each vertex

					ORG		IM2_ROUTINE
					ei
					ret
end:
					SAVEDEV	"output/demo.banks", 0, 0, $20000
					SAVEBIN	"output/demo.bin", $4000, $8000
