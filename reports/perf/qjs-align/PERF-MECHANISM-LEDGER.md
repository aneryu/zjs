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

---

## `small-function-inlining`（PROPOSED，方案甲）

```
参照:      V8/JSC 调用点内联 + inline-frame 栈重建（保 Error.stack）
形态:      几何门（体长/argc/realm/单态）下把小函数体展开进调用点；
           put_field/get_field 照跑；消的是 call+Entry+return，不是语义步骤。
           现有 inline_calls 同机 Entry 不是本机制（那笔钱就是 R9 的 0.34）。
通用性:    不认 initialize / sc_Pair / accessor 名字；多形不展开（无悬崖）
等价面:    Error.stack 靠 InlinedSite 重建逻辑帧；中途 throw；ctor return 两分支；
           setter 仍走 put_field。H3 reuse 明确禁止。
覆盖:      EB sc_Pair（bypass-off −9.08% 主力回收）；
           raytrace G 内层 initialize（~0.34）；
           deltablue 短方法链
配套:      与 classify 删除同包落地（先内联、删除搭便车）。
           capacity-profile 降为次要（≤3 字段回收≈0）。
状态:      **APPROVED-WITH-REVISIONS（driver，2026-08-14）**——K=40/D=2/M=8/特化≤4、
           v1 不展开 getter 照批；六条实施约束：①全局特化字节预算(3% or 256KB)
           ②guard 单次读语义 ③计数器旁表+恒多形负对照(≤1cyc/call)
           ④三靶诚实订正：**raytrace G 形 ctor 体用 arguments→不合格，v1 覆盖≈0**
           （0.34 归 v2 apply-aware 变体另行申报），真靶=EB+deltablue
           ⑤验收线：包 3-pad 不下凹+EB 收回 2/3+；case N2/N3→≤1.05；旧 N3 0.87 门作废
           ⑥展开体 pc/line 须差量映射（操作数重写致字节不等长，线性偏移不成立）
```

---

（解释器 store IC 等候选将来按同一四条件逐个申报。）
