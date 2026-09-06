#!/usr/bin/env python3
"""Gantt of a build graph: run a command, sample its process tree, print
per-process start/duration so the critical path of a gate is visible.

    tools/gates/timeline.py -- zig build merge-gate --summary all

Samples `ps` every --interval seconds (default 0.5). Each distinct child
process (by pid) is one row; the label is a shortened argv. Sorted by
start time. Rows shorter than --min (default 1 s) are dropped so the
compiler driver's short helper spawns do not bury the picture.

`zig build --time-report` needs the web UI; this is the headless
substitute, and it also times the Run steps (test262, gate_smoke, the
test shards), which the compiler's report does not cover.
"""
import argparse
import os
import re
import subprocess
import sys
import time

def ps_snapshot():
    out = subprocess.run(["ps", "-eo", "pid,ppid,args", "--no-headers"],
                         capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        rows[int(parts[0])] = (int(parts[1]), parts[2])
    return rows

def descendants(rows, root):
    kids = {}
    for pid, (ppid, _) in rows.items():
        kids.setdefault(ppid, []).append(pid)
    seen, stack = set(), [root]
    while stack:
        p = stack.pop()
        for k in kids.get(p, []):
            if k not in seen:
                seen.add(k)
                stack.append(k)
    return seen

def label(args):
    a = args
    a = re.sub(r"/home/[^ ]*/\.zig-cache/o/[0-9a-f]+/", "cache/", a)
    a = re.sub(r"/home/[^ ]*/zig-out/bin/", "bin/", a)
    a = re.sub(r"/home/[^ ]*/zig/[^ ]*/zig ", "zig ", a)
    # The compiler driver: keep the emitted name.
    m = re.search(r"^(\S*zig) (build-exe|build-lib|test|build-obj)\b.*?--name (\S+)", a)
    if m:
        kind = m.group(2)
        extra = ""
        if "-fno-emit-bin" in a:
            extra = " (sema-only)"
        if "-OReleaseFast" in a:
            extra += " RF"
        return f"zig {kind} {m.group(3)}{extra}"
    m = re.search(r"^(\S*zig) build ", a)
    if m:
        return "zig build (runner)"
    if len(a) > 110:
        a = a[:107] + "..."
    return a

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--min", type=float, default=1.0, help="drop rows shorter than this (s)")
    ap.add_argument("--all", action="store_true", help="keep every row")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    ns = ap.parse_args()
    cmd = ns.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        ap.error("command required after --")
    t0 = time.monotonic()
    proc = subprocess.Popen(cmd)
    first, last, labels = {}, {}, {}
    while proc.poll() is None:
        now = time.monotonic() - t0
        rows = ps_snapshot()
        for pid in descendants(rows, proc.pid):
            if pid not in first:
                first[pid] = now
                labels[pid] = label(rows[pid][1])
            last[pid] = now
        time.sleep(ns.interval)
    total = time.monotonic() - t0
    print(f"\n=== timeline: {' '.join(cmd)}  total {total:.1f} s  exit {proc.returncode} ===")
    print(f"{'start':>7} {'dur':>7}  label")
    rowsout = []
    for pid in sorted(first, key=lambda p: first[p]):
        dur = last[pid] - first[pid] + ns.interval
        if not ns.all and dur < ns.min:
            continue
        rowsout.append((first[pid], dur, labels[pid]))
    # Collapse identical labels that overlap (the 8 test shards) into a range.
    for start, dur, lab in rowsout:
        print(f"{start:7.1f} {dur:7.1f}  {lab}")
    sys.exit(proc.returncode)

if __name__ == "__main__":
    main()
