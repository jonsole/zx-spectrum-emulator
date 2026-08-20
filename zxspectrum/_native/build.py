import pathlib

import cffi

_HERE = pathlib.Path(__file__).parent
_VENDOR = _HERE.parent.parent / "vendor" / "chips"

# cffi's cdef() parser doesn't understand preprocessor directives, so the
# declarations are duplicated here in directive-free form; shim.h (with its
# #pragma/#include) is what actually gets compiled, via set_source() below.
ffibuilder = cffi.FFI()
ffibuilder.cdef("""
    typedef struct zx_cpu_s zx_cpu_t;

    typedef struct {
        uint16_t pc, sp, af, bc, de, hl, ix, iy, ir, wz;
        uint16_t af2, bc2, de2, hl2;
        uint8_t im;
        bool iff1, iff2;
    } zx_regs_t;

    zx_cpu_t* zx_alloc(void);
    void zx_free(zx_cpu_t* c);

    uint64_t zx_init(zx_cpu_t* c);
    uint64_t zx_reset(zx_cpu_t* c);
    uint64_t zx_tick(zx_cpu_t* c, uint64_t pins);
    uint64_t zx_prefetch(zx_cpu_t* c, uint16_t new_pc);
    bool zx_opdone(zx_cpu_t* c);

    void zx_get_regs(zx_cpu_t* c, zx_regs_t* out);
    void zx_set_regs(zx_cpu_t* c, const zx_regs_t* in);
""")
ffibuilder.set_source(
    "zxspectrum._native._z80",
    '#include "shim.h"',
    sources=[str(_HERE / "shim.c")],
    include_dirs=[str(_HERE), str(_VENDOR)],
)

if __name__ == "__main__":
    ffibuilder.compile(verbose=True)
