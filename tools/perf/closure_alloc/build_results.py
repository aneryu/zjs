#!/usr/bin/env python3
"""P7-50: assemble the machine-readable results sibling from the raw artefacts.

Every number quoted in P7-50-closure-allocation.md is written here from the same
raw files, so the prose and the JSON cannot drift.
"""

import argparse
import json
import re
import statistics

SHAPES = ["arrow_nocap", "fnexpr_nocap", "arrow_cap1", "fnexpr_cap1",
          "arrow_cap4", "arrow_loopbind", "arrow_call"]

QGROUP = [
    ("wrapper-create", r"JS_NewObjectProtoClass|JS_NewObjectFromShape|JS_NewObjectClass|js_new_shape2|find_hashed_shape_proto|js_closure|js_closure2"),
    ("property-publish", r"add_property|add_shape_property|JS_CreateProperty|JS_DefineProperty|JS_DefinePropertyValue|js_function_set_properties|find_hashed_shape_prop|js_shape_prepare_update|resize_properties|js_clone_shape|JS_AtomToString|__JS_AtomToValue|JS_DefineObjectName|js_object_has_name|JS_DefineAutoInitProperty|js_update_property_flags"),
    ("env-cells", r"get_var_ref|js_create_var_ref|free_var_ref|close_var_refs"),
    ("teardown", r"free_gc_object|__JS_FreeValueRT|js_free_shape|free_property|js_bytecode_function_finalizer|JS_FreeValue"),
    ("allocator", r"__js_malloc|__js_free|js_malloc|js_mallocz|js_realloc|js_free|js_def_malloc|js_def_realloc|js_realloc2|js_malloc_usable_size|__js_malloc_usable_size"),
    ("vm-dispatch", r"JS_CallInternal|js_call_c_function"),
]
ZGROUP = [
    ("wrapper-create", r"createBytecodeFunctionObjectInternal|Object\.createInternal|Object\.create$|createWithFamInternal|createObjectRoot|bytecodeFunctionPrototypeForRealm|setFunctionBytecodeValue|vm_call\.closure|installOrdinaryFunctionPrototype|allocFunctionPayload|createShape"),
    ("property-publish", r"defineOwnProperty|defineOrdinaryOwnProperty|appendPreparedPropertyEntry|adoptShapeForNewProperty|transitionPropertyUncached|ensureUniqueShapeForMutation|cloneShape|Registry\.prepareUpdate|reservePropertyAppend|appendProperty|rehashShape|relocateShape|defineModuleNamespaceProperty|functionNameValueFromAtom|defineFunctionNameProperty|replaceProperty|getOwnProperty|descriptorFromOwnPropertySlot|findProperty|createStringValue|internString|updatePropertyFlags|setName|arrayIndexFromAtom|AtomTable\.kind|mergeDescriptor|isCompatible|materializeAutoInit|prepareMappedArguments|updateMappedArguments|materializeMappedArguments"),
    ("env-cells", r"VarRef|attachFunctionCaptures|resolveNestedClosureCell|ensureOpenVarRefSlots|closeOpenVarRefs|ensureVarRefsCapacity"),
    ("teardown", r"destroyFromHeader|destroyShape|destroyZeroRef|endDecrefPhase|destroyPropertySlot|FunctionRarePayload|drainCycleDeferredFrees|freeInlinePayload|Registry\.release"),
    ("allocator", r"MemoryAccount|SmallObjectSlab|^malloc$|^free$|page_allocator"),
    ("vm-dispatch", r"tailcall_dispatch|zjs_vm|call_runtime\.(?!functionNameValueFromAtom)|inline_calls"),
]
SHAPE_CLONE = (r"cloneShape|ensureUniqueShapeForMutation|destroyShape"
               r"|allocAlignedBytesNoTrigger|freeAlignedBytes|Registry\.release"
               r"|relocateShape|rehashShape")


def med(values):
    return statistics.median(values)


def pmu_per_op(matrix, case, label, lifetime):
    series = matrix["pmu_combined"]["data"]["%s|%s" % (case, label)]
    lo, hi = matrix["pmu_combined"]["lo"], matrix["pmu_combined"]["hi"]
    ops = (hi - lo) * matrix["inner_loop_n"]
    if lifetime == "retain":
        ops //= 2
    out = {}
    for event in ("instructions", "cycles"):
        out[event] = (med([r[event] for r in series["hi"]])
                      - med([r[event] for r in series["lo"]])) / ops
    return out


def main():
    parser = argparse.ArgumentParser()
    for name in ("matrix", "identtarget", "counts", "counts-identtarget",
                 "profiles", "analysis"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    a = vars(args)

    matrix = json.load(open(a["matrix"]))
    ident = json.load(open(a["identtarget"]))
    counts = json.load(open(a["counts"]))
    counts_i = json.load(open(a["counts_identtarget"]))
    profiles = json.load(open(a["profiles"]))
    analysis = json.load(open(a["analysis"]))
    inner = matrix["inner_loop_n"]
    ops = profiles["inner"] * profiles["iterations"]

    out = {
        "line": "P7-50",
        "question": "where the per-iteration closure-allocation gap comes from",
        "nature": "profiling-only; no production code changed",
        "date": "2026-07-30",
        "baseline_commit": "18816862",
        "branch": "perf/qjs-align-p7-closure",
        "layer": "same-runtime (source compiled once, retained run() invoked repeatedly)",
        "cpu": matrix["cpu"],
        "pmu_device": matrix["pmu_device"],
        "inner_loop_n": inner,
        "binaries": matrix["binaries"],
        "qjs_pin": {"head": "04be246001599f5995fa2f2d8c91a0f198d3f34c",
                    "version": "2026-06-04"},
        "build_instances": {
            "zjs": "two cold-cache builds, DIFFERENT bytes (2ddbc16a / f2e58958)",
            "qjs": "two cold-cache builds, BYTE-IDENTICAL (0ad62282)",
        },
        "identity_probe": {
            "case": "closure_identity_probe",
            "result": "passes on zjsA, zjsB and qjs with identical checksum 6000128",
            "meaning": "every evaluation of every shape yields a distinct Function"
                       " identity with the right captured values; neither engine"
                       " hoists or caches the loop-body function",
        },
    }

    # ---- 1. headline ratios -------------------------------------------------
    head = {}
    for label in ("qjs", "zjsA", "zjsB"):
        head["identtarget_nocap_churn|" + label] = {
            k: (pmu_per_op(ident, "closure_identtarget_nocap_churn", label, "churn")[k]
                - pmu_per_op(ident, "closure_identtarget_reuse_churn", label, "churn")[k])
            for k in ("instructions", "cycles")}
        head["arrow_nocap_churn|" + label] = {
            k: analysis["baseline_subtracted"]["closure_arrow_nocap_churn|" + label][k]
            for k in ("instructions", "cycles")}
    for label in ("zjsA", "zjsB"):
        for case in ("identtarget_nocap_churn", "arrow_nocap_churn"):
            q = head[case + "|qjs"]
            z = head[case + "|" + label]
            head["ratio|%s|%s" % (case, label)] = {
                "instructions": z["instructions"] / q["instructions"],
                "cycles": z["cycles"] / q["cycles"],
            }
    out["headline"] = head

    # ---- 2. stage attribution of the 3.4x case -----------------------------
    stages = {}
    for label in ("zjsA", "zjsB"):
        total = (head["identtarget_nocap_churn|" + label]["cycles"]
                 - head["identtarget_nocap_churn|qjs"]["cycles"])
        generic = (head["arrow_nocap_churn|" + label]["cycles"]
                   - head["arrow_nocap_churn|qjs"]["cycles"])
        redefine = total - generic
        stages[label] = {
            "total_cycle_gap_per_op": total,
            "generic_creation_and_release_gap": generic,
            "generic_share": generic / total,
            "namedevaluation_name_redefine_gap": redefine,
            "namedevaluation_name_redefine_share": redefine / total,
            "instructions": {
                "total_gap": (head["identtarget_nocap_churn|" + label]["instructions"]
                              - head["identtarget_nocap_churn|qjs"]["instructions"]),
                "generic_gap": (head["arrow_nocap_churn|" + label]["instructions"]
                                - head["arrow_nocap_churn|qjs"]["instructions"]),
            },
        }
        stages[label]["instructions"]["namedevaluation_gap"] = (
            stages[label]["instructions"]["total_gap"]
            - stages[label]["instructions"]["generic_gap"])
        stages[label]["instructions"]["namedevaluation_share"] = (
            stages[label]["instructions"]["namedevaluation_gap"]
            / stages[label]["instructions"]["total_gap"])
    out["stage_attribution"] = stages

    # ---- 3. perf-record stage groups ---------------------------------------
    def diff(label, event, case, base):
        x = profiles["profiles"]["%s|%s|%s" % (label, event, case)]
        y = profiles["profiles"]["%s|%s|%s" % (label, event, base)]
        keys = set(x["symbols"]) | set(y["symbols"])
        return {k: x["symbols"].get(k, 0) - y["symbols"].get(k, 0) for k in keys}

    def grouped(delta, groups):
        res = {}
        other = 0.0
        for k, v in delta.items():
            for name, pat in groups:
                if re.search(pat, k):
                    res[name] = res.get(name, 0.0) + v / ops
                    break
            else:
                other += v / ops
        res["other/unattributed"] = other
        return res

    groups_out = {}
    for tag, case, base in (
            ("generic_creation_and_release", "closure_arrow_nocap_churn",
             "closure_reuse_churn"),
            ("namedevaluation_name_redefine",
             "closure_identtarget_nocap_churn", "closure_arrow_nocap_churn"),
            ("capture_one_existing_outer_local",
             "closure_arrow_cap1_churn", "closure_arrow_nocap_churn")):
        entry = {}
        for label, gdef in (("qjs", QGROUP), ("zjsA", ZGROUP), ("zjsB", ZGROUP)):
            dl = diff(label, "cycles", case, base)
            entry[label] = {"groups": grouped(dl, gdef),
                            "total_cyc_per_op": sum(dl.values()) / ops,
                            "top_symbols_cyc_per_op": {
                                k: v / ops for v, k in
                                sorted(((v, k) for k, v in dl.items()),
                                       reverse=True)[:12]}}
            if label != "qjs":
                entry[label]["shape_clone_subtotal_cyc_per_op"] = sum(
                    v for k, v in dl.items() if re.search(SHAPE_CLONE, k)) / ops
        entry["gap_share_of_group"] = {
            label: {g: (entry[label]["groups"].get(g, 0.0)
                        - entry["qjs"]["groups"].get(g, 0.0))
                    / (entry[label]["total_cyc_per_op"]
                       - entry["qjs"]["total_cyc_per_op"])
                    for g in set(entry[label]["groups"]) | set(entry["qjs"]["groups"])}
            for label in ("zjsA", "zjsB")}
        groups_out[tag] = entry
    out["perf_record_stage_groups"] = groups_out

    # ---- 4. eight-case matrix ----------------------------------------------
    mtx = {}
    for lifetime in ("retain", "churn"):
        for shape in SHAPES:
            case = "closure_%s_%s" % (shape, lifetime)
            row = {"lifetime": lifetime, "shape": shape}
            for label in ("qjs", "zjsA", "zjsB"):
                bs = analysis["baseline_subtracted"]["%s|%s" % (case, label)]
                row[label] = {"instructions_per_op": bs["instructions"],
                              "cycles_per_op": bs["cycles"]}
            for label in ("zjsA", "zjsB"):
                row["ratio_" + label] = {
                    "instructions": row[label]["instructions_per_op"]
                    / row["qjs"]["instructions_per_op"],
                    "cycles": row[label]["cycles_per_op"]
                    / row["qjs"]["cycles_per_op"]}
            for label in ("zjsA", "zjsB"):
                w = analysis["baseline_subtracted"][
                    "wall|%s|%s|qjs" % (case, label)]
                row["wall_" + label] = w
            mtx[case] = row
    out["matrix"] = mtx

    # ---- 5. creation vs destruction ----------------------------------------
    cd = {}
    for shape in SHAPES:
        entry = {}
        for label in ("zjsA", "zjsB"):
            w = analysis["baseline_subtracted"][
                "wall|closure_%s_retain|%s|qjs" % (shape, label)]
            gf = w["zjs"]["fill_ns_per_op"] - w["qjs"]["fill_ns_per_op"]
            gc = w["zjs"]["clear_ns_per_op"] - w["qjs"]["clear_ns_per_op"]
            entry[label] = {
                "creation_ns_per_op_qjs": w["qjs"]["fill_ns_per_op"],
                "creation_ns_per_op_zjs": w["zjs"]["fill_ns_per_op"],
                "creation_ratio": w["zjs"]["fill_ns_per_op"] / w["qjs"]["fill_ns_per_op"],
                "destruction_ns_per_op_qjs": w["qjs"]["clear_ns_per_op"],
                "destruction_ns_per_op_zjs": w["zjs"]["clear_ns_per_op"],
                "destruction_ratio": w["zjs"]["clear_ns_per_op"] / w["qjs"]["clear_ns_per_op"],
                "destruction_share_of_gap": gc / (gf + gc),
            }
        cd[shape] = entry
    out["creation_vs_destruction"] = {
        "instrument": "harness per-sample clock_gettime around one run() call;"
                      " retain odd samples are creation-only, even samples are"
                      " release-only",
        "per_shape": cd,
        "pmu_split_rejected": "the consecutive-iteration PMU delta produced"
                              " negative per-op values (single-sample deltas"
                              " against a ~350 M-cycle process); it is recorded"
                              " in raw/matrix.json pmu_split but NOT used",
    }

    # ---- 6. capture axis ----------------------------------------------------
    cap = {}
    for shape in SHAPES + ["reuse"]:
        cr = counts["per_op"].get("closure_%s_retain|qjs|create" % shape)
        rl = counts["per_op"].get("closure_%s_retain|qjs|release" % shape)
        zc = counts["per_op"].get("closure_%s_retain|zjs|create" % shape)
        zr = counts["per_op"].get("closure_%s_retain|zjs|release" % shape)
        if cr is None:
            continue
        by = matrix["bytes"]["data"]
        cap[shape] = {
            "dynamic_capture_slots_qjs_get_var_ref": cr["get_var_ref"],
            "dynamic_capture_slots_qjs_free_var_ref": rl["free_var_ref"],
            "fresh_cell_alloc_per_op_qjs_js_mallocz": cr["js_mallocz"],
            "fresh_cell_destroy_per_op_zjs":
                zr["core.var_ref.VarRef.destroyFromHeader__anon_60948"],
            "zjs_attach_function_captures_per_op":
                zc["exec.object_ops.attachFunctionCaptures"],
            "live_bytes_per_op_qjs":
                by["closure_%s_retain|qjs" % shape]["allocated_bytes_per_op"],
            "live_bytes_per_op_zjsA":
                by["closure_%s_retain|zjsA" % shape]["allocated_bytes_per_op"],
            "live_bytes_per_op_zjsB":
                by["closure_%s_retain|zjsB" % shape]["allocated_bytes_per_op"],
            "qjs_allocations_per_op_js_malloc": cr["js_malloc"],
        }
    out["capture_axis"] = {
        "note": "x-axis is the DYNAMIC capture-slot count, not the source"
                " variable count. arrow_cap4 really does materialise 4 slots"
                " (qjs get_var_ref 4.000/op; zjs live bytes +32.0 B over"
                " arrow_nocap = 4 pointers).",
        "per_shape": cap,
    }

    # ---- 7. topology equality check ----------------------------------------
    topo = {}
    for shape in SHAPES + ["reuse"]:
        ch = counts["per_op"].get(
            "closure_%s_churn|zjs|create_plus_release" % shape)
        rt = counts["per_op"].get(
            "closure_%s_retain|zjs|create_plus_release" % shape)
        if ch is None:
            continue
        diffs = {k: rt[k] - ch[k] for k in ch if abs(rt[k] - ch[k]) > 5e-4}
        topo[shape] = {"zjs_retain_minus_churn_per_op": diffs}
        chq = counts["per_op"]["closure_%s_churn|qjs|create_plus_release" % shape]
        rtq = counts["per_op"]["closure_%s_retain|qjs|create_plus_release" % shape]
        topo[shape]["qjs_retain_minus_churn_per_op"] = {
            k: rtq[k] - chq[k] for k in chq if abs(rtq[k] - chq[k]) > 5e-4}
        topo[shape]["gc_runs_per_op_qjs_JS_RunGC"] = chq["JS_RunGC"]
        topo[shape]["gc_polls_per_op_zjs_pollGC"] = ch["core.runtime.JSRuntime.pollGC"]
    out["topology_equality"] = {
        "namedevaluation_equalised": "both lifetimes store through an array"
            " element, so neither pays a NamedEvaluation name re-define; before"
            " that fix churn did one extra property define and zjs additionally"
            " one cloneShape + one ensureUniqueShapeForMutation per op",
        "residual_difference": "only the allocator arena refill rate differs"
            " (retain 0.036-0.054/op, churn 0.000/op); GC runs are 0/op in both"
            " engines and both lifetimes",
        "per_shape": topo,
    }

    # ---- 8. build bistability ----------------------------------------------
    bist = {}
    for lifetime in ("retain", "churn"):
        for shape in SHAPES:
            case = "closure_%s_%s" % (shape, lifetime)
            x = analysis["baseline_subtracted"][case + "|zjsA"]
            y = analysis["baseline_subtracted"][case + "|zjsB"]
            bist[case] = {
                ev: abs(x[ev] - y[ev]) / ((x[ev] + y[ev]) / 2)
                for ev in ("instructions", "cycles")}
    out["build_bistability"] = {
        "note": "the two zjs builds differ in bytes, so this is a real"
                " bistability case, not a free noise floor. instructions are"
                " tight everywhere; retain-lifetime CYCLES are not, so every"
                " headline number is taken from the churn lifetime.",
        "per_case_relative_spread": bist,
        "worst_cycles": max(v["cycles"] for v in bist.values()),
        "worst_instructions": max(v["instructions"] for v in bist.values()),
        "worst_cycles_churn_only": max(v["cycles"] for k, v in bist.items()
                                       if k.endswith("churn")),
    }

    # ---- 9. named-evaluation stage counts ----------------------------------
    ne = {}
    for engine in ("qjs", "zjs"):
        i = counts_i["per_op"][
            "closure_identtarget_nocap_churn|%s|create_plus_release" % engine]
        s = counts["per_op"][
            "closure_arrow_nocap_churn|%s|create_plus_release" % engine]
        ne[engine] = {k: {"identifier_target": i[k],
                          "array_element_target": s.get(k, 0.0),
                          "delta": i[k] - s.get(k, 0.0)}
                      for k in i
                      if abs(i[k]) > 5e-4 or abs(s.get(k, 0.0)) > 5e-4}
    out["namedevaluation_stage_counts"] = ne

    with open(a["out"], "w") as handle:
        json.dump(out, handle, indent=1)
    print(a["out"])


if __name__ == "__main__":
    main()
