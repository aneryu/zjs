# L3-RC-DIVERGENCE — 忠实对齐 qjs RC 纪律（只析不改）

日期：2026-08-17。**只析不改。无产品 commit。**  
driver 改令：暂停「qjs 没有的新机制」。本层只回答：**qjs 哪里用 borrow / 免 RC 惯用法，z 对位有没有多付真 RC 对。**  
对齐定义 = **镜像 `quickjs.c` / `quickjs.h` 的 RC 纪律**（宪法原文：只有 `JS_DupValue` 才 `rc++`，只有拥有者 `JS_FreeValue` 才 `rc--`；`JS_VALUE_GET_OBJ` / 栈窗 / 形参不是拥有者）。

| | |
|---|---|
| z 钉 | `main@f0070244` RF `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |
| 普查孤岛 | `/tmp/wt-l3-rcframe`（`ZJS_RC_CENSUS`）/ `/tmp/wt-l3-qjs`（`JS_DupValue`/`JS_FreeValue` 内联计数） |
| 夹具 | `/tmp/r5/fixed/{typescript,box2d,splay,earley-boyer,pdfjs}.js` |
| 核 | CPU **16** |
| 原始 | `/tmp/rc-census/` |
| 前序（已改向，不沿用其立项） | `/tmp/lanes/MECH-L3-RCFRAME.md` |
| 数字 | **非裁决** |

**停：** emit 期借用消除（`get_loc`→`get_field` 窗内 +1−1）。qjs **无对应形**（`OP_get_loc*` 恒 `JS_DupValue`，`GET_FIELD_INLINE` 恒 `JS_FreeValue` 接收者）。两边都付，不是偏差。

---

## 0. 一句话

**热径上 qjs 的 borrow / 免 RC 惯用法，z 已经镜像。** 五落后案 JSValue `rc++`/`rc--` 比 0.82–1.03；call+ret 合并 dec 0.89–1.00；cmp dec 贴到条。普查**找不出**「q 只取指针、z 付真 RC 对」的大额热位点。

splay ⑦ +204M、TS ④a return 5.70G **不是 RC 对盈余**——前者是拆毁走访占用（IRON），后者是帧字段存/撤占用。宪法句管的是 Dup/Free 次数，不是 Entry 宽度。

剩余可点名的偏差要么是 **q 比 z 多付**（`argc < arg_count` 时 q `JS_DupValue` 拷进 alloca，z 挪槽），要么是 **L0 / apply 幽灵帧** 的一次 Dup（发数不是 zoo 热尺）。没有够 30M 门的「补齐 qjs 免 RC」刀。

---

## 1. 宪法原文（本层尺子）

`quickjs.h:687–723`：

```
JS_FreeValue:  if (HAS_REF_COUNT) { if (--p->ref_count <= 0) __JS_FreeValue; }
JS_DupValue:   if (HAS_REF_COUNT) { p->ref_count++; }  return v;
```

配套惯用法（`quickjs.c` 解释器，不是另一套语义）：

| 惯用法 | 原文 | 含义 |
|---|---|---|
| **取对象指针不加引用** | `p = JS_VALUE_GET_OBJ(v)`（宏，`quickjs.c:229`） | 走访 / 比身份 / `is_exotic`。拥有者仍是那份 `JSValue` |
| **栈上 borrow** | `arg_buf = argv`（17841）；`OP_call*` 返回后才 `JS_FreeValue` 调用方槽 | 形参窗不是第二份拥有 |
| **帧字段不 Dup** | `sf->cur_func = (JSValue)func_obj`（17843）；`done:` **不** Free `cur_func` | 拥有者仍在调用方栈 |
| **this / new_target 是形参** | `JS_CallInternal(..., this_obj, new_target, ...)`；`JSStackFrame` 无这两字段 | 不另立拥有者 |
| **闭包数组借指针** | `var_refs = p->u.func.var_refs`（17844） | 不 Dup 每个 cell |
| **槽替换** | `set_value`（2664–2669）：写入新值（已拥有），再 Free 旧值 | 不先 Dup 再 Free 新值 |
| **要拥有才 Dup** | `GET_LOC` / `GET_FIELD` 槽 / `push_this` / `set_loc` | 栈槽是拥有者，必须 +1 |

z 对位：`JSValue.dup` = `JS_DupValue`；`free` / `freeDuringActiveBytecode` / `release*NeedsDestroy*` = `JS_FreeValue`；`objectFromValueTrustedExpression` = `JS_VALUE_GET_OBJ`；`OwnershipDisposition` + `takeSourceSlot` = 帧级隐式合同的显式版。

普查只计这两条内联（不计 shape / atom / `BlockHeader`）。`rc==1` destroy 尾只记一次 dec。

---

## 2. RC 流量普查（z vs q 本体）

### 2.1 总数

| 案 | z inc | q inc | z/q | z dec | q dec | z/q |
|---|---:|---:|---:|---:|---:|---:|
| typescript | 125.93M | 129.48M | **0.973** | 126.12M | 129.87M | **0.971** |
| box2d | 47.89M | 47.74M | **1.003** | 47.69M | 48.17M | **0.990** |
| splay | 11.40M | 13.97M | **0.816** | 12.63M | 16.44M | **0.768** |
| earley-boyer | 178.27M | 173.85M | **1.025** | 180.46M | 180.14M | **1.002** |
| pdfjs | 23.54M | 23.63M | **0.996** | 23.25M | 26.47M | **0.879** |

**z 没有系统性更高的 JSValue RC 次数。** 唯一 inc 略高是 EB +2.5%；splay/pdfjs dec 是 z 更少。

`dec − inc` ≈ 分配出来、未经 Dup 的 RC 对象在拆毁时的那一次 Free（`JS_New*` 置 `rc=1` 不进 inc）。splay q 的差更大（2.47M vs z 1.23M），与 ⑦ 占用同向，仍不是「z 多 Dup」。

### 2.2 按族（读合并，防归因伪影）

z 把融合 `get_loc0_field` 的 `loadOwned` 记在 prop；q 的 `OP_get_loc0` 在 other。prop inc 的 z>q **不是**多付。  
z 在 return 撤帧里 Free 参数窗；q 在 `OP_call` 返回后 Free（族=call）。公平尺 = **call+ret 合并 dec**。

| 案 | call+ret dec z/q | prop dec z vs q | cmp dec |
|---|---:|---|---|
| typescript | **0.917**（46.9 / 51.1） | 57.55 vs 58.44 | 2.088M = 2.088M |
| box2d | **1.001** | 32.18 vs 33.00 | 0.391 vs 0.379 |
| splay | **1.000** | 3.065 vs 3.124 | 7040 = 7040 |
| earley-boyer | **0.888** | **33.937 = 33.936** | 36.634M = 36.634M |
| pdfjs | **0.920** | 5.55 vs 5.69 | 4.172 vs 4.175 |

cmp 发数五案整数级相等。比较路径**没有**额外 RC 对。

### 2.3 用户码发数（同一套字节码）

| | z `get_field` | q `get_field` | z `call_method` | q `call_method` |
|---|---:|---:|---:|---:|
| TS | 52.41M | 53.58M | 11.00M | 11.04M |
| box2d | 30.61M | 31.43M | 1.73M | 1.73M |
| EB | 26.43M | 26.43M | — | — |

差 1–3% = 融合/opt-chain 切分，不是多走一遍查找。

---

## 3. 逐惯用法：差异 + 税

税 = 「z 比对位 q 多付的真 `dup`/`free` 对 × 动态次数」。0 = 已镜像。负 = q 多付。

### I1. `JS_VALUE_GET_OBJ` 走访不加引用

| | |
|---|---|
| q | `GET_FIELD_INLINE` 19124：`p = JS_VALUE_GET_OBJ(obj)`，沿 `p->shape->proto` 走；**不** Dup 接收者。身份比较 20305：`JS_VALUE_GET_OBJ(op1) == JS_VALUE_GET_OBJ(op2)`。`OP_put_field` 19191 同。 |
| z | `objectFromValueTrustedExpression`（`object_ops.zig:2706`，注释钉 19123–19125）；`qjsGetFieldFastSlotOrAbsent` 用接收者位型走 shape；`same()` / `refHeaderAssumeObject` 比身份。 |
| 差 | **无。** 热叶不 `dup` 接收者再 walk。 |
| 税 | **0** |

### I2. 栈上 borrow（`arg_buf = argv`）

| | |
|---|---|
| q | 17841：`argc >= arg_count` 且无 `COPY_ARGV` → `arg_buf = argv`。`done:` 只 Free `local_buf..sp`（callee 局部+运算栈），**不** Free `arg_buf`。拥有者是调用方槽，`OP_call*` 18233–18234 返回后 Free。 |
| z | `pushExactSimpleFrame`：`args` 切片就是调用方窗；`ownership.storage = .borrowed`。撤帧 `for (frame.args) \|v\| v.free` = q 的 post-call Free，时点挪到 callee `done:`，**次数相同**。 |
| 差 | 时点不同（return vs call 尾），净 RC 同。普查 call+ret 合并已对上。 |
| 税 | **0** |

### I3. `cur_func` 不 Dup

| | |
|---|---|
| q | 17843：`sf->cur_func = (JSValue)func_obj` 位拷。`done:` **不** `JS_FreeValue(cur_func)`。 |
| z | `takeSourceSlot` 把调用方栈上那份挪进 `current_function`，撤帧 `current_function.free`。调用方槽写成 `undefined`，不会二次 Free。 |
| 差 | 拥有者从「调用方栈」换成「帧字段」，**仍是那一份**。 |
| 税 | **0** |

### I4. `this_obj` / `new_target` 形参，帧上不另立拥有者

| | |
|---|---|
| q | `JSStackFrame` 无 `this` / `new.target`。`OP_push_this` 直接 `JS_DupValue(this_obj)`（17933–17951）。 |
| z | 每帧存 `this_value`。sloppy 全局：`global.value()`（`JSValue.object` **不** bump）+ `.borrowed`。method：`take` 接收者槽。`new_target` 已是冷盒 / `aliases_function`。`OP_push_this` 对 `frame.this_value` Dup，与 q 对形参 Dup 同次。 |
| 差 | **多一次存**（帧宽度），**不多一次 RC**。 |
| 税 | RC **0**。存字段税归 call/return 占用账，不是本层刀。 |

### I5. `var_refs` 借闭包数组

| | |
|---|---|
| q | 17844：`var_refs = p->u.func.var_refs`。 |
| z | `ownership.var_refs = .borrowed`，`var_refs = captures`。撤帧不 `freeCell`。 |
| 差 | 无。 |
| 税 | **0** |

### I6. `GET_LOC` / `GET_ARG` 恒 Dup（栈槽要拥有）

| | |
|---|---|
| q | 18589+：`*sp++ = JS_DupValue(ctx, var_buf[i])`。`GET_ARG` 18562 同。 |
| z | `value_slot.loadOwned` = `dup()`。 |
| 差 | **无。** 这是宪法「要拥有才 Dup」，不是免 RC。 |
| 税 | **0**（两边都付）。**停** emit 期消这对：q 无「`GET_LOC_BORROW`」。 |

### I7. `GET_FIELD`：Dup 槽 + Free 接收者

| | |
|---|---|
| q | 19131 `JS_DupValue(pr->u.value)`；19157 `JS_FreeValue(sp[-1])`。接收者走访用 I1，不加引用。 |
| z | `_ = value.dup()`；`releaseObjectAssumeObjectNeedsDestroyDuringActiveBytecode`。`get_loc0_field` **仍** `loadOwned` 再 tail `get_field`。 |
| 差 | 融合只并 handler，RC 纪律与分立的 `get_loc0; get_field` 相同 = **与 q 分立形相同**。 |
| 税 | **0**。窗 79.3M 对是**两边都付**的上界，不是偏差矿。 |

### I8. `PUT_FIELD` / `set_value`：新值已拥有，只 Free 旧槽

| | |
|---|---|
| q | 19198：`set_value(ctx, &pr->u.value, sp[-1])` 吃栈上那份；再 `JS_FreeValue(obj)`。 |
| z | `storeValueAsIntPair(slot, value)` 注释：consumes the stack's ref；`releaseRefCountedNeedsDestroy` 旧值；再 release 接收者。 |
| 差 | 无。 |
| 税 | **0** |

### I9. `PUT_LOC` 吃栈 / `SET_LOC` Dup 再留栈

| | |
|---|---|
| q | `put_loc*`：`set_value(..., *--sp)`。`set_loc*`：`set_value(..., JS_DupValue(sp[-1]))`。 |
| z | `replaceOwnedDuringActiveBytecode` / `replaceBorrowedDuringActiveBytecode`（先 `dup` 再换）。 |
| 差 | 无。 |
| 税 | **0** |

### I10. 比较 / `instanceof`：比完 Free 操作数（last-ref）

| | |
|---|---|
| q | `OP_CMP_EQ` 对象臂：`GET_OBJ` 比指针（I1）+ `JS_FreeValue` 两侧。字符串臂 `js_string_eq` 后 Free。`js_operator_instanceof` 16015–16016 Free 两侧。 |
| z | 叶用 `same` / `isHTMLDDA`（不 Dup）；last-ref 走 framed 兄 Free。普查 **cmp dec 贴合、发数相等**。 |
| 差 | 无（混型 0.55G 是 handler 形，不是多 Dup）。 |
| 税 | **0** |

### I11. `OP_push_this` / `THIS_FUNC`：对形参/帧字段 Dup 一份到栈

| | |
|---|---|
| q | 17950 `JS_DupValue(this_obj)`；17981–17983 `JS_DupValue(sf->cur_func)`。 |
| z | `op_push_this` / `op_special_object` current_function：`this_value.dup()` / `current_function.dup()`。 |
| 差 | 无。 |
| 税 | **0** |

### I12. `argc < arg_count` / `COPY_ARGV`：q **多**付一对

| | |
|---|---|
| q | 17848–17851：`arg_buf[i] = JS_DupValue(argv[i])`。`done:` Free 这份；`OP_call` 再 Free 调用方槽。每缺参调用每实参 **+1 Dup +2 Free**。 |
| z | `pad_args`/`move_args`：`memcpy` 后把源槽写成 `undefined`（挪，不 Dup）。撤帧 Free 一份。 |
| 差 | z **少**一对。语义净所有权同（源槽已空，不会双 Free）。 |
| 税 | **负**（q 更密）。不是「补齐 z」。 |

### I13. L0 `initCallBindings` 默认 `.dup`

| | |
|---|---|
| q | `JS_Eval` / 顶层 `JS_Call` 常带 `JS_CALL_FLAG_COPY_ARGV`，this/func 由调用方拥有。 |
| z | `zjs_vm.zig:605` `initCallBindings` 走默认 `CallBindingModes{ .dup, .dup }`（`frame.zig:233–234`）。热 `pushExactSimpleFrame` / `setupSimpleInlineEntry` **不用**这条，用 take/borrow。 |
| 差 | 每脚本入口最多 +2 对。 |
| 税 | **噪声**（每案 1 次量级）。不是 zoo 热尺。 |

### I14. apply 幽灵 `native_caller` Dup

| | |
|---|---|
| q | `Function.prototype.apply` 是一层 native `JSStackFrame`，`cur_func` 位拷。 |
| z | `attachApplyForwardNativeCaller`：`entry.native_caller = apply_obj.value().dup()`，专为栈迹顺序。 |
| 差 | 每个 apply-forward 位点 +1 对。 |
| 税 | 发数 ≪ `call_method`。不构成落后案主尺。 |

---

## 4. 停：emit 期借用消除

前序 `MECH-L3-RCFRAME` 把 79.3M 窗写成 beyond-qjs 矿。改令后：

- qjs **没有** `GET_LOC_BORROW` / `GET_FIELD` 不解接收者的形。
- z `get_loc0_field` 的 RC 边与 q 的分立 `get_loc0; get_field` **相同**，这是对齐，不是漏对齐。
- 再消这对 = 新机制，本轮暂停。

---

## 5. 地基两句（RC 纪律读法）

| 提示 | 本层 |
|---|---|
| splay ⑦ +204M | 拆毁走访占用（`SPLAY-BR-⑦` IRON）。z inc **少 18%**。不是「z 多 Dup」。 |
| TS ④a return 5.70G | 撤帧存/走访占用。return 发数同量级；call+ret dec z **还少 8%**。不是「z 多 Free」。 |

帧上仍比 q 多付的是 **字段存**（`planned_stack_bytes`、软件 `call_depth`、`this_value` 槽、Entry 256B），属于 call/return 占用账。那不是 RC 纪律偏差，本层不立项、不复活 `call-entry-slim`。

---

## 6. 可开的对齐清单（诚实）

按宪法「镜像 qjs 的免 RC」筛选后：

| 项 | 开？ | 原因 |
|---|---|---|
| I1–I11 热径 | **不要** | 已镜像，税 0 |
| I12 缺参拷 argv | **不要** | z 已经更省；改回去是加税 |
| I13 L0 默认 dup | 可记，不可当刀 | 每评测 1 次 |
| I14 apply 幽灵 | 可记，不可当刀 | 发数不够 |
| emit 窗消 +1−1 | **停** | q 无对应形 |
| 帧字段少存 | **不归本层** | 不是 RC；slim 已 REJECT |

**本层无「补齐 qjs 免 RC」的可开刀。** 落后案的 RC 次数不是密度源。

---

## 7. 工装 / 纪律

- 普查 env：`ZJS_RC_CENSUS=<tsv>`；未设永久 off。
- 占用 ≠ 独占。⑦ / ④a 的 q CASE 采不到 ≠ z 多 Dup。
- 禁外提 `call_method` `0x3f0`。
- `call-entry-slim` / `limit-slim` REJECT。
- put 壳不是本层。
- 数字非裁决。
