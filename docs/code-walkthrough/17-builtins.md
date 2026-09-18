# 17 — 其余内建：标准全局、分发、JSON/Date/Math、RegExp、Atomics、集合、强制转换

11–16 册已经覆盖 VM opcode、调用约定、属性、Array/String、Promise/模块。本册是 **exec 里剩下的标准内建**：realm 安装、`NativeEntry` 分发，以及 JSON/Date/Math/Number/RegExp/URI/Atomics/Buffer/集合/Reflect/强制转换/Error/Function/print。

## 先读这两条流水线

### 1. `standard_globals` 怎么装满一个 realm

```
JSRuntime.create
  → 复制默认 installer 回调到 Runtime（尚未创建 realm/global）
JSContext.create / createWithOptions
  → ensureStandardGlobalsRegistered + core context 构造
  → globalObject → exec 的 contextGlobal 物化回调
  → rt.installStandardGlobals(global) → installStandardGlobals(rt, global)
  → rt.internal_builtins = &internal_builtins.table
  → installStandardConstructors          // Object.prototype → … → Iterator
  → AUTOINIT: Math/JSON/Reflect/Atomics/performance/navigator
  → 全局函数 parseInt/eval/encodeURI/…
  → initializeInitialShapes + publishStandardArrayPrototype
```

方法不是按名字注册到运行时表，而是 comptime `InternalEntry` → `NativeEntry`，安装时只把 `(domain, id)` 盖到函数对象上。首次 get 才把 AUTOINIT 占位物化成真正的 C_FUNCTION。

### 2. `builtin_dispatch` 怎么映射 NativeEntry

```
op_call / nativeMethodFastDispatch
  → 从函数 payload 一次取出 NativeEntry + Realm
  → kind:
       leaf / method_leaf   标签命中则直接 C 调用 + 装箱
       managed              callManagedFromWindow（无 env）
       needs_env            NativeCallEnvironment + nativeCall()
  → 失败：JSValue exception 哨兵 ⇔ pending exception
```

`.host` domain 在 `internal_builtins.table` 里是空的：`eval` 必须保持无 id（直接 eval 靠编译器认身份）；`btoa`/`gc` 等走 host 开关。

### 3. Atomics.waitAsync 线程规则

外线程的 `Atomics.notify` **只允许**：改 `AtomicsWaiter.completion` 标量、`cond.signal`、`signalHostCompletion`。  
**禁止**：分配、改 Promise、改 RealmRef、跑 GC。  
owner 线程的事件循环才 `processExpiredAtomicsWaiters` → typed job → `atomicsRunAsyncWaiterCompletion` 结算 Promise。

## 子文档

| 文件 | 内容 |
| --- | --- |
| [17-globals-dispatch.md](17-globals-dispatch.md) | `standard_globals`、`builtin_dispatch`、`builtin_glue`、`internal_builtins`、`open_bindings` |
| [17-json-date-math.md](17-json-date-math.md) | JSON / Date / Math / Number |
| [17-regexp-uri.md](17-regexp-uri.md) | RegExp 三件套 + URI |
| [17-atomics-buffer.md](17-atomics-buffer.md) | Atomics.waitAsync、ArrayBuffer/DataView 记录 |
| [17-collection-reflect.md](17-collection-reflect.md) | Map/Set/Weak*、Reflect/Proxy.revocable |
| [17-coercion-error.md](17-coercion-error.md) | 强制转换、value_ops、Error/Function/print、`exceptions.zig` |

## 和相邻册的边界

- Array/String/Iterator **不**在本册（15）。
- Promise/async/module **不**在本册（16），但 `Atomics.waitAsync` 的 Promise 结算借用 `promise_ops`。
- regexp **库**在 19；本册是 JS 内建与运行时适配。
- 事件循环如何 `waitForAtomicsHostSignalUntil` 在 18。

## 覆盖核对

- 清单函数数: 1031（子文档标题之和；另含零函数文件 `src/exec/exceptions.zig`）
- 本文标题覆盖: 0（索引，函数在子文档）
- 未覆盖: 无
