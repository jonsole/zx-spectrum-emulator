; ---------------------------------------------------------------------------
; Where the end screens and the menu put a character, kept with them in the
; cold end of the $6000 region.
;
; Both of them are cold -- they run between rooms, or at the end of a game --
; so contended memory costs them nothing. On the 48K this sat with the room
; builder at $5B00, the only place with room for it; on the 128K the menu and
; the end screens moved down to $6000 themselves, and it follows them.
; ---------------------------------------------------------------------------

; Where a cell is on the screen.
;
; In:  D = the row
;      E = the column
; Out: HL -> the cell's top row of pixels
; Corrupts: AF, BC
end_at:             ld      a,d
                    add     a,a
                    add     a,a
                    add     a,a
                    ld      b,a
                    ld      a,e
                    add     a,a
                    add     a,a
                    add     a,a
                    ld      c,a
                    jp      pixelAddress

; And where its attribute is.
;
; In:  D = the row
;      E = the column
; Out: HL -> the attribute
; Corrupts: F, BC
end_attr_at:        ld      h,0
                    ld      l,d
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl
                    add     hl,hl               ; the row * 32
                    ld      c,e
                    ld      b,$58
                    add     hl,bc
                    ret
