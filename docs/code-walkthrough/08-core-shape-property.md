# 08 — Shape、属性槽、class payload 与函数对象

本册覆盖 `src/core/` 里对象模型的「形状 / 属性 / class 身份 / 各 class payload」一层：隐藏类怎么转移、属性槽怎么存、AUTOINIT 怎么物化、NativeEntry 怎么成为唯一原生分发记录、VarRef 怎么做闭包别名、Promise 对象状态和 `exec/promise_ops.zig` 怎么分工。

对象本体（`Object` 分配、exotic、payload 访问器）在 [07-core-object.md](07-core-object.md)。本册不改 `src/`。

权威：源码 + ECMA-262。QuickJS 是对照实现。布局数字以 `docs/perf/object-shape-design.md` 与各文件 comptime assert 为准。

## 本册文件

| 文件 | 覆盖 |
| --- | --- |
| 本文件 | 分层地图：shape 转移、AUTOINIT、NativeEntry 布局与生命周期、VarRef、Promise vs exec |
| [08-core-shape.md](08-core-shape.md) | `shape.zig`（91） |
| [08-core-property.md](08-core-property.md) | `property.zig`（32）+ `module_auto_init.zig`（0，只讲类型） |
| [08-core-object-payloads.md](08-core-object-payloads.md) | `object_payloads.zig`（83）+ `object_gc.zig`（1） |
| [08-core-array-class.md](08-core-array-class.md) | `array.zig`（9）+ `class.zig`（56，含1个测试辅助） |
| [08-core-function-native.md](08-core-function-native.md) | `function.zig`（12）+ `host_function.zig`（40）+ `native_entry.zig`（11）+ `native_object.zig`（6） |
| [08-core-typed-array.md](08-core-typed-array.md) | `typed_array.zig`（81）+ `typed_array_names.zig`（3） |
| [08-core-collection.md](08-core-collection.md) | `collection.zig`（49） |
| [08-core-regexp-promise-varref.md](08-core-regexp-promise-varref.md) | `regexp.zig`（7）+ `promise.zig`（11）+ `var_ref.zig`（15）+ `generator_state.zig`（30） |

合计清单函数 537；`module_auto_init.zig` 零函数，类型在 property 分册讲。

## 1. Shape 转移

`Shape` 是 GC 管理的隐藏类：同一条结构属性序列 + 同一 prototype 身份共享一个 Shape。固定头 64 字节（含 8 字节 `identity`），后面是内联 FAM：

```text
[Shape 64B][Property × prop_size][u32 hash buckets]
```

属性记录在前、桶在后，和 QuickJS（桶在前）相反，这样 `props()` 是相对 Shape 指针的常数偏移。`shape.Property` 是 8 字节 packed（`hash_next:26` + `flags:6` + `atom_id`）。对象上的 `property.Entry` 数组只存值侧，下标必须与 shape 属性数组 1:1。

**添加属性**走转移，不是每次哈希整表：

1. 热路径 `Registry.tryCachedTransition`：用 `transitionHash(parent.hash, atom, flags)` 在 runtime 的 shape-hash 表里找已经存在的子 Shape。命中则 `markShared`、把对象的 `shape_ptr` 换成缓存项、`dropUnshared` 旧父（未共享且不在 teardown/condemned 保护阶段时立即释放）。对齐 qjs `add_property` 的 `find_hashed_shape_prop` 命中腿（quickjs.c:9209-9222）。
2. 未命中走 `transitionPropertyUncached`：
   - **共享**父：按调用方给出的对象值数组容量 `cloneShape`，再 `appendProperty`，写 `transitionHash`，`rehashShape`。子 Shape 的 `prop_size` 必须等于对象真实值数组容量，不能继承父上被别的对象原地撑大的 `prop_size`。
   - **未共享**父：`reservePropertyAppend` 在容量不足时一次迁移到同时满足属性和含墓碑哈希容量的新块（足够时不迁移），再 `appendProperty`，hashed 时更新 hash。

**clone-before-mutate**：第二个持有者 `markShared` 之后，`shared` 永不清除。一般属性修改先调用 `prepareUpdate` 准备唯一且未 hashed 的布局；专用追加路径另有自己的共享检查和转移逻辑。`prepareUpdate` 的分支：hashed 且未共享则先摘哈希表；已共享则克隆。对齐 qjs `sh->header.ref_count != 1`。

**`identity`（PERF-SHAPE-ID）**：单调 u64，创建与受保护布局发生变化时刷新；prepareUpdate 还会提前刷新；grow-relocation（`relocateShape`）保留 identity（逻辑布局没变，只是地址变了）；`compactProperties` / `restorePropertyLayout` 发新 identity。站点缓存不能用指针当 guard：未共享 Shape 会在同一地址原地改。

**删除**不立刻压槽：`markPropertyDeleted` 从属性哈希链摘掉、atom 置 `null_atom`、`deleted_prop_count++`。枚举/查找跳过墓碑。`compactProperties` 在无共享、未 hashed、有墓碑时重建，保持存活项相对顺序，并同步对象值数组。

**原型**是 Shape 的一部分：`replacePrototypeAssumePrepared` 换 proto、重算 hash、发新 identity，并对 Shape→proto 做分代屏障。

属性快路径包括 `exec/property_direct.zig` 的无用户代码探测，以及 `vm_property_field.zig` 的站点 inline cache。`PropSiteCache` 由 VM 字段站点和宿主 `PropertySite` 共用：own-data 最多缓存两种 shape identity，另有单层原型数据与 native getter 分支；miss 后允许重新捕获，达到预算后退为 `.mega`。缓存存 identity/slot 等标量，不持有对象指针；shape 变更通过新的 identity 使旧缓存失效。

## 2. 属性槽与 AUTOINIT

`property.Kind` 对齐 qjs `JS_PROP_TMASK`：`data` / `accessor` / `var_ref` / `auto_init`。kind **不**存在值 cell 里，而在 shape 的 per-property flags（`Object.propFlagsAt`）。`Slot` 是 16 字节无标签 union（ReleaseFast/Small 下 comptime 钉死）；Debug/ReleaseSafe 有 Zig 安全 tag。

四臂：

| kind | 槽内容 |
| --- | --- |
| data | `JSValue` |
| accessor | `Accessor`：两个 `?*gc.Header`（getter/setter），缺省 = undefined |
| var_ref | `*VarRef`，读写自动解引用 `cell.pvalue`（全局词法 `let`/`const`、与帧共享） |
| auto_init | `AutoInitSlot` 两字：Realm 头低 2 位编码 `AutoInitId`，第二字是不可变 opaque |

`AutoInitId`：`prototype`（opaque=null）/ `module_ns`（`AutoInitModuleOwner*`）/ `prop`（intern 的 `AutoInit*`）。描述符由 `internAutoInit` 按 Runtime 生命周期 intern，地址稳定。物化时 `prepare_native_function` 只能给新函数补元数据，**禁止** retain/改拥有 AUTOINIT 槽的对象。

`module_auto_init.zig` 是无 Runtime 依赖的叶子契约：MODULE_NS 延迟导出走不可变 `AutoInitModuleOwner.resolve`。解析器返回新命名空间值或已有 export 的 `*VarRef`，从不快照 VarRef 当前值。一个 owner 服务同一模块的全部延迟导出（atom 在回调参数里），对齐 qjs `(module, property atom)`。

## 3. NativeEntry 布局与生命周期

NB2：内建、宿主、插件、native accessor 都解析成同一份 **48 字节 extern `NativeEntry`**。VM 稳态分发不看条目从哪来。字段偏移钉死（JIT 以后按偏移读 `target`/`kind`/`sig`/`class_id`）。

生命周期由拥有者管理：内建通常为静态表；宿主条目由 runtime 单独分配并记入 native_entries 列表。退役原地写 `kind = .retired` 并更新 epoch，不释放；正常缓存依赖条目在 runtime 清理前地址稳定。`clearExternalHostFunctions` 才释放所登记的宿主条目。

`Kind`：`managed` / `constructor` / `constructor_or_func` / `getter` / `setter` / `leaf` / `method_leaf` / `method_managed` / `retired=255`。`code()` 只擦除 target 指针类型，不验证其与 kind/sig 匹配。`EntryTable.get` 对 dense 前缀里的 retired 返回 null。

`NativeObject`（`native_object.zig`）是 `zjs.native.Class`：动态 class id，payload 臂是 opaque `self`（null=已 dispose）。`NativeType` 挂在 class record 上，不在对象里。

## 4. VarRef

内部 GC 节点，不是 JS Object。40 字节，对齐 qjs `JSVarRef`：

- **打开**：`pvalue` 别名活动帧槽；帧停在 generator 里时 `value` 持有拥有该槽的 generator 对象（`attachOpenOwner`），从不把打开边记成 `cell -> *pvalue`。
- **关闭**：`close` 把 `*pvalue` 拷进 `value`，`pvalue` 改指自己，分代屏障。打开帧结束、对象析构时关。
- 值**永远不是**另一个 cell：写入路径先解开。读热路径是裸 `*pvalue`。

`is_lexical` 管全局词法 TDZ；`is_deletable` 是 zjs 对 eval 绑定的簿记（qjs 用属性 CONFIGURABLE）。

## 5. Promise：对象状态 vs `exec/promise_ops.zig`

分层：

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 对象状态 | `core/promise.zig` + `PromisePayload` | 造 Promise 对象、fulfilled/rejected 快照、`withResolvers`、resolving function、把 reaction job 丢进 `core/jobs` |
| 抽象操作 | `exec/promise_ops.zig` | `PerformPromiseThen`、reaction 跑起来、species、静态 `Promise.*` 语义、与 VM/内建的衔接 |
| 任务队列 | `core/jobs.zig` | 原语；事件循环在 `runtime/event_loop.zig` 排空 |

`PromisePayload` 持有 `result`、`is_rejected`、subscriber 列表（`reactions` + capacity）、可选 reaction callback/arg、`atomics_wait_async`。core 构造路径不跑 thenable 吸收：`fulfilledWithPrototype` / `rejectedWithPrototype` 只写 result 标志。无共享 prototype 时在实例上 `defineNativeMethod` 装 `then`/`catch`（C_FUNCTION_DATA，调用方 realm）。

`enqueueReaction` 只是 `job_queue.enqueueFunc`。真正的 then/reaction 算法在 exec。

## 6. 其它本册角色（一句话）

- **array.zig**：数组下标判定 + 字面量构造（`OP_array_from` 的 MOVE 语义，不是 `new Array(n)`）。
- **class.zig**：进程级 class id + 每 Runtime 的定义表；标准 id 只读 plan 缓存，动态 id 用 pin/generation 防注销竞态。
- **object_payloads.zig**：各 class 的线外布局、`destroy`/`traceChildEdges`。RegExp 两字符串指针直接躺在 `ObjectStorage`。
- **object_gc.zig**：FinalizationRegistry 清理入队（sweep 不得分配；槽在 register 时预留）。
- **typed_array.zig**：AB/SAB/TA/DataView 的存储与元素编解码；不跑用户 `valueOf`。
- **collection.zig**：Map/Set 开链哈希；弱键走 identity，不是强边。
- **regexp.zig**：字面 character class 对单个 UTF-16 unit 的纯谓词。
- **generator_state.zig**：suspend 时驻留的帧/栈/catch-target；对齐 qjs `JSAsyncFunctionState`。

读函数条目时跟 `` (`file.zig:LINE`) `` 跳源码。源码与文档冲突，信源码。

## 覆盖核对

```
python3 docs/code-walkthrough/_check_coverage.py --docs 'docs/code-walkthrough/08-*.md' \
  src/core/object_payloads.zig src/core/object_gc.zig src/core/shape.zig src/core/property.zig \
  src/core/array.zig src/core/class.zig src/core/function.zig src/core/host_function.zig \
  src/core/native_entry.zig src/core/native_object.zig src/core/typed_array.zig \
  src/core/typed_array_names.zig src/core/collection.zig src/core/regexp.zig \
  src/core/promise.zig src/core/var_ref.zig src/core/generator_state.zig \
  src/core/module_auto_init.zig
```

结果：`docs 9 inventory 537 missing 0`。

- 清单函数数: 537（18 个文件；`module_auto_init.zig` 0 函数，类型在 [08-core-property.md](08-core-property.md)）
- 本文标题覆盖: 0（函数条目在子文件）
- 未覆盖: 无
