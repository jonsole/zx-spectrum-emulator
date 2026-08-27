---
name: zx-live-verify
description: Verify a rust-core/zx-engine/zx-server change against a real, running zx-server instance -- driven through the actual DAP or MCP protocol, the same way VS Code or an MCP client would. Use this whenever a fix touches live/interactive behavior that unit tests can't fully exercise -- interrupt timing, HALT/step-over semantics, breakpoints, contention, or anything where "does it actually behave right when stepped through" matters more than "does the isolated function return the right value". Do NOT use this for changes fully covered by cargo test alone.
---

# Verifying zx-server live, without touching the user's own session

This project's `zx-server` (`rust-core/zx-server`) is usually already running
as the user's own live VS Code debug session (DAP on port 4711, MCP on 8000,
screen stream on 8500). **Never** build over that binary or touch that
process directly -- Windows will refuse to overwrite a locked `.exe`, and
killing someone's live debug session out from under them is exactly the kind
of action to ask about first, not assume.

Instead, this skill runs a **second, throwaway instance** on different ports,
built to a separate Cargo target directory, verifies the fix against it, then
tears it down completely. This is the exact workflow that found and
confirmed two real, non-obvious bugs in this codebase (an interrupt-during-
HALT return-address bug, and a sticky-vs-pulsed INT line bug) -- hand-rolling
it from scratch each time is what caused the concrete mistakes documented
below, so use the checked-in library rather than re-deriving it.

## Steps

1. **Build to an isolated target dir**, so the user's own running server
   (which locks its own `target/debug/zx-server.exe` on Windows) is never
   touched:
   ```
   cd rust-core
   CARGO_TARGET_DIR=/tmp/zx_verify_target cargo build -p zx-server
   ```
   (Use a fresh, distinctive tmp dir per verification session if running
   more than one build in a row -- reusing the same one across unrelated
   sessions is fine and saves rebuild time.)

2. **Check the alternate ports are free first** (14711/18000/18500 by
   convention -- pick different ones only if these are somehow already
   taken by something unrelated):
   ```
   netstat -ano | grep -E "14711|18000|18500"
   ```
   If anything shows up, it's very likely a leftover instance from an
   earlier verification run that didn't get cleaned up -- find and kill
   that specific PID before continuing (see Cleanup below), don't just pick
   different ports and let it accumulate.

3. **Start the instance in the background**, capture its PID, confirm it's
   actually listening before moving on:
   ```
   /tmp/zx_verify_target/debug/zx-server.exe --dap-port 14711 --mcp-port 18000 --screen-port 18500 > /tmp/zx_verify_server.log 2>&1 &
   ```
   Then poll `netstat -ano | grep "14711.*LISTENING"` (a `sleep 1.5` first is
   fine; don't assume it's up immediately) and note the PID from that line
   -- that's the PID to kill in cleanup, not anything guessed from the
   background task's own job id.

4. **Drive it** using the bundled client libraries (`dap_client.py` for the
   real DAP protocol -- `next`/`stepIn`/`continue`/breakpoints/registers via
   `scopes`+`variables`, the same requests VS Code sends; `mcp_client.py` for
   simpler state reads or single-instruction stepping via MCP tools). Run
   scripts with this repo's own venv interpreter, not a bare `python`:
   ```
   C:\Users\jonso\zx-spectrum-emulator\.venv-win\Scripts\python.exe -u your_check.py
   ```
   Import them directly (`sys.path.insert(0, ".../.claude/skills/zx-live-verify")`
   or just run a script from inside this skill's directory) -- don't
   hand-roll a new raw DAP-framing or MCP-connection implementation; both
   are already correct and covered by the gotchas below.

5. **Clean up unconditionally**, even (especially) if the check failed or
   raised:
   ```
   powershell -Command "Stop-Process -Id <pid> -Force -ErrorAction SilentlyContinue"
   ```
   then confirm with `netstat -ano | grep "14711.*LISTENING"` that it's
   actually gone. Also check for and kill any duplicate copies of your OWN
   verification script left running from a previous attempt (see gotcha
   below) -- `tasklist | grep -i python` and cross-check command lines via
   `Get-CimInstance Win32_Process` if more than one shows up.

## Gotchas already paid for -- don't rediscover these

- **Two copies of the same verification script running against the same
  server corrupts the sequence.** A backgrounded run that appeared to hang
  was actually a second, still-running copy of the exact same script issuing
  its own `next`/`step` calls concurrently on the shared engine, interleaving
  with the first. Before starting a new run, confirm no earlier one is still
  alive.
- **A `next` request's `stopped` event isn't reliable on its own.** Several
  DAP `next` cases (CALL/RST, block-repeat instructions, HALT) reply to the
  request immediately and do the real work in a background task -- the
  *first* `stopped` event received afterward can be a stray one left over
  from an earlier, unrelated step, arriving out of order. Use
  `DapClient.wait_for_settled_stop()`, which re-reads live state until it
  stops changing, rather than trusting the first event's own payload.
- **MCP import name**: it's `from mcp.client.streamable_http import
  streamable_http_client` (no extra "s"), and it yields a 2-tuple
  `(read, write)`, not 3 -- both were guessed wrong from memory before being
  confirmed against the installed package.
- **`cargo build` silently targets the locked binary if you forget
  `CARGO_TARGET_DIR`**, failing with `Access is denied` if the user's own
  server is running -- always set it explicitly for a verification build,
  never rely on the default `target/`.
- **A raw address breakpoint can't tell "genuinely there" from "about to be
  there again"** for anything whose PC display is ambiguous (HALT reads as
  `halt_addr+1` both while still waiting AND once truly past it -- see
  `Cpu::registers()`'s doc comment in `rust-core/zx-core/src/cpu.rs`). If a
  verification script's own break condition just checks an address, double
  check whether the state it's watching for is actually reachable more than
  one way.

## What this skill deliberately does NOT do

- Doesn't touch `.vscode/tasks.json`'s `zxspectrum-rust.start-server` task or
  the user's own launch configs -- those are for the user's own interactive
  debugging, not automated verification.
- Doesn't replace `cargo test` -- reach for this only when the thing being
  checked genuinely needs live, protocol-level interaction (stepping,
  breakpoints, timing as observed through the debugger) rather than a
  function call's return value.
- Doesn't commit anything or touch git -- purely a local, throwaway
  verification run.
