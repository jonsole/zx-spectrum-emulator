; ---------------------------------------------------------------------------
; Rotation buffers.
;
; An object drawn at a sub-byte X offset has its sprite rotated into a buffer
; first, and the rotated copy has to survive until that object is blitted --
; which is after every object has been updated. So the buffer cannot be
; shared between objects: with one between them, the last object to shift
; would overwrite what the others had prepared and they would all draw its
; bitmap.
;
; One per OBJECT, though, not one per sprite. An animated object shows a
; different frame every few steps and rotates into the same buffer each time,
; so there is no reason to keep a rotated copy of every frame -- which is
; what makes this affordable at all. The consequence is that the buffer has
; to be big enough for the LARGEST frame the object will ever show; see
; shift_alloc.
;
; They come out of a per-room arena rather than being declared per object,
; because which objects need one is a property of where the room puts them:
; a static placed in world coordinates lands on an arbitrary pixel, and only
; the ones that land off the byte grid need rotating. In room $B3 that is 7
; objects of 19, wanting 1,838 bytes between them.

SHIFT_ARENA_SIZE	EQU		2048

shift_arena:		DS		SHIFT_ARENA_SIZE
shift_arena_next:	DW		shift_arena


; Hand the whole arena back. Called when a room is built; every object in the
; old room loses its buffer with it, which is the point.
shift_reset:		ld		hl,shift_arena
					ld		(shift_arena_next),hl
					ret


; Give this object a rotation buffer out of the arena.
;
;   HL -> the sprite record whose size the buffer has to hold
;   IX -> the object
;
; A buffer is (width + 1) columns, because rotating spills into one column
; more than the bitmap has, times the height, times two for the mask and data
; bytes that sit side by side.
;
; object_update calls this the first time an object turns out to need a
; buffer and has none, sizing it from whatever sprite the object is carrying
; at that moment. For a static that is the only sprite it will ever have. An
; ANIMATED object should be given its buffer up front instead, by calling
; this with its largest frame before the object is first placed: a buffer
; already allocated is left alone, so an explicit one always wins.
;
; Preserves HL. Leaves BUF_L/BUF_H alone if the arena is full, which drops
; the object back to being drawn byte-aligned -- see object_update's null
; buffer guard, which is the same fallback.
shift_alloc:		push	hl
					ld		a,(hl)
					rlca
					rlca
					rlca			; the width class, down into the low bits
					and		7		; width - 2
					add		a,3		; ...so this is width + 1
					add		a		; two bytes a column
					ld		e,a
					ld		d,0		; de = bytes in one row
					inc		hl
					ld		b,(hl)		; rows
					ld		hl,0
.size:				add		hl,de
					djnz	.size		; hl = bytes wanted

					ld		de,(shift_arena_next)
					add		hl,de		; where the block would end
					push	hl
					ld		de,shift_arena + SHIFT_ARENA_SIZE
					ex		de,hl
					or		a
					sbc		hl,de		; what is left after it
					pop		hl		; the block end again
					jr		c,.full		; less than nothing: no room

					ld		de,(shift_arena_next)
					ld		(ix+OBJ.BUF_L),e
					ld		(ix+OBJ.BUF_H),d
					ld		(shift_arena_next),hl

.full:				pop		hl
					ret
