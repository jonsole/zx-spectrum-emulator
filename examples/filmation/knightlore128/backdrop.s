; ---------------------------------------------------------------------------
; The backdrop: a picture of the room's background, in bank 6.
;
; The walls and the trees along the back of a room -- the pieces a room's
; templates mark OBJ_BACKGROUND, templates.json's meta.background -- are drawn
; once, as the room is built, and never again. Nothing can get behind them, so
; nothing that moves ever needs them redrawn: a region the knight or a monster
; disturbs starts from a copy of the backdrop instead of from nothing, and the
; draw walk has only what stands in front. The pieces stay in the pool, so they
; still stop things; they are only out of the depth list.
;
; The backdrop is the screen's 6,144 bytes of pixels, but a byte a column and
; 32 a row, top row first -- not the screen's own interleave -- so a region's
; rows are 32 apart. It is made from the screen itself: room_show_backdrop
; draws the room with only its background in the list, the screen still black
; by its attributes, and backdrop_capture copies the pixels across -- all in
; backdrop_build.s, which runs once a room and lives with the cold code.
;
; The saving is every background piece the draw walk no longer visits,
; rotates or blits. Pentagram's start room measured 9.9% of a turn in blits
; and walk with its walls culled, less the copy's own cost against the clear
; it replaces -- about 6% net: ../engine/memory-128k.md, section 6. And the
; walls no longer need rotation buffers, so they rotate through the shared one
; once, at build time, and the arena is left to what moves.
; ---------------------------------------------------------------------------

BACKDROP_BANK       EQU     6
BACKDROP            EQU     $C000               ; in bank 6
BACKDROP_ROW        EQU     32                  ; bytes from one row to the next

; Non-zero once the room's backdrop is built: redraw_view's regions start from
; it. Zero while it is being built, when they start from nothing.
backdrop_ready:     DB      0

; Where a region starts: engine/redraw.s's view_clear, which knightlore128.s
; defines as a call here. Nothing, while the backdrop is being drawn; after
; that, the backdrop's own bytes for the region's rows. Eight a row, whatever
; the region's width: the buffer is eight across and the copy to the screen
; takes only the region's own columns, so the rest go unread. A region at the
; right-hand edge reads the start of the next row, and one on the bottom row
; reads past the end into bank 6's spare, both into columns nothing copies.
;
; In:  region_rows, view_y_extent, view_x_extent = the region
; Out: region_rows rows of view_buffer filled; bank 0 at $C000
; Corrupts: AF, BC, DE, HL
backdrop_clear:     ld      a,(backdrop_ready)
                    or      a
                    jr      z,.zeroes
                    ; Does any of the region's columns have something of the
                    ; backdrop in the region's rows? Most of what moves is out
                    ; on the floor, clear of the walls, and a region clear of
                    ; them starts from nothing the quick way: the copy below is
                    ; 165 T a row against the clear's 57.
                    ld      a,(view_y_extent)   ; its top row
                    ld      d,a
                    ld      a,(region_rows)
                    add     a,d
                    ld      e,a                 ; one past its bottom row
                    ld      a,(region_width)
                    or      a
                    jr      z,.zeroes
                    ld      b,a
                    ld      a,(view_x_extent)   ; its left column
                    add     a,a                 ; two bytes a column
                    ld      hl,backdrop_band
                    add     a,l
                    ld      l,a
                    adc     a,h
                    sub     l
                    ld      h,a
.column:            ld      a,(hl)              ; the column's first row with anything
                    inc     hl
                    cp      e
                    jr      nc,.next            ; that is below the region
                    ld      a,d
                    cp      (hl)                ; one past its last
                    jr      c,.copy             ; and the region starts above it
.next:              inc     hl
                    djnz    .column
.zeroes:            view_clear_zeroes
                    ret

.copy:              ld      a,(view_y_extent)   ; its top row
                    ld      l,a
                    ld      h,0
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl               ; * BACKDROP_ROW
                    ASSERT  BACKDROP_ROW == 32
                    ld      a,(view_x_extent)   ; its left column
                    ld      e,a
                    ld      d,high BACKDROP
                    ASSERT  low BACKDROP == 0
                    add     hl,de
                    ld      de,view_buffer
                    ld      a,BACKDROP_BANK
                    call    page_in
                    ld      a,(region_rows)
.row:               ldi                         ; eight, as VIEW_BUF_WIDTH is
                    ldi
                    ldi
                    ldi
                    ldi
                    ldi
                    ldi
                    ldi
                    ASSERT  VIEW_BUF_WIDTH == 8
                    ld      bc,BACKDROP_ROW - VIEW_BUF_WIDTH
                    add     hl,bc
                    dec     a
                    jr      nz,.row
                    ld      a,PAGE_PLAY
                    jp      page_in
