#!/usr/bin/env python3
"""Match build outputs to compiler states X / Y by normalized symbol distance.

Why a matcher is needed
-----------------------
`compare_symbol_disassembly.py` gives a global signature that identifies which
build instance a binary is, but that signature cannot be used as a state label
shared across candidates: the experiment variant and the layout pad both change
it by construction. Deciding that "this B binary is in the same compiler state
as that A binary" therefore has to be done on the symbols the variant and the
pad do *not* touch.

Distance is computed over symbols after excluding three groups:

  * pad-generated symbols (`zjs_dossier_pad_*`);
  * harness/attestation-only symbols carrying the variant identity;
  * the functions the simple-constructor switch is known to rewrite.

A pairing is only accepted when it is unambiguous, by either margin rule:

    cross_state_distance >= 4 x same_state_distance
    cross_state_distance -  same_state_distance >= 1000

If neither holds the classifier reports `ambiguous` and the caller must stop
rather than guess -- a mislabelled state would silently mix two populations.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from itertools import permutations
from pathlib import Path
from typing import Any

CLASSIFIER_VERSION = 1

# Symbols whose difference between two binaries is explained by the experiment
# itself rather than by the compiler state, and which must not vote.
EXCLUDED_PATTERNS = (
    # layout-lineage pad
    re.compile(r"^zjs_dossier_pad_\d+$"),
    # variant attestation / harness-only surface
    re.compile(r"dossier_variant"),
    re.compile(r"dossier_options"),
    # functions the simple-constructor switch directly rewrites or removes
    re.compile(r"constructSimpleFieldConstructor"),
    re.compile(r"ensureSimpleCtorMemo"),
    re.compile(r"simpleFieldConstructorPattern"),
    re.compile(r"simpleLocalThisFieldConstructorPattern"),
    re.compile(r"simpleStackThisFieldConstructorPattern"),
    re.compile(r"tryAppendSimpleConstructorField"),
    re.compile(r"decodeSimpleConstructor"),
    re.compile(r"prototypeChainBlocksSimpleFieldStore"),
    re.compile(r"constructOrdinaryBytecodeFunctionObject"),
    re.compile(r"prepareSameMachineConstructorAfterFirstPoll"),
)

# A missing or extra symbol is stronger evidence than one changed body.
PRESENCE_PENALTY = 10
MARGIN_RATIO = 4.0
MARGIN_ABSOLUTE = 1000

# A candidate that genuinely shares a reference's compiler state matches it
# exactly once switch-owned and pad symbols are excluded -- measured distance is
# 0 on real two-state binaries. Without this bound a margin rule alone can be
# satisfied by a build belonging to neither reference: a third state sitting
# nearer Y than X passes at ratio 40 while its true same-state distance is not
# zero. Such a build must be reported as unmatched, not filed under the closer
# label. If a future toolchain makes honest same-state distance nonzero, this
# has to be re-calibrated deliberately rather than relaxed.
SAME_STATE_TOLERANCE = 0


def excluded(name: str) -> bool:
    return any(pattern.search(name) for pattern in EXCLUDED_PATTERNS)


def votable(identity: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {n: e for n, e in identity["symbols"].items() if not excluded(n)}


def distance(left: dict[str, Any], right: dict[str, Any]) -> dict[str, Any]:
    a, b = votable(left), votable(right)
    shared = set(a) & set(b)
    size_changed = sum(1 for n in shared if a[n]["size"] != b[n]["size"])
    body_changed = sum(
        1 for n in shared
        if a[n]["normalized_body_sha256"] != b[n]["normalized_body_sha256"]
    )
    added = len(set(b) - set(a))
    removed = len(set(a) - set(b))
    total = size_changed + body_changed + PRESENCE_PENALTY * (added + removed)
    return {
        "distance": total,
        "size_changed": size_changed,
        "body_changed": body_changed,
        "added": added,
        "removed": removed,
        "votable_symbols": len(shared),
    }


def match(
    reference: dict[str, dict[str, Any]],
    candidates: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    """Assign two candidate builds to the two reference states.

    `reference` and `candidates` are both {label: identity}; reference labels
    are the state names (conventionally "X" and "Y").
    """
    ref_labels = sorted(reference)
    cand_labels = sorted(candidates)
    if len(ref_labels) != 2 or len(cand_labels) != 2:
        raise ValueError("matcher requires exactly two references and two candidates")

    matrix = {
        f"{c}->{r}": distance(candidates[c], reference[r])["distance"]
        for c in cand_labels
        for r in ref_labels
    }

    scored = []
    for order in permutations(ref_labels):
        assignment = dict(zip(cand_labels, order))
        total = sum(matrix[f"{c}->{r}"] for c, r in assignment.items())
        scored.append((total, assignment))
    scored.sort(key=lambda item: item[0])

    same_total, best = scored[0]
    cross_total, _ = scored[1]

    ratio_ok = same_total == 0 or cross_total >= MARGIN_RATIO * same_total
    absolute_ok = (cross_total - same_total) >= MARGIN_ABSOLUTE
    separated = ratio_ok or absolute_ok
    belongs = same_total <= SAME_STATE_TOLERANCE

    if not separated:
        verdict = "ambiguous"
    elif not belongs:
        # Well separated, but the winning pairing still is not an exact match:
        # at least one candidate belongs to neither reference state.
        verdict = "no_matching_state"
    else:
        verdict = "matched"

    return {
        "state_classifier_version": CLASSIFIER_VERSION,
        "assignment": best if verdict == "matched" else None,
        "verdict": verdict,
        "same_state_tolerance": SAME_STATE_TOLERANCE,
        "candidate_belongs_to_reference_states": belongs,
        "same_state_distance": same_total,
        "cross_state_distance": cross_total,
        "margin_ratio": (
            float("inf") if same_total == 0 else cross_total / same_total
        ),
        "margin_absolute": cross_total - same_total,
        "rule_ratio_satisfied": ratio_ok,
        "rule_absolute_satisfied": absolute_ok,
        "distance_matrix": matrix,
        "reference_signatures": {
            r: reference[r].get("global_normalized_signature") for r in ref_labels
        },
        "candidate_signatures": {
            c: candidates[c].get("global_normalized_signature") for c in cand_labels
        },
    }


def load(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    dist = sub.add_parser("distance", help="distance between two identities")
    dist.add_argument("left")
    dist.add_argument("right")

    m = sub.add_parser("match", help="assign two candidates to two reference states")
    m.add_argument("--reference-x", required=True)
    m.add_argument("--reference-y", required=True)
    m.add_argument("--candidate", required=True, action="append", dest="candidates")
    m.add_argument("-o", "--output")

    args = parser.parse_args(argv)

    if args.command == "distance":
        print(json.dumps(distance(load(args.left), load(args.right)), indent=1))
        return 0

    if len(args.candidates) != 2:
        print("error: exactly two --candidate arguments required", file=sys.stderr)
        return 2

    result = match(
        {"X": load(args.reference_x), "Y": load(args.reference_y)},
        {Path(p).stem: load(p) for p in args.candidates},
    )
    text = json.dumps(result, indent=1)
    if args.output:
        Path(args.output).write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0 if result["verdict"] == "matched" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError) as error:
        print(f"classify_build_state: {error}", file=sys.stderr)
        raise SystemExit(2)
