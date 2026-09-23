; Sprite record constants and the width unpack, on their own so that something
; assembling without the rest of the engine -- tests/sprite_tests.s -- can use
; them.

; Byte 0 of a sprite record is the blit index, (width - 2) * JUMP_GROUP, so
; bits 4-6 are the width class and the rest are spare. Bit 0 says which way
; round the bytes currently are -- see sprite_flip_h. Knight Lore keeps that in
; the same byte, but at bit 6, which is part of the width field for us. Bit 7
; marks a frame of an animation, whose rotation buffer is rounded up.
;
; The class used to be scaled by 32, when a group held a jump entry for every
; column count as well. One blitter later there is nothing in a group but the
; index arithmetic for its width and, for the widths that can be rotated, the
; entry shift_sprite finishes on -- and sixteen is room enough for both.
;
; Anything that uses byte 0 as a jump-table index must mask it with
; BLIT_IDX_MASK first. The width unpack does not need to: it rotates the class
; down and masks with 7, which drops the spare bits on the way past.
SPRITE_FLIPPED		EQU		0x01
SPRITE_ANIMATED_BIT	EQU		7		; a frame of a mover's animation: see
									; shift_alloc, and ANIMATIONS in sprite_sheet.py
WIDTH_CLASS_SHIFT	EQU		4		; where the class sits in byte 0, and so
JUMP_GROUP			EQU		1 << WIDTH_CLASS_SHIFT		; the stride of a group
SHIFT_FINAL_AT		EQU		JUMP_GROUP - 2		; the shift entry ends a group
BLIT_IDX_MASK		EQU		7 * JUMP_GROUP		; the three class bits, in place


; The width class out of a sprite's byte 0 and down into the low bits.
;
; Four places want this, and they each used to spell it out. When the class
; moved down from bits 5-7 -- one blitter having emptied most of a group --
; three of them were changed and the fourth, shift_alloc, was not: every
; rotated object then got a buffer sized for the wrong width, and they wrote
; over each other in the arena. A macro cannot be changed in three places.
;
; In:  A = byte 0 of a sprite record
; Out: A = width - 2, so add 2 for the width in bytes, or 3 for the width of a
;          rotated copy, which carries one more column
; Corrupts: F
				MACRO	sprite_width_class
				REPT	8 - WIDTH_CLASS_SHIFT
					rlca
				ENDR
					and		7
				ENDM
