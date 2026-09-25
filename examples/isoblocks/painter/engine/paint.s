; isoblocks: paint the places onto the hidden screen (present.s says which).
;
; A painter's algorithm: every place holding a height-0 block is painted, top
; to bottom, then every height-1 block, and so on up. That is the order
; Ant Attack paints in (Sandy White, 1983), and it is why nothing needs a
; depth test: whatever is nearer the viewer, or higher, is painted later.
;
; sort_places makes the order in one pass over the places, into sixteen
; lists: one per height for each of the two pages of places. A page's list is
; in place order because the pass is, so painting the lists in turn -- height
; 0's first page, its second, height 1's first... -- is the painter's order.
; A list is a page at LISTS + 256 x (2 x height + page), holding the low byte
; of each of its places; LIST_ENDS says how many each has.
;
; The same pass leaves out every block that would be covered whole. Three
; places are painted after a block's and can cover it: the place a row above,
; if it holds a higher block (over the top face), and the two places half a
; block to either side and a half-row down, if they hold one at least as high
; (over the sides). Every block landing on a place is drawn at the same spot
; with the same picture, whatever its height, so the places' marks are all it
; takes -- and it is safe even when one of the three is itself left out,
; because what covers that is painted later still, over the same ground. The
; picture cannot change; check_render.py compares every frame with a model
; that paints every block.
;
; read_view clears the rows of places just outside the view after it has
; read, since nothing is painted there: a block at the top or bottom edge is
; never left out on their account.


; ---------------------------------------------------------------------------
; sort_places: after read_view. Uses everything but IX and IY.

sort_places:
					ld		hl,LIST_ENDS		; empty every list
					ld		b,16
					xor		a
.empty:				ld		(hl),a
					inc		l
					djnz	.empty
					ld		hl,PLACES
					; Sixteen places at a time while they are empty, from a place
					; that is a multiple of 16, so that the last INC L of the
					; sixteen is the one that says the page is done.
.find:
					DUP		16
					ld		a,(hl)
					or		a
					jr		nz,.found
					inc		l
					EDUP
					jr		nz,.find
.page_done:			inc		h
					ld		a,h
					cp		high PLACES_END
					jr		nz,.find
					ret

.found:				ld		e,a					; the mark: height + 1
					; The place a row up must hold a higher block...
					ld		a,l
					sub		32
					ld		c,a
					ld		a,h
					sbc		a,0
					ld		b,a
					ld		a,(bc)
					cp		e
					jr		z,.shows
					jr		c,.shows
					ld		a,l
					and		31
					cp		16
					jr		nc,.second
					; ...and in a first half-row, the places 15 and 16 on one at
					; least as high -- but column 0 has nothing to its lower left.
					or		a
					jr		z,.shows
					ld		a,l
					add		a,15
					jr		.below
.second:			; In a second half-row, 16 and 17 on -- and column 15 has
					; nothing to its lower right.
					cp		31
					jr		z,.shows
					ld		a,l
					add		a,16
.below:				ld		c,a
					ld		a,h
					adc		a,0
					ld		b,a
					ld		a,(bc)
					cp		e
					jr		c,.shows
					inc		bc
					ld		a,(bc)
					cp		e
					jr		nc,.next			; covered whole: left out

.shows:				; Onto the end of its list: page 2 x (mark - 1) + this page.
					ld		a,e
					add		a,a
					add		a,h
					add		a,high LISTS - 2 - high PLACES
					ld		d,a
					sub		high LISTS
					ld		c,a
					ld		b,high LIST_ENDS
					ld		a,(bc)
					ld		e,a
					ld		a,l
					ld		(de),a
					inc		e
					ld		a,e
					ld		(bc),a
.next:				inc		l
					jr		z,.page_done
					; Back to sixteen at a time, one at a time until the next
					; multiple of 16.
.odd:				ld		a,l
					and		15
					jp		z,.find
					ld		a,(hl)
					or		a
					jr		nz,.found
					inc		l
					jr		nz,.odd
					jp		.page_done


; ---------------------------------------------------------------------------
; paint: the lists, in order, onto the hidden screen. Uses everything but IX
; and IY.

paint:
					ld		hl,LIST_ENDS
.list:				ld		a,(hl)
					or		a
					jr		z,.done_list
					push	hl
					ld		b,a					; the list's length
					ld		a,l
					add		a,high LISTS
					ld		d,a
					ld		e,0					; DE = its first entry
					ld		a,l
					and		1					; which page of places it lists...
					add		a,a
					add		a,a
					add		a,a
					ld		c,a
					ld		a,(back_high)		; ...and so which third of the screen:
					add		a,c					; place rows 0-7 are character rows
					ld		c,a					; 0-7, and 8-15 are 8-15
.entry:				ld		a,(de)				; the place's low byte
					inc		e
					push	bc
					push	de
					call	paint_place
					pop		de
					pop		bc
					djnz	.entry
					pop		hl
.done_list:			inc		l
					ld		a,l
					cp		16
					jr		nz,.list
					ret


; Paint the block at a place. In: A the place's low byte, C the high byte of
; the screen third its page of places starts in.
;
; A place's row is its low byte / 32 within the page, its column the bottom
; four bits, and bit 4 says which half-row. On the screen, place row R's
; first half-row starts at line 8R + 4 -- four lines into character row R --
; and its second half-row a byte across, at line 8R + 8: the top of
; character row R + 1, which for a page's last row is in the next third. The
; screen address is two tables, PLACE_HIGH and PLACE_LOW, and the two
; half-rows have their own drawers, since they cross character rows at
; different lines.
paint_place:
					ld		e,a
					ld		d,high PLACE_HIGH
					ld		a,(de)
					add		a,c
					ld		h,a
					inc		d					; PLACE_LOW is the next page
					ld		a,(de)
					ld		l,a
					bit		4,e
					jr		nz,paint_drawer_second
paint_drawer_first:	jp		draw_block_even_first	; view_update puts this view's
paint_drawer_second: jp		draw_block_even_second	; drawers here


; The two tables paint_place reads, by a place's low byte.
make_place_tables:
					ld		hl,PLACE_HIGH
.high:				bit		4,l
					ld		a,4					; a first half-row: line 4
					jr		z,.high_done
					ld		a,l
					cp		$E0
					ld		a,0					; a second: line 0 of the next row...
					jr		c,.high_done
					ld		a,8					; ...which after row 7 is the next third
.high_done:			ld		(hl),a
					inc		l
					jr		nz,.high
					inc		h					; PLACE_LOW
.low:				ld		a,l
					and		15
					add		a,a					; two bytes a column
					ld		c,a
					ld		a,l
					and		$E0					; the place row is the character row
					bit		4,l
					jr		z,.first
					add		a,32				; a second half-row: a row down...
					inc		c					; ...and a byte across
.first:				or		c
					ld		(hl),a
					inc		l
					jr		nz,.low
					ret
