; Aviator for the 48K Spectrum, after Geoff Crammond's BBC Micro original
; (Acornsoft, 1983) as documented by Mark Moxon at aviator.bbcelite.com.
;
; The game's logic follows model/, the Python port, routine for routine and
; bit for bit; the screen follows model/zx.py. See README.md.
;
; Memory:
;
;   $4000  the screen: the canopy in character rows 0-14, the dashboard 15-23
;   $5B00  code that is not on any hot path
;   $6000  the recorded flight stage 1 replays
;   $8000  the original's data, at its BBC address + $8000 (layout.py), with
;          Z80 code in the gaps where the 6502 code was
;   $D800  the canopy view's buffer, 114 rows of 32 bytes
;   $E800  quarter squares for multiplying, four pages
;   $EC00  the view's tables: x and y to the Spectrum's, pixel masks, screen
;          row addresses, the frame's overlay
;   $FC00  the stack, down from $FDF0
;   $FDFD  the IM 2 handler's jump, $FE00 its vector table

    DEVICE ZXSPECTRUM48

    INCLUDE "gen_bbc_labels.s"

CANOPY_BUFFER   equ $D800
CANOPY_ROWS     equ 114
SQ_LO           equ $E800       ; (n * n / 4) & $FF for n = 0..511, two pages
SQ_HI           equ $EA00       ; and >> 8
view_x          equ $EC00       ; the Spectrum x of BBC x
view_y          equ $ED00       ; the buffer row of BBC canopy y
bit_masks       equ $EE00       ; $80 >> n
view_rows       equ $EE08       ; the screen address of each buffer row
canopy_overlay  equ $EF00       ; (keep, OR) for bytes 0, 1, 30, 31 of each row
ext_lo          equ $F300       ; this view's first column drawn in, each row
ext_hi          equ ext_lo + 120 ; and last
prev_lo         equ ext_lo + 256 ; the last view's
prev_hi         equ prev_lo + 120
STACK_TOP       equ $FDF0
IM2_JUMP        equ $FDFD
IM2_TABLE       equ $FE00

; ---- the screen, as the game starts -------------------------------------

    ORG $4000
    INCBIN "gen_screen.bin"

; ---- code off the hot paths ---------------------------------------------

    ORG $5B00
start:
    di
    ld sp,STACK_TOP
    call im2_init
    ei
    jp fly_recorded

; The frame interrupt only counts frames.
im2_init:
    ld hl,IM2_TABLE
    ld (hl),high IM2_JUMP
    ld de,IM2_TABLE + 1
    ld bc,256
    ldir
    ld a,$C3                    ; JP
    ld (IM2_JUMP),a
    ld hl,frame_interrupt
    ld (IM2_JUMP + 1),hl
    ld a,high IM2_TABLE
    ld i,a
    im 2
    ret

frame_interrupt:
    push hl
    ld hl,(frames)
    inc hl
    ld (frames),hl
    pop hl
    ei
    reti

frames:     dw 0
start_end:

; ---- the hot code, in the gaps of the data window -------------------------

    ORG $8D00
    INCLUDE "maths.s"
    INCLUDE "matrices.s"
    INCLUDE "points.s"
    INCLUDE "project.s"
    INCLUDE "visibility.s"
    INCLUDE "clip.s"
    ASSERT $ <= $AE60

    ORG $AEA0
    INCLUDE "canopy.s"
    INCLUDE "view.s"
    ASSERT $ <= $B400

; ---- stage 1's driver, off the hot paths (assembled after the modules whose
; macros it uses) ---------------------------------------------------------------

    ORG start_end
    INCLUDE "stage1.s"
    ASSERT $ <= $6000

    ORG $6000
    INCLUDE "gen_flight.s"
    ASSERT $ <= $8000

; ---- the original's data ---------------------------------------------------

    INCLUDE "gen_bbc_data.s"

; ---- tables ----------------------------------------------------------------

    ORG CANOPY_BUFFER
    INCBIN "gen_buffer.bin"
    ORG ext_lo
    INCBIN "gen_extents.bin"
    ORG SQ_LO
    INCLUDE "gen_tables.s"
    ORG view_x
    INCLUDE "gen_view.s"

    SAVEBIN "output/aviator.bin", $4000, $C000
