const std = @import("std");
const line_filter = @import("../line_filter.zig");

const FAIL_MARK = "✗ ";

pub fn filter(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return line_filter.filterLines(allocator, input, shouldKeep);
}

fn shouldKeep(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    if (std.mem.startsWith(u8, trimmed, "(fail) ")) return true;
    if (std.mem.startsWith(u8, trimmed, FAIL_MARK)) return true;
    if (std.mem.startsWith(u8, line, "error:")) return true;
    if (std.mem.startsWith(u8, trimmed, "Expected: ")) return true;
    if (std.mem.startsWith(u8, trimmed, "Received: ")) return true;
    if (std.mem.startsWith(u8, trimmed, "at ")) return true;
    if (isCountLine(trimmed, " pass")) return true;
    if (isCountLine(trimmed, " fail")) return true;
    if (std.mem.startsWith(u8, line, "Ran ") and std.mem.indexOf(u8, line, " tests") != null) return true;
    return false;
}

fn isCountLine(trimmed: []const u8, suffix: []const u8) bool {
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) : (i += 1) {}
    if (i == 0) return false;
    return std.mem.eql(u8, trimmed[i..], suffix);
}

test "filter keeps failure output" {
    const allocator = std.testing.allocator;
    const input =
        \\bun test v1.1.0
        \\
        \\src/add.test.ts:
        \\(pass) add > adds positives [0.10ms]
        \\(fail) add > handles zero [0.30ms]
        \\error: expect(received).toBe(expected)
        \\
        \\Expected: 0
        \\Received: 1
        \\
        \\      at /home/user/proj/src/add.test.ts:8:23
        \\      at processTicksAndRejections (node:internal/process/task_queues:95:5)
        \\
        \\ 1 pass
        \\ 1 fail
        \\ 1 expect() calls
        \\Ran 2 tests across 1 files. [15.00ms]
    ;
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        \\(fail) add > handles zero [0.30ms]
        \\error: expect(received).toBe(expected)
        \\Expected: 0
        \\Received: 1
        \\      at /home/user/proj/src/add.test.ts:8:23
        \\      at processTicksAndRejections (node:internal/process/task_queues:95:5)
        \\ 1 pass
        \\ 1 fail
        \\Ran 2 tests across 1 files. [15.00ms]
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "filter keeps only counts on pass" {
    const allocator = std.testing.allocator;
    const input =
        \\bun test v1.1.0
        \\
        \\src/add.test.ts:
        \\(pass) add > adds positives [0.10ms]
        \\(pass) add > adds negatives [0.05ms]
        \\
        \\ 2 pass
        \\ 0 fail
        \\ 1 expect() calls
        \\Ran 2 tests across 1 files. [15.00ms]
    ;
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        \\ 2 pass
        \\ 0 fail
        \\Ran 2 tests across 1 files. [15.00ms]
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "filter empty input" {
    const allocator = std.testing.allocator;
    const out = try filter(allocator, "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}
