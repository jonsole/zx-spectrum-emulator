# Feature ideas

Running backlog of things we might build next. Not scheduled or scoped in
detail yet -- just captured here so they don't get lost.

- [ ] **Classify memory as code/data (read / read-write) as execution runs.**
      Track, per address, whether it's ever been fetched as an opcode
      (code) vs read or written as data, live while the CPU runs -- e.g. a
      byte first hit as an M1 opcode fetch is "code"; a byte only ever
      touched by LD/PUSH/etc is "data" (read-only vs read-write
      distinguished by whether a write ever landed there). Likely surfaces
      as a per-byte classification alongside the existing memory-read
      tooling (MCP `read_memory`, and/or a new view), useful for
      distinguishing genuine code from data embedded in ROM/program
      images without needing a full static disassembly pass.

- [ ] **Integrate SkoolKit to reverse-engineer an unknown binary from an execution trace.**
      Depends on the memory classification above. SkoolKit's
      `sna2skool.py` (already vendored -- see `build_rom_source.py`/
      `build_manicminer.py`) takes a snapshot plus a `.ctl` control file
      marking address ranges as code/byte/word/text/etc; without one it
      blindly disassembles everything as code, misreading embedded data
      tables as bogus instructions. Export the live code/data
      classification as a `.ctl` file, then run `sna2skool.py` against it
      to get a real annotated disassembly of a program we don't already
      have source for -- unlike `build_rom_source.py`/
      `build_manicminer.py`, which lean on a disassembly someone else
      already did. Limitation worth flagging: coverage only reflects
      what a given run actually executed/touched, so a thin run (e.g.
      never past a title screen) will under-classify most of the image
      as unvisited/unknown.

- [ ] **ULA memory/IO contention (T-state-accurate timing).** Neither core
      implements this yet -- `zxspectrum/core/ula.py` explicitly flags it
      as out of scope ("a functionally-correct decode of the display file,
      not a cycle-perfect raster model"), so this is new work, not a port.
      The classic model: extra wait T-states inserted when the CPU accesses
      contended memory (0x4000-0x7FFF) or an I/O port with the high bit of
      the address clear, during the ULA's screen-fetch window -- the
      well-known 6,5,4,3,2,1,0,0 delay pattern repeating every 8 T-states,
      active for the contended region of each scanline. Needed for
      cycle-accurate timing (some games rely on it for effects/sync); no
      Python reference to verify against, so correctness would need to lean
      on published reference T-state tables instead.
