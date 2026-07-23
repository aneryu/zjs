# OPT-ROADMAP 2026-07-19 — QuickJS 机制忠实对齐计划

> 当前 main 审计基线：`936111c5fd6d1b0be522672d681b3eb0eeda1a50`。
> `M-FCLOSURE-WIDTH` 已在该点完成并合入；当前
> `perf/hoist-construction-qjs-align` 是以它为 base 的**未合入审计候选**，不能当成新 baseline。
>
> named-function compiler correctness 前置已由 `c034597c` 合入，宽 `fclosure` correctness 前置已由
> `936111c5` 合入；两者均不计作后续 plain-put 收益。旧 M-CELL binary 只保留历史证据用途。
>
> P1 构造候选的 pre-change ReleaseFast zjs 冻结件位于
> `.scratch/m-hoist-construction/baseline/zjs`：完整 SHA-256
> `e718f917c30191b372cd2b464c91f7ae7ffc0b3776dd52013817814ad9073642`；`.text`
> SHA-256 `d20da48f6f353fca62be1a1ac1af06c794f152685190f9afeaedb06560af11ca`
>（4,035,952 bytes）。它只用于本候选审计；P1 真正收口后仍须重新冻结 M-CELL。
>
> 性能参照 qjs：完整 SHA-256
> `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`；`.text`
> SHA-256 `f2d32f392089673065d7984b61c3ca30d818df54b9816152cd40d5d11e29b5bb`
>（725,228 bytes）
>
> QuickJS 源码 checkout：`/home/aneryu/quickjs-zjs-ref` @
> `04be246001599f5995fa2f2d8c91a0f198d3f34c`；该 checkout 新建 qjs 的完整 SHA-256 为
> `5e331bf92e236c8e2c3bd88032b3c1ec2c2e9e0cfe2e1bd40b4ce2bbeaacd365`，与性能 qjs 的
> `.text` 逐字节相同。完整 hash 差异来自非 `.text` 构建产物，性能仍固定使用前一个二进制。
>
> 本文取代 2026-07-18 版本；基于 2026-07-19 对当前代码、QuickJS 源码、历史战报和 PMU 的重新审计。
>
> **第七次 QuickJS 反向复核与 CORE 收口（2026-07-20，当前状态）**：第六次复核列出的
> `M-LVALUE-PROVENANCE-CORE`缺口已按机制落地，但结论严格限于ordinary reference/call surface：
>
> 1. private member producer已恢复为普通field transport；`delete`按atom的private kind拒绝，而不是按`#`字符串猜测。
>    完整private slot/brand/VarKind/class-init仍归W1d，本轮不把baseline transport写成QJS exact。
> 2. code、atom operand、source loc、parser-label count与last-op由同一emission snapshot回滚；lvalue detach/owner transfer、
>    optional bridge和moved-bytecode splice均先完整校验/claim再无失败commit。`push_const`改为先事务性发占位opcode、
>    cpool成功后无失败patch，避免orphan constant。该结论不外推到后续child/finalizer topology transaction。
> 3. ordinary assignment/update、generic for LHS及simple `var`共用最后opcode驱动的`getLValue/putLValue`；正式reference target
>    直接patch。`emitScopeMakeRef`、`active_with_atom`和bounded `findGlobalRefPutTail`现只剩具名destructuring旧路径，必须在
>    紧随其后的M-DSTR checkpoint一起删除，不能据此宣称全parser reference已封口。
> 4. normal call、optional call与tagged template共用一个call consumer；identifier/member/super producer不看后续token。
>    direct eval、with receiver、parenthesized super、comma tag均由最终opcode决定，旧call/source-tail状态已删除；对象shorthand
>    也只发普通scope getter。pinned QuickJS自身对`with (s) m?.()`报`InternalError: inconsistent stack size`，zjs对应
>    `SyntaxError: StackMismatch`；它作为reference已知失败单列，不伪装成正向语义通过。
> 5. optional chain整链只创建一个共享label identity，每个短路边引用该identity；getter后的raw label不覆盖last-op。
>    binder先验证全部definition/reference，再一次分配映射并commit；不存在固定16项数组、per-exit vector或signature scan。
>    257-site普通/delete/closed-call/optional-call回归均通过。
> 6. 当前证据：QuickJS差分5/5逐字节输出一致；`test-parser`397/397、`test-bytecode`98/98、`test-exec`284/284、
>    OOM injection 8/8、`quick-check`8/8 steps、`checkpoint-check`32/32 steps（统一Debug 1613/1613、test262-smoke 12/12）
>    全绿；定向test262 optional-chaining 38/38、class statements/elements准备1534项且1532通过、2项feature skip、0 error。
>    下一步因此是`M-PARSER-CONTROL-CLEANUP`，随后进入不可拆的M-DSTR traversal checkpoint；不得回头用特性fast path
>    替代这次建立的last-op/transaction/label机制。
>
> **第六次 QuickJS 反向复核（2026-07-20，历史裁决；边界规则仍适用）**：本轮以
> `emit_op/get_prev_opcode → get_lvalue/put_lvalue → call rewrite → js_parse_delete →
> js_parse_destructuring_element/js_parse_for_in_of`为一条链重新核对，并用当前未提交实现做反证。结论是
> `M-LVALUE-PROVENANCE-CORE`必须缩回**普通 reference provenance**，不能同时吞下 class-private 拓扑和
> destructuring 单遍化：
>
> 1. QuickJS不只让assignment读取`last_opcode_pos`；普通call、optional call和tagged template也在call点统一
>    switch最后一条`scope_get_var/get_field/get_array_el/get_super_value/scope_get_private_field`，再决定direct
>    `eval`、`scope_get_ref`或receiver-preserving getter。当前zjs仍在identifier/member parse时看后续`(`提前选择
>    `scope_get_ref/get_field2/get_array_el2/private2`，并用`last_was_direct_eval_callee`、
>    `last_was_with_method_ref`和括号tail扫描修补。故当前步新增一个共享`rewriteCallReference` consumer；普通identifier
>    无论with/direct-eval/括号一律先发`scope_get_var`，direct eval判定优先于with rewrite，`new`不误继承method receiver。
> 2. QuickJS optional chain在getter后追加不更新last-op的raw label，再把getter改成
>    `get_field_opt_chain/get_array_el_opt_chain`；delete/call直接从该相邻phase-1形状取得chain label。当前zjs的
>    `last_opcode_is_optional_chain`布尔、固定16项exit buffer和全段bytecode signature scan不是Zig限制，也不是唯一
>    provenance。整条链必须像QuickJS一样只持一个共享`LabelSlot/LabelRef`，每个短路边只引用它；不能按每个`?.`
>    收集exit，也不能以“可增长vector”替换固定数组。若保留zjs absolute-offset label表示，只能作为经resolver/relocation/OOM
>    对照证明等价的单一fixup identity；证明不了就直接采用QuickJS label slot。超过16个`?.`必须正常编译，且不会因链长
>    额外分配per-exit状态。
> 3. `get_lvalue`截下atom后，所有成功、语法错误和OOM出口都必须恰好转移或释放一次；当前descriptor在re-emit/
>    make-ref失败时仍可能失去owner。`put_lvalue`本身不发source marker，compound/update只在QuickJS明确的operator
>    source位置发一次；当前setter/shuffle用普通source-aware helper会制造伪pc2line。当前步必须同时锁atom refcount、
>    source-loc和Nth-OOM，不能只锁stdout。assignment仍用`KEEP_TOP`、logical assignment仍用QJS的
>    insert+`NOKEEP_DEPTH`、postfix仍用`KEEP_SECOND`；discard优化只能由对应final pass证明，不能让parser的
>    `result_needed`改变phase-1 reference协议。
> 4. QuickJS的普通`var x = rhs`也是reference consumer：`need_var_reference`成立时先发
>    `scope_get_var → get_lvalue(FALSE)`，RHS后在`=`位置发source，再由`put_lvalue(NOKEEP)`写回。当前zjs却直接发
>    label operand保持未patch绝对偏移`0`的`scope_make_ref`，resolver再用最多16条指令的`findGlobalRefPutTail`猜put尾部；旧destructuring binding也走
>    同一补偿。普通`var`必须在CORE阶段迁入正式descriptor/label；旧pattern fallback只可具名活到M-DSTR，pattern迁完后
>    这种unpatched-target producer和bounded tail scan必须同时为零。QuickJS `optimize_scope_make_ref`读取正式label slot的`pos`，不存在
>    “安全扫一小段”的等价机制。
> 5. 当前private半迁移已用最小`class A { #x=1; m(){ return this.#x; } }`稳定复现
>    `ClosureVarNotFound`。原因不是lvalue classifier：QuickJS在声明点用
>    `add_private_class_field(add_scope_var, lexical+const+VarKind)`建立槽并以`private_symbol`、method或accessor初始化，
>    resolver再按field/method/getter/setter展开不同的`get_private_field/check_brand/call_method/throw`序列；zjs仍只有
>    private-name side table和home-object descriptor copy。只给resolver加atom fallback或只补空VarDef都会形成双authority，
>    禁止合入。普通M-LVALUE暂不改变private producer；完整private迁移留在W1d，并把
>    `add_private_class_field → slot init → setter companion row → VarKind lowering → method/accessor需要时每个instance/static侧至多一个brand → 删除
>    descriptor copy/remap side channel`作为一个不可拆的checkpoint。
> 6. destructuring当前只有通用target helper开始使用descriptor，生产路径仍有
>    `destructuringAssignmentTargetCanStart`、`thisPrivateAssignmentTargetFollows`、array/object shape scan和完整pattern
>    双parse。M-LVALUE只交付可复用API；这些consumer在紧随其后的M-DSTR-SOURCE-ORDER一次正式遍历中迁移并删除，
>    不能提前宣称“destructuring已统一”，也不能为了让当前步独立变绿再造第三套target parser。
> 7. 因此当前未提交M-LVALUE实现不是合入候选：parser 395/395只能证明局部语法未退化；exec的3个private用例因
>    `ClosureVarNotFound`对用户表现为`SyntaxError`，已经证明阶段边界错误。修订后的顺序是
>    `M-LVALUE-PROVENANCE-CORE → M-PARSER-CONTROL-CLEANUP → [M-DSTR-SOURCE-ORDER → M-DEFINE-VAR-CLOSE →
>    M-DSTR-STACK]不可拆checkpoint（在此迁全部pattern target） → ... → W1d PRIVATE-BINDING/CLASS-INIT checkpoint`。CORE退出前还必须让
>    `scope_no_dynamic_env_flag/selected_reference/emitScopePutVarNoDynamicEnv`零生产，并删除仅服务call/source-tail补偿的
>    状态；`active_with_atom`若暂由旧destructuring binding transport读取，只能具名留到M-DSTR，普通expression consumer必须为零。
>
> **最新 worktree 复审快照（未提交）**：W1b1 的 ordinary/parameter-eval **语义表契约**已完成：最终
> vardef 为 args→locals 单表，eval operand 为最终链头，parameter environment 由 `ARG_SCOPE_END` 表达，
> compile/final closure row 均已删除 `source_depth`，dynamic-env lookup 按表序，eval identity 为不向子函数传播的
> combined bit。dynamic-env 的 producer 也已按 QuickJS 分成两条路径：只有函数自身含 direct eval 时才由
> `add_eval_variables` 捕获可见父绑定；普通后代只有在未解析名字实际跨过 `<var>/<arg_var>` 时才由
> `resolve_scope_var` 逐层转发，不能 blanket-propagate。W1b2 也已在该未提交 worktree 落地：compile/final
> closure 共享 8B/align4 storage，final vardef 为 12B/align4，`VarKind` 恢复 QJS 0..10，临时
> `class_static_this` 只占未用 11，uncaptured final row 以 `is_captured=0,var_ref_idx=0` 表示。零填充
> QJS C probe 与 Zig raw golden 逐字节一致；15 轮 Zoo paired median 为 -1.10%，低于裁决线，故性能收益明确记零。
> 仍有一个明确未封闭项：static class-field initializer 还以内联代码执行，因此 `eval/apply_eval` 暂占
> `0x8000` 传递 grammar capability，并把可用链头限制在 15 位；它归 W1d“把 static initializer 也迁入
> `<class_fields_init>` child”所有，不能写成 Zig 限制或已对齐。此次复审还修正了遗留 `0x3fff` mask，
> `0x4000` 已恢复为普通 scope 数据。2026-07-20 最新 declaration/body-identity slice 已重跑
> `test-parser` 395/395、`test-bytecode` 98/98、`test-exec` 282/282、`test-builtins` 175/175；
> 随后`quick-check` 3/3与`checkpoint-check` 32/32 steps全绿，其中统一Debug 1609/1609、architecture/public API、
> Debug/ReleaseFast smoke及test262-smoke 12/12均通过。ReleaseFast完整test262仍是更早证据：当时准备49775项，
> 44599通过、2项与`test262_errors.txt`完全相同、0项unexpected；3518项配置排除、5174项因feature跳过。
> 该full-test262证据包含旧的spec-over-QJS catch-var行为，不能再作为本轮“忠实QJS”出口；OOM injection与最终唯一一次
> ReleaseSafe仍未运行，因此这仍不是合入结论；W1b2的Zoo数字只证明当时isolated row-layout候选性能中性，后续
> correctness变化已经使“当前worktree总体性能”基线失效；ordinary/core compiler可在W1b2.5独立收口，但总体性能基线要等
> W1b2.6移除剩余using runtime helper/cache后再冻结，避免把产品特性初始化债务带进后续Realm/FB归因。
> 最新focused gate覆盖了普通block/function-body分界、body pre-scan删除、generic for-in/of非声明LHS单遍构造、
> parser-time visible scope head、catch wrapper、if/classic-for/for-in-of/switch/with/class scope节点及lexical-for单一binding。
> 两个direct-eval assignment测试原预期不是pinned QuickJS行为；源码oracle与当前`zjs-dev`都输出
> `1 0 / 12 3 / 1 0`和`10 10`，测试已改为该reference结果。尚未重跑
> full test262/ReleaseSafe/OOM injection，也没有封闭下述destructuring child/cpool源码顺序红灯；因此当前仍不是compiler exact或可合入结论。
>
> **第五次QuickJS反向调用点复核（历史快照；状态与裁决均受上方第六次复核覆盖）**：
> 1. `M-BODY-SCOPE-IDENTITY`的identity部分已经落地：root script/module/direct/indirect eval、block/concise arrow、普通函数和
>    generated default constructor都有真实`body_scope`节点；synthetic `<class_fields_init>` aggregator仍按QuickJS保持scope0。
>    body `enter_scope`事件与hoist消费仍未迁移，不能把identity完成写成body anchor完成。
> 2. `M-DEFINE-VAR-CORE`算法与non-pattern ordinary producer已经落地。`WITH/LET/CONST/FUNCTION/NEW_FUNCTION/CATCH/VAR`共享
>    一个scope-collision owner；function var以parser期`scope_next`保留声明scope；GLOBAL/MODULE、DIRECT、INDIRECT四类eval的
>    `is_global_var`和lexical carrier已按`js_parse_program/define_var`重新区分。simple catch与classic/for-in/of不再做future-source scan，
>    它们的冲突完全由真实scope链裁决。module default expression/class的LET与export entry已移到ClassTail/表达式之后，匿名default
>    function的GlobalVar也移到child构造之后。
> 3. 仍未封闭的声明owner只剩明确边界：`BlockScopeDecls`、switch全case scanner和pattern裸`addScopeVar/addGlobalVar`属于
>    destructuring双遍历；`remainingBlockHasDirectFunctionDeclarationName(arguments)`属于implicit-arguments/final lookup债务；
>    TS enum/namespace与using是产品扩展；`class_static_this`和过早`<class_fields_init>`属于W1d。private/pseudo rows是QuickJS本来就不走
>    `define_var`的低层边界，不能为了“调用点归零”错误迁入core。反查`quickjs.c:36838-36870`等`add_var` callsite还补出两个必须明确保留的边界：parameter-expression
>    scope结束时把仅存在于argument environment的名字复制为scope0 row，以及script/eval的`<ret>` completion slot；candidate这两处已按
>    raw `add_var`身份实现。相反，当前复制finally为每个出口创建`__finally_ret_N` row，不等于`quickjs.c:29503-29538`共享finally里唯一一次
>    `add_var(JS_ATOM__ret_)`，已补入`M-FINALLY-SINGLE-BODY`出口。
> 4. 新补出的关键构造阶段差异是**函数声明carrier时机**：`quickjs.c:36567-36616,36958-37055`显示body/global/module statement先完整解析child，再给body local/arg写
>    `func_pool_idx`或追加GlobalVar；block function只在child前追加lexical FunctionDecl，Annex-B outer var在child后追加/复用。当前zjs为满足
>    全树staging，在child前就建立body/global/Annex-B outer carrier。它与`M-FINALIZER-PRECHILD + M-BODY-HOIST-ANCHOR`强耦合，必须在
>    current-before-children finalizer可用时原子迁移，不能再局部提前/延后一个row制造第三种顺序。anonymous default function/class当前仍通过
>    expression+post-hoist adapter模拟QuickJS的export-aware statement producer，也在该原子checkpoint改成同一producer。这里不能简化成
>    “所有检查后置”：module-eval function对已有同scope GlobalVar的检查、block lexical `define_var(FUNCTION)`以及Annex-B eligibility都仍在
>    child前；只把QuickJS确实在child完成后执行的outer/body/global carrier commit及其错误/OOM时序后置。
> 5. “test262/规范优于pinned QuickJS”的三个旧reference exception已取消。body同名`var + eval`已改回QuickJS的`undefined`；ordinary
>    descendant direct eval改写named-function self binding以及simple-catch同名eval `var`仍是当前红灯，必须按pinned QuickJS对齐。
>    test262差异只记录为reference已知行为，不再授权optimization分支保留另一套语义；若未来要做spec模式，必须另立产品决策且不得称为QJS对齐。
> 6. 当前收口顺序固定为：先关本checkpoint及gate；随后`M-LVALUE-PROVENANCE-CORE → M-PARSER-CONTROL-CLEANUP →
>    [M-DSTR-SOURCE-ORDER → M-DEFINE-VAR-CLOSE → M-DSTR-STACK]不可拆checkpoint → M-FINALLY-SINGLE-BODY → M-SCOPE-EVENT-PRODUCERS →
>    M-DERIVED-THIS-CANONICAL → (M-FINALIZER-PRECHILD + M-BODY-HOIST-ANCHOR + M-SCOPE-CLOSE-LOWERING)`。不再穿插feature fast path。
>
> 下方“第四次/第三次复核”保留发现过程与源码证据；其中“body identity尚未建立”“simple catch/for scanner仍在”等状态句已被本快照取代。
>
> **第四次scope全调用点复核补正**：`quickjs.c:24106-24169`的`push_scope/pop_scope/close_scopes`及其全部
> parser callsite已逐项映射。当前candidate已经补上if wrapper、classic-for无条件head、for-in/of无条件head、with enter、
> catch binding→wrapper→ordinary body以及class-name/private两层scope；所有`scopes[].first` exact-scope consumer也都在
> inherited tail遇到不同`scope_level`时停止。仍有三个不能藏进“已对齐”的缺口：第一，普通block-bodied function虽已有
> `body_scope`节点，却没有发QuickJS唯一的body `enter_scope`；root program/eval、concise arrow与default constructor又连
> body节点都不完整。第二，QuickJS的synthetic `<class_fields_init>` aggregator本来就是scope0、**没有**普通body push；只有
> parsed static-block child有body scope，而aggregator调用它时另push/pop一个wrapper scope，不能把“所有FunctionDef都push body”
> 当作规则。第三，TypeScript namespace是zjs产品扩展，当前另建无event的scope；它必须单列extension policy，不能计入QJS core exact。
> 此外`<class_fields_init>` lexical row在QuickJS解析完class elements后才由`define_var(CONST)`追加，candidate仍在进入private scope后
> 提前追加；该append顺序与static child/wrapper一起留给class initializer机制收口，不能只凭parent scope正确就冻结VarDef index。
>
> 2026-07-20第三次逐段核对以`define_var → get_lvalue/put_lvalue → js_create_function/resolve_variables`
> 为主链。最新slice已经删除`predeclareFunctionBodyVars/DirectEvalReferenceScan/predeclareVarDeclarators`与
> `needs_dynamic_lvalue_refs`，按源码正式parse恢复`let a; var b`顺序并阻断nested arrow/class method的`var`泄漏；
> direct eval只在正式遇到call时标`has_eval_call`，完整FunctionDef建成后再由`add_eval_variables`捕获。此前三个assignment/
> arguments测试的旧stdout并非QuickJS行为，已用pinned qjs重新定oracle；不能为保留旧测试而恢复pre-scan或parser-time dynamic ref。
> ordinary block/function body也已拆开：directive只在program/function body消费，空普通block不建scope；generic for-in/of
> LHS已按QJS label布局只正式parse一次，iterable先运行、next value经bottom-stack put回到target。
>
> 这次复核同时发现，余下工作不能从“删四个forward scanner”直接开始。QuickJS的`define_var`是声明语义的唯一owner：
> LET/CONST/FUNCTION当前scope冲突、catch `scope+2`特例、`find_var_in_child_scope`、VAR对可见lexical链的冲突、
> parameter/global/eval分支都在同一入口裁决。第三次复核时的candidate仍以`BlockScopeDecls`平行账本、switch/catch/for/arguments扫描器和散落的
> `findCurrentScopeVar/registerBlock*`共同决定结果。必须在真实scope topology/body identity上建立`M-DEFINE-VAR-CORE`，先迁non-pattern producer；
> destructuring恢复单遍后再由`M-DEFINE-VAR-CLOSE`让pattern/catch/for-head回到同一入口并删账本与扫描器，否则只是把已有语义补丁拆掉。
> 其更底层的parser-scope表示也必须一并对齐：QuickJS `push_scope`让新`scopes[scope].first`继承当前可见`scope_first`，
> lexical `add_scope_var`再prepend；function-scoped `var`本身保持`scope_level=0`，但正式parse期间暂以`scope_next=current scope`
> 记录声明来源，供`find_var_in_child_scope`检查，`js_create_function`才破坏性重建最终链。当时zjs的`appendScope(first=-1)`与
> same-scope list假设正是forward scanner存在的结构原因。该阶段不得新增`origin_scope`或第二scope graph来绕过这一双阶段契约。
> scope callsite对照还发现lexical for-in/of的identity差异：QuickJS只push一个head scope，iterable求值后与body末尾分别
> `close_scopes`，循环结束才pop；zjs却在iterable后pop/push并重新`addScopeVar`，制造第二scope/VarDef。catch也少了
> binding scope与ordinary body之间的wrapper scope。故`defineVar`之前新增`M-DECL-SCOPE-TOPOLOGY`：先恢复声明所依赖的
> scope节点/父链、单一loop binding与可复用`closeScopes` primitive；这些identity/core项已在第五次复核前落地，后面的M-SCOPE-EVENT-PRODUCERS完成全部abrupt edge，
> current-before-children finalizer后再由M-SCOPE-CLOSE-LOWERING完成captured-cell detach和future-hint退场。前者不是for/catch fast path，而是后两者的parser-time基础。
>
> 第二个缺口是统一phase-1 lvalue provenance。QuickJS由emitter维护`last_opcode_pos`，完整operand后让
> `get_lvalue/put_lvalue`改写最后一条`scope_get_var/get_field/get_array_el/get_super_value/private`；label、comma等边界显式
> invalidate。`with`只在scope链放`_with_` VarDef，identifier仍发普通`scope_get_var`，需要method receiver时才改
> `scope_get_ref`，最终with/eval/local/global选择交resolver。zjs仍有`peekParenthesizedBareIdent`、parser-time
> `active_with_atom`与若干tail/source lookahead，故generic-for局部修复尚不能代表assignment/update/delete/typeof/destructuring
> 已共享同一机制。第六次复核进一步把private完整producer移到W1d；CORE只迁普通variant、simple var和call consumer。
> 该缺口单列`M-LVALUE-PROVENANCE-CORE`，禁止用新的AST/source shape classifier替代。
>
> 继续枚举所有`ParserSnapshot`后又补出更早的topology泄漏：destructuring declaration/assignment会先用
> `parseDestructuringPattern(..., null)`完整试解析，再只回滚code/atom/lexer，**不会回滚child/cpool/temp local/VarDef**，
> 随后正式解析第二次。最小probe
> `function f(){let a; ({a=function x(){}}={}); function y(){}; return a}`中，zjs实际构造`x,x,y`三个child，
> `f`为`var_count=3,cpool=3`；pinned QJS只构造`x,y`，locals为`a,y`、cpool为2。参数路径虽已把pattern预读
> 改成token-only scan，仍把外层default initializer提前正式parse：
> `function f({a=function x(){}}=function d(){}){}`的QJS child/cpool顺序为`x,d`，zjs却为`d,x`。
> 这证明只删重复child仍不够；必须像QJS一样按源码顺序构造pattern/default/RHS，再用label/operand stack让RHS在运行时先求值。
> 非destructuring的generic for-in/of LHS已作为首个消费者改成QJS label+bottom-stack put，原来的
> `parseLhsExpr→truncate→LexerReplayPoint→parseLhsExpr`与`value_loc`路径已删除，并锁定`(a).p`、`a["p"]`、
> computed child只构造一次及iterable-before-target顺序。它是`M-LVALUE-PROVENANCE-CORE`的先行证据，不是保留其他shape/replay的理由。
> 同一类partial transaction在destructuring member target里更严重：
> `let a={}; ({x:[function f(){}][0]}={x:1});`当前zjs构造四份`f` child artifact，pinned QJS只构造一份；
> `arrayLiteralPatternCandidateIsMemberTarget`先正式parse array literal，再由后续shape/pattern replay重复消费源码。另有
> `collectParamPatternDupNames/collectArrowPatternBindingNamesSnapshot`为parameter、arrow和catch另跑一套binding-name parser，
> 而QJS在正式destructuring traversal遇到每个binding时直接做duplicate check。前者是明确topology错误，后者即使最终表相同也增加
> atom/allocation/OOM顺序，均不能以“只是lookahead”保留。
> 源码还明写
> `peekParenthesizedBareIdent`“qjs has no such shortcut”，return-comma会重扫余下表达式，所有普通block又先全文扫描
> `using`。QJS的destructuring只用`js_parse_skip_parens_token`作不改topology的grammar判别，随后
> `js_parse_destructuring_element`一次完成，并以operand stack/iterator catch-offset承载状态。故六个dstr helper对应的
> source-order与stack transport必须提前到compiler finalizer之前；否则额外temp local、伪callable和重复/乱序child仍会改变全部后续index。
> 八个`using` helper属于pinned QJS没有的产品特性：它的全块预扫要在M-PARSER-CONTROL-CLEANUP消失，但typed-control迁移单列W1b2.6，
> 不得反过来阻塞ordinary/core finalizer，只需在realm callable inventory前完成。
>
> 同一轮还确认zjs先扫描`try`是否有`finally`，再从lexer snapshot为throw/return/break/continue/normal路径重复解析并复制
> finally body；QJS只解析一次，以`gosub/ret`共享。普通block/body差异已在最新slice修正并以focused tests锁住，不能再列作
> 未完成项。最后，zjs finalizer还无条件capture derived-constructor `this`以维持`frame.this_value`双权威；QJS无child/eval capture的
> derived constructor `var_ref_count`为0。这些都不是Zig限制。
>
> 第四次复核把依赖顺序进一步修正为：M-DECL-SCOPE-TOPOLOGY → **M-BODY-SCOPE-IDENTITY** →
> **M-DEFINE-VAR-CORE** → M-LVALUE-PROVENANCE-CORE → M-PARSER-CONTROL-CLEANUP → M-DSTR-SOURCE-ORDER →
> **M-DEFINE-VAR-CLOSE** → M-DSTR-STACK → M-FINALLY-SINGLE-BODY → **M-SCOPE-EVENT-PRODUCERS** →
> M-DERIVED-THIS-CANONICAL → M-FINALIZER-PRECHILD → M-BODY-HOIST-ANCHOR → **M-SCOPE-CLOSE-LOWERING**。
> BODY-SCOPE-IDENTITY必须先于`define_var`，因为QuickJS的root/eval `body_scope=1`直接参与parameter/global/eval声明裁决；
> 但它与DEFINE-VAR-CORE是同一个parser checkpoint：candidate仍有若干`scope_level==0`顶层判断，不能先单独合入scope1再让
> global/module声明暂时被当作block local。
> DEFINE必须拆core/close，因为当前destructuring完整试解析会产生第二套binding，不能在保留双parse时假装所有producer已经共享唯一owner；
> scope event也必须拆parser producer/final lowering，因为finally复制退场后才能建立唯一控制边，且`close_loc`必须在current-before-children
> finalizer完成真实capture后由`resolve_variables`消费。最后四项是同一个QJS finalize checkpoint，不得分别拿中间双表示做性能归因或合入结论。
> 它们全部先于Realm/FB/layout和新的性能归因。root program、concise arrow与generated constructor都必须建立真实body identity/event；
> synthetic `<class_fields_init>` aggregator则明确保持scope0无body event。sloppy Annex-B仍须先append lexical
> FunctionDecl、解析child后再append/复用外层`var`。W1b2的row schema/lookup与closure identity规则可以冻结，
> 但在单遍declaration producer收口前，具体VarDef顺序、`var_idx`、open-binding index与final bytecode不能再标成exact。
> 最新逐段对照还补出 hidden trailing return sentinel、finalize 时重复 dup/copy、debug bytes 错误 packing 假设、
> pc2line起始坐标被另存字段、first-instantiation realm mutation 与 module/class staging 边界；下文已把它们拆成
> 独立机制；再复核`js_closure2`与当前cached view后，又补出owned FB attach的refcount往返、arguments-rescue
> adapter、leaf-call派生事实以及fixture raw construction边界。同时纠正了“full-debug都是128B就等于header exact”的误判：QJS align8、zjs align16，且QJS
> strip-debug header只有`0x60`，W1d前zjs仍有side facts，
> 所以core pack与total exact-close必须分开。最新 realm 深挖还确认：QJS 的 realm owner 不只在 FB，
> `JS_CLASS_C_FUNCTION`、AUTOINIT property、job entry 与 FinalizationRegistry 也各自 `JS_DupContext`，而
> `JS_CLASS_C_FUNCTION_DATA`明确沿caller；zjs 的
> `eval_function`/class prototype cache 仍在共享 `JSContext`，random 与 module registry 仍在 runtime，pending job
> 又不携带 enqueue realm。因而不能再以“把 global header 提前写进 FB”冒充 context 对齐，也不能按旧
> W1b2→direct-FB→pack→root 的顺序直接开工。
> 最后一轮`JSObject` union、全部`JS_DupContext` callsite与zjs producer/reader扫描又确认：QuickJS的ordinary、Promise、
> RegExp、arguments、typed-array、generator、bound/proxy等对象都没有通用realm字段；zjs当前却有20处
> `realm_global_ptr`声明/视图，并让普通namespace/prototype替AUTOINIT传realm。这是待退场的补偿模型，不是应升级为
> 20个RealmRef owner的设计。同时`borrowed_reference_holders`还服务真实weak edges，收口目标是删除realm参与和对应
> function/generator holder开销，而不是误删WeakRef/WeakMap/FinalizationRegistry的弱引用机制。继续按reader扫描又找到一组
> 更隐蔽且可观察的补偿：alternate-realm `Function`上会定义十个可写/可枚举/可配置的`__realm_*_proto`字符串属性，
> dynamic Function再复制这些属性；eval/RegExp getter、Object primitive wrapper与TypedArray backing buffer还分别依赖
> `tagRealm*`、`FunctionRarePayload.primitive_prototypes/realm_type_error_constructor`及ordinary payload中的
> `typed_array_array_buffer_prototype`。pinned QuickJS没有这些object/property side channel，全部来源都可由active
> C_FUNCTION/FB RealmContext、`JS_GetFunctionRealm`与`class_proto/native_error_proto/eval_obj`直接表达，故W1b3e已扩成
> non-carrier compensation退场，而不只是borrowed pointer cleanup。最后，`JS_SetPropertyFunctionList`复核确认QuickJS只有
> C function/string/object三类generic property走AUTOINIT；CGETSET、数值常量与alias都在安装期完成，alias源码还明确说明
> 不可安全地做AUTOINIT。W1b3d1因此先裁决lazy domain并删除alias shared-cache补偿，再处理realm owner/error/global VARREF。
> 最终按property union继续下钻又补出两个不能省略的机制事实：AUTOINIT第二word是entry/null/module的direct opaque pointer，
> 不是runtime ID；MODULE_NS materialize也可能把resolver得到的既有export VarRef直接发布，而非普通data snapshot。前者归W1b3d1
> 负向验收，后者只在W1b3d1固定typed协议、由W1e随per-realm module owner和namespace producer真正接入。
> 继续按**传递性强根与实际callback数据流**而非`realm`字段名复核，又补出七项此前遗漏。第一，`JSRuntime.internal_destructuring_helpers`
> runtime-wide缓存14个无name/prototype/realm的C function object；其中六个解构helper把
> `special_object + call`当作内部控制协议，而QuickJS直接使用`for_of_next/iterator_close/copy_data_properties`等
> bytecode栈协议，另外八个`using` helper是reference没有的product extension，也不应伪装成JS callable。第二，
> binding边界同时有两种相反的lifetime错误：每个`MethodRuntime`在runtime external-record表中持有realm prototype的`JSValueHandle`，
> 即使字段名没有realm，仍会把alternate RealmContext钉到runtime teardown；公开且可复制的`JSObject.Binding`却直接保存
> `prototype: *Object`，没有owner/deinit/lifetime contract，realm释放后会悬空。W1b3a把后者收成ctx-lifetime borrowed
> `{RealmContext,class_id}` view并提供显式RealmRef owner variant给真正escape，W1b3b让两种method/new/payload lookup都读live callee/binding
> RealmContext的class slot，不再保存prototype pointer/value。第三，公开`JSValueHandle`本身可经C_FUNCTION/FB传递性保活realm，
> runtime destroy不能清空root-slot表后留下外部handle悬空。第四，两种`DynamicImport*State.load`都丢弃job/callback传入的`ctx`，
> 转而使用state中的裸`context`；QuickJS `JSJobEntry` own enqueue context，`js_dynamic_import_job(ctx, ...)`再把同一ctx传给
> Runtime module loader。W1b2.5先恢复destructuring单遍/stack边界，W1b2.6再移除`using`伪callable；W1b3b随后让binding method从稳定callee
> RealmContext查class prototype并删除内部persistent handle；W1b3a的teardown出口同时要求
> 公开strong/weak/local handle slot与外部RealmRef均已按契约释放；W1b3d2则必须让dynamic-import handler使用entry RealmContext，
> state只承载有明确lifetime的host policy/continuation数据，Runtime loader hook的最终placement随W1e对齐。第五，
> `runtime.EventLoop`保存裸binding wrapper，并在整个HostEventLoop vtable中把`*core.JSContext`反向`@ptrCast`成外层wrapper；同一布局
> 假设还散落在`run_test262.wrapExternal*`、`src/tests/exec.zig` harness与`src/core/string_view.zig`测试。wrapper拆分后这些cast都会失效。
> 同一callback数据流还暴露出`ExternalCall.ctx`与`global`是两个可独立漂移的authority，而QuickJS callback只有ctx；W1b3b必须把
> ctx/global/global-slots作为同一RealmContext view原子切换，兼容`global`字段只作alias，不能继续fallback `functionRealmGlobalPtr`。
> W1b3a让EventLoop成为命名host RealmRef owner、只保存稳定core RealmContext并让vtable直接消费它，deinit先detach/释放callbacks再free ref；
> 该额外owner是为了保持zjs现有`runUntilIdle(self)`自包含host API，不是QuickJS或Zig限制，必须单独登记。第六，全局`atomics_waiters`中的
> waitAsync heap node同时持Promise与裸`ctx`，notify线程还在
> mutex内直接分配/修改JS heap并用`catch {}`丢弃settle失败；pinned QuickJS只有不持context的同步stack waiter，根本没有waitAsync。
> 这是zjs reference-version product extension：W1b3a先把node改成命名RealmRef owner，W1b3d2再让foreign-thread/timeout只发布typed
> host completion，由owner runtime安全点按该realm进入统一job FIFO；禁止跨线程执行JS、丢失败或让Runtime静默清节点。第七，runtime
> plugin的`InstalledPlugin.host_classes[].prototype: JSValue`由external-record/plugin refcount持到Runtime teardown，绕过已经存在的Context
> `class_prototypes`；QuickJS由process-global `JS_NewClassID`分配稳定id、由每个Runtime的`JS_NewClass1`注册definition并先给全部live Context扩出null slot，随后
> `JS_SetClassProto/JS_NewObjectClass`才精确把prototype放在/取自调用Context。W1b3a因此补齐all-live/future slot capacity invariant，plugin
> HostClass只留runtime metadata/class id，prototype仅安装到construction RealmContext slot；opaque object创建按callback ctx取slot，之后只由
> shape保活prototype，不给InstalledPlugin保留JSValue root、也不给opaque wrapper补RealmRef。七项都记correctness/ownership收益零。
>
> 本次再按`JS_NewContextRaw/JS_MarkContext/mark_children/JS_FreeContext`、class API与全部job enqueue/dequeue点逐段复核，补出五个机制级缺口。
> 第一，QuickJS的`JSContext`同时有`JSGCObjectHeader`和独立`context_list` link；前者进入trial-decref的child traversal，后者服务
> dynamic class扩槽、memory/diagnostic枚举，以及Object.prototype新增索引属性时定位对应realm并清除
> `Array.prototype.is_std_array_prototype`。zjs当前`JSContext`只注册`root_provider`，而`Runtime.traceRoots`并不被
> `destroyRuntimeCyclesWithValueRoots`消费；仅把现有`traceRoots`改名或给struct加refcount，仍无法回收
> `Context→global/prototype→C_FUNCTION/AUTOINIT→Context`。W1b3a因此必须增加真正的RealmContext GC kind、独立runtime context list、
> typed realm child edge以及所有collector switch/teardown；root-provider若为host tracer contract保留，也只是borrowed enumeration，绝不成为
> GC child traversal或base owner。第二，`JS_NewClassID`的ID namespace是process-global，definition registration才属于各Runtime；当前zjs
> `Table.next_dynamic_id`把两层合并，必须默认对齐或登记成明确的plugin产品偏离。第三，`JS_NewClass1`只负责all-live Context capacity与Runtime
> class record，`JS_SetClassProto`另行**consume**传入prototype，`JS_GetClassProto`才返回dup；不能把low-level QJS步骤与zjs plugin安装事务混成一个
> “class+prototype原子API”。第四，QuickJS runtime FIFO每次`JS_ExecutePendingJob`只dequeue一个entry，异常即返回并保留后续FIFO；当前zjs generic
> `Queue.runAll`却连续执行并释放result，公开`job.drain`还忽略budget并伪造count。W1b3d2除统一queue/realm外，还必须恢复run-one/status/exception
> cleanup transaction与真实public adapter，不能只把裸ctx换成RealmRef。第五，Promise reaction/thenable/dynamic-import的pinned内部调用点都忽略
> `JS_EnqueueJob`失败，FinalizationRegistry还显式使用no-exception enqueue；zjs统一queue时不得复制silent drop，而要保留/推广pre-reserve→no-fail commit或
> pending retry，并把这项偏离登记为GUIDE safety contract。
>
> 本轮查漏又把上述结论收紧到具体边界：`JS_SetClassProto` consume任意JSValue，object creation才把非object按null proto处理；
> Array guard只在prototype真实改变并commit后失效，同值/失败设置不清。Realm构造拆成GC header `.constructing`与context-list `.live`
> 两个publication point，五个QJS initial shape默认改为RealmContext direct Shape owner而非隐藏template Object；RootProvider只保留
> diagnostic/真正host-owned external edge。zjs plugin unload在slot→definition→DSO顺序之外还要用execution pin保证callback返回前不close。
> job侧则区分dynamic-import promise暴露前/后的OOM事务，并保留Promise `state/result→rejection tracker→旧reaction enqueue`的可重入phase；
> 预制资源不能把reference的可观察顺序“原子化”掉。
>
> 最后一轮按最新`recordPtr`与deferred cleanup代码反查QuickJS create/free顺序，又补出三个窗口：class-table pointer不得跨GC/allocation/callback，
> dynamic definition需generation/owner pin；Array/Object prototype的tagged-small property attempt在后续shape OOM前已经清guard；复制DSO callback pointer的
> deferred node本身也是installation/definition owner，不能在queue尚未执行时close。三项均先修correctness/lifetime，既不恢复88B record copy，也不计性能收益。

## 0. 目标、优先级与边界

本计划优化的是**引擎机制**，不是某个语言特性或 benchmark：

1. **第一优先：忠实采用 QuickJS 的通用机制。** 先逐段确认 QuickJS 的数据流、
   所有权、异常顺序、栈形态和热汇编，再讨论 zjs 改动。
2. **第二优先：因 Zig/LLVM/ABI/所有权模型限制而做的等价变体。** 这类偏离必须先写明
   无法直接镜像的具体限制，并保留语义等价证明和反汇编证据。
3. **最低优先：QuickJS 没有的 zjs 超集优化。** 只有当 QuickJS 机制已对齐、残差仍被
   定量证明，且偏离不是 benchmark 特化时才进入裁决。

本计划不再保留“规范/test262优于pinned QuickJS”的隐式语义例外。test262差异仍是必须记录的兼容性证据，
但在本优化分支上默认行为、构造顺序和异常顺序都以固定commit的QuickJS为准。只有可复核的Zig/LLVM/ABI/
内存安全限制允许等价实现差异；若产品将来需要spec模式或修正reference缺陷，必须另立显式产品决策、单独测试与
性能基线，不能混进QJS alignment或用它阻止通用机制收口。

“Zig 限制”必须是可复核的编译器、calling convention、布局、错误传播或内存安全约束；
代码写起来不方便、现有结构难改、或某个 benchmark 需要更快，都不算限制。resident Machine、
internal-record table、lazy property storage 和 parser 提前发 short opcode 是需要逐项审计的 zjs
架构选择，不自动等于 Zig 限制。tail-call dispatch 需要更精确地分类：历史
comptime-delete 二分已证明单体 Zig dispatcher 会引入约 3,504 bytes 的加性 spill，而 224-arm
tailcall 与 labeled-switch 的实测基本等价，两者的 next-dispatch 也已与 qjs computed-goto 处在同一量级。
这些数据的 owning 事实文档是 [CALL-MACHINERY-FAITHFUL-FRONTIER.md](CALL-MACHINERY-FAITHFUL-FRONTIER.md)。
因此当前 tailcall 形态是有代码生成证据的 Zig/LLVM 等价适配，整体 dispatch 战役冻结；
Zig 0.16 缺少 `preserve_none` 既不是这个结论的唯一理由，也不能用来免于逐 opcode 对照。
冷 handler 中单个 opcode family 的 pc/sp 发布与 residency 仍是可审计的执行差异，但不延伸成
“重写整个 dispatcher”。

禁止：

- 按脚本名、输入、pattern、literal、循环次数或 Zoo case 分支；
- 只为验收脚本融合函数体、硬编码输出或缩窄语义；
- 在 QuickJS 通用路径尚未对齐前新增 zjs-only fast path；
- 把“少了 instructions”直接等同于“更快”；
- 把已失败的历史刀换名后原样重跑；
- 一个候选同时修改两个机制，再用总结果反推各自收益；
- 新增仅为阻止 LLVM 重写或塑造单一热布局的 inline asm、opaque/volatile barrier、padding 或空逻辑；
  真实 ABI/硬件边界必须有独立机制理由、可观察契约和跨消费者证据。

QuickJS 自身存在的 invariant-based fast path 可以忠实镜像；它必须服务同一类运行时不变量，
而不是服务某个 benchmark。已有且正确、同时证明优于 qjs 的 zjs 机制也不为“代码长得一样”
而主动退化；此时要记录为什么它仍满足语义和机制边界。

### 0.1 当前代码的 no-cheating 前置审计

最新调用图复核确认，当前 main 继承了若干**绕过通用 parser/eval/closure 机制的源码特判**。
它们不是本 P1 候选新增；本候选已逐个给出 active caller、最小反例和 qjs 对照后删除，尚未合入
main。删除这些 bypass 的成本与收益全部记 correctness，不进入后续 construction PMU 归因：

| 当前实现 | 已确认事实 | 裁决 |
|---|---|---|
| `isWhitespaceSeparatedNumericScript` | parser 拒绝后把空白分隔数字源码当 `undefined`；`qjs -e '1 2'` 抛 `SyntaxError` | **本候选已删除**；Engine 与 CLI 红灯先失败、删除后通过，qjs/zjs 均以非零状态抛 `SyntaxError`。这是 correctness 修复，收益记零 |
| `simpleEvalRegExpLiteral`、`evalSimpleCallerExpression`、`simpleEvalStringLiteral` | 在 generic eval parse/root closure 前解释特定源码；caller helper 还把 named-function assignment completion 错成异常/`undefined` | **本候选已删除**；exact/terminated RegExp、string、`this`、sloppy/strict named assignment 均由 generic parser/VM 处理并与 qjs 对齐，收益记零 |
| `sourceHasOnlyStrictFlag`、`sourceHasUseStrictDirective` | engine 对源码/frontmatter 再做字符串扫描；例如注释中的 `flags: [onlyStrict]` 被误当 strict | **本候选已删除**；host/runner option 与 parser directive prologue 是唯一真源，frontmatter 注释不改变 engine strictness |
| `canReturnUndefinedWithoutVm` | 空/无副作用脚本按最终字节码形状跳过 VM，qjs 没有对应 entry bypass | **本候选已删除**；empty/comment/no-effect 统一进入 root runner。real root function object 仍属于 P1b，不再与 bypass 删除绑定 |
| `nativeTypedArraySubclassBase` | `Function(body)` 按 `class … extends TypedArray` 源码片段把**整个 body**替换为 `return <base>`；qjs 得到 `false X`，旧 zjs 得到 `true Uint8Array` 且吞掉 body side effect | **本候选已删除**；现有真实 class/Reflect.construct/typed-array subclass 机制已足够，Dynamic Function 现保留原 body，identity/name/instance/side-effect 与 qjs 一致 |
| `parameterSourceContainsAwait`、`parameterInitializerContainsAwait`、`arrowBlockStartsUseStrict`、`defaultInitializerHitsParameterTdz` | 在统一 grammar/scope resolution 前扫描 token/source，或用永远 TDZ 的匿名 local 伪造参数错误；合法 `({await:1}).await`、nested async function 被误拒绝 | **本候选已删除**；AwaitExpression 在 parser production 处裁决，directive prologue 解析后裁决 strict，parameter `enter_scope` + 最终名字解析提供真实 TDZ cell |

源码中特化 helper 的**存在本身**不等于 active cheating。本次 reachability 检查显示 regexp 中若干
literal/pattern 命名 helper 当前无 caller；它们先作为 dead-code cleanup 候选记录，不据此否定
`cb41f7fe` 已验证的 generic split/match 路径。以后 no-cheating 审计必须同时给出 caller/reachability、
触发样例和 qjs 对照，不能只凭函数名定罪。

## 1. 当前事实基线

### 1.1 已完成，不再列为未来工作

以下项目在旧路线图创建前或最新 regexp 战役中已经落地：

- shape transition 已有 cache hit / shared clone / `rc==1` in-place 三臂的拓扑；但 cache key 和
  property-storage reconciliation 尚未完全对齐，不再重做三臂，只继续审计其命中资格；
- Array.push 已在 `ToObject` 前走 qjs 式 direct dense-array arm，并直接维护 count/length；
- `resolve_labels` 及相关 finalize 已实现 dup+put→set、逻辑链、nullish/typeof、constant branch、
  push-neg、return-undef、dead code、inc/add-loc 等 matcher/fuse；完整 coverage 仍由 M-EMIT
  的最终字节码矩阵封账；
- 内建 Array/Map/Set/generator iterator 已有与 `JS_IteratorNext2` 对应的 result-object-free
  路径；
- 默认 64 位 16-byte JSValue、inline dup/free、zero-ref queue，以及 `[]*VarRef` + `pvalue`
  open/closed cell 表示已经按 qjs 落地；
- 普通对象的 `get_field/get_field2` 已有 qjs `GET_FIELD_INLINE` 式 shape-hash + prototype data walk；
  这不等于后续 method call 或 zjs fallback transport 已经对齐；
- regexp literal 编译、RegExp payload、result template、native cproto dispatch，以及
  split/match 的 realm/species/ownership 路径已在 `cb41f7fe` 对齐。

后续 profile 可以证明这些机制仍有残差，但不得再以“缺少该机制”为前提开刀。

### 1.2 2026-07-19 当前 zjs/qjs 基线测量

环境：Cortex-X925 CPU19、ReleaseFast、`taskset -c 19`、`armv8_pmuv3_1`，9 轮交错；
下表用 paired 样本的中位比，不使用 best-of-min 作为主结论。

| 症状探针 | zjs/qjs cycles | zjs/qjs instructions | 结论边界 |
|---|---:|---:|---|
| `for-of-bytecode-next-zero-arg-2m` | 1.771x | 1.560x | 复合了 iterator、cell、属性写和算术 |
| `array-push-one-arg-5m` | 1.541x | 1.467x | 不能直接归因为元素增长 |
| `object-literal-var-1m` | 1.440x | 1.619x | allocation + property publish 复合 |
| `allocation-empty-object-2m` | 1.149x | 1.356x | object lifecycle 的直接症状 |

M-CELL 的独立 direct probes 已进一步把读、写、set 和复合更新拆开；同样使用 CPU19、paired
median。下表来自历史冻结件
`5da80d18ca74466513be780c31df3662358c184c3508904aacd3f7463c9894fc`，只保留排序价值：

| cell direct probe | zjs/qjs cycles | zjs/qjs instructions | 当前结论 |
|---|---:|---:|---|
| short plain read | 0.897x | 0.874x | zjs 已快于 qjs；不是当前收益面 |
| generic plain read | 0.899x | 0.884x | 同上，不能仅因源码多一个分支就开刀 |
| short plain put | 1.787x | 1.661x | 旧 baseline 的最大 direct 写差距；P1a/P1b 构造对齐后重测，才裁决 P1c |
| short set | 1.349x | 1.293x | 与 put 分开，作为第二候选 |
| short post-inc | 2.276x | 1.953x | 混入 read/number/update/lowering，只作后续 consumer |

已做过一次“plain read 与 checked read 分 handler”的干净候选，并在独立重建后跑 15 轮 paired
复核。它删除了 plain read 的 TDZ compare，instructions 如预期下降约 1.26%，但没有 cycles 收益，
同时无关 put/set controls 超过 +1%：

| 既有失败候选 | candidate/baseline cycles | candidate/baseline instructions |
|---|---:|---:|
| short read | 0.99998x | 0.98728x |
| generic read | 0.99939x | 0.98740x |
| short put control | 1.01219x | 0.99993x |
| short set control | 1.01191x | 1.00004x |
| post-inc control | 0.99792x | 0.99498x |

按 §8 该候选已回退，保留最终 opcode 契约测试。结论不是“分流机制错误”，而是这次 read-only
布局变化没有转化为 cycles，且污染了更重要的 write controls；没有新的源码事实、handler-cluster
策略或工具链变化，不得换名重跑。当前先完成 P1a/P1b 构造对齐，重冻后 P1c 直接转向
plain put，再单独做 set。

这些数字只是本计划的最新快照。正式候选开始前，M0 必须把原始逐轮数据、二进制 hash、
命令和环境固化到当前工作项；计划文本不代替可审计的原始证据。

注意：上面 M-CELL 的机制排序和失败刀结论仍有效，但 `c034597c`、`936111c5` 以及当前 P1
构造候选都会改变 compiler/construction 状态；旧 zjs binary 不得继续充当 plain-put 候选的因果 baseline。

### 1.3 已确认的归因修正

1. `for-of-bytecode-next-zero-arg-2m.js` 在循环外创建并反复复用同一个 result 对象，
   因而不存在每轮 result 分配。zjs self-time 主要落在：
   `finishForOfNextResult` 17.15%、捕获 cell get/put 17.72%、post-update 11.47%、
   `op_for_of_next` 8.33%、result 属性写 7.12%、borrowed setup 6.67%。
2. for-of 差分结果为 zero-arg 1.772x、constant-result 1.423x、self-result 1.476x；
   普通零参 method control 仅 1.095x。generic continuation 与用户 `next()` 的 cell/property
   成本必须分开。
3. Array.push profile 中 field/method lookup、property helpers、call glue 和 length 远大于真正的
   append body；空数组 `pop()` 不增长元素却仍为 1.604x。当前要分别审计 shared property lookup
   与 native-call 机制，不能继续合成一个“push 成本”，也不是先改 capacity 算法。
4. object literal 当前热点仍包含 `adoptShapeForNewProperty`、object/shape create/destroy、
   root-shape lookup 和 MemoryAccount。因为 `rc==1` 臂已完成，必须先扣除空对象 lifecycle，
   再解释 property publish 残差。
5. “alloc-empty 在 07-08 曾为 0.96x”尚无同一入库脚本和原始数据可复核；该脚本到
   07-14 才入库。复现前只称“当前残差”，不称“已知回归”。

### 1.4 对 pinned QuickJS 实现的逐段复核

当前 checkout 在 Linux/aarch64 使用 `OPTIMIZE=1`、`SHORT_OPCODES=1`、`DIRECT_DISPATCH=1`
和 `CONFIG_STACK_CHECK`。这些编译期机制属于 reference 身份；只钉源码 commit 和 binary hash
还不够，M0 还要钉编译器、flags 和这些宏的有效值。

| 机制面 | QuickJS 实际实现 | 当前 zjs 结论 | 路线图动作 |
|---|---|---|---|
| call/dispatch | 单体 `JS_CallInternal`，computed-goto；bytecode call 递归进入新的 C frame，locals/stack 用 `alloca` | resident Machine + tail handlers + inline Entry 与 qjs 外形不同；但 3,504B spill 二分、224-arm A/B 和 next-dispatch 指令数已证明当前 dispatch 是 Zig/LLVM 下的等价适配 | 整体 dispatch 标记 DONE，不再全盘重开；只审计 qjs CASE-inline opcode 在 zjs 的冷/常驻位置，以及非 `.next` post-call continuation |
| generic iterator | `js_for_of_next → JS_IteratorNext → JS_IteratorNext2 → JS_Call`；generic result 依次读 `done`、ToBool、仅在 false 时读 `value`，最后 free result | `finishForOfNextResult` 的可观察顺序已基本相同；for-of 这类需要返回后继续作业的非 `.next` action 额外经 `return_action/payload` 和 cold continuation，普通 call 不经该路径 | 只将 post-call work 列入 M-RETURN-CONT；iterator 只是 direct consumer，不再成立 feature 刀 |
| captured cell / root eval | `JS_EvalFunctionInternal` 对 script/direct/indirect eval 一律先 `js_closure`，因此 root 也有真实 function object、最终 capture array 和自己的 `cur_func`；`js_closure2` 清零数组、eval pass1、one-pass cell，之后才装函数属性 | zjs 直接执行裸 `Bytecode`，entry frame 临时造 refs；direct eval 还把 outer function 当 `current_function_value`，并经 placeholder/copy/replace；nested capture 又晚于多个属性/adaptor | undefined-sentinel迁移已完成；新增顺序是realm carriers→non-carrier compensation-retire→显式terminator→canonical root FB→direct-FB consumer→GLOBAL selector→root/nested closure2，否则只是把旧补偿固化进对象 |
| binding resolution | `add_func_var` 用 `add_var` 建特殊 fallback，不挂 scope 链；const 取决于**定义函数** strict；sloppy `scope_put`→drop、`scope_make_ref`→临时对象引用；ordinary assignment由`scope_make_ref→with_make_ref/get_ref_value→put_ref_value`在RHS前固定reference，只有for/destructuring等直接`scope_put_var` consumer才降低到`with_put_var`。call在最后一条`scope_get_var`上改`scope_get_ref` | `dbe50d7d` 已补 exact `add_var`、strict metadata、parameter-env fallback、drop/dummy-ref；但历史`scope_no_dynamic_env_flag + selected_reference with_put_var`是parser提前选reference的补偿，且ordinary identifier仍由`active_with_atom`与下一个token决定`scope_get_ref` | named-function基础前置保持封账；M-LVALUE-PROVENANCE-CORE删除selected-reference补偿，让assignment只走make-ref/put-ref、call只在call点改写。QJS本来存在的resolver产物`with_get_ref/with_put_var`保留，不能把“最终有同名opcode”和非QJS selected mode混为一谈 |
| phase-1 reference/call provenance | `emit_op`发布opcode位置后写入同一DynBuf；写失败会永久poison本次compile，因此没有可恢复consumer能观察半状态。source/raw optional label不更新last-op；`get_lvalue/put_lvalue`消费最后getter与正式reference label；普通`var`在`need_var_reference`时也走同一路径；call/tagged-template在消费点改field/index/super/scope getter，optional call/delete直接读getter后的raw label。resolver的`optimize_scope_make_ref`只读该label slot的`pos` | 当前WIP同样在append前更新last-op，但zjs OOM是可返回/恢复的，atom/source/code三条fallible stream又未原子commit，故会暴露QJS不会继续消费的半状态；assignment/postfix还按`result_needed`换协议。simple var与旧pattern仍留下unpatched absolute-target `0`，`findGlobalRefPutTail`最多扫16条；optional chain另存bool、16项exit数组并全段识别signature；call仍读token/source-tail状态 | M-LVALUE-PROVENANCE-CORE以reserve/commit或完整rollback复现QJS“失败后不继续”的可观察保证，再迁simple var和全部ordinary reference/call consumer；普通路径不得读bounded tail scan。M-DSTR迁完最后legacy pattern producer后删除unpatched-target与scan。optional整链只用一个共享LabelSlot/LabelRef，不新增per-exit容器；source、atom与Nth-OOM是同一出口条件 |
| private binding/class initialization | 每个private声明先`add_private_class_field→add_scope_var`建立lexical+const VarDef并按field/method/getter/setter初始化；setter另有`<set>` companion。resolver按VarKind产生field access、brand check、getter/setter call或readonly throw。private field本身使用独立private symbol；只有method/accessor令instance/static侧`need_brand`，每侧至多一个共享brand | parser以`class_private_bound_names/class_private_elements`和constructor metadata传名；resolver还有bound-name atom fallback；runtime `initializeClassPrivateMethods`从home object逐descriptor复制到instance。当前半迁移把member改成`scope_get_private_field`后因声明槽不存在而报`ClosureVarNotFound` | CORE阶段回到既有private transport并只做负向不回退门禁；W1d以PRIVATE-BINDING/CLASS-INIT不可拆checkpoint迁声明、初始化、capture、VarKind、按需brand和class initializer，随后删除descriptor copy、name remap/side table与fallback。不得靠空VarDef或atom fallback让半套实现变绿 |
| named property read | `GET_FIELD_INLINE` 直接 `find_own_property`，沿 prototype walk；data hit dup，accessor/exotic/primitive 才进 `JS_GetPropertyInternal`；没有 IC | zjs ordinary data walk 已近似镜像，但 slow-object 顺序、null-prototype class fallback 和 tail transport 不同 | 从 native call 中拆出 M-PROPERTY-LOOKUP，独立测 lookup 与 fallback |
| native call | c-function object 直接保存 function union、cproto、magic、realm；`js_call_c_function` 建 native `JSStackFrame`、补可读缺参，再按 cproto switch | zjs function object 缓存 `InternalRecord*`，经 table/host-call transport；直接指针是等价候选，但不是 qjs 原布局。最新全仓扫描还确认`InternalRecord.prepared_call_ok`只有table写入、零reader，相关“VM prepared gate”注释已过期 | W1b3b先删死`prepared_call_ok`事实/注释并禁止用它绕过C_FUNCTION carrier；M-NATIVE-CALL再只审计真实callable→frame→record，不混入property lookup或复活无carrier prepared call |
| internal control不是JS callable | array destructuring直接由parser发`OP_for_of_start/next`、`OP_iterator_close`、`OP_copy_data_properties`并以stack/catch-offset保存iterator状态；runtime没有为它们缓存C_FUNCTION。pinned commit没有explicit-resource-management feature | zjs把六个解构动作和八个`using`动作编码成`special_object`返回的无realm C function，再走通用`call`；14个对象由Runtime强缓存/trace/free，解构还用Ordinary state object与全frame扫描补异常关闭 | W1b2.5先以M-DSTR-SOURCE-ORDER/M-DSTR-STACK按源码顺序单遍构造pattern/default/RHS，并恢复QJS label/iterator opcode/abrupt-close协议。八个`using` helper作为product extension在W1b2.6改为最窄typed opcode/continuation，沿active realm但不创建JS function；它不阻塞ordinary/core finalizer，却必须先于realm callable inventory。不得只把14个对象改成caller-data class绕过C_FUNCTION invariant |
| AUTOINIT dispatch domain | property低2位只有PROTOTYPE/MODULE_NS/PROP三个ID；第二word直接保存static function-list entry、null或module pointer。PROP只延迟`JS_DEF_CFUNC/PROP_STRING/OBJECT`。CGETSET、数值/布尔/atom/undefined常量都立即定义；`JS_DEF_ALIAS`会立即读取source并定义同一value，源码明确写着alias用autoinit不安全 | `AutoInitKind`还承载native accessor、number/int常量、alias shared cache及多类host object；`AutoInitRef{rt,id}`把每个slot变成runtime table lookup，`shared_lazy_native_functions/shared_native_cache_slot`再把本应按安装顺序建立的alias identity变成realm cache | M-AUTOINIT-QJS-DOMAIN-PUBLISH先逐producer映射三个QJS ID或eager路径；standard slot改direct typed opaque pointer并删runtime-ID lookup。accessor/数值常量/alias回到安装期，alias按source materialize→同值define并删除shared cache。host扩展只能复用PROP的immutable builder契约，不能扩张slot dispatch或把“启动更快”冒充Zig限制 |
| AUTOINIT publication/failure | property slot own压缩的context+id；先以caller ctx准备shape，再用slot realm调用builder；PROTOTYPE/PROP在ordinary target发布normal value，MODULE_NS可直接发布namespace object或把resolver返回的encoded VarRef转为VARREF，global target另建VARREF cell；随后free slot context。builder exception向上传播，当前QJS失败后留下normal `undefined` | `materializeAutoInit`把所有builder error压成null/`undefined`、保留placeholder重试；native function builder甚至在同一次read静默尝试两遍，成功一律发布data/accessor而非global/module VARREF；generic `getProperty`无error channel | 同一机制随后改成一次fallible builder+显式异常传播，并分别锁normal、module VARREF与global VARREF publish。成功owner转换忠实对齐；为满足GUIDE same-runtime recovery，失败保留placeholder/RealmRef供后续重试是命名的transactional safety divergence，不能继续吞错或双试 |
| realm compensation side channels | ordinary/class object不存context；builtin eval、Object/TypedArray/RegExp getter与Dynamic Function直接使用active C_FUNCTION/FB context的`eval_obj/class_proto/native_error_proto`，newTarget fallback才调用`JS_GetFunctionRealm` | alternate `Function`公开十个`__realm_*_proto`属性并复制到dynamic function；另有`tagRealmEval/tagRealmRegExpAccessorErrors`、function rare primitive/error cache与ordinary typed-array ArrayBuffer-prototype cache | 归M-REALM-NONCARRIER-RETIRE逐reader删除；先让真实carrier/state提供来源，再删property/tag/cache。公开字符串属性的存在、枚举、Proxy get trap与可变性都是correctness/no-cheating问题，不以payload缩小或性能收益记账 |
| runtime/embedding传递性强根 | Runtime的context list只枚举；class prototype由Context own，`JS_GetOpaque2`只按class id取payload。QJS要求embedding在`JS_FreeRuntime`前释放context/value owner，没有runtime-wide method record暗持某realm prototype | `MethodRuntime.prototype: JSValueHandle`由runtime external-record表保留到clear/teardown；公开persistent handle同样能经函数值保活RealmContext，而Runtime当前会主动clear slot使外部handle悬空 | 内部external record逐ptr-state审计JSValue/handle/RealmRef；method callback从callee RealmContext读取该class的prototype以保持现有realm-local binding contract，并删prototype handle。公开handle是命名embedding root，不删除，但Runtime teardown必须在释放job/host owner后验证strong/weak/local slot归零 |
| RealmContext GC与枚举拓扑 | `JSContext`有两条独立intrusive link：header进入`gc_obj_list`，`mark_children(JS_CONTEXT)`调用`JS_MarkContext`作为trial-decref child traversal；普通`link`进入Runtime `context_list`，供class扩槽、memory/diagnostic枚举及Object.prototype索引变更时定位本realm Array prototype guard。两条list都不额外retain | Context只向`root_providers`登记裸地址；`Runtime.traceRoots`会枚举它，但当前cycle collector明确不调用该路径，只在`Object.traceChildren`处理object/FB/VarRef/shape。数组写则依赖runtime-wide永久单向flag+逐链扫描，跨realm互相污染且被write/append/fill/unshift/bulk helper共用 | W1b3a新增`.realm_context` GC kind、typed child edge与独立runtime context list并补齐collector switch；provider只作borrowed diagnostic/真正host-owned external tracer，RealmContext-owned slot不得再冒充external root。随后单列M-ARRAY-WRITE-CONSUMER-MAP→M-ARRAY-PROTO-GUARD：先按Set/Define/own overwrite/hole/product fast path分类，再只给QJS `can_extend_fast_array`对应reader使用per-realm direct guard，退掉global compensation且不混账 |
| custom class ID/definition/prototype | `JS_NewClassID`为调用方持有的ID slot在process-global namespace分配一次；复用同一slot才跨Runtime稳定，独立slot不按名称自动合并。每个Runtime用`JS_NewClass1`注册definition/扩全部live Context storage，再commit record与`class_count` bound，65535仍有效。partial realloc失败只留不可观察capacity；Set/Get proto只按published bound，setter先publish new再free old以允许reentry | `class.Table.next_dynamic_id`在每个Runtime分配并允许unregister，且错误拒绝65535；Context以slice.len混合storage/published范围，只在set的Context扩；plugin还由Runtime record持prototype | 引入显式caller-owned ClassIdSlot/registration identity，static binding可复用，dynamic plugin instance各分配一次且永不回收；不按descriptor名字误合并。Runtime definition/bound、Realm storage继续分层；allocator加宽/exhaustion并修65535，partial OOM不泄漏bound，slot bound与高层NotInstalled不混写。若保留Runtime-local ABI须具名。all-live/future capacity及consume/get-dup/borrow、publish-before-free重入顺序仍对齐；plugin rollback另列，object只经shape保prototype |
| class record pointer lifetime | `JS_NewObjectFromShape`先`js_trigger_gc`，对象/属性分配后才按`class_id`读取`class_array[class_id].exotic`；`free_object`先递归释放property/shape，随后重新按id读取finalizer。class array可在`JS_NewClass1` realloc，但没有跨GC/回调保留表内pointer，且definition无动态unregister | `Object.createInternal`在`collectBeforeObjectAllocation`前取得`recordPtr`，跨GC、shape/property/payload allocation后仍读取；destroy也让pointer跨若干可重入cleanup。动态register可搬records buffer，unregister可清record，现有“table static once registered”注释只在更强契约下才成立 | 保留pointer-only标量访问，但先做M-CLASS-RECORD-LIFETIME：任何table pointer只活在no-GC/no-callback窗口。construction在fallible窗口前只复制最小immutable plan+registration generation，最终publication前按id重取并校验；或由明确definition pin保证同一record不可卸载。plugin execution pin不替代全表realloc防护。收益记零，不退回88B整record复制 |
| Atomics waiter与host completion | pinned QuickJS`:60808-60997`只有同步`Atomics.wait/notify`：waiter是调用栈节点，仅含cond+shared pointer，不持ctx/JSValue，也不从notify线程执行JS；该版本无`Atomics.waitAsync` | zjs waitAsync在全局`atomics_waiters`挂heap node，持Promise+裸Context；notify在mutex内直接create string/settle Promise，失败`catch {}`后仍unlink/free。timeout又靠任意同ctx Promise/job poll扫描 | 作为reference-version product extension分两步收口：W1b3a让node own RealmRef，消灭裸ctx；W1b3d2让notify/timeout仅无分配地标记并转交owner-runtime host completion，runtime线程再按node realm进入统一FIFO。失败保留node/promise/ref可重试，destroy按cancel/drain contract恰好释放，不伪称QuickJS或Zig限制 |
| job执行事务 | `JS_ExecutePendingJob`每次只摘一个entry，以entry realm调用；随后free argv/result/entry并free context，返回`-1/0/1`。异常停止本次host loop，后续FIFO不被消费；`pctx`已标obsolete，且只在job ref之外仍有owner时才给borrowed ctx | generic `Queue.runAll`连续跑完整queue并无条件free result；Promise/Finalization另有两套drain。公开`job.drain`又忽略`budget`，把“曾有work”硬报为drained=1 | W1b3d2建立唯一`runOne` transaction：empty/success/exception显式返回，异常保留Runtime current exception并停止，后续entry原序不动。public drain作为zjs adapter精确循环至budget/empty/error并返回真实count/has_more；释放entry RealmRef后不得返回悬空raw ctx |
| job enqueue/OOM publication | `JS_EnqueueJob2`分配entry后dup ctx/args再挂FIFO；但Promise reaction、thenable与dynamic-import内部调用都忽略失败，FinalizationRegistry用`no_exception`后也忽略，可能丢work/留下pending promise。Promise reject另有state/result→host tracker→旧reactions enqueue的可重入phase | Promise settle已有`qjsPreparePromiseReactionJobs`+capacity preflight后commit；其他producer与分散queue各自处理，统一时既可能退回先改state再enqueue/silent catch，也可能把tracker phase错误折叠进“原子commit” | 建立producer transaction矩阵：generic显式enqueue失败不消费输入；Promise/thenable先reserve entries/RealmRefs/args，再按QJS state→tracker→reaction次序no-fail publish，reservation须耐reentry；dynamic import区分promise暴露前的reject/throw与暴露后的typed pending completion retry；Finalization/waitAsync保留pending retry。全部是具名GUIDE safety divergence，收益零 |
| empty object | `OP_object → JS_NewObject → JS_NewObjectFromShape`：GC trigger、Object alloc、按 shape `prop_size` 分配 property array、rc=1、挂 GC list | zjs 使用 shared root，但空对象 lazy-skip property array，并承担 MemoryAccount/Registry；这是已有 zjs 优化，不是 Zig 限制 | 按事件和关键链比较，不以分配次数机械求同 |
| shape transition | `find_hashed_shape_prop` 不比较 `prop_size`；cache hit 后若容量不同就 realloc 对象 property array，再采用目标 shape | zjs 三臂已存在，但 `findHashedShapeProperty` 要求 candidate `prop_size == property_capacity` | M-SHAPE-PUBLISH 的第一项改为验证并对齐 cache-hit 资格/容量协调 |
| RC/free | inline `JS_DupValue/JS_FreeValue`；对象到 0 后入 `gc_zero_ref_count_list`，由最外层 drain 调 `free_object/free_gc_object` | 默认 value representation 和 zero-ref queue 已同构 | 不重开抽象；只在 allocation direct profile 证明重复记账或关键链差异时动 |
| compiler topology | 单次正式parse按遇见顺序建FunctionDef；for-in/of与destructuring均以label/operand stack分离源码构造顺序和运行顺序，后者再以iterator catch-offset承载且不复制child/temp；finally只生成一个`gosub/ret` body。随后对每个FunctionDef执行scope-link rebuild→`add_eval_variables → add_global_variables → 递归 finalize children → resolve_variables → resolve_labels → compute_stack_size`；`capture_var`在第一次真实capture时编号，scope close/body hoist均由真实事件锚定 | candidate已删除closure permutation/remap、grouped open-index、forward retrofit与ancestor fallback，并完成body pre-scan删除、ordinary block/body、generic-for普通LHS单遍、scope/body identity、lexical-for单一VarDef与non-pattern `defineVar` core；剩余pattern ledger/arguments scan、statement carrier偏早、通用lvalue source shape、destructuring replay、finally复制及scope/finalizer/body双表示、全树prepass、entry预刷新与derived `this`伪capture。`using`和TS namespace是独立产品控制面 | P0只冻结row schema/identity规则；W1b2.5从M-LVALUE-PROVENANCE-CORE开始按control→DSTR source→DEFINE close→DSTR stack→finally→scope events→derived this→finalizer/body/close原子checkpoint推进。特别禁止在destructuring双parse尚存时宣称define owner完成，也禁止在current-before-children前提前用future capture降低leave。W1b2.6再隔离M-USING-TYPED-CONTROL；correctness变化不计性能 |
| final bytecode语义表 | `OP_eval/apply_eval` 在`resolve_variables`中把parser scope改写为`vardefs`链头；最终`JSBytecodeVarDef[arg_count + var_count]`按args→locals连续打包，direct eval只沿`scope_next`；最终`JSClosureVar`没有来源深度 | row schema、args→locals容器、final chain head、`ARG_SCOPE_END`与table-order lookup已同构，scope/body identity和non-pattern declaration core也已落地；但pattern旁路、statement carrier时机、destructuring topology与Annex-B仍可改变VarDef顺序/loc operand，static class-field inline eval仍占`0x8000` | W1b1 lookup契约与W1b2物理表示冻结；具体index/final bytecode不冻结。pattern、destructuring、carrier/Annex-B与高位分别由DEFINE-CLOSE、M-DSTR、finalizer/body原子checkpoint与W1d收口 |
| dynamic environment producer | `add_eval_variables`只为**自身含direct eval**的函数捕获所有可见父绑定；普通后代在`resolve_scope_var`先命中近侧lexical/arg/pseudo binding，只有未解析名字继续越过动态环境时才逐层加入`<var>/<arg_var>` ref | 已删除把每个direct-eval var object无条件转发给全部后代的helper；自身direct-eval仍在prefix阶段捕获，普通lookup在final resolver按实际跨越路径产生inside-out rows | producer与consumer同时冻结：first-match只解释已有row，不能靠全量传播再靠排序/深度补救；near lexical shadow与跨两层missing-name均有diagnostic-qjs同构回归 |
| final record物理布局 | `JSClosureVar` 8B、`JSBytecodeVarDef` 12B；bitfield/flags、`var_idx`和atom按4-byte alignment紧凑排列；in-memory masks与serializer wire masks不同 | W1b2 已让compile/final closure共享8B/align4 explicit-mask storage，vardef为12B/align4 extern storage；VarKind、raw masks、zero holes与uncaptured index均由C/Zig golden锁定 | **表示已完成，性能收益记零**；后续只允许ownership move复用该storage，不得重开packed规则、serializer或把Zoo噪声继承成收益 |
| finalization ownership | cpool/closure rows/var-name atoms/func-name/filename/source/pc2line在所有fallible准备完成后转移到FB；没有逐元素dup→FunctionDef teardown free的往返 | zjs逐项dup vardef/closure atoms与cpool values，复制source/pc2line，再由FunctionDef/lowered teardown释放原owner；FB的intrusive GC publication当前实际no-fail但API仍写成error union | 单列 M-FB-COMMIT-TRANSFER；先完成真实fallible准备，把FB publication收紧为类型上no-fail，再进入move commit，不与allocation packing合并归因，也不虚构registry OOM |
| production terminator | parser对script/eval显式发`get_loc _ret_; return`，module/function fallthrough显式发`return_undef`；final pack只复制`fd->byte_code.size` | final FB和mutable Bytecode都额外分配1 byte不可见`op.return`，root/eval和branch-to-end仍依赖falloff读取它 | 单列 M-EXPLICIT-TERMINATOR：先让所有生产控制流显式终止并拒绝reachable falloff，再删除`+1`；fixture安全不得污染生产artifact |
| stack/interrupt | stack overflow 是 native SP + planned `alloca_size` 检查；interrupt counter 属于Context并跨call持续，在call entry和jump/backedge poll | jump/call poll point已有，但VM-local budget会随Machine/call重建、阈值为1024且无handler时不持续；无限tail recursion另来自frame reuse未消耗stack budget | tail stack与interrupt budget是两个正确性机制：W2先分别对齐再审计return continuation，不用一个廉价计数器互相冒充 |

### 1.5 本轮可复核源码锚点

以下行号钉在页首 QuickJS commit；若 reference 更新，先重新生成本表，不把旧行号/结论平移：

| 事实链 | QuickJS 锚点 | 当前 zjs 锚点 |
|---|---|---|
| capture identity/index 与 dynamic eval producer | `quickjs.c:32736 get_closure_var`、`:32907 capture_var`、`:33060 resolve_scope_var`、`:33610 add_eval_variables` | `src/parser.zig` 的 `prepareDirectEvalAndGlobalClosures`/`captureVisibleParentVarsForDirectEval`；`src/bytecode.zig` 的 `resolveBindingTopology`、`beginOpenBindingResolution`、`captureParentBindingsFromChild` |
| 单遍declaration/lvalue producer | QJS正式parse时才由`define_var/add_var`按遇见顺序append；identifier lvalue先发`scope_*`，再由`:32907-33320 resolve_scope_var`按完整FunctionDef决定local/with/eval-object/global。QJS的`js_parse_skip_parens_token`只服务参数/解构/for/arrow等grammar lookahead | body pre-scan、`needs_dynamic_lvalue_refs`及simple catch/for future scans已删除；剩余声明旁路是pattern `BlockScopeDecls`+switch scanner，以及只为future `function arguments`存在的`remainingBlockHasDirectFunctionDeclarationName`。`active_with_atom`仍提前选择reference transport |
| phase-1 emitter、LValue与call consumer | `quickjs.c:23864 emit_op`、`:23923 emit_label_raw`、`:25933-26191 get_lvalue/put_lvalue`、`:27139-27233` call last-op switch、`:27480-27562` optional marker/delete、`:28291-28309` comma invalidate | `src/parser.zig:5965 beginOpcodeNoSource`当前先改provenance再fallible append；`:6731 getLValue/:6847 putLValue`仍含final `get_var` adapter、private半variant和source-aware put；`:7870-8140`靠optional signature scan；`:8406-8773`与`:9205-9227`仍读call/token状态 |
| simple var/reference label与resolver | `quickjs.c:26300 need_var_reference`、`:28515-28575 js_parse_var`明确发`scope_get_var→get_lvalue(FALSE)→RHS→source(=)→put_lvalue(NOKEEP)`；`:32790 optimize_scope_make_ref`用make-ref operand对应`LabelSlot.pos`定位put尾 | `src/parser.zig:12945-13070`直接`emitScopeMakeRef(unpatched target=0)→RHS→put_ref_value`；旧pattern的`captureDestructuringVarBindingRef`同类；`src/bytecode.zig:5231 findGlobalRefPutTail`在direct target失败后最多扫16条。CORE先迁simple var，M-DSTR迁pattern，随后bounded fallback必须删除 |
| private binding/brand/class init | `quickjs.c:24432 add_private_class_field`、`:25218-25252 emit_class_init_start`、`:25435-25639` field/method/accessor slot init、`:25683-25723`按需instance/static brand、`:33423-33585 resolve_scope_private_field` | `src/parser.zig:3956`的private side lists、`:17627-18786` class parse/constructor metadata；`src/bytecode.zig:3957 resolvePrivateField`含side-name fallback；`src/exec/class_init_ops.zig:276 initializeClassPrivateMethods`逐descriptor复制。完整替换只归W1d PRIVATE-BINDING/CLASS-INIT |
| declaration scope双阶段字段 | `quickjs.c:24106 push_scope`令新scope继承`scope_first`；`:24038 find_var_in_child_scope`读取function-scoped VAR在compile期`scope_next`里保存的声明scope；`:36034-36059 js_create_function`再破坏性重建最终链 | compile期scope inheritance、visible chain和VAR origin已对齐；`finalizedScopeHead/Next`仍另算final链。M-FINALIZER-PRECHILD必须破坏性重建一次并删除最终平行authority |
| expression/lvalue与speculation边界 | `quickjs.c:27500 js_parse_delete`、`:27635 unary update/typeof`、`:28178 destructuring assignment`先完整parse operand或仅用`js_parse_skip_parens_token`判grammar，再由`get_prev_opcode/get_lvalue`改写；`:28745-28761 for-in/of`同样只parse target一次，并用label把iterable运行移到target前。lookahead不创建FunctionDef/VarDef/cpool；duplicate parameter在`:26276/:26325`由正式pattern traversal逐binding检查 | generic for target已改为单遍label/bottom-put并修合法member target；其余仍有`peekParenthesizedBareIdent`、`returnExprOperandHasFollowingTopLevelComma`与多处`parse*Literal/parseDestructuringPattern` snapshot。回滚只截code/atom，不恢复child/cpool/temp/VarDef：析构probe仍为`x,x,y`，array-literal member target仍可把一份`f`变四份；parameter/arrow/catch duplicate check仍由`collect*BindingNamesSnapshot`另跑名字parser |
| destructuring parser/transport | `quickjs.c:26338-26798 js_parse_destructuring_element`按源码顺序一次解析pattern/default/RHS，并以`label_parse/label_assign`把运行时RHS求值织到pattern之前；array pattern使用`for_of_start/next`、`iterator_close`和BlockEnv catch-offset，对象rest用`copy_data_properties`；无内部JS function | declaration/assignment会完整试解析后重放，parameter outer default又先于pattern正式parse；六个dstr subtype经`special_object + call`和Ordinary state/temp locals执行。另有八个`using` subtype伪装JS callable，且`blockDirectUsingDeclarationKind/programDirectUsingDeclarationKind`先全文扫描每个block/program；后者是独立product extension |
| finally单一控制流 | `quickjs.c:28392 emit_return`对active finally发`nip_catch; gosub`；`:29388-29545`只解析一次finally body并以`ret`返回，同一body服务normal/throw/return/break/continue | `src/parser.zig:tryStatementHasFinally`先扫源码；`parseFinallyBlockForAbruptPath/ReturnPath`和`emit*FinallyCop*`从snapshot多次重解析并复制body，现有`gosub/ret` opcode未成为production finally真源 |
| scope linkage与captured-cell关闭点 | `quickjs.c:24106 push_scope`、`:24152 pop_scope`、`:24164 close_scopes`发真实entry/leave；`:34398 OP_enter_scope`初始化binding，`:34432 OP_leave_scope`才按`is_captured`发`close_loc` | `src/parser.zig:parseBlock`只调用`emitEnterScope`后直接`popScope`，loop另调`emitCloseCurrentScopeLexicals`；`src/bytecode.zig:enterScopeRefreshSize/writeEnterScopeRefresh`在entry按hint先发`close_loc`，leave marker被直接丢弃 |
| lexical for-in/of scope identity | `quickjs.c:28689`只push一个head scope，`:28811/:28856`在iterable/body后`close_scopes`，`:28888`循环结束才pop；diagnostic probe只有一个`let x` local | 单一head/binding与通用`closeScopes` primitive已落地，body冲突由`defineVar`可见链裁决；abrupt-edge detach仍归M-SCOPE-EVENT/CLOSE |
| scope producer/directive边界 | `quickjs.c:28495 js_parse_block`只为非空普通block push/pop且不解析directive；`:29024 if`、`:29160 for`、`:29302 switch`、`:29427/:29463 catch wrappers`、`:29560 with`均发真实scope事件。directive只在`:37078 js_parse_program`和function body解析 | ordinary block/function-body分界、empty block与directive已对齐；if/catch/with等scope event/leave矩阵及后续scope-close仍不同，多类push没有成对phase-1 event |
| body事件与函数声明producer | root在`quickjs.c:37265`、function/arrow在`:36884`、default constructor在`:25129`均先`push_scope`并记录`body_scope`；statement child完成后才建立body/global carrier；sloppy block function先`define_var` lexical，child后才append/reuse outer var | body identity已统一但event/hoist仍分路；zjs仍在child前建立statement/global/Annex-B outer carrier，anonymous default又用expression+post-hoist adapter。统一留给PRECHILD+BODY-HOIST原子checkpoint |
| derived `this` capture provenance | `capture_var`只有真实resolver/eval/mapped-arguments callsite；无nested capture的derived constructor最终`this`是普通lexical local且`var_ref_count=0`，`super()`以`put_loc_check_init`初始化同一local | `src/bytecode.zig` finalizer无条件`captureLocal(this)`；`src/exec/vm_call.zig:linkDerivedConstructorThisLocal`把local再与`frame.this_value` cell绑定，制造非QJS capture/index和第二authority |
| final vardef/eval operand/artifact | `quickjs.c:624 JSClosureVar`、`:654 JSBytecodeVarDef`、`:33780 add_closure_variables`、`:34247 OP_eval/apply_eval rewrite`、`:36128-36263 pack/transfer/realm` | `src/bytecode.zig` 的`BytecodeVarDef`/`BytecodeClosureVar`、`finalizedScope{Head,Next}`、`encodeEvalScopeHead`、`createFunctionBytecodeAfterChildren`；`src/exec/eval_ops.zig:createDirectEvalClosureSeed`；`src/parser.zig:markDirectEvalVisibleOwnBindings`；realm仍由`bindBytecodeFunctionRealmGlobal`首实例绑定 |
| module local-export final index | `quickjs.c:35954-36017 add_global_variables`在递归child前以最终closure表解析每个local export并写`JSExportEntry.u.local.var_idx` | `src/parser.zig:20028 validateModuleLocalExports`只在parser末尾按名字确认存在；`src/bytecode.zig:Export`只保存export/local name，无indexed carrier。普通finalizer收口不能冒充module exact，归W1e persistent/indexed link |
| realm state与owned carriers | `quickjs.c:518-560 JSContext`、`:2710/2765 Dup/FreeContext`；FB`:36261`、native`:5961`、AUTOINIT`:10670`、job`:2276`、FinalizationRegistry`:61312`分别dup，析构路径分别free/mark；`:2405 JS_FreeRuntime`先释放jobs并最终要求GC/context graph为空 | `src/core/object.zig:RealmPayload`只含部分cache；`src/core/context.zig`仍own eval/class prototypes，`src/core/runtime.zig`仍own random/modules/OOM且destroy会整体deinit；native/AUTOINIT/FinalizationRegistry多为borrowed global，FB首closure才retain |
| RealmContext GC/list双拓扑 | `quickjs.c:2593-2618 JS_NewContextRaw`把header加入GC list、另把`link`加入context list；`:2717-2759 JS_MarkContext`列owned children；`:6656-6674 mark_children`从`JS_CONTEXT` kind进入；`:2765-2828 JS_FreeContext`释放children后从两条list移除 | `src/core/context.zig:497-520`只注册RootProvider、`:688-719`只实现external RootVisitor枚举；`src/core/runtime.zig:1430-1456`消费provider，但`src/core/object.zig:7013-7056/:7296`的trial-decref只认自身child visitor；`src/core/gc.zig:110-117/:1270`尚无context kind/candidate |
| context-list的Array prototype guard与reader域 | `quickjs.c:56469`只在standard Array bootstrap完成后置flag；`:9184-9204 add_property`在后续fallible shape/property growth**之前**，只对`__JS_AtomIsTaggedInt`（0...`2^31-1`）按realm清flag，故该attempt稍后OOM也不恢复；`:7984`只在prototype实际改变并commit后清，`:9284`在dense→ordinary后清；`:9935`的`can_extend_fast_array`只供Set/put append、push、splice四处extension reader。已有own dense index直接set；CreateProperty append不查prototype；fill/unshift走generic | runtime-wide sticky+chain scanner被write/append/range/fill/unshift共用，且“可能有indexed”域比QJS small tagged atom更宽 |
| OOM error来源与递归保护 | `quickjs.c:7638-7659 JS_ThrowError2`按**当前ctx**的`native_error_proto[error_num]`构造；若对象分配失败就以`JS_NULL`作为exception避免递归。`:7778-7787 JS_ThrowOutOfMemory`只在Runtime保存`in_out_of_memory` guard，没有预分配OOM Error对象 | `src/core/runtime.zig:preallocated_oom_error`是首个bootstrap realm构造的Runtime强root，后续alternate-realm OOM会复用错误prototype/identity；`src/tests/oom_cap.zig:1-11/:158-198`另有既存“catchable object + exhausted window零分配 + same-context recovery”门禁。`runtime.zig:864-867`、`exec/zjs_vm.zig:193-200`、`exec/vm_exception_ops.zig:39-50`仍把该zjs fallback误注释为QuickJS analogue/preallocated exception |
| global discriminator/payload split | `quickjs.c:780 JSGlobalObject.uninitialized_vars`、`:989 JSObject.class_id`与`JS_CLASS_GLOBAL_OBJECT`；`:17054` global mark/finalizer、`:8188` AUTOINIT只按class选择VARREF publication | `src/core/object.zig:isGlobal`以`.realm` payload kind判定，RealmPayload同时承担uninitialized vars、realm state/cache与global marker |
| RealmContext initial shapes | `quickjs.c:2717-2762 JS_MarkContext/:2825-2829 JS_FreeContext`直接mark/free五个shape；array/arguments bootstrap`:56472-56507`、regexp`:49289-49313`一次建shape；constructors`:5843/:16166/:16229/:47658/:48210`只dup shape并交owned stack `JSProperty props[]`。`:5613-5736 JS_NewObjectFromShape`失败按shape flags释放props+shape，成功把props无额外dup地转移给object | `src/core/object.zig:RealmValueSlot`以JSValue缓存regexp/arguments/match-result/iterator template；`object_ops.zig:2380-2468`和`standard_globals.zig:876-886`先造完整template Object，再由construction clone shape/entries。`shape.Registry` hash bucket本身只借ptr并在shape destroy unlink |
| AUTOINIT允许域、opaque与alias | `quickjs.c:39569 JS_InstantiateFunctionListItem2`只构造C function/string/object；`:39606 JS_InstantiateFunctionListItem`让CGETSET/常量/alias eager，alias注释明确禁止autoinit；`:8164`低位仅三种dispatch；`:10655 JS_DefineAutoInitProperty`第二word直接保存entry/null/module opaque | `src/core/property.zig:AutoInitKind/AutoInitRef/internAutoInit`含native accessor/number/int/empty-array/host namespace等扩展并以`{rt,id}`查runtime table；`src/core/object.zig:sharedLazyNativeFunctionSlotForAutoInit`与`RealmPayload.shared_lazy_native_functions`为alias identity另建realm cache |
| AUTOINIT publish/error | `quickjs.c:6076-6095` decode/free/mark realm、`:8164-8210 JS_AutoInitProperty`一次调用stored-realm builder、ordinary发布normal、global发布VARREF并传播exception；`:30378 js_module_ns_autoinit`与`:30487`让delayed namespace解析为namespace object或shared VarRef | `src/core/object.zig:8845 materializeAutoInit`用optional/undefined吞builder error，`:9028 materializeNativeFunctionAutoInit`同次失败双试；`:8949 installMaterializedAutoInit`只发布data且失败保留placeholder，generic `getProperty`无error union |
| 非carrier对象没有realm | `quickjs.c:989-1075 JSObject` union只有bytecode FB、C_FUNCTION realm和各class数据；generator经`:20893 async_func_init`保存的`frame.cur_func→FB`恢复；bound`:17692`/proxy`:51337`先在caller执行再递归target | `src/core/object.zig`有20处`realm_global_ptr`声明/视图、两个平行`realm_global` value，`objectRealmGlobal`可从十余payload取realm；ordinary namespace/prototype还被注册进borrowed-holder表 |
| 非carrier realm side channel | `quickjs.c:40098 js_object_constructor`、`:41055 js_function_constructor`、`:47855 js_regexp_get_source`、`:59904-60034 typed-array constructors`均只读active ctx或`JS_GetFunctionRealm→class_proto`；源码无`__realm_` | `src/exec/call.zig:tagRealmEval/tagRealmFunctionConstructor/tagRealmRegExpAccessorErrors`；`object_ops.zig:copyRealmPrototypeKeys/reflectConstructRealmPrototype`；`construct.zig`同名复制；`FunctionRarePayload.primitive_prototypes/realm_type_error_constructor`与`OrdinaryPayload.typed_array_array_buffer_prototype` |
| call phase与FunctionRealm | `quickjs.c:17562 js_call_c_function`、`:17746 JS_CallInternal`：direct arm stack preflight后才切callee realm；C_FUNCTION_DATA`:5999-6068`沿caller；bound`:17692`与proxy`:51337`在caller完成wrapper/trap工作后才递归target；`:20735 JS_GetFunctionRealm`递归解析，但真实consumer仅create-from-ctor/Dynamic Function/Error prototype fallback与ArraySpecies cross-realm intrinsic comparison | `src/exec/vm_call.zig`、`call.zig`、`call_runtime.zig:functionRealmGlobal`及`src/core/object.zig:functionRealmGlobalPtr`当前混合caller fallback、borrowed payload与bound/proxy复制，record table尚未分类data-callable |
| internal callable class map | Promise resolving专用class`:53518-53630`、async function resolve/reject`:21215-21315`沿caller；C_FUNCTION_DATA call/owner`:5999-6068`及proxy/promise/async-generator/async-from-sync/module/iterator producers`:21434/:31009/:31373/:51499/:53741/:54047/:54314/:54348/:54464/:54480/:56568`；reaction/thenable/dynamic import直接enqueue job`:53466/:53626/:31155` | `src/core/host_function.zig:InternalCallableTag`的13类大多由`nativeFunction`+realm tag创建；`src/exec/promise_ops.zig`还把reaction/thenable job包装成函数，`src/exec/module_graph.zig`把dynamic import job包装成external host function；`c_function_data` class当前零producer |
| internal-control stack protocol | array destructuring parser`:26665/:26765`直接发`for_of_start/next`、spread loop和`iterator_close`；object rest`:26421`发`copy_data_properties`；VM handlers`:19000-19025/:19679`在active ctx执行，runtime无helper function cache | `src/parser.zig:emitBindingIndex/Elision/Rest/Close/RequireIterator`发`special_object + call`；`src/exec/call.zig:internalDestructuringHelperFunction`创建并缓存六个dstr+八个using C function；`src/core/runtime.zig:internal_destructuring_helpers[14]`负责root/trace/free，`src/exec/call_runtime.zig`另有destructuring iterator state与frame-wide abrupt scan |
| callback-facing context/global identity | `quickjs.c:17562 js_call_c_function`切到`u.cfunc.realm`后把该稳定`JSContext*`传C callback；`:6025 js_c_function_data_call`则把caller ctx传data callback。ABI没有独立global参数，callback读取的global天然就是该ctx的`global_obj` | `src/exec/call.zig:hostCallExternalHostFunction`把当前`*core.JSContext`塞进`ExternalCall.ctx:anyopaque`，同时另传可独立漂移的`global`；binding、plugin/error、output、dynamic-import与test262 consumer再cast/自行fallback，`run_test262.wrapExternal*`甚至反向cast成by-value嵌core的binding wrapper。FFI `CallFrame.ctx`是公开raw ABI字段但尚未写明borrow lifetime；`ZigCall.ctx`才恢复typed core pointer |
| core/binding wrapper布局假设 | QuickJS embedding始终持/传稳定`JSContext*`，没有“outer public wrapper首字段恰好是core context”的第二identity | 除production EventLoop/test262 callback外，`src/tests/exec.zig:TestEngine`与`src/core/string_view.zig`测试也把`*core.JSContext`直接cast成`*binding.JSContext`；这些会掩盖owner/view API是否真实可用 |
| event-loop host context | `quickjs-libc.c:2175 setTimeout/:2014 setReadHandler`只保存callback value；`:4292 js_std_loop(ctx)`由host在运行时传入稳定ctx，loop本身不存/dup context；函数自己的callee realm仍由JS call carrier处理 | `src/runtime/event_loop.zig:EventLoop.context`保存`*binding.JSContext`；HostEventLoop vtable的timer/rw/signal入口把每个`*core.JSContext`直接`@ptrCast`回wrapper，依赖core恰好是wrapper首字段。zjs的`runUntilIdle(self)`与QuickJS `js_std_loop(ctx)`API形状不同，因此若保持现有API，loop的单一RealmRef是命名host-lifetime adaptation而非QJS/Zig限制 |
| Atomics waiter/context与线程边界 | `quickjs.c:60808-60997 JSAtomicsWaiter/js_atomics_wait/notify`：同步stack waiter只存cond+buffer ptr，无context/JSValue；notify只摘链并signal。pinned commit无waitAsync | `src/exec/call_runtime.zig:3155 AtomicsWaiter/:3413 atomicsWakeWaiters`全局node存Promise+裸ctx；`src/exec/promise_ops.zig:2634/:2641/:2731`直接settle/destroy/create，notify arm以`catch {}`吞错并可从foreign thread触碰runtime heap |
| binding prototype view与handle传递根 | `quickjs.c:2672 JS_SetClassProto`把prototype放Context；`:11031 JS_GetOpaque/JS_GetOpaque2`只检查class id，native callback/embedding操作由收到的active ctx取state；runtime context list不own base ref，没有可独立逃逸的raw prototype handle | `src/binding/binding.zig:MethodRuntime`把realm-local prototype放`JSValueHandle`，external host record使其存活到runtime clear；相反，`:106 JSObject.Binding{runtime,class_id,prototype:*Object}`公开可复制却没有owner/lifetime，`:243/:249`直接解引用。`payloadFromClassAndPrototype`的exact prototype是现有binding contract。`src/core/runtime.zig:JSValueHandle`注册runtime root slot，而destroy当前会主动`clearPersistentRootSlots`；`docs/public-api-contract.md:127-139`尚未说明Binding view lifetime |
| plugin custom class ID/definition/prototype | `quickjs.c:1414/:3816-3838 JS_NewClassID`从process-global计数器给调用方slot稳定分配id，`CONFIG_ATOMICS`下只给该global allocator加mutex；`:3857-3904 JS_NewClass1`本身不加Runtime mutation lock，接受`id < 1<<16`、在串行的每个Runtime注册并把**所有live Context**的`class_proto[]`扩到同一class-count；`:2662-2676 set_value/JS_SetClassProto`在指定Context slot consume任意tag且先publish new再free old，`:2679-2683` getter返回dup；`:5743/:5831-5834`创建对象时才把object-tag slot装进shape，其他tag落为null proto | `src/core/class.zig:Table.next_dynamic_id/newClassId/register/unregisterDynamic`把id allocation、Runtime record和unregister绑在一起，`registerAtom`还以`>= maxInt(ClassId)`拒绝QJS合法的65535；`src/core/context.zig:ensureClassPrototypeSlot`只在单一Context延迟扩槽。plugin prototype又由`InstalledPlugin`持有至Runtime teardown |
| class table pointer与重入窗口 | `quickjs.c:5613-5736 JS_NewObjectFromShape`先`:5619 js_trigger_gc`，之后才按id读`:5725 class_array[class_id].exotic`；`:6334-6386 free_object`先释放properties/shape，再于`:6365`按id读finalizer。`:3857-3904 JS_NewClass1`虽可realloc `class_array`，上述路径不跨GC/回调缓存表内pointer | `src/core/object.zig:createInternal`在`collectBeforeObjectAllocation`前取得`recordPtr`并跨shape/property/payload allocation继续读；`destroyFromHeader`也复用pointer跨cleanup。`src/core/class.zig:ensureCapacity`会搬records buffer，`unregisterDynamic`会清slot，而`recordPtr`注释假定table static |
| class growth的list/GC窗口 | `JS_NewClass1`沿context list调用`js_realloc_rt`，该raw Runtime allocation不在每次Context扩槽前触发JS GC，因此borrowed list不会在循环中因collector unlink | `MemoryAccount.alloc`会走trigger，`JSRuntime.allocRuntime`也先`requestGCForAllocation`；若未来裸遍历context list逐realm扩slice，forced-GC可在中途回收/unlink当前或后继realm |
| zjs plugin unregister/DSO order | pinned QuickJS无class unregister；class definition通常活到Runtime free，Context各自释放prototype slot | `InstalledPlugin.release`当前先`lib.close()`，随后`releaseInstalledHostClasses` free prototype/unregister；prototype迁slot后若metadata不记realm，必须另有clear路径。binding call、opaque finalizer/tracer又会进入DSO descriptor callback，卸载资格还必须覆盖active/queued callback窗口 |
| plugin deferred callback owner | pinned QuickJS没有动态DSO/class unload，class finalizer function pointer随Runtime definition存活 | `src/core/runtime.zig:NativeCleanupJob`和`DeferredClassPayloadFinalizer`把finalizer pointer复制进队列后延迟调用；InstalledBinding/OpaqueWrapperPayload当前间接retain plugin，但若重构只按live object/count判断，可能在queued callback执行前close DSO |
| job/module/interrupt context | runtime FIFO entry own realm`:2263-2335`；dynamic-import job以该`ctx`调用loader`:31035-31155`，normalize/load hook在Runtime并接收ctx`:29917-30058`；`loaded_modules`在Context`:549/:2618/:29663`；interrupt counter在Context`:512/:7867` | generic `src/core/jobs.zig:Job`借裸Context，Promise/Finalization分属Context/Runtime；`src/exec/module_graph.zig:DynamicImportState.load/DynamicImportHostState.load`忽略callback ctx并使用state裸context；`JSRuntime.modules`全局；VM-local InterruptPoller会随Machine重建 |
| job dequeue/exception边界 | `quickjs.c:2299-2335 JS_ExecutePendingJob`只执行FIFO head，按entry ctx释放args/result/ref并返回三态；异常不继续drain，`pctx`注释已标obsolete | `src/core/jobs.zig:47-107 Job.run/Queue.runAll`连续消费并free result；`src/exec/promise_ops.zig:3853-3901`与module/event-loop又各自组织drain，缺少统一run-one status |
| job enqueue/OOM边界 | `quickjs.c:2263-2291 JS_EnqueueJob2`先alloc/dup再publish；`:31155/:53466/:53626/:54238`的dynamic-import/Promise内部producer忽略返回；`:61277` finalization以`no_exception` enqueue并忽略 | `src/exec/promise_ops.zig:qjsPreparePromiseReactionJobs/qjsPromiseSettleValue`已有prepare+capacity+commit；`module_graph.enqueueDynamicImportJobWithAttributes`与后期loader/TLA continuation、waitAsync/finalization另有不同错误事务，统一queue时尚无一张按“promise暴露前/后”分phase的producer contract表 |
| Promise settle/tracker/reaction次序 | `quickjs.c:53441-53476 fulfill_or_reject_promise`先写result/state，再同步调用host rejection tracker，之后才按旧reaction list顺序enqueue并删除；`:54191-54242 perform_promise_then`对已reject promise也先发handled tracker通知，再enqueue该then reaction，最后置`is_handled`。tracker是可重入host callback，quickjs-libc的记录分配失败则只丢host report | zjs当前tracker是Context内部list且`qjsPreparePromiseReactionJobs`先建job，但路线图若把“state+全部FIFO publish”写成一个commit，会改变未来host callback/reentrant then的先后；tracker list的fallible host-policy又不能回滚已settle promise |
| zjs-only async host continuation | pinned无waitAsync；同步Atomics waiter不own context/value且notify不执行JS。QJS deferred JS work只能经own context的job entry回到runtime线程 | waitAsync node同时是跨runtime global-list link、Promise root、timeout state和裸context；foreign notify直接settle JS，错误被吞。它既未登记为host owner，也未进入ECMAScript FIFO |
| explicit production return | `quickjs.c:36990 js_parse_program`最终读取`_ret_`并`emit_return(TRUE)`；module走`emit_return(FALSE)`；`js_create_function`只打包`fd->byte_code.size` | `src/parser.zig`的root/function epilogue与jump-aware terminator；`src/bytecode.zig:createFunctionBytecodeAfterChildren`和mutable `Bytecode.ensureTrailingReturnSentinel`仍保留不可见`code[len]` |
| finalization move ownership | `quickjs.c:36128-36263`：vardef/closure atom、cpool value、func/filename/source/pc2line所有权从FunctionDef转入FB；`:36300 free_function_bytecode`统一释放 | `src/bytecode.zig:createFunctionBytecodeAfterChildren`当前dup atoms/values、copy debug buffers，再由FunctionDef/lowered teardown释放原owner |
| pc2line producer/consumer | `quickjs.c:34564 compute_pc2line_info`、`:7440 find_line_num`：buffer头拥有起始line/column | `src/bytecode.zig:pc2line.encode/decode`与`DebugInfo.line_num/col_num`；`src/exec/vm_exception_ops.zig:sourceLocationFromPc2Line` |
| post-order finalize 与 body hoist | `quickjs.c:34005 instantiate_hoisted_definitions`、`:34187 resolve_variables`、`:36024 js_create_function` | `src/bytecode.zig` 的 `installChildFunctionBytecodes`、`createFunctionBytecodeAfterChildren`、body/`enter_scope` hoist lowering；`src/parser.zig` 的 `VarDef.func_pool_idx` assignment |
| root/global/nested closure与FB引用转移 | `quickjs.c:17228 js_closure_global_var`、`:17262 js_closure2`、`:17367 js_closure`、`:37148 JS_EvalFunctionInternal`；`js_closure2`消费传入`bfunc`拥有的那一份引用，失败时随未发布object释放，不在attach内部额外dup | `src/exec/array_ops.zig:pushFunctionClosure`当前从cpool取得owned value后又`dup`给`createBytecodeFunctionObject`并在返回后free原值；`src/core/object.zig:setFunctionBytecodeValue`消费传入value但还在attach时fallible建cached view |
| FB raw producer边界 | ordinary compile只有`quickjs.c:36024 js_create_function`；binary/ROM reader另走`:38743 JS_ReadFunctionTag`且C function使用独立`JS_CLASS_C_FUNCTION`，不手造FB | production raw allocation只有`createFunctionBytecodeAfterChildren`；其余`alloc(FunctionBytecode)+init`命中均位于Zig test/fixture。native builtins走`core.function.nativeFunction`/`InternalCallableTag`，不是第二种FB producer |
| entry environment / current function | qjs 每个 script/eval frame 都由真实 function object 进入；global-var、`arguments`、`new.target`、`super` 资格来自 FunctionDef/bytecode/caller environment，不用“无 current function”作顶层哨兵 | 最新候选的`EntryContract`已接管declaration environment、pseudo binding capability与global IC gating；全仓`current_function.isUndefined()`只剩generator optional-state/首次resume身份fallback，不再承担上述语义。contract仍须在real root后退场审计 |
| closure 构造侧通道 | qjs 的 import-meta/script-or-module、private binding、arrow lexical state 与 `<class_fields_init>` 均由 bytecode/lexical capture/constructor bytecode承载；private method访问是lexical value + brand check，不把method descriptor复制到每个instance | `createBytecodeFunctionObject` 在 capture 前复制 import-meta、private remap、arrow home/super/constructor state，并递归创建 `class_fields_init`；`installChildClassFieldInitializers` 写bytecode side pointer，`initializeClassPrivateMethods` 再扫描home object注入instance |
| module function/link/namespace | context-owned registry`:29663 js_new_module_def/:30003 loaded_modules lookup`；`:30512 JS_GetModuleNamespace`、`:30580 js_create_module_function`、`:30622 js_inner_module_linking` | `src/core/runtime.zig:modules`与`src/core/module.zig:Registry`当前runtime-global；function/link/namespace consumer在`src/exec/module.zig`与`src/exec/module_graph.zig` |
| retained entry/source-shaped bypasses | qjs eval bytecode统一走 `__JS_EvalInternal → js_closure → JS_CallFree`；Dynamic Function只拼接原参数/body后统一parse | candidate已删除已确认的active bypass；负向 `rg` 与 numeric/regexp/string/strict/async-param/typed-array/empty-entry行为矩阵共同守门 |

### 1.6 2026-07-19 三层产物复审补漏

本轮不再按“字段名相似”判断对齐，而是把每项事实分成三层：**FunctionDef编译期事实 →
FunctionBytecode最终只读事实 → closure/call运行期消费**。复审结论如下：

| 项目 | QuickJS最终契约 | 最新zjs状态 | 计划裁决 |
|---|---|---|---|
| eval作用域操作数 | parser scope只活到`resolve_variables`；最终operand是`scopes[scope].first - ARG_SCOPE_END`，runtime加回marker后直接沿`scope_next` | 已按该链路改写；parameter高位已删除，`scope_parents`不再进入final artifact。唯一残项是inline static class-field eval的`0x8000` capability marker；此次复审把遗留mask从`0x3fff`改为`~0x8000`并用第16384后scope的`close_loc`红灯证明`0x4000`是数据 | 冻结ordinary/parameter机制；W1d先让static field也执行于真实`<class_fields_init>` child，再删除最后高位和15-bit上限。不得另造第二个flag或把容量缩窄称为Zig限制 |
| vardef语义表 | 一个`JSBytecodeVarDef[arg_count + var_count]`，args在前、locals在后；只保留name/scope_next/flags/var_ref_idx | final-only `BytecodeVarDef`单表已是12B/align4，arguments先于locals；final不含`scope_level/func_pool_idx/tdz_emitted_at_decl`，也无`arg_names/arg_open_binding_indices/scope_parents`；body identity与`defineVar` core/simple producer已落地 | **row schema、lookup contract与物理表示完成并冻结**；compile append provenance只剩pattern ledger/switch scanner、implicit-arguments future scan、statement carrier时机、Annex-B与class initializer边界，分别由M-DSTR-SOURCE-ORDER/DEFINE-CLOSE、final lookup、最终原子checkpoint和W1d收口。VM兼容view只借用arg/local切片 |
| artifact分配拓扑 | 一次`js_mallocz(function_size)`只包含FB header/可选inline debug metadata、cpool、vardefs、closure rows和bytecode；`source`与`pc2line_buf`仍是独立、转移进来的buffer；`strip-debug`缩短header并按`has_eval_call`决定是否保留var names，`strip-source`只去source | 每个普通FB分别分配FB slice、总是存在的`DebugInfo` box、read-only block；当前block还错误地复制并包含source/pc2line bytes；zjs尚无对应strip policy；首次closure构造另分配cached view | core pack只合并QJS core/metadata/四个trailing tables/code，非QJS事实暂置code后extension；source/pc2line保持独立move ownership。W1c3先锁retention/ownership，W1d才裁决total exact-close；不要把QJS未来注释或extension隐藏成“exact” |
| pc2line最终格式 | `compute_pc2line_info`先把function起始`line-1/column-1`以两个ULEB128写入`pc2line_buf`，随后才写pc/line/column增量；`find_line_num`从buffer解头，FB没有独立起始坐标字段 | zjs `pc2line.encode`只存增量，`DebugInfo.line_num/col_num`与compat view另存起始坐标，runtime decoder从平行字段起步 | 单列 M-PC2LINE-QJS-FORMAT：先改producer+decoder+malformed fallback，再删除final平行字段；它是debug artifact correctness，不与ownership transfer或pack收益合刀 |
| closure row | compile/final都使用同一个8B `JSClosureVar`；只有type、lexical/const/kind、index、name，顺序本身就是查找/provenance契约 | compile/final已共享同一个8B/align4 explicit-mask `ClosureVar` storage；均无`source_depth`，dynamic-env与eval seed按表序first-match；finalize仍dup atom而非move owner | **row语义/物理完成并冻结**；剩余仅是 M-FB-COMMIT-TRANSFER 的ownership，不得重新拆成两个record |
| VarKind raw encoding | QJS固定`normal..function_name=0..4`、private field/method/getter/setter/getset=`5..9`、global function decl=`10` | zjs在5插入`class_static_this`，private kinds变6..10、global function decl变11；enum名相同不代表row bits相同 | W1b2显式赋QJS数值0..10，把临时`class_static_this`放未用11并锁raw bytes；W1d删除临时kind。不存在serializer不是允许final row编码漂移的理由 |
| eval身份位 | final FB只有`is_direct_or_indirect_eval`，只属于eval编译单元；nested function不继承。该位供global declaration configurable行为及script/module-name frame跳过 | final FB和mutable root view已使用combined bit；script=false、direct/indirect=true、indirect中的nested=false。`eval_global_var_bindings`已改为L0入口事实，不再冒充nested FB属性；root closure2仍由runner布尔驱动 | **字段与传播范围完成**；W1b5 canonical root、W1c1 closure2后让global-declaration construction消费该bit，并把入口布尔降为调用断言后删除 |
| entry capability | final FB保留`new_target/super_call/super/arguments_allowed`四位；实际this/arguments/var environment由vardef/closure topology体现 | `EntryContract`另存var_environment、两个binding bit和四个capability bit | 当前显式contract正确地移除了undefined-current-function语义哨兵，但只是迁移脚手架；real root+final vardef后逐项删减，保留项必须有QJS外的真实consumer理由 |
| final flag集合 | QJS FB有单一`js_mode:u8`和两字节bitfield。ordinary compiler把STRICT写入FB；虽然`JS_MODE_BACKTRACE_BARRIER`定义在同一mode命名空间，当前`JS_EvalInternal`只在调用期间临时改`current_stack_frame->js_mode`，不把它写入FunctionDef/FB。其余final bits为prototype/simple-params/derived/home/kind、四个capability、`has_debug/read_only_bytecode`和combined eval | zjs当前把strict/backtrace拆进自己的packed flags，但全仓没有把FB `backtrace_barrier`置true的producer；`runtime_strict_mode`是公开host policy扩展；zjs无binary-bytecode/ROM reader，debug则由nullable box隐式表达；`is_arrow_function/is_class_constructor/has_eval_call`、EntryContract三类字段及`from_block`仍是迁移/存储事实 | W1b6删除零producer的FB backtrace位与view consumer；若未来暴露对应host flag，必须像QJS一样归entry/current-frame policy。W1c4建立QJS `js_mode` byte并只为真实FB producer提供accessor；ROM mask位置在raw flag byte中保留为固定零hole，但不伪造reader/API。runtime-strict在W1b3c变为finalize-time compile policy，再作为documented product extension裁决placement；arrow/class/eval-call随W1c1/W1d删除consumer；fixture统一builder后`from_block`在W1c4删除，独立artifact block只以临时extension base owner过渡到W1c5 |
| arrow/class身份 | lexical this/new.target/home来自closure；constructibility/class发布来自function object constructor bit及`define_class`路径，final FB只保留derived bit | final FB和兼容view持久化arrow与普通class-constructor位，call/construct/eval多条热路径读取 | closure side-channel清除后审计删除；禁止先删bit再用调用点布尔补回 |
| realm所有权与调用上下文 | `js_create_function` finalize时`b->realm = JS_DupContext(ctx)`；bytecode/native call在preflight后令`ctx=callee realm`，closure2不首次绑定；native/AUTOINIT/job/FinalizationRegistry也独立dup context | zjs final FB的global header初始null并由首closure写入；native/AUTOINIT及大量object payload仍用borrowed global registry；现有core Context又混合realm、执行与embedding state，random/modules在Runtime，job无enqueue realm | **global token与未拆分host Context都不是QJS等价owner**；先拆出GC/refcount `RealmContext`和pointer-sized `RealmRef`，再对齐state/carrier/call phase及每个FB finalize retain。异常槽/当前栈属于QJS Runtime execution state，不误搬进realm |
| finalization所有权 | var/closure atom IDs、cpool values、func/filename/source/pc2line在成功路径move进FB；FunctionDef backing arrays释放但不再释放元素 | zjs逐元素dup atoms/values并copy source/pc2line，随后teardown原owner；`gc.addInitializedWithSize`虽保留error-union签名，当前intrusive-list/accounting实现没有allocation或实际error producer | 先完成全部真实fallible allocation/validation，再进入no-fail commit并清空source slots；把FB publication在类型上收紧成专用no-fail initialized-add，不能伪造“registry reserve OOM”。该候选与pack分开测 |
| 终止控制流 | production script/eval/function/module都有可见return，final code长度就是可执行长度 | root/direct/indirect eval及goto-to-end仍可fall off到不可见`op.return`；FB和mutable root都保留`+1` | 先补QJS式显式return与reachable-falloff validator，再移除sentinel；hand-authored fixture单独修，不允许生产VM依赖测试安全垫 |
| root产物 | script/direct/indirect eval compile结果是单一FB value，进入`js_closure2`后调用 | `parser.Result`仍拥有可变裸`Bytecode`；child才是FB；root frame临时建refs | final artifact契约完成后，把Result改为canonical root FB；迁移中若短期需要adapter，只能是栈上borrowed view，不能复制第二份mutable root |
| execution view | VM直接从`JSFunctionBytecode*`读code/vardefs/cpool/closure table；attach FB不分配 | FB懒建并缓存一个约300B heap `Bytecode` view；`setFunctionBytecodeValue`在capture前强制分配它，root又直接拥有另一种`Bytecode` | W1b5先形成canonical root，W1b6再逐consumer让VM/frame直接读FB并删除cached view；迁移patch只可用非逃逸borrowed adapter，阶段出口attach无分配、cached-view reader为零 |
| cached-view派生事实 | QJS call直接读FB基础flags/counts并走统一frame机制；module身份属于module record/调用入口，隐式`arguments`由resolver建立pseudo local；没有zjs的simple/snapshot/empty/exact-args/capture-leaf分类 | `makeBytecodeView`除字段别名外，还扫描code/closure生成`is_global_var`、`has_mapped_arguments`和多组leaf-call eligibility；其中`codeRescuesImplicitArgumentsViaGetVar`及两个global handler分支是显式非QJS补偿 | direct-FB前逐项裁决：便宜派生项改读canonical owner；先证明final code中`get_var(arguments)` producer为零，否则修resolver，再删rescue；leaf分类按最新direct-FB基线重做paired A/B，仅有仍成立的Zig/LLVM证据才可压入header保留字节，禁止保留heap view、per-call scan或无文档extension |
| closure attach引用 | `OP_fclosure`/eval/module入口先取得一份owned bytecode value，`js_closure2`把该引用直接转入function object；capture array失败由object teardown释放它 | `pushFunctionClosure`当前owned `constants.get` → attach前再dup → 返回后free，形成attach-local refcount往返 | 建立显式`attachFunctionBytecodeOwned`/owned closure2 core：成功消费且转移一份引用、失败恰好释放一次；borrowed调用者只能在外层显式dup，不能把dup藏回attach helper |
| closure2顺序 | final class/prototype object→attach FB→zero final slots→eval pass1→one-pass fill→length/name/prototype/home等发布 | nested object在capture前复制import-meta/private/arrow/class-field适配器并定义length/name；root还没有对象 | real root和nested共用一个closure2核心；所有非必要发布后移，旁路优先改成bytecode/closure事实 |
| plain var-ref write | `put_var_ref{0..3}`/generic只是`set_value`；非法const/function-name写已在resolver发`throw_error`或drop | `execPutVarRef`每次又读ClosureVar和cell flags裁决const/function-name | 先用final-bytecode矩阵证明所有写形态，再删除热检查；未证明前不得为benchmark直接删 |
| ordinary GLOBAL | lexical VARREF→global AUTOINIT materialize/retry→global VARREF→shared uninitialized cell | 三个root/nested/direct-eval consumer都缺AUTOINIT retry | one-pass后共用一个waterfall helper；不重写已对齐的GLOBAL_DECL descriptor surgery |
| module slots/link | module function先于dependency创建；imports在closure array中可暂时null并按index链接；精确phase/SCC rollback | file module重复compile、name驱动parallel cells、非空pointer数组迫使adapter、phase/error order不同 | persistent artifact之后再做optional staging/indexed link；“Zig slice非空”不是偏离理由 |
| 无runtime消费者的metadata | final FB不保存call-site预测表 | zjs曾生产/重映射`DirectCallSite`，但全仓没有reader | 本候选已删除producer和维护链；不得为了“将来优化”把dead metadata塞回FB，未来需求先提交consumer与A/B证据 |

final flags / cold metadata 的 disposition 固定如下，后续改动必须更新“owner + consumer”，不能只看字段数量：

| zjs事实 | QuickJS对应 | 当前裁决 |
|---|---|---|
| `is_strict_mode` | `JSFunctionBytecode.js_mode & JS_MODE_STRICT` | W1c4物理放入一个`js_mode:u8`，原名只作为accessor，不保留平行storage |
| `backtrace_barrier` | QJS的mask属于stack-frame mode；当前eval API临时set/restore caller frame，ordinary compiler没有对应FB true producer；binary reader会原样读取generic `js_mode`，属于未来reader契约 | zjs当前无reader且FB位没有true producer；W1b6连同compat-view reader删除。未来host能力只能落entry/frame transaction；未来binary reader另审计accepted mode bits，二者都不能为当前dead FB bool续命 |
| prototype/simple-params/derived/home/kind、四个grammar capability | 同名final bits | exact，保留 |
| `is_direct_or_indirect_eval` | 同名combined bit | exact；已锁script/direct/indirect/nested范围，W1c1接管construction consumer |
| `has_debug`及strip-source/strip-debug policy | QJS runtime strip flags决定optional debug header、source保留和部分row atom ownership | zjs当前production始终full-debug且没有strip producer/API；W1c3只迁现有ownership，W1c4设置byte18 bit2并断言`has_debug ⇔ 32B debug tail present`，fixture可显式no-debug。strip功能另立未来兼容项，不进入本轮收益或出口 |
| `read_only_bytecode` | QJS binary reader的ROM模式让`byte_code_buf`直接借输入buffer，主allocation不含code bytes，memory accounting也不计code；ROM与非ROM两路都会dup内嵌atom并在FB释放时free atom ref | zjs当前没有binary bytecode reader/ROM producer；登记为缺失能力，不添加可读写状态/API，也不把它误写成atom ownership开关。W1c4仍须把byte18 bit3作为固定零的QJS物理hole，保证后续combined-eval仍在bit4；这不是伪造能力 |
| `runtime_strict_mode` | 无；zjs host API可在不改变parse grammar时强制escaped nested function的runtime strict行为 | deliberate product extension，必须留在可逃逸function事实上；当前`eval_entry.forceRuntimeStrict`在finalize后递归改child FB，先于direct-FB改成compile policy递归传入、每个FB发布前一次初始化并删后置mutation。再审计它能否归entry/function object或折入既有严格事实，确需FB hot bit才使用明确登记的byte18 spare/extension，禁止占QJS `JS_MODE_ASYNC/BACKTRACE_BARRIER`位。它不算Zig限制，也不纳入QJS性能收益 |
| `script_or_module`（独立于diagnostic filename） | 当前QJS沿stack frame跳过eval FB，取首个non-eval FB的debug filename；源码也承认这只是ScriptOrModule近似，strip-debug时明确返回null | **W1d裁决为保留documented product extension。** escaped direct-eval函数可在caller frame退出后继续存活；其dynamic import仍须以原caller module路径作referrer，而异常栈诊断仍显示`<eval>`，故diagnostic filename/frame不能替代该identity。Canonical FB保留exact-code-end处8B Hot（`CallFacts + ScriptOrModule`）；只声明QJS core/table/code offset exact，total allocation必须表述为“QJS-order core + documented 8B product extension”，不得称QJS total exact |
| `is_arrow_function`、普通`is_class_constructor` | QJS由lexical captures/function object class与constructibility表达 | W1d迁移consumer后删除，禁止换成call-site布尔 |
| `has_eval_call` | QJS仅在FunctionDef阶段用于capture与strip-var-debug裁决；final不保存 | 本轮只保留capture consumer；W1c1让eval object直接拥有arguments/captures后删除FrameCold cache并从FB删除。zjs尚无strip producer，不为未来strip names把该事实带入final bit |
| `var_environment/has_arguments_binding/has_this_binding` | 由final vardef/closure与真实entry function表达 | EntryContract迁移脚手架；W1c1/W1d逐consumer退场 |
| `from_block` / 独立artifact block owner | QJS单allocation天然确定ownership | W1c4让production/fixture builder都建立同一种独立block owner，删除`from_block`双析构位，并把唯一`artifact_block_base`暂放extension；W1c5合并FAM后删除base owner和旧block allocation |
| `class_meta/class_fields_init`及其他过渡side facts | QJS core header无对应pointer | 当前工作树已删除`ClassMeta`、FunctionDef/Bytecode的`private_bound_names/class_private_names`、object/function private remap、ordinary class carrier、arrow/static runtime side channel及canonical `FunctionBytecodeSideExtension`等finalization/final/runtime carrier；相关语义已回到lexical capture和真实class-initializer child。`Parser.State.class_private_elements/class_private_bound_names`仅作为grammar/early-error/direct-eval parse临时表保留，不进入FunctionDef/Bytecode/FB/object/runtime。Legacy stack adapter仅保留固定`0x68` borrowed-pointer尾槽；canonical allocation止于`code_end + 8B Hot`，这里关闭的是Side而非上行已裁决的product extension |

### 1.7 物理布局、所有权和终止路径的二次证据

仅看 `@sizeOf(FunctionBytecode)==128` 会得到错误结论。对 pinned diagnostic qjs 与当前 Debug zjs
binary 的 DWARF 做同架构查询后，事实是：

| record | pinned qjs | 当前 zjs | 裁决 |
|---|---:|---:|---|
| closure row | `JSClosureVar` 8B/align4 | compile/final共享`ClosureVar` 8B/align4 | W1b2 C/Zig masked raw golden已锁定；保持holes归零与accessor唯一读写入口 |
| final vardef row | `JSBytecodeVarDef` 12B/align4 | `BytecodeVarDef` 12B/align4 | W1b2已锁`var_name@0/scope_next@4/flags@8/pad@9/var_ref_idx@10`及uncaptured zero |
| final FB header | full-debug `JSFunctionBytecode` 128B/align8；strip-debug base到`debug@0x60`即96B | `FunctionBytecodeImpl` 128B/align16且总有DebugInfo pointer/box | 相等只是假象：zjs有`cached_view/class_meta/class_fields_init`等额外pointer，热字段offset不同；`header align(16)`还把GC prefix从8推到16并绕过align8 slab。W1c4先定96B base + optional 32B debug tail/align8与稳定offset，把尚未消除的非QJS事实移到不改core offset的optional extension；W1d后才裁决total allocation exact-close |
| compile-only records | `JSVarDef` 20B、`JSGlobalVar` 16B、`JSFunctionDef` 576B | `VarDef` 24B、`GlobalVar` 20B、`FunctionDef` 608B | 作为construction profile的次级证据；没有direct allocation/scan热点前不扩大战役 |

QJS FB 的关键offset为 bytecode `0x18`、vardefs `0x28`、closures `0x30`、realm `0x48`、cpool `0x50`、
debug metadata `0x60`。zjs nominal 128B header内部则先承载cached view和class side pointers；因此后续不能只用
总大小验收，必须同时看offset、执行期load chain和assembly。Zig默认struct重排不构成“无法对齐”：可用
`extern` core record、显式mask的flag bytes及optional tail；不能假设Zig `packed struct`会自动复刻C实现定义的bitfield
落位，必须用pinned toolchain下的raw flag-byte golden、field offset和accessor测试锁住。zjs自己的`GCObjectHeader`和`Object`已经以align8工作，当前
FunctionBytecode的16-byte对齐只是字段排序补偿，不是GC/pointer-tag硬约束。只有实际编译器/ABI反例才能升级为Zig限制。

pinned qjs的`gdb ptype /o`还给出不能省略的**内存位契约**：FB byte17依次是prototype bit0、simple-params bit1、
derived bit2、home bit3、kind bits4–5、new-target bit6、super-call bit7；byte18是super bit0、arguments bit1、
debug bit2、ROM bit3、combined-eval bit4，bits5–7与byte19–23均为空洞。`JSClosureVar`的byte0是type bits0–2、
lexical bit3、const bit4，byte1低4位才是VarKind，随后`var_idx@2`、`var_name@4`；`JSBytecodeVarDef`则是
`name@0/scope_next@4/flags@8/pad@9/var_ref_idx@10`，flags为const/lexical/captured/has-scope bits0–3与
VarKind bits4–7。optional debug tail也不是抽象box：`filename@0x60`、`source_len@0x64`、`pc2line_len@0x68`、
4B zero pad、`pc2line_buf@0x70`、`source@0x78`，两个length均为i32。W1b2/W1c4的golden必须逐byte/mask/offset
写出这些位置，不能只锁`@sizeOf`。

这套**内存位契约不等于QJS binary-bytecode wire格式**：writer把vardef的VarKind放wire低4位后再写四个bool，
closure wire又以type→const→lexical→kind编码；ROM身份也不在serialized function flags中，而由reader mode注入。
zjs当前没有reader/writer，W1b2只能对齐in-memory storage，禁止照抄`bc_set_flags`顺序或为测试临时造serializer。
C padding同样不是可读契约：header/vardef因`js_mallocz`可验证为零，compile `JSClosureVar`却未memset且整row memcpy，
其hole可能不定。C probe应先zero fixture或只比较defined masks；zjs显式storage统一zero holes，但不得把未初始化C padding
纳入full-row byte equality、hash或性能结论。

另一个值级差异已经随W1b2封闭：QJS `add_var/add_arg`先memset，未捕获vardef由`is_captured==0`判别，
其未使用`var_ref_idx`为零；zjs final row现同样规范化为零，final consumer只读`is_captured`/checked accessor，
`0xffff`只存在于compile-only `VarDef.open_binding_idx`。后续不得把compile sentinel重新穿过final boundary。

QJS的`vardefs/closure_var/cpool`在对应count为零时保持`NULL`；zjs当前`noSlice()`用一个非空dangling address代替。
optional many-pointer或C pointer应先以`@sizeOf/@alignOf`证明仍是单word后采用，建立`count==0 ⇔ ptr==null`的raw-header
invariant；“Zig slice不能为null”不是保留非空哨兵的理由。

raw producer审计也改变了实施边界：当前production只有`createFunctionBytecodeAfterChildren`直接分配FB，仓库其余
`alloc(FunctionBytecode)+FunctionBytecode.init`全部是嵌在各子系统里的GC/ownership fixture；native builtin使用独立
function-object/internal-callable表示，与QuickJS的C function class一样，不是“synthetic FB”特例。变长header落地前必须
提供一个fixture-only builder，迁移所有手造测试并删除by-value `FunctionBytecode.init`；production只允许finalizer调用唯一
raw builder。阶段出口用语法/AST感知检查（不是会把test误报为production的裸`rg`）证明没有第二个生产入口。
仓库已有的`MemoryAccount.createWithFam/destroyWithFam`正是这一对象所需的GC allocation primitive：96B base作为固定`T`，
optional debug/table/code/extension都属于FAM bytes，才能继续得到8B metadata prefix、slab资格和正确accounting。普通
`allocAlignedBytes`会绕过GC prefix，禁止作为替代；allocate/free两边的FAM byte count都必须来自同一个`FunctionLayout`。
`createWithFam`本身不清payload，而QJS调用`js_mallocz(function_size)`；唯一builder必须把完整base+FAM payload清零后再填充，
不能只zero header或只初始化会读到的字段来制造偏离reference的allocation收益。

QuickJS 当前实现的allocation topology也必须按源码而不是注释愿望复刻：`js_mallocz(function_size)`包含
header、可选inline debug metadata、cpool、vardefs、closures、bytecode；`source`和`pc2line_buf`仍是两个独立
owned buffer，只在finalize转移指针。zjs当前把两者复制进trailing block，不能把这个更大pack称为QJS exact。
同理，W1d之前仍活跃的class/import/arrow/ScriptOrModule事实不能继续占QJS core header却把中间态叫“exact”：
W1c4只冻结**QJS header layout**并把非QJS事实放header后extension；W1c5才形成QJS-order core pack并把extension搬到
exact code后，全程不得移动core/table offset。W1d清理后再做total-size/extension-presence的exact-close。这样
core-close后的hot load chain不会因W1d再次重排。

“exact”还必须绑定value representation：默认64位zjs与pinned qjs均为16B payload+tag JSValue，只有该目标的cpool
stride及后续table offsets可做raw byte exact断言。项目要求保持的8B NaN-boxing alternate build使用同一QJS顺序、nullable
pointer、checked layout和ownership公式，但其cpool stride天然不同；它是documented product portability configuration，
只声明semantic/owner/order alignment，不拿同一个pinned qjs二进制虚报total byte exact。W1c5因此必须同时跑default exact
offset golden与alternate representation安全门禁。

`pc2line_buf`的**字节契约**也不同：QJS先编码起始`line-1/column-1`两个ULEB128，随后才是增量；zjs把
起始坐标放在`DebugInfo`/view字段，buffer只含增量。它必须在ownership/pack前单独对齐，否则即使allocation
形状相同，header字段与debug consumer仍不是同一机制。full-debug producer因此至少有两个header byte；空buffer只能是
strip-debug或malformed/legacy输入，不能作为正常full-debug artifact。QJS **ordinary compiler**经`js_strndup`保存的source
allocation还包含末尾NUL而`source_len`不含它；zjs应在ordinary source producer处建立同一`len+1` owner后再move，不能在
finalize重新copy来伪装转移。QJS binary reader当前另按wire `source_len`分配，未来若实现reader必须单独审计，不能把该路
反推成ordinary compiler无需NUL。

所有权同样是独立机制。QJS先完成child finalize、resolve、stack size和主allocation等fallible步骤，再把
vardef/closure atoms、cpool values、func/filename atoms、source/pc2line和bytecode atom ownership移入FB；成功路径
没有“dup全部元素→销毁FunctionDef时再free全部原元素”的往返。zjs必须先完成所有真实fallible allocation、layout验证与
side metadata准备，再进入清空source slot的no-fail commit；当前intrusive GC publication没有allocation/error producer，
应把FB专用调用在类型上收紧为no-fail，而不是为它虚构reserve/OOM路径。否则只是用OOM顺序换取少几次refcount操作。

最后，当前`code[len] = op.return`不是fixture防护，而是root/direct/indirect eval完成值和branch-to-end的生产语义。
QJS则由parser显式发script/eval的`get _ret_; return`及module/function的`return_undef`，final pack没有额外byte。
所以删除sentinel之前必须先让每条production CFG显式落到return，并让stack/finalizer拒绝reachable falloff；测试手写
bytecode可补显式terminator或走fixture-only checked runner，不能继续让不可见字节进入生产artifact。

这次复审后的边界是：**FunctionDef拓扑、ordinary/parameter final table语义和W1b2 record物理布局已经封账；realm
state与全部owner carriers、显式terminator、canonical root、direct-FB/closure2、pc2line格式、move commit、QJS-order core pack与
W1d内的total exact-close均未封账；
EntryContract仍只是安全迁移脚手架；cached view中的arguments-rescue/leaf分类也尚未逐项裁决。** static field高位只在W1d随真实child机制删除，不能让它无限阻塞ordinary
core，也不能据此宣称全部final artifact已经同构。

final-bytecode最小证据也重新跑过：
`function outer(){ const x=1; return function(){ x=2; } } outer()();`在diagnostic qjs的最终child中为
`push_2; dup; throw_error x,0`，zjs为`push_2; throw_error "x",0`，两边都没有`put_var_ref`。
这证明“非法写由compiler裁决、plain put只set_value”是正确目标；它只覆盖一个capture形态，不能替代
§5矩阵，因此当前仍不授权直接删除`execPutVarRef`检查。

### 1.8 Realm/context 与 owner carrier 的第三次复核

把`realm_global_header`提前写入FB仍然不够。pinned QuickJS的`JSContext`同时是realm state和可被
`JS_DupContext`持有的owner，但其**当前异常槽、当前stack frame、job FIFO与module loader hook在`JSRuntime`**。zjs现有
core `JSContext`把realm、执行和embedding facade揉在一起，不能原地给整块struct加refcount；现有global上的`RealmPayload`
又只覆盖部分state，也不能升格成context identity。更忠实的做法是先拆出GC/refcount `RealmContext`，让公开JSContext owner handle
只拥有一个RealmRef；Zig模块分层只影响callback facade的类型形状，不改变realm identity/owner拓扑。callback统一拿underlying
RealmContext的typed borrowed view；若为保留方法式public API必须有facade，它只能是RealmContext内同寿命固定成员，不能是独立
wrapper、`anyopaque`或per-call temporary。全仓`JS_DupContext`除函数定义外只有六个现役调用点：job、
C_FUNCTION、AUTOINIT、ordinary compiler发布FB、binary reader发布FB与FinalizationRegistry；`:38939` reader只是同一FB owner的
第二producer，而zjs当前没有reader，所以不另造本轮feature，未来reader必须复用同一RealmRef/raw-builder契约。相反，
`JSFunctionDef/JSParseState/BCReader/BCWriter/array-sort/ValueBuffer`里的`JSContext*`都被同步调用树或栈frame包住且无dup/free，
只能映射为typed borrow；不能因“struct里存了ctx”机械加RealmRef。逐个carrier及
析构点复核后的契约如下：

| 状态/owner | pinned QuickJS | 当前 zjs | 收口裁决 |
|---|---|---|---|
| realm identity与生命周期 | `JSContext`是GC/refcount owner；GC header与Runtime context-list link互相独立，global、global lexical、intrinsics、class prototypes、random和loaded modules都由它拥有 | core/host Context不可逃逸持有，`$262.createRealm()`只创建global+`RealmPayload`；Context只有RootProvider登记而没有GC kind/context list，job/native因此只能借pointer | 新建header-first `RealmContext`作为唯一GC/refcount identity，另带独立runtime context link；pointer-sized `RealmRef`只是typed owner handle。公开JSContext handle own一个default ref，`$262.createRealm()`创建真正RealmContext。现有RealmPayload可并入/附属于该owner，但不再充当identity |
| global object identity/payload | global是`JS_CLASS_GLOBAL_OBJECT`，与Context state storage分离；但`JSGlobalObject.uninitialized_vars`确实属于global payload并由其mark/finalizer管理。AUTOINIT global→VARREF及global exotic只读class identity | `Object.isGlobal()`等价于`class_payload_kind == .realm`，同一RealmPayload混装global lexicals、uninitialized vars、intrinsic/template cache和alias cache | state迁出前先建显式global-object class/flag并按字段split：uninitialized-vars留在global class payload；global lexical与intrinsics迁RealmContext；alias cache删除。AUTOINIT/global exotic/closure selector只读discriminator。阶段出口无“为identity留下的空RealmPayload”，普通对象也不能因附属cache误变global |
| runtime execution state | `current_exception`、uncatchable/OOM recursion flag和`current_stack_frame`在`JSRuntime` | exception/backtrace、call depth及active native state分散在Runtime与host Context | 不以“realm对齐”为名迁移异常/栈；先按并发/嵌套执行契约裁决它们的runtime或stack-local owner。realm切换只改变intrinsic/global/module等可观察来源 |
| FB/C_FUNCTION/AUTOINIT/FinalizationRegistry | FB finalize/reader、`JS_CLASS_C_FUNCTION`、每个AUTOINIT property和FinalizationRegistry construction各自`JS_DupContext`；各自析构free并GC mark。`JS_CLASS_C_FUNCTION_DATA`反而只own captured values并沿用caller context | FB只在首closure后强持global；native/AUTOINIT/FinalizationRegistry及大量payload保存borrowed global并依赖cleanup registry，内部data-callable与builtin又未按QJS class边界分类 | RealmRef落地后按真实carrier分别retain/release/trace；C_FUNCTION与FB是callee realm carrier，C_FUNCTION_DATA等data-callable按captured-values/caller语义作control。禁止把所有native/ordinary object一刀加owner，也禁止borrowed registry模拟escaped C_FUNCTION lifetime |
| runtime传递性root与embedding handle | runtime `context_list`只枚举且不own base ref；Context的GC mark来自**另一条**`gc_obj_list→mark_children(JS_CONTEXT)`。realm-specific class prototype在Context。C API的JSValue/context owner必须先于`JS_FreeRuntime`释放 | runtime root-provider列表借core Context地址，但只被external RootVisitor路径消费；`MethodRuntime`又通过`JSValueHandle`强持安装realm prototype。反向的公开`JSObject.Binding`只借raw prototype且无lifetime；destroy当前会主动clear handle slot | 把context GC child edge、runtime context enumeration与host root-provider三种关系分开。root census继续沿`Runtime field→opaque ptr/root slot→JSValue→C_FUNCTION/FB→RealmContext`追传递边；MethodRuntime删除prototype handle，Binding改live-slot borrow/显式OwnedBinding。公开owner必须先释放，Runtime不能静默失效 |
| 非carrier对象上的realm | ordinary/Promise/RegExp/arguments/typed-array/VarRef/module namespace等对象没有通用context字段；generator resume经`frame.cur_func→FB`，bound/proxy在caller中处理后递归target，Promise reaction使用触发时enqueue context | `borrowedRealmGlobalPtr`覆盖generator、Promise、RegExp、typed array、arguments、ordinary object等十余payload，并由runtime cleanup registry清悬空pointer；普通namespace/prototype还替其AUTOINIT slot提供realm | carrier完成后做M-REALM-NONCARRIER-RETIRE：每个reader改回active caller、最终call carrier、current function、job、AUTOINIT slot或prototype/constructor来源，再逐类删producer/slot。只删除borrowed-holder的realm匹配/注册职责；WeakRef/weak collection/FinalizationRegistry cell所需真实weak-edge registry必须保留或重命名，不能整表删除 |
| AUTOINIT property-list域 | low bits只有PROTOTYPE/MODULE_NS/PROP；PROP builder只覆盖C function/string/object。accessor、数值常量和alias在`JS_SetPropertyFunctionList`安装期完成，alias读取已安装source后定义同一value；第二word为static entry/null/module的direct opaque pointer | `AutoInitKind`把accessor、number/int常量与alias共享cache也延迟；`AutoInitRef{rt,id}`/descriptor还混有runtime lookup、整数realm token与mutable cache slot | W1b3d1先建producer分类表：只有三个QJS ID进入slot；eager类别在bootstrap用realm-aware C_FUNCTION constructor/normal value发布。standard descriptor改direct typed pointer，dynamic host descriptor给stable owner；删除alias cache、runtime-ID lookup、descriptor realm/global token和mutable materialization state |
| job与FIFO | runtime只有一个FIFO；每个`JSJobEntry`在enqueue时dup realm，执行/释放都用该realm；`JS_ExecutePendingJob`每次只执行一个并以三态返回，异常停止；dynamic import使用entry ctx；Promise、dynamic import和FinalizationRegistry走同一排序域 | generic job保存裸`*JSContext`且`Queue.runAll`连续执行/释放result；Promise job在context slice，Finalization job在runtime slice，后二者只靠sequence归并。两种DynamicImport state callback还忽略传入ctx | 统一runtime FIFO entry的owned RealmRef+typed payload，并建立唯一run-one cleanup/status transaction；host loop可重复调用，但首个exception必须停止且保留后续entry。dynamic-import handler/loader只用entry ctx，state不得成为realm authority；host event-loop work若非ECMAScript job保持明确adapter |
| call phase与函数realm解析 | bytecode/native的object-callable判断、arg/stack sizing和stack-overflow preflight使用caller context；frame准备后才切`b->realm`/`cfunc.realm`。C_FUNCTION的constructor-cproto “must be called with new”却在切换后判断，使用callee。bound/proxy class-call自身仍接收caller：先完成bound argv/Proxy trap工作，再递归target；C callback只有ctx，global由`ctx->global_obj`唯一确定。`JS_GetFunctionRealm`只服务四类fallback/comparison | 多处以`call.global orelse functionRealm...`混合caller fallback，bound/proxy复制独立borrowed realm；`ExternalCall`又把ctx/global作为可撕裂的两项传递 | 建立一个带caller参数的递归FunctionRealm resolver但不拿它提前切实际call；除四类QJS consumer及明确public query adapter外无reader。bound/proxy不own第二个realm，wrapper/trap阶段沿caller，只有最终bytecode/C_FUNCTION arm原子切`active RealmContext + global_obj/global slots`。若保留ExternalCall.global兼容字段，它只能是同ctx global的borrowed alias，不能成为realm authority或fallback链。测试分别锁preflight caller、body callee、trap realm、sloppy-this、ctx/global pair及三臂Array species |
| intrinsics/eval/class prototype | `eval_obj`、`class_proto[]`、`function_proto/function_ctor/array_ctor/regexp_ctor/promise_ctor/iterator_ctor`、`async_iterator_proto/array_proto_values/throw_type_error/native_error_proto[]`均为context state | `eval_function`和dynamic class-prototype slots在共享host Context，alternate realm主要靠global上的tag/cache补偿；`RealmPayload.shared_lazy_native_functions`又替alias identity保留额外cache | 全部真实intrinsic state移入RealmContext；现有RealmPayload若保留只能是其唯一owned storage，不能继续挂global反查。alias shared cache不随state迁移，先由W1b3d1按QJS eager alias删除；direct eval identity及iterator/string/collection prototype cache不得跨realm共享 |
| embedding custom class ID/definition/prototype | `JS_NewClassID`在Runtime之外给static caller slot分配稳定id；每个Runtime分别注册definition。注册增长先把全部live Context的`class_proto[]`扩到统一class-count，新槽为`JS_NULL`。class record发布后，`JS_SetClassProto`独立consume任意JSValue、`JS_GetClassProto`返回dup；`JS_NewObjectClass`创建对象时才把slot中的object当prototype，其他tag按null prototype处理，并把结果固化进shape。ID、Runtime definition、Context slot和既有object是四个lifetime | binding `JSObject`已近似per-context owner，但`Table.next_dynamic_id`让ID随Runtime/安装顺序变化并支持unregister；注册未同步扩全部Context，setter又dup raw object。plugin的`InstalledPlugin.host_classes[].prototype`绕过ctx slot；高层binding另以`NotInstalled`拒绝未安装realm | W1b3a先审public/plugin ID是否跨Runtime；无已发布阻碍则对齐stable global ID+per-Runtime registration，不能把Zig当理由。再建立all-live/future capacity与`takeClassPrototype(JSValue)/getClassPrototypeDup/borrow`，分别发布definition和construction slot；如public binding只接受object，须保留为具名高层校验，不能反写成QJS low-level契约。Runtime-local ID或unregister若保留必须命名扩展、禁止ID跨Runtime/重用并单测；plugin多class rollback仍是上层transaction。null-slot/core、NotInstalled/high-level、shape旧对象、slot release与definition unregister分别验收 |
| initial shapes/templates与Array proto guard | Context直接own `array/arguments/mapped_arguments/regexp/regexp_result`五个Shape ref；构造时dup shape并以stack props初始化值，不创建“只为钉shape”的JS template object。Runtime shape hash只是borrowed intern index。初始Array.prototype另带`is_std_array_prototype`及精确失效协议 | zjs shape hash同样不retain，但RealmPayload用`regexp_instance/match_result`、mapped/unmapped arguments等完整JS template object间接钉shape+默认值；`iterator_result_template`还是QJS没有的product cache。数组写另用runtime-wide sticky guard | M-REALM-INITIAL-SHAPES先逐slot分类：五个QJS对应项默认改为RealmContext direct Shape owner+typed initialization data，删除仅作layout carrier的template JSObject；不能因现有helper方便就称Zig限制。真正zjs-only template另列product optimization并独立裁决。随后M-ARRAY-PROTO-GUARD镜像realm-local publication/invalidation与O(1) direct-proto资格，不把两项收益混账 |
| random/OOM | random state在context；`JS_ThrowError2`按当前callee/caller phase的`ctx->native_error_proto[InternalError]`构造，分配失败时throw `JS_NULL`；Runtime只存`in_out_of_memory`递归guard，**没有**预制Error对象 | random与单个preallocated OOM Error在Runtime，后者来自首个bootstrap global；`oom_cap`门禁另外要求fully-exhausted catch仍得到InternalError-shaped object且delivery零分配 | random移为per-realm。为保留这项既存zjs OOM-cap contract，可保留per-realm fallback，但必须用active realm的InternalError prototype构造并明确登记为failure-path safety adaptation，不能列作QJS Context字段。正常可分配路径仍新建Error；仅fully-exhausted fallback可能复用同一对象、无stack，其identity/mutation差异必须明确而不得冒充QJS。bootstrap/递归路径只用runtime-neutral sentinel，不借首realm |
| modules | `loaded_modules` list/base ref属于Context，`JSModuleDef`自身**不**dup context且finalizer可从list unlink；module normalize/load hooks属于Runtime | `module.Registry`属于Runtime，同一specifier会跨realm共用record | W1e把registry/list owner迁为RealmContext，但不给每个record额外RealmRef；record/function/job各按QJS既有owner链存活。之后再做persistent artifact/indexed link；此前不能声明完整context/module exact |
| host/eval hooks | `compile_regexp`、`eval_internal`与context opaque在Context；module normalize/load callback/opaque在Runtime且每次接收job ctx | dynamic-import callback/userdata与host event loop在host Context；`DynamicImportState/HostState`混装裸context、stack-scoped continuation lists与loader policy，callback忽略active ctx；builtin eval/regexp安装又主要由global/runtime路由 | ordinary builtin eval/regexp证明active RealmRef正确；d2先禁止loader state替代entry ctx，scoped userdata必须证明队列排空后才restore/free。W1e再把normalize/load policy归Runtime、per-realm continuation/module state归RealmContext/module owner；会逃逸的host policy必须有显式owner，未实现reader hook不反压本轮 |
| binary bookkeeping | `binary_object_count/size`在Context，仅被binary-object memory accounting/reader路径更新；reader创建的FB同样dup Context | zjs没有binary bytecode/ROM reader，也没有对应公开计数contract | 不为struct外形新增未读state；未来reader作为独立feature时把计数与FB RealmRef接入同一RealmContext/raw-builder，本轮只保留负向无producer证明 |
| zjs embedding policy | QJS stack limit、rejection tracker和job scheduler主要是Runtime/host-lib policy；quickjs-libc handler表只own callback values，`js_std_loop(ctx)`由host每次传ctx且loop不dup它 | per-context stack limit override、unhandled rejection state、preserve-uncaught、event loop等是zjs公开扩展并位于host Context；EventLoop保存裸binding wrapper且vtable从core ptr反向cast wrapper | 作为documented HostPolicy归RealmContext或Runtime并保持public API；若保留zjs自包含`runUntilIdle(self)`，EventLoop以一个命名RealmRef补足其存储ctx的lifetime，这是existing-API adaptation，不伪称QJS或Zig限制。vtable直用稳定core pointer，deinit先detach/释放callback roots再free ref；job逃逸后仍需的policy必须owned，纯调用期flag可stack-local |
| legacy `realm_global` API | QuickJS embedding总是传`JSContext*`，无需从任意object反查realm | zjs公开call/property/error/eval/external-function options接受`realm_global: ?*Object`，内部目前借generic object/global resolver传播 | 保持现有public surface的兼容adapter，但只在冷embedding边界从runtime **context list**（或严格同生命周期index）把“调用时已登记RealmContext的exact global object”解析并dup为RealmRef；不得扫描collection期间会移动的GC list或任意RootProvider表。比较前不解引用输入，禁止在global/ordinary payload加反向realm pointer。任意live ordinary/non-global或未登记地址明确报错；裸指针释放后地址复用无法辨旧身份，属于legacy API无效use-after-free，若需强检测必须另给generation handle。VM/exec hot path不得调用adapter |
| interrupt | poll counter属于Context、reset阈值10000；raw Context零填充使首次poll立即进入slow arm并重置，之后callback间隔恰好10000，且无handler时仍持续减/重置；call entry先poll caller context，final arm切realm后body backedge再poll callee context | VM-local `InterruptPoller`按Machine/call重建，budget 1024且只在handler存在时活跃；regexp另有自己的10000 counter | 新立M-INTERRUPT-BUDGET：counter随RealmContext持续，同realm nested call/Machine重建不刷新；跨realm严格区分caller entry与callee body。poll point与budget state分别验收，regexp counter保持独立；它不混进FB/root或tail stack候选 |

对当前`JSRuntime`以及跨Runtime host registry所有能直接或间接碰到JS graph的存储再做一次owner census，避免实现时只执行几个
`rg realm`负向：

| 当前Runtime存储 | 实际owner语义 | 路线图裁决 |
|---|---|---|
| `current_exception` | QJS同样是Runtime execution root；只在当前异常生命周期暂时持value | 保留Runtime owner，不作为FunctionRealm来源；throw/take/clear与teardown顺序照常验收 |
| `internal_destructuring_helpers[14]` | Runtime直接mark/free的永久JSValue cache；对象是内部控制transport，不是用户可见函数 | W1b2.5 M-DSTR-STACK先删除六个dstr producer/record/state；W1b2.6 M-USING-TYPED-CONTROL再删除八个using producer与剩余cache/trace/free。不得给任一项补RealmRef |
| `preallocated_oom_error` | 当前由首bootstrap realm构造的Runtime强root；QJS完全没有该对象，只用Runtime recursion guard、当前ctx error prototype与分配失败时的`JS_NULL` fallback；zjs的`oom_cap`门禁则明确要求fully-exhausted delivery零分配、catchable object及same-context recovery | W1b3a迁成per-RealmContext safety adaptation并单列偏离；正常错误仍按QJS新建，只有fully-exhausted路径可复用该realm fallback。bootstrap/递归路径在fallback可用前只允许runtime-neutral emergency state，禁止回落首realm；测试/注释不得把该对象、无stack或重复identity归因给QJS |
| `job_queue`、`pending_finalization_jobs`及Context `pending_promise_jobs` | ECMAScript deferred work/args本来就是显式root，但当前queue与realm owner分裂；generic `runAll`还把多个job/result压成无status drain | W1b3d2/d3统一Runtime FIFO并让entry/registry分别own正确RealmRef；按enqueue/run-one/drop逐项mark/free，异常停止且后续FIFO保持；禁止由host loop吞result后继续 |
| global `atomics_waiters` / waitAsync heap node | zjs-only host continuation跨runtime共享通知key，却又直接own Promise、裸ctx与deadline；global list本身只应是同步/通知索引，不应成为JS heap executor | W1b3a把node变成命名RealmRef owner；W1b3d2让registry只借node并发布ready，不在foreign thread分配/settle。owner runtime消费typed completion并入FIFO；settle OOM保留node重试，cancel/drain/destroy恰好释放Promise/store/ref |
| `deferred_weak_value_frees`、deferred native/class cleanup | teardown/GC事务期间的临时root或opaque cleanup，不是realm解析器 | 保留其no-fail/reentrant cleanup职责；先drain host finalizer再检查handles/contexts，禁止从stored value反查realm |
| `modules` | 当前Runtime registry强持record/function/cell；QuickJS loaded module identity属于Context | W1e迁per-RealmContext list/base owner；module record不额外dup RealmContext |
| local/persistent/weak root slots与`root_providers` | strong/local slot中的JSValue是实际RC owner，weak slot不是；当前唯一provider只借core Context地址并服务`Runtime.traceRoots` visitor，**不进入**trial-decref child walk；它还经Context转发EventLoop真正host-owned的callback roots | handle按调用方lifetime显式释放；RealmContext-owned child与external host root分成具名visitor surface。provider若保留，只枚举诊断或host-owned edge并随对应owner detach/finalization unlink，不参与RealmContext liveness。Runtime destroy验证零slot/零provider，不主动制造悬空handle，也不把provider冒充RealmRef |
| 新runtime `context_list` | 当前不存在；root-provider表不能可靠替代，因为它可容纳任意host provider，且没有QJS class-capacity/list语义 | W1b3a给每个published RealmContext独立link；只借地址，用于all-live class扩槽、cold exact-global lookup、accounting、Array guard invalidation，以及具名zjs plugin-unload slot cleanup。不得复用GC header links/root-provider，也不得增加base ref；所有mutation要有finalizing/reentrancy规则 |
| `external_host_functions[].ptr` | Runtime只看opaque ptr/finalizer；内部或用户state可能自行持handle/RealmRef。当前`MethodRuntime`直接持handle，plugin `InstalledBinding→InstalledPlugin→HostClass.prototype`间接持JSValue | 内部producer逐state审计；`MethodRuntime.prototype`删除，plugin HostClass prototype迁RealmContext slot并让InstalledPlugin只留metadata。用户通过公开handle持值是命名embedding root，由host finalizer/调用方先释放 |
| `cached_iterator_next_entries` | storage在Runtime，但value edge由对应iterator object拥有、由object mark/free；不是Runtime独立root | 保留前必须锁object destroy/cycle/reentrant clear与entry removal；realm只能来自被缓存的真实function carrier，不能把side table当context owner |
| auto-init descriptor table、class `binding_data`、string/atom caches、weak identity registries | descriptor/runtime metadata或非realm数据；当前AutoInit descriptor例外地混入realm/global token和mutable cache | W1b3d1删descriptor realm/cache并改property-slot owner；binding/runtime opaque state按上行审计；其余不得因存储位于Runtime就机械迁RealmContext |

当前 callable 不能只按“native/internal”二分；下面是 W1b3b 必须冻结的 class/record 映射。左列均已在当前
`InternalCallableTag`、native record 或 fake job callable 中找到producer：

| 当前 zjs callable family | pinned QuickJS class/机制 | realm裁决 |
|---|---|---|
| standard builtin/accessor/external native（含runtime plugin binding）与 `throw_type_error_intrinsic` | `JS_CLASS_C_FUNCTION`；`throw_type_error`由`JS_NewCFunction`创建 | 真C_FUNCTION：construction RealmContext+final Function prototype，独立own RealmRef。plugin回调再按收到的callee RealmContext取其HostClass `class_proto`，InstalledPlugin不另存prototype value |
| binding `JSObject` prototype method / `MethodRuntime` external record | native method仍是真C_FUNCTION；class prototype属于callback的Context，QJS `JS_GetOpaque2`本身只做class-id brand | function own construction RealmRef；callback从收到的稳定callee RealmContext按class_id取得realm-local prototype，不让runtime record再持`JSValueHandle`。当前exact-prototype/realm-local binding由`docs/public-api-contract.md`和tests明确承诺，不伪称QJS语义或Zig限制；先保持API，若改成QJS class-id-only另立兼容裁决 |
| runtime缓存的六个dstr与八个`using` helper function | 解构不是callable class：parser/VM直接用iterator/copy-data opcode栈协议；pinned commit无`using` feature | W1b2.5先删除六个dstr function producer/state并恢复QJS stack/catch-offset/abrupt-close；W1b2.6再让`using`走命名product-extension typed opcode/continuation并删除剩余runtime JSValue cache。两者都不得降级成C_FUNCTION_DATA临时壳 |
| `promise_resolving` | `JS_CLASS_PROMISE_RESOLVE_FUNCTION/REJECT_FUNCTION`专用class-call，payload只own promise/state | caller semantics；不own RealmRef。resolution引发的thenable job在实际enqueue时另own realm |
| `promise_capability_executor`、`promise_combinator_element`、`promise_finally_callback` | `JS_NewCFunctionData`：promise executor/all element/finally thunk与handler | C_FUNCTION_DATA：只own captured values，call/throw使用caller RealmContext |
| `async_generator_resolve`、`async_from_sync_iterator_unwrap/close_wrap` | `JS_NewCFunctionData` | C_FUNCTION_DATA caller semantics；generator/iterator state自身按其真实owner链存活 |
| `async_function_resume` | `JS_CLASS_ASYNC_FUNCTION_RESOLVE/REJECT`专用class-call；resume再经saved `frame.cur_func→FB` | wrapper使用caller；恢复bytecode时由最终FB carrier切realm，不给continuation object加realm |
| `promise_reaction_job`、`promise_thenable_job`与dynamic-import fake external callable | `JSJobEntry{realm, job_func, argv}`，不是JS function object；dynamic-import job及Runtime loader都使用entry ctx | 删除fake C_FUNCTION/object realm；变为M-JOB-REALM-FIFO entry+typed payload，enqueue entry独立own RealmRef。DynamicImport callback不得忽略entry ctx或从state裸context恢复realm |
| Proxy revoker、async-module/evaluate resolving callbacks及Iterator constructor getset等captured helper | pinned QuickJS其余`JS_NewCFunctionData` callsite | 当前zjs逐producer改用同一caller-data class/record；不能因它们不在13个tag中漏审或升级成C_FUNCTION owner |
| `async_disposable_stack_continuation`、`array_from_async_continuation` | pinned commit无对应feature | 作为命名product extension映射最窄的caller-data continuation；若enqueue则realm只属于job entry。无源码对照时禁止默认套C_FUNCTION |
| legacy `c_closure`与零producer `c_function_data` class | QJS没有按名字对应的通用realm carrier；当前`constructFunctionValue`还用`c_closure`复制realm properties | Dynamic Function补偿随W1b3e删除；其余真实producer逐个归caller-data或明确embedding extension。零producer class不能作为“已经对齐”的证据 |

`JS_GetFunctionRealm`的default arm对这些caller-data/专用class一律返回caller；表中只有真C_FUNCTION（含binding method）与bytecode FB属于direct callee
realm carrier，internal-control行根本不是function object。W1b2.5先移除六个dstr callable，W1b2.6再移除八个using callable；W1b3b只负责剩余function/data-class producer，W1b3d2负责三种job-only producer。联合出口必须由清单证明每个对象只有
一个class语义，禁止同一`c_function` class再靠tag决定有时own realm、有时沿caller，也不能继续把job包装成可被用户观察/调用的函数对象。

非carrier补偿不能只按字段名批量删除；下面的reader map是W1b3e的最小完整清单：

| zjs补偿 | QuickJS真实来源 | 退场验收 |
|---|---|---|
| alternate `Function`上的十个`__realm_*_proto` own property、dynamic Function复制与`reflectConstructRealmPrototype`读取 | `js_function_constructor`在Function C_FUNCTION的active realm编译；只有`newTarget.prototype`非object时才由`JS_GetFunctionRealm(newTarget)->class_proto[class_id]`fallback，且不会触发任意字符串property get | 删除tag/copy/read helper和全部property。`Object.getOwnPropertyNames`/`Object.keys`无该前缀；Proxy newTarget只观察`prototype`get，修改/删除同名字符串不能改变fallback prototype |
| `tagRealmEval`把global强引用塞入eval function rare payload | `ctx->eval_obj`只做direct-eval identity；间接eval C_FUNCTION在自己的active realm调用`JS_EvalObject(ctx, ctx->global_obj, ...)` | `eval_obj`只由RealmContext own；alternate eval逃逸调用、替换eval与direct/indirect identity通过，function rare不再保存realm global |
| `tagRealmRegExpAccessorErrors`给每个getter缓存realm TypeError constructor | CGETSET在property-list安装期就创建C_FUNCTION并own realm；getter抛错直接用active ctx的`native_error_proto[TypeError]` | accessor先在W1b3d1改回eager C_FUNCTION；随后删除`realm_type_error_constructor`及tag。跨realm getter的error prototype正确且无缓存value |
| Object constructor的`FunctionRarePayload.primitive_prototypes[]` | `js_object_constructor`/`JS_ToObject`直接读当前Object C_FUNCTION realm的`class_proto[String/Number/Boolean/Symbol/BigInt]` | primitive wrapper原型来自active RealmContext；删除function rare数组、安装/trace/free/count reader，不按constructor object缓存 |
| typed-array prototype的`OrdinaryPayload.typed_array_array_buffer_prototype` | typed-array C_FUNCTION先以active ctx创建结果；内部`js_array_buffer_constructor1(ctx, JS_UNDEFINED, ...)`用同一target-callee realm的`class_proto[ArrayBuffer]`，而newTarget只影响typed-array结果prototype fallback | cross-realm target+foreign newTarget同时锁结果prototype与backing-buffer prototype；删除prototype链cache及安装/trace/free/count reader |
| 20处`realm_global_ptr`、两个strong `realm_global`、`host_function_realm_global`与generic resolver | final C_FUNCTION/FB、caller-class、saved current-function、job、AUTOINIT或explicit host carrier | 每个reader先换成左列对应provenance，再删producer/slot/cleanup；不得用一个新的generic `RealmRef?`字段重包同一补偿 |

其中observable fallback至少用下面的reference-shaped红灯锁住；预期own-key计数均为0、trap只看到`prototype`、最终prototype来自R：

```js
const R = $262.createRealm().global;
const f = R.Function("return 1");
const gets = [];
const newTarget = new Proxy(R.Function, {
  get(target, key, receiver) {
    gets.push(String(key));
    if (key === "prototype") return 0;
    return Reflect.get(target, key, receiver);
  }
});
const value = Reflect.construct(Object, [], newTarget);
[
  Object.getOwnPropertyNames(R.Function).filter(x => x.startsWith("__realm_")).length,
  Object.getOwnPropertyNames(f).filter(x => x.startsWith("__realm_")).length,
  gets.join(","),
  Object.getPrototypeOf(value) === R.Object.prototype,
];
```

因此不是一个大字段迁移：先以W1b2.5的`M-DSTR-STACK`与W1b2.6的`M-USING-TYPED-CONTROL`移除根本不该属于callable集合的runtime helper；随后realm本体拆成五个机制，
`M-REALM-STATE-REF`从host facade拆出identity/state owner，`M-REALM-CALL-CARRIERS`对齐native/FunctionRealm/call phase，
`M-FB-REALM-FINALIZE`把compile token递归交给每个FB，
`M-REALM-DEFERRED-CARRIERS`内部再按AUTOINIT publish、job FIFO、Finalization enqueue三把刀统一escape lifetime，最后
`M-REALM-NONCARRIER-RETIRE`按reader与传递root census删除非carrier对象上的pointer/property/cache补偿和realm-cleanup职责。每个retain/release都必须在realm
创建期的fallible准备之后成为no-fail；每个carrier有独立mark/free测试。module registry在W1e收口，interrupt budget在W2-0
收口，二者都是已登记的context差异，不能从ordinary core-close结论中消失。

## 2. 正确性前置依赖

正确性任务可以在独立 worktree 开发，但不能在 PMU 基线冻结后无条件并行合入。它们会改变
相关机制的成本或可验证边界；合入后必须重建基线。

| 正确性项 | 当前复现 | 阻塞的性能机制 |
|---|---|---|
| eval entry 不得吞 parser error | 本候选已令 public `-e '1 2'` 与 Engine eval 都抛 `SyntaxError`；CLI 非零退出，和 qjs 一致 | **correctness 子项已完成但未合入**；不得把删除 fallback 的性能变化计入收益 |
| generic eval/root closure 唯一路径 | 本候选已删除 active `simpleEval*`/caller-expression helper及`canReturnUndefinedWithoutVm`；所有源码进入parser/root runner，但root仍是裸Bytecode而非真实function object | entry no-cheating子项已完成；real root/capture array/current-function仍阻塞 M-CLOSURE2-ONEPASS、M-CELL-EXEC |
| entry environment 与current-function身份解耦 | candidate已让direct-eval var environment、implicit `arguments`、`new.target`/`super`资格与global IC读取显式`EntryContract`；负向`rg`只剩generator optional-state/首次resume fallback | **迁移前置已完成但未合入**；它解除undefined-sentinel阻塞，不代表contract是最终模型。real root前新增的硬前置是M-FINAL-BYTECODE-CONTRACT；root完成后再按QJS vardef/closure事实删减contract |
| force-GC heap accounting / weak liveness | ✅ `f221dfee` 已把 open VarRef 的 owned edge 恢复为 parked generator owner，不再把 borrowed `pvalue` 当 owned edge 追踪并破坏 trial RC；`2ecbf301`、`951726e1`、`1f67bdbc` 已分别无条件锁定 preserved WeakMap、deep weak chain、job-queue symbol root 的 force-GC 精确存活/释放，`ad3218dd` 同时锁定 exhausted-heap OOM delivery 零分配 | M-ALLOC-LIFECYCLE、M-SHAPE-PUBLISH 的 liveness 前置已解除；剩余 core stats 条件只区分 force instrumentation 的 pending request / major count / timing / threshold 语义，不是 liveness skip；阶段末仍须跑统一 force-GC/OOM gate |
| tail-call reuse 的等价 stack budget | 已在 `0c7a46f8` 重验：`function f(){"use strict";return f()} f()` 的 zjs 1s 超时，qjs 由 `js_check_stack_overflow` 抛 `InternalError: stack overflow` | M-RETURN-CONT、M-FRAME-CONT |
| interrupt counter lifetime | call/jump poll point已存在，但zjs budget随VM Machine/call重建为1024且无handler时不持续；QJS counter属于Context，raw初值0在首次poll重置到10000，随后跨call/backedge持续 | W2-0 M-INTERRUPT-BUDGET；其后重冻M-RETURN-CONT/M-FRAME-CONT，不与tail stack合刀 |
| realm identity/carrier/call phase | 当前host Context不可被FB/native/job安全持有，global token与20处payload borrowed pointer代偿；另有可观察`__realm_*`属性、tag和function/ordinary cache代偿；bound/proxy又可能把target realm提前用于wrapper | W1b3a–c先建立RealmContext、真实C_FUNCTION/FB carrier与caller-wrapper/final-arm协议；W1b3d1–d3补deferred owner/FIFO，W1b3e退全部non-carrier补偿。未完成前阻塞canonical root/closure2与其PMU基线 |
| OOM realm与恢复模型 | zjs Runtime preallocated Error来自首realm；pinned QJS没有预制对象，普通/首层OOM按active ctx的InternalError prototype，递归分配失败退`JS_NULL`；仓库`oom_cap`另钉fully-exhausted catchable object与零分配delivery | W1b3a先恢复active-realm来源；per-realm fallback只作为既存OOM-cap/recovery safety adaptation，bootstrap使用runtime-neutral sentinel。正常可分配路径仍新建Error，fully-exhausted对象复用/无stack是显式偏离。该correctness变化收益记零，且禁止把“字段搬进Context”称为QJS exact |
| internal control伪callable与binding lifetime | `internal_destructuring_helpers[14]`把六个dstr/八个using动作物化为runtime-cached无realm C_FUNCTION；`MethodRuntime.prototype`又通过external record→persistent handle钉住安装realm，公开`JSObject.Binding.prototype:*Object`则在另一端没有owner而可能悬空。公开value handle还会在runtime destroy时被静默clear成悬空slot | W1b2.5先恢复QJS destructuring单遍/stack/opcode协议，W1b2.6再把using收为typed product control；W1b3b随后从callee RealmContext解析method prototype，W1b3a把public Binding分成ctx-lifetime borrow与显式RealmRef owner，并先释放host owner后验证全部public root slots。未完成时不能宣称“所有C_FUNCTION都有carrier”或context teardown exact |
| plugin HostClass prototype绕过Context | `InstalledPlugin.host_classes[].prototype`经external record活到Runtime teardown，opaque wrapper creation不读callback ctx；zjs动态class注册也只让发生set的Context延迟扩slot。QJS class definition在Runtime，注册时先扩全部live Context的null slot，prototype只在指定Context，`JS_NewObjectClass`按调用ctx取slot并把prototype交shape | W1b3a补齐all-live/future RealmContext slot-capacity invariant，把plugin prototype迁construction slot并删除InstalledPlugin JSValue edge；W1b3b用真实C_FUNCTION callback ctx创建opaque object。opaque wrapper只经shape保活prototype，不得升级成RealmRef owner。未完成前阻塞alternate realm独立回收、registration OOM、class teardown与external-record owner census封口 |
| wrapper布局与EventLoop owner | EventLoop/test262 production以及TestEngine/string-view fixture仍把`*core.JSContext`反向cast成outer binding wrapper；wrapper拆分或先销毁即悬空。quickjs-libc loop不存ctx，但zjs现有`runUntilIdle(self)`会存 | W1b3a删除全树layout cast；loop因existing API own单一host RealmRef并只保存稳定core context，明确登记为API-lifetime adaptation。vtable直用core ctx，deinit按detach→callback roots→RealmRef释放；未完成前阻塞公开context拆分、callback ABI及Runtime teardown exact |
| Atomics.waitAsync裸context与跨线程JS | pinned QJS无waitAsync；其同步waiter只在栈上等待cond。zjs heap waiter挂全局链表并持Promise+裸ctx，notify可从foreign thread直接修改JS heap，settle失败又被`catch {}`吞掉后销毁node | W1b3a先建立node RealmRef owner以阻断UAF；W1b3d2再实现no-alloc host completion→owner-runtime FIFO settlement及OOM retry/cancel。未完成前阻塞RealmContext last-ref、Runtime teardown和“deferred work统一由job承载”的封口 |
| AUTOINIT允许域/opaque/error/publication | zjs把CGETSET、number/int常量和alias cache也做lazy，以`AutoInitRef{rt,id}`查runtime table；generic `getProperty`又把builder OOM变undefined、native builder同read双试，成功global slot仍是data。QJS仅三类ID、direct opaque，accessor/常量/alias eager，builder一次调用并上传异常，global当场发布VARREF，MODULE_NS可发布原export VarRef | W1b3d1 M-AUTOINIT-QJS-DOMAIN-PUBLISH；先按producer恢复QJS允许域/direct descriptor并删除shared alias cache，再修owner/error/global publication；MODULE_NS真实producer随W1e接入。它先于ordinary GLOBAL selector；correctness/OOM变化收益记零，完成后construction/cell/Zoo基线全部重冻 |
| generator 函数表达式作默认参数 | 已在 `0c7a46f8` 重验：`function f(x=function*(){yield 1}){...}` 在 zjs 为 `UnexpectedToken`，qjs 返回 `1` | M-EMIT 的 parser/发码面 |
| named function-expression self-binding construction | 原冻结点的 lazy materialization 沿用旧 scope-linked/unconditional-const metadata，且参数默认值 `function f(x=f)` 被错发为 global read。`dbe50d7d` 已按 qjs 修复并由 `c034597c` 合入；checkpoint 1507/1507、相关 test262 30/30、full gate 0/49775 errors | 已解除 correctness 阻塞并废弃旧 M-CELL A/B；这一项本身不授权删 runtime publication，后者仍受 M-HOIST-CONSTRUCTION 阻塞 |
| `fclosure` cpool 宽度 | 260 个 expression 的 parser panic 已修；producer 保留宽 index，最终只对 ≤255 缩短 | `936111c5` 已合入并通过相关 parser/exec/checkpoint/full gates；DONE，不计性能收益 |
| module link-time wide-function hoist | 260 个 exported function 的 cycle TDZ 已修；link consumer 同时解码 `fclosure8/fclosure` | `936111c5` 已合入；P0 DONE。它只证明 operand transport，不证明 module guarded prefix 已与 qjs 同构 |
| script/direct-eval 函数声明的创建阶段 | qjs `js_closure2` 只建/别名 cell，最终字节码执行 `fclosure; put_var_ref`；statement child解析完成后才给body local/arg写`func_pool_idx`或追加GlobalVar，block lexical则先于child、Annex-B outer var后于child | eager function-value publication虽已删除，但zjs仍在child前建立body/global/Annex-B outer carrier来补偿当前全树staging；FunctionDef构造顺序尚未对齐。归`M-FINALIZER-PRECHILD + M-BODY-HOIST-ANCHOR`原子checkpoint，之后才进入FB/closure2基线 |
| Function-constructor typed-array 源码替换 | `Function("return class X extends Uint8Array {}")()` 返回真实 subclass，`X !== Uint8Array` 且 `X.name === "X"`；helper已删除，真实subclass、name、双instanceof、length与body side effect均通过 | **correctness 子项已完成但未合入**；性能变化记零 |
| 参数语法/TDZ旁路 | token级await扫描误拒绝合法IdentifierName/nested async，裸`a=b`曾用synthetic TDZ local强制报错；pre-scan/synthetic local已删除，参数scope发真实`enter_scope/leave_scope`，AwaitExpression与directive由parser production裁决 | **correctness/机制子项已完成但未合入**；结构与行为测试均覆盖 |
| direct eval 下 function-name 与同名 body `var` | pinned qjs返回`undefined`，旧zjs/test262导向预期为`11` | 已改回pinned QuickJS；回归明确记录这是`add_eval_variables`的function-name append/lookup顺序，不再保留spec-over-reference分支 |
| ordinary descendant direct eval转发function-name | pinned qjs在`add_eval_variables` unscoped parent-var分支把`var_kind`归一为normal；最小复现输出`false / false`，不会保留原函数或抛TypeError | **当前红灯**：zjs仍输出`true / TypeError / true`。在dynamic-env/finalizer checkpoint按QJS row type与表序对齐；test262差异只记账，不授权继续偏离 |
| direct eval 的 simple-catch 同名 `var` | pinned qjs的`instantiate_hoisted_definitions`在首个同名catch closure停止，最小复现输出`g 42g`；其自身failure ledger也记录相应test262差异 | **当前红灯**：删除“outer variable environment第二target”的spec补偿，恢复pinned QuickJS declaration/initializer target；仅GUIDE要求的OOM rollback可作为安全差异，不能改变成功语义 |

上述两个未完成红灯都必须保留最小qjs/zjs复现与相关test262差异，但验收oracle固定为pinned QuickJS。
若未来产品要提供spec模式，应从该QJS基线另立模式与API；不得让optimization branch同时维护两套默认声明语义。

依赖规则：

- W1 的第一出口是 M-EVAL-ENTRY-INTEGRITY：public eval/CLI 的 parser error 不得被源码识别器改写，
  active direct/indirect eval 必须进入同一 parser→root closure→call 链。该清理是正确性前置，收益为零；
  删除 shortcut 导致的性能变化不能计入 closure construction 候选；
- M-ALLOC-LIFECYCLE/M-SHAPE-PUBLISH 的 force-GC liveness 前置已按上表收口；这只解除生产候选的
  正确性前置，不替代 W4 阶段末统一 force-GC/OOM gate；
- 再动 M-RETURN-CONT/M-FRAME-CONT 前，先为复用 frame 的 tail chain 实现并验证与 qjs stack guard
  等价的可观察终止；现有 call/jump interrupt polling 单独保留并回归，不把两种机制揉成一个计数器；
- parser 正确性修复可独立进行，但若合入，M-EMIT 的 bytecode 基线必须重冻；
- M-FCLOSURE-WIDTH 已由 `936111c5` 完成；后续不得把它的 correctness 变化并入 construction 或
  plain-put 收益。当前候选已删除 module declaration scanner/body skip，宽度测试只继续证明同一 guarded
  bytecode 的 `fclosure8/fclosure` 两种编码；
- named function-expression 修复已独立 review/合入；当前 M-CELL 性能 baseline 已作废，新的
  plain-put 候选不得跨这个 compiler invariant 状态比较；并且必须先完成
  M-HOIST-CONSTRUCTION 的对齐/裁决，不能把构造阶段改变的性能算给 resident put；
- ordinary real root的**语义表**前置已满足且W1b2物理row已落地；但必须先按W1b2.5完成single-parse/lvalue、destructuring
  source-order+stack、single-body finally、scope-close、derived-this、逐FunctionDef pre-child和body-hoist整条compiler机制链；W1b2.6的
  product-only using transport可独立合入，但必须在总体PMU重冻与callable inventory前退场。随后才进入RealmContext、同步/延迟carrier、AUTOINIT QJS-domain/fallible/global-VARREF
  publish、non-carrier compensation-retire、显式terminator、canonical root与direct-FB仍须先收口；
  随后建立GLOBAL selector与canonical root/closure2，把pc2line起始坐标并回QJS buffer格式，再做move commit、
  QJS core layout与独立core pack。packing不能早于root/pc2line/ownership transfer，header layout与allocation merge也不得合刀，
  否则只会把第二份mutable root与重复dup/copy固化进新block；static class-field的`0x8000`只阻塞全量
  eval-operand同构声明，并在W1d真实child迁移时删除；
- pinned QuickJS 是本计划的实现与可观察语义参照；test262/规范差异只进入兼容性账本，不能授权候选保留另一套行为。
  只有可复现的 Zig/LLVM/ABI 或内存安全限制，才允许采用已经证明等价的表示或调度；若未来要做规范优先模式，必须作为独立产品决策，
  不得混入本轮 QuickJS 对齐；
- 不把正确性修复的性能变化计入随后某把优化刀的收益。

这些项不是全局串行屏障：不依赖它们的 source recon 和机制可以先推进；但某机制的最终
baseline/candidate PMU 必须在自己的正确性前置合入后冻结，禁止跨前置状态拼 A/B。

## 3. 机制地图与当前优先级

优先级按“当前可约绝对 cycles × 服务面 × QuickJS 对齐确定性”排列，不按 benchmark ratio
排列。M0 完成后可以重新排序，但必须用定量证据更新，而不是凭名称调整。

| 顺序 | 机制 | QuickJS 锚点 | 当前判断 |
|---:|---|---|---|
| DONE | M-FCLOSURE-WIDTH correctness：cpool 宽/短编码与 hoist consumer | parser 先发宽 `OP_fclosure`，`resolve_labels` 只在 index≤255 时缩短；module consumer 接受两种形态 | `936111c5` 已合入；不再重开，不计性能收益 |
| P1-0（候选完成） | M-ENTRY-NO-CHEATING：generic parser/root-runner 唯一路径与 active source replacement | `__JS_EvalInternal → js_create_function → JS_EvalFunctionInternal → js_closure → JS_CallFree`；Function constructor保留原 body | candidate已删除所有已确认active entry/source bypass并补对照矩阵；real root function object归P1b，不能因P1-0完成而宣称construction完成 |
| P1a（编译期capture schema候选完成） | M-CLOSURE-RESOLUTION：closure表、open-binding编号规则和parent identity provenance | `add_eval_variables → add_global_variables → child post-order → resolve_variables/get_closure_var/capture_var` | candidate已实现event-driven编号器、exact identity、eval/declaration prefix、ordinary-global topology及pseudo append/prologue双快照；row均已去depth，body pre-scan与lexical-for重复VarDef已删除。但pattern平行owner/重复child、函数声明carrier提前、class-fields row提前和derived `this`仍会改变VarDef/parent/cpool/capture provenance，故具体index未完成。W1b2.5按下列机制链收口，不得按name/depth事后重排 |
| P1a.3（迁移候选完成） | M-ENTRY-ENV-CONTRACT：frame environment与current-function解耦 | `js_parse_program`的`is_global_var`、四个capability bit、真实`cur_func` | semantic undefined-sentinel已由显式contract替代；它是real root安全迁移脚手架，不是最终QJS数据模型，P1b后必须做退场审计 |
| P1a.4a-semantic（候选完成） | M-FINAL-VARDEF-CONTRACT：final vardef、eval operand与closure row语义 | `JSBytecodeVarDef`、`resolve_variables(OP_eval)`、`add_closure_variables` | 单表、final chain、ARG_SCOPE_END、table-order、compile/final no-depth及combined eval已完成并通过96/373/281 focused gate；收益记零。仅static class-field的`0x8000`残项转交W1d |
| DONE/W1b2（表示完成） | M-FINAL-ROW-LAYOUT：8B closure / 12B vardef | QJS in-memory bitfield record、masked raw bytes及DWARF size/offset；wire flags另序 | shared explicit-mask storage、VarKind 0..10、uncaptured zero及C/Zig golden已落地；Zoo paired median -1.10%，**性能收益记零**。后续只消费该表示，不重开布局或把噪声继承为收益 |
| DONE（one-pass slice） | M-PARSER-ONEPASS-SLICE：正式body parse、block/body语法边界与generic-for非声明LHS单遍构造 | `has_eval_call`只由正式call设置；`add_eval_variables`在完整FunctionDef后运行；`js_parse_block`空block无scope且不读directive；`js_parse_for_in_of`以label分离target构造与iterable运行 | candidate已删body pre-scan与`needs_dynamic_lvalue_refs`，拆开ordinary block/function-body grammar并让generic non-declaration target只构造一次；本轮focused parser 395/395、exec 282/282。只冻结语法边界，不把它误写成function-body runtime enter event已对齐 |
| W1b2.5a0（identity完成） | M-DECL-SCOPE-TOPOLOGY：声明所依赖的parser scope identity | `push_scope`继承visible head；catch为binding→wrapper→ordinary body；for-in/of只建一个head scope并以`close_scopes`分隔iterable/body/exit | candidate已补if/classic-for/for-in/of/switch/with/catch/class节点、inherited head、exact-scope stop与通用leave primitive；lexical for第二VarDef已删除。它仍不是scope close完成：普通pop/abrupt edge和entry future-hint归后续event/final lowering；TS namespace是独立产品scope |
| W1b2.5a0b（identity完成） | M-BODY-SCOPE-IDENTITY：先给声明owner正确body边界 | root/program/eval与parsed function/arrow/default constructor各有真实body scope；synthetic class-fields aggregator例外保持scope0 | `body_scope`身份和全部producer节点已统一，GLOBAL/MODULE/DIRECT/INDIRECT声明分支已改读该事实；尚无QuickJS body `enter_scope` marker，hoist/TDZ仍在旧prepend路径。event与hoist只由最终原子checkpoint迁移，不给aggregator伪造body |
| W1b2.5a1a（core/simple producer完成） | M-DEFINE-VAR-CORE：建立声明冲突与追加顺序唯一core | compile-phase function var以`scope_next`记声明scope；`define_var`统一WITH/LET/CONST/FUNCTION/CATCH/VAR、current/child scope、parameter、global/eval规则 | 算法、simple var/lexical/catch/for/with/class/function调用点已共用core，catch与for future scan已删除；private/pseudo保留QuickJS低层入口。pattern仍由双遍历账本支撑，函数statement parent carrier仍早于child；前者归b/b1，后者归g+h，故此处只称core/simple producer完成，不称声明owner唯一 |
| W1b2.5a2（已合入 `fde49b15`） | M-LVALUE-PROVENANCE-CORE：最后发射指令驱动普通reference与call rewrite | emitter `last_opcode_pos`；`get_lvalue/put_lvalue`；simple `var`的`get_lvalue(FALSE)`；call点last-op switch；optional getter+相邻raw label；comma/normal label显式invalidate；with只由`_with_` scope+resolver决定 | 已落地：code/atom/source/provenance原子commit，phase-1 descriptor已建立并迁assignment/update/delete/typeof/generic-for与simple var；call/optional-call/tagged-template共用`prepareCallReference`(parser.zig:8145)，direct eval优先。普通路径正式label/fixup直达put，不能读`findGlobalRefPutTail`扫描；旧pattern unpatched-target仅具名留到b。optional整链只有一个共享LabelSlot/LabelRef。删除`peekParenthesizedBareIdent`、call/source-tail状态、selected-reference scope flag、`result_needed`协议分叉及普通expression对`active_with_atom`的读取。pattern consumer在b迁移；private producer回到baseline，完整binding/lowering留W1d |
| W1b2.5a3 | M-PARSER-CONTROL-CLEANUP：语义parser不靠未来源码/优化模式 | return先完整`js_parse_expr`再`emit_return`；lookahead只允许`js_parse_skip_parens_token`等topology-free grammar判别 | 删除remaining semantic/source scans、return-comma重扫和parser内tail-call pushdown；QJS-aligned baseline不产tail-call，未来若保留只能是显式启用的独立后置CFG扩展并单独A/B。block/program using改单遍typed scope record，runtime transport仍归W1b2.6；收益记零 |
| W1b2.5b | M-DSTR-SOURCE-ORDER：解析顺序与运行顺序分离，并迁完pattern assignment target | 解构按源码遇见顺序由一次`js_parse_destructuring_element`建立binding/child/cpool/default/RHS并逐binding校验duplicate，再以`label_parse/label_assign`把RHS运行移到pattern前；非binding target在唯一遍历中调用同一个`get_lvalue/put_lvalue`。对象target reference先固定再读source property；数组target reference先固定再`for_of_next`，depth由栈协议运输 | 删除declaration/assignment完整试解析、outer-default前置、名字/shape parser与partial rollback，锁`x,d`/`x,y`/array-member单child；全部pattern target改用a2 descriptor与正式reference label，删除`captureDestructuringVarBindingRef`及unpatched-target producer。若旧helper暂时阻碍栈运输，本步与c只作同一不可拆checkpoint的内部切片，禁止新增第三套temp/reference adapter；c结束时一并删除bounded tail scan。仍不做性能归因 |
| W1b2.5b1 | M-DEFINE-VAR-CLOSE：单遍pattern接回同一owner | QJS destructuring traversal遇见每个binding时直接调用同一`define_var`并做duplicate/redeclaration检查 | 仅在M-DSTR-SOURCE-ORDER删掉topology-producing双parse后迁destructuring parameter/catch/declaration/for-head callback；再删除`BlockScopeDecls`、switch scanner与散落register/check。`arguments` future-function scanner要由最终lookup证明后删除，不能混称pattern scanner。此行完成前不得宣称declaration owner唯一 |
| W1b2.5c | M-DSTR-STACK：解构内部控制不物化JS callable | `for_of_start/next(depth)`、`iterator_close`、`copy_data_properties(depth bits)`和catch-offset/operand-stack状态；Runtime无helper C_FUNCTION | 与b/b1组成不可拆的M-DSTR-QJS-TRAVERSAL checkpoint：删除六个dstr helper、Ordinary state、frame-wide abrupt scan、非QJS temp local及最后的unpatched-target/tail-scan补偿，恢复target-reference→source-get/iterator-next→default→put的精确顺序；这一步后才允许冻结destructuring VarDef/cpool index，收益记零 |
| W1b2.5d | M-FINALLY-SINGLE-BODY：唯一finally artifact | `emit_return/js_parse_try_catch_finally`用`nip_catch; gosub`进入一次解析的finally body并以`ret`返回 | 删除finally源码预扫、snapshot重解析和按exit复制；normal/throw/return/break/continue/iterator-close共享一组child/cpool/code，收益记零 |
| W1b2.5e1 | M-SCOPE-EVENT-PRODUCERS：控制流稳定后补齐phase-1事件 | `push_scope/pop_scope/close_scopes`发enter/leave；break/continue按BlockEnv关闭跨越scope，return/throw不合成leave | 必须在single-body finally后接入a0唯一primitive；补ordinary pop、break/continue、loop/iterator边界，只生产事件、不手写`close_loc`，并锁same-frame catch负向边。body event由h统一生产 |
| W1b2.5f | M-DERIVED-THIS-CANONICAL：derived `this`单一local authority | derived constructor的lexical `this`由`super()`的`put_loc_check_init`初始化；只有真实nested/eval引用才`capture_var` | 删除unconditional capture与local↔`frame.this_value`双写；最小derived constructor保持`var_ref_count=0`，收益记零 |
| W1b2.5g | M-FINALIZER-PRECHILD：逐FunctionDef current→children | current先重建唯一scope链并做`add_eval_variables/add_global_variables`，再递归child，最后resolve current；capture只由真实事件编号 | 融合全树stage/prepare/clear/rebuild与双reconcile，删除`finalizedScopeHead/Next`平行authority；该调度稳定后才能把body/global statement GlobalVar/func_pool carrier从“child前补偿”移回QuickJS的child后构造点。module local-export index仍明确留W1e，收益记零 |
| W1b2.5h | M-BODY-HOIST-ANCHOR：有body的producer共享真实body event | root/parsed function/arrow/default constructor push body scope；body `enter_scope`按arg→local→GlobalVar消费hoist；block lexical先于child、Annex-B outer与statement carrier后于child | 覆盖root/block/concise/generated body，统一normal/export-aware function/class producer，删除anonymous default expression+post-hoist adapter、恒skip child补发与第二global declaration source；synthetic `<class_fields_init>` aggregator保持scope0无marker，parsed static-block child及其wrapper留W1d，收益记零 |
| W1b2.5e2 | M-SCOPE-CLOSE-LOWERING：最终capture事实消费leave事件 | `resolve_variables(OP_leave_scope)`只为该scope最终`is_captured` local发`close_loc`；enter只做TDZ/function init，frame退出统一关剩余refs | 在g/h同一finalize checkpoint末尾删除next-entry future-capture refresh、手写lexical全关与child-table旁路scan；ordinary/core event矩阵、loop旧cell、same-frame catch和Nth-OOM同构后才宣称scope close完成 |
| W1b2.6 | M-USING-TYPED-CONTROL：隔离无reference产品特性 | pinned commit无explicit-resource-management | M-PARSER-CONTROL-CLEANUP先删block/program全文预扫并改成单遍scope control record；本步再把八个using helper改为typed opcode/continuation并删剩余runtime cache。它不阻塞ordinary/core finalizer，但必须先于总体性能重冻与realm callable inventory，收益记零 |
| P1a.4c1 | M-REALM-STATE-REF：refcount/GC RealmContext、显式global class与普通realm state | `JSContext`的global/intrinsics/class_proto/direct initial shapes/eval_obj/random；custom class definition在Runtime，注册增长同步扩全部Context的null slot，prototype只在指定Context；object create先GC再按id读class record，definition活到Runtime；`JS_CLASS_GLOBAL_OBJECT`与state storage分离。OOM只用Runtime recursion guard+active ctx prototype，无预制对象 | 只有W1b2.5 ordinary/core compiler出口成立后才进入。RealmPayload既覆盖部分state又被`isGlobal`当identity，core/host Context还混有执行facade；plugin HostClass prototype又藏在Runtime external-record owner链，动态class slot只在set时单ctx增长，layout又由hidden template Object钉住；`recordPtr`跨GC/allocation。先建显式global discriminator，再拆header-first RealmContext/pointer-sized RealmRef并迁state/direct shapes/custom class slot及all-live/future capacity invariant，同时完成M-CLASS-RECORD-LIFETIME。公开JSContext handle只own ref；callback用同identity typed borrowed view，`ExternalCall.ctx:anyopaque`与全树wrapper反向cast为零；raw plugin frame若保留opaque ABI则仅documented borrow。per-realm预制OOM与EventLoop ref均登记为zjs adaptation，不原地refcount by-value struct |
| P1a.4c2b | M-REALM-CALL-CARRIERS：C_FUNCTION owner/final prototype、data-callable control、FunctionRealm与call phase | C_FUNCTION以construction ctx的显式prototype（默认Function.prototype）创建并dup context，C_FUNCTION_DATA沿caller；bound/proxy wrapper沿caller递归target；`JS_GetFunctionRealm`只供constructor/Dynamic Function/Error fallback与ArraySpecies comparison；final direct arm preflight后才切callee | zjs `nativeFunction(rt)`后补realm/prototype且可吞setPrototype失败，data helpers未按class分界、bound/proxy用borrowed fallback；binding MethodRuntime还用persistent prototype root，plugin opaque creation也不读callback ctx class slot。先改constructor/record映射与typed callback lookup，再锁wrapper-caller/final-carrier切换、plugin class proto、newTarget与foreign Array species，收益记零 |
| P1a.4c3 | M-FB-REALM-FINALIZE：每个FB finalize-time owner | 递归`js_create_function(ctx, child)`且每个`b->realm=JS_DupContext(ctx)`；`js_closure2`不写realm | production compile显式携带borrowed RealmRef；child/root各自在发布前retain，删除first-closure mutation及parent借owner，收益记零 |
| P1a.4c4a | M-AUTOINIT-QJS-DOMAIN-PUBLISH：三类dispatch、direct opaque、property slot owner与一次fallible publish | low bits仅PROTOTYPE/MODULE_NS/PROP，第二word为entry/null/module pointer；PROP只延迟C function/string/object，accessor/常量/alias eager；slot dup/free/mark stored realm，builder一次调用，ordinary发布normal、global发布VARREF，MODULE_NS可发布原VarRef，exception上传 | 当前AutoInit域过宽、`AutoInitRef{rt,id}`与alias realm cache又增加indirection/state，realm还借target cleanup表；builder optional且native双试、OOM静默undefined、global只发布data。先按producer恢复QJS域/direct opaque/alias顺序并删cache，再引入fallible read、typed slot owner与global cell commit；MODULE_NS production rollout留W1e，失败保留placeholder是命名的GUIDE transaction divergence，收益记零 |
| P1a.4c4b | M-JOB-REALM-FIFO + M-HOST-COMPLETION-TO-JOB：enqueue realm、单FIFO与foreign completion边界 | 每个QJS job entry dup/free ctx+args，Promise/dynamic import共用runtime FIFO；dynamic-import handler/Runtime loader沿entry ctx。pinned Atomics只同步signal，无waitAsync/foreign JS settlement | generic/Promise/finalization queue分散且裸借Context，DynamicImport callback又忽略传入ctx；zjs waitAsync node还让notify线程直接settle JS并吞错。先统一Promise/dynamic-import/generic job并删除state realm authority，再让host completion无分配发布、由owner runtime按node RealmRef入FIFO；锁跨realm顺序/OOM retry/cancel和host queue边界，收益记零 |
| P1a.4c4c | M-FINALIZATION-REALM-ENQUEUE：registry construction realm与GC enqueue | FinalizationRegistry own ctx，GC cleanup用它向同一runtime FIFO enqueue | 当前payload借global且cleanup queue独立；依赖c4b接入同一FIFO，单独处理GC-time OOM recovery与weak cells，收益记零 |
| P1a.4c5 | M-REALM-NONCARRIER-RETIRE：非carrier对象/property/cache不编码realm | `JSObject` ordinary/class payload无通用ctx；builtin realm来自active C_FUNCTION/FB、FunctionRealm、job或AUTOINIT；源码无`__realm_*`property及primitive/error/typed-array realm cache | 逐reader替换20处pointer/两个value槽与generic resolver，并删除`__realm_*`、三个`tagRealm*`、copy/reflect helper及function/ordinary cache；删除realm matcher/holder注册但保留真实weak-edge registry。按reader family拆patch，收益记零 |
| P1a.4d | M-EXPLICIT-TERMINATOR：生产CFG显式return | `js_parse_program/emit_return`；pack无`+1` | 当前root/eval/branch-to-end依赖hidden sentinel；先做correctness snapshot/CFG validator，再删除生产sentinel，为canonical root提供合法最终code |
| P1a.4e | M-CANONICAL-ROOT-FB：root走与child同一final artifact | `__JS_EvalInternal → js_create_function`；root和child都由同一finalizer发布 | 当前parser.Result保留mutable/root Bytecode；先把compile policy与RealmRef传进root finalization，ordinary script/direct/indirect eval只持一个owned FB。临时runner adapter只能stack-borrowed、不可逃逸 |
| P1a.4f | M-FB-DIRECT-EXEC：VM直接消费FB | qjs VM从`JSFunctionBytecode*`直接读全部artifact；`js_closure2`消费owned bfunc引用 | canonical root和child均稳定后逐accessor删除heap cached view；view里的arguments rescue/leaf事实逐项裁决，owned attach消除dup/free往返。单独A/B，不与root、realm或packing合刀 |
| P1b | M-GLOBAL-CELL-SELECTOR + M-CLOSURE2-ONEPASS：root/nested eval function与最终cell array | `JS_EvalFunctionInternal`、`js_closure2`、`js_closure_global_var`、`instantiate_hoisted_definitions` | block hoist与body binding分类已显著对齐，但scope-exit cell lifetime、finalizer调度和全body执行锚点仍需W1b2.5修正；其后仍有裸Bytecode root、outer current-function、placeholder/copy/replace、ordinary GLOBAL缺AUTOINIT retry。module import staging不在ordinary core伪装完成 |
| P1b.1 | M-PC2LINE-QJS-FORMAT：最终debug buffer自描述起始坐标 | `compute_pc2line_info → find_line_num` | 当前起始line/column另存于DebugInfo/view；先把两个ULEB128头并回buffer并删parallel fields，收益记零 |
| P1b.2 | M-FB-COMMIT-TRANSFER：finalize move ownership | `js_create_function`成功提交与`free_function_bytecode` | 当前atoms/values/debug buffers重复dup/copy/free；先完成所有真实fallible准备并收紧no-fail GC publication，再move，单独做refcount/OOM归因 |
| P1b.3 | M-FB-CORE-LAYOUT：QJS header offset/alignment | `JSFunctionBytecode` base/debug layout与DWARF | 先建立唯一production raw builder/fixture builder，再把header改成96B base + optional 32B debug tail（full 128B）/align8及显式flag masks；非QJS事实与临时`artifact_block_base`置header后的可计算extension，tables/code block暂不合并但双析构位退场，单独归因load chain/prefix/slab |
| P1b.4 | M-FB-PACK-CORE：QJS-order common artifact | `function_size → js_mallocz → self pointers` | 用唯一checked layout公式从稳定header把cpool/vardefs/closures/code并入同一allocation，extension移到code后并显式记录对齐padding；source/pc2line仍独立。只归因allocation topology，W1d内另做total exact-close |
| P1e（部分完成） | M-MODULE-REALM-PERSISTENT-LINK：per-Realm registry、persistent function、indexed imports/exports、namespace varref、guarded prefix | context-owned `loaded_modules`、`js_create_module_function`、`js_inner_module_linking`、`js_build_module_ns` | candidate已有同一guarded bytecode入口并删除scanner/body-skip；registry仍Runtime-global，file graph重复编译/不持有同一function，link phase/cells/namespace/rollback均未对齐。先隔离realm registry再迁persistent owner |
| P1c | M-CELL-EXEC：plain put/set 执行与 opcode residency | `JSVarRef.pvalue`、plain/short/checked var-ref CASE labels、`set_value` | 表示已对齐；read direct已约0.90x qjs且split候选失败；W1-core-close后先重测并证明compiler已拒绝各owner的非法写，再决定是否做resident plain put、resident set。已登记的class/private/import closure side channel与module full-close不无条件阻塞ordinary cell基线；realm pointer/property/cache补偿必须已按W1b3e退场 |
| P1d recon | M-DYNAMIC-VAR：`.global/.global_ref` 的 `get_var/put_var` 两腿 | qjs `OP_get_var/OP_put_var` CASE 内先直接 cell，只在 uninitialized/const 时进 global-object slow leg | zjs get 侧已有对齐历史，`put_var` 目前整体仍在 `h_put_var/coldStd`。P1a改变 carrier拓扑、P1b改变 cell source；两者合入后才能建 direct probe/重排，不混入 plain-var-ref收益 |
| P2-0（correctness） | M-INTERRUPT-BUDGET：跨call持续的per-realm/context poll counter | `JS_INTERRUPT_COUNTER_INIT=10000`、`js_poll_interrupts` | poll points已有但budget随Machine/call重建且handler关闭时不持续；先锁nested call/backedge/handler cadence，不与tail stack或dispatch性能归因混合 |
| P2 | M-RETURN-CONT：bytecode callee 返回后的 non-`.next` continuation transport | `JS_CallInternal` 的嵌套 call/return、`JS_IteratorNext` | tail-chain stack correctness与M-INTERRUPT-BUDGET分别重冻后，只审计`return_action/payload → op_post_call_continuation`；普通call/return已排除，iterator/Proxy只是消费者 |
| P3 | M-PROPERTY-LOOKUP：named property shape/prototype walk | `GET_FIELD_INLINE`、`find_own_property`、`JS_GetPropertyInternal` | push/pop 最大前置面之一；已部分对齐，先找 fallback/transport 残差 |
| P4 | M-NATIVE-CALL：callable→native frame→cproto/record | `JS_CallInternal`、`js_call_c_function`、各 cproto | 与 lookup 分离；push/pop/regexp/Math 等共享 |
| P5 | M-ALLOC-LIFECYCLE：object create/free/accounting | `JS_NewObjectFromShape`、`js_malloc/free`、`__JS_FreeValueRT`、`free_gc_object` | 当前 1.149x；force-GC liveness 前置已收口，按冻结/PMU协议执行，阶段末统一复验 force-GC/OOM |
| P6 | M-SHAPE-PUBLISH：root/transition/property publish | `find_hashed_shape_prop`、`add_property`、`add_shape_property` | 三臂已有，但 capacity-independent cache hit 尚未对齐；扣除 allocation 后执行 |
| P7 | M-EMIT：当前仍缺的 qjs lowering/peephole | `resolve_variables`、`resolve_labels` | 先按最终 bytecode 重建规则清单，不按 pass 位置猜测 |
| P8 | M-FRAME-CONT：通用 frame/prologue/epilogue | `JSStackFrame`、`JS_CallInternal` | 调用已在 0.98–1.16x；tail guard 修复且新 profile 证明共同杠杆才重开 |

M-ARRAY-STORAGE 暂停：qjs 式 fast push/count/length 已存在，当前 profile 不支持它是主杠杆。
RegExp、Array、for-of、spread、objlit 等只作为机制消费者和语义验证面，不各自成立性能战役。

**Opcode residency 规则：** 不新建宽泛 M-DISPATCH。只有当 qjs 对应 opcode 是 CASE-inline、zjs 因冷 helper
额外发布/恢复 pc/sp，且 direct profile 证明该段在关键链上时，才能把**一个完整语义 family**
迁入 resident handler。这是逐 opcode 对齐，不是 benchmark fast path，也不允许顺手改 next-dispatch 架构。

P1d 是本次查漏保留的**强制 recon 项**，不是已批准的生产刀。它的 direct probe 必须分开
initialized-cell hit、uninitialized global-object hit/miss、strict miss、lexical TDZ/const 和 Proxy/exotic global；只有
cell-hit 差距与实际 consumer 同时成立，才按 opcode-residency 规则排到 P2 之前。

## 4. M0：每个生产改动的统一证据包

M0 是**按当前机制增量完成**的前置，不是要求 P1–P7 全部 recon 完才能产出第一把刀。
每个机制先完成一个只读 recon 包，内容必须齐全。源码/字节码 recon 可以早于正确性修复；
最终 PMU freeze 必须晚于该机制在 §2 中的前置门禁：

1. **QuickJS 事实链**：源码函数、关键结构字段、调用者、异常/所有权顺序，以及对应热汇编；
   同时记录 `OPTIMIZE/SHORT_OPCODES/DIRECT_DISPATCH/CONFIG_STACK_CHECK` 的有效值。
2. **zjs 当前链**：对应模块、调用者、结构字段和热汇编；标出已经对齐的部分，避免重复工作。
3. **差异分类**：
   - QJS 机制缺失；
   - 同一机制但 Zig 表示/ABI 不同；
   - 纯代码生成差异；
   - benchmark 自身混入的其他机制。
4. **最小探针矩阵**：每个脚本标为 symptom、direct、consumer 或 control。一个脚本不能同时
   充当直接归因和受益面证明。
5. **收益上限**：按 self cycles、调用次数和关键链估计可约上限；未算上限前不写 −15%/−20%
   之类目标。
6. **三方冻结**：recon 先冻结 baseline zjs / pinned qjs 的完整 binary SHA 与 `.text` SHA/size、
   stdout、原始逐轮计数、环境和命令；生产候选完成后再追加 candidate zjs 的同类证据，形成
   可比较的三方包。完整 hash 用于钉具体文件，`.text` hash 用于识别同源码重建中的代码身份；
   两者不能互相替代。

性能 qjs 二进制与 QuickJS 源码 checkout 必须可追溯到同一构建。若不能证明二者对应，或
checkout 发生变化，M0 先从该源码重建 qjs 并同时重钉源码 commit、构建命令和 binary SHA；
不得保留旧二进制却用新源码解释机制。

本轮已完成这项核验：性能 qjs 与 clean checkout 新建 qjs 的完整 hash 不同，但 `.text` 的
725,228 bytes 完全相同。差异来自构建路径/调试等非 `.text` 产物；因此继续用页首性能二进制
跑 PMU，同时以 clean checkout 解释源码。未来任何 `.text` 变化都必须重冻，不能用“同 commit”
带过。

compiler/bytecode recon 另建一个同 commit 的 diagnostic qjs（当前源码明确使用
`DUMP_BYTECODE=7` 导出 pass1/pass2/final，或使用经证明等价的导出），只用于字节码对照，不作为
性能参照。diagnostic 与 performance qjs 的 hash、flags 和用途分开记录，禁止把带诊断宏的二进制
混入 PMU。

当前 diagnostic qjs 已存在：`/home/aneryu/quickjs-zjs-dump` @
`04be246001599f5995fa2f2d8c91a0f198d3f34c`，唯一源码差异是启用 `DUMP_BYTECODE=7`；其 `qjs`
完整 SHA-256 为 `c8785a6e40e0c570f23d19f1b91db8e4202d66d3959980af88bb03e352cc534f`。

测量约定：

- 每个生产候选从冻结 baseline 建独立 worktree/branch，diff 只含一个机制；期间若合入相关
  正确性或共享 runtime 改动，就废弃旧 A/B、重建候选并重新冻结，不跨基线拼数据；
- 主结论使用交错 paired median，并报告范围或 MAD；best/min 只作辅助；
- `cycles,instructions` 一组采集；branch、branch-miss、L1I、frontend/backend stall 分组采集，
  避免事件 multiplexing 扭曲主计数；
- 至少 9 轮。候选效应低于 1.5%，或改动 `.text`/热结构布局时，再做独立 ReleaseFast 重建
  和至少 15 轮复核；
- 两侧都做 symbol + instruction-level profile。热点占用不是关键链证明，必须追踪值的消费者；
- 候选前冻结一组不受益 sentinel（至少覆盖既有 call shape、property read、string/loop 和 allocation
  control）；看到结果后不得替换 control、重分类 consumer 或删去回退形态；
- raw 数据放在当前 `.scratch/<mechanism>/` 工作项或等价临时证据包，结论写进 owning commit/
  issue；不新增全局历史账本。

## 5. 第一阶段：解释执行共同热机制

### 5.1 M-HOIST-CONSTRUCTION → M-CELL-EXEC

这里有两个必须分开的机制：**cell/函数值在什么阶段被创建与发布**，以及最终
`put_var_ref/set_var_ref` **如何执行一次已授权的 cell 写入**。前者改变可达字节码和 runtime
补偿分支，必须先独立对齐；不得把它的收益算给后者。当前 `[]*VarRef`、open cell 的
`pvalue → frame slot`、close 后 `pvalue → self.value` 已能表达 qjs，没有已知 Zig 限制。

#### QuickJS 的完整构造链

1. compiler 先重建全部 scope linkage（parameter scope 以 `ARG_SCOPE_END` 为特殊首项），再严格按
   `add_eval_variables → add_global_variables → recursively js_create_function(children) → resolve_variables
   → resolve_labels → compute_stack_size` finalize；`capture_var` 在某个 arg/local **第一次被实际要求捕获时**
   当场分配 `var_ref_idx`。`resolve_variables`同时把`eval/apply_eval`的parser scope改写为最终vardef链头；
   随后只把args→locals连续复制为compact `JSBytecodeVarDef[]`，parser scope数组与完整`JSVarDef`不进入最终产物；
2. `add_eval_variables` 的 **VarDef append 顺序**是按适用条件加入 `_var_`、`_arg_var_` → `this`、`new.target`、
   `this_active_func`、`home_object` → `arguments`（parameter-scope alias 单独链接）→ function-expression name。
   这与 `resolve_labels` 的**最终初始化 prologue**不同：home object → active func → new target → this →
   arguments → function name → `_var_` → `_arg_var_`。随后 `resolve_variables` 先输出 direct-eval
   lexical-conflict throws；遇到 body 的 `OP_enter_scope` 才插入 arg/local/global hoists，再插入该 scope 的
   lexical TDZ/function 初始化。因此最终执行顺序是 special slots → conflict throws → parameter/default
   bytecode（若有）→ body hoists → body lexicals；`leave_scope/close_scopes`再只为当时已经capture的locals发
   `close_loc`，cell在离开本次scope时detach，不在下一次entry预刷新；
3. `JS_EvalFunctionInternal` 对普通 script、direct/indirect eval 都把 bytecode交给 `js_closure`，建立一个
   **真实 root function object** 与 capture array，再调用它；direct eval 的 caller frame只是 capture 来源，
   不是 eval 的 `cur_func`；module root 同样持有真实 module function object；
4. `js_closure2` 先把 bytecode挂到已建立的 function object，并分配清零的最终 `JSVarRef**` 表；eval 时
   pass 1 只做全部 `GLOBAL_DECL` 合法性检查，随后 capture pass 按 closure 次序一次创建/别名精确 cell；
   `MODULE_IMPORT` 是唯一有意保持 null、等待 link 按 index 填写的 slot。此时仍不创建 hoisted function value；
5. global capture 的来源顺序固定为 global lexical `VARREF` → global object（`AUTOINIT` 必须先物化并重试，
   已有 `VARREF` 就别名）→ shared uninitialized-global side-table cell；不是“每次缺失就新建 cell”；
6. module function/cell graph 在 link 前创建：bytecode module 先为当前节点建 function/capture array，C/native
   module则直接建local export cells；两者都先标记`func_created`再递归dependency。link 的单节点阶段固定为
   dependency DFS → 间接 export 全验证 → 按
   `JSImportEntry.var_idx` 填 import slots → retain local export cell → 以 `this=true` 调 guarded declaration prefix →
   SCC commit；任一失败把 linking stack 上全部 module 恢复为 unlinked。namespace import 写 importer-owned
   `MODULE_DECL` cell，普通 import别名 exporter cell；namespace normal export直接安装 `JS_PROP_VARREF`，
   cycle-dependent export才用 `AUTOINIT`；
7. 最终 bytecode 再执行 `fclosure + put_var_ref`。diagnostic qjs 中 script/global function 的 final
   前缀就是 `fclosure8 0; put_var_ref0 0:f`。module 额外带
   `push_this; if_false; ...; return_undef` 链接前缀，linker 用 `this=true` 只执行这段，正常求值再从
   body 入口继续。cpool index 0..255 最终为 `fclosure8`，256 起保留宽 `fclosure`；两者只是
   operand 编码不同，构造/链接语义完全相同。

执行端的契约同样窄：

- `get_var_ref{0..3}`/plain get 只做 `*pvalue → JS_DupValue → *sp++`；
- plain put 消费 TOS，plain set 写入 dup 并保留 TOS；`set_value` 先保存 old，再把 new
  写入 slot，最后 free old，避免 old 的释放重入后破坏目标 slot；
- const/function-name非法写由resolver改成`throw_error`或sloppy drop，plain put handler不再读取closure metadata；
- 只有 `*_check`/`*_check_init` 做 TDZ/初始化检查，0..3 short forms 是独立 CASE labels。

#### 2026-07-19 复审：QuickJS 的阶段真源

不能只把 eager helper 搬到 bytecode；QuickJS 的正确性来自六个阶段各自只拥有一种事实：

1. **parse metadata**：body-scope local/arg 的最终函数只保存在
   `JSVarDef.func_pool_idx`，同槽重复声明是 last-wins、只生成一次初始化；script/module global
   function 则逐条追加 `JSGlobalVar`，重复声明不去重。sloppy Annex-B block function先append block lexical
   FunctionDecl，child解析完成后才append/复用外层var；两个binding的index provenance不能交换。
2. **eval prefix / capture provenance**：`add_eval_variables` 按 `_var_/_arg_var_` → this-family → arguments →
   function-name 的 VarDef append顺序准备自身特殊 binding，再依次 capture 当前函数的 args、scope-0 vars；
   `resolve_labels` 的 prologue 顺序是另一套已固定的执行顺序，不能拿 append snapshot 去重排它。向祖先走时严格按
   visible scoped lexicals → args → unscoped vars（parameter scope 只保留 pseudo vars）追加 closure。
   遇到 eval root 时只把非 GLOBAL family entry 继续作为 `REF` 转发。`capture_var` 在每个实际事件上
   分配 `var_ref_idx`；不存在“先收集完，再 vars-first/args-second 编号”的独立阶段。
3. **direct-eval seed 与 declaration append**：`add_closure_variables` 为动态编译的 direct eval 按
   visible lexicals → args → unscoped locals 建固定前缀，再把 caller 的 LOCAL/ARG/REF/MODULE_DECL/
   MODULE_IMPORT 全部作为 REF 追加；它保留同名但 identity 不同的 entry，让 lookup first-match 决定
   可见绑定。`add_global_variables` 随后按 `global_vars` 原顺序追加每个
   `GLOBAL_DECL/MODULE_DECL`，包括同名重复；只有 sloppy direct eval 已落到 `_var_/_arg_var_` 时才不追加。
4. **child post-order / resolution**：declaration carrier 在递归 child 前已经稳定，children 全部 finalize
   后 parent 才解析自己的 scope bytecode。`get_closure_var` 以 `(closure_type,var_idx)` 去重，name 只参与
   lookup；ordinary global 沿 parent 链形成一个 root `GLOBAL` 与逐层 `GLOBAL_REF`。local export 的
   `var_idx` 在 declaration append 后固化。scope entry只做function/TDZ初始化；normal与abrupt scope exit
   才按已经发生的capture关闭cell，因此resolver不需要future-capture hint或child-row旁路扫描。
5. **root/nested closure construction**：script/direct/indirect eval 先由 `js_closure` 得到自己的 function
   object。`js_closure2` 分配/清零最终 pointer array，eval pass 1 按 closure 表验证全部 `GLOBAL_DECL`，
   pass 2 再按同一顺序一次创建/别名 cell；直到 capture 完成后才安装 length/name/prototype 等属性。
   configurable accessor/function property surgery 与 global waterfall 也属于这里，但不创建 hoisted function value。
6. **execution bytecode**：进入 body scope 时按 arg index、local index、global-var list order 生成
   初始化。每个 global var 从 closure 表头开始扫描：第一个同名 entry 胜出；否则第一个
   `_var_/_arg_var_` 胜出。closure target 用 `fclosure|undefined + put_var_ref`，var-object target
   用 `get_var_ref + fclosure|undefined + define_field + drop`。`force_init` 仅决定 cpool 缺席时是否
   发 `undefined`，不能承担声明分类。普通 non-lexical global read/write 仍是
   `get_var/put_var`，不能因为存在 `GLOBAL_DECL` 而降成 plain `get_var_ref/put_var_ref`。

`resolve_variables` 的锚点不是“统一 prepend 一个 prologue”：direct-eval var 与可见 lexical 冲突时，
它先把 `throw_error(VAR_REDECL)` 放入输出；只有扫描到 **body** `OP_enter_scope` 才插入 hoists，随后
插入该 scope lexical TDZ/init。`resolve_labels` 的 special-slot 初始化最终位于更前。这个锚点保证参数
默认值先于 body function hoist；当前少数语义 probe 恰好同为 `undefined`/`ReferenceError`，不能证明
全局 prepend 在 allocation、GC、OOM 和最终 bytecode 上等价。module default 的 `set_name(default)`、
module link-only guard 与 `fclosure8/fclosure` 宽度只是这套序列的消费者，不能另造规则。

#### 当前候选的真实状态

当前 worktree 已完成但尚未合入的 P1a/W1b1-semantic 及module-prefix子集为：

- 最终closure row已呈现`eval prefix → global declarations → child-demanded captures → parent bytecode encounter`
  的QJS provenance；ordinary phase-1 reference不再parser-time eager建capture row。调度仍是全树
  `stageOwnEvalPseudoBindings`后再全树`prepareDirectEvalAndGlobalClosures`，不是QJS逐FunctionDef current→children，
  因而只冻结row schema、type+source identity与lookup规则；具体row内容/index及allocation/OOM顺序均不冻结；
- `capture_var` 首次事件当场分配 owner open-binding index；删除 vars/args grouped assignment、closure
  permutation/remap、forward retrofit、ancestor-index fallback与按 atom 猜 binding use；
- capture identity 使用 `(closure_type,var_idx)`；direct-eval seed保留同名不同 identity，GLOBAL family
  不进入 seed，MODULE/REF按普通 REF转发；ordinary global只有root `GLOBAL`与逐层 `GLOBAL_REF`；动态环境
  producer不再把每个direct-eval `<var>`无条件灌入所有后代：函数自身direct eval走`add_eval_variables`式
  visible-parent capture，普通后代仅在final resolver确认未解析名字实际跨越环境时inside-out转发；
- `GlobalVar` carrier按原顺序逐条追加，local/arg function declaration由 `func_pool_idx` last-wins；函数体
  pre-scan与nested arrow/class method泄漏已修，body identity和non-pattern `defineVar` producer也已统一；当前平行declaration owner
  只剩destructuring双遍历使用的`BlockScopeDecls`/switch scanner，以及implicit-arguments的future-function scanner。
  statement body/global/Annex-B outer carrier仍早于child，因此不能冻结具体local/closure index或宣称producer order exact。
  block `enter_scope`已负责自己的hoist，但body只有`body_scope`分类，arg/local/global hoist与body lexical prep仍被统一
  prepend到parameter bytecode之前。旧per-child prologue fallback已删除，未被metadata/source/global三类覆盖的
  hand-built FunctionDef直接报`InvalidBytecode`；但production仍保留一个被`functionHasGlobalFunctionVarCpool`恒挡住的
  `emit_top_level_closure_init/top_level_closure_var_idx`补发loop，尚未达到GlobalVar单一真源；
- nested block的binding init虽在entry，但captured cell lifetime尚未对齐：普通block不发leave，部分loop边界已有通用leave marker，
  其余abrupt path仍依赖下一次entry按future-capture hint刷新。lexical for-in/of的重复scope/VarDef已删除；sloppy Annex-B block function
  仍先append outer var、后append lexical FunctionDecl，与QJS相反。这些差异仍会改变final bytecode/index/OOM，不能包含在“block hoist已对齐”里；
- body级`var/eval`预声明已删除；剩余非QJS声明scan是destructuring/switch账本与implicit-arguments future-function scan，
  return另以comma/source scan驱动parser tail-call mode，`try/finally`还先扫描后按每条abrupt path重解析/复制body。
  declaration扫描先由M-DECL-SCOPE-TOPOLOGY/M-BODY-SCOPE-IDENTITY提供真实scope identity、再由
  M-DEFINE-VAR-CORE与pattern单遍后的M-DEFINE-VAR-CLOSE收口；return归
  M-PARSER-CONTROL-CLEANUP，finally归M-FINALLY-SINGLE-BODY；不得混成一把“删扫描”patch；
- 普通generic for-in/of member LHS已改为单遍label/bottom-put；computed child为QJS的`x,y`，parenthesized dotted/indexed已接受。
  这组回归必须保持，并在M-LVALUE-PROVENANCE-CORE中改成统一get/put consumer，不能留成专用shape fast path；
- destructuring declaration/assignment还会完整试解析后只截断code/atom，FunctionDef的child/cpool/temp local并未事务回滚；
  最小probe已直接看到zjs的`x,x,y`/3 locals/3 constants对QJS的`x,y`/2 locals/2 constants。parameter路径虽已使用
  topology-free pattern scan，但仍先正式parse外层default initializer，因此`{a=x}=d`的child顺序由QJS `x,d`变成zjs `d,x`；
  不能以“没有重复child”误判为单遍构造。六个dstr helper及其temp/state又形成第二套control transport；故具体
  VarDef/child/cpool顺序在M-DSTR-SOURCE-ORDER/M-DSTR-STACK前同样不能冻结。八个using helper及block/program全文扫描
  是独立product debt：全文扫描归M-PARSER-CONTROL-CLEANUP，typed transport归W1b2.6；
- module final bytecode已有 `this` guard，link-time调用同一入口执行 declaration branch；旧scanner/body-skip
  已删除，inline module eval也执行该入口；
- implicit `arguments` 已改用 `appendVar/add_var` 语义，不再挂普通 lexical scope chain；parameter-expression
  environment现发真实`enter_scope/leave_scope`，TDZ来自实际parameter VarDef，不再来自blanket body prefix或synthetic local；
- 所有eval pseudo binding现只在统一finalization stage落位：`_var_/_arg_var_ → this/new.target/active/home →
  arguments → function-name`使用非scope-linked `appendVar`，parameter-scope arguments alias是唯一专用link；parser-time
  eval扫描、`this`/`new.target`/arrow/super与`delete function-name`均只发name+scope bytecode。最终prologue保持原有
  `home→active→new.target→this→arguments→name→_var_/_arg_var_`，没有按VarDef顺序重排；
- semantic `current_function == undefined`判断已由显式`EntryContract`替代；当前负向扫描只剩generator执行状态中
  “尚未保存current function”的optional-state/首次resume fallback，不再决定eval/global/arguments/super语义；
- 全仓没有reader的`DirectCallSite`已连同parser producer、pass remap与free链删除；QuickJS最终FB也没有对应表，
  因此不再把它包装成“root迁移必须保留的metadata”；
- 已确认entry层的eval/Dynamic Function源码替换、empty-root VM bypass、await/parameter-TDZ token捷径及body pre-scan已删除；
  但不能再概括成“parser source/token bypass全部删除”：pattern declaration ledger/switch scanner、implicit-arguments future scan、lvalue/source control与destructuring/finally replay仍是active production路径，
  必须由M-DECL-SCOPE-TOPOLOGY/M-BODY-SCOPE-IDENTITY、M-DEFINE-VAR-CORE/CLOSE、M-LVALUE-PROVENANCE-CORE、M-PARSER-CONTROL-CLEANUP、M-DSTR-SOURCE-ORDER/M-DSTR-STACK与
  M-FINALLY-SINGLE-BODY分别收口；using runtime transport另归W1b2.6。

这些成果加上最新W1b1-semantic说明：**closure row schema/type+source identity规则、ordinary/parameter final table lookup契约、compile/final
closure no-depth与combined eval identity均可冻结**；由declaration append决定的具体`var_idx`/open-binding index/final bytecode仍未冻结。
单遍parser producer、destructuring source-order/stack、single-body finally、scope-exit cell lifetime、唯一final scope链、derived-`this`真实capture、全树多prepass/hint replay调度、
Annex-B VarDef producer顺序和全body hoist anchor均未冻结，另有cached view暴露的一个必须在direct-FB前证伪的
`get_var(arguments)` rescue adapter：若final-bytecode corpus仍有真实producer，就只修对应arguments pseudo-resolution，
不得借机重排closure row；若producer为零，则删除scanner和两个runtime rescue分支。W1b2虽已完成物理record且性能收益记零，
仍不能宣称整个construction或全部FunctionBytecode已对齐。declaration scope topology→body scope identity→define-var core/simple producer
这一前缀已经完成；当前private半迁移先回退到可运行baseline。剩余顺序固定为phase-1 emitter transaction+ordinary last-op/call+simple-var reference→parser control cleanup→[destructuring source-order→define-var close→destructuring stack control]不可拆checkpoint→single-body finally→scope-event producers→derived-`this`单一authority→(逐FunctionDef pre-child调度+body hoist event+scope-close lowering)→using typed product isolation→RealmRef/state→同步call carrier→每个FB finalize-time
realm→deferred carrier/FIFO→non-carrier compensation-retire→显式terminator→canonical root FB→direct-FB→GLOBAL selector/closure2→QJS pc2line格式→
move commit→QJS core layout→QJS-order core pack；static class-field eval的`0x8000`
随W1d真实child删除，persistent file-module/indexed link/namespace VARREF归W1e。

验证状态必须和代码同步记录。2026-07-20最新scope/define-var/export-order代码之后已重跑`test-parser` **395/395**、
`test-bytecode` **98/98**、`test-exec` **282/282**、`test-builtins` **175/175**与`quick-check` **3/3**；随后最新
`checkpoint-check` **32/32 steps**通过，含统一Debug **1609/1609**、architecture/public API、Debug/ReleaseFast CLI smoke及
Debug test262-smoke **12/12**。更早的完整ReleaseFast test262准备49775项、passed 44599、known 2、unexpected 0，且未改
配置/exclude/known-error/submodule；但该结果包含现已取消的spec-over-QJS catch-var行为，不能作为本轮“忠实QuickJS”full gate。
full test262/OOM injection/ReleaseSafe均未重跑。

最新slice已修复并加focused回归：body pre-scan与nested arrow/class-method var泄漏、`let a; var b`源码顺序、
ordinary block directive/empty-scope边界、完整scope visible chain/catch wrapper/lexical-for单一binding、body identity与non-pattern
`defineVar`调用点，以及generic for普通LHS的单次构造、合法member target与iterable-before-target运行顺序；simple catch和classic/
for-in/of future scanner已经删除。direct-eval assignment/arguments旧stdout也已按pinned qjs纠正，不能恢复旧oracle。当前**未修红灯**收敛为：
pattern `BlockScopeDecls`+switch scanner、implicit-arguments future-function scan；generic for仍靠`classifyLhs/peekParenthesizedBareIdent`
手写put；return-comma scan仍驱动非QJS parser tail-call；destructuring仍有`x,x,y`/`d,x`/array-member四child与helper/temp/state，
finally仍复制body；statement body/global/Annex-B carrier构造时机仍早于QuickJS。故当前focused/checkpoint全绿也不能恢复
“compiler exact”或合入结论。

W1b2表示候选现已落地但尚未合入：`VarKind`恢复QuickJS的0..10，zjs临时
`class_static_this`移到11；compile/final closure共享一条显式byte flags的8B/align4 row，final vardef为
12B/align4；final未捕获row以`is_captured=0,var_ref_idx=0`表示，`0xffff`仅留在compile-only
`VarDef.open_binding_idx`。零填充C probe与Zig golden逐byte同为closure
`1a 08 34 12 88 77 66 55`、vardef
`44 33 22 11 04 03 02 01 8f 00 34 12`，没有混用wire flags。runtime门禁曾发现一个fixture只写
`var_count=1`却不分配vardef table，现补真实row而未弱化production deinit；最终累计门禁见上段。

ReleaseFast regexp Zoo在固定X925 CPU上交错15轮：baseline/candidate score中位数893/881，paired
median **-1.10%**、MAD 0.91%，低于1.5%裁决线；candidate仅4/15胜，因此W1b2**性能收益记零**，不得宣称
row缩小让Zoo变快。padded-flags与natural-storage分层诊断也未把代价归到8/12B宽度或bit extraction；临时强制
inline `matchPutGetPeephole`反而把paired结果恶化到-2.78%，已完整回退。raw数据、二进制hash、perf profile与
C probe记录在`.scratch/m-hoist-construction/w1b2/`；这不阻塞物理QJS对齐作为correctness/memory候选，
但后续W1b3a–W1b3e不得继承或包装该噪声为性能收益。

本轮raw-construction扫描确认：除`createFunctionBytecodeAfterChildren`外，所有直接
`alloc(FunctionBytecode)+init`均在test/fixture作用域；native builtin走独立native function object。这一事实把后续
layout迁移的门禁收紧为“唯一production raw builder + fixture-only builder”，也否定了为所谓synthetic FB保留第二种
header/free路径的理由。另对照`js_closure/js_closure2`确认attach应消费一份owned FB引用；当前
`constants.get → dup attach → free get-result`的往返必须在one-pass closure2中消除，不能计入pack收益。

上一checkpoint在初始化的pinned test262 submodule上完整通过，architecture dependency/OOM-panic、
public API、Debug/ReleaseFast CLI smoke、统一Debug 1585/1585与test262-smoke 12/12均为绿；当时完整ReleaseFast
test262-gate另为0/49775 unexpected。最新scope slice之后已有上述focused与checkpoint证据；
full test262/OOM injection/ReleaseSafe均未重跑，后者仍只在最终pre-commit阶段执行一次。

二次逐段对照确认下列差异仍在：

| 机制 | QuickJS 精确行为 | 最新候选状态 | 裁决 |
|---|---|---|---|
| entry environment discriminator | 每个执行frame都有真实`cur_func`；是否是global-var environment、是否暴露arguments/new.target/super由FunctionDef/bytecode与caller environment决定 | 显式`EntryContract`已接管全部语义分支；`current_function.isUndefined()`只剩generator optional-state/首次resume fallback | **迁移候选已完成**；real root不再被语义sentinel阻塞，但contract在final vardef/root完成后必须退场审计，不能当成QJS已有字段 |
| eval entry / root function | script/direct/indirect eval均先`js_closure`，root拥有真实function与最终capture array；direct-eval frame的`cur_func`是eval function | entry bypass已删除，但仍直接执行裸`Bytecode`；direct eval沿用outer `current_function_value` | 完成P1a.4 final artifact与ordinary GLOBAL selector后进入 **P1b**；caller只保留为capture source，不再兼任eval current function |
| parser declaration/lvalue topology | 正式parse按源码遇见顺序append VarDef；`push_scope`与compile-phase `scope_next`提供真实visible/child-scope关系，`define_var`独占LET/CONST/FUNCTION/CATCH/VAR的scope/parameter/global/eval冲突。identifier统一保留scope operand，完整FunctionDef建成后才解析local/with/eval-object/global；完整operand后以`last_opcode_pos/get_lvalue`分类，simple var需要reference时也走同一descriptor，call在消费点改last getter，comma/label显式invalidate。只有有源码锚点且不改topology的grammar lookahead允许重扫 | scope topology、body identity、function-var origin、non-pattern `defineVar` producer、generic-for普通LHS单遍和lexical-for单一VarDef已对齐；剩余声明旁路只有pattern `BlockScopeDecls`/switch scanner与implicit-arguments future scan，statement carrier时机仍偏早。`active_with_atom`、`peekParenthesizedBareIdent`、call state、simple-var unpatched-target make-ref与return-comma scan仍绕过resolver/last-op | **scope/body identity与declaration core/simple producer完成，reference/call未封口**；下一步CORE先做emitter transaction、last-op consumer与simple var，再清parser control；随后不可拆DSTR source→DEFINE-CLOSE→stack删pattern旁路/scan。arguments scanner由final lookup单独删除，carrier时机归最终原子checkpoint。TS namespace/using单列产品扩展，不得算QJS scope证据 |
| speculative parse / internal control topology | destructuring只由`js_parse_skip_parens_token`判别cover grammar，随后`js_parse_destructuring_element`按源码顺序一次创建binding/child/cpool；label/operand stack另行保证RHS先运行。iterator/catch state在operand stack，普通实现不创建temp local或内部JS callable | declaration/assignment先`parseDestructuringPattern(..., null)`再正式parse，回滚仅覆盖lexer/code/atom；probe生成重复`x` child、额外temp local并把后续`y` cpool从1推到2。parameter虽已token-only预读，却先正式parse outer default，把`x,d`倒为`d,x`。六个dstr helper还经`special_object + call`；八个using helper/全文预扫是独立product debt | **未对齐，新增M-DSTR-SOURCE-ORDER与M-DSTR-STACK并前移到finalizer之前**；完整parser调用不得处于partial snapshot transaction，正式parse顺序也不得为运行时求值顺序倒置。using全文预扫在M-PARSER-CONTROL-CLEANUP删除，typed transport归W1b2.6。完成前具体VarDef/cpool/child顺序均不冻结 |
| try/finally control topology | finally body只parse/emission一次；normal、throw、return、break、continue经`gosub`进入，`ret`返回，catch marker/iterator cleanup由栈协议统一 | 先`tryStatementHasFinally`扫源码，再从snapshot为不同出口重复parse/emit finally；相同源码可生成多份constants/children/atoms/code，现有`gosub/ret` production未使用 | **未对齐，新增M-FINALLY-SINGLE-BODY**；先恢复共享subroutine再改scope-close，避免在复制CFG上对齐错误leave事件；收益先记零并单独测code size/compile profile |
| closure discovery/order | 对每个FunctionDef依次重建scope→`add_eval_variables(current)`→`add_global_variables(current)`→递归children→resolve current；capture事件直接标owner，不存在事后全树clear/rebuild | candidate已实现row schema/prefix规则、identity与post-order算法并删除permutation/remap/forward retrofit；scope节点已改善，但平行declaration owner与speculative destructuring仍会改变VarDef/child/cpool index，入口又全树递归stage/prepare/clear/rebuild，atom/allocation/OOM与capture provenance并非QJS逐节点顺序 | **schema/type+source identity规则冻结，具体row index和finalizer调度未exact**；BODY identity、DEFINE close、DSTR source/stack后由M-FINALIZER-PRECHILD融合producer并删除hint replay，不按name/depth重排，也不把correctness变化计性能 |
| scope linkage / captured-cell close | `js_create_function`先破坏性重建唯一`scopes[].first/VarDef.scope_next`链；`resolve_variables`在真实`leave_scope`及parser `close_scopes`生成`close_loc`，所以cell在离开本次scope时detach | parser visible-head与exact-scope walk、for straight-line leave marker已补，但普通pop/abrupt edge尚未全发；finalizer仍保留`finalizedScopeHead/Next`，`enterScopeRefresh`又在下一次entry预先`close_loc`未来captured binding | **未对齐，拆成M-SCOPE-EVENT-PRODUCERS与M-SCOPE-CLOSE-LOWERING**；single-body finally后先建唯一事件，derived/finalizer/body完成真实capture与hoist后才降低leave并删future hint。该差异不是Zig限制，也不能只靠stdout/closure-row相同封账 |
| open-binding index / identity | `capture_var`首次真实事件编号；`get_closure_var`按`(type,index)`去重；derived `this`没有无条件capture | candidate的编号器已event-driven且identity规则正确；scope/body identity、lexical-for单一VarDef和non-pattern core已落地，但pattern旁路、statement carrier时机与destructuring topology仍可改变owner index，finalizer又无条件capture derived `this`维持`frame.this_value` alias | **算法/identity规则冻结，具体index尚未exact**；先DEFINE close/DSTR，再M-DERIVED-THIS-CANONICAL和current-before-children finalizer，之后才能以相反capture次序与同名shadow封账 |
| pseudo binding staging | VarDef append为`_var_/_arg_var_ → this/new.target/active/home → arguments → function-name`，特殊binding多由`add_var`建立、不挂scope链；最终prologue则是`home→active→new.target→this→arguments→name→_var_/_arg_var_` | candidate的单节点append内容、scope身份与最终prologue顺序已对齐并有独立快照；剩余差异只是上一行的全树多prepass调度/hint replay | **内容冻结、调度待收口**；禁止重新引入parser eager materialization或用append顺序驱动prologue，M-FINALIZER-PRECHILD只做逐节点current→children融合 |
| final vardef/eval operand | args→locals连续vardefs；`resolve_variables`把scope改为链头；runtime沿`scope_next`，parameter scope以`ARG_SCOPE_END`终止 | ordinary/parameter lookup contract已完成且删除final parallel scope/arg metadata；scope/body identity和non-pattern declaration core已落地，但pattern ledger/scanner、speculative/temporary destructuring、statement carrier时机与sloppy Annex-B仍会改变producer/index；static class-field inline eval另占`0x8000` | **record schema/lookup语义冻结，具体producer/index不冻结**；pattern owner/destructuring source+temp与finalizer/body/Annex-B按固定顺序收口；高位只随W1d真实static initializer child删除 |
| final closure row / dynamic eval | compile/final同一个8B row且没有depth；`add_closure_variables`严格按vardef/closure表序复制，lookup first-match | compile/final共享8B/align4 storage且已删除depth；eval seed与compiler probe按table-order first-match | **W1b2已完成**；C/Zig defined-mask golden及final uncaptured zero保持冻结，后续realm/owner迁移只复用storage |
| dynamic env row产生条件 | direct-eval函数在`add_eval_variables`捕获全部可见parent binding；ordinary descendant由`resolve_scope_var`先查近侧binding，再只为实际跨越的`<var>/<arg_var>`逐层建REF | 旧候选曾把每个eval var object blanket-forward到所有descendant，导致近侧lexical被outer eval对象抢先；现已删除该传播，resolver只按unresolved lookup建链 | **候选已对齐**；表序first-match与row producer必须成对锁定，禁止以“consumer顺序正确”掩盖多产row |
| finalization transfer / debug topology | cpool/atoms/artifacts move；主allocation不包含source/pc2line bytes | 当前逐项dup/copy/free，source/pc2line被复制进block | move commit与core pack分刀；不得用“allocation数下降”掩盖refcount/ownership变化 |
| pc2line artifact | buffer前两个ULEB128就是起始line-1/column-1，所有lookup只需FB的buffer+len | 起始坐标在`DebugInfo`及compat view平行字段，buffer字节与QJS不同 | **未对齐**；real root后、move commit前单独改producer/decoder并删平行字段，收益记零 |
| production terminator | parser显式return，final bytecode无隐藏尾字节 | root/eval与goto-to-end可读`code[len]` sentinel | canonical root前先补显式终止；性能收益只归移除sentinel/dispatch依赖的独立生产候选 |
| direct-eval prefix / forwarding | visible lexicals→args→unscoped vars；保留同名identity；LOCAL/ARG/REF/MODULE转REF，GLOBAL family跳过；最终eval object拥有这些slots | prefix、identity、global skip、module forwarding及final vardef链均已对齐；`eval_current_function`仍是outer，slot array仍由root adapter构造 | 不重写prefix；W1c只改eval object/capture-array所有权与`cur_func` |
| final eval/arrow/view metadata | 就这三类额外身份而言，QJS final只需combined direct-or-indirect eval位；四个grammar capability属于独立core flags，nested function不继承eval marker；无arrow位、无parallel execution view | combined marker与传播范围已对齐；arrow仍是hot flag，FB仍缓存完整compat Bytecode view，root construction仍有入口布尔 | W1b6删view；W1c1让combined bit成为closure2 construction真源；arrow在W1d lexical capture/constructibility对齐后删除 |
| ordinary global topology | root单一`GLOBAL`，descendants逐层`GLOBAL_REF`，ordinary access仍是dynamic global opcode | candidate topology已对齐并保持`get_var/put_var` | **候选已对齐**；cell source仍未完成 |
| GLOBAL_DECL cell/descriptor surgery | lexical declaration可把已有global-object VARREF的旧cell转成TDZ lexical cell，并把旧value移入新property cell；non-lexical declaration复用/建立global-object VARREF | `ensureGlobalLexicalCell`与`ensureGlobalObjectVarRefCell`已实现该拆分、flags与rollback | **已有对齐面，先加identity/descriptor锁定测试，不重写**；后续只统一consumer调用与OOM证明 |
| ordinary GLOBAL cell source | lexical VARREF→global-object AUTOINIT物化并retry→已有VARREF→shared uninitialized side table | `createGlobalClosureVarRef`、`initialClosureVarRef`与direct-eval initial path只查lexical/VARREF/side-table，遗漏AUTOINIT materialization；`createGlobalModuleVarRef`另造fresh cell | **P1b未对齐**；焦点是ordinary GLOBAL consumer的AUTOINIT retry；module fresh-cell adapter随persistent link删除，不拿来重做已对齐的declaration surgery |
| cell metadata ownership | `js_closure2`的LOCAL/ARG/REF/GLOBAL/GLOBAL_REF alias arm不按capturing row改cell flags；global declaration/create与owner VarDef/opcode各自拥有const/lexical/function-name语义 | `createBytecodeFunctionObject`取得cell后仍对LOCAL/ARG/GLOBAL/GLOBAL_DECL按capturing `ClosureVar` OR const/function-name，尽管`captureLocal`和global declaration owner已设置 | **one-pass invariant**；删除consumer-side flag mutation，或仅在证明Zig表示必须时把它移到单一owner creation点。用共享ordinary global、同cell多capture与function-name/const shadow防止alias被毒化 |
| plain var-ref write authorization | resolver把非法const/function-name写降成`throw_error`/drop；plain put/set CASE只调用`set_value` | `execPutVarRef`每次同时读cell flags和capturing ClosureVar，执行const/function-name裁决 | **P1c前置证明项**；覆盖local/arg/ref/global/module、strict/sloppy、direct eval后再删热检查，绝不先删后靠benchmark补测试 |
| `js_closure2` allocation/order | 以最终class/prototype分配function object、attach bytecode→清零最终array→eval pass1全验证→按closure顺序一次填cell→最后装length/name/prototype；module import的null staging属于module create/link | root仍placeholder/copy/replace；nested attach时还分配cached view，并在capture前做properties与多类side adapter | **ordinary P1b未对齐**；capture前只保留final object class/prototype与已拥有realm的final FB retain/attach，且attach必须无分配；module nullable slots推迟W1e，不在ordinary core伪造 |
| import-meta/private/arrow adapters | qjs从stack/bytecode取得script-or-module；private与arrow lexical state走编译期binding/capture，method/constructor的home object在capture后设置 | zjs在capture前把import-meta复制到每个nested function、安装private-name remap，并复制arrow home/super/constructor-this side slots | **默认消除并改由closure/bytecode承载**；只有给出具体Zig限制与等价证明才能保留，不能仅重新排序这些side slots |
| class-fields initializer ownership | instance initializer child写入lexical`<class_fields_init>` binding并由constructor普通调用；static initializer也建立child，随后以class作receiver立即调用；QJS无`class_static_this` kind或eval高位 | zjs instance child经`FunctionBytecode.class_fields_init`→rare payload→construct call-site注入；static initializer仍inline并用`class_static_this`、runtime vardef scan和`0x8000`传grammar capability | **W1d/full-close条件，不再冒充P1b core条件**；先迁instance lexical binding，再迁static child/immediate call并删除extra kind、scan、高位/15-bit限制 |
| private method / brand topology | private field各自以lexical `private_symbol`为identity，不需要shared brand；只有method/getter/setter令instance/static侧`need_brand`，每侧至多一个。instance initializer把prototype/home-object brand加到新instance，static brand加到class；method/accessor function保留为lexical binding，`scope_get_private_field`按VarKind lower为symbol access或`check_brand`+call/throw，不复制method property | `initializeClassPrivateMethods`遍历home-object private descriptors并逐个define到instance；private atom remap还依赖function/home-object side table；当前半迁移因没有声明slot而稳定报`ClosureVarNotFound` | **并入W1d PRIVATE-BINDING/CLASS-INIT不可拆checkpoint**；完整迁声明slot、initializer、setter companion、capture/lowering与按需brand后，删除per-instance descriptor scan/copy及name side channel。non-extensible实例也锁定pinned QuickJS结果；test262差异只记账，不作为保留旧拓扑的例外 |
| body/block/parameter scope anchor | parameter`enter_scope`先TDZ、默认值后`leave_scope`；root eval/program、parsed block/concise arrow及default constructor都push真实body scope；body `enter_scope`才注入arg/local/global hoist并随后做body lexical prep。synthetic `<class_fields_init>` aggregator是明确例外：scope0直发initializer code，不push普通body；parsed static-block child仍有body，aggregator调用它时另有wrapper scope。directive只属于program/function body；空ordinary block不建scope | candidate已统一root/program/eval、ordinary/block/concise arrow和default constructor的body identity，parameter事件、module guard及nested block entry也存在；但body尚无唯一enter marker，`resolve_variables`仍把hoist/body TDZ统一prepend到parameter/directive之前 | **identity完成、anchor未完成**；finalize checkpoint由M-BODY-HOIST-ANCHOR发/消费真实marker，并与statement carrier后置、current-before-children finalizer和scope-close原子迁移。不得给class-fields aggregator伪造body，也不得把identity完成写成runtime event已对齐 |
| module guarded prefix | 同一module function以`this=true`执行guarded declaration branch，正常求值执行body | candidate已生成guard并删除scanner/body-skip；inline eval复用同一compiled bytecode，file graph仍用不同recompile实例 | prefix子项**候选已对齐**；file graph未达到“同一function” |
| module artifact/link slots | loaded registry属于realm Context；link前按“当前module function/cells→dependencies”建完整graph；link节点按deps DFS→间接export验证→indexed imports→retain local exports→guarded declaration call→SCC commit；任一失败把linking stack全部恢复unlinked | registry当前Runtime-global；deps后先resolve imports、再ensure local export、最后检查indirect export并把本节点标linked；errdefer只清本节点且置errored。record不持久化function/capture，file graph重复compile | **W1e未对齐**；先迁per-Realm registry并持久化artifact，再按精确phase/error precedence与Tarjan transaction改indexed link；不能只把name换成index |
| module namespace/default name | normal export property直接VARREF，cycle-dependent才AUTOINIT；anonymous default由prefix`set_name default` | namespace仍data snapshot+parallel cells；default child仍parser预命名 | **W1e未对齐**；core已有VARREF，不是Zig限制 |
| descriptor / failure | successful descriptor surgery遵循qjs；仓库要求OOM完整传播与same-runtime recovery | plain-data normalization、global lexical flags仍需裁决；module/link及closure失败顺序未形成统一rollback证明 | 成功路径忠实对齐；仅GUIDE安全要求允许更强transactionality，不复制qjs failure quirk |

因此当前 P1 diff **按现状不允许整体合入 main，也不允许据此重冻 M-CELL**。先保留已证明的metadata/direct-eval
语义修复，先撤掉broken private半迁移，再按declaration scope topology→declaration owner→phase-1 emitter/reference/call（含simple var）→parser control cleanup→[destructuring source-order→define-var close→operand-stack control]不可拆checkpoint→single-body finally→scope-exit cell close/唯一scope事件→derived-`this`单一authority→逐FunctionDef pre-child/capture-once→全body producer hoist anchor→using typed product isolation→RealmRef/state→call/FB/deferred carrier→non-carrier compensation-retire→terminator→canonical root→direct-FB→GLOBAL/closure2→pc2line→
move commit→QJS core layout→QJS-order core pack完成core-close后
拆分审计、独立合入并立即重测Zoo/cell；不再让class/private/module
扩展无条件阻塞ordinary核心落地。W1d/W1e仍分别阻塞各自机制及“全部construction已对齐”的声明。

#### 新的机制收敛顺序

1. **M-ENTRY-NO-CHEATING：候选已完成，保持为永久前置门禁。**
   - numeric/eval regexp/string/caller-expression shortcut、源码strict第二真源、empty-root VM bypass、typed-array
     Dynamic Function body replacement、async-parameter token scan和synthetic parameter TDZ均已删除；这些变化收益记零。
   - 用非法`1 2`、exact/terminated eval、frontmatter strict、empty root、合法/非法await grammar、typed-array
     subclass identity/name/instance/body-side-effect及active-helper负向`rg`持续守门。
   - “入口无旁路”不等于“已有real root function”；canonical root FB在第11步落地，最终root function/cell array仍须等待
     第13步GLOBAL selector与第14步closure2。
2. **M-CLOSURE-RESOLUTION-CLOSE：capture schema/identity规则已完成；具体index等待producer收口。**
   - 保留已完成的post-order规则、event-driven编号器、exact identity、eval/declaration prefix、ordinary-global topology；禁止重做
     permutation/remap/name dedup。
   - 已对照`add_eval_variables`一次性迁移`_var_/_arg_var_`、this/new.target/active/home、arguments、function-name这组
     **pseudo VarDef append顺序**与`add_var`非scope-linked身份；parameter-scope arguments alias保留其专用link规则，parser只发
     scope bytecode，不提前改变最终VarDef顺序。
   - 已锁住`home→active→new.target→this→arguments→name→_var_/_arg_var_`最终prologue；append snapshot
     与执行snapshot分别断言，不允许一个测试替代另一个。
   - diagnostic qjs的locals/prologue快照、parameter-scope alias、显式`arguments`形参、arrow/class/super与nested eval行为已锁定；
     旧ordinary-name parser eager helper与body pre-scan已删除。closure-row schema/type+source identity与final no-depth表示冻结，但
     declaration ledger/scanner、destructuring topology、scope close/finalizer调度及Annex-B declaration VarDef顺序尚未封闭；具体`var_idx`/open-binding index不得冻结，
     也不得再引入`source_depth/scope_parents`runtime补偿。
   - dynamic environment producer按两条QJS路径锁定：只有自身direct eval运行visible-parent capture；ordinary descendant
     必须等final `resolve_scope_var`确认某个未解析名字越过该环境后才转发`<var>/<arg_var>`。保留near-lexical-shadow
     与two-eval/missing-name两个相反回归，禁止恢复blanket descendant propagation。
   - direct-FB前单独审计`codeRescuesImplicitArgumentsViaGetVar`声称的Annex B/catch/cover-grammar形状：逐个与QJS final
     bytecode对照。若存在`get_var(arguments)`，只把引用解析到当前非arrow function的arguments pseudo local；若不存在，
     删除scanner和global handler rescue。两种结果都必须以final-bytecode负向矩阵收口，不把stale adapter改名后带入FB。
2a. **M-PARSER-ONEPASS已完成slice：固定成果，不扩大结论。**
   - 已删除`predeclareFunctionBodyVars/DirectEvalReferenceScan/predeclareVarDeclarators`与
     `needs_dynamic_lvalue_refs`。`var`与direct-eval事实只由正式parse产生，`add_eval_variables`在完整FunctionDef后运行；
     `let a; var b`、nested arrow/class-method var泄漏与direct-eval前后顺序均按pinned QJS重定oracle。
   - function/program body与ordinary block已拆成两个production；directive只由program/function body消费，ordinary empty block
     不push scope。generic for-in/of普通LHS已按`js_parse_for_in_of`只构造一次，以label让iterable先运行，再用bottom-stack put
     消费next value；原lexer replay与`value_loc`已删除，但`classifyLhs/validateForInOfGenericAssignmentTarget`及
     `peekParenthesizedBareIdent`仍在手写shape→put分支，因此只冻结single-parse/control layout，不宣称统一lvalue完成。
     lexical declaration head的pop/push/re-add scope差异也不属于这个已完成slice，明确由2a0收口。
   - 当前最新focused出口是parser 395/395、bytecode 98/98、exec 282/282、builtins 175/175与quick-check 3/3；随后checkpoint 32/32、统一Debug 1609/1609与test262-smoke 12/12也通过。它只证明以上slice及随后scope/define-var/export-order改动；full test262/OOM injection/ReleaseSafe未重跑，
     余下declaration owner、通用lvalue、destructuring与control topology仍不得标成exact。

2a0. **M-DECL-SCOPE-TOPOLOGY（identity完成）：先恢复声明可依赖的scope identity。**
   - 逐个对照QuickJS全部`push_scope/pop_scope/close_scopes` callsite，先恢复parser-time linkage：`pushScope`令新scope的
     `first`继承当前`scope_first`，lexical `addScopeVar`以`scope_next`prepend可见链，`popScope`恢复父scope可见头；
     current-scope查询遇到第一个不同`scope_level`即停止。现有`appendScope(first=-1)`/same-scope list不再冒充QuickJS。
   - catch必须是catch binding scope → catch wrapper scope → ordinary nonempty body scope，保证后续`define_var`的catch `scope+2`
     规则有真实拓扑；switch所有case共享一个scope；with在独立scope放`_with_`；if/普通for/for-in/of及class name/private
     initializer的声明scope/parent逐项锁定。这里只建立scope node和父链，不用feature scanner补未来声明；root/concise arrow/
     generated constructor的统一body event仍归M-BODY-HOIST-ANCHOR，static initializer真实child仍归W1d。
   - lexical for-in/of只创建一个head scope和一组VarDef。iterable求值后、body正常末尾及loop exit复用通用
     `emitLeaveScope/closeScopes(scope, stop)` primitive，不再`popScope→pushScope→addScopeVar`复制binding；同一cell的每轮detach时序
     与QJS pass1/pass2对照。诊断probe `function f(a){for(let x of a){function g(){return x}}}`现在只有一个`let x` local，
     iterable后、body后与exit也复用同一binding的leave primitive；完整abrupt-edge/最终`close_loc`精确时机仍由后续event/lowering验收。
     该primitive是后续M-SCOPE-EVENT-PRODUCERS/M-SCOPE-CLOSE-LOWERING的唯一基础，不建立for专用close helper。
   - 本步只接入声明拓扑和for straight-line边界；return/throw/break/continue/finally跨scope的完整close矩阵、entry future-hint与
     captured-cell detach全量证明仍归M-SCOPE-EVENT-PRODUCERS与final checkpoint的M-SCOPE-CLOSE-LOWERING。若finally复制尚在，禁止在本步向每份copy散播leave修补。

2a0b. **M-BODY-SCOPE-IDENTITY（identity完成）：先补`define_var`会读取的body边界，不提前搬hoist。**
   - QuickJS root script/module/direct/indirect eval在parse program前push scope1并写`body_scope`；普通/arrow function在参数结束、
     generator initial-yield之后push body；default class constructor显式push。当前candidate已经统一这些节点、parent和`body_scope`，
     但仍没有body enter marker；因此identity完成只允许`define_var`读取正确边界，不能当作hoist/runtime event完成，
     因为`define_var`直接以`scope_level == body_scope`裁决parameter冲突以及global/module eval lexical carrier，不能等声明迁完再改scope编号。
   - 这一步只建立identity并让phase-1 operand使用新scope；hoist/TDZ仍由既有路径暂时消费，不能同时加第二份初始化。
     最终marker及hoist迁移归M-BODY-HOIST-ANCHOR，并与M-FINALIZER-PRECHILD同一checkpoint收口。
     代码落地必须与M-DEFINE-VAR-CORE同一parser checkpoint更新所有top-level/body判断；scope1身份不得作为可独立合入的半成品。
   - `js_parse_function_class_fields_init`是源码确认的例外：synthetic instance/static fields aggregator保持scope0且不push普通body。
     parsed static-block child仍按普通function有body；aggregator在调用该child时的额外push/pop wrapper归W1d class initializer迁移。
     TS namespace另建scope是产品扩展，不得借本步获得QJS body身份。

2a1a. **M-DEFINE-VAR-CORE（core/simple producer完成）：建立声明语义唯一core，但不在双parse上伪造“全部producer完成”。**
   - function-scoped VAR仍以`scope_level=0`存储，但正式parse期间把声明发生的lexical scope写入`scope_next`，供
     `find_var_in_child_scope/is_child_scope`使用；后续M-FINALIZER-PRECHILD再像`js_create_function`破坏性重建最终runtime链。
     在此之前`finalizedScopeHead/Next`只能是明确的临时final consumer，不能反过来决定parser declaration lookup；禁止新增
     `origin_scope`、ledger或第二graph延续旧same-scope-list契约。
   - 在该链上按QuickJS `JSVarDefEnum + define_var`建立单一phase-1 API；WITH、LET、CONST、FUNCTION_DECL、NEW_FUNCTION_DECL、
     CATCH、VAR都通过同一入口映射到真实`FunctionDef.vars/scopes`。该API必须同时拥有：当前scope lexical重定义、sloppy Annex-B
     function例外、catch `scope+2`冲突、`find_var_in_child_scope`、body parameter冲突、global/eval global-var分支、VAR沿可见
     lexical链检查与function var复用。Zig只允许改变表示/错误返回方式，不允许拆成语义不同的预扫账本。
     像QJS `js_define_var`一样保留一个薄token/name wrapper处理generator `yield`、strict `eval/arguments`与lexical `let`等语法限制；
     wrapper不拥有scope冲突或追加规则，function/class/catch等非普通var语法可直接调用同一`defineVar` core。
   - 不依赖pattern replay的producer已迁入：simple var/let/const、function/class statement、simple catch、switch/simple for-head、with及
     using product declaration；simple catch与classic/for-in/of的future-source scanner已删除，SyntaxError只由真实scope链产生。
     pattern declaration/catch/parameter/for-head仍走双遍历与平行账本，必须在M-DSTR-SOURCE-ORDER后接回core；不能保留
     “预声明模式”或为了第二遍放宽duplicate规则。
   - QuickJS function statement的parent carrier在child完整解析后才建立；block lexical例外地在child前建立，Annex-B outer在child后。
     zjs当前仍为全树staging提前建立body/global/Annex-B outer carrier。它不是`defineVar`算法缺口，必须由
     M-FINALIZER-PRECHILD与M-BODY-HOIST-ANCHOR原子迁移；producer必须拆成QJS已有的preflight与post-child commit：module-eval
     same-scope GlobalVar检查、block lexical row和Annex-B eligibility保留pre-child，body local/arg `func_pool_idx`、global carrier与
     Annex-B outer row后置。锁定SyntaxError位置、child/cpool是否已构造和Nth-OOM，不得只比最终row；在此之前不得写
     “non-pattern append order exact”。
   - 明确低层边界：private field/method/accessor走QJS `add_private_class_field→add_scope_var`；function-name/arguments/this等pseudo、
     parameter-expression scope向variable scope复制的名字、script/eval completion `<ret>`及共享finally保存slot走`add_var`，都不是普通
     `define_var`；Annex-B outer var也是明确绕过lexical check的post-child `add_var`。`<class_fields_init>`则是private scope内的
     `define_var(CONST)`，其源码后置append与constructor phase-1 lookup需在class initializer机制中恢复。不能为了口号把这些低层row
     塞进错误API，也不能让它们继续调用散落的普通声明裁决；当前finally synthetic-name多row由M-FINALLY-SINGLE-BODY删除。
   - 本步出口是core算法和non-pattern producer，不删除仍由pattern双parse支撑的全部scanner，也不宣称declaration owner已封口。
     同一probe仍同时比phase-1 VarDef append顺序、scope level/kind与final bytecode，覆盖switch、simple catch/for、parameter/function/
     arguments、global/eval/module及sloppy Annex-B；Nth-OOM后同runtime恢复。

2a2. **M-LVALUE-PROVENANCE-CORE：让最后发射指令成为普通reference和call receiver的唯一事实。**
   - 先建立一个最窄但真实的**phase-1 emitter transaction**。code bytes、atom operand、source marker/`source_loc_slots`、label/fixup
     refcount与`last_opcode_pos`必须先reserve或能完整rollback，再一次commit；只有真实opcode append成功后才发布last-op。当前
     `beginOpcodeNoSource`在append前改状态、`emitOwnedAtom*`在code成功前转移atom owner都不允许保留。Nth-OOM后code/atom/source/
     provenance长度和owner必须回到调用前，同runtime继续编译金丝雀；这只是correctness prerequisite，不冒充W5 peephole收益。
   - 复用每个`FunctionDef`自己的`last_opcode_pos`。`line_num`、source-location bytes、operand append和optional-chain raw end label不更新；
     normal label、comma、CFG merge、detached-code splice和明确non-reference boundary令其失效。完整parser transaction必须保存/恢复它，
     但不得从token/source tail、最终代码字节模式或“最后看起来像identifier”的缓存重建。
   - CORE production的`getLvalue`只接受最后实际发射的`scope_get_var/get_field/get_array_el/get_super_value`，截去getter并返回
     `{opcode,scope,owned_atom,label_ref,depth}`。最终`get_var`只可留在明确的fixture/legacy Bytecode builder adapter，production parser
     不得借它绕过phase-1；`scope_get_private_field`variant在W1d声明槽存在后才启用。`putLvalue`逐字对应QuickJS五种
     `NOKEEP/NOKEEP_DEPTH/KEEP_TOP/KEEP_SECOND/NOKEEP_BOTTOM`。strict `eval/arguments`、`this/new.target`及非reference末条按
     assignment/update/for/destructuring调用语境产生对应SyntaxError/message；不能把所有失败压成一个generic target error来过stdout测试。
   - assignment无条件`KEEP_TOP`；logical assignment无条件按depth insert，再`NOKEEP_DEPTH`，skip臂逐depth `nip`；prefix/postfix固定
     `KEEP_TOP/KEEP_SECOND`；generic-for固定`NOKEEP_BOTTOM`。expression statement在完整expression形成后才drop/completion-store，
     `result_needed`与`suppress_expr_statement_drop`不得改变reference/update协议；discard、`inc_loc`等融合只能由QJS对应final pass证明。
   - descriptor承接被截getter atom的唯一live retain。re-emit需要另dup，make-ref operand也另dup，put成功才把descriptor owner转给setter；
     所有语法/OOM/patch失败出口各释放一次。getter前已有source marker保留，re-emit/make-ref/stack shuffle/put不新增marker。source锚点
     明确冻结：plain与logical assignment不因assignment operator新增marker；compound、prefix、postfix只在operator；simple var initializer
     在`=`；call在`(`/template token。phase-1 bytes、pc2line/source-loc、atom accounting和Nth-OOM必须同时与diagnostic qjs对照。
   - identifier无论是否位于with、是否是`eval`、是否括号包裹或紧跟call，都先发带scope operand的`scope_get_var`。`with`只通过
     `define_var(_with_)`进入scope链；assignment在`has_with_scope`成立时由正式
     `scope_make_ref(label_ref)→[get_ref_value]→label→put_ref_value`在RHS前固定reference。普通路径resolver直接消费该label identity，
     不得调用`findGlobalRefPutTail`猜尾部。zjs absolute-offset fixup只有在producer、relocation和resolver均证明与QJS LabelSlot等价时才可
     作为表示适配；否则采用LabelSlot，不能增加扫描。
   - 把simple `var` initializer纳入同一consumer：`needVarReference`成立时严格发
     `scope_get_var→getLvalue(false)→RHS/set_object_name→source(=)→putLValue(NOKEEP)`；let/const和无需reference的var仍走直接init/put。
     删除普通`parseVar`的unpatched-target `emitScopeMakeRef`。旧destructuring unpatched-target producer与tail-scan fallback可具名留到紧随其后的M-DSTR，
     但CORE出口普通reader必须为零，M-DSTR完整出口二者必须全仓为零。
   - 新建唯一`rewriteCallReference`，只在真正call/tagged-template消费点读取last-op：field→receiver-preserving field getter，index同理，
     `get_super_value→get_array_el`，scope var先判非optional ordinary `eval`，再判with并改`scope_get_ref`，其余为plain call。
     spread/非spread共用该分类；`new`不继承method receiver，tagged template也不误判direct eval。删除
     `last_was_direct_eval_callee`、`last_was_with_method_ref`、parenthesized tail rewrite及member parser对后续`(`的getter选择。
   - optional chain整条链惰性创建且只共享一个`LabelSlot/LabelRef`；每个`optional_chain_test`直接branch到它，不保存per-`?.` exit。
     链尾用不更新last-op的相邻raw label结束，再把最后field/index getter改为`*_opt_chain` marker。method call把marker改为receiver getter、
     截去相邻raw label并给短路臂补额外`undefined` receiver；delete从同一marker取label并路由到`drop; true`。删除
     `last_opcode_is_optional_chain`、固定16项buffer、`collectOptionalChainExits/promoteTrailingOptionalChainExitForMethodCall`及signature scan，
     并联审phase-1 decoder、label resolver、code splice/relocation和OOM；合法链长不产生per-exit allocation。
   - 当前步迁assignment、compound/logical assignment、prefix/postfix、`typeof`末条scope-get patch、`delete`、simple var、generic
     for-in/of及全部ordinary call；generic-for已有label/bottom-put只是首个consumer。删除`classifyLhs/
     validateForInOfGenericAssignmentTarget`、`peekParenthesizedBareIdent`、`force_with_lvalue/skip_next_ident_get`、dead delete-super shortcut、
     `scope_no_dynamic_env_flag/selected_reference/emitScopePutVarNoDynamicEnv`。QJS resolver正常生成的`with_get_ref/with_put_var`保留。
     `active_with_atom`对ordinary expression/call为零reader；若旧pattern仍读，只能具名留到M-DSTR。
   - private不是CORE特例。先把当前半迁移的member producer恢复到此前可运行的private transport，只锁行为不退化，不把它写成QJS exact；
     禁止用atom fallback、空VarDef或descriptor copy补`scope_get_private_field`的一半。W1d一次完成声明槽、初始化、capture、VarKind和按需brand后，
     private才成为同一descriptor/call rewrite的正式variant。
   - 出口oracle至少覆盖`(eval)()`、`(0,eval)()`、`eval?.()`、tagged-`eval` template、with内shadow/global eval、spread/nonspread、`new`、super、
     parenthesized field/index、tagged template、optional method/delete和超过16段的链；另锁comma/label失效、computed function/class/arrow key
     单child/cpool、zero/multi-iteration与operator source。phase-1/final bytecode、运行顺序、atom owner及Nth-OOM均对照diagnostic qjs；
     private只锁baseline且已知3个`ClosureVarNotFound`必须先消失，本步才可成为合入候选。

2a3. **M-PARSER-CONTROL-CLEANUP：最后删除无QJS锚点的source/control shortcut。**
   - pinned QuickJS的return先完整`js_parse_expr`，再由`emit_return`处理finally/iterator/derived constructor；parser没有
     return-mode向conditional branches下推tail-call的producer。删除`returnExprOperandHasFollowingTopLevelComma`及parser内
     `call→tail_call`重写，保留语义/栈安全回归并改用QJS final-bytecode golden。若产品仍要尾调优化，只能在语义bytecode完成后
     作为显式启用且QJS baseline默认关闭的独立CFG pass实现、单独A/B；不得用parser flag或source rescan恢复，也不得把该扩展输出计入
     final-bytecode exact结论。
   - 不做“所有lookahead归零”：逐个清点`ParserSnapshot/LexerReplayPoint`。只保留有QJS
     `js_parse_skip_parens_token`等锚点、且不append VarDef/child/cpool/capture/atom owner的token-only grammar scan；regexp slash
     判定属于lexer，TypeScript erasure是命名product frontend。调用正式`parse*`却只回滚lexer/code/atom的partial transaction一律禁止。
   - `blockDirectUsingDeclarationKind/programDirectUsingDeclarationKind`全文预扫改为正式parse逐scope累积typed compile record/anchor；
     八个using helper与runtime unwind transport仍归W1b2.6，不让reference没有的产品feature反向塑造ordinary parser。
     pattern-specific名字/shape/replay在紧随其后的M-DSTR-SOURCE-ORDER一次删除，不在本步制造半套解构。
   - 出口跑parser/bytecode、exec、相关test262与Nth-OOM，再单独测compile-only large-function/regexp-literal corpus。
     删除重复lexer工作只记候选；最终bytecode/语义未对齐前收益仍记零，不得把少解析一遍当成跳过grammar验证。
2b. **M-DSTR-SOURCE-ORDER：先消除会污染FunctionDef的speculation与构造顺序倒置。**
   - destructuring cover grammar只允许对应QJS `js_parse_skip_parens_token`的token-only判别；随后由一个正式pattern traversal同时建立
     binding、child/cpool、default initializer和source-position。删除`destructuring_predeclare_only`及“完整parse→只truncate code/atom→
     完整parse”路径；任何失败要么发生在无topology的scan，要么由真正拥有全部FunctionDef mutation的transaction完整回滚，不能只补child rollback
     把双parse继续包装成正确。
   - 单遍不仅指“每个child最终只留一份”，还必须保持QJS的**源码构造顺序**。declaration/assignment/parameter都先按源码遇见顺序
     parse pattern、computed target与各层default initializer，再parse outer initializer/RHS；需要RHS先运行时，像QJS一样用`label_parse/label_assign`
     与stack上的value把控制流织回pattern，不得先正式parse RHS后靠lexer replay补target。锁定
     `function f({a=function x(){}}=function d(){}){}`为child/cpool `x,d`，以及declaration/assignment的
     `{a=function x(){}}=function y(){}`都只生成`x,y`而非当前`x,y,x`，也不能“修复”为`y,x`。nested pattern、computed key/target与for-in/of
     同样按source-position建立child/cpool/atom；运行时求值顺序另由最终bytecode golden证明。
   - duplicate/redeclaration validation也合并进这一次traversal：删除parameter/arrow/catch的
     `collectParamPatternDupNames/collectArrowPatternBindingNamesSnapshot`，像QJS `js_parse_check_duplicate_parameter`一样在正式遇到binding时检查。
     删除`scanBindingPatternForTrailingDefault`对名字数组的收集，以及`arrayLiteralPatternCandidateIsMemberTarget`、四个
     `arrayPatternContains*`、`objectLiteralPatternCandidateIsMemberTarget`、`destructuringAssignmentTargetCanStart`与
     `thisPrivateAssignmentTargetFollows`这套shape grammar；assignment target统一正式parse完整LHS后交`get_lvalue`。必要的ellipsis/outer-delimiter判断只保留
     QJS `js_parse_skip_parens_token`等价的topology-free bits，不retain property atom、不分配binding-name数组。
   - 这次唯一traversal必须迁完**所有**pattern target，而不只是通用member helper。`var` binding在`need_var_reference`时也先发
     `scope_get_var→getLvalue(false)`；assignment target直接parse LHS后取descriptor；let/const只保留QJS的direct init。每个reference
     使用CORE交付的正式label/fixup，删除`captureDestructuringVarBindingRef`、unpatched-target `emitScopeMakeRef`和以三个temp local搬运
     base/key/value的旧路径。若旧special helper无法承载descriptor depth，不准为source-order阶段新建第四种spill adapter：2b/2b1/2c
     是同一`M-DSTR-QJS-TRAVERSAL`checkpoint的内部切片，中间态不得合入或宣称机制对齐。
   - 最终bytecode还要锁QuickJS看似反直觉但可观察的reference时机：对象显式target先求值并固定reference，再执行source
     `get_field/get_array_el`，之后才判断/执行default并put；object rest同样先固定target，再`copy_data_properties`。数组元素先求值并
     固定target，再以descriptor depth执行`for_of_next`，之后default、put；computed source key仍在target之前按源码求值。
     这些顺序分别用getter/proxy/call/throw probe对照，不可只由stdout相同推断。
   - 出口先只冻结source topology：declaration/assignment/parameter/catch/for pattern各源码片段只正式parse一次，child/cpool/VarDef/atom
     按QJS source position出现；pattern binding在outer default/RHS child被解析前已经建立。default child捕获同一pattern binding、direct eval、
     anonymous function name及Nth-OOM也按该顺序锁定。本步不夹带using feature；iterator transport允许作为未完成的2c内部态存在，
     但不能为使2b单独绿色而增加新runtime/reference机制。
2b1. **M-DEFINE-VAR-CLOSE：让单遍pattern producer接回唯一声明owner并退掉平行账本。**
   - 只在2b证明每个pattern恰好一次正式遍历后，把declaration/parameter/catch/for-head destructuring binding callback全部接到
     M-DEFINE-VAR-CORE；duplicate parameter、catch `scope+2`、body parameter conflict、VAR child-scope conflict不再由pattern名字数组或
     token scanner预判。不得新增“predeclare-only define”模式，也不得让第二次相同名字调用被静默当作复用。
   - 全部pattern producer迁完后删除`BlockScopeDecls`、`validateSwitchCaseBlockDeclarations`及仅服务它们的register/check；
     simple catch与for scanner已由真实scope链替代。`remainingBlockHasDirectFunctionDeclarationName`不是pattern债务：later
     `function arguments(){}`要在final lookup自然压过implicit arguments后单独删除；若probe不绿，修scope/pseudo precedence，
     不恢复future-name scan。
   - 出口覆盖simple/pattern catch、switch多case、for lexical head+body var、parameter/function/arguments、global/eval/module与sloppy Annex-B；
     同一probe同时比较phase-1 VarDef append顺序、scope/kind、final bytecode和SyntaxError，Nth-OOM后同runtime恢复。到此才允许写“声明owner唯一”。
2c. **M-DSTR-STACK：再把解构运行时状态恢复为QJS operand-stack协议。**
   - array pattern恢复QJS `for_of_start/next`、`iterator_close`与BlockEnv catch-offset stack协议；object rest使用
     `copy_data_properties`语义。删除destructuring Ordinary state、frame-wide iterator扫描、为搬运RHS/iterator而追加的非QJS temp local，
     以及六个dstr `special_object + call` helper/function/root。最小`x/x/y` probe出口必须只有`x,y`，`f`的locals/cpool与QJS均为2；
     后续child cpool index、raw VarDef及Nth-OOM逐点相同。
   - `for_of_next`的depth和`copy_data_properties`的depth bits直接运输2b形成的reference stack，不把target重新求值，也不把reference
     降成runtime object。到本步结束，ordinary/simple-var和全部pattern的make-ref都由正式label直达put；删除
     `findGlobalRefPutTail`的16-instruction fallback及仅服务它的decoder/stop-list。若保留任何direct-target优化，它只能读取正式label/fixup，
     与QuickJS `optimize_scope_make_ref(LabelSlot.pos)`逐项对应。
   - 负向出口：六个dstr helper/record及其Runtime roots、dstr `special_object + call` producer、destructuring完整试解析、partial snapshot
     mutation、Ordinary iterator state、frame scan、unpatched-target make-ref、bounded tail scan和pattern temp-ref transport均为零。覆盖
     nested/default/rest/elision/computed-key、assignment/declaration/parameter、
     iterator return precedence、generator/return/throw abrupt close及每个allocation点恢复。八个using helper不属于本刀出口。
2d. **M-FINALLY-SINGLE-BODY：恢复QJS `gosub/ret`共享finally。**
   - 删除`tryStatementHasFinally`源码预扫和`parseFinallyBlockForAbruptPath/ReturnPath`的snapshot重解析；parse try/catch时像QJS预建
     catch/catch2/finally/end labels与BlockEnv，占位label允许事后确认有无finally，不需要预知未来token。
   - finally源码只parse一次、只创建一组VarDef/child/cpool/atom/source-position；normal、caught/uncaught throw、return、break、continue
     和iterator-close路径用`nip_catch/gosub`进入同一body，末尾`ret`。现有production `gosub/ret` VM实现先做语义审计，若有缺口修通，
     不再用复制finally规避它；async generator在进入finally前await return value的QJS顺序保持。
   - script/eval completion存在时，QuickJS在共享finally label处只调用一次`add_var(JS_ATOM__ret_)`保存旧completion，再设主`<ret>`为
     undefined，执行唯一body并按normal/abrupt结果恢复。删除每份replay创建的`__finally_ret_N` atom/VarDef；raw vardef必须是与主slot
     同名的第二个`<ret>`且append时机、局部index、atom retain和Nth-OOM都与pinned QuickJS一致，不能只锁最终stdout。
   - 对照QJS锁定无finally的catch tail-position、有finally的return value、nested try/finally、labelled break/continue、for-of iterator close、
     throw in catch/finally、async/generator suspend与eval completion；同一finally含function/regexp/string literal时cpool/atom/code只出现一次。
     code size随finally body线性增长而不随exit数相乘，Nth-OOM释放唯一artifact。此项correctness/control-flow收益先记零，之后才允许profile。
2e1. **M-SCOPE-EVENT-PRODUCERS：在finally控制流唯一后补齐phase-1 scope事件。**
   - 前置M-DECL-SCOPE-TOPOLOGY已固定scope node/parent/visible-head、catch wrapper、lexical for单一VarDef，并建立唯一
     `emitLeaveScope/closeScopes` primitive及for straight-line调用点。本步只让所有真实parser edge生产同一事件，不降低成
     `close_loc`，不得重建第二套scope API或重新复制loop binding。
   - QJS ordinary nested scope的`push_scope/pop_scope/close_scopes`保留真实`enter_scope/leave_scope`；parameter-expression scope
     显式leave，function/root body只有一次enter、没有pop/leave。普通block fallthrough、if/switch/catch/with/class pop、classic/for-in/of
     iteration/exit以及BlockEnv break/continue跨scope都复用唯一primitive；return与throw不合成leave，frame teardown关闭剩余refs，
     throw到同frame catch也不伪造词法unwind事件。single-body finally之前不得向每份copy散播事件。
   - 逐项冻结empty/non-empty block、Annex-B if、classic for、for-in/of、switch、catch三层、with、class-name/private、parameter/body/root。
     body marker本身由M-BODY-HOIST-ANCHOR统一生产；synthetic class-fields aggregator无body，static-block child/wrapper留W1d。
     每次QJS真实event都必须在phase-1出现，即使该scope当时无binding；不得给empty ordinary block或TS namespace伪造QJS证据。
     本步只完成producer，不以当前future-capture resolver的输出宣称cell lifetime已对齐。
2f. **M-DERIVED-THIS-CANONICAL：删除derived `this`的伪capture与双authority。**
   - QJS的derived constructor按需append lexical `this`，prologue设TDZ，`super()`用`put_loc_check_init`初始化；只有nested
     arrow/function、direct eval或真实reference capture才调用`capture_var`。无这些consumer的最小constructor最终
     `var_ref_count=0`。当前zjs finalizer无条件`captureLocal(this)`并由`linkDerivedConstructorThisLocal`把local与
     `frame.this_value`再绑一次，既改变index/OOM，也让两个slot可能漂移；没有Zig表示限制支持它。
   - 让derived return、field initializer与`this`检查只读canonical lexical local；删除unconditional capture、link helper和
     `put_loc_check_init`对第二`frame.this_value`的同步。nested arrow/direct eval沿普通scope resolver取得同一local cell；非derived
     call receiver若仍需frame field不得反向成为derived authority。本步不夹带private method/static field feature迁移。
   - 锁无capture/arrow capture/direct-eval capture三组var_ref index，double `super()`、pre-super read、object/primitive return、
     base/derived/default/user constructor及field initializer；OOM覆盖cell仅在真实capture时分配。此项收益记零。
2g. **M-FINALIZER-PRECHILD：把全树多prepass收回QJS逐FunctionDef调度。**
   - 当前`prepareFunctionDefsForFinalization*`依次递归`stageOwnEvalPseudoBindings`、
     `prepareDirectEvalAndGlobalClosures`、`clearCaptureHints`、`rebuildCaptureHints`整棵树；QJS在
     `js_create_function(current)`中先完成current的scope linkage、eval pseudo/capture与global declaration carrier，随后才递归child，
     child的真实capture事件直接标parent。两者最终row现已相同，但capture-state provenance、atom retain、allocation peak和Nth-OOM顺序不同。
   - 每个current入栈时先像QJS一样**破坏性重建一次**`scopes[].first/VarDef.scope_next`并写`ARG_SCOPE_END`；随后append不挂scope的
     eval pseudo bindings、执行own eval capture、append GlobalVar carriers。最终resolver和vardef pack都读这条唯一final链，删除
     `finalizedScopeHead/Next`平行计算。pseudo binding仍遵守QJS `add_var`身份，只有`arguments_arg_idx`允许显式接到parameter scope。
   - QJS同一`add_global_variables`阶段还会以最终closure表解析module local export，并在递归child前写
     `JSExportEntry.u.local.var_idx`；当前zjs `validateModuleLocalExports`只在parser末尾按名字确认存在，`Record.Export`也尚无该indexed carrier。
     这项明确留给W1e的persistent module/indexed link，不得在W1b2.5临时把index前移到parser，也不得据普通script/eval finalizer
     完成就宣称module `add_global_variables`阶段exact。
   - 将其余单节点producer组合为`prepareCurrentBeforeChildren(current, root_view?)`，由唯一finalizer DFS在入栈时执行；child完成后仍按
     bytecode encounter resolve parent。本步删除clear/rebuild future-hint replay，让direct-eval和child capture事件直接调用唯一
     `captureBinding`设置owner状态与index；production中`.is_captured = true`不得再散落在parser/direct-eval helper。前一步只生产的
     `leave_scope` marker保持到current resolver，随后M-SCOPE-CLOSE-LOWERING才能按这份最终capture事实生成`close_loc`。
     `add_eval_variables`只在pre-child捕获own args→scope0 vars；ordinary outer reference、with/eval-object与private-name capture继续在
     current resolver的真实lookup事件发生；block eval chain在扫描`OP_eval`时捕获，mapped arguments仍像QJS在`resolve_labels`晚捕获，
     四类不得合成一次eager全量capture。production同时删除`installChildFunctionBytecodes`完成child后的capture与
     `runPhases.reconcileCapturedBindings`再次idempotent replay这组双consumer：唯一child-complete事件只交付一次parent capture；
     hand-built Bytecode兼容若仍需reconcile，隔离成fixture-only adapter。不得重新扫描source、不得按name排序、不得改变event-driven open-binding index。
   - 结构出口为每个节点的pre-child snapshot、已冻结row schema/identity golden与vardef record bytes不变，production capture mutation只有
     `captureBinding`一个入口且每个事件计数恰好一次；具体index以M-DECL-SCOPE-TOPOLOGY、M-BODY-SCOPE-IDENTITY、M-DEFINE-VAR-CLOSE、M-LVALUE-PROVENANCE-CORE、M-DSTR-SOURCE-ORDER与M-DSTR-STACK后的QJS顺序为基线，
     Annex-B declaration append由下一项单独改。
     failure出口覆盖parent准备第N项、child第N项和sibling失败时已准备atom/row恰好释放。此项只对齐编译调度与所有权，性能收益记零。
2h. **M-BODY-HOIST-ANCHOR：让所有拥有body scope的producer在真实`enter_scope`消费hoist。**
   - 建立唯一`beginFunctionBody` producer：ordinary/block-arrow为a0b已有节点补唯一marker；concise arrow也在真实body scope解析表达式；
     synthesized default constructor走同一入口；root script/module/direct/indirect eval在directive解析前push真实body scope并发marker。
     synthetic `<class_fields_init>` aggregator保持QuickJS的scope0直接code，绝不能走该入口；W1d创建/迁移parsed class-static child时只能
     复用普通function入口，并另恢复aggregator调用它的wrapper scope，不能为aggregator伪造marker或提前宣称class topology exact。
     所有**源码声明位置**的“位于body顶层/是否block”判定改为`scope_level == body_scope`或显式environment kind；
     QJS明确用`vd.scope_level == 0`表示unscoped var storage/hoist时仍保持literal scope0，不能机械替换成body_scope。禁止只给root伪造scope0 marker。
     marker位于parameter初始化/parameter `leave_scope`及generator initial-yield之后、directive/body runtime bytecode之前。
     `resolve_variables`扫描到它时按arg index→local index→GlobalVar order写`instantiate_hoisted_definitions`，随后写body lexical
     function/TDZ初始化，再删除marker。`instantiate_hoisted_definitions`也是`GlobalVar` buffer的唯一消费点：逐条释放name并清空buffer，
     后续阶段不得保留第二份global declaration列表。body arm不发M-SCOPE-CLOSE-LOWERING所删除的nested re-entry refresh；parameter与nested block继续走各自真实事件。
   - `GlobalVar.cpool_idx`成为top-level/module/eval function hoist的唯一carrier；证明production `emit_top_level_closure_init`循环恒被
     `functionHasGlobalFunctionVarCpool`挡住后，删除`emit_top_level_closure_init/top_level_closure_var_idx`和child-list补发，不保留第二真源。
     sloppy Annex-B block function按QJS先append lexical FunctionDecl并记录其index，child完成后才append/复用外层var；入口初始化lexical、
     source-position copy写outer var。锁定raw VarDef顺序和两个`fclosure`目标，不能只锁stdout。
   - direct-eval conflict throw仍在special-slot prologue之后、body entry之前；module的`push_this/if_false/.../return_undef`仍包住global
     declaration branch，但body TDZ只在normal evaluation入口执行。simple-catch同名direct-eval `var`只实现pinned QuickJS实际产生的
     declaration target与初始化解析顺序，不再额外制造“caller VariableDeclarationEnvironment第二target”；相关ensure不得提前到parameter
     defaults之前或移到runtime declaration scanner。
   - 用`default parameter → body function hoist/body lexical`、root directive completion与concise-arrow的qjs/zjs pass1/final-bytecode顺序，
     加closure allocation Nth-OOM、derived/default constructor、generator、direct eval、module guard及Annex-B block-function矩阵验收。
     当前相同stdout只算语义回归，不算机制证明；收益记零。
2h1. **M-SCOPE-CLOSE-LOWERING：用最终capture事实消费唯一leave事件。**
   - `resolve_variables`的普通`enter_scope`只做该scope的function initializer与TDZ；body enter走2h的hoist arm且frame cell本来fresh，
     不执行nested re-entry refresh。`leave_scope`只遍历该scope exact rows，并仅为最终`is_captured` local发`close_loc`后删除marker。
     删除entry-side `localIsCaptured` detach、对子closure表的旁路scan和所有按词法类型手写close；uncaptured lexical不得产生cell操作。
   - 当前`enterScopeRefresh`在下一次entry预先detach“未来可能capture”binding，改变final bytecode、cell allocation/release与Nth-OOM；
     e1/g/h完成后必须归零。return/escaping throw只走frame teardown，同frame catch接住throw时不可见open ref也留到frame teardown，
     不以structured-language直觉添加QuickJS没有的leave。
   - 用同一最小loop锁定`fclosure/TDZ/body → close_loc → update/backedge`，覆盖normal fallthrough、break/continue、try/catch/finally、
     throw-to-same-frame-catch、nested loop、parameter closure、direct-eval before/after exit与未capture control。旧迭代closure保留旧cell，
     新迭代取得新cell；final bytecode、open-ref计数、GC与Nth-OOM同构。到此才允许声明ordinary/core scope close完成，收益记零。
2i（W1b2.6）. **M-USING-TYPED-CONTROL：在core compiler封口后隔离无reference产品特性。**
   - pinned QuickJS没有explicit-resource-management；不得让该feature继续决定QJS core finalizer顺序。前置
     M-PARSER-CONTROL-CLEANUP必须先把全文预扫换成per-scope typed compile record/anchor；本步只把八个using
     `special_object + call` helper改成最窄typed opcode/continuation，沿active
     RealmContext并使用结构化scope/unwind状态，不创建无name/prototype/realm的JS function，也不复用C_FUNCTION_DATA临时壳。
   - `internal_destructuring_helpers`剩余using slots、function/record/cache/trace/free与special-object producer均为零；sync/async using的
     normal/throw/return/break/continue、nested disposal order、suppressed-error precedence和每个allocation点恢复通过。它是具名product extension，
     无QJS bytecode exact声明、收益记零；可以与W1b2.5分开合入，但必须先于W1b3b callable inventory。
3. **M-ENTRY-ENV-CONTRACT：迁移候选已完成，冻结并准备退场。**
   - direct-eval global-var environment、implicit arguments、new.target/super与global IC均已改读一个通用contract；全仓
     `current_function.isUndefined()`只剩generator optional-state/首次resume fallback。
   - 保持现有行为矩阵，不再给contract加字段。第14步real root function落地时先删除`var_environment`与root身份补偿；
     `has_arguments_binding/has_this_binding`等第19步class/arrow capture对齐后删除；四个grammar capability bit直接留在FB。
   - generator fallback单独改成“执行状态是否已保存cur_func”的construction invariant，不与顶层environment混账。
4. **M-FINAL-ROW-LAYOUT：W1b2已完成，作为冻结表示继续消费。**
   - compile/final closure共享8B/align4 explicit-mask storage，vardef为12B/align4；VarKind 0..10、临时kind 11、
     uncaptured zero、offset与C/Zig defined-mask golden均已锁定。`0xffff`只存在compile-only open-binding index。
   - focused correctness门禁已通过；Zoo paired median -1.10%低于裁决线，**性能收益记零**。后续ownership move可复制row bytes，
     但不得重开packed bitfield、wire serializer、scope graph或把W1b2噪声包装进下一候选。
5. **M-REALM-STATE-REF：先建立唯一identity与普通realm state owner。**
   - 先把当前core/host `JSContext`拆成header-first、GC/refcount的`RealmContext`与公开/embedding owner handle；`RealmRef`只是
     pointer-sized typed owner，`dup/free/mark`逐项镜像`JS_DupContext/JS_FreeContext/JS_MarkContext`。binding `JSContext` handle只持一个
     RealmRef并delegate，故现有heap `create/destroy`与stack `init/deinit`都只建立/释放base ref，不再by-value嵌入或提前deinit core state。
     callback-facing `core.JSContext`成为RealmContext本体的类型别名或同寿命固定成员，地址在realm存活期间稳定；`ExternalCall.ctx`、
     FFI `ZigCall.ctx`及public host callback统一使用typed borrowed-context view，不再用`anyopaque`暗示可cast回owner wrapper。raw plugin
     `CallFrame.ctx`若为ABI兼容继续保持pointer-sized opaque字段，只能是明确文档化的call-duration borrow，并由唯一helper转typed view；不得
     直接cast成owner。若Zig模块分层要求保留方法式callback facade，只允许RealmContext内固定同寿命member+typed accessor；不得独立分配、
     反向猜首字段或每次造临时facade。
     `RealmRef`和公开owner都是move-only语义capability：bitwise copy不产生第二份owner，只有显式`dup/clone`才增加header rc；
     callback/API内部统一传`*RealmContext` borrow。safe build至少以released token/poison尽可能抓double-free/use-after-release，不能因为Zig允许struct copy
     就把同一ref隐式释放两次。
   - RealmContext必须成为runtime cycle-GC能枚举/mark/remove的真实GC kind，而不是普通refcount box。这里不能复用现有
     `JSContext.traceRoots`假装完成：当前RootProvider只由`Runtime.traceRoots`的external visitor消费，cycle collector实际走
     `Object.traceChildren`的trial-decref/scan/restore。新增`.realm_context`时必须**append而不重编号**既有`GcKind`，并一次补齐
     `defaultHeapBytes/heapByteSizeFromHeader/isCycleCandidate/headerHasTraceableChildren/traceChildren`、zero-ref queue、
     `finalizing/remove_cycles/deinit` gates、garbage partition/teardown order、deferred struct free、intrusive-list/accounting verifier全部kind switch。
   - 新增typed `visitor.visitRealm`或等价generic-header edge；W1b3b/c/d1/d2/d3各自迁入的FB、C_FUNCTION、AUTOINIT、job、
     FinalizationRegistry carrier在所属patch直接trace RealmContext header。W1b3a只建基础设施和本阶段真实edge，不得为了让中间cycle测试变绿
     给尚未迁移的payload补temporary generic RealmRef；禁止把context编码成fake JSValue、Object/global或root-provider。RealmContext自己的
     `traceChildEdgesNoFail`只枚举**本patch真实owned**的JSValue/Object/Shape/RealmRef：最终至少覆盖global/global lexical、
     intrinsic/prototype/direct initial-shape、仍被明确保留的具名product cache与已迁入state；borrowed HostEventLoop pointer、active stack/native pointer、user opaque和
     runtime context/root-provider links不得误算child。迁移中的临时owned backtrace/job/value字段必须在同一patch进入trace/free矩阵，不能只按最终QJS字段漏边。
   - RootProvider若因现有public `Runtime.traceRoots`诊断/host-tracer contract保留，必须与上面的cycle child visitor拆成两个具名surface：
     RealmContext-owned slot只由GC child visitor决定liveness，不能再被标成external root；EventLoop timer/RW/signal callback等真正由host storage
     own的JSValue仍需作为external roots枚举，可由EventLoop自身provider或attached-loop专用bridge实现。EventLoop的命名RealmRef保证bridge期间
     RealmContext存活，detach/unregister必须先于释放callback storage和RealmRef。即使诊断visitor为了完整快照重复看到某个slot，也不得让同一
     trial-decref transaction同时消费两条边或把provider residual count当base ref。
   - QuickJS `gc_free_cycles`不把`JS_CONTEXT`列为首轮`free_gc_object`对象，而由object/FB/AUTOINIT等carrier teardown把其ref降到零后
     `JS_FreeContext`释放；zjs现有batch collector若必须显式stage RealmContext，只能作为命名的collector-transaction适配，并证明
     object/FB resources→RealmContext owned slots→shape/deferred structs的次序无double-free/UAF。普通last-ref与cycle removal最终共用一个
     RealmContext child-release/raw-free实现；Runtime `gc.deinit`不得兜底强销毁仍有external ref的context。
   - RealmContext另带与GC header links完全独立的runtime context-list link，两个publication point不得再绑成一次commit。先在未发布raw storage中
     完成当前published class-count的null slots及不含GC child的fallible scaffolding；在任何可能分配/触发collector、或创建C_FUNCTION/AUTOINIT等
     RealmRef carrier的bootstrap之前，以no-fail操作把**GC header**发布为`.constructing`。此后每个已初始化child都立即进入trace/free矩阵，local
     construction base ref保证Context本体存活；失败统一走普通RealmContext child teardown→header unlink→raw free，绝不能复制pinned
     `JS_NewContextRaw`在`add_gc_object`之后`class_proto`分配失败便直接free raw context的脆弱路径。完整global/intrinsics/initial-shapes bootstrap成功后，
     才以预留好的no-fail storage发布**runtime context link**并转`.live`；RootProvider若保留也在对应external-tracer commit点发布。
     若未来允许bootstrap内重入dynamic class registration，就必须把constructing realm纳入专用capacity registry并让其他list consumer显式跳过，
     不能为了省一条状态把半初始化realm暴露给legacy adapter/plugin unload。该两阶段顺序是按GUIDE/OOM纪律登记的zjs safety adaptation，
     不伪称QuickJS逐行步骤或Zig限制。dynamic class growth、Object.prototype索引失效、cold exact-global adapter、memory/accounting与具名plugin-unload slot cleanup只枚举这条list，不能复用
     GC list（collection会移动节点）或任意RootProvider表。两条list都只借；runtime context list只含published、可用且非finalizing realm。
     zjs一旦进入不可revive的finalizing commit，先unlink context link并注销RootProvider，再释放children；GC header link按collector partition/deferred-free
     phase独立摘除，最终raw free前两者都已恰好unlink一次。这是把QuickJS同步`JS_FreeContext`适配到zjs staged teardown的安全顺序，必须以finalizing guard证明，
     不能误写成reference逐行顺序。
     这些机制共同保证Context→global/prototype→C_FUNCTION/AUTOINIT→Context循环可回收，不能靠teardown全表扫pointer打断。
   - 并发边界也要照reference分层：pinned QuickJS只给process-global `JS_NewClassID` allocator加mutex，同一Runtime的Context创建、class registration、
     context-list mutation与GC默认串行。zjs若维持owner-runtime-thread contract，就在class-count snapshot→header construction→live-link commit及class-growth
     全程assert该contract；foreign waitAsync completion只能signal owner thread。若公开API已经允许跨线程Context/plugin mutation，则必须用同一Runtime mutation lock
     覆盖snapshot/reconcile/list commit、registration、plugin slot cleanup与相关GC/list mutation，作为具名product extension，不能只让global ID atomic而留下
     “新realm按旧class_count发布”或unload扫描与live publication交错的竞态。两种模型只能选一套并进入public API contract；foreign completion不得直接取得该锁后执行JS。
     mutation lock只保护窄结构snapshot/reconcile/no-fail commit，绝不能跨GC、会回调的allocator、JS/DSO callback、payload finalizer/tracer持有；需要分配时按
     generation snapshot→owner thread或独立thread-safe/no-GC allocator在结构锁外prepare→重新加锁校验/补差→commit循环，或使用已证明不回调的scoped raw allocation。
     不能把现有Runtime allocator未经证明地拿到foreign thread。owner-thread模型同样允许callback reentry，
     所以仍必须遵守class-record瞬时view、context-list pin和publish-before-free规则，不能把“同一线程”误当“不重入”。
   - 在context list稳定后先做M-ARRAY-WRITE-CONSUMER-MAP，再做M-ARRAY-PROTO-GUARD；不能把旧chain helper的所有reader机械换成一个bool。
     逐调用链对照QJS：已有own dense index且slot确实存在时直接set、不查prototype；fresh CreateDataProperty append只验own descriptor/extensible；
     普通`[[Set]]`在logical dense end且尚未走过prototype时、`OP_put_array_el`、push/splice等source对应点才读`can_extend_fast_array`式direct proto flag；
     已由`JS_SetPropertyInternal`完成prototype walk后再进入own append的路径不能重复guard；hole fill、缺失own index、custom/proxy/exotic继续走可观察generic path。
     `fill`和growing unshift在pinned QJS没有现有zjs fast branch，range/mask bulk又是zjs product optimization：默认不消费standard flag；若保留，只能使用
     独立命名的actual-chain proof并维持既有correctness/perf证据，否则退generic，且两者收益均不计入本刀。
   - bootstrap只给每个realm真正的Array.prototype置standard flag；该对象进入新增QJS tagged-small integer atom（0...`2^31-1`）的
     `add_property` publication attempt时，像QJS一样在后续fallible shape/property growth前永久清flag，因此稍后OOM/rollback也不恢复。与此不同，Array.prototype自身
     **成功提交且新旧prototype不同**的`setPrototype`或dense→ordinary conversion时清自身flag；同值set-prototype在QJS
     `JS_SetPrototypeInternal`中先返回TRUE，不得误清。Object.prototype进入同域`add_property` attempt时也先沿context list按exact Object prototype找到同realm并清
     对应Array prototype，稍后OOM同样不恢复。`2^31`以上虽仍可能是ECMAScript ArrayIndex，但不影响QJS最高`INT32_MAX` fast-array extension，不能扩大永久失效域；
     非canonical数字字符串也不清。删除runtime-wide sticky
     `any_prototype_may_have_indexed_properties`与只为其服务的`flags.is_prototype/markObjectAsPrototype` authority；
     `may_have_indexed_properties`若仍被own-object/具名full-chain product proof读取，只保留local summary，不再向Runtime传播或决定canonical extension资格。
     A修改Object.prototype只能让A数组退回generic，B仍保持standard；delete不重新置true，custom proto/Proxy/accessor仍走generic。
     此刀在RealmContext correctness之后单独做hot A/B，不能把consumer语义修正、zjs-only fast-path去留或cycles变化算给context split。
   - 普通context bootstrap和`$262.createRealm()`都创建真正RealmContext，再由它own global/global lexical/intrinsics；后者不再只
     造一个带RealmPayload的global object。现有RealmPayload必须按字段split而非整包改名：`uninitialized_vars`像QJS
     `JSGlobalObject`一样留在显式global class payload并由其mark/finalizer负责；`global_lexicals`与intrinsic/prototype/template/
     RegExp-legacy state迁入RealmContext或成为其唯一附属storage。shared alias cache不能随state迁入RealmContext，也不能在eager alias
     producer就绪前抢先删除；它只允许改名为不参与global判定/realm反查的临时global-bootstrap debt，并在第8步同patch删除。
     global对象本身不能继续充当realm identity。
   - base-ref来源必须显式：公开JSContext handle own创建时那一份；runtime context/GC list与root-provider只枚举、不偷偷retain；函数/property/job等
     escape carrier各自dup。`$262.createRealm().global`会立即丢临时wrapper，因此test262 HostPolicy/harness要用命名的child-realm list
     own base RealmRef直到父test context teardown，或提供等价专用RealmRecord lifecycle；不得依赖“global上总有某个builtin carrier”
     偶然维持context。释放harness base后，只有真实escaped carrier/object graph决定GC存活。
   - state搬离global之前，先把`Object.isGlobal()`从“拥有`.realm` payload”改为显式global-object class/flag，逐个迁
     global exotic、AUTOINIT global→VARREF、global declaration/closure selector及bootstrap reader；对应QuickJS
     `JS_CLASS_GLOBAL_OBJECT`。阶段出口不允许为了global判定保留空RealmPayload，也不允许普通object因附属cache被判成global。
   - `global/lexicals/eval_obj`、`class_proto[]`、`function_proto/function_ctor/array_ctor/regexp_ctor/promise_ctor/iterator_ctor`、
     `async_iterator_proto/array_proto_values/throw_type_error/native_error_proto[]`与random state归RealmContext；已有intrinsic/prototype
     cache复用但只留一个owner，template不能整类原样搬迁。per-realm preallocated OOM Error仅作为既存`oom_cap`零分配交付与same-runtime recovery的
     **zjs safety adaptation**附着于RealmContext：QuickJS没有该字段，而是Runtime `in_out_of_memory` guard + 当前ctx prototype +
     `JS_NULL` fallback。正常仍优先按active realm新建Error；只有fully-exhausted delivery才使用无stack fallback，重复耗尽时可能复用同一对象，
     这项identity/mutation surface必须明确登记且不得扩写成QJS契约。Context/global上的
     重复slot逐项删除，不能长期双写，也不能把该adaptation写成QJS layout exact。现有三处“QuickJS analogue/preallocated
     OOM exception”误导注释与相同措辞的测试说明同时改为zjs GUIDE safety contract，不能只搬字段而保留错误历史依据。
   - M-REALM-INITIAL-SHAPES逐项对齐Context直接owned shape：`array_shape`、`arguments_shape`、`mapped_arguments_shape`、`regexp_shape`、
     `regexp_result_shape`在`.constructing` bootstrap中以最终realm prototype和固定property flags一次建立，RealmContext child visitor直接visit Shape header，
     teardown直接release；construction dup该shape并用typed fixed entry/stack values初始化length、iterator、callee、lastIndex、index/input/groups，
     不再先造一个永不暴露的完整JS template Object来钉shape和值。typed props builder明确own这五类shape实际使用的data/getset entry：object/prop allocation失败按shape flags
     释放全部prepared entries与本次shape ref，成功则把entries无二次dup地move进object并清builder owner；array的implicit length/null-props arm另锁一次初始化。
     arguments callee getter/setter、mapped callee/current function、regexp input/groups等多owner slot逐项走同一move/rollback矩阵，不能因stack值小就恢复clone-template的dup/free往返。
     Runtime shape hash继续只是borrowed interning index，shape raw free前必须unlink，
     不能成为第五种owner。`iterator_result_template`及其他找不到QJS Context-shape对应的cache逐个标为zjs-only product optimization：默认移除；
     若profile与语义证据要求保留，改成独立命名的RealmContext-owned cache并单独A/B，不能算作initial-shape忠实对齐或混入本阶段收益。
   - custom class先拆清四层identity/lifetime：process-global stable class ID、per-Runtime definition、per-Realm prototype slot、既有object shape/payload。
     先枚举`ClassId`在public Binding、plugin descriptor/loaded handle与跨Runtime cache中的escape；若没有已发布兼容阻碍，镜像
     `JS_NewClassID`为显式caller-owned `ClassIdSlot`/registration identity只分配一次：static binding复用同一slot时可在各Runtime独立register；
     每个dynamic plugin installation若没有跨Runtime共享identity则各取新ID，不按descriptor name/type_id自动合并。ID一经分配不因registration OOM/plugin unload回收。
     allocator内部用能表达`65536/exhausted`的加宽状态并做thread-safe、no-allocation publication：65535仍是合法ID，下一次明确报exhausted，
     绝不让当前`u16 next_dynamic_id`wrap或把已卸载ID复用；显式error是GUIDE safety adaptation，不能用off-by-one缩小QJS合法域。
     若保留当前Runtime-local allocator，必须作为命名plugin API extension写入contract，所有handle都带/校验Runtime且禁止跨Runtime比较、注册或复用，
     不能归因于Zig。Runtime class table只保留class id/definition/opaque metadata，每个RealmContext的`class_proto[id]` own该realm prototype。
     随后镜像`JS_NewClass1`的capacity/publication机制：class record发布前，所有live RealmContext的slot表扩到
     新Runtime class-count且新槽为null；之后创建的RealmContext也按当前count初始化。增长Nth-OOM不得发布半个**class record**；和QuickJS一样，
     已提前长大的部分Context buffer/额外capacity可以保留且不可观察，same-runtime retry必须成功。由于Zig slice.len本身会暴露逻辑范围，
     必须把slot storage capacity与Runtime published `class_count` bound分离，所有low-level get/set先校验该bound；失败后不能仅因某个
     RealmContext的slice已长大就查询/安装新bound之外的slot。`class_count`可以包含尚未注册record的hole，这与高层Binding的registered/`NotInstalled`
     gate是另一层；若zjs core object-create额外拒绝unregistered id，登记为safety API validation而非QJS slot语义。class record/count commit完成后，prototype installation才是
     独立步骤：内部提供所有权明确的`takeClassPrototype(JSValue)`（consume new、free old）、`getClassPrototypeDup`与callback-duration borrow，不能让当前
     `setClassPrototype(*Object)`的隐式dup同时冒充三种API。low-level slot像QJS一样可保存任意JSValue，object creation只把object tag交给shape，
     其他tag按null prototype处理；若zjs公开binding继续只收object，必须标成高层validation。setter/replace/clear共用一个publish-before-free primitive：
     先take old并以no-fail store让new/null成为当前可见slot，再free old；old的last-ref finalizer若重入get/set/register/plugin cleanup，必须看到new/null且不能double-take。
     以后replace/clear slot不改已创建object的shape。
     binding `JSObject`现有slot路径继续复用；
     context list是borrowed registry，扩槽循环中不得裸调用会触发cycle collector的普通MemoryAccount/`allocRuntime`路径。实现固定一种并测试：
     先按总需求触发一次GC/preflight，再在窄scoped no-trigger window用仍执行memory-limit/OOM检查的raw allocation完成所有realm buffer growth；
     或在任何growth前snapshot list并对全部entries做no-fail temporary RealmRef retain；或每轮在仍pin current时先no-fail retain next，再做可能alloc/GC的current操作，
     之后release current并从已pin next继续。最后一种允许原本无external ref的后继暂时revive，等价于QJS循环期间不GC，释放iterator ref后仍可回收。
     仅保存裸`next`指针不够，因为collector可同时free后继。
     forced-GC-on-every-allocation下让一部分realm仅剩cycle、一部分有external ref，注册后已回收者无悬link，全部survivor slot一致；每个Nth-OOM可retry且无skip/UAF。
   - M-CLASS-RECORD-LIFETIME紧随definition publication收口当前pointer view。QuickJS允许`class_array`在注册时realloc，但object create先触发GC、
     `free_object`先递归释放property/shape，二者都只在最后的no-reentry窗口按class id读取所需字段，从不把表内pointer跨GC/finalizer保存。
     zjs不得把“pointer-only比88B copy快”扩大成地址稳定假设：`recordPtr`只能在明确no-GC/no-callback窗口解引用。`createInternal`在GC前若因inline payload
     product layout必须知道allocation size，只复制`{registration_generation, allocation layout, payload kind, has_finalizer, has_exotic}`这一最小immutable construction plan，
     不保留pointer；GC、shape/property/payload等fallible allocation全程只用该snapshot，最终object publication前再按id重取record、校验同一generation并进入no-reentry commit。
     若record已注销或generation变化，必须释放prepared资源后明确失败/重试，不能用旧definition造新object。标准class可用Runtime-lifetime invariant省略动态check；custom/plugin class必须由definition pin或active installation pin证明
     unregister延后，但该pin仍不能阻止**其他**class注册搬整个records buffer，因此所有pointer照样要重取。destroy/deferred-finalizer同理：先保存自身layout/accounting标量，
     在实际读取callback前按id取得仍被object/pending-finalizer owner钉住的definition，再复制function pointer/opaque metadata并持execution pin调用；回调返回前不复用record pointer。
     默认禁止definition在live object、reserved/pending payload finalizer、active construction view或callback存在时unregister；这是QuickJS Runtime-lifetime definition的最小扩展适配。
     runtime plugin的`HostClass.prototype: JSValue`从`InstalledPlugin`删除，`installHostClasses(ctx,...)`只把新prototype交construction
     RealmContext slot，metadata仅留class_id/descriptor。RealmContext last-ref先释放slot；已经创建的opaque wrapper仅由自身shape
     保活prototype，**不**own RealmRef。不能靠external-record/plugin refcount维持prototype，也不能为unload反向给InstalledPlugin补RealmRef。
     pinned QuickJS没有unregister；zjs保留该plugin extension时，每个dynamic installation默认使用自己永不复用的class IDs。每次binding call、
     opaque finalizer/tracer或其他descriptor callback在读取DSO指针前必须先取得temporary plugin execution pin，返回zjs trampoline后才release；
     callback中发生last-owner release只能标记pending unload，不能在仍位于DSO stack时close。plugin zero external/live owner且active-callback pin归零后，先证明
     InstalledBinding external records与OpaqueWrapperPayload均为零。`NativeCleanupJob`/`DeferredClassPayloadFinalizer`等复制DSO function/data pointer的延迟node
     必须从enqueue起显式own installation/definition pin，并在真正callback返回后才release；因此unload gate还要求queued-callback count为零，不能靠live object count推断。
     满足zero live/active/queued三项后，再以no-allocation的current+next temporary RealmRef协议沿runtime context list扫描这些ID：每个slot先take/publish null，再free旧值，
     使RealmContext teardown或prototype finalizer重入时只看到null；随后unregister Runtime definitions，最后才`lib.close()`/释放descriptor metadata。
     RealmContext先死则同一take已清slot，plugin unload扫描不到值；plugin先死则live RealmContext slot被清且高层view转NotInstalled。
     若未来多个installation显式共享同一ClassIdSlot，必须另有per-Runtime registration refcount+per-install slot identity，不能全表clear伤及仍活owner。
     底层QJS-shaped class creation把null slot当null-prototype；高层`JSObject.binding/new`继续以`NotInstalled`作为既有embedding API gate时
     必须单独命名。plugin binding本应由C_FUNCTION carrier回到安装realm，若HostServices仍遇到null slot就是construction invariant/API error；
     两层都绝不扫描其他realm或fallback首realm。QuickJS没有动态unregister API；zjs若继续支持plugin class unregister，它是命名的
     plugin-lifetime extension，必须证明无live class object/payload后才清Runtime metadata，不能冒充Context slot释放的QJS步骤。
     若现有plugin install API承诺多HostClass全有或全无，可在这两个low-level步骤之上保留显式rollback transaction；该transaction的class-id/
     slot回滚、Nth-OOM与retry单独验收，不能把它错误归因给`JS_NewClass1`。
   - 同时封闭公开`JSObject.Binding`的lifetime。现有`Binding{runtime,class_id,prototype:*Object}`既不是QJS Context owner，也没有borrow
     contract，不能原样跨RealmContext拆分。保持`binding(ctx).new/payload`调用形状时，把它改为不含JSValue/raw prototype的
     `BorrowedBinding{realm:*RealmContext,class_id}`，有效期明确限定为对应public owner/RealmRef存活期间；每次new/payload从该realm当前
     `class_proto[class_id]`取exact brand。需要跨wrapper/owner lifetime保存时显式`retain`得到`OwnedBinding{RealmRef,class_id}`并要求deinit，
     独立副本只能显式clone/retain，bitwise copy不增加owner；不允许Runtime表或class metadata替它偷持base ref。现有
     `binding(ctx).new/payload`方法形状保持兼容，`Binding`字段布局不承诺兼容；
     borrow在safe build用live-realm token检查，after-owner-release use明确无效。新增owned variant只扩API、不偷偷改变copy语义。
     现有fixture先补borrowed/owned两路：borrow随ctx
     使用；owned在owner wrapper销毁后仍可new/payload，释放后realm可回收。
     因该Binding被定义为live class-slot view而不是prototype snapshot，slot replace后new/payload读取新brand、slot clear后返回`NotInstalled`；
     这项行为要写入public contract并用old-object/new-object/clear矩阵锁定，不能留下raw旧prototype以维持未声明snapshot语义。
     `RealmPayload.shared_lazy_native_functions`不是QJS intrinsic state，禁止顺手迁入RealmContext；它在第8步随eager alias恢复而删除。
     interrupt counter虽同样最终属于RealmContext，但storage、10000阈值、caller-entry/callee-body poll与跨call lifetime必须在
     M-INTERRUPT-BUDGET一次落地；本步不预埋未读字段，也不保留VM counter双写。
   - `exception_slot/current_exception`与active stack/backtrace/current native call按QJS归Runtime或stack-local execution state；
     compile/eval/dynamic-import callback、opaque、per-context stack-limit扩展、rejection tracking与event-loop逐项归RealmContext
     HostPolicy或Runtime policy。公开handle不再own任何job/call逃逸后仍需使用的裸状态。
   - `runtime.EventLoop`保持公开`init/install/deinit/runUntilIdle`形状，但`init`以no-fail dup取得一个命名host RealmRef，内部只保存
     稳定`*core.JSContext`/RealmContext，不再借binding wrapper地址。HostEventLoop vtable收到的`core_ctx`直接进入core timer/rw/signal
     操作，并验证它就是loop绑定的live realm；全仓core→binding wrapper反向`@ptrCast`为零。loop持有的只是host base ref，handler表只
     own/trace callback JSValue；调用callback时仍由C_FUNCTION/FB等最终call carrier切callee realm，不能给每个handler补RealmRef或让loop
     参与FunctionRealm。`deinit`按detach HostEventLoop→释放timer/rw/signal callback roots与buffer→free loop RealmRef的顺序断环；
     convenience stack loop也走同一路径。installed loop未deinit时Runtime destroy必须把它视为live external owner而拒绝继续，不能清空
     context或callback slot伪造成功。该单一ref不是照抄quickjs-libc：reference的`js_std_loop(ctx)`不存ctx；它是保留zjs现有
     `runUntilIdle(self)`API时对“loop会存ctx”的命名lifetime adaptation，不得归因于Zig或计性能收益。
   - `Atomics.waitAsync`是pinned reference没有的product extension，但其heap waiter已逃逸出调用栈，W1b3a不得继续保存裸Context：node在
     创建时no-fail dup一个RealmRef并显式own Promise/SharedBufferStore/deadline；global waiter list只借node用于跨runtime key匹配。
     settle、timeout、cancel、unlink与Runtime pre-destroy逐条释放恰好一次，公开`cleanupAtomicsWaitersForContext`改按stable realm identity
     cancel，不依赖owner wrapper地址。该步只先封闭lifetime/UAF；foreign-thread直接settle与吞错是命名debt，必须在W1b3d2同一阶段
     由M-HOST-COMPLETION-TO-JOB删除，并阻塞realm联合封口，不能把新增RealmRef误报成机制已经完成。
   - 该阶段内部再分三把correctness刀：先引入RealmContext/RealmRef并让现有handle own default ref、执行栈只借active realm；再迁Runtime/realm
     state并删除双写；最后让`$262.createRealm`和cross-realm entry创建/切换真实context。`create/init/deinit/destroy`及embedding
     surface保持兼容；production的EventLoop/test262 callback与fixture中的`src/tests/exec.zig:TestEngine`、`src/core/string_view.zig`全部
     core↔binding pointer cast逐一删除，测试必须真实持public owner或直接使用typed borrow，不能继续靠首字段布局掩盖API缺口。
     stack-initialized handle和host callback一并审计；任何carrier保存`*JSContext` owner-handle地址的producer在阶段出口必须为零。
   - 公开`*.realm_global` options保持source compatibility，但只在binding/root/CLI冷边界验证它是某个live RealmContext的exact
     `global_obj`并立即dup为typed RealmRef；优先复用本步已为class growth建立的runtime context list做冷scan，除非profile证明需要同生命周期index。
     GC list会在trial-decref/scan中移动节点，RootProvider表又不是context registry，两者均不得作为该adapter的authority。
     不在global payload增加反向ctx pointer，不接受ordinary object，也不让VM/property/error helper调用这条adapter。新内部API只收
     RealmRef/active realm；live non-global、cross-runtime global或未登记地址给清晰错误，不能silent fallback default realm。裸指针在free后发生地址复用时没有
     generation可供识别，定义为legacy API无效use-after-free；不得用“可检测stale”作虚假验收，若产品要求强诊断需另立带generation handle。
   - alternate realm的eval identity、class prototype cache、Array/arguments/RegExp template+prototype、random independence、
     Error/OOM prototype及global/lexical identity先红后绿；handle先销毁但显式test/host RealmRef仍存活、RealmContext→global/prototype
     owner graph及last-ref teardown都通过GC/accounting。专门用“只剩Context↔global/C_FUNCTION”“只剩AUTOINIT↔Context”死环证明
     collector会回收；保留一个external RealmRef/FB/C_FUNCTION/job/OwnedBinding时必须scan-revive并存活，释放最后carrier后才回收。
     provider/context-list仍登记但无ref时不得阻止回收，回收后两条borrowed registry均无悬空entry。random用test-only seed/state probe证明两realm不共享，不硬编码production随机输出；
     RealmRef dup/free不得出现Nth-OOM点。测试必须分别锁QuickJS-shaped普通错误来源与zjs safety adaptation：非递归路径按active
     RealmContext的InternalError prototype；Realm bootstrap/递归OOM发生在per-realm预制Error可用前时只能使用不引用首realm的
     runtime-neutral emergency状态。不得继续借default realm Error污染alternate realm，也不得声称预制Error来自QuickJS。该阶段收益记零。
   - Runtime destroy遵守QuickJS外层lifetime：先清job/host queues并运行host finalizer，使其有机会释放自有handle/RealmRef；随后要求
     公开JSContext handle、harness base、其他external RealmRef以及public strong/weak/local value-root slot全部为零，最终context/GC list为空。
     `JSValueHandle`可经所持C_FUNCTION/FB传递性保活RealmContext，不能只数直接RealmRef；也不能像当前实现一样由Runtime主动
     `clearPersistentRootSlots`后留下外部handle指向已释放slot。现有void destroy API可在safe build断言precondition，但production contract
     和测试必须清晰，跨runtime use-after-free不由RealmRef兜底。runtime root-provider/context list都只借指针并在RealmContext raw free前各unlink一次；
     GC registry必须已通过正常last-ref/cycle路径清空，`Registry.deinit`不能替调用方强制销毁RealmContext。
6. **M-REALM-CALL-CARRIERS：让wrapper留在caller、仅最终call arm切realm。**
   - W1b2.5的M-DSTR-STACK已删除六个dstr伪callable，W1b2.6的M-USING-TYPED-CONTROL已删除八个`using`伪callable及剩余Runtime cache/root；本步把该负向
     当作前置条件，不重做destructuring/using parser或把它们改成C_FUNCTION_DATA/专用class。若任何
     `internal_destructuring_helpers`、`internalDestructuringHelperFunction`或对应`special_object + call` producer复活，立即退回前置阶段，
     不能靠补RealmRef把内部控制协议重新包装成JS调用。
   - 先把zjs callable record逐类映射QJS：真正的C_FUNCTION builtin/external function像`u.cfunc.realm`一样own RealmRef；
     C_FUNCTION_DATA式callback+captured-values helper沿用caller RealmContext且不加owner；bytecode函数只从FB取得。
     其他`JSClassCall`式callable默认也沿caller，除非QJS class arm显式从target/bytecode取得realm。Promise resolving/thenable/
     combinator等内部callable必须按对应QJS class/constructor逐个归类，不能按“都是native”猜。
   - 以§1.8 callable表为生成式inventory：先证明14个internal-control helper已经退出callable集合，再把13个`InternalCallableTag`、
     Proxy revoker、module/iterator captured helper、external host function、binding `MethodRuntime`与legacy `c_closure/c_function_data`
     producer逐项标成C_FUNCTION、caller-data、专用class或job-only。W1b3b删除前三类中
     “先造c_function再靠tag改语义”的producer；reaction/thenable/dynamic-import三类job-only producer明确交W1b3d2并阻塞联合负向封口，
     不能因它们稍后执行就漏出清单。
   - `InternalRecord.prepared_call_ok`当前零reader，随inventory删除字段、table initializer和声称存在VM gate的注释，收益记零；live
     `forwards_call`另有真实tail/inline consumer，不跟着批量删。未来若提出让**JS call opcode/callable dispatch**无function object直达record，
     必须重新给出construction RealmRef carrier、object-surface不可观察证明与独立A/B，不能直接复活这个布尔。算法内部在已确定
     active realm下复用typed record handler不是JS callable invocation，单独分类且不强造function object。
   - 每类代表先在pinned qjs冻结可观察object surface：own `name/length/prototype` descriptor、`Function.prototype.toString`、callable/
     constructible brand及FunctionRealm fallback；专用Promise/async class不能因为zjs复用`nativeFunction`就继承C_FUNCTION surface。
     若pinned行为与test262明确冲突，按§2 reference-exception流程单项裁决，禁止凭印象补属性。cross-realm Promise self-resolution还要锁
     rejection TypeError来自调用resolving function的caller，而saved async body resume后的Error来自`frame.cur_func→FB` realm。
   - 真正C_FUNCTION的construction API必须显式接收RealmContext，在object分配时直接采用显式final prototype（默认该realm的
     Function.prototype）并retain RealmRef，同时把`length`和`name`作为normal data property一次性建立；不能继续
     `nativeFunction(rt)→setFunctionRealmGlobalPtr→setPrototype catch {}`后补，也不能用`nativeFunctionWithLazyName`把QJS eager name
     改成AUTOINIT。bootstrap唯一特殊臂像`JS_AddIntrinsicBasicObjects`：先有Object.prototype，再以它作为显式final prototype创建
     Function.prototype C_FUNCTION，随后其余C_FUNCTION才可默认使用该RealmContext的Function.prototype；全程不创建临时null-prototype
     function再补图。C_FUNCTION_DATA/专用class builder同样从construction caller取得正确prototype，但不因此own realm；
     name/length/property发布错误按GUIDE传播。这样AUTOINIT第8步只需
     调一次stored-realm builder，不依赖target namespace/prototype上的realm slot。production null-realm native builder为零；
     hand-built callable fixture显式传fixture RealmContext或使用标明caller-semantics的data-class builder。
   - native/internal ABI收到的`*core.JSContext`按class phase提供：C_FUNCTION callback拿construction/callee RealmContext的稳定地址；
     C_FUNCTION_DATA与专用caller-class拿调用caller；job callback拿entry RealmContext。public `ExternalCall`/FFI再把同一identity表达为typed
     borrowed-context view；binding owner wrapper即使已destroy也不影响escaped C_FUNCTION callback。`ExternalCall.ctx`本身改typed，binding
     `callContext/callbackArg`、plugin error/output、dynamic-import与`run_test262.wrapExternal*`consumer不再cast；EventLoop vtable和所有public
     examples/fixtures同样走typed accessor/namespace adapter。raw FFI `CallFrame.ctx`若因稳定plugin ABI保留opaque pointer，文档和helper必须
     把它限定为callback-duration RealmContext borrow，`ZigCall.ctx`直接给typed view；这项是product ABI compatibility，不是Zig限制。
     禁止传owner-wrapper地址、host handle裸指针或stack-temporary facade。callback期间由function/job carrier保证RealmContext存活；若host要
     跨callback保存，必须显式取得public owner ref，不能长期保存borrowed view。
   - ctx切换必须与global/slot view原子发生。QuickJS callback没有第二个global参数；zjs为source compatibility保留`ExternalCall.global`时，
     每次**可观察JS callable invocation**都必须非null且等于typed ctx的`global_obj` borrowed alias，`globals`也来自同一RealmContext。
     真有pre-global bootstrap动作就使用单独的typed construction API，不能借`ExternalCall.global=null`给普通call留后门。
     plugin/test262/error path删除`call.global orelse func_obj.functionRealmGlobalPtr() orelse ctx.global`式多权威fallback；C_FUNCTION
     从A在B调用得到`ctx=A/global=A`，caller-data得到`B/B`，EventLoop A中调用B函数仍得到`B/B`。测试故意把caller、loop与callee分属三realm，
     同时观察Error prototype、global mutation与callback记录的underlying identity，禁止只测ctx地址。
   - runtime plugin binding归真C_FUNCTION：从A安装的binding逃逸到B调用时，plugin trampoline及其HostServices收到A typed borrow；
     `createOpaqueObjectValue`以A的`class_proto[class_id]`建wrapper，不再读`InstalledPlugin.host_classes[].prototype`。prototype对象本身、
     opaque wrapper与function分别按普通JSValue/shape/C_FUNCTION carrier存活：binding function own A RealmRef；opaque wrapper只以shape引用
     prototype并以payload retain plugin metadata，不能因“由A创建”再own A RealmRef。external record只保plugin metadata/library lifetime。
     锁在动态class注册前已存在的A/B与注册后创建的C：三者slot容量一致，只有安装realm A有prototype；B/C均为null/NotInstalled。
     再锁增长Nth-OOM、释放A base但分别保留binding或仅opaque object、删除binding后仅metadata存活以及Runtime teardown unregister顺序。
   - binding method的realm-local brand不再靠runtime external record中的`MethodRuntime.prototype: JSValueHandle`。C_FUNCTION最终arm已经把
     callback ctx切到method construction realm，stub按`class_id`从该稳定RealmContext的`class_proto[]`读取exact prototype，再执行现有
     `payloadFromClassAndPrototype`；record只留runtime/class_id/host state。这样保留当前跨realm拒绝与prototype-mutation行为，却不让
     runtime表成为hidden RealmContext base owner。QJS `JS_GetOpaque2`只按class id，因此这项exact-prototype检查必须登记为zjs embedding
     API contract、不是QJS或Zig限制；若未来改成class-id-only另立API兼容裁决，不能夹在性能patch中。新增“释放realm base、保留runtime及
     external record并GC后prototype/context可回收”的测试，同时保留multi-realm install/cross-call与record-finalizer测试。W1b3a的
     `BorrowedBinding/OwnedBinding`也必须复用同一live slot lookup，仓库中不再有第二套cached/raw prototype authority。
   - 对已判定C_FUNCTION/bytecode的路径删除`caller global orelse borrowed payload`语义fallback，缺失owner直接是construction
     invariant错误；data-callable的caller语义是显式class arm，不是同一个fallback偷偷兜底。
   - 建立单一递归`FunctionRealm(caller, value)` resolver：C_FUNCTION/bytecode返回own carrier的borrowed view，bound/proxy递归target，
     revoked Proxy在caller realm抛错；非object、C_FUNCTION_DATA与其他class-call/default arm精确返回caller RealmContext，绝不尝试
     generic object realm。只有已经判定为C_FUNCTION/bytecode却缺owner才是construction invariant错误。内部reader限定为
     `js_create_from_ctor`式constructor fallback、Dynamic Function fallback、Error constructor
     fallback与ArraySpecies foreign-intrinsic comparison；另有public function-realm query只能作为命名的cold adapter。ArraySpecies必须
     只在`ctor`确为foreign realm intrinsic `array_ctor`时做第一次undefined suppression，不能把所有foreign constructor替换掉；
     读取`@@species`后还要保留QJS对active realm自身`array_ctor`的第二次suppression。该resolver
     **不能**作为实际call的提前切换捷径；
     bound先在caller做argv sizing/alloca并递归target，Proxy先在caller取trap/建arg array/校验结果，再由trap或target自己的最终arm切换。
     bound/proxy不再复制、注册或清理第二个realm pointer。
   - 严格保留final direct-arm phase：object-not-callable、interrupt entry poll、argv sizing、native/VM stack preflight与这些preflight错误
     使用caller realm；frame/argv准备完成后才从bytecode FB/C_FUNCTION读取callee RealmRef并原子安装active RealmContext、global_obj与
     global-slot view。C_FUNCTION的
     constructor-cproto call-without-new检查在切换后执行，和函数体、sloppy `this` global及callee内部error一样使用callee realm；
     return/abrupt后原子恢复caller三元组。C_FUNCTION_DATA/其他caller-class arm全程不切换。
   - 只有最终bytecode/C_FUNCTION arm解析一次direct carrier；VM与native helper随后沿当前frame直接借`*RealmContext`，不允许每个
     opcode/property/error helper重新做handle→realm/global fallback。这才对应QJS局部`ctx=b->realm`，也避免为了公开handle引入
     新热load chain。
   - bytecode/C_FUNCTION/C_FUNCTION_DATA/default class-call/bound/proxy/newTarget/ArraySpecies矩阵与caller-wrapper/preflight、trap-call、callee-body Error prototype
     先锁行为；captured-data helper至少覆盖Promise resolving/thenable与一个generic data callback。RealmContext→global/prototype→
     C_FUNCTION→RealmContext循环必须由cycle GC回收，普通last-ref不能泄漏或提前free。这是correctness，收益记零。
7. **M-FB-REALM-FINALIZE：compile realm在每个FB发布前确定。**
   - production compile入口显式接收borrowed `CompileContext{ realm, policy }`并递归传给child finalizer；普通production不得
     使用null realm，手造fixture必须显式提供fixture realm或走fixture-only builder。
   - 对照递归`js_create_function(ctx, child)`，每个child/root FB在自己的finalize commit中独立retain一次RealmRef；不能从parent
     借owner，也不能只让root持有。`runtime_strict`等compile policy同样只在发布前写一次，删除对finalized cpool tree的后置mutation。
   - 删除`bindBytecodeFunctionRealmGlobal`及first-closure mutation。parent finalize失败、child先发布、FB/closure不同销毁顺序、
     cycle GC/accounting和escaped nested function逐项锁恰好一次release；retain本身no-fail，Nth-OOM只覆盖真实artifact准备。
8. **M-REALM-DEFERRED-CARRIERS：按AUTOINIT→job FIFO→Finalization拆成三把correctness刀。**
   - M-AUTOINIT-QJS-DOMAIN-PUBLISH先逐producer建立exact分类，不从当前`AutoInitKind`反推reference：
     `function_prototype→PROTOTYPE`，module namespace delayed binding→MODULE_NS；PROP只允许C function、string、object/property-list builder。
     标准`JS_DEF_OBJECT`还要锁prototype选择：`Symbol.unscopables`使用null，其余使用active RealmContext的Object prototype；
     zjs公开lazy empty-array/host namespace若保留，只能作为同一PROP builder contract下的命名host extension，不能伪称QuickJS标准entry。
     Math/JSON/Reflect/Atomics及明确host namespace可作为documented PROP-object builder，Console/Navigator/Performance等host surface也必须
     复用同一immutable builder/error契约，不能增加第四个slot dispatch。CGETSET/native accessor、number/int/bool/atom/undefined常量和
     alias不进入AUTOINIT；它们按`JS_InstantiateFunctionListItem`在安装期发布。producer清单与descriptor/flags golden先红后绿，不能只把
     enum case保留在共享descriptor中就声称低两bit已对齐。
   - alias严格按QJS安装顺序：先读取/必要时materialize已经安装的source property，再把同一value定义到alias；覆盖
     global parseInt/parseFloat、Array/TypedArray iterator、Map/Set、String trim与Date aliases。删除
     `shared_lazy_native_functions/shared_native_cache_slot`及其RealmPayload owner/trace/free，锁alias identity、descriptor与source
     delete/redefine后的独立性。QJS注释“alias用autoinit不安全”是机制约束；现有bootstrap加速不是Zig限制，也不允许以shared cache
     模拟。alias source base也不能泛化成realm猜测：`-1`读安装target、`0`读active realm global、`1`读active realm Array prototype；
     `Symbol.toPrimitive`和`Symbol.hasInstance`沿QJS修正最终flags。CGETSET eager创建的getter/setter各自走第6步C_FUNCTION constructor并
     own RealmRef；numeric constant安装不新增builder/OOM点。
   - AUTOINIT property slot自身own RealmRef，descriptor只保存immutable、可共享的builder事实；slot保持QJS property-union的两个word：
     有alignment断言的`realm_and_init_id` wrapper只在realm pointer低两bit编码PROTOTYPE/MODULE_NS/PROP，第二个opaque word保存稳定
     pointer-sized typed opaque pointer：standard PROP直接指向comptime/static descriptor，PROTOTYPE为null，MODULE_NS在W1e指向其QJS式
     module owner；动态host descriptor只能放进有明确Runtime/HostPolicy lifetime的stable arena。默认删除`AutoInitRef{rt,id}`/runtime-ID lookup，
     因为Zig可直接表达`*const`，若要保留索引必须先给出具体pointer/lifetime限制和双consumer证据。descriptor不得保存`rt`、realm/global
     整数token、target object或mutable alias/materialization cache；runtime从RealmRef取得。realm owner不能偷移到runtime table直到teardown，
     也不能由target ordinary object代持；wrapper提供typed dup/free/mark。
     materialize/error使用property construction realm，materialized C_FUNCTION再独立retain同一realm。未读取就delete/redefine、
     owner object destroy、property-storage clone/move及cycle mark也必须走同一typed slot API，逐路径锁恰好一次dup/free/mark；
     不能只在materialize成功路径处理owner。
   - 随后把仍合法的所有builder从optional/null改为真实error union，generic property read必须能传播builder exception；
     先以访问caller RealmContext完成QJS式shape-prepare/unique update，再以slot RealmContext调用builder，commit阶段不得再失败。
     builder只返回typed materialization result，不得修改或重入当前owner的同一property slot；PROP object builder只能填充新建result object。
     该不变量以debug guard和恶意host-builder回归锁定，不能靠缓存一个可能已被realloc的slot pointer继续写。
     同一read只调用builder一次，删除`materializeNativeFunctionAutoInit`的静默双试和“OOM已经致命”注释。成功时忠实完成
     slot RealmRef free→normal value/C_FUNCTION独立retain。QJS失败会消费slot并留下normal undefined；zjs为满足GUIDE same-runtime
     recovery，在失败时原子保留placeholder+RealmRef供下一次显式read重试，但本次必须抛错。这是命名的transactional safety divergence，
     不是允许吞错的理由；shape-prepare失败与builder失败分别注入。
     PROTOTYPE/PROP在ordinary target成功commit为normal value；accessor已在安装期发布，不再出现“materialize成accessor”的slot arm。
     MODULE_NS resolver若得到namespace object同样发布normal value，若得到export binding则直接把同一个shared VarRef发布到namespace property，
     不得先快照value或新造cell；不必复制QJS用string tag偷运pointer的C表示，只需typed result union保持同一owner/identity/异常顺序。
     W1b3d1只固定该property-slot协议和typed result contract；当前zjs module namespace仍是data snapshot+parallel cells，真实
     delayed-export producer、module opaque lifetime与namespace rollout归W1e。不得用一个孤立unit arm把生产module标成已对齐。
     global target在builder后以caller context准备VARREF，把materialized value移入cell并按writable设置const，再一次commit AUTOINIT→VARREF。
     VarRef allocation失败同样释放临时value、保留原slot/RealmRef并抛错；
     不能把global data留给后续GLOBAL selector临时修补，因为QJS cell identity在materialization时已经确定。
     VM/public generic property读取统一接入该error channel；只读raw data slot的helper只有在调用者已证明非AUTOINIT/非accessor时才能
     保留，并以命名/precondition区分，不能新增另一个会把materialization error改成undefined的“infallible fast path”。
   - M-JOB-REALM-FIFO再让Promise、dynamic import和generic native job统一进入runtime FIFO；每个entry own RealmRef与args，
     job callback直接接收仍存活的RealmContext。删除host-handle裸指针和context/runtime两套ECMAScript queue；sequence不再只是
     事后归并补偿。`promise_reaction_job/promise_thenable_job` InternalCallableTag与dynamic-import external-host fake function
     producer/object/property payload一并删除，queue entry直接保存typed job kind+args；job不得再进入FunctionRealm、own-key或普通call路径。
     dynamic-import job handler、attribute检查、resolve/reject与loader invocation全程使用entry RealmContext；
     `DynamicImportState.load/DynamicImportHostState.load`不得丢弃callback `ctx`后改用`state.context`。d2允许loader I/O policy/continuation
     adapter仍由命名host owner持有，但它不能决定realm；stack-scoped userdata只有在对应queue已排空、无continuation/waiter逃逸后才能restore/free。
     W1e再把QJS runtime-wide normalize/load hook与per-Realm module/continuation owner最终归位，不能把该placement debt反向留成裸ctx例外。
   - 统一storage前先冻结M-JOB-ENQUEUE-TRANSACTION producer表，不能因pinned内部代码忽略`JS_EnqueueJob`失败就复制silent drop。
     generic/public enqueue先reserve entry storage、dup RealmRef/args/payload，失败不消费caller owner也不改变FIFO；Promise reaction/thenable沿当前
     `qjsPreparePromiseReactionJobs→ensure capacity→commit`思路一次预制本次全部entry，使fallible准备先完成、可见阶段不再因本批entry OOM；但不能把
     可观察顺序压成一个黑盒原子commit。必须保留QJS phase：先publish promise result/state，再同步通知rejection tracker，返回后才把**settle前已有**
     reactions按序接到FIFO并清list；对already-rejected promise的`then`则先handled通知、再发布该reaction job、最后置handled。
     若保留/开放可重入host tracker，queue reservation必须是不会被tracker内新enqueue吃掉的node/token，保证tracker中追加的job先于旧reaction batch，
     不能只预留一个会被reentry占用的slice tail。当前CLI-style unhandled list的OOM/报告策略单列HostPolicy，绝不能回滚已发布的promise state或污染core enqueue error。
     Nth-OOM保持原状态或进入显式pending-retry，但绝不settled-with-missing-job。dynamic import要按phase拆开：初始job尚未把promise返回给JS时，
     enqueue OOM可用entry realm与现成reject capability事务性拒绝后返回promise，或在连rejection都无法安全表达时保留明确Runtime exception且不返回
     永远pending promise；promise已暴露后的loader/TLA/host continuation若再次需要enqueue，则必须由typed pending-completion node own
     capability+RealmRef+reason并按序重试，不能把初始“可改为同步reject”的结论套到后期。reject本身若会发布reaction job，也必须复用同一
     Promise prepare→no-fail commit协议，不能假定调用resolve/reject天然no-fail。error/result ownership与递归OOM单独测试。
     FinalizationRegistry和waitAsync的no-throw来源分别由d3/下一bullet保留pending node重试。
     这些都是按GUIDE/no-cheating登记的safety divergence，不是QuickJS或Zig限制，也不计性能收益。
   - queue统一后立即删除ECMAScript路径上的`Queue.runAll`语义，建立QJS式`runOne` transaction：空队列返回empty；否则先unlink FIFO head，
     以entry RealmContext执行一个typed job，再按args/result/payload/entry RealmRef顺序清理并返回success或exception。exception value留在唯一
     Runtime exception slot，host/event-loop/module drain在首错处停止，后续entry与sequence原样保留；host若要drain到空，只能显式循环runOne并处理每次status。
     QJS `pctx`已经标obsolete，本轮不新增会在entry ref释放后悬空的context返回值；错误格式化/host callback若确实需要job realm，必须在release前
     使用borrow或显式临时dup。公开`job.drain(ctx, options)`只是选定Runtime的zjs host adapter，传入ctx不得筛选entry realm或覆盖entry RealmRef：
     `budget=null`循环到FIFO empty/首错，`budget=0`不执行，`budget=N`最多执行N个成功job；正常返回的`jobs_drained`为本次真实success数，
     `has_more`精确反映统一ECMAScript FIFO，首错则直接返回error而不是伪造部分`DrainResult`。以“A job抛错、B job随后排队”锁定第一次只消费A、
     A cleanup恰好一次、B第二次才运行；再以“队列已有B，A执行中enqueue C”锁定剩余顺序B→C。generic result不得被free后静默继续。
   - M-HOST-COMPLETION-TO-JOB在同一阶段收掉waitAsync product debt：foreign `Atomics.notify`/timeout path在global mutex下只能
     no-alloc地把preallocated node从waiting转为ready并signal owner runtime，禁止创建string、写Promise slot、跑reaction或调用allocator。
     owner runtime安全点按ready publication order取node，以node RealmRef把typed settle payload接入上述FIFO；job成功settle Promise后才释放
     Promise/store/RealmRef/node。settle或enqueue OOM必须保留ready/pending node按原序重试，`catch {}`、unlink后丢pending Promise和同一node
     双settle均为零。timeout由owner runtime/host clock queue驱动，不再靠“任意一次同ctx Promise调用顺便扫描”决定；notify/timeout/cancel竞态
     在一个显式state machine中只有一个winner，loser不触碰JS owner。Runtime destroy先停止接收、摘除/取消本runtime nodes、在runtime线程完成
     必需cleanup，再验证global registry/ready list/FIFO均无本runtime edge。该扩展明确登记为reference-version/API surface，不能伪称QuickJS实现。
   - M-FINALIZATION-REALM-ENQUEUE最后让FinalizationRegistry payload own construction RealmRef，cleanup job再按该realm进入
     上一步同一FIFO；registry自身仍参与真实weak-cell追踪，不能和普通borrowed realm slot一起删除。这里要分开两个phase：A realm构造的
     registry永远以A作为enqueue/job entry ctx，但cleanup callback若是B构造的C_FUNCTION/FB，`js_finrec_job(A)→JS_Call(callbackB)`的最终
     function carrier仍进入B。测试同时观察job前置错误/held-value处理的A来源与callback body/Error/global的B来源，不能把registry RealmRef
     错当callback realm，也不能给callback再复制A owner。
   - QJS FinalizationRegistry在GC中用`no_exception` enqueue并忽略失败；zjs不得用silent drop复制该quirk。GC-time enqueue OOM
     不抛递归JS异常，而是保留pending cell/realm/held value并在恢复后按原序重试，或使用预留的no-fail publication；这是命名的
     GUIDE safety divergence，必须有same-runtime recovery与不重复cleanup证据。
   - host timer/signal/I/O若继续走host event-loop queue，记录为非ECMAScript adapter；它不能抢占或重排QJS job FIFO。
   - creator facade销毁后native/lazy property/job/finalizer仍可运行，跨realm交错FIFO、GC mark/free与enqueue OOM rollback先红后绿。
     其他ordinary object上的borrowed realm pointer按真实consumer另审，不在本步盲目全删。
9. **M-REALM-NONCARRIER-RETIRE：按reader删除非carrier对象、property与cache上的realm补偿。**
   - 先冻结全量inventory：`realm_global_ptr`的20处声明/视图、BoundFunction/FunctionRarePayload的两个`realm_global` value、
     `host_function_realm_global`整数token、`objectRealmGlobal/functionRealmGlobalPtrSlotEnsured`及所有producer/reader；再加十个
     `__realm_*_proto`字符串property及`realmPrototypeKey/tagRealmFunctionConstructor/copyRealmPrototypeKeys/reflectConstructRealmPrototype/
     constructFunctionValue`，`tagRealmEval/tagRealmRegExpAccessorErrors`，FunctionRarePayload的`primitive_prototypes`与
     `realm_type_error_constructor`，以及OrdinaryPayload的`typed_array_array_buffer_prototype`。每个删除patch都先给当前reader标出
     QuickJS来源，不能因字段“看起来多余”整包清零，也不能换成generic RealmRef/property symbol后称为完成。
   - inventory不能止于字段名：同时枚举Runtime直接JSValue/Object roots、root providers、value-root slots、external-host opaque ptr state与
     class/plugin payload tracer，沿值边检查是否传递到C_FUNCTION/FB RealmContext。公开persistent/weak handle、活跃stack root和用户通过
     tracer声明的host object edge是命名owner，不应删除；内部runtime cache/record若无QJS对应或escape contract则必须在所属机制退场。
     W1b2.5/W1b2.6已分别负责六个dstr与八个using的`internal_destructuring_helpers`退场，W1b3b负责`MethodRuntime.prototype`；本步用全仓negative census防止只消灭`realm_*`拼写后
     留下等价hidden root；root-provider/runtime context list只能借且不得成为base ref，但RealmContext GC child traversal必须保留真实owned edge，
     不能把“删hidden root”误做成少trace一条强引用。
   - 按QuickJS class/data flow分组替换：bytecode/generator/async从`frame.cur_func→FB RealmRef`；C_FUNCTION从自身carrier；
     C_FUNCTION_DATA及其他data-callable从caller；bound/proxy wrapper保持caller并在需要FunctionRealm时递归target；constructor fallback
     经`newTarget/ctor→FunctionRealm`；ArraySpecies仅以FunctionRealm识别foreign intrinsic Array constructor；Promise reaction/thenable/
     dynamic-import/finalization从实际enqueue RealmRef；AUTOINIT从property slot。
   - 单独收掉可观察property链：Dynamic Function在Function C_FUNCTION的RealmContext中compile并由FB retain；Reflect.construct的
     `newTarget.prototype`非object fallback只走FunctionRealm→`class_proto[class_id]`。删除`__realm_*`定义/复制/读取后，以alternate Function
     own-key/枚举为零、dynamic function own-key为零、可写同名property不影响结果及Proxy newTarget只触发`prototype`get验收。
     任何字符串/symbol“隐藏键”都仍是可观察property，不能改名规避负向扫描。
   - 其余cache逐reader换源：eval identity与indirect eval global读active RealmContext的`eval_obj/global_obj`；RegExp accessor TypeError读
     eager getter C_FUNCTION active realm的`native_error_proto`；Object primitive boxing读Object C_FUNCTION realm的`class_proto`；
     typed-array内部backing ArrayBuffer读target C_FUNCTION active realm的`class_proto[ArrayBuffer]`，不得从result/newTarget prototype链猜。
     cross-realm target+foreign newTarget必须同时断言typed-array结果prototype与backing-buffer prototype，防止删cache后退回caller global。
   - global object、ordinary object/namespace/prototype、Array/arguments、RegExp、buffer/typed-array、collection/iterator、Promise实例、WeakRef/VarRef、
     module namespace与disposable-stack实例不再提供通用realm。它们的分配/异常用当前operation RealmContext，realm-specific prototype/
     constructor由已有object graph或newTarget决定；host std-file/plugin等扩展若确有跨回调需求，必须使用命名的HostPolicy/RealmRef carrier
     并给escape证据，不能继续借generic object slot。
   - lazy namespace/prototype迁移是硬门禁：每个AUTOINIT slot在第8步已经own RealmRef，materialized C_FUNCTION再own；target ordinary
     object因此删realm也不改变方法realm。generator删cache前证明saved current function在所有suspend/resume/free路径支配FB；
     raw internal generator若没有function object，必须让execution state显式own FB/RealmRef，不能保留特殊borrowed例外。
   - 从一个payload family开始，依次删除producer→reader→slot→teardown/size补偿并跑cross-realm/OOM；最后删除
     `clearBorrowedReferencesForDestroyedObject`中的realm matcher、AUTOINIT realm token清零和仅为function/generator realm存在的holder
     index/registration。`borrowed_reference_holders`若仍服务WeakRef、weak collection和FinalizationRegistry cells，就重命名/收窄为
     weak-edge registry并保留其GC逻辑；禁止为了负向`rg`误删真实weak semantics。
   - 阶段出口要求generic `objectRealmGlobal`、realm-oriented `setFunctionRealmGlobalPtr*`、所有非carrier
     `realm_global_ptr/realm_global`与`host_function_realm_global`为零；`__realm_`、全部tag/copy/reflect helper为零；
     `primitive_prototypes/realm_type_error_constructor/typed_array_array_buffer_prototype`在FunctionRare/Ordinary payload、trace/free/count
     路径为零。RealmContext本身可有QJS对应的`class_proto/native_error_proto`，负向检查必须限定owner，不能误删真state。
     公开`realm_global`兼容只允许命名的cold boundary exact-global→RealmRef adapter，VM/exec reader为零；它不算generic object resolver。
     只允许FB、C_FUNCTION、AUTOINIT、job、FinalizationRegistry及明确host carrier中的typed RealmRef；内部Runtime-owned JSValue/root
     不能无清单地传递性保活RealmContext，公开embedding handles则由W1b3a teardown precondition计数。该patch train只做
     correctness/ownership退场，收益记零，不夹带payload layout、cell或call fast path。
10. **M-EXPLICIT-TERMINATOR：让production bytecode永不fall off。**
   - 对照`js_parse_program`：script/direct/indirect eval显式维护completion并以可见`return`结束；module与普通函数的
     normal fallthrough显式`return_undef`，所有jump-to-end落到真实terminator。
   - diagnostic qjs/zjs snapshot覆盖empty/comment/last-expression/if-switch-loop/try-finally/generator/module/eval；
     stack-size/finalizer拒绝任一reachable falloff。先完成correctness，不把新增opcode成本算作优化。
   - 删除final FB与mutable root的`+1`、`ensureTrailingReturnSentinel`及生产dispatch对`code[len]`的依赖。hand-built tests
     补显式terminator；确需容错的fixture-only runner保持bounds check，不反向污染production artifact。
   - sentinel storage/dispatch-residency变化单独测量，不借机重开整个dispatcher。
11. **M-CANONICAL-ROOT-FB：root与child只保留一种final artifact。**
   - terminator与CompileContext稳定后，让script/direct/indirect eval的root FunctionDef也走
     `createFunctionBytecodeAfterChildren`同一finalizer；`parser.Result`只own一个final FB，不再并存mutable Bytecode root与第二份表。
   - VM尚未直接消费FB的过渡patch只允许non-escaping stack-borrowed adapter；不得建立heap view、复制rows/source/debug或
     给Result新增第二套析构公式。compile/finalize失败和Result未执行销毁都释放唯一owner。
   - module root暂留显式legacy variant并在W1e迁移，不能为了ordinary root先伪造QJS nullable import/link状态。
   - root/child bytecode与ownership snapshot、direct/indirect eval compile policy、empty/abrupt/OOM先锁；该步是canonicalization，
     不把删除后续view或closure construction收益提前记入。
12. **M-FB-DIRECT-EXEC：canonical root后让VM/frame/call直接消费最终FB。**
   - 按code/vardef/closure/cpool/debug accessor逐组把canonical function类型迁为`*const FunctionBytecode`；中间patch只允许
     第11步的non-escaping stack adapter，不能建立第二个heap view。
   - 删除`cached_view/ensureCachedView`；attach core接收并消费一份**owned** FB value，成功把该引用转给object，失败由object
     teardown恰好释放一次。`fclosure`的cpool get-result直接转移，不再“dup给attach再free原值”；attach/pass1前不新增OOM点。
   - 对view中非别名字段完整disposition：module身份归record/entry，mapped arguments只来自pseudo vardef/opcode；
     `codeRescuesImplicitArgumentsViaGetVar`逐个对照QJS final code后修producer或删除。simple/strict/snapshot与leaf分类在新基线
     单独A/B；无收益删除，有可复核Zig/LLVM收益才允许作为compact documented execution extension，禁止每call扫描code。
   - 删除无true producer的FB/view backtrace位；QJS barrier只作为entry对caller frame的临时set/restore。以offset/load-chain/
     assembly及first-closure/no-call、repeated closure、first-call、call/regexp controls验收，不与root、terminator、move或pack合刀。
13. **M-GLOBAL-CELL-SELECTOR：先给closure2准备唯一的ordinary GLOBAL来源。**
   - 先为`ensureGlobalLexicalCell`的“旧global-object VARREF变lexical cell、旧值移入新property cell”和
     `ensureGlobalObjectVarRefCell`补identity/descriptor/OOM锁定；它们是已对齐机制，不纳入重写范围。
   - `createGlobalClosureVarRef`、`initialClosureVarRef`、direct-eval初始capture共用
     lexical VARREF→materialize AUTOINIT/retry→global-object VARREF→shared uninitialized side-table cell；selector只选择/
     retain cell，不读取capturing row去改owner flags。
   - data/accessor/VARREF/AUTOINIT、configurable/extensible与两个root共享缺失global cell逐项锁identity与异常顺序；
     `createGlobalModuleVarRef`的fresh fallback留到persistent module删除。
14. **M-CLOSURE2-ONEPASS：ordinary root与nested共用一次最终cell构造。**
   - script/direct/indirect eval先建立自己的function object/current-function，再分配最终slot array；完整
     GLOBAL_DECL pass1后按closure顺序一次创建/别名，不经过placeholder→frame copy→replace。
   - function class/prototype与所有construction errors使用FB RealmRef对应的RealmContext；nested路径断言当前active realm与child FB
     realm相同，root路径直接从owned FB取realm。caller realm不能作为fallback，closure2也绝不写回或“修正”FB realm。
   - ordinary script/direct/indirect eval消费第11步`parser.Result`中唯一owned root FB并把它转移给最终function object；
     direct-eval caller frame只作为capture source，最终eval function拥有capture array与`cur_func`。本步不设计module owner状态机；
     module legacy variant与nullable import/indexed linker完整归第20步。
   - capture fill只选择/创建/retain cell，不按consumer row二次修改flags；local owner metadata、GLOBAL_DECL helper、module
     owner与closure opcode各自承担自己的const/lexical/function-name语义，ordinary GLOBAL alias保持纯别名。
   - direct eval通过最终closure rows直接捕获arguments object/binding后，删除`frameArgumentsObjectForSpecialObject`按
     final `has_eval_call`写FrameCold的跨bytecode cache；`has_eval_call`只留FunctionDef供capture，
     不进入FB。leaf eligibility若仍需排除eval，在第12步已裁决的derived execution class中表达，不能复活原bit。
   - nested function在最终class/prototype上分配、以owned-transfer attach bytecode后立即capture；只有对象class/prototype与
     bytecode ownership可在capture前，realm已经属于FB而不是closure mutation。length/name以normal data property按QJS后移并
     传播真实失败，只有`.prototype`按PROTOTYPE ID保持lazy；不得用通用string AUTOINIT延迟function name。随后再安装其余属性，
     lazy prototype property使用第8步owned RealmRef。QJS的void property helper会忽略部分失败；zjs按GUIDE传播错误并完整teardown，
     这是命名的failure-path safety divergence，不能复制QJS缺陷或用它制造更少分支的性能收益。
   - 先把现有import-meta/private/arrow/class-field adapter全部移到capture之后，证明object发布/OOM顺序；它们的删除拆到第19步，
     不与root所有权迁移塞进同一候选。
   - field-by-field退场`EntryContract`：本步删除`var_environment`和root current-function补偿；四个QJS grammar capability
     继续留在FB；`has_arguments_binding/has_this_binding`只在第19步证明class/arrow lexical captures后删除，不能整包延期或整包先删。
   - OOM覆盖function/array allocation、pass1第N项、pass2第N cell；成功路径对齐qjs，失败路径按GUIDE
     完整rollback并验证same-runtime recovery。
15. **M-PC2LINE-QJS-FORMAT：让最终debug buffer自己拥有起始坐标。**
   - 在canonical root后修改唯一producer：buffer先写起始`line-1`与`column-1`两个ULEB128，再写现有
     pc/line/column delta；删除`DebugInfo.line_num/col_num`及最终compat view的平行start fields，runtime只从buffer解码。
     当前full-debug production产物必须至少含这两个ULEB128；无debug只允许fixture/future reader显式构造，空/截断full-debug
     一律走malformed路径。
   - decoder按`find_line_num`做完整边界检查；显式no-debug、截断header、坏LEB、pc在首slot前/中间/末尾与
     `pc=-1`式function-definition location均有明确fallback，不能靠unchecked slice或默认`1:1`掩盖坏artifact。
   - 用不同起始line/column、短/长delta、nested/eval/throw stack的diagnostic-qjs bytes与行为golden锁定；这一步是
     correctness/layout前置，字段减少收益记零并且不夹带buffer ownership或主allocation变化。
16. **M-FB-COMMIT-TRANSFER：finalize成功路径move，不再dup/copy/free往返。**
   - 在commit前完成主/side allocation、row count/layout验证及所有可能失败的debug/class准备；commit之后不得再`try`。
     当前`gc.addInitializedWithSize`是intrusive link + scalar accounting，没有真实error producer；为FB提供类型上no-fail的
     initialized publication并在move commit后调用。不得保留虚假的`try`/reserve-OOM测试来制造transaction复杂度。
   - vardef/closure atom IDs、cpool values、func_name/filename、bytecode中编码的atom ownership、source与pc2line owner逐项转移，
     同步把FunctionDef/lowered source slots置null/undefined/empty；closure共享storage后只复制row bytes，不逐项dup atom。
     注意QJS最终仍把code bytes `memcpy`进inline tail再释放旧buffer；这里转移的是其**内嵌atom引用所有权**，不得把
     “move ownership”误写成最终code pointer零拷贝。
   - 当前zjs没有strip producer/API，本阶段只迁移**现有full-debug production contract**：filename/source/pc2line与所有
     vardef/closure runtime name保持原有可观察保留。不得为了贴QJS feature surface新增`strip-debug/strip-source/strip-var`
     mode，也不得让`has_eval_call`重新进入final FB。第17步的optional debug tail只需由fixture builder证明表示/析构完整；
     真正strip policy与binary reader以后作为独立功能兼容项，不阻塞本轮机制优化。
   - ordinary source producer先建立QJS compiler式`logical_len+1` owner并写末尾NUL，FB只记录logical length，finalize直接move；
     binary-reader source owner若未来实现则按reader源码另立契约。QJS对
     DynBuf pc2line作best-effort shrink；Zig allocator释放时需要真实allocation length，而QJS header没有capacity字段，所以
     用已有source-location slots做“两遍exact-size producer”（checked计算编码长度→一次accounted allocation→写入）后直接move。
     删除当前ArrayList临时buffer→exact-fit allocation的额外copy，也禁止为了源码外形再造一次realloc/OOM点。若未来producer
     保留capacity，必须在commit前exact-fit，或以具体allocator限制给出capacity owner，不能偷偷拿logical len释放更大allocation。
   - Nth真实pre-commit allocation/transfer边界、refcount/accounting、child cpool、现有full-debug name/source retention、
     abrupt finalize与same-runtime recovery先红后绿。该候选单独测construction refcount/bytes，不把后续header layout/
     inline-debug box消除或artifact allocation merge收益算进来。
   - free path对照`free_function_bytecode`锁code atoms→vardef atoms→cpool values→closure atoms→realm→func/debug atoms与
     buffers→GC unlink/raw free的逻辑owner释放序；若zjs cycle breaker必须先clear edge，记录为具体GC transaction适配并证明
     每个owner仍只释放一次，不能以“析构反正不可观察”忽略child FB/realm lifetime。
17. **M-FB-CORE-LAYOUT：先冻结QJS header offsets/alignment。**
   - canonical root、direct consumer、QJS pc2line格式和move commit稳定后，把独立header allocation改成96B/align8
     `extern` base + optional 32B inline debug tail（当前production始终full-debug，共128B）；cpool/vardefs/closures/code仍留在既有read-only block，
     不在本刀合并。self pointers先照旧指向block，但header字段offset与QJS一致；原`DebugInfo.block_ptr`迁为header后的临时
     `artifact_block_base` extension owner，block size由唯一checked `ArtifactBlockLayout`从counts/code长度重建。
   - flag storage用显式整数byte/mask和raw-byte golden复刻pinned C bitfield结果，不把Zig packed布局当证据：byte17/18
     逐位按§1.7固定，byte18 bit3作为无reader时恒零的ROM hole、bit4仍是combined eval。W1d前仍活跃的
     `class_meta/class_fields_init`、ScriptOrModule及其他非QJS事实不得占core pointer；以spare flag说明
     presence，并紧跟本阶段header放入可计算extension。extension只保存现有事实/owner，不改语义，不建第二个execution view。
     strict必须回到QJS `js_mode:u8`的STRICT mask；删除零producer的FB backtrace事实，QJS BACKTRACE_BARRIER只保留为frame-mode
     常量/entry行为依据。zjs `runtime_strict`先完成owner审计，确需持久FB hot bit时才占明确的byte18 product-extension
     spare bit或optional extension，禁止复用QJS `JS_MODE_ASYNC/BACKTRACE_BARRIER`位，也不能保留第二份strict storage。
   - `vardefs/closure_var/cpool`改为single-word nullable pointer（先锁Zig ABI），count为零时必须raw NULL、非零时必须指向
     有效table；accessor才把null+zero变为空slice。production code在第10步后至少含terminator，byte-code pointer不靠dangling
     sentinel表示空fixture；ROM借用形状只登记未来reader，不制造当前producer。
   - header宽度/signedness也逐字段锁定：`byte_code_len/cpool_count/closure_var_count`为i32，
     `arg_count/var_count/defined_arg_count/stack_size/var_ref_count`为u16；debug tail的`source_len/pc2line_len`为i32，
     RealmRef必须保持single pointer并位于`realm@0x48`，`filename@0x60`、4B zero pad和两个pointer offset逐项断言。
     所有转usize都在validated accessor/layout calculator内完成。
   - 先引入唯一production raw builder和fixture-only builder；迁移所有测试中的直接alloc/by-value init，fixture输入显式声明
     code/table/debug内容，但builder统一复制/转移成与production相同的独立artifact block owner。由此在本步删除`from_block`
     与per-slice fixture free分支；native function object保持独立control，不允许为test方便恢复第二种production header/free路径。
     builder复用`MemoryAccount.createWithFam(FunctionBytecodeBase, tail_bytes)`与`destroyWithFam`，不得以普通aligned allocation
     绕过GC metadata；allocation后按QJS `js_mallocz`清零整个base+tail。本阶段tail只含32B debug（或fixture显式no-debug）与header extension，
     并断言所有tail成员alignment不超过base align8。
   - 删除`header align(16)`、`*align(16)`parent casts与总是存在的DebugInfo box，锁临时block-base extension、8B GC prefix、slab资格、
     production full-debug/fixture no-debug header、extension/no-extension、关键offset/load chain、heap accounting/GC/OOM。单独A/B construction/no-call/
     first-call，明确这一步包含QJS inline-debug header带来的box消除，但不计下一步header+artifact allocation merge。
18. **M-FB-PACK-CORE：再单独改变allocation topology，不虚报total exact。**
   - 从稳定header layout把cpool、vardefs、closure rows和**精确code长度**并入同一个raw GC allocation；self pointers由QJS
     offset建立。`source`与`pc2line_buf`保持第16步转移来的独立owned buffers；不把QJS未来pack注释当当前机制。
     zero-init范围必须随FAM扩大到header+debug/tables/code/extension全payload，再覆盖有效row/value/code bytes；这部分成本
     属于QJS core pack，不允许通过未初始化尾部规避。
   - 把第17步header后的extension搬到exact code之后，presence/size仍由counts+flags计算。第10步reachable-falloff拒绝是
     数据位于code后的硬前置，任何dispatch都不得读取extension首字节；ordinary core access不得新增extension load。
   - allocation/free/accounting/extension定位必须共用一个checked `FunctionLayout`计算器：先验证u16/i32 counts与
     `byte_code_len`非负，再用checked add/mul得到QJS顺序offset和total size；禁止allocator、destructor、heapByteSize各复制
     一份reserve公式，也禁止靠wrapping cast复刻QJS C的整数溢出缺陷。自然alignment以pinned offset断言证明，不插入未记录padding。
     默认16B JSValue锁pinned qjs raw offsets；8B alternate只锁参数化公式、owner/free和行为，不声称同一raw offset。
     QJS core的header→cpool→vardef→closure→code之间不得有padding；optional extension若含align8成员，则其
     `extension_off = alignForward(code_end, extension_align)`及zero padding必须由layout显式记录并标为core外成本，extension为空时
     allocation必须恰好止于code末尾。
   - `FunctionLayout.mainPayloadBytes/famBytes()`同时服务`createWithFam/destroyWithFam`与主allocation accounting；析构先从
     live counts/flags捕获一次layout，再清owner字段。`heapByteSize`在该main payload之上只显式加独立source(`len+1`)、pc2line及
     仍获准的side owners；MemoryAccount自行计算的8B metadata/slab prefix不得在layout里重复加。禁止从已清零字段猜另一份长度。
   - 删除W1c4临时`artifact_block_base`、独立block allocation/free与旧`ArtifactBlockLayout`，由`FunctionLayout`统一heap accounting/free；debug/no-debug、extension/no-extension、
     args/noargs、closures/no-closures、offset、OOM和GC cycle逐项锁定。从core-layout稳定点单独A/B allocation/no-call/
     repeated closure及controls。此阶段只可称core pack，total allocation exact归W1d/full-close。
19. **M-CLOSURE-SIDECHANNEL：把仍活跃的函数语境全部迁回bytecode/closure。**
   - import-meta/private-name/arrow lexical state改由bytecode/closure承载并删除side slots。private作为本阶段第一个不可拆checkpoint：
     每个声明在private scope调用等价`add_private_class_field→add_scope_var`，compile VarDef携带lexical+const、exact VarKind和仅供
     duplicate getter/setter检查的static事实；field立即以`private_symbol→scope_put_var_init`初始化，method以
     `set_home_object→set_name→scope_put_var_init`初始化，getter/setter建立base row、`<set>` companion row并在配对时把base kind升级为
     `private_getter_setter`。nested method/field initializer/direct eval只经普通capture取得这些槽，undefined private name仍在resolver报错。
     `resolve_scope_private_field`逐VarKind精确展开field的get/put、method的`check_brand+nip`、getter的brand+零参call、setter companion的
     stack rotation+一参call及readonly throw；`#x in obj`同样读取binding，不再以bound-name atom fallback代替槽。
   - private field本身不触发shared brand：每个field的lexical slot保存独立`private_symbol`并由它完成identity/access。只有private
     method/getter/setter把对应`ClassFieldsDef.need_brand`置真，此时instance/static**每侧至多一个**shared brand。instance侧在class定义点把
     prototype登记为brand，并patch fields-init child使每个新instance执行`this+home_object+add_brand`；static侧在class定义点让class自身
     持有对应brand。private method/getter/setter保留为lexical captured values，instance不复制descriptor。删除
     `initializeClassPrivateMethods`的home-object descriptor scan/copy、object/function private remap，以及由
     FunctionDef→Bytecode/FB/constructor传递的private-name metadata carrier；`Parser.State.class_private_elements/class_private_bound_names`
     只保留为grammar/early-error/direct-eval parse临时表，不属于该final/runtime负向门禁。重复class evaluation必须由运行时
     `private_symbol`/closure产生新identity，而非parser atom冒充。non-extensible实例同样以pinned QuickJS结果验收，不保留test262语义旁路。
     该checkpoint绿前不得从CORE提前合入private temp opcode、空声明槽或atom fallback。
   - class-fields再拆成两个QJS精确子步：instance initializer child写入
     lexical `<class_fields_init>` binding并由base/derived/default/user constructor普通调用，删除
     `FunctionBytecode.class_fields_init`、function rare payload与construction call-site注入；static initializer也建立
     `<class_fields_init>` child并以class作receiver立即调用，随后删除`VarKind.class_static_this`、synthetic atom、runtime
     vardef scan、eval `0x8000`和15-bit限制。所有有/无initializer的public/private/computed field均由对应child定义。
     `class_instance_fields`当前无parser producer，先锁empty/reachability再作为dead parallel
     mechanism删除；不得把它计作active候选收益。任何保留项都须先记录具体Zig限制。
   - `script_or_module`不再预判永久保留：real root/frame完成后，对照QJS `JS_GetScriptOrModuleName`覆盖普通/直接/
     间接/escaped eval、dynamic import、import.meta与display stack filename；本轮只验当前full-debug production contract，
     不为测试这个字段新增strip feature。能从frame/module owner精确取得就删除FB atom；
     若zjs规范/host contract确需“诊断名≠referrer”，保留extension前必须给出行为反例并登记为product divergence，
     不是Zig限制，也不能再称total allocation exact。
   - final FB删除`is_arrow_function`前，证明lexical this/new.target/home只来自captures、constructibility只来自function object；
     本阶段只清掉第14步后剩余的`has_arguments_binding/has_this_binding`脚手架。每类adapter第N项补OOM recovery。
   - 最后执行 **M-FB-PACK-EXACT-CLOSE**：所有QJS-compatible function的optional extension必须为空，allocation在exact
     code末尾结束，96B base/128B full-debug header、align8及table offsets不因本阶段改变；若header保留字节仍承载经A/B
     裁决的Zig执行分类，或只剩经裁决的product extension，结论必须写成
     “QJS core exact + documented extension”，禁止省略限定词。重跑ordinary call/cell/Zoo确认core-close load chain未漂移。
20. **M-MODULE-REALM-PERSISTENT-LINK：每个realm内同一个function、同一段bytecode、同一套cell。**
   - 先把`JSRuntime.modules`的loaded-record identity/index迁入`RealmContext`，normalize/load callback继续作为runtime host hook；
     改为RealmContext own registry/list及其base refs；ModuleRecord本身不额外own RealmRef，并像QJS finalizer一样允许从live list
     unlink。同一specifier在两个realm中必须产生不同record/function/cell/namespace与错误状态。registry析构随realm owner走，
     不能靠runtime teardown兜底，也不能把host file cache误当loaded-module registry共享。
   - module record以同一个`func_obj`变体slot持有编译产物/function/capture array，停止preload/instantiation/evaluation重复compile；
     精确复制QJS owner状态机：object allocation失败时slot仍持FB；allocation成功后先把slot改成object再owned-attach，成功后
     object传递性持FB；attach失败则slot清undefined并由object teardown释放FB。不得用“record和object双retain”简化失败路径。
     当前module closure先于dependency创建。
   - declaration append后固化export/import`var_idx`；MODULE_IMPORT用optional staging，normal import alias exporter，
     namespace import写importer-owned cell，link完成后seal typed refs并retain local export cells。
   - 严格按deps DFS→indirect export validation→indexed import wiring→retain local exports→`this=true` declaration call→
     Tarjan SCC commit执行；用同一graph中同时存在missing indirect export与bad import的反例锁异常优先级。
   - 任一失败先忠实把linking stack全部恢复unlinked，不把本节点永久置errored；partial refs/cells cleanup是GUIDE要求的
     更强transactionality，必须证明不改变qjs的异常优先级、可观察identity与合法重试结果。namespace normal property直接
     VARREF、cycle-dependent才AUTOINIT；anonymous default由prefix`set_name default`。
   - QuickJS C module没有bytecode function/guarded declaration call；zjs host/plugin/synthetic module作为对应control单独映射，
     不为追求表面统一强造JS function，但必须遵守相同dependency、export resolution与SCC status协议。
   - `MODULE_IMPORT`在module function创建时使用真正nullable optional staging并保持null，完成indexed wiring后再seal
     typed refs；该null时序、失败清理与namespace import own-cell测试只在本步验收，不反压ordinary closure2。
21. **阶段门禁与重新冻结。**
   - 每一子机制先focused red/green，再parser/bytecode/exec/module、quick-check、checkpoint、相关test262；ownership阶段跑OOM。
   - 第4–18步形成**ordinary script/direct/indirect-eval core close**：按pre-commit规则跑该候选唯一一次ReleaseSafe、
     完整相关gate并可独立合入；随后立即重冻cell direct controls与regexp Zoo，按新profile决定plain put是否仍排第一。
   - 第19步sidechannel与第20步module各自独立收口/合入并重冻受影响consumer；它们阻塞“全部construction对齐”的声明，
     但不阻塞ordinary regexp/cell的因果测量。plain put与set若进入生产候选仍各自单刀，read split不重开。

#### 必须先变红的最小矩阵

- entry integrity：public `-e '1 2'`/`eval('1 2')` 必须 SyntaxError；empty/comment/direct/indirect eval都经过
  parser和 real root function；direct eval frame 的 current-function是 eval function，caller只作为 capture source；
  `Function("return class X extends Uint8Array {}")()`必须返回真实`X`而非基类且保留body side effect；async参数中的
  IdentifierName/nested function合法、真正AwaitExpression非法；全仓active source replacement为零；
- entry environment：在创建real root前后，sloppy/strict root direct eval的global declaration归属完全相同；nested ordinary/
  arrow/class method/class-field initializer中的eval分别锁`arguments`、`new.target`、`super.prop`资格；同名local/closure/global
  lexical存在时，global data read/write/`undefined` IC都不得因current-function从undefined变object而绕过或误触发；
  generator/async suspend-resume始终保存真实current function，不再靠receiver fallback补身份；Annex B block function、catch、
  cover-grammar shorthand、参数环境和nested arrow逐一证明隐式`arguments`最终只读pseudo local/capture，production final code无
  `get_var(arguments)` rescue形状且两个global handler不再按atom特判；
- exact structure：root `declared,childOnly,print,rootOnly` 次序；child-only ordinary global 的 root
  `GLOBAL` + 全链 `GLOBAL_REF`；nested eval的 `a,b,eval` fixed prefix；open-binding index覆盖 args-first eval与
  child-demand-first普通 closure；capture identity按 `(type,index)` 而非 name；同一cell被const/function-name/ordinary rows
  多次capture后owner flags不被consumer污染；finalization开始后只有一条破坏性重建的scope链，`finalizedScopeHead/Next`第二算法为零；
  production `.is_captured` mutation只经`captureBinding`，ordinary access仍是 `get_var/put_var`；
- final table semantics：args→locals位于同一个vardef数组，arg/local `var_ref_idx`均保持event编号；compile/final
  closure都不含`source_depth`，最终FB不含`scope_parents`，也不复制`func_pool_idx/tdz_emitted_at_decl`；每个
  `eval/apply_eval` operand等于vardef链头调整值，parameter scope以`ARG_SCOPE_END`结束且不占高位；static class-field的
  `0x8000`必须明确归W1d红灯，W1d完成后所有eval operand才恢复完整u16；script/direct/indirect combined-eval位正确；
- final physical records：closure compile/final storage均为8B/align4、vardef为12B/align4，并锁QJS对应offset；
  closure byte0/byte1与vardef flag byte逐defined-mask一致、padding由zjs归零且不读取QJS未初始化hole；wire flags另序且未被
  误当storage golden；QJS VarKind 0..10 raw值逐项一致且临时`class_static_this`只占11；uncaptured final vardef以
  `is_captured==0`判别并把无效index归零，不再泄漏compile `0xffff` sentinel；
  `closure_var_count`与`var_ref_count`语义不混淆；FB base为96B/align8、full-debug header为128B、GC prefix 8B且不再需要
  `*align(16)`cast；header验收包含关键field offset/load chain、raw flag bytes与唯一layout公式，不能只断言full-debug总大小128B；
  vardefs/closures/cpool逐项满足zero-count↔raw-NULL；production raw builder只有finalizer一个，所有手造FB测试经fixture-only
  builder，native function不进入FB路径；
- realm state/identity：default与`$262.createRealm()`都建立独立GC/refcount RealmContext；`eval_obj/class_proto[]`、
  function/array/regexp/promise/iterator constructors与prototypes、`array_proto_values/throw_type_error/native_error_proto[]`、
  五个direct initial Shape/global lexical与random逐realm隔离；对应regexp/arguments/match-result的layout carrier不再是隐藏JS template Object，
  iterator-result等zjs-only template已删除或作为独立product cache验收；
  direct-shape constructor在object/property allocation的每个Nth-OOM都释放prepared data/getset entries与shape ref恰好一次，成功路径无template clone或entry二次dup；
  array implicit length、mapped/unmapped callee、regexp lastIndex及result input/groups的move后source均清空，失败后same-runtime可继续构造；
  zjs-only preallocated OOM Error按realm隔离且明确不是QJS Context字段，普通/仍可分配OOM错误继续按active realm prototype新建，
  fully-exhausted fallback才零分配复用且无stack；bootstrap/递归fallback不引用首realm。
  A/B fully-exhausted catch得到各自prototype/fallback且不共享identity；同realm重复耗尽可能复用对象这一observable safety divergence有明确
  contract，不能归因给QJS。源码/测试中把它称作QuickJS analogue/preallocated exception的误导措辞为零；
  公开handle与global不再冒充identity或平行own slot；
  global object由显式class/flag判别，`.realm` payload presence不再决定`isGlobal`；uninitialized-vars仍由global class payload own/trace/free，
  global lexical与intrinsic caches归RealmContext，AUTOINIT global→VARREF与global exotic仍精确命中；
  exception/current stack已归Runtime/stack-local。释放host handle后，escaped RealmRef仍保持context/global/intrinsics存活；
  `$262.createRealm().global`在临时wrapper回收后仍由命名harness base存活，父test teardown恰好释放；runtime context list不own ref，
  root-provider list同样只借且不进入cycle child walk；RealmContext-owned children不经provider冒充external root，EventLoop等host-owned callback
  仍由专用external tracer枚举。`.realm_context`已覆盖GC kind/candidate/size/trace/revive/zero-ref/gates/partition/deferred-free/deinit verifier全部switch；
  construction Nth-OOM锁定“raw slots→GC header `.constructing`→fallible bootstrap→context-list `.live`”两阶段publication：本阶段已迁入以及后续carrier patch发布的每个RealmRef edge都能trace header，
  失败走统一child teardown且半初始化realm从不被legacy/plugin/list consumer看到。runtime context link与GC header link互不复用并各unlink一次，finalizing realm在child release前已不出现在context list/provider。destroy先运行host finalizer，再要求job/harness/public/external RealmRef及
  strong/weak/local value-root slot归零，不靠`clearPersistentRootSlots`静默invalidate外部handle。dup/free no-fail、bitwise copy不产生owner，
  且context↔global cycle本阶段闭合，native/AUTOINIT cycle分别在W1b3b/d1迁入后闭合；external-ref scan revival与last-ref GC/accounting恰好一次；public `realm_global`仅对调用时registered live exact global成功并在边界
  变为RealmRef，live ordinary/cross-runtime global/未登记地址报错且比较前不解引用，VM内无reverse lookup；free后地址复用明确不在裸指针API可诊断contract内；
  Context创建、class growth、plugin slot cleanup和GC/list mutation要么都在同一owner-runtime thread且错误线程被assert/reject，要么都受同一具名Runtime mutation lock保护；
  并发Context创建/注册/卸载测试不得出现旧`class_count`的live Realm、漏扩slot、重复unlink或callback栈内close；锁模型以hook断言GC/JS/DSO/finalizer进入时未持mutation lock，
  callback重入registration靠generation reconcile完成，foreign waitAsync只signal owner执行域；
- host event-loop context：A上的installed EventLoop own一个命名RealmRef且只保存稳定A core context；该ref明确是保持zjs
  `runUntilIdle(self)`API的host-lifetime adaptation，不宣称quickjs-libc也dup ctx。销毁A的binding wrapper后仍可
  enqueue/drain timer、rw与signal callback，vtable收到的context地址等于A RealmContext且无core→binding反向cast。handler只own/trace
  callback value：A loop中调用B构造的函数仍由该函数carrier进入B，loop本身不参与FunctionRealm。deinit按detach→释放所有callback
  roots/buffer→free RealmRef恰好一次，随后A可回收；live installed loop会使Runtime destroy前置检查失败，不能被teardown静默失效；
- custom class ID/definition/prototype：默认QJS路径下，同一显式ClassIdSlot/static binding在R1/R2取得同一stable class ID，独立plugin installation
  则取得不同且永不复用的ID；definition、
  registration OOM与prototype slot彼此独立；卸载R1不清R2 record且ID不回收/复用；65535可注册，下一次allocation明确exhausted且不wrap。
  若审计最终证明必须保留Runtime-local产品contract，则改锁
  cross-Runtime handle/ID use必拒绝且文档不得宣称QJS aligned。动态class注册前已经live的A/B与注册后创建的C都有当前Runtime class-count对应的slot capacity，新槽初始null；
  增长Nth-OOM不发布class record且可same-runtime retry，允许不可观察的partial storage growth，但失败后low-level get/set仍按旧published bound拒绝这次新增范围；registered/NotInstalled另测；low-level class publish与prototype
  take/get-dup是两步；setter分别consume object/null/primitive值，getter返回dup，而对象创建只对object tag采用该prototype、其余tag都得到null prototype。
  replace/clear把new/null写入后才释放old；old prototype的last-ref finalizer重入getter/第二次setter/class registration时只看到新slot，old/new各释放一次且既有object shape不变。
  forced-GC allocation下，只有cycle的realm可在preflight回收，有external ref的realm全部扩槽；遍历中无unlink/UAF/skip。
  object construction在GC/fallible allocation期间触发另一class注册扩表、目标class pending-unregister及plugin callback重入时，无stale `recordPtr`/旧definition publication；
  generation变化在object挂GC list前回滚，standard class不多付dynamic pin，live object与pending payload finalizer都阻止definition注销。destroy路径在property/shape递归释放触发扩表后仍调用原definition的恰好一个finalizer；
  若plugin高层transaction失败，按其命名contract rollback，不能据此改写QJS步骤。runtime plugin HostClass与binding JSObject只把prototype安装进
  construction RealmContext A的`class_proto[class_id]`，B/C仍为null；Runtime class table/InstalledPlugin只存metadata，
  `InstalledPlugin.host_classes[].prototype`及其他external-record JSValue edge为零。从A安装的plugin binding在B调用时按C_FUNCTION进入A，
  HostServices创建的opaque wrapper使用A slot；binding function own A RealmRef，而只剩opaque wrapper时仅由shape保活prototype、payload保活
  plugin metadata，不得继续钉住A RealmContext。每次DSO binding/finalizer/tracer callback有temporary execution pin，callback内部删除最后owner只排队unload，
  回到zjs trampoline并释放最后pin后才沿context list把A slot take-null、unregister/close；
  object/binding销毁已把DSO finalizer复制进deferred queue时，该node从enqueue到callback返回持installation/definition pin；last live owner释放后lib仍不close，
  drain执行一次callback再解pin，或Runtime teardown走明确不调用DSO且能安全释放payload的cancel contract，绝不清空node后留下悬空code/data pointer；
  A teardown触发最后binding release时同一scan可重入且不double-free；只剩opaque wrapper时A可先回收，wrapper释放后scan为空仍可安全unregister。
  测试用hook锁定slot free→definition unregister→DSO close顺序，close后无descriptor/finalizer调用。最终slot release与dynamic class unregister各恰好一次。未安装realm不fallback其他realm；
  core null-slot class creation保持null-prototype，`JSObject.binding/new`的`NotInstalled`只作为已命名embedding gate；prototype chain/branding与
  现有binding/plugin fixture保持；
- public native Binding lifetime：method-shape-compatible `Binding`只含borrowed RealmContext identity+class_id、无raw prototype/JSValue，
  new/payload每次读live class slot且只能在owner/RealmRef lifetime内用；显式`OwnedBinding` own一份RealmRef并deinit。销毁public ctx wrapper后
  owned binding仍可new/payload且exact realm brand不漂移，deinit后realm/prototype可回收；borrowed after-owner-release为无效用法并在safe build
  尽可能拒绝。slot replace后view使用新brand、old object保持旧shape且不再被该live view接受，slot clear后`NotInstalled`；
  `Binding.prototype:*Object`、copyable implicit owner、Runtime/class metadata替binding保活三者为零；
- Array write consumer/guard：A/B初始Array.prototype各自standard；给A的Array.prototype或Object.prototype加tagged-small整数索引，或把A Array.prototype的
  prototype成功改成不同值，只清A guard，B logical-end append/push仍有direct资格；同值设置和被拒绝/抛错的设置都不误清。
  tagged-small property publication在flag清除后的shape/property增长Nth-OOM仍保持A guard为false，retry/delete都不重新开启；这与失败的setPrototype不清flag分别锁定。
  A的missing/hole Set观察继承值/setter并退generic；已有own dense slot即使prototype
  同index有setter也只改own值，fresh CreateDataProperty不触发继承setter；delete guard不重新开启，custom prototype/Proxy不误入。
  0、`2^31-1`清flag，`2^31`、`2^32-2`与`"01"`不误清但其generic语义仍正确。Set/OP-put/push/splice、already-walked internal Set、DefineProperty与own-overwrite各锁对应QJS arm。pinned无fast branch的fill/growing-unshift及zjs range helper
  不读取standard flag；若保留full-chain product proof则独立测试/测量。runtime-wide bool与`is_prototype`传播为零，local
  `may_have_indexed_properties`仅剩own-summary/具名product reader；direct/control PMU从RealmContext稳定点独立归因；
- realm call carriers：C_FUNCTION own RealmRef、C_FUNCTION_DATA式captured callback沿caller；bound argv准备与Proxy trap lookup/arg-array/
  invariant检查仍在caller，随后才递归target或调用trap，不因FunctionRealm查询提前切换。最终bytecode/native direct arm的not-callable/
  stack-preflight error使用caller realm，frame建立后的constructor-cproto、sloppy-this、intrinsic eval与body error使用callee realm，return/abrupt恢复caller；newTarget
  prototype fallback、revoked Proxy、跨realm constructor及ArraySpecies foreign-intrinsic/active-intrinsic两次suppression均走唯一`FunctionRealm(caller,value)` resolver；
  C_FUNCTION/bytecode读owner，bound/proxy递归，C_FUNCTION_DATA/other class-call/default精确返回caller，
  但ordinary foreign species constructor不被抹掉，也不再读取borrowed fallback；从realm A逃逸到B调用的函数在函数体内
  直接调用自己的intrinsic `eval`时仍命中A的direct-eval identity、lexical/global与Error prototypes，替换eval后才退化普通call；
  C_FUNCTION在单一realm-aware constructor中直接取得final Function.prototype+RealmRef，C_FUNCTION_DATA取得prototype但不own realm；
  前置W1b2.5已使六个dstr helper恢复QJS iterator/copy-data opcode stack与abrupt-close协议，W1b2.6已使八个using helper成为typed product control；
  runtime `internal_destructuring_helpers[14]`、对应special-object+call、HostFunction record与destructuring state全frame扫描均为零。
  13个InternalCallableTag及Proxy/module/iterator captured helper均命中§1.8唯一class，representative own-descriptor/toString/callable/constructible
  surface与pinned qjs golden一致；`throw_type_error`是C_FUNCTION，Promise resolving/
  async-function resume为专用caller-class，其余captured helper为caller-data或命名product extension。`nativeFunction(rt)`后补realm/prototype、
  external/binding callback从A构造后在B调用仍收到指向稳定A RealmContext的typed borrowed view，销毁A的binding owner wrapper后escaped
  function仍可调用且underlying identity不变；`ExternalCall.ctx:anyopaque`、全部ExternalCall consumer cast、`run_test262.wrapExternal*`/
  EventLoop/`src/tests/exec.zig`/`src/core/string_view.zig`的core→binding cast及临时facade为零。raw FFI frame若保留opaque ABI字段，仅由
  documented borrow helper转成typed `ZigCall.ctx`，跨callback保存为负向；ExternalCall兼容`global`/internal globals view与typed ctx
  同属一个RealmContext且每次可观察call的global非null，pre-global bootstrap不走ExternalCall。A-callee/B-caller/A-loop三方矩阵不存在
  ctx/global撕裂，`global orelse functionRealm...`多权威fallback为零；
  binding method从该A context的class-prototype slot做现有exact brand，`MethodRuntime.prototype`/内部persistent handle为零，runtime external
  record仍存活时释放A base并GC可回收context/prototype；cross-realm与prototype mutation保持当前binding contract；
  caller-data在B调用则收到B。borrowed view跨callback保存、wrapper/temp-facade/host-handle pointer传入callback、“先造c_function再靠tag切caller语义”、
  realm-sensitive `setPrototype catch {}`与缺ownerfallback均负向为零；
- AUTOINIT domain/publish：所有producer先映射PROTOTYPE/MODULE_NS/PROP或eager；PROP只含C function/string/object builder，
  CGETSET/accessor、number/int/bool/atom/undefined常量与alias均非AUTOINIT。alias按安装顺序读取source并定义同一value，global
  parseInt/parseFloat、Array/TypedArray、Map/Set、String trim和Date identity保持；target/global/Array-prototype三种base与
  `Symbol.toPrimitive`/`Symbol.hasInstance`最终flags逐项锁定；`shared_lazy_native_functions/shared_native_cache_slot`
  及descriptor内`rt`/realm token/mutable cache为零；standard opaque直接为static entry/null/module pointer，`AutoInitRef{rt,id}`及runtime-ID lookup为零，
  dynamic host descriptor只来自明确stable owner。slot的typed `realm_and_id`在materialize、delete/redefine、owner destroy、clone/move和cycle mark
  均独立dup/free/mark；caller-realm shape prepare与stored-realm builder错误prototype分别锁定，builder不得重入/修改当前slot，
  每次read最多调用builder一次。成功slot owner释放且materialized C_FUNCTION独立retain；Nth-OOM本次抛错、placeholder+RealmRef完整保留，
  same-runtime下一次read只构造一次并成功。PROTOTYPE/PROP ordinary成功为normal value，accessor只能eager；MODULE_NS成功为namespace object或
  原export shared VarRef，global成功当场发布共享VARREF cell且descriptor/const/value
  identity与后续closure capture一致；shape/builder/VarRef三类失败均不半发布。optional/null吞错、“OOM致命”注释、双试、self-mutating builder与target ordinary
  realm代持负向为零；
- FB/job/finalization carriers：compile `RealmRef+policy`递归传入且每个FB发布前独立retain，first closure不写FB；
  FinalizationRegistry和每个runtime FIFO job own enqueue realm。creator facade/realm wrapper释放后native、lazy property、Promise/
  dynamic-import/finalization job仍在原realm执行；dynamic-import handler、attribute/error和Runtime loader都使用entry ctx，
  `DynamicImportState.load/DynamicImportHostState.load`不再忽略callback ctx或以state.context决定realm，scoped userdata在queue/
  continuation清空前不得释放；跨realm交错保持全局FIFO。parent-failure child-release、GC mark/free及enqueue OOM
  transaction全部锁定：generic失败不消费args/ref，Promise多reaction Nth-OOM不出现settled-but-missing-job/半清reaction；test tracker中reentrant `then`
  先于settle前旧reaction batch入队，handled通知也保持QJS phase，tracker记录OOM不回滚settlement；thenable不丢一次调用，
  dynamic import初始enqueue得到rejected promise或明确exception而非永久pending；promise已暴露后的loader/TLA completion OOM保留typed pending node并按原序恢复，resolve/reject也走prepare/commit；恢复后顺序/次数唯一。统一runner每次只执行一个job并返回empty/success/exception，异常保留Runtime exception且不消费后续FIFO；A失败/B随后
  的两次drain锁定entry args/result/ref cleanup和停止边界；队列已有B时A再enqueue C，A后保持B→C。公开`job.drain`以任意同Runtime ctx调用都不筛realm，
  `budget=0/1/N/null`分别锁定零执行、上限、drain-to-empty/首错，`jobs_drained/has_more`与统一FIFO真实状态一致。A-registry的cleanup job entry保持A，但其B-function callback body按最终carrier进入B，job前置与callback Error/global来源
  分别可见。reaction/thenable/dynamic-import job不再以JS function/external host callable表示，三个fake callable producer、
  InternalCallableTag和FunctionRealm/call reader均为零；
- host async completion：waitAsync node own construction RealmRef+Promise+shared-store key，global registry只借；A owner wrapper销毁后从
  foreign notifier唤醒仍只做waiting→ready+signal，runtime-thread job才在A settle并按与既有Promise/dynamic-import job冻结的顺序执行。
  finite timeout不依赖后续`.then`/Promise调用扫描；notify/timeout/cancel race恰有一个winner。enqueue/settle Nth-OOM保留同node与顺序，
  same-runtime recovery只settle一次；Runtime teardown cancel/drain后global/ready/FIFO无本runtime node。foreign-thread allocator/JS heap access、
  waiter裸Context、settle `catch {}`、失败后unlink/drop、double free/settle均负向为零；
- non-carrier realm absence：ordinary namespace/prototype、Array/arguments、RegExp、buffer/typed-array、collection/iterator、Promise、
  WeakRef/VarRef、generator instance、bound/proxy、module namespace及disposable实例均无generic realm owner；generator/async从saved
  current-function/FB恢复，AUTOINIT/materialized C_FUNCTION分别own，Promise/finalization/dynamic-import用enqueue RealmRef。
  `realm_global_ptr`20处声明/视图、两个平行value、`host_function_realm_global`、generic `objectRealmGlobal`和realm-destruction matcher
  负向为零；`__realm_` property/tag/copy/reflect helper为零，alternate/dynamic Function own keys不泄露内部realm且Proxy newTarget只观察
  `prototype`get。FunctionRare/Ordinary payload不再含primitive prototype、realm TypeError constructor或typed-array ArrayBuffer-prototype
  cache；Object boxing、RegExp getter、indirect eval和target-realm TypedArray backing buffer分别从active RealmContext取得正确state。
  weak-holder表仍只含真实WeakRef/weak collection/FinalizationRegistry cell职责，不能用删weak tests制造通过；
- direct execution：canonical root与child均由同一finalizer产生；VM直接读FB、attach不分配、heap cached view为零；cpool owned FB
  ref由closure attach消费，成功/每个失败点均恰好一次retain/release；cached view的module/global/mapped-arguments派生事实均回到
  canonical owner，leaf分类不是删除就是有最新A/B支持的compact documented extension；`forceRuntimeStrict`后置递归mutation为零，
  FB/view backtrace位及reader为零，若存在barrier能力只验证entry对caller frame的set/restore；
- terminator/artifact topology：empty/comment/last-expression/branch-to-end/try-finally/eval/module均以可见return结束，
  reachable falloff被finalizer拒绝，final/mutable code无`+1` sentinel；pc2line前两个ULEB128自描述起始line/column，
  full-debug buffer至少含两个header LEB且final FB/view不再另存平行坐标；ordinary compiler source allocation为
  `logical_len+1`且末字节NUL；
  core-close主allocation按header/optional debug metadata/cpool/vardefs/closures/exact code
  排列且整个base+FAM先按`js_mallocz`语义清零，W1d前非QJS事实仅能位于code后的optional extension；extension alignment/padding
  由唯一layout显式记录且extension为空时allocation恰止于code，source与pc2line仍是独立move-owned buffers；W1d exact-close后
  QJS-compatible function无extension；debug/no-debug与args/noargs组合的alignment/free/accounting正确；
  默认16B JSValue逐offset对齐pinned qjs，8B NaN-boxing用参数化cpool stride且通过altrepr/GC/OOM但不声称raw byte exact；
  `header align(16)`、`*align(16)` parent cast与dead `DirectCallSite`负向扫描均为零；
- direct eval：GLOBAL family不进 seed，MODULE/REF必须进 seed；同名 shadowed entries按 qjs次序全部保留并
  first-match且不借source depth排序；字符串/属性 atom不得触发 forward capture；catch、var-object force-init、leading conflict throw；
  ordinary descendant direct eval转发named-function binding时按QJS `add_eval_variables`把unscoped parent row归一为ordinary kind，
  最小复现必须得到pinned QuickJS的`false / false`，不得保留immutable-kind/strict-throw旁路；simple-catch同名`var`的declaration target、
  initializer解析和outer lexical冲突也逐项锁pinned QuickJS，不额外创建第二target；function declaration仍单独按QJS callsite矩阵验收；
- declaration scope topology：parser-time新scope继承visible `scope_first`，lexical row沿`scope_next`成链；catch严格为
  binding→wrapper→ordinary-body三层，switch cases共享一层，with/if/for/class声明父链与QJS callsite矩阵一致。lexical for-in/of只有一个
  head scope/VarDef，iterable后、body后与exit使用同一个`closeScopes` primitive，raw locals没有第二个`x`，per-iteration closure cell
  identity与QJS pass1/pass2一致；无for/catch scanner或专用close helper；
- declaration owner：function-scoped VAR在final rebuild前以`scope_next`记录声明scope并由`find_var_in_child_scope`消费；无
  `origin_scope`/parallel declaration graph。`defineVar`是全部ordinary declaration producer的唯一入口；raw locals锁`let a; var b`为`a,b`，再覆盖
  var-before/after lexical/function/class、destructuring var及same-name last-wins。outer assignment加nested block/arrow/async-arrow/
  class method中的`var`只让普通block var归outer，function boundary内var绝不泄漏；for lexical head与nested-arrow同名var合法；
  switch/catch/for/parameter/global/eval/module重定义由同一真实scope规则裁决。pattern `BlockScopeDecls`/switch scanner及
  implicit-arguments future-name scanner均为零；`predeclareFunctionBodyVars/DirectEvalReferenceScan/needs_dynamic_lvalue_refs`保持为零。later
  `function arguments(){}`由final scope lookup压过implicit arguments，production无future-name scan；
- lvalue/call provenance：phase-1 code/atom/source/label/provenance按一次fallible transaction commit，Nth-OOM不留下orphan atom/source或
  stale last-op；emitter last-op metadata是唯一事实，comma/normal-label/CFG边界有明确invalidate测试，optional chain则以一个共享
  LabelSlot/LabelRef及getter marker+相邻raw label保留唯一last-op，不存在per-`?.` exit vector；assignment/update/compound/logical
  assignment/typeof/delete/generic-for与simple `var` initializer在later direct eval、
  shadowed eval、nested eval与with下的phase-1/final bytecode逐项对照。ordinary call/optional-call/tagged-template只在call点改写
  field/index/super/scope getter，direct eval优先于with；`new`不继承method receiver。`peekParenthesizedBareIdent`、call/source-tail状态、
  fixed optional-exit buffer/signature scan、`scope_no_dynamic_env_flag/selected_reference`、ordinary `parseVar` unpatched-target make-ref、
  `result_needed/suppress_expr_statement_drop` reference分叉及ordinary expression的parser-time with transport为零；plain/logical assignment
  无伪source marker，compound/prefix/postfix、var `=`和call token各只有QJS anchor。atom retain与Nth-OOM逐项对照。generic for-in/of继续无replay，`(a).p`、`a["p"]`与parenthesized indexed均按QJS接受，
  computed function/class/arrow key各只建一个child/cpool entry，iterable仍先于每轮target求值，且无`value_loc` temp/`close_loc`；
  destructuring target的shape/replay负向出口归紧随其后的source-order阶段，private完整binding/lowering归W1d，不以半迁移计本项完成；
- parser control：return-comma全文扫描和parser内tail-call pushdown为零；return完整expression后才`emit_return`，QJS-aligned baseline
  不产tail-call。若存在tail-call extension，只能是显式启用、baseline默认关闭的post-parse CFG pass，有自己的语义/stack/OOM/A-B门禁且不参与QJS exact结论。调用正式`parse*`却只回滚
  lexer/code/atom的partial snapshot为零；保留lookahead逐个有QJS grammar锚点且不得append/capture。inner ordinary block string不设strict，
  empty ordinary block不增scope；block/program using全文预扫为零，只留下per-scope typed compile record；
- destructuring scan inventory：`collectParamPatternDupNames/collectArrowPatternBindingNamesSnapshot`名字预扫及
  `arrayLiteralPatternCandidateIsMemberTarget`/四个`arrayPatternContains*` shape scanner为零；array-literal member target中的
  function/class/arrow只生成一份child，而非当前四份；
- destructuring/internal control：parameter `{a=function x(){}}=function d(){}`的child/cpool严格为`x,d`；declaration和assignment
  `{a=function x(){}}=function y(){}`均严格为`x,y`，没有重复`x`，也不倒置成`y,x`。nested/default/rest/elision/computed-key/target、
  for-in/of与catch pattern同时锁phase-1 child/cpool/VarDef/source-position顺序及最终运行时求值顺序；pattern/RHS只各正式parse一次，
  对象target reference先于source property get/rest copy，数组target reference先于`for_of_next`，二者均在default前固定且不重复求值；
  `captureDestructuringVarBindingRef`、unpatched-target make-ref、`findGlobalRefPutTail` bounded scan、non-QJS temp local、destructuring state object、
  frame-wide abrupt-close scan、六个dstr helper及其`special_object + call`/Runtime root为零。
  block/program using全文预扫在M-PARSER-CONTROL-CLEANUP出口为零；八个`using` helper在独立W1b2.6出口为零，保留feature只经typed product control，
  不作为W1b2.5 ordinary/core closure的阻塞项；iterator return/throw precedence及Nth-OOM恢复通过；
- finally topology：一个finally源码无论有多少normal/throw/return/break/continue出口都只有一份body、一组child/cpool/atom，final code使用
  `gosub/ret`且size线性；覆盖无finally catch tail-call、有finally return value、nested finally、labelled control、for-of iterator close、
  catch/finally再throw、async/generator和eval completion。`tryStatementHasFinally/parseFinallyBlockFor*`及copy helpers为零；
- pseudo/prologue：分别锁diagnostic qjs的`_var_/_arg_var_ → this/new.target/... → arguments → function-name` VarDef append
  和`home→active→new.target→this→arguments→name→_var_/_arg_var_` prologue；special bindings不误挂scope链；参数默认值与
  body hoist/lexical init的final-bytecode顺序；root directive、block/concise arrow、普通/生成constructor都出现同一真实body event；
  captured block的normal/continue/break路径按QJS在exit发`close_loc`，return/throw不合成leave；escaping frame统一close，
  same-frame catch后的不可见ref留到frame close。entry不预刷新且
  `emitCloseCurrentScopeLexicals/localIsCaptured(child scan)`为零；production逐FunctionDef current→children且每个capture event只交付一次，无全树
  clear/rebuild或idempotent reconcile replay；`GlobalVar.cpool_idx`是top-level function hoist唯一carrier，恒skip的child补发字段/loop为零；
  sloppy Annex-B block function的raw locals为lexical binding先于outer var，两个`fclosure`各写正确target；block function
  每次scope entry只初始化一次，不再经body fallback重复构造；AUTO_INIT先物化再capture；
  无nested/eval capture的derived constructor `var_ref_count=0`，arrow/direct-eval分别只增加真实需要的cell；
  `linkDerivedConstructorThisLocal`及derived local↔`frame.this_value`双写为零，double-super/return/field行为保持；
  两个 root/eval closure对同一缺失 ordinary global共享 side-table cell；已有global-object VARREF再声明lexical时，旧cell
  变TDZ lexical、旧value移到新property cell，既有capture identity保持qjs一致；
- closure side channels：base/derived/default/user constructor分别覆盖public/private/computed field、private brand/method、
  initializer只执行一次且顺序正确、`super()`内外和arrow内的this/new.target/super；import.meta与nested function、private
  name shadow、arrow home/super均证明只由bytecode/capture取得；两个instance的private method/getter identity、`#x in obj`、
  wrong-brand TypeError与non-extensible pinned-QuickJS行为锁定“field独立private symbol + method/accessor每侧按需至多一个brand + lexical method”而非per-instance descriptor copy；删除finalization/FB/object/runtime side slots后
  补每个allocation/capture点OOM recovery；negative census允许`class_private_elements/class_private_bound_names`仅命中
  `Parser.State`及其grammar/direct-eval helper，禁止出现在FunctionDef/Bytecode/FB/Object/exec reader；instance initializer由lexical
  binding调用，static initializer由child以class receiver立即调用，`class_static_this`/synthetic atom/runtime vardef scan/eval高位均负向为零；
- module：同一specifier在两个RealmContext-owned registry中得到不同record/function/cell/namespace与error state，realm销毁只清
  自己list持有的base refs；ModuleRecord不额外own RealmRef且finalize/unlink恰好一次；
  record owner slot先持FB、成功创建后只持传递性拥有同一FB的function；object allocation/attach失败分别锁slot与refcount
  状态且禁止双retain；indirect export validation先于import wiring；imports全在 declarations前；local export固化 var index并在 link后 retain；
  MODULE_IMPORT slots在function创建后真实为null、indexed wiring后才seal，失败恢复null；normal import alias、
  namespace import own-cell、namespace-from fresh cell；namespace normal VARREF与 delayed AUTOINIT；anonymous
  default `set_name`、guarded prefix、function销毁后 live binding、cycle、TLA、cpool 255/256；同一SCC任意阶段失败后全部
  linking节点回到unlinked、partial slot/cell清空并可在修正依赖后重试；
- declaration/descriptor：local/arg last-wins，global duplicate全写第一 carrier；Annex B false/true block；
  configurable accessor→function、non-config data、global lexical flags、auto-init、non-extensible global；
- write authorization：local/arg/ref/global/module与function-name分别覆盖strict/sloppy、初始化写、后续写和direct-eval写；
  diagnostic qjs与zjs final bytecode均在非法写处出现`throw_error`/drop，plain put/set handler才获准退化为纯`set_value`；
- interrupt budget：handler开启后，单Machine backedge、同realm nested bytecode/native call和generator resume共享同一个持续counter，
  只在第10000个QJS-equivalent poll触发并重置；handler关闭/重开不因创建Machine偷换budget且handler为null时counter仍推进。
  跨realm call entry扣caller counter，切换后的body/backedge扣callee counter，两个realm互不串扰；
  poll point集合与counter lifetime分别snapshot，tail recursion stack overflow仍由独立stack budget裁决；
- ownership：root function/array allocation before pass1、pass1不造 cell、pass2第 N项失败、第一/第二fclosure失败、
  commit前Nth真实allocation/validation失败、commit后无fallible step且GC publication类型上no-fail；vardef/closure/code atoms、cpool values、func/filename/source/pc2line
  move后source slots清空且refcount恰好一次；当前full-debug production的所有必要name/source/debug信息保持不变，fixture no-debug
  只验证layout/free且不得生成新strip API；每个仍获准存在的pre-capture immutable-init点失败、abrupt eval/module后
  recovery、closure escape/GC。

closure 逃逸/close、generator suspend、module cycle、direct-eval abrupt completion、GC/OOM 只验证同一套
cell 与构造契约；不借本战役引入 pointer cache、第二套 cell layout 或 benchmark-local slot typing。

### 5.2 M-INTERRUPT-BUDGET — poll point之外的counter lifetime

QuickJS的`JS_INTERRUPT_COUNTER_INIT=10000`只是reset阈值常量；`JS_NewContextRaw`来自零填充分配且不另写counter，
所以新Context的第一次poll会从0进入slow arm、先重置为10000再读取handler，之后callback间隔才恰好为10000。关键机制是counter属于
`JSContext`：每次call entry先减caller context的counter，最终function arm切换后jump/backedge再减callee context的counter；
即使handler为null也不暂停counter。zjs已有大部分poll point，但`InterruptPoller`是VM-local、
阈值1024并会随Machine/call重建；这不是同一机制，也不能因默认benchmark未安装handler而忽略。

Recon/修复顺序：

1. 用可计数handler分别测单函数backedge、同realm nested bytecode/native calls、跨realm call、generator suspend/resume、两个realm
   交错，记录QJS第一次与连续callback间隔，并用cross-realm样例区分caller-entry poll与callee-body poll；regexp内部execution
   counter单列control，不把两种counter相加。
2. 在本机制中给第5步已建立的RealmContext增加counter并删除VM-local owner；Machine/Frame只借用active RealmContext。创建/销毁
   Machine、inline/tail frame reuse和handler临时为null均不得重置counter，Runtime只保存handler与opaque；不预先保留双写字段。
3. 保持现有call/jump poll位置，先用snapshot证明没有漏点/重复点，再替换budget owner；不得为对齐counter顺手改dispatch、
   tail-call stack guard或regexp matcher。
4. handler抛出的Interrupted错误按**被poll的context**构造：call entry是caller，body backedge是callee；随后进入现有
   exception/uncatchable协议。callback重入、关闭自身、realm销毁和counter wrap都有明确行为。
5. 这是correctness候选，收益记零；完成后重冻call/backedge controls，再开放M-RETURN-CONT。

W2-0收口行为：slow arm在调用Runtime callback前已把Realm counter重置为10000，因此callback重入同Realm时继续消费同一
已重置counter；callback在自身内部清除/替换Runtime handler只影响后续slow arm，当前已取出的callback/opaque调用完成。
counter的有效状态只有raw初始0与reset后的1..10000，每次到界立即重置，不存在有效执行路径上的整数wrap。counter随
RealmContext销毁，不由Runtime延寿；执行中的Realm由现有call/embedding owner保活，在callback内销毁active Realm属于既有
lifetime contract之外的无效用法。Interrupted持有被poll Realm的真实`InternalError("interrupted")`并标为Runtime
uncatchable；frame unwind跳过catch/finally与for-of IteratorClose扫描，直到embedding take/clear exception才清flag。

### 5.3 M-RETURN-CONT — 通用 post-call continuation transport

QuickJS 在 `JS_IteratorNext2` 中递归 `JS_Call`；callee 返回后，C 控制流直接继续读取 result。
zjs 不递归第二个 VM；普通 `.next` call/return 已在专用 handler 内完成 teardown/resume，不经过
通用 `op_post_call_continuation`。只有 `for_of_next`、Proxy 等需要 callee 返回后继续作业的
**非 `.next` action** 才发布 `return_action/payload`，经 `popAndResume` 和
`op_post_call_continuation` 回到 `finishForOfNextResult` 等消费者。因此这里只审计 post-call work
的 continuation transport，不把普通 call/return 或整体 dispatch 重新归因给它。

Recon 顺序：

1. 用普通 zero-arg method 证明 `.next` control 不进通用 continuation；再用 self-result iterator、
   constant-result iterator 和 bytecode Proxy `get` 分别隔离 post-work return 与 result-property work。
2. 逐项计数 action/payload publish、frame pop、resume pc/sp 恢复、post-call indirect dispatch、
   `done/value` lookup 与 ownership；`finishForOfNextResult` self% 不能全部算作 continuation。
3. 对照 qjs 的 receiver/method/argv 所有权、异常回到 caller 的位置、`sf->cur_pc`、result free 和
   done 时 iterator 清理；先确认现有语义相同，再找重复 transport。
4. 候选必须简化所有同类**非 `.next`** post-call action 的 continuation 表示，或把 continuation 直接并入既有
   return 协议；不得按 iterator result shape、固定 `next`、Proxy trap 名称或 benchmark 建分支。

生产修改受 §2 tail-chain stack budget与W2-0 interrupt counter lifetime共同阻塞。若剩余差异只是 resident Machine 的架构成本，记录为
“zjs architecture divergence”；只有真实编译器/ABI 证据才能进一步归为 Zig 限制。

W2-cont收口裁决（2026-07-24）：生产callsite census确认非`.next` action只有
`for_of_next`与`proxy_get`。前者以u8 depth为borrowed/moved iterator call携带返回后的
`done/value`作业，后者以owned Atom携带Proxy trap返回后的target descriptor invariant检查；
两者均经`popAndResume → op_post_call_continuation`消费，tail replacement则显式转移同一
continuation ownership。普通call/method/constructor/generator/async entry都初始化为
`.next + payload 0`，返回时直接恢复caller，不进入该cold handler。

QuickJS的对应状态由递归`JS_Call`上层的C locals保存：`JS_IteratorNext2`返回后继续读
`done/value`，`js_proxy_get`返回后继续验证descriptor invariant。resident Machine没有可借用的
C caller frame，因此当前tag+u32 payload是这两类post-call work的最小durable state；把tag塞进
payload会与完整32-bit Atom域冲突，改用heap/cold frame会引入allocation，function pointer则扩大
entry状态，均不形成符合本节约束的共同候选。裁决为**zjs architecture divergence**，不归因为
Zig限制，收益记零，生产代码不改。

ReleaseFast语义direct/control以同一脚本逐项对照qjs：self-result iterator为
`2000000 2000000`，constant-result iterator为`2000000 2000000`，zero-arg iterator为
`-1455759936 2000000`，普通zero-arg method为`10000000`，static/computed Proxy constant trap
均为`1000000`。现有exec回归继续锁定无备用operand capacity的Proxy continuation、
for-of result/abrupt顺序，以及computed Proxy nested call/throw/invariant。新增
`native tail calls preserve iterator and proxy continuation success and throws`直接迫使两类
continuation经driver `.returned`消费，并覆盖native tail-call成功与抛错。for-of的局部value释放
顺序与Proxy key临时root lifetime仍分别属于consumer ownership审计，不反向扩大本transport机制。
这里没有生产候选，不伪造PMU收益；W2 call/return与dispatch继续冻结。

### 5.4 M-PROPERTY-LOOKUP — named property shape/prototype walk

QuickJS 的 `OP_get_field/get_field2/get_length` 共用 `GET_FIELD_INLINE`：直接查当前 shape hash chain，
data hit dup，miss 沿 `shape->proto` 继续；property kind 或 exotic/primitive 才进入
`JS_GetPropertyInternal`。这一步发生在 `OP_call_method` 之前，且 reference 没有 site IC。

zjs 的 `qjsGetFieldFast/findOwnDataValueFast` 已镜像普通 data walk，因此本战役不是新增 property
fast path，而是核对当前链为何仍比 qjs 贵：

1. 建 ordinary object 的 own-data、prototype-data、true-miss、getter、primitive 和 exotic 六个
   direct/control，另用 Array.push/pop、regexp method、普通 bytecode method 作 consumers。global object 的
   `JS_PROP_VARREF`/zjs var-ref property 另建 probe，不混进 ordinary-data direct attribution；否则样本同时测了
   M-CELL 别名与 property lookup。
2. 对照 atom→bucket、hash-chain load、kind flags、prototype load、receiver dup/free 和 slow-path
   publication；把 callable 后续 dispatch 从样本和 profile 中扣除。
3. 单独审计 zjs 的 `needsSlowPropertyAccess`、private-atom probe、null-prototype class-global fallback
   与 qjs `p->is_exotic` 顺序。它们是表示/语义差异，不得笼统写成“IC 成本”。
4. 只有证明当前 qjs-style walk 仍承担 qjs 没有的通用工作才改生产代码。新 site IC 属 zjs 超集，
   不在本阶段提出；已有正确 IC 也只作为 control，不拿模块名替代实际调用链。

M-PROPERTY-LOOKUP收口裁决（2026-07-24）：final bytecode census与既有W1d递归回归确认
`get_field/get_field2`不携带private Atom，private field/method/accessor均已降为专用operandless
opcode。因此试做了只让这两个final handler跳过`mightBePrivate`的trusted-public候选；generic、
computed、internal与`get_length`入口仍保留原guard。候选通过exec 367/367与三方语义stdout，
并新增static true-miss与global VARREF固定probe。

ReleaseFast三方冻结件为baseline `a2499f4c` SHA
`8d26990fd07d00f2f51ba6de1c164ead6517626336d463a3c661db4b1ff89d65`、candidate SHA
`cec79a6e70aaf0ea7576a1ababcb8cabffb2c739e6c6c8d310cc29e450926547`与qjs SHA
`b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`。CPU19、
ASLR-off、显式big-core PMU、5次warmup、18个位置平衡block的paired median如下；true-miss有
16个完整有效block，另两个整block按协议剔除：

| direct | candidate/baseline cycles | candidate/baseline instructions | candidate/qjs cycles |
|---|---:|---:|---:|
| own data | 1.01695x | 0.98457x | 1.84145x |
| prototype data | 0.99333x | 0.98524x | 1.77618x |
| true miss | 0.99586x | 0.98813x | 2.22880x |

候选虽每次direct read稳定减少约3～4条指令，own-data的18个paired block却全部回退，
范围为+1.13%～+2.32%，中位+1.695%，明确越过§8的+1% cycles回退线。反汇编同时确认
`op_get_field2/op_get_field`各缩短32B且后者entry前移32B，但代码形态变化不能替代cycles
裁决，也不能用padding把失败包装成收益；生产候选已完整回退。结论是当前private-atom guard
仍属源码差异，却没有可保留的独立性能收益；ordinary lookup机制继续冻结，下一步只进入
M-NATIVE-CALL。

### 5.5 M-NATIVE-CALL — callable 到 native frame/cproto record

property lookup 完成后，QuickJS `OP_call_method → JS_CallInternal → js_call_c_function`：从 c-function
object 直接读取 realm、function union、cproto、magic，建立 `JSStackFrame`，保证至少 formal length
个 argv 可读，再按 cproto switch 调用。zjs 已把 `InternalRecord*` 缓存在 function object 上，但
table/HostCall/native-frame 的等价性仍需独立审计。

Recon 顺序：

1. direct probes 预先缓存 callable，分别覆盖 exact argc、missing argc、plain call、method call、
   两个不同 builtin domain；Array.push/pop 只作 consumer，不再把 lookup 算进 native call。
2. 分解 class/callable discrimination、record pointer、realm、argv padding、native stack guard、
   native frame/backtrace、cproto/tag dispatch、builtin body 和返回值所有权。
3. 核对 getter/setter、generic_magic、iterator_next、constructor、cross-realm、Function.call/apply 和
   异常 backtrace；其中 `iterator_next` 在 `JS_IteratorNext2` 可直接调用 function union、绕过常规
   `js_call_c_function`，必须单列为 control。缺失的 native frame 可观察语义先作为 correctness
   修复，不能用性能理由跳过。
4. 只删除所有 native domains 共同承担且 qjs 不承担的 transport。收益至少在两个 builtin domain
   复现；regexp Zoo 是 breadth/semantic consumer，不是 direct attribution probe。

M-NATIVE-CALL correctness 前置收口（2026-07-24）：对照 pinned QuickJS
`js_call_c_function`，确认 observable `C_FUNCTION` 必须先在 caller realm 以
`formal length × sizeof(JSValue)`做 native-stack preflight，成功后才切 function realm 并建立
native frame。zjs 此前的 resolved `InternalRecord` terminal 没有这层 preflight，External
HostCall 同时缺 native frame；String/Date/RegExp construct 的外层 coercion scope 也会让过晚
preflight 错误地带上 callee frame。现已把 guard 放到最终 C_FUNCTION 入口及 constructor
外层 scope 之前，`C_FUNCTION_DATA`与`func_obj == null`的 synthetic record reuse 保持 caller
semantics；External HostCall 的单一 native frame 覆盖 callback 及其 host-error materialization。
回归锁定递归 record 的 catchable `InternalError: stack overflow`与同 runtime 恢复、external
host native backtrace，以及 cross-realm overflow Error 属 caller prototype而 callback
`TypeError`属 callee prototype；changed-area exec 370/370 通过。该补丁只计 correctness、收益
记零；下一步仍只审计已解析 `NativeCallTarget{record, realm}` 的重复 transport，不把本修复包装
成性能候选。

M-NATIVE-CALL transport 候选收口（2026-07-24）：唯一候选删除
`NativeCallEnvironment/FinalCallEnvironment/NativeCall`重复保存的`callable_realm`，让 observable
call 从同一 final-arm 已有的`ctx/global/func_obj`导出 callable view；ordinary/cross-realm、
`C_FUNCTION_DATA`、constructor、synthetic record reuse 与 nested native call 的语义审计及
定向 exec/builtins 回归均通过。CPU19、ASLR-off、显式 big-core PMU、六种平衡顺序×3轮的
18-block 三方测量中，Object.is plain/method 与 Math.abs plain/method 的 exact/missing-argc
探针稳定减少每次约6/4与4/2条指令；首个候选布局的 direct cycles 中位从
Object.is plain exact 的-1.689%到 Math.abs plain exact 的+0.393%不等。冻结 baseline
SHA256=`80ce7c9495c8ca53669a605f1223fc3aa4cd4330e166fcffba863ebd472a7a39`，
`.text`为3,780,812B /
`bcba789ff3a4acb7a23b67925f6d0adbf8c69023b6d50496ff9f7cb32a3134a5`；首个 candidate
SHA256=`6bc8ae46385f6f312cfd68c1c923ec393bdb28a357b13055c95559b127f04cfc`，
`.text`为3,778,164B /
`a9833b679efff06c7cd28d05d034c56d6336535c1ec3fb98e99cdf9e08b8b6fd`。

按§8对小于1%的形状做空cache/独立prefix重建后，candidate
SHA256=`3886fce7b12926e57f10b840f158e87ce21210653d0b2f88aa9d2d4017330c0d`，
`.text`为3,780,596B /
`baa47a765f1f2f061c0bf9932a5e183040a1efc573a3c839584f87ce740abbac`。同一18-block协议仍精确得到
Object.is plain/Math.abs plain/Math.abs method 每次-6.005/-4.000/-1.997条指令，direct cycles
分别-1.229%/-0.748%/-0.053%；但与native transport无关的property-read和allocation controls
分别回退+1.477%和+1.660%，均越过+1%否决线，且property control相对首个布局的-3.211%发生
方向翻转。这是未解释的code-layout回退，不能用padding或挑选首个artifact掩盖；生产候选已完整
回退，九个固定direct/control探针与否决结论保留。结论是重复view确有静态transport成本，但
当前变换没有可保留的独立cycles收益，W3-native至此冻结。

在 direct storage 探针证明前，不改 Array capacity/count 算法；不得把 push/pop 名称或 builtin id
本身当成新的生产分支依据。

## 6. 第二阶段：对象生命周期与属性发布

### 6.1 M-ALLOC-LIFECYCLE — create/free/accounting

前置已经收口：`f221dfee` 修复 open VarRef 对 parked generator backing 的 owner 边，停止把
borrowed `pvalue` 当作 owned edge 追踪造成的 trial-RC double count；`2ecbf301`、`951726e1`、
`1f67bdbc` 分别把 preserved WeakMap、deep weak chain 和 job-queue symbol root 的精确
liveness 断言扩到 force-GC，`ad3218dd` 把 exhausted-heap OOM delivery 的零分配断言也扩到
force-GC。`src/tests/core.zig` 剩余的 force 条件只区分 synthetic collection 对 pending request、
major count、timing 与 threshold 的 instrumentation 语义，不是 weak/liveness skip。该证据允许
allocation/ownership 候选进入独立测量，但不等于阶段收口；W4 结束时仍须执行统一 force-GC
与相关 OOM/`test-oom` 门禁。

QuickJS 空对象链是 `OP_object → JS_NewObject → JS_NewObjectProtoClass →
JS_NewObjectFromShape`：先找/retain empty prototype shape，再 `js_trigger_gc`，分配 `JSObject` 和
`shape->prop_size` 个 `JSProperty`，初始化 rc/list；释放则是 inline rc-- → `__JS_FreeValueRT` queue
→ outermost `free_zero_refcount` → `free_object`。当前 zjs 已镜像 RC queue，但空对象 lazy-skip
property array，且初始 shape capacity 为 4（qjs `JS_PROP_INITIAL_SIZE` 为 2）。这是事件数不同的
既有优化，不能为了“忠实”恢复一次无收益分配。

两个历史 allocation 差异在当前代码已经 **CLOSED**，不得重列为未来刀：

- `SpaceAccount.recordAlloc/recordFree` 热路现在只更新 `live_bytes`，committed/free page geometry
  已改为 `refreshPageState` 在 stats/debug verify 时惰性派生；
- `Object.createInternal` 现在用 `recordPtr(class_id)` 的 `class_record` 指针视图，不再把整个
  class Record 按值复制到热栈。

第二项只关闭“88B按值复制”的性能候选，不证明pointer lifetime正确。当前pointer取得早于
`collectBeforeObjectAllocation`且跨后续fallible allocation继续读取，必须先由W1b3a的
M-CLASS-RECORD-LIFETIME改成最小scalar plan + publication前按id重取/校验；不得用现有
“table static once registered”注释跳过dynamic registration realloc、plugin unregister或finalizer reentry。

历史文档可以用来说明这两项为何曾经昂贵，不能用来证明它们在当前 HEAD 仍存活。
这只封闭“per-allocation page geometry”和“整个 class Record 按值复制”两把旧刀；如果当前 profile
另外证明 pointer view 的必需标量读、allocator limit 或其他记账在关键链上，必须以新的
QuickJS 对照事实单独立项，不从已关闭收益外推。

Recon 顺序：

1. 用当前同一 `allocation-empty-object-2m.js` 跨 07-08 候选提交复现 0.96x；无法复现就删除
   “回归”叙事，从当前 1.149x 残差重新开始；
2. 将 root-shape lookup/retain、object alloc、property-storage alloc、GC trigger/list link、
   MemoryAccount、zero-ref enqueue/drain、property/shape release 和 raw free 分开计数；
3. 对照 qjs `JSMallocState`/`js_malloc` 记账、`JS_NewObjectFromShape` 和 `free_object` 的关键链；
   比较“同一语义工作是否重复”，不要求两侧 malloc 次数相同；
4. 先验证已对齐的 zero-ref queue 没有额外 per-object policy，再依次裁决 construct、accounting、
   destroy、allocator geometry；一次只动一个子机制。

必须保留公开 `gcStats()`、live=0、OOM 恢复、weak/finalizer、deferred cleanup 和 GC pacing
契约。若要把累计统计移出热路，必须先决定兼容实现，不能静默降低公共统计语义。

### 6.2 M-SHAPE-PUBLISH — 扣除 allocation 后的 shape/property 残差

旧计划的 `rc==1` 主刀已完成，不再重做；但源码复核确认三臂的 cache-hit 资格仍不完全相同：
qjs `find_hashed_shape_prop` 只比较 hash/proto/property sequence，不比较 `prop_size`，命中后若
容量不同就 realloc 对象 property array；zjs `findHashedShapeProperty` 当前要求 candidate
`prop_size == property_capacity`。新 recon 以 `{}` 为 lifecycle control，以 `{value}`、
let/var/pinned 和不同预留容量对象为 property-publish 差分：

1. 先记录 cache/shared/unique 三臂的命中分布，并用同 property sequence、不同 initial capacity
   直接验证 capacity 是否造成 qjs-hit/zjs-miss；不再以“三臂函数存在”代替机制等价；
2. 分解 root shape lookup、transition lookup、object property-buffer reconciliation、transition
   hash、FAM relocation、atom retain、property publication 和 destroy；
3. 第一个生产候选只能对齐 cache-hit eligibility + OOM-safe storage reconciliation；后续才分别
   研究 hash lookup 或 FAM relocation，不能一刀合并；
4. pin probe 只用于区别 shared shape 与 churn，不把 pin 本身当生产假设；
5. qjs object literal 仍是 `OP_object + OP_define_field/add_property`，没有普通 literal template。
   因此候选必须适用于普通 property addition，不得新增 object-literal-only template。

RegExp result、iterator result、arguments 等对象只能作为同机制消费者；如果它们使用预制
shape/template，则不得用其收益证明普通 shape publish 已改善。

## 7. 第三阶段：发码与帧协议

### 7.1 M-EMIT — 只做当前仍缺的 QuickJS 规则

先从当前 QuickJS `resolve_variables/resolve_labels` 和当前 zjs pipeline 自动或人工生成一份
规则映射：`qjs producer/phase → phase-1 input → final-bytecode rule → ownership/source/OOM → tests → status`。
最终bytecode相同只是必要条件，不足以证明机制等价：pass位置若会改变parser provenance、child/cpool/VarDef
构造顺序、atom retain、source位置、OOM点或某条opcode能否被后续通用规则消费，就必须忠实回到QuickJS的phase，
除非先记录可复核的Zig/LLVM限制与等价证明。只有上述事件全部相同、位置纯属内部组织差异时，才允许zjs在
parser提前发short form而不机械搬代码；`get_length`提前发射和parser tail-call rewrite不能再仅凭final bytes获得豁免，
必须先过各自producer/consumer审计。

本次静态源码复核得到的初始清单如下；“待 diff”不是已确认缺失，必须先由 diagnostic qjs 的
final bytecode 与 zjs snapshot 证明：

| QJS rule family | 当前 zjs 状态 | 动作 |
|---|---|---|
| binding resolution 与 hoist construction：single parse、scope/arg/function-name/eval-object/with/closure/global优先级，以及final vardef、root function、capture index、cell/value创建阶段 | candidate已恢复bytecode function-value producer并对齐row schema/closure identity/pseudo staging、args→locals lookup、eval链头、8B/12B row和guarded module prefix；仍缺单遍declaration/lvalue、destructuring source-order/internal stack、single-body finally、完整scope event/exit cell close、derived-this真实capture、唯一finalizer/body anchor与Annex-B producer，以及RealmRef/carriers/terminator/root/direct-FB/closure2/pc2line/move/pack/module | 当前compiler缺口严格归W1b2.5，product-only using transport归W1b2.6；随后才进入M-REALM-STATE-REF至M-FB-PACK-CORE，最后由W1d exact-close/W1e补齐class/module producer。不是peephole，不进行“只缩短序列”的PMU归因 |
| pipeline order、short loc/arg/var-ref、const8/fclosure8 | 普通 pipeline/encoding 已有，`fclosure` 255/256 producer/consumer 已由 `936111c5` 修复 | P0 封账；其他 short family 只补矩阵证据，不重做 |
| tail call、`get_field(length)`、empty string short form | zjs多在parser提前输出，但三者不能因“最终更短”合并裁决：pinned QJS parser没有tail-call pushdown；`get_length`又会改变last-op/delete/call consumer，empty-string才可能只是纯表示 | tail-call producer在M-PARSER-CONTROL-CLEANUP删除；未来product tail-call只能是baseline默认关闭的后置CFG pass。`get_length`先做producer/consumer/source/OOM审计，不能只比final bytes；empty-string确认不改变任何phase事件后才允许保留等价pass位置 |
| logical chain、null/undefined/typeof、constant branch、push-neg、dup-put/set、return-undef、dead code、inc/add-loc | 已有 matcher 或独立 fuse | 逐条钉 snapshot 后封账；不能再用旧的粗粒度族数代替 coverage |
| `insert3 + put_array_el/put_ref_value + drop` | 待 final-bytecode diff | 若 zjs 最终仍保留该序列，一条规则一刀 |
| redundant `to_propkey` before simple producer + `put_array_el` | 待 final-bytecode diff | 先覆盖 symbol/object coercion 反例，再裁决 |
| `insert2 + put_field + drop` | 待 final-bytecode diff | 先证明 stack effect/atom ownership，再裁决 |
| post-inc/dec store rewrites（loc/arg/var-ref/field/array） | loc 已有部分 fuse，其余待 diff | 按 destination family 分刀，不合批 |
| `put_x(n); get_x(n) → set_x(n)` 与 bigint-i32 neg | 待 coverage/diff | 只有最终差异且有可达脚本才进入 PMU |

执行纪律：

- binding resolution/hoist construction 与 peephole 分账：前者决定 cell 和函数值的创建阶段、
  属性别名及哪些 runtime opcode 可达，必须先于 M-CELL baseline；后者才只在同一语义动作上
  缩短最终序列；
- 一条独立 qjs rule 一个候选和一组 bytecode snapshot；
- 先证明最终 bytecode 差异，再测执行性能；没有 bytecode 差异就不进入 PMU；
- atom ownership、jump target、finally/rethrow、generator、eval/with、TDZ 和 dead-code
  可达性先有红灯；
- 全量 test262 delta-zero 后才保留发码刀。

`inc_loc_check` 是 qjs 没有的 zjs 超集 opcode，继续暂停。只有证明 Zig 当前 checked-local
表示无法获得 qjs 同等 lowering，且现有 qjs 规则已全部对齐，才单独裁决。

### 7.2 M-FRAME-CONT — 最后才重开通用帧战役

调用战役已把主形态压到 0.98–1.16x，并积累大量反证：共享 source/setup、scalar transport、
descriptor/interface 包装、额外长期活跃参数、raw resume、target 字段删除等都曾因寄存器压力、
`.text`、L1I 或其他形态 cycles 回退而撤销。

因此：

- 不执行旧计划的“八臂收敛为描述符单构造器”；性能中性只证明它可能是架构重构，不能占用
  性能战役；
- 先修 tail-call reuse 的等价 stack budget，再重新 profile fib/closure/borrowed continuation；
  qjs 的 native-SP guard 与 interrupt counter 是两个机制，zjs 不得用一个廉价计数器冒充两者；
- 只有同一个 qjs 对齐缺口在至少两个 frame shape 的关键链上出现，才重开生产候选；
- resident Machine、Entry slab 和 frame reuse 仍要按各自契约审计；但 tailcall dispatch 本身已由
  单体 dispatcher 3,504B spill 二分、224-arm A/B 和 next-dispatch 指令数封账，不得从 frame
  战役侧面重开。`preserve_none` 是明确工具链缺口，但不是当前结论的唯一证据；
- 架构可维护性重构另立工作项，不把“代码更少”记成性能收益。

当前裁决（2026-07-24）：`a11f99d3`已完成tail stack等价修复，`a2499f4c`已关闭
continuation审计；但现有W3 property/native数据不覆盖frame关键链，也没有冻结binary hash的
post-W2 fib/closure/borrowed-continuation profile证明至少两个frame shape共享同一新热点。
重开条件未满足，M-FRAME-CONT关闭、收益记零；只有补齐上述frozen profile后才可重新裁决。

## 8. 候选判定与止损协议

候选只有同时满足以下五项才保留：

1. **语义正确**：QuickJS 可观察顺序、异常、realm、Proxy/accessor、所有权和 OOM 不变。
2. **机制忠实**：有明确 qjs 锚点；若偏离，Zig 限制与等价证明完整。
3. **直接收益**：direct probe 的 paired median 改善超过该探针噪声；只有“方向同向”不算。
4. **受益面成立**：广域机制在至少两个真实消费者上复现；窄而忠实的机制允许一个直接
   消费者，但必须说明服务面为何天然狭窄。
5. **零未解释回退**：control 或无关热形态的 cycles 回退必须解释并复核；不能因 instructions
   未增就标为布局幻影。

回退规则：

- paired median cycles > +1.0% 先按真实回退处理，不与 instructions 条件做 `AND`；
- `|cycles| <= 1.0%` 的结果不宣称收益，除非独立重建、更多轮次和关键链证据一致；
- instructions、branch、L1I、stall 用于解释 cycles，不替代 cycles；
- 如果独立重建显示布局吸引子，允许通过通用 handler-cluster/layout 策略解决；禁止 padding、
  空逻辑或 benchmark-specific alignment 粉饰单个结果；
- 同一 qjs 对齐假设连续两个干净候选都失败，就停止该方向，写清反汇编死因；除非出现新的
  源码事实或工具链能力，不换名重试。

QJS ratio 用于确认差距是否收敛；baseline zjs → candidate zjs 才是因果 A/B。反超 qjs 时仍要
核对双方是否执行同一语义，但不为了 ratio=1 主动退化正确且通用的 zjs 机制。

## 9. 验证档位

每把刀按最小充分证据推进：

1. **迭代档**：ReleaseFast 编译、direct/control stdout、反汇编、最窄 changed-area 测试、
   `quick-check`。
2. **保留档**：对应 subsystem 测试、语义 slice、`checkpoint-check`、三方 PMU 包、
   `perf-self-check`；广域机制补 Zoo deterministic 检查。
3. **阶段收口**：
   - parser/exec/可观察语义改动：完整 `test262-gate`；
   - value representation：`test-altrepr`，并按项目规则跑 nan-boxing test262；
   - allocation/GC/ownership：阶段关闭时统一执行 force-GC、相关 OOM 与 `test-oom`；迭代期
     已恢复的 focused liveness 门禁不能替代该统一出口；
   - final pre-commit：唯一一次 ReleaseSafe 全套；
   - `git diff --check`、干净工作树、无临时 profile/log。

不要每个小改动都跑全套；也不要用测试成本为理由跳过变更面必需的门禁。测试、exclude、
known-error、benchmark iteration 和 stdout oracle 均不得为候选让路。

## 10. 执行顺序与交付物

| 阶段 | 工作 | 出口 |
|---|---|---|
| M0 | 维持可追溯 performance/diagnostic qjs；按**当前机制**逐个做 source/final-bytecode recon | 当前候选的 qjs/zjs 差异、direct/control、收益上限齐全；不等待 P1–P7 全部完成，也不把早期 PMU 当最终 baseline |
| W1a（当前候选冻结面） | no-cheating entry cleanup → closure row schema/type+source identity规则 → 显式EntryContract → 删除零reader `DirectCallSite` | 保持lookup语义、row表示与identity测试；具体VarDef/closure/open-binding index不冻结。body/semantic prescan、finally复制、scope event/close、derived-this伪capture、全树hint replay、Annex-B与body hoist全部交W1b2.5；`get_var(arguments)` adapter只允许证伪/退场；correctness变化均不计性能 |
| W1b1-semantic（候选完成，correctness） | args+locals单表 → eval operand改vardef链头/ARG_SCOPE_END → dynamic env按自身eval capture/实际lookup跨越两路生产且table-order消费 → 删除final scope graph/parameter高位 → compile/final closure去depth → combined eval传播范围 | 96/373/281/160及quick-check 3/3保持绿；只冻结语义表，收益记零。static class-field `0x8000`明确转交W1d，不虚报物理或全量同构 |
| W1b2（**已完成，表示候选**） | VarKind恢复QJS 0..10、临时class kind移到11 → closure compile/final共享8B storage → vardef 12B storage/accessor → uncaptured row zero → masked raw bytes/size/alignment/offset锁定 | focused gates通过；Zoo paired median -1.10%低于裁决线，性能收益记零。后续只复用表示，不重开wire/packed/layout或继承噪声 |
| W1b2.5（correctness，当前阶段） | 已完成body pre-scan删除、block/body语法边界、generic-for普通LHS单遍、M-DECL-SCOPE-TOPOLOGY、M-BODY-SCOPE-IDENTITY、M-DEFINE-VAR-CORE/simple producer与M-LVALUE-PROVENANCE-CORE（后者已随`fde49b15`合入，private已恢复baseline transport，结论严格限ordinary reference/call surface）。M-PARSER-CONTROL-CLEANUP的tail-call/return单遍清理已合入main（`6e83f394`，忠实对齐、全绿：tail-call pushdown/return-comma-rescan/droppable-rethrow删除，深递归改抛catchable InternalError，test262 tail-call-optimization=skip）；其using单遍部分因与runtime disposal transport耦合（两次返工均栽在per-exit sync/async异常传播——early-exit须sync处置并同步传异常，而非promote-to-async）改与W1b2.6 runtime typed transport一起做，不在PCC阶段单独完成。✅**W1b2.5/2.6 core全链已合main全绿**（2026-07-22）：M-DSTR-QJS-TRAVERSAL(`a08ac398`)→M-FINALLY-SINGLE-BODY(`90982b18`)→M-SCOPE-EVENT-PRODUCERS(`1d0704ac`)→M-DERIVED-THIS-CANONICAL(`82d70a47`)→finalize checkpoint三合一 M-FINALIZER-PRECHILD+M-BODY-HOIST-ANCHOR+M-SCOPE-CLOSE-LOWERING(`7e604a85`)→M-USING-TYPED-CONTROL(`131a396e`，W1b2.6 typed disposal transport)。test262 **0/49775全绿，passed 44537→44542(+5)，known 29→24**；load-bearing early-break await-using sync案例已修（typed disposal走handleCatchableRuntimeError同步、8条special_object host-call链退役）。**W1 core闭合，解锁性能门**。残余：#7 return-endpoint统一（收益零、跟踪中，emitReturnValue非唯一终点+生成默认derived-ctor在State-bound emitter外）、W1d(private完整slot/brand/class-fields aggregator/static-block wrapper)、W1e(module local-export index)。下一步 → Realm/FB规范化（首个性能门） | row schema/identity/record bytes保持；parser scope/`defineVar`/last-op分别成为scope、declaration、reference/call唯一owner，source semantic scan、parser tail-call pushdown、per-exit optional状态、selected-reference与bounded reference-tail scan为零；ordinary/Annex-B/destructuring raw vardef与child/cpool、finally code、scope-exit、parameter/body final bytecode及derived capture index逐项同构；parent/child/sibling、loop cell identity与Nth-OOM正确。只可声明ordinary/core compiler construction close；private完整slot/brand/lowering、class-fields aggregator/static-block wrapper与提前`<class_fields_init>` row归W1d，module local-export index归W1e，using/TS namespace不在QJS-core结论内。W1b2.5完成前不得进入Realm/FB/pack，总体PMU重冻仍等待W1b2.6 |
| W1b2.6（product correctness，独立） | M-USING-TYPED-CONTROL现同时承接从PCC移入的using parser单遍（block/program全文预扫→per-scope typed record/anchor；PCC两次返工证实它与runtime disposal transport耦合、不能先于本步单独做）→ 八个using `special_object + call` helper改typed opcode/continuation，使per-exit sync/async处置能正确同步/异步传播disposer异常 → 删除剩余internal-helper cache/trace/free | sync/async using的structured unwind、suppressed-error precedence与Nth-OOM通过；无QJS exact声明、收益记零。不得拖住W1b2.5 ordinary/core finalizer，但必须在总体性能重冻与W1b3b callable inventory前完成 |
| W1b3a（correctness，**中间态不可独立合入**） | 先把global判定从RealmPayload拆为显式class/flag并字段级split global payload → 拆分cycle-GC/refcount RealmContext、append GC kind并补全collector switch/typed child traversal，按GC-header `.constructing`/context-list `.live`两阶段发布并另建non-owning runtime context list → 冻结owner-runtime-thread或具名Runtime mutation lock二选一契约，覆盖Context/class/plugin/GC/list mutation → pointer-sized move-only public owner与typed callback view → `$262.createRealm`创建真实context/harness base owner → global/eval/intrinsic+custom class prototypes/random迁RealmContext，并把五个QJS initial shape改为direct Shape owner、删除layout-only template Object；先拆caller-owned stable class-ID namespace/per-Runtime definition/per-Realm slot，再让capacity覆盖所有live/future realm、限制record pointer为no-reentry view且definition publish/prototype consume分步，plugin HostClass只留Runtime metadata，公开Native Binding改live ctx-slot borrow+显式OwnedBinding，per-realm OOM预制对象只登记为zjs safety adaptation → EventLoop改命名host RealmRef owner并删wrapper cast，RootProvider只留diagnostic/host-owned external edge → waitAsync node裸ctx改RealmRef → public `realm_global`只扫描context list → exception/stack归Runtime或stack-local → runtime teardown验证全部context/value handles；interrupt留给W2-0整机制落地 | 本阶段只验RealmContext自身及已迁入edge：alternate state/identity、global payload、base/external RealmRef、legacy adapter、wrapper回收与destroy precondition；`.realm_context`全collector switch、construction Nth-OOM、双link、direct initial shapes/props move transaction、class slot/capacity/record lifetime/plugin metadata/Binding/EventLoop/waitAsync owner及Runtime mutation contract通过。不得声称native/FB/AUTOINIT/job/finalization cycle已闭合，也不得为中间绿灯增加temporary generic owner；这些生产escape carrier分别由W1b3b/c/d1/d2/d3关闭后才做联合cycle/teardown结论。shared alias cache只作临时debt，收益记零 |
| W1b3a-plugin-unload（zjs extension correctness；生产出口依赖W1b3b typed callback） | InstalledPlugin不持prototype/RealmRef → 每次DSO callback持temporary execution pin，last-owner只标pending → deferred native/class-payload callback node持installation/definition pin → zero-live-owner/zero-active/zero-queued证明binding record/opaque payload为零 → context-list按本installation IDs take-null全部live slots → unregister Runtime definition → 最后close DSO；RealmContext teardown复用同一slot take | plugin-first、realm-first、callback内self-remove/last-release、teardown中last-binding reentry、finalizer/tracer reentry、queued-finalizer-after-last-live-owner、仅opaque-wrapper存活及多class rollback矩阵通过；callback返回前及queued callback存在时绝不close，slot/record/node/lib各清一次，close后无descriptor callback，且opaque creation已用W1b3b callback RealmContext slot；收益记零且不宣称QJS机制 |
| W1b3a-array-guard（correctness后独立A/B） | 先逐reader区分own overwrite/CreateDataProperty/logical-end Set/already-walked Set/hole与zjs-only fill-unshift-bulk → 以stable context list实现per-realm `is_std_array_prototype` publication/invalidation → 仅QJS `can_extend_fast_array`对应reader改direct guard → 退掉runtime-wide sticky/`is_prototype`传播；product full-chain proof隔离 | A/B跨realm污染、Array/Object prototype新增属性及其publication Nth-OOM、setPrototype同值/失败/成功、dense conversion/delete/custom/Proxy、own-vs-hole setter、Set-vs-Define、push/splice及fill/unshift隔离矩阵通过；从W1b3a二进制独立测append/push与generic controls，未过裁决线仍保留correctness但不宣称收益，zjs-only fast path收益不并入 |
| W1b3b（correctness） | 以前置W1b2.5已删除六个dstr、W1b2.6已删除八个using伪callable为负向门禁 → §1.8全callable inventory映射C_FUNCTION/caller-data/专用class/job-only并冻结每类object-surface golden → 删除零reader`prepared_call_ok`及过期gate注释 → realm-aware constructor直接装final prototype、eager normal name/length且只有C_FUNCTION own RealmRef → callback ABI按callee/caller原子传稳定RealmContext+同realm global/slots，`ExternalCall.ctx`/typed FFI borrow不再经owner-wrapper cast，binding method/plugin HostServices/public Binding都从对应live RealmContext class_proto查prototype并删平行authority → bootstrap先Object.prototype再Function.prototype → 删除后补realm/prototype/lazy-name与silent catch → FunctionRealm限定四类consumer → wrapper caller/final-arm phase切换 | `internal_destructuring_helpers[14]`、对应special-object+call/record/state-scan继续为零且不在本阶段重构；13个InternalCallableTag、Proxy/module/iterator captured helper与product extension各有唯一class；MethodRuntime无JSValueHandle、InstalledPlugin无prototype JSValue、Binding无raw prototype且runtime存活时alternate realm可独立回收；own descriptors/toString/callable/constructible、跨realm/handle-destroy后的callback ctx/global identity、realm-local binding/plugin class prototype contract、Promise self-resolution caller error、async resume FB realm及其余data-callback controls、constructor/bootstrap OOM、bound/Proxy/newTarget、foreign/active intrinsic与ordinary species、return逐阶段对齐。全部ExternalCall consumer cast与多权威global fallback为零；raw FFI opaque字段若保留，只能call-duration borrow且`ZigCall.ctx` typed。“c_function+tag切caller”与`prepared_call_ok` reader/writer/comment在function/data-class producer为零；job-only三项显式交W1b3d2并阻塞联合封口，收益记零 |
| W1b3c（correctness） | production `CompileContext{realm,policy}`递归进入finalizer → 每个child/root FB独立retain → runtime-strict发布前唯一写入 → 删除first-closure/后置tree mutation | parent failure/child release、escaped closure、GC/accounting/OOM通过；production null realm与`bindBytecodeFunctionRealmGlobal` reader/producer均为零，收益记零 |
| W1b3d1（correctness） | 现役AutoInit producer映射三种QJS ID或eager → CGETSET/常量/alias安装期发布并删shared cache → slot改typed `realm_and_id` owner+direct stable opaque → builder/error fallible、单次且不自改slot → PROP/PROTOTYPE发布normal、MODULE_NS typed result contract允许namespace或原VarRef、global发布VARREF并让C_FUNCTION独立retain → failure保留placeholder但向当前read抛错 | alias/accessor/constant descriptor与identity、caller shape/VarRef prepare、stored-realm builder错误prototype、fixture module-result/global cell identity、materialize/delete/redefine/destroy/clone-move/cycle-mark owner转换、Nth-OOM同runtime retry通过；过宽AutoInitKind producer、`AutoInitRef{rt,id}`/runtime-ID lookup、descriptor rt/realm/cache、optional吞错、同read双试、self-mutating builder、target-object代持均为零。当前data-snapshot module producer仍明确未对齐并由W1e接入，收益记零 |
| W1b3d2（correctness） | Promise/dynamic-import/generic ECMAScript job统一runtime FIFO entry+enqueue RealmRef+typed payload → producer按promise暴露前/后各自reserve/commit/pending-retry，并保留state→tracker→reaction的QJS可重入phase，禁止复制ignored-enqueue OOM或把事务合并过头 → 删除ECMAScript `runAll`并建立run-one empty/success/exception transaction → 公开`job.drain`按`0/1/N/null`精确循环并报告count/has_more、ctx只选Runtime不筛realm → dynamic-import沿entry ctx并删除state realm authority → waitAsync foreign notify/timeout改no-alloc host completion并由owner runtime按node RealmRef入FIFO → 删除fake function、裸Context及平行queue | generic/Promise/thenable/import Nth-OOM无owner消费、半settle、丢job或永久pending；tracker reentrant-then先于旧batch且handled通知phase一致，host-report OOM不回滚promise；初始import可reject/throw，已暴露promise的loader/TLA completion由typed node按序重试，resolve/reject不暗中丢reaction；creator facade销毁后仍以enqueue realm运行；A异常/B后继需两次drain，首错保留Runtime exception且B顺序不动，A enqueue C时剩余B→C，entry cleanup恰好一次且无dangling ctx；budget/count/has_more矩阵通过；DynamicImport不忽略ctx，scoped userdata仅在queue/continuation清空后释放；waitAsync foreign path不碰allocator/JS heap，race single winner，OOM按序重试，teardown无本runtime edge；跨realmFIFO/host adapter明确；三个job-only function producer/tag/payload、waiter裸ctx与settle `catch {}`为零，收益记零 |
| W1b3d3（correctness） | FinalizationRegistry own construction RealmRef → GC cleanup接入d2 FIFO → no-drop enqueue OOM恢复；weak cells仍走真实weak-edge registry | cleanup使用construction realm且不重排/重复；registry/context cycle、GC mark/free、pending retry与same-runtime recovery通过，收益记零 |
| W1b3e（correctness patch train） | 按QuickJS reader map依次迁generator/async、bound/proxy、Promise/jobs、ordinary/prototype/namespace与host payload → 删除generic realm slots/resolver → 删除`__realm_*`property/tag/copy/reflect与primitive/error/typed-array cache → realm退出borrowed-holder职责 → 沿Runtime/opaque ptr/root slot/value edge做传递性owner census | 20处pointer声明/视图、两个value槽、旧`host_function_realm_global`整数token、realm matcher及全部observable/cache side channel为零；AUTOINIT的typed `realm_and_id`、C_FUNCTION、FB、job、FinalizationRegistry/explicit host carrier之外无RealmRef，且内部Runtime-owned value/opaque record无未分类的RealmContext传递根。alternate/dynamic Function own-key与Proxy-newTarget trap矩阵通过；公开embedding handles仍是显式owner，weak-edge registry及WeakRef/weak collection/finalization tests保持，收益记零 |
| W1b4（correctness后独立测量） | production CFG显式return → reachable-falloff拒绝 → 删除final/mutable `+1` sentinel | qjs/zjs final-bytecode矩阵同构；fixture不再支配production artifact；sentinel变化单独A/B且dispatch整体不重开 |
| W1b5（canonicalization） | compile policy/realm显式传入 → ordinary script/direct/indirect root走child同一finalizer → parser.Result只own一个FB → module保持显式legacy variant | root/child final-bytecode、owner/free/OOM同构；只有non-escaping stack adapter，没有第二份mutable root或heap view；收益记零 |
| W1b6（correctness prep后单独生产候选） | 证伪/消除`get_var(arguments)` rescue producer → VM/frame/call直接读FB → cached-view派生事实逐项归owner/裁决 → 删除heap view/backtrace位 → owned FB ref直接转移attach且无分配 | 无stale arguments/runtime/backtrace adapter；leaf分类仅在最新A/B证明后以compact documented extension保留；direct construction/first-call A/B及关键offset/load chain、call/regexp controls无未解释回退 |
| W1c1（**已完成，correctness**） | ordinary GLOBAL唯一selector（含AUTOINIT retry）→ root+nested共享closure2 pass1/one-pass fill → owner-only cell flags → properties/capture失败完整rollback | ✅ script/direct/indirect均先构造自己的real function/current-function/final cell array；root与nested共用一次capture allocation、GLOBAL_DECL pass1和顺序fill，无placeholder/copy/replace；length/name/lazy prototype及W1d临时side channel均在capture后。FB owner在所有早退/OOM点恰好消费一次，inline-call source window与Error stack capture的前置失败也完整回滚；lazy global、same-Realm bootstrap、constructing-Realm publication可原地恢复。2026-07-23证据：core 274/274、exec 330/330、builtins 193/193、OOM 12/12、quick-check 3/3；module owner/null slots仍明确留给W1e |
| W1c2（**已完成，correctness/layout**） | pc2line buffer prepend起始line-1/column-1 ULEB128 → full-debug至少两个header LEB → producer/decoder/fallback同构 → 删除final/view平行坐标字段 | ✅ 唯一producer写两个header ULEB，DebugInfo不再平行保存line/column；reader对no-debug、截断/坏LEB和transition边界返回明确fallback，byte golden与nested/eval/throw stack矩阵锁定。2026-07-23证据：bytecode 112/112、parser 422/422、exec 330/330；不改owner/allocation，收益记零 |
| W1c3（**已完成，单独ownership候选**） | 只按当前full-debug production contract建立source NUL owner+pc2line exact-size producer → 完成真实fallible准备并收紧no-fail publication → atoms/values/内嵌atom ownership move → debug buffers转移 → 清空FunctionDef slots | ✅ source producer持有`logical_len+1`且写NUL，pc2line两遍计长后仅一次exact allocation；FB/DebugInfo/main block/ClassMeta/class-init box与count/layout全部在commit前准备，class sibling先全量验证再无失败安装，commit后只做owner move、Realm retain与no-fail GC publication。func/filename/script、vardef/closure/class atom、cpool child/value、code atom ledger、source/pc2line均直接转移并清源槽；析构按code→vardef→cpool→closure/class→realm→func/debug顺序。refcount无临时`+1`、child cpool RC、FD先析构、source指针/NUL、single-owner pc2line、malformed atom ledger、Nth真实OOM、abrupt/same-runtime recovery与class sibling原子性均锁定；未新增strip/shrink/registry伪失败点，也未计入后续layout/pack收益。2026-07-23证据：bytecode 118/118、parser 422/422、core 274/274、exec 330/330、builtins 193/193、OOM 12/12、quick-check 3/3、test262-smoke 12/12、`git diff --check`通过 |
| W1c4（**已完成，表示/layout候选**） | 唯一production raw builder+fixture builder → `createWithFam`并zero完整payload → 96B/align8 QJS base+32B production debug tail（fixture可显式no-debug）→ flag masks/ROM zero hole/zero-count NULL → 临时extension；tables/code暂不合并 | ✅ `FunctionBytecodeImpl`冻结为96B/align8 QJS core、可选inline 32B `DebugInfo`和可选40B extension；production保持full-debug，fixture可显式no-debug，唯一raw `createWithFam` builder归零完整FAM，zero-FAM/deferred-cycle free走同一析构契约。独立artifact owner仍明确暂存在extension并留给W1c5合并；flags（含ROM固定零hole）、zero-count NULL、raw offset/golden、rollback及legacy adapter矩阵均锁定。热调用路径以单次4B `CallFacts` load传递execution/behavior facts，消除重复extension定位且不缓存可变状态。2026-07-23证据：bytecode 124/124、exec 330/330、quick-check 3/3、统一Debug 1801/1801、alternate表示1801/1801、OOM 13/13、checkpoint 26/26（含test262-smoke 12/12）、perf-self-check 75/75、`git diff --check`通过；冻结Debug二进制baseline `28159a247dbed32f9001994aecda770940e17fde9f752985e7d8f4dcd50c998e`与candidate-v7 `c8de56ced0c446e8d793d64f32a9a13b5e4b63d8273d0d8cfc3d5291a253d435`做9轮interleaved A/B：no-call total -3.858%、first-call -6.736%、closure controls +1.408%/+1.438%、zero-arg call +4.690%、inline-add +0.246%；2k finalize alloc/free各-8002且peak allocation count -1。原始本地证据为`/tmp/w1c4-v7-final-ab-result.json`，不作为仓内ledger |
| W1c5（**已完成，单独allocation/layout候选**） | 统一checked `FunctionLayout.famBytes`把cpool/vardefs/closures/exact code并入同一`createWithFam` allocation并删除临时artifact block/base/allocation；source/pc2line继续独立move-owned；code后zjs tail拆成exact `code_end`处8B Hot（CallFacts+ScriptAtom，align1访问）与`align8(code_end+8)`处24B Side（三个指针），总尺寸恒等旧`align8(code_end)+32`；析构先capture layout/tails | ✅ production只剩一次main FAM allocation，物理顺序为96B core→可选32B debug→cpool→vardefs→closures→exact code→Hot/padding/Side；默认16B与alternate 8B JSValue的order、raw offsets、全部`code_end % 8`、zero-code fixture、no-extension、legacy Hot@96/Side@104/size128、heap accounting、cycle/deinit、cross-runtime与OOM均锁定。legacy以唯一`byte_code_len=-1`判别并在base+104直接取adapter，canonical table access不再定位Side；production callable冷发布验证non-empty/self-owned/extension，inline resolver以Debug contract使用3-load canonical CallFacts。2k finalize的logical alloc/free各减少4001且peak allocation count -1；backing slab/page几何的Debug噪声不伪称收益。2026-07-23证据：bytecode 131/131、OOM 13/13、alternate统一1809/1809、checkpoint 26/26（统一1809/1809、CLI 3/3、test262-smoke 12/12、architecture全绿）、perf-self-check 75/75、`git diff --check`通过。最终ReleaseFast候选`/tmp/zjs-w1c5-releasefast-candidate-v8`，sha256 `5d8087c097b3ea3d5c0e6be43756037c7c3f5b20dabb774d1114a0122aba5778`，28,707,536B；CPU19、ASLR-off、显式big-core PMU、六种平衡顺序的有效三方A/B相对W1c4：zero-arg cycles -0.548%/instructions -1.972%，inline-add control +0.368%/+0.000%，closure-hold cycles -0.262%/instructions +0.123%，nested-hold +0.156%/+0.180%。直接no-call/first-call的cycles受恒定12.1万page-fault与allocator微架构模式影响仍不稳定，未挑最快样本制造结论；原始证据为`/tmp/w1c5-v8-threeway-{hot,hold}-perf-result.json`与诊断JSON，均不作为仓内ledger |
| W1-core-close | W1a–W1c5 focused/checkpoint/test262/OOM → 该合入候选唯一一次ReleaseSafe → 审计后独立合入 → 重冻M-CELL与regexp Zoo | ordinary script/direct/indirect-eval及其realm carrier construction形成可落地基线，generic pointer与observable/cache realm补偿已退场；明确不包含per-realm module registry、class/private/import closure sidechannel或interrupt budget；按新profile重排plain put/set |
| W1d（**已完成，correctness/layout**） | PRIVATE-BINDING/CLASS-INIT迁移后，object/function private remap、ordinary `is_class_constructor` FB carrier、arrow/static runtime/FB side channel，以及finalization/final/runtime owners中的`ClassMeta`、FunctionDef/Bytecode `private_bound_names/class_private_names`、canonical `FunctionBytecodeSideExtension`均已删除；`Parser.State.class_private_elements/class_private_bound_names`仅保留为grammar/early-error/direct-eval parse临时表，不进入FunctionDef/Bytecode/FB/object/runtime；`<class_fields_init>`由真实child与lexical binding承载。ScriptOrModule因escaped direct-eval的referrer/diagnostic分离而保留在8B Hot documented product extension中 | ✅ canonical allocation止于`code_end + 8B Hot`，即“canonical Side carrier删除 + documented 8B Hot保留”，不是止于code。2026-07-23阶段收口证据：focused core/bytecode/parser/exec/builtins 1377项；最终修复后NaN-boxing exec 347/347、builtins 193/193，原production未知test262 25/25；OOM 14/14；alternate representation统一1837/1837；`engine-production-gate` 26/26（统一Debug 1837/1837、ReleaseFast CLI 3/3、architecture dependency/OOM-panic/public API snapshot全绿、full test262 0/49775 errors，passed 44542、known 24）。ReleaseSafe仍按总体路线图最终pre-commit/pre-push门禁唯一执行 |
| W1e（**已完成，correctness/ownership**） | ✅ ordinary root继续只产`FunctionBytecode`，module root改产唯一`ModuleArtifact{function_bytecode,record}`；request/import/local-export/indirect-export/star-export/attribute全部冻结为indexed metadata与final `var_idx`。RealmContext地址稳定`ModuleRecord`持久own精确module function、retained export cells、namespace/import-meta/eval-exception强边；module function从首次声明到SCC link/eval/TLA resume始终复用同一对象与nullable capture table，named import只在indexed link时接入最终VarRef，namespace import/`export * as`由canonical VARREF/AUTOINIT发布。link改Tarjan SCC与active-stack rollback，evaluation postorder从record request graph重建，static/dynamic import、synthetic module与Context.eval共享persistent status/result/error，TLA沿runtime FIFO reaction恢复且不重复load/evaluate。export resolver递归穿透`import {x}; export {x}`到最终binding，同时保留namespace identity；namespace `[[HasProperty]]`不读取TDZ，`super` Set按base descriptor→Receiver descriptor顺序传播ReferenceError/TypeError | ✅ registry地址稳定/跨Realm隔离、publication retry、GC/cycle/value rooting、persistent function/capture identity、indexed linking/ambiguity、namespace live binding与TDZ、Tarjan cycle、TLA FIFO、synthetic/static/dynamic import及same-path single-load均有回归。2026-07-23收口证据：focused parser 433/433、bytecode 134/134、core 282/282、exec 357/357、builtins 193/193；checkpoint 26/26（统一Debug 1856/1856、CLI 3/3、test262-smoke 12/12、architecture dependency/OOM-panic/public API snapshot全绿）；OOM 14/14；定向`language/module-code`+`expressions/dynamic-import`为prepared 1540、feature-skipped 346、passed 1193、known 1、unexpected 0；`git diff --check`通过。ReleaseSafe仍按总体路线图留到W1e–W6最终pre-commit/pre-push门禁唯一执行 |
| W1-full-close | W1d/W1e分别完成各自gate、审计、合入与affected-consumer重冻 | 此时才可声明全部closure/module construction对齐；若仍有product extension只能声明“QJS core exact + documented extension”，不追溯改写core-close或plain-put既有A/B |
| W2-0（**已完成，correctness**） | ✅ RealmContext直接own raw-zero/10000-reset interrupt counter，VM-local 1024 `InterruptPoller`与active gate删除；call/method/native/array/inline/tail/Function.prototype.call融合快路、constructor/Bound/Proxy及simple-field constructor按QJS entry次数扣caller，jump/branch只在唯一handler扣一次；最终bytecode arm后body扣callee。Interrupted按被poll Realm构造真实InternalError并以Runtime uncatchable flag跨inline unwind，catch/finally/IteratorClose不得洗掉；regexp counter、tail stack均未改 | ✅ 无handler推进、首poll与连续10000 cadence、Realm隔离、跨Machine、nested/tail、numeric cold branch、constructor双poll、fused forwarding、generator resume、cross-Realm caller-entry/callee-body及error prototype、outer inline for-of/catch均有回归。2026-07-23证据：focused core 283/283、exec 361/361；checkpoint 26/26（统一Debug 1861/1861、CLI 3/3、test262-smoke 12/12、architecture dependency/OOM-panic/public API snapshot与OOM-cap全绿）；OOM 14/14；三份独立终审PASS，`git diff --check`通过。收益记零并重冻；ReleaseSafe仍留到W1e–W6最终pre-commit/pre-push门禁唯一执行 |
| W2-tail（**已完成，correctness**） | ✅ Runtime同时记录native/logical depth与按QJS `JS_CallInternal` alloca公式计算的planned bytecode-stack bytes；普通、inline、generator/async resident entry及COPY_ARGV forwarding均精确charge/release。proper-tail-call先在caller仍存活时完整准备target，全部fallible setup成功后才以no-fail transaction转移continuation、最早arena mark、profile restore chain和累计tail budget并复用物理Entry；失败继续由原caller正常unwind/catch。caller guard/poll先于callee Realm切换，async init只准备resident frame，首次resume独占单次guard→poll；interrupt跨Promise边界只局部转移原caller-Realm uncatchable InternalError为rejection reason，不放宽通用error matcher；interrupt error构造OOM时以预制OOM对象维持unconditional uncatchable | ✅ 尾递归/大小frame混合/逻辑深度/stack overflow、raw tail opcode、COPY_ARGV、cross-Realm interrupt-vs-stack次序、generator/async cadence及async rejection Realm、interrupt×OOM catch bypass、target setup deterministic OOM与同Runtime恢复均有回归。2026-07-23证据：focused exec 366/366；OOM 14/14；alternate representation统一1866/1866；opcode-profile启用构建及tail smoke通过；checkpoint 26/26（统一Debug 1866/1866、CLI 3/3、test262-smoke 12/12、architecture dependency/OOM-panic/public API snapshot与OOM-cap全绿）；三份独立终审PASS，`git diff --check`通过。收益记零并重冻；ReleaseSafe仍留到W1e–W6最终pre-commit/pre-push门禁唯一执行 |
| W2-cont（**已完成，架构差异审计**） | ✅ production非`.next` action census仅有`for_of_next`与`proxy_get`；两者分别own depth与Atom，并在callee返回后执行不同但必需的post-work。普通call全为`.next + payload 0`并直接resume；tail replacement只转移既有continuation ownership | ✅ QuickJS以递归C caller locals保存同等post-call状态，resident Machine必须显式持久化；tag+u32已是无allocation且覆盖完整Atom域的共同表示，无符合约束的生产候选。self/constant/zero-arg iterator、ordinary method及static/computed Proxy direct/control输出与qjs逐项一致；exec回归补齐driver `.returned`上的native tail-call成功/抛错矩阵，收益记零、不作PMU声明，W2继续冻结 |
| W3-property（**已完成，候选回退**） | ✅ ordinary/global-varref probe分开；只让final `get_field/get_field2`跳过private-atom guard的干净候选通过exec与语义矩阵，direct instructions稳定下降约1.2%～1.5% | ❌ own-data 18-block paired cycles全部回退，中位+1.695%，越过+1%门槛；生产代码完整回退，固定static-miss/global-VARREF probe与失败结论保留 |
| W3-native（**已完成，correctness + 候选回退**） | ✅ observable C_FUNCTION caller-realm native-stack preflight、constructor pre-scope guard与External HostCall单一native frame已补齐；递归恢复/backtrace/cross-realm prototype回归及exec 370/370通过，收益记零。重复`callable_realm`transport候选在ordinary/cross-realm/C_FUNCTION_DATA/constructor/synthetic/nested语义矩阵通过，并在两个builtin domain的plain/method与exact/missing形状稳定减少每次2～6条指令 | ❌ 独立布局重建虽保留direct指令削减，却使property-read/allocation controls回退+1.477%/+1.660%，越过+1%门槛且暴露code-layout方向翻转；生产候选完整回退，九个direct/control probe与失败结论保留，W3冻结 |
| W4 | ✅ force-GC liveness 前置（`f221dfee` + `2ecbf301`/`951726e1`/`1f67bdbc`/`ad3218dd`）→ 重冻 → M-ALLOC-LIFECYCLE → M-SHAPE-PUBLISH | 前置门禁已恢复；剩余 core stats 条件是 instrumentation 语义而非 liveness skip。先空对象 lifecycle，后 transition/capacity 差分；阶段末仍跑统一 force-GC/OOM gate，不重做已关闭的 per-alloc page-geometry/按值 class-record 刀 |
| W5 | parser 默认参数 correctness → 重冻 diagnostic/PMU → M-EMIT | hoist construction 不算 peephole；只做 final bytecode 确认仍缺的 qjs rule |
| W6（**已关闭，条件未满足**） | ✅ `a11f99d3`完成tail stack guard；`a2499f4c`关闭continuation审计 | ❌ 现有W3数据不覆盖frame，且无frozen post-W2 profile证明至少两个frame shape共享同一新热点；M-FRAME-CONT不重开，收益记零 |

每个机制工作项只交付四类内容：最小代码改动、红灯/语义测试、三方性能证据、简短机制结论。
失败候选删除代码但保留结论；完成后更新本计划的当前优先级，不追加逐日流水账。

## 11. 历史教训转成的永久约束

- **先读 qjs，再形成假设。** Q1、for-of result allocation、Array storage 都证明名称相似不等于
  热机制相同。
- **源码宏和构建配置属于 reference。** `DIRECT_DISPATCH/SHORT_OPCODES/CONFIG_STACK_CHECK` 不同，
  即使同一 commit 也不是同一机制基线；diagnostic qjs 不能拿来跑性能。
- **zjs 架构选择不自动是 Zig 限制。** record table、lazy property storage、提前发码都必须
  按 deliberate divergence 审计。tail dispatch 则已有单体 spill 与 224-arm A/B 证据，当前作为
  Zig/LLVM 等价适配封账；这个结论来自数据，不是来自“Zig 写法不同”。
- **runtime 补偿分支往往是构造阶段不同的信号。** `publishTopLevelFunctionVarRef` 不能凭
  benchmark 没触发就删；先对照 qjs 的 metadata→cell→value-publication 阶段，再用 final
  bytecode 和别名 invariant 证明补偿不可达。
- **源码识别器不是 parser/runtime 机制。** 已确认的 `1 2 → undefined` 说明“只处理一个看似安全输入”
  会直接吞掉 syntax error；任何 eval/Function/source helper 都必须证明走通用 parse、realm、closure、异常链，
  否则先按 correctness debt处理，不能进入性能 baseline。
- **root bytecode 不是无对象的特殊脚本。** qjs 对 script/direct/indirect eval 都建立真实 function object与
  capture array；跳过它会同时改变 current-function、GC/OOM、stack/backtrace和 cell lifetime，不能只用
  最终 stdout相同裁决。
- **“字段更少”不等于物理compact。** ordinary/parameter路径先删了scope graph/depth，但直到W1b2用DWARF/raw bytes验证后
  closure才真正从12B收敛到8B、vardef从16B收敛到12B；W1b2 Zoo又证明表示对齐不自动带来cycles收益。以后仍须同时锁
  size/alignment/offset/accessor并独立测量；static class-field的`0x8000`必须在其真实child迁移时删除。
- **总struct大小相同也可能是假对齐。** 两边full-debug FB都是128B，但QJS align8且strip header只有96B，zjs align16；后者还把GC prefix扩大并绕过
  align8 slab，cached view/class side pointers又改变hot field offset和load chain。layout验收必须同时看size/alignment、
  prefix/allocator class、字段offset、consumer assembly和side allocation，不能只报一个`@sizeOf`。
- **C bitfield源码相同不等于Zig位布局相同。** `packed struct`只证明Zig自己的规则；QJS的`uint8_t : n`落位要以pinned
  compiler/target的raw bytes和字段行为为准。用显式mask/accessor锁定，并把zjs执行分类放入保留字节时明确登记扩展，不能靠
  “offset没变”冒充语义完全相同。
- **compatibility view可能同时藏着语义补偿和性能特性。** cached `Bytecode`不只是code/table别名：它还扫描
  `get_var(arguments)`做runtime rescue并发布多组leaf-call分类。删view之前必须把前者回推到QJS pseudo-binding producer、
  把后者在新基线上重测后逐项裁决；整包复制进FB只是把旧架构永久化。
- **attach的owned引用来自producer/load，不来自attach内部。** QJS的cpool load先得到一份owned bfunc，`js_closure2`
  消费并转移；`dup attach → free原值`虽语义等价却改变refcount成本和失败边界。所有权API必须在类型/命名和OOM测试中区分
  borrowed与owned，不能把这部分收益塞进allocation pack。
- **测试fixture不是第二个production producer。** 当前所有finalizer之外的raw FB allocation都位于test作用域；变长header
  必须用fixture-only builder迁移，而不是为了手造测试保留by-value init、双free公式或synthetic FB生产路径。native function
  本来就有独立object表示，与QJS C function相同，是control而非例外。
- **common core exact不等于total allocation exact。** 为了先冻结ordinary hot offsets，过渡side facts可以在exact code后
  进入显式optional extension，但此时只能叫QJS-order core pack；W1d删除/裁决extension后才可exact-close。把nullable
  class pointer继续塞在每个FB header里，或把extension尾巴从文档中省略，都会让core-close基线失真。
- **按QuickJS当前代码，不按注释里的未来愿望。** QJS主allocation没有包含source/pc2line bytes；二者只转移指针。
  把它们也塞进zjs trailing block不是“更忠实”，更不能用一次allocation总数掩盖额外copy。
- **相同lookup结果不等于相同debug artifact。** zjs把起始line/column另存字段也能打印多数正确栈，但QJS把它们作为
  pc2line buffer的两个ULEB128头；不比较golden bytes、malformed fallback和最终字段集合，就会在core/exact pack时把平行格式固化。
- **move ownership与pack allocation是两把刀。** 先预留所有fallible资源并建立no-fail move commit，再从稳定点改变
  allocation topology；否则atom/value dup减少、buffer copy减少和allocator调用减少无法分别归因，OOM顺序也会漂移。
- **不可见sentinel会变成真实生产语义。** 只要root/eval或branch-to-end会读取`code[len]`，它就不是fixture安全垫。
  必须先按QJS发显式return并拒绝reachable falloff，才有资格删除`+1`和相关dispatch假设。
- **realm field不等于realm机制。** QJS Context中的global/intrinsics/class prototypes/eval/random/modules是realm state，
  当前exception/stack/job queue则属于Runtime；zjs不能机械refcount整个host Context，也不能把global header提前写进FB就宣告完成。
  先从host handle拆出唯一GC/refcount RealmContext与RealmRef/state map，再逐consumer删除global/Context/Runtime上的平行realm slot。
- **RootProvider不是RealmContext GC。** QuickJS用GC header所在的`gc_obj_list`对Context做trial-decref child traversal，另用
  `context_list`做class扩槽/枚举和realm-local Array prototype guard失效；zjs当前RootProvider只服务external `traceRoots` visitor，cycle collector不会读取它。
  RealmContext必须有独立GC kind、owned-child visitor和runtime context link；三条路径均不得互相冒充或偷偷retain。新增kind要覆盖
  size/candidate/revive/zero-ref/remove-cycles/deinit/deferred-free/accounting全部switch，不能只让一个cycle测试碰巧通过。
  RealmContext-owned slot只进GC child visitor；RootProvider保留时只作诊断或枚举EventLoop等真正host-owned edge，不能把同一owned child再算成external base。
- **GC header publication与live-context publication是两件事。** null class slots/no-child scaffolding先准备，随后header以`.constructing`进入collector；
  任何可能分配或创建RealmRef carrier的bootstrap只能发生在这之后。global/intrinsics/initial-shapes全部成功后，context link才以no-fail commit进入
  live registry。失败必须从普通child teardown摘header，不能直接free；半初始化realm不能被class growth、legacy adapter、Array invalidation或plugin unload看见。
- **initial shape不是隐藏template object。** QuickJS让Context直接own五个Shape并在construction传入固定props值；zjs默认也应使用RealmContext direct
  Shape ref+typed initialization data。prepared props在失败时按shape flags完整释放，成功时无额外dup地move进object；只换shape owner、不锁entry ownership仍未对齐。
  Runtime shape hash只借ptr。仅为复用现有helper而保留完整JS template不是Zig限制；无QJS对应的template若保留，
  必须作为独立product cache测量和追踪，不能冒充Context shape对齐。
- **runtime-wide保守flag不是per-realm guard。** QuickJS用每个Array.prototype的`is_std_array_prototype`让dense append O(1)裁决，
  并在该realm的Array/Object prototype进入tagged-small（0...`2^31-1`）property publication attempt时、或Array.prototype的prototype成功改变时永久清零；
  前者早于fallible shape growth，后续OOM也不恢复，后者只在真实commit后发生，两类失败事务不能混成同一规则。
  同值set-prototype提前成功返回而不失效，更大的字符串ArrayIndex不扩大该域。
  zjs的sticky runtime bool+逐链scan语义安全但拓扑不同且跨realm污染，
  不是Zig限制；待context list稳定后单独迁移、单独A/B，删除属性也不得擅自重新开启guard。
- **`is_std_array_prototype`不是通用chain-clean capability。** pinned QuickJS只在`can_extend_fast_array`对应的Set/put/push/splice等extension
  reader消费它；已有own dense slot、CreateDataProperty、已经完成prototype walk的append和hole Set各有不同协议。zjs现有fill/growing-unshift/bulk
  fast path不能因新flag而被“顺便证明”：要么保留独立actual-chain product proof并单独封账，要么退generic。先画reader map再改authority，
  `any_prototype_may_have_indexed_properties/is_prototype`传播必须退场，local indexed-summary若保留也不得重新成为realm-wide guard。
- **global class不等于realm storage。** QuickJS以`JS_CLASS_GLOBAL_OBJECT`选择global exotic与AUTOINIT VARREF publication，Context另own
  realm state，但`uninitialized_vars`确实留在global class payload；zjs不能继续以RealmPayload存在性实现`isGlobal`，也不能反向把
  global专属cell side table搬进Context。必须字段级split，否则state迁移后会留下identity空壳、让附属cache改变对象类别或改变cell lifetime。
- **legacy global参数只在embedding边界解析。** 为保持zjs公开`realm_global` options，可在冷边界把调用时registered live exact global映射成RealmRef；
  这不授权global/object payload保存反向ctx pointer，也不授权VM恢复`objectRealmGlobal`。live non-global/未登记地址必须在不解引用输入时
  报错，不能退回default realm；但free后地址若复用，裸`*Object`没有generation，无法证明调用方想的是旧对象。强stale诊断需要新handle，
  不能把scan/index描述成它做不到的保证。
- **realm ownership是一组carrier，不是FB特例。** pinned QJS明确dup/free context的现役carrier包括FB、C_FUNCTION、
  AUTOINIT property、job entry和FinalizationRegistry；C_FUNCTION_DATA沿caller，bound/proxy只递归target。任何escaped carrier仍靠borrowed cleanup registry
  存活都算未对齐，每个carrier必须各自有mark/free/escape证据。反向也不能过度retain：FunctionDef/parser/serializer/sort等同步state里的ctx
  没有dup/free，只是调用期borrow；最终FB/job等发布点才取得owner。
- **context list不是隐藏base owner。** 公开handle或命名harness/host policy own创建时base ref，runtime context list只枚举且不能复用
  会在collection中移动节点的GC links或任意RootProvider表；
  `$262.createRealm().global`不能靠临时wrapper或偶然builtin cycle保活。Runtime teardown先释放queue/host refs并要求外部RealmRef归零，
  不能强制销毁后留下看似有效的handle。遍历borrowed list时也不能调用可触发collector/unlink的allocator；class growth须scoped no-GC allocation
  、先snapshot+temporary retain，或在pin current时先retain next再执行可重入操作；保存裸next指针不足以防后继被free。进入不可revive finalizing
  commit的RealmContext必须先退出context list/root-provider，不能继续被class growth、legacy adapter或plugin unload当live realm使用。
- **process-global Class ID并发安全不等于Runtime mutation并发安全。** pinned QuickJS只在`CONFIG_ATOMICS`下保护`JS_NewClassID`的global allocator；
  同一Runtime的Context创建、class registration、context/GC list与prototype slot mutation依赖串行执行。zjs必须明确选择并执行owner-runtime-thread断言，
  或用同一具名Runtime mutation lock覆盖class-count snapshot→constructing header→live-link reconcile、class growth、plugin slot cleanup与相关GC/list commit；
  不能只把ID改atomic。锁只能包窄结构commit，fallible prepare须在owner thread或已证明thread-safe/no-GC的allocator完成，GC/JS或DSO callback必须在结构锁外并靠generation+pin重验；owner thread也仍可能回调重入。
  foreign waitAsync只能发布no-alloc signal/ready state，不能跨线程拿锁后分配、settle Promise或运行JS。
- **pointer-only class record不是stable handle。** QuickJS的`class_array`可realloc，但create先GC、free先递归cleanup，随后才按id读取record；definition本身则活到Runtime销毁。
  zjs的`recordPtr`只能是no-GC/no-callback瞬时view，不能跨collector、allocator、host finalizer或dynamic registration。需要跨窗口的数据只复制最小immutable plan并带registration generation，
  publication前按id重取/校验；live object、pending finalizer、active construction/callback必须阻止definition unregister。修这个correctness窗口不授权恢复88B by-value copy，也不能把plugin execution pin误当全表地址pin。
- **class ID、definition、prototype与object是四层lifetime。** QuickJS `JS_NewClassID`在process-global namespace给调用方stable slot分配ID，
  definition才按Runtime注册，prototype按RealmContext安装，object把创建时prototype固化进shape。zjs不能再把`Table.next_dynamic_id`的
  Runtime-local策略写成reference事实；默认对齐stable ID。若已发布plugin contract迫使保留，必须命名为产品偏离、所有handle校验Runtime且ID不跨Runtime/不复用，
  不能归因于Zig。ID合法域是1...65535；allocator必须用加宽/exhausted state，不能因`ClassId=u16`拒绝65535或发生wrap。
- **custom class definition在Runtime，prototype在RealmContext。** QuickJS `JS_SetClassProto/JS_NewObjectClass`已经给出owner边界；
  `JS_NewClass1`还要求class-count增长时全部live Context先拥有null slot，future Context按新count初始化。zjs binding与runtime plugin必须共用
  这套capacity/publication机制。Zig slice.len不能把partial OOM后的storage growth冒充published `class_count` bound；low-level get/set按bound，
  registered definition与高层NotInstalled另行裁决，不能混成一个条件。
  external record、InstalledPlugin或class table只能保存class id/descriptor/opaque metadata，不能暗持prototype
  JSValue或跨realm fallback。底层null slot仍按QJS表示null-prototype；zjs高层binding的`NotInstalled`是另一个已命名API gate，不能反写成
  QJS语义。opaque wrapper creation使用typed callback RealmContext的slot；创建后由shape保活prototype，不因construction realm再持RealmRef。
  low-level `JS_SetClassProto`式slot必须consume任意JSValue，getter返回dup；只有object creation把object-tag值当prototype，null与其他tag都落为null prototype。
  setter/clear必须先publish new/null再free old，使old finalizer重入时观察新状态；若公开binding只允许object，则它是另一个具名高层validation，不能缩窄或改写core slot契约。
  RealmContext释放slot与Runtime注销class definition是两个不同lifetime事件，必须分别封账；后者是zjs plugin-lifetime extension，
  pinned QuickJS没有动态unregister class API。保留时不得靠metadata持RealmRef：所有DSO callback先持temporary execution pin；复制DSO code/data pointer的
  deferred node从enqueue到callback返回持installation/definition pin。zero live-owner、zero active-callback且zero queued-callback后，才沿context list把本installation slot
  先take-null/free，再unregister definition，最后close DSO；callback栈内last-release只标pending，
  RealmContext teardown复用同一take并允许reentry。
  `JS_NewClass1`也不安装prototype：slot setter consume、getter dup、object shape retain是三个明确
  ownership动作；plugin跨class rollback若保留只能是上层zjs transaction，不能重写low-level reference步骤。
- **公开binding不是裸prototype handle。** 保持`binding(ctx).new/payload`方法形状的`JSObject.Binding`只能是ctx-lifetime borrowed
  `{RealmContext,class_id}` view，new/payload现查live class slot；它不own、也不缓存prototype。需要跨owner wrapper lifetime时显式取得
  `OwnedBinding{RealmRef,class_id}`并deinit；独立副本只能经显式`clone/retain`取得，bitwise copy不产生第二份owner。Runtime record/class metadata
  不能替borrow偷偷续命，raw `prototype:*Object`也不能在realm释放后继续可调用；exact-prototype brand是已命名zjs API contract，
  不是增加hidden owner的理由。
- **owner审计必须沿传递边，不按字段名。** Runtime的JSValue cache、root provider、value-root slot、external-record opaque ptr和
  host payload即使没有`realm`拼写，也可能经C_FUNCTION/FB钉住RealmContext。内部owner必须有QJS对应或命名escape contract；
  公开`JSValueHandle`/weak handle与host tracer edge是合法embedding root，但调用方必须在Runtime teardown前释放，Runtime不能清slot后
  留下悬空handle。host finalizer可先释放自己的root，随后再断言context/root-provider/value-handle图为空。
- **没有realm字段本身也是机制。** QJS的ordinary/Promise/RegExp/arguments/typed-array/generator/VarRef/module namespace等payload
  不own通用Context；realm由active operation、saved function/FB、target、newTarget、AUTOINIT或job provenance提供。zjs的20处
  `realm_global_ptr`不能机械升级成20个RealmRef。逐reader退场时只移除weak-holder的realm匹配职责；WeakRef、weak collection和
  FinalizationRegistry cell仍需的真实weak-edge registry必须保留，不能用整表删除伪造“更像QJS”。
- **可观察property不是内部realm carrier。** `__realm_*`即使改成non-enumerable或symbol，仍可被own-key、Proxy trap、修改和删除观察；
  用它传FunctionRealm/class prototype既改变语义也让用户状态影响内部fallback。真正来源是active C_FUNCTION/FB RealmContext或
  `JS_GetFunctionRealm`，因此必须删除property/tag/copy/read整链，不能只换名字或descriptor flags。
- **realm切换有阶段边界。** bytecode/native的callability、argv/stack sizing和stack-overflow preflight仍在caller realm，
  frame建立后函数体才进入callee realm。把整个call入口先切callee会改变错误prototype；只在body中继续用caller又会改变
  sloppy this、intrinsic eval与Error prototype。bound/proxy还要先在caller完成argv/trap wrapper，再递归target；
  `JS_GetFunctionRealm`的真实内部consumer是constructor/Dynamic Function/Error prototype fallback与ArraySpecies foreign-intrinsic
  comparison，不是把wrapper提前切realm的许可。测试必须同时锁wrapper、preflight、最终callee和foreign/ordinary species两臂。
- **job FIFO与enqueue realm不可分割。** QJS runtime单FIFO中的每个entry都own realm；把Promise放Context、finalization放Runtime、
  再靠sequence归并只是zjs补偿模型。dynamic-import job、attribute/error处理和Runtime loader也必须沿entry ctx；callback忽略传入ctx、
  从userdata里的裸context恢复realm同样算丢owner。统一queue时不能让state成为realm authority，也不能让host timer/signal插队成ECMAScript job。
- **reference的ignored enqueue OOM不是要复制的机制。** Promise reaction/thenable/dynamic-import与FinalizationRegistry的pinned内部调用点会忽略
  `JS_EnqueueJob(2)`失败；zjs按GUIDE保留prepare/reserve→no-fail commit或pending retry。每个producer必须明确“失败是否消费输入、promise是否commit、
  work由谁重试/拒绝”，禁止settled-without-job、永久pending import或silent drop；这项safety divergence收益记零。
- **统一FIFO不等于继续run-all。** `JS_ExecutePendingJob`一次只消费head并返回empty/success/exception；异常后的entry仍在原序列。
  zjs host loop可以显式重复run-one，但不能free异常result后继续，也不能在释放job唯一RealmRef后返回raw ctx。queue storage、realm owner与
  dequeue/cleanup/status transaction三项必须同时对齐。公开`job.drain(ctx,{budget})`只用ctx选择/校验Runtime，不能过滤或改写entry realm；
  null/0/N的执行上限、正常返回的真实`jobs_drained`及统一FIFO `has_more`必须是该transaction的直接聚合，不能再用“曾经有work”近似。
- **foreign host completion不能直接执行JS。** pinned QuickJS Atomics waiter只同步signal；zjs waitAsync是额外surface，必须由node own RealmRef，
  foreign notify/timeout只做no-alloc ready publication，owner runtime再把typed settlement接入统一FIFO。跨线程分配/写Promise、`catch {}`后
  unlink丢completion、靠无关Promise调用轮询timeout或Runtime teardown强拆node都不允许；OOM必须保留同node按序重试，cancel/notify/timeout
  只能有一个释放owner的winner。这是product extension contract，不是QuickJS或Zig限制。
- **OOM对齐的是active realm与递归协议，不是一个不存在的预制对象。** QuickJS只有Runtime `in_out_of_memory` guard，并按当前ctx的
  `native_error_proto[InternalError]`尝试构造；再次分配失败时throw `JS_NULL`。zjs为既存`oom_cap`零分配catch与same-runtime recovery保留
  per-realm preallocated Error属于明确的failure-path safety adaptation，不能写成QJS Context字段、不能由首realm做Runtime强root，也不能据此
  跳过普通/可分配OOM的caller/callee phase测试。fully-exhausted fallback无stack且同realm重复时可能复用identity/用户mutation，这也是必须明示的
  product divergence；预制对象尚不可用时只能走runtime-neutral emergency state。
- **lazy不是吞错许可。** QJS AUTOINIT用stored context只调用builder一次并把exception上传；当前zjs optional builder、undefined
  fallback和同read双试会隐藏真实OOM。GUIDE允许失败时事务性保留placeholder以支持same-runtime retry，但本次read必须抛错，
  且成功时slot RealmRef→materialized C_FUNCTION RealmRef的owner转换仍逐项对齐。不能把QJS失败后留下undefined的quirk或zjs现有
  “OOM反正致命”注释用来绕过错误通道。
- **lazy允许域也必须对齐。** QuickJS low bits只有PROTOTYPE/MODULE_NS/PROP，且PROP只延迟C function/string/object；
  accessor、数值常量和alias不是“同一机制的更多case”。尤其alias在QJS安装期读取source并定义同一value，不能靠per-realm shared cache
  模拟。zjs host object可以复用PROP builder作为documented surface extension，但不得扩张slot dispatch、改变alias时序或把bootstrap
  加速称作Zig限制。第二个word也应直接保存stable typed opaque；Zig能表达`*const`，所以`AutoInitRef{rt,id}`/runtime table lookup不是
  表示限制。只有动态host descriptor的真实lifetime证据才允许stable arena，不能借此给standard entry保留整数间接层。
- **对齐owner/identity，不复制C的tag偷运。** QuickJS MODULE_NS builder用`JS_TAG_STRING`临时携带`JSVarRef*`，随后立即转成
  VARREF property；那是C union表示技巧，不是可观察语义。zjs应以typed materialization result表达namespace value或shared VarRef，
  但必须保持原cell identity、publication顺序和异常；把它简化成data snapshot同样不忠实。
- **C function的realm从构造第一刻成立。** final prototype、RealmRef、normal `length/name`必须由一个fallible constructor同时建立；
  Function.prototype bootstrap显式使用Object.prototype，之后才允许默认Function.prototype。先造null-prototype对象、后补realm/prototype、
  lazy name或吞掉`setPrototype`失败都会改变OOM和可观察对象图，不能留作过渡出口。
- **callback context必须和realm同生命周期。** binding wrapper只是owner handle；C_FUNCTION callback收到其callee RealmContext的typed
  borrowed view，caller-data收到caller，job收到enqueue realm。Zig模块分层若需要public facade，只能使用RealmContext内同寿命固定member；
  不能把已destroy wrapper、host handle裸指针或stack-temporary facade传给embedding callback。raw plugin `CallFrame.ctx`是唯一可因已发布
  ABI保留的opaque表示，但仍只允许由helper取得call-duration typed borrow，不能cast成owner或保存。borrowed view可比较underlying identity；
  需要逃逸时显式取得owner ref。若兼容ABI继续暴露`ExternalCall.global`，它只是同一borrow view的`global_obj`别名；每个可观察JS call都
  必须非null，pre-global bootstrap另走typed construction API。ctx/global/globals必须原子切换，禁止独立fallback或出现A ctx+B global。
- **EventLoop是具名zjs host owner，不是QuickJS carrier或wrapper布局适配器。** quickjs-libc由`js_std_loop(ctx)`每次接收borrowed ctx，
  不dup/store它；zjs若保持`runUntilIdle(self)`现有API，就必须为自己保存的stable core ctx持一个RealmRef，并把这项记作API-lifetime
  adaptation而非QJS/Zig限制。HostEventLoop vtable直接消费收到的core ctx，禁止反向cast binding wrapper；handler表只own callback value，
  最终JS call仍由函数carrier决定callee realm，不能给每个handler复制context。deinit先detach、再释放callback roots、最后释放loop ref；
  Runtime不得替调用方静默拆掉live loop。
- **内部控制协议不是低配JS调用。** QuickJS解构把iterator/next/catch-offset放在operand stack并用专用opcode处理step、rest与close，
  不创建一个无属性、无realm的C_FUNCTION再走通用call。zjs-only proposal控制流也应使用typed opcode/continuation并借active realm。
  把伪helper改成C_FUNCTION_DATA或专用class只能隐藏carrier矛盾，不能算对齐；Runtime不得缓存这类helper JSValue。
- **无reference产品特性不能反排QJS core优先级。** `using`的全块预扫会污染所有普通parser construction，故其共享parser债务必须在
  M-PARSER-CONTROL-CLEANUP消除；但八个helper的typed runtime迁移属于独立product correctness，不应阻塞ordinary/core finalizer。
  它仍须在总体性能重冻和callable/realm inventory前完成。这样既不让feature拖住机制，也不把feature债务藏进下一条基线。
- **embedding brand偏离必须显式命名。** QuickJS `JS_GetOpaque2`按class id，不检查当前prototype；zjs `docs/public-api-contract.md`与tests要求
  exact realm-local prototype。保留该公开contract时，应由method C_FUNCTION的callee RealmContext查`class_proto[class_id]`，而非让
  runtime record强持prototype；它是product/API divergence，不是QuickJS行为或Zig限制。若改变brand语义，必须另做API兼容裁决。
- **JS prepared call不能凭死flag复活。** 当前`prepared_call_ok`零reader；QuickJS C_FUNCTION的realm、prototype和object identity都在
  真实function object上。任何未来从JS call opcode/callable dispatch跳过对象的候选必须另有等价carrier与不可观察证明，并单独A/B；
  一个table布尔不能授权跳过FunctionRealm/call phase。已处于某算法active realm的内部typed-handler复用不是JS调用，单独分类；live
  `forwards_call`也有独立consumer，不能因字段相邻被误删。
- **loaded module identity是per-realm state。** runtime级文件读取/cache可以共享，`loaded_modules` record/function/cell/namespace/error
  不能共享；但QJS是`JSContext.loaded_modules` list持ModuleDef base ref，而非每个ModuleDef dup Context，不能过度补一个record RealmRef。W1e未完成前禁止把
  ordinary realm对齐扩写成完整context/module exact。
- **poll point存在不等于interrupt机制已对齐。** counter lifetime、阈值、跨call持续性和handler cadence与poll位置是两组契约；
  call entry扣caller context，最终arm切换后的backedge扣callee context，handler为null时counter仍推进。interrupt counter也不是
  tail-recursion stack budget或regexp execution counter，三者不得共享一个“够用”的计数器。
- **对齐当前机制，不顺手补reference feature surface。** zjs没有strip producer/API或binary reader；本轮可让layout表示no-debug，
  但不得为了复刻QJS选项新增strip功能并把其代码量/收益混入FB ownership/layout候选。
- **忠实成功路径不要求复制已知failure quirk。** QJS `js_function_set_properties`等void helper会忽略部分property失败；GUIDE要求
  zjs传播真实OOM/异常并rollback。此类差异必须命名、测试并记为safety adaptation，不能当作“Zig限制”或性能捷径。
- **FunctionDef事实不自动有资格进入FunctionBytecode。** `func_pool_idx`、source scope、TDZ发码标记等只服务
  compile/finalize；final FB只保留运行期consumer必需的最小事实。没有reader的`DirectCallSite`已证明“也许以后用”
  不是持久化理由；新增final metadata必须同时提交真实consumer、生命周期和A/B证据。
- **迁移脚手架必须有退场门禁。** `EntryContract`正确解决了undefined-current-function语义耦合，但QJS final FB
  没有其中的environment/binding位；real root/vardef topology可表达同一事实后必须删减，而不是把过渡字段改名成架构。
- **short opcode 是最终编码选择，不是数据模型。** qjs 先保留宽 `fclosure` index，只在
  index≤255 时缩短。历史 zjs 的直接 `u8` cast 与 short-only consumer 已由 `936111c5` 修复；永久教训是
  producer 与所有 consumer 必须成对审计；当前scanner已删除，但仍不能因P0完成而跳过persistent module
  function、indexed slot和guarded-call时序审计。
- **顺序必须来自 provenance，不能来自事后 permutation。** qjs 的 eval prefix、declarations、child-demanded
  captures、parent body captures 分别在固定阶段产生；把最终 closure table 全局“child-first”排序会直接破坏
  nested-eval 前缀。没有 provenance 的 reorder 不是 post-order finalization 的等价替代。
- **grammar lookahead不能变成semantic producer。** QJS只为参数、解构、for/arrow等语法歧义做有源码锚点且
  不改声明表的lookahead；zjs历史body `var/eval`及simple catch/for扫描已删除，当前只剩pattern/switch账本与
  implicit-arguments future-function scan仍替正式producer/final resolver作决定。任何重扫只要会写binding、capture、strict状态或环境transport，
  就不再是lookahead，必须删除或给出对应QJS producer；普通`var`与Annex-B都按正式parse遇见顺序建立。
- **validation也不能维护第二套grammar。** QJS在正式destructuring traversal遇到binding时立即查duplicate；zjs另跑
  `collect*BindingNamesSnapshot`，即使不创建child，也会重复property-name解析、atom retain/free、临时name-array allocation与OOM点。
  duplicate/redeclaration规则应成为正式producer的检查，不得以“只验证、不发码”为由保留全pattern预解析。
- **`ParserSnapshot`不是FunctionDef transaction，单份结果也不等于单遍构造。** snapshot最多恢复lexer、code、atom operand和
  feature bits，不能撤销child list/cpool、VarDef/temp local、scope/label/catch表及其owner/refcount；因此destructuring的“完整parse后truncate”仍会把
  `{a=function x(){}}`变成`x,x`；此前generic for target的同类LHS replay已删除，作为禁止回归证据。反过来，只把预读换成token scan、却先正式parse外层RHS/default，再回放pattern，会把QJS的
  `x,d`倒成`d,x`。正式parser必须严格按源码遇见顺序只调用一次；运行时要求RHS先求值时，用QJS的label/operand-stack控制流表达，
  不能用解析顺序倒置。若确需可回滚事务，必须显式拥有并恢复全部FunctionDef mutation，而不是继续扩充partial snapshot。
- **共享源码body也是控制流identity。** QJS finally只parse/emission一次，所有abrupt edge通过`gosub/ret`进入；
  从lexer snapshot为每条路径复制相同文本，即使stdout一致，也会复制child/cpool/atom/source position并改变
  code size、capture provenance与Nth-OOM。已有opcode足以表达时，这不是Zig限制，也不能作为“展开更快”的候选。
- **canonical lexical binding不能靠伪capture维持第二authority。** derived constructor的`this`在没有真实nested
  reference时是普通local，`super()`初始化同一binding；finalizer无条件capture再让runtime把它alias到
  `frame.this_value`会制造非QJS row/index与同步路径。capture只能由真实resolver/eval/mapped-arguments事件产生；
  若Zig表示确有障碍，必须先证明不能由同一local/cell表达，而不是把补偿字段升级为架构。
- **cell identity的更新时间也是provenance。** qjs在`leave_scope/close_scopes`按已经发生的capture detach；把它搬到
  下一次entry并预扫future capture，即使普通stdout一致，也会改变旧closure与新迭代cell的交接点、allocation/GC/OOM顺序，
  并迫使compiler维护第二套hint。除非有具体Zig/LLVM限制及同等级证据，不得把exit改entry称为机制对齐。
- **body scope必须按FunctionDef producer分类，不能“一刀切所有FunctionDef”。** root eval/program、parsed block/concise arrow与
  generated default constructor都经过QJS `push_scope`；只修`parseBlock`会让多数参数测试变绿却继续把root directive或concise body
  留在统一prepend路径。但`js_parse_function_class_fields_init`创建的synthetic aggregator明确保持scope0、无普通body push；parsed
  static-block child有body，aggregator调用它时另有wrapper scope。body身份来自真实producer/event，不来自literal scope0或一个无bytecode
  consumer的`body_scope`字段，也不能把aggregator例外抹平为“更统一”。
- **声明carrier与VarDef append顺序都只能有一个真源。** top-level/module/eval function由`GlobalVar.cpool_idx`驱动；
  恒被skip的child补发loop也会掩盖producer错误，必须删除。Annex-B block function先建lexical binding、child完成后再建/复用
  outer var；ordinary body `var`也不得由预扫描整体前置。索引目标同步自洽不等于append provenance对齐。
- **open-binding index也来自 provenance。** `capture_var` 在第一次 capture事件上编号；把所有 vars再 args
  分组编号，即使随后 closure表看似可 remap，也已改变 parent index、cell alias与 OOM顺序。
- **atom 相等不等于 binding use。** string literal、property key、`set_name` 与 identifier 可共享 atom；
  forward capture 只能由 scope-resolution opcode/已解析 capture 驱动，不能扫描未分类 atom side table。
- **类型判定只读 closure type，表序承载可见性。** 历史`source_depth=max`可能来自经REF传播的MODULE_DECL，
  用它猜global会漏module live binding；该字段现已从zjs compile/final closure全部删除。派生depth不得代替
  `ClosureType`，也不得重新进入FunctionDef/FB来补偿错误表序。
- **正确的consumer顺序不能抵消错误的producer集合。** dynamic eval first-match只有在row确实代表可见路径时才正确；
  把outer `<var>`预先灌入所有后代，会在resolver看到近侧lexical之前就制造错误候选。必须分别锁定
  `add_eval_variables`的“自身direct eval全可见capture”和`resolve_scope_var`的“未解析名字实际跨越才转发”，
  禁止用blanket propagation + reorder/depth修补。
- **非空指针切片是设计选择，不是 Zig 限制。** 若 qjs module link 需要暂时为空的 import slots，应使用
  optional staging/link plan，link 完再 seal typed refs；不能因当前 `[]*VarRef` 不容 null 而改变链接阶段。
- **本轮没有“规范/test262优于QuickJS”的成功语义例外。** 历史三项必须按pinned QuickJS重判：same-body function-name
  `var + eval`已经回到`undefined`；ordinary descendant direct eval仍是红灯，需把转发行归一为ordinary kind并得到`false / false`；
  simple-catch同名direct-eval `var`仍是红灯，需删除额外第二target并锁定QJS declaration/initializer顺序。test262与规范证据继续记录，
  但不改变本计划的目标。唯一可接受的实现差异是有具体证据的Zig/LLVM/ABI或内存安全约束，且必须证明可观察行为和所有权等价。
- **复合 benchmark 必须最小化。** for-of 同时混入 cell/property/arith；push/pop 混入
  lookup/call/length。症状比值不能直接给机制排功劳。
- **占用不等于承载。** profile self% 只是入口；要追值是否进入间接跳转、依赖 load、allocator
  或关键 store/load 链。
- **cycles 可以在 instructions 下降时回退。** branch miss、L1I、前端布局和寄存器压力是真实
  成本，不称“幻影”。
- **热源码共享可能改变 codegen。** 历史 shared template/scalar ABI/extra state 多次导致其他
  shape 回退；抽象更整洁不自动等于热路径更好。
- **失败刀是边界证据。** 没有新事实就不重跑；负结果用于缩小搜索空间。
- **少 instructions 不自动形成 cycles 收益。** M-CELL read split 在 plain read 上少约 1.26%
  instructions，cycles 仍为 1.000x，并把 put/set controls 推到约 +1.2%；以后先看关键链和布局，
  不把静态分支删除当成果。
- **状态先审计。** shape unique arm、Array.push fast arm、多族 peephole 已完成却被旧计划重列，
  此后每个计划项必须先经 `git blame/log + 当前源码` 双确认。
- **已关闭的 allocation 差异不用历史 profile 复活。** page geometry 已移到惰性 refresh，
  class metadata 已是 pointer-only view；88B copy候选只有当前HEAD调用链/汇编再次证明仍存活才可重开。但pointer view跨GC/realloc的lifetime属于
  M-CLASS-RECORD-LIFETIME correctness前置，不能被“性能已关闭”遮掉，也不能借修lifetime恢复整record copy后申报收益。
- **迁移一个机制要同时迁移 metadata、resolution action 与初始化。** `6fdaf1be` 正确对齐了 qjs
  lazy named-function self-binding 的 materialization/prologue，获得了真实调用收益，但保留了旧 zjs
  的 scope-linked、unconditional-const 形状和 runtime function-name write workaround；因此漏掉定义侧
  strict、sloppy drop/dummy-ref、参数环境 fallback。今后不能以“分配时机已相同”宣告机制完成。
- **QuickJS 的特殊 binding 不是普通 scope var。** `add_func_var` 明确调用 `add_var`，解析优先级在
  ordinary scope/var/arg 之后；zjs 若因内部表示采用等价 helper，必须用参数默认值、shadow、eval、
  with 和 nested closure 证明相同优先级，不能把 scope 0 当作近似替代。
- **拓扑相同不等于机制相同。** shape 三臂虽都存在，cache key 的 `prop_size` 条件和命中后的
  storage reconciliation 仍可不同；必须比较 eligibility、动作和失败回滚。
- **成功输出相同不等于 prologue 同构。** 参数默认值 probe当前可能与 qjs同为 `undefined`/`ReferenceError`，
  但 hoist若没有锚在 body `enter_scope`，allocation/GC/OOM及 final bytecode仍不同。
- **忠实成功路径不要求复制 reference 的失败缺陷。** qjs个别 OOM路径忽略错误或非事务化；GUIDE要求的
  Zig错误传播、rollback与 same-runtime recovery是明确安全约束，必须作为有名字的允许偏离记录。
- **最终 bytecode 优先于 pass 位置。** parser 提前发同一 short opcode 不算缺失；反之 opcode
  名字存在也不证明对应 peephole 可达。
- **所有权、异常和恢复不是冷得可以忽略。** OOM、GC、Proxy、getter、realm、backtrace、
  interrupt 和 abrupt teardown 是机制的一部分，不能在性能路径里伪装成 unreachable。

计划的最终完成标准不是所有 ratio 强行到 1.0，而是：每个高占用残差要么被一个忠实的
QuickJS 机制消除，要么有可复核的 Zig/ABI/布局地板证明，并且没有通过特性 fast path、
测试弱化或不可审计的最小值制造“完成”。
