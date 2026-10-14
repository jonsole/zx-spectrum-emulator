; fast3d's demo: a wireframe cube or icosahedron, turning about all three
; axes, drawn by the routines in fast3d.s. SPACE changes the object.
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
DISTANCE			EQU		400					; the eye from the object's centre

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
					ld		hl,DISTANCE * 128
					ld		(zoff),hl
					ld		a,$80				; draw on bank 7 first
					ld		(screen_high),a
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

					ld		ix,(object)			; the vertices to the screen
					ld		l,(ix + 0)
					ld		h,(ix + 1)
					ld		b,(ix + 2)
					ld		de,points
					call	transform

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
					ld		ix,(object)			; the edges
					ld		l,(ix + 3)
					ld		h,(ix + 4)
					ld		a,(ix + 5)
.edge:				ld		(.edges_left),a
					ld		a,(hl)				; B, C = the first end
					inc		hl
					add		a,a
					ld		e,a
					ld		d,high points
					ld		a,(de)
					ld		b,a
					inc		e
					ld		a,(de)
					ld		c,a
					ld		a,(hl)				; D, E = the second
					inc		hl
					ld		(.edge_at),hl
					add		a,a
					ld		l,a
					ld		h,high points
					ld		d,(hl)
					inc		l
					ld		e,(hl)
					ld		a,c					; either end off the screen:
					cp		$FF					; leave the edge out
					jr		z,.next
					ld		a,e
					cp		$FF
					call	nz,draw_line
.next:				ld		hl,(.edge_at)
					ld		a,(.edges_left)
					dec		a
					jr		nz,.edge

					; this screen's box, for next time: round the points on it
					ld		ix,(object)
					ld		b,(ix + 2)
					ld		hl,points
					ld		de,$FF00			; D = least x, E = most
					ld		c,$FF				; C = least y
					xor		a					; A' = most y
					ex		af,af'
.extent:			ld		a,(hl)				; x
					inc		l
					ex		af,af'
					ld		ixl,a
					ld		a,(hl)				; y
					inc		l
					cp		$FF
					jr		z,.off
					cp		c
					jr		nc,.not_least_y
					ld		c,a
.not_least_y:		cp		ixl
					jr		c,.not_most_y
					ld		ixl,a
.not_most_y:		ex		af,af'				; A = x
					cp		d
					jr		nc,.not_least_x
					ld		d,a
.not_least_x:		cp		e
					jr		c,.not_most_x
					ld		e,a
.not_most_x:		ex		af,af'
.off:				ld		a,ixl
					ex		af,af'
					djnz	.extent
					ex		af,af'				; A = most y
					sub		c
					ld		b,a					; rows - 1
					ld		a,c
					cp		$FF
					jr		z,.no_box			; nothing on the screen
					inc		b
					srl		d					; columns
					srl		d
					srl		d
					srl		e
					srl		e
					srl		e
					ld		a,e
					sub		d
					inc		a
					ld		e,a
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

.edges_left:		DB		0
.edge_at:			DW		0

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
points:				DS		2 * 256				; x, y for each vertex

					ORG		IM2_ROUTINE
					ei
					ret
end:
					SAVEDEV	"output/demo.banks", 0, 0, $20000
					SAVEBIN	"output/demo.bin", $4000, $8000
