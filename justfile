zig_dirs := "cc-statusline cc-filter daily memo zig-util"

default:
    @just --list

# Run all checks (CI equivalent)
check: zig-check zig-test cc-filter-scan
    @set -e; for dir in {{ zig_dirs }}; do \
      echo "zig fmt --check: $dir"; \
      (cd "$dir" && zig fmt --check .); \
    done
    alejandra -c .

# Format Zig and Nix files
fmt:
    @set -e; for dir in {{ zig_dirs }}; do \
      echo "zig fmt: $dir"; \
      (cd "$dir" && zig fmt .); \
    done
    alejandra -q .

# Build all Zig projects
zig-build:
    @set -e; for dir in {{ zig_dirs }}; do \
      echo "zig build: $dir"; \
      (cd "$dir" && zig build); \
    done

# Check all Zig projects (Debug build)
zig-check:
    @set -e; for dir in {{ zig_dirs }}; do \
      echo "zig check: $dir"; \
      (cd "$dir" && zig build -Doptimize=Debug 2>&1); \
    done

# Test all Zig projects
zig-test:
    @set -e; for dir in {{ zig_dirs }}; do \
      echo "zig build test: $dir"; \
      (cd "$dir" && zig build test); \
    done

# Scan cc-filter for forbidden patterns (std.net, std.process.Child)
cc-filter-scan:
    @if grep -rnE 'std\.net|std\.process\.Child|@import\("std"\)\.net|@import\("std"\)\.process\.Child' cc-filter/src/; then \
      echo "ERROR: cc-filter must not use std.net or std.process.Child (including reflective forms)"; \
      exit 1; \
    fi
    @echo "OK: cc-filter has no forbidden patterns"
