#!/usr/bin/env python3
"""P7-61 dynamic purity probe: how many times does one `!x` reach each stage?

Counting only, never timing -- the binaries here are built with
`-Dzjs_enable_opcode_profile=true` plus a temporary counter, and the host lock
is therefore not taken (the P7-51A / P7-60 precedent).

Each case is run at two iteration counts and DIFFERENCED, so the harness,
parser and bootstrap hits cancel and what remains is exactly the per-`!` cost.
HTMLDDA objects are only constructible through `$262.IsHTMLDDA`, so that one
case runs under the test262 runner instead of the plain CLI; the same
differencing applies.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

IMMEDIATE = ["undefined", "null", "false", "true", "int_zero", "int_nonzero"]

# `+0.0` is deliberately absent: both engines normalise integral positive zero
# back to the int tag (P7-60 §3), so a "+0 float" cell does not exist.
COMPLEX = [
    "double_neg_zero", "double_nan", "double_nonzero",
    "bigint_short", "bigint_heap",
    "string_empty", "string_short", "string_rope",
    "symbol", "object_plain", "object_function", "object_trap",
]

DECLS = {
    "undefined": "var src=[undefined];",
    "null": "var src=[null];",
    "false": "var src=[false];",
    "true": "var src=[true];",
    "int_zero": "var src=[0];",
    "int_nonzero": "var src=[7];",
    "double_neg_zero": "var src=[-0.0];",
    "double_nan": "var src=[NaN];",
    "double_nonzero": "var src=[1.5];",
    "bigint_short": "var src=[7n];",
    "bigint_heap": "var src=[123456789012345678901234567890n];",
    "string_empty": "var src=[''];",
    "string_short": "var src=['abcdefgh'];",
    "string_rope": "var src=['x'.repeat(70000) + 'y'.repeat(70000)];",
    "symbol": "var src=[Symbol('s')];",
    "object_plain": "var src=[{a:1}];",
    "object_function": "var src=[function(){}];",
    # `!obj` must never invoke valueOf/toString; if it did, this case throws.
    "object_trap": ("var src=[{valueOf(){throw new Error('valueOf ran');},"
                    "toString(){throw new Error('toString ran');}}];"),
}

SITES = ["hot_entered", "hot_immediate", "cold_body", "logical_not"]


def cli_source(decl, n):
    return (f"function run() {{\n"
            f"    {decl}\n"
            f"    var x = src[0];\n"
            f"    var t = 0;\n"
            f"    for (var i = 0; i < {n}; i++) {{ if (!x) t = t + 1; }}\n"
            f"    return t;\n"
            f"}}\n"
            f"print(run());\n")


DDA_SOURCE = """/*---
description: P7-61 HTMLDDA dynamic purity probe
flags: [noStrict]
---*/
var x = $262.IsHTMLDDA;
var t = 0;
for (var i = 0; i < %d; i++) {{ if (!x) t = t + 1; }}
if (t !== %d) throw new Error("HTMLDDA must be falsy");
if ((!x) !== true) throw new Error("!HTMLDDA must be true");
if ((!!x) !== false) throw new Error("!!HTMLDDA must be false");
"""


def read_probe(path):
    vals = {s: 0 for s in SITES}
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) == 2 and parts[0] in vals:
                vals[parts[0]] += int(parts[1])
    return vals


def run_cli(binary, source, tmpdir):
    script = os.path.join(tmpdir, "case.js")
    probe = os.path.join(tmpdir, "probe.txt")
    with open(script, "w") as fh:
        fh.write(source)
    if os.path.exists(probe):
        os.unlink(probe)
    env = dict(os.environ, ZJS_LNOT_PROBE_FILE=probe)
    proc = subprocess.run([binary, script], capture_output=True, text=True,
                          env=env, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError(f"{binary} failed: {proc.stderr[-400:]}")
    return read_probe(probe), proc.stdout.strip()


def run_dda(runner, n, tmpdir, repo):
    script = os.path.join(tmpdir, "lnot_htmldda.js")
    probe = os.path.join(tmpdir, "probe.txt")
    with open(script, "w") as fh:
        fh.write(DDA_SOURCE % (n, n))
    if os.path.exists(probe):
        os.unlink(probe)
    env = dict(os.environ, ZJS_LNOT_PROBE_FILE=probe)
    proc = subprocess.run(
        [runner, "-c", "test262.conf", "-t", "1", "-T", "60000", "-f", script],
        capture_output=True, text=True, env=env, cwd=repo, timeout=600)
    if "0/1 errors" not in proc.stdout:
        raise RuntimeError("HTMLDDA fixture did not pass: " + proc.stdout[-400:])
    return read_probe(probe), "ok"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True, help="counter-build zjs CLI")
    ap.add_argument("--runner", default=None, help="counter-build run-test262")
    ap.add_argument("--repo", default=os.getcwd())
    ap.add_argument("--label", required=True)
    ap.add_argument("--n1", type=int, default=1000)
    ap.add_argument("--n2", type=int, default=3000)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    delta_iters = args.n2 - args.n1
    rows = {}
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmpdir:
        for name in IMMEDIATE + COMPLEX:
            lo, out_lo = run_cli(args.binary, cli_source(DECLS[name], args.n1), tmpdir)
            hi, out_hi = run_cli(args.binary, cli_source(DECLS[name], args.n2), tmpdir)
            # The loop counts how many iterations saw `!x` as true, so a falsy
            # operand must report every iteration and a truthy one none. Anything
            # else means the case did not run what it claims to (and a throwing
            # `valueOf` case would have failed in run_cli already).
            for out, n in ((out_lo, args.n1), (out_hi, args.n2)):
                if out not in (str(n), "0"):
                    raise RuntimeError(f"{name}: unexpected stdout {out!r}")
            if (out_lo == "0") != (out_hi == "0"):
                raise RuntimeError(f"{name}: truthiness flipped between runs")
            rows[name] = {s: (hi[s] - lo[s]) / delta_iters for s in SITES}
            rows[name]["kind"] = "immediate" if name in IMMEDIATE else "complex"
            rows[name]["stdout_lo"] = out_lo
            rows[name]["stdout_hi"] = out_hi
            print(f"{name:20s} " + "  ".join(
                f"{s}={rows[name][s]:.4f}" for s in SITES), flush=True)
        if args.runner:
            lo, _ = run_dda(args.runner, args.n1, tmpdir, args.repo)
            hi, _ = run_dda(args.runner, args.n2, tmpdir, args.repo)
            rows["object_htmldda"] = {s: (hi[s] - lo[s]) / delta_iters for s in SITES}
            rows["object_htmldda"]["kind"] = "complex"
            rows["object_htmldda"]["host"] = "run-test262 ($262.IsHTMLDDA)"
            print("object_htmldda       " + "  ".join(
                f"{s}={rows['object_htmldda'][s]:.4f}" for s in SITES), flush=True)

    payload = {
        "collector": "tools/perf/logical_not/run_purity.py",
        "label": args.label,
        "binary": os.path.abspath(args.binary),
        "runner": os.path.abspath(args.runner) if args.runner else None,
        "iterations_low": args.n1,
        "iterations_high": args.n2,
        "note": ("counts are (high - low) / (high_iters - low_iters); the "
                 "harness/bootstrap hits cancel in the difference"),
        "sites": SITES,
        "rows": rows,
    }
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
