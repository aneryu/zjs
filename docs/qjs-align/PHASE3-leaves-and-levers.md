# Phase 3 — 叶子（GC-无关忠实对齐 + 赢回退 + 大杠杆）

> 依赖 Phase 1（部分项也依赖 Phase 2 的 refcount 纪律）。**设计/实现规格，非代码。**
> 项目级清单源自首轮 15 项审计 workflow（已带 file:line + qjs 锚点）。每项门禁：`0/49775` default + nan_boxing + 结构对照 review。

## A. GC-无关忠实对齐

| 项 | 现状 → qjs | 锚点 |
|---|---|---|
| **属性槽 16B**（rank 4） | 40B tagged-union(enum) → 16B untagged，变体经 shape flags（JS_PROP_TMASK）派生 | property.zig:125-134 vs quickjs.c:947-963 |
| **删冗余 findProperty**（rank 5） | set→create 路径 2 次 findProperty → 1 次（thread first-miss 进 createOwnDataProperty）；保 public defineOwnProperty 重扫 | object.zig:8858/8880/9240 vs quickjs.c:9705 |
| **fast-array realloc**（rank 6） | alloc+memcpy+free → realloc/remap（slab-eligible 块保 copy+free 回退） | object.zig:3382 vs quickjs.c:9524-9538 |
| **Array.push 多参**（rank 12） | args.len==1 守卫 → argc 参数 expand-once + tight store loop | array_ops.zig:2792 vs quickjs.c:42761-42789 |
| **arith window**（rank 7） | add/sub… 无条件 syncDown → 接上**已写零调用**的 `tryInt32BinaryWindow`、int32 fast path 不 syncDown | vm_arith.zig:175 vs quickjs.c:19696-19709 |
| **bothInt 单测试**（rank 10） | 两次 asInt32 orelse → `(a.tag|b.tag)==0` 单测试 | vm_arith.zig:167-212 vs quickjs.h:284 |
| **string hash 懒算**（rank 8） | create/concat 即时 O(n) 算 hash → 懒到 intern 时（注意 in-place append 链 self.hash 须先物化） | string.zig:123/149/340… vs quickjs.c:3200 |
| **JS→C kind-switch**（rank 11） | ~20 项线性探测梯 → 函数对象创建期定的 kind-tag switch | call_runtime.zig:478 vs quickjs.c:17816-17824 |
| **parser peephole**（rank 13，编译期） | 补 jump-threading + push_i32+if_false/true 常量折叠 + push_i32+neg 折叠 + skip-dead-past-goto（修 resolve_labels.zig:69-70 过期注释） | resolve_labels.zig vs quickjs.c:35197-35223 |
| **热 opcode 寄存器驻留**（rank 14，依赖 A 的 property fast-path） | ~166 syncDown+out-of-line 臂中，把 prop_write/create/array_push/get_field happy path 提为寄存器驻留（非全部，避 I-cache 炸） | — |

## B. 赢回退（回退到 qjs 结构）

| 项 | 回退 | 备注 |
|---|---|---|
| 小 shape 线性扫 | ≤4 属性线性扫 → qjs always-build-hash | 行为等价 |
| 双 shape-transition | per-parent 链 + 全局 root-intern → qjs 单 `find_hashed_shape_prop` | 注意：审计曾称二者"索引不同东西"——**回退前查证**该说法，确认全局 hash 能否覆盖 per-parent transition cache 的语义 |
| **string-off-cycle-list**（codex 更正 2026-06-23） | qjs **有** rope（`JS_TAG_STRING_ROPE`/`JSStringRope`，refcount-only 不上 gc_obj_list，图无环）→ 把 zjs string/rope/.slice **移出环收集器 gc list** → refcount-only、极小头，对齐 qjs；**保留 rope（不 revert）** | 解开 keystone S1 延后的 24B-header 耦合；.slice 的 dangling-borrow「风险」落实时查证 |

（注：dup-proto 回退、SHAPE 入 gc_obj_list 已并入 keystone **S4b**。）

## C. 大杠杆（高侵入，flag-gated，逐阶段 0/49775 把关）

### C.1 global-var 稳定 cell（global_destruct_strict 1.85×）
- 撤 zjs 的 global-var-by-name（global-object property 表 + IC + cascade）+ `global_lexical_sync` 镜像 → qjs 稳定 var_ref cell
  （稳态一次间接，property 表仅作 missing/slow 回退）。
- **高风险**：编码 TDZ(let/const)、eval_local_names/eval_var_ref overlay、with-binding、跨 realm 词法可见性（syncFrameVarRefMirror）。
  da34bc1 用镜像修过 8 回归（1 跨 realm 重赋写穿 + 6 for-of/for-in TDZ + 1 eval-delete）。**编译器+linker+frame 多处侵入**，
  必 flag-gated 分阶段、每阶段 0/49775（parser-align 7 回归是前车之鉴）。保 PASS1-check-before-PASS2-create 序、`var_ref_is_global_decl[idx]` 门控。

### C.2 builtin 方法上 prototype（method_call_loop 7.06×、array_push 1.69×）
- 每个 builtin 方法物化为各 prototype 对象的**真 own-property**（匹配 qjs 结构）→ fast path 在 receiver 自有链上够得着。
- **高侵入**（碰 builtin 注册、非 fast path）。**不**单独解 null-proto 内部数组（createArray(rt,null) 的 rest-param/regexp-split/iterator-result，
  vm_property_field.zig:335-342、commit decd0288）的 by-class-name 回退——那需每个 builtin prototype 在 receiver 自有链可达 **且** null-proto 数组有链。
  与 null-proto-array 问题一并解或留 do_not_align 直到解决。

### C.3 array count/length 拆分
- 撤 zjs 的 `array_count` 同时是 .length 和 dense 上界的融合（object.zig:1143-1145）→ qjs 尾部虚 hole 表示（dense-count + 独立 length）。
- **逐 reader 审计**：arrayLength/arrayElements/isFastArrayIndexInBounds/setArrayLength —— [count,length) 读为 hole（undefined、
  hasProperty/for-in/Object.keys 缺席）。**任一 reader 漏处理 = hole 语义 test262 回归**。

## 验收

- 每项：`0/49775` default + nan_boxing + 结构对照 quickjs.c:N；碰 refcount 的项加 force-GC。
- C 类大杠杆：flag-gated、分阶段、每阶段全门。
- 反作弊：性能只相边界 sanity，永不作单项去留偏离的理由。
