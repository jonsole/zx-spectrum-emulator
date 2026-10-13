"""The view out of the canopy, each iteration: the visible lines, the
horizon's second half, the canopy's top corners and the gun sights.

The BBC draws the new view in one of Mode 5's colours while the old one
still shows in the other, then swaps the two in the palette and rubs the old
view out (see the "flicker-free animation through colour cycling" deep
dive). colourCycle says which colour is showing, colourLogic which the
drawing is in, and each colour's lines are kept in a line buffer so they can
be drawn again, in AND, to erase them.

The port keeps all of that state exactly as the original does, since it is
cheap and the tests compare it, but the drawing itself goes to hooks: the
lines to clip.draw_hook (each a CanopyLine, as drawn), and the rest to
`hook`, called as

    hook("erase", CanopyLine)       a buffered line rubbed out
    hook("show", colour)            the palette swap: colour (1 or 2) now shows
    hook("corners")                 the canopy's diagonal top corners redrawn
    hook("sights", shown)           the gun sights drawn (shown True) or cleared
    hook("fill", colour, row, rows) character rows of the canopy filled
                                    (row is the Mode 5 character row)

A renderer that keeps a buffer of its own (the Spectrum's) can ignore the
erasing and draw each view afresh: the BBC shows, after each swap, exactly
the lines drawn since the swap before, plus the corners and sights.

Not reproduced: the bytes of DrawCanopyLine's code that ModifyDrawRoutine
rewrites to choose the colour and the logic (DRAWING_CODE below), which only
the drawing code reads.
"""

from . import clip
from .controls import toggle_joystick
from .hardware import KEY_CODES, key_pressed
from .memory import M
from .names import (colourCycle, colourLogic, dlin2, dlin4, dlin23, dlin24, dlin28, dlin29,
                    dlin34, dlin47, dlin50, dlin51, dlin58, dlin59, dlin62, dlin63, gunSights,
                    lineBuffer1Count, lineBuffer2Count, lineBufferG, lineBufferR, lineBufferS,
                    lineBufferT, lineBufferU, lineBufferV, lineBufferW, lineCounter,
                    lineEndPointId, lineId, linesToShow, linesToShowEnd, lineStartPointId,
                    pointStatus, xPointHi, xPointLo, xTemp1Lo, yPointHi, yPointLo, yTemp1Lo)

SHOW_1 = 0x0F                # colourCycle: colour 1 showing, colour 2 hidden
SHOW_2 = 0xF0
DRAW_1 = 0x80                # colourLogic: drawing in colour 1
DRAW_2 = 0x40
ERASE = 0x00

HORIZON_LINE = 0
HORIZON_MIDDLE = 30          # the horizon is 31 -> 30 -> 32; line 0 is 31 to 30
HORIZON_START = 31
HORIZON_END = 32

BUFFER1_EMPTY = 0xFF
BUFFER2_EMPTY = 47

SIGHTS_ROW = 6               # the gun sights fill character rows 6 to 8
SIGHTS_ROWS = 3
CANOPY_ROW = 1               # FillCanopy covers rows 1 to 19
CANOPY_ROWS = 19

# DrawCanopyLine's instructions and operands that ModifyDrawRoutine rewrites.
DRAWING_CODE = (dlin24, dlin29, dlin34, dlin51, dlin2 + 1, dlin23 + 1, dlin4 + 1, dlin28 + 1,
                dlin50, dlin50 + 1, dlin47 + 1, dlin58 + 1, dlin59 + 1, dlin62 + 1, dlin63 + 1)


def _no_drawing(*args):
    pass


hook = _no_drawing


def modify_draw_routine():
    """ModifyDrawRoutine: on the BBC, rewrite the line drawer for the current
    colour and logic. Nothing of it is state the game reads; the colour each
    line is drawn in reaches the hook in its CanopyLine."""


def flip_colours():
    """Swap which colour shows and which is drawn in. Starting from an erase
    (colourLogic 0), this also sets colourLogic back to drawing."""
    if M[colourCycle] & 0x80:
        M[colourCycle], M[colourLogic] = SHOW_1, DRAW_1
    else:
        M[colourCycle], M[colourLogic] = SHOW_2, DRAW_2


def draw_half_horizon():
    """The horizon's second half: point 32 is point 30 doubled less point 31,
    so the line 31-30 carries on through 30 as far again, and that half is
    drawn from 30 to 32."""
    for lo, hi in ((xPointLo, xPointHi), (yPointLo, yPointHi)):
        middle = M[lo + HORIZON_MIDDLE] | (M[hi + HORIZON_MIDDLE] << 8)
        start = M[lo + HORIZON_START] | (M[hi + HORIZON_START] << 8)
        end = ((middle << 1) - start) & 0xFFFF
        M[lo + HORIZON_END] = end & 0xFF
        M[hi + HORIZON_END] = end >> 8
    clip.draw_clipped_line(HORIZON_MIDDLE, HORIZON_END, horizon=True)


def erase_canopy_lines():
    """Rub out the hidden colour's lines, emptying its line buffer."""
    M[colourLogic] = ERASE
    modify_draw_routine()
    while True:
        if M[colourCycle] & 0x80:
            slot = M[lineBuffer2Count]
            if slot == BUFFER2_EMPTY:
                return
            M[lineBuffer2Count] = (slot - 1) & 0xFF
        else:
            slot = M[lineBuffer1Count]
            if slot == BUFFER1_EMPTY:
                return
            M[lineBuffer1Count] = (slot - 1) & 0xFF
        r, w, s, g = M[lineBufferR + slot], M[lineBufferW + slot], M[lineBufferS + slot], M[lineBufferG + slot]
        t, u, v = M[lineBufferT + slot], M[lineBufferU + slot], M[lineBufferV + slot]
        M[xTemp1Lo] = r
        M[yTemp1Lo] = s
        (x0, y0), (x1, y1) = clip.canopy_line_ends(r, s, w, g, t, u, v)
        hook("erase", clip.CanopyLine(x0, y0, x1, y1, r, s, slot, 0,
                                      bool(v & clip.HORIZON), bool(v & clip.CLIPPED)))


def draw_gun_sights():
    """The canopy's corners every time, and the gun sights if they are on;
    I switches them on and off, once a press (bit 7 of gunSights is on,
    bit 6 that I is held). Then, as the original falls through to it,
    ToggleJoystick."""
    hook("corners")
    if key_pressed(KEY_CODES["I"]):
        if not M[gunSights] & 0x40:
            a = M[gunSights] ^ 0xC0
            if not a & 0x80:
                hook("fill", 0, SIGHTS_ROW, SIGHTS_ROWS)
            M[gunSights] = a
    else:
        M[gunSights] &= 0x80
    if M[gunSights] & 0x80:
        hook("sights", True)
    toggle_joystick()


def fill_canopy(colour, row=CANOPY_ROW, rows=CANOPY_ROWS):
    hook("fill", colour, row, rows)


def clear_canopy():
    fill_canopy(0)


def draw_canopy_view():
    """Draw every line on linesToShow (the horizon's other half with line 0),
    marking each line's points as needing working out again, then the
    corners and the sights; swap the colours, rub out the old view, and flip
    colourCycle and colourLogic for next time. With nothing to show, only the
    flip happens."""
    modify_draw_routine()
    if M[linesToShowEnd]:
        M[lineCounter] = 0
        while True:
            line = M[linesToShow + M[lineCounter]]
            M[lineId] = line
            if line == HORIZON_LINE:
                draw_half_horizon()
                line = M[lineId]
            end = M[lineEndPointId + line]
            M[pointStatus + end] = 0
            start = M[lineStartPointId + line]
            M[pointStatus + start] = 0
            clip.draw_clipped_line(start, end)
            M[lineCounter] = (M[lineCounter] + 1) & 0xFF
            if M[lineCounter] >= M[linesToShowEnd]:
                break
        draw_gun_sights()
        hook("show", 1 if not M[colourCycle] & 0x80 else 2)
        erase_canopy_lines()
    flip_colours()
