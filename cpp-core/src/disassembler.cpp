#include "disassembler.h"

#include <cstdio>
#include <cstdlib>

namespace zx {
namespace {

const char* const R8[8] = {"B", "C", "D", "E", "H", "L", "(HL)", "A"};
const char* const RP[4] = {"BC", "DE", "HL", "SP"};
const char* const RP2[4] = {"BC", "DE", "HL", "AF"};
const char* const CC[8] = {"NZ", "Z", "NC", "C", "PO", "PE", "P", "M"};
const char* const ALU[8] = {"ADD A,", "ADC A,", "SUB ", "SBC A,", "AND ", "XOR ", "OR ", "CP "};
const char* const ROT[8] = {"RLC ", "RRC ", "RL ", "RR ", "SLA ", "SRA ", "SLL ", "SRL "};
const uint8_t IM_MODE[8] = {0, 0, 1, 2, 0, 0, 1, 2};

const char* block_name(uint8_t z, uint8_t y) {
    static const char* const BLOCK[4][4] = {
        {"LDI", "LDD", "LDIR", "LDDR"},
        {"CPI", "CPD", "CPIR", "CPDR"},
        {"INI", "IND", "INIR", "INDR"},
        {"OUTI", "OUTD", "OTIR", "OTDR"},
    };
    return BLOCK[z][y - 4];
}

std::string hex2(uint8_t v) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "0x%02X", v);
    return buf;
}

std::string hex4(uint16_t v) {
    char buf[8];
    std::snprintf(buf, sizeof buf, "0x%04X", v);
    return buf;
}

/// Reads successive bytes starting at `addr` (wrapping at the 64K address
/// space), tracking how many were consumed.
struct Cursor {
    uint16_t start;
    uint16_t pos;

    explicit Cursor(uint16_t addr) : start(addr), pos(addr) {}

    uint8_t byte(const ReadFn& read) {
        uint8_t v = read(pos);
        pos = uint16_t(pos + 1);
        return v;
    }

    uint16_t word(const ReadFn& read) {
        uint8_t lo = byte(read);
        uint8_t hi = byte(read);
        return uint16_t(lo | (hi << 8));
    }

    uint8_t length() const { return uint8_t(pos - start); }
};

std::string decode(Cursor& c, const ReadFn& read, const char* index);
std::string decode_cb(Cursor& c, const ReadFn& read, const char* index);
std::string decode_ed(Cursor& c, const ReadFn& read);

std::string addr_rel(const Cursor& c, int8_t displacement) {
    return hex4(uint16_t(c.pos + displacement));
}

/// "(IX+5)" / "(IY-3)".
std::string indexed(const char* idx, int8_t d) {
    int value = d;
    const char* sign = value >= 0 ? "+" : "-";
    return std::string("(") + idx + sign + std::to_string(std::abs(value)) + ")";
}

/// (HL) becomes (IX+d)/(IY+d) under a DD/FD prefix; H/L become the
/// undocumented IXH/IXL/IYH/IYL only when NOT the (HL) memory slot.
std::string rr(uint8_t i, Cursor& c, const ReadFn& read, const char* index) {
    if (index == nullptr) {
        return R8[i];
    }
    if (i == 6) {
        return indexed(index, int8_t(c.byte(read)));
    }
    if (i == 4) {
        return std::string(index) + "H";
    }
    if (i == 5) {
        return std::string(index) + "L";
    }
    return R8[i];
}

std::string decode(Cursor& c, const ReadFn& read, const char* index) {
    uint8_t op = c.byte(read);

    if (op == 0xCB) {
        // Under a DD/FD prefix this is the DD CB d op / FD CB d op form --
        // `index` must carry through so decode_cb knows to read a
        // displacement byte and target (IX+d)/(IY+d) instead of a plain r.
        return decode_cb(c, read, index);
    }
    if (op == 0xED) {
        return decode_ed(c, read);
    }
    if (op == 0xDD) {
        return decode(c, read, "IX");
    }
    if (op == 0xFD) {
        return decode(c, read, "IY");
    }

    const uint8_t x = uint8_t(op >> 6);
    const uint8_t y = uint8_t((op >> 3) & 0x07);
    const uint8_t z = uint8_t(op & 0x07);
    const uint8_t p = uint8_t(y >> 1);
    const uint8_t q = uint8_t(y & 0x01);

    // HL becomes IX/IY under a prefix, in the 16-bit register-pair slot.
    auto rp = [&](uint8_t i) -> std::string {
        if (index != nullptr && i == 2) {
            return index;
        }
        return RP[i];
    };
    const char* hlx = index != nullptr ? index : "HL";

    if (x == 0) {
        if (z == 0) {
            if (y == 0) {
                return "NOP";
            }
            if (y == 1) {
                return "EX AF,AF'";
            }
            if (y == 2) {
                int8_t d = int8_t(c.byte(read));
                return "DJNZ $" + addr_rel(c, d);
            }
            if (y == 3) {
                int8_t d = int8_t(c.byte(read));
                return "JR $" + addr_rel(c, d);
            }
            int8_t d = int8_t(c.byte(read));
            return std::string("JR ") + CC[y - 4] + ",$" + addr_rel(c, d);
        }
        if (z == 1) {
            if (q == 0) {
                uint16_t nn = c.word(read);
                return "LD " + rp(p) + "," + hex4(nn);
            }
            return std::string("ADD ") + hlx + "," + rp(p);
        }
        if (z == 2) {
            if (q == 0) {
                if (p == 0) {
                    return "LD (BC),A";
                }
                if (p == 1) {
                    return "LD (DE),A";
                }
                if (p == 2) {
                    uint16_t nn = c.word(read);
                    return "LD (" + hex4(nn) + ")," + hlx;
                }
                uint16_t nn = c.word(read);
                return "LD (" + hex4(nn) + "),A";
            }
            if (p == 0) {
                return "LD A,(BC)";
            }
            if (p == 1) {
                return "LD A,(DE)";
            }
            if (p == 2) {
                uint16_t nn = c.word(read);
                return "LD " + std::string(hlx) + ",(" + hex4(nn) + ")";
            }
            uint16_t nn = c.word(read);
            return "LD A,(" + hex4(nn) + ")";
        }
        if (z == 3) {
            return std::string(q == 0 ? "INC " : "DEC ") + rp(p);
        }
        if (z == 4) {
            return "INC " + rr(y, c, read, index);
        }
        if (z == 5) {
            return "DEC " + rr(y, c, read, index);
        }
        if (z == 6) {
            std::string dest = rr(y, c, read, index);
            uint8_t n = c.byte(read);
            return "LD " + dest + "," + hex2(n);
        }
        // z == 7
        static const char* const ACC[8] = {"RLCA", "RRCA", "RLA", "RRA",
                                           "DAA",  "CPL",  "SCF", "CCF"};
        return ACC[y];
    }

    if (x == 1) {
        if (z == 6 && y == 6) {
            return "HALT";
        }
        if (index != nullptr && (y == 6 || z == 6)) {
            // A genuine (IX+d)/(IY+d) memory access is involved -- these are
            // the DOCUMENTED "LD r,(IX+d)"/"LD (IX+d),r" instructions, where
            // r=H or r=L means the REAL H/L register, not IXH/IXL. (The
            // undocumented IXH/IXL substitution only applies to *pure*
            // register-to-register moves, handled by the rr() branch below.)
            std::string mem = indexed(index, int8_t(c.byte(read)));
            if (y == 6) {
                return "LD " + mem + "," + R8[z];
            }
            return "LD " + std::string(R8[y]) + "," + mem;
        }
        // dest is evaluated before the source: at most one of y/z can be 6
        // here, so only one of these consumes a displacement byte, and the
        // order it happens in still matters for the two-argument form.
        std::string dest = rr(y, c, read, index);
        return "LD " + dest + "," + rr(z, c, read, index);
    }

    if (x == 2) {
        return std::string(ALU[y]) + rr(z, c, read, index);
    }

    // x == 3
    if (z == 0) {
        return std::string("RET ") + CC[y];
    }
    if (z == 1) {
        if (q == 0) {
            return std::string("POP ") + ((p == 2 && index != nullptr) ? index : RP2[p]);
        }
        if (p == 0) {
            return "RET";
        }
        if (p == 1) {
            return "EXX";
        }
        if (p == 2) {
            return std::string("JP (") + hlx + ")";
        }
        return std::string("LD SP,") + hlx;
    }
    if (z == 2) {
        uint16_t nn = c.word(read);
        return std::string("JP ") + CC[y] + "," + hex4(nn);
    }
    if (z == 3) {
        if (y == 0) {
            uint16_t nn = c.word(read);
            return "JP " + hex4(nn);
        }
        // y == 1 (opcode 0xCB) is unreachable here -- it's intercepted at the
        // top of decode() before the x/y/z decomposition, since it needs to
        // consume a displacement byte first under DD/FD.
        if (y == 2) {
            uint8_t n = c.byte(read);
            return "OUT (" + hex2(n) + "),A";
        }
        if (y == 3) {
            uint8_t n = c.byte(read);
            return "IN A,(" + hex2(n) + ")";
        }
        if (y == 4) {
            return std::string("EX (SP),") + hlx;
        }
        if (y == 5) {
            return "EX DE,HL";
        }
        if (y == 6) {
            return "DI";
        }
        return "EI";
    }
    if (z == 4) {
        uint16_t nn = c.word(read);
        return std::string("CALL ") + CC[y] + "," + hex4(nn);
    }
    if (z == 5) {
        if (q == 0) {
            return std::string("PUSH ") + ((p == 2 && index != nullptr) ? index : RP2[p]);
        }
        if (p == 0) {
            uint16_t nn = c.word(read);
            return "CALL " + hex4(nn);
        }
        if (p == 1) {
            return decode(c, read, "IX");
        }
        if (p == 2) {
            return decode_ed(c, read);
        }
        return decode(c, read, "IY");
    }
    if (z == 6) {
        uint8_t n = c.byte(read);
        return std::string(ALU[y]) + hex2(n);
    }
    // z == 7
    return "RST " + hex2(uint8_t(y * 8));
}

std::string decode_cb(Cursor& c, const ReadFn& read, const char* index) {
    uint8_t op;
    std::string target;
    if (index != nullptr) {
        int8_t d = int8_t(c.byte(read));
        op = c.byte(read);
        target = indexed(index, d);
    } else {
        op = c.byte(read);
        target = R8[op & 0x07];
    }

    const uint8_t x = uint8_t(op >> 6);
    const uint8_t y = uint8_t((op >> 3) & 0x07);
    const uint8_t z = uint8_t(op & 0x07);

    std::string text;
    if (x == 0) {
        text = std::string(ROT[y]) + target;
    } else if (x == 1) {
        // BIT never writes back, so it has no undocumented copy form.
        return "BIT " + std::to_string(y) + "," + target;
    } else if (x == 2) {
        text = "RES " + std::to_string(y) + "," + target;
    } else {
        text = "SET " + std::to_string(y) + "," + target;
    }

    // DD CB d/FD CB d forms where the low 3 bits aren't the (IX+d) slot itself
    // are undocumented: they also copy the result into R[z].
    if (index != nullptr && z != 6) {
        text += ",";
        text += R8[z];
    }
    return text;
}

std::string decode_ed(Cursor& c, const ReadFn& read) {
    uint8_t op = c.byte(read);
    const uint8_t x = uint8_t(op >> 6);
    const uint8_t y = uint8_t((op >> 3) & 0x07);
    const uint8_t z = uint8_t(op & 0x07);
    const uint8_t p = uint8_t(y >> 1);
    const uint8_t q = uint8_t(y & 0x01);

    if (x == 1) {
        if (z == 0) {
            return y == 6 ? "IN (C)" : "IN " + std::string(R8[y]) + ",(C)";
        }
        if (z == 1) {
            return y == 6 ? "OUT (C),0" : "OUT (C)," + std::string(R8[y]);
        }
        if (z == 2) {
            return std::string(q == 0 ? "SBC" : "ADC") + " HL," + RP[p];
        }
        if (z == 3) {
            uint16_t nn = c.word(read);
            if (q == 0) {
                return "LD (" + hex4(nn) + ")," + RP[p];
            }
            return "LD " + std::string(RP[p]) + ",(" + hex4(nn) + ")";
        }
        if (z == 4) {
            return "NEG";
        }
        if (z == 5) {
            return y == 1 ? "RETI" : "RETN";
        }
        if (z == 6) {
            return "IM " + std::to_string(IM_MODE[y]);
        }
        if (z == 7) {
            static const char* const SPECIAL[8] = {"LD I,A", "LD R,A", "LD A,I", "LD A,R",
                                                   "RRD",    "RLD",    "NOP",    "NOP"};
            return SPECIAL[y];
        }
    }

    if (x == 2 && z <= 3 && y >= 4) {
        return block_name(z, y);
    }

    return "DEFB 0xED," + hex2(op);
}

} // namespace

Instruction disassemble_one(const ReadFn& read, uint16_t addr) {
    Cursor c(addr);
    Instruction inst;
    inst.addr = addr;
    inst.text = decode(c, read, nullptr);
    inst.length = c.length();
    for (uint8_t i = 0; i < inst.length; i++) {
        inst.raw.push_back(read(uint16_t(addr + i)));
    }
    return inst;
}

std::vector<Instruction> disassemble_range(const ReadFn& read, uint16_t addr, size_t count) {
    std::vector<Instruction> out;
    out.reserve(count);
    uint16_t a = addr;
    for (size_t i = 0; i < count; i++) {
        Instruction inst = disassemble_one(read, a);
        a = uint16_t(a + inst.length);
        out.push_back(std::move(inst));
    }
    return out;
}

} // namespace zx
