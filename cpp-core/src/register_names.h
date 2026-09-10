#pragma once
// Registers by name, for the two debugger front ends that let a user type
// "HL" or "AF'" and expect the right thing to change. One table, so a name
// that works in VS Code's Variables pane works over MCP too.

#include "registers.h"

#include <cstdint>
#include <string>

namespace zx {

/// Bit width of the register called `name`: 8, 16, 1 for IFF1/IFF2, 2 for
/// IM, or 0 for a name that is not a register. Names are case-insensitive;
/// a shadow register is written AF' or AF_ (the latter for callers whose
/// identifiers cannot carry a quote). The halves of the index registers are
/// IXH/IXL/IYH/IYL.
int register_width(const std::string& name);

/// Assigns `value` to the register called `name`. Returns false, with `error`
/// saying why, for an unknown name or a value too wide for it.
bool set_register(Registers& r, const std::string& name, uint32_t value, std::string& error);

/// Sets or clears one bit of F by its flag letter: S, Z, H, P/V (also PV or
/// P), N or C. Returns false for anything else.
bool set_flag(Registers& r, const std::string& name, bool value, std::string& error);

} // namespace zx
