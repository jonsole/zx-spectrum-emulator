; The object record, on its own so that something assembling without the rest
; of the engine -- tests/depth_tests.s -- can lay records out the same way.

; The stride between records, which the pool's ALIGN fixes.
ROOM_STRIDE         EQU     32

; The fields are grouped by what they are for: drawing, the depth list, where
; the thing is, what it looks like, and what drives it. The first ten bytes are
; the one part whose order is not free -- see the note on the drawing block.
					STRUCT 	OBJ

; --- drawing: read by objects_draw_all through SP ----------------------------
;
; The draw walk points SP at a record and pops these in this order: NEXT, the
; two extents, FLAGS with BLIT_IDX, SHIFT with CLIP_Y, and SPRITE -- noting
; where SHIFT is as it passes. Moving any of these twelve bytes means rewriting
; that walk; nothing else depends on where a field sits.
;
; NEXT is the depth list's link to the object drawn after this one, and it
; has to be at offset 0: see PREV.
NEXT:				DS		2
MIN_Y:				DS		1	; byte position
MAX_Y:				DS		1	; byte position
MIN_X:				DS		1
MAX_X:				DS		1

; The OBJ_ bits in object.s: movable, background, shifted, cached, shared
; shift, passable, copied, and which way round. Popped into E beside the jump
; index in D, and the draw's orientation check reads it there.
FLAGS:				DS		1
BLIT_IDX:			DS		1	; blit_index

; Pixels of sub-byte X, for an object that rotates at DRAW time rather than at
; placement -- see OBJ_SHARED_SHIFT. Zero for everything else, which is what
; objects_draw_all tests.
SHIFT:				DS		1

; How many rows of this sprite are above the top of the screen. The draw walk
; takes the pair with POP IX: SHIFT into IXL, which it tests for a rotation at
; draw time, and this into IXH, which it subtracts the region's clip from.
CLIP_Y:				DS		1

SPRITE_L:			DS		1	; sprite data address: the sprite's own bitmap for an unshifted
							; object, or this object's BUF_L/BUF_H when it was shifted
SPRITE_H:			DS		1

; --- the depth list's other link ------------------------------------------
;
; PREV does NOT point at the previous object. It points at the NEXT
; FIELD that points at us -- which is that object's own address, since
; NEXT is at offset 0, or object_list itself when we are the head. That
; is what lets depth_unlink and depth_insert skip the "am I the head?"
; branch. Never dereference it as a record. It sits straight after the
; drawing block rather than beside NEXT, because the draw walk pops the
; extents straight after NEXT and would have to step over it.
PREV:				DS		2

; --- the rest of drawing ----------------------------------------------------
;
; The object's own rotation buffer, for a MOVABLE object only -- see the
; object_record macro.
BUF_L:				DS		1
BUF_H:				DS		1

; --- where it is, where it is going, and how big it is -------------------
;
; Its centre on the floor and its base, in world units.
U:					DS		1
V:					DS		1
Z:					DS		1

; What Knight Lore calls dX, dY and dZ, at +$09, +$0A and +$0B of its own
; records: what this object would like to do this turn, before anything has
; been allowed to stop it. object_collide cuts them down and whoever asked
; for them applies what is left. Every object carries them, as in the game.
DU:					DS		1		; signed, along U
DV:					DS		1
DZ:					DS		1

; The solid box: U and V are its centre and SIZE_U and SIZE_V its half-widths,
; so it covers U - SIZE_U to U + SIZE_U, and Z is its base with SIZE_Z its
; height. Boxes that only touch count as apart. This is the world footprint,
; not the sprite box -- a sprite w bytes wide sits on a base diamond
; SIZE_U + SIZE_V pixels across and half that in rows.
SIZE_U:				DS		1
SIZE_V:				DS		1
SIZE_Z:				DS		1

; --- what it looks like ----------------------------------------------------
;
; The Knight Lore graphic number this object is drawn from. object_update
; takes it in A and does not keep it, but room building needs it after the
; fact to look the pixel adjustments up, and animation will need it to step
; from one frame to the next.
GFX:				DS		1

; Knight Lore's per-sprite nudges, straight out of its own object table.
; Its set_pixel_adj ($C72B) gives every sprite a small signed offset that
; lines the artwork up with the logical point, and without them a room
; reproduced from its data sits up to 20 pixels out.
;
; ADJ_X is added to the screen x; ADJ_Y is SUBTRACTED from the base row,
; because their pixel Y counts up from the bottom and ours counts down.
;
; A game with more than 256 graphic numbers (GRAPHIC_COUNT, from its
; graphics_gen.s) keeps ADJ_Y doubled, with bit 8 of the graphic in bit 0:
; the graphic is GFX plus 256 when that bit is set. room_add sets the bit,
; room_adjust keeps it when it writes the nudge, and object_place takes it off
; with an SRA. Graphics a mover steps through keep it, since GFX is all they
; change; code that gives a record a graphic by name clears it.
ADJ_X:				DS		1
ADJ_Y:				DS		1

; --- what drives it --------------------------------------------------------
;
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
MOVE_STATE:			DS		1

; Two bytes a mover may keep whatever it likes in from turn to turn, beyond
; MOVE_STATE. Nothing else reads or writes them, and nothing clears them: a
; mover that uses them sets them when its object is made. The homer keeps its
; sixteenths of a unit along U and V here -- HOMER_ACC_U and HOMER_ACC_V.
DATA_1:				DS		1
DATA_2:				DS		1
					ENDS

; A character is two records that move as one -- legs on the floor, body a
; dozen units above -- and the state that steers them lives past its two
; slots: see CHARACTER_DZ and the rest in walker.s.
