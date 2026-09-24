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
; For now bank 0 is the only one ever paged in. The image still sits where the
; 48K game put it, with the code and sprite data from $C000 up in bank 0, and
; the stack at the top of bank 0 too. Nothing may page bank 0 out while that
; stack is in use -- a RET would read its address from the other bank -- so the
; stack has to move below $C000 before anything else is paged in. See
; ../engine/memory-128k.md for where everything is going.
PAGE_ROM_48         EQU     %00010000   ; bit 4: the 48 BASIC ROM at $0000

; The last value written to $7FFD.
bank_port:          DB      PAGE_ROM_48

; Puts a RAM bank at $C000.
;
; In:  A = the bank, 0-7
; Out: bank_port = what was written to the port
; Corrupts: AF, BC
page_in:            or      PAGE_ROM_48
                    ld      (bank_port),a
                    ld      bc,$7FFD
                    out     (c),a
                    ret
