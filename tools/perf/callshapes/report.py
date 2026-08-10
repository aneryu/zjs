#!/usr/bin/env python3
"""Aggregate tools/perf/callshapes/sample.sh CSV into a per-shape zjs/qjs table.

Reports the median across samples, and the startup-subtracted per-operation
cost (the `empty` case is pure process startup, so it is removed from every
other case before the ratio is taken).
"""
import csv
import statistics
import sys

ITERS = {
    "empty": 0,
    "ctrl": 200_000_000,
    "A_direct_call": 30_000_000,
    "A2_direct_call_ret": 25_000_000,
    "B_method_call": 25_000_000,
    "C_apply_array_literal": 6_000_000,
    "C2_apply_array_hoisted": 9_000_000,
    "D_apply_arguments": 3_500_000,
    "E0_arguments_zeroarg": 5_000_000,
    "E1_arguments_length": 5_000_000,
    "E2_arguments_index": 5_000_000,
    "E4_arguments_fourarg": 5_000_000,
    "F_simple_ctor": 5_000_000,
    "G_raytrace_ctor": 2_000_000,
    "H1_prop_read": 40_000_000,
    "H2_prop_write": 60_000_000,
    "I_proto_method": 12_000_000,
    "J_instanceof": 15_000_000,
    "K1_length_array": 40_000_000,
    "K2_length_plain": 40_000_000,
    "L0_ctor_noprops": 5_000_000,
    "L3_ctor_threeprops": 5_000_000,
    "M1_proto_data_read": 40_000_000,
    "L3p_ctor_shadowing": 5_000_000,
    "M2_chain_read": 10_000_000,
    "M3_poly_read": 40_000_000,
    "L4_generic_ctor": 5_000_000,
    "L4p_generic_ctor_shadowing": 5_000_000,
    "W0_fresh_object": 5_000_000,
    "W1_newprop_writes": 5_000_000,
}

LABEL = {
    "ctrl": "ctrl  (empty loop)",
    "A_direct_call": "A     f(1,2)",
    "A2_direct_call_ret": "A2    s += f(1,2)",
    "B_method_call": "B     o.f(1,2)",
    "C_apply_array_literal": "C     f.apply(o,[1,2])",
    "C2_apply_array_hoisted": "C2    f.apply(o,args)",
    "D_apply_arguments": "D     f.apply(o,arguments)",
    "E0_arguments_zeroarg": "E0    arguments, 0 args",
    "E1_arguments_length": "E1    arguments.length",
    "E2_arguments_index": "E2    arguments[0]",
    "E4_arguments_fourarg": "E4    arguments, 4 args",
    "F_simple_ctor": "F     new Pair(1,2)",
    "G_raytrace_ctor": "G     RayTrace ctor",
    "H1_prop_read": "H1    o.x",
    "H2_prop_write": "H2    o.x = v",
    "I_proto_method": "I     o.method()",
    "J_instanceof": "J     o instanceof Pair",
    "K1_length_array": "K1    array.length",
    "K2_length_plain": "K2    plainobj.length",
    "L0_ctor_noprops": "L0    new Empty()",
    "L3_ctor_threeprops": "L3    new Three(1,2,3)",
    "M1_proto_data_read": "M1    o.protoProp",
    "L3p_ctor_shadowing": "L3p   new Three + proto x,y,z",
    "M2_chain_read": "M2    a.b.c.c2.d",
    "M3_poly_read": "M3    o.p (2 shapes)",
    "L4_generic_ctor": "L4    generic ctor, 3 props",
    "L4p_generic_ctor_shadowing": "L4p   generic ctor + proto x,y,z",
    "W0_fresh_object": "W0    var o = {} (control)",
    "W1_newprop_writes": "W1    {} + 3 new-prop writes",
}

ORDER = [c for c in ITERS if c != "empty"]


def main(path):
    rows = list(csv.DictReader(open(path)))
    bins = []
    for r in rows:
        if r["binary"] not in bins:
            bins.append(r["binary"])
    if len(bins) != 2:
        sys.exit(f"expected exactly 2 binaries, got {bins}")
    # Ratio is always first-label / second-label, in CSV appearance order.
    b_zjs, b_qjs = bins

    def med(binary, case, field):
        vals = [float(r[field]) for r in rows
                if r["binary"] == binary and r["case"] == case and r[field]]
        return statistics.median(vals) if vals else float("nan")

    def spread(binary, case, field):
        vals = sorted(float(r[field]) for r in rows
                      if r["binary"] == binary and r["case"] == case and r[field])
        if len(vals) < 2:
            return 0.0
        return (vals[-1] - vals[0]) / statistics.median(vals) * 100.0

    base = {b: {f: med(b, "empty", f) for f in ("instructions", "cycles", "task_clock_ns")}
            for b in (b_zjs, b_qjs)}

    n = len({r["sample"] for r in rows})
    print(f"samples: {n}   binaries: {b_zjs} vs {b_qjs}   (median, startup-subtracted, per operation)")
    print(f"startup (empty.js): {b_zjs} {base[b_zjs]['instructions']/1e6:.2f}M insn "
          f"{base[b_zjs]['task_clock_ns']/1e6:.1f}ms | "
          f"{b_qjs} {base[b_qjs]['instructions']/1e6:.2f}M insn "
          f"{base[b_qjs]['task_clock_ns']/1e6:.1f}ms")
    print()
    hdr = (f"{'shape':<26} {'insn/op':>16} {'ratio':>7} {'cyc/op':>16} {'ratio':>7} "
           f"{'ns/op':>14} {'ratio':>7} {'spread%':>8}")
    print(hdr)
    print("-" * len(hdr))

    for case in ORDER:
        it = ITERS[case]
        out = [f"{LABEL[case]:<26}"]
        ratios = {}
        # perf -x, reports task-clock in nanoseconds on this host.
        for field, scale, unit in (("instructions", 1.0, "insn"),
                                   ("cycles", 1.0, "cyc"),
                                   ("task_clock_ns", 1.0, "ns")):
            z = (med(b_zjs, case, field) - base[b_zjs][field]) * scale / it
            q = (med(b_qjs, case, field) - base[b_qjs][field]) * scale / it
            ratios[field] = z / q if q else float("nan")
            out.append(f"{z:>7.1f}/{q:<8.1f}")
            out.append(f"{ratios[field]:>7.2f}")
        sp = max(spread(b_zjs, case, "cycles"), spread(b_qjs, case, "cycles"))
        out.append(f"{sp:>8.1f}")
        print(" ".join(out))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/dev/stdin")
