# Rust core (`rust-core/`) — deprecated

Part of the [zx-spectrum-emulator README](../README.md).

> **Deprecated, kept for the record.** The C++ core took over the role this was
> being built for, and `rust-core/` is no longer developed. What follows
> describes where it got to, not what to use. The same goes for the Python core
> it refers to.

A from-scratch, hand-written Z80 interpreter in Rust — not an FFI wrapper
around `z80.h` — built alongside the Python project for two reasons: a genuine
path to WebAssembly (a browser-playable target had no good story via the
Python/`cffi` stack), and a deliberate Rust-learning exercise. The goal was for
`rust-core/` to grow into a full replacement for the Python
DAP/MCP/screen-stream server, reusing one core for both a native server and a
wasm browser player. It stopped at CPU-only, with the memory/ULA/keyboard/
snapshot layer and both front-ends never built.

**Status: the CPU core is complete and independently verified two ways.**
- **Tick/pin-level, not instruction-level** (mirroring the Python project's
  own `z80.h` wrapper, and for the same reason): `Cpu::tick()` advances
  exactly one T-state with real address/data/control pins, including the
  real overlapped-fetch pipeline — needed later for cycle-accurate ULA
  memory contention, which depends on genuine per-T-state bus visibility,
  not "this instruction took N T-states" as a lump sum.
- **Every opcode is generated, not hand-transcribed.**
  `scripts/generate_z80_dispatch.py` ports
  [floooh/chips](https://github.com/floooh/chips)' own `z80_gen.py` codegen
  algorithm (Python, already) to emit Rust instead of C, reading the same
  `vendor/chips/z80_desc.yml` instruction-cycle description that generates
  the real `z80.h` — literal fidelity to the authoritative source, and a
  generator that asserts no two opcode descriptors ever claim the same byte
  catches transposition bugs a human eyeballing an opcode table can miss.
  The `(IX+d)`/`(IY+d)` displacement-addressing sequence and the `DD CB
  d`/`FD CB d` double-prefix machine cycle are hand-written in `cpu.rs`
  instead (small, fixed sequences that mix bus-pin-issuing steps with plain
  idle ones, a shape the generator's per-machine-cycle templates don't
  cleanly express) — everything else is generated output, regenerated via
  `python scripts/generate_z80_dispatch.py` whenever the mapping changes.
- **Verified two independent ways:**
  1. A differential test harness (the `zx-core-conformance` crate, dev-only)
     links the real `vendor/chips/z80.h` via FFI and runs both cores in
     lockstep — fuzzed random instruction streams plus hand-written
     programs for anything unsafe to fuzz (control flow, the stack) —
     checked register-for-register after every instruction, and separately,
     pin-for-pin on every single T-state.
  2. The real [ZEXALL/ZEXDOC](https://github.com/agn453/ZEXALL) Z80
     exerciser (fetched at test time, not vendored — see
     `scripts/fetch_zexall.py`) runs against the core through a minimal
     CP/M BDOS shim. **Both zexdoc.z80 and its stricter sibling zexall.z80
     (which checks the undocumented flag bits fully instead of masking them
     out) pass in full: every test group in both suites reports `OK`, zero
     errors.** This checks agreement with known-correct Z80 semantics
     directly, independent of z80.h — the stronger of the two claims, since
     it would catch a bug the two cores happened to share.
- Covers the full documented instruction set plus the well-known
  undocumented forms: unprefixed, `ED`, `CB`, `DD`/`FD` (register
  substitution including `IXH`/`IXL`/`IYH`/`IYL`, and `(IX+d)`/`(IY+d)`
  addressing), and `DD CB d`/`FD CB d` (including the undocumented "also
  store to register" behavior). I/O opcodes and interrupt handling are
  deferred, same as the Python core's own priorities — see
  `rust-core/zx-core-conformance/tests/zexall.rs`'s doc comment for the
  full detail on what's verified and how.

```bash
cd rust-core
cargo test                                                            # fast suite, seconds
cargo test --test zexall zexdoc_reports_no_errors -- --ignored --nocapture  # full ZEXDOC run, ~18 min
cargo test --test zexall zexall_reports_no_errors -- --ignored --nocapture  # stricter sibling, ~18 min
```
