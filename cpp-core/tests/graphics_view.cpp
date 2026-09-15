// The graphics view: where VS Code's ZX Spectrum Graphics panel is pointed.
//
// Nothing here touches the machine. The Engine holds this purely as the one
// place an MCP client and a DAP client can both see -- MCP sets it, the DAP
// server broadcasts each change, the extension moves its panel -- because the
// two front-ends have no other channel between them.
//
// What is worth pinning down is the version counter, which is not decoration.
// The panel remembers its own last layout, and a panel that opened onto
// whatever the server happened to hold would throw that away every time. So
// "nobody has ever asked for anything" has to be distinguishable from "someone
// asked for the defaults", and version 0 is how.

#include "engine.h"
#include "test_main.h"

#include <string>

using namespace zx;

TEST(a_fresh_engine_has_asked_for_nothing) {
    Engine engine;
    uint64_t version = 12345;
    const GraphicsView view = engine.graphics_view(&version);
    CHECK(version == 0);
    // The defaults are a whole screen at $4000, which is the one view that
    // needs no thought to be worth looking at.
    CHECK(view.source == "memory");
    CHECK(view.address == "$4000");
    CHECK(view.format == "screen");
}

TEST(setting_a_view_bumps_the_version) {
    Engine engine;
    GraphicsView view;
    view.address = "sprite_000";
    view.format = "sprite";
    engine.set_graphics_view(view);

    uint64_t version = 0;
    const GraphicsView back = engine.graphics_view(&version);
    CHECK(version == 1);
    CHECK(back.address == "sprite_000");
    CHECK(back.format == "sprite");

    engine.set_graphics_view(back);
    engine.graphics_view(&version);
    CHECK(version == 2);
}

TEST(a_handler_hears_every_change) {
    Engine engine;
    std::string seen_address;
    uint64_t seen_version = 0;
    int calls = 0;
    engine.on_graphics_view([&](const GraphicsView& v, uint64_t version) {
        seen_address = v.address;
        seen_version = version;
        calls++;
    });

    GraphicsView view;
    view.address = "$8000";
    engine.set_graphics_view(view);
    CHECK(calls == 1);
    CHECK(seen_address == "$8000");
    CHECK(seen_version == 1);

    view.address = "sprite_017";
    engine.set_graphics_view(view);
    CHECK(calls == 2);
    CHECK(seen_address == "sprite_017");
    CHECK(seen_version == 2);
}

TEST(a_file_view_carries_an_offset) {
    // Only the memory source has an address, so a byte range inside a bigger
    // file -- a sprite in a .sna, say -- is reached by this and nothing else.
    Engine engine;
    GraphicsView view;
    view.source = "file";
    view.file = "kl.sna";
    view.offset = 19237;
    engine.set_graphics_view(view);
    CHECK(engine.graphics_view().offset == 19237);
}

TEST(pin_does_not_survive_into_the_next_view) {
    // Not a setting but an instruction, so the Engine stores whatever it was
    // given and the MCP layer clears it before merging -- see set_graphics_view
    // in mcp_server.cpp. What is pinned here is that the field round-trips at
    // all, since the panel acts on it and nothing else would notice it missing.
    Engine engine;
    GraphicsView view;
    view.pin = true;
    engine.set_graphics_view(view);
    CHECK(engine.graphics_view().pin == true);

    view.pin = false;
    engine.set_graphics_view(view);
    CHECK(engine.graphics_view().pin == false);
}

TEST(the_version_is_optional_to_ask_for) {
    // The DAP request wants it; most callers reading the view do not.
    Engine engine;
    GraphicsView view;
    view.width = 3;
    engine.set_graphics_view(view);
    CHECK(engine.graphics_view().width == 3);
}

TEST(setting_a_view_does_not_touch_the_machine) {
    // The reason this can be set mid-run without queueing: it is not a command
    // to the emulator, and must not behave like one. If it ever grew a
    // submit() this test would deadlock or hang rather than quietly slow down.
    Engine engine;
    const MachineState before = engine.state();
    GraphicsView view;
    view.format = "font";
    engine.set_graphics_view(view);
    const MachineState after = engine.state();
    CHECK(after.pc == before.pc);
    CHECK(after.tstate == before.tstate);
}

RUN_TESTS()
