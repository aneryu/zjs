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


class MatcherContract(unittest.TestCase):
    def test_clean_two_state_match(self) -> None:
        x, y = identity(population("X", 400)), identity(population("Y", 400))
        result = cbs.match(
            {"X": x, "Y": y},
            {"cand_a": identity(population("Y", 400)), "cand_b": identity(population("X", 400))},
        )
        self.assertEqual(result["verdict"], "matched")
        self.assertEqual(result["assignment"], {"cand_a": "Y", "cand_b": "X"})
        self.assertEqual(result["same_state_distance"], 0)
        self.assertGreater(result["cross_state_distance"], 0)

    def test_ambiguous_pairing_is_refused(self) -> None:
        """Near-equal pairings must not be resolved by a coin flip."""
        x = identity({"core.a": "1", "core.b": "2"})
        y = identity({"core.a": "1", "core.b": "3"})
        # Both candidates sit equally far from both references.
        c1 = identity({"core.a": "9", "core.b": "8"})
        c2 = identity({"core.a": "7", "core.b": "6"})
        result = cbs.match({"X": x, "Y": y}, {"c1": c1, "c2": c2})
        self.assertEqual(result["verdict"], "ambiguous")
        self.assertIsNone(result["assignment"])
        self.assertFalse(result["rule_ratio_satisfied"])
        self.assertFalse(result["rule_absolute_satisfied"])

    def test_variant_touched_symbols_do_not_vote(self) -> None:
        """A variant difference must not be mistaken for a state difference."""
        base = population("X", 200)
        x = identity(base)
        y = identity(population("Y", 200))
        # Same state as X, but every switch-owned symbol differs.
        switch_owned = {
            "exec.call_runtime.constructSimpleFieldConstructor": "differs",
            "exec.call_runtime.ensureSimpleCtorMemo": "differs",
            "exec.call_runtime.constructOrdinaryBytecodeFunctionObject": "differs",
            "zjs_dossier_pad_0": "differs",
        }
        cand_same_state = identity({**base, **switch_owned})
        cand_other_state = identity({**population("Y", 200), **switch_owned})
        result = cbs.match(
            {"X": x, "Y": y},
            {"same": cand_same_state, "other": cand_other_state},
        )
        self.assertEqual(result["verdict"], "matched")
        self.assertEqual(result["assignment"], {"same": "X", "other": "Y"})
        self.assertEqual(result["same_state_distance"], 0)

    def test_pad_symbols_do_not_inflate_distance(self) -> None:
        base = population("X", 100)
        with_pad = {**base, **{f"zjs_dossier_pad_{i}": f"p{i}" for i in range(50)}}
        self.assertEqual(
            cbs.distance(identity(base), identity(with_pad))["distance"], 0
        )

    def test_presence_difference_is_weighted(self) -> None:
        a = identity({"core.a": "1"})
        b = identity({"core.a": "1", "core.b": "2"})
        measured = cbs.distance(a, b)
        self.assertEqual(measured["added"], 1)
        self.assertEqual(measured["distance"], cbs.PRESENCE_PENALTY)

    def test_size_change_counts_even_with_equal_body(self) -> None:
        a = identity({"core.a": "1"}, sizes={"core.a": 16})
        b = identity({"core.a": "1"}, sizes={"core.a": 32})
        measured = cbs.distance(a, b)
        self.assertEqual(measured["size_changed"], 1)
        self.assertEqual(measured["body_changed"], 0)
        self.assertEqual(measured["distance"], 1)

    def test_absolute_margin_rule_is_computed_but_cannot_stand_alone(self) -> None:
        """Both separation rules are evaluated, but with SAME_STATE_TOLERANCE
        at 0 the ratio rule already admits every acceptable case (same == 0
        passes it outright). The absolute rule therefore only ever matters if
        the tolerance is deliberately widened; a large separation on its own
        must not rescue a candidate that belongs to neither reference."""
        x = identity(population("X", 4000))
        y = identity(population("Y", 4000))
        noise = {f"noise{i}": "n" for i in range(600)}
        result = cbs.match(
            {"X": x, "Y": y},
            {
                "c1": identity({**population("X", 4000), **noise}),
                "c2": identity({**population("Y", 4000), **noise}),
            },
        )
        # This case separates the two rules: the ratio is only 1.33 (below the
        # 4x bar) while the absolute gap is 4000 (well past 1000). The absolute
        # rule is genuinely load-bearing for separation...
        self.assertTrue(result["rule_absolute_satisfied"])
        self.assertFalse(result["rule_ratio_satisfied"])
        # ...yet membership is not exact, so the verdict is still withheld.
        self.assertEqual(result["verdict"], "no_matching_state")
        self.assertGreater(result["same_state_distance"], cbs.SAME_STATE_TOLERANCE)

    def test_third_state_masquerading_as_a_reference_is_rejected(self) -> None:
        """A build belonging to neither reference must not be filed under the
        closer one. The margin rules alone let a third state through at ratio
        40; only an exact same-state distance proves membership."""
        x, y = identity(population("X", 400)), identity(population("Y", 400))
        drifted = dict(population("Y", 400))
        for index in range(1, 20, 2):
            drifted[f"core.f{index}"] = "drift"
        result = cbs.match(
            {"X": x, "Y": y},
            {"real_x": identity(population("X", 400)), "third": identity(drifted)},
        )
        self.assertEqual(result["verdict"], "no_matching_state")
        self.assertIsNone(result["assignment"])
        self.assertFalse(result["candidate_belongs_to_reference_states"])
        # The margin rules were satisfied -- separation alone was not enough.
        self.assertTrue(
            result["rule_ratio_satisfied"] or result["rule_absolute_satisfied"]
        )

    def test_both_candidates_in_an_unknown_state_are_refused(self) -> None:
        x, y = identity(population("X", 400)), identity(population("Y", 400))
        result = cbs.match(
            {"X": x, "Y": y},
            {"z1": identity(population("Z", 400)), "z2": identity(population("Z", 400))},
        )
        self.assertIn(result["verdict"], ("ambiguous", "no_matching_state"))
        self.assertIsNone(result["assignment"])

    def test_requires_exactly_two_candidates(self) -> None:
        x, y = identity({"core.a": "1"}), identity({"core.a": "2"})
        with self.assertRaises(ValueError):
            cbs.match({"X": x, "Y": y}, {"only": x})


if __name__ == "__main__":
    unittest.main(verbosity=2)
