const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const posix = std.posix;
const zig_time = @import("zig_util").time;

// ============================================================
// Constants
// ============================================================

const color_red = "\x1b[0;31m";
const color_green = "\x1b[0;32m";
const color_yellow = "\x1b[1;33m";
const color_blue = "\x1b[0;34m";
const color_reset = "\x1b[0m";

// ============================================================
// Command parsing
// ============================================================

const Command = enum {
    create,
    help,
};

const ParsedArgs = struct {
    cmd: Command,
    local: bool = false,
};

fn parseArgs(args: []const []const u8) ParsedArgs {
    if (args.len == 0) return .{ .cmd = .create };

    const first = args[0];
    if (mem.eql(u8, first, "-h") or mem.eql(u8, first, "--help")) return .{ .cmd = .help };
    if (mem.eql(u8, first, "--local")) return .{ .cmd = .create, .local = true };

    fatal("不明なオプションです。memo -h でヘルプを表示");
}

// ============================================================
// Output helpers
// ============================================================

fn writeStderr(msg: []const u8) void {
    const f = fs.File{ .handle = posix.STDERR_FILENO };
    f.writeAll(msg) catch {};
}

fn writeStdout(msg: []const u8) void {
    const f = fs.File{ .handle = posix.STDOUT_FILENO };
    f.writeAll(msg) catch {};
}

fn fatal(msg: []const u8) noreturn {
    writeStderr(color_red);
    writeStderr("エラー: ");
    writeStderr(msg);
    writeStderr(color_reset);
    writeStderr("\n");
    std.process.exit(1);
}

fn success(msg: []const u8) void {
    writeStderr(color_green);
    writeStderr("✓ ");
    writeStderr(msg);
    writeStderr(color_reset);
    writeStderr("\n");
}

fn info(msg: []const u8) void {
    writeStderr(color_blue);
    writeStderr("ℹ ");
    writeStderr(msg);
    writeStderr(color_reset);
    writeStderr("\n");
}

fn showHelp() void {
    writeStdout(
        color_green ++ "memo" ++ color_reset ++ " - タイムスタンプ付き単独メモを作成するツール\n" ++
            "\n" ++
            color_yellow ++ "使い方:" ++ color_reset ++ "\n" ++
            "  memo              新規メモファイルを作成してエディタで開く\n" ++
            "  memo --local      ローカル専用メモ (.local.md) を作成して開く\n" ++
            "  memo -h, --help   このヘルプを表示\n" ++
            "\n" ++
            color_yellow ++ "保存先:" ++ color_reset ++ "\n" ++
            "  <repo>/.kokatsu/memo/YYYY/MM/DD/YYYY-MM-DD-HHMMSS.md\n" ++
            "  <repo>/.kokatsu/memo/YYYY/MM/DD/YYYY-MM-DD-HHMMSS.local.md  (--local)\n",
    );
}

// ============================================================
// Local time
// ============================================================

// Zig の {d:0>4} は i32 正値に '+' を prefix するため u32 にキャストして吸収する
const LocalTime = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn getLocalTime(allocator: std.mem.Allocator) LocalTime {
    const now_s = std.time.timestamp();
    const offset = zig_time.getUtcOffsetSeconds(allocator, now_s);
    const local_s = now_s + @as(i64, offset);
    const civil = zig_time.epochToCivil(local_s);
    return .{
        .year = @intCast(civil.year),
        .month = civil.month,
        .day = civil.day,
        .hour = civil.hour,
        .minute = civil.minute,
        .second = civil.second,
    };
}

// ============================================================
// Git / file operations
// ============================================================

fn getRepoRoot(allocator: std.mem.Allocator) []const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
    }) catch fatal("gitコマンドの実行に失敗しました");
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            fatal("Gitリポジトリが見つかりません");
        },
        else => fatal("Gitリポジトリが見つかりません"),
    }
    return mem.trimRight(u8, result.stdout, "\n");
}

fn getMemoFilePath(allocator: std.mem.Allocator, lt: LocalTime, local: bool) []const u8 {
    const repo_root = getRepoRoot(allocator);

    const dir_path = std.fmt.allocPrint(allocator, "{s}/.kokatsu/memo/{d:0>4}/{d:0>2}/{d:0>2}", .{ repo_root, lt.year, lt.month, lt.day }) catch fatal("out of memory");
    const suffix: []const u8 = if (local) ".local.md" else ".md";
    const file_path = std.fmt.allocPrint(allocator, "{s}/{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}{s}", .{ dir_path, lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second, suffix }) catch fatal("out of memory");

    fs.cwd().makePath(dir_path) catch
        fatal("ディレクトリの作成に失敗しました");

    return file_path;
}

// ============================================================
// Editor / memo creation
// ============================================================

fn spawnEditor(allocator: std.mem.Allocator, file_path: []const u8) void {
    const editor = posix.getenv("EDITOR") orelse "vi";
    var child = std.process.Child.init(&.{ editor, file_path }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch fatal("エディタの起動に失敗しました");
    _ = child.wait() catch {};
}

fn createMemo(allocator: std.mem.Allocator, local: bool) void {
    const lt = getLocalTime(allocator);
    const file_path = getMemoFilePath(allocator, lt, local);

    // `.exclusive = true` で既存ファイルを上書きしないようにする。
    // 1 秒以内に 2 回実行されて衝突した場合は、既存ファイルを開くだけで終わる。
    const file = fs.createFileAbsolute(file_path, .{ .exclusive = true }) catch |e| switch (e) {
        error.PathAlreadyExists => {
            const msg = std.fmt.allocPrint(allocator, "既存ファイルを開きます: {s}", .{file_path}) catch return;
            info(msg);
            spawnEditor(allocator, file_path);
            return;
        },
        else => fatal("ファイルの作成に失敗しました"),
    };
    const header = std.fmt.allocPrint(allocator, "# {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n\n", .{ lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second }) catch fatal("out of memory");
    file.writeAll(header) catch fatal("書き込みに失敗しました");
    file.close();

    const msg = std.fmt.allocPrint(allocator, "メモを作成しました: {s}", .{file_path}) catch return;
    success(msg);

    spawnEditor(allocator, file_path);
}

// ============================================================
// Entry point
// ============================================================

pub fn main() void {
    mainImpl() catch |err| {
        writeStderr(color_red);
        writeStderr("エラー: ");
        writeStderr(@errorName(err));
        writeStderr(color_reset);
        writeStderr("\n");
        std.process.exit(1);
    };
}

fn mainImpl() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    const parsed = parseArgs(args[1..]);

    switch (parsed.cmd) {
        .help => showHelp(),
        .create => createMemo(allocator, parsed.local),
    }
}

// ============================================================
// Tests
// ============================================================

test "parseArgs: no args → create" {
    const parsed = parseArgs(&.{});
    try std.testing.expect(parsed.cmd == .create);
    try std.testing.expect(parsed.local == false);
}

test "parseArgs: -h → help" {
    const parsed = parseArgs(&.{"-h"});
    try std.testing.expect(parsed.cmd == .help);
}

test "parseArgs: --help → help" {
    const parsed = parseArgs(&.{"--help"});
    try std.testing.expect(parsed.cmd == .help);
}

test "parseArgs: --local → create with local" {
    const parsed = parseArgs(&.{"--local"});
    try std.testing.expect(parsed.cmd == .create);
    try std.testing.expect(parsed.local == true);
}
