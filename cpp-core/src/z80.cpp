#include "z80.h"

#include "alu.h"
#include "flags.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <utility>

namespace zx {
namespace {

/// Opcodes for which a DD/FD prefix means "(IX+d)/(IY+d)" and therefore need
/// the 8-T-state displacement sequence, rather than just substituting IX/IY
/// for HL. Hand-transcribed from vendor/chips/z80.h's _z80_indirect_table.
/// 25 entries; note 0x76 (HALT) is deliberately absent even though its
/// neighbours 0x70-0x77 are present.
constexpr bool DDFD_INDIRECT_TABLE[256] = {
    // 0x00
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
    0,0,0,0, 1,1,1,0, 0,0,0,0, 0,0,0,0,   // 0x34,0x35,0x36
    // 0x40
    0,0,0,0, 0,0,1,0, 0,0,0,0, 0,0,1,0,   // 0x46, 0x4E
    0,0,0,0, 0,0,1,0, 0,0,0,0, 0,0,1,0,   // 0x56, 0x5E
    0,0,0,0, 0,0,1,0, 0,0,0,0, 0,0,1,0,   // 0x66, 0x6E
    1,1,1,1, 1,1,0,1, 0,0,0,0, 0,0,1,0,   // 0x70-0x75,0x77 (0x76=HALT), 0x7E
    // 0x80
    0,0,0,0, 0,0,1,0, 0,0,0,0, 0,0,1,0,   // 0x86, 0x8E
    0,0,0,0, 0,0,1,0, 0,0,0,0, 0,0,1,0,   // 0x96, 0x9E
    0,0,0,0, 0,0,1,0, 0,0,0,0, 0,0,1,0,   // 0xA6, 0xAE
    0,0,0,0, 0,0,1,0, 0,0,0,0, 0,0,1,0,   // 0xB6, 0xBE
    // 0xC0
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
    0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
};

} // namespace

// ============================================================================
// Fetch entry points
// ============================================================================

uint64_t Z80::begin_fetch(uint64_t pins) {
    hlx_idx_ = 0;
    prefix_active_ = false;
    // An IM 0 instruction ends here: PC moves again from this fetch on.
    im0_pc_hold_ = false;

    // NMI and INT are sampled here, before any bus activity, so an accepted
    // interrupt replaces this fetch's T1 rather than racing it. An NMI edge
    // comes first: it cannot be masked and outranks INT.
    if (nmi_pending_) {
        nmi_pending_ = false;
        // Undoes op_halt()'s per-refetch PC decrement, as for INT below.
        if (halted) {
            regs.pc = uint16_t(regs.pc + 1);
        }
        halted = false;
        interrupt_count++;
        nmi_ack_ = true;
        // IFF2 keeps IFF1, so RETN can put it back; IFF1 masks INT.
        regs.iff2 = regs.iff1;
        regs.iff1 = false;
        // T1H of the dummy opcode fetch: PC out, M1 down, PC not moved.
        pins = set_addr_assert(pins, regs.pc, M1);
        step_ = STEP_NMI_T1L;
        return pins;
    }
    if (asserted(pins, INT) && regs.iff1) {
        // Undoes op_halt()'s per-refetch PC decrement. Without this the
        // interrupt would push HALT's own address as the return address and
        // a `HALT; <body>; JP` loop would re-halt forever instead of running
        // <body> -- a real, reproducible hang, not a hypothetical.
        if (halted) {
            regs.pc = uint16_t(regs.pc + 1);
        }
        interrupt_count++;
        // T1H of the acknowledge: PC on the address bus and M1 down, as for
        // an opcode fetch, but no MREQ and PC not moved.
        pins = set_addr_assert(pins, regs.pc, M1);
        step_ = STEP_INT_T1H;
        return pins;
    }

    // T1H: address valid, M1 asserted. MREQ|RD follow at T1L.
    pins = set_addr_assert(pins, pc_post_inc(), M1);
    step_ = STEP_M1_T1L;
    return pins;
}

uint64_t Z80::begin_fetch_ed(uint64_t pins) {
    prefix_active_ = true;
    // Killing hlx_idx_ here makes a pathological `DD ED xx` behave as the
    // hardware does: the ED prefix cancels any pending IX/IY substitution.
    hlx_idx_ = 0;
    pins = set_addr_assert(pins, pc_post_inc(), M1);
    step_ = STEP_ED_M1_T1L;
    return pins;
}

uint64_t Z80::begin_fetch_cb(uint64_t pins) {
    prefix_active_ = true;
    if (hlx_idx_ > 0) {
        // A DD/FD has already been seen, so this is DD CB d / FD CB d. This
        // half-state is T1H of the read of d: d's address goes out now, as
        // any read's does, so the ULA sees it at the T-state's check.
        // prefix_active_ stays set for the whole chain; only the terminal
        // begin_fetch clears it.
        pins = set_addr(pins, pc_post_inc());
        step_ = STEP_DDFDCB_T1H;
        return pins;
    }
    // Deliberately does NOT reset hlx_idx_, unlike begin_fetch_ed.
    pins = set_addr_assert(pins, pc_post_inc(), M1);
    step_ = STEP_CB_M1_T1L;
    return pins;
}

uint64_t Z80::begin_fetch_dd(uint64_t pins) {
    prefix_active_ = true;
    hlx_idx_ = 1;
    pins = set_addr_assert(pins, pc_post_inc(), M1);
    step_ = STEP_DDFD_M1_T1L;
    return pins;
}

uint64_t Z80::begin_fetch_fd(uint64_t pins) {
    prefix_active_ = true;
    hlx_idx_ = 2;
    pins = set_addr_assert(pins, pc_post_inc(), M1);
    step_ = STEP_DDFD_M1_T1L;
    return pins;
}

/// Drives the I:R refresh address with RFSH (MREQ follows at T3L). R is a
/// 7-bit counter: bit 7 is preserved, and the address carries the
/// PRE-increment value.
uint64_t Z80::refresh(uint64_t pins) {
    uint16_t ir = uint16_t((regs.i << 8) | regs.r);
    regs.r = uint8_t((regs.r & 0x80) | ((regs.r + 1) & 0x7F));
    return set_addr_assert(pins, ir, RFSH);
}

uint64_t Z80::op_halt(uint64_t pins) {
    halted = true;
    // Rewinds onto HALT's own address so the next fetch re-reads the same
    // 0x76 byte. begin_fetch's own pc++ undoes this each pass, so PC nets
    // back to the HALT address at rest while R keeps incrementing at the
    // correct 1-per-4-T-states rate.
    regs.pc = uint16_t(regs.pc - 1);
    return begin_fetch(pins);
}

// ============================================================================
// Helpers the generated dispatch calls
// ============================================================================

void Z80::alu_op(uint8_t op, uint8_t val) {
    uint8_t carry = uint8_t(regs.f & FLAG_C);
    switch (op) {
        case 0: { auto r = alu::add8(regs.a, val); regs.a = r.value; regs.f = r.flags; break; }
        case 1: { auto r = alu::adc8(regs.a, val, carry); regs.a = r.value; regs.f = r.flags; break; }
        case 2: { auto r = alu::sub8(regs.a, val); regs.a = r.value; regs.f = r.flags; break; }
        case 3: { auto r = alu::sbc8(regs.a, val, carry); regs.a = r.value; regs.f = r.flags; break; }
        case 4: { auto r = alu::and8(regs.a, val); regs.a = r.value; regs.f = r.flags; break; }
        case 5: { auto r = alu::xor8(regs.a, val); regs.a = r.value; regs.f = r.flags; break; }
        case 6: { auto r = alu::or8(regs.a, val); regs.a = r.value; regs.f = r.flags; break; }
        default: regs.f = alu::cp8(regs.a, val); break; // 7 = CP, no write-back
    }
}

bool Z80::cb_action(uint8_t val, bool is_indirect, uint8_t* out) {
    uint8_t x = uint8_t(opcode_ >> 6);
    uint8_t y = uint8_t((opcode_ >> 3) & 7);
    switch (x) {
        case 0: {
            uint8_t carry = uint8_t(regs.f & FLAG_C);
            alu::Alu8 r{};
            switch (y) {
                case 0: r = alu::rlc(val); break;
                case 1: r = alu::rrc(val); break;
                case 2: r = alu::rl(val, carry); break;
                case 3: r = alu::rr(val, carry); break;
                case 4: r = alu::sla(val); break;
                case 5: r = alu::sra(val); break;
                case 6: r = alu::sll(val); break;
                default: r = alu::srl(val); break;
            }
            regs.f = r.flags;
            *out = r.value;
            return true;
        }
        case 1:
            // BIT writes nothing back -- that is what `false` signals here.
            regs.f = alu::bit(val, y, is_indirect, regs.wz, uint8_t(regs.f & FLAG_C));
            return false;
        case 2:
            *out = alu::res(val, y); // RES/SET touch no flags at all
            return true;
        default:
            *out = alu::set(val, y);
            return true;
    }
}

uint8_t Z80::get_reg8_plain(uint8_t idx) const {
    switch (idx) {
        case 0: return regs.b;
        case 1: return regs.c;
        case 2: return regs.d;
        case 3: return regs.e;
        case 4: return regs.h;
        case 5: return regs.l;
        case 7: return regs.a;
        default: std::abort(); // idx 6 is (HL) -- routed to CBHL_STEP instead
    }
}

void Z80::set_reg8_plain(uint8_t idx, uint8_t value) {
    switch (idx) {
        case 0: regs.b = value; break;
        case 1: regs.c = value; break;
        case 2: regs.d = value; break;
        case 3: regs.e = value; break;
        case 4: regs.h = value; break;
        case 5: regs.l = value; break;
        case 7: regs.a = value; break;
        default: std::abort();
    }
}

uint16_t Z80::hlx() const {
    switch (hlx_idx_) {
        case 0: return regs.hl();
        case 1: return regs.ix;
        default: return regs.iy;
    }
}

void Z80::set_hlx(uint16_t v) {
    switch (hlx_idx_) {
        case 0: regs.set_hl(v); break;
        case 1: regs.ix = v; break;
        default: regs.iy = v; break;
    }
}

uint8_t Z80::hlx_h() const {
    switch (hlx_idx_) {
        case 0: return regs.h;
        case 1: return regs.ixh();
        default: return regs.iyh();
    }
}

void Z80::set_hlx_h(uint8_t v) {
    switch (hlx_idx_) {
        case 0: regs.h = v; break;
        case 1: regs.set_ixh(v); break;
        default: regs.set_iyh(v); break;
    }
}

uint8_t Z80::hlx_l() const {
    switch (hlx_idx_) {
        case 0: return regs.l;
        case 1: return regs.ixl();
        default: return regs.iyl();
    }
}

void Z80::set_hlx_l(uint8_t v) {
    switch (hlx_idx_) {
        case 0: regs.l = v; break;
        case 1: regs.set_ixl(v); break;
        default: regs.set_iyl(v); break;
    }
}

// ============================================================================
// The generated half-state table
// ============================================================================

bool Z80::dispatch_generated(uint64_t& pins) {
    switch (step_) {
#include "generated/dispatch.inc"
        default:
            return false;
    }
}

// ============================================================================
// Public API
// ============================================================================

Registers Z80::registers() const {
    Registers r = regs;
    // Undoes the overlapped fetch's look-ahead. Not applied while halted:
    // op_halt already parks PC where a debugger wants to see it.
    if (!halted) {
        r.pc = uint16_t(r.pc - 1);
    }
    return r;
}

void Z80::set_registers(const Registers& r, Memory& mem) {
    regs = r;
    step_ = 0;
    prefix_active_ = false;
    rfsh_release_ = false;
    nmi_pending_ = false;
    nmi_ack_ = false;
    im0_pc_hold_ = false;
    // One priming half-clock, whose memory request MUST be serviced -- step 0
    // is NOP, whose generated body is begin_fetch(), so this leaves the
    // pipeline at STEP_M1_T1L with a real opcode read in flight. Skipping the
    // service would leave whatever was on the data bus to be read as the
    // next "opcode".
    pins_ = service_memory(mem, clock(PINS_IDLE));
}

uint64_t Z80::service_memory(Memory& mem, uint64_t pins) {
    if (asserted(pins, MREQ)) {
        if (asserted(pins, RD)) {
            return set_data(pins, mem.read(get_addr(pins)));
        }
        if (asserted(pins, WR)) {
            mem.write(get_addr(pins), get_data(pins));
        }
    }
    return pins;
}

uint16_t Z80::step_instruction(Memory& mem) {
    uint64_t pins = service_memory(mem, clock(pins_));
    uint16_t half_clocks = 1;
    while (!is_instruction_boundary()) {
        pins = service_memory(mem, clock(pins));
        half_clocks++;
    }
    pins_ = pins;
    return half_clocks;
}

// ============================================================================
// clock(): one half-T-state
// ============================================================================

uint64_t Z80::clock(uint64_t pins) {
    // NMI is edge-triggered: a falling edge (asserted, in pins.h's terms) is
    // latched whenever it comes, and taken at the next instruction boundary.
    const bool nmi = asserted(pins, NMI);
    if (nmi && !nmi_level_) {
        nmi_pending_ = true;
    }
    nmi_level_ = nmi;

    // RFSH outlives the refresh's MREQ by half a T-state: the real chip lets
    // it go at the start of the next half-clock, whatever that half is, and
    // so does this.
    if (rfsh_release_) {
        pins = release_pins(pins, RFSH);
        rfsh_release_ = false;
    }
    switch (step_) {
        // ---- prefix / HALT opcode entries the generator deliberately skips
        // (see SKIP_NAMES). 0xED is NOT here: the generator emits it itself,
        // via the `prefix: ed` overlapped branch.
        case 0x76: pins = op_halt(pins); break;
        case 0xCB: pins = begin_fetch_cb(pins); break;
        case 0xDD: pins = begin_fetch_dd(pins); break;
        case 0xFD: pins = begin_fetch_fd(pins); break;

        // ---- M1 opcode fetch ------------------------------------------------
        case STEP_M1_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_M1_T2H;
            break;
        case STEP_M1_T2H:
            step_ = STEP_M1_T2L;
            break;
        case STEP_M1_T2L:
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_M1_T3H;
            break;
        case STEP_M1_T3H:
            opcode_ = get_data(pins);
            pins = release_pins(pins, M1 | MREQ | RD);
            pins = refresh(pins);
            step_ = STEP_M1_T3L;
            break;
        case STEP_M1_T3L:
            // Refresh MREQ. This half-state and the next are the window in
            // which the I:R address sits on the bus with MREQ asserted --
            // which is exactly how the "snow" artifact happens on real
            // hardware when I lands in the contended page.
            pins = assert_pins(pins, MREQ);
            step_ = STEP_M1_T4H;
            break;
        case STEP_M1_T4H:
            step_ = STEP_M1_T4L;
            break;
        case STEP_M1_T4L:
            pins = release_pins(pins, MREQ);
            rfsh_release_ = true;
            addr_ = regs.hl();
            prefix_active_ = false;
            step_ = opcode_;
            break;

        // ---- ED prefix second M1 ---------------------------------------------
        case STEP_ED_M1_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_ED_M1_T2H;
            break;
        case STEP_ED_M1_T2H: step_ = STEP_ED_M1_T2L; break;
        case STEP_ED_M1_T2L:
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_ED_M1_T3H;
            break;
        case STEP_ED_M1_T3H:
            opcode_ = get_data(pins);
            pins = release_pins(pins, M1 | MREQ | RD);
            pins = refresh(pins);
            step_ = STEP_ED_M1_T3L;
            break;
        case STEP_ED_M1_T3L: pins = assert_pins(pins, MREQ); step_ = STEP_ED_M1_T4H; break;
        case STEP_ED_M1_T4H: step_ = STEP_ED_M1_T4L; break;
        case STEP_ED_M1_T4L:
            pins = release_pins(pins, MREQ);
            rfsh_release_ = true;
            addr_ = regs.hl();
            prefix_active_ = false;
            step_ = uint16_t(ED_STEP_BASE + opcode_);
            break;

        // ---- CB prefix second M1 ---------------------------------------------
        case STEP_CB_M1_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_CB_M1_T2H;
            break;
        case STEP_CB_M1_T2H: step_ = STEP_CB_M1_T2L; break;
        case STEP_CB_M1_T2L:
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_CB_M1_T3H;
            break;
        case STEP_CB_M1_T3H:
            opcode_ = get_data(pins);
            pins = release_pins(pins, M1 | MREQ | RD);
            pins = refresh(pins);
            step_ = STEP_CB_M1_T3L;
            break;
        case STEP_CB_M1_T3L: pins = assert_pins(pins, MREQ); step_ = STEP_CB_M1_T4H; break;
        case STEP_CB_M1_T4H: step_ = STEP_CB_M1_T4L; break;
        case STEP_CB_M1_T4L:
            pins = release_pins(pins, MREQ);
            rfsh_release_ = true;
            // Load-bearing: without clearing this, step_instruction() would
            // run two instructions per call.
            prefix_active_ = false;
            if ((opcode_ & 7) == 6) {
                addr_ = regs.hl();
                step_ = ZX_CBHL_STEP;
            } else {
                step_ = ZX_CB_STEP;
            }
            break;

        // ---- DD/FD prefix second M1 -------------------------------------------
        case STEP_DDFD_M1_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_DDFD_M1_T2H;
            break;
        case STEP_DDFD_M1_T2H: step_ = STEP_DDFD_M1_T2L; break;
        case STEP_DDFD_M1_T2L:
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_DDFD_M1_T3H;
            break;
        case STEP_DDFD_M1_T3H:
            opcode_ = get_data(pins);
            pins = release_pins(pins, M1 | MREQ | RD);
            pins = refresh(pins);
            step_ = STEP_DDFD_M1_T3L;
            break;
        case STEP_DDFD_M1_T3L: pins = assert_pins(pins, MREQ); step_ = STEP_DDFD_M1_T4H; break;
        case STEP_DDFD_M1_T4H: step_ = STEP_DDFD_M1_T4L; break;
        case STEP_DDFD_M1_T4L:
            pins = release_pins(pins, MREQ);
            rfsh_release_ = true;
            addr_ = hlx();
            prefix_active_ = false;
            // Non-indirect DD/FD ops dispatch into the SAME 0..256 table as
            // unprefixed ones -- only hlx_idx_ makes them mean IX/IY.
            step_ = DDFD_INDIRECT_TABLE[opcode_] ? uint16_t(STEP_DDFD_D_T1H)
                                                 : uint16_t(opcode_);
            break;

        // ---- DD/FD displacement sequence, 8 T-states ---------------------------
        // The published timing is pc+2:3, pc+2:1 x 5 -- a plain memory read of
        // d in T1-T3, then five internal T-states with d's address still on
        // the bus -- or, for LD (IX/IY+d),n, pc+2:3, pc+3:3, pc+3:1 x 2: d,
        // then n, then two internal T-states holding n's address. The internal
        // T-states are where a 48K's ULA contends these instructions, by the
        // address left on the bus, so the reads have the same shape as every
        // other read and the address is not moved until the next cycle needs
        // the bus.
        case STEP_DDFD_D_T1H:
            pins = set_addr(pins, pc_post_inc());
            step_ = STEP_DDFD_D_T1L;
            break;
        case STEP_DDFD_D_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_DDFD_D_T2H;
            break;
        case STEP_DDFD_D_T2H: step_ = STEP_DDFD_D_T2L; break;
        case STEP_DDFD_D_T2L:
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_DDFD_D_T3H;
            break;
        case STEP_DDFD_D_T3H: step_ = STEP_DDFD_D_T3L; break;
        case STEP_DDFD_D_T3L:
            addr_ = uint16_t(addr_ + int8_t(get_data(pins)));
            regs.wz = addr_;
            pins = release_pins(pins, MREQ | RD);
            step_ = STEP_DDFD_D_T4H;
            break;
        case STEP_DDFD_D_T4H:
            // Only LD (IX/IY+d),n has an immediate byte to read here.
            if (opcode_ == 0x36) {
                pins = set_addr(pins, pc_post_inc());
            }
            step_ = STEP_DDFD_D_T4L;
            break;
        case STEP_DDFD_D_T4L:
            if (opcode_ == 0x36) {
                pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            }
            step_ = STEP_DDFD_D_T5H;
            break;
        case STEP_DDFD_D_T5H: step_ = STEP_DDFD_D_T5L; break;
        case STEP_DDFD_D_T5L:
            if (opcode_ == 0x36 && asserted(pins, WAIT)) { break; }
            step_ = STEP_DDFD_D_T6H;
            break;
        case STEP_DDFD_D_T6H: step_ = STEP_DDFD_D_T6L; break;
        case STEP_DDFD_D_T6L:
            if (opcode_ == 0x36) {
                dlatch_ = get_data(pins);
                pins = release_pins(pins, MREQ | RD);
            }
            step_ = STEP_DDFD_D_T7H;
            break;
        case STEP_DDFD_D_T7H: step_ = STEP_DDFD_D_T7L; break;
        case STEP_DDFD_D_T7L: step_ = STEP_DDFD_D_T8H; break;
        case STEP_DDFD_D_T8H: step_ = STEP_DDFD_D_T8L; break;
        case STEP_DDFD_D_T8L:
            step_ = (opcode_ == 0x36) ? uint16_t(STEP_DDFD_LDHLN_WR_T1H)
                                      : uint16_t(opcode_);
            break;

        // ---- LD (IX/IY+d),n write tail, 3 T-states ------------------------------
        case STEP_DDFD_LDHLN_WR_T1H:
            pins = set_addr(pins, addr_);
            step_ = STEP_DDFD_LDHLN_WR_T1L;
            break;
        case STEP_DDFD_LDHLN_WR_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = STEP_DDFD_LDHLN_WR_T2H;
            break;
        case STEP_DDFD_LDHLN_WR_T2H:
            pins = set_data(pins, dlatch_);
            step_ = STEP_DDFD_LDHLN_WR_T2L;
            break;
        case STEP_DDFD_LDHLN_WR_T2L:
            if (asserted(pins, WAIT)) { break; }
            pins = assert_pins(pins, WR);
            step_ = STEP_DDFD_LDHLN_WR_T3H;
            break;
        case STEP_DDFD_LDHLN_WR_T3H: step_ = STEP_DDFD_LDHLN_WR_T3L; break;
        case STEP_DDFD_LDHLN_WR_T3L:
            pins = release_pins(pins, MREQ | WR);
            step_ = STEP_DDFD_LDHLN_WR_OVL;
            break;
        case STEP_DDFD_LDHLN_WR_OVL:
            pins = begin_fetch(pins);
            break;

        // ---- DD CB d / FD CB d, 15 T-states --------------------------------------
        // The published timing after the two M1s is pc+2:3, pc+3:3, pc+3:1 x 2,
        // ii+n:3, ii+n:1, ii+n(write):3 -- 15 T-states, or 12 for BIT, which
        // writes nothing. begin_fetch_cb() has already been T1H of the read of
        // d, putting its address out, so each step below runs half a T-state
        // later than its name says: STEP_DDFDCB_T1H is T1L, and so on, and
        // STEP_DDFDCB_T15L is the next instruction's T1H. The comments give the
        // real half-clock.
        case STEP_DDFDCB_T1H: // d: T1L
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_DDFDCB_T1L;
            break;
        case STEP_DDFDCB_T1L: step_ = STEP_DDFDCB_T2H; break; // T2H
        case STEP_DDFDCB_T2H: // T2L
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_DDFDCB_T2L;
            break;
        case STEP_DDFDCB_T2L: step_ = STEP_DDFDCB_T3H; break; // T3H
        case STEP_DDFDCB_T3H: // T3L
            addr_ = uint16_t(hlx() + int8_t(get_data(pins)));
            regs.wz = addr_;
            pins = release_pins(pins, MREQ | RD);
            step_ = STEP_DDFDCB_T3L;
            break;
        case STEP_DDFDCB_T3L: // the CB-suffix opcode: T4H
            // An ORDINARY memory read, NOT an M1 cycle: no M1, no RFSH, and R
            // is NOT incremented.
            pins = set_addr(pins, pc_post_inc());
            step_ = STEP_DDFDCB_T4H;
            break;
        case STEP_DDFDCB_T4H: // T4L
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_DDFDCB_T4L;
            break;
        case STEP_DDFDCB_T4L: step_ = STEP_DDFDCB_T5H; break; // T5H
        case STEP_DDFDCB_T5H: // T5L
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_DDFDCB_T5L;
            break;
        case STEP_DDFDCB_T5L: step_ = STEP_DDFDCB_T6H; break; // T6H
        case STEP_DDFDCB_T6H: // T6L
            opcode_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = STEP_DDFDCB_T6L;
            break;
        // T7 and T8: internal, the opcode's address still on the bus.
        case STEP_DDFDCB_T6L: step_ = STEP_DDFDCB_T7H; break;
        case STEP_DDFDCB_T7H: step_ = STEP_DDFDCB_T7L; break;
        case STEP_DDFDCB_T7L: step_ = STEP_DDFDCB_T8H; break;
        case STEP_DDFDCB_T8H: step_ = STEP_DDFDCB_T8L; break;
        case STEP_DDFDCB_T8L: // the operand at IX/IY+d: T9H
            pins = set_addr(pins, addr_);
            step_ = STEP_DDFDCB_T9H;
            break;
        case STEP_DDFDCB_T9H: // T9L
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_DDFDCB_T9L;
            break;
        case STEP_DDFDCB_T9L: step_ = STEP_DDFDCB_T10H; break; // T10H
        case STEP_DDFDCB_T10H: // T10L
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_DDFDCB_T10L;
            break;
        case STEP_DDFDCB_T10L: step_ = STEP_DDFDCB_T11H; break; // T11H
        case STEP_DDFDCB_T11H: { // T11L
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            uint8_t out = 0;
            if (cb_action(dlatch_, true, &out)) {
                dlatch_ = out;
                // The undocumented DDCB register copy: the result also lands
                // in the register the CB-suffix's z field names (unless that
                // is 6, i.e. (HL) itself). Real silicon behaviour.
                uint8_t z1 = uint8_t(opcode_ & 7);
                if (z1 != 6) {
                    set_reg8_plain(z1, out);
                }
            }
            step_ = STEP_DDFDCB_T11L;
            break;
        }
        // T12: internal, the operand's address still on the bus.
        case STEP_DDFDCB_T11L: step_ = STEP_DDFDCB_T12H; break;
        case STEP_DDFDCB_T12H: step_ = STEP_DDFDCB_T12L; break;
        case STEP_DDFDCB_T12L: // T13H: the write -- or, for BIT, the next fetch
            if ((opcode_ & 0xC0) == 0x40) {
                pins = begin_fetch(pins);
                break;
            }
            pins = set_addr(pins, addr_);
            step_ = STEP_DDFDCB_T13H;
            break;
        case STEP_DDFDCB_T13H: // T13L
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = STEP_DDFDCB_T13L;
            break;
        case STEP_DDFDCB_T13L: // T14H
            pins = set_data(pins, dlatch_);
            step_ = STEP_DDFDCB_T14H;
            break;
        case STEP_DDFDCB_T14H: // T14L
            if (asserted(pins, WAIT)) { break; }
            pins = assert_pins(pins, WR);
            step_ = STEP_DDFDCB_T14L;
            break;
        case STEP_DDFDCB_T14L: step_ = STEP_DDFDCB_T15H; break; // T15H
        case STEP_DDFDCB_T15H: // T15L
            pins = release_pins(pins, MREQ | WR);
            step_ = STEP_DDFDCB_T15L;
            break;
        case STEP_DDFDCB_T15L: // the next instruction's T1H
            pins = begin_fetch(pins);
            break;

        // ---- Interrupt acknowledge -----------------------------------------------
        // As the datasheet draws it: an M1 cycle with two wait states -- T1,
        // T2, TW, TW, T3, T4 -- with PC on the bus and M1 down from T1, no MREQ
        // until the refresh, IORQ down from the first wait state, and the
        // device's byte taken at the start of T3. Then:
        //   IM 0  the byte is the opcode, and runs from here as if fetched
        //         (RST p: one internal T-state and two pushes, 13 in all);
        //   IM 1  a seventh T-state, the two pushes, PC = 0x0038 (13);
        //   IM 2  the same, then the vector read from (I << 8) | byte (19).
        // begin_fetch() was T1H, so each step below runs half a T-state after
        // its name: STEP_INT_T1H is T1L, and so on. The comments give the real
        // half-clock.
        case STEP_INT_T1H: // T1L
            regs.iff1 = false;
            regs.iff2 = false;
            halted = false;
            step_ = STEP_INT_T1L;
            break;
        case STEP_INT_T1L: step_ = STEP_INT_T2H; break; // T2H
        case STEP_INT_T2H: step_ = STEP_INT_T2L; break; // T2L
        case STEP_INT_T2L: step_ = STEP_INT_T3H; break; // TW1H
        case STEP_INT_T3H: // TW1L
            pins = assert_pins(pins, IORQ);
            step_ = STEP_INT_T3L;
            break;
        case STEP_INT_T3L: step_ = STEP_INT_T4H; break; // TW2H
        case STEP_INT_T4H: // TW2L
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_INT_T4L;
            break;
        case STEP_INT_T4L: // T3H
            dlatch_ = get_data(pins);
            pins = release_pins(pins, M1 | IORQ);
            // R increments on the acknowledge as on any M1.
            pins = refresh(pins);
            step_ = STEP_INT_T5H;
            break;
        case STEP_INT_T5H: pins = assert_pins(pins, MREQ); step_ = STEP_INT_T5L; break; // T3L
        case STEP_INT_T5L: step_ = STEP_INT_T6H; break; // T4H
        case STEP_INT_T6H: // T4L
            pins = release_pins(pins, MREQ);
            rfsh_release_ = true;
            if (regs.im == 0) {
                // The acknowledged byte is the instruction: from here on it is
                // what an opcode fetch of it would have left -- the opcode
                // latched and the opcode's own steps next. Any further bytes
                // (operands, and a prefixed instruction's next opcode byte)
                // are read by the instruction's own cycles with PC held where
                // the interrupt found it: Zilog's interrupt application note
                // has them "read in by a normal memory read sequence (The PC,
                // however, remains at its pre-interrupt state ...)", the
                // device answering at that address. So CALL nn takes 6 + 13 =
                // 19 T-states and pushes the interrupted PC. A prefix's next
                // opcode byte comes by the CPU's opcode fetch, M1 and refresh
                // included, as it always does -- the note does not say, and
                // that is the CPU's one way of reading an opcode.
                opcode_ = dlatch_;
                addr_ = regs.hl();
                prefix_active_ = false;
                im0_pc_hold_ = true;
                step_ = opcode_;
            } else {
                step_ = STEP_INT_T6L;
            }
            break;
        case STEP_INT_T6L: step_ = STEP_INT_T7L; break; // T5H: internal
        case STEP_INT_T7L: step_ = STEP_INT_PUSH_HI_T1H; break; // T5L

        // ---- NMI: a dummy opcode fetch, 5 T-states -------------------------------
        // begin_fetch() was T1H. The byte read at PC is not used.
        case STEP_NMI_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_NMI_T2H;
            break;
        case STEP_NMI_T2H: step_ = STEP_NMI_T2L; break;
        case STEP_NMI_T2L:
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_NMI_T3H;
            break;
        case STEP_NMI_T3H:
            pins = release_pins(pins, M1 | MREQ | RD);
            pins = refresh(pins);
            step_ = STEP_NMI_T3L;
            break;
        case STEP_NMI_T3L: pins = assert_pins(pins, MREQ); step_ = STEP_NMI_T4H; break;
        case STEP_NMI_T4H: step_ = STEP_NMI_T4L; break;
        case STEP_NMI_T4L:
            pins = release_pins(pins, MREQ);
            rfsh_release_ = true;
            step_ = STEP_NMI_T5H;
            break;
        case STEP_NMI_T5H: step_ = STEP_NMI_T5L; break; // internal
        case STEP_NMI_T5L: step_ = STEP_INT_PUSH_HI_T1H; break;

        case STEP_INT_PUSH_HI_T1H:
            pins = set_addr(pins, sp_pre_dec());
            step_ = STEP_INT_PUSH_HI_T1L;
            break;
        case STEP_INT_PUSH_HI_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = STEP_INT_PUSH_HI_T2H;
            break;
        case STEP_INT_PUSH_HI_T2H:
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = STEP_INT_PUSH_HI_T2L;
            break;
        case STEP_INT_PUSH_HI_T2L:
            if (asserted(pins, WAIT)) { break; }
            pins = assert_pins(pins, WR);
            step_ = STEP_INT_PUSH_HI_T3H;
            break;
        case STEP_INT_PUSH_HI_T3H: step_ = STEP_INT_PUSH_HI_T3L; break;
        case STEP_INT_PUSH_HI_T3L:
            pins = release_pins(pins, MREQ | WR);
            step_ = STEP_INT_PUSH_LO_T1H;
            break;

        case STEP_INT_PUSH_LO_T1H:
            pins = set_addr(pins, sp_pre_dec());
            step_ = STEP_INT_PUSH_LO_T1L;
            break;
        case STEP_INT_PUSH_LO_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = STEP_INT_PUSH_LO_T2H;
            break;
        case STEP_INT_PUSH_LO_T2H:
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = STEP_INT_PUSH_LO_T2L;
            break;
        case STEP_INT_PUSH_LO_T2L:
            if (asserted(pins, WAIT)) { break; }
            pins = assert_pins(pins, WR);
            if (nmi_ack_) {
                regs.wz = 0x0066;
                regs.pc = 0x0066;
            } else if (regs.im == 2) {
                // IM2: the acknowledged byte and I form the vector table address.
                regs.set_wzl(dlatch_);
                regs.set_wzh(regs.i);
            } else {
                // IM 1. (IM 0 never comes here: it runs the acknowledged byte.)
                regs.wz = 0x0038;
                regs.pc = 0x0038;
            }
            step_ = STEP_INT_PUSH_LO_T3H;
            break;
        case STEP_INT_PUSH_LO_T3H: step_ = STEP_INT_PUSH_LO_T3L; break;
        case STEP_INT_PUSH_LO_T3L:
            pins = release_pins(pins, MREQ | WR);
            step_ = (regs.im == 2 && !nmi_ack_) ? uint16_t(STEP_INT_VEC_LO_T1H)
                                                : uint16_t(STEP_INT_DONE_IM1_H);
            break;

        // IM 1 and the NMI: the half-clock after the last push is the next
        // fetch's T1H, as after any instruction's last cycle.
        case STEP_INT_DONE_IM1_H:
            nmi_ack_ = false;
            pins = begin_fetch(pins);
            break;
        // No longer reached since the acknowledge took its seventh T-state;
        // kept so that the step numbers after it do not move.
        case STEP_INT_DONE_IM1_L:
        case STEP_INT_VEC_HI_T4L:
            pins = begin_fetch(pins);
            break;

        // IM2 only: read the 2-byte handler address from (I<<8)|ack_byte.
        case STEP_INT_VEC_LO_T1H:
            pins = set_addr(pins, wz_post_inc());
            step_ = STEP_INT_VEC_LO_T1L;
            break;
        case STEP_INT_VEC_LO_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_INT_VEC_LO_T2H;
            break;
        case STEP_INT_VEC_LO_T2H: step_ = STEP_INT_VEC_LO_T2L; break;
        case STEP_INT_VEC_LO_T2L:
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_INT_VEC_LO_T3H;
            break;
        case STEP_INT_VEC_LO_T3H:
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = STEP_INT_VEC_LO_T3L;
            break;
        case STEP_INT_VEC_LO_T3L: step_ = STEP_INT_VEC_HI_T1H; break;

        case STEP_INT_VEC_HI_T1H:
            pins = set_addr(pins, regs.wz);
            step_ = STEP_INT_VEC_HI_T1L;
            break;
        case STEP_INT_VEC_HI_T1L:
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = STEP_INT_VEC_HI_T2H;
            break;
        case STEP_INT_VEC_HI_T2H: step_ = STEP_INT_VEC_HI_T2L; break;
        case STEP_INT_VEC_HI_T2L:
            if (asserted(pins, WAIT)) { break; }
            step_ = STEP_INT_VEC_HI_T3H;
            break;
        case STEP_INT_VEC_HI_T3H:
            regs.set_wzh(get_data(pins));
            regs.set_wzl(dlatch_);
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = STEP_INT_VEC_HI_T3L;
            break;
        case STEP_INT_VEC_HI_T3L: step_ = STEP_INT_VEC_HI_T4H; break;
        case STEP_INT_VEC_HI_T4H: // the next fetch's T1H
            pins = begin_fetch(pins);
            break;

        default:
            if (!dispatch_generated(pins)) {
                // Loud rather than silently wrong -- an unimplemented opcode
                // that limps along corrupts state in ways that surface much
                // later and much more confusingly.
                std::fprintf(stderr,
                             "zx::Z80: unimplemented step 0x%04X (opcode 0x%02X) at PC 0x%04X\n",
                             step_, opcode_, uint16_t(regs.pc - 1));
                std::abort();
            }
            break;
    }

    return halted ? assert_pins(pins, HALT) : release_pins(pins, HALT);
}

#if ZX_REWIND
void Z80::save_state(State& s) const {
    s.regs = regs;
    s.halted = halted;
    s.interrupt_count = interrupt_count;
    s.step = step_;
    s.opcode = opcode_;
    s.dlatch = dlatch_;
    s.addr = addr_;
    s.prefix_active = prefix_active_;
    s.hlx_idx = hlx_idx_;
    s.pins = pins_;
    s.rfsh_release = rfsh_release_;
    s.nmi_level = nmi_level_;
    s.nmi_pending = nmi_pending_;
    s.nmi_ack = nmi_ack_;
    s.im0_pc_hold = im0_pc_hold_;
}

void Z80::restore_state(const State& s) {
    regs = s.regs;
    halted = s.halted;
    interrupt_count = s.interrupt_count;
    step_ = s.step;
    opcode_ = s.opcode;
    dlatch_ = s.dlatch;
    addr_ = s.addr;
    prefix_active_ = s.prefix_active;
    hlx_idx_ = s.hlx_idx;
    pins_ = s.pins;
    rfsh_release_ = s.rfsh_release;
    nmi_level_ = s.nmi_level;
    nmi_pending_ = s.nmi_pending;
    nmi_ack_ = s.nmi_ack;
    im0_pc_hold_ = s.im0_pc_hold;
}
#endif

} // namespace zx
