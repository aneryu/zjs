# zjs → QuickJS 忠实对齐计划（keystone-first）

> 决策已锁（2026-06-22，grill-me 收口）。本文件是逐项对齐 checklist 的正典。

## 0. 操作原则（不可违背）

1. **忠实对齐 qjs = 全局性能最优的目标基线**，不是可被局部 microbench「赢」二次质疑的步骤。
   先对齐到 qjs，建立干净、均匀、可对照的基线，**再**在其上、用严谨方法谈「超过 qjs」。
2. **不信任 agent 声称的局部「赢」**。历史背书：fusion 作弊层曾把 geomean 刷到 0.716，不泛化，已被
   `06e4389`/`764d823` 物理删除。凡 zjs 偏离 qjs 之处，默认一律回退到 qjs 结构——包括那些
   被审计标为「赢」的（符号 atom-id、双 transition、dup proto、小 shape 线性扫）。
3. **Zig 不构成墙**。qjs 地基的 4 处 C 机制全有忠实 Zig 等价物（见 §1）。现存偏离是**选择**，不是
   Zig 所迫。转写用 `extern struct/union` + `@ptrCast` + `@fieldParentPtr` + intrusive list + arena slab。
4. **唯一硬门是正确性**。`test262 0/49775` 是红线。若 qjs 的结构会让某 test262 用例回归（参见
   codex parser-align 的 7 回归：TDZ / eval-delete / 跨 realm），则保留**最小**必要偏离并记录；
   忠实让位于正确性，仅此一处。

## 1. Zig 等价物已证（Zig-墙消解）

| qjs 机制 | qjs 源 | Zig 忠实转写 |
|---|---|---|
| `JSAtomStruct == JSString`（同类型别名，非 punning） | quickjs.c:225-226 | `const JSAtomStruct = String;` |
| `JSRefCountHeader`（首字段，`(u32*)ptr-1` 访问） | quickjs.h:99-101,684 | `@ptrCast` / `@fieldParentPtr` |
| 侵入式 `gc_obj_list`（`list_head link` 内嵌） | quickjs.c:284,337 | intrusive `{prev,next}` + `@fieldParentPtr` |
| frame slab（arg/var/stack/var_refs 紧随 frame） | quickjs.c:793 | 从 `VmStackArena` 切一块连续 slab（zjs 不用 C 栈递归） |

字面不可达且**无需**：C `alloca`（zjs 无 C 栈递归）、computed-goto（dispatch 已用 `switch`+`continue :sw` 对齐反超）。

## 2. 验收门（每一项、反作弊）

- **每项硬门**：`test262 0/49775` + `zig build test` + ReleaseSafe + test-altrepr，不过不合入。
- **每项忠实检查**：对照它所镜像的具体 `quickjs.c:N` 做结构 code-review（「是否真的和 qjs 结构一致」）。
- **性能**：只在**相边界**对 qjs 测一次 sanity（不得回退于前相基线）；**永不**作为保留某单项偏离的理由。
- **GC 相补强**：S3/S5 的 weak/borrow desync 可被时序掩盖、test262 0/49775 抓不到 → 必须额外过
  **force-GC-on-every-alloc** 构建（每次分配前强制 GC，qjs `FORCE_GC_AT_MALLOC` 类比）。
- **风格**：每相一个（或一组紧致）大 commit，门禁后置。

## 3. 相结构（keystone-first）

```
Phase 0  Keystone 规划（不出货代码）
Phase 1  Keystone：GC / value-refcount / frame 地基，忠实转写 qjs
Phase 2  下游：调用机制 / dispatch / 对象-属性 refcount 纪律（落在 qjs 地基上，6-7× 在此解开）
Phase 3  叶子：GC-无关忠实对齐 + 余下赢回退 + global-var 稳定 cell + builtin 上 prototype
```

### 文档地图（审查入口）

- `QJS-FAITHFUL-ALIGN.md`（本文件）— 原则 + 验收门 + 相结构总图 + 各相状态。
- `docs/qjs-align/` — **仍活跃的待办规格**（Phase 1 的施工蓝图 KEYSTONE + S1–S5 + Phase 2 规格已随 `e8c852b` 落地并退役，留存于 git 历史）：
  - `INLINE-CACHE-PLAN.md` — IC：get/put_field 已落地；**S3 = 退役 global_lexical_sync 镜像已 DONE（A4 `45e9f55`，2026-06-26）**（read-IC 子项 MOOT——script 顶层 let/const 读早是 cell deref，stale catalog 的「按名查找」是错的）；S4 poly/mega 非忠实目标（本版 qjs 无 IC）。
  - `GLOBAL-VARREF-PLAN.md` — ✅ 已落地（见 round-2 handover）。
  - `PHASE3-leaves-and-levers.md` — 余下叶子 + 大杠杆登记。
  - **`HANDOVER-perf-round2.md`（2026-06-24 收口，本轮总入口；2026-06-25 追加 method-dispatch slice）** — 5 commit（global var_ref 7×→2.35× · add_loc 融合累加 2.4×→1.3× · 全局绑定即权威 全局==局部 · **method-dispatch cascade hoist `b20d5b4`：`o.m(s)` 4.43×→2.30×、`p.step(s)` 4.85×→2.74×**）+ 方法论纠偏（对照 qjs 实现抹平偏离、perf 是结果）+ 关键事实（qjs 此机 16 字节非 8、NaN-boxing 是伪命题且预存编译失败）+ 剩余两深前沿。分支 `qjs-faithful-perf-round2`（叠 main 9fc72eb）。
    - **lazy function.prototype（2026-06-25，`18a2610`）**：`createBytecodeFunctionObject` 对每个 normal+has_prototype 函数**急切**建 prototype 对象 + `constructor` 反向引用 → 两个偏离合一：① `.prototype` 永不被观测的函数（回调/IIFE/工厂结果）白白分配；② `func ↔ prototype.constructor` **引用环**使 refcount 永远无法释放该函数，只能等环收集器。每迭代建闭包的循环因此付全套 mark/sweep（`destroyRuntimeCyclesWithValueRoots` ~10%）。qjs 用 lazy autoinit（`JS_AUTOINIT_ID_PROTOTYPE`/`js_instantiate_prototype` quickjs.c:17341）。zjs 已有 autoinit 基建（`Slot.auto_init`，~700 lazy builtin 在用）；加 `function_prototype` AutoInitKind，materializer 从 owner 函数对象推导 realm/constructor（单一共享 interned 描述符，无 per-function 增长）；装在 normal 非 class-ctor 函数上，generator/async-gen/class-ctor 保持急切。永不构造的闭包 → 无 prototype 无环 → refcount 回收。闭包/迭代 5.68×→3.90×，环收集器从 profile 消失；构造函数在 `new` 时照常物化。剩余闭包开销=函数对象创建（length/name 的 defineOwnProperty）——qjs 亦 lazy autoinit（下一切片候选）。**⚠️ 基准陷阱**：`zig build test*`（尤其 `-Dzjs_force_gc=true`）会用不同 build 选项覆写 `zig-out/bin/zjs`；force-GC 二进制每次分配前全量 GC → 分配密集基准读成 100–260×（纯伪象）。**测 perf 前必先 `zig build zjs`**。详见 round-2 handover「Benchmarking hazard」节。
    - **method-dispatch 发现（2026-06-25）**：method 调用是本轮最大**被低估**缺口（4.4–4.85×，比 fib 更糟且无处不在）。根因=`qjsArrayMethodFastCall`（array_ops.zig:193）对**每个**无 native-id 的 callee（即所有用户 bytecode 方法）跑 ~20 成员线性级联，每成员都以同一 `callableObjectFromValue(func) orelse return null` 开头 → bytecode callee 下整条级联是 ~20 次空转（占简单 method-loop ~30%）。提升该共有前置条件为单次 early-out（可证保行为：恰在每个成员本就返回 null 时返回 null，故 generic `Array.prototype.X.call(arrayLike)` 与同名 user-method shadow 字节级不变）。忠实于 qjs：OP_call_method 一次解析 callee 后按 magic 在 `js_call_c_function` 分发，从不 per-call 扫方法集。剩余 method 缺口=proto get_field IC 税 + call-machinery（帧）税，皆为共有广谱前沿，无 method 专属偏离。调查见 `array-cascade-faithful-gate` workflow（5 agent，证 receiver-gate 不安全：成员实现 generic array-like 语义只需 `receiver.isObject()`）。
  - `HANDOVER-global-varref.md` — global var_ref 下沉 + 33 回归 4 阶段修复细节。
  - `DISPATCH-TAX-FINDINGS.md` — 广谱 dispatch 税定性（结构已对齐；残差=跳转表基址未提升 ~26% + LLVM-vs-gcc op-body ~74%，非忠实可抹平）+ add_loc 融合。
  - `CALL-MACHINERY-QJS.md` / `FRAME-STRUCTURAL-ALIGN.md` — 帧模型偏离剖析（剩余最大单项，多周/高风险，需先出分步门控计划）。

---

### Phase 0 — Keystone 规划 ✅ 已完成（2026-06-22，13-agent workflow + skeptic 复核）

转写依赖图、逐结构 Zig 写法、Phase 1 commit 切分均已定稿并执行（蓝图 `KEYSTONE-DESIGN.md` 已退役，留存于 git 历史）。

### Phase 1 — Keystone（地基，qjs-faithful）✅ 已落地于 `e8c852b`

5 个严格有序大 commit slice 全部合入（三门绿 test262 0/49775 + 1223 单测 + 1223 force-GC）：

- [x] **S1 value-refcount + atom-string** — dup/free 热路径塌成 `gc.retain/release(*gc.Header)`；`JSAtomStruct=String` 别名 + seeded hash + masked free-list。
- [x] **S2 symbol-model**（Option B）— symbol 值 = 指向 refcounted String body 的指针；refcount 生命周期取代全局 unrooted-symbol GC 扫描。
- [x] **S3 gc-cycle-collector** — canonical header + `weakref_count` + 单次 pre-GC weak sweep 替 fixpoint；删 symbol-scan / value-roots resurrection。
- [x] **S4 object-shape-header** — `@fieldParentPtr` header punning。
- [x] **S4b shape-owns-proto** — SHAPE 入 `gc_obj_list` + proto 移到 shape（owning `*Object`）+ 删 Object 重复 proto 边。
- [x] **S5 frame-slab** — 删 `FrameRootScope`/`active_value_roots`，单 `FrameSlab` carve（args/locals/stack/var_refs）；top-level-let 单 cell byte-for-byte 保留（防 da34bc1 跨 realm 写穿）。

锚点：`JS_CallInternal` 帧建立、`JSStackFrame`（quickjs.c:410,793）、`JSRefCountHeader`、`gc_obj_list`/环收集器。施工细节见 git 历史（`e8c852b`）。

### Phase 2 — 下游（落在 qjs 地基上）✅ 已对齐（2026-06-26 bottom-up 审计确认）

> **2026-06-26 `zjs-bottomup-divergence-audit`（11-reader + synth）逐项对照 quickjs.c 核实**：Phase 2 调用机制层在
> 当前 HEAD（`eb85a49`）已忠实对齐 qjs。下列「未勾选框」实为后续轮次悄悄落地（文档 stale），审计已纠正。详见
> `docs/qjs-align/DIVERGENCE-CATALOG.md` §🧱 2026-06-26 bottom-up re-audit。

- [x] **调用机制（6-7×）**：`OP_call` 忠实 `JS_CallInternal` 入口；Bytecode view **按指针**（**DONE**：`InlineTarget.view`/`Entry.function`
      皆 `*const bytecode.Bytecode`；递归慢路径 `nested` 亦取 `ensureCachedBytecodeView` 缓存指针，**无** per-call 43-字段 memcpy——
      catalog 旧「rank 1 按值拷」前提是 FALSE）。4 KiB Machine memcpy 亦已消除（`Machine.chunks` 懒堆分配，默认空切片）。
- [x] **回溯懒构造**（**DONE** round-8 `29e93a6`）：删 per-call `ActiveBacktraceFrame`，改 `MachineBacktrace` 单链按需走 Entry 链
      （faithful `build_backtrace` quickjs.c:7571）。
- [x] **put_field 转移所有权**省 dup/free（**DONE**：`qjsPutFieldFast` vm_property_field.zig:359 直接将 value 移入 slot
      `lookup.value.*=value` + free 旧值 + `value_consumed=true`，无 dup/free 抖动）。
- [x] 对象-属性 fast path 的 refcount 纪律按新 value 模型对齐（**DONE**：F1 审计确认所有写路径 capture-old/write-new/destroy-old-with-OLD-flags
      锁步,无 double-free/UAF；16B accessor `?*gc.Header` 在 GC trace 中无损往返）。
- [x] **var_refs O(1) 借用**（**DONE** round-4 `698824e`）：热 inline 路径 `borrow_var_refs`（inline_calls.zig:403-407/493-498，
      `var_refs_borrowed` flag）+ 零拷贝 arg 借用——faithful `var_refs = p->u.func.var_refs`/`arg_buf = argv`（quickjs.c:17844/17841）。
      **余**：递归慢路径仍 per-element `.dup`（vm_call.zig:171），但那是冷回退（generators/async/derived-ctor/cross-realm），扩借用碰
      generator var_refs 挂起生命周期、零热路径收益 → 文档化的不可消除 ~1.3-1.5× 帧地板，REJECT 为目标。

**Phase 2 后的下一前沿**（bottom-up 审计排序，均 faithful/bounded）：
- [x] **S2** spread/rest 迭代器守卫 ⚠️ **正确性 bug → ✅ DONE 2026-06-26**（§0.4 红线优先;新 `appendSpreadValuesEnumerate` 忠实
      `js_append_enumerate`:总是解析 `@@iterator`+建迭代器,仅默认 Array Iterator(value)+builtin `next`+无 hole fast array(`len==count`)
      才 dense 拷贝,否则通用步进;从迭代器 target 读、对覆写后返回他数组迭代器仍正确。门禁 0/49775+1227+force-GC+12/12 手测)。
- [x] **C2** derived-ctor 删急切 `this` → ✅ **DONE 2026-06-26**（derived 早返回 `callFunctionBytecodeConstruct(this=uninitialized,
      ctor_this=undefined)`,不建实例不查原型——qjs `JS_CallConstructorInternal` 20837;base 保留急切 `js_create_from_ctor` 20842。
      受控实验证急切实例非 load-bearing(super() 用 new.target 在 base 建)。**bonus 修预存双读**:`Reflect.construct` + getter 原型 2→1。
      门禁 0/49775+1227+force-GC+10 baseline+9 边界。dispatch 2 孪生站点(7058/7082)留后续)。
- [x] **C3 slice A** generator resume throwaway slab → ✅ **DONE 2026-06-26**（`runWithArgsState` 对已启动 resume 跳 slab+init
      块,gate `is_started_resume and !need_original_args`;qjs 帧创建时一次性分配、resume 直接续 `JS_CALL_FLAG_GENERATOR` 17790。
      **门禁抓到回归**:initArguments 还重建 unmapped `arguments` 快照 `original_args` + 设 `actual_arg_count`,首版漏 → 59 个
      arguments-object 回归 → 修(need_original_args 走全路径 + skip 路径补 actual_arg_count)。perf 1M resume 11.13B→10.62B(~4.6%)。
      门禁 0/49775+1227+force-GC+13 gen+7 args。**slice B(result-obj-free for-of step)留后续**）。

### Phase 3 — 叶子（GC-无关忠实对齐 + 赢回退 + 大杠杆）

GC-无关忠实对齐：
- [x] 属性槽 40B tagged-union → **16B untagged**（**DONE 2026-06-26 `040f3ba`（L2）**：裸 untagged `Slot` union、kind 由 shape `Flags`（JS_PROP_TMASK）派生、`Accessor`=2×`?*gc.Header`；复用 codex stash 表示设计（它停滞在 mega-commit-on-stale-base + flag-less test harness,非设计问题）；落地关键=§4 纪律(typed-API chokepoint `propKindAt`/`asDataAt`、单一 `setEntryKindAndSlot` 配对 mutator、`destroy/dup` flags-by-signature 编译期逼出所有 caller、同 shot 修 exec.zig harness、保留 var_ref 环守卫);**Debug 裸 union 安全 tag 把 kind/slot desync 变响亮 panic**(抓到 3 个真 desync)。门禁 test262 0/49775(0 意外,6 known)+1227+force-GC) qjs `JSProperty`（property.zig vs quickjs.c:947-963）。
- [x] create 路径删冗余第二次 `findProperty`（rank 5，object.zig:8880/9240）—— prop_create 1.95×。
- [x] fast-array 增长改 realloc/remap（rank 6，object.zig:3382）；`Array.push` 多参快路径（rank 12）。
- [x] 算术臂接上 `tryInt32BinaryWindow`（rank 7，vm_arith.zig:175 零调用者）；`bothInt` 单测试（rank 10）。
- [x] string content-hash 懒算（rank 8）。
- [x] JS→C 分发线性探测 → kind-tag switch（rank 11，call_runtime.zig:478）。
- [x] parser peephole：jump-threading + 常量折叠（rank 13，resolve_labels.zig；编译期，修 69-70 过期注释）。

赢回退（回退到 qjs 结构）：
- [x] 小 shape 线性扫 → qjs always-hash。
- [x] 双 shape-transition → qjs 单 `find_hashed_shape_prop`（codex 验证全局 hash 覆盖 per-parent 语义）。
- [x] **string-off-cycle-list**（codex 更正 2026-06-23：qjs **有** rope `JS_TAG_STRING_ROPE`/`JSStringRope`，且
      string+rope **纯 refcount、不上 `gc_obj_list`**——字符串图无环 refcount 足够）：把 zjs string/rope/.slice **移出
      环收集器 gc list** → refcount-only、极小头，对齐 qjs；**保留 rope**（qjs 也有，**不** revert）。解开 S1 延后的 24B-header 耦合。
  （注：dup proto 指针回退已并入 keystone **S4b**；array count/length 拆分见下「大杠杆」。）

大杠杆（高侵入，flag-gated，test262 0/49775 把关）：
- [x] **global-var var_ref cell（已落地 2026-06-24）**：全局 `var`/function 声明建 `JS_PROP_VARREF` cell（qjs `js_closure_define_global_var`）、`.global` 闭包变量别名该 cell、OP_get_var/OP_put_var 直接 deref（qjs OP_get_var 二合一）。**global-read 76.6B→31.3B（7.08×→2.45× over 真实 baseline）、global-write 69.4B→23.3B（6.70×→2.98×）、fib 中性零回归**。33 个作用域回归全修（4 阶段，每阶段 test262 0/49775 + 1223 单测 + force-GC）：① `directEvalGlobalVarNeedsRef` 排序对齐 qjs（force_init 让位 binding-match，17059-17071）② threaded get_var/put_var lane 补 generator stop-boundary 守卫 ③ 既有全局属性不再转 var_ref（qjs 17171-17205 detached var_ref）④ fast lane 加 parent-eval-shadow 守卫（qjs var_object_test 33158-33167）。详见 `docs/qjs-align/HANDOVER-global-varref.md`。**余**：编译期 `parent_has_eval` 标志（零运行期开销，eliminate ④ 的 per-access 守卫）是后续忠实精炼；发现一个**预存** TDZ bug（hoisted 函数前向引用顶层 let，clean HEAD 同样失败、test262 不可见）。
- [ ] **builtin 方法上 prototype**：每个 builtin 方法物化为各 prototype 的真 own-property（qjs 结构）。
      method_call_loop 7.06×。须解 null-proto 内部数组的方法解析。
- [x] array `count`/`length` 拆分 → qjs 尾部虚 hole 表示（撤 zjs 的 count==length 融合）。**DONE 2026-06-26 `9e81f1c`（L3）**:加 `array_length: u32` Object 字段(非 qjs prop[0].u.value——与 zjs 既有 count/capacity 字段惯例一致、且与 L2 解耦);`new Array(n)` 现 born-dense holes;**去险关键=zjs 数组层本就 count-aware 写的**(`[count,length)` 分支是「正确的死代码」,拆分激活而非重写它们→可一次性);agent 额外修 4 个潜伏 bug(slice OOB/fill 漏洞/map 丢值/proxy-set trap),门禁抓到第 5 个(indexOf/lastIndexOf/includes dense 扫漏洞→加 `arrayElements().len==length` 守卫 fall through 原型感知循环)。门禁 test262 0 新增+1227+force-GC。蓝图 docs/qjs-align/L3-ARRAY-COUNT-LENGTH-SPLIT.md。
- [ ] 热属性/数组 opcode 臂寄存器驻留（rank 14，依赖 1/4/5/9 先落）。

## 4. do_not_align（全量忠实后近乎清空）

全量忠实 = 一切转写 qjs，连「正确性-故意」项也采用 qjs 的实现（weakref/finalization resurrection、arguments
语义、cross-realm 都对齐 qjs 的做法）。**唯一保留偏离的触发器**：该处 qjs 结构会让某 test262 用例回归——
此时保留最小偏离 + 记录（§0.4）。
