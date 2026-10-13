"""What the game reads from outside its memory, as replaceable sources.

The original reads the keyboard, the joystick and the clock through the
BBC's OS, and the User VIA's timer 1 low byte (SHEILA &64) as a random
number: when spawning an alien, for the randomNumbers list, for bumpy
landings and for turbulence. The port reads each through a function here,
and whoever runs the port decides where the values come from -- a test sets
them to what the original saw, and the Spectrum version will have its own
keys, Interface II and frame counter.

- `keys(code)`: whether a key is down. Codes are the BBC's, as the original
  passes them to OSBYTE 129 (INKEY with a negative number): the internal key
  number with every bit inverted, so L is &A9 and SHIFT &FF.
- `joystick(channel)`: the BBC analogue joystick's 16-bit ADC reading for
  channel 1 (x) or 2 (y), and channel 0's bit 0 for the fire button.
- `clock()`: the BBC's centisecond clock (OSWORD 1), of which the main loop
  only uses the low byte.
- `source()`: the VIA timer low byte, read through via_timer_low().

Replace them by assigning to this module's attributes (hardware.keys =
...), and read them through the module (hardware.joystick(1)) rather than
importing the function, or the replacement won't be seen.
"""


def _no_keys(code):
    return False


def _centred(channel):
    return 0x7FF0 if channel in (1, 2) else 0


def _stopped_clock():
    return 0


def _default():
    return 0xFF


keys = _no_keys
joystick = _centred
clock = _stopped_clock
source = _default

# The BBC key codes the game scans for (the bit-inverted internal key
# numbers), by the key's name.
KEY_CODES = {
    "L": 0xA9, "A": 0xBE, "S": 0xAE, "W": 0xDE, "U": 0xCA, "F": 0xBC,
    ",": 0x99, ";": 0xA8, "D": 0xCD, "E": 0xDD, "B": 0x9B, "SHIFT": 0xFF,
    "T": 0xDC, "P": 0xC8, "I": 0xDA, "TAB": 0x9F, "RETURN": 0xB6, "RIGHT": 0x86,
    "7": 0xDB, "8": 0xEA,
}


def key_pressed(code):
    return bool(keys(code))


def via_timer_low():
    """The User VIA timer 1 low byte, as the original reads it at &FE64."""
    return source() & 0xFF
