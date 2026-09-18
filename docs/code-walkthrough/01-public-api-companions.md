# 01 — 公共 API 旁路与内部根

`src/root.zig` 旁边的内部编译根与平台时钟。嵌入方不从这些文件进引擎；CLI 与仓内测试会碰到它们。

---

## `src/internal_root.zig`

编译根链的中段：`src/root.zig` ⊂ `src/internal_root.zig` ⊂ `src/all_tests.zig`。CLI 对着这个文件编。

### 类型与 re-export

| 名字 | 含义 |
| --- | --- |
| `public_api` | 公共 `root.zig` 模块，用来对照「内部多暴露了什么」。 |
| `native` | `src/native.zig`。 |
| `platform_clock` | 单调/墙上时钟。CLI 自己的模块图碰不到 `src/platform_clock.zig`，所以从这里转口。 |
| `RuntimeError` / `HostError` | `exec.exceptions` 的 error set。 |
| `JSRuntime` / `JSContext` / `JSValue` | 与公共门面同一批类型；`JSContext` 来自 `js_context.zig`。 |
| `Object` | **core** `Object`，不是门面 `zjs.object.Object`（后者是 opaque）。文件级 test 断言它等于 `core.Object`、带 `create`，而 opaque 类型没有 `create`。 |
| `Descriptor` / `Atom` / `NativePin` / `GCPolicy` / `GCStats` | core 类型；公共 root **不**导出 `Atom` / `NativePin`。 |
| `JSValueHandle` / `LocalHandle` / `HandleScope` / `WeakPersistent` / `WeakPersistentValue` | 句柄族。公共拼写走 `zjs.value.*`。 |
| `JSString` / `JSBytes` | 内部拼写；门面走 `zjs.value.String`。 |
| `EvalOptions` / `EvalTiming` / `DataPropertyOptions` | 选项类型。 |
| `RuntimeMemoryUsage` | core 内存用量记录，包含账户统计和按类别估算的字节字段。 |
| `core` / `parser` / `simple_token` / `bytecode` / `exec` / `libs` / `runtime` / `compiler` | 整层模块。公共 root 故意没有这些。 |
| `sort_erased` | 类型擦除堆，非嵌入 API。 |

文件级 `test` 块：确认内部 `Object` 有 `create`，而 `public_api.object.Object` 没有；再把各层模块拉进编译。

### `printSmallInlineProbe` (`src/internal_root.zig:54`)

- **签名**：`pub fn printSmallInlineProbe() void`。
- **作用**：按环境开关输出 small-inline 探测计数，供内部 CLI 使用。
- **实现**：调用 exec.small_inline.printProbe；当前助手仅在 ZJS_INLINE_PROBE 存在且非空时通过 std.debug.print 输出 prep、take 和整数百分比，不将变量内容当作文件路径，也不写独立探测文件。公共 embedder root 不导出此名。
- **所有权 / 错误 / 调用**：本包装只转发，不返回 I/O 错误；是否启用、写往何处及失败处理由 exec 助手决定，不能由这个 void 包装推断所有写入都成功。

---

## `src/platform_clock.zig`

跨平台单调钟 / 墙上钟。CLI 根模块到不了这个文件（`zjs.zig` 曾内联一份 `monotonicNanos`），内部根把它转口出去。

### `io` (`src/platform_clock.zig:3`)

- **签名**：`fn io() std.Io`。
- **作用**：拿到全局单线程 `std.Io`，给 Timestamp API 用。
- **实现**：`return std.Io.Threaded.global_single_threaded.io();`
- **所有权 / 错误 / 调用**：返回全局 Io 实例的接口值，不创建或销毁独立事件循环；两个读钟入口直接使用它，elapsedNanosSince 经 monotonicNanos 间接使用。

### `monotonicNanos` (`src/platform_clock.zig:10`)

- **签名**：`pub fn monotonicNanos() u64`。
- **作用**：读取 std.Io 的 awake 时钟，供诊断及同一时钟域的耗时计算；不是 Unix 时间戳。
- **实现**：`Timestamp.now(io(), .awake).raw.toNanoseconds()`；`<= 0` 则 0，否则 `@intCast`。
- **所有权 / 错误 / 调用**：本包装没有显式分配或可恢复错误返回；非正读数钳为 0。正值转为 u64 没有上界饱和分支，不能把它描述为所有溢出都自动钳位。

### `elapsedNanosSince` (`src/platform_clock.zig:18`)

- **签名**：`pub fn elapsedNanosSince(start: u64) u64`。
- **作用**：用当前 awake 时钟纳秒值与 start 计算非负时间差。
- **实现**：`end = monotonicNanos()`；`end > start` 则相减否则 0。
- **所有权 / 错误 / 调用**：start 应来自同一时钟域；相等或 end 小于 start 都返回 0，不报告时钟异常。不等待指定时间，不可混用 realtimeMicros 的墙钟值。

### `realtimeMicros` (`src/platform_clock.zig:24`)

- **签名**：`pub fn realtimeMicros() i64`。
- **作用**：Unix epoch 以来的墙上微秒。
- **实现**：`Timestamp.now(io(), .real).raw.toMicroseconds()`。
- **所有权 / 错误 / 调用**：返回有符号墙钟值，不钳为正数、不保证单调或每次唯一，也没有失败回退到 1 的逻辑；Runtime 的随机种子包装另行处理零值。不宜用来替代 awake 时钟计算运行耗时。
