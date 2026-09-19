; ---------------------------------------------------------------------------
; The menu -- $BB74, and the byte it chooses.
;
; The original's: a frame ($BD59, the game over's), the title and four ways to
; play, "0 START GAME" and its copyright, each line in its own colour. The way
; chosen flashes; 1 to 4 choose and 0 starts. The first time it is shown it
; plays the title tune ($D69C, which keeps a flag at $A747 for that), and any
; key cuts it short.
;
; The remake adds one line, as Knight Lore's does: 5 turns directional control
; on and off, and it flashes while it is on. The original leaves a line empty
; between 4 and 0, and that is where it goes.
;
; The choice, in the original's own layout at $A709, which is Knight Lore's
; too: bits 1 and 2 are the way to play, 00 keyboard, 01 Kempston, 10 cursor,
; 11 Interface II, and input_read takes it from there. Bit 3 is directional
; control, which the original does NOT have: it is rotational only, turn then
; walk. player_turn is the only thing that reads it; input.s leaves the same
; five bits either way, so nothing else in the game can tell the difference.
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
MENU_DIRECTIONAL    EQU     1 << 3

MENU_INK            EQU     $43                 ; magenta: the frame and title
MENU_KEYS_1_5       EQU     $F7FE               ; 1 in bit 0 up to 5 in bit 4
MENU_KEY_0          EQU     $EFFE               ; 0 in bit 0
MENU_TOGGLE_LINE    EQU     5                   ; the directional line

menu_mode:          DB      MENU_KEYBOARD

; The directional toggle is a toggle rather than a choice, so it only counts on
; the way down -- see Knight Lore's menu, which keeps the same byte for the
; same reason.
menu_held:          DB      0

menu_tuned:         DB      0                   ; the title tune has played


; 1 to 5, and the lines again if one of them changed something.
; Corrupts everything.
menu_pick:          ld      bc,MENU_KEYS_1_5
                    in      a,(c)
                    cpl                         ; held reads 0, and this is
                    and     $1F                 ; easier to read the other way
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
                    jr      z,.directional
                    or      MENU_INTERFACE_II

                    ; 5 turns directional control over rather than choosing
                    ; it, so it has to be let go of before it counts again.
.directional:       ld      hl,menu_held
                    bit     4,e
                    jr      z,.let_go
                    bit     0,(hl)
                    jr      nz,.settled
                    set     0,(hl)
                    xor     MENU_DIRECTIONAL
                    jr      .settled
.let_go:            res     0,(hl)

.settled:           ld      (menu_mode),a
                    cp      d
                    ret     z                   ; nothing moved
                    jp      menu_show
