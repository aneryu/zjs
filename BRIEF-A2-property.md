# A2 — align property get/set to qjs (strip the 4 layers qjs lacks)

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, builds on A1 commit 9b4d726c). #2 ranked lever: property get/set is 2-6.5x qjs insn/op and extremely hot on object-heavy Octane (richards/deltablue/box2d/raytrace/pdfjs). The shape-hash probe ALGORITHM is already faithful to qjs; the gap is 4 layers wrapped around it that qjs does not have. Remove them to reach qjs's GET_FIELD_INLINE / find_own_property cost.

## qjs reference (the target)
- find_own_property (quickjs.c:6115-6133): `h = atom & shape->prop_hash_mask; for (prop_idx = shape->prop_hash_end[-h-1]; prop_idx; prop_idx = pr->hash_next) { pr = &shape->prop[prop_idx-1]; if (pr->atom == atom) return pr; }` — ONE tight loop, no per-iter guards.
- OP_get_field GET_FIELD_INLINE (quickjs.c:19107-19160): on the object fast path, a SINGLE `p->is_exotic` bit test gates the slow path; own-hit reads the value in one shot. OP_put_field set_value (19177-19216): single flag-mask + store + free-old.
- JSShape: hash_table[] + prop[] (8B JSShapeProperty) in ONE trailing-flex allocation; the value array is parallel, indexed by the same probe result.

## The 4 layers to remove (zjs current, with refs)
1. **Per-access `atoms.kind(atom_id) == .private`** (vm_property_field.zig:373, 394) — ~11 insns: indexes the predefined-atom table (atom*24) + load + mask + compare, on EVERY field access. qjs never touches the atom table here. FIX: private atoms are a contiguous atom-id range — replace with a single `atom_id >= first_private_atom` range compare (or hoist the kind read out of the hot loop entirely). 
2. **`qjsFieldObjectNeedsSlow` class gauntlet** (vm_property_field.zig:413) — ~50 insns of proxy/exotic/is_array/typedarray/regexp-lastIndex/module-ns/mapped-args checks, INCLUDING a real `bl arrayIndexFromAtom` on the is_array branch. qjs collapses ALL of this into ONE `p->is_exotic` bit. FIX: precompute a single `needs_slow_property` / `is_exotic` flag bit in ObjectFlags, SET whenever the object becomes proxy/array/typedarray/regexp/module/mapped-arguments (at the transition that makes it so), so the hot path is one `tbnz is_exotic` exactly like qjs — and NEVER `bl arrayIndexFromAtom` on the fast path.
3. **3-4 separate-allocation two-array indirection + redundant guards** — findProperty (object.zig:9468-9487) returns only an index into shape.props (a 12B Property in a SEPARATE slice from hash_buckets), with per-iter guards `steps<prop_count`/`index>=props.len`/`index>=prop_count` qjs lacks; the value then comes from object.properties[index] (a 4th SEPARATE slice, a tagged-union Slot needing a tag check); flags re-loaded a SECOND time via propFlagsAt. FIX: a single own-data-hit path that does ONE probe and returns the value+flags without the per-iter guards (verifier-bounded) and without the doubled flag-load and the Slot tag double-check; ideally read shape.props once. (Folding props+hash into one alloc like qjs is the Shape lever A3 — here just drop the redundant guards + doubled loads + the Slot indirection on the data-hit path.)
4. **put_field multi-call store** — dupPropertyDataValue + destroyPropertySlot + pruneBorrowedReferenceHolderIfEmpty. FIX: when the existing slot is a plain writable non-accessor `.data` slot, do the qjs `set_value` equivalent INLINE: dup the new value, store into the slot, free the old value — skip the destroy/prune dispatch.

Also: inline Stack.push on the property-hit path (it currently `bl`s; use *sp++ like the other hot arms).

## Gate (CORRECTNESS first)
1. Build 3 flags 0 errors. `zig build test --summary all` → 1194 passed; 0 failed.
2. Property-correctness smoke (own/proto/accessor/array-index/proxy/typedarray/delete/redefine): `zig-out/bin/zjs -e 'var o={a:1};Object.defineProperty(o,"g",{get:function(){return 9}});var p=Object.create(o);p.b=2; var a=[10,20];a.x=3; var pr=new Proxy({},{get:function(){return 7}}); delete o.a; print((p.b)+"|"+(p.g)+"|"+(a[1])+"|"+(a.x)+"|"+(pr.z)+"|"+(o.a))'` → expect `2|9|20|3|7|undefined`. Plus richards.js/deltablue.js/raytrace.js run.
3. GC-stress (tiny threshold): object-churn + property writes → no leak/UAF; revert.
4. `zig fmt`; commit `perf(zjs): A2 property get/set — drop atom.kind/needsSlow/redundant-guards, is_exotic bit, in-place data store (align qjs)`.

## Constraints
- CORRECTNESS first — the slow-path triggers (proxy/array/typedarray/regexp/module/mapped-args/accessor/private) MUST still all fire correctly. The risk is the precomputed is_exotic bit: it must be SET on every transition INTO an exotic/needs-slow state and never stale. When unsure, fall to slow (set the bit). test262 is the hard gate.
- Do NOT judge/revert on perf — commit on correctness-green; perf measured at end.
- Do NOT touch the dispatcher (A1 done) or the Shape allocation layout (that is A3).
- If all 4 are too much at once, land them as separate commits in order (1 atom.kind, 2 is_exotic bit, 3 guard/indirection drop, 4 in-place put), each gated; report which landed.
