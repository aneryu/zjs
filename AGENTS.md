# AGENTS.md

## 项目定位

本仓库是 **QuickJS C → Zig** 的重写工程，目标是在当前仓库内持续收敛语义兼容性与可用性。

- 引擎入口：`src/engine/root.zig`
- VM 入口：`src/engine/vm_entry.zig`
- CLI：`src/cli/qjs.zig`
- 构建入口：`build.zig`

## 目录结构（重点）

- `src/engine/`：词法、语法、AST 与引擎导出
- `src/engine/vm/`：运行时、值系统、编译器、字节码执行、内建对象
- `src/tests/`：Zig 单测/集成测试入口
- `src/tests/vm/`：VM 子系统测试
- `tests/zig-smoke/`：JS 脚本 smoke 集
- `quickjs-zig-plan.md`：当前阶段计划与里程碑

## 必跑命令

### 构建与可执行

- `zig build qjs`：构建并安装 `zjs`

### 测试

- `zig build test --summary all`：主测试集（必须通过）
- `zig build test-vm`：VM-only 测试
- `zig build smoke`：运行已纳入的 smoke 脚本集

## CLI 使用约定

`zjs` 当前支持：

- `zjs -e "<script>"`
- `zjs <file.js>`

缺参数时会报 usage 并退出非 0。

## 代码修改策略（必须遵守）

1. **先复现再修改**：先跑对应失败脚本/测试，确认现象。
2. **最小改动原则**：优先在现有模块补齐，不做无关重构。
3. **分层定位**：
    - 语义/执行错误优先看 `src/engine/vm/vm.zig`
    - 编译期绑定/作用域优先看 `src/engine/vm/compiler.zig`
    - 内建行为优先看 `src/engine/vm/builtins.zig`
4. **每次改动后回归**：
    - 至少执行 `zig build test --summary all && zig build smoke`
5. **不扩散修复**：一次只收敛一类失败（如 string、array、json）。

## 当前能力边界（开发时注意）

- 已有较完整的内建初始化链路（含 `JSON`、`Math` 等注册）。
- 仍处于兼容性收敛阶段，部分 smoke 脚本尚未纳入 `build.zig` 的 smoke 集。
- 对 `new`、回调调用、对象包装等路径，优先保证已覆盖脚本稳定通过，再扩展行为面。

## 下一阶段优先级

以 `quickjs-zig-plan.md` 为准，当前优先顺序：

1. `JSON`（`tests/zig-smoke/json.js`）
2. `Math`（`tests/zig-smoke/math.js`）
3. `Date`（`tests/zig-smoke/date.js`）

每完成一项，立即执行全量回归并再推进下一项。

## 提交前检查清单

- [ ] 相关失败用例已复现并定位
- [ ] 修改集中在最小必要文件
- [ ] `zig build test --summary all` 通过
- [ ] `zig build smoke` 通过
- [ ] 未引入新的构建噪声或明显日志污染
