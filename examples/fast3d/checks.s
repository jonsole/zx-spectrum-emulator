; fast3d's routines alone, at $8000, for check.py to run in a simulator.
					DEVICE	ZXSPECTRUM48
					ORG		$8000
					INCLUDE	"fast3d.s"
					INCLUDE	"output/objects_gen.s"
checks_object:		DS		OBJECT_SIZE			; an object, for check.py
checks_vertex:		DS		3 * 16				; vertices, for check.py
checks_points:		DS		2 * 16
end:
					SAVEBIN	"output/checks.bin", $8000, end - $8000
