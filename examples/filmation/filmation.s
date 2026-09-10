					DEVICE ZXSPECTRUM48


					ORG	0x8000

; The view buffer is a window, not a screen: everything that intersects the
; area a moved object disturbed is composited here, then copied out in one
; go. Its shape is therefore the hard limit on how big a single object can
; be, and both dimensions have to clear the whole sprite set:
;
;   widest sprite   5 bytes, and a sprite that is not byte-aligned spans one
;                   column more than its own width -- so 6 columns
;   tallest sprite  64 rows (the castle door arch; the forest one is 52)
;
; 8 x 64 = 512 bytes covers both with the stride a power of two, which is
; what makes the row address a shift rather than a multiply. Six would be
; tight enough to work and no cheaper: 6 x 64 is 384, still over a page, so
; the second page has to be handled either way, and the multiply-by-6 costs
; more than the multiply-by-8 saves. The padding from the sprite's width out
; to the stride is what the extra two columns actually cost -- see the row
; advance in sprite_blit.
VIEW_BUF_WIDTH		EQU		8

; The buffer spans two pages, so the blit cannot address it with `ld d,high
; view_buffer` plus `inc e` throughout. Rows are 8 bytes on an 8-byte
; boundary, so no row straddles the page break and only the increments that
; can land on a row boundary have to carry into D -- which is the last one
; of each row, plus the row advance itself. Everything inside a row stays
; `inc e`. Knight Lore has no limit of this kind at all, because its buffer
; IS the screen; ours is a small window, and this is what that costs.
VIEW_BUF_ROWS		EQU		512 / VIEW_BUF_WIDTH

; The stack, in UNCONTENDED memory. sjasmplus's SAVESNA leaves SP at 0x5D56,
; which is inside the ULA-contended 0x4000-0x7FFF window, so on real hardware
; every call and return there pays a contention delay -- a few hundred
; T-states a frame for nothing. Everything else this engine touches already
; lives above 0x8000: the sprite data, the rotate table, the view buffer, the
; object records and the code. The stack was the one thing left behind.
;
; It grows down from here into the space above the program, which ends around
; 0xE080 -- getting on for 8K of headroom, against the handful of frames deep
; this ever nests.
STACK_TOP			EQU		0xFF00

; ---------------------------------------------------------------------------
; Room $B3 of Knight Lore, reproduced from the game's own object table.
;
; The coordinates, the bounding boxes and the per-sprite adjustments were read
; straight out of a running Knight Lore at $5C08, and the graphic numbers were
; matched to our sprite indices by comparing bitmaps. calc_screen_xy is already
; their projection, so with WORLD_X_ORIGIN = 128 and WORLD_Y_ORIGIN = 40 their
; coordinates drop in unchanged and land on the same pixels:
;
;     screenX = U + V - 128 + adjX
;     base    = 296 - ((V - U + 128) >> 1) - Z - adjY
;
; Verified against three of their objects before any of this was written.
;
; The player (their slots 0 and 1) is left out -- this is the room, not the
; game. Their slots 2 and 3 are empty.

ROOM_OBJECTS		EQU		19

; sprite, U, V, Z, adjX, adjY, flip
room_data:			
					DB		 71, 141, 196, 128, 239, 254, 1	; arch (mirrored)
					DB		 72, 115, 196, 128, 249, 254, 1	; arch (mirrored)
					DB		 71, 196, 115, 128, 249, 253, 0	; arch
					DB		 72, 196, 141, 128, 247, 253, 0	; arch
					DB		 71, 141,  59, 128, 239, 254, 1	; arch (mirrored)
					DB		 72, 115,  59, 128, 249, 254, 1	; arch (mirrored)
					DB		 69,  63, 184, 128, 248, 252, 0	; wall
					DB		 70,  71, 192, 128, 248, 252, 0	; wall
					DB		 73,  63,  73, 128, 248, 252, 0	; wall
					DB		 73, 184, 192, 128, 248, 252, 1	; wall (mirrored)
					DB		 73,  63,  73, 172, 248, 252, 0	; wall
					DB		 73, 184, 192, 172, 248, 252, 1	; wall (mirrored)
					DB		 76,  92, 192, 128, 236, 255, 1	; block (mirrored)
					DB		 77,  63,  92, 152, 244, 254, 0	; block
					DB		 78,  63, 160, 152, 248, 252, 0	; block
					DB		 77, 164, 192, 152, 244, 254, 1	; block (mirrored)
					DB		 76,  63, 109, 177, 236, 255, 0	; block
					DB		 78,  96, 192, 160, 248, 252, 1	; block (mirrored)
					DB		 76, 144, 192, 176, 236, 255, 1	; block (mirrored)


					INCLUDE "sprite.s"
					INCLUDE "object.s"
					INCLUDE "shift.s"

					STRUCT SPRITE
WIDTH:				DS		1
HEIGHT:				DS		1
					ENDS
					
	

; Aligned to its own size, so that a row start is a multiple of the stride in
; both pages and `high view_buffer` is even -- the row address folds its top
; bit into D with a single `rl d`, which only works on an even base.
					ALIGN	512
view_buffer:		DS		VIEW_BUF_ROWS * VIEW_BUF_WIDTH


;sprite_shift_buffer:
;					DS	6*64*2




; One record per object in the room. The loader fills them in from room_data.
room_records:		
				REPT	ROOM_OBJECTS
					ALIGN	32
					object_record	0,		0,				0, 0, 0
				ENDR

; The stride between records, which the ALIGN above fixes.
ROOM_STRIDE			EQU		32


; Interrupts stay off for good. Every part of the drawing path repurposes
; SP as a data pointer -- object_update walks sprite data with it,
; objects_draw_all reads object records with it, the blitters read their
; sprites with it, and redraw_view clears the view buffer by pushing
; through it. An interrupt taken during any of those would push a return
; address into whatever SP was aimed at.
start:				di		
					ld		sp,STACK_TOP		; off the contended stack, first thing

					; attributes: bright yellow on black, as Knight Lore has them
					ld		hl,22528
					ld		de,22529
					ld		bc,767
					ld		(hl),64 + 6
					ldir	

					; Place every object in the room from room_data, then insert them all
					; into the depth-sorted list, then paint each one once. Placement has to
					; finish before any insertion, so that every comparison sees real
					; coordinates.
					ld		hl,room_data
					ld		ix,room_records
					ld		b,ROOM_OBJECTS
.place_room:		push	bc
					push	hl
					ld		a,(hl)		; sprite
					inc		hl
					ex		af,af'
					ld		a,(hl)
					ld		(ix+OBJ.U),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.V),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.Z),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.ADJ_X),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.ADJ_Y),a
					; the flip byte is read in stage two; for now everything is unflipped
					ex		af,af'
					call	object_place
					pop		hl
					ld		de,7
					add		hl,de		; next room_data entry
					ld		de,ROOM_STRIDE
					add		ix,de		; next record
					pop		bc
					djnz	.place_room

					; into the sorted list
					ld		ix,room_records
					ld		b,ROOM_OBJECTS
.insert_room:		push	bc
					push	ix
					call	depth_insert
					pop		ix
					ld		de,ROOM_STRIDE
					add		ix,de
					pop		bc
					djnz	.insert_room

					; and paint it
					ld		ix,room_records
					ld		b,ROOM_OBJECTS
.draw_room:			push	bc
					push	ix
					call	redraw_object
					pop		ix
					ld		de,ROOM_STRIDE
					add		ix,de
					pop		bc
					djnz	.draw_room

					; Nothing moves yet, so there is nothing to redraw.
.loop:				jr		.loop


; The movers, their MOVER records and the ghost's square path all went with
; the demo scene -- this room is static. The redraw machinery below is still
; live: start: uses redraw_object to paint each object once.



; --- redrawing ------------------------------------------------------
;
; Nothing draws the whole screen. Each moving object repaints only the
; area it disturbed -- the union of where it was and where it now is --
; and objects_draw_all composites every object that intersects that area,
; so whatever the mover passed over is put back in the same pass.
;
; An area is bounded by what the view buffer holds: VIEW_BUF_WIDTH bytes
; across and VIEW_BUF_ROWS rows down, which is 8 x 64. A one-pixel step
; widens an object's extent by at most one byte -- a byte-aligned sprite
; spans w bytes and a shifted one w+1, and the union of two adjacent
; positions is never more than w+1 -- so with the widest sprite at 5 bytes
; the union peaks at 6 columns, and the tallest at 64 rows. Both fit.

region_rows:		DB		0
region_width:		DB		0

prev_min_y:			DB		0
prev_max_y:			DB		0
prev_min_x:			DB		0
prev_max_x:			DB		0

; ...and where it was in the world, which is what depth_relink gates on.
prev_u:				DB		0
prev_v:				DB		0
prev_z:				DB		0

; The copy routine for each region width, 1 to VIEW_BUF_WIDTH. These read a
; plain buffer -- one composited byte per column, which is what view_buffer
; holds. vid_buff_blit_5 is the odd one out and is not in here: it reads an
; interleaved mask/data source, which nothing in this engine copies to the
; screen.
copy_routines:		DW		vid_buff_copy_1, vid_buff_copy_2, vid_buff_copy_3
					DW		vid_buff_copy_4, vid_buff_copy_5, vid_buff_copy_6
					DW		vid_buff_copy_7, vid_buff_copy_8


; Remember an object's extent, before it moves.
;   IX -> the object
extent_save:		ld		a,(ix+OBJ.MIN_Y)
					ld		(prev_min_y),a
					ld		a,(ix+OBJ.MAX_Y)
					ld		(prev_max_y),a
					ld		a,(ix+OBJ.MIN_X)
					ld		(prev_min_x),a
					ld		a,(ix+OBJ.MAX_X)
					ld		(prev_max_x),a
					ld		a,(ix+OBJ.U)
					ld		(prev_u),a
					ld		a,(ix+OBJ.V)
					ld		(prev_v),a
					ld		a,(ix+OBJ.Z)
					ld		(prev_z),a
					ret		


; Repaint the area a just-moved object affected: the union of the extent
; extent_save recorded and the one it has now. The old half erases its
; previous image, the new half draws it where it is.
;   IX -> the object, already moved
redraw_moved:		ld		hl,prev_min_y
					ld		a,(ix+OBJ.MIN_Y)
					cp		(hl)
					jr		c,.min_y		; keep whichever is smaller
					ld		a,(hl)
.min_y:				ld		(view_y_extent),a

					ld		hl,prev_max_y
					ld		a,(ix+OBJ.MAX_Y)
					cp		(hl)
					jr		nc,.max_y		; keep whichever is larger
					ld		a,(hl)
.max_y:				ld		(view_y_extent+1),a

					ld		hl,prev_min_x
					ld		a,(ix+OBJ.MIN_X)
					cp		(hl)
					jr		c,.min_x
					ld		a,(hl)
.min_x:				ld		(view_x_extent),a

					ld		hl,prev_max_x
					ld		a,(ix+OBJ.MAX_X)
					cp		(hl)
					jr		nc,.max_x
					ld		a,(hl)
.max_x:				ld		(view_x_extent+1),a
					jr		redraw_view


; Repaint one object's own area, with no previous position to take in --
; what the opening screen is built from.
;   IX -> the object
redraw_object:		ld		a,(ix+OBJ.MIN_Y)
					ld		(view_y_extent),a
					ld		a,(ix+OBJ.MAX_Y)
					ld		(view_y_extent+1),a
					ld		a,(ix+OBJ.MIN_X)
					ld		(view_x_extent),a
					ld		a,(ix+OBJ.MAX_X)
					ld		(view_x_extent+1),a


; Clear the view buffer, composite everything that intersects the view
; extent into it, and copy the result to its place on the screen. Both
; extents are (min, max) with max exclusive, so max - min is a size.
; No object in the sprite set is taller than VIEW_BUF_ROWS, so there is no
; height case to handle here: the tallest is the 64-row castle arch and the
; buffer holds exactly 64. That is the whole reason the buffer went to
; 8 x 64 -- a region that does not fit has nowhere to go but wrap.
redraw_view:		ld		hl,(view_y_extent)	; l = min, h = max
					ld		a,h
					sub		l
					ld		(region_rows),a

					ld		hl,(view_x_extent)
					ld		a,h
					sub		l
					cp		VIEW_BUF_WIDTH + 1		; a region wider than the buffer has
					jr		c,.width_ok		; no routine to copy it, so clamp
					ld		a,VIEW_BUF_WIDTH		; rather than index off the end of
.width_ok:			ld		(region_width),a		; copy_routines

					; Clear the rows this region uses, by pushing zeroes down through
					; them. PUSH writes two bytes for 11T against LDIR's 21T per byte,
					; so even blanking the lot this way beats LDIR over one region.
					;
					; It no longer blanks the lot, though. At 512 bytes that would be
					; 2816T every region, twice what the old 256-byte buffer cost, and
					; the rows past the region are never read. `push de` is one byte, so
					; where the run is entered decides how much it clears: rows * 8
					; bytes is rows * 4 pushes, so enter that many pushes from the end.
					; A 30-row region now costs 1320T, under what the flat clear cost.
					ld		(.restore_sp+1),sp		; save the real stack
					ld		a,(region_rows)
					ld		l,a
					ld		h,0
					add		hl,hl
					add		hl,hl		; hl = rows * 4, the pushes needed
					ld		e,l
					ld		d,h
					add		hl,hl		; hl = rows * 8, the bytes they cover
					ld		bc,view_buffer
					add		hl,bc
					ld		sp,hl		; PUSH pre-decrements, so this fills downwards
					ld		hl,.clear_end
					or		a
					sbc		hl,de		; ...from here, so exactly de pushes are left
					ld		de,0		; and this is what every one of them writes
					jp		(hl)
				REPT	VIEW_BUF_ROWS * VIEW_BUF_WIDTH / 2
					push	de
				ENDR
.clear_end:
.restore_sp:		ld		sp,0		; operand set just above

					call	objects_draw_all

					; the copy routine for this width...
					ld		a,(region_width)
					dec		a
					add		a		; (width - 1) * 2
					ld		e,a
					ld		d,0
					ld		hl,copy_routines
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		(.copy + 1),de

					; ...and where on the screen it goes
					ld		a,(view_x_extent)		; min x, in bytes
					add		a
					add		a
					add		a		; -> pixels
					ld		c,a
					ld		a,(view_y_extent)
					ld		b,a
					call	pixelAddress		; hl = screen address; bc kept
					ex		de,hl		; de = destination
					ld		hl,view_buffer
					ld		a,(region_rows)
					ld		b,a		; row counter, for the DJNZ. C is the copy
					; routine's own -- it resets it per row so
					; that LDI's countdown can never borrow
					; into B and lose a row.
.copy:				call	0		; -> vid_buff_copy_N
					ret		






;; Takes a B = Y, C = X 8-pixel coordinate. Real Spectrum screen
;; coords - top left is (0,0).
;;
;; Returns a pointer to corresponding bitmap address in DE.
screen_address: 
					ld 		h,high screen_hi_address_table
					ld 		l,b
					ld		a,(hl)
					inc		h
					ld		h,(hl)
					or		c
					ld		l,a
					ret





; This is the final optimized code. It takes the X coordinate in the C register,
; and the Y coordinate in the B register. The screen address is returned in the HL register pair.
; BC and DE are unchanged, so there is no need for expensive push and pop operations.
pixelAddress:   ld      a, b
                and     %00000111
                ld      h, a    ; h contains Y2-Y0
                ld      a, b
                rra
                scf             ; set bit 14
                rra
                rra
                ld      l, a    ; l contains Y5-Y3
                and     %01011000
                or      h
                ld      h, a    ; h is complete now
                ld      a, c    ; divide X by 8
                rr      l       ; and rotate Y5-Y3 in
                rra
                rr      l
                rra
                rr      l
                rra
                ld      l, a    ; l is complete now
                ret



					INCLUDE "vid_buff.s"



					align	256
screen_hi_address_table:
					REPT	192, y
					DW		high ((y & 0x07) * 256) + ((y & 0x38) * 4) + ((y >> 6) * 2048)
					ENDR
					align	256
screen_lo_address_table:
					REPT	192, y
					DW		low ((y & 0x07) * 256) + ((y & 0x38) * 4) + ((y >> 6) * 2048)
					ENDR


					SAVESNA "output/filmation.sna", start
