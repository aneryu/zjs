# ARGSSLIM — mapped arguments 对齐 q 经济学

Lane: `grok/args-slim` @ this commit. CPU **9**。`flock -x` 构建 / `flock -s` 测量。
官方 z = `/home/aneryu/zjs/zig-out/bin/zjs`（02070b60）。q = `/home/aneryu/quickjs/qjs`。
立案：`/tmp/micro-case/periphery/REPORT.md` §3.1 / 刀 A（外围 arguments 桶 +40.9M）。

## 0. 裁决

`arguments[i]` 不再掉进 cold `getValueProperty`。创建拆成 q 同形的直线 `createMappedArgumentsObject`（`quickjs.c:16215-16266`）。`arguments.length` 走自家 data 槽，不再进 exotic tail。

| Case | 官方 z/q cyc | 本刀 z/q cyc | 官方 insn | 本刀 insn | 靠拢（cyc 超额） |
|---|---:|---:|---:|---:|---:|
| `case-args-read.js`（`f(){return arguments.length+arguments[0]}` ×300k） | 1.300 | **1.137** | 1.354 | **1.202** | **54%** |
| `case-sc-list.js`（0 形参 mapped，length+`[i]` ×300k） | 1.343 | **1.121** | 1.273 | **1.070** | **65%** |

`case-noappend.js` 同会话：官方 638.10M insn / 130.41M cyc → 本刀 **621.89M / 126.59M**（**−16.2M insn / −3.8M cyc**）。外围信封 −20M 未吃满：创建链（`createMappedArgumentsObject` 仍 10% sclist）是剩下的结构税（VarRef + `MemoryAccount` + `registerObjectWithBytes`），对照 q `js_malloc`+`js_create_var_ref`，硬削会动 GC 记账。

## 1. 改了什么

对照 `js_build_mapped_arguments`（`quickjs.c:16215-16266`）和 `JS_GetPropertyValue` mapped 臂（`9047-9049`）。

1. **创建** — `createMappedArgumentsObject`（`src/exec/object_ops.zig`，**1024 B**；原先与 unmapped 混在 1984 B 的 `createArgumentsObject` 里）。realm 已缓存的 `ctx.mapped_arguments_shape` 直接用；形参 `captureArg`、多余实参 `VarRef.createClosed`，与 q `get_var_ref` / `js_create_var_ref` 同序。未改 mapped 别名 / delete / callee 语义。
2. **`arguments[i]`** — `op_get_array_el` 在 ARRAY / TypedArray 之后加 `class_id==mapped_arguments` 臂，内联 `mappedArgumentsIntElementDup`（`object.zig`，对齐 `*var_refs[idx]->pvalue`）。原先 integer key 先 interning 再 `getValueProperty`，`fastMappedArgumentsElementValue` 永远走不到。cold `getArrayElement` 同样把 mapped 探针提前。用掉原先 0x90 tombstone，留 0x20。
3. **`arguments.length`** — `op_get_length` 对 arguments / mapped_arguments 直接 `findOwnDataSlotFast(length)`。shape 上 length 是 own data int32（`quickjs.c:16225`）；`classNeedsSlowPropertyAccess` 不再把这条读推进 exotic tail。

未做（结构必需）：不把 mapped 标成 `fast_array`——`isFastArrayIndexInBounds` 只看 `fast_array` 会把 var-ref 当 JSValue 读。q 用 `class_id` switch 分叉；z 用独立臂。

## 2. 测量（CPU 9，ABBA n=8）

校验和三方一致：`2050477040:300000:aread` / `:sclist`；`2:1:2000:16:noap`。

### 2.1 微 case

| | 官方 z | 本刀 z | q | 本刀/官方 insn |
|---|---:|---:|---:|---:|
| aread cyc | 110.06M | 96.33M | 84.72M | |
| aread insn | 610.20M | 541.77M | 450.80M | 0.888 |
| sclist cyc | 170.22M | 142.08M | 126.70M | |
| sclist insn | 898.26M | 755.43M | 705.85M | 0.841 |

### 2.2 `case-noappend.js`

| | 官方 | 本刀 | q |
|---|---:|---:|---:|
| cyc | 130.41M | **126.59M** | 96.51M |
| insn | 638.10M | **621.89M** | 514.35M |
| z/q cyc | 1.351 | **1.308** | 1 |
| z/q insn | 1.241 | **1.209** | 1 |

过程 insn −16.2M。sclist 剖面：`createMappedArgumentsObject` 10.3%、`op_get_length` 7.3%、`op_get_array_el` **2.5%**（读路径已离开 cold resolver）。

## 3. gate

- `zig build test-core`：334 passed / 1 skipped
- `zig build test-exec`：484 passed（含 `mapped arguments rest-style 0-formal length and index (sc_list)`）
- `zig build checkpoint-check`：2270 passed / 1 skipped + architecture checks
- `zig build test -Doptimize=ReleaseSafe`：2270 passed / 1 skipped
- `zig build zjs`：过
- test262 `language/arguments-object`：**263/263**；`Function/prototype/apply`：**48/48**
- raytrace 方向（n=2，分数文本 z/q 分叉属 octane 已知）：本刀 0.993 cyc / 官方 1.000，无回退

未改 `earley-boyer.js`。未碰 main。`case-noappend` 即 EB 出树浓缩尺（过程 −16.2M insn）。

## 4. 剩余

创建仍比 q 肥一个数量级（每 `sc_list` 一次 `createRuntime(VarRef)` + shape 对象 + MemoryAccount）。下一刀若还打 arguments，应对准 `createArgumentsFromShape` / `VarRef.createClosed` 的记账，而不是再加读臂。
