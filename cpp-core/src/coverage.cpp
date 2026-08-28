#include "coverage.h"

#include "pins.h"

#include <fstream>
#include <vector>

namespace zx {

void Coverage::record(uint64_t pins, bool instruction_boundary) {
    if (!asserted(pins, MREQ)) {
        return;
    }
    const uint16_t addr = get_addr(pins);
    if (asserted(pins, RD)) {
        if (asserted(pins, M1)) {
            // An opcode fetch. Whether it STARTS an instruction cannot be
            // read off the bus -- the second fetch of a CB/ED/DD/FD pair
            // asserts exactly the same pins as the first -- so the caller
            // passes the CPU's own answer (Z80::fetch_began_instruction).
            //
            // MREQ|RD stay asserted for several half-clocks, so this runs
            // repeatedly for one fetch; setting a bit twice is the same as
            // setting it once, which is why no edge detection is needed.
            flags_[addr] |= uint8_t(instruction_boundary
                                        ? (COV_CODE | COV_INSTRUCTION)
                                        : COV_CODE);
        } else {
            flags_[addr] |= COV_READ;
        }
        return;
    }
    if (asserted(pins, WR)) {
        flags_[addr] |= COV_WRITTEN;
    }
    // A bare MREQ with neither RD nor WR is the refresh cycle: the address
    // is live on the bus but nothing is being accessed, so it is not
    // evidence of anything. Interrupt acknowledge never reaches here at
    // all -- it asserts M1 and IORQ, not MREQ.
}

CoverageCounts Coverage::counts(uint32_t start, uint32_t end) const {
    CoverageCounts c;
    for (uint32_t a = start; a < end && a < flags_.size(); a++) {
        const uint8_t f = flags_[a];
        if (f == 0) {
            c.untouched++;
            continue;
        }
        if (f & COV_INSTRUCTION) {
            c.instructions++;
        }
        if (f & COV_CODE) {
            c.code++;
        }
        if (f & COV_READ) {
            c.read++;
        }
        if (f & COV_WRITTEN) {
            c.written++;
        }
    }
    return c;
}

std::string Coverage::write(const std::string& path, uint32_t start, uint32_t end) const {
    // Always 65536 bytes, whatever the range: SkoolKit picks the map format
    // from the file's SIZE (8192 = a bitmap, 65536 = one byte per address,
    // anything else = a text profile), so a short file would be misread as a
    // profile rather than as a narrowed map.
    std::vector<uint8_t> out(flags_.size(), 0);
    for (uint32_t a = start; a < end && a < out.size(); a++) {
        out[a] = flags_[a];
    }
    std::ofstream file(path, std::ios::binary);
    if (!file) {
        return "couldn't open " + path + " for writing";
    }
    file.write(reinterpret_cast<const char*>(out.data()), std::streamsize(out.size()));
    if (!file) {
        return "couldn't write " + path;
    }
    return {};
}

} // namespace zx
