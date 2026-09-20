# 11 — 同机调用与小函数内联（`inline_calls.zig` / `small_inline.zig`）

`inline_calls` 是 **同一 `runDispatchLoop` 里** 的字节码→字节码入帧/拆帧，对应 qjs `JS_CallInternal` 对 `OP_call` 的「push frame 继续跑」而不是递归 `runWithArgsState`。只有普通 kind、非 class constructor、同 Realm 走这条；其余仍走递归慢路径，两者共享帧构造原语。

`small_inline` 是另一件事：把合格 callee **展开进 caller 的专用字节码副本**（OPT-R10）。不是 Entry、不是 PTC、也不是已删的 simple-field constructor bypass。门限 K=40 / D=2 / M=8 / 每 caller ≤4 份副本。L1 `fn.apply(this, arguments)` 改写成 `call_method_apply_fwd`。

## `inline_calls.zig` 类型

`RegionLayout`：`plain` = `[callable, args…]`；`method` = `[receiver, callable, args…]`。

`LeafThis`：`sloppy_global` / `raw_undefined` / `receiver` — 空叶帧的 this 臂，对齐 qjs 只在 `OP_push_this` 才看 strict。

`InlineTarget` / `ResolvedInlineFunction`：从栈上 callable 解析出的同机目标（`fb`、captures、`CallFacts`、raw this）。

`ReturnAction`：`next / proxy_get / for_of_next / to_boolean / constructor / native_boundary / async_complete`。

`Entry`（**256 字节** comptime 钉死）：一帧的 `Frame+Stack+catch_target+arena_mark+teardown flags+continuation+native_caller+prev`。`prev==null` 表示调用者是 L0，对齐 `JSStackFrame.prev_frame`。

`ExecutionLevel`：`frame/stack/catch_target` 借用束。`L0State`：根层政策（eval/generator stop/module await）。

`Machine`：`top/depth/l0/pending_call_region` + **驻留 `tailcall_dispatch.Vm`**。`init` 时 `vm.initResident`；每次 `runTC` 只写 per-level 字段。

`ActiveInvocation`：header 在偏移 0，给 core 的 `traceRoots` 看，不让 core 学会 VM 布局。

`NativeBoundaryScope` / `IdleBoundaryScope`：native→JS 同步回调事务。前者快照 `Vm.EntryState` 与预算；depth-0 宿主调用用瘦的 Idle 版。

`LeanFrame`：站点拥有的瘦 native-boundary 帧，返回走专用 epilogue。

## `small_inline.zig` 类型

`InlinedSite`：展开区间 `pc_lo..pc_hi`、原 `call_pc`、callee FB/原子、this/arg 槽、pc_map、ctor shape 守卫。`CallerState` 存在 FB hot-extension pad。`ApplyForwardCold` 与 site 平行，避免拉宽 `findInlinedSite` 步距。

## `src/exec/inline_calls.zig` 函数

### `resetMachineTestMetrics` (`src/exec/inline_calls.zig:43`)

- **签名**：`pub fn resetMachineTestMetrics() void`。
- **作用**：把 `Machine` 的测试计数器 `MachineTestMetrics`（machine_inits / entry_chunk_allocations / same_machine_sync_calls / same_machine_async_calls / max_depth）整体清零，让每个用例从干净基线开始断言内联入帧行为。
- **实现**：先 `if (!builtin.is_test) @compileError("test-only helper")` 把非测试构建挡在编译期，再把 `TestMetricStorage.metrics` 整体赋成默认 `.{}`（五个计数全 0）。`TestMetricStorage` 只在 `builtin.is_test` 时才带 `var metrics`，Release 下是空结构体，所以这个 `@compileError` 同时也是防止引用不存在字段的守卫。
- **所有权 / 错误 / 调用**：错误：不返回错误；非 `is_test` 构建直接 `@compileError("test-only helper")`。所有权：只把 comptime 静态 `TestMetricStorage.metrics` 归零，不分配、不涉及 GC 根。调用：仅测试树 `src/tests/exec.zig`（25 处，如 `:650`、`:747`、`:821`），生产路径没有调用方。

### `machineTestMetrics` (`src/exec/inline_calls.zig:48`)

- **签名**：`pub fn machineTestMetrics() MachineTestMetrics`。
- **作用**：读出当前累计的 `Machine` 内联入帧计数快照，供测试断言「走了几次同机同步调用」「开了几块 Entry chunk」「逻辑深度峰值多少」。
- **实现**：同样以 `if (!builtin.is_test) @compileError("test-only helper")` 拒绝非测试构建，然后按值 `return TestMetricStorage.metrics`——返回的是结构体副本而非指针，调用方之后的计数不会回写到这份快照。
- **所有权 / 错误 / 调用**：错误：无；非 test 构建同样 `@compileError`。所有权：按值返回计数器快照，调用方不持有任何指针。调用：仅测试树 `src/tests/exec.zig`（27 处断言点），生产路径没有调用方。

### `recordSameMachineSyncCall` (`src/exec/inline_calls.zig:53`)

- **签名**：`pub inline fn recordSameMachineSyncCall() void`。
- **作用**：在同机（不递归进新 `runWithArgsState`）的同步调用真正成立时打一次点，用于测试确认某条调用形态确实走了 `Machine` 入帧而不是退回递归慢路径。
- **实现**：单行 `if (comptime builtin.is_test) TestMetricStorage.metrics.same_machine_sync_calls += 1;`——判定是 `comptime` 的，所以非测试构建下整个函数体被编译掉，是空的 `inline fn`，热路径上零代价。
- **所有权 / 错误 / 调用**：错误：无。所有权：只在 test 构建自增静态计数器，Release 下函数体为空。调用：`src/exec/call_runtime.zig:528`、`:573`、`:601`——同机同步调用的三条 route（moved / copied-args / moved-args）各记一次。

### `InlineTarget.captureSlice` (`src/exec/inline_calls.zig:107`)

- **签名**：`pub inline fn captureSlice(self: InlineTarget) []*core.VarRef`。
- **作用**：把 `InlineTarget` 里以裸 `[*]*core.VarRef` 形式保存的闭包 capture 指针，按目标函数真正的闭包变量个数收成切片，供建帧时拷进 `Frame`。
- **实现**：一行 `return self.var_refs[0..self.fb.closureVarCount()]`：长度不存在 `InlineTarget` 里，每次从不可变的 `fb` 重新取 `closureVarCount()`，这样目标解析阶段只需搬一个指针，长度与 FunctionBytecode 保持单一真相。
- **所有权 / 错误 / 调用**：错误：无。所有权：返回借用视图，backing 是 callable 的 `BytecodeFunctionStorage.var_refs` 数组，调用方不得释放，其存活由 callable 自身的 GC 可达性保证。调用：本文件建帧点 `target.captureSlice()` 共 11 处（`src/exec/inline_calls.zig:1265`、`:1850`、`:3210` 等）；`function_data.captureSlice()` 形态的命中属同名的 `BytecodeFunctionStorage.captureSlice`，不是本函数。

### `ResolvedInlineFunction.bind` (`src/exec/inline_calls.zig:122`)

- **签名**：`pub inline fn bind(self: ResolvedInlineFunction, receiver: core.JSValue, func: core.JSValue) InlineTarget`。
- **作用**：把「解析出可内联函数」和「这次调用的 this 与 callable 值」两件事合成建帧要用的 `InlineTarget`：解析结果只依赖 callable 对象，可以被站点缓存复用，receiver 每次调用才知道。
- **实现**：构造并返回一个结构体字面量：`var_refs`/`fb`/`call_facts` 从 `self` 原样搬过来，`callable` 取参数 `func`，`this_value` 取参数 `receiver`。没有任何检查或解引用——合法性已经在 `resolveInlineFunction*` 一侧判完。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯字段搬运——`fb` 与 `var_refs` 仍归 callable，`receiver`/`func` 是借用的 `JSValue`，不 retain 也不建根。调用：所有「解析成功后绑定 this」的调用点共 16 处，如 `src/exec/tailcall_dispatch.zig:920`、`src/exec/call_site.zig:319`、`src/exec/inline_calls.zig:295`。

### `resolveInlineFunction` (`src/exec/inline_calls.zig:136`)

- **签名**：`pub inline fn resolveInlineFunction(global: *core.Object, func: core.JSValue) ?ResolvedInlineFunction`。
- **作用**：判定一个 `JSValue` callable 能否走同机字节码调用（普通 kind、非 class constructor、同 Realm），能则连带取出 `FunctionBytecode`、capture 数组与 `CallFacts` 快照。
- **实现**：两步：`object_ops.plainBytecodeFunctionObjectFromValue(func)` 先用一次比较把非字节码函数、generator/async 这些独立 class 的 callable 全部筛掉（注释标注对齐 qjs `JS_CallInternal`，quickjs.c:17816：qjs 在这里就落到慢路径，而不是先过四类集合测试再被 kind 检查驳回）；通过后转交 `resolveInlineFunctionFromObject` 做 kind / entry 策略 / Realm global 三项检查。
- **所有权 / 错误 / 调用**：错误：不返回错误；任何不合格条件都返回 null，调用方据此退到通用 [[Call]]。所有权：纯读，不分配；返回的 `ResolvedInlineFunction` 借用 `FunctionBytecode` 与 capture 数组。调用：`src/exec/host_invocation.zig:219`、`src/exec/call_site.zig:318` 与 `:490`、`src/exec/tailcall_dispatch.zig:2898`，以及本文件 `resolveInlineTargetInto`（`:294`）。

### `resolveInlineFunctionFromObject` (`src/exec/inline_calls.zig:150`)

- **签名**：`pub inline fn resolveInlineFunctionFromObject(global: *core.Object, function_object: *core.Object) ?ResolvedInlineFunction`。
- **作用**：对一个已经拿到的函数对象做同机调用准入：普通 kind、不被 entry 策略拒绝、与当前 global 同 realm，通过则带回 FB、capture 数组与 `CallFacts` 快照。
- **实现**：读 bytecode arm 的 FB 与 raw captures；kind 必须 normal；derived/entry_rejects_plain_call 拒绝；Realm global 必须等于当前 global。成功带回 `CallFacts` 快照。
- **所有权 / 错误 / 调用**：错误：无；无 `function_bytecode`、`functionKind() != .normal`、realm 与 `global` 不符都返回 null。所有权：纯读；返回的 `var_refs` 裸指针借自 callable 的 storage，Debug 下与 `captureSlice()` 对账。调用：`src/exec/tailcall_dispatch.zig:919`（方法调用臂）、`:1232`、`:2353`、`:5878`、`:1995`，以及本文件 `resolveInlineFunction`（`:142`）。

### `resolveNoSuspendAsync` (`src/exec/inline_calls.zig:195`)

- **签名**：`pub fn resolveNoSuspendAsync(ctx: *core.JSContext, global: *core.Object, func: core.JSValue) ?InlineTarget`。
- **作用**：判定一次 async 函数调用能否当成「保证不挂起」的同机调用来跑——即它的编译期策略是 `no_suspend`，于是不必真的建 generator 状态机。
- **实现**：先拒绝装了中断处理器的 runtime（`ctx.runtime.hasInterruptHandler()`），再 `object_ops.objectFromValue` 取对象并要求 `class_id == async_function`、`fb.functionKind() == .async`、canonical hot extension 的 `async_execution_policy == no_suspend`、`fb.realmContext().global == global`；通过则返回 `this_value = undefined` 的 `InlineTarget`。
- **所有权 / 错误 / 调用**：错误：无；装了 interrupt handler、类不是 `async_function`、策略不是 `no_suspend`、realm 不符都返回 null。所有权：纯读，`InlineTarget` 借 callable 的 fb 与 captures。调用：只有 `src/exec/tailcall_dispatch.zig:2205`、`:2223` 两处（`region[0]`/`region[1]` 两个 callee 位置）。

### `resolveInlineDirectConstructorFunction` (`src/exec/inline_calls.zig:217`)

- **签名**：`pub inline fn resolveInlineDirectConstructorFunction(global: *core.Object, func: core.JSValue) ?ResolvedInlineFunction`。
- **作用**：宿主直接 `construct`（无 spread）时的内联准入：判定目标构造器能否在同机建帧执行。
- **实现**：自己展开一遍取数（`plainBytecodeFunctionObjectFromValue` → `bytecodeFunctionStoragePtr` → `function_bytecode`，缺一返回 null），`var_refs` 直接 `@ptrCast` 成裸指针，Debug 下用 `function_data.captureSlice()` 断言长度等于 `fb.closureVarCount()`、指针一致。准入条件与 `resolveInlineFunctionFromObject` 的差别只有一处：kind 仍须 `.normal`，但 `call_facts.execution.entry_rejects_plain_call` 只在**非** derived class constructor 时才拒绝，于是 derived 构造器在这里被接纳、base class 构造器仍被拒；最后 `fb.realmContext().global` 必须等于传入的 `global`。
- **所有权 / 错误 / 调用**：错误：无，返回 null 即退回通用 construct 路径。所有权：纯读，不分配。调用：唯一调用方 `src/exec/call_runtime.zig:2007`（宿主直接 construct 的内联准入）。

### `resolveInlineSpreadConstructorFunction` (`src/exec/inline_calls.zig:245`)

- **签名**：`pub inline fn resolveInlineSpreadConstructorFunction(global: *core.Object, func: core.JSValue) ?ResolvedInlineFunction`。
- **作用**：带 spread 实参的 `construct` 的内联准入，比直接 construct 更宽：只要是同 Realm 的普通字节码函数就收。
- **实现**：取数与 Debug 断言同 `resolveInlineDirectConstructorFunction`，但只检查两件事：`fb.functionKind() == .normal`，以及 `fb.realmContext().global == global`。既不看 `isDerivedClassConstructor` 也不看 `entry_rejects_plain_call`——spread 路径带着真的 `new.target` 进入，base-class 函数体是由 `super(...args)` 到达的，不存在被当成普通调用误入的风险。返回值里的 `call_facts` 现取 `fb.canonicalCallFacts()`。
- **所有权 / 错误 / 调用**：错误：无，返回 null 即退回通用 construct。所有权：纯读，不分配。调用：唯一调用方 `src/exec/call_runtime.zig:2027`（带 spread 的 construct 准入）。

### `resolveInlineTarget` (`src/exec/inline_calls.zig:277`)

- **签名**：`pub inline fn resolveInlineTarget(global: *core.Object, receiver: core.JSValue, func: core.JSValue) ?InlineTarget`。
- **作用**：`resolveInlineTargetInto` 的按值封装：给只想要「可内联就拿 `InlineTarget`，否则 null」的调用点用。
- **实现**：栈上开一个 `undefined` 的 `InlineTarget`，交给 `resolveInlineTargetInto` 就地填写；返回 false 则原样返回 null，true 则把填好的结构体按值返回。之所以保留 into 版本，是因为热调用点希望把 `InlineTarget` 直接写进自己已有的槽，省掉这次按值搬运。
- **所有权 / 错误 / 调用**：错误：无；不可内联返回 null。所有权：按值返回 `InlineTarget`，内部引用全部借用，不分配。调用：`src/exec/vm_call.zig:567` 与 `:780`、`src/exec/tailcall_dispatch.zig:4793`（getter）与 `:4896`（proxy trap）、`src/exec/call_runtime.zig:106`、`src/exec/eval_ops.zig:283`。

### `resolveInlineTargetInto` (`src/exec/inline_calls.zig:285`)

- **签名**：`pub inline fn resolveInlineTargetInto( target: *InlineTarget, global: *core.Object, receiver: core.JSValue, func: core.JSValue, ) bool`。
- **作用**：解析加绑定一步到位：判定 callable 可否同机内联，可以就把结果连同 receiver 就地写进调用方给的 `InlineTarget` 槽，省掉一次按值返回的结构体搬运。
- **实现**：`resolveInlineFunction(global, func)` 失败返回 false，成功则 `target.* = resolved.bind(receiver, func)` 并返回 true。（两个函数原先都带一个只为签名对称保留的 `ctx: *core.JSContext` 首参，已连同全部调用点删除。）
- **所有权 / 错误 / 调用**：错误：无，返回 false 表示不可内联。所有权：把结果就地写进调用方栈上的 `target`，不分配。调用：`src/exec/call_runtime.zig:491` 与本文件 `resolveInlineTarget`（`:280`）。

### `ReturnContinuation.deinit` (`src/exec/inline_calls.zig:328`)

- **签名**：`pub fn deinit(self: *ReturnContinuation, _: *core.JSRuntime) void`。
- **作用**：把 continuation 记录复位成 `.next`/0。
- **实现**：无条件 `self.action = .next; self.payload = 0`。（原先前面还有一条 `if (self.action == .proxy_get and self.payload != core.atom.null_atom) {}` 的空分支——tracing GC 之后 atom 不再需要释放，这条判断已删。）
- **所有权 / 错误 / 调用**：错误：无。所有权：`proxy_get` 的 atom payload 由 tracer 拥有、不需要释放，函数只把 `action`/`payload` 复位；`*JSRuntime` 形参未用（保留以对齐 deinit 家族签名）。调用：`src/exec/inline_calls.zig:1394`、`:5168`、`:5192`、`:5223`——`Machine` 重定向与丢弃续延的四处。

### `ReturnContinuation.takeAtom` (`src/exec/inline_calls.zig:334`)

- **签名**：`pub fn takeAtom(self: *ReturnContinuation) core.Atom`。
- **作用**：把 `.proxy_get` continuation 里寄存的属性 atom 取走并让记录侧放手，好让返回臂拿它去补完那次代理读。
- **实现**：断言 `action == .proxy_get` 且 `payload != null_atom`，把 `payload` 窄化成 `core.Atom` 返回，随后把 `payload` 写 0（`action` 不动）：所有权已经交给调用方，原槽不再指向该 atom。
- **所有权 / 错误 / 调用**：所有权：atom 的所有权随返回值移交调用方，记录侧不再持有。 错误：无，只有 Debug/Safe 断言。 调用：`tailcall_dispatch.zig:7172` 的 `.proxy_get` continuation 分支，取到的 atom 直接喂给 `completeProxyGetContinuation`。

### `ReturnContinuation.takeForOfDepth` (`src/exec/inline_calls.zig:342`)

- **签名**：`pub fn takeForOfDepth(self: *ReturnContinuation) u8`。
- **作用**：取出 `.for_of_next` continuation 里寄存的 for-of 迭代器栈深度，供返回臂定位该循环在栈上的迭代器记录。
- **实现**：断言 `action == .for_of_next`，把 `payload` 窄化成 `u8` 的 for-of 迭代器栈深度返回，再把 `payload` 写 0。
- **所有权 / 错误 / 调用**：所有权：`u8` 深度是纯数值，没有要释放的资源。 错误：无。 调用：`tailcall_dispatch.zig:7173` 的 `.for_of_next` 分支（→ `completeForOfNextContinuation`），以及 `Machine` 展开路径 `inline_calls.zig:5189`/`5220`。

### `Entry.takeContinuation` (`src/exec/inline_calls.zig:423`)

- **签名**：`fn takeContinuation(self: *Entry) ReturnContinuation`。
- **作用**：在这一帧释放资源之前，把「返回之后还要做什么」（`return_action` + `continuation_payload`）搬出 Entry，交给返回臂去执行。
- **实现**：构造 `ReturnContinuation{ .action = self.return_action, .payload = self.continuation_payload }` 返回。刻意**不**清零 Entry 上的两个字段：函数注释说明清零只会给每次普通返回多加两条 store，退役槽保留失效位、等下一次 push 初始化即可。
- **所有权 / 错误 / 调用**：错误：无。所有权：按值复制走 `return_action` 与 `continuation_payload`，Entry 上的原字段不清零，由随后的 teardown/复用负责。调用：本文件三条 pop 路径 `src/exec/inline_calls.zig:4783`、`:4839`、`:4870`。

### `Entry.isEmptyLeaf` (`src/exec/inline_calls.zig:430`)

- **签名**：`pub inline fn isEmptyLeaf(self: *const Entry) bool`。
- **作用**：问这一帧是不是「空叶帧」——零实参、无栈区、无 catch、按最短尾声退役的那一类内联帧。
- **实现**：单个位域读 `return self.teardown.empty_leaf`。该位在 `pushEmptyLeafCall` 的建帧点写入，返回分派靠这一位就能选中最便宜的那条 epilogue，不必再探 args 长度或栈窗口。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `teardown` 位域，无副作用。调用：`src/exec/tailcall_dispatch.zig:1579` 的返回分派，以及本文件断言/路由 `:486`、`:491`、`:4487`、`:4998`。

### `Entry.isExactArgsLeaf` (`src/exec/inline_calls.zig:434`)

- **签名**：`pub inline fn isExactArgsLeaf(self: *const Entry) bool`。
- **作用**：问这一帧是不是「精确实参叶帧」：与空叶帧同样的暖建帧和单条 ldp 恢复记录，但多一个位于 caller 区的实参窗口，返回尾声要负责释放其中的值。
- **实现**：单个位域读 `return self.teardown.exact_args_leaf`。之所以另立一位而不复用 `empty_leaf` 加长度判断，是要让既有的零参返回臂保持「一个位测试」的精确形态（见字段注释：argc==0 叶家族上不做 args len 探测）。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `teardown` 位域。调用：`src/exec/tailcall_dispatch.zig:1632`（栈空的精确实参叶臂），本文件断言 `:486`、`:491`、`:4487`、`:5028`。

### `Entry.isForwardedLeaf` (`src/exec/inline_calls.zig:438`)

- **签名**：`pub inline fn isForwardedLeaf(self: *const Entry) bool`。
- **作用**：问这一帧是不是 `Function.prototype.call` 透明转发出来的叶帧——即帧上挂着一条合成的 native `call` 记录、返回要走非普通路径的那种。
- **实现**：两位与：`teardown.special_return and teardown.has_native_caller`。`special_return` 只说明「返回要离开普通 `.next` 路径」，同步 native 栅栏也会置它；靠 `has_native_caller` 把转发叶从栅栏里分出来（字段注释明写这条区分规则）。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读两个 teardown 位。调用：`src/exec/tailcall_dispatch.zig:1697`、`:1783`，本文件 deinit 路由 `:614`、`:832` 与断言 `:508`、`:706`、`:4487`、`:5057`。

### `Entry.hasSpecialReturn` (`src/exec/inline_calls.zig:442`)

- **签名**：`pub inline fn hasSpecialReturn(self: *const Entry) bool`。
- **作用**：问这一帧返回时是否必须离开普通 `.next` 续跑路径（转发叶或同步 native 栅栏两者之一）。
- **实现**：单个位域读 `return self.teardown.special_return`。这一位复用了原本的冷返回测试，返回分派先用它把普通 Entry 返回留在原有的精确分支序列上，命中后才继续区分是哪一种特殊返回。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `teardown.special_return`。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:1765`（特殊返回分派）。

### `Entry.isNativeBoundaryReturn` (`src/exec/inline_calls.zig:446`)

- **签名**：`pub inline fn isNativeBoundaryReturn(self: *const Entry) bool`。
- **作用**：问这一帧是不是 native→JS 同步栅栏帧：返回要交还给宿主，而不是继续跑 caller 的字节码。
- **实现**：三项与：`teardown.special_return` 为真、`teardown.has_native_caller` 为假（排除 `Function.call` 转发叶）、且 `return_action == .native_boundary`。前两位来自同一个 teardown 字节，第三项才读 `return_action`。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 teardown 位与 `return_action`。调用：`src/exec/tailcall_dispatch.zig:1571`、`:1778`，本文件 `:5080`（`popReturnedNativeBoundary` 前的判定）与 `:4934` 断言。

### `Entry.isLeanBoundaryReturn` (`src/exec/inline_calls.zig:455`)

- **签名**：`pub inline fn isLeanBoundaryReturn(self: *const Entry) bool`。
- **作用**：问这一帧是不是站点自有的瘦 native-boundary 帧（`LeanFrame`）——那种由专用 epilogue 退役的形状。
- **实现**：两项与：`return_action == .native_boundary` 且 `continuation_payload == LeanFrame.marker`。函数注释说明该 marker 只会与 `.native_boundary` 一起写入，所以两次 load 就能判定。
- **所有权 / 错误 / 调用**：错误：无。所有权：只比较 `return_action` 与 `continuation_payload == LeanFrame.marker`。调用：`src/exec/tailcall_dispatch.zig:1912`、`:1938` 两处 lean 帧返回臂的否定断言。

### `Entry.completesConstructor` (`src/exec/inline_calls.zig:460`)

- **签名**：`pub inline fn completesConstructor(self: *const Entry) bool`。
- **作用**：问这一帧返回时是否还要做构造器补完——即按 [[Construct]] 语义决定返回对象还是返回 `this`，并处置急切创建的兜底实例。
- **实现**：单个位域读 `return self.teardown.constructor_completion`。按字段注释，这一位为真时：普通构造器的 `native_caller` 槽持有急切兜底实例（帧的 `this` 绑定只是借用），正常完成会把它 move 走、异常完成会释放它；derived 构造器则因为 super 之前没有实例而把该槽留成 undefined。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `teardown.constructor_completion`。调用：`src/exec/tailcall_dispatch.zig:1824`、`:7201`、`:7206`，本文件 `:5084`。

### `Entry.emptyLeafResumeWords` (`src/exec/inline_calls.zig:474`)

- **签名**：`inline fn emptyLeafResumeWords(self: *Entry) *[2]usize`。
- **作用**：把 Entry 的 `native_caller` 槽重解释成两个 usize 字，给空叶帧存放 {resume pc, resume sp} 记录。
- **实现**：comptime 断言 `@sizeOf(core.JSValue) == 2 * @sizeOf(usize)`，然后 `@ptrCast(@alignCast(&self.native_caller))`。
- **所有权 / 错误 / 调用**：错误：无（只有 comptime 断言 `JSValue` 恰为两个字宽）。所有权：把 `native_caller` 槽重解释为两个 `usize`，不分配；空叶帧期间该槽不作为 JSValue 被扫描。调用：私有，只有本文件 `:480`（`setEmptyLeafResume`）、`:487`、`:492` 两个读取器。

### `Entry.setEmptyLeafResume` (`src/exec/inline_calls.zig:480`)

- **签名**：`pub inline fn setEmptyLeafResume(self: *Entry, resume_pc: [*]const u8, resume_sp: [*]core.JSValue) void`。
- **作用**：把调用方的 resume `{pc, sp}` 一次性写进叶帧里那 16 字节的死槽，供返回臂一条 `ldp` 取回。
- **实现**：先断言 `!teardown.has_native_caller`——被复用的正是 `native_caller` 那 16 字节；再经 `emptyLeafResumeWords()` 取到 `*[2]usize` 视图，把 `resume_pc`、`resume_sp` 两个指针 `@intFromPtr` 后写进 words[0]/words[1]。三个叶构造尾各调一次：`finishEmptyLeafFrame`（2658）、exact-args 尾（2759）、capture-leaf 尾（2826）；落到 heap-fallback（非叶）形状时这两个字是死字节，通用返回路径不读。
- **所有权 / 错误 / 调用**：所有权：只存裸指针，不持有任何对象。 错误：无。 调用：三个叶帧发布尾；读方是 `tailcall_dispatch.zig` 的叶返回臂。

### `Entry.emptyLeafResumePc` (`src/exec/inline_calls.zig:487`)

- **签名**：`pub inline fn emptyLeafResumePc(self: *Entry) [*]const u8`。
- **作用**：取回调用方的续跑字节码指针，即叶帧返回后要执行的下一条指令地址。
- **实现**：断言 `isEmptyLeaf() or isExactArgsLeaf()`，从 `emptyLeafResumeWords()[0]` `@ptrFromInt` 还原 `[*]const u8`。返回臂（`tailcall_dispatch.zig:1596`/`1659`）刻意先读这一对，再做拆除，好让调用方的下一次分发装载不必等 `prev→frame.function→code.ptr→(+frame.pc)` 那条重导出链。
- **所有权 / 错误 / 调用**：所有权：借用，指向调用方 `FunctionBytecode` 的 code 缓冲区。 错误：无。 调用：`tailcall_dispatch.zig` 的两处叶返回臂。

### `Entry.emptyLeafResumeSp` (`src/exec/inline_calls.zig:492`)

- **签名**：`pub inline fn emptyLeafResumeSp(self: *Entry) [*]core.JSValue`。
- **作用**：取回调用方的续跑栈顶指针，即这次调用的参数区起点（`region_start`）。
- **实现**：断言 `isEmptyLeaf() or isExactArgsLeaf()`，从 `emptyLeafResumeWords()[1]` `@ptrFromInt` 还原 `[*]core.JSValue`。叶返回臂用它取代 `stack→top_ptr` 的重导出：调用方的栈顶就是当初被调用方参数窗口的起点，返回值写在这里。
- **所有权 / 错误 / 调用**：所有权：借用，指向调用方 Stack 的 backing。 错误：无。 调用：`tailcall_dispatch.zig:1597`/`1660`。

### `Entry.tailChainBudgetSlot` (`src/exec/inline_calls.zig:506`)

- **签名**：`inline fn tailChainBudgetSlot(self: *Entry) *TailChainBudget`。
- **作用**：把尾调用链累计的深度/字节预算安放在通用帧里那 16 字节没人用的 `native_caller` 槽上，让 Entry 的实测布局不因尾调用记账而变大。
- **实现**：四条 Debug 断言先钉死这个 Entry 的形状——`!has_native_caller`、`!empty_leaf`、`!exact_args_leaf`、`!isForwardedLeaf()`，即它确实是不带合成 `Function.call` 记录的通用帧，那 16 字节是死的；两条 comptime 断言确认 `core.JSValue` 的大小与对齐都容得下 `TailChainBudget{extra_depth, planned_stack_bytes}`；最后 `@ptrCast(@alignCast(&self.native_caller))` 把该槽重解释成 `*TailChainBudget`。
- **所有权 / 错误 / 调用**：所有权：不分配，只是同一块字节的另一种解释；写入方与读取方都在尾调用替换路径内。 错误：无。 调用：`replaceTopFrameForTailCall` 一族——4758/4943 读被退役帧继承的预算，4792 在 `.chain` 分支写入 `extra_depth + 1` 与累加后的 `planned_stack_bytes`，4863 在释放腿取回。

### `Entry.adoptContinuation` (`src/exec/inline_calls.zig:517`)

- **签名**：`fn adoptContinuation(self: *Entry, continuation: *ReturnContinuation) void`。
- **作用**：尾调用复用一个已有 Entry 的存储时，把被替换帧的 continuation 接管过来，让最终 callee 返回时仍执行原来那份调用后工作。
- **实现**：断言当前 `return_action == .next` 且 payload 为 0；把 continuation 的 action 搬进来，payload 在 `.native_boundary` 时写 0（丢掉 lean pop marker）否则原样搬入，`.native_boundary` 还要置 `teardown.special_return`；最后把来源 continuation 复位成 `.next`/0。
- **所有权 / 错误 / 调用**：错误：无；前置 `assert` 要求目标 Entry 的续延还是初始 `.next`/0。所有权：move 语义——把续延的 action/payload 转移到 Entry 后把源 `ReturnContinuation` 清成 `.next`/0，`native_boundary` 的 lean marker 被丢弃并改置 `teardown.special_return`。调用：唯一调用方 `src/exec/inline_calls.zig:4784`（尾调用复用同一 Entry 的存储时）。

### `Entry.isOrdinaryReturn` (`src/exec/inline_calls.zig:590`)

- **签名**：`pub inline fn isOrdinaryReturn(self: *const Entry) bool`。
- **作用**：一次性判定这一帧是不是「什么特殊事都没有」的普通返回帧——没有任何 completion/特殊返回位、是 simple 形状、续延是 `.next`；命中后返回分派就能走最短的一条 epilogue。
- **实现**：把 `teardown` 整字节 `@bitCast` 后与 `extended_completion_flags` 相与，非 0 即返回 false；再要求 `teardown.simple` 且 `return_action == .next`。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `teardown` 字节与 `return_action`。调用：`src/exec/tailcall_dispatch.zig:1559` 的返回分派首臂，本文件断言 `:753`、`:4891`。

### `Entry.canUseSimpleTeardown` (`src/exec/inline_calls.zig:597`)

- **签名**：`inline fn canUseSimpleTeardown(self: *const Entry) bool`。
- **作用**：判定这一帧能否用便宜的 simple 拆除（只关 open var-ref + 回滚 arena），还是必须走会逐一释放 stack/frame 自有存储的通用拆除。
- **实现**：四项与，全是纯读：`teardown.simple`（建帧时就是 simple 形状）、`frame.cold == null`（运行中没有 materialize `arguments` / new_target 盒子这类冷存储）、`frame.ownership.storage == .borrowed`（帧窗口是借 arena 的、不是自有 slab）、`stack.isArenaWindow()`（操作数栈也还在 arena 窗口里没扩过容）。任一条不成立就说明帧在运行中长出了自有存储，simple 尾声不能用。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 teardown/frame/stack 的四个条件位，不改状态。调用：私有，只在本文件——deinit 家族路由 `:616`、`:767`、`:801`、`:834`、`:4953`，以及断言 `:736`、`:754`、`:4980`。

### `Entry.deinit` (`src/exec/inline_calls.zig:607`)

- **签名**：`inline fn deinit(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：continuation 已被移走之后的「异常 / 尾调用替换」拆除腿：空布局的帧在 opcode 抛出时仍可能留着活操作数，所以这里必须保留权威的 Stack/Frame 清理，不能用正常返回的叶尾声。
- **实现**：`empty_leaf`/`exact_args_leaf`/`isForwardedLeaf()` 三种叶形态一律走 `deinitGeneral`（它们的 `frame.locals` 是空切片，不满足 `deinitSimple` 的 live_values 推导）；否则 `canUseSimpleTeardown()` 走 `deinitSimple`，再否则 `deinitGeneral`。
- **所有权 / 错误 / 调用**：所有权：释放这个 Entry 拥有的帧存储、操作数栈与绑定；continuation 必须已被 `takeContinuation` 移走。 错误：无。 调用：`deinitReturned`（633）的通用回退腿、通用 push 中途失败的 `errdefer`（3584/3649）、尾调用替换退役被替换帧时（4843/4874）。

### `Entry.deinitReturned` (`src/exec/inline_calls.zig:631`)

- **签名**：`inline fn deinitReturned(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：正常返回时的拆除入口：先试最窄的空叶尾声，不合格再退回通用 `deinit`。
- **实现**：`teardown.empty_leaf` 且 `stack.len() == 0` 走 `deinitEmptyLeaf(ctx)`，否则回到通用的 `deinit(ctx)`。
- **所有权 / 错误 / 调用**：错误：无。所有权：两条路由都在内部把帧窗口还给 `VmStackArena`（空叶走 `deinitEmptyLeaf`，其余走 `Entry.deinit`），本函数自身不分配。调用：本文件 pop 路径 `src/exec/inline_calls.zig:4841`、`:4872`、`:4956`。

### `deinitEmptyLeaf` (`src/exec/inline_calls.zig:642`)

- **签名**：`noinline fn deinitEmptyLeaf(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：空叶帧正常返回拆除的 outline 包装：驱动侧 `.returned` / falloff 走这里，避免把冷路径装进热 handler。
- **实现**：唯一语句是 `self.deinitEmptyLeafInline(ctx.runtime)`。热 handler 的返回臂直接调 `deinitEmptyLeafInline`，让 arena restore 不经过 bl/ret；本包装把冷消费者（驱动侧 `.returned` / falloff）从 opcode 体里拉开。（源码注释里原先还提到「非零 refcount 腿」与 `destroyZeroRef`，那是 rc 时代的说法，现在函数体里只剩 `rt.vm_stack.restore`，注释已改实。）
- **所有权 / 错误 / 调用**：不另分配。真实释放在 `deinitEmptyLeafInline`：`rt.vm_stack.restore(self.arena_mark)`，不逐值挂 root。错误：无。调用：`Entry.deinitReturned` 在 `teardown.empty_leaf && stack.len()==0` 时。

### `Entry.deinitEmptyLeafInline` (`src/exec/inline_calls.zig:661`)

- **签名**：`inline fn deinitEmptyLeafInline(self: *Entry, rt: *core.JSRuntime) void`。
- **作用**：空叶帧正常返回的最窄尾声本体：这类帧被证明没有实参、局部、capture、open-ref 与操作数，所以除了退还 arena 水位什么都不用做。
- **实现**：先是一串 Debug/Safe 断言把发布契约钉死：`teardown.simple`、无 `has_native_caller`、`frame.cold == null`、`ownership.storage == .borrowed`、`locals`/`args`/`var_refs`/`open_var_refs` 四个切片全空、`stack.isArenaWindow()` 且 `stack.len() == 0`。真正执行的只有一条 `rt.vm_stack.restore(self.arena_mark)`。栈长必为 0 这一条不靠运行期守卫，而靠发布时的静态返回平衡证明 `codeProvesLeafReturnBalance`（解析器省略末尾 drop、switch 判别值残留在栈上的形态一律被拒发 flag）。
- **所有权 / 错误 / 调用**：错误：无（失败条件全是 `assert`：simple、无 native caller、cold 为 null、storage 借用、args/locals/var_refs 全空、栈是 arena 窗口且长度 0）。所有权：空叶帧没有任何自有窗口，只把 `rt.vm_stack` 回滚到 `arena_mark`，成批归还 arena 预算。调用：本文件 `:642`（`deinitEmptyLeaf`）与 `:5013`（pop 的空叶臂）。

### `Entry.deinitExactArgsLeafInline` (`src/exec/inline_calls.zig:683`)

- **签名**：`inline fn deinitExactArgsLeafInline(self: *Entry, rt: *core.JSRuntime) void`。
- **作用**：精确实参叶帧正常返回的尾声：与空叶同构，只是多一个位于调用方区的实参窗口——而那个窗口是借来的，这里同样什么都不用释放。
- **实现**：断言链：`teardown.simple`、`exact_args_leaf` 且非 `empty_leaf`、无 native caller、`frame.cold == null`、`ownership.storage == .borrowed`、`locals.len == 0`、`args.len == frame.function.arg_count`（精确匹配，无补 undefined）、`args.len != 0 or var_refs.len != 0`（否则应归空叶）、`ownership.var_refs == .borrowed`、`open_var_refs.len == 0`、栈是空的 arena 窗口。源码注释点明：继承来的 capture 借自闭包的 cell 数组、永不在此释放，且这种 callee 不可能 CREATE cell。唯一动作仍是 `rt.vm_stack.restore(self.arena_mark)`。
- **所有权 / 错误 / 调用**：错误：无，前置条件全走 `assert`（精确实参叶、无 native caller、locals 空、`args.len == function.arg_count`、var_refs 借用、栈空且在 arena）。所有权：实参窗口与 var_ref 窗口都是借来的，无需逐值释放，只把 `rt.vm_stack` 回滚到 `arena_mark`。调用：唯一调用方 `src/exec/inline_calls.zig:5042`（pop 的精确实参叶臂）。

### `Entry.deinitForwardedLeafInline` (`src/exec/inline_calls.zig:704`)

- **签名**：`inline fn deinitForwardedLeafInline(self: *Entry, rt: *core.JSRuntime) void`。
- **作用**：`Function.prototype.call` 透明转发出来的叶帧的返回尾声——帧上挂着合成 native `call` 记录，但实参窗口是就地借用的，所以尾声仍然只是退还 arena 水位。
- **实现**：断言链：`teardown.simple`、`isForwardedLeaf()` 且非空叶、非精确实参叶、`has_native_caller`、`frame.cold == null`、`ownership.storage == .borrowed`、`locals.len == 0`、`args.len == frame.function.arg_count`、`var_refs` 借用或为空、`open_var_refs.len == 0`、栈是空 arena 窗口。注释对齐 qjs `arg_buf = argv`（quickjs.c:17841）：转发形态就地借用调用方区的实参窗口，那些槽位于调用方已回退的操作数顶之上，帧一解链就是死值。动作只有 `rt.vm_stack.restore(self.arena_mark)`。
- **所有权 / 错误 / 调用**：错误：无，前置条件全是 `assert`（forwarded 叶、有 native caller、非精确实参叶、locals 空、栈空且在 arena）。所有权：转发叶就地借用调用方的实参窗口，不复制也不释放，只回滚 `rt.vm_stack` 到 `arena_mark`。调用：唯一调用方 `src/exec/inline_calls.zig:5067`（pop 的 forwarded 叶臂）。

### `Entry.deinitSimple` (`src/exec/inline_calls.zig:725`)

- **签名**：`inline fn deinitSimple(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：simple 形状帧的完整拆除：资源释放 + arena 水位回滚，两步合一。
- **实现**：两行：`deinitSimpleResources(ctx)` 关掉可能存在的 open var-ref，然后 `ctx.runtime.vm_stack.restore(self.arena_mark)` 把帧窗口成批还给 arena。拆成两个函数是因为尾调用替换只要前半步——被替换的调用方要一直留着自己 alloca 形状的 arena 窗口，直到最终 callee 完成（对齐 qjs 嵌套 `JS_CallInternal` 帧仍存活）。
- **所有权 / 错误 / 调用**：错误：无。所有权：先由 `deinitSimpleResources` 关闭可能存在的 open var-ref，再把 `vm_stack` 回滚到 `arena_mark`；帧窗口本身是 arena 借用，不单独 free。调用：本文件 `:617`（`Entry.deinit` 的 simple 臂）与 `:4954`（pop 的 simple 臂）。

### `Entry.deinitSimpleResources` (`src/exec/inline_calls.zig:734`)

- **签名**：`inline fn deinitSimpleResources(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：释放 simple 帧除 VM 栈水位以外的全部资源：实际只有把逃逸出去的局部变量搬进堆 cell 这一件事。
- **实现**：Debug/Safe 下有不变量断言（`canUseSimpleTeardown()`、var_refs 为 borrowed 或空、locals 紧邻操作数栈基址）。真正的释放动作只有一条：`frame.function.openVarRefCount() != 0` 时 `frame.closeOpenVarRefs(rt)`——按 FB 的发布计数判断，不读 `frame.open_var_refs`。
- **所有权 / 错误 / 调用**：错误：无；`assert` 保证 simple 前提与 locals/stack 相邻布局。所有权：只在 `function.openVarRefCount() != 0` 时调 `frame.closeOpenVarRefs(rt)` 把逃逸变量搬进堆 cell（R-A1：不读 `frame.open_var_refs` 切片，以 FB 计数为准）；不 free 任何窗口，arena 回滚由调用方做。调用：本文件 `:725`（`deinitSimple`）与 `:835`（`deinitForTailReplacement`）。

### `Entry.deinitOrdinarySimpleResources` (`src/exec/inline_calls.zig:751`)

- **签名**：`inline fn deinitOrdinarySimpleResources(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：`isOrdinaryReturn()` 已分类过的帧的资源释放：与 `deinitSimpleResources` 同一套动作、同一顺序，但 native-caller 释放与构造器 fallback 释放两支已被分类证伪，直接删掉。
- **实现**：四条 Debug 断言（`isOrdinaryReturn()`、`canUseSimpleTeardown()`、`var_refs` 为 borrowed 或长度 0、`locals` 紧邻操作数栈基址）之后只剩唯一一条真动作：`frame.function.openVarRefCount() != 0` 时 `frame.closeOpenVarRefs(rt)`——以 FunctionBytecode 的发布计数为准，不读 `frame.open_var_refs` 切片。注释记下动机：被删的两项测试里仅第一项就占 fib_rec 中 `op_return` 的 6.22%。
- **所有权 / 错误 / 调用**：所有权：只关闭本帧发布过的 open var-ref cell；存储窗口由 arena 的 `restore` 成批回收。 错误：无。 调用：唯一调用方是 `deinitOrdinaryReturned`（768）的 `canUseSimpleTeardown()` 快臂。

### `Entry.deinitOrdinaryReturned` (`src/exec/inline_calls.zig:767`)

- **签名**：`inline fn deinitOrdinaryReturned(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：被 `isOrdinaryReturn()` 分类过的普通返回帧的拆除：三个叶位和各种 completion 位都已被静态证否，只剩「帧有没有在运行中长出自有存储」这一个真动态判断。
- **实现**：`canUseSimpleTeardown()` 为真走快臂——`deinitOrdinarySimpleResources(ctx)` 后 `vm_stack.restore(self.arena_mark)` 直接返回；否则整条交给 `deinitGeneral(ctx)`。按注释，这条剩下的分支是唯一无法在 push 时判定的：函数体里 materialize 了 `arguments` 或扩了栈的帧就得走通用体，这属于帧的事实而非返回路径的税。
- **所有权 / 错误 / 调用**：错误：无。所有权：simple 帧只关 open var-ref 后回滚 `arena_mark`；否则整条交给 `deinitGeneral`（会 `stack.deinit` 并 `frame.deinitInlineCall`）。调用：唯一调用方 `src/exec/inline_calls.zig:4905`（普通返回的 pop 臂）。

### `Entry.deinitConstructorReturned` (`src/exec/inline_calls.zig:795`)

- **签名**：`inline fn deinitConstructorReturned(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：构造器帧正常返回的专用拆除：调用方已经把 `native_caller` 里的兜底实例读走，所以这里既不释放 native 记录也不释放 fallback 实例。
- **实现**：五条断言先钉死形状：`constructor_completion` 为真，`has_native_caller`/`empty_leaf`/`exact_args_leaf`/`special_return` 全假（构造器建帧走 `pushConstructorCall`/`pushDerivedConstructorCall`，从不发布叶位、从不持有 native `call` 记录）。随后 `canUseSimpleTeardown()` 为真时，再断言 var_refs 借用或为空、`locals` 紧邻操作数栈基址，并只在 `frame.function.openVarRefCount() != 0` 时 `closeOpenVarRefs(rt)`；否则 `stack.deinit(rt)` + `frame.deinitInlineCall(&rt.memory, rt)`。两臂最后都 `rt.vm_stack.restore(self.arena_mark)`。注释强调异常完成绝不能走这里——它仍从 `Entry.deinit` 进入，由带 flag 守卫的 `releaseConstructorFallback` 恰好释放一次实例。
- **所有权 / 错误 / 调用**：错误：无；五条 `assert` 钉死这是构造器完成且非叶、非特殊返回的帧。所有权：simple 分支只 `closeOpenVarRefs`，否则 `stack.deinit(rt)` + `frame.deinitInlineCall(&rt.memory, rt)` 释放堆窗口；两条路最后都回滚 `vm_stack` 到 `arena_mark`。调用：唯一调用方 `src/exec/inline_calls.zig:5147`（构造器完成的 pop 臂）。

### `Entry.deinitGeneral` (`src/exec/inline_calls.zig:816`)

- **签名**：`fn deinitGeneral(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：任意形状帧的权威拆除：把 stack 与 frame 的自有存储真正释放掉，再回滚 arena 水位。
- **实现**：两行：`deinitGeneralResources(ctx)` 释放资源，`ctx.runtime.vm_stack.restore(self.arena_mark)` 回滚水位。与 `deinitSimple` 同样的二分，是为了让尾调用替换只做资源释放而保留 arena 窗口。
- **所有权 / 错误 / 调用**：错误：无。所有权：`deinitGeneralResources` 释放 stack 与 frame 的自有存储，然后回滚 `vm_stack` 到 `arena_mark`。调用：本文件 `:615`、`:619`（`Entry.deinit` 的非 simple 臂）与 `:772`（`deinitOrdinaryReturned` 的回落）。

### `Entry.deinitGeneralResources` (`src/exec/inline_calls.zig:821`)

- **签名**：`fn deinitGeneralResources(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：通用拆除的资源腿：不假设任何形状，逐一释放操作数栈与帧自身可能持有的存储，但不碰 arena 水位。
- **实现**：取 `rt = ctx.runtime` 后两次调用：`self.stack.deinit(rt)` 处理操作数栈（清活值、切断 backing，只有既非 arena 又非驻留的 backing 才真 free），`self.frame.deinitInlineCall(&rt.memory, rt)` 处理帧（自有 slab、cold 存储、open var-ref、按 `OwnershipDisposition` 释放 `this` 与实参）。`arena_mark` 的回滚留给 `deinitGeneral`，因此尾调用替换可以只用这一半。
- **所有权 / 错误 / 调用**：错误：无。所有权：`stack.deinit(rt)` 把活值清成 undefined 并切断 backing，只有非 arena、非驻留的 backing 才真 `free`，`frame.deinitInlineCall(&rt.memory, rt)` 释放帧自有 slab、关 open var-ref；arena watermark 不在这里回滚。调用：本文件 `:816`（`deinitGeneral`）、`:833` 与 `:837`（`deinitForTailReplacement` 的两条臂）。

### `Entry.deinitForTailReplacement` (`src/exec/inline_calls.zig:831`)

- **签名**：`inline fn deinitForTailReplacement(self: *Entry, ctx: *core.JSContext) void`。
- **作用**：尾调用要复用这块 Entry 存储时的拆除：释放帧的全部资源，但**保留** arena 水位——被替换的调用方那块 alloca 形状的窗口要一直活到最终 callee 完成（对齐 qjs 嵌套 `JS_CallInternal` 帧仍存活）。
- **实现**：与 `deinit` 同形但只释放资源、不恢复 watermark：叶形态（`empty_leaf`/`exact_args_leaf`/`isForwardedLeaf()`）走 `deinitGeneralResources`，`canUseSimpleTeardown()` 走 `deinitSimpleResources`，其余走 `deinitGeneralResources`。
- **所有权 / 错误 / 调用**：错误：无。所有权：尾调用要复用这块 Entry 存储，所以只释放资源不回滚 arena——叶形态与非 simple 形态都走 `deinitGeneralResources`，simple 形态走 `deinitSimpleResources`。调用：唯一调用方 `src/exec/inline_calls.zig:4808`（尾调用替换当前帧时）。

### `ExecutionLevel.function` (`src/exec/inline_calls.zig:859`)

- **签名**：`pub inline fn function(self: ExecutionLevel) *const bytecode.FunctionBytecode`。
- **作用**：从一个执行层级的借用束里取出当前正在跑的 `FunctionBytecode`——`ExecutionLevel` 不自己存 FB，`frame.function` 才是权威来源。
- **实现**：一行 `return self.frame.function`。`ExecutionLevel` 只是 `{frame, stack, catch_target}` 三个指针的借用束（栈与 catch 槽单列是因为它们的存储生命周期与帧 slab 不同），FB 指针不在束里镜像一份，避免与 `Vm.function` 这个可重载的热分派缓存产生第二个真相。
- **所有权 / 错误 / 调用**：错误：无。所有权：只转发 `frame.function` 这个借用指针，`FunctionBytecode` 归 callable/bytecode 树所有。调用：`src/exec/builtin_dispatch.zig:176`（填 `caller_function`）与 `src/exec/zjs_vm.zig:703`。

### `MachineBacktraceView.root` (`src/exec/inline_calls.zig:895`)

- **签名**：`pub fn root(machine: *const Machine) MachineBacktraceView`。
- **作用**：给一台 `Machine` 造一个覆盖整条 Entry 链、并且连 L0 帧一起算进去的 backtrace 视图，用于从最外层抓完整调用栈。
- **实现**：返回 `.{ .machine = machine, .include_l0 = true }`；其余字段吃默认值——`frozen_top = null`、`bottom_exclusive = null`（一直枚举到链底）、`live = true`（每次解析都重读 `machine.top`，跟随实时栈顶）。
- **所有权 / 错误 / 调用**：错误：无。所有权：只包住 `*Machine` 指针，视图本身是调用方栈上的值。调用：唯一调用方 `src/exec/zjs_vm.zig:504`，它把视图挂进 `BacktraceFrame`（`:507` 的 resolver）。

### `MachineBacktraceView.segment` (`src/exec/inline_calls.zig:902`)

- **签名**：`pub fn segment(machine: *const Machine, bottom_exclusive: ?*Entry) MachineBacktraceView`。
- **作用**：给一段 native→JS 回调造只覆盖它自己那截 Entry 的视图：从当时的栈顶往下到 `bottom_exclusive`（不含）为止，不含 L0，这样嵌套的原生跨界能拼成互不重叠的段。
- **实现**：`include_l0 = false`、`bottom_exclusive` 取参数（通常是栅栏处的 `machine.top`）、`live` 保持默认 true。`frozen_top` 的初值分两臂：ReleaseFast 下写 `undefined`，其余构建写 `null`。注释给了理由——live 视图只读 `Machine.top` 永不读 `frozen_top`，而嵌套的原生再入总是先 `freeze` 再翻 `live`，所以该字段在第一次可能被读到之前必已初始化。
- **所有权 / 错误 / 调用**：错误：无。所有权：借用 `*Machine`，`bottom_exclusive` 记录段底 Entry；ReleaseFast 下 `frozen_top` 留 undefined，靠 `freeze` 填。调用：`src/exec/host_invocation.zig:105`（常驻宿主 invocation 的 root view）与本文件 `:1073`（`NativeBoundaryScope.init`）。

### `MachineBacktraceView.freeze` (`src/exec/inline_calls.zig:914`)

- **签名**：`fn freeze(self: *MachineBacktraceView, top: ?*Entry) void`。
- **作用**：在原生栅栏处把外层 view 钉住：记下当时的链顶并让它停止读 `Machine.top`，这样嵌套的 native→JS 段装上自己的 view 之后，外层不会再把同一批 Entry 枚举第二遍。
- **实现**：断言 `self.live`（不能冻结已冻结的 view），写 `frozen_top = top`，再把 `live` 置 false。调用方 `NativeBoundaryScope.push`（1091）传的 top 是 `self.view.bottom_exclusive`，也就是内层段的底——外层从那里继续往下枚举。
- **所有权 / 错误 / 调用**：所有权：只存 Entry 指针，不持有。 错误：无。 调用：`NativeBoundaryScope.push`。

### `MachineBacktraceView.thaw` (`src/exec/inline_calls.zig:920`)

- **签名**：`fn thaw(self: *MachineBacktraceView) void`。
- **作用**：原生栅栏退出时把外层 view 解冻，重新让它跟随 `Machine.top`。
- **实现**：断言 `!self.live`，`frozen_top = null`，`live = true`。只有 `NativeBoundaryScope.popBacktrace` 的非 ReleaseFast 腿（1171）走这里；ReleaseFast 腿跳过清字段，直接 `outer_view.live = true`——下一次 `freeze` 总会覆盖 `frozen_top`，而 live 的 view 从不读它。
- **所有权 / 错误 / 调用**：所有权：无。 错误：无。 调用：`NativeBoundaryScope.popBacktrace` 的非 ReleaseFast 腿。

### `resolveMachineBacktraceRange` (`src/exec/inline_calls.zig:927`)

- **签名**：`fn resolveMachineBacktraceRange( machine: *const Machine, top: ?*Entry, bottom_exclusive: ?*Entry, include_l0: bool, index: usize, ) ?core.ActiveBacktraceSnapshot`。
- **作用**：backtrace 解析的核心游标：把「Machine 的一段 Entry 链」按 `index` 展平成第 index 个栈帧快照，逻辑内联帧、物理帧、合成 native 记录、L0 帧依次计数。
- **实现**：从 `top` 沿 `Entry.prev` 走到 `bottom_exclusive`（不含）为止，每层先 `consumeInlineThenPhysical(&entry.frame, &remaining)` 消费该物理帧的小函数内联逻辑帧与自身，再在 `teardown.has_native_caller` 时消费一个 `nativeBacktraceSnapshot(entry.native_caller)`；走完仍有余量且 `include_l0` 为真，最后消费 `machine.l0.level.frame`。
- **所有权 / 错误 / 调用**：错误：无；走到底返回 null 表示该 index 超出这段栈。所有权：只读遍历 Entry 链与 `machine.l0`，快照里的 atom 不额外 retain。调用：唯一调用方是本文件的 `resolveMachineBacktraceView`（`src/exec/inline_calls.zig:968`）。

### `consumeInlineThenPhysical` (`src/exec/inline_calls.zig:953`)

- **签名**：`fn consumeInlineThenPhysical(frame: *const frame_mod.Frame, remaining: *usize) ?core.ActiveBacktraceSnapshot`。
- **作用**：把一个物理帧在 backtrace 上应当呈现的帧数消费掉：小函数内联展开出来的每个逻辑 callee 各算一帧，最后才是这个物理帧自己。
- **实现**：栈上开 `[small_inline.max_depth]InlinedSite` 缓冲，用 `small_inline.logicalInlineFrames(frame.function, frame.pc -| 1, &buf)` 取出当前 pc 落在哪些内联窗口里（`pc -| 1` 是饱和减一，取调用指令而非返回地址）。逐个 site：`remaining.* == 0` 说明要找的就是它，返回 `small_inline.inlinedSnapshot(&site, frame.pc -| 1)`；否则 `remaining.* -= 1`。逻辑帧走完再轮到物理帧自身：`remaining.* == 0` 就返回 `exception_ops.frameBacktraceSnapshot(frame)`，否则再减一并返回 null，让调用方继续往下一个 Entry 走。
- **所有权 / 错误 / 调用**：错误：无；本帧没消耗完 `remaining` 就返回 null 让调用方继续往下走。所有权：内联站点数组是栈上 `buf`（`small_inline.max_depth` 上限），快照按值返回。调用：本文件 `:939`（逐个 Entry）与 `:947`（L0 物理帧）。

### `resolveMachineBacktraceView` (`src/exec/inline_calls.zig:966`)

- **签名**：`pub fn resolveMachineBacktraceView(data: ?*const anyopaque, index: usize) ?core.ActiveBacktraceSnapshot`。
- **作用**：装进 `ActiveBacktraceFrame` 的 resolver 函数指针：core 的通用 backtrace 遍历器拿 `index` 来问，这里把它翻译成 Machine 段内的第 index 帧。
- **实现**：把 `?*const anyopaque` 还原成 `*const MachineBacktraceView`（`data.?` 直接解包，安装时保证非 null），然后按视图状态选栈顶——`view.live` 为真读实时的 `view.machine.top`，已被 `freeze` 的外层视图则读 `view.frozen_top`——最后连同 `bottom_exclusive`、`include_l0`、`index` 交给 `resolveMachineBacktraceRange`。
- **所有权 / 错误 / 调用**：错误：无。所有权：把 `?*const anyopaque` 还原成 `*const MachineBacktraceView`（视图归 scope 所有），live 时读 `machine.top`、否则读冻结的 `frozen_top`。调用：不被直接调用，而是作为 `BacktraceFrame.resolver` 函数指针安装：`src/exec/inline_calls.zig:1094`（`NativeBoundaryScope.push`）、`src/exec/host_invocation.zig:108`、`src/exec/zjs_vm.zig:507`。

### `nativeBacktraceSnapshot` (`src/exec/inline_calls.zig:978`)

- **签名**：`fn nativeBacktraceSnapshot(function_value: core.JSValue) core.ActiveBacktraceSnapshot`。
- **作用**：为 Entry 上挂着的合成 native `call` 记录造一帧 backtrace 快照，好让捕获到的栈保持 qjs 的帧序 `target → call (native) → caller`。
- **实现**：直接返回字面量：`function_name`/`filename` 都填 `core.atom.null_atom`（native 帧没有源位置，也就不占 atom 引用），`line_num`/`col_num` 为 0，`function_value` 取参数，`is_native = true`。
- **所有权 / 错误 / 调用**：错误：无。所有权：函数名/文件名填 `null_atom`（不占 atom 引用），`function_value` 借用 Entry 的 `native_caller`，`is_native = true`。调用：唯一调用方 `src/exec/inline_calls.zig:941`（遍历到带 native caller 的 Entry 时）。

### `copyValueSlotPinned` (`src/exec/inline_calls.zig:1010`)

- **签名**：`pub inline fn copyValueSlotPinned(dst: *core.JSValue, src: *const core.JSValue) void`。
- **作用**：按两个 64-bit 字搬运一个 JSValue 槽；AArch64 上钉成内联 `ldp`/`stp`，不让 LLVM 合并成 `q` 访问（`q` 访问不对刚写下的 64 位 store 转发）。
- **实现**：`builtin.cpu.arch == .aarch64` 时走 `ldp x9, x10, [src]` / `stp x9, x10, [dst]` 的 `asm volatile`（clobber x9/x10 与 memory）；其它架构退回 `JSValue.storeSlotAsIntPair(dst, JSValue.loadSlotAsIntPair(src))`。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯 16 字节槽搬运，不改引用计数、不建根；aarch64 走 `ldp/stp` 内联汇编，其余架构走 `loadSlotAsIntPair`/`storeSlotAsIntPair`。调用：本文件的搬参/搬 this 路径共 13 处，如 `src/exec/inline_calls.zig:3745`、`:3761`、`:3886`。

### `activeInvocation` (`src/exec/inline_calls.zig:1024`)

- **签名**：`pub inline fn activeInvocation(rt: *core.JSRuntime) ?*ActiveInvocation`。
- **作用**：从 runtime 上取回当前那次宿主 invocation 的记录（`ActiveInvocation`），没有正在进行的 invocation 就返回 null。
- **实现**：`rt.active_invocation orelse return null` 之后 `@ptrCast(@alignCast(...))`。runtime 里存的是 `anyopaque`，因为 core 不应当认识 VM 的布局；`ActiveInvocation` 把它的 header 放在偏移 0，core 的 `traceRoots` 只看那个 header。
- **所有权 / 错误 / 调用**：错误：无；`rt.active_invocation` 为空返回 null。所有权：只做 `anyopaque` 还原，invocation 由宿主入口（`zjs_vm`/`host_invocation`）拥有。调用：`src/exec/builtin_dispatch.zig:174`、`src/exec/call_site.zig:314`/`:369`/`:497`、`src/exec/call_runtime.zig:482`、`src/exec/zjs_vm.zig:518`（串联 `previous`）。

### `NativeBoundaryScope.init` (`src/exec/inline_calls.zig:1062`)

- **签名**：`pub fn init(invocation: *ActiveInvocation) NativeBoundaryScope`。
- **作用**：为一次 native→JS 同步回调快照 Machine 状态：外层 backtrace view、`machine.vm.rt`、本段的 `MachineBacktraceView.segment`、栅栏深度 `machine.depth` 与 `machine.vm.saveEntryState()`。
- **实现**：取 `machine = invocation.machine` 后一次性构造：`outer_view` 存下当前 `invocation.current_backtrace_view`；`rt` 特意取 `machine.vm.rt`（驻留字段，一次 load）而不是 `machine.ctx.runtime`（machine→ctx→runtime 两次依赖 load）；`view` 是以当前 `machine.top` 为段底的 `MachineBacktraceView.segment`；`fence_depth = machine.depth`；`vm_entry = machine.vm.saveEntryState()` 保存外层分派层的整组寄存器（快照而非事后从 Machine 反推，因为恢复时是八条可转发的独立 load，而不是 machine→top→frame→function→code 的依赖链）。`validation` 只在 Debug/ReleaseSafe 下填：栈顶指针、栈长、`vm_stack.mark()`、`call_depth`、`native_call_depth`、`active_bytecode_stack_bytes`；ReleaseFast 下该类型是空结构体。注意 `push` 之所以与 `init` 分开，是因为活动帧要借用 `self.view`，必须等 scope 落到最终地址后才能接线。
- **所有权 / 错误 / 调用**：错误：无。所有权：只做快照——保存 `invocation.current_backtrace_view`、`machine.depth`、`vm.saveEntryState()`，Debug/ReleaseSafe 另存栈顶、arena mark、三个深度计数以便 `deinit`/`finish` 对账；scope 本身是调用方栈上的值。调用：`src/exec/call_runtime.zig:516`、`:551`、`:587` 三条 `runSyncInlineRoute*`（idle 机器时改用 `IdleBoundaryScope.init`）。

### `NativeBoundaryScope.push` (`src/exec/inline_calls.zig:1088`)

- **签名**：`pub fn push(self: *NativeBoundaryScope) void`。
- **作用**：把本段 backtrace view 挂上：冻结外层 view，并把本 scope 的节点推到 runtime 的 backtrace 帧链头。
- **实现**：四步：`self.outer_view.freeze(self.view.bottom_exclusive)` 把外层视图钉在本段底部（此后外层从那里继续往下枚举，不会重复本段的 Entry）；用 `{ .data = &self.view, .resolver = resolveMachineBacktraceView }` 填好 `self.frame`；把 `frame.previous` 指向 `rt.hot.current_backtrace_frame` 后让后者指向 `&self.frame`（头插）；最后把 `invocation.current_backtrace_view` 改指本段视图。注意 `data` 存的是 `&self.view`，这正是本函数不能并进 `init` 的原因。
- **所有权 / 错误 / 调用**：错误：无。所有权：把外层视图 `freeze` 到本段底部，然后把本 scope 的 `frame` 链进 `rt.hot.current_backtrace_frame`（栈式借用，`popBacktrace` 摘除），并把 `invocation.current_backtrace_view` 指向本段视图。调用：`src/exec/call_runtime.zig:517`、`:552`、`:588`，紧跟各自的 `init`。

### `NativeBoundaryScope.deinit` (`src/exec/inline_calls.zig:1099`)

- **签名**：`pub fn deinit(self: *NativeBoundaryScope) void`。
- **作用**：错误腿收尾：丢弃栅栏之上残留的 Entry，再还原 Vm 入口状态并弹出 backtrace 节点。
- **实现**：`machine.depth > fence_depth` 则 `discardToDepth(fence_depth)`，随后断言 depth 与 `machine.top` 回到栅栏；Debug/ReleaseSafe 另外比对 `init` 存下的栈顶/长度、arena mark、两个深度计数与 `active_bytecode_stack_bytes`。最后 `machine.vm.restoreEntryState(&self.vm_entry)` 并 `popBacktrace()`。
- **所有权 / 错误 / 调用**：错误：无。所有权：异常路径的回滚——`machine.depth > fence_depth` 时 `discardToDepth` 把多出来的 Entry 全部销毁，再 `restoreEntryState` 复原 VM 寄存器并摘掉 backtrace 帧；Debug/ReleaseSafe 逐项校验栈顶、arena mark 与深度计数。调用：`src/exec/call_runtime.zig:518`、`:553`、`:589` 的 `errdefer boundary.deinit()`。

### `NativeBoundaryScope.finish` (`src/exec/inline_calls.zig:1125`)

- **签名**：`pub fn finish(self: *NativeBoundaryScope) void`。
- **作用**：成功腿收尾：断言栅栏未被破坏后还原 Vm 入口状态并弹出 backtrace 节点（不做丢弃）。
- **实现**：断言 `machine.depth == fence_depth` 且 `machine.top == view.bottom_exclusive`；Debug/ReleaseSafe 复核 `init` 存下的六项快照；随后 `machine.vm.restoreEntryState(&self.vm_entry)` 与 `popBacktrace()`。
- **所有权 / 错误 / 调用**：错误：无。所有权：成功路径的关闭——只 `assert` 深度与栈状态未变，然后 `restoreEntryState` + `popBacktrace`；不销毁任何 Entry（此时应已被正常 pop 光）。调用：`src/exec/call_runtime.zig:530`、`:575`、`:603`，在 `runActiveInvocationUntilNativeBoundary` 返回后、取回值之前。

### `NativeBoundaryScope.fenceDepth` (`src/exec/inline_calls.zig:1147`)

- **签名**：`pub inline fn fenceDepth(self: *const NativeBoundaryScope) usize`。
- **作用**：回报这次原生栅栏建立时的 Machine 逻辑深度，错误腿据此把栅栏之上多出来的 Entry 全丢掉。
- **实现**：一行 `return self.fence_depth`，读的是 `init` 时抄下的 `machine.depth`。存在这个访问器而不是直接读字段，是为了让 `zjs_vm` 那两处对 `NativeBoundaryScope` 与 `IdleBoundaryScope` 泛型写同一份代码。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `fence_depth`。调用：`src/exec/zjs_vm.zig:729`、`:747`（两条 `runActiveInvocation*UntilNativeBoundary` 在出错时用它调 `runActiveInvocationAfterNativeBoundaryError`）；`IdleBoundaryScope` 提供同名函数以便这两处对两种 scope 泛型调用。

### `NativeBoundaryScope.expectedTop` (`src/exec/inline_calls.zig:1151`)

- **签名**：`pub inline fn expectedTop(self: *const NativeBoundaryScope) ?*Entry`。
- **作用**：回报栅栏处的 Entry 链顶（即本段的段底），用来断言「回调跑完后栈已恢复原状」，出错时也用它界定要丢弃到哪里。
- **实现**：一行 `return self.view.bottom_exclusive`——`init` 里这个字段就是用当时的 `machine.top` 填的，可能为 null（栅栏建立时 Machine 为空）。与 `fenceDepth` 一样是为泛型调用点准备的访问器。
- **所有权 / 错误 / 调用**：错误：无。所有权：只回传 `view.bottom_exclusive`（本段栈底那个 Entry 指针，可能为 null），不转移所有权。调用：`src/exec/zjs_vm.zig:732`、`:734`、`:755`、`:757`——出错时传给 `runActiveInvocationAfterNativeBoundaryError`，正常路径当断言用。

### `NativeBoundaryScope.popBacktrace` (`src/exec/inline_calls.zig:1155`)

- **签名**：`inline fn popBacktrace(self: *NativeBoundaryScope) void`。
- **作用**：把本次原生栅栏挂上去的 backtrace 段摘掉：从 runtime 的帧链上解链，并把 `invocation` 的当前视图还原成外层那一份。
- **实现**：ReleaseFast 臂直接解链：断言 runtime 的 `current_backtrace_frame` 就是本节点，改指 `frame.previous`，恢复 `invocation.current_backtrace_view` 并把外层 view 的 `live` 置回 true（不清 `frozen_top`）；其余构建走 `ctx.popActiveBacktraceFrame(&self.frame)` 再 `outer_view.thaw()`。
- **所有权 / 错误 / 调用**：错误：无。所有权：私有 helper，把本 scope 的 `BacktraceFrame` 从 `rt.hot.current_backtrace_frame` 链上摘掉并把 `invocation.current_backtrace_view` 还原成外层视图；ReleaseFast 直接改链并置 `outer_view.live = true`，Debug/ReleaseSafe 走 `ctx.popActiveBacktraceFrame` 校验顺序后 `outer_view.thaw()`。调用：本文件 `:1121`（`deinit`）与 `:1143`（`finish`）。

### `IdleBoundaryScope.init` (`src/exec/inline_calls.zig:1187`)

- **签名**：`pub inline fn init(invocation: *ActiveInvocation) IdleBoundaryScope`。
- **作用**：为「机器空闲（depth 0）时的嵌入者调用」开一笔轻量原生边界事务：没有挂起的字节码帧要快照，只需记住 `ActiveInvocation` 指针——错误腿唯一用得上的字段。
- **实现**：两条 Debug 断言：`invocation.machine.depth == 0`，以及当前 backtrace view 仍 live 且 `bottom_exclusive == null`（即根 view）；然后返回只含一个 `invocation` 字段的结构体。相对 `NativeBoundaryScope.init` 省掉的正是在 C 栈上搭那 200 字节事务的开销（注释实测：每次嵌入者跨界 11 条 store 加一次常真分支）。
- **所有权 / 错误 / 调用**：所有权：借用 `ActiveInvocation`，不持有。 错误：无。 调用：`call_runtime.zig:514`/`549`，由 `comptime idle_machine` 选中这一支而不是 `NativeBoundaryScope`。

### `IdleBoundaryScope.fenceDepth` (`src/exec/inline_calls.zig:1194`)

- **签名**：`pub inline fn fenceDepth(_: *const IdleBoundaryScope) usize`。
- **作用**：瘦栅栏版的同名访问器：idle 机器按定义就在深度 0 上建栅栏，直接回报 0。
- **实现**：忽略 self（形参写成 `_`），`return 0`。`IdleBoundaryScope.init` 用 Debug 断言保证了 `invocation.machine.depth == 0`，所以这个常量与实际深度一致。
- **所有权 / 错误 / 调用**：错误：无。所有权：常量 0——idle 机器的围栏深度按构造就是 0，无状态可持有。调用：`src/exec/zjs_vm.zig:729`、`:747`，与 `NativeBoundaryScope.fenceDepth` 共用同一处泛型调用点。

### `IdleBoundaryScope.expectedTop` (`src/exec/inline_calls.zig:1198`)

- **签名**：`pub inline fn expectedTop(_: *const IdleBoundaryScope) ?*Entry`。
- **作用**：瘦栅栏版的同名访问器：idle 机器进入时 Entry 链是空的，段底就是 null。
- **实现**：忽略 self，`return null`。`init` 的 Debug 断言已核对当前 backtrace view 仍是 `bottom_exclusive == null` 的根视图，与这个常量一致。
- **所有权 / 错误 / 调用**：错误：无。所有权：常量 null——idle 机器进入时栈空，没有段底 Entry。调用：`src/exec/zjs_vm.zig:732`、`:734`、`:755`、`:757`（与 `NativeBoundaryScope.expectedTop` 同址，靠 `boundary` 的静态类型分派）。

### `IdleBoundaryScope.push` (`src/exec/inline_calls.zig:1202`)

- **签名**：`pub inline fn push(_: *IdleBoundaryScope) void`。
- **作用**：空操作：depth-0 的瘦栅栏没有要挂的 backtrace 段。
- **实现**：函数体为空。
- **所有权 / 错误 / 调用**：错误：无。所有权：空函数体——idle 机器没有外层 backtrace 段要冻结，也没有 frame 要挂链。调用：`src/exec/call_runtime.zig:517`、`:552`、`:588`（`idle_machine` 为真时 `boundary` 就是本类型）。

### `IdleBoundaryScope.finish` (`src/exec/inline_calls.zig:1204`)

- **签名**：`pub inline fn finish(self: *IdleBoundaryScope) void`。
- **作用**：成功腿收尾：只断言 Machine 仍在 depth 0。
- **实现**：函数体只有 `std.debug.assert(self.invocation.machine.depth == 0)`：成功腿没有快照要恢复、没有 backtrace 节点要摘，ReleaseFast 下整个调用消失。失败腿的清理在 `deinit`（1212）。
- **所有权 / 错误 / 调用**：所有权：无。 错误：无。 调用：`call_runtime.zig` 两条同步内联路由在 `runActiveInvocationUntilNativeBoundary` 返回后调用。

### `deinit` (`src/exec/inline_calls.zig:1210`)

- **签名**：`pub noinline fn deinit(self: *IdleBoundaryScope) void`。
- **作用**：depth-0 宿主回调的错误腿：丢掉栅栏之上残留的 Entry。永不内联进 crossing（成功路径只走 `finish`）。
- **实现**：取出 `self.invocation.machine`。若 `machine.depth > 0` 则 `discardToDepth(0)` 把回调段里压出的帧全部 `popFrame` 掉；然后断言 `depth == 0`。`IdleBoundaryScope` 本身不装 200 字节事务，错误腿才需要这条。
- **所有权 / 错误 / 调用**：`discardToDepth` 对每层 `popFrame` 并把 `async_complete` continuation 交还 `async_completions`，再 `continuation.deinit(runtime)`。错误：无。调用：Idle 栅栏的 errdefer / 失败路径。

### `LeanFrame.isIntact` (`src/exec/inline_calls.zig:1246`)

- **签名**：`pub inline fn isIntact(self: *const LeanFrame) bool`。
- **作用**：问站点自有的这块 lean 帧模板还完不完好——callee 里的尾调用如果复用了这个物理 Entry，会把它改建成通用帧并抹掉标记，此时站点必须重新 `initInPlace` 才能再用。
- **实现**：一行 `return self.entry.continuation_payload == marker`（`marker` 常量为 1，其它 native-boundary 帧该字段一律是 0）。清标记的动作发生在 `Entry.adoptContinuation`：尾调用接管续延时，`.native_boundary` 分支把 payload 写 0。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `entry.continuation_payload` 与 `marker` 比较，判断这块常驻 lean 帧有没有被后续调用改写过。调用：`src/exec/call_site.zig:139`、`src/exec/host_invocation.zig:155` 与 `:202`（复用前的校验）。

### `LeanFrame.initInPlace` (`src/exec/inline_calls.zig:1253`)

- **签名**：`pub inline fn initInPlace(lean: *LeanFrame, rt: *core.JSRuntime, target: *const InlineTarget) bool`。
- **作用**：把站点自有的 `LeanFrame` 按一个内联目标就地烘成模板：凡是每次调用都不变的几何与字段都在这里写死，之后每次跨界只剩「arena 切窗、拷实参、填与 arena 相关的窗口字段、加深度/字节预算、挂链」五件事。
- **实现**：先过准入：`Machine.nativeBoundarySimpleEligible(target)` 不成立返回 false；`function.openVarRefCount() != 0` 返回 false；形状必须是已发布的空叶（`simple_inline_empty_leaf` 或 `raw_this_inline_empty_leaf`）或精确实参叶（`exact_args_leaf_kind != .none`），否则 false；空叶却带 capture 也返回 false。随后算几何：`frame_arg_count` 空叶为 0、否则取 `function.arg_count`，`stack_count = function.stack_size + 1`，`planned_stack_bytes = vm_call.bytecodeFrameAllocaSize(function, 0, true)`，`total_words = frame_arg_count + stack_count`，并把 `in_use` 置 false。再填内嵌 `Entry`：`return_action = .native_boundary`、`continuation_payload = marker`、`catch_target = null`、`arena_mark` 故意留 `undefined`（push 时才知道）、`frame` 写死 function/this/current_function/captures 与 `ownership`（capture 非空为 `.borrowed`、空则 `.owned`；storage 恒 `.borrowed`），`args` 与 `stack` 用 `undefined` 基址加固定长度先把**长度**定下来（注释：指针每次调用现切，长度不变），`teardown = { .simple, .special_return, .copy_argv }`，`native_caller = undefined value`，`prev = null`。成功返回 true。写成就地初始化 + bool 而不是返回 optional，是因为按值返回会把 300 字节的帧从 q 寄存器搬一遍。
- **所有权 / 错误 / 调用**：错误：无，任何不合格（非 native-boundary simple、有 open var-ref、既不是空叶也不是精确实参叶、空叶却带 captures）都返回 false，调用方退回通用 push。所有权：就地初始化调用方持有的 `LeanFrame`——`entry.arena_mark` 留 undefined 待 push 时填，`continuation_payload` 写 `marker` 作为完好性凭证，`prev`/`native_caller` 置空；不分配任何内存。调用：`src/exec/host_invocation.zig:168`、`src/exec/call_site.zig:146`（`src/core/runtime.zig:1591` 的同名命中属 `classes.initInPlace`）。

### `Machine.init` (`src/exec/inline_calls.zig:1339`)

- **签名**：`pub fn init(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, l0: *const L0State) Machine`。
- **作用**：建一台 depth 0 的内联调用机——Entry 链与驻留分发寄存器包的宿主——并把 `vm` 的不变字段一次写好。
- **实现**：测试构建给 `machine_inits` 加一；填入 `ctx`/`output`/`global`/`l0` 与空的 `pending_call_region`，`vm` 先留 undefined，再由 `machine.vm.initResident(ctx, output, global)` 写入驻留字段。
- **所有权 / 错误 / 调用**：所有权：返回按值的 Machine；chunk 存储要到第一次 push 才分配，销毁走 `deinit` / `deinitStorage`。`l0` 借用调用方提供的 `L0State`，必须比 Machine 活得久。 错误：无。 调用：`host_invocation.HostInvocation.create`（host_invocation.zig:102）建驻留机，以及 `zjs_vm.zig:503` 为一次顶层执行建临时机。

### `Machine.alreadyTargets` (`src/exec/inline_calls.zig:1358`)

- **签名**：`pub inline fn alreadyTargets(self: *const Machine, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) bool`。
- **作用**：问这台常驻 Machine 现在挂的是不是正好就是要用的那组 (ctx, global, output)，是则可以跳过 `retarget`。
- **实现**：三个指针相等的与：`self.ctx == ctx and self.global == global and self.output == output`。存在这道判断是因为不加时每次宿主调用都会写五条必然相同的 store（见 `retarget` 的注释）。
- **所有权 / 错误 / 调用**：错误：无。所有权：只做三个指针比较（ctx / global / output），不改状态。调用：唯一调用方 `src/exec/host_invocation.zig:136`，用于决定常驻 Machine 是否需要 `retarget`。

### `Machine.retarget` (`src/exec/inline_calls.zig:1362`)

- **签名**：`pub fn retarget(self: *Machine, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) void`。
- **作用**：把一台空闲（depth 0）的 Machine 连同它内嵌的驻留 `Vm` 改挂到同一 runtime 的另一组 (ctx, global, output) 上，省掉重建。
- **实现**：断言 `depth == 0`（只允许空闲机改挂），改写 `ctx`/`global`/`output` 三个字段，再把同样三项转给 `self.vm.retarget`。chunk 存储、`l0`、`pending_call_region` 原样留用，不重建。调用方 `host_invocation.acquire`（host_invocation.zig:137）先用 `alreadyTargets` 挡掉同 (ctx, output, global) 的重复改挂——否则每次调用都是五条死 store——真正改挂时还 `retarget_epoch +%= 1`（host_invocation.zig:138）。
- **所有权 / 错误 / 调用**：所有权：只换指针，不转移任何存储。 错误：无。 调用：`host_invocation.HostInvocation.acquire`。

### `Machine.deinitStorage` (`src/exec/inline_calls.zig:1373`)

- **签名**：`pub fn deinitStorage(self: *Machine, rt: *core.JSRuntime) void`。
- **作用**：释放 Machine 自己的 Entry 块存储（只在 depth 0 时允许）。
- **实现**：断言 `depth == 0`；`async_completions.deinit(rt)`，逐块 `rt.memory.destroy` 已分配的 `chunk_count` 个 `[entries_per_chunk]Entry`，把 `chunk_count` 归零，再 `rt.memory.free` chunk 指针数组并置空切片。
- **所有权 / 错误 / 调用**：错误：无（`assert(depth == 0)` 要求栈已空）。所有权：释放 Machine 自己的堆存储——`async_completions.deinit(rt)`、逐块 `rt.memory.destroy` Entry chunk、再 `free` chunk 指针数组并把 `chunks` 置空切片；帧内的 JSValue 不在这里处理。调用：本文件 `:1396`（`Machine.deinit`）与 `src/exec/host_invocation.zig:126`（常驻宿主 Machine 拆除）。

### `Machine.deinit` (`src/exec/inline_calls.zig:1388`)

- **签名**：`pub fn deinit(self: *Machine) void`。
- **作用**：销毁一台机：先把链上残留的内联帧排干（没有 catch 处理的错误传出分发循环时会留下帧），再交还 Entry 块存储。
- **实现**：先把残留的帧全部弹掉：`while (self.depth > 0)` 里 `popFrame()`，`.async_complete` 的 continuation 交还 `async_completions.release(payload)`，再 `continuation.deinit(runtime)`；最后 `deinitStorage(self.ctx.runtime)` 释放 Entry 块。
- **所有权 / 错误 / 调用**：所有权：排干残帧时逐层释放 Entry 资源与 continuation payload，最后释放 chunk 数组；`ctx`/`l0`/`global` 都是借用，不动。 错误：无。 调用：`zjs_vm.zig:525` 的 `defer`（临时机）；驻留机改走 `deinitStorage`（host_invocation.zig:126），因为它的 `ctx` 可能已经比 Machine 先没了。

### `Machine.topEntry` (`src/exec/inline_calls.zig:1401`)

- **签名**：`pub fn topEntry(self: *Machine) *Entry`。
- **作用**：取当前栈顶 Entry。
- **实现**：断言 `depth > 0`，直接返回缓存的 `self.top.?`。文档注释点明它刻意不用 `entryAt` 从 depth 索引重算——那要一条 umaddl 链——与 qjs 直接读 `rt->current_stack_frame`（quickjs.c:2864）同形。
- **所有权 / 错误 / 调用**：所有权：返回借用指针，Entry 存活在 Machine 的 chunk 数组或 CallSite 的 LeanFrame 里。 错误：无。 调用：`tailcall_dispatch.zig` 的返回/尾调用臂（多处仅用于断言 `dying == machine.topEntry()`）、`Machine` 自身的展开与尾调用替换路径。

### `Machine.loadCurrentLevel` (`src/exec/inline_calls.zig:1409`)

- **签名**：`pub inline fn loadCurrentLevel( self: *Machine, frame: **frame_mod.Frame, stack: **stack_mod.Stack, catch_target: **?usize, ) void`。
- **作用**：把当前执行层的 `frame`/`stack`/`catch_target` 指针装进三个出参。
- **实现**：`depth == 0` 时取 `self.l0.level` 的三个指针；否则取 `topEntry()` 的 `&entry.frame` / `&entry.stack` / `&entry.catch_target`。
- **所有权 / 错误 / 调用**：错误：无。所有权：只把当前层的三个指针写进调用方给的出参——depth 为 0 指向 `l0.level`（宿主/L0 帧，存储归调用方），否则指向栈顶 Entry 内嵌的 frame/stack/catch_target。调用：本文件 `:1432`（`currentLevel`）与 `src/exec/tailcall_dispatch.zig:7046`（重入后刷新 VM 寄存器）。

### `Machine.currentLevel` (`src/exec/inline_calls.zig:1428`)

- **签名**：`pub inline fn currentLevel(self: *Machine) ExecutionLevel`。
- **作用**：把当前执行层（L0 或栈顶 Entry）的 frame / stack / catch_target 三个指针收成一个 `ExecutionLevel` 借用束，按值交给调用方。
- **实现**：栈上开一个 `undefined` 的 `ExecutionLevel`，把三个字段的地址交给 `loadCurrentLevel` 就地写满，再整体返回。真正的分支在 `loadCurrentLevel`：`depth == 0` 取 `l0.level`，否则取 `topEntry()` 内嵌的三个字段。
- **所有权 / 错误 / 调用**：错误：无。所有权：返回借用三元组 `ExecutionLevel`，指针指向 L0 或栈顶 Entry 的内部字段，Entry 一旦 pop 即失效。调用：本文件 `:1077`/`:1109`/`:1132`（boundary scope 校验）、`:4515`、`:5086`、`:5092`、`:5198`、`:5225` 共 8 处，以及 `src/exec/builtin_dispatch.zig:175`、`src/exec/zjs_vm.zig:702`。

### `Machine.entryAt` (`src/exec/inline_calls.zig:1434`)

- **签名**：`pub inline fn entryAt(self: *Machine, index: usize) *Entry`。
- **作用**：按逻辑深度索引定位 Entry：Entry 存储是分块的，这里做「块号 + 块内下标」的二维寻址。
- **实现**：一行 `&self.chunks[index / entries_per_chunk][index % entries_per_chunk]`，`entries_per_chunk` 是文件级常量 16（`max_chunks` 512，即逻辑栈上限 8192 帧）。分块是为了让已有 Entry 的地址在扩容时保持稳定——`Entry.prev` 与 `Machine.top` 存的都是裸指针。
- **所有权 / 错误 / 调用**：错误：无；越界只靠调用方保证 `index < chunk_count * entries_per_chunk`。所有权：返回 chunk 数组里那一格 Entry 的借用指针，存储归 `Machine.chunks`。调用：本文件 11 处，如 `:1443`（`acquireSlot` 快路径）、`:1473`、`:2225`。

### `Machine.acquireSlot` (`src/exec/inline_calls.zig:1438`)

- **签名**：`fn acquireSlot(self: *Machine, global: *core.Object) HostError!*Entry`。
- **作用**：为下一次入帧取出 `depth` 位置那格 Entry 的存储；块还没开到就转冷路径去分配。
- **实现**：`index = self.depth`，`chunk_index = index / entries_per_chunk`；`chunk_index < self.chunk_count` 说明这块已经分配过，直接 `entryAt(index)` 返回（热路径上只有一次除法/移位加一次比较，不触碰分配器）；否则尾调 `acquireSlotSlow(global, index, chunk_index)` 去新开一块或报逻辑栈溢出。注意本函数**不**递增 `depth`，由各 push 路径在 Entry 初始化完成后自己接链并 `self.depth += 1`。
- **所有权 / 错误 / 调用**：错误：`HostError`——只有走 `acquireSlotSlow` 新开 chunk 时才可能 OOM，快路径无错。所有权：只交出 `depth` 位置那格 Entry 的指针，不递增 depth（由各 push 路径在初始化完成后自己接链并 `self.depth += 1`）。调用：本文件各 push 路径共 10 处，如 `:1571`、`:2417`、`:3551`（其中若干用 `catch |err|` 先清理已搬运的实参再上抛）。

### `acquireSlotSlow` (`src/exec/inline_calls.zig:1449`)

- **签名**：`noinline fn acquireSlotSlow(self: *Machine, global: *core.Object, index: usize, chunk_index: usize) HostError!*Entry`。
- **作用**：Entry chunk 耗尽时的冷分配：新开一块 `[entries_per_chunk]Entry`，或报逻辑栈溢出。
- **实现**：`chunk_index >= max_chunks` 时 `throwInternalErrorMessage(..., "stack overflow")` 后返回 `error.StackOverflow`（对齐 qjs `JS_ThrowStackOverflow`，quickjs.c:17837/7789，不是 RangeError）。`chunks.len==0` 则 `memory.alloc(*[entries_per_chunk]Entry, max_chunks)`。断言 `chunk_index == chunk_count`，`memory.create` 新 chunk；测试构建给 `entry_chunk_allocations` 加一。每个 virgin 槽预写 `frame.var_refs = &.{}`，让 `finishBorrowedIteratorFrame` 的 store-elision 比较读到已定义内存。挂上 `chunks[chunk_index]`，`chunk_count += 1`，返回 `entryAt(index)`。`noinline` 把分配/错误构造的寄存器压力挡在每次入帧热臂之外。
- **所有权 / 错误 / 调用**：chunk 数组与 Entry 块经 `MemoryAccount` 分配，由 `Machine.deinitStorage` 释放。错误：`HostError`（`StackOverflow` 或 OOM）。调用：仅 `Machine.acquireSlot` 在 `chunk_index >= chunk_count` 时。

### `Machine.ArgsSource.initStack` (`src/exec/inline_calls.zig:1491`)

- **签名**：`fn initStack(start: [*]core.JSValue, argc: u16, has_receiver: bool) ArgsSource`。
- **作用**：为「实参仍留在调用方操作数栈上」的调用形态描述参数来源：`start` 就是已后撤的调用区起点。
- **实现**：转调 `ArgsSource.init(start, argc, has_receiver, false)`——`moved = false` 意味着这段值还归调用方栈，失败路径要靠 `cleanupStackSource` 把整段清掉，成功路径则由帧按 `canBorrowSourceArgs` 决定借用还是搬运。
- **所有权 / 错误 / 调用**：错误：无。所有权：只描述窗口，值仍归调用方栈；失败清理走 `cleanupStackSource`。调用：本文件 `:3404`、`:3502`、`:3540`、`:3631` 四处从 `PendingCallRegion` 起点建源的调用点。

### `Machine.ArgsSource.initMoved` (`src/exec/inline_calls.zig:1495`)

- **签名**：`fn initMoved(moved_values: []core.JSValue, has_receiver: bool) ArgsSource`。
- **作用**：为「参数已经被搬进一块独立缓冲」的调用形态描述参数来源：缓冲开头是可选 receiver 与 callable，其余才是实参。
- **实现**：`binding_count = 1 + has_receiver`（callable 槽，加可选 receiver 槽），断言 `moved_values.len >= binding_count`，然后转调 `init`，把 `arg_count` 定为 `len - binding_count`、`moved` 置 true。`moved = true` 正是后续 `sourceHasStackRegion` 判否的依据：这类来源不占调用方 Stack 区域，不需要回退栈顶。
- **所有权 / 错误 / 调用**：所有权：只描述窗口，值的搬运由 `pushFrame` 完成。 错误：无。 调用：`pushMovedCall`（4469/4492）、`borrowed_iterator` push（4533）、尾调用替换（4778）。

### `Machine.ArgsSource.init` (`src/exec/inline_calls.zig:1501`)

- **签名**：`fn init(values: [*]core.JSValue, arg_count: usize, has_receiver: bool, moved: bool) ArgsSource`。
- **作用**：`ArgsSource` 的唯一真构造器：把窗口首指针与 {arg_count, has_receiver, moved} 三项打包成一个 `u64` 的 `Metadata`，供 `initStack` / `initMoved` 两个入口共用。
- **实现**：把 `values` 原样存下，再用 `@intCast` 把 `arg_count` 塞进 `Metadata` 的 `u62` 位段，和 `has_receiver`、`moved` 两个布尔合成一个 `u64`——整个 `ArgsSource` 因此只有两个字，能整体在寄存器里传递。
- **所有权 / 错误 / 调用**：所有权：只描述一个窗口，不拥有其中的值。 错误：无。 调用：`initStack`（1493）与 `initMoved`（1497）两个入口，外部不直调。

### `Machine.ArgsSource.valueCount` (`src/exec/inline_calls.zig:1512`)

- **签名**：`inline fn valueCount(self: ArgsSource) usize`。
- **作用**：算出这个 `ArgsSource` 窗口一共覆盖几个槽——实参数加上必有的 callable 槽，再加上可选的 receiver 槽。
- **实现**：`argCount() + 1 + @intFromBool(metadata.has_receiver)`，即窗口布局 `[receiver?] [callable] [args...]` 的总长；因为 `Metadata` 是一个 u64 位域，这一步只是两次位读加算术，`inline` 保证它折进调用点。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `metadata`，不碰值。调用：本文件 `:1519`（`slice` 用它定长度）与 `:3366`（`cleanupStackSource` 从窗口尾部倒着释放）。

### `Machine.ArgsSource.slice` (`src/exec/inline_calls.zig:1516`)

- **签名**：`inline fn slice(self: ArgsSource) []core.JSValue`。
- **作用**：把窗口整体取成切片（含 receiver/callable 两个绑定槽），供建帧路径一次性读写。
- **实现**：`values[0..valueCount()]`；`values` 是窗口首槽的裸指针，切片只是借用视图——调用方栈的源窗口在 `top_ptr` 之后，`pending_call_region` 负责让收集器仍能看到它。
- **所有权 / 错误 / 调用**：错误：无。所有权：返回借用窗口 `values[0..valueCount()]`（callee + 可选 receiver + 实参），值的释放义务仍按 `metadata.moved` 归调用方或 `cleanupStackSource`。调用：本文件 `:1839`、`:2072`、`:2235` 三处建帧路径。

### `Machine.ArgsSource.argCount` (`src/exec/inline_calls.zig:1520`)

- **签名**：`inline fn argCount(self: ArgsSource) usize`。
- **作用**：取这次调用的实参个数（不含 receiver / callable 绑定槽）。
- **实现**：把 `metadata.arg_count` 这个 u62 位段 `@intCast` 成 `usize`；`ArgsSource` 只有两个字，这一步在寄存器里完成。
- **所有权 / 错误 / 调用**：错误：无。所有权：只把 `metadata.arg_count` 位域展宽成 usize。调用：本文件 12 处准入/布局计算，如 `:1515`（`valueCount`）、`:1677`（padded 模式判定）、`:1891`（slab 尺寸）。

### `Machine.pushFrame` (`src/exec/inline_calls.zig:1542`)

- **签名**：`fn pushFrame( self: *Machine, comptime setup_path: FrameSetupPath, comptime stack_preflighted: bool, comptime copy_argv: bool, global: *core.Object, target: *const InlineTarget, source: ArgsSource, ) align(64) HostError!*Entry`。
- **作用**：同机调用的通用入帧核心：把调用深度/字节预算记上、从 chunk 池取一格 Entry、按 `setup_path` 选一条帧初始化特化、最后把新帧链进 Entry 链并递增 depth。
- **实现**：同机调用的唯一入帧核心。先按 `bytecodeFrameAllocaSize` 记账调用深度（`stack_preflighted` 时只 `commitInlineCallDepthBytes`，否则 `enterInlineCallDepthBytes`，失败先 `cleanupStackSource`）；`acquireSlot` 取 256 字节 Entry。`setup_path` 只有四个值：`generic`、`generic_after_exact_plain`、`moved_method`、`borrowed_iterator`——前两者先写 `.next`/0 continuation，`borrowed_iterator` 走 `setupBorrowedIteratorEntry`，`moved_method` 按 `methodSimpleInlineMode` 的 moved 四态选特化、否则 `setupInlineEntry`，`generic_after_exact_plain` 直接 `setupFallbackInlineEntry`，`generic` 再按 `isSimpleInlineFrame` / `isStrictSimpleInlineFrame` / fallback 三选一。成功后写 `teardown.copy_argv` 与 `planned_stack_bytes`，再 `prev = top; top = entry; depth += 1`（qjs sf->prev_frame / current_stack_frame）。返回新 top 指针给调用方直接用，避免再按 depth 索引。
- **所有权 / 错误 / 调用**：错误：`HostError`——`enterInlineCallDepthBytes` 超栈预算时先 `cleanupStackSource` 释放源窗口再上抛；`acquireSlot` 的 OOM 同样在清理后返回。所有权：Entry 取自 Machine 的 chunk 池（不分配），帧窗口按 `setup_path` 从 `VmStackArena` 或堆切；`copy_argv` 为真时实参被复制进帧、源窗口随后清理。调用：本文件 7 处 `:3411`、`:3516`、`:4471`、`:4473`、`:4492`、`:4533`、`:4772`，各自钉死一组 comptime 参数。

### `Machine.isSimpleInlineFrame` (`src/exec/inline_calls.zig:1623`)

- **签名**：`fn isSimpleInlineFrame(target: *const InlineTarget, source: ArgsSource) bool`。
- **作用**：判定这次 plain（无接收者、this 为 undefined）调用能不能用最便宜的 simple 建帧：实参就地借用调用方栈区、locals 与操作数栈从 arena 一块切出来。
- **实现**：五项与。第一项 `execution.simple_inline_eligible` 是 FunctionBytecode 终结时预计算好的一个字节，打包了「普通 kind、sloppy、简单形参、无全局变量重绑定」四件事——注释说明这替掉了原来约 6 次散落的 FB bool load（那串 `ldrb [fb,#…]` 曾主导 `op_call`）。其余四项与站点有关：`source.metadata.moved` 为真则退出（尾调用复用保留通用路径），`source.metadata.has_receiver` 为真则退出（那是方法形态），`target.this_value` 必须是 undefined，`canBorrowSourceArgs(function, source)` 必须成立。注释特别说明**不**做 capture 检查：`[]*core.VarRef` 这个类型本身就保证「每个 capture 都是 cell」（对齐 qjs `js_closure2` 的槽恒为 `JSVarRef*`，quickjs.c:17297-17331），原来的 `allCapturesAreCellsCached` 备忘与逐闭包 header load 循环已随 phase-D 删除。
- **所有权 / 错误 / 调用**：错误：无，任一条件不满足返回 false 走通用建帧。所有权：纯判定，不改 target/source。调用：本文件 `:1599`（`pushFrame` 的路由）、`:3405`，以及 `:2351` 的断言。

### `Machine.paddedSimpleInlineMode` (`src/exec/inline_calls.zig:1706`)

- **签名**：`fn paddedSimpleInlineMode(target: *const InlineTarget, source: ArgsSource) ?PaddedSimpleInlineMode`。
- **作用**：判定「实参不够、需要补 undefined」的 plain 调用能走哪一种 simple 建帧（sloppy / strict / strict+snapshot），不能走就返回 null。
- **实现**：先排除三种不适用：`source.metadata.moved` 或 `has_receiver` 为真、`target.this_value` 非 undefined、`source.argCount() >= function.arg_count`（实参够数就不是补参形态，归 `isSimpleInlineFrame` 那条）。通过后按 FB 预计算的三个资格位依次挑选并立即返回：`simple_inline_eligible` → `.sloppy`，`strict_simple_inline_eligible` → `.strict`，`strict_simple_snapshot_inline_eligible` → `.strict_snapshot`；都不中返回 null。
- **所有权 / 错误 / 调用**：错误：无，返回 null 表示不适用补参快路径。所有权：纯判定。调用：唯一调用方 `src/exec/inline_calls.zig:1751`（`setupFallbackInlineEntry` 的补参分派）。

### `Machine.methodSimpleInlineMode` (`src/exec/inline_calls.zig:1724`)

- **签名**：`fn methodSimpleInlineMode(target: *const InlineTarget, source: ArgsSource) ?MethodSimpleInlineMode`。
- **作用**：判定方法形态（栈区是 `[receiver, callable, args…]`）的调用能走哪一种 simple 建帧，结果是 stack/moved × snapshot/非 × 补参/精确共八个模式之一。
- **实现**：先要求 `source.metadata.has_receiver`，且 `target.this_value.same(source.values[0])`——目标绑定的 this 必须就是栈区第 0 槽那个接收者，否则退出。再看资格：`snapshot = strict_simple_snapshot_inline_eligible`，`no_snapshot = simple_inline_eligible or strict_simple_inline_eligible`，两者全假返回 null。`padded = sourceArgCount(source) < function.arg_count`。最后按 `moved`（尾调用/Proxy 续延消费的临时 owned 区）× `snapshot` × `padded` 三个 bool 组合出 `.stack_exact` / `.stack_padded` / `.stack_snapshot_exact` / `.stack_snapshot_padded` / `.moved_*` 八个枚举值之一。
- **所有权 / 错误 / 调用**：错误：无，返回 null 即退出方法快路径。所有权：纯判定，只读 `source.values[0]` 与 target 的 this 做同一性比较。调用：本文件 `:1588`、`:1741`、`:3571`（构造器版）。

### `Machine.isStrictSimpleInlineFrame` (`src/exec/inline_calls.zig:1754`)

- **签名**：`fn isStrictSimpleInlineFrame(comptime snapshot_args: bool, target: *const InlineTarget, source: ArgsSource) bool`。
- **作用**：`isSimpleInlineFrame` 的 strict 版：strict 函数不借全局当 this，帧的 `this` 直接写 undefined，其余 simple 建帧条件相同。
- **实现**：comptime 参数 `snapshot_args` 选资格位——真取 `execution.strict_simple_snapshot_inline_eligible`（函数体要一份不可变的原始实参快照，供未映射的 strict `arguments` 用），假取 `execution.strict_simple_inline_eligible`。资格不成立返回 false；随后与 sloppy 版同样的三项站点检查：非 moved、非 has_receiver、`this_value` 为 undefined、`canBorrowSourceArgs` 成立。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯判定，`snapshot_args` 是 comptime 参数，决定读 `strict_simple_snapshot_inline_eligible` 还是 `strict_simple_inline_eligible`。调用：本文件 `:1601`、`:1756`、`:3408` 与 `:2349` 的断言。

### `setupFallbackInlineEntry` (`src/exec/inline_calls.zig:1774`)

- **签名**：`noinline fn setupFallbackInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void`。
- **作用**：把 arguments-snapshot / 填充 / method 变体从 `pushFrame` 的公共分发器里拉开：命中 simple 形状则 `setupSimpleInlineEntryDispatch`，否则 `setupInlineEntry`。
- **实现**：先 `methodSimpleInlineMode`：`.stack_exact` / `.stack_padded` / snapshot 与 moved 八种组合各自 `setupSimpleInlineEntryDispatch(false, snapshot, pad, true, move, ...)`。再 `paddedSimpleInlineMode`：`.sloppy` / `.strict` / `.strict_snapshot`。再 `isStrictSimpleInlineFrame(true, ...)` 走 strict snapshot 无填充。全未命中才 `setupInlineEntry`。所有 callee 都是 noinline，本函数只返回它们的结果，ReleaseFast 可做成尾跳而不是再开一帧。
- **所有权 / 错误 / 调用**：不自己切 arena；由被调 setup 写 `entry.arena_mark` 与 frame 窗口。错误：`HostError`（OOM / 帧初始化失败）。调用：`Machine.pushFrame` 的 generic 冷臂。

### `Machine.simpleInlineSlabTotal` (`src/exec/inline_calls.zig:1787`)

- **签名**：`inline fn simpleInlineSlabTotal( function: *const bytecode.FunctionBytecode, actual_arg_count: usize, comptime pad_args: bool, comptime move_args: bool, comptime snapshot_args: bool, ) usize`。
- **作用**：算出一个 simple 帧要从 VM 栈 arena 上切多少个 `JSValue` 槽——即 qjs `alloca_size`（quickjs.c:17834-17836）的 zjs 版本。
- **实现**：五段相加：`arg_storage_count`（只有补参或 move 形态才需要实参存储，长度是 `pad_args ? function.arg_count : actual_arg_count`；精确借用形态为 0）、`var_count = function.var_count`、`stack_count = function.stack_size + 1`、`open_slots`（把 `frame_mod.frameOpenVarRefStorageCount(function)` 个 `?*core.VarRef` 按 `JSValue` 大小向上取整换算成槽数，计数为 0 时直接 0）、`snapshot_count`（仅 snapshot 形态等于 `actual_arg_count`）。三个 comptime 开关让每个特化只留下自己那几项。
- **所有权 / 错误 / 调用**：错误：无（纯算术，不检查溢出——输入都来自已验证的 `FunctionBytecode` 计数）。所有权：只返回槽数，不分配。调用：本文件 `:1891`（`setupSimpleInlineEntryDispatch`）与 `:1910`（构造器版）。

### `setupSimpleInlineEntryWarm` (`src/exec/inline_calls.zig:1810`)

- **签名**：`noinline fn setupSimpleInlineEntryWarm( comptime strict_this: bool, comptime pad_args: bool, comptime method_receiver: bool, comptime move_args: bool, comptime constructor_this: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource, carve: core.VmStackArena.ActiveCarve, ) void`。
- **作用**：simple 帧 setup 的热臂：调用方已成功 `carveActiveMarked`，本函数 `void`、不可失败，调用点不必付 error-union 检查。
- **实现**：`entry.catch_target = null`，`teardown = .{ .simple = true }`。comptime 断言 `!move_args or method_receiver`、`!constructor_this or (method_receiver and !move_args and !strict_this)`。按 pad/move 算出 `arg_storage_count`、`var_count`、`stack_count`、open-var-ref 槽，把 `carve.window` 切成 args/locals/stack/open。locals `@memset` 为 undefined，open refs 填 null。method 则 `takeSourceSlot` 接收者；strict 保 undefined this，sloppy 借 realm `global.value()`；callable `takeSourceSlot`。pad/move 时把 args memcpy 进 slab 并清空源槽，不足的 pad undefined。captures 借 `target.captureSlice()`。`ownership.storage = .borrowed`，`cold = null`。栈用 `Stack.initArenaWindow`。`noinline` 与 `setupSimpleInlineEntry` 同因：禁止折进 `pushExactSimpleFrame` / `pushConstructorCall` / `pushFrame`。
- **所有权 / 错误 / 调用**：窗口来自调用方已提交的 `ActiveCarve`；callable/receiver 从源槽 take。错误：无（不可失败）。调用：`setupSimpleInlineEntryDispatch` / `setupSimpleConstructorEntryDispatch` 的 carve 命中臂。

### `Machine.setupSimpleInlineEntryDispatch` (`src/exec/inline_calls.zig:1897`)

- **签名**：`inline fn setupSimpleInlineEntryDispatch( comptime strict_this: bool, comptime snapshot_args: bool, comptime pad_args: bool, comptime method_receiver: bool, comptime move_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource, ) HostError!void`。
- **作用**：simple 建帧的两臂分派器：先试「一次 carve 就拿到窗口」的暖臂，不成再落到会分配的权威实现。
- **实现**：非 snapshot 形态先按 `simpleInlineSlabTotal` 算出槽数，试 `rt.vm_stack.carveActiveMarked(total)`；命中就交给不可失败的 `setupSimpleInlineEntryWarm`（`void` 返回，调用点连 error-union 检查都不用付）。snapshot 形态或 carve 未命中，则回落到会分配的 `setupSimpleInlineEntry`。五个 comptime 开关（strict this / snapshot / 补参 / 方法接收者 / move 实参）原样透传给两臂。
- **所有权 / 错误 / 调用**：错误：`HostError`，由 `setupSimpleInlineEntry` 的堆分配路径上抛。所有权：非 snapshot 形态先试 `vm_stack.carveActiveMarked(total)` 直接在 arena 上切窗口（`setupSimpleInlineEntryWarm`，无错、无分配），切不动才回落到会分配的 `setupSimpleInlineEntry`。调用：本文件 19 处模式分派，如 `:1589`-`:1592` 的 moved 四态、`:1600`/`:1602`、`:1742` 起的 stack 四态。

### `Machine.setupSimpleConstructorEntryDispatch` (`src/exec/inline_calls.zig:1915`)

- **签名**：`inline fn setupSimpleConstructorEntryDispatch( comptime snapshot_args: bool, comptime pad_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource, ) HostError!void`。
- **作用**：构造器版的 simple 建帧两臂分派器，与 `setupSimpleInlineEntryDispatch` 同形，只是把 this 语义钉成「新建实例」。
- **实现**：与 `setupSimpleInlineEntryDispatch` 同形：非 snapshot 时按构造器版的槽数试 `carveActiveMarked`，命中走 `setupSimpleInlineEntryWarm`，但两个接收者相关的 comptime 参数被钉死成 `method_receiver = true`、`constructor_this = true`（构造器的栈区是 `[instance, callable, args…]` 的方法形状，`this` 是新建实例）；未命中或 snapshot 形态回落 `setupSimpleConstructorEntry`。只保留 `snapshot_args`/`pad_args` 两个开关，因为构造器不会出现 strict-this 与 moved 两种变体。
- **所有权 / 错误 / 调用**：错误：`HostError`，来自回落的 `setupSimpleConstructorEntry`。所有权：同 `setupSimpleInlineEntryDispatch`，但 warm 路径固定 `method_receiver=true`、`constructor_this=true`——`this` 是新建实例而非搬来的接收者。调用：本文件 `:3573`-`:3576` 四个构造器模式。

### `setupSimpleInlineEntry` (`src/exec/inline_calls.zig:1956`)

- **签名**：`noinline fn setupSimpleInlineEntry(comptime strict_this: bool, comptime snapshot_args: bool, comptime pad_args: bool, comptime method_receiver: bool, comptime move_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void`。
- **作用**：plain/method simple-inline 的直线 setup 入口（arena miss / snapshot 冷臂）。对齐 qjs `JS_CallInternal` 序言（quickjs.c:17828-17871）：一块 slab、指针算术分区、每个字段只写一次。
- **实现**：`return setupSimpleInlineEntryImpl(..., constructor_this=false, ...)`。`noinline` 是负荷：寄存器分配必须离开 `setupInlineEntry`/`pushFrame` 链；若 LLVM 折回去，simple 路径的 spill 会与通用路径耦合（实测 fib 3.09x→3.26x qjs）。
- **所有权 / 错误 / 调用**：实现在 Impl：arena carve 或 heap slab，`errdefer` 回滚 watermark / 堆块。错误：`HostError`。调用：`setupSimpleInlineEntryDispatch` 在 snapshot 或 `carveActiveMarked` 未命中时。

### `setupSimpleConstructorEntry` (`src/exec/inline_calls.zig:1977`)

- **签名**：`noinline fn setupSimpleConstructorEntry(comptime snapshot_args: bool, comptime pad_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void`。
- **作用**：simple 帧族的构造器成员：与方法调用共用同一条 `JS_CallInternal` 式序言，只把帧 `this` 写成 `.borrowed`（eager 实例归 `Entry.native_caller`）。
- **实现**：`return setupSimpleInlineEntryImpl(false, snapshot_args, pad_args, true, false, true, ...)`：`strict_this=false`、`method_receiver=true`、`move_args=false`、`constructor_this=true`。qjs `JS_CallConstructorInternal`（quickjs.c:20845）直入共享 alloca 序言（17828-17871），`JS_CALL_FLAG_CONSTRUCTOR` 不被那条字节码序言消费。`noinline` 负荷与 `setupSimpleInlineEntry` 相同：不得折回 `pushConstructorCall`，否则 spill 再与 push 壳耦合（fib 3.09x→3.26x 先例）。
- **所有权 / 错误 / 调用**：`this` 一次写成 `.borrowed`；fallback 实例由 `pushConstructorCall` 在本函数返回后写入 `native_caller` 并置 `teardown.constructor_completion`。错误：`HostError`。调用：`setupSimpleConstructorEntryDispatch` 在 snapshot 或 `carveActiveMarked` 未命中时。

### `Machine.setupSimpleInlineEntryImpl` (`src/exec/inline_calls.zig:1982`)

- **签名**：`inline fn setupSimpleInlineEntryImpl(comptime strict_this: bool, comptime snapshot_args: bool, comptime pad_args: bool, comptime method_receiver: bool, comptime move_args: bool, comptime constructor_this: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void`。
- **作用**：simple 帧族的唯一直线建帧体：一块 slab、指针算术分区、每个字段只写一次——对齐 qjs `JS_CallInternal` 的序言（quickjs.c:17828-17871）。六个 comptime 开关（strict this / snapshot / 补参 / 方法接收者 / move 实参 / 构造器 this）把 plain、strict、method、moved、constructor 全部形态压成同一份代码。
- **实现**：顺序是「先算、后切、再绑定」，且所有可失败步骤都排在任何所有权转移之前。①`entry.catch_target = null`，`entry.teardown = .{ .simple = true }`（整字节赋值顺带清掉上一个占用者留下的 native-caller 位）。②comptime 断言 `!move_args or method_receiver`、`!constructor_this or (method_receiver and !move_args and !strict_this)`，运行期断言 `source.metadata` 的 moved/has_receiver 与 comptime 开关一致。③算槽数，与 `simpleInlineSlabTotal` 同式（`arg_storage_count` + `var_count` + `stack_count` + `open_slots` + `snapshot_count`），并按 `pad_args` 断言 `actual_arg_count` 与 `function.arg_count` 的大小关系。④装 `errdefer`：非 move 形态下失败要 `cleanupStackSource(rt, source)` 直接释放窗口外的源区（不把它临时重新发布给 GC 视图）。⑤切 slab：先试 `rt.vm_stack.carveActiveMarked(total)` 暖臂（一次快照同时拿到 watermark 与窗口，只对活跃 chunk 的实际长度做一次容量分支，且 `entry.arena_mark` 在 carve 之后才发布，避免 LLVM 跨可能别名的 Entry store 重载 chunk_count/active/used）；未命中才 `mark()` + `carve()`，再不行 `rt.memory.alloc` 堆 slab 并置 `storage_on_heap`，两条 errdefer 分别回滚 watermark 与堆块。⑥指针算术分区（对齐 17855-17866）：`arg_storage | locals | stack | open | snapshot` 依次排布，`@memset(locals, undefined)`（17859-17860）、open 槽 `@memset(null)`（17866-17867）。⑦slab 切完后才重建源视图 `values = source.slice()`，取出 `receiver_slot`（仅方法形态）、`callable_slot`、`args`。⑧snapshot 形态在这里 `rt.memory.create(FrameCold)` 并把实参抄进 `original_args`——这是最后一个可失败点，放在 `takeSourceSlot` 之前以保住上面的源回滚 errdefer。⑨此后不再可失败：补参/move 形态 `@memcpy` 实参进前缀、把源槽 `@memset` 成 undefined、补参再把尾部填 undefined；精确形态继续就地借用调用方的操作数槽（qjs `arg_buf = argv`，17841）。⑩一次性写完 `entry.frame` 字面量（对齐 qjs 17838-17845 的「不做先默认后覆盖」）：`this_value` 由 comptime 三选一（方法取接收者、strict 保 undefined、sloppy 借 `global.value()`，对应 17933 的 sloppy 腿），`ownership.var_refs` 有 capture 时 `.borrowed` 否则 `.owned`，`ownership.storage` 按 `storage_on_heap` 取 `.owned`/`.borrowed`。构造器的兜底实例在此刻仍写 `.borrowed`——那份 owned 引用由紧随其后的 `pushConstructorCall` 记进 `Entry.native_caller`，中间没有可失败步骤。⑪最后 `entry.stack = Stack.initArenaWindow(...)` 把操作数栈建在同一块 slab 上。
- **所有权 / 错误 / 调用**：错误：`HostError`（切不到 arena 时向 `MemoryAccount` 要 slab 会 OOM）；`errdefer` 在非 move 形态下调 `cleanupStackSource(rt, source)` 把源窗口的值放掉。所有权：帧 storage 优先 arena 窗口、否则堆 slab（由 `Frame.ownership.storage` 记录，pop 时据此 free）；实参按 `pad_args`/`move_args`/`snapshot_args` 三个 comptime 开关决定复制、移动还是就地借用；操作数栈以 `Stack.initArenaWindow` 建在同一块 slab 上。调用：本文件 `:1943`（`setupSimpleInlineEntry`）与 `:1963`（`setupSimpleConstructorEntry`）两个 comptime 包装。

### `pushExactSimpleFrame` (`src/exec/inline_calls.zig:2175`)

- **签名**：`noinline fn pushExactSimpleFrame( self: *Machine, comptime strict_this: bool, comptime snapshot_args: bool, comptime method_receiver: bool, global: *core.Object, target: *const InlineTarget, source: ArgsSource, caller_fp: usize, ) align(32) ?*Entry`。
- **作用**：exact-simple 入帧的热探测（plain 与 method 两形态，非构造器）：深度/字节/chunk/arena 全是谓词；失败返回 null 且不改 depth、槽、arena、源所有权，调用方可进 Slow。
- **实现**：comptime 断言 `!method_receiver or !strict_this`。`snapshot_args` 直接 `return null`。`planned_stack_bytes = var_count*16 + stack_size*16 + var_ref_count*ptr`（copy_argv=false，argc>=arg_count）。`rt.hot.call_depth >= stack_size`、字节累加溢出、`caller_fp - planned < native_stack_limit` 任一则 null。新 chunk、`open_n > fast_open_var_ref_max`、无 active arena chunk、剩余不足 `total` 也 null。通过后提交 `active_bytecode_stack_bytes` / `call_depth` / `arena.used`，切 locals/stack/open，locals memset undefined，小 open 窗口 `storeOpenVarRefNulls`（避免 compiler_rt.memset 的 bl）。method 则 take receiver，strict 写 undefined this，否则借 global。args 借源窗口。`ownership.storage=.borrowed`。链 `prev=top`，`depth+=1`。HostError 在此不可达——qjs:17837 深度准入是纯谓词，溢出只在 Slow 抛。
- **所有权 / 错误 / 调用**：arena 窗口 borrowed；callable/receiver take 自源槽。错误：无（失败只 null）。调用：`pushExactSimpleOrSlow`；未命中再 `pushExactSimpleFrameSlow`。

### `pushExactSimpleFrameSlow` (`src/exec/inline_calls.zig:2308`)

- **签名**：`noinline fn pushExactSimpleFrameSlow( self: *Machine, comptime strict_this: bool, comptime snapshot_args: bool, comptime method_receiver: bool, global: *core.Object, target: *const InlineTarget, source: ArgsSource, ) align(32) HostError!*Entry`。
- **作用**：exact-simple 的权威可失败构造器。HostError（stack overflow、OOM）只活在这里；深度按 qjs:17837 经 `enterInlineCallDepthBytes` 再检查。
- **实现**：`return pushExactSimpleFrameImpl(...)`。`noinline` 让 Slow 做薄包装，热探测是 outlined 叶；固定 arity handler `bl` 那片叶而不是展开 Impl（r12-KNIFE §c）。
- **所有权 / 错误 / 调用**：失败时 Impl 的 `cleanupStackSource` + `leaveInlineCallDepthBytes` 回滚。错误：`HostError`。调用：`pushExactSimpleOrSlow` 在 snapshot 或热探测 null 时。

### `Machine.pushExactSimpleOrSlow` (`src/exec/inline_calls.zig:2318`)

- **签名**：`inline fn pushExactSimpleOrSlow( self: *Machine, comptime strict_this: bool, comptime snapshot_args: bool, comptime method_receiver: bool, global: *core.Object, target: *const InlineTarget, source: ArgsSource, ) HostError!*Entry`。
- **作用**：exact-simple（实参数量恰好够、就地借用调用方栈区）入帧的两臂入口：先跑不可失败的热探测，探测拒绝才走可失败的权威构造器。
- **实现**：三条路。`comptime snapshot_args` 为真直接走 `pushExactSimpleFrameSlow`（快探测里没有 snapshot 臂）；否则先调 `pushExactSimpleFrame(..., @frameAddress())`——`@frameAddress()` 传的是调用方的 C 栈帧地址，探测用它来算原生栈余量——命中就返回；返回 null 说明探测拒绝且**没有**改动 depth、槽、arena 与源所有权，此时再调 `pushExactSimpleFrameSlow` 重做一遍。
- **所有权 / 错误 / 调用**：错误：`HostError`，来自回落的 `pushExactSimpleFrameSlow`（栈预算或 chunk 扩容）。所有权：快路径 `pushExactSimpleFrame` 返回 null 时不留任何副作用，由 slow 版重做并负责源窗口清理；snapshot 形态直接走 slow。调用：本文件 `:3406`、`:3409`（plain 调用的 sloppy/strict 两臂）与 `:3510`、`:3513`（方法调用的普通/snapshot 两臂）。

### `Machine.pushExactSimpleFrameImpl` (`src/exec/inline_calls.zig:2338`)

- **签名**：`inline fn pushExactSimpleFrameImpl( self: *Machine, comptime strict_this: bool, comptime snapshot_args: bool, comptime method_receiver: bool, global: *core.Object, target: *const InlineTarget, source: ArgsSource, ) HostError!*Entry`。
- **作用**：exact-simple 入帧的可失败权威实现：把深度记账、取槽、建帧、挂链四步串成一个单元，热探测拒绝时由它兜底。
- **实现**：先是一组按 comptime 开关分流的断言：`method_receiver` 时核对非 moved、有 receiver、`target.this_value.same(source.values[0])`、`argCount() >= fb.arg_count`，并按 `snapshot_args` 检查对应的资格位；`strict_this` 时核对 `isStrictSimpleInlineFrame(false, ...)`；两者皆非时核对 `isSimpleInlineFrame(...)`。随后 `vm_call.bytecodeFrameAllocaSize(fb, argCount, false)` 定价一次（copy_argv 恒 false），`enterInlineCallDepthBytes` 记账，失败先 `cleanupStackSource` 再上抛，成功后装 `errdefer leaveInlineCallDepthBytes`。`acquireSlot` 取槽（同样的失败清理），写 `.next`/0 续延，`setupSimpleInlineEntryDispatch(strict_this, snapshot_args, pad=false, method_receiver, move=false, ...)` 建帧，写回 `planned_stack_bytes`，最后 `prev = top; top = entry; depth += 1` 并返回新 Entry。
- **所有权 / 错误 / 调用**：错误：`HostError`——`acquireSlot` 失败时先 `cleanupStackSource` 再上抛。所有权：Entry 来自 chunk 池；成功末尾把 `entry.prev` 接到旧 `top`、更新 `self.top` 并 `depth += 1`，实参窗口仍借用调用方栈。调用：唯一调用方是薄包装 `src/exec/inline_calls.zig:2303`（`pushExactSimpleFrameSlow`），comptime 参数由它透传。

### `pushEmptyLeafFrame` (`src/exec/inline_calls.zig:2398`)

- **签名**：`noinline fn pushEmptyLeafFrame( self: *Machine, comptime leaf_this: LeafThis, global: *core.Object, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]core.JSValue, ) HostError!*Entry`。
- **作用**：已发布空叶形状的深构造器：argc=0、无 locals/captures/open/arguments/direct eval；只初始化执行叶真正用到的操作数 arena。
- **实现**：`assertLeafEligible`，断言 `arg_count==0 && var_count==0 && openVarRefCount()==0`。调用方已把逻辑栈顶后撤，失败时 `errdefer` `freeSourceSlot` 释放 callable（及 method 的 receiver）。`enterInlineCallDepthBytes` → `acquireSlot` → `arena_mark`；carve `stack_size+1`，不够则 `memory.alloc` 并记 `storage_on_heap`。交给 `finishEmptyLeafFrame(..., callerResumePc())`。`leaf_this` 选区域布局与 this 臂：plain sloppy 借 realm global，strict 保 undefined，receiver 成为 callee 的 raw this。
- **所有权 / 错误 / 调用**：源槽在最后一次不可失败转移前仍是唯一所有者。错误：`HostError`（深度/槽/OOM）。调用：唯一直接调用方 `pushEmptyLeafCall`（dispatch 的 `pushEmptyLeafMiss` 也经它进入）。

### `pushExactArgsLeafFrame` (`src/exec/inline_calls.zig:2453`)

- **签名**：`noinline fn pushExactArgsLeafFrame( self: *Machine, comptime leaf_this: LeafThis, global: *core.Object, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]core.JSValue, argc: u16, ) align(32) HostError!*Entry`。
- **作用**：O1 权威构造器：argc==arg_count>0 的叶，args 窗口就地借自调用者区域（qjs `arg_buf = argv`，quickjs.c:17841）。独立函数体，避免与零参构造器共享参数化体后 LLVM tail-merge 打乱零参热臂。
- **实现**：`assertExactArgsLeafEligible`，断言 argc 匹配且 `var_count==0`、无 open refs。`errdefer` 逆序 `freeSourceSlot` 整个 args 窗 + callable + 可选 receiver。深度/槽/arena 与空叶相同，carve 失败走 heap。`finishExactArgsLeafFrame(..., native_caller=undefined)`。
- **所有权 / 错误 / 调用**：args 借调用者槽，backing 留给调用者下次 push 复用。错误：`HostError`。调用：唯一直接调用方 `pushExactArgsLeafCall`（dispatch 的 `pushExactArgsLeafMiss` 经它进入）。

### `pushCaptureLeafFrame` (`src/exec/inline_calls.zig:2513`)

- **签名**：`noinline fn pushCaptureLeafFrame( self: *Machine, comptime leaf_this: LeafThis, global: *core.Object, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]core.JSValue, ) HostError!*Entry`。
- **作用**：O2 权威构造器：零参叶、唯一帧窗口是继承的 capture 数组（`() => this.x`）。区域是 `[callable]` / `[receiver, callable]`，无 args 窗。
- **实现**：`assertCaptureLeafEligible`，断言 argc/var_count/open 为 0 且 `captures.len != 0`。`errdefer` 释放 callable（及 receiver）。深度/槽/arena/carve 同空叶。`finishCaptureLeafFrame`。单独函数体的原因与 exact-args 相同：共享参数化体会重排已建立的零参热臂。
- **所有权 / 错误 / 调用**：captures 借自闭包对象；源槽失败时释放。错误：`HostError`。调用：唯一直接调用方 `pushCaptureLeafCall`（dispatch 的 `pushCaptureLeafMiss` 经它进入）。

### `Machine.assertLeafEligible` (`src/exec/inline_calls.zig:2567`)

- **签名**：`inline fn assertLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts) void`。
- **作用**：Debug/Safe 断言：comptime 选定的 `leaf_this` 臂必须与 callee 发布的空叶资格位对上，且非 `.receiver` 时 strict 与 raw-undefined 臂一一对应。
- **实现**：按 comptime 的 `leaf_this` 分三臂断言 callee 的空叶资格位：`.sloppy_global` 要求 `execution.simple_inline_empty_leaf`，`.raw_undefined` 要求 `execution.raw_this_inline_empty_leaf`，`.receiver` 两者之一即可。`leaf_this != .receiver` 时再补一条：`function.isStrictMode() or function.runtimeStrictMode()` 必须恰好等于 `leaf_this == .raw_undefined`——即 strict 函数只能走 raw undefined 这条 this 臂，sloppy 函数只能借 realm global。全部是 `std.debug.assert`，ReleaseFast 下整体消失。
- **所有权 / 错误 / 调用**：错误：无，全部是 `std.debug.assert`（ReleaseFast 下整体消失）。所有权：只读 `call_facts.execution` 与 `FunctionBytecode` 的 strict 位，验证 `leaf_this` 选得与 callee 的空叶资格一致。调用：本文件 `:2401`、`:2863`、`:3430` 三条空叶 push 路径的入口断言。

### `Machine.assertExactArgsLeafEligible` (`src/exec/inline_calls.zig:2581`)

- **签名**：`inline fn assertExactArgsLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts) void`。
- **作用**：Debug/Safe 断言：comptime 选定的 `leaf_this` 臂必须与 callee 发布的精确实参叶资格位对上，且非 `.receiver` 时 strict 与 raw-undefined 臂一一对应。
- **实现**：与 `assertLeafEligible` 同构，只是资格位换成精确实参叶的那对：`.sloppy_global` → `simple_inline_exact_args_leaf`，`.raw_undefined` → `raw_this_inline_exact_args_leaf`，`.receiver` → 两者之一。非 `.receiver` 时同样断言 strict 位与 this 臂一一对应。
- **所有权 / 错误 / 调用**：错误：无，全是断言。所有权：只读 execution 位。调用：本文件 `:2458`、`:2921`、`:2978`（forwarded 形态钉死 `.receiver`）、`:3450`。

### `Machine.assertCaptureLeafEligible` (`src/exec/inline_calls.zig:2596`)

- **签名**：`inline fn assertCaptureLeafEligible(comptime leaf_this: LeafThis, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts) void`。
- **作用**：Debug/Safe 断言：comptime 选定的 `leaf_this` 臂必须与 callee 发布的 `capture_leaf_kind` 对上，且非 `.receiver` 时 strict 与 raw-undefined 臂一一对应。
- **实现**：读 `call_facts.execution.capture_leaf_kind` 这个三态枚举而非 bool 位：`.sloppy_global` 要求它等于 `.sloppy`，`.raw_undefined` 要求 `.raw_this`，`.receiver` 只要求不是 `.none`。非 `.receiver` 时同样断言 strict 位与 this 臂一一对应。
- **所有权 / 错误 / 调用**：错误：无，全是断言。所有权：只读 `execution.capture_leaf_kind` 与 strict 位。调用：本文件 `:2517`、`:3027`、`:3469` 三条 capture 叶 push 路径。

### `Machine.finishEmptyLeafFrame` (`src/exec/inline_calls.zig:2622`)

- **签名**：`inline fn finishEmptyLeafFrame( self: *Machine, comptime leaf_this: LeafThis, rt: *core.JSRuntime, entry: *Entry, global: *core.Object, function: *const bytecode.FunctionBytecode, region_start: [*]core.JSValue, stack_window: []core.JSValue, storage_on_heap: bool, planned_stack_bytes: usize, resume_pc: [*]const u8, ) *Entry`。
- **作用**：空叶帧的发布尾巴：调用方已经把深度记账、取槽、切 arena 做完，这里一次性写完 `entry.frame`/`stack`/`teardown`/恢复记录并挂链——这之后不再有任何可失败操作。
- **实现**：`method_receiver` 由 `leaf_this == .receiver` comptime 决定，`callable_slot` 是 `region_start[method_receiver ? 1 : 0]`。两条断言：`rt == self.ctx.runtime`，以及 `planned_stack_bytes == vm_call.bytecodeLeafFrameAllocaSize(function)`——定价由构造器算一次传进来，不在这里重推三个函数头标量（注释指出 LLVM 无法跨中间的 entry store 做 CSE，qjs 也只对 alloca_size 定价一次，quickjs.c:17828-17836）。随后一次性写 `entry.frame` 字面量：`this_value` 按 `leaf_this` 三选一（`.receiver` 用 `takeSourceSlot(&region_start[0])` 把值从调用方槽移走、`.raw_undefined` 写 undefined、`.sloppy_global` 取 `global.value()`），`current_function` 同样 `takeSourceSlot(callable_slot)`，`storage_values` 与 `ownership.storage` 按 `storage_on_heap` 二选一（堆兜底才算自有）。接着 `entry.stack = Stack.initArenaWindow(...)`，`teardown = { .simple = true, .empty_leaf = !storage_on_heap }`（堆兜底形态不发布叶位，返回走通用路径），`setEmptyLeafResume(resume_pc, region_start)` 写入 {resume pc, resume sp} 记录（堆形态下这几个字节是死的，通用返回路径不读）。最后 `prev = top; top = entry; depth += 1` 并返回 Entry。
- **所有权 / 错误 / 调用**：错误：无（前置全 `assert`，容量与预算由调用方先行保证）。所有权：`this` 按 `leaf_this` 取值——`.receiver` 用 `takeSourceSlot` 从调用方栈槽移走（源槽写 undefined），`.sloppy_global` 取 `global.value()`，`.raw_undefined` 直接 undefined；callee 同样 move 进 `current_function`；帧窗口是传进来的 arena carve（`storage_on_heap` 为真才算堆所有）。末尾接链 `top`/`depth += 1`。调用：本文件 `:2433`（`pushEmptyLeafFrame`）与 `:2896`（`tryPushEmptyLeafCallFast`）。

### `Machine.finishExactArgsLeafFrame` (`src/exec/inline_calls.zig:2685`)

- **签名**：`inline fn finishExactArgsLeafFrame( self: *Machine, comptime leaf_this: LeafThis, comptime forwarded: bool, rt: *core.JSRuntime, entry: *Entry, global: *core.Object, function: *const bytecode.FunctionBytecode, captures: []*core.VarRef, region_start: [*]core.JSValue, argc: u16, stack_window: []core.JSValue, storage_on_heap: bool, planned_stack_bytes: usize, resume_pc: [*]const u8, native_caller: core.JSValue, ) *Entry`。
- **作用**：精确实参叶帧的发布尾巴（O1）：与空叶尾巴并列的双生体，多做的只有一件事——把实参窗口就地绑到调用方区上（qjs `arg_buf = argv`，quickjs.c:17841）。`forwarded` 开关另外支持 `Function.prototype.call` 透明转发形态。
- **实现**：先 comptime 断言 `!forwarded or leaf_this == .receiver`，再按 `leaf_this` 选 this（receiver 取源槽、raw_undefined 写 undefined、sloppy_global 借 `global.value()`），args 窗口就地指向调用者区域 `region_start + (receiver?1:0) + 1`，`var_refs` 无条件 `.borrowed`，栈用 `Stack.initArenaWindow`。`forwarded` 臂置 `simple + special_return + has_native_caller` 并把跳过的 native 记录写进 `native_caller`（不设 `exact_args_leaf`）；非 forwarded 臂置 `exact_args_leaf = !storage_on_heap` 并 `setEmptyLeafResume(resume_pc, region_start)`。最后链 `prev`、`depth += 1`。
- **所有权 / 错误 / 调用**：错误：无。所有权：与 `finishEmptyLeafFrame` 同构，但实参窗口就地借用调用方栈上的 `argc` 个槽（`forwarded` 形态还记下 `native_caller`），不复制；成功后接链并 `depth += 1`。调用：本文件 `:2493`（`pushExactArgsLeafFrame`）、`:2949`（快路径）、`:3002`（forwarded 快路径）。

### `Machine.finishCaptureLeafFrame` (`src/exec/inline_calls.zig:2790`)

- **签名**：`inline fn finishCaptureLeafFrame( self: *Machine, comptime leaf_this: LeafThis, rt: *core.JSRuntime, entry: *Entry, global: *core.Object, function: *const bytecode.FunctionBytecode, captures: []*core.VarRef, region_start: [*]core.JSValue, stack_window: []core.JSValue, storage_on_heap: bool, planned_stack_bytes: usize, resume_pc: [*]const u8, ) *Entry`。
- **作用**：capture 叶帧（零实参、唯一的帧窗口是继承来的 capture 数组，典型形态 `() => this.x`）的发布尾巴。
- **实现**：与 `finishEmptyLeafFrame` 逐句同构——同样的 `callable_slot` 取法、同样两条断言、同样按 `leaf_this` 三选一的 this、同样的 `Stack.initArenaWindow` 与 `setEmptyLeafResume` 与挂链。两处差别：`entry.frame` 多写 `.var_refs = captures` 且 `ownership.var_refs` 恒为 `.borrowed`（capture 数组归 callable 所有，帧只借用）；`teardown` 发布的是 `.exact_args_leaf = !storage_on_heap` 而不是 `.empty_leaf`，于是零参返回臂得以保留它的单位测试，而这类帧的异常完成被路由到通用拆除。
- **所有权 / 错误 / 调用**：错误：无。所有权：与另两个 finish 同构，另把 `captures` 切片直接装进 `frame.var_refs`（借用 callable 的 capture 数组，`ownership.var_refs = .borrowed`）。调用：本文件 `:2548`（`pushCaptureLeafFrame`）与 `:3057`（快路径）。

### `Machine.callerResumePc` (`src/exec/inline_calls.zig:2846`)

- **签名**：`inline fn callerResumePc(self: *const Machine) [*]const u8`。
- **作用**：取出调用方「这次调用返回后该从哪条字节码继续」的指针——正是 `reloadAfterPop` 在返回时会重新推导的那个值，叶帧把它预先存进恢复记录，返回时一条 ldp 就能复原。
- **实现**：取调用者帧（`self.top` 非空时是它的 `frame`，否则 `l0.level.frame`），返回 `function.byteCode().ptr + frame.pc`，即调用者恢复执行的 pc。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读——从 `top` Entry（无则 L0）的帧算 `byteCode().ptr + pc`，返回的指针指向 callee 拥有的字节码缓冲。调用：本文件 `:2433`、`:2493`、`:2548` 三处，把调用方的续行 pc 交给 finish 系列当 resume 点。

### `Machine.tryPushEmptyLeafCallFast` (`src/exec/inline_calls.zig:2859`)

- **签名**：`pub inline fn tryPushEmptyLeafCallFast( self: *Machine, comptime leaf_this: LeafThis, rt: *core.JSRuntime, global: *core.Object, caller_stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]core.JSValue, resume_pc: [*]const u8, ) ?*Entry`。
- **作用**：空叶调用的暖建帧：不分配、不抛错，全部准入通过才动状态。返回 null 是纯 miss——调用深度、arena 水位、源槽所有权、Machine 链全都没变，调用方可以原样改调 `pushEmptyLeafCall` 去处理首次 Entry 分配、换 chunk、堆兜底、OOM 或逻辑栈溢出异常。`resume_pc` 由暖适配器从寄存器里直接透传，免得为了存恢复记录再去重载帧状态。
- **实现**：Debug/Safe 下有不变量断言（`caller_stack.topPtr() == region_start`、`assertLeafEligible`、rt 一致）。 K1 单次定价 `vm_call.bytecodeLeafFrameAllocaSize`；K2 准入即提交 `vm_call.tryCommitInlineCallDepthBytesRt`，随后 chunk 未分配或 `vm_stack.carveActiveMarked` 未命中都先 `vm_call.retreatInlineCallDepthBytesMiss` 再返回 null；命中则写 `.next`/0/catch_target/arena_mark 后交给 `finishEmptyLeafFrame`。
- **所有权 / 错误 / 调用**：错误：无——预算不够（`tryCommitInlineCallDepthBytesRt`）、chunk 不够、arena 切不动都返回 null，且失败前用 `retreatInlineCallDepthBytesMiss` 把已提交的字节数退回，调用方据此回落到会分配的 push。所有权：Entry 取自 chunk 池，帧窗口来自 `carveActiveMarked`（`entry.arena_mark = carve.mark`），实参 slot 在 finish 里 move 走。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:941`（`op_call` 的空叶臂）。

### `Machine.tryPushExactArgsLeafCallFast` (`src/exec/inline_calls.zig:2915`)

- **签名**：`pub inline fn tryPushExactArgsLeafCallFast( self: *Machine, comptime leaf_this: LeafThis, rt: *core.JSRuntime, global: *core.Object, caller_stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]core.JSValue, argc: u16, resume_pc: [*]const u8, ) ?*Entry`。
- **作用**：精确实参叶调用的暖建帧，与空叶版同样的「纯 miss」契约。
- **实现**：Debug/Safe 下有不变量断言（`assertExactArgsLeafEligible`、`arg_count == argc > 0`、rt 一致）。 与 `tryPushEmptyLeafCallFast` 同一 K1/K2 结构：`vm_call.bytecodeLeafFrameAllocaSize` 定价、`vm_call.tryCommitInlineCallDepthBytesRt` 准入、chunk/`vm_stack.carveActiveMarked` 未命中走 `vm_call.retreatInlineCallDepthBytesMiss` 返回 null；命中交给 `finishExactArgsLeafFrame(..., forwarded=false, native_caller=undefined)`。
- **所有权 / 错误 / 调用**：错误：无；三道 miss（栈预算、chunk、arena）都回退预算后返回 null。所有权：同空叶快路径，另把调用方栈上的 `argc` 个实参槽就地借给帧，不复制。调用：`src/exec/tailcall_dispatch.zig:959`（`op_call`）与 `:6942`（方法调用臂）。

### `Machine.tryPushForwardedExactArgsLeafFast` (`src/exec/inline_calls.zig:2973`)

- **签名**：`pub inline fn tryPushForwardedExactArgsLeafFast( self: *Machine, rt: *core.JSRuntime, global: *core.Object, caller_stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]core.JSValue, argc: u16, native_caller: core.JSValue, ) ?*Entry`。
- **作用**：`Function.prototype.call`/`apply` 透明转发到精确实参叶时的暖建帧：`op_call_method` 的窗口重写已经把区域整成方法布局 `[thisArg, f, args…]`，所以这条等价于 `tryPushExactArgsLeafCallFast(.receiver, ...)`，只是把被跳过的那条合成 native `call`/`apply` 记录塞进本该放恢复记录的槽里。在这条臂之前，转发调用得走通用的 exact-simple 帧（`pushMethodCall` → `pushExactSimpleFrame`）并经 `popOrdinaryFrame` + `reloadAfterPop` 退役，而形状完全相同的 `recv.m(x)` 却走叶构造器与扁平重发布。
- **实现**：Debug/Safe 下有不变量断言（按 `.receiver` 臂做 `assertExactArgsLeafEligible`、`arg_count == argc > 0`）。 定价/准入/回退与 `tryPushExactArgsLeafCallFast` 相同；命中则交给 `finishExactArgsLeafFrame(.receiver, forwarded=true, ..., resume_pc=undefined, native_caller)`，即把被跳过的 native `Function.prototype.call` 记录写进帧。
- **所有权 / 错误 / 调用**：错误：无，miss 走 null + 预算回退。所有权：`native_caller` 被存进 Entry，pop 时由 forwarded 叶的 teardown 处理；实参窗口借用不复制。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:1275`（宿主转发的精确实参叶）。

### `Machine.tryPushCaptureLeafCallFast` (`src/exec/inline_calls.zig:3022`)

- **签名**：`pub inline fn tryPushCaptureLeafCallFast( self: *Machine, comptime leaf_this: LeafThis, rt: *core.JSRuntime, global: *core.Object, caller_stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]core.JSValue, resume_pc: [*]const u8, ) ?*Entry`。
- **作用**：capture 叶调用（零实参、只带继承 capture 数组）的暖建帧，同样遵守「miss 不留副作用」契约。
- **实现**：Debug/Safe 下有不变量断言（`assertCaptureLeafEligible`、`captures.len != 0`）。 定价/准入/回退与 `tryPushEmptyLeafCallFast` 相同；命中交给 `finishCaptureLeafFrame`。
- **所有权 / 错误 / 调用**：错误：无，miss 走 null + 预算回退（`assert(captures.len != 0)` 保证这是带捕获的形态）。所有权：`captures` 借自 callable，帧窗口来自 arena carve。调用：`src/exec/tailcall_dispatch.zig:1039` 与 `:6972`。

### `setupInlineEntry` (`src/exec/inline_calls.zig:3075`)

- **签名**：`pub noinline fn setupInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void`。
- **作用**：通用同机帧 setup：零拷贝 args move（`initArgumentsMoved`）、this 绑定、arena carve。不是 dup 重的 `callFunctionBytecodeModeState`。调用方负责深度记账。
- **实现**：`teardown = .{}`。`arena_mark` + `errdefer restore`。`Frame.init` + `errdefer frame.deinit`。plain undefined this：strict 保 undefined，sloppy 用 `global.value()`；method 若 `effective_this.same(slot)` 则 `takeSourceSlot`。`errdefer cleanupSource`。`current_function` 总是 take callable 槽。能借源 args（`canBorrowSourceArgs`）则 `initArgumentsBorrowedSlots` 并把 cleanup 收成 `.non_args`；否则 `initArgumentsMoved`。非 global-var 且 captures 非空则 `frame.var_refs` 直接别名闭包数组（qjs `var_refs = p->u.func.var_refs`，quickjs.c:17844），`ownership.var_refs=.borrowed`；否则 `initFrameVarRefs`。slab 先 `FrameSlab.carve`，失败 `allocHeap` 并 `installOwnedStorage`。`initFrameLocals`、open-var-ref 槽。成功后 `cleanupSource` 并把 cleanup 置 `.none`。
- **所有权 / 错误 / 调用**：部分初始化由 errdefer 释放：watermark、Frame、源窗、stack。错误：`HostError`。调用：`pushFrame` generic、`setupFallbackInlineEntry` 未命中 simple、`pushConstructorCall` 非 simple 模式、`pushDerivedConstructorCall`。

### `Machine.isBorrowedIteratorSimpleInlineFrame` (`src/exec/inline_calls.zig:3217`)

- **签名**：`inline fn isBorrowedIteratorSimpleInlineFrame(target: *const InlineTarget, iterator_record: []const core.JSValue) bool`。
- **作用**：判定一次 for-of 的 `iterator.next()` 能不能用「借用迭代器记录」的 simple 建帧——即 this 与 callee 直接借用挂起调用方栈上那两个槽，不再复制。
- **实现**：三项同一性检查加一项资格：`iterator_record.len` 必须恰好是 2；`target.this_value.same(iterator_record[0])`（this 就是记录里的 iterator 对象）；`target.callable.same(iterator_record[1])`（callee 就是记录里缓存的 `next` 方法）。三项都过后，再要求 `execution` 三个 simple 资格位（`simple_inline_eligible` / `strict_simple_inline_eligible` / `strict_simple_snapshot_inline_eligible`）至少命中一个。
- **所有权 / 错误 / 调用**：错误：无；`iterator_record` 不是两元、this/callee 与记录不同一、callee 无 simple 资格都返回 false。所有权：纯比较，不动 record。调用：唯一调用方 `src/exec/inline_calls.zig:4530`（`pushBorrowedIteratorNext` 的准入）。

### `setupBorrowedIteratorEntry` (`src/exec/inline_calls.zig:3233`)

- **签名**：`noinline fn setupBorrowedIteratorEntry(ctx: *core.JSContext, entry: *Entry, target: *const InlineTarget) HostError!void`。
- **作用**：零参 method 序言：this/callable 借自挂起调用者的 iterator record（qjs `JS_CallInternal` 赋 `sf->cur_func` 且不 retain `this_obj`）。独立于已建立的 plain/method setup，避免扰动它们的选择器/寄存器。
- **实现**：`teardown = .{ .simple = true }`。按 `arg_count + var_count + stack_size+1 + open_slots` 算 total。`arena_mark`；carve 失败则 heap alloc。分区 args/locals/stack/open，args/locals memset undefined，open 填 null。`this_value = target.this_value`、`current_function = target.callable`（borrow，不 take）、`actual_arg_count = 0`。captures 借 `captureSlice()`。`storage_values` 仅 heap 时指向 slab。所有可失败工作完成后才写 Frame。
- **所有权 / 错误 / 调用**：调用绑定仍由调用者 iterator record 拥有；本帧只拥有 slab。错误：`HostError`（carve/heap）。调用：`pushFrame` 的 `.borrowed_iterator` 臂（`:1586`），该路径由 `pushBorrowedIteratorNext` 选中。

### `Machine.sourceCallableSlot` (`src/exec/inline_calls.zig:3296`)

- **签名**：`fn sourceCallableSlot(source: ArgsSource) *core.JSValue`。
- **作用**：在调用区里定位 callee 所在的那个槽——`plain` 布局是 `[callable, args…]`，`method` 布局是 `[receiver, callable, args…]`，索引差一个接收者。
- **实现**：`&source.values[@intFromBool(source.metadata.has_receiver)]`：用 bool 转 0/1 当下标偏移，无分支。
- **所有权 / 错误 / 调用**：错误：无。所有权：返回调用方栈上 callee 槽的借用指针（有 receiver 时在索引 1，否则 0），后续通常被 `takeSourceSlot` 移走。调用：唯一调用方 `src/exec/inline_calls.zig:3075`（通用建帧路径取 callable）。

### `Machine.sourceReceiverSlot` (`src/exec/inline_calls.zig:3300`)

- **签名**：`fn sourceReceiverSlot(source: ArgsSource) ?*core.JSValue`。
- **作用**：在调用区里定位接收者槽；plain 布局没有接收者，返回 null。
- **实现**：`if (source.metadata.has_receiver) &source.values[0] else null`——method 布局的接收者恒在区首。
- **所有权 / 错误 / 调用**：错误：无；无 receiver 时返回 null。所有权：返回栈上 receiver 槽的借用指针。调用：唯一调用方 `src/exec/inline_calls.zig:3092`。

### `Machine.takeSourceSlot` (`src/exec/inline_calls.zig:3304`)

- **签名**：`inline fn takeSourceSlot(slot: *core.JSValue) core.JSValue`。
- **作用**：把调用区某个槽里的值移交给帧：读出值并把源槽写成 undefined，使这个值在任一时刻只有一个所有者。
- **实现**：三行 move：读出 `slot.*`，把源槽写成 `undefined`，返回读到的值。清源槽是关键——建帧后这个值由帧持有，源槽必须停止被 GC 的精确 walk 当作活引用，否则同一个值会被两处同时视为活。
- **所有权 / 错误 / 调用**：错误：无。所有权：move 语义——读出值后把源槽写成 undefined，值的所有权转给帧；因为 VM 值不计引用计数，这一步只保证同一个值不被两处同时视为活。调用：本文件 14 处建帧点，如 `:1859`、`:2266`、`:2640`（`finishEmptyLeafFrame` 的 `.receiver` 臂）。

### `Machine.storeOpenVarRefNulls` (`src/exec/inline_calls.zig:3314`)

- **签名**：`inline fn storeOpenVarRefNulls(dst: []?*core.VarRef) void`。
- **作用**：把一个小的 open var-ref 窗口填 null：按长度 comptime 展开成定量 store，避开 `compiler_rt.memset` 的 `bl`。
- **实现**：断言长度落在 1..=`fast_open_var_ref_max`（16），随后 comptime 展开 16 个 `n == k` 比较，命中哪个就用 `inline for` 的 k 条定量指针 store 把窗口写满 null 并返回。上界 16 来自 EB 的 open-ref miss 直方图（99.97% 在 ≤10），目的就是让这条 Fast 叶路径不出现 `compiler_rt.memset` 的 `bl`。
- **所有权 / 错误 / 调用**：所有权：写的是通用 push 刚从 arena slab 切出来的 open var-ref 窗口，本函数不分配。 错误：无。 调用：唯一调用方是 `pushExactSimpleFrame`（exact-simple 热探测）的 slab 切分处（2244），且只在 `open_n != 0` 时进来。

### `Machine.sourceHasStackRegion` (`src/exec/inline_calls.zig:3327`)

- **签名**：`fn sourceHasStackRegion(source: ArgsSource) bool`。
- **作用**：问这次调用的实参来源是不是调用方操作数栈上的那段 `PendingCallRegion`（而不是尾调用/Proxy 续延交来的临时 owned 区）——决定失败时要不要整段清理。
- **实现**：`return !source.metadata.moved`：`moved` 位为真表示区已是临时 owned 的、由建帧路径独占消费，假则实参还在调用方栈区里。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `metadata.moved`——非 moved 表示实参还在调用方操作数栈的 `PendingCallRegion` 里，失败时要整段清理。调用：唯一调用方 `src/exec/inline_calls.zig:3110`（决定 `SourceCleanupMode`）。

### `Machine.sourceArgCount` (`src/exec/inline_calls.zig:3331`)

- **签名**：`fn sourceArgCount(source: ArgsSource) usize`。
- **作用**：取这次调用的实参个数（不含 callee 与可选接收者）。
- **实现**：`return source.argCount()`，即把 `metadata` 里的 u62 位段 `arg_count` 展宽成 usize。存在这个同名转发是为了让本文件的准入/布局代码统一用 `sourceXxx(source)` 的写法。
- **所有权 / 错误 / 调用**：错误：无。所有权：转发 `source.argCount()`，只读。调用：本文件 `:1699`（padded 判定）、`:3125`、`:3345`。

### `Machine.sourceArgs` (`src/exec/inline_calls.zig:3335`)

- **签名**：`fn sourceArgs(source: ArgsSource) []core.JSValue`。
- **作用**：从调用区切出纯实参那一段切片，跳过 callee 与可选接收者。
- **实现**：`args_start = 1 + @intFromBool(source.metadata.has_receiver)`（plain 跳 1 个 callee，method 跳 receiver+callable 共 2 个），再取 `source.values[args_start..][0..source.argCount()]`。
- **所有权 / 错误 / 调用**：错误：无。所有权：返回借用切片——跳过 callee 与可选 receiver 后的 `argCount()` 个槽，仍归调用方栈所有。调用：本文件 `:3182`、`:3192`（把实参交给帧初始化）。

### `Machine.canBorrowSourceArgs` (`src/exec/inline_calls.zig:3340`)

- **签名**：`fn canBorrowSourceArgs(function: *const bytecode.FunctionBytecode, source: ArgsSource) bool`。
- **作用**：判定帧能否就地借用调用方栈上的实参窗口而不复制——这是 simple 建帧最省的那一档（qjs `arg_buf = argv`）。
- **实现**：两条。先用 `@max(argc, function.arg_count) != argc` 表达「实参不足形参」（写成 max 而不是 `<` 是为了让 argc 保持在寄存器里做一次 umax+cmp）；不足就得补 undefined，不能借用。再要求 `!source.metadata.moved`：moved 区是临时 owned 的，值必须搬进帧而不是借。
- **所有权 / 错误 / 调用**：错误：无；实参少于形参（需要补 undefined）或已 moved 都返回 false。所有权：纯判定，决定帧能否直接借用调用方栈上的实参窗口而不复制。调用：本文件 `:1641`、`:1730`、`:3128`。

### `Machine.cleanupSource` (`src/exec/inline_calls.zig:3352`)

- **签名**：`fn cleanupSource(source: ArgsSource, mode: SourceCleanupMode) void`。
- **作用**：按调用点算好的清理模式处置调用区：建帧失败时要把没交出去的值放掉，成功时也要把已经被帧接手的那部分排除在外。
- **实现**：对 `SourceCleanupMode` 做三臂 switch：`.none` 空操作（源已 moved 或整段都归帧），`.full` → `cleanupStackSource`（整段清），`.non_args` → `cleanupStackSourcePreserveArgs`（只清 receiver 与 callee，实参已被帧借走）。
- **所有权 / 错误 / 调用**：错误：无。所有权：按 `SourceCleanupMode` 三态转发——`.none` 什么都不做，`.full` 清整段，`.non_args` 只清 callee/receiver（实参已被帧接手）。调用：本文件 `:3111` 的 `errdefer` 与 `:3198` 的成功路径。

### `Machine.cleanupStackSource` (`src/exec/inline_calls.zig:3360`)

- **签名**：`fn cleanupStackSource(source: ArgsSource) void`。
- **作用**：把调用方栈上这段调用区整段置空：建帧在把值交给帧之前失败时用它，保证没有槽既被放弃又仍被当成活值。
- **实现**：`source.metadata.moved` 为真直接返回（moved 区不归调用方栈）。否则从 `source.valueCount()` 倒着往 0 走，逐槽 `freeSourceSlot(&source.values[index])`。倒序是为了与建帧时的正序转移对称。
- **所有权 / 错误 / 调用**：错误：无；`metadata.moved` 为真直接返回（这段值已归帧）。所有权：从窗口尾部倒着把 `valueCount()` 个槽交给 `freeSourceSlot`，即把 `PendingCallRegion` 整段置空，防止收集器重复看见。调用：本文件 10 处失败清理，如 `:1566`、`:2007`、`:2364`、`:3359`。

### `Machine.cleanupStackSourcePreserveArgs` (`src/exec/inline_calls.zig:3369`)

- **签名**：`fn cleanupStackSourcePreserveArgs(source: ArgsSource) void`。
- **作用**：只清调用区里的接收者与 callee 两槽，实参留着——用于「帧已经把实参窗口借走了，但其余部分要放弃」的收尾。
- **实现**：`moved` 源直接返回。否则：有接收者就先 `freeSourceSlot(&values[0])`，再 `freeSourceSlot(&values[@intFromBool(has_receiver)])` 清 callee 槽（plain 布局下这两个索引会重合到 0，但 plain 不进这条分支的第一句）。
- **所有权 / 错误 / 调用**：错误：无；moved 源直接返回。所有权：只清 receiver 与 callee 两槽，实参留给已经接手它们的帧。调用：唯一调用方 `src/exec/inline_calls.zig:3360`（`cleanupSource` 的 `.non_args` 臂）。

### `Machine.freeSourceSlot` (`src/exec/inline_calls.zig:3377`)

- **签名**：`inline fn freeSourceSlot(slot: *core.JSValue) void`。
- **作用**：放弃调用区里的一个槽：VM 值不计引用计数，所以「释放」就是把它写成 undefined，让 GC 的精确 walk 不再把它当活引用。
- **实现**：单行 `slot.* = core.JSValue.undefinedValue()`。（原先带一个 `_: *core.JSRuntime` 首参，整条 `cleanupSource`/`cleanupStackSource`/`cleanupStackSourcePreserveArgs` 链上的 `rt` 实参都只是穿过、无人使用，已一并删除。）
- **所有权 / 错误 / 调用**：错误：无。所有权：VM 值不计引用计数，所以「释放」就是把槽写成 undefined，让收集器的精确 walk 不再把它当活值。调用：本文件 10 处，如 `:2411`、`:2471`、`:3369`（`cleanupStackSource` 的循环体）。

### `Machine.pushPlainCall` (`src/exec/inline_calls.zig:3387`)

- **签名**：`pub inline fn pushPlainCall( self: *Machine, global: *core.Object, caller_stack: *stack_mod.Stack, target: *const InlineTarget, region_start: [*]core.JSValue, argc: u16, ) HostError!*Entry`。
- **作用**：plain 形态（栈区 `[callable, args…]`、this 不是显式接收者）同机调用的入帧选择器：从最窄的空叶一路退到通用建帧。
- **实现**：先断言 `caller_stack.topPtr() == region_start`（调用方逻辑栈顶已后撤到区首）。然后按代价从低到高四选一：`execution.simple_inline_empty_leaf && argc == 0` → `pushEmptyLeafCall(.sloppy_global, ...)`；`raw_this_inline_empty_leaf && argc == 0` → `pushEmptyLeafCall(.raw_undefined, ...)`（strict 函数的空叶，this 写 raw undefined）；否则用 `ArgsSource.initStack(region_start, argc, false)` 包出借用源，`isSimpleInlineFrame` 命中走 `pushExactSimpleOrSlow(strict=false, snapshot=false, method=false, ...)`，`isStrictSimpleInlineFrame(false, ...)` 命中走同一函数的 strict 臂；全不中则 `pushFrame(.generic_after_exact_plain, ...)`——这个 setup_path 告诉 `pushFrame` 精确 plain 形态已试过，直接进 fallback 建帧。
- **所有权 / 错误 / 调用**：错误：`HostError`，由被选中的 push 路径上抛（源窗口清理在各自路径内完成）。所有权：Entry 与帧窗口的所有权全在被调路径；本函数只按 `execution` 位和 argc 选臂，并用 `ArgsSource.initStack` 把调用方栈段包成借用源。调用：本文件 `:3678`（`pushCall` 的 `.plain` 臂）与 `src/exec/tailcall_dispatch.zig:855`。

### `Machine.pushEmptyLeafCall` (`src/exec/inline_calls.zig:3418`)

- **签名**：`pub inline fn pushEmptyLeafCall( self: *Machine, comptime leaf_this: LeafThis, global: *core.Object, caller_stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]core.JSValue, ) HostError!*Entry`。
- **作用**：空叶调用的入口薄壳：核对调用方栈顶与资格，然后转交权威构造器 `pushEmptyLeafFrame`。
- **实现**：两条断言后一次转发：`std.debug.assert(caller_stack.topPtr() == region_start)` 确认调用方逻辑栈顶已后撤到区首；`assertLeafEligible(leaf_this, function, call_facts)` 确认 `leaf_this` 这条 this 臂与 callee 发布的空叶资格位一致；随后 `return self.pushEmptyLeafFrame(...)`。壳与体分开是为了让断言在 ReleaseFast 消失后这里退化成纯尾调。
- **所有权 / 错误 / 调用**：错误：`HostError`，由 `pushEmptyLeafFrame` 的栈预算/chunk 扩容上抛。所有权：只做断言并转发，帧窗口与 `region_start` 上 callee/receiver 槽的接管都在下游完成。调用：本文件 `:3399`、`:3402`（`pushPlainCall` 的两种 this 形态）与 `src/exec/tailcall_dispatch.zig:980`、`:1007`（快路径 miss 后的回落）。

### `Machine.pushExactArgsLeafCall` (`src/exec/inline_calls.zig:3436`)

- **签名**：`pub inline fn pushExactArgsLeafCall( self: *Machine, comptime leaf_this: LeafThis, global: *core.Object, caller_stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]core.JSValue, argc: u16, ) HostError!*Entry`。
- **作用**：精确实参叶调用的入口薄壳（argc == arg_count > 0），核对后转交 `pushExactArgsLeafFrame`。
- **实现**：同 `pushEmptyLeafCall` 的两条断言（`caller_stack.topPtr() == region_start`、`assertExactArgsLeafEligible`），然后把 `captures` 与 `argc` 一并转发给 `pushExactArgsLeafFrame`。
- **所有权 / 错误 / 调用**：错误：`HostError`，来自 `pushExactArgsLeafFrame`。所有权：`captures` 借自 callable，实参窗口借调用方栈；本函数不分配。调用：`src/exec/tailcall_dispatch.zig:1024`、`:6926`、`:6943`（后者是 `tryPushExactArgsLeafCallFast` miss 后的 slow 臂）。

### `Machine.pushCaptureLeafCall` (`src/exec/inline_calls.zig:3456`)

- **签名**：`pub inline fn pushCaptureLeafCall( self: *Machine, comptime leaf_this: LeafThis, global: *core.Object, caller_stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]core.JSValue, ) HostError!*Entry`。
- **作用**：capture 叶调用的入口薄壳（零实参、只有继承来的 capture 数组），核对后转交 `pushCaptureLeafFrame`。
- **实现**：断言 `caller_stack.topPtr() == region_start` 与 `assertCaptureLeafEligible(leaf_this, ...)`，然后转发给 `pushCaptureLeafFrame`（`captures` 必非空，这一点由 `pushCaptureLeafFrame` 内的断言把关）。
- **所有权 / 错误 / 调用**：错误：`HostError`，来自 `pushCaptureLeafFrame`。所有权：同上，`captures` 非空且借用。调用：`src/exec/tailcall_dispatch.zig:1068`、`:6957`、`:6973`（快路径 miss 的回落）。

### `Machine.pushMethodCall` (`src/exec/inline_calls.zig:3491`)

- **签名**：`pub inline fn pushMethodCall( self: *Machine, global: *core.Object, caller_stack: *stack_mod.Stack, target: *const InlineTarget, region_start: [*]core.JSValue, argc: u16, ) HostError!*Entry`。
- **作用**：method 形态（栈区 `[receiver, callable, args…]`）同机调用的入帧选择器。
- **实现**：断言栈顶等于区首后，用 `ArgsSource.initStack(region_start, argc, true)` 包出带接收者的借用源。先过一道共用的 arity 闸门 `argc >= function.arg_count`——注释说明把它提前，是让需要补参的兄弟形态只失败一次比较就直奔通用选择器，而不必把每个资格字节都读一遍。闸门内按资格二选一：`simple_inline_eligible` → `pushExactSimpleOrSlow(strict=false, snapshot=false, method=true, ...)`；`strict_simple_snapshot_inline_eligible` → 同函数的 snapshot 臂。都不中（含 argc 不足）则 `pushFrame(.generic, false, false, ...)`。
- **所有权 / 错误 / 调用**：错误：`HostError`，由被选中的 push 路径上抛。所有权：`ArgsSource.initStack(..., true)` 表示窗口首槽是 receiver；实参够数且 callee 有 simple 资格时借用窗口，否则 `pushFrame(.generic)` 复制。调用：`src/exec/tailcall_dispatch.zig:856`、`:882`、`:1290`、`:5849`，以及本文件 `:3679`（`pushCall` 的 `.method` 臂）。

### `pushConstructorCall` (`src/exec/inline_calls.zig:3524`)

- **签名**：`pub noinline fn pushConstructorCall( self: *Machine, global: *core.Object, caller_stack: *stack_mod.Stack, target: *const InlineTarget, region_start: [*]core.JSValue, argc: u16, owned_new_target: ?core.JSValue, ) align(16) HostError!*Entry`。
- **作用**：在本 Machine 进入普通构造器。调用方已把区域改写成 `[instance, callable, args...]`；setup 后 fallback 实例所有权从 `Frame.this_value` 挪到 `Entry.native_caller`，this 只借活实例。
- **实现**：断言 `topPtr()==region_start` 且 `this_value.is(.object)`。`initStack(..., has_receiver=true)`。`enterInlineCallDepthBytes` 失败则 `cleanupStackSource`。`acquireSlot` 同样。`return_action=.constructor`。`methodSimpleInlineMode` 命中则 `setupSimpleConstructorEntryDispatch`（moved 变体 unreachable，source 来自 initStack）；否则 `setupInlineEntry`。`errdefer entry.deinit`。setup 之后才设 `native_caller = this_value`、`teardown.constructor_completion=true`（setup 会整字节覆盖 teardown）。`ownership.new_target=.aliases_function`；若 `owned_new_target` 则 `takeConstructorNewTarget`。链 prev、depth++。对齐 `JS_CallConstructorInternal` → 共享 alloca 序言（quickjs.c:20845 / 17828-17871）；`JS_CALL_FLAG_CONSTRUCTOR` 不被那条字节码序言消费。
- **所有权 / 错误 / 调用**：fallback 实例由 `native_caller` 单所有；this `.borrowed`。spread 的 `owned_new_target` 成功才接管，失败仍归调用方。错误：`HostError`。调用：`enterSameMachineSpreadConstructor` / `op_call_constructor` 的普通构造臂。

### `pushDerivedConstructorCall` (`src/exec/inline_calls.zig:3614`)

- **签名**：`pub noinline fn pushDerivedConstructorCall( self: *Machine, global: *core.Object, caller_stack: *stack_mod.Stack, target: *const InlineTarget, region_start: [*]core.JSValue, argc: u16, owned_new_target: ?core.JSValue, ) HostError!*Entry`。
- **作用**：`pushConstructorCall` 的 derived 孪生：无 eager 实例，this 保持 uninitialized，直到 super()/return 字节码解析；`native_caller=undefined` 作无 fallback 哨兵。
- **实现**：断言 `this_value.is(.uninitialized)`。深度/槽/cleanup 同普通构造。只走 `setupInlineEntry`（不走 simple constructor dispatch）。`ownership.new_target=.aliases_function`，可选 `takeConstructorNewTarget`。断言 this 仍 uninitialized。`native_caller=undefinedValue()`，`constructor_completion=true`。链 prev、depth++。
- **所有权 / 错误 / 调用**：无 fallback 实例；完成时 `popConstructorReturn` 见 undefined 则转发结果。错误：`HostError`。调用：`pushDerivedConstructorEntry` / `pushSpreadDerivedConstructorEntry`。

### `Machine.pushCall` (`src/exec/inline_calls.zig:3663`)

- **签名**：`pub inline fn pushCall( self: *Machine, global: *core.Object, caller_stack: *stack_mod.Stack, target: *const InlineTarget, region_start: [*]core.JSValue, argc: u16, layout: RegionLayout, ) HostError!*Entry`。
- **作用**：按调用区布局把入帧请求分到 plain 与 method 两条选择器上——是重入重放这类不知道具体形态的调用点的统一入口。
- **实现**：按 `layout` 二选一转发：`.plain` → `pushPlainCall`，`.method` → `pushMethodCall`。
- **所有权 / 错误 / 调用**：错误：`HostError`，透传自两条分支。所有权：不持有任何东西，只按 `RegionLayout` 选 plain/method 两条 push。调用：生产里只有 `src/exec/tailcall_dispatch.zig:7230`（重入请求重放调用点），其余为测试。

### `Machine.nativeBoundarySimpleEligible` (`src/exec/inline_calls.zig:3678`)

- **签名**：`pub fn nativeBoundarySimpleEligible(target: *const InlineTarget) bool`。
- **作用**：判定一个内联目标能不能在 native→JS 栅栏上用 simple 建帧——这是宿主跨界调用是否走瘦路径（含 `LeanFrame`）的总闸门。
- **实现**：读 `target.call_facts.execution`，返回三个 FB 预计算资格位的或：`simple_inline_eligible`（sloppy）、`strict_simple_inline_eligible`（strict）、`strict_simple_snapshot_inline_eligible`（strict 且需要原始实参快照）。三者都不中说明 callee 需要通用序言，栅栏侧只能走权威路径。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `execution` 的三个 eligible 位。调用：13 处准入判断，如 `src/exec/host_invocation.zig:224`、`src/exec/call_runtime.zig:684`、本文件 `:1258`（`LeanFrame.initInPlace`）与 `:3813`、`:4127`；`src/exec/call_runtime.zig:547`、`:586`、`:640` 是断言形态。

### `Machine.pushNativeBoundaryCopiedArgs` (`src/exec/inline_calls.zig:3690`)

- **签名**：`pub fn pushNativeBoundaryCopiedArgs( self: *Machine, global: *core.Object, target: *const InlineTarget, args: []const core.JSValue, ) HostError!?*Entry`。
- **作用**：宿主用一段**只读**实参切片发起同步 JS 调用时的权威入帧入口：实参会被复制进帧，宿主侧仍拥有原值。
- **实现**：唯一语句 `return self.pushNativeBoundarySimple(false, global, target, args, &.{})`——copied 变体，源参数窗口不被清空。
- **所有权 / 错误 / 调用**：错误：`HostError`，透传 `pushNativeBoundarySimple`。所有权：`args` 是宿主提供的只读切片，帧会复制一份（`moved_args` 传空切片表示不接管）。调用：唯一调用方 `src/exec/call_runtime.zig:571`（快路径 miss 后的回落，返回值以 `.?` 解包）。

### `Machine.pushNativeBoundaryMovedArgs` (`src/exec/inline_calls.zig:3702`)

- **签名**：`pub fn pushNativeBoundaryMovedArgs( self: *Machine, global: *core.Object, target: *const InlineTarget, args: []core.JSValue, ) HostError!?*Entry`。
- **作用**：宿主用一段**可写、所有权转移**的实参窗口发起同步 JS 调用时的权威入帧入口：值搬进帧后源槽被清空。
- **实现**：唯一语句 `return self.pushNativeBoundarySimple(true, global, target, args, args)`——moved 变体，同一窗口既是读源也是被清空的源。
- **所有权 / 错误 / 调用**：错误：`HostError`。所有权：`args` 同时作为 `moved_args` 传入，表示这段值的所有权转给帧，宿主侧不再释放。调用：唯一调用方 `src/exec/call_runtime.zig:596`。

### `Machine.pushLeanEntry` (`src/exec/inline_calls.zig:3716`)

- **签名**：`pub inline fn pushLeanEntry( self: *Machine, comptime fixed_argc: ?usize, rt: *core.JSRuntime, lean: *LeanFrame, this_value: *const core.JSValue, args: []const core.JSValue, ) ?*Entry`。
- **作用**：把站点自有的 `LeanFrame` 模板压成一个活的 Entry：模板里已经烘好的几何与不变字段全部沿用，这次调用只付「arena 切窗 + 拷实参 + 写 this/pc/argc + 改三个窗口指针 + 记预算 + 挂链」。
- **实现**：断言 `rt == self.ctx.runtime`，`fixed_argc` 给定时断言 `args.len` 与之相符。三道 miss 闸门依次：`lean.in_use` 为真（站点被回调重入，模板正被占用）返回 null；`vm_call.tryCommitInlineCallDepthBytesRt(rt, planned)` 预算不过返回 null；`rt.vm_stack.carveActiveMarked(lean.total_words)` 切不动则先 `retreatInlineCallDepthBytesMiss` 把已提交的预算退回再返回 null。切到窗口后前段是 `frame_args`、后段是 `stack_window`。拷参分两臂：`fixed_argc` 已知时（`call0..call4` 这类定 arity 形态）用 `inline for` 把拷贝展开，只留「要不要补 undefined」一个运行期判断，实参多于形参时只拷前 `frame_arg_count` 个；未知 arity 时用 `@min(args.len, frame_arg_count)` 循环拷再 `@memset` 补齐。随后断言模板仍完好（`continuation_payload == LeanFrame.marker`、`return_action == .native_boundary`），只重写每次调用才变的那几项：`copyValueSlotPinned` 写 this、`frame.pc = 0`、`actual_arg_count`、`args.ptr`/`locals.ptr`/`arena_mark`/`stack.values`/`stack.top_ptr`；几何量（`args.len`、`stack.capacity`）在 `initInPlace` 就定死了，这里只用断言核对。最后置 `lean.in_use = true`，挂链 `depth += 1`。
- **所有权 / 错误 / 调用**：错误：无——`lean.in_use`、栈预算、arena carve 三种 miss 都返回 null（预算已提交的先 `retreatInlineCallDepthBytesMiss` 退回），调用方回落到通用 push。所有权：复用调用方常驻的 `LeanFrame`（置 `in_use`，由 `call_runtime` 的 defer 复位），帧/栈窗口来自 arena carve；实参用 `copyValueSlotPinned` 复制进帧，宿主保留原值。调用：唯一调用方 `src/exec/call_runtime.zig:565`。

### `Machine.tryPushNativeBoundaryCopiedArgsFast` (`src/exec/inline_calls.zig:3779`)

- **签名**：`pub inline fn tryPushNativeBoundaryCopiedArgsFast( self: *Machine, rt: *core.JSRuntime, target: *const InlineTarget, args: []const core.JSValue, ) ?*Entry`。
- **作用**：只读实参形态的原生栅栏快路径包装：命中就地建帧返回 Entry，不命中返回 null 让调用方走权威路径。
- **实现**：唯一语句 `return self.tryPushNativeBoundaryArgsFast(false, rt, target, args, &.{})`。
- **所有权 / 错误 / 调用**：错误：无，miss 返回 null。所有权：`moved_args` 传空切片——实参只复制不接管。调用：唯一调用方 `src/exec/call_runtime.zig:570`。

### `Machine.tryPushNativeBoundaryMovedArgsFast` (`src/exec/inline_calls.zig:3790`)

- **签名**：`pub inline fn tryPushNativeBoundaryMovedArgsFast( self: *Machine, rt: *core.JSRuntime, target: *const InlineTarget, args: []core.JSValue, ) ?*Entry`。
- **作用**：所有权转移实参形态的原生栅栏快路径包装。
- **实现**：唯一语句 `return self.tryPushNativeBoundaryArgsFast(true, rt, target, args, args)`。
- **所有权 / 错误 / 调用**：错误：无，miss 返回 null。所有权：`args` 与 `moved_args` 同一段，值的所有权转给帧。调用：唯一调用方 `src/exec/call_runtime.zig:592`。

### `Machine.tryPushNativeBoundaryArgsFast` (`src/exec/inline_calls.zig:3799`)

- **签名**：`inline fn tryPushNativeBoundaryArgsFast( self: *Machine, comptime move_args: bool, rt: *core.JSRuntime, target: *const InlineTarget, args: []const core.JSValue, moved_args: []core.JSValue, ) ?*Entry`。
- **作用**：原生栅栏快路径的形态选择器：按 callee 已发布的调用事实把活分给空叶、精确实参叶、moved 通用三条暖建帧之一。
- **实现**：断言 `rt == self.ctx.runtime` 后先过总闸门 `nativeBoundarySimpleEligible(target)`，不合格返回 null。然后读 `execution` 分派：`simple_inline_empty_leaf or raw_this_inline_empty_leaf` → `tryPushNativeBoundaryEmptyFast(rt, target, args.len)`（空叶只需要实参个数用于定价）；`exact_args_leaf_kind != .none` → `tryPushNativeBoundaryLeafArgsFast(move_args, ...)`。都不中时，只有 `comptime move_args` 为真才继续试 `tryPushNativeBoundarySimpleGeneralFast`，copied 形态直接返回 null。注释（NB2-C）解释这个不对称：moved 通用形态有真实热点（RayTrace 经 `Function.apply` 调 `initialize`——会 materialize `arguments`、`var_count > 0`），而 copied 变体在三个调用点内联后实测事件为零，把共享热体拓宽过去曾经破坏布局。
- **所有权 / 错误 / 调用**：错误：无；不合 simple 资格或三条子路径都 miss 时返回 null。所有权：本层不分配，只按 `execution` 位把活分给空叶/精确实参叶/一般 simple 三条 fast 路径。调用：本文件 `:3790`（copied 包装）与 `:3801`（moved 包装）。

### `Machine.tryPushNativeBoundaryEmptyFast` (`src/exec/inline_calls.zig:3835`)

- **签名**：`inline fn tryPushNativeBoundaryEmptyFast( self: *Machine, rt: *core.JSRuntime, target: *const InlineTarget, actual_arg_count: usize, ) ?*Entry`。
- **作用**：空几何 callee 的原生栅栏暖建帧：callee 被证明没有形参、locals、open ref、`arguments` 与 direct eval，只需要一块操作数栈窗口。
- **实现**：断言两个空叶资格位之一成立。`bytecodeFrameAllocaSize(function, actual_arg_count, true)` 定价后 `tryCommitInlineCallDepthBytesRt` 不过即返回 null（此时还没提交任何东西）。取槽是内联版 `acquireSlot`：`chunk_index >= self.chunk_count` 说明要新开块，快路径不分配，`retreatInlineCallDepthBytesMiss` 退预算后返回 null；否则 `entryAt(index)`。再 `carveActiveMarked(stack_size + 1)` 切操作数栈，未命中同样退预算返回 null。三关全过才写 Entry：`.native_boundary`/0 续延、`catch_target = null`、`arena_mark = carve.mark`，`entry.frame` 里 this/callable 先留 `undefined` 再用 `copyValueSlotPinned` 从 target 搬入，`locals` 是 `carve.window[0..0]` 空切片，`ownership.storage = .borrowed`；`Stack.initArenaWindow` 建栈，`teardown = { simple, special_return, copy_argv }`（不发布 `empty_leaf` 位，返回仍走原生特殊返回臂），挂链 `depth += 1`。
- **所有权 / 错误 / 调用**：错误：无——栈预算不足、chunk 不足、arena 切不动都返回 null，失败前回退已提交的字节数。所有权：Entry 来自 chunk 池，帧窗口来自 `carveActiveMarked`；空叶不接管任何实参（`actual_arg_count` 只用于算 planned bytes），`return_action` 置 `.native_boundary`。调用：唯一调用方 `src/exec/inline_calls.zig:3818`。

### `Machine.tryPushNativeBoundaryLeafArgsFast` (`src/exec/inline_calls.zig:3906`)

- **签名**：`inline fn tryPushNativeBoundaryLeafArgsFast( self: *Machine, comptime move_args: bool, rt: *core.JSRuntime, target: *const InlineTarget, args: []const core.JSValue, moved_args: []core.JSValue, ) ?*Entry`。
- **作用**：精确实参叶 callee 的原生栅栏暖建帧：callee 只有形参窗口与操作数栈，但宿主给的实参可能多于或少于形参，所以窗口要可写且需补 undefined。
- **实现**：定价、预算提交、chunk 检查、`carveActiveMarked` 与失败退预算的结构完全同 `tryPushNativeBoundaryEmptyFast`，只是切的槽数是 `arg_count + stack_size + 1`——多出的前缀是可写的声明形参窗口。实参用 `copyValueSlotPinned` 逐槽搬进该窗口，`move_args` 臂搬完把源槽清空，多出的形参位补 undefined；宿主给多了的实参不必拷进来（函数注释：精确叶的发布事实已证明这帧没有 `arguments`/rest/eval 消费者，多余实参不可观测），但 `actual_arg_count` 与 qjs 栈预算记账仍按真实个数。capture 借闭包的 cell 数组，`teardown = { simple, special_return, copy_argv }`。
- **所有权 / 错误 / 调用**：错误：无，三道 miss 返回 null 并回退预算。所有权：`move_args` 为真时实参从宿主切片搬进帧（源不再拥有），为假时复制；Debug 下断言两种形态的切片关系。调用：唯一调用方 `src/exec/inline_calls.zig:3821`。

### `Machine.tryPushNativeBoundarySimpleGeneralFast` (`src/exec/inline_calls.zig:4009`)

- **签名**：`inline fn tryPushNativeBoundarySimpleGeneralFast( self: *Machine, rt: *core.JSRuntime, target: *const InlineTarget, moved_args: []core.JSValue, ) ?*Entry`。
- **作用**：moved 实参 + 一般 simple 几何（有 locals / open var-ref，但不需要原始实参快照）的原生栅栏暖建帧，把权威路径那套分区就地展开一遍。
- **实现**：断言 `nativeBoundarySimpleEligible(target)`。先排除带快照的形态：`frame_mod.originalArgCount(actual_arg_count, frame_mod.argumentsNeedsOriginalSnapshot(function)) != 0` 就返回 null——那类 callee（strict / derived 构造器 / 非简单形参表且 argc>0）要分配 `FrameCold` 盒子，留给权威路径。随后 `bytecodeFrameAllocaSize(function, actual_arg_count, true)` 定价，`tryCommitInlineCallDepthBytesRt` 不过返回 null。取槽是内联版的 `acquireSlot`：算 `chunk_index`，需要新块就 `retreatInlineCallDepthBytesMiss` 退预算并返回 null（快路径里绝不分配），否则 `entryAt(index)`。接着按 `frameArgCount + var_count + stack_size+1 + open_slots` 算 total，`carveActiveMarked` 未命中同样退预算返回 null。窗口切成 args/locals/stack/open 四段，`@memset(locals, undefined)`、open 段填 null；实参用 `copyValueSlotPinned` 逐槽搬进 `frame_args`，随后 `@memset(moved_args, undefined)` 清空源、`@memset(frame_args[actual_arg_count..], undefined)` 补齐形参尾部。最后写 Entry：`return_action = .native_boundary`、payload 0、`catch_target = null`、`arena_mark = carve.mark`，一次性写 `entry.frame` 字面量（this/callable 先留 `undefined` 再用 `copyValueSlotPinned` 从 target 搬进去，`ownership.storage` 恒 `.borrowed`），`Stack.initArenaWindow` 建操作数栈，`teardown = { simple, special_return, copy_argv }`，挂链并 `depth += 1`。
- **所有权 / 错误 / 调用**：错误：无；需要 `original_args` 快照的 callee 直接返回 null 交给慢路径，其余 miss 同样 null + 预算回退。所有权：只接受 moved 实参（所有权转帧），帧窗口取自 arena carve。调用：唯一调用方 `src/exec/inline_calls.zig:3835`。

### `Machine.pushNativeBoundarySimple` (`src/exec/inline_calls.zig:4114`)

- **签名**：`fn pushNativeBoundarySimple( self: *Machine, comptime move_args: bool, global: *core.Object, target: *const InlineTarget, args: []const core.JSValue, moved_args: []core.JSValue, ) HostError!?*Entry`。
- **作用**：原生栅栏建帧的权威选择器兼通用体：先判总资格，再按 callee 形态分给空叶/精确实参叶两个专用构造器，剩下的形态在本函数里走完整的 simple 建帧。
- **实现**：`nativeBoundarySimpleEligible(target)` 不过返回 null（这是「不适用」不是错误）。随后断言两种变体的切片关系：`move_args` 时 `args` 与 `moved_args` 必须是同一段，否则 `moved_args.len == 0`。形态分派：空叶两位任一 → `pushNativeBoundaryEmpty(global, target, args.len)`；`exact_args_leaf_kind != .none` → `pushNativeBoundaryLeafArgs(move_args, ...)`。都不中走本体：`bytecodeFrameAllocaSize(fb, args.len, true)` 定价（copy_argv 恒 true——栅栏形态一律复制实参），`enterInlineCallDepthBytes` 记账并装 `errdefer leaveInlineCallDepthBytes`，`acquireSlot` 取槽，写 `.native_boundary`/0 续延，交给 `noinline` 的 `setupNativeBoundarySimpleEntry` 建帧，回写 `teardown.copy_argv = true` 与 `planned_stack_bytes`，最后挂链 `depth += 1`。
- **所有权 / 错误 / 调用**：错误：`HostError`，由三条子路径的 `enterInlineCallDepthBytes`/`acquireSlot` 上抛；不合 simple 资格返回 null（不是错误）。所有权：按 callee 形态分给 `pushNativeBoundaryEmpty`/`pushNativeBoundaryLeafArgs` 或落到本体的通用 simple 建帧；`move_args` 决定实参是搬运还是复制。调用：本文件 `:3701`、`:3713` 两个包装。

### `Machine.pushNativeBoundaryLeafArgs` (`src/exec/inline_calls.zig:4175`)

- **签名**：`fn pushNativeBoundaryLeafArgs( self: *Machine, comptime move_args: bool, global: *core.Object, target: *const InlineTarget, args: []const core.JSValue, moved_args: []core.JSValue, ) HostError!*Entry`。
- **作用**：精确实参叶 callee 的原生栅栏权威构造器：与 `pushNativeBoundaryEmpty` 同族，只是多一个可写的形参窗口——宿主回调可能给多或给少，所以这里不能像普通精确实参叶那样就地借用。
- **实现**：断言 `exact_args_leaf_kind != .none`。定价 `bytecodeFrameAllocaSize(fb, args.len, true)` → `enterInlineCallDepthBytes` + `errdefer leaveInlineCallDepthBytes` → `acquireSlot`，写 `.native_boundary`/0 续延与 `catch_target = null`。几何：`frame_arg_count = function.arg_count`，`copied_arg_count = @min(args.len, frame_arg_count)`，`stack_count = stack_size + 1`，`total` 用 `std.math.add` 防溢出。切 slab 三级回退：`carveActiveMarked` → `mark()` + `carve()` → `rt.memory.alloc` 并置 `storage_on_heap`，两条 errdefer 分别回滚 watermark 与堆块。窗口前段是 `frame_args`、后段是 `stack_window`；`move_args` 臂 `@memcpy` 后把源槽 `@memset` 成 undefined，copied 臂逐个按值拷；不论哪臂都把 `frame_args[copied_arg_count..]` 补 undefined。随后一次性写 `entry.frame`（this/callable 直接借 `target`——原生算法仍以它们为根，`actual_arg_count` 记的是宿主给的**真实**实参数而非形参数，`locals` 是 `stack_window[0..0]` 的空切片），`Stack.initArenaWindow` 建栈，`teardown = { simple, special_return, copy_argv }`，挂链 `depth += 1`。
- **所有权 / 错误 / 调用**：错误：`HostError`——`enterInlineCallDepthBytes` 与 `acquireSlot` 都可能失败，`errdefer vm_call.leaveInlineCallDepthBytes` 把已记的栈字节退回。所有权：帧窗口切 arena、切不动改堆（`Frame.ownership.storage` 记录）；`return_action = .native_boundary`，pop 时由 native boundary 臂处理。调用：唯一调用方 `src/exec/inline_calls.zig:4135`。

### `Machine.pushNativeBoundaryEmpty` (`src/exec/inline_calls.zig:4268`)

- **签名**：`fn pushNativeBoundaryEmpty( self: *Machine, global: *core.Object, target: *const InlineTarget, actual_arg_count: usize, ) HostError!*Entry`。
- **作用**：零形参空几何 callee 的原生栅栏权威构造器：调用事实已证明没有 args/locals/open-ref/快照分区要做，只需要一块操作数栈。
- **实现**：断言两个空叶位之一成立。定价、`enterInlineCallDepthBytes` + `errdefer`、`acquireSlot`、写 `.native_boundary`/0 续延与 `catch_target = null`，与 `pushNativeBoundaryLeafArgs` 同序。几何只有 `stack_count = function.stack_size + 1`；同样三级回退地切窗（`carveActiveMarked` → `mark`+`carve` → 堆），两条 errdefer 回滚。`entry.frame` 里 this/callable 借自 `target`，`actual_arg_count` 记宿主传来的真实个数——即使多余实参在没有 `arguments`/rest/eval 时不可观测，qjs 的栈预算记账仍要算上它们；`locals` 为空切片。`teardown` 刻意**不**置普通的 `empty_leaf` 位，而是 `{ simple, special_return, copy_argv }`：返回仍要走原生特殊返回臂。最后挂链 `depth += 1`。
- **所有权 / 错误 / 调用**：错误：`HostError`，同样带 `errdefer leaveInlineCallDepthBytes` 回滚。所有权：空叶帧只需要 `stack_size + 1` 个操作数槽，不接管实参；Entry 取自 chunk 池。调用：唯一调用方 `src/exec/inline_calls.zig:4132`。

### `setupNativeBoundarySimpleEntry` (`src/exec/inline_calls.zig:4341`)

- **签名**：`noinline fn setupNativeBoundarySimpleEntry( move_args: bool, ctx: *core.JSContext, entry: *Entry, target: *const InlineTarget, args: []const core.JSValue, moved_args: []core.JSValue, ) HostError!void`。
- **作用**：native 栅栏 simple 帧的 copied vs moved args 共用 setup。`move_args` 运行时决定，两份特化共享这一 `noinline` 体。禁止折进 `setupSimpleInlineEntry`（其 noinline 对 fib 是负荷）。
- **实现**：断言 `nativeBoundarySimpleEligible`。`teardown = .{ .simple, .special_return }`。按 `frameArgCount` + locals + stack+1 + open + snapshot 算 total（`std.math.add` 防溢出）。优先 `carveActiveMarked`，否则 mark+carve，再 heap。分区 args/locals/stack/open/snapshot。locals/open memset。若需要 snapshot 则 `create(FrameCold)` 并把 args 拷进 `original_args`（这是最后一次可失败操作，失败不碰源所有者）。`move_args` 则 memcpy `moved_args` 进 frame_args 并清空源；否则按值拷 `args`。不足的 arg 槽 pad undefined。this/callable 借 `target`（native 算法仍根着它们）。heap 时 `storage_values=slab`。
- **所有权 / 错误 / 调用**：errdefer restore watermark 并在 heap 时 free slab。错误：`HostError`（溢出/OOM/FrameCold）。调用：`pushNativeBoundarySimple`。

### `Machine.pushMovedCall` (`src/exec/inline_calls.zig:4455`)

- **签名**：`pub fn pushMovedCall( self: *Machine, global: *core.Object, target: *const InlineTarget, moved_values: []core.JSValue, layout: RegionLayout, return_action: ReturnAction, continuation_payload: u32, ) HostError!*Entry`。
- **作用**：从一段调用方已交出所有权的临时值区建帧，并给这一帧安上一个非默认的返回续延（Proxy get 补完、for-of next、to_boolean、原生栅栏之一）。
- **实现**：Debug/Safe 下有不变量断言（`native_boundary` 不得落在任何叶形态上）。 `ArgsSource.initMoved` 包住调用方的临时区域后，method 布局走 `pushFrame(.moved_method, …, copy_argv=true)`、plain 走 `pushFrame(.generic, …, copy_argv=true)`；随后写 `return_action`，`.native_boundary` 另置 `teardown.special_return`，payload 按 action 分派（`.proxy_get` 取 atom、`.for_of_next` 取深度，其余为 0；`.constructor`/`.async_complete` 不可达）。
- **所有权 / 错误 / 调用**：错误：`HostError`，由 `pushFrame` 上抛（失败时 moved 值由 `pushFrame` 的清理路径负责）。所有权：`moved_values` 的所有权转给新帧（`ArgsSource.initMoved`，`copy_argv=true`）；随后按 `return_action` 写续延 payload，`native_boundary` 另置 `teardown.special_return` 并断言该帧不是任何叶形态。调用：`src/exec/call_runtime.zig:520`、`src/exec/tailcall_dispatch.zig:1112`、`:6999`。

### `Machine.pushAsyncMovedCall` (`src/exec/inline_calls.zig:4486`)

- **签名**：`pub fn pushAsyncMovedCall(self: *Machine, target: *const InlineTarget, moved_values: []core.JSValue, layout: RegionLayout, id: u32) HostError!*Entry`。
- **作用**：从一段 moved 值区建帧，并把这一帧标成「返回即完成某个 async 边界」——返回时用 `continuation_payload` 里的 id 去 `async_completions` 找对应的 promise 结算。
- **实现**：`pushFrame(.generic, stack_preflighted=false, copy_argv=true, self.global, target, ArgsSource.initMoved(moved_values, layout == .method))` 建帧，随后写 `return_action = .async_complete`、`continuation_payload = id`（`async_completions` 表里的槽号），并置 `teardown.special_return` 让返回离开普通 `.next` 路径。末尾在 `comptime builtin.is_test` 下给 `same_machine_async_calls` 计数加一。
- **所有权 / 错误 / 调用**：错误：`HostError`，来自 `pushFrame`。所有权：`moved_values` 转给帧；Entry 记 `.async_complete` 与 completion id（`continuation_payload`），对应的 completion 槽由 `async_completions` 持有到 `completeAsync` 释放。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2182`。

### `Machine.completeAsync` (`src/exec/inline_calls.zig:4495`)

- **签名**：`pub fn completeAsync(self: *Machine, id: u32, rejected: bool) HostError!core.JSValue`。
- **作用**：结算一条 async 边界记录：把已经算好的返回值/异常喂给它的 promise，并交还这条记录占的槽位。
- **实现**：`async_completions.at(id)` 取记录，`defer self.async_completions.release(id)` 保证无论成败都归还槽位。随后 `promise_ops.settleAsyncPromise(ctx, output, global, boundary.promise, boundary.value, rejected)` 结算；`rejected` 为真时再 `promise_ops.clearHandledRejectionException(ctx)` 把已被 promise 接手的异常从 context 上清掉，免得它继续作为 pending exception 向外传。最后返回 `boundary.promise`。
- **所有权 / 错误 / 调用**：错误：`HostError`，来自 `settleAsyncPromise`。所有权：`defer self.async_completions.release(id)` 归还 completion 槽；promise 与 value 由该槽借出，settle 后 promise 作为返回值交给调用方压栈；`rejected` 时额外 `clearHandledRejectionException`。调用：本文件 `:4514`（`catchAsyncBoundary`）与 `src/exec/tailcall_dispatch.zig:1385`、`:1771`、`:7166`。

### `Machine.catchAsyncBoundary` (`src/exec/inline_calls.zig:4504`)

- **签名**：`fn catchAsyncBoundary(self: *Machine, err: HostError) HostError!bool`。
- **作用**：错误展开时的第一道拦截：如果栈顶这一帧本身就是一个 async 边界，那么这个错误不该继续往外抛，而应该变成该 async 函数返回的 rejected promise。
- **实现**：栈顶 `return_action != .async_complete` 直接返回 false，让展开继续。否则取出 `continuation_payload` 当 id，把 `exception_ops.promiseErrorValue(ctx, global, err)` 算出的异常值写进 `async_completions.at(id).value`，`popFrame()` 退掉这一帧，`completeAsync(id, true)` 以 rejected 结算并拿回 promise，再 `currentLevel().stack.pushOwnedAssumeCapacity(promise)` 把它压回新的栈顶层，返回 true 表示错误已被吸收。
- **所有权 / 错误 / 调用**：错误：`HostError`——`promiseErrorValue` 与 `completeAsync` 都可能失败，向上抛给 unwind 循环。所有权：把错误值存进 `async_completions` 的 completion 槽，`popFrame` 拆掉 async 帧后 `completeAsync(id, true)` 释放该槽并返回 promise，promise 以 owned 语义压回下一层操作数栈。调用：本文件 `:5186`（`unwindForErrorToDepth`）与 `:5217`（`unwindForError`）。

### `Machine.pushBorrowedIteratorNext` (`src/exec/inline_calls.zig:4518`)

- **签名**：`pub inline fn pushBorrowedIteratorNext( self: *Machine, global: *core.Object, target: *const InlineTarget, iterator_record: []core.JSValue, depth: u8, ) HostError!?*Entry`。
- **作用**：for-of 循环每轮的 `iterator.next()` 入帧：this 与 callee 直接借用挂起调用方栈上的 iterator 记录，不搬也不取，并把这一帧标成 `.for_of_next` 续延。
- **实现**：`isBorrowedIteratorSimpleInlineFrame` 不成立就返回 null；成立则以 `ArgsSource.initMoved(iterator_record, true)` 作诊断见证走 `pushFrame(.borrowed_iterator, …)`（该 setup 路径不读 ArgsSource、不取用两个槽），再写 `return_action = .for_of_next` 与 `continuation_payload = depth`。
- **所有权 / 错误 / 调用**：错误：`HostError`，来自 `pushFrame`。所有权：`iterator_record` 只以 `ArgsSource.initMoved(..., true)` 作诊断见证传入——`.borrowed_iterator` setup 借读 this/callee，既不 take 也不清空 record 的两个槽；不合准入返回 null，record 同样原样留给调用方。调用：`src/exec/tailcall_dispatch.zig:1142` 与 `:6993`（for-of 的两处 next 调用点）。

### `Machine.assertBorrowedIteratorWarmEligible` (`src/exec/inline_calls.zig:4542`)

- **签名**：`inline fn assertBorrowedIteratorWarmEligible(function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts) void`。
- **作用**：Debug/Safe 断言暖借用迭代器构造器的两项前提：callee 至少命中一个 simple 资格位，且它没有 open var-ref 存储（暖路径不切那段窗口）。
- **实现**：两条断言：`execution` 的三个 simple 资格位（`simple_inline_eligible` / `strict_simple_inline_eligible` / `strict_simple_snapshot_inline_eligible`）至少命中一个；以及 `frame_mod.frameOpenVarRefStorageCount(function) == 0`——暖路径不切 open var-ref 窗口，所以 callee 必须证明自己没有逃逸变量。
- **所有权 / 错误 / 调用**：错误：无，两条 `std.debug.assert`（simple 资格三选一、无 open var-ref 存储）。所有权：只读。调用：唯一调用方 `src/exec/inline_calls.zig:4599`（`tryPushBorrowedIteratorNextFast` 的入口）。

### `Machine.readValueAsIntPair` (`src/exec/inline_calls.zig:4558`)

- **签名**：`inline fn readValueAsIntPair(slot: *const core.JSValue) core.JSValue`。
- **作用**：把一个 JSValue 槽按两个 u64 字读出来，避免 16 字节向量读。
- **实现**：comptime 判断 `@sizeOf(core.JSValue) != 2 * @sizeOf(u64)` 时直接 `slot.*`；否则把槽 `@ptrCast` 成 `*const [2]u64`，分别读 lo/hi 再 `@bitCast` 回 JSValue。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读拷贝——把 16 字节槽按两个 u64 读出再 `@bitCast` 回 `JSValue`，不改源槽（与 `takeSourceSlot` 的 move 语义相反，借用的 iterator record 要保留原值）。调用：本文件 `:4676`、`:4677`（借用 iterator 帧取 this 与 callee）。

### `Machine.tryPushBorrowedIteratorNextFast` (`src/exec/inline_calls.zig:4586`)

- **签名**：`pub inline fn tryPushBorrowedIteratorNextFast( self: *Machine, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, iterator_record: []core.JSValue, depth: u8, ) ?*Entry`。
- **作用**：for-of `next()` 的暖入帧：在不分配、不提交任何预算的前提下做完全部准入，全部通过才一次性提交并建帧，任何一处不合格都返回 null 且不留副作用。
- **实现**：Debug/Safe 下有不变量断言（`assertBorrowedIteratorWarmEligible`、record 长度为 2）。 K1 单次定价 `vm_call.bytecodeFrameAllocaSize(function, 0, false)`，`vm_call.canEnterInlineCallDepthBytes` 只做谓词；chunk 未分配或 `vm_stack.carveActiveMarked` 未命中直接返回 null（此时尚未提交），命中后才 `vm_call.commitInlineCallDepthBytes`，写 `.for_of_next`/depth/catch_target/arena_mark 并交给 `finishBorrowedIteratorFrame`。
- **所有权 / 错误 / 调用**：错误：无——栈预算、chunk、arena carve 任一 miss 返回 null；注意这里先用 `canEnterInlineCallDepthBytes` 试算、成功后才 `commitInlineCallDepthBytes`，所以 miss 路径不需要回退。所有权：Entry 取自 chunk 池，帧窗口来自 arena carve，`iterator_record` 只借不移。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2930`。

### `Machine.finishBorrowedIteratorFrame` (`src/exec/inline_calls.zig:4638`)

- **签名**：`inline fn finishBorrowedIteratorFrame( self: *Machine, entry: *Entry, function: *const bytecode.FunctionBytecode, captures: []*core.VarRef, iterator_record: []core.JSValue, slab: []core.JSValue, frame_arg_count: usize, var_count: usize, ) *Entry`。
- **作用**：借用迭代器帧的发布尾巴：把 arena 切好的窗口与借来的 this/callee 写进 Entry 并挂链。
- **实现**：args+locals 前缀一次性 `@memset` 成 undefined；this/callable 用 `readValueAsIntPair` 从调用者 iterator record 借读（不 take）；帧字段逐个写而不是整结构赋值，其中 `frame.var_refs` 只在与 `captures` 不同时才写（store elision）；`open_var_refs`/`storage_values` 置空，栈用 `stack_mod.Stack.initArenaWindow`，teardown 只有 `simple`，最后链 `prev`、`depth += 1`。
- **所有权 / 错误 / 调用**：错误：无。所有权：把 carve 出来的 slab 切成 args/locals/stack 三段并把前两段 `@memset` 成 undefined；this 与 callee 用 `readValueAsIntPair` 从 iterator record 借读（不清空源）；`captures` 借自 callable；末尾接链 `top` 并 `depth += 1`。调用：唯一调用方 `src/exec/inline_calls.zig:4625`。

### `Machine.tailCallReuse` (`src/exec/inline_calls.zig:4717`)

- **签名**：`pub fn tailCallReuse( self: *Machine, global: *core.Object, caller_stack: *stack_mod.Stack, target: *const InlineTarget, region_base: usize, argc: u16, layout: RegionLayout, budget: TailBudgetMode, ) HostError!*Entry`。
- **作用**：正规尾调用（ES2015 PTC 与 eval-tail）的帧复用：在调用方还是当前帧时先把目标建到下一个槽，再把建好的 Entry 整体搬进调用方那一格，于是物理栈深度不增长。
- **实现**：ES2015 PTC / eval-tail：在调用者仍是 current 时把目标建到下一槽，再把准备好的 Entry 搬进调用者槽。`.chain` 累加 logical budget（看起来像压栈）；`.release` 释放死去帧的深度与 planned bytes（严格 `tail_call` 常数栈）。操作数区先搬到 scratch，再 `deinitForTailReplacement` 调用者。
- **所有权 / 错误 / 调用**：错误：`HostError`——`checkTailCallChainStackBudget` 与大 `total` 时的 `rt.memory.alloc` 都可能失败。所有权：先把调用方栈上的 callee+receiver+实参整段 `@memcpy` 进临时缓冲（≤10 个值用栈上 `inline_buf`，超出才向 `MemoryAccount` 借并 `defer free`），然后销毁被替换的帧（`deinitForTailReplacement`，不回滚 arena）并在同一块 Entry 上重建，`depth` 净减 1 后返回复用的 Entry。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:7211`。

### `Machine.popFrameMode` (`src/exec/inline_calls.zig:4814`)

- **签名**：`inline fn popFrameMode(self: *Machine, comptime returned: bool) ReturnContinuation`。
- **作用**：通用出帧：把栈顶帧的返回续延取走、释放它的资源、退还它占的深度与栈字节预算，最后解链。`returned` 这个 comptime 参数区分正常返回与异常/丢弃两种拆除。
- **实现**：取 `dying = topEntry()`。第一件事是把带 tail-chain 的帧甩出去：`dying.teardown.tail_chain` 为真就整条转给 outline 的 `popTailChainFrameMode(returned)`——那类帧要先读 overlay 里累积的预算、再对 runtime 的两个计数器走第二遍，而普通帧的这份预算静态就是 {0,0}，没必要每次返回都构造它并在拆除期间保活、然后往两个热字段各减一个零；这里测的位与 `deinitReturned` 自己要读的 flag 在同一个 `teardown` 字节里。随后读 `dying.frame.planned_stack_bytes`（建帧时就持久化的承诺值），Debug 下用 `bytecodeFrameAllocaSize` 重算一遍做 lockstep 对账，防止某个构造器漏写这个 store。接着 `takeContinuation()` 把续延搬出来，按 `returned` 选 `deinitReturned(ctx)` 或 `deinit(ctx)`，`leaveInlineCallDepthBytes` 退还字节预算，`depth -= 1`，`self.top = dying.prev` 解链（对齐 qjs `done:` 尾声的 `rt->current_stack_frame = sf->prev_frame`，quickjs.c:20709），返回续延。
- **所有权 / 错误 / 调用**：错误：无。所有权：取走续延后按 `returned` 选 `deinitReturned`/`deinit` 释放帧资源，再 `leaveInlineCallDepthBytes` 归还栈预算、`depth -= 1`、`top` 退回 `prev`；tail_chain 帧改走 `popTailChainFrameMode`。返回的 `ReturnContinuation` 由调用方负责 `deinit`。调用：本文件 `:4915`（`popFrame`）与 `:4921`（`popReturnedFrame`）。

### `popTailChainFrameMode` (`src/exec/inline_calls.zig:4853`)

- **签名**：`noinline fn popTailChainFrameMode(self: *Machine, returned: bool) ReturnContinuation`。
- **作用**：`popFrameMode` 给继承了被复用尾调用者 logical depth / planned bytes 的帧。普通返回既不物化 overlay 也不付第二次计数器通行；`returned` 在此是运行时而非 comptime（每条 tail chain 进一次，不是每次 call）。
- **实现**：断言 `teardown.tail_chain`。拆帧前读 `tailChainBudgetSlot()`。取 continuation，按 `returned` 走 `deinitReturned` 或 `deinit`。`leaveInlineCallDepthBytes` 释放本帧单位，再减去 `chain_budget.extra_depth` / `planned_stack_bytes`（Debug 断言 runtime 计数够减）。`depth-=1`，`top=dying.prev`（qjs `rt->current_stack_frame = sf->prev_frame`，quickjs.c:20709）。
- **所有权 / 错误 / 调用**：continuation 所有权交给调用方直到消费或 deinit。错误：无。调用：仅 `popFrameMode` 在 `teardown.tail_chain` 时。

### `Machine.popOrdinaryFrame` (`src/exec/inline_calls.zig:4884`)

- **签名**：`pub inline fn popOrdinaryFrame(self: *Machine) void`。
- **作用**：被 `isOrdinaryReturn()` 分类过的普通返回帧的专用出帧：续延必定是 `.next`/0，所以连 `ReturnContinuation` 都不用构造，直接丢弃。
- **实现**：`dying = topEntry()` 后两条断言：`dying.isOrdinaryReturn()`，以及 `dying.continuation_payload == 0`——注释指出后者是这条路径上唯一不循环论证的检查（分类本身从不读 payload），它能抓住「装了 payload 却没装对应 tag」的生产者，而那恰恰是这条路径会默默丢掉的帧。随后与 `popFrameMode` 同样的 `planned_stack_bytes` 读取与 Debug 对账，调 `deinitOrdinaryReturned(ctx)`，`leaveInlineCallDepthBytes`，`depth -= 1`，`top = dying.prev` 解链（qjs:20709）。
- **所有权 / 错误 / 调用**：错误：无；`assert(dying.isOrdinaryReturn())` 与 planned bytes 对账保证走这条臂的前提。所有权：`deinitOrdinaryReturned` 释放帧资源并回滚 arena，随后归还栈预算、`depth -= 1`、`top = dying.prev`；没有续延要交还。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:1560`（返回分派的普通臂）。

### `Machine.popFrame` (`src/exec/inline_calls.zig:4909`)

- **签名**：`pub inline fn popFrame(self: *Machine) ReturnContinuation`。
- **作用**：异常展开、尾调用替换、丢弃等**非正常返回**场景的出帧入口。
- **实现**：一行 `return self.popFrameMode(false)`：`returned = false` 让拆除走 `Entry.deinit` 那条权威腿——空布局的帧在 opcode 抛出时仍可能留着活操作数，不能用正常返回的叶尾声。
- **所有权 / 错误 / 调用**：错误：无。所有权：转调 `popFrameMode(false)`（异常/主动丢弃语义，不走「已返回」的精简 teardown）；续延所有权交给调用方。调用：本文件 `:1392`（`Machine.deinit` 排干残帧）、`:4513`、`:5166`、`:5187`、`:5218`。

### `Machine.popReturnedFrame` (`src/exec/inline_calls.zig:4915`)

- **签名**：`pub inline fn popReturnedFrame(self: *Machine) ReturnContinuation`。
- **作用**：正常返回场景的通用出帧入口（不走各叶形态专用臂时用它）。
- **实现**：一行 `return self.popFrameMode(true)`：`returned = true` 让拆除走 `deinitReturned`，可以尝试最窄的空叶尾声。
- **所有权 / 错误 / 调用**：错误：无。所有权：转调 `popFrameMode(true)`，即帧是正常 return 完成的。调用：本文件 `:5089`（`popReturn`）与 `src/exec/tailcall_dispatch.zig:1769`、`:1833`。

### `Machine.popReturnedNativeBoundary` (`src/exec/inline_calls.zig:4926`)

- **签名**：`pub inline fn popReturnedNativeBoundary(self: *Machine, rt: *core.JSRuntime) void`。
- **作用**：原生栅栏帧的返回出帧：这一帧的返回值要交还给发起调用的宿主 native 代码，而不是继续跑 caller 的字节码。
- **实现**：断言 `rt == self.ctx.runtime`、`dying.isNativeBoundaryReturn()`、payload 只能是 0 或 `LeanFrame.marker`。payload 等于 marker 的话整条转给 `popReturnedLean(rt, dying)` 并返回。否则先取 tail-chain 预算：`teardown.tail_chain` 为真读 `tailChainBudgetSlot().*`，否则用静态的 `{0, 0}`。读 `planned_stack_bytes` 并 Debug 对账。拆除按形状二选一：`canUseSimpleTeardown()` 走 `deinitSimple`，否则 `deinitReturned`。随后 `leaveInlineCallDepthBytesRt(rt, ...)` 退本帧预算，再断言 runtime 的 `hot.call_depth` 与 `hot.active_bytecode_stack_bytes` 够减，并减去 chain 预算的 `extra_depth` 与 `planned_stack_bytes`。最后 `depth -= 1`、`top = dying.prev`。
- **所有权 / 错误 / 调用**：错误：无。所有权：lean 帧转 `popReturnedLean`；其余按 simple/一般两路 deinit，并把 tail-chain 记下的 `extra_depth`/`planned_stack_bytes` 从 `rt.hot` 的预算里一并扣回，最后 `depth -= 1`、`top = dying.prev`。返回值已由 VM 的 native return 槽持有，不在这里压栈。调用：本文件 `:5081`（`popReturn`）与 `src/exec/tailcall_dispatch.zig:1572`、`:1779`。

### `Machine.popReturnedLean` (`src/exec/inline_calls.zig:4971`)

- **签名**：`pub inline fn popReturnedLean(self: *Machine, rt: *core.JSRuntime, dying: *Entry) void`。
- **作用**：站点自有 `LeanFrame` 的专用返回出帧：模板帧没有任何自有资源，退役只剩「退 arena 水位 + 退预算 + 解链」三步。
- **实现**：六条断言先把形状钉死：`dying == topEntry()`、`return_action == .native_boundary`、`continuation_payload == LeanFrame.marker`、`canUseSimpleTeardown()`、非 `tail_chain`、`frame.function.openVarRefCount() == 0`（`initInPlace` 的准入已排除有 open var-ref 的 callee）。随后三条真动作：`rt.vm_stack.restore(dying.arena_mark)` 退还这次调用切的窗口、`leaveInlineCallDepthBytesRt(rt, dying.frame.planned_stack_bytes)` 退预算、`depth -= 1` 与 `top = dying.prev` 解链。注意这里不调任何 `deinit*`——lean 帧的实参是复制进来的、capture 是借的、栈窗口在 arena 上，没有需要逐项释放的东西。
- **所有权 / 错误 / 调用**：错误：无，六条 `assert` 钉死 lean 形态（native_boundary、marker、simple teardown、非 tail chain、无 open var-ref）。所有权：lean 帧不持有任何需要逐值释放的窗口——只 `rt.vm_stack.restore(arena_mark)` 回滚 arena、归还 planned bytes，然后退栈；`LeanFrame.in_use` 由调用方的 defer 复位。调用：`src/exec/tailcall_dispatch.zig:1869` 与本文件 `:4938`。

### `Machine.popReturnedEmptyLeaf` (`src/exec/inline_calls.zig:4988`)

- **签名**：`pub inline fn popReturnedEmptyLeaf(self: *Machine, rt: *core.JSRuntime) void`。
- **作用**：空叶帧正常返回的专用出帧臂——整条返回路径上最短的一条，代价只有一次 arena 水位回滚。
- **实现**：一串断言把这条最短路径的前提钉死：`rt == self.ctx.runtime`（runtime 由返回 handler 从 `Vm` 的驻留字段直接传入，省掉 machine→ctx→runtime 那条链）、`dying.isEmptyLeaf()`、非 `tail_chain`、`return_action == .next`、payload 为 0，以及两条来自发布事实的静态结论——`!teardown.copy_argv` 且 `frame.function.arg_count == 0`（空叶几何按 `bytecode.zig` 的 `empty_leaf_geometry` 就是零参、从不按 copy_argv 定价，所以补参前缀静态为空）。再用 `bytecodeLeafFrameAllocaSize` 对账 `planned_stack_bytes`。真动作三条：`deinitEmptyLeafInline(rt)`（内联展开，注释说明这样能把空叶返回路径上唯一的 bl/ret 去掉；注释里旧的 `destroyZeroRef`/rc 说法已改实）、`leaveInlineCallDepthBytesRt` 退预算、`depth -= 1` 与 `top = dying.prev` 解链。
- **所有权 / 错误 / 调用**：错误：无，前置全 `assert`（空叶、非 tail chain、`.next` 续延、`arg_count == 0`、planned bytes 与叶帧公式一致）。所有权：`deinitEmptyLeafInline` 只回滚 arena，随后 `leaveInlineCallDepthBytesRt` 归还预算并退栈。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:1599`。

### `Machine.popReturnedExactArgsLeaf` (`src/exec/inline_calls.zig:5018`)

- **签名**：`pub inline fn popReturnedExactArgsLeaf(self: *Machine, rt: *core.JSRuntime) void`。
- **作用**：精确实参叶（含零参 capture 叶）正常返回的专用出帧臂。
- **实现**：断言同族：`rt == self.ctx.runtime`、`dying.isExactArgsLeaf()`、非 `tail_chain`、`return_action` 为 `.next` 或 `.to_boolean`、payload 为 0、`!teardown.copy_argv`。注释指出这一位同时覆盖 argc==0 的 capture 叶家族，所以释放动作仍是 argc 敏感的，只有 copy_argv 的定价选择在这里静态为假（精确叶与 capture 叶两个 finisher 都不置它）。用 `bytecodeFrameAllocaSize(..., false)` 对账后：`deinitExactArgsLeafInline(rt)`、`leaveInlineCallDepthBytesRt`、`depth -= 1`、`top = dying.prev`。
- **所有权 / 错误 / 调用**：错误：无，前置全 `assert`（精确实参叶、续延为 `.next` 或 `.to_boolean`、未复制 argv）。所有权：实参窗口是借来的，`deinitExactArgsLeafInline` 只回滚 arena；随后归还预算并退栈。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:1669`。

### `Machine.popReturnedForwardedLeaf` (`src/exec/inline_calls.zig:5047`)

- **签名**：`pub inline fn popReturnedForwardedLeaf(self: *Machine, rt: *core.JSRuntime) void`。
- **作用**：`Function.prototype.call` 透明转发出来的叶帧的专用出帧臂。
- **实现**：断言：`rt == self.ctx.runtime`、`dying.isForwardedLeaf()`、非 `tail_chain`、`return_action == .next`、payload 为 0。对账用的是 `bytecodeLeafFrameAllocaSize`——注释说明两种转发形状都释放这个叶数字：零参那种按 copy_argv 定价提交但补参前缀是空的，精确实参那种直接按叶尺寸提交（argc == arg_count，前缀同样为空）。随后 `deinitForwardedLeafInline(rt)`、`leaveInlineCallDepthBytesRt`、`depth -= 1`、`top = dying.prev`。
- **所有权 / 错误 / 调用**：错误：无，前置全 `assert`（forwarded 叶、非 tail chain、`.next` 续延）。所有权：同上，`deinitForwardedLeafInline` 只回滚 arena 与预算。调用：`src/exec/tailcall_dispatch.zig:1712`、`:1794`。

### `Machine.popReturn` (`src/exec/inline_calls.zig:5071`)

- **签名**：`pub fn popReturn(self: *Machine, result: core.JSValue) ReturnContinuation`。
- **作用**：返回值的总出口：按这一帧的续延类别决定返回值去哪儿——结算 async promise、交还原生栅栏、做构造器补完，还是压回调用方的操作数栈。
- **实现**：Debug/Safe 下有不变量断言（ordinary 臂的 payload 为 0）。 `.async_complete` 先把结果存进 `async_completions`；`isNativeBoundaryReturn()` 走 `popReturnedNativeBoundary` 并回一个 `.native_boundary` continuation；`completesConstructor()` 走 `popConstructorReturn` 并把完成值压回调用者栈、回 `.next`；其余 `popReturnedFrame()`，continuation 为 `.next` 时才把 `result` 压回调用者栈。
- **所有权 / 错误 / 调用**：错误：无。所有权：`async_complete` 帧先把 `result` 存进 completion 槽；native boundary 帧的返回值留在 VM 的 native 返回槽，构造器帧由 `popConstructorReturn` 算出 `completed` 并以 owned 语义压栈；普通帧在续延为 `.next` 时把 `result` 压回调用方栈，其余续延由调用方处理并负责 `deinit`。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:7148`（`op_return` 的统一出口）。

### `popConstructorReturn` (`src/exec/inline_calls.zig:5122`)

- **签名**：`pub noinline fn popConstructorReturn(self: *Machine, result: core.JSValue) align(16) core.JSValue`。
- **作用**：构造器返回完成，对齐 qjs 两分支：共享 `done:` 序言后（quickjs.c:20699-20709）`JS_CallConstructorInternal` 只做 tag 测试加一次 free（quickjs.c:20846-20856）。基类 Entry 拥有 fallback：对象结果替换它，原语丢弃改用实例。derived 的 undefined 哨兵则转发已检查的结果。
- **实现**：断言 `constructor_completion`、无 native_caller、无 tail_chain、`return_action==.constructor`、payload==0（静态证明 constructor_completion∧tail_chain 不可满足）。读 `native_caller` 为 fallback；非 undefined 则 `noteConstructorAllocation`。`deinitConstructorReturned`（不走会 `releaseConstructorFallback` 的共享 deinit——flag 在此路径已死）。`leaveInlineCallDepthBytes`，unlink `top=prev`。fallback undefined → 返回 result；`result.is(.object)` → result；否则 fallback。 abrupt 完成仍走 `Entry.deinit` 且 flag 仍 SET，经 `releaseConstructorFallback` 释放一次。
- **所有权 / 错误 / 调用**：接管 `result`；返回值给 `popReturn` `pushOwnedAssumeCapacity`。错误：无。调用：`Machine.popReturn` 在 `completesConstructor()` 时；outline 是为了 return handler 只付一次 bl。

### `Machine.discardToDepth` (`src/exec/inline_calls.zig:5157`)

- **签名**：`pub fn discardToDepth(self: *Machine, depth: usize) void`。
- **作用**：把 `depth` 以上的 Entry 全部强行退役——这是「有界展开过程本身又抛错」时的恢复尾巴。
- **实现**：断言 `depth <= self.depth`；循环 `popFrame()` 直到降到目标深度，每层若 continuation 是 `.async_complete` 先 `async_completions.release(payload)` 归还槽位，再 `continuation.deinit(self.ctx.runtime)`。全程不做任何可观察操作：不找 catch、不跑 IteratorClose。
- **所有权 / 错误 / 调用**：所有权：逐层释放 Entry 持有的帧资源与 continuation payload。 错误：无（本身不会再抛）。 调用：`NativeBoundaryScope` 的错误腿（1104，退到 `fence_depth`）、`IdleBoundaryScope.deinit`（1214，退到 0）、`unwindForErrorToDepth` 的 `errdefer`（5183）。

### `Machine.unwindForErrorToDepth` (`src/exec/inline_calls.zig:5170`)

- **签名**：`pub fn unwindForErrorToDepth( self: *Machine, global: *core.Object, fence_depth: usize, err: HostError, ) HostError!bool`。
- **作用**：从当前栈顶向下展开错误，直到某一层接住它或降到给定的栅栏深度为止——栅栏之下属于仍在运行的宿主 native 代码，不归这次展开管。
- **实现**：断言 `fence_depth <= self.depth`，装 `errdefer self.discardToDepth(fence_depth)`（展开过程本身再抛错时把残帧强行清到栅栏）。循环条件 `self.depth > fence_depth`，每轮：①`catchAsyncBoundary(err)` 命中就返回 true（错误变成了 rejected promise）；②`popFrame()` 取回续延，若是 `.for_of_next` 先 `takeForOfDepth()` 留下该轮迭代器的栈深度，再 `continuation.deinit(ctx.runtime)`；③如果这一弹刚好降到 `fence_depth`，立即返回 false——注释说明外层那一级属于仍在运行的 native builtin，不能替它关闭迭代器或查它的 catch 标记；④否则取 `currentLevel()`，有 `iterator_next_depth` 就 `forof_ops.abandonForOfIteratorAtDepth` 退役那条记录，再 `forof_ops.closeStackTopForOfIteratorForPendingError` 对栈顶迭代器执行 IteratorClose，最后 `call_runtime.tryCatchInFrame` 在本层找 catch 目标，命中返回 true。循环走完返回 false。
- **所有权 / 错误 / 调用**：错误：`HostError`——`catchAsyncBoundary`、for-of 关闭、`tryCatchInFrame` 都可能再抛；`errdefer self.discardToDepth(fence_depth)` 保证即使二次出错也把栈退到围栏深度。所有权：每层 `popFrame` 取回的续延在本层 `deinit`；`for_of_next` 续延先取出迭代器深度，再由 `abandonForOfIteratorAtDepth`/`closeStackTopForOfIteratorForPendingError` 关闭迭代器。返回 true 表示某层 catch 接住了。调用：唯一调用方 `src/exec/zjs_vm.zig:772`。

### `Machine.unwindForError` (`src/exec/inline_calls.zig:5208`)

- **签名**：`pub fn unwindForError(self: *Machine, global: *core.Object, err: HostError) HostError!bool`。
- **作用**：错误展开的根层版本：一路展到 Machine 空为止，没有任何层接住就返回 false，把错误交回分发循环之外。
- **实现**：循环条件是 `self.depth > 0`，每轮与 `unwindForErrorToDepth` 同序：`catchAsyncBoundary(err)` 命中返回 true；`popFrame()` 取续延，`.for_of_next` 先 `takeForOfDepth()` 留下该轮迭代器的栈深度，再 `continuation.deinit(ctx.runtime)`；取 `currentLevel()` 后，有深度就 `forof_ops.abandonForOfIteratorAtDepth` 单独退役那条记录（注释说明续延能挺过正规尾调用替换，所以异常中断的字节码 `next()` 可以恰好退役自己那一条，再由普通展开去关闭外层迭代器），接着 `closeStackTopForOfIteratorForPendingError` 做 IteratorClose，最后 `call_runtime.tryCatchInFrame` 找 catch 目标。与栅栏版的两处差别：没有 `errdefer discardToDepth`（本来就一直退到底），以及「降到底就停」的判断放在 `tryCatchInFrame` **之后**（`if (self.depth == 0) return false`）——L0 层自己的 catch 目标仍要被检查。
- **所有权 / 错误 / 调用**：错误：`HostError`，同 `unwindForErrorToDepth`，但没有围栏——一直退到 `depth == 0`，因此不带 `errdefer discardToDepth`。所有权：同上，逐层 pop、`continuation.deinit`、关闭 for-of 迭代器、尝试 `tryCatchInFrame`。调用：唯一调用方 `src/exec/zjs_vm.zig:582`（顶层解释循环的异常臂）。
## `src/exec/small_inline.zig` 函数

### `printProbe` (`src/exec/small_inline.zig:38`)

- **签名**：`pub fn printProbe() void`。
- **作用**：进程收尾时按需打印小函数内联的两个探针计数（`probe_prep` = 准备过多少次特化，`probe_take` = 真正命中执行多少次），供调优时看 take 率。原名 `writeProbeFile` 有误导——它不写文件，只打 stderr。
- **实现**：`std.c.getenv("ZJS_INLINE_PROBE")` 未设置或值为空串直接返回（注释说明 zig 0.16 链接 libc 时没有 `std.posix.getenv`，只能用 `std.c.getenv`）。否则 `std.debug.print` 输出 `prep`、`take` 与整数百分比 `take*100/prep`（`prep == 0` 时打 0，避免除零）。
- **所有权 / 错误 / 调用**：错误：无；`ZJS_INLINE_PROBE` 未设置或为空串直接返回。所有权：只读 `probe_prep`/`probe_take` 两个全局计数器并打印，不分配、不建根。调用：`src/internal_root.zig` 的 `printSmallInlineProbe` 包装（进程退出时打印探针计数）。

### `decodeCallerState` (`src/exec/small_inline.zig:137`)

- **签名**：`fn decodeCallerState(raw: usize) ?*CallerState`。
- **作用**：把从 `FunctionBytecode` 的 hot-extension pad 里读出的那个裸整数还原成 `*CallerState`，同时挡掉「没装」和「未初始化毒值」两种情况。
- **实现**：三道闸：`raw == 0`（没装）或 `raw == 0xaaaaaaaaaaaaaaaa`（Zig 的 undefined 毒字节填充）返回 null；`raw % @alignOf(CallerState) != 0` 说明这不可能是一个合法的 `CallerState` 地址，也返回 null；都过了才 `@ptrFromInt(raw)`。
- **所有权 / 错误 / 调用**：错误：无；raw 为 0、为 `0xaaaa…`（未初始化毒值）或未按 `CallerState` 对齐都返回 null。所有权：只把 `_ctor_alloc_pad` 里存的整数还原成指针，`CallerState` 归 `rt.memory` 所有（`ensureCallerState` 创建、`destroyCallerState` 销毁）。调用：唯一调用方 `src/exec/small_inline.zig:144`（`callerState`）。

### `callerState` (`src/exec/small_inline.zig:143`)

- **签名**：`pub fn callerState(fb: *const FunctionBytecode) ?*CallerState`。
- **作用**：取出某个 caller `FunctionBytecode` 挂着的小函数内联状态（站点计数、已展开的站点表、特化副本数），没有就返回 null。
- **实现**：`fb.hotExtension()` 没有就返回 null；有则从 `hot._ctor_alloc_pad` 的前 `@sizeOf(usize)` 个字节按小端 `readInt` 出一个整数，交给 `decodeCallerState` 校验并转成指针。状态指针借住在这块 pad 的偏移 0，偏移 8 是 borrowed realm，偏移 16 是 apply-forward memo 字节。
- **所有权 / 错误 / 调用**：错误：无；没有 hot extension 或未安装状态返回 null。所有权：返回借用指针，`CallerState` 的生命周期跟随 `FunctionBytecode`（由 `rt.small_inline_destroy` 钩子在 fb 销毁时释放）。调用：本文件 12 处，如 `:148`（`callerStateMut`）、`:242`、`:294`、`:1011`。

### `callerStateMut` (`src/exec/small_inline.zig:149`)

- **签名**：`fn callerStateMut(fb: *FunctionBytecode) ?*CallerState`。
- **作用**：`callerState` 的可写别名：签名收 `*FunctionBytecode` 而非 `*const`，用在要修改状态的调用点上以表明意图。
- **实现**：一行 `return callerState(fb)`——`CallerState` 指针本身不带 const 限定，所以两者实现完全相同，区别只在形参的常量性。
- **所有权 / 错误 / 调用**：错误：无。所有权：与 `callerState` 同一个实现，只是命名上表示调用方要写这块状态（`CallerState` 本身不区分 const）。调用：本文件 `:217`（`destroyCallerState`）与 `:265`（`ensureCallerState` 的已存在分支）。

### `setCallerState` (`src/exec/small_inline.zig:153`)

- **签名**：`fn setCallerState(fb: *FunctionBytecode, state: ?*CallerState) void`。
- **作用**：把 `CallerState` 指针（或 null）写回 `FunctionBytecode` 的 hot-extension pad，是安装与卸载状态的唯一写入点。
- **实现**：`fb.hotExtensionMut()` 拿不到就静默返回（没有 pad 可写）。把 optional 指针折成 `usize`（null → 0），`std.mem.writeInt(..., .little)` 写进 `hot._ctor_alloc_pad[0..@sizeOf(usize)]`。
- **所有权 / 错误 / 调用**：错误：无；没有可写 hot extension 时静默返回。所有权：把指针（或 0）以小端整数写进 `hot._ctor_alloc_pad`，不转移所有权——真正的分配/释放在 `ensureCallerState`/`destroyCallerState`。调用：本文件 `:218`（销毁时清零）与 `:268`（安装新状态）。

### `applyForwardEligible` (`src/exec/small_inline.zig:166`)

- **签名**：`fn applyForwardEligible(fb: *FunctionBytecode) bool`。
- **作用**：问某个 callee 的函数体是不是 L1 可改写的 `f.apply(this, arguments)` 形状；结果按 FB 缓存，避免每个站点都重跑整趟字节码分析。
- **实现**：带 memo 的分析：先读 `hot._ctor_alloc_pad[apply_forward_memo_off]`（偏移 16 的那个字节），命中 `apply_forward_memo_yes`(2) 返回 true、`apply_forward_memo_no`(1) 返回 false；0 表示未知。未知时才跑一次真分析 `analyzeApplyForward(fb) != null`，并把结果写回 memo 字节（若有可写 pad）。这个 memo 与偏移 0 的 CallerState 指针、偏移 8 的 borrowed realm 字共用同一块 pad，互不重叠。
- **所有权 / 错误 / 调用**：错误：无。所有权：结果 memo 在 `hot._ctor_alloc_pad[apply_forward_memo_off]` 这个字节里缓存（yes/no 两个哨兵），未命中才跑 `analyzeApplyForward`；不分配。调用：唯一调用方 `src/exec/small_inline.zig:332`（内联准入的 callee 判定）。

### `anyApplyForwardSite` (`src/exec/small_inline.zig:180`)

- **签名**：`fn anyApplyForwardSite(state: *const CallerState) bool`。
- **作用**：问某个 caller 的已展开站点里有没有哪一个做了 L1 的 `fn.apply(this, arguments)` 转发改写——用于决定要不要给这个 FB 打 `apply_forward_inlined` 标志。
- **实现**：从 0 线性扫到 `state.inlined_len`，只要 `state.apply_forward[i].call_pc != no_forward_pc`（哨兵是 `maxInt(u32)`）就返回 true，扫完返回 false。读的是与热表 `inlined` 并列的冷表 `apply_forward`——把 L1 事实放在旁边而不是塞进 `InlinedSite`，是为了不拉宽 `findInlinedSite` 扫描的步距。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读扫描 `state.apply_forward[0..inlined_len]`，看有没有站点的 `call_pc != no_forward_pc`。调用：唯一调用方 `src/exec/small_inline.zig:1320`。

### `siteSlot` (`src/exec/small_inline.zig:188`)

- **签名**：`fn siteSlot(state: *const CallerState, site: *const InlinedSite) u8`。
- **作用**：把一个 `InlinedSite` 指针换算回它在 `CallerState.inlined` 数组里的槽号，以便索引并列存放的冷侧表。
- **实现**：指针算术：`(@intFromPtr(site) - @intFromPtr(&state.inlined[0])) / @sizeOf(InlinedSite)`，前后各一条 Debug 断言（不低于数组首、小于 `inlined_len`），结果窄化成 `u8`。热侧 `inlined` 与冷侧 `apply_forward` 同序同长，所以这个下标直接就是冷侧查表键。
- **所有权 / 错误 / 调用**：所有权：无。 错误：无。 调用：唯一调用方 `applyForwardColdOf`（small_inline.zig:195）。

### `applyForwardColdOf` (`src/exec/small_inline.zig:197`)

- **签名**：`fn applyForwardColdOf(state: *const CallerState, site: *const InlinedSite) ApplyForwardCold`。
- **作用**：取出某个已展开站点对应的 L1 转发冷记录（被转发的方法名 atom 与改写点 pc）。
- **实现**：一行 `return state.apply_forward[siteSlot(state, site)]`：用 `siteSlot` 把站点指针换算成下标，再从并列的冷表取记录，按值返回 `ApplyForwardCold`（`{method_atom, call_pc}` 两个字段）。
- **所有权 / 错误 / 调用**：错误：无；站点索引由 `siteSlot` 负责。所有权：按值返回 `ApplyForwardCold` 副本，不借指针。调用：本文件 `:200`（`siteApplyForwarded`）、`:1489`、`:1505`。

### `siteApplyForwarded` (`src/exec/small_inline.zig:201`)

- **签名**：`fn siteApplyForwarded(state: *const CallerState, site: *const InlinedSite) bool`。
- **作用**：问某一个具体站点是不是做了 L1 apply 转发改写。
- **实现**：一行 `return applyForwardColdOf(state, site).call_pc != no_forward_pc`——冷记录里的 `call_pc` 保持哨兵值就表示这个站点没做转发。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读。调用：唯一调用方 `src/exec/small_inline.zig:1333`。

### `markApplyForwardInlined` (`src/exec/small_inline.zig:205`)

- **签名**：`fn markApplyForwardInlined(fb: *FunctionBytecode) void`。
- **作用**：给 caller 的 `FunctionBytecode` 打上「本函数体内已存在 apply 转发展开」的执行标志，让运行期的相关守卫知道要检查这条路径。
- **实现**：读 `fb.executionFlags()`，已置 `apply_forward_inlined` 就直接返回（避免一次无谓的写回），否则置位并 `fb.setExecutionFlags(flags)` 写回。
- **所有权 / 错误 / 调用**：错误：无；`executionFlags` 已置位就直接返回，避免重复写。所有权：改的是 `FunctionBytecode` 自己的执行标志位。调用：唯一调用方 `src/exec/small_inline.zig:1320`（发现有 apply 转发站点时）。

### `setBorrowedRealm` (`src/exec/small_inline.zig:212`)

- **签名**：`fn setBorrowedRealm(fb: *FunctionBytecode, realm: ?*core.JSContext) void`。
- **作用**：把生成特化副本时所依据的那个 realm（`JSContext`）借记在 caller FB 上，供后续守卫核对「这份展开是在哪个 realm 的全局对象上证明的」。
- **实现**：`fb.hotExtensionMut()` 拿不到就静默返回。把 optional `*JSContext` 折成 `usize`（null → 0），写进 `hot._ctor_alloc_pad[borrowed_realm_off..][0..@sizeOf(usize)]`，即 pad 的偏移 8 那个字，小端。
- **所有权 / 错误 / 调用**：错误：无；没有可写 hot extension 就静默返回。所有权：只把 realm 的 `JSContext` 指针以整数形式借存在 `hot._ctor_alloc_pad[borrowed_realm_off..]`——「borrowed」即不 retain、不参与 GC 边，realm 死掉前由 `destroyCallerState` 写回 0。调用：本文件 `:221`（`destroyCallerState` 清理）与 `:1319`（特化副本记下调用方 realm）。

### `destroyCallerState` (`src/exec/small_inline.zig:218`)

- **签名**：`pub fn destroyCallerState(rt: *JSRuntime, fb: *FunctionBytecode) void`。
- **作用**：`FunctionBytecode` 销毁时释放它挂着的小函数内联状态，并把 pad 里的两个借用字清零。
- **实现**：`callerStateMut(fb)` 为 null 直接返回（从没装过）。否则先 `setCallerState(fb, null)` 断开指针，再 `setBorrowedRealm(fb, null)` 清掉 realm 字，最后 `rt.memory.destroy(CallerState, state)` 归还内存。站点里的 atom **不**在这里释放（tracer 拥有那些边）——原先这里还有一个遍历 `inlined_len` 的空循环体，是 rc 时代的残骸，已删。
- **所有权 / 错误 / 调用**：`CallerState` 经 `MemoryAccount` 分配，这里 `rt.memory.destroy` 释放并把 FB hot-extension pad 里的指针与 borrowed realm 清零。错误：无。 调用：经 `rt.small_inline_destroy` 钩子，由 `src/bytecode.zig` 的 FunctionBytecode 析构调用。

### `destroyCallerStateOpaque` (`src/exec/small_inline.zig:225`)

- **签名**：`fn destroyCallerStateOpaque(rt: *JSRuntime, fb_ptr: *anyopaque) void`。
- **作用**：`destroyCallerState` 的类型擦除包装，用来装进 `rt.small_inline_destroy` 这个函数指针钩子——core 不认识 `FunctionBytecode` 的具体类型。
- **实现**：把 `*anyopaque` 用 `@ptrCast(@alignCast(...))` 还原成 `*FunctionBytecode`，再转调 `destroyCallerState(rt, fb)`。
- **所有权 / 错误 / 调用**：错误：无。所有权：只做 `*anyopaque` → `*FunctionBytecode` 的还原并转调，真正的释放在 `destroyCallerState`。调用：不直接被调用——`ensureCallerState` 把它装进 `rt.small_inline_destroy`，再由 FunctionBytecode 析构经钩子调用。

### `traceCallerStateAtoms` (`src/exec/small_inline.zig:235`)

- **签名**：`fn traceCallerStateAtoms( rt: *JSRuntime, fb_ptr: *anyopaque, ctx: *anyopaque, visit: *const fn (ctx: *anyopaque, id: core.Atom) void, ) void`。
- **作用**：GC 标记阶段的边报告函数：在 `FunctionBytecode` 被 trace 时把 `CallerState` 里持有的 atom id 全部报给 tracer（TGC S3 §2.2 边 H）。`destroyCallerState` 那侧**没有**对应的释放动作——这些 atom 边完全归 tracer。
- **实现**：`_ = rt`；把 `fb_ptr` 还原成 `*FunctionBytecode`，取 `callerState`（无则直接返回），遍历 `inlined_len` 个站点，对每个站点 `visit` 其 `callee_name`、`callee_file`，以及并行数组 `apply_forward[i]` 里非 null 的 `method_atom`。
- **所有权 / 错误 / 调用**：只读遍历，不转移所有权。错误：无。 调用：不直接被调用——`ensureCallerState` 把它装进 `rt.small_inline_trace_atoms`，由 `src/core/gc_trace_stw.zig` 标记阶段经钩子调用。

### `fillDefaultCallerState` (`src/exec/small_inline.zig:256`)

- **签名**：`fn fillDefaultCallerState(state: *CallerState) void`。
- **作用**：把新建的 `CallerState` 初始化成等价于 `.{}` 的状态，但避开按默认值赋值带来的大块常量复制。
- **实现**：两步：`@memset(std.mem.asBytes(state), 0)` 整块清零，再 `for (&state.apply_forward) |*fwd| fwd.call_pc = no_forward_pc` 把每个冷记录的 `call_pc` 写成哨兵。注释给了动机——`CallerState{}` 除这一个字段外全是 0，直接写 `state.* = .{}` 会从 `.rodata` 复制一份 3592 字节的模板。
- **所有权 / 错误 / 调用**：错误：无。所有权：就地初始化调用方给的 `CallerState`——整块 `@memset(0)` 后把每个 `apply_forward[i].call_pc` 写成 `no_forward_pc` 哨兵，等价于 `.{}` 但避免复制 3592 字节 `.rodata` 模板。调用：本文件 `:267`（`ensureCallerState` 新建后）与 `:1557`。

### `ensureCallerState` (`src/exec/small_inline.zig:263`)

- **签名**：`fn ensureCallerState(rt: *JSRuntime, fb: *FunctionBytecode) ?*CallerState`。
- **作用**：取出或按需创建某个 caller 的 `CallerState`，并在首次使用时把销毁与 GC 描边两个钩子装到 runtime 上。
- **实现**：先补钩子：`rt.small_inline_destroy` 为 null 就装 `destroyCallerStateOpaque`，`rt.small_inline_trace_atoms` 为 null 就装 `traceCallerStateAtoms`——这样一个从不建 `CallerState` 的 runtime 一分钱都不付。随后 `callerStateMut(fb)` 命中就直接返回已有状态；否则 `rt.memory.create(CallerState) catch return null`（OOM 时放弃特化而不是报错），`fillDefaultCallerState` 初始化，`setCallerState` 装到 fb 上并返回。
- **所有权 / 错误 / 调用**：错误：无——`rt.memory.create` 失败时 `catch return null`，调用方据此放弃特化。所有权：新建的 `CallerState` 归 `rt.memory`，指针存进 fb 的 hot extension；释放靠首次调用时安装的 `rt.small_inline_destroy = destroyCallerStateOpaque` 钩子（同时安装 `small_inline_trace_atoms`，让 GC 能扫到状态里的 atom）。调用：本文件 `:336`（`noteMonomorphic`）与 `:1264`。

### `hasTrailingAfterReturn` (`src/exec/small_inline.zig:273`)

- **签名**：`fn hasTrailingAfterReturn(code: []const u8) bool`。
- **作用**：扫一遍 callee 的字节码，判断它在第一条 `return` / `return_undef` 之后还有没有残留指令——有的话形状不是单出口直线体，不能内联展开。
- **实现**：`pc` 从 0 起；若首字节是 `op.check_ctor` 就跳过它（构造器体的固定前缀）。循环按 `bytecode.opcode.sizeOf(opc)` 步进：size 为 0 或 `pc + size` 越界时保守返回 true（未知编码一律当作有尾巴，禁止内联）；遇到 `op.return_undef` 或 `op.@"return"` 就返回 `pc < code.len`，即「返回指令之后还有字节吗」。整条扫完没遇到返回指令则返回 false。
- **所有权 / 错误 / 调用**：错误：无；遇到未知/越界指令时保守返回 true（视为有尾巴，禁止内联）。所有权：只读字节码切片。调用：唯一调用方 `src/exec/small_inline.zig:380`（`specializeCallSite` 的 callee 形状检查）。

### `budgetRemaining` (`src/exec/small_inline.zig:286`)

- **签名**：`fn budgetRemaining(rt: *const JSRuntime) usize`。
- **作用**：算出当前还允许生成多少字节的特化副本——这是防止内联在大代码库上无限膨胀的全局闸门。
- **实现**：以 `rt.small_inline_published_bytes`（已发布字节码总量）为基数取 3%（`published / 100 * 3`，先除后乘避免溢出），再夹进 `[16 KiB, 256 KiB]`：`@min(@max(frac, budget_floor_bytes), budget_cap_bytes)`。已用的 `rt.small_inline_specialized_bytes` 达到或超过这个 cap 就返回 0，否则返回差值。常量注释说明 16 KiB 地板是 driver 批准的（INLINE-PROPOSAL §8）——3% 对一个 200 字节的 micro 只有 6 字节，会把用例唯一需要的那份副本挡掉；zoo/TS 规模则仍受 3%/256 KiB 上限约束。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `rt.small_inline_published_bytes` 与 `small_inline_specialized_bytes` 两个计数器算剩余预算（按已发布字节的比例，夹在 floor 与 cap 之间）。调用：本文件 `:396`（特化前的闸门）与 `:1148`（按新代码长度二次核算）。

### `findInlinedSite` (`src/exec/small_inline.zig:294`)

- **签名**：`pub fn findInlinedSite(fb: *const FunctionBytecode, call_pc: u32) ?*const InlinedSite`。
- **作用**：按调用指令的 pc 查这个 caller 有没有在该站点做过内联展开——这是运行期决定「走展开体还是走真调用」的查表入口。
- **实现**：`callerState(fb)` 为 null 返回 null；否则从 0 线性扫到 `inlined_len`，比对 `state.inlined[i].call_pc == call_pc`，命中返回该站点指针。站点表最长 `max_sites`=16，所以线性扫即可；冷侧的 `apply_forward` 刻意不在这个循环里读，以保住扫描步距。
- **所有权 / 错误 / 调用**：错误：无；没有 `CallerState` 或没命中返回 null。所有权：返回指向状态数组内部的借用指针，随 `CallerState` 生命周期失效。调用：本文件 `:335`、`:391`，以及 `src/exec/tailcall_dispatch.zig:2705`、`:2787`（回溯/调试查内联站点）。

### `siteForPc` (`src/exec/small_inline.zig:303`)

- **签名**：`pub fn siteForPc(fb: *const FunctionBytecode, pc: usize) ?*const InlinedSite`。
- **作用**：按任意一个 pc 反查它落在哪次内联展开的区间里，用于异常回溯时判断当前正在执行的是哪个被内联掉的 callee。
- **实现**：与 `findInlinedSite` 同样的线性扫，但匹配条件是区间包含：`pc >= site.pc_lo and pc < site.pc_hi`，即这个 pc 落在某次展开占用的字节码区间里。
- **所有权 / 错误 / 调用**：错误：无。所有权：同 `findInlinedSite`，但按 `[pc_lo, pc_hi)` 区间找包含该 pc 的站点，返回借用指针。调用：本文件 `:1376`（`logicalInlineFrames`）与 `:1503`。

### `mapCalleePc` (`src/exec/small_inline.zig:313`)

- **签名**：`pub fn mapCalleePc(site: *const InlinedSite, expanded_pc: usize) usize`。
- **作用**：把 caller 特化副本里的 pc 翻译回 callee 原始字节码的 pc，让被内联掉的函数在栈回溯里仍能报出自己的位置。
- **实现**：把 caller 特化副本里的 pc 翻回 callee 原始 pc。`expanded_pc < site.pc_lo` 返回 0；算 `rel = expanded_pc - site.pc_lo`，`rel >= site.pc_map_len` 返回 0；查 `site.pc_map[rel]`，等于 `0xFFFF`（未知空洞）也返回 0。返回 0 表示回落到 callee 函数体起点。`pc_map` 是固定 `max_pc_map`=64 项的 u16 数组。
- **所有权 / 错误 / 调用**：错误：无；越界或 `0xFFFF` 空洞都返回 0（回落到 callee 入口）。所有权：只读站点内的 `pc_map`。调用：唯一调用方 `src/exec/small_inline.zig:1401`（合成内联帧的快照 pc）。

### `noteMonomorphic` (`src/exec/small_inline.zig:326`)

- **签名**：`pub fn noteMonomorphic( rt: *JSRuntime, caller: *FunctionBytecode, call_pc: u32, callee: *FunctionBytecode, callee_obj: *Object, ) bool`。
- **作用**：在一个调用站点每次观察到「callee 与上次是同一个函数对象」时记一次数，命中门限（M=8）后回报 true，告诉调用方该给这个 caller 生成展开了这个站点的特化副本。
- **实现**：计同一 call_pc + callee_obj 的命中。换 callee 则 `never`。达到 `monomorph_hits`(8) 且副本未超上限时返回 true，让调用方 `specializeCallSite`。
- **所有权 / 错误 / 调用**：错误：无，返回 false 表示这次不要特化。所有权：状态由 `ensureCallerState` 创建并归 fb 所有；本函数只更新站点计数——同一 callee 再次命中就加计数，callee 变了就把该站点标 `never` 并清掉记录的 `callee_obj`（去优化为多态）。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2807`。

### `specializeCallSite` (`src/exec/small_inline.zig:368`)

- **签名**：`pub fn specializeCallSite( rt: *JSRuntime, caller_obj: *Object, caller: *FunctionBytecode, call_pc: u32, callee: *FunctionBytecode, callee_fn_obj: *Object, kind: Kind, argc: u16, ) void`。
- **作用**：小函数内联的安装入口：过完全部门禁（形状、预算、apply 守卫）后让 `cloneAndExpand` 造出展开副本，并把它换到 caller 的函数对象上。
- **实现**：拒绝 eval/module/超 2048B/欠参/return 后还有代码。`cloneAndExpand` 出新 FB，`caller_obj.setFunctionBytecodeValue` 换成专用副本。apply-forward 先检查 realm `Function.prototype.apply` 守卫。
- **所有权 / 错误 / 调用**：错误：无——所有失败条件（eval/module、字节码超 2048、实参不足、callee 有尾巴、预算耗尽、apply 守卫不成立、克隆失败、`setFunctionBytecodeValue` 失败）都是静默 return。所有权：`cloneAndExpand` 造出的特化 `FunctionBytecode` 通过 `caller_obj.setFunctionBytecodeValue(rt, next)` 装到调用方函数对象上，从此由该对象/GC 持有；失败时克隆体随 fb 的常规回收路径处理。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2815`。

### `locIndexOf` (`src/exec/small_inline.zig:424`)

- **签名**：`fn locIndexOf(opc: u8, src: []const u8, pc: usize) ?u16`。
- **作用**：从一条局部变量存取指令里解出它访问的是第几号 local——短形式把槽号编进 opcode，长形式才带操作数。
- **实现**：对 opcode 做 switch：`get_loc0`/`put_loc0`/`get_loc0_field` → 0，`get_loc1`/`put_loc1` → 1，`get_loc2`/`put_loc2`/`get_loc2_field` → 2，`get_loc3`/`put_loc3` → 3；`get_loc8`/`put_loc8`/`put_loc8_get_loc8` 读紧跟的一个字节 `src[pc+1]`；`get_loc`/`put_loc` 按小端读两字节 `u16`；其余返回 null（不是局部存取指令）。
- **所有权 / 错误 / 调用**：错误：无；不是局部变量访问类指令返回 null。所有权：只读字节码，短形式从 opcode 自身取槽号，`get_loc8`/`put_loc8` 读 1 字节、`get_loc`/`put_loc` 读小端 u16。调用：本文件 6 处，如 `:517`、`:582`、`:628`。

### `isPutLoc` (`src/exec/small_inline.zig:436`)

- **签名**：`fn isPutLoc(opc: u8) bool`。
- **作用**：问某个 opcode 是不是「写局部变量」这一族。
- **实现**：switch 白名单：`put_loc0`..`put_loc3`、`put_loc8`、`put_loc`、以及融合形 `put_loc8_get_loc8` 返回 true，其余 false。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯 switch，无状态。调用：本文件 `:515` 与 `:627`。

### `isGetLoc` (`src/exec/small_inline.zig:443`)

- **签名**：`fn isGetLoc(opc: u8) bool`。
- **作用**：问某个 opcode 是不是「读局部变量」这一族。
- **实现**：switch 白名单：`get_loc0`..`get_loc3`、`get_loc8`、`get_loc`，以及两个融合形 `get_loc0_field`、`get_loc2_field` 返回 true，其余 false。注意融合形也算「读局部」，因为它们的第一步就是取局部槽。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯 switch。调用：本文件 `:524`、`:581`、`:590`。

### `isPutArg` (`src/exec/small_inline.zig:450`)

- **签名**：`fn isPutArg(opc: u8) bool`。
- **作用**：问某个 opcode 是不是「写形参」这一族——apply 转发分析里一旦出现就直接否决（条款 S7），因为改写后的实参窗口语义与原体不同。
- **实现**：switch 白名单：`put_arg0`..`put_arg3` 与 `put_arg` 返回 true，其余 false。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯 switch。调用：唯一调用方 `src/exec/small_inline.zig:499`（S7 条款：写实参的 callee 不许转发）。

### `isForwardForbiddenOp` (`src/exec/small_inline.zig:457`)

- **签名**：`fn isForwardForbiddenOp(opc: u8) bool`。
- **作用**：问某条指令是否禁止出现在 apply 转发候选体里——判据不再是手工维护的名单，而是 opcode 声明自带的转发策略。
- **实现**：两步：`bytecode.opcode.physical.stateOf(opc) != .claimed` 说明这个物理编号没被任何逻辑 opcode 认领（未定义/保留），保守返回 true；否则把编号 `@enumFromInt` 成 `LogicalOpcode`，读 `traitsOf(form).forward_policy`，等于 `.forbidden` 才返回 true。注释（F0b）说明这么写是为了让策略随声明走（不变量 5），它替换掉的是 5.2 条款 3 所指的两张手工身份表里的第二张。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 opcode 表——物理编号未 `claimed` 一律视为禁止，其余查逻辑 opcode 的 `traitsOf(form).forward_policy`。调用：唯一调用方 `src/exec/small_inline.zig:498`（S2/S3 条款）。

### `analyzeApplyForward` (`src/exec/small_inline.zig:470`)

- **签名**：`fn analyzeApplyForward(fb: *const FunctionBytecode) ?ApplyForwardPlan`。
- **作用**：对一个 callee 函数体做 L1 模式识别：它必须恰好是「取 `arguments` 存进一个局部 → 取 this 上的某个方法 → 取它的 `apply` → 用 (thisArg, 那个局部) 调用」这一条直线，识别成功就给出改写所需的全部 pc 与槽号。
- **实现**：一遍线性扫描 + 一组收尾核对，任何一条不满足就返回 null。**前置筛（S1/S2）**：形参表必须简单、`closureVarCount`/`openVarRefCount` 均为 0、kind 为 `.normal`、不是 derived class constructor、字节码非空且长度 ≤ `max_code`(40)。**主扫描**（首字节是 `op.check_ctor` 则从 1 开始）：每条按 `sizeOf` 步进，size 为 0 或越界返回 null；`isForwardForbiddenOp`（S2/S3）或 `isPutArg`（S7）命中返回 null；见到跳转类 opcode 且还没遇到目标 call，就置 `saw_jump_before_call`。遇 `op.special_object` 时子类型必须是 `arguments` 或 `mapped_arguments`，且只允许出现一次，记下 `special_pc`。紧跟其后的 `put_loc` 认定为「把 arguments 存进某个 local」，记下 `args_local`/`special_put_pc`；此后若再有 `put_loc` 写同一个 local 则返回 null（该 local 必须单赋值）。读该 local 的 `get_loc` 计入 `get_args_count` 并记 `get_args_pc`。遇 `get_field` 家族时读 4 字节 atom：若 atom 是 `apply` 且 opcode 是 `get_field2`/`get_field2_call_method`，则它必须只出现一次、前一条必须是 `get_field`/`get_field_field2`（那才是取被转发方法本身），并记下 `method_get_pc` 与 `method_atom`（方法名不能也是 `apply`）。遇 `op.call_method` 时实参数必须恰为 2（S5：`apply(thisArg, argArray)`）且此前已见 apply 取值，记 `call_pc`；其它任何 call 家族出现在目标 call 之前一律返回 null。**收尾核对**：`saw_jump_before_call` 为真返回 null；七个记录位（special/special_put/args_local/apply_get/method_get/method_atom/call_pc/get_args_pc）缺一返回 null；`get_args_count` 与 `put_args_count` 都必须恰为 1（S4）；`get_args_pc` 必须正好是 `call_pc` 的前一条指令。再往前一条是 thisArg 的来源，它要么是 `push_this`/`push_this_put_loc0`，要么是读 `firstThisLocal(code)` 找出的那个 this local（S6），否则 null；`method_get_pc` 前一条同样要满足这个 this 判据。全部通过才返回填好九个 pc/槽位的 `ApplyForwardPlan`。
- **所有权 / 错误 / 调用**：错误：无；十几处形状检查任一不过都返回 null。所有权：只读 callee 字节码，结果 `ApplyForwardPlan` 按值返回（`applyForwardEligible` 会把「有/无」memo 进 hot extension）。调用：本文件 `:170`（memo 填充）、`:399`（安装前的守卫）、`:747`（`rewriteBody` 重写时）。

### `prevOpBefore` (`src/exec/small_inline.zig:609`)

- **签名**：`fn prevOpBefore(code: []const u8, target: usize) usize`。
- **作用**：求出 `target` 这个 pc 之前紧邻的那条指令的起点——字节码是变长的，只能从头解码着走。
- **实现**：起点跳过可选的 `op.check_ctor` 前缀（首字节是它就从 1 开始）。循环 `while (pc < target)`：每轮先把当前 `pc` 记进 `last`，再按 `sizeOf(code[pc])` 步进；size 为 0（未知编码）就跳出。返回 `last`。注意若 `target` 就是起点，返回的也是起点。
- **所有权 / 错误 / 调用**：错误：无；`sizeOf` 为 0 时提前 break，返回已走到的最后一个 pc。所有权：只读。调用：本文件 `:574`、`:576`、`:586`（apply 转发形状的回看）。

### `firstThisLocal` (`src/exec/small_inline.zig:621`)

- **签名**：`fn firstThisLocal(code: []const u8) ?u16`。
- **作用**：找出函数体把 `this` 缓存进了哪个局部槽——形如 `push_this; put_locN` 的序言，apply 转发分析要用它来核对 thisArg 的来源是同一个 this。
- **实现**：同样跳过可选 `op.check_ctor` 后线性解码，维护 `prev_op`。一旦当前指令是 `isPutLoc` 且前一条是 `push_this` 或融合形 `push_this_put_loc0`，就 `locIndexOf` 出槽号返回。遇到 size 为 0 或越界返回 null；扫完没找到也返回 null。
- **所有权 / 错误 / 调用**：错误：无；没找到返回 null。所有权：只读——扫 `push_this`/`push_this_put_loc0` 之后紧跟的 put_loc，取其槽号。调用：唯一调用方 `src/exec/small_inline.zig:578`。

### `emitByte` (`src/exec/small_inline.zig:649`)

- **签名**：`fn emitByte(out: *Rewrite, b: u8) bool`。
- **作用**：往特化副本的改写缓冲里追加一个字节，缓冲满时返回 false 让整次改写作废。
- **实现**：容量检查 `out.len >= out.code.len` 不过就返回 false（调用方据此放弃整次改写），否则写一个字节并 `out.len += 1`，返回 true。`Rewrite` 缓冲是定长的，所有 emit 都靠这个布尔返回值串成「一处失败即整体放弃」。
- **所有权 / 错误 / 调用**：错误：无；输出缓冲满返回 false，调用方一路 `orelse return null` 放弃重写。所有权：写的是调用方栈上的 `Rewrite.code` 定长缓冲，不分配。调用：本文件 9 处发射点，如 `:670`、`:682`、`:813`。

### `emitSlice` (`src/exec/small_inline.zig:656`)

- **签名**：`fn emitSlice(out: *Rewrite, bytes: []const u8) bool`。
- **作用**：往改写缓冲里追加一段字节（指令的操作数），放不下返回 false。
- **实现**：`out.len + bytes.len > out.code.len` 返回 false；否则 `@memcpy` 进缓冲尾部并推进 `out.len`，返回 true。
- **所有权 / 错误 / 调用**：错误：无；容量不足返回 false。所有权：`@memcpy` 进调用方的定长缓冲。调用：本文件 6 处，如 `:678`、`:906`、`:909`。

### `emitLocOp` (`src/exec/small_inline.zig:663`)

- **签名**：`fn emitLocOp(out: *Rewrite, get: bool, slot: u16) bool`。
- **作用**：发射一条读或写局部变量的指令，并按槽号自动挑最短的编码形式。
- **实现**：按槽号挑最短的形式发射一条局部读或写。`wide` 取 `.get_loc` 或 `.put_loc`；`decode.selectSlotShortForm(wide, slot)` 命中短形式时，发射短 opcode，并按 `decode.form_row[...].size == 2` 决定要不要再补一个字节的槽号（`loc0..loc3` 把槽号编在 opcode 里、size 为 1，`loc8` 需要一个字节）。未命中短形式则发射宽 opcode 加两字节小端槽号。注释指出这与 `resolve_labels` 的 `putShortCode` 用同一个选择器（契约 3）：短形式来自声明表而不是 `base + slot` 的编号算术，操作数有没有也是被选中那一行的事实。
- **所有权 / 错误 / 调用**：错误：无，容量不足经 `emitByte`/`emitSlice` 返回 false。所有权：只写重写缓冲——能用短形式（`selectSlotShortForm`）就发 1-2 字节，否则发宽形式加小端 u16 槽号。调用：本文件 16 处局部变量读写发射点，如 `:805`、`:825`、`:845`。

### `emitCallMethodApplyFwd` (`src/exec/small_inline.zig:682`)

- **签名**：`fn emitCallMethodApplyFwd(out: *Rewrite, argc: u16) bool`。
- **作用**：发射 L1 改写的核心指令 `call_method_apply_fwd`：它用调用方活的 argv 直接做方法调用，取代原体里那次 `f.apply(this, arguments)`。
- **实现**：发射 `op.call_method_apply_fwd` 后跟三字节操作数：两字节小端 `argc`，第三字节写 `bytecode.CallSiteCache.no_cache_idx`。注释说明为什么不给缓存槽——改写后的站点住在 caller 的特化副本里，而缓存下标空间属于 caller 自己的那些站点，沿用 callee 体里的下标会与其中之一别名。
- **所有权 / 错误 / 调用**：错误：无，缓冲不足返回 false。所有权：发 `call_method_apply_fwd` + argc(u16) + `CallSiteCache.no_cache_idx`——特化副本不继承调用点缓存槽。调用：唯一调用方 `src/exec/small_inline.zig:809`。

### `clearPropSiteIndices` (`src/exec/small_inline.zig:692`)

- **签名**：`fn clearPropSiteIndices(code: []u8) void`。
- **作用**：把一段刚拷进特化副本的字节码里所有属性访问的内联缓存下标抹成「无缓存」——这些下标属于原 callee 的站点空间，直接搬过来会与 caller 自己的站点别名。
- **实现**：从 0 线性解码：按 `sizeOf` 步进，size 为 0 或越界就提前返回（保守放弃后续清理）；`bytecode.opcode.carriesPropCacheIdx(opc)` 为真的指令把 `code[pc + 5]`（opcode 之后 4 字节 atom 再往后那一位）写成 `bytecode.PropSiteCache.no_cache_idx`。
- **所有权 / 错误 / 调用**：错误：无；遇到非法 size 直接 return。所有权：就地改写传入的可变字节码切片，把所有带属性缓存槽的指令的 `cache_idx` 写成 `PropSiteCache.no_cache_idx`，避免克隆体复用原函数的缓存槽。调用：唯一调用方 `src/exec/small_inline.zig:1109`。

### `emitGetField2` (`src/exec/small_inline.zig:704`)

- **签名**：`fn emitGetField2(out: *Rewrite, atom_id: u32) bool`。
- **作用**：发射一条 `get_field2` 属性读，用于在改写体里取出被转发的那个方法。
- **实现**：发射 `op.get_field2` 后跟五字节：四字节小端 atom id，第五字节是 W1 的 `atom_cache_u8`，同样写 `bytecode.PropSiteCache.no_cache_idx`——理由与 `emitCallMethodApplyFwd` 相同：callee 体的站点下标会与 caller 自己的属性站点别名，所以改写出来的这次读不带缓存槽。
- **所有权 / 错误 / 调用**：错误：无。所有权：发 `get_field2` + atom id(u32) + `no_cache_idx`；atom 的引用由站点记录（`traceCallerStateAtoms` 会报给 tracer）。调用：唯一调用方 `src/exec/small_inline.zig:794`。

### `emitGoto` (`src/exec/small_inline.zig:715`)

- **签名**：`fn emitGoto(out: *Rewrite, target: i32) bool`。
- **作用**：发射一条宽形式无条件跳转，目标由第二遍回填。
- **实现**：发射 `op.goto` 后跟四字节小端 `i32` 相对目标。改写第一遍发射时目标通常先填 0，第二遍由 `patchJump` 回填真实偏移。
- **所有权 / 错误 / 调用**：错误：无。所有权：发 `goto` + 4 字节相对位移占位，真正的目标由 `patchJump` 回填。调用：本文件 `:880`、`:887`、`:1110`。

### `recordMap` (`src/exec/small_inline.zig:722`)

- **签名**：`fn recordMap(out: *Rewrite, start_len: usize, callee_pc: usize) void`。
- **作用**：给刚刚发射出来的那几个字节登记「它们来自 callee 的哪个 pc」，喂给 `InlinedSite.pc_map`，异常回溯时才能把展开后的 pc 翻回原始行列号。
- **实现**：从本条指令发射前的 `start_len` 遍历到当前 `out.len`（上限 `max_pc_map`=64），把每个字节位置的 `pc_map[i]` 都写成 `callee_pc`（`std.math.cast(u16, ...)` 溢出时退成 0）。随后把 `out.map_len` 抬到 `@min(out.len, max_pc_map)`。也就是说映射表是按**字节**而非按指令建的，且只覆盖前 64 字节。
- **所有权 / 错误 / 调用**：错误：无。所有权：把新发射区间 `[start_len, out.len)` 的每个字节都映射到 callee 的 `callee_pc`，写进 `Rewrite.pc_map`（上限 `max_pc_map`），用于回溯还原内联帧。调用：本文件 5 处发射点之后，如 `:795`、`:814`、`:912`。

### `rewriteBody` (`src/exec/small_inline.zig:730`)

- **签名**：`fn rewriteBody( callee: *const FunctionBytecode, this_slot: u16, arg_base: u16, var_base: u16, kind: Kind, site_argc: u16, ) ?Rewrite`。
- **作用**：把 callee 体改写成以调用者槽（this/arg/var base）为基准的字节码片段，供 `cloneAndExpand` 拼进专用副本。
- **实现**：先 `analyzeApplyForward(callee)` 取 L1 计划；源码长度超 `max_code` 直接返回 null。第一遍按指令起点逐条发射（apply-forward 命中的 special_object/put_loc/get_loc/apply 取值站点被吞掉，method 取值改发 `emitGetField2`，`call_method` 改成逐参 `emitLocOp` + `emitCallMethodApplyFwd`），跳转操作数先留 0 并记录发射位置与 `pc_map`；第二遍再用 `patchJump` 把跳转回填到新偏移。
- **所有权 / 错误 / 调用**：错误：无；任何一步（源码过长、不支持的指令、缓冲溢出、跳转回填失败）返回 null，调用方放弃特化。所有权：整个重写在栈上的 `Rewrite` 里完成（定长 `code`/`pc_map`/`old_to_new`），不分配；产物由 `cloneAndExpand` 再复制进新 `FunctionBytecode`。调用：唯一调用方 `src/exec/small_inline.zig:1100`。

### `relTarget` (`src/exec/small_inline.zig:954`)

- **签名**：`fn relTarget(pos: usize, operand_off: usize, diff: i32) usize`。
- **作用**：把源字节码里一条跳转的相对偏移换算成绝对目标 pc，用于在改写第一遍里记下「这条跳转原本要跳到哪」。
- **实现**：`base = pos + operand_off` 是相对偏移的计算基准（操作数字段之后的位置），加上 `diff` 得 `dest`。`dest < 0` 时返回 `std.math.maxInt(usize)` 当哨兵——调用方把这个值当作「目标非法」，随后的映射查找必然落空，从而放弃改写。全程用 `i64` 中转，避免 usize 下溢。
- **所有权 / 错误 / 调用**：错误：无；目标为负时返回 `maxInt(usize)` 当无效哨兵。所有权：纯算术。调用：本文件 `:928`-`:944` 五处跳转目标换算。

### `patchJump` (`src/exec/small_inline.zig:961`)

- **签名**：`fn patchJump(out: *Rewrite, emit_pc: usize, opc: u8, new_target: usize) ?void`。
- **作用**：改写第二遍的回填器：已知某条跳转发射在新副本的哪个位置、以及它的新目标 pc，把相对偏移按该 opcode 的操作数宽度写回去。
- **实现**：`operand_off` 固定为 1（所有跳转的操作数都紧跟 opcode），`from = emit_pc + 1`，`diff64 = new_target - from`。随后按 opcode 宽度分三臂写回：`goto`/`if_true`/`if_false` 用 `i32`（4 字节小端），`goto16` 用 `i16`（2 字节），`goto8`/`if_true8`/`if_false8` 用 `i8`（1 字节，`@bitCast` 后直写）。每臂都先 `std.math.cast` 检查偏移放不放得下，放不下返回 null；不认识的 opcode 也返回 null。返回类型是 `?void`——null 即「回填失败，整次改写作废」。
- **所有权 / 错误 / 调用**：错误：无（返回 `?void`）；位移放不进目标宽度或 opcode 不是跳转就返回 null，重写整体作废。所有权：就地回填 `Rewrite.code` 里的跳转操作数，按 opcode 宽度写 i32/i16/i8。调用：本文件 `:953`（重写循环内）与 `:1119`（body 末尾跳到 after-body）。

### `collectSameCalleeConstructorPcs` (`src/exec/small_inline.zig:982`)

- **签名**：`fn collectSameCalleeConstructorPcs( caller: *const FunctionBytecode, trigger_pc: u32, trigger_obj: *Object, out: *[max_sites]u32, ) u8`。
- **作用**：在 caller 体里找出所有「应当与触发站点一起被展开」的 `new` 站点：同一个构造器对象、同样的实参数、且没有被标记为不可内联的那些，让一次特化把同族站点一并处理。
- **实现**：线性解码 caller 字节码，遇 `op.call_constructor` 时判定是否收录：正是触发 pc 则无条件收；否则要求指令长度 ≥3 以便读出两字节 `site_argc`，并与触发站点的 `trig_argc` 相等（触发指令长度不足 3 时退化成相等）；相等后再查 `CallerState.sites`，若该 pc 的槽标了 `never`、或它记录的 `callee_obj` 非空且不是 `trigger_obj`（说明观察到过别的 callee），就 `banned`，不收。收录时写进 `out` 并计数，上限 `max_sites`(16)。解码遇 size 为 0 或越界即 break。最后兜底：一个都没收到时，只要 `trigger_pc` 在范围内就至少放它进去（`n = 1`）。
- **所有权 / 错误 / 调用**：错误：无；扫描中遇到非法指令长度就 break，最坏只返回触发点自己。所有权：结果写进调用方栈上的 `out: *[max_sites]u32`，返回有效条数。调用：唯一调用方 `src/exec/small_inline.zig:1051`（`cloneAndExpand` 先收集同 callee、同 argc 的全部 `call_constructor` 站点）。

### `cloneAndExpand` (`src/exec/small_inline.zig:1033`)

- **签名**：`fn cloneAndExpand( rt: *JSRuntime, caller: *FunctionBytecode, callee: *FunctionBytecode, callee_fn_obj: *Object, call_pc: u32, kind: Kind, argc: u16, ) ?*FunctionBytecode`。
- **作用**：生成 caller 的专用字节码副本（小函数内联）。
- **实现**：收集同 callee 的 constructor 站点，为每站点分配 this+args+callee.locals 槽，把 callee 体 rewrite 进 caller 副本并打 pc_map。失败返回 null。
- **所有权 / 错误 / 调用**：错误：无；任何一步失败（站点为 0、超预算、重写失败、布局/分配失败）返回 null，调用方放弃特化。所有权：向 `rt` 申请一个新的 `FunctionBytecode`（含扩容后的 locals 与合并后的字节码），成功后 `rt.gc.addInitializedWithSizeNoFail(&spec.header, ...)` 把它交给 GC 管理，并把 `new_len` 记进 `rt.small_inline_specialized_bytes` 预算；返回的指针由调用方装进函数对象。调用：唯一调用方 `src/exec/small_inline.zig:404`（`specializeCallSite`）。

### `consumedArgSlots` (`src/exec/small_inline.zig:1326`)

- **签名**：`pub fn consumedArgSlots(fb: *const FunctionBytecode, site: *const InlinedSite) u16`。
- **作用**：算出一次展开在 caller 的 locals 窗口里要占掉几个实参槽——普通展开按 callee 声明的形参数，apply 转发形态则按站点记录的实际 argc。
- **实现**：`callerState(fb)` 可能为 null（状态已销毁），此时 `forwarded` 取 false。有状态则 `siteApplyForwarded(st, site)` 判断该站点是否做过 L1 转发改写。转发形态返回 `site.argc`（实参在改写后是逐个搬进槽的），否则返回 `site.callee_fb.arg_count`（按 callee 的形参表铺开）。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读——apply 转发站点按站点实参数 `site.argc` 计，普通站点按 callee 形参数 `callee_fb.arg_count` 计。调用：本文件 `:1338`（`windowFits`）与 `:1356`（`installInlineWindow`）。

### `windowFits` (`src/exec/small_inline.zig:1332`)

- **签名**：`pub fn windowFits(frame: *const frame_mod.Frame, fb: *const FunctionBytecode, site: *const InlinedSite) bool`。
- **作用**：在真正往 caller 的 locals 里写入内联窗口之前，核对这一帧的 locals 数组装得下站点要用的 this 槽与实参槽。
- **实现**：`arg_slots = consumedArgSlots(fb, site)`，`need = site.arg_base + arg_slots`；返回 `site.this_slot < frame.locals.len and need <= frame.locals.len`。两条分别管 this 槽下标合法与实参区上界不越界。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读比较，确认 `this_slot` 与 `arg_base + arg_slots` 都落在当前帧的 locals 窗口内。调用：`src/exec/tailcall_dispatch.zig:2716`、`:2790`（进内联站点前的最后一道边界检查）。

### `installInlineWindow` (`src/exec/small_inline.zig:1340`)

- **签名**：`pub fn installInlineWindow( frame: *frame_mod.Frame, fb: *const FunctionBytecode, site: *const InlinedSite, this_value: JSValue, args: []JSValue, ) void`。
- **作用**：把一次内联调用的 this 与实参搬进 caller 帧的 locals 窗口——展开后的 callee 体读的就是这些槽，不再有独立的帧。
- **实现**：`this_value` 直接写进 `locals[site.this_slot]`（下标越界则跳过这一步）。实参循环 `arg_slots = consumedArgSlots(fb, site)` 次：下标在 `args` 范围内时取走 `args[i]` 并把源槽写成 undefined（move 语义，所有权转给 locals 槽），超出则填 undefined 补齐声明形参；目标 `slot = site.arg_base + i` 同样做越界保护。注意这里逐槽做越界检查而不是先断言——`windowFits` 已经在调用前把关，这些检查是防御性的。
- **所有权 / 错误 / 调用**：错误：无；越界的槽静默跳过（由 `windowFits` 在前面保证）。所有权：move 语义——`this_value` 直接写进 `this_slot`，实参逐个从 `args[i]` 取走并把源槽写 undefined，缺的补 undefined；调用方之后不得再用那段 args。调用：`src/exec/tailcall_dispatch.zig:2721`（融合构造）与 `:2794`。

### `logicalInlineFrames` (`src/exec/small_inline.zig:1366`)

- **签名**：`pub fn logicalInlineFrames( fb: *const FunctionBytecode, pc: usize, out: *[max_depth]InlinedSite, ) []const InlinedSite`。
- **作用**：给定 caller 的一个 pc，把它对应的逻辑内联帧链（由内向外）展开出来——展开深度最多 D=2，这是 backtrace 能看见被内联掉的 callee 的依据。
- **实现**：`siteForPc(fb, pc)` 找不到包含该 pc 的站点就返回空切片。否则从最内层站点起沿 `site.parent` 往外走：每步把站点整体复制进 `chain`（按值，因为 `CallerState` 可能在使用期间被销毁），`parent == 0xFF` 表示到顶就停，`parent >= state.inlined_len` 说明记录不一致也停，深度到 `max_depth`(2) 同样停。最后把 `chain[0..n]` 抄进调用方给的 `out` 缓冲并返回它的切片。注释点明链本来就是由内向外的（起点就是最内层）。
- **所有权 / 错误 / 调用**：错误：无；pc 不在任何站点里返回空切片。所有权：按 `parent` 链从最内层往外收集站点副本（先写栈上 `chain`，再拷进调用方给的 `out` 缓冲，深度上限 `max_depth`），返回指向 `out` 的切片。调用：唯一调用方 `src/exec/inline_calls.zig:955`（`consumeInlineThenPhysical` 展开逻辑内联帧）。

### `inlinedSnapshot` (`src/exec/small_inline.zig:1390`)

- **签名**：`pub fn inlinedSnapshot(site: *const InlinedSite, expanded_pc: usize) core.ActiveBacktraceSnapshot`。
- **作用**：把一个内联站点合成成一帧 backtrace 快照，让被展开掉的 callee 在栈回溯里仍以自己的名字、文件和行列号出现。
- **实现**：字面量：`function_name`/`filename` 取站点记录的 `callee_name`/`callee_file` atom，`line_num`/`col_num` 取 callee FB 的函数头位置，`pc` 由 `mapCalleePc(site, expanded_pc)` 把展开后的 pc 翻回 callee 原始 pc，`location_data` 存 callee FB、`location_resolver` 装 `resolveCalleeLocation`（供按 pc 细化行列号的通道），`function_value` 填 undefined——内联掉的 callee 没有活的函数值可借。
- **所有权 / 错误 / 调用**：错误：无。所有权：快照按值返回；`callee_name`/`callee_file` 是站点持有的 atom（由 `traceCallerStateAtoms` 报给 tracer，不在这里 retain），`location_data` 借 callee 的 `FunctionBytecode`，`function_value` 置 undefined 表示没有可展示的函数对象。调用：唯一调用方 `src/exec/inline_calls.zig:957`。

### `resolveCalleeLocation` (`src/exec/small_inline.zig:1403`)

- **签名**：`fn resolveCalleeLocation(data: ?*const anyopaque, pc: usize) core.BacktraceLocation`。
- **作用**：backtrace 的位置解析回调：给出内联 callee 自身 FunctionBytecode 的行列号。
- **实现**：把 `?*const anyopaque` 还原成 `*const FunctionBytecode`（`data.?` 直接解包，安装时保证非空），`_ = pc` 忽略传入的 pc，返回 callee FB 的 `lineNum()`/`colNum()`。也就是说当前实现只给到函数头位置，不做 pc→行列的逐点解析。
- **所有权 / 错误 / 调用**：错误：无；`pc` 形参未用（内联站点的行列取 callee 函数头）。所有权：把 `?*const anyopaque` 还原成 `*const FunctionBytecode`（借用）。调用：不被直接调用，只作为 `location_resolver` 函数指针写进快照：`src/exec/small_inline.zig:1403`。

### `sampleCtorCache` (`src/exec/small_inline.zig:1418`)

- **签名**：`fn sampleCtorCache(func_obj: *Object) ?CtorCache`。
- **作用**：给一个构造器函数对象取一份「融合 new」要用的守卫快照：它当时的 shape、`prototype` 属性所在的槽号，以及那个 prototype 对象。
- **实现**：四道关，任一不过返回 null：`func_obj.hasExoticMethods()` 为真（有异常行为的对象，属性读不可预测）直接拒；`findProperty(core.atom.ids.prototype)` 找不到 `prototype` 拒；`asDataAt(index)` 拿不到数据属性值（访问器等）拒；`object_ops.objectFromValue(stored)` 不是对象拒。通过则返回 `{ shape = func_obj.shape_ref, proto, slot = index }`。记 shape 指针（R-v15-a）是关键：构造器对象上任何自有属性增删都会换 shape，从而让守卫失效。
- **所有权 / 错误 / 调用**：错误：无；exotic 方法、没有 `prototype` 自有数据属性、值不是对象都返回 null。所有权：采样出的 `shape`/`proto` 都是借用指针，仅作后续同一性比较用（不 retain），槽号 `slot` 用于快速重取。调用：唯一调用方 `src/exec/small_inline.zig:1283`（建构造器内联站点时）。

### `calleeMatches` (`src/exec/small_inline.zig:1431`)

- **签名**：`pub fn calleeMatches(site: *const InlinedSite, func: JSValue) bool`。
- **作用**：运行期的 take 守卫：核对这次实际拿到的 callee 值是不是当初做展开时记下的那个**函数对象**。
- **实现**：`object_ops.plainBytecodeFunctionObjectFromValue(func)` 取不到普通字节码函数对象就返回 false；否则与 `site.callee_obj` 比指针，`callee_obj` 为 null（没记）时保守返回 false。注释（R-v15-b）强调守卫比的是对象指针而不是 FunctionBytecode 身份——同一份 FB 可以被多个闭包对象共享，只有对象相同才能保证 capture 与 realm 也相同。
- **所有权 / 错误 / 调用**：错误：无。所有权：只比较对象同一性，站点没记 `callee_obj` 一律返回 false。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2789`。

### `realmFunctionApply` (`src/exec/small_inline.zig:1436`)

- **签名**：`fn realmFunctionApply(rt: *JSRuntime, global: *Object) ?*Object`。
- **作用**：取出某个 realm 的 `Function.prototype.apply` 属性当前指向的对象，供 L1 转发守卫核对它有没有被改写过。
- **实现**：`object_ops.functionPrototypeFromGlobal(rt, global)` 拿到该 realm 的 `Function.prototype`，再 `getOwnDataObjectBorrowed(core.atom.ids.apply)` 取其自有 `apply` 数据属性的对象值（借用，不 retain）；任一步为空返回 null。
- **所有权 / 错误 / 调用**：错误：无；取不到 `Function.prototype` 或它没有 `apply` 自有数据属性返回 null。所有权：`getOwnDataObjectBorrowed` 顾名思义返回借用对象指针。调用：本文件 `:1473`（`applyForwardGuardHolds`）与 `:1510`（`realmApplyBuiltin`）。

### `isFunctionApplyBuiltin` (`src/exec/small_inline.zig:1441`)

- **签名**：`fn isFunctionApplyBuiltin(obj: *const Object) bool`。
- **作用**：问某个对象是不是引擎内建的 `Function.prototype.apply` 本体——L1 改写把 `f.apply(...)` 换成了直接方法调用，只有 `apply` 未被脚本替换时这个等价才成立。
- **实现**：三项：`obj.class_id` 必须是 `c_function`（原生函数类）；`core.function.decodeNativeBuiltinId(obj.nativeFunctionId())` 能解出一个内建引用；该引用的 `domain == .function` 且 `id == @intFromEnum(function_ops.PrototypeMethod.apply)`。比的是内建身份编号，而不是指针相等，因此跨 realm 的同一内建也能认出来。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读——要求类是 `c_function`，且 `decodeNativeBuiltinId` 解出的 domain/id 恰是 `function_ops.PrototypeMethod.apply`，即该 realm 的 `apply` 还是原装内建。调用：本文件 `:1474` 与 `:1511`。

### `lookupProtoChainDataFunction` (`src/exec/small_inline.zig:1447`)

- **签名**：`fn lookupProtoChainDataFunction(start: *Object, atom_id: core.Atom) ?*Object`。
- **作用**：沿原型链找出某个名字第一次出现在哪个对象上，并取回它的数据属性值（必须是对象）——用于核对被 apply 转发的那个方法解析到的是不是当初记录的同一个函数。
- **实现**：从 `start` 起沿 `obj.getPrototype()` 逐级上行：`findProperty(atom_id)` 命中就 `asDataAt(idx)` 取值，取不到（访问器/空洞）直接返回 null——**不**继续往上找，因为「第一次命中」才是语义上的解析结果；取到后 `object_ops.objectFromValue` 转成对象指针返回。走完整条链没命中返回 null。
- **所有权 / 错误 / 调用**：错误：无；找到的属性不是数据属性或不是对象、或走到原型链尽头都返回 null。所有权：返回借用对象指针，不触发 getter（只看 `asDataAt`）。调用：唯一调用方 `src/exec/small_inline.zig:1476`。

### `applyForwardGuardHolds` (`src/exec/small_inline.zig:1461`)

- **签名**：`pub fn applyForwardGuardHolds( rt: *JSRuntime, global: *Object, ctor_obj: *Object, method_atom: core.Atom, ) bool`。
- **作用**：L1 转发改写的运行期总守卫：核对 `Function.prototype.apply` 还是原装内建、被转发的方法仍能从构造器的 prototype 链上解析到一个函数、且那个函数自己没有遮蔽 `apply`。
- **实现**：`method_atom` 为 null_atom 直接 false；`realmFunctionApply` 取到 realm 的 `Function.prototype.apply` 且 `isFunctionApplyBuiltin` 为真；构造器自身的 `prototype` 必须是对象；沿其原型链 `lookupProtoChainDataFunction` 找到的目标方法不得有自己的 `apply` 属性——全部满足才返回 true。
- **所有权 / 错误 / 调用**：错误：无，任一条件不成立返回 false。所有权：只读守卫——realm 的 `Function.prototype.apply` 仍是内建、构造器的 `prototype` 上能找到目标方法、且该方法自己没有 own `apply`；这几条是 apply 转发内联的去优化前提。调用：本文件 `:402`（安装时）与 `:1492`（`applyForwardTakeOk` 的运行时复查）。

### `applyForwardTakeOk` (`src/exec/small_inline.zig:1476`)

- **签名**：`pub inline fn applyForwardTakeOk( rt: *JSRuntime, global: *Object, fb: *const FunctionBytecode, site: *const InlinedSite, func: JSValue, ) bool`。
- **作用**：在真正走进某个展开站点之前问一句：如果这个站点做过 L1 转发改写，它的守卫现在还成立吗？没做过改写则直接放行。
- **实现**：`callerState(fb)` 为 null 时返回 true（没有状态就没有转发改写，无需守卫）。取该站点的冷记录，`call_pc == no_forward_pc` 说明这个站点没做转发，同样直接 true。做过转发的才真检查：`plainBytecodeFunctionObjectFromValue(func)` 取不到构造器对象返回 false，否则交给 `applyForwardGuardHolds(rt, global, ctor, fwd.method_atom)` 核对 `Function.prototype.apply` 与被转发方法是否仍是当初那两个对象。
- **所有权 / 错误 / 调用**：错误：无；没有 `CallerState` 或该站点不是转发站点一律放行（true）。所有权：只读；转发站点要把 callee 还原成函数对象再走 `applyForwardGuardHolds` 复查。调用：`src/exec/tailcall_dispatch.zig:2707`、`:2791`（进内联臂前的守卫）。

### `applyForwardSiteAfterCall` (`src/exec/small_inline.zig:1493`)

- **签名**：`pub fn applyForwardSiteAfterCall(fb: *const FunctionBytecode, pc_after: u32) ?*const InlinedSite`。
- **作用**：从「刚执行完一条指令后的 pc」反推出这次调用是不是某个 apply 转发站点，供调用后的续行逻辑定位站点记录。
- **实现**：先看 caller 的 `call_facts_mirror.execution.apply_forward_inlined` 标志，没置位说明本函数体里根本没有转发展开，返回 null（这是最常见的一条，放在最前）。取 `call_method_apply_fwd` 的指令长度，`pc_after` 小于它就不可能是这条指令，返回 null；否则 `call_pc = pc_after - insn_size`。用 `siteForPc(fb, call_pc)` 找到站点、`callerState` 取状态，最后核对该站点冷记录里的 `call_pc` 恰好等于算出来的 `call_pc` 才返回站点，否则 null。
- **所有权 / 错误 / 调用**：错误：无；函数没有 `apply_forward_inlined` 标志、pc 不足一条指令、站点对不上都返回 null。所有权：只读，返回借用的站点指针。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:761`。

### `realmApplyBuiltin` (`src/exec/small_inline.zig:1504`)

- **签名**：`pub fn realmApplyBuiltin(rt: *JSRuntime, global: *Object) ?*Object`。
- **作用**：取回某 realm 的 `Function.prototype.apply`，并确认它仍是引擎内建的那个实现（没被脚本替换成别的函数）。
- **实现**：两步：`realmFunctionApply(rt, global)` 取出当前挂在 `Function.prototype.apply` 上的对象，`isFunctionApplyBuiltin(apply_obj)` 核对它确实是内建 apply；任一不过返回 null。这是 L1 转发改写成立的前提之一——改写把 `f.apply(this, arguments)` 变成了直接的方法调用，只有在 `apply` 还是原装内建时才等价。
- **所有权 / 错误 / 调用**：错误：无；不是原装内建就返回 null。所有权：返回借用的 `apply` 内建函数对象。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:762`。

### `tryFusedConstructor` (`src/exec/small_inline.zig:1512`)

- **签名**：`pub fn tryFusedConstructor(rt: *JSRuntime, site: *const InlinedSite, func: JSValue) ?JSValue`。
- **作用**：融合 `new`：在守卫（同一构造器对象、同一 shape、同一 prototype）全部成立时，直接按缓存的 prototype 建出实例对象，省掉走一遍属性查找与通用 [[Construct]] 序言。
- **实现**：先过四道站点记录检查：`site.kind` 必须是 `.constructor`，`callee_obj`/`ctor_shape`/`proto` 三个守卫快照缺一返回 null。再过三道运行期核对：`plainBytecodeFunctionObjectFromValue(func)` 取到的对象必须等于 `expected_obj`；`obj.shape_ref` 必须等于 `expected_shape`（R-v15-a：比 shape 指针而不是只比缓存的槽号，这样构造器上任何自有属性增删都会让守卫失效）；按缓存槽 `site.proto_slot` 读出的 `prototype` 值转成对象后必须等于 `expected_proto`。全过才真的建实例：把 `proto` 与 `obj` 两个裸指针声明成 GC 根（`core.runtime.rootObjects(...)` + `activate`/`defer deactivate`），然后 `core.Object.createPlainObject(rt, proto_object)`，失败 `catch return null`，成功返回 `instance.value()`。注释（TGC R1）解释根声明的必要性：`createPlainObject` 会发布一个 Shape、经过分配前的收集边界、再分配对象 cell——三处都可能跑 minor GC，而此时 prototype 与构造器只作为本帧的 Zig 局部变量存在；生产的「只扫容器」策略会把这个 scope 擦掉，所以热臂没有变化，但精确根集需要这份声明（R3 第 2 项）。
- **所有权 / 错误 / 调用**：错误：无——站点类型、callee 对象、shape、proto 槽任一不匹配，或 `createPlainObject` OOM（`catch return null`）都返回 null，调用方回落到正常 construct。所有权：分配新实例前用 `core.runtime.rootObjects` 把 `proto_object`/`ctor_object` 登记成 GC 根并 `defer roots.deactivate`；新实例的所有权随返回的 `JSValue` 交给调用方。调用：唯一调用方 `src/exec/tailcall_dispatch.zig:2714`。
## 覆盖核对

- 清单函数数: 242（`src/exec/inline_calls.zig` 181 + `src/exec/small_inline.zig` 61）
- 本文标题覆盖: 242
- 未覆盖: 无
