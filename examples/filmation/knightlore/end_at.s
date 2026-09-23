; ---------------------------------------------------------------------------
; Where the end screens and the menu put a character, kept down here with the
; room builder rather than up with the rest of end.s.
;
; Both of them are cold -- they run between rooms, or at the end of a game --
; so contended memory costs them nothing, and the code region is the one that
; is full. See "Cold code into the room builder's region" in README.md.
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
