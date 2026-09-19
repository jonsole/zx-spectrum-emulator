; ---------------------------------------------------------------------------
; The menu's lines, in print_lines' shape: the row, the column, the colour,
; then the characters in the font's own codes to an $FF. The positions and the
; colours are the original's ($BBF1 and $BBF8, from the bottom up there).
;
; Here, past the pixel adjustments, because the menu's code filled the space
; in front of them.
; ---------------------------------------------------------------------------

menu_text:
                    DB      32, 11, $43             ; PENTAGRAM
                    DB      'P'-$30,'E'-$30,'N'-$30,'T'-$30,'A'-$30,'G'-$30
                    DB      'R'-$30,'A'-$30,'M'-$30,$FF
                    DB      48, 6, $44              ; 1 KEYBOARD
                    DB      '1'-$30,SPACE_CHAR,'K'-$30,'E'-$30,'Y'-$30,'B'-$30
                    DB      'O'-$30,'A'-$30,'R'-$30,'D'-$30,$FF
                    DB      64, 6, $44              ; 2 KEMPSTON JOYSTICK
                    DB      '2'-$30,SPACE_CHAR,'K'-$30,'E'-$30,'M'-$30,'P'-$30
                    DB      'S'-$30,'T'-$30,'O'-$30,'N'-$30,SPACE_CHAR,'J'-$30
                    DB      'O'-$30,'Y'-$30,'S'-$30,'T'-$30,'I'-$30,'C'-$30
                    DB      'K'-$30,$FF
                    DB      80, 6, $44              ; 3 CURSOR   JOYSTICK
                    DB      '3'-$30,SPACE_CHAR,'C'-$30,'U'-$30,'R'-$30,'S'-$30
                    DB      'O'-$30,'R'-$30,SPACE_CHAR,SPACE_CHAR,SPACE_CHAR,'J'-$30
                    DB      'O'-$30,'Y'-$30,'S'-$30,'T'-$30,'I'-$30,'C'-$30
                    DB      'K'-$30,$FF
                    DB      96, 6, $44              ; 4 INTERFACE II
                    DB      '4'-$30,SPACE_CHAR,'I'-$30,'N'-$30,'T'-$30,'E'-$30
                    DB      'R'-$30,'F'-$30,'A'-$30,'C'-$30,'E'-$30,SPACE_CHAR
                    DB      'I'-$30,'I'-$30,$FF
                    DB      128, 6, $47             ; 0 START GAME
                    DB      '0'-$30,SPACE_CHAR,'S'-$30,'T'-$30,'A'-$30,'R'-$30
                    DB      'T'-$30,SPACE_CHAR,'G'-$30,'A'-$30,'M'-$30,'E'-$30
                    DB      $FF
                    DB      152, 10, $47            ; (c) 1986 A.C.G.
                    DB      COPYRIGHT_CHAR,SPACE_CHAR,'1'-$30,'9'-$30,'8'-$30,'6'-$30
                    DB      SPACE_CHAR,'A'-$30,STOP_CHAR,'C'-$30,STOP_CHAR,'G'-$30
                    DB      STOP_CHAR,$FF
                    DB      0                   ; no more lines
