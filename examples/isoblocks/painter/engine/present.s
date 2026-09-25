; isoblocks: two screens -- paint one while the other is shown.
;
; The 128K has two screens, banks 5 and 7, and bit 3 of port $7FFD says which
; the ULA shows. The view is painted straight onto the hidden one, so there
; is no buffer to copy out, and shown by switching screens at the next
; interrupt, so the switch is never part-way down the picture. Bank 5 is
; always at $4000 and is painted there; bank 7 is paged in at $C000 over the
; map, which read_view has finished with by then, and the map is paged back
; as soon as it is painted.
;
; A frame: view_update, read_view, sort_places, clear_back, paint, show_back;
; and the interrupt routine calls show_switch.
;
; clear_back first waits for the last frame's switch, because until then the
; screen it is about to clear is the one being shown. read_view and
; sort_places take longer than a TV frame, so it hardly ever has to.

back_high:			DB		$C0			; the hidden screen's high byte: $40 or $C0
show_next:			DB		$FF			; $7FFD for the next interrupt; $FF none
clear_sp:			DW		0


; ---------------------------------------------------------------------------
; clear_back: before paint. Pages the hidden screen in, if it is bank 7, and
; clears the view on it. Uses everything but IX and IY.
;
; The view is character rows 2-17, and PUSH clears it 32 columns wide: in
; each third, a character row's pixel line is 32 bytes on from the row
; above's, so the rows of a third at one pixel line are one run. Third 1 is
; all view, a single 2K run; thirds 2 and 0 are eight runs each. They are
; cleared from the top of memory down -- third 2, then 1, then 0 -- so what
; an interrupt pushes lands below SP on bytes that are still to be cleared,
; or at the very end on character row 1 or 23, which are never shown. The
; interrupt routine must not push more than the 64 bytes of rows 0 and 1.

clear_back:
.wait:				ld		a,(show_next)
					inc		a
					jr		nz,.wait			; the last frame still to be shown
					ld		a,(back_high)
					cp		$C0
					jr		nz,.paged			; bank 5, at $4000
					ld		a,SCREEN_7_BANK		; bank 7 at $C000; bank 5 shown
					ld		bc,$7FFD
					out		(c),a
.paged:				ld		(clear_sp),sp
					ld		de,0
					; Third 2: character rows 16 and 17, 64 bytes a pixel line.
					ld		a,(back_high)
					add		a,$17
					ld		h,a
					ld		l,64
					ld		b,8
.third_2:			ld		sp,hl
					DUP		32
					push	de
					EDUP
					dec		h
					djnz	.third_2
					; Third 1: all of it.
					ld		a,(back_high)
					add		a,$10
					ld		h,a
					ld		l,0
					ld		sp,hl
					ld		b,64
.third_1:
					DUP		16
					push	de
					EDUP
					djnz	.third_1
					; Third 0: character rows 2-7, 192 bytes a pixel line.
					ld		a,(back_high)
					add		a,8
					ld		h,a
					ld		b,8
.third_0:			ld		sp,hl
					DUP		96
					push	de
					EDUP
					dec		h
					djnz	.third_0
					ld		sp,(clear_sp)
					ret


; ---------------------------------------------------------------------------
; show_back: after paint. The screen just painted is shown from the next
; interrupt, and the other becomes the hidden one. Uses A and BC.

show_back:
					ld		a,(back_high)
					cp		$C0
					jr		nz,.bank_5
					ld		a,MAP_BANK			; the map back at $C000; bank 5 shown
					ld		bc,$7FFD
					out		(c),a
					ld		a,$40
					ld		(back_high),a
					ld		a,MAP_BANK + SHOW_SCREEN_7
					ld		(show_next),a		; last: the interrupt may act on it
					ret
.bank_5:			ld		a,$C0
					ld		(back_high),a
					ld		a,MAP_BANK
					ld		(show_next),a
					ret


; show_switch: from the interrupt routine, the switch show_back asked for.
; Uses A and BC.
show_switch:
					ld		a,(show_next)
					inc		a
					ret		z
					dec		a
					ld		bc,$7FFD
					out		(c),a
					ld		a,$FF
					ld		(show_next),a
					ret
