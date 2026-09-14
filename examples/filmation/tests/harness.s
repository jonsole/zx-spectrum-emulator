; The checking and printing every *_tests.s shares.
;
; A suite is a CP/M-style .com that cpp-core's z80_com_runner loads at $0100.
; It INCLUDEs this straight after its ORG, defines `start`, names each test
; with TEST, checks with the EXPECT_ macros and expect_bytes, and ends with
; `call finish` and its own name. Failures are printed through BDOS and
; counted, and finish hands the count back in A as it jumps to $0000 -- which
; is the runner's exit status.

BDOS				EQU		5

					jp		start		; over everything here


; Name the test that the checks after this belong to.
					MACRO	TEST name
					call	test_begin
					DB		name, 0
					ENDM

					MACRO	EXPECT_WORD addr, value, what
					ld		hl,(addr)
					ld		de,value
					call	expect_hl_de
					DB		what, 0
					ENDM

					MACRO	EXPECT_BYTE addr, value, what
					ld		a,(addr)
					ld		l,a
					ld		h,0
					ld		de,value
					call	expect_hl_de
					DB		what, 0
					ENDM

; Out of the flags snap took.
					MACRO	EXPECT_CARRY value, what
					ld		a,(s_af)
					and		1
					ld		l,a
					ld		h,0
					ld		de,value
					call	expect_hl_de
					DB		what, 0
					ENDM

; A out of what snap took.
					MACRO	EXPECT_A value, what
					EXPECT_BYTE	s_af + 1, value, what
					ENDM


tests:				DB		0
failures:			DB		0
test_name:			DW		0

s_af:				DW		0		; F low, A high
s_bc:				DW		0
s_de:				DW		0
s_hl:				DW		0
e_got:				DW		0
e_want:				DW		0

; Every register as it came back from the call before, into s_*. Changes none.
snap:				ld		(s_hl),hl
					ld		(s_de),de
					ld		(s_bc),bc
					push	af
					pop		hl
					ld		(s_af),hl
					ld		hl,(s_hl)
					ret

test_begin:			ex		(sp),hl
					ld		(test_name),hl
					call	skip0
					ex		(sp),hl
					ld		a,(tests)
					inc		a
					ld		(tests),a
					ret

; HL = what came back, DE = what should have; followed by what it is.
expect_hl_de:		ld		(e_got),hl
					ld		(e_want),de
					and		a
					sbc		hl,de
					pop		hl
					jr		nz,.wrong
					call	skip0
					jp		(hl)
.wrong:				call	fail_begin
					call	print0
					push	hl
					call	got_want
					pop		hl
					jp		(hl)

; BC bytes at HL against the same number at DE; followed by what they are. The
; first byte that differs is reported, with its offset, and the rest skipped.
expect_bytes:		ld		(.first+1),hl
.loop:				ld		a,(de)
					cp		(hl)
					jr		nz,.wrong
					inc		hl
					inc		de
					dec		bc
					ld		a,b
					or		c
					jr		nz,.loop
					pop		hl
					call	skip0
					jp		(hl)
.wrong:				ld		c,(hl)
					ld		b,0
					ld		(e_got),bc
					ld		a,(de)
					ld		c,a
					ld		(e_want),bc
.first:				ld		de,0		; imm: where the block starts
					and		a
					sbc		hl,de
					ex		de,hl		; DE = how far in it went wrong
					pop		hl
					call	fail_begin
					call	print0
					push	hl
					push	de
					ld		hl,s_at
					call	print0
					pop		hl
					call	hex16
					call	got_want
					pop		hl
					jp		(hl)

got_want:			ld		hl,s_got
					call	print0
					ld		hl,(e_got)
					call	hex16
					ld		hl,s_want
					call	print0
					ld		hl,(e_want)
					call	hex16
					ld		hl,s_crlf
					jp		print0

; "FAIL name: ", and one more failure.
fail_begin:			ld		a,(failures)
					inc		a
					ld		(failures),a
					push	hl
					ld		hl,s_fail
					call	print0
					ld		hl,(test_name)
					call	print0
					ld		hl,s_colon
					call	print0
					pop		hl
					ret

; The suite's summary, and back to the runner with the failures in A.
; Followed by the suite's name.
finish:				pop		hl
					call	print0
					ld		hl,s_colon
					call	print0
					ld		a,(tests)
					call	dec8
					ld		hl,s_tests
					call	print0
					ld		a,(failures)
					call	dec8
					ld		hl,s_failures
					call	print0
					ld		a,(failures)
					jp		0

;   HL -> a zero-terminated string; out HL past it
print0:				ld		a,(hl)
					inc		hl
					or		a
					ret		z
					call	putc
					jr		print0

skip0:				ld		a,(hl)
					inc		hl
					or		a
					jr		nz,skip0
					ret

; Keeps HL, BC is not touched but C, and D.
putc:				push	bc
					push	de
					ld		e,a
					ld		c,2
					call	BDOS
					pop		de
					pop		bc
					ret

hex16:				ld		a,h
					call	hex8
					ld		a,l
hex8:				push	af
					rrca
					rrca
					rrca
					rrca
					call	.digit
					pop		af
.digit:				and		15
					add		a,'0'
					cp		'9' + 1
					jr		c,.out
					add		a,'A' - '9' - 1
.out:				jp		putc

dec8:				ld		c,100
					call	.digit
					ld		c,10
					call	.digit
					add		a,'0'
					jp		putc
.digit:				ld		b,'0' - 1
.count:				inc		b
					sub		c
					jr		nc,.count
					add		a,c
					push	af
					ld		a,b
					call	putc
					pop		af
					ret

s_fail:				DB		"FAIL ", 0
s_colon:			DB		": ", 0
s_at:				DB		" at +", 0
s_got:				DB		" got ", 0
s_want:				DB		", want ", 0
s_crlf:				DB		13, 10, 0
s_tests:			DB		" tests, ", 0
s_failures:			DB		" failed", 13, 10, 0
