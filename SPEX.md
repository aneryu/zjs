# SKILL.md — C → Zig（0.16.0）迁移规范

## 目标

将 C 项目迁移到 Zig（固定版本 **0.16.0**），实现：

- 内部逻辑 Zig 化（类型安全、显式内存、显式错误）
- C ABI 边界最小化
- 可维护、可测试、可演进

---

## 0. 基本原则（必须遵守）

1. **内部代码必须是 Zig 风格，不是“C + 语法糖”**
2. **所有权必须显式：谁分配，谁释放**
3. **错误必须显式：error set，不用隐式错误码**
4. **指针必须收敛：内部优先 slice**
5. **C ABI 仅存在于边界层**
6. **固定使用 Zig 0.16.0，不混用旧教程或 master API**

---

## 1. 类型映射规范（C → Zig）

| C 写法 | Zig 推荐写法 | 说明 |
|---|---|---|
| `char* + len` | `[]const u8` | 字节串 / 字符串视图 |
| mutable buffer | `[]u8` | 可写切片 |
| nullable pointer | `?*T` | 可能为空 |
| non-null pointer | `*T` / `*const T` | 非空单对象指针 |
| `void*` | `*anyopaque` / `?*anyopaque` | C 边界使用 |
| array pointer + len | `[]T` / `[]const T` | 内部优先 slice |
| C string | `[:0]const u8` / `[*:0]const u8` | NUL 结尾 |
| ABI struct | `extern struct` | 保证 C ABI |
| internal struct | `struct` | 普通 Zig 结构 |
| bit layout struct | `packed struct` | 仅在必须控制位级布局时使用 |

### 强制规则

- 内部禁止长期保留 `[*c]T`
- 内部禁止传播 `void*`
- 内部禁止使用“裸指针 + 长度”作为主要接口
- 到达 Zig 内部后，应尽快把 C 指针转换成 slice
- 字符串参数默认优先使用 `[]const u8`

### 推荐示例

```zig
fn parse(input: []const u8) !Result { ... }

fn fill(buf: []u8) void { ... }

fn maybeUse(ptr: ?*Node) void { ... }
```

---

## 2. 内存管理规范（核心）

Zig 不会替你隐藏内存分配。所有需要分配内存的逻辑，都必须明确 allocator、所有权和释放责任。

### 2.1 分配规则

所有需要分配内存的函数必须接收：

```zig
allocator: std.mem.Allocator
```

#### 禁止

- 函数内部偷偷挑选 allocator
- 在库函数里直接绑定全局分配器
- 返回需要释放的内存但不说明由谁负责释放

### 2.2 所有权规则

| 返回值 | 含义 |
|---|---|
| `[]u8` | owned，调用方负责 `allocator.free()` |
| `[]const u8` | 通常是 borrowed view，不可释放，除非文档另有说明 |
| `*T` | 需要说明生命周期归属 |
| `?*T` | 同上，且可为空 |

### 2.3 文档要求

每个会分配内存或返回借用视图的函数，都必须写明所有权：

```zig
/// Returns owned memory. Caller must free with the same allocator.
fn buildMessage(allocator: std.mem.Allocator) ![]u8 { ... }

/// Returns a borrowed slice valid during self lifetime.
fn name(self: *const User) []const u8 { ... }
```

### 2.4 defer / errdefer 模式

分配后立刻绑定清理逻辑。

```zig
const std = @import("std");

fn makeBuffer(allocator: std.mem.Allocator, n: usize) ![]u8 {
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);

    @memset(buf, 0);
    return buf;
}
```

调用方：

```zig
fn run(allocator: std.mem.Allocator) !void {
    const buf = try makeBuffer(allocator, 4096);
    defer allocator.free(buf);

    // use buf
}
```

### 2.5 规则

- 每个 `alloc` 之后必须立刻考虑释放路径
- 成功后交给调用方，就在文档中写清 caller owns
- 同一 allocator 分配的内存，应由同一 allocator 释放
- 不要返回指向栈内存的 slice / pointer
- 不要把 arena 分配结果伪装成长期 owned 对象

### 2.6 allocator 选择策略

| 场景 | 推荐 allocator |
|---|---|
| 库代码 | 由调用方传入 |
| CLI / 短生命周期流程 | arena allocator |
| 固定上限临时缓冲 | fixed buffer allocator |
| C 互操作 | `std.heap.c_allocator`（必要时） |
| 单元测试 | `std.testing.allocator` |

### 2.7 Agent 输出代码时必须解释

- allocator 从哪里来
- 谁拥有返回值
- 谁负责释放
- 错误路径是否有清理逻辑

---

## 3. 错误处理规范

Zig 内部错误处理应使用 `error{...}!T`，不要继续沿用 C 的错误码风格。

### 3.1 内部 API 标准写法

```zig
const ParseError = error{
    InvalidInput,
    Overflow,
};

fn parse(input: []const u8) ParseError!Result {
    if (input.len == 0) return error.InvalidInput;
    if (input.len > std.math.maxInt(i32)) return error.Overflow;
    return .{ .value = @intCast(input.len) };
}
```

### 3.2 强制规则

- 内部函数优先返回 `error{...}!T`
- 错误集合尽量明确，不要滥用 `anyerror`
- 不要用返回码 + out-param 表达内部逻辑
- 不要无理由使用 `catch unreachable`

### 3.3 禁止写法

```zig
fn parse(input: []const u8, out: *Result) c_int
```

这类写法只能保留在 C ABI 边界，不能作为内部主接口。

### 3.4 C 边界适配模式

```zig
const std = @import("std");

const Result = extern struct {
    value: i32,
};

const ParseError = error{
    InvalidInput,
    Overflow,
};

fn parseZig(input: []const u8) ParseError!Result {
    if (input.len == 0) return error.InvalidInput;
    if (input.len > std.math.maxInt(i32)) return error.Overflow;
    return .{ .value = @intCast(input.len) };
}

fn mapError(err: ParseError) c_int {
    return switch (err) {
        error.InvalidInput => -1,
        error.Overflow => -2,
    };
}

export fn parse_c(ptr: ?[*]const u8, len: usize, out: ?*Result) c_int {
    const p = ptr orelse return -1;
    const o = out orelse return -1;

    o.* = parseZig(p[0..len]) catch |err| return mapError(err);
    return 0;
}
```

### 3.5 规则总结

- Zig 内部：显式错误集合
- C 边界：适配为错误码
- 不要把 C 风格错误处理扩散回 Zig 内部

---

## 4. C 互操作规范

迁移目标不是“把整个项目都写成半 C 半 Zig”，而是把 C ABI 收敛在少数边界文件中。

### 4.1 推荐目录结构

```text
src/
  core.zig        # 纯 Zig 业务逻辑
  memory.zig      # allocator / 生命周期逻辑
  c_api.zig       # extern / export / C ABI 适配
  main.zig        # 可执行程序入口
```

### 4.2 边界层职责

`c_api.zig` 负责：

- `extern`
- `export`
- C 指针类型
- C 错误码
- `void*` / `anyopaque`
- ABI 兼容结构体

业务逻辑文件负责：

- slice
- allocator
- error set
- 普通 Zig struct / enum / union
- 资源生命周期管理

### 4.3 强制规则

- `[*c]T` 只能停留在边界层
- `void*` 只能停留在边界层
- `errno` / 返回码风格只在边界层保留
- 所有边界输入，进入内部后尽快转换为 Zig 类型

### 4.4 `translate-c` 的使用规则

`translate-c` 只能用来：

- 快速导入头文件定义
- 过渡期 bootstrap
- 帮助理解 ABI / 常量 / 结构体

#### 禁止

- 把 translate-c 结果当作最终可维护业务代码
- 不审查宏翻译结果
- 不审查整数类型 / 指针 / ABI 对齐
- 不审查生成出来的 `[*c]T`

### 4.5 宏处理策略

C 宏迁移时按优先级处理：

1. 常量宏 → `const`
2. 简单函数宏 → 普通 `fn` / `inline fn`
3. 类型相关宏 → `comptime` 参数或泛型函数
4. 无法安全映射的复杂宏 → 人工重写，不强行自动翻译

### 4.6 ABI 结构体规则

- 对外暴露给 C 的结构体：`extern struct`
- 内部使用：普通 `struct`
- 位级布局必须严格一致时，才考虑 `packed struct`
- 不要为了“看起来像 C”而把所有结构都写成 `extern struct`

---

## 5. Zig 0.16.0 特别注意事项

迁移时最容易出错的地方，不是 Zig 语言本身，而是模型会混入老版本示例或 master API。

### 5.1 版本锁定

- 固定目标版本：**Zig 0.16.0**
- 所有 API 写法都以 0.16.0 为准
- 不要直接照抄旧博客、旧 issue、旧回答
- 不要把 master 文档写法直接用于稳定版

### 5.2 I/O 模型

应按 0.16.0 风格组织 I/O，避免旧版 `std.io` 常见写法。

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "hello world!\n");
}
```

#### 规则

- 不使用旧版 `std.io.getStdOut().writer()` 风格，除非已明确验证兼容
- 需要 I/O 的逻辑，应由 `main` 注入或传入相关能力
- 不要让底层业务逻辑隐式依赖全局 I/O

### 5.3 `@cImport`

在 0.16.0 迁移中：

- 优先通过 `build.zig` 集中管理 translate-c
- 不要把 `@cImport` 散落在多个业务文件中
- C 头依赖配置应尽量在构建系统中完成

### 5.4 容器 API

0.16.0 的标准库容器趋向 unmanaged / 显式 allocator 模式。

#### 规则

- 使用容器前，先核对当前版本 API
- 不照抄旧版 `ArrayList` / map / queue 示例
- allocator 传递方式必须按 0.16.0 标准库实际签名来

---

## 6. 构建系统规范（build.zig）

中大型迁移项目必须把 `build.zig` 当成正式工程基础设施，而不是可有可无的脚本。

### 6.1 build.zig 职责

- 管理 target / optimize
- 管理 Zig 模块
- 添加现有 C 源文件
- 配置 include path
- 配置编译选项 / 宏
- 链接 libc / 系统库
- 管理 translate-c
- 组织 test / run / install step

### 6.2 迁移阶段建议

| 阶段 | 目标 |
|---|---|
| 阶段 1 | 用 Zig build 接管构建，仍保留大部分 C 源 |
| 阶段 2 | 按模块逐步把 C 文件替换成 Zig |
| 阶段 3 | 内部 API Zig 化，边界层收缩 |
| 阶段 4 | 删除冗余 C shim / translate-c 过渡产物 |

### 6.3 推荐策略

- 优先先让项目能在 Zig build 下稳定编译
- 再逐模块迁移，不要一口气重写全部
- 每个模块迁移后立即补测试
- 每次迁移一层：类型 → 生命周期 → 错误 → API 整理

---

## 7. 风格规范

### 7.1 命名

- 函数：`camelCase`
- 类型：`TitleCase`
- 变量：`snake_case`
- 常量：根据上下文保持可读性，避免无意义全大写风格泛滥
- 私有字段不要机械使用前导下划线

### 7.2 格式

- 4 空格缩进
- 花括号同行
- 多元素列表倾向于每行一个元素并保留尾随逗号
- 始终运行：

```bash
zig fmt .
```

### 7.3 代码组织

- 小模块、明确职责
- 不要把 ABI 层和业务层写在同一个大文件
- 不要为了“接近 C 原结构”而牺牲 Zig 可读性
- 优先写清楚生命周期，而不是追求短代码

### 7.4 使用返回值

Zig 强制非 `void` 值必须被使用。

如需明确忽略：

```zig
_ = someValue;
```

禁止无意识丢弃返回值，特别是：

- 错误返回
- 分配结果
- 容器操作结果

---

## 8. 安全规则（强制）

### 严格禁止

- 返回栈内存引用
- 返回局部数组的 slice
- 隐式泄漏错误路径资源
- 在内部逻辑中继续传播 `[*c]T`
- 在无法证明安全时使用 `catch unreachable`
- 把 borrowed 数据伪装成 owned
- 混用不同 allocator 分配 / 释放同一块内存
- 抄写未经核对版本的 Zig 示例代码

### 需要特别谨慎

- 指针生命周期
- sentinel terminated 数据
- ABI 对齐与字段布局
- C 与 Zig 的整数宽度差异
- 并发下共享缓冲区的可变性

---

## 9. Agent 行为规范（关键）

Agent 在辅助迁移时，必须遵守以下工作流。

### 9.1 写代码前必须先做的事

1. 确认目标 Zig 版本为 **0.16.0**
2. 判断当前修改属于哪一层：
   - ABI 边界层
   - 内部逻辑层
   - 构建系统层
3. 明确这次改动涉及：
   - allocator
   - 所有权
   - 错误集合
   - 生命周期
   - API 映射

### 9.2 输出代码时必须同时说明

- allocator 从哪里来
- 返回值是否 owned / borrowed
- 谁负责释放
- 错误集合是什么
- 旧 C API 与新 Zig API 的映射关系
- C ABI 假设是什么

### 9.3 强制编码偏好

优先使用：

- `[]T` / `[]const T`
- `error{...}!T`
- `defer`
- `errdefer`
- `extern struct`（只在 ABI 边界）
- `struct`（内部）
- `const` 默认优先

避免使用：

- `[*c]T`
- `anyerror`
- out-param 风格内部接口
- “先写通再说”的无所有权设计

### 9.4 修改策略

- 一次只迁移一个清晰边界内的模块
- 每次改动后立即运行格式化和测试
- 不把“兼容旧接口”当成长期目标
- 优先保证正确性，再考虑性能微调

---

## 10. 自检清单

每次提交前必须检查以下项目：

### 10.1 类型与接口

- [ ] 是否把 ptr+len 尽量转成 slice？
- [ ] nullable / non-null pointer 是否正确区分？
- [ ] C ABI struct 是否用 `extern struct`？
- [ ] 内部 struct 是否避免了不必要的 `extern`？

### 10.2 内存与生命周期

- [ ] 函数若分配内存，是否接收 allocator？
- [ ] 返回值所有权是否明确？
- [ ] 每个 alloc 是否有对应释放策略？
- [ ] 错误路径是否使用 `errdefer` 清理？
- [ ] 是否错误返回了栈上数据？

### 10.3 错误处理

- [ ] 是否使用明确 error set？
- [ ] 是否存在 `anyerror`？
- [ ] 是否仍有内部 out-param + 错误码风格？
- [ ] 是否存在没有根据的 `catch unreachable`？

### 10.4 C 互操作

- [ ] `[*c]T` 是否只停留在边界层？
- [ ] `void*` / `anyopaque` 是否没有泄漏到内部？
- [ ] translate-c 结果是否已人工复核？
- [ ] 宏是否被安全地重写或替换？

### 10.5 版本与标准库

- [ ] 是否确认 API 属于 Zig 0.16.0？
- [ ] 是否混入旧版 `std.io` 写法？
- [ ] 是否抄用了过时容器示例？

### 10.6 工具链

- [ ] 是否运行 `zig fmt .`？
- [ ] 是否通过 Debug 测试？
- [ ] 是否通过 ReleaseSafe 测试？

建议命令：

```bash
zig fmt .
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
```

---

## 11. 推荐提示词（给 coding agent）

下面这段可以直接作为 agent 的工作约束：

```text
你正在把一个 C 项目迁移到 Zig。目标版本固定为 Zig 0.16.0，不要使用 master API，也不要照抄旧 Zig 教程。每次写 Zig 代码前先确认 API 是否适用于 0.16.0。

迁移原则：
1. C ABI 只保留在边界层；内部代码必须 Zig 化。
2. 内部函数优先使用 []T / []const T、error{...}!T、std.mem.Allocator、defer/errdefer。
3. 不要把 [*c]T、errno 风格错误码、void*、out-param 扩散到内部逻辑。
4. 可能为 NULL 的指针写成 ?*T；非 NULL 指针写成 *T；数组指针加长度尽快转换成 slice。
5. 函数如果分配内存，必须接收 allocator，并说明返回内存的所有权。
6. 每个 alloc 后必须有对应 free、defer 或 errdefer；不要泄漏错误路径。
7. 不要滥用 anyerror；尽量写明确 error set。
8. I/O 使用 Zig 0.16 的 std.Io 模型；需要 I/O 的函数接收 Io 或由 main(init: std.process.Init) 传入。
9. C 头文件导入和 translate-c 优先集中在 build.zig；@cImport 不要散落在业务代码中。
10. translate-c 产物只能作为脚手架，必须人工复核宏、指针、ABI、整数类型和所有权。
11. ABI 结构使用 extern struct；内部结构使用普通 struct；位级布局才考虑 packed struct。
12. 不要返回指向栈内存的 slice 或 pointer。
13. 不要用 catch unreachable 掩盖真实错误，除非能证明该错误在当前上下文不可能发生，并写明理由。
14. 每次修改后运行 zig fmt、Debug 测试和 ReleaseSafe 测试。
15. 输出代码前说明：allocator 策略、所有权、错误集合、C ABI 假设、旧 C API 到新 Zig API 的映射。
```

---

## 12. 结论

> **C 边界可以像 C，内部必须完全 Zig 化。**

迁移质量标准不是“能编译”，而是：

- 生命周期清晰
- 内存行为可推导
- 错误路径完整
- API 一致且可组合
- 边界层和内部层职责明确

判断一段迁移后的 Zig 代码是否合格，看这几个问题：

1. 谁分配？
2. 谁释放？
3. 失败时怎么清理？
4. 返回值是谁拥有？
5. 这是 Zig 接口，还是 C 兼容接口？
6. 它是否仍然在用 C 的思维方式写 Zig？

如果这些问题不能一眼回答，这段迁移代码通常还不够好。
