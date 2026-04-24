const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const zig_time = @import("zig_util").time;

// ============================================================
// Constants
// ============================================================

const color_red = "\x1b[0;31m";
const color_green = "\x1b[0;32m";
const color_yellow = "\x1b[1;33m";
const color_blue = "\x1b[0;34m";
const color_reset = "\x1b[0m";

// Single-threaded CLI, so module-level io/env handles keep helper APIs simple.
var g_io: Io = undefined;
var g_env: *const std.process.Environ.Map = undefined;

const categories = [_][]const u8{
    "[タスク] 作業開始・完了",
    "[調査] 調査・分析作業",
    "[学び] 新しい知見、気づき",
    "[問題] バグ、課題の発見",
    "[解決] 問題の解決",
    "[振り返り] 日報、週報など",
    "[会議] ミーティング",
    "[レビュー] コードレビュー",
    "[デプロイ] リリース関連",
    "[アイデア] 今後の改善案",
    "[LLM活用] Claude Code等の活用",
    "[手戻り] 修正・やり直し",
};

const importance_markers = [_][]const u8{
    "なし",
    "⭐ 重要 - 後で振り返りたい重要な出来事",
    "🔥 緊急 - すぐに対応が必要な問題",
    "💡 アイデア - 良いアイデア、ひらめき",
    "✅ 完了 - 大きな成果、達成",
};

const summary_template =
    \\
    \\---
    \\
    \\## 📝 本日のサマリー
    \\
    \\### 完了したこと
    \\- [ ]
    \\
    \\### 学んだこと・気づき
    \\-
    \\
    \\### 明日やること
    \\- [ ]
    \\
    \\### 感情・コンディション
    \\😐 普通 / 集中度: /10
    \\
;

// ============================================================
// Command parsing
// ============================================================

const Command = union(enum) {
    open_editor,
    quick: []const u8,
    interactive,
    positional: []const u8,
    multiline,
    template,
    help,
};

fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) Command {
    if (args.len == 0) return .open_editor;

    const first = args[0];

    if (mem.eql(u8, first, "-h") or mem.eql(u8, first, "--help")) return .help;
    if (mem.eql(u8, first, "-i") or mem.eql(u8, first, "--interactive")) return .interactive;
    if (mem.eql(u8, first, "-t") or mem.eql(u8, first, "--template")) return .template;
    if (mem.eql(u8, first, "-m") or mem.eql(u8, first, "--multiline")) return .multiline;

    if (mem.eql(u8, first, "-q") or mem.eql(u8, first, "--quick")) {
        if (args.len < 2) fatal("メモ内容を指定してください");
        return .{ .quick = joinArgs(allocator, args[1..]) };
    }

    if (first.len > 0 and first[0] == '-') {
        fatal("不明なオプションです。daily -h でヘルプを表示");
    }

    return .{ .positional = joinArgs(allocator, args) };
}

fn joinArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) []const u8 {
    var total: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) total += 1;
        total += arg.len;
    }
    const buf = allocator.alloc(u8, total) catch fatal("out of memory");
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos..][0..arg.len], arg);
        pos += arg.len;
    }
    return buf;
}

// ============================================================
// Output helpers
// ============================================================

fn writeStderr(msg: []const u8) void {
    Io.File.stderr().writeStreamingAll(g_io, msg) catch {};
}

fn writeStdout(msg: []const u8) void {
    Io.File.stdout().writeStreamingAll(g_io, msg) catch {};
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
        color_green ++ "daily" ++ color_reset ++ " - 日記にメモを追加するツール\n" ++
            "\n" ++
            color_yellow ++ "使い方:" ++ color_reset ++ "\n" ++
            "  daily                  エディタで日記を開く\n" ++
            "  daily -i               対話モード（カテゴリー・重要度選択あり）\n" ++
            "  daily \"メモ内容\"        簡易モード（カテゴリー・重要度選択あり）\n" ++
            "  daily -q \"メモ内容\"     クイックモード（カテゴリー選択なし）\n" ++
            "  daily -m               エディタで複数行メモを作成\n" ++
            "  daily -t               日次サマリーテンプレートを追加\n" ++
            "  daily -h, --help       このヘルプを表示\n",
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
    const now_s: i64 = Io.Clock.real.now(g_io).toSeconds();
    const offset = zig_time.getUtcOffsetSeconds(g_io, g_env, allocator, now_s);
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
    const result = std.process.run(allocator, g_io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
    }) catch fatal("gitコマンドの実行に失敗しました");
    switch (result.term) {
        .exited => |code| if (code != 0) {
            fatal("Gitリポジトリが見つかりません");
        },
        else => fatal("Gitリポジトリが見つかりません"),
    }
    return mem.trimEnd(u8, result.stdout, "\n");
}

fn getDailyFilePath(allocator: std.mem.Allocator, lt: LocalTime) []const u8 {
    const repo_root = getRepoRoot(allocator);

    const dir_path = std.fmt.allocPrint(allocator, "{s}/.kokatsu/daily/{d:0>4}/{d:0>2}", .{ repo_root, lt.year, lt.month }) catch fatal("out of memory");
    const file_path = std.fmt.allocPrint(allocator, "{s}/{d:0>4}-{d:0>2}-{d:0>2}.md", .{ dir_path, lt.year, lt.month, lt.day }) catch fatal("out of memory");

    Io.Dir.cwd().createDirPath(g_io, dir_path) catch
        fatal("ディレクトリの作成に失敗しました");

    const file = Io.Dir.openFileAbsolute(g_io, file_path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => {
            const header = std.fmt.allocPrint(allocator, "# {d:0>4}-{d:0>2}-{d:0>2}\n", .{ lt.year, lt.month, lt.day }) catch fatal("out of memory");
            const new_file = Io.Dir.createFileAbsolute(g_io, file_path, .{}) catch fatal("ファイルの作成に失敗しました");
            new_file.writeStreamingAll(g_io, header) catch {};
            new_file.close(g_io);
            return file_path;
        },
        else => fatal("ファイルアクセスエラー"),
    };
    file.close(g_io);
    return file_path;
}

fn appendToFile(file_path: []const u8, data: []const u8) void {
    const file = Io.Dir.openFileAbsolute(g_io, file_path, .{ .mode = .read_write }) catch fatal("ファイルを開けません");
    defer file.close(g_io);

    const len = file.length(g_io) catch fatal("ファイルサイズ取得に失敗しました");
    var buf: [1024]u8 = undefined;
    var writer = file.writerStreaming(g_io, &buf);
    writer.seekTo(len) catch fatal("シークに失敗しました");
    writer.interface.writeAll(data) catch fatal("書き込みに失敗しました");
    writer.interface.flush() catch fatal("書き込みに失敗しました");
}

// ============================================================
// fzf integration
// ============================================================

fn selectWithFzf(allocator: std.mem.Allocator, items: []const []const u8, prompt_text: []const u8, header: []const u8) ?[]const u8 {
    var child = std.process.spawn(g_io, .{
        .argv = &.{ "fzf", "--height=40%", "--border=rounded", prompt_text, header, "--color=header:italic:underline,prompt:bold" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch fatal("fzfの起動に失敗しました");

    const stdin_file = child.stdin.?;
    for (items, 0..) |item, i| {
        if (i > 0) stdin_file.writeStreamingAll(g_io, "\n") catch {};
        stdin_file.writeStreamingAll(g_io, item) catch {};
    }
    child.stdin.?.close(g_io);
    child.stdin = null;

    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(g_io, &read_buf);
    const stdout_data = reader.interface.allocRemaining(allocator, .limited(4096)) catch return null;

    const term = child.wait(g_io) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = mem.trimEnd(u8, stdout_data, "\n\r");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn selectCategory(allocator: std.mem.Allocator) []const u8 {
    const selected = selectWithFzf(
        allocator,
        &categories,
        "--prompt=📌 カテゴリーを選択: ",
        "--header=Ctrl-C でスキップ",
    ) orelse return "";

    if (mem.indexOfScalar(u8, selected, ']')) |end| {
        if (selected[0] == '[') {
            return selected[0 .. end + 1];
        }
    }
    return "";
}

fn selectImportance(allocator: std.mem.Allocator) []const u8 {
    const selected = selectWithFzf(
        allocator,
        &importance_markers,
        "--prompt=🎯 重要度: ",
        "--header=重要度マーカーを選択",
    ) orelse return "";

    if (mem.eql(u8, selected, importance_markers[0])) return "";

    if (mem.indexOfScalar(u8, selected, ' ')) |space_idx| {
        return selected[0..space_idx];
    }
    return selected;
}

// ============================================================
// Memo operations
// ============================================================

fn addMemo(allocator: std.mem.Allocator, category: []const u8, content: []const u8, importance: []const u8) void {
    const lt = getLocalTime(allocator);
    const daily_file = getDailyFilePath(allocator, lt);

    const timestamp = std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second }) catch fatal("out of memory");

    const imp_part = if (importance.len > 0) std.fmt.allocPrint(allocator, "{s} ", .{importance}) catch fatal("out of memory") else "";
    const cat_part = if (category.len > 0) std.fmt.allocPrint(allocator, "{s} ", .{category}) catch fatal("out of memory") else "";
    const entry = std.fmt.allocPrint(allocator, "\n## {s}\n{s}{s}{s}\n", .{ timestamp, imp_part, cat_part, content }) catch fatal("out of memory");

    appendToFile(daily_file, entry);

    const msg = std.fmt.allocPrint(allocator, "メモを追加しました: {s}", .{daily_file}) catch return;
    success(msg);

    const preview = std.fmt.allocPrint(allocator, "内容: {s}{s}{s}", .{ imp_part, cat_part, content }) catch return;
    info(preview);
}

fn spawnEditor(file_path: []const u8) void {
    const editor = g_env.get("EDITOR") orelse "vi";
    var child = std.process.spawn(g_io, .{
        .argv = &.{ editor, file_path },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch fatal("エディタの起動に失敗しました");
    _ = child.wait(g_io) catch {};
}

fn openEditor(allocator: std.mem.Allocator) void {
    const lt = getLocalTime(allocator);
    const daily_file = getDailyFilePath(allocator, lt);
    spawnEditor(daily_file);
}

fn addSummaryTemplate(allocator: std.mem.Allocator) void {
    const lt = getLocalTime(allocator);
    const daily_file = getDailyFilePath(allocator, lt);

    appendToFile(daily_file, summary_template);

    const msg = std.fmt.allocPrint(allocator, "日次サマリーテンプレートを追加しました: {s}", .{daily_file}) catch return;
    success(msg);
}

// ============================================================
// Multiline mode
// ============================================================

fn multilineMode(allocator: std.mem.Allocator) void {
    const category = selectCategory(allocator);
    const importance = selectImportance(allocator);

    const pid = std.posix.system.getpid();
    const ts: i64 = Io.Clock.real.now(g_io).toSeconds();
    const tmpdir = g_env.get("TMPDIR") orelse "/tmp";
    const tmp_path = std.fmt.allocPrint(allocator, "{s}/daily-{d}-{d}.md", .{ tmpdir, pid, ts }) catch fatal("out of memory");

    const tmp_file = Io.Dir.createFileAbsolute(g_io, tmp_path, .{}) catch fatal("一時ファイルの作成に失敗");
    tmp_file.writeStreamingAll(g_io, "# 下記にメモ内容を記入してください\n# この行と上の行は削除されます\n\n\n") catch {};
    tmp_file.close(g_io);
    defer Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};

    spawnEditor(tmp_path);

    const raw_content = blk: {
        const f = Io.Dir.openFileAbsolute(g_io, tmp_path, .{}) catch fatal("一時ファイルの読み込みに失敗");
        defer f.close(g_io);
        var buf: [4096]u8 = undefined;
        var reader = f.readerStreaming(g_io, &buf);
        break :blk reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch fatal("out of memory");
    };

    var lines: std.ArrayList([]const u8) = .empty;
    var iter = mem.splitScalar(u8, raw_content, '\n');
    var past_header = false;
    while (iter.next()) |line| {
        const trimmed = mem.trimStart(u8, line, " \t");
        if (!past_header) {
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            past_header = true;
        }
        lines.append(allocator, line) catch fatal("out of memory");
    }

    // Trim trailing empty lines
    while (lines.items.len > 0 and mem.trimEnd(u8, lines.items[lines.items.len - 1], " \t").len == 0) {
        _ = lines.pop();
    }

    if (lines.items.len == 0) {
        fatal("メモ内容が空です");
    }

    var total_len: usize = 0;
    for (lines.items, 0..) |line, i| {
        if (i > 0) total_len += 1;
        total_len += line.len;
    }
    const content_buf = allocator.alloc(u8, total_len) catch fatal("out of memory");
    var pos: usize = 0;
    for (lines.items, 0..) |line, i| {
        if (i > 0) {
            content_buf[pos] = '\n';
            pos += 1;
        }
        @memcpy(content_buf[pos..][0..line.len], line);
        pos += line.len;
    }

    addMemo(allocator, category, content_buf, importance);
}

// ============================================================
// Interactive mode
// ============================================================

fn interactiveMode(allocator: std.mem.Allocator) void {
    info("対話モードでメモを追加します");

    const category = selectCategory(allocator);
    const importance = selectImportance(allocator);

    writeStdout(color_yellow ++ "メモ内容: " ++ color_reset);

    var buf: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(g_io, &buf);
    const content_raw = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch fatal("入力の読み取りに失敗");
    const content = mem.trimEnd(u8, content_raw, "\n\r");

    if (content.len == 0) {
        fatal("メモ内容が空です");
    }

    addMemo(allocator, category, content, importance);
}

// ============================================================
// Entry point
// ============================================================

pub fn main(init: std.process.Init) void {
    g_io = init.io;
    g_env = init.environ_map;
    mainImpl(init) catch |err| {
        writeStderr(color_red);
        writeStderr("エラー: ");
        writeStderr(@errorName(err));
        writeStderr(color_reset);
        writeStderr("\n");
        std.process.exit(1);
    };
}

fn mainImpl(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const cmd = parseArgs(allocator, args[1..]);

    switch (cmd) {
        .help => showHelp(),
        .open_editor => openEditor(allocator),
        .quick => |text| addMemo(allocator, "", text, ""),
        .interactive => interactiveMode(allocator),
        .positional => |text| {
            const category = selectCategory(allocator);
            const importance = selectImportance(allocator);
            addMemo(allocator, category, text, importance);
        },
        .multiline => multilineMode(allocator),
        .template => addSummaryTemplate(allocator),
    }
}

// ============================================================
// Tests
// ============================================================

test "parseArgs: no args → open_editor" {
    const alloc = std.testing.allocator;
    const cmd = parseArgs(alloc, &.{});
    try std.testing.expect(cmd == .open_editor);
}

test "parseArgs: -h → help" {
    const alloc = std.testing.allocator;
    const cmd = parseArgs(alloc, &.{"-h"});
    try std.testing.expect(cmd == .help);
}

test "parseArgs: --help → help" {
    const alloc = std.testing.allocator;
    const cmd = parseArgs(alloc, &.{"--help"});
    try std.testing.expect(cmd == .help);
}

test "parseArgs: -i → interactive" {
    const alloc = std.testing.allocator;
    const cmd = parseArgs(alloc, &.{"-i"});
    try std.testing.expect(cmd == .interactive);
}

test "parseArgs: -t → template" {
    const alloc = std.testing.allocator;
    const cmd = parseArgs(alloc, &.{"-t"});
    try std.testing.expect(cmd == .template);
}

test "parseArgs: -m → multiline" {
    const alloc = std.testing.allocator;
    const cmd = parseArgs(alloc, &.{"-m"});
    try std.testing.expect(cmd == .multiline);
}

test "parseArgs: -q with text → quick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = parseArgs(arena.allocator(), &.{ "-q", "hello", "world" });
    switch (cmd) {
        .quick => |text| try std.testing.expectEqualStrings("hello world", text),
        else => return error.TestUnexpectedResult,
    }
}

test "parseArgs: positional text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmd = parseArgs(arena.allocator(), &.{"hello world"});
    switch (cmd) {
        .positional => |text| try std.testing.expectEqualStrings("hello world", text),
        else => return error.TestUnexpectedResult,
    }
}
