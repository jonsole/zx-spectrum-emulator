; isoblocks: the numbers the engine is built on, and where it keeps things.
; A game INCLUDEs this before the rest of the engine. isogeom.py says the same
; things in Python, and is where the view tables come from.
;
; Bank 2, $8000-$BFFF, holds the engine and its work space. $C000 holds the
; map's bank, except while bank 7, the second screen, is being painted there
; (present.s). Bank 5, the first screen, is always at $4000.
;
;   $8000   code
;   $9000   the sixteen lists of places to paint, a page each (paint.s)
;   $A000   free
;   $B220   spare places below the view (7 rows of 32), written, never read
;   $B300   the places, 16 rows of 32
;   $B500   spare places above the view
;   $B600   PLACE_HIGH: a place's low byte to its screen address's high byte,
;           from its third's
;   $B700   PLACE_LOW: a place's low byte to its screen address's low byte
;   $B800   the interrupt vectors, 257 bytes of $BB
;   $BA00   LIST_ENDS: how long each list is
;   $BBBB   the interrupt routine
;   $C000   the stack's top, below which it grows

MAP					EQU		$C000		; the map's bank, paged in here
MAP_SIZE			EQU		128			; cells a side, a byte each
HEIGHTS				EQU		8			; a bit each in a cell

; The view is VIEW_ROWS rows of 32 places. A row is two half-rows of 16, the
; second a byte across and four pixel rows down from the first, so the places
; tile like bricks 16 pixels wide. Tall blocks behind the view reach into it,
; so HEIGHTS - 1 more rows of cells are read than there are rows of places.
VIEW_ROWS			EQU		16
PLACES_COUNT		EQU		VIEW_ROWS * 32
READ_ROWS			EQU		VIEW_ROWS + HEIGHTS - 1

; The view is painted straight onto whichever screen is hidden, and shown
; by switching screens. Place row R's first half-row starts at screen line
; 8R + 4, and a block is 16 lines tall, so blocks reach from line 4 to
; line 147; lines 16-143, columns 1-30, are the view, and the rest is black
; on black, so nothing painted outside the view shows or needs clearing.
MAP_BANK			EQU		0			; the map's bank, at $C000
SCREEN_7_BANK		EQU		7			; the second screen's
SHOW_SCREEN_7		EQU		8			; $7FFD's bit to show it
VIEW_FIRST_LINE		EQU		16
VIEW_CHAR_ROWS		EQU		16			; character rows 2-17

; The places, with (HEIGHTS - 1) rows of 32 spare either side: a cell's
; block at height h lands 32h places back from the cell's own place, and one
; that falls outside the view lands in the spare rows instead of being
; tested for. Page-aligned, so a place's row is its address's top bits.
PLACES_BELOW		EQU		(HEIGHTS - 1) * 32
PLACES				EQU		$B300
PLACES_END			EQU		PLACES + PLACES_COUNT

LISTS				EQU		$9000		; 16 pages: 2 per height
PLACE_HIGH			EQU		$B600
PLACE_LOW			EQU		PLACE_HIGH + 256
IM2_TABLE			EQU		$B800
LIST_ENDS			EQU		$BA00		; 16 bytes, page-aligned
IM2_ROUTINE			EQU		$BBBB
STACK_TOP			EQU		$C000

					ASSERT	(PLACES & $FF) == 0
					ASSERT	PLACES_END + PLACES_BELOW <= PLACE_HIGH
					ASSERT	LISTS + 16 * 256 <= PLACES - PLACES_BELOW
