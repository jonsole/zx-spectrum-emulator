#pragma once
#include <stdint.h>
#include <stdbool.h>

/* Opaque handle wrapping a floooh/chips z80_t plus its last pin state.
   Kept opaque here so cffi's cdef parser never has to see z80.h's
   anonymous unions/structs, which it can't parse. */
typedef struct zx_cpu_s zx_cpu_t;

/* Flat, cffi-friendly mirror of the interesting parts of z80_t. */
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
