; fast3d's routines alone, at $8000, for check.py to run in a simulator.
					DEVICE	ZXSPECTRUM48
					ORG		$8000
					INCLUDE	"fast3d.s"
					INCLUDE	"output/objects_gen.s"
					INCLUDE	"output/check_models_gen.s"
checks_object:		DS		OBJECT_SIZE			; an object, for check.py
checks_vertex:		DS		3 * 16				; vertices, for check.py
checks_points:		DS		2 * 16
					ALIGN	256
checks_points_far:	DS		256					; transform_object's
checks_cuts:		DS		8 * 64				; cut_edges'
checks_edges:		DS		2 * 255				; facing_edges'
end:
					IF WORLD_WRAP
					SAVEBIN	"output/checks_wrap.bin", $8000, end - $8000
					ELSE
					SAVEBIN	"output/checks.bin", $8000, end - $8000
					ENDIF
