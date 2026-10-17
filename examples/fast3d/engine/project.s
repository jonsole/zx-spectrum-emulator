; fast3d: project, a rotated vertex onto the screen, by perspective.
;
; Z = (rot_z + zoff) >> 8, and the vertex lands at rot_x / Z, rot_y / Z
; from the screen's centre. rot_x is 128 x, so with zoff = 128 d that is
; 256 x / (z + d): an eye d units from the object's centre, 256 units from
; the screen. The object must keep in front of the eye, with Z 1..255.
;
; In: rot_x, rot_y, rot_z (rotate leaves them); zoff.
; Out: B = x, 0..255; C = y, 0..191 downwards -- or carry set if the vertex
;      is off the screen, or Z is 0. Uses A, BC, DE, HL.

; Where the view's centre is on the screen: the middle unless the program
; defines them before the INCLUDE, for a view that is not the whole screen
; (model.project_far and model.object_lines take the same).
					IFNDEF	SCREEN_CENTRE_X
SCREEN_CENTRE_X		EQU		128
					ENDIF
					IFNDEF	SCREEN_CENTRE_Y
SCREEN_CENTRE_Y		EQU		96
					ENDIF
SCREEN_HEIGHT		EQU		192

project:
					ld		hl,(rot_z)
					ld		de,(zoff)
					add		hl,de
					ld		a,h
					or		a
					scf
					ret		z					; Z = 0: at or behind the eye
					ld		c,a
					ld		hl,(rot_y)
					call	divide				; HL = rot_y / Z
					ret		c
					ex		de,hl
					ld		hl,SCREEN_CENTRE_Y
					or		a
					sbc		hl,de				; down the screen from its centre
					ld		a,h
					or		a
					scf
					ret		nz
					ld		a,l
					cp		SCREEN_HEIGHT
					ccf
					ret		c
					push	af
					ld		hl,(rot_x)
					call	divide				; HL = rot_x / Z
					pop		de					; D = y
					ret		c
					ld		bc,SCREEN_CENTRE_X
					add		hl,bc
					ld		a,h
					or		a
					scf
					ret		nz
					ld		b,l
					ld		c,d
					and		a					; carry clear: on the screen
					ret

zoff:				DW		128 * 256			; 128 * the eye's distance


; ---------------------------------------------------------------------------
; divide: HL = HL / C, signed by unsigned, truncated toward zero; carry set
; (and HL lost) if the quotient will not fit a byte, |HL| >= 256 C.
; In: C = 1..255. Uses A, HL. 333..453 T-states (43 when it does not fit).

divide:
					bit		7,h
					jr		z,divide_unsigned
					xor		a					; HL = -HL
					sub		l
					ld		l,a
					sbc		a,a
					sub		h
					ld		h,a
					call	divide_unsigned
					ret		c
					xor		a					; HL = -HL
					sub		l
					ld		l,a
					sbc		a,a
					ld		h,a
					or		a					; carry clear
					ret

; One bit of the quotient: the remainder in A takes the next bit of the
; dividend from L's top, which takes the last bit of the quotient, inverted,
; from the carry. A remainder past 255 (only possible when C > 128) is always
; at least C. The OR clears the borrow that subtraction can leave: taking it
; out of line for that case alone was tried and lost, since Z is normalised
; to 128..255 for anything far and the overflow then comes every other bit.
					MACRO	DIVIDE_BIT
					rl		l
					rla
					jr		c,.subtract
					cp		c
					jr		c,.next
.subtract:			sub		c
					or		a
.next:
					ENDM

divide_unsigned:
					ld		a,h
					cp		c
					ccf
					ret		c					; H >= C: more than 255
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					DIVIDE_BIT
					rl		l
					ld		a,l
					cpl
					ld		l,a
					ld		h,0					; and carry clear: the 0 the first
					ret							; bit shifted in, out again
