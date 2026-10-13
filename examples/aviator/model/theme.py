"""The Theme: the guns, the bullets and the aliens.

Firing the guns on the runway starts the Theme (see the "aliens attack
Acornsville" and "alien feeding and growth patterns" deep dives). A wave is
eight aliens, spawned one at a time at random among the fourteen landing
places that objects 16 to 29 mark. They then:

- lie dormant (state 0), all eight shown through object 30;
- are woken two at a time into feeding slots 31 and 32 (state 1), and feed,
  growing by doubling their scale every four states, up to state 22;
- one at a time take off from a feeding slot (state 23), climb as object 33
  (24 to 27) and fly towards Acornsville at alienSpeed, and descend on it
  (28). Reaching it is the end of the game.

The guns fire two bullets, each a trail of two objects (12 and 13, 14 and
15) from the plane's guns along its line of flight. A hit is found by
stepping along each trail in 32 steps and checking each step against the
alien's weak spot, a box at a fixed offset from its anchor that shrinks with
the feeding stage. A hit alien explodes for 27 iterations, its points flung
apart at random, and scores by its stage; a whole wave destroyed scores 500
and the next wave comes faster.

alienSlot holds, for objects 30 to 33, which alien (0 to 7) each shows; a
negative entry is empty. alienObjectId holds each alien's landing place
(16 to 29), negative once it is destroyed.
"""

from .events import TooLate
from .flight import next_random_number
from .hardware import via_timer_low
from .memory import M
from .names import (alienObjectId, alienScore, alienSlot, alienSpeed, alienState, alienToMove,
                    distanceFromHit, dormantAlienScore, explodeFrom, explodeTo, feedingStage,
                    firingStatus, hitObjectId, hitTimer, mainLoopCounter, matrixNumber, nextAxis,
                    objectAnchorPoint, objectId, onGround, randomNumbers, showLine, themeStatus,
                    xObjectHi, xObjectLo, xPlaneLo, xPointLo, xTemp1Lo, xTemp2Hi, xTemp2Lo,
                    xTurnHi, yObjectHi, yObjectLo, yPointLo, zObjectPoint, zPointLo, zTemp2Hi,
                    zVelocityPHi)
from .points import (add_point_to_object, add_temp_to_point, copy_point_to_work, copy_temp_to_point,
                     copy_work_to_point, set_obj_point_coords, set_object_to_origin, set_point_coords,
                     set_point_to)
from .scoring import print_too_late, score_points, update_score
from .sound import make_sound
from .visibility import check_line_distance, set_object_coords

MATRIX_2 = 9                 # matrixNumber for matrix 2: from the plane's frame to the world's
FIRING = 9                   # firingStatus while bullets are in the air
EXPLOSION = 27               # hitTimer's start: iterations an explosion lasts
EXPLODED_SOUND = 2
GUNS_SOUND = 6

FEEDING = 1                  # alien states
READY = 22                   # finished feeding
TAKING_OFF = 23
CLIMBING_OUT = 24
HEADING_FOR_TOWN = 27
ATTACKING = 28

SLOT_EMPTY = 0xFE
DORMANT_SLOT, FEED_SLOT_1, FEED_SLOT_2, FLYING_SLOT = 30, 31, 32, 33

# The work vector offset CopyPointToWork and CopyWorkToPoint take for
# (xTemp2, yTemp2, zTemp2) and (xPlane, yPlane, zPlane): the original passes
# the low byte of the address, which works because xTurnHi starts a page.
TEMP2 = xTemp2Lo - xTurnHi
PLANE = xPlaneLo - xTurnHi

# Bullet points and vectors (see FireGuns).
GUN_OFFSET_POINT = 95        # the left gun's position relative to the plane
PLANE_POINT = 96
BULLET_VELOCITY = 228        # points 228 to 231: each bullet object's velocity
TRAIL_LINE = 60              # the line whose visible distance the bullets use


def _object(index):
    """An object coordinate as the original indexes them: xObjectLo + index,
    with the index an 8-bit register, so index + 40 moves to the next axis
    and indices above 215 wrap round to the start."""
    return M[xObjectLo + index] | (M[xObjectHi + index] << 8)


def fire_guns():
    """Fire both guns, unless bullets are already in the air or an alien has
    just been hit: start the bullets at the plane, moving at the plane's
    speed plus 200 along its line of flight, from the two gun positions."""
    if M[firingStatus] | M[hitTimer]:
        return
    set_point_to(BULLET_VELOCITY, 0)
    M[zPointLo + BULLET_VELOCITY] = (M[zVelocityPHi] + 200) & 0xFF
    set_point_to(GUN_OFFSET_POINT, 0xFF)
    M[zPointLo + GUN_OFFSET_POINT] = 0x14
    M[xPointLo + GUN_OFFSET_POINT] = 0xF6
    M[yPointLo + GUN_OFFSET_POINT] = 0xFC        # (-10, -4, -236)
    M[matrixNumber] = MATRIX_2
    M[firingStatus] = FIRING
    set_point_coords(BULLET_VELOCITY, MATRIX_2)
    for pid in range(BULLET_VELOCITY + 1, BULLET_VELOCITY + 4):
        copy_temp_to_point(pid)
    set_point_coords(GUN_OFFSET_POINT, MATRIX_2)
    copy_work_to_point(PLANE, PLANE_POINT)
    for oid in range(12, 16):
        set_object_to_origin(oid)
        add_point_to_object(PLANE_POINT, oid)
    add_point_to_object(GUN_OFFSET_POINT, 12)
    M[objectAnchorPoint] = GUN_OFFSET_POINT
    set_obj_point_coords(96, MATRIX_2)
    set_obj_point_coords(97, MATRIX_2)
    add_temp_to_point(98, 96)
    for oid, pid in ((15, 98), (14, 97), (13, 96)):
        add_point_to_object(pid, oid)


def update_bullets():
    """Move the four bullet objects by their velocities; once any of them is
    out of sight or beyond the trail's visible distance, the bullets are
    over (firingStatus = 0)."""
    gg = 98
    M[objectId] = 15
    while M[objectId] >= 12:
        oid = M[objectId]
        add_point_to_object((oid + 216) & 0xFF, oid)
        M[showLine] = 0
        status = set_object_coords(gg)
        if not status & 0x80 or check_line_distance(TRAIL_LINE, gg):
            M[firingStatus] = 0
        gg -= 1
        M[objectId] = (oid - 1) & 0xFF


def get_trail_vector_step(index):
    """One axis of a thirty-second of a bullet trail: the next axis after
    index (228 or 230 to start, for the left and right trails) of the
    vector from the trail's back object to its front one, divided by 32, as
    a 24-bit value. Returns (the new index, the value)."""
    index = (index + nextAxis) & 0xFF
    front = M[xObjectLo + 1 + index] | (M[xObjectHi + 1 + index] << 8)
    back = M[xObjectLo + index] | (M[xObjectHi + index] << 8)
    d = (front - back) & 0xFFFF
    wide = d << 8
    if d & 0x8000:
        wide |= 0xFF000000
    return index, (wide >> 5) & 0xFFFFFF


def get_alien_weak_spot(oid, q):
    """The alien's weak spot, (z, y, x) as the original orders them: its
    anchor plus (5 q) on the x and z axes."""
    offset = 0x0500 | q
    x = (_object(oid) + offset) & 0xFFFF
    y = _object((oid + nextAxis) & 0xFF)
    z = (_object((oid + 2 * nextAxis) & 0xFF) + offset) & 0xFFFF
    return [z, y, x]


def check_alien_weak_spot(index, weak, sizes):
    """Whether the object at index (216 for object 0, 228 or 230 for a
    trail's back object) is inside the weak-spot box: its coordinate minus
    the weak spot's must be from 0 to just under the box's size on every
    axis. A hit records the alien and starts its explosion."""
    for axis in (2, 1, 0):
        index = (index + nextAxis) & 0xFF
        d = (_object(index) - weak[axis]) & 0xFFFF
        if d >> 8:
            return False
        if (d & 0xFF) >= sizes[axis]:
            return False
    M[hitObjectId] = M[objectId]
    M[hitTimer] = EXPLOSION
    return True


def check_if_alien_is_hit(oid):
    """Check whether either bullet trail passes through alien oid's weak
    spot (30 to 33), stepping along each trail a thirty-second at a time.

    The weak spot's box, and its offset from the anchor, are halved for
    each feeding stage below the biggest: the dormant aliens (30) are
    stage 4, the flying one (33) always stage 0, and the feeding ones (31 and
    32) take their stage from their current scale. The stepping uses object 0
    and point 0 as its moving test position."""
    sizes = [0xA0, 0x7D, 0xA0]                  # (z, y, x) sizes
    q = 0x40
    if oid < FEED_SLOT_1:
        stage, shifts = 4, 3
    elif oid != FLYING_SLOT:
        pid = 183 if oid == FEED_SLOT_1 else 188
        stage = (((M[zObjectPoint + pid] ^ 0x70) >> 4) - 2) & 0xFF
        shifts = stage
    else:
        stage, shifts = 0, 0
    for _ in range(shifts):
        sizes = [s >> 1 for s in sizes]
        q >>= 1
    M[feedingStage] = stage

    M[hitTimer] = 0
    weak = get_alien_weak_spot(M[objectId], q)
    for trail in (BULLET_VELOCITY, BULLET_VELOCITY + 2):
        index = trail
        for axis in range(3):
            index, step = get_trail_vector_step(index)
            M[xTemp2Hi + axis] = step >> 16
            M[xTemp2Lo + axis] = (step >> 8) & 0xFF
            M[xTemp1Lo + axis] = step & 0xFF
        copy_work_to_point(TEMP2, 0)
        if check_alien_weak_spot(trail, weak, sizes):
            return
        # Object 0 starts at the trail's back object.
        src, dst = trail, 216
        while True:
            src = (src + nextAxis) & 0xFF
            dst = (dst + nextAxis) & 0xFF
            M[xObjectLo + dst] = M[xObjectLo + src]
            if dst == 200:
                break
        for _ in range(32):
            # The steps' fractions build up in xTemp2Hi, carrying into
            # object 0 when they make a whole unit.
            for axis, index0 in ((2, 2 * nextAxis), (1, nextAxis), (0, 0)):
                total = M[xTemp1Lo + axis] + M[xTemp2Hi + axis]
                M[xTemp2Hi + axis] = total & 0xFF
                if total > 0xFF:
                    lo = (M[xObjectLo + index0] + 1) & 0xFF
                    M[xObjectLo + index0] = lo
                    if lo == 0:
                        M[xObjectHi + index0] = (M[xObjectHi + index0] + 1) & 0xFF
            add_point_to_object(0, 0)
            if check_alien_weak_spot(216, weak, sizes):
                return


def set_random_number():
    """Put a new random number (the VIA timer) in the list and move on."""
    M[randomNumbers + 1 + M[randomNumbers]] = via_timer_low()
    return next_random_number()


def explode_alien():
    """While an alien is exploding (hitTimer counting down from 27), throw
    its points apart by random amounts, bigger for bigger aliens; score it
    when the explosion ends. Just after the hit, note how near the plane is
    in distanceFromHit, which the flight model uses for turbulence."""
    if M[hitTimer]:
        make_sound(EXPLODED_SOUND)
        hit = M[hitObjectId]
        pid = M[explodeFrom + hit - 30]
        last = M[explodeTo + hit - 30]
        shifts = 2 if 2 >= M[feedingStage] else M[feedingStage]
        mask = 0xFF >> (shifts + 1)
        while True:
            copy_point_to_work(pid, TEMP2)
            for axis in (2, 1, 0):
                r = 0
                a = M[randomNumbers + 1 + next_random_number()]
                carry = a & 1
                a = (a >> 1) & mask
                if carry:
                    # Negative: the complement plus the carry still set from
                    # the shift makes a two's complement negation.
                    r = 0xFF
                    a ^= 0xFF
                lo = a + M[xTemp2Lo + axis] + carry
                M[xTemp2Lo + axis] = lo & 0xFF
                M[xTemp2Hi + axis] = (r + M[xTemp2Hi + axis] + (lo >> 8)) & 0xFF
            copy_work_to_point(TEMP2, pid)
            pid = (pid - 1) & 0xFF
            if pid < last:
                break
        M[hitTimer] = (M[hitTimer] - 1) & 0xFF
        if not M[hitTimer]:
            score_hit_points()
    if M[hitTimer] == EXPLOSION - 1:
        a = M[zTemp2Hi]
        if M[hitObjectId] == FLYING_SLOT:
            a = (a - 8) & 0xFF
            if a & 0x80:
                a = 0
        M[distanceFromHit] = a


def _reset_radar():
    from . import dashboard
    dashboard.reset_radar()


def score_hit_points():
    """Score a destroyed alien and take it out of the wave."""
    hit = M[hitObjectId]
    if hit == DORMANT_SLOT:
        alien = M[alienSlot]
    else:
        alien = M[alienSlot + hit - 30]
        M[alienSlot + hit - 30] = 0xFF
    M[alienObjectId + alien] = 0xFF
    if hit == FLYING_SLOT:
        _reset_radar()
        points = 3
    elif hit < FEED_SLOT_1:
        points = M[dormantAlienScore]
    else:
        points = M[alienScore + M[feedingStage]]
    update_score(points)


def spawn_alien():
    """While a wave is being spawned (themeStatus counting down from 8) and
    the plane is airborne, perhaps add an alien: a random landing place, used
    only if no alien of this wave has it already."""
    count = M[themeStatus]
    if count & 0x80 or count == 0:
        return
    if M[onGround]:
        return
    M[alienState + count - 1] = 0
    r = via_timer_low() & 15
    if r >= 14:
        return
    place = r | 16
    M[themeStatus] = (M[themeStatus] - 1) & 0xFF
    x = 8
    while True:
        x -= 1
        if x == M[themeStatus]:
            M[alienObjectId + x] = place
            return
        if M[alienObjectId + x] == place:
            M[themeStatus] = (M[themeStatus] + 1) & 0xFF
            return


def resize_feeding_alien(a, slot):
    """Double the size of the alien in feeding slot 31 or 32 by adding 1 to
    the scale in its four object points' z values, or, if bit 7 of a is set,
    reset it to the first feeding stage's scale (2^2)."""
    pid = 186 if slot == FEED_SLOT_1 else 191
    for p in range(pid, pid - 4, -1):
        z = (M[zObjectPoint + p] + 16) & 0xFF
        if a & 0x80:
            z = (z & 15) | 32
        M[zObjectPoint + p] = z


def update_aliens():
    """Move the aliens on through their lives: their states advance twice
    every 256 iterations; feeding slots are filled from the dormant aliens and
    emptied of the dead; a finished feeder takes off; feeders grow; and a
    wave all destroyed scores 500 and starts the next, faster."""
    counter_due = (M[mainLoopCounter] & 127) == 0
    if counter_due:
        for x in range(7, -1, -1):
            s = M[alienState + x]
            if s and s != READY and s < HEADING_FOR_TOWN:
                M[alienState + x] = s + 1

    for slot in (FEED_SLOT_1, FEED_SLOT_2):
        x = M[alienSlot + slot - 30]
        if not x & 0x80:
            if M[alienState + x] != CLIMBING_OUT and not M[alienObjectId + x] & 0x80:
                continue
            M[alienSlot + slot - 30] = SLOT_EMPTY
        other = M[alienSlot + 2] if slot == FEED_SLOT_1 else M[alienSlot + 1]
        for x in range(7, -1, -1):
            if M[alienObjectId + x] & 0x80 or M[alienState + x]:
                continue
            if x == other:
                continue
            M[alienSlot + slot - 30] = x
            resize_feeding_alien(0x80, slot)
            M[alienState + x] = FEEDING
            break

    x = M[alienSlot + 3]
    flying = False
    if not x & 0x80:
        if not M[alienObjectId + x] & 0x80:
            flying = True
        else:
            M[alienSlot + 3] = M[alienObjectId + x]
    if not flying:
        for slot in (FEED_SLOT_1, FEED_SLOT_2):
            x = M[alienSlot + slot - 30]
            if x & 0x80 or M[alienState + x] != READY:
                continue
            M[alienToMove] = x
            M[alienState + x] = TAKING_OFF
            break

    if not counter_due:
        return
    for slot in (FEED_SLOT_1, FEED_SLOT_2):
        x = M[alienSlot + slot - 30]
        if x & 0x80:
            continue
        s = M[alienState + x]
        if s < 5 or s >= 20 or s & 3:
            continue
        resize_feeding_alien(s, slot)
    for x in range(7, -1, -1):
        if not M[alienObjectId + x] & 0x80:
            return
    M[themeStatus] = 8
    score_points(0x0050)
    speed = M[alienSpeed] + 4
    if speed < 19:
        M[alienSpeed] = speed


def alien_in_acornsville():
    """Move the alien heading for Acornsville: up to height first, then along
    x and z towards the town at alienSpeed, then down on it -- and if it gets
    there, the game is over."""
    a = M[alienToMove]
    if a & 0x80:
        return
    state = M[alienState + a]
    if state == HEADING_FOR_TOWN:
        if M[yObjectHi + FLYING_SLOT] < 12:
            total = M[yObjectLo + FLYING_SLOT] + 10
            M[yObjectLo + FLYING_SLOT] = total & 0xFF
            if total > 0xFF:
                M[yObjectHi + FLYING_SLOT] = (M[yObjectHi + FLYING_SLOT] + 1) & 0xFF
            return
        moved = False
        for axis in (0, 2):
            off = axis * nextAxis + FLYING_SLOT
            if M[xObjectHi + off] == 0:
                continue
            lo = M[xObjectLo + off] - M[alienSpeed]
            M[xObjectLo + off] = lo & 0xFF
            if lo < 0:
                M[xObjectHi + off] = (M[xObjectHi + off] - 1) & 0xFF
            moved = True
        if moved:
            return
        M[alienState + a] = ATTACKING
        state = ATTACKING
    if state != ATTACKING:
        return
    if M[hitTimer]:
        return
    lo = M[yObjectLo + FLYING_SLOT] - 10
    M[yObjectLo + FLYING_SLOT] = lo & 0xFF
    if lo < 0:
        M[yObjectHi + FLYING_SLOT] = (M[yObjectHi + FLYING_SLOT] - 1) & 0xFF
    if M[yObjectHi + FLYING_SLOT] or M[yObjectLo + FLYING_SLOT] >= 10:
        return
    print_too_late()
    raise TooLate("an alien reached Acornsville")
