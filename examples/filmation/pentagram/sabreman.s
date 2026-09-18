; ---------------------------------------------------------------------------
; Sabreman: his size, his step, how he jumps and the box a doorway puts round
; him. The engine asks a game for all of this -- see "What the game supplies"
; in ../engine/README.md.
;
; Most of it is MEASURED off the running original rather than copied from
; Knight Lore, by driving it over DAP and reading his own object records at
; $A76F (legs) and $A78F (body). Where a number is inherited instead, it says
; so. The method matters because it is easy to get wrong: relaunch before
; every measurement, let him settle to rest first, and take a no-key control --
; standing still he sits on one graphic at (128,128,128) and does not move, so
; any drift means the reading is contaminated.
;
; Nearly every number came out the same as Knight Lore's, which is no surprise:
; the same engine and, for most of it, the same character. The one that did not
; is the jump.
; ---------------------------------------------------------------------------

; His legs carry W=5, D=5, H=23 and his body carries H=0, so the whole of him
; is one box hung on the lower half. Read straight out of the live records.
COLLIDE_HEIGHT		EQU		23

; What the two kept rotation buffers are sized from -- the biggest frame each
; half can wear, once sprite_source.py has taken the blank rows off. It checks
; this on every build, so a wrong guess here fails loudly rather than rotating
; a buffer past its end into the other.
;
; They are declared, with the graphics each half can wear, in ROTATION_BUFFERS
; in sprite_sheet.py -- change them there and here together.
CHARACTER_LARGEST	EQU		sprite_066		; 3x18: graphic 36, his legs facing us
CHARACTER_TALLEST	EQU		sprite_061		; 3x34: graphic 46, his body facing us

CHARACTER_BODY_UP	EQU		12		; how far his body rides above his legs facing away
					; (8 facing towards: PLAYER_BODY_UP_TOWARDS in player.s).
					; Measured: the body record sits at Z 140
					; with the legs at 128. Z is what the depth
					; sort reads, so the height belongs here and
					; not in the pixel nudge.
CHARACTER_Z			EQU		128		; the floor, where he stands at rest

; How wide he is, as a half-extent about U and V -- see COLLIDE_HEIGHT for why
; that is the convention. Both records carry five each way.
CHARACTER_HALF_U	EQU		5
CHARACTER_HALF_V	EQU		5

; The box round a doorway that counts as standing in it.
;
; INHERITED from Knight Lore, not measured. Working these out means walking him
; into an arch and watching where the room changes, which wants the controls
; settled first. They are the right shape -- the same engine reads them the
; same way -- but treat them as a starting point.
DOOR_ACROSS		EQU		6
DOOR_ALONG		EQU		15
DOOR_LEVEL		EQU		4
DOOR_HEIGHT		EQU		13		; Z up to twelve above the arch's floor

; The jump, and this is the one that differs from Knight Lore, which gives its
; knight 8.
;
; Measured: from a standstill at Z=128 he rises +7, +6, +5, +4, +3, +2, +1 and
; peaks at 156 -- 7+6+5+4+3+2+1 is 28, and 128+28 is exactly the 156 observed.
; The value here is 8, not 7, because the engine's gravity takes its unit off
; in the same turn the jump starts, so the first step it takes is one less
; than this. At 7 the remake rose +6 first and peaked at 149.
CHARACTER_JUMP_DZ	EQU		8

; Measured, and it is not Knight Lore's -8. Stepping off the walkway in room 93
; he falls 176 to 128 at -2, -4, -6, -8, -10, -12 and lands still speeding up,
; and a held jump comes down through -9. So if the original has a limit at all
; it is past 12. The highest thing in the room data to fall from is 89 above
; the floor, which a fall from rest reaches at -18 -- so -18 is no limit for
; any fall the game can produce, while the engine keeps its bound.
CHARACTER_FALL_MAX	EQU		-18 & $FF

; How far he walks in a turn. Measured: holding the walk row, his U moves in
; steps of exactly 3, every time.
CHARACTER_STEP		EQU		3


; ---------------------------------------------------------------------------
; Called by the engine with the step in D, E before a walk, and may adjust it.
;
; Walking near a doorway lines him up with it, a unit a turn along its wall,
; towards the middle of the opening -- the original does it: walking out of
; room 92 its V went 119, 122, 127 as he reached the east door. This is Knight
; Lore's character_steer (see ../knightlore/knight.s for the whole account),
; with one change: the middle of the opening is room_door_mid, not the middle
; of the wall, because Pentagram's raised doorways stand off to one side.
;   IX -> the legs record
;   D, E - the step for his facing, which this may add a unit to
; Corrupts AF, BC, HL.
character_steer:	ld		c,0
.side:				ld		b,0
					ld		hl,room_door_z
					add		hl,bc
					ld		a,(hl)
					or		a
					jr		z,.next		; no arch this side
					sub		(ix+OBJ.Z)
					call	character_door_find.abs
					cp		DOOR_LEVEL
					jr		nc,.next

					ld		hl,room_door_mid
					add		hl,bc
					ld		a,(hl)		; where the opening is centred along the wall
					ld		hl,room_door_at
					add		hl,bc
					ld		l,(hl)
					ld		h,a		; H = its centre U, L = its centre V, for
					bit		0,c		; north and south, which stand in a wall
					jr		z,.centred		; across V
					ld		a,h
					ld		h,l
					ld		l,a		; ...and the other way round for east and west

.centred:			ld		a,(ix+OBJ.U)
					sub		h
					call	character_door_find.abs
					cp		DOOR_ALONG
					jr		nc,.next
					ld		a,(ix+OBJ.V)
					sub		l
					call	character_door_find.abs
					cp		DOOR_ALONG
					jr		nc,.next

					bit		0,c
					jr		z,.along_u
					ld		a,l		; east or west: V towards its centre
					cp		(ix+OBJ.V)
					ret		z
					ld		a,1
					jr		nc,.v
					neg
.v:					add		a,e
					ld		e,a
					ret
.along_u:			ld		a,h		; north or south: U towards its centre
					cp		(ix+OBJ.U)
					ret		z
					ld		a,1
					jr		nc,.u
					neg
.u:					add		a,d
					ld		d,a
					ret

.next:				inc		c
					ld		a,c
					cp		4
					jr		c,.side
					ret


; ---------------------------------------------------------------------------
; His top half looking about as he goes.
;   A - block + phase in, the body frame to show out
;   IX -> his legs
; Corrupts C. Returning A unchanged means no glance.
;
; Knight Lore gives its knight a glance of his own -- see ../knightlore/glance.s
; -- and whether Sabreman does the same here has not been established. Until
; then he does not, which is a valid answer rather than a stub.
walker_glance:		ret
