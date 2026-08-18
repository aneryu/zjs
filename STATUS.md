# STATUS

This page is the single authoritative status source for `zjs`.
README keeps only a pointer here.

## test262

Checked report date: 2026-08-05 (source: `COMPATIBILITY.md`).

- 49,775 prepared / 44,581 pass / 0 checked-in known failures / 0 unexpected failures / 5,194 feature skips
- 配置 = 仓库 test262.conf + submodule pin `4249661388e5d3f92a85186213da140a6481490f`

See `COMPATIBILITY.md` and `test262.conf` for the active validation boundary.
Configured skip classes include Intl, Temporal, ShadowRealm, decorators,
source-phase imports, and PTC.

## 性能

分数的权威来源是 `docs/perf/zoo-status.md`（本页不再自报一套 zoo 数字）。
当前 headline（zoo-status 2026-08-18 r3，`main@0280e278`，官方 8 样本并行
cluster 协议）：geomean **1.0335**，11/15 项 ≥ 1.0。落后项见 zoo-status
（pdfjs / earley-boyer / typescript / box2d）。

This is a maintainer single-machine measurement; there is no independent
reproduction yet.

- 机器：ARM Cortex-X925（3.9 GHz 大核，绑核），Linux 6.17；测量协议见仓库测量合同文档
- QuickJS 对照 pin：commit `04be246`，upstream Makefile 默认 release 构建（GCC 13.3.0，aarch64）
- 战役账本与归因报告（PARITY-LEDGER 及 46 份 2026-08-17 报告）已移出活树，可在 tag `v0.1.0` 的 `reports/perf/qjs-align/` 或 git 历史中恢复。原始采样文件已按收尾清理令清除，复测需按测量合同重新执行。

Measurement contract: `tools/compare/measurement_contract.js` with
`tools/compare/measurement_policy.json`; the prose incident register
(16 clauses) is preserved at tag `v0.1.0` under
`reports/perf/qjs-align/measurement-contracts.md`.

## 门禁

| Gate | What it covers | This lane |
|------|----------------|-----------|
| `zig build engine-production-gate --summary all` | unified Debug suite, ReleaseFast CLI smoke, architecture lints (including compiler-stage `nm`), OOM-cap, full test262 | 2026-08-17, branch `lane/prod-v0.1.0`: PASS. 35/35 steps succeeded. unified-tests: 2266 passed / 1 skipped / 0 failed. test262-check: `0/49775 errors, passed 44581`. Historical row also named `architecture-check` and `config-drift-gate`; those steps are gone. |
| `zig build test -Doptimize=ReleaseSafe --summary all` | optimized-loop safety | 2026-08-17, branch `lane/prod-v0.1.0`: PASS. 9/9 steps succeeded. 2266 passed / 1 skipped / 0 failed. |
| `zig build test-oom --summary all` | corpus × allocation-failure injection plus same-runtime recovery canaries | phase-close tier; not re-run in this packaging lane |
| `zig build test-altrepr --summary all` | nan-boxing representation guard | **已知存量失败**（2026-08-18 在 main 复现，与维护性战役无关）：`tests.exec.test.Engine direct eval shares top-level lexical cells across nested closures` 在 nan_boxed 下 SIGABRT（`bytecode.openVarRefCount` / `tailcall_dispatch.run`）。待独立修复。 |
| `mise run checkpoint-gate` | unified Debug suite, Debug CLI smoke, source-side architecture | handoff gate; does not compile ReleaseFast `zjs` |
| `zig build perf-self-check --summary all` | ZJS self-baseline | driver 在 release 时于测量机执行 |

## 复现命令

```sh
zig build zjs --summary all
zig build test --summary all
zig build engine-production-gate --summary all
zig build test262-check --summary all
```

Direct test262 runner (after `zig build run-test262 --summary all`):

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000
```

## CI

[![CI](https://github.com/aneryu/zjs/actions/workflows/ci.yml/badge.svg)](https://github.com/aneryu/zjs/actions/workflows/ci.yml)

x86-64/macOS 首跑 advisory，绿后转 required.
