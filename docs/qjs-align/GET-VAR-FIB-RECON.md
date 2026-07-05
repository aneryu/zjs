# GET-VAR-FIB-RECON — fib 自引用的 get_var 双引擎对照侦察

日期:2026-07-04 · qjs 参考:/home/aneryu/quickjs(Bellard 版,version 2026-06-04)· zjs:main HEAD(bd50aeb)
方法:qjs 侧自建 `DUMP_BYTECODE=1` dump 二进制(/tmp/qjs-dump,原 quickjs.c:93 注释宏打开 + 20 行 mini host 绕过 repl blob 链接失败)+ 源码逐行;zjs 侧 `ZJS_DISASM=1` dump + perf record/annotate/stat(taskset -c 0,armv8_pmuv3_0)。

## TL;DR 判定

1. **bench 真实形态是顶层声明**:`/home/aneryu/.claude/jobs/eb06ffb9/tmp/bench/fib.js` 中 `function fib` 与 `function main` 都在脚本顶层,fib **不是** main 的局部函数(任务预设第 3 点与真实文件不符,已按真实文件 + 另造 wrapped 变体双双分析)。
2. **parser/lowering 偏离不成立**:两引擎对同一输入编译出同构字节码 —— 顶层自引用两边都是 `get_var <u16 idx>`(3 字节、闭包变量表索引、**非 atom**);wrapped 变体两边都是 `get_var_ref0` + main 内 `get_loc`。lever ②(parser/scope lowering)在此场景**没有可对齐的差异**。
3. **任务预设的 zjs 运行时形态(名字查询+IC)也不成立**:zjs 热路径 `op_get_var` 不做名字查找、不碰 IC —— 它和 qjs 一样直读 var_refs cell;名字+IC 只在冷路径 `vm_property_globals.getVar`,本 bench 从不执行(perf 证:冷符号零样本)。
4. **真偏离(代码实现级)在 var_refs 槽契约**:
   - qjs:`JSVarRef **var_refs` **类型化数组,构造期保证每槽是真 cell**;一切歧义(delete/顶层 let 遮蔽/eval 绑定/未声明全局)在**闭包创建期/突变期**折叠进 cell 状态;`OP_get_var` 热路径 = 2 次载入 + 1 个 `JS_IsUninitialized` 检查 + dup。
   - zjs:`frame.var_refs: []JSValue` 无类型槽(可装原始值/嵌套 cell/被 eval republish),`op_get_var` 每次执行付 **8 项守卫**,其中两条 GC header kind 字节载入(判「槽是 cell」+「值不是嵌套 cell」)合计占该 op 24% 时间,是最热两条指令;另付 5 对寄存器 spill 序言。
5. 量化:fib bench zjs/qjs = 2.36× 指令 / 2.61× 周期;`op_get_var` self 10.91%(≈28 cycles/次 vs qjs ≈4);qjs 从 get_var 换 get_var_ref 只差 1.4% 周期而 zjs 差 8.8% —— 守卫即偏离的直接实验证明。修复上限 ≈ zjs fib 自身时间 9%,≈ zjs−qjs 差距的 15%。

---

## 1. qjs 侧形态(源码 + dump 双证)

### 1.1 dump ground truth(真实 bench 文件)

```
function: fib            closure vars: 0: var fib [global_ref0]
    7:  get_var 0: fib   ← 自引用,u16 idx=0
function: main           closure vars: 0: var fib [global_ref0]
        get_var 0: fib   ← 调用点同样是 get_var
function: <eval>         closure vars: 0: fib [global_decl]  1: main [global_decl]  2: print [global]
        fclosure8 0; put_var_ref0 0: fib   ← 顶层前奏:函数值经 cell 写入
```

wrapped 变体(fib 声明进 main 内):

```
function: fib    closure vars: 0: var fib [loc0]
    7:  get_var_ref0 0: fib      ← JS_CLOSURE_LOCAL 捕获,1 字节
function: main   locals: 0: var fib …
        fclosure8 0; put_loc0    ← decl 提升到函数顶
        get_loc0 0: fib          ← main 内调用点 = 纯局部槽
```

### 1.2 编译链(行号 = quickjs.c)

| 步骤 | 机制 | 行号 |
|---|---|---|
| 顶层 `function fib(){}` | `js_parse_function_decl2`:`is_global_var` → `add_global_var`,`hf->cpool_idx = idx` 标记函数声明 | 37040-37050 |
| global_vars → 闭包变量 | `js_create_function`:`fd->is_eval` → `add_global_variables` 把每个 JSGlobalVar 转成 **JS_CLOSURE_GLOBAL_DECL** cv(函数声明 `cpool_idx>=0 && !is_lexical` → var_kind=JS_VAR_GLOBAL_FUNCTION_DECL);**先于子函数创建**,子函数解析时父闭包表已就绪 | 36066-36070 / 35954-36001 / 36074-36089 |
| fib 内自引用解析 | `resolve_scope_var`:本地扫描未中(32938-32958)→ 父函数链未中(33106-33183,顶层函数的全局在 global_vars 不在 vars)→ `fd->is_eval` 分支扫父闭包表(33189-33215):命中 `fib [GLOBAL_DECL]` → 在子函数登记 **JS_CLOSURE_GLOBAL_REF**(33196-33206)→ 发射 `OP_get_var <u16 idx>`(33269-33273) | 32916-33283 |
| 未声明全局(如 print) | 33236 `add_closure_var(JS_CLOSURE_GLOBAL)` → 同样发射 get_var u16 | 33235-33248 |
| wrapped:decl 变局部 | `!is_global_var` → `define_var(JS_VAR_DEF_VAR)` + `vars[var_idx].func_pool_idx = idx`(函数顶 fclosure+put_loc) | 37028-37038 |
| wrapped:自引用 | 父链命中 main.vars → `capture_var` + `get_closure_var(JS_CLOSURE_LOCAL)`(33292-33298)→ `OP_get_var_ref`(短形 get_var_ref0,opcode.h:333-336) | 33106-33135, 33309+ |

关键设计事实:**此版本 qjs 的 `OP_get_var` 操作数是 u16 闭包变量索引,不是 atom**(quickjs-opcode.h:126-128,`var_ref` 格式,3 字节)。全局变量访问已是"scope-resolved"编码 —— zjs 现行编码与之完全一致。

### 1.3 运行时机制

**闭包实例化 `js_closure2`(17262-17339)**:每个 cv 槽装一个**真 JSVarRef**:

- `JS_CLOSURE_GLOBAL_DECL` → `js_closure_define_global_var`(17125-17226):在**全局对象上创建 `JS_PROP_VARREF` 属性**,cell 即属性存储(`pr->u.var_ref = var_ref`,17218-17224)。全局变量本体就是一个 var_ref cell,属性与所有捕获者共享同一 cell。
- `JS_CLOSURE_GLOBAL` → `js_closure_global_var`(17228-17260):先查 `global_var_obj`(顶层 lexical,17235)→ 再查 `global_obj` VARREF 属性(17243)→ 都未中 → `js_global_object_get_uninitialized_var`(17069-17096):在全局对象的 **uninitialized_vars 侧表**登记一个值为 `JS_UNINITIALIZED` 的 cell。
- `JS_CLOSURE_GLOBAL_REF` → 直接拷父帧指针 `var_refs[i] = cur_var_refs[cv->var_idx]`(17322-17324)。

**解释器 `OP_get_var`(18461-18488)**:

```c
idx = get_u16(pc);
val = *var_refs[idx]->pvalue;             // 2 次依赖载入
if (unlikely(JS_IsUninitialized(val))) {  // 唯一检查
    ... JS_GetPropertyInternal(ctx->global_obj, cv->var_name, ...)  // 慢路兜底
} else {
    sp[0] = JS_DupValue(ctx, val);
}
```

**`OP_get_var_ref`(18627-18637)**:连 uninitialized 检查都没有,纯 `*var_refs[idx]->pvalue` + dup。

**歧义如何被挤出热路径(全部在突变期折叠进 cell 状态)**:

| 条件 | qjs 处理点 | 行号 |
|---|---|---|
| delete 全局 var | `remove_global_object_property`:cell 值置 `JS_UNINITIALIZED` + cell 挪进 uninitialized_vars 侧表 → 读端命中唯一的 uninit 检查 | 9288-9309(delete_property 9348-9351 调用) |
| 顶层 `let x` 遮蔽既有全局 var | 定义期 cell 手术:旧 cell 变成 lexical cell(捕获者自动改读 lexical),新 cell 顶替属性 | 17148-17162 |
| 未声明/builtin 全局(print) | cell 初值 UNINITIALIZED → 每次读走 `JS_GetPropertyInternal` 通用查找 | 17069 + 18476 |
| direct eval 绑定 | 编译期真闭包变量 `add_eval_variables`(无运行时 overlay 名单) | 33610 / 36064-36065 |

**回答任务问题「qjs 对 global 读是否也走通用属性查找」**:分两类 —— 脚本内声明的 var/function(fib 属此类):**否**,永远是 cell 直读;脚本外 builtin/未声明全局(print):**是**,每次经 uninit sentinel 落 `JS_GetPropertyInternal`。fib 的自引用属于前者,便宜形态成立。

---

## 2. zjs 侧形态

### 2.1 dump(ZJS_DISASM=1,与 qjs 同构)

```
顶层:   fib 自引用  7: get_var 0   (raw 38 00 00,u16 idx)   main 调用点同 get_var 0
wrapped: fib 自引用  7: get_var_ref0 (raw db)                 main 调用点 get_loc2
```

与 qjs 唯一表面差异:wrapped 变体 main 的局部槽序(qjs 函数声明占 loc0,zjs 排 s/i 之后占 loc2)—— 纯 cosmetic。

### 2.2 编译链(与 qjs 同构)

| 步骤 | zjs 机制 | 位置 |
|---|---|---|
| 标识符引用 | `emitScopeGetVar`:phase1 发 `scope_get_var`(atom+scope u16,同 qjs 267-278 的临时 op) | src/parser.zig:5231-5238 |
| 顶层函数声明 | `addGlobalVar` 进 global_vars(qjs find_global_var/24066 等已在注释锚定) | src/parser.zig:4262-4276 / 4209-4232 |
| resolve_variables 决策 | local(scope 链)→ closure(`lookupClosureVar`)→ global(`emitGlobalVarOp` → `ensureGlobalClosureVar` 加 `.global` cv 携 atom → 发 `get_var <u16 idx>`) | src/bytecode.zig:4530-4576 / 3141-3165 / 3179-3200 |
| wrapped 自引用 | parser `ensureClosureVar` 父链命中 main.vars → `.local` cv → `get_var_ref0`(短形 selectVarRefForm) | src/parser.zig:5327-5378;src/bytecode.zig:3267-3272 |

### 2.3 运行时:cell 别名机制已对齐,守卫未对齐

**捕获(js_closure2 等价物)** `createBytecodeFunctionObject` 捕获 switch(src/exec/object_ops.zig:431-464):
- `.local` → `ensureLocalVarRefCell`(≙ JS_CLOSURE_LOCAL)
- `.global_ref` → `frame.var_refs[cv.var_idx].dup()`(≙ JS_CLOSURE_GLOBAL_REF)
- `.global/.global_decl` → `createGlobalClosureVarRef`(object_ops.zig:253-264)→ `globalObjectVarRefCell`(src/exec/call_runtime.zig:3776-3781):**zjs 也把顶层 var/function 存成全局对象上的 VARREF 属性 cell 并别名之**(`ensureGlobalObjectVarRefCell` call_runtime.zig:3783+,注释直接锚定 qjs 17171-17205)。fib 的 cell 共享链路与 qjs 同构 —— perf 证实 fast path 全程命中。

**热路径 `op_get_var`(src/exec/tailcall_dispatch.zig:1217-1231)—— 与 qjs 的逐项对照**:

| # | zjs 守卫(每次执行) | qjs 对应 |
|---|---|---|
| 1 | `vm.local_fast_blocked`(1 load+branch) | 无(无此机制) |
| 2 | `hasDynamicGlobalOverlay`(vm_property_globals.zig:97-108;4 个 slice len + 1 value tag) | 无 —— eval 绑定是编译期闭包变量 |
| 3 | `idx >= frame.var_refs.len` bounds | 无(bytecode 保证) |
| 4 | `varRefCellFromValue`:**载 GC header kind 字节**判槽是 cell | 无 —— `JSVarRef**` 类型化,构造保证 |
| 5 | `cell.is_deleted` flag | 无 —— delete 折叠进 UNINITIALIZED sentinel(9288) |
| 6 | `v.isUninitialized()` | **有(唯一检查,18469)** |
| 7 | `VarRef.fromValue(v)`:**载值的 GC header kind 字节**判非嵌套 cell | 无 —— cell 里永远是值,不可能套 cell |
| 8 | `globalLexicalShadowsGlobalForIdx`(ctx.lexicals null 检查) | 无 —— let 遮蔽在定义期做 cell 手术(17148) |
| 9 | `parentEvalShadowsGlobalForIdx`(frameClosureHasEvalParent) | 无 —— 同 2 |

外加:handler 序言 5 对寄存器 spill(`sub sp,#0x50` + 4×stp,因 shadow 慢臂含 out-of-line 调用;≙ memory「帧=所有 arm spill 之和」)。

**`get_var_ref0`(opGetVarRef,tailcall_dispatch.zig:720-744)**:同样付 #3/#4/#5/#6/#7 五项(无 overlay/shadow),qjs 对应 op 为**零检查**。

**冷路径 `getVar`(src/exec/vm_property_globals.zig:160-330+)**:atom 名字查找瀑布 + per-pc IC(`fastInstalledGlobalDataValueForAtomAtPc`:215、`globalDataPropertyValueForFastPath`:229)。**本 bench 从不执行** —— 任务预设的「名字查询+IC」只存在于这里。

---

## 3. perf 证据(taskset -c 0,fib(30)×3)

| 指标 | zjs 顶层 | qjs 顶层 | zjs wrapped | qjs wrapped |
|---|---|---|---|---|
| instructions | 7.438e9 | 3.147e9(0.42×) | 7.098e9 | 3.123e9 |
| cycles | 2.094e9 | 0.803e9(0.38×) | 1.910e9 | 0.792e9 |

- `op_get_var` self **10.91%**(2996 样本 record;冷符号 `vm_property_globals.getVar` 零样本 → fast path 全命中)。≈8.08M 次 get_var(2,692,537 调用/fib(30) 中 1,346,268 内部节点 ×2 ×3)→ **≈28 cycles/次**;qjs 等价序列 ≈4-5 cycles。
- annotate 内部分布(op_get_var 327 样本):**#4 header 字节载入 10.42%+1.53%、#7 header 字节载入 13.44%+2.75%**(两条 `ldurb [x,#-6]` = 该 op 28% 时间,每次触碰 cell 与函数对象两条额外 cache line)、#6 uninit cmp 8.25%(依赖载入停顿)、序言 stp 链 ~12%、#2 overlay 链 ~8%、槽载入 6.42%。
- **换形态对照实验**:qjs 顶层→wrapped(get_var→get_var_ref)只省 1.4% 周期 —— 两 op 在 qjs 里同价;zjs 同样变换省 8.8% —— overlay/shadow 守卫(#1/2/8/9)即差价。守卫是偏离,形态不是。

---

## 4. 偏离判定

**不成立的偏离(任务预设)**:
- ✗「qjs 把 fib 解析成更便宜的 scope-resolved 形态、zjs 停在 get_var」—— 两边形态一致(顶层 `get_var u16` / wrapped `get_var_ref0`),且此版 qjs 的 get_var 本身就是 index-based cell 读。parser/scope-lowering 无事可做。
- ✗「zjs get_var 运行时 = 名字查询+IC」—— 那是从不执行的冷路径;热路径已是 cell 直读。

**成立的偏离(代码实现级,quickjs.c 锚点如上)**:
- ✓ **var_refs 槽契约**:qjs `JSVarRef **var_refs`(JSObject.u.func.var_refs,17277)类型化 + js_closure2 构造保证每槽真 cell;zjs `frame.var_refs: []JSValue` 无类型,槽/值双重运行时判别(#4/#7)。
- ✓ **语义解决时机**:qjs 在闭包创建期(17125/17228/17069)与突变期(9288/17148)把 delete/let-shadow/eval/未声明四类歧义折叠进「捕获哪个 cell + cell 是否 UNINITIALIZED」;zjs 把同四类语义留给每次读(#2/5/8/9)。
- 代价:~24 cycles/次 × 8.1M 次 ≈ 195M cycles ≈ zjs fib 时间 9.3% ≈ zjs−qjs 差距(1.29e9 cycles)的 15%。get_var_ref/put_var/put_var_ref 三个双胞胎同病同治。

---

## 5. 忠实修复路径(exec 层,非 parser)

按 qjs 机制逐条搬语义解决时机,每步独立可门禁:

| 步 | 内容 | qjs 锚 | zjs 动点 | 删除的守卫 |
|---|---|---|---|---|
| 1 | delete → sentinel:删全局 VARREF 属性时置 cell UNINITIALIZED + uninitialized_vars 侧表(zjs 尚无侧表概念,需在 global object 挂等价物) | 9288-9309, 17069-17096 | 属性删除路径 + slot_ops cell 语义 | #5 is_deleted |
| 2 | 顶层 let 遮蔽 → 定义期 cell 手术(旧 cell 变 lexical cell、新 cell 顶属性);zjs `defineGlobalDeclVarCell`/`globalLexicalCell` 已有半套 | 17134-17162 | call_runtime.zig:3765/3783+ 定义路径 | #8 globalLexicalShadows |
| 3 | 槽类型化:创建期保证 var_refs 每槽真 cell、chase 嵌套链(module import/eval republish 的 cell-in-cell 在实例化时解开,≙ js_closure2 每臂返回 JSVarRef*);终态 `frame.var_refs: []*VarRef` | 17262-17339 | frame.zig 结构 + object_ops 捕获 switch + eval republish 各写点 | #4、#7 两条 header 载入(本 op 28% 时间)+ #3 |
| 4 | eval overlay → 编译期闭包变量(direct eval 编出真 cv 链,删 frame 上的 eval_local_names/eval_var_ref_names 运行时名单) | add_eval_variables 33610, 36064 | parser eval 编译 + call_runtime overlay 全网(数十处) | #2、#9 + 序言 spill 大半 |

**波及面/风险**:每个守卫都护着真语义 —— test262 的 delete/global-let-TDZ/direct-eval/annex-B 族是雷区;Step 3 动 Frame 结构,generator resume、module import、direct-eval republish 全要全量回归(memory 纪律:帧改动唯一 oracle = 全量 test262,gate 前 sequential 重建 zjs+run-test262 两个二进制);Step 4 与 REMAINING-KNOWN-HANDOFF 的 direct-eval 重构同体,all-or-nothing 不可增量。

**预估工作量**:Step 1-2 各 ~1-2 agent-日;Step 3 ~3-4 agent-日(结构改动+全量门禁);Step 1-3 合计约一周,可摘 #3/4/5/7/8 五项守卫 ≈ 该 op 一半以上时间;Step 4 1-2 周,并入已有 eval 重构计划而非单独做。**收益上限 fib 总时间 ~9%(对 qjs 差距的 ~15%)** —— 值得做但非 fib 主杠杆;fib 主差距仍在调用机制函数分解(memory:CALL-MACHINERY-FAITHFUL-FRONTIER,fib gap=指令数 2.88× 非停顿,本次实测 2.36× 指令印证)。

## 附:侦察踩点记录

- qjs 官方二进制无字节码 dump 选项(`-d`=内存统计);`DUMP_BYTECODE` 是编译期宏(quickjs.c:93,bit1=最终字节码);qjs.c 链接需 repl blob(qjsc_repl),用 mini host(JS_Eval + js_std_add_helpers)绕过。
- zjs dump 开关:`ZJS_DISASM=1` 环境变量(src/bytecode.zig:6422-6430),只 dump 嵌套函数不含顶层 `<eval>`,不显示闭包变量表(可考虑补齐 dump 以便日后对照)。
- aarch64 big.LITTLE 双 PMU:perf stat 须显式 `armv8_pmuv3_0/…/` 事件名,裸 `instructions` 在 taskset 下 `<not counted>`。
