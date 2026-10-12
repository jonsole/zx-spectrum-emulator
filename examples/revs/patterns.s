; Fill patterns, one byte per colour, for even track lines: odd lines use
; the same byte rotated right two places, so the dots of a tone fall
; between those of the line above. White, grass, red and black are a grey
; ramp, so they stay apart on a monochrome screen. The road is solid black,
; as on the BBC: a black verge mark runs into it, leaving the white marks
; as dashes along its edge.
GRASS       equ %10001000       ; a quarter
SKY         equ 0

    ALIGN 8                     ; so an index never carries out of the page
patterns:
    db GRASS                    ; 0 grass
    db %11111111                ; 1 road: black
    db %11111111                ; 2 verge, black
    db %11001100                ; 3 verge, red: a half
    db 0                        ; 4 verge, white
    db SKY                      ; 5 sky
