#pragma once
// Minimal test harness. Deliberately not a framework: these tests mostly do
// things a framework doesn't help with (run two CPU cores in lockstep and diff
// them, run ZEXALL to completion), and a header with three macros keeps the
// build free of another vendored dependency.
//
// Usage:
//     #include "test_main.h"
//     TEST(some_name) { CHECK_EQ(a, b); }
//     RUN_TESTS()

#include <cstdio>
#include <string>
#include <vector>

namespace zxtest {

struct TestCase {
    const char* name;
    void (*fn)();
};

inline std::vector<TestCase>& registry() {
    static std::vector<TestCase> tests;
    return tests;
}

inline int& failure_count() {
    static int failures = 0;
    return failures;
}

struct Registrar {
    Registrar(const char* name, void (*fn)()) { registry().push_back({name, fn}); }
};

inline void report_failure(const char* file, int line, const std::string& detail) {
    std::printf("    FAIL %s:%d\n      %s\n", file, line, detail.c_str());
    failure_count()++;
}

/// Values are stringified via to_string where possible so a failure shows the
/// actual numbers, not just "assertion failed".
template <typename T>
std::string describe(const T& value) {
    return std::to_string(value);
}
inline std::string describe(const std::string& value) { return value; }
inline std::string describe(bool value) { return value ? "true" : "false"; }

inline int run_all() {
    int passed = 0;
    for (const TestCase& test : registry()) {
        int before = failure_count();
        test.fn();
        if (failure_count() == before) {
            passed++;
        } else {
            std::printf("  %s FAILED\n", test.name);
        }
    }
    std::printf("%d/%zu tests passed\n", passed, registry().size());
    return failure_count() == 0 ? 0 : 1;
}

} // namespace zxtest

#define TEST(name)                                                             \
    static void name();                                                        \
    static ::zxtest::Registrar registrar_##name(#name, name);                  \
    static void name()

#define CHECK(cond)                                                            \
    do {                                                                       \
        if (!(cond)) {                                                         \
            ::zxtest::report_failure(__FILE__, __LINE__, "expected: " #cond);   \
        }                                                                      \
    } while (0)

#define CHECK_EQ(actual, expected)                                             \
    do {                                                                       \
        auto actual_value_ = (actual);                                         \
        auto expected_value_ = (expected);                                     \
        if (!(actual_value_ == expected_value_)) {                             \
            ::zxtest::report_failure(                                          \
                __FILE__, __LINE__,                                            \
                std::string(#actual) + " == " + #expected                      \
                    + "\n        actual:   " + ::zxtest::describe(actual_value_)  \
                    + "\n        expected: " + ::zxtest::describe(expected_value_)); \
        }                                                                      \
    } while (0)

#define RUN_TESTS()                                                            \
    int main() { return ::zxtest::run_all(); }
