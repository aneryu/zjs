# AUDIT-EXEC 计划 — 基于已核查差异台账的修复批次（交 grok 执行）

日期：2026-08-14。制定者：driver。执行者：**grok**（`~/.local/bin/grok`，headless 单轮模式已冒烟验证）。
状态：**已合入 main 并完成 §6 验收**。
merge `65a60344`（G1→G4→G3→G2）+ follow-up `192a097d`（tagged-template 补 `Array.prototype`，X-10 删除兜底后的依赖方）。
canonical `zig build test262-gate`：0/49775 errors，passed 44581（与基线持平）。
zoo A/B（pads 0/3/7 × 8 samples，CPU 19，ABBA）：after/before geomean 1.0018 / 0.9998 / 1.0019，中位 **+0.18%**（相对 0.9278 基线约 **+0.17 pp**）< MDE 0.278 pp → **性能中性，正确性通道落地**。

## 0. 输入与目标

输入 = `worktree-impl-audit`（分支 `audit/impl-divergence-20260813`，commit `113b6614`）的
`docs/qjs-align/IMPL-DIVERGENCE-2026-08-13/VERIFIED-LEDGER.md`：
**一审 CONFIRMED-EXEC 且二审 UPHELD ≈278 条**是唯一可直接开工面（台账 §3）。

本批从中选 **17 条**（Tier S 全部 9 条 + Tier A 高价值 8 条），按**文件足迹**切成 4 条互不冲突的 lane。
基线 = main `10221e76`（codex 的 stack3+typed-int `42b6160f` 已在其中）。

**准入通道**：本批走 MECHANISM-REGISTRY 末段的**唯一例外通道**——
「QuickJS alignment / correctness 修复，按忠实性规则评审，不伪装成性能候选」。
因此不受 PARITY-LEDGER 的 0.3pp 登记线约束；但其中三条（X-10 / X-03 / X-38）落在热路径上，
**性能是副产品也是风险**，由 driver 在合并后串行做一次打包 zoo A/B 定价（§6）。

**与 codex 线的边界**：codex 在 main 上做 dispatch/stack 性能主线。本批四条 lane 的文件足迹
（regexp / object 冷路径 / parser / string·value builtins）与其不重叠；**不碰**
`tailcall_dispatch*.zig`、`stack.zig`、dispatch 热表。台账 4.3 的 `tail_call` 发射缺失
与 codex 线强耦合，**不进本批**（见 §8 backlog）。

## 1. 全 lane 公共契约（每份任务书原样携带）

1. **worktree 隔离**：只在指定 worktree 内工作。**禁止任何 git 写操作**
   （commit/checkout/branch/reset/stash/rebase/add/merge）——改动留在工作区，由 driver 验收提交。
2. **禁碰**：`test262.conf`、`test262_errors.txt`、`reports/**`、`docs/**`、
   `tools/perf/**`。test262 门禁裁决不归 agent——canonical `zig build test262-gate` 由 driver 在 main 亲跑
   （worktree 的 test262 submodule 是空的，跑了也会响亮失败，不要试）。
3. **每条的固定流程**：
   a. 先 `zig build zjs` 出基线二进制；
   b. 用 `ZJS=<本worktree>/zig-out/bin/zjs bash /home/aneryu/worktree-impl-audit/difftest.sh <用例>`
      复现，**逐字贴上前后输出**；复现必须用台账原文用例（台账写法是权威；
      若失败，先换 ≥3 种写法——含台账«二审»列出的变体——再判 NOT-REPRODUCED 跳过，不得硬改）；
   c. 读 qjs 参照（`/home/aneryu/quickjs/quickjs.c` 等，台账已给行号），**镜像其机制**修复，
      代码注释与总结中标注 `qjs:<行号>`；
   d. difftest 复跑至 `VERDICT: IDENTICAL`；
   e. 在仓库测试惯例位置添加最小回归测试（先 `ls tests/`/grep 找惯例，不确定就学最近的同类测试）；
   f. `zig build test` 全绿；`zig build -Doptimize=ReleaseSafe` 构建并用 ReleaseSafe 二进制复跑本条 difftest；
   g. `bash tools/perf/lint_anti_goals.sh` 退出 0；
   h. 打一行 `[PROGRESS] X-NN <状态>` 再进入下一条。
4. **修复红线**：只允许「对齐 QuickJS 的语义机制」或「删除 zjs 独有机制」；
   **禁止发明 QuickJS 没有的新语义机制、快捷语义路径或工作量绕过**
   （允许不改变逻辑执行模型的代码生成、状态承载和布局优化）。
5. **性能测量禁令**：agent **不得**跑任何 PMU / zoo 测量（「诊断并行、测量串行」——测量归 driver）。
6. **⛔ 禁做清单**（zjs 是规范正确方，或需用户裁决，绝不向 qjs 对齐）：
   - `bind()` 的 `[[Prototype]]`（台账 §3.5 / X-32 只修 name/length **顺序**，[[Prototype]] 半条已摘除）；
   - `08·#48/#50` 与 `13·K8`（node 佐证 zjs 正确）；
   - **X-23 / X-24（BigInt.asUintN F1/F3）——忠实与合规互斥，等用户裁决，本批不碰**。
7. **收尾**：输出总结表（每条：VERDICT 前→后 / 改动文件行数 / qjs 参照行号 / 测试位置 /
   NOT-REPRODUCED 或 BLOCKED 的说明），并确保 `git diff --stat` 与总结一致
   （防「工作区改动静默丢失」事故——driver 验收第一步就是核对这两者）。

## 2. Lane G1 — regexp（`src/libs/regexp.zig`；CPU 5）

| 条目 | 断言 | 修复面 | qjs 参照 |
|---|---|---|---|
| **X-01** 正则编译器无栈溢出检查 ⇒ SIGSEGV | `new RegExp("(?:".repeat(40000))` → zjs exit=139 零输出；v-mode 变体 `"[".repeat(1000)+"a"+"]".repeat(1000),"v"` 更浅即崩 | `re_parse_disjunction` 与 v-mode 嵌套类解析两条递归入口各加一次栈检查（现状 `grep -c 'stack_overflow\|checkStackOverflow' src/libs/regexp.zig` = 0，连深度计数器都没有）。**机制必须镜像 qjs 的 `lre_check_stack_overflow`**（真实栈指针检查），不是加人为深度上限 | `libregexp.c:1390`、`:2410` |
| **X-13** 非 u 模式拒绝字面量 astral 群名 | `new RegExp("(?<"+String.fromCharCode(0xD801,0xDC00)+">x)")` → zjs `invalid syntax` / qjs accepted | `readGroupNameCodePoint` 字面量分支（`regexp.zig:1995-1998`）补代理对重组（`\u` 转义分支 `1983-1994` 已会重组，照抄其逻辑） | `libregexp.c:1648-1656` |

X-01 验收补充：修后 `(?:`×40000 与 v-mode 变体都必须是**干净的 `SyntaxError: stack overflow`**（exit=0 被 catch）；
×1000 仍须两侧 accepted。阈值出线点（qjs 在 ×5000 已溢出）不要求逐格对齐——那由各自栈上限决定，
但方向必须一致：**深了报错，绝不 SIGSEGV**。
⚠️ regexp 是三大反超资产之一（zoo 1.114），栈检查加在**每层递归**上，位置照 qjs（入口处一次），不要加在字符循环里。

## 3. Lane G2 — object/property 冷路径（`src/core/object.zig`、`src/exec/object_ops.zig`；CPU 6）

按下列顺序做（X-10 最大、最独立，先做）：

| 条目 | 断言 | 修复面 | qjs 参照 |
|---|---|---|---|
| **X-10** `[[Get]]` miss 兜底 `globalThis.<Ctor>.prototype` | `globalThis.Function={prototype:{zzz:1}}` 后 `f.zzz===1` 而 `'zzz' in f===false`；不改原型链即可劫持 | **整臂删除**：`object_ops.zig:2944-2967` 的类名兜底（实测 18 条类名腿 + DataView 三键腿 `2926-2933` + String 索引腿 `2938-2942` = **20 条**，README 说 13 是少算）+ `4147-4157` 的 `getPrototypeMethod`。qjs 原型链走完即 `return JS_UNDEFINED`，**没有任何兜底** ⇒ 这是 zjs-only 机制删除，也是本批唯一的每-miss 纯税削减 | `quickjs.c:8210` 入口，终点 `8355-8363` |
| **X-07** `[[Set]]` 原型链不于首命中处 break（整数键冷路径） | 原型链远处有 readonly/无 setter 属性时，近处 writable 数据属性命中后仍继续走链并抛 TypeError | `object.zig:10921-10933` `setProperty` 冷路径：命中即 break。⚠️ 命名键快路径是对的，**只有整数/下标键冷路径错** | `quickjs.c:9839`（`retry2:`）…`:9853`（`break`） |
| **X-08** 全局 `var` 的 `writable:false` 静默失效 | `(0,eval)("var ev=1")` 后 `defineProperty({writable:false})` 不生效，desc 谎报 `writable:true` | `object.zig:11932-11945` VARREF 重定义臂补 `is_const` 同步写（创建路径 `commitAutoInitValue` `object.zig:9417` 已是对的，照抄） | `quickjs.c:10508-10520`（双写） |
| **X-09** VARREF⇄GETSET 转换后同一绑定两种读法两个值 | 转 getter 后裸 `ev` 读陈旧 cell = 7，`globalThis.ev` = 42 | `object.zig:11947-11956` 通用替换臂：VARREF→GETSET 方向补 cell 摘除 + var_ref 释放 | `quickjs.c:10410-10426`（`remove_global_object_property` + `free_var_ref`） |
| **X-02** Array exotic `length` 的 `[[Set]]` 不做 Receiver 重定向 | `Reflect.set(arr,"length",2,recv)` 改了 arr、没写 recv（静默数据损坏；任何包数组的 Proxy 的 `p.length=n` 全中） | Array exotic `[[Set]]` 的 length 臂：`O !== Receiver` 时走 `OrdinarySetWithOwnDescriptor`（qjs 观察序列 `set → gopd:length → def:length`），而非直接 `ArraySetLength`。先在 quickjs.c 里找到 receiver≠target 的处理路径并引用行号 | `JS_SetPropertyInternal` 的 receiver 分派（自行定位并标注） |
| 附带（X-08/X-09 同族回归面） | 台账 X-08/X-09 的**对照组**（`gp`、`ev2`、普通 var TypeError）修后必须仍 IDENTICAL | — | — |

X-10 风险提示：兜底臂删除后 zjs 自身内部代码若暗依赖它（20 条腿中 DataView/String 索引腿最可疑），
`zig build test` 会炸——**炸了就逐腿查是谁在依赖，把依赖方改为走正常原型链，不许保留兜底**。

## 4. Lane G3 — parser / 前端（`src/parser.zig`；CPU 7）

| 条目 | 断言 | 修复面 | qjs 参照 |
|---|---|---|---|
| **X-04** 顶层 direct eval ⇒ 全脚本私有名解析出错 | 脚本任意处一行 `eval("1")` 就让所有「经 direct eval 的私有名访问」失败；`eval("#f in this")` **静默返回 false** 最危险 | **先归因再修**：台账判「归属 05 parser 或 10 call/frame/closure」。从「顶层 direct eval 存在」如何改变私有名环境/作用域编译入手；6 形态矩阵（字段/getter/方法/brand/写/对照）全部要修到与 qjs 一致 | qjs 私有名经 `JS_EVAL_FLAG_*` 与作用域链解析，自行定位并标注 |
| **X-05** switch 落穿在 while 家族尾部丢失 | `case 0: while(true){…break;} case 1:` 的 case1 被跳过（`a,d` vs `a,b`） | `parser.zig:11820 v2CaseTailCanFallthrough`（终结集 `11834-11842`）。⚠️ **修复前必须先把真正的判据搞清楚**：`for(;;)` 同为回边 goto 却不触发（尾部有 leave_scope 遮住）——判据必须区分「回边 goto」与「跳出 goto」，不能只看最后一条 opcode。台账 12 形状表（3 触发 / 9 不触发）修后必须逐格过 | qjs 落穿由字节码顺序天然成立，无此判据 |
| **X-29** `for (var yield of …)` 被接受 | generator 内 zjs accepted / qjs SyntaxError；叠加面 `for (var yield = 1 in {a:1})` 同时绕过两个检查 | `parser.zig:14799-14803` 的 `sloppy_keyword_var` 副本（parseForInOf 侧）与 `parseVar`（`14500-14507`）的完整谓词对齐 | qjs 单一谓词天然一致 |
| **X-26**（伸展）`async yield => 1` 被拒绝 | sloppy 下 `async <上下文关键字> => 1` 应为 `function`；**例外：`async await => 1` zjs 拒绝是 spec 正确的，保持** | `parser.zig:7508-7512 checkAsyncArrowHeadAfterAsync` 的 `param_kind == TOK_IDENT` 判据——上下文关键字是独立 token 种类，永远≠TOK_IDENT | — |
| **X-27**（伸展）`({get})`/`({set})` 简写被拒绝 | `var get=1; ({get})` → SyntaxError | `parser.zig:10558-10563` 退回门只排除 `':'` 与 `'('`，需再放行 `,` 与 `}` | — |
| **X-28**（伸展）≥129 字符数字字面量被拒绝 | 128 个 '1' ok / 129 拒 | `parser.zig:1924-1929` `stripped: [128]u8` 定长缓冲。看 qjs 用什么机制（js_atof 无长度上限），对齐之 | — |

X-04 是本 lane 最重的一条，允许花最多时间；若归因指向 call/frame/closure 子系统且改动越出 parser 足迹，
先打 `[PROGRESS] X-04 BLOCKED <归因结论>` 并继续后面条目，把归因写进总结（driver 决定转派）。

## 5. Lane G4 — string / value / builtins（`src/exec/vm_arith.zig`、`src/core/value_format.zig`、`src/exec/{class_init_ops,construct,number_ops}.zig`；CPU 8）

| 条目 | 断言 | 修复面 | qjs 参照 |
|---|---|---|---|
| **X-03** accumulator rope 的 `max_ref_count=2` 别名假设 ⇒ 赋值丢失 + 字符串可变性破坏 | 用户 `toString` 重入改写同一局部后，`s = s + o` 结果被丢弃、stash 持有的字符串被就地改写（V8 佐证 qjs 正确）。⚠️ **必须用台账用例**（driver 自编的四种写法全不触发；触发变体见台账 X-03：`s+=o`/`valueOf`/`Symbol.toPrimitive`/闭包捕获/9000 字符长串） | `vm_arith.zig addLocalString`：对齐 qjs——`OP_add_loc` 字符串臂要求 `*pv` 与 `op2` **都已是 `JS_TAG_STRING`**，对象操作数直接落 `js_add_slow`，结构上不可能在用户 toString 之后才 in-place。若保留 rope 承载，必须在 `toPrimitiveForAdditionFree` **之后**重新校验 `frame.locals[idx]` 仍持同一 rope——**优先前者（结构对齐）** | `quickjs.c:19766-19767` |
| **X-38** ToNumber latin1 快路把裸字节当 UTF-8 空白 | `String.fromCharCode(0xE2,0x80,0x80)+"1"` → `Number(s)=1`（应 NaN）；同一次运行 `Number(s)===1` 而 `s*1===NaN` 引擎内自相矛盾；触发面 7 组序列 × 前后缀 14/14 | `value_format.zig` 的 latin1 快路：latin1 backing 的码点 0x80-0xFF 是单个码点，**不得**把原始字节序列交给 UTF-8 空白判定。对齐 qjs 的 `js_strtod`/skip_spaces 按码点判空白 | `quickjs.c` `js_atof` 一带（自行定位并标注） |
| **X-37** `class extends Number` 跳过整个 ToPrimitive | `new MyNum({valueOf(){return 42}}).valueOf()` → NaN（应 42）；异常被吞、副作用被消除；触发条件 = `new_target !== Number` 且实参是对象 | `class_init_ops.zig:141` 与 `construct.zig:189` 两个违约调用点改走完整 ToPrimitive（`toNumberValue` 共 46 个调用点，只有这两个违约；不要动 `toNumberValue` 本身的其余 44 个调用面） | qjs `js_number_constructor` 走 `JS_ToNumeric` |
| **X-12**（伸展，一行级）`(5).toString(Infinity)` 在 Debug/ReleaseSafe panic | `@intFromFloat` 在范围检查**之前**，任何超出 i32 域的 radix 都是 UB；ReleaseFast 靠运气正确 | `number_ops.zig:239-245`：范围检查移到 `@intFromFloat` 之前。用 Debug 构建验证 `Infinity`/`-Infinity`/`1e30`/`2**31` 全部从 exit=134 变 RangeError | `quickjs.c` `js_number_toString` 先 `JS_ToInt32Sat` |

X-03 验收补充：台账的 **3 组归因对照**（无 tail 侧车的 rope 不触发 / toString 返数字不触发 / `var r=s+o` 不触发）
修后仍须 IDENTICAL——它们是「没把不该改的路径改坏」的负对照。
⚠️ X-03/X-38 都在热路径（add_loc 字符串臂、ToNumber 主线）：**只做结构对齐，不加防御性分支**；
性能后果由 driver 的打包 zoo A/B 承接。

## 6. Driver 验收流程（测量串行，全归 driver）

1. 每 lane 完成后：`git diff --stat` 与 agent 总结逐条核对（防静默丢失）→ 逐条 difftest 抽验
   （至少每 lane 抽 2 条亲跑）→ 在 lane worktree 跑 `zig build test` + ReleaseSafe + anti-goal lint。
2. 合并顺序（按爆炸半径升序）：**G1 → G4 → G3 → G2**。每合并一个 lane 到 main：
   canonical `zig build test262-gate` 亲跑（基线 0/49775 errors, passed 44581——修真 bug 只可能多 pass，
   任何新 error 都是回归，回滚该 lane 单条排查）。
3. 全部合并后**一次打包 zoo A/B**：main(前) vs main(后)，同核交错 ABBA，3 pads（0/3/7），每侧 ≥8 samples。
   判读分三档：
   - **三大反超资产**（crypto 1.057 / code-load 1.094 / regexp 1.114）任一回退超噪声 → 定位到 lane 单条消融；
   - geomean 变化在 ±MDE（0.278pp）内 → 记「性能中性，正确性通道落地」，符合预期；
   - X-10（每-miss 税删除）若带来可测正效应 → 在 PARITY-LEDGER 机制账本登记实测值。
4. 收尾：PARITY-LEDGER 与 HANDOFF §9 补记本批结果；台账 `VERIFIED-LEDGER.md` 不改
   （它是审计产物，修复状态记在本文档追加的「落地表」里）。

## 7. 派发机制（就绪未执行）

```bash
# 1) worktree ×4（从 main HEAD）
cd /home/aneryu/zjs
for l in g1-regexp g2-object g3-parser g4-value; do
  git worktree add /home/aneryu/worktree-grok-$l -b grok/audit-fix-$l main
done

# 2) 任务书 = §1 公共契约 + 对应 lane 节（§2-§5）原样拼接，存 /tmp/grok-briefs/<lane>.md
#    每份头部加一行：工作目录、CPU 号、台账绝对路径
#    /home/aneryu/worktree-impl-audit/docs/qjs-align/IMPL-DIVERGENCE-2026-08-13/VERIFIED-LEDGER.md

# 3) 驱动器 tools/perf/grok_run.sh：codex_run.sh 同构（PID+DONE marker，不用 pgrep），启动行换成
grok --prompt-file "$d/prompt.md" --cwd "$wt" \
     --permission-mode bypassPermissions --max-turns 500 --output-format plain \
     > "$d/log" 2>&1

# 4) 并行启动 4 lane（G1=CPU5 G2=CPU6 G3=CPU7 G4=CPU8；build 不锁核，测量禁令见公共契约第 5 条）
# 5) 进度：bash tools/perf/grok_run.sh status；结论：… show <lane>
```

## 8. Backlog（本批不做，已排序待后续批次）

- **批次二（Tier A 余量）**：X-06（数字键 `1e21` 格式化，须换用运行期 Number::toString 同一实现）、
  X-11（`globalThis.Iterator` 注入迭代器原型链）、X-14（内部错误 prototype 取自可变全局）、
  X-25（`x = eval('var x=5; 7')` 凭空建全局）、X-30/X-31（转义关键字参数名 / `<class_fields_init>` 泄漏）、
  X-32（bind 的 name/length **顺序**，⛔[[Prototype]] 半条不做）、X-33–X-36（iterator/JSON 族）、
  X-15/X-16（module：star-export 歧义 / TLA 顺序）、X-17–X-22（array 族，含 sort 的 UTF-16 序）、
  X-39（`--stack-size` 量纲：zjs 内部两种量纲同读一个标量，对齐 qjs=字节）。
- **X-40 异常 message/类型漏斗**：跨子系统系统性缺陷，量大（09 二审一次跑出 7 处），单独立项。
- **性能通道（须按测量合同第 9 条先量频次）**：台账 4.4「qjs 完全没有 X」的 zjs-only 199 条中
  **44 条热频条目**逐条评估删除；4.3「定义但不发射」的 `tail_call`/`tail_call_method` 全套
  （DeltaBlue 7.06M 次缺失，与 codex 的 dispatch 线协调后排期）。
- **等用户裁决**：X-23/X-24（`BigInt.asUintN`——zjs 忠实对齐 qjs 则违规范、修对规范则偏离 qjs，二选一）。

## 9. 落地表（2026-08-14 grok 执行）

基线 = `6d8295ce`（计划写的 `10221e76` 已过期）。Claude Code 咨询了 X-02 / X-04 / X-05 三处归因（`/tmp/grok-1000/audit-exec/claude-x0{2,4,5}.md`）。
合入 main：`65a60344` + `192a097d`。test262-gate 与 zoo A/B 见本节末。

| 条目 | lane | 状态 | 备注 |
|---|---|---|---|
| X-01 | G1 | **FIXED** IDENTICAL | `SyntaxError: stack overflow`（不再 SIGSEGV）。qjs:`libregexp.c:1390/2410`、`quickjs.c:48000`。v-mode `[`×1000 zjs 现亦干净 SyntaxError（qjs 仍 accept；合同要求不崩）。`/home/aneryu/worktree-grok-g1-regexp` |
| X-13 | G1 | **FIXED** IDENTICAL | 字面量 astral 群名重组。qjs:`libregexp.c:1648-1656`。U+10400，非 emoji |
| X-10 | G2 | **FIXED** IDENTICAL | 删除 20 条 `[[Get]]` miss 类名兜底。qjs:`quickjs.c:8355-8363`。依赖方改为走真实 `Array.prototype`（rest / iterator pair / Object.keys / **tagged-template cooked+raw**，`192a097d`） |
| X-07 | G2 | **FIXED** IDENTICAL | 整数键冷路径命中即 break。qjs:`9839-9853`。命名键对照仍 IDENTICAL |
| X-08 | G2 | **FIXED** IDENTICAL | VARREF 重定义同步 `is_const`。qjs:`10508-10520`。gp/ev2 对照 IDENTICAL |
| X-09 | G2 | **FIXED** IDENTICAL | VARREF→GETSET 摘 cell。qjs:`10410-10426` |
| X-02 | G2 | **FIXED** IDENTICAL | `qjsReflectSetCall`：receiver≠target 走 OrdinarySet。qjs:`9701-9702` skip `set_array_length`。异 receiver 不做 ToUint32（`length=-1` 两侧 `recv.length=-1`） |
| X-04 | G3 | **FIXED** IDENTICAL | 归因订正：不是私有名解析，是 direct eval 的 `this` 编译。`emitThisValue` 对 `is_direct_eval` 发 `scope_get_var this`（qjs:`26934-26939` / `37239`）。6 形态矩阵 IDENTICAL |
| X-05 | G3 | **FIXED** IDENTICAL | 已收档为 `isLiveCode` 入边检查（qjs `js_is_live_code`）。并删掉 `v2SwitchBreakRefCount` 守卫：`if(false) break; print("y"); case 1: print("z")` 现为 `y\\nz` |
| X-26 | G3 | **FIXED** IDENTICAL | `async yield => 1` 接受。`async await => 1` **保持拒绝**（spec 正确，对 qjs DIFFER 是合同要求） |
| X-27 | G3 | **FIXED** IDENTICAL | `({get})`/`({set})` 简写。qjs:`24643-24646` |
| X-28 | G3 | **FIXED** IDENTICAL | 去掉 128 字节数字缓冲上限。qjs:`js_atof` 12876+ |
| X-29 | G3 | **FIXED** 接受集合 IDENTICAL | `for (var yield of/in)` 现拒绝。消息仍 `UnexpectedToken` vs qjs `variable name expected`（与 `var yield` 对照同族，归 X-40） |
| X-03 | G4 | **FIXED** IDENTICAL | `add_loc` 仅当 RHS 已是 string 才 in-place。qjs:`19766-19767`。3 组负对照仍 IDENTICAL |
| X-38 | G4 | **FIXED** IDENTICAL | latin1 ToNumber 按码点判空白。qjs:`skip_spaces` 11230。7 组序列 × 前后缀 |
| X-37 | G4 | **FIXED** IDENTICAL | 仅改 `class_init_ops.zig` / `construct.zig` 两处走 `toPrimitiveForNumber`。qjs:`44822 JS_ToNumeric` |
| X-12 | G4 | **FIXED** IDENTICAL | radix 先饱和再范围检查。Debug 不再 panic。qjs:`JS_ToInt32Sat` |

### worktree / 总结文件

| lane | worktree | branch | 总结 |
|---|---|---|---|
| G1 | `/home/aneryu/worktree-grok-g1-regexp` | `grok/audit-fix-g1-regexp` | `/tmp/grok-1000/audit-exec/g1-summary.md` |
| G2 | `/home/aneryu/worktree-grok-g2-object` | `grok/audit-fix-g2-object` | `/tmp/grok-1000/audit-exec/g2-summary.md` |
| G3 | `/home/aneryu/worktree-grok-g3-parser` | `grok/audit-fix-g3-parser` | `/tmp/grok-1000/audit-exec/g3-summary.md` |
| G4 | `/home/aneryu/worktree-grok-g4-value` | `grok/audit-fix-g4-value` | `/tmp/grok-1000/audit-exec/g4-summary.md` |
| ALL | `/home/aneryu/worktree-grok-audit-all` | `grok/audit-exec-20260814` | G1→G4→G3→G2 已合入 main `65a60344`；17/17 difftest IDENTICAL；test-parser 493 / test-exec 435 / test-core 329 |

### §6 验收

| 项 | 结果 |
|---|---|
| 合并顺序 | G1 `ab2cd515` → G4 `32100b5d` → G3 `cb4d3d16` → G2 `a56baaaf` → 集成 `65a60344` → X-10 依赖方 `192a097d` |
| `zig build test262-gate --seed 0` | **0/49775 errors，passed 44581**（与基线相同）。合入后第一次 gate 暴露 5 个 `harness/deepEqual-*.js` TypeError：tagged-template 数组无 `Array.prototype`，`strings.map` 不是函数。`192a097d` 后复跑归零。 |
| zoo A/B | 产物 `zoo-ab-pad{0,3,7}.json` + `zoo-ab-audit-exec-pack.json`。`--zjs`=after / `--qjs`=before，CPU 19，8 samples，ABBA。 |
| geomean after/before | pad0 **1.0018** / pad3 **0.9998** / pad7 **1.0019**；中位 **1.0018**（+0.18%，约 +0.17 pp） |
| 三大反超资产（中位） | crypto **1.009** / code-load **0.998** / regexp **1.007**。无超噪声回退（regexp pad3 0.993 被 pad0/pad7 的 1.007 对冲，符号翻转 = 布局噪声）。 |
| 其它同号移动 | typescript 三 pad 均约 +1.2%；mandreel 三 pad 均约 −1.2%。geomean 仍在 MDE 内，不触发回滚。 |
| 判读 | **性能中性，正确性通道落地**。X-10 未给出可测正效应（+0.17 pp < 0.278 pp），不进 PARITY-LEDGER 机制候选。 |

## 10. Driver 审查记录（2026-08-14，事后复核）

### 10.1 正确性面：坐实

- 抽验 9 条亲跑 difftest（X-01/02/03/04/05/10/29/38 + X-05 的 `if(false)break` 附带改动）：**全部已修**。
- canonical `zig build test262-gate` 由 driver 亲跑复核：**0/49775 errors, passed 44581**，与 §6 账面一致。
- `lint_anti_goals.sh` exit 0。
- 残留偏离（须登记，非阻塞）：**X-01 v-mode 接受集合收窄**——`"[".repeat(1000)+"a"+"]".repeat(1000),"v"`
  zjs 现报 `SyntaxError: stack overflow` 而 qjs accepted。检查是诚实的（修复前同深度直接 SIGSEGV），
  暴露的真差异是 **zjs v-mode 类解析每层栈耗远大于 qjs**。进 backlog。

### 10.2 性能判读订正：「中性」是错误的粗读

§6 的 geomean-in-MDE 一票放行**掩盖了四个三 pad 同号、效应>样本离散的 SEMANTIC 信号**
（lineage 判据：同号且 |中位| > 离散）：

| benchmark | 三 pad | 中位 | max CV | 判 |
|---|---|---:|---:|---|
| typescript | +++ | **+1.23%** | 0.29% | SEMANTIC 赢 |
| crypto | +++ | +0.93% | 0.53% | SEMANTIC 赢（资产增厚） |
| box2d | +++ | +0.78% | 0.23% | SEMANTIC 赢 |
| mandreel | −−− | **−1.23%** | 0.49% | **SEMANTIC 回退，验收时未归因即放行** |

净 +0.18% 是**对冲结果**，不是「什么都没发生」。

### 10.3 单基准 lane 二分归因（16 samples，CPU 19，vs base `6d8295ce`）

| 累积段 | mandreel | typescript |
|---|---:|---:|
| G1+G4（`32100b5d`） | +0.43% | — |
| +G3（`cb4d3d16`） | −0.11%（G3 段 −0.54%） | −0.48%（非-G2 合计） |
| +G2（HEAD） | **−1.44%（G2 段 −1.33%）** | **+1.23%（G2 段 +1.71%）** |

- **TS 的赢与 mandreel 的亏都在 G2**（`b9f5731e`，五条目单 commit 未拆）。
- X-10 兜底删除拿到**实测定价 +1.71% on TS**——同时第 N 次印证合同第 9 条：
  静态「每次 miss 都付」的税，动态上只有 TS 一个基准可测出（zoo 热循环属性读几乎全 hit）。
- mandreel 段内嫌疑排序：X-07 整数键 Set 冷路径重构 > X-10 依赖方（arguments dense-Get、
  rest/iterator/keys 数组换真原型）> X-02/08/09（纯冷）。**须拆 patch 消融定位**；
  这些是正确性修复不能回滚，正确动作是「让忠实路径与 qjs 同价」——qjs 在相同语义下不亏。

### 10.4 「优化效果不及预期」的裁定

1. 本批在 §0 就注册为**正确性通道**，预注册判据即「geomean 在 ±MDE 内＝符合预期」——
   期望差主要来自把本批当成了优化批次；真正的优化储备（44 条热频 zjs-only 机制、
   tail_call 发射、readfwd 假设）全在 §8 backlog 未动。
2. 但验收本身有一处方法论错误（10.2）：单基准同号信号被 geomean 吞掉。
   **已修正为：打包 zoo A/B 的判读必须逐基准过 lineage 判据，不允许只看 geomean。**
3. mandreel −1.33% 已归因到 G2 并登记 PARITY-LEDGER；后续任务=段内拆分消融 + 忠实路径成本对齐。
