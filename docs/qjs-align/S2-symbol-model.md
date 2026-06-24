# S2 — symbol-model（Option B：symbol 值 = 指向 refcounted body 的指针）

> Phase 1 第二个 commit。依赖 S1。上位：`KEYSTONE-DESIGN.md`。**设计/实现规格，非代码。**

## 目标与边界

- 把符号从 zjs 的 **非 refcount 裸 atom-id** 回退到 qjs 的 **refcounted JSAtomStruct\***（qjs `JS_MKPTR(JS_TAG_SYMBOL, JSString*)`，
  `__JS_FreeValueRT` case `JS_TAG_SYMBOL → JS_FreeAtomStruct`，quickjs.c:6492-6496）。
- **必须单大 commit**（非原子拆分 = 每个仅作为 value 可达的符号瞬间可回收 → ===/UAF）。
- heap-scan（`seedSymbolRootsFromRuntimeHeldValues`/`sweepUnrootedUniqueSymbols`）**此处不删**，留作冗余 belt-and-suspenders，
  到 S3 才删。

## 为何 Option B（不是 Option A）

- **Option A**（审计的天真版）：`AtomTable.dup(atom_id)` 需要 `rt`。`JSValue.dup()` **无 rt 参数**、**814 个 .dup() 站点**
  依赖此签名（codex 确认 814）。→ **侵入、非字面"不可实现"**（codex 更正：runtime/context dupValue wrapper 已存在
  runtime.zig:1516-1519/context.zig:614-616，理论上可全仓库改签名或路由）——但代价大，故选 Option B。
- **Option B**（唯一可行且忠实 qjs）：`Tag.symbol` 变成**指向 refcounted String body 的指针**，rc 在内在 `gc.Header`。
  `dup()/free()` 走既有 header 路径、**零签名改动**。这正是 qjs 的 `JSString*`（symbol body 即一个 JSString，hash 字段复用为 weakref_count）。

## 改动清单（带 file:line 锚点）

### 1. symbol 值变 refcounted body 指针
- `JSValue.symbol(...)`（value.zig:228-230）：payload 从裸 atom-id 改为 `@intFromPtr(body)`。
- `asSymbolAtom()`（value.zig:369）+ **~36 调用者**（codex 更正，非 ~15；property_ops.zig:85、call.zig:2513、
  builtin_glue.zig:453/481、promise_ops.zig:1112、value_ops.zig:637、object.zig:3247、collection.zig:93、runtime.zig:1507 …）：
  从 body 指针解 atom-id（经 **`String.internAtom`**——codex 更正：**无 `ensureAtom`**，需新增该 helper 或改用 internAtom）。
- **【lockstep】** symbol 移入 refcount 前缀 band；**同 commit** 改 comptime tag_assertions（value.zig:80-99）——把 symbol 从
  非-refcount 列移入连续 refcount range（否则 @compileError，这是有用的 guard）。

### 2. Symbol() 创建时物化 body
- zjs 的 String 是相对 AtomTable entry 的**懒物化 cache** → `Symbol()` 必须**强制物化** body 并把 table-entry 生命周期系在它上。
- 审计确认：生产环境唯一 value-symbol 创建者是 `qjsSymbolConstructorCall`（返回 rc=1）；其余 `newValueSymbol` 都在 test block。

### 3. 全局注册表（Symbol.for / keyFor）
- 加 `AtomKind.global_symbol`（第 4 变体），更新**所有 ~7 处非穷尽 kind==.symbol guard**：internSymbol assert（atom.zig:911）、
  internRegisteredValueSymbol（921）、isRegisteredSymbol（938）、sweepUnrootedUniqueSymbols（946）、free() 穷尽 switch（976-981）、
  indexEntry（1200-1203）、predefinedId（1250-1253）——global_symbol 路由到 symbol_index、`JS_AtomGetKind` 映射 global_symbol→KIND_SYMBOL。
- `Symbol.for → internSymbol(kind=global_symbol)`；`keyFor` 返回 body iff kind==global_symbol。

### 4. weak 资格 + description
- `canBeHeldWeakly := isObject() or (asSymbolAtom() and kind==.symbol)`——预定义 well-known 符号（atom.zig:290-304）**保持
  kind=.symbol**（weak 可持）；`Symbol.for` 结果是 .global_symbol（排除 weak）。
- description：复刻 qjs 的「空 wide-char 无描述」marker；**删** `registry_prefix='Symbol.for:'` 和 `undefined_description='Symbol.undefined'`
  sentinel（这**顺带修两个 latent zjs bug**）。

### 5.【强制·stopgap】weakref_count
- 加 weakref_count 到 symbol entry（或在有 weak holder 时 pin slot）；**rc==0 且 weakref_count==0 才释放 body**（镜像 js_weakref_free）。
- 必需，因为 S2 还没删 heap-scan，但符号已 refcount 化——一个仅被 WeakRef 持有的符号不能在 rc==0 时回收 slot。

## 绿桥（为何单 commit + 仍绿）

- **关键·绝不拆分**：翻 value-refcounting + 重写 ~30 注册/反注册站点 + 加 weakref_count **同一 commit**。非原子拆分使每个仅作为
  value 可达的符号瞬间可回收 → ===/UAF 横扫 built-ins/Symbol。
- heap-scan **不删**，作冗余 keepalive：即使某 store 路径忘了 dup，scan 仍兜底（scan 只 ADD root、从不 free 一个 refcount-live 符号）。
  → 符号"refcount + heap-scan 双覆盖"，无害；S3 才删 scan。
- store 路径（codex 更正）：`setOptionalValueSlot`（object.zig:2665）本身是 **take-owned/free-on-overwrite**，dup 由**调用者**
  供给（object_ops.zig:649、vm_value.zig:637）——整链仍 dup-on-store/free-on-overwrite，符号 refcount 化后**自动平衡**。
  `symbolPrimitiveValue`/**`symbolDescriptionValue`**（codex 更正：object_ops.zig:3199/3189，zjs **无** js_thisSymbolValue）的
  dup/free 从 no-op 静默变真 retain/release，但本就成对平衡。
- 跨 realm **低风险**：`$262.createRealm` 共享单一 runtime/atom 表（call.zig:1646），registry 已进程级。

## 风险（高危，对应 keystone 风险登记 #2/#3/#4）

| 风险 | 缓解 |
|---|---|
| 符号非原子拆分 → ===/UAF；tag_assertions 会 @compileError 挡 | 同 commit 翻 refcount + 改 assertions + 留 scan |
| weakref_count 缺失 → WeakRef-only-held 符号 slot 被回收（时序可掩盖，仅 force-GC 抓） | 本 commit 加 weakref_count stopgap |
| 跨 realm Symbol.for dedup 要跨 realm 单指针 | registry 走 global_symbol kind；共享 atom 表 |

## 验收（结构对照 + 门）

- **结构对照**：symbol 值 vs qjs `JS_MKPTR(JS_TAG_SYMBOL, JSString*)`；free vs `__JS_FreeValueRT` JS_TAG_SYMBOL 臂；
  weakref_count vs `js_weakref_free` 的 `rc==0 && weakref_count==0`。
- **门**：built-ins/Symbol 98/98、WeakRef 29/29、WeakSet 85/85、FinalizationRegistry 47/47、Symbol/for 9/9、keyFor 8/8 +
  全 `0/49775` default + `-Dzjs_nan_boxing=true`。（weakref_count 时序缺陷 test262 可能漏 → S3 起加 force-GC 兜底。）
