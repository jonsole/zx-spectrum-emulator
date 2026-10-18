"""Jetrun's game in Python: one pass exactly as the Z80 does it, for check.py
to compare with the built game step for step.

A pass, which the game starts on the frame interrupt (ADR 0003):

1. put back what lay under the astronaut's sprite;
2. save what lies under the sprite at its new place and draw it;
3. draw the landscape for the view: Cyberun's renderer, which the model
   does not imitate -- draw() is handed it, and check.py hands it the Z80's;
4. mend the sprite where the landscape drew over it (mend_sprite);
5. read the controls and move the astronaut (the physics below);
6. move the view to keep the astronaut at the centre.

Steps 1-4 draw what steps 5-6 of the pass before worked out; they come first,
and the sprite before the landscape, so the sprite is gone from the screen
only while the beam is still in the top border.

The physics works in 256ths of a pixel and probes the rock where the screen
shows it: rock is the checker, so a pair of pixels with either set is rock,
and black is sky. Inside the sprite's own box it reads what was saved from
under the sprite instead, so the astronaut never collides with itself.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import model as M    # noqa: E402
import sprites as S  # noqa: E402
import world as W    # noqa: E402

# Controls: one byte, a bit each, as read_controls makes it.
RIGHT, LEFT, DOWN, UP, FIRE = 1, 2, 4, 8, 16

GRAVITY = 0x0030        # a pass, per pass, in 256ths of a pixel
THRUST = 0x0070         # the jetpack's push up, the same units
ACCEL = 0x0030          # steering in the air
WALK = 0x0200           # walking speed: 2 pixels a pass, so the view scrolls
                        # its 2-pixel step every pass rather than every other
MAX_SPEED = 0x0200      # each way: the view can follow 2 pixels a pass

# The body inside the sprite's 16 x 24 box: what collides.
BODY_LEFT, BODY_RIGHT, BODY_TOP, BODY_BOTTOM = 3, 12, 1, 23

# Where the view keeps the sprite: its top-left in the play area, on
# character cells (screen 112, 88), so that it covers exactly 2 x 3 of them.
CENTRE_X, CENTRE_Y = 104, 64
# The view moves as Cyberun's renderer can: 2 pixels a pass across, 2 or 4
# up and down -- 4 only from a view_y that is a multiple of 4.
VIEW_STEP_Y = 4
# Nothing flies above this world row, so the view never goes above the world.
CEILING = CENTRE_Y + 2

ASTRONAUT_ATTR = 0x47   # bright white on black
WALK_RATE = 2           # passes per walking frame, as a shift: 4 passes
# How far walking climbs or steps down for one pixel across: Cyberun's ground
# is textured, and its caps dip at the joints.
CLIMB = 4               # and no more than this in all, in a pass


@dataclass
class Game:
    world: W.World
    screen: M.Screen = field(default_factory=M.Screen)
    attrs: bytearray = field(default_factory=lambda: bytearray(768))
    ax: int = 0          # the sprite's top-left, world x in 256ths, wrapping
    ay: int = 0
    vx: int = 0          # speed, 256ths of a pixel a pass, signed
    vy: int = 0
    on_ground: bool = True
    facing: int = 0      # 0 right, 1 left
    frame: int = 0
    passes: int = 0
    view_x: int = 0
    view_y: int = 0
    drawn_at: tuple = (0, 0)     # the sprite's screen x, y as drawn
    saved: bytearray = field(default_factory=lambda: bytearray(72))
    saved_attrs: bytearray = field(default_factory=lambda: bytearray(12))   # 3 x 4 cells

    # ---- life start ----------------------------------------------------------

    def start(self, landscape=None) -> None:
        """A new life. `landscape(game)` draws the play area for the view;
        without one, the model's full render."""
        start = self.world.start
        column, row = start["page"]
        px = column * W.PAGE_W + start["x"] - 8
        py = row * W.PAGE_H + start["y"] - S.HEIGHT
        self.ax, self.ay = (px << 8) | 0x80, (py << 8) | 0x80
        self.vx = self.vy = 0
        self.on_ground, self.facing, self.frame, self.passes = True, 0, 0, 0
        self.view_x = ((px & ~1) - CENTRE_X) % self.world.world_w
        self.view_y = (py & ~1) - CENTRE_Y
        if landscape is None:
            M.full_render(self.world, self.screen, self.view_x, self.view_y)
        else:
            landscape(self)
        self.place_sprite()

    # ---- drawing ---------------------------------------------------------------

    def sprite_screen(self) -> tuple[int, int]:
        px, py = self.ax >> 8, self.ay >> 8
        return ((px - self.view_x) % self.world.world_w & ~1) + M.PLAY_LEFT,             ((py - self.view_y) & ~1) + M.PLAY_TOP

    def restore_sprite(self) -> None:
        sx, sy = self.drawn_at
        for r in range(S.HEIGHT):
            for b in range(3):
                self.screen.pixels[M.screen_offset((sx >> 3) + b, sy + r)] = self.saved[r * 3 + b]
        for r in range(4):
            for c in range(3):
                self.attrs[((sy >> 3) + r) * 32 + (sx >> 3) + c] = self.saved_attrs[r * 3 + c]

    def place_sprite(self) -> None:
        sx, sy = self.sprite_screen()
        data = S.frame_bytes(self.frame, sx & 7)
        for r in range(S.HEIGHT):
            for b in range(3):
                at = M.screen_offset((sx >> 3) + b, sy + r)
                old = self.screen.pixels[at]
                self.saved[r * 3 + b] = old
                mask, ink = data[r * 6 + b * 2], data[r * 6 + b * 2 + 1]
                self.screen.pixels[at] = (old & mask) | ink
        self.drawn_at = (sx, sy)
        # Its cells: the 3 x 4 from its top-left kept, those it covers white.
        for r in range(4):
            for c in range(3):
                self.saved_attrs[r * 3 + c] = self.attrs[((sy >> 3) + r) * 32 + (sx >> 3) + c]
        for r in range(sy >> 3, ((sy + S.HEIGHT - 1) >> 3) + 1):
            for c in range(sx >> 3, ((sx + 15) >> 3) + 1):
                self.attrs[r * 32 + c] = ASTRONAUT_ATTR

    def mend_sprite(self) -> None:
        """The sprite again where the landscape drew over it: a byte that is
        not what place_sprite left is the landscape's, so it is what lies
        under the sprite now. Cells likewise, by the astronaut's colour."""
        sx, sy = self.drawn_at
        data = S.frame_bytes(self.frame, sx & 7)
        for r in range(S.HEIGHT):
            for b in range(3):
                at = M.screen_offset((sx >> 3) + b, sy + r)
                i = r * 3 + b
                mask, ink = data[r * 6 + b * 2], data[r * 6 + b * 2 + 1]
                now = self.screen.pixels[at]
                if now != (self.saved[i] & mask) | ink:
                    self.saved[i] = now
                    self.screen.pixels[at] = (now & mask) | ink
        rows = 3 if sy & 7 == 0 else 4
        columns = 2 if sx & 7 == 0 else 3
        for r in range(4):
            for c in range(3):
                at = ((sy >> 3) + r) * 32 + (sx >> 3) + c
                if self.attrs[at] != ASTRONAUT_ATTR:
                    self.saved_attrs[r * 3 + c] = self.attrs[at]
                if r < rows and c < columns:
                    self.attrs[at] = ASTRONAUT_ATTR

    # ---- probing the rock ------------------------------------------------------

    def rock(self, px: int, py: int) -> bool:
        """Whether world pixel (px, py) is rock, read from the screen."""
        if py < CEILING:
            return True          # nothing flies off the top of the world
        sx = (px - self.view_x) % self.world.world_w + M.PLAY_LEFT
        sy = py - self.view_y + M.PLAY_TOP
        dx_, dy_ = self.drawn_at
        column = sx >> 3
        if dx_ >> 3 <= column <= (dx_ >> 3) + 2 and dy_ <= sy < dy_ + S.HEIGHT:
            byte = self.saved[(sy - dy_) * 3 + column - (dx_ >> 3)]
        else:
            byte = self.screen.pixels[M.screen_offset(column, sy)]
        return byte & (0xC0 >> (sx & 6)) != 0

    def row_rock(self, py: int, px: int) -> bool:
        return any(self.rock(px + x, py) for x in range(BODY_LEFT, BODY_RIGHT + 1))

    def climb(self, lead: int, px: int, py: int) -> int:
        """How far up, 1 to CLIMB, the body can go and so step into the
        lead column; 0 if it cannot."""
        for up in range(1, CLIMB + 1):
            if self.row_rock(py + BODY_TOP - up, px):
                return 0        # no head room
            if not self.column_rock(lead, py - up, BODY_TOP, BODY_BOTTOM):
                return up
        return 0

    def drop(self, px: int, py: int) -> int:
        """How far down, 1 to CLIMB, there is rock to stand on; 0 if none."""
        for down in range(1, CLIMB + 1):
            if self.row_rock(py + BODY_BOTTOM + 1 + down, px):
                return down
        return 0

    def column_rock(self, px: int, py: int, top: int, bottom: int) -> bool:
        return any(self.rock(px, py + y) for y in range(top, bottom + 1))

    # ---- a pass ----------------------------------------------------------------

    def draw(self, landscape) -> None:
        """Steps 1-4; `landscape(game)` is step 3."""
        self.restore_sprite()
        self.place_sprite()
        landscape(self)
        self.mend_sprite()

    def move(self, keys: int) -> None:
        """Steps 5-6."""
        ww = self.world.world_w << 8
        thrust = bool(keys & UP)
        if thrust:
            self.vy -= THRUST
            self.on_ground = False
        self.vy += GRAVITY
        if self.on_ground:
            self.vx = WALK if keys & RIGHT else -WALK if keys & LEFT else 0
        else:
            if keys & RIGHT:
                self.vx += ACCEL
            elif keys & LEFT:
                self.vx -= ACCEL
            else:
                self.vx -= self.vx >> 4
        self.vx = max(-MAX_SPEED, min(MAX_SPEED, self.vx))
        self.vy = max(-MAX_SPEED, min(MAX_SPEED, self.vy))
        if keys & RIGHT:
            self.facing = 0
        elif keys & LEFT:
            self.facing = 1

        # Across, a pixel at a time.
        px, py = self.ax >> 8, self.ay >> 8
        target = self.ax + self.vx
        steps = (target >> 8) - px
        sign = 1 if steps > 0 else -1
        blocked = False
        climbed = 0
        for _ in range(abs(steps)):
            lead = px + (BODY_RIGHT + 1 if sign > 0 else BODY_LEFT - 1)
            if not self.column_rock(lead, py, BODY_TOP, BODY_BOTTOM):
                px += sign
            elif self.on_ground and 0 < self.climb(lead, px, py) <= CLIMB - climbed:
                up = self.climb(lead, px, py)    # walking up: a pixel across, up to CLIMB up
                climbed += up
                py -= up
                px += sign
            else:
                blocked = True
                break
        if blocked:
            self.vx = 0
            self.ax = ((px % self.world.world_w) << 8) | 0x80
        else:
            self.ax = target % ww
        self.ay = (py << 8) | (self.ay & 0xFF)

        # Down or up, a pixel at a time.
        target = self.ay + self.vy
        steps = (target >> 8) - py
        sign = 1 if steps > 0 else -1
        blocked = False
        for _ in range(abs(steps)):
            edge = py + (BODY_BOTTOM + 1 if sign > 0 else BODY_TOP - 1)
            if self.row_rock(edge, px):
                blocked = True
                break
            py += sign
        if blocked:
            self.vy = 0
            self.ay = (py << 8) | 0x80
            if sign > 0:
                self.on_ground = True
        else:
            self.ay = target

        # Standing: rock under the feet, or one pixel down for walking down
        # a slope; otherwise falling.
        py = self.ay >> 8
        if not thrust:
            if self.row_rock(py + BODY_BOTTOM + 1, px):
                self.on_ground = True
                self.vy = 0
            elif self.on_ground and self.drop(px, py):
                self.ay += self.drop(px, py) << 8     # walking down, up to CLIMB
                self.vy = 0
            else:
                self.on_ground = False

        walking = self.on_ground and keys & (LEFT | RIGHT)
        if not self.on_ground:
            pose = 3
        elif walking:
            pose = 1 + ((self.passes >> WALK_RATE) & 1)
        else:
            pose = 0
        self.frame = self.facing * 4 + pose

        # The view follows, keeping the sprite at the centre as far as
        # Cyberun's renderer can scroll in a pass.
        ww = self.world.world_w
        px, py = self.ax >> 8, self.ay >> 8
        dx = ((px & ~1) - CENTRE_X - self.view_x) % ww
        if dx >= ww // 2:
            dx -= ww
        dx = max(-W.MOVE, min(W.MOVE, dx))
        self.view_x = (self.view_x + dx) % ww
        dy = max(-VIEW_STEP_Y, min(VIEW_STEP_Y, (py & ~1) - CENTRE_Y - self.view_y))
        if abs(dy) == VIEW_STEP_Y and self.view_y & 2:
            dy //= 2
        self.view_y += dy
        self.passes = (self.passes + 1) & 0xFF

    def run(self, keys: int, landscape) -> None:
        self.draw(landscape)
        self.move(keys)
