#include "snapshot.h"

namespace zx {
namespace {

constexpr uint16_t word(uint8_t lo, uint8_t hi) {
    return uint16_t(lo | (hi << 8));
}

} // namespace

std::string load_sna(Spectrum48K& m, const uint8_t* data, size_t len) {
    if (len != SNA_48K_SIZE) {
        return "a 48K .sna must be exactly " + std::to_string(SNA_48K_SIZE)
             + " bytes, got " + std::to_string(len);
    }

    const uint8_t* h = data;
    const uint8_t* ram = data + SNA_HEADER_SIZE;

    Registers r;
    r.i = h[0];
    r.l_ = h[1];  r.h_ = h[2];
    r.e_ = h[3];  r.d_ = h[4];
    r.c_ = h[5];  r.b_ = h[6];
    r.f_ = h[7];  r.a_ = h[8];
    r.l = h[9];   r.h = h[10];
    r.e = h[11];  r.d = h[12];
    r.c = h[13];  r.b = h[14];
    r.iy = word(h[15], h[16]);
    r.ix = word(h[17], h[18]);
    // Bit 2 of byte 19 holds IFF2; IFF1 is not stored separately, so both
    // take that value.
    r.iff1 = r.iff2 = (h[19] & 0x04) != 0;
    r.r = h[20];
    r.f = h[21];
    r.a = h[22];
    const uint16_t sp = word(h[23], h[24]);
    r.im = h[25];
    const uint8_t border = uint8_t(h[26] & 0x07);

    // Pop PC off the stack -- the format's defining quirk (see snapshot.h).
    const size_t stack_offset = size_t(sp) - ROM_SIZE;
    if (sp < ROM_SIZE || stack_offset + 1 >= RAM_SIZE) {
        char buf[96];
        std::snprintf(buf, sizeof buf,
                      ".sna SP=0x%04X does not point into RAM, so PC cannot be popped", sp);
        return buf;
    }
    r.pc = word(ram[stack_offset], ram[stack_offset + 1]);
    r.sp = uint16_t(sp + 2);

    for (size_t i = 0; i < RAM_SIZE; i++) {
        m.memory.ram[i] = ram[i];
    }
    m.set_registers(r); // also clears the call stack
    m.ula.border = border;
    return {};
}

} // namespace zx
