; ---------------------------------------------------------------------------
; Keep the nearly empty rooms from racing.
;
; A turn takes as long as its work, and a room with nothing moving in it has
; almost none: a hundred turns a second, against twenty or thirty in a busy
; one. Knight Lore holds every frame to a fixed budget, counting interrupts in
; game_delay; we cannot count interrupts, because every part of the drawing
; path borrows SP and a single interrupt taken there would write into a sprite.
;
; So the turn counts its own work instead, as it goes, in units of about
; TURN_UNIT_T T-states, and whatever is left of TURN_BUDGET_T at the end is
; spent in a delay loop. A turn already over the budget pays nothing, so the
; busy rooms go exactly as fast as they did.
;
; The counts come from measuring: 258 turns across 43 rooms, timed by the
; emulator and fitted against what each did. A turn costs about 5,400 T to
; begin with, 172 for every row a blit composites and 1,300 for the blit itself,
; 3,900 for every region drawn, 15,000 for every collision gather, and 620 for
; every row rotated. Rounded into units, that predicts a turn to within 4,000 T
; for half of them and 10,000 T for nine in ten -- near enough, when the only
; question is how much of the gap to fill.
;
; It errs a little low, though -- a real turn runs some thousands of T past its
; count -- so the budget is set below the pace it is meant to give. Measured
; turn by turn across all 128 rooms: the 60 that ran faster than 45 turns a
; second now run at 33 to 38, median 35; a room already slower than about 30 is
; untouched; and a turn over the budget is never padded. What it costs is a
; little in the rooms just under the cap whose turns vary, where the light ones
; are padded and the heavy ones are not -- $09 and $12 lose about four and
; seven turns a second.
TURN_BUDGET_T       EQU     86000               ; about 35 turns a second
TURN_UNIT_T         EQU     172
TURN_BASE_T         EQU     5400
TURN_PER_BLIT       EQU     8                   ; plus a unit a row
TURN_PER_REGION     EQU     23
TURN_PER_GATHER     EQU     87
TURN_SPIN           EQU     11                  ; DJNZs making up one unit

turn_work:          DW      0

; Add A units to the turn's work. Corrupts AF and HL.
turn_add:           ld      hl,turn_work
                    add     a,(hl)
                    ld      (hl),a
                    ret     nc
                    inc     hl
                    inc     (hl)
                    ret


; Spend what is left of the budget, and start the next turn's count.
; One pass of .wait is 7 + (TURN_SPIN * 13 - 5) + 26 = 171 T, which is the unit.
turn_pace:          ld      hl,(TURN_BUDGET_T - TURN_BASE_T) / TURN_UNIT_T
                    ld      de,(turn_work)
                    or      a
                    sbc     hl,de
                    push    af                  ; carry: over the budget
                    push    hl

                    ; How long the turn will have taken -- its work, or the
                    ; budget if that is longer -- onto the sound clock, and a
                    ; new Knight Lore frame for the sounds when that passes
                    ; SOUND_FRAME_T. See sound.s.
                    jr      c,.long
                    ld      de,(TURN_BUDGET_T - TURN_BASE_T) / TURN_UNIT_T
.long:              ld      hl,(sound_clock)
                    add     hl,de
                    ld      de,TURN_BASE_T / TURN_UNIT_T - SOUND_FRAME_T / TURN_UNIT_T
                    add     hl,de               ; its start, less a frame: carry if
                                                ; a frame has gone by
                    sbc     a,a
                    jr      c,.frame
                    ld      de,SOUND_FRAME_T / TURN_UNIT_T
                    add     hl,de               ; not yet: put the frame back
.frame:             ld      (sound_clock),hl
                    ld      (sound_now),a
                    pop     hl
                    pop     af

                    ld      de,0
                    ld      (turn_work),de
                    ret     c                   ; over the budget already
                    ret     z
.wait:              ld      b,TURN_SPIN
.spin:              djnz    .spin
                    dec     hl
                    ld      a,h
                    or      l
                    jr      nz,.wait
                    ret
