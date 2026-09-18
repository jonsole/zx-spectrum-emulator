; ---------------------------------------------------------------------------
; The sounds the engine asks a game for.
;
; walker.s calls sound_jump when a jump starts and sound_z when a fall gets
; faster than two units a turn. It wants nothing back from either, so a RET is
; a complete implementation -- and that is what these are, rather than stubs:
; Pentagram's own effects have not been worked out, so the honest answer for
; now is that he jumps and falls silently.
;
; When they do arrive they belong here, and they go through engine/sound.s,
; whose timing counts towards the turn -- so anything added has to be paid for
; out of turn_pace's budget rather than taken on top of it.
; ---------------------------------------------------------------------------

sound_jump:         ret
sound_z:            ret
