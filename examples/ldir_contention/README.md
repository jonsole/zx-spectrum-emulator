# ldir_contention

Isolated reproduction for the Aquaplane border-timing investigation: sets
up IM2, waits for the first interrupt via `EI; HALT` (the ISR just does
`EI; RET`, returning immediately), then runs a single `LDIR` copying 256
bytes from uncontended memory (`SourceData`, 0x8100) into contended screen
memory (0x4000) -- isolating write-side memory contention across a real
block copy, independent of anything else a real game does.

Built with `sjasmplus` (fetched into `tools/sjasmplus/`, gitignored --
see `.gitignore`), producing `test.sna` + `test.sld` for source-level
stepping. Launch **"ZX Spectrum (Rust core): LDIR contention test"** from
the Run and Debug view -- its `preLaunchTask` (`ldir-contention.build-
and-start-server`) rebuilds from `test.asm` before starting the server,
so editing the `.asm` and relaunching picks up changes automatically.

Currently reproduces a real bug: `BC` (the LDIR byte counter, starts at
0x0100) should count down to 0 as the copy completes, but was observed
growing past its starting value instead during headless testing --
something corrupts state before the loop finishes, possibly repeated/
spurious interrupt redirection mid-`LDIR`. Not yet root-caused.
