#!/usr/bin/env python3
"""Move src/*/tests/*.zig to sibling *_tests.zig and hang them off impl files."""

from __future__ import annotations

import os
import shutil
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / "src/testing.zig"

# src, dest, impl (None = don't hang), support dest
Plan = tuple[str, str, str | None, str]

CORE_SUPPORT = "src/core/test_support.zig"
EXEC_SUPPORT = "src/exec/test_support.zig"
PARSER_SUPPORT = "src/parser/test_support.zig"
BUILTIN_SUPPORT = "src/exec/builtin_test_support.zig"

PLAN: list[Plan] = []

for name in [
    "array", "atom", "class", "collection", "context", "errors", "exception",
    "function", "gc", "gc_conservative", "gc_trace_stw", "generator_state",
    "jobs", "module", "object", "object_payloads", "property", "runtime",
    "string", "typed_array", "value", "var_ref",
]:
    PLAN.append((
        f"src/core/tests/{name}.zig",
        f"src/core/{name}_tests.zig",
        f"src/core/{name}.zig",
        CORE_SUPPORT,
    ))
PLAN.append(("src/core/tests/support.zig", CORE_SUPPORT, None, CORE_SUPPORT))

for name in [
    "array_ops", "builtin_dispatch", "call", "class_init_ops", "closure",
    "construct", "disposable_ops", "error_stack_ops", "eval_entry", "frame",
    "function_ops", "iterator_ops", "object_ops", "promise_ops", "property_ops",
    "reflect_ops", "regexp_ops", "standard_globals", "string_ops",
    "typed_array_construct", "value_ops", "vm_gen_async", "vm_property",
    "zjs_vm",
]:
    PLAN.append((
        f"src/exec/tests/{name}.zig",
        f"src/exec/{name}_tests.zig",
        f"src/exec/{name}.zig",
        EXEC_SUPPORT,
    ))
PLAN.append(("src/exec/tests/jobs.zig", "src/exec/jobs_tests.zig", "src/exec/root.zig", EXEC_SUPPORT))
PLAN.append(("src/exec/tests/support.zig", EXEC_SUPPORT, None, EXEC_SUPPORT))

PLAN += [
    ("src/parser/tests/classes.zig", "src/parser/classes_tests.zig", "src/parser/classes.zig", PARSER_SUPPORT),
    ("src/parser/tests/closure.zig", "src/parser/closure_tests.zig", "src/parser/closure.zig", PARSER_SUPPORT),
    ("src/parser/tests/declarations.zig", "src/parser/declarations_tests.zig", "src/parser/declarations.zig", PARSER_SUPPORT),
    ("src/parser/tests/emitter.zig", "src/parser/emitter_tests.zig", "src/parser/emitter.zig", PARSER_SUPPORT),
    ("src/parser/tests/expressions.zig", "src/parser/expressions_tests.zig", "src/parser/expressions.zig", PARSER_SUPPORT),
    ("src/parser/tests/functions.zig", "src/parser/functions_tests.zig", "src/parser/functions.zig", PARSER_SUPPORT),
    ("src/parser/tests/lexer.zig", "src/lexer_tests.zig", "src/lexer.zig", PARSER_SUPPORT),
    ("src/parser/tests/lookahead.zig", "src/parser/lookahead_tests.zig", "src/parser/lookahead.zig", PARSER_SUPPORT),
    ("src/parser/tests/modules.zig", "src/parser/modules_tests.zig", "src/parser/modules.zig", PARSER_SUPPORT),
    ("src/parser/tests/parse_state.zig", "src/parser/parse_state_tests.zig", "src/parser/parse_state.zig", PARSER_SUPPORT),
    ("src/parser/tests/statements.zig", "src/parser/statements_tests.zig", "src/parser/statements.zig", PARSER_SUPPORT),
    ("src/parser/tests/typescript.zig", "src/parser/typescript_tests.zig", "src/parser/typescript.zig", PARSER_SUPPORT),
    ("src/parser/tests/support.zig", PARSER_SUPPORT, None, PARSER_SUPPORT),
]

for name, dest_name, impl_name in [
    ("array_builtin_ops", "array_builtin_ops_tests.zig", "array_builtin_ops.zig"),
    ("collection_ops", "collection_ops_tests.zig", "collection_ops.zig"),
    ("dispatch", "builtin_dispatch_realm_tests.zig", "builtin_dispatch.zig"),
    ("error_ops", "error_ops_tests.zig", "error_ops.zig"),
    ("eval_ops", "eval_ops_tests.zig", "eval_ops.zig"),
    ("iterator_builtin_ops", "iterator_builtin_ops_tests.zig", "iterator_builtin_ops.zig"),
    ("math_ops", "math_ops_tests.zig", "math_ops.zig"),
    ("module", "module_tests.zig", "module.zig"),
    ("object_builtin_ops", "object_builtin_ops_tests.zig", "object_builtin_ops.zig"),
    ("string_builtin_ops", "string_builtin_ops_tests.zig", "string_builtin_ops.zig"),
    ("uri_ops", "uri_ops_tests.zig", "uri_ops.zig"),
    ("class_init_ops", "class_init_ops_builtin_tests.zig", "class_init_ops.zig"),
    ("disposable_ops", "disposable_ops_builtin_tests.zig", "disposable_ops.zig"),
    ("function_ops", "function_ops_builtin_tests.zig", "function_ops.zig"),
    ("promise_ops", "promise_ops_builtin_tests.zig", "promise_ops.zig"),
    ("property_ops", "property_ops_builtin_tests.zig", "property_ops.zig"),
    ("regexp_ops", "regexp_ops_builtin_tests.zig", "regexp_ops.zig"),
    ("typed_array_construct", "typed_array_construct_builtin_tests.zig", "typed_array_construct.zig"),
    ("zjs_vm", "zjs_vm_builtin_tests.zig", "zjs_vm.zig"),
]:
    PLAN.append((
        f"src/exec/tests/builtins/{name}.zig",
        f"src/exec/{dest_name}",
        f"src/exec/{impl_name}",
        BUILTIN_SUPPORT,
    ))
PLAN.append(("src/exec/tests/builtins/support.zig", BUILTIN_SUPPORT, None, BUILTIN_SUPPORT))


def rel_import(from_file: Path, to_file: Path) -> str:
    rel = os.path.relpath(to_file, start=from_file.parent)
    if not rel.startswith("."):
        rel = "./" + rel
    return rel


def rewrite_imports(dest: Path, support: Path) -> None:
    text = dest.read_text()
    text = text.replace('@import("support.zig")', f'@import("{rel_import(dest, support)}")')
    for old in (
        '@import("../../../testing.zig")',
        '@import("../../testing.zig")',
        '@import("../testing.zig")',
        '@import("testing.zig")',
    ):
        text = text.replace(old, f'@import("{rel_import(dest, HELPERS)}")')
    dest.write_text(text)


def append_pulls(impl: Path, test_files: list[Path]) -> None:
    text = impl.read_text()
    missing = [p for p in test_files if p.name not in text]
    if not missing:
        return
    unified = rel_import(impl, ROOT / "src/unified_test.zig")
    chunk = ["\n", "test {\n", f'    if (comptime @import("{unified}").enabled()) {{\n']
    for p in test_files:
        chunk.append(f'        _ = @import("{rel_import(impl, p)}");\n')
    chunk.append("    }\n}\n")
    if not text.endswith("\n"):
        text += "\n"
    impl.write_text(text + "".join(chunk))


def main() -> None:
    impl_to_tests: dict[Path, list[Path]] = defaultdict(list)
    for src_s, dest_s, impl_s, support_s in PLAN:
        src, dest, support = ROOT / src_s, ROOT / dest_s, ROOT / support_s
        if not src.exists():
            print("missing", src_s)
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dest))
        print(f"mv {src_s} -> {dest_s}")
        rewrite_imports(dest, support)
        if impl_s:
            impl_to_tests[ROOT / impl_s].append(dest)

    extra = [
        (ROOT / "src/core/gc.zig", ROOT / "src/core/gc_stress_tests.zig"),
        (ROOT / "src/core/gc_alloc.zig", ROOT / "src/core/oom_cap_tests.zig"),
        (ROOT / "src/js_context.zig", ROOT / "src/js_context_tests.zig"),
        (ROOT / "src/bytecode.zig", ROOT / "src/bytecode_tests.zig"),
    ]
    for impl, test in extra:
        if impl.exists() and test.exists():
            impl_to_tests[impl].append(test)

    for impl, tests in sorted(impl_to_tests.items()):
        tests = [t for t in tests if t.exists() and not t.name.endswith("support.zig")]
        if not tests:
            continue
        append_pulls(impl, tests)
        print(f"pull {impl.relative_to(ROOT)} <- {[t.name for t in tests]}")


if __name__ == "__main__":
    main()
