# EARLEY-TREES-INSN — 出树多 25% insn 锁源 + 刀

日期：2026-08-17。九期主攻。CPU 未占 5/6/7/19。数字非裁决。

| | |
|---|---|
| 分支 | `grok/earley-trees` **`b33994d9`**（基 `0f721021`） |
| 工作树 | `/tmp/wt-earley-trees` |
| z dump 二进制 | `/home/aneryu/zjs/zig-out/bin/zjs` RF tagged（emit 对账） |
| q dump 二进制 | `/tmp/qjs-dump/qjs` `DUMP_BYTECODE=1\|2\|4` |
| 同一 JS | `/tmp/census/det/earley-only.js` 的 compile-only 拷贝 |
| 原始 dump | `/tmp/lanes/earley-trees/dumps/` |

config: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

---

## 0. 结论先行

**z 没有在出树族上 emit 更多热路径 op。** 同一 JS，`sc_Pair` / `sc_isPair` / `sc_cons` / `sc_list` / `sc_append` / `deriv_trees` 的**执行序列与 q 同形**。Earley insn 1.252 不是「编译器多吐了 25% 字节码」，是**同 op 数下热臂更肥**（再加 H3 故意留下的 `tail_call` 后 `return` 桩）。

| 问题 | 答案 |
|---|---|
| z emit 了更多 op？ | **热路径没有。** helpers 字节码逐条相同。`deriv_trees` 42=42。 |
| 同 op 数但热臂更肥？ | **是。** 25% 原生 insn 来自每发代价，不是多出来的字节码。 |
| dump 上 loop2/loop3 多 1–2 条？ | `tail_call` 后多一个 `return`。H3 故意留的 resume 桩（q 把 return 熔进 `tail_call`/`goto done`）。**会执行**，但不是 25% 的主项，且 H3 已封，本单不重开。 |
| 08-11 fclosure 热表？ | **不重跑。** 那是 0.645 合凳账。外壳已常驻。 |

四条采样嫌疑的实现级对账：

| 嫌疑 | emit | 实现 vs q | 25% 角色 |
|---|---|---|---|
| `fclosure8` 800 ns/发 | 同：`fclosure8; set_name; set_loc0` | 创建链比 `js_closure`/`js_closure2` 厚（ValueRootFrame 因精确 GC 必留；生产路径曾多 Realm/扩展校验 + `atoms.kind` 探测） | **创建税。** r11c 刀口。本单下刀处。 |
| `get_var_ref` 7.2M | 同：idx&lt;4 短形式，其余 `get_var_ref u16` | 已是 `*var_refs[i]->pvalue` + `dup`（q 18613–18636） | 发数来自闭包捕获，不是多 emit |
| `call_constructor` 4.7M | 同：`get_var; dup; args; call_constructor` | `JS_CallConstructorInternal` 镜像 + same-Machine 准入。r11c s5 已证 ctor 不是比值载体 | **不是 emit 源**；不要重开 simple-field bypass |
| `instanceof` 7.9M | 同：`get_arg0; get_var; instanceof` | q `js_operator_instanceof`→`JS_IsInstanceOf`；z 已走 default `@@hasInstance`→`ordinaryHasInstance` proto walk | **单价。** 每发都 `publish` + noinline。瘦得掉，但不是「多发 op」 |

**对 EB-FUNC-ATTRIB §0b「瘦 handler 削不掉」的订正：** 那句建立在「多干活 = 多字节码」上。本单证明**执行的字节码条数对齐**，多出来的原生 insn 就是每条 op 的 native 展开。瘦创建链/热臂**可以**削 25% 里的单价部分。上限仍受 H3 return 桩 + 精确 GC 根 + 同发数约束。

---

## 1. ① 字节码对账

方法：`ZJS_DISASM=1 zjs` vs qjs `DUMP_BYTECODE` pass 3。同一份 compile-only JS（`RunSuites` 换成 `print("compiled-only")`，函数全部编译、不跑 2500 次）。

函数数：z 440 / q 441（差 1 是脚本根）。

### 1.1 具名 helpers — 逐条同形

| 函数 | z nops | q nops | 序列 |
|---|---:|---:|---|
| `sc_isPair` | 4 | 4 | `get_arg0 get_var instanceof return` **同** |
| `sc_cons` | 6 | 6 | `get_var dup get_arg0 get_arg1 call_constructor return` **同** |
| `sc_list` | 26 | 26 | `special_object … call_constructor … dec_loc goto8` **同** |
| `sc_append` | 36 | 36 | **同** |
| `sc_consStar` | 30 | 30 | **同** |
| `sc_Pair` | 9 dump | 9 | 见下（fusion 影子） |
| `sc_dualAppend` | 19 | 18 | 末尾 `tail_call` 后 z 多 `return`（H3 桩） |

`sc_Pair` z dump：

```
push_this_put_loc0   ; fc   first-byte rewrite of push_this
put_loc0_get_loc0    ; fd   leftover B（handler `cont(pc+2)` 跳过）
get_loc0
get_arg0 put_field
get_loc0 get_arg1 put_field
return_undef
```

q：`push_this; put_loc0; get_loc0; get_arg0; put_field; …`。执行语义 = 同 9 步。252/253 是**第一字节改写**，dump 的 `size=1` 把 leftover 也列出来了，**不是多执行**。

### 1.2 出树闭包族（按 q 源行对齐）

| 源 | 角色 | q nops | 对齐的 z | 差 |
|---|---|---:|---:|---|
| L4656 | `deriv_trees` | 42 | 42 | `lt; if_false8` → z `cmp_if_false8` + leftover。执行同 |
| L4660 | `sc_loop1_98` | 33 | 34 | +1 = `tail_call` 后 `return` |
| L4674 | `loop2` | 72 | 74 | +2 = 两处 `tail_call` 后 `return` |
| L4688 | `loop3` | 44 | 46 | +2 = 同上；`get_loc0; get_field` → `get_loc0_field` + leftover |
| L4726 | `deriv-trees*` 外层 | 73 | 73 | 同 |
| L4759 | `nb_deriv_trees` | 34 | 34 | 同 |
| L4763 | `nb` 内层 | 108 | 109 | +1 return 桩 + `get_loc8_push_1` fusion |
| L5001 | `parse→trees` | 38 | 39 | +1 return 桩 |
| L5020 | `test` | 21 | 22 | +1 return 桩 |

`loop3` 热臂（两边一样，z 只是 fusion 改写）：

```
get_arg0 get_var instanceof if_false8          // l3 instanceof sc_Pair
get_var get_arg0 get_field call1 put_loc2      // sc_list(l3.car)
get_var_ref2 put_loc0
get_arg1 put_loc1
get_loc0 get_var instanceof if_false8          // while (l4 instanceof sc_Pair)
get_var dup get_var get_loc0 get_field get_loc2 call2
get_loc1 call_constructor put_loc1             // new sc_Pair(sc_append(...), ...)
get_loc0 get_field put_loc0 goto8
… tail_call (loop3) / tail_call (loop2)
```

**没有「z 多 emit 一串 get_loc / check / proto」。** `fclosure8`+`set_name` 两边都有（具名函数表达式 `loop2`/`loop3`）。

### 1.3 H3 `return` 桩（唯一系统性多 emit）

`resolve_labels.zig:2266-2271` 明文：

> Keep the following `return` (do not skipDeadCode it). zjs inline frames resume the caller at the next pc; leaving `return` is the H3 shared return stub. qjs fuses the return into the opcode because `JS_CallInternal` + `goto done` never resumes.

所以 dump 多出来的 1–2 条**会执行**（callee 回到下一条 `return`）。这是已知 H3 税，不是本单新发现的 emit 漏。重开 true-tail = 重开 H3，本单不碰。

对 25% 的贡献：出树每次 `sc_loop1`/`loop2`/`loop3` 走一条 tail。r11c 量级 0.44M+0.72M+0.74M ≈ 1.9M 次额外 `return`。即使按 80 native/发也只 ~150M insn，远不够填 Earley 整段 +25%。

---

## 2. ② 四条路径实现镜像

### 2.1 `fclosure8` — 创建链，不是 handler

| | z | q |
|---|---|---|
| CASE | `opFclosure` 已常驻，`*sp++` 形（`tailcall_dispatch.zig:2966`） | `CASE(OP_fclosure8)` 17914：`*sp++ = js_closure(...)` |
| 对象 | `createBytecodeFunctionObject` → Internal → `attachFunctionCaptures` | `js_closure` 17369 → `js_closure2` 17262 |
| 捕获 | `captureLocal`/`captureArg` / `var_refs[i].retain()` | `get_var_ref` / `cur_var_refs[idx]; ref_count++` |
| 属性 | `jsFunctionSetProperties` length+name | `js_function_set_properties` |
| proto | `defineFunctionPrototypeAutoInit` | `JS_DefineAutoInitProperty(PROTOTYPE)` |

z 多出来、q 没有的：

1. **ValueRootFrame** 包住 FB。z 是精确 GC，C 栈上的 JSValue 扫不到；q 保守扫描。**必留。**
2. ~~每次创建的 `hasExtension` / `byte_code_len` / Realm==ctx / global 三等式 `return error`~~ → 本单改 `debug.assert`（finalize 已保证；q `js_closure` 只 `JS_VALUE_GET_PTR`）。
3. ~~`atoms.kind(func_name)` + `kind(name_fallback)` 两次表探~~ → 本单改成 q 的 `func_name` 否则 fallback（17388–17390）。
4. `resolveNestedClosureCell` 里 LOCAL/ARG 的生产期 bounds `error`、REF 的 `ensureVarRefsCapacity` 调用 → 本单改直接索引 + `assert`（q 17313–17325）。
5. `captureLocal`/`captureArg` 三道 `error.InvalidBytecode` → 本单改 `assert`，对齐 q `get_var_ref` 的 NDEBUG `assert`。

**禁止：** 再做 `opFclosure` 热表（08-11 / r11c §8）。

### 2.2 `get_var_ref` — 已经齐

z `opGetVarRef`：`cell = vm.var_refs_base[idx]; sp[0] = cell.pvalue.*.dup()`。  
q：`*sp++ = JS_DupValue(ctx, *var_refs[i]->pvalue)`。

loop2 有 18 个 closure var，热槽 ≥4 走 3 字节 `get_var_ref`，**两边一样**（q 只把 idx&lt;4 收成 `get_var_ref0+idx`）。7.2M 发是捕获变量的真实访问次数，不是 z 多 emit。

### 2.3 `call_constructor` / `new sc_Pair`

emit 同。实现：`JS_CallConstructorInternal` 镜像 + `resolveSameMachineConstructor`（`dup` 后 identity，不再跑 SameValue）。  
r11c s5：`new sc_Pair`→字面量 **两侧都变慢**，ctor 不是比值载体。本单不重开 simple-field bypass、不特判 `sc_Pair`。

### 2.4 `instanceof`

emit 同。q：`sf->cur_pc = pc; js_operator_instanceof` → `JS_IsInstanceOf`（每次 `GetProperty(@@hasInstance)` 再 Call）。  
z：`publish` + 探 `@@hasInstance`；命中 default 则 `completeOrdinaryInstanceof`（noinline）→ `ordinaryHasInstance` 的 `shape->proto` 走（已对齐 q 8087–8125）。

z 在 default `@@hasInstance` 上比 q **少一次** Call，这是已有瘦身。剩下的税是 `publish` + noinline 出岛。7.9M 发的单价刀另立，本单先锁「不是多 emit」。

---

## 3. ③ 刀

### 3.1 不下的刀

| 候选 | 原因 |
|---|---|
| 删 `tail_call` 后的 `return` | H3 桩，true-tail 才删得掉。封条有效 |
| `opFclosure` 热表 / 08-11 旧刀 | 0.645 合凳账；外壳已常驻 |
| 产品里压扁 `deriv_trees` 成 while | r11c s3 只定价，禁止进产品 |
| `sc_Pair` / `instanceof` 特判 | 宪法：不对 zoo 源形态开洞 |
| simple-field ctor bypass | r11c s5 证伪 |

### 3.2 下的刀（忠实：压到 `js_closure` / `js_closure2` / `get_var_ref`）

分支 `grok/earley-trees`，两文件：

- `src/exec/object_ops.zig`
  - `createBytecodeFunctionObjectInternal`：生产路径不再 `return error` 重验 extension/Realm；名字按 q 取 `func_name` 否则 fallback，去掉 `atoms.kind`。
  - `resolveNestedClosureCell`：LOCAL/ARG/REF/GLOBAL_REF 按 q 17313–17325 直取，REF 不再每发走 `ensureVarRefsCapacity`（finalize 已定长，热路径上那是纯空调用）。
- `src/exec/frame.zig`
  - `captureLocal` / `captureArg`：bounds / captured 位改 `std.debug.assert`，对齐 q `get_var_ref` 的 NDEBUG。Debug/Safe 仍留 cell-shape 哨兵。

ValueRootFrame **保留**（精确 GC ≠ q 保守扫描，删了会在创建期分配时丢 FB 根）。

### 3.3 验证（补全门）

提交：`b33994d9` `perf(exec): slim fclosure create toward js_closure2`（只 `frame.zig` + `object_ops.zig`；工作树 `test262` symlink 未入仓）。

收尾复跑（commit 后，同一 RF pin）：

| 门 | 结果 |
|---|---|
| `zig build test-exec` 全量 | **480/480** |
| test262 全量 | **0/49775 errors**，passed 44581，exit 0 |
| RF nm 岛 | **未动**（收尾前已验：`.text.zjs.op_handlers` `0x1070000` / `0x2d688`；岛内 343 符号 addr+size 全等） |
| FW CPU15 ABBA n=4 | 见下（收尾复跑） |

FW（A=`/tmp/eb-s1/zjs-base` ≡ `0f721021` RF，B=`/tmp/lanes/earley-trees/zjs-knife`，CPU15 `armv8_pmuv3_1`）：

**主尺 cyc（终盘钉号，n=8）：不赢。**

| 发 | n | Δcyc | B/A cyc | Δinsn | B/A insn |
|---|---:|---:|---:|---:|---:|
| 补全门 | 4 | +9.0M | 1.0028 | −123.8M | 0.9910 |
| commit 后 | 4 | +12.6M | 1.0040 | −114.4M | 0.9917 |
| **终盘钉** | **8** | **−4.4M** | **0.9986** | **−120.4M** | **0.9912** |

n=8 中位 A 3163.5M / B 3159.1M。A 散 3120–3180M、B 散 3139–3194M（~60M）。Δcyc 落在噪声里，三次符号翻转。**insn 每次都少 114–124M，四/八发无交叉。** 按「insn 赢 cyc 不赢杀」：本刀 **cyc 未过门**。

哨（commit 后 n=4）：boyer-only Δcyc −204M / Δinsn +254M（双侧 241.45/241.96G 双峰中位，比值 1.0011）；splay Δcyc +20M / Δinsn +1.7M。

原始：`/tmp/lanes/earley-trees/fw.json`，`/tmp/lanes/earley-trees/fw-earley-d16-n8.json`。

出树超额的大头仍是「同 op、更肥的 native」（instanceof `publish`、ctor 入帧、创建期 malloc+属性+精确 GC 根）。本刀吃的是创建链上 q 没有的校验/表探/空调用。

---

## 4. 锁源一句话（给 driver）

> Earley +25% insn **不是 emit 多 op**。同一 JS，出树闭包族执行序列与 q 对齐；dump 多的是 H3 `tail_call`+`return` 桩和 first-byte fusion 影子。25% 是 **同 op 的 native 展开**（fclosure 创建链、`instanceof` publish、`new sc_Pair` 入帧、`get_var_ref` 发数本身）。本单刀：创建链去 q 没有的生产校验/`kind()`/`ensureVarRefsCapacity` 空调用。不重开 H3、不重跑 08-11 热表。

---

## 5. 路径

| 路径 | 内容 |
|---|---|
| `/tmp/lanes/EARLEY-TREES-INSN.md` | 本文件 |
| `/tmp/lanes/earley-trees/earley-compile-only.js` | 对账夹具 |
| `/tmp/lanes/earley-trees/dumps/z-full.txt` `q-full.txt` | 全量 dump |
| `/tmp/wt-earley-trees` | `grok/earley-trees` 工作树 + 刀 |
