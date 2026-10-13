"""An NMOS 6502 interpreter: enough of one to run BBC Micro Aviator as a
reference for the port.

It runs the documented instruction set, with decimal mode (Aviator keeps its
scores in BCD), the JMP (indirect) page-wrap bug, and the usual cycle counts
including the extra cycle for crossing a page and for a taken branch. The
undocumented opcodes raise, since Aviator does not use them and meeting one
means the program has gone astray.

Two hooks connect it to a machine:

- io_read / io_write are called for addresses from io_base to io_top - 1
  (the BBC's memory-mapped hardware at &FC00-&FEFF); everything else is
  plain RAM in mem.
- traps maps an address to a function called just before the instruction
  there runs. The BBC machine puts an RTS at each OS entry point and traps it,
  so a JSR OSBYTE runs the Python stand-in and then returns.

Checked against Klaus Dormann's 6502 functional test (tests/test_m6502.py).
"""


class Unimplemented(Exception):
    pass


# Flag bits in the status register.
C_FLAG = 0x01
Z_FLAG = 0x02
I_FLAG = 0x04
D_FLAG = 0x08
B_FLAG = 0x10
U_FLAG = 0x20
V_FLAG = 0x40
N_FLAG = 0x80


class CPU:
    def __init__(self, mem, io_read=None, io_write=None, io_base=0xFC00, io_top=0xFF00):
        self.mem = mem
        self.io_read = io_read
        self.io_write = io_write
        self.io_base = io_base
        self.io_top = io_top
        self.traps = {}
        self.a = self.x = self.y = 0
        self.s = 0xFF
        self.pc = 0
        # The flags are kept apart; p() and set_p() pack and unpack them.
        self.n = self.v = self.d = self.c = 0
        self.i = 1
        self.z = 0
        self.cycles = 0
        self._build_table()

    # ---- memory -------------------------------------------------------

    def read(self, addr):
        if self.io_base <= addr < self.io_top and self.io_read is not None:
            return self.io_read(addr) & 0xFF
        return self.mem[addr]

    def write(self, addr, value):
        if addr >= self.io_base:
            if addr < self.io_top and self.io_write is not None:
                self.io_write(addr, value & 0xFF)
            # Everything from io_base up is hardware or ROM: a write there
            # never changes what is read back from RAM.
            return
        self.mem[addr] = value & 0xFF

    def read16(self, addr):
        return self.read(addr) | (self.read((addr + 1) & 0xFFFF) << 8)

    def push(self, value):
        self.mem[0x100 + self.s] = value & 0xFF
        self.s = (self.s - 1) & 0xFF

    def pull(self):
        self.s = (self.s + 1) & 0xFF
        return self.mem[0x100 + self.s]

    # ---- status register ----------------------------------------------

    def p(self):
        return ((N_FLAG if self.n else 0) | (V_FLAG if self.v else 0) | U_FLAG | B_FLAG
                | (D_FLAG if self.d else 0) | (I_FLAG if self.i else 0)
                | (Z_FLAG if self.z else 0) | (C_FLAG if self.c else 0))

    def set_p(self, value):
        self.n = 1 if value & N_FLAG else 0
        self.v = 1 if value & V_FLAG else 0
        self.d = 1 if value & D_FLAG else 0
        self.i = 1 if value & I_FLAG else 0
        self.z = 1 if value & Z_FLAG else 0
        self.c = 1 if value & C_FLAG else 0

    def nz(self, value):
        self.n = 1 if value & 0x80 else 0
        self.z = 1 if value == 0 else 0
        return value

    # ---- addressing modes ---------------------------------------------
    # Each returns the effective address and advances pc past the operand.
    # Those that can cross a page add the extra cycle themselves, but only
    # for instructions that read: stores and read-modify-writes always take
    # the longer time, which their base cycle count already includes.

    def am_imm(self, extra):
        addr = self.pc
        self.pc = (self.pc + 1) & 0xFFFF
        return addr

    def am_zp(self, extra):
        addr = self.mem[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        return addr

    def am_zpx(self, extra):
        addr = (self.mem[self.pc] + self.x) & 0xFF
        self.pc = (self.pc + 1) & 0xFFFF
        return addr

    def am_zpy(self, extra):
        addr = (self.mem[self.pc] + self.y) & 0xFF
        self.pc = (self.pc + 1) & 0xFFFF
        return addr

    def am_abs(self, extra):
        addr = self.mem[self.pc] | (self.mem[(self.pc + 1) & 0xFFFF] << 8)
        self.pc = (self.pc + 2) & 0xFFFF
        return addr

    def am_absx(self, extra):
        base = self.mem[self.pc] | (self.mem[(self.pc + 1) & 0xFFFF] << 8)
        self.pc = (self.pc + 2) & 0xFFFF
        addr = (base + self.x) & 0xFFFF
        if extra and (base ^ addr) & 0xFF00:
            self.cycles += 1
        return addr

    def am_absy(self, extra):
        base = self.mem[self.pc] | (self.mem[(self.pc + 1) & 0xFFFF] << 8)
        self.pc = (self.pc + 2) & 0xFFFF
        addr = (base + self.y) & 0xFFFF
        if extra and (base ^ addr) & 0xFF00:
            self.cycles += 1
        return addr

    def am_indx(self, extra):
        zp = (self.mem[self.pc] + self.x) & 0xFF
        self.pc = (self.pc + 1) & 0xFFFF
        return self.mem[zp] | (self.mem[(zp + 1) & 0xFF] << 8)

    def am_indy(self, extra):
        zp = self.mem[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        base = self.mem[zp] | (self.mem[(zp + 1) & 0xFF] << 8)
        addr = (base + self.y) & 0xFFFF
        if extra and (base ^ addr) & 0xFF00:
            self.cycles += 1
        return addr

    def am_ind(self, extra):
        # JMP (indirect): the high byte comes from the same page as the low
        # byte, so JMP (&10FF) reads &10FF and &1000.
        ptr = self.mem[self.pc] | (self.mem[(self.pc + 1) & 0xFFFF] << 8)
        self.pc = (self.pc + 2) & 0xFFFF
        hi = (ptr & 0xFF00) | ((ptr + 1) & 0xFF)
        return self.read(ptr) | (self.read(hi) << 8)

    def am_rel(self, extra):
        offset = self.mem[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        if offset & 0x80:
            offset -= 0x100
        return (self.pc + offset) & 0xFFFF

    def am_none(self, extra):
        return None

    # ---- operations ---------------------------------------------------

    def op_lda(self, addr):
        self.a = self.nz(self.read(addr))

    def op_ldx(self, addr):
        self.x = self.nz(self.read(addr))

    def op_ldy(self, addr):
        self.y = self.nz(self.read(addr))

    def op_sta(self, addr):
        self.write(addr, self.a)

    def op_stx(self, addr):
        self.write(addr, self.x)

    def op_sty(self, addr):
        self.write(addr, self.y)

    def _adc(self, m):
        a = self.a
        c = self.c
        if not self.d:
            t = a + m + c
            self.v = 1 if (~(a ^ m) & (a ^ t) & 0x80) else 0
            self.c = 1 if t > 0xFF else 0
            self.a = self.nz(t & 0xFF)
            return
        # NMOS decimal mode: Z comes from the binary sum, N and V from the
        # high digit before it is adjusted, C from the adjusted result.
        binary = (a + m + c) & 0xFF
        lo = (a & 0x0F) + (m & 0x0F) + c
        hi = (a & 0xF0) + (m & 0xF0)
        if lo > 0x09:
            lo += 0x06
        if lo > 0x0F:
            hi += 0x10
        self.z = 1 if binary == 0 else 0
        self.n = 1 if hi & 0x80 else 0
        self.v = 1 if (~(a ^ m) & (a ^ hi) & 0x80) else 0
        if hi > 0x90:
            hi += 0x60
        self.c = 1 if hi > 0xFF else 0
        self.a = (hi & 0xF0) | (lo & 0x0F)

    def _sbc(self, m):
        a = self.a
        borrow = 1 - self.c
        t = a - m - borrow
        # The flags are the binary subtraction's in both modes on the NMOS
        # part; only the accumulator is adjusted in decimal mode.
        self.v = 1 if ((a ^ m) & (a ^ t) & 0x80) else 0
        self.c = 1 if t >= 0 else 0
        self.nz(t & 0xFF)
        if not self.d:
            self.a = t & 0xFF
            return
        lo = (a & 0x0F) - (m & 0x0F) - borrow
        hi = (a >> 4) - (m >> 4)
        if lo < 0:
            lo -= 6
            hi -= 1
        if hi < 0:
            hi -= 6
        self.a = ((hi << 4) | (lo & 0x0F)) & 0xFF

    def op_adc(self, addr):
        self._adc(self.read(addr))

    def op_sbc(self, addr):
        self._sbc(self.read(addr))

    def op_and(self, addr):
        self.a = self.nz(self.a & self.read(addr))

    def op_ora(self, addr):
        self.a = self.nz(self.a | self.read(addr))

    def op_eor(self, addr):
        self.a = self.nz(self.a ^ self.read(addr))

    def _compare(self, reg, m):
        t = reg - m
        self.c = 1 if t >= 0 else 0
        self.nz(t & 0xFF)

    def op_cmp(self, addr):
        self._compare(self.a, self.read(addr))

    def op_cpx(self, addr):
        self._compare(self.x, self.read(addr))

    def op_cpy(self, addr):
        self._compare(self.y, self.read(addr))

    def op_bit(self, addr):
        m = self.read(addr)
        self.n = 1 if m & 0x80 else 0
        self.v = 1 if m & 0x40 else 0
        self.z = 1 if (self.a & m) == 0 else 0

    # Read-modify-write: addr None means the accumulator.

    def _rmw(self, addr, fn):
        if addr is None:
            self.a = self.nz(fn(self.a))
        else:
            self.write(addr, self.nz(fn(self.read(addr))))

    def op_asl(self, addr):
        def f(m):
            self.c = m >> 7
            return (m << 1) & 0xFF
        self._rmw(addr, f)

    def op_lsr(self, addr):
        def f(m):
            self.c = m & 1
            return m >> 1
        self._rmw(addr, f)

    def op_rol(self, addr):
        def f(m):
            c = self.c
            self.c = m >> 7
            return ((m << 1) | c) & 0xFF
        self._rmw(addr, f)

    def op_ror(self, addr):
        def f(m):
            c = self.c
            self.c = m & 1
            return (m >> 1) | (c << 7)
        self._rmw(addr, f)

    def op_inc(self, addr):
        self.write(addr, self.nz((self.read(addr) + 1) & 0xFF))

    def op_dec(self, addr):
        self.write(addr, self.nz((self.read(addr) - 1) & 0xFF))

    def op_inx(self, addr):
        self.x = self.nz((self.x + 1) & 0xFF)

    def op_iny(self, addr):
        self.y = self.nz((self.y + 1) & 0xFF)

    def op_dex(self, addr):
        self.x = self.nz((self.x - 1) & 0xFF)

    def op_dey(self, addr):
        self.y = self.nz((self.y - 1) & 0xFF)

    def op_tax(self, addr):
        self.x = self.nz(self.a)

    def op_tay(self, addr):
        self.y = self.nz(self.a)

    def op_txa(self, addr):
        self.a = self.nz(self.x)

    def op_tya(self, addr):
        self.a = self.nz(self.y)

    def op_tsx(self, addr):
        self.x = self.nz(self.s)

    def op_txs(self, addr):
        self.s = self.x

    def op_pha(self, addr):
        self.push(self.a)

    def op_php(self, addr):
        self.push(self.p())

    def op_pla(self, addr):
        self.a = self.nz(self.pull())

    def op_plp(self, addr):
        self.set_p(self.pull())

    def _branch(self, addr, taken):
        if taken:
            self.cycles += 1
            if (addr ^ self.pc) & 0xFF00:
                self.cycles += 1
            self.pc = addr

    def op_bpl(self, addr):
        self._branch(addr, not self.n)

    def op_bmi(self, addr):
        self._branch(addr, self.n)

    def op_bvc(self, addr):
        self._branch(addr, not self.v)

    def op_bvs(self, addr):
        self._branch(addr, self.v)

    def op_bcc(self, addr):
        self._branch(addr, not self.c)

    def op_bcs(self, addr):
        self._branch(addr, self.c)

    def op_bne(self, addr):
        self._branch(addr, not self.z)

    def op_beq(self, addr):
        self._branch(addr, self.z)

    def op_jmp(self, addr):
        self.pc = addr

    def op_jsr(self, addr):
        ret = (self.pc - 1) & 0xFFFF
        self.push(ret >> 8)
        self.push(ret & 0xFF)
        self.pc = addr

    def op_rts(self, addr):
        lo = self.pull()
        hi = self.pull()
        self.pc = (((hi << 8) | lo) + 1) & 0xFFFF

    def op_rti(self, addr):
        self.set_p(self.pull())
        lo = self.pull()
        hi = self.pull()
        self.pc = (hi << 8) | lo

    def op_brk(self, addr):
        ret = (self.pc + 1) & 0xFFFF
        self.push(ret >> 8)
        self.push(ret & 0xFF)
        self.push(self.p() | B_FLAG)
        self.i = 1
        self.pc = self.read16(0xFFFE)

    def op_clc(self, addr):
        self.c = 0

    def op_sec(self, addr):
        self.c = 1

    def op_cli(self, addr):
        self.i = 0

    def op_sei(self, addr):
        self.i = 1

    def op_cld(self, addr):
        self.d = 0

    def op_sed(self, addr):
        self.d = 1

    def op_clv(self, addr):
        self.v = 0

    def op_nop(self, addr):
        pass

    # ---- the opcode table ---------------------------------------------

    def _build_table(self):
        # (mnemonic, mode, cycles, page-cross penalty applies)
        spec = {}

        def add(op, mn, mode, cyc, extra=False):
            spec[op] = (mn, mode, cyc, extra)

        for mn, ops in (
            ("lda", {0xA9: ("imm", 2), 0xA5: ("zp", 3), 0xB5: ("zpx", 4), 0xAD: ("abs", 4),
                     0xBD: ("absx", 4, 1), 0xB9: ("absy", 4, 1), 0xA1: ("indx", 6), 0xB1: ("indy", 5, 1)}),
            ("ldx", {0xA2: ("imm", 2), 0xA6: ("zp", 3), 0xB6: ("zpy", 4), 0xAE: ("abs", 4), 0xBE: ("absy", 4, 1)}),
            ("ldy", {0xA0: ("imm", 2), 0xA4: ("zp", 3), 0xB4: ("zpx", 4), 0xAC: ("abs", 4), 0xBC: ("absx", 4, 1)}),
            ("sta", {0x85: ("zp", 3), 0x95: ("zpx", 4), 0x8D: ("abs", 4), 0x9D: ("absx", 5),
                     0x99: ("absy", 5), 0x81: ("indx", 6), 0x91: ("indy", 6)}),
            ("stx", {0x86: ("zp", 3), 0x96: ("zpy", 4), 0x8E: ("abs", 4)}),
            ("sty", {0x84: ("zp", 3), 0x94: ("zpx", 4), 0x8C: ("abs", 4)}),
            ("cpx", {0xE0: ("imm", 2), 0xE4: ("zp", 3), 0xEC: ("abs", 4)}),
            ("cpy", {0xC0: ("imm", 2), 0xC4: ("zp", 3), 0xCC: ("abs", 4)}),
            ("bit", {0x24: ("zp", 3), 0x2C: ("abs", 4)}),
        ):
            for op, m in ops.items():
                add(op, mn, m[0], m[1], len(m) > 2)

        # The eight ALU groups share one layout of opcodes.
        for mn, base in (("ora", 0x00), ("and", 0x20), ("eor", 0x40), ("adc", 0x60),
                         ("cmp", 0xC0), ("sbc", 0xE0)):
            add(base + 0x09, mn, "imm", 2)
            add(base + 0x05, mn, "zp", 3)
            add(base + 0x15, mn, "zpx", 4)
            add(base + 0x0D, mn, "abs", 4)
            add(base + 0x1D, mn, "absx", 4, True)
            add(base + 0x19, mn, "absy", 4, True)
            add(base + 0x01, mn, "indx", 6)
            add(base + 0x11, mn, "indy", 5, True)

        for mn, base in (("asl", 0x00), ("rol", 0x20), ("lsr", 0x40), ("ror", 0x60)):
            add(base + 0x0A, mn, "none", 2)
            add(base + 0x06, mn, "zp", 5)
            add(base + 0x16, mn, "zpx", 6)
            add(base + 0x0E, mn, "abs", 6)
            add(base + 0x1E, mn, "absx", 7)

        for mn, base in (("dec", 0xC0), ("inc", 0xE0)):
            add(base + 0x06, mn, "zp", 5)
            add(base + 0x16, mn, "zpx", 6)
            add(base + 0x0E, mn, "abs", 6)
            add(base + 0x1E, mn, "absx", 7)

        for op, mn in ((0x10, "bpl"), (0x30, "bmi"), (0x50, "bvc"), (0x70, "bvs"),
                       (0x90, "bcc"), (0xB0, "bcs"), (0xD0, "bne"), (0xF0, "beq")):
            add(op, mn, "rel", 2)

        for op, mn, cyc in ((0xAA, "tax", 2), (0xA8, "tay", 2), (0x8A, "txa", 2), (0x98, "tya", 2),
                            (0xBA, "tsx", 2), (0x9A, "txs", 2), (0x48, "pha", 3), (0x08, "php", 3),
                            (0x68, "pla", 4), (0x28, "plp", 4), (0xE8, "inx", 2), (0xC8, "iny", 2),
                            (0xCA, "dex", 2), (0x88, "dey", 2), (0x18, "clc", 2), (0x38, "sec", 2),
                            (0x58, "cli", 2), (0x78, "sei", 2), (0xD8, "cld", 2), (0xF8, "sed", 2),
                            (0xB8, "clv", 2), (0xEA, "nop", 2), (0x60, "rts", 6), (0x40, "rti", 6),
                            (0x00, "brk", 7)):
            add(op, mn, "none", cyc)

        add(0x4C, "jmp", "abs", 3)
        add(0x6C, "jmp", "ind", 5)
        add(0x20, "jsr", "abs", 6)

        self.table = [None] * 256
        self.mnemonic = [None] * 256
        for op, (mn, mode, cyc, extra) in spec.items():
            self.table[op] = (getattr(self, "op_" + mn), getattr(self, "am_" + mode), cyc, extra)
            self.mnemonic[op] = mn

    # ---- running ------------------------------------------------------

    def step(self):
        pc = self.pc
        trap = self.traps.get(pc)
        if trap is not None:
            trap()
            pc = self.pc
        op = self.mem[pc]
        entry = self.table[op]
        if entry is None:
            raise Unimplemented(f"opcode &{op:02X} at &{pc:04X}")
        fn, mode, cyc, extra = entry
        self.pc = (pc + 1) & 0xFFFF
        self.cycles += cyc
        fn(mode(extra))

    def run(self, until=None, max_cycles=None, stop=None):
        """Run until pc reaches an address in until (a set), the cycle count
        reaches max_cycles, or stop() returns true. Returns the pc."""
        until = until or ()
        limit = None if max_cycles is None else self.cycles + max_cycles
        step = self.step
        while True:
            step()
            if self.pc in until:
                return self.pc
            if limit is not None and self.cycles >= limit:
                return self.pc
            if stop is not None and stop():
                return self.pc
