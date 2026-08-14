# PERF-MECHANISM 偏离账本

依据：**通用性原则**（PARITY-LEDGER 宪法，2026-08-14 用户裁定）。
本账本登记「QuickJS 没有、但按通用性原则允许」的引擎机制。
准入四条件（每条目必须逐条核证）：
1. **通用**：对同类全部形态一致适用，无形态特判、无悬崖；
2. **用户代码照常执行**：不跳过任何语义步骤（工作量绕过仍然禁止）；
3. **可观察等价**：difftest 面 + test262 + 异常栈/枚举序探针逐项证明；
4. **zoo 验收**：3-pad lineage 逐基准判读，四资产不回退。

---

## `constructor-allocation-profile`（PROPOSED，R10）

```
参照:      JSC op_create_this + ObjectAllocationProfile（V8 slack tracking /
           SpiderMonkey template object 同族）
形态:      构造函数携带「实例初始 shape + 槽容量」画像；`new` 按画像预留容量分配、
           取缓存初始 shape；构造体照常执行，字段写走正常 shape 转换
           （zjs 的转换查找已镜像 qjs shape-hash，二次实例天然命中）；
           预测失配走原路径并重新学习——无悬崖
通用性:    适用于一切构造器（含 G 形 apply 转发、含逻辑体），无模式匹配
等价面:    容量预留不可观察；shape 转换序列不变；枚举顺序不变；
           待证：GC 在部分初始化窗口的扫描、Proxy/异常中途逃逸
配套:      与 classifySimpleFieldConstructor 全套删除同批落地（R10「删特化上通用」），
           包级 zoo 验收不下凹
状态:      PROPOSED——等 R9（真帧瘦身）落地后开工
```

---

（deltablue accessor 内联、解释器 store IC 等候选将来按同一四条件逐个申报。）
