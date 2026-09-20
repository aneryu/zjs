#!/usr/bin/env python3
"""Merge *_tests.zig into the matching implementation file and drop the siblings."""

from __future__ import annotations

import os
import re
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SKIP_PREAMBLE = re.compile(
    r"^(//!|"
    r"const std = |"
    r"const builtin = |"
    r"const zjs = |"
    r"const engine = |"
    r"const core = |"
    r"const helpers = |"
    r"const support = |"
    r"const bytecode = zjs|"
    r"const function_def = |"
    r"const op = |"
    r"const qop = |"
    r"const parser = |"
    r"const property_ops = |"
    r"const object_ops = |"
    r"const array_ops = |"
    r"const frame_mod = |"
    r"const inline_calls = |"
    r"const compiler = |"
    r"const t = |"
    r"const QjsLexer = |"
    r"const parser_core = |"
    r"const Emitter = |"
    r"const atom = |"
    r"const function_def_mod = |"
    r"const ParseState = |"
    r"const test_entry = |"
    r"const runFunction = |"
    r"const objectFromValue = |"
    r"const expectActiveSetStrings = |"
    r"const makeFunction = )"
)

COMPTIME_PULL = re.compile(
    r"\ncomptime \{\n    if \(@import\(\"builtin\"\)\.is_test and @import\(\"[^\"]+\"\)\.enabled\(\)\) \{\n(?:        _ = @import\(\"[^\"]+\"\);\n)+    \}\n\}\n?"
)

# test_file -> (impl_file, support_kind)
# support_kind: core | exec | parser | builtin | none

def rel_import(from_file: Path, to_file: Path) -> str:
    rel = os.path.relpath(to_file, start=from_file.parent)
    if not rel.startswith("."):
        rel = "./" + rel
    return rel


def existing_consts(text: str) -> set[str]:
    return set(re.findall(r"^(?:pub )?const (\w+) ", text, re.M))


def strip_preamble(text: str) -> str:
    lines = text.splitlines(keepends=True)
    i = 0
    # skip leading //! and blank and SKIP_PREAMBLE const lines; keep support aliases
    out = []
    skipping = True
    for line in lines:
        if skipping:
            if line.strip() == "":
                continue
            if SKIP_PREAMBLE.match(line):
                continue
            skipping = False
        out.append(line)
    return "".join(out)


def test_env_block(impl: Path, names: set[str], support: str | None, builtin_support: bool) -> str:
    src = ROOT / "src"
    test_env = src / "test_env.zig"
    helpers = src / "testing.zig"
    lines = []
    if "zjs" not in names:
        lines.append(
            f'const zjs = if (@import("builtin").is_test) @import("{rel_import(impl, test_env)}").zjs else struct {{}};\n'
        )
    if "engine" not in names:
        lines.append("const engine = zjs;\n")
    if "core" not in names:
        lines.append(
            f'const core = if (@import("builtin").is_test) @import("{rel_import(impl, test_env)}").zjs.core else struct {{}};\n'
        )
    if "helpers" not in names:
        lines.append(
            f'const helpers = if (@import("builtin").is_test) @import("{rel_import(impl, helpers)}") else struct {{}};\n'
        )
    if support:
        sup = src / support
        if "support" not in names:
            lines.append(
                f'const support = if (@import("builtin").is_test) @import("{rel_import(impl, sup)}") else struct {{}};\n'
            )
    if builtin_support and "builtin_support" not in names:
        bs = src / "exec/builtin_test_support.zig"
        lines.append(
            f'const builtin_support = if (@import("builtin").is_test) @import("{rel_import(impl, bs)}") else struct {{}};\n'
        )
    return "".join(lines)


def collect_plan() -> dict[Path, list[tuple[Path, str]]]:
    """impl -> list of (test_file, support_kind)."""
    plan: dict[Path, list[tuple[Path, str]]] = defaultdict(list)
    pull = re.compile(r'_ = @import\("\./([^"]+_tests\.zig)"\);')
    extra_pull = re.compile(r'_ = @import\("\./([^"]+)"\);')
    for p in (ROOT / "src").rglob("*.zig"):
        if p.name.endswith("_tests.zig"):
            continue
        text = p.read_text()
        if "unified_test.zig" not in text:
            continue
        for m in extra_pull.finditer(text):
            name = m.group(1)
            if not name.endswith(".zig"):
                continue
            tf = p.parent / name
            if not tf.exists():
                continue
            kind = "none"
            t = tf.read_text() if tf.exists() else ""
            if "builtin_test_support" in t or "Tests split from src/exec/builtin_tests" in t:
                kind = "builtin"
            elif "core/test_support" in t or str(p).find("/core/") != -1 and "test_support" in t:
                kind = "core"
            elif str(p.parent).endswith("parser") or p.name == "lexer.zig":
                kind = "parser"
            elif str(p.parent).endswith("exec") or p.name == "root.zig" and "exec" in str(p):
                kind = "exec"
            elif str(p.parent).endswith("core"):
                kind = "core"
            plan[p].append((tf, kind))
    return plan


def rewrite_builtin_support(body: str) -> str:
    body = body.replace("const support = @import", "const builtin_support_unused = @import")
    # aliases: const Foo = support.Foo -> builtin_support.Foo
    body = re.sub(
        r"^const (\w+) = support\.(\w+);",
        r"const \1 = builtin_support.\2;",
        body,
        flags=re.M,
    )
    # remaining support. in tests
    # don't replace builtin_support
    body = re.sub(r"(?<!builtin_)support\.", "builtin_support.", body)
    return body


def main() -> None:
    plan = collect_plan()
    merged = 0
    for impl, tests in sorted(plan.items()):
        text = impl.read_text()
        names = existing_consts(text)
        kinds = {k for _, k in tests}
        support_path = {
            "core": "core/test_support.zig",
            "exec": "exec/test_support.zig",
            "parser": "parser/test_support.zig",
        }.get(next((k for k in kinds if k in ("core", "exec", "parser")), ""), None)
        if "core" in kinds:
            support_path = "core/test_support.zig"
        elif "parser" in kinds:
            support_path = "parser/test_support.zig"
        elif "exec" in kinds:
            support_path = "exec/test_support.zig"
        need_builtin = "builtin" in kinds
        # if only builtin, support is builtin file as `support` to avoid rewriting
        only_builtin = kinds == {"builtin"}
        if only_builtin:
            support_path = "exec/builtin_test_support.zig"
            need_builtin = False

        text = COMPTIME_PULL.sub("\n", text)
        names = existing_consts(text)
        env = test_env_block(impl, names, support_path, need_builtin and not only_builtin)
        chunks = [text.rstrip() + "\n\n", env, "\n"]
        seen_alias = set()
        for tf, kind in tests:
            body = strip_preamble(tf.read_text())
            if kind == "builtin" and not only_builtin:
                body = rewrite_builtin_support(body)
            # drop duplicate aliases
            kept = []
            for line in body.splitlines(keepends=True):
                m = re.match(r"^const (\w+) = ", line)
                if m:
                    if m.group(1) in seen_alias or m.group(1) in names:
                        continue
                    seen_alias.add(m.group(1))
                kept.append(line)
            chunks.append("".join(kept).rstrip() + "\n\n")
            tf.unlink()
            print(f"merge {tf.relative_to(ROOT)} -> {impl.relative_to(ROOT)}")
            merged += 1
        impl.write_text("".join(chunks))
    print("merged", merged, "files into", len(plan), "impls")


if __name__ == "__main__":
    main()
