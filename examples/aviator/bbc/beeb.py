"""A BBC Micro Model B, as much of one as Aviator needs, around m6502.

Aviator talks to the machine through very little: OSBYTE for the keyboard,
the joystick and a couple of settings; OSWORD for the clock and sound; OSWRCH
for Mode 5, the palette, a few lines and some text; OSCLI to load the
dashboard; and the User VIA's timer 1 as a source of random numbers. Each is
stood in for here in Python, and nothing else of the OS or the hardware is
emulated -- no interrupts, no video timing, no sound chip.

Two things a real machine gets from the passage of time are made explicit,
so that runs can be repeated exactly:

- The clock (OSWORD 1), which the main loop reads to decide when it has spent
  9 centiseconds on hidden lines. clock="cycles" runs it from the CPU's own
  cycle count at 2 MHz, as the real machine would. clock="per-read" instead
  adds clock_step centiseconds each time it is read, so every iteration does
  the same work however long it takes -- what the port is compared with.
- The User VIA timer, read for random numbers. Its counter runs from the
  cycle count, which the port cannot reproduce; via_t1 can be set to a
  function returning the value to read instead.

The screen is plain memory at &5800-&7FFF, as on the real machine; render()
turns it into an image through the current palette.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import m6502  # noqa: E402
import acornsoft  # noqa: E402

OSWRCH = 0xFFEE
OSWORD = 0xFFF1
OSBYTE = 0xFFF4
OSCLI = 0xFFF7

SCREEN = 0x5800
CPU_HZ = 2_000_000

# Where call() makes a subroutine return to: in the OS ROM's page, which no
# game code runs, and above the hardware pages.
RETURN_TRAP = 0xFF00


class Snapshot:
    """Memory and registers at one moment, as call() and the recorders use."""
    __slots__ = ("mem", "a", "x", "y", "s", "pc", "p")

    def __init__(self, mem, a, x, y, s, pc, p):
        self.mem, self.a, self.x, self.y, self.s, self.pc, self.p = mem, a, x, y, s, pc, p

    @property
    def c(self):
        return self.p & 1

    def __getstate__(self):
        return (self.mem, self.a, self.x, self.y, self.s, self.pc, self.p)

    def __setstate__(self, state):
        self.mem, self.a, self.x, self.y, self.s, self.pc, self.p = state
CYCLES_PER_CS = CPU_HZ // 100

# The BBC's internal key numbers (the bit-inverted values are what INKEY
# with a negative number, and so OSBYTE 129, takes).
KEY_NUMBERS = {
    "SHIFT": 0x00, "CTRL": 0x01,
    "Q": 0x10, "3": 0x11, "4": 0x12, "5": 0x13, "f4": 0x14, "8": 0x15, "f7": 0x16, "-": 0x17,
    "^": 0x18, "LEFT": 0x19,
    "f0": 0x20, "W": 0x21, "E": 0x22, "T": 0x23, "7": 0x24, "I": 0x25, "9": 0x26, "0": 0x27,
    "_": 0x28, "DOWN": 0x29,
    "1": 0x30, "2": 0x31, "D": 0x32, "R": 0x33, "6": 0x34, "U": 0x35, "O": 0x36, "P": 0x37,
    "[": 0x38, "UP": 0x39,
    "CAPS": 0x40, "A": 0x41, "X": 0x42, "F": 0x43, "Y": 0x44, "J": 0x45, "K": 0x46, "@": 0x47,
    ":": 0x48, "RETURN": 0x49,
    "SHIFTLOCK": 0x50, "S": 0x51, "C": 0x52, "G": 0x53, "H": 0x54, "N": 0x55, "L": 0x56,
    ";": 0x57, "]": 0x58, "DELETE": 0x59,
    "TAB": 0x60, "Z": 0x61, "SPACE": 0x62, "V": 0x63, "B": 0x64, "M": 0x65, ",": 0x66,
    ".": 0x67, "/": 0x68, "COPY": 0x69,
    "ESCAPE": 0x70, "f1": 0x71, "f2": 0x72, "f3": 0x73, "f5": 0x74, "f6": 0x75, "f8": 0x76,
    "f9": 0x77, "\\": 0x78, "RIGHT": 0x79,
}

# The eight physical colours, as RGB.
PHYSICAL = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]

# How many parameter bytes follow each VDU code that takes any.
VDU_PARAMS = {1: 1, 17: 1, 18: 2, 19: 5, 22: 1, 23: 9, 24: 8, 25: 5, 28: 4, 29: 4, 31: 2}


class Beeb:
    def __init__(self, clock="per-read", clock_step=3, font=None):
        self.mem = bytearray(65536)
        self.cpu = m6502.CPU(self.mem, io_read=self.io_read, io_write=self.io_write)
        self.symbols = acornsoft.symbols()
        self.clock_mode = clock
        self.clock_step = clock_step
        self.centiseconds = 0
        self.via_t1 = None
        self.via_latch = 0
        self.via_started = None
        self.keys = set()
        self.joystick = (0x7FF0, 0x7FF0)
        self.joystick_fire = 0
        self.sounds = []
        self.envelopes = []
        self.vdu_queue = []
        self.vdu_needed = 0
        self.palette = [0, 1, 3, 7]      # Mode 5's default logical colours
        self.text_col = self.text_row = 0
        self.graphics = (0, 0)           # the graphics cursor, in VDU units
        self.font = font if font is not None else load_font()
        for addr, fn in ((OSWRCH, self.oswrch), (OSWORD, self.osword),
                         (OSBYTE, self.osbyte), (OSCLI, self.oscli)):
            self.mem[addr] = 0x60        # RTS, run after the trap
            self.cpu.traps[addr] = fn
        self.mem[acornsoft.AVIA_LOAD:acornsoft.AVIA_LOAD + 19785] = acornsoft.read("AVIA.bin")
        self.cpu.pc = acornsoft.AVIA_EXEC
        self.cpu.s = 0xFF

    # ---- running ------------------------------------------------------

    def label(self, name):
        return self.symbols[name]

    def run_to(self, name_or_addr, max_cycles=50_000_000):
        addr = name_or_addr if isinstance(name_or_addr, int) else self.label(name_or_addr)
        start = self.cpu.cycles
        self.cpu.run(until={addr}, max_cycles=max_cycles)
        if self.cpu.pc != addr:
            raise RuntimeError(f"did not reach &{addr:04X} in {self.cpu.cycles - start:,} cycles "
                               f"(pc &{self.cpu.pc:04X})")
        return self.cpu.cycles - start

    def boot(self):
        """Run from the entry point to the top of the first main loop."""
        return self.run_to("MainLoop")

    def call(self, name_or_addr, max_cycles=5_000_000):
        """Run one subroutine with the registers as they are, by pushing a
        return address that stops the run when the routine's RTS reaches it.
        Returns the cycles it took."""
        addr = name_or_addr if isinstance(name_or_addr, int) else self.label(name_or_addr)
        cpu = self.cpu
        ret = RETURN_TRAP - 1
        cpu.push(ret >> 8)
        cpu.push(ret & 0xFF)
        cpu.pc = addr
        start = cpu.cycles
        cpu.run(until={RETURN_TRAP}, max_cycles=max_cycles)
        if cpu.pc != RETURN_TRAP:
            raise RuntimeError(f"&{addr:04X} did not return in {max_cycles:,} cycles (pc &{cpu.pc:04X})")
        return cpu.cycles - start

    def snapshot(self):
        """The whole machine state that a routine can see, to restore later."""
        cpu = self.cpu
        return Snapshot(bytes(self.mem), cpu.a, cpu.x, cpu.y, cpu.s, cpu.pc, cpu.p())

    def restore(self, snap):
        cpu = self.cpu
        # A snapshot may hold only the memory below the OS (the recorders
        # keep &0000-&7FFF); the rest is left as it is.
        self.mem[:len(snap.mem)] = snap.mem
        cpu.a, cpu.x, cpu.y, cpu.s, cpu.pc = snap.a, snap.x, snap.y, snap.s, snap.pc
        cpu.set_p(snap.p)
        for addr in self.cpu.traps:      # the OS entry points must stay RTS
            if addr >= 0xFF00:
                self.mem[addr] = 0x60

    def iterate(self, keys=()):
        """Run one iteration of the main loop with the keys held, ending at the
        top of the next. Returns the cycles it took."""
        self.keys = set(keys)
        main = self.label("MainLoop")
        self.cpu.step()
        start = self.cpu.cycles
        self.cpu.run(until={main}, max_cycles=50_000_000)
        if self.cpu.pc != main:
            raise RuntimeError(f"main loop did not come round (pc &{self.cpu.pc:04X})")
        return self.cpu.cycles - start

    # ---- hardware -----------------------------------------------------

    def io_read(self, addr):
        if addr == 0xFE64:               # User VIA T1C-L
            if self.via_t1 is not None:
                return self.via_t1()
            if self.via_started is None:
                return 0xFF
            # Timer 1 counts down at 1 MHz and, in free-run mode, reloads
            # from the latch: one cycle of the timer is latch + 2 ticks.
            ticks = (self.cpu.cycles - self.via_started) // 2
            period = self.via_latch + 2
            return (self.via_latch - (ticks % period)) & 0xFF
        return 0xFF

    def io_write(self, addr, value):
        if addr == 0xFE64:               # T1L-L
            self.via_latch = (self.via_latch & 0xFF00) | value
        elif addr == 0xFE65:             # T1C-H: load the latch and start
            self.via_latch = (value << 8) | (self.via_latch & 0xFF)
            self.via_started = self.cpu.cycles

    # ---- the OS -------------------------------------------------------

    def now(self):
        if self.clock_mode == "cycles":
            return self.cpu.cycles // CYCLES_PER_CS
        return self.centiseconds

    def osbyte(self):
        cpu = self.cpu
        a, x, y = cpu.a, cpu.x, cpu.y
        if a == 129:
            if y == 0xFF and x == 0:
                cpu.x = cpu.y = 0xFF        # OS 1.x
            elif y == 0xFF:
                code = x ^ 0xFF          # INKEY(-n): the internal key number
                pressed = any(KEY_NUMBERS.get(k) == code for k in self.keys)
                cpu.x = cpu.y = 0xFF if pressed else 0
            else:
                # INKEY with a time limit: nothing is typed, so it times out.
                self.centiseconds += x | (y << 8)
                cpu.y = 0xFF
        elif a == 128:
            # ADC channels 1 and 2 are the joystick's axes; "channel 0"
            # returns the fire buttons in X.
            value = self.joystick[x - 1] if x in (1, 2) else self.joystick_fire
            cpu.x = value & 0xFF
            cpu.y = value >> 8
        # 140 (*TAPE) and 200 (ESCAPE and BREAK) change nothing that matters.

    def osword(self):
        cpu = self.cpu
        block = cpu.x | (cpu.y << 8)
        if cpu.a == 1:
            if self.clock_mode != "cycles":
                self.centiseconds += self.clock_step
            t = self.now()
            for i in range(5):
                self.mem[block + i] = (t >> (8 * i)) & 0xFF
        elif cpu.a == 7:
            self.sounds.append((self.cpu.cycles, bytes(self.mem[block:block + 8])))
        elif cpu.a == 8:
            self.envelopes.append(bytes(self.mem[block:block + 14]))

    def oscli(self):
        cpu = self.cpu
        addr = cpu.x | (cpu.y << 8)
        command = bytearray()
        while self.mem[addr] != 13:
            command.append(self.mem[addr])
            addr += 1
        words = command.decode("latin-1").split()
        if words[0].upper() in ("L.", "LOAD") or words[0].upper().startswith("L."):
            if words[0].upper().startswith("L.") and len(words[0]) > 2:
                words = ["L.", words[0][2:]] + words[1:]
            name, load = words[1], int(words[2], 16)
            data = acornsoft.read(name + ".bin")
            self.mem[load:load + len(data)] = data
        else:
            raise RuntimeError(f"unexpected OSCLI {command!r}")

    # ---- VDU ----------------------------------------------------------

    def oswrch(self):
        ch = self.cpu.a
        if self.vdu_needed:
            self.vdu_queue.append(ch)
            self.vdu_needed -= 1
            if self.vdu_needed == 0:
                self.vdu_command(self.vdu_queue)
            return
        if ch in VDU_PARAMS:
            self.vdu_queue = [ch]
            self.vdu_needed = VDU_PARAMS[ch]
            return
        if ch == 13:
            self.text_col = 0
        elif ch == 10:
            self.text_row = min(31, self.text_row + 1)
        elif ch == 12:
            self.mem[SCREEN:0x8000] = bytes(0x8000 - SCREEN)
            self.text_col = self.text_row = 0
        elif ch == 30:
            self.text_col = self.text_row = 0
        elif 32 <= ch < 127:
            self.print_char(ch)

    def vdu_command(self, q):
        code = q[0]
        if code == 22:
            self.mem[SCREEN:0x8000] = bytes(0x8000 - SCREEN)
            self.palette = [0, 1, 3, 7]
            self.text_col = self.text_row = 0
        elif code == 31:
            self.text_col, self.text_row = q[1], q[2]
        elif code == 19:
            self.palette[q[1] & 3] = q[2] & 7
        elif code == 25:
            k = q[1]
            x = q[2] | (q[3] << 8)
            y = q[4] | (q[5] << 8)
            x = x - 0x10000 if x & 0x8000 else x
            y = y - 0x10000 if y & 0x8000 else y
            if not k & 4:                # relative
                x += self.graphics[0]
                y += self.graphics[1]
            mode = k & 3
            if mode:
                colour = 3 if mode == 1 else None   # the default GCOL 0,3
                if k & 0xF8 == 64:
                    self.plot_point(x, y, colour, mode)
                elif k & 0xF8 == 0:
                    self.plot_line(self.graphics, (x, y), colour, mode)
            self.graphics = (x, y)
        # 23 (the cursor) and the rest need nothing here.

    def pixel(self, px, py, colour, mode=1):
        """Set a Mode 5 pixel: px 0-159 from the left, py 0-255 from the top."""
        if not (0 <= px < 160 and 0 <= py < 256):
            return
        addr = SCREEN + (py >> 3) * 320 + (px >> 2) * 8 + (py & 7)
        n = px & 3
        hi, lo = 0x80 >> n, 0x08 >> n
        b = self.mem[addr]
        if mode == 2:                    # invert
            b ^= hi | lo
        else:
            b &= ~(hi | lo) & 0xFF
            if colour & 2:
                b |= hi
            if colour & 1:
                b |= lo
        self.mem[addr] = b

    def plot_point(self, x, y, colour, mode):
        self.pixel(x >> 3, 255 - (y >> 2), colour or 0, mode)

    def plot_line(self, a, b, colour, mode):
        x0, y0 = a[0] >> 3, 255 - (a[1] >> 2)
        x1, y1 = b[0] >> 3, 255 - (b[1] >> 2)
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        while True:
            self.pixel(x0, y0, colour or 0, mode)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def print_char(self, ch):
        glyph = self.font[(ch - 32) * 8:(ch - 31) * 8] if self.font else bytes(8)
        for row in range(8):
            bits = glyph[row] if row < len(glyph) else 0
            for col in range(8):
                on = bits & (0x80 >> col)
                self.pixel(self.text_col * 8 + col, self.text_row * 8 + row, 3 if on else 0)
        self.text_col += 1
        if self.text_col >= 20:
            self.text_col = 0
            self.text_row = min(31, self.text_row + 1)

    # ---- the screen ---------------------------------------------------

    def logical_pixels(self):
        """The screen as 256 rows of 160 logical colours (0-3)."""
        rows = []
        mem = self.mem
        for py in range(256):
            base = SCREEN + (py >> 3) * 320 + (py & 7)
            row = []
            for cx in range(40):
                b = mem[base + cx * 8]
                for n in range(4):
                    row.append((((b >> (7 - n)) & 1) << 1) | ((b >> (3 - n)) & 1))
            rows.append(row)
        return rows

    def render(self, scale=2):
        """The screen as a PIL image as the palette shows it, each Mode 5
        pixel two wide so the shape is right, scaled up by scale."""
        from PIL import Image
        img = Image.new("RGB", (320, 256))
        colours = [PHYSICAL[p] for p in self.palette]
        put = img.putpixel
        for py, row in enumerate(self.logical_pixels()):
            for px, c in enumerate(row):
                rgb = colours[c]
                put((px * 2, py), rgb)
                put((px * 2 + 1, py), rgb)
        if scale != 1:
            img = img.resize((320 * scale, 256 * scale), Image.NEAREST)
        return img


def load_font():
    """A character set for the little text the game prints. The BBC's own is
    in Acorn's MOS ROM, which is not to hand; the Spectrum ROM's, if roms/
    has one, is close enough for a reference picture."""
    rom = HERE.parents[2] / "roms" / "48.rom"
    if rom.exists():
        return rom.read_bytes()[0x3D00:0x4000]
    return None
