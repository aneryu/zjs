#!/usr/bin/env python3
"""Mechanism-bucket attribution for the RayTrace zjs/QuickJS cycle gap.

Both engines execute the same fixed-work RayTrace source and, as the opcode
census shows, essentially the same bytecode (zjs/qjs = 1.0013 opcodes).  The
whole score gap is therefore per-operation cost, so grouping every profiled
symbol into one mechanism bucket and comparing absolute cycles attributes the
gap without needing per-opcode instruction counts.

Inputs are two flat `perf report` symbol lists plus each run's total cycles.
QuickJS is profiled with OPCODE_ASM_LABEL so its interpreter loop resolves to
per-opcode `label_OP_*` symbols; those buckets are spelled `OP_<name>` here.
"""

import argparse
import json
import re
from collections import Counter

# Ordered longest-prefix rules.  First match wins, so put specific names first.
QJS_RULES = [
    ("prop-read", [
        "OP_get_field", "OP_get_field2", "JS_GetPropertyInternal",
        "OP_get_array_el", "OP_get_length", "js_get_length64",
        "JS_GetPropertyValue", "find_own_property", "JS_GetPropertyInternal2",
    ]),
    ("prop-write", [
        "OP_put_field", "JS_SetPropertyInternal", "add_property",
        "add_shape_property", "js_new_shape2", "js_clone_shape",
        "resize_properties", "compact_properties", "find_hashed_shape",
        "JS_CreateProperty", "JS_DefineProperty", "JS_SetPropertyValue",
        "js_shape_prepare_update", "OP_define_field", "OP_put_array_el",
    ]),
    ("object-create", [
        "JS_NewObjectFromShape", "JS_NewObjectProtoClass", "js_create_from_ctor",
        "js_mallocz", "JS_NewObjectClass", "JS_NewObject",
    ]),
    ("object-free/rc", [
        "free_gc_object", "free_property", "__JS_FreeValueRT", "JS_FreeValue",
        "js_free_shape", "js_trigger_gc", "free_object", "free_zero_refcount",
        "gc_decref", "gc_scan", "js_free_value",
    ]),
    ("allocator", [
        "__js_malloc", "__js_free", "__js_realloc", "js_realloc",
        "__memset_zva64", "memcpy", "memset", "malloc", "free", "cfree",
    ]),
    ("arguments/apply", [
        "js_build_mapped_arguments", "js_create_var_ref", "free_var_ref",
        "js_function_apply", "build_arg_list", "OP_special_object",
        "js_mapped_arguments_finalizer", "close_var_refs",
        "js_build_arguments", "OP_apply",
    ]),
    ("call/frame", [
        "CallInternal.prologue", "OP_return", "OP_tail_call_method",
        "OP_call_method", "OP_call_constructor", "OP_call", "OP_tail_call",
        "js_call_c_function", "JS_CallConstructorInternal", "JS_CallInternal",
        "JS_CallFree", "JS_Call", "js_poll_interrupts", "OP_fclosure",
        "js_closure",
    ]),
    ("locals/stack", [
        "OP_get_loc", "OP_put_loc", "OP_set_loc", "OP_get_arg", "OP_put_arg",
        "OP_set_arg", "OP_push", "OP_dup", "OP_drop", "OP_swap", "OP_insert",
        "OP_get_var", "OP_make_var_ref_ref", "OP_nip", "OP_perm",
    ]),
    ("arith/control", [
        "OP_add", "OP_sub", "OP_mul", "OP_div", "OP_mod", "OP_neg", "OP_inc",
        "OP_dec", "OP_lt", "OP_gt", "OP_le", "OP_ge", "OP_eq", "OP_neq",
        "OP_lnot", "OP_not", "OP_if_false", "OP_if_true", "OP_goto",
        "OP_strict_eq", "OP_strict_neq", "OP_pow", "OP_plus",
        "js_binary_arith_slow", "JS_ToBoolFree", "JS_ToInt64Clamp",
        "js_math_", "JS_ToNumber", "js_pow", "pow", "sqrt", "floor",
        "JS_ToNumeric",
    ]),
]

ZJS_RULES = [
    ("prop-read", [
        "exec.tailcall_dispatch.op_get_field", "exec.vm_property_field.field",
        "exec.object_ops.getValueProperty", "core.object.Object.findProperty",
        "exec.tailcall_dispatch.coldStd__struct_115259",
        "exec.tailcall_dispatch.op_get_length",
        "exec.tailcall_dispatch.op_get_array_el",
        "core.array.arrayIndexFromAtom",
        "core.object.Object.getOwnConstructorPrototypeObject",
        "exec.coercion_ops.toLengthIndexInto",
        "exec.property_ic.dataPropertyValue",
        "exec.object_ops.getValuePropertyFromObject",
    ]),
    ("prop-write", [
        "exec.tailcall_dispatch.op_put_field",
        "exec.object_ops.setValuePropertyWithThrow",
        "core.object.Object.defineNewOwnDataPropertyForSimpleSet",
        "core.object.Object.appendPreparedPropertyEntry",
        "core.object.Object.adoptShapeForNewProperty",
        "core.object.Object.setOwnWritableDataProperty",
        "exec.property_ic.writableOwnDataPropertyLookupForObject",
        "core.shape.Registry.cloneShape", "core.shape.Registry.relocateShape",
        "core.object.flagsFromDescriptor", "core.object.slotFromDescriptor",
        "core.object.Object.defineOwnProperty",
        "exec.tailcall_dispatch.op_put_array_el",
    ]),
    ("object-create", [
        "core.object.Object.createInternal", "core.object.Object.create",
        "core.shape.Registry.createObjectRoot",
        "core.runtime.JSRuntime.collectBeforeObjectAllocation",
    ]),
    ("object-free/rc", [
        "core.object.Object.destroyFromHeader", "core.gc.destroyZeroRef",
        "core.gc.destroyZeroRefNow", "core.value.JSValue.destroyZeroRef",
        "core.shape.Registry.destroyShape",
        "core.gc.Registry.heapByteSizeFromHeader",
        "core.memory.MemoryAccount.destroyWithFam",
        "core.object.Object.deinit", "core.gc.",
    ]),
    ("allocator", [
        "core.memory.MemoryAccount.free", "core.memory.MemoryAccount.alloc",
        "core.memory.MemoryAccount.createInternal",
        "core.memory.MemoryAccount.createWithFamInternal",
        "core.memory.SmallObjectSlab", "compiler_rt.memset",
        "compiler_rt.memcpy", "core.memory.",
    ]),
    ("arguments/apply", [
        "exec.vm_literal.specialObject",
        "exec.tailcall_dispatch.coldStd__struct_115633",
        "exec.tailcall_dispatch.op_special_object",
        "exec.array_ops.materializeArgsFromArrayLike",
        "exec.call_runtime.qjsFunctionApply",
        "exec.array_ops.OwnedArrayLikeArgs",
        "core.var_ref.VarRef.destroyFromHeader", "core.var_ref.",
        "exec.object_ops.createArgumentsObject",
    ]),
    ("call/frame", [
        "exec.tailcall_dispatch.op_call", "exec.tailcall_dispatch.op_return",
        "exec.inline_calls.", "exec.call_runtime.runSyncInlineRoute",
        "exec.call_runtime.prepareSameMachineConstructor",
        "exec.call_runtime.constructSimpleFieldConstructor",
        "exec.zjs_vm.runTC", "exec.zjs_vm.runActiveInvocation",
        "exec.frame.FrameSlab", "core.runtime.VmStackArena",
        "exec.stack.Stack.reserveAdditional", "exec.vm_call.",
        "exec.function_ops.functionCall", "exec.builtin_dispatch.",
        "exec.frame.", "exec.call_runtime.",
    ]),
    ("locals/stack", [
        "exec.tailcall_dispatch.op_get_arg", "exec.tailcall_dispatch.opLoc",
        "exec.tailcall_dispatch.opArgStore", "exec.tailcall_dispatch.op_dup",
        "exec.tailcall_dispatch.op_push", "exec.tailcall_dispatch.op_get_var",
        "exec.tailcall_dispatch.op_drop", "exec.tailcall_dispatch.op_get_loc",
        "exec.tailcall_dispatch.op_put_loc",
    ]),
    ("arith/control", [
        "exec.tailcall_dispatch.opBinary", "exec.tailcall_dispatch.opCompare",
        "exec.tailcall_dispatch.op_if_", "exec.tailcall_dispatch.op_goto",
        "exec.tailcall_dispatch.coldStd__struct_115053",
        "exec.tailcall_dispatch.coldStd__struct_115020",
        "exec.tailcall_dispatch.coldStd__struct_114903",
        "exec.tailcall_dispatch.coldStd__struct_114812",
        "exec.tailcall_dispatch.coldStd__struct_114987",
        "exec.vm_value.logicalNot", "core.value_semantics.toBoolean",
        "core.value.JSValue.sameValue", "exec.vm_arith.",
        "exec.value_ops.unary", "exec.tailcall_dispatch.op_div",
        "exec.tailcall_dispatch.op_update_loc", "math.pow",
        "exec.tailcall_dispatch.opUnary",
    ]),
]


def classify(name, rules):
    best = None
    for bucket, prefixes in rules:
        for p in prefixes:
            if name.startswith(p) and (best is None or len(p) > best[1]):
                best = (bucket, len(p))
    return best[0] if best else "other/unclassified"


def load_flat(path):
    rows = []
    pat = re.compile(r"^\s*([0-9.]+)%\s+(?:\[[.k]\]\s+)?(\S+)")
    for line in open(path):
        m = pat.match(line)
        if m:
            rows.append((m.group(2), float(m.group(1))))
    return rows


def load_bucketed_json(path):
    return list(json.load(open(path)).items())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qjs-symbols", required=True,
                    help="JSON dict symbol->sample count (opcode-label resolved)")
    ap.add_argument("--zjs-symbols", required=True, help="flat perf report text")
    ap.add_argument("--qjs-cycles", type=float, required=True)
    ap.add_argument("--zjs-cycles", type=float, required=True)
    ap.add_argument("--output")
    args = ap.parse_args()

    qraw = load_bucketed_json(args.qjs_symbols)
    qtot = sum(v for _, v in qraw)
    qjs = Counter()
    qdetail = {}
    for name, count in qraw:
        b = classify(name, QJS_RULES)
        share = count / qtot
        qjs[b] += share * args.qjs_cycles
        qdetail.setdefault(b, Counter())[name] = share * args.qjs_cycles

    zraw = load_flat(args.zjs_symbols)
    ztot = sum(v for _, v in zraw)
    zjs = Counter()
    zdetail = {}
    for name, pct in zraw:
        b = classify(name, ZJS_RULES)
        share = pct / ztot
        zjs[b] += share * args.zjs_cycles
        zdetail.setdefault(b, Counter())[name] = share * args.zjs_cycles

    buckets = sorted(set(qjs) | set(zjs), key=lambda b: -(zjs[b] - qjs[b]))
    total_excess = args.zjs_cycles - args.qjs_cycles
    G = 1e9
    print(f"total cycles: qjs {args.qjs_cycles/G:.2f}G   zjs {args.zjs_cycles/G:.2f}G   "
          f"ratio {args.zjs_cycles/args.qjs_cycles:.4f}   excess {total_excess/G:.2f}G\n")
    print(f"{'bucket':22} {'qjs G':>8} {'zjs G':>8} {'delta G':>9} "
          f"{'z/q':>6} {'% of excess':>12}")
    for b in buckets:
        d = zjs[b] - qjs[b]
        r = (zjs[b] / qjs[b]) if qjs[b] > 0 else float("inf")
        print(f"{b:22} {qjs[b]/G:8.2f} {zjs[b]/G:8.2f} {d/G:+9.2f} "
              f"{r:6.2f} {100*d/total_excess:11.1f}%")
    print(f"{'TOTAL':22} {args.qjs_cycles/G:8.2f} {args.zjs_cycles/G:8.2f} "
          f"{total_excess/G:+9.2f} {args.zjs_cycles/args.qjs_cycles:6.2f} {100.0:11.1f}%")

    if args.output:
        json.dump({
            "qjsCycles": args.qjs_cycles, "zjsCycles": args.zjs_cycles,
            "buckets": {b: {"qjs": qjs[b], "zjs": zjs[b]} for b in buckets},
            "qjsDetail": {b: dict(c) for b, c in qdetail.items()},
            "zjsDetail": {b: dict(c) for b, c in zdetail.items()},
        }, open(args.output, "w"), indent=1)

    for label, detail in (("QJS", qdetail), ("ZJS", zdetail)):
        u = detail.get("other/unclassified")
        if u:
            print(f"\n{label} unclassified ({sum(u.values())/G:.2f}G):")
            for n, v in u.most_common(12):
                print(f"   {v/G:6.3f}G  {n}")


if __name__ == "__main__":
    main()
