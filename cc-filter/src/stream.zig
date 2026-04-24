const std = @import("std");
const cargo_test = @import("filters/cargo_test.zig");
const rspec = @import("filters/rspec.zig");
const bun_test = @import("filters/bun_test.zig");
const jest = @import("filters/jest.zig");

const MAX_INPUT: usize = 16 * 1024 * 1024;

pub fn run(allocator: std.mem.Allocator, io: std.Io, kind: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &buf);
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);
    stdin_reader.interface.appendRemaining(allocator, &data, .limited(MAX_INPUT)) catch {};

    const out = try filter(allocator, kind, data.items);
    defer allocator.free(out);
    try std.Io.File.stdout().writeStreamingAll(io, out);
}

pub fn filter(allocator: std.mem.Allocator, kind: []const u8, input: []const u8) ![]u8 {
    const stripped = try stripAnsi(allocator, input);
    defer allocator.free(stripped);
    if (std.mem.eql(u8, kind, "cargo-test")) return cargo_test.filter(allocator, stripped);
    if (std.mem.eql(u8, kind, "rspec")) return rspec.filter(allocator, stripped);
    if (std.mem.eql(u8, kind, "bun-test")) return bun_test.filter(allocator, stripped);
    if (std.mem.eql(u8, kind, "jest")) return jest.filter(allocator, stripped);
    return allocator.dupe(u8, stripped);
}

pub fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != 0x1B) {
            try buf.append(allocator, input[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) break;
        switch (input[i + 1]) {
            '[' => i = skipCsi(input, i + 2),
            ']', 'P', 'X', '^', '_' => i = skipOsc(input, i + 2),
            else => i += 2,
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn skipCsi(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] >= 0x40 and input[i] <= 0x7E) return i + 1;
    }
    return i;
}

fn skipOsc(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] == 0x07) return i + 1;
        if (input[i] == 0x1B and i + 1 < input.len and input[i + 1] == '\\') return i + 2;
    }
    return i;
}

test "filter unknown kind passes through" {
    const allocator = std.testing.allocator;
    const out = try filter(allocator, "unknown", "hello\n");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "filter strips CSI from cargo-test output" {
    const allocator = std.testing.allocator;
    const input = "test foo ... \x1b[31mFAILED\x1b[0m\n";
    const out = try filter(allocator, "cargo-test", input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("test foo ... FAILED\n", out);
}

test "filter strips CSI from rspec output" {
    const allocator = std.testing.allocator;
    const input = "\x1b[31mFailures:\x1b[0m\n";
    const out = try filter(allocator, "rspec", input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Failures:\n", out);
}

test "filter strips OSC from input" {
    const allocator = std.testing.allocator;
    const input = "\x1b]0;title\x07test foo ... FAILED\n";
    const out = try filter(allocator, "cargo-test", input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("test foo ... FAILED\n", out);
}

test "filter strips OSC terminated by ST" {
    const allocator = std.testing.allocator;
    const input = "\x1b]0;title\x1b\\test foo ... FAILED\n";
    const out = try filter(allocator, "cargo-test", input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("test foo ... FAILED\n", out);
}

test "filter strips ANSI for unknown kind too" {
    const allocator = std.testing.allocator;
    const input = "\x1b[31mhello\x1b[0m\n";
    const out = try filter(allocator, "unknown", input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "filter passes non-ANSI input unchanged for cargo-test" {
    const allocator = std.testing.allocator;
    const input = "test foo ... FAILED\n";
    const out = try filter(allocator, "cargo-test", input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("test foo ... FAILED\n", out);
}

test "stripAnsi: passthrough when no ANSI" {
    const out = try stripAnsi(std.testing.allocator, "hello world\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world\n", out);
}

test "stripAnsi: removes complete CSI" {
    const out = try stripAnsi(std.testing.allocator, "a\x1b[31mred\x1b[0mb");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("aredb", out);
}

test "stripAnsi: removes OSC terminated by BEL" {
    const out = try stripAnsi(std.testing.allocator, "x\x1b]0;title\x07y");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}

test "stripAnsi: removes OSC terminated by ST" {
    const out = try stripAnsi(std.testing.allocator, "x\x1b]0;title\x1b\\y");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}

test "stripAnsi: drops incomplete CSI at end of input" {
    const out = try stripAnsi(std.testing.allocator, "abc\x1b[");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "stripAnsi: drops bare ESC at end of input" {
    const out = try stripAnsi(std.testing.allocator, "abc\x1b");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "stripAnsi: empty input" {
    const out = try stripAnsi(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "stripAnsi: two-byte Fe sequence" {
    const out = try stripAnsi(std.testing.allocator, "a\x1bMb");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("ab", out);
}

test "stripAnsi: removes DCS payload terminated by ST" {
    const out = try stripAnsi(std.testing.allocator, "x\x1bPfoo\x1b\\y");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}

test "stripAnsi: removes DCS payload terminated by BEL" {
    const out = try stripAnsi(std.testing.allocator, "x\x1bPfoo\x07y");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}

test "stripAnsi: removes SOS payload" {
    const out = try stripAnsi(std.testing.allocator, "x\x1bXdata\x1b\\y");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}

test "stripAnsi: removes PM payload" {
    const out = try stripAnsi(std.testing.allocator, "x\x1b^msg\x1b\\y");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}

test "stripAnsi: removes APC payload" {
    const out = try stripAnsi(std.testing.allocator, "x\x1b_cmd\x1b\\y");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}
