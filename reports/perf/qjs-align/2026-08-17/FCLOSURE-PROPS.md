# FCLOSURE-PROPS — 创建链二段（length/name + lazy prototype）

日期：2026-08-17。lane **w1:pS**。**w46 候件。**  
分支 `grok/fclosure-props` @ **b4eb69dc**，基 `main@62552228`。件 `/tmp/wt-fclosure-props`。  
对照 RF `/tmp/fclosure-props-zjs-base`（同 main，无本刀）。数字 **非裁决用**（CPU **16**）。

锁源：pQ [`EARLEY-TREES-INSN.md`](/tmp/lanes/EARLEY-TREES-INSN.md) §2.1。  
一段（`grok/earley-trees` / 生产校验·`kind()`·`ensureVarRefsCapacity`）已另案。本单只对账两件属性发布。

布局线封存令仍在，不合。聚簇 `grok/earley-cluster` @ **a5772141**（EB 三 pad 同号正 + crypto 解除红线，封存资产升值），见 [`EARLEY-CLUSTER.md`](/tmp/lanes/EARLEY-CLUSTER.md) §7。

---

## 0. 判决

**有差，已忠实对齐。不宣 win，不合 main。**

| | qjs | 战前 z | 本刀 |
|---|---|---|---|
| length+name | `js_function_set_properties` → `JS_DefinePropertyValue` ×2 | `Descriptor.data` 96B 绕路 + `defineOwnPropertyAssumingNew` + `functionNameValueFromAtom`（多一次 `isPublicSymbol`） | `JS_AtomToString` 形 `toStringValueForPush` + CreateProperty miss/`add_property` 数据臂 |
| prototype | `JS_DefineAutoInitProperty(PROTOTYPE, WRITABLE)`，`JS_DupContext(ctx)`，`opaque=NULL` | `autoInitRealmForDefinition` 走 bytecode/native/global；`appendPreparedPropertyEntry` 再 dup atom + `atomIsArrayIndex` | 创建 `ctx` 直传；named `add_property` 臂（预定义 `prototype`，非下标） |

`JS_SetConstructorBit` **不对齐成对象位**：z 的可构造性是 `fb.hasPrototype() ∧ functionKind==normal`（`construct.zig`），加对象位是新字段，不是本单。可观察 `new fn` / `.prototype` 与 q 同。

---

## 1. 逐指令对账

### 1.1 `js_function_set_properties`（quickjs.c:5853-5861）

```
JS_DefinePropertyValue(ctx, func_obj, JS_ATOM_length, JS_NewInt32(ctx, len), JS_PROP_CONFIGURABLE);
JS_DefinePropertyValue(ctx, func_obj, JS_ATOM_name, JS_AtomToString(ctx, name), JS_PROP_CONFIGURABLE);
```

`JS_DefinePropertyValue` = `JS_DefineProperty(..., flags|HAS_VALUE|HAS_C|HAS_W|HAS_E)` 再 `JS_FreeValue(val)`。  
新鲜函数 `find_own_property` miss → `JS_CreateProperty` 非 exotic 臂（10215-10266）：`prop_flags = flags & C_W_E`（仅 CONFIGURABLE）→ `add_property` → `pr->u.value = JS_DupValue(val)`。

战前 z 多出来的：

1. 96B `Descriptor` 再 `flagsFromDescriptor` / `slotFromDescriptor`（后者再 `dup`）  
2. `defineOwnPropertyAssumingNew` 的 exotic/extensible assert 后仍走通用 `addProperty`  
3. `functionNameValueFromAtom` 在无 prefix 时仍探 `isPublicSymbol`（q 这条路径是纯 `JS_AtomToString`）

本刀：`defineOwnDataValueAssumingNew` = 上述 CreateProperty 数据臂；name 走 `AtomTable.toStringValueForPush`（`__JS_AtomToValue(..., force_string)`）。临时值直接进槽（dup+free 终态相同）。`length`/`name` 是预定义非下标原子 → `caller_holds_atom_ref` + `named_put_no_index`。

### 1.2 `JS_DefineAutoInitProperty`（quickjs.c:10648-10675 + js_closure 17408-17415）

```
JS_SetConstructorBit(ctx, func_obj, TRUE);
JS_DefineAutoInitProperty(ctx, func_obj, JS_ATOM_prototype,
                          JS_AUTOINIT_ID_PROTOTYPE, NULL, JS_PROP_WRITABLE);
```

`DefineAutoInitProperty`：tag 检查 → `find_own_property` 已有则 `abort` → `add_property((flags & C_W_E) | AUTOINIT)` → `realm_and_id = JS_DupContext(ctx) | id`，`opaque = NULL`。

战前 z 多出来的：

1. `autoInitRealmForDefinition`：`bytecodeFunctionRealmContext` → native → `contextForGlobalIncludingConstructing`。q 只 `JS_DupContext(ctx)`。  
2. 通用 `appendPreparedPropertyEntry`：atom dup/free + `atomIsArrayIndex`（`prototype` 两者都不需要）。

本刀：`defineFunctionPrototypeAutoInit(rt, ctx, WRITABLE)`，`retainPrototype(&ctx.header)` = DupContext | PROTOTYPE，`opaque=NULL`，同一 named add_property 臂。

---

## 2. 尺

### 2.1 earley-only FW（主尺，CPU16 ABBA n=4）

A=`/tmp/fclosure-props-zjs-base` B=`/tmp/fclosure-props-zjs-knife`。原始 `/tmp/fclosure-props/fw.json`。

| | Δ insn | Δ cyc | ratio cyc | Δ refill |
|---|---:|---:|---:|---:|
| **earley-only** | **−2.39B** | **−112M** | **0.9978** | +40M |
| earley-boyer 合凳 | −202M | −24M | 0.9964 | +1.8M |

insn 明显下降 = 去掉 Descriptor / realm 查找 / 多余 atom 探，不是少干活。cyc 同号微负。refill 反向只记疑点。

### 2.2 门

| 门 | 结果 |
|---|---|
| `zig build test-exec --seed 0` | **481/481** |
| `zig build test262-smoke --seed 0` | **15/15** |
| Function/arrow 切片 1567（built-ins/Function + language/{expressions,statements}/function + arrow-function） | **0 errors** |
| `git diff --check` | PASS |
| CLI 冒烟 `length`/`name`/`prototype.constructor` | 过 |

未跑全量 test262-gate / 全套 `zig build test`。未 3-pad（本刀非布局线）。

---

## 3. 未动

- `atoms.kind(func_name)` 取名（一段 / earley-trees 范围，不在本令）  
- 对象 `is_constructor` 位  
- handler / musttail / RC / bypass / 形态特判  
- 岛 / `.text.zjs.hot`

未合 main。未 push。
