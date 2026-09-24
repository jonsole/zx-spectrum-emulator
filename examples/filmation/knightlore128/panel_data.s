; The status panel's data, down here with the castle's: it is read when the
; panel is drawn and never in a hurry, and it fits in what the nudge table's
; ALIGN would otherwise leave empty.

; ---------------------------------------------------------------------------
; The status panel's pieces -- panel_data at $D27E, and print_lives_gfx's head:
; the graphic, x plus one if it is drawn mirrored, and the row below its bottom
; one. The game's Y counts up from the bottom of the screen, so that row is
; 192 - Y. Two runs of five links, a step of 16 across and 8 up or down, then a
; bar at the edge and a piece by the day; the same again mirrored.
panel_pieces:		DB		134,  16, 140
					DB		134,  32, 148
					DB		134,  48, 156
					DB		134,  64, 164
					DB		134,  80, 172
					DB		135, 240, 192
					DB		136, 144, 188
					DB		134, 160 + 1, 172
					DB		134, 176 + 1, 164
					DB		134, 192 + 1, 156
					DB		134, 208 + 1, 148
					DB		134, 224 + 1, 140
					DB		135,   0 + 1, 192
					DB		136,  96 + 1, 188
					DB		140,  16, 160		; the knight's head, by the lives
PANEL_PIECES		EQU		($ - panel_pieces) / 3

; The word over the day: four characters of the game's own, day_font at $BCEC.
panel_word:			DB		$06, $07, $06, $06, $06, $06, $06, $0F
					DB		$00, $01, $82, $C6, $64, $6C, $6D, $C6
					DB		$C8, $C6, $E1, $60, $60, $E0, $64, $63
					DB		$60, $60, $60, $E0, $60, $40, $C0, $80
