# zjs ↔ qjs 实现差异现状全景与整改结果（2026-07-11，更新至 2026-07-12）

> 方法：分步骤对比 — ①重建双引擎并测量 20 个基准（insn+cycles）→ ②同源码双引擎字节码序列 dump 对比 → ③perf 热点归因 → ④九个子系统代码级审计 → ⑤正确性与性能前沿排序。
> 结论先行：本文最初记录的 C1–C4 正确性缺陷已经修复；二次审计又闭合了 conditional-only 回边中断、lexical lowering 死路径和 native builtin 栈帧。本轮进一步修复了模块 DFS/TLA 调度、动态导入 arrow 的 named-evaluation 状态泄漏、隐式 `arguments` 绑定优先级、generator return 穿越 finally 时的显式抛出传播，以及 `Promise.resolve` 身份命中的构造器验证顺序。原 13 条 known-errors 中已有 11 条转绿并移除，剩余 2 条在当前 QJS 参照上也失败，不构成已证实的 zjs → QJS 差异。§5.2 的 10 个性能候选均已执行“重建证据→实现、收窄或否决”：1–6、8、10 已按证据闭环；7 已完成 Math typed-cproto 首域、通用 op_call memo、Function record 化，让 `Array.prototype.push/pop` 进入 per-method full-context record、让 `Promise.resolve` 成为 Promise 域首个 per-method record，并让 String 大小写转换直达 qjs 式 per-method body、把 ASCII 输出直接写入最终 inline String；其他 builtin 域的 typed ABI 仍是架构迁移债；9 的 delete compact 原假设被基准否决，改为收益明确的 cached-string-atom 读路径。§1–§4 保留为**整改前历史快照**，当前结论以 §5 为准。
>
> **证据边界**：原始 20 项 best-of-5 仍只有聚合结果，不能回推方差或严谨 IPC。本轮把字符串、属性、peephole、调用、函数生命周期、Array.push/Array.pop 与 Promise.resolve 的 25 个固定脚本补入 `tests/perf/qjs-align/`，但尚未重建原历史 20 项全集和所有 perf.data；新旧数字必须分开解释。

## 0. 初始审计环境与方法

- zjs：初始审计时 commit `1a1343e`（当时的 HEAD/main），Zig `0.16.0`，`zig build zjs`（CLI target 固定 ReleaseFast）当场重建；当时实测二进制 SHA-256 `249c9f4e5b3bdee0a717f91aaab70302fd7541cd40ae4331043ba3e5b468572c`。该身份只对应 §1–§4 的历史快照，不代表整改后工作树。
- qjs 参照：工作树 commit `04be246`，`/home/aneryu/quickjs/qjs` 报告 QuickJS version 2026-06-04；实测二进制 SHA-256 `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`。后续复测必须同时核对 commit 与二进制 hash，不能只依赖版本字符串。
- 机器：Cortex-X925（20 核），测量 `taskset -c 19`，PMU 事件 `armv8_pmuv3_1/instructions/,cycles/`，best-of-5 取 min。
- 基准：历史标准 L0–L5 分层集 + P_tdz/P_ifobj 探针 + 当时新增的 objlit_var/objlit_let churn 对照对（脚本均为包函数形态，防顶层变量污染）。原始 20 项脚本仍未从 job 临时目录恢复；本轮另补的 11 个固定脚本不能反向补足历史样本，因此表中旧数据只能用于提出假设，不能用于验收改动。
- 字节码：zjs 用 `ZJS_DISASM=1` 环境变量 dump；qjs 用隔离副本树开 `DUMP_BYTECODE=1` 重编（参照树未动）。

## 1. 整改前基准测量快照（zjs/qjs 比率，越小越好）

| 基准 | 形态 | insn 比 | cyc 比 | 层级判定 |
|---|---|---|---|---|
| L0_emptyloop | 空 for-let 循环 | **0.93** | 0.99 | ✅ 反超 |
| L1a_accum | s=s+1 | **1.00** | 1.02 | ✅ 平 |
| L1b_localarith | s=(s+a+b)\|0 | **0.96** | 1.01 | ✅ 平/反超 |
| P_ifobj | if(常驻对象) 真值分支 | **0.95** | 1.02 | ✅ 反超 |
| P_tdz | 循环体 let v=1（TDZ 对） | 1.12 | 1.16 | 🟢 近平（T3 成果保持） |
| L5b_charcode | s.charCodeAt(i%11) | 1.06 | 1.19 | 🟢 insn 近平，cyc 有残余 |
| L2a_propread | s+=o.a（4 属性常驻对象） | 1.13 | 1.12 | 🟢 小 gap |
| L2b_arrayread | s+=t[0] | 1.02 | 1.07 | ✅ 平 |
| L5a_strconcat | "a"+"b"+i 新鲜短串/iter | 1.30 | 1.46 | 🟡 |
| floatsum | s+=1.5（浮点累加） | 1.32 | 1.41 | 🟡 |
| objprop | o.a=s; s=o.a+o.b 写读混合 | 1.36 | 1.26 | 🟡 |
| template | s=\`x${i}y\` | 1.37 | 1.41 | 🟡 |
| L4a_emptyobj | let o={}; if(o)（TDZ+alloc） | 1.42 | 1.32 | 🟡（与 memory T3 后口径一致） |
| **L3b_funcall** | s=f(s) 紧调用 | **1.67** | **1.69** | 🔴 调用前沿 |
| **L4c_array3** | let a=[1,2,3]/iter | **1.69** | **1.54** | 🔴 数组字面量 |
| **L3a_fib** | fib(34) 递归 | **1.79** | **1.92** | 🔴 调用前沿 |
| strconcat（累积） | s+='ab' ×1e6 | 1.79 | **3.13** | 🔴 cyc 异常（见 §3.4） |
| **objlit_let** | 循环体 let o={v:i}（churn） | **1.99** | **1.83** | 🔴 对象字面量前沿 |
| **L4b_objalloc** | let o={a,b,c}/iter | **2.04** | **1.95** | 🔴 对象字面量前沿 |
| **objlit_var** | var o={v:i}（无 churn！） | **2.48** | **2.40** | 🔴 **最大 gap** |

本轮快照的关键观察：
1. **这组脚本中的分派/算术/TDZ/真值负载已接近 qjs**（L0/L1/P 系 0.93–1.12x）——从 dispatch 逐层对齐的历史工作（tail-call threaded、T1/T3 fast handler、dup+drop 删除、opBinary float leg 等）在本轮测量中保持住了；在基准脚本和原始样本补齐前，不外推为全域结论。
2. **对象字面量分配是最大前沿**（1.99–2.48x），且 **objlit_var（shape 不 churn 的形态）比 objlit_let（每迭代 churn）差距更大**——大头不只在 churn，还有独立的槽访问税叠加（§3.1）。qjs 侧 var 形态比 let 形态便宜 12%（churn 省掉），zjs 侧反而贵 10%（var-init 的 make_loc_ref 把 cell 装进槽、击穿裸 loc fast handler，毒化税 > churn 节省）。
3. **调用机制 1.67–1.92x** 仍是第二前沿（历史从 4.15x 收到此处后驻留）。
4. 每迭代绝对指令数（1e7 iter）：L4b zjs 4739 vs qjs 2320；objlit_var zjs 2728 vs qjs 1100；objlit_let zjs 2485 vs qjs 1251；L4a zjs 1324 vs qjs 933。

## 2. 整改前字节码发码层：稳态循环体基本收敛，但 lowering 仍在因果链

**证据支持的窄结论：下表留存的 6 个热构造，其稳态循环体 op 序列两侧逐条一致或 zjs 更短。它不等于发码层已退出性能因果链：D-BC1 当时仍增加每次 lexical init 的检查，D-BC2 更会在函数级把局部槽 ref 化，直接造成初始快照的最大 gap。**

> 整改后：D-BC2 的安全 local-ref tail 已降成 loc 写；D-BC4 所列五族 resolve-label peephole 已实现。二次审计删除了永远受 `use_short_opcodes=false` 阻断的 `useUncheckedLexicalLocals` 数据流，并按 QuickJS `resolve_scope_var` 规则保留 lexical 读写检查、把普通声明初始化降成裸 `put_loc`、仅为派生构造器 `this` 保留 `put_loc_check_init`。当前 `function f(){let x=1;return x}` 的两侧最终序列均为 `set_loc_uninitialized; push_1; put_loc0; get_loc_check; return`，因此 D-BC1/D-BC3 不再是当前差异。

已留存的逐构造摘要（zjs `ZJS_DISASM=1` vs qjs `DUMP_BYTECODE=1` 最终 pass）：

| 构造 | qjs ops/iter | zjs ops/iter | 差异 |
|---|---|---|---|
| for-let 累加循环体 | 13 | **12** | zjs `inc`（1 op）vs qjs `post_inc`+`drop`（语句语境 zjs 反而省 1 op） |
| objlit3 `{a:1,b:2,c:3}` 体 | 25 | **24** | 序列逐条同构：`object`+3×(`push_N`+`define_field`)+`put_loc*` |
| fib 函数体 | 18 | 18 | **逐条完全一致**（get_arg0/push/lt/if_false8/get_var/sub/call1/add/return） |
| funcall 循环体 | 13 | 12 | 一致（get_var/get_loc_check/call1/put_loc_check） |
| varloop `{v:i}` 体 | 15 | 15 | **逐条完全一致**，zjs 也用裸短变体 `get_loc0-2`/`put_loc0-1`/`inc_loc` |
| arr3 `[1,2,3]` 体 | 18 | 17 | 一致（push×3+`array_from 3`+`get_array_el`） |

初始审计记录的发码差异及当前处置：
- **D-BC1（已对齐）** 初始 zjs 的 let 声明初始化使用 `put_loc_check_init`；当前普通 lexical 初始化与 qjs 一样使用裸 `put_loc0/1/2`，后续读取仍保持 `get_loc_check`。
- **D-BC2（已对齐窄路径）** 初始 var 声明初始化序言会发 `make_loc_ref "name"`+`push_0`+`put_ref_value` 并毒化整个函数的裸 loc 快路；当前仅在可证明无 eval/with/closure/destructuring/const/function-name 风险的 ref-tail 上降成 loc get/put。
- **D-BC3（旧判断被双侧 dump 否决）** QuickJS `resolve_variables` 在进入 lexical scope 时同样发 `set_loc_uninitialized`；简单函数的两侧最终序列逐条一致，不存在“zjs 独有函数序言武装”。
- **D-BC4（已对齐）** dup+put→set、同向逻辑链、null/undefined/typeof 比较、undefined+return 和终止后死代码删除均已实现，并覆盖 atom ownership 与隐式控制流边界。
- zjs 有与 qjs 对应的短 op 变体（get_loc0-3 raw c3-c6、put_loc0 c7、inc_loc 91、if_false8/goto8、push_0-N、call1 ed），opcode 表与 quickjs-opcode.h 逐项同构；发射层差异见 §4.9。

审计当时声称另有 5 个构造完成 dump 对比，但其脚本与 dump 未留存。本文件不再把它们计入可核查证据；补齐材料后才能恢复“11 个构造逐条验证”的表述。

## 3. 整改前 per-op 执行成本层：perf 热点归因历史快照（cycles，taskset -c 19）

本节百分比来自另行采集的 perf profile，不是附录 B 的 best-of-5 最小值运行；因此总 cycles 可与附录略有不同。原 perf.data 未留存，百分比仅用于定位代码审计方向，不能作为实施后的验收基线。

### 3.1 第一前沿：局部槽访问机制（objlit_var 2.40x cyc 的解剖）

> 整改后：`localRefPutTailPlan` 只在 reference 不逃逸、无 eval/with 探针、非 const/function-name 的 local 形态改写 `make_loc_ref … put_ref_value`；closure/eval/destructuring/with 语义回归保留原引用路径。

zjs 热点（objlit_var，总 4.33e9 cyc）vs qjs（1.74e9 cyc）：

| zjs 符号 | % | 对应 qjs 机制 |
|---|---|---|
| exec.vm_property_locals.loc | 12.24 | var_buf[idx] 裸数组索引（内联 2-3 insn） |
| exec.tailcall_dispatch.coldStd（槽 op cold 包装） | 8.01 | 无对应（qjs 无 cold/fast 分层） |
| exec.slot_ops.setSlotValueRefCounted | 5.89 | `set_value(ctx, &var_buf[idx], sp[-1])` |
| exec.value_ops.unary + toNumberValue | 7.14 | OP_inc_loc 的 int 内联快路径（≈4 insn） |
| exec.slot_ops.execPutLoc | 2.50 | 同上 var_buf 写 |
| exec.tailcall_dispatch.op_update_loc_cold | 2.13 | —（inc_loc 落 cold） |
| core.var_ref.VarRef.setVarRefValue | 1.94 | —（qjs 未捕获 var 不走 var_ref） |
| **小计：槽访问语义** | **~40%** | qjs 全部内联在 JS_CallInternal 27% 内 |

根因链条（已逐环代码验证，双侧 file:line）：

1. **整改前 zjs 缺 qjs 的 `optimize_scope_make_ref`**：qjs resolve_variables 对 `var x = init` 模式（quickjs.c:33007 `can_opt_put_ref_value` + quickjs.c:32791 `optimize_scope_make_ref`）把 `scope_make_ref+…+put_ref_value` 改写成**裸 `put_loc`，且不 capture_var**；只有改写不了的（with/复杂目标）才发真 OP_make_loc_ref。zjs 的 lowering（bytecode.zig:4343 `writeLoweredScopeMakeRef`）当时**无条件**发 `make_loc_ref`（仅有 global ref 的尾部优化 `decodeGlobalRefPutTail`，local/arg 版缺失）。
2. **make_loc_ref 把 cell 物理装进槽**：zjs `makeSlotRef`（vm_property_ref.zig:157-161）→ `ensureLocalVarRefCell`——`frame.locals[idx]` 本身被替换为 var-ref cell 值。qjs OP_make_loc_ref（quickjs.c:18777）建的 var_ref 是 `pvalue = &var_buf[idx]` **指向**槽，`var_buf[idx]` 永远是裸值。
3. **裸 loc fast handler 被 cell 击穿**：zjs 裸短 op 其实有 frameless fast handler（`opLoc`，tailcall_dispatch.zig:890，get_loc0→opLoc(.get,.c0) 等），但入口守卫 `varRefCellFromValue(old_v) != null` 对 cell 槽必然成立 → 每次执行 tail-call 进 cold 表：coldStd 包装（208B C 栈帧物化 + frame.pc/stack.values 写回，tailcall_dispatch_colds.zig:47-55）→ `vm_property_locals.loc` 通用槽路径 → put 走 `setSlotValueRefCounted`/`VarRef.setVarRefValue` 写穿 cell。`inc_loc` 同理：fast `op_update_loc` 的 cell 守卫失败 → `op_update_loc_cold` → `value_ops.unary` → `toNumberValue` 通用数值路径。
4. 附带的函数级降级：函数体含 make_loc_ref ⇒ `locals_never_boxed=false`（bytecode.zig:8338-8350），check 变体 op 的 cell 守卫也不能豁免。

qjs 同负载零税：var-init 优化成 `put_loc0`（varloop 的 qjs dump 实证），槽是裸值，get/put_loc CASE 体 2-4 条指令。
另一个独立观察：fib（无 var、无 cell）的 `op_get_arg_short` 仍占 16%——arg 槽 fast handler 本身与 qjs「CASE 内 2-3 insn + 寄存器驻留」相比仍有每-op 进出成本（见 §3.3 调用机制）。

### 3.2 第二前沿：shape 周期 churn（objlit_let 的解剖）

> 整改后：`transitionProperty(**Shape, …)` 已按 cache hit / shared clone / rc==1 in-place 三臂实现，并覆盖 FAM relocation、hash 重挂、缓存共享和 OOM 门禁。

objlit_let（每迭代 kill-before-create）zjs 热点：`cloneShape` 7.76% + `destroyShape` 7.14% + `Registry.link` 3.50% ≈ **18.4% 周期在 shape 建毁**；另 `adoptShapeForNewProperty` 9.74% + `addPropertyTrusted` 3.23% 在属性追加。qjs 同形态也 churn（js_new_shape2 3.04% + js_free_shape 2.91% + add_property 13.78%），但绝对量小得多。alloc/free 本体（createInternal/createWithFam/MemoryAccount.free/destroyFromHeader/gc.addWithSize 合计）与 qjs（__js_malloc/__js_free/free_gc_object 相应段）绝对 cyc 已基本打平——与 memory「{} alloc+free 本体打平」结论一致。

**当时记录的 churn 隔离结果**（pin 对照：循环外 `const pin={v:0}` 钉住同形 shape 使其不死；脚本与逐次样本待重建）：
- zjs：objlit_let 2485 → pin 1882 insn/iter，**churn 净成本 ≈603 insn/iter**
- qjs：objlit_let 1251 → pin 1199 insn/iter，**churn 净成本 ≈52 insn/iter**（11.6x 差）
整改前代码机制差异见 §4.4：qjs 在转移缓存 MISS 且 shape rc==1 时走 `add_shape_property` **原地改写**（root shape 同块内存演化为终态）；zjs 当时在 MISS 后无条件 `cloneShape` + `release` 父。`{v:i}` / `{a,b,c}` 的具体每迭代建毁次数来自当时的 profile/分配轨迹摘要，需在脚本补齐后重测确认。

### 3.3 调用机制（fib 1.92x cyc 的分布）

qjs：**99.43% 单符号 JS_CallInternal**（帧建立/所有 op/返回全内联，寄存器驻留 sp/pc）。
zjs：op_return 17.92% + op_get_arg_short 16.03% + op_call 13.04% + setupSimpleInlineEntry 10.30% + op_get_var 8.35% + next 8.20% + pushFrame 7.83%。
残余形态 = 调用路径仍分散在 ~7 个符号（跨函数边界的寄存器保存/恢复 + 每段重建状态），且 get_arg 槽访问中 T-A 税。

### 3.4 字符串累积追加异常（strconcat cyc 3.13x）——历史归因快照，待重建

> 整改后证据：固定 2M `var` 累积脚本定位到 cell-backed local 人为禁用 rope tail，而不是 GC pacing。解除该无效门后，代表运行由约 3.009B instructions / 995M cycles / 59,671 minor faults 降到 1.138B / 216.5M / 2,259；同脚本 qjs 约 1.847B / 324M / 1,356。fresh-string 加法仍接近（zjs/qjs 约 2.382B/2.278B instructions），因此未继续改 allocator/GC 触发策略。

当时的规模扫描（2.5e5→2e6 次追加）记录为**双侧近似线性**，并报告每追加 zjs 1616 insn/525 cyc、qjs ~900 insn/160 cyc。扫描逐点数据与 perf.data 未留存，因此不能独立确认复杂度，也不再把由聚合最小值推得的 IPC 当作严谨证据。历史 perf 笔记如下：
- zjs：**35%+ 周期在内核态**（页错误/mmap 族地址）——rope tail 摊还倍增的大块 realloc 走 `init.gpa` backing 直通 mmap/munmap，每次倍增触发新映射+逐页页错误；用户态 createRope 2.9%+allocAligned 2.6% 并不高。
- qjs：全用户态（JS_CallInternal 27% + __js_malloc 24.7% + __js_free 12.7%）。qjs 超 8192B 后**同样每追加建 rope 节点**（js_new_string_rope 2.5% + rebalance 3.6%），但 24B 节点走 arena 小池、大块走 glibc malloc（brk 复用不还内核）。
- 当时的归因假设：insn 1.79x 来自 §4.6 的 OP_add 字符串腿冷链分派税 + rope 逻辑差，cyc 进一步恶化主要来自 backing 分配器行为。该判断需用留存的规模脚本、major/minor faults、mmap/munmap 计数和 allocator 对照实验重建后，才能据此选择“缓存 allocator”或 tail 预留策略。

## 4. 整改前九子系统代码级差异清单

（代码级审计后经主线交叉验证；关键结论尽量标注双侧 file:line，但部分 perf 归因仅保留了聚合百分比，不能视为完整可复核证据。分类：[对齐]=机制同构 / [多做工]=zjs 热路径独有开销 / [结构]=数据结构算法不同 / [反超]=zjs 更优勿动）

### 4.1 值表示与 dup/free（横切所有基准的乘数税）

> 整改后：默认 16B 表示的 `requiresRefCount` 已改为与 qjs 同构的无符号范围比较；opcode profile 空测由 comptime 门裁掉。rc 物理偏移统一未捆绑实施，alternate representation 仍作为强制门禁。

**最重要横切项——dup/free 判别与 rc 布局**（A2-D1/A1-D6；反汇编量化摘要已记录，但原始反汇编未留存）：
- [多做工+结构] zjs `requiresRefCount`（value.zig:358-370）默认 repr 是 7-tag 精确 switch（编译成 ~8 条 ALU），且 String 头 rc 在 payload+0、GC 头 rc 在 payload−4，命中后还要掩码分双腿（value.zig:576-625）。qjs `JS_VALUE_HAS_REF_COUNT` = `(unsigned)tag >= JS_TAG_FIRST` **1 条比较**（quickjs.h:287），全部 refcounted 类型统一 `JSRefCountHeader` 前缀 rc 偏移。每 dup zjs ≈3-11 insn vs qjs 2-5；每 free ≈8 vs 2。两侧 tag 数值集完全相同——qjs 故意把空洞 -5/-4 纳入宽松范围测试，zjs 花指令精确排除。**修法：默认 repr 退化为单比较 + 评估统一 rc 偏移**（nanbox altrepr 已是范围测试）。
- [多做工] 每次 free 内联 `rt.gc.phase==.deinit` + `rt.opcode_profile` 空测探针（value.zig:606-612），≈+6 insn/3 载入 per free（A2-D8）。qjs JS_FreeValue 无探针。profile 空测可 comptime 门掉。
- [对齐] JSValue 16B repr 逐字段对齐（payload 前 tag 后、tag i64、int/bool 低 32 位零扩展、float64 整存取不规范化 NaN）；`asInt32Pair` 融合 OR 测 ≙ `JS_VALUE_IS_BOTH_INT`。

**数值算术**（A1）：
- [对齐] opBinary 11 op 的 int 腿逐条同构（add/sub int64 加宽、mul -0 门、shr JS_NewUint32 语义）；add/sub/mul float 腿内联 ≙ qjs OP_add CASE float 腿；add_loc 三路（int 溢出内联装箱/float 裸装箱/字符串原地追加）≙ OP_add_loc；inc/dec 溢出门同构。
- [多做工] **eq/strict_eq 族只有 int-int 快臂**（tailcall_dispatch.zig:1357-1373）：float×int/float×float/对象恒等/null-undef/string 相等全落冷（且冷链 valuesEqual 前置 isBigInt×2+双 isNan 冗余）。qjs OP_CMP_EQ/STRICT_EQ CASE 内全内联（quickjs.c:20273-20398）。
- [多做工] **一元族无快 handler**：neg/plus/not(~)/lnot(!)/post_inc/post_dec 全走 coldStd 壳（colds:267-296），`!flag` 布尔操作数也付全额冷壳；qjs 各有 CASE 内联腿（19940-20111）。冷体还用浮点算 int（`@floatFromInt` 往返，vm_arith.zig:297-302）。
- [多做工] div/mod/位运算冷梯子深（发布壳+两层调用+全套重分类），qjs js_binary_arith_slow 入口即 both-float64 快腿（14906-14922）。
- [结构] ToInt32 float→int 用 `@floor+@abs+@mod(2^32)` 浮点算法（value_ops.zig:891-897 等 4 处副本），qjs 用 IEEE 指数位技巧、|x|<2^31 单条转换（13319-13369）。
- [反超·勿动] fastStringToInt32 免拷贝解析；fastInt32Mod 免 fmod libcall；TDZ resolve 降级见 §4.2。

### 4.2 分派与热 op handler（A2，带反汇编）

> 整改后：const local 写在 resolve_variables 期直接发带变量名的 `throw_error`，快 handler 不再查询 `vardefs.is_const`。其他 checked-loc、条件分支和宽跳转残余没有借本轮顺手扩大。

- [对齐] tail-call threaded ≙ computed goto；短变体全集齐平；push 系/drop/dup/goto8/if8 布尔+对象腿/get_var_ref0-3/add_loc/inc_loc 快 handler 均与 qjs CASE 同构（T1/T3 成果）。
- [结构] 分派本体每 op +1 次 `vm.tbl` 载入（表基驻 Vm 是对 adrp 重算的已证修复）；跳转类再 +code_end 检查。qjs 表基寄存器驻留、无越界检查。≈+1-2 insn/op 结构地板。
- [多做工] **快 handler 残余税**（反汇编）：get_loc_check 19 insn/8 载入 vs qjs 12；put_loc_check 36 vs 13。构成：`local_fast_blocked` 门(3) + `locals_never_boxed` 门(3) + cell guard（D2 模型税）+ **运行时 is_const 测试(5 insn/3 载入——qjs 在 resolve 期对 const 写直接发 OP_throw_error**，quickjs.c:32945，zjs bytecode.zig:4980-4988 留给运行时) + dup/free 判别（§4.1）+ put 类帧 prologue(6，因内联 free 的 bl)。
- [多做工] **if_false8/if_true8 的 int/null/undefined 真值腿缺失**：快腿只认 bool+对象，int 条件（`if (n%2)`）每迭代付全额冷壳；qjs `(uint32_t)tag <= JS_TAG_UNDEFINED` 单比较内联四类（18881-18919）。**放宽快腿测试即可，改动极小**。
- [多做工] goto16/goto32、if_false/if_true 16/32 位无快 handler——体 >127B 的循环每回边付 ~900B 冷壳；put_arg*/get_arg(u16) 全冷（get_arg0-3 有快）。
- [结构] push_const/push_atom_value/fclosure8 等 refcounted 常量推送全冷——GC 根窗口契约（快 handler 不 publish stack.values.len，新 refcounted 值会落在追踪窗口外）。修法需"先 publish 再推"半快形态。**实测印证：floatsum（`s+=1.5`）热点 pushConst8 占 15.3% cyc——float64 常量非 refcounted，此腿可无条件 fast，floatsum 1.32x 的主要成分之一**（其余=opLocCheck 残余 39%+opBinary/分派）。
- ~~[反超] zjs resolve 期 TDZ 降级~~ **整改前勘误，现已删除死路**：旧 `useUncheckedLexicalLocals` 在 resolve_variables 阶段永远因 `use_short_opcodes=false` 失活；当前不再保留这套伪数据流，lowering 直接表达 qjs 的 checked-read/checked-write/bare-init 规则。
- [已修复行为缺口] `if_true/if_false/if_true8/if_false8` 四种路径在 installed-handler 下均于消费条件、更新 PC 后 poll；`do {} while (true)` 这类没有 goto 的 conditional-only 回边现在可被中断。
- **checkedLocVm 现状**：快 handler 已覆盖 6 op 中 5 个，checkedLocVm 退为 cell/const/TDZ-throw/checkthis 冷路径；历史 14.86-27.61% 自时间已迁移为快 handler 残余税（上条）。get_loc_checkthis 恒冷（派生 ctor this 读，非循环热点）。

### 4.3 调用机制（A3）

> 整改后：write-only `Machine.switched` 已删除；`op_return` 已把结果移出 operand region 后再 teardown，与 qjs `ret_val = *--sp` 的 ownership 时序一致。simple-frame 资格和其他调用架构候选仍分开处置。

调用链逐跳对照结论：qjs 单函数 JS_CallInternal 一条 C call 进入新寄存器组；zjs 7 跳（next→op_call→resolveInlineTarget→pushAndEnter/pushCall/pushFrame→setupSimpleInlineEntry→链接+9 个 vm.\* 重载→next）。
- [结构·主体] 帧建立 ~30-40 存（Entry 9 字段+Frame 15 字段+Stack 5 字段）vs qjs 9 字段 sf 共 8 存 + alloca；返回路径 reloadTop ~10 存 + Machine 解链 vs qjs C return + 1 存。**loop-in-place 换 no-C-stack-growth 的架构成本主体，历史已论证否决瘦身**（cold 字段跨 generator suspend 承重）。
- [多做工·可删] `Machine.switched` 每 push/pop 各 1 存——**write-only 死簿记**（inline_calls.zig:238 声明+3 写 0 读，grep 实证）。纯删除即赢。
- [多做工] `frame.pc += 2` 对刚 publish 的内存 RMW（qjs pc 寄存器 +2 后单存 sf->cur_pc）仍在；旧 op_return 的 `stack.peek()` dup+teardown-free 已改成 move，不再列为开放项。
- [多做工] resolveInlineTarget 7 道资格闸门含 realm **比较**（qjs 是 realm **采纳** `ctx=b->realm`，跨 realm 不慢）；`acquireSlot` 每 call `depth/16` 除法；call_depth 双计数器 vs qjs 单条栈指针比较。
- [结构] **method 调用/strict/argc==0/缺参永走重路径 setupInlineEntry**（isSimpleInlineFrame 要求 sloppy+无 receiver+argc>=arg_count，inline_calls.zig:364-385）——OOP 递归负载每 call 付全套（qjs 唯一慢支路是 arity-pad 循环）。
- [结构] **捕获局部模型**（"var make_loc_ref" open 项实体，§3.1 根因链的模型层）：zjs cell-in-slot（`ensureLocalVarRefCell` 替换 `frame.locals[idx]` 本身）vs qjs open-ref `pvalue` 指向槽、var_buf 永远裸值（quickjs.c:16997-17055）；open-ref 定位线性扫描 vs qjs parse 期 `var_ref_idx` O(1)；open 槽按 var_count+argc 粗留 vs qjs 精确 var_ref_count。下游税=每条 loc op 的 cell guard。
- [多做工] put_var_ref 家族无快 handler（写侧全冷 4 类检查合一）；get_var_ref0 多 bounds+isUninitialized 2 检查（qjs 零检查，check 变体分开）。
- [反超·勿动] 真 PTC 尾调用（qjs 非消除式）；中断 poll 的 active 门；分派机制本身（ledger dispatch −44 zjs 领先）。
- deferred 项核实：K1（open-ref 存储量每 FB 预计算）未做；K2 已由 `JSContext.native_call_depth`、`enterCallDepth` 硬上限和接近上限时的 heap-frame fallback 落地；B5 裸 sp=已判 mirage 勿重启；**Step4 direct-eval 已落地**（80da8e4，op_get_var 只剩 3 守卫 ≙ qjs 同构+2）。

### 4.4 属性与 shape（A4——T4 前沿的解剖）

> 整改后：rc==1 named-shape 原地追加已实现。属性读专项显示 64 个 delete 墓碑对静态/计算读 instructions 几乎无可测惩罚，因此没有冒险做物理 compact；实际热点是计算键反复 `internAtom/free`。`String.internAtom` 先查 back-pointer，`get_array_el` 可借用 live cached atom 后，5M computed-read 约 4.311B→3.150B instructions、756M→578M cycles；静态读约 1.525B instructions，未见回退。

- [整改前结构·**T4 头号刀**] **命名属性添加缺 qjs「rc==1 原地改写」路径**：qjs `add_property`（quickjs.c:9206-9236）三臂——转移缓存 HIT 共享 / MISS 且 rc!=1 才克隆 / **MISS 且 rc==1 → `add_shape_property`（5469）原地追加**。zjs `adoptShapeForNewProperty`（object.zig:9777-9799）当时无条件走转移缓存，MISS 即 `transitionProperty` 克隆 child，随后替换 `self.shape_ref` 并 release parent（shape.zig:281-295）。pin 快照显示 churn 差异很大，但原始脚本尚未留存，数值需复测。

整改前已有 `appendProperty`/`rehashShape`/`relocateShape` 机件，**但不能只在旧 `transitionProperty` 中加一个“返回 parent”的分支**：调用者无条件 release old shape；不扩容时会把仍在使用的 parent 降到 rc=0，扩容时 `relocateShape` 已释放旧块，调用者再 release 会触发悬空访问。本轮最终选择了 `**Shape`/显式 ownership 方案，并覆盖缓存 HIT/MISS、同指针、FAM relocation、OOM rollback、hash 摘链重挂与重复对象 shape 收敛测试。
- [多做工] cloneShape 合并了扩容语义→永远逐 prop 重建（@memset 桶+props、逐 prop 写+atoms.dup+linkPropertyHash 重建链，shape.zig:589-642）；qjs js_clone_shape（5268-5297）尺寸恒等**单次 memcpy 整个尾部**+仅逐 prop DupAtom；resize_properties 搬移时 atom 所有权转移不重 dup。
- [结构] 转移缓存键含 prop_size（shape.zig:307，容量不等不共享）+ 预容量 root shape 进 intern 表不查重（每个 c_function/JSON.parse 对象建一次性 shape）；qjs hashed shape 容量统一故键中无容量、预容量 shape 走 nohash 不入表（5766）。**实测佐证：L4c_array3（1.69x）热点含 destroyShape 4.4%+Registry.link 3.6%——`[1,2,3]` 无命名属性也每迭代 shape 建毁**（另 createInternal 14.3%+ensureArrayBufferCapacity 10.6%+constructLiteralWithPrototype 8.6% 为数组本体）。
- [多做工] **delete 不摘哈希链**：deleted 条目留在链中，**每次属性探测每步付 `!flags.deleted` 测试（从未 delete 的对象也付）**（object.zig:9981/10007）；qjs delete_property 物理摘链+阈值 compact_properties（9311-9369），探测循环零 deleted 测试。
- [多做工] atoms.dup/free 单价 ~10-14 insn vs qjs 4-6（isConst+taggedInt 双测+域检查+越界检查+symbol 分支 vs qjs 单比较+atom_array 直索引）；被 shape 建毁 2x 流量放大。
- [多做工] shape 注册表负载因子 1.0 vs qjs 0.5（桶链 ~2x 长）；removeShapeHash 有防御性全表扫 fallback。
- [结构] get 链尾不合成 undefined（部分内建对象 prototype 物理链为 null 靠按名回退）——miss 型读恒走冷壳；qjs GET_FIELD_INLINE 链尾内联 `val=JS_UNDEFINED`（19107-19160）。即 DEEP backlog「builtin-proto 物理链」确认仍在。
- [多做工] define_field 值 refcounted 时跳过快臂（vm_literal.zig:51，rooting 纪律所致）——`{a:{},b:"s"}` 嵌套字面量走冷 defineField；int 值不受影响。
- [对齐] shape 56B 真 FAM/8B packed prop/哈希函数 0x9e370001 全套/转移 hash/注册表结构/prepareUpdate rc 判/own lookup 桶链 trusted 探针/proto walk/覆写快路径/relocate 不 realloc/释放步骤序。**双侧均无活体 IC**（zjs property_ic.zig 是恒 null 桩+两段过时注释）。
- [反超·勿动] define_field 快臂外壳比 qjs 通用链瘦（三刀成果）；`{}` 不分配属性数组。

### 4.5 分配与 GC（A5）

> 整改后：slab-backed GC 对象已把 `Metadata` 折进既有 8B allocator header，64B payload 从旧 80-class 回到 72-class；独立前缀仍服务大块/过对齐对象。`heap_accounted` 与 `metadata_in_slab` 分位保留 `GCStats`、memory limit、`verifyHeapAccounting` 和 live=0 语义。

**前提勘误**（修正 memory/历史文档）：参照 qjs 树**自带 arena 分配器** `__js_malloc`（quickjs.c:1549-1594，31 size class/4KB arena/8B 块头），**GC 元数据（rc/mark/gc_obj_type）就内嵌在这个 8B malloc 块头里**（quickjs.c:270-280）；js_def_malloc 只是 backing（arena 碎取/大块时才被调）。zjs SmallObjectSlab 正是它的镜像（size class 表逐字节相同）。

- [多做工·最大剩余集中税] **每-alloc/free 记账标量 zjs 4-5 个 vs qjs 0 个**：zjs 每对象更新 memory.allocated_bytes（双向）+ stats.allocated_bytes/alloc_count + space.live_bytes（双向）+ meta.size_class + gc_object_count；qjs 小块路径的 malloc_size 按 **arena 粒度**更新（稳态循环通常不动）。但 `stats.allocated_bytes/alloc_count` 不是可直接删除的内部探针：它们进入公开 `JSRuntime.gcStats()`/`GCStats` 的累计字段，现有测试也断言其语义。优化必须先选定兼容方案（例如显式可选的累计统计、冷路径事件汇总，或经 API 决策后的语义变更）；不得以性能名义静默改变公共统计契约。`live_bytes` 是否能降到 arena 粒度也要保留 `verifyHeapAccounting` 与释放后 live=0 的不变量。
- [结构] **GC 元数据独立 8B 前缀 + 三重初始化**：zjs 对象块=8 slab 头+8 Metadata+64 对象=80-class（每 arena 50 块）vs qjs 8+64=72-class（56 块）；rc/flags/prev/next 在 initGcPrefix、addWithSize、`.header=.{}` 写 2-3 遍（qjs 各字段恰一次）。折叠 Metadata 进 slab 块头有 qjs 锚点；顺带消掉 free 侧尺寸重构税（destroyFromHeader 重算 inline_layout→alloc_size，qjs js_free 从块头自恢复）。
- [多做工] refcount dec 的 3 项额外分支（§4.1 已列：string rc 偏移不统一/deinit 相位提前到每-dec/profile 探针）——三者均有 qjs 锚点。
- [多做工] free 路径 side tables 现状：weak-id/borrowed/std_file **已旗标化**（~5 分支，接近 qjs 平价）；**唯一剩 iterator 缓存表每 free 无门线性扫**（object.zig:1902→1604-1628，qjs 无对应物）。历史"15% 集中税"已大幅缩水。
- [多做工·仅 GC 周期] 环收集 ~7 次全表遍历+每周期堆分配（garbage_headers ArrayList 快照）vs qjs 3 遍零分配（intrusive list 拼接即分区）；弱清扫遍历全部 GC 对象 vs qjs 只遍历 weakref_list。
- [多做工·小] 对象创建时 class 元数据读取（recordPtr+layout+exotic/slow 谓词 ~10-20 insn vs qjs JS_CLASS_OBJECT 臂零读取）；限额检查每 alloc vs qjs arena 粒度。
- [对齐] slab 几何全套逐字节同（31-class 表/4KB arena/8B 块头/u16 free 链/满-空迁移时序/**一空即还 backing——修正 memory 中"背离"定性，两边同构**）；>512B 直达 backing；GC 阈值 1.5x 增长+单点触发；环收集三访问器语义 1:1；Pass-B husk 延迟；fast array 1.5x 增长。
- [反超·勿动] `{}` 与数组 1 笔分配 vs qjs 2 笔（qjs 恒分配 prop[2]=32B；zjs capacity=0 不建+array_length 内联字段）——抵消记账税的另一半，"本体打平"的原因。

### 4.6 字符串与 atom（A6）

> 整改后：cell-backed local 与裸 local 都按“binding 一份 + 临时 dup 一份”的 rc==2 规则启用 rope tail；独立快照会把 rc 提高并自动阻止原地追加。通用 rope 已补齐 qjs 的 512/8192 短串阈值、depth>60 Fibonacci 重平衡、无分配叶迭代与非 flatten 单码元读取；未删除普通构建的 GC hook。

- [多做工] **OP_add 字符串腿走 4 层冷链**（cold-hop→h_binary→binaryVm noinline→binary 重判→value_ops.binary 二次分派→stringAdd），qjs OP_add CASE 体第三腿内联 `JS_IsString×2 → JS_ConcatString`（quickjs.c:19729-19733）。L5a（1.30x）最大每迭代固定税。
- [结构·双向补偿·勿单向修] qjs `JS_ConcatStringInPlace`（4671-4705）靠 malloc-slack（桶余量）rc==1 原地追加免结果分配；zjs flat 串 FAM 精确尺寸无 slack——但 zjs 的 string+int 免中间 digits 串（smallIntString 缓存+栈 itoa 直拼单分配），qjs 恒 1 digits 分配+free。净分配打平。
- [多做工] **普通构建中每次字符串分配付 GC 阈值检查**（string.zig:647→requestGCForAllocation）；qjs 的 js_trigger_gc **只挂在 JS_NewObjectFromShape 一处**（5619），字符串/绳节点分配不查。生产态 GC pacing 可向“对象创建触发”收敛，但不能直接从通用分配包装器删除 hook：`requestGCForAllocation` 同时承载测试 trigger 与 `-Dzjs_force_gc` 的“每次 runtime allocation 前强制 GC”契约。正确拆分应让普通构建跳过非对象阈值检查，同时在 test/force-GC comptime 分支继续覆盖所有相关分配。
- [多做工] template `concat` 体前多 3 层+qjsStringPrototypeMethod 7 个顺序 id 比较（qjs 函数指针直达）；但 zjs concat 体本身分配侧更优（32-part 测长单分配 vs qjs 左折叠逐步 concat）。template 1.37x 的主体在分派塔。
- [结构] atom 表：qjs「字符串即 atom」（JSString 第三 u32 是 hash_next 内嵌链，新串就地变 atom 零拷贝）；zjs 独立 AtomTable+bytes 副本+双向缓存（第三 u32 是 atom_id 回指）。稳态被缓存抹平，差在首次 intern 与内存形态。
- [对齐] 通用 rope 几何：512/8192 阈值、depth>60 Fibonacci buckets、无分配叶迭代、单码元递归读取、比较/哈希不强制 flatten，以及线性化结果缓存均已有对应实现。
- [对齐] JSString 12B 布局/短串创建/字面量 atom 复用（push_atom_value 稳态 dup）/fresh 拼接单分配双 memcpy/add_loc 窥孔/template 发码/charCodeAt 体语义/s.length rope 感知 O(1)/内容哈希 h*263/子串立即拷贝。
- [反超·勿动] 累积 rope-tail 累加器（机制在位）；int→string 0-255 缓存+免 digits；单字符/recent-atom 缓存群；charCodeAt 直达。

### 4.7 builtins 与原生调用边界（A7）

> 整改后（部分完成）：Math 一元方法迁到 `.f_f`，`atan2/pow` 迁到 `.f_f_f`，非 primitive 参数仍走完整可观察 ToNumber fallback；普通调用优先使用对象 memo 的 `nativeRecord`。Math.abs 方法代表运行约 3.372B→3.101B instructions、665M→566M cycles；plain-call 代表运行约 1.821B→1.456B、369M→259M；generic `Math.min` 未见 instructions 回退。二次审计把 `Function.prototype.call/apply` 也绑定到 `.function` record，并为所有 internal-record 调用链接 native backtrace frame。`Array.prototype.push` 现为 Array 域首个 per-method full-context record，且 fast array 在 ToObject/receiver dup 前处理；Array 其余方法和 string 等大域仍使用共享 full-context handler，不宣称全仓 typed-cproto 迁移完成。

层数结论（nm 实证动态调用边界）：qjs 恒 3 层（JS_CallInternal→js_call_c_function→body 指针）。zjs 分化：charCodeAt/at/codePointAt **2 层（反超）**；Math.floor 2 层+每参数 3 个协转出线调用≈5；Array.push 4 层；**普通位置原生调用（parseInt 等走 op.call）5+ 层**。
- [整改前结构·迁移未开始] **record.call 指向 per-domain magic-switch 共享 handler 而非 per-method body**：QJS 式 `NativeCProto`/`native_function` 字段当时已声明但**全仓 0 个 entry 使用**（1eacd18 文档明示的未完成迁移）。Math 37 臂 switch、array 40+ 臂。qjs JSCFunctionListEntry 指针直达 body，magic 只做 selector。
- [整改前多做工] Math 参数协转塔：`toMathNumber→toPrimitiveForNumber→toNumberValue` 每参数 3 个真实调用+2 次 free；qjs f_f cproto 在 js_call_c_function 内联 `JS_ToFloat64`+libm（17647-17656）。当时的 `tryFastMathCall` 是零调用死代码，当前已删除。
- [已完成] 普通位置（op_call）原生调用已使用函数对象的 `nativeRecord` memo，并从 payload 直接读取 native realm；不再每次 decode id+查表。
- [已完成·Array 首域] `Array.prototype.push` 的 record 指针直接进入 152B 专用 wrapper，绕过 4620B Array 共享分派体和 444B `qjsArrayPushCall` 再验证；语义体在 receiver dup/ToObject 前尝试真实 Array fast arm，包含 qjs 的零参数路径。
- [多做工] string 兜底组（repeat/toUpperCase 等）双重 record 分派自我重入 ≈6 层（callStringBody 重编码 id+查表二次进 stringCall）。
- [结构·迁移债] 名字分派兜底链（首字符 switch+~40 段 std.mem.eql，atomics/performance/promise 等未迁移域）；qjs 无按名分派。
- [结构·当前边界] qjs 在 `JS_CallInternal` 入口 poll、在 `js_call_c_function` 检查 native stack 并链接 `JSStackFrame`。zjs 在 VM call entry/所有跳转和条件分支 poll，以 `native_call_depth`+heap-frame fallback 保护解释器重入，并在递归 JSON/join 等 native 算法入口检查真实机器栈；internal-record 现在链接 `ActiveBacktraceFrame`，`map.call(...)` 的栈为 `map (native) → call (native) → <eval>`，与 qjs 一致。record 本身没有独立 interrupt-counter decrement，仍属调用架构差异，不能再写成“native frame 未验证”。
- [对齐] 发码形态 get_field2+call_method/receiver 布局/区域拆除/comptime record 表（length/magic 与 js_math_funcs 逐条一致）/懒物化安装链/回边 poll。
- [反超·勿动] charCodeAt 2 层直达；op_get_field2 对原始 string 接收者直解方法（qjs 每次走慢径）；dropUnusedCallResult 结果丢弃融合。
- [已清理] 零调用的 `tryFastMathCall` 和 `preparedCallOk` 已删除；前者与当前 typed-cproto/nativeRecord 快路重复，后者从未进入 prepared-call 资格判定。

### 4.8 杂项运行时构造（A8）

> 整改后：primitive/string-wrapper for-of 快路已删除并统一 GetMethod；`in` 的 `toString` 名字拐杖和 `instanceof Array` 的 `flags.is_array` 特判已删除。C2–C4 现与 qjs 输出一致。

前置勘误：参照 qjs 树已是**新版 var_ref 化全局机制**（JS_CLOSURE_GLOBAL cell），旧版"JS_GetGlobalVar 两级查找"叙事作废；zjs 全局模型（global cell/ctx.lexicals/uninitialized_vars 侧表）与新版结构一致。
- [多做工] **put_var 无 fast handler**（get_var 有——读写不对称）：每全局写付 publish+noinline putVar+coldNext；qjs OP_put_var 热臂 ~10 insn 内联（18490-18525）。zjs 热臂本体对齐但多 3 项载荷（无条件 globalVarAtom/嵌套 cell 检查/function-name 位独立检查）。⚠️补 handler 前须实测（memory 有 T2 时间中性否决先例）。
- [多做工] **put_var_ref 家族恒冷** + `publishTopLevelFunctionVarRef` 检查链被泛化到所有 var_ref 写（qjs 该语义只在 put_var）；qjs put_var_ref0 = `set_value` 4-5 insn（18617）。读侧已对齐。
- [多做工] try 块进/出各付一次 cold hop（op.catch 恒冷+catch_target 侧寄存器模型）；qjs OP_catch 内联 3 insn 推 tagged 值、抛时扫栈（18922-18930）。
- [多做工] instanceof 走按名分派瀑布（借名+2 次字符串比较才到 hasInstance 体，qjs 函数指针直达）；in 运算符每 proto 层 materialize 完整 Descriptor（含值 dup/free，qjs desc==NULL 纯存在探测）。
- [多做工] `a[i]=v` 引用计数值存储走 dup+free 往返（setFastArrayElementDup+handler free）；qjs OP_put_array_el `set_value` **MOVE** 零 rc 流量（19546-19583）。int 元素无差。
- [多做工·小] op_get_var fast 臂 3 处额外载荷（local_fast_blocked 门/界检查/frame 间接——qjs var_refs 寄存器驻留）；lnot/typeof 族恒冷（本体已对齐）。
- [对齐] 全局 VARREF cell 模型全套/闭包 var_refs 借用/direct eval 编译期绑定（80da8e4 后 get_var 热路径零 eval 残留）/for-in 全套/a[i] 读/数组 append 门。
- [整改前结构·正确性缺口] for-of 的 iterator-result 主体与 result-obj-free 已对齐，但 primitive string/string-wrapper 入口提前构造内建 iterator，绕过可观察的 `Symbol.iterator` 读取；当时不能概括为“for-of 全套对齐”。
- 🐛 **已确认的忠实性缺陷 3 项（非性能）**：
  1. `instanceof` 的 Array 特判可达，但原先猜测的“用户 `function Array(){}` 命中”不成立——`constructorNameEqlLocal` 只识别 native dispatch name。真实最小用例是先给原生 `Array` 定义 own `Symbol.hasInstance = undefined`，再把数组实例 prototype 改为 null；qjs 按 OrdinaryHasInstance 返回 false，zjs 用 `flags.is_array` 返回 true。
  2. for-of 对 primitive string 直接构造内建 string iterator，跳过 `GetMethod(value, Symbol.iterator)`；patch `String.prototype[Symbol.iterator]` 后，qjs 迭代 patch 结果 `X`，zjs 仍输出原串 `ab`。
  3. in 运算符的 `atomNameEql(key,"toString")` 兜底造成直接错误：`"toString" in Object.create(null)` 在 qjs 为 false、zjs 为 true。无需再以“根因未定位的风险”降级描述；应删除语义拐杖并补齐真实 Object.prototype 链/存在性探测。

### 4.9 发码形态与 peephole（A9——补充 §2 的系统化全集）

> 整改后：C1 的 for-head lexical 在声明点无条件武装 TDZ。resolve_labels 已实现 dup+put→set、同向逻辑链、null/undefined/typeof 比较、undefined+return 和终止后死代码删除；删除 atom-bearing 指令时同步重建 atom ownership。generator finally 的隐式 rethrow marker、外部 jump target、IsHTMLDDA 和 callable native/Proxy 均有专门回归。

管线级事实：zjs 三 pass = resolve_variables → fuseIncLoc → resolve_labels（bz:7254-7307）；opcode 表与 quickjs-opcode.h **逐项同构**（id/尺寸/格式全同），差异全在发射层。
- 🐛 **整改前真语义 bug（本轮已修复）**：C-style for-头 let 绑定从不被 `set_loc_uninitialized` 武装——decl 点发射在死门后（pz:13568-13572 依赖恒 false 的 use_short_opcodes）+ 序言武装被 `tdz_emitted_at_decl=true` 跳过（bz:5150）+ for 路径无 enter_scope。整改前实测 `for (let i = i; …)` qjs 抛 ReferenceError、zjs 静默通过（test262 未覆盖此形状）；本轮去掉了声明点发射对 use_short_opcodes 的错误依赖。
- [整改前多做工·peephole 缺口]（qjs resolve_labels 有、zjs 当时无，每处 +1~2 op）：①**dup+put→set 族规则缺失**（qc:35368-35400/35475-35492）——值被使用的赋值（`y=(x=v)`、`while((c=…))`）zjs 发 `dup;put_loc` 2 条 vs qjs `set_loc0-3` 1 条，set_loc 族短 op zjs 几乎不产生；②**`&&` 链坍缩缺失**（qc:34478-34515 dup/if_false/drop→单 if_false）——每 `&&` +2 op；③**is_null/is_undefined/typeof_is_* 折叠缺失**（qc:35143-35168/35326-35345/35533-35570）——`x===null`/`typeof x==="undefined"` 每处 +1 op；④undefined+return→return_undef 折叠缺失；⑤块中 return 后死语句保留（qjs skip_dead_code）。
- [对齐] 短 int 推送/push_const8/fclosure8/loc 短形/call0-3/if8-goto8 松弛/inc_loc-add_loc 融合（fuseIncLoc 窗是 qjs 超集）/goto 链穿透/tail_call（zjs parse 期改写 vs qjs resolve 融合，结果等价）/丢值赋值无 dup+drop（parse 期 result_needed vs qjs peephole 坍缩，殊途同归——即 30c292d 历史修复的延续确认）。
- [反超·勿动] 全局赋值语句 4 op vs qjs 6（qjs 的 dup+put_var+drop 无坍缩规则）；for-let 丢值 i++ 少 1 op（inc vs post_inc+drop）；array_from 无 32 元素上限（qjs 超 32 转 define_field）。
- 结构备忘：zjs 的 TDZ 武装时序=函数序言一次性+enter_scope 入口 close+re-arm（boxed-cell 模型）vs qjs 每 enter_scope 展开+leave_scope 出口 close（捕获者）；zjs 方法调用额外记 direct_call_sites side-table 元数据（非 op）；局部 const 写=运行时 vardefs 查询 vs qjs 编译期 throw_error 替换（§4.2 is_const 刀的发码侧确认）。

## 5. 本轮整改状态

### 5.1 正确性门禁

十一项均先加入失败回归或双引擎可执行证据，再修根因；没有扩大 test262 exclude；C7–C10 只删除已经转绿的 known-errors。

| # | 整改 | 当前结果 |
|---|---|---|
| C1 | for-head lexical 在声明点发 `set_loc_uninitialized`，不再依赖 phase-2 尚未开启的 short-opcode 标志 | 自引用、空 test/update、closure capture 回归通过；zjs/qjs 均抛 `ReferenceError` |
| C2 | 删除 primitive/string-wrapper 和 iterator-class 的协议前置短路，统一读取 iterator method | patched `String.prototype[Symbol.iterator]` 两端均得到 `X`；sync/async iterator 切片通过 |
| C3 | 删除 `toString` 名字兜底，ordinary/proxy 路径走真实存在性探测 | `"toString" in Object.create(null)` 两端均为 `false` |
| C4 | 删除 native-name Array 特判，`@@hasInstance` 缺省时走 prototype chain | prototype=null 数组两端均为 `false` |
| C5 | conditional-only 回边在四种条件跳转形态上统一 poll installed interrupt handler | `do {} while (true)` 修复前超时，修复后返回 `error.Interrupted` |
| C6 | internal builtin 调用链接 native frame；`Function.prototype.call/apply` 进入 `.function` record | `map.call/apply` 两端均为 `map (native) → call/apply (native) → <eval>`；CallSite file/line/column 为 null，`isNative()` 为 true |
| C7 | 模块声明先实例化且只执行一次；TLA 恢复占据真实 Promise reaction 位置；等待中动态导入共享求值结算；拒绝按叶到根传播 | 原失败 7/7 转绿；整个 `top-level-await` 目录 251/251；4 条新增 Zig 回归并入 unified 1329/1329；同一 awaited Promise 的顺序与 qjs 均为 `before,module,after` |
| C8 | DynamicImportCall 发码后清除匿名函数 named-evaluation 候选，避免参数 arrow 把外层声明错误标记为匿名函数命名目标 | 原失败 1/1 转绿；整个 dynamic-import assignment-expression 目录 28/28；直接 arrow 声明的正对照仍保留 `set_name` |
| C9 | 当前非箭头函数的隐式 `arguments` 在父作用域捕获前物化；显式参数绑定优先于 pseudo-variable，嵌套 arrow 捕获同一函数绑定 | 原失败 2/2 转绿；整个 `for-await-of` 目录 1234/1234；显式同名参数与 destructuring 对照均与当前 qjs 一致 |
| C10 | generator return-through-finally 用正常出口定位真正的合成重抛，并让该出口标记跨 dead-code peephole 保留 | 原 AsyncGenerator 失败转绿；`AsyncGeneratorPrototype/return` 19/19；同步/异步显式 finally throw 与关闭后 `.next()` 均有 Zig 回归 |
| C11 | `Promise.resolve` 对 native Promise 先读取 observable `constructor` 并完成身份命中，再由 capability 慢路验证 `this` 是否可构造 | ordinary receiver 与自定义 `promise.constructor` 相同的最小用例由 `TypeError` 转为身份返回；getter 次数/抛出顺序、subclass、`.call`/`Reflect.apply` 与 qjs 一致；resolve 目录 30/30 |

原先列为开放的 if-only 中断 poll 与 `useUncheckedLexicalLocals` 死码均已闭合。仍存在的正确性与机制差异单列在 §5.4，不再与 §5.2 的性能架构迁移或附录 A 的历史证据缺失混写。

### 5.2 性能前沿逐项处置

| # | 状态 | 本轮处置与证据 |
|---|---|---|
| 1 | 完成 | shape transition 改为 `**Shape` ownership API，cache/shared/rc==1 三臂；FAM relocation、hash、共享与 OOM 回归通过 |
| 2 | 完成 | safe local ref-tail 改写为 loc get/put；eval/with/closure/destructuring/const/function-name 均保守退出 |
| 3 | 完成（窄刀） | 默认 repr 使用无符号 tag 范围比较，profile 探针 comptime 裁剪；未捆绑 rc 物理布局重写 |
| 4 | 完成 | slab header 与 GC Metadata 复用，64B payload 使用 72-class；公开累计统计和 heap-accounting 不变量保留 |
| 5 | 完成（窄刀） | const local write resolve 期发 message-carrying `throw_error`；运行时 handler 删除 is_const 分支 |
| 6 | 完成（首刀） | 删除 `Machine.switched` 3 写 0 读；其余调用架构候选仍独立留置 |
| 7 | 部分完成（边界扩大） | Math `.f_f/.f_f_f` + observable-coercion fallback + plain-call nativeRecord memo；Function `toString/bind/call/apply` 全部 record 化，native frame 可见；Array.push/pop 使用 per-method full-context record，push 在 ToObject/receiver dup 前走 qjs 式 fast-array arm，pop 直接处理真实 Array 的 length 槽并为 observable 慢路保留完整 Get/Delete/Set 顺序；Promise.resolve 使用 Promise 域首个 per-method record 并在 capability 验证前完成身份命中；String 大小写方法使用 qjs 式共享 per-method body，ASCII 映射直接写最终 inline String；其他共享 full-context builtin 域未伪装成 typed-cproto 已迁移 |
| 8 | 完成（证据改刀） | 原 GC-pacing 假设未采纳；真正瓶颈是 cell local 禁用 rope tail，2M 代表运行约 −62.2% instructions / −78.2% cycles / −96.2% minor faults |
| 9 | 原刀否决，替代刀完成 | 64 tombstones 无可测 instructions 惩罚，未做 risky compact；cached-string-atom 路径使 computed read 约 −26.9% instructions / −23.5% cycles，静态读不回退 |
| 10 | 完成 | 五族 peephole、atom ownership 与隐式控制流保护均有 snapshot/语义回归；相关 test262 867/867 |

第 10 项固定脚本 `peephole-mixed-2m.js` 的 5 次 CPU5 计数：zjs 4.24004–4.24066B instructions、725.0–733.2M cycles；qjs 2.13953–2.13971B、350.0–353.3M。该总差距还包含 checked locals、调用与其他残余，不能全部归因给 peephole。

调用/闭包前沿的追加测量（CPU19，ReleaseFast；7 轮配对、每轮各运行 5 次，表中为每次运行的归一化代表值）如下；冻结的本轮工作树起点二进制只用于同机 A/B，不替代 qjs 参照：

| 固定脚本 | 起点 zjs | 当前 zjs | qjs | 当前 zjs/qjs |
|---|---:|---:|---:|---:|
| `call-const-zero-arg-10m.js` | 0.47s | 0.316s | 0.196s | 1.61x |
| `call-add-two-arg-10m.js` | 0.37s | 0.338s | 0.212s | 1.59x |
| `call-named-function-expression-two-arg-10m.js` | 0.43s | 0.370s | 0.214s | 1.73x |
| `call-closure-two-arg-10m.js` | 0.49s | 0.400s | 0.239s | 1.67x |

新增 named-function 隔离把 closure cell 与函数名序言拆开：匿名 factory 与直接声明在 zjs 都约 1.76–1.77s/50M，给返回函数增加内部名字后变为 2.16s，而 qjs 两者都约 1.05–1.06s。两端都发 `special_object THIS_FUNC; put_loc*`；qjs 在 `JS_CallInternal` CASE 内直接 `JS_DupValue(sf->cur_func)`，zjs 原先却走 `coldStd → vm_literal.specialObject → coldNext`。当前只把不可失败的 `THIS_FUNC` arm 放进 152B frameless handler，其他会分配或访问复杂状态的 subtype 保持 cold；named 与 named-closure 分别约下降 14.4%/14.5%。同时 FunctionDef 序言复用 `selectShortSlot/emitSlotInstruction`，开启 short-opcode 时的全序言样本从 42B 降到 29B，实际 named 函数从 wide `put_loc u16` 对齐为 qjs 式 `put_loc0`（9B→7B）。

本轮也用单变量构建否决了四个诱人但无收益的方向：强制内联 `pushFrame` 让三组调用变慢 3–8%；删除 inline depth 上限比较对 call0 中性、对 call2/named 变慢约 4%；删除未读 `InlineTarget.callable`（48B→40B）中性到约 +1%；关闭 same-loop 后，现有 recursive fallback 慢 3.2–3.4 倍。四项源码均已撤回，避免把结构清理或“更像 C 递归”误报成性能对齐。

后续调用 A/B 又否决了四个表面更像 qjs、但当前代码生成无净收益的方向：运行时 `args_never_boxed` 标志让调用脚本慢 3–5%；只为证明不会 boxing 的函数发无守卫 short `get_arg`，普通 identity 仅约 −0.3%，mapped arguments 反而慢 1.7–3.6%；预计算 `needs_open_var_refs` 虽让 constant-pool call 快约 7%，却让 identity 及 mapped/captured 形态退化；`VmStackArena.restore` 显式 same-chunk arm令 identity/call-add 慢约 4%。四项均已撤回。独立缓存重建还证明相同源码的 `.text` 完全一致；先前一次普通调用约 3.6% 的漂移在全新重建后不复现，因此没有把函数地址变化误报成逻辑回退。

Array builtin 首域使用固定脚本 `array-push-one-arg-5m.js` 做 CPU19、ReleaseFast、7 轮交替配对：冻结起点 zjs 中位数 299.828ms，当前 275.392ms，qjs 184.735ms，故 zjs/qjs 由 1.62x 降到 1.49x（当前相对起点 −8.15%）。同一反馈环的零参数探针为 422.105→235.786ms、qjs 166.703ms（2.53x→1.41x），四参数探针为 370.241→344.611ms、qjs 226.592ms（1.63x→1.52x）；未改的 `call-const-zero-arg-10m.js` 控制为 315.856→315.052ms，中性。反汇编显示起点 `arrayCall` 共享体 4620B、后续 `qjsArrayPushCall` 再验证 444B；当前 record 直达 152B wrapper 后进入同一语义实现体。收益因此同时来自 per-method record 与 qjs 式 pre-ToObject fast-array arm，不外推为整个 Array 域已迁移。

Array.pop 使用新增固定脚本 `array-pop-empty-5m.js` 做 CPU19、ReleaseFast、9 轮轮换顺序墙钟配对；当前容器禁止 PMU 访问，因此这组数据只作同机 A/B，不冒充 instructions/cycles 证据。最终源码的冻结起点 zjs 中位数 618.509ms，当前 392.214ms，qjs 238.340ms，故 zjs/qjs 由 2.60x 降到 1.65x（当前相对起点 −36.6%）。单做 per-method record 只有约 −2.8%，主收益来自真实空 Array 直接读写不可观察的 length 槽；非空真实 Array 也直接读 length，并在 getter 未把当前 length 扩到原值之外时直接完成最终缩短。若 getter 扩容、receiver 是 Proxy 或普通 array-like，则仍走完整 Get/Delete/Set，确保最终缩长会清掉 getter 新增的高位元素且保留 non-writable 抛出顺序。提取式 `pop.call([])` 与普通 array-like 探针仍约为 qjs 的 2.98x/3.89x，表明 Function.call 与通用属性路径尚未闭合；把通用慢路强制拆成 noinline 对 array-like 反而约 +2.5%，已撤回。新增 Zig 回归覆盖 frozen empty Array、Proxy traps、普通 length accessor、Array subclass、getter 中途扩容，以及 qjs 的只读 length 错误文本/删除顺序；目标 test262 目录 23/23。

Promise builtin 首刀使用固定脚本 `promise-resolve-same-1m.js` 做 CPU19、ReleaseFast、9 轮交错配对：冻结起点 zjs 中位数 580.090ms，当前 130.166ms，qjs 40.408ms，故 zjs/qjs 由 14.36x 降到 3.22x（当前相对起点 −77.6%）。根因是 `.promise` 域原先没有 internal record，VM 每次都借 dispatch name、重新解析 realm 的 `Promise.resolve`，并在身份命中前先验证 `this` 的构造器能力；当前 record 直达独立的 `qjsPromiseResolveStaticCall`，且按 qjs `js_promise_resolve` 顺序先做 observable `constructor` 身份检查。提取式 `.call` 探针下降约 29%，primitive resolve 探针下降约 35%；未改的 `call-const-zero-arg-10m.js` 控制为 316.187→316.274ms，中性。把 capability 慢路再标为 `noinline` 的实验使身份脚本 130.829→131.481ms（+0.5%），已经撤回。3.22x 残差因此仍属开放性能边界，不外推为整个 Promise 域已迁移。

String case-conversion 使用固定脚本 `string-upper-ascii-5m.js` 做 CPU19、ReleaseFast、7 轮交错配对：冻结起点 zjs 中位数 1717.672ms，当前 308.435ms，qjs 487.991ms，故 zjs/qjs 由 3.52x 降到 0.63x（当前相对起点 −82.0%）。起点路径为 `stringCall → qjsStringPrototypeMethod → callStringBody → stringCall → methodCall → unicodeCaseReceiver`，且 `unicodeCaseReceiver` 先逐字符写临时 `ArrayList`、再分配并复制最终 String；qjs 的 `js_string_toLowerCase` 是独立 function-list body，`string_buffer_init(p->len)` 分配的缓冲本身就是最终 `JSString`。当前 `toUpperCase`/`toLowerCase` 两条 record 直达 264B 的共享 handler，ToString owned value 按 qjs 顺序被转换体消费，ASCII 源经一次证明后直接写最终 inline narrow String。单做 record 化约 −11.3%；只预留临时 ArrayList 为 +0.5%、ASCII 专用映射但仍保留临时缓冲为 +4.3%，两项均撤回。未改的普通 call0 控制为 316.143→317.146ms（+0.3%）；非 ASCII `é` 探针为 105.941→81.100ms、qjs 46.880ms，说明 per-method 分派收益覆盖全域，但通用 Unicode 临时缓冲仍留下约 1.73x 残差。

函数生命周期另发现一个独立的二次复杂度缺陷：嵌套函数的 realm 借用引用都登记在 runtime holder 数组，FIFO 析构原先逐项线性查找并 `copyForwards`，20 万函数需要 2.26s。当前函数 payload 用既有 3 字节尾隙缓存 `index+1`，holder 删除改为 swap-remove 并修复被移动项的缓存；`function-create-nested-hold-200k.js` 降到 0.11s，复杂度扫描 50k/100k/200k 为 0.02/0.06/0.10s。qjs 同一 200k 脚本为 0.04s，因此算法级差异已闭合，固定成本和内存差距仍在。DWARF 实测默认 `FunctionPayload` 保持 80B；该脚本 max RSS 当前约 79.4MiB、qjs 约 30.8MiB。

### 5.3 验证状态

- Debug unified：最新工作树 1349/1349；`checkpoint-check` 25/25 steps。
- `quick-check` 16/16、`checkpoint-check` 25/25、architecture/API snapshot、OOM-cap 2/2：通过。
- alternate representation：最新工作树 1349/1349。
- OOM injection：最新工作树 7/7。
- `test262-smoke`：12/12；Array/prototype/push 24/24、Array/prototype/pop 23/23；Promise/resolve 30/30；String 四个 case-conversion 目录 110/110；最新联合 changed-area：TLA 251、dynamic-import assignment-expression 28、for-await-of 1234、AsyncGeneratorPrototype return 19、Function call/apply 97，合计 1629/1629。staging `Function/arguments-parameter-shadowing.js` 当前 zjs 1/1，当前 qjs 0/1。
- 函数序言 changed-area：function expression/statement、new.target、method-definition、arrow-function、Function builtins 联合 1884/1884。
- C1–C4/相关 changed-area test262：1215/1215；peephole 相关切片：867/867；二次审计 `let` 145/145；C7 的 module-code 595、dynamic-import 597。
- full test262：默认 8B repr 与 alternate 16B repr 均准备 49,775/53,293，排除 3,518，按 feature 跳过 5,174；通过 44,599，known 2，unexpected 0；两次 `test262-gate` 均 5/5 steps。
- ReleaseSafe unified：1349/1349，10/10 steps。

full test262 的阶段首跑曾暴露 IsHTMLDDA callable 判定与 generator finally rethrow marker；C8–C10 的收口首跑又暴露普通 catch 误判 finally、参数环境 `arguments` 同名声明回填两条回归。上面的最终全量结果均已覆盖，不以逐文件复测替代全量门禁。

仍不主动改动的候选：`{}`/数组单笔分配、int→string 缓存、charCodeAt 直达、真 PTC、全局赋值语句短序列。它们没有新的可复现证据支持扩大本轮范围。

### 5.4 当前仍未与 qjs 对齐的边界

同一 test262 checkout 上逐条用本地 qjs 复跑原 13 条 known-errors：qjs 通过 11 条、失败 2 条。C7–C10 已让 qjs 通过的 11 条全部转绿并从账本移除；当前账本只剩下 qjs 自身也失败的 2 条，因此这份账本中已没有仍可确认的 zjs → qjs 语义差异。

剩余两条是 import attributes 的 `type: "text"`，以及未求值分支中的 `await using` 不应隐含 await。它们仍是 test262 兼容性债，但不能以“对齐当前 qjs”为理由直接整改；需要单独决定是否超越当前参照实现。

这个结论只覆盖原 13 条 known-errors 与已执行切片，不代表所有 test262 feature skip、配置排除项或未覆盖语义均已对齐。

另有一条明确的反向差异：zjs 通过 staging 的 `Function/arguments-parameter-shadowing.js`，当前 qjs 参照失败。这里保留 test262 所要求的参数环境/函数体同名 `arguments` 分离，不为了逐 bug 复刻 qjs 而制造回退。

参数环境还有一个必须明确记录的参照边界：`function f(arguments='old', x=(arguments='new')) {}` 中当前 zjs 与 qjs 都让函数体看到 `old`；destructured `{arguments}` 对照则都看到 `new`。前者追随当前 qjs 的 pseudo-variable 行为，但 ECMAScript 的 FunctionDeclarationInstantiation 会在参数 BoundNames 已含 `arguments` 时禁止创建 arguments object，因此这不是可外推为规范同构的证据。staging 的函数体同名 `var arguments` 分离仍是反向差异：zjs 通过、当前 qjs 失败。

机制层面仍须保留边界：当前文件加载器已覆盖上述 test262 TLA/DFS/动态导入顺序，但模块记录尚未完整承载 qjs 的 `dfs_index`、`dfs_ancestor_index`、`cycle_root`、`pending_async_dependencies`、`async_parent_modules` 和共享 top-level capability；host-hook 动态导入也仍使用独立求值路径。因此 251/251 证明目标语义面转绿，不等于异步模块 SCC 状态机已经与 qjs 逐字段同构。

当前已确认、且仍有实际成本或覆盖风险的机制差异按优先级归纳如下：

| 优先级 | 未对齐边界 | 当前证据/影响 |
|---|---|---|
| P0 | 调用帧与闭包访问 | qjs 的 `JS_CallInternal` 单体路径与寄存器驻留仍未被 zjs 的 Machine/Frame、tail-dispatch 分段路径同构替代；本轮闭合 named-function cold 序言后，四个固定调用脚本仍为 1.59–1.73x。 |
| P0 | 函数对象与 runtime holder 内存 | FIFO 析构已从 O(n²) 修成 O(n)，但 qjs 没有对应 borrowed-holder side table；20 万嵌套函数 max RSS 仍约 79.4MiB vs 30.8MiB。 |
| P1 | builtin typed ABI | Math `.f_f/.f_f_f` 与 Function record 已迁移；Array.push/pop、Promise.resolve 与 String 大小写方法已用 per-method full-context function pointer 直达，但尚非 typed ABI；Array 其余方法、String 其余方法、Promise 其余方法等仍经过共享 full-context/magic-switch handler。空 Array.pop 仍为 qjs 的 1.65x，提取式/普通 array-like pop 约 2.98x/3.89x；Promise identity 为 3.22x；非 ASCII case conversion 约 1.73x。 |
| P1 | 异步模块 SCC 状态机 | 目标 test262 切片已对齐，但 ModuleRecord 字段、cycle-root capability、parent/pending 关系以及 host-hook dynamic import 路径仍非 qjs 同构。 |
| P1 | 分配、RC 与 cycle GC | slab-backed GC metadata/refcount 前缀已与 qjs allocator header 同构；默认 8B NaN-box JSValue 仍是有意偏离本机 qjs 的 16B repr，每对象公开统计记账、borrowed/iterator/weak-id side table 与需要堆分配候选快照的多阶段 cycle collector 仍有额外工作。 |
| P2 | atom、shape 与属性删除 | zjs 仍是独立 AtomTable/字符串回指、deleted tombstone；qjs 是 JSString 即 atom，并物理摘链/阈值 compact。tombstone 专项没有测出收益，所以目前只记录机制差异，不凭结构相似性强改。 |
| P2 | 若干 opcode 热腿与 zjs 专用扩展 | 通用 rope 的阈值、Fibonacci rebalance、叶迭代和非 flatten 索引已对齐；zjs 仍保留 fused-local accumulator tail 这一有证据的扩展。`put_var`、写侧 `put_var_ref` 等仍在 cold handler，qjs 在解释器主体内联。是否改动继续以固定负载证据为准。 |

因此，“当前已测语义面没有已知 zjs→qjs 红项”与“实现已经对齐”是两件事；后者仍然不成立。

## 附录 A：证据重建命令（当前不构成完整复现）

以下命令说明测量机制；由于原基准脚本和 5 次原始样本缺失，它们不能单独复现 §1 数字。

```sh
# 身份核对
git rev-parse HEAD
git -C /home/aneryu/quickjs rev-parse HEAD
sha256sum zig-out/bin/zjs /home/aneryu/quickjs/qjs

# 单次测量模板；<bench.js> 必须替换为今后纳入仓库的固定脚本
taskset -c 19 perf stat -e armv8_pmuv3_1/instructions/,armv8_pmuv3_1/cycles/ -x, zig-out/bin/zjs <bench.js>
taskset -c 19 perf stat -e armv8_pmuv3_1/instructions/,armv8_pmuv3_1/cycles/ -x, /home/aneryu/quickjs/qjs <bench.js>

# zjs 字节码 dump
ZJS_DISASM=1 zig-out/bin/zjs file.js
# qjs 字节码 dump（隔离树，DUMP_BYTECODE=1 重编）
<qjs-dump-tree>/qjs file.js
```

将本快照升级为可验收基线前，至少补齐：

1. `tests/perf/qjs-align/` 下的 20 个脚本与 pin 对照，固定迭代数和预期 stdout。
2. 每引擎每脚本 5 次完整 perf stat CSV/JSON；聚合必须从原始记录自动生成，并报告方差/离散度。
3. 11 个构造的双侧 bytecode dump 与生成命令。
4. perf.data 或可导出的 folded profile、kernel/perf/compiler 版本、CPU governor 与二进制 hash。

## 附录 B：聚合测量快照（best-of-5 min，非原始数据）

下表是当时保存的聚合最小值。五次逐次结果未留存，因此无法检查方差、异常值或确认 instructions/cycles 最小值是否来自同一次运行；不得据此计算严谨 IPC 或设置自动回归阈值。

| bench | zjs insn | zjs cyc | qjs insn | qjs cyc |
|---|---|---|---|---|
| L0_emptyloop | 7157729330 | 1204197845 | 7705621169 | 1216493303 |
| L1a_accum | 11709185853 | 1809883590 | 11706990677 | 1777242761 |
| L1b_localarith | 15060794162 | 2408862599 | 15758349825 | 2392033386 |
| L2a_propread | 10929422186 | 1841902053 | 9696683563 | 1647978835 |
| L2b_arrayread | 9999013274 | 1636703839 | 9756335385 | 1523972125 |
| L3a_fib | 12855530846 | 2469565293 | 7184664154 | 1286194858 |
| L3b_funcall | 16732169659 | 2989624576 | 10006836070 | 1767263460 |
| L4a_emptyobj | 13239481835 | 1882950447 | 9326065677 | 1422214428 |
| L4b_objalloc | 47391746002 | 7050722620 | 23201260017 | 3610735983 |
| L4c_array3 | 17430848523 | 2480399252 | 10286548197 | 1612933544 |
| L5a_strconcat | 10178123621 | 1742184459 | 7844318148 | 1193689961 |
| L5b_charcode | 16731870560 | 2880190063 | 15808422345 | 2423315684 |
| P_tdz | 10689014524 | 1647465210 | 9516050426 | 1416185944 |
| P_ifobj | 9608577000 | 1511363583 | 10116304854 | 1479779884 |
| objlit_var | 27284391213 | 4175444510 | 10996530032 | 1738257388 |
| objlit_let | 24852960857 | 3588035640 | 12507107011 | 1957049957 |
| objprop | 11909444857 | 1877775180 | 8786208992 | 1491992341 |
| template | 4185503776 | 705840420 | 3052658116 | 499400918 |
| floatsum | 15811027208 | 2554669513 | 12007002588 | 1815457089 |
| strconcat | 1616116856 | 496650041 | 900614296 | 158711359 |

## 附录 C：已修复语义差异的最小回归

以下输出同时保留整改前事实和当前结果，避免把历史复现误读成现状。

### C1：for 头 let TDZ

```js
for (let i = i; false; ) {}
```

- 整改前 zjs：exit 0，无异常。
- 当前 zjs / qjs：均抛 `ReferenceError`（变量 `i` 尚未初始化）。

### C2：for-of 必须读取 patched String `@@iterator`

```js
String.prototype[Symbol.iterator] = function () {
  let done = false;
  return {
    next() {
      if (done) return { done: true };
      done = true;
      return { done: false, value: "X" };
    },
  };
};
let out = "";
for (const c of "ab") out += c;
console.log(out);
```

- 整改前 zjs：`ab`。
- 当前 zjs / qjs：均输出 `X`。

### C3：null-prototype 对象不继承 `toString`

```js
console.log("toString" in Object.create(null));
```

- 整改前 zjs：`true`。
- 当前 zjs / qjs：均输出 `false`。

### C4：Array OrdinaryHasInstance 必须走 prototype chain

```js
Object.defineProperty(Array, Symbol.hasInstance, { value: undefined });
const a = [];
Object.setPrototypeOf(a, null);
console.log(a instanceof Array);
```

- 整改前 zjs：`true`。
- 当前 zjs / qjs：均输出 `false`。
