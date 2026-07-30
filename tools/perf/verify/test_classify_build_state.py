#!/usr/bin/env python3
"""Contract tests for the compiler-state matcher.

The matcher's job is to decide, for two builds of some (pad, variant, layer)
configuration, which of them shares a compiler state with which reference
build. Getting that wrong silently mixes two populations, so every test here
is about the matcher refusing to guess.
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "classify_build_state.py"
_spec = importlib.util.spec_from_file_location("cbs", MODULE_PATH)
cbs = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(cbs)


def identity(bodies: dict[str, str], sizes: dict[str, int] | None = None) -> dict:
    sizes = sizes or {}
    return {
        "global_normalized_signature": "sig-" + "".join(sorted(bodies.values()))[:8],
        "symbols": {
            name: {
                "present": True,
                "size": sizes.get(name, 16),
                "instruction_count": 4,
                "normalized_body_sha256": body,
            }
            for name, body in bodies.items()
        },
    }


def population(state: str, count: int, prefix: str = "core.f") -> dict[str, str]:
    """A body-hash population where `state` decides half the symbols."""
    out = {}
    for index in range(count):
        stable = f"{prefix}{index}"
        out[stable] = f"h{index}" if index % 2 == 0 else f"h{index}{state}"
    return out


def big(state: str, n: int = 3000) -> dict:
    """A population large enough to clear minimum_votable_symbols."""
    return identity(population(state, n))


class MatcherContract(unittest.TestCase):
    def test_x_then_y_matches(self) -> None:
        r = cbs.match({"X": big("X"), "Y": big("Y")}, {"c1": big("X"), "c2": big("Y")})
        self.assertEqual(r["verdict"], "matched")
        self.assertEqual(r["assignment"], {"c1": "X", "c2": "Y"})

    def test_swapped_order_still_matches_correctly(self) -> None:
        r = cbs.match({"X": big("X"), "Y": big("Y")}, {"c1": big("Y"), "c2": big("X")})
        self.assertEqual(r["verdict"], "matched")
        self.assertEqual(r["assignment"], {"c1": "Y", "c2": "X"})

    def test_x_plus_third_state_is_rejected(self) -> None:
        third = dict(population("Y", 3000))
        for i in range(1, 40, 2):
            third[f"core.f{i}"] = "drift"
        r = cbs.match({"X": big("X"), "Y": big("Y")},
                      {"real": big("X"), "third": identity(third)})
        self.assertEqual(r["verdict"], "no_matching_state")
        self.assertIsNone(r["assignment"])

    def test_third_state_with_large_margin_still_fails(self) -> None:
        """Separation must not rescue a non-member."""
        third = dict(population("Y", 3000))
        for i in range(1, 10, 2):
            third[f"core.f{i}"] = "drift"
        r = cbs.match({"X": big("X"), "Y": big("Y")},
                      {"real": big("X"), "third": identity(third)})
        self.assertEqual(r["verdict"], "no_matching_state")
        self.assertGreater(r["separation_gap"], 0)

    def test_two_candidates_in_the_same_state_is_non_bijective(self) -> None:
        r = cbs.match({"X": big("X"), "Y": big("Y")}, {"c1": big("X"), "c2": big("X")})
        self.assertEqual(r["verdict"], "non_bijective_assignment")
        self.assertIsNone(r["assignment"])

    def test_identical_references_are_invalid(self) -> None:
        r = cbs.match({"X": big("X"), "Y": big("X")}, {"c1": big("X"), "c2": big("X")})
        self.assertEqual(r["verdict"], "invalid_references")

    def test_references_below_separation_floor_are_rejected(self) -> None:
        near = dict(population("X", 3000))
        near["core.f1"] = "one-symbol-apart"
        r = cbs.match({"X": big("X"), "Y": identity(near)},
                      {"c1": big("X"), "c2": identity(near)})
        self.assertEqual(r["verdict"], "insufficient_state_separation")
        self.assertLess(r["reference_separation"], cbs.ABSOLUTE_STATE_SEPARATION_MIN)

    def test_too_few_votable_symbols_fails_closed(self) -> None:
        r = cbs.match({"X": identity(population("X", 40)), "Y": identity(population("Y", 40))},
                      {"c1": identity(population("X", 40)), "c2": identity(population("Y", 40))})
        self.assertEqual(r["verdict"], "insufficient_votable_symbols")

    def test_switch_owned_and_pad_symbols_do_not_vote(self) -> None:
        owned = {
            "exec.call_runtime.constructSimpleFieldConstructor": "differs",
            "exec.call_runtime.ensureSimpleCtorMemo": "differs",
            "exec.call_runtime.constructOrdinaryBytecodeFunctionObject": "differs",
            "zjs_dossier_pad_7": "differs",
        }
        r = cbs.match(
            {"X": big("X"), "Y": big("Y")},
            {
                "c1": identity({**population("X", 3000), **owned}),
                "c2": identity({**population("Y", 3000), **owned}),
            },
        )
        self.assertEqual(r["verdict"], "matched")
        self.assertEqual(r["same_state_distance"], 0)

    def test_size_change_alone_breaks_membership(self) -> None:
        """Equal bodies with a changed size is still a different build."""
        base = population("X", 3000)
        resized = identity(base, sizes={"core.f0": 999})
        r = cbs.match({"X": big("X"), "Y": big("Y")}, {"c1": resized, "c2": big("Y")})
        self.assertEqual(r["verdict"], "no_matching_state")

    def test_exclusion_policy_is_reported_for_audit(self) -> None:
        r = cbs.match({"X": big("X"), "Y": big("Y")}, {"c1": big("X"), "c2": big("Y")})
        self.assertEqual(r["excluded_symbols_policy"], "simple-constructor-v1")
        self.assertEqual(len(r["excluded_symbols_sha256"]), 64)
        self.assertIsNone(r["separation_ratio"])  # null, never JSON Infinity

    def test_policy_cannot_be_supplied_by_an_artifact(self) -> None:
        """The exclusion set comes from the checked-in file, not from input."""
        forged = big("X")
        forged["excluded_symbols"] = ["core.f1", "core.f3"]
        forged["exclusion_policy"] = {"exact_symbols": ["core.f1"]}
        r = cbs.match({"X": big("X"), "Y": big("Y")}, {"c1": forged, "c2": big("Y")})
        # The forged fields are ignored entirely: c1 is still an exact X.
        self.assertEqual(r["verdict"], "matched")
        self.assertEqual(r["excluded_symbols_policy"], "simple-constructor-v1")

    def test_requires_exactly_two_candidates(self) -> None:
        with self.assertRaises(ValueError):
            cbs.match({"X": big("X"), "Y": big("Y")}, {"only": big("X")})

    def test_presence_difference_is_weighted(self) -> None:
        a = identity({"core.a": "1"})
        b = identity({"core.a": "1", "core.b": "2"})
        measured = cbs.distance(a, b)
        self.assertEqual(measured["added"], 1)
        self.assertEqual(measured["distance"], cbs.PRESENCE_PENALTY)


if __name__ == "__main__":
    unittest.main(verbosity=2)
