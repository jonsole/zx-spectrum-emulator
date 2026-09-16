; ---------------------------------------------------------------------------
; The room the engine plays in: its bounds and doorways, which the walker and
; the collision read every turn, and the objects in the pool -- filled in by
; room_add, then placed, sorted and drawn by room_show.
;
; The game's room builder, knightlore/room_build.s, empties and fills these.
; ---------------------------------------------------------------------------

; The Z of a room's floor, from room_size_tbl. Object positions are measured
; up from it; scenery carries absolute Z and does not need it.
; How far this room's floor reaches from its centre, along each axis. Knight
; Lore keeps the same numbers at $5BAB and $5BAE and clamps against them the
; same way -- see character_collide.
; Which sides of the room have a doorway, and where each one stands. A
; doorway is an arch, and an arch is scenery, so both facts are already in
; the room's own data -- room_door_note picks them out as the scenery goes by.
;
; The directions are the scenery data's own: north is +V, east +U, south -V
; and west -U, which is the order the four arch templates come in, so the
; index falls out of the bottom two bits of the template number.
;
; room_door_z is the height of the arch's floor, and doubles as whether there
; is a door at all -- nothing in the castle stands at Z=0. room_door_at is how
; far the arch stands out along its own axis. The game's arches sit four units
; beyond the wall, and the two ends of the castle are not quite symmetric
; about 128, so this is read from the artwork rather than assumed.
ROOM_DOOR_N		EQU		0
ROOM_DOOR_E		EQU		1
ROOM_DOOR_S		EQU		2
ROOM_DOOR_W		EQU		3

room_door_z:		DS		4
room_door_at:	DS		4

room_half_u:		DB		0
room_half_v:		DB		0
room_floor_z:		DB		0

; How many objects the room has produced so far.
room_object_count:	DB		0


; What drives the record room_add is about to fill in, and what drives the
; group it belongs to. Only the FIRST sprite of an object is given the
; behaviour -- a guard is drawn from two records and only one of them may be
; the one that walks.
room_behaviour:		DB		0


; ---------------------------------------------------------------------------
; Fill one object record.
;   HL -> sprite, U, V, Z, size U, size V, size Z, flags
;   IX -> the record
; Advances HL past the eight bytes and IX to the next record.
room_add:			ld		a,(room_object_count)
					cp		ROOM_SLOTS
					jr		nc,.full

					ld		a,(hl)
					cp		2		; 0 ends a template and 1 means
					jr		c,.skip		; "drawn by something else"
					ld		(ix+OBJ.GFX),a
					inc		hl
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
					ld		(ix+OBJ.SIZE_U),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.SIZE_V),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.SIZE_Z),a
					inc		hl
					ld		a,(hl)
					inc		hl

					; Already in our layout: rooms.py wrote it that way.
					ld		(ix+OBJ.FLAGS),a

					; A rotation buffer belongs to the room, not the object;
					; shift_reset has just taken the last room's back.
					ld		a,(room_behaviour)
					ld		(ix+OBJ.BEHAVIOUR),a
					ld		(ix+OBJ.MOVE_STATE),0

					; And no step left over from whatever this record was in the last
					; room. The pool is reused and nothing else clears these -- which
					; mattered the moment object_carry started reading them off
					; whatever a thing is standing on: a plain block that had been a
					; ghost would have shoved the knight sideways.
					ld		(ix+OBJ.DU),0
					ld		(ix+OBJ.DV),0
					ld		(ix+OBJ.DZ),0

					ld		(ix+OBJ.BUF_L),0
					ld		(ix+OBJ.BUF_H),0

					call	room_adjust

					ld		bc,ROOM_STRIDE
					add		ix,bc
					ld		a,(room_object_count)
					inc		a
					ld		(room_object_count),a
					ret

.skip:				ld		bc,8
					add		hl,bc		; step over it, add nothing
					ret

.full:				ld		bc,8
					add		hl,bc
					ret


; The pixel nudge that lines this sprite's artwork up with its position.
; Knight Lore picks these inside its per-graphic update routines; adj.py
; harvested the values into two tables, one for each way round.
;   IX -> the record, with GFX and FLAGS already set
room_adjust:		push	hl
					ld		h,high sprite_adj_index
					ld		l,(ix+OBJ.GFX)		; the table is page-aligned, so the
					ld		a,(hl)		; graphic number is the address

					; Bit 7 says this graphic wants a different nudge mirrored,
					; which four of them do. Everything else uses the one index
					; whichever way round it is drawn.
					bit		OBJ_FLIP_BIT,(ix+OBJ.FLAGS)
					jr		z,.found
					and		a		; bit 7 into the sign flag
					jp		p,.found
					call	.mirrored

.found:				and		$7F		; the index, already doubled
					ld		c,a
					ld		b,0
					ld		hl,sprite_adj_pairs
					add		hl,bc
					ld		a,(hl)
					ld		(ix+OBJ.ADJ_X),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.ADJ_Y),a
					pop		hl
					ret

					; One of the four. Walk the short list for this graphic and
					; take the index it names instead.
.mirrored:			ld		hl,sprite_adj_mirror
					ld		c,(ix+OBJ.GFX)
.look:				ld		a,(hl)
					and		a
					ret		z		; not there after all: keep what we had
					inc		hl
					cp		c
					jr		z,.take
					inc		hl
					jr		.look
.take:				ld		a,(hl)
					ret


; ---------------------------------------------------------------------------
; Place every object, sort them, and paint the room.
;
; Placement has to finish before any insertion, so that every depth comparison
; sees real coordinates; and everything is placed before anything is drawn, so
; that the first object painted already has the rest behind it.
room_show:			ld		hl,object_place
					call	room_each
					ld		hl,room_insert_one
					call	room_each
					jp		redraw_screen		; and all of it drawn, a tile at a time


; Call a routine once for every object in the room. One walk for the three
; passes of room_show, with the routine written into the CALL.
;   HL -> the routine, which gets IX -> the record and may corrupt anything
room_each:			ld		(.call+1),hl
					ld		a,(room_object_count)
					or		a
					ret		z		; DJNZ would take a zero as 256
					ld		b,a
					ld		ix,room_objects
.next:				push	bc
					push	ix
.call:				call	0		; imm: the routine
					pop		ix
					ld		bc,ROOM_STRIDE
					add		ix,bc
					pop		bc
					djnz	.next
					ret


; Into the depth list: the background straight to the front, never compared
; with anything, and everything else sorted.
;   IX -> the record
room_insert_one:	ld		a,(ix+OBJ.FLAGS)
					and		OBJ_BACKGROUND
					jp		nz,background_insert
					jp		depth_insert
