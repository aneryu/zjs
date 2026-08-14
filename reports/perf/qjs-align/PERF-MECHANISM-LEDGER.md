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
状态:      AWAIT-MEASURE——`grok/opt-r10` `a55cfb1e`（先删 `45dc3640` 后立）。zoo 3-pad 交 driver
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
状态:      v1 已落地（991e649f，接通但结构性不足：只消 callee 帧 +18 段，EB 零回收）。
           **v1.5「构造管线熔合」APPROVED-WITH-REVISIONS（2026-08-14）**：
           多 site（16/4，废 caller 级一刀切→覆盖 91.5%）+ proto 指针缓存 +
           E1-E6/E8 被消项逐条证明/deopt（E4 proto 查找 16-21 cyc 是主项）；
           覆盖门 ≥90%、cyc 门 ≥16/take；三修订：
           a) per-take 快检须防 slot 搬迁（比较 ctor shape 指针或 gen 随任意 shape 转换 bump，
              禁止「缓存 index+仅 prototype 写 gen」）；
           b) guard=callee 对象指针相等，同 FB 异对象一律 miss（删「同形换人仍熔合」）；
           c) 保留 poll 钉 qjs JS_CallConstructorInternal 入口位（注行号）。
           v1 六条约束照旧有效。EB 单基准先行，包不交付。
```

---

（解释器 store IC 等候选将来按同一四条件逐个申报。）

---

## `apply-arguments-forwarding`（small-function-inlining 的 rewrite 修订；APPROVED-DESIGN，2026-08-14）

```
来源:      v2 lane 申报（/tmp/lanes/v2-REPORT.md）——raytrace G 形的通用化改写
形态:      两级。L1 转发（吃 0.11 段）：arguments 逃逸证明（S1-S8 数据流谓词，无形态特判）
           + apply 是 realm builtin 守卫 → caller 副本内 DCE 掉 special_object+apply 物化，
           保留 get_field initialize，活 argv 直呼；共享 Class.create FB 不动。
           L2 再展开（吃 0.34 段）：D=2 内联 initialize 体（put_field/分支全留），
           新守卫 I3=proto 方法槽身份（D4 deopt）。
关键义务:  D8 native apply 幽灵帧——两侧 Error.stack 都有 `at apply (native)`，
           省 apply 必须在栈重建里补该帧（InlinedSite 扩展，实现规格前置中）。
           S7 mapped 活槽转发（形参写后 apply 看到当前槽，亲验）。
条件:      L2 受 K=40 闸——qjs 侧 Vector/Color initialize 42B>40；zjs 长度测量中，
           K→48 裁决待数据。K 不扩则只剩 L1（D11 量级 ~+0.34pp）。
预计:      L1+L2 诚实中位 ~+0.5pp（2.53M×~150cyc≈0.38G，raytrace 0.777→0.82-0.90）。
状态:      APPROVED-DESIGN；实施排队（EB 双刀+v11 之后）；前置=K 数据+D8 规格
```
