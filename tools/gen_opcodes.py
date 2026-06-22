#!/usr/bin/env python3
"""Generate src/bytecode/opcodes_generated.zig from tests/fixtures/quickjs-opcode.h.

The fixture is the single definition source for the zjs opcode set. It uses
the upstream QuickJS conventions (quickjs.c:1166 + 21826):

  - `DEF(name, size, n_pop, n_push, fmt)` defines a real opcode. DEF entries
    receive sequential ids in file order; the temporary `def` entries do not
    advance that counter, so the short opcodes (everything after the temp
    block) overlap the temp id range.
  - `def(...)` defines a phase-1 temporary opcode. Temps must sit directly
    after OP_nop; their ids are OP_nop+1.. and overlap the short opcodes.
  - The merged `opcode_info` table is filled in *file order*: temp entries
    occupy their id positions, short entries are pushed `op_temp_count`
    slots past their ids (QuickJS `short_opcode_info`).

Usage:
  python3 tools/gen_opcodes.py                 # rewrite the generated file
  python3 tools/gen_opcodes.py --check         # exit 1 if on-disk file is stale
  python3 tools/gen_opcodes.py --verify-legacy OLD.zig
        # one-time migration check: compare the new table (final view and
        # phase-1 view) against the pre-refactor generated file plus the
        # handwritten switch overrides that used to live in opcode.zig /
        # zjs_parser.zig / resolve_variables.zig.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = REPO_ROOT / "tests/fixtures/quickjs-opcode.h"
OUTPUT = REPO_ROOT / "src/bytecode/opcodes_generated.zig"

# Zig identifiers that need @"..." quoting, exactly the set used by the
# pre-refactor file (kept stable to avoid churn in op.* call sites).
ZIG_QUOTED = {"undefined", "null", "return", "catch", "and", "or", "const", "var", "fn", "error"}

DEF_RE = re.compile(
    r"^\s*(DEF|def)\(\s*([A-Za-z0-9_]+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([A-Za-z0-9_]+)\s*\)"
)
FMT_RE = re.compile(r"^FMT\(([A-Za-z0-9_]+)\)")


class Entry:
    def __init__(self, kind: str, name: str, size: int, n_pop: int, n_push: int, fmt: str):
        self.kind = kind  # "normal" | "temp" | "short"
        self.name = name
        self.size = size
        self.n_pop = n_pop
        self.n_push = n_push
        self.fmt = fmt
        self.id = -1  # opcode id (overlapping for temp/short)
        self.index = -1  # index into the merged opcode_info table


def zig_ident(name: str) -> str:
    return f'@"{name}"' if name in ZIG_QUOTED else name


def parse_fixture(text: str):
    formats: list[str] = []
    entries: list[Entry] = []
    for line in text.splitlines():
        m = FMT_RE.match(line.strip())
        if m:
            formats.append(m.group(1))
            continue
        m = DEF_RE.match(line)
        if m:
            macro, name, size, n_pop, n_push, fmt = m.groups()
            kind = "temp" if macro == "def" else "normal"
            entries.append(Entry(kind, name, int(size), int(n_pop), int(n_push), fmt))

    # Assign ids: DEF entries get sequential ids (temps skipped); temps get
    # nop+1.. and everything after the temp block is a short opcode.
    def_counter = 0
    temp_seen = False
    nop_id = None
    temp_start = None
    n_temp = 0
    for e in entries:
        if e.kind == "temp":
            if nop_id is None:
                raise SystemExit("fixture error: temp opcode before nop")
            if not temp_seen:
                temp_seen = True
                temp_start = nop_id + 1
            e.id = temp_start + n_temp
            n_temp += 1
        else:
            if temp_seen:
                e.kind = "short"
            e.id = def_counter
            def_counter += 1
            if e.name == "nop":
                nop_id = e.id
    if nop_id is None or temp_start is None:
        raise SystemExit("fixture error: missing nop or temp block")
    if temp_start != nop_id + 1:
        raise SystemExit("fixture error: temp block must directly follow nop")
    op_count = def_counter
    temp_end = temp_start + n_temp
    if op_count - 1 > 0xFF or temp_end - 1 > 0xFF:
        raise SystemExit("fixture error: opcode ids exceed u8")

    # Merged-table indices in file order. Temp entries land exactly at their
    # id; short entries land at id + n_temp.
    for i, e in enumerate(entries):
        e.index = i
        if e.kind == "temp":
            assert e.index == e.id, f"{e.name}: temp index {e.index} != id {e.id}"
        elif e.kind == "short":
            assert e.index == e.id + n_temp, f"{e.name}: short index {e.index} != id+{n_temp}"
        else:
            assert e.index == e.id, f"{e.name}: normal index {e.index} != id {e.id}"

    # Duplicate-name check.
    names = [e.name for e in entries]
    if len(names) != len(set(names)):
        dupes = sorted({n for n in names if names.count(n) > 1})
        raise SystemExit(f"fixture error: duplicate opcode names {dupes}")

    return formats, entries, op_count, temp_start, temp_end


def render(formats, entries, op_count, temp_start, temp_end) -> str:
    n_temp = temp_end - temp_start
    finals = [e for e in entries if e.kind != "temp"]
    temps = [e for e in entries if e.kind == "temp"]

    out: list[str] = []
    w = out.append
    w("// Generated by tools/gen_opcodes.py from tests/fixtures/quickjs-opcode.h.")
    w("// DO NOT EDIT BY HAND. Regenerate with:")
    w("//   python3 tools/gen_opcodes.py")
    w("//")
    w("// Layout mirrors QuickJS (`quickjs.c:1166` + `quickjs.c:21826`):")
    w("//   - DEF entries get sequential ids 0..op_count-1.")
    w("//   - def (temp) entries take ids op_temp_start..op_temp_end-1, which")
    w("//     OVERLAP the short opcodes in the same range. Temp ops exist only")
    w("//     in phase-1 streams (parser output, before resolve_labels); short")
    w("//     ops only exist afterwards, so sharing the id space is sound.")
    w("//   - `opcode_info` is filled in file order: temp entries sit exactly at")
    w("//     their id, short entries are shifted op_temp_count slots past their")
    w("//     id (QuickJS `short_opcode_info`). Do not index it with a raw id;")
    w("//     use the view functions in opcode.zig (`sizeOf` for final-form")
    w("//     bytecode, `sizeOfPhase1` for phase-1 streams, and friends).")
    w("")
    w("/// Operand format tags, from the FMT() list in quickjs-opcode.h.")
    w("pub const Format = enum {")
    for f in formats:
        w(f"    {zig_ident(f)},")
    w("};")
    w("")
    w("/// One row of opcode metadata (QuickJS `JSOpCode`).")
    w("pub const Info = struct {")
    w("    name: []const u8,")
    w("    size: u8,")
    w("    n_pop: u8,")
    w("    n_push: u8,")
    w("    fmt: Format,")
    w("};")
    w("")
    w("pub const op = struct {")
    for e in finals:
        w(f"    pub const {zig_ident(e.name)}: u8 = {e.id};")
    w("")
    w("    // Temporary opcodes (phase-1 emit, erased before resolve_labels).")
    w("    // Ids overlap the short opcodes above; phase-1 streams and final")
    w("    // streams must use the matching opcode.zig view to size them.")
    for e in temps:
        w(f"    pub const {zig_ident(e.name)}: u8 = {e.id};")
    w("")
    w("    /// Number of real (DEF) opcodes; ids 0..op_count-1 are claimed.")
    w(f"    pub const op_count: u16 = {op_count};")
    w("    /// First id of the temp/short overlap range (OP_nop + 1).")
    w(f"    pub const op_temp_start: u8 = {temp_start};")
    w("    /// One past the last temp id (exclusive).")
    w(f"    pub const op_temp_end: u8 = {temp_end};")
    w("    /// Number of temp opcodes (= short-entry shift in `opcode_info`).")
    w(f"    pub const op_temp_count: u8 = {n_temp};")
    w("};")
    w("")
    w(f"pub const op_info_len: usize = {len(entries)};")
    w("")
    w("/// Merged metadata table in quickjs-opcode.h file order (see header")
    w("/// comment for the index layout).")
    w("pub const opcode_info: [op_info_len]Info = .{")
    for e in entries:
        if e.kind == "temp":
            loc = f"id {e.id} (temp)"
        elif e.kind == "short":
            loc = f"id {e.id} (short, shifted)"
        else:
            loc = f"id {e.id}"
        w(
            f'    .{{ .name = "{e.name}", .size = {e.size}, .n_pop = {e.n_pop}, '
            f".n_push = {e.n_push}, .fmt = .{zig_ident(e.fmt)} }}, // [{e.index}] {loc}"
        )
    w("};")
    w("")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Legacy verification: prove zero drift against the pre-refactor tables plus
# the handwritten switch overrides that this refactor deletes.
# ---------------------------------------------------------------------------


def parse_legacy(path: Path):
    text = path.read_text()
    const_re = re.compile(r"pub const (@\"[^\"]+\"|[A-Za-z0-9_]+): u8 = (\d+);")
    consts = [
        (m.group(1).strip('@"'), int(m.group(2)))
        for m in const_re.finditer(text)
        if not m.group(1).startswith("op_")
    ]

    def array_ints(name: str) -> list[int]:
        m = re.search(rf"pub const {name}: \[256\]u8 = \.{{(.*?)}};", text, re.S)
        return [int(v) for v in m.group(1).replace("\n", " ").split(",") if v.strip()]

    def array_strs(name: str) -> list[str]:
        m = re.search(rf"pub const {name}: \[256\]\[\]const u8 = \.{{(.*?)}};", text, re.S)
        return re.findall(r'"([^"]*)"', m.group(1))

    return {
        "consts": consts,
        "size": array_ints("opcode_size"),
        "n_pop": array_ints("opcode_n_pop"),
        "n_push": array_ints("opcode_n_push"),
        "fmt": array_strs("opcode_format_name"),
        "name": array_strs("opcode_name"),
    }


def legacy_live_views(legacy):
    """Emulate the pre-refactor live accessors (table + handwritten switches
    from the old opcode.zig)."""

    def size_of(op):
        if 176 <= op <= 196:
            return {176: 1, 177: 5, 178: 1, 188: 2, 189: 3, 190: 2, 191: 2, 192: 1, 196: 1}.get(
                op, 1 if op <= 187 else 2
            )
        return legacy["size"][op]

    def format_of(op):
        if 176 <= op <= 196:
            if op in (176, 178, 192):
                return "none"
            if op == 177:
                return "i32"
            if 179 <= op <= 187:
                return "none_int"
            if op == 188:
                return "i8"
            if op == 189:
                return "i16"
            if op in (190, 191):
                return "const8"
            if 193 <= op <= 195:
                return "loc8"
            return "none_loc"
        return legacy["fmt"][op]

    short_names = [
        "private_in", "push_bigint_i32", "nop", "push_minus1", "push_0", "push_1",
        "push_2", "push_3", "push_4", "push_5", "push_6", "push_7", "push_i8",
        "push_i16", "push_const8", "fclosure8", "push_empty_string", "get_loc8",
        "put_loc8", "set_loc8",
    ]

    def name_of(op):
        if 176 <= op < 176 + len(short_names):
            return short_names[op - 176]
        return legacy["name"][op]

    def n_pop_of(op):
        if 176 <= op <= 196:
            if op == 176:
                return 2
            if op in (194, 195):
                return 1
            return 0
        return legacy["n_pop"][op]

    def n_push_of(op):
        if 176 <= op <= 196:
            if op == 194:
                return 0
            if op == 196:
                return 2
            return 1  # note: returns 1 for op 178 (nop) — a known table conflict
        return legacy["n_push"][op]

    return size_of, format_of, name_of, n_pop_of, n_push_of


# Phase-1 sizes previously hardwired in zjs_parser.zig (scanTrailingCode,
# parserEmittedOpcodeSize) and resolve_variables.zig
# (inputInstrSizeForRefTailScan, isScopeVarOp/isScopeRefOp/
# isScopePrivateFieldOp walkers).
HANDWRITTEN_PHASE1 = {
    "enter_scope": 3,
    "leave_scope": 3,
    "label": 5,
    "scope_get_var_undef": 7,
    "scope_get_var": 7,
    "scope_put_var": 7,
    "scope_delete_var": 7,
    "scope_make_ref": 11,
    "scope_get_ref": 7,
    "scope_put_var_init": 7,
    "scope_get_private_field": 7,
    "scope_get_private_field2": 7,
    "scope_put_private_field": 7,
    "scope_in_private_field": 7,
    "get_field_opt_chain": 5,
    # phase-1 sizes of non-temp opcodes special-cased by the old walkers
    "eval": 5,  # emitOpU32At: op + (argc | scope << 16)
    "apply_eval": 3,  # emitOpU16At: op + scope u16 (the old hardwired 2 was a
    #                   dead branch: stopsGlobalRefTailScan fires first)
    "with_get_var": 10,
    "with_put_var": 10,
    "with_delete_var": 10,
    "with_make_ref": 10,
    "with_get_ref": 10,
}

# Deliberate, reviewed deltas vs the legacy live accessors.
WHITELIST = {
    (178, "n_push"),  # old handwritten switch said 1; table/QuickJS say 0 (nop)
}


def verify_legacy(legacy_path: Path, formats, entries, op_count, temp_start, temp_end):
    legacy = parse_legacy(legacy_path)
    n_temp = temp_end - temp_start

    # --- id map comparison -------------------------------------------------
    new_ids = {}
    for e in entries:
        new_ids[e.name] = e.id
    old_ids = dict(legacy["consts"])
    problems = []
    for name, oid in old_ids.items():
        if name not in new_ids:
            problems.append(f"op constant missing in new table: {name} (old id {oid})")
        elif new_ids[name] != oid:
            problems.append(f"op id drift: {name} old {oid} new {new_ids[name]}")
    for name, nid in new_ids.items():
        if name not in old_ids:
            problems.append(f"op constant only in new table: {name} (id {nid})")

    # --- view comparison ----------------------------------------------------
    by_index = {e.index: e for e in entries}

    def final_entry(op):
        if op >= op_count:
            return None
        idx = op + n_temp if op >= temp_start else op
        return by_index[idx]

    def phase1_entry(op):
        if temp_start <= op < temp_end:
            return by_index[op]
        return final_entry(op)

    size_of, format_of, name_of, n_pop_of, n_push_of = legacy_live_views(legacy)
    whitelisted = []
    for opid in range(256):
        e = final_entry(opid)
        new_vals = {
            "size": e.size if e else 0,
            "fmt": e.fmt if e else "none",
            "name": e.name if e else "",
            "n_pop": e.n_pop if e else 0,
            "n_push": e.n_push if e else 0,
        }
        old_vals = {
            "size": size_of(opid),
            "fmt": format_of(opid),
            "name": name_of(opid),
            "n_pop": n_pop_of(opid),
            "n_push": n_push_of(opid),
        }
        for field in new_vals:
            if new_vals[field] != old_vals[field]:
                msg = f"final view drift at id {opid} ({old_vals['name'] or '?'}) {field}: old {old_vals[field]!r} new {new_vals[field]!r}"
                if (opid, field) in WHITELIST:
                    whitelisted.append(msg)
                else:
                    problems.append(msg)

    # --- phase-1 comparison vs handwritten sizes ----------------------------
    for name, expected in HANDWRITTEN_PHASE1.items():
        opid = new_ids[name]
        e = phase1_entry(opid)
        if e is None or e.size != expected or e.name != name:
            problems.append(
                f"phase-1 drift for {name} (id {opid}): handwritten size {expected}, "
                f"table entry {e.name if e else None} size {e.size if e else None}"
            )

    print(f"verify-legacy: {len(problems)} problem(s), {len(whitelisted)} whitelisted delta(s)")
    for msg in whitelisted:
        print(f"  whitelisted: {msg}")
    for msg in problems:
        print(f"  PROBLEM: {msg}")
    return not problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the generated file is stale")
    ap.add_argument("--verify-legacy", metavar="OLD_ZIG", help="compare against a pre-refactor opcodes_generated.zig")
    args = ap.parse_args()

    formats, entries, op_count, temp_start, temp_end = parse_fixture(FIXTURE.read_text())
    rendered = render(formats, entries, op_count, temp_start, temp_end)

    if args.verify_legacy:
        ok = verify_legacy(Path(args.verify_legacy), formats, entries, op_count, temp_start, temp_end)
        return 0 if ok else 1

    if args.check:
        if OUTPUT.read_text() != rendered:
            print(f"{OUTPUT} is stale; run: python3 tools/gen_opcodes.py", file=sys.stderr)
            return 1
        print(f"{OUTPUT} is up to date")
        return 0

    OUTPUT.write_text(rendered)
    print(f"wrote {OUTPUT}: {op_count} opcodes, {temp_end - temp_start} temps, {len(entries)} table entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
