#include "shim.h"

#define CHIPS_IMPL
#include "z80.h"

#include <stdlib.h>

struct zx_cpu_s {
    z80_t cpu;
    uint64_t pins;
};

zx_cpu_t* zx_alloc(void) {
    return (zx_cpu_t*)calloc(1, sizeof(zx_cpu_t));
}

void zx_free(zx_cpu_t* c) {
    free(c);
}

uint64_t zx_init(zx_cpu_t* c) {
    c->pins = z80_init(&c->cpu);
    return c->pins;
}

uint64_t zx_reset(zx_cpu_t* c) {
    c->pins = z80_reset(&c->cpu);
    return c->pins;
}

uint64_t zx_tick(zx_cpu_t* c, uint64_t pins) {
    c->pins = z80_tick(&c->cpu, pins);
    return c->pins;
}

uint64_t zx_prefetch(zx_cpu_t* c, uint16_t new_pc) {
    c->pins = z80_prefetch(&c->cpu, new_pc);
    return c->pins;
}

bool zx_opdone(zx_cpu_t* c) {
    return z80_opdone(&c->cpu);
}

void zx_get_regs(zx_cpu_t* c, zx_regs_t* out) {
    out->pc = c->cpu.pc;
    out->sp = c->cpu.sp;
    out->af = c->cpu.af;
    out->bc = c->cpu.bc;
    out->de = c->cpu.de;
    out->hl = c->cpu.hl;
    out->ix = c->cpu.ix;
    out->iy = c->cpu.iy;
    out->ir = c->cpu.ir;
    out->wz = c->cpu.wz;
    out->af2 = c->cpu.af2;
    out->bc2 = c->cpu.bc2;
    out->de2 = c->cpu.de2;
    out->hl2 = c->cpu.hl2;
    out->im = c->cpu.im;
    out->iff1 = c->cpu.iff1;
    out->iff2 = c->cpu.iff2;
}

void zx_set_regs(zx_cpu_t* c, const zx_regs_t* in) {
    c->cpu.pc = in->pc;
    c->cpu.sp = in->sp;
    c->cpu.af = in->af;
    c->cpu.bc = in->bc;
    c->cpu.de = in->de;
    c->cpu.hl = in->hl;
    c->cpu.ix = in->ix;
    c->cpu.iy = in->iy;
    c->cpu.ir = in->ir;
    c->cpu.wz = in->wz;
    c->cpu.af2 = in->af2;
    c->cpu.bc2 = in->bc2;
    c->cpu.de2 = in->de2;
    c->cpu.hl2 = in->hl2;
    c->cpu.im = in->im;
    c->cpu.iff1 = in->iff1;
    c->cpu.iff2 = in->iff2;
}
