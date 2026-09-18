# 01 — binding 聚合

`src/binding/root.zig` 是 binding 层聚合边界：允许暴露 core/binding 声明，禁止依赖 CLI。CLI 与仓内测试经 `src/root.zig` / `src/internal_root.zig` 进来。

`prop_name.zig`、`property_site.zig`、`binding.zig`（`NativeBinding`）已删除。

---

## `src/binding/root.zig`

几乎全是类型别名。句柄、字符串、字节视图的生命周期与 core 相同，本文件不加一层所有权。

### 类型与 re-export

| 名字 | 来源 | 备注 |
| --- | --- | --- |
| `JSRuntime` / `JSValue` / `Object` | core | `Object` 是真对象，不是门面 opaque。 |
| `GCStats` / `GCPauseDistribution` | core | `gcStats()` / `gcPauseDistribution()` 的快照。 |
| `JSContext` | `context.zig` | 门面。 |
| `JSValueHandle` / `LocalHandle` / `HandleScope` / `WeakPersistent` / `WeakPersistentValue` | core | 公共别名在 `zjs.value.*`。 |
| `RuntimeOptions` / `RuntimeMemoryUsage` / `ContextOptions` / `Eval*` / `DataPropertyOptions` / `PropertyAccessOptions` / `PropertyDescriptor` / `FunctionCallOptions` / `ErrorOptions` / `ScriptEvalOptions` / `SharedArrayBufferRef` / `OpcodeProfile` | core | 选项与统计。 |
| `default_stack_size` / `default_gc_threshold` | `core.runtime` | 默认栈与 GC 阈值。 |
| `native` | `native.zig` | `zjs.native`（仅 `managed`）。 |
| `JSString` / `JSBytes` | `JSValue.String` / `Bytes` | `string` / `bytes` 命名空间再包一层。 |
| `bytes.BytesError` | `JSValue.Bytes.Error` | |

测试钉住：`JSValue` 上没有 `Scope`/`Local`/`Persistent`/`Weak`（句柄在 `zjs.value`）、本模块**没有** `NativePin` / `Atom` / `pinValueForNative`。

### `activateOpcodeProfile` (`src/binding/root.zig`)

- **签名**：`pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile`。
- **作用**：把 opcode 剖析器接到给定缓冲区（或关掉）。
- **实现**：`return core.profile.activate(profile);`
- **所有权 / 错误 / 调用**：设置线程局部活动指针并返回此前的指针，不拥有、清空或释放 profile。公共 `root.activateOpcodeProfile` 会先安装 opcode 名称提供者再调这里。
