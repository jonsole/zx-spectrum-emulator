; isoblocks: read the cells in view out of the map, and sort them by height
; into the places, in one pass.
;
; Each place ends up holding the topmost block seen there, as its height plus
; one (1-8), or 0 for nothing. The rule that makes one pass enough: the cells
; are read in place order, and a cell that is read later and reaches the same
; place is always one whose block is higher -- a height up is a row of places
; up the screen, and a row of cells further on -- so it simply overwrites.
; There is no comparing, and no buffer of cells in between.
;
; Most cells are empty, so the loop is built for them: an empty cell is a
; read, an add and a test (32 T-states). A cell with blocks in it calls out to
; write them (solid).
;
; The rows of places just outside the view are cleared again afterwards:
; nothing is painted there, and sort_places reads them when it asks whether a
; block at the edge of the view is covered.

half_places:		DW		0			; the place of this half-row's first cell
row_map:			DW		0			; the map address this row starts at
read_sp:			DW		0


; ---------------------------------------------------------------------------
; read_view: fill the places for the frame. view_update first.
;
; Uses everything but IX and IY.

read_view:
					; Clear the places and the row either side, top down, with the
					; stack. An interrupt pushing meanwhile lands below SP, on
					; places still to be cleared, or in the spare rows below.
					ld		(read_sp),sp
					ld		sp,PLACES_END + 32
					ld		hl,0
					DUP		(PLACES_COUNT + 64) / 2
					push	hl
					EDUP
					ld		sp,(read_sp)

					ld		hl,PLACES
					ld		(half_places),hl
					exx
					ld		de,-32				; for solid: a height up, a row of places up
					exx
					ld		hl,(view_map)
					ld		b,READ_ROWS
.row:				push	bc
					ld		(row_map),hl
					ld		bc,(step_along)
					call	read_half			; the first half-row
					ld		hl,(row_map)
					ld		de,(step_second)
					add		hl,de
					call	read_half			; the second, a cell to the side
					ld		hl,(row_map)
					ld		de,(step_next)
					add		hl,de				; the next row, a cell back
					pop		bc
					djnz	.row
					; The rows either side of the view, cleared again.
					ld		(read_sp),sp
					ld		sp,PLACES_END + 32
					ld		hl,0
					DUP		16
					push	hl
					EDUP
					ld		sp,PLACES
					DUP		16
					push	hl
					EDUP
					ld		sp,(read_sp)
					ret


; Sixteen cells along a half-row. In: HL the first cell's map address, BC the
; step from one to the next. Keeps BC; moves half_places on 16.
;
; A cell with blocks in it calls out through a stub that knows which cell it
; is. The stub and solid work in the other register set, where BC' holds the
; half-row's first place and DE' the step a height up -- so reaching them is an
; EXX, not a round of pushes and pops.
read_half:
					exx
					ld		bc,(half_places)
					exx
					DUP		16, cell
					ld		a,(hl)
					add		hl,bc
					or		a
					call	nz,solid_stubs + 6 * cell
					EDUP
					ld		hl,(half_places)
					ld		de,16
					add		hl,de
					ld		(half_places),hl
					ret


; One stub per cell of a half-row, six bytes each, to say which cell it was.
solid_stubs:
					DUP		16, cell
					exx
					ld		hl,cell
					jr		solid
					EDUP

; A cell with blocks in it: write each of its heights into its place.
; In: A the cell (not 0); the other set, HL' its position in the half-row,
; BC' the half-row's first place, DE' -32. Back in the main set on return.
solid:
					add		hl,bc				; the cell's own place: height 0
					; Heights 0-7 in turn, until no bits are left: SRL moves the
					; next height's bit to carry and says whether any remain.
					srl		a
					jr		nc,.h1
					ld		(hl),1
.h1:				jr		z,.done
					add		hl,de
					srl		a
					jr		nc,.h2
					ld		(hl),2
.h2:				jr		z,.done
					add		hl,de
					srl		a
					jr		nc,.h3
					ld		(hl),3
.h3:				jr		z,.done
					add		hl,de
					srl		a
					jr		nc,.h4
					ld		(hl),4
.h4:				jr		z,.done
					add		hl,de
					srl		a
					jr		nc,.h5
					ld		(hl),5
.h5:				jr		z,.done
					add		hl,de
					srl		a
					jr		nc,.h6
					ld		(hl),6
.h6:				jr		z,.done
					add		hl,de
					srl		a
					jr		nc,.h7
					ld		(hl),7
.h7:				jr		z,.done
					add		hl,de
					ld		(hl),8				; only height 7's bit can be left
.done:				exx
					ret
