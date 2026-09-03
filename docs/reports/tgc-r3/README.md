# TGC R3 根集诊断报告（S0 L4）

日期 2026-09-03 · driver 亲跑 · 分支 `gc/tgc-s0-20260903` · 二进制 `zig build zjs -Dzjs_gc_roots_diag=true`（ReleaseFast + 生产链入标量 ValueRootFrame + 保守根普查）

问题：**生产二进制里保守扫描到底救了谁？** 计划 `tracing-gc-completion-plan.md` §3 T-R 的 R3 步：在 R1（全精确、非移动）开工前拿到清单，把 F9 类洞（解释器未提交的操作数）逼出来。

## 1. 方法

- 探针：`computeFullReachable`（`ZJS_GC_VERIFY_MINOR=1` 每次 minor、`ZJS_GC_VERIFY_MAJOR_ALL=1` 每次 incremental finish）先跑精确根到不动点，再跑保守臂；保守臂回调进入时未标记、`shadeExact` 后已标记的 header = **直接保守根**（有一个原生 word 指着它）；此后 drain 新标记的 = **传递**（只因直接根而活）。
- 每个直接根记 (解释器当前函数名, header kind, class, word 来源桶, 指针形状, young, native)；来源 = 寄存器溢出镜像内的偏移（x0-x30 / q0-q31 两半）或原生栈相对 sp 的深度桶。
- 语料：Octane 2.0 14 个 fixed-work 脚本（`run_fixed_pmu.py` 同款拼装，doWarmup=false/doDeterministic=true）+ 六个 gate 负载（`/tmp/gcgap-fixed`，与 Stage 0 相同）。每负载 `--gc-stats` 全量输出在 `runs/<load>.stdout`，VERIFY 行在 `.stderr`。
- 规格偏离：spec §L4-1 要求探针对照臂改为「精确 only」；实际保留双臂（精确在前），因为归因只能在保守臂发生（精确 trace 到不动点后才能判定「只靠保守」）。「精确 only」的读数就是表里的 direct=0 期望值。

## 2. 结果

| load | exit | minors | majors | probes | direct | direct young | transitive | precise violations | conservative-only violations | wall s |
|---|---|---|---|---|---|---|---|---|---|---|
| gate-deltablue | 0 | 583 | 15 | 598 | 4446 | 765 | 573684 | 0 | 134 | 354.30 |
| gate-earley-boyer | 124 | - | - | - | - | - | - | 0 | 1005 | 3600.00 |
| gate-pdfjs | 0 | 155 | 6 | 161 | 814 | 179 | 8071 | 0 | 40 | 174.13 |
| gate-raytrace | 0 | 2620 | 4 | 2624 | 16725 | 3513 | 10804 | 0 | 3798 | 1123.22 |
| gate-regexp | 0 | 164 | 1 | 165 | 798 | 736 | 0 | 0 | 18 | 46.02 |
| gate-splay | 0 | 5 | 8 | 14 | 4 | 2 | 11 | 0 | 0 | 33.42 |
| octane-box2d | 0 | 193 | 9 | 202 | 1630 | 620 | 223706 | 0 | 65 | 291.53 |
| octane-code-load | 0 | 3 | 3 | 6 | 33 | 15 | 2557 | 0 | 0 | 6.49 |
| octane-crypto | 0 | 9 | 2 | 11 | 22 | 15 | 20 | 0 | 2 | 54.06 |
| octane-deltablue | 0 | 584 | 14 | 598 | 4545 | 833 | 624682 | 0 | 1755 | 575.80 |
| octane-earley-boyer-majoronly | 0 | 9094 | 163 | 163 | 599 | 241 | 11751 | 0 | 0 | 58.07 |
| octane-earley-boyer | 124 | - | - | - | - | - | - | 0 | 809 | 3600.00 |
| octane-gbemu | 0 | 3 | 7 | 8 | 102 | 12 | 298 | 0 | 12 | 13.06 |
| octane-mandreel | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 11.87 |
| octane-navier-stokes | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 5.60 |
| octane-pdfjs | 0 | 154 | 6 | 160 | 836 | 187 | 19507 | 0 | 44 | 177.29 |
| octane-raytrace | 0 | 2619 | 4 | 2623 | 16706 | 3424 | 10791 | 0 | 3726 | 1708.58 |
| octane-regexp | 0 | 164 | 1 | 165 | 875 | 765 | 0 | 0 | 20 | 45.94 |
| octane-richards | 0 | 12 | 2 | 14 | 41 | 30 | 372 | 0 | 4 | 41.85 |
| octane-splay | 0 | 5 | 8 | 14 | 3 | 1 | 0 | 0 | 0 | 32.64 |
| octane-typescript | 0 | 62 | 5 | 67 | 75 | 32 | 1039037 | 0 | 0 | - |

Totals: probes 7593, direct 48254 (young 11370), transitive 2525291, precise violations 0, conservative-only violations 11432

By source: registers 34844, stack<1K 724, stack<4K 10334, stack<16K 2225, stack<64K 127, stack>=64K 0
By pointer: exact 44102, prefix 308, interior 3844
By kind: object 20876, function_bytecode 8, var_ref 27085, shape 285
Registers: q3.hi 6760, q3.lo 6758, q2.lo 6757, q2.hi 6697, q5.hi 5683, q4.lo 1271, q4.hi 433, q5.lo 429, x10 50, x4 5, x25 1

Top 25 (function, kind, class, source, pointer, young, native, load):

| # | hits | function | kind | class | source | pointer | young | native | load |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 82 | `Type1Parser_extractFontProgram` | object | 13 | register | exact | 0 | 0 | octane-pdfjs |
| 2 | 77 | `Exec` | object | 19 | stack_lt_4k | exact | 1 | 0 | octane-regexp |
| 3 | 75 | `Type1Parser_extractFontProgram` | object | 13 | register | exact | 0 | 0 | gate-pdfjs |
| 4 | 73 | `Type1Parser_extractFontProgram` | object | 2 | register | exact | 0 | 0 | gate-pdfjs |
| 5 | 72 | `Exec` | object | 19 | stack_lt_4k | exact | 1 | 0 | gate-regexp |
| 6 | 66 | `Type1Parser_extractFontProgram` | object | 2 | register | exact | 0 | 0 | octane-pdfjs |
| 7 | 60 | `r` | object | 1 | register | exact | 0 | 0 | octane-box2d |
| 8 | 56 | `chainTest` | object | 1 | register | exact | 0 | 0 | octane-deltablue |
| 9 | 52 | `sc_list` | var_ref | 0 | register | exact | 1 | 0 | octane-earley-boyer-majoronly |
| 10 | 45 | `createTableEntry` | object | 13 | register | exact | 0 | 0 | octane-pdfjs |
| 11 | 43 | `createTableEntry` | object | 13 | register | exact | 0 | 0 | gate-pdfjs |
| 12 | 41 | `BinaryConstraint` | object | 1 | register | exact | 0 | 0 | octane-deltablue |
| 13 | 40 | `Variable` | object | 1 | register | exact | 0 | 0 | octane-deltablue |
| 14 | 40 | `createTableEntry` | object | 2 | register | exact | 0 | 0 | octane-pdfjs |
| 15 | 39 | `projectionTest` | object | 1 | register | exact | 0 | 0 | octane-deltablue |
| 16 | 38 | `Type1Font_flattenCharstring` | object | 2 | register | exact | 0 | 0 | gate-pdfjs |
| 17 | 38 | `Type1Parser_extractFontProgram` | object | 1 | register | exact | 0 | 0 | octane-pdfjs |
| 18 | 36 | `chainTest` | object | 2 | register | exact | 0 | 0 | gate-deltablue |
| 19 | 36 | `projectionTest` | object | 1 | register | exact | 0 | 0 | gate-deltablue |
| 20 | 32 | `OrderedCollection` | object | 1 | register | exact | 0 | 0 | gate-deltablue |
| 21 | 32 | `createTableEntry` | object | 2 | register | exact | 0 | 0 | gate-pdfjs |
| 22 | 30 | `Type1Font_flattenCharstring` | object | 13 | register | exact | 0 | 0 | gate-pdfjs |
| 23 | 30 | `arrayToString` | object | 13 | register | exact | 0 | 0 | gate-pdfjs |
| 24 | 28 | `Type1Font_flattenCharstring` | object | 2 | register | exact | 0 | 0 | octane-pdfjs |
| 25 | 28 | `Exec` | object | 2 | stack_lt_4k | interior | 1 | 0 | octane-regexp |


说明：
- `octane-earley-boyer` 在每-minor 探针下 3600 s 超时（9.4k 次 minor × 30 MB 堆的全量 trace）；`gate-earley-boyer` 同理。补跑 `octane-earley-boyer-majoronly`（只在 `ZJS_GC_VERIFY_MAJOR_ALL=1`，163 次 major 探针，58 s）已并入上表。
- `octane-typescript` exit 133 = 诊断构建的 `ValueRootFrame LIFO violation` panic（`[].sort()` 的 `SortEntryRootWindow` 空接收者 deactivate 一个从未 activate 的帧；生产 containers-only 策略把它遮住了）。同一缺陷让 diag 构建的 test262 也在 array sort 处 panic。已修（array_ops.zig），第三轮验证链复跑的 typescript 读数已并入上表（67 次探针、75 个直接根）。
- 函数名为空 = 匿名函数（atom 存在但名字空串）；`<no frame>` = 探针时没有 backtrace 帧（realm 初始化 / 原生边界）。

## 3. 发现

**F-R3-1 寄存器残留是最大来源，且几乎全是 F9。**（class 13 = bytecode function 对象、class 2 = Array、class 1 = 普通对象，即 pdfjs 解析器里被当作调用参数/返回值搬运的值。） 34,419 / 47,580 个直接保守根来自寄存器，集中在 q2.lo/hi、q3.lo/hi、q5.hi、q4.lo：正是 tailcall 解释器用 `loadValueAsIntPair/storeValueAsIntPair` 搬 16 字节 JSValue 的 NEON 对。这些值同时也在操作数栈上（它们刚从 `sp-1` 装出来），精确 trace 却没标到它们——因为 fast handler 只推进 `reg_sp` 不提交 `stack.len`（计划 F9）。young=0 占多数说明它们是老对象（对 minor 无害，对 major 的 remark 有害：一次 major 中被 conservative 救下的老对象都是「本该由操作数栈精确覆盖」的）。**最小改法：safepoint poll 前 `publish(sp)`，或把 `[stack.len, reg_sp)` 作 `ValueRootSlice.windowed` 根。** 这一项落地后预期寄存器桶 → 接近 0。

**F-R3-2 raytrace：13,029 个 VarRef 只靠寄存器保活。** raytrace 的匿名闭包（`fn=` 空）的 VarRef cell 在寄存器里、精确根没覆盖——当前帧的 `var_refs`（闭包环境）不在 `active_invocation_trace` 的精确根里，或者 closure 创建路径把新 cell 放在寄存器就分配了函数对象。**最小改法：frame 的 var_refs 切片作 `ValueRootSlice`（容器帧，生产已链入）；`createClosure` 期间用 windowed 根。**

**F-R3-3 原生栈 <4K 桶（10,117）= Zig 局部变量跨分配。** 代表：regexp `Exec` class 19（RegExp 对象）+ class 2（Array，结果数组）young=1、`stack_lt_4k` exact —— `regexpExec` 在构造结果数组时把 RegExp/数组指针留在局部变量里跨分配；raytrace `class 9`（mapped_arguments：`arguments` 对象创建路径把新对象留在局部变量里跨分配）1,520 次 young exact；deltablue class 2 数组 293/255。**最小改法：站点级 `rootValues`（诊断构建里标量帧已链入，生产需把这些站点改成容器窗口或等 R1 翻转 `value_root_link_containers_only`）。** 这些是 R1 的主体工作量，清单可从 `runs/*.stdout` 的 top-20 按函数名反查。

**F-R3-4 传递集巨大。** deltablue 一次探针平均 1,000+ 传递对象、box2d 1,100+：一个漏根钉住整张子图。这解释了为什么 v2 的 minor 在 splay 上「conservative-only young 仅 1/12」也不能推断保守扫描无关紧要——它救的是根，不是对象数。

**F-R3-5 精确根与屏障零违规。** 7,363 次探针（含 finish 处的 VERIFY-STICKY full scope）precise 违规 = 0：在诊断构建下多链入的标量 ValueRootFrame 没有暴露任何「精确根说活、实际被 condemned」的对象；L3/L2 修的 7 处漏屏障（见 s0-spec 执行记录）之后，remembered set 与精确根自洽。

**F-R3-6 interior 指针 3,797（8%）**，prefix 305：R1 若要去掉保守扫描，interior 命中对应的是 `*JSValue` 槽指针 / 数组元素裸指针类局部（F10 的 4 处 + 属性存储 Entry 指针），需要窗口根而不是标量根。

## 4. 对 R1 的量级判断

按来源桶归并后 R1 的工作分三层：
1. 解释器操作数提交（F9）：一处机制改动（safepoint poll 提交 sp / windowed 根），覆盖 72% 的直接根；
2. 帧 var_refs + closure 创建：一处根提供者改动，覆盖 raytrace 类负载的 VarRef 桶（28%）；
3. Zig 局部站点：<4K/<16K 桶共 12.3k 次命中，但按 (函数, class) 去重后只有 **约 130 个键**（`top N of M keys` 行），落到 Zig 站点估计 30-60 处，主要在 regexp exec、数组构造、deltablue/box2d 的属性写入路径。

这比计划里「≈740 个候选函数」的上界小一个数量级；R1 的 12-20 lane-week 上界应按此收窄，owner 二次裁决前建议先做 (1)(2) 两处机制改动再复跑本普查。

## 5. 复跑记录

- typescript：sort LIFO 修复后复跑正常结束（见 §2）。
- diag 构建 test262 script 全量（`ZJS_GC_VERIFY_MINOR=fatal`，每次 minor 一次全量精确+保守探针）：**0/49778**，即在 49,778 个测试 × 每次 minor 的探针里没有一次「精确根说活、minor 却 condemn」的违规；标量 ValueRootFrame 全链入后 LIFO 违规只剩 `[].sort()` 一处（已修）。
- 默认构建 test262 script：0/49778；`ZJS_GC_STRESS=1` 全量：从两处 SIGSEGV（FinalizationRegistry husk 二次 condemn、RegExp replace 匹配列表无根）修到 2 个非崩溃错误（`Iterator/zip*/basic-shortest.js` TypeError，GC 时机相关，记入 stress 基线待查）。

## 6. 产物

- `runs/<load>.stdout|stderr`：每负载原始输出（`--gc-stats` 全段 + VERIFY 行）。
- 汇总脚本：`tools/perf/r3_summarize.py`（从 runs/ 生成 §2 表）。
