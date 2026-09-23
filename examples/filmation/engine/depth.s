; --- depth sorting --------------------------------------------------
;
; Draw order is a property of U, V and Z, held as a permanent invariant
; of the list. Nothing ever sorts: when an object moves it is unlinked
; and re-inserted in one pass, and an object that has not moved costs
; nothing at all. That is Head Over Heels' design. Knight Lore instead
; re-derives the whole order every frame by repeatedly scanning for an
; object nothing occludes and restarting -- O(n^2) at best.


; Head of the depth-sorted list. Empty until start: inserts everything --
; draw order is derived from U/V/Z, never authored. See depth_insert_from.
object_list			DW		0

; Where the SORTED part of the list begins. Everything before it is
; background scenery: drawn first, so always behind, and never compared
; or moved. Like PREV, this is not a pointer to an object -- it is the
; address of the NEXT field that names the first sorted object, which is
; the last background object itself, or object_list when there is no
; background at all.
;
; objects_draw_all does not know about any of this: it walks the one
; chain from object_list and the background simply comes out first.
; Head Over Heels does the same thing with a separate "far" list that
; DrawCore blits before the sorted one.
sort_head			DW		object_list


; Empty the list. A room change keeps nothing: room_build expands this before
; it places anything, and every object goes back in through depth_insert or
; background_insert. It is a macro rather than a routine because the games
; have no bytes to spare for a CALL, and it is here rather than in each of
; them so that sort_head is never named outside this file -- a game that
; emptied object_list and forgot sort_head would leave the sorted run
; starting inside the room that has just gone.
; Corrupts HL.
				MACRO	depth_reset
					ld		hl,0
					ld		(object_list),hl
					ld		hl,object_list		; no background yet: the sorted run is all of it
					ld		(sort_head),hl
				ENDM


; Take an object out of the list.
;
; A NEXT field never ends a page, so the pointers here step with INC L. PREV
; aims at offset 0 of a record, whose low byte is a multiple of ROOM_STRIDE,
; or at object_list, which is asserted. A record's own PREV is well inside
; its slot.
;   IX -> the object
; Out: DE -> the NEXT field that named us, which is where we came out of
; Corrupts F, BC, HL. A is kept.
					ASSERT	(object_list & $FF) != $FF
					ASSERT	OBJ.PREV + 1 < ROOM_STRIDE
depth_unlink:		ld		l,(ix+OBJ.PREV)
					ld		h,(ix+OBJ.PREV+1)		; hl -> the NEXT field aimed at us
					ld		c,(ix+OBJ.NEXT)
					ld		b,(ix+OBJ.NEXT+1)		; bc = whoever follows us
					ld		(hl),c
					inc		l
					ld		(hl),b		; *prev = next
					dec		l
					ex		de,hl		; de -> the field we just wrote
					inc		b
					dec		b
					ret		z		; we were last: nothing behind to fix
					ld		hl,OBJ.PREV
					add		hl,bc
					ld		(hl),e
					inc		l
					ld		(hl),d		; next->PREV = that field
					ret


; Hoist the placed object's bounds into the scan's immediates -- the six CP
; operands inside depth_insert_from. Six stores once per insert, against six
; (ix+d) reads and their adds per candidate if they stayed in the record: it
; pays for itself after about three candidates.
;   IX -> the object
; Corrupts AF, B.
depth_cmp_setup:	ld		a,(ix+OBJ.U)		; the centre, then the max, then
											; back down past it to the min
					ld		b,(ix+OBJ.SIZE_U)
					add		a,b
					ld		(depth_insert_from.u_max+1),a
					sub		b
					sub		b
					inc		a
					ld		(depth_insert_from.u_min+1),a

					ld		a,(ix+OBJ.V)
					ld		b,(ix+OBJ.SIZE_V)
					add		a,b
					ld		(depth_insert_from.v_max+1),a
					sub		b
					sub		b
					inc		a
					ld		(depth_insert_from.v_min+1),a

					ld		a,(ix+OBJ.Z)
					inc		a
					ld		(depth_insert_from.z_min+1),a
					dec		a		; Z again
					add		a,(ix+OBJ.SIZE_Z)
					ld		(depth_insert_from.z_max+1),a
					ret		


; Add a step to an object's U, V and Z.
;   IX -> the object
;   D  - the step in U, E in V, A in Z
; Out: Z set if the step was zero, and so moved nothing
; Corrupts AF, C. HL, DE and B come through.
;
; The step is ORed together before anything is added, so a step of nothing
; costs 27 T rather than the 148 of three read-add-writes it does not need. It
; is ORed again on the way out because the flags of the last ADD are no use: a
; coordinate can wrap to zero.
depth_add_step:		ld		c,a
					ld		a,d
					or		e
					or		c
					ret		z		; nothing to add, and Z says so
					ld		a,c
					add		a,(ix+OBJ.Z)
					ld		(ix+OBJ.Z),a
					ld		a,(ix+OBJ.U)
					add		a,d
					ld		(ix+OBJ.U),a
					ld		a,(ix+OBJ.V)
					add		a,e
					ld		(ix+OBJ.V),a
					ld		a,d		; NZ: it moved
					or		e
					or		c
					ret


; Move an object by a step, and put it back in depth order if that moved it.
;
; The step is the only thing that can say whether an object moved, and this
; is the one moment it is known -- so the question is asked here, of the step
; itself, rather than by saving where the object was and comparing later. A
; zero step leaves U, V and Z as they were, and a non-zero one cannot: adding
; it changes the coordinate.
;
; It has to be the step the caller really applies, which is not always what
; the record's DU and DV hold. A character has already spent those -- they
; carry shoves into his turn and are cleared once added -- so he passes the
; clamped step he walks by. A guard's legs have no step of their own at all,
; and call depth_relink themselves.
;
; Nothing here reads the screen position, so this runs before room_adjust and
; object_place, not after.
;   IX -> the object, in the list
;   D  - the step in U, E in V, A in Z
; Corrupts A, BC, DE, HL, IY.
depth_step:			call	depth_add_step
					ret		z		; no step: nothing to re-sort
					; NB: fall through


; Put an object that has moved back into depth order.
;   IX -> the object, in the list
; Corrupts A, BC, DE, HL, IY.
;
; It comes out and goes back in, scanned from the front of the sorted run --
; every time, however little it moved.
;
; It used to look at its neighbours first and do nothing if it still sat
; between them: two comparisons against a walk down the whole run, and
; almost always enough, since an object creeping a unit a frame crosses
; someone only every several frames. What that check could not do is be
; right. It is sound only if the order is transitive, and isometric boxes
; are not. Room $A3 made the case: the moveable block rides the hunting
; ball, which carried it in under the feet of a knight standing still
; beside it; between the two lay a spike and a spiked ball the block could
; only guess about, so its look either side said "in order" while its top
; stayed drawn over his legs.
;
; A full scan has no such hole, and it is what makes the rest of this file
; small. Nothing needs to know how sure a comparison was -- that answer had
; exactly one reader, the scan deciding whether it might stop early -- so
; the comparison returns from its first separating axis and the scan has one
; branch. Between them that paid for the extra walking in bytes twice over.
;
; It is also self-repairing, which the neighbour check never was. Two
; objects that both stood still cannot have come to need a different order,
; and anything that moved is placed against the whole run again, so a
; mistake cannot outlive the frame that made it.
depth_relink:		call	depth_unlink
					jr		depth_insert		; which does depth_cmp_setup for us


; The upper half of a two-part object -- a character's body, a guard's torso --
; moved by a step, and both halves put back in depth order.
;
; The upper comes out of the list before the lower is re-sorted. That was once
; load-bearing: when depth_relink only looked at its neighbours, the lower found
; its own upper sitting behind it, called that "in order" and never re-sorted at
; all -- the knight stepped forward onto the next block, his legs stayed behind
; it while his body went past, and the block's top was drawn over his feet. A
; full scan cannot be fooled that way: the upper is always the nearer of the
; two, so the scan never takes it as somewhere to go after. The order is kept
; because both halves have to come out regardless and it costs nothing --
; re-sorting the lower first passes both suites.
;
; Then the upper goes back in. The two share U and V and the upper is the
; nearer, so it can never belong in front of the lower. Everything a scan from
; the front would compare on its way down to the lower half it answers the same
; way for the upper, so the scan starts right after the lower half: not a
; shortcut past the walk, but the rest of it. Head Over Heels does the same, in
; EnlistAux.
;
; The upper is re-scanned every turn, never assumed to be in place. Room $38 is
; why that has to be so: the knight stepped down off a block, the lower half
; moved back past it, and the block was left sitting between his two halves --
; his body drawn in front of something it was behind.
;
; The lower half's own step has to be added before this, and a caller that
; re-sorts it as well does no harm: it is re-sorted again here, properly.
;   IX -> the upper record, in the list
;   HL -> the lower record, which is its own NEXT field
;   D  - the step in U, E in V, A in Z
; Corrupts A, BC, DE, HL, IY.
depth_step_upper:	call	depth_add_step		; HL comes through this
					ret		z
					push	hl		; the lower, for the scan that puts us back
					push	hl		; ...and to be re-sorted now
					call	depth_unlink		; us, out of its way
					ex		(sp),ix		; IX the lower, and us kept
					call	depth_relink		; against the room this time
					pop		ix		; us
					call	depth_cmp_setup		; after the lower's: it rewrote them
					pop		hl
					jr		depth_insert_from


; Put an object into the list in depth order. It must not already be in
; the list -- NEXT and PREV are written, not read.
;   IX -> the object
; Corrupts A, BC, DE, HL, IY.
;
; The scan walks the whole sorted run and leaves the object after the LAST
; candidate it was nearer than. It never stops early, and that is the point:
; isometric depth is not transitive -- A in front of B in front of C in front
; of A is constructible from three long boxes -- so an order that is right
; about every pair does not exist, and a scan that stopped at the first
; candidate it was behind would be trusting exactly the thing that is not
; true. Walking on costs the rest of the run and is never wrong about more
; than the cycle itself.
depth_insert:		call	depth_cmp_setup
					; NB: the two entries below assume depth_cmp_setup has already run for
					; this object. depth_step_upper is what relies on that -- it runs setup
					; itself for the upper half and then enters at depth_insert_from.
depth_insert_placed:	ld		hl,(sort_head)		; the front of the SORTED run
					; NB: fall through

; ...and the same, starting at the NEXT field HL names instead of at the front.
;   IX -> the object, HL -> where to start looking
;
; The comparison is written out inside the loop rather than called. This is its
; only caller, and the CALL, the RET and the PUSH HL / POP IY that handed it
; the candidate were 53 T of the ~140 the loop spent around each one. Written
; out, every answer is a CP and a JR straight to where the loop goes next, and
; the axis that runs the other way round simply jumps to the other target: no
; carry to flip on the way out, and no convention about what it would mean.
;
; The candidate is in IY; the placed object's bounds are the six immediates
; depth_cmp_setup patched in below. On each axis the two boxes are in one of
; three states -- their max at or below our min, their min at or above our
; max, or overlapping -- and the first two answer, we are the nearer or they
; are, while the third says nothing and hands the question on. The first axis
; that separates the boxes decides, and the ones after it are never read.
;
; U is asked first because it is the axis most likely to answer: almost
; everything in a room is somewhere else along U -- the same fact
; collide_gather's sweep is built on -- so most candidates cost two loads and
; one CP. Z is asked last because when a floor axis and Z disagree the floor is
; what the eye goes by: the knight pushing a table from behind has his body's
; box starting at the table's top, so Z calls the body nearer by twelve while U
; calls it further by eleven, and asking Z first drew the body over the table.
; U before V costs nothing, because the two floor axes can never disagree about
; a pair you can see: if U separates with us nearer and V with them nearer, the
; sprites are at least (SIZE_U + SIZE_V) apart for each of them along screenX,
; which is exactly the width at which they stop overlapping. Their order still
; matters to a third object between them -- room $B3.
;
; Boxes that only touch count as apart, which is what lets a stack of cubes
; each SIZE_Z above the last separate cleanly on Z. Three overlapping axes is
; interpenetration: no order is right, and the loop falls out of the bottom to
; "nearer", which is where it would have left the object anyway.
;
; The list is walked the way objects_draw_all walks it: SP pointed at a
; record's NEXT field and a POP IY, 24 T against 54 for reading the two bytes
; through IY. Nothing can interrupt -- the engine runs with interrupts off
; for exactly this, see main.s -- but nothing can be pushed either, so the
; insertion point, the NEXT field the object will be linked after, lives in
; B and D rather than on the stack, and the real SP comes back at .commit.
;
; .advance comes first and falls into the comparison, so a candidate that
; turns us away costs no jump back to the top. The field the scan starts
; from is read exactly like a candidate's NEXT, which is what loads the first
; candidate.
depth_insert_from:	ld		(.commit+1),sp		; the real stack, back at the end
					ld		b,h
					ld		d,l		; the insertion point: the field we start from
					push	hl
					pop		iy		; and IY on it, for .advance to read

.advance:			ld		sp,iy
					pop		iy		; IY -> the next candidate
					ld		a,iyh		; no record lives in page 0, so a high
					and		a		; byte of zero is the end and nothing else
					jr		z,.commit

					; U -- nearer as U grows. E holds their half-width for both
					; bounds, read once: a byte less than reading it twice, and 11 T
					; quicker whenever the first bound does not settle the axis.
.each:				ld		c,(iy+OBJ.U)		; c = their centre
					ld		e,(iy+OBJ.SIZE_U)		; e = their half-width
					ld		a,c
					add		a,e		; a = their max
.u_min:				cp		0		; imm = our min + 1
					jr		c,.nearer		; their max <= our min: we are nearer
					ld		a,c
					sub		e		; a = their min
.u_max:				cp		0		; imm = our max
					jr		nc,.advance		; their min >= our max: they are nearer

					; V -- FURTHER as V grows, so the same two tests go the other way
					ld		c,(iy+OBJ.V)
					ld		e,(iy+OBJ.SIZE_V)
					ld		a,c
					add		a,e
.v_min:				cp		0
					jr		c,.advance		; their V is the lower: they are nearer
					ld		a,c
					sub		e
.v_max:				cp		0
					jr		nc,.nearer		; their V is the higher: we are nearer

					; Z -- nearer as Z grows, and the odd one out in shape: the
					; coordinate is the box's base and SIZE_Z its height, so the
					; minimum is Z itself and there is nothing to subtract.
					ld		a,(iy+OBJ.Z)
					ld		c,a
					add		a,(iy+OBJ.SIZE_Z)
.z_min:				cp		0		; imm = our Z + 1
					jr		c,.nearer		; their top at or below our base: we are nearer
					ld		a,c
.z_max:				cp		0		; imm = our Z + SIZE_Z
					jr		nc,.advance		; their base at or above our top: they are nearer
					; nothing separates them: interpenetrating, and nearer it is

.nearer:			ld		b,iyh		; we go after this one, so it is the
					ld		d,iyl		; insertion point now
					jr		.advance

.commit:			ld		sp,0		; patched: the real stack
					ld		h,b
					ld		l,d		; HL -> the field to link after
					; NB: fall through

; Splice IX in after a NEXT field. depth_insert_from falls into it once its
; scan has settled on one, and background_insert calls it with the boundary.
;   IX -> the object, HL -> the NEXT field to follow
; Corrupts A, BC, DE, HL.
depth_link:				ld		e,(hl)
					inc		l
					ld		d,(hl)
					dec		l		; de = whoever follows us
					ld		(ix+OBJ.NEXT),e
					ld		(ix+OBJ.NEXT+1),d
					ld		(ix+OBJ.PREV),l
					ld		(ix+OBJ.PREV+1),h
					push	ix
					pop		bc		; bc = our own address
					ld		(hl),c
					inc		l
					ld		(hl),b		; *field = us
					ld		a,d
					and		a
					ret		z		; nothing follows us
					ld		hl,OBJ.PREV
					add		hl,de
					ld		(hl),c
					inc		l
					ld		(hl),b		; follower->PREV = us
					ret		


; Put an object into the background run: drawn before everything else and
; never sorted, so it is permanently behind. Splices in at sort_head --
; the same splice depth_insert uses -- and then moves sort_head past us,
; so the sorted run now starts after this object.
;   IX -> the object, not currently in any list
; Corrupts A, BC, DE, HL.
background_insert:	ld		hl,(sort_head)
					call	depth_link
					ld		(sort_head),ix		; our NEXT field is the new boundary
					ret
