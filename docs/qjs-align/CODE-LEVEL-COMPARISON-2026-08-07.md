# zjs × QuickJS 代码级逐条对照梳理（2026-08-07）

基于当前 HEAD `b240f8d9` 的全量源码审计，按子系统逐条对比 QuickJS 参考实现与 zjs
实际实现，标注忠实实现 / 故意偏离 / zjs 自造，并记录基线 `32e881db` 之后的漂移。

分类标记：
- ✅ 忠实实现：语义与机制对应 QuickJS
- ⚠️ 故意偏离：语义目标一致，表示或执行形态不同
- 🔧 zjs 自造：QuickJS 没有的机制

---

## 1. JSValue 值表示

**QuickJS 实现**：`quickjs.h` / `quickjs.c` value macros。64-bit 默认 16-byte payload
+ signed tag；备选 NaN-boxing 为高 32-bit tag + 低 32-bit payload。

**zjs 实现**：`src/core/value.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| 默认 16B 布局 | payload:u64 + tag:i64 | `JSValue` extern struct（`value.zig:129`），`Repr`（`value.zig:146-158`）非 nan_boxing 时 payload+tag，`@sizeOf==16` 断言 | ✅ |
| Tag 语义 | tag -9~8 | `Tag` enum（`value.zig:11-29`），编译期断言顺序与范围（`value.zig:78-103`） | ✅ |
| NaN-boxing 备选 | 高 32-bit tag + 低 32-bit payload | `NanBox`（`value.zig:37-127`），48-bit payload window 自定义 dense encoding | ⚠️ 语义守卫，非 bit-for-bit ABI |
| abi revision | 无 | `abi_encoding_revision`（`value.zig:144`），nan_boxing=3 / default=1 | 🔧 |
| 访问器封装 | C macros 直接操作 | 方法封装字段访问 | ⚠️ |

**漂移**：无。

---

## 2. Runtime / Context

**QuickJS 实现**：`JSRuntime`（单线程 owner）、`JSContext`（realm 隔离），持
atom/class/shape/GC/job/module/exception/interrupt 状态。

**zjs 实现**：`src/core/runtime.zig`、`src/core/context.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| `JSRuntime` 核心状态 | atom/class/shape/GC/job/module/exception/interrupt | `runtime.zig:767` `JSRuntime`：`hot`/`memory`/`gc`/`atoms`/`classes`/`shapes`/`current_exception`/`current_exception_uncatchable` | ✅ |
| `JSContext` realm 隔离 | global/intrinsic 隔离 | `context.zig:447` `JSContext`：header refcounted、runtime list、`modules`、`class_prototypes`、`native_error_prototypes`、initial shapes、`interrupt_counter` | ✅ |
| HotExecState | C 栈深度跟踪 | `runtime.zig:819` `hot: HotExecState align(64)`：call_depth、native_call_depth、active_bytecode_stack_bytes、native_stack_guard、stack_size | ✅ |
| malloc_gc_threshold | `js_trigger_gc` 阈值 | `runtime.zig:917`，commit `a66d2576` 对齐 qjs 触发点 | ✅（基线后对齐） |
| HandleScope/Local/Persistent | 无（显式 Dup/Free + C 栈扫描） | `runtime.zig:450-620` `RootProvider`/`RootSlot`/`HandleScope`/`LocalHandle`/`JSValueHandle`/`WeakPersistentValue` | 🔧 embedding 扩展 |
| Root provider / active roots | 无 | `runtime.zig:868-877` root_providers/local/persistent/weak slots、active_value_roots | 🔧 |
| Deferred cleanup 队列 | 无 | `runtime.zig:884-893` deferred_native_cleanups/class_payload_finalizers/weak_value_frees | 🔧 |
| VmStackArena | C 栈 alloca | `runtime.zig:934` `VmStackArena align(64)` | ⚠️ heap arena 替代 C 栈 |
| Runtime string caches | 无同形 | `runtime.zig:948-950` single_byte_strings[128]、recent_atom_string | 🔧 对齐策略债 |
| External host function registry | 无 | `runtime.zig:962` external_host_functions | 🔧 |
| SimpleCtorMemo | 无 | `runtime.zig:853` `simple_ctor_memo: SimpleCtorMemo`（最多 8 字段模式） | 🔧 **基线 P0 删除候选，仍存在** |
| UnhandledRejectionEntry | qjs CLI 有 | `context.zig:480` | ✅ |

**漂移**：`a66d2576` 对齐 allocation-threshold GC 触发点。SimpleCtorMemo 仍存在。

---

## 3. Allocator / RC / GC

**QuickJS 实现**：`JSMallocBlockHeader` 8B allocator metadata、`JSGCObjectHeader` 16B
intrusive GC header、`__js_rc` 4B flat string RC prefix、非原子 RC + trial-deletion
循环回收、非移动单线程。

**zjs 实现**：`src/core/memory.zig`、`src/core/gc.zig`（3,868 行）

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| allocator metadata prefix | `JSMallocBlockHeader` 8B | `memory.zig:105` `BlockHeader` 8B（index_or_next + block_size_idx）；`gc.zig:406` `Metadata` 8B（size_class + alloc_info + flags + rc） | ✅ |
| intrusive GC header | `JSGCObjectHeader` 16B | `gc.zig:443` `BlockHeader` 16B（prev/next 链） | ✅ |
| flat string RC prefix | `__js_rc` 4B | `gc.zig:479` `RefCountHeader` 4B = `StringHeader` | ✅ |
| object refcount | allocator block header | `Metadata.rc` 位于 payload-4 | ✅ |
| slab allocator | qjs malloc | `memory.zig:93` `SmallObjectSlab`：4KB arena、max 512B、31 size classes（16~512） | ⚠️ slab 与 metadata 叠合 |
| slab BlockHeader | qjs 一次 per-arena | zjs 每次 GC 分配 stamp `block_size_idx` | ⚠️ |
| MemoryAccount | 基于 allocator usable size | `memory.zig:393`：allocated_bytes/allocation_count/peak/limit/trigger_gc_fn | ⚠️ 逻辑 limit 触发边界可能不同 |
| RC 即时释放 | 非原子 RC | ✅ 同 | ✅ |
| zero-ref 收集 | zero-ref 队列 | `gc.zig:1743` `enqueueZeroRef`、`gc.zig:1712` `drainZeroRefs`、`beginDecrefPhase`/`endDecrefPhase` 批处理 | ✅ |
| 循环回收 trial-deletion | 三阶段：decref → scan → restore | `object.zig:7521` `destroyRuntimeCyclesWithValueRoots`：Phase 1 `DecrefVisitor`（`7531-7548`）→ Phase 2 `ScanIncrefVisitor`（`7550-7565`）→ Phase 3 `ScanRestoreVisitor`（`7567-7573`） | ✅ |
| 临时列表 | gc_obj_list/tmp_obj_list | `gc.zig:523` `HeaderList`（allocation-free 临时链表） | ⚠️ |
| cycle_visited 标记 | list membership | `Metadata.flags.cycle_visited` | ⚠️ |
| Phase enum | 无显式 | `gc.zig` `.none/.decref/.remove_cycles/.deinit/.cycle` | 🔧 |
| GC Policy 并发/分代 | 无 | `gc.zig:54-56` `enable_concurrent_mark/sweep/selective_evacuation` 均默认 false | 🔧 占位，不可写成已实现 |
| GC Policy mode | 无 | `gc.zig:29` `.balanced/.throughput/.low_rss/.low_latency`，各有 growth_factor/budget/cleanup_jobs 默认 | 🔧 |
| external memory token / RSS | 无 | `gc.ExternalMemoryToken`、Policy 中 external_soft/hard_limit、rss_soft/hard_limit、cgroup ratios | 🔧 |
| OOM 注入 / recovery canary | 无 | `src/tests/oom.zig`/`oom_cap.zig` | 🔧 |
| allocation_gc_trigger_enabled | 无 | comptime flag，生产跳过 per-allocation GC check | 🔧 |
| RefKind enum | 无显式 | `gc.zig:140` u3：object=0/function_bytecode=1/var_ref=2/realm_context=3/module=4/shape=5/string=6/big_int=7 | ⚠️ |

**漂移**：无结构性漂移。`a66d2576` 对齐 GC 触发点。

---

## 4. Weak lifecycle

**QuickJS 实现**：`weakref_count` + weakref header/list + 对象地址生命周期，无 ABA
保护。

**zjs 实现**：`src/core/runtime.zig:902-916`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| weak identity | weakref_count + 地址 | `runtime.zig:907-909` 单调 `weak_id` + 双 hash table（addr→id, id→object） | ⚠️ 避免 ABA，O(1) 查询 |
| deferred weak free | 无 | `runtime.zig:893` deferred_weak_value_frees | 🔧 |
| weak cleanup identity set | 无 | `runtime.zig:896-901` borrowed_weak_cleanup_identities + set | 🔧 |
| weak holder intrusive list | weakref list | `runtime.zig:851-852` weak_reference_holder_head/tail | ⚠️ |

**漂移**：无。

---

## 5. String / Atom / Unicode

**QuickJS 实现**：`JSString` 12B body + latin1/UTF-16 flat payload + 4B RC prefix；
`JSAtomStruct` 就是带 atom metadata/hash chain 的 `JSString` body；rope
concatenation with depth-based flatten/rebalancing。

**zjs 实现**：`src/core/string.zig`（3,344 行）、`src/core/atom.zig`（3,875 行）

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| flat string body | `JSString` 12B | `string.zig:222` `String`：`len_meta`（u32: len:u31 + is_wide:bool）、`hash_meta`（u32: hash:u30 + atom_type:u2）、`atom_id`（u32 回指） | ✅ |
| RC prefix | `__js_rc` 4B | `gc.StringHeader` 4B at stringPtr-4 | ✅ |
| latin1/UTF-16 | 两种 payload | `LenMeta.is_wide` 区分 | ✅ |
| rope | `JSStringRope` left/right/depth | `string.zig:39-100` `StringRope`：left/right/rt/len/depth/wide/flags | ✅ |
| rope flatten | depth-based | `string.zig:148` `flatten()` materialize 到 flat，缓存 in left（depth=0），释放 children | ✅ |
| rope rebalance | depth-based | `String.rope_max_depth` 超限时 rebalance | ✅ |
| atom = string body | `JSAtomStruct` 就是 `JSString` | `atom.zig:851` `DynamicAtom` 与 `String` 分离：bytes/str(惰性)/hash/hash_next/kind/ref_count | ⚠️ 降低耦合但增加双份 metadata 风险 |
| atom hash chain | `hash_next` 字段 | `atom.zig:871` `hash_next`，commit `aaa804af` 镜像 qjs chained hash；`chainInsert`（`1215`）/`chainUnlink`（`1231`） | ✅（基线后对齐） |
| AtomTable | — | `atom.zig:974`：entries[]、atom_hash[]（power-of-two buckets）、atom_hash_count、atom_count_resize=2*buckets、predefined_hash_next[]、free_slot_head | ✅ |
| predefined atoms | — | comptime `predefined_atoms`（1-656），`predefined_str[]` 缓存 strings，`isConst()` 免 refcount | ✅ |
| atom-to-string materialization | 直接 dup body | `cacheString`/`cachedString`/`toStringValue` 惰性 materialize | ⚠️ |
| ownership_audit | 无 | `atom.zig` `OwnershipAuditState` quarantine | 🔧 |
| RopeTailState | 无 | `string.zig:198-206` sidecar：`data` union(latin1/utf16) + len，用于 fused `add_loc` accumulator | 🔧 对齐策略债 |
| runtime string caches | 无同形 | `runtime.zig:948` single_byte_strings[128] + recent_atom_string + 其他（two-unit/%XX/small-int） | 🔧 对齐策略债 |
| StringHash | — | `hash_meta.hash` 缓存（0=未计算），rope hash 无需 materialize | ✅ |

**漂移**：`aaa804af` 把 atom hash 改为 qjs chained hash——已确认 `hash_next` 字段和
`chainInsert`/`chainUnlink`，注释 "QuickJS's chained table, mirrored"。

---

## 6. Object / Shape / Property / Proxy

**QuickJS 实现**：`JSObject` 64B、`JSShape` 56B（FAM: [hash buckets][ShapeProperty
array]）、`JSProperty` 16B、无 inline cache。

**zjs 实现**：`src/core/object.zig`（23,494 行）、`src/core/shape.zig`（1,996 行）、
`src/core/property.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| `JSObject` 64B | 16B GC header + 8B metadata + shape/prop + 24B class union | `object.zig:1809` `Object` extern struct，`@sizeOf==64` 断言：header(16) + weakref_count(4) + class_id(4) + flags(2) + pad(6) + shape_ref(8) + prop_values(8) + u:ObjectStorage(24) | ✅ |
| ObjectStorage union | bare union + discriminant | `object.zig:1795` `ObjectStorage` extern union：payload/array/bytecode_function/regexp | ✅ |
| `JSShape` 56B | 56B header | `shape.zig:57` `Shape` extern struct，`@sizeOf==56` 断言：header(16) + is_hashed(1) + hash(4) + prop_hash_mask(4) + prop_size(4) + prop_count(4) + deleted_prop_count(4) + registry_hash_next(8) + proto(8) | ✅ |
| Shape FAM 顺序 | `[56B][hash buckets][ShapeProperty array]` | `[56B][ShapeProperty array][hash buckets]`（props first） | ⚠️ props 常量偏移 vs qjs buckets 常量偏移 |
| ShapeProperty | 12B | `shape.zig:30-34` `Property` packed struct(u64)：hash_next:u26 + flags:u6 + atom_id:u32 = 8B | ⚠️ 更紧凑 |
| prop_size | 从 prop_count 推导 | 显式 `prop_size` 字段 | ⚠️ |
| deleted_prop_count | — | 显式跟踪 | 🔧 |
| `JSProperty` 16B | value slot | `property.zig:436` `Entry`：Slot union 默认 16B JSValue | ✅ |
| Property Flags | JS_PROP_TMASK | `property.zig:20-92` 6-bit packed：writable/enumerable/configurable/kind/deleted | ✅ |
| Accessor | getter/setter pair | `property.zig:98-160` `Accessor` | ✅ |
| deletion/tombstone | qjs tombstone | `Flags.deleted` | ✅ |
| inline cache | 无 | `src/exec/property_ic.zig`——**文件名历史遗留**，`cachedSetObjectDataPropertyForPutFastPath` 恒返回 false，实际是 shape/hash 直接快路 | ✅（无 IC，与 qjs 一致） |
| ExoticMethods vtable | class-specific logic | `object.zig:82` `ExoticMethods` struct（get_own_property/define_own_property/delete_property/own_keys），`exoticMethodsForClassId`（`1772`）——当前标准类均返回 null，Proxy/Array/TypedArray exotic 在 property access 路径中 class-specific 处理 | ⚠️ |
| DenseArrayStorage | fast array union | `object.zig:1784`：values ptr + count + capacity + length + padding = 24B | ✅ |
| `.length` 存放 | shape/property slot | `DenseArrayStorage.length` 标量 | ⚠️ 避免属性槽读取 |
| sort 算法 | qjs sort | `array_ops.zig:5103` `stableArraySortEntries` merge sort | ⚠️ 不同比较器调用序列 |
| BufferPayload | `JSArrayBuffer` inline union | `object.zig:467` out-of-line：bytes + inline_bytes[32] + shared_store + external_memory + detached/immutable + max_byte_length + first_view | ⚠️ 额外间接层 |
| TypedArrayPayload | `JSTypedArray` in view list | `object.zig:567`：buffer/byte_offset/element_size/fixed_length/kind/live_length/data/backing_payload/buffer_prev/buffer_next | ⚠️ doubly-linked view list |
| view cache invalidation | 直接 union 访问 | `BufferPayload.invalidateViews/updateViews` 显式失效 | ⚠️ |
| immutable ArrayBuffer | 无 | `typed_array.zig:160` `sliceToImmutable`/`transferToImmutable` | 🔧 |
| SuspendedExecutionState | detached `JSStackFrame` | `object.zig:1116`：pc/storage/catch_target_pc/has_frame/running_aliases/resident_storage_owner | ⚠️ |
| GeneratorExecutionState | `JSAsyncFunctionState` | `object.zig:1215`：suspended/this_value/current_function/yield_star_iterator/actual_arg_count/combined_stack_slots/combined_frame_metadata | ⚠️ |
| iteratorTargetSlot | 无 | `object.zig:3594` 缓存 iterator target | 🔧 |
| iteratorNextSlot | 无 | `object.zig:3711` 缓存 next method | 🔧 |

**漂移**：无。

---

## 7. Parser

**QuickJS 实现**：`JSParseState` monolith 贯穿产生式，lexer/parser/emitter 集中在
`quickjs.c`。

**zjs 实现**：`src/parser.zig`（20,688 行）

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| monolith 结构 | `JSParseState` | `parser.zig:4035` `State` struct，字段直接对应：lex/function/token/function_def/cur_func_stack/scope_level/is_strict/is_eval/eval_ret_idx/top_break 等 | ✅ |
| Lexer | 内嵌 | `parser.zig:309` `LexerImpl`：allocator/atoms/source/pos/line/col/is_strict_mode/is_module/got_lf | ✅ |
| token kind 值 | `quickjs.c:21246` TOK_* | `parser.zig:76-181` 精确整数对齐（`TOK_NUMBER=-128`，keyword block `TOK_NULL..TOK_AWAIT` 对应 atom 映射） | ✅ |
| next_token | `next_token` | `parser.zig:478` `nextInto`，`nextIntoReplacing`（`421`）释放 payload 再覆写避免 tagged union 写 | ✅ |
| parseFunctionDecl | `js_parse_function_decl` | `parser.zig:15127`，处理 generator/async，retain name atom | ✅ |
| parseFunctionParamsAndBody | — | `parser.zig:15571`，调 `parseFunctionParameters`（`15346`） | ✅ |
| parseStatementOrDecl | `js_parse_statement_or_decl` | `parser.zig:12844`，function decl fast-path，`parseStatementOrDeclSlow`（`12871`） | ✅ |
| parseClass | `js_parse_class` | `parser.zig:18928`，strict mode for ClassTail，class-name scope | ✅ |
| ASI | — | `parser.zig:5576` `expectSemicolon`：line terminator / EOF / `}` | ✅ |
| postfix ++/-- ASI | — | `parser.zig:9365` 用 `lex.got_lf` | ✅ |
| strict mode errors | — | legacy octal（`1221`）、future reserved words（`2023`）、duplicate lexical（`15760`）、invalid binding names（`16012`）、duplicate params（`16017`） | ✅ |
| 源码位置 | line/col | `Position` struct（offset/line/column），`source_line_starts` O(1) 转换缓存 | ✅（zjs O(1) 优化） |
| TypeScript erasure | 无 | `parser.zig:359` `enableTypeScript`/`markTypeRanges`（`2090`）/`tsTokenize`：type-only statements、mixed type specifiers、class/type modifiers、implements clauses、function overload signatures、type parameters、type annotations、type assertions、non-null assertions；`.ts/.mts/.cts/.tsx` | 🔧 |
| 不支持语法检测 | — | decorators `@`、CommonJS `import =`/`export =`（`2119`） | 🔧 |

**漂移**：`d7c91d36` 对齐 V2 frontend code-load pipeline。

---

## 8. Bytecode / FunctionBytecode

**QuickJS 实现**：`JSFunctionDef` → resolve/optimize/finalize → pack
`JSFunctionBytecode`（96B core + 32B DebugInfo tail）。

**zjs 实现**：`src/bytecode.zig`（10,239 行）

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| opcode 0-243 | qjs 主表 263 entries | `bytecode.zig:653` metadata 表精确对齐，`Info` struct（name/size/n_pop/n_push/fmt），`CompactInfo` 4B 匹配 qjs `JSOpCode` | ✅ |
| temp/short opcode 重叠 | — | temp: enter_scope(192)..scope_in_private(199)；short: push_minus1(192)..set_loc8(199)；`finalInfo`（`717`）解析为 short，`phase1Info`（`748`）解析为 temp | ✅ |
| using opcodes 244-247 | 无 | `bytecode.zig:342-345` `using_create_stack`/`add_resource`/`dispose_stack`/`dispose_stack_for_throw` | 🔧 explicit resource management |
| operand formats | — | `Format` enum（none/u8/i8/loc8/const8/label8/u16/i16/label16/npop/npopx/loc/arg/var_ref/u32/i32/const/label/atom/atom_u8/atom_u16/atom_label_u8/atom_label_u16/label_u16） | ✅ |
| `FunctionBytecode` 96B | `JSFunctionBytecode` | `bytecode.zig:1656` extern struct：header(16) + js_mode/flags(4) + call_facts_mirror(2) + pad(2) + byte_code(8) + byte_code_len(4) + func_name(4) + vardefs(8) + closure_var(8) + arg/var/defined_arg/stack_size/var_ref_count(10) + pad(6) + realm(8) + cpool(8) + cpool_count(4) + closure_var_count(4) | ✅ |
| `DebugInfo` 32B | qjs inline optional | `bytecode.zig:1558` extern struct：filename(4) + source_len(4) + pc2line_len(4) + pad(4) + pc2line_buf(8) + source_ptr(8) = 32B | ✅ |
| `FunctionBytecodeHotExtension` | 无 | `bytecode.zig:1635` 8B：call_facts(2) + pad(2) + script_or_module(4) | 🔧 |
| `FunctionDefImpl` | `JSFunctionDef` | `bytecode.zig:2959`：memory/atoms/parent/flags（is_eval/is_global_var/is_module/...）、func_kind、vars/args/scopes/labels/cpool/closure_var/jump_slots/source_loc_slots、`v2_builder`（QCP-1 stage 2P）、`closure_var_may_have_dynamic_env`（zjs monotone flag） | ✅ + 🔧 |
| pipeline createFunctionBytecode | — | `bytecode.zig:8608`：validateRuntimeIdentity → installChildFunctionBytecodes → createFunctionBytecodeAfterChildren | ✅ |
| lowerAttachedBuilder | — | `bytecode.zig:8904`：调 `compiler_v2.compileFunctionV2`，consumeGlobalVars，publishLoweredMetadata | ✅ |
| tail_call / tail_call_method | qjs 有但不 emit proper PTC | zjs 同 | ✅ |

**漂移**：`96cf3af1` 对齐 S4 opcode row and label frontier。

---

## 9. Compiler V2

**QuickJS 实现**：`JSFunctionDef` DynBuf resolved/optimized/finalized → pack
`JSFunctionBytecode`。单编译路径。

**zjs 实现**：`src/compiler_v2/`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| 单编译路径 | DynBuf → resolve → finalize → pack | `root.zig:53` `compileFunctionV2` → `resolve_variables.run` → `resolve_labels.run` | ✅ |
| **legacy compiler 已删除** | — | commit `7877c3bf` 删除；`build.zig:23` `compiler_name="v2"` 硬编码；`tools/architecture/check_legacy_pipelines_gone.js` 门禁验证 retired tokens（`pipeline_resolve_variables`/`pipeline_resolve_labels`/`lowerLegacyPhase1`/`runPhases`）零符号 | ✅（基线后完成） |
| Builder | DynBuf | `builder.zig:141` `Builder`：code/atom_operands/label_slots/relocs/control_index/source_slots/last_opcode_pos | ⚠️ |
| LabelId | absolute PC | `labels.zig:15` `LabelId` enum(u32)，parser 从不 emit absolute-PC jump，resolve_labels 一次性分配最终位置 | ⚠️ identity-native |
| LabelFlags | — | `labels.zig:28` bound/backward_target/match_barrier | 🔧 |
| RelocEntry | — | `labels.zig:68` next/operand_offset/kind（jump32/aux32） | ⚠️ |
| CFG | qjs 有 CFG | `cfg.zig:1362` `build`：从 read-only Builder 构建 immutable LabelId CFG | ⚠️ instruction-granularity |
| Oracle | 无 | `cfg.zig:50-98` Debug/ReleaseSafe only，comptime erased in ReleaseFast；6 diff buckets：boundary/ownership/binding/cfg/continuation/source_event | 🔧 |
| resolve_variables | qjs scope resolution | `resolve_variables.zig:2477` `run`：Pass A build CFG + Pass B delegate binding_rules；`ResolvedProduct` transactional output with atom ownership | ⚠️ exact LabelId block-CFG liveness vs ref_count |
| PendingTailRewrite | 无 | `resolve_variables.zig:170` make_ref folding | 🔧 |
| resolve_labels | qjs jump threading | `resolve_labels.zig:3248` `run`：single forward pass + relocation chains，jump threading（ref_count==0 且无 match_barrier 时 fold），pc2line 直接生成 | ⚠️ |
| LayoutMode | — | `resolve_labels.zig:20` `.plain/.short`，`default_layout` 从 `build_options.zjs_v2_layout` 读取，生产=short | ⚠️ |
| finalAliasSplit | — | `resolve_labels.zig:129` alias liveness split detection | 🔧 |
| Snapshot/Rollback | — | `builder.zig:131` `Snapshot`：code_len/atom_len/label_len/reloc_len/control_len/source_len | 🔧 |

**漂移**：**重大变化**——legacy compiler 完全删除，V2 是唯一编译器。

---

## 10. VM / Frame / Call / Eval / Exception

**QuickJS 实现**：递归 `JS_CallInternal`，C 栈 locals via `alloca`，
switch/computed-goto handler。

**zjs 实现**：`src/exec/zjs_vm.zig`、`src/exec/inline_calls.zig`、
`src/exec/tailcall_dispatch.zig`、`src/exec/vm_call.zig`、`src/exec/call.zig`、
`src/exec/construct.zig`、`src/exec/call_runtime.zig`、`src/exec/vm_*.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| VM 入口 | `JS_Eval`/`js_eval_internal` | `zjs_vm.zig:36` `run`、`runWithOutput`（`44`）、`runWithCallEnv`（`166`）、`contextGlobal`（`187`）lazy global | ✅ |
| Vm struct | C 栈 locals | `tailcall_dispatch.zig:94` `Vm`：ctx/function/global/frame/stack/machine/output/code_base/rt | ⚠️ |
| 执行循环 | monolithic switch | `tailcall_dispatch.zig:4279` `dispatch_table`：256-entry static handler table，`@call(.always_tail, dispatch_table[pc[0]])` | ⚠️ per-opcode handler functions |
| Machine | — | `inline_calls.zig:87-186` `Machine`：chunked entry storage，pushFrame/popFrame | ⚠️ |
| Frame | C 栈 `alloca` | `frame.zig:15` `FrameSlab` typed windows（args/locals/stack/var_refs）；`stack.zig:7` `Stack` arena | ⚠️ heap-resident for generator |
| Frame sizing | `alloca_size` | `vm_call.zig:139` `qjsBytecodeFrameAllocaSize`：allocated_arg_count + var_count + stack_size，× JSValue + var_ref_count × VarRef | ✅ |
| call depth guard | stack guard | `vm_call.zig:92` `enterCallDepth`：native_call_depth/call_depth/bytecodeStackBudget 检查 | ✅ |
| op_call_method | `OP_call_method` | `tailcall_dispatch.zig:1597`：syncPc → read argc → objectFromValue → resolveInlineFunctionFromObject → inline fast path / native dispatch | ✅（`b240f8d9` 对齐） |
| op_tail_call_method | `OP_tail_call` | `tailcall_dispatch.zig:2131`：publish → tailCallMethod → handled/return_value/tail_inline | ✅ |
| op_drop_fast | — | `tailcall_dispatch.zig:2184` frameless drop | 🔧 |
| property_tail_table | — | `tailcall_dispatch.zig:4301` 13 个 property tail handlers | 🔧 |
| callValue | `JS_CallInternal` | `call.zig:97` `callValue`、`callValueWithThisAndGlobals`（`126`）、`callBoundFunction`（`312`）、`callHostFunction`（`342`）、`callValueOrBytecodeRoot`（`382`） | ✅ |
| constructValue | `JS_CallConstructor` | `construct.zig:83`：prototype resolution → TypedArray fast path → builtin record dispatch → name cascade | ✅ |
| leaf frame 分类 | 无 | `inline_calls.zig` `pushEmptyLeafFrame`（`640`）/`pushExactArgsLeafFrame`（`720`）/`pushCaptureLeafFrame`（`810`）/`pushPaddedArgsLeafFrame`（`900`）；`LeafThis` enum（sloppy_global/raw_undefined/receiver） | 🔧 **基线 P0 删除候选，仍存在** |
| published leaf bit | 无 | 函数发布时标记 leaf eligibility | 🔧 |
| forwarded Function.prototype.call | 无 | `inline_calls.zig:4088-4187` `finishForwardedEmptyLeafFrame`/`tryPushForwardedEmptyLeafCallFast`：`fn.call(undefined, ...)` warm path | 🔧 **基线 P0 删除候选，仍存在** |
| simple-field constructor memo | 无 | `call_runtime.zig:2911` `ensureSimpleCtorMemo`（scan bytecode once）、`2931` `constructSimpleFieldConstructor`（skip body，直接 create instance + defineOwnProperty）、`2993` `simpleFieldConstructorPattern`（scan: push_this; (get_loc0; get_argN; put_field)*; return_undef） | 🔧 **基线 P0 删除候选，仍存在** |
| direct eval | 捕获 caller bindings 为 closure refs | `eval_ops.zig:75` `createDirectEvalClosureSeed`：caller frame overlay/name pre-scan | ⚠️ 语义风险 |
| exception 传播 | C 栈传播 | `exceptions.zig` Zig error union + runtime pending exception | ⚠️ |
| throwTop | `OP_throw` | `vm_control.zig:99`：pop value → close for-of iterators → catch marker stack → catch_target 或 throwValue | ✅ |
| returnTop | `OP_return` | `vm_control.zig:25`：move ownership off stack → `finishFunctionReturn`（derived constructor 特殊处理） | ✅ |
| jump/branch | `OP_goto`/`OP_if_true`/`OP_if_false` | `vm_control.zig:57-97` `jump32`/`jump16`/`jump8`/`branch32`/`branch8` | ✅ |
| arithmetic | `js_add`/`js_binary_arith` | `vm_arith.zig:16` `binary`：Int32 fast path → Short BigInt fast path → string concat fast path → toPrimitive coercion → value_ops.binary | ✅ + 🔧 fast paths |
| compare | `js_relational_slow`/`js_eq_slow` | `vm_arith.zig:89` `compare`：Int32 fast path → Short BigInt fast path → looseEqual/strictEqual/toPrimitive | ✅ + 🔧 fast paths |
| compareAt | — | `vm_arith.zig:169` register-resident slow compare | 🔧 |
| push* opcodes | `OP_push_*` | `vm_value.zig:22-130` pushInt32Operand/pushI16Operand/pushI8Operand/pushSmallInt/pushUndefined/pushNull/pushBoolean/pushConst/pushConst8/pushAtomValue/pushPrivateSymbol/pushEmptyString/pushThis | ✅ |
| typeOf | `js_operator_typeof` | `vm_value.zig:185`：预定义 atom 字符串 | ✅ |
| toObject | `OP_to_object` | `vm_value.zig:156` | ✅ |
| property get/put/delete | `OP_get_field`/`OP_put_field` | `vm_property_field.zig:135` `toPropKey`、`206` `getOwnProperty`、`252` `putOwnProperty`、`302` `deleteProperty`、`342` `inOperator`、`382` `instanceofOperator` | ✅ |
| get_loc/put_loc/set_loc | `OP_get_loc`/`OP_put_loc` | `vm_property_locals.zig:95` `loc`：get_loc/put_loc/set_loc + get_loc0/1/2/3 variants，调 `slot_ops.execGetLoc`/`execPutLoc`/`execSetLoc` | ✅ |
| get_arg/put_arg | `OP_get_arg`/`OP_put_arg` | `vm_property_locals.zig:141` `arg` | ✅ |
| var_ref | `OP_get_var_ref`/`OP_put_var_ref` | `vm_property_locals.zig:160` `varRef` | ✅ |
| get_var/put_var | `OP_get_var`/`OP_put_var` | `vm_property_globals.zig:159` `getVar`、`179` `putVar`、`119` `getVarFromGlobalObject`（strict lexical → global data → hasObjectBinding → ReferenceError）、`199` `getGlobalData`、`232` `putGlobalData` | ✅ |
| private field | `OP_get_private_field` | `vm_property_private.zig:36` `getPrivateField`、`70` `putPrivateField`、`105` `definePrivateField` | ✅ |
| with-statement | `OP_with_get_var`/`OP_with_delete` | `vm_property_ref.zig:34` `withGetOrDelete`：has_binding → unscopables → get/delete | ✅ |
| makeRef/getRef/putRef | `OP_make_ref`/`OP_get_ref_value` | `vm_property_ref.zig:145` `makeSlotRef`、`179` `makeVarRef`、`222` `getRefValue`、`252` `putRefValue` | ✅ |
| closeLoc | `OP_close_loc` | `vm_property_locals.zig:179` `closeLoc` | ✅ |
| catch marker stack | — | `vm_control.zig:99` `throwTop` 中 `popCatchMarker` array-based catch target restoration | ⚠️ |

**漂移**：`b240f8d9` 对齐 call_method dispatch 和 array-length fast path。P0 非 qjs
调用机制（leaf frame 分类、forwarded call leaf、simple-field constructor memo）全部
仍存在。

---

## 11. Modules

**QuickJS 实现**：`JSModuleDef` 含 link/eval DFS index/ancestor/stack、async
parent/pending/cycle root/promise capability/cached exception/import.meta。

**zjs 实现**：`src/core/module.zig`、`src/exec/module.zig`、
`src/exec/module_graph.zig`、`src/exec/vm_eval_module.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| ModuleRecord | `JSModuleDef` | `module.zig:311`：status/module_name/requests/imports/exports/indirect_exports/star_exports/import_attributes/func_obj/module_ns/dfs_index/dfs_link/synthetic_kind/has_top_level_await | ✅ |
| Status enum | `JSModuleState` | `module.zig:13` unlinked/linking/linked/evaluating/evaluated/errored | ✅ |
| RequestEntry | — | `module.zig:33` resolved module request | ✅ |
| ImportEntry | — | `module.zig:38` var_idx + namespace flag | ✅ |
| ExportEntry | — | `module.zig:53` retained_cell for live binding | ✅ |
| IndirectExportEntry | — | `module.zig:60` re-export with namespace | ✅ |
| StarExportEntry | — | `module.zig:70` | ✅ |
| ResolvedBinding | — | `module.zig:80` binding identity + normalization | ✅ |
| resolveExport | `js_module_resolve_export` | `module.zig:641` ambiguity detection | ✅ |
| resolveImport | `js_module_resolve_import` | `module.zig:709` | ✅ |
| linkModuleGraph | `js_module_link` | `module.zig:247` DFS-based linking with cycle detection，LinkState with DFS indices，LinkDiagnostic | ✅ |
| evaluateModuleGraph | `js_module_evaluate` | `module.zig:341` post-order DFS evaluation，returns LinkDiagnostic，handles TLA | ✅ |
| async SCC | qjs job queue | `module_graph.zig:38` `ModuleContinuation`、`30` `ModuleEvalStep` union（completed/suspended） | ⚠️ explicit continuation struct |
| dynamic import | `js_dynamic_import` | `module_graph.zig:100` `DynamicImportState`、`449` `evaluateImportCall`；`vm_eval_module.zig:90` `dynamicImport` opcode handler | ⚠️ separate state object |
| import attributes | — | `module.zig` ImportAttributeEntry，支持 type: json/text | 🔧 |
| 序列化 `JS_WriteObject`/`JS_ReadObject` | 有 | **无** | 🔧 缺失 |
| `JS_EvalFunction`/`qjsc` AOT | 有 | **无** | 🔧 缺失 |
| C module init ABI | 有 | **无** | 🔧 缺失 |

**漂移**：无。

---

## 12. Promise / Jobs / Generator / Iterator

**QuickJS 实现**：generic `JSJobEntry` FAM + promise records；heap detached
`JSStackFrame` + `JSAsyncFunctionState`；IteratorRecord per-operation next。

**zjs 实现**：`src/core/jobs.zig`、`src/core/promise.zig`、`src/exec/promise_ops.zig`、
`src/exec/promise_builtin_ops.zig`、`src/exec/async_generator.zig`、
`src/exec/vm_gen_async.zig`、`src/exec/iterator_ops.zig`、
`src/exec/iterator_builtin_ops.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| Job entry | generic `JSJobEntry` FAM | `jobs.zig:132` `Job` + `117` `Payload` tagged union：generic/promise/promise_reaction/promise_thenable/promise_settlement/dynamic_import/atomics_waiter/finalization | ⚠️ typed union |
| PromiseReactionPhase | — | `jobs.zig:24` invoke/resolve/reject | ⚠️ |
| PromiseThenablePhase | — | `jobs.zig:45` prepare/invoke/reject | ⚠️ |
| OOM transactional commit | 无 | `jobs.zig:219` `initPromiseSettlementNoFail`：allocation-free continuation after FIFO slot reservation；once-guard | 🔧 |
| promise construct | `js_promise_resolution` | `promise.zig:20` `construct`/`24` `constructWithPrototype`/`35` `fulfilledWithPrototype`/`54` `rejectedWithPrototype` | ✅ |
| markHandled | `js_std_promise_rejection_tracker` | `promise.zig:184`：removeUnhandledPromiseRejection | ✅ |
| staticCall | `js_promise_call` | `promise.zig:138` `staticCall`/`staticCallWithPrototype`，LegacyStaticMethod enum dispatch | ✅ |
| promiseAll/Race/AllSettled/Any | — | `promise.zig:236`/`282`/`314`/`362` | ✅ |
| withResolvers | — | `promise.zig:421` | ✅ |
| Promise.allKeyed/allSettledKeyed | 无 | `promise.zig:449`/`514`，`promise_builtin_ops.zig:24-25` internal_entries | 🔧 |
| promiseResolveCall | `JS_PromiseResolve` | `promise_builtin_ops.zig:52` specialized handler | ✅ |
| promiseStaticCall | magic dispatch | `promise_builtin_ops.zig:72` single handler with PromiseStaticMode switch | ✅ |
| generator State | `JSAsyncGeneratorStateEnum` | `async_generator.zig:44` suspended_start/suspended_yield/suspended_yield_star/executing/awaiting_return/completed | ✅ |
| ResolveAction | qjs magic 0/1/2/3 | `async_generator.zig:56` none/await_resume/yield_operand/awaiting_return | ⚠️ |
| pushRequest | `list_add` | `async_generator.zig:75` slice with capacity doubling | ⚠️ |
| takeHeadRequest | `list_del` | `async_generator.zig:94` array memcopyForwards | ⚠️ |
| settleHead | `js_async_generator_resolve_or_reject` | `async_generator.zig:116` ValueRootFrame for GC safety | ✅ |
| resolveHead | `js_async_generator_resolve` | `async_generator.zig:150` createIteratorResult | ✅ |
| complete | `js_async_generator_complete` | `async_generator.zig:168` eager frame free via completeGeneratorExecution | ✅ |
| parkGeneratorExecutionState | in-place modify | `vm_gen_async.zig:87`：resident_frame_views_match check → zero-copy path / legacy transfer fallback | ⚠️ |
| saveGeneratorExecutionState | `save_frame` in OP_await | `vm_gen_async.zig:181`：ownership validation，open_var_refs attachment | ⚠️ |
| IteratorHelperKind | 无 | `iterator_ops.zig:2344` map/filter/take/drop/flatMap/concat/zip/zip_keyed | 🔧 |
| forOfStart | `js_get_iterator` | `iterator_ops.zig:27` GetIterator for sync/async | ✅ |
| iteratorNextMethod | — | `iterator_ops.zig:117` | ✅ |
| iterator side cache | 无 | `iterator_ops.zig:185` `iteratorTargetSlot`、`186` `iteratorNextSlot`，23 处使用 | 🔧 **需验证 mutation/proxy/invalidation** |
| flatMap close | inner 两次 + outer | `iterator_ops.zig:3284` `qjsIteratorHelperCloseInner` inner 一次 + outer | ⚠️ 基线说"保留 zjs 并回归" |
| Iterator.zip/zipKeyed | 无 | `iterator_builtin_ops.zig` internal entries | 🔧 |
| Iterator.prototype[Symbol.dispose] | 无 | — | 🔧 |

**漂移**：`Promise.allKeyed/allSettledKeyed` 确认为已实现 static method。

---

## 13. Builtins / Standard Globals

**QuickJS 实现**：`JSCFunctionListEntry` + cproto/magic 分发，68 global own keys。

**zjs 实现**：`src/core/host_function.zig`、`src/exec/internal_builtins.zig`、
`src/exec/builtin_dispatch.zig`、`src/exec/standard_globals.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| NativeCProto | `JSCFunctionEnum` | `host_function.zig:207` enum：generic/generic_magic/constructor/constructor_magic/constructor_or_func/constructor_or_func_magic/getter/setter/getter_magic/setter_magic/f_f/f_f_f | ✅ |
| NativeFunctionPtr | C function pointer | `host_function.zig:242` union(NativeCProto) typed function pointers | ✅ |
| InternalEntry | `JSCFunctionListEntry` | `host_function.zig:262`：name/length/id/magic/forwards_call/cproto/native_function/fallback_function | ✅ + 🔧 forwards_call/fallback |
| InternalRecord | runtime entry | `host_function.zig:276`：length/magic/forwards_call/cproto/native_function/fallback_function | ✅ |
| InternalCallableTag | C_FUNCTION_DATA magic | `host_function.zig:17` enum：promise_resolving/promise_capability_executor/promise_combinator_element/promise_finally_callback/async_function_resume/async_from_sync_iterator_unwrap/async_disposable_stack_continuation/throw_type_error_intrinsic/async_generator_resolve/async_from_sync_iterator_close_wrap/array_from_async_continuation | 🔧 |
| table | separate js_*_funcs | `internal_builtins.zig:83` `[domain_count][]const InternalRecord`，`denseRecords`（`45`）comptime 验证无重复 id | ✅ |
| domain_count | implicit | `internal_builtins.zig:37` explicit count | ⚠️ |
| nativeCall | `JS_CallInternal` env | `builtin_dispatch.zig:137` typed struct with all context，inline | ✅ |
| finalCallableRealmView | `ctx = p->u.cfunc.realm` | `builtin_dispatch.zig:71` explicit realm selection with validation | ✅ |
| installStandardGlobals | `JS_InitClass`/`JS_AddIntrinsic` | `standard_globals.zig:1514` fixed order installation | ⚠️ |
| global own keys | 68 | 76（基线值） | — |
| zjs-only globals | — | AsyncDisposableStack/DOMException/DisposableStack/SuppressedError/TypedArray/atob/btoa/gc/navigator/queueMicrotask | 🔧 |
| qjs-only globals | Symbol.toStringTag own symbol/__loadScript | `__loadScript` **未实现** | — |
| zjs-only prototype | — | Array.fromAsync/immutable ArrayBuffer accessors/Atomics.waitAsync/Promise.allKeyed/allSettledKeyed/RegExp legacy statics/Iterator.zip/zipKeyed/Iterator.prototype[Symbol.dispose] | 🔧 |
| qjs-only prototype | Function.prototype.fileName/lineNumber/columnNumber/Set.groupBy | — | — |

**漂移**：无。

---

## 14. RegExp

**QuickJS 实现**：`libregexp.c` + `libunicode.c`，NFA backtracking，54 opcodes。

**zjs 实现**：`src/libs/regexp.zig`（4,040 行）、`src/exec/regexp_ops.zig`（1,889 行）、
`src/exec/regexp_adapter.zig`、`src/exec/regexp_fastpath.zig`、
`src/exec/vm_regexp.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| flags | — | `regexp.zig:15` bit flags：global/ignore_case/multiline/dot_all/unicode/sticky/indices/named_groups/unicode_sets | ✅ |
| Capture | — | `regexp.zig:27` start/end/name | ✅ |
| REBytecodeHeader | — | `regexp.zig:74` flags/capture_count/register_count/bytecode_len | ✅ |
| REExecContext | — | `regexp.zig:201` allocator/buffer pointers/capture/register counts/backtrack frames/undo stack | ✅ |
| compilePatternAndFlags | `re_compile` | `regexp.zig:423` → `compileWithFlagBits`（`1881`）：REParseState → emit header → sticky → save_start/disjunction/save_end/match | ✅ |
| execIntoMatchTrustedWithOptions | `lre_exec_backtrack` | `regexp.zig:481` trusted variant skips header validation → `execCaptureSlotsParsed`（`557`）→ `lreExecBacktrack`（`1190`） | ✅ |
| bytecode VM | 54 opcodes | `regexp.zig:103` char/char_i/char32/dot/any/space/line_start/goto_/split_goto_first/match/lookahead/back_reference/range/class8/loop 等 | ✅ |
| backreferences | 有 | `regexp.zig:136-139` back_reference/back_reference_i/backward_back_reference/backward_back_reference_i | ✅ |
| lookbehind | 有 | **未实现**——只有 lookahead/negative_lookahead（`144-145`） | ⚠️ |
| named groups | 有 | `regexp.zig:23` flags.named_groups，`2096-2133` group_name storage | ✅ |
| unicode | 有 | flags.unicode/unicode_sets + canonicalization tables | ✅ |
| 1M-bit cap | 有 | `regexp.zig:10` max_bits=1024*1024 | ✅ |
| checked/trusted paths | C asserts | `.checked`/`.trusted` comptime safety modes | ⚠️ |
| CaptureSlotBuffer | — | `regexp.zig:81-99` inline/heap allocation strategy | ⚠️ |
| timeout polling | — | `regexp.zig:228-235` CheckTimeout callback | 🔧 |
| RegExp.escape | qjs 过度转义 | zjs 符合当前 proposal/test262 精确转义 | ⚠️ 保留 zjs |
| RegExp.prototype.compile subclass | qjs 接受 | zjs 抛 TypeError（legacy-regexp test262 行为） | ⚠️ 保留 zjs |
| legacy statics ($1-$9) | qjs 有 | zjs 有 | 🔧 zjs-only 表面 |
| 484/484 core match | — | 0 mismatch，per-case 0.84x qjs time | ✅ |

**漂移**：无。

---

## 15. BigInt

**QuickJS 实现**：单次 FAM allocation，`len + tab[]`，two's-complement limbs，1M-bit
上限。

**zjs 实现**：`src/libs/bigint.zig`（1,328 行）、`src/core/bigint.zig`（362 行）

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| heap BigInt | 单次 FAM `len + tab[]` | `core/bigint.zig:31` `BigInt` GC wrapper：header + limbs_ptr + allocator + len + capacity + flags | ⚠️ |
| limb 类型 | — | `u64`（Limb），`u128`（DoubleLimb） | ✅ |
| 表示 | two's-complement | sign+magnitude `[]u64` | ⚠️ 物理表示不对齐 |
| 1M-bit 上限 | 有 | `libs/bigint.zig:10` max_bits=1024*1024，`checkLimbCount` | ✅ |
| add/sub/mul/div/rem/pow | `mp_*` | `libs/bigint.zig:63-148`：`addAlloc`（`936`）sign-aware、`mulAlloc`（`963`）shorter-operand outer loop、`divRemAbsAlloc`（`915`）long division、`pow`（`148`）repeated squaring | ✅ |
| bitwise | — | `libs/bigint.zig:202` AND/OR/XOR with sign extension、`193` bitNot two's complement | ✅ |
| shiftLeft/shiftRight | — | `libs/bigint.zig:410-466` limb-level shifts with carry | ✅ |
| formatBaseAlloc | — | `libs/bigint.zig:101` base 2-36，special base-10 chunking | ✅ |
| **inline FAM storage** | 单次 FAM | `core/bigint.zig:51` `flags.inline_storage`、`179` `createInlineUninitialized`、`194` `inlineBase`、`201` `publishInline` | 🔧 **基线后新增** |
| storage-agnostic access | — | `core/bigint.zig:85` `limbs()` works for both modes、`112` `borrowedValue` | 🔧 |
| explicit capacity | — | `capacity` field separate from `len` | 🔧 |
| allocator migration | — | `createFromOwned` handles cross-allocator transfers | 🔧 |

**漂移**：**有**——BigInt 新增 inline FAM 存储能力，减少乘法结果的分配次数。基线说
"limbs 通常是第二次 allocation"，现在可以 inline FAM tail。

---

## 16. Number / dtoa / Date / JSON

**QuickJS 实现**：`dtoa.c` Bellard dtoa/atod；Date/JSON C 实现。

**zjs 实现**：`src/libs/number_format.zig`（1,650 行）、`src/exec/date_ops.zig`（1,781
行）、`src/core/json.zig`（158 行）、`src/exec/json_ops.zig`（2,935 行）

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| dtoa | `dtoa.c` | `number_format.zig:948` `jsDtoaImpl`：extract sign/exp/mantissa → special cases → normalize → compute P → bignum → round → output | ✅ |
| atod | `dtoa.c` | `number_format.zig:1179` `jsAtodImpl`：parse sign → radix prefix → int/frac parts → bignum → scale → IEEE 754 round | ✅ |
| flags | — | `number_format.zig:39-54` JS_DTOA_FORMAT(FREE/FIXED/FRAC)/JS_DTOA_EXP(AUTO/ENABLED/DISABLED)/JS_ATOD flags | ✅ |
| tables | — | `number_format.zig:105-178` pow5_table/pow5_inv_table/mul_log2_radix_table/digits_per_limb_table/max/min_exponent | ✅ |
| temp memory | — | `JSDTOATempMem` [37]u64、`JSATODTempMem` [27]u64 | ✅ |
| bump-pointer allocator | malloc/free | `number_format.zig:222` `dtoaMalloc` | ⚠️ |
| Mpb(comptime cap) | runtime allocation | compile-time sized bignum | ⚠️ |
| C ABI wrappers | — | `number_format.zig:1503-1517` js_dtoa/js_atod | 🔧 |
| Date | qjs C | `date_ops.zig` Zig 实现：`33` constructDateRecord、`120` qjsDateSetYear、`139` qjsDateSetTime、`156` qjsDateStaticCall（UTC/parse/now）、34 prototype methods | ⚠️ Zig 实现 |
| captured-setter | — | `date_ops.zig:84` callDateSetYearWithCapturedMs、`99` callDateSetPartsWithCapturedMs（spec 合规：coercion 前捕获 t） | ✅ |
| host timezone/DST | — | 边界 concern | ⚠️ |
| JSON stringify | `js_json_obj` | `json_ops.zig:150` `stringify`：replacer/space → property list + gap → appendJsonValue recursive | ✅ |
| JSON parse | `js_json_funcs` | `json_ops.zig:184` `parse`：appendJsonInputString → `parseSimpleJsonValue` hand-rolled recursive descent | ⚠️ hand-rolled parser |
| reviver/replacer | — | `json_ops.zig:1796-1955` reviver_call with context argument | ✅ |
| rawJSON | — | `json_ops.zig:103` rawJSON validates via parseSimpleJsonValue | ✅ |
| WTF-8 handling | — | `json.zig:70-86` lone surrogates emit \udXXX | ✅ |
| ASCII fast path | — | `json.zig:18` createJsonStringValue checks high bytes | 🔧 |
| tagged-int atom rendering | — | `json.zig:59` appendJsonAtomName renders tagged ints as decimal indices | 🔧 |

**漂移**：无。

---

## 16b. ArrayBuffer / TypedArray / DataView / Atomics

**QuickJS 实现**：`JSArrayBuffer` inline object union + linked `JSTypedArray`，hot
path element access reads ptr/count from object union。

**zjs 实现**：`src/core/typed_array.zig`（1,091 行）、`src/exec/buffer_ops.zig`（281
行）、`src/exec/typed_array_construct.zig`、`src/exec/atomics_wait.zig`

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| buffer 结构 | inline union | `object.zig:467` `BufferPayload` out-of-line：bytes + inline_bytes[32] + shared_store + external_memory + external_deinit + detached/immutable + max_byte_length + first_view | ⚠️ |
| typed array | `JSTypedArray` in view list | `object.zig:567` `TypedArrayPayload`：buffer/byte_offset/element_size/fixed_length/kind/live_length/data/backing_payload/buffer_prev/buffer_next | ⚠️ |
| view list | linked list | doubly-linked list via buffer_prev/buffer_next | ⚠️ |
| view cache invalidation | 直接 union | `BufferPayload.invalidateViews/updateViews` 显式失效 | ⚠️ |
| element access | ptr/count from union | `TypedArrayPayload.updateLiveState/clearLiveState` recompute live_length/data | ⚠️ 每元素 load chain 更长 |
| immutable ArrayBuffer | 无 | `typed_array.zig:160` `sliceToImmutable`/`transferToImmutable`/`markArrayBufferImmutable` | 🔧 |
| resizable/growable | qjs 有 | `typed_array.zig:218` `arrayBufferGrow`、max_byte_length | ✅ |
| Atomics.wait | 有 | `atomics_wait.zig` | ✅ |
| Atomics.waitAsync | 无 | `atomics_wait.zig:25` | 🔧 |
| isLockFree | — | sizes 1/2/4/8 | ✅ |
| DataView get/set | — | `typed_array.zig` endianness-aware get/setElement | ✅ |
| method dispatch | C function list | `buffer_ops.zig:86-139` internal_entries table with magic IDs | ⚠️ record-based |
| immutable methods | 无 | `buffer_ops.zig` sliceToImmutable/transferToImmutable | 🔧 |

**漂移**：无。

---

## 17. CLI / Binding / API / Runner

**QuickJS 实现**：`qjs` CLI + C API（runtime/context/value/class/module/serialization/
qjsc）+ qjs test262 runner。

**zjs 实现**：`src/cli/zjs.zig`（1,054 行）、`src/cli/run_test262.zig`（4,390 行）、
`src/root.zig`（1,319 行）、`src/binding/binding.zig`（1,647 行）、
`src/binding/ffi.zig`（1,492 行）

| 项 | QuickJS | zjs | 分类 |
|---|---|---|---|
| CLI flags | `-h/-i/--script/--strict/--std/...` | `zjs.zig:42` RuntimeOptions：memory_limit/stack_size/can_block/dump_memory/trace_memory/profile_opcodes/perf_json/leak_check/include_paths；flags: -d/-T/--profile-opcodes/--perf-json/--leak-check/--memory-limit/--stack-size/-I/-m | ⚠️ 不同产品合同 |
| print 格式 | inspector（BigInt `3n`） | ECMAScript 字符串转换 | ⚠️ |
| TS erasure | 无 | lexer `enableTypeScript`/`markTypeRanges` | 🔧 |
| teardown | 显式 teardown | 默认 OS 回收，`--leak-check`/测试路径强制 | ⚠️ |
| config signature | 无 | `--print-config-signature` build verification | 🔧 |
| 公开 API | C API | `root.zig` Zig-first：value/host/object namespaces，opaque Object type | 🔧 非 drop-in |
| JSObject template | `JSClassDef` | `binding.zig:83` `JSObject(comptime Payload, comptime spec)` comptime generic | 🔧 |
| Binding/OwnedBinding | — | `binding.zig:109` Binding（context-lifetime borrowed）、`137` OwnedBinding（retained realm） | 🔧 |
| TraceVisitor | — | `binding.zig:51` explicit GC tracing interface | 🔧 |
| FFI ABI versioning | 无 | `ffi.zig:6-7` magic=0x5A4A5346、abi_version=1、Target validation | 🔧 |
| BorrowedBytes/MutableBytes/JSValueSlice | — | `ffi.zig:105-139` zero-copy slice passing | 🔧 |
| HostTypeId | — | `ffi.zig:233` u64 hash of type name | 🔧 |
| OpaqueHostObject | — | `ffi.zig:251` type-safe external object references | 🔧 |
| 序列化/AOT | `JS_WriteObject`/`JS_ReadObject`/`JS_EvalFunction`/`qjsc` | **无** | 🔧 缺失 |
| test262 runner | qjs runner | `run_test262.zig`：-c/-d/-f/-e/-u/-m/-t/-T/-R/--engine/--regression-baseline/--enable-feature/--skip-feature | 🔧 zjs 工具更强 |
| external engine | 无 | `--engine <path>` cross-engine comparison | 🔧 |
| regression baseline | 无 | `--regression-baseline` gate enforcement | 🔧 |
| batch_worker_restart | — | 256 tests per worker restart | 🔧 |

**漂移**：无。

---

## 总结矩阵

### 忠实实现（✅）核心清单

- JSValue 默认 16B 布局 + Tag 语义
- Allocator/RC/GC 物理布局（8B/16B/4B prefix）
- GC trial-deletion 三阶段循环回收
- Object 64B / Shape 56B / Property 16B 尺寸
- Parser monolith + token kind 精确对齐 + ASI + strict mode
- Bytecode opcode 0-243 + FunctionBytecode 96B + DebugInfo 32B
- Compiler V2 单编译路径（基线后完成 legacy 删除）
- RegExp libregexp 核心移植（484/484 一致）
- BigInt 算术（add/sub/mul/div/pow/bitwise/shift/format）+ 1M-bit cap
- dtoa/atod 算法移植
- Promise 构造/reaction/all/race/allSettled/any/withResolvers
- Generator State enum + request queue + settlement
- Module linking/evaluation DFS + export/import resolution
- Builtins NativeCProto/InternalEntry/InternalRecord typed dispatch
- ArrayBuffer/TypedArray resizable/growable + DataView + Atomics
- VM opcode handlers（push/arith/compare/jump/branch/return/throw/property）

### 故意偏离（⚠️）核心清单

- JSValue NaN-boxing 备选表示（自定义 dense encoding）
- Runtime VmStackArena（heap arena 替代 C 栈）
- Shape FAM 顺序反转（props first）
- ShapeProperty 8B packed（qjs 12B）
- Array length 标量存放 + merge sort
- ArrayBuffer/TypedArray out-of-line payload + intrusive view list + explicit invalidation
- VM tail-call dispatch（per-opcode handler vs monolithic switch）
- Frame heap-resident + arena（vs C 栈 alloca）
- direct eval overlay（vs closure-ref capture）
- exception Zig error union + runtime pending
- BigInt sign+magnitude（vs two's-complement）+ GC wrapper
- Date/JSON Zig 实现
- modules async SCC explicit continuation struct
- generator ownership transfer（vs in-place）
- flatMap single-close（vs qjs double-close）
- RegExp.escape/compile 保留 zjs 规范行为
- RegExp lookbehind 未实现
- Job typed union（vs generic FAM）
- Builtins fixed installation order
- CLI 不同产品合同 + print 格式 + teardown 策略

### zjs 自造（🔧）核心清单

- HandleScope/Local/Persistent/Weak handles + RootProvider
- Weak lifecycle monotonic weak_id 双 hash table + deferred free
- Deferred cleanup 队列 + OOM injection/recovery canary
- GC Policy mode/concurrent/generational fields（占位）
- external memory token / RSS / cgroup policy
- Runtime string caches（single-byte/two-unit/%XX/small-int）
- RopeTailState fused-local accumulator
- TypeScript erasure（markTypeRanges/tsTokenize）
- 4 个 using opcodes (244-247) + FunctionBytecodeHotExtension
- closure_var_may_have_dynamic_env monotone flag
- **leaf frame 分类 + forwarded call leaf + simple-field constructor memo**（⚠️ 基线 P0 删除候选，仍存在）
- iterator side cache（iteratorTargetSlot/iteratorNextSlot）
- immutable ArrayBuffer + Atomics.waitAsync + Promise.allKeyed/allSettledKeyed
- zjs-only globals（AsyncDisposableStack/DOMException/DisposableStack/SuppressedError/TypedArray/atob/btoa/gc/navigator/queueMicrotask）
- BigInt inline FAM storage（基线后新增）
- RegExp timeout polling + checked/trusted paths
- dtoa bump-pointer allocator + Mpb + C ABI wrappers
- JSON ASCII fast path + tagged-int atom rendering + hand-rolled parser
- Zig-first binding API + FFI ABI versioning + comptime JSObject template
- test262 runner external engine + regression baseline + feature flags
- Compiler V2 Oracle（Debug/ReleaseSafe only）/ LabelId / match_barrier / PendingTailRewrite / Snapshot

### 基线后关键漂移

1. **Compiler V2 成为唯一编译器**——legacy pipelines 完全删除（`7877c3bf`），架构门禁
   验证零 retired 符号
2. **BigInt inline FAM storage**——`flags.inline_storage` + `createInlineUninitialized`，
   基线说"limbs 通常是第二次 allocation"，现在可以 inline FAM tail
3. **Atom chained hash**——`aaa804af` 镜像 qjs chained hash table
4. **call_method dispatch / allocation-threshold GC / S4 opcode row**——三个 perf commit
   向 qjs 对齐
5. **P0 非 qjs 调用机制仍未删除**——leaf frame 分类、forwarded call leaf、
   simple-field constructor memo 全部仍在，与基线 P0 建议相反
