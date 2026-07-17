# CALL-SUPERNODE-PLAN v2.10 — 调用机制追平 qjs 的三波方案（终局执行记录）

> 日期：2026-07-16（v2.1）· 基线：main `54a75913`（**16B JSValue 已翻默认**）· qjs 参照：`b76d1542…`（2026-06-04）
> **总目标：纯调用税 461 → 238±10%（追平 qjs），不是收窄。** 分三波，每波独立门禁、独立可回退。
> v2→v2.1：16B 默认合入 main，repr 排期依赖解除；基线在 16B 同 repr 口径重测（本页数字已更新）：**纯调用税 zjs 461 insn/80.4 cyc vs qjs 238/40.4 = 1.94x/1.99x**（8B 旧口径 452/78.2）；控制组 191.5 insn/iter 反超 qjs 234（NaN-box 解码税消失）；fib insn 1.53x/cyc 1.74x。§1 的 8B 逐符号分解定性结论不变（税源结构与 repr 无关），P-1 预验证与 Wave 1 首个 PMU 检查点须在 16B 上重做逐符号分解定量。16B Entry=280B、shift 寻址失效的已知 cyc 回退进一步抬高 W2-A 优先级。
> v1→v2 修订：新增 P-1 预验证；P5 降级并入 Wave 2（预算高估+Function.call 回退风险）；P2 逃逸点枚举修正；新增 Wave 2 结构刀（追平级）与 Wave 3；验收线算术修正；补 OOM 回归与漏测探针。

## 执行结果（2026-07-16～2026-07-17）

本计划的实验、止损和可行性分支均已执行；v2.10 将纯调用税降到 **261.007 insn/call**，达到终局
`≤265` 验收线。该结论只覆盖指令目标：纯调用税仍为 **54.679 cyc/call**，尚未达到 qjs 的周期水平，不能写成全面性能追平。施工在独立 worktree
`/home/aneryu/zjs-call-supernode`、分支 `perf/call-supernode` 上进行，起点为
`5bb624525488bde82a15651c3275984852352f58`。原工作目录的未提交内容未被修改。

上面的 v2.1 头部是立项时的历史口径；从 `5bb62452` 起步的性能施工 worktree 以
**8B NaN-boxed JSValue 为默认**、16B 为 `test-altrepr` 参考腿，因此本轮 PMU 和尺寸数据均按 8B 口径记录，并用 16B 测试腿守护兼容性。
合入 main 时保留了 `54a75913` 的 64-bit **16B 默认**，并在合并态重新验证默认 16B 与 alternate 8B；下文冻结 PMU 数字仍是原 8B
实验口径，不因合并后的默认值而重解释。

### 最终三方复测与 v2.10 续跑

CPU19（Cortex-X925），ReleaseFast，`armv8_pmuv3_1`，三方轮换 best-of-9；脚本 SHA 与二进制 SHA 冻结。qjs commit
`04be246001599f5995fa2f2d8c91a0f198d3f34c`，qjs 二进制 SHA
`b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`；起点二进制 SHA
`94de4f59f6c0f62cbe463ebb934b66322178f319acfa3cc9dfa896a0085125c3`，v2.3 baseline SHA
`5ce9c603ac83e36bf601b614f5359b5cb11e75b85f3afb9cf603b3b79fbd29c0`，v2.4 baseline SHA
`2f2b3e906b9534011e52d3db32bdb054f59bba5e78f13720621d7fe301aa0d79`，v2.5 最终 SHA
`ec2c535ffd270bdb4a0b3df200067b670c36877e8ce4c43c867216cf1c3853e6`。v2.6 续跑的同轮 v2.5 源码 baseline SHA
`268b1b3db7778ae60eac3f1e6fce55f561ff0e2a7c8afb9f98ec5cabdae1215d`，最终候选 SHA
`8bce8bbf44d3e51352491c02bad7822add19b87041b72531f75a63b49ec82ab9`。v2.7 clean-cache baseline/candidate SHA 分别为
`11e0a794e30b0b8f8c824ca9d221ecc38ae52b33c54766979a94d898fc805368` / `bc8e9d00a7fd9a38883512b8fc00a3ef1bdd4f1b08a63fead05ad69d8230404a`；
候选拒绝后普通单目标 fresh build 再次逐字节复现最终保留 SHA `8bce…`。call-const / control / fib
脚本 SHA 分别为 `bf05b6be…`、`e49098de…`、`26c695bc…`。
v2.9 冻结 v2.8 loadable image 为 baseline（SHA `5eeb369e…`），最终隔离 ReleaseFast 候选 SHA
`851faa803051c1fa84a198cd0f3285d65644b36adeff94499a0d4e3c408a82b7`。v2.10 以该 image 为阶段起点；最终 r35
ReleaseFast SHA 为 `a5ab4991010709e84a7fb6218ecc78f0e4d766072259113474d7420ee1c8a1ef`。

v2.3 校正了一个测量来源错误：v2.2 的 `b7abb7de…` 是从既有
`zig-out/bin/zjs` 直接复制的产物，并非由收口后的源码 fresh build；两次独立
ReleaseFast fresh build 均得到 `5ce9c603…`。因此 v2.2 旧 SHA 及其三方数字作废，`5ce9c603…` 保留为本次同轮复测的 v2.3 baseline。

v2.4 在同一 worktree 继续执行“单一活动 Stack facade + raw frame header”的最小可回退切片。删除测试先证明
`arg_buf` 是只有一个消费者的浅 cache，而 `function` cache 有 70+ cold-table 消费点、仍在赚取接口 leverage；随后只保留
`arg_buf` 派生化与 return 时冗余 `local_fast_blocked=false` 发布消除。最终源码与此前保留二进制各 fresh build 一次，均得到
`2f2b3e906b9534011e52d3db32bdb054f59bba5e78f13720621d7fe301aa0d79`；v2.3 fresh baseline 仍为
`5ce9c603ac83e36bf601b614f5359b5cb11e75b85f3afb9cf603b3b79fbd29c0`。

v2.5 继续清理 Entry 的浅状态发布：普通调用从不携带 Function.prototype.call 的 synthetic native frame，却在每次
push 时把 `native_caller` 写成 undefined，并在每次 return 进入完整 JSValue refcount/GC-phase 分类。现在 teardown 原有的
1B 状态字同时拥有 `has_native_caller`；普通 setup 的整字节发布自然清零该位，forwarded call 才写 payload 并置位，稀有释放
收进 noinline cold helper。两个同源码 fresh build 均得到 `ec2c535f…`，Entry 仍为 248B，后半字段 offset 不变。

v2.6 从回退到精确 v2.5 源码的单目标 fresh baseline 重新起算，拆开了此前仍被共享 handler 隐藏的 opcode decode 税：
`OP_call` 与 `OP_call0..3` 原来都指向一个 `op_call`，每次先执行五路 opcode select，再二次判断 PC advance；现在 dispatch table
分别指向同一个 comptime 语义体的五个实例，只把 `argc` 与 advance 固定，inline miss、OOM/catch、Entry setup 和 fallback
仍走同一源码。共享体为 0x630B；固定 argc 实例为 0x5e4B，operand 实例为 0x5e8B；总 `.text` 增 5,584B，但单次实际执行的
handler 反而缩小。baseline/候选在临时恢复源码后分别再次显式 `zig build zjs`，逐字节复现 `268b…`/`8bce…`；checkpoint
多目标图产生的另一链接布局未混入 PMU。

v2.7 先按架构审查的删除测试确认：`Stack` 同时拥有 reserve/grow refresh、arena/heap ownership、resume 和 teardown，属于仍在
赚取 leverage 的 deep implementation；浅缝是 call-source transport 与 setup 内重复派生。四路 concrete source、折叠 source union、
scalar `pushFrame` 和 scalar `setupSimple` 均做成 ReleaseFast 候选后止损：最好的版本约省 1～5 instructions/call，却分别付出
`.text` +16,856B、alloc +1.65% cycles、`pushFrame` +8 instructions/call，或 method/missing/for-of 超过 1% 的回退。每轮源码均完整
摘除；最终 fresh build 精确复现 v2.6 SHA `8bce…`，没有把失败 adapter 留在树内。

最后一个候选继续收窄到 resident-view capture slice。exact、borrowed-source 的 simple setup 已把 cached view 保持为 `function`，却仍为
capture 数量追一次 `target.fb -> var_refs_len`；候选直接读取同一 immutable FB 发布出的 `function.closure_var.len`，并在 target 发布处
用 Debug assert 固化两者相等。padded/snapshot/moved 实例继续走共享 accessor。热 `setupSimpleInlineEntry` 从 0x33cB 缩到
0x330B，五个 `op_call` handler 尺寸不变。第一次全实例版把 `forof_zero` 的 L1I refill 从约 0.15M 推到 20.15M，立即拒绝；
exact-only 再给 2KB `finishForOfNextResult` 显式 64B 函数对齐后，既有 cache 图产物 `4997…` 一度恢复原虚址，但独立 cache
fresh audit 得到真实候选 `bc8e…`（`.text` +416B），证明 `4997…` 只是构建图布局产物，不能充当 final。

clean/clean PMU 中该候选仍省约 1 instruction/call，fib/method cycles 也下降；但 alloc 扩到 15 轮后 cycles 独立 best
仍为 **+1.100%**（整体中位 +0.994%、配对中位 +0.974%）。按预先声明的 1% 门禁，resident-view 与对齐两处源码全部摘除。
回退后的普通单目标 fresh build 逐字节复现 `8bce…`，`.text/data/bss` 恢复 `4,505,901 / 201,864 / 263,040`B；v2.7 没有新增
保留代码。

v2.8 先尝试把 `enterEntry`、`reloadTop`、`reloadAfterPop` 与 grow 后的 base refresh 收回一个 execution-transition interface。
该结构层不改语义，却在同一普通构建图中令 `.text` 增 496B，并扰动 `.bss`；删除测试成立但编译产物不再中性，因此立即摘除，
没有为“更像架构”保留零性能 leverage 的 wrapper。随后把默认表示 Entry 原有 16B stride padding 改成 raw caller `pc/sp`：带
validity 的版本约多 **19 instructions/call**，去掉 runtime validity、覆盖全部生产 entry 后仍多约 **11 instructions/call**；两版都因
跨 teardown 的 store/load 与寄存器分配扩大 `op_return`，call/method/for-of cycles 越过或逼近 1% 门禁，完整回退。

最后验证 call-target transport：同时删除 operand source 已拥有的 `callable` 与恒为 undefined 的 `new_target`，clean 候选 SHA
`b70add3b…` 相对 clean baseline `7efa68dc…` 使 `.text` −676B、纯税 **413.179→410.192 insn/call**，但 cycles
**72.499→74.013**（+1.514），call/fib independent-best 分别 +1.286%/+1.175%。保持原物理 stride 的 padding 版把 cycles 拉回门内，
却令纯税 +1.000 instruction/call；只删尾部 `new_target` 的最后归因版虽省 0.989 instruction/call，纯税 cycles 仍 +1.555、fib
paired +1.169%。这也复核了账本中既有 W2-A InlineTarget 结论；三版均摘除。最终普通构建产物 `fd75765b…` 与冻结 `8bce…`
虽然因非加载元数据而整文件 SHA 不同，但 `.text/.rodata/.data` section hash、热符号地址/尺寸及
`4,505,901 / 201,864 / 263,040`B 完全一致，v2.8 仍无新增保留代码。

v2.9 按 v2.8 收口结论真正改造活动 operand window，而不是再包一层 transition adapter。`Stack` 仍是拥有 reserve/grow、
arena/heap/resident backing、generator 移交和 teardown 的 deep module，物理尺寸保持 40B；其中 backing base 与 live top 改为
两个 raw pointer，`top_ptr` 成为唯一权威 live-prefix 终点。push/pop/grow、cold helper、exception/for-of、generator suspend/resume
以及所有 VM shard 均读取同一表示，tail-threaded `publish/syncSp` 只需写一个 pointer，grow 后仍显式 refresh raw base。

第一版只替换 Stack 表示，约省 2 instructions/call，却在 arguments 形态出现超过门槛的 cycles 回退。第二版让 inline setup 在
caller 预先 retreat top，纯税降到约 406.18，但新增的浅 `pushTruncatedCall` wrapper 使 `.rodata` +48B、`.text` 起点后移 64B；
allocation 的 L1I refill 中位从约 98.9k 升到 101.4k，cycles +1.314%，拒绝。删除 wrapper、让既有 `pushCall` 直接声明
“top 已等于 source start”的契约后，section 起点恢复，allocation 转为改善，r3 的纯税为约 406.195 insn/71.663 cyc。

随后用 raw source pointer 取代 `sp → region_base index → pointer` 往返：plain/method/getter 热路径直接携带 `sp-total`，setup 和
失败 cleanup 从 backing capacity 内的 off-window source slots 完成所有权转移。r4 纯税进一步到约 402.171/71.112。删除测试又发现
tagged `ArgsSource` 即使去掉只供 Debug 断言的 Stack 指针仍为 32B，真正的物理 seam 是 union tag + moved slice；最终统一为 16B
`values pointer + packed { arg_count, has_receiver, moved }`。中间存 `value_count` 的 r5 令 method 多约 13 instructions/call，未直接
保留；改存两种入口本来都已知的 `arg_count` 后收回约 6 条 method 指令，同时保留 plain 的收益，形成 r6 final。

r6 相对冻结 baseline 的 21 形态 × 9 轮 direct A/B 全部过门：allocation/property/for-of cycles best 分别
−0.971%/−1.035%/+0.228%，cold arguments 最差正向变化仅 +0.097%；method、fib、closure、Function.call cycles 分别
−2.253%/−2.370%/−2.043%/−2.980%。最终 `.text/data/bss` 为
`4,505,949 / 201,864 / 262,992`B，即相对 baseline text 仅 +48B、bss −48B；未加地址 padding 或虚假对齐来制造门禁通过。

### v2.10 终局续跑：静态 empty-leaf 与 warm frame

v2.10 没有把 `push_1; return` 或任何常量函数体融合进 call handler。它在不可变 Bytecode view 上发布
`simple_inline_empty_leaf`：普通 sloppy、exact argc=0、无参数/locals/capture/open binding、arguments 物化与 direct eval 的函数，
可使用一个更深的 frame constructor。这里的 “empty” 指词法 frame 形状，不指函数体；callee 的任意字节码仍由通用 handler 执行，
可以分支、递归或抛异常，因此正常 return 与 abrupt teardown 仍分别覆盖完整所有权语义。

r18 用专用 deep constructor 去掉通用 geometry/capture selector，将纯税从 v2.9 的 395.177 降到 **324.007**；r19 把
receiver-independent resolver prefix 独立为 `ResolvedInlineFunction`，避免命中该形状前构造完整 `InlineTarget`，降到 **317.007**。
r20～r22 的 arena-restore 变体虽曾到约 314，却让 control cycles 越过 1%，全部回退；r24 不计性能收益，专门把正常 return 与
abrupt teardown 拆开并加入 pending operands 释放回归。r25 的 typed object release 降到 **310.007**，r26 的 leaf continuation
降到 **308.007**。

r27/r28 的 warm push 一度到 **274.007**，但 method 或 allocation cycles 分别越线，未原样保留。r29 改为从当前 active arena chunk
做带 mark 的原位 carve，miss 保持纯净并回落权威 cold constructor，达到 **269.007** 且负对照过门。r30～r34 继续删掉热路径上的
容量派生与重复发布：增加 Runtime policy word、压缩同一 `stack_size` slot、cold-miss repair、截断超大 stack-size getter、缩窄 arena
index 等版本，分别因 allocation instructions、call/allocation/fib cycles、公开 getter 语义或稳态 codegen 回退而拒绝。

r35 保留完整 `usize stack_size`，用 packed `RuntimeCompactState` 合并原有冷状态以腾出预计算 arena policy 的一个 word，并让
`finishEmptyLeafFrame` 只发布一次 teardown state。相对直接 retained baseline r29 再省 **8.000 insn/call**，形成最终
**261.007 insn/call、54.679 cyc/call**。最终 image section 为 `.rodata` 164,664B、`.text` 4,118,800B、
`.data.rel.ro` 181,248B、`.data` 19,408B、`.bss` 64B；没有地址 padding、常量答案或测试专用分支。

| 实现 | call-const insn | control insn | 纯调用税 insn/call | 纯调用税 cyc/call | fib insn | fib cyc |
|---|---:|---:|---:|---:|---:|---:|
| 施工起点（历史冻结） | 6,796,728,748 | 2,274,681,471 | **452.205** | **80.317** | 4,897,432,316 | 907,852,638 |
| v2.3 fresh baseline | 6,646,682,797 | 2,274,978,280 | **437.170** | **75.578** | 4,808,820,666 | 900,832,403 |
| v2.4 同轮 baseline | 6,588,049,481 | 2,276,205,012 | **431.184** | **74.640** | 4,749,258,877 | 840,813,962 |
| v2.5 最终保留实现 | 6,518,014,604 | 2,276,228,872 | **424.179** | **74.044** | 4,692,647,394 | 840,727,503 |
| v2.6 同轮 baseline（精确 v2.5 源码 fresh） | 6,518,053,196 | 2,276,198,890 | **424.185** | **73.542** | 4,725,034,151 | 878,235,453 |
| v2.6 最终保留实现 | 6,407,882,656 | 2,276,193,554 | **413.169** | **72.636** | 4,603,884,738 | 850,291,522 |
| v2.7 clean baseline（冻结 v2.6） | 6,406,423,714 | 2,274,579,617 | **413.184** | **73.008** | 4,602,235,956 | 829,994,189 |
| v2.7 resident-view 候选（拒绝） | 6,396,367,147 | 2,274,592,735 | **412.177** | **73.150** | 4,594,113,963 | 823,468,049 |
| v2.7 最终保留（等于 v2.6） | 6,407,882,656 | 2,276,193,554 | **413.169** | **72.636** | 4,603,884,738 | 850,291,522 |
| v2.8 clean baseline（target transport 同轮） | 6,406,393,445 | 2,274,604,020 | **413.179** | **72.499** | 4,602,244,309 | 846,836,715 |
| v2.8 双字段 target compaction（拒绝） | 6,376,459,592 | 2,274,536,706 | **410.192** | **74.013** | 4,578,046,745 | 856,788,573 |
| v2.8 `new_target` 单字段归因（拒绝） | 6,396,378,603 | 2,274,561,051 | **412.182** | **73.976** | 4,594,196,888 | 854,692,242 |
| v2.8 最终保留（等于 v2.6） | 6,407,882,656 | 2,276,193,554 | **413.169** | **72.636** | 4,603,884,738 | 850,291,522 |
| v2.9 direct baseline（冻结 v2.8 image） | 6,406,792,815 | 2,274,933,908 | **413.186** | **73.149** | 4,602,620,953 | 834,135,370 |
| v2.9 最终保留（raw top + compact source） | 6,226,376,779 | 2,274,603,982 | **395.177** | **69.664** | 4,456,854,515 | 814,367,415 |
| v2.10 r18（deep empty-leaf constructor） | 5,512,009,723 | 2,271,940,082 | **324.007** | **60.334** | 4,259,074,218 | 789,872,171 |
| v2.10 r19（resolver prefix） | 5,442,009,663 | 2,271,940,193 | **317.007** | **58.798** | 4,259,074,318 | 798,640,686 |
| v2.10 r25（typed object release） | 5,372,009,518 | 2,271,940,024 | **310.007** | **58.299** | 4,259,074,179 | 801,437,036 |
| v2.10 r26（leaf continuation） | 5,352,009,680 | 2,271,940,206 | **308.007** | **58.471** | 4,259,074,351 | 796,859,722 |
| v2.10 r29（warm active carve） | 4,962,009,720 | 2,271,940,229 | **269.007** | **54.767** | — | — |
| v2.10 r35 最终保留 | 4,882,010,058 | 2,271,940,589 | **261.007** | **54.679** | 4,226,764,281 | 803,230,044 |
| qjs | 4,725,886,563 | 2,344,993,928 | **238.089** | **40.468** | 3,123,474,193 | 557,230,196 |

结论：v2.5 相对同轮 v2.4 baseline 再省 **7.006 insn/call、0.596 cyc/call**。v2.6 相对自己的 fresh baseline
再省 **11.017 insn/call、0.905 cyc/call**；fib 为 −2.564% instructions、−3.182% cycles，closure 为
−1.690%/−1.356%。v2.7 clean 候选相对同轮 baseline 的独立 best 约省 **1.007 insn/call**、cycles +0.142；同轮配对中位为
−1.000 insn/call/−0.456 cyc/call。fib 配对 −0.174%/−0.890%，closure −0.114%/+0.589%，method −0.505%/−1.488%，
但 alloc 15 轮 best +1.100% 令整刀拒绝，不能计入累计收益；到 v2.8 收口时最终实现仍是 v2.6。

v2.8 又确认：raw resume 与 target compaction 都能在局部汇编或 instruction 指标上展示预算，但该预算会通过寄存器分配和代码布局
转成 cycles 回退。最强 target 候选的 −2.987 instructions/call 不能覆盖 +1.514 cycles/call；最终累计数字因此不变。

v2.9 的 authoritative operand window 相对自己的 direct baseline 再省 **18.009 insn/call、3.486 cyc/call**；fib 为
−3.167% instructions/−2.370% cycles，closure 为 −2.067%/−2.043%，method 为 −1.517%/−2.253%，不是只优化 plain call0。
v2.10 再把 v2.9 final 的 **395.177→261.007 insn/call**（−134.170，−33.96%）与
**69.664→54.679 cyc/call**（−14.985，−21.51%）。最终相对 qjs 只剩 **22.918 insn/call**（1.096x），达到 `≤265`
终局线；周期仍差 **14.211 cyc/call**（1.351x），因此只宣告指令目标达成，不宣告周期追平。

四指标权衡必须显式记录：v2.4 的 fib branch-miss 历史分叉仍存在；v2.5 同轮 fib branch-miss/L1I 均微降且 cycles 中性，
const L1I best 约 +8% 但 const cycles −0.66%。15 轮扩展矩阵中 alloc/property cycles 为 +0.21%/+0.04%，method/closure
为 −0.12%/−0.27%；Function.call 因稀有 cold helper 多约 6 instructions/call（+0.52%），cycles −0.22%。该权衡没有被隐藏，
也没有用指令 padding 修饰结果。

v2.6 的扩展矩阵覆盖 call0/1/2/3 与 operand argc=4：call3 为 −1.843% instructions/−3.400% cycles，argc=4 为
−1.030%/−0.775%；strict、arrow、missing、two-arg 均受益。未改的 Function.call 与 method-arguments 中性；for-of 15 轮
best/整体中位为 +0.823%/+0.735% cycles，仍在 1% 门内。固定虚址前端复核没有被包装成“全降”：call0 的 L1I 中位多约
39k/10M calls、branch miss 多约 2.7k/10M；closure L1I 微降，fib 两项均降，for-of branch miss 多约 5.5k/2M。
这些绝对量权衡没有抵消上述 call/fib/closure cycles 收益，但继续说明代码布局不是免费变量。

v2.7 clean 候选的 15 形状 × 9 轮配对矩阵中，property、for-of、strict、arrow、missing 与 method-arguments 均在 1% 门内；
method/fib cycles 分别 −1.488%/−0.890%。唯独 alloc 的 9 轮独立 best/中位为 +1.028%/+1.028%，扩到 15 轮后仍为
+1.100%/+0.994%（配对 +0.974%）。门槛按预先声明的独立 best 执行，不能用刚好低于 1% 的配对中位覆盖失败；候选完整回退。

v2.9 的最终矩阵没有把中间失败藏掉：r2 因新增 wrapper 导致 allocation +1.314% cycles 而拒绝，r5 的 `value_count` metadata
令 method 多约 13 instructions/call 后改为 `arg_count`，r6 才进入最终 direct A/B。r6 的 arrow instructions −2.069%、strict
−3.124%、two-arg −2.518%、missing −1.559%；arguments 系 instructions 均不回退，cycles 的两个正值仅 for-of +0.228% 与
cold-missing +0.097%。这组结果同时覆盖 source representation、setup selector 与未改调用形态。

v2.10 r35 相对直接 retained baseline r29 的独立 best PMU 为：allocation +0.107% instructions/−0.729% cycles，closure
−0.482%/+0.147%，call-const −1.612%/+0.211%，control 约 0%/+0.815%，fib −0.759%/+0.536%，method
−0.508%/+0.765%，strict-method-arguments −0.080%/−0.357%，strict0 −0.501%/+0.929%，for-of
−0.287%/+0.518%，property 约 0%/+0.031%。所有 authoritative independent-best cycle 变化均在 1% 门内。method/strict0
扩到 15 轮后的整体中位分别为 +1.071%/+1.030%，但同轮配对中位为 +0.963%/+0.989%；这个贴线布局权衡保留在账本中，
没有用总体中位或单次低值替换预先声明的 independent-best + paired 口径。

### 决策账本

| 刀 | 结论 | 关键证据 |
|---|---|---|
| V1 / P4 | **拒绝** | 强制内联 `pushFrame` 增加约 2–3 insn/call，method cycles 约 +5%；融合预算不存在。 |
| V2 / P3 | **拒绝** | `next→cont` 虽省约 7 insn/call，objalloc cycles +1.55%；V3 还证明普通 call 合法地可在逻辑 `code_end` 恢复，直跳前提为假。 |
| P0 | **保留** | 新增逻辑末端 call、Function.call 栈序、inline 参数释放、Machine 逃逸 teardown、生产构建递归中断、arrow direct-eval / arrow-super capture、resident generator 拒绝 inline Entry 等永久回归。 |
| P1 | **保留** | 四个进入路径共享 `enterEntry`；三探针约 −0.02%，行为/性能中性。 |
| P2 | **拒绝** | 两个真实静态 flag 版本均回退：call instructions +1.6%～+1.9%，cycles +3.4%～+4.7%。 |
| P6 | **保留** | 入库 arrow、arrow-this、fib(30)×3 探针；control 已在树内。 |
| W2-D | **保留** | FB 发布前建立不可空 cached view；相对 P1，const −0.735% insn、method −0.365%、Function.call −0.085%，负对照过门。 |
| W2-B | **保留** | arrow `this/new.target` 改普通 closure cells，direct eval 同路径；相对 W2-D，arrow −4.629% insn/−4.524% cyc，arrow-this −13.882%/−10.102%；普通 call 亦约 −1.1%～−1.3% insn。Function.call 的 arrow 转发也保留。 |
| W2-C | **拒绝** | 完整 Entry realm + enter/return/error/tail 切换语义测试虽绿，普通 call 增 1–2 insn，arrow cycles 在两轮修复后仍 +1.34%～+1.90%。跨 realm 继续走正确的慢路径。 |
| W2-E | **拒绝** | `Entry.prev` free-list 省约 5 insn/call，但 call cycles +1.26%～+1.79%；`ctx.call_depth` 索引版只省约 1 insn，cycles +3.17%～+3.66%。 |
| W2-A（部分） | **保留两片，原整刀未成立** | Stack policy 48B→40B；`new.target` 移入 FrameCold，Frame 144B→136B、Entry 256B→248B。进一步 Stack32、Entry240、Frame128 分别令 alloc/closure 等负对照回退；Frame128 的 15 轮复核为 closure +2.317%、alloc +3.290% cycles，已回退。当时延期的完整活动视图改造后来由 v2.9 `W3-WINDOW` 作为独立、全消费者迁移完成，不能倒算为本刀收益。 |
| W2-A（InlineTarget） | **拒绝** | 在 fresh/fresh 口径删除恒为 undefined 的 `new_target`，48/72B→40/56B：instructions 约省 1～2/call，但 15 轮确认 const +1.424%、strict +1.389%、纯调用税 +1.879% cycles。恢复尺寸的 byte/typed padding 生成完全相同 `.text`，周期恢复但纯调用税 +1.008 insn/call，closure/fib 亦约 +1/call。根因是 ReleaseFast 把原 `isUndefined` assert 当优化假设，通用 setup 反而少 44B；全部回退。 |
| W3-STATE（`arg_buf`） | **保留** | 删除单消费者 cache，`get_arg_short` 从 `frame.args.ptr` 派生；保留 8B layout slot，隔离 Vm 后半字段位移。汇编在 enter/return 各删 `ldr+str`，每次 `get_arg` 只多一条依赖 load。15 轮纯调用税约 −4.00 insn/call，cycles best/median −0.96/−0.60；fib −0.926% insn、−4.24% cycles，objalloc +0.07% cycles 过门。fib branch miss 的 +11% 布局权衡见上文。 |
| W3-STATE（return false 发布） | **保留** | inline callee 的 `local_fast_blocked` 必为 false；`reloadAfterPop` 回 inline caller/普通 L0 不再重复发布 false，仅 stop-boundary L0 写 true，并以 Debug assert 固化不变量。15 轮纯调用税约 −2.00 insn/call；fib −0.347% insn/−0.604% cycles，扩展负对照过门。 |
| W3-ENTRY（native caller ownership） | **保留** | `native_caller` 只属于 Function.call 转发帧。直接加 undefined guard 令普通 return 多 2 条指令，汇编阶段拒绝；最终把 ownership 位并入现有 1B teardown 状态字，普通 push 热臂删 join branch + undefined materialize/store，普通 return 只做 bit-test，真实释放进 cold helper。15 轮纯调用税 best/median −6.993/−7.180 insn、−0.387/−0.448 cyc；fib −1.190% insn/+0.133% cyc，alloc +0.212%、property +0.042% cycles 过门。Function.call instructions +0.515%/cycles −0.218% 的稀有路径代价已记录。 |
| W3-ENTRY（continuation 发布） | **拒绝** | valid-bit 版普通税再省约 1 insn/call，但 for-of median cycles +1.25%、alloc best +1.16%；把三态 action 压入 teardown byte 后 for-of 恢复中性，却因 `ubfx`+action spill 令纯调用税 +4.004 insn/call。两轮止损，action/payload 协议完整回退；fresh SHA 与保留基线逐字节一致。 |
| W3-PROFILE | **无税可删** | 默认 ReleaseFast 的 `zjs_enable_opcode_profile=false`，`CallProfileGuard` 是零尺寸空实现；热汇编中的 arena 状态不是 profiler guard。未为不存在的税增加 cache/分支。 |
| W3-STATE（`function`） | **拒绝** | 保留同位 padding 后把 70+ 消费点改读 `frame.function`。零参数约省 2 insn/call，但 fib cycles +1.59%、closure +1.65%、two-arg +1.72%、one-arg 约 +3%；删除测试与 PMU 均证明该 cache 有 leverage，完整回退。 |
| W3-STACK（raw return length） | **拒绝** | `sp` 直送 `popFrameAtStackLen` 可再省约 3.97 insn/call/0.94 cyc，但 objalloc cycles +3.03%。将 general materialization 收进 cold implementation 的第二版仍 +1.60%，按“两轮修复不果即摘除”止损，未用代码 padding 粉饰布局。 |
| W3-CC | **不可用** | Zig 0.16 未暴露 `preserve_none/preserve_most`；`.auto` 仅生成 LLVM `fastcc`，AArch64 musttail 与当前 C ABI 汇编相同（均保存/恢复 x29/x30）。 |
| W3-CC（普通 C ABI 携带 `stack_base`） | **拒绝** | 在现有四参数 tail chain 上用 x4、再用 x5 携带第五个状态，确实把纯调用税再省约 5 insn/call；但 x4 版 fib/closure/alloc cycles 分别 +1.54%/+2.23%/+4.07%，换 x5 无改善。最后一次在 non-tail helper 后重载以截断活跃区间，虽令 fib/closure 转为 −1.29%/+0.05%，却把 control/alloc/property 推到 +2.18%/+2.56%/+1.53%。两轮止损，tailcall 源码 SHA 恢复为实验前 `6c4b…`。这证明缺的不是“再占一个 C ABI 参数”，而是 preserve-none 类跨 handler 协约。 |
| W3-DISPATCH（callee entry 首跳） | **拒绝** | 新 Entry 的 `pc==code_base`，可安全绕过 `next`，约省 4 insn/call；但直接版 closure cycles best/paired-median +1.07%/+1.03%。给同样高频的 `op_call` 做 64B 对齐后 closure 回到 +0.70%，无调用 control 又变为 +1.01%/+1.13%。两版各有负对照越线，完整摘除；没有把 caller 可恢复到 `code_end` 的已证伪前提偷渡回来。 |
| W3-CALL-ARITY | **保留** | dispatch table 将 `OP_call`/`OP_call0..3` 指向同一 comptime 语义体的五个 argc 实例，删掉每 call 的五路 opcode select 与重复 advance 判断。15 轮纯调用税 424.185→413.169 insn/call、73.542→72.636 cyc/call；fib −2.564%/−3.182%，closure −1.690%/−1.356%。call3 与 operand argc=4 也分别为 −1.843%/−3.400%、−1.030%/−0.775%，不是只优化 call0 基准；未改路径和负对照过门。代价是 `.text` +5,584B，前端绝对计数权衡已单列。 |
| W3-SOURCE（concrete/scalar transport） | **拒绝** | 四路 concrete source 的 plain 路径约省 5 insn/call、method 约 −2%～−3%，但 `.text` +16,856B；折叠共享 general setup 后仍 +1,592B 且 alloc cycles +1.65%。单一 scalar `pushFrame` 虽只 +188B，却因保存 x19～x27 约多 8 insn/call。三版均完整回退，ReleaseFast SHA 精确恢复 `8bce…`。 |
| W3-SETUP（scalar ABI） | **拒绝** | 全链 scalar setup `.text` −124B、纯税约 −0.979 insn/call/−0.54% cycles，但 for-of zero/constant/self 复核约 +0.97%/+1.86%/+1.15%；local-scalar 版约省 0.995 insn/call，却让 method/missing 分别 +8.9%/+10.5% cycles。接口搬运的局部汇编收益无法跨形状成立。 |
| W3-CAPTURE（resident view exact slice） | **拒绝** | exact borrowed-source 实例从已驻留 view 取 capture 长度，热 setup 0x33cB→0x330B、纯税约 −1 insn/call；全实例版先触发 20.15M L1I 灾难。exact-only + 64B 完成器对齐的 clean 候选仍 `.text` +416B，alloc 15 轮 cycles best +1.100%，按门禁回退；普通 fresh build 精确恢复 `8bce…`。 |
| W3-TRANSITION（活动 level interface） | **拒绝结构层** | 统一 bind/refresh seam 的 inline wrapper 行为零变化，但同一普通构建图 `.text` +496B 且链接布局漂移；删除测试的 locality 收益不足以支付实际 codegen 成本，源码精确回退。 |
| W3-RESUME（padding-backed raw `pc/sp`） | **拒绝** | Entry 仍为 248B，但 validity 版约 +19 instructions/call；让所有生产 Entry 必有 raw resume、删除分支后仍约 +11。store/load 跨 teardown 扩大 return handler，call/method/for-of cycles 不过门；两轮完整摘除。 |
| W3-TARGET（callable/new.target transport） | **拒绝** | 双字段版 `.text` −676B、纯税 −2.987 instructions/call，却 +1.514 cycles/call；原 stride padding 版变成 +1 instruction/call；`new_target` 单字段版仍 +1.555 cycles/call、fib paired +1.169%。既有 W2-A InlineTarget 结论得到复核，没有把字段删除包装成保留优化。 |
| W3-WINDOW（authoritative raw top） | **保留** | 40B Stack 以 raw base + authoritative `top_ptr` 表示 live prefix，所有 hot/cold/grow/generator/teardown 消费者迁到同一 interface；caller 在进入 setup 前一次 retreat top，失败 cleanup 直接释放 backing capacity 内的 off-window source。新增 wrapper 的 r2 因 `.rodata`/L1I 令 alloc +1.314% cycles 而拒绝；删 wrapper 后负对照恢复。 |
| W3-WINDOW（compact source） | **保留** | call seam 直接携带 `sp-total`，删除 pointer→index→pointer 往返；32B tagged source 统一为 16B pointer + packed `arg_count/receiver/moved`。`value_count` 中间版的 method +13 instructions/call 未保留；最终版 direct A/B 纯税 413.186→395.177 insn/call、73.149→69.664 cyc/call，21 形态矩阵与全部语义门禁通过，text 仅 +48B。 |
| W3-LEAF（静态形态 + deep constructor） | **保留** | Bytecode view 发布 receiver-independent 的 `simple_inline_empty_leaf`，resolver prefix 不构造无用的完整 target；r18/r19 将纯税 395.177→324.007→317.007。形态不检查或融合 body，任意 callee bytecode 仍进入通用 dispatch。typed object release 与 leaf continuation 继续把 r25/r26 降到 310.007/308.007。 |
| W3-LEAF（return / abrupt teardown） | **保留，正确性刀** | r24 将 normal return 的空 frame unlink 与 abrupt pending-operands 清理分开；throw/catch 仍走通用异常可观察性。新增回归证明 pending values 与 source ownership 均释放，不把异常路径当作“不发生”。 |
| W3-LEAF（warm active carve） | **保留** | first-use、chunk switch、heap fallback、OOM 与 stack overflow 仍走权威 cold constructor；warm hit 用 `carveActiveMarked` 原位取得 arena window，miss 对 call depth、mark、source ownership 与 Machine links 完全无副作用。r27/r28 因 method/allocation cycles 越线未原样保留，r29 修正后到 269.007。 |
| W3-LEAF（runtime policy + one-shot publication） | **保留** | Runtime 预计算 arena window policy，但继续完整保存公开 `usize stack_size`；原有冷状态压为一个 byte，Runtime 不增大。`finishEmptyLeafFrame` 只发布一次 teardown。r35 相对 r29 再省 8.000 insn/call，最终 261.007，全部 authoritative independent-best cycle 门禁过线。 |
| W3-LEAF（r20～r34 失败变体） | **拒绝** | arena restore、额外 Runtime word、复用 stack-size 高位、cold miss repair、超大 getter 截断与 u32 arena index 等方案，分别因 control/allocation/call/fib cycles、allocation instructions、公开 API roundtrip 或稳态 codegen 失败而完整摘除；最终实现不继承这些语义或布局捷径。 |
| W3-CLUSTER（body fusion） | **不实施** | 只融合 `push_1; return` 常量体会绕过通用调用机制、只优化验收基准；通用 body cluster 则要重新设计异常/backtrace/interrupt 语义。v2.10 的 empty-leaf 是 frame-shape constructor，函数体仍逐 opcode 通用执行，因此不改变本项结论。 |

### Wave 3 残差分解

修复 arrow-super 前的保留二进制 `9153d40d…` 上，call-const 与 control 的同机
`perf record` 差分把当时 75.3 cyc/call 的税主要闭合到：

- `op_return` 约 18.7 cyc/call；
- call 独有的 `next` 转换约 15.7 cyc/call；
- `op_call` 约 15.7 cyc/call；
- `setupSimpleInlineEntry` 约 11.6 cyc/call；
- `pushFrame` 约 4.4 cyc/call。

五项合计约 66.1 cyc/call。残差不是某个可删 guard，而是活动 Frame/Stack 的发布、重载、异常与 backtrace 可观察性共同形成的边界。
v2.5 已验证第三个最小状态/所有权切片可独立获益，也验证 continuation 发布与 raw return length 一旦扩大刀面就会触发
专项或布局负对照止损。v2.6 又确认共享 `op_call` 中还残留一项真正的 opcode decode 税；逐 opcode specialization 将其删除后，
同轮残差降至 413.169 insn/72.636 cyc per call。普通 C ABI 多携带一个长期活跃参数和 entry-only 首跳则分别被寄存器压力、
布局负对照否决，不能计入后续预算。v2.7 又封死了 concrete/scalar source adapter：局部少搬字段不能补偿跨 helper 的寄存器压力；
resident-view 派生虽有约 1 insn/call 的真实预算，也被 alloc 负对照否决，最终残差仍停在 v2.6 的 413.169 insn/72.636 cyc per call。
v2.8 又证明：仅把现有字段同步包成 deep-looking interface 会增加 codegen，复用 padding 缓存 raw frame header 则让 return 的
寄存器分配恶化；它们都不是完整 Stack facade 的安全垫脚石。v2.9 随后完成了这里要求的活动 operand-window 权威表示，并一次性
证明 publish、grow refresh、generator resume、exception/backtrace、OOM cleanup 与 teardown：raw top + compact source 将同轮残差降到
395.177 insn/69.664 cyc per call，而没有增加浅 adapter。

v2.10 没有沿用 413 阶段的符号比例，也没有把 source/setup/target transport 换名重跑。r18～r35 找到的是更深的 frame-shape seam：
在 Bytecode 发布期证明空词法 frame，cold constructor 保持权威，warm hit 只旁路重复的通用 frame 几何与 arena bookkeeping；函数体、
异常与 teardown 语义仍共用原执行机制。该序列把残差闭合到 **261.007 insn/54.679 cyc per call**，终局 instruction 线已完成。

本计划不再以 instruction 目标为理由继续扩大刀面。若继续性能工作，应另立 cycle-focused 续案，以 **14.211 cyc/call** 的 qjs 残差
重新 profile，并继续覆盖异常、backtrace、interrupt、generator 与 GC 可观察性；preserve-none handler ABI 或直接执行
FunctionBytecode 仍可能是结构前沿，但不是本计划完成状态的前置条件。

### 收口验证

第一次 full test262 没有被“known 化”：它暴露了
`superPropDerivedCalls.js` 与 `superPropHomeObject.js` 两条 unexpected。最小复现和反汇编证明 arrow 内的 `super.prop` 发出了 `push_this`，却没有请求普通 `this` closure cell；先加入 parser / exec 红灯测试，再让共享 `emitSuperThis` 走同一词法捕获链。原两条 test262 随后 2/2 通过，最终 full gate 无 unexpected。
v2.6 的 handler specialization 不改语义分支，仍重新执行 checkpoint、call-expression 92 项切片、full test262、16B、force-GC、OOM 与最终一次 ReleaseSafe；结果如下。v2.7 的最终 resident-view 候选不新增语义分支，也通过了 checkpoint、call-expression、16B 与 ReleaseSafe，但随后因性能门禁失败而回退；这些绿灯只证明候选语义正确，不把它变成保留实现。v2.8 的 raw-resume 与 target-transport 候选各通过 `test-exec` 222/222 后才进入 PMU，并都因性能门禁失败而回退；最终 loadable image 逐 section 恢复冻结 v2.6，因此 full test262/force-GC/OOM 与最终 ReleaseSafe 仍由已经通过的 v2.6 final 覆盖。
v2.9 改动 Stack/ArgsSource 的真实所有权表示，不能复用旧门禁：r6 final 重新执行 checkpoint、call-expression、full test262、16B、
force-GC、OOM，并只在最终保留决定后执行一次 ReleaseSafe，结果如下。
v2.10 又改动 Bytecode shape publication、Entry teardown、VM arena policy 与 JSValue typed release，同样不能借用 v2.9 绿灯。
r35 final 已重新执行 changed-area、quick、checkpoint、16B、OOM 和 16B full test262，并只在最终保留决定后执行一次 ReleaseSafe。

| 门禁 | 最终结果 |
|---|---|
| v2.10 changed-area | `test-core` 229/229；`test-exec` 224/224；`test-bytecode` 90/90 |
| v2.10 `quick-check` | 8/8 steps；CLI smoke 3/3 |
| v2.10 `checkpoint-check` | 32/32 steps；unified 1441/1441；smoke、architecture、public API、test262-smoke 12/12 全绿 |
| v2.10 `test-altrepr`（16B） | unified 1441/1441；2/2 outer steps |
| v2.10 `test-oom` | 8/8 |
| v2.10 `test262-gate -Dzjs_nan_boxing=false` | prepared 49,775/53,293；44,599 passed；known 2；feature skip 5,174；exclude 3,518；unexpected 0 |
| v2.10 `test -Doptimize=ReleaseSafe` | unified 1441/1441；9/9 steps；0 failed |
| `git diff --check` | 通过 |
| v2.10 PMU | r29 vs r35 direct A/B；纯税 269.007→261.007 insn、54.767→54.679 cyc；全部 authoritative independent-best cycle 门禁 <1%，method/strict0 贴线权衡已记录 |
| v2.10 final image | SHA `a5ab499101…`；`.rodata/.text/.data.rel.ro/.data/.bss` 为 `164,664 / 4,118,800 / 181,248 / 19,408 / 64`B |
| main 合并态 changed-area（默认 16B） | `test-core` 239/239；`test-bytecode` 90/90；`test-exec` 227/227 |
| main 合并态 `checkpoint-check` | 32/32 steps；unified 1454/1454；CLI smoke 3/3；test262-smoke 12/12；architecture 与 public API 全绿 |
| main 合并态 `test-altrepr`（8B） | unified 1454/1454；2/2 steps |
| main 合并态 `test-oom` | 8/8 |
| main 合并态 `test262-gate`（默认 16B） | prepared 49,775/53,293；44,599 passed；known 2；feature skip 5,174；exclude 3,518；unexpected 0 |
| main 合并态 `test -Doptimize=ReleaseSafe` | unified 1454/1454；9/9 steps；0 failed |
| v2.9 历史语义门禁 | parser 334/334、exec 222/222、checkpoint unified 1438/1438、call-expression 92/92、full test262 unexpected 0、force-GC 222/222、16B 1438/1438、OOM 8/8、ReleaseSafe 1438/1438 |
| v2.5 fresh final | 两次同源码 ReleaseFast 构建 SHA 均为 `ec2c535f…`；continuation 等未过门候选已完整回退 |
| v2.6 fresh final | 精确源码恢复后 baseline/final 均逐字节复现 `268b…`/`8bce…`；C ABI carry 与 entry-first-dispatch 候选均完整回退 |
| v2.7 拒绝候选 `checkpoint-check` | 32/32 steps；unified 1438/1438；smoke、architecture、test262-smoke 全绿 |
| v2.7 拒绝候选 call-expression test262 | 92/92 passed |
| v2.7 拒绝候选 `test-altrepr`（16B） | 1438/1438 |
| v2.7 拒绝候选 `test -Doptimize=ReleaseSafe` | 1438/1438，9/9 steps；本轮仅执行一次 |
| v2.7 final restoration | 普通单目标 fresh build SHA 精确恢复 `8bce8bbf…`；`.text/data/bss` 与热符号虚址均一致 |
| v2.8 拒绝候选 `test-exec` | raw-resume、target-transport 均为 222/222 |
| v2.8 final restoration | `.text/.rodata/.data` section hash、热符号地址/尺寸与冻结 `8bce…` 一致；`.text/data/bss` 为 `4,505,901 / 201,864 / 263,040`B |
| v2.9 changed-area | `test-core` 228/228；`test-exec` 222/222 |
| v2.9 PMU | 冻结 baseline vs r6 final，21 形态 × 9 轮；纯税 413.186→395.177 insn、73.149→69.664 cyc；无回退越线 |
| v2.9 final image | SHA `851faa8030…`；`.text/data/bss` 为 `4,505,949 / 201,864 / 262,992`B；ArgsSource 16B、Stack 40B |

## 0. 结论先行

**执行结论（v2.10）**：原投影的 instruction 终态已兑现为 **261.007 insn/call**，是 qjs 238.089 的 **1.096x**；
`≤265` 终局线通过。cycles 为 **54.679 cyc/call**、qjs 的 **1.351x**，留给单独的 cycle-focused 续案。

**立项判断（历史）**：保持 tail-call threaded 骨架（CPython 3.14 同构背书）。Wave 1 塌缩调用进/出转换的边界税（低风险，预算 −40~70）；Wave 2 上结构刀——Stack 对象消除 + Entry 薄化 + arrow 捕获对齐 + realm 切换镜像（追平的主体，预算 −60~100）；Wave 3 以新分解数据扫残差。**投影终态 240~280 insn/call ≈ qjs 的 1.00–1.18x。**

**不做**（证据封死，v1 不变）：全单体（07-14 PMU no-go）；逐 handler 全局微剥离（branch miss +24%/L1I +12% 历史否决——本方案直跳只改 2 个转换位点，不动 handler 链尾）；continuation 直送完成器（已撤回）；IC/特化/JIT（换赛道）；退回 C 递归（CPython 3.11 亲证同环切换更优）。

## 1. 证据基线（2026-07-16 实测，方法与数据见 v1 归档段，此处保留结论）

四引擎纯调用税（调用基准−内联控制组，CPU19，best-of-5 PMU）：**Lua 147 / qjs 238 / CPython3.12 242 / zjs 452 insn/call**（cyc 33.8/40.5/40.2/78.2，两侧 IPC 均 ~5.9）。qjs 与 CPython 机制迥异收敛同一数：**调用转换发生在状态寄存器驻留的同一代码域是收敛点本质**。fib 交叉验证 gap 222 一致。

zjs 452 逐符号分解：op_call ~105（含 pushAndEnter 内联的 12 字段装载）、setupSimpleInlineEntry ~68（**与 qjs prologue 已同构，非税源**）、pushFrame ~35（独立 noinline 边界）、op_return+popAndResume ~76、`next` 转换增量 ~61（归因含弥散）、结果路径弥散 ~107。

三税归类：①状态发布/重建与转换边界（进出各一次装载+`next` 往返）②账本宽度（Entry 256B、teardown 三动态谓词、continuation 搬运）③资格判定（resolveInlineTarget ~30 vs qjs ~8）。

已同构不再动：args 原地借用/slab carve=alloca/locals memset/var_refs 借用/Entry 链=sf 链/acquireSlot 快臂/深度守卫单比较。

**repr 测量口径（已解决）**：16B 已翻默认（`54a75913`），全部验收自动三方同 repr。16B 重测基线：zjs 税 461 insn/80.4 cyc（vs 8B 旧口径 452/78.2——insn 微升 +9、cyc +2.2，与 16B Entry 寻址/q 寄存器搬运的已知回退一致），qjs 238/40.4 复测与冻结值一致。§1.2 逐符号分解为 8B 数据，定性结构不变，16B 定量分解随 P-1 一并重做。

## 2. 现状路径地图（锚点，v1 详版归档）

进：`op_call:794`/`op_call_method:833`（**共享**）→ `resolveInlineTarget`（inline_calls.zig:93）→ `pushAndEnter:403` → `pushFrame:531`（守卫+`acquireSlot:464`+selector+`setupSimpleInlineEntry:756`）→ 12 字段装载:417-429 → `next:219`。
出：`op_return:727` → `popAndResume:701` → `popFrame:1425`（`takeContinuation` + `canUseSimpleTeardown:256` + `deinitSimple:271`）→ `reloadAfterPop:2431` → 结果 push → `next`。
同形副本：`pushMovedAndEnter:437`、`pushBorrowedIteratorAndEnter:475`。线性 op 走 `cont:1240` 免检直跳（「fast op 永非函数末指令」既有先例）。

## 3. Wave 0：P-1 预验证（先于一切，当天可完成）

零承诺、几行改动的前提证伪实验，每个都按 4 指标 A/B：

| 实验 | 改动 | 证伪对象 |
|---|---|---|
| V1 | `pushFrame` 标 inline（或 `inline fn` 包装），单变量 | P4 预算 30–50 是否真实存在于函数边界+selector 重推导 |
| V2 | `popAndResume:717` 与 `pushAndEnter:430` 两处 `next`→`cont` | P3/P4 直跳收益 7–9×2 与 branch/L1I 风险 |
| V3 | Debug 构建加 `call 家族非末 op` assert 跑全量单测+test262 切片 | §6.1 不变量的经验性成立 |

V1/V2 若为噪声带 → 对应 patch 从序列中剔除，预算表更新。**这三个实验的结果决定 Wave 1 的最终形态，先跑再动手。**

## 4. Wave 1：边界塌缩（v1 的 P1–P4+P6，P5 移除）

单分支 `perf/call-supernode`，组合门禁后一次 ff。依赖：P3/P4 依赖 P1；P2 独立。

| # | 内容 | 锚点 | 预算 insn/call | 检查点 |
|---|---|---|---|---|
| P0 | 永久回归先行（§7） | tests | — | 预期绿 |
| P1 | 提取 `enterEntry(vm, entry)` 公共装载块，pushAndEnter/pushMoved/pushBorrowed 三处共享；驱动 reloadTop 若同形一并归一 | tailcall_dispatch.zig:403/437/475 | 0（行为零变化） | 三探针 A/B 中性 ±1% |
| P2 | `fast_teardown` 静态化：三动态谓词折单 flag；Debug 保留 `assert(flag == canUseSimpleTeardown())` 全等 | inline_calls.zig:214-259/271 + 逃逸点（§4.1） | −4~8 | call 探针降，负对照中性 |
| P3 | 出簇直跳（V2 通过为前提） | :717 | −7~9 | branch-miss/L1I 无恶化 |
| P4 | `enterSimplePlainCall` 融合（V1 通过为前提）：守卫+acquireSlot+Entry 头 init+setup 本体+链接单边界；**selector（simple/strict 两态判定）留在 pushFrame 通用臂之前的 handler 侧或融合函数入口，实施时按 V1 反汇编定夺**；显式 align(64)（op_call_method 先例）；进簇直跳 | inline_calls.zig:531-572 旁路 + :430 | −30~50 | 最大项；4 指标全绿才保留；OOM 语料回归 |
| P6 | fib/控制组脚本入库 + §5.4 P0 刷新 + 本文状态更新 | docs/tests | — | — |

### 4.1 P2 逃逸点全集（v2 修正——不是「三通道」，是三谓词 × 全部写点）

| 谓词 | 写点 | 处置 |
|---|---|---|
| `stack.arena_window=false` | stack.zig:40、:132（操作数栈堆化） | 翻 `fast_teardown=false` |
| 同上（generator/async 持久化） | vm_gen_async.zig:68/227/268 | **out-of-scope 论证**：generator/async 帧被 `resolveInlineTarget:99`（func_kind != .normal 拒绝）挡在 inline Entry 之外，这些写点只作用于 L0 状态；在方案回归中加一条 resident-generator 断言钉死该前提 |
| `frame.cold` 挂接 | frame.zig:299（installCold 类入口，实施时以 `self.cold = c` 写点反查全部调用方枚举） | 翻 flag |
| `frame.ownership.storage` 升级 | frame.zig:859、:887（+ :564 语义实施时核对） | 翻 flag |
| `simple_teardown` setup 写点 | inline_calls.zig:760（simple=true）、:943（fallback=false）、:1124（borrowed=true） | 三处均显式写 ✓ 无陈旧位；folding 覆盖三处 |

Debug 全等断言是逃逸点枚举漂移的永久安全网：任何新增写点漏翻 flag，Debug 套件即红。

### 4.2 v1-P5（native_caller 迁出）为何移除

复审实测前提：写点仅 pushFrame:535（init undefined）与 pushForwardedCall（inline_calls.zig:1375，Function.call 透明转发独占）✓。但 ①undefined 上的 `free` 仅为 tag 检查，P5 真值 ~4–6 insn 非 8–12；②转发帧当前享受 simple teardown（deinitSimple:279 无条件 free），若以 `fast_teardown=false` 承载会把 Function.call（刚从 6.43x 收到 1.66x）打回 deinitGeneral 全价路径。**性价比不成立，风险不对称 → 并入 Wave 2 的 Entry 薄化统一重排（Stack 消除后 teardown 形态重写，届时自然处理）。**

## 5. Wave 2：结构刀（追平的主体）

Wave 1 合入并复测分解后启动。每刀独立 worktree + 独立门禁，方向按收益排序：

### W2-A Stack 对象消除 + Entry 薄化（主刀，预估 −40~70）
CALL-MACHINERY-QJS.md item-1 的完整执行。现状：操作数窗口已与 locals 同 slab 连续（setup :846-850），但每 Entry 仍带独立 `Stack` 结构，边界处反复做 values-slice 物化（op_call:806-807 / publish:153 / syncSp:161 / 结果 push / reload sp 派生）。终态=qjs `local_buf` 形态：**操作数窗口就是 slab 子区 + 裸 sp，帧头只存窗口基址**；Entry 收向 qjs sf 字段集（func/prev/pc/base + catch + action，目标 ≤128B）；teardown free 环直接 `locals.ptr..sp`（deinitSimple:282 已是此形态，删的是中间层）。native_caller 语义在此重排中处理（转发帧专用 action 位）。**这是账本宽度与边界物化的总答案，也是 16B repr 已知 Entry 寻址回退的正确修复点。**

### W2-B arrow this/new_target 改闭包捕获（qjs js_closure2 17297 忠实对齐，预估 resolve −8~12 且 arrow 调用大幅）
qjs 无 arrow 分支：arrow 的 this/new.target 在闭包**创建期**绑成普通 capture var。zjs 放在 function object 上（resolveInlineTarget:119-123 每 call 分支+lookup）。对齐后 resolve 的 arrow 臂整个消失。编译器+闭包层改动，独立可验（arrow 专项探针 + test262 arrow/this 切片）。

### W2-C realm 门改 realm 切换（qjs `ctx = b->realm` 镜像）
zjs 当前 cross-realm 拒绝进快路（resolveInlineTarget:104-108）；qjs 是直接切 ctx 不拒绝。镜像后少一比较分支、跨 realm 调用回快路。需审计 handler 对 vm.ctx/global 的假设面——实施成本主要在审计不在改动。

### W2-D cachedBytecodeView 非空不变量前移（预估 −3~5）
view 在闭包创建期或首调用时一次性建成非空不变量，resolve 删 `orelse return null` 臂（:127）。

### W2-E Machine 计数扁平化（预估 −5~8）
`ctx.call_depth` 与 `machine.depth` 双计数 + acquireSlot 除法/entryAt 重推导 → bump-pointer Entry + 单比较守卫（qjs `js_check_stack_overflow` 形态）。W2-A 完成后做（Entry 尺寸变了）。

**Wave 2 合计预估 −60~100 → 投影 240~280 insn/call。**

## 6. Wave 3：残差扫尾（以 Wave 1+2 后的新分解立项）

- 重跑逐符号分解与 107 弥散专项（call 结果路径的 refcount/搬运——qjs 同样有此段，需先测同 repr 真差）；
- Vm/Entry 单变量实验：`arg_buf` 派生化、return false 发布消除与 native-caller ownership 已保留；`function` 派生化和 continuation 发布消除已拒绝；完整 dispatch-table 交换与 jump 专用轻 `next` 未混入本轮；
- **W3-CC 携带寄存器扩容（追平预案 1）**：查证 Zig/LLVM 在 AArch64 上是否暴露 `preserve_none` 类调用约定（CPython 3.14 tail-call 解释器以此实现状态全寄存器穿行、实测不输其单体）；可行则把 Entry/frame 基址等再放 1–2 个携带寄存器，直接压低转换重建下限。先做 CC 可用性 spike（独立小实验，不依赖 W1/W2）；
- **W3-CLUSTER 有边界的调用簇单体（追平预案 2）**：若复分解显示残差 >30 insn 且集中于转换分派/携带上限，评估把「call 进入 → callee 直线体 → return」融为单个跨 op supernode handler——**不是全单体**（07-14 no-go 针对 91 臂全单体；其复盘点名「per-op 簇是真前沿」即此方向）。以 fib/call-const 的 callee 形态（≤N op 直线体）做门控，先取 LLVM 布局证据再动；
- 若仍有 >30 insn 结构残差且上述两预案均不可行：以复分解证据更新本文，将「追平」目标正式修订为带宽目标并给出结构证明。

## 7. 永久回归（P0 先行 + Wave 2 各刀自带）

1. verifier：call/call0-3/call_method/tail_call 家族永非函数末 op（V3 先经验验证）。
2. fast_teardown 逃逸全通道行为测试：栈堆化后 return、arguments 物化后 return、open var_refs 关闭后 return、cold 挂接（catch/with/direct-eval）后 return——ReleaseSafe 无泄漏 + force-GC 绿 + Debug 全等断言。
3. resident-generator 不入 inline Entry 断言（§4.1 out-of-scope 前提钉死）。
4. Function.call 透明转发栈快照序 `target→call(native)→caller`。
5. 紧调用环中断可打断（poll 位置=qjs 17787 对位）。
6. **OOM 故障注入**（v2 新增）：`zjs_oom_coverage` 语料覆盖融合后 enterSimplePlainCall 的每个可失败点——errdefer 链（call_depth 回退、region 长度恢复 :809-812、slab 归还）逐点等价。
7. 既有全套：nested continuation/trap throw/PTC/moved padded/strict snapshot/for-of abrupt IteratorClose。

## 8. 门禁与验收协议（v2 修正）

**功能**：full test262 0 unexpected、known 账本逐位一致；单测全绿；ReleaseSafe unified；16B altrepr 腿；force-GC；OOM 语料（§7.6）。gate 前 sequential 重建 zjs 与 run-test262（stale 二进制纪律）。

**性能**：冻结三方 SHA；CPU19 ReleaseFast；9 轮三方轮换 best-of-N min；**4 指标**（insn/cyc/branch-miss/L1I）。
- 探针（v2 补全）：call-const/empty/strict/closure/missing-one/method-zero、**function-call-zero-arg-5m**、**call-strict-method-arguments-exact/missing**（setup 选择器面）、fib、for-of-next；
- 负对照：call-control-inline、property-read-mono、objalloc、L1a_accum——|Δcyc| ≤ 1%；
- **接受线（分层，修正 v1 算术矛盾）**：Wave 1 保守线=call 探针组合 insn ≥ −5% 且 cyc ≥ −2.5% 且负对照中性且 branch/L1I 无恶化；冲刺线 −8%/−4%。**终局验收线（三波后）=纯调用税 ≤ 265 insn/call（qjs 的 1.11x）**，以控制组相减法复测；
- 单步止损：任一探针或负对照 cyc 回退 >1%，两轮修复不果即摘除该 commit；
- 构建噪声纪律：±2.8% 布局陷阱，同源交错 A/B，insn 差 <300M 先疑布局。

## 9. 预算与投影（v2）

| 波 | 项 | 保守 | 乐观 |
|---|---|---|---|
| W1 | P2+P3+P4（P-1 预验证通过为前提） | 40 | 70 |
| W1 | LLVM 融合域弥散 | 0 | +30 |
| W2 | A Stack 消除+Entry 薄化 | 40 | 70 |
| W2 | B/C/D/E（arrow/realm/view/计数） | 15 | 25 |
| W3 | 镜像实验+残差 | 0 | 30 |
| **合计** | | **95** | **225** |

投影：452 − (95~225) = **227~357**；中位情形 ~280（qjs 的 1.18x），乐观触及 238 平线。fib 投影 1.57x → 1.25~1.40（W1+W2 后）。**风险声明**：W2-A 是全方案最大不确定项（触面广），其保守/乐观差即整体差的主源；预算以 Wave 1 后复分解修正。

## 10. 中止与回退

- P-1 预验证否决某 patch → 剔除并更新预算，不影响其余；
- Wave 1 内每 commit 独立可摘（P3/P4 依赖 P1）；P4 两轮修复不果 → 接受 P1/P2/P3 部分落地（~15–20），P4 降级独立后续；
- Wave 2 每刀独立 worktree，互不阻塞；W2-A 失败不影响 B/C/D/E；
- 全量 gate 任何 unexpected：阻塞，无例外。

## 状态

- [x] P-1 预验证（V1/V2/V3）：V1/V2 拒绝，V3 前提证伪
- [x] Wave 1：P0、P1、P6 保留；P2/P3/P4 按 PMU 止损拒绝
- [x] Wave 1 后复分解并以实测修正 Wave 2 预算
- [x] Wave 2：B/D 保留，A 部分保留，C/E 拒绝；每刀均完成独立语义/PMU 判定
- [x] Wave 3：残差 profile、CC/carry spike、entry 首跳与逐 call-opcode specialization 完成；arity specialization 保留
- [x] v2.10 续跑：static empty-frame shape、deep constructor、warm active carve、typed release 与 one-shot publication 保留；r20～r34 失败变体均回退
- [x] 终局验收：纯调用税 **261.007 insn/call**，达到 ≤265；cycles **54.679** 的剩余差距未包装成全面追平

## 附：v2 复审修订记录（2026-07-16）

1. P5 移除：预算高估（真值 4–6 非 8–12，undefined free 仅 tag 检查）+ Function.call teardown 回退风险；并入 W2-A。
2. P2 逃逸点修正：3 谓词 ×7 写点（含 vm_gen_async 三处的 out-of-scope 论证义务），非「三通道」。
3. 新增 P-1 预验证（pushFrame inline / next→cont / 末 op assert），先证伪再动手。
4. 新增 OOM 故障注入回归（P4 动 errdefer 链）。
5. 探针补 function-call-zero-arg 与 method-arguments 系；验收线分层修正算术矛盾（v1 保守预算 −7~9% 与 −8% 线自相矛盾）。
6. 目标从「收窄」升级为「追平」：新增 Wave 2 结构刀（Stack 消除/arrow 捕获/realm 切换/view 不变量/计数扁平化）与终局验收线 ≤265。
7. 确认 op_call_method 共享 pushAndEnter（:850），W1 收益覆盖 method 调用。
