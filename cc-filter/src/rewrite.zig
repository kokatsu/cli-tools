const std = @import("std");

const Rule = struct {
    prefix: []const u8,
    empty: []const u8,
    with_args: []const u8,
    require_args: bool = false,
    skip_if_has_flags: []const []const u8 = &.{},
};

const ARGS_PLACEHOLDER = "%ARGS%";

const GIT_STATUS_SKIP = [_][]const u8{ "--short", "-s", "--porcelain", "-z" };
const GIT_LOG_SKIP = [_][]const u8{ "--oneline", "--pretty", "--format", "-n", "--max-count", "-p", "--patch" };
const GIT_DIFF_SKIP = [_][]const u8{ "--stat", "--shortstat", "--numstat", "--dirstat", "--name-only", "--name-status", "-p", "--patch" };
const LS_SKIP = [_][]const u8{"-1"};
const TREE_SKIP = [_][]const u8{ "-L", "--level" };

const RULES = [_]Rule{
    .{ .prefix = "bundle exec rspec", .empty = "bundle exec rspec 2>&1 | cc-filter stream -k rspec", .with_args = "bundle exec rspec %ARGS% 2>&1 | cc-filter stream -k rspec" },
    .{ .prefix = "git status", .empty = "git status --short", .with_args = "git status --short %ARGS%", .skip_if_has_flags = &GIT_STATUS_SKIP },
    .{ .prefix = "git log", .empty = "git log --oneline -n 15", .with_args = "git log --oneline -n 15 %ARGS%", .skip_if_has_flags = &GIT_LOG_SKIP },
    .{ .prefix = "git diff", .empty = "git diff --stat", .with_args = "git diff --stat %ARGS%", .skip_if_has_flags = &GIT_DIFF_SKIP },
    .{ .prefix = "git add", .empty = "", .with_args = "git add %ARGS% && echo ok", .require_args = true },
    .{ .prefix = "git push", .empty = "{ git push 2>&1 | tail -3; }", .with_args = "{ git push %ARGS% 2>&1 | tail -3; }" },
    .{ .prefix = "cargo test", .empty = "cargo test 2>&1 | cc-filter stream -k cargo-test", .with_args = "cargo test %ARGS% 2>&1 | cc-filter stream -k cargo-test" },
    .{ .prefix = "bun test", .empty = "bun test 2>&1 | cc-filter stream -k bun-test", .with_args = "bun test %ARGS% 2>&1 | cc-filter stream -k bun-test" },
    .{ .prefix = "rspec", .empty = "rspec 2>&1 | cc-filter stream -k rspec", .with_args = "rspec %ARGS% 2>&1 | cc-filter stream -k rspec" },
    .{ .prefix = "jest", .empty = "jest 2>&1 | cc-filter stream -k jest", .with_args = "jest %ARGS% 2>&1 | cc-filter stream -k jest" },
    .{ .prefix = "ls", .empty = "ls --color=never -1 | head -50", .with_args = "ls --color=never -1 %ARGS% | head -50", .skip_if_has_flags = &LS_SKIP },
    .{ .prefix = "tree", .empty = "tree -L 2 --noreport", .with_args = "tree -L 2 --noreport %ARGS%", .skip_if_has_flags = &TREE_SKIP },
};

pub fn apply(allocator: std.mem.Allocator, command: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\n\r");
    if (trimmed.len == 0) return null;

    if (hasShellMeta(trimmed)) return null;
    if (std.mem.startsWith(u8, trimmed, "cc-filter")) return null;

    const split = stripEnvPrefix(trimmed);
    if (split.rest.len == 0) return null;
    if (std.mem.startsWith(u8, split.rest, "cc-filter")) return null;

    for (RULES) |rule| {
        const args = stripPrefix(split.rest, rule.prefix) orelse continue;
        if (args.len == 0) {
            if (rule.require_args) return null;
            return try prependEnv(allocator, split.env, rule.empty);
        }
        if (hasAnyFlag(args, rule.skip_if_has_flags)) return null;
        const rewritten = try substitute(allocator, rule.with_args, args);
        defer allocator.free(rewritten);
        return try prependEnv(allocator, split.env, rewritten);
    }

    return null;
}

fn hasAnyFlag(args: []const u8, flags: []const []const u8) bool {
    if (flags.len == 0) return false;
    var iter = std.mem.tokenizeAny(u8, args, " \t");
    while (iter.next()) |token| {
        for (flags) |flag| {
            if (matchesFlag(token, flag)) return true;
        }
    }
    return false;
}

fn matchesFlag(token: []const u8, flag: []const u8) bool {
    if (std.mem.eql(u8, token, flag)) return true;
    if (std.mem.startsWith(u8, flag, "--")) {
        if (std.mem.startsWith(u8, token, flag) and token.len > flag.len and token[flag.len] == '=') return true;
        return false;
    }
    if (flag.len == 2 and flag[0] == '-' and std.mem.startsWith(u8, token, flag) and token.len > 2) {
        return true;
    }
    return false;
}

fn prependEnv(allocator: std.mem.Allocator, env: []const u8, body: []const u8) ![]u8 {
    if (env.len == 0) return allocator.dupe(u8, body);
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, env);
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, body);
    return buf.toOwnedSlice(allocator);
}

const EnvSplit = struct { env: []const u8, rest: []const u8 };

fn stripEnvPrefix(input: []const u8) EnvSplit {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const next = parseOneEnvAssignment(input, cursor) orelse break;
        cursor = next;
        cursor = skipSpaces(input, cursor);
    }
    const env_end = std.mem.trimRight(u8, input[0..cursor], " ").len;
    return .{ .env = input[0..env_end], .rest = input[cursor..] };
}

fn parseOneEnvAssignment(input: []const u8, start: usize) ?usize {
    var i = start;
    if (i >= input.len) return null;
    if (!(std.ascii.isAlphabetic(input[i]) or input[i] == '_')) return null;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) : (i += 1) {}
    if (i >= input.len or input[i] != '=') return null;
    i += 1;
    while (i < input.len and input[i] != ' ' and input[i] != '\t') : (i += 1) {
        if (input[i] == '"' or input[i] == '\'') return null;
    }
    return i;
}

fn skipSpaces(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}
    return i;
}

fn substitute(allocator: std.mem.Allocator, template: []const u8, args: []const u8) ![]u8 {
    const idx = std.mem.indexOf(u8, template, ARGS_PLACEHOLDER) orelse return allocator.dupe(u8, template);
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, template[0..idx]);
    try buf.appendSlice(allocator, args);
    try buf.appendSlice(allocator, template[idx + ARGS_PLACEHOLDER.len ..]);
    return buf.toOwnedSlice(allocator);
}

fn stripPrefix(input: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, input, prefix)) return "";
    if (std.mem.startsWith(u8, input, prefix) and input.len > prefix.len and input[prefix.len] == ' ') {
        return std.mem.trimLeft(u8, input[prefix.len..], " ");
    }
    return null;
}

fn hasShellMeta(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '|', ';', '`', '&', '>', '<' => return true,
            '$' => if (i + 1 < s.len and s[i + 1] == '(') return true,
            else => {},
        }
    }
    return false;
}

test "apply: git status" {
    const out = try apply(std.testing.allocator, "git status");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git status --short", out.?);
}

test "apply: git status with args" {
    const out = try apply(std.testing.allocator, "git status -uno");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git status --short -uno", out.?);
}

test "apply: git log" {
    const out = try apply(std.testing.allocator, "git log");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git log --oneline -n 15", out.?);
}

test "apply: git log with args" {
    const out = try apply(std.testing.allocator, "git log --author=me");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git log --oneline -n 15 --author=me", out.?);
}

test "apply: git diff" {
    const out = try apply(std.testing.allocator, "git diff");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git diff --stat", out.?);
}

test "apply: git diff with args" {
    const out = try apply(std.testing.allocator, "git diff HEAD~1");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git diff --stat HEAD~1", out.?);
}

test "apply: git add with args" {
    const out = try apply(std.testing.allocator, "git add foo.txt");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git add foo.txt && echo ok", out.?);
}

test "apply: git add without args returns null" {
    const out = try apply(std.testing.allocator, "git add");
    try std.testing.expect(out == null);
}

test "apply: git push" {
    const out = try apply(std.testing.allocator, "git push");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("{ git push 2>&1 | tail -3; }", out.?);
}

test "apply: git push with args" {
    const out = try apply(std.testing.allocator, "git push origin main");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("{ git push origin main 2>&1 | tail -3; }", out.?);
}

test "apply: ls" {
    const out = try apply(std.testing.allocator, "ls");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("ls --color=never -1 | head -50", out.?);
}

test "apply: ls with args" {
    const out = try apply(std.testing.allocator, "ls -la");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("ls --color=never -1 -la | head -50", out.?);
}

test "apply: tree" {
    const out = try apply(std.testing.allocator, "tree");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("tree -L 2 --noreport", out.?);
}

test "apply: tree with args" {
    const out = try apply(std.testing.allocator, "tree src");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("tree -L 2 --noreport src", out.?);
}

test "apply: unknown command returns null" {
    const out = try apply(std.testing.allocator, "echo hi");
    try std.testing.expect(out == null);
}

test "apply: unknown git subcommand returns null" {
    const out = try apply(std.testing.allocator, "git foo");
    try std.testing.expect(out == null);
}

test "apply: skip when contains pipe" {
    const out = try apply(std.testing.allocator, "ls | grep foo");
    try std.testing.expect(out == null);
}

test "apply: skip when contains &&" {
    const out = try apply(std.testing.allocator, "git status && echo done");
    try std.testing.expect(out == null);
}

test "apply: skip when contains background &" {
    const out = try apply(std.testing.allocator, "git status &");
    try std.testing.expect(out == null);
}

test "apply: skip when contains semicolon" {
    const out = try apply(std.testing.allocator, "git status; echo");
    try std.testing.expect(out == null);
}

test "apply: skip when contains backtick" {
    const out = try apply(std.testing.allocator, "git log `cat a`");
    try std.testing.expect(out == null);
}

test "apply: skip when contains command substitution" {
    const out = try apply(std.testing.allocator, "git log $(cat a)");
    try std.testing.expect(out == null);
}

test "apply: skip when contains stdout redirect" {
    const out = try apply(std.testing.allocator, "git log > out.txt");
    try std.testing.expect(out == null);
}

test "apply: skip when contains append redirect" {
    const out = try apply(std.testing.allocator, "ls >> log.txt");
    try std.testing.expect(out == null);
}

test "apply: skip when contains stdin redirect" {
    const out = try apply(std.testing.allocator, "git diff < patch.txt");
    try std.testing.expect(out == null);
}

test "apply: skip when contains heredoc" {
    const out = try apply(std.testing.allocator, "git diff << EOF");
    try std.testing.expect(out == null);
}

test "apply: skip cc-filter prefixed" {
    const out = try apply(std.testing.allocator, "cc-filter hook");
    try std.testing.expect(out == null);
}

test "apply: ls does not match lsof" {
    const out = try apply(std.testing.allocator, "lsof -i");
    try std.testing.expect(out == null);
}

test "apply: empty command returns null" {
    const out = try apply(std.testing.allocator, "");
    try std.testing.expect(out == null);
}

test "apply: whitespace-only returns null" {
    const out = try apply(std.testing.allocator, "   ");
    try std.testing.expect(out == null);
}

test "apply: cargo test" {
    const out = try apply(std.testing.allocator, "cargo test");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("cargo test 2>&1 | cc-filter stream -k cargo-test", out.?);
}

test "apply: cargo test with args" {
    const out = try apply(std.testing.allocator, "cargo test --lib foo");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("cargo test --lib foo 2>&1 | cc-filter stream -k cargo-test", out.?);
}

test "apply: bun test" {
    const out = try apply(std.testing.allocator, "bun test");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("bun test 2>&1 | cc-filter stream -k bun-test", out.?);
}

test "apply: bun test with args" {
    const out = try apply(std.testing.allocator, "bun test src/foo.test.ts");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("bun test src/foo.test.ts 2>&1 | cc-filter stream -k bun-test", out.?);
}

test "apply: rspec" {
    const out = try apply(std.testing.allocator, "rspec");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("rspec 2>&1 | cc-filter stream -k rspec", out.?);
}

test "apply: rspec with args" {
    const out = try apply(std.testing.allocator, "rspec spec/foo_spec.rb");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("rspec spec/foo_spec.rb 2>&1 | cc-filter stream -k rspec", out.?);
}

test "apply: bundle exec rspec" {
    const out = try apply(std.testing.allocator, "bundle exec rspec");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("bundle exec rspec 2>&1 | cc-filter stream -k rspec", out.?);
}

test "apply: bundle exec rspec with args" {
    const out = try apply(std.testing.allocator, "bundle exec rspec spec/foo_spec.rb");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("bundle exec rspec spec/foo_spec.rb 2>&1 | cc-filter stream -k rspec", out.?);
}

test "apply: bundle without rspec returns null" {
    const out = try apply(std.testing.allocator, "bundle install");
    try std.testing.expect(out == null);
}

test "apply: jest" {
    const out = try apply(std.testing.allocator, "jest");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("jest 2>&1 | cc-filter stream -k jest", out.?);
}

test "apply: jest with args" {
    const out = try apply(std.testing.allocator, "jest --coverage");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("jest --coverage 2>&1 | cc-filter stream -k jest", out.?);
}

test "apply: longest match wins for bundle exec rspec" {
    const out = try apply(std.testing.allocator, "bundle exec rspec --tag slow");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("bundle exec rspec --tag slow 2>&1 | cc-filter stream -k rspec", out.?);
}

test "apply: env prefix preserved on pipe injection" {
    const out = try apply(std.testing.allocator, "RUST_LOG=debug cargo test");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("RUST_LOG=debug cargo test 2>&1 | cc-filter stream -k cargo-test", out.?);
}

test "apply: env prefix preserved on simple replacement" {
    const out = try apply(std.testing.allocator, "LANG=C git status");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("LANG=C git status --short", out.?);
}

test "apply: multiple env prefixes preserved" {
    const out = try apply(std.testing.allocator, "A=1 B=2 cargo test --lib");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("A=1 B=2 cargo test --lib 2>&1 | cc-filter stream -k cargo-test", out.?);
}

test "apply: env prefix only without command returns null" {
    const out = try apply(std.testing.allocator, "FOO=bar");
    try std.testing.expect(out == null);
}

test "apply: env prefix with unknown command returns null" {
    const out = try apply(std.testing.allocator, "FOO=bar echo hi");
    try std.testing.expect(out == null);
}

test "apply: env prefix with quoted value bails" {
    const out = try apply(std.testing.allocator, "FOO=\"bar baz\" git status");
    try std.testing.expect(out == null);
}

test "apply: env prefix with empty value" {
    const out = try apply(std.testing.allocator, "FOO= git status");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("FOO= git status --short", out.?);
}

test "apply: skip git status with --short" {
    const out = try apply(std.testing.allocator, "git status --short");
    try std.testing.expect(out == null);
}

test "apply: skip git status with -s" {
    const out = try apply(std.testing.allocator, "git status -s");
    try std.testing.expect(out == null);
}

test "apply: skip git status with --porcelain" {
    const out = try apply(std.testing.allocator, "git status --porcelain");
    try std.testing.expect(out == null);
}

test "apply: skip git log with --oneline" {
    const out = try apply(std.testing.allocator, "git log --oneline");
    try std.testing.expect(out == null);
}

test "apply: skip git log with -n separated value" {
    const out = try apply(std.testing.allocator, "git log -n 5");
    try std.testing.expect(out == null);
}

test "apply: skip git log with -n combined value" {
    const out = try apply(std.testing.allocator, "git log -n5");
    try std.testing.expect(out == null);
}

test "apply: skip git log with --pretty equals" {
    const out = try apply(std.testing.allocator, "git log --pretty=full");
    try std.testing.expect(out == null);
}

test "apply: skip git log with --max-count" {
    const out = try apply(std.testing.allocator, "git log --max-count=10");
    try std.testing.expect(out == null);
}

test "apply: skip git diff with --stat" {
    const out = try apply(std.testing.allocator, "git diff --stat");
    try std.testing.expect(out == null);
}

test "apply: skip git diff with --name-only" {
    const out = try apply(std.testing.allocator, "git diff --name-only");
    try std.testing.expect(out == null);
}

test "apply: skip git diff with -p" {
    const out = try apply(std.testing.allocator, "git diff -p HEAD~1");
    try std.testing.expect(out == null);
}

test "apply: skip ls with -1" {
    const out = try apply(std.testing.allocator, "ls -1");
    try std.testing.expect(out == null);
}

test "apply: ls with -l still rewrites (volume not affected)" {
    const out = try apply(std.testing.allocator, "ls -l");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("ls --color=never -1 -l | head -50", out.?);
}

test "apply: skip tree with -L" {
    const out = try apply(std.testing.allocator, "tree -L 3");
    try std.testing.expect(out == null);
}

test "apply: skip tree with --level" {
    const out = try apply(std.testing.allocator, "tree --level=3");
    try std.testing.expect(out == null);
}

test "apply: git log with non-shape flag still rewrites" {
    const out = try apply(std.testing.allocator, "git log --author=me");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git log --oneline -n 15 --author=me", out.?);
}

test "apply: git diff with path still rewrites" {
    const out = try apply(std.testing.allocator, "git diff HEAD~1");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("git diff --stat HEAD~1", out.?);
}

test "apply: ls with path still rewrites" {
    const out = try apply(std.testing.allocator, "ls /tmp");
    defer if (out) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("ls --color=never -1 /tmp | head -50", out.?);
}

test "apply: idempotency works with env prefix" {
    const out = try apply(std.testing.allocator, "GIT_PAGER=cat git log --oneline");
    try std.testing.expect(out == null);
}
