# Perf 三方对比:qjs-align-phaseA vs qjs vs main(2026-07-04)

分支 `qjs-align-phaseA`(HEAD `4577f4d`,领先 main 120 commit)合入前的性能核验。
main 恰好停在 perf-recovery 状态(`541c30f`),因此「分支/main」一列干净隔离了
整个 qjs-align 修复程序(Phase A 栈守卫、B 系 JSON/字符串/数组重写、C 系解析器、
D 系 for-in/promise/modules、E1 async-gen 等 120 commit)的性能代价。

## 协议

- 机器:big.LITTLE(Cortex-X925 ×10 + A725 ×10),`taskset -c 19` 绑最快大核
- `perf stat -e task-clock,instructions`,1 次热身 + 3 次取最优
- 两引擎 14 个基准输出逐字一致后才计时(qjs = `~/quickjs/qjs`,04be246 era)
- `zig build zjs`(ReleaseFast);main 二进制在独立 worktree 构建
- **基准必须包函数**:顶层作用域跑会让 zjs 全线虚差到 3-4×(顶层变量慢路径,
  已知假象,见 memory zjs-qjs-layered-perf-baseline「包函数」纪律)
- big.LITTLE 陷阱:perf `instructions` 拆双 PMU,真值在 `armv8_pmuv3_1` 行;
  `-x,` 模式 task-clock 单位是 ns

## 主表(时间比 zjs/qjs,<1 = zjs 更快;best-of-3)

| 基准 | qjs | 分支 | 分支/qjs | 分支/main | 指令比 |
|---|---|---|---|---|---|
| loop `s=s+i` (float) | 1221ms | 999ms | **0.82** | 0.99 | 0.69 |
| loop float `i++` | 727ms | 911ms | 1.25 | 1.04 | 1.34 |
| loop `s=s+1` (int) | 578ms | 499ms | **0.86** | 0.99 | 0.92 |
| loop `i--` | 472ms | 396ms | **0.84** | 1.04 | 0.93 |
| fib(30) | 49ms | 201ms | 4.14 | 1.02 | 3.56 |
| funcall | 371ms | 1388ms | 3.74 | 1.01 | 3.09 |
| strcat `s=s+"a"` | 77ms | 66ms | **0.85** | 1.00 | 0.79 |
| 字符串 churn | 166ms | 288ms | 1.74 | 1.01 | 1.57 |
| objalloc `{a,b,c}` | 742ms | 1999ms | 2.70 | **0.91** | 2.81 |
| objprop 读写 | 875ms | 1365ms | 1.56 | 1.02 | 1.82 |
| charCodeAt | 541ms | 1578ms | 2.92 | 0.99 | 2.14 |
| template 字面量 | 311ms | 883ms | 2.84 | 1.00 | 2.41 |
| regexp (exec+replace) | 320ms | 1861ms | 5.81 | 1.00 | 4.76 |
| array 索引读写 | 387ms | 550ms | 1.42 | 1.02 | 1.48 |

## 结论

1. **120 个对齐 commit 零性能代价**:分支/main 全线 0.99–1.04(噪声带);
   objalloc 0.91 分支反而略快。合入 main 无性能顾虑。
2. **与既往基线吻合**:循环族(3/4 反超)与 strcat/churn 确认 rope +
   execution_view 两个 recovery 提交在位有效;fib 4.14 / funcall 3.74 仍是
   最大前沿(见 CALL-MACHINERY-FAITHFUL-FRONTIER.md);objprop/array/objalloc/
   template/charCodeAt 均在既往带内。
3. **新线索(预存,非本分支引入):replace 路径 8–16×**,见下节。

## replace 差分归因(下一个 ROI 最高的忠实修复)

| 微基准 | zjs | qjs | 比值 |
|---|---|---|---|
| `re.test(s)` | 317ms | 317ms | **1.00(完全对齐)** |
| `re.exec(s)` | 391ms | 153ms | 2.57(match 数组构造,同 octane 口径) |
| `s.replace(re, "$2 $1")` | 1346ms | 165ms | 8.2 |
| `s.replace(re, "X")` | 1317ms | 152ms | 8.7 |
| `s.replace("John", "X")`(纯字符串) | 1153ms | 70ms | **16.4** |

纯字符串 replace 每次 1153ns vs qjs 70ns → 问题不在 regexp,而在 **per-native-call
固定开销**。perf profile(fn_str_replace_str):

- `exec.call.nativeFunctionNameForVm` 自身 11.9%,驱动 malloc 16.3% + free 15.8%
- `mem.eqlBytes` 6.3%(名字逐表 strcmp)
- 纯字符串基准的 profile 里出现 `arrayPrototypeRecordId` / `qjsArrayIterationCall` /
  `qjsArrayMethodFastCall` / `qjsArrayReduceCall` —— 分派链跨域乱走

根因:native 内建分派按「函数名字符串」比较,且每次调用 malloc 名字再 free。
qjs 对应机制是 cfunc 指针 + magic int(JSCFunctionType 记录表),零分配。
零分配变体 `nativeFunctionDispatchNameRef`(src/exec/call.zig:2689,注释明说为
热路径而写)已存在但仅 2 个调用点;array_ops / string_ops / call_runtime 有
几十个分配版 `nativeFunctionNameForVm` 调用点。这同时解释 charCodeAt 2.92 的
native-call 残差。**忠实修法 = 镜像 qjs 的 magic 记录表分派,消灭按名分派。**

## 当前前沿排序(合入后 backlog 视角)

1. **native 按名分派 → magic 记录表**(replace 16×/regexp 5.8×/charcode 残差,预存)
2. **调用机制**(fib 4.14 / funcall 3.74,方案见 CALL-MACHINERY-FAITHFUL-FRONTIER.md
   激进 method-A:塌缩 call 路径 ~9 布帧函数 + 砍 qjs 没有的 per-call 簿记)
3. objalloc 2.70(接近忠实地板 ~qjs 不缓存中间 shape,见 memory)
4. template 2.84 / charcode 2.92(部分与 1 重叠)
