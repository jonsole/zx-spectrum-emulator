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

; rooms.py writes every template's flags byte in OBJ.FLAGS' own layout, so
; room_add copies it straight in. These are what it wrote them with.
					ASSERT	ROOM_FLAG_FLIP == OBJ_FLIP_H
					ASSERT	ROOM_FLAG_PASSABLE == OBJ_PASSABLE
					ASSERT	ROOM_FLAG_SHARED_SHIFT == OBJ_SHARED_SHIFT
					ASSERT	ROOM_FLAG_CACHE == OBJ_CACHE
					ASSERT	ROOM_FLAG_BACKGROUND == OBJ_BACKGROUND

; An object on its way into a record: sprite, U, V, Z, size U, size V, size Z,
; flags -- the same eight bytes a scenery piece already is, which is why both
; paths can share room_add.
room_stage:			DS		8


; What drives the record room_add is about to fill in, and what drives the
; group it belongs to. Only the FIRST sprite of an object is given the
; behaviour -- a guard is drawn from two records and only one of them may be
; the one that walks.
room_behaviour:		DB		0
room_group_move:	DB		0


; ---------------------------------------------------------------------------
; Find a room's record, by walking the list and comparing each record's own
; number. That is how Knight Lore does it -- find_screen at $D3CF -- and for
; the reason its author will have had: an index over all 256 numbers is 512
; bytes to hold 128 rooms, and half of it is zero. The walk is a few hundred
; T-states and it happens once, when the room changes.
;
; Each record says how far it is to the next, so a step is one add. And it
; never has to ask whether the list has ended: the records are in ascending
; order and the last one is room $FF -- rooms.py asserts both -- so the walk
; always reaches a number at least the one it wants, and stops there.
;
;   C  - the room wanted
; Out: cf set and HL -> its record; cf clear if there is no such room.
; Corrupts AF, DE, HL.
room_find:			ld		hl,room_list
					ld		d,0
.next:				ld		a,(hl)
					cp		c
					jr		nc,.here		; this room, or already past it
					inc		hl
					ld		e,(hl)		; the skip, counted from its own byte
					add		hl,de
					jr		.next
.here:				ret		nz		; past it: no such room, and cf is clear
					scf
					ret


; Build a room and draw it.
;   A = room number
;
; Everything the previous room owned goes with it: the sorted list is emptied,
; the rotation arena handed back, and the object pool refilled from the start.
room_build:			ld		c,a
					call	room_find
					ret		nc		; no such room, and the caller must not go
					; on to put anything in one that was never
					; built: the list is still the old room's,
					; with the old room's objects in it, and
					; adding one that is already there makes it
					; its own successor

					push	hl		; the record

					; Nothing survives a room change.
					call	shift_reset
					ld		hl,0
					ld		(object_list),hl
					ld		hl,object_list
					ld		(sort_head),hl
					xor		a
					ld		(room_object_count),a
					ld		(room_door_z + ROOM_DOOR_N),a
					ld		(room_door_z + ROOM_DOOR_E),a
					ld		(room_door_z + ROOM_DOOR_S),a
					ld		(room_door_z + ROOM_DOOR_W),a
					ld		(room_behaviour),a
					ld		(room_group_move),a
					ld		(mover_ball_top),a
					ld		(mover_gate_busy),a
					ld		(mover_gate_drops),a
					ld		(spike_ball_falling),a
					ld		a,(room_number)
					and		1
					ld		(spike_ball_held),a

					pop		de
					inc		de		; past its own number
					ld		a,(de)
					sub		2		; the skip, less the rest of the header:
					ld		c,a		; the body
					inc		de
					ld		a,(de)
					ld		(room_attr),a
					inc		de		; -> the scenery indices
					ASSERT	ROOM_SCN_SHIFT == 5
					rlca
					rlca
					rlca		; three left is five right
					and		7
					ld		(room_scenery_left),a
					neg
					add		a,c		; and the rest of the body is objects
					ld		(room_bytes_left),a

					push	de
					call	room_wipe
					call	room_paper
					call	room_shape
					pop		de

					ld		ix,room_objects
					call	room_scenery
					call	room_objects_of

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
r					ldir
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


; The room's shape. Bits 3 and 4 of the attribute byte index room_size_tbl,
; three bytes an entry; above them is the scenery count.
room_shape:			ld		a,(room_attr)
					rrca
					rrca
					rrca
					and		3
					ld		l,a
					add		a,a
					add		a,l		; index * 3
					ld		l,a
					ld		h,0
					ld		de,room_size_tbl
					add		hl,de
					ld		a,(hl)		; how far the floor reaches along U,
					ld		(room_half_u),a		; measured from the room's centre
					inc		hl
					ld		a,(hl)
					ld		(room_half_v),a
					inc		hl
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
					ld		c,a		; which template, kept for room_door_note

					ld		l,a
					ld		h,0
					; Which pieces are background -- walls and trees -- is in their
					; flags already: see rooms.py.

					add		hl,hl
					ld		de,background_type_tbl
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ex		de,hl		; -> the template
					call	room_scenery_move	; before room_door_note, which takes C
					call		room_door_note

.piece:				ld		a,(hl)
					or		a		; a zero sprite ends it
					jr		z,.done
					call	room_add
					xor		a
					ld		(room_behaviour),a	; only the first piece drives
					jr		.piece

.done:				pop		de
					jr		room_scenery


; Does this piece of scenery move?
;
; Two kinds do. The portcullis that hangs in an arch in rooms $09, $CF and $F1
; is graphic 8, which dispatches to upd_8 exactly as the gate objects do, so it
; rises and falls on the same rules and shares their one-at-a-time count.
;
; And the wizard walks the same square circuit a guard does -- graphics
; 30, 31, 158 and 159 all dispatch to upd_30_31_158_159, and the routine it
; turns on is called move_guard_wizard_NSEW, which says as much. He is scenery
; rather than an object only because that is where the room data puts him.
;
; His two pieces are eight units apart in the template, where a guard's sit on
; top of each other. It does not matter: mover_move_pair copies the torso's U
; and V down to the legs every turn, so they are together from his first step.
;   C  - the scenery template index
; Corrupts AF.
room_scenery_move:	xor		a
					ld		(room_behaviour),a
					ld		a,c
					sub		BG_GATE_0
					cp		BG_GATE_3 - BG_GATE_0 + 1
					ld		a,MOVE_GATE
					jr		c,.moves
					ld		a,c
					cp		BG_WIZARD
					ret		nz
					ld		a,MOVE_GUARD_SQ
.moves:				ld		(room_behaviour),a
					ret		


; If this piece of scenery is an arch, remember the doorway it makes.
;
; Knight Lore keeps the same three facts -- which side, how far out, what
; height -- but reaches them from the other end: each arch is an object with
; an update routine, and that routine walks the characters every frame and
; marks any one standing in its opening ($C7DB). Ours cannot, because our
; scenery has no update routines; but an arch never moves, so the answer is
; the same all room long and is worth working out once.
;
; The first piece of an arch template is the one the game measures from --
; its opening is centred thirteen units from that leaf, which is the middle
; of the room -- so its position is the one to keep.
;
;   C  - the scenery template index
;   HL -> the template
; Corrupts AF and BC. HL comes back where it was.
room_door_note:		ld		a,c
					cp		8		; 0-7 are the four arches, plain and
					jr		c,.plain		; among the trees; the side is in bit 0-1
					cp		BG_HIGH_ARCH_E
					ret		c
					cp		BG_HIGH_ARCH_S + 1
					ret		nc		; not an arch at all
					; The two high arches are a doorway on the walkway of a
					; tall room, and they only ever face east or south.
					sub		BG_HIGH_ARCH_E - ROOM_DOOR_E
					jr		.have
.plain:				and		3
.have:				push	hl
					ld		c,a
					ld		b,0

					inc		hl
					inc		hl
					inc		hl		; sprite, U, V, Z
					ld		a,(hl)
					push	hl
					ld		hl,room_door_z
					add		hl,bc
					ld		(hl),a
					pop		hl

					; North and south face along V, east and west along U.
					dec		hl		; -> V
					bit		0,c
					jr		z,.along
					dec		hl		; -> U
.along:				ld		a,(hl)
					ld		hl,room_door_at
					add		hl,bc
					ld		(hl),a
					pop		hl
					ret		


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
					push	af
					call		mover_find
					ld		(room_group_move),a
					pop		af
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
					ld		a,(room_group_move)
					ld		(room_behaviour),a

					; A template may hold several sprites -- a guard is drawn
					; from two -- and they all sit at this one position.
.entry:				ld		a,(hl)
					or		a
					jr		z,.entry_done
					call	room_unpack
					push	hl
					ld		hl,room_stage
					call	room_add
					xor		a
					ld		(room_behaviour),a	; only the first sprite drives
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
					ld		hl,redraw_object
					;; NB: fall through into room_each


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


; ---------------------------------------------------------------------------
; The room number in the top-left corner, for finding your way about.
;
; Printed every turn rather than once when the room is built, because a redraw
; region that reaches the corner would otherwise wipe it and it would not come
; back until the next room.
;
; Straight to the screen, byte-aligned, no mask: it is a debug read-out and
; whatever it lands on is meant to be covered.
DEBUG_AT			EQU		$4000		; the top-left character cell

print_room:			ld		a,(days)		; the day, top right
					ld		hl,DEBUG_AT + 27
					call	print_hex
					ld		a,(player_lives)		; and the lives beside it
					ld		hl,DEBUG_AT + 30
					call	print_hex
					ld		a,(room_shown)
					ld		hl,DEBUG_AT

					;; NB: fall through into print_hex


; A byte as two digits.
;   A  - the byte, HL -> the top row of the first cell
; Corrupts AF, BC, DE, HL.
print_hex:			push	af
					push	hl
					rrca
					rrca
					rrca
					rrca
					and		$0F
					call	print_char
					pop		hl
					inc		hl
					pop		af
					and		$0F

					;; NB: fall through into print_char


; One character of the font, eight rows of it.
;   A  - which character, HL -> the top row of its cell
; Corrupts AF, BC, DE, HL.
print_char:			push	hl
					ld		l,a
					ld		h,0
					add		hl,hl
					add		hl,hl
					add		hl,hl		; eight bytes a character
					ld		de,font
					add		hl,de
					ex		de,hl		; de -> the glyph
					pop		hl		; hl -> the screen

					ld		b,8
.row:				ld		a,(de)
					ld		(hl),a
					inc		de
					inc		h		; the next pixel row of the same cell
					djnz	.row
					ret		


; ---------------------------------------------------------------------------
; The collectables, at the moments the room changes -- see special.s for the
; rest of them.

; Deal the collectables out, at the start of every game. init_special_objects gives
; each row a graphic by counting on from a random number, so the kinds come
; round in turn and every game puts them in different places; and
; shuffle_objects_required turns the wizard's list round four to seven places.
special_init:		ld		hl,special_where_start		; every collectable back where it
					ld		de,special_where		; began, nothing carried and
					ld		bc,SPECIAL_ROWS * 4		; nothing delivered
					ldir
					xor		a
					ld		(special_count),a
					ld		(special_busy),a
					ld		(special_key_held),a
					ld		h,a
					ld		l,a
					ld		(special_slots),hl
					ld		hl,special_carried
					ld		b,8
.empty:				ld		(hl),a
					inc		hl
					djnz	.empty

					ld		a,r
					ld		e,a
					ld		hl,special_gfx
					ld		b,SPECIAL_ROWS
.deal:				ld		a,e
					and		7
					or		SPECIAL_FIRST
					ld		(hl),a
					inc		hl
					inc		e
					djnz	.deal

					ld		a,r
					and		3
					or		4
.turn:				push	af
					ld		hl,special_wanted + 1
					ld		de,special_wanted
					ld		a,(de)
					ld		bc,SPECIAL_WANTED - 1
					ldir
					ld		(de),a
					pop		af
					dec		a
					jr		nz,.turn
					ret


; Write back whatever is lying in the room being left. update_special_objs.
; Something on its way into the pot is not lying anywhere, and nothing in the
; second slot of the pot's room belongs to the table.
special_room_leave:	ld		ix,(special_slots)
					ld		a,ixh
					or		a
					ret		z		; no room yet
					ld		b,SPECIAL_SLOTS
.slot:				ld		a,(ix+OBJ.GFX)
					sub		SPECIAL_FIRST
					cp		8
					jr		nc,.next
					ld		c,(ix+OBJ.MOVE_STATE)
					ld		e,c
					ld		d,0
					ld		hl,special_gfx
					add		hl,de
					ld		a,(ix+OBJ.GFX)
					ld		(hl),a
					call	special_where_of
					ld		a,(ix+OBJ.U)
					ld		(hl),a
					inc		hl
					ld		a,(ix+OBJ.V)
					ld		(hl),a
					inc		hl
					ld		a,(ix+OBJ.Z)
					ld		(hl),a
					inc		hl
					ld		a,(special_room)
					ld		(hl),a
.next:				ld		de,ROOM_STRIDE
					add		ix,de
					djnz	.slot
					ret


; Put the room's collectables in it: the next two records after everything
; the room data made, filled from any rows naming this room. find_special_objs_here.
; Runs after room_show, so each one is placed, sorted and drawn here.
special_room_enter:	xor		a
					ld		(special_busy),a
					ld		a,(room_shown)
					ld		(special_room),a
					ld		a,(room_object_count)
					ld		l,a
					ld		h,0
					add		hl,hl
					add		hl,hl
					add		hl,hl
					add		hl,hl
					add		hl,hl		; * ROOM_STRIDE
					ld		de,room_objects
					add		hl,de
					ld		(special_slots),hl
					push	hl
					pop		ix
					ld		b,SPECIAL_SLOTS
.blank:				call	special_blank
					ld		(ix+OBJ.BUF_L),0
					ld		(ix+OBJ.BUF_H),0
					ld		(ix+OBJ.NEXT),0		; not in the list, which the
					ld		(ix+OBJ.NEXT+1),0	; twin scan does not ask but a
					ld		de,ROOM_STRIDE		; reader of the pool might
					add		ix,de
					djnz	.blank
					ld		a,(room_object_count)
					add		a,SPECIAL_SLOTS
					ld		(room_object_count),a

					ld		ix,(special_slots)
					ld		c,0
.row:				ld		hl,special_gfx
					ld		b,0
					add		hl,bc
					ld		a,(hl)
					or		a
					jr		z,.next
					push	af		; the graphic
					call	special_where_of
					inc		hl
					inc		hl
					inc		hl
					ld		a,(room_shown)
					cp		(hl)
					jr		z,.here
					pop		af
					jr		.next
.here:				dec		hl
					dec		hl
					dec		hl
					pop		af
					push	bc
					push	ix
					ld		b,MOVE_SPECIAL
					call	special_fill
					pop		ix
					pop		bc
					ld		de,ROOM_STRIDE
					add		ix,de
					ld		a,ixl
					ld		hl,(special_slots)
					sub		l
					cp		ROOM_STRIDE * SPECIAL_SLOTS
					jr		z,.shown		; both slots taken
.next:				inc		c
					ld		a,c
					cp		SPECIAL_ROWS
					jr		c,.row
.shown:				jp		special_show


; Where a row says its collectable is.
;   C - the row
; Out: HL -> its U, V, Z and room. Corrupts AF, DE.
special_where_of:	ld		a,c
					add		a,a
					add		a,a
					ld		e,a
					ld		d,0
					ld		hl,special_where
					add		hl,de
					ret


; Fill a collectable slot and put it in the room.
;   IX -> the slot
;   A  - the graphic, B - its behaviour, C - its table row
;   HL -> U, V and Z
; Corrupts everything, IX included.
special_fill:		ld		(ix+OBJ.GFX),a
					ld		(ix+OBJ.BEHAVIOUR),b
					ld		(ix+OBJ.MOVE_STATE),c
					ld		a,(hl)
					ld		(ix+OBJ.U),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.V),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.Z),a
					ld		(ix+OBJ.SIZE_U),SPECIAL_SIZE_UV
					ld		(ix+OBJ.SIZE_V),SPECIAL_SIZE_UV
					ld		(ix+OBJ.SIZE_Z),SPECIAL_SIZE_Z
					xor		a
					ld		(ix+OBJ.FLAGS),a
					ld		(ix+OBJ.DU),a
					ld		(ix+OBJ.DV),a
					ld		(ix+OBJ.DZ),a

					; One buffer for the life of the room, sized for the largest thing
					; a slot can show -- every one of them is three bytes by 24 rows at
					; most -- because a slot changes graphic and object_update would
					; size one for whatever it happened to be carrying first. If the
					; arena cannot spare it, rotate at draw time rather than risk a
					; buffer too small.
					ld		a,(ix+OBJ.BUF_H)
					or		a
					jr		nz,.buffered
					ld		hl,sprite_035
					call	shift_alloc		; OBJ_SHARED_SHIFT if there is none
.buffered:			call	room_adjust
					call	object_place
					call	depth_insert
					jp		redraw_object
