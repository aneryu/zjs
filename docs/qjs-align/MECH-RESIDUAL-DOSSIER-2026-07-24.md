# 残差机制档案（2026-07-24）

回归修复战役（post_inc/poll/TDZ/class-plan/leaf-pricing 七提交）收口后的机制级残差
归因。测量：CPU19 绑核，armv8 pmu instructions，双引擎同脚本 perf record，
symbol% × 每迭代总量折算。qjs 冻结尺 `b76d1542…`。

## 残差机制矩阵

| # | 机制 | zjs insn/iter | qjs 对照 | 覆盖面 |
|---|---|---:|---|---|
| M1 | 调用 teardown/预算记账 | op_return 197 + opCall 148（e73e8a0c 时 106+121） | call+return 全链 ~238；预算=原生 sp 本身，零记账 | 全部调用形态 |
| M2 | VM-helper 帧化传输 | for-of: completeForOfNextContinuation 269 + varRefVm 族 ~120 | 无此层（JS_CallInternal 局部变量） | for-of、冷路径 |
| M3 | GC 注册 | registerObjectWithBytes 72 | add_gc_object = 2 store + list_add（quickjs.c:6540-6546） | 每次对象分配 |
| M4 | property 发布 | adoptShapeForNewProperty 246 + addPropertyTrusted 90 + define_field 80 | add_property 全链 ~184 + Create/Define ~51 | objlit/属性写负载 |
| M5 | MemoryAccount 包装 | objlit 上 memory.* 4 实例化 ~362 | __js_malloc+__js_free ~185 | 全部分配 |

## M1 —— 已部分处置（78914bbc），第二片待布局实验

根因：W-train 用字节计数器 `rt.active_bytecode_stack_bytes` 模拟 qjs 的原生 sp
距离检查，进出两侧各重算一次 `qjsBytecodeFrameAllocaSize`（3×ldrh + argc/copy_argv
pricing select）。第一片已落地：进入侧 Bytes API 去双算 + 零参叶退账坍缩为函数头
标量（发布几何：empty/capture 恒 arg_count==0、exact 恒 argc==arg_count、
padded 与 exact 共用 teardown 位必须保留 argc 感知、forwarded 带 copy_argv=true
但零参下数值等价——三个 release 点已用 Debug assert 编码）。

第二片：Entry 增 `planned_stack_bytes: u32` 做水位保存/恢复，彻底消掉退账依赖
链与寄存器压力（op_return 热臂现有 6 组 stp spill）。被 256B comptime 布局断言
拦下（264B）；需要带 closure/negative-control 探针的交错 A/B（240B 布局有回退
前科，见 inline_calls.zig `_stride_padding` 注释）。

## M4 —— 结构性发现：shape FAM 布局与链摘要缓存（最大机制杠杆）

qjs 机制（quickjs.c:5533-5563 find_hashed_shape_prop + shape 布局）：

1. **链摘要缓存在 shape 里**（`h = sh->hash`），追加 (atom, flags) 两次乘法即得
   桶号；探测环先比 `sh1->hash == h` —— 一条 w 比较拒绝几乎全部候选。
2. **prop_hash FAM 在结构体负偏移侧**（`prop_hash_end[-i-1]`，分配后返回内部
   指针），`get_shape_prop(sh) = (JSShapeProperty*)(sh+1)` 是常量偏移。

zjs 现状（adoptShapeForNewProperty 反汇编 0x1077920-0x1077998）：hash 表 FAM 在
正侧且变长，**每候选验证要 5 字段比较 + `size*4+4 else 0` csel 链推导 props 基址
+ ldp 末属性 + lsr#26 位段抽取**——该依赖链即 29.4%+12.8% 采样热点；且所有
shapeProps() 访问点（查找、遍历、define）都在付同一笔基址推导税。

机制刀（独立战役规模）：镜像 qjs 负偏移布局——分配 `[prop_hash FAM][Shape][props FAM]`
返回内部指针，props 恒定偏移；影响面=shape.zig 分配/释放/克隆/rehash、GC header
内嵌（@fieldParentPtr 与 destroyFromHeader 的基址恢复，qjs get_alloc_from_shape
同款）、全部 FAM 访问点。门禁必须含 force-GC + ReleaseSafe + test262 全量。
预期受益：objlit 家族（现 1.75-1.83x）、objprop（1.20x）、propread（1.08x）与
所有属性写路径。

## M3 —— GC 注册增量清单（中杠杆，pacing 语义需裁决）

zjs registerObjectWithBytes 相对 qjs add_gc_object 的每分配额外项：
`isLargeAllocation` 判别、`size_class` 编码分支（metadata_in_slab 门）、
`heap_accounted` 位、`recordSpaceAlloc`（GC-D2 后已是单标量 bump）、
**`hasPendingMajorRequest()+pollGC` 每分配轮询**。最后一项 qjs 没有对应物
（qjs pacing 只在分配前 js_trigger_gc = zjs collectBeforeObjectAllocation 已
镜像）；若将 post-register 轮询并入下一次 pre-alloc 检查即 qjs 同构，但 pacing
点位移 ≤1 次分配，对 force-GC/checkpoint 门禁与 GC 阈值边界测试（74f4f988）
可观察——动刀前需先裁决语义等价性。

## M2/M5 —— 待深挖

M2 = A0 矩阵的横切根因（帧化传输 + q-spill），方向裁决为同链帧切换 supernode
（出簇先行，见 CALL-SUPERNODE-PLAN.md）；for-of 最大受益。M5 与 M3 部分同源
（分配记账层），在 M3 裁决后一并复查。

## 建议次序

M4（shape 布局战役，最大机制杠杆）→ M1 第二片（264B 布局实验，call 家族收口）
→ M3（pacing 裁决后的注册瘦身）→ M2（supernode）。
