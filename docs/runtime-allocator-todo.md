# Runtime 默认 allocator：决策与剩余实验

Status: 2026-09-23，D1/F1 已完成：A9 前后均完成 c/smp 比较，默认 c_allocator 已落地；额外实验保留 TODO

所属设计：[Runtime 内存职责与交付边界](runtime-target-design.md)。

用户于 2026-09-21 要求记录待办，后续对比 `std.heap.c_allocator` 与
`std.heap.smp_allocator` 的性能。随后已开展测量，结果见下文。

## 比较范围

- 执行耗时、吞吐，以及分配密集负载的表现。
- 内存峰值，以及大型脚本结束、Runtime 销毁后的内存回落。
- 短命 CLI、长期运行并反复创建销毁 Runtime、多 Runtime 并发场景。
- 明确 Zig 版本、平台/libc、实际经过候选 allocator 的分配范围；内部绕过路径
  需列明，不能把仅替换入口 allocator 的结果当成整个引擎的全量替换结果。
- 普通原生小分配直接使用候选 allocator，与额外经过 SmallObjectSlab 的方案比较。
  普通原生默认直接分配，GC 专用 slab 保留；所有权见 [Runtime 设计](runtime-target-design.md#6-为什么保留这些现有机制)。
  比较应保留 GC 所依赖的存储路径，避免将 GC 存储变化混入普通分配的结果。

## 决策边界

A9 后复测支持选择 c_allocator 作为默认值，依据是本机长期及并发负载较低的销毁后 RSS；耗时区间重叠，不声称普遍速度优势。Runtime.create(.{}) 已采用此默认值，显式 allocator 仍可覆盖。
已确定保留可选宿主 allocator、引擎提供默认值、Runtime 使用单一 create 入口。
以当前验证政策为准；本轮测量依据用户继续完成剩余工作的授权执行。

## 本轮测量与明确剩余项

完整条件、范围、原始样本及中位数见 [测量记录](runtime-review/allocator-2026-09-22/README.md)。

- [x] c/smp 的反复创建销毁、长期重复 eval、四 Runtime 并发场景。
- [x] 记录耗时、采样 RSS 峰值、销毁后 RSS 与二进制/源码身份。
- [x] A9 后复跑 24 个样本，记录最终源码/二进制身份；F1 已安装默认 allocator。
- [ ] 普通小分配直接分配与额外 slab 的独立 A/B；不作为恢复通用 slab 的理由。
- [ ] 更长 idle 回落及其他平台的代表性负载，当前没有这些结论。
