#!/usr/bin/env python3
"""P7-42 stage attribution: map sampled IPs onto bridge stages via addr->srcline.

Why not `perf annotate` alone: the bridge is almost entirely `inline fn`, so the
stage boundaries do not exist as symbols. What does survive is the DWARF line
table: every inlined copy still carries line records. This tool

1. disassembles a symbol range with `objdump -d -l`, producing an exact
   address -> file:line map (one entry per instruction, so the static
   instruction census per stage is exact, not sampled);
2. buckets the addresses into named stages with an explicit, auditable
   file:line-range table;
3. aggregates `perf script` sample IPs into the same buckets.

The static census is the trustworthy half: every bridge stage runs exactly once
per callback (P7-41 §3 proved this with gdb counters), so static instruction
counts per stage equal dynamic instructions per callback, with the single
exception of the <=3-iteration argument copy loop. The sampled half inherits
PMU skid and is reported as such.
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

INSN_RE = re.compile(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)$")
LINE_RE = re.compile(r"^(/?[^\s:]+):(\d+)(?: \(discriminator \d+\))?$")


def symbols(binary):
    out = subprocess.run(["nm", "--print-size", binary],
                         capture_output=True, text=True).stdout
    syms = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        addr, size, _kind, name = parts
        syms[name] = (int(addr, 16), int(size, 16))
    return syms


def disasm_lines(binary, start, stop):
    """Return [(addr, srcline, text)] for every instruction in [start, stop)."""
    out = subprocess.run(
        ["objdump", "-d", "-l", f"--start-address={hex(start)}",
         f"--stop-address={hex(stop)}", binary],
        capture_output=True, text=True).stdout
    cur = None
    rows = []
    for raw in out.splitlines():
        s = raw.strip()
        m = LINE_RE.match(s)
        if m and (s.startswith("/") or s.startswith("src")):
            path = m.group(1)
            if path.startswith(ROOT + "/"):
                path = path[len(ROOT) + 1:]
            cur = f"{path}:{m.group(2)}"
            continue
        mi = INSN_RE.match(raw)
        if mi:
            rows.append((int(mi.group(1), 16), cur, mi.group(3).strip()))
    return rows


def load_stage_table(path):
    with open(path) as fh:
        return json.load(fh)


def stage_of(srcline, table, default, sym):
    """Stage lookup is SYMBOL-SCOPED. Without scoping, shared inline helpers
    (`Vm.next`, `FunctionBytecode.byteCode`, `Machine.loadCurrentLevel`,
    `Stack.topPtr`) leak samples between the driver re-entry stage and the
    return handler, because the identical file:line appears in several of the
    mapped symbols."""
    if srcline is None:
        return default
    f, _, l = srcline.rpartition(":")
    try:
        ln = int(l)
    except ValueError:
        return default
    for stage in table["stages"]:
        scope = stage.get("symbol_scope")
        if scope is not None and sym not in scope:
            continue
        for rng in stage["ranges"]:
            if rng["file"] == f and rng["lo"] <= ln <= rng["hi"]:
                return stage["name"]
    return default


def perf_ips(data_path):
    out = subprocess.run(["perf", "script", "-i", data_path, "-F", "ip"],
                         capture_output=True, text=True).stdout
    hist = collections.Counter()
    total = 0
    for line in out.splitlines():
        s = line.strip()
        if not s:
            continue
        try:
            ip = int(s, 16)
        except ValueError:
            continue
        hist[ip] += 1
        total += 1
    return hist, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--stages", required=True)
    ap.add_argument("--data", action="append", default=[],
                    help="label=path/to/perf.data, repeatable")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    table = load_stage_table(args.stages)
    syms = symbols(args.binary)

    addr_stage = {}
    addr_line = {}
    static = collections.Counter()
    static_by_line = collections.Counter()
    per_symbol_static = {}
    for entry in table["symbols"]:
        sym = entry["name"]
        default = entry.get("default_stage", "Zother")
        if sym not in syms:
            sys.exit("missing symbol: " + sym)
        start, size = syms[sym]
        rows = disasm_lines(args.binary, start, start + size)
        per_symbol_static[sym] = len(rows)
        for addr, srcline, _text in rows:
            st = stage_of(srcline, table, default, sym)
            addr_stage[addr] = st
            addr_line[addr] = srcline
            static[st] += 1
            static_by_line[(st, srcline)] += 1

    result = {"binary": os.path.abspath(args.binary),
              "stage_table": os.path.abspath(args.stages),
              "symbol_static_instruction_counts": per_symbol_static,
              "static_instructions_per_stage": dict(static),
              "static_instructions_by_line": {
                  f"{k[0]}|{k[1]}": v for k, v in
                  sorted(static_by_line.items(), key=lambda kv: -kv[1])},
              "samples": {}}

    for spec in args.data:
        label, _, path = spec.partition("=")
        hist, total = perf_ips(path)
        in_range = collections.Counter()
        mapped = 0
        for ip, n in hist.items():
            if ip in addr_stage:
                in_range[addr_stage[ip]] += n
                mapped += n
        by_line = collections.Counter()
        for ip, n in hist.items():
            if ip in addr_stage:
                by_line[(addr_stage[ip], addr_line[ip])] += n
        result["samples"][label] = {
            "perf_data": os.path.abspath(path),
            "total_samples": total,
            "samples_in_mapped_symbols": mapped,
            "by_stage": dict(in_range),
            "by_line_top": {f"{k[0]}|{k[1]}": v for k, v in
                            sorted(by_line.items(), key=lambda kv: -kv[1])[:60]},
        }
        print(f"{label}: total={total} mapped={mapped} "
              f"({100.0*mapped/max(total,1):.2f}%)")
        for st, n in sorted(in_range.items(), key=lambda kv: -kv[1]):
            print(f"    {st:44s} {n:8d}  {100.0*n/max(total,1):6.2f}% of process")

    with open(args.out, "w") as fh:
        json.dump(result, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
