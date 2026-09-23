					INCLUDE	"object_struct.s"


; An object is drawn at a sub-byte X offset by rotating its sprite into a
; buffer first, and the rotated copy has to survive until that object is
; blitted -- which is after EVERY object has been updated. So the buffer
; cannot be shared: with one between them, the last object to shift would
; overwrite what the others had prepared and they would all draw its
; bitmap. Each object that needs one takes its own from the room's arena --
; see shift.s -- or, if it is marked OBJ_SHARED_SHIFT or the arena is full,
; rotates into the one shared buffer at the moment it is drawn.
;
; An object that is only ever drawn byte-aligned never reaches that path,
; so it needs no buffer at all, and a record declared with object_record
; passes 0 for one to be found when it is wanted.

OBJ_MOVABLE			EQU		0x80		; FLAGS bit 7

; FLAGS bit 5: SPRITE_L/H points at this object's own rotated copy rather
; than at the shared graphic. Set by shift_sprite, cleared on the byte-
; aligned path. sprite_orient skips these -- the copy is private, it was
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
; rooms_source.py works out the graphics some room wants both ways, nominates one
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
; The two origins say where the world's origin lands on screen, and are
; ours to choose. X is 128; Y is 40, which is 296 mod 256 -- the origin
; Knight Lore itself uses, once its bottom-up rows are turned over.
; object_place is where the projection is done.
WORLD_X_ORIGIN		EQU		128
WORLD_Y_ORIGIN		EQU		40		; 296 mod 256 -- the origin Knight Lore itself uses

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

COLLIDE_U			EQU		1
COLLIDE_V			EQU		2
COLLIDE_Z			EQU		4

; What stopped a thing before object_collide gets its say: the room's own edges
; and its floor. object_collide opens by clearing collide_hit, so neither can go
; straight in there -- they are gathered here and folded in afterwards.
;
; The edges matter to more than the walker. Knight Lore sets the same bit from
; inside the bound check itself, SET 0,(IX+$0C) at $CCF6, and it is what tells a
; pacing fire to turn at the wall rather than stand pressed against it.
collide_bound:		DB		0

; Which axes had to give, one bit each. The caller reads it to know it has hit
; something -- landing on a floor is the Z bit and a step into a wall is the U
; or V one.
collide_hit:		DB		0

; The bit object_clamp sets when it has to cut the axis it was given. Straight
; after collide_hit, so that object_clamp loads the pair in one.
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


; What object_clamp walks: the records this step could touch at all, gathered
; once per move by collide_gather. Knight Lore walks all forty slots of its
; table on every axis; ours are in two places, the room's pool and the other
; character, and walking both three times over was most of what a mover cost
; -- 21,000 T for each block riding on the ghost in room $BB, which is itself
; three axes of twenty-odd records every turn. Almost all of them are nowhere
; near, and one look at the whole step says so for all three axes at once.
collide_list:		DS		2 * (POOL_SLOTS + 1)
collide_list_count:	DB		0
collide_list_at:	DW		0

; A ride fills in a step the object did not have when the list was gathered:
; object_carry copies whatever it is standing on. So an axis with nothing on it
; is gathered this much wider either way, which covers anything in the castle
; walking or being walked, and a bigger one makes object_collide gather again.
CARRY_REACH			EQU		8

; The character to test against as well as the room, or zero. There are only
; ever two of them and each needs the other, so a single pointer does.
collide_other:		DW		0

; Our own box with the step already in it, worked out once and then read by
; every test in the scan. It was being recomputed from the record and the
; deltas for each object, which is four indexed loads an axis for something
; that only changes when an axis is actually cut.
;
; Between each floor axis's pair, how far the gathered box reaches along it
; from where the object stands, so that object_collide can tell whether a ride
; has handed it a step the gather did not allow for. In this order because
; collide_gather writes them in it, through one pointer.
collide_u_min:		DB		0
collide_u_max:		DB		0
collide_reach_u:	DB		0
collide_v_min:		DB		0
collide_v_max:		DB		0
collide_reach_v:	DB		0
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


; Do our box and this object's overlap on all three axes? Touching exactly
; counts as apart, which is what lets a character stand on a block rather than
; sink into it. BC and HL are kept, which object_clamp is using.
;
; In:  IX -> the character's legs record, its step in DU, DV and DZ
;      IY -> the object to test against
; Out: carry set if they overlap, clear if any axis separates them
; Corrupts: A, DE
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
					ld		a,(collide_u_max)
					ld		e,a
					ld		a,d
					sub		(iy+OBJ.SIZE_U)		; their min
					cp		e
					jr		nc,.apart		; their min >= our max

					; The gather does its own U test, inline, and comes in here.
.v:					ld		a,(iy+OBJ.V)
					ld		d,a
					add		a,(iy+OBJ.SIZE_V)
					ld		e,a
					ld		a,(collide_v_min)
					cp		e
					jr		nc,.apart
					ld		a,(collide_v_max)
					ld		e,a
					ld		a,d
					sub		(iy+OBJ.SIZE_V)
					cp		e
					jr		nc,.apart

					; The gather does U and V inline and comes in here.
					;
					; Z is a base and a full height, not a centre and a half,
					; so it keeps the edge comparison.
					;
					; A character is the exception at this end too: its record
					; says twelve because that is the box the depth sort wants,
					; and the figure is the whole COLLIDE_HEIGHT.
					;
					; In:  IX -> the character's legs record
					;      IY -> the object to test against
					; Out: carry set if they overlap in Z
					; Corrupts: A, DE
.z:					ld		d,(iy+OBJ.Z)
					ld		e,(iy+OBJ.SIZE_Z)
					bit		7,(iy+OBJ.FLAGS)		; OBJ_MOVABLE
					jr		z,.their_height
					ld		e,COLLIDE_HEIGHT
.their_height:		ld		a,d
					add		a,e
					ld		e,a		; their top
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
;
; In:  IX -> the character's legs record
; Out: collide_u_min to collide_z_max = the box
; Corrupts: AF
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

					; And the same exception object_overlaps makes at the other end. A
					; character is one figure in two records and the whole of it is
					; COLLIDE_HEIGHT; anything else is exactly as tall as it says it is.
					; This used to hand COLLIDE_HEIGHT to whatever was moving, which was
					; true while only the knight ever moved -- and then a ghost twelve
					; units tall got a box of twenty-three, reached up into the block
					; standing on it, and was stopped in every direction by its own
					; passenger.
					ld		c,(ix+OBJ.SIZE_Z)
					bit		7,(ix+OBJ.FLAGS)	; OBJ_MOVABLE
					jr		z,.own_height
					ld		c,COLLIDE_HEIGHT
.own_height:		add		a,c
					ld		(collide_z_max),a
					ret


; Cut one axis of the step back until nothing in the room is in the way.
;
; Every object in the room is tested with the step as it currently stands, so
; the axes have to be done in a fixed order and each sees the ones before it
; already settled. An object that is in the way takes one unit off this axis,
; and is then tested again from the new position -- so a step of eight into a
; wall ends up as however much of it fits, not as nothing.
;
; In:  HL -> the delta to cut, one of this object's DU, DV or DZ
;      IX -> the character's legs record
;      collide_mask = the bit to set in collide_hit if this axis has to give
; Out: (HL) = the delta, cut
; Corrupts: AF, BC, DE, IY
object_clamp:		ld		a,(hl)
					or		a
					ret		z		; not moving along this axis

					ld		a,(collide_list_count)
					or		a
					ret		z
					ld		b,a
					ld		de,collide_list
					ld		(collide_list_at),de
					call	collide_box

.load:				ld		de,(collide_list_at)
					ld		a,(de)
					ld		iyl,a
					inc		de
					ld		a,(de)
					ld		iyh,a
					inc		de
					ld		(collide_list_at),de

.object:			call	object_overlaps
					jr		nc,.next

					; Something is in the way. If this is the Z pass then we have
					; just landed on it, and if we are the sort of thing that rides
					; on other things we go where it goes -- see object_carry.
					ld		a,(collide_mask)
					cp		COLLIDE_Z
					jr		nz,.shove
					call	object_landed_on
					call	object_carry
					jr		.contact
.shove:			call	object_shove
.contact:			call	object_touched


					; In the way, so this axis has had to give.
					ASSERT	collide_mask == collide_hit + 1
					ld		de,(collide_hit)		; E - what has given, D - this axis
					ld		a,d
					or		e
					ld		(collide_hit),a

					; Give a unit back and look again -- at the same object,
					; because one unit may not be enough. The sign of the step
					; picks the way back, and INC and DEC say whether it is
					; now nothing.
					bit		7,(hl)
					jr		nz,.negative
					dec		(hl)
					jr		.gave
.negative:			inc		(hl)
.gave:				ret		z		; nothing left to give, and nothing else
					; can take any: the rest of the room
					; cannot make a zero step smaller
					call	collide_box
					jr		.object

.next:				djnz	.load
					ret


; Gather the records this object's step could touch: everything whose box
; meets the box swept by the whole of DU, DV and DZ. The clamp only ever cuts a
; step back towards nothing, so every box it tries lies inside this one, and
; anything outside it cannot be in the way on any axis. Touching counts as
; apart here exactly as it does in object_overlaps, which does the testing.
;
; The one thing that can grow a step is a ride -- see CARRY_REACH.
;
; In:  IX -> the record, DU, DV and DZ its step
; Out: collide_list, collide_list_count = what it could touch
; Corrupts: AF, BC, DE, HL, IY
collide_gather:		ld		a,TURN_PER_GATHER
					call	turn_add
					ld		e,0
					ld		a,(ix+OBJ.DZ)
					or		a
					jr		z,.no_ride		; only the Z pass can hand over a ride
					ld		e,CARRY_REACH

					ASSERT	collide_reach_u == collide_u_min + 2 && collide_v_min == collide_u_min + 3
					ASSERT	collide_z_min == collide_u_min + 6 && collide_z_max == collide_u_min + 7
					ASSERT	OBJ.V == OBJ.U + 1 && OBJ.SIZE_V == OBJ.SIZE_U + 1 && OBJ.DV == OBJ.DU + 1
.no_ride:			push	ix
					pop		iy
					ld		hl,collide_u_min
					call	.axis		; U
					inc		iy		; V's fields are U's, one along
					call	.axis

					ld		e,0
					ld		a,(ix+OBJ.DZ)
					call	.span
					ld		a,(ix+OBJ.Z)
					sub		d
					ld		(hl),a		; collide_z_min
					inc		hl
					ld		a,(ix+OBJ.Z)
					ld		b,(ix+OBJ.SIZE_Z)
					bit		7,(ix+OBJ.FLAGS)		; OBJ_MOVABLE: a character's whole
					jr		z,.own_height		; figure, as collide_box has it
					ld		b,COLLIDE_HEIGHT
.own_height:		add		a,b
					add		a,c
					ld		(hl),a		; collide_z_max

					; Almost everything in the room is somewhere else along U, so
					; that one test is what the sweep spends its time on -- and
					; it was paying 27T of call and return to reach it and 13T
					; a time to read our own edges out of memory. Inline, with
					; the edges patched in as immediates the way depth_cmp_setup
					; hoists its own, a miss costs 40T where it used to cost
					; 102T. What passes goes into object_overlaps at .v, which
					; is the same routine with the U test already done.
					;
					; The edges are the swept box .axis has just written, so
					; this has to follow it. One past the minimum, because
					; touching exactly counts as apart and a CP that way round
					; says "less than".
					ld		a,(collide_u_min)
					inc		a
					ld		(.u_over + 1),a
					ld		a,(collide_u_max)
					ld		(.u_under + 1),a
					ld		a,(collide_v_min)
					inc		a
					ld		(.v_over + 1),a
					ld		a,(collide_v_max)
					ld		(.v_under + 1),a

					ld		hl,collide_list
					ld		c,0
					ld		a,(room_object_count)
					or		a
					jr		z,.other
					ld		b,a
					ld		iy,room_objects
					ld		de,ROOM_STRIDE		; kept across the loop, and only
					; object_overlaps takes it away

					; Their centre is not kept either. Holding it costs 4T on
					; every object to save 15T on the few that get past the
					; first compare, and reading it twice leaves DE alone.
.each:				ld		a,(iy+OBJ.U)
					add		a,(iy+OBJ.SIZE_U)		; their max
.u_over:			cp		0		; patched: one past our min
					jr		c,.next		; their max is at or below it
					ld		a,(iy+OBJ.U)
					sub		(iy+OBJ.SIZE_U)		; their min
.u_under:			cp		0		; patched: our max
					jr		nc,.next

					; V the same way. What is left by here is the handful of
					; objects standing along our own line of U, so the last
					; axis and the flags are worth a call.
					ld		a,(iy+OBJ.V)
					add		a,(iy+OBJ.SIZE_V)
.v_over:			cp		0		; patched: one past our min
					jr		c,.next
					ld		a,(iy+OBJ.V)
					sub		(iy+OBJ.SIZE_V)
.v_under:			cp		0		; patched: our max
					jr		nc,.next
					call	object_overlaps.z		; preserves BC and HL
					call	c,.keep
					ld		de,ROOM_STRIDE		; which the call does not
.next:				add		iy,de
					djnz	.each

.other:				ld		iy,(collide_other)
					ld		a,iyh		; zero for none: no record lives
					or		a		; in the bottom page
					jr		z,.done
					call	object_overlaps
					call	c,.keep
.done:				ld		a,c
					ld		(collide_list_count),a
					ret

.keep:				ld		a,iyl
					ld		(hl),a
					inc		hl
					ld		a,iyh
					ld		(hl),a
					inc		hl
					inc		c
					ret

					; One floor axis of the box. IY -> the record, moved along so that
					; its U fields are this axis's; HL -> the axis's min, max and reach,
					; and past them to the next axis's on the way out.
.axis:				ld		a,(iy+OBJ.DU)
					call	.span
					ld		b,a		; the reach
					ld		a,(iy+OBJ.U)
					sub		(iy+OBJ.SIZE_U)
					sub		d
					ld		(hl),a		; min
					inc		hl
					ld		a,(iy+OBJ.U)
					add		a,(iy+OBJ.SIZE_U)
					add		a,c
					ld		(hl),a		; max
					inc		hl
					ld		(hl),b		; reach
					inc		hl
					ret

					; A step in A: how far the box reaches below the object (D) and
					; above it (C), and the further of the two back in A. A step of
					; nothing reaches E either way.
.span:				or		a
					jr		nz,.moving
					ld		d,e
					ld		c,e
					ld		a,e
					ret
.moving:			jp		m,.down
					ld		d,0
					ld		c,a
					ret
.down:				neg
					ld		d,a
					ld		c,0
					ret


; The U and V passes: we have run into IY. If it is the sort of thing that can
; be shoved, it takes the step we wanted -- read before the walk-back below, so
; it gets the whole of it and not what is left after we have given way.
;
; We still walk our own step back either way, so the shove costs us the turn
; and IY moves on its own next one. That is the game's, at loc_CBAF, and it is
; why a block meeting the knight both stops and moves him.
;
; Whether the shove comes off is not decided here. IY's own clamp has the say
; when its turn comes, and if it cannot go anywhere it simply does not.
;
; In:  IX -> us
;      IY -> what we ran into
;      collide_mask = which axis
; Out: nothing
; Corrupts: AF
object_shove:		bit		7,(iy+OBJ.FLAGS)	; the same test object_carry makes, the
					jr		nz,.shoveable		; other way round: one flag in the game
					ld		a,(iy+OBJ.BEHAVIOUR)	; means both carried and pushed, and it
					cp		BEHAVIOUR_LOOSE	; is on the block, the chest, the table
					ret		c			; and the knight alike
.shoveable:			ld		a,(collide_mask)
					cp		COLLIDE_U
					jr		nz,.along_v
					ld		a,(ix+OBJ.DU)
					ld		(iy+OBJ.DU),a
					ret		
.along_v:			ld		a,(ix+OBJ.DV)
					ld		(iy+OBJ.DV),a
					ret		


; We have just been stopped in Z by IY, which means we are standing on it. If
; we are the sort of thing that rides, and we are not already going somewhere
; under our own steam, we take its step for our own.
;
; That is the whole of how a block rides on a ghost, and Knight Lore puts it in
; exactly this place -- loc_CC4D, inside the Z half of the object clamp. It
; costs nothing anywhere else because a carried thing clears its own DU and DV
; at the top of every turn and has nothing else to say; the ride is the only
; thing that ever fills them in.
;
; The Z pass runs before U and V, so what is written here is what those two
; passes then clamp and apply, in the same turn.
;
; In:  IX -> us
;      IY -> what stopped us
; Out: nothing
; Corrupts: AF
object_carry:		bit		7,(ix+OBJ.FLAGS)	; OBJ_MOVABLE: a character, and
					jr		nz,.rides		; the knight rides in the game too --
					ld		a,(ix+OBJ.BEHAVIOUR)	; plyr_spr_init_data gives his record
					cp		BEHAVIOUR_LOOSE	; flags $1C, which has the same bit 2
					ret		c			; a moveable block, a table and a
										; chest all have
.rides:

					ld		a,(ix+OBJ.DU)
					or		a
					jr		nz,.own_v
					ld		a,(iy+OBJ.DU)
					ld		(ix+OBJ.DU),a
.own_v:				ld		a,(ix+OBJ.DV)
					or		a
					ret		nz
					ld		a,(iy+OBJ.DV)
					ld		(ix+OBJ.DV),a
					ret		


; We are touching IY, on whichever axis. If one of us is the knight and the
; other kills, he is dead. Knight Lore spreads the same thing through the same
; place: every contact in all three passes of its clamp -- $CBAF, $CBFE and
; $CC4D -- copies each side's deadly bit into the other's "touched" bit, so it
; does not matter whether he walks into a spike or a guard walks into him.
;
; The two bits are separate there, though, and a thing can carry only the one
; that says it kills when it hits him. Those are [CRUSHING, HARMLESS): deadly
; when they are the mover, and harmless when he is.
;
; In:  IX -> us
;      IY -> what we touched
; Out: nothing
; Corrupts: AF
object_touched:		bit		7,(ix+OBJ.FLAGS)		; OBJ_MOVABLE: we are the knight
					jr		nz,.he_is_us
					bit		7,(iy+OBJ.FLAGS)
					ret		z		; neither of us is
					ld		a,(ix+OBJ.BEHAVIOUR)	; it came at him
					sub		BEHAVIOUR_DEADLY
					cp		BEHAVIOUR_HARMLESS - BEHAVIOUR_DEADLY
					jr		.deadly
.he_is_us:			ld		a,(iy+OBJ.BEHAVIOUR)	; he came at it
					sub		BEHAVIOUR_DEADLY
					cp		BEHAVIOUR_CRUSHING - BEHAVIOUR_DEADLY
.deadly:			ret		nc
					ld		a,1
					ld		(deadly_touched),a
					ret


; We have just come down on IY. A block that gives way under a weight wants to
; know: the game marks everything landed on, SET 3,(IY+$0D) at $CC6C, and the
; dropping and collapsing blocks look for the mark on their next turn. Ours goes
; in MOVE_STATE, which every other mover uses for something else, so only those
; two are marked.
;
; In:  IY -> what stopped us
; Out: nothing
; Corrupts: AF
object_landed_on:	ld		a,(iy+OBJ.BEHAVIOUR)
					cp		BEHAVIOUR_GIVES
					ret		c
					cp		BEHAVIOUR_GIVES_LAST + 1
					ret		nc
					set		3,(iy+OBJ.MOVE_STATE)
					ret


; Cut a whole step down to what fits, Z first and then U and then V.
;
; In:  IX -> the character's legs record, DU, DV and DZ what it would like
; Out: DU, DV and DZ = what it may do
;      collide_hit = which axes gave
; Corrupts: AF, BC, DE, HL, IY
object_collide:		xor		a
					ld		(collide_hit),a
					ld		(collide_eff_u),a		; nothing is moving yet, as
					ld		(collide_eff_v),a		; far as any test can see
					ld		(collide_eff_z),a

					; Not moving at all, and nothing to gather for.
					ld		a,(ix+OBJ.DU)
					or		(ix+OBJ.DV)
					or		(ix+OBJ.DZ)
					ret		z

					; Z, then U, then V. Each takes what the object asked for on
					; its own axis, has it cut down against everything, and hands
					; the answer back to the record -- where the axes after it
					; will see it, and the axes before it already have. The
					; gather reads the record's own deltas, not collide_eff, so it
					; can go first.
					call	collide_gather
					ld		a,COLLIDE_Z
					ld		hl,collide_eff_z
					call	object_pass

					; Did a ride hand over more than the gather allowed for? Then
					; gather again, around the step as it now stands.
					; SBC with the carry set takes one more off, so it borrows
					; exactly when the step is no more than the reach.
					ld		a,(ix+OBJ.DU)
					call	character_door_find.abs
					ld		hl,collide_reach_u
					scf
					sbc		a,(hl)
					jr		nc,.again
					ld		a,(ix+OBJ.DV)
					call	character_door_find.abs
					ld		hl,collide_reach_v
					scf
					sbc		a,(hl)
					jr		c,.passes
.again:				call	collide_gather
.passes:
					ld		a,COLLIDE_U
					ld		hl,collide_eff_u
					call	object_pass
					ld		a,COLLIDE_V
					ld		hl,collide_eff_v

					;; NB: fall through into object_pass


; One axis of object_collide: the record's delta into collide_eff for the tests
; to see, cut down by object_clamp, and back into the record. The three
; collide_eff bytes and the record's three deltas run in the same order, U, V
; then Z, so where HL is among the first says which of the second to use, and
; that offset is written into the two indexed loads.
;
; In:  A  = the axis's bit, for collide_hit
;      HL -> its collide_eff byte
;      IX -> the record
; Out: nothing
; Corrupts: AF, BC, DE, IY
					ASSERT	collide_eff_v == collide_eff_u + 1 && collide_eff_z == collide_eff_u + 2
					ASSERT	OBJ.DV == OBJ.DU + 1 && OBJ.DZ == OBJ.DU + 2
object_pass:		ld		(collide_mask),a
					ld		a,l
					sub		low collide_eff_u - OBJ.DU
					ld		(.get+2),a
					ld		(.put+2),a
.get:				ld		a,(ix+0)		; imm: the delta's offset
					ld		(hl),a
					call	object_clamp
					ld		a,(hl)
.put:				ld		(ix+0),a		; imm: the same
					ret


; Place an object from its world coordinates, and update it: the screen position
; from U, V and Z, projected as WORLD_X_ORIGIN's comment describes, then
; object_update with it. The only place the projection is done, so it is here
; rather than in a routine of its own.
;
; In:  IX -> the object, with U, V, Z and GFX set
; Out: nothing
; Corrupts: everything but IX
object_place:		ld		a,(ix+OBJ.U)
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
					ld		a,(ix+OBJ.GFX)		; and the graphic to draw it with
					; NB: fall through


; Update an object for a screen position and a graphic: its sprite, the way
; round it wants it, rotated if it lands off a byte, and its extent.
;
; In:  IX -> the object
;      A  = the graphic
;      B  = the screen y of its base
;      C  = the screen x
; Out: nothing
; Corrupts: everything but IX
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
					; checked again at draw time, in sprite_orient, because some
					; other object may mirror the shared bytes in the meantime.
					;
					; BC is the screen position and is wanted below; DE is not live
					; yet, so sprite_flip_h is free to use it.
					ASSERT	SPRITE_FLIPPED == 1
					ld		a,(hl)
					xor		(ix+OBJ.FLAGS)
					rrca			; the two flip bits differ: carry
					jr		nc,.oriented
					push	bc
					call	sprite_flip_h		; which keeps HL
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
					; the sprite width and the distance to the view edge. When the
					; blit was one unrolled routine per (columns, width) pair, an
					; overlap wider than the sprite indexed past them all and into
					; the jump table's padding, which then ran as code.
					;
					; (hl) is the BLIT INDEX, (width-2) * JUMP_GROUP, not a width in
					; bytes -- sprite_source.py changed that encoding. So unpack the width
					; back out rather than adding it raw, which is what the old
					; "adc (hl) / inc a" did.
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

					; It runs off the top. MIN_Y is clamped to row 0 and what it
					; lost is kept, for the blit to start that far in.
					neg			; height - base, the rows above row 0
					ld		(ix+OBJ.CLIP_TOP),a
					xor		a
					ld		(ix+OBJ.MIN_Y),a
					ld		(ix+OBJ.MAX_Y),b	; the base
					jr		.y_done

.on_screen:			ld		(ix+OBJ.MIN_Y),a		; top = base - height
					ld		(ix+OBJ.CLIP_TOP),0	; and nothing lost off the top

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
.where:				bit		3,(ix+OBJ.FLAGS)		; OBJ_SHARED_SHIFT: not here, but
					jp		nz,.defer_shift		; at the moment it is drawn
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
					jr		.where		; and ask again, which cannot come back
					; here: now there is a buffer or the flag

					; A null buffer here means the arena is full, and nothing can be
					; rotated into a null pointer -- it would read the blit back out
					; of ROM. The fallback used to be to draw it byte-aligned, up to
					; seven pixels left of true; it rotates into the shared buffer at
					; draw time instead, which is slower every time it is drawn but
					; is in the right place. So the arena is a budget for speed now
					; rather than a cliff the picture falls off, and a sprite set
					; that outgrows it gets slower rather than wrong. shift_alloc
					; sets OBJ_SHARED_SHIFT itself when it cannot give one.
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
					ld		h,a		; what a twin's flags must look like; HL is saved
					ld		c,(ix+OBJ.GFX)
					ld		iy,room_objects
					ld		de,ROOM_STRIDE
					ld		a,(room_object_count)
					ld		b,a
					or		a
					jr		z,.no_twin

.twin:				ld		a,(iy+OBJ.FLAGS)
					and		OBJ_COPIED | OBJ_FLIP_H
					cp		h
					jr		nz,.next_twin
					ld		a,(iy+OBJ.GFX)
					cp		c
					jr		z,.twinned
.next_twin:			add		iy,de
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
					call	.share		; SPRITE -> the shared graphic

					; A rotated form carries one overflow column the artwork does
					; not, and the blit index and the extent widen with it.
.widen:				ld		a,(ix+OBJ.BLIT_IDX)
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

					; Already in there? The same graphic, the same shift and the same
					; way round as last time leave nothing to do -- see the two bytes
					; shift_alloc keeps in front of every buffer.
					ld		c,a		; the shift
					ld		a,(ix+OBJ.FLAGS)
					and		OBJ_FLIP_H
					add		a,a
					add		a,a
					add		a,a
					or		c
					or		$80
					ld		b,a		; what the buffer has to say
					dec		de		; -> the shift and way round
					ld		a,(de)
					cp		b
					jr		nz,.stale
					dec		de		; -> the graphic
					ld		a,(de)
					cp		(ix+OBJ.GFX)
					jr		z,.rotated
					inc		de
.stale:				ld		a,b
					ld		(de),a
					dec		de
					ld		a,(ix+OBJ.GFX)
					ld		(de),a
					inc		de
					inc		de		; -> the buffer again
					ld		a,c
					call	.rotate
.rotated:

					ld		a,(ix+OBJ.BUF_L)
					ld		(ix+OBJ.SPRITE_L),a
					ld		a,(ix+OBJ.BUF_H)
					ld		(ix+OBJ.SPRITE_H),a
					set		5,(ix+OBJ.FLAGS)		; this copy is private and already
					; the right way round: sprite_orient
					; leaves it alone
					jr		.widen


					; Rotate a sprite. A local label, because the rest of
					; object_update's locals sit below it and a global one here
					; would take them out of its scope -- objects_draw_all calls
					; it as object_update.rotate.
					; SP is borrowed, and restored.
					;
					; In:  A  = the shift, 1 to 7
					;      DE -> where the rotated copy goes
					;      HL -> the sprite record's height byte
					;      IX -> the object, for BLIT_IDX -- which must be the
					;            UNROTATED index, as it is at placement
					; Out: nothing
					; Corrupts: everything but IX
.rotate:
                    ; A - shift amount, A' - height
                    ; C - BLIT_INX

                    ex      af,af'      ; stash shift amount before it's overwritten below
                    ld      a,(hl)      ; get height
					push	af		; and count it towards the turn: three
					push	hl		; units a row
					ld		h,a
					add		a,a
					add		a,h
					call	turn_add
					pop		hl
					pop		af
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


;; Calculate parameters to do with overlapping extents
;;
;;  E------D
;;  |      |
;; C--B    |
;; |  |    |
;; +--+    |
;;  |      |
;;  +------+
;;
;; In:  BC = the sprite's extent
;;      DE = the current extent
;; Out: carry set if there is any overlap
;;      A  = the overlap's size
;;      H  = the extent adjustment
;;      L  = the sprite adjustment
;; Corrupts: B
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


; Composite every object that meets the region into the view buffer, in list
; order, furthest first.
;
; In:  view_x_extent, view_y_extent = the region
; Out: nothing
; Corrupts: everything
objects_draw_all:				
					ld		hl,(view_x_extent)			
					ld		(.set_x_extent + 1),hl
					ld		hl,(view_y_extent)			
					ld		(.set_y_extent + 1),hl

					; 'return' address in IX
					ld		ix,.next_object

					; Save stack pointer as we going to use stack pointer to read object data					
					ld		(.set_stack + 1),sp
					
					; Walk though objects filtering out those outside the view extent.
					; The four rejects below are JPs rather than JRs: they used to be
					; JRs and the loop had to stay inside a byte's reach of them,
					; which it no longer does. It costs nothing -- a reject is the
					; common case, and a taken JR is 12T against a JP's 10.
					ld		iy,(object_list)					
					jp		.next_object		; the same test also covers an empty list
					; JP, not JR: the loop below no longer fits in a byte's reach
.filter_loop:		ld		sp,iy
					pop		iy					; get next object

.set_y_extent:		ld		de,0				; de = view y extent
					pop		bc					; bc = object y excent
					ld		a,c					; a = obj_min_y
					cp		d					; obj_min_y - view_max_y
					jp		nc,.next_object		; if obj_min_y - view_max_y >= 0, return					
					ld		a,e					; a = view_min_y
					cp		b					; view min_y - obj_max_y
					jp		nc,.next_object   	; if view_min_y - obj_max_y >= 0, return
					exx
.set_x_extent:		ld		de,0				; de = view x extent
					pop		bc					; bc = object x excent
					ld		a,c					; a = obj_min_x
					cp		d					; obj_min_x - view_max_x
					jp		nc,.next_object		; if obj_min_x - view_max_x >= 0, return					
					ld		a,e					; a = view_min_x
					cp		b					; view min_x - obj_max_x
					jp		nc,.next_object   	; if view_min_x - obj_max_x >= 0, return

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

					; Rows to skip before the first one that shows: what the redraw
					; region cuts off the top, plus what the SCREEN cuts off above
					; that. The second is CLIP_TOP, and it is reached through SP,
					; which is eight bytes into this record with two pops to go.
					;
					; Ultimate did not need any of this. Their artwork is stored
					; bottom row first -- sprite_source.py turns it the right way up on the
					; way in -- and an object hung on its base draws upward from a
					; known address, so running off the top of the screen just means
					; drawing fewer rows and stopping. Top-down data has to find the
					; first visible row instead, and that is a multiply.
					ld		b,l				; what the region skips, negated
					ld		hl,OBJ.CLIP_TOP - 8
					add		hl,sp
					ld		a,(hl)			; and what the screen took
					sub		b					; A = both, as a positive row count
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
					; Out of line because it was once the thing that kept this
					; loop inside a JR's reach of the filter tests above. They
					; are JPs now, and it stays out of line for its size.
					;
					; First, count the blit towards the turn -- see turn_pace. It is
					; written out rather than a call to turn_add, which would save HL
					; for nobody: this is once per object drawn, and H and L are
					; free here. The rows are in the other bank.
					exx
					ld		a,b
					exx
					add		a,TURN_PER_BLIT
					ld		hl,turn_work
					add		a,(hl)
					ld		(hl),a
					jr		nc,.counted
					inc		hl
					inc		(hl)
.counted:			ex		af,af'				; x overlap: the columns to composite
					jp		sprite_blit_setup

					; Return here after blit routine
.next_object:		ld		a,iyh
					and		a
					jp		nz,.filter_loop		; loop back if not
.set_stack			ld		sp,000				; restore stack pointer
					ret
