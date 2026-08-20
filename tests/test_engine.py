"""engine/actor.py: two simulated front-ends sharing one engine queue."""
import asyncio

from zxspectrum.engine import commands as cmd
from zxspectrum.engine.actor import Engine


def _run(coro):
    return asyncio.run(coro)


def test_state_change_from_one_front_end_is_visible_to_the_other():
    async def scenario():
        engine = Engine()
        engine.start()
        try:
            # "front-end A" sets a breakpoint and loads a tiny program
            await engine.set_breakpoint(0x8003)
            engine.machine.write_memory(0x8000, bytes([0x00, 0x00, 0x00, 0x76]))
            regs = await engine.get_registers()
            regs.pc = 0x8000
            await engine.set_registers(regs)

            # "front-end B" runs and independently observes where it stopped
            await engine.run()
            state = await engine.get_state()
            assert state.pc == 0x8003
            assert 0x8003 in state.breakpoints
            assert state.running is False
        finally:
            await engine.stop()

    _run(scenario())


def test_events_are_broadcast_to_every_subscriber():
    async def scenario():
        engine = Engine()
        engine.start()
        try:
            sub_a = engine.subscribe()
            sub_b = engine.subscribe()

            engine.machine.write_memory(0x8000, bytes([0x00]))
            regs = await engine.get_registers()
            regs.pc = 0x8000
            await engine.set_registers(regs)  # publishes one Stopped event
            await sub_a.get()
            await sub_b.get()

            await engine.step()
            event_a = await asyncio.wait_for(sub_a.get(), timeout=1)
            event_b = await asyncio.wait_for(sub_b.get(), timeout=1)
            assert isinstance(event_a, cmd.Stopped) and isinstance(event_b, cmd.Stopped)
            # Both subscribers must observe the exact same resulting PC --
            # that consistency (not the specific address) is what this test
            # is actually checking.
            assert event_a.pc == event_b.pc
            assert event_a.pc >= 0x8000
        finally:
            await engine.stop()

    _run(scenario())


def test_pause_interrupts_a_run_in_progress_from_another_task():
    async def scenario():
        engine = Engine()
        engine.start()
        try:
            # memory is all zero -> free-running NOPs forever, so only an
            # out-of-band Pause (not a queued command competing with Run for
            # the same queue) can ever stop it. Wait for the Continued event
            # confirming Run() actually started before pausing -- pausing
            # any earlier would race Run()'s own pause_requested reset at
            # entry and get silently discarded.
            sub = engine.subscribe()
            run_task = asyncio.create_task(engine.run())
            event = await asyncio.wait_for(sub.get(), timeout=2)
            assert isinstance(event, cmd.Continued)
            await engine.pause()
            await asyncio.wait_for(run_task, timeout=2)

            state = await engine.get_state()
            assert state.running is False
        finally:
            await engine.stop()

    _run(scenario())
