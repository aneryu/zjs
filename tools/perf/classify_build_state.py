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
import hashlib
import re
import sys
from itertools import permutations
from pathlib import Path
from typing import Any

CLASSIFIER_VERSION = 2

POLICY_PATH = Path(__file__).resolve().parent / "state_exclusions.json"

# A missing or extra symbol is stronger evidence than one changed body.
PRESENCE_PENALTY = 10

# Membership is exact. A candidate that genuinely shares a reference's compiler
# state matches it with distance 0 once switch-owned and pad symbols are
# excluded -- measured on real two-state binaries. Separation alone is not
# enough: a third state sitting nearer Y than X satisfied a 4x ratio rule at
# ratio 40 while its true same-state distance was 10, and would have been filed
# under Y. If a future toolchain makes honest same-state distance nonzero, the
# references must be rebuilt and the comparator re-calibrated, not this widened.
SAME_STATE_TOLERANCE = 0

# Separation is now a health gate on the reference pair itself, not an
# admission route for candidates: it asks whether X and Y are far enough apart
# to be distinguishable at all.
ABSOLUTE_STATE_SEPARATION_MIN = 1000


class PolicyError(RuntimeError):
    """Raised when the checked-in exclusion policy cannot be honoured."""


def load_policy(path: Path = POLICY_PATH) -> dict[str, Any]:
    """Load the checked-in exclusion policy.

    The exclusion set decides which symbols get to vote on state membership, so
    it carries the same authority as a performance policy: it lives in git,
    changing it requires review, and an artifact under test may not extend it.
    """
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise PolicyError(f"cannot read exclusion policy: {error}") from error
    try:
        policy = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PolicyError(f"invalid exclusion policy JSON: {error}") from error
    for field in ("policy_id", "policy_version", "exact_symbols", "audited_patterns"):
        if field not in policy:
            raise PolicyError(f"exclusion policy is missing {field}")
    policy["_sha256"] = hashlib.sha256(raw).hexdigest()
    policy["_exact"] = frozenset(policy["exact_symbols"])
    policy["_patterns"] = tuple(
        re.compile(entry["pattern"]) for entry in policy["audited_patterns"]
    )
    policy["_minimum_votable"] = int(policy.get("minimum_votable_symbols", 0))
    return policy


def excluded(name: str, policy: dict[str, Any]) -> bool:
    if name in policy["_exact"]:
        return True
    return any(pattern.search(name) for pattern in policy["_patterns"])


def votable(
    identity: dict[str, Any], policy: dict[str, Any]
) -> dict[str, dict[str, Any]]:
    return {n: e for n, e in identity["symbols"].items() if not excluded(n, policy)}


def distance(
    left: dict[str, Any],
    right: dict[str, Any],
    policy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    policy = policy or load_policy()
    a, b = votable(left, policy), votable(right, policy)
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
    policy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Assign two candidate builds to the two reference states.

    Three layers, evaluated in order:

      1. reference health -- X and Y must differ, and by at least
         ABSOLUTE_STATE_SEPARATION_MIN, or they are not distinguishable states;
      2. membership -- each candidate must match its assigned reference
         *exactly* (distance 0). Separation is not an admission route: a third
         state nearer Y than X clears any ratio bar while belonging to neither;
      3. bijection -- the two candidates must occupy the two distinct states.

    Ratio and gap are reported for diagnosis only and never decide a verdict.
    """
    policy = policy or load_policy()
    ref_labels = sorted(reference)
    cand_labels = sorted(candidates)
    if len(ref_labels) != 2 or len(cand_labels) != 2:
        raise ValueError("matcher requires exactly two references and two candidates")

    reference_gap = distance(reference[ref_labels[0]], reference[ref_labels[1]], policy)
    votable_count = reference_gap["votable_symbols"]

    matrix: dict[str, int] = {}
    detail: dict[str, dict[str, Any]] = {}
    for c in cand_labels:
        for r in ref_labels:
            measured = distance(candidates[c], reference[r], policy)
            matrix[f"{c}->{r}"] = measured["distance"]
            detail[f"{c}->{r}"] = measured

    exact_matches = {
        c: [r for r in ref_labels if matrix[f"{c}->{r}"] <= SAME_STATE_TOLERANCE]
        for c in cand_labels
    }

    assignment: dict[str, str] | None = None
    if votable_count < policy["_minimum_votable"]:
        verdict = "insufficient_votable_symbols"
    elif reference_gap["distance"] == 0:
        verdict = "invalid_references"
    elif reference_gap["distance"] < ABSOLUTE_STATE_SEPARATION_MIN:
        verdict = "insufficient_state_separation"
    elif any(len(m) == 0 for m in exact_matches.values()):
        verdict = "no_matching_state"
    elif any(len(m) > 1 for m in exact_matches.values()):
        # Only reachable if the references are not actually distinct, which the
        # earlier gate should already have caught; kept as a belt-and-braces
        # guard rather than silently picking one.
        verdict = "ambiguous"
    elif len({m[0] for m in exact_matches.values()}) != 2:
        verdict = "non_bijective_assignment"
    else:
        verdict = "matched"
        assignment = {c: exact_matches[c][0] for c in cand_labels}

    same_total = (
        sum(matrix[f"{c}->{assignment[c]}"] for c in cand_labels)
        if assignment
        else min(
            sum(matrix[f"{c}->{r}"] for c, r in zip(cand_labels, order))
            for order in permutations(ref_labels)
        )
    )
    cross_total = max(
        sum(matrix[f"{c}->{r}"] for c, r in zip(cand_labels, order))
        for order in permutations(ref_labels)
    )

    return {
        "state_classifier_version": CLASSIFIER_VERSION,
        "verdict": verdict,
        "assignment": assignment,
        "same_state_tolerance": SAME_STATE_TOLERANCE,
        "absolute_state_separation_min": ABSOLUTE_STATE_SEPARATION_MIN,
        "excluded_symbols_policy": policy["policy_id"],
        "excluded_symbols_policy_version": policy["policy_version"],
        "excluded_symbols_sha256": policy["_sha256"],
        "votable_symbols": votable_count,
        "reference_separation": reference_gap["distance"],
        "same_state_distance": same_total,
        "cross_state_distance": cross_total,
        # Diagnostics only. Written as null rather than a JSON-illegal Infinity
        # when the denominator is zero, which is the healthy case.
        "separation_ratio": (
            None if same_total == 0 else cross_total / same_total
        ),
        "separation_gap": cross_total - same_total,
        "exact_matches": exact_matches,
        "distance_matrix": matrix,
        "distance_detail": detail,
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
