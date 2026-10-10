; The planet: map.txt, a byte a block, held whole.
;
; 128 x 128 blocks, row after row from map_data, which is page-aligned: block
; (x, y) is at map_data + y * 128 + x, so its page is y >> 1 and its low byte
; (y & 1) << 7 | x. A block number picks 32 bytes out of block_gfx to draw
; and 32 out of block_mask to collide with -- blocks.py says how they are laid
; out, and blocks.png is where they come from.

MAP_W       equ 128         ; blocks: planet.py's MAP_W and MAP_H
MAP_H       equ 128

; map_addr -- HL = the map byte for block (B = column, C = row). Uses A.
map_addr:
    ld a,c
    rrca                    ; row >> 1 in bits 0-6, row & 1 in bit 7
    ld h,a
    and 0x80
    or b
    ld l,a
    ld a,h
    and 0x7F
    add a,high map_data
    ld h,a
    ret
