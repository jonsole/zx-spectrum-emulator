; fast3d: fast 3D for the Z80 -- signed multiplication, a rotation matrix
; from three angles, rotating and projecting vertices, and drawing lines,
; clipped to a window; and objects seen from a camera, culled when out of
; view, their edges cut at a near plane. INCLUDE this file
; anywhere in a program; it aligns its tables itself (1.5K, at a 512-byte
; boundary), and build.py writes their contents to output/tables_gen.s.

					INCLUDE	"engine/tables.s"
					INCLUDE	"engine/multiply.s"
					INCLUDE	"engine/matrix.s"
					INCLUDE	"engine/rotate.s"
					INCLUDE	"engine/project.s"
					INCLUDE	"engine/transform.s"
					INCLUDE	"engine/line.s"
					INCLUDE	"engine/clip.s"
					INCLUDE	"engine/objects.s"
