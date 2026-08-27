// Differential test: our half-T-state Z80 against the real vendor/chips/z80.h,
// run in lockstep from identical state, comparing the full register file after
// every instruction.
//
// What is and isn't compared, and why:
//
//  * REGISTERS after each instruction -- the real correctness bar, and
//    language/architecture independent.
//  * T-STATE COUNTS per instruction -- our half-clock count must be exactly
//    twice the reference's T-state count. This is what catches a machine
//    cycle that lost or gained a half-state during the expansion, which
//    register comparison alone would not notice.
//  * NOT pin-level timing. z80.h's pins are a per-tick "what is being
//    requested" mask, not literal wire state -- it asserts MREQ on T1 and T3
//    with T2 idle, which no real Z80 does. Our whole point is to model the
//    wires properly, so diffing pins against it would be diffing against the
//    thing we deliberately diverge from. Half-T pin fidelity gets its own
//    tests, written against the datasheet.

#include "memory.h"
#include "test_main.h"
#include "z80.h" // ours

// The reference. Included as "chips/z80.h" rather than "z80.h" so it can't be
// confused with our own same-named header -- the test include path points at
// vendor/, not vendor/chips/, precisely to keep those two distinguishable.
#define CHIPS_IMPL
#include "chips/z80.h"

#include <algorithm>
#include <array>
#include <cstdio>
#include <iterator>
#include <string>
#include <vector>

using namespace zx;

namespace {

/// Deterministic PRNG (SplitMix64) so a failing seed is reproducible without
/// pulling in a dependency.
class Rng {
public:
    explicit Rng(uint64_t seed) : state_(seed) {}

    uint64_t next_u64() {
        state_ += 0x9E3779B97F4A7C15ULL;
        uint64_t z = state_;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
        return z ^ (z >> 31);
    }
    uint8_t next_u8() { return uint8_t(next_u64()); }
    uint16_t next_u16() { return uint16_t(next_u64()); }
    uint8_t choice(const std::vector<uint8_t>& options) {
        return options[size_t(next_u64() % options.size())];
    }

private:
    uint64_t state_;
};

/// Both cores' register files, side by side, for a mismatch report.
///
/// Compares RAW PC on both sides, deliberately: both cores use the same
/// overlapped-fetch convention (PC already points past the next opcode), so
/// raw-vs-raw matches directly. Applying our registers()' pc-1 correction to
/// one side only would manufacture an off-by-one that isn't there.
std::string diff_registers(const Registers& ours, const z80_t& ref) {
    std::string out;
    auto line = [&out](const char* name, unsigned a, unsigned b) {
        if (a != b) {
            char buf[128];
            std::snprintf(buf, sizeof buf, "\n        %-5s ours=%04X ref=%04X", name, a, b);
            out += buf;
        }
    };
    line("AF", ours.af(), ref.af);
    line("BC", ours.bc(), ref.bc);
    line("DE", ours.de(), ref.de);
    line("HL", ours.hl(), ref.hl);
    line("AF'", uint16_t((ours.a_ << 8) | ours.f_), ref.af2);
    line("BC'", uint16_t((ours.b_ << 8) | ours.c_), ref.bc2);
    line("DE'", uint16_t((ours.d_ << 8) | ours.e_), ref.de2);
    line("HL'", uint16_t((ours.h_ << 8) | ours.l_), ref.hl2);
    line("IX", ours.ix, ref.ix);
    line("IY", ours.iy, ref.iy);
    line("SP", ours.sp, ref.sp);
    line("PC", ours.pc, ref.pc);
    line("I", ours.i, ref.i);
    line("R", ours.r, ref.r);
    line("IM", ours.im, ref.im);
    line("IFF1", ours.iff1, ref.iff1);
    line("IFF2", ours.iff2, ref.iff2);
    // WZ/MEMPTR is internal and unreadable by any instruction, but it is
    // architectural state: it feeds the undocumented bit5/bit3 flags of
    // BIT n,(HL). Comparing it directly turns "some flag bits are wrong
    // several instructions later" into "WZ diverged here".
    line("WZ", ours.wz, ref.wz);
    return out;
}

/// Services the reference's memory pins the same way our step_instruction()
/// does. Z80_SET_DATA is a statement macro that assigns to its first argument,
/// not an expression -- hence the slightly awkward shape.
uint64_t ref_service(uint64_t /*prev*/, FlatMemory& mem, uint64_t p) {
    if (p & Z80_MREQ) {
        if (p & Z80_RD) {
            uint64_t d = mem.bytes[Z80_GET_ADDR(p)];
            Z80_SET_DATA(p, d);
        } else if (p & Z80_WR) {
            mem.bytes[Z80_GET_ADDR(p)] = Z80_GET_DATA(p);
        }
    }
    return p;
}

/// Runs one whole instruction on the reference. Returns the T-states taken.
uint16_t ref_step(z80_t& cpu, uint64_t& pins, FlatMemory& mem) {
    pins = ref_service(pins, mem, z80_tick(&cpu, pins));
    uint16_t tstates = 1;
    while (!z80_opdone(&cpu)) {
        pins = ref_service(pins, mem, z80_tick(&cpu, pins));
        tstates++;
    }
    return tstates;
}

/// Drives both cores through `count` instructions from identical memory and
/// registers, comparing after each. Returns "" on success, or a report.
std::string run_lockstep(const std::array<uint8_t, 0x10000>& image,
                         const Registers& start, int count, bool check_timing = true) {
    Z80 ours;
    FlatMemory our_mem;
    our_mem.bytes = image;
    ours.set_registers(start, our_mem);

    z80_t ref{};
    uint64_t ref_pins = z80_init(&ref);
    FlatMemory ref_mem;
    ref_mem.bytes = image;
    ref.af = start.af(); ref.bc = start.bc(); ref.de = start.de(); ref.hl = start.hl();
    ref.af2 = uint16_t((start.a_ << 8) | start.f_);
    ref.bc2 = uint16_t((start.b_ << 8) | start.c_);
    ref.de2 = uint16_t((start.d_ << 8) | start.e_);
    ref.hl2 = uint16_t((start.h_ << 8) | start.l_);
    ref.ix = start.ix; ref.iy = start.iy; ref.sp = start.sp;
    ref.i = start.i; ref.r = start.r;
    ref.iff1 = start.iff1; ref.iff2 = start.iff2; ref.im = start.im;
    // z80_init() fills every register with 0xFFFF, so WZ must be set
    // explicitly too -- it is not covered by the pair assignments above.
    ref.wz = start.wz;
    ref_pins = z80_prefetch(&ref, start.pc);
    // z80_prefetch only sets step=0 and returns; it does NOT tick. Our
    // set_registers() does perform that one priming half-clock (step 0 is
    // NOP, whose body is begin_fetch), so without matching it here the
    // reference sits one whole instruction behind and every comparison is
    // off by one fetch -- which looks alarmingly like a real core bug (PC and
    // R each off by exactly one) but is purely a harness artifact.
    ref_pins = ref_service(ref_pins, ref_mem, z80_tick(&ref, ref_pins));

    for (int i = 0; i < count; i++) {
        uint16_t our_halves = ours.step_instruction(our_mem);
        uint16_t ref_tstates = ref_step(ref, ref_pins, ref_mem);

        std::string d = diff_registers(ours.regs, ref);
        if (!d.empty()) {
            return "instruction " + std::to_string(i) + ": registers diverged" + d;
        }
        if (check_timing && our_halves != ref_tstates * 2) {
            return "instruction " + std::to_string(i) + ": timing diverged -- ours="
                 + std::to_string(our_halves) + " half-clocks ("
                 + std::to_string(our_halves / 2.0) + " T), ref="
                 + std::to_string(ref_tstates) + " T";
        }
    }
    return {};
}

Registers default_regs(uint16_t pc = 0) {
    Registers r;
    r.pc = pc;
    r.sp = 0xFF00;
    return r;
}

} // namespace

// ---- the simplest possible thing that could work ---------------------------

TEST(nops_run_in_lockstep_with_the_reference) {
    std::array<uint8_t, 0x10000> image{}; // all zero == all NOPs
    std::string err = run_lockstep(image, default_regs(), 16);
    CHECK_EQ(err, std::string());
}

TEST(ld_and_alu_opcodes_run_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    const uint8_t program[] = {
        0x3E, 0x42,        // LD A,0x42
        0x06, 0x13,        // LD B,0x13
        0x0E, 0x77,        // LD C,0x77
        0x80,              // ADD A,B
        0x91,              // SUB C
        0xA0,              // AND B
        0xB1,              // OR C
        0xA9,              // XOR C
        0xB8,              // CP B
        0x04,              // INC B
        0x0D,              // DEC C
        0x2F,              // CPL
        0x37,              // SCF
        0x3F,              // CCF
        0x27,              // DAA
        0x07, 0x0F, 0x17, 0x1F, // RLCA RRCA RLA RRA
    };
    std::copy(std::begin(program), std::end(program), image.begin());
    std::string err = run_lockstep(image, default_regs(), 20);
    CHECK_EQ(err, std::string());
}

TEST(memory_read_write_opcodes_run_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    const uint8_t program[] = {
        0x21, 0x00, 0x90,  // LD HL,0x9000
        0x36, 0x5A,        // LD (HL),0x5A
        0x7E,              // LD A,(HL)
        0x23,              // INC HL
        0x77,              // LD (HL),A
        0x34,              // INC (HL)
        0x35,              // DEC (HL)
        0x01, 0x34, 0x12,  // LD BC,0x1234
        0x11, 0x78, 0x56,  // LD DE,0x5678
        0xEB,              // EX DE,HL
        0x22, 0x10, 0x90,  // LD (0x9010),HL
        0x2A, 0x10, 0x90,  // LD HL,(0x9010)
    };
    std::copy(std::begin(program), std::end(program), image.begin());
    std::string err = run_lockstep(image, default_regs(), 14);
    CHECK_EQ(err, std::string());
}

TEST(control_flow_runs_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    const uint8_t program[] = {
        0x31, 0x00, 0xFF,        // LD SP,0xFF00
        0xCD, 0x10, 0x00,        // CALL 0x0010
        0xC3, 0x20, 0x00,        // JP 0x0020
    };
    std::copy(std::begin(program), std::end(program), image.begin());
    image[0x0010] = 0xC9;        // RET
    image[0x0020] = 0x06; image[0x0021] = 0x03;  // LD B,3
    image[0x0022] = 0x05;        // DEC B
    image[0x0023] = 0x20; image[0x0024] = 0xFD;  // JR NZ,-3
    image[0x0025] = 0x00;        // NOP
    std::string err = run_lockstep(image, default_regs(), 16);
    CHECK_EQ(err, std::string());
}

TEST(push_pop_and_exchange_run_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    const uint8_t program[] = {
        0x31, 0x00, 0xFF,  // LD SP,0xFF00
        0x01, 0x34, 0x12,  // LD BC,0x1234
        0xC5,              // PUSH BC
        0xE1,              // POP HL
        0xD9,              // EXX
        0x08,              // EX AF,AF'
        0xE5,              // PUSH HL
        0xE3,              // EX (SP),HL
        0xF1,              // POP AF
        0xF9,              // LD SP,HL
    };
    std::copy(std::begin(program), std::end(program), image.begin());
    std::string err = run_lockstep(image, default_regs(), 11);
    CHECK_EQ(err, std::string());
}

TEST(halt_runs_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    image[0] = 0x00;   // NOP
    image[1] = 0x76;   // HALT -- then spins re-fetching itself
    std::string err = run_lockstep(image, default_regs(), 12);
    CHECK_EQ(err, std::string());
}

TEST(ed_prefixed_opcodes_run_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    const uint8_t program[] = {
        0x21, 0x34, 0x12,        // LD HL,0x1234
        0x01, 0x11, 0x11,        // LD BC,0x1111
        0xED, 0x4A,              // ADC HL,BC
        0xED, 0x42,              // SBC HL,BC
        0xED, 0x44,              // NEG
        0xED, 0x5E,              // IM 2
        0xED, 0x47,              // LD I,A
        0xED, 0x57,              // LD A,I
        0xED, 0x4F,              // LD R,A
        0xED, 0x5F,              // LD A,R
        0xED, 0x43, 0x00, 0x90,  // LD (0x9000),BC
        0xED, 0x4B, 0x00, 0x90,  // LD BC,(0x9000)
    };
    std::copy(std::begin(program), std::end(program), image.begin());
    std::string err = run_lockstep(image, default_regs(), 12);
    CHECK_EQ(err, std::string());
}

TEST(ed_block_transfer_and_search_run_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    const uint8_t program[] = {
        0x21, 0x00, 0x90,  // LD HL,0x9000
        0x11, 0x00, 0x91,  // LD DE,0x9100
        0x01, 0x03, 0x00,  // LD BC,3
        0xED, 0xB0,        // LDIR
        0x21, 0x00, 0x90,  // LD HL,0x9000
        0x01, 0x03, 0x00,  // LD BC,3
        0x3E, 0x22,        // LD A,0x22
        0xED, 0xB1,        // CPIR
        0xED, 0xA0,        // LDI
        0xED, 0xA8,        // LDD
        0xED, 0xA1,        // CPI
        0xED, 0xA9,        // CPD
    };
    std::copy(std::begin(program), std::end(program), image.begin());
    image[0x9000] = 0x11; image[0x9001] = 0x22; image[0x9002] = 0x33;
    std::string err = run_lockstep(image, default_regs(), 14);
    CHECK_EQ(err, std::string());
}

TEST(cb_prefixed_opcodes_run_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    std::vector<uint8_t> program = {0x21, 0x00, 0x90, 0x3E, 0xA5}; // LD HL,0x9000 ; LD A,0xA5
    // One CB op of each x-group against a register and against (HL).
    for (uint8_t cb : {uint8_t(0x07), uint8_t(0x0F), uint8_t(0x17), uint8_t(0x1F),
                       uint8_t(0x27), uint8_t(0x2F), uint8_t(0x37), uint8_t(0x3F),
                       uint8_t(0x47), uint8_t(0x87), uint8_t(0xC7),
                       uint8_t(0x06), uint8_t(0x46), uint8_t(0x86), uint8_t(0xC6)}) {
        program.push_back(0xCB);
        program.push_back(cb);
    }
    std::copy(program.begin(), program.end(), image.begin());
    image[0x9000] = 0x5A;
    std::string err = run_lockstep(image, default_regs(), int(program.size()));
    CHECK_EQ(err, std::string());
}

TEST(ix_iy_prefixed_opcodes_run_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    const uint8_t program[] = {
        0xDD, 0x21, 0x00, 0x90,  // LD IX,0x9000
        0xFD, 0x21, 0x00, 0x91,  // LD IY,0x9100
        0xDD, 0x36, 0x05, 0x7B,  // LD (IX+5),0x7B
        0xDD, 0x7E, 0x05,        // LD A,(IX+5)
        0xDD, 0x34, 0x05,        // INC (IX+5)
        0xDD, 0x35, 0x05,        // DEC (IX+5)
        0xDD, 0x86, 0x05,        // ADD A,(IX+5)
        0xFD, 0x77, 0x02,        // LD (IY+2),A
        0xDD, 0x23,              // INC IX
        0xDD, 0x2B,              // DEC IX
        0xDD, 0xE5,              // PUSH IX
        0xDD, 0xE1,              // POP IX
        0xDD, 0x24,              // INC IXH (undocumented)
        0xDD, 0x2C,              // INC IXL (undocumented)
    };
    std::copy(std::begin(program), std::end(program), image.begin());
    std::string err = run_lockstep(image, default_regs(), 14);
    CHECK_EQ(err, std::string());
}

TEST(ddcb_fdcb_double_prefix_runs_in_lockstep) {
    std::array<uint8_t, 0x10000> image{};
    const uint8_t program[] = {
        0xDD, 0x21, 0x00, 0x90,   // LD IX,0x9000
        0xDD, 0xCB, 0x02, 0x06,   // RLC (IX+2)
        0xDD, 0xCB, 0x02, 0x46,   // BIT 0,(IX+2)  -- the no-write-back path
        0xDD, 0xCB, 0x02, 0x86,   // RES 0,(IX+2)
        0xDD, 0xCB, 0x02, 0xC6,   // SET 0,(IX+2)
        0xDD, 0xCB, 0x02, 0x00,   // RLC (IX+2),B -- undocumented register copy
    };
    std::copy(std::begin(program), std::end(program), image.begin());
    image[0x9002] = 0x5A;
    std::string err = run_lockstep(image, default_regs(), 6);
    CHECK_EQ(err, std::string());
}

// ---- randomised streams ----------------------------------------------------

TEST(random_non_control_flow_streams_run_in_lockstep) {
    // Opcodes safe to fuzz: no control flow (so PC only advances), no stack,
    // and nothing that would let HL wander into the instruction stream. HL is
    // parked on a scratch page and H/L are excluded as destinations.
    const std::vector<uint8_t> dst_regs = {0, 1, 2, 3, 7};      // B C D E A
    const std::vector<uint8_t> src_regs = {0, 1, 2, 3, 4, 5, 7}; // no (HL)
    const std::vector<uint8_t> singles = {0x07, 0x0F, 0x17, 0x1F, 0x27, 0x2F, 0x37, 0x3F};

    for (uint64_t seed = 1; seed <= 8; seed++) {
        Rng rng(seed);
        std::array<uint8_t, 0x10000> image{};
        size_t at = 0;
        const int instructions = 64;
        for (int n = 0; n < instructions; n++) {
            switch (rng.next_u64() % 5) {
                case 0: // LD r,r'
                    image[at++] = uint8_t(0x40 | (rng.choice(dst_regs) << 3) | rng.choice(src_regs));
                    break;
                case 1: // LD r,n
                    image[at++] = uint8_t(0x06 | (rng.choice(dst_regs) << 3));
                    image[at++] = rng.next_u8();
                    break;
                case 2: // ALU A,r
                    image[at++] = uint8_t(0x80 | (uint8_t(rng.next_u64() % 8) << 3) | rng.choice(src_regs));
                    break;
                case 3: // ALU A,n
                    image[at++] = uint8_t(0xC6 | (uint8_t(rng.next_u64() % 8) << 3));
                    image[at++] = rng.next_u8();
                    break;
                default: // accumulator/flag single-byte ops
                    image[at++] = rng.choice(singles);
                    break;
            }
        }

        Registers start = default_regs();
        start.a = rng.next_u8(); start.f = rng.next_u8();
        start.b = rng.next_u8(); start.c = rng.next_u8();
        start.d = rng.next_u8(); start.e = rng.next_u8();
        start.set_hl(0x9000); // scratch page, well clear of the code
        start.a_ = rng.next_u8(); start.f_ = rng.next_u8();
        start.b_ = rng.next_u8(); start.c_ = rng.next_u8();
        start.ix = 0x9100; start.iy = 0x9200;
        start.i = rng.next_u8(); start.r = uint8_t(rng.next_u8() & 0x7F);

        std::string err = run_lockstep(image, start, instructions);
        if (!err.empty()) {
            std::printf("    seed %llu: %s\n", (unsigned long long)seed, err.c_str());
        }
        CHECK_EQ(err, std::string());
    }
}

RUN_TESTS()
