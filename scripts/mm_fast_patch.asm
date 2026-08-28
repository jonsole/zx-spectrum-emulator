; ---------------------------------------------------------------------------
; Manic Miner "dirty cell" patch -- see scripts/build_manicminer_fast.py
;
; Stock Manic Miner rebuilds the whole play area every pass through its main
; loop: a 4096-byte LDIR to restore the empty cavern into the working buffer
; at 0x6000, and another 4096-byte LDIR to blit that buffer to the display
; file. At 21 T-states per byte that is 172,022 T-states -- nearly 2.5 PAL
; frames -- spent copying, every single iteration, whether or not anything in
; a given cell actually changed.
;
; This patch splits each of the 16 character rows into four quarters of eight
; columns, records the range of columns drawn into within each quarter, and
; copies only those. Two earlier granularities were measured and rejected:
;
;   whole rows        1.0x. The guardians are spread down the cavern, so
;                     between four of them, Willy, the portal, the items and
;                     the conveyor, 10-13 of the 16 rows are dirty every
;                     frame. The quarter of the copying it skipped came
;                     straight back as per-row loop overhead.
;   one span per row  1.65x. Better, but two sprites at opposite ends of a
;                     row make one span covering everything between them --
;                     eleven columns of thirty-two, measured.
;
; Quartering keeps sprites in separate spans without having to scan a bitmap
; for runs, which is what makes it cheap: the index does the work.
;
; Placement: this code occupies 0x9D00-0x9FFF, uncontended RAM, so the copy
; loop takes no ULA wait states on opcode fetches. That space is bought as
; follows, and nothing else in the image moves:
;
;   0x9D00  MESSINTRO, the title screen's scrolling message. Exactly 256
;           bytes and page-aligned, relocated by the build script to 0x5B00 --
;           the ZX printer buffer, which Manic Miner never touches, since it
;           runs with interrupts disabled from startup and so has no use for
;           the printer or the system variables.
;   0x9E00  LOWERATTRS, 512 bytes of attributes for the bottom two thirds of
;           the title screen. It is only 18 runs long, so the build script
;           re-encodes it as run-length pairs and LOWERFILL below expands it
;           back out -- same pixels, ~470 bytes cheaper.
;
; Every hook replaces an existing instruction with one of exactly the same
; length, so every other address in the game is unchanged.
; ---------------------------------------------------------------------------
FASTBASE:

; One byte per quarter-row: 16 rows x 4 quarters, indexed row*4+quarter. Each
; byte packs the span of columns drawn into within that quarter as
; (high << 3) | low, both 0-7 and relative to the quarter. A quarter with
; nothing in it holds low=7, high=0, which reads as high < low.
;
; The two tables must stay adjacent and inside one page: the indexing below
; builds only the low byte of the address, and steps between the tables by
; adding 64 to it.
EMPTYCELL:  EQU 7         ; low=7, high=0
FULLCELL:   EQU 56        ; low=0, high=7

CELLPREV:
  DUP 64
  DEFB FULLCELL           ; quarters drawn into last frame
  EDUP
CELLTHIS:
  DUP 64
  DEFB FULLCELL           ; quarters drawn into this frame
  EDUP

SRCMSB:
  DEFB 0                  ; high byte of the buffer being copied from
DSTMSB:
  DEFB 0                  ; high byte of the buffer being copied to
CELLIDX:
  DEFB 0                  ; quarter-row being copied
SPANW:
  DEFB 0                  ; columns in the span being copied
MKROW:
  DEFB 0                  ; row being marked
MKROWS:
  DEFB 0                  ; rows left to mark
MKLO:
  DEFB 0                  ; leftmost column being marked
MKHI:
  DEFB 0                  ; rightmost column being marked

; ---------------------------------------------------------------------------
; Record columns C to E as drawn into, for B character rows starting at row A.
; Rows at or past 16 are ignored: the play area is rows 0-15, and the cavern
; name, air bar and score in the bottom third are drawn straight to the
; display file rather than through the buffers. Preserves every register.
; ---------------------------------------------------------------------------
MARKCELLS:
  PUSH AF
  PUSH BC
  PUSH DE
  PUSH HL
  LD (MKROW),A
  LD A,B
  LD (MKROWS),A
  LD A,C
  LD (MKLO),A
  LD A,E
  LD (MKHI),A

MARKCELLS_0:
  LD A,(MKROW)
  CP 16
  JR NC,MARKCELLS_5       ; off the bottom of the play area
  ADD A,A
  ADD A,A                 ; four quarters per row
  ADD A,CELLTHIS & 255
  LD L,A
  LD H,CELLTHIS >> 8
  LD A,(MKLO)
  RRCA
  RRCA
  RRCA
  AND 3
  LD B,A                  ; first quarter touched
  LD A,(MKHI)
  RRCA
  RRCA
  RRCA
  AND 3
  LD C,A                  ; last quarter touched

MARKCELLS_1:
  PUSH HL
  LD A,L
  ADD A,B
  LD L,A                  ; this quarter's byte
  LD A,B
  ADD A,A
  ADD A,A
  ADD A,A                 ; the quarter's first column
  LD E,A
  LD A,(MKLO)
  SUB E
  JR NC,MARKCELLS_2
  XOR A                   ; the span starts before this quarter
MARKCELLS_2:
  LD D,A                  ; low, relative to the quarter
  LD A,(MKHI)
  SUB E
  CP 8
  JR C,MARKCELLS_3
  LD A,7                  ; the span runs past this quarter
MARKCELLS_3:
  LD E,A                  ; high, relative to the quarter

  LD A,(HL)
  AND 7
  CP D
  JR C,MARKCELLS_4        ; already reaches further left
  LD A,(HL)
  AND 56
  OR D
  LD (HL),A
MARKCELLS_4:
  LD A,(HL)
  RRCA
  RRCA
  RRCA
  AND 7
  CP E
  JR NC,MARKCELLS_45      ; already reaches further right
  LD A,E
  ADD A,A
  ADD A,A
  ADD A,A
  LD E,A
  LD A,(HL)
  AND 7
  OR E
  LD (HL),A
MARKCELLS_45:
  POP HL
  LD A,B
  CP C
  JR NC,MARKCELLS_5       ; that was the last quarter
  INC B
  JR MARKCELLS_1

MARKCELLS_5:
  LD A,(MKROW)
  INC A
  LD (MKROW),A
  LD A,(MKROWS)
  DEC A
  LD (MKROWS),A
  JR NZ,MARKCELLS_0
  POP HL
  POP DE
  POP BC
  POP AF
  RET

; ---------------------------------------------------------------------------
; Record B rows starting at the row containing HL, where HL is an address in
; one of the pixel buffers at 0x6000 or 0x7000. Both use the display file's
; layout: bit 3 of H selects the screen third, bits 5-7 of L give the row
; within it, and bits 0-4 of L the column. Preserves every register.
;
;   MARKHL   for a 16-pixel-wide sprite (two columns)
;   MARKHL1  for an 8-pixel-wide one (a single column)
; ---------------------------------------------------------------------------
MARKHL:
  PUSH AF
  PUSH DE
  PUSH BC
  LD A,L
  AND 31
  LD C,A
  INC A
  CP 32
  JR C,MARKHL_0
  LD A,31                 ; a sprite at column 31 wraps; keep the span in range
MARKHL_0:
  LD E,A
  JR MARKHL_2

MARKHL1:
  PUSH AF
  PUSH DE
  PUSH BC
  LD A,L
  AND 31
  LD C,A
  LD E,A

MARKHL_2:
  LD A,L
  RLCA
  RLCA
  RLCA
  AND 7                   ; row within the third
  LD D,A
  LD A,H
  AND 8                   ; third * 8
  OR D
  CALL MARKCELLS
  POP BC
  POP DE
  POP AF
  RET

; As MARKHL1, but for an address in the attribute buffer at 0x5C00, where the
; third is bit 0 of H.
MARKATTR:
  PUSH AF
  PUSH DE
  PUSH BC
  LD A,L
  AND 31
  LD C,A
  LD E,A
  LD A,L
  RLCA
  RLCA
  RLCA
  AND 7
  LD D,A
  LD A,H
  AND 1
  RLCA
  RLCA
  RLCA                    ; third * 8
  OR D
  CALL MARKCELLS
  POP BC
  POP DE
  POP AF
  RET

; ---------------------------------------------------------------------------
; Mark the whole play area, in both frames' tables. Used when something
; outside the normal sprite path has rewritten the buffers. Leaves the flags
; alone, so it can be called from a path carrying a result in them.
; ---------------------------------------------------------------------------
ALLDIRTY:
  PUSH AF
  PUSH BC
  PUSH HL
  LD HL,CELLPREV
  LD B,128                ; both tables
  LD A,FULLCELL
  JR CELLFILL

; Empty this frame's table, ready to accumulate.
CLEARTHIS:
  PUSH AF
  PUSH BC
  PUSH HL
  LD HL,CELLTHIS
  LD B,64
  LD A,EMPTYCELL

CELLFILL:
  LD (HL),A
  INC HL
  DJNZ CELLFILL
  POP HL
  POP BC
  POP AF
  RET

; ---------------------------------------------------------------------------
; Hooks. Each replaces a single instruction of identical length at its site,
; records the cells about to be drawn into, then does what the original
; instruction did.
; ---------------------------------------------------------------------------

; Replaces "LD HL,(PORTALLOC2)" in CHKPORTAL_0, which falls through into
; DRWFIX rather than calling it.
PORTHOOK:
  LD HL,(PORTALLOC2)
  LD B,3
  JP MARKHL               ; MARKHL preserves HL and returns

; Replaces the leading "LD A,(WILLY_Y)" of DRAWWILLY. WILLY_Y is a byte offset
; into the two-bytes-per-entry lookup table at SBUFADDRS, so it is twice
; Willy's pixel y-coordinate and his character row is WILLY_Y/16. His column
; comes from LOCATION, and his 16 pixel rows straddle three character rows.
WILLYHOOK:
  LD A,(WILLY_Y)
  PUSH AF
  PUSH BC
  PUSH DE
  LD A,(LOCATION)
  AND 31
  LD C,A
  INC A
  CP 32
  JR C,WILLYHOOK_0
  LD A,31
WILLYHOOK_0:
  LD E,A
  LD A,(WILLY_Y)
  RRCA
  RRCA
  RRCA
  RRCA
  AND 15                  ; (WILLY_Y / 2) / 8
  LD B,3
  CALL MARKCELLS
  POP DE
  POP BC
  POP AF
  RET

; Replaces "CALL PRINTCHAR_0" in DRAWITEMS, which draws an 8x8 item into the
; buffer with the destination address in DE.
ITEMHOOK:
  PUSH BC                 ; PRINTCHAR_0 expects B=8
  EX DE,HL
  LD B,1
  CALL MARKHL1
  EX DE,HL
  POP BC
  JP PRINTCHAR_0

; Replaces "CALL MVCONVEYOR" in the main loop. The conveyor animates in the
; empty-cavern buffer at 0x7000, so its cells have to be restored afresh every
; frame, not only when a sprite has been drawn over them. It spans CONVLEN
; tiles; caverns without a conveyor have CONVLEN zero.
CONVHOOK:
  PUSH AF
  PUSH BC
  PUSH DE
  PUSH HL
  LD A,(CONVLEN)
  OR A
  JR Z,CONVHOOK_1         ; no conveyor in this cavern
  LD HL,(CONVLOC)
  LD A,L
  AND 31
  LD C,A
  LD A,(CONVLEN)
  ADD A,C
  DEC A                   ; rightmost tile
  CP 32
  JR C,CONVHOOK_0
  LD A,31
CONVHOOK_0:
  LD E,A
  LD A,L
  RLCA
  RLCA
  RLCA
  AND 7
  LD D,A
  LD A,H
  AND 8
  OR D
  LD B,1
  CALL MARKCELLS
CONVHOOK_1:
  POP HL
  POP DE
  POP BC
  POP AF
  JP MVCONVEYOR

; Replaces "CALL Z,CRUMBLE" in MOVEWILLY (both sites). CRUMBLE eats away a
; floor tile in the 0x7000 buffer, with HL holding that tile's address in the
; attribute buffer.
CRUMBHOOK:
  LD B,1
  CALL MARKATTR
  JP CRUMBLE

; Replaces "CALL CHKSWITCH" in KONGBEAST (both sites). Flipping a switch opens
; a wall or drops a floor by rewriting the 0x7000 buffer, so the play area has
; to be repainted in full. Returns with CHKSWITCH's flags intact.
SWHOOK:
  CALL CHKSWITCH
  RET NZ                  ; switch not flipped -- nothing was rewritten
  JP ALLDIRTY

; Replaces the leading "LD A,(SHEET)" of NEWSHT, the single entry point for
; starting, restarting and advancing a cavern.
NEWHOOK:
  CALL ALLDIRTY
  LD A,(SHEET)
  RET

; Replaces "JP LOOP_4" at KILLWILLY_1, which abandons the current frame's
; drawing part-way through and jumps straight to the blit.
KILLHOOK:
  CALL ALLDIRTY
  JP LOOP_4

; ---------------------------------------------------------------------------
; Copy a span of B columns from HL to DE, eight pixel rows deep.
;
; Column-major rather than row-major: the eight bytes of one column are 256
; apart, so walking down a column is INC H, with no pointer to rebuild between
; pixel rows. Copying row-major instead means eight separate LDIRs, and for
; the two- and three-column spans this patch produces, the per-row setup costs
; more than the bytes it moves.
; ---------------------------------------------------------------------------
SPANCOPY:
  LD A,(HL)
  LD (DE),A
  INC H
  INC D
  LD A,(HL)
  LD (DE),A
  INC H
  INC D
  LD A,(HL)
  LD (DE),A
  INC H
  INC D
  LD A,(HL)
  LD (DE),A
  INC H
  INC D
  LD A,(HL)
  LD (DE),A
  INC H
  INC D
  LD A,(HL)
  LD (DE),A
  INC H
  INC D
  LD A,(HL)
  LD (DE),A
  INC H
  INC D
  LD A,(HL)
  LD (DE),A
  INC H
  INC D
  LD A,H
  SUB 8                   ; back to the top pixel row
  LD H,A
  LD A,D
  SUB 8
  LD D,A
  INC L                   ; one column right
  INC E
  DJNZ SPANCOPY
  RET

; ---------------------------------------------------------------------------
; Copy every dirty quarter-row from the buffer at (SRCMSB) to the one at
; (DSTMSB). A quarter's span is the union of the two tables: cells drawn into
; this frame need their sprites shown, and cells drawn into last frame but not
; this one need their restored background shown, to erase what was there. On
; the restore pass the two tables still hold the same values, so the union is
; simply last frame's spans.
; ---------------------------------------------------------------------------
COPYCELLS:
  XOR A
COPYCELLS_0:
  LD (CELLIDX),A
  ADD A,CELLPREV & 255
  LD L,A
  LD H,CELLPREV >> 8
  LD D,(HL)               ; last frame's packed span
  LD A,L
  ADD A,64                ; the same quarter in the other table
  LD L,A
  LD E,(HL)               ; this frame's packed span

  ; Most quarters hold nothing, and there are 64 of them on every pass, so
  ; settle that case before spending ~200 T-states unpacking both spans.
  LD A,D
  CP EMPTYCELL
  JR NZ,COPYCELLS_A
  LD A,E
  CP EMPTYCELL
  JR Z,COPYCELLS_3        ; untouched in both frames
COPYCELLS_A:
  LD A,D
  AND 7
  LD B,A
  LD A,E
  AND 7
  CP B
  JR NC,COPYCELLS_1
  LD B,A                  ; whichever reaches further left
COPYCELLS_1:
  LD A,D
  RRCA
  RRCA
  RRCA
  AND 7
  LD C,A
  LD A,E
  RRCA
  RRCA
  RRCA
  AND 7
  CP C
  JR C,COPYCELLS_2
  LD C,A                  ; whichever reaches further right
COPYCELLS_2:
  LD A,C
  CP B
  JR C,COPYCELLS_3        ; high below low: nothing was drawn here
  SUB B
  INC A
  LD (SPANW),A

  LD A,(CELLIDX)
  AND 3                   ; quarter
  ADD A,A
  ADD A,A
  ADD A,A                 ; * 8 columns
  ADD A,B                 ; + the span's first column
  LD C,A
  LD A,(CELLIDX)
  RRCA
  RRCA
  AND 15                  ; character row
  LD B,A
  AND 7
  RRCA
  RRCA
  RRCA                    ; (row within third) * 32
  ADD A,C
  LD L,A
  LD E,A                  ; both buffers share the low address byte
  LD A,B
  AND 8                   ; third * 8
  LD C,A
  LD A,(SRCMSB)
  ADD A,C
  LD H,A
  LD A,(DSTMSB)
  ADD A,C
  LD D,A
  LD A,(SPANW)
  LD B,A
  CALL SPANCOPY
COPYCELLS_3:
  LD A,(CELLIDX)
  INC A
  CP 64
  JR NZ,COPYCELLS_0
  RET

; ---------------------------------------------------------------------------
; Replaces the 4096-byte LDIR that restored the empty cavern into the working
; buffer. Only the cells drawn into last frame still hold sprite pixels, so
; only those need wiping back to the empty cavern.
; ---------------------------------------------------------------------------
FASTRESTORE:
  LD HL,24688             ; L = 0x70 source, H = 0x60 destination
  LD (SRCMSB),HL
  CALL COPYCELLS
  JP CLEARTHIS

; ---------------------------------------------------------------------------
; Replaces the 4096-byte LDIR that blitted the working buffer to the display
; file. This frame's spans then become last frame's.
; ---------------------------------------------------------------------------
FASTBLIT:
  LD HL,16480             ; L = 0x60 source, H = 0x40 destination
  LD (SRCMSB),HL
  CALL COPYCELLS
  LD HL,CELLTHIS
  LD DE,CELLPREV
  LD BC,64
  LDIR
  RET

; ---------------------------------------------------------------------------
; Expands the run-length encoded title screen attributes into DE. Replaces the
; 512-byte LDIR from LOWERATTRS, whose slot this patch has taken over.
; ---------------------------------------------------------------------------
LOWERFILL:
  LD HL,LOWERRLE
  JP RLEFILL              ; the expander lives in region 2

LOWERRLE:
; @@LOWERRLE@@

  DEFS 768-($-FASTBASE)   ; MESSINTRO's and LOWERATTRS's slots together are
                          ; exactly 768 bytes; keep TITLESCR1 at 0xA000

; @@REGION2@@
; ---------------------------------------------------------------------------
; Second patch region, in TITLESCR2's slot at 0xA800-0xAFFF.
;
; TITLESCR2 is the middle third of the title screen bitmap: 2048 bytes, but
; only 648 runs, so run-length encoded it is 1297 and buys ~750 bytes. That is
; what pays for the IM 2 vector table below -- the first region was full.
;
; TITLESCR1 and TITLESCR2 are contiguous and START copies all 4096 bytes to
; the display file in one LDIR, so TITLEFILL now does it in two steps.
; DRAWSHEET's separate 2048-byte copy of TITLESCR1 alone, for The Final
; Barrier, is untouched.
; ---------------------------------------------------------------------------

; The handler must sit at an address whose two halves are equal: both bytes of
; the interrupt vector are read out of the table, and the table holds a single
; repeated value. The table itself must be page-aligned. Pinning both here
; lets the padding below reach them, and fails the build if the run-length
; data ever grows past either.
INTHANDLER_ADDR:  EQU 44461     ; 0xADAD
IM2TABLE_ADDR:    EQU 44544     ; 0xAE00

REGION2BASE:

TITLE2RLE:
; @@TITLE2RLE@@

; Expand run-length pairs -- (count, value), a zero count ends it -- into DE.
RLEFILL:
  LD B,(HL)
  INC HL
  LD A,B
  OR A
  RET Z
  LD A,(HL)               ; the byte to repeat
  INC HL
RLEFILL_0:
  LD (DE),A
  INC DE
  DJNZ RLEFILL_0
  JR RLEFILL

; Replaces START's 4096-byte LDIR of the title screen bitmap.
TITLEFILL:
  LD HL,TITLESCR1
  LD DE,16384
  LD BC,2048              ; the top third is still stored literally
  LDIR
  LD HL,TITLE2RLE
  JP RLEFILL              ; DE now points at the middle third

; ---------------------------------------------------------------------------
; Wait for the frame interrupt, so each pass through the main loop starts at a
; fixed point in the raster rather than wherever the last one happened to end.
;
; Manic Miner runs with interrupts disabled from startup and cannot simply
; enable them: in IM 1 the ROM's handler increments FRAMES at 0x5C78 and scans
; the keyboard into the system variables, all of which sit inside the
; attribute buffer the game keeps at 0x5C00-0x5DFF. Freeing that buffer is
; very likely why the interrupts were turned off in the first place. So this
; uses IM 2 with a handler of its own, which touches nothing.
;
; Interrupts stay enabled for the rest of the loop, so they keep arriving while
; the frame's work is going on and the handler counts them. Waiting for a set
; count, rather than just HALTing once, is what makes the cadence fixed: a bare
; HALT waits for the next interrupt, so a pass takes ceil(work) frames and
; flips between two and three as the workload crosses the boundary. Counting
; pins it at SYNCFRAMES whether the work took 1.5 frames or 2.9.
;
; An overrunning pass simply finds the count already reached and does not wait,
; so it slips a frame and the next pass carries on from there, rather than the
; cadence changing permanently.
;
; The setup is idempotent and costs ~26 T-states, so it runs every pass rather
; than needing a separate one-time hook.
; ---------------------------------------------------------------------------
SYNCFRAMES: EQU 3         ; frames per pass through the main loop

SYNCWAIT:
  LD A,IM2TABLE_ADDR >> 8
  LD I,A
  IM 2
  EI
SYNCWAIT_0:
  LD A,(FRAMECT)
  CP SYNCFRAMES
  JR NC,SYNCWAIT_1        ; that many have already gone by
  HALT
  JR SYNCWAIT_0
SYNCWAIT_1:
  XOR A                   ; start counting the next pass from here
  LD (FRAMECT),A
  RET

; The wait is spent in HALT rather than holding the note across it. Sustaining
; was tried and sounds wrong: the in-game tune is deliberately sparse, a
; ~31,000 T-state blip against ~219,000 of silence in stock, and filling the
; gap turns it into a drone. It needs no filling anyway -- the pass is shorter
; here than stock's, so the game's own unmodified note already occupies a
; slightly larger share of it (14.8% against 12.4%).

  DEFS INTHANDLER_ADDR-$
INTHANDLER:
  PUSH AF
  PUSH HL
  LD HL,FRAMECT
  INC (HL)
  POP HL
  POP AF                  ; an interrupt lands anywhere, so restore the flags
  EI
  RET

FRAMECT:
  DEFB 0                  ; frame interrupts since the last sync point

; The vector is read from (I << 8) | whatever is on the data bus, which floats
; to 0xFF on an unexpanded 48K. A full 257-byte table of one repeated value is
; the standard way to make that read land somewhere known whatever the bus
; does, and there is room for it here.
  DEFS IM2TABLE_ADDR-$
IM2TABLE:
  DUP 257
  DEFB INTHANDLER_ADDR & 255
  EDUP

; Replaces every "CALL DRWFIX". DRWFIX draws 16 pixel rows two columns wide,
; straddling three character rows unless the sprite starts on a row boundary
; -- Eugene, the Skylabs, the vertical guardians and the Kong Beast all move a
; pixel at a time, so they usually do not. DRWFIX also draws straight to the
; display file during the title screen and the game over sequence, so only
; draws into the buffer at 0x6000 are tracked.
DRWFIXM:
  LD B,2
  LD A,H
  AND 7                   ; pixel row within the character row
  JR Z,DRWFIXM_0
  INC B                   ; off a row boundary, so it spans a third row
DRWFIXM_0:
  BIT 5,H                 ; set only for the 0x6000/0x7000 buffers
  CALL NZ,MARKHL
  JP DRWFIX

  DEFS 2048-($-REGION2BASE)
