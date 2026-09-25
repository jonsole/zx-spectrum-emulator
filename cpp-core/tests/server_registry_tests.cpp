// The advert a server writes so it can be found (server_registry.h), and the
// listener behaviour it rests on: a port of 0 comes back as a real port, and
// a port already taken is refused rather than shared.

#include "test_main.h"

#include "net.h"
#include "server_registry.h"

#include <nlohmann/json.hpp>

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace fs = std::filesystem;
using namespace zx;

namespace {

/// Beside the test executable rather than in a system temp directory: see
/// tracelog_tests.cpp for why.
const char* const ADVERT_DIR = "zx_test_adverts";

nlohmann::json read_json(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    std::stringstream text;
    text << file.rdbuf();
    return nlohmann::json::parse(text.str(), nullptr, false);
}

ServerIdentity sample_identity() {
    ServerIdentity id;
    id.version = "0.3.0-dev";
    id.host = "127.0.0.1";
    id.ports.dap = 14711;
    id.ports.mcp = 18000;
    id.ports.screen = 18500;
    id.ports.audio = 0; // --no-audio
    id.exe = "zx_server.exe";
    id.roms = {"roms/48.rom"};
    id.audio_device = true;
    return id;
}

} // namespace

TEST(advert_names_the_server_and_its_ports) {
    fs::remove_all(ADVERT_DIR);
    set_server_identity(sample_identity());
    std::string error;
    CHECK(advertise(ADVERT_DIR, error));

    // One file, named for the process, holding what serverInfo reports.
    const nlohmann::json info = server_info();
    const fs::path file = fs::path(ADVERT_DIR) / (std::to_string(info["pid"].get<uint32_t>()) + ".json");
    CHECK(fs::exists(file));
    const nlohmann::json advert = read_json(file);
    CHECK(!advert.is_discarded());
    CHECK(advert == info);
    CHECK_EQ(advert["version"].get<int>(), SERVER_ADVERT_VERSION);
    CHECK_EQ(advert["ports"]["dap"].get<int>(), 14711);
    CHECK_EQ(advert["ports"]["mcp"].get<int>(), 18000);
    CHECK_EQ(advert["ports"]["screen"].get<int>(), 18500);
    // No audio stream is null, not a port 0 for a reader to connect to.
    CHECK(advert["ports"]["audio"].is_null());
    CHECK(advert["program"].is_null());
    CHECK(advert["audioDevice"].get<bool>());
    CHECK(!advert["started"].get<std::string>().empty());
    CHECK_EQ(advert["serverVersion"].get<std::string>(), std::string("0.3.0-dev"));

    // Nothing left behind by the write-then-rename.
    size_t files = 0;
    for (const auto& entry : fs::directory_iterator(ADVERT_DIR)) {
        (void)entry;
        files++;
    }
    CHECK_EQ(files, size_t(1));

    withdraw();
}

TEST(loading_a_program_rewrites_the_advert) {
    fs::remove_all(ADVERT_DIR);
    set_server_identity(sample_identity());
    std::string error;
    CHECK(advertise(ADVERT_DIR, error));
    note_program("examples/filmation/knightlore/output/knightlore.z80");

    const fs::path file =
        fs::path(ADVERT_DIR) / (std::to_string(server_info()["pid"].get<uint32_t>()) + ".json");
    const nlohmann::json advert = read_json(file);
    CHECK_EQ(advert["program"].get<std::string>(),
             std::string("examples/filmation/knightlore/output/knightlore.z80"));

    // A bare reset into the ROM runs no program.
    note_program("");
    CHECK(read_json(file)["program"].is_null());
    withdraw();
}

TEST(withdrawing_removes_the_advert_and_can_be_repeated) {
    fs::remove_all(ADVERT_DIR);
    set_server_identity(sample_identity());
    std::string error;
    CHECK(advertise(ADVERT_DIR, error));
    const fs::path file =
        fs::path(ADVERT_DIR) / (std::to_string(server_info()["pid"].get<uint32_t>()) + ".json");
    CHECK(fs::exists(file));
    withdraw();
    CHECK(!fs::exists(file));
    withdraw();
    // After a withdraw a load has nothing to rewrite, and must not bring the
    // advert back: the process is on its way out.
    note_program("late.tap");
    CHECK(!fs::exists(file));
    fs::remove_all(ADVERT_DIR);
}

TEST(port_zero_is_given_a_real_port) {
    net::Listener listener;
    std::string error;
    CHECK(listener.listen("127.0.0.1", 0, error));
    CHECK(listener.port() != 0);
}

TEST(a_port_in_use_is_refused) {
    // What stops a second zx_server started on the same ports: it has to
    // fail to bind, not share the port with the first.
    net::Listener first;
    std::string error;
    CHECK(first.listen("127.0.0.1", 0, error));
    net::Listener second;
    CHECK(!second.listen("127.0.0.1", first.port(), error));
    CHECK(!second.valid());
    CHECK_EQ(second.port(), uint16_t(0));
}

RUN_TESTS()
