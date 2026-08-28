#!/usr/bin/env python3
"""F0d raw-access CI gate (opcode-design.md 10.5).

The F0b/F0c migrations moved every reader and the shortening writers onto
the declaration-derived decode layer. This gate freezes that state: the
remaining raw accesses are enumerated in the allowlist with a reason and a
removal stage, and ANY INCREASE fails. A decrease is reported so the
baseline can be tightened in the same commit that earns it.

State-scan, not diff-scan: a diff gate misses relocations of old
violations into new files.

Rules (10.5's four, mapped to scannable patterns):
  R1 raw-emit    emitByte/appendByte of an `op.X` constant outside the
                 encoder seams
  R2 identity    `== op.X` / `!= op.X` physical comparisons and
                 `op.X =>` switch arms over stream bytes
  R3 operand     readInt/readU*At over `code[pc + N]` outside the decode
                 layer

Exit 0 clean, 1 on increase, 2 on usage error.
"""
import json, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
ALLOWLIST = pathlib.Path(__file__).with_name("raw_access_allowlist.json")

# The scanned population: everything that consumes or produces bytecode
# streams. The interpreter handler bodies (tailcall_dispatch*.zig) are NOT
# scanned -- executing `pc[0]` is their job, and the carrier adapter work
# that changes that is contract 4's, gated separately.
SCAN = [
    "src/bytecode.zig",
    "src/compiler/resolve_labels.zig",
    "src/compiler/resolve_variables.zig",
    "src/compiler/cfg.zig",
    "src/exec/small_inline.zig",
    "src/exec/vm_property.zig",
]

RULES = {
    "R1_raw_emit": re.compile(r"(?:emitByte|appendByte)\s*\(\s*(?:out\s*,\s*)?op\.[a-zA-Z_]"),
    "R2_identity": re.compile(r"(?:[=!]= op\.[a-zA-Z_@\"]|^\s*op\.[a-zA-Z_@\"][a-zA-Z_0-9@\".]*(?:\s*,\s*op\.[a-zA-Z_@\"][a-zA-Z_0-9@\".]*)*\s*=>)", re.M),
    "R3_operand": re.compile(r"readInt\s*\(\s*[iu](?:8|16|32|64)\s*,\s*(?:self\.)?code\["),
}

def scan():
    counts = {}
    for rel in SCAN:
        text = (ROOT / rel).read_text()
        # strip comments so documentation does not count as violations
        code = re.sub(r"//[^\n]*", "", text)
        for rule, pat in RULES.items():
            n = len(pat.findall(code))
            if n:
                counts.setdefault(rel, {})[rule] = n
    return counts

def main():
    update = "--update-baseline" in sys.argv
    counts = scan()
    if update:
        base = json.loads(ALLOWLIST.read_text()) if ALLOWLIST.exists() else {"entries": {}}
        for f, rules in counts.items():
            for r, n in rules.items():
                key = f"{f}:{r}"
                entry = base["entries"].get(key, {"reason": "TODO", "removal": "TODO"})
                entry["count"] = n
                base["entries"][key] = entry
        # drop entries that no longer occur
        base["entries"] = {k: v for k, v in base["entries"].items()
                           if counts.get(k.rsplit(":", 1)[0], {}).get(k.rsplit(":", 1)[1], 0) > 0}
        ALLOWLIST.write_text(json.dumps(base, indent=2) + "\n")
        print(f"baseline updated: {sum(r['count'] for r in base['entries'].values())} allowed accesses")
        return 0

    base = json.loads(ALLOWLIST.read_text())["entries"]
    failures, tighten = [], []
    seen = set()
    for f, rules in counts.items():
        for r, n in rules.items():
            key = f"{f}:{r}"
            seen.add(key)
            allowed = base.get(key, {}).get("count", 0)
            if n > allowed:
                failures.append(f"{key}: {n} found, {allowed} allowed")
            elif n < allowed:
                tighten.append(f"{key}: {n} found, {allowed} allowed -- tighten the baseline")
    for key in base:
        if key not in seen:
            tighten.append(f"{key}: 0 found, {base[key]['count']} allowed -- remove the entry")
    for t in tighten:
        print(f"note: {t}")
    if failures:
        print("RAW-ACCESS GATE FAILED (opcode-design.md 10.5: new raw stream")
        print("access belongs in the decode layer / encoder, not in consumers):")
        for x in failures:
            print(f"  {x}")
        return 1
    print(f"raw-access gate clean ({sum(r.get('count',0) for r in base.values())} allowed accesses frozen)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
