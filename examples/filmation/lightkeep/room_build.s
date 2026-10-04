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
; room, one packed byte each, unpacked in room_unpack below.
;
; See room_data.s, which rooms_source.py generates, for the data itself.
; ---------------------------------------------------------------------------


; What the record said, and how much of it is left to walk.
room_attr:			DB		0
room_scenery_left:	DB		0
room_bytes_left:	DB		0

; Within one object group: how many positions still to place, and the
; template they all share.
room_count_left:	DB		0
room_template:		DW		0
room_packed:		DB		0


; rooms_source.py writes every template's flags byte in OBJ.FLAGS' own layout, so
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


; What drives the group the record belongs to -- see room_behaviour.
room_group_move:	DB		0


; Where each side's doorway leads, indexed by ROOM_DOOR_N/E/S/W: the
; destination byte of the arch in that wall, kept as the scenery goes by for
; player_exit to read. Only a side room_door_z says has a doorway means
; anything; the rest are whatever the last room left.
room_door_to:		DS		4


; ---------------------------------------------------------------------------
; room_find, which looks a record up, is in room_find.s: the rooms are in
; another bank, and it copies the one wanted out into room_record.


; Build a room and draw it.
;
; Everything the previous room owned goes with it: the sorted list is emptied,
; the rotation arena handed back, and the object pool refilled from the start.
;
; In:  A = the room number
; Out: carry set if it was built; carry clear if there is no such room, and
;        the old one is still up
; Corrupts: everything
room_build:			ld		c,a
					call	room_find
					ret		nc		; no such room, and the caller must not go
					; on to put anything in one that was never
					; built: the list is still the old room's,
					; with the old room's objects in it, and
					; adding one that is already there makes it
					; its own successor

					push	hl		; the record
					call	things_gather		; C is still the room: its things,
					call	room_page_fill		; and its sprites

					; Nothing survives a room change.
					call	shift_reset
					depth_reset
					xor		a
					ld		(room_object_count),a
					ld		(room_door_z + ROOM_DOOR_N),a
					ld		(room_door_z + ROOM_DOOR_E),a
					ld		(room_door_z + ROOM_DOOR_S),a
					ld		(room_door_z + ROOM_DOOR_W),a
					ld		(room_behaviour),a
					ld		(room_group_move),a
					; Scenery takes room_weight too, and nothing has set it for this
					; room yet: without this it wore whatever the last room's last
					; mover_find left, which since things are placed last is a
					; table's weight.
					ld		(room_weight),a
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
					add		a,a		; two bytes a scenery entry
					neg
					add		a,c		; and the rest of the body is objects
					ld		(room_bytes_left),a

					; The screen goes black at once, by its attributes, and the room
					; is drawn behind that. start colours it in with room_paper once
					; the knight and the panel are there as well, so a new room
					; appears whole instead of being watched as it draws. Nothing is
					; wiped: redraw_screen writes every pixel there is.
					;
					; Nothing may colour a cell in the meantime, or the panel turns
					; up before the room it belongs to -- and everything that
					; colours one goes through attr_fill. So its
					; first byte is a RET until room_paper puts the LD back, and so
					; is the first of redraw_view's panel hook, which would only
					; draw those again for every tile of the room that reached them.
					push	de
					xor		a
					call	screen_colour
					ld		a,$C9		; RET
					ld		(attr_fill),a
					ld		(redraw_hook),a
					call	room_shape
					pop		de

					ld		ix,room_objects
					call	room_scenery
					call	room_objects_of
					call	room_things_place	; and what was left here: things.s

					call	room_show_backdrop	; room_show, with the walls drawn once
					ld		a,(room_number)
					call	room_seen		; for the percentage at the end
					scf				; built
					ret		


; Wipe the last room off the screen. Only whole rooms are drawn this way --
; once something moves, redraw_view repaints the area it disturbed and nothing
; else -- so the cost of an LDIR here is paid once per room and buys clarity.
;
; In:  nothing
; Out: nothing
; Corrupts: F, BC, DE, HL
room_wipe:			ld		hl,16384
					ld		de,16385
					ld		bc,6143
					ld		(hl),0
					ldir
					ret


; The room's colour over the whole screen. Bits 0-2 of the attribute byte,
; always bright.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, BC, DE, HL
room_paper:			ld		a,ATTR_FILL_ON		; colours may go on again
					ld		(attr_fill),a
					ld		a,REDRAW_HOOK_ON		; and the panel be put back
					ld		(redraw_hook),a
					ld		a,(room_attr)
					and		7
					or		64		; BRIGHT

					;; NB: fall through into screen_colour


; Every attribute cell one colour.
;
; In:  A = the colour
; Out: nothing
; Corrupts: F, BC, DE, HL
screen_colour:		ld		hl,22528
					ld		de,22529
					ld		bc,767
					ld		(hl),a
					ldir
					ret


; The room's shape. Bits 3 and 4 of the attribute byte index room_size_tbl,
; three bytes an entry; above them is the scenery count.
;
; In:  room_attr = the room's attribute byte
; Out: room_half_u, room_half_v, room_floor_z = the room's
; Corrupts: AF, BC, DE, HL
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
					; How far the floor reaches along U and V, measured from the
					; room's centre, and then the floor's own height: three bytes
					; in the table, in the order they are kept in here.
					ASSERT	room_half_v == room_half_u + 1
					ASSERT	room_floor_z == room_half_u + 2
					ld		de,room_half_u
					ld		bc,3
					ldir
					ret


; ---------------------------------------------------------------------------
; The scenery. Each index names a template of pieces, each piece already in
; the eight-byte shape room_add wants, so this is a walk and a call.
;
; In:  DE -> the scenery indices
;      IX -> the first free record
;      room_scenery_left = how many indices
; Out: DE -> the first object byte
;      IX -> the next free record
; Corrupts: AF, BC, HL
room_scenery:		ld		a,(room_scenery_left)
					or		a
					ret		z
					dec		a
					ld		(room_scenery_left),a

					ld		a,(de)
					inc		de
					ld		c,a		; which template, kept for room_door_note
					ld		a,(de)
					inc		de
					ld		b,a		; and where it leads, if it is a doorway
					push	de

					ld		l,c
					ld		h,0
					; Which pieces are background -- walls and trees -- is in their
					; flags already: see rooms_source.py.

					add		hl,hl
					ld		de,room_bg_at		; this room's copies: see room_find
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
; One kind does: the portcullis that hangs in an arch in rooms $09, $CF and
; $F1 is graphic 8, which dispatches to upd_8 exactly as the gate objects do,
; so it rises and falls on the same rules and shares their one-at-a-time
; count. Knight Lore's wizard walked a guard's square as scenery too; he is
; gone from this game.
;
; In:  C = the scenery template index
; Out: room_behaviour = MOVE_GATE or 0
; Corrupts: AF
room_scenery_move:	xor		a
					ld		(room_behaviour),a
					ld		a,c
					sub		BG_GATE_0
					cp		BG_GATE_3 - BG_GATE_0 + 1
					ret		nc
					ld		a,MOVE_GATE
					ld		(room_behaviour),a
					ret		


; If this piece of scenery is a doorway, remember it: which wall, how far out,
; what height, and where it leads.
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
; Which templates are doorways, and in which wall, is scenery_door_side's,
; made from templates.json's meta.doorways, so any template can be one. Knight
; Lore tested the index instead: 0-7 the arches, and two high ones. Where each
; leads is the byte beside the template in the room's record. A doorway leading
; to ROOM_NO_EXIT is walled up: drawn, but not a way through, so it is not
; noted and nothing walks into it.
;
; In:  C  = the scenery template index
;      B  = the room it leads to, or ROOM_NO_EXIT
;      HL -> the template
; Out: room_door_z, room_door_at and room_door_to = the doorway, if it is one
; Corrupts: AF, BC, DE
room_door_note:		ld		a,b
					cp		ROOM_NO_EXIT
					ret		z		; no way out here, whatever is drawn
					ld		e,c
					ld		d,0
					push	hl
					ld		hl,scenery_door_side
					add		hl,de
					ld		a,(hl)		; its wall, or SCENERY_NOT_A_DOORWAY
					or		a
					jp		m,.not
					ld		e,a
					ld		hl,room_door_to
					add		hl,de
					ld		(hl),b
.not:				pop		hl
					ret		m
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
; The objects. These come in groups: the template's index, how many of it,
; then that many packed positions.
;
;   type   the first byte: any of up to 256 object templates
;   count  the second: how many, one to eight, less one, in bits 0-2, and a
;          shift in Z in bits 3-7 -- signed, 4 units a step -- which goes on
;          every object of the group (room_group_dz)
;
; Knight Lore packs both into one byte, the type in bits 3-7 and the count less
; one in bits 0-2, which reaches only 32 templates. It has 29; with Pentagram's
; there are 57, so a group costs one byte more here.
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
;
; In:  DE -> the object bytes
;      IX -> the next free record
;      room_bytes_left = how many bytes
; Out: DE -> past the last of them
;      IX -> the next free record
; Corrupts: AF, BC, HL
room_objects_of:	ld		a,(room_bytes_left)
					or		a
					ret		z
					dec		a
					ld		(room_bytes_left),a

					ld		a,(de)		; the template's index
					inc		de
					ld		c,a
					ld		a,(de)		; and how many of it: two bytes, where
					inc		de		; Knight Lore packs both into one that
					ld		b,a		; holds only 32 templates
					and		7		; how many, less one
					inc		a
					ld		(room_count_left),a
					ld		a,b		; and the five bits above it, a shift in
					and		$F8		; Z in steps of 4: as they lie that is
					sra		a		; eight a step, signed, so one SRA
					ld		(room_group_dz),a
					ld		hl,room_bytes_left
					dec		(hl)		; the second of them
					ld		a,c

					push	de
					push	af
					call		mover_find
					ld		(room_group_move),a
					pop		af
					ld		l,a
					ld		h,0
					add		hl,hl
					ld		de,room_fg_at
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
;
; It is two steps: the position byte into a place in the room -- the base the
; template's offsets go on, in room_base_u, room_base_v and room_base_z -- and
; then the entry at that place. A thing (things.s) keeps its base in its entry
; instead of a packed byte, and goes in at the second step.
;
; In:  HL -> sprite, size U, size V, size Z, flags, offsets
;      room_packed = the position byte
; Out: room_stage = the eight bytes
; Corrupts: AF, BC, DE
room_unpack:		ld		a,(room_packed)
					and		7
					add		a,a
					add		a,a
					add		a,a
					add		a,a		; cell * 16
					add		a,72
					ld		(room_base_u),a

					ld		a,(room_packed)
					rrca
					rrca
					rrca
					and		7
					add		a,a
					add		a,a
					add		a,a
					add		a,a
					add		a,72
					ld		(room_base_v),a

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
					ld		b,a
					ld		a,(room_group_dz)	; the group's shift, which can
					add		a,b		; put it between the levels,
					ld		b,a		; above them, or below the floor
					ld		a,(room_floor_z)
					add		a,b
					ld		(room_base_z),a

					;; NB: fall through into room_unpack_base


; One template entry at a place in the room: its half-cell nudges and its
; height above the base added on. The level is a multiple of 12, so adding the
; offsets byte with its two nudge bits masked off is the same sum Knight Lore
; makes, which adds the byte and masks the total.
;
; In:  HL -> sprite, size U, size V, size Z, flags, offsets
;      room_base_u, room_base_v, room_base_z = the place
; Out: room_stage = the eight bytes
; Corrupts: AF, BC, DE
room_unpack_base:	push	hl
					ld		a,(hl)
					ld		(room_stage + 0),a		; sprite
					inc		hl
					ld		de,room_stage + 4		; size U, size V, size Z and
					ld		bc,4		; the flags, in that order in both
					ldir		; (DE is the caller's and already on the stack)
					ld		c,(hl)		; the offsets byte

					ld		a,(room_base_u)
					bit		0,c
					jr		z,.no_half_u
					add		a,8
.no_half_u:			ld		(room_stage + 1),a		; U

					ld		a,(room_base_v)
					bit		1,c
					jr		z,.no_half_v
					add		a,8
.no_half_v:			ld		(room_stage + 2),a		; V

					ld		a,c
					and		$FC		; the template's own offset, without the nudges
					ld		b,a
					ld		a,(room_base_z)
					add		a,b
					ld		(room_stage + 3),a		; Z

					pop		hl
					ret

room_base_u:		DB		0
room_base_v:		DB		0
room_base_z:		DB		0

; The shift in Z of the group being placed, from the top five bits of its count
; byte: signed, in units, a multiple of 4 from -64 to +60. The room designer
; puts an object in such a group when it stands off the four levels.
room_group_dz:		DB		0


LIVES_AT			EQU		$4000 + 2 * 2048 + 3 * 32 + 4	; row 19, print_lives

; ---------------------------------------------------------------------------
; The lives in their place on the panel, and -- in a build with
; DEBUG_ROOM defined, `build.py --debug-room` -- the room number in the top-left
; corner, for finding your way about.
;
; Printed every turn rather than once when the room is built, because a redraw
; region that reaches them would otherwise wipe them, and it keeps the numbers
; right without anything else having to ask.
;
; Straight to the screen, byte-aligned, no mask.
;
; In:  nothing
; Out: nothing
; Corrupts: AF, B, DE, HL
print_room:			ld		a,(player_lives)
					ld		hl,LIVES_AT
				IFDEF	DEBUG_ROOM
					call	print_hex
					ld		a,(room_shown)
					ld		hl,$4000		; the top-left character cell
				ENDIF

					;; NB: fall through into print_hex


; A byte as two digits.
;
; In:  A  = the byte
;      HL -> the top row of the first cell
; Out: nothing
; Corrupts: AF, B, DE, HL
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
;
; In:  A  = which character
;      HL -> the top row of its cell
; Out: DE -> past the glyph
; Corrupts: AF, B, H
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

					;; NB: fall through into print_glyph


; Eight rows of a glyph.
;
; In:  DE -> the glyph
;      HL -> the top row of its cell
; Out: DE -> past it
; Corrupts: AF, B, H
print_glyph:		ld		b,8
.row:				ld		a,(de)
					ld		(hl),a
					inc		de
					inc		h		; the next pixel row of the same cell
					djnz	.row
					ret
