#include "logpoint.h"

#include "register_names.h"
#include "spectrum.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>

namespace zx {
namespace {

std::string trimmed(const std::string& s) {
    size_t start = 0;
    size_t end = s.size();
    while (start < end && std::isspace(uint8_t(s[start]))) {
        start++;
    }
    while (end > start && std::isspace(uint8_t(s[end - 1]))) {
        end--;
    }
    return s.substr(start, end - start);
}

/// A number written 0x.., $.. or in decimal, all of it. False for anything
/// else, which is then tried as a register or a symbol.
bool parse_number(const std::string& s, uint32_t& value) {
    if (s.empty()) {
        return false;
    }
    int base = 10;
    size_t start = 0;
    if (s[0] == '$') {
        base = 16;
        start = 1;
    } else if (s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        start = 2;
    }
    if (start >= s.size()) {
        return false;
    }
    char* end = nullptr;
    const unsigned long v = std::strtoul(s.c_str() + start, &end, base);
    if (end != s.c_str() + s.size() || v > 0xFFFF) {
        return false;
    }
    value = uint32_t(v);
    return true;
}

/// The address part of a {(...)} hole: a pair, a number or a symbol, with an
/// optional +n or -n after it.
bool parse_address(const std::string& inside, const SymbolResolver& resolve, LogSegment& seg,
                   std::string& error) {
    std::string base = inside;
    int32_t offset = 0;
    // The last + or - past the first character is the offset's; a leading
    // one would be part of nothing we accept anyway.
    const size_t sign = inside.find_last_of("+-");
    if (sign != std::string::npos && sign > 0) {
        uint32_t n = 0;
        if (!parse_number(trimmed(inside.substr(sign + 1)), n)) {
            error = "\"" + inside + "\": the offset is not a number";
            return false;
        }
        offset = inside[sign] == '-' ? -int32_t(n) : int32_t(n);
        base = trimmed(inside.substr(0, sign));
    }
    uint32_t number = 0;
    if (parse_number(base, number)) {
        seg.text.clear();
        seg.addr = uint16_t(number + uint32_t(offset));
        return true;
    }
    if (register_width(base) == 16) {
        seg.text = base;
        seg.addr = uint16_t(offset);
        return true;
    }
    uint16_t symbol = 0;
    if (resolve && resolve(base, symbol)) {
        seg.text.clear();
        seg.addr = uint16_t(symbol + offset);
        return true;
    }
    error = "\"" + base + "\" is not a register pair, a number or a known symbol";
    return false;
}

/// One {...} hole, without its braces.
bool parse_hole(const std::string& raw, const SymbolResolver& resolve, LogSegment& seg,
                std::string& error) {
    std::string body = trimmed(raw);
    std::string format;
    const size_t colon = body.rfind(':');
    if (colon != std::string::npos) {
        format = trimmed(body.substr(colon + 1));
        body = trimmed(body.substr(0, colon));
    }
    if (body.size() >= 2 && body.front() == '(' && body.back() == ')') {
        seg.kind = LogSegment::Kind::Memory;
        if (!parse_address(trimmed(body.substr(1, body.size() - 2)), resolve, seg, error)) {
            return false;
        }
        if (!format.empty() && (format[0] == 'w' || format[0] == 'W')) {
            seg.word = true;
            format = format.substr(1);
        }
    } else {
        if (register_width(body) == 0) {
            error = "\"" + body + "\" is not a register -- memory is written {(" + body + ")}";
            return false;
        }
        seg.kind = LogSegment::Kind::Register;
        seg.text = body;
    }
    if (format.empty()) {
        seg.format = 'x';
    } else if (format == "x" || format == "d" || format == "c") {
        seg.format = format[0];
    } else {
        error = "\":" + format + "\" is not a format: :x, :d or :c, and :w before one for a word";
        return false;
    }
    return true;
}

std::string hex(uint32_t value, int digits) {
    char buf[8];
    std::snprintf(buf, sizeof buf, digits > 2 ? "0x%04X" : "0x%02X", unsigned(value));
    return buf;
}

std::string character(uint32_t value) {
    const uint8_t c = uint8_t(value);
    if (c == 0x0D) {
        return "\n";
    }
    if (c >= 0x20 && c < 0x7F) {
        return std::string(1, char(c));
    }
    char buf[8];
    std::snprintf(buf, sizeof buf, "\\x%02X", unsigned(c));
    return buf;
}

} // namespace

bool parse_log_message(const std::string& text, const SymbolResolver& resolve,
                       std::vector<LogSegment>& out, std::string& error) {
    out.clear();
    std::string literal;
    size_t i = 0;
    while (i < text.size()) {
        const char c = text[i];
        if (c == '{' && i + 1 < text.size() && text[i + 1] == '{') {
            literal.push_back('{');
            i += 2;
            continue;
        }
        if (c == '}' && i + 1 < text.size() && text[i + 1] == '}') {
            literal.push_back('}');
            i += 2;
            continue;
        }
        if (c == '}') {
            error = "a } with no { before it -- a brace on its own is written }}";
            return false;
        }
        if (c != '{') {
            literal.push_back(c);
            i++;
            continue;
        }
        const size_t close = text.find('}', i + 1);
        if (close == std::string::npos) {
            error = "a { with no } after it -- a brace on its own is written {{";
            return false;
        }
        if (!literal.empty()) {
            LogSegment seg;
            seg.text = literal;
            out.push_back(seg);
            literal.clear();
        }
        LogSegment seg;
        if (!parse_hole(text.substr(i + 1, close - i - 1), resolve, seg, error)) {
            return false;
        }
        out.push_back(seg);
        i = close + 1;
    }
    if (!literal.empty()) {
        LogSegment seg;
        seg.text = literal;
        out.push_back(seg);
    }
    return true;
}

std::string format_log_message(const std::vector<LogSegment>& message, Spectrum& m) {
    std::string out;
    const Registers r = m.registers();
    for (const LogSegment& seg : message) {
        uint32_t value = 0;
        int digits = 2;
        if (seg.kind == LogSegment::Kind::Text) {
            out += seg.text;
            continue;
        }
        if (seg.kind == LogSegment::Kind::Register) {
            get_register(r, seg.text, value);
            digits = register_width(seg.text) == 16 ? 4 : 2;
        } else {
            uint32_t base = 0;
            if (!seg.text.empty()) {
                get_register(r, seg.text, base);
            }
            const uint16_t at = uint16_t(base + seg.addr);
            const std::vector<uint8_t> bytes = m.read_memory(at, seg.word ? 2 : 1);
            value = bytes[0];
            if (seg.word) {
                value |= uint32_t(bytes[1]) << 8;
                digits = 4;
            }
        }
        if (seg.format == 'd') {
            out += std::to_string(value);
        } else if (seg.format == 'c') {
            out += character(value);
        } else {
            out += hex(value, digits);
        }
    }
    return out;
}

} // namespace zx
