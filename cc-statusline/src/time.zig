const std = @import("std");
const zig_time = @import("zig_util").time;

pub const daysFromCivil = zig_time.daysFromCivil;

// ============================================================
// ISO 8601 Parser
// ============================================================

pub fn parseIso8601ToMs(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't') or s[13] != ':' or s[16] != ':') return null;

    const year = parseDecimal(s[0..4]) orelse return null;
    const month = parseDecimal(s[5..7]) orelse return null;
    const day = parseDecimal(s[8..10]) orelse return null;
    const hour = parseDecimal(s[11..13]) orelse return null;
    const minute = parseDecimal(s[14..16]) orelse return null;
    const second = parseDecimal(s[17..19]) orelse return null;

    var millis: i64 = 0;
    if (s.len > 19 and s[19] == '.') {
        var pos: usize = 20;
        var mult: i64 = 100;
        while (pos < s.len and s[pos] >= '0' and s[pos] <= '9' and mult > 0) : (pos += 1) {
            millis += @as(i64, s[pos] - '0') * mult;
            mult = @divFloor(mult, 10);
        }
    }

    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    const epoch_s = days * 86400 + @as(i64, @intCast(hour)) * 3600 + @as(i64, @intCast(minute)) * 60 + @as(i64, @intCast(second));
    return epoch_s * 1000 + millis;
}

fn parseDecimal(s: []const u8) ?i64 {
    var result: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = std.math.mul(i64, result, 10) catch return null;
        result = std.math.add(i64, result, @as(i64, c - '0')) catch return null;
    }
    return result;
}

pub fn computeLocalDayStartMs(now_ms: i64, utc_offset_s: i32) i64 {
    const now_s = @divFloor(now_ms, @as(i64, 1000));
    const offset_s: i64 = @intCast(utc_offset_s);
    const local_s = now_s + offset_s;
    const local_day_start_s = @divFloor(local_s, @as(i64, 86400)) * 86400;
    return (local_day_start_s - offset_s) * 1000;
}

/// Get the start of today in milliseconds (local timezone, pure Zig)
pub fn getLocalDayStartMs(io: std.Io, env: *const std.process.Environ.Map, allocator: std.mem.Allocator, now_ms: i64) i64 {
    const now_s = @divFloor(now_ms, @as(i64, 1000));
    const offset_s = zig_time.getUtcOffsetSeconds(io, env, allocator, now_s);
    return computeLocalDayStartMs(now_ms, offset_s);
}

pub fn floorToHourMs(ms: i64) i64 {
    const ms_per_hour: i64 = 3600 * 1000;
    return @divFloor(ms, ms_per_hour) * ms_per_hour;
}

// ============================================================
// Tests
// ============================================================

test "parseIso8601ToMs" {
    const ts1 = parseIso8601ToMs("2025-01-15T10:30:00Z").?;
    const expected1: i64 = (daysFromCivil(2025, 1, 15) * 86400 + 10 * 3600 + 30 * 60) * 1000;
    try std.testing.expectEqual(expected1, ts1);

    const ts2 = parseIso8601ToMs("2025-01-15T10:30:00.123Z").?;
    try std.testing.expectEqual(expected1 + 123, ts2);

    try std.testing.expectEqual(@as(?i64, null), parseIso8601ToMs("invalid"));
    try std.testing.expectEqual(@as(?i64, null), parseIso8601ToMs(""));
}

test "parseDecimal overflow" {
    try std.testing.expectEqual(@as(?i64, 12345), parseDecimal("12345"));
    try std.testing.expectEqual(@as(?i64, 0), parseDecimal("0"));
    try std.testing.expectEqual(@as(?i64, null), parseDecimal("99999999999999999999"));
    try std.testing.expectEqual(@as(?i64, null), parseDecimal("12a3"));
    try std.testing.expectEqual(@as(?i64, 0), parseDecimal(""));
}

test "daysFromCivil re-export smoke test" {
    // Full coverage lives in zig-util.time; this just guards the re-export.
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
}

test "floorToHourMs" {
    const ms = 3600 * 1000 + 30 * 60 * 1000 + 15 * 1000;
    try std.testing.expectEqual(@as(i64, 3600 * 1000), floorToHourMs(ms));
    try std.testing.expectEqual(@as(i64, 0), floorToHourMs(0));
}

test "getLocalDayStartMs returns valid day boundary" {
    const now_ms: i64 = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const day_start = getLocalDayStartMs(std.testing.io, &env, std.testing.allocator, now_ms);
    try std.testing.expect(day_start <= now_ms);
    try std.testing.expect(now_ms - day_start < 86400 * 1000);
    const diff_ms = day_start - @divFloor(day_start, @as(i64, 1000)) * 1000;
    try std.testing.expectEqual(@as(i64, 0), diff_ms);
}

test "computeLocalDayStartMs UTC" {
    const now_ms: i64 = (daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600 + 30 * 60) * 1000;
    const day_start = computeLocalDayStartMs(now_ms, 0);
    const expected: i64 = daysFromCivil(2025, 6, 15) * 86400 * 1000;
    try std.testing.expectEqual(expected, day_start);
}

test "computeLocalDayStartMs JST +9h" {
    const now_ms: i64 = (daysFromCivil(2025, 6, 15) * 86400 + 2 * 3600) * 1000;
    const day_start = computeLocalDayStartMs(now_ms, 32400);
    const expected: i64 = (daysFromCivil(2025, 6, 14) * 86400 + 15 * 3600) * 1000;
    try std.testing.expectEqual(expected, day_start);
}

test "computeLocalDayStartMs EST -5h" {
    const now_ms: i64 = (daysFromCivil(2025, 6, 15) * 86400 + 3 * 3600) * 1000;
    const day_start = computeLocalDayStartMs(now_ms, -18000);
    const expected: i64 = (daysFromCivil(2025, 6, 14) * 86400 + 5 * 3600) * 1000;
    try std.testing.expectEqual(expected, day_start);
}

test "computeLocalDayStartMs result is multiple of 1000" {
    const now_ms: i64 = (daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600) * 1000 + 500;
    const day_start = computeLocalDayStartMs(now_ms, 32400);
    try std.testing.expectEqual(@as(i64, 0), @mod(day_start, 1000));
}

// --- parseIso8601ToMs edge cases ---

test "parseIso8601ToMs lowercase t separator" {
    const ts = parseIso8601ToMs("2025-01-15t10:30:00Z").?;
    const expected: i64 = (daysFromCivil(2025, 1, 15) * 86400 + 10 * 3600 + 30 * 60) * 1000;
    try std.testing.expectEqual(expected, ts);
}

test "parseIso8601ToMs milliseconds 1 digit" {
    const ts = parseIso8601ToMs("2025-01-15T00:00:00.1Z").?;
    const base: i64 = daysFromCivil(2025, 1, 15) * 86400 * 1000;
    try std.testing.expectEqual(base + 100, ts);
}

test "parseIso8601ToMs milliseconds 2 digits" {
    const ts = parseIso8601ToMs("2025-01-15T00:00:00.12Z").?;
    const base: i64 = daysFromCivil(2025, 1, 15) * 86400 * 1000;
    try std.testing.expectEqual(base + 120, ts);
}

test "parseIso8601ToMs milliseconds 4+ digits truncated" {
    const ts = parseIso8601ToMs("2025-01-15T00:00:00.1234Z").?;
    const base: i64 = daysFromCivil(2025, 1, 15) * 86400 * 1000;
    try std.testing.expectEqual(base + 123, ts);
}

test "parseIso8601ToMs leap year Feb 29" {
    const ts = parseIso8601ToMs("2024-02-29T00:00:00Z").?;
    const expected: i64 = daysFromCivil(2024, 2, 29) * 86400 * 1000;
    try std.testing.expectEqual(expected, ts);
}

// --- floorToHourMs edge cases ---

test "floorToHourMs negative timestamp" {
    try std.testing.expectEqual(@as(i64, -3600000), floorToHourMs(-1));
}

test "floorToHourMs exactly on hour boundary" {
    try std.testing.expectEqual(@as(i64, 3600000), floorToHourMs(3600000));
}

test "floorToHourMs negative exactly on hour" {
    try std.testing.expectEqual(@as(i64, -3600000), floorToHourMs(-3600000));
}
