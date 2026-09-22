; ---------------------------------------------------------------------------
; The knight: how big he is, how far he walks and how high he jumps, how
; close to an arch counts as being in it -- the numbers engine/walker.s moves
; a character by -- and the nudge that lines him up with an arch as he passes.
; ---------------------------------------------------------------------------

; A character walks into things as one figure, not as the two records it is
; drawn from. Knight Lore says the same thing with its own numbers: the
; knight's legs carry W=5, D=5, H=23 and his body carries H=0, so the whole
; of him is one box hung on the lower half.
COLLIDE_HEIGHT		EQU		23

; What the two kept rotation buffers are sized from -- the biggest frame each
; half can wear, once sprite_source.py has taken the blank rows off. That is a fact
; about the trimmed set, not the game's artwork, so sprite_source.py checks it on
; every build: a buffer too small gets rotated past its end, into the other.
CHARACTER_LARGEST	EQU		sprite_spell_1		; 3x24: the sparkle the legs die and
					; come back as, which is bigger than any walking frame
CHARACTER_TALLEST	EQU		sprite_werewolf_body_9		; 3x29: the werewolf's body, which only a
					; walking character's top half ever wears
CHARACTER_BODY_UP	EQU		12		; how far every body rides above its legs,
					; the same twelve Knight Lore gives the
					; knight. Z is what the depth sort reads, so
					; the height belongs here and not in the
					; pixel nudge.
CHARACTER_Z			EQU		128		; the floor

; How wide a character is, as a half-extent about U and V -- see COLLIDE_HEIGHT
; for why that is the convention. Knight Lore gives the knight five each way.
CHARACTER_HALF_U	EQU		5
CHARACTER_HALF_V	EQU		5

; How close to an arch counts as standing in it: six units across the opening,
; fifteen along it, and in height from just below the arch's floor to one
; object's height above it. Across and along are Knight Lore's own numbers,
; from the box its arches test against ($06/$0F either way round). Its height
; is four either way ($04 in Z), and steering still uses that; standing in the
; doorway does not. A room's edge is behind the knight once he is in the arch,
; and with only four units of height, standing on something there -- a spell,
; a collectable, a block, all twelve tall -- turned the edge back on with him
; already past it, and every step he took was cut to nothing.
;
; No higher than that, though: the doorway lifting the edge is also what would
; let a jump that started in the room carry him into the arch through its top.
; He cannot jump in a doorway (character_jump), and above this height the edge
; holds him back. On something twelve tall his head is at 164, under the
; pillars' 168. A walkway's arch is 48 above the floor's and no side of any
; room has more than one arch, so neither storey reaches the other.
DOOR_ACROSS		EQU		6
DOOR_ALONG		EQU		15
DOOR_LEVEL		EQU		4
DOOR_HEIGHT		EQU		13		; Z up to twelve above the arch's floor

; Knight Lore gives the knight an impulse of eight and then takes one a turn
; off it while the jump key is still down and two once it is let go, so how
; long you hold the key is how high he goes. That is the whole of a
; variable-height jump and it costs one test a turn. Head Over Heels has no
; velocity at all -- a counter of rising steps, four or eight or ten of them,
; at one unit each -- so its jump is the same height however it is asked for.
CHARACTER_JUMP_DZ	EQU		8
CHARACTER_FALL_MAX	EQU		-8 & $FF		; terminal velocity, so that the
					; clamp never has far to walk back

; How far a character walks in a turn.
; Three units a turn, which is what the game walks: move_plyr_W at $CA3A
; is ADD A,$FD and its three siblings match. The clamp still stops him
; exactly on a face, because it walks the step back a unit at a time --
; three only changes how fast the ground goes by, not where he ends up.
CHARACTER_STEP		EQU		3

; Walking near an arch lines him up with it. Every arch in Knight Lore looks for
; the knight inside a box fifteen units either way of its centre and four in
; height, and nudges him one unit a turn along its wall, towards the middle of
; the opening: along U for an arch in the north or south wall, along V for one
; in the east or west. adj_ew and adj_ns at $C7A6, and the choice between them
; goes through adj_arch_tbl by the ARCH's graphic and mirror bit -- IX is still
; the arch when get_sprite_dir reads them -- which is what a north or south
; arch's mirroring selects. It is never across the wall, whichever way he
; faces: walking along the north wall past its arch, the game only lengthens
; his step towards the middle and shortens it after, and he walks straight on.
; Taking the axis from his facing instead pulled him into the doorway.
; calc_plyr_dXY adds the nudge to his step, which is why it only happens while
; he walks.
;
; An arch's centre is the room's doorway table all over again: the wall it
; stands in on its own axis, and the middle of the room on the other.
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

					ld		hl,room_door_at
					add		hl,bc
					ld		l,(hl)
					ld		h,128		; H = its centre U, L = its centre V, for
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
