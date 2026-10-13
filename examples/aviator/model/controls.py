"""The controls: the key logger, and turning key presses into stick, rudder
and throttle positions (UpdateFlightModel parts 1 to 3).

The key logger (see "the key logger" deep dive) has six entries, one for
each pair of keys: elevator (L dives, "," climbs), rudder (A left, ";"
right), ailerons (S left, D right), throttle (W less, E more), undercarriage
or brakes (U, B), flaps or fire (F, SHIFT). Each entry is a 16-bit value
from the key tables for whichever key of the pair is down (the first key
wins if both are), or 0.

The axis controls move one step a press, and four once a key has been held
for six iterations; the stick and rudder stay where they are left, like
trim. The throttle moves 15 a press up to 1,280. The other four toggle once
a press.
"""

from . import hardware
from .hardware import KEY_CODES, key_pressed
from .memory import M
from .names import (axisChangeRate, axisKeyUsage, elevatorPosition, keyLoggerHi, keyLoggerLo,
                    keyTable1, keyTable1Hi, keyTable1Lo, keyTable2, keyTable2Hi, keyTable2Lo,
                    aileronPosition, pressingTab, row29_char20_4,
                    soundData, thrustHi, thrustLo)

KEY_PAIRS = 6
AXES = 3                     # elevator, rudder, aileron: the first three pairs
THROTTLE = 3
HELD_FOR = 6                 # iterations before an axis key moves at full rate
FULL_RATE_EXTRA = 3          # added to the step once it has been held that long
AXIS_MIN = 140               # -116
AXIS_MAX = 118
THRUST_MAX_HI = 5            # thrust saturates at (5 0) = 1,280
FIRE_BUTTON = 8              # the key logger value for fire (keyTable2Lo+5)


def update_key_logger():
    for i in range(KEY_PAIRS - 1, -1, -1):
        if key_pressed(M[keyTable1 + i]):
            lo, hi = M[keyTable1Lo + i], M[keyTable1Hi + i]
        elif key_pressed(M[keyTable2 + i]):
            lo, hi = M[keyTable2Lo + i], M[keyTable2Hi + i]
        else:
            lo = hi = 0
        M[keyLoggerHi + i] = hi
        M[keyLoggerLo + i] = lo


def move_axes():
    """UpdateFlightModel part 1: the elevator, rudder and ailerons.

    While a key is held, axisKeyUsage counts the presses and axisChangeRate
    counts down from 6; when it reaches 0 the step grows from 1 to 4. The
    position is limited to -116 to +118."""
    for x in range(AXES - 1, -1, -1):
        lo = M[keyLoggerLo + x]
        if not lo:
            M[axisChangeRate + x] = HELD_FOR
            continue
        M[axisKeyUsage + x] = (M[axisKeyUsage + x] + lo) & 0xFF
        carry = 1 if M[axisKeyUsage + x] < lo else 0
        direction = M[keyLoggerHi + x]
        total = direction + M[elevatorPosition + x] + carry
        a = total & 0xFF
        carry = total >> 8
        if M[axisChangeRate + x]:
            M[axisChangeRate + x] -= 1
        if not M[axisChangeRate + x]:
            # Held long enough: three more, or (going down) three more less 6.
            total = a + FULL_RATE_EXTRA
            a = total & 0xFF
            carry = total >> 8
            if direction & 0x80:
                total = a + 250 + carry
                a = total & 0xFF
        if a & 0x80:
            if a < AXIS_MIN:
                a = AXIS_MIN
        elif a >= AXIS_MAX + 1:
            a = AXIS_MAX
        M[elevatorPosition + x] = a


def read_joystick():
    """With the joystick switched on (the indicator pixel above the rudder,
    which is the setting), the stick sets the elevator and ailerons directly
    and its button fires."""
    if not M[row29_char20_4]:
        return
    M[aileronPosition] = _adc(1)
    M[elevatorPosition] = _adc(2)
    if hardware.joystick(0) & 1:
        M[keyLoggerLo + 5] = FIRE_BUTTON


def _adc(channel):
    """ReadADCChannel: the high byte of the reading, clipped to 12-246 and
    taken from 128 the other way round, so -118 to +116."""
    a = (hardware.joystick(channel) >> 8) & 0xFF
    if a >= 247:
        a = 246
    if a < 12:
        a = 12
    return (-(a - 128)) & 0xFF


def move_throttle():
    """UpdateFlightModel part 2: the throttle, from 0 to 1,280. Returns
    whether it moved, as the original then updates the thrust indicator."""
    lo = M[keyLoggerLo + THROTTLE]
    if not lo:
        return False
    total = lo + M[thrustLo]
    x = total & 0xFF
    y = (M[keyLoggerHi + THROTTLE] + M[thrustHi] + (total >> 8)) & 0xFF
    if y & 0x80:
        x = y = 0
    elif y >= THRUST_MAX_HI:
        x, y = 0, THRUST_MAX_HI
    M[thrustLo] = x
    M[thrustHi] = y
    return True


def process_volume_keys():
    """7 makes the sounds quieter and 8 louder, by changing the amplitude in
    the original's sound 1 block, between 0 and -15; each change also nudges
    a byte of the engine sound's block, as the original does."""
    if key_pressed(KEY_CODES["7"]):
        step = 1
    elif key_pressed(KEY_CODES["8"]):
        step = 0xFF
    else:
        return
    a = (step + M[soundData + 10]) & 0xFF
    # Only -1 to -15 are kept: the original's checks also turn away 0, so
    # the quietest setting is -1.
    if not (a & 0x80 and a >= 241):
        return
    M[soundData + 10] = a
    M[soundData + 60] = (M[soundData + 60] + 1) & 0xFF


def toggle_joystick():
    """TAB switches the joystick on and off, once a press; the setting is the
    indicator pixel itself."""
    if not key_pressed(KEY_CODES["TAB"]):
        M[pressingTab] = 0
        return
    if M[pressingTab]:
        return
    M[row29_char20_4] ^= 0x88
    M[pressingTab] = 0x80
