#!/usr/bin/env python3
"""Reject legacy string materializers outside their compatibility owners.

This is a lexical dependency guard, not a proof of GC safety. It also rejects
member references (aliases), ignores comments/literals, and exempts test bodies.
"""

import os
from pathlib import Path
import re
import sys


TOKEN = re.compile(
    r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    r'|[A-Za-z_][A-Za-z_0-9]*|[^\s]'
)
LEGACY = {"asString", "asStringBody", "flattenInfallible", "stringValueFromReceiver"}
OWNERS = {
    ("src/core/value.zig", "asString"): {"fromValue"},
    ("src/core/value.zig", "asStringBody"): {"flattenInfallible"},
    ("src/core/string_view.zig", "fromValue"): {"asStringBody"},
}


def violations(path, source):
    tokens = [(m.group(), m.start()) for m in TOKEN.finditer(source)
              if not m.group().startswith(("//", "\\\\"))]
    scopes = []
    pending = None
    result = []
    for i, (token, offset) in enumerate(tokens):
        if token == "test":
            pending = "test"
        elif token == "fn" and i + 1 < len(tokens):
            pending = tokens[i + 1][0]
        elif token == "{":
            scopes.append(pending)
            pending = None
        elif token == "}":
            if scopes:
                scopes.pop()
        elif token == ";":
            pending = None

        if "test" in scopes:
            continue
        # The declaration itself is allowed, but referring to it is guarded.
        if i and tokens[i - 1][0] == "fn":
            continue
        name = token
        if token.startswith('@"'):
            name = token[2:-1]
        elif token.startswith('"') and i and tokens[i - 1][0] == "@":
            name = token[1:-1]
        legacy = name in LEGACY
        if name == "fromValue" and i >= 2:
            legacy = tokens[i - 1][0] == "." and tokens[i - 2][0] in {"String", "JSString"}
        if not legacy:
            continue
        owner = next((scope for scope in reversed(scopes) if scope), None)
        if name in OWNERS.get((path, owner), set()):
            continue
        line = source.count("\n", 0, offset) + 1
        result.append(f"{path}:{line}: legacy string materializer {name}; use a pure projection or explicit rooted materialization")
    return result


def self_test():
    cases = [
        ('fn f() void { _ = value.asString(); }', True),
        ('fn f() void { const alias = Value.asStringBody; }', True),
        ('fn f() void { _ = value.@"asString"(); }', True),
        ('fn f() void { _ = Value.String.fromValue(value); }', True),
        ('fn f() void { _ = JSString.fromValue(value); }', True),
        ('fn f() void { _ = stringValueFromReceiver(value); }', True),
        ('test "legacy" { _ = value.asString(); } fn f() void { _ = value.asString(); }', True),
        ('test "legacy" { if (true) { _ = value.asString(); } }', False),
        ('// value.asString()\nfn f() void { _ = "value.asString()"; }', False),
        ('fn f() void { _ = value.asStringBodyRaw(); }', False),
    ]
    for source, expected in cases:
        if bool(violations("src/example.zig", source)) != expected:
            raise AssertionError(source)
    allowed = 'pub fn asString(v: Value) ?String { return String.fromValue(v); }'
    assert not violations("src/core/value.zig", allowed)
    assert violations("src/other.zig", allowed)
    assert violations("src/core/value.zig", allowed + ' fn other(v: Value) void { _ = String.fromValue(v); }')


def main():
    self_test()
    root = Path(__file__).resolve().parent.parent
    files = sorted((root / "src").rglob("*.zig"))
    if not files:
        raise RuntimeError("empty source selection")
    errors = []
    for file in files:
        errors.extend(violations(file.relative_to(root).as_posix(), file.read_text()))
    if os.environ.get("ZJS_STRING_BOUNDARY_INJECT") == "1":
        errors.extend(violations("src/injected.zig", 'fn f(v: Value) void { _ = v.asString(); }'))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"String materialization boundary: {len(files)} source files checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
