; Cyberun's landscape renderer.
;
; Ultimate Play The Game's own code from Cyberun (1986), taken from the
; Cyberun disassembly in game-disassemblies (scripts/build_cyberun.py; how it
; works is notes/cyberun/landscape.md there): scroll_landscape moves the view
; by this pass's scroll, and draw_landscape draws every step of the four map
; pages the view can see straight onto the screen with POP blitters, from
; graphics pre-shifted for 0, 2, 4 and 6 pixels, then fills the strips that
; moving edges uncover. The screen is never cleared. ADR 0007.
;
; It is assembled wherever Jetrun puts it: every address the listing had as a
; number inside the renderer is a label here (cy_XXXX names the instruction
; or byte at Cyberun's address $XXXX that something patches or points into).
; The step graphics' shifted copies, which Cyberun made at start-up
; (build_shifted_pieces), are given as the bytes it made. Jetrun's changes are
; marked "Jetrun:": its map and tiles; the fly-in, objects and Cyberun's
; fixed stack depth gone. The variables at the end were in
; Cyberun's system-variable area.
;
; Jetrun supplies MAP_W, MAP_H, EMPTY_TILE, world_map, tile_table and the
; page-aligned bit_reverse_table.

  MODULE cyberun

; Adjust a landscape run's start and width for its end pieces
;
; Used by the routine at fill_behind_moving_piece.
;
; Called by fill_behind_moving_piece (when the byte at piece_rise is 0) just
; before it draws a run of the landscape. piece_extra_a and piece_extra_b hold
; the codes of the run's first and last pieces (piece_ends sets them from the
; map); pieces $90-$93 are ends that need the run moved or widened, depending
; on the scroll step across (the second byte of scroll_down) and on E, which is
; 0 or $AA (fill_behind_moving_piece sets DE to 0 or $55AA, the dither's
; phase). B is added to the run's x and C to its width.
;
; The width's base is the operand of the LD A,n near the end of this routine,
; which fill_behind_moving_piece writes as its own width less one. The result
; goes to piece_step_y and HL is left at the run's screen position from
; saved_speed with x moved.
;
; How the pieces look and why each case needs its adjustment is not yet worked
; out; a first piece of $93 never came up in the build's sessions.
;
;   IX The landscape strip's record (nothing is done when +1 is 0)
;   E 0 or $AA
; O:HL The run's screen position, x moved by B
; O:A Its width, also in piece_step_y
landscape_end_pieces:
  LD A,(IX+$01)           ; Nothing for a strip whose +1 is 0
  AND A                   ;
  RET Z                   ;
  LD HL,(piece_extra_a)   ; The first and last pieces' codes; B and C from them
  LD BC,$0000             ; (first_piece_shift, last_piece_width)
  CALL first_piece_shift  ;
  CALL last_piece_width   ;
  LD A,L                       ; First piece $91 with the last below $80 and
  CP $91                       ; E=0: one wider
  JR NZ,landscape_end_pieces_0 ;
  BIT 7,H                      ;
  JR NZ,landscape_end_pieces_0 ;
  LD A,E                       ;
  AND A                        ;
  JR NZ,landscape_end_pieces_0 ;
  INC C                        ;
landscape_end_pieces_0:
  LD A,L                       ; First piece $93: one wider when E=0, if the
  CP $93                       ; landscape scrolls this pass or saved_speed is
  JR NZ,landscape_end_pieces_2 ; not on a byte boundary
  LD A,(scroll_across)         ;
  AND A                        ;
  JR NZ,landscape_end_pieces_1 ;
  LD A,(saved_speed)           ;
  AND $07                      ;
  JR Z,landscape_end_pieces_2  ;
landscape_end_pieces_1:
  LD A,E                       ;
  AND A                        ;
  JR NZ,landscape_end_pieces_2 ;
  INC C                        ;
landscape_end_pieces_2:
  LD HL,(saved_speed)     ; The run's position, x moved by B
  LD A,L                  ;
  ADD A,B                 ;
  LD L,A                  ;
cy_8383:
  LD A,$00                ; Width = the base fill_behind_moving_piece wrote
  ADD A,C                 ; into the operand + C
  LD C,A                  ;
  LD (piece_step_y),A     ;
  RET                     ;

; Widen a landscape run for its last piece
;
; Used by the routine at landscape_end_pieces.
;
; Part of landscape_end_pieces: one wider when the last piece (piece_extra_b)
; is $93 and E is 0, or $92 and E is not 0.
;
; E 0 or $AA
; C The width so far
last_piece_width:
  LD A,(piece_extra_b)    ; Only pieces $92 and $93
  CP $93                  ;
  JR Z,last_piece_width_1 ;
  CP $92                  ;
  JR Z,last_piece_width_0 ;
  RET                     ;
last_piece_width_0:
  LD A,E                  ; $92: one wider unless E=0
  AND A                   ;
  RET Z                   ;
  INC C                   ;
  RET                     ;
last_piece_width_1:
  LD A,E                  ; $93: one wider when E=0
  AND A                   ;
  RET NZ                  ;
  INC C                   ;
  RET                     ;

; Move a landscape run's start for its first piece
;
; Used by the routine at landscape_end_pieces.
;
; Part of landscape_end_pieces, for the first piece (piece_extra_a). $90: B=7
; when E=0; otherwise B is minus the scroll step across (the second byte of
; scroll_down) when that is positive, with the run one wider, and 0 when it is
; not. $91: B=7 unless E=0, when it is minus the scroll step. Other pieces
; leave B at 0.
;
; L holds piece_extra_a itself here, so the AND 7 near the end always gives 0
; for piece $90 and the run is always one wider on that path.
;
;   E 0 or $AA
; O:B The shift in x
first_piece_shift:
  LD A,(piece_extra_a)     ; Only pieces $90 and $91
  CP $90                   ;
  JR Z,first_piece_shift_0 ;
  CP $91                   ;
  RET NZ                   ;
  LD A,E                   ; $91
  AND A                    ;
  JR Z,first_piece_shift_1 ;
  LD B,$07                 ;
  RET                      ;
first_piece_shift_0:
  LD B,$07                ; $90 with E=0: 7
  LD A,E                  ;
  AND A                   ;
  RET Z                   ;
  LD B,$00                ; Otherwise 0 unless the scroll step is positive...
  LD A,(scroll_across)    ;
  BIT 7,A                 ;
  RET NZ                  ;
  AND A                   ;
  RET Z                   ;
  LD A,L                    ; ...then one wider
  AND $07                   ;
  JR NZ,first_piece_shift_1 ;
  INC C                     ;
first_piece_shift_1:
  LD A,(scroll_across)    ; And B is minus the scroll step
  NEG                     ;
  LD B,A                  ;
  RET                     ;

; This pass's vertical scroll
;
; Signed, in pixels: the ship's step up this pass, worked out from its climb
; speed (move_ship), positive climbing; 0 while dying. With scroll_across it is
; read as a word by draw_stars.
scroll_down:
  DEFB $00

; This pass's horizontal scroll
;
; Signed, in pixels, a multiple of 2 (speed_to_scroll).
scroll_across:
  DEFB $00

; Something to do for this star
;
; Bit 0 set by draw_star_layer and star_in_sight when the star has an old image
; to erase or a new one to draw.
star_drawn:
  DEFB $00

; This pass's shift table
;
; Chosen by draw_landscape from the fine scroll: one of the four tables from
; piece_blitters_shift2 (shifts 2, 4, 6, then 0) (sixteen entries of four
; bytes, one per piece direction: a blitter entry point and the address of the
; piece's graphic at that shift).
shift_table:
  DEFW $0000

; The landscape's graphic-offset table
;
; Six bytes for each piece direction 0 to 8 (directions 7 to 13 use 0 to 6's
; rows, 14 and 15 rows 7 and 8: the code in landscape_step_loop that finds the
; row). The byte at the row plus twice the column's variety (0-2, from
; column_varieties), plus one if the fine scroll is not 0 (draw_landscape then
; starts the table one byte on), is the offset into the piece's graphic at
; which its POP blitter starts: so each column of a flat run can show one of
; three stretches of the ground's graphic.
graphic_offsets:
  DEFB $00,$00,$0C,$0C,$18,$18
  DEFB $00,$00,$12,$1B,$24,$36
  DEFB $00,$00,$09,$12,$12,$24
  DEFB $00,$00,$11,$22,$22,$44
  DEFB $00,$00,$12,$1B,$24,$36
  DEFB $00,$00,$09,$12,$12,$24
  DEFB $00,$00,$11,$22,$22,$44
  DEFB $00,$00,$11,$22,$22,$44
  DEFB $00,$00,$11,$22,$22,$44

; Move the column address on by the piece's column step, and stop the piece
; stepping
;
; Used by the routines at set_right_clip_columns, use_mirrored_right_clip and
; slope_step_at_left_edge.
;
; Used by the clipping code at use_mirrored_right_clip and
; slope_step_at_left_edge: the current column's screen address (its low byte,
; column_address) takes the piece's column step at once, and the piece's x and
; column steps (piece_dx, piece_dcolumn) become zero.
fold_column_step:
  LD A,(column_address)   ; Add the step; clear both steps.
  LD B,A                  ;
  LD A,(piece_dcolumn)    ;
  ADD A,B                 ;
  LD (column_address),A   ;
  XOR A                   ;
  LD (piece_dcolumn),A    ;
  LD (piece_dx),A         ;
  RET                     ;

; Set up a piece's steps from its direction
;
; Used by the routine at draw_landscape.
;
; Called for each piece by draw_landscape with the piece's direction in +3 of
; the piece state at IX (current_piece). A tile turned upside down
; (draw_landscape's $99) first remaps the direction through upside_down_table:
; 0-6 to 7-13 and back, which turns each piece over top to bottom. Then
; set_piece_shape loads the direction's three steps from piece_shapes: the x
; step in pixels (piece_dx), the column step in screen bytes (piece_dcolumn)
; and the rise in rows (piece_rise), each per step of the piece, and sets
; direction_flag to $FF for a piece that steps right or 1 for one that steps
; left.
;
; The directions, by their steps (x pixels, bytes, rows): 0 flat (24, 3, 0); 1
; a gentle slope (16, 2, 8); 2 a steep one (8, 1, 8); 3 steeper (8, 1, 16); 4-6
; the same three going left (-16, -2, 8; -8, -1, 8; -8, -1, 16); 7-13 the same
; seven upside down (the rise is still taken from 0-6, and piece_ceiling bit 7
; marks them); 14 and 15 a wall, going right or left (0, +1 or -1, 16).
;
; From those: piece_rows, the rows to work on per step (piece_rise, or 4 for a
; flat piece); piece_step_y, the size of the column step; piece_dx_copy, the x
; step (0 for a wall); piece_step_x, the size of the x step, or 8 for a wall. A
; wall in an upside-down tile is also moved 8 pixels.
;
; IX The piece state (current_piece)
load_piece_steps:
  LD A,(tile_upside_down) ; An upside-down tile: the direction through
  AND A                   ; upside_down_table.
  JR Z,load_piece_steps_0 ;
  LD E,(IX+$03)           ;
  LD D,$00                ;
  LD HL,upside_down_table ;
  ADD HL,DE               ;
  LD A,(HL)               ;
  LD (IX+$03),A           ;
load_piece_steps_0:
  CALL set_piece_shape    ; The direction's steps.
  LD A,(piece_rise)        ; Rows per step: the rise, or 4 for a flat piece.
  LD (piece_rows),A        ;
  AND A                    ;
  JR NZ,load_piece_steps_1 ;
  OR $04                   ;
  LD (piece_rows),A        ;
load_piece_steps_1:
  LD A,(piece_dcolumn)    ; The column step, and the x step kept in
  LD (piece_step_y),A     ; piece_dx_copy.
  LD A,(piece_dx)         ;
  LD (piece_dx_copy),A    ;
  AND A                    ; A wall (no x step): 8 pixels, with the sign of its
  JR NZ,load_piece_steps_2 ; direction.
  LD A,(direction_flag)    ;
  NEG                      ;
  ADD A,A                  ;
  ADD A,A                  ;
  ADD A,A                  ;
  LD B,A                   ;
load_piece_steps_2:
  LD (piece_step_x),A     ; piece_step_x the size of the x step; going left,
  BIT 7,A                 ; piece_step_y the size of the column step.
  JR Z,load_piece_steps_3 ;
  NEG                     ;
  LD (piece_step_x),A     ;
  LD A,(piece_step_y)     ;
  NEG                     ;
  LD (piece_step_y),A     ;
load_piece_steps_3:
  LD A,(tile_upside_down) ; A wall upside down: 8 pixels over.
  CP $99                  ;
  RET NZ                  ;
  LD A,(piece_dx_copy)    ;
  AND A                   ;
  RET NZ                  ;
  LD A,(piece_page_x)     ;
  ADD A,B                 ;
  LD (piece_page_x),A     ;
  RET                     ;

; Read a flat piece's end pieces, and mirror a piece for a mirrored tile
;
; Used by the routine at draw_landscape.
;
; Called for each piece by draw_landscape after load_piece_steps, with HL at
; the byte after the piece's direction-and-steps byte and C its number of
; steps. Only a flat piece (no rise) has two more bytes: the codes of the
; pieces at its left and right ends, kept in piece_extra_a and piece_extra_b
; ($16 means none, and codes from $10 have special handling in flat_step_clip).
; For a tile mirrored left-right ($FF) they are read the other way round with
; bit 1 changed (left for right); for one turned upside down ($99) bit 0 is
; changed as well (top for bottom), and the piece's y is moved (XOR $0C).
;
; The address of the next piece is kept in next_piece. Then, for a mirrored
; tile, the piece's x is reflected across the page (piece_page_x becomes the
; complement of x plus its x step plus $0F), its direction is remapped through
; mirror_table (right for left), set_piece_shape reloads the steps, and a flat
; run is moved back along by its length less one step (24 pixels a step), so it
; starts at its other end. A flat piece whose right end is $16 is not mirrored
; at all.
;
; HL The next byte of the tile record
; C The piece's number of steps
; IX The piece state (current_piece)
piece_ends:
  LD A,(piece_rise)       ; A piece with a rise has no end bytes.
  AND A                   ;
  JR NZ,piece_ends_4      ;
  LD A,(tile_upside_down) ; An upside-down tile moves a flat piece's y.
  AND A                   ;
  JR Z,piece_ends_0       ;
  LD A,(piece_page_y)     ;
  XOR $0C                 ;
  LD (piece_page_y),A     ;
piece_ends_0:
  LD A,(tile_mirrored_left_right) ; A mirrored tile reads the ends the other
  AND A                           ; way round.
  JR Z,piece_ends_2               ;
  LD A,(HL)               ; Mirrored: the first byte, changed left for right,
  XOR $02                 ; is the right end; the second (unless $16) the left
  LD (piece_extra_b),A    ; end.
  INC HL                  ;
  LD A,(HL)               ;
  CP $16                  ;
  JR Z,piece_ends_1       ;
  XOR $02                 ;
  LD (piece_extra_a),A    ;
  INC HL                  ;
  JR piece_ends_3         ;
piece_ends_1:
  LD (piece_extra_b),A    ; Mirrored, second byte $16: the right end is none.
  INC HL                  ;
  JR piece_ends_3         ;
piece_ends_2:
  LD A,(HL)               ; Not mirrored: left end, then right end.
  LD (piece_extra_a),A    ;
  INC HL                  ;
  LD A,(HL)               ;
  LD (piece_extra_b),A    ;
  INC HL                  ;
piece_ends_3:
  LD A,(tile_upside_down) ; Upside down: both ends top for bottom, except $16.
  AND A                   ;
  JR Z,piece_ends_4       ;
  LD A,(piece_extra_a)    ;
  XOR $01                 ;
  LD (piece_extra_a),A    ;
  LD A,(piece_extra_b)    ;
  CP $16                  ;
  JR Z,piece_ends_4       ;
  XOR $01                 ;
  LD (piece_extra_b),A    ;
piece_ends_4:
  LD (next_piece),HL      ; Where the next piece starts.
  LD A,(tile_mirrored_left_right) ; Not mirrored, or mirrored with no right
  AND A                           ; end: done.
  RET Z                           ;
  LD A,(piece_extra_b)            ;
  CP $16                          ;
  RET Z                           ;
  LD A,(piece_page_x)     ; Reflect the x across the page.
  LD B,A                  ;
  LD A,(piece_step_x)     ;
  ADD A,B                 ;
  ADD A,$0F               ;
  CPL                     ;
  LD (piece_page_x),A     ;
  EXX                     ; Remap the direction through mirror_table and reload
  LD E,(IX+$03)           ; the steps.
  LD D,$00                ;
  LD HL,mirror_table      ;
  ADD HL,DE               ;
  LD A,(HL)               ;
  LD (IX+$03),A           ;
  CALL set_piece_shape    ;
  EXX                     ;
  LD A,(piece_rise)       ; A slope: done.
  AND A                   ;
  RET NZ                  ;
  LD B,C                  ; A flat run: back along by its length less one step.
  LD A,(piece_page_x)     ;
  DEC B                   ;
  RET Z                   ;
piece_ends_5:
  SUB $18                 ;
  DJNZ piece_ends_5       ;
  LD (piece_page_x),A     ;
  RET                     ;

; The left-right mirror table
;
; For a tile mirrored left-right ($FF, piece_ends): a piece direction to the
; direction of the same piece left for right (1 and 4, 2 and 5, 3 and 6 swap,
; 8-10 and 11-13 swap, the walls 14 and 15 swap; 0 and 7 stay).
mirror_table:
  DEFB $00,$04,$05,$06,$01,$02,$03,$07
  DEFB $0B,$0C,$0D,$08,$09,$0A,$0F,$0E

; The upside-down table
;
; For a tile turned upside down ($99, load_piece_steps): a direction to the
; same piece upside down (0-6 and 7-13 swap; the walls swap too), so floors
; become ceilings.
upside_down_table:
  DEFB $07,$08,$09,$0A,$0B,$0C,$0D,$00
  DEFB $01,$02,$03,$04,$05,$06,$0F,$0E

; The column-variety sequence
;
; Seventeen bytes, each 0, 1 or 2, walked one a column by the piece drawing
; (draw_landscape leaves HL here for each piece): which of three stretches of a
; piece's graphic each column uses (graphic_offsets), so that a long flat run
; is not one pattern repeated.
column_varieties:
  DEFB $00,$01,$00,$02,$02,$01,$00,$02,$01,$02,$00,$01,$02,$00,$01,$00,$02

; The piece's x step
;
; In pixels per step, signed (set_piece_shape from piece_shapes; cleared by
; fold_column_step). Also a scratch byte of the sprite code (draw_sprite_pair).
; Like the rest of the landscape's variables here, zero in the snapshot.
piece_dx:
  DEFB $00

; The piece's column step
;
; In screen bytes per step, signed (set_piece_shape; cleared by
; fold_column_step and for walls by colour_piece).
piece_dcolumn:
  DEFB $00

; The piece's rise
;
; In rows per step, 0 for a flat piece (set_piece_shape). Also written by the
; sprite code (draw_sprite_pair).
piece_rise:
  DEFB $00

; Not used
;
; Nothing refers to these two bytes (searched).
landscape_spare:
  DEFB $00,$00

; An object's box: x; or a list pointer
;
; The object's collision box made by place_collision_box is here and in the
; next three bytes: x, bottom line (box_bottom), height (box_height) and width
; (box_width). As a word it is also a list pointer: draw_frame walks the corner
; bitmaps with it.
box_x:
  DEFB $00

; An object's box: bottom line
;
; See box_x.
box_bottom:
  DEFB $00

; An object's box: height; the piece's y as read
;
; The box's height (place_collision_box); and, while the landscape is drawn,
; the current piece's y as read from its tile record before any change
; (draw_landscape), which colour_piece compares with $67.
box_height:
  DEFB $00

; An object's box: width
;
; See box_x.
box_width:
  DEFB $00

; Attribute rows to colour per step
;
; Worked out by colour_piece for the piece being coloured.
attribute_rows:
  DEFB $00

; The size of the vertical scroll
;
; scroll_down without its sign (scroll_landscape), used to uncover rows behind
; pieces (fill_behind_moving_piece).
vertical_step_size:
  DEFB $00

; Half the rows per step
;
; piece_rows halved (the code in landscape_step_loop), for the blitter.
half_rows:
  DEFB $00

; The horizontal origin
;
; Added to a page position to give the screen x; AND 7 is the fine scroll. With
; view_x it always sums to 8 (scroll_landscape). draw_landscape moves it on by
; $E0 for the right-hand pages and puts it back.
origin_x:
  DEFB $00

; The vertical origin
;
; Added to a page position to give the screen y. With view_y it sums to $B7:
; the scroll moves one up as the other comes down, and the wraps set both
; afresh. The exception is a new game's start, whose pair from start_position
; sums to $F7 until the fly-in's first vertical wrap. draw_landscape moves it
; on by $A0 for the lower pages and back.
origin_y:
  DEFB $00

; The piece's x
;
; The current piece's x in its page (draw_landscape), moved as it is drawn;
; also the start of a word used by place_collision_box.
piece_page_x:
  DEFB $00

; The piece's y
;
; The current piece's y in its page (draw_landscape), moved as it is drawn.
piece_page_y:
  DEFB $00

; The view's x in its page
;
; Moved by the horizontal scroll and wrapped into the next page by
; scroll_landscape; saved with the restart point (save_restart_point).
view_x:
  DEFB $00

; The view's y in its page
;
; Moved by the vertical scroll (scroll_landscape).
view_y:
  DEFB $00

; The piece's graphic
;
; Its address at this pass's shift, from shift_table's table (the code in
; landscape_step_loop).
piece_graphic:
  DEFW $0000

; The column being drawn
;
; The screen address of the piece's current column (landscape_step_loop,
; fold_column_step).
column_address:
  DEFW $0000

; Where to start in the graphic-offset table
;
; graphic_offsets, or one byte on when the scroll is shifted (draw_landscape).
offsets_start:
  DEFW $0000

; The next piece
;
; Its address in the tile record (piece_ends), picked up by draw_landscape's
; loop.
next_piece:
  DEFW $0000

; The piece's first step
;
; Its screen address, kept by step_screen_address.
first_step_address:
  DEFW $0000

; The piece's row of graphic offsets
;
; In graphic_offsets (the code in landscape_step_loop).
piece_offsets:
  DEFW $0000

; The piece's first step: y
;
; Kept by step_screen_address; read by after_step_drawn.
first_step_y:
  DEFB $00

; Columns at the view's edges
;
; Counted for each piece by column_clipped and after_step_drawn; cleared by
; draw_landscape.
clipped_columns:
  DEFB $00

; The first drawn step's place: x
;
; Kept by step_screen_address with first_step_y_drawn; the two are read as a
; word by fill_behind_moving_piece.
first_step_x:
  DEFB $00

; The first drawn step's place: y
;
; See first_step_x.
first_step_y_drawn:
  DEFB $00

; The view's page: column
;
; 0-$5F, wrapping (scroll_landscape, load_map_window); with view_row it is the
; word the restart point saves (save_restart_point).
view_column:
  DEFB $00

; The view's page: row
;
; 0-$1B: rows 0-3 are open sky (stars, draw_stars; no landscape below row 3),
; $0B is the surface's lowest, $0C on are the caverns.
view_row:
  DEFB $00

; The piece's x step again
;
; piece_dx kept by load_piece_steps: 0 for a wall.
piece_dx_copy:
  DEFB $00

; Rows per step
;
; piece_rise, or 4 for a flat piece (load_piece_steps); reused by colour_piece
; and after_step_drawn.
piece_rows:
  DEFB $00

; A column of a piece is cut off at the top or bottom of the view
;
; Used by the routine at landscape_step_loop.
;
; Jumped to from the column loop (landscape_step_loop) when a column lies
; across the view's top or bottom edge (edge_flags, the edge flags, bit 0 or 1,
; or any of bits 0-3 with others). In the upper tiles, a slope ends after this
; column (C=1). The column is counted in clipped_columns, and the first one so
; counted calls the code in step_screen_address that keeps the first step's
; place; then on to the next column.
column_clipped:
  LD A,(ground_cell)      ; Upper tile and a slope: stop after this column.
  BIT 0,A                 ;
  JR NZ,column_clipped_0  ;
  LD A,(piece_rise)       ;
  AND A                   ;
  JR Z,column_clipped_0   ;
  LD C,$01                ;
column_clipped_0:
  LD A,(clipped_columns)       ; Count it; the first one keeps the step's place
  INC A                        ; (step_screen_address).
  LD (clipped_columns),A       ;
  CP $01                       ;
  CALL Z,step_screen_address_2 ;
  JP after_step_drawn_2   ; Next column.

; A lower tile's column reaches the view's bottom edge
;
; Used by the routine at landscape_step_loop.
;
; From landscape_step_loop when, in one of the two lower tiles, the column's
; top is level with the view's edge (view_y). Bit 7 of the edge flags
; edge_flags is set; unless the vertical step scroll_down is negative, bit 0 is
; set instead and copied to piece_clip. On to the horizontal tests.
column_at_view_bottom:
  LD A,(edge_flags)           ; Flag it; a negative step: no more.
  OR $80                      ;
  LD (edge_flags),A           ;
  LD A,(scroll_down)          ;
  BIT 7,A                     ;
  JP NZ,landscape_step_loop_2 ;
  LD A,(edge_flags)        ; Otherwise bit 0, kept in piece_clip too.
  XOR $81                  ;
  LD (edge_flags),A        ;
  LD (piece_clip),A        ;
  JP landscape_step_loop_2 ;

; An upper tile's column reaches the view's top edge
;
; Used by the routine at landscape_step_loop.
;
; From landscape_step_loop when, in one of the two upper tiles, the column's y
; is the view's y (view_y). As column_at_view_bottom but bit 1, when the
; vertical step scroll_down is negative.
column_at_view_top:
  LD A,(edge_flags)          ; Flag it; a positive step: no more.
  OR $80                     ;
  LD (edge_flags),A          ;
  LD A,(scroll_down)         ;
  BIT 7,A                    ;
  JP Z,landscape_step_loop_2 ;
  LD A,(edge_flags)        ; Otherwise bit 1, kept in piece_clip too.
  XOR $82                  ;
  LD (edge_flags),A        ;
  LD (piece_clip),A        ;
  JP landscape_step_loop_2 ;

; A column reaches the view's left edge
;
; Used by the routine at landscape_step_loop.
;
; From the horizontal test in landscape_step_loop when, in one of the left-hand
; tiles, the column's x is the view's left edge (view_x). Moving left
; (scroll_across negative): bit 3 of the edge flags; otherwise the column is
; not drawn.
column_at_view_left:
  LD A,(scroll_across)    ; Not moving left: next column.
  BIT 7,A                 ;
  JP Z,after_step_drawn_2 ;
  LD A,(edge_flags)        ; Flag it and go on.
  OR $08                   ;
  LD (edge_flags),A        ;
  JP landscape_step_loop_5 ;

; A column reaches the view's right edge
;
; Used by the routine at landscape_step_loop.
;
; As column_at_view_left for the right-hand tiles: moving right (scroll_across
; positive or zero), bit 2 of the edge flags; otherwise the column is not
; drawn.
column_at_view_right:
  LD A,(scroll_across)     ; Moving left: next column.
  BIT 7,A                  ;
  JP NZ,after_step_drawn_2 ;
  LD A,(edge_flags)        ; Flag it and go on.
  OR $04                   ;
  LD (edge_flags),A        ;
  JP landscape_step_loop_5 ;

; A column on the view's left or right edge
;
; Used by the routine at landscape_step_loop.
;
; From landscape_step_loop when the edge flags hold just bit 2 or 3. For a
; slope going the way that matters for its tile (right in the upper tiles, left
; in the lower), the piece is cut to at most two more steps (C). The first such
; column of the piece takes its screen position (step_screen_address) and
; clears +1 of the piece state; every one is counted in piece_steps_done and
; clipped_columns by after_step_drawn and is not drawn here.
edge_column:
  LD A,(piece_dx_copy)    ; A slope going the right way: no more than two more
  AND A                   ; steps.
  JR Z,edge_column_2      ;
  LD A,(ground_cell)      ;
  BIT 1,A                 ;
  JR NZ,edge_column_1     ;
  LD A,(direction_flag)   ;
  CP $01                  ;
  JR NZ,edge_column_2     ;
edge_column_0:
  LD A,C                  ;
  CP $02                  ;
  JR C,edge_column_2      ;
  LD C,$02                ;
  JR edge_column_2        ;
edge_column_1:
  LD A,(direction_flag)
  CP $FF
  JR NZ,edge_column_2
  JR edge_column_0
edge_column_2:
  LD A,(piece_steps_done)  ; Not the first: count it.
  AND A                    ;
  JP NZ,after_step_drawn_1 ;
  EXX                      ; The first: its screen position; then count it.
  CALL step_screen_address ;
  XOR A                    ;
  LD (IX+$01),A            ;
  EXX                      ;
  JP after_step_drawn_1    ;

; Jump to IY
;
; Used by the routine at colour_piece.
;
; Lets colour_piece CALL the colouring routine whose address it put in IY.
jump_iy:
  JP (IY)                 ; Off to it.

; Is the next attribute cell inside the play area?
;
; Used by the routines at colour_one_cell, colour_two_cells and
; colour_three_cells.
;
; Tests the attribute address one on from HL: inside rows 3 to 22 of the screen
; it returns NZ (A=$FF); in the panel's rows 0-2 or the bottom row 23, Z. HL is
; left as it was.
;
; HL An attribute address
in_play_area:
  INC HL                  ; In the top third: rows 3 and below are inside.
  LD A,H                  ;
  CP $58                  ;
  JR NZ,in_play_area_2    ;
  LD A,L                  ;
  AND $E0                 ;
  CP $60                  ;
  JR C,in_play_area_1     ;
in_play_area_0:
  DEC HL                  ; Inside.
  OR $FF                  ;
  RET                     ;
in_play_area_1:
  DEC HL                  ; Outside.
  XOR A                   ;
  RET                     ;
in_play_area_2:
  LD A,H                  ; The middle third is inside; in the bottom third,
  CP $5A                  ; row 23 is outside.
  JR NZ,in_play_area_0    ;
  LD A,L                  ;
  AND $E0                 ;
  CP $E0                  ;
  JR NC,in_play_area_1    ;
  JR in_play_area_0       ;

; Colour the attribute cells under a landscape piece
;
; Used by the routine at after_step_drawn.
;
; Called by after_step_drawn after a piece is drawn. The landscape takes its
; colour from its attribute cells, a colour for the upper tiles
; (map_row_colour) and another for the lower ones (map_row_colour_next), both
; set from the level's pair of colours (start_landscape) by
; set_landscape_colours (the deeper colour from map row $0C down: the caverns).
; Where the surface meets the caverns (map row $0B in a lower tile, or $0C in
; an upper one) the deeper colour is used, or the upper one for a piece
; starting above y $67.
;
; For each step of the piece it colours a column of cells (the rows per step,
; attribute_rows) one, two or three cells wide (the column step plus one:
; colour_one_cell, colour_two_cells, colour_three_cells), then moves up by the
; rise and across by the column step; a flat piece colours three cells wide and
; as deep as its graphic (about two cells). Only cells inside the play area
; (in_play_area) and its columns 1-28 are coloured. A piece ending in the
; special end piece $13 on the right gets one more column when the scroll is
; not on a byte boundary.
;
; Nothing is coloured while the landscape is being built after a restart
; (map_rebuild), nor for a piece with no columns drawn.
;
; IX The piece state (current_piece): +0 +1 the screen x and y of its first
;    column, +2 the number of steps drawn, +3 the direction
colour_piece:
  LD A,(colour_now)       ; Jetrun: a piece drawn whole colours the same
  AND A                   ; cells as last pass unless colour_this_pass says
  JR NZ,colour_piece_go   ; otherwise; one the view's edge cuts may not.
  LD A,(piece_steps)      ;
  CP (IX+$02)             ;
  RET Z                   ;
colour_piece_go:
  LD A,(map_rebuild)      ; Building after a restart, or nothing drawn: no
  AND A                   ; colour.
  RET NZ                  ;
  LD A,(IX+$01)           ;
  AND A                   ;
  RET Z                   ;
  LD A,(IX+$02)           ;
  AND A                   ;
  RET Z                   ;
  LD A,(piece_dx_copy)    ; A wall: no column step, and one byte (two cells)
  AND A                   ; wide.
  JR NZ,colour_piece_0    ;
  LD (piece_dcolumn),A    ;
  INC A                   ;
  LD (piece_step_y),A     ;
colour_piece_0:
  LD A,(piece_step_y)     ; The width in cells.
  INC A                   ;
  LD C,A                  ;
  LD A,(direction_flag)   ; A piece going left starts a cell further left.
  CP $FF                  ;
  JR Z,colour_piece_1     ;
  LD A,(IX+$00)           ;
  SUB $02                 ;
  AND $F8                 ;
  LD (IX+$00),A           ;
colour_piece_1:
  LD A,C                   ; The colouring routine for the width.
  LD (colour_piece_width+1),A ; Jetrun: and the width, for the fast path.
  LD IY,colour_one_cell    ;
  LD DE,colour_one_fast    ;
  CP $01                   ;
  JR Z,colour_piece_2      ;
  LD IY,colour_two_cells   ;
  LD DE,colour_two_fast    ;
  CP $02                   ;
  JR Z,colour_piece_2      ;
  LD IY,colour_three_cells ;
  LD DE,colour_three_fast  ;
colour_piece_2:
  LD (colour_piece_fast+1),DE ;
  LD A,(piece_rise)       ; The rise in cells per step; the screen position.
  SRL A                   ;
  SRL A                   ;
  SRL A                   ;
  LD (piece_rows),A       ;
  LD L,(IX+$00)           ;
  LD H,(IX+$01)           ;
  LD A,(piece_rows)       ; Rows to colour: the rise in cells, one more if the
  LD (attribute_rows),A   ; first row does not end on a cell boundary.
  LD A,H                  ;
  AND $07                 ;
  XOR $07                 ;
  JR Z,colour_piece_3     ;
  LD A,(attribute_rows)   ;
  INC A                   ;
  LD (attribute_rows),A   ;
colour_piece_3:
  LD A,(IX+$03)           ; A flat piece (direction 0 or 7):
  AND A                   ;
  JR Z,colour_piece_4     ;
  CP $07                  ;
  JR NZ,colour_piece_5    ;
colour_piece_4:
  LD A,$03                 ; Jetrun: the fast path's width and routine too.
  LD (colour_piece_width+1),A ;
  LD DE,colour_three_fast  ;
  LD (colour_piece_fast+1),DE ;
  LD IY,colour_three_cells ; three cells wide, no rise, and the cells from its
  XOR A                    ; y down to $0B rows below.
  LD (piece_rows),A        ;
  LD A,H                   ;
  SUB $0B                  ;
  LD B,A                   ;
  LD A,H                   ;
  OR $07                   ;
  SUB B                    ;
  SRL A                    ;
  SRL A                    ;
  SRL A                    ;
  LD (attribute_rows),A    ;
colour_piece_5:
  PUSH HL                 ; Jetrun: the fast path's top limit, $5860 (row 3)
  LD A,(attribute_rows)   ; + 32 * (rows - 1): a column's bottom cell at or
  DEC A                   ; above it has its top cell inside.
  LD L,A                  ;
  LD H,$00                ;
  ADD HL,HL               ;
  ADD HL,HL               ;
  ADD HL,HL               ;
  ADD HL,HL               ;
  ADD HL,HL               ;
  LD DE,$5860             ;
  ADD HL,DE               ;
  LD A,L                  ;
  LD (colour_piece_top+2),A ;
  LD A,H                  ;
  LD (colour_piece_top+5),A ;
  POP HL                  ;
  LD B,L                  ; The attribute address (an x of $F0 or more, off the
  LD A,L                  ; right, wraps to the start of the row).
  CP $F0                  ;
  JR C,colour_piece_6     ;
  LD L,$00                ;
colour_piece_6:
  CALL pixel_to_attribute ;
  LD A,B                  ;
  CP $F0                  ;
  JR C,colour_piece_7     ;
  DEC HL                  ;
colour_piece_7:
  LD A,(map_row_colour)      ; The upper or lower colour.
  LD C,A                     ;
  LD A,(ground_cell)         ;
  BIT 0,A                    ;
  JR Z,colour_piece_8        ;
  LD A,(map_row_colour_next) ;
  LD C,A                     ;
colour_piece_8:
  LD A,(view_row)          ; Where the surface meets the caverns, the deeper
  CP $0B                   ; colour, or the upper one above y $67.
  JR Z,colour_piece_9      ;
  CP $0C                   ;
  JR NZ,colour_piece_11    ;
  LD A,(ground_cell)       ;
  BIT 0,A                  ;
  JR NZ,colour_piece_11    ;
  JR colour_piece_10       ;
colour_piece_9:
  LD A,(ground_cell)       ;
  BIT 0,A                  ;
  JR Z,colour_piece_11     ;
colour_piece_10:
  LD A,(ground_attr_below) ;
  LD C,A                   ;
  LD A,(box_height)        ;
  CP $67                   ;
  JR NC,colour_piece_11    ;
  LD A,(ground_attr_above) ;
  LD C,A                   ;
colour_piece_11:
  LD DE,$0020             ; Each step of the piece:
  LD B,(IX+$02)           ;
colour_piece_12:
  PUSH BC                 ; a column of cells,
  LD A,(attribute_rows)   ;
  LD B,A                  ;
  PUSH HL                 ;
  LD A,L                  ; Jetrun: a column wholly inside the play area --
  AND $1F                 ; columns 1-28, rows 3-22 -- is coloured without
  JR Z,colour_piece_slow  ; Cyberun's tests on every cell.
colour_piece_width:
  ADD A,$00               ; (the width in cells, set above)
  CP $1E                  ;
  JR NC,colour_piece_slow ;
  LD A,H                  ; The bottom cell above row 23 ($5AE0).
  CP $5A                  ;
  JR C,colour_piece_top   ;
  JR NZ,colour_piece_slow ;
  LD A,L                  ;
  CP $E0                  ;
  JR NC,colour_piece_slow ;
colour_piece_top:
  LD A,L                  ; The top cell in row 3 or below (the limit set
  SUB $00                 ; above).
  LD A,H                  ;
  SBC A,$00               ;
  JR C,colour_piece_slow  ;
colour_piece_fast:
  CALL $0000              ; (the width's fast routine, set above)
  JR colour_piece_column  ;
colour_piece_slow:
  CALL jump_iy            ;
colour_piece_column:
  POP HL                  ;
  LD A,(piece_rows)       ; up by the rise,
  AND A                   ;
  JR Z,colour_piece_14    ;
  LD B,A                  ;
colour_piece_13:
  AND A                   ;
  SBC HL,DE               ;
  DJNZ colour_piece_13    ;
colour_piece_14:
  LD A,(piece_dcolumn)    ; and across by the column step (signed).
  LD C,A                  ;
  LD B,$00                ;
  BIT 7,A                 ;
  JR Z,colour_piece_15    ;
  DEC B                   ;
colour_piece_15:
  ADD HL,BC               ;
  POP BC                  ;
  DJNZ colour_piece_12    ;
  LD A,(piece_extra_b)    ; The end piece $13 on the right, scrolled off a byte
  AND $7F                 ; boundary: one more column.
  CP $13                  ;
  RET NZ                  ;
  LD A,(origin_x)         ;
  AND $07                 ;
  RET Z                   ;
  LD A,(attribute_rows)   ;
  LD B,A                  ;

; Colour a column of attribute cells one wide
;
; colour_piece runs on into it for the extra column after an end piece $13, and
; enters it through IY for the narrowest pieces. Each row upwards: the cell at
; HL, if it is inside the play area (in_play_area) and its columns 1-28.
;
; B The number of rows
; C The attribute
; DE $0020
; HL The attribute address of the bottom row
colour_one_cell:
  CALL in_play_area       ; One cell a row, upwards.
  JR Z,colour_one_cell_0  ;
  LD A,L                  ;
  AND $1F                 ;
  DEC A                   ;
  CP $1C                  ;
  JR NC,colour_one_cell_0 ;
  LD (HL),C               ;
colour_one_cell_0:
  AND A                   ;
  SBC HL,DE               ;
  DJNZ colour_one_cell    ;
  RET                     ;

; Colour a column of attribute cells two wide
;
; Entered through IY from colour_piece for pieces with a column step of one
; byte (and for walls). Each row upwards: the two cells at HL, wherever they
; are inside the play area and its columns 1-28.
;
; B The number of rows
; C The attribute
; DE $0020
; HL The attribute address of the bottom row
colour_two_cells:
  CALL in_play_area        ; The first cell.
  JR Z,colour_two_cells_2  ;
  LD A,L                   ;
  AND $1F                  ;
  DEC A                    ;
  CP $1C                   ;
  JR NC,colour_two_cells_0 ;
  LD (HL),C                ;
colour_two_cells_0:
  INC HL                   ; The second.
  LD A,L                   ;
  AND $1F                  ;
  DEC A                    ;
  CP $1C                   ;
  JR NC,colour_two_cells_1 ;
  LD (HL),C                ;
colour_two_cells_1:
  DEC HL                   ;
colour_two_cells_2:
  AND A                   ; Up a row.
  SBC HL,DE               ;
  DJNZ colour_two_cells   ;
  RET                     ;

; Colour a column of attribute cells three wide
;
; As colour_two_cells for three cells: pieces with a column step of two bytes
; or more, and flat pieces.
;
; B The number of rows
; C The attribute
; DE $0020
; HL The attribute address of the bottom row
colour_three_cells:
  CALL in_play_area          ; The first cell.
  JR Z,colour_three_cells_3  ;
  LD A,L                     ;
  AND $1F                    ;
  DEC A                      ;
  CP $1C                     ;
  JR NC,colour_three_cells_0 ;
  LD (HL),C                  ;
colour_three_cells_0:
  INC HL                     ; The second.
  LD A,L                     ;
  AND $1F                    ;
  DEC A                      ;
  CP $1C                     ;
  JR NC,colour_three_cells_1 ;
  LD (HL),C                  ;
colour_three_cells_1:
  INC HL                     ; The third.
  LD A,L                     ;
  AND $1F                    ;
  DEC A                      ;
  CP $1C                     ;
  JR NC,colour_three_cells_2 ;
  LD (HL),C                  ;
colour_three_cells_2:
  DEC HL                     ;
  DEC HL                     ;
colour_three_cells_3:
  AND A                   ; Up a row.
  SBC HL,DE               ;
  DJNZ colour_three_cells ;
  RET                     ;

; Jetrun: one, two or three cells a row, upwards, for a column colour_piece
; has found wholly inside the play area.
colour_one_fast:
  LD (HL),C               ;
  AND A                   ;
  SBC HL,DE               ;
  DJNZ colour_one_fast    ;
  RET                     ;
colour_two_fast:
  LD (HL),C               ;
  INC L                   ;
  LD (HL),C               ;
  DEC L                   ;
  AND A                   ;
  SBC HL,DE               ;
  DJNZ colour_two_fast    ;
  RET                     ;
colour_three_fast:
  LD (HL),C               ;
  INC L                   ;
  LD (HL),C               ;
  INC L                   ;
  LD (HL),C               ;
  DEC L                   ;
  DEC L                   ;
  AND A                   ;
  SBC HL,DE               ;
  DJNZ colour_three_fast  ;
  RET                     ;


; Landscape pieces' collision classes
;
; Sixteen bytes, one per piece direction, put in +4 of each piece's collision
; box (draw_landscape) for the collision code (collide_with_landscape): 4 flat;
; 1, 2, 3 the three slopes rising to the right; $41-$43 the same rising to the
; left (bit 6); 8 flat upside down; $81-$83 and $C1-$C3 the slopes upside down
; (bit 7); $10 and $20 the two walls.
piece_classes:
  DEFB $04,$01,$02,$03,$41,$42,$43,$08
  DEFB $81,$82,$83,$C1,$C2,$C3,$10,$20

; Redraw the trail
;
; Set by the collision code (ship_contact, ship_hits_ground_objects,
; hit_slope); makes draw_trail erase and redraw the ship's trail even if its
; frame has not changed; cleared there.
trail_collision:
  DEFB $00

; Draw the landscape
;
; Used by the routine at scroll_landscape.
;
; Called each pass by scroll_landscape, when the view is below the sky (map row
; 3 or more). The screen shows at most four map tiles, each the size of the
; play area: the view's page, the one below, the one to the right and the one
; below that. load_map_window has listed their tile records' addresses after
; map_window_pointer, which points into the list, and their collision-box lists
; (37 bytes each) are at ground_cell_top_left, ground_cell_bottom_left,
; ground_cell_top_right and ground_cell_bottom_right; ground_cell says which of
; the four is being drawn (0 the view's page, 1 below, 2 right, 3 below right).
; Nothing is scrolled: every piece that can be seen is drawn again, straight
; onto the screen, from a copy of its graphic pre-shifted for this pass's fine
; scroll.
;
; First the shift table: the fine scroll (origin_x AND 7) picks one of four
; tables (at 0, 2, 4 or 6 pixels; shift_table), and the graphic-offset table's
; start (graphic_offsets, or one byte on when shifted). Then, for each tile:
; the page-to-screen offsets origin_x and origin_y are moved on to that tile
; ($E0 to the right, $A0 down, as 8-bit sums) and put back at the end (in
; after_step_drawn).
;
; A tile record (the tables from tile_records): first byte 0, an empty tile.
; Otherwise, optionally $99 (the tile is turned upside down: floors become
; ceilings), optionally $FF (mirrored left-right), optionally a byte of $95 or
; more (skipped: padding, so a mirrored or upside-down tile can point a few
; bytes before a plain record and share it), then the number of pieces. Each
; piece: x and y in the page (pixels; y counts down from the top of the page,
; and the piece's line rises from there), then a byte whose high nibble is its
; direction (load_piece_steps) and whose low nibble its number of steps (0
; meaning 16), and, only for a flat direction (0 or 7), the codes of its two
; end pieces (piece_ends). So a tile's ground is a chain of pieces, each a line
; of steps of one shape: a flat run of 24-pixel steps, a slope up or down, a
; wall.
;
; Each collision-box list: +0 the number of pieces, then up to seven 5-byte
; boxes, one per piece: +0 +1 x and y, +2 +3 for a flat piece its width (24 a
; step) and $14, for a wall $18 and its height (16 a step), for a slope its far
; end's x and y; +4 its class (piece_classes). These are refilled only while
; record_ground is set: when the view has moved into a new page this pass
; (scroll_landscape) or the screen is being built after a restart
; (map_rebuild); otherwise only the piece count is rewritten.
;
; Each piece is then tested against the view: a piece wholly outside it across
; (view_x, piece_off_left_edge for the left-hand tiles, piece_off_right_edge
; for the right) or up and down (view_y, piece_off_top_edge for the upper
; tiles, piece_off_bottom_edge for the lower) is not drawn. One that may be
; seen is drawn by the column loop at landscape_step_loop, its attributes
; coloured by colour_piece, and the next piece taken from next_piece. The
; renderer uses SP for its POP blitter and reloads it from the fixed address
; stack_top between pieces.
draw_landscape:
  LD (landscape_sp),SP    ; Jetrun: where SP goes back to after each piece.
  LD A,(map_rebuild)      ; Building after a restart: refill the collision
  AND A                   ; records too.
  JR Z,draw_landscape_0   ;
  LD (record_ground),A    ;
draw_landscape_0:
  LD A,(origin_y)         ; The vertical offset for the first tile.
  ADD A,$60               ;
  LD (origin_y),A         ;
  LD DE,graphic_offsets   ; Start of the graphic-offset table for an unshifted
  LD (offsets_start),DE   ; scroll.
  EXX                         ; The fine scroll picks the shift table (and the
  LD HL,piece_blitters_shift0 ; shifted half of the offsets) for 0, 2, 4 or 6
  LD A,(origin_x)             ; pixels.
  AND $07                     ;
  JR Z,draw_landscape_1       ;
  EXX                         ;
  INC DE                      ;
  LD (offsets_start),DE       ;
  EXX                         ;
  LD HL,piece_blitters_shift2 ;
  CP $02                      ;
  JR Z,draw_landscape_1       ;
  LD HL,piece_blitters_shift4 ;
  CP $04                      ;
  JR Z,draw_landscape_1       ;
  LD HL,piece_blitters_shift6 ;
draw_landscape_1:
  LD (shift_table),HL         ;
  XOR A                   ; The first tile.
  LD (ground_cell),A      ;
; This entry point is used by the routine at after_step_drawn.
draw_landscape_2:
  LD IX,ground_cell_top_left             ; Each tile: its box list.
  LD A,(ground_cell)             ;
  AND A                          ;
  JR Z,draw_landscape_3          ;
  LD IX,ground_cell_bottom_left  ;
  CP $01                         ;
  JR Z,draw_landscape_3          ;
  LD IX,ground_cell_top_right    ;
  CP $02                         ;
  JR Z,draw_landscape_3          ;
  LD IX,ground_cell_bottom_right ;
draw_landscape_3:
  LD HL,(map_window_pointer) ; The next tile record's address from the list.
  LD E,(HL)                  ;
  INC HL                     ;
  LD D,(HL)                  ;
  INC HL                     ;
  LD (map_window_pointer),HL ;
  EX DE,HL                   ;
  XOR A                           ; Not mirrored, not upside down, no pieces
  LD (tile_mirrored_left_right),A ; yet.
  LD (tile_upside_down),A         ;
  LD (IX+$00),A                   ;
  LD A,(HL)                ; An empty tile: on to the next.
  AND A                    ;
  JP Z,after_step_drawn_17 ;
  CP $99                  ; $99: upside down.
  JR NZ,draw_landscape_4  ;
  LD (tile_upside_down),A ;
  INC HL                  ;
draw_landscape_4:
  LD A,(HL)                       ; $FF: mirrored left-right.
  CP $FF                          ;
  JR NZ,draw_landscape_5          ;
  LD (tile_mirrored_left_right),A ;
  INC HL                          ;
draw_landscape_5:
  LD A,(HL)               ; A byte from $95 up is skipped.
  CP $95                  ;
  JR C,draw_landscape_6   ;
  INC HL                  ;
  LD A,(HL)               ;
draw_landscape_6:
  LD (pieces_left),A       ; The number of pieces, to pieces_left and the box
  LD (IX+$00),A            ; list; its first box kept at collision_object.
  INC IX                   ;
  INC HL                   ;
  LD (collision_object),IX ;
; This entry point is used by the routine at after_step_drawn.
draw_landscape_7:
  LD IX,current_piece        ; Each piece: its state at current_piece, and the
  XOR A                      ; per-piece flags cleared.
  LD (piece_steps_done),A    ;
  LD (clipped_columns),A     ;
  LD (piece_clip),A          ;
  LD (piece_kept),A          ;
  LD (piece_extra_b),A       ;
  LD (piece_extra_a),A       ;
  LD (piece_ceiling),A       ;
  LD (piece_rows),A          ;
  LD (last_step_in_border),A ;
  LD (IX+$01),A              ;
  LD A,(HL)               ; Its x and y in the page (the y kept unchanged in
  LD (piece_page_x),A     ; box_height too).
  INC HL                  ;
  LD A,(HL)               ;
  LD (piece_page_y),A     ;
  LD (box_height),A       ;
  INC HL                  ;
  LD A,(HL)               ; Its direction (high nibble) and its steps
  RRCA                    ; (load_piece_steps).
  RRCA                    ;
  RRCA                    ;
  RRCA                    ;
  AND $0F                 ;
  LD (IX+$03),A           ;
  EXX                     ;
  CALL load_piece_steps   ;
  EXX                     ;
  LD A,(HL)               ; The number of steps; 0 means 16.
  AND $0F                 ;
  JR NZ,draw_landscape_8  ;
  LD A,$10                ;
draw_landscape_8:
  LD (piece_steps),A      ;
  LD C,A                  ;
  INC HL                  ; The end pieces, and a mirrored tile's changes
  CALL piece_ends         ; (piece_ends).
  LD HL,column_varieties  ; The column-variety sequence in HL; the direction
  LD B,(IX+$03)           ; kept in B.
  EXX                      ; The box, filled only while building
  LD IX,(collision_object) ; (record_ground).
  LD A,(record_ground)     ;
  AND A                    ;
  JP Z,draw_landscape_15   ;
  LD A,(current_piece+3)            ; Its class, steps, x and y.
  LD E,A                  ;
  LD D,$00                ;
  LD HL,piece_classes     ;
  ADD HL,DE               ;
  LD A,(HL)               ;
  LD (IX+$04),A           ;
  LD A,(piece_steps)      ;
  LD (IX+$02),A           ;
  LD A,(piece_page_x)     ;
  LD (IX+$00),A           ;
  LD A,(piece_page_y)     ;
  LD (IX+$01),A           ;
  LD A,(piece_rise)       ; A flat piece:
  AND A                   ;
  JR NZ,draw_landscape_10 ;
  LD B,(IX+$02)           ; width 24 pixels a step, height $14,
  XOR A                   ;
draw_landscape_9:
  ADD A,$18               ;
  DJNZ draw_landscape_9   ;
  LD (IX+$02),A           ;
  LD A,(current_piece+3)            ;
  CP $07                  ;
  LD (IX+$03),$14         ;
  JP Z,draw_landscape_15  ;
  LD A,(IX+$01)           ; and its y $10 lower unless it is upside down.
  ADD A,$10               ;
  LD (IX+$01),A           ;
  JP draw_landscape_15    ;
draw_landscape_10:
  LD A,(piece_dx_copy)    ; A wall:
  AND A                   ;
  JR NZ,draw_landscape_12 ;
  LD B,(IX+$02)           ; width $18, height 16 a step, and the left-going
  XOR A                   ; wall $10 to the left.
draw_landscape_11:
  ADD A,$10               ;
  DJNZ draw_landscape_11  ;
  LD B,A                  ;
  LD (IX+$02),$18         ;
  LD A,(current_piece+3)            ;
  LD (IX+$03),B           ;
  CP $0F                  ;
  JP NZ,draw_landscape_15 ;
  LD A,(IX+$00)           ;
  SUB $10                 ;
  LD (IX+$00),A           ;
  JP draw_landscape_15    ;
draw_landscape_12:
  LD A,(direction_flag)   ; A slope going left starts one x step further right.
  CP $FF                  ;
  JR Z,draw_landscape_13  ;
  LD A,(piece_step_x)     ;
  ADD A,(IX+$00)          ;
  LD (IX+$00),A           ;
draw_landscape_13:
  LD B,(IX+$02)           ; Its far end: the x and y after all its steps.
  LD D,(IX+$00)           ;
  LD E,(IX+$01)           ;
draw_landscape_14:
  LD A,(piece_dx)         ;
  ADD A,D                 ;
  LD D,A                  ;
  LD A,(piece_rise)       ;
  NEG                     ;
  ADD A,E                 ;
  LD E,A                  ;
  DJNZ draw_landscape_14  ;
  LD (IX+$03),E           ;
  LD (IX+$02),D           ;
draw_landscape_15:
  LD A,(view_x)             ; Wholly to the left or right of the view?
  LD B,A                    ;
  LD A,(ground_cell)        ;
  BIT 1,A                   ;
  JR Z,draw_landscape_16    ;
  CALL piece_off_right_edge ;
  JR draw_landscape_17      ;
draw_landscape_16:
  CALL piece_off_left_edge  ;
draw_landscape_17:
  JP NZ,draw_landscape_20   ;
  LD A,(view_y)              ; Wholly above or below it?
  LD B,A                     ;
  LD A,(ground_cell)         ;
  BIT 0,A                    ;
  JR Z,draw_landscape_18     ;
  CALL piece_off_bottom_edge ;
  JR draw_landscape_19       ;
draw_landscape_18:
  CALL piece_off_top_edge    ;
draw_landscape_19:
  JP NZ,draw_landscape_20    ;
  CALL next_piece_box      ; It can be seen: on to the next collision record,
  JP landscape_step_loop_0 ; and draw it.
draw_landscape_20:
  CALL next_piece_box     ; It cannot: on to the next collision record and the
  JP after_step_drawn_16  ; next piece.

; Test whether a piece in a left-hand map cell ends before the play area's left
; edge
;
; Used by the routine at draw_landscape.
;
; Used by draw_landscape for each piece of the two left-hand map cells of the
; 2x2 window (bit 1 of the cell counter ground_cell clear). It finds the
; piece's rightmost x within the cell from the piece's collision box and
; compares it with view_x, the in-cell x that sits at the play area's left
; edge. A piece that ends left of it cannot be seen and is skipped without
; walking its steps.
;
; The box (IX) is five bytes of a map cell's collision-box list (ground_cell_top_left,
; ground_cell_bottom_left, ground_cell_top_right or ground_cell_bottom_right:
; the view's page, the one below, right, below-right). It holds the piece's
; start x at +0 and, for a flat piece, its length in pixels at +2; for a sloped
; piece +2 holds the x of its far end, and +0 its start x (moved on by a step's
; width for a piece running left, direction_flag = 1). +4 is a class byte from
; piece_classes for the collision code (collide_with_landscape).
;
;   IX Piece's collision box
;   B In-cell x at the play area's left edge (view_x)
; O:F Z clear (NZ) if the piece is wholly left of the edge
piece_off_left_edge:
  LD A,(piece_rise)           ; Flat piece (no rise, piece_rise zero): right
  AND A                       ; end = start x + length.
  JR NZ,piece_off_left_edge_0 ;
  LD A,(IX+$00)               ;
  ADD A,(IX+$02)              ;
  JR piece_off_left_edge_3    ;
piece_off_left_edge_0:
  LD A,(piece_dx_copy)        ; A vertical wall (no run, piece_dx_copy zero) is
  AND A                       ; 8 pixels wide.
  JR NZ,piece_off_left_edge_1 ;
  LD A,(piece_page_x)         ;
  ADD A,$08                   ;
  JR piece_off_left_edge_3    ;
piece_off_left_edge_1:
  LD A,(direction_flag)      ; A sloped piece: its right end is +0 if it runs
  CP $01                     ; left (direction_flag = 1), else +2.
  JR Z,piece_off_left_edge_2 ;
  LD A,(IX+$02)              ;
  JR piece_off_left_edge_3   ;
piece_off_left_edge_2:
  LD A,(IX+$00)              ;
piece_off_left_edge_3:
  CP B                    ; NZ (skip) if the right end is left of the edge; Z
  RET C                   ; otherwise.
  XOR A                   ;
  RET                     ;

; Test whether a piece in a right-hand map cell starts beyond the play area's
; right edge
;
; Used by the routine at draw_landscape.
;
; The counterpart of piece_off_left_edge for the two right-hand map cells of
; the window. In the right-hand cell the play area's right edge falls at the
; same in-cell x as the left edge does in the left-hand one (view_x), so a
; piece whose leftmost x is beyond it is out of sight.
;
;   IX Piece's collision box
;   B In-cell x of the play area's right edge (view_x)
; O:F Z clear (NZ) if the piece is wholly right of the edge
piece_off_right_edge:
  LD A,(piece_dx_copy)        ; A sloped piece running left: its leftmost x is
  AND A                       ; its far end, +2, less one.
  JR Z,piece_off_right_edge_0 ;
  LD A,(direction_flag)       ;
  CP $FF                      ;
  JR Z,piece_off_right_edge_0 ;
  LD A,(IX+$02)               ;
  DEC A                       ;
  JR piece_off_right_edge_1   ;
piece_off_right_edge_0:
  LD A,(piece_page_x)     ; Otherwise the piece's start x.
piece_off_right_edge_1:
  CP B                    ; NZ if beyond the edge. (A piece starting exactly on
  RET NC                  ; the edge gives Z and is walked anyway.)
  XOR A                   ;
  RET                     ;

; Test whether a piece in an upper map cell lies wholly above the play area
;
; Used by the routine at draw_landscape.
;
; Pieces are walked upwards from their start, so in the upper map cells of the
; window a piece whose start (lowest) y is above the in-cell y of the play
; area's top edge cannot be seen.
;
;   B In-cell y of the play area's bottom edge in the lower cell, which is also
;     the top edge's in-cell y in the upper one (view_y)
; O:F Z clear (NZ) if the piece is wholly above the play area
piece_off_top_edge:
  LD A,(piece_page_y)
  CP B
  RET C
  XOR A
  RET

; Test whether a piece in a lower map cell lies wholly below the play area
;
; Used by the routine at draw_landscape.
;
; The counterpart of piece_off_top_edge for the lower map cells: the piece's
; topmost y is compared with view_y, the in-cell y of the play area's bottom
; row. A flat piece's top is its start y less 4 (a flat step is four rows
; tall); a vertical wall's is +1 less +3 of its collision box; a slope's is +3.
;
;   IX Piece's collision box
;   B In-cell y of the play area's bottom edge (view_y)
; O:F Z clear (NZ) if the piece is wholly below the play area
piece_off_bottom_edge:
  LD A,(piece_rise)             ; Flat piece.
  AND A                         ;
  JR NZ,piece_off_bottom_edge_0 ;
  LD A,(piece_page_y)           ;
  SUB $04                       ;
  JR piece_off_bottom_edge_2    ;
piece_off_bottom_edge_0:
  LD A,(piece_dx_copy)          ; Vertical wall.
  AND A                         ;
  JR NZ,piece_off_bottom_edge_1 ;
  LD A,(IX+$01)                 ;
  SUB (IX+$03)                  ;
  JR piece_off_bottom_edge_2    ;
piece_off_bottom_edge_1:
  LD A,(IX+$03)           ; Slope.
piece_off_bottom_edge_2:
  CP B                    ; NZ if below the bottom edge.
  RET NC                  ;
  XOR A                   ;
  RET                     ;

; Move to the next piece's collision box and back to the current-piece record
;
; Used by the routine at draw_landscape.
;
; Called by draw_landscape once a piece's visibility has been decided. Moves
; the pointer collision_object on by the five bytes of a box, points IX back at
; the current-piece record current_piece, clears its "first step set up" byte
; (+1) and stores the piece's direction at +3.
;
; IX Box just used
; B' Direction (in the other register set)
next_piece_box:
  LD DE,$0005              ; Advance the box pointer.
  ADD IX,DE                ;
  LD (collision_object),IX ;
  LD IX,current_piece     ; IX = current-piece record; switch register sets;
  EXX                     ; clear +1; keep the direction at +3.
  LD (IX+$01),$00         ;
  LD (IX+$03),B           ;
  RET                     ;

; Move to the next step of a piece, cull it, and set up its graphic and blitter
;
; Used by the routine at after_step_drawn.
;
; The per-step loop of the landscape renderer. A piece is a straight run of
; identical steps; each step moves the drawing position on by its direction's
; advance (piece_dx pixels across, piece_dcolumn bytes across, piece_rise
; pixels up, from the table at piece_shapes by set_piece_shape). Directions 0-6
; are floors -- flat, three slopes rising to the right, three rising to the
; left -- and 7-13 the same shapes as ceilings (rock above, sky below;
; set_piece_shape sets piece_ceiling to $80 for them); 14 and 15 are vertical
; walls. For each step this routine:
;
; 1. Advances the in-cell position (piece_page_x, piece_page_y) and the screen
; position (piece_x, piece_y). A piece's first step is entered further down,
; without moving. 2. Culls it against the play area. Vertically: in an upper
; map cell a step whose base is above the top edge is skipped; in a lower one,
; a step whose top is below the bottom edge; a step exactly on the edge sets a
; flag in edge_flags (column_at_view_top, column_at_view_bottom). Horizontally
; the same against view_x, with flags set by column_at_view_left and
; column_at_view_right. Skipped steps go to the step counter in
; after_step_drawn without drawing. 3. With an edge flag set, goes to
; edge_column or column_clipped (the edge-exact cases). 4. Otherwise reads the
; step's variant (0-2, from the repeating sequence at column_varieties) and,
; for the piece's first drawn step, looks its direction up in the fine-scroll
; table at shift_table (16 entries of four bytes: a blitter address into IY, a
; graphic address into piece_graphic), works out the screen address
; (step_screen_address) and finds this direction's row of variant offsets
; (piece_offsets). 5. Chooses how to draw: a flat step goes to flat_step_clip;
; a sloped step near the right edge (screen x from $D1) through the patched JR
; at the end of this routine to slope_step_at_right_edge; others to
; slope_step_at_left_edge, which clips at the left edge or draws whole. All of
; them end at draw_step, which draws the step.
;
; Interrupts are off for the whole game, which is what makes it safe for the
; blitters to borrow SP.
;
; HL' Address of this step's variant byte (in column_varieties)
; C' Steps left in the piece
; D' Steps drawn so far
landscape_step_loop:
  LD A,(piece_rise)       ; Move to this step: up by the direction's rise,
  LD B,A                  ; across by its run.
  LD A,(piece_page_y)     ;
  SUB B                   ;
  LD (piece_page_y),A     ;
  LD A,(piece_y)          ;
  SUB B                   ;
  LD (piece_y),A          ;
  LD A,(piece_dx)         ;
  LD B,A                  ;
  LD A,(piece_x)          ;
  ADD A,B                 ;
  LD (piece_x),A          ;
  LD A,(piece_page_x)     ;
  ADD A,B                 ;
  LD (piece_page_x),A     ;
; This entry point is used by the routine at draw_landscape.
landscape_step_loop_0:
  XOR A                   ; A piece's first step enters here (from
  LD (edge_flags),A       ; draw_landscape): no edge flags yet.
  LD A,(ground_cell)          ; Upper map cell: skip if the step's base is
  BIT 0,A                     ; above the top edge; exactly on it, flag it
  JR NZ,landscape_step_loop_1 ; (column_at_view_top).
  LD A,(piece_page_y)         ;
  LD B,A                      ;
  LD A,(view_y)               ;
  CP B                        ;
  JP Z,column_at_view_top     ;
  JP NC,after_step_drawn_2    ;
  JP landscape_step_loop_2    ;
landscape_step_loop_1:
  LD A,(piece_rows)          ; Lower map cell: skip if the step's top is below
  LD B,A                     ; the bottom edge; exactly on it, flag it
  LD A,(piece_page_y)        ; (column_at_view_bottom).
  SUB B                      ;
  LD B,A                     ;
  LD A,(view_y)              ;
  CP B                       ;
  JP C,after_step_drawn_2    ;
  JP Z,column_at_view_bottom ;
; This entry point is used by the routines at column_at_view_bottom and
; column_at_view_top.
landscape_step_loop_2:
  LD A,(piece_page_x)         ; Horizontal cull; the right-hand map cells are
  LD B,A                      ; tested further on.
  LD A,(ground_cell)          ;
  BIT 1,A                     ;
  JR NZ,landscape_step_loop_4 ;
  LD A,(piece_rise)           ; A flat step of a left-hand cell whose screen x
  AND A                       ; falls in $F1-$F6 (hanging off the left edge
  JR NZ,landscape_step_loop_3 ; into the border) is drawn only if it is the
  LD A,(origin_x)             ; piece's last, and then the flag
  ADD A,B                     ; last_step_in_border is set to $FF. Exactly $F0
  CP $F0                      ; is an edge case (column_at_view_left).
  JR C,landscape_step_loop_3  ;
  JP Z,column_at_view_left    ;
  CP $F7                      ;
  JR NC,landscape_step_loop_3 ;
  LD A,C                      ;
  DEC A                       ;
  JP NZ,after_step_drawn_2    ;
  DEC A                       ;
  LD (last_step_in_border),A  ;
landscape_step_loop_3:
  LD A,(piece_step_x)      ; Skip the step if it ends left of the left edge;
  ADD A,B                  ; exactly on it, column_at_view_left.
  LD B,A                   ;
  LD A,(view_x)            ;
  CP B                     ;
  JP Z,column_at_view_left ;
  JP NC,after_step_drawn_2 ;
  JR landscape_step_loop_5 ;
landscape_step_loop_4:
  LD A,(view_x)             ; Right-hand map cell: skip the step if it starts
  CP B                      ; right of the right edge; exactly on it,
  JP Z,column_at_view_right ; column_at_view_right.
  JP C,after_step_drawn_2   ;
; This entry point is used by the routines at column_at_view_left and
; column_at_view_right.
landscape_step_loop_5:
  LD A,(edge_flags)          ; An edge flag set: off to the edge-case handlers.
  AND A                      ;
  JR Z,landscape_step_loop_6 ;
  CP $08                     ;
  JP Z,edge_column           ;
  CP $04                     ;
  JP Z,edge_column           ;
  CP $01                     ;
  JP Z,column_clipped        ;
  CP $02                     ;
  JP Z,column_clipped        ;
  AND $0F                    ;
  JP NZ,column_clipped       ;
  JP after_step_drawn_2      ;
landscape_step_loop_6:
  LD E,(HL)               ; E = this step's variant (0, 1 or 2).
  LD A,(IX+$01)               ; Steps after the piece's first drawn one carry
  AND A                       ; on from where the last blitter left HL.
  JP NZ,landscape_step_loop_8 ;
  EXX                     ; First drawn step: from the fine-scroll table
  LD HL,(shift_table)     ; (shift_table + 4 * direction) the blitter address
  LD E,(IX+$03)           ; into IY and the graphic address into piece_graphic.
  LD D,$00                ;
  SLA E                   ;
  SLA E                   ;
  ADD HL,DE               ;
  LD C,(HL)               ;
  INC HL                  ;
  LD B,(HL)               ;
  INC HL                  ;
  PUSH BC                 ;
  POP IY                  ;
  LD C,(HL)               ;
  INC HL                  ;
  LD B,(HL)               ;
  LD (piece_graphic),BC   ;
  LD A,(piece_rows)       ; Row pairs to draw = the step's height (piece_rows)
  SRL A                   ; / 2.
  LD (half_rows),A        ;
  CALL step_screen_address ; Screen address of the step (step_screen_address),
  LD A,(piece_dcolumn)     ; less the byte advance, into column_address.
  LD B,A                   ;
  LD A,L                   ;
  SUB B                    ;
  LD L,A                   ;
  LD (column_address),HL   ;
  LD DE,(offsets_start)      ; piece_offsets = this direction's row of variant
  LD A,(IX+$03)              ; offsets: offsets_start (graphic_offsets on a
  CP $07                     ; byte boundary, one byte on off it) + 6 *
  JR C,landscape_step_loop_7 ; (direction mod 7).
  SUB $07                    ;
landscape_step_loop_7:
  ADD A,A                    ;
  LD H,A                     ;
  ADD A,A                    ;
  ADD A,H                    ;
  LD L,A                     ;
  LD H,$00                   ;
  ADD HL,DE                  ;
  LD (piece_offsets),HL      ;
  EXX                         ; D' = 0 steps drawn; the displacement of the JR
  XOR A                       ; at the end of slope_step_at_right_edge = 1 if
  LD D,A                      ; the step is on a byte boundary, else 0
  LD (slope_step_at_right_edge_0+1),A                ; (mirrored_slope_far_right copies it too).
  LD A,(IX+$00)               ;
  AND $07                     ;
  JR NZ,landscape_step_loop_8 ;
  LD A,$01                    ;
  LD (slope_step_at_right_edge_0+1),A                ;
landscape_step_loop_8:
  LD A,(piece_dx_copy)        ; A vertical wall: once a step is drawn the rest
  AND A                       ; go straight to the draw; before that piece_dx =
  JR NZ,landscape_step_loop_9 ; -8 * direction.
  LD A,D                      ;
  AND A                       ;
  JP NZ,draw_step             ;
  LD A,(direction_flag)       ;
  NEG                         ;
  ADD A,A                     ;
  ADD A,A                     ;
  ADD A,A                     ;
  LD (piece_dx),A             ;
landscape_step_loop_9:
  XOR A                   ; Default dispatch (the dispatch JR in draw_step):
  LD (draw_step_7+1),A            ; the step's own blitter. Flat steps: flat_step_clip.
  LD A,(piece_rise)       ;
  AND A                   ;
  JP Z,flat_step_clip     ;
  LD A,(piece_x)               ; A sloped step: near the right edge (screen x
  CP $D1                       ; $D1 or more)?
  JP C,slope_step_at_left_edge ;
  LD B,A                  ; B = screen x, A = run in pixels.
  LD A,(piece_dx)         ;
landscape_step_loop_10:
  JR landscape_step_loop_10 ; Patched by set_piece_shape: displacement 0 for a
                            ; piece running left, into slope_step_at_right_edge
                            ; to negate the run first; 2 for one running right,
                            ; past the NEG.

; Decide how a sloped step near the right edge is clipped
;
; Entered from the patched JR at the end of landscape_step_loop with A = the
; step's run in pixels (negated here for a piece running left) and B its screen
; x. If the step's far side stays left of $E9 it goes on to
; slope_step_at_left_edge. Otherwise it crosses the play area's right edge and
; one of the right-clipping blitters is chosen: for a step starting left of $E0
; only its rightmost column is lost (slope_lose_last_column); for one starting
; at $E0 or later only its first column or two are drawn, the count patched
; into the blitter's JR (blit_right_clip by set_right_clip_columns, or
; blit_mirrored_right_clip by mirrored_slope_far_right).
;
; A Run of the step in pixels
; B Screen x of the step
slope_step_at_right_edge:
  NEG                          ; Far side left of $E9: no right clipping.
  ADD A,B                      ;
  CP $E9                       ;
  JP C,slope_step_at_left_edge ;
  LD A,B                      ; Starts left of $E0: slope_lose_last_column.
  CP $E0                      ;
  JR C,slope_lose_last_column ;
  LD A,(direction_flag)         ; A piece running left uses the mirrored
  CP $01                        ; blitter (mirrored_slope_far_right).
  JR Z,mirrored_slope_far_right ;
  LD A,(piece_dcolumn)    ; Displacement for the JR in blit_right_clip: $21
  LD B,A                  ; less the byte advance.
  LD A,$21                ;
  SUB B                   ;
slope_step_at_right_edge_0:
  JR slope_step_at_right_edge_0 ; Patched by landscape_step_loop (displacement
                                ; 1 on a byte boundary): into
                                ; set_right_clip_columns (one less) or past its
                                ; DEC A.

; Patch the right-clipping blitter's column count
;
; The target of the patched JR at the end of slope_step_at_right_edge, entered
; at its DEC A when the step is off a byte boundary and just after it when it
; is on one. Stores A as the displacement of the JR after the first write in
; blit_right_clip, selects that blitter through the dispatch JR in draw_step,
; and draws.
;
; A Displacement, plus one unless the DEC A is skipped
set_right_clip_columns:
  DEC A                   ; Off a byte boundary: one less.
  LD (blit_right_clip_1+1),A            ; Patch the JR in blit_right_clip.
  LD A,$02                ; Dispatch 2: blit_right_clip (through
  LD (draw_step_7+1),A            ; step_dispatch).
  LD A,(piece_dx_copy)    ; A vertical wall moves its address once and stops
  AND A                   ; stepping across (fold_column_step).
  CALL Z,fold_column_step ;
  JP draw_step            ; Draw.

; Clip a sloped step that loses only its rightmost column at the right edge
;
; Used by the routine at slope_step_at_right_edge.
;
; For a step starting left of $E0 that crosses the right edge. A piece running
; right uses blit_right_clip with its patched JR at displacement 0 (all but the
; last column); one running left goes to use_mirrored_right_clip.
slope_lose_last_column:
  LD A,(direction_flag)        ; Running left: the mirrored blitter.
  CP $01                       ;
  JR Z,use_mirrored_right_clip ;
  XOR A                   ; Displacement 0 into the JR in blit_right_clip;
  LD (blit_right_clip_1+1),A            ; dispatch 2; draw.
  LD A,$02                ;
  LD (draw_step_7+1),A            ;
  JP draw_step            ;

; Work out the column count for a mirrored step far into the right edge
;
; Used by the routine at slope_step_at_right_edge.
;
; A step of a piece running left that starts at screen x $E0 or more. The
; displacement for the patched JR in blit_mirrored_right_clip is $29 less the
; byte advance's size, one less again unless the step is on a byte boundary:
; the JR at the end of this routine (whose displacement is copied here from the
; byte-boundary flag landscape_step_loop left in the JR at the end of
; slope_step_at_right_edge) skips the DEC A at use_mirrored_right_clip or not.
mirrored_slope_far_right:
  LD A,(slope_step_at_right_edge_0+1)            ; Copy the byte-boundary flag into the JR's
  LD (mirrored_slope_far_right_0+1),A            ; displacement.
  LD A,(piece_dcolumn)    ; A = $29 - size of the byte advance (negative for
  NEG                     ; these directions).
  LD B,A                  ;
  LD A,$29                ;
  SUB B                   ;
mirrored_slope_far_right_0:
  JR mirrored_slope_far_right_0 ; Patched: into use_mirrored_right_clip (DEC A)
                                ; or past it.

; Select the mirrored right-clipping blitter
;
; Used by the routine at slope_lose_last_column.
;
; Entered at its DEC A or just after it by the patched JR at the end of
; mirrored_slope_far_right, and from slope_lose_last_column with A = 1
; (displacement 0: all but the last column). Stores the displacement of the
; patched JR in blit_mirrored_right_clip and selects that blitter with dispatch
; displacement 5.
;
; A Column-count displacement, plus one
use_mirrored_right_clip:
  DEC A                   ; Patch the JR in blit_mirrored_right_clip.
  LD (blit_mirrored_right_clip_2+1),A            ;
  LD A,$05                ; Dispatch 5: blit_mirrored_right_clip (through
  LD (draw_step_7+1),A            ; step_dispatch).
  LD A,(piece_dx_copy)    ; A vertical wall moves its address once and stops
  AND A                   ; stepping across (fold_column_step); draw.
  CALL Z,fold_column_step ;
  JP draw_step            ;

; Draw a sloped step whole, or decide how it is clipped at the left edge
;
; Used by the routines at landscape_step_loop and slope_step_at_right_edge.
;
; Steps whose screen x is from -8 to 6 hang over the play area's left edge
; (column 0 is the border, and x from $F0 is "negative": columns 30 and 31 of
; the same character row). Anything else is drawn whole (with fold_column_step
; for a vertical wall). A clipped step uses blit_left_clip (dispatch 8) for a
; piece running right, or blit_mirrored_left_clip (dispatch 11) for one running
; left; the bytes to skip and the columns to draw are patched into those
; blitters' JRs, and for blit_left_clip the next step's column into
; move_across_kept, according to the column the step starts in.
;
; All the clipped cases ran in the build's sessions.
slope_step_at_left_edge:
  LD A,(piece_x)                 ; Not near the left edge: draw whole.
  ADD A,$08                      ;
  CP $0F                         ;
  JR C,slope_step_at_left_edge_0 ;
  LD A,(piece_dx_copy)           ;
  AND A                          ;
  JP NZ,draw_step                ;
  CALL fold_column_step          ;
  JP draw_step                   ;
slope_step_at_left_edge_0:
  LD A,(direction_flag)          ; A piece running left: further on.
  CP $01                         ;
  JR Z,slope_step_at_left_edge_6 ;
  LD A,(column_address)          ; Running right: by the column in
  AND $1F                        ; column_address ($1D, $1E or another).
  CP $1D                         ;
  JR Z,slope_step_at_left_edge_4 ;
  CP $1E                         ;
  JR Z,slope_step_at_left_edge_5 ;
slope_step_at_left_edge_1:
  LD A,(piece_dx_copy)    ; Another column: skip one graphic byte (first JR in
  AND A                   ; blit_left_clip at 1), draw the last column of a
  CALL Z,fold_column_step ; two-byte step (second JR at $2C), the next step's
  LD A,(piece_dcolumn)    ; column from the byte advance (move_across_kept);
  LD (move_across_kept),A ; dispatch 8.
  LD A,$2C                ;
  LD (blit_left_clip_2+1),A            ;
slope_step_at_left_edge_2:
  LD A,$01                ;
  LD (blit_left_clip_0+1),A            ;
slope_step_at_left_edge_3:
  LD A,$08                ;
  LD (draw_step_7+1),A            ;
  JP draw_step            ;
slope_step_at_left_edge_4:
  LD A,$01                     ; $1D: skip two graphic bytes (first JR at 0),
  LD (move_across_kept),A      ; draw the last column of a three-byte step
  XOR A                        ; (second JR at $30); the next step's column
  LD (blit_left_clip_0+1),A                 ; from 1.
  LD A,$30                     ;
  LD (blit_left_clip_2+1),A                 ;
  JP slope_step_at_left_edge_3 ;
slope_step_at_left_edge_5:
  LD A,(slope_step_at_right_edge_0+1)                   ; $1E off a byte boundary: skip one byte, draw
  CP $01                         ; the last two columns (second JR at 0).
  JR Z,slope_step_at_left_edge_1 ;
  LD A,(piece_dcolumn)           ;
  LD (move_across_kept),A        ;
  XOR A                          ;
  LD (blit_left_clip_2+1),A                   ;
  JP slope_step_at_left_edge_2   ;
slope_step_at_left_edge_6:
  LD A,(piece_dcolumn)           ; A piece running left: by the column the step
  LD B,A                         ; starts in.
  LD A,(column_address)          ;
  SUB B                          ;
  AND $1F                        ;
  CP $02                         ;
  JR Z,slope_step_at_left_edge_8 ;
  CP $03                         ; Another column off a byte boundary: skip one
  JR Z,slope_step_at_left_edge_9 ; byte, two columns (first JR in
  LD A,(slope_step_at_right_edge_0+1)                   ; blit_mirrored_left_clip at 1, second at 0);
  CP $01                         ; dispatch 11.
  JR Z,slope_step_at_left_edge_8 ;
  XOR A                          ;
  LD (blit_mirrored_left_clip_2+1),A                   ;
  INC A                          ;
slope_step_at_left_edge_7:
  LD (blit_mirrored_left_clip_0+1),A                   ;
  LD A,$0B                       ;
  LD (draw_step_7+1),A                   ;
  JP draw_step                   ;
slope_step_at_left_edge_8:
  LD A,(piece_dx_copy)         ; Column 2, or on a byte boundary: skip one
  AND A                        ; byte, one column (second JR at $26).
  CALL Z,fold_column_step      ;
  LD A,$26                     ;
  LD (blit_mirrored_left_clip_2+1),A                 ;
  LD A,$01                     ;
  JP slope_step_at_left_edge_7 ;
slope_step_at_left_edge_9:
  LD A,D                           ; Column 3: skip two bytes, one column
  AND A                            ; (first JR at 0, second at $2A); with no
  JR NZ,slope_step_at_left_edge_10 ; step drawn yet, column_address goes a
  LD A,(column_address)            ; character row back.
  SUB $20                          ;
  LD (column_address),A            ;
slope_step_at_left_edge_10:
  LD A,$2A                         ;
  LD (blit_mirrored_left_clip_2+1),A                     ;
  XOR A                            ;
  JP slope_step_at_left_edge_7     ;

; Patch the flat-step blitter for the play area's edges and the piece's end
; caps
;
; Used by the routine at landscape_step_loop.
;
; Flat steps (directions 0 and 7) are three bytes wide and four rows tall, all
; drawn by blit_flat_step, which has three patchable JRs in its loop and two on
; its cut path (flat_blit_left_edge, flat_blit_left_rows). This routine resets
; the loop's three to draw all three columns, then patches them by the column
; the step starts in (the low five bits of column_address are three less than
; that column):
;
; * $1D (start in column 0, the left border): the first JR to
;   flat_blit_left_edge, which skips the first byte and draws columns 1 and 2
;   (flat_blit_left_two_rows).
; * $1C (start in column 31, one column left of the screen): the same, drawing
;   only the third byte, in column 1 (flat_blit_left_one_row).
; * $18 (columns 27-29): the third JR to flat_blit_left_two, two columns.
; * $19 (columns 28-30): the second JR to flat_blit_one_column, one column.
;
; Then the piece's end caps. A flat piece carries two cap bytes (piece_extra_a
; for its first step, piece_extra_b for its last, read by piece_ends); bit 4
; marks a cap to act on, and bit 7 is set here when it is acted on
; (landscape_end_pieces looks for $91 and $93). A cap's low two bits pick one
; of four extra graphics stored after the three variants (offset $24 + 12 * n),
; drawn in place of the variant. Cap $16 ($96 once seen) draws just the first
; column, and skips the step if that column is outside. An odd cap marks a drop
; at that end of the run: if the step is on a byte boundary and the horizontal
; scroll is moving towards that end, its address and x are kept
; (first_step_address, piece_kept, scratch_count) for the column fill after the
; piece (fill_flat_end_column).
;
; The first step of a piece whose start cap is exactly $10 loses its first
; column (the first JR to flat_blit_lose_first) when the ground is off a byte
; boundary.
;
; C' Steps left (equal to piece_steps on the piece's first step, 1 on its last)
flat_step_clip:
  XOR A                   ; All three loop JRs to displacement 0: draw every
  LD (blit_flat_step_0+1),A            ; column.
  LD (flat_blit_first_byte_0+1),A            ;
  LD (flat_blit_second_byte_0+1),A            ;
  LD A,(column_address)   ; The step's start column.
  AND $1F                 ;
  CP $1D                  ;
  JR Z,flat_step_clip_0   ;
  CP $1C                  ;
  JR Z,flat_step_clip_2   ;
  CP $18                  ;
  JR Z,flat_step_clip_3   ;
  CP $19                  ;
  JR Z,flat_step_clip_4   ;
  LD A,(last_step_in_border) ; A last step hanging into the border
  AND A                      ; (last_step_in_border set) is not drawn.
  JP NZ,after_step_drawn_1   ;
  LD A,(piece_steps)      ; First step, start cap $10, off a byte boundary:
  CP C                    ; lose the first column.
  JR NZ,flat_step_clip_5  ;
  LD A,(piece_extra_a)    ;
  CP $10                  ;
  JR NZ,flat_step_clip_5  ;
  LD A,(origin_x)         ;
  AND $07                 ;
  JR Z,flat_step_clip_5   ;
  LD A,$EE                ;
  JR flat_step_clip_1     ;
flat_step_clip_0:
  LD A,$33                ; Start column 0: from the second byte on.
flat_step_clip_1:
  LD (blit_flat_step_0+1),A            ;
  XOR A                   ;
  LD (flat_blit_left_rows_0+1),A            ;
  INC A                   ;
  LD (flat_blit_left_edge_2+1),A            ;
  JR flat_step_clip_5     ;
flat_step_clip_2:
  LD A,$33                ; Start column 31: only the third byte.
  LD (blit_flat_step_0+1),A            ;
  LD A,$0B                ;
  LD (flat_blit_left_rows_0+1),A            ;
  XOR A                   ;
  LD (flat_blit_left_edge_2+1),A            ;
  JR flat_step_clip_5     ;
flat_step_clip_3:
  LD A,$26                ; Start column 27: two columns.
  LD (flat_blit_second_byte_0+1),A            ;
  JR flat_step_clip_5     ;
flat_step_clip_4:
  LD A,$24                ; Start column 28: one column.
  LD (flat_blit_first_byte_0+1),A            ;
flat_step_clip_5:
  LD A,(piece_steps)      ; First step with a start cap to act on: mark it.
  CP C                    ;
  JP NZ,flat_step_clip_10 ;
  LD A,(piece_extra_a)    ;
  BIT 4,A                 ;
  JP Z,draw_step          ;
  OR $80                  ;
  LD (piece_extra_a),A    ;
flat_step_clip_6:
  LD B,A                     ; An odd cap (a drop) facing the scroll's
  CP $96                     ; direction, on a byte boundary: keep the step's
  JR Z,flat_step_clip_8      ; address and screen x for fill_flat_end_column.
  BIT 0,A                    ;
  JR Z,flat_step_clip_9      ;
  CP $91                     ;
  LD A,(scroll_across)       ;
  JR Z,flat_step_clip_7      ;
  NEG                        ;
flat_step_clip_7:
  BIT 7,A                    ;
  JR NZ,flat_step_clip_9     ;
  LD A,(IX+$00)              ;
  AND $07                    ;
  JR NZ,flat_step_clip_9     ;
  LD A,B                     ;
  LD (piece_kept),A          ;
  EXX                        ;
  LD HL,(column_address)     ;
  LD (first_step_address),HL ;
  LD A,(piece_x)             ;
  LD (scratch_count),A       ;
  EXX                        ;
  JR flat_step_clip_9        ;
flat_step_clip_8:
  LD A,(column_address)    ; Cap $16: one column only, or nothing if that
  INC A                    ; column is outside.
  INC A                    ;
  AND $1F                  ;
  CP $1C                   ;
  JP NC,after_step_drawn_2 ;
  XOR A                    ;
  LD (blit_flat_step_0+1),A             ;
  LD (flat_blit_second_byte_0+1),A             ;
  LD A,$24                 ;
  LD (flat_blit_first_byte_0+1),A             ;
flat_step_clip_9:
  LD A,B                  ; Graphic offset of the cap: $24 + 12 * (cap AND 3),
  AND $03                 ; and on to the draw.
  ADD A,A                 ;
  ADD A,A                 ;
  LD B,A                  ;
  ADD A,A                 ;
  ADD A,B                 ;
  ADD A,$24               ;
  EXX                     ;
  LD E,A                  ;
  LD D,$00                ;
  JR draw_step_0          ;
flat_step_clip_10:
  LD A,C                  ; Last step with an end cap to act on: mark it and
  CP $01                  ; treat it the same way.
  JR NZ,draw_step         ;
  LD A,(piece_extra_b)    ;
  BIT 4,A                 ;
  JR Z,draw_step          ;
  OR $80                  ;
  LD (piece_extra_b),A    ;
  JP flat_step_clip_6     ;

; Draw a landscape step
;
; Used by the routines at landscape_step_loop, set_right_clip_columns,
; slope_lose_last_column, use_mirrored_right_clip, slope_step_at_left_edge and
; flat_step_clip.
;
; The draw shared by every direction, reached from landscape_step_loop,
; set_right_clip_columns, slope_lose_last_column, use_mirrored_right_clip,
; slope_step_at_left_edge and flat_step_clip (which jumps into it past the
; first lines with DE already holding a cap's graphic offset). It turns the
; variant into a graphic address and loads SP with it. If the step hangs below
; the play area (piece_y from $B8) it pops the rows below the edge away and
; starts at the bottom row; if it reaches above the top it shortens the row
; count (and, for a slope, cuts the piece short, since pieces only climb). Then
; the JR at the end, whose displacement was set to 0, 2, 5, 8 or 11 (0 by
; landscape_step_loop, the others by the clipping set-ups), lands on one of the
; five jumps at step_dispatch: the step's own blitter (IY) or one of the four
; edge-clipping blitters.
;
; Every blitter is entered with A = row pairs to draw, HL = the screen address
; less the step's byte advance, SP = the first graphic byte, and ends by
; jumping to after_step_drawn with HL where the next step will start.
;
; E Variant (0-2)
; HL' Screen address of the step, less the byte advance (column_address)
draw_step:
  LD A,E                  ; Normal graphic: the offset from this direction's
  EXX                     ; variant row (piece_offsets + 2 * variant).
  LD HL,(piece_offsets)   ;
  LD E,A                  ;
  SLA E                   ;
  LD D,$00                ;
  ADD HL,DE               ;
  LD E,(HL)               ;
; This entry point is used by the routine at flat_step_clip.
draw_step_0:
  LD HL,(piece_graphic)   ; SP = the step's graphic. (A cap's offset joins
  ADD HL,DE               ; here.)
  LD SP,HL                ;
  LD A,(half_rows)        ; E = row pairs. Does the step hang below the play
  LD E,A                  ; area (piece_y from $B8)?
  LD A,(piece_y)          ;
  CP $B8                  ;
  JP C,draw_step_3        ;
  SUB $B7                 ; It does: lose half the overhang in row pairs, and
  LD B,A                  ; pop those rows of the graphic away (D POPs a row
  SRL B                   ; pair: the byte advance, plus one for a sloped step
  LD A,E                  ; off a byte boundary).
  SUB B                   ;
  LD E,A                  ;
  LD A,(piece_step_y)     ;
  LD D,A                  ;
  LD A,(piece_rise)       ;
  AND A                   ;
  JR Z,draw_step_1        ;
  LD A,(IX+$00)           ;
  AND $07                 ;
  JR Z,draw_step_1        ;
  INC D                   ;
draw_step_1:
  LD A,D                  ;
draw_step_2:
  POP HL                  ;
  DEC A                   ;
  JR NZ,draw_step_2       ;
  DJNZ draw_step_1        ;
  LD H,$57                ; Start at the play area's bottom row (pixel row $B7)
  LD A,(column_address)   ; in the step's column.
  LD L,A                  ;
  LD A,(piece_dcolumn)    ;
  ADD A,L                 ;
  AND $1F                 ;
  OR $C0                  ;
  LD L,A                  ;
  LD A,(piece_dcolumn)    ;
  NEG                     ;
  ADD A,L                 ;
  LD L,A                  ;
  LD A,(draw_step_7+1)            ; For the mirrored left-clipping blitter a column
  CP $0B                  ; past 28 belongs to the character row above.
  JP NZ,draw_step_6       ;
  LD A,L                  ;
  CP $DD                  ;
  JP C,draw_step_6        ;
  LD A,L                  ;
  SUB $20                 ;
  LD L,A                  ;
  JP draw_step_6          ;
draw_step_3:
  LD B,A                  ; Not below: does the step reach above the top row
  LD A,(piece_rows)       ; ($18)?
  NEG                     ;
  ADD A,B                 ;
  SUB $18                 ;
  JP NC,draw_step_5       ;
  CPL                     ; It does: shorten it; a slope's piece is cut to at
  SRL A                   ; most one more step (C' = 2 unless already 1).
  NEG                     ;
  ADD A,E                 ;
  LD E,A                  ;
  LD A,(piece_rise)       ;
  AND A                   ;
  JR Z,draw_step_5        ;
  EXX                     ;
  LD A,C                  ;
  CP $01                  ;
  JR Z,draw_step_4        ;
  LD C,$02                ;
draw_step_4:
  EXX                     ;
draw_step_5:
  LD HL,(column_address)  ; HL = the screen address kept for this step.
draw_step_6:
  LD A,E                  ; A = row pairs to draw.
draw_step_7:
  JR draw_step_7          ; Patched dispatch: displacement 0, 2, 5, 8 or 11
                          ; lands on one of the five jumps that follow.

; The five jumps of the step dispatch
;
; Reached through the patched JR at the end of draw_step: displacement 0 lands
; on the first, 2 on the second, and so on.
step_dispatch:
  JP (IY)                 ; 0: the step's own blitter, from the fine-scroll
                          ; table.
  JP blit_right_clip      ; 2: blit_right_clip, right edge, piece running
                          ; right.
  JP blit_mirrored_right_clip ; 5: blit_mirrored_right_clip, right edge, piece
                              ; running left.
  JP blit_left_clip       ; 8: blit_left_clip, left edge, piece running right.
  JP blit_mirrored_left_clip ; 11: blit_mirrored_left_clip, left edge, piece
                             ; running left.

; Finish a step; at a piece's end repair behind it and colour it; then the next
; piece and map cell
;
; Used by the routines at blit_right_clip, blit_left_clip,
; blit_mirrored_left_clip, blit_mirrored_right_clip, blit_one, blit_three,
; blit_two, blit_mirror_three, blit_mirror_two and blit_mirror_one.
;
; Every step blitter ends with JP after_step_drawn (HL = where the next step
; starts); the flat-step blitter blit_flat_step stores column_address itself
; and comes back to the second instruction. edge_column and column_clipped come
; in further down, at the step counters, for steps handled at the edges.
;
; When a piece's last step is done the stack is put back at stack_top. That
; address is hard-wired: the landscape is always reached by the play loop's
; CALL ship_pass (2 bytes), its PUSH IY (2) and the CALL draw_landscape in
; scroll_landscape (2), below the game's stack top; the fly-in in
; start_landscape reaches it at the same depth (its CALL, a PUSH BC, the CALL).
;
; Then what lies behind the moving landscape is repaired. The screen is never
; cleared: the sky is black and the inside of the ground is a $55/$AA checker,
; and both look the same after a move of two pixels either way, which is why
; the landscape scrolls in steps of two. Only the strips a moving edge uncovers
; need painting. Across: when the fine horizontal position comes back to a byte
; boundary each step has just moved into the next byte column, leaving its old
; one behind; a sloped piece gets that column filled step by step by
; fill_under_slope, with the checker ($55AA) or black (0) chosen by the
; scroll's direction, the piece's direction and whether it is a ceiling
; (piece_ceiling); a flat piece's drop ends are done by fill_flat_end_column.
; Up and down: if the landscape moved vertically (scroll_down),
; fill_behind_moving_piece fills the rows behind every drawn step. Then
; colour_piece colours the piece.
;
; Then the next piece of this map cell begins (back in draw_landscape); when
; the cell's pieces are done, the next of the four map cells (ground_cell 0 to
; 3: upper-left, lower-left, upper-right, lower-right) follows, with the
; drawing origin moved down a cell (origin_y + $A0) or back up (origin_y + $60,
; i.e. - $A0), and right a cell (origin_x - $20, i.e. + $E0) for the right-hand
; pair. After the fourth, origin_x is put back and the landscape is done.
; draw_landscape jumps to both of those places too.
;
; HL Screen address where the next step starts
after_step_drawn:
  LD (column_address),HL  ; Keep it.
; This entry point is used by the routine at flat_blit_upper_row.
after_step_drawn_0:
  EXX                     ; Count the step as drawn (D'). The flat-step blitter
  INC D                   ; returns here.
; This entry point is used by the routines at edge_column and flat_step_clip.
after_step_drawn_1:
  LD A,(piece_steps_done) ; Count it in piece_steps_done and clipped_columns
  INC A                   ; too.
  LD (piece_steps_done),A ;
  LD A,(clipped_columns)  ;
  INC A                   ;
  LD (clipped_columns),A  ;
; This entry point is used by the routines at column_clipped,
; column_at_view_left, column_at_view_right, landscape_step_loop and
; flat_step_clip.
after_step_drawn_2:
  INC HL                    ; Next step: its variant byte, one fewer to go.
  DEC C                     ;
  JP NZ,landscape_step_loop ;
  LD (IX+$02),D           ; Steps drawn, into the current-piece record.
  LD SP,(landscape_sp)    ; Take the stack back from the blitters. Jetrun:
                          ; to where draw_landscape was entered; Cyberun used
                          ; the fixed stack_top, the depth it called from.
  CALL draw_flat_end_lip  ; A flat piece's end lip (draw_flat_end_lip).
  LD A,(piece_steps_done)   ; Column fill only if steps were drawn and the fine
  AND A                     ; horizontal position is on a byte boundary.
  JP Z,after_step_drawn_14  ;
  LD A,(origin_x)           ;
  AND $07                   ;
  JP NZ,after_step_drawn_14 ;
  LD (touch_depth),A       ; No horizontal scroll: a flat piece needs nothing;
  LD A,(scroll_across)     ; a sloped one is filled anyway, with a scroll
  AND A                    ; direction made up from its own direction
  JP NZ,after_step_drawn_4 ; (direction_flag, flipped by the ceiling flag
  LD A,(piece_rise)        ; piece_ceiling for a slope) and taken away
  AND A                    ; afterwards (touch_depth says to).
  JP Z,after_step_drawn_14 ;
  LD (touch_depth),A       ;
  LD A,(direction_flag)    ;
  LD B,A                   ;
  LD A,(piece_dx_copy)     ;
  AND A                    ;
  JR Z,after_step_drawn_3  ;
  LD A,(piece_ceiling)     ;
after_step_drawn_3:
  XOR B                    ;
  LD (scroll_across),A     ;
after_step_drawn_4:
  LD A,(piece_rise)         ; Flat piece: fill_flat_end_column.
  AND A                     ;
  JP Z,fill_flat_end_column ;
  EXX                        ; Start from the piece's first step
  LD HL,(first_step_address) ; (first_step_address, its y from first_step_y). A
  LD A,(first_step_y)        ; vertical wall is not a ceiling here, and moves a
  LD (piece_page_y),A        ; byte against its direction.
  LD A,(piece_dx_copy)       ;
  AND A                      ;
  JR NZ,after_step_drawn_5   ;
  LD (piece_ceiling),A       ;
  LD A,(direction_flag)      ;
  NEG                        ;
  LD (piece_dcolumn),A       ;
after_step_drawn_5:
  LD DE,$55AA             ; DE = the checker, or black if scroll direction,
  LD A,(scroll_across)    ; ceiling flag and piece direction say the uncovered
  LD B,A                  ; side is sky.
  LD A,(piece_ceiling)    ;
  XOR B                   ;
  LD B,A                  ;
  LD A,(direction_flag)   ;
  XOR B                   ;
  BIT 7,A                 ;
  JR Z,after_step_drawn_6 ;
  LD DE,$0000             ;
after_step_drawn_6:
  LD A,(direction_flag)     ; The column to fill: just left of the piece, or
  CP $FF                    ; past its steps, by direction.
  JR Z,after_step_drawn_8   ;
  LD A,(scroll_across)      ;
  BIT 7,A                   ;
  JR NZ,after_step_drawn_7  ;
  DEC L                     ;
  JP after_step_drawn_11    ;
after_step_drawn_7:
  LD A,(piece_step_y)       ;
  ADD A,L                   ;
  LD L,A                    ;
  JP after_step_drawn_9     ;
after_step_drawn_8:
  LD A,(scroll_across)      ;
  BIT 7,A                   ;
  JR NZ,after_step_drawn_10 ;
  DEC L                     ;
after_step_drawn_9:
  JP after_step_drawn_11    ;
after_step_drawn_10:
  LD A,(piece_dcolumn)      ;
  ADD A,L                   ;
  LD L,A                    ;
after_step_drawn_11:
  LD A,(piece_dx_copy)      ; A wall is filled as one column, 16 rows a step
  AND A                     ; tall.
  JR NZ,after_step_drawn_13 ;
  LD A,(piece_steps_done)   ;
  LD B,A                    ;
  XOR A                     ;
after_step_drawn_12:
  ADD A,$10                 ;
  DJNZ after_step_drawn_12  ;
  LD (piece_rows),A         ;
  LD A,$01                  ;
  LD (piece_steps_done),A   ;
after_step_drawn_13:
  LD A,(piece_rows)       ; C = row pairs a step, B = steps: fill
  SRL A                   ; (fill_under_slope).
  LD C,A                  ;
  EXX                     ;
  LD A,(piece_steps_done) ;
  LD B,A                  ;
  CALL fill_under_slope   ;
  LD A,(touch_depth)       ; Take away a made-up scroll direction.
  AND A                    ;
  JR Z,after_step_drawn_14 ;
  XOR A                    ;
  LD (scroll_across),A     ;
; This entry point is used by the routine at fill_flat_end_column.
after_step_drawn_14:
  EXX                            ; Vertical scroll this pass and steps drawn:
  LD A,(scroll_down)             ; fill the rows behind
  AND A                          ; (fill_behind_moving_piece).
  JR Z,after_step_drawn_15       ;
  LD A,(clipped_columns)         ;
  AND A                          ;
  JP NZ,fill_behind_moving_piece ;
; This entry point is used by the routine at fill_behind_moving_piece.
after_step_drawn_15:
  CALL colour_piece       ; Colour the piece (colour_piece).
  EXX                     ;
; This entry point is used by the routine at draw_landscape.
after_step_drawn_16:
  LD SP,(landscape_sp)    ; Stack back (Jetrun: as above); the next piece, if any are
  LD HL,(next_piece)      ; left in this map cell (pieces_left). draw_landscape
  LD A,(pieces_left)      ; jumps here for a piece it skips.
  DEC A                   ;
  LD (pieces_left),A      ;
  JP NZ,draw_landscape_7  ;
; This entry point is used by the routine at draw_landscape.
after_step_drawn_17:
  LD A,(ground_cell)       ; Next map cell of the window. draw_landscape jumps
  INC A                    ; here for an empty cell.
  LD (ground_cell),A       ;
  CP $04                   ;
  JR Z,after_step_drawn_19 ;
  BIT 0,A                  ; Origin down a cell for a lower one, back up for an
  LD B,$60                 ; upper one.
  JR Z,after_step_drawn_18 ;
  LD B,$A0                 ;
after_step_drawn_18:
  LD A,(origin_y)          ;
  ADD A,B                  ;
  LD (origin_y),A          ;
  LD A,(ground_cell)      ; Origin right a cell for the right-hand pair.
  CP $02                  ;
  JP NZ,draw_landscape_2  ;
  LD B,$20                ;
  LD A,(origin_x)         ;
  SUB B                   ;
  LD (origin_x),A         ;
  JP draw_landscape_2     ;
after_step_drawn_19:
  LD A,(origin_x)         ; Done: horizontal origin put back.
  ADD A,$20               ;
  LD (origin_x),A         ;
  RET                     ;

; End-lip graphics for flat floor pieces
;
; Used by draw_flat_end_lip. Three lips, four rows tall and one byte wide, one
; for each fine horizontal position 2, 4 and 6 (none is needed on a byte
; boundary), each listed from the bottom row up. The ceiling pieces' lips
; follow at ceiling_lip_bytes.
floor_lip_bytes:
  DEFB $40,$C0,$00,$00    ; Fine positions 2, 4, 6
  DEFB $50,$B0,$C0,$80    ;
  DEFB $54,$AC,$F0,$E0    ;

; Last flat step hangs into the border
;
; $FF when a flat piece's last step hangs off the left edge into the border
; (set by landscape_step_loop, cleared for each piece by draw_landscape); 0
; otherwise. It makes flat_step_clip skip that step, draw_flat_end_lip draw the
; piece's lip a character row up, and fill_behind_moving_piece treat the
; piece's fill differently.
last_step_in_border:
  DEFB $00

; End-lip graphics for flat ceiling pieces
;
; As floor_lip_bytes, for direction 7.
ceiling_lip_bytes:
  DEFB $00,$00,$C0,$C0    ; Fine positions 2, 4, 6
  DEFB $00,$C0,$70,$B0    ;
  DEFB $00,$F0,$5C,$AC    ;

; Draw the lip at the end of a flat piece whose end cap is $13
;
; Used by the routine at after_step_drawn.
;
; A flat run ending in cap $13 ($93 once seen) gets a lip one byte wide and
; four rows tall in the byte column after its last step, from floor_lip_bytes
; (floor) or ceiling_lip_bytes (ceiling) for the current fine horizontal
; position. Nothing is drawn on a byte boundary or outside the play area's
; columns, and the lip is cut to two rows at the play area's bottom (piece_y =
; $B9) or top (piece_y = $19).
draw_flat_end_lip:
  LD A,(piece_rise)       ; Only for a flat piece with end cap $13 that drew
  AND A                   ; something.
  RET NZ                  ;
  LD A,(piece_extra_b)    ;
  AND $7F                 ;
  CP $13                  ;
  RET NZ                  ;
  LD A,(piece_steps_done) ;
  AND A                   ;
  RET Z                   ;
  LD HL,floor_lip_bytes    ; DE = the lip for this direction and fine position.
  LD A,(IX+$03)            ;
  AND A                    ;
  JR Z,draw_flat_end_lip_0 ;
  LD HL,ceiling_lip_bytes  ;
draw_flat_end_lip_0:
  LD A,(origin_x)          ;
  AND $07                  ;
  RET Z                    ;
  DEC A                    ;
  DEC A                    ;
  ADD A,A                  ;
  LD E,A                   ;
  LD D,$00                 ;
  ADD HL,DE                ;
  EX DE,HL
  LD A,(last_step_in_border) ; The column after the last step; a last step
  AND A                      ; hanging into the border puts it a character row
  LD HL,(column_address)     ; up.
  JR Z,draw_flat_end_lip_1   ;
  LD (IX+$01),$00            ;
  LD A,L                     ;
  SUB $20                    ;
  LD L,A                     ;
  INC L                      ;
  INC L                      ;
  INC L                      ;
draw_flat_end_lip_1:
  INC L                      ;
  INC L                      ;
  INC L                      ;
  LD A,L                  ; Outside columns 1-28: nothing.
  AND $1F                 ;
  DEC A                   ;
  CP $1C                  ;
  RET NC                  ;
  LD B,$04                  ; At the bottom edge: two rows only, from the play
  LD A,(piece_y)            ; area's bottom row (the cut never came up in the
  CP $B9                    ; build's sessions).
  JR NZ,draw_flat_end_lip_2 ;
  INC DE                    ;
  INC DE                    ;
  LD H,$57                  ;
  LD A,L                    ;
  AND $1F                   ;
  OR $C0                    ;
  LD L,A                    ;
  LD B,$02                  ;
  JR draw_flat_end_lip_3    ;
draw_flat_end_lip_2:
  CP $19                    ; At the top edge: two rows only.
  JR NZ,draw_flat_end_lip_3 ;
  LD B,$02                  ;
draw_flat_end_lip_3:
  LD A,(DE)                ; Write the lip upwards.
  LD (HL),A                ;
  INC DE                   ;
  CALL line_up_hl          ;
  DJNZ draw_flat_end_lip_3 ;
  RET                      ;

; Blank the byte column a flat piece's drop leaves behind when scrolling across
;
; Used by the routine at after_step_drawn.
;
; Called at the end of a flat piece when the fine horizontal position is on a
; byte boundary and the landscape is scrolling across (scroll_across). A byte
; column four rows tall beside a drop at one end of the run is cleared to black
; by fill_under_slope. Which step gives the place depends on the current-piece
; record's +1: if zero, the piece's first step (first_step_address), provided
; its cap on the side the scroll moves towards (piece_extra_b when
; scroll_across is negative, else piece_extra_a) is odd; otherwise the step
; kept by flat_step_clip (piece_kept set), two columns on.
fill_flat_end_column:
  LD A,(scroll_across)     ; No horizontal scroll: nothing to do.
  AND A                    ;
  JP Z,after_step_drawn_14 ;
  LD A,(IX+$01)                ; +1 zero: is that cap odd? Then the column left
  AND A                        ; of the first step.
  JR NZ,fill_flat_end_column_1 ;
  LD A,(scroll_across)         ;
  BIT 7,A                      ;
  LD A,(piece_extra_b)         ;
  JR NZ,fill_flat_end_column_0 ;
  LD A,(piece_extra_a)         ;
fill_flat_end_column_0:
  BIT 0,A                      ;
  JP Z,after_step_drawn_14     ;
  EXX                          ;
  LD HL,(first_step_address)   ;
  DEC L                        ;
  JR fill_flat_end_column_2    ;
fill_flat_end_column_1:
  LD A,(piece_kept)           ; Otherwise the step kept by flat_step_clip, two
  AND A                       ; columns on (a character row up if it hung off
  JP Z,after_step_drawn_14    ; the left edge).
  EXX                         ;
  LD HL,(first_step_address)  ;
  INC L                       ;
  INC L                       ;
  LD A,(scratch_count)        ;
  CP $F0                      ;
  JR C,fill_flat_end_column_2 ;
  LD A,L                      ;
  SUB $20                     ;
  LD L,A                      ;
fill_flat_end_column_2:
  LD A,(first_step_y)         ; Its y; scrolling the other way, four columns
  LD (piece_page_y),A         ; further.
  LD A,(scroll_across)        ;
  BIT 7,A                     ;
  JR Z,fill_flat_end_column_3 ;
  LD A,L                      ;
  ADD A,$04                   ;
  LD L,A                      ;
fill_flat_end_column_3:
  LD DE,$0000             ; Black, two row pairs, one step: fill_under_slope.
  LD C,$02                ;
  EXX                     ;
  LD B,$01                ;
  CALL fill_under_slope   ;
  JP after_step_drawn_14  ;

; Work out a step's screen position and address
;
; Used by the routines at edge_column and landscape_step_loop.
;
; Screen x = in-cell x (piece_page_x) + horizontal origin (origin_x); screen y
; = in-cell y (piece_page_y) + vertical origin (origin_y). Both go into the
; current-piece record (+0, +1) and piece_x/piece_y, and HL is the screen
; address (pixel_to_screen). For the piece's first step the address is also
; kept in first_step_address (a character row back when the step hangs off the
; left edge, x from $F0) and its y in first_step_y; for the piece's first drawn
; step the screen position is kept in first_step_x/first_step_y_drawn
; (column_clipped calls the routine's last part for that alone).
;
;   IX Current-piece record (current_piece)
; O:HL Screen address of the step
step_screen_address:
  LD A,(piece_page_y)     ; Screen y.
  LD H,A                  ;
  LD A,(origin_y)         ;
  ADD A,H                 ;
  LD H,A                  ;
  LD (IX+$01),A           ;
  LD (piece_y),A          ;
  LD A,(piece_page_x)     ; Screen x.
  LD L,A                  ;
  LD A,(origin_x)         ;
  ADD A,L                 ;
  LD L,A                  ;
  LD (piece_x),A          ;
  LD (IX+$00),A           ;
  LD D,$00                   ; D = $20 if the step hangs off the left edge; the
  CP $F0                     ; address.
  JR C,step_screen_address_0 ;
  LD D,$20                   ;
step_screen_address_0:
  CALL pixel_to_screen       ;
  LD A,(piece_steps_done)     ; First step of the piece: keep its address and
  AND A                       ; y.
  JR NZ,step_screen_address_1 ;
  LD A,L                      ;
  SUB D                       ;
  LD L,A                      ;
  LD (first_step_address),HL  ;
  ADD A,D                     ;
  LD L,A                      ;
  LD A,(piece_y)              ;
  LD (first_step_y),A         ;
step_screen_address_1:
  LD A,(clipped_columns)  ; Not the first drawn step: done.
  AND A                   ;
  RET NZ                  ;
; This entry point is used by the routine at column_clipped.
step_screen_address_2:
  LD A,(piece_page_x)       ; Keep the first drawn step's screen position (also
  LD B,A                    ; entered here).
  LD A,(origin_x)           ;
  ADD A,B                   ;
  LD (first_step_x),A       ;
  LD A,(piece_page_y)       ;
  LD B,A                    ;
  LD A,(origin_y)           ;
  ADD A,B                   ;
  LD (first_step_y_drawn),A ;
  RET                       ;

; Adjust a vertical fill's start column and width for a horizontal scroll
;
; Used by the routine at fill_behind_moving_piece.
;
; Used by fill_behind_moving_piece for a flat piece with no step set up. With
; scroll_across negative the fill starts a column further left. The rest (a
; column back right and one narrower) can only run for scroll_across = -128,
; never ran, and looks dead.
;
; L Low byte of the fill's screen address
; C Fill width in bytes
adjust_fill_for_scroll:
  LD A,(scroll_across)
  BIT 7,A
  RET Z
  DEC L
  LD A,(piece_page_y)
  CP $5F
  RET NC
  LD A,(scroll_across)
  NEG
  BIT 7,A
  RET Z
  INC L
  DEC C
  RET

; Fill the rows a vertically scrolled piece has uncovered
;
; Used by the routine at after_step_drawn.
;
; When the landscape has moved up or down by vertical_step_size pixels (2 or 4)
; this pass, each drawn step of the piece leaves that many rows of its old
; place uncovered: below it when the landscape moved up, above when it moved
; down. Starting from the first drawn step (first_step_x), this paints them
; step by step (fill_next_step with IY = fill_two_rows for 2 rows,
; fill_four_rows for 4) with the checker ($55AA) for ground or black for sky --
; the other way round for a ceiling piece (piece_ceiling). The width per step
; is its byte advance (piece_step_y), adjusted for the shift, a reversing piece
; and drop caps (landscape_end_pieces, adjust_fill_for_scroll).
fill_behind_moving_piece:
  LD IY,fill_four_rows            ; Two rows or four.
  LD A,(vertical_step_size)       ;
  CP $04                          ;
  JR Z,fill_behind_moving_piece_0 ;
  LD IY,fill_two_rows             ;
fill_behind_moving_piece_0:
  LD DE,$0000                     ; Black or checker by the direction and the
  LD A,(scroll_down)              ; ceiling flag.
  LD B,A                          ;
  LD A,(piece_ceiling)            ;
  XOR B                           ;
  BIT 7,A                         ;
  JR Z,fill_behind_moving_piece_1 ;
  LD DE,$55AA                     ;
fill_behind_moving_piece_1:
  LD HL,(first_step_x)             ; Start at the first drawn step.
  LD A,(piece_dx_copy)             ;
  AND A                            ;
  JR NZ,fill_behind_moving_piece_4 ;
  LD A,(direction_flag)           ; A vertical wall: filled as one tall step;
  CP $01                          ; nothing if it is moving the wrong way.
  JR Z,fill_behind_moving_piece_2 ;
  LD A,L                          ;
  ADD A,$07                       ;
  LD L,A                          ;
fill_behind_moving_piece_2:
  LD A,(clipped_columns)          ;
  LD B,A                          ;
  XOR A                           ;
fill_behind_moving_piece_3:
  ADD A,$10                       ;
  DJNZ fill_behind_moving_piece_3 ;
  LD (piece_rows),A               ;
  LD A,$01                        ;
  LD (clipped_columns),A          ;
  LD DE,$55AA                     ;
  LD A,(direction_flag)           ;
  LD B,A                          ;
  LD A,(scroll_across)            ;
  AND A                           ;
  JR Z,fill_behind_moving_piece_4 ;
  XOR B                           ;
  BIT 7,A                         ;
  JP NZ,after_step_drawn_15       ;
fill_behind_moving_piece_4:
  LD A,(scroll_down)               ; Start above the step (moving down) or
  BIT 7,A                          ; below it (moving up).
  LD A,(vertical_step_size)        ;
  JR NZ,fill_behind_moving_piece_5 ;
  LD A,(piece_rows)                ;
  NEG                              ;
fill_behind_moving_piece_5:
  ADD A,H                          ;
  LD H,A                           ;
  LD (piece_page_y),A              ;
  LD (saved_speed),HL     ; Keep the start for landscape_end_pieces.
  LD A,(piece_rise)                ; Flat piece: moved by the horizontal
  AND A                            ; scroll, and filled as a single strip as
  JR NZ,fill_behind_moving_piece_9 ; wide as all its steps (1 + 3 a step, in
  LD A,(scroll_across)             ; piece_step_y, and less one into the
  NEG                              ; operand of the LD A,n near the end of
  ADD A,L                          ; landscape_end_pieces).
  LD L,A                           ;
  LD A,(clipped_columns)           ;
  LD B,A                           ;
  LD A,$01                         ;
  LD (clipped_columns),A           ;
  LD A,(last_step_in_border)       ;
  AND A                            ;
  JR Z,fill_behind_moving_piece_6  ;
  LD A,(piece_extra_b)             ;
  AND $7F                          ;
  CP $13                           ;
  JR NZ,fill_behind_moving_piece_6 ;
  LD A,E                           ;
  AND A                            ;
  JR Z,fill_behind_moving_piece_6  ;
  LD A,$01                         ;
  JR fill_behind_moving_piece_8    ;
fill_behind_moving_piece_6:
  LD A,$01                         ;
fill_behind_moving_piece_7:
  ADD A,$03                        ;
  DJNZ fill_behind_moving_piece_7  ;
fill_behind_moving_piece_8:
  LD (piece_step_y),A              ;
  DEC A                            ;
  LD (cy_8383+1),A                     ;
fill_behind_moving_piece_9:
  LD A,(piece_dx_copy)              ; No step set up and not a wall: moved by
  AND A                             ; the horizontal scroll; a piece that
  JP Z,fill_behind_moving_piece_15  ; reverses (piece_clip) turns
  LD A,(IX+$01)                     ; direction_flag round; off a byte boundary
  AND A                             ; the strip is a byte wider.
  JR NZ,fill_behind_moving_piece_15 ;
  LD A,E                            ;
  AND A                             ;
  JR Z,fill_behind_moving_piece_10  ;
  LD A,(piece_clip)                 ;
  AND A                             ;
  JR Z,fill_behind_moving_piece_10  ;
  LD A,H                            ;
  CP $1F                            ;
  JR NC,fill_behind_moving_piece_11 ;
fill_behind_moving_piece_10:
  LD A,(scroll_across)              ;
  NEG                               ;
  ADD A,L                           ;
  LD L,A                            ;
fill_behind_moving_piece_11:
  LD A,(piece_clip)                 ;
  AND A                             ;
  JR Z,fill_behind_moving_piece_15  ;
  CP $01                            ;
  JR Z,fill_behind_moving_piece_13  ;
  LD A,(direction_flag)             ;
  CP $01                            ;
  JR Z,fill_behind_moving_piece_14  ;
fill_behind_moving_piece_12:
  NEG                               ;
  LD (direction_flag),A             ;
  JR fill_behind_moving_piece_14    ;
fill_behind_moving_piece_13:
  LD A,(direction_flag)             ;
  CP $01                            ;
  JR Z,fill_behind_moving_piece_12  ;
fill_behind_moving_piece_14:
  LD A,L                            ;
  AND $07                           ;
  JR Z,fill_behind_moving_piece_15  ;
  LD A,(piece_step_y)               ;
  INC A                             ;
  LD (piece_step_y),A               ;
fill_behind_moving_piece_15:
  LD A,(piece_rise)           ; Flat piece: width adjusted for drop caps
  AND A                       ; (landscape_end_pieces).
  CALL Z,landscape_end_pieces ;
  LD B,$00                         ; Screen address of the start; x from $F0 is
  LD A,L                           ; the character row before.
  LD (scratch_count),A             ;
  CP $F0                           ;
  JR C,fill_behind_moving_piece_16 ;
  LD L,B                           ;
  INC B                            ;
fill_behind_moving_piece_16:
  CALL pixel_to_screen             ;
  LD A,L                           ;
  SUB B                            ;
  LD L,A                           ;
  LD A,(piece_step_y)               ; C = width; nudge the start column by the
  LD C,A                            ; piece's and the scroll's directions.
  LD A,(piece_dx_copy)              ;
  AND A                             ;
  JP Z,fill_behind_moving_piece_21  ;
  LD A,(piece_rise)                 ;
  AND A                             ;
  JR Z,fill_behind_moving_piece_18  ;
  LD A,(IX+$01)                     ;
  AND A                             ;
  JP Z,fill_behind_moving_piece_19  ;
  LD A,(scratch_count)              ;
  AND $07                           ;
  JP NZ,fill_behind_moving_piece_19 ;
  LD A,(scroll_across)              ;
  AND A                             ;
  JR Z,fill_behind_moving_piece_17  ;
  LD B,A                            ;
  LD A,(scroll_down)                ;
  XOR B                             ;
  LD B,A                            ;
  LD A,(direction_flag)             ;
  XOR B                             ;
  BIT 7,A                           ;
  JR Z,fill_behind_moving_piece_17  ;
  DEC L                             ;
  LD A,(scroll_across)              ;
  BIT 7,A                           ;
  JR Z,fill_behind_moving_piece_17  ;
  INC L                             ;
  INC L                             ;
fill_behind_moving_piece_17:
  JP fill_behind_moving_piece_21    ;
fill_behind_moving_piece_18:
  LD A,(IX+$01)                     ;
  AND A                             ;
  CALL Z,adjust_fill_for_scroll     ;
  JR fill_behind_moving_piece_21    ;
fill_behind_moving_piece_19:
  LD A,(piece_rise)                 ;
  AND A                             ;
  JR Z,fill_behind_moving_piece_21  ;
  LD A,(direction_flag)             ;
  CP $01                            ;
  LD A,(scroll_down)                ;
  JR NZ,fill_behind_moving_piece_20 ;
  NEG                               ;
fill_behind_moving_piece_20:
  BIT 7,A                           ;
  JR Z,fill_behind_moving_piece_21  ;
  INC L                             ;
fill_behind_moving_piece_21:
  EXX                     ; B = steps: fill behind them, then on to colouring.
  LD A,(clipped_columns)  ;
  LD B,A                  ;
  CALL fill_next_step     ;
  EXX                     ;
  JP after_step_drawn_15  ;

; Fill behind one step (loop head)
;
; Used by the routines at fill_behind_moving_piece and fill_up_past_step.
;
; Switches to the fill's register set and jumps to the routine in IY
; (fill_two_rows or fill_four_rows), which comes back through fill_up_past_step
; for the next step.
;
; B' Steps left
fill_next_step:
  EXX
  JP (IY)

; Move a fill up past the rest of a step, and loop
;
; Used by the routines at fill_two_rows and fill_four_rows.
;
; Moves HL up the rest of the step's height (piece_rows less the B rows already
; filled), keeps piece_page_y in step, and loops to fill_next_step for the next
; step.
;
; B Rows already filled
fill_up_past_step:
  LD A,(piece_rows)
  SUB B
  LD B,A
  LD A,(piece_page_y)
  SUB B
  LD (piece_page_y),A
  LD B,A                  ; Jetrun: HL straight to that row, its column kept.
  AND $07                 ; Cyberun walked it up two rows at a time with
  OR $40                  ; line_up_hl, a third of a busy pass.
  LD H,A                  ;
  LD A,B                  ;
  RRA                     ;
  RRA                     ;
  RRA                     ;
  AND $18                 ;
  OR H                    ;
  LD H,A                  ;
  LD A,B                  ;
  RLA                     ;
  RLA                     ;
  AND $E0                 ;
  LD B,A                  ;
  LD A,L                  ;
  AND $1F                 ;
  OR B                    ;
  LD L,A                  ;
  EXX
  DJNZ fill_next_step
  RET

; Fill two rows behind a step
;
; One row pair (fill_row_pair), then up the step.
fill_two_rows:
  CALL fill_row_pair
  LD B,$02
  JP fill_up_past_step

; Fill four rows behind a step
;
; Two row pairs, the second a byte advance back to the left, then up the step.
fill_four_rows:
  CALL fill_row_pair
  LD A,(piece_dcolumn)
  NEG
  ADD A,L
  LD L,A
  CALL fill_row_pair
  LD B,$04
  JP fill_up_past_step

; Fill one row pair across a step's width
;
; Used by the routines at fill_two_rows and fill_four_rows.
;
; Writes D on the row at HL and E on the row above, for C bytes rightwards,
; skipping any byte outside columns 1-28, and only when the row (piece_page_y)
; is inside the play area. Then moves piece_page_y and HL two rows up and a
; byte advance on.
;
; HL Screen address
; C Width in bytes
; DE Fill pattern: $55AA (checker) or 0
fill_row_pair:
  LD A,(piece_page_y)     ; Row outside the play area: nothing.
  CP $B8                  ;
  JR NC,fill_row_pair_2   ;
  CP $18                  ;
  JR C,fill_row_pair_2    ;
  LD B,C                  ; Across the width, inside columns 1-28 only.
  PUSH HL                 ;
  LD A,L                  ; Jetrun: a strip wholly inside columns 1-28 is
  AND $1F                 ; written without testing each byte's column.
  JR Z,fill_row_pair_0    ;
  ADD A,C                 ;
  CP $1E                  ;
  JR NC,fill_row_pair_0   ;
fill_row_pair_fast:
  LD (HL),D               ;
  DEC H                   ;
  LD (HL),E               ;
  INC H                   ;
  INC L                   ;
  DJNZ fill_row_pair_fast ;
  POP HL                  ;
  JR fill_row_pair_2      ;
fill_row_pair_0:
  LD A,L                  ;
  AND $1F                 ;
  DEC A                   ;
  CP $1C                  ;
  JR NC,fill_row_pair_1   ;
  LD (HL),D               ;
  DEC H                   ;
  LD (HL),E               ;
  INC H                   ;
fill_row_pair_1:
  INC L                   ;
  DJNZ fill_row_pair_0    ;
  POP HL                  ;
fill_row_pair_2:
  LD A,(piece_page_y)     ; Two rows up, a byte advance across.
  DEC A                   ;
  DEC A                   ;
  LD (piece_page_y),A     ;
  LD A,(piece_dcolumn)    ;
  ADD A,L                 ;
  LD L,A                  ;
  DEC H                   ;
  JP line_up_hl           ;

; Draw a sloped step cut off by the right edge
;
; Used by the routine at step_dispatch.
;
; Reached through step_dispatch (dispatch 2) for a sloped step of a piece
; running right (directions 1-3 and their ceilings) that crosses the play
; area's right edge: only its left one or two byte columns are written. Like
; the full blitters it zig-zags up the screen two rows at a time, popping the
; graphic from SP. After the first column's byte, the JR whose displacement
; set_right_clip_columns or slope_lose_last_column set decides the rest:
;
; * 0: the second column, then the upper row's second and first columns,
;   passing the third column's pair -- a three-byte step cut to two.
; * $1E: one column -- a three-byte step cut to one.
; * $1F: one column -- a two-byte step cut to one.
; * $20: one column -- a one-byte step, uncut.
;
; This was code typed as text and data in the first code map.
;
; A Row pairs
; HL Screen address, less the byte advance
; SP The step's graphic
blit_right_clip:
  LD B,A                  ; B = row pairs.
  LD A,(piece_dcolumn)    ; To the step's first column.
  ADD A,L                 ;
  LD L,A                  ;
blit_right_clip_0:
  POP DE                  ; Lower row, first column.
  LD (HL),E               ;
blit_right_clip_1:
  JR blit_right_clip_1    ; Patched: how much more of the row pair is drawn.
  INC L                   ; Second column; up a row.
  LD (HL),D               ;
  DEC H                   ;
  POP DE                  ; Pass the third column's pair; take the upper row's.
  POP DE                  ;
  LD (HL),E               ; Upper row: second column, first column.
  DEC L                   ;
blit_right_clip_2:
  LD (HL),D               ;
  DEC H                   ; Up a pixel row, crossing a character row if need
  LD A,H                  ; be.
  INC A                   ;
  AND $07                 ;
  JR NZ,blit_right_clip_3 ;
  LD A,L                  ;
  SUB $20                 ;
  LD L,A                  ;
  JR C,blit_right_clip_3  ;
  LD A,H                  ;
  ADD A,$08               ;
  LD H,A                  ;
blit_right_clip_3:
  DJNZ blit_right_clip_0  ; Next row pair.
  JP after_step_drawn     ; Done.
  POP DE                  ; One-column cuts: pass two pairs, one, or none; up a
  POP DE                  ; row; the upper row's first column.
  DEC H                   ;
  JP blit_right_clip_2    ;

; Draw a sloped step cut off by the left edge
;
; Used by the routine at step_dispatch.
;
; Reached through step_dispatch (dispatch 8) for a sloped step of a piece
; running right that hangs over the play area's left edge
; (slope_step_at_left_edge). HL moves to column 1 of the same character row;
; the first patched JR decides whether one or two graphic bytes are skipped
; (INC SP), so that the first byte popped belongs in column 1; the second
; decides how much of each row pair is written: displacement 0 the last two
; columns, $2C the last column of a two-byte step, $30 the last column of a
; three-byte step. A POP at the end of each row pair keeps the graphic in step.
; Afterwards the next step's column comes from move_across_kept.
;
; This was code typed as text and data in the first code map, before the staged
; tours ran it.
;
; A Row pairs
; HL Screen address
; SP The step's graphic
blit_left_clip:
  LD B,A                  ; B = row pairs.
  LD A,L                  ; Column 1 of this character row.
  INC A                   ;
  INC A                   ;
  AND $E0                 ;
  INC A                   ;
  LD L,A                  ;
  INC SP                  ; Skip a graphic byte...
blit_left_clip_0:
  JR blit_left_clip_0     ; ...patched: and another (displacement 0) or not
                          ; (1).
  INC SP                  ; The second byte skipped.
blit_left_clip_1:
  POP DE                  ; Lower row, column 1.
  LD (HL),E               ;
blit_left_clip_2:
  JR blit_left_clip_2     ; Patched: how much more of the row pair is drawn.
  INC L                   ; Column 2; up a row; upper row column 2, column 1.
  LD (HL),D               ;
  DEC H                   ;
  POP DE                  ;
  LD (HL),E               ;
  DEC L                   ;
blit_left_clip_3:
  LD (HL),D               ;
blit_left_clip_4:
  POP DE                  ; Pass the rest of the row pair.
  DEC H                   ; Up a pixel row, crossing a character row if need
  LD A,H                  ; be.
  INC A                   ;
  AND $07                 ;
  JR NZ,blit_left_clip_5  ;
  LD A,L                  ;
  SUB $20                 ;
  LD L,A                  ;
  JR C,blit_left_clip_5   ;
  LD A,H                  ;
  ADD A,$08               ;
  LD H,A                  ;
blit_left_clip_5:
  DJNZ blit_left_clip_1   ; Next row pair.
  LD A,(move_across_kept) ; The next step's column, from move_across_kept and
  LD B,A                  ; the byte advance.
  LD A,(piece_dcolumn)    ;
  LD C,A                  ;
  LD A,L                  ;
  AND $E0                 ;
  OR B                    ;
  SUB C                   ;
  LD L,A                  ;
  JP after_step_drawn     ; Done.
  DEC H                   ; Last column of a two-byte step: up a row, the upper
  JP blit_left_clip_3     ; row's byte.
  DEC H                   ; Last column of a three-byte step: up a row, the
  LD (HL),D               ; upper row's byte, pass a pair.
  POP DE                  ;
  JP blit_left_clip_4     ;

; Draw a mirrored sloped step cut off by the left edge
;
; Used by the routine at step_dispatch.
;
; Reached through step_dispatch (dispatch 11) for a sloped step of a piece
; running left (directions 4-6 and their ceilings) that hangs over the left
; edge. Those directions are drawn as mirror images: each byte is looked up in
; the bit-reversing table bit_reverse_table with B = its page and C = the byte,
; so the row count lives in B' and the loop switches register sets. HL goes to
; column 1; INC SP and the first patched JR skip one or two graphic bytes; the
; second patched JR (displacement 0, $26 or $2A, set by
; slope_step_at_left_edge) picks how many columns of each row pair are written.
;
; This was code partly typed as data in the first code map.
;
; A Row pairs
; HL Screen address
; SP The step's graphic
blit_mirrored_left_clip:
  EXX                     ; Row count into B'.
  LD B,A                  ;
  EXX                     ;
  LD A,L                  ; Column 1 of this character row.
  INC A                   ;
  INC A                   ;
  AND $E0                 ;
  INC A                   ;
  LD L,A                  ;
  LD B,high bit_reverse_table ; B = the page of the bit-reversing table.
  EXX                     ; Skip one graphic byte...
  INC SP                  ;
blit_mirrored_left_clip_0:
  JR blit_mirrored_left_clip_0 ; ...patched: and another (displacement 0) or
                               ; not (1).
  INC SP                  ; The second byte skipped.
blit_mirrored_left_clip_1:
  EXX                     ; Lower row, column 1, mirrored.
  POP DE                  ;
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
blit_mirrored_left_clip_2:
  JR blit_mirrored_left_clip_2 ; Patched: how much more of the row pair is
                               ; drawn.
  INC L                   ; Column 2; up a row; upper row column 2.
  LD C,D                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC H                   ;
  POP DE                  ;
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC L                   ;
blit_mirrored_left_clip_3:
  LD C,D                  ; Upper row, column 1.
  LD A,(BC)               ;
  LD (HL),A               ;
blit_mirrored_left_clip_4:
  POP DE                  ; Pass the rest of the row pair.
  DEC H                           ; Up a pixel row, crossing a character row if
  LD A,H                          ; need be.
  INC A                           ;
  AND $07                         ;
  JR NZ,blit_mirrored_left_clip_5 ;
  LD A,L                          ;
  SUB $20                         ;
  LD L,A                          ;
  JR C,blit_mirrored_left_clip_5  ;
  LD A,H                          ;
  ADD A,$08                       ;
  LD H,A                          ;
blit_mirrored_left_clip_5:
  EXX                            ; Next row pair (counted in B'); done.
  DJNZ blit_mirrored_left_clip_1 ;
  EXX                            ;
  JP after_step_drawn            ;
  DEC H                        ; One column of a two-byte step: up a row, the
  JP blit_mirrored_left_clip_3 ; upper row's byte.
  DEC H                        ; One column of a three-byte step: up a row, the
  LD C,D                       ; upper row's byte, pass a pair.
  LD A,(BC)                    ;
  LD (HL),A                    ;
  POP DE                       ;
  JP blit_mirrored_left_clip_4 ;

; Draw a mirrored sloped step cut off by the right edge
;
; Used by the routine at step_dispatch.
;
; Reached through step_dispatch (dispatch 5) for a sloped step of a piece
; running left that crosses the right edge. Like blit_mirrored_left_clip it
; mirrors each byte through the table bit_reverse_table and keeps the row count
; in B'. The patched JR (displacement set by use_mirrored_right_clip: 0 for two
; columns, $26, $27 or $28 for one, by how many pairs must be passed) decides
; how many of the step's columns are written.
;
; This was code partly typed as data in the first code map.
;
; A Row pairs
; HL Screen address less the byte advance
; SP The step's graphic
blit_mirrored_right_clip:
  EXX                     ; Row count into B'.
  LD B,A                  ;
  EXX                     ;
  LD A,(piece_dcolumn)    ; To the step's first column.
  ADD A,L                 ;
  LD L,A                  ;
  LD B,high bit_reverse_table      ; B = the page of the bit-reversing table; into
  JP blit_mirrored_right_clip_1 ; the loop.
blit_mirrored_right_clip_0:
  EXX                     ; Loop: the drawing registers.
blit_mirrored_right_clip_1:
  POP DE                  ; Lower row, first column, mirrored.
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
blit_mirrored_right_clip_2:
  JR blit_mirrored_right_clip_2 ; Patched: how much more of the row pair is
                                ; drawn.
  INC L                   ; Second column; up a row; pass the third column's
  LD C,D                  ; pair; upper row second column.
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC H                   ;
  POP DE                  ;
  POP DE                  ;
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC L                   ;
blit_mirrored_right_clip_3:
  LD C,D                  ; Upper row, first column.
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC H                            ; Up a pixel row, crossing a character row
  LD A,H                           ; if need be.
  INC A                            ;
  AND $07                          ;
  JR NZ,blit_mirrored_right_clip_4 ;
  LD A,L                           ;
  SUB $20                          ;
  LD L,A                           ;
  JR C,blit_mirrored_right_clip_4  ;
  LD A,H                           ;
  ADD A,$08                        ;
  LD H,A                           ;
blit_mirrored_right_clip_4:
  EXX                             ; Next row pair (counted in B'); done.
  DJNZ blit_mirrored_right_clip_0 ;
  EXX                             ;
  JP after_step_drawn             ;
  POP DE                        ; One-column cuts: pass two pairs, one, or
  POP DE                        ; none; up a row; the upper row's first column.
  DEC H                         ;
  JP blit_mirrored_right_clip_3 ;

; The next tile record to draw
;
; A pointer into map_window_tiles: reset to its start by scroll_landscape and
; load_map_window, and moved on a word by draw_landscape as it takes each map
; cell's tile record (and by load_map_window as it fills the list).
map_window_pointer:
  DEFW $0000

; The tile records of the four map cells on screen
;
; Filled by load_map_window whenever the view crosses into a new map cell: the
; addresses of the tile records (from tile_table) of the view's page, the one
; below, the one to the right and the one below-right -- the same order as
; their collision-box lists ground_cell_top_left, ground_cell_bottom_left,
; ground_cell_top_right and ground_cell_bottom_right. Walked through
; map_window_pointer by draw_landscape once a pass.
map_window_tiles:
  DEFW $0000
  DEFW $0000
  DEFW $0000
  DEFW $0000

; The tile bytes of the four map cells on screen
;
; Written by load_map_window: the four cells' tile bytes from the map
; landscape_map, in the same order as map_window_tiles. The collision and
; object code reads them too.
map_window_tile_bytes:
  DEFB $02                ; The view's cell

; The tile byte of the cell below the view's
;
; The second of map_window_tile_bytes's four, read on its own by the collision
; and object code.
map_window_tile_below:
  DEFB $02

; The tile byte of the cell right of the view's
;
; The third of map_window_tile_bytes's four.
map_window_tile_right:
  DEFB $02

; The tile byte of the cell below and right of the view's
;
; The fourth of map_window_tile_bytes's four.
map_window_tile_below_right:
  DEFB $02

; The window's right-hand map column
;
; The map column after view_column, wrapped to 0-95, written by read_map_cell
; as it reads the map. load_map_window, drop_far_objects, spawn_column_objects
; and the object code read it.
right_map_column:
  DEFB $00

; The landscape's attribute above ground
;
; Copied by start_landscape from the current planet's pair in
; planet_ground_colours. set_landscape_colours uses it for map rows above row
; 12; draw_landscape's colouring reads it too.
ground_attr_above:
  DEFB $00

; The landscape's attribute below ground
;
; Copied by start_landscape from the current planet's pair in
; planet_ground_colours. set_landscape_colours uses it for map rows 12 on, the
; caverns.
ground_attr_below:
  DEFB $00

; Scroll the view, step through the map, and draw the landscape
;
; Used by the routines at ship_pass and start_landscape.
;
; Jumped to at the end of ship_pass (once a play pass) and from start_landscape
; (the fly-in). scroll_down and scroll_across are this pass's vertical and
; horizontal scroll in pixels (signed, from the ship's movement). The scroll
; origins origin_y and origin_x move by them, and the in-cell positions at the
; play area's bottom and left edges (view_y = $B7 - origin_y, view_x = 8 -
; origin_x) move the other way. When an edge position leaves its map cell it
; wraps by a cell -- 160 rows or 224 columns -- and the map row or column
; (view_row, view_column) moves by one; C counts the wraps into record_ground.
;
; If any happened (or in the fly-in) the window of four map cells is rebuilt
; (load_map_window) and its colours chosen (set_landscape_colours). The
; landscape is drawn (draw_landscape) unless the view is in the top three map
; rows, which hold no landscape (the four collision-box lists are just
; emptied). The sprites are handled by update_ground_objects before or after
; the landscape by the scroll's direction, draw_beams and draw_stars run, four
; rows of the frame below the play area's bottom-left corner are made solid
; again, and the pass goes on at draw_ship -- or at fly_in_step during the
; fly-in.
scroll_landscape:
  LD A,(scroll_down)        ; vertical_step_size = size of the vertical scroll.
  BIT 7,A                   ;
  JR Z,scroll_landscape_0   ;
  NEG                       ;
scroll_landscape_0:
  LD (vertical_step_size),A ;
  LD C,$00                ; No wraps yet; HL = map column and row.
  LD HL,(view_column)     ;
scroll_landscape_1:
  LD A,(origin_y)          ; Move vertically.
  LD B,A                   ;
  LD A,(scroll_down)       ;
  ADD A,B                  ;
  LD (origin_y),A          ;
  LD A,(scroll_down)       ;
  NEG                      ;
  LD B,A                   ;
  LD A,(view_y)            ;
  ADD A,B                  ;
  LD (view_y),A            ;
  CP $B8                   ;
  JR NC,scroll_landscape_2 ;
  CP $16                   ; The bottom edge has passed the cell's top: wrap to
  JR NC,scroll_landscape_3 ; the cell above (row - 1).
  LD A,$B7                 ;
  LD (view_y),A            ;
  XOR A                    ;
  LD (origin_y),A          ;
  DEC H                    ;
  INC C                    ;
  JP scroll_landscape_1    ;
scroll_landscape_2:
  LD A,$17                ; Past its bottom: wrap to the cell below (row + 1).
  LD (view_y),A           ;
  LD A,$A0                ;
  LD (origin_y),A         ;
  INC H                   ;
  INC C                   ;
  JP scroll_landscape_1   ;
scroll_landscape_3:
  LD A,(scroll_across)     ; Move horizontally.
  LD B,A                   ;
  LD A,(origin_x)          ;
  ADD A,B                  ;
  LD (origin_x),A          ;
  LD A,(scroll_across)     ;
  NEG                      ;
  LD B,A                   ;
  LD A,(view_x)            ;
  ADD A,B                  ;
  LD (view_x),A            ;
  CP $E9                   ;
  JR NC,scroll_landscape_4 ;
  CP $07                   ; The left edge has passed the cell's left: wrap
  JR NC,scroll_landscape_5 ; (column - 1).
  LD A,$E8                 ;
  LD (view_x),A            ;
  LD A,$20                 ;
  LD (origin_x),A          ;
  DEC L                    ;
  INC C                    ;
  JP scroll_landscape_3    ;
scroll_landscape_4:
  LD A,$08                ; Past its right: wrap (column + 1).
  LD (view_x),A           ;
  XOR A                   ;
  LD (origin_x),A         ;
  INC L                   ;
  INC C                   ;
  JP scroll_landscape_3   ;
scroll_landscape_5:
  LD A,C                     ; Rebuild the window if a cell was crossed.
  LD (record_ground),A       ;
  AND A                      ;
  CALL NZ,load_map_window    ;
  CALL set_landscape_colours ; Its colours.
  CALL colour_this_pass      ; Jetrun: whether colour_piece need colour.
  LD DE,map_window_tiles     ; Walk the window's four cells from the first.
  LD (map_window_pointer),DE ;
  JP draw_landscape          ; Jetrun: and draw. Cyberun drew its ground
                             ; objects, beams, stars and ship around this, and
                             ; drew no landscape in map rows 0-2.

; Current-piece record
;
; Five bytes, addressed through IX while a piece is drawn: +0, +1 the screen x
; and y of the latest step set up (+1 is cleared at the start of each piece, so
; zero means none yet), +2 the number of steps drawn, +3 the direction (0-15).
; +4 is not used here. test_landscape_at and hit_block use the same bytes as
; scratch.
current_piece:
  DEFS $05

; Jetrun: decide whether the pieces are coloured this pass
;
; Used by the routine at scroll_landscape.
;
; colour_piece colours the cells along each piece from its screen place, and
; all the pieces move with the origins: the cells it colours change only when
; the horizontal origin moves into another cell (pieces' x are on byte
; boundaries), when the horizontal scroll comes onto or off a byte boundary (a
; $13 end takes a column more off one), when the landscape moves up or down
; at all (pieces' y are odd), or when the window moves to new pages
; (record_ground). Otherwise it would write each
; cell as it already is, so colour_now is cleared and it is skipped. While the
; landscape is being built (map_rebuild) nothing is coloured, and the pass
; after must colour, so the key is spoiled.
colour_this_pass:
  LD A,(origin_x)         ; B: the across cell, bit 0 off a byte boundary.
  AND $07                 ;
  ADD A,$FF               ;
  SBC A,A                 ;
  AND $01                 ;
  LD B,A                  ;
  LD A,(origin_x)         ;
  AND $F8                 ;
  OR B                    ;
  LD B,A                  ;
  LD A,(origin_y)         ; C: the down origin, whole: pieces' y are odd, so
  LD C,A                  ; any move up or down may cross a cell.
  LD HL,(colour_key)      ; Last pass's.
  LD (colour_key),BC      ;
  LD A,(map_rebuild)      ; Building: spoil the key, colour the pass after.
  AND A                   ;
  JR Z,colour_this_pass_0 ;
  LD HL,$FFFF             ;
  LD (colour_key),HL      ;
  RET                     ;
colour_this_pass_0:
  LD A,(record_ground)    ; New pages: colour.
  AND A                   ;
  JR NZ,colour_this_pass_1 ;
  AND A                   ; Moved into other cells: colour.
  SBC HL,BC               ;
  LD A,$00                ;
  JR Z,colour_this_pass_2 ;
colour_this_pass_1:
  LD A,$01                ;
colour_this_pass_2:
  LD (colour_now),A       ;
  RET                     ;

; Jetrun: the cells colour_this_pass last saw, and whether to colour.
colour_key:
  DEFW $FFFF
colour_now:
  DEFB $01

; Choose the landscape attributes for the upper and lower map cells
;
; Used by the routine at scroll_landscape.
;
; When the window has moved (record_ground) or during the fly-in:
; map_row_colour gets the attribute for the upper map row (view_row) and
; map_row_colour_next the one for the row below -- ground_attr_above for rows
; below 12 (above ground), ground_attr_below from row 12 (caverns). The
; routine's tail is called as a subroutine for the first and fallen into for
; the second.
set_landscape_colours:
  LD A,(record_ground)    ; Nothing changed: done.
  LD B,A                  ;
  LD A,(map_rebuild)      ;
  OR B                    ;
  RET Z                   ;
  LD A,(view_row)              ; The upper row's attribute.
  CALL set_landscape_colours_0 ;
  LD (map_row_colour),A        ;
  LD A,(view_row)              ; The lower row's.
  INC A                        ;
set_landscape_colours_0:
  CP CAVERN_ROW + 1            ; Jetrun: its map's (Cyberun's rows count from 1)
  LD A,(ground_attr_above)     ;
  LD B,A                       ;
  JR C,set_landscape_colours_1 ;
  LD A,(ground_attr_below)     ;
  LD B,A                       ;
set_landscape_colours_1:
  LD A,B                       ;
  LD (map_row_colour_next),A   ;
  RET                          ;

; Build the 2x2 window of map cells
;
; Used by the routine at scroll_landscape.
;
; HL is the map column (0 to MAP_W - 1, wrapping at both ends) and row. The
; four tile bytes -- (column, row), (column, row+1), (column+1, row),
; (column+1, row+1) -- are read from the map world_map (MAP_W bytes a row,
; read_map_cell) into map_window_tile_bytes, and their tile records' addresses
; from tile_table into map_window_tiles. Below the map, the empty tile.
;
; Jetrun: Cyberun went on to bring in the objects lying in the window, and
; swapped one tile for another in its fly-in; neither is here.
;
; HL Map column (L) and row (H)
load_map_window:
  LD DE,MAP_W                ; Wrap the column; reset the window's pointer.
  LD A,L                     ;
  CP $FF                     ;
  JR NZ,load_map_window_0    ;
  LD L,MAP_W - 1             ;
load_map_window_0:
  CP MAP_W                   ;
  JR NZ,load_map_window_1    ;
  LD L,$00                   ;
load_map_window_1:
  LD (view_column),HL        ;
  LD BC,map_window_tiles     ;
  LD (map_window_pointer),BC ;
  PUSH HL                            ; The four tile bytes.
  CALL read_map_cell                 ;
  LD (map_window_tile_bytes),A       ;
  ADD HL,DE                          ;
  LD A,(HL)                          ;
  LD (map_window_tile_below),A       ;
  POP HL                             ;
  INC L                              ;
  CALL read_map_cell                 ;
  LD (map_window_tile_right),A       ;
  ADD HL,DE                          ;
  LD A,(HL)                          ;
  LD (map_window_tile_below_right),A ;
  LD A,(view_row)                    ; The view's page on the map's last row:
  CP MAP_H                           ; the lower two are below it.
  JR NZ,load_map_window_2            ;
  LD A,EMPTY_TILE                    ;
  LD (map_window_tile_below),A       ;
  LD (map_window_tile_below_right),A ;
load_map_window_2:
  CP MAP_H + 1                       ; Below the map: all four.
  JR NZ,load_map_window_6            ;
  LD BC,EMPTY_TILE * $0101           ;
  LD (map_window_tile_bytes),BC      ;
  LD (map_window_tile_right),BC      ;
load_map_window_6:
  LD BC,map_window_tile_bytes ; The four tile-record addresses.
  LD A,$04                    ;
load_map_window_7:
  EX AF,AF'                   ;
  LD A,(BC)                   ;
  LD L,A                      ;
  LD H,$00                    ;
  LD DE,tile_table            ;
  ADD HL,HL                   ;
  ADD HL,DE                   ;
  LD E,(HL)                   ;
  INC HL                      ;
  LD D,(HL)                   ;
  LD HL,(map_window_pointer)  ;
  LD (HL),E                   ;
  INC HL                      ;
  LD (HL),D                   ;
  INC HL                      ;
  LD (map_window_pointer),HL  ;
  INC BC                      ;
  EX AF,AF'                   ;
  DEC A                       ;
  JR NZ,load_map_window_7     ;
  RET

; Address of a map cell
;
; Used by the routine at read_map_cell.
;
; Map rows are numbered from 1: row H is at landscape_map + (H - 1) * $60 (rows
; 0 and 1 give the same address; read_map_cell treats row 0 as empty). The
; column wraps: $FF becomes 95 and 96 becomes 0. C is left holding the wrapped
; column.
;
;   HL Column (L), row (H)
;   DE $60
; O:HL Address in the map
; O:C Column, wrapped
map_cell_address:
  LD C,L                  ; Row.
  LD A,H                  ;
  AND A                   ;
  LD B,H                  ;
  LD HL,world_map         ; Jetrun's map;
  JR Z,map_cell_address_1 ;
  DEC B                   ;
  JR Z,map_cell_address_1 ;
map_cell_address_0:
  ADD HL,DE               ;
  DJNZ map_cell_address_0 ;
map_cell_address_1:
  LD A,C                   ; Column, wrapped. (Never needed in the sessions.)
  CP $FF                   ;
  JR NZ,map_cell_address_2 ;
  LD C,MAP_W - 1           ;
map_cell_address_2:
  LD A,C                   ;
  CP MAP_W                 ;
  JR NZ,map_cell_address_3 ;
  LD C,$00                 ;
map_cell_address_3:
  ADD HL,BC                ;
  RET

; Read a tile byte from the map
;
; Used by the routine at load_map_window.
;
; Returns the tile byte at (column, row), keeping the wrapped column in
; right_map_column. For the upper row 0 (above the map) it returns 0 (empty)
; and moves HL a row back so that HL + $60 is still the lower cell's.
;
;   HL Column (L), row (H)
; O:A Tile byte
read_map_cell:
  CALL map_cell_address
  LD A,C
  LD (right_map_column),A
  LD A,(view_row)
  AND A
  JR Z,read_map_cell_0
  LD A,(HL)
  RET
read_map_cell_0:
  AND A                   ; Row 0.
  SBC HL,DE               ;
  XOR A                   ;
  RET                     ;

; Flat-step blitter: lose the first column
;
; Where the first patched JR in blit_flat_step goes when flat_step_clip sets
; its displacement to $EE: the first step of a piece with start cap $10, off a
; byte boundary, is drawn from its second column (by way of the end of
; flat_blit_left_edge, which skips one graphic byte and repatches the JR for
; the following row pairs).
flat_blit_lose_first:
  INC L
  JP flat_blit_left_edge_1

; Draw a flat landscape step
;
; The blitter for directions 0 and 7 (flat floor and flat ceiling) at every
; fine position: all four entries in the fine-scroll tables point here. The
; step is three bytes wide and four rows tall (two row pairs); its graphic is
; twelve bytes in the order the zig-zag writes them -- the bottom row left to
; right, the row above right to left, and so on up. SP points at the graphic
; and each POP DE fetches two bytes.
;
; column_address is moved on three bytes for the next step. Then each row pair
; passes three JRs whose displacements flat_step_clip patches: all 0 draws
; every column; the first (here) can go to flat_blit_left_edge (start column 0
; or 31: from the second or third byte, at column 1), to flat_blit_lose_first,
; or, on later row pairs, straight into flat_blit_left_rows; the second
; (flat_blit_first_byte) to flat_blit_one_column (one column); the third
; (flat_blit_second_byte) to flat_blit_left_two (two columns). The cut paths
; POP the bytes they do not write, so SP stays in step with the graphic.
;
; Each row pair ends with the step up a pixel row, including the crossing of a
; character row, and DJNZ back to this JR (in flat_blit_upper_row); at the end
; it returns to the second instruction of after_step_drawn with column_address
; already set. An uncut row pair costs about 170 T-states and a whole step
; about 400 -- less than the deciding done for each step in landscape_step_loop
; and flat_step_clip.
;
; A Row pairs to draw
; HL Screen address, three bytes to the left
; SP The step's graphic
blit_flat_step:
  LD B,A                  ; The next step starts three bytes on.
  LD A,(column_address)   ;
  ADD A,$03               ;
  LD (column_address),A   ;
  INC L                   ; To the step's first column.
  INC L                   ;
  INC L                   ;
; This entry point is used by the routine at flat_blit_upper_row.
blit_flat_step_0:
  JR blit_flat_step_0     ; Patched: 0 to draw; $33, $EE or $4C for the cut
                          ; paths.

; Flat-step blitter: first column of the lower row
;
; Part of blit_flat_step.
flat_blit_first_byte:
  POP DE
  LD (HL),E
flat_blit_first_byte_0:
  JR flat_blit_first_byte_0 ; Patched: 0, or $24 to flat_blit_one_column.

; Flat-step blitter: second column of the lower row
;
; Part of blit_flat_step.
flat_blit_second_byte:
  INC L
  LD (HL),D
flat_blit_second_byte_0:
  JR flat_blit_second_byte_0 ; Patched: 0, or $26 to flat_blit_left_two.

; Flat-step blitter: third column, the upper row, and the step up
;
; Part of blit_flat_step: the third column of the lower row, one row up, then
; the upper row right to left; then up another pixel row with the fix-up for
; leaving a character row (H back up by 8 within the third, unless the
; character row was the third's top one), and the loop.
flat_blit_upper_row:
  INC L                   ; Third column, lower row.
  POP DE                  ;
  LD (HL),E               ;
  DEC H                   ; Row up; third, second, first columns.
  LD (HL),D               ; flat_blit_left_two joins at the second,
  DEC L                   ; flat_blit_one_column at the first.
; This entry point is used by the routine at flat_blit_left_two.
flat_blit_upper_row_0:
  POP DE
  LD (HL),E
  DEC L
; This entry point is used by the routine at flat_blit_one_column.
flat_blit_upper_row_1:
  LD (HL),D               ; }
; This entry point is used by the routines at flat_blit_left_two_rows and
; flat_blit_left_one_row.
flat_blit_upper_row_2:
  DEC H                       ; Up a pixel row, crossing a character row if
  LD A,H                      ; need be. flat_blit_left_two_rows and
  INC A                       ; flat_blit_left_one_row join here.
  AND $07                     ;
  JR NZ,flat_blit_upper_row_3 ;
  LD A,L                      ;
  SUB $20                     ;
  LD L,A                      ;
  JR C,flat_blit_upper_row_3  ;
  LD A,H                      ;
  ADD A,$08                   ;
  LD H,A                      ;
flat_blit_upper_row_3:
  DJNZ blit_flat_step_0   ; Next row pair (back to the patched JR in
                          ; blit_flat_step).
  JP after_step_drawn_0   ; Done: count the step and carry on.

; Flat-step blitter: one column only
;
; Reached by the JR in flat_blit_first_byte (displacement $24) after the first
; byte has been written: row up, two POPs to pass the rest of the row pair's
; graphic, and the upper row's first-column byte (D of the last pop), written
; by the last part of flat_blit_upper_row.
flat_blit_one_column:
  DEC H
  POP DE
  POP DE
  JP flat_blit_upper_row_1

; Draw only a flat piece's left two bytes
;
; One of the clipped ways through the flat-piece blitter blit_flat_step, for a
; piece that runs off the right-hand side of the play area with two of its
; three bytes still on it. flat_step_clip sends the loop here by patching the
; JR in flat_blit_second_byte (offset $26) when the piece's column (the low
; five bits of column_address) is $18. Each pair of rows is then drawn two
; bytes wide: the first row's third byte and the second row's right-hand byte
; are popped and dropped, so SP stays in step with the graphic.
flat_blit_left_two:
  DEC H                   ; Up a pixel row: the first row's third byte is not
                          ; drawn
  POP DE                  ; Drop it, and the second row's right-hand byte with
                          ; it
  JP flat_blit_upper_row_0 ; Draw the second row's other two bytes, right to
                           ; left, and go round the loop

; Start a flat piece that crosses the left-hand side of the play area
;
; The first pass of the flat-piece blitter blit_flat_step comes here when
; flat_step_clip has patched the JR at the top of its loop to offset $33 (the
; piece's column is $1C or $1D, that is, it begins just left of the play area,
; whose columns are 1 to 28). It keeps the column saved for the next piece
; (column_address) in the right character row, moves L to column 1 of the row,
; and patches the loop's JR again (offset $4C) so that every later pair of rows
; goes straight to flat_blit_left_rows's second instruction. Then it skips the
; graphic's first byte, and through the JR flat_step_clip also patched (0 or 1)
; maybe a second one, so that only the bytes that lie on the play area are
; drawn.
;
; Column $1D leaves two bytes of each row to draw (flat_blit_left_two_rows),
; column $1C one (flat_blit_left_one_row). The POPs that follow are one byte
; out of step with the graphic's pairs, which is why each row's last write and
; the drops in those two routines look lopsided.
;
; A the column kept for the next piece, low byte (column_address after the
;   blitter added 3)
; HL the screen address of the piece's first byte
flat_blit_left_edge:
  INC A                       ; Has the next piece's column come round to the
  AND $1F                     ; start of a character row?
  JR NZ,flat_blit_left_edge_0 ;
  LD A,L                  ; If so, take it back into this one
  SUB $20                 ;
  LD (column_address),A   ;
flat_blit_left_edge_0:
  LD A,L                  ; L to column 1 of this pixel row
  AND $E0                 ;
  INC A                   ;
  LD L,A                  ;
; This entry point is used by the routine at flat_blit_lose_first.
flat_blit_left_edge_1:
  LD A,$4C                ; From now on the loop's JR goes to
  LD (blit_flat_step_0+1),A            ; flat_blit_left_rows + 1 (offset $4C)
  INC SP                  ; Skip the graphic's first byte
flat_blit_left_edge_2:
  JR flat_blit_left_edge_2 ; JR patched by flat_step_clip: 0 skips a second
                           ; byte at flat_blit_left_rows, 1 does not

; Draw a flat piece's rows that lie right of the play area's left-hand side
;
; Part of flat_blit_left_edge's clipped path. The INC SP here is executed only
; on the first pass, and only when flat_step_clip left the JR before it at 0
; (the piece starts two bytes left of the play area); every later pass of the
; blitter's loop enters at the POP. The JR at the end is patched by
; flat_step_clip too: 0 goes on to draw two bytes (flat_blit_left_two_rows),
; $0B one (flat_blit_left_one_row).
flat_blit_left_rows:
  INC SP                  ; Skip another byte of the graphic
  POP DE                  ; The first visible byte of the row, at column 1
  LD (HL),E               ;
flat_blit_left_rows_0:
  JR flat_blit_left_rows_0 ; JR patched by flat_step_clip: 0 for two bytes, $0B
                           ; for one

; Draw a pair of rows two bytes wide at the play area's left-hand side
;
; For a flat piece that begins one byte left of the play area: draws the second
; byte of the first row next to the one flat_blit_left_rows drew, the second
; row's two right-hand bytes back the other way, and drops the second row's
; left-hand byte together with the first byte of the next pair (the POPs run
; one byte out of step with the graphic since flat_blit_left_edge's INC SP).
flat_blit_left_two_rows:
  INC L                   ; The first row's other byte, at column 2
  LD (HL),D               ;
  POP DE                  ; Up a row; the second row's two bytes, right to left
  DEC H                   ;
  LD (HL),E               ;
  DEC L                   ;
  LD (HL),D               ;
  POP DE                  ; Drop the second row's left-hand byte and the next
                          ; row's first
  JP flat_blit_upper_row_2 ; Up a row, the character-row fix-up and the loop

; Draw a pair of rows one byte wide at the play area's left-hand side
;
; For a flat piece that begins two bytes left of the play area: one byte of
; each row is drawn, at column 1, and the rest popped and dropped.
flat_blit_left_one_row:
  DEC H                   ; Up a row: the second row's right-hand byte, at
  LD (HL),D               ; column 1
  POP DE                  ; Drop the second row's other two bytes and the next
  POP DE                  ; row's first two
  JP flat_blit_upper_row_2 ; Up a row, the character-row fix-up and the loop

; Landscape pieces: blitters and graphics at a shift of 2 pixels
;
; The first of four tables of 16 entries, one per piece direction (the high
; nibble of the piece's direction-and-steps byte in its tile record, kept in
; (IX+3)), chosen by draw_landscape from the fine scroll position and kept in
; shift_table: this one for a shift of 2 pixels, piece_blitters_shift4 for 4,
; piece_blitters_shift6 for 6 and piece_blitters_shift0 for 0. Each entry is
; two words: the blitter that draws a step of the piece, which
; landscape_step_loop loads into IY and step_dispatch jumps to, and the step's
; graphic at that shift, which it keeps in piece_graphic and starts SP from.
;
; The directions: 0 is flat, three bytes wide; 1, 2 and 3 are slopes that climb
; to the right (8 rows over 16 pixels, 8 rows over 8, 16 rows over 8), 4, 5 and
; 6 the same three climbing to the left; 7 to 13 are 0 to 6 upside down
; (ceilings: rock above, sky below), and 14 and 15 are a 16-row wall facing
; either way. Each graphic holds three variants of the step one above the other
; (9 or 17 rows each; 28 rows for a flat step); landscape_step_loop picks one
; and the count of row pairs comes in A.
;
; Only nine graphics are stored: a step climbing to the left is its partner's
; graphic started one row later and drawn by a blitter that mirrors each byte
; through the bit-reversed table at bit_reverse_table (blit_mirror_two,
; blit_mirror_one). That works because the graphics zig-zag: each pair of rows
; is stored left to right and then right to left, so read one row later every
; row's bytes come in the other order. A mirrored shifted step uses the
; partner's graphic at the opposite shift: a slope climbing left at a shift of
; 2 is the right-climbing one at 6, mirrored.
;
; The blitters: blit_flat_step for the flat steps at every shift; at shift 0
; blit_two (two bytes wide), blit_one (one byte), and their mirrored twins
; blit_mirror_two (entered one DEC L early, at the end of blit_mirror_three)
; and blit_mirror_one; at shifts 2 to 6, one byte wider, blit_three (entered at
; its second INC L), blit_two (at its second INC L) and the mirrored
; blit_mirror_three (at its second DEC L) and blit_mirror_two. The walls
; (directions 14 and 15) enter one instruction later than the slopes, skipping
; the INC L or DEC L that places a slope in its column.
piece_blitters_shift2:
  DEFW blit_flat_step     ; Shift 2: directions 0 (flat) and 1 (climbs right,
  DEFW flat_piece_shifted ; 16 pixels)
  DEFW cy_E4A8              ;
  DEFW slope_1_shifted    ;
  DEFW cy_E4D0              ; Directions 2 and 3 (climb right, 8 pixels: 8 and 16
  DEFW slope_2_shifted    ; rows)
  DEFW cy_E4D0              ;
  DEFW slope_3_shifted    ;
  DEFW cy_E4F2              ; Directions 4 and 5 (climb left: mirrors of 1 and 2)
  DEFW cy_E8BC+5              ;
  DEFW blit_mirror_two    ;
  DEFW cy_E7C2+6              ;
  DEFW blit_mirror_two        ; Directions 6 (mirror of 3) and 7 (flat, upside
  DEFW cy_E9F6+6                  ; down)
  DEFW blit_flat_step         ;
  DEFW flat_piece_two_shifted ;
  DEFW cy_E4A8              ; Directions 8 and 9 (1 and 2 upside down)
  DEFW slope_8_shifted    ;
  DEFW cy_E4D0              ;
  DEFW slope_9_shifted    ;
  DEFW cy_E4D0              ; Directions 10 and 11 (3 and 4 upside down)
  DEFW slope_10_shifted   ;
  DEFW cy_E4F2              ;
  DEFW cy_EF52+5              ;
  DEFW blit_mirror_two    ; Directions 12 and 13 (5 and 6 upside down)
  DEFW cy_EE58+6              ;
  DEFW blit_mirror_two    ;
  DEFW cy_F089+6              ;
  DEFW cy_E4D1              ; Directions 14 and 15 (wall, and its mirror)
  DEFW wall_shifted       ;
  DEFW cy_E52D              ;
  DEFW cy_ED6E+6              ;

; Landscape pieces: blitters and graphics at a shift of 4 pixels
;
; Laid out as piece_blitters_shift2: 16 entries, a blitter and a graphic for
; each piece direction.
piece_blitters_shift4:
  DEFW blit_flat_step     ; Shift 4: directions 0 and 1
  DEFW cy_EAB8+4              ;
  DEFW cy_E4A8              ;
  DEFW cy_E85C+5              ;
  DEFW cy_E4D0              ; Directions 2 and 3
  DEFW cy_E782+6              ;
  DEFW cy_E4D0              ;
  DEFW cy_E986+6              ;
  DEFW cy_E4F2              ; Directions 4 and 5
  DEFW cy_E864              ;
  DEFW blit_mirror_two    ;
  DEFW cy_E78A              ;
  DEFW blit_mirror_two    ; Directions 6 and 7
  DEFW cy_E98E              ;
  DEFW blit_flat_step     ;
  DEFW cy_EBB4+4              ;
  DEFW cy_E4A8              ; Directions 8 and 9
  DEFW cy_EEF2+5              ;
  DEFW cy_E4D0              ;
  DEFW cy_EE18+6              ;
  DEFW cy_E4D0              ; Directions 10 and 11
  DEFW cy_F019+6              ;
  DEFW cy_E4F2              ;
  DEFW cy_EEFA              ;
  DEFW blit_mirror_two    ; Directions 12 and 13
  DEFW cy_EE20              ;
  DEFW blit_mirror_two    ;
  DEFW cy_F021              ;
  DEFW cy_E4D1              ; Directions 14 and 15
  DEFW cy_ECFE+6              ;
  DEFW cy_E52D              ;
  DEFW cy_ED06              ;

; Landscape pieces: blitters and graphics at a shift of 6 pixels
;
; Laid out as piece_blitters_shift2: 16 entries, a blitter and a graphic for
; each piece direction.
piece_blitters_shift6:
  DEFW blit_flat_step     ; Shift 6: directions 0 and 1
  DEFW cy_EB10              ;
  DEFW cy_E4A8              ;
  DEFW cy_E8BC+2              ;
  DEFW cy_E4D0              ; Directions 2 and 3
  DEFW cy_E7C2+4              ;
  DEFW cy_E4D0              ;
  DEFW cy_E9F6+4              ;
  DEFW cy_E4F2              ; Directions 4 and 5
  DEFW slope_1_shifted+3              ;
  DEFW blit_mirror_two    ;
  DEFW slope_2_shifted+2              ;
  DEFW blit_mirror_two    ; Directions 6 and 7
  DEFW slope_3_shifted+2              ;
  DEFW blit_flat_step     ;
  DEFW cy_EC0C              ;
  DEFW cy_E4A8              ; Directions 8 and 9
  DEFW cy_EF52+2              ;
  DEFW cy_E4D0              ;
  DEFW cy_EE58+4              ;
  DEFW cy_E4D0              ; Directions 10 and 11
  DEFW cy_F089+4              ;
  DEFW cy_E4F2              ;
  DEFW slope_8_shifted+3              ;
  DEFW blit_mirror_two    ; Directions 12 and 13
  DEFW slope_9_shifted+2              ;
  DEFW blit_mirror_two    ;
  DEFW slope_10_shifted+2              ;
  DEFW cy_E4D1              ; Directions 14 and 15
  DEFW cy_ED6E+4              ;
  DEFW cy_E52D              ;
  DEFW wall_shifted+2              ;

; Landscape pieces: blitters and graphics at a shift of 0 pixels
;
; Laid out as piece_blitters_shift2: 16 entries, a blitter and a graphic for
; each piece direction.
piece_blitters_shift0:
  DEFW blit_flat_step     ; Shift 0: directions 0 and 1
  DEFW cy_E583              ;
  DEFW blit_two           ;
  DEFW cy_E6A5              ;
  DEFW blit_one           ; Directions 2 and 3
  DEFW cy_E64E              ;
  DEFW blit_one           ;
  DEFW cy_E716              ;
  DEFW cy_E52B              ; Directions 4 and 5
  DEFW cy_E6A5+2              ;
  DEFW blit_mirror_one    ;
  DEFW cy_E64E+1              ;
  DEFW blit_mirror_one    ; Directions 6 and 7
  DEFW cy_E716+1              ;
  DEFW blit_flat_step     ;
  DEFW cy_E5D9              ;
  DEFW blit_two           ; Directions 8 and 9
  DEFW cy_E66C              ;
  DEFW blit_one           ;
  DEFW cy_E630              ;
  DEFW blit_one           ; Directions 10 and 11
  DEFW cy_E6E0              ;
  DEFW cy_E52B              ;
  DEFW cy_E66C+2              ;
  DEFW blit_mirror_one    ; Directions 12 and 13
  DEFW cy_E630+1              ;
  DEFW blit_mirror_one    ;
  DEFW cy_E6E0+1              ;
  DEFW cy_E48C              ; Directions 14 and 15
  DEFW cy_EC63              ;
  DEFW cy_E55C              ;
  DEFW cy_EC63+1              ;

; Terrain piece shapes
;
; Nine records of three bytes, read by set_piece_shape, which copies one to
; piece_dx, piece_dcolumn and piece_rise for the piece being drawn: its run in
; pixels (negative for a piece that climbs to the left; 0 for a wall), its
; width in bytes signed the same way (also the step from one column of the
; ground fill to the next, fill_under_slope), and its rise in pixel rows (0 for
; a flat piece). Directions 0 to 6 (the high nibble of the map byte) use
; records 0 to 6, directions 7 to 15 records 0 to 8.
piece_shapes:
  DEFB $18,$03,$00        ; 0: flat, 24 pixels, 3 bytes
  DEFB $10,$02,$08        ; 1: climbs right, 16 pixels, 2 bytes, 8 rows
  DEFB $08,$01,$08        ; 2: climbs right, 8 pixels, 1 byte, 8 rows
  DEFB $08,$01,$10        ; 3: climbs right, 8 pixels, 1 byte, 16 rows
  DEFB $F0,$FE,$08        ; 4: climbs left, mirror of 1
  DEFB $F8,$FF,$08        ; 5: climbs left, mirror of 2
  DEFB $F8,$FF,$10        ; 6: climbs left, mirror of 3
  DEFB $00,$01,$10        ; 7 (direction 14): a wall, 16 rows
  DEFB $00,$FF,$10        ; 8 (direction 15): the wall, mirrored

; Look up a terrain piece's shape
;
; Used by the routines at load_piece_steps and piece_ends.
;
; Called by load_piece_steps and piece_ends with the piece in hand. Copies its
; direction's three bytes from piece_shapes to piece_dx (run in pixels),
; piece_dcolumn (width in bytes) and piece_rise (rise in rows); directions 7
; and up (the ceilings, and the walls) use the records seven lower and set
; piece_ceiling to $80. Then sets direction_flag and the displacement of the JR
; at the end of landscape_step_loop to match: for a piece that climbs to the
; right (width positive) direction_flag is $FF and the JR skips the NEG at
; slope_step_at_right_edge; for one that climbs to the left it is 1 and the NEG
; is done.
;
; IX the collision-box list of the map cell being drawn (see draw_landscape);
;    (IX+3) the piece's direction
set_piece_shape:
  LD HL,piece_shapes      ; The shape records
  LD A,(IX+$03)           ; Directions 0 to 6 go straight to their record
  CP $07                  ;
  JR C,set_piece_shape_0  ;
  LD A,$80                ; Directions 7 to 15: say so, and use records 0 to 8
  LD (piece_ceiling),A    ;
  LD A,(IX+$03)           ;
  SUB $07                 ;
set_piece_shape_0:
  LD E,A                  ; Three bytes a record
  ADD A,A                 ;
  ADD A,E                 ;
  LD E,A                  ;
  LD D,$00                ;
  ADD HL,DE               ;
  LD A,(HL)               ; Run, width and rise
  LD (piece_dx),A         ;
  INC HL                  ;
  LD A,(HL)               ;
  LD (piece_dcolumn),A    ;
  INC HL                  ;
  LD A,(HL)               ;
  LD (piece_rise),A       ;
  LD A,$01                ; Say it climbs to the left: direction 1, the NEG
  LD (direction_flag),A   ; done
  XOR A                   ;
  LD (landscape_step_loop_10+1),A            ;
  LD A,(piece_dcolumn)
  BIT 7,A                 ; It does if the width is negative
  RET NZ                  ;
  LD A,$FF                ; Climbs to the right: $FF, and the JR jumps over the
  LD (direction_flag),A   ; NEG
  LD A,$02                ;
  LD (landscape_step_loop_10+1),A            ;
  RET                     ;

; The current terrain piece's direction, and a flag of the collision-box
; builder's
;
; For the landscape: $FF for a piece that climbs to the right (directions 0 to
; 3, 7 to 10, 14), 1 for one that climbs to the left. Set by set_piece_shape,
; turned round by fill_behind_moving_piece when a piece reverses, and read
; throughout the landscape drawing (landscape_step_loop,
; slope_step_at_right_edge, after_step_drawn and others).
;
; place_collision_box borrows it as well: set to 1 there, it says the part to
; the right is still to test, and next_part clears it when it does so. The code
; map took it for an unused byte.
direction_flag:
  DEFB $00

; Fill the ground under a terrain piece, column by column
;
; Used by the routines at after_step_drawn and fill_flat_end_column.
;
; Called by after_step_drawn once a piece is drawn, to fill what lies beneath
; it with the ground's checkerboard (DE = $55AA) or to clear it (DE = 0), and
; by fill_flat_end_column to clear a column four rows deep. Each column is one
; byte wide and climbs from HL for C pairs of rows: D is written on one pixel
; row and E on the row above. After each column L moves on by the piece's width
; in bytes (piece_dcolumn), and piece_page_y, the screen row the fill has
; reached, goes up by the column's height. B, the number of columns, is the
; number of steps of the piece drawn (piece_steps_done), so this is one column
; a step, each the step's width in bytes across and as tall as the fill needs,
; which is how the ground under a slope comes out solid.
;
; A column is clipped to the play area: one in screen column 0 or 29 to 31 is
; not drawn at all (the pointer is only moved on); if the fill starts below row
; 183 ($B7, the bottom of the play area) the first rows are dropped and it
; starts at the bottom row of the play area; and near the top it is cut short
; by what the sum with piece_rows (the piece's height) and 24 says. The
; arithmetic of the top clip is read but not traced through.
;
; B the number of columns
; C' pairs of rows in each column
; DE' the two pattern bytes ($55AA for the ground's checkerboard, 0 to clear)
; HL' the screen address of the first column's bottom byte
fill_under_slope:
  EXX                     ; Into the other set: B counts this column's pairs of
  LD B,C                  ; rows
  LD A,L                   ; Off the play area (column 0, or 29 and up)? Only
  AND $1F                  ; move on
  DEC A                    ;
  CP $1C                   ;
  JR NC,fill_under_slope_3 ;
  LD A,(piece_page_y)     ; Does the fill start below the play area (row 184 or
  CP $B8                  ; more)?
  JR C,fill_under_slope_0 ;
  JR Z,fill_under_slope_0 ;
  SUB $B7                 ; Then drop the rows that would lie below it
  SRL A                   ;
  NEG                     ;
  ADD A,B                 ;
  LD B,A                  ;
  LD H,$57                ; And start on the play area's bottom row, $57C0 +
  LD A,L                  ; the column
  AND $1F                 ;
  OR $C0                  ;
  LD L,A                  ;
  JP fill_under_slope_1   ;
fill_under_slope_0:
  LD B,A                   ; Will the column reach above the top of the play
  LD A,(piece_rows)        ; area?
  NEG                      ;
  ADD A,B                  ;
  SUB $18                  ;
  LD B,C                   ;
  JR NC,fill_under_slope_1 ;
  CPL                     ; Then shorten it
  SRL A                   ;
  NEG                     ;
  ADD A,B                 ;
  LD B,A                  ;
fill_under_slope_1:
  LD A,(piece_page_y)     ; piece_page_y goes up by the column's height (two
  SLA C                   ; rows a pair)
  SUB C                   ;
  SRL C                   ;
  LD (piece_page_y),A     ;
fill_under_slope_2:
  LD (HL),D               ; Fill the column: D, up a row, E, up a row
  DEC H                   ;
  LD (HL),E               ;
  CALL line_up_hl         ;
  DJNZ fill_under_slope_2 ;
  LD A,(piece_dcolumn)    ; On to the next column, by the piece's width in
  ADD A,L                 ; bytes
  LD L,A                  ;
  EXX                     ; The next column
  DJNZ fill_under_slope   ;
  RET                     ;
fill_under_slope_3:
  LD A,(piece_page_y)     ; A column off the play area: account for its height
  SLA B                   ; and step across
  SUB B                   ;
  SRL B                   ;
  LD (piece_page_y),A     ;
  LD A,(piece_dcolumn)    ;
  ADD A,L                 ;
  LD L,A                  ;
fill_under_slope_4:
  DEC H                   ; Move HL up by its height without drawing
  CALL line_up_hl         ;
  DJNZ fill_under_slope_4 ;
  EXX                     ; The next column
  DJNZ fill_under_slope   ;
  RET                     ;

; Draw a one-byte-wide terrain step
;
; The blitter for the one-byte-wide slopes at shift 0: directions 2, 3, 9 and
; 10 here, the wall (direction 14) one instruction on, skipping the INC L. Two
; rows a POP, one byte a row, climbing the screen with DEC H; about 75 T-states
; a pair of rows. The right-climbing twin of blit_mirror_one.
;
; A the number of pairs of rows
; HL the screen address of the bottom row, less one
; SP the graphic (at the variant to draw)
blit_one:
  INC L                   ; Step right into the column; B counts the pairs of
cy_E48C:
  LD B,A                  ; rows; pop two bytes
blit_one_0:
  POP DE                  ;
  LD (HL),E               ; One on this row, up a row, the other on the row
  DEC H                   ; above, up a row
  LD (HL),D               ;
  DEC H                   ;
  LD A,H                  ; Into the next character row up if this one is done;
  INC A                   ; the next pair; leave HL as the column for the next
  AND $07                 ; step (after_step_drawn)
  JR NZ,blit_one_1        ;
  LD A,L                  ;
  SUB $20                 ;
  LD L,A                  ;
  JR C,blit_one_1         ;
  LD A,H                  ;
  ADD A,$08               ;
  LD H,A                  ;
blit_one_1:
  DJNZ blit_one_0         ;
  JP after_step_drawn     ;

; Draw a three-byte-wide terrain step
;
; The blitter for the two-byte-wide slopes shifted by 2, 4 or 6 pixels, which
; are three bytes wide: directions 1 and 8, entered at the second INC L (the
; first is not used by the tables). Each pair of rows is three POPs: a row left
; to right, up a row, a row right to left; about 125 T-states a pair.
;
; A the number of pairs of rows
; HL the screen address of the bottom row's first byte, less two
; SP the graphic
blit_three:
  INC L                   ; Step right into the column; B counts the pairs of
cy_E4A8:
  INC L                   ; rows
  INC L                   ;
  LD B,A                  ;
blit_three_0:
  POP DE                  ; Pop two bytes: the row's first two, left to right
  LD (HL),E               ;
  INC L                   ;
  LD (HL),D               ;
  INC L                   ;
  POP DE                  ; Pop two more: the row's third byte; up a row; the
  LD (HL),E               ; next row's right-hand byte
  DEC H                   ;
  LD (HL),D               ;
  DEC L                   ;
  POP DE                  ; Pop two more: that row's other two bytes, right to
  LD (HL),E               ; left; up a row
  DEC L                   ;
  LD (HL),D               ;
  DEC H                   ;
  LD A,H                  ; Into the next character row up if this one is done;
  INC A                   ; the next pair; leave HL as the column for the next
  AND $07                 ; step
  JR NZ,blit_three_1      ;
  LD A,L                  ;
  SUB $20                 ;
  LD L,A                  ;
  JR C,blit_three_1       ;
  LD A,H                  ;
  ADD A,$08               ;
  LD H,A                  ;
blit_three_1:
  DJNZ blit_three_0       ;
  JP after_step_drawn     ;

; Draw a two-byte-wide terrain step
;
; Directions 1 and 8 at shift 0 (here), the one-byte slopes shifted by 2, 4 or
; 6 (directions 2, 3, 9 and 10, at the second INC L), and the wall shifted
; (direction 14, at the LD B,A). Two POPs a pair of rows: a row left to right,
; up, a row right to left, up; about 105 T-states a pair.
;
; A the number of pairs of rows
; HL the screen address of the bottom row's first byte, less one or two
; SP the graphic
blit_two:
  INC L                   ; Step right into the column; B counts the pairs of
cy_E4D0:
  INC L                   ; rows
cy_E4D1:
  LD B,A                  ;
blit_two_0:
  POP DE                  ; Pop two bytes: a row left to right; up a row
  LD (HL),E               ;
  INC L                   ;
  LD (HL),D               ;
  DEC H                   ;
  POP DE                  ; Pop two more: the row above, right to left; up a
  LD (HL),E               ; row
  DEC L                   ;
  LD (HL),D               ;
  DEC H                   ;
  LD A,H                  ; Into the next character row up if this one is done;
  INC A                   ; the next pair; leave HL as the column for the next
  AND $07                 ; step
  JR NZ,blit_two_1        ;
  LD A,L                  ;
  SUB $20                 ;
  LD L,A                  ;
  JR C,blit_two_1         ;
  LD A,H                  ;
  ADD A,$08               ;
  LD H,A                  ;
blit_two_1:
  DJNZ blit_two_0         ;
  JP after_step_drawn     ;

; Draw a three-byte-wide terrain step, mirrored
;
; Directions 4 and 11 shifted by 2, 4 or 6 pixels, entered at the second DEC L
; (the first is not used by the tables). As blit_three, but each byte goes
; through the bit-reversed table at bit_reverse_table, and the graphic is the
; partner's at the opposite shift, started one row on. The last DEC L is the
; entry for directions 4 and 11 at shift 0 into blit_mirror_two.
;
; A the number of pairs of rows
; HL the screen address, plus two
; SP the graphic
blit_mirror_three:
  DEC L                   ; Step left into the column
cy_E4F2:
  DEC L                   ;
  DEC L                   ;
  LD B,high bit_reverse_table ; B' holds the table's page, B the count; (the loop)
  EXX                     ; pop two bytes and mirror the first
  LD B,A                  ;
blit_mirror_three_0:
  EXX                     ;
  POP DE                  ;
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ; It goes on the left; the second
  INC L                   ;
  LD C,D                  ;
  LD A,(BC)               ; Mirrored on its right; pop two more and mirror the
  LD (HL),A               ; first
  INC L                   ;
  POP DE                  ;
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ; The row's third byte; up a row; the next
  DEC H                   ;
  LD C,D                  ;
  LD A,(BC)               ; Mirrored, right to left; pop two more and mirror
  LD (HL),A               ; the first
  DEC L                   ;
  POP DE                  ;
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ; Leftwards; the last of the row
  DEC L                   ;
  LD C,D                  ;
  LD A,(BC)                 ; Mirrored; up a row; into the next character row
  LD (HL),A                 ; up if this one is done; the next pair; leave HL
  DEC H                     ; as the column for the next step. The last DEC L
  LD A,H                    ; is the entry for directions 4 and 11 at shift 0
  INC A                     ; into blit_mirror_two
  AND $07                   ;
  JR NZ,blit_mirror_three_1 ;
  LD A,L                    ;
  SUB $20                   ;
  LD L,A                    ;
  JR C,blit_mirror_three_1  ;
  LD A,H                    ;
  ADD A,$08                 ;
  LD H,A                    ;
blit_mirror_three_1:
  EXX                       ;
  DJNZ blit_mirror_three_0  ;
  EXX                       ;
  JP after_step_drawn       ;
cy_E52B:
  DEC L                     ;

; Draw a two-byte-wide terrain piece, mirrored
;
; The blitter for the pieces that climb to the left and are two bytes wide:
; directions 4 and 11 at shift 0 (entered one DEC L earlier, at the end of
; blit_mirror_three), directions 5, 6, 12 and 13 at shifts 2 to 6 (here), and
; the wall direction 15 at those shifts (at blit_mirror_two + 1, skipping the
; DEC L). It draws like the two-byte blitter at blit_two -- POP DE, two bytes
; left to right, up a row, two bytes right to left, up a row -- but each byte
; goes through the bit-reversed table at bit_reverse_table (built by
; build_bit_reverse), so the graphic comes out mirrored. With the graphic
; started one row later than its right-climbing partner's (see
; piece_blitters_shift2), each row's bytes arrive in the mirrored order too.
;
; The table lookups make it about 40 T-states a pair of rows slower than the
; plain blitter: about 150 T-states for two rows of two bytes, against about
; 105.
;
; A the number of pairs of rows
; HL the screen address of the bottom row's right-hand byte, plus one
; SP the piece's graphic (at the variant to draw)
blit_mirror_two:
  DEC L                   ; Step left into the piece's column
cy_E52D:
  LD B,high bit_reverse_table ; B' holds the table's page; B the count
  EXX                     ;
  LD B,A                  ;
blit_mirror_two_0:
  EXX                     ; Pop two bytes; the first, mirrored, on the left
  POP DE                  ;
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
  INC L                   ; The second, mirrored, on its right
  LD C,D                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC H                   ; Up a row
  POP DE                  ; Pop two more: the first on the right
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC L                   ; The second on the left
  LD C,D                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC H                   ; Up a row
  LD A,H                  ; Into the next character row up if this one is done
  INC A                   ;
  AND $07                 ;
  JR NZ,blit_mirror_two_1 ;
  LD A,L                  ;
  SUB $20                 ;
  LD L,A                  ;
  JR C,blit_mirror_two_1  ;
  LD A,H                  ;
  ADD A,$08               ;
  LD H,A                  ;
blit_mirror_two_1:
  EXX                     ; The next pair of rows
  DJNZ blit_mirror_two_0  ;
  EXX                     ; Leave HL as the column for the next piece
  JP after_step_drawn     ; (after_step_drawn)

; Draw a one-byte-wide terrain piece, mirrored
;
; The blitter for the one-byte-wide pieces that climb to the left at shift 0:
; directions 5, 6, 12 and 13 here, and the wall direction 15 at blit_mirror_one
; + 1 (skipping the DEC L). Each popped byte is mirrored through the
; bit-reversed table at bit_reverse_table on its way to the screen; one byte a
; row, two rows a POP. The right-climbing twin is the blitter at blit_one,
; which the code map left as data.
;
; A the number of pairs of rows
; HL the screen address of the bottom row's byte, plus one
; SP the piece's graphic (at the variant to draw)
blit_mirror_one:
  DEC L                   ; Step left into the piece's column
cy_E55C:
  LD B,high bit_reverse_table ; B' holds the table's page; B the count
  EXX                     ;
  LD B,A                  ;
blit_mirror_one_0:
  EXX                     ; Pop two bytes: the first, mirrored, then up a row
  POP DE                  ;
  LD C,E                  ;
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC H                   ;
  LD C,D                  ; The second, mirrored, then up a row
  LD A,(BC)               ;
  LD (HL),A               ;
  DEC H                   ;
  LD A,H                  ; Into the next character row up if this one is done
  INC A                   ;
  AND $07                 ;
  JR NZ,blit_mirror_one_1 ;
  LD A,L                  ;
  SUB $20                 ;
  LD L,A                  ;
  JR C,blit_mirror_one_1  ;
  LD A,H                  ;
  ADD A,$08               ;
  LD H,A                  ;
blit_mirror_one_1:
  EXX                     ; The next pair of rows
  DJNZ blit_mirror_one_0  ;
  EXX                     ; Leave HL as the column for the next piece
  JP after_step_drawn     ; (after_step_drawn)

; Landscape graphics: the flat piece (direction 0)
;
; Its three variants and its four end caps, each drawn as one step of direction
; 0 at shift 0 by the blitter piece_blitters_shift0 gives it (its clipping
; jumps set to draw every column, as flat_step_clip sets them for a step clear
; of the edges), in planet 0's surface colour (four times the size).
;
; The terrain pieces' graphics as they came on the tape: the nine stored shapes
; unshifted (to the end of slope_3_gfx), each after a header, and the room
; after them for their copies shifted by 2, 4 and 6 pixels, which
; build_shifted_pieces makes at the start (from slope_2_shifted). The tables at
; piece_blitters_shift2 point into them. All are drawn bottom row first by the
; POP blitters, and stored as the blitters read them: each pair of rows left to
; right, then right to left. Every graphic holds three variants of its piece
; one above the other.
;
; This one: a two-byte header for shift_flat_piece, then the flat piece, three
; bytes a row, 28 rows (84 bytes). The ground is the planet's checkerboard ($55
; and $AA on alternate rows) with the surface's bumps at the top.
graphics:                 ; Jetrun: where the step graphics start, after two
  DEFS 2                  ; bytes an interrupt's push may land on when SP has
                          ; just been pointed at the first graphic
flat_piece_gfx:
  DEFB $06,$02            ; Header: pairs of rows to make shifted (6), width in
                          ; bytes less one (2)
cy_E583:
  DEFB $55,$55,$55        ; The flat piece, 28 rows of 3 bytes
  DEFB $AA,$AA,$AA        ;
  DEFB $7E,$FD,$77        ;
  DEFB $C1,$63,$B5        ;
  DEFB $55,$55,$55        ;
  DEFB $AA,$AE,$EB        ;
  DEFB $F7,$FF,$77        ;
  DEFB $C1,$E1,$8C        ;
  DEFB $55,$55,$55        ;
  DEFB $AA,$BE,$EA        ;
  DEFB $FD,$7F,$77        ;
  DEFB $C1,$C3,$87        ;
  DEFB $00,$F5,$55        ;
  DEFB $AA,$7A,$00        ;
  DEFB $00,$0F,$77        ;
  DEFB $C0,$01,$00        ;
  DEFB $D5,$55,$55        ;
  DEFB $AA,$BA,$EA        ;
  DEFB $7F,$7F,$77        ;
  DEFB $C1,$E3,$1D        ;
  DEFB $55,$57,$00        ;
  DEFB $00,$FC,$AA        ;
  DEFB $77,$E0,$00        ;
  DEFB $00,$C0,$C1        ;
  DEFB $55,$55,$55        ;
  DEFB $AB,$EA,$AA        ;
  DEFB $77,$FF,$FC        ;
  DEFB $78,$DC,$C1        ;

; Landscape graphics: the flat ceiling (direction 7)
;
; Its three variants and its four end caps, each drawn as one step of direction
; 7 at shift 0 by the blitter piece_blitters_shift0 gives it (its clipping
; jumps set to draw every column, as flat_step_clip sets them for a step clear
; of the edges), in planet 0's surface colour (four times the size).
;
; A two-byte header for shift_flat_piece as at flat_piece_gfx, then 28 rows of
; 3 bytes.
flat_piece_two_gfx:
  DEFB $06,$02            ; Header: pairs of rows to make shifted (6), width
                          ; less one (2)
cy_E5D9:
  DEFB $F8,$00,$0F        ; The piece, 28 rows of 3 bytes
  DEFB $FA,$01,$BE        ;
  DEFB $55,$87,$55        ;
  DEFB $AA,$FE,$AA        ;
  DEFB $07,$FE,$0F        ;
  DEFB $FA,$AB,$FF        ;
  DEFB $55,$55,$55        ;
  DEFB $AA,$AA,$AA        ;
  DEFB $C0,$00,$0F        ;
  DEFB $FA,$F9,$F0        ;
  DEFB $5F,$DF,$55        ;
  DEFB $AA,$AA,$AA        ;
  DEFB $00,$00,$0F        ;
  DEFB $FA,$0F,$00        ;
  DEFB $00,$7D,$55        ;
  DEFB $AA,$EA,$00        ;
  DEFB $3F,$00,$0F        ;
  DEFB $FA,$F9,$6B        ;
  DEFB $D5,$5F,$55        ;
  DEFB $AA,$AA,$AA        ;
  DEFB $0F,$80,$00        ;
  DEFB $00,$F0,$FA        ;
  DEFB $55,$5C,$00        ;
  DEFB $00,$AF,$AA        ;
  DEFB $0F,$87,$C0        ;
  DEFB $FC,$FE,$FA        ;
  DEFB $55,$55,$57        ;
  DEFB $AB,$AA,$AA        ;

; Landscape graphics: direction 9, direction 2 upside down, one byte wide
;
; Its three variants, each drawn as one step of direction 9 at shift 0 by the
; blitter piece_blitters_shift0 gives it, in planet 0's surface colour (four
; times the size).
;
; A three-byte header for read_piece_header (rows in each variant, halved and
; rounded up: 5; pairs of rows to make: 17; width in bytes: 1), then three
; variants of 9 rows, one byte a row (27 bytes). Direction 12 is this graphic
; one byte (one row) on, mirrored. The shifting at the start reads on past the
; end into the next graphic, for a fourth, partial variant that is never drawn.
slope_9_gfx:
  DEFB $05,$11,$01        ; Header
cy_E630:
  DEFB $80,$E0,$78,$BC,$56,$AA,$57,$AB,$55 ; Three variants of 9 rows
  DEFB $80,$80,$C0,$C0,$60,$B0,$5B,$AF,$57 ;
  DEFB $80,$80,$D8,$FC,$54,$AE,$57,$AB,$57 ;

; Landscape graphics: direction 2, a slope one byte wide, 9 rows
;
; Its three variants, each drawn as one step of direction 2 at shift 0 by the
; blitter piece_blitters_shift0 gives it, in planet 0's surface colour (four
; times the size).
;
; Header (5, 17, 1: see slope_9_gfx), then three variants of 9 rows of one
; byte. Direction 5 is this graphic one byte on, mirrored.
slope_2_gfx:
  DEFB $05,$11,$01        ; Header
cy_E64E:
  DEFB $D5,$EA,$55,$6A,$3D,$1E,$07,$01,$01 ; Three variants of 9 rows
  DEFB $F5,$DA,$0D,$06,$03,$03,$01,$01,$01 ;
  DEFB $D5,$EA,$75,$2A,$3F,$1B,$01,$01,$01 ;

; Landscape graphics: direction 8, direction 1 upside down, two bytes wide
;
; Its three variants, each drawn as one step of direction 8 at shift 0 by the
; blitter piece_blitters_shift0 gives it, in planet 0's surface colour (four
; times the size).
;
; Header (5, 17, 2), then three variants of 9 rows of two bytes (54 bytes).
; Direction 11 is this graphic one row (two bytes) on, mirrored.
slope_8_gfx:
  DEFB $05,$11,$02        ; Header
cy_E66C:
  DEFB $C0,$00,$00,$F0,$5F,$00 ; Three variants of 9 rows (a pair of rows and a
  DEFB $C0,$AB,$55,$70,$B8,$AA ; half a line)
  DEFB $55,$5E,$AB,$AA,$55,$53 ;
  DEFB $C0,$00,$00,$FC,$5E,$00 ;
  DEFB $00,$AB,$55,$80,$C0,$AA ;
  DEFB $55,$78,$AF,$AA,$55,$57 ;
  DEFB $80,$00,$00,$E0,$71,$00 ;
  DEFB $88,$BB,$5F,$D8,$FC,$AE ;
  DEFB $55,$F6,$AB,$AA,$55,$55 ;

; Landscape graphics: direction 1, a slope two bytes wide, 9 rows
;
; Its three variants, each drawn as one step of direction 1 at shift 0 by the
; blitter piece_blitters_shift0 gives it, in planet 0's surface colour (four
; times the size).
;
; Header (5, 17, 2), then three variants of 9 rows of two bytes, and the extra
; row the mirrored direction 4 reads (it starts one row on).
slope_1_gfx:
  DEFB $05,$11,$02        ; Header
cy_E6A5:
  DEFB $D5,$55,$AA,$7A,$1D,$55 ; Three variants of 9 rows, and a row more
  DEFB $AA,$0E,$03,$D5,$FA,$00 ;
  DEFB $00,$0F,$03,$00,$00,$01 ;
  DEFB $F5,$55,$AA,$DE,$03,$55 ;
  DEFB $AA,$01,$00,$D5,$7A,$00 ;
  DEFB $00,$3F,$03,$00,$00,$01 ;
  DEFB $D5,$55,$AA,$6F,$3F,$75 ;
  DEFB $FA,$1B,$11,$DD,$1E,$00 ;
  DEFB $00,$07,$01,$00,$00,$01 ;
  DEFB $00,$00                 ;

; Landscape graphics: direction 10, direction 3 upside down
;
; Its three variants, each drawn as one step of direction 10 at shift 0 by the
; blitter piece_blitters_shift0 gives it, in planet 0's surface colour (four
; times the size).
;
; Header (9, 29, 1: variants of 17 rows), then three variants of 17 rows of one
; byte (51 bytes). Direction 13 is this graphic one byte on, mirrored.
slope_10_gfx:
  DEFB $09,$1D,$01        ; Header
cy_E6E0:
  DEFB $80,$80,$80,$C0,$40,$C0,$40,$E0,$70,$B0,$50,$B8,$58 ; Three variants of
  DEFB $AE,$57,$AB,$55,$80,$80,$80,$E0,$70,$B4,$5C,$AE,$56 ; 17 rows
  DEFB $AA,$57,$AB,$55,$AB,$55,$AB,$55,$80,$80,$C0,$E0,$60 ;
  DEFB $A0,$50,$B8,$58,$A8,$58,$AA,$56,$AB,$55,$AB,$55     ;

; Landscape graphics: direction 3, a steep slope, one byte wide, 17 rows
;
; Its three variants, each drawn as one step of direction 3 at shift 0 by the
; blitter piece_blitters_shift0 gives it, in planet 0's surface colour (four
; times the size).
;
; Header (9, 29, 1), then three variants of 17 rows of one byte, and one byte
; more for the mirrored direction 6.
slope_3_gfx:
  DEFB $09,$1D,$01        ; Header
cy_E716:
  DEFB $D5,$EA,$75,$1A,$1D,$0A,$0D,$0E,$07,$02,$03,$02,$03 ; Three variants of
  DEFB $01,$01,$01,$01,$D5,$AA,$D5,$AA,$D5,$EA,$55,$6A,$75 ; 17 rows and a byte
  DEFB $3A,$2D,$0E,$07,$01,$01,$01,$01,$D5,$AA,$D5,$6A,$55 ; more
  DEFB $1A,$15,$1A,$1D,$0A,$05,$06,$03,$03,$01,$01,$01,$00 ;

; Landscape graphics: direction 2 shifted by 2, 4 and 6 pixels
;
; As the game's start-up makes them (run in the simulator): the variants at
; shifts 2, 4 and 6, a row each, each drawn as one step of direction 2 by the
; blitter piece_blitters_shift2, piece_blitters_shift4 or piece_blitters_shift6
; gives it, in planet 0's surface colour (four times the size).
;
; Made at the start by shift_slope_piece from slope_2_gfx (zeros on the tape):
; three copies of 62 bytes, one after another from here, each two bytes wide
; and 31 rows (three variants of 9 and a partial fourth). The mirrored
; direction 5 uses them two bytes on, at the opposite shift.
slope_2_shifted:
  DEFB $35,$55,$AA,$3A,$15,$55,$AA,$1A
  DEFB $0F,$55,$AA,$07,$01,$D5,$6A,$00
  DEFB $00,$55,$3D,$55,$AA,$36,$03,$55
  DEFB $AA,$01,$00,$D5,$EA,$00,$00,$55
  DEFB $6A,$00,$00,$55,$35,$55,$AA,$3A
  DEFB $1D,$55,$AA,$0A,$0F,$D5,$EA,$06
  DEFB $00,$55,$6A,$00,$00,$55,$01,$55
cy_E782:
  DEFB $6A,$04,$00,$95,$2A,$30,$0D,$55
cy_E78A:
  DEFB $AA,$0E,$05,$55,$AA,$06,$03,$D5
  DEFB $EA,$01,$00,$75,$1A,$00,$00,$15
  DEFB $0F,$55,$AA,$0D,$00,$D5,$6A,$00
  DEFB $00,$35,$3A,$00,$00,$15,$1A,$00
  DEFB $00,$15,$0D,$55,$AA,$0E,$07,$55
  DEFB $AA,$02,$03,$F5,$BA,$01,$00,$15
  DEFB $1A,$00,$00,$15,$00,$55,$1A,$01
cy_E7C2:
  DEFB $00,$25,$0A,$0C,$03,$55,$AA,$03
  DEFB $01,$55,$AA,$01,$00,$F5,$7A,$00
  DEFB $00,$1D,$06,$00,$00,$05,$03,$D5
  DEFB $6A,$03,$00,$35,$1A,$00,$00,$0D
  DEFB $0E,$00,$00,$05,$06,$00,$00,$05
  DEFB $03,$55,$AA,$03,$01,$D5,$AA,$00
  DEFB $00,$FD,$6E,$00,$00,$05,$06,$00
  DEFB $00,$05,$00,$15,$46,$00,$00,$09
  DEFB $02,$03

; Landscape graphics: direction 1 shifted by 2, 4 and 6 pixels
;
; As the game's start-up makes them (run in the simulator): the variants at
; shifts 2, 4 and 6, a row each, each drawn as one step of direction 1 by the
; blitter piece_blitters_shift2, piece_blitters_shift4 or piece_blitters_shift6
; gives it, in planet 0's surface colour (four times the size).
;
; Made at the start by shift_slope_piece from slope_1_gfx: three copies of 93
; bytes (three bytes wide, 31 rows) one after another from here, and three
; spare bytes the mirrored direction 4 reads.
slope_1_shifted:
  DEFB $35,$55,$55,$AA,$AA,$1E,$07,$55
  DEFB $55,$AA,$AA,$03,$00,$F5,$55,$AA
  DEFB $3E,$00,$00,$03,$D5,$EA,$00,$00
  DEFB $00,$00,$55,$3D,$55,$55,$AA,$AA
  DEFB $37,$00,$D5,$55,$AA,$6A,$00,$00
  DEFB $35,$55,$AA,$1E,$00,$00,$0F,$D5
  DEFB $EA,$00,$00,$00,$00,$55,$35,$55
  DEFB $55,$AA,$EA,$1B,$0F,$DD,$55,$AA
  DEFB $FE,$06,$04,$77,$55,$AA,$07,$00
  DEFB $00,$01,$D5,$6A,$00,$00,$00,$00
  DEFB $55,$00,$00,$15,$6A,$42,$07,$00
cy_E85C:
  DEFB $60,$15,$2A,$20,$20,$0D,$55,$55
cy_E864:
  DEFB $AA,$AA,$07,$01,$D5,$55,$AA,$EA
  DEFB $00,$00,$3D,$55,$AA,$0F,$00,$00
  DEFB $00,$F5,$3A,$00,$00,$00,$00,$15
  DEFB $0F,$55,$55,$AA,$EA,$0D,$00,$35
  DEFB $55,$AA,$1A,$00,$00,$0D,$55,$AA
  DEFB $07,$00,$00,$03,$F5,$3A,$00,$00
  DEFB $00,$00,$15,$0D,$55,$55,$AA,$FA
  DEFB $06,$03,$F7,$55,$AA,$BF,$01,$01
  DEFB $1D,$D5,$EA,$01,$00,$00,$00,$75
  DEFB $1A,$00,$00,$00,$00,$15,$00,$00
  DEFB $05,$9A,$D0,$01,$00,$18,$05,$0A
cy_E8BC:
  DEFB $08,$08,$03,$55,$55,$AA,$EA,$01
  DEFB $00,$75,$55,$AA,$3A,$00,$00,$0F
  DEFB $55,$EA,$03,$00,$00,$00,$3D,$0E
  DEFB $00,$00,$00,$00,$05,$03,$D5,$55
  DEFB $AA,$7A,$03,$00,$0D,$55,$AA,$06
  DEFB $00,$00,$03,$55,$EA,$01,$00,$00
  DEFB $00,$FD,$0E,$00,$00,$00,$00,$05
  DEFB $03,$55,$55,$AA,$BE,$01,$00,$FD
  DEFB $D5,$EA,$6F,$00,$00,$47,$75,$7A
  DEFB $00,$00,$00,$00,$1D,$06,$00,$00
  DEFB $00,$00,$05,$00,$00,$01,$26,$74
  DEFB $00,$00,$06,$01,$02,$02,$02,$00
  DEFB $00,$00

; Landscape graphics: direction 3 shifted by 2, 4 and 6 pixels
;
; As the game's start-up makes them (run in the simulator): the variants at
; shifts 2, 4 and 6, a row each, each drawn as one step of direction 3 by the
; blitter piece_blitters_shift2, piece_blitters_shift4 or piece_blitters_shift6
; gives it, in planet 0's surface colour (four times the size).
;
; Made at the start by shift_slope_piece from slope_3_gfx: three copies of 110
; bytes (two bytes wide, 55 rows: three variants of 17 and a partial fourth)
; one after another from here.
slope_3_shifted:
  DEFB $35,$55,$AA,$3A,$1D,$55,$AA,$06
  DEFB $07,$55,$AA,$02,$03,$55,$AA,$03
  DEFB $01,$D5,$AA,$00,$00,$D5,$AA,$00
  DEFB $00,$D5,$6A,$00,$00,$55,$6A,$00
  DEFB $00,$55,$35,$55,$AA,$2A,$35,$55
  DEFB $AA,$2A,$35,$55,$AA,$3A,$15,$55
  DEFB $AA,$1A,$1D,$55,$AA,$0E,$0B,$55
  DEFB $AA,$03,$01,$D5,$6A,$00,$00,$55
  DEFB $6A,$00,$00,$55,$35,$55,$AA,$2A
  DEFB $35,$55,$AA,$1A,$15,$55,$AA,$06
  DEFB $05,$55,$AA,$06,$07,$55,$AA,$02
  DEFB $01,$55,$AA,$01,$00,$D5,$EA,$00
  DEFB $00,$55,$6A,$00,$00,$55,$00,$15
cy_E986:
  DEFB $6A,$0D,$15,$55,$AA,$2A,$0D,$55
cy_E98E:
  DEFB $AA,$0E,$07,$55,$AA,$01,$01,$D5
  DEFB $AA,$00,$00,$D5,$EA,$00,$00,$75
  DEFB $2A,$00,$00,$35,$2A,$00,$00,$35
  DEFB $1A,$00,$00,$15,$1A,$00,$00,$15
  DEFB $0D,$55,$AA,$0A,$0D,$55,$AA,$0A
  DEFB $0D,$55,$AA,$0E,$05,$55,$AA,$06
  DEFB $07,$55,$AA,$03,$02,$D5,$EA,$00
  DEFB $00,$75,$1A,$00,$00,$15,$1A,$00
  DEFB $00,$15,$0D,$55,$AA,$0A,$0D,$55
  DEFB $AA,$06,$05,$55,$AA,$01,$01,$55
  DEFB $AA,$01,$01,$D5,$AA,$00,$00,$55
  DEFB $6A,$00,$00,$35,$3A,$00,$00,$15
  DEFB $1A,$00,$00,$15,$00,$05,$5A,$03
cy_E9F6:
  DEFB $05,$55,$AA,$0A,$03,$55,$AA,$03
  DEFB $01,$D5,$6A,$00,$00,$75,$2A,$00
  DEFB $00,$35,$3A,$00,$00,$1D,$0A,$00
  DEFB $00,$0D,$0A,$00,$00,$0D,$06,$00
  DEFB $00,$05,$06,$00,$00,$05,$03,$55
  DEFB $AA,$02,$03,$55,$AA,$02,$03,$55
  DEFB $AA,$03,$01,$55,$AA,$01,$01,$D5
  DEFB $EA,$00,$00,$B5,$3A,$00,$00,$1D
  DEFB $06,$00,$00,$05,$06,$00,$00,$05
  DEFB $03,$55,$AA,$02,$03,$55,$AA,$01
  DEFB $01,$55,$6A,$00,$00,$55,$6A,$00
  DEFB $00,$75,$2A,$00,$00,$15,$1A,$00
  DEFB $00,$0D,$0E,$00,$00,$05,$06,$00
  DEFB $00,$05,$00,$01,$D6,$00,$01,$55
  DEFB $AA,$02

; Landscape graphics: the flat piece (direction 0) shifted by 2, 4 and 6 pixels
;
; As the game's start-up makes them (run in the simulator): the variants and
; its four end caps at shifts 2, 4 and 6, a row each, each drawn as one step of
; direction 0 by the blitter piece_blitters_shift2, piece_blitters_shift4 or
; piece_blitters_shift6 gives it (its clipping jumps set to draw every column,
; as flat_step_clip sets them for a step clear of the edges), in planet 0's
; surface colour (four times the size).
;
; Three copies of 84 bytes (three bytes wide, 28 rows) one after another from
; here. Only the first 12 rows of each are made at the start (shift_flat_piece,
; by rotating the rows of flat_piece_gfx); the other 16 rows of each came on
; the tape already shifted.
flat_piece_shifted:
  DEFB $55,$55,$55,$AA,$AA,$AA,$DF,$BF
  DEFB $5D,$F0,$58,$6D,$55,$55,$55,$AA
  DEFB $EB,$BA,$FD,$FF,$DD,$70,$38,$63
  DEFB $55,$55,$55,$AA,$AF,$BA,$FF,$5F
  DEFB $DD,$F0,$F0,$61,$C0,$3D,$55,$AA
  DEFB $1E,$80,$00,$03,$DD,$70,$00,$00
  DEFB $35,$55,$55,$AA,$AE,$3A,$1F,$DF
  DEFB $DD,$F0,$78,$07,$55,$55,$C0,$00
  DEFB $AF,$AA,$DD,$F8,$00,$00,$70,$70
  DEFB $55,$55,$55,$AA,$BA,$AA,$DD,$FF
cy_EAB8:
  DEFB $FF,$1E,$77,$70,$55,$55,$55,$AA
  DEFB $AA,$AA,$77,$EF,$D7,$3C,$56,$1B
  DEFB $55,$55,$55,$EA,$BA,$AE,$7F,$7F
  DEFB $F7,$1C,$CE,$18,$55,$55,$55,$EA
  DEFB $AB,$AE,$7F,$D7,$F7,$3C,$7C,$18
  DEFB $70,$0F,$55,$AA,$07,$E0,$C0,$00
  DEFB $F7,$1C,$00,$00,$0D,$55,$55,$AA
  DEFB $AB,$0E,$07,$F7,$F7,$3C,$DE,$01
  DEFB $55,$55,$70,$C0,$AB,$AA,$77,$7E
  DEFB $00,$00,$1C,$1C,$55,$55,$55,$AA
  DEFB $AE,$AA,$77,$7F,$FF,$C7,$1D,$1C
cy_EB10:
  DEFB $55,$55,$55,$AA,$AA,$AA,$DD,$FB
  DEFB $F5,$8F,$D5,$06,$55,$55,$55,$BA
  DEFB $AE,$AB,$DF,$DF,$FD,$87,$33,$06
  DEFB $55,$55,$55,$FA,$AA,$AB,$DF,$F5
  DEFB $FD,$0F,$1F,$06,$5C,$03,$D5,$EA
  DEFB $01,$B8,$70,$00,$3D,$07,$00,$C0
  DEFB $03,$55,$55,$EA,$AA,$03,$01,$FD
  DEFB $FD,$8F,$77,$00,$55,$55,$5C,$F0
  DEFB $AA,$AA,$DD,$DF,$80,$00,$07,$07
  DEFB $55,$55,$55,$AA,$AB,$AA,$DD,$DF
  DEFB $FF,$71,$07,$07

; Landscape graphics: the flat ceiling (direction 7) shifted by 2, 4 and 6
; pixels
;
; As the game's start-up makes them (run in the simulator): the variants and
; its four end caps at shifts 2, 4 and 6, a row each, each drawn as one step of
; direction 7 by the blitter piece_blitters_shift2, piece_blitters_shift4 or
; piece_blitters_shift6 gives it (its clipping jumps set to draw every column,
; as flat_step_clip sets them for a step clear of the edges), in planet 0's
; surface colour (four times the size).
;
; As flat_piece_shifted, from flat_piece_two_gfx: three copies one after
; another, their first 12 rows made at the start.
flat_piece_two_shifted:
  DEFB $FE,$00,$03,$7E,$80,$AF,$55,$61
  DEFB $D5,$AA,$BF,$AA,$C1,$FF,$83,$FE
  DEFB $EA,$BF,$55,$55,$55,$AA,$AA,$AA
  DEFB $F0,$00,$03,$7E,$3E,$BC,$57,$F7
  DEFB $D5,$AA,$AA,$AA,$00,$00,$03,$FE
  DEFB $03,$00,$80,$1F,$55,$AA,$3A,$C0
  DEFB $0F,$C0,$03,$7E,$FE,$1A,$35,$57
  DEFB $D5,$AA,$AA,$2A,$C3,$E0,$00,$00
  DEFB $BC,$BE,$55,$57,$00,$C0,$AB,$AA
  DEFB $C3,$E1,$F0,$BF,$BF,$BE,$55,$55
cy_EBB4:
  DEFB $55,$AA,$AA,$AA,$FF,$80,$00,$1F
  DEFB $E0,$AB,$55,$58,$75,$EA,$AF,$AA
  DEFB $F0,$7F,$E0,$BF,$FA,$AF,$55,$55
  DEFB $55,$AA,$AA,$AA,$FC,$00,$00,$9F
  DEFB $0F,$AF,$55,$FD,$F5,$AA,$AA,$AA
  DEFB $00,$00,$00,$FF,$00,$80,$60,$07
  DEFB $D5,$AA,$0E,$B0,$03,$F0,$00,$9F
  DEFB $BF,$06,$0D,$55,$F5,$AA,$AA,$0A
  DEFB $F0,$F8,$00,$00,$AF,$AF,$55,$55
  DEFB $C0,$F0,$AA,$AA,$F0,$F8,$7C,$EF
  DEFB $AF,$AF,$55,$55,$55,$AA,$AA,$AA
cy_EC0C:
  DEFB $3F,$E0,$00,$07,$F8,$EA,$55,$56
  DEFB $1D,$FA,$AB,$AA,$3C,$1F,$F8,$AF
  DEFB $FE,$EB,$55,$55,$55,$AA,$AA,$AA
  DEFB $3F,$00,$00,$E7,$C3,$EB,$55,$7F
  DEFB $7D,$AA,$AA,$AA,$40,$00,$00,$3F
  DEFB $00,$A0,$58,$01,$FA,$AA,$03,$AC
  DEFB $00,$FC,$00,$E7,$AF,$01,$03,$55
  DEFB $7D,$AA,$AA,$02,$3C,$3E,$00,$C0
  DEFB $EB,$EB,$55,$55,$70,$BC,$AA,$AA
  DEFB $3C,$3E,$1F,$FB,$EB,$EB,$55,$55
  DEFB $55,$AA,$AA,$AA

; Landscape graphics: the wall (direction 14)
;
; Its three variants, each drawn as one step of direction 14 at shift 0 by the
; blitter piece_blitters_shift0 gives it, in planet 0's surface colour (four
; times the size).
;
; Header (9, 29, 1), then three variants of 17 rows of one byte; the mirrored
; direction 15 reads it one byte on. Its last bytes are overwritten by the
; first shifted copy (wall_shifted) before the shifting reads them, so the
; partial fourth variant it makes is garbage -- harmless, as it is never drawn.
wall_gfx:
  DEFB $09,$1D,$01
cy_EC63:
  DEFB $D5,$AA,$D5,$6A,$75,$3A,$0D,$06,$0D,$3A,$75,$6A,$55
  DEFB $EA,$D5,$AA,$D5,$D5,$EA,$55,$6A,$35,$6A,$55,$EA,$D5
  DEFB $AA,$D5,$6A,$55,$6A,$D5,$AA,$D5,$D5,$EA,$55,$6A,$35
  DEFB $1A,$1D,$1A,$1D,$1A,$35,$2A,$75,$6A,$D5,$AA,$D5

; Landscape graphics: the wall (direction 14) shifted by 2, 4 and 6 pixels
;
; As the game's start-up makes them (run in the simulator): the variants at
; shifts 2, 4 and 6, a row each, each drawn as one step of direction 14 by the
; blitter piece_blitters_shift2, piece_blitters_shift4 or piece_blitters_shift6
; gives it, in planet 0's surface colour (four times the size).
;
; Made at the start by shift_slope_piece from wall_gfx: three copies of 110
; bytes one after another from here.
wall_shifted:
  DEFB $35,$55,$AA,$2A,$35,$55,$AA,$1A
  DEFB $1D,$55,$AA,$0E,$03,$55,$AA,$01
  DEFB $03,$55,$AA,$0E,$1D,$55,$AA,$1A
  DEFB $15,$55,$AA,$3A,$35,$55,$AA,$2A
  DEFB $35,$55,$35,$55,$AA,$3A,$15,$55
  DEFB $AA,$1A,$0D,$55,$AA,$1A,$15,$55
  DEFB $AA,$3A,$35,$55,$AA,$2A,$35,$55
  DEFB $AA,$1A,$15,$55,$AA,$1A,$35,$55
  DEFB $AA,$2A,$35,$55,$35,$55,$AA,$3A
  DEFB $15,$55,$AA,$1A,$0D,$55,$AA,$06
  DEFB $07,$55,$AA,$06,$07,$55,$AA,$06
  DEFB $0D,$55,$AA,$0A,$1D,$55,$AA,$1A
  DEFB $35,$55,$AA,$2A,$35,$55,$0D,$55
cy_ECFE:
  DEFB $6A,$15,$2A,$95,$AA,$0A,$0D,$55
cy_ED06:
  DEFB $AA,$0A,$0D,$55,$AA,$06,$07,$55
  DEFB $AA,$03,$00,$D5,$6A,$00,$00,$D5
  DEFB $AA,$03,$07,$55,$AA,$06,$05,$55
  DEFB $AA,$0E,$0D,$55,$AA,$0A,$0D,$55
  DEFB $0D,$55,$AA,$0E,$05,$55,$AA,$06
  DEFB $03,$55,$AA,$06,$05,$55,$AA,$0E
  DEFB $0D,$55,$AA,$0A,$0D,$55,$AA,$06
  DEFB $05,$55,$AA,$06,$0D,$55,$AA,$0A
  DEFB $0D,$55,$0D,$55,$AA,$0E,$05,$55
  DEFB $AA,$06,$03,$55,$AA,$01,$01,$D5
  DEFB $AA,$01,$01,$D5,$AA,$01,$03,$55
  DEFB $AA,$02,$07,$55,$AA,$06,$0D,$55
  DEFB $AA,$0A,$0D,$55,$03,$55,$5A,$05
cy_ED6E:
  DEFB $0A,$A5,$AA,$02,$03,$55,$AA,$02
  DEFB $03,$55,$AA,$01,$01,$D5,$EA,$00
  DEFB $00,$35,$1A,$00,$00,$35,$EA,$00
  DEFB $01,$D5,$AA,$01,$01,$55,$AA,$03
  DEFB $03,$55,$AA,$02,$03,$55,$03,$55
  DEFB $AA,$03,$01,$55,$AA,$01,$00,$D5
  DEFB $AA,$01,$01,$55,$AA,$03,$03,$55
  DEFB $AA,$02,$03,$55,$AA,$01,$01,$55
  DEFB $AA,$01,$03,$55,$AA,$02,$03,$55
  DEFB $03,$55,$AA,$03,$01,$55,$AA,$01
  DEFB $00,$D5,$6A,$00,$00,$75,$6A,$00
  DEFB $00,$75,$6A,$00,$00,$D5,$AA,$00
  DEFB $01,$D5,$AA,$01,$03,$55,$AA,$02
  DEFB $03,$55,$00,$D5,$56,$01,$02,$A9
  DEFB $AA,$00

; Landscape graphics: direction 9 shifted by 2, 4 and 6 pixels
;
; As the game's start-up makes them (run in the simulator): the variants at
; shifts 2, 4 and 6, a row each, each drawn as one step of direction 9 by the
; blitter piece_blitters_shift2, piece_blitters_shift4 or piece_blitters_shift6
; gives it, in planet 0's surface colour (four times the size).
;
; Made at the start by shift_slope_piece from slope_9_gfx, with the
; checkerboard on the left: three copies of 62 bytes one after another from
; here.
slope_9_shifted:
  DEFB $60,$00,$00,$B8,$5E,$00,$00,$AF
  DEFB $55,$80,$80,$AA,$55,$C0,$C0,$AA
  DEFB $55,$40,$60,$00,$00,$A0,$70,$00
  DEFB $00,$B0,$58,$00,$00,$AC,$56,$C0
  DEFB $C0,$AB,$55,$C0,$60,$00,$00,$A0
  DEFB $76,$00,$00,$BF,$55,$00,$80,$AB
  DEFB $55,$C0,$C0,$AA,$55,$C0,$41,$40
cy_EE18:
  DEFB $40,$84,$40,$40,$40,$B5,$58,$00
cy_EE20:
  DEFB $00,$AE,$57,$80,$C0,$AB,$55,$60
  DEFB $A0,$AA,$55,$70,$B0,$AA,$55,$50
  DEFB $58,$00,$00,$A8,$5C,$00,$00,$AC
  DEFB $56,$00,$00,$AB,$55,$B0,$F0,$AA
  DEFB $55,$70,$58,$00,$00,$A8,$5D,$80
  DEFB $C0,$AF,$55,$40,$E0,$AA,$55,$70
  DEFB $B0,$AA,$55,$70,$50,$50,$10,$A1
cy_EE58:
  DEFB $50,$10,$50,$AD,$56,$00,$80,$AB
  DEFB $55,$E0,$F0,$AA,$55,$58,$A8,$AA
  DEFB $55,$5C,$AC,$AA,$55,$54,$56,$00
  DEFB $00,$AA,$57,$00,$00,$AB,$55,$80
  DEFB $C0,$AA,$55,$6C,$BC,$AA,$55,$5C
  DEFB $56,$00,$00,$AA,$57,$60,$F0,$AB
  DEFB $55,$50,$B8,$AA,$55,$5C,$AC,$AA
  DEFB $55,$5C,$54,$14,$44,$A8,$54,$04
  DEFB $54,$AB

; Landscape graphics: direction 8 shifted by 2, 4 and 6 pixels
;
; As the game's start-up makes them (run in the simulator): the variants at
; shifts 2, 4 and 6, a row each, each drawn as one step of direction 8 by the
; blitter piece_blitters_shift2, piece_blitters_shift4 or piece_blitters_shift6
; gives it, in planet 0's surface colour (four times the size).
;
; Made at the start by shift_slope_piece from slope_8_gfx: three copies of 93
; bytes one after another from here.
slope_8_shifted:
  DEFB $70,$00,$00,$00,$00,$BC,$57,$C0
  DEFB $00,$00,$F0,$AA,$55,$5C,$00,$00
  DEFB $AE,$AA,$55,$57,$80,$C0,$AA,$AA
  DEFB $55,$54,$C0,$70,$00,$00,$00,$00
  DEFB $BF,$57,$80,$00,$00,$C0,$AA,$55
  DEFB $60,$00,$00,$B0,$AA,$55,$5E,$00
  DEFB $C0,$AB,$AA,$55,$55,$C0,$60,$00
  DEFB $00,$00,$00,$B8,$5C,$40,$00,$00
  DEFB $E2,$AE,$57,$F6,$00,$00,$BF,$AB
  DEFB $55,$7D,$80,$C0,$AA,$AA,$55,$55
  DEFB $40,$41,$44,$40,$80,$40,$B5,$55
cy_EEF2:
  DEFB $6A,$80,$80,$5E,$87,$5C,$00,$00
cy_EEFA:
  DEFB $00,$00,$AF,$55,$F0,$00,$00,$BC
  DEFB $AA,$55,$57,$00,$80,$AB,$AA,$55
  DEFB $55,$E0,$B0,$AA,$AA,$55,$55,$30
  DEFB $5C,$00,$00,$00,$C0,$AF,$55,$E0
  DEFB $00,$00,$B0,$AA,$55,$58,$00,$00
  DEFB $AC,$AA,$55,$57,$80,$F0,$AA,$AA
  DEFB $55,$55,$70,$58,$00,$00,$00,$00
  DEFB $AE,$57,$10,$00,$80,$B8,$AB,$55
  DEFB $FD,$80,$C0,$EF,$AA,$55,$5F,$60
  DEFB $B0,$AA,$AA,$55,$55,$50,$50,$51
  DEFB $10,$20,$50,$AD,$55,$5A,$A0,$A0
cy_EF52:
  DEFB $D7,$A1,$57,$00,$00,$00,$C0,$AB
  DEFB $55,$7C,$00,$00,$AF,$AA,$55,$55
  DEFB $C0,$E0,$AA,$AA,$55,$55,$78,$AC
  DEFB $AA,$AA,$55,$55,$4C,$57,$00,$00
  DEFB $00,$F0,$AB,$55,$78,$00,$00,$AC
  DEFB $AA,$55,$56,$00,$00,$AB,$AA,$55
  DEFB $55,$E0,$BC,$AA,$AA,$55,$55,$5C
  DEFB $56,$00,$00,$00,$80,$AB,$55,$C4
  DEFB $00,$20,$EE,$AA,$55,$7F,$60,$F0
  DEFB $BB,$AA,$55,$57,$D8,$AC,$AA,$AA
  DEFB $55,$55,$54,$54,$14,$44,$08,$54
  DEFB $AB,$55,$56,$A8,$E8,$75,$A8

; Landscape graphics: direction 10 shifted by 2, 4 and 6 pixels
;
; As the game's start-up makes them (run in the simulator): the variants at
; shifts 2, 4 and 6, a row each, each drawn as one step of direction 10 by the
; blitter piece_blitters_shift2, piece_blitters_shift4 or piece_blitters_shift6
; gives it, in planet 0's surface colour (four times the size).
;
; Made at the start by shift_slope_piece from slope_10_gfx: three copies of 110
; bytes one after another from here. The mirrored direction 13 reads two bytes
; past the end.
slope_10_shifted:
  DEFB $60,$00,$00,$A0,$60,$00,$00,$B0
  DEFB $50,$00,$00,$B0,$50,$00,$00,$B8
  DEFB $5C,$00,$00,$AC,$54,$00,$00,$AE
  DEFB $56,$00,$80,$AB,$55,$C0,$C0,$AA
  DEFB $55,$40,$60,$00,$00,$A0,$60,$00
  DEFB $00,$B8,$5C,$00,$00,$AD,$57,$00
  DEFB $80,$AB,$55,$80,$80,$AA,$55,$C0
  DEFB $C0,$AA,$55,$40,$C0,$AA,$55,$40
  DEFB $C0,$AA,$55,$40,$60,$00,$00,$A0
  DEFB $70,$00,$00,$B8,$58,$00,$00,$A8
  DEFB $54,$00,$00,$AE,$56,$00,$00,$AA
  DEFB $56,$00,$80,$AA,$55,$80,$C0,$AA
  DEFB $55,$40,$C0,$AA,$55,$40,$42,$40
cy_F019:
  DEFB $40,$87,$40,$40,$40,$B5,$58,$00
cy_F021:
  DEFB $00,$A8,$58,$00,$00,$AC,$54,$00
  DEFB $00,$AC,$54,$00,$00,$AE,$57,$00
  DEFB $00,$AB,$55,$00,$80,$AB,$55,$80
  DEFB $E0,$AA,$55,$70,$B0,$AA,$55,$50
  DEFB $58,$00,$00,$A8,$58,$00,$00,$AE
  DEFB $57,$00,$40,$AB,$55,$C0,$E0,$AA
  DEFB $55,$60,$A0,$AA,$55,$70,$B0,$AA
  DEFB $55,$50,$B0,$AA,$55,$50,$B0,$AA
  DEFB $55,$50,$58,$00,$00,$A8,$5C,$00
  DEFB $00,$AE,$56,$00,$00,$AA,$55,$00
  DEFB $80,$AB,$55,$80,$80,$AA,$55,$80
  DEFB $A0,$AA,$55,$60,$B0,$AA,$55,$50
  DEFB $B0,$AA,$55,$50,$50,$90,$D0,$A1
cy_F089:
  DEFB $50,$10,$50,$AD,$56,$00,$00,$AA
  DEFB $56,$00,$00,$AB,$55,$00,$00,$AB
  DEFB $55,$00,$80,$AB,$55,$C0,$C0,$AA
  DEFB $55,$40,$E0,$AA,$55,$60,$B8,$AA
  DEFB $55,$5C,$AC,$AA,$55,$54,$56,$00
  DEFB $00,$AA,$56,$00,$80,$AB,$55,$C0
  DEFB $D0,$AA,$55,$70,$B8,$AA,$55,$58
  DEFB $A8,$AA,$55,$5C,$AC,$AA,$55,$54
  DEFB $AC,$AA,$55,$54,$AC,$AA,$55,$54
  DEFB $56,$00,$00,$AA,$57,$00,$80,$AB
  DEFB $55,$80,$80,$AA,$55,$40,$E0,$AA
  DEFB $55,$60,$A0,$AA,$55,$60,$A8,$AA
  DEFB $55,$58,$AC,$AA,$55,$54,$AC,$AA
  DEFB $55,$54,$54,$24,$74,$A8,$54,$04
  DEFB $54,$AB


graphics_end:             ; Jetrun: and end. SP points in here while a
                          ; blitter runs (jetrun.s's isr minds that).

; ---------------------------------------------------------------------------
; The renderer's working variables. Cyberun kept these at $5B80-$5C3D; they
; are in its order, since some are read and written in pairs.

; The four on-screen pages' collision-box lists, as draw_landscape records
; them: a count, then up to seven boxes of five bytes. (The view's page's was
; Cyberun's loader_entry, written over its loader.)
ground_cell_top_left:
  DEFS 37
ground_cell_bottom_left:
  DEFS 37
ground_cell_top_right:
  DEFS 37
ground_cell_bottom_right:
  DEFS 37

touch_depth:
  DEFB $00,$00
scratch_count:
  DEFB $00
ground_cell:
  DEFB $00
row_count:
  DEFB $00,$00
pieces_left:
  DEFB $00,$00
piece_steps:
  DEFB $00,$00
piece_step_y:
  DEFB $00
piece_step_x:
  DEFB $00
tile_upside_down:
  DEFB $00
piece_kept:
  DEFB $00
  DEFB $00,$00,$00,$00    ; Cyberun's sprite variables
piece_x:
  DEFB $00
piece_y:
  DEFB $00
move_across_kept:
  DEFB $00
piece_steps_done:
  DEFB $00
tile_mirrored_left_right:
  DEFB $00
edge_flags:
  DEFB $00
piece_clip:
  DEFB $00
piece_extra_a:
  DEFB $00
piece_extra_b:
  DEFB $00
piece_ceiling:
  DEFB $00
  DEFB $00,$00,$00,$00    ; Cyberun's ship variables
map_row_colour:           ; the upper pages' landscape attribute
  DEFB $00
map_row_colour_next:      ; the lower pages'
  DEFB $00
map_rebuild:
  DEFB $00
record_ground:
  DEFB $00
collision_object:         ; Cyberun's $BA09
  DEFW $0000
saved_speed:              ; Cyberun's $BA8D
  DEFW $0000
landscape_sp:             ; Jetrun: draw_landscape's SP
  DEFW $0000

; The screen helpers the renderer calls, from elsewhere in Cyberun.

; Turn pixel coordinates into an attribute address
;
; Used by the routines at print_string, draw_star_layer, draw_trail,
; fill_attributes and colour_piece.
;
; The attribute that colours the pixel at (x, y): 22528 + 32 * (y / 8) + x / 8.
;
;   L x in pixels
;   H y in pixels
; O:HL The attribute address
pixel_to_attribute:
  PUSH BC
  LD A,L                  ; The column, x divided by 8
  RRC A                   ;
  RRC A                   ;
  RRC A                   ;
  AND $1F                 ;
  LD L,A                  ;
  LD A,H                  ; Bits 3-5 of y become bits 5-7 of the low byte
  RLC A                   ;
  RLC A                   ;
  LD C,A                  ;
  AND $E0                 ;
  OR L                    ;
  LD L,A                  ;
  LD A,C                  ; Bits 6-7 of y become bits 0-1 of the high byte, in
  AND $03                 ; the attribute file
  OR $58                  ;
  LD H,A                  ;
  POP BC
  RET

; Turn pixel coordinates into a screen address
;
; Used by the routines at place_flicker_beam, dissolve_play_area,
; clear_play_area, print_string, set_direct_new, record_screen_address,
; draw_sprite_pair, copy_box_in, load_ore, toggle_carried_part,
; draw_carried_piece, draw_ship_image, draw_trail, side_jet, lift_jet,
; draw_bitmap, update_fuel_gauge, step_screen_address, fill_behind_moving_piece
; and fly_in_step.
;
; The standard Spectrum screen-address calculation from a pixel position: L is
; x (0-255, its low three bits dropped) and H is y (0-191 from the top).
; Everything in the game that draws on the screen uses this.
;
;   L x in pixels
;   H y in pixels
; O:HL The screen byte containing the pixel
pixel_to_screen:
  LD A,L                  ; The column, x divided by 8
  RRC A                   ;
  RRC A                   ;
  RRC A                   ;
  AND $1F                 ;
  LD L,A                  ;
  LD A,H                  ; Bits 3-5 of y become bits 5-7 of the low byte
  RLC A                   ;
  RLC A                   ;
  AND $E0                 ;
  OR L                    ;
  LD L,A                  ;
  LD A,H                  ; Bits 0-2 of y are the pixel line within the cell
  AND $07                 ;
  EX AF,AF'               ;
  LD A,H                  ; Bits 6-7 of y pick the third of the screen; combine
  RRC A                   ; with the pixel line
  RRC A                   ;
  RRC A                   ;
  AND $18                 ;
  OR $40                  ;
  LD H,A                  ;
  EX AF,AF'               ;
  OR H                    ;
  LD H,A                  ;
  RET

; Move HL up one pixel line
;
; Used by the routines at dissolve_play_area, clear_play_area, print_char_rows,
; print_char_double, toggle_carried_part, draw_beam, erase_laser, draw_bitmap,
; draw_frame, draw_fuel_gauge, draw_flat_end_lip, fill_up_past_step,
; fill_row_pair, start_landscape and fill_under_slope.
;
; Moves a screen address one pixel line up the screen: the line above within
; the cell, or the bottom line of the cell above, crossing into the third above
; when the row was the top of a third. Everything in the game draws bottom-up
; -- the graphics are stored bottom row first -- so this, and copies of it
; written inline in the sprite routines, are what step the drawing. About 47
; T-states with the CALL, most of the time.
;
;   HL A screen address
; O:HL The address one pixel line above
line_up_hl:
  DEC H                   ; Up a line; done unless that was the top line of the
  LD A,H                  ; cell (the line number wrapped to 7)
  INC A                   ;
  AND $07                 ;
  RET NZ                  ;
  LD A,L                  ; Back up a character row; done if that borrowed,
  SUB $20                 ; which means the row is in the same third and H is
  LD L,A                  ; right as it is
  RET C                   ;
  LD A,H                  ; Otherwise put H back into the third the row is in
  ADD A,$08               ;
  LD H,A                  ;
  RET                     ;

  ENDMODULE
