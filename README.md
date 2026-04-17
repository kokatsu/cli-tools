# cli-tools

自作 CLI ツール集 (Zig 実装)。`kokatsu/dotfiles` から切り出されたモノレポ。

## Tools

| Tool | Description |
|---|---|
| [`cc-filter`](./cc-filter) | Claude Code PreToolUse hook: Bash 出力の圧縮と危険パターン検知 |
| [`cc-statusline`](./cc-statusline) | Claude Code statusline: git/usage/rate-limit 情報を高速描画 |
| [`daily`](./daily) | 日記メモツール |
| [`memo`](./memo) | タイムスタンプ付き単独メモツール |
| [`zig-util`](./zig-util) | 共通ユーティリティモジュール (json, time 等) |

## Build

Nix (flakes):

```sh
nix build .#cc-filter
nix build .#cc-statusline
nix build .#daily
nix build .#memo
```

Dev shell:

```sh
nix develop
cd cc-filter && zig build test
```

`just` タスク:

```sh
just zig-build
just zig-test
just zig-check
```

## Consume from another flake

```nix
# flake.nix
inputs.cli-tools = {
  url = "github:kokatsu/cli-tools";
  inputs.nixpkgs.follows = "nixpkgs";
};

# overlay
nixpkgs.overlays = [inputs.cli-tools.overlays.default];
```
