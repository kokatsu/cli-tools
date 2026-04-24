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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        try std.Io.File.stderr().writeStreamingAll(io, Usage);
        std.process.exit(2);
    }

    const sub = args[1];
    if (std.mem.eql(u8, sub, "hook")) {
        try hook.run(allocator, io);
    } else if (std.mem.eql(u8, sub, "stream")) {
        const kind = parseStreamKind(args[2..]) orelse {
            try std.Io.File.stderr().writeStreamingAll(io, "cc-filter: stream requires -k <kind>\n");
            std.process.exit(2);
        };
        try stream.run(allocator, io, kind);
    } else if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        try std.Io.File.stdout().writeStreamingAll(io, Usage);
    } else {
        try std.Io.File.stderr().writeStreamingAll(io, Usage);
        std.process.exit(2);
    }
}

fn parseStreamKind(args: []const [:0]const u8) ?[]const u8 {
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
    const args = [_][:0]const u8{ "-k", "cargo-test" };
    try std.testing.expectEqualStrings("cargo-test", parseStreamKind(&args).?);
}

test "parseStreamKind returns null without -k" {
    const args = [_][:0]const u8{"cargo-test"};
    try std.testing.expect(parseStreamKind(&args) == null);
}

test "parseStreamKind returns null when -k has no value" {
    const args = [_][:0]const u8{"-k"};
    try std.testing.expect(parseStreamKind(&args) == null);
}
