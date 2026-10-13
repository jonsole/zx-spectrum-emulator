"""Which lines of the world are visible, and where their points are.

Aviator's world is 193 lines between points (see the "lines and points"
deep dive). Each main-loop iteration it keeps two lists:

- linesToShow, the lines that were visible last time, which are checked
  again (UpdateLinesToShow), projected and drawn;
- linesToHide, the rest, which are worked through a few at a time
  (ProcessLinesToHide) in whatever time the iteration has left, and moved to
  linesToShow when they come into view.

Checking a line means working out where its two points are relative to the
plane, rotated into the plane's view (ProcessLine). Points come in three
kinds:

- the horizon's two points, which are worked out from the plane's pitch
  (ProcessHorizonLine);
- the runway's, which are built from its four corners each time, with the
  dashes down the middle filled in between (ProcessRunwayLine);
- everyone else's, which belong to objects: an object has an anchor point at
  its position in the world (SetObjectCoords), and its other points are
  offsets from the anchor, rotated with it (SetObjPointCoords). A point that
  links to another point (objectPoints >= 40) is reached through it, so a
  line's point may need a chain of points working out first; those go on the
  relatedPoints list so that their "worked out" marks can be cleared at the
  end of the iteration.

A point's status byte (pointStatus) has bit 7 set once its coordinates are
worked out this iteration. An object's (objectStatus) has bit 6 set once it
has been looked at and bit 7 if it is visible. showLine is the verdict on
the line being processed: 0 visible, anything else not.

Object groups: objects 6 to 9 each stand for eight copies of an object at
different places (objectGroup cycles through them, NextObjectGroup), and
object 30 for the eight dormant aliens. Only the first copy found within
range is shown in an iteration.
"""

from .memory import M
from .names import (L as _L, alienObjectId, alienSlot, alienState, groupStart, isObject, lineEndPointId,
                    lineId, linesToHide, linesToHideEnd, linesToHidePointer, linesToShow,
                    linesToShowEnd, linesToShowPointer, lineCounter, lineStartPointId, matrixAxis,
                    matrixNumber, maxLineDistance, maxObjDistance, objCount, objectAnchorPoint,
                    objectGroup, objectId, objectPoints, objectStatus, pointCount, pointId,
                    pointStatus, relatedPoints, showLine, showRunwayDashes, startStatus, themeStatus,
                    xDashesVectorLo, xGroupObjectHi, xObjectHi, xObjectLo, xPlaneHi, xPlaneLo,
                    xPlaneTop, xPointHi, xPointLo, xRotationHi, xTemp1Hi, xTemp1Lo, xTemp2Hi,
                    xTemp2Lo, xTurnHi, yObjectHi, yObjectLo, yPlaneHi, yPlaneLo, yPlaneTop,
                    yPointHi, yPointLo, zGroupObjectHi, zObjectHi, zObjectLo, zPlaneHi, zPlaneLo,
                    zPlaneTop, zPointHi, zPointLo)
from .points import (add_temp_to_point, copy_point_to_work, copy_work_to_point, set_obj_point_coords,
                     set_point_coords, set_point_to, set_temp1, temp1)

NOT_VISIBLE = 0x80           # showLine and status bit 7
WORKED_OUT = 0x80            # pointStatus bit 7
LOOKED_AT = 0x40             # objectStatus bit 6
VISIBLE_OBJECT = 0xC0        # objectStatus bits 6 and 7

FIRST_ANCHOR = 216           # object n's anchor is point 216 + n
RUNWAY = 1                   # the runway's object ID
RUNWAY_ANCHOR = 217
LINK = 40                    # objectPoints entries >= 40 link to point n - 40
RELATED_POINTS_MAX = 49      # the relatedPoints list is full at this many

MATRIX_1 = 0                 # matrixNumber for matrix 1 (the world as seen from the plane)
MATRIX_4 = 27                # matrixNumber for matrix 4 (roll and pitch only)

# Group objects (6-9) and the dormant aliens (object 30) each go through
# eight copies.
GROUP_SIZE = 8

# The lines that ProcessLinesToHide skips (60 and 61 belong to bullets'
# trails, which UpdateBullets handles).
SKIPPED_HIDDEN_LINES = (60, 61)


def next_object_group(oid):
    """Move a group object (6 to 9) on to its next copy; returns whether oid
    was one."""
    if not 6 <= oid < 10:
        return False
    i = oid - 6
    M[objectGroup + i] = ((M[objectGroup + i] + 1) & 7) | M[groupStart + i]
    return True


def check_obj_distance(oid, top, high, k):
    """Whether an object is too far along one axis to see: returns 0 if it is
    near enough, k if not. top and high are the top two bytes of the 24-bit
    distance; only distances whose top byte is 0 or -1 can be near, and then
    the high byte's magnitude is compared with the object's maxObjDistance.
    The magnitude of a negative distance is taken as its ones' complement,
    which is one short, as the original does."""
    if top & 0x80:
        if top != 0xFF:
            return k
        high ^= 0xFF
    elif top:
        return k
    return 0 if high < M[maxObjDistance + oid] else k


def check_line_distance(line, pid):
    """1 if any coordinate of point pid is too far for the line to be seen
    (its high byte's magnitude, again as ones' complement, at or beyond the
    line's maxLineDistance), otherwise the current showLine."""
    limit = M[maxLineDistance + line]
    for hi in (xPointHi, yPointHi, zPointHi):
        v = M[hi + pid]
        if v & 0x80:
            v ^= 0xFF
        if v >= limit:
            return 1
    return M[showLine]


def set_point_visibility(top):
    """Mark points top down to 1 as worked out."""
    for pid in range(top, 0, -1):
        M[pointStatus + pid] |= WORKED_OUT


def _relative_to_plane(oid, gg, k):
    """SetObjectCoords part 8: the object's position minus the plane's, into
    point gg, rotated by matrix 1. Returns "far" if any axis is beyond the
    object's visible distance (the axes are done in turn, and the point keeps
    whatever was written before the axis that failed), "outside" if the
    rotation overflowed the world, or "visible"."""
    axes = ((xObjectLo, xObjectHi, xPlaneLo, xPlaneHi, xPlaneTop, xPointLo, xPointHi),
            (yObjectLo, yObjectHi, yPlaneLo, yPlaneHi, yPlaneTop, yPointLo, yPointHi),
            (zObjectLo, zObjectHi, zPlaneLo, zPlaneHi, zPlaneTop, zPointLo, zPointHi))
    for olo, ohi, plo, phi, ptop, dlo, dhi in axes:
        obj = M[olo + oid] | (M[ohi + oid] << 8)
        plane = M[plo] | (M[phi] << 8) | (M[ptop] << 16)
        diff = (obj - plane) & 0xFFFFFF
        M[dlo + gg] = diff & 0xFF
        M[dhi + gg] = (diff >> 8) & 0xFF
        if check_obj_distance(oid, diff >> 16, (diff >> 8) & 0xFF, k):
            return "far"
    M[matrixNumber] = MATRIX_1
    set_point_coords(gg, MATRIX_1)
    return "outside" if M[showLine] else "visible"


def set_object_coords(bullet_point=0):
    """Work out where object objectId is relative to the plane, put its anchor
    in point 216 + id (bullet_point for the bullets, 12 to 15), and mark its
    status: bit 6 looked at, bit 7 visible. Returns the new status byte,
    whose bit 7 callers test.

    Group objects and the dormant aliens try each of their eight copies in
    turn and stop at the first within range. A bullet's trail ends below
    ground are not shown, and bullets are always near enough (their distance
    check is made to pass)."""
    oid = M[objectId]
    M[isObject] = oid
    gg = (FIRST_ANCHOR + oid) & 0xFF
    k = 1
    state = "objc3"
    if 12 <= oid < 16:
        k = 0
        gg = bullet_point
        if M[yObjectHi + oid] & 0x80 and not oid & 1:
            state = "objc10"
    elif 6 <= oid < 10:
        M[objCount] = GROUP_SIZE
        state = "objc2"

    while True:
        if state == "objc2":
            copy = M[objectGroup + oid - 6]
            M[xObjectHi + oid] = M[xGroupObjectHi + copy]
            M[zObjectHi + oid] = M[zGroupObjectHi + copy]
            state = "objc9"
        elif state == "objc3":
            if oid >= 34 or oid < 30:
                state = "objc9"
            elif oid == 30:
                if M[themeStatus]:
                    state = "objc12"
                else:
                    M[objCount] = GROUP_SIZE
                    state = "objc4"
            else:
                slot = M[alienSlot + oid - 30]
                if slot & 0x80:
                    state = "objc11"
                elif M[alienState + slot] >= 27:
                    state = "objc9"                 # heading for Acornsville
                else:
                    source = M[alienObjectId + slot]
                    state = ("objc5", source) if not source & 0x80 else "objc11"
        elif state == "objc4":
            slot = M[alienSlot]
            if M[alienState + slot]:
                state = "objc11"
            else:
                state = ("objc5", M[alienObjectId + slot])
        elif isinstance(state, tuple):              # objc5: take that alien's place
            source = state[1]
            M[xObjectHi + oid] = M[xObjectHi + source]
            M[zObjectHi + oid] = M[zObjectHi + source]
            state = "objc9"
        elif state == "objc9":
            verdict = _relative_to_plane(oid, gg, k)
            if verdict == "far":
                state = "objc10"
            elif verdict == "outside":
                state = "objc12"
            else:
                return _mark(oid, VISIBLE_OBJECT)
        elif state == "objc10":
            if next_object_group(oid):
                M[objCount] = (M[objCount] - 1) & 0xFF
                state = "objc12" if M[objCount] == 0 else "objc2"
            else:
                state = "objc11"
        elif state == "objc11":
            if oid != 30:
                state = "objc12"
            else:
                M[alienSlot] = (M[alienSlot] + 1) & 7
                M[objCount] = (M[objCount] - 1) & 0xFF
                state = "objc12" if M[objCount] == 0 else "objc4"
        elif state == "objc12":
            return _mark(oid, LOOKED_AT)


def _mark(oid, bits):
    M[objectStatus + oid] |= bits
    return M[objectStatus + oid]


def process_horizon_line(start, end):
    """The horizon: a start point at (-4096, 0, z) and an end point at
    (0, 0, z), with z = +10240 or -10240, rotated by matrix 4 (roll and pitch,
    no yaw), so the line lies along the horizon whichever way the plane
    points. z is +10240 when the plane's pitch is within a quarter turn of
    level and -10240 when it is beyond that (the top two bits of the pitch
    differ), so the points are always on the side the plane is looking at.
    Only half the horizon is a line in the world; the canopy drawing mirrors
    it for the other half (DrawHalfHorizon)."""
    set_point_to(end, 0)
    set_point_to(start, 0)
    M[xPointHi + start] = 0xF0
    pid = start
    while True:
        rot = M[xRotationHi]
        same = bool(rot & 0x80) == bool(rot & 0x40)
        M[zPointHi + pid] = 40 if same else 216
        M[pointStatus + pid] |= WORKED_OUT
        M[matrixNumber] = MATRIX_4
        set_point_coords(pid, MATRIX_4)
        if pid == end:
            return
        pid = end


def process_runway_line():
    """The runway: lines 1 to 4 are its outline, 5 to 11 the dashes down the
    middle. The first runway line looked at in an iteration works out the
    whole runway: the anchor (point 217, which is also corner 1), corners 2
    and 4 from the runway object's offsets, corner 3 as 2 + (4 - anchor),
    then, if the dashes are near enough, 15 points along the middle (5 to 19)
    a sixteenth of the length apart, starting half a width in from the end.
    The rest read the verdict from the runway object's status.

    If the line along the middle crosses the plane's z = 0 (part ahead, part
    behind), the end of the outline behind the plane is pulled in to the
    first point ahead, so the projection never sees a corner behind the
    viewer."""
    status = M[objectStatus + RUNWAY]
    if status:
        if status & 0x80:
            if M[lineId] >= 5:
                M[showLine] = M[showRunwayDashes]
            return
        M[showLine] = NOT_VISIBLE
        return

    M[matrixNumber] = MATRIX_1
    M[objectId] = RUNWAY
    status = set_object_coords()
    if not status & 0x80:
        M[showLine] = NOT_VISIBLE
        return
    set_temp1((0, 0, 0))
    M[objectAnchorPoint] = RUNWAY_ANCHOR
    add_temp_to_point(1, RUNWAY_ANCHOR)
    set_obj_point_coords(2, M[matrixNumber])
    # Keep corner 2's vector from the anchor in (xTemp2Top xTemp2Hi), the top
    # two bytes of a 24-bit vector, for the dashes.
    for i in range(6):
        M[xTemp2Hi + i] = M[xTemp1Lo + i]
    set_obj_point_coords(4, M[matrixNumber])
    add_temp_to_point(3, 2)
    if M[showLine]:
        M[objectStatus + RUNWAY] = LOOKED_AT
        return
    set_point_visibility(4)

    for pid in (1, 3):
        verdict = check_line_distance(10, pid)
        M[showLine] = verdict
        if verdict:
            M[showRunwayDashes] = NOT_VISIBLE
            M[showLine] = 0 if M[lineId] < 5 else NOT_VISIBLE
            return

    # The dashes. Half the width vector (corner 4 - anchor) gives the middle
    # of each end: point 21 off corner 2 and point 5 off corner 1.
    half = []
    for v in temp1():
        half.append(((v >> 1) | (v & 0x8000)) & 0xFFFF)
    set_temp1(half)
    add_temp_to_point(21, 2)
    add_temp_to_point(5, 1)
    for i in range(6):
        M[xDashesVectorLo + i] = M[xTemp1Lo + i]

    # A sixteenth of the length vector, as a 24-bit (xTemp1Hi xTemp1Lo low)
    # step, so the fifteen steps don't accumulate rounding.
    low = [0, 0, 0]
    for axis in range(3):
        length = (M[xTemp2Hi + 3 + axis] << 8) | M[xTemp2Hi + axis]
        wide = length << 8
        if length & 0x8000:
            wide |= 0xFF000000
        step = (wide >> 4) & 0xFFFFFF
        M[xTemp1Hi + axis] = step >> 16
        M[xTemp1Lo + axis] = (step >> 8) & 0xFF
        low[axis] = step & 0xFF
    work = xTemp2Lo - xTurnHi                    # the offset CopyPointToWork takes
    copy_point_to_work(5, work)
    acc = [0, 0, 0]                              # the low bytes of the running point
    pid = 5
    while pid != 19:
        for axis in (2, 1, 0):
            total = acc[axis] + low[axis]
            acc[axis] = total & 0xFF
            mid = M[xTemp2Lo + axis] + M[xTemp1Lo + axis] + (total >> 8)
            M[xTemp2Lo + axis] = mid & 0xFF
            M[xTemp2Hi + axis] = (M[xTemp2Hi + axis] + M[xTemp1Hi + axis] + (mid >> 8)) & 0xFF
        pid += 1
        copy_work_to_point(work, pid)
    set_point_visibility(19)

    # Pull in the end of the outline that is behind the plane.
    for i in range(6):
        M[xTemp1Lo + i] = M[xDashesVectorLo + i]
    sign = M[zPointHi + 6]
    pid = 6
    while pid < 20:
        if (M[zPointHi + pid] ^ sign) & 0x80:
            break
        pid += 1
    else:
        return
    if not sign & 0x80:
        second, first = 2, 3
    else:
        pid -= 1
        second, first = 1, 4
    add_temp_to_point(first, pid)
    set_temp1([(-v) & 0xFFFF for v in temp1()])
    add_temp_to_point(second, pid)


def process_line(line, check_distance=True):
    """Work out whether line `line` is visible, setting showLine (0 if so),
    and work out its points' coordinates relative to the plane on the way.
    check_distance=False skips the check against the line's maximum visible
    distance (the original's HH non-zero), which lines already on screen
    don't need.

    The original keeps the chain of linked points on the 6502 stack; here it
    is a list, worked through in the same order."""
    M[showLine] = 0
    M[isObject] = 0
    end = M[lineEndPointId + line]
    start = M[lineStartPointId + line]
    if line < 12:
        if line == 0:
            process_horizon_line(start, end)
            return
        process_runway_line()
        _behind_check(start, end)
        return

    M[pointCount] = 2
    pid = start
    while True:
        result = _work_out_point(line, pid, check_distance)
        if result is None:
            return
        pid = result
        # plin17/plin18: the distance check, then mark the point.
        if check_distance:
            verdict = check_line_distance(line, pid)
            M[showLine] = verdict
            if verdict:
                return
        M[pointStatus + pid] |= WORKED_OUT
        M[pointCount] = (M[pointCount] - 1) & 0xFF
        if M[pointCount] == 0:
            break
        pid = end
    _behind_check(start, end)


def _behind_check(start, end):
    """plin19: a line with both ends behind the plane isn't shown, and a group
    object it belongs to moves on to its next copy."""
    if not M[zPointHi + end] & 0x80:
        return
    if not M[zPointHi + start] & 0x80:
        return
    M[showLine] |= NOT_VISIBLE
    next_object_group(M[isObject])


def _work_out_point(line, pid, check_distance):
    """plin3 to plin16 for one of a line's points: make sure its coordinates
    are worked out, following its chain of linked points to the object it
    belongs to. Returns the point ID to go on with (for the distance check),
    or None if the line has been found not visible (showLine is set)."""
    if M[pointStatus + pid] & WORKED_OUT:
        return pid
    stack = [pid]
    M[pointId] = pid
    p = pid
    while True:
        entry = M[objectPoints + p]
        if entry < LINK:
            break
        p = entry - LINK
        M[objectAnchorPoint] = p
        if M[pointStatus + p] & WORKED_OUT:
            return _rotate_chain(stack)
        stack.append(p)
        if M[relatedPoints] >= RELATED_POINTS_MAX:
            M[showLine] = NOT_VISIBLE
            return None
        M[relatedPoints] += 1
        M[relatedPoints + M[relatedPoints]] = p

    oid = entry
    M[objectId] = oid
    if 12 <= oid < 16:
        # A bullet's point: the object must already be visible.
        gg = stack.pop()
        if M[objectStatus + oid] & 0x80:
            return gg
        M[showLine] = NOT_VISIBLE
        return None
    if not M[objectStatus + oid] & LOOKED_AT:
        set_object_coords()
    oid = M[objectId]
    if not M[objectStatus + oid] & 0x80:
        M[showLine] = NOT_VISIBLE
        return None
    M[objectAnchorPoint] = (oid + FIRST_ANCHOR) & 0xFF
    return _rotate_chain(stack)


def _rotate_chain(stack):
    """plin14 and plin15: work out the points on the stack, nearest the
    anchor first, each from the one before. The first point pushed (the
    line's own point) is the last done. Returns that point, or None if any
    overflowed the world."""
    first = stack[0]
    while len(stack) > 1:
        gg = stack.pop()
        M[matrixAxis] = 0
        M[matrixNumber] = MATRIX_1
        set_obj_point_coords(gg, MATRIX_1)
        if M[showLine]:
            return None
        M[objectAnchorPoint] = gg
        M[pointStatus + gg] |= WORKED_OUT
    M[matrixAxis] = 0
    M[matrixNumber] = MATRIX_1
    set_obj_point_coords(first, MATRIX_1)
    if M[showLine]:
        return None
    return first


def show_or_hide_line(line):
    """Check line `line` and add it to linesToShow or linesToHide."""
    process_line(line, check_distance=True)
    if M[showLine]:
        M[linesToHideEnd] = (M[linesToHideEnd] + 1) & 0xFF
        M[linesToHide + M[linesToHideEnd]] = line
        return
    M[linesToShowEnd] = (M[linesToShowEnd] + 1) & 0xFF
    M[linesToShowPointer] = (M[linesToShowPointer] + 1) & 0xFF
    M[linesToShow + M[linesToShowPointer]] = line


def update_lines_to_show():
    """Check every line on linesToShow again, keeping the visible ones (and
    the horizon, always) and moving the rest to linesToHide."""
    if not M[linesToShowEnd]:
        return
    M[linesToShowPointer] = 0xFF
    M[lineCounter] = 0
    while True:
        line = M[linesToShow + M[lineCounter]]
        M[lineId] = line
        process_line(line, check_distance=False)
        if line == 0 or not M[showLine]:
            M[linesToShowPointer] = (M[linesToShowPointer] + 1) & 0xFF
            M[linesToShow + M[linesToShowPointer]] = line
        else:
            M[linesToHideEnd] = (M[linesToHideEnd] + 1) & 0xFF
            M[linesToHide + M[linesToHideEnd]] = line
        M[lineCounter] = (M[lineCounter] + 1) & 0xFF
        if M[lineCounter] >= M[linesToShowEnd]:
            break
    M[linesToShowEnd] = (M[linesToShowPointer] + 1) & 0xFF


def process_lines_to_hide():
    """Take the next unchecked line from linesToHide and check it again,
    skipping the bullet trail lines; ShowOrHideLine puts it back on one list
    or the other."""
    while True:
        if M[linesToHidePointer] == M[linesToHideEnd]:
            return
        M[linesToHidePointer] = (M[linesToHidePointer] + 1) & 0xFF
        line = M[linesToHide + M[linesToHidePointer]]
        M[lineId] = line
        if line not in SKIPPED_HIDDEN_LINES:
            break
    show_or_hide_line(line)


def process_lines_to_show():
    """Project both points of every line on linesToShow onto the screen, and
    move to linesToHide any line whose points are both off the same side of
    the screen (the horizon always stays). Then clear the "worked out" marks
    of every point on the relatedPoints list, ready for the next iteration.

    ProjectPoint leaves bits 2 to 5 of each point's status saying which side
    of the screen it is off, if any: bits 4 and 5 that it is off at all, in x
    and in y, bits 2 and 3 which way. Both ends off the same way means the
    line can't cross the screen."""
    from .project import project_point
    if M[linesToShowEnd]:
        M[linesToShowPointer] = 0xFF
        M[lineCounter] = 0
        while True:
            line = M[linesToShow + M[lineCounter]]
            M[lineId] = line
            start = M[lineStartPointId + line]
            end = M[lineEndPointId + line]
            project_point(start)
            project_point(end)
            M[startStatus] = M[pointStatus + start]
            end_status = M[pointStatus + end]
            both_off = end_status & M[startStatus] & 0x30
            hide = False
            if both_off:
                same_way = ~(end_status ^ M[startStatus]) & (both_off >> 2) & 0xFF
                hide = bool(same_way) and line != 0
            if hide:
                M[linesToHideEnd] = (M[linesToHideEnd] + 1) & 0xFF
                M[linesToHide + M[linesToHideEnd]] = line
            else:
                M[linesToShowPointer] = (M[linesToShowPointer] + 1) & 0xFF
                M[linesToShow + M[linesToShowPointer]] = line
            M[lineCounter] = (M[lineCounter] + 1) & 0xFF
            if M[lineCounter] >= M[linesToShowEnd]:
                break
        M[linesToShowEnd] = (M[linesToShowPointer] + 1) & 0xFF
    for x in range(M[relatedPoints], 0, -1):
        M[pointStatus + M[relatedPoints + x]] = 0
