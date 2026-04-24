const std = @import("std");

pub fn filterLines(
    allocator: std.mem.Allocator,
    input: []const u8,
    comptime keep: fn ([]const u8) bool,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |line| {
        if (keep(line)) {
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
    }
    return buf.toOwnedSlice(allocator);
}

test "filterLines keeps matching lines" {
    const allocator = std.testing.allocator;
    const keep = struct {
        fn f(line: []const u8) bool {
            return std.mem.startsWith(u8, line, "keep");
        }
    }.f;
    const out = try filterLines(allocator, "keep1\ndrop\nkeep2\n", keep);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("keep1\nkeep2\n", out);
}

test "filterLines empty input with non-matching predicate" {
    const allocator = std.testing.allocator;
    const keep = struct {
        fn f(line: []const u8) bool {
            return line.len > 0;
        }
    }.f;
    const out = try filterLines(allocator, "", keep);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}
