# How depth sorting works

This is a walk through [depth.s](depth.s): what problem it solves, the data it
keeps, how two objects are compared, and how an object gets into the list, out
of it, and back into it after it moves. It ends with who calls what, the
register contracts, and the traps.

The short version: the engine keeps every object in one linked list, furthest
first, and never sorts it. The list is put in order once, when a room is built.
After that an object that moves is taken out and put back in the right place,
and an object whose step is zero costs one OR.

## Contents

1. [The problem](#1-the-problem)
2. [Boxes, and which way is nearer](#2-boxes-and-which-way-is-nearer)
3. [The list](#3-the-list)
4. [Comparing two objects: depth_cmp](#4-comparing-two-objects-depth_cmp)
5. [There is no "certain" any more](#5-there-is-no-certain-any-more)
6. [Putting an object in: depth_insert](#6-putting-an-object-in-depth_insert)
7. [The background run: background_insert](#7-the-background-run-background_insert)
8. [Taking an object out: depth_unlink](#8-taking-an-object-out-depth_unlink)
9. [Moving an object: depth_step and depth_relink](#9-moving-an-object-depth_step-and-depth_relink)
10. [Who calls what](#10-who-calls-what)
11. [Register contracts and state](#11-register-contracts-and-state)
12. [Traps](#12-traps)
13. [Tests](#13-tests)

---

## 1. The problem

The screen is drawn with the painter's algorithm. `objects_draw_all` walks the
list from `object_list` and blits each object over the ones before it, so an
object drawn later covers an object drawn earlier. For the picture to be right,
anything that should appear in front of something else has to come after it in
the list. The list is therefore kept **furthest first**.

Knight Lore worked out this order afresh every frame, in
`calc_display_order_and_render` at `$CEBB`. It scanned its objects for one
that nothing else hides, drew it, and started the scan again -- O(n²) at best,
with an eight-entry list at `$D01A` to catch the cycles that scan can fall
into. This engine follows Head Over Heels instead: the order is a standing
property of the list, repaired one object at a time when that object moves.

The *comparison* is Knight Lore's, though, arrived at here independently and
only later checked against its code. Its test at `$CEF8` sorts each axis into
the same three states this one does -- we are clear of them, they are clear
of us, or the boxes overlap -- and folds the three into a base-3 index into a
27-entry jump table at `$CF69`. Decoded, that table carves the 27 cases up
exactly as [section 4](#4-comparing-two-objects-depth_cmp) does, and its near
direction is `+X, -Y, +Z`: the same signs. (Addresses from tcdev's
disassembly as converted by Michael R. Cook; facts only, nothing copied.)

## 2. Boxes, and which way is nearer

### The box

Every object is a solid box in world coordinates, held in its record:

| Axis | Record fields | The box covers |
|---|---|---|
| U, a floor axis | `U`, `SIZE_U` | `U - SIZE_U` to `U + SIZE_U` |
| V, a floor axis | `V`, `SIZE_V` | `V - SIZE_V` to `V + SIZE_V` |
| Z, height | `Z`, `SIZE_Z` | `Z` to `Z + SIZE_Z` |

U and V are **centres with half-widths**. Z is **the base with a height**, so
`Z = 0` stands on the floor. depth_cmp, collide_box and object_overlaps all use
the box this way.

Two boxes that only **touch** count as apart. A box from 36 to 44 and one from
44 to 52 do not overlap on that axis. This is what lets a stack of cubes, each
exactly `SIZE_Z` above the last, sort cleanly on Z.

### Which way is nearer

`object_place` sends +U down the screen and +V up it, and Z up. For an
orthographic projection, the direction you can move in without changing where a
thing lands on screen is the direction you are looking along. Here that is
`(1, -1, 1)`. So the depth of a point is

```
depth = U - V + Z
```

and bigger is nearer the viewer:

| Moving | Gets |
|---|---|
| U up | nearer |
| V up | further |
| Z up | nearer |

Head Over Heels uses `U + V + Z`, because its projection sends both floor axes
down the screen. The signs here belong to this engine's projection, and if
`object_place` changes, depth_cmp has to change with it.

One consequence: `U+1, V-1, Z+1` is a move straight along the line of sight. It
changes depth but not the picture. That is why the "has it moved?" question is
asked of the step in world coordinates, and never of the screen extents.

## 3. The list

### The links

Each record has two links:

| Offset | Field | Holds |
|---|---|---|
| 0 | `NEXT` | the address of the next object, nearer than this one, or 0 at the end |
| 15 | `PREV` | the address of **the NEXT field that points at this object** |

`PREV` is not a pointer to the previous object. It points at a NEXT field.
Because `NEXT` is at offset 0, the NEXT field of a record *is* the record's
address, so for most objects PREV happens to equal the previous record's
address. For the first object it does not: its PREV points at `object_list`.

`object_list` is a two-byte variable, and the trick is that it looks exactly
like a NEXT field. Everything that writes "the field that points at me" can
write through PREV without asking whether the object is first in the list. That
removes the "am I the head?" branch from both unlink and insert.

```
 object_list          record A              record B              record C
 +---------+          +---------+           +---------+           +---------+
 | NEXT: A-+--------->| NEXT: B-+---------->| NEXT: C-+---------->| NEXT: 0 |
 +---------+    +-----+-PREV    |     +-----+-PREV    |     +-----+-PREV    |
      ^         |     +---------+     |     +---------+     |     +---------+
      |         |          ^          |          ^          |
      +---------+          +----------+          +----------+

   furthest ---------------------------------------------------> nearest
   drawn first                                                  drawn last
```

The list is doubly linked so that taking an object out is a constant-time job.
Nothing walks it backwards: PREV exists only so depth_unlink can splice an
object out without first finding what points at it.

The draw loop fixes where `NEXT` has to be. `objects_draw_all` points SP at a
record and pops: NEXT, then the Y extent, the X extent, the flags and blit
index, and the sprite address. So offsets 0 to 9 are claimed. PREV just has to
be somewhere after that.

### The background run and sort_head

Some objects are scenery that is always behind everything: walls and trees,
flagged `OBJ_BACKGROUND` in the room data. There is no point comparing anything
against them, so they sit in a run at the front of the list and are never
sorted.

`sort_head` marks where the sorted part begins. Like PREV, it holds the address
of a NEXT field: the NEXT field of the last background object, or `object_list`
itself when there is no background.

```
 object_list     wall 1        wall 2        A             B
 +--------+     +--------+    +--------+    +--------+    +--------+
 | NEXT --+---->| NEXT --+--->| NEXT --+--->| NEXT --+--->| NEXT 0 |
 +--------+     +--------+    +--------+    +--------+    +--------+
                               ^
                               |
 sort_head --------------------+    the sorted run starts after wall 2

 |<-------- background -------->|<--------- sorted --------->|
```

The draw loop knows nothing about this. It walks one chain from `object_list`,
and the background simply comes out first.

## 4. Comparing two objects: depth_cmp

depth_cmp compares **the object being placed** with **a candidate in IY**, and
answers one question: is the placed object further than the candidate? Carry
set means further.

It used to answer a second one -- *and how sure are you?* -- which is gone.
[Section 5](#5-there-is-no-certain-any-more) is why, because it is the change
the rest of this file hangs off.

### The first axis that separates decides

On each axis the two boxes are in one of three states:

| State | Test on U | Means |
|---|---|---|
| We are nearer | their max <= our min | answer: carry clear |
| They are nearer | their min >= our max | answer: carry set |
| They overlap | neither | this axis says nothing: ask the next |

The moment an axis separates them depth_cmp returns, and the axes after it are
never read. On V the first two rows swap, because V grows away from the viewer.

Two boxes that only **touch** count as apart. That is what lets a stack of
cubes, each exactly `SIZE_Z` above the last, sort cleanly on Z, and what lets a
box of no height separate from the one it stands on.

If all three overlap the boxes interpenetrate, no order is right, and it
returns "nearer" -- which is where the scan would have left the object anyway.

### Why U, then V, then Z

**U first because it is the one most likely to answer.** Almost everything in a
room is somewhere else along U -- the same fact `collide_gather`'s sweep is
built on -- so most comparisons return from the first test, about 57 T-states
in. That is what makes it affordable for every moving object to walk the whole
run, which is what section 6 does.

**Z last because when a floor axis and Z disagree, the floor is what the eye
goes by.** The knight pushing a table from behind is the case: his body's box
starts at the table's top, so Z says the body is nearer by twelve while U says
it is further by eleven. Ask Z first and the body draws over the table.

**U before V costs nothing**, which is worth showing because it looks as though
it should. Suppose U separates with us nearer and V separates the other way:

```
U separated, we nearer:    dU >= SIZE_U(ours) + SIZE_U(theirs)
V separated, they nearer:  dV >= SIZE_V(ours) + SIZE_V(theirs)
```

`object_place` puts `screenX = U + V`, so the two sprites are

```
d(screenX) = dU + dV >= (SIZE_U + SIZE_V)ours + (SIZE_U + SIZE_V)theirs
```

apart across the screen. A box's half-width in screenX is exactly
`SIZE_U + SIZE_V`, so that sum **is** the distance at which the two sprites
stop overlapping. Two floor axes can never disagree about a pair you can see.

Their order still matters, but only through a third object standing between
them. Room `$B3` is that case, and section 13 has it.

### Worked examples

```
Nearer along U.  Placed at U 60, candidate at U 40, both half-width 5.

  U: their max = 40 + 5 = 45,  our min = 60 - 5 = 55
     45 <= 55, so we are nearer  ->  carry clear, and V and Z are never read
```

```
The floor axes disagreeing.  Placed at U 70 V 90, candidate at U 40 V 50,
all half-widths 5.

  U: their max 45 <= our min 65  ->  we are nearer, carry clear, done.

V would have said the opposite. It is never asked -- and the two sprites are
(70 + 90) - (40 + 50) = 70 apart across a screen where each is 10 half-wide,
so no picture shows the pair.
```

```
Above and behind.  The knight's body at U 101 Z 140 (half 5, height 11),
the table he is pushing at U 112 Z 128 (half 6, height 12).

  U: their max = 118, our min + 1 = 97.   118 < 97?   no.
     their min = 106, our max = 106.      106 < 106?  no.
     So their min >= our max: they are nearer  ->  carry set.

Z, which would have called the body nearer by twelve, is never reached.
```

### The patched immediates and depth_cmp_setup

The placed object is the same for every candidate in a scan, so its bounds are
worked out once. depth_cmp_setup writes them straight into the operands of
depth_cmp's own instructions:

| Label in depth_cmp | Instruction | Operand written by setup |
|---|---|---|
| `.u_min` | `cp n` | our U - SIZE_U + 1 |
| `.u_max` | `cp n` | our U + SIZE_U |
| `.v_min` | `cp n` | our V - SIZE_V + 1 |
| `.v_max` | `cp n` | our V + SIZE_V |
| `.z_min` | `cp n` | our Z + 1 |
| `.z_max` | `cp n` | our Z + SIZE_Z |

So the `cp 0`s in the source are placeholders; the labels exist only to give
setup an address to write to, one byte past each.

The `+ 1` on the mins turns "their max <= our min" into a single compare. CP
sets the carry for "less than", so `cp our_min + 1` sets it for "less than or
equal".

A patched `cp n` is 2 bytes and 7 T-states. Reading the bound out of the record
instead would be at least 3 bytes and 19 T, before redoing the add or subtract
for every candidate. Setup's six stores pay for themselves after about three
candidates.

depth_cmp reads nothing but the candidate in IY and those six bytes. It leaves
IX, HL, B and D alone, which is why the insertion scan can hold its cursor
across the call.

---

## 5. There is no "certain" any more

depth_cmp used to return a second answer in A: whether every separating axis
agreed, or whether they disagreed and the ordering was only a guess. It summed
the separating axes into HL as it went, voted in B, and dispatched on the two
together.

All of that had **exactly one reader**: the insertion scan, deciding whether it
was entitled to stop early. Once the scan was changed to walk the whole run
every time (section 6), both ways of being further came to mean the same thing
-- keep going -- and the votes, the running difference, the one-unit Z
tie-break and the dispatch that read them were all dead. Removing them is what
lets depth_cmp return from its first separating axis, and took it from 100
bytes to 56.

What makes that a repair rather than a loss is that the flag was never sound
enough to lean on. A sort needs a total order: if A is behind B and B is behind
C, then A is behind C. Isometric boxes do not promise that. Three long bars
laid out like a pinwheel can each be partly in front of the next, so A is in
front of B, B in front of C, and C in front of A, and **no list order draws all
three correctly**. Overlap is not transitive either, so one long object can be
undecided against two that are themselves separated:

```
A  block   U  92..108   V  92..108
B  long    U 106..130   V 139..141      (12,1,32) -- one of the castle's own
C  block   U 120..136   V 172..188

A vs B:  U overlaps, V separates  ->  A nearer
B vs C:  U overlaps, V separates  ->  B nearer
A vs C:  U separates              ->  C nearer      ... a cycle
```

A cycle is harmless to a scan that never stops early: the object lands after
the last candidate it was nearer than, and the cycle is the only thing that
order is wrong about. It is *not* harmless to a scan that stops at the first
candidate it is behind, which is what the certainty flag was propping up, and
what section 9 used to need two list walks for.

So the order the list holds is not "sorted" in the usual sense. It is an order
in which the comparison was asked about every pair on the way past, and
resolved as far as anything can resolve it.

---

## 6. Putting an object in: depth_insert

There are three entry points, which fall through into each other:

| Entry | Does | Then |
|---|---|---|
| `depth_insert` | runs depth_cmp_setup for IX | falls into depth_insert_placed |
| `depth_insert_placed` | loads HL from sort_head | falls into depth_insert_from |
| `depth_insert_from` | scans from the NEXT field HL names | links IX in |

The object must not already be in the list. Insert writes its NEXT and PREV and
never reads them.

### The scan

The scan keeps two positions:

- **The cursor, in IY**, the candidate being compared.
- **The insertion point**, the NEXT field the object will be linked after. It
  is kept on the stack for the length of the scan, and starts as the field the
  scan began from.

For each candidate:

| depth_cmp says | Then |
|---|---|
| we are nearer | move the insertion point to this candidate, and move on |
| we are further | move on, and leave the insertion point where it is |
| (no candidate left) | link at the insertion point |

In pseudo-code:

```
at     = start
cursor = *start
while cursor != 0:
    if placed is nearer than cursor:
        at = cursor                     # we go after this one
    cursor = cursor.NEXT
link the placed object after at
```

The object ends up just after **the last candidate it was nearer than**. The
whole run is walked, always.

There is no early exit, and that is deliberate. Stopping at the first candidate
the object is behind would be trusting the relation to be transitive, which
section 5 shows it is not. It is also what pays for the rest: with nothing to
decide about stopping, the scan has one branch and depth_cmp has no verdict to
compute.

### Worked example

The list holds A, B and C at U 20, 40 and 60, all half-width 4. X is inserted
at U 50.

```
start      at = object_list, cursor = A
vs A (20)  X nearer                       at = A
vs B (40)  X nearer                       at = B
vs C (60)  X max 54 <= C min 56: further, so at stays at B
(end)      link after B:  A, B, X, C
```

### The link

`depth_link` splices IX in after the NEXT field HL points at. The scan pops the
insertion point into HL and falls into it:

```
before:   [at] --> F                (F may be 0)

  our NEXT       = F
  our PREV       = at
  *at            = us
  if F != 0:
      F.PREV     = us                (our NEXT field is our address)

after:    [at] --> us --> F
```

background_insert calls the same splice.

---


## 7. The background run: background_insert

background_insert links IX at `sort_head` without comparing it with anything,
then moves `sort_head` to IX, since IX's NEXT field is now the last one in the
background run.

Each background object therefore goes in after the previous one, in room order,
and the sorted run always starts after the newest. Background objects are walls
and trees, which never move, so nothing relinks them.

## 8. Taking an object out: depth_unlink

```
PREV --> [field] --> us --> F

  *[field] = F                        (the field that pointed at us)
  if F != 0:
      F.PREV = [field]

after:  [field] --> F
```

That is the whole routine. Because PREV points at a field, the same two writes
work whether the object was first, in the middle, or last.

Its contract:

- **In:** IX, the object.
- **Out:** DE points at the field that used to point at the object. That is
  where the object came out, and depth_relink uses it.
- **A is kept**, which nothing needs any more: depth_relink used to carry an
  answer across the call in A. It costs nothing to keep -- the last-object
  test is `inc b` / `dec b` rather than `ld a,b` / `or c` -- so it stays.
- **Corrupts** F, BC and HL.

It steps between the two bytes of a field with `inc l` rather than `inc hl`.
That is safe because a NEXT field never starts on the last byte of a page. It is
either at offset 0 of a record, whose low byte is a multiple of 32, or it is
`object_list`, and an ASSERT checks that `object_list` does not end in `$FF`. A
record's own PREV, at offset 15, is well inside its 32-byte slot.

Unlinking does not clear the object's own NEXT and PREV. They are stale
afterwards, and insert overwrites them.

## 9. Moving an object: depth_step and depth_relink

This is the code that runs all the time. Every mover, character half and guard
torso moves through depth_step, and a guard's legs call depth_relink directly.
There are two stages: did it move, and if so, out and back in.

### Stage 1: did the step move it at all?

depth_step takes the step in D, E and A, for U, V and Z, and adds it to the
record. It then ORs the three together. A zero step leaves the object where it
was, so the routine returns. A non-zero step changes at least one coordinate, so
it falls into depth_relink.

The question is asked of the step, at the one moment the step is known, rather
than by saving the position and comparing it later. That is what an earlier
version did, with `extent_save` and `prev_u`, `prev_v` and `prev_z`. Asking
the step instead removed 76 bytes.

**It has to be the step the caller really applies.** That is not always what
the record's DU and DV hold:

| Object | Its step comes from | Why |
|---|---|---|
| a mover | its own DU, DV and DZ | it adds exactly those |
| a guard torso | its own DU, DV and DZ | the same |
| a character half | D and E, and the record's DZ | character_settle adds any shove waiting in DU and DV to the walk, clamps the total into D and E, and clears DU and DV |
| a guard's legs | no step of its own | they are moved onto the torso's new U and V |

The legs are the exception. The wizard's two records start eight units apart,
and mover_move_pair snaps the legs onto the torso every turn, so the legs can
move when the torso's step is zero. mover_move_pair compares the legs' new U and
V with their current ones before writing them, and calls depth_relink only if
either differs.

**The step runs before the screen position is worked out.** Nothing in depth.s
reads the screen extents, and room_adjust, character_lift and object_place
don't write U, V, Z or the sizes. So callers run depth_step first and
object_place afterwards, and the flags from the OR are still intact for its
`ret z`.

### Stage 2: out, and back in from the front

```
depth_relink:   call depth_unlink
                jr   depth_insert       ; which does depth_cmp_setup for us
```

That is the whole routine: five bytes. However little the object moved, it
comes out of the list and is scanned back in from the front of the sorted run.

**What used to be here.** depth_relink was 62 bytes and had a stage of its own
in between. It compared the object with the neighbour before it and the
neighbour after it, and if it was still between the two it returned without
touching the list -- two depth_cmp calls instead of a walk down the whole run,
and it was the common case, since an object creeping a unit a frame crosses
somebody only every several frames. When the check did find a crossing it
unlinked and re-scanned, from `sort_head` if the object belonged earlier and
from where it came out if it belonged later.

It was taken out because it cannot be made right. The check is sound only if
the order is transitive, and [section 5](#5-there-is-no-certain-any-more) shows
it is not: the neighbours either side can both be content while something
further along the list is certainly on the wrong side of you.

Room `$A3` is the case that made it, and `pair_sort_tests.s` still holds the
scene. The moveable block there rides the hunting ball. The knight stood still
on a stack beside it, and the block was ahead of him in the list, which was
right -- side by side, their boxes disagree by axis. Then the ball carried the
block in under his feet, where he is certainly the nearer. Between the two in
the list lay a spike and a spiked ball that the block could only guess about,
so its look at its neighbours said "in order"; the knight had taken no step, so
nothing re-sorted him either; and the block's top stayed drawn over his legs
until something else moved. It had already been patched once, to walk past a
neighbour it was unsure of rather than stop at it, and that patch is what a
full scan does by construction.

**What the full scan buys back.** Three things, and together they more than
pay for the extra walking:

- Nothing needs to know how sure a comparison was, so depth_cmp lost its votes,
  its running sum and its dispatch, and returns from the first axis that
  separates -- 100 bytes down to 56.
- depth_relink lost both walks and the two scan-start cases: 62 bytes down to 5.
- The scan lost its early exit and its certainty test.

That is 105 bytes for the module as a whole, against maybe two or three
thousand T-states a frame -- and the object count is what makes it affordable.
There are only a handful of things moving in a room at once.

**And it is self-repairing**, which the neighbour check could never be. Two
objects that both stood still cannot have come to need a different order
between them, and anything that moved is placed against the whole run again.
An error cannot outlive the frame that made it, so there is no need for a
separate pass to go looking for one.

### depth_step_upper: two-part objects

A character is two records, legs and body, and a guard is a torso over legs.
The two halves share U and V, and the upper half is always the nearer of the
two. So the upper half can never belong in front of the lower one, and every
comparison a scan from the front would make on its way down to the lower half
would come out the same for the upper.

`depth_step_upper` uses this. It takes the lower half in HL, adds the step to
the upper, and then puts both halves in order:

```
upper.UVZ += step;  if step == 0: return
unlink(upper)                  the upper out of the lower's way
relink(lower)                  the lower, against the room
insert(upper, after lower)     the upper, scanned in from right after it
```

HL is the lower record's address, which is also its NEXT field, so the scan can
start from it. Head Over Heels does the same in `EnlistAux`.

**The upper has to be out while the lower is re-sorted.** Left in, it sits
right behind the lower half, and to the lower half it is always in front: it
stands on it. The lower's own scan would then take its upper as the last
thing it was nearer than and settle right in front of it -- which is where
the upper *was*, not where it is going. The knight stepping forward onto the
next block showed it: his legs stayed behind the block while his body went
past it, and the block's top was drawn over his feet until his next step.

Sorting the two halves one after the other like any other object does not get
round it: whichever goes second, the first is still in its way at its old
place. Legs first fails walking forward, as above, and body first fails walking
back.

**The upper is always re-scanned**, from right after the lower half rather
than from `sort_head`. That is not a shortcut past the walk but the rest of
it: the two halves share U and V and the upper is the nearer, so every
comparison a scan from the front would have made on its way down to the lower
half comes out the same for the upper. Room `$38` is what proves the scan is
needed at all -- when the lower half moves back past something, that thing is
left sitting between the two halves.

The lower half's step has to be added before depth_step_upper is called.
character_move only adds it, with depth_add_step, since depth_step_upper
re-sorts it anyway. mover_move_pair re-sorts a guard's legs itself as well,
because when the torso stands still depth_step_upper returns at once, and legs
snapped somewhere new would not be re-sorted at all.

## 10. Who calls what

### When a room is built

1. **room_build** empties the list with the `depth_reset` macro, which is what
   sets `object_list` to 0 and `sort_head` back to `object_list`. It is a macro
   because neither game has the bytes for a CALL; it lives here so that no game
   has to know `sort_head` exists.
2. **room_show** places every object first, so every comparison sees real
   coordinates. Then it inserts each one: `background_insert` if it has
   `OBJ_BACKGROUND`, otherwise `depth_insert`. Only then does it draw anything.
3. **Characters** are added with `object_place` then `depth_insert`, one call
   per half.
4. **Special objects** placed into the room also go through `depth_insert`.

### Every turn

| Caller | Does |
|---|---|
| mover_paint | depth_step with DU, DV and DZ, then room_adjust and object_place |
| a guard's move | the legs: compare and write U and V, depth_relink if they changed. Then the torso: depth_step_upper with its DU, DV and DZ and HL = the legs, which re-sorts the legs again with the torso out of their way |
| character_move_go | the legs: depth_add_step with D, E and DZ, which only moves them. Then the body: depth_step_upper with the same step and HL = the legs, which re-sorts both. Each half then goes through character_place |
| character_place | room_adjust, character_lift and object_place |
| objects_draw_all | walks the list from object_list and draws |

### When something leaves

**object_hide**, in `movers.s`, calls `depth_unlink` when something is taken
out of the room, such as a collectable, then repaints where it was.

### Why no extra repainting is needed

A relink moves one object to a new place in the list. Every other pair of
objects keeps its relative order, so no two objects that did not move can swap.
An object's place in the list only affects the pixels it covers, so repainting
the union of its old and new extents, which the movers already do, covers
everything the relink could change.

## 11. Register contracts and state

### Routines

| Routine | In | Out | Corrupts |
|---|---|---|---|
| depth_unlink | IX | DE = the field that pointed at IX. **A kept**, carry clear | F, BC, HL |
| depth_cmp_setup | IX | the six operands in depth_cmp | AF, B |
| depth_cmp | IY = candidate, setup done | carry = further | A, C, E. Keeps IX, IY, B, D, HL |
| depth_cmp_hl | HL = candidate, setup done | as depth_cmp, with IY = the candidate | A, C, E, IY. Keeps IX, B, D, HL |
| depth_insert | IX | IX linked in | A, BC, DE, HL, IY |
| depth_insert_placed | IX, setup done | IX linked in | A, BC, DE, HL, IY |
| depth_insert_from | IX, HL = the field to start at, setup done | IX linked in | A, BC, DE, HL, IY |
| background_insert | IX | IX linked, sort_head moved | A, BC, DE, HL |
| depth_link | IX, HL = the NEXT field to follow | IX spliced in after it | A, BC, DE, HL |
| depth_add_step | IX, D, E, A = the step | Z set if the step was zero | AF, C. Keeps HL, DE, B |
| depth_step | IX in the list, D, E, A = the step | IX moved, and in order | A, BC, DE, HL, IY |
| depth_relink | IX in the list and moved | IX in order | A, BC, DE, HL, IY |
| depth_step_upper | IX = the upper half, HL = the lower half with its step already added, D, E, A = the upper's step | both in order, IX after HL | A, BC, DE, HL, IY |

### State

| Variable | Where | Holds |
|---|---|---|
| `object_list` | depth.s | the first object, or 0. Doubles as a NEXT field |
| `sort_head` | depth.s | the NEXT field that starts the sorted run |
| `depth_reset` | depth.s, a macro | sets both back to an empty list |
| the insertion point | the stack, during a scan | the NEXT field the object will be linked after |
| six operands | inside depth_cmp | the placed object's bounds, from depth_cmp_setup |

## 12. Traps

- **Never insert an object that is already in the list.** It compares against
  itself, the two boxes interpenetrate, and the scan can pick the object as its
  own insertion point and link its NEXT to itself. The draw loop then never
  ends. `start` in knightlore/main.s has a note about this happening after a failed
  room build.

- **depth_cmp is only valid after depth_cmp_setup for the object being placed.**
  Its bounds live in the code, so any setup for a different object in between
  silently changes the answers. depth_insert_placed and depth_insert_from
  assume setup has run. depth_relink gets it from the depth_insert it jumps
  to; depth_step_upper runs it a second time itself, because re-sorting the
  lower half rewrites it.

- **Give the lower half its step before depth_step_upper.** It re-sorts the
  lower half itself, with the upper out of the way, and then scans the upper in
  from after it. Re-sorting the lower half first as well does no harm, but it
  is compared with an upper half still at its old place, so it cannot be
  relied on to get past anything.

- **Move through depth_step, with the step you really apply.** Changing U, V
  or Z directly skips the re-sort. Passing a zero step when the object did move,
  as the record's DU and DV would be for a character, skips it too.

- **Keep boxes inside the byte.** All the bounds are unsigned 8-bit. A box whose
  low edge would go below 0, such as U = 2 with SIZE_U = 4, wraps to $FE and
  compares as far away. The castle never puts anything near either end of the
  range, and the tests keep clear of it too.

- **Keep NEXT at offset 0 of the record.** Both the draw loop's `pop iy` and the
  PREV-points-at-a-field trick depend on it.

- **PREV is a record address only when it is not sort_head.** Otherwise it may
  be `object_list` or a background object, and must not be read as the previous
  sorted object.

## 13. Tests

[tests/depth_tests.s](tests/depth_tests.s) assembles depth.s on its own, with
no other engine code, and runs 42 tests on the C++ Z80 core. It builds its
lists with its own helpers, so no test depends on the code it is testing. It
covers:

- **depth_unlink** from the middle, the head, the tail and a list of one,
  including DE and A on the way out. The records sit either side of a page
  boundary.
- **depth_cmp** on every axis in both directions -- which checks which axis
  got asked as much as what it answered, since a later axis answering at all
  would mean an earlier one had wrongly separated. Plus a zero-height box on
  top, two agreeing axes, the floor axes disagreeing either way round, room
  `$B3`'s pair both ways, above-and-behind, and interpenetration.
- **depth_insert** into an empty list, before, between and after, and after a
  background object.
- **depth_relink** on an object that has not moved, one moved past either
  neighbour, and one at either end of the run.
- **depth_step** with a zero step on an out-of-order list, the step landing in
  U, V and Z, steps along V alone and Z alone, moving later, moving earlier, a
  move that crosses no one, the tail to the front, and behind a background
  object.
- **depth_step_upper** scanning from after the lower half, moving later, staying
  in order, and a zero step; room `$38`; and the knight in Knight Lore's room
  `$B4` stepping forward onto the next block and back off it, with the room's
  own boxes.

[tests/pair_sort_tests.s](tests/pair_sort_tests.s) runs the two-part
figures' real moves against the real sort: the knight through character_move
and a guard through mover_move_pair. walker_tests.s and mover_tests.s stub the
depth routines to count what a move asks for; this suite assembles walker.s,
mover.s and depth.s together instead, so every step goes through the sort as it
does in the game. It stands the knight, or a guard, on a three-by-three
platform of room `$B4`'s blocks, walks it across in all four directions, and
after every step checks the whole list for a **certain inversion**: an object
before one that every separating axis agrees it is in front of.

That "certain" is the suite's own reading of the two boxes, in
`certainly_nearer`, and deliberately not depth_cmp's. depth_cmp answers from
the first axis that separates the pair and has no notion of how sure it is;
what a picture can be wrong about is narrower -- a pair that *every*
separating axis agrees on. Where the axes disagree the sort may settle it
either way and no test should hold it to one. Asking the boxes rather than
the code under test is also what lets the suite survive a change to the
comparison, which is exactly what it had to do.

On the code before the legs-and-body fix it finds inversions for both figures
in both walks towards the viewer, which is where the legs have to move later
in the list. It also sets up room `$A3`'s corner: the knight standing still on
a stack, and the moveable block stepping in under his feet along V, checked
after every step -- the scene that retired depth_relink's neighbour check,
where it found 12 inversions, the first on the block's first step.

To run them:

```
cpp-core/build.ps1 -Release -Target z80_com_runner
python examples/filmation/engine/tests/run_tests.py depth pair_sort
```

A failure prints the test's name, what was checked, and the value it got
against the one it wanted. The runner exits with the number of failures.
