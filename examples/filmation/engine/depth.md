# How depth sorting works

A walk through [depth.s](depth.s): what problem it solves, the data it keeps,
how two objects are compared, and how an object gets into the list, out of it,
and back into it after it moves. It ends with who calls what, the register
contracts, the traps, and an appendix on what the current design replaced.

The short version, in four sentences. Every object in the room is on one linked
list, furthest first, and the draw loop just walks it. Two objects are compared
by their boxes, one axis at a time, and the first axis that separates them
decides. An object that moves comes out of the list and is scanned back in
against the whole run; an object that has not moved costs one `OR`. There is no
sort, and nothing keeps a score.

## Contents

1. [The problem](#1-the-problem)
2. [Boxes, and which way is nearer](#2-boxes-and-which-way-is-nearer)
3. [The list](#3-the-list)
4. [Comparing two objects](#4-comparing-two-objects)
5. [Why there is no sort](#5-why-there-is-no-sort)
6. [Putting an object in: depth_insert](#6-putting-an-object-in-depth_insert)
7. [The background run: background_insert](#7-the-background-run-background_insert)
8. [Taking an object out: depth_unlink](#8-taking-an-object-out-depth_unlink)
9. [Moving an object: depth_step and depth_relink](#9-moving-an-object-depth_step-and-depth_relink)
10. [Who calls what](#10-who-calls-what)
11. [Register contracts and state](#11-register-contracts-and-state)
12. [Traps](#12-traps)
13. [Tests](#13-tests)
14. [Appendix: what this replaced](#14-appendix-what-this-replaced)

---

## 1. The problem

The screen is drawn with the painter's algorithm. `objects_draw_all` walks the
list from `object_list` and blits each object over the ones before it, so an
object drawn later covers an object drawn earlier. For the picture to be right,
anything that should appear in front of something else has to come after it in
the list. The list is therefore kept **furthest first**.

Knight Lore worked the order out afresh every frame, in
`calc_display_order_and_render` at `$CEBB`: it scanned its objects for one that
nothing else hides, drew it, and started the scan again -- O(n²) at best, with
an eight-entry list at `$D01A` to break the cycles that scan can fall into.
This engine follows Head Over Heels instead. The order is a standing property
of the list, repaired one object at a time, when that object moves.

The *comparison*, though, is Knight Lore's, arrived at here independently and
only later checked against its code. Its test at `$CEF8` sorts each axis into
the same three states this one does -- we are clear of them, they are clear of
us, or the boxes overlap -- and folds the three into a base-3 index into a
27-entry jump table at `$CF69`. Decoded, that table carves the 27 cases up
exactly as [section 4](#4-comparing-two-objects) does, and its near
direction is `+X, -Y, +Z`: the same signs. (Addresses from tcdev's disassembly
as converted by Michael R. Cook; facts and credit only, nothing copied.)

---

## 2. Boxes, and which way is nearer

### The box

Every object is a solid box in world coordinates, held in its record:

| Axis | Record fields | The box covers |
|---|---|---|
| U, a floor axis | `U`, `SIZE_U` | `U - SIZE_U` to `U + SIZE_U` |
| V, a floor axis | `V`, `SIZE_V` | `V - SIZE_V` to `V + SIZE_V` |
| Z, height | `Z`, `SIZE_Z` | `Z` to `Z + SIZE_Z` |

U and V are **centres with half-widths**. Z is **the base with a height**, so
`Z = 0` stands on the floor. The scan, collide_box and object_overlaps all
read the box this way.

Two boxes that only **touch** count as apart. A box from 36 to 44 and one from
44 to 52 do not overlap on that axis. That is what lets a stack of cubes, each
exactly `SIZE_Z` above the last, separate cleanly on Z, and what lets a box of
no height separate from the one it stands on.

### Which way is nearer

`object_place` sends +U down the screen and +V up it, and Z up. For an
orthographic projection the direction you can move in without changing where a
thing lands on screen is the direction you are looking along, and here that is
`(1, -1, 1)`. So depth grows with U, falls with V and grows with Z:

| Moving | Gets |
|---|---|
| U up | nearer |
| V up | further |
| Z up | nearer |

Head Over Heels has `U + V + Z`, because its projection sends both floor axes
down the screen. The signs here belong to this engine's projection, and if
`object_place` changes, the scan's axes have to change with it.

One consequence: `U+1, V-1, Z+1` is a move straight along the line of sight. It
changes depth but not the picture. That is why "has it moved?" is asked of the
step in world coordinates, and never of the screen extents.

---

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
write through PREV without asking whether the object is first in the list,
which removes the "am I the head?" branch from both unlink and insert.

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

Nothing walks the list backwards. PREV exists only so that depth_unlink can
splice an object out in constant time without first hunting for what points
at it.

The draw loop fixes where `NEXT` has to be. `objects_draw_all` points SP at a
record and pops: NEXT, then the Y extent, the X extent, the flags and blit
index, and the sprite address. So offsets 0 to 9 are claimed, and PREV only has
to be somewhere after that.

### The background run and sort_head

Some objects are scenery that is always behind everything -- walls and trees,
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
and the background simply comes out first. Head Over Heels does the same thing
with a separate "far" list that `DrawCore` blits before the sorted one.

The `depth_reset` macro sets both variables back to an empty list. It is a
macro rather than a routine because neither game had the bytes for a CALL, and
it lives here so that no game has to know `sort_head` exists -- one that
emptied `object_list` and forgot `sort_head` would leave the sorted run
starting inside the room that had just gone.

---

## 4. Comparing two objects

The comparison is the inner loop of `depth_insert_from`, written out in place
rather than a routine of its own: it has one caller, and the `CALL`, the `RET`
and the `PUSH HL`/`POP IY` that handed the candidate over were 53 T-states of
the ~140 the loop spent around each one. It compares **the object being
placed** -- whose bounds depth_cmp_setup has hoisted into the loop's
immediates -- with **the candidate in IY**, and answers one question: is the
placed object nearer than the candidate? Each answer is a `JR` straight to
where the loop goes next.

### The first axis that separates decides

On each axis the two boxes are in one of three states:

| State | Test on U | Means |
|---|---|---|
| We are nearer | their max <= our min | answer: `jr .nearer` |
| They are nearer | their min >= our max | answer: `jr .advance` |
| They overlap | neither | this axis says nothing: ask the next |

The moment an axis separates the two, the loop moves on; the axes after it are
never read. On V the first two rows swap, because V grows away from the viewer.

If all three overlap the boxes interpenetrate, no order is right, and the loop
falls out of the bottom to "nearer" -- which is where it would have left the
object anyway.

### Why U, then V, then Z

**U first because it is the axis most likely to answer.** Almost everything in
a room is somewhere else along U -- the same fact `collide_gather`'s sweep is
built on -- so most comparisons return from the very first test, 64
T-states in. That is what makes it affordable for every moving object to walk
the whole run, which is what [section 6](#6-putting-an-object-in-depth_insert)
does.

**Z last, because when a floor axis and Z disagree the floor is what the eye
goes by.** The knight pushing a table from behind is the case: his body's box
starts at the table's top, so Z says the body is nearer by twelve while U says
it is further by eleven. Ask Z first and the body is drawn over the table.

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
them. Room `$B3` is that case, and [section 13](#13-tests) has it.

### The exits

Every answer is a `CP` and a conditional `JR` to one of the loop's two
continuations. On V the two go the other way round, because V runs nearer as
it *falls*:

```
.u_min:   cp   <our min + 1>
          jr   c,.nearer          ; their max <= our min: we are nearer
.u_max:   cp   <our max>
          jr   nc,.advance        ; their min >= our max: they are nearer

.v_min:   cp   <our min + 1>
          jr   c,.advance         ; their V is the lower, so THEY are nearer
.v_max:   cp   <our max>
          jr   nc,.nearer

.z_max:   cp   <our Z + SIZE_Z>
          jr   nc,.advance        ; their base at or above our top
          ; fall through: interpenetrating, and nearer it is
.nearer:  pop  de
          push iy                 ; the insertion point is this candidate now
.advance: ...
```

When the comparison was a routine the same answers had to come back in the
carry, and which way round it meant was decided by where `CP` leaves it: right
on U and Z, reversed on V, which cost V a `CCF`. Written out, there is no carry
to flip and no convention about what it means -- the mirrored axis simply
jumps to the other target.

### Worked examples

```
Nearer along U.  Placed at U 60, candidate at U 40, both half-width 5.

  U: their max = 40 + 5 = 45,  our min = 60 - 5 = 55
     45 <= 55, so we are nearer  ->  carry set, and V and Z are never read
```

```
The floor axes disagreeing.  Placed at U 70 V 90, candidate at U 40 V 50,
all half-widths 5.

  U: their max 45 <= our min 65  ->  we are nearer, carry set, done.

V would have said the opposite. It is never asked -- and the two sprites are
(70 + 90) - (40 + 50) = 70 apart across a screen where each is 10 half-wide,
so no picture shows the pair.
```

```
Above and behind.  The knight's body at U 101 Z 140 (half 5, height 11),
the table he is pushing at U 112 Z 128 (half 6, height 12).

  U: their max = 118, our min + 1 = 97.   118 < 97?   no.
     their min = 106, our max = 106.      106 < 106?  no.
     So their min >= our max: they are nearer  ->  carry clear.

Z, which would have called the body nearer by twelve, is never reached.
```

### The patched immediates and depth_cmp_setup

The placed object is the same for every candidate in a scan, so its bounds are
worked out once. depth_cmp_setup writes them straight into the operands of the
loop's own `CP` instructions:

| Label in depth_insert_from | Instruction | Operand written by setup |
|---|---|---|
| `.u_min` | `cp n` | our U - SIZE_U + 1 |
| `.u_max` | `cp n` | our U + SIZE_U |
| `.v_min` | `cp n` | our V - SIZE_V + 1 |
| `.v_max` | `cp n` | our V + SIZE_V |
| `.z_min` | `cp n` | our Z + 1 |
| `.z_max` | `cp n` | our Z + SIZE_Z |

So the `cp 0`s in the source are placeholders; the labels exist only to give
setup an address to write to, one byte past each. They are local to
`depth_insert_from`, so setup names them as `depth_insert_from.u_min` and so
on.

The `+ 1` on the mins turns "their max <= our min" into a single compare: CP
sets the carry for "less than", so `cp our_min + 1` sets it for "less than or
equal".

A patched `cp n` is 2 bytes and 7 T-states. Reading the bound out of the record
instead would be at least 3 bytes and 19 T, before redoing the add or subtract
for every candidate. Setup's six stores pay for themselves after about three
candidates.


---

## 5. Why there is no sort

A sort needs a total order: if A is behind B and B is behind C, then A is
behind C. Isometric boxes do not promise that.

Three long bars laid out like a pinwheel can each be partly in front of the
next, so A is in front of B, B in front of C, and C in front of A. **No list
order draws all three correctly.** And overlap is not transitive either, so one
long object can be undecided against two that are themselves separated:

```
A  block   U  92..108   V  92..108
B  long    U 106..130   V 139..141      (12,1,32) -- one of the castle's own
C  block   U 120..136   V 172..188

A vs B:  U overlaps, V separates  ->  A nearer
B vs C:  U overlaps, V separates  ->  B nearer
A vs C:  U separates              ->  C nearer      ... a cycle
```

Two things follow, and between them they are why the rest of this file is as
small as it is.

**The scan must not stop early.** A cycle is harmless to a scan that walks the
whole run: the object lands after the last candidate it was nearer than, and
the cycle is the only thing that order is wrong about. It is *not* harmless to
a scan that stops at the first candidate it is behind, because stopping is
exactly an appeal to transitivity -- everything after this must be nearer too.

**The comparison needs no notion of how sure it is.** It used to have one, and
the only thing that ever read it was a scan deciding whether it might stop.
With no early exit there is nothing to tell: both ways of being further mean
the same thing, keep walking. That is what lets it leave from its first
separating axis rather than weighing all three.

So the order the list holds is not "sorted". It is an order in which the
comparison was asked about every pair on the way past, and resolved as far as
anything can resolve it.

---

## 6. Putting an object in: depth_insert

Three entry points, which fall through into each other:

| Entry | Does | Then |
|---|---|---|
| `depth_insert` | runs depth_cmp_setup for IX | falls into depth_insert_placed |
| `depth_insert_placed` | loads HL from sort_head | falls into depth_insert_from |
| `depth_insert_from` | scans from the NEXT field HL names | links IX in |

The object must not already be in the list. Insert writes its NEXT and PREV and
never reads them.

### The scan

Two positions are kept: **the cursor**, in IY, the candidate being compared;
and **the insertion point**, the NEXT field the object will be linked after,
held in B and D and starting as the field the scan began from.

The cursor is advanced the way `objects_draw_all` walks the same list: SP is
pointed at the candidate's NEXT field and `pop iy` loads the next one, 24
T-states against 54 for reading the two bytes through IY. Nothing can
interrupt -- the engine runs with interrupts off for exactly this -- but
nothing can be pushed while SP is borrowed either, which is why the insertion
point lives in registers; the real SP is saved on entry and put back at
`.commit`. The end of the list is a high byte of zero, since no record lives
in page 0.

`.advance` sits in front of the comparison and falls into it, so a candidate
that turns the object away costs no jump back to the top. The scan enters at
`.advance` with IY on the field it starts from: that field is a NEXT field like
any other, so reading it as one loads the first candidate.

```
at     = start
cursor = *start
while cursor != 0:
    if placed is nearer than cursor:
        at = cursor                     # we go after this one
    cursor = cursor.NEXT
link the placed object after at
```

The object ends up just after **the last candidate it was nearer than**, and
the whole run is always walked. One branch, no early exit --
[section 5](#5-why-there-is-no-sort) is why.

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

---

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
- **Out:** DE points at the field that used to point at the object.
- **A is kept**, which nothing needs any more -- depth_relink used to carry an
  answer across the call in A. It costs nothing to keep, since the last-object
  test is `inc b` / `dec b` rather than `ld a,b` / `or c`, so it stays.
- **Corrupts** F, BC and HL.

It steps between the two bytes of a field with `inc l` rather than `inc hl`.
That is safe because a NEXT field never starts on the last byte of a page: it
is either at offset 0 of a record, whose low byte is a multiple of 32, or it is
`object_list`, and an ASSERT checks that `object_list` does not end in `$FF`. A
record's own PREV, at offset 15, is well inside its 32-byte slot.

Unlinking does not clear the object's own NEXT and PREV. They are stale
afterwards, and insert overwrites them.

---

## 9. Moving an object: depth_step and depth_relink

This is the code that runs all the time. Every mover, character half and guard
torso moves through depth_step, and a guard's legs call depth_relink directly.

### Did the step move it at all?

depth_step takes the step in D, E and A, for U, V and Z. depth_add_step ORs
the three together first: a zero step leaves the object where it was, so it
returns before touching the record, at 27 T-states rather than the 148 of
three read-add-writes. A non-zero step is added and changes at least one
coordinate, so depth_step falls into depth_relink. (The OR is repeated on the
way out, because the flags of the last ADD are no use -- a coordinate can
wrap to zero.)

The question is asked of the step, at the one moment the step is known, rather
than by saving the position and comparing it later.

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
move when the torso's step is zero. mover_move_pair compares the legs' new U
and V with their current ones before writing them, and calls depth_relink only
if either differs.

**The step runs before the screen position is worked out.** Nothing in depth.s
reads the screen extents, and room_adjust, character_lift and object_place do
not write U, V, Z or the sizes. So callers run depth_step first and
object_place afterwards, and the flags from the OR are still intact for its
`ret z`.

### Out, and back in from the front

```
depth_relink:   call depth_unlink
                jr   depth_insert       ; which does depth_cmp_setup for us
```

That is the whole routine: five bytes. However little the object moved, it
comes out of the list and is scanned back in against the whole sorted run.

**It is self-repairing**, and that is the property worth having. Two objects
that both stood still cannot have come to need a different order between them,
and anything that moved is placed against the whole run again. An error cannot
outlive the frame that made it, so nothing needs a separate pass to go looking
for one.

The obvious cheaper thing -- check the neighbours either side first and do
nothing if the object still sits between them -- is what used to be here, and
it cannot be made right: it is sound only if the order is transitive, which
[section 5](#5-why-there-is-no-sort) shows it is not. See
[the appendix](#14-appendix-what-this-replaced) for the scene that settled it,
and for what walking the whole run actually costs.

### Two-part objects: depth_step_upper

A character is two records, legs and body; a guard is a torso over legs. The
two halves share U and V, and the upper half is always the nearer of the two.

```
upper.UVZ += step;  if step == 0: return
unlink(upper)                  the upper out of the lower's way
relink(lower)                  the lower, against the room
insert(upper, after lower)     the upper, scanned in from right after it
```

**The upper's scan starts after the lower** rather than at `sort_head`. That is
not a shortcut past the walk but the rest of it: since the two share U and V
and the upper is the nearer, every comparison a scan from the front would make
on its way down to the lower half comes out the same for the upper. Head Over
Heels does the same, in `EnlistAux`.

**The upper is re-scanned every turn**, never assumed to be in place. Room `$38`
is why: the knight stepped down off a block, the lower half moved back past it,
and the block was left sitting between his two halves -- his body drawn in
front of something it was behind.

**The upper comes out before the lower is re-sorted.** That ordering used to be
load-bearing, back when depth_relink only looked at its neighbours: the lower
found its own upper sitting behind it, called that "in order" and never
re-sorted at all. A full scan cannot be fooled that way, because the upper is
always the nearer of the two and the scan never takes it as somewhere to go
after -- re-sorting the lower first passes both suites. The order is kept
because both halves have to come out regardless and it costs nothing.

**The lower half's step has to be added before depth_step_upper is called.**
character_move only adds it, with depth_add_step, since depth_step_upper
re-sorts it anyway. mover_move_pair re-sorts a guard's legs itself as well,
because when the torso stands still depth_step_upper returns at once, and legs
snapped somewhere new would not be re-sorted at all.

---

## 10. Who calls what

### When a room is built

1. **room_build** empties the list with the `depth_reset` macro.
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

---

## 11. Register contracts and state

### Routines

| Routine | In | Out | Corrupts |
|---|---|---|---|
| depth_reset | -- (a macro) | an empty list | HL |
| depth_unlink | IX | DE = the field that pointed at IX. **A kept**, carry clear | F, BC, HL |
| depth_cmp_setup | IX | the six operands in depth_insert_from | AF, B |
| depth_insert | IX | IX linked in | A, BC, DE, HL, IY |
| depth_insert_placed | IX, setup done | IX linked in | A, BC, DE, HL, IY |
| depth_insert_from | IX, HL = the field to start at, setup done | IX linked in | A, BC, DE, HL, IY |
| depth_link | IX, HL = the NEXT field to follow | IX spliced in after it | A, BC, DE, HL |
| background_insert | IX | IX linked, sort_head moved | A, BC, DE, HL |
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
| the insertion point | B and D, during a scan | the NEXT field the object will be linked after |
| six operands | inside depth_insert_from | the placed object's bounds, from depth_cmp_setup |

The whole module is 271 bytes, four of them the two variables above.

---

## 12. Traps

- **Never insert an object that is already in the list.** It compares against
  itself, the two boxes interpenetrate, and the scan can pick the object as its
  own insertion point and link its NEXT to itself. The draw loop then never
  ends. `start` in knightlore/main.s has a note about this happening after a
  failed room build.

- **The scan is only valid after depth_cmp_setup for the object being placed.**
  Its bounds live in the code, so any setup for a different object in between
  silently changes the answers. depth_insert_placed and depth_insert_from
  assume setup has run; depth_relink gets it from the depth_insert it jumps to,
  and depth_step_upper runs it a second time itself, because re-sorting the
  lower half rewrites it.

- **Give the lower half its step before depth_step_upper.** It re-sorts the
  lower half itself, with the upper out of the way, and then scans the upper in
  from after it.

- **Move through depth_step, with the step you really apply.** Changing U, V or
  Z directly skips the re-sort. Passing a zero step when the object did move,
  as the record's DU and DV would be for a character, skips it too.

- **Keep boxes inside the byte.** All the bounds are unsigned 8-bit. A box whose
  low edge would go below 0, such as U = 2 with SIZE_U = 4, wraps to `$FE` and
  compares as far away. The castle never puts anything near either end of the
  range, and the tests keep clear of it too.

- **Keep NEXT at offset 0 of the record.** Both the draw loop's `pop iy` and the
  PREV-points-at-a-field trick depend on it.

- **PREV is a record address only when it is not sort_head.** Otherwise it may
  be `object_list` or a background object, and must not be read as the previous
  sorted object.

---

## 13. Tests

[tests/depth_tests.s](tests/depth_tests.s) assembles depth.s on its own, with
no other engine code, and runs 44 tests on the C++ Z80 core. It builds its
lists with its own helpers, so no test depends on the code it is testing. It
covers:

- **depth_unlink** from the middle, the head, the tail and a list of one,
  including DE and A on the way out. The records sit either side of a page
  boundary.
- **the comparison**, by inserting one record into a list holding another and
  seeing which side it lands: on every axis in both directions -- which checks
  which axis got asked as much as what it answered, since a later axis
  answering at all would mean an earlier one had wrongly separated. Plus a zero-height box on top, two
  agreeing axes, the floor axes disagreeing either way round, room `$B3`'s pair
  both ways, above-and-behind, and interpenetration.
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

Room `$B3` is the pair worth knowing about: a spike and a block, 16 apart along
U and 16 along V, with a ball between them that is certainly nearer than the
spike and certainly further than the block. Get those two the wrong way round
and the ball has nowhere in the list it can go.

[tests/pair_sort_tests.s](tests/pair_sort_tests.s) runs the two-part figures'
real moves against the real sort: the knight through character_move and a guard
through mover_move_pair. walker_tests.s and mover_tests.s stub the depth
routines to count what a move asks for; this suite assembles walker.s, mover.s
and depth.s together instead, so every step goes through the sort as it does in
the game. It stands the knight, or a guard, on a three-by-three platform of
room `$B4`'s blocks, walks it across in all four directions, and after every
step checks the whole list for a **certain inversion**: an object before one
that every separating axis agrees it is in front of.

That "certain" is the suite's own reading of the two boxes, in
`certainly_nearer`, and deliberately not the sort's. The scan answers from
the first axis that separates the pair and has no notion of how sure it is;
what a picture can be wrong about is narrower -- a pair that *every* separating
axis agrees on. Where the axes disagree the sort may settle it either way and
no test should hold it to one. Asking the boxes rather than the code under test
is also what let the suite survive a change to the comparison, which is exactly
what it had to do.

On the code before the legs-and-body fix it finds inversions for both figures
in both walks towards the viewer, which is where the legs have to move later in
the list. It also sets up room `$A3`'s corner -- the knight standing still on a
stack, and the moveable block stepping in under his feet along V, checked after
every step.

To run them:

```
cpp-core/build.ps1 -Release -Target z80_com_runner
python examples/filmation/engine/tests/run_tests.py depth pair_sort
```

A failure prints the test's name, what was checked, and the value it got
against the one it wanted. The runner exits with the number of failures.

---

## 14. Appendix: what this replaced

The design in sections 4 to 6 arrived in three steps, and the middle one threw
a lot of machinery away. This is what that machinery was, and what going
without it cost -- kept here rather than in the explanation, because none of it
is needed to read the code.

### The neighbour check

depth_relink was 62 bytes. Before touching the list it compared the object with
the neighbour before it and the neighbour after it, and if it was still between
the two it returned -- two depth_cmp calls instead of a walk down the whole
run, and it was the common case, since an object creeping a unit a frame
crosses somebody only every several frames. When it did find a crossing it
unlinked and re-scanned: from `sort_head` if the object belonged earlier, and
from where it came out if it belonged later.

Room `$A3` is the scene that retired it, and `pair_sort_tests.s` still holds it.
The moveable block there rides the hunting ball. The knight stood still on a
stack beside it, and the block was ahead of him in the list, which was right --
side by side, their boxes disagree by axis. Then the ball carried the block in
under his feet, where he is certainly the nearer. Between the two in the list
lay a spike and a spiked ball that the block could only guess about, so its
look at its neighbours said "in order"; the knight had taken no step, so
nothing re-sorted him either; and the block's top stayed drawn over his legs
until something else moved. It had already been patched once, to walk past a
neighbour it was unsure of rather than stop at it, and a full scan is that
patch taken to its conclusion.

### What came off with it

depth_cmp used to answer a second question in A: whether every separating axis
agreed, or whether they disagreed and the ordering was only a guess. It summed
the separating axes into HL as it went, voted in B, and dispatched on the two
together, with a one-unit Z tie-break for the ties the floor terms could not
break. All of that existed for the scan's early exit, and went with it.

| | before | after |
|---|---|---|
| depth_cmp | 102 B | 50 B |
| depth_relink | 62 B | 5 B |
| depth_insert_from | 28 B | 26 B |
| the module | 375 B | **264 B** |

Knight Lore's build went from 10 bytes free below the stack to 121. Writing
the comparison out inside the loop and testing a step before adding it then
put 3 back (`depth_insert_from` 77 B with the comparison inside it,
`depth_add_step` 30 B, the module 267 B) for the speed below.

### What it costs

Measured on the real game rather than estimated: both versions built from the
same tree with only depth.s swapped, driven from a breakpoint at `start.loop`
so that a turn is exactly one `run`, 300 turns a room, knight walking,
`idle: ["turn_pace"]`.

| room | sorted | movers | old T/turn | new T/turn | |
|---|---|---|---|---|---|
| `$BF` | 25 | 2 | 13,254 | 14,572 | +10% |
| `$A3` | 24 | 6 | 10,720 | 9,876 | -8% |
| `$8C` | 22 | 3 | 8,674 | 9,519 | +10% |
| `$43` | 23 | 1 | 5,341 | 5,284 | -1% |
| `$E3` | 23 | 17 | 6,124 | 5,067 | -17% |

The mean over the five worst rooms is **+0.5%**, and depth sorting is about
4.2% of a turn either way. The two effects very nearly cancel: a comparison got
roughly twice as cheap, and roughly twice as many of them happen.

The spread goes the way the design says it should. `$E3`, with 17 movers, got
17% *faster* -- with that many objects moving, the neighbour check kept failing
and falling through to a full scan anyway, so it paid for both. `$BF`, with
two, got 10% slower, because there the check usually succeeded in two
comparisons. Rooms whose movers are gated out by `monster_gate` come out
identical on both, at about 300 T a turn: nothing but the zero-step early-outs
runs.

For scale, in those same rooms `sprite_blit` and `objects_draw_all` between
them account for the bulk of a turn, and a turn takes 2.5 to 3.5 frames.

### Writing the comparison into the loop

The same five rooms again, entered in the same order on both builds -- which
matters, since a room's movers are in a different phase depending on where the
knight came from, and the first attempt at this table compared two different
games. Busy time per turn agrees to within a few percent between the two runs,
which is the check that they are the same scene.

| room | called | inlined | |
|---|---|---|---|
| `$BF` | 5,763 | 4,762 | -17% |
| `$A3` | 9,383 | 8,239 | -12% |
| `$8C` | 9,833 | 7,626 | -22% |
| `$43` | 5,284 | 4,397 | -17% |
| `$E3` | 4,177 | 3,407 | -18% |

Mean **-17%** on depth's T-states per turn, from about 3.4% of a turn to 2.8%,
for +3 bytes -- against a price of -19% worked out from the listing. What went:
the `CALL` and `RET` around the comparison, the `PUSH HL`/`POP IY` that handed
it the candidate, the `CCF` on V, and the `HL` round trip when advancing, which
now loads NEXT straight into IY with `ld iyh,a`/`ld iyl,c`. `depth_add_step`'s
early return for a zero step is the rest, and is why `$E3`, whose seventeen
movers mostly sit out a turn, gains more than its scan alone would give.

### Walking the list with SP

Then the walk itself: `ld sp,iy / pop iy` in place of two indexed loads, the
insertion point moved off the stack into B and D to make that possible, and the
loop rotated so `.advance` falls into the comparison. Same method, one snapshot
of the tree built twice with only depth.s different, the same rooms in the same
order, `depth_insert_from` in T-states per turn:

| room | before | after | |
|---|---|---|---|
| `$BF` | 3,927 | 3,184 | -19% |
| `$A3` | 6,953 | 6,118 | -12% |
| `$43` | 3,443 | 2,918 | -15% |
| `$E3` | 2,611 | 2,189 | -16% |

**-15%** on the scan against -20% priced, for 4 bytes. `$8C` is left out: its
busy time per turn came out 238k on one run and 260k on the other, so the two
saw different scenes and the pair says nothing.
