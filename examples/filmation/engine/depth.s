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


; Compare the object being placed, in IX -- whose bounds depth_cmp_setup has
; hoisted into the immediates below -- against the candidate in IY.
;
; On any axis where the two boxes do NOT overlap, that axis's coordinate
; is part of the key; where they DO overlap the axis says nothing and
; contributes nothing. Summed, that is exactly Head Over Heels' seven-
; case dispatch table -- their key is always the sum over the non-
; overlapping axes -- with no dispatch at all. Three axes overlapping is
; interpenetration and gives the empty sum, which is the right
; degenerate answer for free. (Z is the exception: it votes, but its term
; is left out of the sum -- see there.)
;
; The SIGNS are ours, not theirs. object_place sends +U down the screen
; and +V up it, so the projection's null direction -- which for an
; orthographic projection IS the depth axis -- is (1,-1,1), and depth is
; U - V + Z. Head Over Heels' U + V + Z comes from a projection where
; both floor axes descend. Change object_place and this must follow.
;
; Out: cf = 1  the placed object is FURTHER than the candidate
;      a  = 0  every axis that separates them agrees, so that is certain;
;              any other value and the ordering is only a guess
;      zf = 1  the same thing: certain. The scans test Z rather than A, so
;              the certain answers must keep coming from XOR A and the
;              guess must keep ending in INC A.
; Corrupts A, BC, DE, HL. IX, IY and the shadow set are untouched. IX is read
; for the two centres -- once per separating floor axis, which is seldom enough
; that hoisting them too cost six bytes of setup to save twelve T a time.
;
; depth_cmp_hl takes the candidate in HL instead, and leaves it in IY -- which
; is where every caller wants it afterwards.
depth_cmp_hl:		push	hl
					pop		iy
					; NB: fall through
depth_cmp:			ld		hl,0		; running difference, signed
					ld		b,l		; which of us the separating axes name

					; Each axis votes with one of two SETs, and the first of them
					; hops the second with a $11: LD DE,nn takes the SET's two
					; bytes as its operand. DE is free there -- the axis's term
					; loads it straight after -- and it is a byte smaller and two T
					; quicker than a JR.
					;
					; E holds the half-width for the two bounds, read once. Reading
					; it from the record for each was a byte more an axis, and 11 T
					; more whenever the first bound does not settle it.

					; U -- nearer as U grows
					ld		c,(iy+OBJ.U)		; c = their centre
					ld		e,(iy+OBJ.SIZE_U)		; e = their half-width
					ld		a,c
					add		a,e		; a = their max
.u_min:				cp		0		; imm = our min + 1
					jr		c,.u_near		; their max <= our min: we are nearer
					ld		a,c
					sub		e		; a = their min
.u_max:				cp		0		; imm = our max
					jr		c,.u_over		; their min < our max: they overlap
					set		1,b		; their min >= our max: they are nearer
					DB		$11		; ld de,nn: over the SET
.u_near:			set		0,b
.u_term:								ld		a,(ix+OBJ.U)		; our U
					sub		c
					ld		e,a
					sbc		a,a		; sign-extend the borrow
					ld		d,a
					add		hl,de
.u_over:			

					; V -- FURTHER as V grows, so the operands swap, the term
					; negates, and so does which of us a separation names
					ld		c,(iy+OBJ.V)
					ld		e,(iy+OBJ.SIZE_V)
					ld		a,c
					add		a,e
.v_min:				cp		0
					jr		c,.v_far		; their V is the lower: they are nearer
					ld		a,c
					sub		e
.v_max:				cp		0
					jr		c,.v_over
					set		0,b
					DB		$11		; ld de,nn: over the SET
.v_far:				set		1,b
.v_term:			ld		a,c		; a = their V
					sub		(ix+OBJ.V)		; theirV - ourV
					ld		e,a
					sbc		a,a
					ld		d,a
					add		hl,de
.v_over:			

					; Z -- nearer as Z grows, the same shape as U, but its term is
					; one unit and no more, whatever the height between them. The
					; sum is only read when the separating axes disagree, and when
					; one of them is Z that is something above and behind
					; something else -- the knight's body over the top of a table
					; he is pushing, whose box starts where the table's ends.
					; Counting the whole of Z there put the body in front by a
					; unit, twelve up against eleven back; the floor is what the
					; eye goes by, and any floor term at all outvotes this one.
					;
					; A single unit still breaks a tie, which is what it is for.
					; Room $B3 has a spike and a block whose floor terms cancel
					; exactly, and a ball that is certainly nearer than the spike
					; and certainly further than the block: order those two by a
					; coin toss and the ball has nowhere in the list it can go.
					ld		a,(iy+OBJ.Z)
					ld		c,a
					add		a,(iy+OBJ.SIZE_Z)
.z_min:				cp		0
					jr		c,.z_near
					ld		a,c
.z_max:				cp		0
					jr		c,.z_over
					set		1,b
					dec		hl		; and the one unit of tie-break above
					jr		.z_over
.z_near:			set		0,b
					inc		hl
.z_over:

					; What decides it is not how MANY axes separate the two but
					; whether they agree. Two axes that both say the same object
					; is in front are more certain than one, not less -- this
					; used to count them and call anything but a single axis a
					; guess, and a guess does not stop the scan, so a guard with
					; a spike to its east and below it walked straight past the
					; spike in the list and drew in front of it.
					;
					; Only b = 3 is genuinely ambiguous: one axis saying we are
					; in front while another says they are, which is the
					; non-transitive case the lagging insertion point exists for.
					; b = 0 is interpenetration, and just as unanswerable.
					;
					; The direction comes from b and not from the sum, because a
					; separating axis can still give a zero term: a box of no
					; height sits at the same Z as the one standing on it, and
					; the two are disjoint all the same.
					;
					; So b - 1 == 0 is the first, b - 2 == 0 the second, and every
					; other value -- 0 and 3 -- falls out of the bottom to the guess.
					xor		a		; a = 0 and cf clear, and DEC B leaves both alone
					dec		b
					ret		z		; b was 1: nearer, and cf already says so
					dec		b
					jr		nz,.guess		; b was 0 or 3: nothing certain to go on
					scf
					ret				; b was 2: further
.guess:				sla		h		; cf = sign of the difference, which is
					inc		a		; the best guess there is. INC leaves cf alone
					ret

					; Each DB $11 above is LD DE,nn eating the two bytes of the SET that
					; follows it. Put a third byte there and it would eat half of it, so
					; the assembler is made to check the length rather than a reader.
					ASSERT	depth_cmp.u_term - depth_cmp.u_near == 2
					ASSERT	depth_cmp.v_term - depth_cmp.v_far == 2


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
; The list is furthest first, so an object is still in place if it is not
; further than the ones before it and not nearer than the ones after it -- a
; guess counts either way. Usually the neighbours settle it: a certain answer
; from each costs two depth_cmp calls instead of a scan down the whole list,
; and it is the common case: an object creeping a unit per frame changes its
; place in the order only every several frames.
;
; But a neighbour that can only guess settles nothing, and the check walks on
; past it, back and forward, until an answer is certain -- the way the
; insertion scan walks on past a guess. Stopping at the neighbour missed room
; $A3: the moveable block rides the hunting ball, which carried it in under the
; feet of a knight standing still beside it. The two had been guessed apart
; and he was ahead of it in the list, rightly; under his feet he is certainly
; the nearer, but between the two lay a spike and a spiked ball that the block
; could only guess about, so its look at its neighbours said "in order", he
; took no step to be re-sorted by, and the block's top stayed drawn over his
; legs.
;
; When it has crossed one, it comes out and goes back in, and which neighbour
; it crossed says where the scan may start:
;
; Later, and starting where it already is gives the same answer as starting
; from the front: everything ahead of it was not-further last time it was
; placed, and moving nearer cannot have changed that.
;
; Earlier is not the mirror of that, and it took a measurement to believe it.
; Backing up to a point and scanning forward from there loses what the scan
; learns on the way down -- the insertion point, the last object it was NEARER
; than -- so it can settle in front of where a scan from the front would put
; it. It differed on 22 frames of 180. So that half goes the long way round,
; and only the cheap half is taken cheaply.
;
; The check jumps straight to whichever scan it needs. It used to be a routine
; of its own, depth_in_order, answering 0 or 1 in A for this one to branch on
; -- which also meant A had to survive depth_unlink in between.
depth_relink:		call	depth_cmp_setup		; its bounds, for every depth_cmp below

					; Against the ones before it, back to where the sorted run starts:
					; there is nothing sorted ahead of that to cross. Each walk starts
					; with IY on the object itself, and steps from it.
					;
					; depth_cmp's Z says whether it was certain: its two certain answers
					; come from XOR A, and its guess ends with INC A.
					push	ix
					pop		iy
.back:				ld		l,(iy+OBJ.PREV)
					ld		h,(iy+OBJ.PREV+1)
					ld		de,(sort_head)
					or		a
					sbc		hl,de
					add		hl,de		; HL back, and ADD HL leaves Z alone
					jr		z,.next		; the front of the run
					call	depth_cmp_hl		; PREV is the record itself here
					jr		c,.earlier		; further than it: it belongs earlier
					jr		nz,.back		; only guessed nearer: and the one before?

					; Against the ones after it, to the tail.
.next:				push	ix
					pop		iy
.on:				ld		l,(iy+OBJ.NEXT)
					ld		h,(iy+OBJ.NEXT+1)
					ld		a,h
					and		a
					ret		z		; the tail: nothing to cross
					call	depth_cmp_hl
					jr		nc,.later		; nearer than it: it belongs later
					ret		z		; certainly further: in order
					jr		.on		; only guessed further: and the one after?

.later:				call	depth_unlink		; later, so on from
					ex		de,hl		; where it came out -- the setup above
					jr		depth_insert_from		; still stands

.earlier:			call	depth_unlink
					jr		depth_insert_placed		; from the front of the run


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
; The insertion point LAGS the scan cursor: an ordering we are only
; guessing at moves the cursor on but is not trusted enough to commit to.
; Isometric depth is genuinely non-transitive -- A in front of B in front
; of C in front of A is constructible -- so there is no total order to
; sort by, and this is why the scan needs the authoritative flag to know
; when it may stop.
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
					jr		c,.further
					pop		de		; we are nearer: we go after this one,
					push	iy		; so it is the insertion point now
.advance:			ld		l,(iy+OBJ.NEXT)
					ld		h,(iy+OBJ.NEXT+1)
					jr		.scan
.further:			jr		nz,.advance		; only a guess: keep looking -- depth_cmp's
										; Z is whether it was certain
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
