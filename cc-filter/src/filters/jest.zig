const std = @import("std");
const line_filter = @import("../line_filter.zig");

const BULLET = "● ";

pub fn filter(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return line_filter.filterLines(allocator, input, shouldKeep);
}

fn shouldKeep(line: []const u8) bool {
    if (isFailHeader(line)) return true;
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (std.mem.startsWith(u8, trimmed, BULLET)) return true;
    if (std.mem.startsWith(u8, trimmed, "Expected:")) return true;
    if (std.mem.startsWith(u8, trimmed, "Received:")) return true;
    if (std.mem.startsWith(u8, trimmed, "at ") and std.mem.indexOf(u8, trimmed, "(") != null) return true;
    if (std.mem.startsWith(u8, line, "Test Suites:")) return true;
    if (std.mem.startsWith(u8, line, "Tests:")) return true;
    return false;
}

fn isFailHeader(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    return std.mem.startsWith(u8, trimmed, "FAIL ");
}

test "filter keeps failure block" {
    const allocator = std.testing.allocator;
    const input =
        " FAIL  src/calculator.test.js\n" ++
        "  Calculator\n" ++
        "    \xE2\x9C\x93 adds numbers (2ms)\n" ++
        "    \xE2\x9C\x95 subtracts numbers (3ms)\n" ++
        "\n" ++
        "  \xE2\x97\x8F Calculator \xE2\x80\xBA subtracts numbers\n" ++
        "\n" ++
        "    expect(received).toBe(expected)\n" ++
        "\n" ++
        "    Expected: 3\n" ++
        "    Received: 2\n" ++
        "\n" ++
        "      10 |     test('subtracts numbers', () => {\n" ++
        "      11 |         const result = subtract(5, 3);\n" ++
        "    > 12 |         expect(result).toBe(3);\n" ++
        "         |                        ^\n" ++
        "      13 |     });\n" ++
        "\n" ++
        "      at Object.<anonymous> (src/calculator.test.js:12:24)\n" ++
        "\n" ++
        "Test Suites: 1 failed, 1 total\n" ++
        "Tests:       1 failed, 1 passed, 2 total\n" ++
        "Snapshots:   0 total\n" ++
        "Time:        1.234s\n" ++
        "Ran all test suites.\n";
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        " FAIL  src/calculator.test.js\n" ++
        "  \xE2\x97\x8F Calculator \xE2\x80\xBA subtracts numbers\n" ++
        "    Expected: 3\n" ++
        "    Received: 2\n" ++
        "      at Object.<anonymous> (src/calculator.test.js:12:24)\n" ++
        "Test Suites: 1 failed, 1 total\n" ++
        "Tests:       1 failed, 1 passed, 2 total\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "filter keeps only summary on pass" {
    const allocator = std.testing.allocator;
    const input =
        " PASS  src/math.test.js\n" ++
        "  math\n" ++
        "    \xE2\x9C\x93 adds (2ms)\n" ++
        "\n" ++
        "Test Suites: 1 passed, 1 total\n" ++
        "Tests:       1 passed, 1 total\n" ++
        "Snapshots:   0 total\n" ++
        "Time:        0.789s\n" ++
        "Ran all test suites.\n";
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        "Test Suites: 1 passed, 1 total\n" ++
        "Tests:       1 passed, 1 total\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "filter empty input" {
    const allocator = std.testing.allocator;
    const out = try filter(allocator, "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}
