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
; built in turn and its objects' sub-byte offsets totted up; the hungriest was
; $97 at 4,922 bytes, with $CF, $D5, $D4, $D3 and $67 all above 4,600, and
; 5,120 covered the castle with a little to spare.
;
; It buys more than rotation now. A piece the room data marks OBJ_CACHE is
; drawn from a private copy of its graphic, out of the same arena, and that
; costs up to 1,398 bytes in a room -- one copy a graphic, not one a piece.
;
; The walls and the trees used to be marked OBJ_SHARED_SHIFT so that they
; rotated into shift_shared at draw time rather than each holding a buffer.
; That took the hungriest room from 5,682 bytes to 4,122 and let the arena be
; 4,608. They are not marked any more and the arena is 6,144, because the trade
; turns out badly as soon as anything else is moving: rotating at draw time is
; work done again on every redraw, and a wall is redrawn once per region. It
; was the single largest item in the frame -- 14 ms of a 62 ms turn in room
; $9B, more than the blitting it fed, and dropping it took that room from 16
; turns a second to 21.
;
; Measured, not guessed, and measured again since: every room entered in turn
; and played for a hundred turns, with shift_arena_next read every turn, so
; that a mover taking its buffer several turns in is counted too. The hungriest
; are $41 and $BE at 5,718, then $01 at 5,624, $CF at 5,466 and $97 at 5,404.
; 5,760 leaves the worst room 42 to spare and no room in the castle is refused
; anything.
;
; A refusal is not silent. It falls back on rotating at draw time, which is
; slow but in the right place, where it used to fall back on drawing
; byte-aligned, which is fast and up to seven pixels wrong. So this number is a
; budget for speed and no longer something the picture breaks on -- but it
; still wants re-measuring if the artwork or the placement changes.
;
; Leaving the high scenery out of the arena was tried on paper and does not
; work: a wall is only about forty-eight rows tall on screen, so a knight
; standing at the back wall already has his head within a few rows of the tier
; above, and a jump covers the rest. Every buffered piece is reachable, and the
; fourth hungriest room -- $87, the gates -- has no high scenery at all, so
; there is nothing there to win.

SHIFT_ARENA_SIZE	EQU		4992

; Every buffer carries two bytes in front of it saying what is in it: the
; graphic, and then the shift and the way round with bit 7 set, or zero for
; nothing yet. object_update rotates into a buffer only when those have
; changed. A mover used to re-rotate on every step, and most steps do not
; change what is rotated at all: a ghost going diagonally moves U and V
; together, so the screen x moves in whole bytes and the shift never changes.
; That was 14,000 T a step for a block.

shift_arena:		DS		SHIFT_ARENA_SIZE
shift_arena_next:	DW		shift_arena


; The one buffer every OBJ_SHARED_SHIFT object rotates into, on its way to
; being blitted. One is enough because it is filled immediately before the blit
; reads it and nothing has to survive the object that filled it -- which is
; exactly how Head Over Heels does all of its rotation, with a single Buffer at
; $BF20.
;
; Sized for the largest rotated form in the sprite set: sprite_071, the arch
; leaf, three bytes wide and 52 rows, which rotates to four columns of mask and
; data -- 416 bytes. Like the arena, this wants re-measuring if the artwork
; grows, and like the arena it will not say so itself.
SHIFT_SHARED_SIZE	EQU		416

; Reserved down in the castle's own memory, with the view buffer and the pool
; -- see the foot of filmation.s. It is written once and read once per
; object drawn, so contention costs it almost nothing, and the code region
; had run out of room for it.


; Every object that survives objects_draw_all's filter comes through here on
; its way to the blit. SHIFT is zero for all but the marked ones, so this is
; usually a load, a test and a return.
;
;   HL -> the sprite's bitmap
; The object comes from draw_object, which objects_draw_all patches as it
; walks the record -- see there for why IY cannot be used.
; Preserves everything, the flags included.
shift_if_deferred:	push	af
					push	iy
draw_object:		ld		iy,0		; patched: the record + 10, where the
					; walk had got to when it stored SP
					ld		a,(iy+OBJ.SHIFT-10)
					or		a
					call	nz,shift_at_draw
					pop		iy
					pop		af
					ret


; Rotate this object's sprite into the shared buffer, for objects_draw_all.
;
;   HL -> the sprite's bitmap, the way round this object wants it
;   IY -> the object, as shift_if_deferred has just set it: the record + 10
; Returns HL -> the shared buffer, and preserves everything else, both
; register sets included -- the caller is mid-blit and every one of them is
; live.
shift_at_draw:		push	bc
					push	de
					push	ix
					exx
					push	bc
					push	de
					push	hl
					exx
					ex		af,af'
					push	af
					ex		af,af'

					push	iy
					pop		ix
					ld		bc,-10
					add		ix,bc		; the rotation wants the record itself, in IX

					; The blit index has already been widened to the rotated
					; width, at placement; the rotation wants the artwork's own.
					ld		a,(ix+OBJ.BLIT_IDX)
					sub		JUMP_GROUP
					ld		(ix+OBJ.BLIT_IDX),a

					dec		l		; hl -> the height byte. SPRITE is the record
					; + 2 and records are ALIGN 4, so this cannot borrow
					ld		de,shift_shared
					ld		a,(ix+OBJ.SHIFT)
					call	object_update.rotate

					ld		a,(ix+OBJ.BLIT_IDX)
					add		a,JUMP_GROUP		; put the drawn width back
					ld		(ix+OBJ.BLIT_IDX),a
					ex		af,af'
					pop		af		; the x overlap, back into the shadow
					ex		af,af'
					exx
					pop		hl
					pop		de
					pop		bc
					exx
					pop		ix
					pop		de
					pop		bc
					ld		hl,shift_shared
					ret


; Where the arena starts handing out. The knight's two buffers are taken once,
; at the start of the game, and kept: the arena is given out in the order
; things ask for it and he is added after the room is built, so a room that
; asks for more than there is would have refused HIM -- and he is the one thing
; redrawn every turn, so he is the worst of them all to leave rotating at draw
; time. Scenery asked for later goes without instead, which costs only the
; redraws it is in.
shift_kept:			DW		shift_arena

; Hand back everything but those. Called when a room is built; every other
; object in the old room loses its buffer with it, which is the point.
shift_reset:		ld		hl,(shift_kept)
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
; Preserves HL. If the arena is full, BUF_L/BUF_H are left alone and the
; object is marked OBJ_SHARED_SHIFT instead, to rotate into the shared buffer at
; draw time -- slower every time it is drawn, but in the right place. All three
; callers wanted exactly that, so it is done once, here.
shift_alloc:		push	hl
					ld		a,(hl)
					sprite_width_class
					add		a,3		; width - 2, so this is width + 1
.sized:				add		a		; two bytes a column
					ld		e,a
					ld		d,0		; de = bytes in one row
					inc		hl
					ld		b,(hl)		; rows
					ld		hl,0
.size:				add		hl,de
					djnz	.size		; hl = bytes wanted
					inc		hl
					inc		hl		; and two in front -- see ROTATED_GFX


					ld		de,(shift_arena_next)
					add		hl,de		; where the block would end
					push	de		; and where it starts
					ex		de,hl
					ld		hl,shift_arena + SHIFT_ARENA_SIZE
					or		a
					sbc		hl,de		; what is left after it
					pop		hl		; the start again
					jr		c,.full		; less than nothing: no room

					xor		a
					ld		(hl),a		; nothing rotated into it yet
					inc		hl
					ld		(hl),a
					inc		hl
					ld		(ix+OBJ.BUF_L),l
					ld		(ix+OBJ.BUF_H),h
					ld		(shift_arena_next),de
					pop		hl
					ret

					ASSERT	OBJ_SHARED_SHIFT == 1 << 3
.full:				set		3,(ix+OBJ.FLAGS)		; OBJ_SHARED_SHIFT
					pop		hl
					ret


; As shift_alloc, but for a straight copy rather than a rotated one: nothing
; spills sideways, so the sprite's own width exactly.
copy_alloc:			push	hl
					ld		a,(hl)
					sprite_width_class
					add		a,2		; the blit index holds width - 2
					jr		shift_alloc.sized


; Take a private copy of the graphic this object is carrying, so that nothing
; else can mirror it out from under us.
;
; A graphic is shared by everything drawn from it, and an object that wants it
; the other way round mirrors it where it lies. That is fine until two of them
; are on screen at once wanting opposite orientations: then every draw mirrors
; the whole sprite back, 10,251 T at a time for the castle arch, twice a region
; for as long as both are in one. Room $88's two right-hand arches are exactly
; that pair, and it cost 85% of the frame to stand in front of them.
;
; Rotating already gives an object private bytes -- that is why sprite_orient
; skips a shifted one -- so this is the same answer for the objects that do not
; rotate, and it is settled once at placement rather than twice a frame.
;
;   IX -> the object, its buffer already allocated
;   HL -> the sprite's height byte, where object_update holds it
; Corrupts AF, BC, DE, HL.
sprite_copy:		ld		b,(hl)		; rows
					dec		l		; -> the header. ALIGN 4 makes this safe
					ld		a,(hl)
					sprite_width_class
					add		a,2		; width
					add		a		; two bytes a column
					ld		c,a		; c = bytes in one row
					inc		l
					inc		l		; -> the bitmap
					ld		e,(ix+OBJ.BUF_L)
					ld		d,(ix+OBJ.BUF_H)
					dec		de
					xor		a
					ld		(de),a		; a copy, not a rotation: nothing to reuse
					inc		de
					push	de		; where it lands, for SPRITE below
.row:				push	bc
					ld		b,0		; LDIR wants the count in BC, and the row
					ldir			; counter is in B, so it goes on the stack
					pop		bc
					djnz	.row

					pop		hl
					ld		(ix+OBJ.SPRITE_L),l
					ld		(ix+OBJ.SPRITE_H),h
					set		5,(ix+OBJ.FLAGS)		; private bytes: nothing re-orients
					set		1,(ix+OBJ.FLAGS)		; them, and another piece may share
					ret		
