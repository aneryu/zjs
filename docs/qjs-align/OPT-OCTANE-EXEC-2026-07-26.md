# OPT-OCTANE-EXEC 2026-07-26 — Octane 宏基准执行层 QuickJS 忠实对齐

> **范围**：本会话在 Octane（JavaScript Zoo）宏基准上对 zjs 执行层做的 qjs 忠实对齐优化。
> 承接 2026-07-25 的宏基准归因（两个 O(n²) 解析 bug 修复 + typed-array 读写腿），
> 本轮聚焦**执行指令数**在真实多态热路径上的对齐，共 7 个 commit（`21b8c53c..76270b67`）。
>
> **纪律（贯穿全程，硬约束）**：一切改动必须是 **quickjs.c 实际机制的忠实镜像**，
> 而非行为等价的捷径（禁 inline cache / opcode fusion / qjs 没有的表示改）。每刀：
> 对照 quickjs.c 证明分歧真实 → 改 → edge 逐字节 == qjs → 全门禁
> （test262 0/49775 known 25 + test-exec/bytecode/builtins/core + force-GC + OOM）。
>
> **性能参照**：冻结 qjs `/home/aneryu/quickjs/qjs`；CPU19 绑核（`taskset -c 19`）；
> `armv8_pmuv3_1` PMU；固定二进制交错 A/B（`--seed 0` 增量重建非字节确定，必 `cp` 二进制）；
> 指令数为仲裁，cycles 指示性（布局彩票 ±2.8%，故交错多轮）。

---

## 1. 结果总览（Octane 分数比 zjs/qjs，>1 = zjs 快）

| case | 本轮前 | 本轮后 | 动因 |
|---|---|---|---|
| **crypto** | 0.39 | **0.67** | slow(sparse)-array 自有整型读写腿 |
| **earley-boyer** | 0.42 | **0.54** | 构造器 simple-field 快路复活 + per-FB pattern memo |
| **raytrace** | 0.35 | **0.43** | 原型 writable-data 默认值上建自有字段（删每写一次 Descriptor 分配） |
| gbemu | 0.65 | 0.65 | typed-array 直接定长 store + named-prop trusted probe（微赢/对齐，宏观中性） |
| richards | 0.78 | 0.78 | — |
| deltablue | 0.76 | 0.76 | get_field mapped-args 测试收窄（对齐，宏观中性） |
| navier-stokes | 0.65 | 0.64 | float-div 腿（helps float-div-heavy，此 case 非） |
| splay | 0.30 | 0.31 | — (GC-dominated) |
| box2d | 0.71 | 0.71 | — |

三个宏观移动：**crypto +72%、earley +29%、raytrace +26%**。其余稳定（对应机制不在其热路，或聚合近对齐无单点）。

---

## 2. 落地的七刀（按 commit 顺序）

### ① `21b8c53c` float 除法冷路内联 both-number 腿
- **分歧**：`opBinary` 的 both-int32 快路处理 `int/int` 除法（canonicalizing），但 float/float 直落通用 `h_binary→binaryVm`（403 insn，全 ToNumeric + tag 分类）。
- **qjs**：OP_div 仅 both-int 腿，其余全 `js_binary_arith_slow`→`handle_float64`：`dr=d1/d2; __JS_NewFloat64`（**裸 float 不规范化**——because both-int 腿已吃掉 int 规范化那支，quickjs.c:15037 handle_float64）。
- **改**：加 `op_div_cold`，镜像已有的 `op_mod_cold`（`numberValue` 双取 → `JSValue.float64(lhs/rhs)`，BigInt/string/object 返 null 留通用路），挂 `cold_table[OP_div]`。
- **量**：isolated float div **403→106 insn**（3.63x→0.95x 反超）。⚠️零 Octane 宏观位移（此集无 float-div-bound case）。

### ② `bdacf2fa` slow(sparse)-array 自有整型读写腿 ⭐crypto 大赢
- **分歧**：crypto BigInteger `bnpMultiplyTo` 用 `while(--i>=0) r.array[i]=0` 对空数组**高位先写** → 非连续 → dense append gate 拒 → 转 shape 存储。之后每次元素访问**双 fast-path miss（dense+typed）→ cold `arrayElement` 又重试一遍 → `toPropertyKeyAtom`（两非内联调用 + defer-free 仅为 int→atom）→ getValueProperty**。`getDenseArrayElementValue` 跑 3×、typed probe 2×/读。纯读 715 / 纯写 887 insn vs qjs 365 / 394（1.96x/2.25x，fill 一次摊掉后测）。
- **qjs**：`JS_Get/SetPropertyValue` 的 `JS_CLASS_ARRAY` 臂在 `idx >= u.array.count` 时把 int atom 交 `JS_Get/SetPropertyInternal` = 一次 find_own_property (+set_value)。
- **改**：dense miss 后加两热腿 `fastArrayOwnIntElement{Value,Set}` → `getOwnDataPropertyValue(atomFromUInt32)` / `setOwnWritableDataProperty`，均 gate on `isArray`（Array 绝非 typed → 也省 slow-array 的 typed probe；排除 mapped-arguments/proxy 留精确 ordering）。hole/accessor/non-writable/new/proto-only 返 null|false 落原冷路 → 语义不变。
- **量**：纯读 1.96x→0.73x、纯写 2.25x→0.90x（均反超）；**crypto 0.39→0.67**。20+ 读写 edge 逐字节 == qjs。

### ③ `611a7700` 构造器 simple-field 快路复活 ⭐earley 大赢
- **分歧（两处死码，逐 gate instrument 挖穿）**：`new Vec(x,y,z)` 2.6x：
  1. `constructSimpleFieldConstructor`（`this.f=arg` 模式 → `defineOwnPropertyAssumingNew` 跳过 body）**被 `fb.argumentsAllowed()` gate 判死**——该 flag parser 对**每个非箭头函数**都设 true（意为「arguments 在作用域内」非「被用」），故快路对所有普通构造器全废。pattern 已保证 body 纯 field-store 不引用 arguments，gate 冗余 → 删。
  2. **函数 `.prototype` 在 zjs 惰性（auto_init 占位）** 而 qjs `js_closure2` 急切建 → `getOwnDataObjectBorrowed` 对 auto_init 失败 → `createBytecodeConstructorInstance` + simpleField 双双落 `reflectConstructPrototypeVm`（全 VM property GET）**每次构造**。加 `getOwnConstructorPrototypeObject`：首次构造物化 auto_init（转 .data 永久），后续走 direct read + Object.create。
- **量**：new Vec 2.59x→1.41x；**earley-boyer 0.42→0.53**。18 构造 edge（arguments 用/默认参/继承/class-extends-super/Reflect.construct 异 new.target/proto getter&替换）逐字节 == qjs。⚠️raytrace 不动（其 Vector 用 Class.create 双调用 + `this.x=(x?x:0)` 三元非 simple-field）。

### ④ `b446c2a1` typed-array 元素写 = 直接定长 store 非 memcpy
- **分歧**：`putTypedArrayElementFast` coerce 进 8B scratch 后 `@memcpy(bytes[off..][0..width], scratch)`，`width=payload.element_size` 是运行时值 → LLVM 不能特化 → 即使 1B Uint8 写也发 `memcpyFast` **调用**（gbemu VRAM 写占 7.1% self）。
- **改**：`storeElementBytes` switch(width) 用 comptime 长度 `dst[0..N].*=scratch[0..N].*`（仅 1/2/4/8），单条定长 load+store（qjs 也直接 store）。read 腿早已 comptime `std.mem.readInt`。
- **量**：uint8 读写 kernel 859→847 insn/iter；memcpyFast 7.1%→0.17%。⚠️gbemu 分数不动（call 开销省，byte copy 内联吸收；宏观瓶颈在 access 重推 length）。全类型 + OOB + detach + resize + valueOf 逐字节 == qjs。

### ⑤ `fea03027` 构造器 simple-field pattern per-FB memo
- **分歧**：③复活后，fast-path 每次 `new F()` 仍**重扫 bytecode 配 `this.f=arg` 模式**（走码 + O(fields²) dedup，占 `new Vec` 循环 6.15% self）——但 match 是 FB immutable 纯函数。
- **改（跨层干净解）**：JSRuntime 上单条 memo `simple_ctor_memo{fb:usize, is_simple, len, atoms:[8]u32, args:[8]u16}`——**key 用 FB 指针的 usize（裸整数）故 core 不泄漏 exec 类型（破循环 import）**；FB 析构器（`destroyFromHeader` 有 rt）`if memo.fb==@intFromPtr(self) memo.fb=0` 清 memo → **指针复用无 ABA**。单 runtime/线程故无锁。
- **量**：new Vec 1.41→1.35；earley 0.53→0.55（宏观在 Octane ±噪声带边缘，指令赢确凿）。⭐ABA 门 = 2000 轮 eval 出的相异构造器（两 simple shape + 一 non-simple 逼 FB create/free/同址复用）normal + force-GC 双 build 逐字节 == qjs。

### ⑥ `0c218744` 原型 writable-data 默认值上建自有字段 ⭐raytrace 大赢
- **分歧**：`defineNewOwnDataPropertyForSimpleSetKnownNoOwn` 只要**任何**原型拥有该 key 就 bail 到重 resolver（`findPropertyDescriptor→getOwnProperty` 沿链重建 **allocating Descriptor** 只为发现是 data 非 accessor）。
- **qjs**：`JS_SetPropertyInternal` 原型循环读 `prs->flags`——writable-data → `break` + `add_property(JS_PROP_C_W_E)` 建接收者自有属性（quickjs.c:9840-9853, 9884）；仅 GETSET(setter)/AUTOINIT(materialize)/non-writable(read_only) 走别的路。
- **改**：原型命中读 `propFlagsAt` inline，writable-data（`!deleted and kind==.data and writable`）→ break 落已有 `addProperty(C_W_E)`，否则 return false 留原 resolver。3 原型 walk→1 + **删每写一次 Descriptor 分配**。
- **量**：raytrace 主导写（每 `new Vector/Color` 写 `this.x/y/z` 而 `Vector.prototype={x:0,y:0,z:0}` 已拥有）。**交错 A/B 6 轮 1166→1443（+23.7%），raytrace 0.34→0.43**。18 原型-set edge（writable-data own-create/继承 setter 触发/getter-only & non-writable sloppy-noop + strict-throw/多层原型/shadow-builtin）逐字节 == qjs。
- ⭐**关键教训坐实**：这是本会话唯一的 **allocation-removal** change-class——真能动 Octane macro；纯 insn-cut（①④⑤两对齐）被乱序核藏住多为宏观中性。

### ⑦ `76270b67` 两条属性快路探针对齐 qjs（删 zjs-only 分歧，宏观中性）
- **gbemu**：typed-array named-prop 探针 `findProperty`→`findPropertyIndexTrusted`（qjs 强制内联 `find_own_property` quickjs.c:6135 的忠实镜像，删 zjs-only 防御 cycle/bounds guard，well-formed shape 上恒等；已有 5 生产 caller）。
- **deltablue**：`qjsGetFieldFastSlot` 的 mapped-arguments class 测试 hoist + gate on `isTaggedInt(atom_id)`——mapped-arg 数字绑定 index∈[0,argc)⊂tagged-int（argc≤u16≤max_int_atom），named/symbol atom 永不别名绑定 → shape slot 权威（qjs 用 JS_PROP_VARREF shape entry 本无此测）。named-field 读省 per-object class 测试。

---

## 3. 方法与纪律（可复用资产）

1. **micro ≠ macro，必 profile 真 case 归因**。float-div（①）与 typed-store（④）都是确凿的指令赢却零 Octane 位移——纯 insn-cut 被乱序核（OoO）藏住。**只有 allocation-removal（⑥）真动了 macro**。反面：raytrace 曾被误归因为 float，profile 才发现是 property + construct。
2. **忠实优先于快**。每刀先在 quickjs.c 找到对应机制、引行号证分歧真实，再镜像；禁 IC/fusion。②③⑥都是「zjs 落了 qjs 已有的快路/急切物化」而非发明新机制。
3. **instrument 逐 gate print 挖 fast-path 不 fire 的根因**——③的两条死码（`argumentsAllowed` 死 gate + auto_init prototype）都靠此挖穿，纯读码看不出。
4. **门禁不减**：test262 0/49775 known 25 + focused suites + force-GC + OOM + edge 逐字节 == qjs；生命周期敏感 cache（⑤memo）加 ABA 压测（force-GC 双 build）。
5. **workflow（代码分析挖掘 + 对抗验证）**：⑥⑦由 15-agent workflow 找出——7 路 agent 对照 quickjs.c 挖候选（**不跑 perf**，避免并行互踩），7 路对抗 verify 5 轴（REAL? / SAFE? / **FAITHFUL?(引 quickjs.c，否则出局)** / REGRESS? / deep-sound?），synth 排序。它推翻了「clean 杠杆已尽」的判断。⚠️坑：agent 并发编同一文件 → 候选缠一起 → **落地前必 git checkout 隔离单个 + 交错 A/B**（⑥就是从两缠着的候选里隔离出来独测的）。

---

## 4. 剩余前沿（对抗验证图，下一轮起点）

| 杠杆 | 状态 | 判定 |
|---|---|---|
| **construct inline-frame** | ⏸️ deep，暂缓 | 忠实镜像 `JS_CallConstructorInternal`(20809-20853)，但其 gate 与 simple-field ctor 全同 → 会把它们拖离已落地的 `constructSimpleFieldConstructor` 直写短路（回吐 earley 的赢）。**de-risk：HEAD 已有 `simple_ctor_memo.is_simple` 可路由 simple ctor 回短路**（objection#1 解）。仍卡 macro 未证（raytrace 0.34 是多态慢路非 construct body 物化）。待有界证据证 body 是瓶颈再开。 |
| **typed-array count-cache** | ⏸️ deep，风险高 | qjs `u.array.count`（detach 置 0）一次 `idx<count` 折叠 detach+bounds；zjs 每访问 ~5 检 = 93insn gap 主体。真对齐需**先加 per-buffer view-list**（现 `detachByteStorage` 只置 buffer flag 不通知 view），detach/resize 维护 count = 多文件表示改 + UAF/OOB 安全险，只惠 gbemu 一例。 |
| **box2d `needs_slow_property_access` 预计算位** | ❌ REJECTED | 方向忠实（qjs 5627/5657 创建时算 is_exotic），但 ObjectFlags 无 layout slack：复用 `is_borrowed_reference_holder` 位 → 析构器读它注销弱注册 → **UAF/leak**；`is_with_environment` 门 strict-with。除非 `class_id u16→u8` 重构。 |
| **GC teardown (splay)** | ⏸️ 判死频率角度 | GC 频率**已实测忠实对齐**（256KB + ×1.5 = qjs `malloc_size+(malloc_size>>1)`）。splay 22% GC 是基准固有（GC-latency 基准同频收集）。zjs Phase1 有独立 mark-all walk（~5 vs qjs ~3）可能是分歧，但合并省 ~2% + GC 正确性高危 → 不值。 |
| navier / splay 有界候选 | ⏸️ 判 macro-neutral | op_put_array_el in-bounds float 覆写腿（忠实 set_value，但 float 覆写被 OoO 藏）/ defineField 2nd+ prop 精简（splay GC-dominated 结构锁死）。忠实 + 安全，未实现。 |
| deltablue / richards / navier / gbemu | 聚合近对齐 | property 1.14x / method 1.14x / dense-array ~1.0x 皆前序战役已收，无单点。除非做全局 per-op 再压（收益递减）。 |

**结论**：本集剩余的干净 allocation-removal 杠杆已尽；下一轮真要推需啃 construct inline-frame（deep 但 simple_ctor_memo 已 de-risk）或接受聚合近对齐现状。深改一律 workflow 对抗 verify + 全门禁，绝不偏离 quickjs。
