# R7-R raytrace — 提纯 + 二分

lane: R7-R / CPU 5 / **诊断批，src 只读**  
日期：2026-08-14  
目标宏观：FW cycles **1.2908**（zoo 0.777）  
zjs pad0 `12bc8b8a…cf3309d` / pad3 `542965de…e3d95693` / pad7 `e9fe8f66…6c8a34c9`  
qjs `b76d1542…1171364d`

## 结论先行

**raytrace 1.29x 100% 在三个 JS 构造里，三 pad 零翻转。**

1. case-pure = zoo 源 + 包函数 + 40×`renderScene`。8-sample pad0 **cyc 1.2964**（门 1.27–1.31）。
2. 拿掉 `Class.create` 的 `initialize.apply(this, arguments)` → 1.241（漂移 −0.055）。
3. 再把热路径 `new Color` / `new Vector` 换成带方法的对象字面量 → **1.0019**（8-sample，≥1s）。
4. 三 pad：case-pure 1.296 / 1.293 / 1.288；塌缩体 1.002 / 1.011 / 1.009。无翻转。
5. 宏观回验：case-pure **就是** zoo `raytrace.js`（只换了 RunSuites 驱动）。构造替换做在同一份源上。
6. 登记 **R7-R1**（主）：让 3 字段 simple `new C(x,y,z)` 接近对象字面量。上限 ≈ 单基准追平，geomean ~+1.7pp。  
   **R7-R2**（次）：`apply`/`arguments` 包装，约 20% 的 raytrace 缺口，可被 R1 吸收。

## 1. 提纯轨迹

| 步 | 文件 | n | cyc z/q | 对 1.29 门 | 注 |
|---|---|---:|---:|---|---|
| 0 case-pure | `case-pure.js` | 8 | **1.2964** | PASS | 40×renderScene，checkNumber=2321 |
| 1 去 apply | `step1-no-apply.js` | 4 | 1.2409 | 漂移 −0.055 | 6 参 `initialize(a..f)`，语义仍过 checkNumber |
| 2 关 shadow/reflect | `step2-no-shadow-reflect.js` | 4 | 1.2417 | 漂移；wall 0.26s 不足 1s | 工作量变了，只作排名 |
| 4 扁平 Color+Vector ctor | `s4-flat-color-vec.js` | 4 | 1.2387 | 与去 apply 同量 | 那两个热 ctor 就是 apply 税的载体 |
| 5 Color 算术改字面量 | `s5-color-literal.js` | 4 | 1.2205 | 再漂 −0.076 | 仍保留 apply + `new Vector` |
| 7 去 apply + Color 字面量 | `s7-noapply-literal.js` | 4 | 1.1347 | 大塌 | 两构造叠加 |
| **8 + Vector add/sub/mul 字面量** | `s8-vec-literal.js` | **8** | **1.0019** | **塌到 1.00** | checkNumber 仍 2321；60 次 ≥1s |

每步都是「换写法、不换像素工作量」（除 step2）。s8 仍跑完整场景，checkNumber=2321。

## 2. 二分：三个「拿掉即塌」的构造

| # | 构造 | 单独效果 | 叠加 |
|---|---|---|---|
| A | `Class.create` → `this.initialize.apply(this, arguments)` | 1.296 → 1.241（−0.055） | 与 C 一起进 s7 |
| B | 热路径 `new Flog.RayTracer.Color(...)` | 含在 s5：1.296 → 1.221 | |
| C | 热路径 `new Flog.RayTracer.Vector(...)`（`add`/`subtract`/`multiplyScalar`） | s7→s8：1.135 → **1.002**（−0.133） | **主载体** |

s4 证明：只扁平 Color+Vector 的 `Class.create`、其它 12 个类仍 apply，比值停在 1.239。  
真正把 1.24 打到 1.00 的是 **算术里的 `new Vector`**，不是场景里偶发的 Light/Sphere/Ray `new`。

## 3. 成对定价（归一到 40 次 render）

| | z cycles | q cycles | z/q |
|---|---:|---:|---:|
| case-pure（40）8-sample | 4.379G | 3.378G | 1.2964 |
| s8（60×40/60）8-sample | 2.966G | 2.961G | 1.0019 |
| **构造税（差）** | **1.412G** | **0.417G** | **3.39×** |
| zjs 相对 qjs 多付 | | **+0.996G** | |

qjs 也付 ctor 税（0.42G），zjs 多付 1.00G ≈ 整段宏观超出（4.379−3.378=1.001G）。守恒。

## 4. 三 pad

| | pad0 | pad3 | pad7 |
|---|---:|---:|---:|
| case-pure cyc | 1.2964 (n=8) | 1.2928 (n=4) | 1.2883 (n=4) |
| s8 cyc | 1.0019 (n=8) | 1.0109 (n=4) | 1.0085 (n=4) |
| 塌缩？ | 是 | 是 | 是 |

## 5. 机制连接

s8 的对象字面量**不是**可上线的语义替换（自有 `dot`/`normalize` 属性，形状不同）。它只定价：`[[Construct]]` + `initialize` 调用相对 `{x,y,z}` 在 zjs 上贵 3.4×。

| 项 | zjs | qjs | 裁决 |
|---|---|---|---|
| `new Vector(x,y,z)` / `new Color` | `constructSimpleFieldConstructor` 准入（EB 已报 sameValue + 原型扫描）+ `initialize` JS 调用 + 帧（R5-C / R6-K 仍 ~0xa0 spill） | CASE `OP_new` / `js_call_constructor`，无独立 96B 帧 | **FAITHFUL-FIXABLE**：让 3 字段 simple ctor 接近字面量。不要删 bypass 换更慢的九-opcode 体（08-11 已裁） |
| `initialize.apply(this, arguments)` | `OP_apply` + arguments 对象 + 额外调用 | 同形但更便宜 | **FAITHFUL-FIXABLE** 次要；R1 若内联 initialize 则吸收 |
| `get_field` 命中 | R5-P ZJS-ADVANTAGE | 更胖 | **勿动** |

对照：`src/exec/vm_ops_call.zig` / `src/exec/call_runtime.zig`（`execCall`、`enterEntry`、simple-field ctor）；qjs `quickjs.c` `JS_CallInternal` ~18175 前无独立帧。

## 6. 登记候选（不实施）

| id | 方向 | 分类 | 上限 |
|---|---|---|---|
| **R7-R1** | 3 字段 simple `new` 逼近对象字面量（压 bypass 准入 + 内联 initialize，而不是再开一层 JS 调用） | FAITHFUL-FIXABLE | raytrace 1.30→1.00 ⇒ 分数 0.777→~1.00，geomean **~+1.7pp** |
| **R7-R2** | 便宜 `apply`/`arguments`（ctor 包装） | FAITHFUL-FIXABLE | ~20% 的 raytrace 缺口；R1 可能吞掉 |

R6-K leaf-call 去 0x220 帧是 R1 的下界切片，单独不够 1.7pp。

## 7. 不要做

- 不要把 s8 的字面量写法当产品补丁（形状/原型不同）。
- 不要动 `get_field`。
- 不要重开 H3 / readfwd。
- 不要删 ctor bypass 换通用九-opcode 体。
