; fast3d: mul8s, signed 8 x 8 -> 16 bits by quarter squares.
;
; a*b = f(a+b) - f(a-b), with f(n) = floor(n*n/4) looked up in tables.s. Both
; a+b and a-b take nine bits, so each is worked out on the bytes biased by
; 128 (a xor $80), where the ninth bit comes out in the carry: rl moves it
; into the table's page.
;
; In: B = a, C = b, signed. Out: HL = a*b. Uses A, BC, DE.
; 154 T-states, with the RET.

mul8s:
					ld		a,b
					xor		$80
					ld		b,a					; B = a + 128
					ld		a,c
					xor		$80
					ld		c,a					; C = b + 128
					add		a,b					; a + b + 256: carry is its 9th bit
					ld		l,a
					ld		h,high SQ_LO / 2
					rl		h					; HL = SQ_LO + a + b + 256 = &f(a+b)
					ld		a,c
					sub		b					; b - a: borrow if negative
					ld		e,a
					ccf
					ld		d,high SQ_LO / 2
					rl		d					; DE = SQ_CENTRE + b - a = &f(b-a)
					ld		a,(hl)
					ex		de,hl
					sub		(hl)				; f(a+b) - f(b-a), low bytes
					ld		c,a
					inc		h					; the high bytes, two pages up
					inc		h
					inc		d
					inc		d
					ld		a,(de)
					sbc		a,(hl)
					ld		h,a
					ld		l,c
					ret
