; Head of the depth-sorted list. Empty until start: inserts everything --
; draw order is derived from U/V/Z, never authored. See depth_cmp below.
object_list			DW		0

; Where the SORTED part of the list begins. Everything before it is
; background scenery: drawn first, so always behind, and never compared
; or moved. Like PREV, this is not a pointer to an object -- it is the
; address of the NEXT field that names the first sorted object, which is
; the last background object itself, or object_list when there is no
; background at all.
;
; objects_draw_all does not know about any of this: it walks the one
; chain from object_list and the background simply comes out first.
; Head Over Heels does the same thing with a separate "far" list that
; DrawCore blits before the sorted one.
sort_head			DW		object_list


					STRUCT 	OBJ
NEXT:				DS		2
MIN_Y:				DS		1	; byte position
MAX_Y:				DS		1	; byte position
MIN_X:				DS		1
MAX_X:				DS		1
FLAGS:				DS		1	; bit 7 - object is movable
BLIT_IDX:			DS		1	; blit_index
SPRITE_L:			DS		1	; sprite data address: the sprite's own bitmap for an unshifted
							; object, or this object's BUF_L/BUF_H when it was shifted
SPRITE_H:			DS		1

BUF_L:				DS		1	; shift buffer, for a MOVABLE object only -- see
BUF_H:				DS		1	; the object_record macro below

U:					DS		1
V:					DS		1
Z:					DS		1

; PREV does NOT point at the previous object. It points at the NEXT
; FIELD that points at us -- which is that object's own address, since
; NEXT is at offset 0, or object_list itself when we are the head. That
; is what lets depth_unlink and depth_insert skip the "am I the head?"
; branch. Never dereference it as a record.
PREV:				DS		2

; The solid box, half-open: [U, U+SIZE_U) and so on. This is the world
; footprint, not the sprite box -- a sprite w bytes wide sits on a base
; diamond SIZE_U + SIZE_V pixels across and half that in rows.
SIZE_U:				DS		1
SIZE_V:				DS		1
SIZE_Z:				DS		1

; Knight Lore's per-sprite nudges, straight out of its own object table.
; Its set_pixel_adj ($C72B) gives every sprite a small signed offset that
; lines the artwork up with the logical point, and without them a room
; reproduced from its data sits up to 20 pixels out.
;
; ADJ_X is added to the screen x; ADJ_Y is SUBTRACTED from the base row,
; because their pixel Y counts up from the bottom and ours counts down.
ADJ_X:				DS		1
ADJ_Y:				DS		1

; The Knight Lore graphic number this object is drawn from. object_update
; takes it in A and does not keep it, but room building needs it after the
; fact to look the pixel adjustments up, and animation will need it to step
; from one frame to the next.
GFX:				DS		1
					ENDS


; An object is drawn at a sub-byte X offset by rotating its sprite into a
; buffer first, and the rotated copy has to survive until that object is
; blitted -- which is after EVERY object has been updated. So the buffer
; cannot be shared: with one between them, the last object to shift would
; overwrite what the others had prepared and they would all draw its
; bitmap. Each movable object carries its own instead.
;
; An object that is only ever drawn byte-aligned never reaches that path,
; so it needs no buffer at all and passes 0.

OBJ_MOVABLE			EQU		0x80		; FLAGS bit 7

; FLAGS bit 5: SPRITE_L/H points at this object's own rotated copy rather
; than at the shared graphic. Set by shift_sprite, cleared on the byte-
; aligned path. redraw_orient skips these -- the copy is private, it was
; rotated from the orientation the object wanted, and SPRITE - 2 is not a
; sprite header at all but whatever happens to precede the buffer.
OBJ_SHIFTED			EQU		0x20

; FLAGS bit 0: the orientation this object wants, in the same bit position
; as SPRITE_FLIPPED in the sprite's own header, so the comparison between
; the two is a plain XOR.
OBJ_FLIP_H			EQU		SPRITE_FLIPPED

; One object record. The list owns NEXT and PREV -- they start zero and
; depth_insert fills them in. `shift_buf` is the object's own rotation
; buffer, or 0 when it is never drawn at a sub-byte X offset.
					MACRO	object_record flags, shift_buf, size_u, size_v, size_z
					DW		0		; NEXT
					DS		OBJ.FLAGS - 2		; MIN_Y, MAX_Y, MIN_X, MAX_X
					DB		flags		; FLAGS
					DS		OBJ.BUF_L - OBJ.FLAGS - 1		; BLIT_IDX, SPRITE_L, SPRITE_H
					DW		shift_buf		; BUF_L, BUF_H
					DS		OBJ.PREV - OBJ.U		; U, V, Z
					DW		0		; PREV
					DB		size_u, size_v, size_z
					ENDM	


					; position in B,C
					; object in IX
					; sprite in A
; Isometric world coordinates -> screen, after Knight Lore's
; calc_pixel_XY at $D6C9 (disassembly by tcdev; SkoolKit conversion by
; Michael R. Cook). U and V are the two floor axes, Z is height,
; increasing upwards.
;
;     screenX = U + V - WORLD_X_ORIGIN
;     baseY   = WORLD_Y_ORIGIN - ((V - U + 128) >> 1) - Z
;
; The halving of (V - U) is the 2:1 isometric lozenge: a step along one
; floor axis moves a whole pixel across and half a pixel down. The +128
; before the shift is a bias so that a negative (V - U) survives the
; logical SRL, exactly as Knight Lore does it.
;
; Knight Lore renders into a linear buffer that update_screen ($D56F)
; copies to the display upside down, so its pixel Y counts UP from the
; bottom and lands on the sprite's base. We draw straight into screen
; layout, so the row is flipped back here -- which is why Z is
; subtracted rather than added.
;
; The two origins are Knight Lore's $80 and $68 in spirit: they say
; where the world's origin lands on screen, and are ours to choose.
; These put a floor (Z = 0) across the lower half with U, V in 0..120.
WORLD_X_ORIGIN		EQU		128
WORLD_Y_ORIGIN		EQU		40		; 296 mod 256 -- the origin Knight Lore itself uses

; Screen position of an object, from the U, V and Z in its record.
;   IX -> the object
; Returns C = screen x (pixels), B = screen y of the sprite's base.
; Corrupts A and the flags; everything else is left alone.
calc_screen_xy:		ld		a,(ix+OBJ.U)
					add		a,(ix+OBJ.V)
					sub		WORLD_X_ORIGIN
					add		a,(ix+OBJ.ADJ_X)
					ld		c,a		; screen x

					ld		a,(ix+OBJ.V)
					sub		(ix+OBJ.U)
					add		a,128		; bias, so the SRL below is safe
					srl		a		; (V - U) / 2 + 64
					add		a,(ix+OBJ.Z)
					neg				; up on screen is -Y, so negate...
					add		a,WORLD_Y_ORIGIN		; ...and hang it off the origin
					sub		(ix+OBJ.ADJ_Y)		; their pixel Y is bottom-up, ours is not
					ld		b,a		; screen y of the base
					ret		


; Place an object from its world coordinates and update it.
;   IX -> the object, with U, V and Z set
;   A  = sprite index
object_place:		push	af
					call	calc_screen_xy
					pop		af
					jr		object_update


object_update:
					; A is a Knight Lore graphic number, and sprite_table has an
					; entry for all 256 of them -- 512 bytes, so it cannot be reached
					; by putting the doubled index in L. Hold the base pre-halved
					; instead and double the pair: the index doubles with it, and its
					; carry lands in the high byte where it belongs. Needs ALIGN 512,
					; same as the view buffer's row address.
					ld		l,a
					ld		h,(high sprite_table) / 2
					add		hl,hl		; hl = sprite_table + graphic * 2
					ld		a,(hl)
					inc		l		; the low byte is even, so this cannot wrap
					ld		h,(hl)
					ld		l,a

					; sprite in HL

					; Mirror the graphic now if this object wants the other way
					; round. It has to happen here, before the width is read and
					; before shift_sprite rotates: a rotated copy is private to one
					; object and nothing looks at it again, so it must be taken from
					; the orientation that object asked for. An unshifted object gets
					; checked again at draw time, in redraw_orient, because some
					; other object may mirror the shared bytes in the meantime.
					;
					; BC is the screen position and is wanted below; DE is not live
					; yet, so sprite_flip_h is free to use it.
					ld		a,(hl)
					xor		(ix+OBJ.FLAGS)
					and		SPRITE_FLIPPED
					jr		z,.oriented
					push	bc
					push	hl
					call	sprite_flip_h
					pop		hl
					pop		bc
.oriented:

					; x extent
					ld		a,c
					and		7
					ex      af,af'  ; offset in A'

					ld		a,c
					and		0xF8    ; x with low 3 bits cleared (byte-aligned)
					rra
					rra
					rra
					ld		(ix+OBJ.MIN_X),a
					; MAX_X is EXCLUSIVE -- the first byte column past the object, so
					; MAX_X - MIN_X is its width in bytes. That is what
					; extent_intersect needs: it takes the overlap as the smaller of
					; the sprite width and the distance to the view edge, and an
					; overlap wider than the sprite indexes past the last
					; sprite_blit_N_of_M entry for that width and into the jump
					; table's padding, which then executes as code.
					;
					; (hl) is the BLIT INDEX, (width-2)*32, not a width in bytes --
					; sprites.py changed that encoding, see the commented-out line
					; beside it. So unpack the width back out rather than adding it
					; raw, which is what the old "adc (hl) / inc a" did.
					ld		a,(hl)		; blit index: (width - 2) * 32
					rlca	
					rlca	
					rlca			; 0/32/64/96 -> 0/1/2/3 in the low bits
					and		7		; width - 2, with room for the wider classes
					add		a,2		; width in bytes
					add		a,(ix+OBJ.MIN_X)
					ld		(ix+OBJ.MAX_X),a		; max_x (byte position, exclusive)

					; blit table index -- masked, because byte 0 also carries the
					; sprite's current orientation and this value is used raw as an
					; index into sprite_jump_table, here and in shift_sprite
					ld		a,(hl)
					and		BLIT_IDX_MASK
					ld		(ix+OBJ.BLIT_IDX),a

					; Y extent. B is the sprite's BASE -- the row just past its bottom --
					; not its top, so that a world Z of 0 means "standing on the floor".
					; MIN_Y is therefore base - height, and MAX_Y is the base itself,
					; which keeps MAX_Y exclusive exactly as MAX_X is.
					inc		l		; hl -> the sprite's height
					ld		a,b
					sub		(hl)
					jr		nc,.on_screen

					; It runs off the top of the screen. Nothing here clips a
					; sprite against row 0: the extents are single bytes, so a
					; negative MIN_Y wraps to something near 255, the region
					; that implies is hundreds of rows tall, and the Y offset
					; into the view buffer overflows the one carry the row
					; address can take -- which puts the blit outside the
					; buffer altogether. Give it an empty extent instead, so
					; every cull drops it, and leave it undrawn until there is
					; something here that can clip properly.
					xor		a
					ld		(ix+OBJ.MIN_Y),a
					ld		(ix+OBJ.MAX_Y),a
					jr		.y_done

.on_screen:			ld		(ix+OBJ.MIN_Y),a		; top = base - height
					ld		a,b
					ld		(ix+OBJ.MAX_Y),a		; base (exclusive)
.y_done:
                    
					; rotate sprite in HL to buffer in DE
                    ex      af,af'                  ; A - shift amount / Z set, A' - height
					jr		z,.no_shift		; already byte-aligned: nothing to rotate
					; This object needs rotating. Has it somewhere to rotate into?
					ld		b,(ix+OBJ.BUF_H)		; B is free here; A still holds the
					inc		b		; shift amount, which .shift_sprite
					dec		b		; needs, so test without touching it
					jp		nz,.shift_sprite

					; No. Take one from the room's arena, sized for this sprite.
					; Which objects need a buffer is a property of where the room
					; puts them -- a static placed in world coordinates lands on an
					; arbitrary pixel -- so it is settled here, the first time one
					; turns out to be off the byte grid, rather than declared with
					; the record. An animated object wants its buffer sized for its
					; largest frame instead: allocate that one up front and this
					; will find it already there.
					push	af		; the shift amount, which shift_alloc clobbers
					dec		l		; hl -> the sprite record; ALIGN 4 makes this safe
					call	shift_alloc
					inc		l
					pop		af

					; A null buffer here means the arena is full. Nothing can be
					; rotated into a null pointer -- it would read the blit back out
					; of ROM -- so draw it byte-aligned instead: up to 7 pixels left
					; of true, which MIN_X/MAX_X already describe exactly.
					ld		b,(ix+OBJ.BUF_H)
					inc		b
					dec		b
					jp		nz,.shift_sprite
.no_shift:

					; store sprite mask/data address: sprite's own bitmap, BLIT_IDX
					; already matches its raw width (no +1 - no shift overflow column)
					inc		l
                    ld		(ix+OBJ.SPRITE_L),l
					ld		(ix+OBJ.SPRITE_H),h
					res		5,(ix+OBJ.FLAGS)		; drawn from the shared graphic, so
					ret		; redraw_orient must keep an eye on it

.shift_sprite:
                    ; A - shift amount, A' - height
                    ; C - BLIT_INX

                    ex      af,af'      ; stash shift amount before it's overwritten below
                    ld      a,(hl)      ; get height
                    exx
                    ld      b,a         ; B - height
                    ld 		(.restore_sp+1),sp	; save the real SP, before it gets repurposed below

					; get address of byte shifting routine
					ld		h,high sprite_jump_table
					ld		a,(ix+OBJ.BLIT_IDX)
					add		a,30
					ld		l,a
					ld		sp,hl
					pop		iy

                    exx
                    inc     l                       ; HL was sprite_record+1 (height); skip past it to mask/data
					ld		e,(ix+OBJ.BUF_L)		; this object's own buffer, in the bank
					ld		d,(ix+OBJ.BUF_H)		; .loop's writes use
                    ex      af,af'
                    
					; get sprite mask and data in stack pointer
					ld		sp,hl

					; ix - object
					; de - buffer
					; a - shift amount
					
				    ; get address of shift table
                    add     a,a
					add		a,high SPRITE_ROTATE_BASE		; the -1 is folded into the base
					ld		h,a

					; set left and right masks
					ld		l,255
					ld		a,(hl)
					ld		(.mask_right + 1),a
					cpl
					ld		(.mask_left + 1),a

                    exx


.loop:				exx
					pop		bc					; pop mask+data ; c - mask; b - data

                    ld      l,c
                    ld      a,(hl)              ; A = mask left1
.mask_left:         or      0
                    ld      (de),a
                    inc     de                   ; next byte
					ld		l,b					
					ld		a,(hl)				; A = data left1
					ld		(de),a		
					inc		de                   ; next byte

					jp		(iy)

            REPT 4
					inc		h					; HL = right
                    ld      l,c
                    ld      a,(hl)              ; A = mask right1
                    ex      af,af'
                    ld      l,b
					ld		a,(hl)				; A = data right1
                    ex      af,af'
					pop		bc					; pop mask+data ; c - mask; b - data
                    dec     h                   ; HL = left
                    ld      l,c
                    or      (hl)                ; A =  mask right1 | left2
                    ld      (de),a
                    inc     de
                    ex      af,af'                   
                    ld      l,b
                    or      (hl)                ; A = data right1 | left2
                    ld      (de),a
                    inc     de
            ENDR

.shift_final:
					inc		h					; HL = right
                    ld      l,c
                    ld      a,(hl)              ; A = mask right1
.mask_right:		or      0
                    ld      (de),a
                    inc     de
                    ld      l,b
					ld		a,(hl)				; A = data right1
                    ld      (de),a
                    inc     de
                    dec     h                   ; HL = left
					
					exx
					djnz	.loop

					ld		a,(ix+OBJ.BUF_L)
					ld		(ix+OBJ.SPRITE_L),a
					ld		a,(ix+OBJ.BUF_H)
					ld		(ix+OBJ.SPRITE_H),a
					set		5,(ix+OBJ.FLAGS)		; this copy is private and already
					; the right way round: redraw_orient
					; leaves it alone
					ld		a,(ix+OBJ.BLIT_IDX)
					add		a,32				; the rotated copy has one extra overflow column vs the sprite's own bitmap - bump to the next width-class
					ld		(ix+OBJ.BLIT_IDX),a
					inc		(ix+OBJ.MAX_X)		; ...and one column wider, so widen the extent

.restore_sp:		ld		sp,0				; restore SP, value set before loop

					ret

                    ret





;; Calculate parameters to do with overlapping extents
;; Parameters:
;;  BC holds extent of sprite
;;  DE holds current extent
;; Returns:
;;  Sets carry flag if there's any overlap.
;;  H holds the extent adjustment
;;  L holds the sprite adjustment
;;  A holds the overlap size.
;;
;;  E------D
;;  |      |
;; C--B    |
;; |  |    |
;; +--+    |
;;  |      |
;;  +------+
				MACRO extent_intersect 
					ld		a,d
					sub		c
					ld      l,a     		; l = d - c
					ld      a,c
					sub     e       		; a = c - e
					jr      c,.less
					;; C >= E case
					ld      h,a     		; h = c - e
					ld      a,b
					sub     c       		; a = c - b
					ld      b,l     		; c = d - c
					ld      l,$00   		; l = 0
					jr		.compare
					;; C < E case
.less:          	ld      l,a     		; l = b - d
					ld      a,b
					sub     e
					ld      b,a     		; c = c - d
					ld      a,d
					sub     e       		; a = e - d
					ld      h,$00   		; h = 0
.compare:       	cp      b
					jr		c,.end
					ld      a,b
.end:
				ENDM


view_x_extent:		dw		0
view_y_extent:		dw		0


objects_draw_all:				
					ld		hl,(view_x_extent)			
					ld		(.set_x_extent + 1),hl
					ld		hl,(view_y_extent)			
					ld		(.set_y_extent + 1),hl

					; 'return' address in IX
					ld		ix,.next_object

					; Save stack pointer as we going to use stack pointer to read object data					
					ld		(.set_stack + 1),sp
					
					; Walk though objects filtering out those outside the view extent
					ld		iy,(object_list)					
					jr		.next_object		; the same test also covers an empty list
.filter_loop:		ld		sp,iy
					pop		iy					; get next object

.set_y_extent:		ld		de,0				; de = view y extent
					pop		bc					; bc = object y excent
					ld		a,c					; a = obj_min_y
					cp		d					; obj_min_y - view_max_y
					jr		nc,.next_object		; if obj_min_y - view_max_y >= 0, return					
					ld		a,e					; a = view_min_y
					cp		b					; view min_y - obj_max_y
					jr		nc,.next_object   	; if view_min_y - obj_max_y >= 0, return
					exx
.set_x_extent:		ld		de,0				; de = view x extent
					pop		bc					; bc = object x excent
					ld		a,c					; a = obj_min_x
					cp		d					; obj_min_x - view_max_x
					jr		nc,.next_object		; if obj_min_x - view_max_x >= 0, return					
					ld		a,e					; a = view_min_x
					cp		b					; view min_x - obj_max_x
					jr		nc,.next_object   	; if view_min_x - obj_max_x >= 0, return

					; Calculate x overlap, DE = view_x_extent, BC = object x extent
					extent_intersect			; HL, BC, DE, AF all changed

					; Exchange registers
					exx
					ex		af,af'

					; Calculate y overlap, DE = view_y_extent, BC = object y extent
					extent_intersect

					; A'/A - x/y overlap
					; H'/H - x/y extent adjustment
					; L'/L - x/y sprite adjustment

					; Save y overlap, will be used for line count in blit function
					exx	
					ld		b,a
					exx

					; Calculate address in view_buffer using X & Y extent adjustment.
					;
					; The buffer is VIEW_BUF_ROWS rows of VIEW_BUF_WIDTH, and at a
					; stride of 8 the row offset is three doublings rather than a
					; multiply. It also runs to 512 bytes, so the top bit of the row
					; offset belongs in D: hold D pre-halved, let the third doubling
					; drop its carry out, and RL D shifts the base back up with that
					; carry underneath it. Works only because ALIGN 512 makes
					; `high view_buffer` even.
					;
					; The X extent that follows cannot carry: the row offset is a
					; multiple of 8 and so at most 248, and the X extent is at most
					; VIEW_BUF_WIDTH - 1, which is 7.
					ld      a,h					; Y extent, 0..VIEW_BUF_ROWS-1
					add     a					; *2
					add     a					; *4
					exx							; switch to X adjustments
					ld		d,(high view_buffer) / 2
					add     a					; *8, and the carry is the row's top bit
					rl		d					; ...which is the buffer's second page
					add     h					; X extent
					ld		e,a					; DE is view_buffer + adjustment
					exx							; switch to Y adjustments

					; A' - x overlap
					; H'/H - x/y extent adjustment
					; L'/L - x/y sprite adjustment
					; DE' - view buffer address + adjustment
					; B' - blit line count

					; Adjust sprite data address
					pop		de					; get index into jump table in D (E not used)
					xor		a					; A = 0
					sub		l					; A = -sprite_y_adjustment
					ld		h,high sprite_jump_table
					ld		l,d
					jp		(hl)				; jump to Y adjustment multiply routine
.x_adjust:			exx							; switch to X adjustments                    
					sub		l					; A += sprite_x_adjustment
					add		a					; Double for interleaved mask and data
					pop		hl					; Get sprite address					

					; That doubling is the one step here that can leave eight
					; bits. A holds rows-skipped * columns + the x adjustment,
					; and doubling it for the mask/data pair takes a 52-row
					; arch leaf clipped 49 rows into a region past 255: 198
					; doubles to 396, which wraps to 140 and reads row 17 of
					; the sprite instead of row 49. It drew as a few stray
					; pixels at the foot of both rear arches, because that is
					; the only place a sprite this tall is clipped this deeply.
					;
					; POP does not touch the flags, so the carry is still the
					; one ADD A left.
					jr		nc,.low_half
					inc		h
.low_half:			add		l					; A = L + adjustment 
					ld		l,a					; L = A
 					adc		h 	  	 			; A = A+L+H+carry
    				sub		l       			; A = H+carry
    				ld		h, a    			; H = H+carry
					exx							
					
					; A' - x overlap
					; HL' - sprite address + adjustment
					; DE' - view buffer address + adjustment
					; B' - blit line count

					; Calculate index into blit jump table
					ex		af,af'				; Get x overlap (number of bytes in each row to blit)
					inc		a					; 1 + (x_overlap)
					add		a					; 2 + (x_overlap * 2)
					add		a					; 4 + (x_overlap * 4)
					add		d					; A = 4 + (x_overlap * 4) + blit_table_index; D/BLIT_IDX matches however many columns/row SPRITE_L/H actually has (shift_sprite bumps it by one width-class when it shifts, to account for the overflow column)

					; HL' - sprite address + adjustment
					; DE' - view buffer address + adjustment
					; B' - blit line count

					; Jump to width specific blit routine
					ld		l,a
					jp		(hl)

					; Return here after blit routine
.next_object:		ld		a,iyh
					and		a
					jp		nz,.filter_loop		; loop back if not
.set_stack			ld		sp,000				; restore stack pointer
					ret





; --- depth sorting --------------------------------------------------
;
; Draw order is a property of U, V and Z, held as a permanent invariant
; of the list. Nothing ever sorts: when an object moves it is unlinked
; and re-inserted in one pass, and an object that has not moved costs
; nothing at all. That is Head Over Heels' design. Knight Lore instead
; re-derives the whole order every frame by repeatedly scanning for an
; object nothing occludes and restarting -- O(n^2) at best.


; Take an object out of the list.
;   IX -> the object
; Corrupts A, BC, DE, HL.
depth_unlink:		ld		l,(ix+OBJ.PREV)
					ld		h,(ix+OBJ.PREV+1)		; hl -> the NEXT field aimed at us
					ld		c,(ix+OBJ.NEXT)
					ld		b,(ix+OBJ.NEXT+1)		; bc = whoever follows us
					ld		(hl),c
					inc		hl
					ld		(hl),b		; *prev = next
					dec		hl
					ld		a,b
					and		a
					ret		z		; we were last: nothing behind to fix
					ex		de,hl		; de -> the field we just wrote
					ld		hl,OBJ.PREV
					add		hl,bc
					ld		(hl),e
					inc		hl
					ld		(hl),d		; next->PREV = that field
					ret		


; Compare the object being placed -- whose bounds depth_cmp_setup has
; hoisted into the immediates below -- against the candidate in IY.
;
; On any axis where the two boxes do NOT overlap, that axis's coordinate
; is part of the key; where they DO overlap the axis says nothing and
; contributes nothing. Summed, that is exactly Head Over Heels' seven-
; case dispatch table -- their key is always the sum over the non-
; overlapping axes -- with no dispatch at all. Three axes overlapping is
; interpenetration and gives the empty sum, which is the right
; degenerate answer for free.
;
; The SIGNS are ours, not theirs. calc_screen_xy sends +U down the screen
; and +V up it, so the projection's null direction -- which for an
; orthographic projection IS the depth axis -- is (1,-1,1), and depth is
; U - V + Z. Head Over Heels' U + V + Z comes from a projection where
; both floor axes descend. Change calc_screen_xy and this must follow.
;
; Out: cf = 1  the placed object is FURTHER than the candidate
;      a  = 0  exactly one axis separates them, so that is certain;
;              any other value and the ordering is only a guess
; Corrupts A, BC, DE, HL. IX, IY and the shadow set are untouched.
depth_cmp:			ld		hl,0		; running difference, signed
					ld		b,l		; separating axes so far

					; U -- nearer as U grows
					ld		a,(iy+OBJ.U)
					ld		c,a		; c = their min
					add		a,(iy+OBJ.SIZE_U)		; a = their max
.u_min:				cp		0		; imm = our min + 1
					jr		c,.u_sep		; their max <= our min
					ld		a,c
.u_max:				cp		0		; imm = our max
					jr		c,.u_over		; their min < our max: they overlap
.u_sep:				inc		b
.u_ours:			ld		a,0		; imm = our U
					sub		c
					ld		e,a
					sbc		a,a		; sign-extend the borrow
					ld		d,a
					add		hl,de
.u_over:			

					; V -- FURTHER as V grows, so the operands swap and the term negates
					ld		a,(iy+OBJ.V)
					ld		c,a
					add		a,(iy+OBJ.SIZE_V)
.v_min:				cp		0
					jr		c,.v_sep
					ld		a,c
.v_max:				cp		0
					jr		c,.v_over
.v_sep:				inc		b
					ld		a,c		; a = their V
.v_ours:			sub		0		; imm = our V, so theirV - ourV
					ld		e,a
					sbc		a,a
					ld		d,a
					add		hl,de
.v_over:			

					; Z -- nearer as Z grows, the same shape as U
					ld		a,(iy+OBJ.Z)
					ld		c,a
					add		a,(iy+OBJ.SIZE_Z)
.z_min:				cp		0
					jr		c,.z_sep
					ld		a,c
.z_max:				cp		0
					jr		c,.z_over
.z_sep:				inc		b
.z_ours:			ld		a,0
					sub		c
					ld		e,a
					sbc		a,a
					ld		d,a
					add		hl,de
.z_over:			

					ld		a,b
					dec		a		; zero when exactly one axis separates
					sla		h		; cf = sign of the difference; a survives
					ret		


; Hoist the placed object's bounds into depth_cmp's immediates. Nine
; stores once per insert, against six (ix+d) reads per candidate if they
; stayed in the record -- it pays for itself after about three of them.
;   IX -> the object
depth_cmp_setup:	ld		a,(ix+OBJ.U)
					ld		(depth_cmp.u_ours+1),a
					inc		a
					ld		(depth_cmp.u_min+1),a
					ld		a,(ix+OBJ.U)
					add		a,(ix+OBJ.SIZE_U)
					ld		(depth_cmp.u_max+1),a

					ld		a,(ix+OBJ.V)
					ld		(depth_cmp.v_ours+1),a
					inc		a
					ld		(depth_cmp.v_min+1),a
					ld		a,(ix+OBJ.V)
					add		a,(ix+OBJ.SIZE_V)
					ld		(depth_cmp.v_max+1),a

					ld		a,(ix+OBJ.Z)
					ld		(depth_cmp.z_ours+1),a
					inc		a
					ld		(depth_cmp.z_min+1),a
					ld		a,(ix+OBJ.Z)
					add		a,(ix+OBJ.SIZE_Z)
					ld		(depth_cmp.z_max+1),a
					ret		


insert_at:			DW		0		; the NEXT field we will write

; Put an object into the list in depth order. It must not already be in
; the list -- NEXT and PREV are written, not read.
;   IX -> the object
; Corrupts A, BC, DE, HL, IY.
;
; The insertion point LAGS the scan cursor: an ordering we are only
; guessing at moves the cursor on but is not trusted enough to commit to.
; Isometric depth is genuinely non-transitive -- A in front of B in front
; of C in front of A is constructible -- so there is no total order to
; sort by, and this is why the scan needs the authoritative flag to know
; when it may stop.
depth_insert:		call	depth_cmp_setup
					; NB: depth_insert_placed assumes depth_cmp_setup has already run for
					; this object -- depth_relink calls it once and then uses both.
depth_insert_placed:	ld		hl,(sort_head)
					ld		(insert_at),hl		; default: the front of the SORTED run
					ld		a,(hl)
					inc		hl
					ld		h,(hl)
					ld		l,a
					push	hl
					pop		iy		; the first sorted object, or none
.scan:				ld		a,iyh
					and		a
					jr		z,.link		; ran off the end: commit
					call	depth_cmp
					jr		c,.further
					ld		(insert_at),iy		; we are nearer: we go after this one
.advance:			ld		e,(iy+OBJ.NEXT)
					ld		d,(iy+OBJ.NEXT+1)
					push	de
					pop		iy
					jr		.scan
.further:			and		a
					jr		nz,.advance		; only a guess: keep looking

.link:				ld		hl,(insert_at)	; hl -> the NEXT field naming us
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					dec		hl		; de = whoever follows us
					ld		(ix+OBJ.NEXT),e
					ld		(ix+OBJ.NEXT+1),d
					ld		(ix+OBJ.PREV),l
					ld		(ix+OBJ.PREV+1),h
					push	ix
					pop		bc		; bc = our own address
					ld		(hl),c
					inc		hl
					ld		(hl),b		; *insert_at = us
					ld		a,d
					and		a
					ret		z		; nothing follows us
					ld		hl,OBJ.PREV
					add		hl,de
					ld		(hl),c
					inc		hl
					ld		(hl),b		; follower->PREV = us
					ret		


; Move an object that may have changed position back into depth order.
;   IX -> the object, with extent_save's snapshot still holding where it
;        was
;
; An object that has not actually moved costs the three compares below
; and nothing else -- which is the whole point of the design. The gate is
; on the WORLD coordinates, not the screen extents: the null direction is
; (1,-1,1), so U+1, V-1, Z+1 changes depth with no screen movement at all.
; Is the object still correctly placed relative to the two objects it
; sits between? The list is furthest-first, so it is: not further than
; its predecessor, and not nearer than its successor.
;   IX -> the object, still linked, with its bounds already hoisted into
;         depth_cmp's immediates
; Out: cf = 1  still in the right place, leave it alone
;      cf = 0  it has crossed a neighbour and must be re-inserted
; Corrupts A, BC, DE, HL, IY.
depth_in_order:		ld		l,(ix+OBJ.PREV)
					ld		h,(ix+OBJ.PREV+1)
					ld		de,(sort_head)		; the front of the sorted run
					ld		a,l
					cp		e
					jr		nz,.have_prev
					ld		a,h
					cp		d
					jr		z,.check_next		; nothing sorted ahead of us
.have_prev:			push	hl
					pop		iy		; PREV is the predecessor itself here
					call	depth_cmp
					jr		c,.out_of_order		; further than it: we must move back

.check_next:		ld		l,(ix+OBJ.NEXT)
					ld		h,(ix+OBJ.NEXT+1)
					ld		a,h
					and		a
					jr		z,.in_order		; we are the tail: no successor
					push	hl
					pop		iy
					call	depth_cmp
					jr		nc,.out_of_order		; nearer than it: we must move on
.in_order:			scf		
					ret		
.out_of_order:		and		a		; clear carry
					ret		
; Put an object into the background run: drawn before everything else and
; never sorted, so it is permanently behind. Splices in at sort_head --
; the same splice depth_insert uses -- and then moves sort_head past us,
; so the sorted run now starts after this object.
;   IX -> the object, not currently in any list
; Corrupts A, BC, DE, HL.
background_insert:	ld		hl,(sort_head)
					ld		(insert_at),hl
					call	depth_insert_placed.link
					push	ix
					pop		hl
					ld		(sort_head),hl		; our NEXT field is the new boundary
					ret		




; Move an object that may have changed position back into depth order.
;   IX -> the object, with extent_save's snapshot still holding where it
;        was
;
; Two gates, because the expensive part is the scan. An object that has
; not moved at all costs three compares. One that has moved but has not
; crossed either of its neighbours costs two depth_cmp calls instead of a
; scan down the whole list -- and that is the common case: an object
; creeping a unit per frame changes its place in the order only every
; several frames.
;
; The world coordinates are what the first gate tests, not the screen
; extents: the projection's null direction is (1,-1,1), so U+1, V-1, Z+1
; changes an object's depth with no screen movement at all.
depth_relink:		ld		hl,prev_u
					ld		a,(ix+OBJ.U)
					cp		(hl)
					jr		nz,.moved
					inc		hl
					ld		a,(ix+OBJ.V)
					cp		(hl)
					jr		nz,.moved
					inc		hl
					ld		a,(ix+OBJ.Z)
					cp		(hl)
					ret		z		; stayed put: nothing to do

.moved:				call	depth_cmp_setup
					call	depth_in_order
					ret		c		; moved, but not past anyone
					call	depth_unlink
					jp		depth_insert_placed		; the setup above still stands