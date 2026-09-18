# 18 — Fun Native ABI（`src/abi/`）

FNABI v1 冻结面（2026-08-26，FN-M0F）。单一事实源是 `fun_native_abi.zig`；C 头由 `c_header_text` 在 comptime 拼出，`gen_header.zig` 写回 `fun_native_abi.h`。`src/tests/abi_layout.zig` 钉尺寸/偏移、无隐式 padding、头文件新鲜度、`@cImport` 往返。

这不是 zjs 进程内的 dlopen loader。owner D8 已删除 `src/runtime/plugin.zig` / `src/binding/ffi.zig`；artifact 加载在外部 `fun` 仓。zjs 只消费描述符 → `NativeCallPlanSpec` → `NativeEntry`。演进：append-only minor（`struct_size` + 新 id）或 major bump。下一个空闲签名 id 为 **33**。

目标合同（设计 §11.4）：64 位指针、小端、定宽整数、IEEE-754、平台 C ABI。公开结构无隐式 padding：`reservedN` 必须写 0，loader 验零。

## 文件级类型与常量表（`fun_native_abi.zig`）

### 版本

| 符号 | 值 | 含义 |
| --- | --- | --- |
| `plugin_abi_major` / `plugin_abi_minor` | 1 / 0 | 插件描述符主/次 |
| `fast_call_abi` | 1 | 叶调用约定世代 |
| `value_abi_leaf` | 0 | 叶插件声明的 value_abi；managed 边界直接用 zjs `JSValue`，不另造 FunValue |
| `async_epoch_bits` | 64 | AsyncToken epoch：per-Runtime u64，永不复用（M0D） |

Value ABI 不在本文件编号，是（表示契约 version, `JSValue.abi_encoding_revision`）。`layout_epoch` 与契约文档版号解耦。

### 标量

`FunStatus` u32、`FunExportKind`/`FunCallKind`/`FunSignatureId`/`FunMarshalPolicyId` u16。`FunNativeCodePtr = ?*const fn () callconv(.c) void`：泛代码指针，引擎按描述符原型再 `@ptrCast`，**禁止 `void*`**。

### `status` / `export_kind` / `call_kind` / `marshal_policy`

- status：`ok=0`、`invalid_argument=1`、`out_of_memory=2`、`unsupported=3`、`cancelled=4`、`internal=5`。
- export：`function=1`、`class=2`、`const_i32/f64/bool/utf8=3..6`。
- call：`leaf_static=1`、`leaf_stateful=2`、`leaf_method=3`、`managed_fixed=4`、`managed_generic=5`、`async_entry=6`。NB2 后 managed 热路径是单一 `ManagedFn` 原型；`fn0..fn4` 降级为 SDK 便利，不再是 ABI 面。
- marshal：仅 `canonical=1`（严格，无隐式 ToBoolean/ToString；i32 接受双精度整数 Number）。

### `Signature` / `signatures`

`struct { name: [:0]const u8, id: FunSignatureId }`。id 0 保留/非法。表 1–32：

| id | 名 | 备注 |
| --- | --- | --- |
| 1–6 | VOID_TO_VOID … F64_TO_VOID | 叶数值子集（SDK M0I 已实现） |
| 7 | BOOL_TO_BOOL | |
| 8 | STATE_F64_TO_VOID | 带 state |
| 9–11 | SELF_TO_F64 / SELF_F64_TO_VOID / SELF_F64_F64_TO_VOID | 原 v1 method |
| 12–14 | BUFFER_* | 缓冲租约 |
| 15–19 | MANAGED_VALUE0–4 | 固定元数 managed |
| 20 | GENERIC | managed generic |
| 21–25 | ASYNC_VALUE0–4 | |
| 26 | STATE_I32_TO_I32 | NB2 phase B 追加 |
| 27–28 | STRING_I32_TO_I32 / STRING_I32_TO_STRING | K prim_self：`fn(*const String, i32)` |
| 29–32 | SELF_I32_TO_I32 / SELF_TO_I32 / SELF_I32_TO_VOID / SELF_TO_VOID | K2 method，self = NativeObject payload |

### 不透明类型（§13.1）

插件侧只持指针、不解引用、不取 sizeof：`FunCallContextV1`、`FunAsyncTokenV1`、`FunBufferLeaseV1`、`FunPluginInitHostV1`、`FunManagedHostV1`、`FunAsyncHostV1`、`FunRuntimeTargetInfoV1`、`FunErrorSinkV1`、`FunClassDescriptorV1`（字段级内容属 FN-M1B）。

### 公开 `extern struct`（字段顺序即 ABI）

`ZjsJSValue { payload: u64, tag: i64 }` — 16 字节 tagged，与 `src/core/value.zig` 的 `JSValue` 同布局。C 名 `zjs_JSValue`；除非 `FUN_NATIVE_NO_JSVALUE_ALIAS`，另 typedef `JSValue`（避免与 quickjs.h 撞名时可关）。

`FunUtf8RefV1 { data, length, reserved0 }` — 非拥有 UTF-8 视图，`reserved0` 必 0。

`FunFunctionDescriptorV1`：`struct_size`、`call_kind`、`signature`、`marshal_policy`、`reserved0`、`flags`、`target`。

`FunExportDescriptorV1`：`struct_size`、`reserved0`、`name`、`kind`、`metadata_kind`、`reserved1`、`metadata`、`metadata_size`、`reserved2`。

`FunCreateInstanceFnV1` / `FunShutdownFnV1` — C 调用约定函数指针。

`FunPluginDescriptorV1`：ABI 版本、feature 位、package/module/build_id、exports 数组、`create_instance` / `begin_shutdown` / `destroy_instance`。桌面动态库只导出一个符号：`fun_native_plugin_v1`；静态平台用 `fun_native_plugin_v1_<artifact-prefix>`。

`FunPluginInitContextV1`：`init_host`、`host_context`、`target_info`、`error_sink`。

`public_structs` 元组给出头文件发射顺序。`CField` 把 Zig 字段名锁到 C 拼写。

`c_header_text` 是 comptime 生成的完整头，与仓库内 `.h` 必须字节级一致。

---

## `fun_native_abi.zig` 函数

### `cBody` (`src/abi/fun_native_abi.zig:247`)

- **签名**：`fn cBody(comptime T: type, comptime c_name: []const u8, comptime fields: []const CField) []const u8`。
- **作用**：按 Zig `extern struct` 字段顺序拼 `typedef struct` 体，防止 C 表与 Zig 声明漂移。
- **实现**：`@typeInfo(T).@"struct"`。字段数不等 → `@compileError`。`inline for` 比较 `zf.name` 与 `cf.name`，不等也 compileError。拼接 `c_type name;`。
- **所有权 / 错误 / 调用**：纯 comptime 字符串。只被 `c_header_text` 用来发射 `zjs_JSValue` 与五个 Fun* 结构。布局正确性另由 `@cImport` 往返证明。

### `defineU` (`src/abi/fun_native_abi.zig:260`)

- **签名**：`fn defineU(comptime name: []const u8, comptime v: u64) []const u8`。
- **作用**：发射 `#define NAME Nu`。
- **实现**：`comptimePrint("{d}u", .{v})`。
- **所有权 / 错误 / 调用**：`c_header_text` 里所有版本 / status / kind / `FUN_SIG_*` 宏。

---

## 生成的 C 头 `src/abi/fun_native_abi.h`

**不要手改。** 从 repo 根 `zig run src/abi/gen_header.zig` 或 `zig build gen-abi-header`。下面按导出宏/结构讲，对应设计 §11–§15。

### 头卫与包含

`FUN_NATIVE_ABI_H`。`#include <stdint.h>`。C++ `extern "C"`。注释写明冻结规则与「无隐式 padding」。

### 版本宏

- `FUN_PLUGIN_ABI_MAJOR` 1、`FUN_PLUGIN_ABI_MINOR` 0、`FUN_FAST_CALL_ABI` 1。
- `FUN_ASYNC_EPOCH_BITS` 64。Value ABI 只在注释里说明，不设宏（叶插件 `value_abi = 0`）。

### 标量 typedef

`FunStatus`、`FunExportKind`、`FunCallKind`、`FunSignatureId`、`FunMarshalPolicyId`。`FunNativeCodePtr` = `void (*)(void)`。

### 状态 / 导出 / 调用 / marshal 宏

与 Zig `status` / `export_kind` / `call_kind` / `marshal_policy` 同值：`FUN_STATUS_*`、`FUN_EXPORT_*`、`FUN_CALL_LEAF_STATIC`…`FUN_CALL_ASYNC`、`FUN_MARSHAL_CANONICAL`。

### 签名宏 `FUN_SIG_*`

id 1–32，名字与 `signatures` 表一致。`FUN_SIG_VOID_TO_VOID` … `FUN_SIG_SELF_TO_VOID`。id 0 不定义（保留非法）。

### 不透明 typedef

`typedef struct FunCallContextV1 FunCallContextV1;` 等同 Zig `opaque {}`：插件不得取大小。清单：CallContext、AsyncToken、BufferLease、PluginInitHost、ManagedHost、AsyncHost、RuntimeTargetInfo、ErrorSink、ClassDescriptor。

### `zjs_JSValue` / `JSValue` 别名

```c
typedef struct zjs_JSValue {
    uint64_t payload;
    int64_t tag;
} zjs_JSValue;
#ifndef FUN_NATIVE_NO_JSVALUE_ALIAS
typedef zjs_JSValue JSValue;
#endif
```

公开 ABI **不**引入独立 `FunValue`（owner 裁决）。与 quickjs.h 同进程时定义 `FUN_NATIVE_NO_JSVALUE_ALIAS`。

### 函数指针 typedef

`FunCreateInstanceFnV1(const FunPluginInitContextV1*, void** out_instance) → FunStatus`。`FunShutdownFnV1(void* instance)`。前向声明 `struct FunPluginInitContextV1` 以便在结构体完整定义前引用。

### `FunUtf8RefV1`

`const uint8_t* data; uint32_t length; uint32_t reserved0;`。非拥有。`reserved0` 写 0。

### `FunFunctionDescriptorV1`

`struct_size`、`call_kind`、`signature`、`marshal_policy`、`reserved0`、`flags`、`target`。引擎调用前把 `target` 转成描述符声明的原型。

### `FunExportDescriptorV1`

`struct_size`、`reserved0`、`name`、`kind`、`metadata_kind`、`reserved1`、`metadata`、`metadata_size`、`reserved2`。function 的 metadata 指向 `FunFunctionDescriptorV1`；class 指向仍 opaque 的 `FunClassDescriptorV1`。

### `FunPluginDescriptorV1`

版本四元组（major/minor/fast_call/value_abi）、`required_features` / `optional_features`、三个 `FunUtf8RefV1` 名、`exports`/`export_count`、三个生命周期函数指针。`reserved0`/`reserved1` 必 0。

### `FunPluginInitContextV1`

`struct_size`、`reserved0`、`init_host`、`host_context`、`target_info`、`error_sink`。Host 表 v1 对插件 opaque。

### `FUN_NATIVE_EXPORT` / 入口符号

Windows `__declspec(dllexport)`，否则 `visibility("default")`。桌面动态库**恰好一个**导出：

`FUN_NATIVE_EXPORT const FunPluginDescriptorV1* fun_native_plugin_v1(void);`

静态平台加 artifact 前缀以免多 plugin 撞符号。zjs 树内不再有消费该符号的 loader。

---

## `gen_header.zig`

### `main` (`src/abi/gen_header.zig:9`)

- **签名**：`pub fn main() !void`。
- **作用**：把 comptime 头写进 `src/abi/fun_native_abi.h`。
- **实现**：单线程 Io，`Dir.cwd().writeFile`，`sub_path = "src/abi/fun_native_abi.h"`，`data = abi.c_header_text`。打印字节数。
- **所有权 / 错误 / 调用**：覆盖已有文件。必须从仓库根运行。CI 用 `abi_layout.zig` 比新鲜度，不依赖本工具每次跑。`zig build gen-abi-header` 封装同一入口。

---

## `sdk.zig`（M0I 骨架）

职责（设计 §23）：从插件作者的自然 Zig 函数生成 C-ABI thunk、签名 id、marshal policy、`FunFunctionDescriptorV1`。本文件只实现叶数值子集（arity≤2，`i32`/`f64`/`void`）。其它形状必须 **compile error**，禁止静默落到 GENERIC（§23.4）。buffer/state/self/managed/async 属 FN-M1A+，加在**本文件**同一 schema，不另起表。SDK 经 fun 发给插件作者；放在 schema 旁边是因为 schema 是唯一事实源。

### `sigIdByName` (`src/abi/sdk.zig:22`)

- **签名**：`fn sigIdByName(comptime name: []const u8) abi.FunSignatureId`。
- **作用**：按表里的名字取冻结 id。
- **实现**：comptime 扫 `abi.signatures`，`mem.eql` 命中返回 `s.id`；否则 `@compileError("unknown signature name: " ++ name)`。
- **所有权 / 错误 / 调用**：仅 `signatureIdFor`。名字必须与 schema 完全一致。

### `signatureIdFor` (`src/abi/sdk.zig:34`)

- **签名**：`pub fn signatureIdFor(comptime F: type) abi.FunSignatureId`。
- **作用**：把 Zig fn 类型映射到 v1 签名 id；不在叶子集则编译失败。
- **实现**：`@typeInfo(F).@"fn"`。按 params.len / 参数类型 / 返回类型匹配 VOID_TO_VOID、I32_TO_I32、I32_I32_TO_I32、F64_TO_F64、F64_F64_TO_F64、F64_TO_VOID。其它 `@compileError`，文案指向 FN-M1A 与「fail the build, never auto-degrade」。
- **所有权 / 错误 / 调用**：`LeafExport` 的 `signature_id`。单测用 `add`/`halve` 钉 id 3 与 4。

### `LeafExport` (`src/abi/sdk.zig:56`)

- **签名**：`pub fn LeafExport(comptime func: anytype) type`。
- **作用**：对自然 Zig 函数生成 `callconv(.c)` thunk 与 `descriptor()`。
- **实现**：返回匿名 struct：`signature_id = signatureIdFor(F)`；`Prototype` 按 arity 0/1/2 选 C 原型；`thunk` 指向嵌套 `call`；`descriptor()` 填 `FunFunctionDescriptorV1`（`call_kind = leaf_static`、`marshal_policy = canonical`、`reserved0 = 0`、`flags = 0`、`target = @ptrCast(thunk)`）。arity>2 为 `unreachable`（`signatureIdFor` 已拒）。
- **所有权 / 错误 / 调用**：用法 `const Add = LeafExport(add); const desc = Add.descriptor();`。单测再 `NativeCallPlanSpec.fromFunctionDescriptor` 证明只走一条校验路径，并按 Prototype 直调 `target(2,3)==5`。

### `LeafExport.call` (`src/abi/sdk.zig:74`)

- **签名**：`fn call() callconv(.c) R`。
- **作用**：零参叶入口，转调原 Zig 函数。
- **实现**：`return func()`。
- **所有权 / 错误 / 调用**：地址存在 `thunk`；引擎按 Prototype 调用。无 JS 异常通道（叶路径）。

### `LeafExport.call` (`src/abi/sdk.zig:79`)

- **签名**：`fn call(a: info.params[0].type.?) callconv(.c) R`。
- **作用**：单参叶入口。
- **实现**：`return func(a)`。
- **所有权 / 错误 / 调用**：`halve` 走这条。

### `LeafExport.call` (`src/abi/sdk.zig:84`)

- **签名**：`fn call(a: info.params[0].type.?, b: info.params[1].type.?) callconv(.c) R`。
- **作用**：双参叶入口。
- **实现**：`return func(a, b)`。
- **所有权 / 错误 / 调用**：`add` 走这条。

### `LeafExport.descriptor` (`src/abi/sdk.zig:91`)

- **签名**：`pub fn descriptor() abi.FunFunctionDescriptorV1`。
- **作用**：填一份可交给 `NativeCallPlanSpec` 的 v1 函数描述符。
- **实现**：`struct_size = @sizeOf(FunFunctionDescriptorV1)`，其余见上。
- **所有权 / 错误 / 调用**：返回栈上值。`reserved0` 必须为 0，否则 `NativeCallPlanSpec.fromFunctionDescriptor` 返回 `PlanError.NonZeroReserved`；`flags` 不要求为 0，由 spec 原样透传。

### `add` (`src/abi/sdk.zig:109`)

- **签名**：`fn add(a: i32, b: i32) i32`。
- **作用**：SDK 单测用的自然 Zig 函数（wrapping add）。
- **实现**：`a +% b`。
- **所有权 / 错误 / 调用**：只在本文件 test。证明 I32_I32_TO_I32。

### `halve` (`src/abi/sdk.zig:113`)

- **签名**：`fn halve(x: f64) f64`。
- **作用**：SDK 单测用的 f64 叶函数。
- **实现**：`x / 2.0`。
- **所有权 / 错误 / 调用**：证明 F64_TO_F64。

---

## 覆盖核对

- 清单函数数: 12（`src/abi/fun_native_abi.zig` 2 + `src/abi/gen_header.zig` 1 + `src/abi/sdk.zig` 9）
- 本文标题覆盖: 12
- C 头导出结构/宏: 已按符号讲解（不在 TSV）
- 未覆盖: 无
