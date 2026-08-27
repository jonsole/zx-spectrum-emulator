#pragma once
// Z80 register file, including the shadow (alternate) set and the two index
// registers. Ported from rust-core/zx-core/src/registers.rs.
//
// Flags are kept as a raw byte (`f`) rather than individual bools, matching
// how the real hardware treats it -- bit layout is in flags.h.
//
// AF/BC/DE/HL (and their shadows) are stored as separate 8-bit halves with
// 16-bit accessors on top; IX/IY/SP/PC/WZ are stored as 16-bit words with
// 8-bit accessors on top. That split looks arbitrary but is deliberate: it
// matches which halves instructions actually address individually, and keeps
// the generated dispatch code's register substitution simple.

#include <cstdint>

namespace zx {

struct Registers {
    uint8_t a = 0;
    uint8_t f = 0;
    uint8_t b = 0;
    uint8_t c = 0;
    uint8_t d = 0;
    uint8_t e = 0;
    uint8_t h = 0;
    uint8_t l = 0;

    // Shadow set (EX AF,AF' / EXX swap these).
    uint8_t a_ = 0;
    uint8_t f_ = 0;
    uint8_t b_ = 0;
    uint8_t c_ = 0;
    uint8_t d_ = 0;
    uint8_t e_ = 0;
    uint8_t h_ = 0;
    uint8_t l_ = 0;

    uint16_t ix = 0;
    uint16_t iy = 0;
    uint16_t sp = 0;
    uint16_t pc = 0;

    uint8_t i = 0;
    uint8_t r = 0;
    bool iff1 = false;
    bool iff2 = false;
    uint8_t im = 0;

    /// The internal "MEMPTR" register -- undocumented and not directly
    /// readable by any instruction, but written as a side effect by JP/CALL/
    /// RET, the block instructions, indirect loads and others, and it feeds
    /// several undocumented flag bits (notably CB-prefixed BIT on (HL)).
    uint16_t wz = 0;

    // ---- 16-bit views over the 8-bit halves --------------------------------
    uint16_t af() const { return static_cast<uint16_t>((a << 8) | f); }
    void set_af(uint16_t v) { a = static_cast<uint8_t>(v >> 8); f = static_cast<uint8_t>(v); }

    uint16_t bc() const { return static_cast<uint16_t>((b << 8) | c); }
    void set_bc(uint16_t v) { b = static_cast<uint8_t>(v >> 8); c = static_cast<uint8_t>(v); }

    uint16_t de() const { return static_cast<uint16_t>((d << 8) | e); }
    void set_de(uint16_t v) { d = static_cast<uint8_t>(v >> 8); e = static_cast<uint8_t>(v); }

    uint16_t hl() const { return static_cast<uint16_t>((h << 8) | l); }
    void set_hl(uint16_t v) { h = static_cast<uint8_t>(v >> 8); l = static_cast<uint8_t>(v); }

    // ---- 8-bit views over the 16-bit words ---------------------------------
    uint8_t wzl() const { return static_cast<uint8_t>(wz); }
    void set_wzl(uint8_t v) { wz = static_cast<uint16_t>((wz & 0xFF00) | v); }
    uint8_t wzh() const { return static_cast<uint8_t>(wz >> 8); }
    void set_wzh(uint8_t v) { wz = static_cast<uint16_t>((wz & 0x00FF) | (v << 8)); }

    uint8_t spl() const { return static_cast<uint8_t>(sp); }
    void set_spl(uint8_t v) { sp = static_cast<uint16_t>((sp & 0xFF00) | v); }
    uint8_t sph() const { return static_cast<uint8_t>(sp >> 8); }
    void set_sph(uint8_t v) { sp = static_cast<uint16_t>((sp & 0x00FF) | (v << 8)); }

    uint8_t ixh() const { return static_cast<uint8_t>(ix >> 8); }
    void set_ixh(uint8_t v) { ix = static_cast<uint16_t>((ix & 0x00FF) | (v << 8)); }
    uint8_t ixl() const { return static_cast<uint8_t>(ix); }
    void set_ixl(uint8_t v) { ix = static_cast<uint16_t>((ix & 0xFF00) | v); }

    uint8_t iyh() const { return static_cast<uint8_t>(iy >> 8); }
    void set_iyh(uint8_t v) { iy = static_cast<uint16_t>((iy & 0x00FF) | (v << 8)); }
    uint8_t iyl() const { return static_cast<uint8_t>(iy); }
    void set_iyl(uint8_t v) { iy = static_cast<uint16_t>((iy & 0xFF00) | v); }
};

inline bool operator==(const Registers& x, const Registers& y) {
    return x.a == y.a && x.f == y.f && x.b == y.b && x.c == y.c
        && x.d == y.d && x.e == y.e && x.h == y.h && x.l == y.l
        && x.a_ == y.a_ && x.f_ == y.f_ && x.b_ == y.b_ && x.c_ == y.c_
        && x.d_ == y.d_ && x.e_ == y.e_ && x.h_ == y.h_ && x.l_ == y.l_
        && x.ix == y.ix && x.iy == y.iy && x.sp == y.sp && x.pc == y.pc
        && x.i == y.i && x.r == y.r && x.iff1 == y.iff1 && x.iff2 == y.iff2
        && x.im == y.im && x.wz == y.wz;
}

inline bool operator!=(const Registers& x, const Registers& y) { return !(x == y); }

} // namespace zx
