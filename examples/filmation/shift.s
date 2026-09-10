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
;
; $B3 is not the worst room, though, and sizing the arena to it was a bug --
; a quiet one, because a failed allocation is not an error here: the object
; falls back to byte-aligned and draws up to seven pixels left of where it
; belongs. Room $88 wants 2,728 bytes across 10 objects, so three of them
; missed out and stood seven pixels left of true -- one of them the right-hand
; half of the far corner, which is why the two walls did not meet there.
;
; So the size is measured rather than guessed. Every room in the castle was
; built in turn and its objects' sub-byte offsets totted up; the hungriest is
; $97 at 4,922 bytes, with $CF, $D5, $D4, $D3 and $67 all above 4,600. 5,120
; covers the castle with a little to spare.
;
; It is worth keeping in mind that this is a fallback that hides itself. If
; the sprite set or the placement ever changes, this number wants
; re-measuring -- the failure will not announce itself.

SHIFT_ARENA_SIZE	EQU		5120

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
