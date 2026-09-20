#!/usr/bin/env python3
"""Split mega *tests.zig files into src/<layer>/tests/<impl>.zig."""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def skip_string(text: str, j: int) -> int:
    n = len(text)
    if j >= n:
        return j
    if text.startswith("\\\\", j):
        while j < n:
            if not text.startswith("\\\\", j):
                return j
            nl = text.find("\n", j)
            if nl < 0:
                return n
            j = nl + 1
            while j < n and text[j] in " \t":
                j += 1
            if text.startswith("\\\\", j):
                continue
            return j
        return j
    q = text[j]
    if q not in "\"'":
        return j
    j += 1
    while j < n:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == q:
            return j + 1
        j += 1
    return j


def walk_braces(text: str, j: int) -> int:
    n = len(text)
    if j >= n or text[j] != "{":
        raise ValueError(f"expected '{{' at {j}")
    depth = 0
    while j < n:
        c = text[j]
        if c == "/" and j + 1 < n:
            nxt = text[j + 1]
            if nxt == "/":
                nl = text.find("\n", j)
                j = n if nl < 0 else nl + 1
                continue
            if nxt == "*":
                k = text.find("*/", j + 2)
                j = n if k < 0 else k + 2
                continue
        if text.startswith("\\\\", j):
            # multiline string only at token boundary; still skip
            j = skip_string(text, j)
            continue
        if c in "\"'":
            j = skip_string(text, j)
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            j += 1
            if depth == 0:
                return j
            continue
        j += 1
    raise ValueError("unbalanced braces")


def skip_ws_comments(text: str, i: int) -> int:
    n = len(text)
    while i < n:
        if text[i] in " \t\r\n":
            i += 1
            continue
        if text.startswith("//", i):
            nl = text.find("\n", i)
            i = n if nl < 0 else nl + 1
            continue
        if text.startswith("/*", i):
            k = text.find("*/", i + 2)
            i = n if k < 0 else k + 2
            continue
        break
    return i


def consume_decl(text: str, i: int) -> int:
    n = len(text)
    depth = 0
    j = i
    seen_brace = False
    while j < n:
        c = text[j]
        if c == "/" and j + 1 < n:
            if text[j + 1] == "/":
                nl = text.find("\n", j)
                j = n if nl < 0 else nl + 1
                continue
            if text[j + 1] == "*":
                k = text.find("*/", j + 2)
                j = n if k < 0 else k + 2
                continue
        if text.startswith("\\\\", j):
            j = skip_string(text, j)
            continue
        if c in "\"'":
            j = skip_string(text, j)
            continue
        if c == "{":
            depth += 1
            seen_brace = True
        elif c == "}":
            depth -= 1
            j += 1
            if depth == 0 and seen_brace:
                k = j
                while k < n and text[k] in " \t\r\n":
                    k += 1
                # `fn () struct { .. } { body }` or `[_]struct { .. }{ .. }`
                if k < n and text[k] == "{":
                    j = k
                    continue
                if k < n and text[k] == ";":
                    return k + 1
                return j
            continue
        elif c == ";" and depth == 0:
            return j + 1
        j += 1
    return j


def parse_items(text: str) -> list[tuple[str, int, int, str]]:
    n = len(text)
    i = 0
    items: list[tuple[str, int, int, str]] = []
    test_re = re.compile(r'test\s+"([^"]*)"\s*\{')
    anon_re = re.compile(r"test\s*\{")
    while True:
        i = skip_ws_comments(text, i)
        if i >= n:
            break
        start = i
        m = test_re.match(text, i)
        if m:
            brace = m.end() - 1
            end = walk_braces(text, brace)
            items.append(("test", start, end, m.group(1)))
            i = end
            continue
        m = anon_re.match(text, i)
        if m:
            brace = m.end() - 1
            end = walk_braces(text, brace)
            items.append(("test", start, end, ""))
            i = end
            continue
        end = consume_decl(text, i)
        if end <= i:
            raise ValueError(f"stuck at {i}: {text[i:i+40]!r}")
        items.append(("other", start, end, text[start:end].strip().split("\n", 1)[0][:80]))
        i = end
    return items


def pubify_members(text: str) -> str:
    """Make struct fields and methods visible to other files in the test module."""
    out = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        if stripped.startswith("pub ") or stripped.startswith("//") or stripped.startswith("///"):
            out.append(line)
            continue
        if stripped.startswith("fn "):
            out.append(indent + "pub " + stripped)
            continue
        out.append(line)
    return "\n".join(out)


def make_pub(block: str) -> str:
    raw = block.strip("\n")
    if not raw.endswith("\n"):
        raw += "\n"
    lines = raw.split("\n")
    idx = 0
    while idx < len(lines) and (
        lines[idx].startswith("//!")
        or lines[idx].startswith("///")
        or lines[idx].startswith("//")
        or lines[idx].strip() == ""
    ):
        idx += 1
    if idx >= len(lines):
        return raw if raw.endswith("\n") else raw + "\n"
    line = lines[idx]
    stripped = line.lstrip()
    if stripped.startswith("pub "):
        return raw if raw.endswith("\n") else raw + "\n"
    indent = line[: len(line) - len(stripped)]
    lines[idx] = indent + "pub " + stripped
    out = "\n".join(lines)
    return out if out.endswith("\n") else out + "\n"


def decl_kind_name(header: str) -> tuple[str, str] | None:
    m = re.match(
        r"(?:pub\s+)?(?:extern(?:\s+\"[^\"]*\")?\s+)?(?:threadlocal\s+)?(?:comptime\s+)?"
        r"(const|var|fn)\s+([A-Za-z_][A-Za-z0-9_]*)",
        header.strip(),
    )
    return (m.group(1), m.group(2)) if m else None


def first_match(name: str, rules: list[tuple[str, str]]) -> str:
    lower = name.lower()
    for pat, target in rules:
        if re.search(pat, lower):
            return target
    return "misc"


CORE_RULES = [
    (r"weak (collection|ref|map|persistent)|finalization registry|dead weak|"
     r"live weak|borrowed holder", "collection"),
    (r"handle scope|persistent value handle|native pin", "runtime"),
    (r"module_ns|auto-init", "context"),
    (r"pollgc|gc threshold|allocation-threshold|threshold crossing|"
     r"threshold request|live heap stats|external memory token|"
     r"compact trace|zero-ref release|cycle scan|fallible gc api|"
     r"process heap trim|object allocation (drops|keeps|collects)|"
     r"pure string loop|pure rope-concat|unrequested threshold|"
     r"full-reachable verifier|condemning many shapes|marked-set census|"
     r"terminal pending stats", "gc"),
    (r"payloads ignore|payload noncarriers|native call carriers|"
     r"borrowed realm|leaf payload", "object_payloads"),
    (r"iterator collection and disposable|collection iterator prototype", "collection"),
    (r"active bytecode release", "function"),
    (r"runtime-resident indexes", "runtime"),
    (r"dense parameter arrays borrowed", "array"),
    (r"array target barrier", "array"),
    (r"dense array", "array"),
    (r"array (teardown|length|indexed|element|iterator|buffer)", "array"),
    (r"owned dense array", "array"),
    (r"shared array buffer|shared buffer store|typed.?array|typed-array", "typed_array"),
    (r"array buffer", "typed_array"),
    (r"realmcontext|auto_init|context backtrace|context lexicals", "context"),
    (r"classid|class table|class record|class prototype|class construction|"
     r"class finalizer|class payload|class standard|inline class|dynamic class|"
     r"unregistered dynamic class|external class", "class"),
    (r"unique symbol|ownership audit|atom (slot|entry|verdict|no edge)|tgc s3", "atom"),
    (r"s2-i |string table|string extent|concat operator", "string"),
    (r"shape |property |defineplaindataproperty|prototype replacement|"
     r"slots2|prop_size|tombstone|ic-r1|own data properties|own keys|"
     r"extensibility seal|accessor descriptors|prototype traversal", "property"),
    (r"trace_stw|ephemeron|weakref|weakmap|finalizationregistry pending", "gc_trace_stw"),
    (r"address registry|conservative scan|carrier |conservative candidate", "gc_conservative"),
    (r"gc invariant|gc heap|gc registry|representation audit|block heap|"
     r"block cell|block-cell|minor |major |incremental |barrier |mark frontier|"
     r"g-shape|generational|tgc s4|q2[12]|needs_finalizer|storage-cell|"
     r"remembered|forget fuses|construction root|arena audit|generation audit|"
     r"retirement audit|whole-heap|extent string|marking barrier|frontier |"
     r"ten thousand plain|young churn|old generation|dense buffer adopted|"
     r"regexp capture strings survive a minor|independent runtimes collect|"
     r"cell resolution|carrier exact|carrier generation|production current-membership|"
     r"a minor that keeps|a crossing a minor|a minor-only|an old generation|"
     r"an explicit collection|an urgent poll|runtime teardown owns a detached|"
     r"promise coallocation", "gc"),
    (r"finalizationregistry realmref", "context"),
    (r"module ", "module"),
    (r"generator |suspended execution", "generator_state"),
    (r"native function state|true c functions|bytecode function state", "function"),
    (r"var_ref|varref", "var_ref"),
    (r"runtime queues", "jobs"),
    (r"runtime |process memory|process-global|value root buffer", "runtime"),
    (r"exception slot", "exception"),
    (r"host transports|errors keep independent", "errors"),
    (r"json parse", "json"),
    (r"collection clear|mapped arguments|regexp lastindex|cached iterator|"
     r"object destruction|object release|object data|object trace|object child|"
     r"object creation|plain object|proven object|standalone inline object|"
     r"side authority|weak husk|ordinary objects define|failed object registration|"
     r"cycle is released|self-cycle|cycle removal|exotic dispatch", "object"),
    (r"reference dup", "value"),
    (r"functionbytecode realmref|function bytecode registration|"
     r"function_bytecode trace", "function"),
]


EXEC_RULES = [
    (r"typescript|engine eval", "eval_entry"),
    (r"generator |yield|initial_yield", "vm_gen_async"),
    (r"typed array", "typed_array_construct"),
    (r"native builtin record|cproto dispatch|dispatch metadata|"
     r"dispatch-name|builtin dispatch|auto-init builtin|throw type error intrinsic",
     "builtin_dispatch"),
    (r"error stack|preparestacktrace|syntaxerror|typeerror thrown|"
     r"native builtin errors|callsite metadata", "error_stack_ops"),
    (r"tail_call|pc2line|x-89", "call"),
    (r"with |destructuring", "eval_entry"),
    (r"leftover ", "zjs_vm"),
    (r"qjs alignment|const local writes|named function self-binding|"
     r"local reference-tail|add_loc|inc_loc|checked lexical|"
     r"resident set_var_ref|resident stack|mapped arguments|"
     r"checked local replacement", "zjs_vm"),
    (r"closure helper|wide closure|function expressions|"
     r"top-level function declarations", "closure"),
    (r"math cproto|number native|string (static|prototype|case)|"
     r"date |array (static|prototype)|collection native|buffer native|"
     r"vm collection constructors|instanceof|function hasinstance|"
     r"object\.isextensible|object\.getownpropertynames|array\.(shift|slice|map|sort|fill|indexof|reduce|from)",
     "builtin_dispatch"),
    (r"disposable", "disposable_ops"),
    (r"ic-r1", "vm_property"),
    (r"public property key|thenable job|script entry points|"
     r"shared test engine reset|runtime-strict", "eval_entry"),
    (r"string\.prototype|computed reads", "string_ops"),
    (r"publish-time simple-ctor", "construct"),
    (r"dense parameter arrays", "array_ops"),
    (r"interrupt", "call"),
    (r"machine |native fence|native reentry|apply |spread calls|callback cohort|"
     r"constructor |reflect\.construct|proxy wrapping|proxy native constructor|"
     r"derived constructor|class constructor|super call|bound function call|"
     r"ordinary constructor|tail-frame|tail target|js_function_set_properties", "call"),
    (r"w1 |property site", "vm_property"),
    (r"get_var_ref|js_closure|var-ref|global declaration|hidden uninitialized globals|"
     r"ordinary global closure|local growth|arg aliases|call-binding|"
     r"original-args|strict generator resident", "frame"),
    (r"eval lazily|direct eval|indirect eval|escaped direct eval|module |"
     r"dynamic import|top-level await", "eval_entry"),
    (r"promise |async resume|async ", "promise_ops"),
    (r"for-of|iterator", "iterator_ops"),
    (r"small_inline|inlinedsite|callerstate", "small_inline"),
    (r"vm executes|push constants|return_undef|numeric discarded|"
     r"signed bigint|heap bigint|threaded with atom", "zjs_vm"),
    (r"frame setlocal|lookupframevarref", "frame"),
    (r"value ops", "value_ops"),
    (r"property ops", "property_ops"),
    (r"object_slots2|object_slots", "object_ops"),
    (r"jobs|microtask|job queue", "jobs"),
    (r"atomics", "atomics_ops"),
    (r"regexp", "regexp_ops"),
    (r"proxy |reflect", "reflect_ops"),
    (r"class entry|class ", "class_init_ops"),
    (r"constant pool execution", "zjs_vm"),
    (r"a dynamic function outlives", "function_ops"),
    (r"string leftover", "value_ops"),
    (r"host |print |throw intrinsic|standard globals", "standard_globals"),
]


PARSER_RULES = [
    (r"^ts:|typescript", "typescript"),
    (r"^f8:|import |export ", "modules"),
    (r"^f7:|super\(\)|private (method|getter|setter|accessor)", "classes"),
    (r"^f9:|yield", "functions"),
    (r"^f5:|^f6:|object literal|computed object|object (spread|method|string getter|"
     r"numeric setter)|__proto__|nullish coalescing|inc_loc", "expressions"),
    (r"m-scope|f10\.|functiondef:|scope marker|direct eval captures|"
     r"eval operands|eval marker|implicit arguments", "closure"),
    (r"syntax error|expecttoken|lexer syntax|compile syntax|"
     r"canonical root|compile policy|root strictness|directive", "parse_state"),
    (r"call-site cache|prop-site cache|empty finally", "emitter"),
    (r"^f1(\.|:)|keyword token|of remains an identifier|freetoken|"
     r"punctuators|numeric literals|string escapes|lone surrogate|"
     r"line continuation|legacy octal|template |regex literal|"
     r"private name|unicode escape|escaped keyword|raw unicode identifier|"
     r"got_lf|line_num|end-to-end lex|html comments|hashbang|"
     r"keyword block atom", "lexer"),
    (r"typescript|^ts |: ts ", "typescript"),
    (r"import |export |module ", "modules"),
    (r"class |field |super |static |heritage|computed public class", "classes"),
    (r"function |arrow |async function|parameters", "functions"),
    (r"scope proof|closure |capture |var-ref|lexical", "closure"),
    (r"lookahead", "lookahead"),
    (r"pending diagnostic|parse_state|parse state", "parse_state"),
    (r"^f4:|parseexpr|lowers to|bytecode|opcode|emitter|source position|"
     r"w5:|constant pool", "emitter"),
    (r"statement|if |for |while |switch |try |break |continue |return |"
     r"label |with |do ", "statements"),
    (r"identif|declaration|var |let |const ", "declarations"),
]


BUILTIN_RULES = [
    (r"bound and proxy|lazy standard native|host output number", "dispatch"),
    (r"nested assignment|captured derived this", "class_init_ops"),
    (r"math\.|math min|bare math", "math_ops"),
    (r"array\.|array prototype|dense array|sparse array|array of |"
     r"array from|array species|array named|array dense|array indexed|"
     r"push splice|array for-of|array map", "array_builtin_ops"),
    (r"typedarray|arraybuffer|buffer and typed", "typed_array_construct"),
    (r"regexp", "regexp_ops"),
    (r"set\.|map\.|weakmap|weakset|collection |host map|set combinator|"
     r"set relation|set prototype|set union", "collection_ops"),
    (r"promise", "promise_ops"),
    (r"object\.|object constructor|object assign", "object_builtin_ops"),
    (r"function |reflect apply", "function_ops"),
    (r"json\.", "json_ops"),
    (r"uri |decodeuri", "uri_ops"),
    (r"disposable", "disposable_ops"),
    (r"error\.|error prototype|native error", "error_ops"),
    (r"string match|string iterator|string ", "string_builtin_ops"),
    (r"date/", "date_ops"),
    (r"eval |direct and indirect eval|test262 frontmatter", "eval_ops"),
    (r"induction |range fast path|loop opcodes|global var induction|"
     r"global write induction|short bigint induction", "zjs_vm"),
    (r"cross-realm|callee realm|realm intrinsic|lazy native|"
     r"standard constructors|cproto|native builtin", "dispatch"),
    (r"class |destructur|lexical |parameter|tdz|arguments grammar|"
     r"body function", "class_init_ops"),
    (r"invalid opcode", "zjs_vm"),
    (r"module top-level await", "module"),
    (r"property compaction|shared engine baseline", "property_ops"),
    (r"iterator prototypes", "iterator_builtin_ops"),
]


LAYERS = {
    "core": {
        "src": "src/core/core_tests.zig",
        "out_dir": "src/core/tests",
        "helpers_import": '../../testing.zig',
        "rules": CORE_RULES,
        "preamble_extra": "",
        "default_target": "object",
        "import_rewrites": [('@import("../cli/', '@import("../../cli/')],
    },
    "exec": {
        "src": "src/exec/exec_tests.zig",
        "out_dir": "src/exec/tests",
        "helpers_import": '../../testing.zig',
        "rules": EXEC_RULES,
        "preamble_extra": "const helpers = @import(\"../../testing.zig\");\n",
        "default_target": "zjs_vm",
        "import_rewrites": [
            ('@import("../cli/', '@import("../../cli/'),
            ('@import("../testing.zig")', '@import("../../testing.zig")'),
        ],
    },
    "parser": {
        "src": "src/parser/parser_tests.zig",
        "out_dir": "src/parser/tests",
        "helpers_import": '../../testing.zig',
        "rules": PARSER_RULES,
        "preamble_extra": "",
        "default_target": "expressions",
        "import_rewrites": [('@import("../cli/', '@import("../../cli/')],
    },
    "builtin": {
        "src": "src/exec/builtin_tests.zig",
        "out_dir": "src/exec/tests/builtins",
        "helpers_import": '../../../testing.zig',
        "rules": BUILTIN_RULES,
        "preamble_extra": "",
        "name_prefix": "",
        "default_target": "dispatch",
        "import_rewrites": [('@import("../cli/', '@import("../../../cli/')],
    },
}


def rewrite_helpers_import(preamble: str, new_import: str) -> str:
    preamble = re.sub(
        r'@import\("\.\./testing\.zig"\)',
        f'@import("{new_import}")',
        preamble,
    )
    preamble = re.sub(
        r'@import\("testing\.zig"\)',
        f'@import("{new_import}")',
        preamble,
    )
    return preamble


def split_layer(layer: str) -> dict[str, int]:
    cfg = LAYERS[layer]
    src_path = ROOT / cfg["src"]
    text = src_path.read_text()
    items = parse_items(text)
    tests = [it for it in items if it[0] == "test"]
    print(f"{layer}: parsed {len(tests)} tests, {len(items)} items from {src_path}")

    first_test = next(i for i, it in enumerate(items) if it[0] == "test")
    preamble = text[: items[first_test][1]]
    preamble = rewrite_helpers_import(preamble, cfg["helpers_import"])
    if not preamble.endswith("\n"):
        preamble += "\n"
    test_preamble = preamble
    extra = cfg.get("preamble_extra") or ""
    if extra and "const helpers =" not in test_preamble:
        test_preamble = test_preamble.rstrip() + "\n" + extra
        if not test_preamble.endswith("\n"):
            test_preamble += "\n"

    support_blocks: list[str] = []
    support_const_fn: list[str] = []
    support_vars: list[str] = []
    grouped: dict[str, list[str]] = defaultdict(list)
    counts: dict[str, int] = defaultdict(int)
    prefix = cfg.get("name_prefix", "")

    def rewrite_imports(s: str) -> str:
        for old, new in cfg.get("import_rewrites", []):
            s = s.replace(old, new)
        return s

    for kind, start, end, name in items[first_test:]:
        chunk = rewrite_imports(text[start:end])
        if kind == "other":
            support_blocks.append(pubify_members(make_pub(chunk)))
            kn = decl_kind_name(name)
            if kn:
                kind_s, dn = kn
                if kind_s == "var":
                    support_vars.append(dn)
                else:
                    support_const_fn.append(dn)
            continue
        target = prefix + first_match(name, cfg["rules"])
        if target in (prefix + "misc", "misc"):
            target = prefix + cfg.get("default_target", "misc")
        grouped[target].append(chunk if chunk.endswith("\n") else chunk + "\n")
        counts[target] += 1

    out_dir = ROOT / cfg["out_dir"]
    out_dir.mkdir(parents=True, exist_ok=True)

    support_src = preamble
    if "const helpers =" not in support_src and layer == "exec":
        support_src += 'const helpers = @import("../../testing.zig");\n'
    support_src += "\n" + "\n".join(b.rstrip() for b in support_blocks) + "\n"
    (out_dir / "support.zig").write_text(support_src)

    for target, bodies in grouped.items():
        blob = "\n".join(bodies)
        preamble_names = set(re.findall(r"\b(?:const|var|fn)\s+([A-Za-z_][A-Za-z0-9_]*)", test_preamble))
        used_cf = [
            dn
            for dn in support_const_fn
            if dn not in preamble_names and re.search(r"\b" + re.escape(dn) + r"\b", blob)
        ]
        used_vars = [dn for dn in support_vars if re.search(r"\b" + re.escape(dn) + r"\b", blob)]
        aliases = ""
        if used_cf or used_vars:
            aliases = 'const support = @import("support.zig");\n'
            for dn in used_cf:
                aliases += f"const {dn} = support.{dn};\n"
            aliases += "\n"
        body_text = "\n\n".join(bodies)
        if used_vars:
            for dn in sorted(used_vars, key=len, reverse=True):
                body_text = re.sub(r"\b" + re.escape(dn) + r"\b", f"support.{dn}", body_text)
        header = (
            f"//! Tests split from {cfg['src']} for this implementation slice.\n"
            + test_preamble
            + aliases
        )
        (out_dir / f"{target}.zig").write_text(header + body_text)

    barrel_path = out_dir.parent / (out_dir.name + ".zig")
    # src/core/tests/*.zig  → src/core/tests.zig
    rel_dir = out_dir.name
    lines = [
        f"//! Barrel: pull tests under {cfg['out_dir']}/ into the unified suite.\n",
        "test {\n",
    ]
    for target in sorted(grouped):
        lines.append(f'    _ = @import("{rel_dir}/{target}.zig");\n')
    lines.append("}\n")
    barrel_path.write_text("".join(lines))
    print(f"  barrel {barrel_path.relative_to(ROOT)} ({len(grouped)} files)")

    return dict(counts)


def main() -> None:
    layers = sys.argv[1:] or ["core", "exec", "parser", "builtin"]
    for layer in layers:
        counts = split_layer(layer)
        print(f"  targets ({len(counts)}):")
        for k in sorted(counts, key=lambda x: -counts[x]):
            print(f"    {k:24s} {counts[k]:4d}")
        leftover = counts.get("misc", 0) + counts.get("builtin_misc", 0)
        if leftover:
            print(f"  leftover misc: {leftover}")


if __name__ == "__main__":
    main()
