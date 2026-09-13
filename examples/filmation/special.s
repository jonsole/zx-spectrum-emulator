; ---------------------------------------------------------------------------
; The collectables, and the cauldron they go into.
;
; Knight Lore scatters thirty-two of them about the castle -- special_objs_tbl
; at $6FF2, a row for each -- and the wizard in room $88 wants fourteen of them
; dropped into his pot, one at a time and in an order of his choosing. Graphics
; 96 to 102 are the seven kinds he asks for; 103 is the eighth kind in the
; table, which is not wanted and is not picked up but taken the moment the
; knight touches it.
;
; The table is the castle's memory of them. A room does not hold its
; collectables in its own data: when a room is built the table is searched for
; rows naming it, and when it is left whatever is lying there is written back.
; Picking one up takes its row out of the castle, and putting it down puts it
; back wherever that happens to be.
;
; A room has two records set aside for them, which are the game's two at $5C48
; and $5C68 -- so a room can hold two and no more, and something can only be
; put down in a room with a slot free. In room $88 the second is spoken for:
; it is where the bubbles rise out of the pot.
;
; The room-time half of this -- filling the slots and writing them back -- is
; in room.s, where the room builder lives.
; ---------------------------------------------------------------------------

SPECIAL_ROWS		EQU		32
SPECIAL_SLOTS		EQU		2
SPECIAL_WANTED		EQU		14		; how many the wizard asks for
SPECIAL_FIRST		EQU		96		; the first collectable graphic
SPECIAL_LIFE		EQU		103		; the one that is taken, not carried
SPECIAL_FLIGHT		EQU		8		; added to one on its way into the pot
SPECIAL_BUBBLES		EQU		160		; rising out of it, four frames
SPECIAL_SPELL		EQU		164		; ...and what they turn into for a werewolf
SPECIAL_SHOW		EQU		168		; the wanted one, shown by the bubbles
SPECIAL_POT_ROOM	EQU		$88
SPECIAL_POT_TOP		EQU		$98		; standing on the pot
SPECIAL_POT_FLOOR	EQU		$80		; ...and in it
SPECIAL_SIZE_UV		EQU		5		; the game's box, the same for all of them
SPECIAL_SIZE_Z		EQU		12
SPECIAL_REACH		EQU		4		; how much further the knight reaches to pick
									; one up than he does to walk into it

; Pick up and put down: any of 6, 7, 8, 9 or 0. The game takes the whole top
; row, but 1 and 2 are the room keys here.
KEY_PICKUP			EQU		$EFFE

; The two slots in the current room, or zero before the first room is built.
special_slots:		DW		0

; How many the wizard has had, which is also which one he wants next.
special_count:		DB		0

; Set while a dropped one is on its way into the pot. Nothing else happens
; while it is: the knight hangs where he is and the keys are not read. The
; game's $5BC4.
special_busy:		DB		0

; Whether the pick-up key has already been acted on this press. The game's
; $5BB3.
special_key_held:	DB		0

; Whether there is room above the knight's head to put something under his
; feet, worked out as the key goes down. The game's $5BD3.
special_head:		DB		0

; What the knight is carrying: four slots of graphic and table row, of which
; the last three are the ones shown. The first is only ever filled on its way
; into the others -- see special_shift. The game's $5BD8, four bytes a slot.
special_carried:	DS		8

; The colour each is shown in, by graphic & 15. The game's own, at $BFD3.
special_colours:	DB		$42, $43, $44, $45, $46, $47, $42, $47


; ---------------------------------------------------------------------------
; A collectable's turn.
;
; 96 to 102 lie where they are put and can be carried about by anything they
; stand on or shoved by anything that walks into them: upd_96_to_102 is
; upd_84's move-and-let-go with a different nudge. 103 goes the moment the
; knight is next to it (upd_103, which also gives him a life -- there are no
; lives yet). And one with SPECIAL_FLIGHT added is on its way into the pot.
;   IX -> the record
mover_special:		ld		a,(ix+OBJ.GFX)
					cp		SPECIAL_LIFE
					jp		c,mover_pushed
					jr		nz,.flight

					ld		de,$0001		; next to him, reaching no further down
					call	special_near
					jp		nc,mover_pushed
					call	special_row_gone
					jp		special_hide

					; upd_104_to_110: a unit a turn along each axis towards the middle
					; of the room, rising to the top of the pot and hanging there
					; until it is over the middle -- and then straight down, through
					; the pot and everything else, because nothing collides with it
					; any more.
.flight:			ld		a,(ix+OBJ.U)
					call	.towards
					ld		(ix+OBJ.DU),a
					ld		b,a
					ld		a,(ix+OBJ.V)
					call	.towards
					ld		(ix+OBJ.DV),a
					or		b
					jr		z,.over

					ld		a,(ix+OBJ.Z)
					cp		SPECIAL_POT_TOP
					ld		a,2		; below the top: up a unit, net of gravity
					jr		c,.rise
					dec		a		; at it: stay there
.rise:				ld		(ix+OBJ.DZ),a
					jp		mover_move_always

.over:				ld		a,SPECIAL_POT_FLOOR
					cp		(ix+OBJ.Z)
					jr		nc,.in
					ld		a,(ix+OBJ.FLAGS)
					or		OBJ_PASSABLE
					ld		(ix+OBJ.FLAGS),a
					dec		(ix+OBJ.DZ)		; gravity, with nothing to stop it
					jp		mover_paint

					; add_obj_to_cauldron. The right one moves the wizard on a step and
					; the screen flashes; the wrong one is simply gone.
.in:				ld		a,(special_count)
					cp		SPECIAL_WANTED
					jr		nc,.wrong
					ld		e,a
					ld		d,0
					ld		hl,special_wanted
					add		hl,de
					ld		a,(ix+OBJ.GFX)
					and		7
					cp		(hl)
					jr		nz,.wrong
					ld		hl,special_count
					inc		(hl)
					call	special_flash
					ld		ix,(mover_ix)
.wrong:				xor		a
					ld		(special_busy),a
					call	special_row_gone
					jp		special_hide

					; A unit towards 128, or nothing when it is there. The sign of the
					; difference, as the game takes it.
.towards:			sub		128
					ret		z
					ld		a,1
					ret		m
					neg
					ret


; ---------------------------------------------------------------------------
; What rises out of the pot, in the second slot of room $88.
;
; upd_160_to_163: bubbles, which rise through the pot to $A0 and hang there,
; and every fourth frame show the one the wizard wants next -- as graphic 168
; plus its kind, which upd_168_to_175 turns straight back into bubbles. If the
; knight is a werewolf when they get to the top they turn into a repel spell
; instead, which comes after him. They go away while anything is in the first
; slot.
;
; MOVE_STATE holds the step in Z for next turn. The game leaves it in dZ and
; takes one off before using it; here dZ is gravity's to spend.
;   IX -> the record
mover_cauldron:		ld		a,(ix+OBJ.GFX)
					cp		SPECIAL_SPELL
					jr		c,.bubbles
					cp		SPECIAL_SHOW
					jr		nc,.shown

					; The spell, which in this room goes if he is neither knight nor
					; wolf -- loc_B945's own test on the legs.
					ld		a,(player + OBJ.GFX)
					sub		16
					cp		64
					jp		c,mover_spell
					jp		special_hide

.shown:				ld		(ix+OBJ.GFX),SPECIAL_BUBBLES
					jr		.still

.bubbles:			ld		iy,(special_slots)
					ld		a,(iy+OBJ.GFX)
					or		a
					jp		nz,special_hide

					ld		a,(ix+OBJ.FLAGS)
					or		OBJ_PASSABLE
					ld		(ix+OBJ.FLAGS),a
					ld		a,(ix+OBJ.MOVE_STATE)
					dec		a
					ld		(ix+OBJ.DZ),a
					add		a,(ix+OBJ.Z)
					ld		c,a		; where it is about to be

					ld		a,(ix+OBJ.GFX)		; the next of its four frames
					inc		a
					xor		(ix+OBJ.GFX)
					and		3
					xor		(ix+OBJ.GFX)
					ld		(ix+OBJ.GFX),a

					ld		b,2		; below the top: rise
					ld		a,c
					cp		$A0
					jr		c,.dz
					dec		b		; at it: hang

					ld		a,(player + OBJ.GFX)
					sub		48		; the werewolf's legs are 48 to 63
					cp		16
					jr		nc,.show
					ld		a,(ix+OBJ.GFX)
					or		4
					ld		(ix+OBJ.GFX),a
					ld		a,(ix+OBJ.FLAGS)
					and		$FF - OBJ_PASSABLE
					ld		(ix+OBJ.FLAGS),a
					jr		.dz

.show:				ld		a,(ix+OBJ.GFX)
					and		3
					jr		nz,.dz
					ld		a,(special_count)
					cp		SPECIAL_WANTED
					jr		nc,.dz
					ld		e,a
					ld		d,0
					ld		hl,special_wanted
					add		hl,de
					ld		a,(hl)
					or		SPECIAL_SHOW
					ld		(ix+OBJ.GFX),a

.dz:				ld		(ix+OBJ.MOVE_STATE),b
					jp		mover_paint

.still:				xor		a
					ld		(ix+OBJ.DU),a
					ld		(ix+OBJ.DV),a
					ld		(ix+OBJ.DZ),a
					jp		mover_paint


; Start the bubbles, if this is the pot's room and nothing is in either slot.
; init_cauldron_bubbles, which the game runs at the end of every frame. It only
; asks about the second slot, and the bubbles then take themselves away at once
; if the first is taken; asking about both here saves drawing them for nothing.
special_step:		ld		a,(room_shown)
					cp		SPECIAL_POT_ROOM
					ret		nz
					ld		a,(special_count)
					cp		SPECIAL_WANTED
					ret		nc
					ld		ix,(special_slots)
					ld		a,(ix+OBJ.GFX)
					ld		bc,ROOM_STRIDE
					add		ix,bc
					or		(ix+OBJ.GFX)
					ret		nz
					ld		hl,special_pot
					ld		a,SPECIAL_BUBBLES
					ld		bc,MOVE_CAULDRON * 256 + 0
					jp		special_fill

special_pot:		DB		128, 128, 128


; ---------------------------------------------------------------------------
; The pick-up key. handle_pickup_drop, at $C00E.
;
; One press does one thing, and only once the knight is standing on something
; and inside the room's edges -- held down in the air, it waits for him to
; land. Then, if he is next to a collectable, he picks it up; if not, he puts
; one down.
;   IX -> the knight's legs
; Corrupts everything.
special_keys:		ld		bc,KEY_PICKUP
					in		a,(c)
					cpl
					and		$1F
					ld		hl,special_key_held
					jr		nz,.down
					ld		(hl),a		; let go: the next press counts
					ret
.down:				ld		a,(hl)
					or		a
					ret		nz		; this press has had its turn

					; Inside the room's edges -- chk_plyr_OOB, which keeps a knight
					; in a doorway from leaving something in it.
					ld		a,(ix+OBJ.U)
					sub		128
					jp		p,.u
					neg
.u:					add		a,(ix+OBJ.SIZE_U)
					ld		hl,room_half_u
					cp		(hl)
					ret		nc
					ld		a,(ix+OBJ.V)
					sub		128
					jp		p,.v
					neg
.v:					add		a,(ix+OBJ.SIZE_V)
					inc		hl		; room_half_v
					cp		(hl)
					ret		nc

					; And standing, not jumping or falling.
					bit		0,(ix+CHARACTER_STATE)
					ret		nz
					ld		a,(ix+CHARACTER_DZ)
					or		a
					ret		nz

					; Would he fit a box's height further up? Asked of the whole
					; room with his box moved up by twelve.
					xor		a
					ld		(special_head),a
					ld		(collide_eff_u),a
					ld		(collide_eff_v),a
					ld		a,SPECIAL_SIZE_Z
					ld		(collide_eff_z),a
					call	collide_box
					ld		iy,room_objects
					ld		a,(room_object_count)
					ld		b,a
					ld		de,ROOM_STRIDE
.head:				call	object_overlaps
					jr		c,.no_room
					ld		de,ROOM_STRIDE
					add		iy,de
					djnz	.head
					jr		.pressed
.no_room:			ld		a,1
					ld		(special_head),a

.pressed:			ld		a,1
					ld		(special_key_held),a

					; Next to one? He reaches four further than he walks, and four
					; lower.
					ld		ix,(special_slots)
					ld		b,SPECIAL_SLOTS
.look:				ld		a,(ix+OBJ.GFX)
					sub		SPECIAL_FIRST
					cp		SPECIAL_LIFE - SPECIAL_FIRST
					jr		nc,.not
					push	bc
					ld		de,SPECIAL_REACH * 257
					call	special_near
					pop		bc
					jr		c,special_pickup
.not:				ld		de,ROOM_STRIDE
					add		ix,de
					djnz	.look

					;; NB: fall through into special_drop


; Put down the oldest thing he is carrying, under his own feet, and stand him
; on it. room_to_drop, at $C0B2.
;
; It needs a free slot -- only the first, in the pot's room -- and nothing
; above his head. And if the last slot is empty there is nothing to put down,
; and the press turns the others round instead, which is how you choose what
; to drop.
special_drop:		ld		ix,(special_slots)
					ld		a,(ix+OBJ.GFX)
					or		a
					jr		z,.free
					ld		a,(room_shown)
					cp		SPECIAL_POT_ROOM
					ret		z
					ld		de,ROOM_STRIDE
					add		ix,de
					ld		a,(ix+OBJ.GFX)
					or		a
					ret		nz

.free:				ld		a,(special_carried + 6)
					or		a
					jp		z,special_shift
					ld		a,(special_head)
					or		a
					ret		nz

					; Standing on the pot in its own room, it goes in.
					ld		a,(room_shown)
					cp		SPECIAL_POT_ROOM
					jr		nz,.lift
					ld		a,(player + OBJ.Z)
					cp		SPECIAL_POT_TOP
					jr		c,.lift
					ld		a,1
					ld		(special_busy),a

					; Up with him first and in with it after, so that when it is
					; sorted he is already clear of it.
.lift:				push	ix
					ld		hl,player + OBJ.U
					ld		de,special_where_at
					ld		bc,3
					ldir
					ld		ix,player
					ld		(ix+OBJ.DZ),SPECIAL_SIZE_Z
					ld		de,0
					call	character_move
					pop		ix

					ld		a,(special_busy)
					or		a
					ld		a,(special_carried + 6)
					jr		z,.plain
					add		a,SPECIAL_FLIGHT
.plain:				ld		hl,special_carried + 7
					ld		c,(hl)
					ld		b,MOVE_SPECIAL
					ld		hl,special_where_at
					call	special_fill
					jp		special_shift

special_where_at:	DS		3


; Pick up the one in IX. pickup_object, at $C141.
;
; If all three places are full, the oldest is put down where the new one was
; -- the same record, redrawn with the other graphic.
special_pickup:		ld		a,(ix+OBJ.GFX)
					ld		(special_carried),a
					ld		a,(ix+OBJ.MOVE_STATE)
					ld		(special_carried + 1),a
					call	special_row_gone
					ld		a,(special_carried + 6)
					or		a
					jr		z,.gone
					ld		(ix+OBJ.GFX),a
					ld		a,(special_carried + 7)
					ld		(ix+OBJ.MOVE_STATE),a
					call	region_reset
					call	region_add
					call	room_adjust
					ld		a,(ix+OBJ.GFX)
					call	object_place
					call	region_add
					call	redraw_view
					jr		special_shift
.gone:				call	special_hide

					;; NB: fall through into special_shift


; Move everything carried on a place, the last one dropping off the end, and
; show the result. adjust_carried, at $C12B.
special_shift:		ld		hl,special_carried + 5
					ld		de,special_carried + 7
					ld		bc,6
					lddr
					xor		a
					ld		(special_carried),a
					ld		(special_carried + 1),a

					;; NB: fall through into special_show


; Draw what the knight is carrying in the bottom-left corner: three places of
; three characters by three, each in its own colour. display_objects, at $BF4E.
;
; Straight to the screen, as the room number is. A region reaching the corner
; wipes them, so redraw_view calls back in here when one does.
special_show:		ld		hl,special_carried + 2
					ld		c,2		; the character column
					ld		b,3
.slot:				push	bc
					push	hl
					ld		a,(hl)
					call	special_show_one
					pop		hl
					pop		bc
					inc		hl
					inc		hl
					ld		a,c
					add		a,3
					ld		c,a
					djnz	.slot
					ret

;   A - the graphic, or 0 for none
;   C - the character column
special_show_one:	push	af

					; Its colour, three by three.
					and		15
					ld		e,a
					ld		d,0
					ld		hl,special_colours
					add		hl,de
					ld		e,(hl)
					ld		hl,$5800 + 21 * 32
					ld		a,l
					add		a,c
					ld		l,a
					ld		b,3
.attr:				ld		(hl),e
					inc		hl
					ld		(hl),e
					inc		hl
					ld		(hl),e
					ld		a,l
					add		a,30
					ld		l,a
					jr		nc,.attr_on
					inc		h
.attr_on:			djnz	.attr

					; Blank the place: the bottom 24 rows, three bytes across. A row at
					; a time through pixelAddress, which hands back the screen's own
					; arrangement of rows rather than one row every 32 bytes.
					ld		a,c
					add		a,a
					add		a,a
					add		a,a
					ld		c,a		; x, in pixels
					ld		b,SCREEN_ROWS - 24
.blank:				call	pixelAddress
					xor		a
					ld		(hl),a
					inc		hl
					ld		(hl),a
					inc		hl
					ld		(hl),a
					inc		b
					ld		a,b
					cp		SCREEN_ROWS
					jr		c,.blank
					pop		af
					or		a
					ret		z

					; The graphic, the right way round and standing on the bottom row.
					push	bc
					ld		l,a
					ld		h,(high sprite_table) / 2
					add		hl,hl
					ld		a,(hl)
					inc		l
					ld		h,(hl)
					ld		l,a
					bit		0,(hl)		; SPRITE_FLIPPED
					jr		z,.oriented
					push	hl
					call	sprite_flip_h
					pop		hl
.oriented:			pop		bc
					ld		a,(hl)
					sprite_width_class
					add		a,2
					ld		(.columns+1),a
					inc		hl
					ld		a,SCREEN_ROWS
					sub		(hl)		; its top row
					ld		b,a
					inc		hl

.rows:				ex		de,hl		; DE -> the bitmap
					call	pixelAddress
					push	bc
.columns:			ld		b,0		; patched: the width
.column:			ld		a,(de)		; mask
					inc		de
					and		(hl)
					ld		c,a
					ld		a,(de)		; and bitmap
					inc		de
					xor		c
					ld		(hl),a
					inc		hl
					djnz	.column
					pop		bc
					ex		de,hl
					inc		b
					ld		a,b
					cp		SCREEN_ROWS
					jr		c,.rows
					ret


; ---------------------------------------------------------------------------
; Is the knight next to IX? His box widened by E each way and reaching down by
; D -- is_on_or_near_obj at $C17A, which the game calls with the knight's own
; sizes enlarged.
; Out: carry if so. Corrupts AF, BC, IY.
special_near:		ld		iy,player
					ld		a,(iy+OBJ.U)
					sub		(ix+OBJ.U)
					call	.abs
					ld		c,a
					ld		a,(iy+OBJ.SIZE_U)
					add		a,(ix+OBJ.SIZE_U)
					add		a,e
					ld		b,a
					ld		a,c
					cp		b
					ret		nc

					ld		a,(iy+OBJ.V)
					sub		(ix+OBJ.V)
					call	.abs
					ld		c,a
					ld		a,(iy+OBJ.SIZE_V)
					add		a,(ix+OBJ.SIZE_V)
					add		a,e
					ld		b,a
					ld		a,c
					cp		b
					ret		nc

					; Z is a base and a height: whichever is lower, the other's
					; base has to be under its top.
					ld		a,(iy+OBJ.Z)
					sub		d
					sub		(ix+OBJ.Z)
					jp		p,.above
					neg
					ld		c,a
					ld		a,COLLIDE_HEIGHT
					add		a,d
					ld		b,a
					ld		a,c
					cp		b
					ret
.above:				cp		(ix+OBJ.SIZE_Z)
					ret

.abs:				ret		p
					neg
					ret


; This one's table row no longer has anything in the castle: it is carried,
; or gone for good.
;   IX -> the record
; Corrupts AF, DE, HL.
special_row_gone:	ld		a,(ix+OBJ.MOVE_STATE)
					cp		SPECIAL_ROWS
					ret		nc		; not a row at all
					ld		e,a
					ld		d,0
					ld		hl,special_gfx
					add		hl,de
					ld		(hl),0
					ret


; Take a slot's object out of the room: repaint where it was, without it.
; The game gives it graphic 1, which the next draw wipes and turns to 0.
;   IX -> the record
; Corrupts everything, IX included.
special_hide:		call	region_reset
					call	region_add
					call	depth_unlink
					call	special_blank
					jp		redraw_view

special_blank:		ld		(ix+OBJ.GFX),0
					ld		(ix+OBJ.BEHAVIOUR),0
					ld		(ix+OBJ.FLAGS),OBJ_PASSABLE
					ret


; The wizard has had one he wanted: every attribute's ink steps round, sixteen
; times -- back where it started -- with a pause between.
; cycle_colours_with_sound, at $C2A5, less the sound.
; Corrupts everything but IX.
special_flash:		ld		d,16
.cycle:				ld		hl,$5800
					ld		bc,768
.attr:				ld		a,(hl)
					inc		a
					xor		(hl)
					and		7
					xor		(hl)
					ld		(hl),a
					inc		hl
					dec		bc
					ld		a,b
					or		c
					jr		nz,.attr
					ld		bc,$2000
.wait:				dec		bc
					ld		a,b
					or		c
					jr		nz,.wait
					dec		d
					jr		nz,.cycle
					ret
