"""Where the game makes sound.

The original asks the BBC's OS to play its sounds (OSWORD 7 and 8, through
MakeSound and friends); the Spectrum will make its own on the beeper. So the
port only says which sound it wants, by number as the original numbers them
(soundData), and whoever runs the port decides what that sounds like:
`hook` is called with the sound number, default doing nothing.

    2   an alien being destroyed
    3   a long, medium beep (points scored)
    5   a crash
    6   the guns firing
"""


def _silent(number):
    pass


hook = _silent


def make_sound(number):
    hook(number)
