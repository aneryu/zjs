# M 切换 r2：Object 64B 终态布局规格（driver 设计，2026-09-02）

状态：**规格冻结，交 codex 按此实现**。上级文档：`docs/gc-v2-final-cut-driver-review-2026-09-02.md`（路径 M）。
背景：M 首轮（gc/m-cut-20260902@4a455534）用「方案 A：implicit prop_values + weakref_count bit30 spill 判别」到 64B，
把布局判别（load 状态字 + 2 分支）带进了全部对象的属性路径（getOwnDataPropertyValue 50→66、append 416→505）。
本规格改用**方案 B′：保留 base 的常驻 `prop_values` 指针（所有对象单 load、spill=改指针、无判别位），
slots2 对象省掉 8B class-payload arm**。属性机器与 base 逐字相同，只有 slots2 的 arm 迁到稀疏侧表。

## 1. 布局（以 Object 指针为 0；`Metadata` 8B 在 −8，不变）

| offset | 字段 | 所有对象 |
|---:|---|---|
| 0 | `weakref_count: u32`（bit31 = slots2 布局位，与 base 相同；**删除 bit30 spill 位**，低 31 位计数） | 是 |
| 4 | `class_id: u16` | 是 |
| 6 | `flags: ObjectFlags` | 是 |
| 8 | `shape_ref: *Shape`（parked 尸体链落点 = 本字，已定） | 是 |
| 16 | `prop_values: [*]Entry`（**常驻，base 语义**） | 是 |
| 24 | 非 slots2：`storage: ObjectStorage`（narrow 8 / wide 24）；**slots2：`Entry[2]` 32B，无 arm** | 按布局 |

尺寸：narrow 非 slots2 = 32 → cell 40→48 class；wide = 48 → 56→64 class；**slots2 = 24+32 = 56 → +8 = 64 class**。
`objectTailBytes(class_id, slots2) = if (slots2) trailing_property_bytes else unionArmBytes(class_id)`，
comptime 断言 `slots2 ⇒ class_id == ids.object`。`trailingPropertyStorageBase(self) = self + 24`。

## 2. 属性存储：与 base 逐字相同

- 创建（`createPlainObjectReserved2`/`newPlainObjectReserved2Value`）：`prop_values = trailingPropertyStorageBase(self)`；
  非 slots2：`emptyPropertyStorageBase()`/外部 buffer，同 base。
- spill：容量超过 2 时分配外部 buffer、拷贝、**改 `prop_values` 指针**；OOM 时保持 inline——即 base 现有逻辑。
- 析构：`prop_values != trailingPropertyStorageBase(self)` ⇒ 释放外部 buffer——base 现有逻辑。
- **删除**：`property_storage_spilled_bit`、`propertyStorageIsSpilled`、`propertyStorageSpillBitForAudit`、
  `slots2ExternalPropertyPointer`、`propertyStorageBase` 的双表示分派、spill-bit 相关 representation audit 与 mutant 2/3。
- 验收（反汇编，逐符号）：`getOwnDataPropertyValue`/`getOwnProperty`/`findProperty`/`definePlainDataPropertyKnownFast`/
  `setOwnWritableDataProperty`/`appendPreparedPropertyEntry`/`createPlainObject`/`createInternal` 的指令数、load、branch、call
  数**不得高于 base**（属性路径 diff 应为空或仅 offset 常量变化）。`createPlainObjectReserved2` 比 base 少 1 store（无 arm 置零）。

## 3. slots2 的 class payload：稀疏侧表

- 触发点唯一：`ensureOrdinaryPayload`（懒挂 `OrdinaryPayload`，冷特性）。全局对象/realm record（`.global`/`.realm_record`）
  从不是 slots2（创建路径不同，加断言）。
- 新增 `JSRuntime.slots2_payloads: std.AutoHashMapUnmanaged(*Object, class.Payload)`（no-fail 读；插入可失败，与
  `createRuntime(OrdinaryPayload)` 同一错误路径）。
- 访问器分层：
  - `payloadArm(self)`：保持现签名；**加 debug 断言 `!hasSlots2Layout()`**。87 个调用点里凡是 class 固定为非 `ids.object`
    的（array/function/regexp/typed array/…）天然满足。
  - 新 `payloadSlot(self, rt) *?class.Payload`：`if (hasSlots2Layout()) sideSlot(rt, self) else &storage.payload`；只用于
    可在 `ids.object` 上运行的站点：`ordinaryPayload()`、`ensureOrdinaryPayload`、`freeClassPayloadAllocation`（析构）、
    trace（若 `OrdinaryPayload` 含 traced 引用则 trace 路径先看 `class_payload_kind != .none` 再取 slot——冷分支）。
  - 站点普查方法：断言先行 + `zig build test` + test262 触发；凡命中断言的站点改用 `payloadSlot`。
- 生命周期：析构（`destroyPlainObjectFast`、deinit hold 释放、weak-husk 收尾）在 raw free 前 `remove` 侧表项并释放 payload；
  侧表项不构成 GC 根（payload 归对象所有，对象死则同死）。arena-audit/owned-allocation verifier 加一条：侧表键必须全为
  published 或 owned slots2 对象（无悬空键）。
- Stage 0 加计数器 `slots2_payload_attach`（六负载预期 0 或极小；非零则报告占比）。

## 4. 不变项（沿用 M 首轮已落地部分）
Object 删 `header` 字段、`bodyOffsetFromHeader(.object)=0`、`nextNonObject` 门控、parked 链落 `shape_ref` 字（body+8）、
`snapshotYoungDoomed` + `recordDoomedBlock(origin=.minor)` 不进 hot-reuse（411be1cc）、NonBlockObjectAuthority 三向量、
config 签名 v3、mutant 1/4。**新 mutant**：(a) slots2 对象走 `storage.payload` 被断言捕获；(b) 析构漏删侧表项被 verifier 捕获。

## 5. 验收（按 docs/verification-policy.md 分级金字塔）
Stage 0：六负载 insn/cycles ≤+0.5%，gc-stats 七指标对 base ±10%（R-B 已应使 hot reuse/reopened/deferred runs 回到 base 量级）；
反汇编逐符号 ≤ base。→ Stage 1/2 → Stage 3 正式 1×1（擦线才 2×2）。GO 线：六负载 cycles(u+k) ≤1.003、splay 期望 <1。

## 6. 计账规则（driver 增补，2026-09-02 19:20，来自 R-A Stage 0：EB/deltablue major −23~30%、committed +20~24%）

根因：base 的 Object 计账 = `@sizeOf(Object)(32)+tail`，narrow 为 40（不含 8B `Metadata` 前缀），物理 cell 48；删 `next` 后
`@sizeOf(Object)=24`，计账变 32——每 Object 少计 8B，而 VarRef/Shape 等不变，按字节触发的 major 每周期多放行 ~20% 对象，
浮动垃圾↑、committed↑、cache-miss↑（deltablue +16%）。这是表示切换夹带的节奏变化，必须消除。

**终态规则**：块 cell 中的 Object，`allocationSize` / `heapByteSizeFromHeader` / `bodyBytes` 用于计账时一律返回
**`block.cell_size − gc.metadata_prefix_size`**（物理 body 容量；O(1) 取自块头，`isBlockCellHeader` 分派）。
效果：narrow 48−8=**40**、wide 64−8=**56**——与 base 逐字相同，非 slots2 负载 major/minor 节奏零漂移；slots2 64−8=**56**
（base 72）——密度收益如实进计账。非块（standalone）Object 与其他 kind 计账不变。注册/注销对称（`registerObjectWithBytes`/
`unregisterObjectWithBytes` 同一函数取值）。`heap_live_bytes` 公共语义对非 slots2 程序与 base 数值一致（O3 不变）。
禁止用「逻辑字节 +8」之类常量修补。验收：Stage 0 生命周期表中 deltablue/EB/pdfjs 的 major 次数与 committed 回到 base ±5%。

## 7. 计账实现修正（driver 增补，2026-09-02 20:50，来自 ACCT Stage 0 的 EB insn +0.69% 指令级符号差分）

差分（`perf record -e instructions:u`，base vs 886960eb）：`MemoryAccount.allocInternal` +183、`MemoryAccount.destroy`+`destroyFromHeader`+
`destroyFromHeaderSlow` +143（扣除 `destroyConstFam` 改名 −226 后仍净增）、`Registry.addInitializedWithSize` 0→147（被外提为独立符号）、
`drainCycleDeferredFreesBudgeted` +123；`destroyCondemned` −118/`sweepUnmarkedYoung` +55 净赢。

根因：§6 的实现 `blockObjectAccountedPayload(cell)` = `Block.fromCellTrusted(cell).cell_size − prefix`，在**每次分配 credit、释放 debit、
析构 bodyBytes** 时读块头。base 的字节数是 `objectTailBytes(class_id, slots2)` 的表算术，不碰内存。释放/析构侧读的是死对象所属块头
（冷行）→ deltablue/raytrace 的 cycles 高于 insn 由此而来。

**修正规则（语义不变，只改求值方式）**：`cell_size − prefix` ≡ `roundUpToBlockClass(prefix + @sizeOf(Object) + objectTailBytes(class_id, slots2)) − prefix`。
1. 固定构造（`createObjectConstFam*`）：credit 用 comptime 值（已有 `accountedBodyBytesForRequest` 纯函数），删运行时块头读与断言
   （断言移入单测：对三类 block Object 校验 comptime 值 == 实际 cell_size − prefix）。
2. 动态构造（`createObjectWithFam*`）：`accountedBodyBytesForRequest(prefix + payload)` 纯算术（class 取整表/位运算），不读块头。
3. 释放/析构/`allocationSize`/`bodyBytes`/`heapByteSizeFromHeader`：`objectTailBytes(class_id, hasSlots2Layout())` → 同一取整函数；
   不再 `Block.fromCellTrusted`。standalone 路径不变。
4. `addInitializedWithSize` 恢复 `inline`（或查明外提原因并消除）；发布路径反汇编相对 base 不得新增 call。
5. `deferredLinkSlot` 的 kind 分派（+123）接受为终态成本（Object 尸体链 body+8 与 legacy `next` 偏移不同，census/weak-husk 需要
   word 0 存活，不可统一到偏移 0）；报告中单列其占比。
验收：EB insn ≤ +0.3%（Stage 0，samples 2）、deltablue/raytrace cycles 不高于 insn 比值 +0.3pp；逐符号 allocInternal/destroy*/destroyFromHeader
回到 base ±5 指令。
