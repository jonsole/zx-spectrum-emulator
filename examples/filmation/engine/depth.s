; --- depth sorting --------------------------------------------------
;
; Draw order is a property of U, V and Z, held as a permanent invariant
; of the list. Nothing ever sorts: when an object moves it is unlinked
; and re-inserted in one pass, and an object that has not moved costs
; nothing at all. That is Head Over Heels' design. Knight Lore instead
; re-derives the whole order every frame by repeatedly scanning for an
; object nothing occludes and restarting -- O(n^2) at best.


; Head of the depth-sorted list. Empty until start: inserts everything --
; draw order is derived from U/V/Z, never authored. See depth_cmp below.
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


; Compare the object being placed against the candidate in IY.
;
; The FIRST axis that separates the two boxes decides, and the rest are never
; looked at. An axis where the boxes overlap says nothing about depth, so it
; hands the question on; three overlapping axes is interpenetration, and the
; answer there is arbitrary by definition.
;
; The order is U, then V, then Z, and it is not arbitrary:
;
; U first because almost everything in a room is somewhere else along U --
; the same fact collide_gather's sweep is built on -- so it is the axis most
; likely to answer, and answering here is what makes the scan cheap.
;
; Z last because when a floor axis and Z disagree the floor is what the eye
; goes by. The knight pushing a table from behind is the case: his body's box
; starts at the table's top, so Z says the body is nearer by twelve while U
; says it is further by eleven, and letting Z decide drew the body over the
; table.
;
; U before V costs nothing, because the two can never disagree on a pair you
; can see. If U separates with us nearer then our U exceeds theirs by at least
; SIZE_U + SIZE_U, and if V separates the other way then our V exceeds theirs
; by at least SIZE_V + SIZE_V; screenX is U + V, so the two sprites are at
; least (SIZE_U + SIZE_V) + (SIZE_U + SIZE_V) apart across, which is exactly
; the width at which they stop overlapping. Their order still matters to a
; third object standing between them, but no picture shows the pair itself.
;
; The SIGNS are ours. object_place sends +U down the screen and +V up it, so
; the projection's null direction -- which for an orthographic projection IS
; the depth axis -- is (1,-1,1), and depth grows with U, falls with V and
; grows with Z. Change object_place and this must follow.
;
; There is deliberately no "how certain is this?" answer any more. It existed
; for one reader: the insertion scan, deciding whether it might stop early.
; The scan walks the whole run now, so both ways of being further do the same
; thing, and the votes, the running difference and the dispatch that read them
; all went with it. That is also what lets this return from the first axis.
;
;   IY -> the candidate; depth_cmp_setup has run for the object being placed
; Out: cf = 1  the placed object is FURTHER than the candidate
; Corrupts A, C, E. IX, IY, B, D, HL and the shadow set are untouched.
;
; depth_cmp_hl takes the candidate in HL instead, and leaves it in IY -- which
; is where every caller wants it afterwards.
depth_cmp_hl:		push	hl
					pop		iy
					; NB: fall through

					; On the floor axes E holds the half-width for both bounds,
					; read once. That is a byte less than reading it from the
					; record twice, and 11 T quicker whenever the first bound does
					; not settle the axis, against 4 T more when it does.
depth_cmp:			ld		c,(iy+OBJ.U)		; c = their centre
					ld		e,(iy+OBJ.SIZE_U)		; e = their half-width
					ld		a,c
					add		a,e		; a = their max
.u_min:				cp		0		; imm = our min + 1
					jr		c,.nearer		; their max <= our min: we are nearer
					ld		a,c
					sub		e		; a = their min
.u_max:				cp		0		; imm = our max
					jr		nc,.further		; their min >= our max: they are nearer

					; V -- FURTHER as V grows, so the same two tests send us the
					; other way
					ld		c,(iy+OBJ.V)
					ld		e,(iy+OBJ.SIZE_V)
					ld		a,c
					add		a,e
.v_min:				cp		0
					jr		c,.further		; their V is the lower: they are nearer
					ld		a,c
					sub		e
.v_max:				cp		0
					jr		nc,.nearer

					; Z -- nearer as Z grows, and the odd one out in shape: the
					; coordinate is the box's base and SIZE_Z its height, so the
					; minimum is Z itself and there is nothing to subtract.
					ld		a,(iy+OBJ.Z)
					ld		c,a
					add		a,(iy+OBJ.SIZE_Z)
.z_min:				cp		0		; imm = our Z + 1
					jr		c,.nearer
					ld		a,c
.z_max:				cp		0		; imm = our Z + SIZE_Z
					jr		nc,.further

					; Nothing separates them: the boxes interpenetrate and no
					; order is right. Nearer puts us after the candidate, which
					; is where the scan would leave us anyway.
.nearer:			or		a		; cf = 0
					ret
.further:			scf
					ret


; Hoist the placed object's bounds into depth_cmp's immediates. Six stores
; once per insert, against six (ix+d) reads and their adds per candidate if
; they stayed in the record -- it pays for itself after about three of them.
;   IX -> the object
; Corrupts AF, B.
depth_cmp_setup:	ld		a,(ix+OBJ.U)		; the centre, then the max, then
											; back down past it to the min
					ld		b,(ix+OBJ.SIZE_U)
					add		a,b
					ld		(depth_cmp.u_max+1),a
					sub		b
					sub		b
					inc		a
					ld		(depth_cmp.u_min+1),a

					ld		a,(ix+OBJ.V)
					ld		b,(ix+OBJ.SIZE_V)
					add		a,b
					ld		(depth_cmp.v_max+1),a
					sub		b
					sub		b
					inc		a
					ld		(depth_cmp.v_min+1),a

					ld		a,(ix+OBJ.Z)
					inc		a
					ld		(depth_cmp.z_min+1),a
					dec		a		; Z again
					add		a,(ix+OBJ.SIZE_Z)
					ld		(depth_cmp.z_max+1),a
					ret		


; Add a step to an object's U, V and Z.
;   IX -> the object
;   D  - the step in U, E in V, A in Z
; Out: Z set if the step was zero, and so moved nothing
; Corrupts AF, C. HL, DE and B come through.
depth_add_step:		ld		c,a
					add		a,(ix+OBJ.Z)
					ld		(ix+OBJ.Z),a
					ld		a,(ix+OBJ.U)
					add		a,d
					ld		(ix+OBJ.U),a
					ld		a,(ix+OBJ.V)
					add		a,e
					ld		(ix+OBJ.V),a
					ld		a,d
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
; between them: two depth_cmp calls against a walk down the whole run, and
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
; depth_cmp returns from its first separating axis and the scan has one
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
; The lower half is re-sorted here, with the upper out of the list. Left in, the
; upper sits right behind the lower, and to the lower it is always certainly in
; front -- it stands on it. So the lower's look at its next neighbour found its
; own upper and said "in order", and a scan would have stopped there too. That
; is where the upper USED to be, not where it is going: the knight stepped
; forward onto the next block, his legs stayed behind it while his body went
; past, and the block's top was drawn over his feet until his next step.
;
; Then the upper goes back in. The two share U and V and the upper is the
; nearer, so it can never belong in front of the lower. Everything a scan from
; the front would compare on its way down to the lower half it answers the same
; way for the upper, so the scan starts right after the lower half: not a
; shortcut past the walk, but the rest of it. Head Over Heels does the same, in
; EnlistAux.
;
; And the upper is always re-scanned, never given depth_relink's neighbour
; check. Its neighbours are not what matter: when the lower half moves back
; past something, that something is left between the two halves, and the
; upper's own neighbours can still guess it in order. Room $38 did exactly
; that -- the knight stepped down off a block, his legs went in front of it,
; and his body stayed behind it, drawn in front of a block it was behind.
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
					; NB: depth_insert_placed assumes depth_cmp_setup has already run for
					; this object -- depth_relink calls it once and then uses both.
depth_insert_placed:	ld		hl,(sort_head)		; the front of the SORTED run
					; NB: fall through

; ...and the same, starting at the NEXT field HL names instead of at the front.
; Every field this steps across is a NEXT field or a record's PREV, so INC L is
; enough -- see depth_unlink for why neither can end a page.
;   IX -> the object, HL -> where to start looking
depth_insert_from:	push	hl		; the insertion point: the NEXT field we will write,
					ld		a,(hl)		; kept on the stack for the length of the scan
					inc		l
					ld		h,(hl)
					ld		l,a		; the first sorted object, or none
.scan:				ld		a,h
					and		a
					jr		z,.commit		; ran off the end: commit
					call	depth_cmp_hl		; the candidate is in IY from here
					jr		c,.advance		; further than it: it is not our place
					pop		de		; nearer: we go after this one, so it is
					push	iy		; the insertion point now
.advance:			ld		l,(iy+OBJ.NEXT)
					ld		h,(iy+OBJ.NEXT+1)
					jr		.scan
.commit:			pop		hl
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
