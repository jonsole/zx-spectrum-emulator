"""The flight model: how the forces on the plane change its speed, its spin
and its place in the world, once each iteration of the main loop.

Two frames of reference are in play. The world's has y pointing up and z
pointing north along the runway; the plane's has z pointing out of the nose,
y up through the canopy and x out along the right wing. The plane's state is
kept mostly in the world's frame:

- xVelocity (Top Hi Lo) and its neighbours, the velocity, 24-bit signed;
- xPlane (Top Hi Lo Bot), the position, 32-bit, of which the bottom byte
  only collects the fractions of each step;
- xRotation (Hi Lo), the three rotation angles (pitch, yaw, roll), 16-bit,
  a full circle being 65536;
- xTurn (Top Hi Lo), the turn rates about the plane's own three axes, 24-bit.

Each iteration (ApplyFlightModel) works out the forces in the plane's frame,
where the aerodynamics are simple, and turns them back into the world's to
move the plane:

1. Gravity, (0, -512, 0) in the world, is rotated into the plane's frame by
   matrix 4 (pitch and roll only: yawing does not change which way is down).
   Only its y component is used, as a pitching moment: the nose-down pull
   of a plane balanced nose-heavy, strongest when it is level and gone when
   it is on its side. On the ground with the wheels down and the plane
   accelerating downwards, half that acceleration is taken off it, the
   undercarriage springs pushing back on the nose.
2. The velocity is rotated into the plane's frame by matrix 1, giving
   xVelocityP: zVelocityP is the airspeed over the wings, yVelocityP the air
   coming up from below (the angle of attack) and xVelocityP the sideslip.
3. ApplyAerodynamics turns those into lift and drag (each component of the
   airflow times the largest one -- the original's version of v squared --
   times the air density) and the moments that turn the plane: the tail and
   fin pushing the nose round into the airflow, damped by the turn rates the
   plane already has. It also decides whether the wing has stalled.
4. ApplyFlightControl turns the elevator, rudder and ailerons into moments,
   each proportional to the airflow (zLiftDrag), so the controls have no
   bite at low speed.
5. ScaleFlightForces multiplies each of the eleven forces by its constant
   from the forceFactor and scaleFactor tables: these are the aircraft's
   coefficients, and the configuration (flaps, undercarriage, engine, stall)
   is made by changing them.
6. Turbulence from an exploding alien kicks the controls at random.
7. ApplyTurnAndThrust adds up the moments into angular accelerations
   (dxTurn) and the forces, with the engine's thrust, into linear ones
   (xLinear).
8. On the ground, wheel friction, brakes and ground steering take over.
9. The linear acceleration goes back to the world's frame by matrix 2, the
   plane's weight (a constant 16 * 256 downwards) is taken off it, and it
   is added to the velocity, the angular acceleration to the turn rates; the
   turn rates,
   rotated by the roll angle (matrix 3), become rates of change of the three
   angles; and the velocity and those rates move and turn the plane.
10. ProcessLanding keeps the plane above the ground, and decides whether
    meeting it is a landing or a crash; then fuel is burned.

Airspeed in mph is zVelocityP * 100 / 2368, and yPlane is in feet.

Sounds go to sound.make_sound, by the original's sound numbers. The engine
sound's routines (ToggleEngineSound, MakeEngineSound, ResetEngineSound) are
here, since they keep the engine's pitch and roughness in the game's memory.
Redefining an envelope and drawing on the dashboard go through the hooks
below, which do nothing until the Spectrum's own code is plugged in (assign
to the module attribute, e.g. flight.draw_indicator = ...); everything those
routines change in the game's own state is done here. The User VIA timer,
which the original reads as a random number, is read through
hardware.via_timer_low. Where the original gives up on the flight and jumps
to Crash, the port raises events.Crash.
"""

from .events import Crash
from .hardware import via_timer_low
from .maths import add_scaled, multiply16x16, multiply8x16, negate16
from .memory import M, signed16, signed8, word
from .names import (brakesStatus, distanceFromHit, dxRotationHi, dxRotationLo, dxTurnHi, dxTurnLo,
                    dxTurnTop, dxVelocityHi, dxVelocityLo, dyVelocityHi, dyVelocityLo, dzTurnHi,
                    dzTurnLo, dzTurnTop, elevatorPosition, engineStatus, envelopeData, flapsStatus,
                    forceFactor, fuelLevel, fuelUsedHi, fuelUsedLo, hitTimer, keyLoggerHi,
                    keyLoggerLo, landingStatus, mainLoopCounter, matrixNumber, mult1, onGround,
                    pressingUFBS, propellorStatus, randomNumbers, reached512ft, rudderPosition,
                    scaleFactor, slipRate, soundData, themeStatus, thrustHi, thrustLo, ucStatus,
                    xControlsHi, xControlsLo, xControlsScHi, xControlsScLo, xControlsScTop,
                    xLiftDragHi, xLiftDragLo, xLiftDragScHi, xLiftDragScTop, xLinearHi, xLinearLo,
                    xMomentsHi, xMomentsLo, xMomentsScHi, xMomentsScLo, xMomentsScTop, xObjectHi,
                    xObjectLo, xPlaneBot, xPlaneHi, xPlaneLo, xPlaneTop, xRotationHi, xRotationLo,
                    xTemp3Hi, xTemp3Lo, xTurnHi, xTurnLo, xTurnTop, xVelocityHi, xVelocityLo,
                    xVelocityPHi, xVelocityPLo, xVelocityTop, yFlapsLiftHi, yFlapsLiftLo,
                    yFlapsLiftScHi, yFlapsLiftScTop, yGravityHi, yGravityLo, yLandingGear,
                    yLiftDragScHi, yLiftDragScTop, yLinearHi, yLinearLo, yPlaneHi, yPlaneLo,
                    yRotationHi, yTurnHi, yTurnTop, yVelocityHi, yVelocityTop, zLiftDragHi,
                    zLiftDragLo, zLiftDragScHi, zLiftDragScTop, zLinearHi, zLinearLo, zObjectHi,
                    zObjectLo, zPlaneHi, zPlaneLo, zRotationHi, zRotationLo, zSlipMomentHi,
                    zSlipMomentLo, zSlipMomentScHi, zSlipMomentScLo, zSlipMomentScTop, zTemp3Hi,
                    zTemp3Lo, zTurnHi, zTurnTop, zVelocityPHi, zVelocityPLo)
from .points import copy_point_to_work, copy_work_to_point, set_point_coords, set_point_to
from .sound import make_sound

# Crash (from events) is raised where the original jumps to Crash: the plane
# has hit the ground too hard. Everything the original had changed by then
# has been changed; the crash itself (the flash, the sound, waiting for
# RETURN and starting a new game) is the caller's to do.


# ---- hooks ----------------------------------------------------------------
#
# Each does nothing until the Spectrum's own code replaces it, by assigning
# to the module attribute. The flight model calls them through the module's
# globals, so a replacement takes effect at once.

def define_envelope(offset):
    """Redefine a sound envelope from envelopeData + offset (DefineEnvelope);
    the engine's choppiness lives in the first one."""


def draw_indicator(letter, lit):
    """Light or dim one of the dashboard's lettered indicators: "U"
    (undercarriage), "F" (flaps), "B" (brakes) or "T" (the Theme)."""


def show_upside_down_bar():
    """The artificial horizon's upside-down bar (ShowUpsideDownBar), drawn
    from zRotationHi. Note that CheckFlyingSkills reads the bar back from the
    screen to decide whether the plane is flying upside down, so the
    dashboard code that replaces this needs to keep what it drew."""


def draw_fuel_pixel(pixel, mode):
    """Draw (bit 7 of mode clear) or erase (set) one pixel of the fuel gauge
    (DrawFuelPixel); pixel is a fuel level, 0 to 65."""


# ---- the variable workspace -----------------------------------------------
#
# ResetVariable and AddScaled work on a 16-bit variable whose low byte is at
# xTurnHi + offset and high byte at xTurnTop + offset; these are the offsets
# the flight model uses. For the 24-bit turn rates, that is their top two
# bytes.

X_TURN = 0                               # xTurn (Top Hi)
Z_TURN = zTurnHi - xTurnHi               # zTurn (Top Hi)
DX_TURN = dxTurnHi - xTurnHi             # dxTurn (Top Hi)
DZ_TURN = dzTurnHi - xTurnHi             # dzTurn (Top Hi)
Y_VELOCITY = yVelocityHi - xTurnHi       # yVelocity (Top Hi)
X_CONTROLS_SC = xControlsScHi - xTurnHi  # xControlsSc (Top Hi), then y and z
X_ROTATION = xRotationLo - xTurnHi       # xRotation (Hi Lo)
Z_ROTATION = zRotationLo - xTurnHi       # zRotation (Hi Lo)
Y_PLANE = yPlaneLo - xTurnHi             # yPlane (Hi Lo)

# The working vectors in the point tables (see points.py).
LINEAR_POINT = 252           # xLinear: the linear acceleration
GRAVITY_POINT = 253          # xGravity
TURN_POINT = 254             # the turn rates, on their way to dxRotation
VELOCITY_POINT = 255         # the velocity, on its way to xVelocityP

# The matrices, as the offsets SetPointCoords takes.
MATRIX_1, MATRIX_2, MATRIX_3, MATRIX_4 = 0, 9, 18, 27

# Indexes into the eleven-force tables (xMoments ... zControls, forceFactor,
# scaleFactor and the scaled results), which share one layout: 8 and 9 are
# unused, and ScaleFlightForces skips them.
Y_LIFT_DRAG = 4
Z_LIFT_DRAG = 5
Y_FLAPS_LIFT = 7
FORCE_INDEXES = (12, 11, 10, 7, 6, 5, 4, 3, 2, 1, 0)

# The force factor for yLiftDrag, the wing's lift: a stalled wing gives a
# quarter of the lift.
LIFT_NORMAL = 156
LIFT_STALLED = 39

# Sounds from the soundData table.
SOUND_ENGINE_OFF = 0
SOUND_ENGINE_AMPLITUDE = 1
SOUND_STRAIN = 3
SOUND_STALL = 4
SOUND_ENGINE_PITCH = 7
SOUND_TOUCHDOWN = 26

# landingStatus while the plane is stopped or crawling on the ground.
LANDING_STOPPED = 0x40

# The engine's pitch is byte 5 of sound 7; 255 is its resting value.
ENGINE_PITCH = soundData + 7 * 8 + 4
ENGINE_PITCH_RESET = 255

FUEL_FULL = 65               # fuelLevel of a full tank
RUNWAY_OBJECT = 1            # object 1 is the runway; its anchor is its SW corner
RUNWAY_LENGTH_HI = 24        # the runway is 24 * 256 long and 256 wide


def _get24(lo, hi, top, i=0):
    return M[lo + i] | (M[hi + i] << 8) | (M[top + i] << 16)


def _set24(lo, hi, top, value, i=0):
    M[lo + i] = value & 0xFF
    M[hi + i] = (value >> 8) & 0xFF
    M[top + i] = (value >> 16) & 0xFF


def _set16(lo, hi, value, i=0):
    M[lo + i] = value & 0xFF
    M[hi + i] = (value >> 8) & 0xFF


def _sign_extend24(v16):
    return v16 | 0xFF0000 if v16 & 0x8000 else v16


def reset_variable(offset):
    """Zero the 16-bit variable at xTurnHi + offset and xTurnTop + offset
    (ResetVariable). For a 24-bit turn rate that leaves its low byte, which
    the callers zero themselves when it matters."""
    M[xTurnHi + offset] = 0
    M[xTurnTop + offset] = 0


def next_random_number():
    """Move the pointer at the start of the randomNumbers list on to the next
    of its eleven entries, wrapping round, and return it (NextRandomNumber).
    The entry itself is at randomNumbers + 1 + the pointer."""
    pointer = M[randomNumbers] + 1
    if pointer >= 11:
        pointer = 0
    M[randomNumbers] = pointer
    return pointer


# ---- ApplyFlightModel -----------------------------------------------------

def apply_flight_model():
    """One iteration of the flight model (ApplyFlightModel, parts 1 to 7).

    The value of onGround at the start is what every part goes by, even
    after ProcessLanding has changed onGround itself: the original copies it
    to L first and passes that on. Raises Crash if ProcessLanding decides the
    plane has crashed, in which case the upside-down bar and the fuel are
    left as they were."""
    on_ground = M[onGround]

    # Part 1: gravity, in the plane's frame, for the pitching moment it
    # makes. Normally (0, -512, 0) in the world. On the ground with the
    # undercarriage down and the plane accelerating downwards, the springs
    # in the legs take off half that acceleration (and one more).
    set_point_to(GRAVITY_POINT, 0)
    gravity_hi = 0xFE
    if on_ground and M[ucStatus] and M[dyVelocityHi] & 0x80:
        half = (word(dyVelocityLo, dyVelocityHi) >> 1) | 0x8000    # negative, so a 1 shifts in
        M[yGravityLo] = (half & 0xFF) ^ 0xFF
        gravity_hi = (254 - (half >> 8) - 1) & 0xFF                # -513 - dyVelocity / 2
    M[yGravityHi] = gravity_hi
    M[matrixNumber] = MATRIX_4
    set_point_coords(GRAVITY_POINT, MATRIX_4)

    # Part 2: the airflow over the plane, and the forces it makes.
    copy_work_to_point(xVelocityHi - xTurnHi, VELOCITY_POINT)
    M[matrixNumber] = MATRIX_1
    set_point_coords(VELOCITY_POINT, MATRIX_1)
    copy_point_to_work(VELOCITY_POINT, xVelocityPLo - xTurnHi)
    apply_aerodynamics(on_ground)
    apply_flight_control(on_ground)
    scale_flight_forces()

    # Part 3: turbulence near an exploding alien, as if someone were shaking
    # the stick: a kick to each control moment, bigger the closer the
    # explosion, in a direction from the random number list. The pointer
    # moves on even when the explosion turns out to be too far away to feel.
    if M[hitTimer]:
        for axis in range(3):
            pointer = next_random_number()
            random = M[randomNumbers + 1 + pointer]
            distance = M[distanceFromHit]
            if distance >= 16:
                break
            kick = (distance ^ 0x0F) << 1                 # 30 when close, 0 at 15
            add_scaled(kick, X_CONTROLS_SC + axis, 1, False, random & 1)

    # Part 4: add up the accelerations. The slip indicator shows the
    # sideways acceleration, rounded.
    apply_turn_and_thrust(on_ground)
    round_up = ((M[xLinearLo] ^ 0x80) >> 7) & 1
    M[slipRate] = (0 - M[xLinearHi] - (1 - round_up)) & 0xFF

    # Part 5: on the ground the wheels take over from the air.
    if on_ground:
        _apply_ground_forces()

    # Part 6: from accelerations to motion. The linear acceleration goes back
    # into the world's frame, the plane's weight is taken off, and the
    # results are integrated: acceleration into velocity and turn rate,
    # velocity into position, turn rate (turned by the roll angle into rates
    # of change of the three angles) into rotation.
    M[matrixNumber] = MATRIX_2
    set_point_coords(LINEAR_POINT, MATRIX_2)
    M[yLinearHi] = (M[yLinearHi] - 16) & 0xFF
    copy_point_to_work(LINEAR_POINT, dxVelocityLo - xTurnHi)
    adjust_velocity()
    adjust_turn()
    copy_work_to_point(X_TURN, TURN_POINT)
    M[matrixNumber] = MATRIX_3
    set_point_coords(TURN_POINT, MATRIX_3)
    copy_point_to_work(TURN_POINT, dxRotationLo - xTurnHi)
    adjust_rotation()
    toggle_engine_sound(7)
    process_landing(on_ground)
    show_upside_down_bar()

    # Part 7: burn fuel in proportion to the throttle. thrust / 16 (at most
    # 80) goes into a 16-bit tally whose high byte goes up in fours, so one
    # unit of fuelLevel lasts 16384 of them.
    if M[fuelLevel] == 0:
        set_engine(0)
        return
    if M[engineStatus] == 0:
        return
    used = (word(thrustLo, thrustHi) >> 4) & 0xFF
    total = used + M[fuelUsedLo]
    M[fuelUsedLo] = total & 0xFF
    if total < 0x100:
        return
    total = 4 + M[fuelUsedHi]
    M[fuelUsedHi] = total & 0xFF
    if total < 0x100:
        return
    if M[fuelLevel] == 0:
        set_engine(0)
        return
    M[fuelLevel] -= 1
    if M[fuelLevel] == 0:
        set_engine(0)


def _apply_ground_forces():
    """ApplyFlightModel part 5: what the ground does to a plane on it.

    The rudder steers the plane by braking one wheel or the other, which
    needs it to be rolling forwards at 20 or more; the ground stops it
    rolling about its long axis; with the undercarriage up, it stops the
    nose pitching down into the ground. Then friction: how hard the plane is
    slowed depends on what it is rolling on and how -- wheels on the runway
    with the brakes off roll freely, wheels on grass a little less freely,
    brakes or a belly much less so (more on grass than on the runway), and a
    plane rolling backwards is pushed forwards hard (taking 248 from
    zLinearHi adds 8 to it). A plane crawling at 10 or less is slowed by a
    constant amount, and one that is still is left still; either way
    landingStatus says the plane has stopped. Finally the wheels resist
    being dragged sideways."""
    # Ground steering: yTurn is set outright to four times the rudder.
    steering = 0
    forward_hi = M[zVelocityPHi]
    if not forward_hi & 0x80 and (forward_hi or M[zVelocityPLo] >= 20):
        steering = signed8(M[rudderPosition]) & 0xFFFF
    steering = (steering << 2) & 0xFFFF
    M[yTurnHi] = steering & 0xFF
    M[yTurnTop] = steering >> 8

    reset_variable(DZ_TURN)
    M[dzTurnLo] = 0

    # How much to take off zLinearHi; None means the plane rolls freely.
    if M[ucStatus] == 0:
        if M[xRotationHi] & M[dxTurnTop] & 0x80:
            # Nose down and pitching further down: the ground stops it.
            reset_variable(DX_TURN)
            M[dxTurnLo] = 0
        slowdown = 11 if check_plane_on_runway() else 50
    elif M[brakesStatus]:
        slowdown = 11 if check_plane_on_runway() else 50
    elif check_plane_on_runway():
        slowdown = None
    else:
        slowdown = 7

    status = 0
    if slowdown is not None:
        forward_hi = M[zVelocityPHi]
        if forward_hi & 0x80:
            M[zLinearHi] = (M[zLinearHi] - 248) & 0xFF
        elif forward_hi == 0 and M[zVelocityPLo] == 0:
            status = LANDING_STOPPED
        elif forward_hi == 0 and M[zVelocityPLo] < 11:
            M[zLinearLo] = 0x00
            M[zLinearHi] = 0xFF                       # zLinear = -256
            status = LANDING_STOPPED
        else:
            M[zLinearHi] = (M[zLinearHi] - slowdown) & 0xFF
    M[landingStatus] = status

    # Sideways friction: xLinear = -xVelocityPLo * 128, the sign taken from
    # the high byte but the magnitude from the low byte alone.
    low = M[xVelocityPLo]
    M[slipRate] = 0
    side = (((M[xVelocityPHi] & 0x80) | (low >> 1)) << 8) | ((low & 1) << 7)
    _set16(xLinearLo, xLinearHi, -side)


def adjust_turn():
    """Add the angular accelerations to the turn rates: xTurn += dxTurn and
    likewise for y and z, all 24-bit (AdjustTurn)."""
    for axis in (2, 1, 0):
        total = (_get24(xTurnLo, xTurnHi, xTurnTop, axis)
                 + _get24(dxTurnLo, dxTurnHi, dxTurnTop, axis))
        _set24(xTurnLo, xTurnHi, xTurnTop, total, axis)


def adjust_velocity():
    """Add twice the linear acceleration to the velocity: xVelocity (24-bit)
    += dxVelocity (16-bit, signed) * 2, and likewise for y and z
    (AdjustVelocity)."""
    for axis in (2, 1, 0):
        change = signed16(word(dxVelocityLo, dxVelocityHi, axis)) * 2
        total = _get24(xVelocityLo, xVelocityHi, xVelocityTop, axis) + change
        _set24(xVelocityLo, xVelocityHi, xVelocityTop, total, axis)


def adjust_rotation():
    """Move the plane by its velocity and turn it by its rates of rotation
    (AdjustRotation).

    The position is 32-bit, xPlane (Top Hi Lo Bot), and the top two bytes of
    the velocity are added to its bottom two, so the bottom byte keeps the
    fractions of a unit the plane moves each iteration. The angles are 16-bit
    and wrap round.

    If the pitch has gone past straight up or straight down (bits 6 and 7 of
    xRotationHi differ, so it is between 90 and 270 degrees), the plane is
    now upside down and facing back the way it came; the same attitude is
    described with the pitch reflected back to the forward half (128 - x)
    and yaw and roll each turned through 180 degrees, so the pitch angle
    always stays in the forward half."""
    for axis in (2, 1, 0):
        velocity = signed16(word(xVelocityHi, xVelocityTop, axis))
        position = (M[xPlaneBot + axis] | (M[xPlaneLo + axis] << 8) | (M[xPlaneHi + axis] << 16)
                    | (M[xPlaneTop + axis] << 24))
        position = (position + velocity) & 0xFFFFFFFF
        M[xPlaneBot + axis] = position & 0xFF
        M[xPlaneLo + axis] = (position >> 8) & 0xFF
        M[xPlaneHi + axis] = (position >> 16) & 0xFF
        M[xPlaneTop + axis] = position >> 24
        angle = word(xRotationLo, xRotationHi, axis) + word(dxRotationLo, dxRotationHi, axis)
        _set16(xRotationLo, xRotationHi, angle, axis)
    pitch_hi = M[xRotationHi]
    if (pitch_hi ^ (pitch_hi << 1)) & 0x80:
        for axis in (1, 0):
            M[yRotationHi + axis] ^= 0x80
        _set16(xRotationLo, xRotationHi, 0x8000 - word(xRotationLo, xRotationHi))


# ---- ApplyAerodynamics ----------------------------------------------------

def scale_by_altitude(yx):
    """(Y X) * ~yPlaneHi, as a 24-bit two's complement result (Y X V); the
    callers keep the top two bytes, so it is (Y X) * ~yPlaneHi / 256
    (ScaleByAltitude). (Y X) is taken as signed.

    This is the air density: 255 at sea level, falling by one for every 256
    feet of height, so the air thins steadily to nothing at 65,000 feet."""
    return multiply8x16(yx, M[yPlaneHi] ^ 0xFF)


def _multiply16x16_mix_full(ji, sr):
    """Multiply16x16Mix with its fraction byte: (H G W) = (J I) * (S R) >> 8,
    24-bit two's complement, where (J I) has its sign in bit 7 of J and
    (S R) in bit 0 of R. maths.multiply16x16_mix returns only (H G); the
    fraction W is the low byte of the sum Multiply16x16 builds, rounding
    included. A negative result is the 24-bit negation of the magnitude,
    which is what ApplyAerodynamics makes of the original's (H G) negation
    followed by its own negation of W with the borrow carried up."""
    negative = 0
    if ji & 0x8000:
        ji = (-ji) & 0xFFFF
        negative ^= 1
    if sr & 1:
        negative ^= 1
    h, g, c = multiply16x16(ji, sr)
    if c:
        h = (h + 1) & 0xFF
    j, i = ji >> 8, ji & 0xFF
    s, r = sr >> 8, sr & 0xFF
    w = (s * i + j * r + M[mult1 + 1]) & 0xFF
    magnitude = (h << 16) | (g << 8)
    if negative:
        # (H G) negated as 16 bits, then W negated with its borrow taken
        # from (H G).
        return ((((-(magnitude >> 8)) & 0xFFFF) << 8) - w) & 0xFFFFFF
    return magnitude | w


def apply_aerodynamics(on_ground):
    """The forces the air puts on the plane, from its velocity in its own
    frame (ApplyAerodynamics, parts 1 to 3).

    Lift and drag on a wing go with the square of the airspeed. The original
    gets something like it more cheaply: each component of the airflow,
    doubled, times the largest component (maxv), times the air density.
    That gives the side force (x), the wing's lift (y) and the drag (z) in
    xLiftDrag, and the moments in xMoments (see get_moments): the tail
    pitching the nose into the airflow and the fin yawing it into a
    sideslip, each damped by the turn rate, and the roll damped by the roll
    rate. Then zSlipMoment, which is the side force again (a slipping plane
    rolls away from the slip), and yFlapsLift, the extra lift of the flaps,
    which goes with the drag; the flaps also pitch the nose, down when they
    are out, and without them the drag pitches it up.

    It also decides whether the wing has stalled: when the air comes from
    below at more than a quarter of the airspeed (zVelocityP <= |yVelocityP|
    * 4), the airflow over the wing breaks away and it gives a quarter of
    its lift (the force factor drops from 156 to 39). The stall persists
    until the airspeed is back over 11 * 256 (about 119 mph) and the angle
    has eased. At the moment of stalling, one wing drops before the other,
    rolling the plane the way it is yawing, hardest when it is barely
    pitching; except within 20 feet of the ground. A plane on the ground
    cannot stall, and has no stall warning.

    on_ground is onGround as it was when the iteration began."""
    # Part 1: xLiftDrag = xVelocityP * 2 for now, (J I) = |yVelocityP| * 4,
    # and maxv, the largest of |xVelocityP|, |yVelocityP| and |zVelocityP|.
    maxv = 0
    vertical = 0
    for axis in (2, 1, 0):
        v = word(xVelocityPLo, xVelocityPHi, axis)
        _set16(xLiftDragLo, xLiftDragHi, v << 1, axis)
        magnitude = (-v) & 0xFFFF if v & 0x8000 else v
        if axis == 1:
            vertical = (magnitude << 2) & 0xFFFF
        if magnitude >= maxv:
            maxv = magnitude
    # (S R) for the multiplications below: maxv * 2 * air density / 256,
    # with bit 0 then cleared to make it a positive number with its sign in
    # bit 0, which is maxv * air density / 256.
    scale = (scale_by_altitude((maxv << 1) & 0xFFFF) >> 8) & 0xFFFF

    # Part 2: the stall.
    already = M[forceFactor + Y_LIFT_DRAG] == LIFT_STALLED
    if already and M[zVelocityPHi] < 11:
        stalling = True                           # still too slow to recover
    elif vertical < word(zVelocityPLo, zVelocityPHi):
        stalling = False
    else:
        stalling = True
        high_enough = M[yPlaneHi] != 0 or M[yPlaneLo] >= 20
        if high_enough and M[forceFactor + Y_LIFT_DRAG] != LIFT_STALLED:
            # A wing drops: zTurn +/- (A 0) >> 5, the sign from yTurn, where
            # A is xTurnTop with bits 0 to 5 flipped, and inverted if that is
            # negative (the N flag the original passes to AddScaled).
            pitch = M[xTurnTop] ^ 0x3F
            add_scaled(pitch, Z_TURN, 4, bool(pitch & 0x80), M[yTurnTop] >> 7)
    if stalling and not on_ground:
        make_sound(SOUND_STALL)
        M[forceFactor + Y_LIFT_DRAG] = LIFT_STALLED
    else:
        M[forceFactor + Y_LIFT_DRAG] = LIFT_NORMAL

    # Part 3: the moments (indexes 0-2, from the xTemp3 that get_moments
    # leaves) and the lift and drag (3-5, from part 1), each times maxv and
    # the air density. The multiplications here truncate rather than round:
    # the original switches Multiply16x16's rounding off by rewriting the
    # code at mult1, and back on afterwards.
    get_moments()
    sr = scale & 0xFFFE
    M[mult1 + 1] = 0
    for index in (5, 4, 3, 2, 1, 0):
        if index < 3:
            ji = word(xTemp3Lo, xTemp3Hi, index)
        else:
            ji = word(xMomentsLo, xMomentsHi, index)
        product = _multiply16x16_mix_full(ji, sr)
        shift = 3 if index in (3, 4) else 1       # the side force and lift get * 8
        _set16(xMomentsLo, xMomentsHi, (product << shift) >> 8, index)
    M[mult1 + 1] = 128

    M[zSlipMomentLo] = M[xLiftDragLo]
    M[zSlipMomentHi] = M[xLiftDragHi]
    if M[zLiftDragHi] & 0x80:
        return
    # Flying forwards: the flaps' lift goes with the drag, and the pitching
    # moment gets the drag * 8 with the flaps in, or -drag * 4 with them out.
    # The original means to shift (0 zLiftDragHi zLiftDragLo) and keep the
    # top two bytes, but it loads flapsStatus into A, where the low byte
    # was, before shifting: so the drag's low byte is lost and flapsStatus
    # is shifted in its place (making no difference while it is 0 or 1).
    M[yFlapsLiftHi] = M[zLiftDragHi]
    M[yFlapsLiftLo] = M[zLiftDragLo]
    flaps = M[flapsStatus]
    shifted = (M[zLiftDragHi] << 8) | flaps
    if flaps:
        pitching = negate16(((shifted << 2) >> 8) & 0xFFFF)
    else:
        pitching = ((shifted << 3) >> 8) & 0xFFFF
    _set16(xMomentsLo, xMomentsHi, word(xMomentsLo, xMomentsHi) + pitching)


def get_moments():
    """The turning moments before scaling, into xTemp3 (GetMoments):

        xTemp3 = yLiftDrag - xTurn * 250 / 256      pitch
        yTemp3 = xLiftDrag - yTurn * 250 / 256      yaw
        zTemp3 = -zTurn * 2                         roll

    where the lift-drag figures are still the velocities doubled. Air coming
    at the plane from below or from the side pushes on the tail or the fin
    and turns the nose into it, like a weathervane; the plane's own turning
    is resisted by the air, which damps it. Only the top two bytes of each
    turn rate take part."""
    for axis in (1, 0):
        rate = (word(xTurnHi, xTurnTop, axis) << 1) & 0xFFFF
        damping = (multiply8x16(rate, 125) >> 8) & 0xFFFF
        other = axis ^ 1
        _set16(xTemp3Lo, xTemp3Hi, word(xLiftDragLo, xLiftDragHi, other) - damping, axis)
    _set16(zTemp3Lo, zTemp3Hi, (-word(zTurnHi, zTurnTop)) << 1)


def apply_flight_control(on_ground):
    """The moments from the elevator, rudder and ailerons: each control's
    position times zLiftDrag, so a control surface's bite grows with the
    airflow over it (ApplyFlightControl).

    Before that, for the ailerons and the rudder: with no key pressed, a
    control within 3 of the centre snaps to it (a dead zone); with a key
    pressed against the way the control is deflected, it snaps to the centre
    at once ("instant centre", for keyboard flying), which for the rudder
    only happens on the ground, where it is the steering. The elevator gets
    neither: the original's loop skips back past those checks for it (the
    branch for an elevator key at fcon3 is never reached).

    on_ground is onGround as it was when the iteration began."""
    drag = word(zLiftDragLo, zLiftDragHi)
    for axis in (2, 1, 0):
        position = M[elevatorPosition + axis]
        if axis != 0 and position:
            if M[keyLoggerLo + axis] == 0:
                if position & 0x80:
                    if position >= 0xFD:
                        M[elevatorPosition + axis] = 0
                elif position < 4:
                    M[elevatorPosition + axis] = 0
            elif axis == 2 or on_ground:
                if (position ^ M[keyLoggerHi + axis]) & 0x80:
                    M[elevatorPosition + axis] = 0
        position = M[elevatorPosition + axis]
        magnitude = (-position) & 0xFF if position & 0x80 else position
        moment = (multiply8x16(drag, magnitude) >> 8) & 0xFFFF
        if position & 0x80:
            moment = negate16(moment)
        _set16(xControlsLo, xControlsHi, moment, axis)


def scale_flight_forces():
    """Multiply each of the eleven forces by its coefficients (ScaleFlightForces):

        scaled = force * forceFactor * 2 ^ scaleFactor

    into the 24-bit xMomentsSc and the rest. Shifting right is arithmetic.

    The wing's lift is also checked for strain: if the top byte of
    |yLiftDrag * forceFactor| is 8 or more (|yLiftDrag| of about 13 * 256 in
    normal flight, 52 * 256 stalled; a negative product's top byte is
    inverted rather than negated, which is near enough), the g-force is too
    much for the wings and a warning sounds. Nothing else comes of it."""
    for index in FORCE_INDEXES:
        product = multiply8x16(word(xMomentsLo, xMomentsHi, index), M[forceFactor + index])
        if index == Y_LIFT_DRAG:
            top = product >> 16
            if top & 0x80:
                top ^= 0xFF
            if top >= 8:
                make_sound(SOUND_STRAIN)
        shift = signed8(M[scaleFactor + index])
        if shift < 0:
            signed = product - 0x1000000 if product & 0x800000 else product
            product = (signed >> -shift) & 0xFFFFFF
        elif shift > 0:
            product = (product << shift) & 0xFFFFFF
        _set24(xMomentsScLo, xMomentsScHi, xMomentsScTop, product, index)


# ---- ApplyTurnAndThrust ---------------------------------------------------

def apply_turn_and_thrust(on_ground):
    """Add up the scaled forces into the plane's accelerations, in its own
    frame (ApplyTurnAndThrust, parts 1 and 2).

    The angular acceleration dxTurn is the moments plus the controls, plus
    gravity's pull along the plane's y-axis as a pitching moment (a plane
    nose-heavy by design pitches down as it slows), minus the slip moment in
    roll.

    The linear acceleration xLinear is the side force and the drag against
    the plane, and the lift (flaps included) up through it; and forwards,
    the engine's thrust. A propeller pushes less the faster it goes, so the
    thrust is reduced by airspeed / 16, and it is scaled by the air
    density. On the ground the thrust is doubled at high throttle (1024 or
    more, of 1280) and doubled again at airspeeds from 256 to 1023, which
    helps the plane up to flying speed. At 48 * 256 of airspeed (500 mph)
    and over, the plane is simply held back by a huge drag (zLinearHi is set
    to &EA, leaving the low byte as it was): its maximum speed. The flaps
    are retracted at about 150 mph.

    on_ground is onGround as it was when the iteration began."""
    # Part 1: the angular accelerations.
    for axis in (2, 1, 0):
        total = (_get24(xMomentsScLo, xMomentsScHi, xMomentsScTop, axis)
                 + _get24(xControlsScLo, xControlsScHi, xControlsScTop, axis))
        _set24(dxTurnLo, dxTurnHi, dxTurnTop, total, axis)
    gravity = _sign_extend24(word(yGravityLo, yGravityHi))
    _set24(dxTurnLo, dxTurnHi, dxTurnTop, _get24(dxTurnLo, dxTurnHi, dxTurnTop) + gravity)
    _set24(dzTurnLo, dzTurnHi, dzTurnTop, _get24(dzTurnLo, dzTurnHi, dzTurnTop)
           - _get24(zSlipMomentScLo, zSlipMomentScHi, zSlipMomentScTop))

    # Part 2: the linear accelerations, from the top two bytes of the scaled
    # forces.
    _set16(xLinearLo, xLinearHi, -word(xLiftDragScHi, xLiftDragScTop))
    _set16(yLinearLo, yLinearHi,
           word(yFlapsLiftScHi, yFlapsLiftScTop) - word(yLiftDragScHi, yLiftDragScTop))
    forward_hi = M[zVelocityPHi]
    if forward_hi & 0x80:
        forward_hi = 0
    else:
        retract_flaps_if_fast(forward_hi)
        if forward_hi >= 48:
            M[zLinearHi] = 0xEA
            return
    thrust = 0
    if M[engineStatus]:
        slowing = ((forward_hi << 8) | M[zVelocityPLo]) >> 4
        thrust = word(thrustLo, thrustHi)
        if on_ground:
            if M[thrustHi] >= 4:
                thrust = (thrust << 1) & 0xFFFF
            if 1 <= forward_hi < 4:
                thrust = (thrust << 1) & 0xFFFF
        thrust = (thrust - slowing) & 0xFFFF
        if thrust & 0x8000:
            thrust = 0
    thrust = (scale_by_altitude(thrust) >> 8) & 0xFFFF
    _set16(zLinearLo, zLinearHi, thrust - word(zLiftDragScHi, zLiftDragScTop))


def retract_flaps_if_fast(airspeed_hi):
    """Retract the flaps if the airspeed's high byte is 14 or more (about 150
    mph): flaps are for flying slowly (RetractFlapsIfFast)."""
    if airspeed_hi < 14 or M[flapsStatus] == 0:
        return
    M[flapsStatus] = 0
    indicator_f()


# ---- landing --------------------------------------------------------------

def check_plane_on_runway():
    """Whether the plane is over the runway: within 256 east of its anchor
    (the south-west corner) and between 0 and 24 * 256 north of it
    (CheckPlaneOnRunway, which returns this as the C flag clear). Only the
    low 16 bits of the coordinates take part."""
    east = (word(xPlaneLo, xPlaneHi) - word(xObjectLo, xObjectHi, RUNWAY_OBJECT)) & 0xFFFF
    if east >> 8:
        return False
    north = (word(zPlaneLo, zPlaneHi) - word(zObjectLo, zObjectHi, RUNWAY_OBJECT)) & 0xFFFF
    north_hi = north >> 8
    if north_hi & 0x80:
        return False
    return north_hi < RUNWAY_LENGTH_HI


def process_landing(on_ground):
    """Keep the plane out of the ground, and decide what touching it means
    (ProcessLanding, parts 1 to 7).

    Off the runway, the ground is rough: each iteration on it bumps the
    plane up and rolls it by random amounts that grow with the speed.

    Above yLandingGear (the height of the cockpit over the lowest part of
    the plane: 10 with the wheels down, 5 on its belly) the plane is flying,
    and onGround is cleared; once it climbs to 512 feet, reached512ft is
    set, which makes the next landing earn points.

    Taxiing (onGround at the start of the iteration), the plane sits at
    yLandingGear: it cannot sink and it cannot roll. On its wheels it rests
    nose-up at 7 * 256 (9.84 degrees), where the tail wheel meets the
    ground, and cannot pitch up past that; on its belly it cannot pitch down.

    Touching down (from the air), the plane is lifted back out of the ground
    by half the depth it reached, and its descent turned into a climb at the
    same rate: a bounce. Too fast a descent is a crash. In yVelocity's top
    two bytes, that is 512 or more always; 220 or more on the wheels; 160
    or more on the wheels off the runway; 320 or more on the belly. A belly
    landing breaks the propeller (propellorStatus) and stops the engine.
    Off the runway the low byte of the climb is set to half the speed: the
    bounce is halved below 256, but above it the top byte is left as it
    was (which only a belly landing can reach). Then the wing that touched
    first throws the plane into a roll the other way, harder the faster it
    came down, while the wings are set level (and, on the belly with the
    nose down, the fuselage flat). Once the plane is settled at yLandingGear
    and coming down at under 24, it has landed.

    on_ground is onGround as it was when the iteration began. Raises Crash
    where the original jumps to it."""
    # Part 1: a bumpy ride off the runway.
    if on_ground and not check_plane_on_runway():
        M[landingStatus] = (M[landingStatus] << 1) & 0xFF
        apply_bumpy_ride(Y_PLANE, 8, False)
        direction = via_timer_low() & 1
        apply_bumpy_ride(Z_ROTATION, 4, direction)

    # Part 2: still in the air?
    height_hi = M[yPlaneHi]
    if height_hi & 0x80:
        reset_variable(Y_PLANE)                   # nothing goes below the ground
    elif height_hi:
        if height_hi >= 2:
            M[reached512ft] = height_hi
        M[onGround] = 0
        return
    gear = M[yLandingGear]
    if gear < M[yPlaneLo]:
        M[onGround] = 0
        return

    if on_ground:
        # Part 3: taxiing.
        M[yPlaneLo] = gear
        if M[yVelocityTop] & 0x80:
            reset_variable(Y_VELOCITY)
        reset_variable(Z_ROTATION)
        reset_variable(Z_TURN)
        if M[ucStatus] == 0:
            # Part 4: on its belly, the nose cannot go down.
            if not M[landingStatus] & 0x80:
                M[landingStatus] = (M[landingStatus] << 1) & 0xFF
            if M[xRotationHi] & 0x80:
                reset_variable(X_ROTATION)
                reset_variable(X_TURN)
            return
        # Part 5: on its wheels, the nose cannot go up past the tail wheel.
        pitch_hi = M[xRotationHi]
        if pitch_hi & 0x80 or pitch_hi < 7:
            return
        M[xRotationHi] = 7
        M[xRotationLo] = 0
        if not M[xTurnTop] & 0x80:
            reset_variable(X_TURN)
        return

    # Part 6: touchdown. Lift the plane out of the ground by half the depth
    # it reached, and bounce the descent into a climb.
    M[yPlaneLo] = (((gear - M[yPlaneLo]) >> 1) + gear) & 0xFF
    top = M[yVelocityTop]
    if top & 0x80:
        speed = (-word(yVelocityHi, yVelocityTop)) & 0xFFFF
        M[yVelocityHi] = speed & 0xFF
        top = speed >> 8
        M[yVelocityTop] = top
    if top >> 1:
        raise Crash()                             # 512 or more
    half = ((top & 1) << 7) | (M[yVelocityHi] >> 1)
    if M[ucStatus] == 0:
        M[propellorStatus] = 0xFF                 # the propeller hits the ground
        if half < 160:
            set_engine(0)
        elif half >= 110:
            raise Crash()
    elif half >= 110:
        raise Crash()
    touchdown_sound = True
    if not check_plane_on_runway():
        M[yVelocityHi] = half
        if M[ucStatus]:
            if half >= 80:
                raise Crash()
            touchdown_sound = False
    if touchdown_sound:
        make_sound(SOUND_TOUCHDOWN)
        reset_engine_sound()

    # Part 7: the roll on touchdown, against the roll angle:
    # zTurn = -zRotation * half / 4 (arithmetic shifts), and level the wings.
    roll = negate16((multiply8x16(word(zRotationLo, zRotationHi), half) >> 8) & 0xFFFF)
    roll = (signed16(roll) >> 2) & 0xFFFF
    M[zTurnTop] = roll >> 8
    M[zTurnHi] = roll & 0xFF
    reset_variable(Z_ROTATION)
    if M[xRotationHi] & 0x80 and M[ucStatus] == 0:
        reset_variable(X_ROTATION)                # a belly flop
    if half >= 12 or M[yPlaneLo] != M[yLandingGear]:
        return
    M[onGround] = 1


def apply_bumpy_ride(offset, scale, subtract):
    """Add (A 0) >> (scale + 1) to the 16-bit variable at offset (see
    reset_variable), or take it away, where A is a random number from 0 up
    to zVelocityPHi: the timer ANDed with the airspeed's high byte
    (ApplyBumpyRide). Nothing happens, and the timer is not read, if the
    plane is going backwards."""
    forward_hi = M[zVelocityPHi]
    if forward_hi & 0x80:
        return
    add_scaled(forward_hi & via_timer_low(), offset, scale, False, subtract)


# ---- the engine and fuel --------------------------------------------------

def set_engine(status):
    """Switch the engine on (1) or off (0), if it isn't already, starting or
    stopping its sound (SetEngine). A stopped propeller is a brake: the
    drag's force factor goes up by 20 with the engine off."""
    if status == M[engineStatus]:
        return
    M[engineStatus] = status
    toggle_engine_sound(status)
    drag = M[forceFactor + Z_LIFT_DRAG]
    if M[engineStatus] == 0:
        drag = (drag + 20) & 0xFF
    # The original's branch past the subtraction is a BNE on the sum, so a
    # sum that wraps to 0 (from 236, which play never reaches) falls into
    # the engine-on case and is taken back down to 236.
    if M[engineStatus] or drag == 0:
        drag = (drag - 20) & 0xFF
    M[forceFactor + Z_LIFT_DRAG] = drag


def toggle_engine_sound(pitch):
    """Start or update the engine sound (pitch non-zero) or stop it
    (ToggleEngineSound). The pitch passed is not used: MakeEngineSound works
    its own out."""
    if pitch:
        make_engine_sound()
        return
    make_sound(SOUND_ENGINE_OFF)
    reset_engine_sound()


def reset_engine_sound():
    """Put the engine's pitch back to its resting value (ResetEngineSound),
    so that the next make_engine_sound redefines the sound."""
    M[ENGINE_PITCH] = ENGINE_PITCH_RESET


def make_engine_sound():
    """Set the engine sound from the throttle and the airspeed
    (MakeEngineSound): K = thrust / 16 + zVelocityPHi; the envelope's pitch
    wobble, 50 - K but at least 1, makes a slow, idling engine sound rough
    and a fast one smooth; and the pitch is K + 80. The envelope and the
    sound are only redefined when the pitch changes; the wobble is written
    into envelopeData every time."""
    if M[engineStatus] == 0:
        return
    k = (((word(thrustLo, thrustHi) >> 4) & 0xFF) + M[zVelocityPHi]) & 0xFF
    roughness = (50 - k) & 0xFF
    if roughness == 0 or roughness & 0x80:
        roughness = 1
    M[envelopeData + 2] = roughness
    M[envelopeData + 4] = roughness
    M[envelopeData + 3] = roughness ^ 0xFF
    pitch = (k + 80) & 0xFF
    if pitch == M[ENGINE_PITCH]:
        return
    M[ENGINE_PITCH] = pitch
    define_envelope(0)
    make_sound(SOUND_ENGINE_PITCH)
    make_sound(SOUND_ENGINE_AMPLITUDE)


def fill_up_fuel_tank():
    """Refuelling, called each iteration while the engine is off: every
    fourth iteration, add one unit of fuel and draw it on the gauge; once the
    tank is full (65), clear landingStatus, which ends the refuelling
    (FillUpFuelTank). The pixel drawn is the level before the unit was
    added."""
    if M[mainLoopCounter] & 3:
        return
    level = M[fuelLevel]
    if level >= FUEL_FULL:
        M[landingStatus] = 0
        return
    M[fuelLevel] = level + 1
    draw_fuel_pixel(level, 0)


# ---- the undercarriage, flaps and brakes, and their indicators ------------

def process_other_keys(pair):
    """Act on a press of a toggle key: pair 4 is "U" (undercarriage) or "B"
    (brakes), pair 5 "F" (flaps) or SHIFT (fire). The key logger's low byte
    for the pair says which key, as 4, 5, 7 or 8, and that indexes the
    status byte to flip from ucStatus - 4 and the held-down flag from
    pressingUFBS - 4. A key held down acts only once. Returns 1 for "U" or
    "F", 128 for "B" or SHIFT, 0 if nothing happened (ProcessOtherKeys).

    SHIFT flips the byte after brakesStatus, which nothing reads: the fire
    button's work is done by the caller."""
    key = M[keyLoggerLo + pair]
    if key == 0:
        M[pressingUFBS - 4 + pair] = 0
        M[pressingUFBS - 4 + 3 + pair] = 0
        return 0
    if M[pressingUFBS - 4 + key]:
        return 0
    M[ucStatus - 4 + key] ^= 1
    M[pressingUFBS - 4 + key] = 1
    return 128 if key >= 7 else 1


def indicator_u():
    """Follow a change of ucStatus (IndicatorU): lowering the undercarriage
    adds 10 to the drag's force factor and raising it takes 10 off, and the
    height of the cockpit over the lowest point of the plane (yLandingGear)
    becomes 10 on the wheels or 5 on the belly. It can be raised on the
    ground, but not lowered: ucStatus is put back to 0 and nothing else
    changes."""
    drag = M[forceFactor + Z_LIFT_DRAG]
    if M[ucStatus] == 0:
        drag -= 10
        gear = 5
        lit = False
    elif M[onGround]:
        M[ucStatus] = 0
        return
    else:
        drag += 10
        gear = 10
        lit = True
    M[forceFactor + Z_LIFT_DRAG] = drag & 0xFF
    M[yLandingGear] = gear
    draw_indicator("U", lit)


def indicator_f():
    """Follow a change of flapsStatus (IndicatorF): lowering the flaps adds
    200 to the drag's force factor and raising them takes 200 off; the
    flaps' lift gets a force factor of 152 when they are out, 0 when in."""
    drag = M[forceFactor + Z_LIFT_DRAG]
    if M[flapsStatus] == 0:
        drag -= 200
        lift = 0
        lit = False
    else:
        drag += 200
        lift = 152
        lit = True
    M[forceFactor + Z_LIFT_DRAG] = drag & 0xFF
    M[forceFactor + Y_FLAPS_LIFT] = lift
    draw_indicator("F", lit)


def indicator_b():
    """Show whether the brakes are on (IndicatorB)."""
    draw_indicator("B", M[brakesStatus] != 0)


def indicator_t():
    """Show whether the Theme is on: themeStatus is positive (IndicatorT)."""
    draw_indicator("T", not M[themeStatus] & 0x80)
