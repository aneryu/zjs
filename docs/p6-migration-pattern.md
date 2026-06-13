# Phase 6 Builtin Migration Pattern

迁移期工作文档。Phase 6 收口（HostFunction 枚举退役、依赖规则反转为
`exec must not import builtins`）后整体移除。配合 docs/zjs_架构改进路线图_r5.plan.md
的 D1 节阅读。

## 目标形态（QuickJS 客户模型）

把「仅经 native 函数对象分发可达」的内建方法实现从 `exec/*_ops.zig` 搬进
`src/builtins/<class>.zig`，实现与声明表共置（QuickJS 的 `js_*_funcs`
JSCFunctionListEntry 数组）。builtins 现在合法地 import exec 的 VM ops
（coercion/call/property/string/object），exec 经一张按 (domain, id) 索引的
静态表分发，对具体内建零编译期知识。

Math 和 JSON 是已落地的试点；后续 class 照本模式迁移。

## 机制各部件（已建好，勿重造）

| 部件 | 位置 | 职责 |
| --- | --- | --- |
| `InternalCall` | `core/host_function.zig` | 一次调用的参数包：ctx/output/global/globals/func_obj/this/args + `magic` 选择子 + VM caller 对（`?*const anyopaque`，core 不能命名 exec 类型故擦除） |
| `InternalRecord` | `core/host_function.zig` | 一个可分发记录：`length`/`magic`/`prepared_call_ok`/`call`（`?InternalCallFn`，null = 未占用槽） |
| `InternalEntry` | `core/host_function.zig` | builtins 侧声明项：`name`/`length`/`id`/`magic`/`prepared_call_ok`/`call`。comptime 表构建器把它密化进按 id 索引的 `InternalRecord` 槽 |
| `InternalCallFn` | `core/host_function.zig` | `*const fn (InternalCall) anyerror!JSValue`。实现用收窄错误集声明，在表边界放宽到 anyerror，分发点收窄回 HostError |
| `NativeBuiltinDomain` | `core/function.zig` | 每个 class 一个 domain 枚举值（math/json/string/array/...）。native 函数 id 编码为 (domain, 域内 id) |
| `internal_table.zig` | `src/builtins/` | comptime 汇集各已迁 class 的 `internal_entries` 成 `[domain][id]InternalRecord` 静态表；未迁 domain 留空 slice |
| `JSRuntime.internal_builtins` | `core/runtime.zig` | `[]const []const InternalRecord`，由 `registry.installStandardGlobals` 指向 `internal_table.table`。`internalBuiltinRecord(domain, id)` 做边界检查查表 |
| `builtin_dispatch.zig` | `src/exec/` | exec 侧桥：`callInternalRecord` 先探表（命中即调、未命中返 null 落回 enum 分发）；`callerBytecode`/`callerFrame` 把擦除的 caller 对恢复成 typed `*Bytecode`/`*Frame` |

## 分发流（热路径）

`call.zig` 的 `callNativeFunctionRecordDispatch`（约 :1491）：

1. `decodeNativeBuiltinId` 取 `native_ref{domain, id}`。
2. `builtin_dispatch.callInternalRecord(...)` 探 `rt.internal_builtins`——命中
   则零编译期知识地调用记录，返回值即结果。
3. 未命中（返 null）落回下方 `switch (native_ref.domain)` 的过渡 enum 分发。
   **已迁 class 在此 switch 中只留损坏 id 兜底**（如 `.math, .json => error.TypeError`），
   不再有 `callXxxNativeFunctionRecord` 分支。

性能：相对迁移前多一次表探查（一次间接调用），与原 jump table 同级；热路径
call case 微基准无可见回归。

## 迁移一个 class 的步骤清单

以 `<Class>`（domain 已在 `NativeBuiltinDomain`）为例：

1. **留/迁判定**。对 `exec/<class>_ops.zig` 每个 pub fn grep 全 src/ 调用点：
   - **MOVE**：调用方仅为 native 分发路径（call.zig/call_runtime.zig 的
     host-function 分支、builtin_glue 转发）→ 搬进 `builtins/<class>.zig`。
   - **STAY**：被 opcode handler（zjs_vm.zig、vm_*.zig）或其他 exec 模块当
     通用 op 直接调用 → 留 exec。
   - **BOTH**：两侧都调 → 核心留 exec，builtins 侧持薄入口（call fn 调
     exec 的公共 op）。object_ops/array_ops/string_ops 的判定清单见 git
     历史中本轮的 inventory（或重跑 Explore agent）。
2. **声明 `internal_entries`**。在 `builtins/<class>.zig` 加
   `pub const internal_entries = [_]core.host_function.InternalEntry{...}`，
   每个方法一项。id 用域内连续小整数（**id 0 保留**，会 @compileError）；
   一个实现服务多方法时用 `magic` 选择子（见 math.zig 的 `mathOpEntry`，
   id==magic，共享 `mathOpCall`）。`prepared_call_ok = true` 仅当该记录
   不依赖物化函数对象/realm（可被 prepared-call 直调）。
3. **写 call fn**。签名 `fn xxxCall(host_call: InternalCall) HostError!JSValue`。
   从 `host_call` 取 ctx/args/this/global；需要 VM caller 时用
   `builtin_dispatch.callerBytecode(host_call)` / `callerFrame(host_call)`
   恢复 typed 指针（**不要** import `src/bytecode/`）。实现体从 exec 搬来，
   import 它需要的 exec ops（现在合法）。
4. **注册 domain**。`internal_table.zig` 的 `table` build 块加一行
   `domains[@intFromEnum(NativeBuiltinDomain.<class>)] = denseRecords(&<class>.internal_entries);`。
5. **接安装路径**。`registry.zig` 的安装循环遍历
   `<class>_builtin.internal_entries` 取 name/length/id 建属性（见 :479
   json、:1085 math；`methodsFromInternalEntries` 派生视图供既有安装代码
   复用）。删除该 class 在 registry 里旧的硬编码方法表/length 重复数据。
6. **删 exec enum 分支**。`call.zig` 的 `switch (native_ref.domain)` 把
   `.<class> => try callXxxNativeFunctionRecord(...)` 改为并入损坏 id 兜底
   `=> error.TypeError`；删除现已无引用的 `callXxxNativeFunctionRecord` 整个
   fn（grep 确认零引用后删）。同步清理 builtin_glue/object_ops 里被搬空的
   转发壳。
7. **门禁**（每个 class 一个本地检查点）：
   - `zig build zjs`
   - `./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test/built-ins/<Class>` 0 失败
   - `zig build test`（全量 Debug）
   - `zig build architecture-check`（deps + OOM-panic + API 快照）
   - 微基准对照 `../quickjs/build/qjs`（纯组织迁移预期持平）：
     `bun tools/compare/run_microbench.js --category <相关> --iters 5`

## 注意事项（试点踩过的坑）

- **微基准用 bun 不用 node**：脚本含 `import.meta.dir`（Bun API）。
  `QJS_ZIG=$(pwd)/zig-out/bin/zjs QJS=$(pwd)/../quickjs/build/qjs bun tools/compare/run_microbench.js ...`。
  microbench 套件无专门 math/json case，调用路径回归看 function 类
  （func_call/call2_loop/closure_call_loop）。
- **bare-runtime 回退路径**：部分方法有「无 realm global 时的 primitive-only
  回退」（host-path 历史行为）。搬迁时连回退一起搬，别只搬 spec 主路径
  （见 math.zig `mathOpCall` 的 global==null 分支）。
- **`magic` 复用**：id 可不连续（math 把 log/cbrt/trunc 的 id 与声明顺序解耦），
  但 `denseRecords` 按 max_id 开数组，过疏的 id 会浪费 comptime 槽——保持
  域内 id 大致连续。
- **错误集**：call fn 声明 `HostError!JSValue`（或更窄）即可，表边界
  `@errorCast` 到 anyerror、分发点 `@errorCast` 回 HostError；只要实际错误
  ∈ HostError，运行时收窄不会失败。
- **依赖规则按方向迁移**：迁第一个真正 import exec 的 class 时，
  `check_deps.js` 的 builtins disallowed 列表已移除 `src/exec/`（试点已做）。
  **exec→builtins 仍合法**，Phase 6 收口才反转——届时删 HostFunction 枚举、
  把 exec disallowed 加上 `src/builtins/`、本文档移除。
- **`prepared_call_ok` 与 fast path**：迁移不要顺手改 fast-call 语义；
  `builtin_dispatch.preparedCallOk` 已替既有 prepared-call 门控查表，保持
  原 class 的 prepared 资格不变。
