# cc-filter

A PreToolUse hook that compresses Claude Code Bash tool output. Only rewrites allowlisted commands; test output is filtered down to failures only.

## Build

```sh
zig build -Doptimize=ReleaseSafe
```

Binary is output to `zig-out/bin/cc-filter`. Via Nix, `home-manager switch` builds it automatically.

## Usage

### Mode 1: `cc-filter hook` (PreToolUse hook)

Reads Claude Code hook JSON from stdin and returns `hookSpecificOutput.updatedInput` to stdout. Env var prefixes (`VAR=value cmd`, multiple supported) are preserved across the rewrite.

```sh
echo '{"tool_input":{"command":"git status"}}' | cc-filter hook
# => {"hookSpecificOutput":{...,"updatedInput":{"command":"git status --short"}}}

echo '{"tool_input":{"command":"RUST_LOG=debug cargo test"}}' | cc-filter hook
# => updatedInput.command: RUST_LOG=debug cargo test 2>&1 | cc-filter stream -k cargo-test
```

### Mode 2: `cc-filter stream -k <kind>` (pipe filter)

Reads raw command output from stdin and compresses it by `kind`-specific rules. ANSI escape sequences (CSI / OSC / DCS / SOS / PM / APC) are stripped before filtering.

```sh
cargo test 2>&1 | cc-filter stream -k cargo-test
```

Supported `kind`: `cargo-test`, `rspec`, `bun-test`, `jest`

## Rewrite Rules

| Original | Rewritten |
|---|---|
| `git status` | `git status --short` |
| `git log [args]` | `git log --oneline -n 15 [args]` |
| `git diff [args]` | `git diff --stat [args]` |
| `git add <args>` | `git add <args> && echo ok` |
| `git push [args]` | `{ git push [args] 2>&1 \| tail -3; }` |
| `ls [args]` | `ls --color=never -1 [args] \| head -50` |
| `tree [args]` | `tree -L 2 --noreport [args]` |
| `cargo test [args]` | `cargo test [args] 2>&1 \| cc-filter stream -k cargo-test` |
| `rspec [args]` | `rspec [args] 2>&1 \| cc-filter stream -k rspec` |
| `bundle exec rspec [args]` | `bundle exec rspec [args] 2>&1 \| cc-filter stream -k rspec` |
| `bun test [args]` | `bun test [args] 2>&1 \| cc-filter stream -k bun-test` |
| `jest [args]` | `jest [args] 2>&1 \| cc-filter stream -k jest` |

## Skip Conditions

The hook leaves the command unchanged (passthrough) when:

- The command contains shell metacharacters: `|`, `;`, `&`, `>`, `<`, `` ` ``, `$(`
- The command starts with `cc-filter` (prevents double-wrap)
- `git add` is invoked with no arguments
- An output-shape flag is already present (idempotency guard):

| Command | Skip if any of these flags is present |
|---|---|
| `git status` | `--short`, `-s`, `--porcelain`, `-z` |
| `git log` | `--oneline`, `--pretty`, `--format`, `-n`, `--max-count`, `-p`, `--patch` |
| `git diff` | `--stat`, `--shortstat`, `--numstat`, `--dirstat`, `--name-only`, `--name-status`, `-p`, `--patch` |
| `ls` | `-1` |
| `tree` | `-L`, `--level` |

Flag detection accepts exact tokens, `--flag=value` form, and combined short forms (`-n5`).

## Claude Code Integration

Add to `PreToolUse.Bash` in `~/.config/claude/settings.json`:

```json
{
  "matcher": "Bash",
  "hooks": [
    {"type": "command", "command": "cc-filter hook"}
  ]
}
```

**Note**: If you have blocking hooks, register them before cc-filter so they run first.

## Test

```sh
zig build test --summary all
```
