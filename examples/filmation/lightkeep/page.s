; ---------------------------------------------------------------------------
; Paging: which RAM bank is at $C000.
;
; On the 128K only $C000-$FFFF pages, through port $7FFD. Bits 0-2 are the bank
; there. Bit 3 picks the screen, and stays 0 so the screen is bank 5 at $4000,
; the one the game draws into. Bit 4 picks the ROM, and stays 1 for the 48 BASIC
; ROM, the one Knight Lore's noises read their pitches from. Bit 5 locks the
; port until a reset, and is never set.
;
; The port is write-only, so the game keeps its own copy of the last value it
; wrote. The snapshot starts from the same value: build.py reads bank_port out
; of the image for the .z80's header, so the two cannot disagree.
;
; Bank 0 is the one paged in during play: it holds the sprites, which the
; drawing reads every turn. Anything else is paged in only for as long as it
; takes to copy something out of it, and bank 0 goes straight back. The stack is
; below $C000, so a RET never reads its address from whatever bank is paged in.
; See ../engine/memory-128k.md for the rest of the plan.
PAGE_ROM_48         EQU     %00010000   ; bit 4: the 48 BASIC ROM at $0000
PAGE_PLAY           EQU     0           ; the bank at $C000 during play

; The last value written to $7FFD.
bank_port:          DB      PAGE_ROM_48 | PAGE_PLAY

; Puts a RAM bank at $C000.
;
; In:  A = the bank, 0-7
; Out: A = bank_port, what was written to the port; carry clear
; Corrupts: F
page_in:            or      PAGE_ROM_48
                    ld      (bank_port),a
                    push    bc
                    ld      bc,$7FFD
                    out     (c),a
                    pop     bc
                    ret
