"""Profile the Knight Lore remake per game turn, over the MCP server.

    python profile_turns.py                          the five worst rooms, 300 turns each
    python profile_turns.py --rooms A3 88 --turns 500
    python profile_turns.py --routines sprite_blit object_update --file depth.s
    python profile_turns.py --build ../../../some/other/tree --out before.json

What it does, and why each step is the way it is -- driving.md section 7 says
the same in prose:

- The unit is a TURN, not a frame. The game loop does not wait for the raster
  (a turn is 2.5 to 3.5 frames in a busy room) and paces itself in turn_pace,
  a busy loop, so break-on-interrupt never fires and a `run` has no natural end.
  A breakpoint on `start.loop`, the top of the loop, makes each `run` exactly
  one turn; the sample size is then a count, and every figure here is per turn.
- The profiler counts inside `run` only. `step` with a tick count moves the
  machine but records nothing, which is why the room changes use it and the
  measured stretch does not.
- turn_pace is idle time, and is told to the profiler as such.
- The knight walks throughout (--walk). Standing still, nothing re-sorts and
  the movers' regions are all there is; that is a different game.
- Every previous breakpoint is cleared after the load. A build's `start.loop`
  is an address inside some other routine in the next build, and left behind
  it stops every `run` mid-turn -- every number then comes out at about half.
- To compare two builds, give both the same rooms in the same order. Where the
  knight came from decides what phase a room's movers are in, and busy
  T-states per turn agreeing to within a few percent is the check that the two
  runs saw the same scene.

Needs the `mcp` package, which the repo's venv has: run it with
`.venv-win\\Scripts\\python.exe`. The server is whatever is listening on the
port -- VS Code's own on 8000, or a second instance on another port, started
with `--uncapped`.
"""

import argparse
import asyncio
import base64
import json
import sys
from pathlib import Path

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

HERE = Path(__file__).resolve().parent

# What drives the per-turn cost of a room is how many objects are sorted and
# how many of them move. These were ranked from rooms.json by object count and
# then confirmed by measuring: they are where depth sorting, drawing and
# rotation all cost the most.
WORST_ROOMS = ["BF", "A3", "8C", "43", "E3"]

# The record layout, for counting a room's objects: see engine/object_struct.s.
STRIDE, F_FLAGS, F_BEHAVIOUR, OBJ_BACKGROUND = 32, 6, 27, 0x40


class Mcp:
    """The few calls this needs, over the server's streamable-HTTP endpoint."""

    def __init__(self, session):
        self.session = session

    async def call(self, tool, args=None):
        result = await self.session.call_tool(tool, args or {})
        text = result.content[0].text
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text

    async def sym(self, name):
        return (await self.call("resolve_symbol", {"name": name}))["address"]

    async def read(self, addr, n=1):
        return bytes.fromhex((await self.call("read_memory", {"addr": addr, "length": n}))["hex"])

    async def write(self, addr, data):
        await self.call("write_memory", {"addr": addr, "data_hex": bytes(data).hex()})


async def profile(args):
    build = Path(args.build).resolve()
    out_dir = build / "examples" / "filmation" / "knightlore" / "output" \
        if (build / "examples").is_dir() else build / "output"
    z80 = (out_dir / "knightlore.z80").read_bytes()
    sld = str(out_dir / "knightlore.sld")
    asm = str(out_dir.parent / "knightlore.s")

    async with streamable_http_client(f"http://127.0.0.1:{args.port}/mcp") as (read, write, *_):
        async with ClientSession(read, write) as session:
            await session.initialize()
            c = Mcp(session)

            await c.call("pause")
            await c.call("load_snapshot", {"sna_base64": base64.b64encode(z80).decode()})
            await c.call("load_debug_info", {"sld_path": sld, "asm_path": asm})
            await c.call("set_speed", {"speed": "uncapped"})
            await c.call("set_break_on_interrupt", {"enabled": False})
            for bp in (await c.call("get_state"))["breakpoints"]:
                await c.call("clear_breakpoint", {"addr": bp})

            S = {n: await c.sym(n) for n in (
                "room_number", "room_shown", "player_lives", "player_touched",
                "start.entered", "start.loop", "room_object_count", "room_objects")}

            # Into the game: 0 at the menu, and wait at the first room.
            await c.call("set_breakpoint", {"addr": S["start.entered"]})
            await c.call("key_down", {"key": "0"})
            await c.call("run")
            await c.call("key_up", {"key": "0"})
            await c.call("clear_breakpoint", {"addr": S["start.entered"]})
            await c.call("set_breakpoint", {"addr": S["start.loop"]})
            for _ in range(10):
                await c.call("run")

            async def alive():
                await c.write(S["player_touched"], [0])
                await c.write(S["player_lives"], [8])

            results = {}
            for room_hex in args.rooms:
                room = int(room_hex, 16)
                await c.write(S["room_number"], [room])
                for _ in range(12):
                    await c.call("run")
                    if (await c.read(S["room_shown"]))[0] == room:
                        break
                else:
                    print(f"room {room:02X}: did not build", flush=True)
                    continue
                for _ in range(15):                      # let it settle
                    await c.call("run")
                await alive()

                n = (await c.read(S["room_object_count"]))[0]
                recs = await c.read(S["room_objects"], n * STRIDE) if n else b""
                sorted_n = sum(1 for i in range(n) if not recs[i * STRIDE + F_FLAGS] & OBJ_BACKGROUND)
                movers = sum(1 for i in range(n) if not recs[i * STRIDE + F_FLAGS] & OBJ_BACKGROUND
                             and recs[i * STRIDE + F_BEHAVIOUR] >= 2)

                if args.walk:
                    await c.call("key_down", {"key": "A"})
                await c.call("profile", {"action": "start", "idle": ["turn_pace"], "period": "frame"})
                for i in range(args.turns):
                    await c.call("run")
                    if i % 20 == 19:
                        await alive()
                rep = await c.call("profile", {"action": "stop", "lines": 0,
                                               "routines": 0, "tree_min_percent": 100})
                if args.walk:
                    await c.call("key_up", {"key": "A"})

                T = args.turns
                routines = sorted(rep["routines"], key=lambda r: -r["tstates"])
                keep = {}
                for r in routines[:30]:
                    keep[r["name"]] = round(r["tstates"] / T)
                for r in routines:
                    if args.file and (r.get("path") or "").endswith(args.file):
                        keep[r["name"]] = round(r["tstates"] / T)
                    if r["name"] in args.routines:
                        keep[r["name"]] = round(r["tstates"] / T)
                busy = rep["busy_tstates"] / T
                results[f"{room:02X}"] = {
                    "sorted": sorted_n, "movers": movers, "turns": T,
                    "stayed_in_room": (await c.read(S["room_shown"]))[0] == room,
                    "busy_per_turn": round(busy),
                    "frames_per_turn": round(rep["tstates"] / T / rep["frame_tstates"], 2),
                    "by_routine": keep,
                }
                asked = args.routines or ([n for n in keep if args.file and n in keep][:6])
                shown = "  ".join(f"{n} {keep.get(n, 0):6}" for n in asked) if asked else \
                        "  ".join(f"{n} {v}" for n, v in list(keep.items())[:4])
                print(f"room {room:02X}: sorted {sorted_n:2} movers {movers:2} | "
                      f"busy {busy:8.0f} T/turn | {shown}", flush=True)

            await c.call("clear_breakpoint", {"addr": S["start.loop"]})
            await c.call("set_speed", {"speed": "realtime"})

    Path(args.out).write_text(json.dumps(results, indent=1))
    print("wrote", args.out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8000, help="the server's MCP port (VS Code's is 8000)")
    p.add_argument("--build", default=str(HERE), help="a tree, or a knightlore/ folder, holding output/knightlore.z80")
    p.add_argument("--rooms", nargs="+", default=WORST_ROOMS, metavar="HEX")
    p.add_argument("--turns", type=int, default=300)
    p.add_argument("--routines", nargs="*", default=[], help="routine names to report per turn")
    p.add_argument("--file", default="", help="also keep every routine in this source file, e.g. depth.s")
    p.add_argument("--out", default="profile.json")
    p.add_argument("--no-walk", dest="walk", action="store_false", help="let the knight stand still")
    args = p.parse_args()
    asyncio.run(profile(args))


if __name__ == "__main__":
    main()
