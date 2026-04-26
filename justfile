zig_dirs := "cc-statusline daily memo zig-util"

default:
    @just --list

# Run all checks (CI equivalent)
check: zig-check zig-test
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
