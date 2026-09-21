# 12 — RegExp 字面量（`vm_regexp.zig`）

文件职责：`op.regexp`（QuickJS `OP_regexp`，quickjs.c:18426）。从栈上拿走 `[pattern, compiled-bytecode]` 常量，用 **realm 固定的 regexp shape** 造新对象，不调用、不查阅可能被替换的全局 `RegExp` 构造器。

## 类型

无公开类型。私有构造走 `Object.createRegExpFromShape`。

### `constructCompiledLiteralInRealm` (`src/exec/vm_opcodes.zig:15`)

- **签名**：`fn constructCompiledLiteralInRealm( rt: *core.JSRuntime, global: *core.Object, source: core.JSValue, compiled_value: core.JSValue, ) !core.JSValue`。
- **作用**：服务 `op.regexp`：校验编译字节码字符串，在当前 realm 的固定 shape 上装配 RegExp 对象。
- **实现**：`compiled_value` 必须是非宽、非空的窄字符串，否则 `TypeError`。`contextForGlobal` 取 realm，`regexp_shape` 缺失也是 `TypeError`。把 `source` 与 compiled 放进 `rootValues` 窗口（构造可能 GC）。`createRegExpFromShape`；失败 `destroyFromHeader`。然后 `setRegexpSource` / `setRegexpCompiledBytecodeString`，返回 `object.value()`。
- **所有权 / 错误 / 调用**：调用方拥有 `source`/`compiled`；本函数把它们写进对象。根窗口覆盖分配。错误：`TypeError`、OOM。仅 `pushLiteral` 调用。

### `pushLiteral` (`src/exec/vm_opcodes.zig:40`)

- **签名**：`pub noinline fn pushLiteral( ctx: *core.JSContext, stack: *stack_mod.Stack, global: *core.Object, ) !void`。
- **作用**：`op.regexp` 的栈适配器：弹出 compiled 与 pattern，压入新 RegExp。
- **实现**：`pop` compiled，再 `pop` pattern（栈顶是编译字节码）。`constructCompiledLiteralInRealm`，`pushOwned` 结果。
- **所有权 / 错误 / 调用**：两次 pop 是所有权移动；成功后结果 owned 在栈上。错误原样上抛，由分发层的 catch 包装。唯一调用方是冷表 `t[op.regexp]`（`tailcall_dispatch_colds.zig:216`）。

## 覆盖核对

- 清单函数数: 2
- 本文标题覆盖: 2
- 未覆盖: 无
