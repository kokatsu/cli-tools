const std = @import("std");
const line_filter = @import("../line_filter.zig");

pub fn filter(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return line_filter.filterLines(allocator, input, shouldKeep);
}

fn shouldKeep(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "test ") and std.mem.endsWith(u8, line, " ... FAILED")) return true;
    if (std.mem.startsWith(u8, line, "thread '") and std.mem.indexOf(u8, line, " panicked at ") != null) return true;
    if (std.mem.startsWith(u8, line, "assertion ")) return true;
    if (std.mem.startsWith(u8, line, "test result:")) return true;
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (std.mem.startsWith(u8, trimmed, "left: ") or std.mem.startsWith(u8, trimmed, "right: ")) return true;
    if (std.mem.startsWith(u8, line, "error[")) return true;
    return false;
}

test "filter keeps only failure info" {
    const allocator = std.testing.allocator;
    const input =
        \\    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.02s
        \\     Running unittests src/lib.rs (target/debug/deps/mylib-abc)
        \\
        \\running 3 tests
        \\test tests::test_add ... ok
        \\test tests::test_subtract ... FAILED
        \\test tests::test_multiply ... ok
        \\
        \\failures:
        \\
        \\---- tests::test_subtract stdout ----
        \\thread 'tests::test_subtract' panicked at src/lib.rs:42:5:
        \\assertion `left == right` failed
        \\  left: 5
        \\ right: 3
        \\note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
        \\
        \\
        \\failures:
        \\    tests::test_subtract
        \\
        \\test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
        \\
        \\error: test failed, to rerun pass `--lib`
    ;
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        \\test tests::test_subtract ... FAILED
        \\thread 'tests::test_subtract' panicked at src/lib.rs:42:5:
        \\assertion `left == right` failed
        \\  left: 5
        \\ right: 3
        \\test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "filter keeps only summary for passing run" {
    const allocator = std.testing.allocator;
    const input =
        \\    Finished `test` profile in 0.02s
        \\
        \\running 2 tests
        \\test tests::test_a ... ok
        \\test tests::test_b ... ok
        \\
        \\test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
    ;
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        \\test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "filter keeps compile errors" {
    const allocator = std.testing.allocator;
    const input =
        \\    Compiling mylib v0.1.0
        \\error[E0308]: mismatched types
        \\  --> src/lib.rs:10:5
        \\error: could not compile `mylib`
    ;
    const out = try filter(allocator, input);
    defer allocator.free(out);
    const expected =
        \\error[E0308]: mismatched types
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
