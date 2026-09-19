; ---------------------------------------------------------------------------
; The menu -- $BB74, and the byte it chooses.
;
; The original's: a frame ($BD59, the game over's), the title and four ways to
; play, "0 START GAME" and its copyright, each line in its own colour. The way
; chosen flashes; 1 to 4 choose and 0 starts. The first time it is shown it
; plays the title tune ($D69C, which keeps a flag at $A747 for that), and any
; key cuts it short.
;
; The choice, in the original's own layout at $A709, which is Knight Lore's
; too: bits 1 and 2 are the way to play, 00 keyboard, 01 Kempston, 10 cursor,
; 11 Interface II, and input_read takes it from there.
;
; This is cold code, and there was no one place with room for all of it: the
; byte it chooses and the keys are here in the room builder's page, the rest is
; menu_run.s in the bytes the pixel adjustments' index would otherwise leave
; empty in front of its page, and the lines are menu_text.s, after it.
; ---------------------------------------------------------------------------

MENU_KEYBOARD       EQU     0 << 1
MENU_KEMPSTON       EQU     1 << 1
MENU_CURSOR         EQU     2 << 1
MENU_INTERFACE_II   EQU     3 << 1

MENU_INK            EQU     $43                 ; magenta: the frame and title
MENU_KEYS_1_4       EQU     $F7FE               ; 1 in bit 0 up to 4 in bit 3
MENU_KEY_0          EQU     $EFFE               ; 0 in bit 0

menu_mode:          DB      MENU_KEYBOARD

menu_tuned:         DB      0                   ; the title tune has played


; 1 to 4, and the lines again if one of them changed something.
; Corrupts everything.
menu_pick:          ld      bc,MENU_KEYS_1_4
                    in      a,(c)
                    cpl                         ; held reads 0, and this is
                    and     $0F                 ; easier to read the other way
                    ld      e,a
                    ld      a,(menu_mode)
                    ld      d,a                 ; to notice a change

                    bit     0,e                 ; 1: the keyboard
                    jr      z,.kempston
                    and     $F9
.kempston:          bit     1,e
                    jr      z,.cursor
                    and     $F9
                    or      MENU_KEMPSTON
.cursor:            bit     2,e
                    jr      z,.interface_ii
                    and     $F9
                    or      MENU_CURSOR
.interface_ii:      bit     3,e
                    jr      z,.settled
                    or      MENU_INTERFACE_II

.settled:           ld      (menu_mode),a
                    cp      d
                    ret     z                   ; nothing moved
                    jp      menu_show
