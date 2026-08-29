# VM 值表示契约(engine plan × tracing GC 同步点)

Version: 2
Date: 2026-08-26
v2(2026-08-26,FN-M0F 冻结同 commit):①§1.1「plugin ABI fingerprint
不变」承诺按 2026-08-25 裁决过渡为 FNABI ABI tuple;②新增
**layout_epoch = 1**——`FUN_VALUE_ABI` 的第一分量,只在真实表示
变化(布局/tag 语义/地址稳定性)时递增,与本文档版号解耦(编辑性
修版不构成 ABI 事件)。v2 不改变任何布局或语义承诺。
v1: 2026-08-24 初版。
Status: normative — 本契约是
[engine-evolution-plan.md](engine-evolution-plan.md)(§3.1 裁决 A 的
"表示定型"里程碑)与 [tracing-gc-design.md](tracing-gc-design.md) 两线
的共同约束面。**修改本页所述协议 = 先改本契约并递增版本号,再动任一线
代码。**

来源:全部条款自 `gc/tracing` 分支实物导出(tip `5bc8373b`,
2026-08-24),非设计意向。引用文件:`src/core/gc_slot.zig`、
`src/core/gc_concurrent.zig`、`src/core/gc_conservative.zig`、
`src/core/gc_trace_stw.zig`(均为分支路径)。

## Errata(2026-08-25,登记欠账;条款本体未修订)

- **导出锚点已过期**:`gc/tracing` 分支自 `5bc8373b` 起又推进 35
  commits(tip `756a1d07`),含 conservative-root 机制重写
  (`9e62e098`)与 collector policy 修正(`f10855c6`)。本契约按
  2026-08-24 冻结快照读;与分支现物的偏差以本节为准。
- **§4"页 radix 地址注册表"机制已被分支取代**:`9e62e098` 改为
  arena-geometry 验证(per-object registration 移除,注册表仅剩
  standalone-prefix 残余用途)。"候选永不解引用"不变量仍成立;
  机制描述待契约修订。
- **§4 conservative_on forcing function 描述与分支代码不符**:现行
  定义(gc_trace_stw.zig:435)为
  `if (!builtin.is_test) !rt.gc.host_quiescent else (rt.test_root_scan_override orelse scan) == .engine_active`
  ——forcing function 仅适用于 host-quiescent 触发;engine-active
  扫描在测试态**开启** conservative(精确模式在该场景被证不
  sound)。
- ~~§1.1"plugin ABI fingerprint 不变"承诺将过渡~~:**已于 v2
  (2026-08-26,FN-M0F 冻结同 commit)执行**——§1.1 现行文即
  FNABI ABI tuple 承诺,第一分量为 layout_epoch(现值 1,与文档
  版号解耦)。

---

## 1. 三条硬承诺(引擎线可以直接依赖)

1. **`JSValue` 16 字节 extern tagged 布局不变**;`property.Slot` 布局
   不变;对插件的表示承诺以 **FNABI ABI tuple** 表达(v2 过渡,
   2026-08-26:`FUN_VALUE_ABI` = (`layout_epoch`,
   `JSValue.abi_encoding_revision`),layout_epoch 现值 **1**,见
   [fun-native-plugin-design.md](fun-native-plugin-design.md) §11.3;
   旧「plugin ABI fingerprint 不变」承诺随 runtime-plugin-abi 退役
   过渡至此)。Slot 是**既有字段之上的突变协议,
   不是新的 16 字节表示**(gc_slot.zig 头注)。
2. **非搬移(non-moving)**:sticky-mark-bit 分代,无 copy/compaction,
   地址稳定性是设计保证(tracing-gc-design.md :58/:848/:897)。
   缓存的对象/shape 指针**永不因 GC 失效于地址**——但生命周期不在
   承诺内(见 §5.2)。
3. **默认 `rc` 构建零痕迹**:gc_slot 模块在默认构建被擦除
   (production `.text` 无 gc_slot 符号);tracing 仅经显式
   `-Dzjs_experimental_gc=trace_stw` 门可达,RC 是 shipped default
   (Stage 7 记录)。

## 2. 堆边突变协议(Slot)

所有堆内 JSValue / header 引用字段的强写走统一序:

```text
retain-new(调用方 dup,即 Slot 的 retain 步)
  → publish(slot.* = new)
  → release-old
```

入口类型:`HeapValueSlot.setOptionalOwned` 等(gc_slot.zig);bulk
copy/move/resize/destruction 有成对入口。写审计(gc_write_audit)在
测试/shadow 构建下计数每一次 Slot 写,覆盖面:tag transition、A→B
覆盖、置 null、same-value、bulk copy/move、destruction、RC 序
(tracing-gc-design.md :1360)。**绕过 Slot 入口直写堆引用字段 =
契约违规**,shadow 边审计与写审计是检出机制。

## 3. 屏障形状(Stage 6 实物,即 engine plan §12.2 的挂钩位)

- **incremental-update,shade exact new target**:只染新目标,不读
  owner 颜色、无 owner-rescan 位(代价=可能保活一轮 floating
  garbage,换取 store 侧零 owner 状态开销);
- 调用点:publish **之后** `postWriteBarrier(owner,
  decodeExactHeapRef(new_value))`;retain-new 在 publish 前,不需要
  屏障;
- **正确性配对**:heap store 与 shading 在同一 `BarrierCriticalScope`
  (RAII 对)内,mutator 在 scope 内不得 ack safepoint——final remark
  因此不可能停在 store 与 shading 之间(唯一能藏引用的交错);
- RC 权威期该挂钩为空;JIT/asm 侧预留 patchable 位即对应此签名。

## 4. 根模型

- **conservative native roots 是生产设计**:原生栈按机器字扫描,候选
  **永不解引用**,经页 radix 地址注册表验证(header/metadata 前缀/
  interior/one-past-end 才算根)。已实现 ABI:AArch64-Linux
  (AAPCS64);x86_64-linux/windows、aarch64-windows/macos 在显式
  未实现清单(gc_conservative.zig);
- **ValueRootFrame 精确根帧在测试态强制**:
  `conservative_on = !builtin.is_test`(gc_trace_stw.zig:288)是
  刻意的 forcing function——测试以精确模式运行,漏挂根帧的代码路径
  会以 SEGV 形式暴露,conservative 不得在测试态打开去掩盖它;
- 推论:**任何新增的"原生代码持 rc 引用跨可 GC 点"路径,必须挂
  ValueRootFrame**(或等价 rooted 传递),否则 trace_stw 单测门必红。

## 5. 对 engine plan 各阶段的约束落点

### 5.1 Phase 0(VmExecState / HelperDescriptor)

ABI 只含指针与出口协议,不编码值内部;`can_gc` helper 边界 =
publish seam = 本契约 §4 的可观察点。与本契约无冲突,可并行。

### 5.2 Phase 0.5(反馈槽)—— 高危约束

- 槽内缓存的 shape 指针 / callee identity 是**非持有引用**:§1.2 保
  地址不保生命周期,RC 立即释放与 tracing 延迟回收下都存在
  dangling/ABA(在册前科:M2 资格链缓存因同址重分配 ABA 判不
  sound)。**槽命中必须经版本/纪元验证后才可解引用或比较**;
- 反馈槽 side table **登记为"非 GC 边"**:shadow tracer 边审计须知道
  它存在且刻意不追踪,否则完整性审计出现无法解释的存活/悬挂差异;
- 失效钩子(shape transition / free)与版本号的选择,须与 GC 线同桌
  评审一次成文。

### 5.3 Phase 2(baseline JIT)

- **值移动经抽象层发射**:RC 权威期发射 inline rc inc/dec(§2 的
  retain/release 步);tracing 权威后同一抽象层换发屏障序(§3)。
  emitter 直接硬编码 RC 序 = 契约违规;
- 堆写发射点预留 `postWriteBarrier` 挂钩(nop sled / 恒跳 stub 槽),
  签名对齐 §3;RC 期为空;
- JIT native 帧的 GC 正确性由 §4 conservative 扫描覆盖(无需精确
  stack map 才正确);safepoint metadata 仍从 v0 记录(优化项与
  时延项,非正确性项);
- `BarrierCriticalScope` 语义对 JIT 代码同样成立:store+shade 序列
  内不得含 safepoint poll。

### 5.4 Phase 1-Z / 1A(解释器骨架,条件项)

值移动生成宏(engine plan §7.4)对接 §2 同一协议:宏产出 RC 序或
屏障序由构建配置选择,handler 文本不变。

## 6. 未决项(本契约不覆盖,谁先碰谁立项)

- 分代/并发 major 的启动接线(marker worker 未被启动、子枚举未搬移、
  block heap 不能供 GC 节点——Stage 7 拒绝生产默认的三个已命名
  原因):不改变本契约任何条款,只改变 §3 屏障从"存在"到"启用"的
  时点;
- conservative 未实现 ABI 清单(§4)与平台矩阵(engine plan §3.2)
  的交集:aarch64-macos/iOS 上 conservative 扫描器落地属 GC 线工作,
  iOS 排期开启前须补;
- 弱引用/finalizer 与反馈槽失效钩子的统一注册表(Phase 3 dependency
  registry 的 GC 侧对应物)。
