; ---------------------------------------------------------------------------
; The collectables, and the cauldron they go into.
;
; Knight Lore scatters thirty-two of them about the castle -- special_objs_tbl
; at $6FF2, a row for each -- and the wizard in room $88 wants fourteen of them
; dropped into his pot, one at a time and in an order of his choosing. Graphics
; 96 to 102 are the seven kinds he asks for; 103 is the eighth kind in the
; table, which is not wanted and is not picked up but taken the moment the
; knight touches it, and gives him a life.
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
; in room.s, where the room builder lives; and picking them up, putting them
; down and showing what is carried are in pickup.s, which only runs when a key
; is pressed.
; ---------------------------------------------------------------------------

SPECIAL_ROWS		EQU		32
SPECIAL_SLOTS		EQU		2
SPECIAL_WANTED		EQU		14		; how many the wizard asks for
SPECIAL_FIRST		EQU		GFX_COLLECTABLE_1_G96		; the first collectable graphic
SPECIAL_LIFE		EQU		GFX_PANEL_4_G103		; the one that is taken, not carried
SPECIAL_FLIGHT		EQU		8		; added to one on its way into the pot
SPECIAL_BUBBLES		EQU		160		; rising out of it, four frames
SPECIAL_SPELL		EQU		164		; ...and what they turn into for a werewolf
SPECIAL_SHOW		EQU		GFX_COLLECTABLE_1_G168		; the wanted one, shown by the bubbles
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

; The room they were filled for, which is where they are written back to.
; Not room_shown: dying starts the room over by making that anything but the
; room it is, and a collectable written back under that would be in no room.
special_room:		DB		0

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
; knight is next to it and gives him a life (upd_103). And one with
; SPECIAL_FLIGHT added is on its way into the pot.
;   IX -> the record
mover_special:		ld		a,(ix+OBJ.GFX)
					cp		SPECIAL_LIFE
					jp		c,mover_pushed
					jr		nz,.flight

					ld		de,$0001		; next to him, reaching no further down
					call	special_near
					jp		nc,mover_pushed
					ld		hl,player_lives		; and a life with it
					inc		(hl)
					call	sound_pickup
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
					call	sound_uvz
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
					ld		a,(special_count)		; the last of them ends the game:
					cp		SPECIAL_WANTED		; the game fills the room with
					jp		nc,game_over		; sparkles that chase him first
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

					call	mover_cycle4		; the next of its four frames

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
					push	de
					ld		a,(ix+OBJ.GFX)
					call	sound_sparkle
					pop		de
					ld		bc,$2000
.wait:				dec		bc
					ld		a,b
					or		c
					jr		nz,.wait
					dec		d
					jr		nz,.cycle
					ret
