const std = @import("std");
const rewrite = @import("rewrite.zig");
const ju = @import("zig_util").json;

const MAX_INPUT: usize = 1024 * 1024;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &buf);
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);
    stdin_reader.interface.appendRemaining(allocator, &data, .limited(MAX_INPUT)) catch {};

    const out = try process(allocator, data.items);
    if (out.len > 0) {
        try std.Io.File.stdout().writeStreamingAll(io, out);
    }
}

pub fn process(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return "";
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return "";
    defer parsed.deinit();

    const root = ju.getObj(parsed.value) orelse return "";
    const tool_input = ju.getObjField(root, "tool_input") orelse return "";
    const cmd = if (tool_input.get("command")) |v| ju.getStr(v) orelse return "" else return "";

    const rewritten = try rewrite.apply(allocator, cmd);
    if (rewritten == null) return "";
    defer allocator.free(rewritten.?);

    return try buildHookOutput(allocator, rewritten.?);
}

fn buildHookOutput(allocator: std.mem.Allocator, new_command: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":
    );
    try appendJsonString(allocator, &buf, new_command);
    try buf.appendSlice(allocator, "}}}\n");
    return buf.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const written = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                try buf.appendSlice(allocator, written);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

test "appendJsonString escapes quotes and backslashes" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try appendJsonString(allocator, &buf, "a\"b\\c");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", buf.items);
}

test "appendJsonString escapes newline" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try appendJsonString(allocator, &buf, "line1\nline2");
    try std.testing.expectEqualStrings("\"line1\\nline2\"", buf.items);
}

test "process passthrough when no match" {
    const allocator = std.testing.allocator;
    const input =
        \\{"tool_input":{"command":"echo hi"}}
    ;
    const out = try process(allocator, input);
    defer if (out.len > 0) allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "process handles empty input" {
    const out = try process(std.testing.allocator, "");
    try std.testing.expectEqualStrings("", out);
}

test "process handles invalid json" {
    const out = try process(std.testing.allocator, "{broken");
    try std.testing.expectEqualStrings("", out);
}

test "process rewrites git status" {
    const allocator = std.testing.allocator;
    const input =
        \\{"tool_input":{"command":"git status"}}
    ;
    const out = try process(allocator, input);
    defer allocator.free(out);
    const expected =
        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"git status --short"}}}
    ++ "\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "process rewrites ls with args" {
    const allocator = std.testing.allocator;
    const input =
        \\{"tool_input":{"command":"ls -la"}}
    ;
    const out = try process(allocator, input);
    defer allocator.free(out);
    const expected =
        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"ls --color=never -1 -la | head -50"}}}
    ++ "\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "process escapes quote in rewritten command" {
    const allocator = std.testing.allocator;
    const input =
        \\{"tool_input":{"command":"git log --grep=\"foo\""}}
    ;
    const out = try process(allocator, input);
    defer allocator.free(out);
    const expected =
        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"git log --oneline -n 15 --grep=\"foo\""}}}
    ++ "\n";
    try std.testing.expectEqualStrings(expected, out);
}
