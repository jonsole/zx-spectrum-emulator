; Unit tests for depth.s, in Z80, run on the C++ core by run_tests.py.
;
; This assembles depth.s on its own, with nothing else of the engine. The
; checking and printing are harness.s, which every suite shares.
;
; Records live at REC_1 onwards, one ROOM_STRIDE apart as in the real pool, and
; the run from REC_2 to REC_3 crosses a page. Lists are built by make_list and
; checked by expect_list, neither of which uses the code under test, so a test
; of depth_insert does not lean on depth_unlink being right or the other way
; round.

					ORG		$0100
					INCLUDE	"harness.s"

REC_1				EQU		$C0C0
REC_2				EQU		$C0E0
REC_3				EQU		$C100		; the page boundary is between 2 and 3
REC_4				EQU		$C120
REC_5				EQU		$C140
REC_6				EQU		$C160

; Where every test box stands on the axes it is not being tested on: V and Z
; the same for all of them, so that only U separates.
;
; depth_cmp compares unsigned, as the castle's coordinates never come near
; either end of a byte. So no box here reaches below 0 or past 255 either: a
; box at U = 0 with a half-width of 4 would have its low edge at $FC.
V0					EQU		50
Z0					EQU		0
HALF				EQU		4		; SIZE_U and SIZE_V are half-widths
TALL				EQU		10		; SIZE_Z is a height

					INCLUDE	"../engine/object_struct.s"


; ---------------------------------------------------------------------------
; Depth's own fixtures.

; A record's position and extent, with NEXT and PREV cleared.
					MACRO	BOX rec, u, v, z, su, sv, sz
					ld		ix,rec
					call	box
					DB		u, v, z, su, sv, sz
					ENDM

; The simple box: U alone varies.
					MACRO	BOX_U rec, u
					BOX		rec, u, V0, Z0, HALF, HALF, TALL
					ENDM

; Step IX by a signed step in U, V and Z, through depth_step.
					MACRO	STEP du, dv, dz
					ld		de,(((du) & $FF) << 8) | ((dv) & $FF)
					ld		a,(dz) & $FF
					call	depth_step
					ENDM

; The same through depth_step_upper, with HL already naming the lower half.
					MACRO	STEP_UPPER du, dv, dz
					ld		de,(((du) & $FF) << 8) | ((dv) & $FF)
					ld		a,(dz) & $FF
					call	depth_step_upper
					ENDM

start:				ld		sp,$FE00

; --- depth_unlink ----------------------------------------------------------

					TEST	"unlink from the middle"
					call	three_in_a_row
					ld		ix,REC_2
					ld		a,$5A
					call	depth_unlink
					call	snap
					call	expect_list
					DW		REC_1, REC_3, 0
					EXPECT_WORD	s_de, REC_1, "DE, the field that named it"
					EXPECT_A	$5A, "A"

					TEST	"unlink the head"
					call	three_in_a_row
					ld		ix,REC_1
					ld		a,$A5
					call	depth_unlink
					call	snap
					call	expect_list
					DW		REC_2, REC_3, 0
					EXPECT_WORD	s_de, object_list, "DE, the field that named it"
					EXPECT_A	$A5, "A"

					TEST	"unlink the tail"
					call	three_in_a_row
					ld		ix,REC_3
					ld		a,$3C
					call	depth_unlink
					call	snap
					call	expect_list
					DW		REC_1, REC_2, 0
					EXPECT_WORD	s_de, REC_2, "DE, the field that named it"
					EXPECT_A	$3C, "A"
					EXPECT_WORD	OBJ.PREV, 0, "nothing written through a null NEXT"

					TEST	"unlink the only one"
					BOX_U	REC_3, 40
					call	make_list
					DW		REC_3, 0
					ld		ix,REC_3
					ld		a,$C3
					call	depth_unlink
					call	snap
					call	expect_list
					DW		0
					EXPECT_WORD	s_de, object_list, "DE, the field that named it"
					EXPECT_A	$C3, "A"

; --- depth_cmp -------------------------------------------------------------
; Out: carry set when the object in IX is further than the one in IY, and A
; zero when every separating axis agrees on that.

					TEST	"cmp: nearer along U"
					BOX_U	REC_1, 40
					BOX_U	REC_2, 20
					call	compare_1_with_2
					EXPECT_CARRY	0, "carry"
					EXPECT_A	0, "A, certain"

					TEST	"cmp: further along U"
					BOX_U	REC_1, 20
					BOX_U	REC_2, 40
					call	compare_1_with_2
					EXPECT_CARRY	1, "carry"
					EXPECT_A	0, "A, certain"

					TEST	"cmp: nearer for a lower V"
					BOX		REC_1, 40, 20, Z0, HALF, HALF, TALL
					BOX		REC_2, 40, 40, Z0, HALF, HALF, TALL
					call	compare_1_with_2
					EXPECT_CARRY	0, "carry"
					EXPECT_A	0, "A, certain"

					TEST	"cmp: further for a higher V"
					BOX		REC_1, 40, 40, Z0, HALF, HALF, TALL
					BOX		REC_2, 40, 20, Z0, HALF, HALF, TALL
					call	compare_1_with_2
					EXPECT_CARRY	1, "carry"
					EXPECT_A	0, "A, certain"

					TEST	"cmp: nearer standing on top"
					BOX		REC_1, 40, V0, 20, HALF, HALF, TALL
					BOX		REC_2, 40, V0, 0, HALF, HALF, TALL
					call	compare_1_with_2
					EXPECT_CARRY	0, "carry"
					EXPECT_A	0, "A, certain"

					TEST	"cmp: further underneath"
					BOX		REC_1, 40, V0, 0, HALF, HALF, TALL
					BOX		REC_2, 40, V0, 20, HALF, HALF, TALL
					call	compare_1_with_2
					EXPECT_CARRY	1, "carry"
					EXPECT_A	0, "A, certain"

					TEST	"cmp: a zero-height box on top"
					BOX		REC_1, 40, V0, 10, HALF, HALF, 0
					BOX		REC_2, 40, V0, 0, HALF, HALF, TALL
					call	compare_1_with_2
					EXPECT_CARRY	0, "carry"
					EXPECT_A	0, "A, certain"

					TEST	"cmp: two axes agreeing"
					BOX		REC_1, 40, V0, 20, HALF, HALF, TALL
					BOX		REC_2, 20, V0, 0, HALF, HALF, TALL
					call	compare_1_with_2
					EXPECT_CARRY	0, "carry"
					EXPECT_A	0, "A, certain"

					TEST	"cmp: axes disagreeing, sum says further"
					BOX		REC_1, 60, 100, Z0, HALF, HALF, TALL	; U +40, V -60
					BOX		REC_2, 20, 40, Z0, HALF, HALF, TALL
					call	compare_1_with_2
					EXPECT_CARRY	1, "carry"
					EXPECT_A	1, "A, a guess"

					TEST	"cmp: axes disagreeing, sum says nearer"
					BOX		REC_1, 100, 100, Z0, HALF, HALF, TALL	; U +80, V -60
					BOX		REC_2, 20, 40, Z0, HALF, HALF, TALL
					call	compare_1_with_2
					EXPECT_CARRY	0, "carry"
					EXPECT_A	1, "A, a guess"

					; The knight's body over a table he is pushing: above it by
					; more than it is behind it, which the old sum -- Z counted --
					; called nearer. Z votes but does not count.
					TEST	"cmp: above and behind, the floor decides"
					BOX		REC_1, 101, 112, 140, 5, 5, 11		; U -11, Z +12
					BOX		REC_2, 112, 106, 128, 6, 10, 12
					call	compare_1_with_2
					EXPECT_CARRY	1, "carry"
					EXPECT_A	1, "A, a guess"

					TEST	"cmp: interpenetrating"
					BOX_U	REC_1, 40
					BOX_U	REC_2, 42
					call	compare_1_with_2
					EXPECT_CARRY	0, "carry"
					EXPECT_A	1, "A, a guess"

; --- depth_insert and background_insert ------------------------------------

					TEST	"insert into an empty list"
					call	make_list
					DW		0
					BOX_U	REC_2, 40
					call	depth_insert
					call	expect_list
					DW		REC_2, 0
					EXPECT_WORD	sort_head, object_list, "sort_head"

					TEST	"insert further, then nearer"
					call	make_list
					DW		0
					BOX_U	REC_2, 40
					call	depth_insert
					BOX_U	REC_1, 20
					call	depth_insert
					BOX_U	REC_3, 60
					call	depth_insert
					call	expect_list
					DW		REC_1, REC_2, REC_3, 0

					TEST	"insert between two"
					BOX_U	REC_1, 20
					BOX_U	REC_3, 60
					call	make_list
					DW		REC_1, REC_3, 0
					BOX_U	REC_2, 40
					call	depth_insert
					call	expect_list
					DW		REC_1, REC_2, REC_3, 0

					TEST	"background stays in front of the sort"
					call	make_list
					DW		0
					BOX_U	REC_4, 100
					call	background_insert
					BOX_U	REC_1, 20
					call	depth_insert
					call	expect_list
					DW		REC_4, REC_1, 0
					EXPECT_WORD	sort_head, REC_4, "sort_head"

; --- depth_in_order ----------------------------------------------------------
; Out: carry set when still in order; otherwise A is 0 for belongs earlier and
; 1 for belongs later.

					TEST	"in order: unmoved"
					call	three_in_a_row
					ld		ix,REC_2
					call	check_order
					EXPECT_CARRY	1, "carry"

					TEST	"in order: moved past the next"
					call	three_in_a_row
					ld		ix,REC_2
					ld		(ix+OBJ.U),80
					call	check_order
					EXPECT_CARRY	0, "carry"
					EXPECT_A	1, "A, belongs later"

					TEST	"in order: moved past the previous"
					call	three_in_a_row
					ld		ix,REC_2
					ld		(ix+OBJ.U),8
					call	check_order
					EXPECT_CARRY	0, "carry"
					EXPECT_A	0, "A, belongs earlier"

					TEST	"in order: the head, moved but not past"
					call	three_in_a_row
					ld		ix,REC_1
					ld		(ix+OBJ.U),30
					call	check_order
					EXPECT_CARRY	1, "carry"

					TEST	"in order: the tail, moved but not past"
					call	three_in_a_row
					ld		ix,REC_3
					ld		(ix+OBJ.U),50
					call	check_order
					EXPECT_CARRY	1, "carry"

; --- depth_step and depth_relink ---------------------------------------------
; depth_step adds the step and re-sorts only when it is not zero, falling into
; depth_relink. depth_step_upper does the same but scans from after HL.

					TEST	"step: zero leaves the list alone"
					call	three_in_a_row
					ld		ix,REC_2
					ld		(ix+OBJ.U),80		; out of order, but nothing
					STEP	0, 0, 0		; stepped, so nothing is asked
					call	expect_list
					DW		REC_1, REC_2, REC_3, 0
					EXPECT_BYTE	REC_2 + OBJ.U, 80, "U"

					TEST	"step: adds to U, V and Z"
					call	three_in_a_row
					ld		ix,REC_2
					STEP	1, 2, 3
					EXPECT_BYTE	REC_2 + OBJ.U, 41, "U"
					EXPECT_BYTE	REC_2 + OBJ.V, V0 + 2, "V"
					EXPECT_BYTE	REC_2 + OBJ.Z, Z0 + 3, "Z"
					call	expect_list
					DW		REC_1, REC_2, REC_3, 0

					TEST	"step: along V alone re-sorts"
					BOX		REC_1, 40, 40, Z0, HALF, HALF, TALL
					BOX		REC_2, 40, 60, Z0, HALF, HALF, TALL
					call	make_list
					DW		REC_2, REC_1, 0
					ld		ix,REC_1
					STEP	0, 40, 0		; V 40 -> 80: now the further
					call	expect_list
					DW		REC_1, REC_2, 0

					TEST	"step: along Z alone re-sorts"
					BOX		REC_1, 40, V0, 0, HALF, HALF, TALL
					BOX		REC_2, 40, V0, 20, HALF, HALF, TALL
					call	make_list
					DW		REC_1, REC_2, 0
					ld		ix,REC_1
					STEP	0, 0, 40		; Z 0 -> 40: now on top
					call	expect_list
					DW		REC_2, REC_1, 0

					TEST	"step: moved later"
					call	three_in_a_row
					ld		ix,REC_2
					STEP	40, 0, 0		; U 40 -> 80
					call	expect_list
					DW		REC_1, REC_3, REC_2, 0

					TEST	"step: moved later, not to the end"
					call	four_in_a_row
					ld		ix,REC_1
					STEP	30, 0, 0		; U 20 -> 50
					call	expect_list
					DW		REC_2, REC_1, REC_3, REC_4, 0

					TEST	"step: the tail moved to the front"
					call	three_in_a_row
					ld		ix,REC_3
					STEP	-52, 0, 0		; U 60 -> 8
					call	expect_list
					DW		REC_3, REC_1, REC_2, 0

					TEST	"step: moved earlier, from the middle"
					call	four_in_a_row
					ld		ix,REC_3
					STEP	-30, 0, 0		; U 60 -> 30
					call	expect_list
					DW		REC_1, REC_3, REC_2, REC_4, 0

					TEST	"step: moved, not past anyone"
					call	three_in_a_row
					ld		ix,REC_2
					STEP	6, 0, 0		; U 40 -> 46, still short of REC_3
					call	expect_list
					DW		REC_1, REC_2, REC_3, 0

					TEST	"upper: scans from after the lower half"
					call	four_in_a_row
					ld		hl,REC_2		; told to look after REC_2...
					ld		ix,REC_3
					STEP_UPPER	-30, 0, 0		; ...though U 30 belongs before it
					call	expect_list
					DW		REC_1, REC_2, REC_3, REC_4, 0

					TEST	"upper: moved later, from after the lower half"
					call	four_in_a_row
					ld		hl,REC_1
					ld		ix,REC_2
					STEP_UPPER	30, 0, 0		; U 40 -> 70, between REC_3 and REC_4
					call	expect_list
					DW		REC_1, REC_3, REC_2, REC_4, 0

					TEST	"upper: moved, not past anyone"
					call	four_in_a_row
					ld		hl,REC_1
					ld		ix,REC_2
					STEP_UPPER	6, 0, 0		; U 40 -> 46
					call	expect_list
					DW		REC_1, REC_2, REC_3, REC_4, 0

					; Room $38, as it was drawn wrong: the knight stepped down off a
					; block, his legs re-sorted in front of it, and his body's own
					; neighbours are two blocks the axes disagree about -- which guess
					; it in order. The block left between the halves is certainly
					; nearer than the body.
					TEST	"upper: past a nearer one left between the halves"
					BOX		REC_1, 102, 183, 152, 5, 5, 12		; the legs
					BOX		REC_2, 104, 168, 164, 8, 8, 12		; the block
					BOX		REC_3, 141, 196, 128, 3, 5, 40		; an arch leaf
					BOX		REC_4, 104, 152, 128, 6, 6, 12		; a block below
					BOX		REC_5, 102, 182, 164, 5, 5, 12		; the body, a unit short
					BOX		REC_6, 104, 136, 128, 6, 6, 12		; another block below
					call	make_list
					DW		REC_1, REC_2, REC_3, REC_4, REC_5, REC_6, 0
					ld		hl,REC_1
					ld		ix,REC_5
					STEP_UPPER	0, 1, 0
					call	expect_list
					DW		REC_1, REC_5, REC_2, REC_3, REC_4, REC_6, 0

					TEST	"upper: zero leaves the list alone"
					call	four_in_a_row
					ld		ix,REC_2
					ld		(ix+OBJ.U),70		; out of order, but not stepped
					ld		hl,REC_1
					STEP_UPPER	0, 0, 0
					call	expect_list
					DW		REC_1, REC_2, REC_3, REC_4, 0

					TEST	"step: behind the background"
					call	make_list
					DW		0
					BOX_U	REC_5, 8
					call	background_insert
					BOX_U	REC_1, 20
					call	depth_insert
					BOX_U	REC_2, 40
					call	depth_insert
					ld		ix,REC_2
					STEP	-32, 0, 0		; U 40 -> 8
					call	expect_list
					DW		REC_5, REC_2, REC_1, 0
					EXPECT_WORD	sort_head, REC_5, "sort_head"

; --- done --------------------------------------------------------------------

					call	finish
					DB		"depth_tests", 0


; ---------------------------------------------------------------------------
; Fixtures.

; REC_1, REC_2 and REC_3 at U = 20, 40, 60, linked in that order.
three_in_a_row:		BOX_U	REC_1, 20
					BOX_U	REC_2, 40
					BOX_U	REC_3, 60
					call	make_list
					DW		REC_1, REC_2, REC_3, 0
					ret

; ...and REC_4 at 80 after them.
four_in_a_row:		BOX_U	REC_1, 20
					BOX_U	REC_2, 40
					BOX_U	REC_3, 60
					BOX_U	REC_4, 80
					call	make_list
					DW		REC_1, REC_2, REC_3, REC_4, 0
					ret

; REC_1 against REC_2, with the results in s_af.
compare_1_with_2:	ld		ix,REC_1
					call	depth_cmp_setup
					ld		iy,REC_2
					call	depth_cmp
					jp		snap

;   IX -> the record
check_order:		call	depth_cmp_setup
					call	depth_in_order
					jp		snap

; ---------------------------------------------------------------------------
; Building and checking lists.

;   IX -> the record; followed by U, V, Z, SIZE_U, SIZE_V, SIZE_Z
box:				pop		hl
					ld		a,(hl)
					ld		(ix+OBJ.U),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.V),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.Z),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.SIZE_U),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.SIZE_V),a
					inc		hl
					ld		a,(hl)
					ld		(ix+OBJ.SIZE_Z),a
					inc		hl
					xor		a
					ld		(ix+OBJ.NEXT),a
					ld		(ix+OBJ.NEXT+1),a
					ld		(ix+OBJ.PREV),a
					ld		(ix+OBJ.PREV+1),a
					jp		(hl)

; Link the records that follow, zero-terminated, into object_list in that
; order, with nothing in the background.
make_list:			pop		hl
					ld		de,object_list		; DE -> the field that names the next
					ld		(sort_head),de
.loop:				ld		c,(hl)
					inc		hl
					ld		b,(hl)
					inc		hl
					ld		a,c
					ld		(de),a
					inc		de
					ld		a,b
					ld		(de),a
					dec		de		; *field = the record, or the end
					or		c
					jr		z,.done
					push	bc
					pop		ix
					ld		(ix+OBJ.PREV),e
					ld		(ix+OBJ.PREV+1),d
					ld		e,c
					ld		d,b		; its own NEXT names the one after
					jr		.loop
.done:				jp		(hl)

; Walk object_list against the records that follow, zero-terminated: each one
; in turn, each one's PREV naming the field that led to it, and then the end.
expect_list:		pop		hl
					ld		de,object_list		; DE -> the field that should name it
.loop:				ld		c,(hl)
					inc		hl
					ld		b,(hl)
					inc		hl		; BC = the record wanted
					push	hl
					ld		a,(de)
					ld		l,a
					inc		de
					ld		a,(de)
					ld		h,a
					dec		de		; HL = the record there
					ld		(e_got),hl
					ld		(e_want),bc
					and		a
					sbc		hl,bc
					jr		nz,.wrong_record
					ld		a,b
					or		c
					jr		z,.right		; the end, where it should be
					push	bc
					pop		ix
					ld		l,(ix+OBJ.PREV)
					ld		h,(ix+OBJ.PREV+1)
					ld		(e_got),hl
					ld		(e_want),de
					and		a
					sbc		hl,de
					jr		nz,.wrong_prev
					ld		e,c
					ld		d,b
					pop		hl
					jr		.loop
.right:				pop		hl
					jp		(hl)

.wrong_prev:		ld		hl,s_prev
					call	.report
					pop		hl
					jr		.skip_word
.wrong_record:		ld		hl,s_record
					call	.report
					pop		hl
					ld		a,b		; if that was the terminator, it is
					or		c		; already behind us
					jr		nz,.skip_word
					jp		(hl)
.skip_word:			ld		a,(hl)
					inc		hl
					or		(hl)
					inc		hl
					jr		nz,.skip_word
					jp		(hl)

.report:			push	hl
					call	fail_begin
					pop		hl
					call	print0
					push	de
					pop		hl
					call	hex16
					jp		got_want

s_record:			DB		"list at field ", 0
s_prev:				DB		"PREV named by field ", 0


; ---------------------------------------------------------------------------
; The code under test.

					INCLUDE	"../engine/depth.s"

					ASSERT	$ < REC_1
