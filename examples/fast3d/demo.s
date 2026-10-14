; fast3d's demo: a flight through a world of objects. Forty cubes and
; icosahedra, each turning, are scattered round a circle the camera flies,
; turning gently of its own accord; O and P turn it more, Q and A pitch it.
; Each frame, every object is culled or drawn: what is out of view is left
; out before a vertex of it is touched (engine/objects.s), and what is in
; view is drawn through a window, its edges clipped to the window's frame.
;
; A 128K program: each frame is drawn on the screen not being shown, then
; shown at the next interrupt, so nothing ever flickers. Only the box drawn
; on that screen last time is cleared first. The next frame's arithmetic is
; done while the last waits for that interrupt.
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

; The picture's arithmetic first, while the last one waits to be shown: by
; the time it is done, the interrupt has shown the last one, and the screen
; it was on is free to draw on. Waiting for the flip right after drawing
; lost what was left of that frame, half of one a picture on average.
frame:
					call	compute_frame
					call	wait_flip
					call	render_frame
					ld		a,(screen_high)		; show it at the next interrupt;
					or		a					; draw on the other next
					ld		a,$0F
					ld		c,$00
					jr		nz,.show
					ld		a,$07
					ld		c,$80
.show:				ld		(flip_to),a
					ld		a,c
					ld		(screen_high),a
					call	read_keys
					jr		frame

; wait_flip: until the interrupt has shown the picture flip_to asks for.
wait_flip:
					ld		a,(flip_to)
					or		a
					ret		z
					halt
					jr		wait_flip

flip_to:			DB		0					; non-zero: what the next interrupt
													; writes to port $7FFD


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
; draw_frame: compute_frame, then render_frame -- the next picture, whole, on
; the screen screen_high says. The demo's loop calls the two apart, to do
; the one while the last picture waits to be shown; check.py calls this.

draw_frame:
					call	compute_frame
					jp		render_frame


; ---------------------------------------------------------------------------
; compute_frame: fly the camera on and turn the objects, and work out what
; is in view, touching no screen: each object drawn gets its points in the
; pool and an entry in `visible`, and the box round them all is new_box.

; An entry in `visible`, for an object drawn.
VIS_PAGE			EQU		0					; its points' page
VIS_BASE			EQU		1					; and its first vertex there
VIS_INSIDE			EQU		2					; non-zero: wholly in the window
VIS_EDGES			EQU		3					; how many edges, and where
VIS_SIZE			EQU		6

compute_frame:
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

					ld		a,255				; the box round every object
					ld		(.least_x),a		; drawn
					ld		(.least_y),a
					xor		a
					ld		(.most_x),a
					ld		(.most_y),a
					ld		(drawn),a
					ld		hl,visible
					ld		(.entry),hl
					ld		hl,point_pool		; the pool's first page, from 0
					ld		(.slot),hl

					ld		ix,world			; every object: IX walks them,
					ld		a,WORLD_OBJECTS		; and cull_object keeps IX
					ld		(.objects_left),a
.object_loop:		ld		a,(ix + OBJECT_ANGLES)	; turned by its spin
					add		a,(ix + OBJECT_SPIN)
					ld		(ix + OBJECT_ANGLES),a
					ld		a,(ix + OBJECT_ANGLES + 1)
					add		a,(ix + OBJECT_SPIN + 1)
					ld		(ix + OBJECT_ANGLES + 1),a
					ld		a,(ix + OBJECT_ANGLES + 2)
					add		a,(ix + OBJECT_SPIN + 2)
					ld		(ix + OBJECT_ANGLES + 2),a
					call	cull_object
					jr		c,.next_object		; out of view
					ld		(.object),ix		; (object_matrix and
					ld		hl,drawn			; transform_object do not)
					inc		(hl)
					call	object_matrix
					ld		ix,(.object)
					ld		l,(ix + OBJECT_MODEL)
					ld		h,(ix + OBJECT_MODEL + 1)
					ld		(.model),hl
					ld		b,(hl)				; MODEL_VERTICES
					ld		de,(.slot)			; room for them on this page?
					ld		a,e
					add		a,b
					cp		65
					jr		c,.room
					inc		d					; else on the next, from 0
					ld		e,0
					ld		a,b
.room:				ld		(.first),de
					ld		e,a
					ld		(.slot),de			; where the next object's go
					ld		de,(.first)
					call	transform_object
					ld		hl,(.model)			; into the box
					ld		b,(hl)
					ld		hl,(.first)
					call	.object_box
					ld		hl,(.model)			; and the entry
					inc		hl
					inc		hl
					inc		hl					; MODEL_EDGES
					ld		de,(.entry)
					ld		a,(.first + 1)
					ld		(de),a				; VIS_PAGE
					inc		de
					ld		a,(.first)
					ld		(de),a				; VIS_BASE
					inc		de
					ld		a,(.all_inside)
					ld		(de),a				; VIS_INSIDE
					inc		de
					ldi							; VIS_EDGES: the count, and
					ldi							; where they are
					ldi
					ld		(.entry),de
					ld		ix,(.object)
.next_object:		ld		de,OBJECT_SIZE
					add		ix,de
					ld		hl,.objects_left
					dec		(hl)
					jp		nz,.object_loop

					ld		a,(.most_y)			; the box, held to the window,
					cp		VIEW_BOTTOM + 1		; in rows and columns
					jr		c,.bottom
					ld		a,VIEW_BOTTOM
.bottom:			ld		b,a
					ld		a,(.least_y)
					cp		VIEW_TOP
					jr		nc,.top
					ld		a,VIEW_TOP
.top:				ld		c,a
					ld		a,b
					sub		c
					jr		c,.no_box			; nothing drawn in the window
					inc		a
					ld		b,a					; rows
					ld		a,(.most_x)
					cp		VIEW_RIGHT + 1
					jr		c,.right
					ld		a,VIEW_RIGHT
.right:				ld		e,a
					ld		a,(.least_x)
					cp		VIEW_LEFT
					jr		nc,.left
					ld		a,VIEW_LEFT
.left:				cp		e
					jr		z,.across
					jr		nc,.no_box
.across:			rrca
					rrca
					rrca
					and		31
					ld		d,a					; first column
					ld		a,e
					rrca
					rrca
					rrca
					and		31
					sub		d
					inc		a
					ld		e,a					; columns
					ld		hl,new_box
					ld		(hl),b
					inc		hl
					ld		(hl),c
					inc		hl
					ld		(hl),d
					inc		hl
					ld		(hl),e
					ret
.no_box:			xor		a
					ld		(new_box),a
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

; The box round the B points transform_object just made from HL (L the
; first vertex, H the page), those in front of the eye, into the picture's
; box: a box round an object's vertices holds
; every line between them, and so every piece of one clipped to the window.
; Each x and y is held to 0..255 first, which keeps their order, so the
; least and most of them are the least and most of the whole, held; the end
; holds those to the window, once a picture, rather than every line end
; being measured. And .all_inside non-zero if the whole object is in the
; window -- every vertex in front of the eye and the box inside -- so that
; none of its edges needs clipping. Uses A, BC, DE, HL, IX.
.object_box:		ld		c,255				; C, D = the least x, the most
					ld		d,0
					ld		e,c					; E, IXL = the least y, the most
					ld		ixl,d
					ld		ixh,d				; IXH non-zero: one is behind
.vertex:			set		6,l
					ld		a,(hl)				; POINTS_X_HI
					res		6,l
					cp		high WIDE_BEHIND
					jr		z,.behind
					or		a
					jr		nz,.x_far
					ld		a,(hl)				; POINTS_X_LO
.x_held:			cp		c
					jr		nc,.not_least_x
					ld		c,a
.not_least_x:		cp		d
					jr		c,.not_most_x
					ld		d,a
.not_most_x:		set		7,l
					set		6,l
					ld		a,(hl)				; POINTS_Y_HI
					res		6,l
					or		a
					jr		nz,.y_far
					ld		a,(hl)				; POINTS_Y_LO
.y_held:			cp		e
					jr		nc,.not_least_y
					ld		e,a
.not_least_y:		cp		ixl
					jr		c,.not_most_y
					ld		ixl,a
.not_most_y:		res		7,l
.next_vertex:		inc		l
					djnz	.vertex

					xor		a					; all of it in the window?
					ld		(.all_inside),a
					or		ixh
					jr		nz,.merge
					ld		a,c
					cp		VIEW_LEFT
					jr		c,.merge
					ld		a,VIEW_RIGHT
					cp		d
					jr		c,.merge
					ld		a,e
					cp		VIEW_TOP
					jr		c,.merge
					ld		a,VIEW_BOTTOM
					cp		ixl
					jr		c,.merge
					ld		(.all_inside),a
.merge:				ld		hl,.least_x			; and into the screen's box
					ld		a,c
					cp		(hl)
					jr		nc,.not_least_x2
					ld		(hl),a
.not_least_x2:		inc		hl					; .least_y
					ld		a,e
					cp		(hl)
					jr		nc,.not_least_y2
					ld		(hl),a
.not_least_y2:		inc		hl					; .most_x
					ld		a,d
					cp		(hl)
					jr		c,.not_most_x2
					ld		(hl),a
.not_most_x2:		inc		hl					; .most_y
					ld		a,ixl
					cp		(hl)
					ret		c
					ld		(hl),a
					ret
.behind:			ld		ixh,1
					jr		.next_vertex
; Off the screen's 256: 0 if negative, 255 if not.
.x_far:				add		a,a
					sbc		a,a
					cpl
					jr		.x_held
.y_far:				add		a,a
					sbc		a,a
					cpl
					jr		.y_held

.object:			DW		0					; the one being drawn
.objects_left:		DB		0
.model:				DW		0
.entry:				DW		0					; -> the next entry in visible
.slot:				DW		0					; where the next points go: the
													; vertex, then the page
.first:				DW		0					; and where this object's went
.least_x:			DB		0
.least_y:			DB		0
.most_x:			DB		0
.most_y:			DB		0
.all_inside:		DB		0					; this object needs no clipping
drawn:				DB		0					; objects drawn this frame
new_box:			DB		0, 0, 0, 0			; rows (0: none), top, column, columns


; ---------------------------------------------------------------------------
; render_frame: on the screen screen_high says, clear what was drawn there
; last time, and draw what compute_frame worked out.

; L = a vertex's number, H = the points' page: its x and y into TO_X and
; TO_X + 2, as clip_line takes them, or on to SKIP_TO if it is at or behind
; the eye. Keeps B and C. A macro, not a call: twice an edge, a hundred
; edges a picture.
					MACRO	END_AT	TO_X, SKIP_TO
					set		6,l
					ld		a,(hl)				; POINTS_X_HI
					cp		high WIDE_BEHIND
					jr		z,SKIP_TO
					ld		d,a
					res		6,l
					ld		e,(hl)				; POINTS_X_LO
					ld		(TO_X),de
					set		7,l
					ld		e,(hl)				; POINTS_Y_LO
					set		6,l
					ld		d,(hl)				; POINTS_Y_HI
					ld		(TO_X + 2),de
					ENDM

render_frame:
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
.cleared:			call	box_of_screen		; and this picture's, for next
					ex		de,hl				; time
					ld		hl,new_box
					ldi
					ldi
					ldi
					ldi
					ld		a,(drawn)
					or		a
					ret		z
					ld		hl,visible
.object:			ld		(.objects_left),a
					ld		a,(hl)				; VIS_PAGE and VIS_BASE, into
					ld		(.page1 + 1),a		; the code below
					ld		(.page2 + 1),a
					inc		hl
					ld		a,(hl)
					ld		(.base1 + 1),a
					ld		(.base2 + 1),a
					ld		(.base3 + 1),a
					ld		(.base4 + 1),a
					inc		hl
					ld		c,(hl)				; VIS_INSIDE
					inc		hl
					ld		a,(hl)				; VIS_EDGES
					inc		hl
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					inc		hl
					ld		(.entry),hl
					ld		(.edge_at),de
					inc		c
					dec		c
					jr		nz,.inside_edge

; An object reaching outside the window, or behind the eye: each edge clipped.
.edge:				ld		(.edges_left),a
					ld		hl,(.edge_at)
					ld		a,(hl)				; its ends
					inc		hl
.base1:				add		a,0
					ld		b,a
					ld		a,(hl)
					inc		hl
					ld		(.edge_at),hl
.base2:				add		a,0
					ld		c,a
.page1:				ld		h,0
					ld		l,b
					END_AT	clip_x0, render_frame.next_edge	; neither behind the eye
					ld		l,c
					END_AT	clip_x1, render_frame.next_edge
					call	clip_line
					jr		c,.next_edge		; none of it in the window
					call	draw_line
.next_edge:			ld		a,(.edges_left)
					dec		a
					jr		nz,.edge
					jr		.next_object

; An object wholly in the window: each edge's ends, their low bytes, straight
; to draw_line, as clip_line would have passed them.
.inside_edge:		ld		(.edges_left),a
					ld		hl,(.edge_at)
					ld		a,(hl)				; its ends
					inc		hl
					ld		e,(hl)
					inc		hl
					ld		(.edge_at),hl
.base3:				add		a,0
					ld		c,a
					ld		a,e
.base4:				add		a,0
					ld		l,a
.page2:				ld		h,0
					ld		d,(hl)				; POINTS_X_LO
					set		7,l
					ld		e,(hl)				; POINTS_Y_LO
					ld		l,c
					ld		b,(hl)
					set		7,l
					ld		c,(hl)
					call	draw_line
					ld		a,(.edges_left)
					dec		a
					jr		nz,.inside_edge
.next_object:		ld		hl,(.entry)
					ld		a,(.objects_left)
					dec		a
					jp		nz,.object
					ret

.objects_left:		DB		0
.entry:				DW		0
.edges_left:		DB		0
.edge_at:			DW		0

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

; Each object drawn: its points, from transform_object, in the four tables
; of 64 on one of these pages (POINT_PAGES, from build.py, is enough for
; every object at once), and its entry.
					ALIGN	256
point_pool:			DS		256 * POINT_PAGES
visible:			DS		VIS_SIZE * WORLD_OBJECTS

; The interrupt: the screen flip_to asks for, if it asks.
					ORG		IM2_ROUTINE
interrupt:			push	af
					ld		a,(flip_to)
					or		a
					jr		z,.done
					push	bc
					ld		bc,$7FFD
					out		(c),a
					pop		bc
					xor		a
					ld		(flip_to),a
.done:				pop		af
					ei
					ret
end:
					ASSERT	end <= IM2_TABLE
					SAVEDEV	"output/demo.banks", 0, 0, $20000
					SAVEBIN	"output/demo.bin", $4000, $8000
