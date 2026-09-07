---
name: zjs-ablation
description: Run evidence-backed binary-size and source-code ablation experiments in zjs, and improve the build/test/measurement iteration loop. Use for continuing ablation batches, pricing deletion or codegen candidates, and reviewing iteration efficiency; not for unrelated semantic fixes or reporting historical benchmark scores alone.
---

# ZJS 消融与迭代

在 zjs 仓库根目录执行。交付可复查的候选、冻结产物、验收结论和本轮 loop 的实际瓶颈；不把“扫到零引用”或体积 `CONTINUE` 当完成。

## 当前合同先于历史经验

先读根 `AGENTS.md`、[验证政策](../../../docs/verification-policy.md)；构建与测试入口查 `GUIDE.md` B.6，体积工具查 [size-screen](../../../docs/perf/size-screen.md)。涉及活跃路径性能时再读 [测量合同](../../../docs/perf/measurement-contracts.md)，涉及公开声明时查 [公共 API 合同](../../../docs/public-api-contract.md)。这些文件拥有规则；skill 不另设门禁、CPU 编号、配置版本或性能通过线。

保留用户在途变更。基线可来自 dirty tree，但必须记录精确内容身份，不能仅写 HEAD。消融任务不隐含 commit、push 或 API 收缩授权。

## 最短可信 loop

1. **先定价。** 明确机制、主指标、最小收益和不可改变的行为。二进制目标用 post-link stripped 文件字节；源码目标用显式分类的物理行数。另一个指标不抵消主指标失败。按当前政策分类：工具、死源码、生产路径/代码生成、GC/分配/根/屏障。
2. **冻结一次基线。** 使用已有同配置快照前验证 manifest、二进制哈希、工具链/目标/来源及其与本轮父状态的关系。需要新基线时用工具 owned build；不要把任意 `zig-out` 文件包装成当前树产物。冻结期间停止共享树编辑，候选可在独立工作树准备。
3. **一次改一个机制。** 先证明浪费或失败，再编辑、`check` 和定向 Debug 测试。默认内循环用 Debug；JS 脚本用 `zjs-dev`，持续 CLI 验证用 `mise run quick-watch`。机制候选稳定后再构建 ReleaseFast 快照，比较父快照和批基线，不为每次编辑重建优化产物。未达预注册收益：STOP，保留候选补丁和负值报告，只撤销本刀。达标：CONTINUE，再做相应行为验证。Debug 的体积、性能和优化相关行为不能替代 ReleaseFast 裁决。

   源码目标先用 `mise run source-screen -- <baseline> --min-lines N`，无需编译即可淘汰小收益候选。CONTINUE 后仍要冻结；核对预筛 `candidate_source_sha256` 与冻结 `source.content_sha256`，有新编辑就重跑预筛。这不提供字节或语义结论。
4. **按实际影响验证。** 复用运行时过滤的 `mise run test-fast -- '<非空测试子串>'`，不要每个测试名重新实例化编译产物。按政策收尾一次全量 test，批边界一次 batch-gate；失败才定向展开。纯死码不自动跑 GC 六负载。影响活跃路径必须完成对应配对性能验证，体积不能抵消回归。
5. **留下可接续结果。** 实验证据放 `.scratch/<batch>/`：预注册、父/候选身份、命令与退出码、字节/源码分类差分、相关输出、验证结果、接受/STOP 原因。报告已通过的层级与尚未验证的层级；不用历史 v8 分数声称当前候选无回归。

常用入口（目录与阈值按本轮预注册替换）：

```sh
mise run size-freeze -- --out .scratch/<batch>/baseline
mise run size-freeze -- --out .scratch/<batch>/candidate
mise run size-screen -- .scratch/<batch>/baseline .scratch/<batch>/candidate --objective binary --min-bytes <minimum>
# 源码刀用 --objective source --min-lines <minimum> --source-category engine
```

compare 退出 0/3/2 分别是 CONTINUE/STOP/证据或参数无效；3 是正常实验结论，不是工具故障。ReleaseSmall 必须显式作为跨配置实验比较，不能改写生产默认或冒充同配置机制收益。

## 如何选刀、证明消融

- 先查产物实际内容：stripped 总量 → 全部 section（含 opcode handler 岛）→ 符号地址区间并集 → 源码/实例化调用点。`NOBITS` 不计磁盘；同址符号不能重复相加。符号大小用于定位，最终收益来自重链接后的整体差分。
- 数据表消融定价前读 `readelf -lW` 的 LOAD 边界和对齐，结合 compare 的 `headers_padding_other_bytes_delta` 对账。只读数据缩小可能完全变成段间填充，文件不变甚至变大；不能用 section 收益替代文件门槛。保留这类负值候选供后续明确预注册的组合实验，不为过线临时降低对齐或修改主指标。
- 大块匿名常量先检查完整字节分布，再由实际加载地址、反汇编调用点和 `addr2line -i` 回到源码；AArch64 的 `adrp` 注释只是页地址附近的符号，必须合并后续偏移，不能直接当引用。大量零字节可能属于 optional/union 表或带非零默认字段的初始化模板，不代表可删除。组合数据刀先算跨段边界的乐观收益上限：即使整块移除仍不够且没有独立代码收益依据时，暂缓优化构建；这是定价判断，不能冒充实测 STOP。保留替代表占用和布局变化的不确定性。
- 稀疏元数据可保留原 comptime 权威，以小索引映射到唯一行或原声明列表。测试分别覆盖所有索引槽的有效/缺失状态与全部合法枚举值；表容量可能大于枚举定义域，不能把每个槽号都 `@enumFromInt`。因填充失败的候选可在事先声明的组合中复用，验收的是整个组合，不能把组合收益分摊成各刀的独立收益。
- 带少数非零默认值的大初始化模板可定价清零加显式默认赋值，必须逐字段等于原类型默认值，并检查生成代码确实消除了模板。关闭 opcode profiling 不代表整个 profile 对象无用：先审查 perf-json 的激活、采集和 flush 调用；保留计数与公共类型合同。
- 功能已在生产构建禁用时，审查**调用点的编译期可达性**。运行时拒绝参数不一定阻止独立序列化函数被链接。裁剪后同时验证生产拒绝行为、普通诊断 schema 和专用 profiling 产物的非零计数；不要删除仍有合同的 GC 诊断或对外 flag。
- 冷输出中，枚举/定长数组的 `inline for` 若不依赖编译期类型选择，可以定价普通循环以共享格式化代码。LLVM 仍可能自行展开，必须看重链接结果，不能按循环次数推算收益。带 GC 名称的纯序列化改动与采集/回收机制分开判级。
- 不把 `cold`/`noinline` 提示当收益保证：提示可能增大产物，仍按主指标 STOP。重复的固定类型诊断可先尝试标签/数值数据加一个共享 writer，保持调用点字段映射与后缀可读；不为少数行另造格式语言。验证完整数值范围、逐字输出和中途写失败，再决定是否扩大应用范围。
- CLI 已有 `src/cli/zjs.zig::writeCounterLine`，只用于无符号整数十进制诊断行；优先复用它。带符号、浮点和特殊格式不能未经合同核对直接迁入。
- 固定宽度表格可尝试显式类型的行数组（字符串域用 `[]const u8`）加普通循环，保留原 `print` 格式。相同格式串的不同参数类型仍可能重复实例化；先测产物，不强加 `noinline`。fixture 同时覆盖短数字和超出列宽的数字，确保最小宽度没有变成截断或固定宽度。
- JSON 数值字段也可共享整数 writer，但标签和后缀是原始文本，迁移 `print` 时要还原 `{{`/`}}` 转义。以不同固定值逐字验证字段映射，并用真实 CLI 解析核对键顺序、类型、null/布尔元数据；保留动态字符串的 JSON 转义入口。共享生产/profiling 输出时在批边界覆盖两种产物。
- 对诊断序列化先在原实现上运行**固定、非零、各行不同值**的完整输出 fixture，再验证候选；同时覆盖未采集提示和 writer 失败。真实堆运行补充路由覆盖，但 wall-clock 相位敏感的计数不适合做逐字 golden。保持下游解析器行名、顺序、单位和索引对应。
- 动态 census 的空表 fixture 不能覆盖实际行；用真实非空堆验证字段数量、占用率公式、分桶与总计相等，并断言确实输出了数据行。固定 fixture 守字段映射，动态不变量守真实采集到输出的路径。
- `tools/maintainability/dead_decls.py` 只提供候选，必须传入真实文件列表（它不是支持 `--help` 的 argparse 工具）。例如用 `rg --files src` 筛 `.zig` 并排除测试/Unicode 生成表后传参。文件内 private 与全树 pub 引用分开核查；进一步查 `@field`、生成器、公共根的重导出。删除后重扫到固定点，再编译验证。内部模块的 `pub` 不等于公共 API；反过来，repo 零调用也不能证明公开 API 可删。
- 默认扫描把注释也算引用。怀疑已迁移的旧实现仍被保留时，可补做文件内私有声明的代码引用筛选，但必须复核字符串反射和真正入口；同名成员引用（如 `const x = module.x`）也会掩盖未使用别名。级联删除后复核这些别名，保留公开重导出。脚本编辑使用唯一锚点，并核对 diff 没有删掉公开声明或测试。
- 顶层声明扫描会漏掉 `State` 等容器中的私有方法。补查嵌套方法后，沿仅被旧发射器调用的辅助链迭代到固定点；历史注释中的 “twin” 或 oracle 名称不是运行入口。函数退出可达图不意味着能顺手删结构体字段和清理路径：布局/生命周期变化另行定价。批内汇总整条链再构建优化产物。
- 自写的代码引用筛选必须覆盖仓库工具和示例调用者，不能只扫描 `src/`；例如 context 的内部测量入口被 `tools/perf/same_runtime` 调用。先完成所选范围内函数、类型、别名和导入的级联审查，再冻结同一机制的稳定源码批，避免每发现几个孤立声明就支付一次 ReleaseFast 构建。
- 不删除测试、生成 Unicode/ABI 数据、GC safety net；不靠把生产代码移到别的分类降低统计值。物理行数包含注释/空行，应与实际删除声明数量一起报告。
- 源文件里的内联 `test` 也计入 `engine` 物理行数。新增回归测试可使二进制下降而该行数上升；如实拆解新增测试与生产修改，不重分类或删测试来制造双赢。

## 每轮顺手评估效率

从日志拆分锁等待、编译、执行、strip/归因、人工复核时间，优先修占主导的成本，区分 cache hit 与首次构建。

- 单个 ReleaseFast 编译仍占主导时，先采集 Zig `--time-report` 的阶段与 LLVM pass 数据。CPU 累计时间与 wall 时间分列，不相加；LLVM 子报告也可能嵌套。若通过 `--listen=-` 读取，保留原始协议，按当前编译器的消息发送实现解码；解析失败离线修复，避免重付一次编译。检查报告是否强制绕过缓存，不把带仪器冷构建与普通 cache hit 比速度。
- 编译期 `-fstrip` 与 post-link strip 不等价：即使配置签名相同，也可能改变 `.text` 和 opcode handler 岛。它只能先作为独立探索臂，记录全部编译参数；不能直接替代正式体积/性能产物。编译耗时收益与运行性能验收分开。
- 基线复用、候选只构建一次；将冻结二进制直接交给后续适用的测量入口。
- 撤回后不假设 Zig 缓存一定命中。先用 `mise run size-verify -- <原快照>` 核对完整源码清单、产物哈希、模式、Zig 版本和 native target；退出 0 才复用原快照，3 表示需重建，2 表示证据/环境无效。它不复制或重新封装产物，也不替代恢复后的测试。完整清单包含工具和文档，任何不匹配都不能手工忽略；外部/ignored 输入仍服从 size-screen 的正常构建输入前提。
- 从构建日志检查改动的 import 影响范围。CLI 专用诊断留在 CLI 层可保留其他引擎入口的编译缓存；不要为共享少量输出代码扩大公共引擎依赖。分别报告 cached 与实际执行/编译步骤，缓存门禁通过不等于所有测试重新执行。
- 测试文件变新不代表生产缓存失效。`gate_smoke.sh` 的默认路径保留 mtime 防误用检查；显式路径由调用者核对构建图依赖或冻结身份，仍执行产物探针和全部运行检查。遇到新鲜度误报先查依赖与身份，不触碰二进制时间戳或强制重编译来制造通过。
- 批边界需要 profiling smoke 时用 `mise run batch-gate-profile`，让它与批门共享构建图；其中已经包含最终全量 test，避免先 `test + smoke` 再串行批门。普通批仍用 `batch-gate`，不扩大 profiling 验证范围。
- 共享主机默认 finite watch，空闲释放编译锁；独占驻留 incremental 的取舍查现行任务文档，不把旧驻留耗时套给默认 watch。
- 探索可并行的是独立源码分析/候选准备；共享树 freeze 期间不能编辑，正式测量不能因“有两个锁”就默认无干扰。用户授权并行时按文件或工作树隔离，driver 统一冻结和批门。
- 快筛淘汰低价刀；大块诊断格式化/泛型实例化先做产物归因再决定共享代码实验。不要从“小段源码删除没有字节收益”推断工具失败。
- 只有实际重复或出错的环节才值得自动化。新增脚本必须验证真实成功和失败边界；优先复用已有工具，避免再造验证框架。

把本轮新发现记录在 owning 实验报告；仅将跨批可复用、改变决策的经验加入此 skill，避免累积易过期分数和状态台账。
