#include "rom_source.h"

#include "file_io.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <sys/stat.h>
#include <sys/types.h>

namespace zx {
namespace {

/// Splits on '|' without collapsing empties -- field positions are what carry
/// the meaning in SLD, so an empty field must still occupy its slot.
std::vector<std::string> split_fields(const std::string& line) {
    std::vector<std::string> fields;
    size_t start = 0;
    for (;;) {
        const size_t bar = line.find('|', start);
        if (bar == std::string::npos) {
            fields.push_back(line.substr(start));
            return fields;
        }
        fields.push_back(line.substr(start, bar - start));
        start = bar + 1;
    }
}

/// A decimal SLD address field. False for values that are not a real 16-bit
/// address: a D record's address can be an arbitrary constant rather than an
/// address (a bitmask, say), and SLD writes -1 for "none". Since every lookup
/// supplies a real uint16_t, a constant outside that range could never match
/// anything anyway.
bool parse_addr_field(const std::string& s, uint16_t& out) {
    if (s.empty()) {
        return false;
    }
    char* end = nullptr;
    const long long v = std::strtoll(s.c_str(), &end, 10);
    if (end == nullptr || *end != '\0' || v < 0 || v > 0xFFFF) {
        return false;
    }
    out = uint16_t(v);
    return true;
}

bool parse_line_field(const std::string& s, uint32_t& out) {
    if (s.empty()) {
        return false;
    }
    char* end = nullptr;
    const long long v = std::strtoll(s.c_str(), &end, 10);
    if (end == nullptr || *end != '\0' || v < 0 || v > 0xFFFFFFFFLL) {
        return false;
    }
    out = uint32_t(v);
    return true;
}

void parse_sld(const std::string& text, RomSource& out) {
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) {
            end = text.size();
        }
        std::string line = text.substr(pos, end - pos);
        pos = end + 1;
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.empty()) {
            continue;
        }

        const std::vector<std::string> fields = split_fields(line);
        if (fields.size() < 8) {
            continue;
        }
        const std::string& line_s = fields[1];
        const std::string& addr_s = fields[5];
        const std::string& rec_type = fields[6];
        const std::string& data = fields[7];

        if (rec_type == "T") {
            uint32_t line_no = 0;
            uint16_t addr = 0;
            if (!parse_line_field(line_s, line_no) || !parse_addr_field(addr_s, addr)) {
                continue;
            }
            // First mapping wins if a line or address ever repeats. That
            // should not happen for real T records, but first-wins is a safer
            // default than silently overwriting.
            out.line_to_addr.emplace(line_no, addr);
            out.addr_to_line.emplace(addr, line_no);
        } else if ((rec_type == "F" || rec_type == "D") && !data.empty()) {
            uint16_t addr = 0;
            if (!parse_addr_field(addr_s, addr)) {
                continue;
            }
            out.symbols[data] = addr;
        }
    }
}

/// Modification time, used only to decide whether a cached parse is stale.
bool file_mtime(const std::string& path, int64_t& out) {
    struct stat info;
    if (stat(path.c_str(), &info) != 0) {
        return false;
    }
    out = int64_t(info.st_mtime);
    return true;
}

bool equal_ignoring_case(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) {
        return false;
    }
    for (size_t i = 0; i < a.size(); i++) {
        if (std::tolower(uint8_t(a[i])) != std::tolower(uint8_t(b[i]))) {
            return false;
        }
    }
    return true;
}

std::string trimmed(const std::string& s) {
    size_t first = 0;
    while (first < s.size() && std::isspace(uint8_t(s[first])) != 0) {
        first++;
    }
    size_t last = s.size();
    while (last > first && std::isspace(uint8_t(s[last - 1])) != 0) {
        last--;
    }
    return s.substr(first, last - first);
}

/// One number of an address expression. `bare_is_hex` is the radix for digits
/// written with no prefix at all -- see parse_address's contract for why that
/// differs between an address and an offset.
bool parse_number(const std::string& token, bool bare_is_hex, uint32_t& out) {
    std::string body = token;
    int base = bare_is_hex ? 16 : 10;
    if (body.size() > 2 && body[0] == '0' && (body[1] == 'x' || body[1] == 'X')) {
        body.erase(0, 2);
        base = 16;
    } else if (body.size() > 1 && body[0] == '$') {
        body.erase(0, 1);
        base = 16;
    }
    if (body.empty()) {
        return false;
    }
    // Checked here rather than left to strtoul, which accepts a leading sign
    // and stops happily at the first character it does not like.
    for (size_t i = 0; i < body.size(); i++) {
        const bool ok = base == 16 ? std::isxdigit(uint8_t(body[i])) != 0
                                   : std::isdigit(uint8_t(body[i])) != 0;
        if (!ok) {
            return false;
        }
    }
    out = uint32_t(std::strtoul(body.c_str(), nullptr, base));
    return true;
}

/// One term: a symbol, or a number. The symbol table is consulted first, so a
/// label spelled in hex digits is still a label.
bool term_value(const Sources& sources, const std::string& token, bool is_base, uint32_t& out,
                std::string& error) {
    if (token.empty()) {
        error = "an address expression cannot end with + or -";
        return false;
    }
    const bool explicit_number =
        token[0] == '$' || (token.size() > 2 && token[0] == '0'
                            && (token[1] == 'x' || token[1] == 'X'));
    if (explicit_number) {
        if (!parse_number(token, true, out)) {
            error = "\"" + token + "\" is not a hex number";
            return false;
        }
        return true;
    }
    uint16_t symbol = 0;
    if (sources.symbol_value(token, symbol)) {
        out = symbol;
        return true;
    }
    if (parse_number(token, is_base, out)) {
        return true;
    }
    if (std::isdigit(uint8_t(token[0])) != 0) {
        error = is_base ? "\"" + token + "\" is not a hex address"
                        : "\"" + token + "\" is not a decimal offset (write 0x" + token
                              + " if you meant hex)";
    } else if (sources.active().empty()) {
        error = "no debug info loaded, so \"" + token
                + "\" cannot be resolved -- see load_debug_info, or "
                  "scripts/build_rom_source.py for the ROM's own symbols";
    } else {
        error = "no symbol named \"" + token + "\"";
    }
    return false;
}

std::string file_name_of(const std::string& path) {
    const size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

bool is_hex_digit(char c) {
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F');
}

bool is_word_char(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) != 0 || c == '_';
}

} // namespace

void RomSource::index() {
    // Sorted by address, so symbol_at can binary-search. Two labels at the
    // same address tie-break by name: arbitrary, but at least deterministic.
    // There is no "correct" choice between co-located labels, and real SLD
    // files essentially never emit two for one address.
    std::vector<std::pair<uint16_t, std::string>> pairs;
    pairs.reserve(symbols.size());
    for (const auto& entry : symbols) {
        pairs.emplace_back(entry.second, entry.first);
    }
    std::sort(pairs.begin(), pairs.end());

    sorted_addrs_.clear();
    sorted_names_.clear();
    sorted_addrs_.reserve(pairs.size());
    sorted_names_.reserve(pairs.size());
    for (auto& pair : pairs) {
        sorted_addrs_.push_back(pair.first);
        sorted_names_.push_back(std::move(pair.second));
    }
}

bool RomSource::addr_for_line(uint32_t line, uint16_t& addr, uint32_t& actual_line) const {
    // A plain forward probe rather than a sorted index: the search is bounded
    // to a handful of lines, and only ever runs when a user clicks the gutter.
    // Forward only -- nudging UP would move the breakpoint above the line the
    // user actually clicked, which is a surprise rather than a convenience.
    for (uint32_t offset = 0; offset <= MAX_BREAKPOINT_NUDGE; offset++) {
        auto it = line_to_addr.find(line + offset);
        if (it != line_to_addr.end()) {
            addr = it->second;
            actual_line = line + offset;
            return true;
        }
    }
    return false;
}

bool RomSource::symbol_at(uint16_t addr, int32_t max_offset, std::string& name,
                          uint16_t& offset) const {
    // Index of the last entry <= addr.
    const auto it = std::upper_bound(sorted_addrs_.begin(), sorted_addrs_.end(), addr);
    if (it == sorted_addrs_.begin()) {
        return false;
    }
    const size_t idx = size_t(it - sorted_addrs_.begin()) - 1;
    const uint16_t candidate = uint16_t(addr - sorted_addrs_[idx]);
    if (max_offset != NO_MAX && candidate > uint16_t(max_offset)) {
        return false;
    }
    name = sorted_names_[idx];
    offset = candidate;
    return true;
}

RomSourcePtr load_source(const std::string& sld_path, const std::string& asm_path,
                         std::string& error) {
    std::vector<uint8_t> bytes;
    if (!read_file(sld_path, bytes)) {
        error = "couldn't read SLD " + sld_path;
        return nullptr;
    }
    auto source = std::make_shared<RomSource>();
    source->asm_path = asm_path;
    parse_sld(std::string(bytes.begin(), bytes.end()), *source);
    source->index();
    return source;
}

RomSourcePtr get_rom_source(const std::string& directory) {
    const std::string asm_path = directory + "/rom.asm";
    const std::string sld_path = directory + "/rom.sld";

    int64_t asm_mtime = 0;
    int64_t sld_mtime = 0;
    if (!file_mtime(asm_path, asm_mtime) || !file_mtime(sld_path, sld_mtime)) {
        return nullptr; // not built; callers fall back to no symbols
    }

    static std::mutex cache_mutex;
    static std::string cached_dir;
    static int64_t cached_asm = 0;
    static int64_t cached_sld = 0;
    static RomSourcePtr cached_source;

    std::lock_guard<std::mutex> lock(cache_mutex);
    if (cached_source != nullptr && cached_dir == directory && cached_asm == asm_mtime
        && cached_sld == sld_mtime) {
        return cached_source;
    }
    std::string error;
    cached_source = load_source(sld_path, asm_path, error);
    cached_dir = directory;
    cached_asm = asm_mtime;
    cached_sld = sld_mtime;
    return cached_source;
}

bool Sources::load_debug_info(const std::string& sld_path, const std::string& asm_path,
                              std::string& error) {
    RomSourcePtr source = load_source(sld_path, asm_path, error);
    if (source == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    debug_info_ = std::move(source);
    return true;
}

void Sources::clear_debug_info() {
    std::lock_guard<std::mutex> lock(mutex_);
    debug_info_.reset();
}

RomSourcePtr Sources::debug_info() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return debug_info_;
}

std::vector<RomSourcePtr> Sources::active() const {
    std::vector<RomSourcePtr> sources;
    RomSourcePtr program = debug_info();
    if (program != nullptr) {
        sources.push_back(std::move(program));
    }
    RomSourcePtr rom = get_rom_source(rom_dir_);
    if (rom != nullptr) {
        sources.push_back(std::move(rom));
    }
    return sources;
}

bool Sources::resolve_symbol(uint16_t addr, std::string& name, uint16_t& offset) const {
    for (const RomSourcePtr& source : active()) {
        if (source->symbol_at(addr, SYMBOL_MAX_OFFSET, name, offset)) {
            return true;
        }
    }
    return false;
}

bool Sources::label_at(uint16_t addr, std::string& name) const {
    uint16_t offset = 0;
    for (const RomSourcePtr& source : active()) {
        if (source->symbol_at(addr, 0, name, offset)) {
            return true;
        }
    }
    return false;
}

bool Sources::symbol_value(const std::string& name, uint16_t& addr) const {
    const std::vector<RomSourcePtr> sources = active();
    for (size_t i = 0; i < sources.size(); i++) {
        auto it = sources[i]->symbols.find(name);
        if (it != sources[i]->symbols.end()) {
            addr = it->second;
            return true;
        }
    }
    // Only once every source has been asked exactly: an exact match in the
    // ROM must still lose to an exact match in the user's own program.
    for (size_t i = 0; i < sources.size(); i++) {
        for (auto it = sources[i]->symbols.begin(); it != sources[i]->symbols.end(); ++it) {
            if (equal_ignoring_case(it->first, name)) {
                addr = it->second;
                return true;
            }
        }
    }
    return false;
}

bool Sources::parse_address(const std::string& text, uint16_t& addr, std::string& error) const {
    const std::string expression = trimmed(text);
    if (expression.empty()) {
        error = "empty address";
        return false;
    }
    // Signed, and only wrapped at the end: SYM-2 two bytes below 0x0000 is
    // 0xFFFE, the same wrap the CPU itself does, rather than an error.
    int64_t total = 0;
    int64_t sign = 1;
    size_t pos = 0;
    bool is_base = true;
    for (;;) {
        size_t end = pos;
        while (end < expression.size() && expression[end] != '+' && expression[end] != '-') {
            end++;
        }
        uint32_t value = 0;
        if (!term_value(*this, trimmed(expression.substr(pos, end - pos)), is_base, value,
                        error)) {
            return false;
        }
        total += sign * int64_t(value);
        is_base = false;
        if (end >= expression.size()) {
            break;
        }
        sign = expression[end] == '+' ? 1 : -1;
        pos = end + 1;
    }
    addr = uint16_t(((total % 0x10000) + 0x10000) % 0x10000);
    return true;
}

RomSourcePtr Sources::source_for_path(const std::string& path) const {
    const std::string target = file_name_of(path);
    for (const RomSourcePtr& source : active()) {
        if (source->asm_path == path || file_name_of(source->asm_path) == target) {
            return source;
        }
    }
    return nullptr;
}

std::function<std::string(uint16_t)> symbol_resolver(Sources& sources) {
    return [&sources](uint16_t addr) {
        std::string name;
        uint16_t offset = 0;
        if (!sources.resolve_symbol(addr, name, offset)) {
            return std::string();
        }
        return offset == 0 ? name : name + "+" + std::to_string(offset);
    };
}

std::string annotate_symbols(const std::string& text, const Sources& sources) {
    std::string out;
    out.reserve(text.size());
    size_t i = 0;
    while (i < text.size()) {
        // Looking for exactly "0x" + 4 hex digits not followed by another word
        // character -- the shape every 16-bit operand the disassembler emits
        // has, and that no 8-bit one (2 digits) does.
        if (text[i] == '0' && i + 1 < text.size() && text[i + 1] == 'x') {
            const size_t hex_start = i + 2;
            const size_t hex_end = hex_start + 4;
            bool all_hex = hex_end <= text.size();
            for (size_t k = hex_start; all_hex && k < hex_end; k++) {
                all_hex = is_hex_digit(text[k]);
            }
            if (all_hex && !(hex_end < text.size() && is_word_char(text[hex_end]))) {
                const uint16_t addr =
                    uint16_t(std::strtoul(text.substr(hex_start, 4).c_str(), nullptr, 16));
                // The closing paren is emitted BEFORE the annotation, so a
                // memory-indirect operand reads "(0x5C0E) (TVDATA)" rather
                // than nesting the label inside the parentheses.
                const bool closing_paren = hex_end < text.size() && text[hex_end] == ')';
                out += text.substr(i, hex_end - i);
                if (closing_paren) {
                    out += ')';
                }
                std::string name;
                uint16_t offset = 0;
                if (sources.resolve_symbol(addr, name, offset)) {
                    out += " (";
                    out += name;
                    if (offset != 0) {
                        out += '+';
                        out += std::to_string(offset);
                    }
                    out += ')';
                }
                i = hex_end + (closing_paren ? 1 : 0);
                continue;
            }
        }
        out += text[i];
        i++;
    }
    return out;
}

} // namespace zx
