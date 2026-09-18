; ---------------------------------------------------------------------------
; The menu's byte, which is all of the menu that exists so far.
;
; The original offers four ways to play -- keyboard, Kempston, cursor and
; Interface II -- and input_read takes its choice from bits 1 and 2 here, the
; same shape Knight Lore uses.
;
; Bit 3 is directional control, which the original does NOT have: it is
; rotational only, turn then walk. The remake offers both, and this bit is the
; whole of the switch. player_turn is the only thing that reads it; input.s
; leaves the same five bits either way, so nothing else in the game can tell
; the difference.
;
;   bits 1-2   00 keyboard, 01 Kempston, 10 cursor, 11 Interface II
;   bit 3      directional control rather than turn-and-walk
;
; The menu itself -- drawing it, and letting those be chosen -- is still to
; write. Until then this is a plain byte that starts on keyboard and
; rotational, which is how the original plays.
; ---------------------------------------------------------------------------

MENU_KEYBOARD       EQU     0 << 1
MENU_KEMPSTON       EQU     1 << 1
MENU_CURSOR         EQU     2 << 1
MENU_INTERFACE_II   EQU     3 << 1
MENU_DIRECTIONAL    EQU     1 << 3

menu_mode:          DB      MENU_KEYBOARD

; The directional toggle is a toggle rather than a choice, so it only counts on
; the way down -- see Knight Lore's menu, which keeps the same byte for the
; same reason.
menu_held:          DB      0
