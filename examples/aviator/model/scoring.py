"""The score, and the two tests of flying skill.

Scores are kept as four BCD digits in score(Hi Lo), counting tens of points
(the display adds a 0), so &0150 is 1,500 points. Points are added through
UpdateScore, or ScorePoints, which also beeps.

The tests of flying skill award points for flying under the suspension
bridge (50, or 100 upside down) and down the main street of Acornsville (100,
or 200 upside down). Each is a set of boxes in the world -- skill zones --
that the plane must be inside, while staying out of the others (the bridge's
deck, the buildings), and the points are banked in pointsToAward and paid out
once the plane is clear again. Flying into a forbidden zone is a crash.

Upside down is told from the dashboard: the bar at the bottom of the
artificial horizon (screen byte row25_char13_1) is drawn only when the plane
is inverted, and the original reads that byte rather than the plane's
rotation. The port keeps that byte where the original does, written by the
dashboard code.

The scores' display goes to `display_hook` (the BBC prints text in the
canopy; the Spectrum will do its own): it is called with ("show", high
score, score) when the scores are shown, ("remove",) when they are taken
down, and ("too late",) for the TOO LATE! message.
"""

from .events import Crash
from .memory import M
from .names import (highScoreHi, highScoreLo, pointsToAward, row25_char13_1, scoreHi, scoreLo,
                    skillZoneHi, skillZoneLo, skillZoneSize, xObjectHi, xPlaneHi, xPlaneLo,
                    zObjectHi, zPlaneHi)
from .sound import make_sound

BEEP = 3                     # sound number for points scored

BRIDGE = 2                   # CheckFlyingSkills' argument: the bridge's object ID
TOWN = 34                    # and the town's
NEAR = 5                     # within 5 x 256 units on x and z before the zones are checked


def _no_display(*args):
    pass


display_hook = _no_display


def bcd_add(a, b, carry):
    """The 6502's decimal-mode ADC of two BCD bytes: (result, carry out)."""
    lo = (a & 0x0F) + (b & 0x0F) + carry
    hi = (a & 0xF0) + (b & 0xF0)
    if lo > 0x09:
        lo += 0x06
    if lo > 0x0F:
        hi += 0x10
    if hi > 0x90:
        hi += 0x60
    return (hi & 0xF0) | (lo & 0x0F), 1 if hi > 0xFF else 0


def update_score(points):
    """Add points (four BCD digits, in tens) to the score.

    The original wraps a score that goes past 9,999 tens back round, and has
    one more case: adding with a high byte of &99 and no carry out resets the
    score to zero. It is never called that way."""
    lo, carry = bcd_add(points & 0xFF, M[scoreLo], 0)
    M[scoreLo] = lo
    hi, carry = bcd_add(points >> 8, M[scoreHi], carry)
    M[scoreHi] = hi
    if not carry and (points >> 8) == 0x99:
        M[scoreLo] = 0
        M[scoreHi] = 0


def score_points(points):
    update_score(points)
    make_sound(BEEP)


def update_high_score():
    score = (M[scoreHi] << 8) | M[scoreLo]
    high = (M[highScoreHi] << 8) | M[highScoreLo]
    if score >= high:
        M[highScoreLo] = M[scoreLo]
        M[highScoreHi] = M[scoreHi]


def display_score():
    display_hook("show", (M[highScoreHi] << 8) | M[highScoreLo], (M[scoreHi] << 8) | M[scoreLo])


def remove_score():
    display_hook("remove")


def print_too_late():
    display_hook("too late")


def check_bridge_and_town(zone):
    """Whether the plane is inside skill zone `zone` (0, 3, ... 18): a box with
    its corner nearest the origin at the zone's coordinate and its size four
    times the zone's skillZoneSize, on every axis."""
    for axis in (2, 1, 0):
        i = zone + axis
        plane = M[xPlaneLo + axis] | (M[xPlaneHi + axis] << 8)
        corner = M[skillZoneLo + i] | (M[skillZoneHi + i] << 8)
        d = (plane - corner) & 0xFFFF
        if d & 0x8000:
            return False
        d >>= 2
        if d >> 8:
            return False
        if d >= M[skillZoneSize + i]:
            return False
    return True


def _upside_down():
    return M[row25_char13_1] != 0


def check_flying_skills(target):
    """Check the bridge (target 2) or the town (34) test of skill."""
    def near(plane_hi, object_hi):
        d = (M[plane_hi] - M[object_hi + target]) & 0xFF
        if d & 0x80:
            d ^= 0xFF
        return d < NEAR

    if not near(xPlaneHi, xObjectHi) or not near(zPlaneHi, zObjectHi):
        return
    if target == BRIDGE:
        if not check_bridge_and_town(6) or check_bridge_and_town(3):
            _pay_out()
            return
        if not check_bridge_and_town(0):
            raise Crash("hit the bridge")
        M[pointsToAward] = 0x10 if _upside_down() else 0x05
        return
    for zone in (12, 15, 9):
        if check_bridge_and_town(zone):
            raise Crash("hit a building")
    if not check_bridge_and_town(18):
        _pay_out()
        return
    M[pointsToAward] = 0x20 if _upside_down() else 0x10


def _pay_out():
    """skil9: outside the zone, so pay any points banked on the way in."""
    if M[pointsToAward]:
        score_points(M[pointsToAward])
        M[pointsToAward] = 0
