# Zig 风格整理战役（2026-09-20 起）

Owner 裁决（2026-09-20）：**不再要求对齐 QuickJS；优先处理「不管 Zig 风格」的代码。**
本文件是全引擎的普查结论与刀序。语义权威仍是 ECMA-262/test262；
`docs/refactor-policy.md` 的热区逐项落地规则不变。

## 1. 普查（不含 src/tests/）

| 形态 | 计数 | 主要分布 |
|---|---|---|
| `quickjs.c` 行号注释 | 1518 | tailcall_dispatch 107、object 98、expressions 68、array_ops 64、bytecode 56、date_ops 50 |
| `var x: T = undefined` 真延迟初始化 | ~80（578 含固定缓冲） | compiler/tests、resolve_*、host_invocation、cli |
| 标量 out-param（`*usize/*bool/*?T`） | 231 | bytecode 31、date_ops 13、iterator_ops 10 |
| 位置 bool ≥2 的签名 / 调用点 | 70 / 500+ | Descriptor.data 209、Flags.data 64、inline_calls 24 comptime 元组 |
| 裸 `method_id: u32` 选择子 | 148 | date/string/object ops |
| `mem.eql` 名字级联 | 421（+call_runtime 103） | buffer/object/standard_globals/date/string ops |
| 手写 growable（slice+capacity+len） | 33 组 + 3 套 helper | builder、FunctionDefImpl、resolve_*、object_payloads、gc_registry_pins/heap |
| `catch return error.OutOfMemory` 吞错 | 70（其中 ~30 是 math 溢出的正确映射） | bytecode 29、cfg 9、builder 7 |
| `catch unreachable` | 67 | cfg 34（诊断格式化）、其余定长 bufPrint |
| 诊断与生产同居 | ~3000 行 | gc_conservative 78%、gc_trace_stw audit、block_heap.verify、gc_audit_print 505 行 |
| 死代码 | ~1000 行 | exec/vm_exec_state.zig、core/list.zig、regexp checked 执行家族 |
| >150 行函数 | 17 个 >200，72 个 >100 | resolve_labels.walk 478、cfg.auditBoundaryUniqueness 624、installTypedArrayPrototypeAccessors 567 |

各子系统的逐条清单（file:line）在 `.scratch/zig-style/0[1-6]-*.md`。

## 2. 刀序

每刀一个 commit；验证 = `zig build check` → 定向 `test-fast` → `zig build test`；
触及 parser/compiler/bytecode 的加 `zjs --bytecode-fingerprint` 前后对比；
触及热路径的加 ReleaseFast 构建 + Octane≥0.95 回归门（perf-line-closed 裁决）。

### 第 0 波：零风险删除与顺手 bug
- 删 `exec/vm_exec_state.zig`、`core/list.zig`（无消费者）。
- `compiler/builder.zig` 九处 `catch |err| { return err; }` → `try`；`cli/zjs.zig` `initOpcodeProfile` → `.{}`；`builtin_dispatch` 四处 `bt_data` undefined → 字面量。
- `event_loop.zig` 信号处理器非原子 RMW → `std.atomic.Value`；`module_graph.zig` `internAtom catch return true` 吞 OOM。
- 删 `libs/regexp.zig` checked 执行家族（`ExecSafety`/`Match`/`ExecStatus`/`writeMatch`，无 in-tree caller）。

### 第 1 波：签名层 Zig 化（编译器兜底、不改布局）
- `Descriptor.data/accessor`、`property.Flags.data` → `Attrs` options struct（273 调用点）。
- `shape.zig` `flags: u6` → `property.Flags`。
- `inline_calls` comptime bool 元组 → `comptime shape: FrameShape`。
- `bytecode.publishExecutionFlags` 6 bool、`addScopeVar`、`scanSmallInlineEligible` → options struct。
- `zjs_vm.runWithArgsState` 23 参 → 贯通已有 `CallEnv`。
- `exec/closure.zig` fixture `kind: i32` → enum + tagged `Spec`。
- `frame.zig` 六 usize 参数 ×4 → `SlabLayout` + `error{Overflow}`。
- `number_format` `pnext` 出参 → `?Parsed`；`flags: i32` → enum options；六个标量出参 → 返回 struct。
- `regexp.zig` `total_capture_count/has_named_captures = -1` → optional；`@"opaque"+fn` 四处 → `Host`。
- `*_ops.zig` `method_id: u32` → 已有 enum；名字级联 → `std.meta.stringToEnum`/`StaticStringMap`。
- `iterator kind: u8` → 真 enum（不 union 化）；`hostFunctionKind/nativeFunctionId i32` → optional/enum。

### 第 2 波：结构层
- GC：pins/heap 手写 ArrayList → std；`gc_registry_lists` 自由函数 → 方法；诊断 comptime 门控 + 拆文件；删 `gc_audit_print`；block_heap flags/links/地址 helper；collectMinor `EnumArray`；`rt: anytype` 收敛；进程级结果槽 → per-runtime。
- 编译器：合并 `resolve_variables.Error`/`binding_rules.Error`；`cfg` 格式化 → `std.Io.Writer`；Builder 三元组 → `ArrayListUnmanaged`；`binding_rules` `CodeWriter` 取代四元游标 + 13 个平行 size 函数；`walk/walkLateArm/run` 按臂拆分；编译期内部哨兵 → optional。
- 对象模型：object.zig 访问器墙 comptime 化（−850 行）；`runtime.zig` 三份 append 合一；`nativeBuiltinId` packed struct。
- VM：`tailcall_dispatch_colds` helper 收 `vm: *Vm`；`ActiveBacktraceFrame` anyopaque → union(enum)；`small_inline.analyzeApplyForward` Scan 结构。
- 内建：`date_ops` 解析器 Cursor/DateFields（先补单测）；扫描循环 comptime 泛化；`Exec` 上下文结构取代五元组（perf 对照）。
- 外层：lexer `namespace()` 拆包 + `token.zig`；unicode 访问层（二分/位段/enum）；cli 参数解析与 `main` 拆分。

### 第 3 波：注释
- `quickjs.c:NNNN` 行号与 `JS_*` 宏对照按文件清理：保留「为什么」、删行号；测量考古移 docs；rc 时代双模式注释压成单一事实。随所触文件顺带做，不单开刀。

### 明确不动
- `FunctionBytecodeImpl` extern 布局、`Block` extern 布局（GC/FAM 义务）；`object.zig` `slow: *bool`（实测转发理由）；`array_list_erased/sort_erased`（体积刀）；native 边界 JSValue 哨兵（调用约定）；`native.zig` 公共 ABI；`memory.zig` SmallObjectSlab 双链；`HostHooks`/vtable 类 anyopaque（真运行时多态）；`gc_registry_lists` 单向链（刻意省一字）。

## 3. 进度
见本文件末尾追加的「已落地」段。

## 4. 已落地（2026-09-20）

> 本节引用的逐刀 commit SHA 只存在于本地分支 `backup/pre-squash-2026-09-20-zigstyle`；main 上整个战役已压成单个提交（2026-09-20）。

第 0 波（全部）：
- `7233242d` 删 `exec/vm_exec_state.zig`、`core/list.zig`。
- `a6d57674` builder 九处无操作 catch → try；`bt_data` 字面量；event_loop 信号位改原子；module_graph 不再吞 OOM。
- `1b7bcdb1` regexp checked 执行家族与 `comptime safety` 参数删除（−289 行，RegExp 切片 2518 通过）。

第 1 波（已做）：
- `3ddcbf29` `property.Attrs`（`.all/.method/.none`）取代 Descriptor/Flags 的位置 bool，582 调用点；standard_globals 本地 Flags 并入。
- `2e5b3a4a` inline_calls `FrameShape`（ReleaseFast 机器码逐字节相同）。
- `505f3e76` bytecode `ExecutionFacts`/`LoweredPublish`/`ScopeVarOptions`（指纹相同）。
- `47cb6426` zjs_vm 三入口贯通 `CallEnv`（23 参 → 1）。
- `80fab7e2` frame `SlabLayout` + 单份 `partition`。
- `7cca4758` `bc21bab4` number_format：`FormatOptions` 枚举、`?Parsed`、五个出参 → 返回结构。
- `4d132812` regexp `Host` + `core.regexp.libraryHost`，capture 计数哨兵 → optional（指纹相同）。
- `4245929a` Date 域删除 legacy 解码 id 层，bodies 直接 switch `PrototypeMethod`/`StaticMethod`。
- `d778d103` runtime 三份 append → 泛型；`defineFreshNonIndexDataProperty` 用 Attrs。

第 1 波（改判/后置）：
- shape `flags: u6 → property.Flags`：object.zig:10821 与 tailcall_dispatch.zig:6703 记录了 `Flags.fromBits` 在 handler 内联时的 alloca 溢出实测；改动会碰 get_field 热臂，移入热区逐项队列，需 perf 对照。
- iterator `kind: u8`：同一字段承载 ≥5 种 enum（array/collection/helper/for-in/regexp-string-iterator 位掩码），单纯换 enum 不成立，须按 class 拆 union（第 2 波，改布局）。
- String/Array/RegExp 域的 decoded id 层：HTML 包装与 `substr` 只有 exec 侧 id、无记录表行，先要决定 Annex B 名字级联的归宿再统一；单独立项。
- `exec/closure.zig` fixture 的 42 个数字 kind：测试夹具，收益低，后置。

- `c092968a` GC pins 账本 → 单个 AutoArrayHashMap；external tokens → ArrayListUnmanaged。
- `e3473788` GC 链表方法化、`?Request`、`EnumSet` 状态掩码、`EnvSwitch`、`LiveAddressClass`；CLI 参数查表 + GC 全局延后到 `applyRuntimeOptions`（⚠️须 `refreshBarrierGate`）。
- object.zig `payloadOf(self, comptime kind)` 泛型取器 + 97 个访问器体压成一行（−140 行）。
- GC minor 阶段 `MinorPhaseTimer` + `EnumArray(MinorPhase, u64)`。

性能：Octane fixed-work A/B（14 项，绑大核 ABBA）几何均值 0.9994；regexp 单项 −3% 经二分定位在 `4245929a`（Date 域枚举化，regexp.js 只在 harness 计时里用 `Date.now`），下一提交 `d778d103` 又 +1.5%，属 ReleaseFast 布局重排噪声（owner 2026-09-03 裁决不阻塞）。

第 2 波（已落地，2026-09-20 续）：
- `5125e4b4` 名字级联 → `StaticStringMap` 表（String/Date/Uint8Array/构造器 class/Annex B 名字集/Array 迭代模式）；`resolve_variables.Error` 别名；cfg 四个格式化器改 `*std.Io.Writer` + `formatInto`（−13 `catch unreachable`，余 20 在 panic 路径与 auditBoundaryUniqueness）。
- `218361dd` lexer.zig 去 `namespace(comptime token)` 包装、token 提成 `src/token.zig`（机器码逐字节相同、指纹相同）。
- `ab7da3fe` `Block.flags` → `packed struct(u8)`；`42170cb5` young/doomed 链 → `BlockLink enum(usize)`（`next_free` 的 flag 双关保留）；checkpoint-gate（含 gc-stress）绿。
- `37f0976b` 1451 行注释去 `quickjs.c:NNNN` 行号定位（保留函数名锚点）。
- `935dafdd` gc_conservative 的 R3 诊断普查拆到 `gc_conservative_diag.zig`（1253 行；roots_diag 配置原本已因 Atom 结构化而编译失败，一并修复）。

改判/保留：Builder/FunctionDefImpl 的 slice+capacity+len 三元组与 `reserveSlowBytes` 擦除慢路径是刻意的体积设计，且 `code_len` 等 u32 字段有 ~750 处外部引用，转 ArrayList 收益不抵；`gc_audit_print` 在 ReleaseFast 仍编入（`arena_audit` 是运行时开关），换 std.fmt 会涨体积，待 `invariantChecksEnabled` comptime 化的裁决。
- `7d655771` date_ops 解析器 Cursor/DateFields/optional（76 条黄金用例固化）；`dfa9a87e` GC 结果槽入 Registry（多 runtime 串味修复）；`b15270e9` hostFunctionKind optional、GC 诊断 `rt: *JSRuntime`；`66b2e787` unicode RunType/CaseConv/packed 表项/共用二分。
- 性能复核：unicode 刀后 regexp.js 指令数 −0.08%、cycles +2.4%（同一二进制族在各提交间 ±3% 来回翻转，perf stat 证实是布局效应而非工作量），按 2026-09-03 裁决不阻塞。
- `1e19b0af` closure fixture 7 个活 kind 枚举化（−700 行死代码）；`ff38df19` `typed_array_names.Kind` 取代 u8 魔数 1..12（DataView 的 kind==1 复用改为显式 `data_view_length_tracking`）。
- 第 2 波末 checkpoint-gate 绿；Octane A/B 几何均值 0.9953（typescript 0.960 但 perf stat 指令数 +0.11%、cycles +1.1%，属测量噪声/布局）。
- iterator payload 的 `kind/zip_mode/zip_state` u8 槽位：新增 `exec/iterator_slots.zig` 类型化视图（ArrayIteratorKind/CollectionIteratorKind/IteratorHelperKind/IteratorZipMode/ZipState/RegExpStringIteratorFlags），全部裸字面量站点（`= 6`、`!= 2`、位掩码 1|2、状态 0..3）改走视图；payload 布局不变。union 化仍留待第 3 波。
- `52344d4e` `core/gc_visit.zig`：tracer 访问协议收敛为一处——七个 `callVisitX` 复制品（object_payloads）+ shape/string/module×2/atom 各自的本地 Helper + object.zig 转发层 + generator_state 别名，全部改为 `gc_visit.call(vis, method, arg)` 的类型化包装（value/optionalValue/object/shape/realm/atom/module/storageCell/weakCollectionEntry/finalizationCell/stringBody）；`@call` 不像方法语法那样自动解引用，`call` 显式处理值/指针两种 visitor 并有单测覆盖。tracer 符号指令数逐一相同，其余 ±1-3 insn 漂移落在无关函数（整程序布局）。
- object_payloads GC 边契约（本刀）：每个带 `traceChildEdges` 的 payload 声明 `pub const gc_edges: gc_visit.Edges = .{ .strong, .nested, .manual, .weak }` 并 `comptime { gc_visit.assertClassified(@This()); }`；`carriesReference(T)` 递归识别 JSValue/`*Object`/`*String`/`*RealmContext`/Atom 及含它们的 optional/slice/array/struct/union，漏列或误列都是编译错误（已人为制造两种错误各验一次）。`traceDeclared` 按清单顺序走 strong+nested 边，21 个 trace 体里 14 个整段变成一行；含 storageCell/realm/entry 数组的边仍手写并列在 `manual`。裸 `// gc-slot: heap|weak|immutable` 注释在该文件删除（清单即分类），留下带 barrier 说明的四条。机器码与前一刀逐字节一致（仅 anon 符号编号变化）。

- rc 残留的槽位清零助手退役：`destroyOptionalValue/destroyOwnedValue/replaceOwnedValue/destroyValueSliceValuesOnly/clearVarRefCellSlice/destroyValueSlice` 六个只做 `slot.* = null/undefined/&.{}` 却带着无用 `rt` 的助手删除；11 个从未被调用的 tracer 拥有 payload 的 `destroy`（Ordinary/PromiseReactionCapability/Bound/Proxy/Arguments/ObjectData/VarRef/DisposableStack/Promise/RegExp/Global/RegExpLegacyStatics/FunctionRare/BytecodeFunctionAux，`payloadKindIsTracerOwnedCellOrNone` 早已在派发前返回）整段删除；generator 挂起帧的 deinit 不再把局部副本清零再丢弃；`setGeneratorThis` 等四个 setter 与 `TypedArrayPayload.destroy` 去掉无用 `rt` 形参。−210 行；ReleaseFast 只有拆除路径 6 个符号变短（−43 insn），其余逐符号相同；checkpoint-gate 绿；test262 generator/async-generator/yield/TypedArray/ArrayBuffer/Function/annexB RegExp 切片 0/4519。

- `core.function.NativeBuiltinId = packed struct(i32){ id: u10, domain: u22 }`：`domain*1024+id` 的手算编码与 21 臂 `switch(domain_code)` 解码换成声明的位布局 + 连续域码范围检查（⚠️`std.enums.fromInt` 在此会展开成 21 路跳转表并让解码在属性快路径上停止内联——第一版实测 `decodeNativeBuiltinId` 变成独立 69 条指令的符号，改范围检查后恢复内联）；存储仍是 i32、格式不变，`init` 在 comptime 表里断言 id ≤ 1023。单测覆盖往返/零 id/未知域/负值。
- `expectObject(v) catch null|return null|return X` 55 处 → `core.value_semantics.objectFromValue(v) orelse X`，`catch return error.TypeError` 38 处 → `try expectObject(v)`（expectObject 只会返回 TypeError）；generatorNext/Return 等三处多余的 `is(.object)` 预检删除。全量 test262 0/49778。

- `Builder.last_opcode_pos: i64 = -1` → `?u32`：40 处 `< 0` / `>= 0` / `@intCast` 站点改 `orelse` / `if (…) |pos|`、5 处 `= -1` 改 `= null`、12 处 `= @intCast(offset)` 改直接赋值；`FunctionDefImpl.last_opcode_pos: i32`（parse_state/lookahead 快照只在存取它自己）是死影子字段，连同两个快照字段删除。字节码指纹 53,579 文件逐位一致；单测绿。

- 属性标志位置 bool 尾巴：call.zig `defineDataPropertyWithFlags`、construct.zig `defineData`、object_ops `defineDataPropertyByAtom` 三个 `(…, writable, enumerable, configurable)` 助手删除，23 个调用点全部内联为 `defineOwnProperty(rt, key, Descriptor.data(value, .method))`（错误对象的 message/cause/errors/stack 等一律 writable+configurable）或 `.{ .configurable = true }`（bound 函数的 name/length）。

- regexp 标志：`libs/regexp.flags` 九个 u16 掩码常量 → `Flags = packed struct(u16){global, ignore_case, multiline, dot_all, unicode, sticky, indices, named_groups, unicode_sets}`（字节码头的 u16 通过 `fromBits/bits` 逐位不变）；`parseFlagBits` 变 `Flags.parse`、`Compiled.flagBits()` 变 `flags()`、`compile*WithFlagBits*` 改 `*WithFlags*`；regexp_fastpath `regExpExecCompiledResult` 的 `is_global, is_sticky, has_indices` 三 bool 形参并成 `flags`；名字分派访问器用 `StaticStringMap(FieldEnum(Flags))`；canonical flags 串与 print 检查器改成 `inline for` 字段表。**顺手修一个真缺陷**：print 检查器按位序 0..7 印 `gimsuydv`，把 bit 7（named_groups）当成 `v`、真正的 `v`（bit 8）永不打印——`print(/(?<a>x)/)` 曾输出 `/(?<a>x)/v`，`print(/x/v)` 输出 `/x/`。qjs 本身就有这个怪癖（tests/exec 的 36 形状 print 期望是 qjs 生成的，含 `/(?<n>x)/v`），按「不再对齐 qjs」裁决期望改为正确输出并在测试上注明这是唯一刻意偏离。⚠️ 教训：`zig build test … | tail -3` 会吞掉退出码，第 8-11 刀的「单测绿」是误读，实际只有这一条失败；此后改为落盘日志 + `exit=$?`。

- resolve_labels 融合表：`fuse_b/fuse_op … fuse_b4/fuse_op4` 八个平行字段 + `0` 哨兵 → `fusions: [4]Fusion{b, fused}` + `fusion_count`，`setFusions(comptime list)` / `addFusion` 写入、`maybeFusePrev` 按序线性匹配（原四段 if/else 的顺序语义不变）。字节码指纹逐位一致。

- 测试夹具的 bool+errdefer 六行样板：`createFixture → var fb_published=false → errdefer if(!published) destroyUnpublishedFixture → 填 cpool → publishFixtureNoFail → published=true` 在 29 处（exec 各文件测试块、core/promise、event_loop、tests/core）合成一行 `createPublishedFixture(rt, opts, &.{…})`（常量池值先算好再建夹具；助手内不再有可失败步骤）；余下 17 处是互相引用的夹具对（left/right、parent/child）与布局断言测试，保留。−137 行；产品二进制逐字节不变。

- date_ops 日历字段：`fields: [9]f64` / `[7]f64` 与 34 处 `fields[0..8]` 魔数索引 → `DateField enum{year, month, day, hours, minutes, seconds, milliseconds, weekday, tz_minutes}` + `DateFieldValues = std.EnumArray(DateField, f64)`（setter 仍按位置写连续一段 `values[first..]`，这正是选 EnumArray 而非 struct 的理由）；`is_local: bool` → `TimeZone enum{utc, local}`；`getDateFields(ms, fields*, is_local, force) bool` → `?DateFieldValues`（NaN 强制分解只在 setFullYear 用到，改为 `getDateFields(0, .utc)`，与 qjs `d = 0, tz = 0` 等价）；`getDateFieldValue(ms, n, is_local, is_get_year)` → `(ms, .month, .local)` + 独立 `getYearValue`；`SetterSpan{first, end: DateField, zone}` 带 `count()`；`dateFieldsFromArgs` 合并 Date.UTC 与构造器的七参数循环。test262 Date 全目录见提交说明。

- generator 恢复完成类型：`resume_completion_type: i32`（0/1/2 = qjs GEN_MAGIC_NEXT/RETURN/THROW）、`AsyncGeneratorRequest.completion_type: i32`、`yield_star.completion: i32`、`asyncGeneratorEnqueue(…, magic: i32)`、`resumeGeneratorYieldStarCompletion(…, completion_type: i32)` 全部改为 `core.generator_state.ResumeCompletion enum(i32){next, return_, throw}`（推栈时 `@intFromEnum`，运行时格式不变）；`async_state: u8` + async_generator 侧 `@enumFromInt/@intFromEnum` 转换层 → payload 直接存 `AsyncGeneratorState`（枚举挪进 core/generator_state，exec 侧别名）；`setGeneratorResumeCompletionType(rt, obj, i32) !void` 的无用 `rt` 与假 `!` 一并去掉（8 个调用点）。

- tailcall_dispatch `reloadAfterPop(vm, entry, *pc, *sp, *vb)` 三出参 + 调用侧 `var pc2/sp2/vb2 = undefined` → 返回 `Regs{pc, sp, vb}`（10 个站点：`regs.sp + 1` 直接进尾调用；caller 快路径的 `vb2 = caller.frame.locals.ptr` 改 `const caller_vb`）。机器码核对见提交说明。
- 保留（复核后不动）：compiler 测试的 `var h: ParseHarness = undefined; try h.init(...)` 是自引用（state 持 `&h.lex/&h.function`）的钉住结构，就地 init 是正确 Zig 形态；`Object.createInternal` 的三 bool + errdefer 守卫在对象构造热路径上，快路径零成本，暂不改守卫值；`array_ops` 扫描族的 `forward: bool` 是运行时值（mode 决定），comptime 方向泛型要付两倍实例。

- 手写 growable（slice + capacity + 手写倍增/memcpy/free）→ `std.ArrayListUnmanaged` + `rt.memory.persistent_allocator`（记账门面，先例 `rt.auto_init_descriptors`）：GeneratorPayload.async_queue（`pushRequest`/`takeHeadRequest` 变 `append`/`orderedRemove(0)`）、FinalizationRegistryPayload.cells（三处压缩循环改 `shrinkRetainingCapacity`，`ensureFinalizationRegistryCellCapacity` 留作测试用薄包装）、JSRuntime.cached_iterator_next_entries（`addOne`/`swapRemove`）；GC 普查记录器改读 `.items.ptr/.capacity/.items.len`。⚠️`JSContext.unhandled_rejections` 同样式样但 JSContext 有 `@offsetOf(runtime)==832` 等布局钉子，换成 ArrayListUnmanaged 会让 Zig 自动布局把 `runtime` 挪位，故不动。注意记账门面分配不触发 GC 安全点（`allocAlignedBytesNoTrigger`），与 `rt.memory.alloc` 的 `trigger_gc=true` 不同——这些是冷侧表，少几个安全点无碍。

- JSRuntime 九个冷侧表（borrowed_reference_holders、local/persistent/weak root slots、weakref_kept_alive、deferred_native_cleanups、deferred_class_payload_finalizers、deferred_class_payload_roots、borrowed_weak_cleanup_identities）→ `std.ArrayListUnmanaged` + persistent 记账门面：`appendRuntimeItem` 泛型与四个 `ensure*Capacity`/三个 `releaseEmpty*Buffer` 手写扩容/释放删除（`ensureTotalCapacity`/`clearAndFree`），pop-front memmove → `orderedRemove(0)`，swap-remove → `swapRemove`；deinit 里 8 行「capacity!=0 ? ptr[0..cap] : [0..0]」重建 + 8 行 free → 8 个 `deinit`。保留：`root_providers`（有内联小缓冲模式，根遍历热）、`backtrace`（每次 native 调用 push）。⚠️四个 OOM 注入测试用 `@sizeOf(*Object) * 64` 复述旧的首次分配大小来定内存上限，ArrayList 的增长策略不同 → 改为在探针运行时上实测 `registerBorrowedReferenceHolder` 的分配增量。

- C 风格计数循环 `var i: usize = 0; while (i < n) : (i += 1)` → `for (0..n) |i|`：脚本判定「循环体不改 i、上界是标识符/`.len` 且体内不改它、循环后不再用 i」的 55 处自动改写（含 array_ops 一处 `index = len; while (index < len + k)` 改 `for (len..len + k)`），两处不用 i 的改 `|_|`；其余 39 处（上界随体变化、体内改 i、循环后复用 i）保留。

- `X orelse unreachable` → `X.?`：86 处（左操作数是单个后缀表达式时机械改写；`(try f()) orelse unreachable` 两处手改）。语义等价（安全模式同为 null 解包 panic），机器码核对见提交说明。⚠️脚本教训：随后想顺手去掉 `(X.?)[…]` 的括号，正则把 `f(x.?).?` 里的调用实参括号也吃掉了——回滚只保留第一步。

- CollectionPayload `entries`/`weak_entries`（Map/Set/WeakMap/WeakSet 的记录数组）→ `std.ArrayListUnmanaged`：删掉两个 `_capacity` 字段与「capacity==0 但 len!=0 的精确切片」双表示、destroy 里的两段分支释放、`ensure*Capacity` 的手写扩容（增长策略 8 起倍增按 qjs 形状原样保留，走 `ensureTotalCapacityPrecise`，builtins 测试断言的 capacity 8 不变）、`shrinkStrongStorage` 的手写缩容（改 `initCapacity` + `appendSliceAssumeCapacity` 换表）；60 余处 `collectionEntriesSlot().*` 读改 `.items`，压缩循环改 `shrinkRetainingCapacity`。`bucket_heads` 是定长哈希索引数组，不动。⚠️首版 destroy 末尾顺手写了 `self.* = .{}`，把还挂在运行时弱持有者链表里的 `weak_holder_link` 一起清零，gc-stress 分片报 ARENA AUDIT / unreachable；payload 的 destroy 只能清它自己拥有的字段，链表链接由拆链方负责。真正的失败根因（带符号栈）是两个测试把 `rt.memory.alloc` 出来的裸切片直接塞进 `entries`（旧 destroy 靠「capacity==0 则按 len 释放」的双表示兜底），列表化后 `deinit` 只释放 `ptr[0..capacity]` → 泄漏断言；测试改走 `append`。

发现的既有缺陷（非本战役引入，未修）：Debug 构建的 `run-test262` 在每个用例结束的 `JSRuntime.deinit` 触发 `allocation_count == 1` 断言（探针读数：490 个未释放分配 / 35,904 B），战役基线 3993cad5 同样复现；同一 harness+用例用 Debug `zjs` 直接跑干净退出，问题在 runner 的 `$262`/agent/动态导入安装或拆除顺序。仓库门禁只跑 ReleaseFast runner（断言关闭），所以从未被门禁看到。单独立项。

欠账：`docs/code-walkthrough/` 的函数级条目已与源码大面积漂移（36 个文件，多数早于本战役：value/atom/string/parser 拆分/event_loop）；本战役只删除了已移除函数的条目。整册重同步单独立项。
