const std = @import("std");
const hook = @import("hook.zig");
const stream = @import("stream.zig");

const Usage =
    \\cc-filter - Claude Code Bash output compressor
    \\
    \\USAGE:
    \\  cc-filter hook              Read Claude Code hook JSON on stdin, emit rewritten tool_input.
    \\  cc-filter stream -k <kind>  Filter command output on stdin by kind.
    \\
    \\STREAM KINDS:
    \\  cargo-test  rspec  bun-test  jest
    \\
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    if (args.len < 2) {
        try std.fs.File.stderr().writeAll(Usage);
        std.process.exit(2);
    }

    const sub = args[1];
    if (std.mem.eql(u8, sub, "hook")) {
        try hook.run(allocator);
    } else if (std.mem.eql(u8, sub, "stream")) {
        const kind = parseStreamKind(args[2..]) orelse {
            try std.fs.File.stderr().writeAll("cc-filter: stream requires -k <kind>\n");
            std.process.exit(2);
        };
        try stream.run(allocator, kind);
    } else if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        try std.fs.File.stdout().writeAll(Usage);
    } else {
        try std.fs.File.stderr().writeAll(Usage);
        std.process.exit(2);
    }
}

fn parseStreamKind(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-k") or std.mem.eql(u8, args[i], "--kind")) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
    }
    return null;
}

test {
    _ = @import("hook.zig");
    _ = @import("stream.zig");
    _ = @import("rewrite.zig");
    _ = @import("line_filter.zig");
    _ = @import("filters/cargo_test.zig");
    _ = @import("filters/rspec.zig");
    _ = @import("filters/bun_test.zig");
    _ = @import("filters/jest.zig");
}

test "parseStreamKind finds -k" {
    const args = [_][]const u8{ "-k", "cargo-test" };
    try std.testing.expectEqualStrings("cargo-test", parseStreamKind(&args).?);
}

test "parseStreamKind returns null without -k" {
    const args = [_][]const u8{"cargo-test"};
    try std.testing.expect(parseStreamKind(&args) == null);
}

test "parseStreamKind returns null when -k has no value" {
    const args = [_][]const u8{"-k"};
    try std.testing.expect(parseStreamKind(&args) == null);
}
