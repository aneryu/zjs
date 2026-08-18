#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for the zjs (QuickJS -> Zig) engine.
# Installs the mise-pinned Zig 0.16.0 toolchain, checks out the test262
# submodule used by the validation ladder, and warms the Debug build cache.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

MISE_BIN="$HOME/.local/bin/mise"

# 1. Install mise (version manager pinned by mise.toml) if it is missing.
if [ ! -x "$MISE_BIN" ]; then
  curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# 2. Make the mise-managed toolchain resolvable in the agent's shells.
#    ~/.profile already sources ~/.bashrc for bash, so this covers both
#    login and interactive non-login shells.
MARKER="# >>> zjs toolchain (mise) >>>"
if ! grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
  {
    echo ""
    echo "$MARKER"
    echo 'export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"'
    echo "# <<< zjs toolchain (mise) <<<"
  } >> "$HOME/.bashrc"
fi

# 3. Install the pinned Zig toolchain (mise.toml: zig = 0.16.0) and refresh shims.
mise trust "$REPO_DIR" >/dev/null
mise install
mise reshim

# 4. Check out the test262 submodule (shallow) used by the test262 gate.
#    Skipped automatically when it is already populated.
if [ ! -e "$REPO_DIR/test262/test" ]; then
  git submodule update --init --depth 1 test262
fi

# 5. Warm the Debug inner-loop build cache so the first agent build is fast.
mise exec -- zig build zjs-dev --seed 0 --summary all

echo "zjs Cloud Agent environment ready: $(mise exec -- zig version)"
