#include "register_names.h"

#include <cctype>

namespace zx {
namespace {

/// Upper-cased, with a trailing underscore turned into the prime that the
/// Z80 documentation uses for the shadow set.
std::string canonical(const std::string& name) {
    std::string out;
    for (char c : name) {
        out.push_back(char(std::toupper(uint8_t(c))));
    }
    if (!out.empty() && out.back() == '_') {
        out.back() = '\'';
    }
    return out;
}

struct Byte {
    const char* name;
    uint8_t Registers::*field;
};

const Byte BYTES[] = {
    {"A", &Registers::a},   {"F", &Registers::f},   {"B", &Registers::b},   {"C", &Registers::c},
    {"D", &Registers::d},   {"E", &Registers::e},   {"H", &Registers::h},   {"L", &Registers::l},
    {"A'", &Registers::a_}, {"F'", &Registers::f_}, {"B'", &Registers::b_}, {"C'", &Registers::c_},
    {"D'", &Registers::d_}, {"E'", &Registers::e_}, {"H'", &Registers::h_}, {"L'", &Registers::l_},
    {"I", &Registers::i},   {"R", &Registers::r},
};

struct Word {
    const char* name;
    uint16_t Registers::*field;
};

const Word WORDS[] = {
    {"IX", &Registers::ix}, {"IY", &Registers::iy}, {"SP", &Registers::sp},
    {"PC", &Registers::pc}, {"WZ", &Registers::wz},
};

/// A 16-bit view made of two 8-bit fields: the main and shadow pairs, and
/// the index registers' halves the other way round.
struct Pair {
    const char* name;
    uint8_t Registers::*hi;
    uint8_t Registers::*lo;
};

const Pair PAIRS[] = {
    {"AF", &Registers::a, &Registers::f},     {"BC", &Registers::b, &Registers::c},
    {"DE", &Registers::d, &Registers::e},     {"HL", &Registers::h, &Registers::l},
    {"AF'", &Registers::a_, &Registers::f_},  {"BC'", &Registers::b_, &Registers::c_},
    {"DE'", &Registers::d_, &Registers::e_},  {"HL'", &Registers::h_, &Registers::l_},
};

struct Half {
    const char* name;
    uint16_t Registers::*field;
    bool high;
};

const Half HALVES[] = {
    {"IXH", &Registers::ix, true}, {"IXL", &Registers::ix, false},
    {"IYH", &Registers::iy, true}, {"IYL", &Registers::iy, false},
};

} // namespace

int register_width(const std::string& raw) {
    const std::string name = canonical(raw);
    for (const Byte& b : BYTES) {
        if (name == b.name) {
            return 8;
        }
    }
    for (const Half& h : HALVES) {
        if (name == h.name) {
            return 8;
        }
    }
    for (const Word& w : WORDS) {
        if (name == w.name) {
            return 16;
        }
    }
    for (const Pair& p : PAIRS) {
        if (name == p.name) {
            return 16;
        }
    }
    if (name == "IFF1" || name == "IFF2") {
        return 1;
    }
    if (name == "IM") {
        return 2;
    }
    return 0;
}

bool set_register(Registers& r, const std::string& raw, uint32_t value, std::string& error) {
    const std::string name = canonical(raw);
    const int width = register_width(name);
    if (width == 0) {
        error = "\"" + raw + "\" is not a register";
        return false;
    }
    const uint32_t limit = width == 8 ? 0xFF : width == 16 ? 0xFFFF : width == 1 ? 1 : 2;
    if (value > limit) {
        error = name + " is " + std::to_string(width) + " bits wide";
        if (width == 1) {
            error = name + " is a flip-flop: 0 or 1";
        } else if (width == 2) {
            error = name + " is an interrupt mode: 0, 1 or 2";
        }
        return false;
    }
    for (const Byte& b : BYTES) {
        if (name == b.name) {
            r.*b.field = uint8_t(value);
            return true;
        }
    }
    for (const Half& h : HALVES) {
        if (name == h.name) {
            const uint16_t old = r.*h.field;
            r.*h.field = h.high ? uint16_t((value << 8) | (old & 0xFF))
                                : uint16_t((old & 0xFF00) | value);
            return true;
        }
    }
    for (const Word& w : WORDS) {
        if (name == w.name) {
            r.*w.field = uint16_t(value);
            return true;
        }
    }
    for (const Pair& p : PAIRS) {
        if (name == p.name) {
            r.*p.hi = uint8_t(value >> 8);
            r.*p.lo = uint8_t(value);
            return true;
        }
    }
    if (name == "IFF1") {
        r.iff1 = value != 0;
        return true;
    }
    if (name == "IFF2") {
        r.iff2 = value != 0;
        return true;
    }
    r.im = uint8_t(value);
    return true;
}

bool set_flag(Registers& r, const std::string& raw, bool value, std::string& error) {
    const std::string name = canonical(raw);
    uint8_t mask = 0;
    if (name == "S") {
        mask = 0x80;
    } else if (name == "Z") {
        mask = 0x40;
    } else if (name == "H") {
        mask = 0x10;
    } else if (name == "P/V" || name == "PV" || name == "P" || name == "V") {
        mask = 0x04;
    } else if (name == "N") {
        mask = 0x02;
    } else if (name == "C") {
        mask = 0x01;
    } else {
        error = "\"" + raw + "\" is not a flag (S, Z, H, P/V, N or C)";
        return false;
    }
    r.f = value ? uint8_t(r.f | mask) : uint8_t(r.f & ~mask);
    return true;
}

} // namespace zx
