# TGC S3 规格：atom 表弱化（tracing 接管 atom 活性）

状态：v0.1 草案（driver，2026-09-04 上午）；上游 `docs/tracing-gc-completion-plan.md` §3 S3、§8 D3/D4（owner 批：全弱化，编译期用作用域 root provider）。
基线：`wip/s2-ablated-base`（23385e95，owner 裁剪树；S2 已固化，`JSValue.dup/free` 已 no-op 且调用点已删）。分支 `gc/tgc-s3-*`。
勘察：两份只读报告（2026-09-04，Opus），事实均对裁剪树核实；本文只引用其结论与位置。

## 0. 目标

动态 atom（`DynamicAtom`）的活性由 tracer 决定：**活 = 本次 major 被某个持有者的 `visitAtom` 边标记 ∨ 其 string body 被标记 ∨ 被 host 显式 pin ∨ 在本次 major 标记期内新生**。删除 `ref_count`、`atoms.dup/free/replace/refCount`（生产 725 处 + 测试 960 处）。预定义 atom（656 条）永久 pin，不变。symbol atom 的 `weakref_count`/弱壳语义不变。

## 1. 事实（勘察摘录）

- 持有者分类（生产站点）：A Shape 属性键 8；B/C/D FunctionBytecode 字段/字节码内联操作数/变量表 ~16；E ModuleRecord 38；F Object payload（`native_dispatch_name`、`IteratorPayload.atom_keys`、ownKeys 数组）~6；G 帧上 atom 盒 3 结构；H small_inline CallerState 15；I backtrace 帧 14；J ClassTable 类名 5；K/L/M parser/lexer/compiler/FunctionDef 编译期 ≈267；N exec 临时 `internAtom`+`defer free` 样板 ~500；P 绑定层/插件 ABI 手持 13；O 预定义 0。
- visitor 协议：`RootVisitor`（runtime.zig:682）只有 `visit_value/visit_object/visit_header` 三回调、17 处构造；`Collector` 的 `visitValue/visitObject/visitShape/visitRealm/visitModule`（gc_trace_stw.zig:1717-1737）；`shape/module/object/generator_state` 的 `Helper.callVisitX` comptime 双形态壳。
- `DynamicAtom`（atom.zig:866）：`id, bytes, str, next_free, hash, hash_next, kind, ref_count, weakref_count, …`；`internDynamic`（:1735）复用 `free_slot_head`；`finalizeDeadEntry`（:1845）unindex + 清 `str.atom_id` + 回收 slot。
- major 标记 epoch：`Heap.mark_epoch: u64`（gc_block_heap.zig:211，偶数、非零；extent 表用 `mark_epoch == Heap.mark_epoch` 判本轮已标记）。
- string atom 与 symbol atom 差异：string atom 的 `str` 是惰性缓存，多数为 null；symbol atom 的 `str` 是身份本体（活 ⇔ 有 body）；`onSymbolBodyDead`（:1906）对 string kind 断言 `entry.str != body`。
- 单字节 string atom 的 `str` 会被绑到 runtime 共享的 `single_byte_strings[128]`（atom.zig:1560-1567）→ 这 128 个 atom 在 S3 下恒活（等价 pin，接受）。
- `recent_atom_strings[4]`（runtime.zig:1320）只缓存 tagged-int id → 不受回收影响；S3 禁止扩大其调用面。

## 2. 设计

### 2.1 数据（atom.zig）

| 项 | 规格 |
|---|---|
| `DynamicAtom.ref_count: usize` | 删除；原字宽拆为 `mark_epoch: u64`（本次 major 标记戳；0 = 未标记）+ `host_pins: u32`（P 类 ABI 显式持有计数，`PropNameID.internStatic/release` 增减；默认 0） |
| `DynamicAtom.born_epoch: u64` | 新增：`internDynamic` 写入 `rt.gc.block_heap.mark_epoch`；若当时 major 标记进行中（谓词见 2.3）同时 `mark_epoch = 当前 epoch`（黑分配） |
| `isLive()` | `slotOccupied()` 语义拆分：`occupied = bytes 已绑定 ∨ str != null ∨ weakref_count != 0`；活性判定只在 sweep 期用 `liveAtEpoch(epoch)`（2.4） |
| `strongRefCount/refCount/hasLiveValue` | 删除；`name()`/`kind()` 改用 `occupied ∧ !is_shell` |
| `dup/free/replace/retainValueSymbolEntry/takeSymbolValue` 的计数臂 | 删除；`takeSymbolValue` 只剩 `ensureSymbolBody` |
| `first_private_dynamic_atom`、`-Dzjs_ownership_audit` 隔离格 | 不变（隔离格改由 sweep 驱动的 finalize 推进） |

### 2.2 标记：`visitAtom` 边

- 协议：`RootVisitor` 加 `visit_atom: ?*const fn(ctx, atom.Atom) RootTraceError!void`（默认 null，17 处构造零改动；`RootVisitor.atom(id)` 在 null 时 no-op）；`Collector.visitAtom(id)`；4 处 `Helper.callVisitX` 壳照抄 `callVisitAtom`（无 `visitAtom` decl 的 visitor 静默跳过，与 `visitShape` 同款）。
- `Collector.visitAtom(id)`：`isConst/isTaggedInt → return`；`entry = findDynamic(id)`；`entry.mark_epoch == epoch → return`；置 epoch；**value-symbol kind 且 `entry.str != null` → `shadeExact(body.header())`**（id 持有者要求 body 可再物化，如 `getOwnPropertySymbols`）；string kind 不 shade body（缓存可丢）。
- 持有者边（新增或扩展 `traceChildEdgesFallible`）：
  - A `Shape.traceChildEdgesFallible`（shape.zig:299）：`visitObject(&proto)` 后 `for props()[0..prop_count]`，跳过 deleted/`null_atom`，`visitAtom(prop.atom_id)`。
  - B/C/D `traceHeaderEdges` `.function_bytecode` 臂（gc_trace_stw.zig:79-84）→ 新 `FunctionBytecode.traceChildEdgesFallible`：`func_name`、`debugPtr().filename`、`hotExtension().script_or_module`、`vardefs[].var_name`、`closureVarSlice()[].var_name`、字节码内联 atom 操作数（把 `dupBytecodeAtoms`（bytecode.zig:4286）的 opcode 扫描骨架改写为 `traceBytecodeAtoms(byte_code, visitor)`，`dup/freeBytecodeAtoms` 删除）、**H** `callerState` 的 `inlined[0..inlined_len]`（`callee_name/callee_file`）与 `apply_forward[].method_atom`（small_inline.zig:64-98）。
  - E `ModuleRecord.traceChildEdgesFallible`（module.zig:547）：requests / import / export / indirect / star_export / import_attributes 六数组的 atom 字段。
  - F `FunctionPayload` 新 `traceNativeAtoms`（配合 :1116 `traceNativeRealm`）访问 `native_dispatch_name`；`IteratorPayload.traceChildEdges`（:328）遍历 `atom_keys`；ownKeys 结果数组（object.zig:10926/9501）按其所属结构补边。
- 根（`JSRuntime.traceRoots` runtime.zig:2212 末尾）：I `backtrace_frames[]`+当前帧链的 `function_name/filename`；J `classes.records[].class_name`；`AtomTable.traceRoots` 改为：`predefined_str[]` 全上报（不变）+ **不再**按 `ref_count` 上报 `entries[].str`（改由 2.2 边与 2.4 规则）。
- 编译作用域 provider（K/L/M）：新 `atom.CompileAtomScope { rt, ids: ArrayList(Atom), provider_node }`，`init` 时 `rt.registerRootProvider`（模式：exec/string_ops.zig:1236 `ReplaceMatchRoots`），`deinit` 反注册；`scope.intern(bytes)/internSymbol(...)` = `rt.atoms.internX` + `ids.append`（**记录取得的每个 id，含已存在的**——只记新生 id 不够：已存在但仅由将死对象持有的 atom 会在编译中途被清）；provider 的 trace = `for ids: visitor.atom(id)`。挂接点：`parser.State` 持有一个 scope，lexer token / FunctionDef / builder / resolve_* 全部经它取 atom；`FunctionBytecode` 发布后自身有边，scope 结束即撤。`atoms.replace` 退化为赋值。
- G 帧上 atom 盒（`PendingPropertyDescriptor.atom_id`、`LengthIndexAtom`、`ReturnContinuation.payload.proxy_get`）：按 §3 缺口 2 的裁决处理（推荐改持 body `JSValue`，值已在 VM 根覆盖）。

### 2.3 写屏障与黑分配

- 增量 major 标记期内，atom id 存入**已发布的** GC 持有者必须 shade（Dijkstra 插入屏障，与 `generationalBarrierValue` 同向）：`rt.gc.shadeAtomIfMarking(id)` = `if (marking_active) collector.visitAtom(id)`。站点 = 今天持有者内所有 `atoms.dup` 处（A `appendProperty` shape.zig:1131、E `add*` module.zig:234-316、F、H、I `context.zig:1259-1336`、J）——规则：**持有者里的 `dup` 变屏障，`free` 直接删**。
- 仅删除屏障不够（白持有者→黑持有者的 id 搬迁会漏标），插入屏障足够（根在标记末重扫）。
- 黑分配：`internDynamic` 在 `marking_active` 时置 `mark_epoch`（新 atom 本轮必活）。`marking_active` 谓词用 Collector 现有的「major 标记进行中」状态（`rt.gc.phase` 的 marking 相位；若无单一谓词则在 Registry 加 `major_marking: bool`，begin 置 / finish 清）。

### 2.4 死亡：`AtomTable.sweepDead(rt, epoch)`

- 时机：major 的 `destroyCondemned` 块段与 `sweepStringExtents` **之后**（body 清扫的握手会先清 `str`），`finishIncrementalCycle` 与 STW 全量路径各接一次。minor 不清 atom。
- 每个 occupied 且非 shell 的条目：`live = mark_epoch == epoch ∨ (str != null ∧ headerMarked(str)) ∨ host_pins != 0 ∨ born_epoch == epoch(黑分配已置 mark，可省)`；不活 → `weakref_count != 0 ? 变弱壳(unindex, str=null) : finalizeDeadEntry`。
- `onSymbolBodyDead` string-kind 臂：断言 `entry.str != body` 改为 `if (entry.str == body) entry.str = null`（缓存丢弃是合法事件）。
- 不变量（验证项）：body 的 `atom_id != no_atom_id ⇒ entries[atom_id].str == body`（否则 `String.internAtom` 命中陈旧 id 会绑到复用后的新拼写）——agent 须核实 `String.internAtom`/`createAtomBacked`（string.zig:302-345）满足，不满足则在 `finalizeDeadEntry` 之外补清。
- deinit：`releaseCachedStrings`/`atoms.deinit` 的 `str == null` 断言改为 deinit 自行清槽（S2 已把 body 内存交给块堆/extent 表 deinit）。

### 2.5 host/plugin（P）

`PropNameID.internStatic` → `entry.host_pins += 1`；`release` → `-= 1`；`traceRoots` 不上报（sweep 规则直接读 `host_pins`）。`binding/context.zig:228-239`、`runtime/plugin.zig:812 releaseAtoms` 同规则。ABI 语义不变（嵌入方仍需配对）。

### 2.6 影子审计（翻开关前的安全网，沿用 S2 经验）

comptime 开关 `gc.atom_tracer_owned`（默认 false）。开关关时：rc 语义原样，但 2.2 的边/根/屏障与 2.4 的判定**照跑**，`sweepDead` 不释放而是审计：`ref_count > 0 ∧ !live` ⇒ `gc: ATOM AUDIT missing edge id=… kind=… bytes=…`（Debug/`-Dzjs_gc_verify` 构建 panic，其余打印计数进 `--gc-stats`）。test262 + Octane 跑一遍审计读数为 0 才翻开关。这一步把「漏边」从翻开关后的 UAF 变成翻开关前的报表。

## 3. 三个缺口的裁决（待 owner；driver 建议加粗）

| ID | 缺口 | 选项 | driver 建议 |
|---|---|---|---|
| D-S3-1 | string atom 多数无 body，「body 被标记 ∨ 边」退化为「只看边」 | (a) atom 自带 mark 戳（2.1）；(b) 强制物化 body | **(a)**，已写入 2.1/2.4；(b) 多一次分配且改变 atom 的内存形态 |
| D-S3-2 | ~500 处 native 临时裸 id 跨 GC 无根（保守扫描认不出 u32） | (i) 只在 safepoint 清 atom 且禁止跨 safepoint 持有（与现状不符）；(ii) `AtomRootFrame` 机械替换 `defer free`（记账没少）；(iii) `internAtom` 一律物化 body 返回 `JSValue`（改全部 `getProperty(rt, atom)` 签名）；**(iv) 按来源分型**：L 字面量 → 预定义 atom `atom.ids.*`（qjs `JS_ATOM_*` 做法，零根零 intern 成本）；V 来自 JS 值 → intern 时绑定 `entry.str = body`，调用方本就持值根（活性走 body-mark）；B 裸字节 → 少量站点用 `AtomRootFrame`/`CompileAtomScope`；S 新建 symbol → 返回值路径 | **(iv)**；定量见 §4（勘察 2 待回） |
| D-S3-3 | `AtomTable.name()` 返回 `entry.bytes` 借用，sweep 驱动后跨 GC 即 UAF | (a) 复制返回；(b) 借用规则并入 `docs/borrowed_atom_audit.md` §8（借用 id 与借用 bytes 同规则：不得跨 safepoint） | **(b)**；调用者集中在 exception_ops/value_format/class/CLI，都是即用即弃 |

另两处会被打破的断言（规格已含）：atom.zig:1907（2.4）、atom.zig:1113/1120 deinit 断言（2.4 末）。

## 4. N 类临时 atom 分型（勘察 2，生产代码，工作树）

入口清单：`AtomTable.internString`（atom.zig:1313）← `JSRuntime.internAtom`（runtime.zig:3893）；`String.internAtom`（string.zig:328，body→id，命中 `atom_id` 时 dup）；`property_ops.propertyKeyAtom`（property_ops.zig:53，JSValue→id）← `object_ops.toPropertyKeyAtom`（:2433，前置 `toPropertyKeyValue` 可跑 JS）；symbol 家族 `newSymbol/newValueSymbol/internSymbol/internGlobalSymbol/internRegisteredValueSymbol`（atom.zig:1331-1361）← `JSRuntime.newSymbolValue`（runtime.zig:2750）；host `PropNameID.internStatic`（prop_name.zig:25）；`exception_ops.backtraceFunctionNameAtom`（:385）。免 intern 旁路：`atomFromUInt32`、`predefinedId`、`standard_globals.temporaryStringAtom`（已是 `predefinedId orelse internAtom` 的半成品，10 个调用点）。

| 来源 | 站点 | 处置 |
|---|---|---|
| **L 字面量** 直写 136 + 经 wrapper（`defineValueProperty/defineNativeDataMethod/…`）传播 51 = **187** | 去重 63+118 个名字；已在 `predefined_atoms`（655 条）内 48+66；**需新增生产名 ≈ 8 直写**（`alphabet/lastChunkHandling/omitPadding/padding/mode/prepareStackTrace/type/userAgent`）**+ ~30 传播**（Math 常量 `E/LN10/…/SQRT2`、`Array.fromAsync` 状态 `k/mapfn/this_arg/iter/items/len/phase/state/pending/rejected`、`fileName/lineNumber/columnNumber`、`code`、`error/suppressed`、`url/main`、`read/written`）；test262 host / binding 自检 / harness 名不进表 | 全部改 `atom.ids.xxx`（常量，永久 pin），删 `defer free`；8 处 `catch return` 吞错的 intern 顺带消失 |
| **V JS 值** 42（`propertyKeyAtom` 10、`toPropertyKeyAtom` 30、`String.internAtom` 2） | 值根来源：VM 栈（vm_property_ref/field）、native 参数数组（object_builtin_ops/reflect_ops）、`rootValues` 帧（vm_literal、json_ops）、`PublicValueRootWindow`（binding/context.zig:356-398）；两处弱根：object_ops.zig:1929（`key_value` 仅由 `trap_result` 间接持有）、promise_ops.zig:1783（依赖 `keys` 数组存活） | `String.internAtom` 保证 `entry.str = body`（已是：命中缓存或 `cacheString`）→ 活性走 body-mark；symbol 值本身是 tracer-owned；数字 key 免 intern。两处弱根改 `rootValues` |
| **B 裸字节** 运行期 **39**（+ 编译期 11 归 `CompileAtomScope`，测试基建 1） | host bytes（binding/context.zig 272/346/362/378/654、prop_name.zig:26、class.zig:458、plugin.zig:459）；JSON 键（json_ops.zig 597/995/1260/1274）；模块路径/说明符（module.zig 768/1000/1196/1344/1352、module_graph.zig 342-2201 共 16 处，其中 4 处 host hook 可重入）；正则命名组（object_ops.zig 1222/1259、regexp_fastpath.zig:499）；`propertyAtomFromLengthIndex`（object_ops.zig:1734）；eval 文件名（eval_entry.zig:58）；backtrace 名（exception_ops.zig:393） | 新 `runtime.AtomRootFrame`（形态照 `ValueRootFrame`，`rt.rootAtoms(.{&a,&b})`，slice 形 `rootAtomList(*ArrayList(Atom))` 覆盖 plugin.zig:452 / module_graph.zig:2201 / `appendOwnedAtom` 系列的非 GC `[]Atom`）；`RootVisitor.atom` 上报。`PropNameID`/class 表/backtrace 走 2.5 与 2.2 根 |
| **S symbol 创建** 9 | `Symbol()`（object_ops.zig:1350）、private/brand（object_ops.zig:4367、vm_value.zig:114）、parser 私有名 3、runtime.zig 2752-2759 | 立即包进 JSValue 或存 shape，无裸持有；无需改 |

结论：D-S3-2 取 (iv)。`AtomRootFrame` 只需覆盖 ~39+ 站点，而非 500；`defer atoms.free` 样板在 L/V 两类整体消失。

## 5. 分批与门

| 批 | 内容 | 门 |
|---|---|---|
| S3-a | 2.1 字段（保留 `ref_count` 并存）+ 2.2 协议/边/根 + 2.3 屏障与黑分配 + 2.4 `sweepDead` 审计模式 + 2.5 host_pins；开关关，行为零变化 | test / stress / diag；test262 + Octane **审计读数 0** |
| S3-b | 编译作用域 provider（K/L/M）+ G 帧盒 + N 类按 D-S3-2 分型改造（L→预定义、V→body 绑定、B→帧）；仍在开关关下审计 | 同上，审计 0 |
| S3-c | 翻开关：`sweepDead` 真释放；删 `ref_count/dup/free/replace/refCount` 与 960 处测试样板；135 处 `refCount` 断言改为「GC 后 `atoms.name(id) == null`」判据；`check_borrowed_atoms.js` 规则更新（§8 章节号不可重编） | 四门 + leak census 0 + 新测试「atom 条目数在 major 后回落」+ Stage 0 |
| S3-d | 删开关与 rc 残迹；文档 | 四门 |

规模（勘察估计）：生产 ~1.4k 行触碰、测试 ~1.1k 行（大部分机械）。

## 6. 风险

- 漏边 = 翻开关后的 UAF；由 2.6 审计前置消解，审计必须覆盖 test262 全量与 Octane。
- `sweepDead` 每 major 线性扫 `entries[]`（10^4–10^5 条）：与 `destroyCondemned` 同量级，Stage 0 记账 `major` 停顿行。
- L 类转预定义会扩大 `predefined_atoms` 表（656 → ?）：预定义 id 空间与 `first_dynamic_atom` 边界、`predefined_hash_next` 表同步，属机械改动但要重生成快照。

## 7. 执行记录

- **S3-b L 类（2026-09-04 下午，`s3-predef-20260904` = 10bcfbf2..373d2f66，已 apply 进主树）**：生产侧直写字面量 `internAtom` 134 处归零（勘察 136 中 2 处是 struct 内嵌 test 块）；24 个 wrapper / ~202 调用点改收 `atom.Atom`（`defineDataPropertyByAtom`、`defineNativeMethodWithRecordId`、`fromAsyncState*` 等），新增 `atom.predefinedName(id)` 从 comptime 存储取拼写（不分配、不回收，正是 S3 要的性质）；`predefined_atoms` 656→692（表尾追加，既有 id 不变；`ids.*` 是手写常量需手补，哈希表 comptime 自动；新增 `ids.zjs_last_predefined_key_name`）；另补 69 个已在表但缺 `ids.*` 的常量。留下 63 个 wrapper 字面量点：closure.zig fixture 名 32、test262 host 24、`predefinedId(...).?` 模式误报 3、`createNamedErrorWithoutStack` 2、`closure.getByName("globalThis")` 2。生产剩余 194 处 `internAtom(` 全是动态参数（V/B 类）。门：test 2497/0、stress 2493/0、test262 0/49778、borrowed-atom 检查器 0 escape。**顺带发现**：`check_oom_panics`（string.zig:1356 `catch @panic`，S2 carrier 遗留）与 `check_gc_slots`（allowlist 陈旧条目 `DeferredWeakValueFree::value`）在基线上就红；`temporaryStringAtom` 尚有 22 个表驱动动态调用点（B 类，可改表存 `Atom`）；`predefinedId("…").?` 模式数十处可换 `ids.*`；closure.zig 是否算生产面待 owner 裁决。
- **S3-a 基础设施（同日，`s3-infra-20260904` = 8c6627b4..e12f3f3b，已 apply 进主树）**：开关 `gc.atom_tracer_owned = false`（gc.zig:59）；`DynamicAtom` 新增 `mark_epoch/born_epoch/host_pins`（与 `ref_count` 并存，终态再合并字宽）；`RootVisitor.visit_atom` 可选回调 + `atomRoot(id)`；`atom.callVisitAtom` 一份共享 comptime 壳（偏离：不是 4 份复制）；`Collector.visitAtom`（value-symbol 连带 shade body）。边落点：A `Shape.traceChildEdgesFallible`；B/C/D/H `gc_trace_stw.traceFunctionBytecodeAtoms`（复用 `atomOperandIterator`，H 经 `rt.small_inline_trace_atoms` 回调缝，因 core 不能 import exec）；E `ModuleRecord.traceChildEdgesFallible`（`star_exports` 无 atom）；F `FunctionPayload.traceNativeRealm` + `IteratorPayload.traceChildEdges`；I/J `JSRuntime.traceAtomRoots`。屏障：`AtomTable.dupForHolder` = dup + `shadeAtomIfMarking`（谓词 `rt.gc.concurrent.markingActive()`），替换 43 处持有者 dup；body 走 `Registry.shadeCellForAtomBarrier`；`AtomTable.owner_runtime` 供 parser/compiler 的独立表退化 no-op。黑分配 `stampBirthEpoch`。P 类 `pinForHost/unpinForHost`。**审计放置点纠正**：增量 major 在 finish 只 condemn、析构分片到后续 poll，已判死未析构的 shape 仍持 `ref_count` → 第一版读数 97% 假阳性；改到 `destroyDoomedSlice` 的 `drain_complete` 分支（STW 路径仍在 `destroyCondemned(true)` 后）后 JS 负载读数 **missing-edge 0**（两个探针脚本 16k/9k 条目）。单测里 ~250 条 `ATOM AUDIT` 全为 Zig 测试自持裸 id 与 parser 私有名（N/K 类），无漏边。不变量 `atom_id ⇒ entry.str == body` 对动态 string atom 成立（`cacheString` 1:1），tagged-int/预定义 id 例外但永不回收，无需补清。`onSymbolBodyDead` string 臂已按开关分叉。门 test 2503/0。未测性能（shape trace 多遍历属性键、FB 多扫字节码）。
- **S3-b 编译作用域（同日，`s3-compile-20260904` = a1f05783..b640193c，已 apply 进主树）**：`atom.CompileAtomScope`（`init/activate/deinit`，provider trace = `for ids: atomRoot`；分配走 `persistent_allocator`，compile 期间 `memory.allocator` 是 arena）。**偏离规格（采纳）**：记录做成 ambient——`AtomTable.compile_scope` 指向最内层活动 scope，`internString/internGlobalSymbol/internRegisteredValueSymbol/internDynamic/dup` 五个汇流入口各加 `noteCompileScope(id)`，前端 189 个取 id 站点零改动、构造上不可能漏；`recent[64]` 直接映射去重。挂接：外层 `compile_entry.compile`（parser.zig:16604，覆盖 filename/carrier/诊断/module 转移），内层 `parser.State.atom_scope`（`initRootEmitter` 构造、`compileQjsProgram` 落位后 `activateAtomScope`、`State.deinit` 最后析构）；`compiler/test_entry.zig` 的按值返回 harness 不激活。实测 typescript-compiler.js 内层 27,875 个 id（112KB）。187 个 `free` 与 `dup` 配对原样保留（开关关，S3-c 再删）。**审计对账更正**：基线 231 条 `ATOM AUDIT` 无一来自 parser/compiler（`pushPrivateSymbol*` 是 vm_value.zig 测试块造的），全部是 Zig 测试自持裸 id（N 类，归 `AtomRootFrame` lane）。门 test 2513/0（+3 测试）。**新缺口（最重要）**：FunctionDef 的 cpool JSValue（字符串常量、子 FunctionBytecode）在编译期间无根，S2-f 让 string 分配也触发 GC 后成为真实 UAF 风险——已让同一代理续做（provider 同时上报 cpool 槽与 GC 指针字段）。其他未决：`atoms.dup` 多一次 nullable 判断在 exec 热路径（未测）；V2 harness 未激活 scope。
- **S3-b 运行期根（同日，`s3-roots-20260904` = 42390ef4..8a29e15f，已 apply 进主树）**：不另设类型，`ValueRootFrame` 加第四类成员 `atoms: []const AtomRootSlot`（`single: *const Atom` / `list: *const []Atom`，list 指切片头故 realloc 自动覆盖）；`rootAtoms/rootAtomList/rootAtomSlots`；**atom 帧在生产构建必须链上**（保守扫描认不出 u32，`activate` 判据改 `container or hasAtomRoots()`）。落点 `rootAtoms` 31 处、list 12 处。B 类 39 条：binding 5 帧；`internStatic` 不加（host_pins 即根）；`class.Table.register` 改先 `ensureCapacity` 再 intern（分层禁 import runtime，消窗口）；plugin/module_graph 的 `[]Atom` 只根已填前缀；json_ops 4 窗口 + `stringify` 顶层 list；module.zig 1343/1351 无窗口；exception_ops:393 直落 backtrace 帧无需帧。`appendOwnedAtom` 系 6 处 `rootAtomList`。V：代理 ownKeys 的 `trap_result/key_value` 加 `rootValues`；promise 那处已在帧内。G：`ReturnContinuation.proxy_get` 在 `traceEntryExtras` 上报 + `completeProxyGetContinuation` 加帧；`PendingPropertyDescriptor` 新 `PendingDescriptorRoots` provider（id + 三个 JSValue）；`LengthIndexAtom`（~60 调用点按值穿）与 `temporaryStringAtom`（22 处表驱动）改用 **`host_pins` 显式 pin**（S3-c 若拆 host/引擎内部计数要一起改）。审计 231→231（全为测试自持与 parser 私有名），生产路径 0；两条「窗口内每次分配都 major」的强测试（JSON.parse 两解析器、host `defineDataProperty`），删帧即红。门 test 2512/0。**规格外真窗口**：`JsonParseRecord.entries[].atom` 与 `.value`（reviver 删属性后 record 成唯一持有者）未处理；同型站点 function.zig:262、object.zig:7637/7710 未动；`vm.return_payload` 从 `popReturn` 到分派之间靠「不分配」论证。
