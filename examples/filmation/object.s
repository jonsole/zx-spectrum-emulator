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

; --- and these belong to a character, and to nothing else ------------------
;
; A character is two records that move as one -- legs on the floor, body a
; dozen units above -- and the state that steers them lives in the tail of the
; legs record. A record is OBJ bytes inside a ROOM_STRIDE slot, so this space
; is already there: the room's own objects simply never look at it.
; What Knight Lore calls dX, dY and dZ, at +$09, +$0A and +$0B of its own
; records: what this object would like to do this turn, before anything has
; been allowed to stop it. object_collide cuts them down and whoever asked
; for them applies what is left.
;
; Every object carries them, as in the game, and the room's pool can afford
; it because the seven fields that used to sit here were only ever a
; character's -- facing, walk phase and the graphic bases -- and no piece of
; scenery has a walk cycle. They live past the character's two slots now.
DU:				DS		1		; signed, along U
DV:				DS		1
DZ:				DS		1

ADJ_LIFT:			DS		1

; Pixels of sub-byte X, for an object that rotates at DRAW time rather than at
; placement -- see OBJ_SHARED_SHIFT. Zero for everything else, which is what
; objects_draw_all tests. This is the last byte of a ROOM_STRIDE slot.
SHIFT:				DS		1
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

; FLAGS bit 4: draw this object from a private copy of its graphic rather than
; from the shared bytes. A graphic is shared by everything drawn from it, and
; an object wanting it the other way round mirrors it where it lies, so two
; objects in one room wanting opposite ways mirror it back and forth -- twice a
; region, and ten thousand T a time for something the size of an arch. Room
; $88's two right-hand arch leaves are exactly that pair, and standing in front
; of them cost 85% of a turn.
;
; Which pieces those are is fixed by the room data, not discovered here:
; rooms.py works out the graphics some room wants both ways, nominates one
; orientation of each, and sets this bit on every piece wearing it. Only the
; nominated ones spend a buffer; everything else goes on sharing.
OBJ_CACHE			EQU		0x10

; FLAGS bit 1: SPRITE points at a straight copy of the graphic rather than at a
; rotated one. Both are private bytes and both set OBJ_SHIFTED, but only a copy
; is the same for every object that wants that graphic that way round, so only
; a copy can be shared -- see object_update's twin scan.
OBJ_COPIED			EQU		0x02

; FLAGS bit 2: nothing collides with this. It is the game's own flag, bit 1 of
; a piece's flags byte, and $B538 tests it at the top of every one of Knight
; Lore's collision scans.
;
; Every piece that carries it is the upper half of a two-part object with a
; height of zero -- the wizard's torso over his legs, the pot's lid, a guard's
; head. The lower half holds the box for both of them, which is the same
; arrangement the knight himself has: his legs are W=5 D=5 H=23 and his body
; is H=0.
OBJ_PASSABLE		EQU		0x04

; FLAGS bit 3: rotate this object into the one shared buffer, at the moment it
; is drawn, instead of giving it a buffer of its own out of the room's arena.
;
; The two are a straight trade. A private buffer is rotated once, when the
; object is placed, and a static then costs nothing however often it is
; redrawn -- but it holds its bytes for the life of the room whether it is ever
; redrawn or not. Room $88 rotates ten objects and eight of them are never
; inside a redraw region again, so eight buffers sit idle.
;
; The shared buffer costs no room memory at all and is rotated afresh on every
; draw, at about 47 T a byte of output: 6,100 T for a character's half, 19,500
; for an arch leaf. So it is the right answer for something drawn rarely and
; the wrong one for something a character walks past every turn -- a judgement
; about where a piece sits in its room rather than anything the engine can work
; out for itself. Hence a flag, set from the room data.
OBJ_SHARED_SHIFT	EQU		0x08

; FLAGS bit 6: scenery. Drawn before everything else and never sorted, so it
; is permanently behind -- see background_insert. Walls and trees are solid and
; never walked through, so there is nothing for the sort to decide about them;
; arches and gates are doorways the player does pass behind, and keep their
; place in the order.
;
; Bit 6 is free here. The sprite header uses it for the width class, but every
; comparison against FLAGS masks down to the one bit it wants.
OBJ_BACKGROUND		EQU		0x40

; FLAGS bit 0: the orientation this object wants, in the same bit position
; as SPRITE_FLIPPED in the sprite's own header, so the comparison between
; the two is a plain XOR.
OBJ_FLIP_H			EQU		SPRITE_FLIPPED
OBJ_FLIP_BIT		EQU		0		; ...and its bit number, for SET and RES

SCREEN_ROWS			EQU		192		; the last row an object may be drawn on

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
; ---------------------------------------------------------------------------
; Collision.
;
; A character proposes a step and this cuts it down until it fits. Knight Lore
; does the same thing and the shape is worth keeping: one axis at a time, Z
; first and then U and then V, each settled before the next is looked at, and
; each cut by stepping the delta one unit towards zero and testing again. That
; one loop gives walls, sliding along them, landing on a block and bumping your
; head into its underside, without any of them being written down separately.
;
; Head Over Heels answers the same question a different way -- a move function
; and a collide function per direction, walking the sorted list forwards or
; backwards so that the nearest obstacle is met first -- which is tidier when
; the boxes are four fixed shapes, as its are. Ours are real sizes already,
; because the depth sort needs them, so the clamp is the cheaper fit.

; Which axes had to give, one bit each. The caller reads it to know it has hit
; something -- landing on a floor is the Z bit and a step into a wall is the U
; or V one.
collide_hit:		DB		0
COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4

; The bit object_clamp sets when it has to cut the axis it was given.
collide_mask:		DB		0

; The step as the tests may see it, which is not the whole of what the object
; asked for. Knight Lore carries dX, dY and dZ through its clamp in C, L and H
; and starts with L and C at zero -- LD L,$00 / LD C,L at $CB56 -- loading each
; only when its own axis comes up. So an axis is tested against the world with
; the axes BEFORE it settled and the axes after it standing still.
;
; That is not a detail. Walk into a block and press jump: with the sideways
; step included, the Z test finds the box already inside the block and refuses
; to let it rise. With the sideways step held at zero, as here, the box is
; beside the block and the jump goes up -- and by the time the sideways axes
; are looked at, dZ has settled and they are tested at the new height.
collide_eff_u:		DB		0
collide_eff_v:		DB		0
collide_eff_z:		DB		0


; The list object_clamp is to walk. Knight Lore has one table and walks all
; forty slots; ours are in two places, the room's pool and the characters,
; which are not in it. Every axis has to see both before the next axis is
; looked at, so the scan takes its list rather than knowing one.
clamp_base:			DW		0
clamp_count:		DB		0
clamp_stride:		DB		0

; The character to test against as well as the room, or zero. There are only
; ever two of them and each needs the other, so a single pointer does.
collide_other:		DW		0

; Our own box with the step already in it, worked out once and then read by
; every test in the scan. It was being recomputed from the record and the
; deltas for each object, which is four indexed loads an axis for something
; that only changes when an axis is actually cut.
collide_u_min:		DB		0
collide_u_max:		DB		0
collide_v_min:		DB		0
collide_v_max:		DB		0
collide_z_min:		DB		0
collide_z_max:		DB		0

; SIZE_U and SIZE_V are HALF-extents about U and V, not sizes reaching up from
; them. That is the game's own convention and it is not a guess: Knight Lore
; tests two boxes as abs(Xa - Xb) < Wa + Wb, which only means anything for a
; centre and a half-width, and it makes two blocks on neighbouring cells touch
; exactly -- centres sixteen apart, halves of eight. The artwork agrees. A
; block's sprite is 32 pixels wide and its nudge is -16, and with
; screenX = U + V - 128 the footprint U+-8, V+-8 projects to exactly those 32
; pixels, where a min-and-size box would cover half of them and sit to one
; side.
;
; Z is the odd one out: there the coordinate is the base and SIZE_Z is the
; whole height, which is why an object stands ON the floor at Z = 128 rather
; than straddling it.
;
; depth_cmp reads the fields the same way. It did not always: it took all
; three axes as min-and-size, which put every box half a width too far along
; +U and +V. Nothing showed, because scenery sits on a sixteen grid with
; halves of eight and the two readings agree exactly there -- it is only a
; character, free to stand anywhere and only five each way, that can sit in
; the band where one says touching and the other says clear.

; A character walks into things as one figure, not as the two records it is
; drawn from. Knight Lore says the same thing with its own numbers: the
; knight's legs carry W=5, D=5, H=23 and his body carries H=0, so the whole
; of him is one box hung on the lower half.
COLLIDE_HEIGHT		EQU		23


; Do our box and this object's overlap on all three axes?
;
;   IX -> the character's legs record
;   IY -> the object to test against
;   OBJ.DU/DV/DZ of ours - the step being considered
;
; Carry set if they overlap, clear if any axis separates them. Touching
; exactly counts as apart, which is what lets a character stand on a block
; rather than sink into it.
;
; Corrupts AF, DE. Preserves BC and HL, which object_clamp is using.
					; U first, because it is the axis most likely to settle it:
					; almost everything in a room is somewhere else along the
					; floor, and this way most objects cost one test.
					; Knight Lore writes this test as the distance between the
					; two centres against the sum of the two halves -- $CC9D --
					; and that is exactly what these edge comparisons say. It
					; is kept in this form because it is faster HERE: a centre
					; distance has to compute the sum and then an absolute
					; value before it can decide anything, where an edge
					; comparison throws most objects out on its first compare,
					; and most objects in a room are somewhere else entirely.
					; Measured, the game's own form cost 9% more a turn.
object_overlaps:	ld		a,(iy+OBJ.U)
					ld		d,a		; their centre
					add		a,(iy+OBJ.SIZE_U)		; their max
					ld		e,a
					ld		a,(collide_u_min)
					cp		e
					jr		nc,.apart		; our min >= their max
					ld		a,d
					sub		(iy+OBJ.SIZE_U)		; their min
					ld		d,a
					ld		a,(collide_u_max)
					ld		e,a
					ld		a,d
					cp		e
					jr		nc,.apart		; their min >= our max

					ld		a,(iy+OBJ.V)
					ld		d,a
					add		a,(iy+OBJ.SIZE_V)
					ld		e,a
					ld		a,(collide_v_min)
					cp		e
					jr		nc,.apart
					ld		a,d
					sub		(iy+OBJ.SIZE_V)
					ld		d,a
					ld		a,(collide_v_max)
					ld		e,a
					ld		a,d
					cp		e
					jr		nc,.apart

					; Z is a base and a full height, not a centre and a half,
					; so it keeps the edge comparison.
					;
					; A character is the exception at this end too: its record
					; says twelve because that is the box the depth sort wants,
					; and the figure is the whole COLLIDE_HEIGHT.
					ld		a,(iy+OBJ.Z)
					ld		d,a
					bit		7,(iy+OBJ.FLAGS)		; OBJ_MOVABLE
					jr		z,.their_height
					add		a,COLLIDE_HEIGHT
					jr		.their_top
.their_height:		add		a,(iy+OBJ.SIZE_Z)
.their_top:			ld		e,a
					ld		a,(collide_z_min)
					cp		e
					jr		nc,.apart
					ld		a,(collide_z_max)
					ld		e,a
					ld		a,d
					cp		e
					jr		nc,.apart

					; All three axes overlap. The only thing that can save it
					; now is the object saying nothing collides with it -- and
					; asking here rather than at the top of the loop is what
					; makes it free, because almost nothing gets this far.
					bit		2,(iy+OBJ.FLAGS)		; OBJ_PASSABLE
					jr		nz,.apart
					scf
					ret

.apart:				or		a		; carry clear: nothing in the way
					ret


; Work our box out from the record and the step as it currently stands.
;   IX -> the character's legs record
; Corrupts AF.
collide_box:		ld		a,(collide_eff_u)
					add		a,(ix+OBJ.U)
					ld		c,a		; our centre in U
					sub		(ix+OBJ.SIZE_U)
					ld		(collide_u_min),a
					ld		a,c
					add		a,(ix+OBJ.SIZE_U)
					ld		(collide_u_max),a
					ld		a,(collide_eff_v)
					add		a,(ix+OBJ.V)
					ld		c,a
					sub		(ix+OBJ.SIZE_V)
					ld		(collide_v_min),a
					ld		a,c
					add		a,(ix+OBJ.SIZE_V)
					ld		(collide_v_max),a
					ld		a,(collide_eff_z)
					add		a,(ix+OBJ.Z)		; Z is the base, so no halving
					ld		(collide_z_min),a
					add		a,COLLIDE_HEIGHT
					ld		(collide_z_max),a
					ret


; Cut one axis of the step back until nothing in the room is in the way.
;
;   HL -> the delta to cut, one of this object's DU, DV or DZ
;   IX -> the character's legs record
;   collide_mask - the bit to set in collide_hit if this axis has to give
;
; Every object in the room is tested with the step as it currently stands, so
; the axes have to be done in a fixed order and each sees the ones before it
; already settled. An object that is in the way takes one unit off this axis,
; and is then tested again from the new position -- so a step of eight into a
; wall ends up as however much of it fits, not as nothing.
;
; Corrupts AF, BC, DE, IY. Preserves HL and IX.
object_clamp:		ld		a,(hl)
					or		a
					ret		z		; not moving along this axis

					ld		a,(clamp_count)
					or		a
					ret		z
					ld		b,a
					ld		iy,(clamp_base)
					call	collide_box

.object:			call	object_overlaps
					jr		nc,.next

					; In the way. Give a unit back and look again -- at the
					; same object, because one unit may not be enough.
					ld		a,(hl)
					or		a		; LD does not touch the flags, and the sign
					jp		m,.negative		; of the step is what picks the way back
					dec		a
					jr		.gave
.negative:			inc		a
.gave:				ld		(hl),a
					push	af
					ld		a,(collide_mask)
					ld		c,a
					ld		a,(collide_hit)
					or		c
					ld		(collide_hit),a
					call	collide_box
					pop		af
					or		a
					ret		z		; nothing left to give, and nothing else
					; can take any: the rest of the room
					; cannot make a zero step smaller
					jr		.object

.next:				ld		a,(clamp_stride)
					ld		e,a
					ld		d,0
					add		iy,de
					djnz	.object
					ret


; Cut a whole step down to what fits, Z first and then U and then V.
;
;   IX -> the character's legs record
;   OBJ.DU/DV/DZ - what it would like to do
;
; Leaves them as what it may do, and collide_hit saying which axes gave.
; Corrupts AF, BC, DE, HL, IY.
object_collide:		xor		a
					ld		(collide_hit),a
					ld		(collide_eff_u),a		; nothing is moving yet, as
					ld		(collide_eff_v),a		; far as any test can see
					ld		(collide_eff_z),a

					; Z, then U, then V. Each takes what the object asked for on
					; its own axis, has it cut down against everything, and hands
					; the answer back to the record -- where the axes after it
					; will see it, and the axes before it already have.
					ld		a,COLLIDE_Z
					ld		(collide_mask),a
					ld		a,(ix+OBJ.DZ)
					ld		(collide_eff_z),a
					ld		hl,collide_eff_z
					call	.axis
					ld		a,(collide_eff_z)
					ld		(ix+OBJ.DZ),a

					ld		a,COLLIDE_U
					ld		(collide_mask),a
					ld		a,(ix+OBJ.DU)
					ld		(collide_eff_u),a
					ld		hl,collide_eff_u
					call	.axis
					ld		a,(collide_eff_u)
					ld		(ix+OBJ.DU),a

					ld		a,COLLIDE_V
					ld		(collide_mask),a
					ld		a,(ix+OBJ.DV)
					ld		(collide_eff_v),a
					ld		hl,collide_eff_v
					call	.axis
					ld		a,(collide_eff_v)
					ld		(ix+OBJ.DV),a
					ret


.axis:				push	hl
					ld		hl,room_objects
					ld		(clamp_base),hl
					ld		a,(room_object_count)
					ld		(clamp_count),a
					ld		a,ROOM_STRIDE
					ld		(clamp_stride),a
					pop		hl
					push	hl
					call	object_clamp
					pop		hl

					ld		de,(collide_other)
					ld		a,d
					or		e
					ret		z		; nobody else about
					push	hl
					ld		(clamp_base),de
					ld		a,1
					ld		(clamp_count),a
					pop		hl
					jp		object_clamp


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
					ld		a,(hl)		; blit index: (width - 2) * JUMP_GROUP
					sprite_width_class
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

					; ...and the other end. A room can stand something below
					; the bottom of the screen -- a wall base in a room whose
					; floor sits low -- and nothing downstream notices: the
					; copy walks down from wherever the region starts, so rows
					; past 191 land in the attribute file and then in the
					; system variables, which is a room of coloured squares and
					; then whatever happens next.
					;
					; A base past the last row is clipped to it, which is all
					; the drawing needs: extent_intersect takes the overlap
					; from the extents, so a shortened one simply blits fewer
					; rows. A top past it is an empty extent, the same answer
					; the other end gives.
					cp		SCREEN_ROWS
					jr		nc,.under
					ld		a,b
					cp		SCREEN_ROWS + 1
					jr		c,.base_on_screen
					ld		a,SCREEN_ROWS		; only the top of it shows
.base_on_screen:	ld		(ix+OBJ.MAX_Y),a		; base (exclusive)
					jr		.y_done

.under:				xor		a		; wholly below the screen
					ld		(ix+OBJ.MIN_Y),a
					ld		(ix+OBJ.MAX_Y),a
.y_done:
                    
					; rotate sprite in HL to buffer in DE
                    ex      af,af'                  ; A - shift amount / Z set, A' - height
					ld		(ix+OBJ.SHIFT),0		; LD does not touch the flags, and
					jr		z,.no_shift		; the deferred path sets it again
					; This object needs rotating. Where does it rotate into?
					bit		3,(ix+OBJ.FLAGS)		; OBJ_SHARED_SHIFT: not here, but
					jr		nz,.defer_shift		; at the moment it is drawn
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
					; Sharing the graphic is what we want, unless this is one of
					; the pieces the room data has marked as contested -- see
					; OBJ_CACHE. Those take a private copy, and then nothing in
					; the room ever mirrors anything.
					bit		4,(ix+OBJ.FLAGS)		; OBJ_CACHE
					jp		z,.share

					; One copy a graphic, though, not one an object. A room can
					; hold several pieces wearing the same marked graphic the
					; same way round -- an east arch and a west arch are the
					; same two leaves twice -- and a copy is the same bytes
					; whoever made it. Room $87 marks nine pieces between four
					; graphics: 2,520 bytes of arena copied per piece, 1,398
					; copied per graphic.
					;
					; Only a straight copy can be shared. A marked piece that
					; landed off the byte grid took the rotating path instead,
					; and its bytes are rotated for its own position, which is
					; why the scan wants OBJ_COPIED and not just OBJ_SHIFTED.
					push	hl
					push	iy
					ld		a,(ix+OBJ.FLAGS)
					and		OBJ_FLIP_H
					or		OBJ_COPIED
					ld		e,a		; what a twin's flags must look like
					ld		c,(ix+OBJ.GFX)
					ld		iy,room_objects
					ld		a,(room_object_count)
					ld		b,a
					or		a
					jr		z,.no_twin

.twin:				ld		a,(iy+OBJ.FLAGS)
					and		OBJ_COPIED | OBJ_FLIP_H
					cp		e
					jr		nz,.next_twin
					ld		a,(iy+OBJ.GFX)
					cp		c
					jr		z,.twinned
.next_twin:			push	bc
					ld		bc,ROOM_STRIDE
					add		iy,bc
					pop		bc
					djnz	.twin

.no_twin:			pop		iy
					pop		hl
					ld		a,(ix+OBJ.BUF_H)		; a buffer already, sized for
					or		a		; this object's largest frame?
					jr		nz,.copy
					dec		l		; hl -> the sprite record; ALIGN 4 makes this safe
					call	copy_alloc
					inc		l
					ld		a,(ix+OBJ.BUF_H)
					or		a
					jr		z,.share		; arena full: share, and let them mirror

.copy:				jp		sprite_copy		; stores SPRITE and sets the two flags

.twinned:			ld		a,(iy+OBJ.SPRITE_L)
					ld		(ix+OBJ.SPRITE_L),a
					ld		a,(iy+OBJ.SPRITE_H)
					ld		(ix+OBJ.SPRITE_H),a
					set		5,(ix+OBJ.FLAGS)		; OBJ_SHIFTED: private bytes, so
					set		1,(ix+OBJ.FLAGS)		; sprite_orient leaves them be
					pop		iy
					pop		hl
					ret

					; Rotated at draw time. Nothing is rotated now and no buffer is
					; taken: the object draws from the shared graphic, exactly as an
					; aligned one does, and objects_draw_all rotates it on the way
					; past.
					;
					; The extents and the blit index still describe the ROTATED
					; form, because that is what gets blitted -- one column wider
					; than the artwork. OBJ_SHIFTED stays clear, though, because the
					; bytes really are shared: sprite_orient must go on keeping them
					; the way round this object wants them.
.defer_shift:		ld		(ix+OBJ.SHIFT),a
					inc		l
					ld		(ix+OBJ.SPRITE_L),l
					ld		(ix+OBJ.SPRITE_H),h
					res		5,(ix+OBJ.FLAGS)
					ld		a,(ix+OBJ.BLIT_IDX)
					add		a,JUMP_GROUP
					ld		(ix+OBJ.BLIT_IDX),a
					inc		(ix+OBJ.MAX_X)
					ret

.share:
					; store sprite mask/data address: sprite's own bitmap, BLIT_IDX
					; already matches its raw width (no +1 - no shift overflow column)
					inc		l
                    ld		(ix+OBJ.SPRITE_L),l
					ld		(ix+OBJ.SPRITE_H),h
					res		5,(ix+OBJ.FLAGS)		; drawn from the shared graphic, so
					ret		; sprite_orient must keep an eye on it

					; Rotate into this object's own buffer, once, here at placement.
					; The core takes its destination in DE so that the draw-time
					; path can hand it the shared buffer instead, and everything
					; that is true only of a private copy is settled out here.
.shift_sprite:		ld		e,(ix+OBJ.BUF_L)
					ld		d,(ix+OBJ.BUF_H)
					call	.rotate

					ld		a,(ix+OBJ.BUF_L)
					ld		(ix+OBJ.SPRITE_L),a
					ld		a,(ix+OBJ.BUF_H)
					ld		(ix+OBJ.SPRITE_H),a
					set		5,(ix+OBJ.FLAGS)		; this copy is private and already
					; the right way round: sprite_orient
					; leaves it alone
					ld		a,(ix+OBJ.BLIT_IDX)
					add		a,JUMP_GROUP		; the rotated copy carries one overflow
					ld		(ix+OBJ.BLIT_IDX),a		; column the artwork does not
					inc		(ix+OBJ.MAX_X)		; ...so the extent widens with it
					ret


					; Rotate a sprite. A local label, because the rest of
					; object_update's locals sit below it and a global one here
					; would take them out of its scope -- objects_draw_all calls
					; it as object_update.rotate.
					;   A  - shift amount, 1..7
					;   DE - where the rotated copy goes
					;   HL -> the sprite record's height byte
					;   IX -> the object, for BLIT_IDX -- which must be the
					;         UNROTATED index, as it is at placement
					; Corrupts AF, AF', BC, DE, HL and their shadows, and IY.
					; Restores SP.
.rotate:
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
					add		a,SHIFT_FINAL_AT
					ld		l,a
					ld		sp,hl
					pop		iy

                    exx
                    inc     l                       ; HL was sprite_record+1 (height); skip past it to mask/data
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


; Make the shared graphic the way round this object wants it.
;
; A graphic is shared by every object drawn from it, and an object that wants
; it the other way round mirrors it where it lies. So the bytes may not be the
; way THIS object wants them: another object in the same region may have turned
; them since. Knight Lore compares the two in print_sprite, per object, for
; exactly this reason.
;
; Settling it once per region cannot work, which is what redraw_orient used to
; try. Two objects in one region wanting opposite orientations leave whichever
; the pass reached last holding the graphic, and the other draws mirrored --
; room $88 puts the north arch's leaf and the east arch's leaf, one flipped and
; one not, in the same region at the foot of an arch, and a few pixels of the
; one landed on the other.
;
;   HL -> the object's sprite data (the record + 2)
;   E' -  the object's FLAGS, popped alongside BLIT_IDX
;
; Preserves everything, the flags included, so it can sit in the middle of the
; offset arithmetic.
sprite_orient:		push	af
					push	bc
					push	de
					push	hl
					exx
					ld		a,e					; FLAGS
					exx
					and		OBJ_SHIFTED
					jr		nz,.done			; its own private copy, and SPRITE - 2
					; is not a sprite header at all
					dec		l					; SPRITE is the record + 2, and records
					dec		l					; are ALIGN 4, so this cannot borrow
					exx
					ld		a,e
					exx
					xor		(hl)
					and		SPRITE_FLIPPED
					call	nz,sprite_flip_h	; HL -> the record, which is what it wants
.done:				pop		hl
					pop		de
					pop		bc
					pop		af
					ret


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
					jp		.next_object		; the same test also covers an empty list
					; JP, not JR: the loop below no longer fits in a byte's reach
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

					; Which object this is, for shift_if_deferred. IY is no use for
					; that: the walk read NEXT into it at the top, so it already
					; names the object AFTER this one -- and for the last object in
					; the list that is zero, which indexes into the ROM. SP is ten
					; bytes into the record here, having just read SPRITE out of it.
					ld		(draw_object + 2),sp		; LD IY,nn is a two-byte opcode

					; The sprite address is the last thing the record walk wants, so
					; SP is free -- and putting the real stack back is what lets this
					; call anything at all. sprite_orient leaves every register alone,
					; the carry from the doubling above included.
					ld		sp,(.set_stack + 1)
					call	sprite_orient

					; An OBJ_SHARED_SHIFT object has no rotated copy of its own:
					; it rotates here, into the one shared buffer, and the blit
					; below reads that instead of the artwork. SHIFT is zero for
					; everything else, which is every object in a room that has
					; not been marked, so this is a load and a test.
					;
					; Out of line, and AF saved inside it: the carry out of the
					; doubling above is read three instructions further down, and
					; this is the one thing between them that could disturb it.
					; Out of line because the four filter tests above are JRs and
					; nine more bytes here puts .next_object out of their reach.
					call	shift_if_deferred		; HL -> the shared buffer

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

					; HL' - sprite address + adjustment
					; DE' - view buffer address + adjustment
					; B' - blit line count

					; Set the blitter up for this sprite and go. There is one
					; blitter, and sprite_blit_setup writes into it the two
					; numbers that used to pick between twenty.
					;
					; Out of line only to keep this loop inside a byte's reach:
					; the four filter tests above are JRs, and the setup is
					; longer than what is left of their range.
					ex		af,af'				; x overlap: the columns to composite
					jp		sprite_blit_setup

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
					ld		c,(iy+OBJ.U)		; c = their centre
					ld		a,c
					add		a,(iy+OBJ.SIZE_U)		; a = their max
.u_min:				cp		0		; imm = our min + 1
					jr		c,.u_sep		; their max <= our min
					ld		a,c
					sub		(iy+OBJ.SIZE_U)		; a = their min
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
					ld		c,(iy+OBJ.V)
					ld		a,c
					add		a,(iy+OBJ.SIZE_V)
.v_min:				cp		0
					jr		c,.v_sep
					ld		a,c
					sub		(iy+OBJ.SIZE_V)
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
					sub		(ix+OBJ.SIZE_U)
					inc		a
					ld		(depth_cmp.u_min+1),a
					ld		a,(ix+OBJ.U)
					add		a,(ix+OBJ.SIZE_U)
					ld		(depth_cmp.u_max+1),a

					ld		a,(ix+OBJ.V)
					ld		(depth_cmp.v_ours+1),a
					sub		(ix+OBJ.SIZE_V)
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

; Where a re-insert starts looking, or zero for the front of the sorted run.
; Only the upper half of a two-part object sets it -- see character_move.
relink_from:		DW		0

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
depth_insert_placed:	ld		hl,(sort_head)		; the front of the SORTED run
					; NB: fall through

; ...and the same, starting at the NEXT field HL names instead of at the front.
;   IX -> the object, HL -> where to start looking
depth_insert_from:	ld		(insert_at),hl
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
					jr		c,.out_of_order_back	; further than it: we must move back

.check_next:		ld		l,(ix+OBJ.NEXT)
					ld		h,(ix+OBJ.NEXT+1)
					ld		a,h
					and		a
					jr		z,.in_order		; we are the tail: no successor
					push	hl
					pop		iy
					call	depth_cmp
					jr		nc,.out_of_order_on	; nearer than it: we must move on
.in_order:			scf		
					ret		
					; Which side failed decides where the search can start, so say so.
					; XOR clears the carry as well, which is what says out of order.
.out_of_order_back:	xor		a		; 0: it belongs earlier than it is
					ret		
.out_of_order_on:	xor		a
					inc		a		; 1: later. INC leaves the carry alone
					ret		
; Put an object into the background run: drawn before everything else and
; never sorted, so it is permanently behind. Splices in at sort_head --
; the same splice depth_insert uses -- and then moves sort_head past us,
; so the sorted run now starts after this object.
;   IX -> the object, not currently in any list
; Corrupts A, BC, DE, HL.
background_insert:	ld		hl,(sort_head)
					ld		(insert_at),hl
					call	depth_insert_from.link
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

					; It has to be put back, and the list is in order apart from it, so
					; the search need not always start at the front of the run.
					;
					; The scan only ever advances, and where it may start depends on which
					; way the object has gone. depth_in_order has just said: A is 1 if it
					; belongs later than it sits, 0 if earlier.
					;
					; Later, and starting where it already is gives the same answer as
					; starting from the front: everything ahead of it was not-further last
					; time it was placed, and moving nearer cannot have changed that.
					;
					; Earlier is not the mirror of that, and it took a measurement to
					; believe it. Backing up to a point and scanning forward from there
					; loses what the scan learns on the way down -- insert_at, the last
					; object it was NEARER than -- so it can settle in front of where a
					; scan from the front would put it. It differed on 22 frames of 180.
					; So that half goes the long way round, and only the cheap half is
					; taken cheaply.
					push	af		; depth_unlink wants A
					ld		l,(ix+OBJ.PREV)
					ld		h,(ix+OBJ.PREV+1)
					ld		(insert_at),hl		; where it came out of
					call	depth_unlink
					pop		af

					; The upper half of a two-part object overrides this: it starts
					; from the lower half, which cannot be behind it.
					ld		hl,(relink_from)
					ld		c,a
					ld		a,h
					or		l
					jr		nz,.from
					ld		a,c
					and		a
					jr		z,.from_front		; belongs earlier: start over
					ld		hl,(insert_at)		; belongs later: on from where it was
					jr		.from
.from_front:		ld		hl,(sort_head)
.from:				jp		depth_insert_from		; the setup above still stands
