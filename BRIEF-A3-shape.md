# A3 — align Shape to qjs (kill double string-parse + fold 3 allocs → 1)

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, builds on A2 commit 863a69e0). Shape is partial-aligned: hash-consing/transition-caching works (shapes ARE shared, not cloned), but the LAYOUT diverges from qjs — 2.65x full / 4.1x pure-lookup insn vs qjs. Two fixes, cheap-first.

## qjs reference
- JSShape: a header + ONE trailing flexible allocation holding BOTH hash_table[] and prop[] (8B JSShapeProperty); the parallel value array is indexed by the same probe. zjs has 3 SEPARATE slice allocs (props 12B, hash_buckets, transitions) + the value array is a 4th slice.
- qjs add-property: checks if the atom is an array index via a TAGGED-INT test (the atom encodes small int indices directly — `__JS_AtomIsTaggedInt`), NOT a string parse.

## Fix A3.1 (CHEAP, surgical 7%-of-cycles, do FIRST) — kill the double arrayIndexFromAtom
On every property ADD, zjs calls `arrayIndexFromAtom` TWICE (object.zig:9377 and :9398) — each is a full string-parse of the atom to test if it's an array index. qjs uses a single tagged-int bit test. FIX: (1) compute the array-index-ness ONCE (not twice) and reuse it; (2) replace the string-parse with the tagged-int fast check — if atoms encode small integers as tagged ints (check atom.zig), test that bit/range first and only string-parse a genuine string atom. This is ~7% of construction-heavy cycles for a ~one-line guard.

## Fix A3.2 (BIGGER) — fold the 3 shape allocs into one trailing-flex allocation (qjs layout)
Read core/shape.zig (~:47-49, the 3 separate slices: props, hash_buckets, transitions). qjs packs hash_table[] + prop[] into ONE allocation (the shape struct with a trailing flexible array), so a property lookup touches one cache line and shape creation does one alloc. FIX: allocate props + hash_buckets as a single backing buffer (one slab alloc, hash_buckets then props, or interleaved like qjs), so getOwnDataPropertyLookup reads one contiguous region. Keep transitions separate if it complicates (it's cold). Also consider shrinking Property 12B→8B (qjs JSShapeProperty) and the value Slot 24B→16B (qjs JSProperty) if feasible without breaking the accessor/auto-init union — but ONLY if it stays correct; report if deferred.

## Gate (CORRECTNESS first)
1. Build 3 flags 0 errors. `zig build test --summary all` → 1194 passed; 0 failed.
2. Shape/property correctness smoke (construction, transitions, shared shapes, add/delete/redefine, dict-mode): `zig-out/bin/zjs -e 'var r=0;for(var i=0;i<100000;i++){var o={a:i,b:i+1,c:i+2};o.d=i;delete o.b;r+=o.a+o.c+o.d} var x={};for(var i=0;i<300;i++)x["k"+i]=i; print(r+"|"+x.k299+"|"+Object.keys(x).length)'` → deterministic; also a few objects sharing a shape + an array-index-key object. richards.js/deltablue.js run.
3. GC-stress (tiny threshold): construction-heavy + shape churn → no leak/UAF; revert.
4. `zig fmt`; commit (separate per fix if cleaner): `perf(zjs): A3.1 single tagged-int array-index check (was double string-parse)` then `perf(zjs): A3.2 fold shape props+hash into one allocation (align qjs)`.

## Constraints
- CORRECTNESS first — shape transitions / sharing / dict-mode / array-index keys MUST stay correct (the tagged-int check must match arrayIndexFromAtom's result exactly for all atoms; the single-alloc layout must keep the hash probe + prop access correct). test262 is the hard gate.
- Do NOT judge/revert on perf — commit on correctness-green.
- Do NOT touch the dispatcher (A1) / property hot path beyond shape (A2) / allocator.
- Do A3.1 first (cheap, isolated, commit). A3.2 is bigger — if too risky, do A3.1 + report A3.2 scope.
