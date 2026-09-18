# 验证与门禁政策(Verification Policy)

Status: **现行**(owner 裁决 2026-09-18:废止测量/消融政策与 Stage 0 /
size-screen / 场锁 / 强制 PMU ABBA;验证摊销仍从批内扩到批间)。本文件是
唯一权威;与旧文档/旧派工惯例冲突时以本文件为准。适用于所有实现工作
(人类、driver、subagent)。

## 原则

**验证成本后置给失败案例,不预付给每次改动。** 批次的意义是留下 bisect
粒度;昂贵验证在合并批边界跑一次,失败才用批内 commit 二分定位。

正确性由测试与批门禁裁决。性能与体积不再有预注册通过线、场锁或快筛
仪器;本地 `perf` / `--gc-stats` / `zig build perf-benchmark` 只是诊断。

## 每次改动(implementer 侧)必须做的

默认编辑内循环使用 Debug：`check`、定向 `test-fast`，需要 CLI 时用
`zjs-dev`。ReleaseFast 后置到稳定候选与批门，
不随每次编辑构建。Debug 结果不能替代生产配置的最终验证。

1. 迭代验证用 `zig build check` 判编译错误;定向测试用
   `mise run test-fast -- '<测试名子串>'`，运行时过滤复用统一测试产物，空选择失败。
   需要符号化失败栈时再用 `-Dtest-filter` 或 `-Dtest-strip=false`;
2. 为改动写针对性测试(新行为/新不变量);
3. 收尾跑**一次** `zig build test`(pipefail)全绿;
4. 注入验证:**仅**对守护新不变量的检查器;用「一次构建多注入点」模式
   (`ZJS_*_INJECT=<n>` 环境选择),不许每断言单独构建;注入必须在
   `zig build test` 形态下做(默认 zjs 产物 safety 关闭会假通过),且确认
   开火的是自己的守卫(「触发别的守卫 ≠ 你的守卫有效」)。

批边界若还需生产/profiling smoke，使用 `mise run batch-gate-profile`
（在 `batch-gate` 的步骤上再加 `smoke`）。无 profiling 相关改动仍用
普通 `batch-gate`。

不以删除测试、放宽 exclude 或删生成表获得收益。保留公共 API/ABI 与
GC safety net。每合并批仍只跑一轮批门禁。

生产 `zjs` 固定 ReleaseFast。代码生成实验使用
`zig build zjs-size -Doptimize=ReleaseSmall`，其 CLI 与引擎同时遵循显式
模式并独立校验配置。跨配置的体积比较必须显式声明。

## 每合并批(driver 侧)做的

1. 合并载荷审查(`git log trunk..candidate`,合并 commit = 合并其全部祖先);
2. 批门禁一轮:`mise run batch-gate` =
   `zig build checkpoint-gate test-stress test262-check -j32`
   (与 CI linux-arm64 同一组步骤,不含已退役的 `gate-smoke` /
   `merge-gate`)。发布门仍是 `mise run production-gate`
   (`engine-production-gate`)。**门禁一律走 mise 任务**:裸 `zig build`
   只有 `核数−1` 个 runner 线程,超出的初始步骤会在主线程内联执行;
3. 失败 → 按批内 commit bisect,只对肇事 commit 追加验证。

## 明确废止的(勿再执行)

- **rc 中立性检查全套**(.text 对比、双变体单测、rc 语义论证)——rc 收集器
  已退役(2026-08-29),无对象;
- 每次改动跑 test262(移至批门禁 / CI);
- 每断言两次构建的注入验证;
- 全负载矩阵的指令筛选;
- **Stage 0 / size-screen / measure_fields / 强制 PMU ABBA / 场锁与
  0.1% 精度制度**(2026-09-18)。`docs/perf/stage0.md`、
  `docs/perf/size-screen.md`、`docs/perf/measurement-contracts.md` 与对应
  仪器已撤;历史文本在 git;
- **refactor-policy rule 2 的强制 bench-v8 A/B 与 identity-set 协议**
  (2026-09-18)。热路径拆分仍有布局税,但不再有预注册测量通过线。

## 保留的纪律(便宜且有战功)

- 设计文过审:仅限触碰对象表示层/GC 语义/公共 ABI 的大刀;
- 环境陷阱清单:linked worktree 的 test262 空 submodule 时先跑
  `mise run worktree-init`;该任务复用主 worktree 的 corpus,且 symlink 不进提交。
  scratch 一律 worktree 内 `.scratch/`,严禁 /tmp 裸文件名(agent 间撞车实录)。

## 风险自认(owner 已知情)

正确性缺陷的拦截点从「改动内」后移到「批门+bisect」。同一笔验证账,
成本从每次改动的预付改为失败案例的后付。性能回归不再被预注册仪器拦截。
