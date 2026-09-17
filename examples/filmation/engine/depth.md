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
5. [Why there is no sort](#5-why-there-is-no-sort)
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

Knight Lore worked out this order afresh every frame. It scanned its objects
for one that nothing else hides, drew it, and started the scan again, which is
O(n²) at best. This engine follows Head Over Heels instead: the order is a
standing property of the list, repaired one object at a time when that object
moves.

## 2. Boxes, and which way is nearer

### The box

Every object is a solid box in world coordinates, held in its record:

| Axis | Record fields | The box covers |
|---|---|---|
| U, a floor axis | `U`, `SIZE_U` | `U - SIZE_U` to `U + SIZE_U` |
| V, a floor axis | `V`, `SIZE_V` | `V - SIZE_V` to `V + SIZE_V` |
| Z, height | `Z`, `SIZE_Z` | `Z` to `Z + SIZE_Z` |

U and V are **centres with half-widths**. Z is **the base with a height**, so
`Z = 0` stands on the floor. (The comment above `SIZE_U` in
[object_struct.s](object_struct.s) still describes the box as `[U, U+SIZE_U)`.
That is out of date: depth_cmp, collide_box and object_overlaps all use the
centre and half-width.)

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

The list is doubly linked only so that taking an object out is a constant-time
job. Nothing ever walks it backwards.

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
answers two questions:

- **Is the placed object further than the candidate?** Carry set means further.
- **Is that answer certain?** A = 0 means certain, anything else a guess.

### One axis at a time

On each axis the two boxes are in one of three states:

| State | Test on U | Vote |
|---|---|---|
| We are nearer | their max ≤ our min | set bit 0 of B |
| They are nearer | their min ≥ our max | set bit 1 of B |
| They overlap | neither | no vote, no term |

On V the meaning of the first two rows swaps, because V grows away from the
viewer. Their max being below our min means *we* are further.

When a floor axis separates the boxes, it also adds a **term** to a running
total in HL, the difference in position in the nearer direction:

| Axis | Term added to HL |
|---|---|
| U | our U − their U |
| V | their V − our V |
| Z | none: Z votes, but adds nothing |

A positive total means we are nearer. Each term is worked out exactly from two
unsigned bytes: the SUB gives the low byte and its borrow, and `sbc a,a` turns
the borrow into the high byte, so a term runs from −255 to +255.

An axis where the boxes overlap says nothing about depth, so it adds nothing.
Head Over Heels sums every separating axis, Z included. Z is left out here
because the total is only ever read when the axes disagree (see below), and
when Z is one of the disagreeing axes the floor is what the picture goes by.
The case that showed it: the knight pushing a table from behind. His body's box
starts at the table's top, so Z says the body is nearer by 12, U says it is
further by 11, and with Z counted the body was drawn over the table.

### The answer

After three axes, B holds the votes:

| B | What the axes said | Carry | A |
|---|---|---|---|
| 1 | every separating axis says we are nearer | clear | 0, certain |
| 2 | every separating axis says they are nearer | set | 0, certain |
| 3 | the axes disagree | sign of HL | 1, a guess |
| 0 | no axis separates: the boxes interpenetrate | sign of HL | 1, a guess |

Two things about this are easy to get wrong.

**Agreement is what makes an answer certain, not the number of axes.** Two axes
that both say "in front" are more convincing than one, not less. An earlier
version counted separating axes and called anything other than exactly one a
guess. A guard with a spike to its east and below it then got a "guess" from two
agreeing axes, the scan walked straight past the spike, and the guard was drawn
in front of it.

**The direction comes from B, not from HL.** A separating axis can add nothing
to HL: Z never does, and a floor axis can add a zero term. Take a box of height
zero at the same Z as another box's base, like a guard's legs record, which has
no height and shares its torso's Z. The flat box's top is at the other's base,
so Z separates them, and HL alone would say "level".

B is set with SET rather than INC because a vote has to count once however many
axes cast it. Two axes both saying nearer must still give 1.

The dispatch at the end uses two DJNZs. The first falls through only when B was
1, the second only when B was 2. A 0 wraps to $FF and a 3 stops at 1, and both
reach the guess, which is `sla h` to put the sign of HL into the carry.

### Worked example: certain

The placed object is at U 60, the candidate at U 40, both with half-width 5,
same V and Z, so V and Z overlap.

```
U:  their max = 40 + 5 = 45    our min = 60 - 5 = 55
    45 <= 55, so we are nearer: B = 1, HL += 60 - 40 = +20
V:  overlap, nothing
Z:  overlap, nothing

B = 1  ->  carry clear, A = 0: certainly nearer
```

### Worked example: a guess

The placed object is at U 70, V 90. The candidate is at U 40, V 50. All
half-widths are 5, and Z overlaps.

```
U:  their max 45 <= our min 65: we are nearer.  B = 01, HL += 70 - 40 = +30
V:  their max 55 <= our min 85: V says we are FURTHER.  B = 11, HL += 50 - 90 = -40
Z:  overlap

B = 3, HL = -10  ->  carry set, A = 1: probably further
```

### The patched immediates and depth_cmp_setup

The placed object is the same for every candidate in a scan, so its bounds are
worked out once. depth_cmp_setup writes them straight into the operands of
depth_cmp's own instructions:

| Label in depth_cmp | Instruction | Operand written by setup |
|---|---|---|
| `.u_min` | `cp n` | our U − SIZE_U + 1 |
| `.u_max` | `cp n` | our U + SIZE_U |
| `.u_ours` | `ld a,n` | our U |
| `.v_min` | `cp n` | our V − SIZE_V + 1 |
| `.v_max` | `cp n` | our V + SIZE_V |
| `.v_ours` | `sub n` | our V |
| `.z_min` | `cp n` | our Z + 1 |
| `.z_max` | `cp n` | our Z + SIZE_Z |

So the `cp 0`, `ld a,0` and `sub 0` you see in the source are placeholders. The
labels are there only to give setup an address to write to, one byte past each.

The `+ 1` on the mins turns "their max ≤ our min" into a single compare. CP sets
the carry for "less than", so `cp our_min+1` sets it for "less than or equal".

A patched `cp n` is 2 bytes and 7 T-states. Reading the bound out of the record
instead would be at least 3 bytes and 19 T, before redoing the add or subtract
for every candidate. Setup's nine stores pay for themselves after about three
candidates, and a scan typically visits many more.

## 5. Why there is no sort

A sort needs a total order: if A is behind B and B is behind C, then A is behind
C. Isometric boxes do not promise that. Three long bars laid out like a
pinwheel can each be partly in front of the next, so A is in front of B, B in
front of C, and C in front of A. No list order draws all three correctly.

So the list is not "sorted" in the usual sense. It is an order in which every
**certain** relationship is respected wherever possible, and **guesses** are
used only to fill in where nothing certain applies. That split is why depth_cmp
returns A as well as the carry, and it is the reason the insertion scan in the
next section is shaped the way it is.

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
- **The insertion point, `at`**, the NEXT field the object will be linked after.
  It is kept on the stack for the length of the scan, and it starts as
  the field the scan started from.

For each candidate:

| depth_cmp says | Then |
|---|---|
| we are nearer, certain or a guess | move the insertion point to this candidate, and move on |
| we are further, and certain | **stop**, and link at the insertion point |
| we are further, but only a guess | move on, but leave the insertion point where it is |
| (no candidate left) | link at the insertion point |

In pseudo-code:

```
at     = start
cursor = *start
while cursor != 0:
    if placed is nearer than cursor:        # certain or guessed
        at = cursor                         # we go after this one
    else if the answer was certain:
        break                               # a certain "further": stop here
    # a guessed "further" moves the cursor on, but not at
    cursor = cursor.NEXT
link the placed object after at
```

The object ends up just after **the last candidate it was nearer than**, as long
as no certain "further" stopped the scan first.

**The insertion point lags the cursor** because of the guesses. A guessed "further" is not
trusted enough to commit to, so the scan looks past it in case something later
says, with more authority, that the object belongs further on.

### Worked example: a plain insert

The list holds A, B and C at U 20, 40 and 60, all half-width 4. X is inserted
at U 50.

```
start      at = object_list, cursor = A
vs A (20)  X nearer, certain       at = A
vs B (40)  X nearer, certain       at = B
vs C (60)  X max 54 <= C min 56:   X further, certain: stop

link after B:   A, B, X, C
```

### Worked example: the lag

The list holds P, Q and R. X is compared with each in turn.

```
vs P   nearer              at = P
vs Q   further, a guess    at stays at P, cursor moves on
vs R   nearer              at = R        ->  P, Q, R, X
```

Had R said "further, certain" instead, the scan would have stopped at R and
linked X after P, giving P, X, Q, R. The guess about Q was never acted on
either way. Only a "nearer" answer moves the insertion point, and only a
certain "further" stops the scan.

### The link

`depth_insert_from.link` splices IX in after the NEXT field HL points at. The scan pops the insertion point into HL and falls into it:

```
before:   [at] --> F                (F may be 0)

  our NEXT       = F
  our PREV       = at
  *at            = us
  if F != 0:
      F.PREV     = us                (our NEXT field is our address)

after:    [at] --> us --> F
```

background_insert uses this same splice.

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
- **A is kept.** depth_relink carries depth_in_order's answer across the call
  in A. The last-object test is `inc b` / `dec b` rather than `ld a,b` /
  `or c` for exactly this reason.
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
There are three stages, and each is cheaper than the one after it.

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

### Stage 2: is it still between its neighbours?

After depth_cmp_setup, `depth_in_order` checks the object against the two
objects either side of it. The list is furthest first, so the object is still
in place if it is not further than the one before it and not nearer than the
one after it.

| Check | Skipped when | Out of order if |
|---|---|---|
| against the predecessor | PREV equals sort_head: nothing sorted is ahead | the object is further, certain or guessed |
| against the successor | NEXT is 0: it is last | the object is nearer, certain or guessed |

When the predecessor check runs, PREV is not sort_head, so it must point at a
sorted record, and PREV is that record's address.

| Result | Carry | A |
|---|---|---|
| still in order | set | whatever depth_cmp left |
| belongs earlier | clear | 0 |
| belongs later | clear | 1 |

If it is still in order, depth_relink returns. This is the common case. An
object creeping one unit a frame only crosses a neighbour every few frames, and
this stage costs two depth_cmp calls instead of a scan.

### Stage 3: take it out and put it back

depth_relink unlinks the object, then chooses where the insertion scan should
start. depth_cmp_setup has already run for this object, and the scan relies on
that.

| Situation | Scan starts at |
|---|---|
| belongs later (A = 1) | DE from depth_unlink: where the object came out |
| belongs earlier (A = 0) | `sort_head`, the front of the sorted run |

**Later can start where it was.** Everything ahead of the object was already
found not-further when it was last placed, and moving nearer cannot change
that, so scanning those again would give the same result.

**Earlier has to go back to the front.** The mirror-image shortcut, backing up
a little and scanning forward from there, looks equally good and is not. A scan
learns things on its way down: the insertion point is the last object it was nearer than.
Starting part-way skips that, and the object can settle in front of a place a
full scan would have put it. Measured, the two disagreed on 22 frames out of
180, so the earlier case takes the long way.

### depth_step_upper: two-part objects

A character is two records, legs and body, and a guard is a torso over legs.
The two halves share U and V, and the upper half is always the nearer of the
two. So the upper half can never belong in front of the lower one, and every
comparison a scan from the front would make on its way down to the lower half
would come out the same for the upper.

`depth_step_upper` uses this. It takes the lower half in HL, adds the step,
checks the upper half against its neighbours, and if it has to move, scans from
right after the lower half. HL is the lower record's address, which is also its
NEXT field. Head Over Heels does the same in `EnlistAux`.

The lower half has to be re-sorted first, with depth_step or depth_relink, for
the shortcut to hold. Every caller does the two halves in that order.

## 10. Who calls what

### When a room is built

1. **room_build** empties the list: `object_list = 0`, `sort_head = object_list`.
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
| a guard's move | the legs: compare and write U and V, depth_relink if they changed. Then the torso: depth_step_upper with its DU, DV and DZ and HL = the legs |
| character_move_go | the legs: depth_step with D, E and DZ. Then the body: depth_step_upper with the same step and HL = the legs. Each half then goes through character_place |
| character_place | room_adjust, character_lift and object_place |
| objects_draw_all | walks the list from object_list and draws |

### When something leaves

**special_hide** calls `depth_unlink` when a collectable is taken out of the
room, then repaints where it was.

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
| depth_recheck | IX in the list and moved | carry set: in order, nothing done. Carry clear: unlinked, A = 0 earlier or 1 later, DE = where it came out | A, BC, DE, HL, IY |
| depth_unlink | IX | DE = the field that pointed at IX. **A kept**, carry clear | F, BC, HL |
| depth_cmp_setup | IX | the nine operands in depth_cmp | AF, B |
| depth_cmp | IY = candidate, setup done | carry = further, A = 0 certain | A, BC, DE, HL. Keeps IX, IY |
| depth_cmp_hl | HL = candidate, setup done | as depth_cmp, with IY = the candidate | A, BC, DE, HL, IY |
| depth_insert | IX | IX linked in | A, BC, DE, HL, IY |
| depth_insert_placed | IX, setup done | IX linked in | A, BC, DE, HL, IY |
| depth_insert_from | IX, HL = the field to start at, setup done | IX linked in | A, BC, DE, HL, IY |
| depth_in_order | IX in the list, setup done | carry = in order, else A = 0 earlier or 1 later | A, BC, DE, HL, IY |
| background_insert | IX | IX linked, sort_head moved | A, BC, DE, HL |
| depth_add_step | IX, D, E, A = the step | Z set if the step was zero | AF, C. Keeps HL, DE, B |
| depth_step | IX in the list, D, E, A = the step | IX moved, and in order | A, BC, DE, HL, IY |
| depth_relink | IX in the list and moved | IX in order | A, BC, DE, HL, IY |
| depth_step_upper | IX = the upper half, HL = the lower half, D, E, A = the step | IX moved, and in order after HL | A, BC, DE, HL, IY |

### State

| Variable | Where | Holds |
|---|---|---|
| `object_list` | depth.s | the first object, or 0. Doubles as a NEXT field |
| `sort_head` | depth.s | the NEXT field that starts the sorted run |
| the insertion point | the stack, during a scan | the NEXT field the object will be linked after |
| nine operands | inside depth_cmp | the placed object's bounds, from depth_cmp_setup |

## 12. Traps

- **Never insert an object that is already in the list.** It compares against
  itself, the two boxes interpenetrate, and the scan can pick the object as its
  own insertion point and link its NEXT to itself. The draw loop then never
  ends. `start` in knightlore/main.s has a note about this happening after a failed
  room build.

- **depth_cmp is only valid after depth_cmp_setup for the object being placed.**
  Its bounds live in the code, so any setup for a different object in between
  silently changes the answers. depth_insert_placed,
  depth_insert_from and depth_in_order all assume setup has run.

- **Re-sort the lower half before the upper.** depth_step_upper scans from
  after the lower half, which is only right once the lower half is in place.

- **Move through depth_step, with the step you really apply.** Changing U, V
  or Z directly skips the re-sort. Passing a zero step when the object did move,
  as the record's DU and DV would be for a character, skips it too.

- **Keep boxes inside the byte.** All the bounds are unsigned 8-bit. A box whose
  low edge would go below 0, such as U = 2 with SIZE_U = 4, wraps to $FE and
  compares as far away. The castle never puts anything near either end of the
  range, and the tests keep clear of it too.

- **Keep NEXT at offset 0 of the record.** Both the draw loop's `pop iy` and the
  PREV-points-at-a-field trick depend on it.

- **A must survive depth_unlink.** depth_relink depends on it. See section 8.

- **PREV is a record address only when it is not sort_head.** Otherwise it may
  be `object_list` or a background object, and must not be read as the previous
  sorted object.

## 13. Tests

[tests/depth_tests.s](tests/depth_tests.s) assembles depth.s on its own, with
no other engine code, and runs 38 tests on the C++ Z80 core. It builds its
lists with its own helpers, so no test depends on the code it is testing. It
covers:

- **depth_unlink** from the middle, the head, the tail and a list of one,
  including DE and A on the way out. The records sit either side of a page
  boundary.
- **depth_cmp** on every axis in both directions, a zero-height box on top, two
  agreeing axes, disagreeing axes with either sign, and interpenetration.
- **depth_insert** into an empty list, before, between and after, and after a
  background object.
- **depth_in_order** unmoved, moved past either neighbour, and at either end.
- **depth_step** with a zero step on an out-of-order list, the step landing in
  U, V and Z, steps along V alone and Z alone, moving later, moving earlier, a
  move that crosses no one, the tail to the front, and behind a background
  object.
- **depth_step_upper** scanning from after the lower half, moving later, staying
  in order, and a zero step.

To run them:

```
cpp-core/build.ps1 -Release -Target z80_com_runner
python examples/filmation/tests/run_tests.py
```

A failure prints the test's name, what was checked, and the value it got
against the one it wanted. The runner exits with the number of failures.
