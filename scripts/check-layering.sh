#!/bin/sh
# check-layering.sh
#
# Enforces the import rules from docs/fun_zjs_subtree_architecture.md §20.
# Only the six listed locations may directly import the zjs engine.
#
# Usage: ./scripts/check-layering.sh
# Exit status 0 = clean, non-zero = violations.

set -eu

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

# Patterns that indicate a direct import of the engine (forbidden outside allowed dirs).
PATTERN='@import("quickjs_zig_engine")|@import("zjs_engine")'

# Allowed directory/file prefixes (checked via grep -v on the path portion of grep -nH output).
# We match on the beginning of the "path:line:content" line produced by grep -R.
ALLOWED='^[^:]*src/js/|^[^:]*src/runtime/vm/|^[^:]*tests/js/|^[^:]*benches/js/|^[^:]*src/tooling/cli/zjs\.zig|^[^:]*src/tooling/js_validation/'

# Find violations: any match not in an allowed prefix.
VIOLATIONS=$(grep -R --include='*.zig' -E "$PATTERN" "$ROOT_DIR/src" "$ROOT_DIR/tests" "$ROOT_DIR/benches" 2>/dev/null | grep -v -E "$ALLOWED" || true)

if [ -n "$VIOLATIONS" ]; then
    echo "LAYERING VIOLATION: direct zjs engine import outside allowed locations"
    echo "$VIOLATIONS"
    echo
    echo "Allowed locations (per fun_zjs_subtree_architecture.md §20):"
    echo "  src/js/"
    echo "  src/runtime/vm/"
    echo "  tests/js/"
    echo "  benches/js/"
    echo "  src/tooling/cli/zjs.zig"
    echo "  src/tooling/js_validation/"
    exit 1
fi

echo "Layering check passed (no forbidden zjs engine imports)."
exit 0
