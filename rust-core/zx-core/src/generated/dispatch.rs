// GENERATED FILE -- do not edit by hand.
// Produced by scripts/generate_z80_dispatch.py from vendor/chips/z80_desc.yml.
// Regenerate with: python scripts/generate_z80_dispatch.py
//
// A separate module (not spliced into cpu.rs -- `include!()` inside an
// `impl` block turned out not to be accepted by Rust's parser in item
// position), so the handful of Cpu fields/methods this needs
// (step/opcode/dlatch/addr/regs, begin_fetch/begin_fetch_ed/alu_op/the
// post-inc-dec helpers) are `pub(crate)` rather than exposed publicly.

use crate::alu;
use crate::flags::*;
use crate::pins::*;

/// Step number for the CB-prefix register-direct payload ("cb" in
/// z80_desc.yml) -- cpu.rs's hand-written CB fetch machine cycle jumps
/// here directly, not through the 0..512 table.
pub(crate) const CB_STEP: u16 = 1558;
/// Same, for the "(HL)" form ("cbhl" in z80_desc.yml).
pub(crate) const CBHL_STEP: u16 = 1559;

impl crate::cpu::Cpu {
    pub(crate) fn dispatch_generated(&mut self, pins: u64) -> Option<u64> {
        Some(match self.step {
            0 => {
                self.begin_fetch(pins)
            }
            1 => {
                self.step = 512;
                pins
            }
            512 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 513;
                pins
            }
            513 => {
                self.regs.c = get_data(pins);
                self.step = 514;
                pins
            }
            514 => {
                self.step = 515;
                pins
            }
            515 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 516;
                pins
            }
            516 => {
                self.regs.b = get_data(pins);
                self.step = 517;
                pins
            }
            517 => {
                self.begin_fetch(pins)
            }
            2 => {
                self.step = 518;
                pins
            }
            518 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), self.regs.a, MREQ | WR);
                self.regs.set_wzl(self.regs.c.wrapping_add(1)); self.regs.set_wzh(self.regs.a);
                self.step = 519;
                pins
            }
            519 => {
                self.step = 520;
                pins
            }
            520 => {
                self.begin_fetch(pins)
            }
            3 => {
                self.regs.set_bc(self.regs.bc().wrapping_add(1));
                self.step = 521;
                pins
            }
            521 => {
                self.step = 522;
                pins
            }
            522 => {
                self.begin_fetch(pins)
            }
            4 => {
                let r = alu::inc8(self.regs.b, self.regs.f); self.regs.b = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            5 => {
                let r = alu::dec8(self.regs.b, self.regs.f); self.regs.b = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            6 => {
                self.step = 523;
                pins
            }
            523 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 524;
                pins
            }
            524 => {
                self.regs.b = get_data(pins);
                self.step = 525;
                pins
            }
            525 => {
                self.begin_fetch(pins)
            }
            7 => {
                let r = alu::rlca(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            8 => {
                let af = self.regs.af(); let af2 = ((self.regs.a_ as u16) << 8) | self.regs.f_ as u16; self.regs.set_af(af2); self.regs.a_ = (af >> 8) as u8; self.regs.f_ = af as u8;
                self.begin_fetch(pins)
            }
            9 => {
                self.regs.wz = self.hlx().wrapping_add(1); let r = alu::add16(self.hlx(), self.regs.bc(), self.regs.f); self.set_hlx(r.value); self.regs.f = r.flags;
                self.step = 526;
                pins
            }
            526 => {
                self.step = 527;
                pins
            }
            527 => {
                self.step = 528;
                pins
            }
            528 => {
                self.step = 529;
                pins
            }
            529 => {
                self.step = 530;
                pins
            }
            530 => {
                self.step = 531;
                pins
            }
            531 => {
                self.step = 532;
                pins
            }
            532 => {
                self.begin_fetch(pins)
            }
            10 => {
                self.step = 533;
                pins
            }
            533 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), MREQ | RD);
                self.step = 534;
                pins
            }
            534 => {
                self.regs.a = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 535;
                pins
            }
            535 => {
                self.begin_fetch(pins)
            }
            11 => {
                self.regs.set_bc(self.regs.bc().wrapping_sub(1));
                self.step = 536;
                pins
            }
            536 => {
                self.step = 537;
                pins
            }
            537 => {
                self.begin_fetch(pins)
            }
            12 => {
                let r = alu::inc8(self.regs.c, self.regs.f); self.regs.c = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            13 => {
                let r = alu::dec8(self.regs.c, self.regs.f); self.regs.c = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            14 => {
                self.step = 538;
                pins
            }
            538 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 539;
                pins
            }
            539 => {
                self.regs.c = get_data(pins);
                self.step = 540;
                pins
            }
            540 => {
                self.begin_fetch(pins)
            }
            15 => {
                let r = alu::rrca(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            16 => {
                self.step = 541;
                pins
            }
            541 => {
                self.step = 542;
                pins
            }
            542 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 543;
                pins
            }
            543 => {
                self.dlatch = get_data(pins);
                self.regs.b = self.regs.b.wrapping_sub(1); if self.regs.b == 0 { self.step = 549; return Some(pins); }
                self.step = 544;
                pins
            }
            544 => {
                self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); self.regs.wz = self.regs.pc;
                self.step = 545;
                pins
            }
            545 => {
                self.step = 546;
                pins
            }
            546 => {
                self.step = 547;
                pins
            }
            547 => {
                self.step = 548;
                pins
            }
            548 => {
                self.step = 549;
                pins
            }
            549 => {
                self.begin_fetch(pins)
            }
            17 => {
                self.step = 550;
                pins
            }
            550 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 551;
                pins
            }
            551 => {
                self.regs.e = get_data(pins);
                self.step = 552;
                pins
            }
            552 => {
                self.step = 553;
                pins
            }
            553 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 554;
                pins
            }
            554 => {
                self.regs.d = get_data(pins);
                self.step = 555;
                pins
            }
            555 => {
                self.begin_fetch(pins)
            }
            18 => {
                self.step = 556;
                pins
            }
            556 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.de(), self.regs.a, MREQ | WR);
                self.regs.set_wzl(self.regs.e.wrapping_add(1)); self.regs.set_wzh(self.regs.a);
                self.step = 557;
                pins
            }
            557 => {
                self.step = 558;
                pins
            }
            558 => {
                self.begin_fetch(pins)
            }
            19 => {
                self.regs.set_de(self.regs.de().wrapping_add(1));
                self.step = 559;
                pins
            }
            559 => {
                self.step = 560;
                pins
            }
            560 => {
                self.begin_fetch(pins)
            }
            20 => {
                let r = alu::inc8(self.regs.d, self.regs.f); self.regs.d = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            21 => {
                let r = alu::dec8(self.regs.d, self.regs.f); self.regs.d = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            22 => {
                self.step = 561;
                pins
            }
            561 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 562;
                pins
            }
            562 => {
                self.regs.d = get_data(pins);
                self.step = 563;
                pins
            }
            563 => {
                self.begin_fetch(pins)
            }
            23 => {
                let r = alu::rla(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            24 => {
                self.step = 564;
                pins
            }
            564 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 565;
                pins
            }
            565 => {
                self.dlatch = get_data(pins);
                self.step = 566;
                pins
            }
            566 => {
                self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); self.regs.wz = self.regs.pc;
                self.step = 567;
                pins
            }
            567 => {
                self.step = 568;
                pins
            }
            568 => {
                self.step = 569;
                pins
            }
            569 => {
                self.step = 570;
                pins
            }
            570 => {
                self.step = 571;
                pins
            }
            571 => {
                self.begin_fetch(pins)
            }
            25 => {
                self.regs.wz = self.hlx().wrapping_add(1); let r = alu::add16(self.hlx(), self.regs.de(), self.regs.f); self.set_hlx(r.value); self.regs.f = r.flags;
                self.step = 572;
                pins
            }
            572 => {
                self.step = 573;
                pins
            }
            573 => {
                self.step = 574;
                pins
            }
            574 => {
                self.step = 575;
                pins
            }
            575 => {
                self.step = 576;
                pins
            }
            576 => {
                self.step = 577;
                pins
            }
            577 => {
                self.step = 578;
                pins
            }
            578 => {
                self.begin_fetch(pins)
            }
            26 => {
                self.step = 579;
                pins
            }
            579 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.de(), MREQ | RD);
                self.step = 580;
                pins
            }
            580 => {
                self.regs.a = get_data(pins);
                self.regs.wz = self.regs.de().wrapping_add(1);
                self.step = 581;
                pins
            }
            581 => {
                self.begin_fetch(pins)
            }
            27 => {
                self.regs.set_de(self.regs.de().wrapping_sub(1));
                self.step = 582;
                pins
            }
            582 => {
                self.step = 583;
                pins
            }
            583 => {
                self.begin_fetch(pins)
            }
            28 => {
                let r = alu::inc8(self.regs.e, self.regs.f); self.regs.e = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            29 => {
                let r = alu::dec8(self.regs.e, self.regs.f); self.regs.e = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            30 => {
                self.step = 584;
                pins
            }
            584 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 585;
                pins
            }
            585 => {
                self.regs.e = get_data(pins);
                self.step = 586;
                pins
            }
            586 => {
                self.begin_fetch(pins)
            }
            31 => {
                let r = alu::rra(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            32 => {
                self.step = 587;
                pins
            }
            587 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 588;
                pins
            }
            588 => {
                self.dlatch = get_data(pins);
                if !(self.regs.f & FLAG_Z == 0) { self.step = 594; return Some(pins); }
                self.step = 589;
                pins
            }
            589 => {
                self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); self.regs.wz = self.regs.pc;
                self.step = 590;
                pins
            }
            590 => {
                self.step = 591;
                pins
            }
            591 => {
                self.step = 592;
                pins
            }
            592 => {
                self.step = 593;
                pins
            }
            593 => {
                self.step = 594;
                pins
            }
            594 => {
                self.begin_fetch(pins)
            }
            33 => {
                self.step = 595;
                pins
            }
            595 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 596;
                pins
            }
            596 => {
                self.set_hlx_l(get_data(pins));
                self.step = 597;
                pins
            }
            597 => {
                self.step = 598;
                pins
            }
            598 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 599;
                pins
            }
            599 => {
                self.set_hlx_h(get_data(pins));
                self.step = 600;
                pins
            }
            600 => {
                self.begin_fetch(pins)
            }
            34 => {
                self.step = 601;
                pins
            }
            601 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 602;
                pins
            }
            602 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 603;
                pins
            }
            603 => {
                self.step = 604;
                pins
            }
            604 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 605;
                pins
            }
            605 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 606;
                pins
            }
            606 => {
                self.step = 607;
                pins
            }
            607 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.wz_post_inc(), self.hlx_l(), MREQ | WR);
                self.step = 608;
                pins
            }
            608 => {
                self.step = 609;
                pins
            }
            609 => {
                self.step = 610;
                pins
            }
            610 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.wz, self.hlx_h(), MREQ | WR);
                self.step = 611;
                pins
            }
            611 => {
                self.step = 612;
                pins
            }
            612 => {
                self.begin_fetch(pins)
            }
            35 => {
                self.set_hlx(self.hlx().wrapping_add(1));
                self.step = 613;
                pins
            }
            613 => {
                self.step = 614;
                pins
            }
            614 => {
                self.begin_fetch(pins)
            }
            36 => {
                let r = alu::inc8(self.hlx_h(), self.regs.f); self.set_hlx_h(r.value); self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            37 => {
                let r = alu::dec8(self.hlx_h(), self.regs.f); self.set_hlx_h(r.value); self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            38 => {
                self.step = 615;
                pins
            }
            615 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 616;
                pins
            }
            616 => {
                self.set_hlx_h(get_data(pins));
                self.step = 617;
                pins
            }
            617 => {
                self.begin_fetch(pins)
            }
            39 => {
                let r = alu::daa(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            40 => {
                self.step = 618;
                pins
            }
            618 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 619;
                pins
            }
            619 => {
                self.dlatch = get_data(pins);
                if !(self.regs.f & FLAG_Z != 0) { self.step = 625; return Some(pins); }
                self.step = 620;
                pins
            }
            620 => {
                self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); self.regs.wz = self.regs.pc;
                self.step = 621;
                pins
            }
            621 => {
                self.step = 622;
                pins
            }
            622 => {
                self.step = 623;
                pins
            }
            623 => {
                self.step = 624;
                pins
            }
            624 => {
                self.step = 625;
                pins
            }
            625 => {
                self.begin_fetch(pins)
            }
            41 => {
                self.regs.wz = self.hlx().wrapping_add(1); let r = alu::add16(self.hlx(), self.hlx(), self.regs.f); self.set_hlx(r.value); self.regs.f = r.flags;
                self.step = 626;
                pins
            }
            626 => {
                self.step = 627;
                pins
            }
            627 => {
                self.step = 628;
                pins
            }
            628 => {
                self.step = 629;
                pins
            }
            629 => {
                self.step = 630;
                pins
            }
            630 => {
                self.step = 631;
                pins
            }
            631 => {
                self.step = 632;
                pins
            }
            632 => {
                self.begin_fetch(pins)
            }
            42 => {
                self.step = 633;
                pins
            }
            633 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 634;
                pins
            }
            634 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 635;
                pins
            }
            635 => {
                self.step = 636;
                pins
            }
            636 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 637;
                pins
            }
            637 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 638;
                pins
            }
            638 => {
                self.step = 639;
                pins
            }
            639 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.wz_post_inc(), MREQ | RD);
                self.step = 640;
                pins
            }
            640 => {
                self.set_hlx_l(get_data(pins));
                self.step = 641;
                pins
            }
            641 => {
                self.step = 642;
                pins
            }
            642 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.wz, MREQ | RD);
                self.step = 643;
                pins
            }
            643 => {
                self.set_hlx_h(get_data(pins));
                self.step = 644;
                pins
            }
            644 => {
                self.begin_fetch(pins)
            }
            43 => {
                self.set_hlx(self.hlx().wrapping_sub(1));
                self.step = 645;
                pins
            }
            645 => {
                self.step = 646;
                pins
            }
            646 => {
                self.begin_fetch(pins)
            }
            44 => {
                let r = alu::inc8(self.hlx_l(), self.regs.f); self.set_hlx_l(r.value); self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            45 => {
                let r = alu::dec8(self.hlx_l(), self.regs.f); self.set_hlx_l(r.value); self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            46 => {
                self.step = 647;
                pins
            }
            647 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 648;
                pins
            }
            648 => {
                self.set_hlx_l(get_data(pins));
                self.step = 649;
                pins
            }
            649 => {
                self.begin_fetch(pins)
            }
            47 => {
                let r = alu::cpl(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            48 => {
                self.step = 650;
                pins
            }
            650 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 651;
                pins
            }
            651 => {
                self.dlatch = get_data(pins);
                if !(self.regs.f & FLAG_C == 0) { self.step = 657; return Some(pins); }
                self.step = 652;
                pins
            }
            652 => {
                self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); self.regs.wz = self.regs.pc;
                self.step = 653;
                pins
            }
            653 => {
                self.step = 654;
                pins
            }
            654 => {
                self.step = 655;
                pins
            }
            655 => {
                self.step = 656;
                pins
            }
            656 => {
                self.step = 657;
                pins
            }
            657 => {
                self.begin_fetch(pins)
            }
            49 => {
                self.step = 658;
                pins
            }
            658 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 659;
                pins
            }
            659 => {
                self.regs.set_spl(get_data(pins));
                self.step = 660;
                pins
            }
            660 => {
                self.step = 661;
                pins
            }
            661 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 662;
                pins
            }
            662 => {
                self.regs.set_sph(get_data(pins));
                self.step = 663;
                pins
            }
            663 => {
                self.begin_fetch(pins)
            }
            50 => {
                self.step = 664;
                pins
            }
            664 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 665;
                pins
            }
            665 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 666;
                pins
            }
            666 => {
                self.step = 667;
                pins
            }
            667 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 668;
                pins
            }
            668 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 669;
                pins
            }
            669 => {
                self.step = 670;
                pins
            }
            670 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.wz_post_inc(), self.regs.a, MREQ | WR);
                self.regs.set_wzh(self.regs.a);
                self.step = 671;
                pins
            }
            671 => {
                self.step = 672;
                pins
            }
            672 => {
                self.begin_fetch(pins)
            }
            51 => {
                self.regs.sp = self.regs.sp.wrapping_add(1);
                self.step = 673;
                pins
            }
            673 => {
                self.step = 674;
                pins
            }
            674 => {
                self.begin_fetch(pins)
            }
            52 => {
                self.step = 675;
                pins
            }
            675 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 676;
                pins
            }
            676 => {
                self.dlatch = get_data(pins);
                let r = alu::inc8(self.dlatch, self.regs.f); self.dlatch = r.value; self.regs.f = r.flags;
                self.step = 677;
                pins
            }
            677 => {
                self.step = 678;
                pins
            }
            678 => {
                self.step = 679;
                pins
            }
            679 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.dlatch, MREQ | WR);
                self.step = 680;
                pins
            }
            680 => {
                self.step = 681;
                pins
            }
            681 => {
                self.begin_fetch(pins)
            }
            53 => {
                self.step = 682;
                pins
            }
            682 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 683;
                pins
            }
            683 => {
                self.dlatch = get_data(pins);
                let r = alu::dec8(self.dlatch, self.regs.f); self.dlatch = r.value; self.regs.f = r.flags;
                self.step = 684;
                pins
            }
            684 => {
                self.step = 685;
                pins
            }
            685 => {
                self.step = 686;
                pins
            }
            686 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.dlatch, MREQ | WR);
                self.step = 687;
                pins
            }
            687 => {
                self.step = 688;
                pins
            }
            688 => {
                self.begin_fetch(pins)
            }
            54 => {
                self.step = 689;
                pins
            }
            689 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 690;
                pins
            }
            690 => {
                self.dlatch = get_data(pins);
                self.step = 691;
                pins
            }
            691 => {
                self.step = 692;
                pins
            }
            692 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.dlatch, MREQ | WR);
                self.step = 693;
                pins
            }
            693 => {
                self.step = 694;
                pins
            }
            694 => {
                self.begin_fetch(pins)
            }
            55 => {
                self.regs.f = alu::scf(self.regs.a, self.regs.f);
                self.begin_fetch(pins)
            }
            56 => {
                self.step = 695;
                pins
            }
            695 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 696;
                pins
            }
            696 => {
                self.dlatch = get_data(pins);
                if !(self.regs.f & FLAG_C != 0) { self.step = 702; return Some(pins); }
                self.step = 697;
                pins
            }
            697 => {
                self.regs.pc = self.regs.pc.wrapping_add_signed(self.dlatch as i8 as i16); self.regs.wz = self.regs.pc;
                self.step = 698;
                pins
            }
            698 => {
                self.step = 699;
                pins
            }
            699 => {
                self.step = 700;
                pins
            }
            700 => {
                self.step = 701;
                pins
            }
            701 => {
                self.step = 702;
                pins
            }
            702 => {
                self.begin_fetch(pins)
            }
            57 => {
                self.regs.wz = self.hlx().wrapping_add(1); let r = alu::add16(self.hlx(), self.regs.sp, self.regs.f); self.set_hlx(r.value); self.regs.f = r.flags;
                self.step = 703;
                pins
            }
            703 => {
                self.step = 704;
                pins
            }
            704 => {
                self.step = 705;
                pins
            }
            705 => {
                self.step = 706;
                pins
            }
            706 => {
                self.step = 707;
                pins
            }
            707 => {
                self.step = 708;
                pins
            }
            708 => {
                self.step = 709;
                pins
            }
            709 => {
                self.begin_fetch(pins)
            }
            58 => {
                self.step = 710;
                pins
            }
            710 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 711;
                pins
            }
            711 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 712;
                pins
            }
            712 => {
                self.step = 713;
                pins
            }
            713 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 714;
                pins
            }
            714 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 715;
                pins
            }
            715 => {
                self.step = 716;
                pins
            }
            716 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.wz_post_inc(), MREQ | RD);
                self.step = 717;
                pins
            }
            717 => {
                self.regs.a = get_data(pins);
                self.step = 718;
                pins
            }
            718 => {
                self.begin_fetch(pins)
            }
            59 => {
                self.regs.sp = self.regs.sp.wrapping_sub(1);
                self.step = 719;
                pins
            }
            719 => {
                self.step = 720;
                pins
            }
            720 => {
                self.begin_fetch(pins)
            }
            60 => {
                let r = alu::inc8(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            61 => {
                let r = alu::dec8(self.regs.a, self.regs.f); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            62 => {
                self.step = 721;
                pins
            }
            721 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 722;
                pins
            }
            722 => {
                self.regs.a = get_data(pins);
                self.step = 723;
                pins
            }
            723 => {
                self.begin_fetch(pins)
            }
            63 => {
                self.regs.f = alu::ccf(self.regs.a, self.regs.f);
                self.begin_fetch(pins)
            }
            64 => {
                self.regs.b = self.regs.b;
                self.begin_fetch(pins)
            }
            65 => {
                self.regs.b = self.regs.c;
                self.begin_fetch(pins)
            }
            66 => {
                self.regs.b = self.regs.d;
                self.begin_fetch(pins)
            }
            67 => {
                self.regs.b = self.regs.e;
                self.begin_fetch(pins)
            }
            68 => {
                self.regs.b = self.hlx_h();
                self.begin_fetch(pins)
            }
            69 => {
                self.regs.b = self.hlx_l();
                self.begin_fetch(pins)
            }
            70 => {
                self.step = 724;
                pins
            }
            724 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 725;
                pins
            }
            725 => {
                self.regs.b = get_data(pins);
                self.step = 726;
                pins
            }
            726 => {
                self.begin_fetch(pins)
            }
            71 => {
                self.regs.b = self.regs.a;
                self.begin_fetch(pins)
            }
            72 => {
                self.regs.c = self.regs.b;
                self.begin_fetch(pins)
            }
            73 => {
                self.regs.c = self.regs.c;
                self.begin_fetch(pins)
            }
            74 => {
                self.regs.c = self.regs.d;
                self.begin_fetch(pins)
            }
            75 => {
                self.regs.c = self.regs.e;
                self.begin_fetch(pins)
            }
            76 => {
                self.regs.c = self.hlx_h();
                self.begin_fetch(pins)
            }
            77 => {
                self.regs.c = self.hlx_l();
                self.begin_fetch(pins)
            }
            78 => {
                self.step = 727;
                pins
            }
            727 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 728;
                pins
            }
            728 => {
                self.regs.c = get_data(pins);
                self.step = 729;
                pins
            }
            729 => {
                self.begin_fetch(pins)
            }
            79 => {
                self.regs.c = self.regs.a;
                self.begin_fetch(pins)
            }
            80 => {
                self.regs.d = self.regs.b;
                self.begin_fetch(pins)
            }
            81 => {
                self.regs.d = self.regs.c;
                self.begin_fetch(pins)
            }
            82 => {
                self.regs.d = self.regs.d;
                self.begin_fetch(pins)
            }
            83 => {
                self.regs.d = self.regs.e;
                self.begin_fetch(pins)
            }
            84 => {
                self.regs.d = self.hlx_h();
                self.begin_fetch(pins)
            }
            85 => {
                self.regs.d = self.hlx_l();
                self.begin_fetch(pins)
            }
            86 => {
                self.step = 730;
                pins
            }
            730 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 731;
                pins
            }
            731 => {
                self.regs.d = get_data(pins);
                self.step = 732;
                pins
            }
            732 => {
                self.begin_fetch(pins)
            }
            87 => {
                self.regs.d = self.regs.a;
                self.begin_fetch(pins)
            }
            88 => {
                self.regs.e = self.regs.b;
                self.begin_fetch(pins)
            }
            89 => {
                self.regs.e = self.regs.c;
                self.begin_fetch(pins)
            }
            90 => {
                self.regs.e = self.regs.d;
                self.begin_fetch(pins)
            }
            91 => {
                self.regs.e = self.regs.e;
                self.begin_fetch(pins)
            }
            92 => {
                self.regs.e = self.hlx_h();
                self.begin_fetch(pins)
            }
            93 => {
                self.regs.e = self.hlx_l();
                self.begin_fetch(pins)
            }
            94 => {
                self.step = 733;
                pins
            }
            733 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 734;
                pins
            }
            734 => {
                self.regs.e = get_data(pins);
                self.step = 735;
                pins
            }
            735 => {
                self.begin_fetch(pins)
            }
            95 => {
                self.regs.e = self.regs.a;
                self.begin_fetch(pins)
            }
            96 => {
                self.set_hlx_h(self.regs.b);
                self.begin_fetch(pins)
            }
            97 => {
                self.set_hlx_h(self.regs.c);
                self.begin_fetch(pins)
            }
            98 => {
                self.set_hlx_h(self.regs.d);
                self.begin_fetch(pins)
            }
            99 => {
                self.set_hlx_h(self.regs.e);
                self.begin_fetch(pins)
            }
            100 => {
                self.set_hlx_h(self.hlx_h());
                self.begin_fetch(pins)
            }
            101 => {
                self.set_hlx_h(self.hlx_l());
                self.begin_fetch(pins)
            }
            102 => {
                self.step = 736;
                pins
            }
            736 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 737;
                pins
            }
            737 => {
                self.regs.h = get_data(pins);
                self.step = 738;
                pins
            }
            738 => {
                self.begin_fetch(pins)
            }
            103 => {
                self.set_hlx_h(self.regs.a);
                self.begin_fetch(pins)
            }
            104 => {
                self.set_hlx_l(self.regs.b);
                self.begin_fetch(pins)
            }
            105 => {
                self.set_hlx_l(self.regs.c);
                self.begin_fetch(pins)
            }
            106 => {
                self.set_hlx_l(self.regs.d);
                self.begin_fetch(pins)
            }
            107 => {
                self.set_hlx_l(self.regs.e);
                self.begin_fetch(pins)
            }
            108 => {
                self.set_hlx_l(self.hlx_h());
                self.begin_fetch(pins)
            }
            109 => {
                self.set_hlx_l(self.hlx_l());
                self.begin_fetch(pins)
            }
            110 => {
                self.step = 739;
                pins
            }
            739 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 740;
                pins
            }
            740 => {
                self.regs.l = get_data(pins);
                self.step = 741;
                pins
            }
            741 => {
                self.begin_fetch(pins)
            }
            111 => {
                self.set_hlx_l(self.regs.a);
                self.begin_fetch(pins)
            }
            112 => {
                self.step = 742;
                pins
            }
            742 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.regs.b, MREQ | WR);
                self.step = 743;
                pins
            }
            743 => {
                self.step = 744;
                pins
            }
            744 => {
                self.begin_fetch(pins)
            }
            113 => {
                self.step = 745;
                pins
            }
            745 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.regs.c, MREQ | WR);
                self.step = 746;
                pins
            }
            746 => {
                self.step = 747;
                pins
            }
            747 => {
                self.begin_fetch(pins)
            }
            114 => {
                self.step = 748;
                pins
            }
            748 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.regs.d, MREQ | WR);
                self.step = 749;
                pins
            }
            749 => {
                self.step = 750;
                pins
            }
            750 => {
                self.begin_fetch(pins)
            }
            115 => {
                self.step = 751;
                pins
            }
            751 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.regs.e, MREQ | WR);
                self.step = 752;
                pins
            }
            752 => {
                self.step = 753;
                pins
            }
            753 => {
                self.begin_fetch(pins)
            }
            116 => {
                self.step = 754;
                pins
            }
            754 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.regs.h, MREQ | WR);
                self.step = 755;
                pins
            }
            755 => {
                self.step = 756;
                pins
            }
            756 => {
                self.begin_fetch(pins)
            }
            117 => {
                self.step = 757;
                pins
            }
            757 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.regs.l, MREQ | WR);
                self.step = 758;
                pins
            }
            758 => {
                self.step = 759;
                pins
            }
            759 => {
                self.begin_fetch(pins)
            }
            119 => {
                self.step = 760;
                pins
            }
            760 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.addr, self.regs.a, MREQ | WR);
                self.step = 761;
                pins
            }
            761 => {
                self.step = 762;
                pins
            }
            762 => {
                self.begin_fetch(pins)
            }
            120 => {
                self.regs.a = self.regs.b;
                self.begin_fetch(pins)
            }
            121 => {
                self.regs.a = self.regs.c;
                self.begin_fetch(pins)
            }
            122 => {
                self.regs.a = self.regs.d;
                self.begin_fetch(pins)
            }
            123 => {
                self.regs.a = self.regs.e;
                self.begin_fetch(pins)
            }
            124 => {
                self.regs.a = self.hlx_h();
                self.begin_fetch(pins)
            }
            125 => {
                self.regs.a = self.hlx_l();
                self.begin_fetch(pins)
            }
            126 => {
                self.step = 763;
                pins
            }
            763 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 764;
                pins
            }
            764 => {
                self.regs.a = get_data(pins);
                self.step = 765;
                pins
            }
            765 => {
                self.begin_fetch(pins)
            }
            127 => {
                self.regs.a = self.regs.a;
                self.begin_fetch(pins)
            }
            128 => {
                self.alu_op(0, self.regs.b);
                self.begin_fetch(pins)
            }
            129 => {
                self.alu_op(0, self.regs.c);
                self.begin_fetch(pins)
            }
            130 => {
                self.alu_op(0, self.regs.d);
                self.begin_fetch(pins)
            }
            131 => {
                self.alu_op(0, self.regs.e);
                self.begin_fetch(pins)
            }
            132 => {
                self.alu_op(0, self.hlx_h());
                self.begin_fetch(pins)
            }
            133 => {
                self.alu_op(0, self.hlx_l());
                self.begin_fetch(pins)
            }
            134 => {
                self.step = 766;
                pins
            }
            766 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 767;
                pins
            }
            767 => {
                self.dlatch = get_data(pins);
                self.alu_op(0, self.dlatch);
                self.step = 768;
                pins
            }
            768 => {
                self.begin_fetch(pins)
            }
            135 => {
                self.alu_op(0, self.regs.a);
                self.begin_fetch(pins)
            }
            136 => {
                self.alu_op(1, self.regs.b);
                self.begin_fetch(pins)
            }
            137 => {
                self.alu_op(1, self.regs.c);
                self.begin_fetch(pins)
            }
            138 => {
                self.alu_op(1, self.regs.d);
                self.begin_fetch(pins)
            }
            139 => {
                self.alu_op(1, self.regs.e);
                self.begin_fetch(pins)
            }
            140 => {
                self.alu_op(1, self.hlx_h());
                self.begin_fetch(pins)
            }
            141 => {
                self.alu_op(1, self.hlx_l());
                self.begin_fetch(pins)
            }
            142 => {
                self.step = 769;
                pins
            }
            769 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 770;
                pins
            }
            770 => {
                self.dlatch = get_data(pins);
                self.alu_op(1, self.dlatch);
                self.step = 771;
                pins
            }
            771 => {
                self.begin_fetch(pins)
            }
            143 => {
                self.alu_op(1, self.regs.a);
                self.begin_fetch(pins)
            }
            144 => {
                self.alu_op(2, self.regs.b);
                self.begin_fetch(pins)
            }
            145 => {
                self.alu_op(2, self.regs.c);
                self.begin_fetch(pins)
            }
            146 => {
                self.alu_op(2, self.regs.d);
                self.begin_fetch(pins)
            }
            147 => {
                self.alu_op(2, self.regs.e);
                self.begin_fetch(pins)
            }
            148 => {
                self.alu_op(2, self.hlx_h());
                self.begin_fetch(pins)
            }
            149 => {
                self.alu_op(2, self.hlx_l());
                self.begin_fetch(pins)
            }
            150 => {
                self.step = 772;
                pins
            }
            772 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 773;
                pins
            }
            773 => {
                self.dlatch = get_data(pins);
                self.alu_op(2, self.dlatch);
                self.step = 774;
                pins
            }
            774 => {
                self.begin_fetch(pins)
            }
            151 => {
                self.alu_op(2, self.regs.a);
                self.begin_fetch(pins)
            }
            152 => {
                self.alu_op(3, self.regs.b);
                self.begin_fetch(pins)
            }
            153 => {
                self.alu_op(3, self.regs.c);
                self.begin_fetch(pins)
            }
            154 => {
                self.alu_op(3, self.regs.d);
                self.begin_fetch(pins)
            }
            155 => {
                self.alu_op(3, self.regs.e);
                self.begin_fetch(pins)
            }
            156 => {
                self.alu_op(3, self.hlx_h());
                self.begin_fetch(pins)
            }
            157 => {
                self.alu_op(3, self.hlx_l());
                self.begin_fetch(pins)
            }
            158 => {
                self.step = 775;
                pins
            }
            775 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 776;
                pins
            }
            776 => {
                self.dlatch = get_data(pins);
                self.alu_op(3, self.dlatch);
                self.step = 777;
                pins
            }
            777 => {
                self.begin_fetch(pins)
            }
            159 => {
                self.alu_op(3, self.regs.a);
                self.begin_fetch(pins)
            }
            160 => {
                self.alu_op(4, self.regs.b);
                self.begin_fetch(pins)
            }
            161 => {
                self.alu_op(4, self.regs.c);
                self.begin_fetch(pins)
            }
            162 => {
                self.alu_op(4, self.regs.d);
                self.begin_fetch(pins)
            }
            163 => {
                self.alu_op(4, self.regs.e);
                self.begin_fetch(pins)
            }
            164 => {
                self.alu_op(4, self.hlx_h());
                self.begin_fetch(pins)
            }
            165 => {
                self.alu_op(4, self.hlx_l());
                self.begin_fetch(pins)
            }
            166 => {
                self.step = 778;
                pins
            }
            778 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 779;
                pins
            }
            779 => {
                self.dlatch = get_data(pins);
                self.alu_op(4, self.dlatch);
                self.step = 780;
                pins
            }
            780 => {
                self.begin_fetch(pins)
            }
            167 => {
                self.alu_op(4, self.regs.a);
                self.begin_fetch(pins)
            }
            168 => {
                self.alu_op(5, self.regs.b);
                self.begin_fetch(pins)
            }
            169 => {
                self.alu_op(5, self.regs.c);
                self.begin_fetch(pins)
            }
            170 => {
                self.alu_op(5, self.regs.d);
                self.begin_fetch(pins)
            }
            171 => {
                self.alu_op(5, self.regs.e);
                self.begin_fetch(pins)
            }
            172 => {
                self.alu_op(5, self.hlx_h());
                self.begin_fetch(pins)
            }
            173 => {
                self.alu_op(5, self.hlx_l());
                self.begin_fetch(pins)
            }
            174 => {
                self.step = 781;
                pins
            }
            781 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 782;
                pins
            }
            782 => {
                self.dlatch = get_data(pins);
                self.alu_op(5, self.dlatch);
                self.step = 783;
                pins
            }
            783 => {
                self.begin_fetch(pins)
            }
            175 => {
                self.alu_op(5, self.regs.a);
                self.begin_fetch(pins)
            }
            176 => {
                self.alu_op(6, self.regs.b);
                self.begin_fetch(pins)
            }
            177 => {
                self.alu_op(6, self.regs.c);
                self.begin_fetch(pins)
            }
            178 => {
                self.alu_op(6, self.regs.d);
                self.begin_fetch(pins)
            }
            179 => {
                self.alu_op(6, self.regs.e);
                self.begin_fetch(pins)
            }
            180 => {
                self.alu_op(6, self.hlx_h());
                self.begin_fetch(pins)
            }
            181 => {
                self.alu_op(6, self.hlx_l());
                self.begin_fetch(pins)
            }
            182 => {
                self.step = 784;
                pins
            }
            784 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 785;
                pins
            }
            785 => {
                self.dlatch = get_data(pins);
                self.alu_op(6, self.dlatch);
                self.step = 786;
                pins
            }
            786 => {
                self.begin_fetch(pins)
            }
            183 => {
                self.alu_op(6, self.regs.a);
                self.begin_fetch(pins)
            }
            184 => {
                self.alu_op(7, self.regs.b);
                self.begin_fetch(pins)
            }
            185 => {
                self.alu_op(7, self.regs.c);
                self.begin_fetch(pins)
            }
            186 => {
                self.alu_op(7, self.regs.d);
                self.begin_fetch(pins)
            }
            187 => {
                self.alu_op(7, self.regs.e);
                self.begin_fetch(pins)
            }
            188 => {
                self.alu_op(7, self.hlx_h());
                self.begin_fetch(pins)
            }
            189 => {
                self.alu_op(7, self.hlx_l());
                self.begin_fetch(pins)
            }
            190 => {
                self.step = 787;
                pins
            }
            787 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.addr, MREQ | RD);
                self.step = 788;
                pins
            }
            788 => {
                self.dlatch = get_data(pins);
                self.alu_op(7, self.dlatch);
                self.step = 789;
                pins
            }
            789 => {
                self.begin_fetch(pins)
            }
            191 => {
                self.alu_op(7, self.regs.a);
                self.begin_fetch(pins)
            }
            192 => {
                if !(self.regs.f & FLAG_Z == 0) { self.step = 796; return Some(pins); }
                self.step = 790;
                pins
            }
            790 => {
                self.step = 791;
                pins
            }
            791 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 792;
                pins
            }
            792 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 793;
                pins
            }
            793 => {
                self.step = 794;
                pins
            }
            794 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 795;
                pins
            }
            795 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 796;
                pins
            }
            796 => {
                self.begin_fetch(pins)
            }
            193 => {
                self.step = 797;
                pins
            }
            797 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 798;
                pins
            }
            798 => {
                self.regs.c = get_data(pins);
                self.step = 799;
                pins
            }
            799 => {
                self.step = 800;
                pins
            }
            800 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 801;
                pins
            }
            801 => {
                self.regs.b = get_data(pins);
                self.step = 802;
                pins
            }
            802 => {
                self.begin_fetch(pins)
            }
            194 => {
                self.step = 803;
                pins
            }
            803 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 804;
                pins
            }
            804 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 805;
                pins
            }
            805 => {
                self.step = 806;
                pins
            }
            806 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 807;
                pins
            }
            807 => {
                self.regs.set_wzh(get_data(pins));
                if self.regs.f & FLAG_Z == 0 { self.regs.pc = self.regs.wz; }
                self.step = 808;
                pins
            }
            808 => {
                self.begin_fetch(pins)
            }
            195 => {
                self.step = 809;
                pins
            }
            809 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 810;
                pins
            }
            810 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 811;
                pins
            }
            811 => {
                self.step = 812;
                pins
            }
            812 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 813;
                pins
            }
            813 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 814;
                pins
            }
            814 => {
                self.begin_fetch(pins)
            }
            196 => {
                self.step = 815;
                pins
            }
            815 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 816;
                pins
            }
            816 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 817;
                pins
            }
            817 => {
                self.step = 818;
                pins
            }
            818 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 819;
                pins
            }
            819 => {
                self.regs.set_wzh(get_data(pins));
                if !(self.regs.f & FLAG_Z == 0) { self.step = 827; return Some(pins); }
                self.step = 820;
                pins
            }
            820 => {
                self.step = 821;
                pins
            }
            821 => {
                self.step = 822;
                pins
            }
            822 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 823;
                pins
            }
            823 => {
                self.step = 824;
                pins
            }
            824 => {
                self.step = 825;
                pins
            }
            825 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 826;
                pins
            }
            826 => {
                self.step = 827;
                pins
            }
            827 => {
                self.begin_fetch(pins)
            }
            197 => {
                self.step = 828;
                pins
            }
            828 => {
                self.step = 829;
                pins
            }
            829 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.b, MREQ | WR);
                self.step = 830;
                pins
            }
            830 => {
                self.step = 831;
                pins
            }
            831 => {
                self.step = 832;
                pins
            }
            832 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.c, MREQ | WR);
                self.step = 833;
                pins
            }
            833 => {
                self.step = 834;
                pins
            }
            834 => {
                self.begin_fetch(pins)
            }
            198 => {
                self.step = 835;
                pins
            }
            835 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 836;
                pins
            }
            836 => {
                self.dlatch = get_data(pins);
                self.alu_op(0, self.dlatch);
                self.step = 837;
                pins
            }
            837 => {
                self.begin_fetch(pins)
            }
            199 => {
                self.step = 838;
                pins
            }
            838 => {
                self.step = 839;
                pins
            }
            839 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 840;
                pins
            }
            840 => {
                self.step = 841;
                pins
            }
            841 => {
                self.step = 842;
                pins
            }
            842 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.wz = 0; self.regs.pc = self.regs.wz;
                self.step = 843;
                pins
            }
            843 => {
                self.step = 844;
                pins
            }
            844 => {
                self.begin_fetch(pins)
            }
            200 => {
                if !(self.regs.f & FLAG_Z != 0) { self.step = 851; return Some(pins); }
                self.step = 845;
                pins
            }
            845 => {
                self.step = 846;
                pins
            }
            846 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 847;
                pins
            }
            847 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 848;
                pins
            }
            848 => {
                self.step = 849;
                pins
            }
            849 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 850;
                pins
            }
            850 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 851;
                pins
            }
            851 => {
                self.begin_fetch(pins)
            }
            201 => {
                self.step = 852;
                pins
            }
            852 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 853;
                pins
            }
            853 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 854;
                pins
            }
            854 => {
                self.step = 855;
                pins
            }
            855 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 856;
                pins
            }
            856 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 857;
                pins
            }
            857 => {
                self.begin_fetch(pins)
            }
            202 => {
                self.step = 858;
                pins
            }
            858 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 859;
                pins
            }
            859 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 860;
                pins
            }
            860 => {
                self.step = 861;
                pins
            }
            861 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 862;
                pins
            }
            862 => {
                self.regs.set_wzh(get_data(pins));
                if self.regs.f & FLAG_Z != 0 { self.regs.pc = self.regs.wz; }
                self.step = 863;
                pins
            }
            863 => {
                self.begin_fetch(pins)
            }
            204 => {
                self.step = 864;
                pins
            }
            864 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 865;
                pins
            }
            865 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 866;
                pins
            }
            866 => {
                self.step = 867;
                pins
            }
            867 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 868;
                pins
            }
            868 => {
                self.regs.set_wzh(get_data(pins));
                if !(self.regs.f & FLAG_Z != 0) { self.step = 876; return Some(pins); }
                self.step = 869;
                pins
            }
            869 => {
                self.step = 870;
                pins
            }
            870 => {
                self.step = 871;
                pins
            }
            871 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 872;
                pins
            }
            872 => {
                self.step = 873;
                pins
            }
            873 => {
                self.step = 874;
                pins
            }
            874 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 875;
                pins
            }
            875 => {
                self.step = 876;
                pins
            }
            876 => {
                self.begin_fetch(pins)
            }
            205 => {
                self.step = 877;
                pins
            }
            877 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 878;
                pins
            }
            878 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 879;
                pins
            }
            879 => {
                self.step = 880;
                pins
            }
            880 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 881;
                pins
            }
            881 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 882;
                pins
            }
            882 => {
                self.step = 883;
                pins
            }
            883 => {
                self.step = 884;
                pins
            }
            884 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 885;
                pins
            }
            885 => {
                self.step = 886;
                pins
            }
            886 => {
                self.step = 887;
                pins
            }
            887 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 888;
                pins
            }
            888 => {
                self.step = 889;
                pins
            }
            889 => {
                self.begin_fetch(pins)
            }
            206 => {
                self.step = 890;
                pins
            }
            890 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 891;
                pins
            }
            891 => {
                self.dlatch = get_data(pins);
                self.alu_op(1, self.dlatch);
                self.step = 892;
                pins
            }
            892 => {
                self.begin_fetch(pins)
            }
            207 => {
                self.step = 893;
                pins
            }
            893 => {
                self.step = 894;
                pins
            }
            894 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 895;
                pins
            }
            895 => {
                self.step = 896;
                pins
            }
            896 => {
                self.step = 897;
                pins
            }
            897 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.wz = 8; self.regs.pc = self.regs.wz;
                self.step = 898;
                pins
            }
            898 => {
                self.step = 899;
                pins
            }
            899 => {
                self.begin_fetch(pins)
            }
            208 => {
                if !(self.regs.f & FLAG_C == 0) { self.step = 906; return Some(pins); }
                self.step = 900;
                pins
            }
            900 => {
                self.step = 901;
                pins
            }
            901 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 902;
                pins
            }
            902 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 903;
                pins
            }
            903 => {
                self.step = 904;
                pins
            }
            904 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 905;
                pins
            }
            905 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 906;
                pins
            }
            906 => {
                self.begin_fetch(pins)
            }
            209 => {
                self.step = 907;
                pins
            }
            907 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 908;
                pins
            }
            908 => {
                self.regs.e = get_data(pins);
                self.step = 909;
                pins
            }
            909 => {
                self.step = 910;
                pins
            }
            910 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 911;
                pins
            }
            911 => {
                self.regs.d = get_data(pins);
                self.step = 912;
                pins
            }
            912 => {
                self.begin_fetch(pins)
            }
            210 => {
                self.step = 913;
                pins
            }
            913 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 914;
                pins
            }
            914 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 915;
                pins
            }
            915 => {
                self.step = 916;
                pins
            }
            916 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 917;
                pins
            }
            917 => {
                self.regs.set_wzh(get_data(pins));
                if self.regs.f & FLAG_C == 0 { self.regs.pc = self.regs.wz; }
                self.step = 918;
                pins
            }
            918 => {
                self.begin_fetch(pins)
            }
            211 => {
                self.step = 919;
                pins
            }
            919 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 920;
                pins
            }
            920 => {
                self.regs.set_wzl(get_data(pins));
                self.regs.set_wzh(self.regs.a);
                self.step = 921;
                pins
            }
            921 => {
                self.step = 922;
                pins
            }
            922 => {
                let pins = set_addr_data_ctrl(pins, self.regs.wz, self.regs.a, IORQ | WR);
                self.step = 923;
                pins
            }
            923 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.set_wzl(self.regs.wzl().wrapping_add(1));
                self.step = 924;
                pins
            }
            924 => {
                self.step = 925;
                pins
            }
            925 => {
                self.begin_fetch(pins)
            }
            212 => {
                self.step = 926;
                pins
            }
            926 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 927;
                pins
            }
            927 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 928;
                pins
            }
            928 => {
                self.step = 929;
                pins
            }
            929 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 930;
                pins
            }
            930 => {
                self.regs.set_wzh(get_data(pins));
                if !(self.regs.f & FLAG_C == 0) { self.step = 938; return Some(pins); }
                self.step = 931;
                pins
            }
            931 => {
                self.step = 932;
                pins
            }
            932 => {
                self.step = 933;
                pins
            }
            933 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 934;
                pins
            }
            934 => {
                self.step = 935;
                pins
            }
            935 => {
                self.step = 936;
                pins
            }
            936 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 937;
                pins
            }
            937 => {
                self.step = 938;
                pins
            }
            938 => {
                self.begin_fetch(pins)
            }
            213 => {
                self.step = 939;
                pins
            }
            939 => {
                self.step = 940;
                pins
            }
            940 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.d, MREQ | WR);
                self.step = 941;
                pins
            }
            941 => {
                self.step = 942;
                pins
            }
            942 => {
                self.step = 943;
                pins
            }
            943 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.e, MREQ | WR);
                self.step = 944;
                pins
            }
            944 => {
                self.step = 945;
                pins
            }
            945 => {
                self.begin_fetch(pins)
            }
            214 => {
                self.step = 946;
                pins
            }
            946 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 947;
                pins
            }
            947 => {
                self.dlatch = get_data(pins);
                self.alu_op(2, self.dlatch);
                self.step = 948;
                pins
            }
            948 => {
                self.begin_fetch(pins)
            }
            215 => {
                self.step = 949;
                pins
            }
            949 => {
                self.step = 950;
                pins
            }
            950 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 951;
                pins
            }
            951 => {
                self.step = 952;
                pins
            }
            952 => {
                self.step = 953;
                pins
            }
            953 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.wz = 16; self.regs.pc = self.regs.wz;
                self.step = 954;
                pins
            }
            954 => {
                self.step = 955;
                pins
            }
            955 => {
                self.begin_fetch(pins)
            }
            216 => {
                if !(self.regs.f & FLAG_C != 0) { self.step = 962; return Some(pins); }
                self.step = 956;
                pins
            }
            956 => {
                self.step = 957;
                pins
            }
            957 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 958;
                pins
            }
            958 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 959;
                pins
            }
            959 => {
                self.step = 960;
                pins
            }
            960 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 961;
                pins
            }
            961 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 962;
                pins
            }
            962 => {
                self.begin_fetch(pins)
            }
            217 => {
                std::mem::swap(&mut self.regs.b, &mut self.regs.b_); std::mem::swap(&mut self.regs.c, &mut self.regs.c_); std::mem::swap(&mut self.regs.d, &mut self.regs.d_); std::mem::swap(&mut self.regs.e, &mut self.regs.e_); std::mem::swap(&mut self.regs.h, &mut self.regs.h_); std::mem::swap(&mut self.regs.l, &mut self.regs.l_);
                self.begin_fetch(pins)
            }
            218 => {
                self.step = 963;
                pins
            }
            963 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 964;
                pins
            }
            964 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 965;
                pins
            }
            965 => {
                self.step = 966;
                pins
            }
            966 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 967;
                pins
            }
            967 => {
                self.regs.set_wzh(get_data(pins));
                if self.regs.f & FLAG_C != 0 { self.regs.pc = self.regs.wz; }
                self.step = 968;
                pins
            }
            968 => {
                self.begin_fetch(pins)
            }
            219 => {
                self.step = 969;
                pins
            }
            969 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 970;
                pins
            }
            970 => {
                self.regs.set_wzl(get_data(pins));
                self.regs.set_wzh(self.regs.a);
                self.step = 971;
                pins
            }
            971 => {
                self.step = 972;
                pins
            }
            972 => {
                self.step = 973;
                pins
            }
            973 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.wz_post_inc(), IORQ | RD);
                self.step = 974;
                pins
            }
            974 => {
                self.regs.a = get_data(pins);
                self.step = 975;
                pins
            }
            975 => {
                self.begin_fetch(pins)
            }
            220 => {
                self.step = 976;
                pins
            }
            976 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 977;
                pins
            }
            977 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 978;
                pins
            }
            978 => {
                self.step = 979;
                pins
            }
            979 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 980;
                pins
            }
            980 => {
                self.regs.set_wzh(get_data(pins));
                if !(self.regs.f & FLAG_C != 0) { self.step = 988; return Some(pins); }
                self.step = 981;
                pins
            }
            981 => {
                self.step = 982;
                pins
            }
            982 => {
                self.step = 983;
                pins
            }
            983 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 984;
                pins
            }
            984 => {
                self.step = 985;
                pins
            }
            985 => {
                self.step = 986;
                pins
            }
            986 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 987;
                pins
            }
            987 => {
                self.step = 988;
                pins
            }
            988 => {
                self.begin_fetch(pins)
            }
            222 => {
                self.step = 989;
                pins
            }
            989 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 990;
                pins
            }
            990 => {
                self.dlatch = get_data(pins);
                self.alu_op(3, self.dlatch);
                self.step = 991;
                pins
            }
            991 => {
                self.begin_fetch(pins)
            }
            223 => {
                self.step = 992;
                pins
            }
            992 => {
                self.step = 993;
                pins
            }
            993 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 994;
                pins
            }
            994 => {
                self.step = 995;
                pins
            }
            995 => {
                self.step = 996;
                pins
            }
            996 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.wz = 24; self.regs.pc = self.regs.wz;
                self.step = 997;
                pins
            }
            997 => {
                self.step = 998;
                pins
            }
            998 => {
                self.begin_fetch(pins)
            }
            224 => {
                if !(self.regs.f & FLAG_PV == 0) { self.step = 1005; return Some(pins); }
                self.step = 999;
                pins
            }
            999 => {
                self.step = 1000;
                pins
            }
            1000 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1001;
                pins
            }
            1001 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1002;
                pins
            }
            1002 => {
                self.step = 1003;
                pins
            }
            1003 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1004;
                pins
            }
            1004 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1005;
                pins
            }
            1005 => {
                self.begin_fetch(pins)
            }
            225 => {
                self.step = 1006;
                pins
            }
            1006 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1007;
                pins
            }
            1007 => {
                self.set_hlx_l(get_data(pins));
                self.step = 1008;
                pins
            }
            1008 => {
                self.step = 1009;
                pins
            }
            1009 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1010;
                pins
            }
            1010 => {
                self.set_hlx_h(get_data(pins));
                self.step = 1011;
                pins
            }
            1011 => {
                self.begin_fetch(pins)
            }
            226 => {
                self.step = 1012;
                pins
            }
            1012 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1013;
                pins
            }
            1013 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1014;
                pins
            }
            1014 => {
                self.step = 1015;
                pins
            }
            1015 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1016;
                pins
            }
            1016 => {
                self.regs.set_wzh(get_data(pins));
                if self.regs.f & FLAG_PV == 0 { self.regs.pc = self.regs.wz; }
                self.step = 1017;
                pins
            }
            1017 => {
                self.begin_fetch(pins)
            }
            227 => {
                self.step = 1018;
                pins
            }
            1018 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.sp, MREQ | RD);
                self.step = 1019;
                pins
            }
            1019 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1020;
                pins
            }
            1020 => {
                self.step = 1021;
                pins
            }
            1021 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.sp.wrapping_add(1), MREQ | RD);
                self.step = 1022;
                pins
            }
            1022 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1023;
                pins
            }
            1023 => {
                self.step = 1024;
                pins
            }
            1024 => {
                self.step = 1025;
                pins
            }
            1025 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.sp.wrapping_add(1), self.hlx_h(), MREQ | WR);
                self.step = 1026;
                pins
            }
            1026 => {
                self.step = 1027;
                pins
            }
            1027 => {
                self.step = 1028;
                pins
            }
            1028 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.sp, self.hlx_l(), MREQ | WR);
                self.set_hlx(self.regs.wz);
                self.step = 1029;
                pins
            }
            1029 => {
                self.step = 1030;
                pins
            }
            1030 => {
                self.step = 1031;
                pins
            }
            1031 => {
                self.step = 1032;
                pins
            }
            1032 => {
                self.begin_fetch(pins)
            }
            228 => {
                self.step = 1033;
                pins
            }
            1033 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1034;
                pins
            }
            1034 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1035;
                pins
            }
            1035 => {
                self.step = 1036;
                pins
            }
            1036 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1037;
                pins
            }
            1037 => {
                self.regs.set_wzh(get_data(pins));
                if !(self.regs.f & FLAG_PV == 0) { self.step = 1045; return Some(pins); }
                self.step = 1038;
                pins
            }
            1038 => {
                self.step = 1039;
                pins
            }
            1039 => {
                self.step = 1040;
                pins
            }
            1040 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 1041;
                pins
            }
            1041 => {
                self.step = 1042;
                pins
            }
            1042 => {
                self.step = 1043;
                pins
            }
            1043 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 1044;
                pins
            }
            1044 => {
                self.step = 1045;
                pins
            }
            1045 => {
                self.begin_fetch(pins)
            }
            229 => {
                self.step = 1046;
                pins
            }
            1046 => {
                self.step = 1047;
                pins
            }
            1047 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.hlx_h(), MREQ | WR);
                self.step = 1048;
                pins
            }
            1048 => {
                self.step = 1049;
                pins
            }
            1049 => {
                self.step = 1050;
                pins
            }
            1050 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.hlx_l(), MREQ | WR);
                self.step = 1051;
                pins
            }
            1051 => {
                self.step = 1052;
                pins
            }
            1052 => {
                self.begin_fetch(pins)
            }
            230 => {
                self.step = 1053;
                pins
            }
            1053 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1054;
                pins
            }
            1054 => {
                self.dlatch = get_data(pins);
                self.alu_op(4, self.dlatch);
                self.step = 1055;
                pins
            }
            1055 => {
                self.begin_fetch(pins)
            }
            231 => {
                self.step = 1056;
                pins
            }
            1056 => {
                self.step = 1057;
                pins
            }
            1057 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 1058;
                pins
            }
            1058 => {
                self.step = 1059;
                pins
            }
            1059 => {
                self.step = 1060;
                pins
            }
            1060 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.wz = 32; self.regs.pc = self.regs.wz;
                self.step = 1061;
                pins
            }
            1061 => {
                self.step = 1062;
                pins
            }
            1062 => {
                self.begin_fetch(pins)
            }
            232 => {
                if !(self.regs.f & FLAG_PV != 0) { self.step = 1069; return Some(pins); }
                self.step = 1063;
                pins
            }
            1063 => {
                self.step = 1064;
                pins
            }
            1064 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1065;
                pins
            }
            1065 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1066;
                pins
            }
            1066 => {
                self.step = 1067;
                pins
            }
            1067 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1068;
                pins
            }
            1068 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1069;
                pins
            }
            1069 => {
                self.begin_fetch(pins)
            }
            233 => {
                self.regs.pc = self.hlx();
                self.begin_fetch(pins)
            }
            234 => {
                self.step = 1070;
                pins
            }
            1070 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1071;
                pins
            }
            1071 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1072;
                pins
            }
            1072 => {
                self.step = 1073;
                pins
            }
            1073 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1074;
                pins
            }
            1074 => {
                self.regs.set_wzh(get_data(pins));
                if self.regs.f & FLAG_PV != 0 { self.regs.pc = self.regs.wz; }
                self.step = 1075;
                pins
            }
            1075 => {
                self.begin_fetch(pins)
            }
            235 => {
                let de = self.regs.de(); self.regs.set_de(self.regs.hl()); self.regs.set_hl(de);
                self.begin_fetch(pins)
            }
            236 => {
                self.step = 1076;
                pins
            }
            1076 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1077;
                pins
            }
            1077 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1078;
                pins
            }
            1078 => {
                self.step = 1079;
                pins
            }
            1079 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1080;
                pins
            }
            1080 => {
                self.regs.set_wzh(get_data(pins));
                if !(self.regs.f & FLAG_PV != 0) { self.step = 1088; return Some(pins); }
                self.step = 1081;
                pins
            }
            1081 => {
                self.step = 1082;
                pins
            }
            1082 => {
                self.step = 1083;
                pins
            }
            1083 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 1084;
                pins
            }
            1084 => {
                self.step = 1085;
                pins
            }
            1085 => {
                self.step = 1086;
                pins
            }
            1086 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 1087;
                pins
            }
            1087 => {
                self.step = 1088;
                pins
            }
            1088 => {
                self.begin_fetch(pins)
            }
            237 => {
                self.begin_fetch_ed(pins)
            }
            238 => {
                self.step = 1089;
                pins
            }
            1089 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1090;
                pins
            }
            1090 => {
                self.dlatch = get_data(pins);
                self.alu_op(5, self.dlatch);
                self.step = 1091;
                pins
            }
            1091 => {
                self.begin_fetch(pins)
            }
            239 => {
                self.step = 1092;
                pins
            }
            1092 => {
                self.step = 1093;
                pins
            }
            1093 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 1094;
                pins
            }
            1094 => {
                self.step = 1095;
                pins
            }
            1095 => {
                self.step = 1096;
                pins
            }
            1096 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.wz = 40; self.regs.pc = self.regs.wz;
                self.step = 1097;
                pins
            }
            1097 => {
                self.step = 1098;
                pins
            }
            1098 => {
                self.begin_fetch(pins)
            }
            240 => {
                if !(self.regs.f & FLAG_S == 0) { self.step = 1105; return Some(pins); }
                self.step = 1099;
                pins
            }
            1099 => {
                self.step = 1100;
                pins
            }
            1100 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1101;
                pins
            }
            1101 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1102;
                pins
            }
            1102 => {
                self.step = 1103;
                pins
            }
            1103 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1104;
                pins
            }
            1104 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1105;
                pins
            }
            1105 => {
                self.begin_fetch(pins)
            }
            241 => {
                self.step = 1106;
                pins
            }
            1106 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1107;
                pins
            }
            1107 => {
                self.regs.f = get_data(pins);
                self.step = 1108;
                pins
            }
            1108 => {
                self.step = 1109;
                pins
            }
            1109 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1110;
                pins
            }
            1110 => {
                self.regs.a = get_data(pins);
                self.step = 1111;
                pins
            }
            1111 => {
                self.begin_fetch(pins)
            }
            242 => {
                self.step = 1112;
                pins
            }
            1112 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1113;
                pins
            }
            1113 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1114;
                pins
            }
            1114 => {
                self.step = 1115;
                pins
            }
            1115 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1116;
                pins
            }
            1116 => {
                self.regs.set_wzh(get_data(pins));
                if self.regs.f & FLAG_S == 0 { self.regs.pc = self.regs.wz; }
                self.step = 1117;
                pins
            }
            1117 => {
                self.begin_fetch(pins)
            }
            243 => {
                self.regs.iff1 = false; self.regs.iff2 = false;
                self.begin_fetch(pins)
            }
            244 => {
                self.step = 1118;
                pins
            }
            1118 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1119;
                pins
            }
            1119 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1120;
                pins
            }
            1120 => {
                self.step = 1121;
                pins
            }
            1121 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1122;
                pins
            }
            1122 => {
                self.regs.set_wzh(get_data(pins));
                if !(self.regs.f & FLAG_S == 0) { self.step = 1130; return Some(pins); }
                self.step = 1123;
                pins
            }
            1123 => {
                self.step = 1124;
                pins
            }
            1124 => {
                self.step = 1125;
                pins
            }
            1125 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 1126;
                pins
            }
            1126 => {
                self.step = 1127;
                pins
            }
            1127 => {
                self.step = 1128;
                pins
            }
            1128 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 1129;
                pins
            }
            1129 => {
                self.step = 1130;
                pins
            }
            1130 => {
                self.begin_fetch(pins)
            }
            245 => {
                self.step = 1131;
                pins
            }
            1131 => {
                self.step = 1132;
                pins
            }
            1132 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.a, MREQ | WR);
                self.step = 1133;
                pins
            }
            1133 => {
                self.step = 1134;
                pins
            }
            1134 => {
                self.step = 1135;
                pins
            }
            1135 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.f, MREQ | WR);
                self.step = 1136;
                pins
            }
            1136 => {
                self.step = 1137;
                pins
            }
            1137 => {
                self.begin_fetch(pins)
            }
            246 => {
                self.step = 1138;
                pins
            }
            1138 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1139;
                pins
            }
            1139 => {
                self.dlatch = get_data(pins);
                self.alu_op(6, self.dlatch);
                self.step = 1140;
                pins
            }
            1140 => {
                self.begin_fetch(pins)
            }
            247 => {
                self.step = 1141;
                pins
            }
            1141 => {
                self.step = 1142;
                pins
            }
            1142 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 1143;
                pins
            }
            1143 => {
                self.step = 1144;
                pins
            }
            1144 => {
                self.step = 1145;
                pins
            }
            1145 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.wz = 48; self.regs.pc = self.regs.wz;
                self.step = 1146;
                pins
            }
            1146 => {
                self.step = 1147;
                pins
            }
            1147 => {
                self.begin_fetch(pins)
            }
            248 => {
                if !(self.regs.f & FLAG_S != 0) { self.step = 1154; return Some(pins); }
                self.step = 1148;
                pins
            }
            1148 => {
                self.step = 1149;
                pins
            }
            1149 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1150;
                pins
            }
            1150 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1151;
                pins
            }
            1151 => {
                self.step = 1152;
                pins
            }
            1152 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1153;
                pins
            }
            1153 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1154;
                pins
            }
            1154 => {
                self.begin_fetch(pins)
            }
            249 => {
                self.regs.sp = self.hlx();
                self.step = 1155;
                pins
            }
            1155 => {
                self.step = 1156;
                pins
            }
            1156 => {
                self.begin_fetch(pins)
            }
            250 => {
                self.step = 1157;
                pins
            }
            1157 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1158;
                pins
            }
            1158 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1159;
                pins
            }
            1159 => {
                self.step = 1160;
                pins
            }
            1160 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1161;
                pins
            }
            1161 => {
                self.regs.set_wzh(get_data(pins));
                if self.regs.f & FLAG_S != 0 { self.regs.pc = self.regs.wz; }
                self.step = 1162;
                pins
            }
            1162 => {
                self.begin_fetch(pins)
            }
            251 => {
                self.regs.iff1 = false; self.regs.iff2 = false;
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = true; self.regs.iff2 = true;
                pins
            }
            252 => {
                self.step = 1163;
                pins
            }
            1163 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1164;
                pins
            }
            1164 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1165;
                pins
            }
            1165 => {
                self.step = 1166;
                pins
            }
            1166 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1167;
                pins
            }
            1167 => {
                self.regs.set_wzh(get_data(pins));
                if !(self.regs.f & FLAG_S != 0) { self.step = 1175; return Some(pins); }
                self.step = 1168;
                pins
            }
            1168 => {
                self.step = 1169;
                pins
            }
            1169 => {
                self.step = 1170;
                pins
            }
            1170 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 1171;
                pins
            }
            1171 => {
                self.step = 1172;
                pins
            }
            1172 => {
                self.step = 1173;
                pins
            }
            1173 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.pc = self.regs.wz;
                self.step = 1174;
                pins
            }
            1174 => {
                self.step = 1175;
                pins
            }
            1175 => {
                self.begin_fetch(pins)
            }
            254 => {
                self.step = 1176;
                pins
            }
            1176 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1177;
                pins
            }
            1177 => {
                self.dlatch = get_data(pins);
                self.alu_op(7, self.dlatch);
                self.step = 1178;
                pins
            }
            1178 => {
                self.begin_fetch(pins)
            }
            255 => {
                self.step = 1179;
                pins
            }
            1179 => {
                self.step = 1180;
                pins
            }
            1180 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), (self.regs.pc >> 8) as u8, MREQ | WR);
                self.step = 1181;
                pins
            }
            1181 => {
                self.step = 1182;
                pins
            }
            1182 => {
                self.step = 1183;
                pins
            }
            1183 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.sp_pre_dec(), self.regs.pc as u8, MREQ | WR);
                self.regs.wz = 56; self.regs.pc = self.regs.wz;
                self.step = 1184;
                pins
            }
            1184 => {
                self.step = 1185;
                pins
            }
            1185 => {
                self.begin_fetch(pins)
            }
            256 => {
                self.begin_fetch(pins)
            }
            257 => {
                self.begin_fetch(pins)
            }
            258 => {
                self.begin_fetch(pins)
            }
            259 => {
                self.begin_fetch(pins)
            }
            260 => {
                self.begin_fetch(pins)
            }
            261 => {
                self.begin_fetch(pins)
            }
            262 => {
                self.begin_fetch(pins)
            }
            263 => {
                self.begin_fetch(pins)
            }
            264 => {
                self.begin_fetch(pins)
            }
            265 => {
                self.begin_fetch(pins)
            }
            266 => {
                self.begin_fetch(pins)
            }
            267 => {
                self.begin_fetch(pins)
            }
            268 => {
                self.begin_fetch(pins)
            }
            269 => {
                self.begin_fetch(pins)
            }
            270 => {
                self.begin_fetch(pins)
            }
            271 => {
                self.begin_fetch(pins)
            }
            272 => {
                self.begin_fetch(pins)
            }
            273 => {
                self.begin_fetch(pins)
            }
            274 => {
                self.begin_fetch(pins)
            }
            275 => {
                self.begin_fetch(pins)
            }
            276 => {
                self.begin_fetch(pins)
            }
            277 => {
                self.begin_fetch(pins)
            }
            278 => {
                self.begin_fetch(pins)
            }
            279 => {
                self.begin_fetch(pins)
            }
            280 => {
                self.begin_fetch(pins)
            }
            281 => {
                self.begin_fetch(pins)
            }
            282 => {
                self.begin_fetch(pins)
            }
            283 => {
                self.begin_fetch(pins)
            }
            284 => {
                self.begin_fetch(pins)
            }
            285 => {
                self.begin_fetch(pins)
            }
            286 => {
                self.begin_fetch(pins)
            }
            287 => {
                self.begin_fetch(pins)
            }
            288 => {
                self.begin_fetch(pins)
            }
            289 => {
                self.begin_fetch(pins)
            }
            290 => {
                self.begin_fetch(pins)
            }
            291 => {
                self.begin_fetch(pins)
            }
            292 => {
                self.begin_fetch(pins)
            }
            293 => {
                self.begin_fetch(pins)
            }
            294 => {
                self.begin_fetch(pins)
            }
            295 => {
                self.begin_fetch(pins)
            }
            296 => {
                self.begin_fetch(pins)
            }
            297 => {
                self.begin_fetch(pins)
            }
            298 => {
                self.begin_fetch(pins)
            }
            299 => {
                self.begin_fetch(pins)
            }
            300 => {
                self.begin_fetch(pins)
            }
            301 => {
                self.begin_fetch(pins)
            }
            302 => {
                self.begin_fetch(pins)
            }
            303 => {
                self.begin_fetch(pins)
            }
            304 => {
                self.begin_fetch(pins)
            }
            305 => {
                self.begin_fetch(pins)
            }
            306 => {
                self.begin_fetch(pins)
            }
            307 => {
                self.begin_fetch(pins)
            }
            308 => {
                self.begin_fetch(pins)
            }
            309 => {
                self.begin_fetch(pins)
            }
            310 => {
                self.begin_fetch(pins)
            }
            311 => {
                self.begin_fetch(pins)
            }
            312 => {
                self.begin_fetch(pins)
            }
            313 => {
                self.begin_fetch(pins)
            }
            314 => {
                self.begin_fetch(pins)
            }
            315 => {
                self.begin_fetch(pins)
            }
            316 => {
                self.begin_fetch(pins)
            }
            317 => {
                self.begin_fetch(pins)
            }
            318 => {
                self.begin_fetch(pins)
            }
            319 => {
                self.begin_fetch(pins)
            }
            320 => {
                self.step = 1186;
                pins
            }
            1186 => {
                self.step = 1187;
                pins
            }
            1187 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), IORQ | RD);
                self.step = 1188;
                pins
            }
            1188 => {
                self.dlatch = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1189;
                pins
            }
            1189 => {
                self.regs.b = self.dlatch; self.regs.f = alu::in_flags(self.dlatch, self.regs.f);
                self.begin_fetch(pins)
            }
            321 => {
                self.step = 1190;
                pins
            }
            1190 => {
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), self.regs.b, IORQ | WR);
                self.step = 1191;
                pins
            }
            1191 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1192;
                pins
            }
            1192 => {
                self.step = 1193;
                pins
            }
            1193 => {
                self.begin_fetch(pins)
            }
            322 => {
                self.regs.wz = self.regs.hl().wrapping_add(1); let r = alu::sbc16(self.regs.hl(), self.regs.bc(), self.regs.f & FLAG_C); self.regs.set_hl(r.value); self.regs.f = r.flags;
                self.step = 1194;
                pins
            }
            1194 => {
                self.step = 1195;
                pins
            }
            1195 => {
                self.step = 1196;
                pins
            }
            1196 => {
                self.step = 1197;
                pins
            }
            1197 => {
                self.step = 1198;
                pins
            }
            1198 => {
                self.step = 1199;
                pins
            }
            1199 => {
                self.step = 1200;
                pins
            }
            1200 => {
                self.begin_fetch(pins)
            }
            323 => {
                self.step = 1201;
                pins
            }
            1201 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1202;
                pins
            }
            1202 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1203;
                pins
            }
            1203 => {
                self.step = 1204;
                pins
            }
            1204 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1205;
                pins
            }
            1205 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1206;
                pins
            }
            1206 => {
                self.step = 1207;
                pins
            }
            1207 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.wz_post_inc(), self.regs.c, MREQ | WR);
                self.step = 1208;
                pins
            }
            1208 => {
                self.step = 1209;
                pins
            }
            1209 => {
                self.step = 1210;
                pins
            }
            1210 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.wz, self.regs.b, MREQ | WR);
                self.step = 1211;
                pins
            }
            1211 => {
                self.step = 1212;
                pins
            }
            1212 => {
                self.begin_fetch(pins)
            }
            324 => {
                let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            325 => {
                self.step = 1213;
                pins
            }
            1213 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1214;
                pins
            }
            1214 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1215;
                pins
            }
            1215 => {
                self.step = 1216;
                pins
            }
            1216 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1217;
                pins
            }
            1217 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1218;
                pins
            }
            1218 => {
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = self.regs.iff2;
                pins
            }
            326 => {
                self.regs.im = 0;
                self.begin_fetch(pins)
            }
            327 => {
                self.regs.i = self.regs.a;
                self.step = 1219;
                pins
            }
            1219 => {
                self.begin_fetch(pins)
            }
            328 => {
                self.step = 1220;
                pins
            }
            1220 => {
                self.step = 1221;
                pins
            }
            1221 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), IORQ | RD);
                self.step = 1222;
                pins
            }
            1222 => {
                self.dlatch = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1223;
                pins
            }
            1223 => {
                self.regs.c = self.dlatch; self.regs.f = alu::in_flags(self.dlatch, self.regs.f);
                self.begin_fetch(pins)
            }
            329 => {
                self.step = 1224;
                pins
            }
            1224 => {
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), self.regs.c, IORQ | WR);
                self.step = 1225;
                pins
            }
            1225 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1226;
                pins
            }
            1226 => {
                self.step = 1227;
                pins
            }
            1227 => {
                self.begin_fetch(pins)
            }
            330 => {
                self.regs.wz = self.regs.hl().wrapping_add(1); let r = alu::adc16(self.regs.hl(), self.regs.bc(), self.regs.f & FLAG_C); self.regs.set_hl(r.value); self.regs.f = r.flags;
                self.step = 1228;
                pins
            }
            1228 => {
                self.step = 1229;
                pins
            }
            1229 => {
                self.step = 1230;
                pins
            }
            1230 => {
                self.step = 1231;
                pins
            }
            1231 => {
                self.step = 1232;
                pins
            }
            1232 => {
                self.step = 1233;
                pins
            }
            1233 => {
                self.step = 1234;
                pins
            }
            1234 => {
                self.begin_fetch(pins)
            }
            331 => {
                self.step = 1235;
                pins
            }
            1235 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1236;
                pins
            }
            1236 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1237;
                pins
            }
            1237 => {
                self.step = 1238;
                pins
            }
            1238 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1239;
                pins
            }
            1239 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1240;
                pins
            }
            1240 => {
                self.step = 1241;
                pins
            }
            1241 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.wz_post_inc(), MREQ | RD);
                self.step = 1242;
                pins
            }
            1242 => {
                self.regs.c = get_data(pins);
                self.step = 1243;
                pins
            }
            1243 => {
                self.step = 1244;
                pins
            }
            1244 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.wz, MREQ | RD);
                self.step = 1245;
                pins
            }
            1245 => {
                self.regs.b = get_data(pins);
                self.step = 1246;
                pins
            }
            1246 => {
                self.begin_fetch(pins)
            }
            332 => {
                let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            333 => {
                self.step = 1247;
                pins
            }
            1247 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1248;
                pins
            }
            1248 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1249;
                pins
            }
            1249 => {
                self.step = 1250;
                pins
            }
            1250 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1251;
                pins
            }
            1251 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1252;
                pins
            }
            1252 => {
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = self.regs.iff2;
                pins
            }
            334 => {
                self.regs.im = 0;
                self.begin_fetch(pins)
            }
            335 => {
                self.regs.r = self.regs.a;
                self.step = 1253;
                pins
            }
            1253 => {
                self.begin_fetch(pins)
            }
            336 => {
                self.step = 1254;
                pins
            }
            1254 => {
                self.step = 1255;
                pins
            }
            1255 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), IORQ | RD);
                self.step = 1256;
                pins
            }
            1256 => {
                self.dlatch = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1257;
                pins
            }
            1257 => {
                self.regs.d = self.dlatch; self.regs.f = alu::in_flags(self.dlatch, self.regs.f);
                self.begin_fetch(pins)
            }
            337 => {
                self.step = 1258;
                pins
            }
            1258 => {
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), self.regs.d, IORQ | WR);
                self.step = 1259;
                pins
            }
            1259 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1260;
                pins
            }
            1260 => {
                self.step = 1261;
                pins
            }
            1261 => {
                self.begin_fetch(pins)
            }
            338 => {
                self.regs.wz = self.regs.hl().wrapping_add(1); let r = alu::sbc16(self.regs.hl(), self.regs.de(), self.regs.f & FLAG_C); self.regs.set_hl(r.value); self.regs.f = r.flags;
                self.step = 1262;
                pins
            }
            1262 => {
                self.step = 1263;
                pins
            }
            1263 => {
                self.step = 1264;
                pins
            }
            1264 => {
                self.step = 1265;
                pins
            }
            1265 => {
                self.step = 1266;
                pins
            }
            1266 => {
                self.step = 1267;
                pins
            }
            1267 => {
                self.step = 1268;
                pins
            }
            1268 => {
                self.begin_fetch(pins)
            }
            339 => {
                self.step = 1269;
                pins
            }
            1269 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1270;
                pins
            }
            1270 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1271;
                pins
            }
            1271 => {
                self.step = 1272;
                pins
            }
            1272 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1273;
                pins
            }
            1273 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1274;
                pins
            }
            1274 => {
                self.step = 1275;
                pins
            }
            1275 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.wz_post_inc(), self.regs.e, MREQ | WR);
                self.step = 1276;
                pins
            }
            1276 => {
                self.step = 1277;
                pins
            }
            1277 => {
                self.step = 1278;
                pins
            }
            1278 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.wz, self.regs.d, MREQ | WR);
                self.step = 1279;
                pins
            }
            1279 => {
                self.step = 1280;
                pins
            }
            1280 => {
                self.begin_fetch(pins)
            }
            340 => {
                let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            341 => {
                self.step = 1281;
                pins
            }
            1281 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1282;
                pins
            }
            1282 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1283;
                pins
            }
            1283 => {
                self.step = 1284;
                pins
            }
            1284 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1285;
                pins
            }
            1285 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1286;
                pins
            }
            1286 => {
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = self.regs.iff2;
                pins
            }
            342 => {
                self.regs.im = 1;
                self.begin_fetch(pins)
            }
            343 => {
                self.regs.a = self.regs.i; self.regs.f = alu::sziff2_flags(self.regs.i, self.regs.f, self.regs.iff2);
                self.step = 1287;
                pins
            }
            1287 => {
                self.begin_fetch(pins)
            }
            344 => {
                self.step = 1288;
                pins
            }
            1288 => {
                self.step = 1289;
                pins
            }
            1289 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), IORQ | RD);
                self.step = 1290;
                pins
            }
            1290 => {
                self.dlatch = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1291;
                pins
            }
            1291 => {
                self.regs.e = self.dlatch; self.regs.f = alu::in_flags(self.dlatch, self.regs.f);
                self.begin_fetch(pins)
            }
            345 => {
                self.step = 1292;
                pins
            }
            1292 => {
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), self.regs.e, IORQ | WR);
                self.step = 1293;
                pins
            }
            1293 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1294;
                pins
            }
            1294 => {
                self.step = 1295;
                pins
            }
            1295 => {
                self.begin_fetch(pins)
            }
            346 => {
                self.regs.wz = self.regs.hl().wrapping_add(1); let r = alu::adc16(self.regs.hl(), self.regs.de(), self.regs.f & FLAG_C); self.regs.set_hl(r.value); self.regs.f = r.flags;
                self.step = 1296;
                pins
            }
            1296 => {
                self.step = 1297;
                pins
            }
            1297 => {
                self.step = 1298;
                pins
            }
            1298 => {
                self.step = 1299;
                pins
            }
            1299 => {
                self.step = 1300;
                pins
            }
            1300 => {
                self.step = 1301;
                pins
            }
            1301 => {
                self.step = 1302;
                pins
            }
            1302 => {
                self.begin_fetch(pins)
            }
            347 => {
                self.step = 1303;
                pins
            }
            1303 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1304;
                pins
            }
            1304 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1305;
                pins
            }
            1305 => {
                self.step = 1306;
                pins
            }
            1306 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1307;
                pins
            }
            1307 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1308;
                pins
            }
            1308 => {
                self.step = 1309;
                pins
            }
            1309 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.wz_post_inc(), MREQ | RD);
                self.step = 1310;
                pins
            }
            1310 => {
                self.regs.e = get_data(pins);
                self.step = 1311;
                pins
            }
            1311 => {
                self.step = 1312;
                pins
            }
            1312 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.wz, MREQ | RD);
                self.step = 1313;
                pins
            }
            1313 => {
                self.regs.d = get_data(pins);
                self.step = 1314;
                pins
            }
            1314 => {
                self.begin_fetch(pins)
            }
            348 => {
                let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            349 => {
                self.step = 1315;
                pins
            }
            1315 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1316;
                pins
            }
            1316 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1317;
                pins
            }
            1317 => {
                self.step = 1318;
                pins
            }
            1318 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1319;
                pins
            }
            1319 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1320;
                pins
            }
            1320 => {
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = self.regs.iff2;
                pins
            }
            350 => {
                self.regs.im = 2;
                self.begin_fetch(pins)
            }
            351 => {
                self.regs.a = self.regs.r; self.regs.f = alu::sziff2_flags(self.regs.r, self.regs.f, self.regs.iff2);
                self.step = 1321;
                pins
            }
            1321 => {
                self.begin_fetch(pins)
            }
            352 => {
                self.step = 1322;
                pins
            }
            1322 => {
                self.step = 1323;
                pins
            }
            1323 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), IORQ | RD);
                self.step = 1324;
                pins
            }
            1324 => {
                self.dlatch = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1325;
                pins
            }
            1325 => {
                self.regs.h = self.dlatch; self.regs.f = alu::in_flags(self.dlatch, self.regs.f);
                self.begin_fetch(pins)
            }
            353 => {
                self.step = 1326;
                pins
            }
            1326 => {
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), self.regs.h, IORQ | WR);
                self.step = 1327;
                pins
            }
            1327 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1328;
                pins
            }
            1328 => {
                self.step = 1329;
                pins
            }
            1329 => {
                self.begin_fetch(pins)
            }
            354 => {
                self.regs.wz = self.regs.hl().wrapping_add(1); let r = alu::sbc16(self.regs.hl(), self.regs.hl(), self.regs.f & FLAG_C); self.regs.set_hl(r.value); self.regs.f = r.flags;
                self.step = 1330;
                pins
            }
            1330 => {
                self.step = 1331;
                pins
            }
            1331 => {
                self.step = 1332;
                pins
            }
            1332 => {
                self.step = 1333;
                pins
            }
            1333 => {
                self.step = 1334;
                pins
            }
            1334 => {
                self.step = 1335;
                pins
            }
            1335 => {
                self.step = 1336;
                pins
            }
            1336 => {
                self.begin_fetch(pins)
            }
            355 => {
                self.step = 1337;
                pins
            }
            1337 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1338;
                pins
            }
            1338 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1339;
                pins
            }
            1339 => {
                self.step = 1340;
                pins
            }
            1340 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1341;
                pins
            }
            1341 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1342;
                pins
            }
            1342 => {
                self.step = 1343;
                pins
            }
            1343 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.wz_post_inc(), self.regs.l, MREQ | WR);
                self.step = 1344;
                pins
            }
            1344 => {
                self.step = 1345;
                pins
            }
            1345 => {
                self.step = 1346;
                pins
            }
            1346 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.wz, self.regs.h, MREQ | WR);
                self.step = 1347;
                pins
            }
            1347 => {
                self.step = 1348;
                pins
            }
            1348 => {
                self.begin_fetch(pins)
            }
            356 => {
                let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            357 => {
                self.step = 1349;
                pins
            }
            1349 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1350;
                pins
            }
            1350 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1351;
                pins
            }
            1351 => {
                self.step = 1352;
                pins
            }
            1352 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1353;
                pins
            }
            1353 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1354;
                pins
            }
            1354 => {
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = self.regs.iff2;
                pins
            }
            358 => {
                self.regs.im = 0;
                self.begin_fetch(pins)
            }
            359 => {
                self.step = 1355;
                pins
            }
            1355 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.hl(), MREQ | RD);
                self.step = 1356;
                pins
            }
            1356 => {
                self.dlatch = get_data(pins);
                self.step = 1357;
                pins
            }
            1357 => {
                let (new_a, new_mem, flags) = alu::rrd(self.regs.a, self.dlatch, self.regs.f); self.regs.a = new_a; self.dlatch = new_mem; self.regs.f = flags;
                self.step = 1358;
                pins
            }
            1358 => {
                self.step = 1359;
                pins
            }
            1359 => {
                self.step = 1360;
                pins
            }
            1360 => {
                self.step = 1361;
                pins
            }
            1361 => {
                self.step = 1362;
                pins
            }
            1362 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.hl(), self.dlatch, MREQ | WR);
                self.regs.wz = self.regs.hl().wrapping_add(1);
                self.step = 1363;
                pins
            }
            1363 => {
                self.step = 1364;
                pins
            }
            1364 => {
                self.begin_fetch(pins)
            }
            360 => {
                self.step = 1365;
                pins
            }
            1365 => {
                self.step = 1366;
                pins
            }
            1366 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), IORQ | RD);
                self.step = 1367;
                pins
            }
            1367 => {
                self.dlatch = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1368;
                pins
            }
            1368 => {
                self.regs.l = self.dlatch; self.regs.f = alu::in_flags(self.dlatch, self.regs.f);
                self.begin_fetch(pins)
            }
            361 => {
                self.step = 1369;
                pins
            }
            1369 => {
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), self.regs.l, IORQ | WR);
                self.step = 1370;
                pins
            }
            1370 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1371;
                pins
            }
            1371 => {
                self.step = 1372;
                pins
            }
            1372 => {
                self.begin_fetch(pins)
            }
            362 => {
                self.regs.wz = self.regs.hl().wrapping_add(1); let r = alu::adc16(self.regs.hl(), self.regs.hl(), self.regs.f & FLAG_C); self.regs.set_hl(r.value); self.regs.f = r.flags;
                self.step = 1373;
                pins
            }
            1373 => {
                self.step = 1374;
                pins
            }
            1374 => {
                self.step = 1375;
                pins
            }
            1375 => {
                self.step = 1376;
                pins
            }
            1376 => {
                self.step = 1377;
                pins
            }
            1377 => {
                self.step = 1378;
                pins
            }
            1378 => {
                self.step = 1379;
                pins
            }
            1379 => {
                self.begin_fetch(pins)
            }
            363 => {
                self.step = 1380;
                pins
            }
            1380 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1381;
                pins
            }
            1381 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1382;
                pins
            }
            1382 => {
                self.step = 1383;
                pins
            }
            1383 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1384;
                pins
            }
            1384 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1385;
                pins
            }
            1385 => {
                self.step = 1386;
                pins
            }
            1386 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.wz_post_inc(), MREQ | RD);
                self.step = 1387;
                pins
            }
            1387 => {
                self.regs.l = get_data(pins);
                self.step = 1388;
                pins
            }
            1388 => {
                self.step = 1389;
                pins
            }
            1389 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.wz, MREQ | RD);
                self.step = 1390;
                pins
            }
            1390 => {
                self.regs.h = get_data(pins);
                self.step = 1391;
                pins
            }
            1391 => {
                self.begin_fetch(pins)
            }
            364 => {
                let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            365 => {
                self.step = 1392;
                pins
            }
            1392 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1393;
                pins
            }
            1393 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1394;
                pins
            }
            1394 => {
                self.step = 1395;
                pins
            }
            1395 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1396;
                pins
            }
            1396 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1397;
                pins
            }
            1397 => {
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = self.regs.iff2;
                pins
            }
            366 => {
                self.regs.im = 0;
                self.begin_fetch(pins)
            }
            367 => {
                self.step = 1398;
                pins
            }
            1398 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.hl(), MREQ | RD);
                self.step = 1399;
                pins
            }
            1399 => {
                self.dlatch = get_data(pins);
                self.step = 1400;
                pins
            }
            1400 => {
                let (new_a, new_mem, flags) = alu::rld(self.regs.a, self.dlatch, self.regs.f); self.regs.a = new_a; self.dlatch = new_mem; self.regs.f = flags;
                self.step = 1401;
                pins
            }
            1401 => {
                self.step = 1402;
                pins
            }
            1402 => {
                self.step = 1403;
                pins
            }
            1403 => {
                self.step = 1404;
                pins
            }
            1404 => {
                self.step = 1405;
                pins
            }
            1405 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.hl(), self.dlatch, MREQ | WR);
                self.regs.wz = self.regs.hl().wrapping_add(1);
                self.step = 1406;
                pins
            }
            1406 => {
                self.step = 1407;
                pins
            }
            1407 => {
                self.begin_fetch(pins)
            }
            368 => {
                self.step = 1408;
                pins
            }
            1408 => {
                self.step = 1409;
                pins
            }
            1409 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), IORQ | RD);
                self.step = 1410;
                pins
            }
            1410 => {
                self.dlatch = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1411;
                pins
            }
            1411 => {
                self.regs.f = alu::in_flags(self.dlatch, self.regs.f);
                self.begin_fetch(pins)
            }
            369 => {
                self.step = 1412;
                pins
            }
            1412 => {
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), 0, IORQ | WR);
                self.step = 1413;
                pins
            }
            1413 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1414;
                pins
            }
            1414 => {
                self.step = 1415;
                pins
            }
            1415 => {
                self.begin_fetch(pins)
            }
            370 => {
                self.regs.wz = self.regs.hl().wrapping_add(1); let r = alu::sbc16(self.regs.hl(), self.regs.sp, self.regs.f & FLAG_C); self.regs.set_hl(r.value); self.regs.f = r.flags;
                self.step = 1416;
                pins
            }
            1416 => {
                self.step = 1417;
                pins
            }
            1417 => {
                self.step = 1418;
                pins
            }
            1418 => {
                self.step = 1419;
                pins
            }
            1419 => {
                self.step = 1420;
                pins
            }
            1420 => {
                self.step = 1421;
                pins
            }
            1421 => {
                self.step = 1422;
                pins
            }
            1422 => {
                self.begin_fetch(pins)
            }
            371 => {
                self.step = 1423;
                pins
            }
            1423 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1424;
                pins
            }
            1424 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1425;
                pins
            }
            1425 => {
                self.step = 1426;
                pins
            }
            1426 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1427;
                pins
            }
            1427 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1428;
                pins
            }
            1428 => {
                self.step = 1429;
                pins
            }
            1429 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.wz_post_inc(), self.regs.spl(), MREQ | WR);
                self.step = 1430;
                pins
            }
            1430 => {
                self.step = 1431;
                pins
            }
            1431 => {
                self.step = 1432;
                pins
            }
            1432 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.wz, self.regs.sph(), MREQ | WR);
                self.step = 1433;
                pins
            }
            1433 => {
                self.step = 1434;
                pins
            }
            1434 => {
                self.begin_fetch(pins)
            }
            372 => {
                let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            373 => {
                self.step = 1435;
                pins
            }
            1435 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1436;
                pins
            }
            1436 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1437;
                pins
            }
            1437 => {
                self.step = 1438;
                pins
            }
            1438 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1439;
                pins
            }
            1439 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1440;
                pins
            }
            1440 => {
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = self.regs.iff2;
                pins
            }
            374 => {
                self.regs.im = 1;
                self.begin_fetch(pins)
            }
            375 => {
                self.begin_fetch(pins)
            }
            376 => {
                self.step = 1441;
                pins
            }
            1441 => {
                self.step = 1442;
                pins
            }
            1442 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.bc(), IORQ | RD);
                self.step = 1443;
                pins
            }
            1443 => {
                self.dlatch = get_data(pins);
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1444;
                pins
            }
            1444 => {
                self.regs.a = self.dlatch; self.regs.f = alu::in_flags(self.dlatch, self.regs.f);
                self.begin_fetch(pins)
            }
            377 => {
                self.step = 1445;
                pins
            }
            1445 => {
                let pins = set_addr_data_ctrl(pins, self.regs.bc(), self.regs.a, IORQ | WR);
                self.step = 1446;
                pins
            }
            1446 => {
                if pins & WAIT != 0 { return Some(pins); }
                self.regs.wz = self.regs.bc().wrapping_add(1);
                self.step = 1447;
                pins
            }
            1447 => {
                self.step = 1448;
                pins
            }
            1448 => {
                self.begin_fetch(pins)
            }
            378 => {
                self.regs.wz = self.regs.hl().wrapping_add(1); let r = alu::adc16(self.regs.hl(), self.regs.sp, self.regs.f & FLAG_C); self.regs.set_hl(r.value); self.regs.f = r.flags;
                self.step = 1449;
                pins
            }
            1449 => {
                self.step = 1450;
                pins
            }
            1450 => {
                self.step = 1451;
                pins
            }
            1451 => {
                self.step = 1452;
                pins
            }
            1452 => {
                self.step = 1453;
                pins
            }
            1453 => {
                self.step = 1454;
                pins
            }
            1454 => {
                self.step = 1455;
                pins
            }
            1455 => {
                self.begin_fetch(pins)
            }
            379 => {
                self.step = 1456;
                pins
            }
            1456 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1457;
                pins
            }
            1457 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1458;
                pins
            }
            1458 => {
                self.step = 1459;
                pins
            }
            1459 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.pc_post_inc(), MREQ | RD);
                self.step = 1460;
                pins
            }
            1460 => {
                self.regs.set_wzh(get_data(pins));
                self.step = 1461;
                pins
            }
            1461 => {
                self.step = 1462;
                pins
            }
            1462 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.wz_post_inc(), MREQ | RD);
                self.step = 1463;
                pins
            }
            1463 => {
                self.regs.set_spl(get_data(pins));
                self.step = 1464;
                pins
            }
            1464 => {
                self.step = 1465;
                pins
            }
            1465 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.wz, MREQ | RD);
                self.step = 1466;
                pins
            }
            1466 => {
                self.regs.set_sph(get_data(pins));
                self.step = 1467;
                pins
            }
            1467 => {
                self.begin_fetch(pins)
            }
            380 => {
                let r = alu::sub8(0, self.regs.a); self.regs.a = r.value; self.regs.f = r.flags;
                self.begin_fetch(pins)
            }
            381 => {
                self.step = 1468;
                pins
            }
            1468 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1469;
                pins
            }
            1469 => {
                self.regs.set_wzl(get_data(pins));
                self.step = 1470;
                pins
            }
            1470 => {
                self.step = 1471;
                pins
            }
            1471 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.sp_post_inc(), MREQ | RD);
                self.step = 1472;
                pins
            }
            1472 => {
                self.regs.set_wzh(get_data(pins));
                self.regs.pc = self.regs.wz;
                self.step = 1473;
                pins
            }
            1473 => {
                let pins = self.begin_fetch(pins);
                self.regs.iff1 = self.regs.iff2;
                pins
            }
            382 => {
                self.regs.im = 2;
                self.begin_fetch(pins)
            }
            383 => {
                self.begin_fetch(pins)
            }
            384 => {
                self.begin_fetch(pins)
            }
            385 => {
                self.begin_fetch(pins)
            }
            386 => {
                self.begin_fetch(pins)
            }
            387 => {
                self.begin_fetch(pins)
            }
            388 => {
                self.begin_fetch(pins)
            }
            389 => {
                self.begin_fetch(pins)
            }
            390 => {
                self.begin_fetch(pins)
            }
            391 => {
                self.begin_fetch(pins)
            }
            392 => {
                self.begin_fetch(pins)
            }
            393 => {
                self.begin_fetch(pins)
            }
            394 => {
                self.begin_fetch(pins)
            }
            395 => {
                self.begin_fetch(pins)
            }
            396 => {
                self.begin_fetch(pins)
            }
            397 => {
                self.begin_fetch(pins)
            }
            398 => {
                self.begin_fetch(pins)
            }
            399 => {
                self.begin_fetch(pins)
            }
            400 => {
                self.begin_fetch(pins)
            }
            401 => {
                self.begin_fetch(pins)
            }
            402 => {
                self.begin_fetch(pins)
            }
            403 => {
                self.begin_fetch(pins)
            }
            404 => {
                self.begin_fetch(pins)
            }
            405 => {
                self.begin_fetch(pins)
            }
            406 => {
                self.begin_fetch(pins)
            }
            407 => {
                self.begin_fetch(pins)
            }
            408 => {
                self.begin_fetch(pins)
            }
            409 => {
                self.begin_fetch(pins)
            }
            410 => {
                self.begin_fetch(pins)
            }
            411 => {
                self.begin_fetch(pins)
            }
            412 => {
                self.begin_fetch(pins)
            }
            413 => {
                self.begin_fetch(pins)
            }
            414 => {
                self.begin_fetch(pins)
            }
            415 => {
                self.begin_fetch(pins)
            }
            416 => {
                self.step = 1474;
                pins
            }
            1474 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.hl_post_inc(), MREQ | RD);
                self.step = 1475;
                pins
            }
            1475 => {
                self.dlatch = get_data(pins);
                self.step = 1476;
                pins
            }
            1476 => {
                self.step = 1477;
                pins
            }
            1477 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.de_post_inc(), self.dlatch, MREQ | WR);
                self.step = 1478;
                pins
            }
            1478 => {
                self.step = 1479;
                pins
            }
            1479 => {
                let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); self.regs.f = alu::ldi_ldd_flags(self.regs.a, self.dlatch, bc_after, self.regs.f);
                self.step = 1480;
                pins
            }
            1480 => {
                self.step = 1481;
                pins
            }
            1481 => {
                self.begin_fetch(pins)
            }
            417 => {
                self.step = 1482;
                pins
            }
            1482 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.hl_post_inc(), MREQ | RD);
                self.step = 1483;
                pins
            }
            1483 => {
                self.dlatch = get_data(pins);
                self.step = 1484;
                pins
            }
            1484 => {
                self.regs.wz = self.regs.wz.wrapping_add(1); let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); let (flags, _repeat) = alu::cpi_cpd(self.regs.a, self.dlatch, bc_after, self.regs.f); self.regs.f = flags;
                self.step = 1485;
                pins
            }
            1485 => {
                self.step = 1486;
                pins
            }
            1486 => {
                self.step = 1487;
                pins
            }
            1487 => {
                self.step = 1488;
                pins
            }
            1488 => {
                self.step = 1489;
                pins
            }
            1489 => {
                self.begin_fetch(pins)
            }
            420 => {
                self.begin_fetch(pins)
            }
            421 => {
                self.begin_fetch(pins)
            }
            422 => {
                self.begin_fetch(pins)
            }
            423 => {
                self.begin_fetch(pins)
            }
            424 => {
                self.step = 1490;
                pins
            }
            1490 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.hl_post_dec(), MREQ | RD);
                self.step = 1491;
                pins
            }
            1491 => {
                self.dlatch = get_data(pins);
                self.step = 1492;
                pins
            }
            1492 => {
                self.step = 1493;
                pins
            }
            1493 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.de_post_dec(), self.dlatch, MREQ | WR);
                self.step = 1494;
                pins
            }
            1494 => {
                self.step = 1495;
                pins
            }
            1495 => {
                let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); self.regs.f = alu::ldi_ldd_flags(self.regs.a, self.dlatch, bc_after, self.regs.f);
                self.step = 1496;
                pins
            }
            1496 => {
                self.step = 1497;
                pins
            }
            1497 => {
                self.begin_fetch(pins)
            }
            425 => {
                self.step = 1498;
                pins
            }
            1498 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.hl_post_dec(), MREQ | RD);
                self.step = 1499;
                pins
            }
            1499 => {
                self.dlatch = get_data(pins);
                self.step = 1500;
                pins
            }
            1500 => {
                self.regs.wz = self.regs.wz.wrapping_sub(1); let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); let (flags, _repeat) = alu::cpi_cpd(self.regs.a, self.dlatch, bc_after, self.regs.f); self.regs.f = flags;
                self.step = 1501;
                pins
            }
            1501 => {
                self.step = 1502;
                pins
            }
            1502 => {
                self.step = 1503;
                pins
            }
            1503 => {
                self.step = 1504;
                pins
            }
            1504 => {
                self.step = 1505;
                pins
            }
            1505 => {
                self.begin_fetch(pins)
            }
            428 => {
                self.begin_fetch(pins)
            }
            429 => {
                self.begin_fetch(pins)
            }
            430 => {
                self.begin_fetch(pins)
            }
            431 => {
                self.begin_fetch(pins)
            }
            432 => {
                self.step = 1506;
                pins
            }
            1506 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.hl_post_inc(), MREQ | RD);
                self.step = 1507;
                pins
            }
            1507 => {
                self.dlatch = get_data(pins);
                self.step = 1508;
                pins
            }
            1508 => {
                self.step = 1509;
                pins
            }
            1509 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.de_post_inc(), self.dlatch, MREQ | WR);
                self.step = 1510;
                pins
            }
            1510 => {
                self.step = 1511;
                pins
            }
            1511 => {
                let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); self.regs.f = alu::ldi_ldd_flags(self.regs.a, self.dlatch, bc_after, self.regs.f); if bc_after == 0 { self.step = 1517; return Some(pins); }
                self.step = 1512;
                pins
            }
            1512 => {
                self.step = 1513;
                pins
            }
            1513 => {
                self.regs.pc = self.regs.pc.wrapping_sub(1); self.regs.wz = self.regs.pc; self.regs.pc = self.regs.pc.wrapping_sub(1);
                self.step = 1514;
                pins
            }
            1514 => {
                self.step = 1515;
                pins
            }
            1515 => {
                self.step = 1516;
                pins
            }
            1516 => {
                self.step = 1517;
                pins
            }
            1517 => {
                self.step = 1518;
                pins
            }
            1518 => {
                self.begin_fetch(pins)
            }
            433 => {
                self.step = 1519;
                pins
            }
            1519 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.hl_post_inc(), MREQ | RD);
                self.step = 1520;
                pins
            }
            1520 => {
                self.dlatch = get_data(pins);
                self.step = 1521;
                pins
            }
            1521 => {
                self.regs.wz = self.regs.wz.wrapping_add(1); let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); let (flags, repeat) = alu::cpi_cpd(self.regs.a, self.dlatch, bc_after, self.regs.f); self.regs.f = flags; if !repeat { self.step = 1527; return Some(pins); }
                self.step = 1522;
                pins
            }
            1522 => {
                self.step = 1523;
                pins
            }
            1523 => {
                self.step = 1524;
                pins
            }
            1524 => {
                self.step = 1525;
                pins
            }
            1525 => {
                self.step = 1526;
                pins
            }
            1526 => {
                self.regs.pc = self.regs.pc.wrapping_sub(1); self.regs.wz = self.regs.pc; self.regs.pc = self.regs.pc.wrapping_sub(1);
                self.step = 1527;
                pins
            }
            1527 => {
                self.step = 1528;
                pins
            }
            1528 => {
                self.step = 1529;
                pins
            }
            1529 => {
                self.step = 1530;
                pins
            }
            1530 => {
                self.step = 1531;
                pins
            }
            1531 => {
                self.begin_fetch(pins)
            }
            436 => {
                self.begin_fetch(pins)
            }
            437 => {
                self.begin_fetch(pins)
            }
            438 => {
                self.begin_fetch(pins)
            }
            439 => {
                self.begin_fetch(pins)
            }
            440 => {
                self.step = 1532;
                pins
            }
            1532 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.hl_post_dec(), MREQ | RD);
                self.step = 1533;
                pins
            }
            1533 => {
                self.dlatch = get_data(pins);
                self.step = 1534;
                pins
            }
            1534 => {
                self.step = 1535;
                pins
            }
            1535 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.de_post_dec(), self.dlatch, MREQ | WR);
                self.step = 1536;
                pins
            }
            1536 => {
                self.step = 1537;
                pins
            }
            1537 => {
                let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); self.regs.f = alu::ldi_ldd_flags(self.regs.a, self.dlatch, bc_after, self.regs.f); if bc_after == 0 { self.step = 1543; return Some(pins); }
                self.step = 1538;
                pins
            }
            1538 => {
                self.step = 1539;
                pins
            }
            1539 => {
                self.regs.pc = self.regs.pc.wrapping_sub(1); self.regs.wz = self.regs.pc; self.regs.pc = self.regs.pc.wrapping_sub(1);
                self.step = 1540;
                pins
            }
            1540 => {
                self.step = 1541;
                pins
            }
            1541 => {
                self.step = 1542;
                pins
            }
            1542 => {
                self.step = 1543;
                pins
            }
            1543 => {
                self.step = 1544;
                pins
            }
            1544 => {
                self.begin_fetch(pins)
            }
            441 => {
                self.step = 1545;
                pins
            }
            1545 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.hl_post_dec(), MREQ | RD);
                self.step = 1546;
                pins
            }
            1546 => {
                self.dlatch = get_data(pins);
                self.step = 1547;
                pins
            }
            1547 => {
                self.regs.wz = self.regs.wz.wrapping_sub(1); let bc_after = self.regs.bc().wrapping_sub(1); self.regs.set_bc(bc_after); let (flags, repeat) = alu::cpi_cpd(self.regs.a, self.dlatch, bc_after, self.regs.f); self.regs.f = flags; if !repeat { self.step = 1553; return Some(pins); }
                self.step = 1548;
                pins
            }
            1548 => {
                self.step = 1549;
                pins
            }
            1549 => {
                self.step = 1550;
                pins
            }
            1550 => {
                self.step = 1551;
                pins
            }
            1551 => {
                self.step = 1552;
                pins
            }
            1552 => {
                self.regs.pc = self.regs.pc.wrapping_sub(1); self.regs.wz = self.regs.pc; self.regs.pc = self.regs.pc.wrapping_sub(1);
                self.step = 1553;
                pins
            }
            1553 => {
                self.step = 1554;
                pins
            }
            1554 => {
                self.step = 1555;
                pins
            }
            1555 => {
                self.step = 1556;
                pins
            }
            1556 => {
                self.step = 1557;
                pins
            }
            1557 => {
                self.begin_fetch(pins)
            }
            444 => {
                self.begin_fetch(pins)
            }
            445 => {
                self.begin_fetch(pins)
            }
            446 => {
                self.begin_fetch(pins)
            }
            447 => {
                self.begin_fetch(pins)
            }
            448 => {
                self.begin_fetch(pins)
            }
            449 => {
                self.begin_fetch(pins)
            }
            450 => {
                self.begin_fetch(pins)
            }
            451 => {
                self.begin_fetch(pins)
            }
            452 => {
                self.begin_fetch(pins)
            }
            453 => {
                self.begin_fetch(pins)
            }
            454 => {
                self.begin_fetch(pins)
            }
            455 => {
                self.begin_fetch(pins)
            }
            456 => {
                self.begin_fetch(pins)
            }
            457 => {
                self.begin_fetch(pins)
            }
            458 => {
                self.begin_fetch(pins)
            }
            459 => {
                self.begin_fetch(pins)
            }
            460 => {
                self.begin_fetch(pins)
            }
            461 => {
                self.begin_fetch(pins)
            }
            462 => {
                self.begin_fetch(pins)
            }
            463 => {
                self.begin_fetch(pins)
            }
            464 => {
                self.begin_fetch(pins)
            }
            465 => {
                self.begin_fetch(pins)
            }
            466 => {
                self.begin_fetch(pins)
            }
            467 => {
                self.begin_fetch(pins)
            }
            468 => {
                self.begin_fetch(pins)
            }
            469 => {
                self.begin_fetch(pins)
            }
            470 => {
                self.begin_fetch(pins)
            }
            471 => {
                self.begin_fetch(pins)
            }
            472 => {
                self.begin_fetch(pins)
            }
            473 => {
                self.begin_fetch(pins)
            }
            474 => {
                self.begin_fetch(pins)
            }
            475 => {
                self.begin_fetch(pins)
            }
            476 => {
                self.begin_fetch(pins)
            }
            477 => {
                self.begin_fetch(pins)
            }
            478 => {
                self.begin_fetch(pins)
            }
            479 => {
                self.begin_fetch(pins)
            }
            480 => {
                self.begin_fetch(pins)
            }
            481 => {
                self.begin_fetch(pins)
            }
            482 => {
                self.begin_fetch(pins)
            }
            483 => {
                self.begin_fetch(pins)
            }
            484 => {
                self.begin_fetch(pins)
            }
            485 => {
                self.begin_fetch(pins)
            }
            486 => {
                self.begin_fetch(pins)
            }
            487 => {
                self.begin_fetch(pins)
            }
            488 => {
                self.begin_fetch(pins)
            }
            489 => {
                self.begin_fetch(pins)
            }
            490 => {
                self.begin_fetch(pins)
            }
            491 => {
                self.begin_fetch(pins)
            }
            492 => {
                self.begin_fetch(pins)
            }
            493 => {
                self.begin_fetch(pins)
            }
            494 => {
                self.begin_fetch(pins)
            }
            495 => {
                self.begin_fetch(pins)
            }
            496 => {
                self.begin_fetch(pins)
            }
            497 => {
                self.begin_fetch(pins)
            }
            498 => {
                self.begin_fetch(pins)
            }
            499 => {
                self.begin_fetch(pins)
            }
            500 => {
                self.begin_fetch(pins)
            }
            501 => {
                self.begin_fetch(pins)
            }
            502 => {
                self.begin_fetch(pins)
            }
            503 => {
                self.begin_fetch(pins)
            }
            504 => {
                self.begin_fetch(pins)
            }
            505 => {
                self.begin_fetch(pins)
            }
            506 => {
                self.begin_fetch(pins)
            }
            507 => {
                self.begin_fetch(pins)
            }
            508 => {
                self.begin_fetch(pins)
            }
            509 => {
                self.begin_fetch(pins)
            }
            510 => {
                self.begin_fetch(pins)
            }
            511 => {
                self.begin_fetch(pins)
            }
            1558 => {
                let z = self.opcode & 7; let val = self.get_reg8_plain(z); if let Some(new_val) = self.cb_action(val, false) { self.set_reg8_plain(z, new_val); }
                self.begin_fetch(pins)
            }
            1559 => {
                self.step = 1560;
                pins
            }
            1560 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_ctrl(pins, self.regs.hl(), MREQ | RD);
                self.step = 1561;
                pins
            }
            1561 => {
                self.dlatch = get_data(pins);
                if let Some(v) = self.cb_action(self.dlatch, true) { self.dlatch = v; } else { self.step = 1565; return Some(pins); }
                self.step = 1562;
                pins
            }
            1562 => {
                self.step = 1563;
                pins
            }
            1563 => {
                self.step = 1564;
                pins
            }
            1564 => {
                if pins & WAIT != 0 { return Some(pins); }
                let pins = set_addr_data_ctrl(pins, self.regs.hl(), self.dlatch, MREQ | WR);
                self.step = 1565;
                pins
            }
            1565 => {
                self.step = 1566;
                pins
            }
            1566 => {
                self.begin_fetch(pins)
            }
            _ => return None,
        })
    }
}
