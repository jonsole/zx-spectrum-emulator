// Code/data classification tests.
//
// The interesting cases are all about telling one kind of memory access from
// another on a bus where several of them look alike: an opcode fetch and a
// data read differ only by M1; the second byte of a prefixed instruction is
// an opcode fetch that must NOT be reported as somewhere an instruction
// starts; and the refresh cycle puts an address on the bus with MREQ asserted
// while accessing nothing at all.
//
// Programs run from RAM (0x8000 up) so that writes actually land, and are
// driven through Spectrum48K directly rather than the Engine -- no thread, no
// queue, just the machine and the bus.

#include "coverage.h"
#include "file_io.h"
#include "spectrum.h"
#include "test_main.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace zx;

namespace {

constexpr uint16_t ORG = 0x8000;

/// Loads `code` at ORG, points PC at it, and runs `instructions` of it with
/// coverage recording.
void run(Spectrum48K& m, Coverage& cov, const std::vector<uint8_t>& code, int instructions) {
    m.write_memory(ORG, code.data(), code.size());
    Registers r;
    r.pc = ORG;
    r.sp = 0xFF00;
    m.set_registers(r);
    m.set_coverage(&cov);
    for (int i = 0; i < instructions; i++) {
        m.step_instruction();
    }
    m.set_coverage(nullptr);
}

} // namespace

TEST(an_opcode_fetch_marks_an_instruction_start) {
    Spectrum48K m;
    Coverage cov;
    //  8000: 00        NOP
    //  8001: 76        HALT
    run(m, cov, {0x00, 0x76}, 1);

    CHECK_EQ(cov.at(ORG), uint8_t(COV_INSTRUCTION | COV_CODE));
    CHECK_EQ(cov.at(ORG + 1), uint8_t(0)); // not reached yet
}

TEST(operands_are_read_not_code) {
    Spectrum48K m;
    Coverage cov;
    //  8000: 21 34 12  LD HL,1234h
    run(m, cov, {0x21, 0x34, 0x12}, 1);

    CHECK_EQ(cov.at(ORG), uint8_t(COV_INSTRUCTION | COV_CODE));
    // The two operand bytes are fetched by the same instruction but without
    // M1: they are data the instruction read, and a disassembler must not be
    // told an instruction starts at either of them.
    CHECK_EQ(cov.at(ORG + 1), uint8_t(COV_READ));
    CHECK_EQ(cov.at(ORG + 2), uint8_t(COV_READ));
}

TEST(a_prefix_marks_only_its_first_byte_as_an_instruction) {
    Spectrum48K m;
    Coverage cov;
    //  8000: CB 27     SLA A       -- two M1 fetches, one instruction
    //  8002: ED 44     NEG         -- likewise
    //  8004: DD 23     INC IX      -- likewise
    run(m, cov, {0xCB, 0x27, 0xED, 0x44, 0xDD, 0x23}, 3);

    for (uint16_t at : {ORG, uint16_t(ORG + 2), uint16_t(ORG + 4)}) {
        CHECK_EQ(cov.at(at), uint8_t(COV_INSTRUCTION | COV_CODE));
        // The second byte IS fetched as an opcode -- it is code, and saying
        // otherwise would be a lie -- but it is not a place to start
        // disassembling from.
        CHECK_EQ(cov.at(uint16_t(at + 1)), uint8_t(COV_CODE));
    }
}

TEST(a_ddcb_instruction_marks_only_its_first_byte) {
    Spectrum48K m;
    Coverage cov;
    // DD CB d op is the awkward one: TWO M1 fetches (DD, CB) and then the
    // displacement and the operation byte read WITHOUT M1, so the instruction
    // ends on a data read rather than an opcode fetch.
    //
    //  8000: DD CB 02 06   RLC (IX+2)
    //  8004: 00            NOP
    run(m, cov, {0xDD, 0xCB, 0x02, 0x06, 0x00}, 2);

    CHECK_EQ(cov.at(ORG), uint8_t(COV_INSTRUCTION | COV_CODE));
    CHECK_EQ(cov.at(ORG + 1), uint8_t(COV_CODE));
    CHECK_EQ(cov.at(ORG + 2), uint8_t(COV_READ));
    CHECK_EQ(cov.at(ORG + 3), uint8_t(COV_READ));
    // And the instruction after it is a start again -- the thing a state
    // machine tracking prefixes gets wrong if it assumes every prefixed
    // instruction ends with an M1 fetch.
    CHECK_EQ(cov.at(ORG + 4), uint8_t(COV_INSTRUCTION | COV_CODE));
}

TEST(writes_are_recorded_separately_from_reads) {
    Spectrum48K m;
    Coverage cov;
    //  8000: 3E 42     LD A,42h
    //  8002: 32 00 90  LD (9000h),A
    //  8005: 3A 01 90  LD A,(9001h)
    run(m, cov, {0x3E, 0x42, 0x32, 0x00, 0x90, 0x3A, 0x01, 0x90}, 3);

    CHECK_EQ(cov.at(0x9000), uint8_t(COV_WRITTEN));
    CHECK_EQ(cov.at(0x9001), uint8_t(COV_READ));
}

TEST(a_byte_that_is_both_read_and_written_carries_both_flags) {
    Spectrum48K m;
    Coverage cov;
    //  8000: 21 00 90  LD HL,9000h
    //  8003: 34        INC (HL)     -- reads it, then writes it back
    run(m, cov, {0x21, 0x00, 0x90, 0x34}, 2);

    CHECK_EQ(cov.at(0x9000), uint8_t(COV_READ | COV_WRITTEN));
}

TEST(the_refresh_address_is_not_recorded) {
    Spectrum48K m;
    Coverage cov;
    // Every M1 cycle drives I:R on the bus with MREQ asserted for two
    // half-clocks. Nothing is accessed, so nothing may be marked. I is 0 out
    // of reset and R climbs by one per fetch, so an unguarded implementation
    // marks a trail of low addresses -- exactly where a Spectrum's ROM is.
    Registers r;
    r.pc = ORG;
    r.i = 0x00;
    r.r = 0x10;
    m.set_registers(r);
    const std::vector<uint8_t> nops(8, 0x00);
    m.write_memory(ORG, nops.data(), nops.size());
    m.set_coverage(&cov);
    for (int i = 0; i < 8; i++) {
        m.step_instruction();
    }
    m.set_coverage(nullptr);

    for (uint16_t a = 0x0000; a < 0x0100; a++) {
        CHECK_EQ(cov.at(a), uint8_t(0));
    }
}

TEST(counts_and_clear) {
    Spectrum48K m;
    Coverage cov;
    //  8000: 21 00 90  LD HL,9000h
    //  8003: 34        INC (HL)
    run(m, cov, {0x21, 0x00, 0x90, 0x34}, 2);

    const CoverageCounts c = cov.counts(0x4000, 0x10000);
    CHECK_EQ(c.instructions, size_t(2));           // the two opcodes
    CHECK_EQ(c.code, size_t(2));
    CHECK_EQ(c.read, size_t(3));                   // two operands + (HL)
    CHECK_EQ(c.written, size_t(1));                // (HL)
    // Five addresses in all: the two opcodes, the two operand bytes, and the
    // one the program read and wrote.
    CHECK_EQ(c.untouched, size_t(0xC000 - 5));

    cov.clear();
    CHECK_EQ(cov.counts(0x4000, 0x10000).untouched, size_t(0xC000));
}

TEST(the_map_file_is_65536_bytes_with_skoolkits_bit_in_bit_0) {
    Spectrum48K m;
    Coverage cov;
    //  8000: CB 27     SLA A
    run(m, cov, {0xCB, 0x27}, 1);

    const std::string path = "coverage_test.map";
    CHECK_EQ(cov.write(path, 0x4000, 0x10000), std::string());

    std::vector<uint8_t> data;
    CHECK(read_file(path, data));
    // SkoolKit picks the map format from the file's size, so this is not
    // incidental: 65536 means "one byte per address", and anything else would
    // be read as a bitmap or as a text profile.
    CHECK_EQ(data.size(), size_t(0x10000));
    // Bit 0 is what sna2ctl tests. Set on the instruction start, clear on the
    // prefixed second byte -- which is the whole point of the distinction.
    CHECK_EQ(uint8_t(data[ORG] & 1), uint8_t(1));
    CHECK_EQ(uint8_t(data[ORG + 1] & 1), uint8_t(0));
    CHECK_EQ(uint8_t(data[ORG + 1] & COV_CODE), uint8_t(COV_CODE));
    std::remove(path.c_str());
}

TEST(the_map_file_is_zero_outside_the_requested_range) {
    Spectrum48K m;
    Coverage cov;
    run(m, cov, {0x00}, 1);

    const std::string path = "coverage_range_test.map";
    // A range that excludes the program: nothing should survive into the file.
    CHECK_EQ(cov.write(path, 0x4000, 0x6000), std::string());
    std::vector<uint8_t> data;
    CHECK(read_file(path, data));
    CHECK_EQ(data.size(), size_t(0x10000));
    CHECK_EQ(data[ORG], uint8_t(0));
    CHECK(cov.at(ORG) != 0); // ...while the map itself still has it
    std::remove(path.c_str());
}

RUN_TESTS()
