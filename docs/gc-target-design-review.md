# GC 后续设计边界

2026-09-21 确认的方向保留如下；这是目标，不是当前实现清单。
当前收集器契约见 [GC invariants](gc-invariants.md)，Runtime 所有权见
[Runtime 设计](runtime-target-design.md)。实施前差距、阶段交付、行数估计
和已退役的性能门槛留在 Git 历史，不再作为当前施工依据。

## 目标

> T1 精确 tracing
> T2 年轻代单区 bump + STW copying
> T3 老区不搬的 mark-sweep（碎了再 compact）
> T4 根只有 VM 栈槽、HandleScope 槽和 Persistent
> T5 生产不扫原生栈
> T6 leaf builtin 靠 `Effect.may_alloc=false` 用裸指针，其余跨 GC 进槽
> T7 不增量
> T8 不上 Immix
> T9 堆不当 Allocator

## 当前工作边界

nursery 的阻塞、正确性验证和启用决策统一记录在
[nursery 评估](runtime-nursery-todo.md)。默认关闭不证明启用路径正确。
保守扫描的移除、内部 effect 标注和 compact 必须分别验证；不能由目标
文字推定已经实现，也不能因精简文档删除现有 GC 安全网。

## 移动式收集的诊断方法

- 检查疏散后的活 owner 是否仍持有 nursery 地址；不要把死 owner 的旧边当缺根。
- 调试时毒化 from-space，使旧指针尽量在使用现场失败。
- 在定向复现中降低收集阈值，放大跨 GC 的根窗口。
- 按第一个引擎源码帧归类失败，再用定向回归验证一般机制。

正确性、预算和 OOM 处理成立后才评估性能。验证义务只由
[验证政策](verification-policy.md)定义，不恢复历史 Octane 比率门槛。
