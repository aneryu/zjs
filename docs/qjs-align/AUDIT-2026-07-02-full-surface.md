# zjs → QuickJS 全功能面忠实对齐审计（2026-07-02）

> 方法：18 个子系统对比 agent 逐一对照 `/home/aneryu/quickjs`（Bellard QuickJS，commit `04be246`），
> 用两个二进制实跑差分探针（不只读代码）；每条 behavior / 中高严重度发现再经独立怀疑者 agent 对抗复核
> （默认立场 REFUTED，自跑 repro + 查登记簿排除已知项）。zjs HEAD = `541c30f`。
> `number-math-dtoa` 为补跑区域（首轮 API 过载失败），9 条为 agent 自验、未过独立对抗管线。
>
> **本文件仅为审计结论，未执行任何对齐改动。** 已知并被过滤的噪声（dispatch 税 / 帧地板 / regexp undo-log /
> struct 尺寸 / IC / builtin-proto 物理链等）不重复登记，详见 `QJS-FAITHFUL-ALIGN.md` 与 `DIVERGENCE-CATALOG.md`。
>
> **✅ 二次人工复核（2026-07-02，主会话直接双引擎重跑，非 agent 转述）**：全部 high + 绝大多数 medium +
> 代表性 low 共 **~110 条可脚本化断言批量重跑**（探针存 `/tmp/recheck/`），结论：
> - **除 json#4 一处措辞过宽外全部逐字复现**（json#4 已就地修正：单字符 'é' gap 不抛，多字符才抛）。
> - 4 条「qjs 上游 bug、zjs 正确、勿对齐」全部坐实（bigint x--、asUintN(64,-1n)、mixed bigint↔double 比较、Math.sumPrecise→Infinity）。
> - 两条初测不符系复核探针形态问题，按审计原文重跑后精确复现：objprop#0-R3 需换 proto 用不同键名；
>   modules#9 需以相对路径调用 zjs（绝对路径时 file:// URL 正确）。
> - 未逐条亲测的剩余项：纯 structural 代码结构断言（其行为面均已复现）、纯 message-shape 类（抽样确认空消息模式成立）、
>   gen#0/#1/promise#0 深层异步时序（其有界姊妹项 gen#2/#3/#4 已复现，间接佐证）。

**总计确认偏离 166 条**：high 48 / medium 70 / low 48；有界（可局部修，天级）156 条，深前沿（多会话/结构重写）10 条。

## 目录（按功能面）

| 功能面 | high | medium | low | 备注 |
|---|---|---|---|---|
| 对象 / 属性 / Shape | 2 | 2 | 4 | |
| Array | 3 | 4 | 3 | |
| String | 2 | 0 | 3 | |
| RegExp（表面行为） | 0 | 3 | 2 | |
| TypedArray / ArrayBuffer / Atomics | 1 | 7 | 4 | |
| Map / Set / Weak* | 1 | 5 | 3 | |
| Promise / 异步 / 微任务 | 4 | 3 | 2 | |
| 生成器 / 迭代器 | 7 | 2 | 4 | |
| class / 构造 | 4 | 1 | 1 | |
| Proxy / Reflect | 1 | 2 | 8 | |
| JSON | 4 | 7 | 1 | |
| Date | 3 | 2 | 2 | |
| Number / Math / dtoa | 4 | 3 | 2 | |
| BigInt | 0 | 8 | 1 | |
| Error / 异常 / 栈回溯 | 1 | 7 | 2 | |
| 模块 / eval / 全局绑定 | 4 | 6 | 1 | |
| 解析器 / 语法 | 5 | 4 | 3 | |
| Function / 全局对象 | 2 | 4 | 2 | |

---

## 对象 / 属性 / Shape  `[object-property-shape]`

> 覆盖说明：Compared zjs HEAD 541c30f vs quickjs 04be246 with 58 differential probe scripts (/tmp/propaudit/p01-p58) plus source reading of src/exec/{object_ops,vm_property_field,vm_property_ref,iterator_ops,forof_ops,call_runtime}.zig, src/builtins/{object,array}.zig, src/core/{object,shape,property,descriptor}.zig against JS_Get/Set/Define/DeleteProperty, JS_GetOwnPropertyNamesInternal, build_for_in_iterator/js_for_in_next, JS_CreateProperty, js_object_* in quickjs.c. CONFIRMED ALIGNED (probe-verified): Object/Object.prototype/Reflect surface is byte-identical (no missing_in_zjs, no zjs_extra); descript

### object-property-shape#0 — HIGH · behavior · 有界

for-in machinery diverges structurally: zjs eagerly snapshots the ENTIRE prototype chain at forInStart and re-checks keys per-step with HasProperty (proto-walking, calls proxy 'has' trap), while qjs snapshots only the root object and walks the prototype chain LAZILY in js_for_in_next with a per-step own-property (gopd) existence re-check — producing at least 4 observable divergences.

- **repro**：R1 (deleted own key shadowing proto): var proto={p:1},o=Object.create(proto);o.a=1;o.p=2;var s=[];for(var k in o){s.push(k);if(k==='a')delete o.p;}print(s.join(',')) -> zjs 'a,p' / qjs 'a'. R2 (proto prop added mid-iteration): var proto={p1:1},o=Object.create(proto);o.a=1;o.b=2;var s=[];for(var k in o){s.push(k);if(k==='a')proto.p2=2;}print(s.join(',')) -> zjs 'a,b,p1' / qjs 'a,b,p1,p2'. R3 (proto swapped): setPrototypeOf(o,protoB) during iteration -> zjs 'a' / qjs 'a,y1'. R4 (grandproto add) -> zjs 'r,m' / qjs 'r,m,deep'.
- zjs：`src/exec/forof_ops.zig:30 (createForInIterator); src/exec/iterator_ops.zig:846-975 (forInNext/simpleForInNext hasValueProperty re-check)`
- qjs：`build_for_in_iterator quickjs.c:16268; js_for_in_next quickjs.c:16404; js_for_in_prepare_prototype_chain_enum quickjs.c:16343`
- 建议修法：Rewrite the for-in iterator to mirror qjs: store {obj, idx, tab_atom, in_prototype_chain}; snapshot only root own keys at start; on exhaustion walk one proto at a time collecting its keys, dedup via visited list (qjs stores visited as props on enum_obj); replace the per-step hasValueProperty check with a per-step OWN-property (gopd/proxy-gopd) existence check on the current chain object.

### object-property-shape#1 — HIGH · behavior · 有界

Length-growing Array mutators (push/unshift/splice-insert) on sealed or non-extensible arrays silently 'succeed' in zjs — growing length, LOSING the value (a null hole appears), and displacing tail elements — where qjs throws TypeError('object is not extensible').

- **repro**：var a=[1,2];Object.seal(a);a.push(9);print(JSON.stringify(a),a.length) -> zjs '[1,2,null] 3' (no throw, 9 lost) / qjs uncaught 'TypeError: object is not extensible'. Also: [1,2] sealed, a.unshift(0) -> zjs [0,1,null] (element 2 lost) / qjs TypeError; a.splice(1,0,9) -> zjs [1,9,null] / qjs TypeError. Non-growing mutators (reverse/sort/fill/copyWithin/splice-swap/pop/shift) align.
- zjs：`src/builtins/array.zig:953 (push); splice src/builtins/array.zig:920; unshift slow path shares the defineOwnProperty pattern`
- qjs：`js_array_push -> JS_SetPropertyInternal; JS_CreateProperty not_extensible branch quickjs.c:10126/10144`
- 建议修法：Route the growth writes in push/unshift/splice through the same Set/CreateDataPropertyOrThrow semantics as qjs (reject when !extensible and throw TypeError), or add the extensibility rejection to the internal array-index defineOwnProperty append path.

### object-property-shape#2 — MEDIUM · behavior · 有界

`delete` on a primitive base always returns true in zjs without coercing the key or consulting the wrapper's property attributes; qjs converts via ToObject and returns false for non-configurable wrapper props (string indices, .length) and throws TypeError in strict mode.

- **repro**：print(delete 'ab'[0]); print(delete 'ab'.length); var log=[],k={toString(){log.push('ts');return '0';}}; print(delete 'ab'[k], log.join(',')); (function(){'use strict'; try{ delete 'ab'[0]; print('nothrow'); }catch(e){ print('strict:'+e.constructor.name); }})(); -> zjs: 'true / true / true <empty> / nothrow(true)' ; qjs: 'false / false / false ts / strict:TypeError'.
- zjs：`src/exec/vm_property_ref.zig:455-457 (deletePropertyVm primitive branch)`
- qjs：`js_operator_delete quickjs.c:16072; JS_DeleteProperty quickjs.c:10920`
- 建议修法：In deletePropertyVm, coerce the key to an atom first (matching qjs's ValueToAtom-first order), then for primitive bases materialize the wrapper (primitiveObjectForAccess) and run the real delete so string indices/.length report false and strict mode throws.

### object-property-shape#3 — MEDIUM · behavior · 有界

Systemic TypeError message-shape divergence: many property-subsystem errors that carry descriptive messages in qjs are EMPTY strings in zjs (bare Zig error.TypeError), and some carry different or wrong-verb text.

- **repro**：try{var o={};Object.defineProperty(o,'x',{value:1});Object.defineProperty(o,'x',{value:2});}catch(e){print(e.message)} -> zjs '' / qjs 'property is not configurable'. var r=Proxy.revocable({},{});r.revoke();try{Object.keys(r.proxy)}catch(e){print(e.message)} -> zjs '' / qjs 'revoked proxy'.
- zjs：`src/exec/object_ops.zig:1934 et al. (bare error.TypeError proxyTarget sites); src/exec/object_ops.zig:4209 (wrong-verb nullish message); descriptor validation sites`
- qjs：`JS_ThrowTypeErrorRevokedProxy / js_obj_to_desc / JS_DefineProperty message sites in quickjs.c (grep the literal strings)`
- 建议修法：Sweep the property subsystem's bare `return error.TypeError` sites reachable from user code and replace with throwTypeErrorMessage using qjs's exact strings; add a 'cannot set property' variant for write paths.

### object-property-shape#4 — LOW · behavior · 有界

For computed SET and DELETE on a null/undefined base, zjs throws before running ToPropertyKey while qjs coerces the key first — user Symbol.toPrimitive/toString side effects that qjs runs are skipped by zjs.

- **repro**：var log=[],key={[Symbol.toPrimitive](){log.push('toPrim');return 'k';}}; try{null[key]=1;}catch(e){log.push('err');} print(log.join(',')) -> zjs 'err' / qjs 'toPrim,err'. Same for `delete null[key]`: zjs 'err' / qjs 'toPrim,err'.
- zjs：`src/exec/vm_property_field.zig:596 (put_array_el); src/exec/vm_property_ref.zig:452 (deletePropertyVm)`
- qjs：`JS_SetPropertyValue slow_path quickjs.c:10060; js_operator_delete quickjs.c:16080`
- 建议修法：Move the nullish-base throw after key coercion in the computed set and delete handlers (mirroring JS_ValueToAtom-first order); keep GET's throw-first order as is.

### object-property-shape#5 — LOW · behavior · 有界

Object.isSealed/isFrozen proxy trap ORDER: zjs follows the spec (isExtensible trap first, early-return false if extensible, then ownKeys/gopd) while qjs scans ownKeys+gopd per key FIRST and calls isExtensible LAST — trap call sequences observably differ in both directions.

- **repro**：var log=[];var p=new Proxy({a:1},{isExtensible(t){log.push('isExt');return Reflect.isExtensible(t);},ownKeys(t){log.push('ownKeys');return Reflect.ownKeys(t);},getOwnPropertyDescriptor(t,k){log.push('gopd:'+String(k));return Reflect.getOwnPropertyDescriptor(t,k);}});print(Object.isSealed(p),log.join(',')) -> zjs 'false isExt' / qjs 'false ownKeys,gopd:a'.
- zjs：`src/builtins/object.zig:961 (qjsObjectTestIntegrityCall)`
- qjs：`js_object_isSealed quickjs.c:40717`
- 建议修法：If strict qjs-faithfulness is desired, reorder qjsObjectTestIntegrityCall to props-first/extensible-last; otherwise document as deliberate spec-over-qjs deviation.

### object-property-shape#6 — LOW · behavior · 有界

Object.defineProperties/Object.create props-source trap order: qjs batches ALL getOwnPropertyDescriptor calls up front (JS_GetOwnPropertyNamesInternal with JS_GPN_ENUM_ONLY, self-documented 'XXX: not done in the same order as the spec') then Gets each value; zjs interleaves gopd/get per key (spec order).

- **repro**：var log=[];var props=new Proxy({a:{value:1},b:{value:2}},{ownKeys(t){log.push('ownKeys');return Reflect.ownKeys(t);},getOwnPropertyDescriptor(t,k){log.push('gopd:'+k);return Reflect.getOwnPropertyDescriptor(t,k);},get(t,k){log.push('get:'+k);return t[k];}});Object.defineProperties({},props);print(log.join(',')) -> zjs interleaved / qjs batched.
- zjs：`src/exec/call_runtime.zig:7068 (qjsDefinePropertiesCall -> qjsDefinePropertiesOnTarget)`
- qjs：`JS_ObjectDefineProperties quickjs.c:40059 (comment at ~40078)`
- 建议修法：Either mirror qjs's batched gopd-then-get order in qjsDefinePropertiesOnTarget, or record as deliberate spec-over-qjs deviation (qjs itself flags it as non-spec).

### object-property-shape#7 — LOW · behavior · 有界

qjs's JS_CreateProperty array quirk (length updated BEFORE the define is validated — its own 'XXX: should update the length after defining the property') is not reproduced by zjs: a failed Reflect.defineProperty of a new index on a sealed array leaves qjs's array grown to idx+1 with null holes while zjs leaves it untouched (spec-correct).

- **repro**：See evidence; both return false but resulting array state diverges.
- zjs：`src/core/object.zig defineOwnProperty array-index path (rejects before touching length)`
- qjs：`JS_CreateProperty quickjs.c:10126, generic_array length pre-update ~10170`
- 建议修法：Probably WONTFIX/document: zjs is spec-correct and matching would mean importing a qjs bug qjs itself marks XXX; decide policy explicitly in the divergence catalog.

---

## Array  `[array]`

> 覆盖说明：Compared all js_array_* surfaces of qjs 04be246 against zjs HEAD 541c30f with ~35 differential probe scripts plus code reading of exec/array_ops.zig (6.4k lines), builtins/array.zig, core/array.zig. CONFIRMED ALIGNED (no divergence found): species construction for map/filter/slice/splice/concat/flat/flatMap incl. Symbol.species overrides, weird species ctors, null/undefined/non-ctor species, species-throw state, and by-copy methods (toReversed/toSorted/toSpliced/with) correctly NOT using species; holes semantics (forEach/map/filter skip, find visits, indexOf/includes/lastIndexOf undefined-vs-h

### array#0 — HIGH · behavior · 有界

Cyclic array join/toString recursion crashes zjs with SIGSEGV (core dump, uncatchable) where qjs throws a catchable InternalError 'stack overflow'.

- **repro**：var c=[1]; c.push(c);
try { c.join(","); print("joined"); } catch(e){ print("caught:", e.name); }
-- zjs: 'timeout: the monitored command dumped core', exit 139 (crash even inside try/catch)
-- qjs: 'caught: InternalError', exit 0
- zjs：`src/exec/array_ops.zig:5739 (qjsArrayJoinCall)`
- qjs：`js_array_join quickjs.c:42651 + js_check_stack_overflow in JS_CallInternal`
- 建议修法：Add the js_check_stack_overflow-equivalent native stack/depth check at nested native-builtin call entry (the same glue that runs element toString from join), turning overflow into a thrown InternalError.

### array#1 — HIGH · behavior · 有界

Array.prototype.shift/unshift bypass Proxy [[HasProperty]]/[[Delete]] during the element-move loop (raw object.hasProperty/deleteProperty on the proxy object), silently corrupting proxy receivers.

- **repro**：var p = new Proxy({length:3, 0:"a", 1:"b", 2:"c"}, {});
print(Array.prototype.shift.call(p), p[0], p[1], p[2], p.length);
p = new Proxy({length:3, 0:"a", 1:"b", 2:"c"}, {});
Array.prototype.unshift.call(p, "z"); print(p[0], p[1], p[2], p[3]);
-- zjs: 'a a b c 2' (elements never moved) and 'z b c undefined' ("a" lost)
-- qjs: 'a b c undefined 2' and 'z a b c'
- zjs：`src/exec/array_ops.zig:3228 (qjsArrayShiftCall move loop), :3552 (unshiftMoveIndex)`
- qjs：`js_array_pop magic=1 (shift) quickjs.c:42708 and js_array_push magic=1 (unshift) quickjs.c:42761 — both use JS_TryGetPropertyInt64/JS_SetPropertyInt64/JS_DeletePropertyInt64`
- 建议修法：Replace raw object.hasProperty/object.deleteProperty in shift and unshiftMoveIndex with the proxy-aware hasValueProperty + deleteValuePropertyOrThrow already used by splice/reverse/sort (whose trap logs match qjs).

### array#2 — HIGH · behavior · 有界

Mutating array builtins (fill/copyWithin/reverse/sort/shift/splice) silently swallow element write failures for sloppy-mode callers — frozen/non-writable receivers get silently corrupted instead of throwing TypeError as qjs always does.

- **repro**：var a=[1,2,3]; Object.defineProperty(a,1,{writable:false}); a.fill(7);
var s=[3,2,1]; Object.defineProperty(s,0,{writable:false}); s.sort();
var f=Object.freeze([1,2,3]); f.reverse(); f.fill(9); f.copyWithin(0,1);
-- zjs: no throws; a==[7,2,7], s==[3,2,3] (silent corruption), frozen calls 'succeed'
-- qjs: TypeError on all (fill stops at [7,2,3], sort leaves [3,2,1])
- zjs：`src/exec/object_ops.zig:3171 (setFailureShouldThrow gate) + src/exec/array_ops.zig:3026/3231/4372 (null-or-caller-gated writes)`
- qjs：`JS_SetPropertyInt64(..., JS_PROP_THROW) in js_array_fill quickjs.c:42370, js_array_reverse 42821, js_array_sort 43476, js_array_copyWithin 43206`
- 建议修法：Route all array-builtin element/length writes through a throw-on-failure setter (setValuePropertyStrict already exists at object_ops.zig:1213), independent of caller strictness; then drop the ensureSettable* pre-checks.

### array#3 — MEDIUM · behavior · 有界

push/pop/shift/unshift re-read and validate 'length' after setting it (verifyArrayLikeLengthSet): an extra observable [[Get]] trap per call, and a spurious TypeError when a length setter silently swallows the write (qjs succeeds).

- **repro**：var t={0:"a",1:"b"}; Object.defineProperty(t,"length",{get(){return 2;},set(v){},configurable:true});
try{ print("pop:", Array.prototype.pop.call(t)); }catch(e){ print("pop threw:", e.name); }
try{ print("push:", Array.prototype.push.call(t,"c")); }catch(e){ print("push threw:", e.name); }
-- zjs: 'pop threw: TypeError' / 'push threw: TypeError'
-- qjs: 'pop: b' / 'push: 3'
- zjs：`src/exec/array_ops.zig:3579 (verifyArrayLikeLengthSet; call sites :3106/:3162/:3244/:3385)`
- qjs：`js_array_push/js_array_pop quickjs.c:42761/42708 (set length once, no read-back)`
- 建议修法：Delete verifyArrayLikeLengthSet and its call sites; rely on the throwing Set from the previous finding for failure semantics.

### array#4 — MEDIUM · structural · 有界

Array.prototype.sort uses a bottom-up merge sort instead of mirroring qjs rqsort + js_array_cmp_generic: comparator call sequence/count differ on every sort, the identical-value memcmp skip is missing, and inconsistent comparators produce different orders.

- **repro**：var log=[]; [5,3,4,1,2].sort((a,b)=>{log.push(a+":"+b); return a-b;}); print(log.join(" "), log.length);
-- zjs: '3:5 1:4 1:3 4:3 4:5 2:1 2:3' count 7 / qjs: '5:3 5:4 3:4 5:1 4:1 3:1 5:2 4:2 3:2 1:2' count 10
var o={},n=0; [o,o].sort(()=>{n++;return 0;}); print(n); -- zjs 1 / qjs 0
var c=[3,1,2]; c.sort((x,y)=>x>y); -- zjs [3,1,2] / qjs [1,2,3] (inconsistent comparator, impl-defined, but diverges)
- zjs：`src/exec/array_ops.zig:4414 (stableArraySortEntries) / :4391 (arraySortCompare)`
- qjs：`js_array_cmp_generic quickjs.c:43362-43422 (memcmp skip at 43377) + rqsort in js_array_sort 43468`
- 建议修法：Port rqsort ordering with the ValueSlot pos tie-break and the bit-identical-pair skip into the sort entry comparator; keep the existing ToString-key cache.

### array#5 — MEDIUM · behavior · 有界

Array-length RangeErrors from 'arr.length = <invalid>' and push-past-2^32-1 escape as bare host errors: uncaught they print 'zjs: evaluation failed: RangeError' with NO stack and all prior stdout lost; caught they have e.message === '' (qjs: 'invalid array length' / 'Array loo long' with backtrace).

- **repro**：print("before"); var b=[]; b.length=-1;
-- zjs: only 'zjs: evaluation failed: RangeError' ('before' vanished), exit 1
-- qjs: 'RangeError: invalid array length' + backtrace + 'before'
Also: try{ b.length=-1 }catch(e){ print(e.message) } -> zjs '' vs qjs 'invalid array length'; same for push at a[4294967294] boundary.
- zjs：`src/exec/object_ops.zig:3206 (InvalidLength -> bare error.RangeError; same pattern at 1236/1713/3255/3311)`
- qjs：`set_array_length quickjs.c:9582 JS_ThrowRangeError(ctx, "invalid array length"); js_array_push overflow quickjs.c:42796 JS_ThrowTypeError(ctx, "Array loo long")`
- 建议修法：Materialize the JS RangeError (with qjs's message) at the set_array_length-equivalent throw sites instead of returning a bare Zig error; ensure the CLI driver flushes stdout before reporting uncaught host errors.

### array#6 — MEDIUM · behavior · 有界

typeof <identifier> inside a with(){} block ignores the with-scope binding entirely and resolves against the outer/global scope (found while probing Array unscopables; root cause is in with/typeof opcode handling, not array code).

- **repro**：with ({a:1}) { print(typeof a); }
with ([1]) { print(typeof join, typeof length); }
-- zjs: 'undefined' / 'undefined undefined'
-- qjs: 'number' / 'function number'
Direct reads are fine: with({a:1}){print(a)} -> 1 in both.
- zjs：`src/exec/vm_property_ref.zig:78 (with_get_var handler is correct; the typeof compile/dispatch path never routes through it)`
- qjs：`OP_with_get_var quickjs.c:20490 + get_with_scope_opcode mapping 32765`
- 建议修法：Make the typeof-identifier bytecode path emit/handle the with-scoped variant (mirror qjs OP_scope_get_var_undef -> OP_with_get_var lowering) so typeof consults with-objects before falling back.

### array#7 — LOW · behavior · 有界

Array.prototype[Symbol.unscopables] is missing the 'at' entry present in qjs (and the spec).

- **repro**：print(Object.keys(Array.prototype[Symbol.unscopables]).sort().join(","))
-- zjs: copyWithin,entries,fill,... (15 keys, no 'at')
-- qjs: at,copyWithin,entries,... (16 keys)
- zjs：`src/core/object.zig:7356 (materializeArrayUnscopablesAutoInit names array)`
- qjs：`js_array_unscopables_funcs quickjs.c (~44750, above js_array_proto_funcs)`
- 建议修法：Add "at" as the first entry of the names list.

### array#8 — LOW · behavior · 有界

Array.prototype.toReversed on non-fast receivers issues only [[Get]] per element; qjs issues [[HasProperty]] then [[Get]] (JS_TryGetPropertyInt64), so proxy has-trap counts differ (zjs matches spec, qjs does not).

- **repro**：var log=[]; var p=new Proxy({length:2,0:"a",1:"b"},{get(t,k){log.push("get:"+String(k));return t[k];},has(t,k){log.push("has:"+String(k));return k in t;}});
Array.prototype.toReversed.call(p); print(log.join(" "));
-- zjs: 'get:length get:1 get:0'
-- qjs: 'get:length has:1 get:1 has:0 get:0'
- zjs：`src/exec/array_ops.zig:4527 (to_reversed branch of qjsArrayByCopyCall)`
- qjs：`js_array_toReversed quickjs.c:42894 (JS_TryGetPropertyInt64)`
- 建议修法：If strict qjs parity is wanted, use the has+get helper here; otherwise document as a deliberate spec-over-qjs divergence.

### array#9 — LOW · behavior · 有界

Array iterator (keys/values/entries) on array-likes with length >= 2^32 iterates in zjs (spec ToLength) but terminates immediately in qjs, whose iterator clamps length via js_get_length32.

- **repro**：var kit = Array.prototype.keys.call({length: Math.pow(2,40)});
print(kit.next().value, kit.next().value);
-- zjs: '0 1'
-- qjs: 'undefined undefined' (done immediately: ToUint32(2^40)==0)
- zjs：`src/exec/array_ops.zig:5437 (qjsArrayIteratorMethodRecord / iterator next length read)`
- qjs：`js_array_iterator_next quickjs.c:43628 (js_get_length32 clamp)`
- 建议修法：Either clamp iterator length to uint32 for byte-level qjs parity or record this as an accepted spec-over-qjs divergence in the catalog.

---

## String  `[string]`

> 覆盖说明：Compared via ~120 differential probes run on both binaries (7 batteries under /tmp/sp*.js) plus source reading of all 4 zjs files against js_string_* in quickjs.c. CONFIRMED ALIGNED: full own-property surface of String and String.prototype (names, symbols, function .length values — byte-identical, including all 13 AnnexB HTML methods, substr, at, isWellFormed/toWellFormed); coercion/side-effect ORDER for indexOf/lastIndexOf/includes/startsWith/endsWith/at/substr/split/padStart/String.raw/fromCharCode/fromCodePoint/normalize (all match); negative/NaN/fractional/-0/Infinity/2^32 indices across a

### string#0 — HIGH · behavior · 有界

String.prototype.repeat with count >= 2^31 segfaults zjs (exit 139) and count in [2^30, 2^31) builds strings qjs forbids, because zjs repeat lacks qjs's `val > 2147483647` RangeError and `val*len > JS_STRING_LEN_MAX` checks.

- **repro**：zjs -e '"a".repeat(4294967296)' => SIGSEGV (exit 139); qjs => RangeError: invalid repeat count. Also '"a".repeat(2147483648)' segfaults zjs; '"a".repeat(1e12)' => zjs InternalError: out of memory vs qjs RangeError: invalid repeat count; '"a".repeat(2147483647)' => zjs succeeds (2GB string) vs qjs RangeError: invalid string length.
- zjs：`src/builtins/string.zig:1342 (repeatReceiver); same gap in fn repeat at :1367`
- qjs：`js_string_repeat, quickjs.c:45371 (checks at 45385 and 45394)`
- 建议修法：Mirror js_string_repeat exactly: reject count > 2147483647 with RangeError 'invalid repeat count', and reject unit_len*count > (1<<30)-1 with RangeError 'invalid string length' before allocating.

### string#1 — HIGH · behavior · 有界

zjs has no JS_STRING_LEN_MAX ((1<<30)-1) enforcement at string creation/concat: strings above 2^30 build silently and at 2^31 the packed u31 len field wraps, making .length report -2147483648 and charAt return garbage, where qjs throws InternalError 'string too long'.

- **repro**：var x="a".repeat(536870912); var y=x+x; var z=y+y; print(y.length, z.length, z.charAt(2147483646)) => zjs: 1073741824, -2147483648, "" ; qjs: throws InternalError: string too long at the first concat (len 2^30 > JS_STRING_LEN_MAX).
- zjs：`src/core/string.zig:611-627 (createUninitialized) + rope create path (StringRope, core/string.zig:26)`
- qjs：`JS_STRING_LEN_MAX quickjs.c:212; JS_ConcatString cap quickjs.c:4368-4369, rope cap 4655, string_buffer_realloc 4077`
- 建议修法：Add a js_string_len_max guard (already defined in exec/string_ops.zig:4533, move it to core) inside createUninitialized and the rope constructor, returning the error mapped to InternalError 'string too long', mirroring quickjs.c:4368/4655.

### string#2 — LOW · behavior · 有界

HTML-legacy attribute methods (anchor/link/fontcolor/fontsize) stringify a missing/null/undefined attribute argument to 'undefined'/'null' in zjs, but qjs deliberately applies JS_ToStringCheckObject to argv[0] and throws TypeError.

- **repro**："x".anchor() / "x".anchor(null) / "x".link(undefined) / "x".fontcolor() / "x".fontsize() => zjs: '<a name="undefined">x</a>', '<a name="null">x</a>', '<a href="undefined">x</a>', '<font color="undefined">x</font>', '<font size="undefined">x</font>' ; qjs: TypeError: null or undefined are forbidden (all five). Non-attr tags (big/bold/...) and object args match.
- zjs：`src/exec/string_ops.zig:4899/4904-4907 (qjsStringHtmlMethod) + qjsStringCreateHtml attr conversion (~4933)`
- qjs：`js_string_CreateHTML, quickjs.c:46790 (CheckObject on attr value at 46817)`
- 建议修法：In qjsStringCreateHtml, when has_attr, throw TypeError 'null or undefined are forbidden' if attr_value is null/undefined before coercing (mirror JS_ToStringCheckObject).

### string#3 — LOW · behavior · 有界

localeCompare clamps its result to -1/0/1 while qjs returns the raw NFC-normalized UTF-32 code-point difference (sign always agrees, magnitude observably differs).

- **repro**："a".localeCompare("c") => zjs -1, qjs -2; "😀".localeCompare("z") => zjs 1, qjs 128390; "ä".localeCompare("z") => zjs 1, qjs 106. NFC-equality cases ("é" composed vs decomposed, "Å" U+212B) match at 0 — zjs does normalize.
- zjs：`src/exec/string_ops.zig:4735-4740`
- qjs：`js_string_localeCompare (CONFIG_ALL_UNICODE variant), quickjs.c:46673 + js_UTF32_compare ~46650`
- 建议修法：Replace std.mem.order with an element-wise loop returning `@as(i64, lhs[i]) - rhs[i]` truncated to i32 at first mismatch, then -1/0/1 on length, mirroring js_UTF32_compare.

### string#4 — LOW · behavior · 有界

Numerous string builtins throw bare error codes so the JS-visible message is empty where qjs carries a specific message (error TYPES all match; message shape only).

- **repro**：e.message for: "abc".includes(/b/) => '' vs 'regexp not supported'; "aa".replaceAll(/a/, "b") => '' vs "regexp must have the 'g' flag"; String.fromCodePoint(-1) => '' vs 'invalid code point'; "a".normalize("NFX") => '' vs 'bad normalization form'; String.raw(undefined) => '' vs 'cannot convert to object'; String.prototype.toString.call(42) => '' vs 'not a string'; "a".concat(Symbol()) => '' vs 'cannot convert symbol to string'.
- zjs：`src/builtins/string.zig:369; src/exec/string_ops.zig:4698 (representative bare-error sites)`
- qjs：`js_string_includes quickjs.c:45743 ('regexp not supported'), js_string_fromCodePoint 45333 ('invalid code point'), js_string_normalize 46599 ('bad normalization form'), js_string_replace 46008 (g-flag message), js_thisStringValue ('not a string')`
- 建议修法：Route the bare error.TypeError/error.RangeError returns in the string record-dispatch bodies through throw*ErrorMessage with qjs's exact strings (the exec helpers already exist and are used by sibling paths).

---

## RegExp（表面行为）  `[regexp-surface]`

> 覆盖说明：Compared zjs HEAD 541c30f vs quickjs 04be246 with ~22 differential probe scripts run on both binaries (all under /tmp/rxprobe). CONFIRMED CLEAN/ALIGNED: lastIndex protocol (writable/non-writable on global+sticky+non-global, frozen regexps across exec/test/match/replace/split/search, valueOf coercion count+order, huge 2^53+/negative/fractional values, no-write on non-global, compile's SetProperty lastIndex reset incl. non-writable throw); Symbol.match/replace/search/split/matchAll generic paths with monkey-patched instance exec, replaced RegExp.prototype.exec, plain-object receivers (property-r

### regexp-surface#0 — MEDIUM · behavior · 有界

String.prototype.match/search/split silently fall back to builtin RegExp matching when RegExp.prototype[Symbol.match]/[Symbol.search]/[Symbol.split] has been deleted, instead of qjs's TypeError (match/search) or ToString-based string split.

- **repro**：delete RegExp.prototype[Symbol.match]; print(JSON.stringify('a'.match(/a/)))  -> zjs: ["a"], qjs: TypeError. Same for search: delete RegExp.prototype[Symbol.search]; 'a'.search(/a/) -> zjs: 0, qjs: TypeError. And split: delete RegExp.prototype[Symbol.split]; 'a,b'.split(/,/) -> zjs: ["a","b"], qjs: ["a,b"] (string-split on ToString(/,/)). Deleted @@replace and @@matchAll paths are correctly aligned.
- zjs：`src/exec/string_ops.zig:2544-2550 (match/search fallback), src/exec/string_ops.zig:2624 (split)`
- qjs：`js_string_match quickjs.c:45836 (JS_Invoke @@match on rx, throws if undefined); js_string_split quickjs.c:46121 (GetMethod @@split, else string split)`
- 建议修法：In qjsStringRegExpCreateAndInvoke, when the well-known method is still missing after constructing rx, throw TypeError (delete the qjsRegExpSearch/qjsRegExpMatch fallback); in qjsStringSplit, only take qjsRegExpSplit when GetMethod(separator,@@split) actually resolved to the builtin, otherwise fall through to the string-split path.

### regexp-surface#1 — MEDIUM · behavior · 有界

RegExp.prototype.compile throws TypeError on RegExp subclass instances (and any regexp whose prototype is not the realm's RegExp.prototype), while qjs only requires JS_CLASS_REGEXP and compiles successfully.

- **repro**：class R extends RegExp {}; var r = new R('a'); r.compile('b'); print(r.source)  -> zjs: TypeError, qjs: 'b'
- zjs：`src/exec/regexp_fastpath.zig:363-367`
- qjs：`js_regexp_compile quickjs.c:47811 (js_get_regexp class-only check)`
- 建议修法：Drop the getPrototype()==RegExp.prototype check; keep only the class_id == regexp gate to mirror js_get_regexp.

### regexp-surface#2 — MEDIUM · behavior · 有界

RegExp constructor with a Symbol pattern or flags never hits ToString's TypeError: zjs builds a regexp with source "[object Object]" (pattern) or throws SyntaxError (flags) where qjs throws TypeError.

- **repro**：new RegExp(Symbol('x'))  -> zjs: constructs /[object Object]/ (no throw), qjs: TypeError. new RegExp('a', Symbol()) -> zjs: SyntaxError, qjs: TypeError. Also reproduces via Reflect.construct(RegExp,[Symbol()]). All object patterns (plain objects with toString, arrays, via new/call/Reflect/bind/apply) coerce correctly.
- zjs：`src/exec/regexp_fastpath.zig:227,253 (isObject-only coercion gate); src/builtins/regexp.zig:1493-1495 (silent '[object Object]' for symbols)`
- qjs：`js_regexp_constructor quickjs.c:47728 (JS_ToString on pattern/flags)`
- 建议修法：In qjsRegExpConstructCall/qjsRegExpFunctionCall coerce any non-string non-regexp pattern/flags through the real ToString helper (which throws for Symbol), or make appendValueString return error.TypeError for symbol values.

### regexp-surface#3 — LOW · behavior · 有界

RegExp.escape output diverges on non-ASCII and control characters: qjs hex-escapes all Latin-1 0x80-0xFF and all C0 controls and backslash-prefixes every other non-alphanumeric ASCII (incl. DEL), while zjs implements the spec's EncodeForRegExpEscape and leaves them raw.

- **repro**：print(RegExp.escape('é'), JSON.stringify(RegExp.escape('\x01')), JSON.stringify(RegExp.escape('\x7f')))  -> zjs: 'é' '""' (raw) '""' (raw); qjs: '\xe9' '"\\x01"' '"\\"' (backslash-prefixed). Alphanumerics, punctuators, whitespace, surrogates, \t\n\v\f\r all align.
- zjs：`src/builtins/regexp.zig:1335 (escape), 1536 (appendEscapedCodeUnit)`
- qjs：`js_regexp_escape quickjs.c:48021-48072`
- 建议修法：Document in DIVERGENCE-CATALOG as spec-vs-qjs conflict resolved in favor of spec/test262; do not align (would break test262 RegExp.escape tests).

### regexp-surface#4 — LOW · behavior · 深前沿

RegExp error message shape diverges: zjs throws TypeError with empty messages and generic SyntaxError 'invalid syntax' where qjs carries specific texts ('invalid regular expression flags', "expecting ')'", 'not an object', "regexp must have the 'g' flag", 'RegExp object expected', 'not a string').

- **repro**：try{new RegExp('a','gg')}catch(e){print(e.name+': '+e.message)}  -> zjs: 'SyntaxError: invalid syntax', qjs: 'SyntaxError: invalid regular expression flags'. try{'x'.matchAll(/a/)}catch(e){print(e.message)} -> zjs: '' , qjs: "regexp must have the 'g' flag"
- zjs：`src/exec/regexp_fastpath.zig (bare `return error.TypeError` sites throughout); src/libs/regexp.zig compile error mapping to generic SyntaxError`
- qjs：`js_regexp_* JS_ThrowTypeError call sites (e.g. quickjs.c:48032 'not a string', 47826 'flags must be undefined')`
- 建议修法：Thread qjs's message strings through the regexp HostError paths (or address engine-wide as a separate message-alignment slice).

---

## TypedArray / ArrayBuffer / Atomics  `[typedarray-buffer]`

> 覆盖说明：Compared zjs HEAD 541c30f vs quickjs 04be246 by source read + ~35 differential probe scripts run on both binaries. CONFIRMED CLEAN/ALIGNED (matched byte-for-byte on both engines): detached-buffer TypeError at all 30+ %TypedArray% methods incl. iterators/toLocaleString/index r/w; detach-and-resize-mid-operation via valueOf/toString/getter side effects for fill/copyWithin/slice/subarray/indexOf/with/at/set/sort/join/toLocaleString (incl. re-clamp semantics on length-tracking views: fill-shrink, cw-grow, set-shrink, sort-shrink all identical); TA ctor paths (iterable vs array-like selection incl.

### typedarray-buffer#0 — HIGH · behavior · 有界

zjs's shared sort merge (used by BOTH TypedArray.prototype.sort/toSorted AND Array.prototype.sort) calls the user comparator with arguments in REVERSED order — comparator receives (later-element, earlier-element) — so inconsistent comparators produce different final orders than qjs and the argument values user code observes differ.

- **repro**：var t=new Int32Array([5,9]); t.sort((a,b)=>{print('args:',a,b);return 0;});
zjs: args: 9 5 — qjs: args: 5 9
var u=new Int32Array([2,1]); u.sort(()=>1); print(u.join(','));
zjs: 2,1 — qjs: 1,2 (also [2,1].sort(()=>true): zjs 2,1 / qjs 1,2; ()=>-1: zjs 1,2 / qjs 2,1; same for plain Arrays)
- zjs：`src/exec/array_ops.zig:4438 (stableArraySortEntries) + arraySortCompare array_ops.zig:4391-4412`
- qjs：`js_TA_cmp_generic quickjs.c:58759; js_array_cmp_generic quickjs.c:43362`
- 建议修法：In the merge loop compare (entries[left], entries[right]) and take the right run only when result > 0 (preserves stability), so the user comparator always receives (earlier, later) like qjs's rqsort callbacks.

### typedarray-buffer#1 — MEDIUM · zjs_extra · 有界

%TypedArray%.prototype is installed with the FULL Array method table, exposing 9 non-standard Array-only methods (push, pop, shift, unshift, splice, concat, flat, flatMap, toSpliced) that qjs and the spec do not have — and splice/flat actually execute with nonsense semantics on fixed-length typed arrays.

- **repro**：var t=new Int32Array([1,2]); print('push' in t, 'flat' in t); try{print('splice:',t.splice(0,1),t.join(','))}catch(e){print('splice:',e.constructor.name)}; try{print('flat:',t.flat().join(','))}catch(e){print('flat:',e.constructor.name)}
zjs: true true / splice: 1 2,2 / flat: 2,2
qjs: false false / splice: TypeError / flat: TypeError
- zjs：`src/builtins/registry.zig:1993 (and array_prototype table at 1562)`
- qjs：`js_typed_array_base_proto_funcs quickjs.c:59765`
- 建议修法：Add a dedicated typed_array_prototype Method table containing only the spec %TypedArray% methods (drop push/pop/shift/unshift/splice/concat/flat/flatMap/toSpliced) and point the TypedArray ConstructorSpec at it.

### typedarray-buffer#2 — MEDIUM · behavior · 有界

Atomics ops on a detached ArrayBuffer (detached before the call or mid value-coercion) throw RangeError in zjs where qjs (and spec ValidateIntegerTypedArray/RevalidateAtomicAccess) throw TypeError.

- **repro**：var ab=new ArrayBuffer(8), t=new Int32Array(ab); ab.transfer();
try{Atomics.load(t,0)}catch(e){print(e.constructor.name)} — zjs: RangeError, qjs: TypeError
var ab3=new ArrayBuffer(8), t3=new Int32Array(ab3);
try{Atomics.store(t3,0,{valueOf(){ab3.transfer();return 7;}})}catch(e){print(e.constructor.name)} — zjs: RangeError, qjs: TypeError
- zjs：`src/exec/call_runtime.zig:3445 (atomicsValidateIndex) + src/exec/array_ops.zig:5052 (atomicsTypedArray)`
- qjs：`js_atomics_get_buf quickjs.c:~60559 + js_atomics_op detached re-check`
- 建议修法：Check buffer.arrayBufferDetached() in atomicsTypedArray (TypeError) and again after operand coercion (mirroring js_atomics_op's re-check) before the index bound check.

### typedarray-buffer#3 — MEDIUM · behavior · 有界

Atomics validates the index against the POST-coercion length: if ToIndex(index) side-effects grow a length-tracking view, zjs accepts an index that was out of bounds at validation time, where qjs captures old_len before JS_ToIndex and throws RangeError.

- **repro**：var ab=new ArrayBuffer(8,{maxByteLength:64}); var ta=new Int32Array(ab);
try{print(Atomics.store(ta,{valueOf(){ab.resize(64);return 10;}},7))}catch(e){print(e.constructor.name)}
zjs: 7 (write succeeds) — qjs: RangeError
- zjs：`src/exec/call_runtime.zig:3104-3106 (index coercion then atomicsValidateIndex)`
- qjs：`js_atomics_get_buf quickjs.c:~60564 (old_len captured before JS_ToIndex)`
- 建议修法：Capture typedArrayLength before coercing the index and reject index >= old length (in addition to the fresh revalidation), mirroring js_atomics_get_buf.

### typedarray-buffer#4 — MEDIUM · behavior · 有界

Atomics.wait performs the value comparison BEFORE the can-block check, returning 'not-equal' on the non-blockable main thread where qjs throws TypeError 'cannot block in this thread' first (spec puts AgentCanSuspend before the load/compare); zjs's TypeError also carries an empty message.

- **repro**：var ta=new Int32Array(new SharedArrayBuffer(16));
try{print(Atomics.wait(ta,0,999,0))}catch(e){print(e.constructor.name,e.message)}
zjs: not-equal — qjs: TypeError cannot block in this thread
- zjs：`src/exec/call_runtime.zig:3216-3218 (qjsAtomicsWait)`
- qjs：`js_atomics_wait quickjs.c:60901`
- 建议修法：Move the canBlock() TypeError before the load/compare in qjsAtomicsWait and give it the qjs message.

### typedarray-buffer#5 — MEDIUM · behavior · 有界

Uint8Array base64/hex entry points skip the GetOptionsObject type check: non-object options (null, number, string, boolean) are silently treated as defaults in zjs where qjs throws TypeError — affects toBase64, fromBase64 and setFromBase64.

- **repro**：try{new Uint8Array([1]).toBase64(null); print('ok')}catch(e){print(e.constructor.name)}
zjs: ok — qjs: TypeError (same for toBase64(5)/toBase64(true)/fromBase64('AQI=',5)/fromBase64('AQI=',null)/setFromBase64('AQI=',5))
- zjs：`src/exec/array_ops.zig:5150-5210 (uint8ArrayBase64Alphabet / LastChunkHandling / OmitPadding)`
- qjs：`js_uint8array_to_base64 quickjs.c:59466 / js_uint8array_from_base64 59552 / js_uint8array_set_from_base64 59665`
- 建议修法：Add a shared GetOptionsObject guard: if options is neither undefined nor an object, throw TypeError, before reading alphabet/lastChunkHandling/omitPadding.

### typedarray-buffer#6 — MEDIUM · zjs_extra · 有界

zjs implements the (stage-proposal, non-standard) Immutable ArrayBuffer surface — ArrayBuffer.prototype.sliceToImmutable / transferToImmutable and the 'immutable' getter — plus immutability guards threaded through TA/DataView/base64/Atomics write paths; qjs 04be246 has none of this.

- **repro**：print(typeof ArrayBuffer.prototype.sliceToImmutable, typeof ArrayBuffer.prototype.transferToImmutable, 'immutable' in ArrayBuffer.prototype)
zjs: function function true — qjs: undefined undefined false
- zjs：`src/builtins/buffer.zig:51-52,98-99,132 + src/core/typed_array.zig:153-221`
- qjs：`js_array_buffer_proto_funcs quickjs.c:57332 (no immutable entries)`
- 建议修法：Decision item: either drop the immutable-ArrayBuffer surface (uninstall the 3 prototype entries and dead-code the guards) for strict qjs parity, or record it in the divergence catalog as an accepted extra like Atomics.waitAsync.

### typedarray-buffer#7 — MEDIUM · structural · 有界

SharedArrayBuffer.prototype.grow allocates a brand-new SharedBufferStore and memcpys, instead of qjs's commit-max-upfront + bump-byte_length — growth changes the backing-store identity, breaking cross-runtime store sharing (embedding SharedArrayBufferRef) and orphaning Atomics waiter keys registered against the old store.

- zjs：`src/core/typed_array.zig:246-257 (sharedArrayBufferGrowLength)`
- qjs：`js_array_buffer_resize quickjs.c:57247-57256 + js_array_buffer_constructor3 upfront commit quickjs.c:56739`
- 建议修法：When maxByteLength is present, allocate the SharedBufferStore at max size upfront and have grow only bump the visible byte length (mirror qjs), keeping store identity stable across grow.

### typedarray-buffer#8 — LOW · behavior · 有界

ArrayBuffer.prototype.resize/SharedArrayBuffer.grow argument handling diverges from js_array_buffer_resize in two edge cases: (a) resize(-1) on a NON-resizable buffer throws RangeError in zjs vs TypeError in qjs; (b) resize(1e300)/grow(1e300) throws RangeError in zjs (spec) but SUCCEEDS in qjs because JS_ToInt64 wraps 1e300 mod 2^64 to 0.

- **repro**：try{new ArrayBuffer(8).resize(-1)}catch(e){print(e.constructor.name)} → zjs RangeError / qjs TypeError
var ab=new ArrayBuffer(0,{maxByteLength:8}); try{ab.resize(1e300); print('ok',ab.byteLength)}catch(e){print(e.constructor.name)} → zjs RangeError / qjs ok 0 (same for SharedArrayBuffer.grow(1e300))
- zjs：`src/core/typed_array.zig:259-281 (arrayBufferResize/arrayBufferResizeLength) + :241-244 (sharedArrayBufferGrow)`
- qjs：`js_array_buffer_resize quickjs.c:57216 (JS_ToInt64 + check order)`
- 建议修法：Decision item: to match qjs exactly, coerce with wrapping ToInt64 semantics and check not-resizable (TypeError) before the range check; zjs's current behavior is closer to spec — catalog it if keeping.

### typedarray-buffer#9 — LOW · behavior · 有界

ArrayBuffer.prototype.transfer(newLength) with newLength > maxByteLength on a resizable buffer throws RangeError in zjs (spec AllocateArrayBuffer) but TypeError in qjs.

- **repro**：var ab=new ArrayBuffer(8,{maxByteLength:32}); try{ab.transfer(64)}catch(e){print(e.constructor.name)}
zjs: RangeError — qjs: TypeError
- zjs：`src/core/typed_array.zig:187-191 (arrayBufferTransferLength)`
- qjs：`js_array_buffer_transfer quickjs.c:~57142`
- 建议修法：Decision item: switch to TypeError for strict qjs parity, or catalog (zjs matches spec RangeError; qjs deviates).

### typedarray-buffer#10 — LOW · behavior · 有界

DataView get*/set* on an out-of-bounds (shrunk-resizable, NOT detached) view throws TypeError in zjs (spec IsViewOutOfBounds) but RangeError in qjs (its 'pos + size > ta->length' check fires first).

- **repro**：var ab=new ArrayBuffer(16,{maxByteLength:64}); var dv=new DataView(ab,8); ab.resize(4);
try{dv.getInt8(0)}catch(e){print(e.constructor.name)}
zjs: TypeError — qjs: RangeError
- zjs：`src/core/typed_array.zig:633-647 (dataViewEffectiveByteLength) via checkDataViewBounds:622`
- qjs：`js_dataview_getValue quickjs.c:60276 (RangeError-before-OOB-TypeError ordering)`
- 建议修法：Decision item: reproduce qjs's check order (length RangeError first) or catalog; zjs matches spec/test262 expectations here.

### typedarray-buffer#11 — LOW · behavior · 有界

maxByteLength getter on a DETACHED resizable ArrayBuffer returns 0 in zjs (spec) but the stale pre-detach max in qjs.

- **repro**：var ab=new ArrayBuffer(8,{maxByteLength:16}); ab.transfer(); print(ab.maxByteLength)
zjs: 0 — qjs: 16
- zjs：`exec buffer-accessor glue (builtin_glue.qjsBufferNativeRecord max_byte_length path)`
- qjs：`js_array_buffer_get_maxByteLength quickjs.c:56999`
- 建议修法：Decision item: drop zjs's detached→0 special case for parity, or catalog (zjs matches spec step 'If IsDetachedBuffer, return +0').

---

## Map / Set / Weak*  `[collections-weak]`

> 覆盖说明：Compared zjs src/builtins/collection.zig (2929 ln, both the realm-aware qjs* path and the bare-runtime primitive path), src/core/collection.zig (610 ln backend), WeakRef/FinalizationRegistry glue (src/exec/builtin_glue.zig, construct.zig, registry.zig tables) against quickjs.c 04be246 js_map_* (ctor 51768, set/get/getOrInsert/has/delete/clear/size/forEach 52131-52341, groupBy 52343, iterators 52516-52640), get_set_record 52641 + all 7 set methods 52745-53195, js_weakref_* 51692/61133, js_finrec_* 61254-61420. Ran ~70 behavioral probes across 6 scripts on both binaries (zjs binary Jul 2 02:18, 

### collections-weak#0 — HIGH · structural · 深前沿

Strong Map/Set delete leaves a permanent tombstone (entries array never compacted or reused, and with <8 active entries no hash index is ever built), giving O(total-ever-inserted) per operation and unbounded memory on set/delete churn, where qjs frees each record on delete and stays O(1).

- zjs：`src/core/collection.zig:398`
- qjs：`map_delete_record_internal quickjs.c:52066 / map_add_record quickjs.c:52027`
- 建议修法：Mirror qjs's record model: insertion-ordered linked list of individually-freed records with per-record ref_count for live iterators (iteration-order-safe), instead of append-only array + active flags; slot free-list reuse alone would corrupt insertion order.

### collections-weak#1 — MEDIUM · behavior · 有界

Set-composition/comparison methods skip the observable `has`/`keys` property reads for native Set (and Map) arguments, so instance-level overrides of has/keys are ignored, unlike qjs get_set_record which reads and calls them even for native Sets.

- **repro**：const b=new Set([7,8,9]); b.has=()=>true; print(new Set([1,2]).isSubsetOf(b)); // zjs: false, qjs: true.  Also: const c=new Set([7]); c.keys=function*(){yield 42;}; print([...new Set([1]).union(c)]); // zjs: [1,7], qjs: [1,42].  Map arg: const m=new Map([['k',1]]); m.keys=function*(){yield 'other';}; print([...new Set(['x']).union(m)]); // zjs: ["x","k"], qjs: ["x","other"]
- zjs：`src/builtins/collection.zig:2323`
- qjs：`get_set_record, quickjs.c:52641`
- 建议修法：Mirror get_set_record exactly: keep the internal-size fast path only for class Set (qjs reads .size property for Map args too), but always JS_GetProperty and use the retrieved has/keys functions; drop native_kind short-circuits in qjsSetLikeHas/qjsSetLikeKeysIterator.

### collections-weak#2 — MEDIUM · behavior · 有界

GetSetRecord is missing the negative-size RangeError: a set-like with size<0 silently proceeds in zjs where qjs throws RangeError '.size must be positive'.

- **repro**：try { print([...new Set([1]).union({size:-1, has(){return false}, keys(){return [][Symbol.iterator]()}})]) } catch(e){ print(e.constructor.name) } // zjs: prints [1] (no error), qjs: RangeError .size must be positive
- zjs：`src/builtins/collection.zig:2343`
- qjs：`get_set_record, quickjs.c:52641 (size<0 branch ~52670)`
- 建议修法：After ToNumber, clamp to int64 like qjs and throw RangeError when negative (before reading has/keys, matching qjs order).

### collections-weak#3 — MEDIUM · behavior · 有界

Map.groupBy requires its receiver to be the Map constructor, so a detached reference `const g = Map.groupBy; g(items, fn)` throws TypeError in zjs but works in qjs (js_object_groupBy ignores this_val entirely).

- **repro**：const g = Map.groupBy; print([...g([1,2,3], x=>x%2).entries()]); // zjs: TypeError, qjs: [[1,[1,3]],[0,[2]]]
- zjs：`src/builtins/collection.zig:243`
- qjs：`js_object_groupBy, quickjs.c:52343`
- 建议修法：Drop the receiver/constructor-name gate; resolve the Map prototype from the realm intrinsic (as qjsMapGroupByCall already does via constructorPrototypeFromGlobal) instead of from this_value.

### collections-weak#4 — MEDIUM · behavior · 有界

Map Iterator's next() accepts Set iterators (and vice versa): zjs shares one iterator_next that admits both classes, while qjs js_map_iterator_next type-checks the exact class per magic and throws TypeError cross-kind.

- **repro**：const mi=new Map([[1,2]]).keys(); const si=new Set([3]).values(); print(JSON.stringify(Object.getPrototypeOf(mi).next.call(si))); // zjs: {"value":3,"done":false}, qjs: TypeError 'Map Iterator object expected'
- zjs：`src/builtins/collection.zig:778`
- qjs：`js_map_iterator_next, quickjs.c:52576`
- 建议修法：Stamp the expected iterator class (map_iterator vs set_iterator) into the installed next function (owner-class, like other collection methods) and reject mismatches.

### collections-weak#5 — MEDIUM · zjs_extra · 有界

~500 lines of test-fixture behavior are baked into the engine's bare-runtime collection path: `__setlike_mode` (modes 1–9) fabricates hardcoded keys/has results and writes to globals named observedOrder/baseSet/iter/expects, closureKind 23-25/34-36/49 triggers hardcoded Map mutations in forEach/getOrInsertComputed, and callNativeCallback returns 3 for any callback named 'three' — none of this exists in qjs.

- zjs：`src/builtins/collection.zig:1395`
- qjs：`no counterpart; js_set_* / js_map_forEach quickjs.c:52294+ are generic`
- 建议修法：Delete the fixture modes and closureKind mutation hooks; make the bare-runtime setLikeHas/setLikeKeys generically call the object's has/keys through CallbackHost like the realm path does.

### collections-weak#6 — LOW · behavior · 有界

Map.prototype.getOrInsertComputed keeps the key at its original insertion position when the callback inserted it, but qjs deletes and re-appends the record after the callback, so subsequent iteration order differs.

- **repro**：const m=new Map(); m.getOrInsertComputed('k',()=>{m.set('k','cb'); m.set('z',9); return 'computed';}); print(JSON.stringify([...m.entries()])); // zjs: [["k","computed"],["z",9]], qjs: [["z",9],["k","computed"]]
- zjs：`src/builtins/collection.zig:2845`
- qjs：`js_map_getOrInsert, quickjs.c:52206`
- 建议修法：After the computed callback, delete any entry for the normalized key before appending the new one (mirror map_delete_record+map_add_record), in both the realm path and the primitive mapGetOrInsertComputed.

### collections-weak#7 — LOW · behavior · 有界

FinalizationRegistry.prototype.register silently skips registration when target === the registry itself, so a later unregister(token) returns false; qjs registers normally and unregister returns true.

- **repro**：const fr=new FinalizationRegistry(()=>{}); const tok={}; fr.register(fr,'held',tok); print(fr.unregister(tok)); // zjs: false, qjs: true
- zjs：`src/exec/builtin_glue.zig:427`
- qjs：`js_finrec_register, quickjs.c:61318`
- 建议修法：Remove the self-target short-circuit and store the cell; hold the target weakly (as for any target) so the registry's own liveness is unaffected.

### collections-weak#8 — LOW · behavior · 有界

Collection-path error messages are empty or reworded where qjs carries specific text: '.size is not a number', '.has is undefined', '.has is not a function', 'not a function', 'value is not iterable', 'set/add is not a function', 'must be called with new', 'invalid target', 'invalid unregister token', and WeakSet add says 'invalid value used in weak set' vs qjs 'invalid value used as WeakSet key'.

- **repro**：try{new Set([1]).union({size:1,keys(){return [][Symbol.iterator]()}})}catch(e){print(e.name,'|',e.message)} // zjs: 'TypeError |' (empty), qjs: 'TypeError | .has is undefined'
- zjs：`src/builtins/collection.zig:2349`
- qjs：`get_set_record quickjs.c:52641 / js_map_constructor quickjs.c:51768`
- 建议修法：Route these through throwTypeErrorMessage with qjs's exact strings instead of bare error.TypeError; fix the WeakSet wording to 'invalid value used as WeakSet key'.

---

## Promise / 异步 / 微任务  `[promise-async-jobs]`

> 覆盖说明：Compared zjs promise/job/async sources (core/promise.zig 794L, core/jobs.zig, exec/promise_ops.zig 3949L, exec/vm_gen_async.zig 571L) against quickjs.c 04be246 js_promise_* (~53340-54420), JS_EnqueueJob (~2263), js_async_function_* (~21196-21345), js_async_generator_* (~21400+), and ran 33 behavioral probes on both binaries. CONFIRMED-ALIGNED (probe-verified, no divergence): resolve-function shape (name ''/length 1/Function.prototype/distinct fns) and once-semantics; capability-executor double-call TypeError; Promise[Symbol.species] getter presence and constructor/species read count+order in t

### promise-async-jobs#0 — HIGH · behavior · 有界

Resolving a promise with a non-promise thenable never enqueues a thenable job: thenable.then is never called if nobody observes the promise, and when observed it runs synchronously inside .then()/await instead of as a microtask.

- **repro**：P1: `const t={then(res){log.push('thenable.then called');res(1);}}; new Promise(r=>r(t)); Promise.resolve().then(...).then(...)` -> zjs: `tick1 | tick2` (then NEVER called); qjs: `thenable.then called | tick1 | tick2`. P8: attaching p.then() -> zjs: `before then | thenable.then | after then | v=1` (synchronous); qjs: `before then | after then | thenable.then | v=1` (microtask).
- zjs：`src/exec/promise_ops.zig:1390-1396 (lazy store), 1485-1496 (qjsSettlePendingThenableJobs)`
- qjs：`js_promise_resolve_function_call ~quickjs.c:53626 (JS_EnqueueJob) + js_promise_resolve_thenable_job ~quickjs.c:53484`
- 建议修法：Enqueue the thenable job into ctx.pending_promise_jobs at resolve time (same queue the reaction jobs use) and drop the lazy promiseReactionCallback path for thenables; drainPendingPromiseJobs already executes callable jobs.

### promise-async-jobs#1 — HIGH · behavior · 有界

Resolving with a NATIVE promise takes a non-faithful fast path: a settled promise's state is adopted directly (zero extra microtask ticks, instance/prototype `then` never read), and a pending promise's `then` is called synchronously — qjs always reads `then` once and enqueues a thenable job (2 extra ticks).

- **repro**：P2: `new Promise(r=>r(Promise.resolve('X'))).then(...)` vs 3 chained ticks -> zjs: `adopted:X | t1 | t2 | t3`; qjs: `t1 | t2 | adopted:X | t3`. P3 (patched instance then): zjs: `value:X` (patch skipped); qjs: `patched then called | value:PATCHED`. P15 (`async function f(){ return Promise.resolve('R') }`): zjs `async:R | t1 | ...`; qjs `t1 | t2 | async:R | ...`.
- zjs：`src/exec/promise_ops.zig:1341-1378 (qjsPromiseResolvingFunctionCall promise special case)`
- qjs：`js_promise_resolve_function_call ~quickjs.c:53600-53630 (uniform GetProperty(then) + EnqueueJob for all objects)`
- 建议修法：Delete the class_id==promise special case in qjsPromiseResolvingFunctionCall; treat every object resolution uniformly (read then once; if callable enqueue the thenable job) — depends on fixing the thenable-job queueing (previous finding).

### promise-async-jobs#2 — HIGH · behavior · 有界

The default/intrinsic Promise constructor is resolved by reading the mutable globalThis.Promise binding: deleting or replacing globalThis.Promise breaks `await` (async fn rejects TypeError) and makes then()'s default-species path construct the replacement; qjs uses the cached intrinsic ctx->promise_ctor.

- **repro**：P33: `const p=Promise.resolve(1); delete globalThis.Promise; (async()=>{print('await ok:'+await p)})().then(()=>print('done'),e=>print('async rejected: '+e));` -> zjs: `async rejected: TypeError`; qjs: `await ok:1 / done`. P5b: p.constructor=undefined + globalThis.Promise=FakePromise; p.then() -> zjs prints `FAKE CONSTRUCTOR CALLED`; qjs does not.
- zjs：`src/exec/promise_ops.zig:2099-2103 (qjsPromiseDefaultConstructor), 2105-2128 (qjsPromiseSpeciesConstructor default)`
- qjs：`js_async_function_resume ~quickjs.c:21268 (ctx->promise_ctor) and js_new_promise_capability ~quickjs.c:53745 (JS_IsUndefined(ctor) -> js_promise_constructor)`
- 建议修法：Store the intrinsic Promise constructor in a realm slot at install time (a cachedPromiseProto-style slot already exists for the prototype, promise_ops.zig:108-118) and use it for qjsPromiseDefaultConstructor/species default instead of a global property read.

### promise-async-jobs#3 — HIGH · behavior · 深前沿

Async-generator and module top-level `await` never actually suspend: zjs drains the whole pending-job queue synchronously inside next()/the module body, and an await of a never-settling promise resumes with undefined instead of staying suspended.

- **repro**：P21: `async function* g(){ log.push('start'); await new Promise(()=>{}); log.push('RESUMED-UNEXPECTEDLY'); yield 1; } g().next().then(...)` -> zjs: `start | RESUMED-UNEXPECTEDLY | sync end | next done`; qjs: `start | sync end`. P22 (pending promise resolved by a later microtask): zjs runs `gen start | t1 resolving | t2 | gen resumed:V` all synchronously INSIDE it.next() before `sync end`; qjs: `gen start | sync end | t1 resolving | gen resumed:V | t2 | next:1`. P23 (module TLA, /tmp/p23_tla.mjs): zjs `before await | t1 | t2 | after await` vs qjs `before await | t1 | after await | t2`.
- zjs：`src/exec/vm_gen_async.zig:437-476 (awaitValueRaw modes .drain/.settled), src/exec/promise_ops.zig:3751 (drainPendingPromiseJobs)`
- qjs：`js_async_generator_await ~quickjs.c:21447 and js_async_function_resume ~quickjs.c:21238 (perform_promise_then + JS_CLASS_ASYNC_GENERATOR queue; no synchronous drain)`
- 建议修法：Route async-generator and module-TLA awaits through the same suspend-and-resume-callback path already used for async functions (mode .raw + qjsAsyncFunctionAwait-style resume), mirroring qjs js_async_generator_await request-queue machinery; never call drainPendingPromiseJobs or fall through with undefined from inside an await.

### promise-async-jobs#4 — MEDIUM · behavior · 有界

`await` of a native promise reads and calls the `then` property (Promise.prototype.then patch is observed/invoked); qjs awaits via internal perform_promise_then and never touches `.then`.

- **repro**：P4: define getter on Promise.prototype.then that logs, then `await Promise.resolve(42)` -> zjs: `then getter | awaited:42`; qjs: `awaited:42`.
- zjs：`src/exec/promise_ops.zig:2928-2954 (qjsAsyncFunctionAwait)`
- qjs：`js_async_function_resume ~quickjs.c:21268-21290 (js_promise_resolve + perform_promise_then)`
- 建议修法：Replace the getValueProperty(then)+call in qjsAsyncFunctionAwait (and qjsAsyncDisposableStackAwaitValue promise_ops.zig:604-610, same pattern) with the internal qjsPerformPromiseThen, mirroring qjs.

### promise-async-jobs#5 — MEDIUM · behavior · 有界

Unhandled-rejection tracking is a single per-context slot matched by sameValue(reason): only the LAST unhandled rejection is reported, and handling one promise suppresses the report of a different promise rejected with the same reason object (process exit code also flips 1->0).

- **repro**：P6: `Promise.reject(new Error('boom1')); Promise.reject(new Error('boom2'))` -> zjs reports only boom2; qjs reports boom1 AND boom2. P26: `const r=new Error('shared'); const a=Promise.reject(r); const b=Promise.reject(r); a.catch(()=>0)` -> zjs: no report, exit 0; qjs: reports b, exit 1.
- zjs：`src/core/context.zig:418-419,750; src/core/promise.zig:166-191 (markHandled); src/exec/promise_ops.zig:1243-1245`
- qjs：`fulfill_or_reject_promise ~quickjs.c:53445 + perform_promise_then ~quickjs.c:54225 (host_promise_rejection_tracker, s->is_handled)`
- 建议修法：Track handled-ness per promise (flag on the promise object, matching qjs is_handled) and keep a list (or tracker callback) of unhandled rejections instead of one slot + reason sameValue matching.

### promise-async-jobs#6 — MEDIUM · structural · 深前沿

Job/reaction plumbing diverges wholesale from qjs: per-context pending_promise_jobs array (sequence-merged with finalization jobs) that can contain promise OBJECTS settled lazily via settlePendingPromiseReaction, plus a single flat reactions list per promise with a rejected flag per job — qjs has one runtime job_list (JS_EnqueueJob) holding closed argument records and two per-promise reaction lists.

- zjs：`src/exec/promise_ops.zig:859,1062-1096,3751-3817; src/core/jobs.zig (parallel Queue)`
- qjs：`JS_EnqueueJob ~quickjs.c:2287, fulfill_or_reject_promise ~quickjs.c:53436, perform_promise_then ~quickjs.c:54192`
- 建议修法：Converge on one runtime-level job queue holding (func,argv) records mirroring JS_EnqueueJob; make reaction settlement enqueue promise_reaction_job-equivalents directly and retire the promise-as-pending-job / promiseReactionCallback representations (this is the enabler for the thenable-job and adoption findings).

### promise-async-jobs#7 — LOW · zjs_extra · 有界

zjs exposes non-standard `Promise.allKeyed` and `Promise.allSettledKeyed` statics on the Promise constructor; neither qjs nor the spec has them.

- zjs：`src/exec/promise_ops.zig:2055-2067, 2351-2501; install path via builtins registry`
- qjs：`js_promise_funcs table ~quickjs.c:54364-54374 (no keyed variants)`
- 建议修法：Remove the keyed combinators from the public Promise surface (or gate behind a host-only flag) for faithful alignment.

### promise-async-jobs#8 — LOW · behavior · 有界

Promise self-resolution rejects with an empty-message TypeError; qjs uses message "promise self resolution".

- **repro**：P7: `let r; const p=new Promise(res=>r=res); r(p); p.catch(e=>print(e.name+': ['+e.message+']'))` -> zjs: `TypeError: []`; qjs: `TypeError: [promise self resolution]`.
- zjs：`src/exec/promise_ops.zig:1332-1340`
- qjs：`js_promise_resolve_function_call ~quickjs.c:53608`
- 建议修法：Pass "promise self resolution" as the error message.

---

## 生成器 / 迭代器  `[generators-iterators]`

> 覆盖说明：Compared zjs HEAD 541c30f (src/exec/vm_gen_async.zig, src/exec/iterator_ops.zig, src/exec/call_runtime.zig qjsGenerator*, src/builtins/iterator.zig, src/exec/object_ops.zig createGeneratorObject) against quickjs 04be246 (js_generator_*, js_async_generator_*, JS_IteratorNext/2/Close, js_for_in_*, js_append_enumerate, js_iterator_proto_*/helpers) with ~20 differential probe scripts run on both binaries. CONFIRMED ALIGNED (no findings): sync-generator state machine on throw/return-before-start, completed-state next/return/throw, running-generator TypeError (type only), parameter-default evaluatio

### generators-iterators#0 — HIGH · behavior · 有界

Async generator yield does not await its operand: yielding a promise delivers the Promise object as result.value, and a rejected yielded promise rejects the next() promise instead of being thrown into the generator body.

- **repro**：/tmp/probe_ag5.js: async function* ag(){ yield Promise.resolve('PV'); } → qjs 'yield-promise:PV,false', zjs 'yield-promise:[object Promise],false'. async function* ag2(){ try { yield Promise.reject('RJ'); } catch(e){ order.push('caught-in-body:'+e); yield 'after'; } } → qjs 'caught-in-body:RJ ... n1:after', zjs 'n1-rej:RJ' (body never resumed with throw).
- zjs：`src/exec/call_runtime.zig:5437-5460`
- qjs：`js_async_generator_resume_next FUNC_RET_YIELD case quickjs.c:21640-21650 → js_async_generator_await 21446`
- 建议修法：In the async-generator resume loop, await the yielded value (spec AsyncGeneratorYield step: Await(value)) before resolving the request's promise, delivering rejections back into the body as a throw completion.

### generators-iterators#1 — HIGH · behavior · 有界

gen.return(v) that suspends inside a finally-block yield loses the pending return completion: the following next() throws undefined instead of completing with {value:v,done:true} (sync crash; async variant also corrupt).

- **repro**：/tmp/probe_crash1.js: function* gf(){ try { yield 1; } finally { yield 'F'; } } it.next(); it.return(9); it.next(). qjs: '3: {"value":9,"done":true}' then '{done:true}'. zjs: uncaught 'zjs: evaluation failed: JSException' (caught form shows 'threw: undefined'). Async variant /tmp/probe_more.js: qjs 'n1:1,false|ret:F,false|n2:9,true' vs zjs 'n1:1,false|ret:[object Promise],false|n2-rej:undefined'.
- zjs：`src/exec/call_runtime.zig:5663-5700 (+ findGeneratorReturnFinallyTarget :6007)`
- qjs：`js_generator_next quickjs.c:21077 GEN_MAGIC_RETURN path: sf->cur_sp[-1]=ret; sf->cur_sp[0]=JS_NewInt32(ctx,magic) — completion value+magic live on the generator's own saved stack so compiled bytecode threads return-through-finally natively`
- 建议修法：Store the pending return completion (value + type) on the generator object when a finally-range run suspends, and have qjsGeneratorNext/throw consult it on resume — or better, adopt qjs's push-(value,magic)-onto-generator-stack protocol (see structural finding).

### generators-iterators#2 — HIGH · behavior · 有界

Async generator .return(v) semantics broken even in ordinary cases: the argument is not awaited when it is a promise (spec/qjs await it) and when suspended at a yield the delivered result.value is a wrong Promise object instead of the argument.

- **repro**：/tmp/probe_ag2.js: ag().return(Promise.resolve(7)) at suspendedStart → qjs 'ret-start:7,true', zjs 'ret-start:[object Promise],true'. Suspended-at-yield: it.return('RV') → qjs 'ret:RV,true' (finally runs in queue order: body|...|n1:1|fin|ret:RV), zjs 'ret:[object Promise],true' with 'fin' run eagerly right after 'body'.
- zjs：`src/exec/call_runtime.zig:5624 (qjsGeneratorReturn)`
- qjs：`js_async_generator_completed_return quickjs.c:21530 (resolves the arg via JS_PromiseResolve + reaction) and GEN_MAGIC_RETURN handling in js_async_generator_resume_next 21596`
- 建议修法：Part of the AsyncGeneratorRequest queue port: return requests must await their argument (completed_return) and resolve the request promise with the unwrapped value.

### generators-iterators#3 — HIGH · behavior · 有界

new f(...spread) inside a try block fails to compile in zjs with 'SyntaxError: ... StackMismatch' — valid JS that qjs runs fine.

- **repro**：/tmp/t4.js: function f(){} try { new f(...[1,2]); print('A ok'); } catch(e){ print('A caught'); } → qjs 'A ok'; zjs 'SyntaxError: SYNTAX ERROR in /tmp/t4.js:2:1 - StackMismatch'. Same construct outside try (t5/t6) and plain-call spread inside try (t8) compile fine.
- zjs：`src/bytecode.zig:5844 (verifier); root cause in the new-with-spread codegen path`
- qjs：`js_parse_postfix_expr construct-with-spread path (OP_apply with magic/OP_array_from) in quickjs.c — compiles and runs`
- 建议修法：Fix the stack-effect accounting of the construct-with-spread emission (its net depth vs the catch-offset bookkeeping) so the verifier passes; add a compile test for new-in-try with spread.

### generators-iterators#4 — HIGH · behavior · 有界

for-in's deleted-key recheck walks the prototype chain / fires the proxy 'has' trap instead of qjs's own-property (getOwnPropertyDescriptor) check on the current chain object, so proxies with virtual keys enumerate nothing and deleted own props shadowed by proto props are still yielded.

- **repro**：(a) /tmp/probe_forin3.js: new Proxy({}, {ownKeys:()=>['a'], getOwnPropertyDescriptor:()=>({value:1,enumerable:true,configurable:true})}) — for-in: qjs '[a]', zjs '[]'. (b) /tmp/probe_forin5.js trap trace: qjs 'ownKeys,gopd:a,gopd:a' vs zjs 'ownKeys,gopd:a,has:a'. (c) /tmp/probe_forin4.js: proto={a:'p',z:'pz'}; o=Object.create(proto); o.b=1; o.a='own'; delete o.a during loop → qjs 'b,z', zjs 'b,a,z'.
- zjs：`src/exec/iterator_ops.zig:886-889 (forInNext) and :929, :961 (simpleForInNext paths)`
- qjs：`js_for_in_next quickjs.c:16480-16495 ('check if the property was deleted' JS_GetOwnPropertyInternal)`
- 建议修法：Replace hasValueProperty in the for-in recheck with an own-property lookup on the current enumeration object (proxy gopd trap for proxies), mirroring JS_GetOwnPropertyInternal.

### generators-iterators#5 — HIGH · behavior · 深前沿

Async generators execute their bodies eagerly/synchronously at next() time instead of via qjs's AsyncGeneratorRequest queue, so side-effect order diverges and reentrant next() rejects with TypeError instead of being queued.

- **repro**：/tmp/probe_ag6.js: var it; async function* ag(){ it.next().then(r=>order.push('inner:'+r.value), e=>order.push('inner-rej')); yield 1; yield 2; } it=ag(); it.next().then(...). qjs: 'outer:1|inner:2,false'. zjs: 'outer-rej:TypeError'. Also /tmp/probe_ag1.js: qjs 'start|mid|r1:1,false|end|r2...' vs zjs 'start|mid|end|r1|r2...' (body runs to completion before any reaction); /tmp/probe_ag3.js: zjs 's|got:A|resumed|sync-after-calls' vs qjs 's|sync-after-calls|got:A|resumed' (both yields executed synchronously inside the next() calls).
- zjs：`src/exec/vm_gen_async.zig:22-32, src/exec/call_runtime.zig:5393`
- qjs：`js_async_generator_next quickjs.c:21706 (enqueues JSAsyncGeneratorRequest, then js_async_generator_resume_next) + js_async_generator_resume_next quickjs.c:21568`
- 建议修法：Port the js_async_generator_* machinery: per-generator FIFO of (magic, arg, promise capability), resume driven from job queue via js_async_generator_resume_next/js_async_generator_resolve_function; remove the drain mode.

### generators-iterators#6 — HIGH · behavior · 深前沿

await inside an async generator on a promise that is not yet resolved resumes the body with undefined (silently wrong value) instead of suspending until resolution.

- **repro**：/tmp/probe_ag4.js: var resolveFn; var p=new Promise(r=>resolveFn=r); async function* ag(){ var v=await p; yield 'got:'+v; } ag().next().then(r=>print('r:'+r.value)); resolveFn('X'). qjs: 'r:got:X'. zjs: 'r:got:undefined'. (Plain async functions are correct: /tmp/probe_af.js identical on both.)
- zjs：`src/exec/vm_gen_async.zig:465-467 (awaitValueRaw)`
- qjs：`js_async_generator_await quickjs.c:21446 (performs a real promise-reaction suspension; resume only when settled)`
- 建议修法：Same queue rework as the eager-drain finding: async-generator awaits must suspend into a promise reaction (js_async_generator_await) instead of drain-then-proceed-with-undefined.

### generators-iterators#7 — MEDIUM · structural · 有界

zjs's for-in iterator is an ordinary object holding an up-front full snapshot (own+prototype keys as numeric properties plus __index/__source string props) versus qjs's dedicated JS_CLASS_FOR_IN_ITERATOR opaque struct with lazy prototype-chain walking and visited-key dedup.

- zjs：`src/exec/iterator_ops.zig:846-897, src/exec/forof_ops.zig:29-180`
- qjs：`build_for_in_iterator + js_for_in_next quickjs.c:16404, js_for_in_prepare_prototype_chain_enum:16341`
- 建议修法：Mirror JSForInIterator: dedicated class with opaque {obj, tab_atom, idx, in_prototype_chain} state, lazy proto-chain enumeration and enum-obj visited dedup; fixes the recheck semantics for free.

### generators-iterators#8 — MEDIUM · structural · 深前沿

zjs implements generator return/throw completions by scanning bytecode for finally ranges and via out-of-band object slots (+ fragile 'yield;if_false' byte-pattern sniffing on resume) instead of qjs's protocol of pushing (value, magic) onto the generator's saved stack and letting compiled bytecode handle completions.

- zjs：`src/exec/call_runtime.zig:6007, src/exec/vm_gen_async.zig:137-152`
- qjs：`js_generator_next quickjs.c:21077-21155 + async_func_resume protocol`
- 建议修法：Adopt the qjs completion protocol: compile yield to leave a (value, magic) consumption site in bytecode and have next/return/throw push onto the saved generator stack, retiring findGeneratorReturnFinallyTarget and the resume-pattern sniffing.

### generators-iterators#9 — LOW · behavior · 有界

When an iterator's next() throws during array spread [...it] or call spread f(...it), qjs closes the iterator (calls .return with exception pending) but zjs does not.

- **repro**：/tmp/probe_spread3.js: iterator whose next() throws on 2nd call and logs return() calls. qjs: 'return-called|arr:boom|return-called|call:boom|rest:boom'; zjs: 'arr:boom|call:boom|rest:boom'. (Rest destructuring agrees: neither closes.)
- zjs：`src/exec/call_runtime.zig:2806 (appendSpreadValuesEnumerate)`
- qjs：`js_append_enumerate quickjs.c:16814, exception close at :16891`
- 建议修法：If strict qjs parity is wanted, call the iterator-close-with-pending-exception helper on the error path of appendSpreadValuesEnumerate; otherwise document as intentional spec-over-qjs divergence.

### generators-iterators#10 — LOW · zjs_extra · 有界

zjs ships Iterator.zip and Iterator.zipKeyed statics that this qjs does not have (qjs Iterator statics are only concat/from).

- zjs：`src/builtins/iterator.zig:23-24, 70-71`
- qjs：`js_iterator_funcs quickjs.c:44720`
- 建议修法：Remove (or gate behind a non-default flag) Iterator.zip/zipKeyed to match the qjs surface, or record as an accepted extra in the divergence catalog.

### generators-iterators#11 — LOW · behavior · 有界

Generator/iterator internal TypeErrors carry empty messages where qjs has descriptive ones ('cannot invoke a running generator', 'iterator does not have a throw method', helper 'not a function').

- **repro**：/tmp/probe_gen1.js reentrant next: qjs 'TypeError: cannot invoke a running generator' vs zjs 'TypeError: '; /tmp/probe_ystar.js A: qjs 'TypeError: iterator does not have a throw method' vs zjs bare TypeError; /tmp/probe_msg.js [1].values().map(1).next(): qjs '[not a function]' vs zjs '[]'. zjs does produce messages elsewhere ('cannot read property x of null' matches), so this is specific to these throw sites.
- zjs：`src/exec/call_runtime.zig:5393 and iterator-helper dispatch (src/builtins/iterator.zig:104)`
- qjs：`js_generator_next quickjs.c:21091/21152 and yield* OP_get_field2-throw path JS_ThrowTypeError strings`
- 建议修法：Attach the qjs message strings at these specific throw sites (throwTypeError with message instead of bare error.TypeError).

### generators-iterators#12 — LOW · behavior · 有界

flatMap helper .return(): zjs closes the active inner iterator once then the outer; qjs calls inner.return twice before outer.return (observable trap-call count).

- **repro**：/tmp/probe_misc.js: fm=Iterator.prototype.flatMap.call(outerIt,x=>x); fm.next(); fm.return() → zjs 'inner-return,outer-return', qjs 'inner-return,inner-return,outer-return'.
- zjs：`src/exec/iterator_ops.zig (flatMap helper close path)`
- qjs：`js_iterator_helper_next quickjs.c:44463 (FLAT_MAP + GEN_MAGIC_RETURN path)`
- 建议修法：Probably keep zjs behavior and catalog as intentional; if byte-faithfulness is demanded, replicate qjs's double inner close.

---

## class / 构造  `[class-construct]`

> 覆盖说明：Compared zjs HEAD 541c30f vs quickjs 04be246 with ~95 differential probes across 16 scripts (/tmp/clsaudit/p1-p16), plus code reading of src/exec/{class_init_ops,construct,vm_property_private,vm_literal,call_runtime}.zig, src/core/class.zig, src/builtins/json.zig, src/parser.zig against quickjs.c js_op_define_class(17426)/JS_CallConstructorInternal(20809)/js_create_from_ctor(20783)/JS_DefinePrivateField(8374)/JS_AddBrand(8464)/JS_CheckBrand(8515)/OP_define_field(19269). CONFIRMED CLEAN (identical output both engines): brand checks incl. wrong receivers/static/subclass/proxy; #x in (instances, 

### class-construct#0 — HIGH · behavior · 有界

When the extends clause is an inline class expression, ALL instance field initializers (public and private) are silently dropped — fields are never defined and initializers never run.

- **repro**：class A extends class {} { x = 5; #p = 3; static rd(o){return o.#p} }
const o = new A(); print(o.x); print(A.rd(o));
— zjs: undefined, then TypeError "private class field '#p' does not exist"; qjs: 5, then 3. Also: class IH2 extends class extends class {} { z = 1; } { w = 2; } → zjs both z,w undefined; qjs "1,2". Explicit ctor with super() same. NOT triggered when heritage is a named binding, a call result, or a function expression (all probed clean); static fields/blocks, methods, brand install, and base-ctor body still work.
- zjs：`src/parser.zig:18750-18760 (parseClass heritage ordering) + src/parser.zig:14769 (by-name findVar of <class_fields_init>)`
- qjs：`js_parse_class / js_op_define_class (quickjs.c:17426); qjs keeps the fields-init closure per class nesting level so `class X extends class {} { fields }` works`
- 建议修法：Disambiguate the <class_fields_init> capture per class parse (e.g. record the var index chosen at :18751-18754 in the parse state and use it directly at :14769 instead of by-name findVar, or scope the heritage parse so the inner class's var cannot shadow the outer's).

### class-construct#1 — HIGH · behavior · 有界

super property access inside STATIC field initializers is rejected with SyntaxError at parse time; qjs evaluates it (home object = constructor).

- **repro**：class A { static sm(){return 2} } class B extends A { static sx = super.sm(); }
— zjs: SyntaxError "invalid syntax" (whole script fails to parse); qjs: B.sx === 2. All forms fail in zjs: super.sm (reference), super['sm'](), super getter, super inside an arrow in the initializer, computed static field (static ['sx'] = super.sm()), and even without extends (class B { static sx = super.toString; }). Instance field initializers with super work (x = super.m() → ok), and static BLOCKS with super work.
- zjs：`src/parser.zig:17899 emitStaticPublicFieldInitializer (+ computed variant ~:18340); deferred static code path rejects super`
- qjs：`js_parse_class static field init: fd->super_allowed = TRUE for field initializer functions (check site quickjs.c:27039 `if (!s->cur_func->super_allowed)`); static initializers compile as normal functions with home_object = ctor`
- 建议修法：Allow get_super emission in the static-field deferred-code context (home object = the constructor, same as static blocks, which already work).

### class-construct#2 — HIGH · behavior · 有界

Defining a public class field on a non-extensible object with zero own properties silently succeeds; qjs (and spec CreateDataPropertyOrThrow) throw TypeError.

- **repro**：class A { constructor(){ Object.preventExtensions(this); } } class B extends A { x = 1; }
print(new B().x)
— zjs: prints 1 (field defined on non-extensible object); qjs: TypeError "object is not extensible". Same with Object.freeze and with a base ctor returning a frozen {} via return-override. If the frozen object already HAS properties (Object.freeze({a:1})), both engines throw — proving only the 0-prop fast path is broken.
- zjs：`src/exec/vm_literal.zig:184-196 and :237-245`
- qjs：`CASE(OP_define_field) quickjs.c:19269 → JS_DefinePropertyValue with JS_PROP_THROW (extensibility enforced in JS_CreateProperty)`
- 建议修法：Add `target.flags.extensible` to both fast-path predicates in defineField (falls through to createDataPropertyOrThrow which already throws).

### class-construct#3 — HIGH · behavior · 有界

JSON.stringify leaks private fields into output for plain class instances (JSON simple-object fast path does not filter private atoms).

- **repro**：class J { #a = 1; b = 2; } print(JSON.stringify(new J()))
— zjs: {"#a":1,"b":2}; qjs: {"b":2}.
- zjs：`src/builtins/json.zig:1888`
- qjs：`js_json_stringify / internal_json uses JS_GetOwnPropertyNames(JS_GPN_STRING_MASK|JS_GPN_ENUM_ONLY) which never returns JS_ATOM_TYPE_PRIVATE atoms`
- 建议修法：Add `if (rt.atoms.kind(prop.atom_id) == .private) continue;` next to the public-symbol filter in qjsJsonAppendSimpleObject (and audit qjsJsonAppendSimpleArray's shapeProps scan for the same hole).

### class-construct#4 — MEDIUM · structural · 深前沿

Private-method/brand machinery: zjs copies every private-named property from the constructor's home object onto each instance at construction, instead of qjs's single private-brand symbol property + closure-resolved methods.

- zjs：`src/exec/class_init_ops.zig:270-282`
- qjs：`JS_AddBrand quickjs.c:8464 / JS_CheckBrand quickjs.c:8515 / CASE(OP_add_brand) quickjs.c:18320`
- 建议修法：Mirror qjs: install one private brand property per (home_object, instance) pair and resolve private methods through closure bindings; brand-check with the home object's brand symbol.

### class-construct#5 — LOW · behavior · 有界

Error message shape: class-machinery errors in zjs carry empty or generic messages where qjs has specific diagnostic text (error TYPES all match).

- **repro**：Examples (zjs vs qjs, same error type): derived ctor returns primitive → "TypeError: " vs "derived class constructor must return an object or undefined"; double super() → "ReferenceError: not defined" vs "'this' can be initialized only once"; this-before-super → "not defined" vs "this is not initialized"; write to read-only private accessor → "TypeError: " vs "'#g' is read-only"; new (extends-null class) → "TypeError: " vs " is not a constructor"; brand failure → "private class field '#m' does not exist" vs "invalid brand on object"; duplicate field stamp → "TypeError: " vs "private class fiel
- zjs：`src/exec/class_init_ops.zig:87 et al. (bare `error.TypeError` returns across class paths)`
- qjs：`JS_ThrowTypeError sites in quickjs.c: 8395 ('already exists'), 8497 ('private method is already present'), 8531 ('expecting <brand> private field'), plus OP_ret/this-init ReferenceError texts in JS_CallInternal`
- 建议修法：Where class paths throw, attach qjs's message strings (ctx-thrown exceptions) instead of bare error codes; prioritize the private-field/brand and derived-ctor messages which are user-visible in try/catch.

---

## Proxy / Reflect  `[proxy-reflect]`

> 覆盖说明：Compared zjs HEAD 541c30f (src/builtins/reflect_proxy.zig, src/exec/reflect_ops.zig, src/exec/object_ops.zig proxy core at lines ~1900-2200/3200-3600/4000-4200/4850-5510, src/exec/iterator_ops.zig forInNext, src/exec/forof_ops.zig createForInIterator, src/exec/call.zig nativeFunctionSourceValue/objectIsSealed, src/builtins/object.zig qjsObjectTestIntegrityCall, src/core/array.zig isArrayValue) against quickjs 04be246 js_proxy_* (50580-51560), js_for_in_* (16268-16500), js_object_isSealed, js_function_toString, get_proxy_method, JS_GetFunctionRealm proxy branch. ~120 behavioral probes run on bo

### proxy-reflect#0 — HIGH · behavior · 有界

for-in's per-iteration 'property still exists' re-check uses [[HasProperty]] (proto-walking, fires the has trap) instead of qjs's own-only [[GetOwnProperty]] (gopd trap), changing which keys are enumerated for proxies

- **repro**：var p=new Proxy({},{ownKeys(){return ['z','a']},getOwnPropertyDescriptor(){return {value:1,configurable:true,enumerable:true}}}); var o=[]; for(var k in p)o.push(k); print(o.join(',')); // zjs: '' ; qjs: 'z,a'.  Also: var proto={b:99},t=Object.create(proto);t.a=1;t.b=2; var q=new Proxy(t,{});var o2=[];for(var k2 in q){o2.push(k2);delete t.b;} // zjs: a|b ; qjs: a (same divergence for plain objects)
- zjs：`src/exec/iterator_ops.zig:890 (also 932, 963)`
- qjs：`js_for_in_next, quickjs.c ~16483 ('check if the property was deleted' JS_GetOwnPropertyInternal)`
- 建议修法：Replace the hasValueProperty existence re-check in forInNext/simpleForInNext/simpleForInNextAtomKeys with an own-only proxy-aware descriptor-existence check (proxyAwareExistsOwnProperty / proxyAwareOwnPropertyDescriptor != null), mirroring JS_GetOwnPropertyInternal(ctx, NULL, ...)

### proxy-reflect#1 — MEDIUM · behavior · 有界

Proxy invariant validation for has/deleteProperty/ownKeys reads target state with raw ordinary lookups, so when the target is itself a proxy the inner proxy's gopd/isExtensible traps never fire and inner invariant violations are silently missed (and defineProperty validation fires an extra isExtensible trap qjs doesn't)

- **repro**：var inner=new Proxy({},{ownKeys(){return ['ghost']},getOwnPropertyDescriptor(t,k){return k==='ghost'?{value:1,configurable:false}:undefined}}); var outer=new Proxy(inner,{ownKeys(){return []}}); Object.getOwnPropertyNames(outer); // zjs: [] (no throw) ; qjs: TypeError: proxy: inconsistent getOwnPropertyDescriptor
- zjs：`src/exec/object_ops.zig:5495 (validateProxyHasResult), 4147 (deleteValueProperty), 4945 (validateProxyOwnKeysResult)`
- qjs：`js_proxy_has quickjs.c ~50765 / js_proxy_delete_property ~51157 / js_proxy_get_own_property_names ~51219 / js_proxy_define_own_property ~51060`
- 建议修法：In the three validators, route target reads through proxyAwareOwnPropertyDescriptor / proxyAwareIsExtensible (matching JS_GetOwnPropertyInternal/JS_IsExtensible); in proxyDefineOwnProperty validation switch the extensibility read to the raw target flag to mirror qjs's p->extensible

### proxy-reflect#2 — MEDIUM · behavior · 有界

zjs snapshots the entire prototype chain eagerly at for-in iterator creation, vs qjs's lazy per-object walk (own snapshot + lazy proto enumeration), so prototype-chain mutations mid-iteration are invisible in zjs and proxy-proto trap call counts/order differ

- **repro**：var proto={p1:1}; var obj=Object.create(proto); obj.a=1; var out=[]; for(var k in obj){out.push(k); if(k==='a')proto.p2=2;} print(out.join('|')); // zjs: a|p1 ; qjs: a|p1|p2
- zjs：`src/exec/forof_ops.zig:29-111 (createForInIterator eager chain walk)`
- qjs：`build_for_in_iterator quickjs.c ~16268 / js_for_in_prepare_prototype_chain_enum ~16341 / js_for_in_next ~16404`
- 建议修法：Port qjs's three-function for-in model: own-keys-only snapshot at start, lazy prototype advance in forInNext with a visited-keys record on the iterator object (fixes this and complements finding 1)

### proxy-reflect#3 — LOW · zjs_extra · 有界

zjs's Proxy.revocable validates its receiver (must be a callable whose constructor name equals "Proxy"), so detached calls (const {revocable}=Proxy; revocable(t,h)) throw TypeError; qjs's js_proxy_revocable ignores this_val entirely

- **repro**：var r = Proxy.revocable; var o = r({}, {}); print(typeof o.proxy); // zjs: TypeError ; qjs: 'object'. Also Proxy.revocable.call(null,{},{}) and .call(Math,{},{}) throw in zjs, work in qjs
- zjs：`src/builtins/reflect_proxy.zig:94-97`
- qjs：`js_proxy_revocable, quickjs.c ~51502`
- 建议修法：Delete the receiver/this checks in the proxy_revocable branch of reflectCall; call reflect_ops.proxyRevocable unconditionally like qjs

### proxy-reflect#4 — LOW · behavior · 有界

Every proxy-related TypeError raised from the object-protocol trap core and Reflect arg validation carries an empty message, vs qjs's specific messages ('revoked proxy', 'proxy: inconsistent get/set/has/deleteProperty/getOwnPropertyDescriptor/defineProperty/prototype/isExtensible/preventExtensions', 'proxy: duplicate property', 'proxy: properties must be strings or symbols', 'not an object', 'not a constructor', 'could not delete property')

- **repro**：var {proxy:p,revoke}=Proxy.revocable({a:1},{}); revoke(); try{p.a}catch(e){print(JSON.stringify(e.message))} // zjs: "" ; qjs: "revoked proxy"
- zjs：`src/exec/object_ops.zig:4027, 4148, 4945-4960 etc. (bare error.TypeError); working pattern at object_ops.zig:5203`
- qjs：`JS_ThrowTypeErrorRevokedProxy + JS_ThrowTypeError sites in js_proxy_* (quickjs.c 50580-51530) and js_reflect_* `
- 建议修法：Mechanically replace bare `return error.TypeError` at the proxy trap/invariant/Reflect-validation sites with throwTypeErrorMessage(ctx, global, <qjs message>) matching quickjs.c strings; ~30 sites, all in object_ops.zig/reflect_ops.zig

### proxy-reflect#5 — LOW · behavior · 有界

An ownKeys trap that revokes its own proxy mid-trap succeeds in zjs but throws TypeError 'revoked proxy' in qjs, which re-checks is_revoked after the trap call before/inside the target invariant walk

- **repro**：var rv=Proxy.revocable({a:1},{ownKeys(t){rv.revoke(); return ['a'];}}); Object.getOwnPropertyNames(rv.proxy); // zjs: ['a'] OK ; qjs: TypeError: revoked proxy
- zjs：`src/exec/object_ops.zig:2139-2170 (objectRestOwnKeys proxy path)`
- qjs：`js_proxy_get_own_property_names, quickjs.c 51285/51293`
- 建议修法：After the trap call in objectRestOwnKeys, re-check source.proxyHandler() == null and throw the revoked TypeError before running validateProxyOwnKeysResult

### proxy-reflect#6 — LOW · behavior · 有界

Function.prototype.toString on a proxy-of-function omits the function name and fires no trap; qjs reads `name` via [[Get]] (fires the proxy get trap, observable) and emits 'function foo() { [native code] }'

- **repro**：var p=new Proxy(function foo(){},{get(t,k,r){print('get:'+String(k));return Reflect.get(t,k,r)}}); print(Function.prototype.toString.call(p)); // zjs: no trap, 'function() {...}' ; qjs: get:name, 'function foo() {...}'
- zjs：`src/exec/call.zig:2756 (nativeFunctionSourceValue)`
- qjs：`js_function_toString, quickjs.c (search 'js_function_toString')`
- 建议修法：In the no-source fallback, read the name property via the generic [[Get]] path (getValueProperty on the function object) instead of the internal name slot, mirroring JS_GetProperty(this_val, JS_ATOM_name)

### proxy-reflect#7 — LOW · behavior · 有界

ownKeys trap returning a non-object: zjs throws TypeError (spec CreateListFromArrayLike); qjs is lenient — reads .length off the primitive and returns an empty key list

- **repro**：Object.getOwnPropertyNames(new Proxy({},{ownKeys:()=>1})) // zjs: TypeError ; qjs: [] (no error)
- zjs：`src/exec/object_ops.zig:2151`
- qjs：`js_proxy_get_own_property_names, quickjs.c ~51247 (js_get_length32 on trap result)`
- 建议修法：Do not change behavior (spec/test262 side); record in DIVERGENCE-CATALOG as qjs spec-noncompliance zjs intentionally does not mirror

### proxy-reflect#8 — LOW · behavior · 有界

Object.isFrozen/isSealed on a proxy fire different trap sequences: zjs uses spec order (isExtensible trap first, short-circuits false before ownKeys); qjs checks properties first (ownKeys + gopd per key) and extensibility last, possibly never firing the isExtensible trap

- **repro**：var log=[];var p=new Proxy({a:1},{ownKeys(t){log.push('ownKeys');return Reflect.ownKeys(t)},getOwnPropertyDescriptor(t,k){log.push('gopd:'+k);return Reflect.getOwnPropertyDescriptor(t,k)},isExtensible(t){log.push('isExt');return Reflect.isExtensible(t)}}); Object.isFrozen(p); print(log.join(',')); // zjs: isExt ; qjs: ownKeys,gopd:a
- zjs：`src/builtins/object.zig:961 (qjsObjectTestIntegrityCall)`
- qjs：`js_object_isSealed, quickjs.c (search 'js_object_isSealed')`
- 建议修法：Either mirror qjs's props-first/extensible-last order in qjsObjectTestIntegrityCall (verify test262 stays green) or catalog as accepted spec-side divergence

### proxy-reflect#9 — LOW · behavior · 有界

Array.isArray on a proxy chain deeper than 1000 returns true in zjs but throws stack-overflow InternalError in qjs (explicit depth>1000 guard in the unwrap loop)

- **repro**：var v=[];for(var i=0;i<1200;i++)v=new Proxy(v,{});Array.isArray(v) // zjs: true ; qjs: InternalError: stack overflow
- zjs：`src/core/array.zig:64 (isArrayValue)`
- qjs：`js_proxy_isArray unwrap loop, quickjs.c ~51415-51436`
- 建议修法：Add the same depth>1000 guard (throwing the engine's stack-overflow error) to isArrayValue's proxy unwrap

### proxy-reflect#10 — LOW · behavior · 有界

Two qjs side-effect-order quirks zjs does not replicate: (a) Object.defineProperties/Object.create with a proxy props object — zjs interleaves gopd:a,get:a,gopd:b (spec order), qjs batches gopd:a,gopd:b then get:a; (b) spread/for-of over a proxy-of-array — qjs reads Symbol.iterator via [[Get]] twice, zjs once

- **repro**：var log=[];var props=new Proxy({},{ownKeys(){log.push('ownKeys');return ['a','b']},getOwnPropertyDescriptor(t,k){log.push('gopd:'+k);return {value:{value:k},enumerable:k==='a',configurable:true}},get(t,k){log.push('get:'+k);return {value:k}}}); Object.defineProperties({},props); print(log.join(',')); // zjs: ownKeys,gopd:a,get:a,gopd:b ; qjs: ownKeys,gopd:a,gopd:b,get:a
- zjs：`src/exec/object_ops.zig (defineProperties path via proxyAwareOwnPropertyDescriptor interleave); iterator setup in src/exec/forof_ops.zig`
- qjs：`js_object_defineProperties + JS_GetOwnPropertyNamesInternal(JS_GPN_ENUM_ONLY); JS_GetIterator/for-of setup for the double @@iterator get`
- 建议修法：Catalog as accepted spec-side divergence (recommended), or replicate qjs's two-pass ENUM_ONLY filtering and double @@iterator lookup if strict qjs fidelity is preferred over spec order

---

## JSON  `[json]`

> 覆盖说明：Compared zjs src/core/json.zig + src/builtins/json.zig (VM paths qjsJsonParseCall/qjsJsonStringifyCall used by CLI, plus embed fallbacks and the no-options fast path) against quickjs.c 04be246 js_json_parse/internalize_json_property/JSONParseRecord, js_json_to_str/js_json_check/JS_JSONStringify, js_json_rawJSON/isRawJSON, JS_ToQuotedString. All findings verified by running both binaries. Confirmed ALIGNED (probed, no divergence): toJSON lookup+call order incl. accessor toJSON and key argument, toJSON-before-replacer ordering, replacer holder/this and root wrapper {'':v}, reviver root holder {'

### json#0 — HIGH · behavior · 有界

JSON.stringify number serialization uses Zig std.fmt '{d}' full-decimal expansion into a 128-byte buffer instead of JS ToString (js_dtoa), producing wrong text for exponent-form numbers and an UNCATCHABLE engine abort (NoSpaceLeft) for numbers whose decimal expansion exceeds 128 chars.

- **repro**：print(JSON.stringify(1e21)); print(JSON.stringify(1e-7)); try{print(JSON.stringify(1e300))}catch(e){print('caught')}  => zjs: '1000000000000000000000' / '0.0000001' / hard abort 'zjs: evaluation failed: NoSpaceLeft' (try/catch does NOT catch; 5e-324 also aborts); qjs: '1e+21' / '1e-7' / '1e+300'
- zjs：`src/builtins/json.zig:2220 (also 1800, 262)`
- qjs：`js_json_to_str concat_primitive -> string_buffer_concat_value_free, quickjs.c ~50230-50240`
- 建议修法：Replace the three bufPrint '{d}' sites with the engine's number-to-string (same path String()/value_format uses, mirroring js_dtoa shortest form).

### json#1 — HIGH · behavior · 有界

Deeply nested JSON input segfaults JSON.parse (native stack overflow) where qjs throws a catchable SyntaxError via js_check_stack_overflow.

- **repro**：JSON.parse('['.repeat(100000)+']'.repeat(100000))  => zjs: SIGSEGV (exit 139); qjs: catchable SyntaxError
- zjs：`src/builtins/json.zig:397 (parseValue recursion), :151 (std.json fallback)`
- qjs：`json_parse_value (quickjs.c ~49484) / js_check_stack_overflow in parse path`
- 建议修法：Add a depth counter or stack-headroom check mirroring js_check_stack_overflow to the parse recursion, converting overflow to SyntaxError/InternalError.

### json#2 — HIGH · behavior · 有界

Deeply nested value graphs segfault JSON.stringify (and would the reviver walk) where qjs throws a catchable InternalError via js_check_stack_overflow at the top of js_json_to_str and internalize_json_property.

- **repro**：var a=[],c=a; for(var i=0;i<200000;i++){var n=[];c.push(n);c=n;} try{JSON.stringify(a)}catch(e){print(e.name)}  => zjs: SIGSEGV (exit 139); qjs: prints 'InternalError'
- zjs：`src/builtins/json.zig:2101, 2174, 1182`
- qjs：`js_json_to_str (quickjs.c ~50060) and internalize_json_property (~49709), js_check_stack_overflow guards`
- 建议修法：Mirror the stack-overflow guard (depth limit or stack probe) at the entry of qjsJsonSerializeProperty/qjsJsonAppendValue and qjsJsonInternalizeProperty, throwing InternalError.

### json#3 — HIGH · behavior · 有界

JSON.parse rejects lone surrogates in strings (both escaped '\ud800' and raw U+D800) with SyntaxError because the Zig std.json backend enforces valid Unicode, while qjs (WTF-16, json_parse_string) accepts them.

- **repro**：JSON.parse('"\\ud800"').charCodeAt(0)  => zjs: SyntaxError thrown; qjs: 55296. Same for JSON.parse('"\ud800"') (raw lone surrogate in input string). Escaped valid pairs ('😀') work in both.
- zjs：`src/builtins/json.zig:151 (std.json.parseFromSlice), :523 (escape rejection)`
- qjs：`json_parse_string (quickjs.c 23305)`
- 建议修法：Stop delegating string decoding to std.json: port json_parse_string's escape/unit handling (WTF-16 tolerant) — naturally falls out of porting json_parse_value (see structural finding).

### json#4 — MEDIUM · behavior · 有界

Multi-char non-ASCII gap strings make JSON.stringify throw URIError ('expecting hex digit') instead of indenting; gap truncation is 10 UTF-8 bytes instead of qjs's 10 UTF-16 chars (js_sub_string). **（复核修正 2026-07-02：原表述「Any non-ASCII gap」过宽——单字符 `'é'` gap 与 qjs 输出一致不抛；`'éé'`、`'日'.repeat(12)` 复现 URIError。偏离真实，触发条件为多字符非 ASCII gap。）**

- **repro**（复核后）：JSON.stringify([1],null,'éé') => zjs: URIError；qjs: 正常缩进（len 7）。JSON.stringify([1],null,'日'.repeat(12)) => zjs: URIError；qjs: 以 10 字符缩进（len 15）。单字符 'é' gap：两引擎一致（len 7，无偏离）。
- zjs：`src/builtins/json.zig:2088-2092 (and :892)`
- qjs：`JS_JSONStringify gap setup: js_sub_string(p,0,min_int(p->len,10)) (quickjs.c ~50345)`
- 建议修法：Keep the gap as a string value (or UTF-16 units) truncated to 10 code units like js_sub_string, and encode to UTF-8 properly when emitting indents.

### json#5 — MEDIUM · behavior · 有界

Lone-surrogate property KEYS are emitted raw into the output string instead of being escaped as \udXXX, because appendJsonAtomName passes atom name bytes through untouched instead of mirroring JS_ToQuotedString's is_surrogate escape.

- **repro**：var s=JSON.stringify({'\ud800':1}); print(s.length, [...s].map(c=>c.charCodeAt(0).toString(16)).join(' '))  => zjs: 7 '7b 22 d800 22 3a 31 7d' (raw unpaired surrogate in result); qjs: 12 '7b 22 5c 75 64 38 30 30 22 3a 31 7d' (\ud800 escape). String VALUES are escaped correctly in both (F2 aligned).
- zjs：`src/core/json.zig:59-67, 126`
- qjs：`JS_ToQuotedString (quickjs.c ~49933), used for prop in js_json_to_str JO loop`
- 建议修法：Route key emission through the same escape path as string values (decode atom name to code points; escape surrogates and controls like JS_ToQuotedString).

### json#6 — MEDIUM · behavior · 有界

JSON.rawJSON result object is left extensible (not frozen): zjs omits qjs's JS_PreventExtensions call after defining the rawJSON property.

- **repro**：var r=JSON.rawJSON('1'); print(Object.isExtensible(r), Object.isFrozen(r))  => zjs: 'true false'; qjs: 'false true' (prop descriptor and null proto match in both).
- zjs：`src/builtins/json.zig:190-204`
- qjs：`js_json_rawJSON (quickjs.c 49887), JS_PreventExtensions at ~49916`
- 建议修法：Call the engine's preventExtensions on the rawJSON object after defineData.

### json#7 — MEDIUM · behavior · 有界

JSON.rawJSON does not apply full ToString to its argument: a plain object with a toString method throws SyntaxError in zjs where qjs coerces and succeeds.

- **repro**：JSON.rawJSON({toString(){return '123'}})  => zjs: throws SyntaxError; qjs: returns rawJSON object, JSON.stringify({x:o}) === '{"x":123}'.
- zjs：`src/builtins/json.zig:174-180, 945-984 (appendJsonInputString)`
- qjs：`js_json_rawJSON (quickjs.c 49887-49895)`
- 建议修法：Use the VM ToString path (string_ops.toStringForAnnexB, as jsonParseRecordCall's global path already does) for the rawJSON argument.

### json#8 — MEDIUM · behavior · 有界

Reviver context.source reports wrong source text under mutation-during-walk and duplicate keys, because zjs uses a linear re-lexed source cursor with prefetch-time gating instead of qjs's per-node JSONParseRecord same-value gating.

- **repro**：(1) JSON.parse('[[1,2],[3,4]]',function(k,v,c){out.push(k+'='+JSON.stringify(v)+'/src='+(c&&'source' in c?c.source:'-')); if(k==='0'&&v&&v[0]===1){this[1].pop();this[1].push(5);} return v;})  => zjs reports '1=5/src=4' (source of the replaced value 4 attributed to 5); qjs reports '1=5/src=-' (no source). (2) JSON.parse('{"a":1,"a":2}',(k,v,c)=>...)  => zjs 'a=2/src=1' (first duplicate's source attached to last value); qjs 'a=2/src=-'.
- zjs：`src/builtins/json.zig:1500 (source collector), 1381-1393 (gating), 1446-1449 (discard)`
- qjs：`JSONParseRecord machinery (quickjs.c 49349-49480) + internalize_json_property pr gating (~49728-49745)`
- 建议修法：Port qjs's JSONParseRecord: capture value+source span per node at parse time and gate per node with same-value, dropping the linear cursor.

### json#9 — MEDIUM · behavior · 有界

The reviver walk performs up to 3 [[Get]] operations per child (value prefetch + same-value check + recursive fetch) versus qjs's single JS_GetProperty per node, observably doubling/tripling getter side effects when a reviver installs an accessor on a not-yet-visited sibling.

- **repro**：JSON.parse('{"a":1,"b":2}',function(k,v){log.push('rev:'+k); if(k==='a'){Object.defineProperty(this,'b',{get(){log.push('getB');return 42},configurable:true,enumerable:true});} return v;})  => zjs log: 'rev:a,getB,getB,rev:b,rev:'; qjs log: 'rev:a,getB,rev:b,rev:' (final values identical).
- zjs：`src/builtins/json.zig:1246-1271, 1383, 1214`
- qjs：`internalize_json_property (quickjs.c 49709), single JS_GetProperty at ~49723`
- 建议修法：Same root as the source-drift finding: with per-node parse records the prefetch and same-check gets disappear, leaving one get per node like qjs.

### json#10 — MEDIUM · structural · 有界

JSON.parse is implemented as Zig std.json + an ASCII-only SimpleJsonParser fast path + a separate text re-scan for reviver sources, instead of mirroring qjs's single json_parse_value tokenizer that builds values and JSONParseRecords in one pass — this is the shared root of the lone-surrogate rejection, parse segfault, source-drift, and generic parse error messages.

- zjs：`src/builtins/json.zig:145-154, 376-579, 1500-1598`
- qjs：`json_parse_value (quickjs.c 49484) + json_next_token (23477)`
- 建议修法：Port json_next_token/json_parse_value (a few hundred lines) with the parse-record union; retire std.json dependency and the source re-scanner in one move.

### json#11 — LOW · behavior · 有界

Error message shape diverges: zjs throws TypeError/SyntaxError with empty or generic messages where qjs has specific texts ('circular reference', 'Do not know how to serialize a BigInt', 'Unexpected end of JSON input', 'expecting property name', "unexpected token: 'X'").

- **repro**：try{var a={};a.a=a;JSON.stringify(a)}catch(e){print(e.name,'|',e.message)}; try{JSON.stringify(5n)}catch(e){print(e.name,'|',e.message)}; try{JSON.parse('{')}catch(e){print(e.name,'|',e.message)}  => zjs: 'TypeError | ' / 'TypeError | ' / 'SyntaxError | invalid syntax'; qjs: 'TypeError | circular reference' / 'TypeError | Do not know how to serialize a BigInt' / 'SyntaxError | expecting property name' (JSON.parse('') qjs: 'Unexpected end of JSON input').
- zjs：`src/builtins/json.zig:2225 (BigInt), 2312/2361 (cycle), parse error mapping json.zig:151`
- qjs：`js_json_to_str 'circular reference' (~50110), BigInt TypeError (~50250), json_parse_value def_token errors (~49640-49650)`
- 建议修法：Attach qjs's message strings when raising these errors (mechanism exists for other builtins); parse messages come free with the json_parse_value port.

---

## Date  `[date]`

> 覆盖说明：Compared src/builtins/date.zig (+ exec/date_ops.zig, exec/builtin_glue.zig glue, registry.zig install tables) against quickjs.c js_Date_parse/js_date_parse_isostring/js_date_parse_otherstring/js_date_constructor/js_Date_UTC/set_date_field/get_date_field/get_date_string/js_date_setYear/js_date_setTime/js_date_toJSON/js_date_Symbol_toPrimitive/getTimezoneOffset, with ~60 behavioral probes on both binaries (host TZ=CST +0800, which exposed local-time divergences invisible on UTC hosts). Confirmed ALIGNED: prototype/static property surface (own-name sets identical incl. getUTCDay/toGMTString/setUT

### date#0 — HIGH · missing_in_zjs · 有界

zjs's Date.parse only accepts ISO strings plus the exact zjs toString/toUTCString shapes; the entire qjs lenient parser js_date_parse_otherstring (month names, slash dates, '2020-1-1', tz abbreviations GMT/UTC/PST/CET..., AM/PM, parenthesized phrases, word skipping) is missing, so most real-world date strings parse to NaN.

- **repro**：Probe /tmp/dp1.js: 'Jan 1 2020' qjs=1577808000000 zjs=NaN; '1/2/2020' qjs=1577894400000 zjs=NaN; '2020-1-1' qjs=1577808000000 zjs=NaN; 'Jan 1 2020 00:00:00 PST' qjs=1577865600000 zjs=NaN; 'Wed Jan 03 2018 00:05:22 GMT+0100 (CET)' qjs=1514934322000 zjs=NaN; 'Thu, 01 Jan 1970 00:00:00 UTC' qjs=0 zjs=NaN; 'Jan 1 2020 12:00 PM' qjs=1577851200000 zjs=NaN
- zjs：`src/builtins/date.zig:884 (parseLegacyDateString) and :547 (parseDateString fallback chain)`
- qjs：`js_date_parse_otherstring, quickjs.c:55758 (plus js_tzabbr table ~55725, string_get_tzoffset ~55631)`
- 建议修法：Port js_date_parse_otherstring verbatim (its helpers string_skip_spaces/separators/until, string_get_digits/milliseconds/tzoffset(strict=false)/tzabbr/month, find_abbrev, and the num[3] end-assignment switch) into date.zig, replacing parseLegacyDateString; keep js_Date_parse's final field_max validation and 24:00 special case.

### date#1 — HIGH · missing_in_zjs · 有界

Local-time support is entirely absent: zjs treats local time as UTC everywhere (getTimezoneOffset hardcoded 0; toString/getHours/setHours/new Date(y,m,...)/Date() all UTC), while qjs computes the host timezone offset per time value, so on any non-UTC host nearly every local-time Date API returns different values than qjs.

- **repro**：Host TZ=CST(+0800). /tmp/dp2.js on new Date(1514934322000): toString qjs='Wed Jan 03 2018 07:05:22 GMT+0800' zjs='Tue Jan 02 2018 23:05:22 GMT+0000'; getTimezoneOffset qjs=-480 zjs=0; getHours qjs=7 zjs=23; new Date(2020,0,1).getTime() qjs=1577808000000 zjs=1577836800000; '1970-01-01 00:00:00' parses to -28800000 in qjs vs NaN in zjs.
- zjs：`src/builtins/date.zig:353 (tz offset constant 0), :341-355 (all methods route through utcDateParts), :249-252 (UTC/local setter ids merged)`
- qjs：`getTimezoneOffset quickjs.c:47454; get_date_fields quickjs.c:55090; set_date_fields quickjs.c:55153`
- 建议修法：Port qjs getTimezoneOffset(int64_t) (localtime_r-based, ~50 lines), split local vs UTC method ids in builtin_method_ids.date, and thread an is_local flag through methodCallArgs/setDateParts/dateString mirroring get_date_fields/set_date_fields; days of work, localized to date.zig + date_ops.zig + host_function id tables.

### date#2 — HIGH · behavior · 有界

Date.parse throws TypeError instead of ToString-coercing its argument: any non-string arg (number, String object, object with toString), zero args, or extra args past the first cause a TypeError in zjs where qjs coerces via JS_ToString and parses.

- **repro**：/tmp/dp3.js + follow-ups: Date.parse(12345) qjs=327403353600000 zjs=TypeError; Date.parse({toString(){return "2020-01-01"}}) qjs=1577836800000 zjs=TypeError; Date.parse() qjs=NaN zjs=TypeError; Date.parse(new String("2020-01-01")) qjs=1577836800000 zjs=TypeError; Date.parse("2020-01-01","x") qjs=1577836800000 zjs=TypeError
- zjs：`src/builtins/date.zig:538-541 (fn parse)`
- qjs：`js_Date_parse, quickjs.c:55907 (JS_ToString at 55921)`
- 建议修法：Replace the isString gate with a ToString coercion in the dateCall/glue path for StaticMethod.parse (mirror qjs: coerce args[0] or undefined via realm ToString, then parse the resulting string); drop the args.len != 1 check.

### date#3 — MEDIUM · behavior · 有界

toLocaleString/toLocaleDateString/toLocaleTimeString are aliased to toString/toDateString/toTimeString instead of qjs's fmt=3 US-style 'MM/DD/YYYY, HH:MM:SS AM' 12-hour format, so every toLocale* output string differs byte-for-byte.

- **repro**：new Date(1514934322000).toLocaleString(): qjs='01/03/2018, 07:05:22 AM' zjs='Tue Jan 02 2018 23:05:22 GMT+0000'; toLocaleTimeString(): qjs='07:05:22 AM' zjs='23:05:22 GMT+0000'; toLocaleDateString(): qjs='01/03/2018' zjs='Tue Jan 02 2018'
- zjs：`src/builtins/date.zig:239-242 (prototypeMethodId aliasing) and :593-645 (dateString has no locale kind)`
- qjs：`get_date_string, quickjs.c:55290 (fmt==3 branches in date part and time part switches)`
- 建议修法：Add a .locale/.locale_date/.locale_time DateStringKind (or fmt/part magic mirroring qjs) to dateString with the MM/DD/YYYY and 12-hour %cM formats, and give toLocale* their own method ids.

### date#4 — MEDIUM · behavior · 有界

ISO date-time strings without a timezone offset (e.g. '2020-01-01T00:00:00') are interpreted as UTC by zjs but as local time by qjs (js_date_parse_isostring sets is_local=TRUE when 'T' is present and no offset follows), diverging on any non-UTC host.

- **repro**：Host TZ=+0800: Date.parse('2020-01-01T00:00:00') qjs=1577808000000 (local) zjs=1577836800000 (UTC); date-only Date.parse('2020-01-01') agrees at 1577836800000 in both (UTC per spec).
- zjs：`src/builtins/date.zig:763-840 (parseIsoDate, no local flag)`
- qjs：`js_date_parse_isostring, quickjs.c:55662 (is_local=TRUE at 'T', ~55750)`
- 建议修法：Track is_local in parseIsoDate exactly as qjs does and apply the local offset in the final ms computation; depends on the getTimezoneOffset port from the local-time finding.

### date#5 — LOW · behavior · 有界

Date [Symbol.toPrimitive] rejects the qjs-supported 'integer' hint with a TypeError (and its invalid-hint TypeError lacks qjs's 'invalid hint' message), where qjs maps JS_ATOM_integer to HINT_NUMBER.

- **repro**：d=new Date(0); d[Symbol.toPrimitive]('integer'): qjs=0, zjs=TypeError. d[Symbol.toPrimitive]('bogus'): both TypeError but qjs message='invalid hint', zjs message=''
- zjs：`src/exec/date_ops.zig:292-293 (hint decode)`
- qjs：`js_date_Symbol_toPrimitive, quickjs.c:55964`
- 建议修法：Add 'integer' to the number-hint branch in the date_ops hint decoder and attach the 'invalid hint' TypeError message.

### date#6 — LOW · behavior · 有界

Date.parse's string-to-bytes conversion diverges for non-Latin1 input: qjs maps U+2212 (Unicode minus) to '-', maps other >255 chars to 'x', and truncates at 127 bytes; zjs instead emits literal '\u{x}' escape text for non-ASCII UTF-16 units, so qjs-parseable strings containing U+2212 become NaN in zjs.

- **repro**：Date.parse('−000001-01-01T00:00:00Z') (U+2212 minus before 6-digit year): qjs=-62198755200000, zjs=NaN
- zjs：`src/builtins/date.zig:692-709 (appendRawString)`
- qjs：`js_Date_parse buffer conversion, quickjs.c:55927-55933`
- 建议修法：Mirror qjs's byte conversion in appendRawString: map 0x2212 to '-', any other unit >255 to 'x', and cap the buffer at 127 bytes.

---

## Number / Math / dtoa  `[number-math-dtoa]`

> 覆盖说明：补跑区域(未过独立对抗验证管线,agent自验9条)。CONFIRMED CLEAN: toFixed/toExponential/toPrecision digit-exact(46 edge x 12 digit + 8000-double fuzz 0 diff); Number(string)/parseFloat correctly-rounded; parse grammar parity; Math edge tables identical(pow/min/max/round/hypot/imul/clz32/fround/f16round/atan2/sign/trunc/sumPrecise)。

### number-math-dtoa#0 — HIGH · behavior · 有界

Math.random() 是常量 0.5 桩(realm+bare 双路径),rt.random_state 存在但从未被使用

- 建议修法：实现 qjs js_math_random(xorshift64star over rt.random_state)

### number-math-dtoa#1 — HIGH · fastpath · 有界

String(double) 在 ~2.5e14..9e14 一段 double 输出非 round-trip(formatSimpleFiniteDecimal 用 value*10 取整误判一位小数)

- 建议修法：给快路径加精确性检查或删掉快路径改走 dtoa.formatNumber

### number-math-dtoa#2 — HIGH · behavior · 有界

Number.prototype.toString(radix!=10) 只转整数部分:小数位被丢弃(纯小数打印空串/裸"-"),>=2^128 触发越界 @intFromFloat,>2^53 无 shortest-roundtrip

- 建议修法：移植 qjs js_dtoa2 radix 路径(FORMAT_FREE|EXP_DISABLED)替换 appendRadixInteger

### number-math-dtoa#3 — HIGH · behavior · 有界

JSON.stringify 数字序列化绕开引擎 dtoa,用 std.fmt {d} 写 128B 栈缓冲:|v|>=1e21 记号错误,|v|>~1e127 或极小 denormal 以 NoSpaceLeft 中止整个求值

- 建议修法：JSON 数字走 core.value_format.formatFiniteNumber(与 String() 同 ToString 路径)

### number-math-dtoa#4 — MEDIUM · behavior · 有界

parseInt 对 >~15-16 有效位输入丢精度(逐位 f64 累加 value=value*radix+digit,而非 qjs 精确 js_atof)

- 建议修法：19 位后切 bigint 累加 + 正确舍入

### number-math-dtoa#5 — MEDIUM · behavior · 有界

ToNumber(string) 对超 64 位的进制前缀字面量返回 NaN(hex>16位/binary>64/octal>21,因 parseUnsigned(u64) 溢出被判非法)

- 建议修法：u64 溢出后继续 f64 累加(mirror qjs js_atod)

### number-math-dtoa#6 — MEDIUM · structural · 有界

超越函数用 Zig std.math(musl 派生)而非 qjs 链接的系统 libm,末位分歧率高:pow~76% cbrt~53% atan2~11% hypot~4% sin/cos/tan~2-3%

- 建议修法：若要 digit-parity 需链同款 libm(先 pow/cbrt/atan2);否则记录为可接受偏离(zjs 有时更准)

### number-math-dtoa#7 — LOW · behavior · 有界

Number.prototype.toLocaleString 强制其首参(可观察 valueOf 调用,抛错会传播),qjs 从不读 argv

- 建议修法：id==to_locale_string 时跳过 coerceOptionalNumberMethodArgument

### number-math-dtoa#8 — LOW · behavior · 有界

Math.sumPrecise: zjs(精确 bigint 求和)正确,而此 qjs 在第 500 次 add 对某有限负和返回 +Infinity — qjs 上游 bug,zjs 勿对齐

- 建议修法：无 zjs 改动;记录为 qjs 04be246 上游 bug

---

## BigInt  `[bigint]`

> 覆盖说明：Compared zjs HEAD 541c30f vs qjs 04be246 (both binaries run head-to-head, node v24 as spec oracle for disagreements; ~150 probes across 7 batteries in /tmp/bigint_*.js). CONFIRMED CLEAN/ALIGNED: div/rem truncation signs incl 1n/0n / 1n%0n error types; ** semantics (0n**0n=1n, negative-exponent RangeError — note focus brief said TypeError but both engines+spec use RangeError); shifts incl negative-shift reversal, >>100n saturation, >>> TypeError; bitwise &|^~ on negatives; unary +/-/!; -0n; ALL mixed equality (numbers/strings/booleans/objects/NaN/Infinity/2^53 boundary) and non-negative relatio

### bigint#0 — MEDIUM · behavior · 有界

zjs StringToBigInt only strips ASCII " \t\r\n" whitespace, rejecting spec-legal whitespace (\v, \f, NBSP U+00A0, U+3000, U+2028/2029, BOM U+FEFF) with SyntaxError in BigInt(string), bigint==string, and bigint<string.

- **repro**：BigInt(' 7') / BigInt('\v7\v') / 1n == '\v1' / 1n < ' 2'  => zjs: SyntaxError / SyntaxError / false / false; qjs AND node: 7n / 7n / true / true (probe /tmp/bigint_ws.js)
- zjs：`src/exec/value_ops.zig:141 (also :573, src/core/typed_array.zig:853)`
- qjs：`JS_StringToBigInt quickjs.c:14609 + skip_spaces quickjs.c:11230`
- 建议修法：Replace the ASCII trim with a StrWhiteSpaceChar-aware skip (same char set as zjs's Number(string) parser should use: TAB VT FF SP NBSP BOM LS PS LF CR + Unicode Zs), mirroring qjs skip_spaces.

### bigint#1 — MEDIUM · behavior · 有界

BigInt() with no arguments returns 0n in zjs; qjs (and spec: ToBigInt(undefined)) throws TypeError 'cannot convert to BigInt'.

- **repro**：zjs -e 'print(String(BigInt()))' => 0 ; qjs -e 'print(BigInt())' => TypeError: cannot convert to BigInt (node also throws TypeError)
- zjs：`src/exec/builtin_glue.zig:65`
- qjs：`js_bigint_constructor quickjs.c:56232 / JS_ToBigIntCtorFree undefined arm quickjs.c:56227`
- 建议修法：Default missing arg to JSValue.undefinedValue() so the ToBigInt path throws TypeError, matching BigInt(undefined) which zjs already gets right.

### bigint#2 — MEDIUM · behavior · 有界

Several zjs builtins silently coerce BigInt arguments through lenient number helpers where spec/qjs require ToNumber(BigInt) to throw TypeError: Date constructor/Date.UTC/setTime accept 1n (NaN or valid Date), Array.prototype.at/slice/fill treat a bigint index as 0, parseInt('10', 2n) coerces radix, and String.fromCodePoint(65n) throws RangeError instead of TypeError.

- **repro**：probe /tmp/bigint_tonum.js — new Date(1n)=>true / Date.UTC(2020,1n)=>NaN / [1,2,3].at(1n)=>1 / [1,2,3].slice(1n)=>1,2,3 / [1,2].fill(0,1n)=>0,0 / parseInt('10',2n)=>10 / fromCodePoint(65n)=>RangeError in zjs; qjs throws TypeError for every one (node agrees). String methods (charAt/repeat/slice/at), toFixed, toString(radix), TypedArray ctor, indexOf fromIndex already throw correctly in zjs.
- zjs：`src/builtins/date.zig:732; src/builtins/array.zig:896; src/builtins/string.zig:368; parseInt glue src/exec/builtin_glue.zig:176`
- qjs：`js_date_constructor / js_array_at (JS_ToInt64Sat) / js_global_parseInt (JS_ToInt32) / js_string_fromCodePoint (JS_ToFloat64) — all via JS_ToFloat64 TypeError on JS_TAG_BIG_INT`
- 建议修法：Make these argument coercions go through the strict ToNumber/ToIntegerOrInfinity path that rejects bigint (zjs already has it — most other builtins throw correctly); fromCodePoint must reject bigint with TypeError before range checks.

### bigint#3 — MEDIUM · missing_in_zjs · 有界

zjs has no BigInt size cap: qjs enforces JS_BIGINT_MAX_SIZE (1M bits) and throws RangeError 'BigInt is too large to allocate' on every bigint allocation and parse, while zjs computes unboundedly — huge shifts/pow/asUintN hang or OOM instead of throwing.

- **repro**：timeout 10 zjs -e 'print(String(BigInt.asUintN(4294967296,-1n)).length)' => exit 124 (hang); qjs => instant (RangeError path or its own shortcut)
- zjs：`src/libs/bigint.zig:184 (shl), :134 (pow), :535 (parseBaseAlloc) — no limb-count guard`
- qjs：`js_bigint_new quickjs.c:11594 / JS_BIGINT_MAX_SIZE quickjs.c:11266`
- 建议修法：Add a 1M-bit (16384×64-bit limbs) guard in the zjs bignum allocation choke points (shl/pow/mul/parse), mapping to error.RangeError, mirroring js_bigint_new.

### bigint#4 — MEDIUM · behavior · 有界

Every BigInt-related error in zjs carries an empty message (bare Zig error enums), while qjs attaches specific texts; error TYPES all match but message shape diverges across ~10 distinct sites.

- **repro**：probe /tmp/bigint_probe.js + /tmp/bigint_parse.js — e.g. 1n/0n => zjs 'RangeError: ' vs qjs 'RangeError: BigInt division by zero'; 1n+1 => zjs 'TypeError: ' vs qjs 'TypeError: cannot convert bigint to number'
- zjs：`src/exec/value_ops.zig:775-785 (and the bigint arms of exec/exceptions error mapping)`
- qjs：`JS_ThrowRangeError/JS_ThrowTypeError call sites in js_bigint_divrem/js_bigint_pow path, js_unary_arith_slow quickjs.c:14771, JS_ToBigIntFree quickjs.c:56227`
- 建议修法：Attach qjs's message strings at the throw sites (zjs clearly supports messages elsewhere); align 'invalid syntax' to 'invalid bigint literal' for StringToBigInt.

### bigint#5 — MEDIUM · behavior · 有界

qjs REFERENCE BUG (zjs is correct — do NOT align): bigint decrement x--/--x adds 4294967295 instead of subtracting 1 for any heap bigint and at SHORT_BIG_INT_MIN, because `2 * (op - OP_dec) - 1` is computed in unsigned enum arithmetic and passed to the 64-bit js_slimb_t parameter without sign extension.

- **repro**：var x=2n**100n; x--; print(x) => qjs: 1267650600228229401500998172671n (== 2^100 + 4294967294, WRONG); zjs & node: 1267650600228229401496703205375n. Also -9223372036854775808n via x-- => qjs -9223372032559808513n wrong. Binary `- 1n` is fine in qjs.
- zjs：`n/a — zjs correct (src/exec/vm_arith.zig shortBigIntUnary + heap slow path)`
- qjs：`js_unary_arith_slow quickjs.c:14812 `js_bigint_set_si(&buf2, 2 * (op - OP_dec) - 1)``
- 建议修法：No zjs change. Document in DIVERGENCE-CATALOG as a known qjs 04be246 bug (compiler-dependent unsigned-enum UB) and consider reporting upstream; any differential test harness must whitelist it.

### bigint#6 — MEDIUM · behavior · 有界

qjs REFERENCE BUG (zjs is correct — do NOT align): BigInt.asUintN returns a negative bigint unchanged when bits >= the value's two's-complement width (e.g. asUintN(64,-1n) => -1n), violating the spec requirement of a non-negative result mod 2^bits.

- **repro**：BigInt.asUintN(64,-1n) => qjs -1n (wrong); zjs & node 18446744073709551615n. Also asUintN(200,-1n), asUintN(65,-1n) wrong in qjs; asUintN(3,-10n)=6n correct in all (truncation path is fine).
- zjs：`n/a — zjs correct (value_ops.asN)`
- qjs：`js_bigint_asUintN quickjs.c:56287 (shortcuts at 56303 and 56319)`
- 建议修法：No zjs change; document as known qjs bug so differential testing whitelists it.

### bigint#7 — MEDIUM · behavior · 有界

qjs REFERENCE BUG (zjs is correct — do NOT align): mixed bigint<->double relational comparison drops the sign in the exponent-differs branch, giving wrong results when both operands are negative and magnitudes differ at the exponent level (e.g. -1n < -0.5 => qjs false).

- **repro**：-0.5 > -1n / -1n < -0.5 / -(10n**400n) < -1.7976931348623157e308 / -(2n**60n) < -1.5 => qjs: false,false,false,false; zjs AND node: true,true,true,true. Equality is unaffected (only nonzero-ness of cmp matters).
- zjs：`n/a — zjs correct (value_ops.compareBigIntToNumber src/exec/value_ops.zig:146)`
- qjs：`js_bigint_float64_cmp quickjs.c:12339 (f != e branch ~12374)`
- 建议修法：No zjs change; document as known qjs bug for differential-test whitelisting.

### bigint#8 — LOW · behavior · 有界

zjs CLI print() renders bigints via ToString ('3') while qjs print() uses JS_PrintValue debug formatting which appends the n suffix ('3n'), diverging on every printed bigint.

- **repro**：zjs -e 'print(1n+2n)' => 3 ; qjs -e 'print(1n+2n)' => 3n (but both print String(1n) => '1')
- zjs：`zjs CLI print host function (src/cli / value_format path)`
- qjs：`js_print quickjs-libc.c:4063 → JS_PrintValue`
- 建议修法：If CLI parity matters for differential testing, make zjs print mirror JS_PrintValue's bigint 'Nn' rendering; otherwise document.

---

## Error / 异常 / 栈回溯  `[error-exception]`

> 覆盖说明：Compared zjs (HEAD 541c30f) src/builtins/error.zig + src/core/exception.zig + src/exec/error_stack_ops.zig (plus construction paths in object_ops.zig/construct.zig/vm_exception_ops.zig/string_ops.zig) against quickjs 04be246 js_error_constructor / build_backtrace / JS_ThrowError2 / js_aggregate_error_constructor / js_error_toString, with ~20 dual-engine behavioral probes. CONFIRMED ALIGNED (clean): error cause semantics fully match qjs — side-effect order (message ToString before cause read), HasProperty-then-Get proxy trap order, inherited cause via proto chain, cause:undefined still defined,

### error-exception#0 — HIGH · zjs_extra · 有界

zjs ships the V8 stack-introspection cluster absent from qjs — Error.captureStackTrace, Error.prepareStackTrace hook (with live CallSite objects), and Error.stackTraceLimit defaulting to 10 which silently truncates every stack to 10 frames (qjs stacks are unlimited).

- **repro**：Error.stackTraceLimit=2; deep 4-frame Error -> zjs prints 2 frames, qjs prints all 4 and Error.stackTraceLimit stays an ordinary user property with no effect.
- zjs：`src/builtins/error.zig:46; src/exec/error_stack_ops.zig:100-150`
- qjs：`js_error_funcs quickjs.c:~41576 (only isError); build_backtrace quickjs.c:7538 has no limit/hook`
- 建议修法：Remove captureStackTrace/prepareStackTrace/stackTraceLimit and the CallSite machinery when porting the eager build_backtrace model (same cluster as finding 1); unlimited frames by default.

### error-exception#1 — MEDIUM · structural · 有界

zjs implements `stack` as a lazy V8-style accessor pair on Error.prototype backed by CallSite arrays, whereas qjs stamps an eager own data-property string on the instance at construction (build_backtrace).

- **repro**：var e=new Error('m'); var d=Object.getOwnPropertyDescriptor(e,'stack'); print(d?typeof d.value:'none'); delete e.stack; print(typeof e.stack);  => zjs: none / string ; qjs: string / undefined
- zjs：`src/exec/error_stack_ops.zig:24-45; src/builtins/error.zig:44-45`
- qjs：`build_backtrace quickjs.c:7538 (final JS_DefinePropertyValue JS_ATOM_stack W|C) + js_error_constructor quickjs.c:41508`
- 建议修法：Mirror build_backtrace: format the stack string eagerly at construction/throw time and define it as an own writable+configurable data property on the instance; retire the prototype accessor + CallSite-array model (cluster is localized to error_stack_ops.zig / builtins/error.zig / object.zig setErrorStackSites).

### error-exception#2 — MEDIUM · behavior · 有界

zjs stamps an own non-enumerable `name` data property (from the invoked constructor's name) on every error instance; qjs leaves `name` solely on the per-class prototype, so prototype patching and new.target-derived prototypes behave differently.

- **repro**：var e=new TypeError('m'); print(Object.prototype.hasOwnProperty.call(e,'name')); TypeError.prototype.name='Patched'; print(e.name, e.toString());  => zjs: true / TypeError / 'TypeError: m' ; qjs: false / Patched / 'Patched: m'. Also: Reflect.construct(TypeError,['m'],Error).name => zjs 'TypeError', qjs 'Error'.
- zjs：`src/exec/object_ops.zig:990; src/exec/construct.zig:288`
- qjs：`js_error_constructor quickjs.c:41441 + js_native_error_proto_funcs quickjs.c:~41552 (name lives on prototype only)`
- 建议修法：Delete the per-instance `name` define in both construction paths; the prototypes already carry correct name/message (verified aligned descriptors w=true e=false c=true).

### error-exception#3 — MEDIUM · missing_in_zjs · 有界

qjs's InternalError native error class is entirely absent from zjs, and the errors qjs raises as InternalError (stack overflow, interrupted, OOM, 'string too long') surface as different types: zjs throws V8-style RangeError 'Maximum call stack size exceeded' for stack overflow vs qjs InternalError 'stack overflow'.

- **repro**：print(typeof globalThis.InternalError); function rec(){return rec()+1} try{rec()}catch(e){print(e.name, e.message)}  => zjs: undefined / RangeError Maximum call stack size exceeded ; qjs: function / InternalError stack overflow
- zjs：`src/exec/vm_call.zig:77,88; src/exec/inline_calls.zig:270`
- qjs：`JS_ThrowStackOverflow -> JS_ThrowInternalError quickjs.c:7791; JS_ATOM_InternalError in js_native_error_proto_funcs quickjs.c:~41565`
- 建议修法：Add InternalError as a native error class (constructor + prototype, parallel to EvalError etc.) and route stack-overflow/interrupt/OOM throws through it with qjs message text.

### error-exception#4 — MEDIUM · behavior · 有界

zjs backtraces omit native (builtin C-function) frames that qjs renders as 'at <name> (native)' lines.

- **repro**：function cb(){return new Error('x')} print([1].map(cb)[0].stack)  => qjs has 'at map (native)' middle line, zjs does not
- zjs：`src/exec/string_ops.zig:556 buildErrorStackStringValue over ctx.snapshotBacktraceFrames (bytecode frames only)`
- qjs：`build_backtrace quickjs.c:~7605 else-branch dbuf_printf(&dbuf, " (native)")`
- 建议修法：Include host/native call frames in the backtrace snapshot and emit ' (native)' suffix instead of file:line:col; the single-backtrace-chain groundwork (DIVERGENCE-CATALOG.md line 190, commit 29e93a6) already walks the frame chain.

### error-exception#5 — MEDIUM · behavior · 有界

Parse-error SyntaxErrors lack the own fileName/lineNumber/columnNumber properties and the leading 'at <file>:line:col' stack line that qjs's build_backtrace(filename,...) adds.

- **repro**：try{eval('var x = ;')}catch(e){print(e.fileName,e.lineNumber,e.columnNumber)}  => zjs 'undefined undefined undefined'; qjs '<input> 1 9'
- zjs：`src/exec/vm_exception_ops.zig:201 (SyntaxError created via createNamedError with generic message, no location plumbing)`
- qjs：`build_backtrace quickjs.c:7553-7570 (filename branch defining JS_ATOM_fileName/lineNumber/columnNumber) called from quickjs.c:22342 (parse error site)`
- 建议修法：Thread parse filename/line/col into SyntaxError construction and define the three own W|C properties plus the extra first stack line, mirroring the build_backtrace filename branch.

### error-exception#6 — MEDIUM · behavior · 有界

Many builtin throw paths produce empty or genericized messages where qjs formats specific text via JS_ThrowTypeError/JS_ThrowRangeError printf formats.

- **repro**：try{Symbol()+''}catch(e){print(e.name+': '+e.message)}  => zjs 'TypeError: ' ; qjs 'TypeError: cannot convert symbol to string'
- zjs：`src/exec/vm_exception_ops.zig:195-210 (createNamedError fallback mapping)`
- qjs：`JS_ThrowError2 quickjs.c:7640 (vsnprintf message) + per-site JS_ThrowTypeError formats`
- 建议修法：At each site currently returning a bare error.TypeError/RangeError, throw a message-bearing exception with qjs's exact format string; keep the bare-code fallback only as last resort.

### error-exception#7 — MEDIUM · behavior · 有界

Promise.any's internally built AggregateError diverges: zjs defines an own empty `message` property (qjs defines none) and defines `errors` as enumerable (qjs W|C non-enumerable), so JSON.stringify and hasOwnProperty differ.

- **repro**：Promise.any([Promise.reject(1)]).catch(e=>print(Object.prototype.hasOwnProperty.call(e,'message'), Object.getOwnPropertyDescriptor(e,'errors').enumerable))  => zjs 'true true'; qjs 'false false'
- zjs：`src/exec/vm_exception_ops.zig:211-218`
- qjs：`js_aggregate_error_constructor quickjs.c:41582 (only errors, JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE; no message)`
- 建议修法：In qjsPromiseAggregateError skip the message define entirely and define errors with writable+configurable, non-enumerable.

### error-exception#8 — LOW · behavior · 有界

Top-level script/eval frames are named '<anonymous>' in zjs stacks where qjs names them '<eval>'.

- **repro**：print(new Error('x').stack) at top level => zjs 'at <anonymous> (...)', qjs 'at <eval> (...)'
- zjs：`src/exec/error_stack_ops.zig:120-125; src/exec/string_ops.zig:580`
- qjs：`build_backtrace quickjs.c:7580 get_prop_string(JS_ATOM_name); top-level eval bytecode is named JS_ATOM__eval_ ('<eval>') by the compiler`
- 建议修法：Name the top-level script/eval function bytecode '<eval>' (as qjs's compiler does) so the existing name-resolution emits it; keep '<anonymous>' only for truly unnamed functions.

### error-exception#9 — LOW · behavior · 有界

Stack line/column mapping deviates from qjs: caller frames map the return address without qjs's -1 adjustment, so the top-level frame of an uncaught throw can point past the last line of the file, and call-site columns differ by several characters.

- **repro**：file: 'function boom(){throw new Error(1)}\nboom();' run uncaught => zjs last frame line 3 col 1 (past EOF); qjs line 2 col 5
- zjs：`src/exec/string_ops.zig:582 entry.location() (BacktraceFrame pc->line mapping without return-address backoff)`
- qjs：`build_backtrace quickjs.c:7597 find_line_num(ctx, b, sf->cur_pc - b->byte_code_buf - 1, &col_num1) — note the -1`
- 建议修法：When mapping a caller frame's pc, back off one byte/instruction to land inside the call opcode (mirror qjs's cur_pc-1) before line/col lookup.

---

## 模块 / eval / 全局绑定  `[modules-eval-global]`

> 覆盖说明：Compared zjs HEAD 541c30f vs qjs 04be246 with ~30 differential probe scripts (/tmp/modaudit) plus source reading of src/core/module.zig, src/exec/module_graph.zig, vm_eval_module.zig, eval_ops.zig, call_runtime.zig publish machinery, core/var_ref.zig, global_slots.zig, cli/zjs.zig against quickjs.c js_module_*/js_evaluate_module/js_inner_module_evaluation/js_dynamic_import/__JS_EvalInternal. CONFIRMED CLEAN (identical outputs both engines): module-namespace exotic object full invariant battery (ownKeys order incl. integer-like and string export names + Symbol.toStringTag placement/descriptor, 

### modules-eval-global#0 — HIGH · behavior · 有界

Dynamic import() re-executes an already-evaluated module (no evaluate-once, no cached-error rethrow): module side effects run once per import() call.

- **repro**：/tmp/modaudit: sideeffect.js = `print('sideeffect evaluating'); export let n = 1;` ; main.js = `import * as st from './sideeffect.js'; await import('./sideeffect.js');` — qjs -m prints 'sideeffect evaluating' ONCE; zjs -m prints it TWICE. Same for errored modules: `import('./errmod.js')` twice re-runs the throwing body in zjs while qjs returns the cached exception without re-evaluating.
- zjs：`src/exec/module_graph.zig:627 (evalDynamicImportModule)`
- qjs：`js_inner_module_evaluation quickjs.c:31423 (status EVALUATED early-return + eval_exception rethrow)`
- 建议修法：Mirror the host-hooks path: check record.status before re-evaluating (skip if evaluating/evaluated), set track_module_status=true, and store/rethrow the cached evaluation error for .errored records.

### modules-eval-global#1 — HIGH · behavior · 有界

import() of an unresolvable module aborts the entire evaluation with an uncatchable host error instead of rejecting the returned promise; the mapped case also rejects with TypeError where qjs uses ReferenceError.

- **repro**：main.js = `try { await import('./nonexistent-file.js'); } catch (e) { print('caught:', e.constructor.name); } print('survived');` — qjs -m: 'caught: ReferenceError / survived' exit 0; zjs -m: 'zjs: evaluation failed: FileNotFound' exit 1, catch never runs.
- zjs：`src/exec/vm_eval_module.zig:143-151 + src/exec/vm_exception_ops.zig:238`
- qjs：`js_dynamic_import_job quickjs.c:31036 (any exception → JS_Reject of the import promise); loader error ReferenceError quickjs-libc.c:699`
- 建议修法：Map FileNotFound (and all loader errors) in evalDynamicImportModule to error.ModuleNotFound before it escapes, and change pushRejectedTypeError to a ReferenceError with qjs's message shape.

### modules-eval-global#2 — HIGH · behavior · 有界

In module (-m) mode, output printed from microtasks that run after a synchronously-completing root module is silently dropped (missing stdout flush before process exit).

- **repro**：drain1.js = `Promise.resolve().then(() => print('micro fired')); print('body done');` — qjs -m prints both lines; zjs -m prints only 'body done'. Script mode (zjs -e / no -m) prints both. Proof jobs DO run: making the microtask print 70000 chars forces a buffer auto-flush and the text appears (wc -c = 70010).
- zjs：`src/cli/zjs.zig:295-333`
- qjs：`qjs.c main → js_std_loop then exit (output unbuffered per job)`
- 建议修法：Add `try stdout_writer.interface.flush();` after runUntilIdle (and before every std.process.exit).

### modules-eval-global#3 — HIGH · behavior · 有界

import() evaluates the target module synchronously inside the import() expression instead of deferring load/evaluate to a job, flipping observable side-effect order.

- **repro**：indep.js = `print('indep runs');` ; main.js = `import('./indep.js'); print('sync line after import()');` — qjs -m: 'sync line after import()' THEN 'indep runs'; zjs -m: 'indep runs' THEN 'sync line after import()'.
- zjs：`src/exec/vm_eval_module.zig:137-157`
- qjs：`js_dynamic_import quickjs.c:31073 + JS_EnqueueJob quickjs.c:31155`
- 建议修法：Enqueue a promise job that invokes the dynamic-import callback and resolves/rejects the returned capability, mirroring js_dynamic_import_job.

### modules-eval-global#4 — MEDIUM · behavior · 有界

Nested direct eval inside a function loses the inner eval's var: `eval('eval("var d=9")')` fails to hoist d into the enclosing function's var environment.

- **repro**：zjs -e 'function n(){ eval("eval(\"var deep = 9;\")"); return typeof deep; } print(n());' → 'undefined' (and reading `deep` throws ReferenceError); qjs → 'number' (deep === 9). Works at global scope and within the outer eval's own body; only the propagation to the function frame is lost.
- zjs：`src/exec/call_runtime.zig:4764 publishDirectEvalVarRefs; src/exec/eval_ops.zig:690`
- qjs：`__JS_EvalInternal quickjs.c:37188 (scope_idx direct-eval compile) + add_eval_variables`
- 建议修法：When the caller frame is itself an eval frame, publish the new var cells through to the original function's frame/function-object (walk the eval chain), or include the inner-eval names in the outer frame's inherited eval-var tables before it returns.

### modules-eval-global#5 — MEDIUM · missing_in_zjs · 有界

Dynamic import() is unsupported outside -m module mode: in script files and -e it rejects with TypeError 'dynamic import is not supported', while qjs supports import() from scripts.

- zjs：`src/cli/zjs.zig:262 (script path, no dynamic_import_callback) + src/exec/vm_eval_module.zig:160`
- qjs：`js_dynamic_import quickjs.c:31073 (works from JS_EVAL_TYPE_GLOBAL); qjs.c JS_SetModuleLoaderFunc`
- 建议修法：Install the file-loader dynamic-import callback for script-mode CLI evaluation too (referrer = script filename or cwd).

### modules-eval-global#6 — MEDIUM · behavior · 有界

import() drops import attributes: dynamic import of a JSON module with { with: { type: 'json' } } fails with SyntaxError (raw JSON parsed as JS), though the same static import works.

- **repro**：main.js = `const m = await import('./data.json', { with: { type: 'json' } }); print(m.default);` — qjs -m prints the JSON; zjs -m fails: "SyntaxError: SYNTAX ERROR in preloadFileModuleGraphInner data.json:2:1 - UnexpectedToken". Static `import data from './data.json' with { type: 'json' }` works in both.
- zjs：`src/exec/vm_eval_module.zig:118-135 + src/core/context.zig:196`
- qjs：`js_dynamic_import quickjs.c:31073 (passes attributes through to the module loader; JSReqModuleEntry attributes)`
- 建议修法：Thread the parsed attribute list through DynamicImportCallback so evalDynamicImportModule can set synthetic_kind=json (reusing the static-import synthetic module path).

### modules-eval-global#7 — MEDIUM · behavior · 有界

import.meta.url is the bare relative filename when zjs is invoked with a relative path, instead of an absolute file:// URL as qjs always produces.

- **repro**：cd /tmp/modaudit; main30.js imports metadep.js, both print import.meta.url. qjs -m main30.js → 'file:///tmp/modaudit/metadep.js' / 'file:///tmp/modaudit/main30.js'; zjs -m main30.js → 'metadep.js' / 'main30.js'. Invoking zjs with the absolute path yields correct file:// URLs — the record names simply keep whatever relative form the resolver produced.
- zjs：`src/exec/module.zig:962-975 importMetaUrlValue`
- qjs：`js_module_set_import_meta quickjs-libc.c:548 (realpath + "file://" prefix)`
- 建议修法：Always resolve the module name against cwd to an absolute path (or normalize module registry keys to absolute at preload) before prefixing file://.

### modules-eval-global#8 — MEDIUM · behavior · 深前沿

TLA scheduling diverges: while an async module is suspended, zjs blocks and drains it to completion before evaluating sibling modules, so independent siblings run late (or never, on error) and caller microtasks are starved during import() of a TLA module.

- **repro**：slowdep.js(TLA) <- syncuser.js; indep.js independent; main imports both. qjs order: 'slowdep start / indep runs / slowdep end / syncuser runs'; zjs order: 'slowdep start / slowdep end / syncuser runs / indep runs'. Error variant: baddep.js(TLA, throws after await) <- user1.js; main also imports indep.js — qjs still prints 'indep runs' before failing; zjs never runs indep. Also main28: `const p=import('./tla.js'); Promise.resolve().then(()=>print('between')); await p` — qjs interleaves 'between' before the module's post-await code, zjs does not.
- zjs：`src/exec/module_graph.zig:502-513, 173-186`
- qjs：`js_execute_async_module quickjs.c:31362 / js_async_module_execution_fulfilled quickjs.c:31301`
- 建议修法：Requires restructuring module evaluation toward spec async-module machinery (pending_async_dependencies / cycle roots) rather than host-side blocking drains; entangled with the whole module_graph continuation design.

### modules-eval-global#9 — MEDIUM · structural · 深前沿

The whole module evaluation pipeline diverges from quickjs: host-driven postorder loop that re-compiles every module 3+ times per run (preload, function-decl init, each eval/resume step) with name-keyed linear-scan Registry and generator-based TLA continuations, instead of qjs's compiled-once JSModuleDef graph driven by js_evaluate_module.

- zjs：`src/exec/module_graph.zig:130-424; src/core/module.zig:303`
- qjs：`js_evaluate_module quickjs.c:31535 / js_link_module / JSModuleDef`
- 建议修法：Keep compiled Bytecode on the ModuleRecord (compile once at preload), resolve requested_modules to record indices at link, and drive evaluation from the record graph mirroring js_evaluate_module; prerequisite for fixing the TLA-ordering finding faithfully.

### modules-eval-global#10 — LOW · behavior · 有界

Module error surface diverges: internal zjs function names leak into user-visible SyntaxError messages, and CLI-level link/load errors lose qjs's descriptive text.

- **repro**：zjs -m main21.js → 'SyntaxError: SYNTAX ERROR in preloadFileModuleGraphInner data.json:2:1 - UnexpectedToken' (internal fn name in JS-visible message). Missing export: qjs prints "SyntaxError: Could not find export 'nonexistent' in module 's1.js'"; zjs prints bare 'zjs: evaluation failed: SyntaxError'. Missing file static import: qjs "ReferenceError: could not load module filename 'no-such-file.js'"; zjs 'evaluation failed: ModuleNotFound'.
- zjs：`src/exec/module_graph.zig:365,620`
- qjs：`js_resolve_export error messages (quickjs.c ~30050 'could not load module'; 'Could not find export')`
- 建议修法：Drop internal function names from message text and construct qjs-shaped messages for MissingExport/AmbiguousExport/ModuleNotFound at the point of throw.

---

## 解析器 / 语法  `[parser-syntax]`

> 覆盖说明：Probed ~200 targeted snippets across both binaries (batches saved under /tmp/gram/p; harness /tmp/gram/batch.sh diffs accept/reject + output). CONFIRMED CLEAN / ALIGNED (both engines identical): optional chaining short-circuit incl. delete-of-plain-member, `?.()`, tagged-template-after-`?.` error, new-with-optional-chain error; logical assignment (&&=/||=/??=) incl. getter short-circuit; static blocks (+return/await/break/yield/super/new.target restrictions); `#x in obj`; numeric separators (all valid + all invalid placements); exponent right-assoc + unary-minus error; hashbang; labels (dup/un

### parser-syntax#0 — HIGH · behavior · 有界

The for-init `no-in` restriction leaks into ALL nested/parenthesized sub-expressions, so `in` inside parens, call args, object values, ternary, array literals, or templates in a for-init is wrongly rejected.

- **repro**：echo 'for (var x = (1 in {a:1}); false;) ; print("ok");' | file. zjs: `SyntaxError ... UnexpectedToken`; qjs: `ok`
- zjs：`src/parser.zig:9166-9167 (paren branch of parsePrimary forwards flags via forceResultNeeded without setting in_accepted=true); array literal 9182, object literal 9185, call args similarly`
- qjs：`js_parse_expr_paren quickjs.c:26195 + PF_IN_ACCEPTED handling quickjs.c:27831 (paren/group re-enables PF_IN_ACCEPTED)`
- 建议修法：In parsePrimary's `(` group branch, array-literal, object-literal-value, and call-argument parses, force `in_accepted=true` (a paren/bracket/brace resets the no-in restriction, matching qjs PF_IN_ACCEPTED re-set inside grouping).

### parser-syntax#1 — HIGH · behavior · 有界

Duplicate parameter names are NOT rejected when any parameter is a destructuring pattern, renamed binding, or rest-in-pattern — zjs only checks simple identifier params.

- **repro**：echo 'function f(a, [a]) { return a; } print(f(1,[2]));' — zjs: `1`; qjs: `SyntaxError: duplicate parameter names not allowed in this context`
- zjs：`src/parser.zig:15004-15010 (dup check only runs for the simple-identifier param branch; destructuring/rename branches at 15053/15060/15067 never record names into simple_param_names nor check duplicates)`
- qjs：`js_parse_check_duplicate_parameter quickjs.c:26278 (checked for every binding added during destructuring param parse)`
- 建议修法：Track every bound name introduced by any parameter (including names inside destructuring patterns and rest patterns) and run the qjs duplicate-parameter check across the full set; the existing has_simple_parameter_list logic already knows a pattern was present.

### parser-syntax#2 — HIGH · behavior · 有界

`new new F().m` (and `new new F().arr[0]`) mis-associates: the member tail on the inner `new` operand is stolen by the outer `new`, so zjs constructs the wrong callee and throws 'not a constructor'.

- **repro**：function F(){ this.m=function(){this.tag='t';}; } var c = new new F().m; print(c.tag); — zjs: TypeError; qjs: `t`
- zjs：`src/parser.zig:8296-8297 (parseNewExpr TOK_NEW branch recurses into parseNewExpr but does NOT call parseNewCalleeMemberAccess afterward, so trailing `.m`/`[..]` on the inner new is left for the outer new's callee-member parse)`
- qjs：`js_parse_postfix_expr TOK_NEW quickjs.c:27001-27017 — inner operand parsed by recursive js_parse_postfix_expr(s,0) which consumes the member tail of the inner new before the outer new applies`
- 建议修法：After the recursive `parseNewExpr` in the TOK_NEW operand branch, call `parseNewCalleeMemberAccess(s, flags)` so member accesses following the inner NewExpression bind to it (mirroring qjs's single postfix recursion that consumes the member tail).

### parser-syntax#3 — HIGH · behavior · 有界

Cross-newline `let` declaration is misparsed: `let\n<ident>`, `let\n{...}`, and `let\n[...]` at statement/block level are wrongly treated as an expression (ReferenceError) or rejected, instead of a lexical declaration.

- **repro**：printf 'let\nx = 5; print(x);\n' — zjs: `ReferenceError`; qjs: `5`
- zjs：`src/parser.zig:12321-12325 canTreatLetAsExpressionStatement — when peek is on a different line and is `{` or TOK_IDENT it returns true (expression), the inverse of qjs; and it does not consult declaration-context (DECL_MASK_OTHER)`
- qjs：`is_let quickjs.c:28619 — a following IDENT/`{`/LET/YIELD/AWAIT means Declaration when scanning for a Declaration (decl_mask & DECL_MASK_OTHER), regardless of an intervening line terminator; only `[` is an unconditional restriction`
- 建议修法：Rewrite canTreatLetAsExpressionStatement to mirror is_let: in a declaration-allowed context, a following `{`, IDENT, `let`, `yield`, or `await` (even across a line terminator) makes `let` a declaration; `[` always makes it a declaration; otherwise it is an expression statement.

### parser-syntax#4 — HIGH · behavior · 有界

Destructuring-assignment default into a MEMBER target (`({y: o.e = 5} = {})`, `({y: o['e'] = 5} = {})`) never assigns the default value; the member is left unset even though the default expression is evaluated.

- **repro**：var o={}; ({y: o.e = 5} = {}); print(o.e); — zjs: `undefined`; qjs: `5`
- zjs：`src/parser.zig:16910-16945 — in the member-target (`.`/`[`) branch of object-pattern destructuring, the default value produced by the keep-value/if_false path is not routed into the value_tmp used by the later put_field/put_array_el store, so the store uses the original (undefined) value`
- qjs：`js_parse_destructuring_element member-target + default handling (quickjs.c around 29438) stores the defaulted value into the member`
- 建议修法：In the member-target destructuring branch, when a default is present, write the post-default value into value_tmp (or otherwise thread it to the get_loc feeding put_field/put_array_el) so the member receives the defaulted value.

### parser-syntax#5 — MEDIUM · behavior · 有界

Class method/getter/setter/field bodies do not run the lexer in strict mode, so strict-only octal lexical errors (legacy octal literals, octal/`\8` string escapes, template octal) are silently accepted inside class bodies.

- **repro**：echo 'class C { m(){ return 08; } } print(new C().m());' — zjs: `8`; qjs: `SyntaxError: octal literals are deprecated in strict mode`
- zjs：`src/parser.zig:14727/15347 set child_fd.is_strict_mode for the FunctionBytecode but the class-method parse paths do not set s.lex.is_strict_mode=true around the method body (unlike the static-block path at 17963), so the number/string tokenizer's `self.is_strict_mode` check (parser.zig:1105/1153/1157/1809) never fires`
- qjs：`class bodies are implicitly strict; lexer octal checks gated on cur_func strict (quickjs.c parse_string / number tokenizer). Static-block init path in zjs already sets lex.is_strict_mode=true (parser.zig:17963)`
- 建议修法：In parseClassElementFunction (and class field initializer parse), save+set `s.lex.is_strict_mode = true` for the duration of the method/field body, mirroring the class-static-block path at parser.zig:17963.

### parser-syntax#6 — MEDIUM · behavior · 有界

`delete` of an optional-chain member (`delete o?.x`, `delete o?.[k]`, `delete p?.y.z`) is a silent no-op: it always returns true without ever removing the property.

- **repro**：var o={x:1}; print(delete o?.x); print('x' in o); — zjs: `true` then `true`; qjs: `true` then `false`
- zjs：`src/parser.zig:7944-7961 parseDelete — the .dotted/.indexed rewrite cases flip get_field->push_atom_value/delete but do not recognize the optional-chain variant of the emitted access, so the delete operand targets the wrong slot and effectively no-ops`
- qjs：`js_parse_delete quickjs.c:27500 — handles OP_get_field_opt_chain / OP_get_array_el_opt_chain by rewriting to OP_delete with the opt-chain label preserved`
- 建议修法：In parseDelete, detect the optional-chain member access shape (as qjs does for OP_get_field_opt_chain / OP_get_array_el_opt_chain) and emit OP_delete with the short-circuit label, returning true on the null-short-circuit path.

### parser-syntax#7 — MEDIUM · behavior · 有界

Lexical/global redeclaration early errors are largely missing: `let x; var x`, `const d=1; var d=2`, `function q(){} let q`, `class h{} var h`, `function z(){} let z` (nested/global), and object-pattern catch `catch({e,e})` are accepted (or throw the wrong runtime error) instead of SyntaxError.

- **repro**：echo 'let x = 1; var x = 2; print(x);' — zjs: `accepted 2`; qjs: `SyntaxError: invalid redefinition of lexical identifier`
- zjs：`src/parser.zig var-declaration path — lexical-vs-var (let-then-var), function-decl-vs-lexical, and class-decl-vs-var conflicts, and object-pattern catch-binding dup, are not checked; only array-pattern catch dup (12118/14286) and some lexical-lexical same-scope cases are`
- qjs：`add_var / find_lexical_decl redefinition checks quickjs.c:24315-24399 (JS_VAR_DEF_LET/CONST/FUNCTION_DECL/VAR conflict detection incl. function-vs-lexical and global-var conflicts)`
- 建议修法：Add the qjs add_var conflict matrix: reject var colliding with an in-scope lexical (let/const/class/function-decl) in either order at function/global body scope, and record object-pattern catch bindings into the same duplicate check already used for array patterns.

### parser-syntax#8 — MEDIUM · behavior · 有界

`typeof async function(){}` (and `typeof <anything> function(){}` in a value position where an unparenthesized function expression follows a keyword operand) fails to parse: zjs reports SyntaxError at the following statement.

- **repro**：echo 'print(typeof async function(){});' — zjs: `SyntaxError ... UnexpectedToken`; qjs: `function`
- zjs：`src/parser.zig:7483-7519 (typeof branch) falls through to parseUnary for the general case, but the `async function` expression operand is not parsed correctly in that path (whereas parenthesized/other positions route differently and succeed)`
- qjs：`js_parse_unary TOK_TYPEOF -> js_parse_unary(PF_POW_FORBIDDEN) -> js_parse_postfix_expr which handles `async function` expression uniformly`
- 建议修法：Ensure the typeof (and other unary) operand parse routes to the same primary/postfix path that recognizes `async function` expressions; likely the async-function lookahead is being suppressed for the typeof operand branch.

### parser-syntax#9 — LOW · behavior · 有界

`import.meta` in non-module (script) code is accepted and evaluated instead of raising the module-only SyntaxError.

- **repro**：printf 'print(import.meta);\n' — zjs: `[object Object]`; qjs: `SyntaxError: import.meta only valid in module code`
- zjs：`src/parser.zig:8969-8984 (guard `!s.lex.is_module or s.is_eval`) — evidently not tripping for script/-e execution; verify is_module/is_eval flags are set on the eval path`
- qjs：`js_parse_postfix_expr TOK_IMPORT '.' quickjs.c:27061 'import.meta only valid in module code'`
- 建议修法：Ensure the script/-e eval entry sets is_module=false and the import.meta guard rejects when not in a module; add a script-mode regression.

### parser-syntax#10 — LOW · behavior · 有界

Module autodetection differs: a LATE `export`/`import` statement (not the first token) is detected as module by zjs but qjs's JS_DetectModule only inspects the FIRST token, so qjs treats such files as scripts and rejects the export/import.

- **repro**：printf 'var x = 1;\nexport { x };\nprint("late-export");\n' as a .js file — zjs: `late-export`; qjs: `SyntaxError: unsupported keyword: export`
- zjs：`src/cli/zjs.zig:425 sourceLooksLikeModule scans the entire token stream for import/export rather than just the first token`
- qjs：`JS_DetectModule quickjs.c:23792 — inspects only the first token (import not followed by . or (, or export)`
- 建议修法：Restrict sourceLooksLikeModule to the qjs rule: after optional shebang, only the FIRST token decides — `import` not followed by `.`/`(` => module, leading `export` => module, else script.

### parser-syntax#11 — LOW · behavior · 有界

BigInt values print without the trailing `n` suffix: `print(10n)` outputs `10` in zjs vs `10n` in qjs's default value printer.

- **repro**：echo 'print(10n)' — zjs: `10`; qjs: `10n`
- zjs：`zjs print() builtin uses the ToString path for BigInt rather than the inspect/print formatter that appends `n``
- qjs：`JS_PrintValue / js_print quickjs.c:4063 (default value formatting appends `n` for BigInt, distinct from ToString)`
- 建议修法：In zjs's print() value formatter, append `n` for BigInt operands (matching JS_PrintValue), keeping String()/toString() unsuffixed.

---

## Function / 全局对象  `[functions-misc-globals]`

> 覆盖说明：Compared zjs HEAD 541c30f vs quickjs 04be246 by aggressive dual-binary probing plus source reading. CONFIRMED CLEAN/ALIGNED: Function constructor output text byte-exact incl. the odd 'function anonymous(a,b\n) {\n...\n}' newline placement, param-injection rejection, anonymous name/length; Function.prototype.toString for source functions, classes, methods, getters, async/generator prefixes, native functions (incl. redefined-name reflection on natives), nameless-native 'function () {' spacing; bind semantics exhaustively (length from getter/non-numeric/NaN, 'bound bound ', non-string name -> 'bo

### functions-misc-globals#0 — HIGH · behavior · 有界

decodeURI/decodeURIComponent corrupt or throw on any input mixing non-ASCII characters with % escapes: latin1 chars 0x80-0xFF cause a spurious URIError, and chars >= U+0100 (incl. astral) are emitted as literal backslash-uXXXX text in the result.

- **repro**：decodeURI("é%41") -> zjs: URIError 'expecting hex digit', qjs: "éA" ; decodeURI("€%41") -> zjs: 7-char literal string "\\u20acA", qjs: 2-char "€A" ; decodeURIComponent("😀%20x") -> zjs 14-char "\\ud83d\\ude00 x", qjs 4-char "😀 x"
- zjs：`src/builtins/uri.zig:164 (decodeStringDataFast) + src/builtins/uri.zig:567 (appendRawString)`
- qjs：`js_global_decodeURI, quickjs.c ~54755`
- 建议修法：Mirror js_global_decodeURI: iterate the string's code units directly, copy non-'%' units through verbatim (build result as utf16-capable string buffer), decode %XX/UTF-8 sequences per qjs; delete the appendValueString/appendRawString \uXXXX-widening fallback for string inputs.

### functions-misc-globals#1 — HIGH · behavior · 有界

zjs has no 65535-argument cap in Function.prototype.apply / Reflect.apply / spread: huge array-like lengths are accepted and fully materialized (effective hang on 2^32) where qjs throws RangeError from build_arg_list.

- **repro**：function count(){return arguments.length}; count.apply(null,{length:65536}) -> zjs OK:65536, qjs RangeError 'too many arguments in function call (only 65534 allowed)'; count.apply(null,{length:Math.pow(2,32)}) -> zjs hangs >2min iterating 4G indices, qjs immediate RangeError. Same divergence for Reflect.apply, f(...new Array(70000)), and apply with a real 70000-element array.
- zjs：`src/exec/call.zig apply/spread arg materialization (no cap present anywhere in src/exec)`
- qjs：`build_arg_list, quickjs.c:41159 (used by js_function_apply:41228, js_reflect_apply:50434, OP_apply_eval:18402)`
- 建议修法：Add the qjs JS_MAX_LOCAL_VARS=65535 check with matching RangeError at zjs's build_arg_list equivalent(s) covering apply, Reflect.apply and spread-call paths.

### functions-misc-globals#2 — MEDIUM · behavior · 有界

Function.prototype.toString on bound functions and callable Proxies omits the function name (and its leading space): zjs never performs qjs's generic Get(this,'name') for sourceless callables, so redefined names are also ignored.

- **repro**：(function foo(){}).bind(null).toString() -> zjs 'function() {\n    [native code]\n}', qjs 'function bound foo() {\n    [native code]\n}'; new Proxy(function named(){},{}).toString() -> zjs 'function() {...}', qjs 'function named() {...}'; var b=(function foo(){}).bind(null); Object.defineProperty(b,'name',{value:'custom'}); b.toString() -> zjs omits, qjs 'function custom() {...}'.
- zjs：`src/exec/call.zig:2652-2664 (functionToStringValue proxy/bound branches)`
- qjs：`js_function_toString, quickjs.c:41335`
- 建议修法：In the proxy and bound branches, pass the actual object and use the generic visible-name lookup (getProperty name, coerce non-string to empty) mirroring js_function_toString, including the space before the name.

### functions-misc-globals#3 — MEDIUM · missing_in_zjs · 有界

The InternalError intrinsic (qjs non-standard native error class) is entirely absent from zjs, and stack overflow throws RangeError 'Maximum call stack size exceeded' instead of qjs's InternalError 'stack overflow'.

- **repro**：function f(){return 1+f()}; try{f()}catch(e){print(e.name, e.message)} -> zjs 'RangeError Maximum call stack size exceeded', qjs 'InternalError stack overflow'; typeof globalThis.InternalError -> zjs 'undefined', qjs 'function'.
- zjs：`src/exec/vm_call.zig:77 (throwRangeErrorMessage 'Maximum call stack size exceeded')`
- qjs：`JS_ThrowInternalError quickjs.c:7767 / js_throw_stack_overflow quickjs.c:7791; InternalError in the native-error class list`
- 建议修法：Add InternalError as a native error class (global ctor + prototype chain like the other NativeErrors) and route stack-overflow/OOM/interrupt throws to it with qjs's messages.

### functions-misc-globals#4 — MEDIUM · zjs_extra · 有界

zjs's globalThis carries 10+ non-qjs globals: atob, btoa, queueMicrotask, navigator, DOMException, gc, TypedArray, DisposableStack, AsyncDisposableStack, SuppressedError, plus Symbol.dispose/Symbol.asyncDispose and console.error/console.warn (qjs console has only log).

- zjs：`src/builtins/registry.zig:848-897`
- qjs：`js_global_funcs / JS_AddIntrinsicBaseObjects global set, quickjs.c ~55000; quickjs-libc.c js_std_add_helpers`
- 建议修法：Decide per-item: either flag-gate the web-API extras (atob/btoa/navigator/DOMException/queueMicrotask/gc) out of the default global and drop the resource-management proposal globals to match qjs 04be246, or record each as an accepted deliberate extra in the divergence catalog.

### functions-misc-globals#5 — MEDIUM · behavior · 有界

print/console.log formatting diverges wholesale: qjs uses the JS_PrintValue inspector for non-string args (objects/arrays/maps/functions/bigint/-0), zjs uses plain ToString.

- **repro**：print([1,[2,"x"]], {a:1}, new Map([[1,2]]), function f(){}, 3n, -0) -> qjs: '[ 1, [ 2, "x" ] ] { a: 1 } Map(1) { 1 => 2 } [Function f] 3n -0' ; zjs: '1,2,x [object Object] [object Object] function f() {\n    [native code]\n} 3 0'
- zjs：`zjs host print/console wiring (src/core/host_function.zig HostGlobalMethod print path)`
- qjs：`js_print, quickjs-libc.c:4063 + JS_PrintValue`
- 建议修法：Port a JS_PrintValue-equivalent value inspector for print/console.log non-string arguments (array/object/map/set/function/bigint/-0 forms).

### functions-misc-globals#6 — LOW · behavior · 有界

Error-message shape diverges in builtin dispatch: all URIError failure modes collapse to 'expecting hex digit', and several builtin-record TypeErrors have empty messages where qjs has specific text.

- **repro**：decodeURI('%C0%80') -> zjs 'expecting hex digit' vs qjs 'malformed UTF-8'; encodeURI('\ud800') -> zjs 'expecting hex digit' vs qjs 'expecting surrogate pair'; encodeURIComponent('\udfff') -> qjs 'invalid character'; decodeURI('%C3x') -> qjs 'expecting %'; Symbol.keyFor('x') -> zjs 'TypeError:' (empty) vs qjs 'not a symbol'; new Symbol() -> qjs 'Symbol is not a constructor'; Boolean.prototype.toString.call(1) -> qjs 'not a boolean'; f.apply(null,1) -> zjs 'not a function' vs qjs 'not a object'; Symbol()+'' -> zjs empty vs qjs 'cannot convert symbol to string'.
- zjs：`src/exec/vm_exception_ops.zig:400`
- qjs：`js_throw_URIError call sites quickjs.c:54748-54898; JS_ThrowTypeError texts in js_symbol_*/js_boolean_*/build_arg_list`
- 建议修法：Give the HostError path a pending-message slot (like ctx.exception message) so builtin bodies can attach qjs's exact strings; split URIError sites into the four qjs messages.

### functions-misc-globals#7 — LOW · behavior · 有界

Bound functions define own properties in order name,length (zjs) vs qjs/spec order length,name, observable via Object.getOwnPropertyNames.

- **repro**：Object.getOwnPropertyNames((function foo(a,b){}).bind(null,1)).join(',') -> zjs 'name,length', qjs 'length,name'
- zjs：`src/exec/call.zig:2349 (createBoundFunction)`
- qjs：`js_function_bind, quickjs.c:41250`
- 建议修法：Swap the two defineOwnProperty calls to define length before name.

---
