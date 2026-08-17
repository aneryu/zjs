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

Maintainer-measured, 2026-08-17 终榜. This is a maintainer single-machine
measurement; there is no independent reproduction yet.

- 15 项 javascript-zoo geomean **1.0141** vs QuickJS（zjs 用时/qjs 用时的比值口径以仓库测量文档为准），9/15 项 ≥ 1.0
- 落后项代表值：pdfjs 0.8141、earley-boyer 0.8153、typescript 0.9443、box2d 0.9668、splay 0.9952
- 机器：ARM Cortex-X925（3.9 GHz 大核，绑核），Linux 6.17；测量协议见仓库测量合同文档
- QuickJS 对照 pin：commit `04be246`，upstream Makefile 默认 release 构建（GCC 13.3.0，aarch64）
- Raw JSON: see release assets

Measurement contract: `reports/perf/qjs-align/measurement-contracts.md` and
`tools/compare/measurement_contract.js`.

## 门禁

| Gate | What it covers | This lane |
|------|----------------|-----------|
| `zig build engine-production-gate --seed 0 --summary all` | unified Debug suite, ReleaseFast CLI smoke, architecture checks, OOM-cap, full test262 | 2026-08-17, branch `lane/prod-v0.1.0`: PASS. 35/35 steps succeeded. unified-tests: 2266 passed / 1 skipped / 0 failed. test262-gate: `0/49775 errors, passed 44581`. smoke, architecture-check, config-drift-gate all success. |
| `zig build test -Doptimize=ReleaseSafe --seed 0 --summary all` | optimized-loop safety | 2026-08-17, branch `lane/prod-v0.1.0`: PASS. 9/9 steps succeeded. 2266 passed / 1 skipped / 0 failed. |
| `zig build test-oom --seed 0 --summary all` | corpus × allocation-failure injection plus same-runtime recovery canaries | phase-close tier; not re-run in this packaging lane |
| `zig build architecture-check --seed 0 --summary all` | dependency rules, public API snapshot, related static checks | included in `engine-production-gate` |
| `zig build config-drift-gate --seed 0 --summary all` | configuration-signature attestation can still fail | included in `engine-production-gate` |
| `zig build perf-self-check --seed 0 --summary all` | ZJS self-baseline | driver 在 release 时于测量机执行 |

## 复现命令

```sh
zig build zjs --seed 0 --summary all
zig build test --seed 0 --summary all
zig build engine-production-gate --seed 0 --summary all
zig build test262-gate --seed 0 --summary all
```

Direct test262 runner (after `zig build run-test262 --seed 0 --summary all`):

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000
```

## CI

[![CI](https://github.com/aneryu/zjs/actions/workflows/ci.yml/badge.svg)](https://github.com/aneryu/zjs/actions/workflows/ci.yml)

x86-64/macOS 首跑 advisory，绿后转 required.
