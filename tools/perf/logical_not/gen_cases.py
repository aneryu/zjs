#!/usr/bin/env python3
"""P7-60 case generator: operand-type matrix for `!` (op.lnot / OP_lnot).

Three families, all sharing one scaffold so that a pair's difference is exactly
one bytecode byte:

* ``t_<type>_k{0,1}``   -- ``u = x;`` vs ``u = !x;``.  One extra ``lnot``.
* ``s_bool_k{1..4}``    -- ``u = !x`` .. ``u = !!!!x``.  Each step adds exactly
  one ``lnot`` whose operand is a boolean, with no store-type asymmetry at all,
  so the slope is the purest single-opcode reading available.
* ``r_<type>_{if,lnot}`` -- ``if (x) t = t + 1;`` vs ``if (!x) {} else t = t + 1;``
  and the no-branch floor ``r_<type>_none``.  These separate the branch opcode
  (which owns an inline immediate arm in both engines) from ``lnot`` (which owns
  one only in QuickJS).

The operand is hoisted out of the loop and read once from an array literal, so
no per-iteration operand production is charged to either side and neither
engine's parser can constant-fold the unary operator.
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
N = 20_000_000

# name -> (source expression list for the 4-element array, index used)
TYPES = {
    "bool_true":     '[true, true, true, true]',
    "bool_false":    '[false, false, false, false]',
    "int_nonzero":   '[7, 7, 7, 7]',
    "int_zero":      '[0, 0, 0, 0]',
    "double_nonzero": '[1.5, 1.5, 1.5, 1.5]',
    # Both engines normalise an int-valued positive double back to the int tag
    # (qjs `JS_NewFloat64`), so `+0` is only a labelled control; `-0` survives as
    # a real float64 thanks to the sign bit.
    "double_pos_zero": '[0.0, 0.0, 0.0, 0.0]',
    "double_neg_zero": '[0.0 * -1.5, 0.0, 0.0, 0.0]',
    "double_nan":    '[NaN, NaN, NaN, NaN]',
    "undefined":     '[undefined, undefined, undefined, undefined]',
    "null":          '[null, null, null, null]',
    "string_short":  '["abcdefgh", "abcdefgh", "abcdefgh", "abcdefgh"]',
    "string_empty":  '["", "", "", ""]',
    "string_long":   '["abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz0123456789abcdefghij", "b", "c", "d"]',
    "object_plain":  '[{a: 1}, {a: 2}, {a: 3}, {a: 4}]',
    "object_array":  '[[1, 2], [3, 4], [5, 6], [7, 8]]',
    "object_function": '[function f1() {}, function f2() {}, function f3() {}, function f4() {}]',
    "bigint_short":  '[7n, 7n, 7n, 7n]',
    "bigint_zero":   '[0n, 0n, 0n, 0n]',
    "bigint_wide":   '[123456789012345678901234567890n, 1n, 2n, 3n]',
    "symbol":        '[Symbol("s1"), Symbol("s2"), Symbol("s3"), Symbol("s4")]',
}

# Types used for the branch-opcode comparison (§ attribution boundary).
BRANCH_TYPES = ["bool_true", "int_nonzero", "double_nonzero",
                "string_short", "object_plain"]

# String concatenation is how a rope representation would be produced, if the
# engine has one.  Kept separate because the operand construction differs.
# Verified with the temporary tag census: this shape really lands on
# `Tag.string_rope`; a short concat chain is flattened and lands on `Tag.string`.
ROPE_PROLOGUE = """  const rope = "x".repeat(70000) + "y".repeat(70000);
  const src = [rope, rope, rope, rope];
"""


def scaffold(prologue, body, tail):
    return (
        "function run() {\n"
        f"{prologue}"
        "  let x = src[0];\n"
        "  let u = 0;\n"
        "  let t = 0;\n"
        f"  for (let i = 0; i < {N}; i++) {{\n"
        f"{body}"
        "  }\n"
        f"{tail}"
        "}\n"
        "print(run());\n"
    )


def write(name, text):
    with open(os.path.join(CASES, name + ".js"), "w") as fh:
        fh.write(text)


def main():
    os.makedirs(CASES, exist_ok=True)
    names = []

    tail = "  return (u ? 1 : 0) + t;\n"

    for tname, literal in TYPES.items():
        prologue = f"  const src = {literal};\n"
        write(f"t_{tname}_k0", scaffold(prologue, "    u = x;\n", tail))
        write(f"t_{tname}_k1", scaffold(prologue, "    u = !x;\n", tail))
        names += [f"t_{tname}_k0", f"t_{tname}_k1"]

    write("t_string_rope_k0", scaffold(ROPE_PROLOGUE, "    u = x;\n", tail))
    write("t_string_rope_k1", scaffold(ROPE_PROLOGUE, "    u = !x;\n", tail))
    names += ["t_string_rope_k0", "t_string_rope_k1"]

    # Pure slope: operand of every added `!` is a boolean, result is a boolean,
    # so consecutive cases differ by exactly one `lnot` and nothing else.
    for k in range(1, 5):
        prologue = "  const src = [7, 7, 7, 7];\n"
        write(f"s_bool_k{k}",
              scaffold(prologue, "    u = " + "!" * k + "x;\n", tail))
        names.append(f"s_bool_k{k}")

    # Branch family.  `r_*_none` is the floor with no truthiness test at all;
    # `r_*_if` adds get_loc + if_false; `r_*_lnot` adds get_loc + lnot + if_false.
    for tname in BRANCH_TYPES:
        prologue = f"  const src = {TYPES[tname]};\n"
        write(f"r_{tname}_none", scaffold(prologue, "    t = t + 1;\n", tail))
        write(f"r_{tname}_if",
              scaffold(prologue, "    if (x) { t = t + 1; }\n", tail))
        write(f"r_{tname}_lnot",
              scaffold(prologue, "    if (!x) { } else { t = t + 1; }\n", tail))
        names += [f"r_{tname}_none", f"r_{tname}_if", f"r_{tname}_lnot"]

    write("baseline", "function run() { return 0; }\nprint(run());\n")
    names.append("baseline")

    with open(os.path.join(HERE, "case_list.txt"), "w") as fh:
        fh.write("\n".join(names) + "\n")
    print(f"wrote {len(names)} cases to {CASES}")


if __name__ == "__main__":
    main()
