# 验证与门禁政策(Verification Policy)

Status: **现行**(owner 裁决 2026-08-29:精简影响效率的门禁;验证摊销从批内
扩到批间)。本文件是唯一权威;与旧文档/旧派工惯例冲突时以本文件为准。
适用于所有实现工作(人类、driver、subagent)。

## 原则

**验证成本后置给失败案例,不预付给每次改动。** 批次的意义是留下 bisect
粒度;昂贵验证在合并批边界跑一次,失败才用批内 commit 二分定位。

## 每次改动(implementer 侧)必须做的

1. 迭代验证用 `zig build check`(纯 sema,~80s),不用完整构建;
2. 为改动写针对性测试(新行为/新不变量);
3. 收尾跑**一次** `zig build test`(pipefail)全绿;
4. 注入验证:**仅**对守护新不变量的检查器;用「一次构建多注入点」模式
   (`ZJS_*_INJECT=<n>` 环境选择),不许每断言单独构建;注入必须在
   `zig build test` 形态下做(默认 zjs 产物 safety 关闭会假通过),且确认
   开火的是自己的守卫(「触发别的守卫 ≠ 你的守卫有效」)。
5. 性能刀附目标负载的指令数 ABBA(匹配 `armv8_pmuv3_1/instructions`);
   **不要求**陪跑全负载矩阵。

## 每合并批(driver 侧)做的

1. 合并载荷审查(`git log trunk..candidate`,合并 commit = 合并其全部祖先);
2. 批门禁一轮:`zig build test` + `tools/perf/gate_smoke.sh <显式二进制>` +
   test262 + 至少一个负载的 `ZJS_GC_ARENA_AUDIT=1`;
3. 失败 → 按批内 commit bisect,只对肇事 commit 追加验证;
4. cycles/L2D 终裁攒安静窗口一次做(全部 agent 停工、`pgrep -x zig`=0、
   mpstat 空闲核)。

## 明确废止的(勿再执行)

- **rc 中立性检查全套**(.text 对比、双变体单测、rc 语义论证)——rc 收集器
  已退役(2026-08-29),无对象;
- 每次改动跑 test262 / gate_smoke / arena audit(移至批门禁);
- 每断言两次构建的注入验证;
- 全负载矩阵的指令筛选。

## 保留的纪律(便宜且有战功)

- **预注册验收线**:性能刀开工前写下通过/失败判据(曾正确否决整把刀);
- 设计文过审:仅限触碰对象表示层/GC 语义/公共 ABI 的大刀;
- 测量合同:编译与测量分核、测量前 mpstat、指令数筛选/cycles 终裁两级仪器、
  wall-clock 在并发场不可信;
- 环境陷阱清单:worktree 的 test262 空 submodule(先 `rmdir` 再
  `ln -s /home/aneryu/zjs/test262`,不进提交);scratch 一律 worktree 内
  `.scratch/`,严禁 /tmp 裸文件名(agent 间撞车实录)。

## 风险自认(owner 已知情)

正确性缺陷的拦截点从「改动内」后移到「批门+bisect」。同一笔验证账,
成本从每次改动的预付改为失败案例的后付。
