# 01 — 公共 API 旁路

`src/root.zig` 旁边的平台时钟。嵌入方不从这些文件进引擎；CLI 会碰到它们。

---

## `src/platform_clock.zig`

跨平台单调钟 / 墙上钟。CLI 根模块到不了这个文件（`zjs.zig` 曾内联一份 `monotonicNanos`），引擎根把它转口出去。

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
