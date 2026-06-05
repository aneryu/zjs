# Production-Grade Plan

本文是 `zjs` 成为 production-grade embeddable JavaScript engine 的总路线图。
它定义目标、完成标准和长期 TODO。更细的契约和发布检查保留在对应文档中：

- 当前 API / 边界契约：[ADR 0001](adr/0001-zig-kernel-api-and-runtime-boundary.md)
- 兼容性边界：[compatibility-v1.md](compatibility-v1.md)
- 安全边界：[security-boundary.md](security-boundary.md)
- 嵌入示例：[embedding-cookbook.md](embedding-cookbook.md)
- 发布检查：[release-checklist.md](release-checklist.md)

Note: earlier Engine-facade API items in this roadmap are legacy direction.
Current public API work follows the low-level kernel surface in ADR 0001.

## 目标

Production v1 的目标是提供一个可嵌入、可验证、可维护的 Zig
JavaScript engine。语义参考是 QuickJS 行为，当前 validation profile 是根目录
`test262.conf`、`test262/test` 和仓库内 focused regression。

Production v1 不代表 Node.js、Deno、浏览器 API 或 hostile-code sandbox
兼容。v1 目标是 trusted-code embedding：宿主负责进程隔离、权限模型和
wall-clock supervision。

## Definition Of Done

- `Engine` 嵌入 API 稳定，所有 ownership-bearing 返回值都有清晰释放路径。
- `EngineOptions`、`EvalOptions`、`Limits`、`ValueHandle` 和
  `ExceptionInfo` 的行为与 [engine-api-v1.md](engine-api-v1.md) 一致。
- 生命周期、异常、Promise job queue、module eval、interrupt hook 和资源限制有回归覆盖。
- GC、atom/string/value/object 所有权规则在 public API 路径上可验证。
- QuickJS 语义差异只存在于已记录的 compatibility boundary 内。
- Production v1 gate 从 clean checkout 可重复通过。
- release notes 明确说明 trusted-code embedding 边界，不宣称 hostile-code sandbox。

## Gate-First TODO

- [x] 保持 `zig build test --summary all` 作为默认 Debug test surface。
- [x] 保持 `zig build test -Doptimize=ReleaseSafe --summary all` 作为 ReleaseSafe exec shard。
- [x] 移除过时的 `smoke` 步骤以保持测试构建的精简干净。
- [x] 保持 `zig build test262-gate --summary all` 使用 checked-in config。
- [x] 保持 `zig build engine-production-gate --summary all` 作为顶层 release gate。
- [x] 对 parser、runner、execution 或 semantic 改动运行 focused test262 slice。
- [x] 对非平凡语义修复记录 reference evidence 和本地复现命令。
- [x] 禁止通过删除测试、扩大 excludes、弱化 skip policy 或硬编码结果制造绿色 gate。

## Embedding API v1 TODO

- [x] 固化 `Engine.init`、`Engine.initWithTrace`、`Engine.initWithOptions`
  的 ownership contract。
- [x] 固化 `Engine.evalHandle`、`Engine.evalModuleHandle`、
  `Engine.evalHandleWithOptions` 的 preferred embedding path。
- [x] 确认低层 `Engine.eval` / `Engine.evalModule` 返回 `core.Value` 的释放路径有文档和测试。
- [x] 为 `ValueHandle.deinit` / `ValueHandle.release` 添加覆盖，避免 double-free 和 leak。
- [x] 为 `Engine.takeExceptionInfo` / `ExceptionInfo.deinit` 添加异常快照覆盖。
- [x] 确认 `EvalOptions.mode` 对 script/module 的行为 and 错误路径稳定。
- [x] 确认 `EvalOptions.filename` 进入 diagnostics and module metadata。
- [x] 确认 `EvalOptions.output` 覆盖 `print` 等宿主输出路径。
- [x] 为 public error set 变化建立 release-note 记录流程。
- [x] 保持 public API 删除或语义收窄必须有迁移说明。

## 生命周期 / GC / 资源控制 TODO

- [x] `Engine.deinit` 后 runtime、context、job queue、atoms、strings 和 values 不泄漏。
- [x] `zig build leak-check-engine --summary all` 覆盖 init/eval/deinit 主路径。
- [x] 覆盖 eval 成功、parse error、runtime exception、OOM 和 interrupt 的 cleanup 路径。
- [x] 确认 pending Promise jobs 在 eval 边界按契约 drain 或保留。
- [x] 确认 module graph、module namespace 和 top-level await 相关生命周期。
- [x] 确认 `Limits.memory_bytes` 映射到 `Runtime.setMemoryLimit`。
- [x] 确认 `Limits.stack_bytes` 映射到 `Runtime.setStackSize`。
- [x] 确认 `Limits.gc_threshold_bytes` 映射到 `Runtime.setGCThreshold`。
- [x] 为资源限制命中路径添加聚焦测试，尤其是 OOM 和 stack overflow。
- [x] 为 cooperative interrupt hook 添加长循环和恢复后的回归测试。
- [x] 明确 one runtime per thread，不支持跨线程共享 `Engine`、`Context` 或 `ValueHandle`。

## 兼容性与验证矩阵 TODO

- [x] `COMPATIBILITY.md` 描述当前 validation boundary，不做 ECMAScript 完整性过度声明。
- [x] `LIMITATIONS.md` 描述已知 runtime 限制和非目标。
- [x] [compatibility-v1.md](compatibility-v1.md) 保持 Production v1 gate 和 boundary。
- [x] 针对改动领域选择 focused test262 slice，例如 `built-ins/RegExp`、`language/expressions`。
- [x] 对 QuickJS parity 外的行为使用最小 JS fixture、Zig regression 或报告 artifact 记录证据。
- [x] 对 CLI contract 保持 `zjs -e "<script>"` 和 `zjs <file.js>` 覆盖。
- [x] 对 module、eval、exceptions、jobs、builtins、RegExp、BigInt、Unicode 和 number formatting
  建立按子系统追踪的回归用例。
- [x] 性能报告只能作为诊断信号，不能替代 semantic gate。
- [x] 恢复或替换当前可重复的性能基准入口；历史 `reports/perf/` 不能作为 release gate。

## Release Readiness TODO

- [x] [release-checklist.md](release-checklist.md) 中所有条目通过。
- [x] `docs/security-boundary.md` 与 release notes 的安全声明一致。
- [x] `docs/embedding-cookbook.md` 示例能用当前 public API 编译或有对应测试覆盖。
- [x] release notes 记录 public API、error set、兼容性边界和已知限制变化。
- [x] release diff 不包含临时日志、调试输出、生成噪声或无关重构。
- [x] `git diff --check` 通过。
- [x] 从 clean checkout 重新运行顶层 Production v1 gate。

## Implementation Order

1. 固化 gate：保证测试入口、test262 config、report 输出 and skip policy 可重复。
2. 固化 embedding API：优先完成 ownership-safe 的 `ValueHandle` 和 `EvalOptions` 路径。
3. 补齐生命周期覆盖：集中处理 exception、OOM、interrupt、jobs 和 module cleanup。
4. 收敛语义差异：按 reference evidence 修复一个问题类，并为每类保留 focused regression。
5. 收敛文档边界：同步 API、compatibility、limitations、security 和 cookbook。
6. 做 release dry run：从 clean checkout 跑 release checklist 并记录证据。

## Assumptions

- Production v1 是 engine-only 目标，不包含 Node.js、Deno 或 browser runtime。
- v1 支持 trusted-code embedding，不支持 hostile JavaScript in-process sandbox。
- QuickJS 行为是语义参考；根目录 `test262.conf` 是当前 validation boundary。
- Zig public API 优先稳定实用的 embedding surface，而不是复制 QuickJS C API。
- 现有 `docs/engine-api-v1.md`、`docs/compatibility-v1.md` 和
  `docs/release-checklist.md` 继续分别承担 API、兼容性和发布检查职责。
