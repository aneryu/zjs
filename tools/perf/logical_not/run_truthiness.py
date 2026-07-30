#!/usr/bin/env python3
"""P7-61 semantic oracle: the truthiness tables must be byte-identical.

Runs both tables (`truthiness_table.js` for the `!x` / `!!x` expression forms,
`truthiness_stmt_table.js` for `if (!x)` / `while (!x)` / `for (; !x; )`)
against every engine build handed in, and reports the sha256 of each output
plus whether all of them agree. Correctness only -- no timing, no host lock.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TABLES = ["truthiness_table.js", "truthiness_stmt_table.js"]


def run(binary, script):
    proc = subprocess.run([binary, script], capture_output=True, text=True,
                          timeout=300)
    if proc.returncode != 0:
        raise RuntimeError(f"{binary} {script} failed: {proc.stderr[-400:]}")
    return proc.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", action="append", required=True,
                    metavar="LABEL=PATH")
    ap.add_argument("--dump-dir", default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    engines = []
    for spec in args.engine:
        label, _, path = spec.partition("=")
        engines.append((label, os.path.abspath(path)))

    payload = {"tables": {}, "engines": {k: v for k, v in engines}}
    all_ok = True
    for table in TABLES:
        script = os.path.join(HERE, table)
        digests = {}
        texts = {}
        for label, binary in engines:
            text = run(binary, script)
            texts[label] = text
            digests[label] = hashlib.sha256(text.encode()).hexdigest()
            if args.dump_dir:
                os.makedirs(args.dump_dir, exist_ok=True)
                with open(os.path.join(args.dump_dir,
                                       f"{table[:-3]}-{label}.txt"), "w") as fh:
                    fh.write(text)
        identical = len(set(digests.values())) == 1
        all_ok = all_ok and identical
        lines = len(next(iter(texts.values())).strip().splitlines())
        payload["tables"][table] = {"sha256": digests,
                                    "byte_identical": identical,
                                    "rows": lines}
        print(f"{table:28s} rows={lines:3d} identical={identical}")
        for label in digests:
            print(f"    {label:24s} {digests[label]}")
        if not identical:
            ref_label = engines[0][0]
            for label, _ in engines[1:]:
                if digests[label] != digests[ref_label]:
                    ref = texts[ref_label].splitlines()
                    cur = texts[label].splitlines()
                    for i, (a, b) in enumerate(zip(ref, cur)):
                        if a != b:
                            print(f"    DIFF line {i+1}: {ref_label}={a!r} "
                                  f"{label}={b!r}")

    payload["all_byte_identical"] = all_ok
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
