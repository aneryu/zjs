# RC 收集器退役(2026-08-29)

分支 `gc/rm-rc`,基线 `main@6e5d7a69`("gc: flip the production default to the
tracing collector (Stage 7)")。owner 裁决:refcounting 收集器整个退役,回滚故事
改由 git 历史 + 冻结二进制承担,不再由构建开关承担。

本文是这次退役的账本:删了什么、留了什么以及为什么、锚等价的口径与记录、测试
收编、以及三个"删了发现是活的"的案例。

---

## 1. 分支与提交

| commit | 批次 | 变更 |
|---|---|---|
| `907ad157` | 1/6 收缩选择面 | 2 文件,+42 −33 |
| `a8dcdb0b` | 2/6 trial-deletion 环收集器 | 3 文件,+27 −491 |
| `e97e1bb4` | 3/6 gc.zig 的 rc 表示层与 rc 专属相位 | 4 文件,+137 −304 |
| `8607cec2` | 4/6 shadow 观察者 | 21 文件,+107 −1878 |
| `251558fa` | 5/6 全树剩余 rc 分支 | 30 文件,+435 −1206 |
| `ea71c549` | 6/6 CI / gate 脚本 / 发布文档 / CHANGELOG | 5 文件,+123 −104 |

合计(`src/` + `build.zig` + `build/` + `tools/` + `.github/`):
**46 文件,+746 −3916,净减 3170 行**。只算 `src/`:+706 −3874,**净减 3168 行**。

净减最大的十个文件:

| 文件 | 净减 | +/− |
|---|---|---|
| `src/core/gc_shadow.zig` | 523 | +0 −523(整份删除) |
| `src/tests/exec.zig` | 474 | +6 −480 |
| `src/core/object_gc.zig` | 445 | +17 −462 |
| `src/tests/core.zig` | 366 | +62 −428 |
| `src/core/object.zig` | 344 | +118 −462 |
| `src/core/gc.zig` | 224 | +133 −357 |
| `src/runtime/plugin.zig` | 174 | +5 −179 |
| `src/cli/run_test262.zig` | 144 | +11 −155 |
| `src/cli/zjs.zig` | 76 | +80 −156 |
| `src/runtime/event_loop.zig` | 70 | +0 −70 |

`src/gc-representation-snapshot.txt`(rc 布局快照基线,42 行)整份删除,只留
`gc-representation-trace-snapshot.txt`。

---

## 2. 锚检查:口径是怎么定下来的

**这一节比结论重要**,因为最初设想的判据在本机根本达不到,而搞清楚"达不到"
本身花了五次构建。

### 2.1 第一版判据:整文件 sha —— 作废

从 `6e5d7a69` 干净构建两次(其中一次先 `rm -rf .zig-cache`),
默认 ReleaseFast 二进制整文件 sha256 完全相同:
`8b56c706…`。看起来判据可以是"候选两次构建复现锚的 sha"。

但第一批改动之后整文件 sha 就变了,而 `cmp -l` 显示前 1500 万字节完全相同,
差异全部从 15029425 字节之后开始 —— 那是 DWARF 区。**删/增源码行会重排行表,
机器码一字未动整文件 sha 也必变**。整文件 sha 作废。

### 2.2 第二版判据:节内容 sha —— 也作废

改为比对 `.text/.rodata/.data/.data.rel.ro/.got/.got.plt` 的节内容 sha 加
`.bss` 尺寸。第一次跑通过了,再跑一次却不通过 —— 于是做了决定性的校准实验:

**只往 `src/core/gc.zig` 里加一行纯注释,重建。**

结果:`.text` 从 3456064 变成 3454712,而且**与做了语义改动(把
`trace_stw_enabled` 写成字面量 `true`)的构建逐字节相同**。把注释改到一个
完全无关的文件(`src/core/shape.zig`)里,得到的还是同一个 sha。

⇒ 这 1352 字节的差是构建系统的抖动,不是改动的效应。节内容 sha 判据作废。

### 2.3 抖动的形态

`nm -S` 逐符号比对告诉我们这个抖动长什么样:

* **符号集合完全不变**,零增零减;
* 174 个函数的尺寸各差几字节到几百字节,净 ±1400 左右;
* 名单里有 `Io.Threaded.netLookup`、`compiler_rt.memmove.memmoveFast`、
  `parser.parser_core.parseClass` —— 与 GC 毫无关系的函数。

删除声明还会重排 Zig 的匿名 decl 编号(`__anon_170887` 之类),把同样的抖动
再放大一层。

### 2.4 现行判据(v4)

`.scratch/anchor_check.py`,三条,第一条是硬条件:

1. **归一化符号名多重集合必须与锚逐个相同**(抹掉 `__anon_N`/`__struct_N`
   编号后比对)。删到活肉一定会少掉或多出符号,这是本机能给出的最强判据。
2. `.text` 总尺寸变化落在抖动包络内(≤ 0.1%)。
3. 单个符号尺寸变化 > 64 字节的一律列出,由人逐条解释。

### 2.5 逐批记录(对 pristine 锚 `zjs.run1`,`.text` 3456064)

| 批 | .text | Δ | 符号集合 | >64B 移动 | 解释 |
|---|---|---|---|---|---|
| 1 | 3454712 | −1352 | 相同 | 26 | 全部是 §2.2 的布局抖动(纯注释对照证明) |
| 2 | 3454712 | −1352 | 相同 | 26 | 同上。`nm` 显示锚里 object_gc 只有两个符号,删的全是 comptime 死码 |
| 3 | 3456000 | −64 | 相同 | **0** | −64 = 删掉 `Phase.remove_cycles` 后 `Object.destroyFromHeader` 少一次枚举比较(908→904) |
| 4 | 3455808 | −256 | 相同 | 1(`collectMinor` −184) | `last_report` 少一个 `usize` 字段要清零 |
| 5 | 3454392 | −1672 | 相同 | 26 | −1352 抖动 + 前两批已解释的部分 |
| 终态 | 3454392 | −1672 | **相同(3369 == 3369)** | 26 | 同上 |

**结论:整条分支没有一个符号被增加或删除。** 唯一有意的机器码变化是
`Phase.remove_cycles` 退役带来的四处运行期枚举比较消失
(`Object.destroyFromHeader`、`FunctionBytecodeImpl` 的两处保尺寸判断、
`phaseIsTwoPassTeardown` 的所有内联点)。

⚠️ 这套口径有一条必须记下的教训:**同一份源码在本机会在两个布局之间非确定地
落点**(3456064 与 3454712),而且 `zig build` 的缓存命中与否不能预测落哪个。
一次比对不等价不代表删到了活肉,必须先用"纯注释对照"确认包络。

---

## 3. 删除清单(按模块)

### 3.1 构建面(`build.zig`, `build/config.zig`)

`-Dzjs_gc` 保留为只有一个合法值 `trace_stw` 的选择器。传 `rc` 或 `shadow` 得到
迁移说明而不是"未知选项":

```
error: -Dzjs_gc=rc is no longer available: rc collector removed 2026-08-29;
use a frozen binary or checkout before 6e5d7a69
```

`-Dzjs_experimental_gc=off|trace_stw` 保留为接受但冗余的兼容别名 —— 大量 gate
脚本和发布自动化仍在传它。两处 "valid only in trace_stw builds" 的守卫删除
(`zjs_gc` 已经装不下别的值,它们永远不可能开火)。

引擎侧 `gc.trace_stw_enabled` 变成 comptime `true`、`shadow_tracer_enabled`
先变成 comptime `false` 再在第 4 批整个删除。**保留 `trace_stw_enabled` 这个
符号名是有意的**:全仓约 270 处 `if (comptime gc.trace_stw_enabled)` 因此一处
都不用动,它们各自塌到被取的那一支,而它们守着的 `else` 支就是被删的东西。

### 3.2 trial-deletion 环收集器(`src/core/object_gc.zig`,1018 → 573 行)

* `destroyRuntimeCyclesWithValueRoots` —— gc_decref / gc_scan /
  gc_scan_incref_child2 三趟驱动;
* `gcDecrefChild*` / `gcScanIncrefChild*` / `gcScanIncrefChild2*` 六个子节点更新器;
* 这一轮专属的弱引用清扫:`gcRemoveWeakObjects`、`sweepDeadWeakRootSlots`、
  `sweepDeadWeakPayloadReferences`、`weakIdentityIsLive`(object.zig 里另有一份
  同名私有函数,是活的);
* `releaseCallbackOwnedFunctionBytecodeCycles` 及其七个辅助 —— rc 的末次引用
  重建趟,函数体第一句就是 `if (comptime trace) return;`;
* `object.zig` 的三个再导出、`runtime.zig` 的 `else` 分支与 teardown 调用点。

tracer 侧存活的三个入口(`drainCycleDeferredFrees*`、
`trySettleTracerBlockCorpse`、`enqueueFinalizationCleanup`)各自去掉 rc 臂。

### 3.3 rc 表示层(`src/core/gc.zig`,5264 → 5087 行)

* **`BlockHeader`**(16 字节 qjs 双链节点)整个删除,`Header` 直接是
  `TraceHeader`(8 字节)。随之删掉侵入式链表里全部 `prev` 维护:
  `listInit` / `listAddTail` / `listDelAfter` / `listPrevious` /
  `headerLinked` / `DeferredFreeStack.pop` 的 rc 臂,以及
  `verifyCircularHeaderList` 的双向一致性检查(单链表里没有反向边可查);
* 生命周期字的 rc 读写路径:`headerRefCount` / `setHeaderRefCount` /
  `headerRefCountIsZeroOrHusk` / `headerIsReclaimableWeakHusk` /
  `setHeaderWeakHusk` / `resetHeaderLifetimeForPublication` /
  `assertInitialHeaderLifetime` / `release` 各自的 rc 臂;
* **`Phase.remove_cycles`** 退役(唯一生产者是 3.2 删掉的驱动)。
  `phaseIsTwoPassTeardown` 塌成 `phase == .tracer_destroy`;
* 标记状态的 rc 臂(`flags.mark` 位)从 `headerMarked` / `setHeaderMarked` /
  `tryAcquireHeaderMark` / `clearHeaderMark` 删除;`header_mark_epoch` 从
  `if (trace) u16 else void` 变成 `u16`;
* 八个 `if (comptime !trace_stw_enabled) return;` 早退;
* `releaseObjectForTest`(rc-only 测试助手)。

### 3.4 shadow 观察者(第 4 批)

判据就在 `gc_shadow.zig` 的文件头:"Observes the current RC heap: enumerate
allocated cycle-list objects through `RcRegistryHeapCensus`"。它观察的是 rc 的
堆。rc 的堆没了,它就没有观察对象;tracer 不需要它,因为 tracer 自己就在做那
件事而且带回收。

* `src/core/gc_shadow.zig` 整份(523 行)+ `core.root` 的导出;
* `string_registry_enabled`(定义就是 `shadow_tracer_enabled`)及它守着的
  字符串/rope 区间注册:`Registry.registerLiveStringRange` /
  `unregisterLiveStringRange`、`string.zig` 四处分配/释放的双臂与
  `freeStringStorage`、`gc_trace_stw` 的 `string_live` 报告字段;
* `--gc-shadow-check`:`zjs` 与 `run-test262` 两侧的 flag、字段、用法行、
  census 聚合器 `ShadowCensusAgg`、`maybeRunShadowCensus`、
  `ExecutionSummary` 的 15 个 shadow 字段、退出码里的 shadow 判据;
* `is_test or shadow` 形态的门一律塌成 `is_test`(`gc_write_audit` /
  `generator_state` / `collection` / `object.zig` 的 30 处写审计点 / `gc_slot` /
  `gc_address_registry` / `memory.zig` 的 `arena_addressable` / `runtime.zig`
  的两个 value-root 常量)。

`gc_conservative.zig` **保留** —— 它是为 shadow 写的,但 tracer 继承了它并且是
现在唯一的调用方;文件头注释已改写,"缺少保守栈扫描器的目标"现在是无条件编译
错误(以前只在 trace 构建下才是)。

### 3.5 全树剩余 rc 分支(第 5 批)

`shape.zig`(`ShapeOwnership` / `ShapeTraceListState` 不再是二选一)、
`context.zig` / `module.zig` / `var_ref.zig` / `bigint.zig`(12 个
`@offsetOf(...) == if (trace) A else B` 布局断言钉死到 A、四个
`if (comptime !trace) unreachable`)、`value.zig`、`memory.zig`(分配路径的
rc 臂)、`tailcall_dispatch.zig`(四个 frameless handler 的 rc 回落体)、
`runtime.zig`(三个 `if (trace) T else void` 字段、增长因子与 headroom 的 rc 臂、
`objectFromLastRefValue` 及其唯一调用者)、`object.zig`(六处对象创建路径的 rc
shape 分支,以及**整簇 rc 末次引用重建算法**:`collectInternalFunctionBytecodes`
/ `collectFunctionBytecodeCandidates` / `pruneNonInternalFunctionBytecodes` /
三个 `countFunctionBytecodeRefsFrom*` / `countDirectFunctionBytecodeRefs` /
`countOptionalFunctionBytecodeRef` —— 第 2 批删掉它们的入口后就已无人引用,
Zig 不会为未使用的私有函数报错,只能靠逐个数引用挖出来)。

### 3.6 CI / 工具 / 文档

* `.github/workflows/ci.yml`:删掉 `zig build smoke -Dzjs_gc=rc`;
* `tools/perf/gate_smoke.sh`:变体探针保留(它还能抓"传错二进制"),
  按收集器命名的措辞改写;
* `docs/tracing-gc-experimental-rollout.md`:重写为"rc 已移除"状态,回滚指引
  改指冻结二进制 / `frozen/gc-tracing-2026-08-26` / `6e5d7a69` 之前的 checkout;
* `CHANGELOG.md`:新增退役条目并修掉前一条里已过时的
  "Refcounting remains fully supported as the rollback"。

---

## 4. 保留清单(现役设计,不是 rc 残留)

| 保留 | 理由 |
|---|---|
| 字符串 / rope 的 4 字节 RC 前缀与 retain/release(`RefCountHeader` / `StringHeader` / `string_rc_prefix_size`) | tracer 不扫字符串:`gc_conservative.scanWords` 丢弃每个 `.string`/`.rope` 命中,`traceHeader` 把字符串当叶子,`JSValue.cycleMarkHeader` 永远不会产出字符串 header。字符串的活性就是这个计数 |
| `LifetimeWord` union 与它的 `.rc` 臂 | `.big_int` 仍在用:它在追踪堆之外,而 JSValue 的 payload-4 ABI 直接落在这个字上。这是 union 存在的唯一现役理由,注释已改写成这句话 |
| Shape / Realm 的真实 refcount(`trace_ref_count`) | 与活性无关。Shape 的 `rc == 1` 是"独占所有权"判据,它授权原地改形状而不是写时复制;冻掉它等于悄悄授权改一个共享的。Realm 是带显式 `JSContext.destroy` API 的宿主句柄 |
| `MemoryAccount` 与全部 trace 机器 | 不在射程内 |
| `destroyZeroRef` / `enqueueZeroRef` / `zero_ref_list` / `Phase.decref` | **看起来像 rc 残留,实际是活的**:见 §6.1 |
| `var_ref.freeVarRef` | 现在是显式空实现。tracer 拥有 cell,计数不维护,释放必须什么都不做。保留的是**形状**:`retain`/`release` 是 binding-identity owner 写死的所有权协议,`destroyOptionalVarRefCellSlice` 保留 qjs 的 finalizer 循环形状。空 release 内联后不花钱,删掉一半会留下一个每个未来 owner 都要重新发现的不对称 |
| `JSValue` 的四个 "assume object" release 变体 | 同上。Object 恒为 tracer 所有 ⇒ 恒为空操作,但它们是 VM handler 写死的值所有权协议的一半 |
| `gc_address_registry` 的 `.string`/`.rope` occupant 种类与 `string_live` 计数器 | **未删,记入剩余清单**。它们现在不可达(唯一生产者 `registerLiveStringRange` 已删),但拆它们要动保守扫描器要读的通用数据结构,不在本次射程内 |
| `object_gc.zig` 的特化 mark 臂 + 三个 parity 测试 | **未删,需 owner 裁决**:见 §6.3 |

---

## 5. 测试收编账

| | 数 |
|---|---|
| 锚(`6e5d7a69` 默认变体) | **2474 passed / 21 skipped / 0 failed** |
| 终态 | **2474 passed / 6 skipped / 0 failed** |

**passed 计数一个不动。** 少掉的 15 个 skip 正是被删的 shadow-only 测试:
exec 7 / core 5 / plugin 2 / event_loop 1(它们的第一句都是
`if (comptime !shadow_tracer_enabled) return error.SkipZigTest;`,在默认构建下
从来没跑过),连同它们的 7 个探针结构。剩下的 6 个 skip 与收集器无关。

其余处理:

* **48 个 `if (comptime !trace) return error.SkipZigTest`** 守卫删除。这些是
  **trace-only** 测试(rc 下跳过),在默认构建下本来就全跑,删守卫不改计数;
* **7 个 `if (comptime !trace) { rc半 } else { trace半 }`** 各留 trace 半;
* 两个用 `.remove_cycles` 打开两趟拆卸窗口的测试改用 `.tracer_destroy`
  —— 同一件事的 tracer 一侧,不是删除;
* 两个 flag 解析测试**改写而不是删除**:现在断言 `--gc-shadow-check` 被
  `error.Usage` 拒绝。理由与 build.zig 拒绝 `-Dzjs_gc=rc` 是同一条 —— 仍在传旧
  flag 的 gate 脚本应该当场失败,而不是安静地跑一个没有 census 的回合。计数因此
  保持不变,而覆盖是真的;
* "public property inputs remain exact during key coercion" 失去了 shadow 半,
  改名为 "public property key coercion accepts a Symbol.toPrimitive key" 并补上
  一句真断言(结果为 undefined),保住那一半从不依赖 shadow 的覆盖。

---

## 6. "删了发现是活的"

### 6.1 `beginDecrefPhase` —— 编译器当场抓到

第 3 批把 `beginDecrefPhase` 当成"随 rc 弱扫描一起死"删掉了,依据是它的唯一
调用者 `gcRemoveWeakObjects` 在第 2 批已删。编译立刻报
`no field or member function named 'beginDecrefPhase'` —— **tracer 的
`Collector.processWeak` 也在用它**,而且用的是同一条纪律(QuickJS 在
weakref_list 遍历外面套 DECREF 相位,好让 payload finalizer 不能把下一个 weak
holder 从遍历下面抽走)。已恢复并改写注释。

同一族的 `destroyZeroRef` / `enqueueZeroRef` / `zero_ref_list` / `Phase.decref`
经复核也全部是活的:`.deinit` 相位仍然靠它们排空堆,`.big_int` 与
`.realm_context` 也仍然走这条路。任务简报把它们列在退役对象里,**读实现后判定
不成立**,已保留。

### 6.2 机械展开 `if (comptime …) { … }` 会把 `defer` 提升出作用域

第 5 批用脚本批量展开 `if (comptime trace) { BODY }`。在
"proven object release preserves generic JSValue ownership semantics" 里,原来的
trace 半是:

```zig
} else {
    var kept: ?*core.Object = object;
    var roots = core.runtime.rootObjects(.{&kept});
    roots.activate(rt);
    defer roots.deactivate(rt);   // <- 作用域是这个 else 块
    helpers.reclaimNow(rt);
    try std.testing.expect(rt.gc.liveCount() > baseline_objects);
}
```

展开后 `defer roots.deactivate(rt)` 变成函数级,对象在最后一次断言时仍被 root
着 —— **测试当场红**(`expected 0, found 2`)。已改为显式裸块保住作用域,并把
全量 diff 里所有新增的 `defer`(共 4 处)逐个复核过,其余三处作用域未变。

教训:块展开不是纯文本操作,`defer`/`errdefer`/`var` 的作用域会跟着动。

### 6.3 `object_gc` 的特化 mark 臂 —— 保留,需 owner 裁决

`markOrdinaryObjectHot` / `markFastArrayHot` / `markShapeHot` /
`markPropertyDataSlots` / `markChildrenCold` / `MarkVisitor` 是 rc 的边枚举。
tracer 直接走 `traceChildEdges*` 这一权威,**不存在第二份枚举需要对齐** ——
所以 rc 走后,`collectCycleMarkChildHeadersForTest` 驱动的三个 parity 测试比较
的两样东西都只为测试而存在,已退化为自洽检查。

但删掉它们会把默认套件 passed 计数从 2474 降到 2471,而 2474 是本次退役的硬门。
**判断:留在原地,记入本文,由 owner 单独裁决。** `MarkMode` 因此只剩
`.collect_test` 一个成员,现状在代码注释里写明了。

---

## 7. 终门禁

| 门 | 结果 |
|---|---|
| 默认单测 `zig build test` | **2474 passed / 6 skipped / 0 failed**,exit 0 |
| `tools/perf/gate_smoke.sh <默认二进制> /tmp/gcgap-fixed 17 3` | **all clean**(3 ordinary + 1 arena-audit/stats run each);六个负载全 ok |
| test262 `./zig-out/bin/run-test262 -c test262.conf -t 8` | **0/49778 errors, passed 44584**,exit 0 |
| `ZJS_GC_ARENA_AUDIT=1` splay | exit 0,零 audit/mismatch/panic 行(Splay 3754 / SplayLatency 2739) |
| `ZJS_GC_ARENA_AUDIT=1` earley-boyer | exit 0,零 audit/mismatch/panic 行(EarleyBoyer 3395) |
| 锚等价 | 归一化符号名多重集合与锚**逐个相同**(3369 == 3369);`.text` −1672(其中 −1352 已由纯注释对照证明是构建抖动) |
| 迁移错误 | `-Dzjs_gc=rc` / `-Dzjs_gc=shadow` 各自给出迁移说明并退出 1;`-Dzjs_gc=bogus` 给出 "expected trace_stw";`-Dzjs_experimental_gc=trace_stw` 仍然构建通过 |

---

## 8. 剩余清单(本次未做)

1. `gc_address_registry` 的 `.string` / `.rope` occupant 种类与 `string_live`
   计数器 —— 现在不可达,但拆它们要动保守扫描器读的通用结构;
2. `object_gc` 的特化 mark 臂与三个 parity 测试(§6.3),等 owner 裁决;
3. `docs/tracing-gc-design.md` / `docs/gc-inventory.md` 里仍在描述 rc 与 shadow
   的段落 —— 那两份是设计史文档,改写它们是另一件事,不应混进这次删除;
4. `policies/gc_merge_policy.json` 与 `reports/evidence/BASE-G0/manifest.json`
   里对 `-Dzjs_gc=rc` 诊断臂的引用 —— 那是已发生事实的记录,不改。
