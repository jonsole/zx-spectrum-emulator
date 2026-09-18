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
					; (8 facing towards: CHARACTER_BODY_UP_TOWARDS in pentagram.s).
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
; peaks at 156. That is an initial 7 with gravity of one a turn, and the peak
; confirms it twice over -- 7+6+5+4+3+2+1 is 28, and 128+28 is exactly the 156
; observed. Knight Lore's 8 would have summed to 36 and peaked at 164.
CHARACTER_JUMP_DZ	EQU		7

; INHERITED. The jump above never reached terminal velocity -- he landed first,
; with the fall still accelerating through -7 -- so this is Knight Lore's
; figure until a longer drop is measured. A room with a high walkway would do
; it.
CHARACTER_FALL_MAX	EQU		-8 & $FF

; How far he walks in a turn. Measured: holding the walk row, his U moves in
; steps of exactly 3, every time.
CHARACTER_STEP		EQU		3


; ---------------------------------------------------------------------------
; Called with the step in D, E before a walk, and may adjust it. The engine is
; happy with a plain RET, and Knight Lore uses it to nudge him round an arch's
; leg so a doorway can be walked through without catching the frame.
;
; Nothing here yet: whether Pentagram needs the same nudge depends on how its
; own arches are shaped, which wants him walked into one first.
;   Corrupts AF, BC, HL.
character_steer:	ret


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
