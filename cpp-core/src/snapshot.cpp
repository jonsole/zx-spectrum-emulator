#include "snapshot.h"

#include <cstdio>

namespace zx {
namespace {

constexpr uint16_t word(uint8_t lo, uint8_t hi) {
    return uint16_t(lo | (hi << 8));
}

void put_word(uint8_t* p, uint16_t v) {
    p[0] = uint8_t(v);
    p[1] = uint8_t(v >> 8);
}

std::string format_error(const char* fmt, unsigned value) {
    char buf[128];
    std::snprintf(buf, sizeof buf, fmt, value);
    return buf;
}

// ---- .sna ------------------------------------------------------------------

/// The 27-byte header both .sna sizes share. SP is returned separately
/// because the two variants treat it differently.
void read_sna_header(const uint8_t* h, Registers& r, uint16_t& sp, uint8_t& border) {
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
    sp = word(h[23], h[24]);
    r.im = h[25];
    border = uint8_t(h[26] & 0x07);
}

void write_sna_header(uint8_t* h, const Registers& r, uint16_t sp, uint8_t border) {
    h[0] = r.i;
    h[1] = r.l_;  h[2] = r.h_;
    h[3] = r.e_;  h[4] = r.d_;
    h[5] = r.c_;  h[6] = r.b_;
    h[7] = r.f_;  h[8] = r.a_;
    h[9] = r.l;   h[10] = r.h;
    h[11] = r.e;  h[12] = r.d;
    h[13] = r.c;  h[14] = r.b;
    put_word(h + 15, r.iy);
    put_word(h + 17, r.ix);
    h[19] = r.iff2 ? 0x04 : 0x00;
    h[20] = r.r;
    h[21] = r.f;
    h[22] = r.a;
    put_word(h + 23, sp);
    h[25] = r.im;
    h[26] = uint8_t(border & 0x07);
}

void copy_bank(std::array<uint8_t, BANK_SIZE>& bank, const uint8_t* from) {
    for (size_t i = 0; i < BANK_SIZE; i++) {
        bank[i] = from[i];
    }
}

void copy_bank_out(uint8_t* to, const std::array<uint8_t, BANK_SIZE>& bank) {
    for (size_t i = 0; i < BANK_SIZE; i++) {
        to[i] = bank[i];
    }
}

std::string load_sna_48k(Spectrum& m, const uint8_t* data) {
    const uint8_t* h = data;
    const uint8_t* ram = data + SNA_HEADER_SIZE;

    Registers r;
    uint16_t sp = 0;
    uint8_t border = 0;
    read_sna_header(h, r, sp, border);

    // Pop PC off the stack -- the format's defining quirk (see snapshot.h).
    const size_t stack_offset = size_t(sp) - ROM_SIZE;
    if (sp < ROM_SIZE || stack_offset + 1 >= RAM_SIZE) {
        return format_error(".sna SP=0x%04X does not point into RAM, so PC cannot be popped", sp);
    }
    r.pc = word(ram[stack_offset], ram[stack_offset + 1]);
    r.sp = uint16_t(sp + 2);

    if (m.model() != Model::Spectrum48) {
        m.set_model(Model::Spectrum48);
    }
    for (size_t i = 0; i < RAM_SIZE; i++) {
        m.memory.ram48(i) = ram[i];
    }
    m.set_registers(r); // also clears the call stack
    m.ula.border = border;
    return {};
}

std::string load_sna_128k(Spectrum& m, const uint8_t* data, size_t len) {
    const uint8_t* h = data;
    const uint8_t* ram = data + SNA_HEADER_SIZE;
    const uint8_t* trailer = ram + RAM_SIZE;
    const uint8_t* rest = trailer + SNA_128K_TRAILER;

    Registers r;
    uint16_t sp = 0;
    uint8_t border = 0;
    read_sna_header(h, r, sp, border);
    // The 128K variant carries PC itself; SP is exactly what it says.
    r.pc = word(trailer[0], trailer[1]);
    r.sp = sp;
    const uint8_t paging = trailer[2];
    const uint8_t paged = uint8_t(paging & PAGING_BANK_MASK);

    // The 48K part is banks 5 and 2 and then whichever bank the paging
    // register has at 0xC000. If that is 5 or 2 the file holds all six other
    // banks after the trailer; otherwise the five that are neither.
    const bool six = paged == BANK_AT_4000 || paged == BANK_AT_8000;
    const size_t expected = six ? SNA_128K_SIZE_6 : SNA_128K_SIZE;
    if (len != expected) {
        return "a 128K .sna with bank " + std::to_string(paged) + " paged at 0xC000 must be "
               + std::to_string(expected) + " bytes, got " + std::to_string(len);
    }

    if (m.model() != Model::Spectrum128) {
        m.set_model(Model::Spectrum128);
    }
    copy_bank(m.memory.bank[BANK_AT_4000], ram);
    copy_bank(m.memory.bank[BANK_AT_8000], ram + BANK_SIZE);
    copy_bank(m.memory.bank[paged], ram + 2 * BANK_SIZE);
    for (uint8_t b = 0; b < RAM_BANKS; b++) {
        if (b == BANK_AT_4000 || b == BANK_AT_8000 || (!six && b == paged)) {
            continue;
        }
        copy_bank(m.memory.bank[b], rest);
        rest += BANK_SIZE;
    }
    // Through the port rather than straight into the map, so the ULA learns
    // which screen it is showing. The lock bit is honoured on the way in --
    // a locked snapshot stays locked -- because paging starts from the reset
    // set_model just did.
    m.write_paging(paging);
    m.set_registers(r);
    m.ula.border = border;
    return {};
}

// ---- .z80 ------------------------------------------------------------------

constexpr size_t Z80_HEADER_SIZE = 30;
constexpr size_t Z80_V2_EXTRA = 23;
constexpr size_t Z80_V3_EXTRA = 54;
/// Marks an uncompressed 16K page in a version 2/3 block header.
constexpr uint16_t Z80_UNCOMPRESSED = 0xFFFF;

/// The hardware-mode byte of a version 2 or 3 header. Every value from the
/// 128K up is loaded as a 128K -- see load_z80 in the header.
bool z80_mode_is_128k(int version, uint8_t mode) {
    return version == 2 ? mode >= 3 : mode >= 4;
}

/// The RAM bank a version 2/3 page number names, or NO_BANK for a ROM page
/// or anything else the emulator has no home for.
uint8_t z80_page_bank(bool is128, uint8_t page) {
    if (is128) {
        return page >= 3 && page <= 10 ? uint8_t(page - 3) : NO_BANK;
    }
    if (page == 4) return BANK_AT_8000;
    if (page == 5) return DEFAULT_BANK_AT_C000;
    if (page == 8) return BANK_AT_4000;
    return NO_BANK;
}

/// The page number a bank is written out under.
uint8_t z80_bank_page(bool is128, uint8_t bank) {
    if (is128) {
        return uint8_t(bank + 3);
    }
    if (bank == BANK_AT_8000) return 4;
    if (bank == DEFAULT_BANK_AT_C000) return 5;
    return 8;
}

/// Expands the format's run-length coding: ED ED nn vv is vv repeated nn
/// times; anything else is literal, including a lone ED. Reads at most `len`
/// input bytes and stops once `out` holds `want`; returns how many input
/// bytes were used.
size_t z80_decompress(const uint8_t* in, size_t len, uint8_t* out, size_t want) {
    size_t i = 0;
    size_t o = 0;
    while (i < len && o < want) {
        if (in[i] == 0xED && i + 3 < len && in[i + 1] == 0xED) {
            const size_t n = in[i + 2];
            const uint8_t v = in[i + 3];
            for (size_t k = 0; k < n && o < want; k++) {
                out[o++] = v;
            }
            i += 4;
        } else {
            out[o++] = in[i++];
        }
    }
    return i;
}

/// The inverse. A run of five or more of any byte, or two or more of ED, is
/// coded; a lone ED is written literally along with the byte after it, so a
/// decoder can never mistake the pair for a run marker.
void z80_compress(const uint8_t* in, size_t len, std::vector<uint8_t>& out) {
    size_t i = 0;
    while (i < len) {
        const uint8_t b = in[i];
        size_t run = 1;
        while (i + run < len && in[i + run] == b && run < 255) {
            run++;
        }
        if (run >= 5 || (b == 0xED && run >= 2)) {
            out.push_back(0xED);
            out.push_back(0xED);
            out.push_back(uint8_t(run));
            out.push_back(b);
            i += run;
        } else if (b == 0xED) {
            out.push_back(b);
            i++;
            if (i < len) {
                out.push_back(in[i]);
                i++;
            }
        } else {
            out.push_back(b);
            i++;
        }
    }
}

std::string read_z80_header(const uint8_t* data, size_t len, SnapshotInfo& info, Registers& r,
                            uint8_t& border, bool& v1_compressed, size_t& body) {
    if (len < Z80_HEADER_SIZE) {
        return "a .z80 needs at least a 30-byte header, got " + std::to_string(len) + " bytes";
    }
    const uint8_t* h = data;
    r.a = h[0];
    r.f = h[1];
    r.set_bc(word(h[2], h[3]));
    r.set_hl(word(h[4], h[5]));
    r.pc = word(h[6], h[7]);
    r.sp = word(h[8], h[9]);
    r.i = h[10];
    // Byte 12 holds bit 7 of R, the border and (version 1) the compressed
    // flag. A value of 255 is to be read as 1, per the format's own note.
    uint8_t flags = h[12] == 0xFF ? uint8_t(1) : h[12];
    r.r = uint8_t((h[11] & 0x7F) | ((flags & 0x01) << 7));
    border = uint8_t((flags >> 1) & 0x07);
    v1_compressed = (flags & 0x20) != 0;
    r.set_de(word(h[13], h[14]));
    r.c_ = h[15];  r.b_ = h[16];
    r.e_ = h[17];  r.d_ = h[18];
    r.l_ = h[19];  r.h_ = h[20];
    r.a_ = h[21];
    r.f_ = h[22];
    r.iy = word(h[23], h[24]);
    r.ix = word(h[25], h[26]);
    r.iff1 = h[27] != 0;
    r.iff2 = h[28] != 0;
    r.im = uint8_t(h[29] & 0x03);

    info.format = SnapshotFormat::Z80;
    if (r.pc != 0) {
        info.version = 1;
        info.model = Model::Spectrum48;
        info.pc = r.pc;
        body = Z80_HEADER_SIZE;
        return {};
    }
    if (len < Z80_HEADER_SIZE + 2) {
        return "a version 2/3 .z80 is missing its extended header";
    }
    const size_t extra = word(h[30], h[31]);
    if (extra == Z80_V2_EXTRA) {
        info.version = 2;
    } else if (extra == Z80_V3_EXTRA || extra == Z80_V3_EXTRA + 1) {
        info.version = 3;
    } else {
        return format_error(".z80 extended header length %u is not one this loader knows",
                            unsigned(extra));
    }
    body = Z80_HEADER_SIZE + 2 + extra;
    if (len < body) {
        return "a .z80's extended header runs past the end of the file";
    }
    r.pc = word(h[32], h[33]);
    info.pc = r.pc;
    info.model = z80_mode_is_128k(info.version, h[34]) ? Model::Spectrum128 : Model::Spectrum48;
    return {};
}

} // namespace

std::string inspect_snapshot(const uint8_t* data, size_t len, SnapshotInfo& info) {
    if (len == SNA_48K_SIZE || len == SNA_128K_SIZE || len == SNA_128K_SIZE_6) {
        info.format = SnapshotFormat::Sna;
        info.version = 0;
        if (len == SNA_48K_SIZE) {
            info.model = Model::Spectrum48;
            const uint16_t sp = word(data[23], data[24]);
            const size_t offset = size_t(sp) - ROM_SIZE;
            if (sp < ROM_SIZE || offset + 1 >= RAM_SIZE) {
                return format_error(".sna SP=0x%04X does not point into RAM, so PC cannot be popped",
                                    sp);
            }
            info.pc = word(data[SNA_HEADER_SIZE + offset], data[SNA_HEADER_SIZE + offset + 1]);
        } else {
            info.model = Model::Spectrum128;
            const uint8_t* trailer = data + SNA_48K_SIZE;
            info.pc = word(trailer[0], trailer[1]);
        }
        return {};
    }
    Registers r;
    uint8_t border = 0;
    bool compressed = false;
    size_t body = 0;
    return read_z80_header(data, len, info, r, border, compressed, body);
}

std::string load_snapshot(Spectrum& m, const uint8_t* data, size_t len) {
    if (len == SNA_48K_SIZE || len == SNA_128K_SIZE || len == SNA_128K_SIZE_6) {
        return load_sna(m, data, len);
    }
    return load_z80(m, data, len);
}

std::string load_sna(Spectrum& m, const uint8_t* data, size_t len) {
    if (len == SNA_48K_SIZE) {
        return load_sna_48k(m, data);
    }
    if (len == SNA_128K_SIZE || len == SNA_128K_SIZE_6) {
        return load_sna_128k(m, data, len);
    }
    return "a .sna must be exactly " + std::to_string(SNA_48K_SIZE) + " bytes (48K), "
           + std::to_string(SNA_128K_SIZE) + " or " + std::to_string(SNA_128K_SIZE_6)
           + " bytes (128K), got " + std::to_string(len);
}

std::string save_sna(const Spectrum& m, std::vector<uint8_t>& out) {
    const Registers r = m.registers();

    if (m.model() == Model::Spectrum128) {
        const uint8_t paging = m.memory.paging();
        const uint8_t paged = uint8_t(paging & PAGING_BANK_MASK);
        const bool six = paged == BANK_AT_4000 || paged == BANK_AT_8000;
        out.assign(six ? SNA_128K_SIZE_6 : SNA_128K_SIZE, 0);
        write_sna_header(out.data(), r, r.sp, m.ula.border);
        uint8_t* ram = out.data() + SNA_HEADER_SIZE;
        copy_bank_out(ram, m.memory.bank[BANK_AT_4000]);
        copy_bank_out(ram + BANK_SIZE, m.memory.bank[BANK_AT_8000]);
        copy_bank_out(ram + 2 * BANK_SIZE, m.memory.bank[paged]);
        uint8_t* trailer = ram + RAM_SIZE;
        put_word(trailer, r.pc);
        trailer[2] = paging;
        trailer[3] = 0; // TR-DOS not paged: there is no TR-DOS here
        uint8_t* rest = trailer + SNA_128K_TRAILER;
        for (uint8_t b = 0; b < RAM_BANKS; b++) {
            if (b == BANK_AT_4000 || b == BANK_AT_8000 || (!six && b == paged)) {
                continue;
            }
            copy_bank_out(rest, m.memory.bank[b]);
            rest += BANK_SIZE;
        }
        return {};
    }

    // PC goes on the stack, so SP has to have two bytes of RAM below it.
    const uint16_t sp = uint16_t(r.sp - 2);
    const size_t stack_offset = size_t(sp) - ROM_SIZE;
    if (sp < ROM_SIZE || r.sp < ROM_SIZE + 2 || stack_offset + 1 >= RAM_SIZE) {
        return format_error("SP=0x%04X leaves no RAM to push PC onto, so a .sna cannot be saved",
                            r.sp);
    }

    out.assign(SNA_48K_SIZE, 0);
    write_sna_header(out.data(), r, sp, m.ula.border);
    uint8_t* ram = out.data() + SNA_HEADER_SIZE;
    for (size_t i = 0; i < RAM_SIZE; i++) {
        ram[i] = m.memory.ram48(i);
    }
    put_word(ram + stack_offset, r.pc);
    return {};
}

std::string load_z80(Spectrum& m, const uint8_t* data, size_t len) {
    SnapshotInfo info;
    Registers r;
    uint8_t border = 0;
    bool v1_compressed = false;
    size_t body = 0;
    const std::string error = read_z80_header(data, len, info, r, border, v1_compressed, body);
    if (!error.empty()) {
        return error;
    }
    const uint8_t* h = data;
    const bool is128 = info.model == Model::Spectrum128;

    // The pages are decoded into a scratch set before the machine is touched
    // at all, so a truncated or malformed file leaves it exactly as it was.
    std::array<std::array<uint8_t, BANK_SIZE>, RAM_BANKS> banks{};
    bool loaded[RAM_BANKS] = {false, false, false, false, false, false, false, false};

    if (info.version == 1) {
        // One 48K block, the whole of RAM from 0x4000 up, compressed or not.
        std::vector<uint8_t> ram(RAM_SIZE, 0);
        if (v1_compressed) {
            z80_decompress(data + body, len - body, ram.data(), RAM_SIZE);
        } else {
            if (len - body < RAM_SIZE) {
                return "an uncompressed version 1 .z80 needs 48K of RAM after its header, got "
                       + std::to_string(len - body) + " bytes";
            }
            for (size_t i = 0; i < RAM_SIZE; i++) {
                ram[i] = data[body + i];
            }
        }
        const uint8_t order[3] = {BANK_AT_4000, BANK_AT_8000, DEFAULT_BANK_AT_C000};
        for (size_t p = 0; p < 3; p++) {
            for (size_t i = 0; i < BANK_SIZE; i++) {
                banks[order[p]][i] = ram[p * BANK_SIZE + i];
            }
            loaded[order[p]] = true;
        }
    } else {
        size_t pos = body;
        while (pos + 3 <= len) {
            const uint16_t block_len = word(data[pos], data[pos + 1]);
            const uint8_t page = data[pos + 2];
            pos += 3;
            const uint8_t bank = z80_page_bank(is128, page);
            if (block_len == Z80_UNCOMPRESSED) {
                if (pos + BANK_SIZE > len) {
                    return "a .z80 page runs past the end of the file";
                }
                if (bank != NO_BANK) {
                    copy_bank(banks[bank], data + pos);
                    loaded[bank] = true;
                }
                pos += BANK_SIZE;
            } else {
                if (pos + block_len > len) {
                    return "a .z80 page runs past the end of the file";
                }
                if (bank != NO_BANK) {
                    z80_decompress(data + pos, block_len, banks[bank].data(), BANK_SIZE);
                    loaded[bank] = true;
                }
                pos += block_len;
            }
        }
    }

    if (m.model() != info.model) {
        m.set_model(info.model);
    }
    for (uint8_t b = 0; b < RAM_BANKS; b++) {
        if (loaded[b]) {
            m.memory.bank[b] = banks[b];
        }
    }
    if (is128) {
        m.write_paging(h[35]);
        // Byte 38 is the last OUT to 0xFFFD (the selected register) and
        // 39-54 the sixteen registers. Restored register by register rather
        // than through write(), so the envelope is not retriggered sixteen
        // times over.
        for (uint8_t i = 0; i < AY_REGISTERS; i++) {
            m.ay.set_reg(i, h[39 + i]);
        }
        m.ay.select(h[38]);
    }
    m.set_registers(r);
    m.ula.border = border;
    return {};
}

void save_z80(const Spectrum& m, std::vector<uint8_t>& out) {
    const Registers r = m.registers();
    const bool is128 = m.model() == Model::Spectrum128;

    out.assign(Z80_HEADER_SIZE + 2 + Z80_V3_EXTRA, 0);
    uint8_t* h = out.data();
    h[0] = r.a;
    h[1] = r.f;
    put_word(h + 2, r.bc());
    put_word(h + 4, r.hl());
    put_word(h + 6, 0); // PC of 0 marks a version 2/3 header
    put_word(h + 8, r.sp);
    h[10] = r.i;
    h[11] = uint8_t(r.r & 0x7F);
    h[12] = uint8_t(((r.r >> 7) & 0x01) | ((m.ula.border & 0x07) << 1));
    put_word(h + 13, r.de());
    h[15] = r.c_;  h[16] = r.b_;
    h[17] = r.e_;  h[18] = r.d_;
    h[19] = r.l_;  h[20] = r.h_;
    h[21] = r.a_;
    h[22] = r.f_;
    put_word(h + 23, r.iy);
    put_word(h + 25, r.ix);
    h[27] = r.iff1 ? 1 : 0;
    h[28] = r.iff2 ? 1 : 0;
    h[29] = uint8_t(r.im & 0x03);
    put_word(h + 30, uint16_t(Z80_V3_EXTRA));
    put_word(h + 32, r.pc);
    h[34] = is128 ? 4 : 0; // version 3 hardware mode: 128K or 48K
    if (is128) {
        h[35] = m.memory.paging();
        h[38] = m.ay.selected();
        for (uint8_t i = 0; i < AY_REGISTERS; i++) {
            h[39 + i] = m.ay.reg(i);
        }
    }

    std::vector<uint8_t> page;
    for (uint8_t b = 0; b < RAM_BANKS; b++) {
        if (!is128 && b != BANK_AT_4000 && b != BANK_AT_8000 && b != DEFAULT_BANK_AT_C000) {
            continue;
        }
        page.clear();
        z80_compress(m.memory.bank[b].data(), BANK_SIZE, page);
        const size_t at = out.size();
        out.resize(at + 3);
        put_word(out.data() + at, uint16_t(page.size()));
        out[at + 2] = z80_bank_page(is128, b);
        out.insert(out.end(), page.begin(), page.end());
    }
}

} // namespace zx
