# 14 — 属性读写、对象抽象操作、slot、class init

本册把一次属性访问从「不能跑用户代码的快探」写到「OrdinaryGet/Set、exotic、Proxy 陷阱、Object 内建」。权威仍是源码与 ECMA-262；QuickJS 行号是对照，不是标准。

## 本册文件

| 文档 | 源码 | 内容 |
| --- | --- | --- |
| 本文 | [`src/exec/property_ops.zig`](../../src/exec/property_ops.zig) | 薄包装与 ToPropertyKey atom 化 |
| [14-property-direct.md](14-property-direct.md) | [`property_direct.zig`](../../src/exec/property_direct.zig) | 无用户代码的 own/proto/global data 快探 |
| [14-object-ops.md](14-object-ops.md) | [`object_ops.zig`](../../src/exec/object_ops.zig) 前半 | 原型、闭包函数对象、构造 |
| [14-object-ops-objects.md](14-object-ops-objects.md) | 同上中段 | rest、generator、iterator、arguments |
| [14-object-ops-get-set.md](14-object-ops-get-set.md) | 同上后段 | OrdinaryGet/Set/Has/Delete/Define |
| [14-object-ops-proxy.md](14-object-ops-proxy.md) | 同上末段 | super/brand、Proxy 陷阱 |
| [14-object-builtin-ops.md](14-object-builtin-ops.md) | [`object_builtin_ops.zig`](../../src/exec/object_builtin_ops.zig) | `Object.*` native-record |
| [14-slot-ops.md](14-slot-ops.md) | [`slot_ops.zig`](../../src/exec/slot_ops.zig) | 帧 loc/arg/var-ref 槽 |
| [14-class-init-ops.md](14-class-init-ops.md) | [`class_init_ops.zig`](../../src/exec/class_init_ops.zig) | 内建 `super()` 构造 |

## OrdinaryGet / OrdinarySet 与 exotic

ECMA-262 把 `[[Get]]` / `[[Set]]` 分成 ordinary 对象与带内部方法的 exotic 对象。zjs 对齐 QuickJS `JS_GetPropertyInternal` / `JS_SetPropertyInternal`（`quickjs.c:8268` / `9707`）：**每一层都先 shape 探自己的槽，miss 才进 class/exotic 臂**。

**Ordinary 热路径**（`getPropertyValueFromObjectChain`，`object_ops.zig:3530`）：

1. `findOwnPropertySlotTrusted` 命中 `.data` → 直接返回槽值（borrowed 语义上的 owned 拷贝，值为 16 字节 tagged）。
2. 命中 `.accessor` → 调 getter；K3 native getter 走 `tryNativeAccessorCall`，否则 `callValueOrBytecodeSyncInternal`，receiver 保持原始值（原始类型读原型链时不装箱）。
3. `.auto_init` / `.var_ref` 不在热循环里物化，交给 `getOwnProperty`。
4. shape miss 且 `needsSlowPropertyAccess()` 为假 → 下一层原型。
5. 链走完 → `undefined`（`getValueProperty` 在 `quickjs.c:8355` 之后不再做 class-name 兜底）。

**Get 入口的 exotic 分流**（`getValueProperty`，`object_ops.zig:2478`），在走进普通链之前：

| 条件 | 行为 |
| --- | --- |
| private atom | `getPrivateValueProperty`：只看 own，没有就 brand TypeError |
| mapped arguments | 覆盖成活着的参数 cell |
| `class_id == proxy` | `getProxyProperty`（`get` trap + invariant） |
| TypedArray 且 shape miss | `typedArrayCanonicalGet`（元素不占 shape） |
| 无 exotic 的 Array | `length` / dense 下标 / own data |
| 无 exotic 的普通 object | own data |
| function-like 的 `caller`/`arguments` | 遗留兼容，outlined |

原型链上的 Proxy / TypedArray 不在入口处理，而在 `getSlowPropertyValueFromObject`：shape miss 之后才测 `class_id == proxy` 或 `isTypedArrayObject`。这保证「自己的数据属性」从不付 Proxy 税。

**Set**（`setValuePropertyWithThrow`，`object_ops.zig:2876`）同样先 private / 原始装箱 / Proxy / with-env / mapped args / TypedArray / Array `length` / dense append，再 **一次** `setOrDefineOwnDataPropertyForSimpleSet`（对应 qjs 单次 `find_own_property`），然后访问器、原型链上的第一个 Proxy、最后 `Object.setProperty`。失败是否抛由 `force_throw` 或调用方严格性决定（qjs `JS_PROP_THROW`）。

**Has / Delete** 走另一条：Has 对 module namespace 只测导出键（避免 TDZ 的 GetOwnProperty）；Delete 对 Proxy 走 `deleteProperty` trap，再按 qjs `js_proxy_delete_property` 读 target 描述符与可扩展性。

## `property_direct` 与字段站点缓存

属性快路径包括 `exec/property_direct.zig` 的无用户代码探测，以及 `vm_property_field.zig` 的站点 inline cache。`PropSiteCache` 由 VM 字段站点和宿主 `PropertySite` 共用：own-data 最多缓存两种 shape identity，另有单层原型数据与 native getter 分支；miss 后允许重新捕获，达到预算后退为 `.mega`。缓存存 identity/slot 等标量，不持有对象指针；shape 变更通过新的 identity 使旧缓存失效。

`property_direct.zig` 本身不维护 `PropSiteCache`，只判断当前对象是否能安全直接读写 data 槽；站点的缓存捕获、命中和退化由 `vm_property_field.zig` 及其调用方处理。

快探失败（`null` / `.slow` / `.proxy` / `.getter`）时，调用方必须落到 `getValueProperty` / `setValueProperty`。约束：

- 不调 getter、不进 Proxy trap、不做 ToPropertyKey 强制转换。
- 拒绝 private、accessor、var_ref、auto_init、`hasExoticMethods`、Proxy。
- Array 的 `length` 与整数下标一律 slow（exotic `[[DefineOwnProperty]]` / 长度语义）。
- 全局写成功后打 `generationalBarrier`：全局对象长寿，新值是 old-to-young 边。

## Object 内建 vs 值级 `object_ops`

| | `object_ops.zig` | `object_builtin_ops.zig` |
| --- | --- | --- |
| 角色 | 值级抽象操作 | `Object` / `Object.prototype` 的 native-record |
| 调用方 | opcode、Proxy、其他内建、本册 builtins | `builtin_dispatch` 经 `internal_entries` |
| 签名 | 显式 `ctx` / `output` / `global` / caller frame | `HostError!JSValue` 或 `!?JSValue` |
| 例子 | `getValueProperty`、`proxyAwareOwnPropertyDescriptor` | `Object.assign`、`hasOwnProperty` |

`defineProperty` / `isExtensible` / `setPrototypeOf` / `keys` / `values` / `entries` / `defineProperties` 因为 opcode 或其他 exec 模块也调用，实现留在 `object_ops`（或 `call_runtime`），`objectCallForNativeRecord` 只做转发。`toString` / `toLocaleString` 在 `string_ops`。

`property_ops.zig` 更薄：对象输入已是 `*Object` 时直接调 core；`getPropertyValue` 才做 `expectObject`。可观察的 VM/Proxy 分发不在这里。

---

## `property_ops.zig`

文件头约定：对象/值参数 borrowed；getter 与按值读取返回 **一个 owned `JSValue`**；成功的 define 按 core `Object` 契约 dup 或转移。属性键转换在本地拥有临时 atom 与字节缓冲。对照 QuickJS 通用属性操作 `quickjs.c:8210-9172` 与 `9663` 起。

`expectObject` 是 `core.value_semantics.expectObject` 的 re-export，清单无独立函数行。

### `getProperty` (`src/exec/property_ops.zig:14`)

- **签名**：`pub fn getProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !core.JSValue`。
- **作用**：对已知对象做 own+原型的 core 级 `getProperty`，不经 VM/Proxy 分发。
- **实现**：忽略 `rt`，直接 `object.getProperty(atom_id)`。这是 core 形状走查，不是 `object_ops.getValueProperty`。
- **所有权 / 错误 / 调用**：返回 owned 值。错误来自 core（OOM、访问器抛错等）。调用方是不需要完整 `[[Get]]` 的内部路径。

### `setProperty` (`src/exec/property_ops.zig:19`)

- **签名**：`pub fn setProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void`。
- **作用**：把 `value` 写进对象的 core `setProperty`。
- **实现**：`object.setProperty(rt, atom_id, value)`。不做严格模式失败转 TypeError，也不走 Proxy trap。
- **所有权 / 错误 / 调用**：`value` borrowed，所有权按 core 槽语义。`ReadOnly` / `NotExtensible` 等原样上抛。

### `defineDataProperty` (`src/exec/property_ops.zig:23`)

- **签名**：`pub fn defineDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void`。
- **作用**：以 `writable/enumerable/configurable = true` 定义 own 数据属性。
- **实现**：`object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true))`。
- **所有权 / 错误 / 调用**：描述符不兼容或不可扩展时 core 报错。给内部安装数据槽用，不是 `Object.defineProperty`。

### `deleteProperty` (`src/exec/property_ops.zig:27`)

- **签名**：`pub fn deleteProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool`。
- **作用**：删除 own 属性，返回是否成功。
- **实现**：`object.deleteProperty(rt, atom_id)`。不抛；不可配置属性返回 `false`。
- **所有权 / 错误 / 调用**：无 JS 异常。完整 `[[Delete]]`（含 Proxy）在 `object_ops.deleteValueProperty`。

### `getPropertyValue` (`src/exec/property_ops.zig:31`)

- **签名**：`pub fn getPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue`。
- **作用**：把值当成对象再读属性；全局对象读 `"globalThis"` 时直接返回该对象。
- **实现**：`expectObject(value)`；若 `object_value.isGlobal()` 且 atom 名为 `"globalThis"`，返回 `object_value.value()`，否则 `getProperty`。
- **所有权 / 错误 / 调用**：非对象 → `expectObject` 的 TypeError。这是 **无 VM 的** 属性读，不能替代 `getValueProperty`（无 getter/Proxy 的完整语义时可用）。

### `optionalGetPropertyValue` (`src/exec/property_ops.zig:37`)

- **签名**：`pub fn optionalGetPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue`。
- **作用**：可选链风格：`null`/`undefined` 读属性得到 `undefined`，否则当对象读。
- **实现**：忽略 `rt`。nullish 直接 `undefinedValue()`；否则 `expectObject` + `getProperty`。
- **所有权 / 错误 / 调用**：非对象非 nullish 仍 TypeError。不实现完整 `?.`（那是 VM opcode）。

### `propertyIn` (`src/exec/property_ops.zig:44`)

- **签名**：`pub fn propertyIn(rt: *core.JSRuntime, object_value: core.JSValue, key_value: core.JSValue) !core.JSValue`。
- **作用**：`in` 的简化实现：对象上是否有该键，并对 `"toString"` 做兼容真值。
- **实现**：`expectObject`；`propertyKeyAtom` 转键；`object.hasProperty(key)`；若未找到且 atom 名为 `"toString"` 则视为找到。返回布尔 `JSValue`。
- **所有权 / 错误 / 调用**：临时 atom 由 `propertyKeyAtom` 拥有。完整 `[[HasProperty]]`（Proxy/exotic）在 `hasValueProperty`。`"toString"` 特判是遗留兼容，不是 spec `HasProperty`。

### `propertyKeyAtomIfReady` (`src/exec/property_ops.zig:56`)

- **签名**：`pub fn propertyKeyAtomIfReady(value: core.JSValue) ?core.Atom`。
- **作用**：`propertyKeyAtom` 的零分配前缀：值已经是不需 intern 的属性键时返回 atom。
- **实现**：符号 → `asSymbolAtom`；字符串且 `atom_id != no_atom_id` → 该 atom；非负 int32 → `atomFromUInt32`；否则 `null`。臂必须与 `propertyKeyAtom` 对齐。
- **所有权 / 错误 / 调用**：不分配、不抛。`objectHasOwnPropertyDirect` 用它跳过 ToPropertyKey。

### `propertyKeyAtom` (`src/exec/property_ops.zig:68`)

- **签名**：`pub fn propertyKeyAtom(rt: *core.JSRuntime, value: core.JSValue) !core.Atom`。
- **作用**：把任意 JS 值收成属性键 atom（ToPropertyKey 的 atom 半截，不做对象 ToPrimitive）。
- **实现**：符号 / 已是字符串（`internAtom`）/ 非负 int32 与 `IfReady` 相同；否则 `appendValueString` 进临时 `ArrayList`，再 `rt.internAtom`。
- **所有权 / 错误 / 调用**：`bytes` 在 `defer deinit`。对象值应先经 `object_ops.toPropertyKeyValue`。OOM 上抛。

## 覆盖核对

本文件（`property_ops.zig`）：

- 清单函数数: 9
- 本文标题覆盖: 9
- 未覆盖: 无

本册全部 `14-*.md`（清单 301）：

| 源文件 | 清单 | 分册 |
| --- | --- | --- |
| `property_ops.zig` | 9 | 本文 |
| `property_direct.zig` | 32 | [14-property-direct.md](14-property-direct.md) |
| `object_ops.zig` | 194 | [14-object-ops.md](14-object-ops.md) 等四篇 |
| `object_builtin_ops.zig` | 42 | [14-object-builtin-ops.md](14-object-builtin-ops.md) |
| `slot_ops.zig` | 21 | [14-slot-ops.md](14-slot-ops.md) |
| `class_init_ops.zig` | 3 | [14-class-init-ops.md](14-class-init-ops.md) |

```sh
python3 docs/code-walkthrough/_check_coverage.py \
    --docs 'docs/code-walkthrough/14-*.md' \
    src/exec/property_ops.zig src/exec/property_direct.zig \
    src/exec/object_ops.zig src/exec/object_builtin_ops.zig \
    src/exec/slot_ops.zig src/exec/class_init_ops.zig
```

输出：`docs 9 inventory 301 missing 0`。
