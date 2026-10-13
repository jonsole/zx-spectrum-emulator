"""The game as a whole: starting it, the main loop, and a flight's end.

    from model import game
    g = game.Game()          # loads the original's memory image and starts
    g.iterate()              # one pass of the main loop

The modules each port a part of the original; this one ties them together
the way the original's main loop does (see "program flow of the main game
loop" and "scheduling tasks in the main loop" deep dives). Each iteration:

1. a new alien may spawn; the keys are read and the flight model run
   (UpdateFlightModel: controls, matrices, ApplyFlightModel, dashboard);
   firing adds the two bullet trail lines to linesToShow;
2. every object is marked as not yet looked at;
3. the bullets move;
4. the alien heading for Acornsville moves;
5. the visible lines are checked again, an exploding alien moves on, the
   bridge and the main street are checked for flying skills, and every
   eighth iteration the radar is updated;
6. bullets in flight are checked against each alien, and the aliens move on
   through their lives;
7. the right arrow, on the ground, ends the flight;
8. firing on the runway starts the Theme; standing with the engine off
   fills the tank; the volume keys; a landing after reaching 512 feet scores;
9. T starts and stops the engine;
10. hidden lines are checked, three at a time, until 9 centiseconds have
    gone since the last time through (CheckTimePassed);
11. the visible lines are projected and drawn, and a random number taken;
12. P shows the scores for a while;
13. the points of lines newly hidden are marked as needing working out.

The memory image the port starts from is the original's, as its own loader
leaves it: the game binary moved into place, the screen cleared and the
dashboard image loaded into it. The binary also holds the game's tables (the
world, the sines and so on); acornsoft.py fetches it. Some of the
variables start with whatever the move left in them, and the port starts
with the same.

The BBC's time and hardware are reached through model.hardware, the
drawing through each module's hooks and the sound through model.sound.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import acornsoft  # noqa: E402

from . import canopy, clip, controls, dashboard, flight, hardware, matrices, scoring, theme, visibility  # noqa: E402
from .events import Crash, FlightOver, Terminated, TooLate  # noqa: E402
from .memory import M  # noqa: E402
from .names import (alienObjectId, alienSlot, alienSpeed, alienState, alienStatus, alienToMove,  # noqa: E402
                    brakesStatus, colourCycle, colourLogic, distanceFromHit, engineStatus,
                    firingStatus, forceFactor, fuelLevel, gunSoundCounter, highScoreHi,
                    highScoreLo, hitTimer, landingStatus, lineBuffer1Count, lineBuffer2Count,
                    lineEndPointId, lineId, linesToHide, linesToHideEnd, linesToHidePointer,
                    linesToShow, linesToShowEnd, linesToShowPointer, lineStartPointId,
                    mainLoopCounter, matrixAxis, matrixNumber, numberOfLines, objectId,
                    objectStatus, onGround, pointStatus, pressingT, previousListEnd, previousTime,
                    propellorStatus, randomNumbers, reached512ft, relatedPoints, scoreDisplayTimer,
                    scoreHi, scoreLo, showRunwayDashes, themeStatus, ucStatus, xPlaneHi, xPlaneLo,
                    xRotationHi, xTurnHi, yPlaneLo, zPlaneHi, zPlaneLo)
from .scoring import score_points  # noqa: E402
from .sound import make_sound  # noqa: E402

# The original's loader: where the binary loads, the two blocks its entry
# routine moves down (and the one it moves again in DrawCanopy), and where
# the dashboard image goes.
LOAD = acornsoft.AVIA_LOAD
MOVES = ((0x5800, 0x0400, 0x0400),      # &5800-&5BFF to &0400 (Entry)
         (0x5C00, 0x0B00, 0x0200),      # &5C00-&5DFF to &0B00 (Entry)
         (0x0400, 0x0D00, 0x0400))      # &0400-&07FF to &0D00 (DrawCanopy)
SCREEN = (0x5800, 0x8000)

GUN_SOUND = 6
CRASH_SOUND = 5
TRAIL_LINES = (60, 61)
TIME_SLICE = 9               # centiseconds spent on hidden lines an iteration
RELATED_POINTS_BUSY = 35     # don't start more hidden lines past this
SCORE_SHOWN_FOR = 220        # scoreDisplayTimer counts down from 255 to here
LANDING_POINTS = 0x15        # 150 points for a landing
WAVE_START = 8

# Indicators.
THRUST = 11


def load_image():
    """The original's memory as its loader leaves it, in M."""
    M[:] = bytes(65536)
    binary = acornsoft.read("AVIA.bin")
    M[LOAD:LOAD + len(binary)] = binary
    for src, dst, size in MOVES:
        M[dst:dst + size] = M[src:src + size]
    # SetupScreen changes to Mode 5, which clears the screen (and the code
    # that was there), and loads the dashboard.
    M[SCREEN[0]:SCREEN[1]] = bytes(SCREEN[1] - SCREEN[0])
    image = acornsoft.read("DASHBD.bin")
    M[acornsoft.DASHBD_LOAD:acornsoft.DASHBD_LOAD + len(image)] = image


def wire_hooks():
    """Connect the flight model's dashboard calls to the dashboard."""
    flight.show_upside_down_bar = dashboard.show_upside_down_bar
    flight.draw_fuel_pixel = dashboard.draw_fuel_pixel


def update_flight_model():
    """UpdateFlightModel: the controls, then the matrices from the plane's
    rotation, then the flight model, then two dashboard indicators."""
    controls.move_axes()
    controls.read_joystick()
    if controls.move_throttle():
        dashboard.update_indicator(THRUST)
    pressed = flight.process_other_keys(4)
    if pressed & 0x80:
        flight.indicator_b()
    elif pressed:
        flight.indicator_u()
    pressed = flight.process_other_keys(5)
    if pressed & 0x80:
        theme.fire_guns()
    elif pressed:
        flight.indicator_f()
    for axis in (2, 1, 0):
        M[matrixAxis] = axis
        matrices.project_axis_angle(axis)
    M[matrixNumber] = 0
    M[matrixAxis] = 0
    matrices.set_matrices()
    flight.apply_flight_model()
    dashboard.update_dashboard()
    dashboard.update_dash_7_to_11()


def reset_variables():
    """ResetVariables: a new flight, on the runway with the engine off and
    an empty tank."""
    M[alienSlot] = 0
    M[forceFactor + 7] = 0
    M[hitTimer] = 0
    M[randomNumbers] = 0
    M[scoreLo] = M[scoreHi] = 0
    M[pointStatus:pointStatus + 256] = bytes(256)
    M[relatedPoints] = 0
    M[mainLoopCounter] = 0
    M[xTurnHi:xTurnHi + 255] = bytes(255)
    M[alienState:alienState + 8] = bytes(8)
    M[zPlaneHi], M[zPlaneLo] = 0x48, 0x5C
    M[xPlaneHi], M[xPlaneLo] = 0xC6, 0xE5
    M[yPlaneLo] = 0x0A
    M[alienSpeed] = 0x0A
    M[forceFactor + 5] = 242
    M[ucStatus] = M[brakesStatus] = M[landingStatus] = 1
    flight.indicator_u()
    M[onGround] = 1
    M[lineBuffer2Count] = 47
    M[themeStatus] = 0xFF
    M[lineBuffer1Count] = 0xFF
    M[xRotationHi] = 7
    M[alienObjectId:alienObjectId + 8] = b"\xff" * 8
    M[alienSlot + 1:alienSlot + 4] = b"\xff" * 3
    flight.indicator_t()
    dashboard.update_indicator(THRUST)
    M[fuelLevel] = 65
    while True:
        M[fuelLevel] -= 1
        dashboard.update_fuel_gauge()
        if not M[fuelLevel]:
            break
    # The original falls through into ResetRadar.
    dashboard.reset_radar()


def reset_line_lists():
    """ResetLineLists: sort every line of the world into linesToShow or
    linesToHide afresh."""
    M[colourLogic] = canopy.DRAW_1
    M[colourCycle] = canopy.SHOW_1
    canopy.modify_draw_routine()
    M[lineId] = 0
    M[linesToShowEnd] = 0
    M[linesToHideEnd] = M[linesToShowPointer] = M[linesToHidePointer] = 0xFF
    while True:
        visibility.show_or_hide_line(M[lineId])
        M[lineId] = (M[lineId] + 1) & 0xFF
        if M[lineId] >= M[numberOfLines]:
            break
    canopy.hook("palette", 3, "white")
    # The original falls through into FlipColours, so the first iteration
    # draws in colour 2.
    canopy.flip_colours()


def new_game():
    canopy.clear_canopy()
    reset_variables()
    controls.update_key_logger()
    update_flight_model()
    reset_line_lists()
    flight.indicator_f()
    flight.indicator_b()


def start_game():
    M[highScoreHi] = M[highScoreLo] = 0
    flight.define_envelope(14)
    new_game()


def check_time_passed(now):
    """Whether 9 centiseconds have gone since the last time this said so
    (the low byte of the clock, either way round)."""
    elapsed = (now - M[previousTime]) & 0xFF
    if elapsed & 0x80:
        elapsed = (-elapsed) & 0xFF
    if elapsed >= TIME_SLICE:
        M[previousTime] = now & 0xFF
        return True
    return False


def terminate_game():
    """TerminateGame, up to waiting for RETURN: the engine quiet, the high
    score updated and the scores shown."""
    flight.toggle_engine_sound(0)
    scoring.update_high_score()
    scoring.display_score()


def crash():
    """The Crash routine, up to waiting for RETURN: the crash sound, a white
    flash of the canopy, and the scores."""
    flight.toggle_engine_sound(0)
    make_sound(CRASH_SOUND)
    canopy.fill_canopy(0xFF)
    canopy.clear_canopy()
    canopy.hook("corners")
    terminate_game()


def main_loop():
    """One iteration of the main loop. Raises events.FlightOver (Crash,
    TooLate or Terminated) where the original ends the flight; the end's
    own sequence has been done by then, up to waiting for RETURN."""
    M[previousListEnd] = M[linesToHideEnd]
    theme.spawn_alien()
    controls.update_key_logger()
    already_firing = M[firingStatus]
    update_flight_model()
    if not already_firing and M[firingStatus]:
        M[gunSoundCounter] = 2
        for oid in range(33, 29, -1):
            M[alienStatus - 30 + oid] = M[objectStatus + oid]
        end = M[linesToShowEnd]
        M[linesToShow + end] = TRAIL_LINES[0]
        M[linesToShow + end + 1] = TRAIL_LINES[1]
        M[linesToShowEnd] = (end + 2) & 0xFF

    M[showRunwayDashes] = 0
    M[relatedPoints] = 0
    M[objectStatus:objectStatus + 40] = bytes(40)

    if M[firingStatus]:
        theme.update_bullets()
        if M[gunSoundCounter]:
            M[gunSoundCounter] -= 1
            make_sound(GUN_SOUND)

    if not M[themeStatus] & 0x80:
        theme.alien_in_acornsville()

    visibility.update_lines_to_show()
    theme.explode_alien()
    scoring.check_flying_skills(scoring.BRIDGE)
    scoring.check_flying_skills(scoring.TOWN)
    M[mainLoopCounter] = (M[mainLoopCounter] + 1) & 0xFF
    if not (M[mainLoopCounter] + 4) & 7:
        dashboard.update_radar_blip(1)
        mover = M[alienToMove]
        if not mover & 0x80 and M[alienState + mover] >= theme.HEADING_FOR_TOWN:
            dashboard.update_radar_blip(33)

    if not M[themeStatus]:
        if M[firingStatus]:
            M[objectId] = 33
            while True:
                oid = M[objectId]
                if M[alienStatus - 30 + oid] & 0x80:
                    theme.check_if_alien_is_hit(oid)
                    if M[hitTimer]:
                        M[distanceFromHit] = M[hitTimer]
                        M[firingStatus] = 0
                        break
                M[objectId] = (oid - 1) & 0xFF
                if M[objectId] < 30:
                    break
        theme.update_aliens()

    if M[onGround] and hardware.key_pressed(hardware.KEY_CODES["RIGHT"]):
        terminate_game()
        raise Terminated("ended on the ground")

    status = M[landingStatus]
    if status:
        if not status & 0x80:
            if M[firingStatus] and M[themeStatus] & 0x80:
                M[themeStatus] = WAVE_START
                flight.indicator_t()
            if not M[engineStatus]:
                flight.fill_up_fuel_tank()
            controls.process_volume_keys()
        if M[reached512ft]:
            M[reached512ft] = 0
            score_points(LANDING_POINTS)

    dashboard.update_fuel_gauge()
    skip_store = False
    if hardware.key_pressed(hardware.KEY_CODES["T"]):
        if M[pressingT]:
            pressing = M[pressingT]
        elif M[propellorStatus]:
            skip_store = True
        else:
            flight.set_engine(M[engineStatus] ^ 1)
            pressing = 1
    else:
        pressing = 0
    if not skip_store:
        M[pressingT] = pressing

    while True:
        if M[relatedPoints] < RELATED_POINTS_BUSY:
            for _ in range(3):
                visibility.process_lines_to_hide()
        if check_time_passed(hardware.clock()):
            break

    visibility.process_lines_to_show()
    canopy.draw_canopy_view()
    theme.set_random_number()

    timer = M[scoreDisplayTimer]
    if timer == SCORE_SHOWN_FOR:
        scoring.remove_score()
        M[scoreDisplayTimer] = 0
    elif timer or hardware.key_pressed(hardware.KEY_CODES["P"]):
        M[scoreDisplayTimer] = (timer - 1) & 0xFF
        scoring.display_score()

    while M[previousListEnd] != M[linesToHideEnd]:
        x = (M[previousListEnd] + 1) & 0xFF
        line = M[linesToHide + x]
        M[previousListEnd] = x
        M[pointStatus + M[lineStartPointId + line]] = 0
        M[pointStatus + M[lineEndPointId + line]] = 0


class Game:
    """The port running on its own: load, start, and step a main-loop
    iteration at a time. When a flight ends, the game waits, as the original
    does, for RETURN, and then starts a new one."""

    def __init__(self, start=True):
        wire_hooks()
        self.over = None
        if start:
            load_image()
            start_game()

    def iterate(self):
        """One main-loop iteration, or, while a flight is over, a check for
        RETURN. Returns the FlightOver that ended the flight, if one did."""
        if self.over is not None:
            if hardware.key_pressed(hardware.KEY_CODES["RETURN"]):
                self.over = None
                new_game()
            return None
        try:
            main_loop()
        except Crash as e:
            crash()
            self.over = e
        except TooLate as e:
            terminate_game()
            self.over = e
        except FlightOver as e:
            self.over = e
        return self.over
