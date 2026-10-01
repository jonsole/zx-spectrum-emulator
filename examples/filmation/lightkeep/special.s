; ---------------------------------------------------------------------------
; The collectables.
;
; Knight Lore scatters thirty-two of them about the castle -- special_objs_tbl
; at $6FF2, a row for each -- and its wizard wants fourteen of them dropped
; into his pot. That quest is not this game's: Knight Lore 128K still has it.
; Here they are only things to carry, until stage 3 of README.md replaces them
; with Fairlight's five slots and weights. Graphics 96 to 102 are the seven
; kinds that are carried; 103 is the eighth kind in the table, which is not
; picked up but taken the moment the knight touches it, and gives him a life.
;
; The table is the castle's memory of them. A room does not hold its
; collectables in its own data: when a room is built the table is searched for
; rows naming it, and when it is left whatever is lying there is written back.
; Picking one up takes its row out of the castle, and putting it down puts it
; back wherever that happens to be.
;
; A room has two records set aside for them, which are the game's two at $5C48
; and $5C68 -- so a room can hold two and no more, and something can only be
; put down in a room with a slot free.
;
; The room-time half of this -- filling the slots and writing them back -- is
; in room.s, where the room builder lives; and picking them up, putting them
; down and showing what is carried are in pickup.s, which only runs when a key
; is pressed.
; ---------------------------------------------------------------------------

SPECIAL_ROWS		EQU		32
SPECIAL_SLOTS		EQU		2
SPECIAL_FIRST		EQU		GFX_COLLECTABLE_1_G96		; the first collectable graphic
SPECIAL_LIFE		EQU		GFX_PANEL_4_G103		; the one that is taken, not carried
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
; knight is next to it and gives him a life (upd_103).
;
; In:  IX -> the record; mover_ix names it too
; Out: nothing
; Corrupts: everything -- IX only on the turn object_hide takes it away
mover_special:		ld		a,(ix+OBJ.GFX)
					cp		SPECIAL_LIFE
					jp		nz,mover_shoved

					ld		de,$0001		; next to him, reaching no further down
					call	special_near
					jp		nc,mover_shoved
					ld		hl,player_lives		; and a life with it
					inc		(hl)
					call	sound_pickup
					call	special_row_gone
					jp		object_hide


; ---------------------------------------------------------------------------
; Is the knight next to IX? His box widened by E each way and reaching down by
; D -- is_on_or_near_obj at $C17A, which the game calls with the knight's own
; sizes enlarged.
;
; In:  IX -> the thing
;      D  = how much further down he reaches
;      E  = how much wider his box is each way
; Out: carry set if he is next to it
; Corrupts: A, BC, IY
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
;
; In:  IX -> the record
; Out: nothing
; Corrupts: AF, DE, HL
special_row_gone:	ld		a,(ix+OBJ.MOVE_STATE)
					cp		SPECIAL_ROWS
					ret		nc		; not a row at all
					ld		e,a
					ld		d,0
					ld		hl,special_gfx
					add		hl,de
					ld		(hl),0
					ret
