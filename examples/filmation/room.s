; ---------------------------------------------------------------------------
; Building a room.
;
; Knight Lore does not store rooms as lists of objects. A room is an attribute
; byte and a handful of indices naming templates that the whole castle shares:
; room $B3 is arch north, arch east, arch south and the walls for a square
; room, and those four expand into 19 objects. This is that expansion.
;
; Scenery templates carry their own positions, so a piece is copied almost
; field for field into an object record. Object templates do not -- one block
; template serves every block in the castle -- so their positions come from the
; room, one packed byte each, unpacked in room_objects below.
;
; See room_data.s, which rooms.py generates, for the data itself.
; ---------------------------------------------------------------------------

; The Z of a room's floor, from room_size_tbl. Object positions are measured
; up from it; scenery carries absolute Z and does not need it.
room_floor_z:		DB		0

; What the record said, and how much of it is left to walk.
room_attr:			DB		0
room_scenery_left:	DB		0
room_bytes_left:	DB		0

; Within one object group: how many positions still to place, and the
; template they all share.
room_count_left:	DB		0
room_template:		DW		0
room_packed:		DB		0

; How many objects the room has produced so far.
room_object_count:	DB		0

; Whether the scenery template being expanded is background -- OBJ_BACKGROUND
; or zero. room_add ors it into each piece's FLAGS.
room_bg_flag:		DB		0

; An object on its way into a record: sprite, U, V, Z, size U, size V, size Z,
; flags -- the same eight bytes a scenery piece already is, which is why both
; paths can share room_add.
room_stage:			DS		8


; ---------------------------------------------------------------------------
; Build a room and draw it.
;   A = room number
;
; Everything the previous room owned goes with it: the sorted list is emptied,
; the rotation arena handed back, and the object pool refilled from the start.
room_build:			ld		l,a
					ld		h,0
					add		hl,hl
					ld		de,room_tbl
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		a,d
					or		e
					ret		z		; no such room. OR clears the carry, and the
					; caller must not go on to put anything in
					; a room that was never built: the list is
					; still the old room's, with the old room's
					; objects in it, and adding one that is
					; already there makes it its own successor

					push	de		; the record

					; Nothing survives a room change.
					call	shift_reset
					ld		hl,0
					ld		(object_list),hl
					ld		hl,object_list
					ld		(sort_head),hl
					xor		a
					ld		(room_object_count),a

					pop		de
					ld		a,(de)
					ld		(room_attr),a
					inc		de
					ld		a,(de)
					ld		(room_scenery_left),a
					inc		de
					ld		a,(de)
					ld		(room_bytes_left),a
					inc		de		; -> the scenery indices

					push	de
					call	room_wipe
					call	room_paper
					call	room_shape
					pop		de

					ld		ix,room_objects
					call	room_scenery
					xor		a
					ld		(room_bg_flag),a		; nothing past the scenery is
					call	room_objects_of		; background

					call	room_show
					scf				; built
					ret		


; Wipe the last room off the screen. Only whole rooms are drawn this way --
; once something moves, redraw_view repaints the area it disturbed and nothing
; else -- so the cost of an LDIR here is paid once per room and buys clarity.
room_wipe:			ld		hl,16384
					ld		de,16385
					ld		bc,6143
					ld		(hl),0
					ldir
					ret


; The room's colour. Bits 0-2 of the attribute byte, always bright.
room_paper:			ld		a,(room_attr)
					and		7
					or		64		; BRIGHT
					ld		hl,22528
					ld		de,22529
					ld		bc,767
					ld		(hl),a
					ldir
					ret


; The room's shape. Bits 3 and up of the attribute byte index room_size_tbl,
; three bytes an entry; only the floor height is wanted here.
room_shape:			ld		a,(room_attr)
					rrca
					rrca
					rrca
					and		$1F
					ld		l,a
					add		a,a
					add		a,l		; index * 3
					ld		l,a
					ld		h,0
					ld		de,room_size_tbl
					add		hl,de
					inc		hl
					inc		hl		; -> the Z of this shape
					ld		a,(hl)
					ld		(room_floor_z),a
					ret


; ---------------------------------------------------------------------------
; The scenery. Each index names a template of pieces, each piece already in
; the eight-byte shape room_add wants, so this is a walk and a call.
;   DE -> the scenery indices
; Leaves DE on the first object byte.
room_scenery:		ld		a,(room_scenery_left)
					or		a
					ret		z
					dec		a
					ld		(room_scenery_left),a

					ld		a,(de)
					inc		de
					push	de

					ld		l,a
					ld		h,0

					; Walls and trees are scenery: solid, never walked through,
					; and so never worth sorting against anything. Arches and
					; gates are doorways the player passes behind, and the
					; wizard and the pot are objects in their own right -- all
					; of those keep their place in the sort.
					cp		BG_WALLS_0
					jr		c,.sorted
					cp		BG_TREES_2 + 1
					jr		nc,.sorted
					ld		a,OBJ_BACKGROUND
					jr		.classified
.sorted:			xor		a
.classified:		ld		(room_bg_flag),a

					add		hl,hl
					ld		de,background_type_tbl
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ex		de,hl		; -> the template

.piece:				ld		a,(hl)
					or		a		; a zero sprite ends it
					jr		z,.done
					call	room_add
					jr		.piece

.done:				pop		de
					jr		room_scenery


; ---------------------------------------------------------------------------
; The objects. These come in groups: a byte giving the template and how many
; of them, then that many packed positions.
;
;   type   bits 3-7 of the group byte
;   count  bits 0-2, plus one -- so one to eight
;
; and a position byte is three cells of U, three of V and two levels of Z:
;
;   U = (byte & 7) * 16       + a half cell if the template asks + 72
;   V = (byte >> 3 & 7) * 16  + a half cell if the template asks + 72
;   Z = (byte >> 6 & 3) * 12  + the template's own offset, up from the floor
;
; The template's last byte carries all three nudges at once: bit 0 for U,
; bit 1 for V, and the whole byte is added into Z with those two bits masked
; off again afterwards.
;   DE -> the object bytes
room_objects_of:	ld		a,(room_bytes_left)
					or		a
					ret		z
					dec		a
					ld		(room_bytes_left),a

					ld		a,(de)		; the group byte
					inc		de
					ld		c,a
					and		7
					inc		a
					ld		(room_count_left),a
					ld		a,c
					rrca
					rrca
					rrca
					and		$1F		; the template index

					push	de
					ld		l,a
					ld		h,0
					add		hl,hl
					ld		de,block_type_tbl
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ld		(room_template),de
					pop		de

.position:			ld		a,(room_count_left)
					or		a
					jr		z,room_objects_of
					dec		a
					ld		(room_count_left),a
					ld		a,(room_bytes_left)
					or		a
					ret		z		; the record ran out mid-group
					dec		a
					ld		(room_bytes_left),a

					ld		a,(de)
					ld		(room_packed),a
					inc		de

					push	de
					ld		hl,(room_template)

					; A template may hold several sprites -- a guard is drawn
					; from two -- and they all sit at this one position.
.entry:				ld		a,(hl)
					or		a
					jr		z,.entry_done
					call	room_unpack
					push	hl
					ld		hl,room_stage
					call	room_add
					pop		hl
					ld		bc,6
					add		hl,bc		; on to the next sprite of the template
					jr		.entry

.entry_done:		pop		de
					jr		.position


; Turn one template entry plus the packed position into the eight bytes
; room_add takes.
;   HL -> sprite, size U, size V, size Z, flags, offsets
; Preserves HL.
room_unpack:		push	hl
					ld		a,(hl)
					ld		(room_stage + 0),a		; sprite
					inc		hl
					ld		a,(hl)
					ld		(room_stage + 4),a		; size U
					inc		hl
					ld		a,(hl)
					ld		(room_stage + 5),a		; size V
					inc		hl
					ld		a,(hl)
					ld		(room_stage + 6),a		; size Z
					inc		hl
					ld		a,(hl)
					ld		(room_stage + 7),a		; flags
					inc		hl
					ld		c,(hl)		; the offsets byte

					ld		a,(room_packed)
					and		7
					add		a,a
					add		a,a
					add		a,a
					add		a,a		; cell * 16
					bit		0,c
					jr		z,.no_half_u
					add		a,8
.no_half_u:			add		a,72
					ld		(room_stage + 1),a		; U

					ld		a,(room_packed)
					rrca
					rrca
					rrca
					and		7
					add		a,a
					add		a,a
					add		a,a
					add		a,a
					bit		1,c
					jr		z,.no_half_v
					add		a,8
.no_half_v:			add		a,72
					ld		(room_stage + 2),a		; V

					ld		a,(room_packed)
					rlca
					rlca
					and		3		; the level
					ld		b,a
					add		a,a
					add		a,a		; * 4
					add		a,b
					add		a,b		; ...* 6
					add		a,a		; ...* 12
					add		a,c		; plus the template's own offset
					and		$FC		; and drop the two nudge bits again
					ld		b,a
					ld		a,(room_floor_z)
					add		a,b
					ld		(room_stage + 3),a		; Z

					pop		hl
					ret


; ---------------------------------------------------------------------------
; Fill one object record.
;   HL -> sprite, U, V, Z, size U, size V, size Z, flags
;   IX -> the record
; Advances HL past the eight bytes and IX to the next record.
room_add:			ld		a,(room_object_count)
					cp		ROOM_MAX_OBJECTS
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

					; Their mirror flag is bit 6; ours is bit 0, next to the
					; sprite header's so that comparing them is one XOR.
					rlca
					rlca
					and		OBJ_FLIP_H
					ld		(ix+OBJ.FLAGS),a
					ld		a,(room_bg_flag)		; and whether this template is
					or		(ix+OBJ.FLAGS)		; scenery rather than an object
					ld		(ix+OBJ.FLAGS),a

					; A rotation buffer belongs to the room, not the object;
					; shift_reset has just taken the last room's back.
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
					ld		a,(ix+OBJ.FLAGS)
					and		OBJ_FLIP_H
					ld		hl,sprite_adj
					jr		z,.table
					ld		hl,sprite_adj_flipped
.table:				ld		c,(ix+OBJ.GFX)
					ld		b,0
					add		hl,bc
					add		hl,bc		; + graphic * 2
					ld		a,(hl)
					ld		(ix+OBJ.ADJ_X),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.ADJ_Y),a
					pop		hl
					ret


; ---------------------------------------------------------------------------
; Place every object, sort them, and paint the room.
;
; Placement has to finish before any insertion, so that every depth comparison
; sees real coordinates; and everything is placed before anything is drawn, so
; that the first object painted already has the rest behind it.
room_show:			ld		a,(room_object_count)
					or		a
					ret		z
					ld		b,a
					ld		ix,room_objects
.place:				push	bc
					ld		a,(ix+OBJ.GFX)
					call	object_place
					ld		bc,ROOM_STRIDE
					add		ix,bc
					pop		bc
					djnz	.place

					ld		a,(room_object_count)
					ld		b,a
					ld		ix,room_objects
.insert:			push	bc
					push	ix
					ld		a,(ix+OBJ.FLAGS)
					and		OBJ_BACKGROUND
					jr		z,.sort_it
					call	background_insert		; straight to the front, never
					jr		.inserted		; compared with anything
.sort_it:			call	depth_insert
.inserted:			pop		ix
					ld		bc,ROOM_STRIDE
					add		ix,bc
					pop		bc
					djnz	.insert

					ld		a,(room_object_count)
					ld		b,a
					ld		ix,room_objects
.draw:				push	bc
					push	ix
					call	redraw_object
					pop		ix
					ld		bc,ROOM_STRIDE
					add		ix,bc
					pop		bc
					djnz	.draw
					ret
