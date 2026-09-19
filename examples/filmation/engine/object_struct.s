; The object record, on its own so that something assembling without the rest
; of the engine -- tests/depth_tests.s -- can lay records out the same way.

; The stride between records, which the pool's ALIGN fixes.
ROOM_STRIDE         EQU     32

					STRUCT 	OBJ
NEXT:				DS		2
MIN_Y:				DS		1	; byte position
MAX_Y:				DS		1	; byte position
MIN_X:				DS		1
MAX_X:				DS		1
FLAGS:				DS		1	; bit 7 - object is movable
BLIT_IDX:			DS		1	; blit_index
SPRITE_L:			DS		1	; sprite data address: the sprite's own bitmap for an unshifted
							; object, or this object's BUF_L/BUF_H when it was shifted
SPRITE_H:			DS		1

BUF_L:				DS		1	; shift buffer, for a MOVABLE object only -- see
BUF_H:				DS		1	; the object_record macro below

U:					DS		1
V:					DS		1
Z:					DS		1

; PREV does NOT point at the previous object. It points at the NEXT
; FIELD that points at us -- which is that object's own address, since
; NEXT is at offset 0, or object_list itself when we are the head. That
; is what lets depth_unlink and depth_insert skip the "am I the head?"
; branch. Never dereference it as a record.
PREV:				DS		2

; The solid box: U and V are its centre and SIZE_U and SIZE_V its half-widths,
; so it covers U - SIZE_U to U + SIZE_U, and Z is its base with SIZE_Z its
; height. Boxes that only touch count as apart. This is the world footprint,
; not the sprite box -- a sprite w bytes wide sits on a base diamond
; SIZE_U + SIZE_V pixels across and half that in rows.
SIZE_U:				DS		1
SIZE_V:				DS		1
SIZE_Z:				DS		1

; Knight Lore's per-sprite nudges, straight out of its own object table.
; Its set_pixel_adj ($C72B) gives every sprite a small signed offset that
; lines the artwork up with the logical point, and without them a room
; reproduced from its data sits up to 20 pixels out.
;
; ADJ_X is added to the screen x; ADJ_Y is SUBTRACTED from the base row,
; because their pixel Y counts up from the bottom and ours counts down.
ADJ_X:				DS		1
ADJ_Y:				DS		1

; The Knight Lore graphic number this object is drawn from. object_update
; takes it in A and does not keep it, but room building needs it after the
; fact to look the pixel adjustments up, and animation will need it to step
; from one frame to the next.
GFX:				DS		1

; --- and these belong to a character, and to nothing else ------------------
;
; A character is two records that move as one -- legs on the floor, body a
; dozen units above -- and the state that steers them lives in the tail of the
; legs record. A record is OBJ bytes inside a ROOM_STRIDE slot, so this space
; is already there: the room's own objects simply never look at it.
; What Knight Lore calls dX, dY and dZ, at +$09, +$0A and +$0B of its own
; records: what this object would like to do this turn, before anything has
; been allowed to stop it. object_collide cuts them down and whoever asked
; for them applies what is left.
;
; Every object carries them, as in the game, and the room's pool can afford
; it because the seven fields that used to sit here were only ever a
; character's -- facing, walk phase and the graphic bases -- and no piece of
; scenery has a walk cycle. They live past the character's two slots now.
DU:				DS		1		; signed, along U
DV:				DS		1
DZ:				DS		1

; Pixels of sub-byte X, for an object that rotates at DRAW time rather than at
; placement -- see OBJ_SHARED_SHIFT. Zero for everything else, which is what
; objects_draw_all tests. This is the last byte of a ROOM_STRIDE slot.
SHIFT:				DS		1
					
; Which mover routine drives this object, or MOVE_NONE. Knight Lore asks the
; graphic instead -- jump_to_upd_object at $B25C indexes a 256-entry table of
; addresses with byte 0 of the record -- but our rooms are built from templates
; and the template is what says whether a thing moves.
BEHAVIOUR:			DS		1

; Whatever that routine needs to remember between turns. Knight Lore keeps the
; same thing in byte $0D of its records, and numbers the bits by axis: bit 0 for
; U and bit 1 for V, which is also how collide_hit numbers them, so one mask
; serves both the direction a thing is going and the test for whether it just
; ran into something.
MOVE_STATE:		DS		1

; How many rows of this sprite are above the top of the screen.
CLIP_TOP:			DS		1
					ENDS
