# Cub

A flight simulator for the 128K Spectrum: the player flies a Piper Cub from an airfield over a small world of farms, a village and woods, drawn with the fast3d engine.

## Flying

**Cub**:
The player's aeroplane, a Piper J-3 Cub: a slow, light, high-winged taildragger.
_Avoid_: Plane, aircraft, player

**Flight**:
One go from the runway until a crash or the player's choice ends it; a flight can hold any number of landings and take-offs.
_Avoid_: Game, session, life

**Flight model**:
The rules that turn the controls, the throttle and the Cub's state into its next position, attitude and speed.
_Avoid_: Physics, simulation

**Step**:
One fiftieth of a second of the flight model; a frame runs as many steps as have passed since the last one.
_Avoid_: Tick, update

**Stall**:
The wing losing its lift because its angle to the oncoming air is too steep, so the nose drops.

**Touchdown**:
The moment a wheel first meets the ground, before it is judged a landing or a crash.
_Avoid_: Contact, impact

**Landing**:
A touchdown gentle enough, level enough and on flat enough ground that the Cub rolls on unharmed; the flight goes on.
_Avoid_: Arrival

**Crash**:
A touchdown that is too hard or too banked, or the Cub striking a tree or a building; it ends the flight.
_Avoid_: Death, collision

## Seeing

**Cockpit view**:
The world as the pilot sees it from the Cub's seat, with nothing of the Cub itself drawn.
_Avoid_: First-person view, inside view, pilot view

**Chase view**:
The Cub seen from a fixed distance behind and above it, following its heading and pitch but not its bank.
_Avoid_: Outside view, external view, third-person view

**Panel**:
The instruments below the view: airspeed, altitude and heading as numbers, throttle and climb as bars, and a stall light.
_Avoid_: Dashboard, HUD, instruments

**Horizon line**:
The line where the ground meets the sky, always drawn so the pilot can judge the Cub's attitude.

**Frame**:
One pass of the game loop, drawing one picture of the view; speed is counted in frames a second.
_Avoid_: Picture, turn, iteration

## The world

**World**:
Everything the Cub can fly over, about twelve miles square, wrapping at its edges so that flying off one side brings the Cub back from the other.
_Avoid_: Map, area, level

**Airfield**:
The place every flight starts: the runway, a hangar and a windsock.
_Avoid_: Airport, aerodrome, base

**Ground feature**:
A flat line on the ground, such as a field edge, a road or a river, there to show the pilot height and speed near the ground.
_Avoid_: Texture, marking
