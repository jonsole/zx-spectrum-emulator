; A Revs-style road engine for the 48K Spectrum.
;
; The track is Geoff Crammond's design from BBC Micro Revs -- sections and
; segment vectors, verges seen as pitch and yaw angles, edges drawn as colour
; changes and filled to the right -- reworked for the Z80. See README.md for
; how it maps onto the BBC routines and what is not done yet.
;
; Memory, all uncontended above $8000 except the screen:
;
;   $8000  code
;   $A000  page-aligned lookup tables (tables.py), seven pages
;   $A800  the track data file, exactly as the BBC loads it (track_data.py)
;   $B000  the view buffer: 80 lines of 32 bytes, top line first
;   $BA00  per-frame verge point lists
;   $C000  every segment's 16-bit coordinates: five arrays of 1024 words
;   $E800  every segment's flags, 1024 bytes
;   $EC00  the edge markers: 128 lines of 32 bytes (80 seen, the rest above)
;   $FC00  the stack, down from $FDF0
;   $FDFD  the IM2 handler's jump, $FE00 its vector table

    DEVICE ZXSPECTRUM48

SEG_XI      equ $C000           ; inner verge x, one word per segment
SEG_YI      equ $C800           ; both verges' height
SEG_ZI      equ $D000
SEG_XO      equ $D800           ; outer verge
SEG_ZO      equ $E000
SEG_FLAGS   equ $E800           ; the section's flag byte, per segment
VIEWBUF     equ $B000
MARKERS     equ $EC00
STACK_TOP   equ $FDF0

VIEW_LINES  equ 80              ; track lines, 0 at the bottom, 79 at the top
VIEW_TOP    equ 16              ; the screen row track line 79 is drawn on

    ORG $8000
start:
    di
    ld sp,STACK_TOP
    call screen_init
    call build_track
    call markers_init
    call im2_init
    call camera_init
    ei
main_loop:
    call camera_update
    call verges_build
    call edges_build
    call compose_view
    halt                        ; the copy runs ahead of the beam from here
    call view_copy
    call fps_show
    jr main_loop

    INCLUDE "screen.s"
    INCLUDE "track.s"
    INCLUDE "maths.s"
    INCLUDE "camera.s"
    INCLUDE "verges.s"
    INCLUDE "edges.s"
    INCLUDE "compose.s"
    INCLUDE "patterns.s"
code_end:
    ASSERT code_end <= $A000

    ORG $A000
    INCLUDE "tables.s"          ; generated, in output/
    ASSERT $ <= $A800

    ORG $A800
track:
    INCLUDE "track.s.gen"       ; generated, in output/: the track data file
    ASSERT $ <= $B000

    SAVEBIN "output/revs.bin",$4000,$C000
