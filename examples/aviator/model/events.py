"""The ways a flight ends, as exceptions, since the original leaves the
routine it is in -- often several calls deep, by adjusting the stack -- and
starts a new game.

- Crash: the plane hit something or landed badly (the original's Crash
  routine: a flash, a pause, the scores, and a new game).
- TooLate: an alien reached Acornsville ("TOO LATE!", then the same).
- Terminated: the player ended the flight with the right arrow key while on
  the ground.

Whatever runs the main loop catches them and starts a new game.
"""


class FlightOver(Exception):
    pass


class Crash(FlightOver):
    pass


class TooLate(FlightOver):
    pass


class Terminated(FlightOver):
    pass
