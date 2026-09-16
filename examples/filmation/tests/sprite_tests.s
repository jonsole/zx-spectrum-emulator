; Unit tests for sprite_flip_h, in Z80, run on the C++ core by run_tests.py.
;
; A sprite record is byte 0 -- the width class in bits 4-6 and which way round
; it is in bit 0 -- then the height in rows, then each row as a mask and data
; byte per column. A mirror reverses the bits of every byte and puts the columns
; the other way round, keeping each column's mask ahead of its data.
;
; Every expected record here is written out by hand: the columns in the other
; order, each byte through REV. So nothing expected comes from the routine or
; from its table. Each test copies its record to BUF, which sits so that the
; rows run across a page boundary, flips it there, and compares.

					ORG		$0100
					INCLUDE	"harness.s"
					INCLUDE	"../engine/sprite_defs.s"

BUF					EQU		$C0FC		; two header bytes, then rows from $C0FE on

; A byte with its bits the other way round, worked out by the assembler.
					MACRO	REV x
					DB		(((x) & $01) << 7) | (((x) & $02) << 5) | (((x) & $04) << 3) | (((x) & $08) << 1) | (((x) & $10) >> 1) | (((x) & $20) >> 3) | (((x) & $40) >> 5) | (((x) & $80) >> 7)
					ENDM

; One column of an expected row: mask and data, each reversed.
					MACRO	RCOL mask, data
					REV		mask
					REV		data
					ENDM

; Byte 0 of a record `width` columns wide.
					MACRO	HEADER width, flipped
					DB		((width) - 2) << WIDTH_CLASS_SHIFT | (flipped)
					ENDM

; Copy the record at `source`, `length` bytes, to BUF and flip it there, with
; the registers it came back with in s_*.
					MACRO	FLIP source, length
					ld		hl,source
					ld		bc,length
					call	flip_at_buf
					ENDM

; The record at BUF against `wanted`, `length` bytes.
					MACRO	EXPECT_RECORD wanted, length
					ld		hl,BUF
					ld		de,wanted
					ld		bc,length
					call	expect_bytes
					DB		"the record", 0
					ENDM


start:				ld		sp,$FE00

					TEST	"width 2, one row"
					FLIP	w2_in, W2_LEN
					EXPECT_RECORD	w2_out, W2_LEN
					EXPECT_WORD	s_hl, BUF, "HL, the record"

					TEST	"width 3, two rows"
					FLIP	w3_in, W3_LEN
					EXPECT_RECORD	w3_out, W3_LEN

					TEST	"width 4, two rows"
					FLIP	w4_in, W4_LEN
					EXPECT_RECORD	w4_out, W4_LEN

					TEST	"width 5, three rows"
					FLIP	w5_in, W5_LEN
					EXPECT_RECORD	w5_out, W5_LEN
					EXPECT_WORD	s_hl, BUF, "HL, the record"

					TEST	"flipped back the other way"
					FLIP	w4_out, W4_LEN		; the mirrored record, mirrored
					EXPECT_RECORD	w4_in, W4_LEN

					TEST	"twice is where it started"
					FLIP	w5_in, W5_LEN
					ld		hl,BUF
					call	sprite_flip_h
					EXPECT_RECORD	w5_in, W5_LEN

					TEST	"spare header bits kept"
					FLIP	spare_in, SPARE_LEN
					EXPECT_RECORD	spare_out, SPARE_LEN

					TEST	"AF' kept"
					ld		a,$A5		; the draw loop holds the x overlap here
					ex		af,af'
					FLIP	w5_in, W5_LEN
					ex		af,af'
					ld		(a_shadow),a
					EXPECT_BYTE	a_shadow, $A5, "A'"
					EXPECT_RECORD	w5_out, W5_LEN

					TEST	"IY kept"
					ld		iy,$1234		; the draw loop's next object
					FLIP	w5_in, W5_LEN
					ld		(iy_after),iy
					EXPECT_WORD	iy_after, $1234, "IY"
					EXPECT_RECORD	w5_out, W5_LEN

					call	finish
					DB		"sprite_tests", 0

a_shadow:			DB		0
iy_after:			DW		0


;   HL -> the record, BC = its length
flip_at_buf:		ld		de,BUF
					ldir
					ld		hl,BUF
					call	sprite_flip_h
					jp		snap


; --- the records -------------------------------------------------------------

w2_in:				HEADER	2, 0
					DB		1
					DB		$12,$34, $56,$78
W2_LEN				EQU		$ - w2_in
w2_out:				HEADER	2, 1
					DB		1
					RCOL	$56,$78
					RCOL	$12,$34

w3_in:				HEADER	3, 0
					DB		2
					DB		$01,$02, $03,$04, $05,$06
					DB		$F0,$0F, $C3,$3C, $81,$18
W3_LEN				EQU		$ - w3_in
w3_out:				HEADER	3, 1
					DB		2
					RCOL	$05,$06
					RCOL	$03,$04
					RCOL	$01,$02
					RCOL	$81,$18
					RCOL	$C3,$3C
					RCOL	$F0,$0F

w4_in:				HEADER	4, 1		; starts mirrored, so this puts it back
					DB		2
					DB		$11,$22, $33,$44, $55,$66, $77,$88
					DB		$9A,$BC, $DE,$F0, $0A,$B0, $C0,$0D
W4_LEN				EQU		$ - w4_in
w4_out:				HEADER	4, 0
					DB		2
					RCOL	$77,$88
					RCOL	$55,$66
					RCOL	$33,$44
					RCOL	$11,$22
					RCOL	$C0,$0D
					RCOL	$0A,$B0
					RCOL	$DE,$F0
					RCOL	$9A,$BC

w5_in:				HEADER	5, 0
					DB		3
					DB		$01,$80, $02,$40, $04,$20, $08,$10, $10,$08
					DB		$E0,$07, $1C,$38, $A5,$5A, $3E,$7C, $FF,$00
					DB		$12,$21, $34,$43, $56,$65, $78,$87, $9A,$A9
W5_LEN				EQU		$ - w5_in
w5_out:				HEADER	5, 1
					DB		3
					RCOL	$10,$08
					RCOL	$08,$10
					RCOL	$04,$20
					RCOL	$02,$40
					RCOL	$01,$80
					RCOL	$FF,$00
					RCOL	$3E,$7C
					RCOL	$A5,$5A
					RCOL	$1C,$38
					RCOL	$E0,$07
					RCOL	$9A,$A9
					RCOL	$78,$87
					RCOL	$56,$65
					RCOL	$34,$43
					RCOL	$12,$21

; Bits 1 to 3 of byte 0 are spare, and bit 7 is outside the class; a flip
; touches bit 0 and nothing else of the header.
spare_in:			DB		(3 - 2) << WIDTH_CLASS_SHIFT | $8E
					DB		1
					DB		$AB,$CD, $EF,$01, $23,$45
SPARE_LEN			EQU		$ - spare_in
spare_out:			DB		(3 - 2) << WIDTH_CLASS_SHIFT | $8F
					DB		1
					RCOL	$23,$45
					RCOL	$EF,$01
					RCOL	$AB,$CD


; --- the code under test -----------------------------------------------------

					INCLUDE	"../engine/sprite_flip.s"

					ALIGN	256
bit_reverse_table:
					bit_reverse_bytes

					ASSERT	$ < BUF
