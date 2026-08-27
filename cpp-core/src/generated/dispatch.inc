// GENERATED FILE -- do not edit by hand.
// Produced by scripts/generate_z80_dispatch.py from vendor/chips/z80_desc.yml.
// Regenerate with: python scripts/generate_z80_dispatch.py
//
// Included directly into the body of Z80::dispatch_generated() in z80.cpp,
// which supplies the enclosing switch and the `pins` reference. Not a
// standalone translation unit -- it needs that function's scope.
//
// One switch case per HALF-T-state: every T-state is two cases, H then L
// (address valid on H, control lines assert on L). See z80.h's header
// comment for why that split exists.

/// Step number for the CB-prefix register-direct payload ("cb" in
/// z80_desc.yml) -- the hand-written CB fetch machine cycle jumps straight
/// here, not through the 0..512 opcode table.
#define ZX_CB_STEP 2772
/// Same, for the "(HL)" form ("cbhl" in z80_desc.yml).
#define ZX_CBHL_STEP 2773

        case 0: {
            pins = begin_fetch(pins);
            return true;
        }
        case 1: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 512;
            return true;
        }
        case 512: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 513;
            return true;
        }
        case 513: {
            step_ = 514;
            return true;
        }
        case 514: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 515;
            return true;
        }
        case 515: {
            step_ = 516;
            return true;
        }
        case 516: {
            regs.c = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 517;
            return true;
        }
        case 517: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 518;
            return true;
        }
        case 518: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 519;
            return true;
        }
        case 519: {
            step_ = 520;
            return true;
        }
        case 520: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 521;
            return true;
        }
        case 521: {
            step_ = 522;
            return true;
        }
        case 522: {
            regs.b = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 523;
            return true;
        }
        case 523: {
            pins = begin_fetch(pins);
            return true;
        }
        case 2: {
            pins = set_addr(pins, regs.bc());
            step_ = 524;
            return true;
        }
        case 524: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 525;
            return true;
        }
        case 525: {
            pins = set_data(pins, regs.a);
            step_ = 526;
            return true;
        }
        case 526: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.set_wzl(uint8_t(regs.c + 1)); regs.set_wzh(regs.a);
            step_ = 527;
            return true;
        }
        case 527: {
            step_ = 528;
            return true;
        }
        case 528: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 529;
            return true;
        }
        case 529: {
            pins = begin_fetch(pins);
            return true;
        }
        case 3: {
            step_ = 530;
            return true;
        }
        case 530: {
            regs.set_bc(uint16_t(regs.bc() + 1));
            step_ = 531;
            return true;
        }
        case 531: {
            step_ = 532;
            return true;
        }
        case 532: {
            step_ = 533;
            return true;
        }
        case 533: {
            pins = begin_fetch(pins);
            return true;
        }
        case 4: {
            auto r = alu::inc8(regs.b, regs.f); regs.b = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 5: {
            auto r = alu::dec8(regs.b, regs.f); regs.b = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 6: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 534;
            return true;
        }
        case 534: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 535;
            return true;
        }
        case 535: {
            step_ = 536;
            return true;
        }
        case 536: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 537;
            return true;
        }
        case 537: {
            step_ = 538;
            return true;
        }
        case 538: {
            regs.b = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 539;
            return true;
        }
        case 539: {
            pins = begin_fetch(pins);
            return true;
        }
        case 7: {
            auto r = alu::rlca(regs.a, regs.f); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 8: {
            uint16_t af = regs.af(); uint16_t af2 = uint16_t((regs.a_ << 8) | regs.f_); regs.set_af(af2); regs.a_ = uint8_t(af >> 8); regs.f_ = uint8_t(af);
            pins = begin_fetch(pins);
            return true;
        }
        case 9: {
            step_ = 540;
            return true;
        }
        case 540: {
            regs.wz = uint16_t(hlx() + 1); auto r = alu::add16(hlx(), regs.bc(), regs.f); set_hlx(r.value); regs.f = r.flags;
            step_ = 541;
            return true;
        }
        case 541: {
            step_ = 542;
            return true;
        }
        case 542: {
            step_ = 543;
            return true;
        }
        case 543: {
            step_ = 544;
            return true;
        }
        case 544: {
            step_ = 545;
            return true;
        }
        case 545: {
            step_ = 546;
            return true;
        }
        case 546: {
            step_ = 547;
            return true;
        }
        case 547: {
            step_ = 548;
            return true;
        }
        case 548: {
            step_ = 549;
            return true;
        }
        case 549: {
            step_ = 550;
            return true;
        }
        case 550: {
            step_ = 551;
            return true;
        }
        case 551: {
            step_ = 552;
            return true;
        }
        case 552: {
            step_ = 553;
            return true;
        }
        case 553: {
            pins = begin_fetch(pins);
            return true;
        }
        case 10: {
            pins = set_addr(pins, regs.bc());
            step_ = 554;
            return true;
        }
        case 554: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 555;
            return true;
        }
        case 555: {
            step_ = 556;
            return true;
        }
        case 556: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 557;
            return true;
        }
        case 557: {
            step_ = 558;
            return true;
        }
        case 558: {
            regs.a = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, MREQ | RD);
            step_ = 559;
            return true;
        }
        case 559: {
            pins = begin_fetch(pins);
            return true;
        }
        case 11: {
            step_ = 560;
            return true;
        }
        case 560: {
            regs.set_bc(uint16_t(regs.bc() - 1));
            step_ = 561;
            return true;
        }
        case 561: {
            step_ = 562;
            return true;
        }
        case 562: {
            step_ = 563;
            return true;
        }
        case 563: {
            pins = begin_fetch(pins);
            return true;
        }
        case 12: {
            auto r = alu::inc8(regs.c, regs.f); regs.c = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 13: {
            auto r = alu::dec8(regs.c, regs.f); regs.c = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 14: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 564;
            return true;
        }
        case 564: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 565;
            return true;
        }
        case 565: {
            step_ = 566;
            return true;
        }
        case 566: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 567;
            return true;
        }
        case 567: {
            step_ = 568;
            return true;
        }
        case 568: {
            regs.c = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 569;
            return true;
        }
        case 569: {
            pins = begin_fetch(pins);
            return true;
        }
        case 15: {
            auto r = alu::rrca(regs.a, regs.f); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 16: {
            step_ = 570;
            return true;
        }
        case 570: {
            step_ = 571;
            return true;
        }
        case 571: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 572;
            return true;
        }
        case 572: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 573;
            return true;
        }
        case 573: {
            step_ = 574;
            return true;
        }
        case 574: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 575;
            return true;
        }
        case 575: {
            step_ = 576;
            return true;
        }
        case 576: {
            dlatch_ = get_data(pins);
            regs.b = uint8_t(regs.b - 1); if (regs.b == 0) { pins = release_pins(pins, MREQ | RD); step_ = 587; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 577;
            return true;
        }
        case 577: {
            step_ = 578;
            return true;
        }
        case 578: {
            regs.pc = uint16_t(regs.pc + int8_t(dlatch_)); regs.wz = regs.pc;
            step_ = 579;
            return true;
        }
        case 579: {
            step_ = 580;
            return true;
        }
        case 580: {
            step_ = 581;
            return true;
        }
        case 581: {
            step_ = 582;
            return true;
        }
        case 582: {
            step_ = 583;
            return true;
        }
        case 583: {
            step_ = 584;
            return true;
        }
        case 584: {
            step_ = 585;
            return true;
        }
        case 585: {
            step_ = 586;
            return true;
        }
        case 586: {
            step_ = 587;
            return true;
        }
        case 587: {
            pins = begin_fetch(pins);
            return true;
        }
        case 17: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 588;
            return true;
        }
        case 588: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 589;
            return true;
        }
        case 589: {
            step_ = 590;
            return true;
        }
        case 590: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 591;
            return true;
        }
        case 591: {
            step_ = 592;
            return true;
        }
        case 592: {
            regs.e = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 593;
            return true;
        }
        case 593: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 594;
            return true;
        }
        case 594: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 595;
            return true;
        }
        case 595: {
            step_ = 596;
            return true;
        }
        case 596: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 597;
            return true;
        }
        case 597: {
            step_ = 598;
            return true;
        }
        case 598: {
            regs.d = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 599;
            return true;
        }
        case 599: {
            pins = begin_fetch(pins);
            return true;
        }
        case 18: {
            pins = set_addr(pins, regs.de());
            step_ = 600;
            return true;
        }
        case 600: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 601;
            return true;
        }
        case 601: {
            pins = set_data(pins, regs.a);
            step_ = 602;
            return true;
        }
        case 602: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.set_wzl(uint8_t(regs.e + 1)); regs.set_wzh(regs.a);
            step_ = 603;
            return true;
        }
        case 603: {
            step_ = 604;
            return true;
        }
        case 604: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 605;
            return true;
        }
        case 605: {
            pins = begin_fetch(pins);
            return true;
        }
        case 19: {
            step_ = 606;
            return true;
        }
        case 606: {
            regs.set_de(uint16_t(regs.de() + 1));
            step_ = 607;
            return true;
        }
        case 607: {
            step_ = 608;
            return true;
        }
        case 608: {
            step_ = 609;
            return true;
        }
        case 609: {
            pins = begin_fetch(pins);
            return true;
        }
        case 20: {
            auto r = alu::inc8(regs.d, regs.f); regs.d = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 21: {
            auto r = alu::dec8(regs.d, regs.f); regs.d = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 22: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 610;
            return true;
        }
        case 610: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 611;
            return true;
        }
        case 611: {
            step_ = 612;
            return true;
        }
        case 612: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 613;
            return true;
        }
        case 613: {
            step_ = 614;
            return true;
        }
        case 614: {
            regs.d = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 615;
            return true;
        }
        case 615: {
            pins = begin_fetch(pins);
            return true;
        }
        case 23: {
            auto r = alu::rla(regs.a, regs.f); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 24: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 616;
            return true;
        }
        case 616: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 617;
            return true;
        }
        case 617: {
            step_ = 618;
            return true;
        }
        case 618: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 619;
            return true;
        }
        case 619: {
            step_ = 620;
            return true;
        }
        case 620: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 621;
            return true;
        }
        case 621: {
            step_ = 622;
            return true;
        }
        case 622: {
            regs.pc = uint16_t(regs.pc + int8_t(dlatch_)); regs.wz = regs.pc;
            step_ = 623;
            return true;
        }
        case 623: {
            step_ = 624;
            return true;
        }
        case 624: {
            step_ = 625;
            return true;
        }
        case 625: {
            step_ = 626;
            return true;
        }
        case 626: {
            step_ = 627;
            return true;
        }
        case 627: {
            step_ = 628;
            return true;
        }
        case 628: {
            step_ = 629;
            return true;
        }
        case 629: {
            step_ = 630;
            return true;
        }
        case 630: {
            step_ = 631;
            return true;
        }
        case 631: {
            pins = begin_fetch(pins);
            return true;
        }
        case 25: {
            step_ = 632;
            return true;
        }
        case 632: {
            regs.wz = uint16_t(hlx() + 1); auto r = alu::add16(hlx(), regs.de(), regs.f); set_hlx(r.value); regs.f = r.flags;
            step_ = 633;
            return true;
        }
        case 633: {
            step_ = 634;
            return true;
        }
        case 634: {
            step_ = 635;
            return true;
        }
        case 635: {
            step_ = 636;
            return true;
        }
        case 636: {
            step_ = 637;
            return true;
        }
        case 637: {
            step_ = 638;
            return true;
        }
        case 638: {
            step_ = 639;
            return true;
        }
        case 639: {
            step_ = 640;
            return true;
        }
        case 640: {
            step_ = 641;
            return true;
        }
        case 641: {
            step_ = 642;
            return true;
        }
        case 642: {
            step_ = 643;
            return true;
        }
        case 643: {
            step_ = 644;
            return true;
        }
        case 644: {
            step_ = 645;
            return true;
        }
        case 645: {
            pins = begin_fetch(pins);
            return true;
        }
        case 26: {
            pins = set_addr(pins, regs.de());
            step_ = 646;
            return true;
        }
        case 646: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 647;
            return true;
        }
        case 647: {
            step_ = 648;
            return true;
        }
        case 648: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 649;
            return true;
        }
        case 649: {
            step_ = 650;
            return true;
        }
        case 650: {
            regs.a = get_data(pins);
            regs.wz = uint16_t(regs.de() + 1);
            pins = release_pins(pins, MREQ | RD);
            step_ = 651;
            return true;
        }
        case 651: {
            pins = begin_fetch(pins);
            return true;
        }
        case 27: {
            step_ = 652;
            return true;
        }
        case 652: {
            regs.set_de(uint16_t(regs.de() - 1));
            step_ = 653;
            return true;
        }
        case 653: {
            step_ = 654;
            return true;
        }
        case 654: {
            step_ = 655;
            return true;
        }
        case 655: {
            pins = begin_fetch(pins);
            return true;
        }
        case 28: {
            auto r = alu::inc8(regs.e, regs.f); regs.e = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 29: {
            auto r = alu::dec8(regs.e, regs.f); regs.e = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 30: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 656;
            return true;
        }
        case 656: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 657;
            return true;
        }
        case 657: {
            step_ = 658;
            return true;
        }
        case 658: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 659;
            return true;
        }
        case 659: {
            step_ = 660;
            return true;
        }
        case 660: {
            regs.e = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 661;
            return true;
        }
        case 661: {
            pins = begin_fetch(pins);
            return true;
        }
        case 31: {
            auto r = alu::rra(regs.a, regs.f); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 32: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 662;
            return true;
        }
        case 662: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 663;
            return true;
        }
        case 663: {
            step_ = 664;
            return true;
        }
        case 664: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 665;
            return true;
        }
        case 665: {
            step_ = 666;
            return true;
        }
        case 666: {
            dlatch_ = get_data(pins);
            if (!((regs.f & FLAG_Z) == 0)) { pins = release_pins(pins, MREQ | RD); step_ = 677; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 667;
            return true;
        }
        case 667: {
            step_ = 668;
            return true;
        }
        case 668: {
            regs.pc = uint16_t(regs.pc + int8_t(dlatch_)); regs.wz = regs.pc;
            step_ = 669;
            return true;
        }
        case 669: {
            step_ = 670;
            return true;
        }
        case 670: {
            step_ = 671;
            return true;
        }
        case 671: {
            step_ = 672;
            return true;
        }
        case 672: {
            step_ = 673;
            return true;
        }
        case 673: {
            step_ = 674;
            return true;
        }
        case 674: {
            step_ = 675;
            return true;
        }
        case 675: {
            step_ = 676;
            return true;
        }
        case 676: {
            step_ = 677;
            return true;
        }
        case 677: {
            pins = begin_fetch(pins);
            return true;
        }
        case 33: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 678;
            return true;
        }
        case 678: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 679;
            return true;
        }
        case 679: {
            step_ = 680;
            return true;
        }
        case 680: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 681;
            return true;
        }
        case 681: {
            step_ = 682;
            return true;
        }
        case 682: {
            set_hlx_l(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 683;
            return true;
        }
        case 683: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 684;
            return true;
        }
        case 684: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 685;
            return true;
        }
        case 685: {
            step_ = 686;
            return true;
        }
        case 686: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 687;
            return true;
        }
        case 687: {
            step_ = 688;
            return true;
        }
        case 688: {
            set_hlx_h(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 689;
            return true;
        }
        case 689: {
            pins = begin_fetch(pins);
            return true;
        }
        case 34: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 690;
            return true;
        }
        case 690: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 691;
            return true;
        }
        case 691: {
            step_ = 692;
            return true;
        }
        case 692: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 693;
            return true;
        }
        case 693: {
            step_ = 694;
            return true;
        }
        case 694: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 695;
            return true;
        }
        case 695: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 696;
            return true;
        }
        case 696: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 697;
            return true;
        }
        case 697: {
            step_ = 698;
            return true;
        }
        case 698: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 699;
            return true;
        }
        case 699: {
            step_ = 700;
            return true;
        }
        case 700: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 701;
            return true;
        }
        case 701: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 702;
            return true;
        }
        case 702: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 703;
            return true;
        }
        case 703: {
            pins = set_data(pins, hlx_l());
            step_ = 704;
            return true;
        }
        case 704: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 705;
            return true;
        }
        case 705: {
            step_ = 706;
            return true;
        }
        case 706: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 707;
            return true;
        }
        case 707: {
            pins = set_addr(pins, regs.wz);
            step_ = 708;
            return true;
        }
        case 708: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 709;
            return true;
        }
        case 709: {
            pins = set_data(pins, hlx_h());
            step_ = 710;
            return true;
        }
        case 710: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 711;
            return true;
        }
        case 711: {
            step_ = 712;
            return true;
        }
        case 712: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 713;
            return true;
        }
        case 713: {
            pins = begin_fetch(pins);
            return true;
        }
        case 35: {
            step_ = 714;
            return true;
        }
        case 714: {
            set_hlx(uint16_t(hlx() + 1));
            step_ = 715;
            return true;
        }
        case 715: {
            step_ = 716;
            return true;
        }
        case 716: {
            step_ = 717;
            return true;
        }
        case 717: {
            pins = begin_fetch(pins);
            return true;
        }
        case 36: {
            auto r = alu::inc8(hlx_h(), regs.f); set_hlx_h(r.value); regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 37: {
            auto r = alu::dec8(hlx_h(), regs.f); set_hlx_h(r.value); regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 38: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 718;
            return true;
        }
        case 718: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 719;
            return true;
        }
        case 719: {
            step_ = 720;
            return true;
        }
        case 720: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 721;
            return true;
        }
        case 721: {
            step_ = 722;
            return true;
        }
        case 722: {
            set_hlx_h(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 723;
            return true;
        }
        case 723: {
            pins = begin_fetch(pins);
            return true;
        }
        case 39: {
            auto r = alu::daa(regs.a, regs.f); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 40: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 724;
            return true;
        }
        case 724: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 725;
            return true;
        }
        case 725: {
            step_ = 726;
            return true;
        }
        case 726: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 727;
            return true;
        }
        case 727: {
            step_ = 728;
            return true;
        }
        case 728: {
            dlatch_ = get_data(pins);
            if (!((regs.f & FLAG_Z) != 0)) { pins = release_pins(pins, MREQ | RD); step_ = 739; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 729;
            return true;
        }
        case 729: {
            step_ = 730;
            return true;
        }
        case 730: {
            regs.pc = uint16_t(regs.pc + int8_t(dlatch_)); regs.wz = regs.pc;
            step_ = 731;
            return true;
        }
        case 731: {
            step_ = 732;
            return true;
        }
        case 732: {
            step_ = 733;
            return true;
        }
        case 733: {
            step_ = 734;
            return true;
        }
        case 734: {
            step_ = 735;
            return true;
        }
        case 735: {
            step_ = 736;
            return true;
        }
        case 736: {
            step_ = 737;
            return true;
        }
        case 737: {
            step_ = 738;
            return true;
        }
        case 738: {
            step_ = 739;
            return true;
        }
        case 739: {
            pins = begin_fetch(pins);
            return true;
        }
        case 41: {
            step_ = 740;
            return true;
        }
        case 740: {
            regs.wz = uint16_t(hlx() + 1); auto r = alu::add16(hlx(), hlx(), regs.f); set_hlx(r.value); regs.f = r.flags;
            step_ = 741;
            return true;
        }
        case 741: {
            step_ = 742;
            return true;
        }
        case 742: {
            step_ = 743;
            return true;
        }
        case 743: {
            step_ = 744;
            return true;
        }
        case 744: {
            step_ = 745;
            return true;
        }
        case 745: {
            step_ = 746;
            return true;
        }
        case 746: {
            step_ = 747;
            return true;
        }
        case 747: {
            step_ = 748;
            return true;
        }
        case 748: {
            step_ = 749;
            return true;
        }
        case 749: {
            step_ = 750;
            return true;
        }
        case 750: {
            step_ = 751;
            return true;
        }
        case 751: {
            step_ = 752;
            return true;
        }
        case 752: {
            step_ = 753;
            return true;
        }
        case 753: {
            pins = begin_fetch(pins);
            return true;
        }
        case 42: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 754;
            return true;
        }
        case 754: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 755;
            return true;
        }
        case 755: {
            step_ = 756;
            return true;
        }
        case 756: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 757;
            return true;
        }
        case 757: {
            step_ = 758;
            return true;
        }
        case 758: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 759;
            return true;
        }
        case 759: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 760;
            return true;
        }
        case 760: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 761;
            return true;
        }
        case 761: {
            step_ = 762;
            return true;
        }
        case 762: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 763;
            return true;
        }
        case 763: {
            step_ = 764;
            return true;
        }
        case 764: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 765;
            return true;
        }
        case 765: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 766;
            return true;
        }
        case 766: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 767;
            return true;
        }
        case 767: {
            step_ = 768;
            return true;
        }
        case 768: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 769;
            return true;
        }
        case 769: {
            step_ = 770;
            return true;
        }
        case 770: {
            set_hlx_l(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 771;
            return true;
        }
        case 771: {
            pins = set_addr(pins, regs.wz);
            step_ = 772;
            return true;
        }
        case 772: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 773;
            return true;
        }
        case 773: {
            step_ = 774;
            return true;
        }
        case 774: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 775;
            return true;
        }
        case 775: {
            step_ = 776;
            return true;
        }
        case 776: {
            set_hlx_h(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 777;
            return true;
        }
        case 777: {
            pins = begin_fetch(pins);
            return true;
        }
        case 43: {
            step_ = 778;
            return true;
        }
        case 778: {
            set_hlx(uint16_t(hlx() - 1));
            step_ = 779;
            return true;
        }
        case 779: {
            step_ = 780;
            return true;
        }
        case 780: {
            step_ = 781;
            return true;
        }
        case 781: {
            pins = begin_fetch(pins);
            return true;
        }
        case 44: {
            auto r = alu::inc8(hlx_l(), regs.f); set_hlx_l(r.value); regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 45: {
            auto r = alu::dec8(hlx_l(), regs.f); set_hlx_l(r.value); regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 46: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 782;
            return true;
        }
        case 782: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 783;
            return true;
        }
        case 783: {
            step_ = 784;
            return true;
        }
        case 784: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 785;
            return true;
        }
        case 785: {
            step_ = 786;
            return true;
        }
        case 786: {
            set_hlx_l(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 787;
            return true;
        }
        case 787: {
            pins = begin_fetch(pins);
            return true;
        }
        case 47: {
            auto r = alu::cpl(regs.a, regs.f); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 48: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 788;
            return true;
        }
        case 788: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 789;
            return true;
        }
        case 789: {
            step_ = 790;
            return true;
        }
        case 790: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 791;
            return true;
        }
        case 791: {
            step_ = 792;
            return true;
        }
        case 792: {
            dlatch_ = get_data(pins);
            if (!((regs.f & FLAG_C) == 0)) { pins = release_pins(pins, MREQ | RD); step_ = 803; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 793;
            return true;
        }
        case 793: {
            step_ = 794;
            return true;
        }
        case 794: {
            regs.pc = uint16_t(regs.pc + int8_t(dlatch_)); regs.wz = regs.pc;
            step_ = 795;
            return true;
        }
        case 795: {
            step_ = 796;
            return true;
        }
        case 796: {
            step_ = 797;
            return true;
        }
        case 797: {
            step_ = 798;
            return true;
        }
        case 798: {
            step_ = 799;
            return true;
        }
        case 799: {
            step_ = 800;
            return true;
        }
        case 800: {
            step_ = 801;
            return true;
        }
        case 801: {
            step_ = 802;
            return true;
        }
        case 802: {
            step_ = 803;
            return true;
        }
        case 803: {
            pins = begin_fetch(pins);
            return true;
        }
        case 49: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 804;
            return true;
        }
        case 804: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 805;
            return true;
        }
        case 805: {
            step_ = 806;
            return true;
        }
        case 806: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 807;
            return true;
        }
        case 807: {
            step_ = 808;
            return true;
        }
        case 808: {
            regs.set_spl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 809;
            return true;
        }
        case 809: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 810;
            return true;
        }
        case 810: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 811;
            return true;
        }
        case 811: {
            step_ = 812;
            return true;
        }
        case 812: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 813;
            return true;
        }
        case 813: {
            step_ = 814;
            return true;
        }
        case 814: {
            regs.set_sph(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 815;
            return true;
        }
        case 815: {
            pins = begin_fetch(pins);
            return true;
        }
        case 50: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 816;
            return true;
        }
        case 816: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 817;
            return true;
        }
        case 817: {
            step_ = 818;
            return true;
        }
        case 818: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 819;
            return true;
        }
        case 819: {
            step_ = 820;
            return true;
        }
        case 820: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 821;
            return true;
        }
        case 821: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 822;
            return true;
        }
        case 822: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 823;
            return true;
        }
        case 823: {
            step_ = 824;
            return true;
        }
        case 824: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 825;
            return true;
        }
        case 825: {
            step_ = 826;
            return true;
        }
        case 826: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 827;
            return true;
        }
        case 827: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 828;
            return true;
        }
        case 828: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 829;
            return true;
        }
        case 829: {
            pins = set_data(pins, regs.a);
            step_ = 830;
            return true;
        }
        case 830: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.set_wzh(regs.a);
            step_ = 831;
            return true;
        }
        case 831: {
            step_ = 832;
            return true;
        }
        case 832: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 833;
            return true;
        }
        case 833: {
            pins = begin_fetch(pins);
            return true;
        }
        case 51: {
            step_ = 834;
            return true;
        }
        case 834: {
            regs.sp = uint16_t(regs.sp + 1);
            step_ = 835;
            return true;
        }
        case 835: {
            step_ = 836;
            return true;
        }
        case 836: {
            step_ = 837;
            return true;
        }
        case 837: {
            pins = begin_fetch(pins);
            return true;
        }
        case 52: {
            pins = set_addr(pins, addr_);
            step_ = 838;
            return true;
        }
        case 838: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 839;
            return true;
        }
        case 839: {
            step_ = 840;
            return true;
        }
        case 840: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 841;
            return true;
        }
        case 841: {
            step_ = 842;
            return true;
        }
        case 842: {
            dlatch_ = get_data(pins);
            auto r = alu::inc8(dlatch_, regs.f); dlatch_ = r.value; regs.f = r.flags;
            pins = release_pins(pins, MREQ | RD);
            step_ = 843;
            return true;
        }
        case 843: {
            step_ = 844;
            return true;
        }
        case 844: {
            step_ = 845;
            return true;
        }
        case 845: {
            pins = set_addr(pins, addr_);
            step_ = 846;
            return true;
        }
        case 846: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 847;
            return true;
        }
        case 847: {
            pins = set_data(pins, dlatch_);
            step_ = 848;
            return true;
        }
        case 848: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 849;
            return true;
        }
        case 849: {
            step_ = 850;
            return true;
        }
        case 850: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 851;
            return true;
        }
        case 851: {
            pins = begin_fetch(pins);
            return true;
        }
        case 53: {
            pins = set_addr(pins, addr_);
            step_ = 852;
            return true;
        }
        case 852: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 853;
            return true;
        }
        case 853: {
            step_ = 854;
            return true;
        }
        case 854: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 855;
            return true;
        }
        case 855: {
            step_ = 856;
            return true;
        }
        case 856: {
            dlatch_ = get_data(pins);
            auto r = alu::dec8(dlatch_, regs.f); dlatch_ = r.value; regs.f = r.flags;
            pins = release_pins(pins, MREQ | RD);
            step_ = 857;
            return true;
        }
        case 857: {
            step_ = 858;
            return true;
        }
        case 858: {
            step_ = 859;
            return true;
        }
        case 859: {
            pins = set_addr(pins, addr_);
            step_ = 860;
            return true;
        }
        case 860: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 861;
            return true;
        }
        case 861: {
            pins = set_data(pins, dlatch_);
            step_ = 862;
            return true;
        }
        case 862: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 863;
            return true;
        }
        case 863: {
            step_ = 864;
            return true;
        }
        case 864: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 865;
            return true;
        }
        case 865: {
            pins = begin_fetch(pins);
            return true;
        }
        case 54: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 866;
            return true;
        }
        case 866: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 867;
            return true;
        }
        case 867: {
            step_ = 868;
            return true;
        }
        case 868: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 869;
            return true;
        }
        case 869: {
            step_ = 870;
            return true;
        }
        case 870: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 871;
            return true;
        }
        case 871: {
            pins = set_addr(pins, addr_);
            step_ = 872;
            return true;
        }
        case 872: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 873;
            return true;
        }
        case 873: {
            pins = set_data(pins, dlatch_);
            step_ = 874;
            return true;
        }
        case 874: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 875;
            return true;
        }
        case 875: {
            step_ = 876;
            return true;
        }
        case 876: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 877;
            return true;
        }
        case 877: {
            pins = begin_fetch(pins);
            return true;
        }
        case 55: {
            regs.f = alu::scf(regs.a, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 56: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 878;
            return true;
        }
        case 878: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 879;
            return true;
        }
        case 879: {
            step_ = 880;
            return true;
        }
        case 880: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 881;
            return true;
        }
        case 881: {
            step_ = 882;
            return true;
        }
        case 882: {
            dlatch_ = get_data(pins);
            if (!((regs.f & FLAG_C) != 0)) { pins = release_pins(pins, MREQ | RD); step_ = 893; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 883;
            return true;
        }
        case 883: {
            step_ = 884;
            return true;
        }
        case 884: {
            regs.pc = uint16_t(regs.pc + int8_t(dlatch_)); regs.wz = regs.pc;
            step_ = 885;
            return true;
        }
        case 885: {
            step_ = 886;
            return true;
        }
        case 886: {
            step_ = 887;
            return true;
        }
        case 887: {
            step_ = 888;
            return true;
        }
        case 888: {
            step_ = 889;
            return true;
        }
        case 889: {
            step_ = 890;
            return true;
        }
        case 890: {
            step_ = 891;
            return true;
        }
        case 891: {
            step_ = 892;
            return true;
        }
        case 892: {
            step_ = 893;
            return true;
        }
        case 893: {
            pins = begin_fetch(pins);
            return true;
        }
        case 57: {
            step_ = 894;
            return true;
        }
        case 894: {
            regs.wz = uint16_t(hlx() + 1); auto r = alu::add16(hlx(), regs.sp, regs.f); set_hlx(r.value); regs.f = r.flags;
            step_ = 895;
            return true;
        }
        case 895: {
            step_ = 896;
            return true;
        }
        case 896: {
            step_ = 897;
            return true;
        }
        case 897: {
            step_ = 898;
            return true;
        }
        case 898: {
            step_ = 899;
            return true;
        }
        case 899: {
            step_ = 900;
            return true;
        }
        case 900: {
            step_ = 901;
            return true;
        }
        case 901: {
            step_ = 902;
            return true;
        }
        case 902: {
            step_ = 903;
            return true;
        }
        case 903: {
            step_ = 904;
            return true;
        }
        case 904: {
            step_ = 905;
            return true;
        }
        case 905: {
            step_ = 906;
            return true;
        }
        case 906: {
            step_ = 907;
            return true;
        }
        case 907: {
            pins = begin_fetch(pins);
            return true;
        }
        case 58: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 908;
            return true;
        }
        case 908: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 909;
            return true;
        }
        case 909: {
            step_ = 910;
            return true;
        }
        case 910: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 911;
            return true;
        }
        case 911: {
            step_ = 912;
            return true;
        }
        case 912: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 913;
            return true;
        }
        case 913: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 914;
            return true;
        }
        case 914: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 915;
            return true;
        }
        case 915: {
            step_ = 916;
            return true;
        }
        case 916: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 917;
            return true;
        }
        case 917: {
            step_ = 918;
            return true;
        }
        case 918: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 919;
            return true;
        }
        case 919: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 920;
            return true;
        }
        case 920: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 921;
            return true;
        }
        case 921: {
            step_ = 922;
            return true;
        }
        case 922: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 923;
            return true;
        }
        case 923: {
            step_ = 924;
            return true;
        }
        case 924: {
            regs.a = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 925;
            return true;
        }
        case 925: {
            pins = begin_fetch(pins);
            return true;
        }
        case 59: {
            step_ = 926;
            return true;
        }
        case 926: {
            regs.sp = uint16_t(regs.sp - 1);
            step_ = 927;
            return true;
        }
        case 927: {
            step_ = 928;
            return true;
        }
        case 928: {
            step_ = 929;
            return true;
        }
        case 929: {
            pins = begin_fetch(pins);
            return true;
        }
        case 60: {
            auto r = alu::inc8(regs.a, regs.f); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 61: {
            auto r = alu::dec8(regs.a, regs.f); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 62: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 930;
            return true;
        }
        case 930: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 931;
            return true;
        }
        case 931: {
            step_ = 932;
            return true;
        }
        case 932: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 933;
            return true;
        }
        case 933: {
            step_ = 934;
            return true;
        }
        case 934: {
            regs.a = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 935;
            return true;
        }
        case 935: {
            pins = begin_fetch(pins);
            return true;
        }
        case 63: {
            regs.f = alu::ccf(regs.a, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 64: {
            regs.b = regs.b;
            pins = begin_fetch(pins);
            return true;
        }
        case 65: {
            regs.b = regs.c;
            pins = begin_fetch(pins);
            return true;
        }
        case 66: {
            regs.b = regs.d;
            pins = begin_fetch(pins);
            return true;
        }
        case 67: {
            regs.b = regs.e;
            pins = begin_fetch(pins);
            return true;
        }
        case 68: {
            regs.b = hlx_h();
            pins = begin_fetch(pins);
            return true;
        }
        case 69: {
            regs.b = hlx_l();
            pins = begin_fetch(pins);
            return true;
        }
        case 70: {
            pins = set_addr(pins, addr_);
            step_ = 936;
            return true;
        }
        case 936: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 937;
            return true;
        }
        case 937: {
            step_ = 938;
            return true;
        }
        case 938: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 939;
            return true;
        }
        case 939: {
            step_ = 940;
            return true;
        }
        case 940: {
            regs.b = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 941;
            return true;
        }
        case 941: {
            pins = begin_fetch(pins);
            return true;
        }
        case 71: {
            regs.b = regs.a;
            pins = begin_fetch(pins);
            return true;
        }
        case 72: {
            regs.c = regs.b;
            pins = begin_fetch(pins);
            return true;
        }
        case 73: {
            regs.c = regs.c;
            pins = begin_fetch(pins);
            return true;
        }
        case 74: {
            regs.c = regs.d;
            pins = begin_fetch(pins);
            return true;
        }
        case 75: {
            regs.c = regs.e;
            pins = begin_fetch(pins);
            return true;
        }
        case 76: {
            regs.c = hlx_h();
            pins = begin_fetch(pins);
            return true;
        }
        case 77: {
            regs.c = hlx_l();
            pins = begin_fetch(pins);
            return true;
        }
        case 78: {
            pins = set_addr(pins, addr_);
            step_ = 942;
            return true;
        }
        case 942: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 943;
            return true;
        }
        case 943: {
            step_ = 944;
            return true;
        }
        case 944: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 945;
            return true;
        }
        case 945: {
            step_ = 946;
            return true;
        }
        case 946: {
            regs.c = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 947;
            return true;
        }
        case 947: {
            pins = begin_fetch(pins);
            return true;
        }
        case 79: {
            regs.c = regs.a;
            pins = begin_fetch(pins);
            return true;
        }
        case 80: {
            regs.d = regs.b;
            pins = begin_fetch(pins);
            return true;
        }
        case 81: {
            regs.d = regs.c;
            pins = begin_fetch(pins);
            return true;
        }
        case 82: {
            regs.d = regs.d;
            pins = begin_fetch(pins);
            return true;
        }
        case 83: {
            regs.d = regs.e;
            pins = begin_fetch(pins);
            return true;
        }
        case 84: {
            regs.d = hlx_h();
            pins = begin_fetch(pins);
            return true;
        }
        case 85: {
            regs.d = hlx_l();
            pins = begin_fetch(pins);
            return true;
        }
        case 86: {
            pins = set_addr(pins, addr_);
            step_ = 948;
            return true;
        }
        case 948: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 949;
            return true;
        }
        case 949: {
            step_ = 950;
            return true;
        }
        case 950: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 951;
            return true;
        }
        case 951: {
            step_ = 952;
            return true;
        }
        case 952: {
            regs.d = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 953;
            return true;
        }
        case 953: {
            pins = begin_fetch(pins);
            return true;
        }
        case 87: {
            regs.d = regs.a;
            pins = begin_fetch(pins);
            return true;
        }
        case 88: {
            regs.e = regs.b;
            pins = begin_fetch(pins);
            return true;
        }
        case 89: {
            regs.e = regs.c;
            pins = begin_fetch(pins);
            return true;
        }
        case 90: {
            regs.e = regs.d;
            pins = begin_fetch(pins);
            return true;
        }
        case 91: {
            regs.e = regs.e;
            pins = begin_fetch(pins);
            return true;
        }
        case 92: {
            regs.e = hlx_h();
            pins = begin_fetch(pins);
            return true;
        }
        case 93: {
            regs.e = hlx_l();
            pins = begin_fetch(pins);
            return true;
        }
        case 94: {
            pins = set_addr(pins, addr_);
            step_ = 954;
            return true;
        }
        case 954: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 955;
            return true;
        }
        case 955: {
            step_ = 956;
            return true;
        }
        case 956: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 957;
            return true;
        }
        case 957: {
            step_ = 958;
            return true;
        }
        case 958: {
            regs.e = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 959;
            return true;
        }
        case 959: {
            pins = begin_fetch(pins);
            return true;
        }
        case 95: {
            regs.e = regs.a;
            pins = begin_fetch(pins);
            return true;
        }
        case 96: {
            set_hlx_h(regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 97: {
            set_hlx_h(regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 98: {
            set_hlx_h(regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 99: {
            set_hlx_h(regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 100: {
            set_hlx_h(hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 101: {
            set_hlx_h(hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 102: {
            pins = set_addr(pins, addr_);
            step_ = 960;
            return true;
        }
        case 960: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 961;
            return true;
        }
        case 961: {
            step_ = 962;
            return true;
        }
        case 962: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 963;
            return true;
        }
        case 963: {
            step_ = 964;
            return true;
        }
        case 964: {
            regs.h = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 965;
            return true;
        }
        case 965: {
            pins = begin_fetch(pins);
            return true;
        }
        case 103: {
            set_hlx_h(regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 104: {
            set_hlx_l(regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 105: {
            set_hlx_l(regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 106: {
            set_hlx_l(regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 107: {
            set_hlx_l(regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 108: {
            set_hlx_l(hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 109: {
            set_hlx_l(hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 110: {
            pins = set_addr(pins, addr_);
            step_ = 966;
            return true;
        }
        case 966: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 967;
            return true;
        }
        case 967: {
            step_ = 968;
            return true;
        }
        case 968: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 969;
            return true;
        }
        case 969: {
            step_ = 970;
            return true;
        }
        case 970: {
            regs.l = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 971;
            return true;
        }
        case 971: {
            pins = begin_fetch(pins);
            return true;
        }
        case 111: {
            set_hlx_l(regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 112: {
            pins = set_addr(pins, addr_);
            step_ = 972;
            return true;
        }
        case 972: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 973;
            return true;
        }
        case 973: {
            pins = set_data(pins, regs.b);
            step_ = 974;
            return true;
        }
        case 974: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 975;
            return true;
        }
        case 975: {
            step_ = 976;
            return true;
        }
        case 976: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 977;
            return true;
        }
        case 977: {
            pins = begin_fetch(pins);
            return true;
        }
        case 113: {
            pins = set_addr(pins, addr_);
            step_ = 978;
            return true;
        }
        case 978: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 979;
            return true;
        }
        case 979: {
            pins = set_data(pins, regs.c);
            step_ = 980;
            return true;
        }
        case 980: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 981;
            return true;
        }
        case 981: {
            step_ = 982;
            return true;
        }
        case 982: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 983;
            return true;
        }
        case 983: {
            pins = begin_fetch(pins);
            return true;
        }
        case 114: {
            pins = set_addr(pins, addr_);
            step_ = 984;
            return true;
        }
        case 984: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 985;
            return true;
        }
        case 985: {
            pins = set_data(pins, regs.d);
            step_ = 986;
            return true;
        }
        case 986: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 987;
            return true;
        }
        case 987: {
            step_ = 988;
            return true;
        }
        case 988: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 989;
            return true;
        }
        case 989: {
            pins = begin_fetch(pins);
            return true;
        }
        case 115: {
            pins = set_addr(pins, addr_);
            step_ = 990;
            return true;
        }
        case 990: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 991;
            return true;
        }
        case 991: {
            pins = set_data(pins, regs.e);
            step_ = 992;
            return true;
        }
        case 992: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 993;
            return true;
        }
        case 993: {
            step_ = 994;
            return true;
        }
        case 994: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 995;
            return true;
        }
        case 995: {
            pins = begin_fetch(pins);
            return true;
        }
        case 116: {
            pins = set_addr(pins, addr_);
            step_ = 996;
            return true;
        }
        case 996: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 997;
            return true;
        }
        case 997: {
            pins = set_data(pins, regs.h);
            step_ = 998;
            return true;
        }
        case 998: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 999;
            return true;
        }
        case 999: {
            step_ = 1000;
            return true;
        }
        case 1000: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1001;
            return true;
        }
        case 1001: {
            pins = begin_fetch(pins);
            return true;
        }
        case 117: {
            pins = set_addr(pins, addr_);
            step_ = 1002;
            return true;
        }
        case 1002: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1003;
            return true;
        }
        case 1003: {
            pins = set_data(pins, regs.l);
            step_ = 1004;
            return true;
        }
        case 1004: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1005;
            return true;
        }
        case 1005: {
            step_ = 1006;
            return true;
        }
        case 1006: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1007;
            return true;
        }
        case 1007: {
            pins = begin_fetch(pins);
            return true;
        }
        case 119: {
            pins = set_addr(pins, addr_);
            step_ = 1008;
            return true;
        }
        case 1008: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1009;
            return true;
        }
        case 1009: {
            pins = set_data(pins, regs.a);
            step_ = 1010;
            return true;
        }
        case 1010: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1011;
            return true;
        }
        case 1011: {
            step_ = 1012;
            return true;
        }
        case 1012: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1013;
            return true;
        }
        case 1013: {
            pins = begin_fetch(pins);
            return true;
        }
        case 120: {
            regs.a = regs.b;
            pins = begin_fetch(pins);
            return true;
        }
        case 121: {
            regs.a = regs.c;
            pins = begin_fetch(pins);
            return true;
        }
        case 122: {
            regs.a = regs.d;
            pins = begin_fetch(pins);
            return true;
        }
        case 123: {
            regs.a = regs.e;
            pins = begin_fetch(pins);
            return true;
        }
        case 124: {
            regs.a = hlx_h();
            pins = begin_fetch(pins);
            return true;
        }
        case 125: {
            regs.a = hlx_l();
            pins = begin_fetch(pins);
            return true;
        }
        case 126: {
            pins = set_addr(pins, addr_);
            step_ = 1014;
            return true;
        }
        case 1014: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1015;
            return true;
        }
        case 1015: {
            step_ = 1016;
            return true;
        }
        case 1016: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1017;
            return true;
        }
        case 1017: {
            step_ = 1018;
            return true;
        }
        case 1018: {
            regs.a = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1019;
            return true;
        }
        case 1019: {
            pins = begin_fetch(pins);
            return true;
        }
        case 127: {
            regs.a = regs.a;
            pins = begin_fetch(pins);
            return true;
        }
        case 128: {
            alu_op(0, regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 129: {
            alu_op(0, regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 130: {
            alu_op(0, regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 131: {
            alu_op(0, regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 132: {
            alu_op(0, hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 133: {
            alu_op(0, hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 134: {
            pins = set_addr(pins, addr_);
            step_ = 1020;
            return true;
        }
        case 1020: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1021;
            return true;
        }
        case 1021: {
            step_ = 1022;
            return true;
        }
        case 1022: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1023;
            return true;
        }
        case 1023: {
            step_ = 1024;
            return true;
        }
        case 1024: {
            dlatch_ = get_data(pins);
            alu_op(0, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1025;
            return true;
        }
        case 1025: {
            pins = begin_fetch(pins);
            return true;
        }
        case 135: {
            alu_op(0, regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 136: {
            alu_op(1, regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 137: {
            alu_op(1, regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 138: {
            alu_op(1, regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 139: {
            alu_op(1, regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 140: {
            alu_op(1, hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 141: {
            alu_op(1, hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 142: {
            pins = set_addr(pins, addr_);
            step_ = 1026;
            return true;
        }
        case 1026: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1027;
            return true;
        }
        case 1027: {
            step_ = 1028;
            return true;
        }
        case 1028: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1029;
            return true;
        }
        case 1029: {
            step_ = 1030;
            return true;
        }
        case 1030: {
            dlatch_ = get_data(pins);
            alu_op(1, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1031;
            return true;
        }
        case 1031: {
            pins = begin_fetch(pins);
            return true;
        }
        case 143: {
            alu_op(1, regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 144: {
            alu_op(2, regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 145: {
            alu_op(2, regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 146: {
            alu_op(2, regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 147: {
            alu_op(2, regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 148: {
            alu_op(2, hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 149: {
            alu_op(2, hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 150: {
            pins = set_addr(pins, addr_);
            step_ = 1032;
            return true;
        }
        case 1032: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1033;
            return true;
        }
        case 1033: {
            step_ = 1034;
            return true;
        }
        case 1034: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1035;
            return true;
        }
        case 1035: {
            step_ = 1036;
            return true;
        }
        case 1036: {
            dlatch_ = get_data(pins);
            alu_op(2, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1037;
            return true;
        }
        case 1037: {
            pins = begin_fetch(pins);
            return true;
        }
        case 151: {
            alu_op(2, regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 152: {
            alu_op(3, regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 153: {
            alu_op(3, regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 154: {
            alu_op(3, regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 155: {
            alu_op(3, regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 156: {
            alu_op(3, hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 157: {
            alu_op(3, hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 158: {
            pins = set_addr(pins, addr_);
            step_ = 1038;
            return true;
        }
        case 1038: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1039;
            return true;
        }
        case 1039: {
            step_ = 1040;
            return true;
        }
        case 1040: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1041;
            return true;
        }
        case 1041: {
            step_ = 1042;
            return true;
        }
        case 1042: {
            dlatch_ = get_data(pins);
            alu_op(3, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1043;
            return true;
        }
        case 1043: {
            pins = begin_fetch(pins);
            return true;
        }
        case 159: {
            alu_op(3, regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 160: {
            alu_op(4, regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 161: {
            alu_op(4, regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 162: {
            alu_op(4, regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 163: {
            alu_op(4, regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 164: {
            alu_op(4, hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 165: {
            alu_op(4, hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 166: {
            pins = set_addr(pins, addr_);
            step_ = 1044;
            return true;
        }
        case 1044: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1045;
            return true;
        }
        case 1045: {
            step_ = 1046;
            return true;
        }
        case 1046: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1047;
            return true;
        }
        case 1047: {
            step_ = 1048;
            return true;
        }
        case 1048: {
            dlatch_ = get_data(pins);
            alu_op(4, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1049;
            return true;
        }
        case 1049: {
            pins = begin_fetch(pins);
            return true;
        }
        case 167: {
            alu_op(4, regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 168: {
            alu_op(5, regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 169: {
            alu_op(5, regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 170: {
            alu_op(5, regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 171: {
            alu_op(5, regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 172: {
            alu_op(5, hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 173: {
            alu_op(5, hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 174: {
            pins = set_addr(pins, addr_);
            step_ = 1050;
            return true;
        }
        case 1050: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1051;
            return true;
        }
        case 1051: {
            step_ = 1052;
            return true;
        }
        case 1052: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1053;
            return true;
        }
        case 1053: {
            step_ = 1054;
            return true;
        }
        case 1054: {
            dlatch_ = get_data(pins);
            alu_op(5, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1055;
            return true;
        }
        case 1055: {
            pins = begin_fetch(pins);
            return true;
        }
        case 175: {
            alu_op(5, regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 176: {
            alu_op(6, regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 177: {
            alu_op(6, regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 178: {
            alu_op(6, regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 179: {
            alu_op(6, regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 180: {
            alu_op(6, hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 181: {
            alu_op(6, hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 182: {
            pins = set_addr(pins, addr_);
            step_ = 1056;
            return true;
        }
        case 1056: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1057;
            return true;
        }
        case 1057: {
            step_ = 1058;
            return true;
        }
        case 1058: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1059;
            return true;
        }
        case 1059: {
            step_ = 1060;
            return true;
        }
        case 1060: {
            dlatch_ = get_data(pins);
            alu_op(6, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1061;
            return true;
        }
        case 1061: {
            pins = begin_fetch(pins);
            return true;
        }
        case 183: {
            alu_op(6, regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 184: {
            alu_op(7, regs.b);
            pins = begin_fetch(pins);
            return true;
        }
        case 185: {
            alu_op(7, regs.c);
            pins = begin_fetch(pins);
            return true;
        }
        case 186: {
            alu_op(7, regs.d);
            pins = begin_fetch(pins);
            return true;
        }
        case 187: {
            alu_op(7, regs.e);
            pins = begin_fetch(pins);
            return true;
        }
        case 188: {
            alu_op(7, hlx_h());
            pins = begin_fetch(pins);
            return true;
        }
        case 189: {
            alu_op(7, hlx_l());
            pins = begin_fetch(pins);
            return true;
        }
        case 190: {
            pins = set_addr(pins, addr_);
            step_ = 1062;
            return true;
        }
        case 1062: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1063;
            return true;
        }
        case 1063: {
            step_ = 1064;
            return true;
        }
        case 1064: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1065;
            return true;
        }
        case 1065: {
            step_ = 1066;
            return true;
        }
        case 1066: {
            dlatch_ = get_data(pins);
            alu_op(7, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1067;
            return true;
        }
        case 1067: {
            pins = begin_fetch(pins);
            return true;
        }
        case 191: {
            alu_op(7, regs.a);
            pins = begin_fetch(pins);
            return true;
        }
        case 192: {
            step_ = 1068;
            return true;
        }
        case 1068: {
            if (!((regs.f & FLAG_Z) == 0)) { step_ = 1081; return true; }
            step_ = 1069;
            return true;
        }
        case 1069: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1070;
            return true;
        }
        case 1070: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1071;
            return true;
        }
        case 1071: {
            step_ = 1072;
            return true;
        }
        case 1072: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1073;
            return true;
        }
        case 1073: {
            step_ = 1074;
            return true;
        }
        case 1074: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1075;
            return true;
        }
        case 1075: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1076;
            return true;
        }
        case 1076: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1077;
            return true;
        }
        case 1077: {
            step_ = 1078;
            return true;
        }
        case 1078: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1079;
            return true;
        }
        case 1079: {
            step_ = 1080;
            return true;
        }
        case 1080: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1081;
            return true;
        }
        case 1081: {
            pins = begin_fetch(pins);
            return true;
        }
        case 193: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1082;
            return true;
        }
        case 1082: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1083;
            return true;
        }
        case 1083: {
            step_ = 1084;
            return true;
        }
        case 1084: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1085;
            return true;
        }
        case 1085: {
            step_ = 1086;
            return true;
        }
        case 1086: {
            regs.c = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1087;
            return true;
        }
        case 1087: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1088;
            return true;
        }
        case 1088: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1089;
            return true;
        }
        case 1089: {
            step_ = 1090;
            return true;
        }
        case 1090: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1091;
            return true;
        }
        case 1091: {
            step_ = 1092;
            return true;
        }
        case 1092: {
            regs.b = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1093;
            return true;
        }
        case 1093: {
            pins = begin_fetch(pins);
            return true;
        }
        case 194: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1094;
            return true;
        }
        case 1094: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1095;
            return true;
        }
        case 1095: {
            step_ = 1096;
            return true;
        }
        case 1096: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1097;
            return true;
        }
        case 1097: {
            step_ = 1098;
            return true;
        }
        case 1098: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1099;
            return true;
        }
        case 1099: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1100;
            return true;
        }
        case 1100: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1101;
            return true;
        }
        case 1101: {
            step_ = 1102;
            return true;
        }
        case 1102: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1103;
            return true;
        }
        case 1103: {
            step_ = 1104;
            return true;
        }
        case 1104: {
            regs.set_wzh(get_data(pins));
            if ((regs.f & FLAG_Z) == 0) { regs.pc = regs.wz; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1105;
            return true;
        }
        case 1105: {
            pins = begin_fetch(pins);
            return true;
        }
        case 195: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1106;
            return true;
        }
        case 1106: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1107;
            return true;
        }
        case 1107: {
            step_ = 1108;
            return true;
        }
        case 1108: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1109;
            return true;
        }
        case 1109: {
            step_ = 1110;
            return true;
        }
        case 1110: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1111;
            return true;
        }
        case 1111: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1112;
            return true;
        }
        case 1112: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1113;
            return true;
        }
        case 1113: {
            step_ = 1114;
            return true;
        }
        case 1114: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1115;
            return true;
        }
        case 1115: {
            step_ = 1116;
            return true;
        }
        case 1116: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1117;
            return true;
        }
        case 1117: {
            pins = begin_fetch(pins);
            return true;
        }
        case 196: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1118;
            return true;
        }
        case 1118: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1119;
            return true;
        }
        case 1119: {
            step_ = 1120;
            return true;
        }
        case 1120: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1121;
            return true;
        }
        case 1121: {
            step_ = 1122;
            return true;
        }
        case 1122: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1123;
            return true;
        }
        case 1123: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1124;
            return true;
        }
        case 1124: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1125;
            return true;
        }
        case 1125: {
            step_ = 1126;
            return true;
        }
        case 1126: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1127;
            return true;
        }
        case 1127: {
            step_ = 1128;
            return true;
        }
        case 1128: {
            regs.set_wzh(get_data(pins));
            if (!((regs.f & FLAG_Z) == 0)) { pins = release_pins(pins, MREQ | RD); step_ = 1143; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1129;
            return true;
        }
        case 1129: {
            step_ = 1130;
            return true;
        }
        case 1130: {
            step_ = 1131;
            return true;
        }
        case 1131: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1132;
            return true;
        }
        case 1132: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1133;
            return true;
        }
        case 1133: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1134;
            return true;
        }
        case 1134: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1135;
            return true;
        }
        case 1135: {
            step_ = 1136;
            return true;
        }
        case 1136: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1137;
            return true;
        }
        case 1137: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1138;
            return true;
        }
        case 1138: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1139;
            return true;
        }
        case 1139: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1140;
            return true;
        }
        case 1140: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1141;
            return true;
        }
        case 1141: {
            step_ = 1142;
            return true;
        }
        case 1142: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1143;
            return true;
        }
        case 1143: {
            pins = begin_fetch(pins);
            return true;
        }
        case 197: {
            step_ = 1144;
            return true;
        }
        case 1144: {
            step_ = 1145;
            return true;
        }
        case 1145: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1146;
            return true;
        }
        case 1146: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1147;
            return true;
        }
        case 1147: {
            pins = set_data(pins, regs.b);
            step_ = 1148;
            return true;
        }
        case 1148: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1149;
            return true;
        }
        case 1149: {
            step_ = 1150;
            return true;
        }
        case 1150: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1151;
            return true;
        }
        case 1151: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1152;
            return true;
        }
        case 1152: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1153;
            return true;
        }
        case 1153: {
            pins = set_data(pins, regs.c);
            step_ = 1154;
            return true;
        }
        case 1154: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1155;
            return true;
        }
        case 1155: {
            step_ = 1156;
            return true;
        }
        case 1156: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1157;
            return true;
        }
        case 1157: {
            pins = begin_fetch(pins);
            return true;
        }
        case 198: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1158;
            return true;
        }
        case 1158: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1159;
            return true;
        }
        case 1159: {
            step_ = 1160;
            return true;
        }
        case 1160: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1161;
            return true;
        }
        case 1161: {
            step_ = 1162;
            return true;
        }
        case 1162: {
            dlatch_ = get_data(pins);
            alu_op(0, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1163;
            return true;
        }
        case 1163: {
            pins = begin_fetch(pins);
            return true;
        }
        case 199: {
            step_ = 1164;
            return true;
        }
        case 1164: {
            step_ = 1165;
            return true;
        }
        case 1165: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1166;
            return true;
        }
        case 1166: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1167;
            return true;
        }
        case 1167: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1168;
            return true;
        }
        case 1168: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1169;
            return true;
        }
        case 1169: {
            step_ = 1170;
            return true;
        }
        case 1170: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1171;
            return true;
        }
        case 1171: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1172;
            return true;
        }
        case 1172: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1173;
            return true;
        }
        case 1173: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1174;
            return true;
        }
        case 1174: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = 0; regs.pc = regs.wz;
            step_ = 1175;
            return true;
        }
        case 1175: {
            step_ = 1176;
            return true;
        }
        case 1176: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1177;
            return true;
        }
        case 1177: {
            pins = begin_fetch(pins);
            return true;
        }
        case 200: {
            step_ = 1178;
            return true;
        }
        case 1178: {
            if (!((regs.f & FLAG_Z) != 0)) { step_ = 1191; return true; }
            step_ = 1179;
            return true;
        }
        case 1179: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1180;
            return true;
        }
        case 1180: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1181;
            return true;
        }
        case 1181: {
            step_ = 1182;
            return true;
        }
        case 1182: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1183;
            return true;
        }
        case 1183: {
            step_ = 1184;
            return true;
        }
        case 1184: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1185;
            return true;
        }
        case 1185: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1186;
            return true;
        }
        case 1186: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1187;
            return true;
        }
        case 1187: {
            step_ = 1188;
            return true;
        }
        case 1188: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1189;
            return true;
        }
        case 1189: {
            step_ = 1190;
            return true;
        }
        case 1190: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1191;
            return true;
        }
        case 1191: {
            pins = begin_fetch(pins);
            return true;
        }
        case 201: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1192;
            return true;
        }
        case 1192: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1193;
            return true;
        }
        case 1193: {
            step_ = 1194;
            return true;
        }
        case 1194: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1195;
            return true;
        }
        case 1195: {
            step_ = 1196;
            return true;
        }
        case 1196: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1197;
            return true;
        }
        case 1197: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1198;
            return true;
        }
        case 1198: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1199;
            return true;
        }
        case 1199: {
            step_ = 1200;
            return true;
        }
        case 1200: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1201;
            return true;
        }
        case 1201: {
            step_ = 1202;
            return true;
        }
        case 1202: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1203;
            return true;
        }
        case 1203: {
            pins = begin_fetch(pins);
            return true;
        }
        case 202: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1204;
            return true;
        }
        case 1204: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1205;
            return true;
        }
        case 1205: {
            step_ = 1206;
            return true;
        }
        case 1206: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1207;
            return true;
        }
        case 1207: {
            step_ = 1208;
            return true;
        }
        case 1208: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1209;
            return true;
        }
        case 1209: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1210;
            return true;
        }
        case 1210: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1211;
            return true;
        }
        case 1211: {
            step_ = 1212;
            return true;
        }
        case 1212: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1213;
            return true;
        }
        case 1213: {
            step_ = 1214;
            return true;
        }
        case 1214: {
            regs.set_wzh(get_data(pins));
            if ((regs.f & FLAG_Z) != 0) { regs.pc = regs.wz; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1215;
            return true;
        }
        case 1215: {
            pins = begin_fetch(pins);
            return true;
        }
        case 204: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1216;
            return true;
        }
        case 1216: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1217;
            return true;
        }
        case 1217: {
            step_ = 1218;
            return true;
        }
        case 1218: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1219;
            return true;
        }
        case 1219: {
            step_ = 1220;
            return true;
        }
        case 1220: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1221;
            return true;
        }
        case 1221: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1222;
            return true;
        }
        case 1222: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1223;
            return true;
        }
        case 1223: {
            step_ = 1224;
            return true;
        }
        case 1224: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1225;
            return true;
        }
        case 1225: {
            step_ = 1226;
            return true;
        }
        case 1226: {
            regs.set_wzh(get_data(pins));
            if (!((regs.f & FLAG_Z) != 0)) { pins = release_pins(pins, MREQ | RD); step_ = 1241; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1227;
            return true;
        }
        case 1227: {
            step_ = 1228;
            return true;
        }
        case 1228: {
            step_ = 1229;
            return true;
        }
        case 1229: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1230;
            return true;
        }
        case 1230: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1231;
            return true;
        }
        case 1231: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1232;
            return true;
        }
        case 1232: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1233;
            return true;
        }
        case 1233: {
            step_ = 1234;
            return true;
        }
        case 1234: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1235;
            return true;
        }
        case 1235: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1236;
            return true;
        }
        case 1236: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1237;
            return true;
        }
        case 1237: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1238;
            return true;
        }
        case 1238: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1239;
            return true;
        }
        case 1239: {
            step_ = 1240;
            return true;
        }
        case 1240: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1241;
            return true;
        }
        case 1241: {
            pins = begin_fetch(pins);
            return true;
        }
        case 205: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1242;
            return true;
        }
        case 1242: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1243;
            return true;
        }
        case 1243: {
            step_ = 1244;
            return true;
        }
        case 1244: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1245;
            return true;
        }
        case 1245: {
            step_ = 1246;
            return true;
        }
        case 1246: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1247;
            return true;
        }
        case 1247: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1248;
            return true;
        }
        case 1248: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1249;
            return true;
        }
        case 1249: {
            step_ = 1250;
            return true;
        }
        case 1250: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1251;
            return true;
        }
        case 1251: {
            step_ = 1252;
            return true;
        }
        case 1252: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1253;
            return true;
        }
        case 1253: {
            step_ = 1254;
            return true;
        }
        case 1254: {
            step_ = 1255;
            return true;
        }
        case 1255: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1256;
            return true;
        }
        case 1256: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1257;
            return true;
        }
        case 1257: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1258;
            return true;
        }
        case 1258: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1259;
            return true;
        }
        case 1259: {
            step_ = 1260;
            return true;
        }
        case 1260: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1261;
            return true;
        }
        case 1261: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1262;
            return true;
        }
        case 1262: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1263;
            return true;
        }
        case 1263: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1264;
            return true;
        }
        case 1264: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1265;
            return true;
        }
        case 1265: {
            step_ = 1266;
            return true;
        }
        case 1266: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1267;
            return true;
        }
        case 1267: {
            pins = begin_fetch(pins);
            return true;
        }
        case 206: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1268;
            return true;
        }
        case 1268: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1269;
            return true;
        }
        case 1269: {
            step_ = 1270;
            return true;
        }
        case 1270: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1271;
            return true;
        }
        case 1271: {
            step_ = 1272;
            return true;
        }
        case 1272: {
            dlatch_ = get_data(pins);
            alu_op(1, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1273;
            return true;
        }
        case 1273: {
            pins = begin_fetch(pins);
            return true;
        }
        case 207: {
            step_ = 1274;
            return true;
        }
        case 1274: {
            step_ = 1275;
            return true;
        }
        case 1275: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1276;
            return true;
        }
        case 1276: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1277;
            return true;
        }
        case 1277: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1278;
            return true;
        }
        case 1278: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1279;
            return true;
        }
        case 1279: {
            step_ = 1280;
            return true;
        }
        case 1280: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1281;
            return true;
        }
        case 1281: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1282;
            return true;
        }
        case 1282: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1283;
            return true;
        }
        case 1283: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1284;
            return true;
        }
        case 1284: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = 8; regs.pc = regs.wz;
            step_ = 1285;
            return true;
        }
        case 1285: {
            step_ = 1286;
            return true;
        }
        case 1286: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1287;
            return true;
        }
        case 1287: {
            pins = begin_fetch(pins);
            return true;
        }
        case 208: {
            step_ = 1288;
            return true;
        }
        case 1288: {
            if (!((regs.f & FLAG_C) == 0)) { step_ = 1301; return true; }
            step_ = 1289;
            return true;
        }
        case 1289: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1290;
            return true;
        }
        case 1290: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1291;
            return true;
        }
        case 1291: {
            step_ = 1292;
            return true;
        }
        case 1292: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1293;
            return true;
        }
        case 1293: {
            step_ = 1294;
            return true;
        }
        case 1294: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1295;
            return true;
        }
        case 1295: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1296;
            return true;
        }
        case 1296: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1297;
            return true;
        }
        case 1297: {
            step_ = 1298;
            return true;
        }
        case 1298: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1299;
            return true;
        }
        case 1299: {
            step_ = 1300;
            return true;
        }
        case 1300: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1301;
            return true;
        }
        case 1301: {
            pins = begin_fetch(pins);
            return true;
        }
        case 209: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1302;
            return true;
        }
        case 1302: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1303;
            return true;
        }
        case 1303: {
            step_ = 1304;
            return true;
        }
        case 1304: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1305;
            return true;
        }
        case 1305: {
            step_ = 1306;
            return true;
        }
        case 1306: {
            regs.e = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1307;
            return true;
        }
        case 1307: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1308;
            return true;
        }
        case 1308: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1309;
            return true;
        }
        case 1309: {
            step_ = 1310;
            return true;
        }
        case 1310: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1311;
            return true;
        }
        case 1311: {
            step_ = 1312;
            return true;
        }
        case 1312: {
            regs.d = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1313;
            return true;
        }
        case 1313: {
            pins = begin_fetch(pins);
            return true;
        }
        case 210: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1314;
            return true;
        }
        case 1314: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1315;
            return true;
        }
        case 1315: {
            step_ = 1316;
            return true;
        }
        case 1316: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1317;
            return true;
        }
        case 1317: {
            step_ = 1318;
            return true;
        }
        case 1318: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1319;
            return true;
        }
        case 1319: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1320;
            return true;
        }
        case 1320: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1321;
            return true;
        }
        case 1321: {
            step_ = 1322;
            return true;
        }
        case 1322: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1323;
            return true;
        }
        case 1323: {
            step_ = 1324;
            return true;
        }
        case 1324: {
            regs.set_wzh(get_data(pins));
            if ((regs.f & FLAG_C) == 0) { regs.pc = regs.wz; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1325;
            return true;
        }
        case 1325: {
            pins = begin_fetch(pins);
            return true;
        }
        case 211: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1326;
            return true;
        }
        case 1326: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1327;
            return true;
        }
        case 1327: {
            step_ = 1328;
            return true;
        }
        case 1328: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1329;
            return true;
        }
        case 1329: {
            step_ = 1330;
            return true;
        }
        case 1330: {
            regs.set_wzl(get_data(pins));
            regs.set_wzh(regs.a);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1331;
            return true;
        }
        case 1331: {
            pins = set_addr(pins, regs.wz);
            step_ = 1332;
            return true;
        }
        case 1332: {
            step_ = 1333;
            return true;
        }
        case 1333: {
            pins = set_addr_data_assert(pins, get_addr(pins), regs.a, IORQ | WR);
            step_ = 1334;
            return true;
        }
        case 1334: {
            step_ = 1335;
            return true;
        }
        case 1335: {
            step_ = 1336;
            return true;
        }
        case 1336: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1337;
            return true;
        }
        case 1337: {
            step_ = 1338;
            return true;
        }
        case 1338: {
            regs.set_wzl(uint8_t(regs.wzl() + 1));
            pins = release_pins(pins, IORQ | WR);
            step_ = 1339;
            return true;
        }
        case 1339: {
            pins = begin_fetch(pins);
            return true;
        }
        case 212: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1340;
            return true;
        }
        case 1340: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1341;
            return true;
        }
        case 1341: {
            step_ = 1342;
            return true;
        }
        case 1342: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1343;
            return true;
        }
        case 1343: {
            step_ = 1344;
            return true;
        }
        case 1344: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1345;
            return true;
        }
        case 1345: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1346;
            return true;
        }
        case 1346: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1347;
            return true;
        }
        case 1347: {
            step_ = 1348;
            return true;
        }
        case 1348: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1349;
            return true;
        }
        case 1349: {
            step_ = 1350;
            return true;
        }
        case 1350: {
            regs.set_wzh(get_data(pins));
            if (!((regs.f & FLAG_C) == 0)) { pins = release_pins(pins, MREQ | RD); step_ = 1365; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1351;
            return true;
        }
        case 1351: {
            step_ = 1352;
            return true;
        }
        case 1352: {
            step_ = 1353;
            return true;
        }
        case 1353: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1354;
            return true;
        }
        case 1354: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1355;
            return true;
        }
        case 1355: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1356;
            return true;
        }
        case 1356: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1357;
            return true;
        }
        case 1357: {
            step_ = 1358;
            return true;
        }
        case 1358: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1359;
            return true;
        }
        case 1359: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1360;
            return true;
        }
        case 1360: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1361;
            return true;
        }
        case 1361: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1362;
            return true;
        }
        case 1362: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1363;
            return true;
        }
        case 1363: {
            step_ = 1364;
            return true;
        }
        case 1364: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1365;
            return true;
        }
        case 1365: {
            pins = begin_fetch(pins);
            return true;
        }
        case 213: {
            step_ = 1366;
            return true;
        }
        case 1366: {
            step_ = 1367;
            return true;
        }
        case 1367: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1368;
            return true;
        }
        case 1368: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1369;
            return true;
        }
        case 1369: {
            pins = set_data(pins, regs.d);
            step_ = 1370;
            return true;
        }
        case 1370: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1371;
            return true;
        }
        case 1371: {
            step_ = 1372;
            return true;
        }
        case 1372: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1373;
            return true;
        }
        case 1373: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1374;
            return true;
        }
        case 1374: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1375;
            return true;
        }
        case 1375: {
            pins = set_data(pins, regs.e);
            step_ = 1376;
            return true;
        }
        case 1376: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1377;
            return true;
        }
        case 1377: {
            step_ = 1378;
            return true;
        }
        case 1378: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1379;
            return true;
        }
        case 1379: {
            pins = begin_fetch(pins);
            return true;
        }
        case 214: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1380;
            return true;
        }
        case 1380: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1381;
            return true;
        }
        case 1381: {
            step_ = 1382;
            return true;
        }
        case 1382: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1383;
            return true;
        }
        case 1383: {
            step_ = 1384;
            return true;
        }
        case 1384: {
            dlatch_ = get_data(pins);
            alu_op(2, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1385;
            return true;
        }
        case 1385: {
            pins = begin_fetch(pins);
            return true;
        }
        case 215: {
            step_ = 1386;
            return true;
        }
        case 1386: {
            step_ = 1387;
            return true;
        }
        case 1387: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1388;
            return true;
        }
        case 1388: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1389;
            return true;
        }
        case 1389: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1390;
            return true;
        }
        case 1390: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1391;
            return true;
        }
        case 1391: {
            step_ = 1392;
            return true;
        }
        case 1392: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1393;
            return true;
        }
        case 1393: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1394;
            return true;
        }
        case 1394: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1395;
            return true;
        }
        case 1395: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1396;
            return true;
        }
        case 1396: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = 16; regs.pc = regs.wz;
            step_ = 1397;
            return true;
        }
        case 1397: {
            step_ = 1398;
            return true;
        }
        case 1398: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1399;
            return true;
        }
        case 1399: {
            pins = begin_fetch(pins);
            return true;
        }
        case 216: {
            step_ = 1400;
            return true;
        }
        case 1400: {
            if (!((regs.f & FLAG_C) != 0)) { step_ = 1413; return true; }
            step_ = 1401;
            return true;
        }
        case 1401: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1402;
            return true;
        }
        case 1402: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1403;
            return true;
        }
        case 1403: {
            step_ = 1404;
            return true;
        }
        case 1404: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1405;
            return true;
        }
        case 1405: {
            step_ = 1406;
            return true;
        }
        case 1406: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1407;
            return true;
        }
        case 1407: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1408;
            return true;
        }
        case 1408: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1409;
            return true;
        }
        case 1409: {
            step_ = 1410;
            return true;
        }
        case 1410: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1411;
            return true;
        }
        case 1411: {
            step_ = 1412;
            return true;
        }
        case 1412: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1413;
            return true;
        }
        case 1413: {
            pins = begin_fetch(pins);
            return true;
        }
        case 217: {
            std::swap(regs.b, regs.b_); std::swap(regs.c, regs.c_); std::swap(regs.d, regs.d_); std::swap(regs.e, regs.e_); std::swap(regs.h, regs.h_); std::swap(regs.l, regs.l_);
            pins = begin_fetch(pins);
            return true;
        }
        case 218: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1414;
            return true;
        }
        case 1414: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1415;
            return true;
        }
        case 1415: {
            step_ = 1416;
            return true;
        }
        case 1416: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1417;
            return true;
        }
        case 1417: {
            step_ = 1418;
            return true;
        }
        case 1418: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1419;
            return true;
        }
        case 1419: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1420;
            return true;
        }
        case 1420: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1421;
            return true;
        }
        case 1421: {
            step_ = 1422;
            return true;
        }
        case 1422: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1423;
            return true;
        }
        case 1423: {
            step_ = 1424;
            return true;
        }
        case 1424: {
            regs.set_wzh(get_data(pins));
            if ((regs.f & FLAG_C) != 0) { regs.pc = regs.wz; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1425;
            return true;
        }
        case 1425: {
            pins = begin_fetch(pins);
            return true;
        }
        case 219: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1426;
            return true;
        }
        case 1426: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1427;
            return true;
        }
        case 1427: {
            step_ = 1428;
            return true;
        }
        case 1428: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1429;
            return true;
        }
        case 1429: {
            step_ = 1430;
            return true;
        }
        case 1430: {
            regs.set_wzl(get_data(pins));
            regs.set_wzh(regs.a);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1431;
            return true;
        }
        case 1431: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 1432;
            return true;
        }
        case 1432: {
            step_ = 1433;
            return true;
        }
        case 1433: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 1434;
            return true;
        }
        case 1434: {
            step_ = 1435;
            return true;
        }
        case 1435: {
            step_ = 1436;
            return true;
        }
        case 1436: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1437;
            return true;
        }
        case 1437: {
            step_ = 1438;
            return true;
        }
        case 1438: {
            regs.a = get_data(pins);
            pins = release_pins(pins, IORQ | RD);
            step_ = 1439;
            return true;
        }
        case 1439: {
            pins = begin_fetch(pins);
            return true;
        }
        case 220: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1440;
            return true;
        }
        case 1440: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1441;
            return true;
        }
        case 1441: {
            step_ = 1442;
            return true;
        }
        case 1442: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1443;
            return true;
        }
        case 1443: {
            step_ = 1444;
            return true;
        }
        case 1444: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1445;
            return true;
        }
        case 1445: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1446;
            return true;
        }
        case 1446: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1447;
            return true;
        }
        case 1447: {
            step_ = 1448;
            return true;
        }
        case 1448: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1449;
            return true;
        }
        case 1449: {
            step_ = 1450;
            return true;
        }
        case 1450: {
            regs.set_wzh(get_data(pins));
            if (!((regs.f & FLAG_C) != 0)) { pins = release_pins(pins, MREQ | RD); step_ = 1465; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1451;
            return true;
        }
        case 1451: {
            step_ = 1452;
            return true;
        }
        case 1452: {
            step_ = 1453;
            return true;
        }
        case 1453: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1454;
            return true;
        }
        case 1454: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1455;
            return true;
        }
        case 1455: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1456;
            return true;
        }
        case 1456: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1457;
            return true;
        }
        case 1457: {
            step_ = 1458;
            return true;
        }
        case 1458: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1459;
            return true;
        }
        case 1459: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1460;
            return true;
        }
        case 1460: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1461;
            return true;
        }
        case 1461: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1462;
            return true;
        }
        case 1462: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1463;
            return true;
        }
        case 1463: {
            step_ = 1464;
            return true;
        }
        case 1464: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1465;
            return true;
        }
        case 1465: {
            pins = begin_fetch(pins);
            return true;
        }
        case 222: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1466;
            return true;
        }
        case 1466: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1467;
            return true;
        }
        case 1467: {
            step_ = 1468;
            return true;
        }
        case 1468: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1469;
            return true;
        }
        case 1469: {
            step_ = 1470;
            return true;
        }
        case 1470: {
            dlatch_ = get_data(pins);
            alu_op(3, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1471;
            return true;
        }
        case 1471: {
            pins = begin_fetch(pins);
            return true;
        }
        case 223: {
            step_ = 1472;
            return true;
        }
        case 1472: {
            step_ = 1473;
            return true;
        }
        case 1473: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1474;
            return true;
        }
        case 1474: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1475;
            return true;
        }
        case 1475: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1476;
            return true;
        }
        case 1476: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1477;
            return true;
        }
        case 1477: {
            step_ = 1478;
            return true;
        }
        case 1478: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1479;
            return true;
        }
        case 1479: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1480;
            return true;
        }
        case 1480: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1481;
            return true;
        }
        case 1481: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1482;
            return true;
        }
        case 1482: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = 24; regs.pc = regs.wz;
            step_ = 1483;
            return true;
        }
        case 1483: {
            step_ = 1484;
            return true;
        }
        case 1484: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1485;
            return true;
        }
        case 1485: {
            pins = begin_fetch(pins);
            return true;
        }
        case 224: {
            step_ = 1486;
            return true;
        }
        case 1486: {
            if (!((regs.f & FLAG_PV) == 0)) { step_ = 1499; return true; }
            step_ = 1487;
            return true;
        }
        case 1487: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1488;
            return true;
        }
        case 1488: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1489;
            return true;
        }
        case 1489: {
            step_ = 1490;
            return true;
        }
        case 1490: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1491;
            return true;
        }
        case 1491: {
            step_ = 1492;
            return true;
        }
        case 1492: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1493;
            return true;
        }
        case 1493: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1494;
            return true;
        }
        case 1494: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1495;
            return true;
        }
        case 1495: {
            step_ = 1496;
            return true;
        }
        case 1496: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1497;
            return true;
        }
        case 1497: {
            step_ = 1498;
            return true;
        }
        case 1498: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1499;
            return true;
        }
        case 1499: {
            pins = begin_fetch(pins);
            return true;
        }
        case 225: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1500;
            return true;
        }
        case 1500: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1501;
            return true;
        }
        case 1501: {
            step_ = 1502;
            return true;
        }
        case 1502: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1503;
            return true;
        }
        case 1503: {
            step_ = 1504;
            return true;
        }
        case 1504: {
            set_hlx_l(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1505;
            return true;
        }
        case 1505: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1506;
            return true;
        }
        case 1506: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1507;
            return true;
        }
        case 1507: {
            step_ = 1508;
            return true;
        }
        case 1508: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1509;
            return true;
        }
        case 1509: {
            step_ = 1510;
            return true;
        }
        case 1510: {
            set_hlx_h(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1511;
            return true;
        }
        case 1511: {
            pins = begin_fetch(pins);
            return true;
        }
        case 226: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1512;
            return true;
        }
        case 1512: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1513;
            return true;
        }
        case 1513: {
            step_ = 1514;
            return true;
        }
        case 1514: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1515;
            return true;
        }
        case 1515: {
            step_ = 1516;
            return true;
        }
        case 1516: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1517;
            return true;
        }
        case 1517: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1518;
            return true;
        }
        case 1518: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1519;
            return true;
        }
        case 1519: {
            step_ = 1520;
            return true;
        }
        case 1520: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1521;
            return true;
        }
        case 1521: {
            step_ = 1522;
            return true;
        }
        case 1522: {
            regs.set_wzh(get_data(pins));
            if ((regs.f & FLAG_PV) == 0) { regs.pc = regs.wz; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1523;
            return true;
        }
        case 1523: {
            pins = begin_fetch(pins);
            return true;
        }
        case 227: {
            pins = set_addr(pins, regs.sp);
            step_ = 1524;
            return true;
        }
        case 1524: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1525;
            return true;
        }
        case 1525: {
            step_ = 1526;
            return true;
        }
        case 1526: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1527;
            return true;
        }
        case 1527: {
            step_ = 1528;
            return true;
        }
        case 1528: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1529;
            return true;
        }
        case 1529: {
            pins = set_addr(pins, uint16_t(regs.sp + 1));
            step_ = 1530;
            return true;
        }
        case 1530: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1531;
            return true;
        }
        case 1531: {
            step_ = 1532;
            return true;
        }
        case 1532: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1533;
            return true;
        }
        case 1533: {
            step_ = 1534;
            return true;
        }
        case 1534: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1535;
            return true;
        }
        case 1535: {
            step_ = 1536;
            return true;
        }
        case 1536: {
            step_ = 1537;
            return true;
        }
        case 1537: {
            pins = set_addr(pins, uint16_t(regs.sp + 1));
            step_ = 1538;
            return true;
        }
        case 1538: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1539;
            return true;
        }
        case 1539: {
            pins = set_data(pins, hlx_h());
            step_ = 1540;
            return true;
        }
        case 1540: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1541;
            return true;
        }
        case 1541: {
            step_ = 1542;
            return true;
        }
        case 1542: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1543;
            return true;
        }
        case 1543: {
            pins = set_addr(pins, regs.sp);
            step_ = 1544;
            return true;
        }
        case 1544: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1545;
            return true;
        }
        case 1545: {
            pins = set_data(pins, hlx_l());
            step_ = 1546;
            return true;
        }
        case 1546: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            set_hlx(regs.wz);
            step_ = 1547;
            return true;
        }
        case 1547: {
            step_ = 1548;
            return true;
        }
        case 1548: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1549;
            return true;
        }
        case 1549: {
            step_ = 1550;
            return true;
        }
        case 1550: {
            step_ = 1551;
            return true;
        }
        case 1551: {
            step_ = 1552;
            return true;
        }
        case 1552: {
            step_ = 1553;
            return true;
        }
        case 1553: {
            pins = begin_fetch(pins);
            return true;
        }
        case 228: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1554;
            return true;
        }
        case 1554: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1555;
            return true;
        }
        case 1555: {
            step_ = 1556;
            return true;
        }
        case 1556: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1557;
            return true;
        }
        case 1557: {
            step_ = 1558;
            return true;
        }
        case 1558: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1559;
            return true;
        }
        case 1559: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1560;
            return true;
        }
        case 1560: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1561;
            return true;
        }
        case 1561: {
            step_ = 1562;
            return true;
        }
        case 1562: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1563;
            return true;
        }
        case 1563: {
            step_ = 1564;
            return true;
        }
        case 1564: {
            regs.set_wzh(get_data(pins));
            if (!((regs.f & FLAG_PV) == 0)) { pins = release_pins(pins, MREQ | RD); step_ = 1579; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1565;
            return true;
        }
        case 1565: {
            step_ = 1566;
            return true;
        }
        case 1566: {
            step_ = 1567;
            return true;
        }
        case 1567: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1568;
            return true;
        }
        case 1568: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1569;
            return true;
        }
        case 1569: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1570;
            return true;
        }
        case 1570: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1571;
            return true;
        }
        case 1571: {
            step_ = 1572;
            return true;
        }
        case 1572: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1573;
            return true;
        }
        case 1573: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1574;
            return true;
        }
        case 1574: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1575;
            return true;
        }
        case 1575: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1576;
            return true;
        }
        case 1576: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1577;
            return true;
        }
        case 1577: {
            step_ = 1578;
            return true;
        }
        case 1578: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1579;
            return true;
        }
        case 1579: {
            pins = begin_fetch(pins);
            return true;
        }
        case 229: {
            step_ = 1580;
            return true;
        }
        case 1580: {
            step_ = 1581;
            return true;
        }
        case 1581: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1582;
            return true;
        }
        case 1582: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1583;
            return true;
        }
        case 1583: {
            pins = set_data(pins, hlx_h());
            step_ = 1584;
            return true;
        }
        case 1584: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1585;
            return true;
        }
        case 1585: {
            step_ = 1586;
            return true;
        }
        case 1586: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1587;
            return true;
        }
        case 1587: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1588;
            return true;
        }
        case 1588: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1589;
            return true;
        }
        case 1589: {
            pins = set_data(pins, hlx_l());
            step_ = 1590;
            return true;
        }
        case 1590: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1591;
            return true;
        }
        case 1591: {
            step_ = 1592;
            return true;
        }
        case 1592: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1593;
            return true;
        }
        case 1593: {
            pins = begin_fetch(pins);
            return true;
        }
        case 230: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1594;
            return true;
        }
        case 1594: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1595;
            return true;
        }
        case 1595: {
            step_ = 1596;
            return true;
        }
        case 1596: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1597;
            return true;
        }
        case 1597: {
            step_ = 1598;
            return true;
        }
        case 1598: {
            dlatch_ = get_data(pins);
            alu_op(4, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1599;
            return true;
        }
        case 1599: {
            pins = begin_fetch(pins);
            return true;
        }
        case 231: {
            step_ = 1600;
            return true;
        }
        case 1600: {
            step_ = 1601;
            return true;
        }
        case 1601: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1602;
            return true;
        }
        case 1602: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1603;
            return true;
        }
        case 1603: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1604;
            return true;
        }
        case 1604: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1605;
            return true;
        }
        case 1605: {
            step_ = 1606;
            return true;
        }
        case 1606: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1607;
            return true;
        }
        case 1607: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1608;
            return true;
        }
        case 1608: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1609;
            return true;
        }
        case 1609: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1610;
            return true;
        }
        case 1610: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = 32; regs.pc = regs.wz;
            step_ = 1611;
            return true;
        }
        case 1611: {
            step_ = 1612;
            return true;
        }
        case 1612: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1613;
            return true;
        }
        case 1613: {
            pins = begin_fetch(pins);
            return true;
        }
        case 232: {
            step_ = 1614;
            return true;
        }
        case 1614: {
            if (!((regs.f & FLAG_PV) != 0)) { step_ = 1627; return true; }
            step_ = 1615;
            return true;
        }
        case 1615: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1616;
            return true;
        }
        case 1616: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1617;
            return true;
        }
        case 1617: {
            step_ = 1618;
            return true;
        }
        case 1618: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1619;
            return true;
        }
        case 1619: {
            step_ = 1620;
            return true;
        }
        case 1620: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1621;
            return true;
        }
        case 1621: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1622;
            return true;
        }
        case 1622: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1623;
            return true;
        }
        case 1623: {
            step_ = 1624;
            return true;
        }
        case 1624: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1625;
            return true;
        }
        case 1625: {
            step_ = 1626;
            return true;
        }
        case 1626: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1627;
            return true;
        }
        case 1627: {
            pins = begin_fetch(pins);
            return true;
        }
        case 233: {
            regs.pc = hlx();
            pins = begin_fetch(pins);
            return true;
        }
        case 234: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1628;
            return true;
        }
        case 1628: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1629;
            return true;
        }
        case 1629: {
            step_ = 1630;
            return true;
        }
        case 1630: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1631;
            return true;
        }
        case 1631: {
            step_ = 1632;
            return true;
        }
        case 1632: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1633;
            return true;
        }
        case 1633: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1634;
            return true;
        }
        case 1634: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1635;
            return true;
        }
        case 1635: {
            step_ = 1636;
            return true;
        }
        case 1636: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1637;
            return true;
        }
        case 1637: {
            step_ = 1638;
            return true;
        }
        case 1638: {
            regs.set_wzh(get_data(pins));
            if ((regs.f & FLAG_PV) != 0) { regs.pc = regs.wz; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1639;
            return true;
        }
        case 1639: {
            pins = begin_fetch(pins);
            return true;
        }
        case 235: {
            uint16_t de = regs.de(); regs.set_de(regs.hl()); regs.set_hl(de);
            pins = begin_fetch(pins);
            return true;
        }
        case 236: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1640;
            return true;
        }
        case 1640: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1641;
            return true;
        }
        case 1641: {
            step_ = 1642;
            return true;
        }
        case 1642: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1643;
            return true;
        }
        case 1643: {
            step_ = 1644;
            return true;
        }
        case 1644: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1645;
            return true;
        }
        case 1645: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1646;
            return true;
        }
        case 1646: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1647;
            return true;
        }
        case 1647: {
            step_ = 1648;
            return true;
        }
        case 1648: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1649;
            return true;
        }
        case 1649: {
            step_ = 1650;
            return true;
        }
        case 1650: {
            regs.set_wzh(get_data(pins));
            if (!((regs.f & FLAG_PV) != 0)) { pins = release_pins(pins, MREQ | RD); step_ = 1665; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1651;
            return true;
        }
        case 1651: {
            step_ = 1652;
            return true;
        }
        case 1652: {
            step_ = 1653;
            return true;
        }
        case 1653: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1654;
            return true;
        }
        case 1654: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1655;
            return true;
        }
        case 1655: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1656;
            return true;
        }
        case 1656: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1657;
            return true;
        }
        case 1657: {
            step_ = 1658;
            return true;
        }
        case 1658: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1659;
            return true;
        }
        case 1659: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1660;
            return true;
        }
        case 1660: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1661;
            return true;
        }
        case 1661: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1662;
            return true;
        }
        case 1662: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1663;
            return true;
        }
        case 1663: {
            step_ = 1664;
            return true;
        }
        case 1664: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1665;
            return true;
        }
        case 1665: {
            pins = begin_fetch(pins);
            return true;
        }
        case 237: {
            pins = begin_fetch_ed(pins);
            return true;
        }
        case 238: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1666;
            return true;
        }
        case 1666: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1667;
            return true;
        }
        case 1667: {
            step_ = 1668;
            return true;
        }
        case 1668: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1669;
            return true;
        }
        case 1669: {
            step_ = 1670;
            return true;
        }
        case 1670: {
            dlatch_ = get_data(pins);
            alu_op(5, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1671;
            return true;
        }
        case 1671: {
            pins = begin_fetch(pins);
            return true;
        }
        case 239: {
            step_ = 1672;
            return true;
        }
        case 1672: {
            step_ = 1673;
            return true;
        }
        case 1673: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1674;
            return true;
        }
        case 1674: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1675;
            return true;
        }
        case 1675: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1676;
            return true;
        }
        case 1676: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1677;
            return true;
        }
        case 1677: {
            step_ = 1678;
            return true;
        }
        case 1678: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1679;
            return true;
        }
        case 1679: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1680;
            return true;
        }
        case 1680: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1681;
            return true;
        }
        case 1681: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1682;
            return true;
        }
        case 1682: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = 40; regs.pc = regs.wz;
            step_ = 1683;
            return true;
        }
        case 1683: {
            step_ = 1684;
            return true;
        }
        case 1684: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1685;
            return true;
        }
        case 1685: {
            pins = begin_fetch(pins);
            return true;
        }
        case 240: {
            step_ = 1686;
            return true;
        }
        case 1686: {
            if (!((regs.f & FLAG_S) == 0)) { step_ = 1699; return true; }
            step_ = 1687;
            return true;
        }
        case 1687: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1688;
            return true;
        }
        case 1688: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1689;
            return true;
        }
        case 1689: {
            step_ = 1690;
            return true;
        }
        case 1690: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1691;
            return true;
        }
        case 1691: {
            step_ = 1692;
            return true;
        }
        case 1692: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1693;
            return true;
        }
        case 1693: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1694;
            return true;
        }
        case 1694: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1695;
            return true;
        }
        case 1695: {
            step_ = 1696;
            return true;
        }
        case 1696: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1697;
            return true;
        }
        case 1697: {
            step_ = 1698;
            return true;
        }
        case 1698: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1699;
            return true;
        }
        case 1699: {
            pins = begin_fetch(pins);
            return true;
        }
        case 241: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1700;
            return true;
        }
        case 1700: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1701;
            return true;
        }
        case 1701: {
            step_ = 1702;
            return true;
        }
        case 1702: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1703;
            return true;
        }
        case 1703: {
            step_ = 1704;
            return true;
        }
        case 1704: {
            regs.f = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1705;
            return true;
        }
        case 1705: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1706;
            return true;
        }
        case 1706: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1707;
            return true;
        }
        case 1707: {
            step_ = 1708;
            return true;
        }
        case 1708: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1709;
            return true;
        }
        case 1709: {
            step_ = 1710;
            return true;
        }
        case 1710: {
            regs.a = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1711;
            return true;
        }
        case 1711: {
            pins = begin_fetch(pins);
            return true;
        }
        case 242: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1712;
            return true;
        }
        case 1712: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1713;
            return true;
        }
        case 1713: {
            step_ = 1714;
            return true;
        }
        case 1714: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1715;
            return true;
        }
        case 1715: {
            step_ = 1716;
            return true;
        }
        case 1716: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1717;
            return true;
        }
        case 1717: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1718;
            return true;
        }
        case 1718: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1719;
            return true;
        }
        case 1719: {
            step_ = 1720;
            return true;
        }
        case 1720: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1721;
            return true;
        }
        case 1721: {
            step_ = 1722;
            return true;
        }
        case 1722: {
            regs.set_wzh(get_data(pins));
            if ((regs.f & FLAG_S) == 0) { regs.pc = regs.wz; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1723;
            return true;
        }
        case 1723: {
            pins = begin_fetch(pins);
            return true;
        }
        case 243: {
            regs.iff1 = false; regs.iff2 = false;
            pins = begin_fetch(pins);
            return true;
        }
        case 244: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1724;
            return true;
        }
        case 1724: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1725;
            return true;
        }
        case 1725: {
            step_ = 1726;
            return true;
        }
        case 1726: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1727;
            return true;
        }
        case 1727: {
            step_ = 1728;
            return true;
        }
        case 1728: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1729;
            return true;
        }
        case 1729: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1730;
            return true;
        }
        case 1730: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1731;
            return true;
        }
        case 1731: {
            step_ = 1732;
            return true;
        }
        case 1732: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1733;
            return true;
        }
        case 1733: {
            step_ = 1734;
            return true;
        }
        case 1734: {
            regs.set_wzh(get_data(pins));
            if (!((regs.f & FLAG_S) == 0)) { pins = release_pins(pins, MREQ | RD); step_ = 1749; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1735;
            return true;
        }
        case 1735: {
            step_ = 1736;
            return true;
        }
        case 1736: {
            step_ = 1737;
            return true;
        }
        case 1737: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1738;
            return true;
        }
        case 1738: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1739;
            return true;
        }
        case 1739: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1740;
            return true;
        }
        case 1740: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1741;
            return true;
        }
        case 1741: {
            step_ = 1742;
            return true;
        }
        case 1742: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1743;
            return true;
        }
        case 1743: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1744;
            return true;
        }
        case 1744: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1745;
            return true;
        }
        case 1745: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1746;
            return true;
        }
        case 1746: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1747;
            return true;
        }
        case 1747: {
            step_ = 1748;
            return true;
        }
        case 1748: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1749;
            return true;
        }
        case 1749: {
            pins = begin_fetch(pins);
            return true;
        }
        case 245: {
            step_ = 1750;
            return true;
        }
        case 1750: {
            step_ = 1751;
            return true;
        }
        case 1751: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1752;
            return true;
        }
        case 1752: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1753;
            return true;
        }
        case 1753: {
            pins = set_data(pins, regs.a);
            step_ = 1754;
            return true;
        }
        case 1754: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1755;
            return true;
        }
        case 1755: {
            step_ = 1756;
            return true;
        }
        case 1756: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1757;
            return true;
        }
        case 1757: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1758;
            return true;
        }
        case 1758: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1759;
            return true;
        }
        case 1759: {
            pins = set_data(pins, regs.f);
            step_ = 1760;
            return true;
        }
        case 1760: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1761;
            return true;
        }
        case 1761: {
            step_ = 1762;
            return true;
        }
        case 1762: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1763;
            return true;
        }
        case 1763: {
            pins = begin_fetch(pins);
            return true;
        }
        case 246: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1764;
            return true;
        }
        case 1764: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1765;
            return true;
        }
        case 1765: {
            step_ = 1766;
            return true;
        }
        case 1766: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1767;
            return true;
        }
        case 1767: {
            step_ = 1768;
            return true;
        }
        case 1768: {
            dlatch_ = get_data(pins);
            alu_op(6, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1769;
            return true;
        }
        case 1769: {
            pins = begin_fetch(pins);
            return true;
        }
        case 247: {
            step_ = 1770;
            return true;
        }
        case 1770: {
            step_ = 1771;
            return true;
        }
        case 1771: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1772;
            return true;
        }
        case 1772: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1773;
            return true;
        }
        case 1773: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1774;
            return true;
        }
        case 1774: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1775;
            return true;
        }
        case 1775: {
            step_ = 1776;
            return true;
        }
        case 1776: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1777;
            return true;
        }
        case 1777: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1778;
            return true;
        }
        case 1778: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1779;
            return true;
        }
        case 1779: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1780;
            return true;
        }
        case 1780: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = 48; regs.pc = regs.wz;
            step_ = 1781;
            return true;
        }
        case 1781: {
            step_ = 1782;
            return true;
        }
        case 1782: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1783;
            return true;
        }
        case 1783: {
            pins = begin_fetch(pins);
            return true;
        }
        case 248: {
            step_ = 1784;
            return true;
        }
        case 1784: {
            if (!((regs.f & FLAG_S) != 0)) { step_ = 1797; return true; }
            step_ = 1785;
            return true;
        }
        case 1785: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1786;
            return true;
        }
        case 1786: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1787;
            return true;
        }
        case 1787: {
            step_ = 1788;
            return true;
        }
        case 1788: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1789;
            return true;
        }
        case 1789: {
            step_ = 1790;
            return true;
        }
        case 1790: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1791;
            return true;
        }
        case 1791: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1792;
            return true;
        }
        case 1792: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1793;
            return true;
        }
        case 1793: {
            step_ = 1794;
            return true;
        }
        case 1794: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1795;
            return true;
        }
        case 1795: {
            step_ = 1796;
            return true;
        }
        case 1796: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1797;
            return true;
        }
        case 1797: {
            pins = begin_fetch(pins);
            return true;
        }
        case 249: {
            step_ = 1798;
            return true;
        }
        case 1798: {
            regs.sp = hlx();
            step_ = 1799;
            return true;
        }
        case 1799: {
            step_ = 1800;
            return true;
        }
        case 1800: {
            step_ = 1801;
            return true;
        }
        case 1801: {
            pins = begin_fetch(pins);
            return true;
        }
        case 250: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1802;
            return true;
        }
        case 1802: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1803;
            return true;
        }
        case 1803: {
            step_ = 1804;
            return true;
        }
        case 1804: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1805;
            return true;
        }
        case 1805: {
            step_ = 1806;
            return true;
        }
        case 1806: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1807;
            return true;
        }
        case 1807: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1808;
            return true;
        }
        case 1808: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1809;
            return true;
        }
        case 1809: {
            step_ = 1810;
            return true;
        }
        case 1810: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1811;
            return true;
        }
        case 1811: {
            step_ = 1812;
            return true;
        }
        case 1812: {
            regs.set_wzh(get_data(pins));
            if ((regs.f & FLAG_S) != 0) { regs.pc = regs.wz; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1813;
            return true;
        }
        case 1813: {
            pins = begin_fetch(pins);
            return true;
        }
        case 251: {
            regs.iff1 = false; regs.iff2 = false;
            pins = begin_fetch(pins);
            regs.iff1 = true; regs.iff2 = true;
            return true;
        }
        case 252: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1814;
            return true;
        }
        case 1814: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1815;
            return true;
        }
        case 1815: {
            step_ = 1816;
            return true;
        }
        case 1816: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1817;
            return true;
        }
        case 1817: {
            step_ = 1818;
            return true;
        }
        case 1818: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1819;
            return true;
        }
        case 1819: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1820;
            return true;
        }
        case 1820: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1821;
            return true;
        }
        case 1821: {
            step_ = 1822;
            return true;
        }
        case 1822: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1823;
            return true;
        }
        case 1823: {
            step_ = 1824;
            return true;
        }
        case 1824: {
            regs.set_wzh(get_data(pins));
            if (!((regs.f & FLAG_S) != 0)) { pins = release_pins(pins, MREQ | RD); step_ = 1839; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 1825;
            return true;
        }
        case 1825: {
            step_ = 1826;
            return true;
        }
        case 1826: {
            step_ = 1827;
            return true;
        }
        case 1827: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1828;
            return true;
        }
        case 1828: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1829;
            return true;
        }
        case 1829: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1830;
            return true;
        }
        case 1830: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1831;
            return true;
        }
        case 1831: {
            step_ = 1832;
            return true;
        }
        case 1832: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1833;
            return true;
        }
        case 1833: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1834;
            return true;
        }
        case 1834: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1835;
            return true;
        }
        case 1835: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1836;
            return true;
        }
        case 1836: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.pc = regs.wz;
            step_ = 1837;
            return true;
        }
        case 1837: {
            step_ = 1838;
            return true;
        }
        case 1838: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1839;
            return true;
        }
        case 1839: {
            pins = begin_fetch(pins);
            return true;
        }
        case 254: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1840;
            return true;
        }
        case 1840: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1841;
            return true;
        }
        case 1841: {
            step_ = 1842;
            return true;
        }
        case 1842: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1843;
            return true;
        }
        case 1843: {
            step_ = 1844;
            return true;
        }
        case 1844: {
            dlatch_ = get_data(pins);
            alu_op(7, dlatch_);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1845;
            return true;
        }
        case 1845: {
            pins = begin_fetch(pins);
            return true;
        }
        case 255: {
            step_ = 1846;
            return true;
        }
        case 1846: {
            step_ = 1847;
            return true;
        }
        case 1847: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1848;
            return true;
        }
        case 1848: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1849;
            return true;
        }
        case 1849: {
            pins = set_data(pins, uint8_t(regs.pc >> 8));
            step_ = 1850;
            return true;
        }
        case 1850: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1851;
            return true;
        }
        case 1851: {
            step_ = 1852;
            return true;
        }
        case 1852: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1853;
            return true;
        }
        case 1853: {
            pins = set_addr(pins, sp_pre_dec());
            step_ = 1854;
            return true;
        }
        case 1854: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1855;
            return true;
        }
        case 1855: {
            pins = set_data(pins, uint8_t(regs.pc));
            step_ = 1856;
            return true;
        }
        case 1856: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = 56; regs.pc = regs.wz;
            step_ = 1857;
            return true;
        }
        case 1857: {
            step_ = 1858;
            return true;
        }
        case 1858: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1859;
            return true;
        }
        case 1859: {
            pins = begin_fetch(pins);
            return true;
        }
        case 256: {
            pins = begin_fetch(pins);
            return true;
        }
        case 257: {
            pins = begin_fetch(pins);
            return true;
        }
        case 258: {
            pins = begin_fetch(pins);
            return true;
        }
        case 259: {
            pins = begin_fetch(pins);
            return true;
        }
        case 260: {
            pins = begin_fetch(pins);
            return true;
        }
        case 261: {
            pins = begin_fetch(pins);
            return true;
        }
        case 262: {
            pins = begin_fetch(pins);
            return true;
        }
        case 263: {
            pins = begin_fetch(pins);
            return true;
        }
        case 264: {
            pins = begin_fetch(pins);
            return true;
        }
        case 265: {
            pins = begin_fetch(pins);
            return true;
        }
        case 266: {
            pins = begin_fetch(pins);
            return true;
        }
        case 267: {
            pins = begin_fetch(pins);
            return true;
        }
        case 268: {
            pins = begin_fetch(pins);
            return true;
        }
        case 269: {
            pins = begin_fetch(pins);
            return true;
        }
        case 270: {
            pins = begin_fetch(pins);
            return true;
        }
        case 271: {
            pins = begin_fetch(pins);
            return true;
        }
        case 272: {
            pins = begin_fetch(pins);
            return true;
        }
        case 273: {
            pins = begin_fetch(pins);
            return true;
        }
        case 274: {
            pins = begin_fetch(pins);
            return true;
        }
        case 275: {
            pins = begin_fetch(pins);
            return true;
        }
        case 276: {
            pins = begin_fetch(pins);
            return true;
        }
        case 277: {
            pins = begin_fetch(pins);
            return true;
        }
        case 278: {
            pins = begin_fetch(pins);
            return true;
        }
        case 279: {
            pins = begin_fetch(pins);
            return true;
        }
        case 280: {
            pins = begin_fetch(pins);
            return true;
        }
        case 281: {
            pins = begin_fetch(pins);
            return true;
        }
        case 282: {
            pins = begin_fetch(pins);
            return true;
        }
        case 283: {
            pins = begin_fetch(pins);
            return true;
        }
        case 284: {
            pins = begin_fetch(pins);
            return true;
        }
        case 285: {
            pins = begin_fetch(pins);
            return true;
        }
        case 286: {
            pins = begin_fetch(pins);
            return true;
        }
        case 287: {
            pins = begin_fetch(pins);
            return true;
        }
        case 288: {
            pins = begin_fetch(pins);
            return true;
        }
        case 289: {
            pins = begin_fetch(pins);
            return true;
        }
        case 290: {
            pins = begin_fetch(pins);
            return true;
        }
        case 291: {
            pins = begin_fetch(pins);
            return true;
        }
        case 292: {
            pins = begin_fetch(pins);
            return true;
        }
        case 293: {
            pins = begin_fetch(pins);
            return true;
        }
        case 294: {
            pins = begin_fetch(pins);
            return true;
        }
        case 295: {
            pins = begin_fetch(pins);
            return true;
        }
        case 296: {
            pins = begin_fetch(pins);
            return true;
        }
        case 297: {
            pins = begin_fetch(pins);
            return true;
        }
        case 298: {
            pins = begin_fetch(pins);
            return true;
        }
        case 299: {
            pins = begin_fetch(pins);
            return true;
        }
        case 300: {
            pins = begin_fetch(pins);
            return true;
        }
        case 301: {
            pins = begin_fetch(pins);
            return true;
        }
        case 302: {
            pins = begin_fetch(pins);
            return true;
        }
        case 303: {
            pins = begin_fetch(pins);
            return true;
        }
        case 304: {
            pins = begin_fetch(pins);
            return true;
        }
        case 305: {
            pins = begin_fetch(pins);
            return true;
        }
        case 306: {
            pins = begin_fetch(pins);
            return true;
        }
        case 307: {
            pins = begin_fetch(pins);
            return true;
        }
        case 308: {
            pins = begin_fetch(pins);
            return true;
        }
        case 309: {
            pins = begin_fetch(pins);
            return true;
        }
        case 310: {
            pins = begin_fetch(pins);
            return true;
        }
        case 311: {
            pins = begin_fetch(pins);
            return true;
        }
        case 312: {
            pins = begin_fetch(pins);
            return true;
        }
        case 313: {
            pins = begin_fetch(pins);
            return true;
        }
        case 314: {
            pins = begin_fetch(pins);
            return true;
        }
        case 315: {
            pins = begin_fetch(pins);
            return true;
        }
        case 316: {
            pins = begin_fetch(pins);
            return true;
        }
        case 317: {
            pins = begin_fetch(pins);
            return true;
        }
        case 318: {
            pins = begin_fetch(pins);
            return true;
        }
        case 319: {
            pins = begin_fetch(pins);
            return true;
        }
        case 320: {
            pins = set_addr(pins, regs.bc());
            step_ = 1860;
            return true;
        }
        case 1860: {
            step_ = 1861;
            return true;
        }
        case 1861: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 1862;
            return true;
        }
        case 1862: {
            step_ = 1863;
            return true;
        }
        case 1863: {
            step_ = 1864;
            return true;
        }
        case 1864: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1865;
            return true;
        }
        case 1865: {
            step_ = 1866;
            return true;
        }
        case 1866: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 1867;
            return true;
        }
        case 1867: {
            regs.b = dlatch_; regs.f = alu::in_flags(dlatch_, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 321: {
            pins = set_addr(pins, regs.bc());
            step_ = 1868;
            return true;
        }
        case 1868: {
            step_ = 1869;
            return true;
        }
        case 1869: {
            pins = set_addr_data_assert(pins, get_addr(pins), regs.b, IORQ | WR);
            step_ = 1870;
            return true;
        }
        case 1870: {
            step_ = 1871;
            return true;
        }
        case 1871: {
            step_ = 1872;
            return true;
        }
        case 1872: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1873;
            return true;
        }
        case 1873: {
            step_ = 1874;
            return true;
        }
        case 1874: {
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | WR);
            step_ = 1875;
            return true;
        }
        case 1875: {
            pins = begin_fetch(pins);
            return true;
        }
        case 322: {
            step_ = 1876;
            return true;
        }
        case 1876: {
            regs.wz = uint16_t(regs.hl() + 1); auto r = alu::sbc16(regs.hl(), regs.bc(), uint8_t(regs.f & FLAG_C)); regs.set_hl(r.value); regs.f = r.flags;
            step_ = 1877;
            return true;
        }
        case 1877: {
            step_ = 1878;
            return true;
        }
        case 1878: {
            step_ = 1879;
            return true;
        }
        case 1879: {
            step_ = 1880;
            return true;
        }
        case 1880: {
            step_ = 1881;
            return true;
        }
        case 1881: {
            step_ = 1882;
            return true;
        }
        case 1882: {
            step_ = 1883;
            return true;
        }
        case 1883: {
            step_ = 1884;
            return true;
        }
        case 1884: {
            step_ = 1885;
            return true;
        }
        case 1885: {
            step_ = 1886;
            return true;
        }
        case 1886: {
            step_ = 1887;
            return true;
        }
        case 1887: {
            step_ = 1888;
            return true;
        }
        case 1888: {
            step_ = 1889;
            return true;
        }
        case 1889: {
            pins = begin_fetch(pins);
            return true;
        }
        case 323: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1890;
            return true;
        }
        case 1890: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1891;
            return true;
        }
        case 1891: {
            step_ = 1892;
            return true;
        }
        case 1892: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1893;
            return true;
        }
        case 1893: {
            step_ = 1894;
            return true;
        }
        case 1894: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1895;
            return true;
        }
        case 1895: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1896;
            return true;
        }
        case 1896: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1897;
            return true;
        }
        case 1897: {
            step_ = 1898;
            return true;
        }
        case 1898: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1899;
            return true;
        }
        case 1899: {
            step_ = 1900;
            return true;
        }
        case 1900: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1901;
            return true;
        }
        case 1901: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 1902;
            return true;
        }
        case 1902: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1903;
            return true;
        }
        case 1903: {
            pins = set_data(pins, regs.c);
            step_ = 1904;
            return true;
        }
        case 1904: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1905;
            return true;
        }
        case 1905: {
            step_ = 1906;
            return true;
        }
        case 1906: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1907;
            return true;
        }
        case 1907: {
            pins = set_addr(pins, regs.wz);
            step_ = 1908;
            return true;
        }
        case 1908: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 1909;
            return true;
        }
        case 1909: {
            pins = set_data(pins, regs.b);
            step_ = 1910;
            return true;
        }
        case 1910: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 1911;
            return true;
        }
        case 1911: {
            step_ = 1912;
            return true;
        }
        case 1912: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 1913;
            return true;
        }
        case 1913: {
            pins = begin_fetch(pins);
            return true;
        }
        case 324: {
            auto r = alu::sub8(0, regs.a); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 325: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1914;
            return true;
        }
        case 1914: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1915;
            return true;
        }
        case 1915: {
            step_ = 1916;
            return true;
        }
        case 1916: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1917;
            return true;
        }
        case 1917: {
            step_ = 1918;
            return true;
        }
        case 1918: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1919;
            return true;
        }
        case 1919: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1920;
            return true;
        }
        case 1920: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1921;
            return true;
        }
        case 1921: {
            step_ = 1922;
            return true;
        }
        case 1922: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1923;
            return true;
        }
        case 1923: {
            step_ = 1924;
            return true;
        }
        case 1924: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1925;
            return true;
        }
        case 1925: {
            pins = begin_fetch(pins);
            regs.iff1 = regs.iff2;
            return true;
        }
        case 326: {
            regs.im = 0;
            pins = begin_fetch(pins);
            return true;
        }
        case 327: {
            step_ = 1926;
            return true;
        }
        case 1926: {
            regs.i = regs.a;
            step_ = 1927;
            return true;
        }
        case 1927: {
            pins = begin_fetch(pins);
            return true;
        }
        case 328: {
            pins = set_addr(pins, regs.bc());
            step_ = 1928;
            return true;
        }
        case 1928: {
            step_ = 1929;
            return true;
        }
        case 1929: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 1930;
            return true;
        }
        case 1930: {
            step_ = 1931;
            return true;
        }
        case 1931: {
            step_ = 1932;
            return true;
        }
        case 1932: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1933;
            return true;
        }
        case 1933: {
            step_ = 1934;
            return true;
        }
        case 1934: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 1935;
            return true;
        }
        case 1935: {
            regs.c = dlatch_; regs.f = alu::in_flags(dlatch_, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 329: {
            pins = set_addr(pins, regs.bc());
            step_ = 1936;
            return true;
        }
        case 1936: {
            step_ = 1937;
            return true;
        }
        case 1937: {
            pins = set_addr_data_assert(pins, get_addr(pins), regs.c, IORQ | WR);
            step_ = 1938;
            return true;
        }
        case 1938: {
            step_ = 1939;
            return true;
        }
        case 1939: {
            step_ = 1940;
            return true;
        }
        case 1940: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1941;
            return true;
        }
        case 1941: {
            step_ = 1942;
            return true;
        }
        case 1942: {
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | WR);
            step_ = 1943;
            return true;
        }
        case 1943: {
            pins = begin_fetch(pins);
            return true;
        }
        case 330: {
            step_ = 1944;
            return true;
        }
        case 1944: {
            regs.wz = uint16_t(regs.hl() + 1); auto r = alu::adc16(regs.hl(), regs.bc(), uint8_t(regs.f & FLAG_C)); regs.set_hl(r.value); regs.f = r.flags;
            step_ = 1945;
            return true;
        }
        case 1945: {
            step_ = 1946;
            return true;
        }
        case 1946: {
            step_ = 1947;
            return true;
        }
        case 1947: {
            step_ = 1948;
            return true;
        }
        case 1948: {
            step_ = 1949;
            return true;
        }
        case 1949: {
            step_ = 1950;
            return true;
        }
        case 1950: {
            step_ = 1951;
            return true;
        }
        case 1951: {
            step_ = 1952;
            return true;
        }
        case 1952: {
            step_ = 1953;
            return true;
        }
        case 1953: {
            step_ = 1954;
            return true;
        }
        case 1954: {
            step_ = 1955;
            return true;
        }
        case 1955: {
            step_ = 1956;
            return true;
        }
        case 1956: {
            step_ = 1957;
            return true;
        }
        case 1957: {
            pins = begin_fetch(pins);
            return true;
        }
        case 331: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1958;
            return true;
        }
        case 1958: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1959;
            return true;
        }
        case 1959: {
            step_ = 1960;
            return true;
        }
        case 1960: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1961;
            return true;
        }
        case 1961: {
            step_ = 1962;
            return true;
        }
        case 1962: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1963;
            return true;
        }
        case 1963: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 1964;
            return true;
        }
        case 1964: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1965;
            return true;
        }
        case 1965: {
            step_ = 1966;
            return true;
        }
        case 1966: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1967;
            return true;
        }
        case 1967: {
            step_ = 1968;
            return true;
        }
        case 1968: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1969;
            return true;
        }
        case 1969: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 1970;
            return true;
        }
        case 1970: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1971;
            return true;
        }
        case 1971: {
            step_ = 1972;
            return true;
        }
        case 1972: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1973;
            return true;
        }
        case 1973: {
            step_ = 1974;
            return true;
        }
        case 1974: {
            regs.c = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1975;
            return true;
        }
        case 1975: {
            pins = set_addr(pins, regs.wz);
            step_ = 1976;
            return true;
        }
        case 1976: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1977;
            return true;
        }
        case 1977: {
            step_ = 1978;
            return true;
        }
        case 1978: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1979;
            return true;
        }
        case 1979: {
            step_ = 1980;
            return true;
        }
        case 1980: {
            regs.b = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 1981;
            return true;
        }
        case 1981: {
            pins = begin_fetch(pins);
            return true;
        }
        case 332: {
            auto r = alu::sub8(0, regs.a); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 333: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1982;
            return true;
        }
        case 1982: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1983;
            return true;
        }
        case 1983: {
            step_ = 1984;
            return true;
        }
        case 1984: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1985;
            return true;
        }
        case 1985: {
            step_ = 1986;
            return true;
        }
        case 1986: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 1987;
            return true;
        }
        case 1987: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 1988;
            return true;
        }
        case 1988: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 1989;
            return true;
        }
        case 1989: {
            step_ = 1990;
            return true;
        }
        case 1990: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 1991;
            return true;
        }
        case 1991: {
            step_ = 1992;
            return true;
        }
        case 1992: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 1993;
            return true;
        }
        case 1993: {
            pins = begin_fetch(pins);
            regs.iff1 = regs.iff2;
            return true;
        }
        case 334: {
            regs.im = 0;
            pins = begin_fetch(pins);
            return true;
        }
        case 335: {
            step_ = 1994;
            return true;
        }
        case 1994: {
            regs.r = regs.a;
            step_ = 1995;
            return true;
        }
        case 1995: {
            pins = begin_fetch(pins);
            return true;
        }
        case 336: {
            pins = set_addr(pins, regs.bc());
            step_ = 1996;
            return true;
        }
        case 1996: {
            step_ = 1997;
            return true;
        }
        case 1997: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 1998;
            return true;
        }
        case 1998: {
            step_ = 1999;
            return true;
        }
        case 1999: {
            step_ = 2000;
            return true;
        }
        case 2000: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2001;
            return true;
        }
        case 2001: {
            step_ = 2002;
            return true;
        }
        case 2002: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2003;
            return true;
        }
        case 2003: {
            regs.d = dlatch_; regs.f = alu::in_flags(dlatch_, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 337: {
            pins = set_addr(pins, regs.bc());
            step_ = 2004;
            return true;
        }
        case 2004: {
            step_ = 2005;
            return true;
        }
        case 2005: {
            pins = set_addr_data_assert(pins, get_addr(pins), regs.d, IORQ | WR);
            step_ = 2006;
            return true;
        }
        case 2006: {
            step_ = 2007;
            return true;
        }
        case 2007: {
            step_ = 2008;
            return true;
        }
        case 2008: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2009;
            return true;
        }
        case 2009: {
            step_ = 2010;
            return true;
        }
        case 2010: {
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | WR);
            step_ = 2011;
            return true;
        }
        case 2011: {
            pins = begin_fetch(pins);
            return true;
        }
        case 338: {
            step_ = 2012;
            return true;
        }
        case 2012: {
            regs.wz = uint16_t(regs.hl() + 1); auto r = alu::sbc16(regs.hl(), regs.de(), uint8_t(regs.f & FLAG_C)); regs.set_hl(r.value); regs.f = r.flags;
            step_ = 2013;
            return true;
        }
        case 2013: {
            step_ = 2014;
            return true;
        }
        case 2014: {
            step_ = 2015;
            return true;
        }
        case 2015: {
            step_ = 2016;
            return true;
        }
        case 2016: {
            step_ = 2017;
            return true;
        }
        case 2017: {
            step_ = 2018;
            return true;
        }
        case 2018: {
            step_ = 2019;
            return true;
        }
        case 2019: {
            step_ = 2020;
            return true;
        }
        case 2020: {
            step_ = 2021;
            return true;
        }
        case 2021: {
            step_ = 2022;
            return true;
        }
        case 2022: {
            step_ = 2023;
            return true;
        }
        case 2023: {
            step_ = 2024;
            return true;
        }
        case 2024: {
            step_ = 2025;
            return true;
        }
        case 2025: {
            pins = begin_fetch(pins);
            return true;
        }
        case 339: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2026;
            return true;
        }
        case 2026: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2027;
            return true;
        }
        case 2027: {
            step_ = 2028;
            return true;
        }
        case 2028: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2029;
            return true;
        }
        case 2029: {
            step_ = 2030;
            return true;
        }
        case 2030: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2031;
            return true;
        }
        case 2031: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2032;
            return true;
        }
        case 2032: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2033;
            return true;
        }
        case 2033: {
            step_ = 2034;
            return true;
        }
        case 2034: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2035;
            return true;
        }
        case 2035: {
            step_ = 2036;
            return true;
        }
        case 2036: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2037;
            return true;
        }
        case 2037: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 2038;
            return true;
        }
        case 2038: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2039;
            return true;
        }
        case 2039: {
            pins = set_data(pins, regs.e);
            step_ = 2040;
            return true;
        }
        case 2040: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2041;
            return true;
        }
        case 2041: {
            step_ = 2042;
            return true;
        }
        case 2042: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2043;
            return true;
        }
        case 2043: {
            pins = set_addr(pins, regs.wz);
            step_ = 2044;
            return true;
        }
        case 2044: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2045;
            return true;
        }
        case 2045: {
            pins = set_data(pins, regs.d);
            step_ = 2046;
            return true;
        }
        case 2046: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2047;
            return true;
        }
        case 2047: {
            step_ = 2048;
            return true;
        }
        case 2048: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2049;
            return true;
        }
        case 2049: {
            pins = begin_fetch(pins);
            return true;
        }
        case 340: {
            auto r = alu::sub8(0, regs.a); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 341: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2050;
            return true;
        }
        case 2050: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2051;
            return true;
        }
        case 2051: {
            step_ = 2052;
            return true;
        }
        case 2052: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2053;
            return true;
        }
        case 2053: {
            step_ = 2054;
            return true;
        }
        case 2054: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2055;
            return true;
        }
        case 2055: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2056;
            return true;
        }
        case 2056: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2057;
            return true;
        }
        case 2057: {
            step_ = 2058;
            return true;
        }
        case 2058: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2059;
            return true;
        }
        case 2059: {
            step_ = 2060;
            return true;
        }
        case 2060: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 2061;
            return true;
        }
        case 2061: {
            pins = begin_fetch(pins);
            regs.iff1 = regs.iff2;
            return true;
        }
        case 342: {
            regs.im = 1;
            pins = begin_fetch(pins);
            return true;
        }
        case 343: {
            step_ = 2062;
            return true;
        }
        case 2062: {
            regs.a = regs.i; regs.f = alu::sziff2_flags(regs.i, regs.f, regs.iff2);
            step_ = 2063;
            return true;
        }
        case 2063: {
            pins = begin_fetch(pins);
            return true;
        }
        case 344: {
            pins = set_addr(pins, regs.bc());
            step_ = 2064;
            return true;
        }
        case 2064: {
            step_ = 2065;
            return true;
        }
        case 2065: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2066;
            return true;
        }
        case 2066: {
            step_ = 2067;
            return true;
        }
        case 2067: {
            step_ = 2068;
            return true;
        }
        case 2068: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2069;
            return true;
        }
        case 2069: {
            step_ = 2070;
            return true;
        }
        case 2070: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2071;
            return true;
        }
        case 2071: {
            regs.e = dlatch_; regs.f = alu::in_flags(dlatch_, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 345: {
            pins = set_addr(pins, regs.bc());
            step_ = 2072;
            return true;
        }
        case 2072: {
            step_ = 2073;
            return true;
        }
        case 2073: {
            pins = set_addr_data_assert(pins, get_addr(pins), regs.e, IORQ | WR);
            step_ = 2074;
            return true;
        }
        case 2074: {
            step_ = 2075;
            return true;
        }
        case 2075: {
            step_ = 2076;
            return true;
        }
        case 2076: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2077;
            return true;
        }
        case 2077: {
            step_ = 2078;
            return true;
        }
        case 2078: {
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | WR);
            step_ = 2079;
            return true;
        }
        case 2079: {
            pins = begin_fetch(pins);
            return true;
        }
        case 346: {
            step_ = 2080;
            return true;
        }
        case 2080: {
            regs.wz = uint16_t(regs.hl() + 1); auto r = alu::adc16(regs.hl(), regs.de(), uint8_t(regs.f & FLAG_C)); regs.set_hl(r.value); regs.f = r.flags;
            step_ = 2081;
            return true;
        }
        case 2081: {
            step_ = 2082;
            return true;
        }
        case 2082: {
            step_ = 2083;
            return true;
        }
        case 2083: {
            step_ = 2084;
            return true;
        }
        case 2084: {
            step_ = 2085;
            return true;
        }
        case 2085: {
            step_ = 2086;
            return true;
        }
        case 2086: {
            step_ = 2087;
            return true;
        }
        case 2087: {
            step_ = 2088;
            return true;
        }
        case 2088: {
            step_ = 2089;
            return true;
        }
        case 2089: {
            step_ = 2090;
            return true;
        }
        case 2090: {
            step_ = 2091;
            return true;
        }
        case 2091: {
            step_ = 2092;
            return true;
        }
        case 2092: {
            step_ = 2093;
            return true;
        }
        case 2093: {
            pins = begin_fetch(pins);
            return true;
        }
        case 347: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2094;
            return true;
        }
        case 2094: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2095;
            return true;
        }
        case 2095: {
            step_ = 2096;
            return true;
        }
        case 2096: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2097;
            return true;
        }
        case 2097: {
            step_ = 2098;
            return true;
        }
        case 2098: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2099;
            return true;
        }
        case 2099: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2100;
            return true;
        }
        case 2100: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2101;
            return true;
        }
        case 2101: {
            step_ = 2102;
            return true;
        }
        case 2102: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2103;
            return true;
        }
        case 2103: {
            step_ = 2104;
            return true;
        }
        case 2104: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2105;
            return true;
        }
        case 2105: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 2106;
            return true;
        }
        case 2106: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2107;
            return true;
        }
        case 2107: {
            step_ = 2108;
            return true;
        }
        case 2108: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2109;
            return true;
        }
        case 2109: {
            step_ = 2110;
            return true;
        }
        case 2110: {
            regs.e = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2111;
            return true;
        }
        case 2111: {
            pins = set_addr(pins, regs.wz);
            step_ = 2112;
            return true;
        }
        case 2112: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2113;
            return true;
        }
        case 2113: {
            step_ = 2114;
            return true;
        }
        case 2114: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2115;
            return true;
        }
        case 2115: {
            step_ = 2116;
            return true;
        }
        case 2116: {
            regs.d = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2117;
            return true;
        }
        case 2117: {
            pins = begin_fetch(pins);
            return true;
        }
        case 348: {
            auto r = alu::sub8(0, regs.a); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 349: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2118;
            return true;
        }
        case 2118: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2119;
            return true;
        }
        case 2119: {
            step_ = 2120;
            return true;
        }
        case 2120: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2121;
            return true;
        }
        case 2121: {
            step_ = 2122;
            return true;
        }
        case 2122: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2123;
            return true;
        }
        case 2123: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2124;
            return true;
        }
        case 2124: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2125;
            return true;
        }
        case 2125: {
            step_ = 2126;
            return true;
        }
        case 2126: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2127;
            return true;
        }
        case 2127: {
            step_ = 2128;
            return true;
        }
        case 2128: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 2129;
            return true;
        }
        case 2129: {
            pins = begin_fetch(pins);
            regs.iff1 = regs.iff2;
            return true;
        }
        case 350: {
            regs.im = 2;
            pins = begin_fetch(pins);
            return true;
        }
        case 351: {
            step_ = 2130;
            return true;
        }
        case 2130: {
            regs.a = regs.r; regs.f = alu::sziff2_flags(regs.r, regs.f, regs.iff2);
            step_ = 2131;
            return true;
        }
        case 2131: {
            pins = begin_fetch(pins);
            return true;
        }
        case 352: {
            pins = set_addr(pins, regs.bc());
            step_ = 2132;
            return true;
        }
        case 2132: {
            step_ = 2133;
            return true;
        }
        case 2133: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2134;
            return true;
        }
        case 2134: {
            step_ = 2135;
            return true;
        }
        case 2135: {
            step_ = 2136;
            return true;
        }
        case 2136: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2137;
            return true;
        }
        case 2137: {
            step_ = 2138;
            return true;
        }
        case 2138: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2139;
            return true;
        }
        case 2139: {
            regs.h = dlatch_; regs.f = alu::in_flags(dlatch_, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 353: {
            pins = set_addr(pins, regs.bc());
            step_ = 2140;
            return true;
        }
        case 2140: {
            step_ = 2141;
            return true;
        }
        case 2141: {
            pins = set_addr_data_assert(pins, get_addr(pins), regs.h, IORQ | WR);
            step_ = 2142;
            return true;
        }
        case 2142: {
            step_ = 2143;
            return true;
        }
        case 2143: {
            step_ = 2144;
            return true;
        }
        case 2144: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2145;
            return true;
        }
        case 2145: {
            step_ = 2146;
            return true;
        }
        case 2146: {
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | WR);
            step_ = 2147;
            return true;
        }
        case 2147: {
            pins = begin_fetch(pins);
            return true;
        }
        case 354: {
            step_ = 2148;
            return true;
        }
        case 2148: {
            regs.wz = uint16_t(regs.hl() + 1); auto r = alu::sbc16(regs.hl(), regs.hl(), uint8_t(regs.f & FLAG_C)); regs.set_hl(r.value); regs.f = r.flags;
            step_ = 2149;
            return true;
        }
        case 2149: {
            step_ = 2150;
            return true;
        }
        case 2150: {
            step_ = 2151;
            return true;
        }
        case 2151: {
            step_ = 2152;
            return true;
        }
        case 2152: {
            step_ = 2153;
            return true;
        }
        case 2153: {
            step_ = 2154;
            return true;
        }
        case 2154: {
            step_ = 2155;
            return true;
        }
        case 2155: {
            step_ = 2156;
            return true;
        }
        case 2156: {
            step_ = 2157;
            return true;
        }
        case 2157: {
            step_ = 2158;
            return true;
        }
        case 2158: {
            step_ = 2159;
            return true;
        }
        case 2159: {
            step_ = 2160;
            return true;
        }
        case 2160: {
            step_ = 2161;
            return true;
        }
        case 2161: {
            pins = begin_fetch(pins);
            return true;
        }
        case 355: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2162;
            return true;
        }
        case 2162: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2163;
            return true;
        }
        case 2163: {
            step_ = 2164;
            return true;
        }
        case 2164: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2165;
            return true;
        }
        case 2165: {
            step_ = 2166;
            return true;
        }
        case 2166: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2167;
            return true;
        }
        case 2167: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2168;
            return true;
        }
        case 2168: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2169;
            return true;
        }
        case 2169: {
            step_ = 2170;
            return true;
        }
        case 2170: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2171;
            return true;
        }
        case 2171: {
            step_ = 2172;
            return true;
        }
        case 2172: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2173;
            return true;
        }
        case 2173: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 2174;
            return true;
        }
        case 2174: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2175;
            return true;
        }
        case 2175: {
            pins = set_data(pins, regs.l);
            step_ = 2176;
            return true;
        }
        case 2176: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2177;
            return true;
        }
        case 2177: {
            step_ = 2178;
            return true;
        }
        case 2178: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2179;
            return true;
        }
        case 2179: {
            pins = set_addr(pins, regs.wz);
            step_ = 2180;
            return true;
        }
        case 2180: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2181;
            return true;
        }
        case 2181: {
            pins = set_data(pins, regs.h);
            step_ = 2182;
            return true;
        }
        case 2182: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2183;
            return true;
        }
        case 2183: {
            step_ = 2184;
            return true;
        }
        case 2184: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2185;
            return true;
        }
        case 2185: {
            pins = begin_fetch(pins);
            return true;
        }
        case 356: {
            auto r = alu::sub8(0, regs.a); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 357: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2186;
            return true;
        }
        case 2186: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2187;
            return true;
        }
        case 2187: {
            step_ = 2188;
            return true;
        }
        case 2188: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2189;
            return true;
        }
        case 2189: {
            step_ = 2190;
            return true;
        }
        case 2190: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2191;
            return true;
        }
        case 2191: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2192;
            return true;
        }
        case 2192: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2193;
            return true;
        }
        case 2193: {
            step_ = 2194;
            return true;
        }
        case 2194: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2195;
            return true;
        }
        case 2195: {
            step_ = 2196;
            return true;
        }
        case 2196: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 2197;
            return true;
        }
        case 2197: {
            pins = begin_fetch(pins);
            regs.iff1 = regs.iff2;
            return true;
        }
        case 358: {
            regs.im = 0;
            pins = begin_fetch(pins);
            return true;
        }
        case 359: {
            pins = set_addr(pins, regs.hl());
            step_ = 2198;
            return true;
        }
        case 2198: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2199;
            return true;
        }
        case 2199: {
            step_ = 2200;
            return true;
        }
        case 2200: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2201;
            return true;
        }
        case 2201: {
            step_ = 2202;
            return true;
        }
        case 2202: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2203;
            return true;
        }
        case 2203: {
            step_ = 2204;
            return true;
        }
        case 2204: {
            auto r = alu::rrd(regs.a, dlatch_, regs.f); regs.a = r.new_a; dlatch_ = r.new_mem; regs.f = r.flags;
            step_ = 2205;
            return true;
        }
        case 2205: {
            step_ = 2206;
            return true;
        }
        case 2206: {
            step_ = 2207;
            return true;
        }
        case 2207: {
            step_ = 2208;
            return true;
        }
        case 2208: {
            step_ = 2209;
            return true;
        }
        case 2209: {
            step_ = 2210;
            return true;
        }
        case 2210: {
            step_ = 2211;
            return true;
        }
        case 2211: {
            pins = set_addr(pins, regs.hl());
            step_ = 2212;
            return true;
        }
        case 2212: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2213;
            return true;
        }
        case 2213: {
            pins = set_data(pins, dlatch_);
            step_ = 2214;
            return true;
        }
        case 2214: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = uint16_t(regs.hl() + 1);
            step_ = 2215;
            return true;
        }
        case 2215: {
            step_ = 2216;
            return true;
        }
        case 2216: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2217;
            return true;
        }
        case 2217: {
            pins = begin_fetch(pins);
            return true;
        }
        case 360: {
            pins = set_addr(pins, regs.bc());
            step_ = 2218;
            return true;
        }
        case 2218: {
            step_ = 2219;
            return true;
        }
        case 2219: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2220;
            return true;
        }
        case 2220: {
            step_ = 2221;
            return true;
        }
        case 2221: {
            step_ = 2222;
            return true;
        }
        case 2222: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2223;
            return true;
        }
        case 2223: {
            step_ = 2224;
            return true;
        }
        case 2224: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2225;
            return true;
        }
        case 2225: {
            regs.l = dlatch_; regs.f = alu::in_flags(dlatch_, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 361: {
            pins = set_addr(pins, regs.bc());
            step_ = 2226;
            return true;
        }
        case 2226: {
            step_ = 2227;
            return true;
        }
        case 2227: {
            pins = set_addr_data_assert(pins, get_addr(pins), regs.l, IORQ | WR);
            step_ = 2228;
            return true;
        }
        case 2228: {
            step_ = 2229;
            return true;
        }
        case 2229: {
            step_ = 2230;
            return true;
        }
        case 2230: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2231;
            return true;
        }
        case 2231: {
            step_ = 2232;
            return true;
        }
        case 2232: {
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | WR);
            step_ = 2233;
            return true;
        }
        case 2233: {
            pins = begin_fetch(pins);
            return true;
        }
        case 362: {
            step_ = 2234;
            return true;
        }
        case 2234: {
            regs.wz = uint16_t(regs.hl() + 1); auto r = alu::adc16(regs.hl(), regs.hl(), uint8_t(regs.f & FLAG_C)); regs.set_hl(r.value); regs.f = r.flags;
            step_ = 2235;
            return true;
        }
        case 2235: {
            step_ = 2236;
            return true;
        }
        case 2236: {
            step_ = 2237;
            return true;
        }
        case 2237: {
            step_ = 2238;
            return true;
        }
        case 2238: {
            step_ = 2239;
            return true;
        }
        case 2239: {
            step_ = 2240;
            return true;
        }
        case 2240: {
            step_ = 2241;
            return true;
        }
        case 2241: {
            step_ = 2242;
            return true;
        }
        case 2242: {
            step_ = 2243;
            return true;
        }
        case 2243: {
            step_ = 2244;
            return true;
        }
        case 2244: {
            step_ = 2245;
            return true;
        }
        case 2245: {
            step_ = 2246;
            return true;
        }
        case 2246: {
            step_ = 2247;
            return true;
        }
        case 2247: {
            pins = begin_fetch(pins);
            return true;
        }
        case 363: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2248;
            return true;
        }
        case 2248: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2249;
            return true;
        }
        case 2249: {
            step_ = 2250;
            return true;
        }
        case 2250: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2251;
            return true;
        }
        case 2251: {
            step_ = 2252;
            return true;
        }
        case 2252: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2253;
            return true;
        }
        case 2253: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2254;
            return true;
        }
        case 2254: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2255;
            return true;
        }
        case 2255: {
            step_ = 2256;
            return true;
        }
        case 2256: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2257;
            return true;
        }
        case 2257: {
            step_ = 2258;
            return true;
        }
        case 2258: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2259;
            return true;
        }
        case 2259: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 2260;
            return true;
        }
        case 2260: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2261;
            return true;
        }
        case 2261: {
            step_ = 2262;
            return true;
        }
        case 2262: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2263;
            return true;
        }
        case 2263: {
            step_ = 2264;
            return true;
        }
        case 2264: {
            regs.l = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2265;
            return true;
        }
        case 2265: {
            pins = set_addr(pins, regs.wz);
            step_ = 2266;
            return true;
        }
        case 2266: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2267;
            return true;
        }
        case 2267: {
            step_ = 2268;
            return true;
        }
        case 2268: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2269;
            return true;
        }
        case 2269: {
            step_ = 2270;
            return true;
        }
        case 2270: {
            regs.h = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2271;
            return true;
        }
        case 2271: {
            pins = begin_fetch(pins);
            return true;
        }
        case 364: {
            auto r = alu::sub8(0, regs.a); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 365: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2272;
            return true;
        }
        case 2272: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2273;
            return true;
        }
        case 2273: {
            step_ = 2274;
            return true;
        }
        case 2274: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2275;
            return true;
        }
        case 2275: {
            step_ = 2276;
            return true;
        }
        case 2276: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2277;
            return true;
        }
        case 2277: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2278;
            return true;
        }
        case 2278: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2279;
            return true;
        }
        case 2279: {
            step_ = 2280;
            return true;
        }
        case 2280: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2281;
            return true;
        }
        case 2281: {
            step_ = 2282;
            return true;
        }
        case 2282: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 2283;
            return true;
        }
        case 2283: {
            pins = begin_fetch(pins);
            regs.iff1 = regs.iff2;
            return true;
        }
        case 366: {
            regs.im = 0;
            pins = begin_fetch(pins);
            return true;
        }
        case 367: {
            pins = set_addr(pins, regs.hl());
            step_ = 2284;
            return true;
        }
        case 2284: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2285;
            return true;
        }
        case 2285: {
            step_ = 2286;
            return true;
        }
        case 2286: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2287;
            return true;
        }
        case 2287: {
            step_ = 2288;
            return true;
        }
        case 2288: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2289;
            return true;
        }
        case 2289: {
            step_ = 2290;
            return true;
        }
        case 2290: {
            auto r = alu::rld(regs.a, dlatch_, regs.f); regs.a = r.new_a; dlatch_ = r.new_mem; regs.f = r.flags;
            step_ = 2291;
            return true;
        }
        case 2291: {
            step_ = 2292;
            return true;
        }
        case 2292: {
            step_ = 2293;
            return true;
        }
        case 2293: {
            step_ = 2294;
            return true;
        }
        case 2294: {
            step_ = 2295;
            return true;
        }
        case 2295: {
            step_ = 2296;
            return true;
        }
        case 2296: {
            step_ = 2297;
            return true;
        }
        case 2297: {
            pins = set_addr(pins, regs.hl());
            step_ = 2298;
            return true;
        }
        case 2298: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2299;
            return true;
        }
        case 2299: {
            pins = set_data(pins, dlatch_);
            step_ = 2300;
            return true;
        }
        case 2300: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.wz = uint16_t(regs.hl() + 1);
            step_ = 2301;
            return true;
        }
        case 2301: {
            step_ = 2302;
            return true;
        }
        case 2302: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2303;
            return true;
        }
        case 2303: {
            pins = begin_fetch(pins);
            return true;
        }
        case 368: {
            pins = set_addr(pins, regs.bc());
            step_ = 2304;
            return true;
        }
        case 2304: {
            step_ = 2305;
            return true;
        }
        case 2305: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2306;
            return true;
        }
        case 2306: {
            step_ = 2307;
            return true;
        }
        case 2307: {
            step_ = 2308;
            return true;
        }
        case 2308: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2309;
            return true;
        }
        case 2309: {
            step_ = 2310;
            return true;
        }
        case 2310: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2311;
            return true;
        }
        case 2311: {
            regs.f = alu::in_flags(dlatch_, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 369: {
            pins = set_addr(pins, regs.bc());
            step_ = 2312;
            return true;
        }
        case 2312: {
            step_ = 2313;
            return true;
        }
        case 2313: {
            pins = set_addr_data_assert(pins, get_addr(pins), 0, IORQ | WR);
            step_ = 2314;
            return true;
        }
        case 2314: {
            step_ = 2315;
            return true;
        }
        case 2315: {
            step_ = 2316;
            return true;
        }
        case 2316: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2317;
            return true;
        }
        case 2317: {
            step_ = 2318;
            return true;
        }
        case 2318: {
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | WR);
            step_ = 2319;
            return true;
        }
        case 2319: {
            pins = begin_fetch(pins);
            return true;
        }
        case 370: {
            step_ = 2320;
            return true;
        }
        case 2320: {
            regs.wz = uint16_t(regs.hl() + 1); auto r = alu::sbc16(regs.hl(), regs.sp, uint8_t(regs.f & FLAG_C)); regs.set_hl(r.value); regs.f = r.flags;
            step_ = 2321;
            return true;
        }
        case 2321: {
            step_ = 2322;
            return true;
        }
        case 2322: {
            step_ = 2323;
            return true;
        }
        case 2323: {
            step_ = 2324;
            return true;
        }
        case 2324: {
            step_ = 2325;
            return true;
        }
        case 2325: {
            step_ = 2326;
            return true;
        }
        case 2326: {
            step_ = 2327;
            return true;
        }
        case 2327: {
            step_ = 2328;
            return true;
        }
        case 2328: {
            step_ = 2329;
            return true;
        }
        case 2329: {
            step_ = 2330;
            return true;
        }
        case 2330: {
            step_ = 2331;
            return true;
        }
        case 2331: {
            step_ = 2332;
            return true;
        }
        case 2332: {
            step_ = 2333;
            return true;
        }
        case 2333: {
            pins = begin_fetch(pins);
            return true;
        }
        case 371: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2334;
            return true;
        }
        case 2334: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2335;
            return true;
        }
        case 2335: {
            step_ = 2336;
            return true;
        }
        case 2336: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2337;
            return true;
        }
        case 2337: {
            step_ = 2338;
            return true;
        }
        case 2338: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2339;
            return true;
        }
        case 2339: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2340;
            return true;
        }
        case 2340: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2341;
            return true;
        }
        case 2341: {
            step_ = 2342;
            return true;
        }
        case 2342: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2343;
            return true;
        }
        case 2343: {
            step_ = 2344;
            return true;
        }
        case 2344: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2345;
            return true;
        }
        case 2345: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 2346;
            return true;
        }
        case 2346: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2347;
            return true;
        }
        case 2347: {
            pins = set_data(pins, regs.spl());
            step_ = 2348;
            return true;
        }
        case 2348: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2349;
            return true;
        }
        case 2349: {
            step_ = 2350;
            return true;
        }
        case 2350: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2351;
            return true;
        }
        case 2351: {
            pins = set_addr(pins, regs.wz);
            step_ = 2352;
            return true;
        }
        case 2352: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2353;
            return true;
        }
        case 2353: {
            pins = set_data(pins, regs.sph());
            step_ = 2354;
            return true;
        }
        case 2354: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2355;
            return true;
        }
        case 2355: {
            step_ = 2356;
            return true;
        }
        case 2356: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2357;
            return true;
        }
        case 2357: {
            pins = begin_fetch(pins);
            return true;
        }
        case 372: {
            auto r = alu::sub8(0, regs.a); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 373: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2358;
            return true;
        }
        case 2358: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2359;
            return true;
        }
        case 2359: {
            step_ = 2360;
            return true;
        }
        case 2360: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2361;
            return true;
        }
        case 2361: {
            step_ = 2362;
            return true;
        }
        case 2362: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2363;
            return true;
        }
        case 2363: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2364;
            return true;
        }
        case 2364: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2365;
            return true;
        }
        case 2365: {
            step_ = 2366;
            return true;
        }
        case 2366: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2367;
            return true;
        }
        case 2367: {
            step_ = 2368;
            return true;
        }
        case 2368: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 2369;
            return true;
        }
        case 2369: {
            pins = begin_fetch(pins);
            regs.iff1 = regs.iff2;
            return true;
        }
        case 374: {
            regs.im = 1;
            pins = begin_fetch(pins);
            return true;
        }
        case 375: {
            pins = begin_fetch(pins);
            return true;
        }
        case 376: {
            pins = set_addr(pins, regs.bc());
            step_ = 2370;
            return true;
        }
        case 2370: {
            step_ = 2371;
            return true;
        }
        case 2371: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2372;
            return true;
        }
        case 2372: {
            step_ = 2373;
            return true;
        }
        case 2373: {
            step_ = 2374;
            return true;
        }
        case 2374: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2375;
            return true;
        }
        case 2375: {
            step_ = 2376;
            return true;
        }
        case 2376: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2377;
            return true;
        }
        case 2377: {
            regs.a = dlatch_; regs.f = alu::in_flags(dlatch_, regs.f);
            pins = begin_fetch(pins);
            return true;
        }
        case 377: {
            pins = set_addr(pins, regs.bc());
            step_ = 2378;
            return true;
        }
        case 2378: {
            step_ = 2379;
            return true;
        }
        case 2379: {
            pins = set_addr_data_assert(pins, get_addr(pins), regs.a, IORQ | WR);
            step_ = 2380;
            return true;
        }
        case 2380: {
            step_ = 2381;
            return true;
        }
        case 2381: {
            step_ = 2382;
            return true;
        }
        case 2382: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2383;
            return true;
        }
        case 2383: {
            step_ = 2384;
            return true;
        }
        case 2384: {
            regs.wz = uint16_t(regs.bc() + 1);
            pins = release_pins(pins, IORQ | WR);
            step_ = 2385;
            return true;
        }
        case 2385: {
            pins = begin_fetch(pins);
            return true;
        }
        case 378: {
            step_ = 2386;
            return true;
        }
        case 2386: {
            regs.wz = uint16_t(regs.hl() + 1); auto r = alu::adc16(regs.hl(), regs.sp, uint8_t(regs.f & FLAG_C)); regs.set_hl(r.value); regs.f = r.flags;
            step_ = 2387;
            return true;
        }
        case 2387: {
            step_ = 2388;
            return true;
        }
        case 2388: {
            step_ = 2389;
            return true;
        }
        case 2389: {
            step_ = 2390;
            return true;
        }
        case 2390: {
            step_ = 2391;
            return true;
        }
        case 2391: {
            step_ = 2392;
            return true;
        }
        case 2392: {
            step_ = 2393;
            return true;
        }
        case 2393: {
            step_ = 2394;
            return true;
        }
        case 2394: {
            step_ = 2395;
            return true;
        }
        case 2395: {
            step_ = 2396;
            return true;
        }
        case 2396: {
            step_ = 2397;
            return true;
        }
        case 2397: {
            step_ = 2398;
            return true;
        }
        case 2398: {
            step_ = 2399;
            return true;
        }
        case 2399: {
            pins = begin_fetch(pins);
            return true;
        }
        case 379: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2400;
            return true;
        }
        case 2400: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2401;
            return true;
        }
        case 2401: {
            step_ = 2402;
            return true;
        }
        case 2402: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2403;
            return true;
        }
        case 2403: {
            step_ = 2404;
            return true;
        }
        case 2404: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2405;
            return true;
        }
        case 2405: {
            pins = set_addr(pins, pc_post_inc());
            step_ = 2406;
            return true;
        }
        case 2406: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2407;
            return true;
        }
        case 2407: {
            step_ = 2408;
            return true;
        }
        case 2408: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2409;
            return true;
        }
        case 2409: {
            step_ = 2410;
            return true;
        }
        case 2410: {
            regs.set_wzh(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2411;
            return true;
        }
        case 2411: {
            pins = set_addr(pins, wz_post_inc());
            step_ = 2412;
            return true;
        }
        case 2412: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2413;
            return true;
        }
        case 2413: {
            step_ = 2414;
            return true;
        }
        case 2414: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2415;
            return true;
        }
        case 2415: {
            step_ = 2416;
            return true;
        }
        case 2416: {
            regs.set_spl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2417;
            return true;
        }
        case 2417: {
            pins = set_addr(pins, regs.wz);
            step_ = 2418;
            return true;
        }
        case 2418: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2419;
            return true;
        }
        case 2419: {
            step_ = 2420;
            return true;
        }
        case 2420: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2421;
            return true;
        }
        case 2421: {
            step_ = 2422;
            return true;
        }
        case 2422: {
            regs.set_sph(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2423;
            return true;
        }
        case 2423: {
            pins = begin_fetch(pins);
            return true;
        }
        case 380: {
            auto r = alu::sub8(0, regs.a); regs.a = r.value; regs.f = r.flags;
            pins = begin_fetch(pins);
            return true;
        }
        case 381: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2424;
            return true;
        }
        case 2424: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2425;
            return true;
        }
        case 2425: {
            step_ = 2426;
            return true;
        }
        case 2426: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2427;
            return true;
        }
        case 2427: {
            step_ = 2428;
            return true;
        }
        case 2428: {
            regs.set_wzl(get_data(pins));
            pins = release_pins(pins, MREQ | RD);
            step_ = 2429;
            return true;
        }
        case 2429: {
            pins = set_addr(pins, sp_post_inc());
            step_ = 2430;
            return true;
        }
        case 2430: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2431;
            return true;
        }
        case 2431: {
            step_ = 2432;
            return true;
        }
        case 2432: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2433;
            return true;
        }
        case 2433: {
            step_ = 2434;
            return true;
        }
        case 2434: {
            regs.set_wzh(get_data(pins));
            regs.pc = regs.wz;
            pins = release_pins(pins, MREQ | RD);
            step_ = 2435;
            return true;
        }
        case 2435: {
            pins = begin_fetch(pins);
            regs.iff1 = regs.iff2;
            return true;
        }
        case 382: {
            regs.im = 2;
            pins = begin_fetch(pins);
            return true;
        }
        case 383: {
            pins = begin_fetch(pins);
            return true;
        }
        case 384: {
            pins = begin_fetch(pins);
            return true;
        }
        case 385: {
            pins = begin_fetch(pins);
            return true;
        }
        case 386: {
            pins = begin_fetch(pins);
            return true;
        }
        case 387: {
            pins = begin_fetch(pins);
            return true;
        }
        case 388: {
            pins = begin_fetch(pins);
            return true;
        }
        case 389: {
            pins = begin_fetch(pins);
            return true;
        }
        case 390: {
            pins = begin_fetch(pins);
            return true;
        }
        case 391: {
            pins = begin_fetch(pins);
            return true;
        }
        case 392: {
            pins = begin_fetch(pins);
            return true;
        }
        case 393: {
            pins = begin_fetch(pins);
            return true;
        }
        case 394: {
            pins = begin_fetch(pins);
            return true;
        }
        case 395: {
            pins = begin_fetch(pins);
            return true;
        }
        case 396: {
            pins = begin_fetch(pins);
            return true;
        }
        case 397: {
            pins = begin_fetch(pins);
            return true;
        }
        case 398: {
            pins = begin_fetch(pins);
            return true;
        }
        case 399: {
            pins = begin_fetch(pins);
            return true;
        }
        case 400: {
            pins = begin_fetch(pins);
            return true;
        }
        case 401: {
            pins = begin_fetch(pins);
            return true;
        }
        case 402: {
            pins = begin_fetch(pins);
            return true;
        }
        case 403: {
            pins = begin_fetch(pins);
            return true;
        }
        case 404: {
            pins = begin_fetch(pins);
            return true;
        }
        case 405: {
            pins = begin_fetch(pins);
            return true;
        }
        case 406: {
            pins = begin_fetch(pins);
            return true;
        }
        case 407: {
            pins = begin_fetch(pins);
            return true;
        }
        case 408: {
            pins = begin_fetch(pins);
            return true;
        }
        case 409: {
            pins = begin_fetch(pins);
            return true;
        }
        case 410: {
            pins = begin_fetch(pins);
            return true;
        }
        case 411: {
            pins = begin_fetch(pins);
            return true;
        }
        case 412: {
            pins = begin_fetch(pins);
            return true;
        }
        case 413: {
            pins = begin_fetch(pins);
            return true;
        }
        case 414: {
            pins = begin_fetch(pins);
            return true;
        }
        case 415: {
            pins = begin_fetch(pins);
            return true;
        }
        case 416: {
            pins = set_addr(pins, hl_post_inc());
            step_ = 2436;
            return true;
        }
        case 2436: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2437;
            return true;
        }
        case 2437: {
            step_ = 2438;
            return true;
        }
        case 2438: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2439;
            return true;
        }
        case 2439: {
            step_ = 2440;
            return true;
        }
        case 2440: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2441;
            return true;
        }
        case 2441: {
            pins = set_addr(pins, de_post_inc());
            step_ = 2442;
            return true;
        }
        case 2442: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2443;
            return true;
        }
        case 2443: {
            pins = set_data(pins, dlatch_);
            step_ = 2444;
            return true;
        }
        case 2444: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2445;
            return true;
        }
        case 2445: {
            step_ = 2446;
            return true;
        }
        case 2446: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2447;
            return true;
        }
        case 2447: {
            step_ = 2448;
            return true;
        }
        case 2448: {
            uint16_t bc_after = uint16_t(regs.bc() - 1); regs.set_bc(bc_after); regs.f = alu::ldi_ldd_flags(regs.a, dlatch_, bc_after, regs.f);
            step_ = 2449;
            return true;
        }
        case 2449: {
            step_ = 2450;
            return true;
        }
        case 2450: {
            step_ = 2451;
            return true;
        }
        case 2451: {
            pins = begin_fetch(pins);
            return true;
        }
        case 417: {
            pins = set_addr(pins, hl_post_inc());
            step_ = 2452;
            return true;
        }
        case 2452: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2453;
            return true;
        }
        case 2453: {
            step_ = 2454;
            return true;
        }
        case 2454: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2455;
            return true;
        }
        case 2455: {
            step_ = 2456;
            return true;
        }
        case 2456: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2457;
            return true;
        }
        case 2457: {
            step_ = 2458;
            return true;
        }
        case 2458: {
            regs.wz = uint16_t(regs.wz + 1); uint16_t bc_after = uint16_t(regs.bc() - 1); regs.set_bc(bc_after); auto r = alu::cpi_cpd(regs.a, dlatch_, bc_after, regs.f); regs.f = r.flags;
            step_ = 2459;
            return true;
        }
        case 2459: {
            step_ = 2460;
            return true;
        }
        case 2460: {
            step_ = 2461;
            return true;
        }
        case 2461: {
            step_ = 2462;
            return true;
        }
        case 2462: {
            step_ = 2463;
            return true;
        }
        case 2463: {
            step_ = 2464;
            return true;
        }
        case 2464: {
            step_ = 2465;
            return true;
        }
        case 2465: {
            step_ = 2466;
            return true;
        }
        case 2466: {
            step_ = 2467;
            return true;
        }
        case 2467: {
            pins = begin_fetch(pins);
            return true;
        }
        case 418: {
            step_ = 2468;
            return true;
        }
        case 2468: {
            step_ = 2469;
            return true;
        }
        case 2469: {
            pins = set_addr(pins, regs.bc());
            step_ = 2470;
            return true;
        }
        case 2470: {
            step_ = 2471;
            return true;
        }
        case 2471: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2472;
            return true;
        }
        case 2472: {
            step_ = 2473;
            return true;
        }
        case 2473: {
            step_ = 2474;
            return true;
        }
        case 2474: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2475;
            return true;
        }
        case 2475: {
            step_ = 2476;
            return true;
        }
        case 2476: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1); regs.b = uint8_t(regs.b - 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2477;
            return true;
        }
        case 2477: {
            pins = set_addr(pins, hl_post_inc());
            step_ = 2478;
            return true;
        }
        case 2478: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2479;
            return true;
        }
        case 2479: {
            pins = set_data(pins, dlatch_);
            step_ = 2480;
            return true;
        }
        case 2480: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.f = alu::ini_ind_flags(regs.b, dlatch_, uint8_t(regs.c + 1));
            step_ = 2481;
            return true;
        }
        case 2481: {
            step_ = 2482;
            return true;
        }
        case 2482: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2483;
            return true;
        }
        case 2483: {
            pins = begin_fetch(pins);
            return true;
        }
        case 419: {
            step_ = 2484;
            return true;
        }
        case 2484: {
            step_ = 2485;
            return true;
        }
        case 2485: {
            pins = set_addr(pins, hl_post_inc());
            step_ = 2486;
            return true;
        }
        case 2486: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2487;
            return true;
        }
        case 2487: {
            step_ = 2488;
            return true;
        }
        case 2488: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2489;
            return true;
        }
        case 2489: {
            step_ = 2490;
            return true;
        }
        case 2490: {
            dlatch_ = get_data(pins);
            regs.b = uint8_t(regs.b - 1);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2491;
            return true;
        }
        case 2491: {
            pins = set_addr(pins, regs.bc());
            step_ = 2492;
            return true;
        }
        case 2492: {
            step_ = 2493;
            return true;
        }
        case 2493: {
            pins = set_addr_data_assert(pins, get_addr(pins), dlatch_, IORQ | WR);
            step_ = 2494;
            return true;
        }
        case 2494: {
            step_ = 2495;
            return true;
        }
        case 2495: {
            step_ = 2496;
            return true;
        }
        case 2496: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2497;
            return true;
        }
        case 2497: {
            step_ = 2498;
            return true;
        }
        case 2498: {
            regs.wz = uint16_t(regs.bc() + 1); regs.f = alu::outi_outd_flags(regs.b, dlatch_, regs.l);
            pins = release_pins(pins, IORQ | WR);
            step_ = 2499;
            return true;
        }
        case 2499: {
            pins = begin_fetch(pins);
            return true;
        }
        case 420: {
            pins = begin_fetch(pins);
            return true;
        }
        case 421: {
            pins = begin_fetch(pins);
            return true;
        }
        case 422: {
            pins = begin_fetch(pins);
            return true;
        }
        case 423: {
            pins = begin_fetch(pins);
            return true;
        }
        case 424: {
            pins = set_addr(pins, hl_post_dec());
            step_ = 2500;
            return true;
        }
        case 2500: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2501;
            return true;
        }
        case 2501: {
            step_ = 2502;
            return true;
        }
        case 2502: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2503;
            return true;
        }
        case 2503: {
            step_ = 2504;
            return true;
        }
        case 2504: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2505;
            return true;
        }
        case 2505: {
            pins = set_addr(pins, de_post_dec());
            step_ = 2506;
            return true;
        }
        case 2506: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2507;
            return true;
        }
        case 2507: {
            pins = set_data(pins, dlatch_);
            step_ = 2508;
            return true;
        }
        case 2508: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2509;
            return true;
        }
        case 2509: {
            step_ = 2510;
            return true;
        }
        case 2510: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2511;
            return true;
        }
        case 2511: {
            step_ = 2512;
            return true;
        }
        case 2512: {
            uint16_t bc_after = uint16_t(regs.bc() - 1); regs.set_bc(bc_after); regs.f = alu::ldi_ldd_flags(regs.a, dlatch_, bc_after, regs.f);
            step_ = 2513;
            return true;
        }
        case 2513: {
            step_ = 2514;
            return true;
        }
        case 2514: {
            step_ = 2515;
            return true;
        }
        case 2515: {
            pins = begin_fetch(pins);
            return true;
        }
        case 425: {
            pins = set_addr(pins, hl_post_dec());
            step_ = 2516;
            return true;
        }
        case 2516: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2517;
            return true;
        }
        case 2517: {
            step_ = 2518;
            return true;
        }
        case 2518: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2519;
            return true;
        }
        case 2519: {
            step_ = 2520;
            return true;
        }
        case 2520: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2521;
            return true;
        }
        case 2521: {
            step_ = 2522;
            return true;
        }
        case 2522: {
            regs.wz = uint16_t(regs.wz - 1); uint16_t bc_after = uint16_t(regs.bc() - 1); regs.set_bc(bc_after); auto r = alu::cpi_cpd(regs.a, dlatch_, bc_after, regs.f); regs.f = r.flags;
            step_ = 2523;
            return true;
        }
        case 2523: {
            step_ = 2524;
            return true;
        }
        case 2524: {
            step_ = 2525;
            return true;
        }
        case 2525: {
            step_ = 2526;
            return true;
        }
        case 2526: {
            step_ = 2527;
            return true;
        }
        case 2527: {
            step_ = 2528;
            return true;
        }
        case 2528: {
            step_ = 2529;
            return true;
        }
        case 2529: {
            step_ = 2530;
            return true;
        }
        case 2530: {
            step_ = 2531;
            return true;
        }
        case 2531: {
            pins = begin_fetch(pins);
            return true;
        }
        case 426: {
            step_ = 2532;
            return true;
        }
        case 2532: {
            step_ = 2533;
            return true;
        }
        case 2533: {
            pins = set_addr(pins, regs.bc());
            step_ = 2534;
            return true;
        }
        case 2534: {
            step_ = 2535;
            return true;
        }
        case 2535: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2536;
            return true;
        }
        case 2536: {
            step_ = 2537;
            return true;
        }
        case 2537: {
            step_ = 2538;
            return true;
        }
        case 2538: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2539;
            return true;
        }
        case 2539: {
            step_ = 2540;
            return true;
        }
        case 2540: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() - 1); regs.b = uint8_t(regs.b - 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2541;
            return true;
        }
        case 2541: {
            pins = set_addr(pins, hl_post_dec());
            step_ = 2542;
            return true;
        }
        case 2542: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2543;
            return true;
        }
        case 2543: {
            pins = set_data(pins, dlatch_);
            step_ = 2544;
            return true;
        }
        case 2544: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.f = alu::ini_ind_flags(regs.b, dlatch_, uint8_t(regs.c - 1));
            step_ = 2545;
            return true;
        }
        case 2545: {
            step_ = 2546;
            return true;
        }
        case 2546: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2547;
            return true;
        }
        case 2547: {
            pins = begin_fetch(pins);
            return true;
        }
        case 427: {
            step_ = 2548;
            return true;
        }
        case 2548: {
            step_ = 2549;
            return true;
        }
        case 2549: {
            pins = set_addr(pins, hl_post_dec());
            step_ = 2550;
            return true;
        }
        case 2550: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2551;
            return true;
        }
        case 2551: {
            step_ = 2552;
            return true;
        }
        case 2552: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2553;
            return true;
        }
        case 2553: {
            step_ = 2554;
            return true;
        }
        case 2554: {
            dlatch_ = get_data(pins);
            regs.b = uint8_t(regs.b - 1);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2555;
            return true;
        }
        case 2555: {
            pins = set_addr(pins, regs.bc());
            step_ = 2556;
            return true;
        }
        case 2556: {
            step_ = 2557;
            return true;
        }
        case 2557: {
            pins = set_addr_data_assert(pins, get_addr(pins), dlatch_, IORQ | WR);
            step_ = 2558;
            return true;
        }
        case 2558: {
            step_ = 2559;
            return true;
        }
        case 2559: {
            step_ = 2560;
            return true;
        }
        case 2560: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2561;
            return true;
        }
        case 2561: {
            step_ = 2562;
            return true;
        }
        case 2562: {
            regs.wz = uint16_t(regs.bc() - 1); regs.f = alu::outi_outd_flags(regs.b, dlatch_, regs.l);
            pins = release_pins(pins, IORQ | WR);
            step_ = 2563;
            return true;
        }
        case 2563: {
            pins = begin_fetch(pins);
            return true;
        }
        case 428: {
            pins = begin_fetch(pins);
            return true;
        }
        case 429: {
            pins = begin_fetch(pins);
            return true;
        }
        case 430: {
            pins = begin_fetch(pins);
            return true;
        }
        case 431: {
            pins = begin_fetch(pins);
            return true;
        }
        case 432: {
            pins = set_addr(pins, hl_post_inc());
            step_ = 2564;
            return true;
        }
        case 2564: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2565;
            return true;
        }
        case 2565: {
            step_ = 2566;
            return true;
        }
        case 2566: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2567;
            return true;
        }
        case 2567: {
            step_ = 2568;
            return true;
        }
        case 2568: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2569;
            return true;
        }
        case 2569: {
            pins = set_addr(pins, de_post_inc());
            step_ = 2570;
            return true;
        }
        case 2570: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2571;
            return true;
        }
        case 2571: {
            pins = set_data(pins, dlatch_);
            step_ = 2572;
            return true;
        }
        case 2572: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2573;
            return true;
        }
        case 2573: {
            step_ = 2574;
            return true;
        }
        case 2574: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2575;
            return true;
        }
        case 2575: {
            step_ = 2576;
            return true;
        }
        case 2576: {
            uint16_t bc_after = uint16_t(regs.bc() - 1); regs.set_bc(bc_after); regs.f = alu::ldi_ldd_flags(regs.a, dlatch_, bc_after, regs.f); if (bc_after == 0) { step_ = 2587; return true; }
            step_ = 2577;
            return true;
        }
        case 2577: {
            step_ = 2578;
            return true;
        }
        case 2578: {
            step_ = 2579;
            return true;
        }
        case 2579: {
            step_ = 2580;
            return true;
        }
        case 2580: {
            regs.pc = uint16_t(regs.pc - 1); regs.wz = regs.pc; regs.pc = uint16_t(regs.pc - 1);
            step_ = 2581;
            return true;
        }
        case 2581: {
            step_ = 2582;
            return true;
        }
        case 2582: {
            step_ = 2583;
            return true;
        }
        case 2583: {
            step_ = 2584;
            return true;
        }
        case 2584: {
            step_ = 2585;
            return true;
        }
        case 2585: {
            step_ = 2586;
            return true;
        }
        case 2586: {
            step_ = 2587;
            return true;
        }
        case 2587: {
            step_ = 2588;
            return true;
        }
        case 2588: {
            step_ = 2589;
            return true;
        }
        case 2589: {
            pins = begin_fetch(pins);
            return true;
        }
        case 433: {
            pins = set_addr(pins, hl_post_inc());
            step_ = 2590;
            return true;
        }
        case 2590: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2591;
            return true;
        }
        case 2591: {
            step_ = 2592;
            return true;
        }
        case 2592: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2593;
            return true;
        }
        case 2593: {
            step_ = 2594;
            return true;
        }
        case 2594: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2595;
            return true;
        }
        case 2595: {
            step_ = 2596;
            return true;
        }
        case 2596: {
            regs.wz = uint16_t(regs.wz + 1); uint16_t bc_after = uint16_t(regs.bc() - 1); regs.set_bc(bc_after); auto r = alu::cpi_cpd(regs.a, dlatch_, bc_after, regs.f); regs.f = r.flags; if (!r.repeat) { step_ = 2607; return true; }
            step_ = 2597;
            return true;
        }
        case 2597: {
            step_ = 2598;
            return true;
        }
        case 2598: {
            step_ = 2599;
            return true;
        }
        case 2599: {
            step_ = 2600;
            return true;
        }
        case 2600: {
            step_ = 2601;
            return true;
        }
        case 2601: {
            step_ = 2602;
            return true;
        }
        case 2602: {
            step_ = 2603;
            return true;
        }
        case 2603: {
            step_ = 2604;
            return true;
        }
        case 2604: {
            step_ = 2605;
            return true;
        }
        case 2605: {
            step_ = 2606;
            return true;
        }
        case 2606: {
            regs.pc = uint16_t(regs.pc - 1); regs.wz = regs.pc; regs.pc = uint16_t(regs.pc - 1);
            step_ = 2607;
            return true;
        }
        case 2607: {
            step_ = 2608;
            return true;
        }
        case 2608: {
            step_ = 2609;
            return true;
        }
        case 2609: {
            step_ = 2610;
            return true;
        }
        case 2610: {
            step_ = 2611;
            return true;
        }
        case 2611: {
            step_ = 2612;
            return true;
        }
        case 2612: {
            step_ = 2613;
            return true;
        }
        case 2613: {
            step_ = 2614;
            return true;
        }
        case 2614: {
            step_ = 2615;
            return true;
        }
        case 2615: {
            pins = begin_fetch(pins);
            return true;
        }
        case 434: {
            step_ = 2616;
            return true;
        }
        case 2616: {
            step_ = 2617;
            return true;
        }
        case 2617: {
            pins = set_addr(pins, regs.bc());
            step_ = 2618;
            return true;
        }
        case 2618: {
            step_ = 2619;
            return true;
        }
        case 2619: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2620;
            return true;
        }
        case 2620: {
            step_ = 2621;
            return true;
        }
        case 2621: {
            step_ = 2622;
            return true;
        }
        case 2622: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2623;
            return true;
        }
        case 2623: {
            step_ = 2624;
            return true;
        }
        case 2624: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() + 1); regs.b = uint8_t(regs.b - 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2625;
            return true;
        }
        case 2625: {
            pins = set_addr(pins, hl_post_inc());
            step_ = 2626;
            return true;
        }
        case 2626: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2627;
            return true;
        }
        case 2627: {
            pins = set_data(pins, dlatch_);
            step_ = 2628;
            return true;
        }
        case 2628: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.f = alu::ini_ind_flags(regs.b, dlatch_, uint8_t(regs.c + 1)); if (regs.b == 0) { pins = release_pins(pins, MREQ | WR); step_ = 2639; return true; }
            step_ = 2629;
            return true;
        }
        case 2629: {
            step_ = 2630;
            return true;
        }
        case 2630: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2631;
            return true;
        }
        case 2631: {
            step_ = 2632;
            return true;
        }
        case 2632: {
            regs.pc = uint16_t(regs.pc - 1); regs.wz = regs.pc; regs.pc = uint16_t(regs.pc - 1);
            step_ = 2633;
            return true;
        }
        case 2633: {
            step_ = 2634;
            return true;
        }
        case 2634: {
            step_ = 2635;
            return true;
        }
        case 2635: {
            step_ = 2636;
            return true;
        }
        case 2636: {
            step_ = 2637;
            return true;
        }
        case 2637: {
            step_ = 2638;
            return true;
        }
        case 2638: {
            step_ = 2639;
            return true;
        }
        case 2639: {
            step_ = 2640;
            return true;
        }
        case 2640: {
            step_ = 2641;
            return true;
        }
        case 2641: {
            pins = begin_fetch(pins);
            return true;
        }
        case 435: {
            step_ = 2642;
            return true;
        }
        case 2642: {
            step_ = 2643;
            return true;
        }
        case 2643: {
            pins = set_addr(pins, hl_post_inc());
            step_ = 2644;
            return true;
        }
        case 2644: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2645;
            return true;
        }
        case 2645: {
            step_ = 2646;
            return true;
        }
        case 2646: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2647;
            return true;
        }
        case 2647: {
            step_ = 2648;
            return true;
        }
        case 2648: {
            dlatch_ = get_data(pins);
            regs.b = uint8_t(regs.b - 1);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2649;
            return true;
        }
        case 2649: {
            pins = set_addr(pins, regs.bc());
            step_ = 2650;
            return true;
        }
        case 2650: {
            step_ = 2651;
            return true;
        }
        case 2651: {
            pins = set_addr_data_assert(pins, get_addr(pins), dlatch_, IORQ | WR);
            step_ = 2652;
            return true;
        }
        case 2652: {
            step_ = 2653;
            return true;
        }
        case 2653: {
            step_ = 2654;
            return true;
        }
        case 2654: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2655;
            return true;
        }
        case 2655: {
            step_ = 2656;
            return true;
        }
        case 2656: {
            regs.wz = uint16_t(regs.bc() + 1); regs.f = alu::outi_outd_flags(regs.b, dlatch_, regs.l); if (regs.b == 0) { pins = release_pins(pins, IORQ | WR); step_ = 2667; return true; }
            pins = release_pins(pins, IORQ | WR);
            step_ = 2657;
            return true;
        }
        case 2657: {
            step_ = 2658;
            return true;
        }
        case 2658: {
            regs.pc = uint16_t(regs.pc - 1); regs.wz = regs.pc; regs.pc = uint16_t(regs.pc - 1);
            step_ = 2659;
            return true;
        }
        case 2659: {
            step_ = 2660;
            return true;
        }
        case 2660: {
            step_ = 2661;
            return true;
        }
        case 2661: {
            step_ = 2662;
            return true;
        }
        case 2662: {
            step_ = 2663;
            return true;
        }
        case 2663: {
            step_ = 2664;
            return true;
        }
        case 2664: {
            step_ = 2665;
            return true;
        }
        case 2665: {
            step_ = 2666;
            return true;
        }
        case 2666: {
            step_ = 2667;
            return true;
        }
        case 2667: {
            pins = begin_fetch(pins);
            return true;
        }
        case 436: {
            pins = begin_fetch(pins);
            return true;
        }
        case 437: {
            pins = begin_fetch(pins);
            return true;
        }
        case 438: {
            pins = begin_fetch(pins);
            return true;
        }
        case 439: {
            pins = begin_fetch(pins);
            return true;
        }
        case 440: {
            pins = set_addr(pins, hl_post_dec());
            step_ = 2668;
            return true;
        }
        case 2668: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2669;
            return true;
        }
        case 2669: {
            step_ = 2670;
            return true;
        }
        case 2670: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2671;
            return true;
        }
        case 2671: {
            step_ = 2672;
            return true;
        }
        case 2672: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2673;
            return true;
        }
        case 2673: {
            pins = set_addr(pins, de_post_dec());
            step_ = 2674;
            return true;
        }
        case 2674: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2675;
            return true;
        }
        case 2675: {
            pins = set_data(pins, dlatch_);
            step_ = 2676;
            return true;
        }
        case 2676: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2677;
            return true;
        }
        case 2677: {
            step_ = 2678;
            return true;
        }
        case 2678: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2679;
            return true;
        }
        case 2679: {
            step_ = 2680;
            return true;
        }
        case 2680: {
            uint16_t bc_after = uint16_t(regs.bc() - 1); regs.set_bc(bc_after); regs.f = alu::ldi_ldd_flags(regs.a, dlatch_, bc_after, regs.f); if (bc_after == 0) { step_ = 2691; return true; }
            step_ = 2681;
            return true;
        }
        case 2681: {
            step_ = 2682;
            return true;
        }
        case 2682: {
            step_ = 2683;
            return true;
        }
        case 2683: {
            step_ = 2684;
            return true;
        }
        case 2684: {
            regs.pc = uint16_t(regs.pc - 1); regs.wz = regs.pc; regs.pc = uint16_t(regs.pc - 1);
            step_ = 2685;
            return true;
        }
        case 2685: {
            step_ = 2686;
            return true;
        }
        case 2686: {
            step_ = 2687;
            return true;
        }
        case 2687: {
            step_ = 2688;
            return true;
        }
        case 2688: {
            step_ = 2689;
            return true;
        }
        case 2689: {
            step_ = 2690;
            return true;
        }
        case 2690: {
            step_ = 2691;
            return true;
        }
        case 2691: {
            step_ = 2692;
            return true;
        }
        case 2692: {
            step_ = 2693;
            return true;
        }
        case 2693: {
            pins = begin_fetch(pins);
            return true;
        }
        case 441: {
            pins = set_addr(pins, hl_post_dec());
            step_ = 2694;
            return true;
        }
        case 2694: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2695;
            return true;
        }
        case 2695: {
            step_ = 2696;
            return true;
        }
        case 2696: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2697;
            return true;
        }
        case 2697: {
            step_ = 2698;
            return true;
        }
        case 2698: {
            dlatch_ = get_data(pins);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2699;
            return true;
        }
        case 2699: {
            step_ = 2700;
            return true;
        }
        case 2700: {
            regs.wz = uint16_t(regs.wz - 1); uint16_t bc_after = uint16_t(regs.bc() - 1); regs.set_bc(bc_after); auto r = alu::cpi_cpd(regs.a, dlatch_, bc_after, regs.f); regs.f = r.flags; if (!r.repeat) { step_ = 2711; return true; }
            step_ = 2701;
            return true;
        }
        case 2701: {
            step_ = 2702;
            return true;
        }
        case 2702: {
            step_ = 2703;
            return true;
        }
        case 2703: {
            step_ = 2704;
            return true;
        }
        case 2704: {
            step_ = 2705;
            return true;
        }
        case 2705: {
            step_ = 2706;
            return true;
        }
        case 2706: {
            step_ = 2707;
            return true;
        }
        case 2707: {
            step_ = 2708;
            return true;
        }
        case 2708: {
            step_ = 2709;
            return true;
        }
        case 2709: {
            step_ = 2710;
            return true;
        }
        case 2710: {
            regs.pc = uint16_t(regs.pc - 1); regs.wz = regs.pc; regs.pc = uint16_t(regs.pc - 1);
            step_ = 2711;
            return true;
        }
        case 2711: {
            step_ = 2712;
            return true;
        }
        case 2712: {
            step_ = 2713;
            return true;
        }
        case 2713: {
            step_ = 2714;
            return true;
        }
        case 2714: {
            step_ = 2715;
            return true;
        }
        case 2715: {
            step_ = 2716;
            return true;
        }
        case 2716: {
            step_ = 2717;
            return true;
        }
        case 2717: {
            step_ = 2718;
            return true;
        }
        case 2718: {
            step_ = 2719;
            return true;
        }
        case 2719: {
            pins = begin_fetch(pins);
            return true;
        }
        case 442: {
            step_ = 2720;
            return true;
        }
        case 2720: {
            step_ = 2721;
            return true;
        }
        case 2721: {
            pins = set_addr(pins, regs.bc());
            step_ = 2722;
            return true;
        }
        case 2722: {
            step_ = 2723;
            return true;
        }
        case 2723: {
            pins = set_addr_assert(pins, get_addr(pins), IORQ | RD);
            step_ = 2724;
            return true;
        }
        case 2724: {
            step_ = 2725;
            return true;
        }
        case 2725: {
            step_ = 2726;
            return true;
        }
        case 2726: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2727;
            return true;
        }
        case 2727: {
            step_ = 2728;
            return true;
        }
        case 2728: {
            dlatch_ = get_data(pins);
            regs.wz = uint16_t(regs.bc() - 1); regs.b = uint8_t(regs.b - 1);
            pins = release_pins(pins, IORQ | RD);
            step_ = 2729;
            return true;
        }
        case 2729: {
            pins = set_addr(pins, hl_post_dec());
            step_ = 2730;
            return true;
        }
        case 2730: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2731;
            return true;
        }
        case 2731: {
            pins = set_data(pins, dlatch_);
            step_ = 2732;
            return true;
        }
        case 2732: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            regs.f = alu::ini_ind_flags(regs.b, dlatch_, uint8_t(regs.c - 1)); if (regs.b == 0) { pins = release_pins(pins, MREQ | WR); step_ = 2743; return true; }
            step_ = 2733;
            return true;
        }
        case 2733: {
            step_ = 2734;
            return true;
        }
        case 2734: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2735;
            return true;
        }
        case 2735: {
            step_ = 2736;
            return true;
        }
        case 2736: {
            regs.pc = uint16_t(regs.pc - 1); regs.wz = regs.pc; regs.pc = uint16_t(regs.pc - 1);
            step_ = 2737;
            return true;
        }
        case 2737: {
            step_ = 2738;
            return true;
        }
        case 2738: {
            step_ = 2739;
            return true;
        }
        case 2739: {
            step_ = 2740;
            return true;
        }
        case 2740: {
            step_ = 2741;
            return true;
        }
        case 2741: {
            step_ = 2742;
            return true;
        }
        case 2742: {
            step_ = 2743;
            return true;
        }
        case 2743: {
            step_ = 2744;
            return true;
        }
        case 2744: {
            step_ = 2745;
            return true;
        }
        case 2745: {
            pins = begin_fetch(pins);
            return true;
        }
        case 443: {
            step_ = 2746;
            return true;
        }
        case 2746: {
            step_ = 2747;
            return true;
        }
        case 2747: {
            pins = set_addr(pins, hl_post_dec());
            step_ = 2748;
            return true;
        }
        case 2748: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2749;
            return true;
        }
        case 2749: {
            step_ = 2750;
            return true;
        }
        case 2750: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2751;
            return true;
        }
        case 2751: {
            step_ = 2752;
            return true;
        }
        case 2752: {
            dlatch_ = get_data(pins);
            regs.b = uint8_t(regs.b - 1);
            pins = release_pins(pins, MREQ | RD);
            step_ = 2753;
            return true;
        }
        case 2753: {
            pins = set_addr(pins, regs.bc());
            step_ = 2754;
            return true;
        }
        case 2754: {
            step_ = 2755;
            return true;
        }
        case 2755: {
            pins = set_addr_data_assert(pins, get_addr(pins), dlatch_, IORQ | WR);
            step_ = 2756;
            return true;
        }
        case 2756: {
            step_ = 2757;
            return true;
        }
        case 2757: {
            step_ = 2758;
            return true;
        }
        case 2758: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2759;
            return true;
        }
        case 2759: {
            step_ = 2760;
            return true;
        }
        case 2760: {
            regs.wz = uint16_t(regs.bc() - 1); regs.f = alu::outi_outd_flags(regs.b, dlatch_, regs.l); if (regs.b == 0) { pins = release_pins(pins, IORQ | WR); step_ = 2771; return true; }
            pins = release_pins(pins, IORQ | WR);
            step_ = 2761;
            return true;
        }
        case 2761: {
            step_ = 2762;
            return true;
        }
        case 2762: {
            regs.pc = uint16_t(regs.pc - 1); regs.wz = regs.pc; regs.pc = uint16_t(regs.pc - 1);
            step_ = 2763;
            return true;
        }
        case 2763: {
            step_ = 2764;
            return true;
        }
        case 2764: {
            step_ = 2765;
            return true;
        }
        case 2765: {
            step_ = 2766;
            return true;
        }
        case 2766: {
            step_ = 2767;
            return true;
        }
        case 2767: {
            step_ = 2768;
            return true;
        }
        case 2768: {
            step_ = 2769;
            return true;
        }
        case 2769: {
            step_ = 2770;
            return true;
        }
        case 2770: {
            step_ = 2771;
            return true;
        }
        case 2771: {
            pins = begin_fetch(pins);
            return true;
        }
        case 444: {
            pins = begin_fetch(pins);
            return true;
        }
        case 445: {
            pins = begin_fetch(pins);
            return true;
        }
        case 446: {
            pins = begin_fetch(pins);
            return true;
        }
        case 447: {
            pins = begin_fetch(pins);
            return true;
        }
        case 448: {
            pins = begin_fetch(pins);
            return true;
        }
        case 449: {
            pins = begin_fetch(pins);
            return true;
        }
        case 450: {
            pins = begin_fetch(pins);
            return true;
        }
        case 451: {
            pins = begin_fetch(pins);
            return true;
        }
        case 452: {
            pins = begin_fetch(pins);
            return true;
        }
        case 453: {
            pins = begin_fetch(pins);
            return true;
        }
        case 454: {
            pins = begin_fetch(pins);
            return true;
        }
        case 455: {
            pins = begin_fetch(pins);
            return true;
        }
        case 456: {
            pins = begin_fetch(pins);
            return true;
        }
        case 457: {
            pins = begin_fetch(pins);
            return true;
        }
        case 458: {
            pins = begin_fetch(pins);
            return true;
        }
        case 459: {
            pins = begin_fetch(pins);
            return true;
        }
        case 460: {
            pins = begin_fetch(pins);
            return true;
        }
        case 461: {
            pins = begin_fetch(pins);
            return true;
        }
        case 462: {
            pins = begin_fetch(pins);
            return true;
        }
        case 463: {
            pins = begin_fetch(pins);
            return true;
        }
        case 464: {
            pins = begin_fetch(pins);
            return true;
        }
        case 465: {
            pins = begin_fetch(pins);
            return true;
        }
        case 466: {
            pins = begin_fetch(pins);
            return true;
        }
        case 467: {
            pins = begin_fetch(pins);
            return true;
        }
        case 468: {
            pins = begin_fetch(pins);
            return true;
        }
        case 469: {
            pins = begin_fetch(pins);
            return true;
        }
        case 470: {
            pins = begin_fetch(pins);
            return true;
        }
        case 471: {
            pins = begin_fetch(pins);
            return true;
        }
        case 472: {
            pins = begin_fetch(pins);
            return true;
        }
        case 473: {
            pins = begin_fetch(pins);
            return true;
        }
        case 474: {
            pins = begin_fetch(pins);
            return true;
        }
        case 475: {
            pins = begin_fetch(pins);
            return true;
        }
        case 476: {
            pins = begin_fetch(pins);
            return true;
        }
        case 477: {
            pins = begin_fetch(pins);
            return true;
        }
        case 478: {
            pins = begin_fetch(pins);
            return true;
        }
        case 479: {
            pins = begin_fetch(pins);
            return true;
        }
        case 480: {
            pins = begin_fetch(pins);
            return true;
        }
        case 481: {
            pins = begin_fetch(pins);
            return true;
        }
        case 482: {
            pins = begin_fetch(pins);
            return true;
        }
        case 483: {
            pins = begin_fetch(pins);
            return true;
        }
        case 484: {
            pins = begin_fetch(pins);
            return true;
        }
        case 485: {
            pins = begin_fetch(pins);
            return true;
        }
        case 486: {
            pins = begin_fetch(pins);
            return true;
        }
        case 487: {
            pins = begin_fetch(pins);
            return true;
        }
        case 488: {
            pins = begin_fetch(pins);
            return true;
        }
        case 489: {
            pins = begin_fetch(pins);
            return true;
        }
        case 490: {
            pins = begin_fetch(pins);
            return true;
        }
        case 491: {
            pins = begin_fetch(pins);
            return true;
        }
        case 492: {
            pins = begin_fetch(pins);
            return true;
        }
        case 493: {
            pins = begin_fetch(pins);
            return true;
        }
        case 494: {
            pins = begin_fetch(pins);
            return true;
        }
        case 495: {
            pins = begin_fetch(pins);
            return true;
        }
        case 496: {
            pins = begin_fetch(pins);
            return true;
        }
        case 497: {
            pins = begin_fetch(pins);
            return true;
        }
        case 498: {
            pins = begin_fetch(pins);
            return true;
        }
        case 499: {
            pins = begin_fetch(pins);
            return true;
        }
        case 500: {
            pins = begin_fetch(pins);
            return true;
        }
        case 501: {
            pins = begin_fetch(pins);
            return true;
        }
        case 502: {
            pins = begin_fetch(pins);
            return true;
        }
        case 503: {
            pins = begin_fetch(pins);
            return true;
        }
        case 504: {
            pins = begin_fetch(pins);
            return true;
        }
        case 505: {
            pins = begin_fetch(pins);
            return true;
        }
        case 506: {
            pins = begin_fetch(pins);
            return true;
        }
        case 507: {
            pins = begin_fetch(pins);
            return true;
        }
        case 508: {
            pins = begin_fetch(pins);
            return true;
        }
        case 509: {
            pins = begin_fetch(pins);
            return true;
        }
        case 510: {
            pins = begin_fetch(pins);
            return true;
        }
        case 511: {
            pins = begin_fetch(pins);
            return true;
        }
        case 2772: {
            uint8_t cb_z = uint8_t(opcode_ & 7); uint8_t cb_val = get_reg8_plain(cb_z); uint8_t cb_out; if (cb_action(cb_val, false, &cb_out)) { set_reg8_plain(cb_z, cb_out); }
            pins = begin_fetch(pins);
            return true;
        }
        case 2773: {
            pins = set_addr(pins, regs.hl());
            step_ = 2774;
            return true;
        }
        case 2774: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ | RD);
            step_ = 2775;
            return true;
        }
        case 2775: {
            step_ = 2776;
            return true;
        }
        case 2776: {
            if (asserted(pins, WAIT)) { return true; }
            step_ = 2777;
            return true;
        }
        case 2777: {
            step_ = 2778;
            return true;
        }
        case 2778: {
            dlatch_ = get_data(pins);
            uint8_t cb_out; if (cb_action(dlatch_, true, &cb_out)) { dlatch_ = cb_out; } else { pins = release_pins(pins, MREQ | RD); step_ = 2785; return true; }
            pins = release_pins(pins, MREQ | RD);
            step_ = 2779;
            return true;
        }
        case 2779: {
            step_ = 2780;
            return true;
        }
        case 2780: {
            step_ = 2781;
            return true;
        }
        case 2781: {
            pins = set_addr(pins, regs.hl());
            step_ = 2782;
            return true;
        }
        case 2782: {
            pins = set_addr_assert(pins, get_addr(pins), MREQ);
            step_ = 2783;
            return true;
        }
        case 2783: {
            pins = set_data(pins, dlatch_);
            step_ = 2784;
            return true;
        }
        case 2784: {
            if (asserted(pins, WAIT)) { return true; }
            pins = assert_pins(pins, WR);
            step_ = 2785;
            return true;
        }
        case 2785: {
            step_ = 2786;
            return true;
        }
        case 2786: {
            pins = release_pins(pins, MREQ | WR);
            step_ = 2787;
            return true;
        }
        case 2787: {
            pins = begin_fetch(pins);
            return true;
        }
