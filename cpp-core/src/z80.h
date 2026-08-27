#pragma once
// Z80 CPU core at HALF-T-STATE resolution.
//
// clock() advances one half-T-state (7MHz on a 48K Spectrum), not one T-state.
// Every T-state is two half-states, H then L, following real Z80 bus timing:
//
//     H phase (clock rising)  -- the address bus goes valid; M1/RFSH change.
//     L phase (clock falling) -- MREQ/IORQ/RD/WR assert; WAIT is sampled.
//
// So a plain 3-T memory read is six half-states:
//
//     T1H  address on the bus, no control lines yet
//     T1L  assert MREQ|RD
//     T2H  (hold)
//     T2L  (hold) sample WAIT
//     T3H  (hold)
//     T3L  latch the data byte, release MREQ|RD
//
// The T1H..T1L gap -- address valid, MREQ still high -- is the whole point.
// That is the window a 48K ULA samples to decide whether to halt the CPU
// clock for contention, and the window in which a refresh address landing in
// screen RAM produces "snow". A whole-T-state core cannot represent it, and
// rust-core's attempts to fake it are exactly what this rewrite is undoing.
//
// Ported from rust-core/zx-core/src/cpu.rs, with the T-state sequences
// expanded per the above and cross-checked against SpecIde's own state names
// (ST_OCF_T1H_ADDRWR / ST_OCF_T1L_ADDRWR / ...).
//
// CONVENTIONS the generated dispatch (generated/dispatch.inc) also relies on:
//
//  * Control lines persist until explicitly released (see pins.h). Each
//    machine cycle's final half-state releases what that cycle asserted.
//    There is no automatic per-clock clear.
//  * `pins` carries the caller's response to the PREVIOUS half-clock: data
//    driven onto D0-7 by whoever serviced the bus, and/or WAIT held.
//  * Overlapped fetch: the next instruction's M1 T1H happens during the
//    current instruction's final half-state (that is what `begin_fetch` is).
//    Hence registers() reporting pc-1, and is_instruction_boundary() being a
//    pin test rather than a step test.

#include "memory.h"
#include "pins.h"
#include "registers.h"

#include <cstdint>

namespace zx {

/// Step numbers 0..255 are the unprefixed opcode dispatch entries (the step
/// number IS the opcode byte), 256..511 the ED-prefixed ones, and 512+ are
/// allocated by the generator for each op's own half-states.
constexpr uint16_t ED_STEP_BASE = 256;

/// Hand-written machine-cycle half-states live well above anything the
/// generator allocates. Sequential rather than hand-numbered: the sequences
/// below are long enough that manual numbering is a bug waiting to happen.
constexpr uint16_t HAND_STEP_BASE = 0xF000;

enum HandStep : uint16_t {
    // ---- M1 opcode fetch, 4 T-states -------------------------------------
    // T1H is not listed: it is performed by begin_fetch(), which runs during
    // the previous instruction's last half-state (the overlapped fetch).
    STEP_M1_T1L = HAND_STEP_BASE,
    STEP_M1_T2H, STEP_M1_T2L,
    STEP_M1_T3H, STEP_M1_T3L,
    STEP_M1_T4H, STEP_M1_T4L,

    // ---- ED-prefix second M1 fetch, 4 T-states ---------------------------
    STEP_ED_M1_T1L,
    STEP_ED_M1_T2H, STEP_ED_M1_T2L,
    STEP_ED_M1_T3H, STEP_ED_M1_T3L,
    STEP_ED_M1_T4H, STEP_ED_M1_T4L,

    // ---- CB-prefix second M1 fetch, 4 T-states ---------------------------
    STEP_CB_M1_T1L,
    STEP_CB_M1_T2H, STEP_CB_M1_T2L,
    STEP_CB_M1_T3H, STEP_CB_M1_T3L,
    STEP_CB_M1_T4H, STEP_CB_M1_T4L,

    // ---- DD/FD-prefix second M1 fetch, 4 T-states ------------------------
    STEP_DDFD_M1_T1L,
    STEP_DDFD_M1_T2H, STEP_DDFD_M1_T2L,
    STEP_DDFD_M1_T3H, STEP_DDFD_M1_T3L,
    STEP_DDFD_M1_T4H, STEP_DDFD_M1_T4L,

    // ---- DD/FD displacement sequence, 8 T-states -------------------------
    // Reads `d`, forms IX/IY+d into `addr`, and for LD (IX+d),n also reads
    // the immediate `n`. Runs between the prefix's M1 and the real opcode's
    // own generated steps.
    STEP_DDFD_D_T1H, STEP_DDFD_D_T1L,
    STEP_DDFD_D_T2H, STEP_DDFD_D_T2L,
    STEP_DDFD_D_T3H, STEP_DDFD_D_T3L,
    STEP_DDFD_D_T4H, STEP_DDFD_D_T4L,
    STEP_DDFD_D_T5H, STEP_DDFD_D_T5L,
    STEP_DDFD_D_T6H, STEP_DDFD_D_T6L,
    STEP_DDFD_D_T7H, STEP_DDFD_D_T7L,
    STEP_DDFD_D_T8H, STEP_DDFD_D_T8L,

    // ---- LD (IX/IY+d),n write tail, 3 T-states + overlapped fetch --------
    // The trailing _OVL half is the next instruction's M1 T1H, exactly as
    // the generated code's `overlapped` half-state is. Folding it into T3L
    // instead would make the instruction come out a half-T-state short.
    STEP_DDFD_LDHLN_WR_T1H, STEP_DDFD_LDHLN_WR_T1L,
    STEP_DDFD_LDHLN_WR_T2H, STEP_DDFD_LDHLN_WR_T2L,
    STEP_DDFD_LDHLN_WR_T3H, STEP_DDFD_LDHLN_WR_T3L,
    STEP_DDFD_LDHLN_WR_OVL,

    // ---- DD CB d / FD CB d, 15 T-states ----------------------------------
    // Note T4: the CB-suffix opcode byte is read as an ORDINARY memory read,
    // not an M1 cycle -- R does NOT increment there. Easy to get wrong when
    // re-deriving, so it is called out both here and at the implementation.
    STEP_DDFDCB_T1H, STEP_DDFDCB_T1L,
    STEP_DDFDCB_T2H, STEP_DDFDCB_T2L,
    STEP_DDFDCB_T3H, STEP_DDFDCB_T3L,
    STEP_DDFDCB_T4H, STEP_DDFDCB_T4L,
    STEP_DDFDCB_T5H, STEP_DDFDCB_T5L,
    STEP_DDFDCB_T6H, STEP_DDFDCB_T6L,
    STEP_DDFDCB_T7H, STEP_DDFDCB_T7L,
    STEP_DDFDCB_T8H, STEP_DDFDCB_T8L,
    STEP_DDFDCB_T9H, STEP_DDFDCB_T9L,
    STEP_DDFDCB_T10H, STEP_DDFDCB_T10L,
    STEP_DDFDCB_T11H, STEP_DDFDCB_T11L,
    STEP_DDFDCB_T12H, STEP_DDFDCB_T12L,
    STEP_DDFDCB_T13H, STEP_DDFDCB_T13L,
    STEP_DDFDCB_T14H, STEP_DDFDCB_T14L,
    STEP_DDFDCB_T15H, STEP_DDFDCB_T15L,

    // ---- Interrupt acknowledge -------------------------------------------
    // IM0 and IM1 are deliberately collapsed: the Spectrum's floating bus
    // returns 0xFF during int-ack, which decodes as RST 38h either way.
    // IM0/IM1 = 13 T-states, IM2 = 19.
    STEP_INT_T1H, STEP_INT_T1L,
    STEP_INT_T2H, STEP_INT_T2L,
    STEP_INT_T3H, STEP_INT_T3L,
    STEP_INT_T4H, STEP_INT_T4L,
    STEP_INT_T5H, STEP_INT_T5L,
    STEP_INT_T6H, STEP_INT_T6L,
    STEP_INT_PUSH_HI_T1H, STEP_INT_PUSH_HI_T1L,
    STEP_INT_PUSH_HI_T2H, STEP_INT_PUSH_HI_T2L,
    STEP_INT_PUSH_HI_T3H, STEP_INT_PUSH_HI_T3L,
    STEP_INT_PUSH_LO_T1H, STEP_INT_PUSH_LO_T1L,
    STEP_INT_PUSH_LO_T2H, STEP_INT_PUSH_LO_T2L,
    STEP_INT_PUSH_LO_T3H, STEP_INT_PUSH_LO_T3L,
    /// IM0/IM1 terminal half-state: begins the next fetch at 0x0038.
    STEP_INT_DONE_IM1_H, STEP_INT_DONE_IM1_L,
    /// IM2 continues into a 2-byte vector read through (I<<8)|bus_byte.
    STEP_INT_VEC_LO_T1H, STEP_INT_VEC_LO_T1L,
    STEP_INT_VEC_LO_T2H, STEP_INT_VEC_LO_T2L,
    STEP_INT_VEC_LO_T3H, STEP_INT_VEC_LO_T3L,
    STEP_INT_VEC_HI_T1H, STEP_INT_VEC_HI_T1L,
    STEP_INT_VEC_HI_T2H, STEP_INT_VEC_HI_T2L,
    STEP_INT_VEC_HI_T3H, STEP_INT_VEC_HI_T3L,
    STEP_INT_VEC_HI_T4H, STEP_INT_VEC_HI_T4L,
};

class Z80 {
public:
    Registers regs{};

    /// HALT latch. Drives the HALT pin, suppresses registers()' PC
    /// correction, and is cleared when an interrupt is accepted.
    bool halted = false;

    /// Interrupts accepted since power-on. A counter rather than a flag
    /// so a caller can tell one happened between two points without
    /// having to catch and clear it -- which is what break-on-interrupt
    /// needs, since the acceptance sequence is over by the time a
    /// debugger gets to look.
    uint64_t interrupt_count = 0;

    Z80() = default;

    /// Advances exactly one half-T-state. `pins` is the caller's response to
    /// the previous half-clock; the return value is this half-clock's bus
    /// state. Pure with respect to `pins` -- the caller owns persisting it.
    uint64_t clock(uint64_t pins);

    /// Register snapshot with PC corrected back by one, undoing the
    /// overlapped fetch's look-ahead -- EXCEPT while halted, where PC is
    /// already parked correctly.
    Registers registers() const;

    /// Replaces the register file and re-primes the fetch pipeline. The
    /// priming clock's memory request MUST be serviced (this does it via
    /// `mem`) or the next "opcode" is whatever was left on the data bus.
    void set_registers(const Registers& r, Memory& mem);

    uint64_t pins() const { return pins_; }

    /// True when a fresh opcode fetch has just begun and we are not part-way
    /// through a prefix -- i.e. the previous instruction has fully retired.
    ///
    /// rust-core made this a PIN test (`M1|RD` both asserted), mirroring
    /// z80_opdone(). That no longer works here for two reasons: M1 and RD
    /// now assert on different half-cycles (T1H and T1L), so they are never
    /// simultaneously true at the one moment a caller wants to sample; and
    /// control lines persist rather than auto-clearing, so any pin pattern
    /// spans several half-states and would match repeatedly. The step number
    /// is exact and unambiguous instead: STEP_M1_T1L is reached only from
    /// begin_fetch(), i.e. only at a real instruction boundary.
    bool is_instruction_boundary() const {
        return step_ == STEP_M1_T1L && !prefix_active_;
    }

    /// Runs whole half-clocks until the current instruction completes,
    /// servicing memory internally. Returns the number of half-clocks taken
    /// (so twice the T-state count). Convenience wrapper for callers that do
    /// not need per-half-clock control; the machine-level driver does not use
    /// this (it needs to service IORQ too, which this ignores).
    uint16_t step_instruction(Memory& mem);

    /// Services an MREQ read/write against `mem`. IORQ is deliberately NOT
    /// handled -- I/O is the machine's business, not the CPU's.
    static uint64_t service_memory(Memory& mem, uint64_t pins);

private:
    uint16_t step_ = 0;
    uint8_t opcode_ = 0;
    /// General one-byte latch: memory read results, the LD (IX+d),n
    /// immediate, the int-ack byte / IM2 vector low, DDCB operand + result.
    uint8_t dlatch_ = 0;
    /// Internal effective-address latch (HL, or IX/IY+d).
    uint16_t addr_ = 0;
    /// Suppresses is_instruction_boundary() between a prefix and its suffix.
    bool prefix_active_ = false;
    /// 0 = HL, 1 = IX, 2 = IY. z80.h's cpu->hlx[cpu->hlx_idx], as accessors.
    uint8_t hlx_idx_ = 0;
    /// PINS_IDLE, not 0: signals are active low, so a zeroed bus would mean
    /// every line asserted at once -- RESET, INT and WAIT included.
    uint64_t pins_ = PINS_IDLE;

    // ---- fetch entry points ------------------------------------------------
    /// M1 T1H: samples INT, then puts PC on the bus and asserts M1. Called
    /// from every instruction's final half-state (the overlapped fetch).
    uint64_t begin_fetch(uint64_t pins);
    uint64_t begin_fetch_ed(uint64_t pins);
    uint64_t begin_fetch_cb(uint64_t pins);
    uint64_t begin_fetch_dd(uint64_t pins);
    uint64_t begin_fetch_fd(uint64_t pins);

    /// M1 T3H: drives the I:R refresh address with RFSH. R is a 7-bit
    /// counter -- bit 7 is preserved.
    uint64_t refresh(uint64_t pins);

    uint64_t op_halt(uint64_t pins);

    // ---- helpers the generated dispatch calls -----------------------------
    void alu_op(uint8_t op, uint8_t val);
    /// Returns false for BIT (which writes nothing back); otherwise writes
    /// the result to `out`.
    bool cb_action(uint8_t val, bool is_indirect, uint8_t* out);

    uint8_t get_reg8_plain(uint8_t idx) const;
    void set_reg8_plain(uint8_t idx, uint8_t value);

    // HL/IX/IY substitution, driven by hlx_idx_.
    uint16_t hlx() const;
    void set_hlx(uint16_t v);
    uint8_t hlx_h() const;
    void set_hlx_h(uint8_t v);
    uint8_t hlx_l() const;
    void set_hlx_l(uint8_t v);

    // Post-increment / pre-decrement address helpers. All return the
    // pre-modification value except sp_pre_dec, which returns the new SP.
    uint16_t pc_post_inc() { return regs.pc++; }
    uint16_t sp_post_inc() { return regs.sp++; }
    uint16_t sp_pre_dec() { return --regs.sp; }
    uint16_t wz_post_inc() { return regs.wz++; }
    uint16_t hl_post_inc() { uint16_t v = regs.hl(); regs.set_hl(uint16_t(v + 1)); return v; }
    uint16_t hl_post_dec() { uint16_t v = regs.hl(); regs.set_hl(uint16_t(v - 1)); return v; }
    uint16_t de_post_inc() { uint16_t v = regs.de(); regs.set_de(uint16_t(v + 1)); return v; }
    uint16_t de_post_dec() { uint16_t v = regs.de(); regs.set_de(uint16_t(v - 1)); return v; }

    /// The generated half-state table. Returns false if `step_` is not one it
    /// knows, which means an unimplemented opcode.
    bool dispatch_generated(uint64_t& pins);
};

} // namespace zx
