; fast3d's demo: a flight through a world of objects. Forty cubes and
; icosahedra, each turning, are scattered round a circle the camera flies,
; turning gently of its own accord; O and P turn it more, Q and A pitch it.
; Each frame, every object is culled or drawn: what is out of view is left
; out before a vertex of it is touched (engine/objects.s), and what is in
; view is drawn through a window, its edges clipped to the window's frame.
;
; A 128K program: each frame is drawn on the screen not being shown, then
; shown at the next interrupt, so nothing ever flickers. Only the box drawn
; on that screen last time is cleared first.
;
;   bank 2, $8000   this and fast3d
;   bank 5, $4000   the first screen
;   bank 7, $C000   the second, paged in all the time
					DEVICE	ZXSPECTRUM128

IM2_TABLE			EQU		$BE00				; 257 bytes of $BD: wherever the
IM2_ROUTINE			EQU		$BDBD				; bus leaves the vector, $BDBD
ATTRIBUTES			EQU		%01000111			; bright white on black
VIEW_LEFT			EQU		8					; the window lines are clipped to
VIEW_TOP			EQU		8
VIEW_RIGHT			EQU		247
VIEW_BOTTOM			EQU		183

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
					call	demo_setup
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
					call	read_keys
					jr		frame


; demo_setup: the window, and its frame on both screens.
demo_setup:
					ld		b,VIEW_LEFT
					ld		c,VIEW_TOP
					ld		d,VIEW_RIGHT
					ld		e,VIEW_BOTTOM
					call	set_window
					xor		a
					call	draw_frame_lines
					ld		a,$80
					call	draw_frame_lines
					xor		a
					ld		(screen_high),a
					ret


; ---------------------------------------------------------------------------
; draw_frame: fly the camera on and turn the objects, and draw what is in
; view on the screen screen_high says, clearing what was drawn there last
; time.

draw_frame:
					ld		hl,camera_angles + 1	; turning gently, always
					inc		(hl)
					call	set_camera
					ld		hl,camera_x			; and on, a quarter of the
					ld		de,matrix + 2		; forward column
					call	.step
					ld		hl,camera_y
					ld		de,matrix + 5
					call	.step
					ld		hl,camera_z
					ld		de,matrix + 8
					call	.step

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
					ld		(drawn),a

					ld		hl,world			; every object
					ld		(.object),hl
					ld		hl,world_spin
					ld		(.spin),hl
					ld		a,WORLD_OBJECTS
.object_loop:		ld		(.objects_left),a
					ld		ix,(.object)		; turned by its spin
					ld		hl,(.spin)
					ld		a,(ix + OBJECT_ANGLES)
					add		a,(hl)
					ld		(ix + OBJECT_ANGLES),a
					inc		hl
					ld		a,(ix + OBJECT_ANGLES + 1)
					add		a,(hl)
					ld		(ix + OBJECT_ANGLES + 1),a
					inc		hl
					ld		a,(ix + OBJECT_ANGLES + 2)
					add		a,(hl)
					ld		(ix + OBJECT_ANGLES + 2),a
					inc		hl
					ld		(.spin),hl
					call	cull_object
					jr		c,.next_object		; out of view
					ld		hl,drawn
					inc		(hl)
					call	object_matrix
					ld		de,points
					call	transform_object
					ld		ix,(.object)		; its edges, clipped
					ld		l,(ix + OBJECT_MODEL)
					ld		h,(ix + OBJECT_MODEL + 1)
					inc		hl
					inc		hl
					inc		hl					; MODEL_EDGES
					ld		a,(hl)
					inc		hl
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ex		de,hl
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
					jr		c,.next_edge
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
					jr		.next_edge
.skip_second:		inc		hl
.next_edge:			ld		a,(.edges_left)
					dec		a
					jr		nz,.edge
.next_object:		ld		hl,(.object)
					ld		de,OBJECT_SIZE
					add		hl,de
					ld		(.object),hl
					ld		a,(.objects_left)
					dec		a
					jp		nz,.object_loop

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

; (HL) += the signed byte at DE >> 2: a step along the camera's forward
; column. Uses A, BC.
.step:				ld		a,(de)
					sra		a
					sra		a
					ld		c,a
					add		a,a
					sbc		a,a
					ld		b,a
					ld		a,(hl)
					add		a,c
					ld		(hl),a
					inc		hl
					ld		a,(hl)
					adc		a,b
					ld		(hl),a
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

.object:			DW		0
.spin:				DW		0
.objects_left:		DB		0
.edges_left:		DB		0
.edge_at:			DW		0
.least_x:			DB		0
.least_y:			DB		0
.most_x:			DB		0
.most_y:			DB		0
drawn:				DB		0					; objects drawn this frame

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

frame_lines:		DB		VIEW_LEFT - 1, VIEW_TOP - 1, VIEW_RIGHT + 1, VIEW_TOP - 1
					DB		VIEW_RIGHT + 1, VIEW_TOP - 1, VIEW_RIGHT + 1, VIEW_BOTTOM + 1
					DB		VIEW_RIGHT + 1, VIEW_BOTTOM + 1, VIEW_LEFT - 1, VIEW_BOTTOM + 1
					DB		VIEW_LEFT - 1, VIEW_BOTTOM + 1, VIEW_LEFT - 1, VIEW_TOP - 1

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
; read_keys: O and P turn the camera, Q and A pitch it.

read_keys:
					ld		a,$DF				; P (bit 0) and O (bit 1)
					in		a,($FE)
					ld		hl,camera_angles + 1
					bit		0,a
					jr		nz,.not_p
					inc		(hl)
					inc		(hl)
.not_p:				bit		1,a
					jr		nz,.not_o
					dec		(hl)
					dec		(hl)
.not_o:				ld		hl,camera_angles
					ld		a,$FB				; Q
					in		a,($FE)
					bit		0,a
					jr		nz,.not_q
					dec		(hl)
.not_q:				ld		a,$FD				; A
					in		a,($FE)
					bit		0,a
					ret		nz
					inc		(hl)
					ret

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

					INCLUDE	"fast3d.s"
					INCLUDE	"output/objects_gen.s"
					INCLUDE	"output/world_gen.s"

points:				DS		4 * 64				; x, y (16-bit) for each vertex

					ORG		IM2_ROUTINE
					ei
					ret
end:
					SAVEDEV	"output/demo.banks", 0, 0, $20000
					SAVEBIN	"output/demo.bin", $4000, $8000
