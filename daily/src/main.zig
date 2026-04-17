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

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) Command {
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

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) []const u8 {
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

fn getDailyFilePath(allocator: std.mem.Allocator, lt: LocalTime) []const u8 {
    const repo_root = getRepoRoot(allocator);

    const dir_path = std.fmt.allocPrint(allocator, "{s}/.kokatsu/daily/{d:0>4}/{d:0>2}", .{ repo_root, lt.year, lt.month }) catch fatal("out of memory");
    const file_path = std.fmt.allocPrint(allocator, "{s}/{d:0>4}-{d:0>2}-{d:0>2}.md", .{ dir_path, lt.year, lt.month, lt.day }) catch fatal("out of memory");

    fs.cwd().makePath(dir_path) catch
        fatal("ディレクトリの作成に失敗しました");

    const file = fs.openFileAbsolute(file_path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => {
            const header = std.fmt.allocPrint(allocator, "# {d:0>4}-{d:0>2}-{d:0>2}\n", .{ lt.year, lt.month, lt.day }) catch fatal("out of memory");
            const new_file = fs.createFileAbsolute(file_path, .{}) catch fatal("ファイルの作成に失敗しました");
            new_file.writeAll(header) catch {};
            new_file.close();
            return file_path;
        },
        else => fatal("ファイルアクセスエラー"),
    };
    file.close();
    return file_path;
}

// ============================================================
// fzf integration
// ============================================================

fn selectWithFzf(allocator: std.mem.Allocator, items: []const []const u8, prompt_text: []const u8, header: []const u8) ?[]const u8 {
    var child = std.process.Child.init(&.{ "fzf", "--height=40%", "--border=rounded", prompt_text, header, "--color=header:italic:underline,prompt:bold" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch fatal("fzfの起動に失敗しました");

    const stdin_file = child.stdin.?;
    for (items, 0..) |item, i| {
        if (i > 0) stdin_file.writeAll("\n") catch {};
        stdin_file.writeAll(item) catch {};
    }
    child.stdin.?.close();
    child.stdin = null;

    const stdout_data = child.stdout.?.readToEndAlloc(allocator, 4096) catch return null;

    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = mem.trimRight(u8, stdout_data, "\n\r");
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

    const file = fs.openFileAbsolute(daily_file, .{ .mode = .write_only }) catch fatal("ファイルを開けません");
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll(entry) catch fatal("書き込みに失敗しました");

    const msg = std.fmt.allocPrint(allocator, "メモを追加しました: {s}", .{daily_file}) catch return;
    success(msg);

    const preview = std.fmt.allocPrint(allocator, "内容: {s}{s}{s}", .{ imp_part, cat_part, content }) catch return;
    info(preview);
}

fn spawnEditor(allocator: std.mem.Allocator, file_path: []const u8) void {
    const editor = posix.getenv("EDITOR") orelse "vi";
    var child = std.process.Child.init(&.{ editor, file_path }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch fatal("エディタの起動に失敗しました");
    _ = child.wait() catch {};
}

fn openEditor(allocator: std.mem.Allocator) void {
    const lt = getLocalTime(allocator);
    const daily_file = getDailyFilePath(allocator, lt);
    spawnEditor(allocator, daily_file);
}

fn addSummaryTemplate(allocator: std.mem.Allocator) void {
    const lt = getLocalTime(allocator);
    const daily_file = getDailyFilePath(allocator, lt);

    const file = fs.openFileAbsolute(daily_file, .{ .mode = .write_only }) catch fatal("ファイルを開けません");
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll(summary_template) catch fatal("書き込みに失敗しました");

    const msg = std.fmt.allocPrint(allocator, "日次サマリーテンプレートを追加しました: {s}", .{daily_file}) catch return;
    success(msg);
}

// ============================================================
// Multiline mode
// ============================================================

fn multilineMode(allocator: std.mem.Allocator) void {
    const category = selectCategory(allocator);
    const importance = selectImportance(allocator);

    const pid = posix.system.getpid();
    const ts = std.time.timestamp();
    const tmpdir = posix.getenv("TMPDIR") orelse "/tmp";
    const tmp_path = std.fmt.allocPrint(allocator, "{s}/daily-{d}-{d}.md", .{ tmpdir, pid, ts }) catch fatal("out of memory");

    const tmp_file = fs.createFileAbsolute(tmp_path, .{}) catch fatal("一時ファイルの作成に失敗");
    tmp_file.writeAll("# 下記にメモ内容を記入してください\n# この行と上の行は削除されます\n\n\n") catch {};
    tmp_file.close();
    defer fs.deleteFileAbsolute(tmp_path) catch {};

    spawnEditor(allocator, tmp_path);

    const raw_content = blk: {
        const f = fs.openFileAbsolute(tmp_path, .{}) catch fatal("一時ファイルの読み込みに失敗");
        defer f.close();
        break :blk f.readToEndAlloc(allocator, 1024 * 1024) catch fatal("out of memory");
    };

    var lines: std.ArrayList([]const u8) = .{};
    var iter = mem.splitScalar(u8, raw_content, '\n');
    var past_header = false;
    while (iter.next()) |line| {
        const trimmed = mem.trimLeft(u8, line, " \t");
        if (!past_header) {
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            past_header = true;
        }
        lines.append(allocator, line) catch fatal("out of memory");
    }

    // Trim trailing empty lines
    while (lines.items.len > 0 and mem.trimRight(u8, lines.items[lines.items.len - 1], " \t").len == 0) {
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

    const stdin_file = fs.File{ .handle = posix.STDIN_FILENO };
    const content_raw = stdin_file.readToEndAlloc(allocator, 1024 * 1024) catch fatal("入力の読み取りに失敗");
    const content = mem.trimRight(u8, content_raw, "\n\r");

    if (content.len == 0) {
        fatal("メモ内容が空です");
    }

    addMemo(allocator, category, content, importance);
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
    const cmd = parseArgs(arena.allocator(), &.{ "hello", "world" });
    switch (cmd) {
        .positional => |text| try std.testing.expectEqualStrings("hello world", text),
        else => return error.TestUnexpectedResult,
    }
}

test "joinArgs: single arg" {
    const alloc = std.testing.allocator;
    const result = joinArgs(alloc, &.{"hello"});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "joinArgs: multiple args" {
    const alloc = std.testing.allocator;
    const result = joinArgs(alloc, &.{ "hello", "beautiful", "world" });
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello beautiful world", result);
}
