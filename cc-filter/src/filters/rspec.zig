const std = @import("std");
const line_filter = @import("../line_filter.zig");

pub fn filter(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return line_filter.filterLines(allocator, input, shouldKeep);
}

fn shouldKeep(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "Failures:")) return true;
    if (std.mem.startsWith(u8, line, "Failed examples:")) return true;
    if (std.mem.startsWith(u8, line, "Finished in ")) return true;
    if (isSummaryLine(line)) return true;
    if (isNumberedEntry(line)) return true;
    if (std.mem.indexOf(u8, line, "Failure/Error:") != null) return true;
    const trimmed = std.mem.trimLeft(u8, line, " ");
    if (std.mem.startsWith(u8, trimmed, "expected: ") or std.mem.startsWith(u8, trimmed, "got: ")) return true;
    if (std.mem.startsWith(u8, trimmed, "# ")) return true;
    if (std.mem.startsWith(u8, line, "rspec ") and std.mem.indexOf(u8, line, " # ") != null) return true;
    return false;
}

fn isNumberedEntry(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " ");
    if (trimmed.len == line.len) return false;
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) : (i += 1) {}
    if (i == 0) return false;
    if (i + 1 >= trimmed.len) return false;
    return trimmed[i] == ')' and trimmed[i + 1] == ' ';
}

fn isSummaryLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 0) return false;
    if (i >= line.len or line[i] != ' ') return false;
    return std.mem.indexOf(u8, line[i..], " example") != null;
}

test "filter keeps failure block" {
    const allocator = std.testing.allocator;
    const input =
        \\Run options: include {:focus=>true}
        \\
        \\.F.
        \\
        \\Failures:
        \\
        \\  1) Calculator#subtract returns correct difference
        \\     Failure/Error: expect(calc.subtract(5, 3)).to eq(3)
        \\
        \\       expected: 3
        \\            got: 2
        \\
        \\       (compared using ==)
        \\     # ./spec/calculator_spec.rb:12:in `block (3 levels) in <top (required)>'
        \\
        \\Finished in 0.00123 seconds (files took 0.05 seconds to load)
        \\3 examples, 1 failure
        \\
        \\Failed examples:
        \\
        \\rspec ./spec/calculator_spec.rb:10 # Calculator#subtract returns correct difference
    ;
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        \\Failures:
        \\  1) Calculator#subtract returns correct difference
        \\     Failure/Error: expect(calc.subtract(5, 3)).to eq(3)
        \\       expected: 3
        \\            got: 2
        \\     # ./spec/calculator_spec.rb:12:in `block (3 levels) in <top (required)>'
        \\Finished in 0.00123 seconds (files took 0.05 seconds to load)
        \\3 examples, 1 failure
        \\Failed examples:
        \\rspec ./spec/calculator_spec.rb:10 # Calculator#subtract returns correct difference
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "filter keeps only summary on pass" {
    const allocator = std.testing.allocator;
    const input =
        \\Run options: include {:focus=>true}
        \\
        \\...
        \\
        \\Finished in 0.00456 seconds (files took 0.03 seconds to load)
        \\3 examples, 0 failures
    ;
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        \\Finished in 0.00456 seconds (files took 0.03 seconds to load)
        \\3 examples, 0 failures
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "filter handles pending count" {
    const allocator = std.testing.allocator;
    const input =
        \\...P.
        \\
        \\Finished in 0.01 seconds (files took 0.5 seconds to load)
        \\5 examples, 0 failures, 1 pending
    ;
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        \\Finished in 0.01 seconds (files took 0.5 seconds to load)
        \\5 examples, 0 failures, 1 pending
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
