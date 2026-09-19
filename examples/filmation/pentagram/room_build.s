; Building a room, adapted from ../knightlore/room_build.s.
;
; The two games' room formats are the same shape -- a directory of records each
; carrying its own number and a skip, an attribute holding colour and shape, a
; scenery section and then object groups -- so most of this is Knight Lore's
; code with the labels changed. Three things genuinely differ, and they are
; the only places worth reading carefully:
;
;   * A scenery entry is TWO bytes here, not one: the template index, then the
;     room a doorway leads to, or zero. room_scenery steps by two and hands the
;     second byte to room_door_note.
;
;   * The scenery count in the attribute is stored LESS ONE. Rooms hold three
;     to eight entries and eight will not fit in three bits, so rooms_source.py
;     biases it; room_build adds ROOM_SCN_BIAS back.
;
;   * Doorways are a LOOKUP, not arithmetic. Knight Lore's castle is a 16x16
;     grid, so it works the next room out with an add: north is +$10, east is
;     the low nibble +1. Pentagram's map is not a grid -- forty distinct deltas
;     between a room and its neighbours, and thirteen different ones for a
;     single doorway direction -- so the destination is read from the record
;     and kept in room_door_to, which player_exit indexes by side.
;
; The doorway templates are scenery indices 0-7 and 24-27, twelve of them in
; three sets of four, and the side is `index & 3` as 0=N, 1=E, 2=S, 3=W. That
; is the engine's own convention -- see the note above ROOM_DOOR_N in
; ../engine/room.s, which says the index falls out of the bottom two bits.
;
; The destination byte is the authority, not the template: one south doorway is
; an exit in twenty-eight rooms and blocked in one, so a zero there means no
; way out even though the arch is drawn.

room_attr:			DB		0
room_scenery_left:	DB		0
room_bytes_left:	DB		0
room_count_left:	DB		0
room_template:		DW		0
room_packed:		DB		0
room_dest:			DB		0		; the destination byte of the entry in hand

; Where each side leads, indexed by ROOM_DOOR_N/E/S/W. Zero means the side has
; no way out. Knight Lore has no equivalent because it computes the answer.
room_door_to:		DS		4

; Where each side's opening is centred along its wall: U for north and south,
; V for east and west. Knight Lore's are all at 128, the middle of the wall,
; and the engine's own doorway test assumes so. Pentagram's are not: its third
; set of doorways, 24-27, is raised to Z 176 on a walkway and stands off to one
; side, centred on 96 or 160 -- so the player's doorway test, his steering and
; where he walks in all read the centre from here instead. Only meaningful
; where room_door_z says there is a door.
room_door_mid:		DS		4

; A doorway's two pieces stand thirteen either side of its centre, and the
; first one in the template is on the low side for north and south and the
; high side for east and west -- true of all twelve doorway templates.
ROOM_DOOR_HALF		EQU		13

; A piece, staged in the eight-byte shape room_add wants.
room_stage:			DS		8


; ---------------------------------------------------------------------------
; Find a room's record.
;
; Each record says how far it is to the next, so a step is one add.
;
;   C  - the room wanted
; Out: cf set and HL -> its record; cf clear if there is no such room.
; Corrupts AF, DE, HL.
room_find:			ld		hl,room_list
					ld		d,0
					ld		b,ROOM_COUNT
.next:				ld		a,(hl)
					cp		c
					jr		z,.here
					inc		hl
					ld		e,(hl)		; the skip, counted from its own byte
					add		hl,de
					djnz	.next
					or		a		; ran off the end: no such room
					ret
.here:				scf
					ret


; ---------------------------------------------------------------------------
; Build a room and draw it.
;   A = room number
;
; Everything the previous room owned goes with it: the sorted list is emptied,
; the rotation arena handed back, and the object pool refilled from the start.
room_build:			ld		c,a
					call	room_find
					ret		nc		; no such room -- the caller must not go on
					; to put anything in one that was never
					; built

					push	hl		; the record

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
					ld		(room_door_to + ROOM_DOOR_N),a
					ld		(room_door_to + ROOM_DOOR_E),a
					ld		(room_door_to + ROOM_DOOR_S),a
					ld		(room_door_to + ROOM_DOOR_W),a
					ld		(room_behaviour),a

					pop		de
					inc		de		; past its own number
					ld		a,(de)
					sub		2		; the skip, less the rest of the header
					ld		(room_bytes_left),a
					inc		de

					; The attribute: colour in bits 0-2, shape in bits 3-4, and
					; the scenery count LESS ONE in bits 5-7.
					ld		a,(de)
					inc		de
					ld		(room_attr),a
					rlca
					rlca
					rlca
					and		7
					add		a,ROOM_SCN_BIAS
					ld		(room_scenery_left),a

					; The screen goes black at once, by its attributes, and the room
					; is drawn behind that; main.s colours it in with room_paper once
					; Sabreman is there as well, so a new room appears whole instead
					; of being watched as it draws -- as Knight Lore's does.
					push	de
					call	panel_off		; no panel until the room is up
					xor		a
					call	screen_colour	; black on black: the old room goes
					call	room_shape		; at once, and nothing is wiped --
									; redraw_screen writes every pixel there
									; is, as Knight Lore's builder says
					pop		de

					ld		ix,room_objects	; room_add fills THROUGH IX and moves it on,
									; so the pool has to be pointed at before
									; anything is added. Without this it read
									; the right template and wrote through
									; whatever IX held, so every record kept
									; its assembled zeros while the count still
									; went up -- which looked like a drawing
									; fault and was not.
					call	room_scenery
					call	room_objects_of
					call	quest_room_enter	; and what persists that is here
					call		room_show
					scf				; built. room_show leaves the flags as it
					ret				; pleases, so the carry the caller branches
									; on has to be set here rather than carried
									; through from room_find.


; ---------------------------------------------------------------------------
; The room's colour over the whole screen: bits 0-2 of the attribute, always
; bright, which is how the game does it -- the builder ORs in $40.
;
; Knight Lore's version also turns its sun window and its panel hook back on
; here. Pentagram has neither yet, so this only sets the colour; whatever it
; grows in their place belongs at this point.
room_paper:			ld		a,(room_attr)
					and		7
					or		64		; BRIGHT

					;; NB: fall through into screen_colour


; Every attribute cell one colour.
;   A - the colour
; Corrupts BC, DE, HL.
screen_colour:		ld		hl,22528
					ld		de,22529
					ld		bc,767
					ld		(hl),a
					ldir
					ret


; ---------------------------------------------------------------------------
; The room's floor, from the shape index in the attribute.
room_shape:			ld		a,(room_attr)
					rrca
					rrca
					rrca
					and		3
					ld		l,a
					ld		h,0
					ld		d,h
					ld		e,l
					add		hl,hl
					add		hl,de		; * 3
					ld		de,room_size_tbl
					add		hl,de
					; The table already holds half-extents -- how far the floor
					; reaches from the room's centre -- and the floor's height, in
					; the order they are kept in here. Same as Knight Lore's.
					ASSERT	room_half_v == room_half_u + 1
					ASSERT	room_floor_z == room_half_u + 2
					ld		de,room_half_u
					ld		bc,3
					ldir
					ret


; ---------------------------------------------------------------------------
; The scenery. Each entry is a template index, and a doorway's is followed by
; the room it leads to -- nothing else has one. The template's pieces are already in the eight-byte shape
; room_add wants, so this is a walk and a call.
;   DE -> the scenery entries
; Leaves DE on the first object byte.
room_scenery:		ld		a,(room_scenery_left)
					or		a
					ret		z
					dec		a
					ld		(room_scenery_left),a

					ld		a,(de)
					inc		de
					ld		c,a		; which template, kept for room_door_note
					ld		b,1		; the bytes this entry takes
					call	room_is_door
					jr		nz,.not_door
					ld		a,(de)
					inc		de
					ld		(room_dest),a	; ...and where a doorway leads
					inc		b
.not_door:			ld		a,(room_bytes_left)	; room_objects_of reads whatever
					sub		b			; is left, and there is no $FF to stop
					ld		(room_bytes_left),a	; it -- the scenery count replaced
									; that, so the body count is the only
									; thing saying where the objects begin.
					push	de

					ld		l,c
					ld		h,0
					add		hl,hl
					ld		de,scenery_type_tbl
					add		hl,de
					ld		e,(hl)
					inc		hl
					ld		d,(hl)
					ex		de,hl		; -> the template

					call	room_scenery_move	; before room_door_note, which takes C
					call	room_door_note

.piece:				ld		a,(hl)
					or		a		; a zero graphic ends it
					jr		z,.done
					call	room_add
					xor		a
					ld		(room_behaviour),a	; only the first piece drives
					jr		.piece

.done:				pop		de
					jr		room_scenery


; ---------------------------------------------------------------------------
; Does this piece of scenery move?
;
; Knight Lore has two kinds that do -- a portcullis and the wizard -- and
; special-cases them by template index. Which of Pentagram's scenery moves has
; not been worked out: its object flag $04 marks a thing as mobile (fields
; +$09..+$0B are a movement vector), but no scenery template carries it, and
; nothing else in the data says so. So this clears the behaviour and returns,
; which is right for scenery that stands still -- and every piece does, until
; something proves otherwise.
;   C  - the scenery template index
; Corrupts AF.
room_scenery_move:	xor		a
					ld		(room_behaviour),a
					ret


; ---------------------------------------------------------------------------
; Is scenery template C a doorway? Twelve are -- indices 0 to 7 and 24 to 27.
; Out: Z if it is.
; Corrupts AF.
room_is_door:		ld		a,c
					cp		8
					jr		c,.yes			; 0-7, the first two sets
					sub		24
					cp		4
					jr		c,.yes			; 24-27
					or		1			; NZ: A is at least 4
					ret
.yes:				xor		a
					ret


; ---------------------------------------------------------------------------
; If this piece of scenery is a doorway, remember where it leads.
;
; Twelve templates are doorways -- indices 0 to 7 and 24 to 27 -- and the side
; is the bottom two bits. An arch never moves, so the answer holds all room
; long and is worth working out once, as the scenery goes by.
;
; The first piece of a template is the one to measure from, so its position is
; the one kept.
;
;   C  - the scenery template index
;   HL -> the template
; Corrupts AF and B. HL comes back where it was.
room_door_note:		call	room_is_door
					ret		nz

					ld		a,(room_dest)
					or		a
					ret		z		; the arch is drawn but walled up

					ld		a,c
					and		3		; the side, as the engine numbers them
					ld		b,a

					push	hl
					ld		hl,room_door_to
					call	.index
					ld		a,(room_dest)
					ld		(hl),a
					pop		hl

					push	hl
					inc		hl
					inc		hl
					inc		hl		; past graphic, U, V -> Z
					ld		a,(hl)
					pop		hl
					push	hl
					ld		hl,room_door_z
					call	.index
					ld		(hl),a
					pop		hl

					; How far the arch stands out along its own axis: U for the
					; east and west sides, V for north and south.
					push	hl
					inc		hl
					ld		a,b
					and		1		; E and W are the odd sides
					jr		nz,.along_u
					inc		hl		; -> V
.along_u:			ld		a,(hl)
					pop		hl
					push	hl
					ld		hl,room_door_at
					call	.index
					ld		(hl),a
					pop		hl

					; And where the opening is centred along the wall.
					push	hl
					inc		hl		; -> U, across a north or south wall
					bit		0,b
					jr		z,.mid_ns
					inc		hl		; -> V, across an east or west one
					ld		a,(hl)
					sub		ROOM_DOOR_HALF
					jr		.mid
.mid_ns:			ld		a,(hl)
					add		a,ROOM_DOOR_HALF
.mid:				ld		hl,room_door_mid
					call	.index
					ld		(hl),a
					pop		hl
					ret

; HL += B, leaving A alone -- two of the three callers are holding the value
; they are about to store in it.
.index:				push	af
					ld		a,b
					add		a,l
					ld		l,a
					ld		a,h
					adc		a,0
					ld		h,a
					pop		af
					ret


; ---------------------------------------------------------------------------
; The object groups. A group is a type-and-count byte then one packed position
; an instance, so an entry is 1 + count bytes -- NOT a fixed size, which is the
; trap in this format.
;
;   DE -> the object bytes
room_objects_of:	ld		a,(room_bytes_left)
					or		a
					ret		z
					dec		a		; the group byte about to be read
					ld		(room_bytes_left),a

					ld		a,(de)
					inc		de
					ld		c,a
					and		7		; the repeat count is bits 0-2...
					inc		a
					ld		(room_count_left),a	; the repeat count, plus one

					ld		a,c
					rrca
					rrca
					and		$3E		; an even index into the table
					push	af
					call	mover_find		; what drives every one of this group
					ld		(room_behaviour),a
					pop		af
					ld		l,a
					ld		h,0
					ld		bc,object_type_tbl
					add		hl,bc
					ld		c,(hl)
					inc		hl
					ld		b,(hl)
					ld		(room_template),bc

.instance:			ld		a,(de)
					inc		de
					ld		(room_packed),a
					push	de
					ld		hl,(room_template)
					call	room_unpack_place
					pop		de
					ld		a,(room_bytes_left)	; the position byte just read
					dec		a
					ld		(room_bytes_left),a
					ld		a,(room_count_left)
					dec		a
					ld		(room_count_left),a
					jr		nz,.instance

					jr		room_objects_of


; ---------------------------------------------------------------------------
; Stage one instance of a template and hand it to room_add.
;
; A template entry is six bytes -- graphic, size U, size V, size Z, flags,
; offsets -- and the position comes from the room's packed byte:
;
;   U = (byte & 7) * 16       + a half cell if the template asks + 72
;   V = (byte >> 3 & 7) * 16  + a half cell if the template asks + 72
;   Z = (byte >> 6 & 3) * 12  + the template's own offset, up from the floor
;
; The offsets byte carries all three nudges at once: bit 0 for U, bit 1 for V,
; and the whole byte added into Z with those two bits masked off again. That
; works because the level times twelve is always a multiple of four. Pentagram
; has no such byte of its own -- rooms_source.py emits zero -- but the shape is
; kept so the capability is there. See ../knightlore/room_build.s.
;   HL -> the template entry
room_unpack_place:	ld		a,(hl)
					ld		(room_stage + 0),a		; graphic
					inc		hl
					ld		de,room_stage + 4		; size U, size V, size Z, flags
					ld		bc,4
					ldir
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

					ld		hl,room_stage
					jp		room_add
