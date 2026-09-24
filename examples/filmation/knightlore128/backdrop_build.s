; ---------------------------------------------------------------------------
; Building the backdrop, as a room is built: see backdrop.s for what it is.
; This is the half that runs once a room, with the rest of the cold code.
; ---------------------------------------------------------------------------

; For each of the screen's 32 byte columns, the rows the backdrop has anything
; in: the first, and one past the last. The walls are along the back of the
; room, high on the screen and lower towards its sides; a region of the floor
; below them starts from nothing without looking at the backdrop at all.
backdrop_band:      DS      BACKDROP_ROW * 2


; engine/room.s's room_show, with the backdrop: every object placed, the
; background alone put in the list and drawn to the screen, which is still
; black; that captured into bank 6; and then the list started again with
; everything else, and the room drawn over the backdrop. room_build calls this
; where Knight Lore calls room_show.
;
; In:  the pool filled
; Out: the room drawn; backdrop_ready set
; Corrupts: everything
room_show_backdrop: ld      hl,object_place
                    call    room_each
                    xor     a
                    ld      (backdrop_ready),a
                    ld      hl,.background
                    call    room_each
                    call    redraw_screen
                    call    backdrop_capture
                    depth_reset
                    ld      a,1
                    ld      (backdrop_ready),a
                    ld      hl,.foreground
                    call    room_each
                    jp      redraw_screen

                    ; What goes in the list, the first time and the second.
.background:        ld      a,(ix+OBJ.FLAGS)
                    and     OBJ_BACKGROUND
                    ret     z
                    jp      background_insert
.foreground:        ld      a,(ix+OBJ.FLAGS)
                    and     OBJ_BACKGROUND
                    ret     nz
                    jp      depth_insert


; The screen's pixels into the backdrop, a row at a time: the screen interleaves
; its rows, and the backdrop keeps them in order.
;
; In:  nothing
; Out: the backdrop filled; bank 0 at $C000
; Corrupts: AF, BC, DE, HL
backdrop_capture:   ld      a,BACKDROP_BANK
                    call    page_in
                    ld      de,BACKDROP
                    ld      b,0                 ; the row
.row:               ld      c,0                 ; its left-hand pixel
                    call    pixelAddress        ; HL -> it; BC kept
                    push    bc
                    ld      bc,BACKDROP_ROW
                    ldir
                    pop     bc
                    inc     b
                    ld      a,b
                    cp      SCREEN_ROWS
                    jr      nz,.row
                    call    backdrop_bands
                    ld      a,PAGE_PLAY
                    jp      page_in


; Each column's band: the first row with anything of the backdrop in it, and one
; past the last, read down and then up the backdrop's column from each end. A
; column with nothing in it gets SCREEN_ROWS and 0, which no region reaches.
; About 90,000 T once a room, most of it reading up from the bottom through the
; empty floor.
;
; In:  bank 6 at $C000, the backdrop filled
; Out: backdrop_band
; Corrupts: AF, BC, DE, HL, IX
backdrop_bands:     ld      ix,backdrop_band
                    ld      hl,BACKDROP
                    ld      de,BACKDROP_ROW
.column:            push    hl
                    ld      b,0                 ; the row
.down:              ld      a,(hl)
                    or      a
                    jr      nz,.top
                    add     hl,de
                    inc     b
                    ld      a,b
                    cp      SCREEN_ROWS
                    jr      nz,.down
                    ld      (ix+0),b            ; nothing in it at all
                    ld      (ix+1),0
                    jr      .next
.top:               ld      (ix+0),b
                    pop     hl
                    push    hl
                    ld      bc,(SCREEN_ROWS - 1) * BACKDROP_ROW
                    add     hl,bc               ; its bottom row
                    ld      b,SCREEN_ROWS       ; one past the row being read
.up:                ld      a,(hl)
                    or      a                   ; and carry clear for the SBC
                    jr      nz,.end
                    sbc     hl,de
                    djnz    .up                 ; never runs out: .top found a row
.end:               ld      (ix+1),b
.next:              pop     hl
                    inc     hl
                    inc     ix
                    inc     ix
                    ld      a,l
                    cp      low (BACKDROP + BACKDROP_ROW)
                    jr      nz,.column
                    ret
