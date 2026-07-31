# P7-51A：no-op property-redefinition 事件普查

- 日期：2026-07-30
- 基线：`fed6948a`
- 性质：**只计数**。临时插桩已还原，`git diff fed6948a -- src/` 为空
- 目的：决定 same-flags shape-uniquing 这一刀**是否排在 P7-41 桥接税之前**。不是重新验证该机制是否正确
- 数据产物：`P7-51A-results.json`

## 裁决

> **defer** —— 这刀仍是正当的 QuickJS 忠实对齐清理，但**不是当前最大项**。
> 先做 **P7-42：builtin→JS bridge phase attribution**。

四条「立即优先」门槛**逐条未达成**：

| 门槛 | 结果 | 依据 |
|---|---|---|
| 至少两个互不相关 workload 出现 | **否** | 两个高计数条目是**同一个** P7-50 合成 NamedEvaluation 形态 |
| 某 Pareto case 解释 ≥10% cycles | **否** | `arrow_call_loop` 20 万次迭代**只有 1 次**事件 |
| 代表性语料绝对总贡献 > builtin bridge | **否** | 去掉合成形态后，170 个条目合计**仅 6 次** |
| NamedEvaluation 之外有高频同形路径 | **否** | var-ref 分支在**全语料 0 次** |

## 两处规格更正（在计数之前就必须修正，否则会数到不存在的桶）

**一、桶 B「unique hashed + same flags → `removeShapeHash`」在这条路径上结构性不存在。**

`replaceProperty` 调用的是 `Object.ensureUniqueShapeForMutation`（`object.zig:11309`），它**不是**
`shape.Registry.prepareUpdate`（`shape.zig:420`）。前者没有 unhash 臂：

```zig
fn ensureUniqueShapeForMutation(self: *Object, rt: *JSRuntime) !void {
    if (!self.shapeNeedsMutationCopy()) return;   // refCount() == 1 → 直接早退
    const next_shape = try rt.shapes.cloneForMutation(self.shape_ref);
    ...
}
```

`prepareUpdate` 才有 `is_hashed and rc == 1 → removeShapeHash` 那一段，但它在别的调用点上。
所以这条路径只可能落进桶 A（shape 共享 → 整体 clone）或桶 C（`rc == 1` → 早退）。

**二、这一刀的第二个门（gate `updatePropertyFlags`）是冗余的**，虽然无害。
`shape.Registry.updatePropertyFlags`（`shape.zig:578`）已经自带 same-flags 早退：

```zig
if (shape.props()[index].flags == flags) return;
```

因此 `replaceProperty` 在 same-flags 情况下**唯一**真正可避免的工作，就是
`ensureUniqueShapeForMutation` 在 shape 共享时那次整体 Shape clone + destroy。

## 语料与计数

173 个条目，每个独立进程跑一次，计数由临时计数器在进程退出时打到 stderr。
**只计数、不计时，因此未占用独占测量锁。**

覆盖：P7-50 的 `g = arrow` / `slot[0] = arrow` 对照、bootstrap、75 个 microbench case
（源码从 `tools/compare/microbench_cases.js` 抽出为独立文件）、P7-50 完整闭包矩阵、
P7-41 的七个 Array builtin workload、same-runtime P0 sentinel、以及 `gbemu`。

var-ref 分支的比较目标按规格用 `next_flags.withKind(.var_ref).bits()`，而非未修正的 `next_flags.bits()`。

## 结果

全语料桶汇总：

| 桶 | 次数 |
|---|---|
| `replaceProperty` 总调用 | 40 594 |
| flags 真变化 | 519 |
| flags 未变 | 40 075（**98.7%**）|
| flags 未变 **且 shape 共享**（可避免 clone） | **40 075** |
| flags 未变且 `rc == 1`（已早退，近免费） | **0** |
| var-ref 分支总计 | **0** |

flags 未变时 shape **总是**共享（40075/40075）—— 与函数对象 shape 被 hash-cons 共享一致。
桶 C 在本语料中一次都没出现。

**但可避免事件几乎全部来自合成形态**：

| 条目 | 可避免次数 |
|---|---|
| `named_eval_assign`（P7-50 合成） | 20 000 |
| `closure_identtarget_nocap_churn`（P7-50 合成） | 20 000 |
| `closure_identity_probe`（P7-50 合成） | 69 |
| `arrow_call_loop`、`arrow_tail_recursion`、`method_call_loop`、`closure_reuse_*`、`closure_identtarget_reuse_churn` | 各 **1** |
| 其余 164 个条目 | **0** |

合成形态占 **40 069 / 40 075 = 99.99%**。其余 170 个条目合计 **6 次**，单条最大 **1 次** ——
那是每进程一次的常量，不是逐迭代成本。

**唯一的产品型负载 `gbemu`：整轮 21 次**，按最贵的 A 类 423.6 cyc/event 计约 **8.9k cycles 全程**。
作为量级参照，P7-41 的桥接税是 27.43 cyc/callback；只要 gbemu 有 10 万次 builtin callback，
桥接侧就是 **2.74M cycles**，相差两个数量级以上。

## 为什么「15 个静态调用点」没能兑现成动态覆盖面

上一轮我从 `ensureUniqueShapeForMutation` 在 `object.zig` 有 15 个调用点，推测该机制「通用」。
普查否证了这个推测：**`replaceProperty` 本身在真实负载里是冷的**。40 594 次总调用中有
40 006 次来自两个合成 case；其余 171 个条目合计只有 588 次调用。其他 14 个调用点走的是
定义、删除、原型替换等路径，不在本刀范围内，本普查也没有统计它们。

这正是「先计数再下刀」的价值：机制方向是对的（且与 `qjs:10332` 的门控不一致这一点已核验），
但**它当前不构成主线最大项**。

## 不外推单事件成本

按三类分别处理，未把 423.6 cycles 乘到所有事件上：

- **A：shared shape + same flags** —— 唯一实际出现的类。成本取 P7-50 在 NamedEvaluation 上的
  实测 423.6 cyc/event，这也是最贵的形态。
- **B：unique hashed + same flags** —— **结构性不存在**（见规格更正一），无需单独测量。
- **C：unique unhashed + same flags** —— 全语料 **0 次**；即便出现也只剩一次早退的函数调用，
  且 `updatePropertyFlags` 已自带早退，成本接近零。

## 这刀的形状（已预批准，保留待 P7-42 之后）

结论不改变实现方向，只改变排期。按普查结果，实际只需要在两处分支各自局部门控
`ensureUniqueShapeForMutation`；第二个门（`updatePropertyFlags`）可省，因为它已自带早退 ——
但保留它也无害，且能让意图在阅读时自明。

## 本条线没有做的事

- **没有**测量另外 14 个 `ensureUniqueShapeForMutation` 调用点。本普查只统计 `replaceProperty`。
  若其中某个调用点在真实负载里是热的，那是**另一条线**，不能用本普查的结论代替。
- **没有**跑完整 test262 计数（按约定不需要），因此不能声称覆盖了所有语言形态。
  真实代码里 `f = function(){}` / `f = () => {}` 的 NamedEvaluation 用法在本语料中罕见，
  但本语料以合成基准为主，**不能据此断言真实应用中也罕见**。
- **没有**做任何性能采样。A 类的 423.6 cyc/event 是引用 P7-50 的实测值，不是本线复测的。
- 临时插桩（`src/core/redefine_census.zig` 与 `replaceProperty` 两处 `record` 调用）已全部还原。
