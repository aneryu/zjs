#!/usr/bin/env python3
"""P7-60 op.lnot frequency census.

Two independent passes, on purpose:

* ``--mode count`` runs the temporary counter build (built with
  ``-Dzjs_enable_opcode_profile=true``, never used for any timing number) once
  per corpus entry and reads ``$ZJS_LNOT_CENSUS_FILE``.  No host lock: counting
  only, exactly as P7-51A did.
* ``--mode cycles`` runs the clean baseline build under ``perf stat`` with the
  exclusive host lock and ``taskset``, to obtain the denominator.

Corpus groups are declared in ``corpus.json`` so the entry list is auditable.
"""

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = "/tmp/zjs-host-heavy.lock"


def load_corpus():
    return json.load(open(os.path.join(HERE, "corpus.json")))


def entries(corpus):
    out = []
    for group, spec in corpus["groups"].items():
        for root in spec["roots"]:
            root = os.path.expanduser(root)
            if os.path.isfile(root):
                out.append((group, os.path.splitext(os.path.basename(root))[0], root))
                continue
            if not os.path.isdir(root):
                continue
            for fn in sorted(os.listdir(root)):
                if not fn.endswith(".js"):
                    continue
                if fn in spec.get("exclude", []):
                    continue
                out.append((group, os.path.splitext(fn)[0], os.path.join(root, fn)))
    return out


def parse_counts(path):
    if not os.path.exists(path):
        return None
    vals = {}
    for line in open(path):
        parts = line.split()
        if len(parts) == 2:
            vals[parts[0]] = int(parts[1])
    return vals


def run_count(binary, script, tmp, timeout):
    out = os.path.join(tmp, "lnot_census.txt")
    if os.path.exists(out):
        os.unlink(out)
    env = dict(os.environ, ZJS_LNOT_CENSUS_FILE=out)
    t0 = time.perf_counter()
    try:
        proc = subprocess.run([binary, script], capture_output=True, text=True,
                              env=env, timeout=timeout)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "wall_s": time.perf_counter() - t0}
    wall = time.perf_counter() - t0
    vals = parse_counts(out) or {}
    return {"status": "ok" if rc == 0 else f"exit{rc}",
            "wall_s": wall,
            "lnot_total": vals.get("lnot_total", 0),
            "tags": {k[len("lnot_tag_"):]: v for k, v in vals.items()
                     if k.startswith("lnot_tag_")}}


def parse_perf(stderr_text, events):
    out = {}
    for line in stderr_text.splitlines():
        parts = line.split(",")
        if len(parts) < 3:
            continue
        raw, _unit, ev = parts[0], parts[1], parts[2]
        if ev not in events:
            continue
        if "not counted" in raw or "not supported" in raw:
            continue
        out[ev] = float(raw)
    return out


def run_cycles(binary, script, cpu, pmu, timeout, tmp):
    """perf stat one run.  The census env var is set unconditionally: on the
    clean build it is inert, and on the counter build it makes the numerator and
    the denominator come out of the *same* process, which matters because the
    Octane-derived product workloads are wall-clock scheduled."""
    events = [f"{pmu}/cycles/", f"{pmu}/instructions/"]
    out = os.path.join(tmp, "lnot_census_cyc.txt")
    if os.path.exists(out):
        os.unlink(out)
    env = dict(os.environ, ZJS_LNOT_CENSUS_FILE=out)
    cmd = ["taskset", "-c", str(cpu), "perf", "stat", "-x,",
           "-e", ",".join(events), "--", binary, script]
    t0 = time.perf_counter()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, env=env)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "wall_s": time.perf_counter() - t0}
    wall = time.perf_counter() - t0
    vals = parse_perf(proc.stderr, events)
    counts = parse_counts(out) or {}
    return {"status": "ok" if rc == 0 else f"exit{rc}",
            "wall_s": wall,
            "cycles": vals.get(events[0]),
            "instructions": vals.get(events[1]),
            "lnot_total": counts.get("lnot_total"),
            "tags": {k[len("lnot_tag_"):]: v for k, v in counts.items()
                     if k.startswith("lnot_tag_")}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["count", "cycles"], required=True)
    ap.add_argument("--binary", required=True)
    ap.add_argument("--tmp", default=os.environ.get("TMPDIR", "/tmp"))
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--groups", default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    corpus = load_corpus()
    todo = entries(corpus)
    if args.groups:
        want = set(args.groups.split(","))
        todo = [e for e in todo if e[0] in want]

    binary = os.path.abspath(args.binary)
    results = {}
    lock_fh = None
    if args.mode == "cycles":
        lock_fh = open(LOCK, "a")
        fcntl.flock(lock_fh, fcntl.LOCK_EX)
    try:
        for group, name, path in todo:
            key = f"{group}/{name}"
            if args.mode == "count":
                rec = run_count(binary, path, args.tmp, args.timeout)
                print(f"{key:52s} {rec['status']:8s} lnot={rec.get('lnot_total', 0):>12} "
                      f"{rec['wall_s']:6.2f}s", flush=True)
            else:
                rec = run_cycles(binary, path, args.cpu, args.pmu, args.timeout, args.tmp)
                cyc = rec.get("cycles")
                print(f"{key:52s} {rec['status']:8s} cyc={cyc if cyc is None else f'{cyc:.0f}':>14} "
                      f"{rec['wall_s']:6.2f}s", flush=True)
            rec["script"] = path
            rec["group"] = group
            results[key] = rec
    finally:
        if lock_fh is not None:
            fcntl.flock(lock_fh, fcntl.LOCK_UN)
            lock_fh.close()

    payload = {
        "collector": "tools/perf/logical_not/run_census.py",
        "mode": args.mode,
        "binary": binary,
        "cpu": args.cpu if args.mode == "cycles" else None,
        "pmu": args.pmu if args.mode == "cycles" else None,
        "host_lock": "exclusive" if args.mode == "cycles" else "none (counting only)",
        "entries": results,
    }
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
