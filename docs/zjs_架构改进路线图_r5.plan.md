---
name: zjs 架构改进路线图 R5
overview: 第五轮架构审视（grill 会话，2026-06-13）的落地路线：迁移前清障（QjsWorker 死簇删除、OOM 门禁基建、throw/stack 原语化、豁免清零）→ Phase 6 builtins 依赖翻转大迁移（QuickJS 客户模型）→ Phase 7 调用形态手术（arrow 内联资格 + tail_call_method 帧复用）→ Phase 8 测量驱动的 GC/shape 余项。
todos:
  - id: pre-worker-removal
    content: "迁移前: QjsWorker 死簇整体删除（含公共符号 cleanupWorkersForRuntime 与 4 层转发链、3 个字符串分发点、object_ops worker parent 簇、root.zig hasDecl 测试），API 快照再生"
    status: completed
  - id: pre-throw-stack
    content: "迁移前: stack 附加收进 createNamedError 原语（预分配 OOM 零分配豁免）；throw*Message 家族迁回 vm_exception_ops；删便利 re-export"
    status: completed
  - id: pre-oom-infra
    content: "迁移前: OOM 五件套基建——静态 no-panic 规则进 architecture-check、test-oom 重生（corpus×checkAllAllocationFailures+恢复金丝雀）、-Dzjs_oom_coverage 覆盖率批评家、8MB cap 行为 fixture、预分配投递单测"
    status: completed
  - id: pre-regexp-libs
    content: "迁移前: regexp 字面量校验搬 src/libs（执行既定 exit_milestone，对齐 QuickJS libregexp），deps-allowlist 清零"
    status: completed
  - id: pre-small-items
    content: "迁移前: 小项——architecture_review.md 撤幽灵 bytecode/ic.zig 表述；LIMITATIONS.md 记 PTC 排除与失败形态；双值表示平台理由注记"
    status: completed
  - id: p6-record-table
    content: "Phase 6: comptime internal record 表机制落地（fn 指针类型与 id 命名空间留 core/host_function.zig，builtins 侧构建表，JSRuntime 持指针，exec 经 rt.internal_builtins[id] 分发）"
    status: pending
  - id: p6-pilot
    content: "Phase 6: Math/JSON 试点迁移，验证留/迁判据与表机制"
    status: pending
  - id: p6-sweep
    content: "Phase 6a: 16 个 domain 的慢路径分发全部走 builtins internal record 表（math/json/uri/number/date/error/function/primitive/iterator/collection/reflect/buffer/string/object/array/regexp）。已完成、全门禁绿；实现仍在 exec（双路径共用），见 6b。"
    status: completed
  - id: p6b-fastpath
    content: "Phase 6b-1: VM 快路径 callNativeBuiltinRecordForVm 也route through 表（exec 双路径零编译期 builtin 知识）。关键：快路径只有 global 对象无 globals 槽数组，需让 collection/error/function handler 对空 globals 回退 host.global。微基准门控热路径间接调用。"
    status: pending
  - id: p6b-relocate
    content: "Phase 6b-2 (进行中): object（−667 行）、string（−333 行）方法实现已搬进 builtins。**终态第一步已完成且验证**：vm_call.zig 四条 dispatch 路径全部统一走表（删 fastNativeMethodCall 热子集 switch + Math hybrid + 死代码），严格同机度量证明**删 bypass 性能中性**（new/old≈1.00，string_fromcharcode 反快 2.2×）——uniform 决策实证成立，bypass 是零收益架构债。below-QuickJS 的点（math 3-5×/array_foreach 10×）是预先存在的 property-IC+InternalCall ABI gap，非统一引入，留 cproto/lean-ABI 后续。连带修复：refAllDeclsRecursive 漏收 json_ops 的 2 个 GC-rooting 测试，已在 all_tests.zig 显式锚定。**①已完成**：array 残留 prepared 路径统一——vm_call.zig:1005 的 `.array` prepared 分支改走 `callInternalRecord`（func_obj=null），arrayCall/qjsArrayNativeRecord/qjsArrayPrototypeNativeRecord 容忍 null func_obj（仅 push/pop 经门 `arrayNativeSupportedWithoutFunctionObject` 到达，直调 *Impl），删 `qjsArrayPreparedNativeCall`。度量（同机 vs ../quickjs/build/qjs）：push 紧循环 zjs≈0.03s/QuickJS≈0.60s（zjs 快 ~20×，与旧 bypass 持平）；pop 紧循环 zjs≈2.98s/QuickJS≈1.57s——pop 旧 bypass 亦 <QuickJS（baseline≈2.78s），是预存 property-IC+InternalCall ABI gap，统一仅叠加 ~7% 既定 ABI 成本，按裁决不恢复 bypass。**②array 搬迁结论**：经逐函数 reachability 核实，与 String 不同，几乎所有 Array.prototype/static 实现体被 opcode 绑定的 fast-array fast-call（qjsArrayMethodFastCall）/map fusion（tryFastMapCallDense）直调 = BOTH，按 client model 核心留 exec、builtins 持薄 arrayCall 入口（已是现状）；唯 join/from/of 仅经 native-dispatch surface（表+call_runtime name cascade）可达但 from/of 缠绕 iterator/TypedArray-construction（留 exec）、且其 name-cascade caller 在 call_runtime.zig（本轮文件范围外），故本轮 array 不搬迁实现体（iterator 协议核心 qjsArrayIteratorMethodRecord 亦留）。**剩余**：③各 domain 剩余 delegation；④见 p6-flip-rule。"
    status: pending
  - id: p6b-terminal-design
    content: "终态设计（grill 裁决，纠正前一版「hybrid」误判）：**QuickJS 不是 hybrid**——源码证实它只有唯一 dispatch 路径 js_call_c_function（quickjs.c:17352），唯一专门化是 cproto 参数编组（f_f 让 Math 免装箱，在同一路径内），解释器无 per-builtin bypass，Array.push 是普通 generic_magic。zjs 的多条 bypass 快路径是 zjs 独有发明（让 zjs 快于 QuickJS，代价是钉死实现）。裁决：采 **QuickJS 统一模型**——一条路径（表）、所有实现搬 builtins、删除全部 bypass（含 fastNativeMethodCall 热子集 + array hub + Math hybrid）。**先架构后优化**：先纯统一（标准 InternalCall record，含 Math），度量基准 = ../quickjs/build/qjs（不是 zjs 旧 bypass）；zjs-统一只要不低于 QuickJS 水平就接受（=zjs 旧 bypass 的 ~5% 是统一既定代价）；若低于 QuickJS（被 11 字段 InternalCall 结构体拖累），修法是精简调用 ABI / 补 cproto-lean record，**不恢复 bypass**。cproto 与 lean-ABI 是测量门控的可选后续，非前置。lazy 物化经 prepared 路径走表（func_obj=null）已保留。"
    status: pending
  - id: p6b-relocate-done
    content: "Phase 6b-2 relocation 进度：object −667、string −333、collection −945（搬出 array_ops 的合并区，array_ops 6981→6036）已搬进 builtins。array 实现体留 exec（justified：被 fast-array fast-call/map fusion opcode 绑定 = VM op，非纯分发）。dispatch 统一全部完成（4 路径走表，含 array prepared 残留，性能中性已验证）。"
    status: completed
  - id: p6-flip-rule
    content: "Phase 6b-3 收口（**比预想大得多——core/builtin 边界纠正，多子项**，用户已裁 A）。**6b-3a 已完成**：sameValue→core JSValue 方法（删包装）、nativeFunction→core（纯下沉）、23 个 method-id 枚举→core/host_function.zig（值字节级不变）、TypedArray Tier A 13 个存储形状谓词→core/object.zig，共 ~350 exec 引用转 core，exec→builtins 30 文件→27、全门禁绿（test262 0/8142、1146/1146 Debug+ReleaseSafe）。**6b-3b 已完成**：TypedArray 元素读写 fabric + DataView 原语 + ArrayBuffer ops（全验证为纯原语，无 exec 依赖）搬进新 core/typed_array.zig，exec→builtins 引用 333→**249**（−84），全门禁绿（test262 0/3070、1146/1146）。**剩余 249 处（仍 27 文件——每文件多 domain，规则翻转是清完全部才触发的后置收益）按 domain**：string 38、collection 32、regexp 29、promise 28、date 28、buffer 23、array 14、uri 11、symbol/number/json 各 8、object 6。**按类**：method-impl 调用（exec 复用 builtin 方法体，~99，最难）、construct 路径（constructWithPrototype 34 + 构造 prims 17，须经表分发——独立 dispatch 子项，类比 call 路径统一）、name/registry 表（53，rehome）。下一步建议：构造 prims 现已只依赖 core.typed_array/object（6b-3b 解锁）可先搬 core；construct 路径经表分发是独立大子项；method-impl 按 BOTH 判据逐个判（exec 复用的若是 VM util 搬 exec、若是 builtin 方法体则 exec 改走表）。

**6b-3c/d/e 已完成**（exec→builtins 249→183）：6b-3c name 表(error_names/typed_array_names)+method-id 助手→core、构造 prims 纯的→core/含 getProperty 的→exec/typed_array_construct.zig；6b-3d/e construct 三分发器（construct.zig+reflect_ops+call_runtime）对 Date/RegExp/String 经表分发统一（建 callConstructRecord + InternalCall.new_target + InternalRecord.constructor flag），消除 std.mem.eql 字符串分发。**剩余 ~183 处是异质长尾**（无大块干净子项）：method-impl 方法体复用（call_runtime/string_ops/object_ops 等，最难，逐个 BOTH 判）、leaf glue（uri.call/string.charAtValue/symbol.description 等）、未接 construct（Array 需 ctor-id+call 路径/species/prepared 门联动、Promise 核心留 exec、collection adder/iterator 协议、class extends 超构造器）。规则翻转是全清才兑现的后置收益。**建议**：这种异质长尾用专门会话的系统性 grind（逐文件清 exec→builtins，每文件清零即移除其 import，全清后翻规则+退役 HostFunction 枚举+清 allowlist+重写 docs+删 p6-migration-pattern.md），或用 workflow 编排逐文件 pipeline。本会话已完成 builtins 翻转的全部高价值核心（dispatch 统一[性能中性已验证]+主体实现搬迁+引擎核心原语归位 core+construct 统一），建议先 squash 并 main 锁定。**剩余 333 处 exec→builtins 引用（27 文件），分类**：method-impl 调用 99（builtin 方法体，属方法搬迁/BOTH）、name/registry/id-helper 表 53（error_names/typed_array_names/registry/*MethodId）、TypedArray Tier B 元素读写 51（getIndex/setIndex/coerce/defineOwnProperty——缠绕 DataView/ArrayBuffer 共享的 ToNumber/ToBigInt coercion fabric，须先把该 fabric 整体搬 core）、constructWithPrototype 34（construct opcode 路径，须经表分发或文档化）、DataView 20、construction prims 16、ArrayBuffer 10。**每类是独立子项**，非单次收尾。完成顺序建议：先搬 TypedArray 共享 coercion fabric→core（解 Tier B + DataView + ArrayBuffer）、再 construct 路径经表分发（解 constructWithPrototype + construction prims）、再 name/registry 表归位、method-impl 按 BOTH 判据处理；全清后才能反转 `exec must not import builtins` 规则、退役 HostFunction 枚举、清 allowlist、重写 docs。原 33 处 import（30 文件）说明（保留）: **深查发现两类**：(1) id 枚举（StaticMethod/PrototypeMethod，prepared 门/id 比对）——机械下沉 core/host_function.zig 即可；(2) **真正的引擎核心原语**被 builtins 迁移误画进 builtins，被 VM opcode 直调：TypedArray 元素机制（isTypedArrayObject/typedArrayGetIndex/SetIndex/Length/OutOfBounds/Detached/canonicalNumericIndex，~200 处，property_ic/vm_property_globals 等调）、object.sameValue(25，value_ops/class_init 调)、function.nativeFunction、date/promise/regexp.constructWithPrototype。QuickJS 把这些放引擎核心。**裁决项**：(A) QuickJS-faithful——把这些引擎核心原语从 builtins 搬回 core/exec（TypedArray 元素机制是大而精细子系统），然后 exec 零 import builtins、规则反转。faithful 但工作量大。(B) 务实——承认这些核心原语留 builtins、规则只对 builtin 方法实现反转，文档化例外。less faithful 但小得多。推荐 A（边界本就该 core），但需 fresh-context 专项 + 用户确认范围。然后 HostFunction 枚举退役、allowlist 清零、docs 重写。

**=== 规则反转已完成 (LIVE) ===** STEP 0-8 全部落地（workflow 生成 8 步计划，逐步聚焦 agent 清除）：所有 exec 文件零 import builtins；check_deps.js 的 exec disallowed 已加 `src/builtins/`（builtins→exec 仍合法=客户模型），architecture-check 绿强制执行；引擎核心原语全归位 core（typed_array/promise/collection/json/regexp/number/symbol/uri/{error,typed_array}_names + sameValue/sameValueZero/stringIterator/method-id 枚举）；registry install 经 core 回调倒置（exec 不调 builtins）；construct 全走 callConstructRecord；method-impl 全走 callInternalRecord。**HostFunction 枚举不退役**——它是宿主助手（print/dstr/external-host）分发，非 builtin（builtin 走 NativeBuiltinDomain+表），正交保留，已文档化。allowlist 保持空。删除工作文档 p6-migration-pattern.md + p6-flip-rule-plan.md。architecture_review.md 加 4.1 Builtins 客户模型节。"
    status: completed
  - id: p6b-known-regression
    status: completed
    content: "**已修复并验证（Phase 7 会话复核：test262 全门禁 0/49775，与 pre-Phase-6 7ac38df 持平；Phase 6 工作已并 main，HEAD=6dc2100）。** 根因确认 setPrototypeOf 环检测的裸 error.TypeError 在 VM catch 用 caller realm(ctx.global) 物化，而 Phase 6 线程化的 callee realm 已正确到达（诊断实证 caller=realm1/global=realm2），改为 throwTypeErrorMessage(ctx, global) 即用 callee realm 抛出。test262 全门禁回 0/49775。教训：run-test262 是独立 binary，验证 exec 改动必须 `zig build run-test262` 重建（否则跑旧 binary 误判修复无效）。原始描述（保留）：**回归（squash 合并 main 后的全 test262 门禁发现，1/49775）**：staging/sm/object/setPrototypeOf-cross-realm-cycle.js——`gw.Object.setPrototypeOf(obj,w)`（realm 2 的方法）检测原型环时抛的 TypeError 用了错误 realm（caller 而非 callee gw）。根因：setPrototypeOf 环检测是裸 `error.PrototypeCycle => error.TypeError`（Phase 6 前就存在，7ac38df:5595），在 **VM catch 点经 handleCatchableRuntimeError(...caller global...) 物化**，绕过任何线程化的 callee realm。Phase 6 前 setPrototypeOf 走「realm-correct generic path」（fastNativeMethodCall 未处理 .object→落通用路径），Phase 6 改走表后该路径的 callee-realm 物化丢失。**已验证无效的修复尝试**：(1) callInternalRecord 内 effective_global=objectRealmGlobal(func_obj) orelse global；(2) setPrototypeOf 改 throwTypeErrorMessage(ctx,global,...)——均无效，说明到达 setPrototypeOf 的 global 仍是 caller realm（objectRealmGlobal 对该 lazy-materialized 跨 realm static 方法可能返回 null/错 realm，或路径未走 fastNativeMethodCall）。**正确修法（焦点会话，可用 run-test262 -f 该测试迭代）**：要么让 builtin 调用切 ctx 活动 realm 到 callee（QuickJS `ctx=cfunc.realm` 模型），要么确保 lazy 物化的跨 realm builtin 方法正确记录 owning realm（functionRealmGlobalPtr）使 objectRealmGlobal 可恢复，再把裸 error 改 throwTypeErrorMessage(ctx, callee_global)。**未并 main**：因此回归，main 已回退到 7ac38df（pre-Phase-6 全绿）；Phase 6 全部工作在 p6-builtins-flip 分支，修复此回归 + 完成规则反转后再并 main。"
  - id: p7-arrow-inline
    content: "Phase 7: arrow 获得内联资格（装箱规则收进两路径共享 frame setup 原语）。**已完成**：(1) `coerceCallThis`（call_runtime.zig）从 callFunctionBytecodeModeState 抽出的 [[Call]] this 装箱原语，递归慢路径与内联 pushFrame 共用——装箱规则归一处；(2) resolveInlineTarget 删 `is_arrow_function` 拒绝 + 加 receiver 参数，arrow 的 this_value=functionLexicalThis()、new_target=functionArrowNewTarget()（arrow 忽略 receiver），非 arrow this_value=receiver；InlineTarget 携 this_value/new_target（借用，callable 存活期内有效）；(3) pushFrame 经 coerceCallThis 装箱 target.this_value、用 target.new_target，替换原硬编码 strict?undef:global——plain 非 arrow 调用字节级不变（receiver=undef→装箱同旧）。fusion arrow（x=>x+1）仍被 fusion 检查挡在更快的 callSimple*Bytecode 路径。验证：arrow 词法 this/new.target/arguments/闭包捕获正确；arrow 非尾递归深度上限对称（function/arrow 都在 ~8192 内联存储上限处一致，改前 arrow 走原生递归慢路径上限低数量级）；test262 0/49775、Debug+ReleaseSafe 1147、arrow-function 目录 0/343。"
    status: completed
  - id: p7-tail-method
    content: "Phase 7: tail_call_method 帧复用（receiver 进 tailCallReuse 帧重建）。**比预想大——为兑现「method 位置深递归」目标须让方法调用整体进内联机器**（否则方法从顶层入口在 depth 0 运行，其 tail_call_method 的 allow_inline=depth>0 为假，退回递归）。落地四子项：(1) **RegionLayout 枚举**（plain `[callable,args]` / method `[receiver,callable,args]` / prepared `[receiver,args...,callable]`）统一三种操作数布局，InlineCallRequest 携 layout；pushFrame 的 callable/this/args 提取按 layout 分派，receiver 经 coerceCallThis 成 this（arrow 仍用词法 this）。(2) **tail_call_method 帧复用**：tailCallMethod 加 inline 快路径 + `.tail_inline` 结果，tailCallReuse 加 has_receiver（moved 缓冲 `[receiver,callable,args]`，receiver 经表 dup 成 this）。(3) **op.call_method 内联**：callMethod 返回 CallStep + 顶部 inline 检查，方法经内联帧运行→获逻辑深度上限 + 其尾调用复用帧。(4) **op.call_prepared 内联**（关键：`obj.method()` 在 finalize 被 prepared_calls.run 重写为 prepare_call_prop_atom+call_prepared，故常见方法调用走 callPrepared 而非 callMethod）：callPrepared 返回 CallStep，`.value` 目标 inline-eligible 时把 func 压回操作数栈顶（prepared 重写在 stack_size 之后发生，原 call_method 的 `[receiver,func,args]` 槽预算尚在→压栈预算安全且保 func rooted 至 pushFrame dup），返回 `.prepared` 请求。class 构造器被 resolveInlineTarget 拒绝→不遮蔽 super 路径。验证：method 自/互尾递归 1e5 从顶层入口 TCO（zjs 完成，QuickJS 不做 PTC→栈溢出）；异常穿透内联帧 catch、原始值 receiver 装箱、生成器/async 不内联均正确；test262 0/49775、call/object/function 目录全绿。"
    status: completed
  - id: p7-bench-fixtures
    content: "Phase 7: 微基准语料补 arrow case；method/arrow 位置 1e5 深递归 runner fixtures。**已完成**：(1) 微基准语料（tools/compare/microbench_cases.js）补 `arrow_call_loop`（arrow 调用循环，镜像 call2_loop）+ `arrow_tail_recursion`（arrow 尾递归非 fusion 体，深度 100×500 复用内联帧）——perf-self-check 75/75 兼容、0 验证失败、几何均值 zjs/qjs ~1.00。(2) Zig 单测 fixtures（src/tests/exec.zig）：「arrow and method tail calls reuse inline frames for deep recursion」40000 深（超 8192 内联存储上限→证帧复用而非仅内联）覆盖 arrow plain-tail + method 互/自 tail；「inlined arrow keeps lexical this and ignores any receiver」证 bound.call/method 调用不改 arrow 词法 this。test262 不覆盖 method/arrow 位置深尾递归，故自建。注：未刷新 reports/perf/baseline JSON（独立干净 perf 运行任务，新 case 已对照 qjs live 验证、不阻塞门禁）。"
    status: completed
  - id: p8-gc-header
    content: "Phase 8: GC 循环回收三 AutoHashMap→header 2-bit 状态机（专门会话+全门禁，先基准证收益）"
    status: pending
  - id: p8-shape-dedup
    content: "Phase 8: shape.props 与 object.properties 的 atom_id/flags 双份元数据去重（shape 持元数据、对象持值，QuickJS 模型；先基准证收益）"
    status: pending
isProject: false
---

# zjs 架构改进路线图 R5（builtins 翻转轮）

接替已全部完成的 R4 路线图（`zjs_架构改进路线图_cd73a21f.plan.md`，已按
完成惯例移出活动树，git 历史可找回）。本文是
2026-06-13 grill 会话的裁决记录与执行路线；前提事实均已核实并标注出处，
未来会话不应重新推导。

## 0. 方法与共识基线

审视方法：**QuickJS 透镜**——每处偏离参照实现的结构，要么有文档化的成本
评估（维持），要么回归参照形态（修正）。

### 维持原判（本轮复核后不再质疑）

- `zjs_parser.zig` 单体、generator 帧豁免 arena、`Bytecode`/`FunctionBytecode`
  双载体、顶层脚本不物化——architecture_review.md 已有成本评估。
- `runtime/`、`binding/` 位于 exec 之上，import exec 合法（check_deps.js 矩阵）。
- **双 JSValue 表示永久双模式**：QuickJS 以 `#ifdef JS_NAN_BOXING` 永久维护
  双布局，双模式本身就是参照设计；唯一余项是平台理由文档化（pre-small-items）。
- **Atomics 等待机制留 exec**：QuickJS 同样放引擎（quickjs.c:61234
  `js_atomics_wait`）；P6 期间顺势拆出独立 `exec/atomics_wait.zig` 即可。
- GC 三 AutoHashMap→header 2-bit、shape/object 元数据去重：维持「已评估
  待做、测量驱动」，排 Phase 8。
- **fun（../fun）是 zjs 下游**；fun 的需求与其 zjs-redesign 文档不反向影响
  zjs 架构判断（用户裁决：zjs 是基石，必须独立牢固）。

## 1. 决策记录

### D1 builtins/exec 依赖翻转（→ Phase 6）

**现状**：依赖规则禁止 builtins→exec，迫使 ~20K 行内建方法语义流亡
`exec/*_ops.zig`（array_ops 197 pub fn、string_ops 218、object_ops 211），
`builtins/` 退化为安装表+id 枚举；`exec/call.zig:305` 的 comptime
`host_function_records` 表与 `@intFromEnum(builtins.*.StaticMethod.*)` 比对
遍布分发路径——exec 在编译期知道每一个内建方法。

**参照**：QuickJS 中 builtins 是引擎内部 API 的**客户**，不是层——实现与
声明表同地共置（quickjs.c:45236 `js_array_proto_funcs`），函数指针分发
（quickjs.h:1323 `JSCFunctionListEntry`），context init 安装
（`JS_SetPropertyFunctionList`），VM 对具体内建零编译期知识。

**裁决**：翻转为 QuickJS 客户模型。终态验收四条：`HostFunction` 枚举删除；
`exec/*_ops.zig` 仅剩 VM ops；依赖规则反转为 `exec must not import
builtins`；deps-allowlist 清零。

**执行要点**：

- 分发：comptime 物化静态表（内建是编译期闭集，无需 external host 那种
  运行时注册），builtins 侧构建，`JSRuntime` 持表指针，exec 经
  `rt.internal_builtins[id]` 调用；fn 指针类型与 id 命名空间留
  `core/host_function.zig`。`ExternalRecord` 机制（runtime.zig:680）是
  同构先例。一次间接调用与现有 600 分支 jump table 同级。
- 留/迁判据：被 opcode handler / VM 内部直接调用 → **留** exec（VM op）；
  仅经 native 函数对象分发可达 → **迁** builtins。判定按 class 做调用点分析。
- 顺序：Math/JSON 试点 → 叶子 glue（URI 等）→ Boolean/Number/Symbol/
  Date/Error → collections/iterator → String → Object/Array（opcode 纠缠
  最深）→ RegExp 最后（regexp_fastpath 纠缠）。**Promise/generator 核心
  机制留 exec**（QuickJS 把 promise 核心放引擎）。
- 快路径（regexp_fastpath、fast array/string）按 core class-id 键控留
  exec——它们直接操作 core 数据结构，不依赖内建实现代码。
- 安装：root facade（check_deps 已允许 import builtins）或 context-init
  回调编排。
- 提交模式（用户裁决）：全量迁移完成后**单 commit 可接受**；过程中按
  class 本地检查点（focused 单测 + test262 切片 + 微基准），收口跑全门禁。
- 本项为**纯组织收益**（无性能/语义红利），与历轮手术不同，预期基准持平。

### D2 QjsWorker 死簇删除（→ 迁移前，独立 commit）

**证据链（已核实）**：唯一创建入口 `createOsModuleNativeFunction`
（call_runtime.zig:4282，legacy `qjs:os` 残留命名）全树零调用方；
`qjsWorkerFunctionCall` 仅被 call_runtime 内部 3 个字符串分发点
（:525/:644/:1459）调用，传递性死亡；`current_qjs_worker` 恒 null；
test262 agent 是 CLI 层独立实现（run_test262.zig:2500 `Test262Agent` +
external host context），与 QjsWorker 无关。eecf6c8 删 `qjs:std/os` 时
漏删了本体。

**删除范围**：`QjsWorker`/`QjsWorkerCoordinator`/`WorkerMessage`/
`WorkerPostTarget`、postMessage/poll/sleep 实现、3 个字符串分发点、
object_ops.zig:3891-3901 worker parent 簇、4 层 `cleanupWorkersForRuntime`
转发链（call_runtime:4382→zjs_vm:1102→runtime/cleanup:26→runtime/public:9）、
root.zig:682 hasDecl 测试、公共符号快照再生
（`architecture-update-api-snapshot`）。fun 侧 VM.zig:81 的调用在 subtree
同步时删除（清理恒空列表，无行为变化）。

**将来真需要 Worker 的路径**（一段话进 architecture_review.md）：fun 侧经
`ExternalHostCall`/`zjs.host.*` 实现 Worker 本体（QuickJS 把 Worker 放
quickjs-libc 的同款分工）；zjs 侧届时补**值序列化原语**（对象图/循环引用/
typed array/SAB 共享/transfer，对齐 QuickJS `JS_WriteObject`/`JS_ReadObject`
——zjs 当前无等价物；死簇的 WorkerMessage 仅 7 种标量+SAB，无抢救价值）。

### D3 OOM 门禁五件套（基建→迁移前；执行档位=阶段收口或更晚）

**背景**：65e22be 退役旧 exhaustive OOM 测试（O(分配点×全套件) 成本结构，
重构期合理）；eecf6c8 随后完成高质量 OOM 硬化（6 个 flatten `@panic` 收敛
为 1 个 last-resort、~40 簇 fallible `ensureFlat`、OutOfMemory→InternalError、
预分配 OOM error 零分配投递），但验证是一次性手工冒烟；现状全树零注入测试，
预分配投递路径无单测。OOM 变 catchable 后，不变量从「干净地死」升级为
「捕获后引擎保持一致状态继续运行」。

**五件套（全部 Zig 原生工具，用户裁决）**：

1. **静态规则进 architecture-check**：src/ 禁止对 OutOfMemory 用
   `@panic`/`catch unreachable`，allowlist 仅挂唯一 last-resort（带
   exit_milestone 格式）。能静态禁止的不靠测试逼近。
2. **test-oom 重生**：精选微型脚本 corpus（parse、各 opcode 族 eval、一轮
   循环回收、rope concat+flatten、module link、promise job）×
   `std.testing.checkAllAllocationFailures`；成本由设计有界（分钟级），
   不随套件增长——旧 exhaustive 模式不回归。
3. **恢复金丝雀**内置同一 harness：每次注入失败被捕获后，同一 runtime
   重跑 canary 断言引擎仍工作，deinit 查泄漏——「捕获后一致」的唯一测法。
4. **`-Dzjs_oom_coverage`** 构建选项（同 `-Dzjs_enable_opcode_profile`
   模式）：allocator 包装按调用点记账，报告未被注入扫过的分配点，corpus
   完备性可测量、可收敛。
5. **8MB cap 行为 fixture**：repeat/数组增长 → JS catch InternalError →
   进程存活 → 继续 eval 成功；固化 eecf6c8 的手工冒烟。

**档位**：architecture-check（每次，毫秒）；常规 `zig build test` 仅含
预分配投递单测+最小注入用例（亚秒）；`test-oom` **阶段收口或更晚**（与
ReleaseSafe 同节奏，用户裁决）；engine_production_gate 含 cap fixture +
覆盖率报告。迭代循环零增量成本。

**时序**：基建在 P6 之前立起，P6 各 class 检查点与收口即用——600 函数
搬运期的 errdefer 丢失是注入层头号猎物。

### D4 调用形态手术（→ Phase 7，P6 之后）

**事实（已核实）**：`resolveInlineTarget`（inline_calls.zig:48-61）同时
把守内联调用与尾调用帧复用，`fb.is_arrow_function` 直接出局（:56，注释
理由「lexical this/new.target 装箱规则留一处」）——arrow 不只无 TCO，而是
**整体走 native 递归慢路径**，Phase 1 同循环内联对现代 JS 最常见形态不
生效。递归上限不对称：内联路径=逻辑深度（`stack_limit`），递归路径=
`max(16, stack_limit/16384)`（vm_call.zig:1475）——同一递归代码 function/
arrow 写法深度上限差数量级。微基准语料 call/closure 类全用 function 形态
（microbench_cases.js 仅 4 处 `=>`），悬崖在基线隐形。test262 对 method/
arrow 位置深尾递归覆盖为**空**（tco-member-args.js 名不符实，内容是普通
`f(n-1)`），PTC 特性声明（test262.conf:223）依据不足。失败形态安全
（vm_call.zig:79 双深度守卫→RangeError），非段错误。class-constructor
排除规范正确（无 new 调用即 TypeError）；L0 外壳/跨 realm 排除合理
（QuickJS 全递归且不声明 PTC）。

**裁决（用户确认）**：

- arrow 获得内联资格：arrow 无自有 this/new.target 绑定，装箱规则收进
  两路径共享的 frame setup 原语。收益三连：现代代码进快路径、arrow 尾
  调用经 `tailCallReuse` 自动获得 TCO、递归上限对称。
- `tail_call_method` 帧复用：receiver 进 `tailCallReuse` 帧重建（当前
  zjs_vm.zig:822 → `callValueOrBytecode` 递归）。
- LIMITATIONS.md 记录保留排除（L0 外壳、跨 realm、fusion 体）——移入
  迁移前小项，与手术解耦。
- 基准语料补 arrow case（arrow 调用循环 + arrow 尾递归）；method/arrow
  位置 1e5 深递归 runner fixtures（test262 不覆盖，自建）。
- 时序：P6 之后——两者都动 call_runtime.zig，串行避免双重手术冲突。

### D5 throw/stack 原语化（→ 迁移前）

**事实（已核实）**：结构已 QuickJS 同构——`createNamedError`
（vm_exception_ops.zig:13）唯一构造原语，`throw*Message`
（call_runtime.zig:8198+）为「构造→attachStackToErrorValue→throwValue→
Zig error」标准壳。但 5+ 模块绕壳直调原语且 **0 次 stack 附加**：
eval_entry(:46/:71)/module(:760)/module_graph(:211/:318/:332) 的
SyntaxError、promise_ops(:1327) 的 TypeError、disposable_ops(:267)——这些
错误无 `.stack`。QuickJS 在 `JS_ThrowError2` 单咽喉点内 `build_backtrace`，
所有错误有栈。test262 不测 `.stack`（非标准），门禁不可见；fun 这类
runtime 打印 `error.stack` 时暴露。

**修复**：stack 附加收进 `createNamedError` 内部（预分配 OOM 对象零分配
豁免）；`throw*Message` 家族从 call_runtime 迁回 vm_exception_ops 与原语
同居；删便利 re-export（promise_ops.zig:13-14、array_ops 顶部
`createNamedError*` 转发）。

## 2. 迁移前小项明细（pre-small-items）

- architecture_review.md：撤掉幽灵 `src/bytecode/ic.zig`「兼容导入路径」
  表述（实际是 bytecode/root.zig 的 re-export，该文件不存在）。
- LIMITATIONS.md：新增 PTC 条目（已实现形态、保留排除、深递归失败形态=
  提前 RangeError）。
- architecture_review.md：双值表示补一段平台理由（QuickJS `#ifdef` 双布局
  先例；16B 为参考表示与 NaN-boxing 不可用平台的后路）。

## 3. 阶段流程

```mermaid
flowchart LR
    PRE[迁移前清障<br/>worker删簇 / OOM基建<br/>throw原语化 / 豁免清零 / 小项] --> P6[Phase 6<br/>builtins 依赖翻转]
    P6 --> P7[Phase 7<br/>arrow内联 + tail_call_method]
    P7 --> P8[Phase 8 测量驱动<br/>GC header 2-bit / shape 去重]
```

## 4. 验证纪律

- 迭代期照旧：定向编译 + 焦点单测 + test262 切片（AGENTS.md）。
- 每个 pre 项独立验证独立落地；worker 删簇后跑 architecture-check（API
  快照再生）+ 全量套件一次。
- P6 按 class 本地检查点：该 class focused 单测 + test262 切片 + 微基准
  对照 `../quickjs/build/qjs`；收口：`zig build test`（Debug）+ ReleaseSafe
  一次 + test262-gate + test-altrepr + **test-oom** + architecture-check +
  微基准全套对照基线（预期持平——本项为纯组织收益）。
- P7 收口同上，另加新 arrow 基准 case 与深递归 fixtures。
- P8 每项先跑基准证明收益再实施（GC header 改造按 architecture_review.md
  要求专门会话 + 全门禁节奏）。
