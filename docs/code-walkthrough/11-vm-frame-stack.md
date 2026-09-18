# 11 — 帧与操作数栈（`frame.zig` / `stack.zig`）

`Frame` 拥有一次激活的调用绑定与窗口；`Stack` 拥有操作数前缀。同步帧从 `VmStackArena` 切 `[args | locals | operand | var-ref metadata]`；generator/async 用可转移驻留存储。活值靠收集器扫帧存储：`active_invocation_trace` 对 Frame 的 this/function/args/locals/var_refs 与 Stack 活前缀做精确 walk（`value_root_frames_enabled` 现在恒为真），生产里只有原生 Zig 标量局部仍留给保守扫描（`-Dzjs_gc_roots_diag` 才连它们一起登记）；push/pop 都不做 refcount。

## `frame.zig` 类型

`FrameSlab`：一次 backing 切出的 typed 窗口（`storage/args/original_args/locals/stack/var_refs/open_var_refs`）。

`CallBindingInputs`：`this` / `current_function` / `new_target`。

`Ownership`：`borrowed | owned`。`NewTargetBinding`：`borrowed | owned | aliases_function`。`OwnershipDisposition` 是 1 字节 packed。

`FrameStorageWindows`：把 slab 窗口可选地交给 `initArguments`/`initFrameLocals`。

`Frame`：热字段含 `function/pc/this_value/current_function/actual_arg_count/planned_stack_bytes/locals/args/var_refs/open_var_refs/storage_values/ownership/cold`。`FrameCold` 才有 `new_target` 与 `original_args`。

`actual_arg_count` 与 `planned_stack_bytes` 共享历史 usize 槽：pop 时用存好的 planned bytes 释放预算，Debug 与重算 lockstep。

## `stack.zig` 类型

`PendingCallRegion`：调用点把 `top_ptr` 退到 region 起点之后、尚未搬进 callee 帧的那一段操作数。`liveValues` 在 `top_ptr` 停住，conservative 扫也看不见这段；必须由 `traceMachine` 在「该 Stack 仍是活层且 top 仍停在 region 起点」时补扫。每 `Machine` 一格，不是 `Stack` 字段（Entry 钉死 256 字节），也不是 TLS。

`Stack`：`memory`（`*MemoryAccount`）+ `values/top_ptr/capacity` + `VmStackWindowPolicy`（62 位 limit 与 arena/resident 两个标志打包成一个字）。`values` 是 backing 基址、`top_ptr` 是活前缀的权威终点，都存裸指针以免每个 VM/冷 helper 缝都重建 slice。空栈两端是不可解引用的对齐哨兵地址。

## `src/exec/frame.zig` 函数

### `FrameSlab.requiredStorageSlots` (`src/exec/frame.zig:35`)

- **签名**：`pub fn requiredStorageSlots( arg_count: usize, original_arg_count: usize, local_count: usize, stack_count: usize, var_ref_count: usize, open_var_ref_count: usize, ) !usize`。
- **作用**：算出一帧全部窗口所需的 JSValue 槽数——四段值槽加上两段指针尾按 `@sizeOf(JSValue)` 向上取整的槽数。
- **实现**：用 `math.add/mul/divCeil` 算 JSValue 槽数：`args+original_args+locals+stack` 的值槽，加上 `var_refs`/`open_var_refs` 指针字节按 `@sizeOf(JSValue)` 向上取整出的槽数。任一步溢出返回 error。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 调用：`FrameSlab.allocHeap`，以及 `object_ops.zig` 预算嵌套帧 slab 时。

### `FrameSlab.partitionStorage` (`src/exec/frame.zig:56`)

- **签名**：`pub fn partitionStorage( storage: []JSValue, arg_count: usize, original_arg_count: usize, local_count: usize, stack_count: usize, var_ref_count: usize, open_var_ref_count: usize, ) FrameSlab`。
- **作用**：把调用方给的整块 backing 切成 FrameSlab 的六个 typed 窗口（backing 仍归调用方）。
- **实现**：先断言 `storage.len` 正好等于值槽 + 指针尾槽，再按 `[args | original_args | locals | stack | var_refs | open_var_refs]` 顺序切 typed 窗口（指针两段由 `sliceAsBytes`/`bytesAsSlice` 重解释）；open_var_refs `@memset(null)`。调用方仍拥有 backing，Frame 只释放窗口里的值/cell。
- **所有权 / 错误 / 调用**：错误：无（长度不符只在 Debug/Safe `assert`）。 调用：`FrameSlab.allocHeap`、`zjs_vm.initFreshEntryFrame` 切 generator 驻留 storage，以及 `object_ops.zig` 的预切帧。

### `FrameSlab.carve` (`src/exec/frame.zig:103`)

- **签名**：`pub fn carve( account: *memory.MemoryAccount, arena: *runtime.VmStackArena, arg_count: usize, original_arg_count: usize, local_count: usize, stack_count: usize, var_ref_count: usize, open_var_ref_count: usize, ) ?FrameSlab`。
- **作用**：从 `VmStackArena` 切出帧窗口；切不动返回 null。
- **实现**：按 `[args | original_args | locals | stack | var_refs 指针尾 | open_var_refs]` 从 arena 切一块；指针尾按 8 字节槽 reinterpret，对齐 qjs alloca 分区 quickjs.c:17834-17866。溢出返回 null 让调用方改 heap。
- **所有权 / 错误 / 调用**：错误：无（失败只 `assert` 或返回 null/false）。 同步帧优先 `VmStackArena` 切窗口，按 watermark 成批回收，不逐值挂 root。 调用：`zjs_vm.initFreshEntryFrame` 与 `inline_calls.zig` 的同机帧构造。

### `FrameSlab.allocHeap` (`src/exec/frame.zig:157`)

- **签名**：`pub fn allocHeap( account: *memory.MemoryAccount, arg_count: usize, original_arg_count: usize, local_count: usize, stack_count: usize, var_ref_count: usize, open_var_ref_count: usize, ) !FrameSlab`。
- **作用**：按所需槽数从 `MemoryAccount` 堆分配 backing，再切成与 `carve` 同形的窗口。
- **实现**：`requiredStorageSlots` 后 `account.alloc`；0 槽直接返回空 slab；`errdefer` free，最后用 `partitionStorage` 切成同样的窗口。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 分配：`MemoryAccount`；整块 backing 由 Frame 的 `installOwnedStorage` 接手，`deinit`/`releaseOwnedStorage` 才 free。 调用：`zjs_vm.initFreshEntryFrame`（arena 切不动或没有 arena 时）与 `inline_calls.zig` 的同机帧构造。

### `argumentsNeedsOriginalSnapshot` (`src/exec/frame.zig:219`)

- **签名**：`pub fn argumentsNeedsOriginalSnapshot(function: *const bytecode.FunctionBytecode) bool`。
- **作用**：unmapped arguments / derived ctor / strict 才需要 `original_args` 快照。
- **实现**：四个条件任一为真即需要快照：`isDerivedClassConstructor()`、`isStrictMode()`、`runtimeStrictMode()`、`!hasSimpleParameterList()`。sloppy + 简单形参用 mapped arguments 直接读活 `frame.args`，省掉复制。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `FunctionBytecode` 的四个形状位。调用：`src/exec/zjs_vm.zig:610`、`src/exec/object_ops.zig:2037`，以及 `src/exec/inline_calls.zig:3127`、`:4028`、`:4367`（建帧前算是否要 `original_args`）。

### `frameArgCount` (`src/exec/frame.zig:226`)

- **签名**：`pub fn frameArgCount(function: *const bytecode.FunctionBytecode, argc: usize) usize`。
- **作用**：`max(argc, function.arg_count)`，不足的形参槽补 undefined。
- **实现**：单表达式 `@max(argc, function.arg_count)`：实参多于形参时帧的实参窗口按实参数开（多出来的槽 `arguments` 仍要能看见），实参少于形参时按形参数开、尾部由建帧方填 undefined。`arg_count` 是 u16，这里 `@intCast` 成 usize 后比较。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯算术。调用：`src/exec/zjs_vm.zig:614`、`src/exec/object_ops.zig:2036`、`src/exec/inline_calls.zig:3126`、`:4045`、`:4364`。

### `originalArgCount` (`src/exec/frame.zig:230`)

- **签名**：`pub fn originalArgCount(argc: usize, need_original_snapshot: bool) usize`。
- **作用**：需要快照且 argc≠0 时等于 argc，否则 0。
- **实现**：`return if (argc != 0 and need_original_snapshot) argc else 0`：两个条件都成立才需要在 slab 上多切一段快照区。argc 为 0 时即使需要快照也不用切（空快照就是空切片），所以补上这条短路。
- **所有权 / 错误 / 调用**：错误：无。所有权：纯算术。调用：`src/exec/zjs_vm.zig:636`/`:649`/`:658`/`:670` 四条入口建帧路径、`src/exec/object_ops.zig:2038`，以及 `src/exec/inline_calls.zig:3150`、`:3159`、`:4026`、`:4365` 的 slab 预算计算。

### `frameVarRefStorageCount` (`src/exec/frame.zig:234`)

- **签名**：`pub fn frameVarRefStorageCount(function: *const bytecode.FunctionBytecode, inherited_var_refs: []const *core.VarRef) usize`。
- **作用**：继承 captures、否则 closureVar、否则 varRefNames 长度。
- **实现**：三级回退，先命中先返回：调用方传进来的 `inherited_var_refs` 非空就用它的长度（闭包已经把 capture 数组给全了）；否则看 `function.closureVar().len`（编译期记录的闭包变量表）；都为 0 才退到 `function.varRefNamesLen()`（只有名字表的情形）。
- **所有权 / 错误 / 调用**：错误：无。所有权：只算槽数，不碰 `VarRef`——继承的 captures 由 callable 拥有，新建的 var-ref cell 在帧初始化时才分配。调用：`src/exec/object_ops.zig:2039`、`src/exec/zjs_vm.zig:639`/`:652`/`:661`/`:673`、`src/exec/inline_calls.zig:3144`。

### `frameOpenVarRefStorageCount` (`src/exec/frame.zig:240`)

- **签名**：`pub fn frameOpenVarRefStorageCount(function: *const bytecode.FunctionBytecode) usize`。
- **作用**：`function.openVarRefCount()`。
- **实现**：单行转发 `function.openVarRefCount()`。留这层包装是为了给建帧侧一个与 `frameArgCount`/`frameVarRefStorageCount` 同形的名字，并把「open var-ref 槽数的权威来源是 FB 而不是帧上的切片」这条约定钉在一个位置（`deinitSimpleResources` 的 R-A1 注释正是依赖它）。
- **所有权 / 错误 / 调用**：错误：无。所有权：转发 `function.openVarRefCount()`，是「这帧有多少个可能逃逸、需要 `closeOpenVarRefs` 收尾的槽」的权威计数。调用：10 处，如 `src/exec/zjs_vm.zig:618`、`src/exec/object_ops.zig:2040`、`src/exec/inline_calls.zig:1774`、`:3145`、`:4048`。

### `Frame.ensureCold` (`src/exec/frame.zig:292`)

- **签名**：`pub fn ensureCold(self: *Frame, account: *memory.MemoryAccount) !*FrameCold`。
- **作用**：第一次用到 new.target/original_args 时分配 `FrameCold`。
- **实现**：`self.cold` 已有就直接返回；否则 `account.create(FrameCold)` 分配，用 `c.* = .{}` 把两个字段置成默认（`new_target` 为 undefined、`original_args` 为空切片），挂到 `self.cold` 并返回。分配失败沿 error union 上抛。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 分配：`MemoryAccount`；对应 `free`/`destroy` 在 deinit/errdefer。 调用：本文件内部——`initCallBindings`、`takeConstructorNewTarget`、`initOriginalArgsSnapshot`。

### `Frame.freeCold` (`src/exec/frame.zig:301`)

- **签名**：`pub fn freeCold(self: *Frame, account: *memory.MemoryAccount) void`。
- **作用**：清 new_target 所有权并 destroy 冷盒。
- **实现**：`self.cold` 为 null 直接返回。否则先把 `ownership.new_target` 复位成 `.borrowed`——盒子没了就不能再声称拥有里面那个 `new.target`——再 `account.destroy(FrameCold, c)` 归还，最后 `self.cold = null`。
- **所有权 / 错误 / 调用**：错误：无（失败只 `assert` 或返回 null/false）。 调用：本文件内部——`Frame.deinit` 与 `Frame.deinitInlineCall`。

### `Frame.releaseColdStorage` (`src/exec/frame.zig:309`)

- **签名**：`pub fn releaseColdStorage(self: *Frame) void`。
- **作用**：丢掉 original_args 窗口但保留冷盒。
- **实现**：`self.cold` 为 null 直接返回，否则把 `c.original_args` 置成空切片。盒子本身保留（`new_target` 可能还活着），只切断那条指向即将被释放的 backing 的快照切片。
- **所有权 / 错误 / 调用**：错误：无（失败只 `assert` 或返回 null/false）。 调用：本文件内部——`Frame.releaseOwnedStorage`，在 free backing 之前清掉指向它的快照。

### `Frame.newTargetValue` (`src/exec/frame.zig:318`)

- **签名**：`pub inline fn newTargetValue(self: *const Frame) JSValue`。
- **作用**：`aliases_function` 时就是 `current_function`，否则读冷盒或 undefined。
- **实现**：两臂：`ownership.new_target == .aliases_function` 时直接返回热字段 `current_function`——`new F()` 的常见情形里 `new.target` 就是被调用的构造器本身，于是不必为它分配冷盒；否则有冷盒就读 `c.new_target`，没有则返回 undefined（普通函数调用没有 `new.target`）。注释强调返回值是 BORROWED，与 `current_function` 一样：每个读者要么只测试它，要么把它交给会自行 dup 的 callee（对齐 qjs `OP_special_object NEW_TARGET` 在 push 处 dup，quickjs.c:17984）。
- **所有权 / 错误 / 调用**：错误：无。所有权：`aliases_function` 时直接复用热字段 `current_function`（省一次 cold 分配），否则从 `FrameCold` 读；返回借用的 `JSValue`。调用：`src/exec/vm_call.zig:868`、`:926`、`:943`，`src/exec/vm_literal.zig:449`（`specialObject` 的 subtype 3 臂，即 `OP_special_object NEW_TARGET`），`src/exec/eval_ops.zig:535`。

### `Frame.takeConstructorNewTarget` (`src/exec/frame.zig:328`)

- **签名**：`pub fn takeConstructorNewTarget(self: *Frame, account: *memory.MemoryAccount, value: JSValue) !void`。
- **作用**：spread/`super()` 转发的 new.target：与 current_function 相同则保持 alias，否则写入冷盒。
- **实现**：先断言当前绑定是 `.aliases_function`（构造 push 建立的别名）；`value.same(current_function)` 就直接返回、丢掉冗余引用；否则 `ensureCold` 后写 `cold.new_target` 并把绑定改成 `.owned`。
- **所有权 / 错误 / 调用**：错误：error union（`ensureCold` 的 OOM）。 调用：`inline_calls.Machine` 处理构造 spread / `super()` 转发的两处。

### `Frame.originalArgs` (`src/exec/frame.zig:336`)

- **签名**：`pub inline fn originalArgs(self: *const Frame) []JSValue`。
- **作用**：冷盒里的调用参数快照，没有则空切片。
- **实现**：`return if (self.cold) |c| c.original_args else &.{}`：没有冷盒就意味着这帧不需要原始实参快照（sloppy + 简单形参用 mapped arguments 直接读活的 `frame.args`），返回空切片。
- **所有权 / 错误 / 调用**：错误：无；没有 cold 就返回空切片。所有权：返回借用窗口，存储归 `FrameCold.original_args`（随帧 slab 一起回收）。调用：`src/exec/vm_call.zig:938`、`src/exec/object_ops.zig:2314`-`:2315`，以及本文件 `:777`、`:791` 的存储重叠断言。

### `Frame.init` (`src/exec/frame.zig:340`)

- **签名**：`pub inline fn init(function: *const bytecode.FunctionBytecode) Frame`。
- **作用**：建一个只绑定了 `FunctionBytecode` 的空 Frame 壳，留给后续的参数/绑定安装步骤去填。
- **实现**：函数体只有 `return .{ .function = function };`：locals / args / var_refs / open_var_refs / storage_values 全部停在类型默认的空切片，`ownership.storage` 为 borrowed，`this_value` / `current_function` 为 undefined，`cold` 为 null。真正的窗口由 `initArguments` 分配、调用绑定由 `initCallBindings` 写入。
- **所有权 / 错误 / 调用**：所有权：此刻不持有任何存储，因此一个只 `init` 过的 Frame 无需 `deinit`。 错误：无。 调用：生产路径只有两处——`zjs_vm.zig:467` 的入口帧（非驻留壳的那一臂）与 `inline_calls.zig:3081`（`setupInlineEntry` 通用 push 的帧重建）；`vm_value.zig:590`/`:669`/`:711` 与 `frame.zig:684` 都是本仓单测夹具。

### `Frame.initResidentExecution` (`src/exec/frame.zig:348`)

- **签名**：`pub inline fn initResidentExecution( function: *const bytecode.FunctionBytecode, this_value: JSValue, current_function: JSValue, actual_arg_count: usize, ) Frame`。
- **作用**：为 resume generator/async 造借用式调用绑定壳（this/cur_func 由 execution record 拥有）。
- **实现**：只填 function/this/current_function/actual_arg_count；不分配 new.target，不做 refcount。resume generator 用的借用壳。
- **所有权 / 错误 / 调用**：错误：无。所有权：只填四个热字段，storage/args/locals 全留空——驻留执行的窗口由 `GeneratorExecutionState` 另行提供。调用：唯一调用方 `src/exec/zjs_vm.zig:461`。

### `Frame.isEmptyResidentExecutionShell` (`src/exec/frame.zig:366`)

- **签名**：`pub inline fn isEmptyResidentExecutionShell(self: *const Frame) bool`。
- **作用**：挂起后窗口已搬回 execution record，临时 Frame 无拆除工作。
- **实现**：七个条件全真才算空壳：`ownership.storage == .borrowed`，且 `storage_values` / `locals` / `args` / `var_refs` / `open_var_refs` 全为空，且 `cold == null`。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读七个字段，确认这确实是「借用 storage 且各窗口皆空」的驻留外壳。调用：唯一调用方 `src/exec/zjs_vm.zig:481`——出口 `defer` 里判断是否要跳过 `frame_storage.deinit`（空壳则不拆）。

### `Frame.initCallBindings` (`src/exec/frame.zig:376`)

- **签名**：`pub fn initCallBindings(self: *Frame, rt: *JSRuntime, inputs: CallBindingInputs) !void`。
- **作用**：写入 this/current_function；new.target 非 undefined 才 ensureCold。
- **实现**：先按 `inputs.new_target_value.isUndefined()` 决定要不要 `ensureCold(&rt.memory)`（分配放在写任何绑定之前，失败时帧还没被改过），再写 `this_value` / `current_function`，最后把 new_target 存进冷盒。
- **所有权 / 错误 / 调用**：错误：error union——只有 `new_target` 非 undefined 时才 `ensureCold` 分配 `FrameCold`，OOM 由此上抛。所有权：`this`/`current_function` 存热字段（借用值），`new_target` 存 cold；cold 块归帧所有，随 `deinit` 释放。调用：唯一调用方 `src/exec/zjs_vm.zig:528`。

### `Frame.initArguments` (`src/exec/frame.zig:386`)

- **签名**：`pub fn initArguments( self: *Frame, account: *memory.MemoryAccount, arena: ?*runtime.VmStackArena, args: []const JSValue, use_inline_storage: bool, need_original_snapshot: bool, windows: FrameStorageWindows, ) !void`。
- **作用**：按 argc 填 args（不足补 undefined）并按需快照 original_args。
- **实现**：先记 `actual_arg_count = args.len`；`frame_arg_count = max(args.len, function.arg_count)`，非 0 则 `allocArgsSlice` 拿窗口，超出实参的尾槽 `@memset(undefined)`，再逐个复制实参并挂到 `self.args`；最后 `initOriginalArgsSnapshot` 按需做快照。
- **所有权 / 错误 / 调用**：错误：error union，来自 `allocArgsSlice` 与 `initOriginalArgsSnapshot` 的分配。所有权：实参窗口优先用 `windows.args` 给的预切窗口、其次 arena、最后堆（`allocOwnedStorage`，记为帧自有）；多出的形参槽 `@memset` 成 undefined，实参逐个复制进来——源 `args` 仍归调用方。调用：唯一调用方 `src/exec/zjs_vm.zig:690`。

### `Frame.initArgumentsMoved` (`src/exec/frame.zig:413`)

- **签名**：`pub fn initArgumentsMoved( self: *Frame, account: *memory.MemoryAccount, arena: ?*runtime.VmStackArena, args: []JSValue, use_inline_storage: bool, need_original_snapshot: bool, windows: FrameStorageWindows, ) !void`。
- **作用**：尾调用复用：把已有槽 move 进帧，源槽写成 undefined。
- **实现**：同 `initArguments` 算 `frame_arg_count`，`allocArgsSlice` 后补 undefined 尾槽、`@memcpy` 实参、再把源 `args` 整段 `@memset(undefined)`（值的所有权转移，不做 refcount）；需要快照时用**已搬进帧的** `self.args[0..args.len]` 做 `initOriginalArgsSnapshot`。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 源切片的 backing 仍归调用方，帧只接管其中的值。 调用：唯一调用方 `inline_calls.setupInlineEntry`（`:3189`），即 `canBorrowSourceArgs` 为假（需要补形参槽，或源槽已标记 moved）的那一臂。

### `Frame.initArgumentsBorrowedSlots` (`src/exec/frame.zig:441`)

- **签名**：`pub fn initArgumentsBorrowedSlots( self: *Frame, account: *memory.MemoryAccount, args: []JSValue, use_inline_storage: bool, need_original_snapshot: bool, windows: FrameStorageWindows, ) !void`。
- **作用**：栈上 JS→JS 且无需补参：直接借用 argv 切片（qjs `arg_buf = argv`）。
- **实现**：记 `actual_arg_count`，断言 `args.len >= function.arg_count`（借用前提：不需要补形参槽），需要时先做 original-args 快照，最后把 `self.args` 直接指向调用方的槽。源 backing 必须活到帧拆除；帧释放值但不释放 backing。
- **所有权 / 错误 / 调用**：错误：error union，由直接调用方处理。 调用：唯一调用方 `inline_calls.setupInlineEntry`（`:3180`），即 `canBorrowSourceArgs` 为真（argc ≥ `arg_count` 且源槽未 moved）的那一臂。

### `Frame.allocArgsSlice` (`src/exec/frame.zig:457`)

- **签名**：`fn allocArgsSlice( self: *Frame, account: *memory.MemoryAccount, arena: ?*runtime.VmStackArena, frame_arg_count: usize, use_inline_storage: bool, window: ?[]JSValue, ) ![]JSValue`。
- **作用**：优先用预切窗口/arena，否则 `allocOwnedStorage`。
- **实现**：给了 `window` 就断言长度相符后直接用；否则有 arena 就 `arena.carve`；都不成才 `allocOwnedStorage` 拿自有 heap 段。`use_inline_storage` 参数当前被 `_ =` 忽略。
- **所有权 / 错误 / 调用**：错误：error union，来自 `allocOwnedStorage`。所有权：三级回退——调用方给了窗口就直接用（断言长度相符，所有权仍在调用方）；否则试 `VmStackArena.carve`（成批回收）；都不行才 `allocOwnedStorage` 让帧自己持有并在 deinit 释放。`use_inline_storage` 形参当前被丢弃（`_ =`）。调用：本文件 `:399`（`initArguments`）与 `:425`。

### `Frame.initOriginalArgsSnapshot` (`src/exec/frame.zig:476`)

- **签名**：`fn initOriginalArgsSnapshot( self: *Frame, account: *memory.MemoryAccount, args: []const JSValue, use_inline_storage: bool, need_original_snapshot: bool, window: ?[]JSValue, ) !void`。
- **作用**：先 ensureCold 再复制；分配失败不得动源槽。
- **实现**：`args` 为空或不需要快照就直接返回；否则先 `ensureCold`（先立好析构 owner，再复制引用），窗口给了就断言长度相符、没给就 `allocOwnedStorage`，逐个复制后写 `cold.original_args`。`use_inline_storage` 被忽略。
- **所有权 / 错误 / 调用**：错误：error union，来自 `ensureCold` 与快照窗口的分配。所有权：`args.len == 0` 或不需要快照时直接返回；否则先 `ensureCold` 再把 `original_args` 存进 `FrameCold`（优先用预切窗口，否则帧自有存储），内容是调用前实参的副本。调用：本文件三处——`initArguments`（`src/exec/frame.zig:405`）、`initArgumentsMoved`（`:432`，传已搬进帧的 `self.args`）、`initArgumentsBorrowedSlots`（`:452`，传借用前的源槽）。

### `Frame.installOwnedStorage` (`src/exec/frame.zig:500`)

- **签名**：`pub fn installOwnedStorage(self: *Frame, storage: []JSValue) void`。
- **作用**：挂上自有 backing 并标 `ownership.storage=.owned`。
- **实现**：断言当前还是 `.borrowed`，写 `storage_values`；只有 `storage.len != 0` 才标成 `.owned`（空切片保持 `.borrowed`）。
- **所有权 / 错误 / 调用**：错误：无（`assert` 要求此前 storage 还是 borrowed）。所有权：这一步把整块 backing 的释放义务转给 Frame——只有非空切片才置 `.owned`，`deinit`/`releaseOwnedStorage` 据此 `account.free`。调用：本文件 `:520`（`allocOwnedStorage`）、`src/exec/inline_calls.zig:3165`，以及 `src/exec/zjs_vm.zig:664`、`:676`（arena 切不动改堆时）。

### `Frame.installResidentStorage` (`src/exec/frame.zig:506`)

- **签名**：`pub fn installResidentStorage(self: *Frame, storage: []JSValue) void`。
- **作用**：挂上驻留 backing，所有权仍 borrowed。
- **实现**：断言当前是 `.borrowed`，只写 `storage_values`，不改 `ownership.storage`——backing 归 `GeneratorExecutionState` 或预切它的调用方。
- **所有权 / 错误 / 调用**：错误：无（同样 `assert` 前置 borrowed）。所有权：与 `installOwnedStorage` 相反——只记下窗口指针、**不**改 `ownership.storage`，因为驻留 storage 归 `GeneratorExecutionState`，帧 pop 时不得释放。调用：`src/exec/zjs_vm.zig:630`、`:642`。

### `Frame.allocOwnedStorage` (`src/exec/frame.zig:511`)

- **签名**：`pub fn allocOwnedStorage(self: *Frame, account: *memory.MemoryAccount, count: usize) ![]JSValue`。
- **作用**：heap 分配并 install；已有 owned 存储则拒绝以免泄漏第二块。
- **实现**：先 `account.alloc(JSValue, count)` 分配。随后一道防重检查：如果本帧已经持有一块自有 storage（`ownership.storage == .owned` 且 `storage_values.len != 0`），就把刚分配的这块 `free` 掉并返回 `error.OutOfMemory`——注释说明不接收预切窗口的动态增长路径本来就罕见，与其悄悄泄漏第二块 backing，不如把所有权规则摆明。检查通过才 `installOwnedStorage(values)` 装上并返回切片。
- **所有权 / 错误 / 调用**：错误：`error.OutOfMemory`——分配成功但发现帧已经持有一块 owned storage 时，会把刚拿到的内存 free 掉再返回 OOM（防止泄漏旧块）。所有权：分配自 `MemoryAccount`，随即 `installOwnedStorage` 把释放义务记到帧上。调用：`src/exec/vm_call.zig:278`、`:389`，本文件 `:473`（实参窗口）、`:494`（original_args 快照）、`:661`（open var-ref 槽）。

### `Frame.deinit` (`src/exec/frame.zig:524`)

- **签名**：`pub fn deinit(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void`。
- **作用**：通用（非内联调用）路径上的 Frame 拆除：把两个调用绑定写回 undefined，再归还自有存储与冷盒。
- **实现**：把 `this_value` / `current_function` 写回 undefined，`releaseOwnedStorage`（关 open cell、清窗口、清 `original_args`、free owned backing），最后 `freeCold` 销毁冷盒。
- **所有权 / 错误 / 调用**：所有权：释放本 Frame 自有的存储切片（`ownership.storage == .owned` 时）与冷盒，并关闭仍开着的 var-ref cell；借用的窗口不动。 错误：无。 调用：`zjs_vm.zig:482` 入口帧出口的 `defer`（驻留空壳除外）、`inline_calls.zig:3082` 通用 push 中途失败的 `errdefer`，以及 `frame.zig:685` 本文件单测的 `defer`；内联调用帧的常规拆除走的是 `deinitInlineCall`，不是这里。

### `Frame.deinitInlineCall` (`src/exec/frame.zig:534`)

- **签名**：`pub inline fn deinitInlineCall(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void`。
- **作用**：同机返回热路径：关 open var-ref、freeCold、owned storage free。
- **实现**：三条带守卫的动作，顺序固定：`open_var_refs.len != 0` 时 `closeOpenVarRefs(rt)` 把逃逸变量搬进堆 cell；`cold != null` 时 `freeCold(account)` 释放冷盒；`ownership.storage == .owned and storage_values.len != 0` 时 `account.free(JSValue, storage_values)` 归还自有 slab。arena 借用的窗口不在这里还——那是 Entry 侧 `vm_stack.restore(arena_mark)` 的事。
- **所有权 / 错误 / 调用**：错误：无。所有权：内联调用帧的三步收尾——先 `closeOpenVarRefs` 把逃逸绑定搬进堆 cell，再 `freeCold` 释放 `FrameCold`，最后只有 storage 真是 `.owned` 且非空才 `account.free`（arena 窗口留给 watermark 回滚）。调用：`src/exec/inline_calls.zig:808`（`deinitConstructorReturned` 的非 simple 臂）与 `:823`（`deinitGeneralResources`）。

### `Frame.releaseOwnedStorage` (`src/exec/frame.zig:540`)

- **签名**：`pub fn releaseOwnedStorage(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void`。
- **作用**：关 open var-ref、清空窗口、free owned backing。
- **实现**：先 `closeOpenVarRefs`，记下 `storage_values` 与其 ownership，然后把 locals/args/var_refs/open_var_refs/storage_values 全清空、`ownership.var_refs` 复位成 `.owned`、`ownership.storage` 复位成 `.borrowed`；有冷盒就 `releaseColdStorage` 丢掉指向该 backing 的 `original_args`（保留冷盒与其 new-target 绑定）；最后只有原来是 `.owned` 且非空才 `account.free`。
- **所有权 / 错误 / 调用**：错误：无。所有权：比 `deinitInlineCall` 更彻底——先关 open var-ref，再把 locals/args/var_refs/open_var_refs/storage 全部清成空切片并把 `ownership.storage` 退回 `.borrowed`（便于帧被复用），cold 走 `releaseColdStorage`，最后才 free 取下来的旧 owned 块。调用：`src/exec/vm_call.zig:268` 的 `errdefer`（storage 未转移时回滚）与本文件 `:530`。

### `Frame.closeOpenVarRefs` (`src/exec/frame.zig:560`)

- **签名**：`pub fn closeOpenVarRefs(self: *Frame, rt: anytype) void`。
- **作用**：把 open 表交给 `open_bindings.Table.closeAll`。
- **实现**：把 `self.open_var_refs` 这段槽包成 `open_bindings_mod.Table{ .cells = ... }`，调它的 `closeAll(rt)`。真正的关闭语义（把仍被闭包引用的槽提升成堆 cell、其余置空）在 open-bindings 模块里，`Frame` 这边只负责提供槽窗口。`rt` 形参声明成 `anytype`，因此 frame.zig 在类型上不依赖 runtime 模块。
- **所有权 / 错误 / 调用**：错误：无。所有权：把 `open_var_refs` 包成 `open_bindings.Table` 后 `closeAll(rt)`——逃逸的绑定被提升成堆 `VarRef` cell（所有权转给闭包），槽本身仍归帧窗口。调用：本文件 `:535`、`:541`，以及 `src/exec/inline_calls.zig:742`、`:757`、`:805` 三处 simple teardown。

### `Frame.captureLocal` (`src/exec/frame.zig:570`)

- **签名**：`pub fn captureLocal(self: *Frame, rt: anytype, local_idx: usize) !*core.VarRef`。
- **作用**：为某个 local 槽建或复用 open `VarRef`（qjs get_var_ref；参数槽走 `captureArg`）。
- **实现**：对齐 qjs `get_var_ref`（quickjs.c:16997-17039）：断言 `local_idx` 在 `locals`/`varDefs()` 范围内，Debug/Safe 下若该槽已是 cell 则 `error.InvalidBytecode`；用 `localOpenBindingIndex(local_idx).?` 取 open 槽号，越出窗口返回 `error.InvalidBytecode`；已有 cell 就（Debug/Safe 校验 `is_open` 与 `pvalue == &locals[i]` 后）复用，否则 `VarRef.createOpen(rt, &locals[local_idx])` 并按 varDef 抄 `is_const`/`is_lexical`/`is_function_name`，登记回 open 槽。
- **所有权 / 错误 / 调用**：错误：error union；新 cell 登记在帧的 open 表里，由 `closeOpenVarRefs` 关闭。 调用：同 `captureArg`（`object_ops.zig` / `vm_property_ref.zig` / `eval_ops.zig`）。

### `Frame.captureArg` (`src/exec/frame.zig:598`)

- **签名**：`pub fn captureArg(self: *Frame, rt: anytype, arg_idx: usize) !*core.VarRef`。
- **作用**：为参数槽建/复用 open VarRef，对齐 get_var_ref。
- **实现**：与 `captureLocal` 同形：断言 `arg_idx < args.len`，Debug/Safe 下若该槽已是 cell 则 `error.InvalidBytecode`；用 `argOpenBindingIndex(arg_idx).?` 定位 open 槽，越出窗口返回 `error.InvalidBytecode`；已有 cell 就（Debug/Safe 校验 `is_open` 与 `pvalue` 指向 `args[i]` 后）复用，否则 `VarRef.createOpen(rt, &args[arg_idx])` 并登记。参数 cell 不带 const/lexical 标志。
- **所有权 / 错误 / 调用**：错误：error union；cell 归 open 表，`closeOpenVarRefs` 统一收口。 调用：闭包 capture 填充与 mapped-arguments 构造（`object_ops.zig`）、`make_var_ref` 一类引用 opcode（`vm_property_ref.zig`）、直接 eval 的外层帧捕获（`eval_ops.zig`）。

### `Frame.closeLocalBinding` (`src/exec/frame.zig:619`)

- **签名**：`pub fn closeLocalBinding(self: *Frame, rt: anytype, local_idx: usize) !void`。
- **作用**：按 local 的 open binding index 关闭对应 cell。
- **实现**：`local_idx` 越出 `locals` 或 `varDefs()` 即 `error.InvalidBytecode`；该 local 没有 open binding index 则什么都不做直接返回；否则把 `open_var_refs` 包成 `open_bindings.Table` 调 `close(rt, binding_idx)`。
- **所有权 / 错误 / 调用**：错误：`error.InvalidBytecode`（局部索引越界）或 `Table.close` 的错误；局部没有对应 open binding 时直接返回。所有权：关闭单个绑定，把值搬进堆 cell。调用：`src/exec/vm_property_locals.zig:111` 与 `:271`（`close_loc` 语义的两处）。

### `Frame.closeParameterEnvironmentVarRefs` (`src/exec/frame.zig:628`)

- **签名**：`pub fn closeParameterEnvironmentVarRefs(self: *Frame, rt: anytype) !void`。
- **作用**：generator 体边界关闭参数环境别名，保留指向驻留 args 的别名。
- **实现**：把 `open_var_refs` 包成 `open_bindings.Table`，遍历 `function.varDefs()`，跳过未被捕获的，其余按 `vd.var_ref_idx` 逐个 `table.close(rt, ...)`。只关 varDef 侧（局部/参数环境别名），指向驻留 args backing 的别名不在这张表里。
- **所有权 / 错误 / 调用**：错误：error union。 调用：`vm_gen_async.zig` 在 generator 尚未 started 时于函数体边界调用一次。

### `Frame.installOpenVarRefSlots` (`src/exec/frame.zig:636`)

- **签名**：`pub fn installOpenVarRefSlots(self: *Frame, slots: []?*core.VarRef) !void`。
- **作用**：安装预切 open 窗口并 memset null。
- **实现**：`slots.len` 与 `function.openVarRefCount()` 不等即 `error.InvalidBytecode`；否则挂上窗口并整段 `@memset(null)`。
- **所有权 / 错误 / 调用**：错误：`error.InvalidBytecode`——传入槽数与 `function.openVarRefCount()` 不符即拒绝。所有权：槽窗口由调用方（arena 预切或 slab 分区）提供，帧只借用；`@memset(null)` 保证收集器看到的是确定值。调用：`src/exec/zjs_vm.zig:691` 与 `src/exec/inline_calls.zig:3202`。

### `Frame.ensureOpenVarRefSlots` (`src/exec/frame.zig:642`)

- **签名**：`pub fn ensureOpenVarRefSlots( self: *Frame, account: *memory.MemoryAccount, arena: ?*runtime.VmStackArena, use_inline_storage: bool, ) !void`。
- **作用**：没有窗口则 arena/heap 切 `?*VarRef` 槽。
- **实现**：已有窗口时长度必须等于 `openVarRefCount()`，否则 `error.InvalidBytecode`（相等则直接返回）；`count == 0` 直接返回；否则优先 `arena.carveTyped(?*VarRef, count)`，失败就按字节数算 JSValue 槽走 `allocOwnedStorage` 再 `bytesAsSlice` 重解释；最后 `@memset(null)` 并挂上。`use_inline_storage` 被忽略。
- **所有权 / 错误 / 调用**：错误：`error.InvalidBytecode`（已装的槽数不符）或分配/算术溢出错误。所有权：已有槽就复用；否则优先 `VmStackArena.carveTyped`（借用、成批回收），失败才按字节数折算成 `JSValue` 槽从 `allocOwnedStorage` 要（帧自有，deinit 释放）；两条路都 `@memset(null)`。调用：`src/exec/zjs_vm.zig:691` 一线与 `src/exec/inline_calls.zig:3204`。

### `Frame.setLocal` (`src/exec/frame.zig:668`)

- **签名**：`pub fn setLocal(self: *Frame, account: *memory.MemoryAccount, index: usize, value: JSValue) !void`。
- **作用**：必要时 `growLocalsCapacity` 后写入。
- **实现**：两行：`growLocalsCapacity(account, self, index)` 先保证 `locals` 长到能容纳 `index`（可能触发分配，失败沿 error union 上抛），随后 `self.locals[index] = value`。这条路径只服务于需要动态扩 locals 的冷场景，正常建帧时 locals 窗口在 slab 上一次切好。
- **所有权 / 错误 / 调用**：错误：error union（`growLocalsCapacity` 的 OOM / `InvalidBytecode`）。 调用：生产代码里没有调用方；只有 frame.zig 自带的 "Frame setLocal preserves inline locals while growing" 这类合成/夹具用例走它。

### `ensureVarRefsCapacity` (`src/exec/frame.zig:697`)

- **签名**：`pub fn ensureVarRefsCapacity(ctx: *core.JSContext, frame: *Frame, idx: usize) !void`。
- **作用**：合成字节码稀疏增长 var_refs；与其它窗口共享的 owned slab 拒绝增长。
- **实现**：`idx` 已在范围内直接返回。若当前 owned slab 不止装着 var_refs（`!ownedStorageContainsOnlyVarRefs`）就拒绝增长，返回 `error.InvalidBytecode`——共享 slab 上换掉一段会让其它窗口悬空。否则按 `next_len` 个指针槽算出 JSValue 槽数、`alloc`（`errdefer` free）、`bytesAsSlice` 成新 `[]*VarRef`，拷回旧 cell，空位用 `VarRef.createClosed(undefined)` 填满（槽契约是「每槽都是活 cell」），再改写 `var_refs`/`storage_values`/两个 ownership，最后释放旧 owned storage。
- **所有权 / 错误 / 调用**：错误：error union。 分配：`ctx.runtime.memory`；新 backing 记在 `storage_values` 上，由 Frame 析构释放。 调用：闭包 capture 填充（`object_ops.zig:418`）、`call_runtime.zig:3154`/`:3283` 的 var-ref 路径、`vm_property_ref.zig:170`（`make_var_ref_ref`），以及 `slot_ops.zig:134`/`:203`/`:265` 三处 var-ref 读写前的按需扩容——都只在合成/legacy 字节码的稀疏索引下才真正增长。

### `growLocalsCapacity` (`src/exec/frame.zig:743`)

- **签名**：`fn growLocalsCapacity(account: *memory.MemoryAccount, frame: *Frame, idx: usize) !void`。
- **作用**：仅在尚无 open cell 时允许扩 locals（地址必须对 open 稳定）。
- **实现**：`idx` 已在范围内直接返回。owned slab 若不止装着 locals（`!ownedStorageContainsOnlyLocals`）就 `error.InvalidBytecode`；再用 `open_bindings.Table.hasOpen()` 检查——已经有 open cell 就不许搬 locals（cell 的 `pvalue` 指着旧地址），同样 `error.InvalidBytecode`，而且这道检查排在分配之前。然后 `alloc`（`errdefer` free）、拷旧值、尾部填 undefined，改写 `locals`/`storage_values`/ownership，最后释放旧 owned storage。
- **所有权 / 错误 / 调用**：错误：error union。 分配：`MemoryAccount`；新 backing 即 `storage_values`。 调用：只有 `Frame.setLocal`（合成/夹具帧）。

### `ownedStorageContainsOnlyLocals` (`src/exec/frame.zig:771`)

- **签名**：`fn ownedStorageContainsOnlyLocals(frame: *const Frame) bool`。
- **作用**：owned backing 是否就是 locals 这一段。
- **实现**：storage 或 locals 为空、起址不同、长度不等都返回 false；再用 `sliceOverlapsStorage` 确认 args / `originalArgs()` / var_refs / open_var_refs 都不落在这块 storage 里，全不重叠才为 true。
- **所有权 / 错误 / 调用**：错误：无。所有权：判定谓词——旧 owned 块是否**只**装着 locals（指针与长度都和 `frame.locals` 重合，且 args/original_args/var_refs/open_var_refs 都不落在这块里），据此决定换窗口时能否安全 free 旧块。调用：唯一调用方 `src/exec/frame.zig:748`。

### `ownedStorageContainsOnlyVarRefs` (`src/exec/frame.zig:782`)

- **签名**：`fn ownedStorageContainsOnlyVarRefs(frame: *const Frame) bool`。
- **作用**：owned backing 是否就是 var_refs 指针尾。
- **实现**：storage 或 var_refs 为空、起址不同都返回 false；storage 槽数必须正好等于指针字节数向上取整出的 JSValue 槽数；再用 `sliceOverlapsStorage` 确认 locals / args / `originalArgs()` / open_var_refs 都不在这块里。
- **所有权 / 错误 / 调用**：错误：无（算术溢出用 `catch return false` 保守处理）。所有权：与上一条对称——旧 owned 块是否只装着 `var_refs` 指针数组（长度按指针字节折算成值槽比对）。调用：唯一调用方 `src/exec/frame.zig:707`。

### `sliceOverlapsStorage` (`src/exec/frame.zig:795`)

- **签名**：`fn sliceOverlapsStorage(comptime T: type, values: []const T, storage: []const JSValue) bool`。
- **作用**：两段是否字节重叠。
- **实现**：任一段为空返回 false；字节数或末地址算溢出时保守返回 true（当作重叠）；否则做 `value_start < storage_end and storage_start < value_end` 的半开区间相交判断。
- **所有权 / 错误 / 调用**：错误：无；任何长度算术溢出都 `catch return true`（保守地报「重叠」，宁可不 free）。所有权：纯地址区间比较 `[start, end)`，不解引用。调用：本文件 `:776`-`:779` 与 `:789`-`:792` 两个谓词的八次调用。
## `src/exec/stack.zig` 函数

### `PendingCallRegion.windowFor` (`src/exec/stack.zig:45`)

- **签名**：`pub inline fn windowFor(self: *const PendingCallRegion, owner: *const Stack) []JSValue`。
- **作用**：若 pending 仍属于该 Stack 且 top 停在 region 起点，返回那一段活窗口。
- **实现**：`pending.stack` 不是这个 owner、或 `len == 0`、或 `owner.top_ptr != pending.values` 三者任一成立就返回空切片（top 一动窗口即失效）；否则 Debug/Safe 断言窗口落在 backing 容量内后返回 `values[0..len]`。
- **所有权 / 错误 / 调用**：错误：无。 调用：`active_invocation_trace.traceStack`（精确根 walk 里判定 pending 窗口是否还活）。

### `Stack.init` (`src/exec/stack.zig:71`)

- **签名**：`pub fn init(account: *memory.MemoryAccount, limit: usize) Stack`。
- **作用**：造一条还没有 backing 的操作数栈：只记住 MemoryAccount 与栈上限，第一次 reserve/push 才真正分配。
- **实现**：`values` 与 `top_ptr` 都设成 `emptyPtr()` 哨兵、`capacity` 取默认 0、`policy = Policy.forLimit(limit)`（两个 window 标志默认关）。不分配任何 backing，首次 push/reserve 才长出来。
- **所有权 / 错误 / 调用**：所有权：只借用 `MemoryAccount`；backing 在首次 `reserveAdditional` 时由该账户分配，由 `deinit` 归还。 错误：无。 调用：`root.zig:86`/`93` 的嵌入门面、`eval_entry.zig:254` 的顶层执行栈、`call.zig:2518` / `function_ops.zig:516` / `eval_ops.zig:475` 等处的 nested_stack，以及 `host_invocation.zig:90` 上限为 0 的 idle 栈。

### `Stack.initArenaWindow` (`src/exec/stack.zig:81`)

- **签名**：`pub fn initArenaWindow(account: *memory.MemoryAccount, policy: Policy, window: []JSValue) Stack`。
- **作用**：借用已切好的 arena 窗口作操作数栈。
- **实现**：断言传入 policy 是 `arena_window and !resident_window`，然后 `values` / `top_ptr` 都指向窗口起点、`capacity = window.len`，backing 不归自己所有。
- **所有权 / 错误 / 调用**：错误：无（`assert` 要求 policy 确实是 arena 窗口且非驻留）。所有权：Stack 只借这段 arena 窗口——`values`/`top_ptr` 都指向窗口起点，`capacity` 是窗口长度；释放靠 Entry pop 时的 `vm_stack.restore(arena_mark)`，`Stack.deinit` 遇到 arena 窗口只清活槽、不 free backing。调用：`src/exec/inline_calls.zig` 里 15 处建帧点（如 `:1294` lean、`:2135`、`:3175`），外加 `src/exec/zjs_vm.zig:687` 入口帧与 `src/exec/call_runtime.zig:3712`。

### `Stack.emptyPtr` (`src/exec/stack.zig:92`)

- **签名**：`inline fn emptyPtr() [*]JSValue`。
- **作用**：空 Stack 两端用不可解引用的对齐哨兵地址。
- **实现**：`return @ptrFromInt(@alignOf(JSValue))`——用 `JSValue` 的对齐值当地址。注释说明动机：Zig 的切片指针不能为 null，所以空 Stack 的 `values` 与 `top_ptr` 用这个既对齐又不可解引用的地址当哨兵，`len()` 算出来自然是 0。
- **所有权 / 错误 / 调用**：错误：无（失败只 `assert` 或返回 null/false）。 调用：本文件内部——`Stack.init` 与 `clearBacking`（`deinit` 经 `clearBacking`）。

### `Stack.stackLimit` (`src/exec/stack.zig:98`)

- **签名**：`pub inline fn stackLimit(self: *const Stack) usize`。
- **作用**：从 packed policy 取出槽上限。
- **实现**：`@intCast(self.policy.limit)`。`policy` 是把 62 位的槽上限与两个 backing 归属标志打包进一个字的 packed struct——注释说明 62 位上限远超任何可寻址的 JSValue 缓冲，而这么排省掉了布尔字段原本带来的六字节尾填充。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `policy.limit`（62 位打包字段）。调用：`src/exec/vm_gen_async.zig:47`、`:48`、`:55`（挂起栈扩容前的上限核算）；其余同名命中是 `JSContext.stackLimit`。

### `Stack.isArenaWindow` (`src/exec/stack.zig:102`)

- **签名**：`pub inline fn isArenaWindow(self: *const Stack) bool`。
- **作用**：backing 是否借自 arena。
- **实现**：读 `self.policy.arena_window` 这一位。为真表示 backing 是 VM 栈 arena 上切出来的窗口，`deinit` 不得 free 它，回收靠 arena 水位回滚。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读 `policy.arena_window` 位。调用：`src/exec/inline_calls.zig:597`（`canUseSimpleTeardown`）与 `:668`/`:697`/`:719` 三处叶 teardown 断言，以及 `src/exec/vm_gen_async.zig:205`、`:301` 的反向断言。

### `Stack.setArenaWindow` (`src/exec/stack.zig:106`)

- **签名**：`pub inline fn setArenaWindow(self: *Stack, value: bool) void`。
- **作用**：改 arena 标志。
- **实现**：写 `self.policy.arena_window = value` 一位。与 `resident_window` 相互独立——两者都为假时 backing 才是本 Stack 自有、需要 `free` 的堆块。
- **所有权 / 错误 / 调用**：错误：无。所有权：只改策略位——挂起 generator 时要把栈从「arena 窗口」改判为独立 backing，免得 watermark 回滚踩到它。调用：`src/exec/vm_gen_async.zig:73`、`:252`、`:292`。

### `Stack.setResidentWindow` (`src/exec/stack.zig:110`)

- **签名**：`pub inline fn setResidentWindow(self: *Stack, value: bool) void`。
- **作用**：改 resident 标志。
- **实现**：写 `self.policy.resident_window = value` 一位。resident 窗口表示 backing 由常驻结构（如挂起的 generator）retain 着，`deinit` 同样不得释放。
- **所有权 / 错误 / 调用**：错误：无。所有权：只改策略位，标记 backing 是可转移的驻留存储（由 `GeneratorExecutionState` 持有）。调用：`src/exec/vm_gen_async.zig:74`、`:253`、`:293`。

### `Stack.topPtr` (`src/exec/stack.zig:114`)

- **签名**：`pub inline fn topPtr(self: *const Stack) [*]JSValue`。
- **作用**：权威活前缀终点。
- **实现**：直接返回 `self.top_ptr` 字段。`values` 与 `top_ptr` 都以裸指针形式保存（而不是维护一个切片长度），是为了让 VM 与各冷 helper 的每个接缝都不必重建切片。
- **所有权 / 错误 / 调用**：错误：无。所有权：返回裸的活前缀终点指针，是分发循环里 `sp` 的权威来源；调用方不得越过 `capacity`。调用：`src/exec/tailcall_dispatch.zig` 里 22 处（如 `:563`、`:595` 的尾调用传参，`:1408`、`:1610` 的断言），以及 `inline_calls.zig` 里 14 处 region 计算。

### `Stack.len` (`src/exec/stack.zig:118`)

- **签名**：`pub inline fn len(self: *const Stack) usize`。
- **作用**：由 top-base 算出的活槽数。
- **实现**：`(@intFromPtr(self.top_ptr) - @intFromPtr(self.values)) / @sizeOf(JSValue)`：长度不是存储字段，每次由两个指针相减算出，因此 `top_ptr` 是活前缀终点的唯一真相。
- **所有权 / 错误 / 调用**：错误：无。所有权：只读——用 `top_ptr` 与 `values` 的地址差除以 `@sizeOf(JSValue)` 算活前缀长度。调用：`src/exec/` 下约 103 处操作数栈深度检查（如 `src/exec/iterator_ops.zig:310`、`:370`）；`src/core/` 里的同名命中属别的容器。

### `Stack.retreatToCallRegionFrom` (`src/exec/stack.zig:136`)

- **签名**：`pub inline fn retreatToCallRegionFrom(self: *Stack, pending: *PendingCallRegion, live_top: [*]JSValue, region_start: [*]JSValue) void`。
- **作用**：在跨入 callee 建帧之前把操作数顶后撤到调用区起点，同时把撤下来的那几个槽（callee、可选 receiver、实参）登记成这次在途调用的 `PendingCallRegion`，好让 GC 在这段「已不在活前缀里、又还没进帧」的窗口期仍能看见它们。
- **实现**：`setTopPtr(region_start)`；若 `live_top` 仍在其上方，把那段记进 `PendingCallRegion`，否则 len=0。resident 分发可能只推进寄存器 sp，所以必须传 live_top，不能只信 `self.top_ptr`。
- **所有权 / 错误 / 调用**：错误：无。所有权：把栈顶退回 `region_start`，并把退掉的这段值登记进 `Machine.pending_call_region`（`stack`/`values`/`len` 三字段）——这段值 `liveValues` 已经看不见，必须靠 `traceMachine` 补扫，否则收集器会漏掉待搬运的实参。调用：本文件 `:154`（`retreatToCallRegion`）与 `src/exec/tailcall_dispatch.zig:908`、`:1263`、`:1999`、`:2181`、`:2355`、`:4795`。

### `Stack.retreatToCallRegion` (`src/exec/stack.zig:153`)

- **签名**：`pub inline fn retreatToCallRegion(self: *Stack, pending: *PendingCallRegion, region_start: [*]JSValue) void`。
- **作用**：`retreatToCallRegionFrom` 的 `top_ptr` 拼写。
- **实现**：一行 `self.retreatToCallRegionFrom(pending, self.top_ptr, region_start)`：把 `live_top` 取成当前 `self.top_ptr`。这个拼写留给那些操作数顶确实已经发布到 `top_ptr` 的调用点；寄存器驻留的分发臂必须走带 `live_top` 参数的版本，否则 `live_top <= region_start` 的守卫会每次都命中、窗口永远发布不出去。
- **所有权 / 错误 / 调用**：错误：无。所有权：等价于 `retreatToCallRegionFrom(pending, self.top_ptr, region_start)`，即活顶就是当前 `top_ptr`。调用：`src/exec/tailcall_dispatch.zig:2558`、`:2599`、`:2674`、`:2832`、`:5879`（构造/方法调用的建 region 点）。

### `Stack.liveValues` (`src/exec/stack.zig:157`)

- **签名**：`pub inline fn liveValues(self: *const Stack) []JSValue`。
- **作用**：`values[0..len]`。
- **实现**：`self.values[0..self.len()]`——活前缀切片，即这条栈当前拥有其中 JSValue 的那一段。GC 的精确遍历与 `deinit` 的清槽都只看这一段。
- **所有权 / 错误 / 调用**：错误：无。所有权：返回借用切片 `values[0..len()]`；注意它不含 `pending_call_region` 那段。调用：`src/exec/active_invocation_trace.zig:103`（精确根扫描）、`src/exec/vm_gen_async.zig:130`/`:163`、`src/exec/vm_control.zig:39`、`src/exec/function_ops.zig:547`，以及本文件 `:200`、`:283`。

### `Stack.backingValues` (`src/exec/stack.zig:161`)

- **签名**：`pub inline fn backingValues(self: *const Stack) []JSValue`。
- **作用**：`values[0..capacity]`。
- **实现**：`self.values[0..self.capacity]`——整块 backing 切片（含 `top_ptr` 之上尚未使用或已被弹出的容量）。只用于把内存还给分配器，不代表所有权。
- **所有权 / 错误 / 调用**：错误：无（失败只 `assert` 或返回 null/false）。 调用：本文件内部——`Stack.deinit` 与 `reserveCapacityUpTo` 取旧 backing 用。

### `Stack.setLen` (`src/exec/stack.zig:165`)

- **签名**：`pub inline fn setLen(self: *Stack, new_len: usize) void`。
- **作用**：按槽数改 top。
- **实现**：断言 `new_len <= capacity`，再把 `top_ptr` 置成 `values + new_len`。
- **所有权 / 错误 / 调用**：错误：无（`assert(new_len <= capacity)`）。所有权：直接把 `top_ptr` 设成 `values + new_len`——截断时被丢弃的槽不做任何释放（VM 值不计引用计数）。调用：`src/exec/` 下 29 处，如 `src/exec/vm_call.zig:731`/`:736`、`src/exec/tailcall_dispatch.zig:1338`。

### `Stack.setTopPtr` (`src/exec/stack.zig:173`)

- **签名**：`pub inline fn setTopPtr(self: *Stack, new_top: [*]JSValue) void`。
- **作用**：一 store 发布新 top；pending 生命期改由读者判断。
- **实现**：Debug/Safe 下断言新 top 不低于 base、不越过 `capacity`、且与 base 的字节差是 `@sizeOf(JSValue)` 的整数倍，然后一条 store 写 `top_ptr`。这里不再做 pending-region 探测（旧 threadlocal 写法的开销就在这条路径上）。
- **所有权 / 错误 / 调用**：错误：无；三条 `assert` 校验新顶不低于基址、不超容量、且按 `JSValue` 对齐。所有权：同 `setLen`，只移动活前缀终点。调用：44 处，主要在 `src/exec/tailcall_dispatch.zig`（如 `:242`、`:586`、`:842`）与本文件 `:137`。

### `Stack.installBacking` (`src/exec/stack.zig:184`)

- **签名**：`pub inline fn installBacking(self: *Stack, live_values: []JSValue, backing_capacity: usize) void`。
- **作用**：generator 所有权移交：装上已有活前缀与 capacity。
- **实现**：断言 `live_values.len <= backing_capacity`，把 `values` 指向 `live_values.ptr`、`top_ptr` 指到其末尾、`capacity` 记成 backing 容量。只在 generator 的所有权移交缝用。
- **所有权 / 错误 / 调用**：错误：无（`assert` 活值不超过新 backing 容量）。所有权：把 Stack 指向别处的 backing（挂起 generator 的驻留存储），Stack 自身不接管释放义务——释放归 `SuspendedStackStorage`。调用：`src/exec/vm_gen_async.zig:251`、`:291`（resume 时装回驻留栈）。

### `Stack.clearBacking` (`src/exec/stack.zig:192`)

- **签名**：`pub inline fn clearBacking(self: *Stack) void`。
- **作用**：丢掉借用视图，两端回到哨兵。
- **实现**：三行：`values` 与 `top_ptr` 都指回 `emptyPtr()` 哨兵，`capacity = 0`。不 free 也不清槽——所有权已经移交别处（generator 挂起）或由调用方另行处置，这里只是让本 Stack 松手。
- **所有权 / 错误 / 调用**：错误：无。所有权：把 `values`/`top_ptr` 指向不可解引用的对齐哨兵、容量清零，切断与原 backing 的关系（所有权已转移给挂起状态），避免误 free。调用：`src/exec/vm_gen_async.zig:72` 与本文件 `:205`。

### `Stack.deinit` (`src/exec/stack.zig:199`)

- **签名**：`pub inline fn deinit(self: *Stack, _: anytype) void`。
- **作用**：拆掉一条操作数栈：把活前缀的槽位清成 undefined，并且只在 backing 确实由本 Stack 自己分配（既不是 arena 窗口也不是 resident 窗口）时才归还内存。
- **实现**：先取好活前缀与 backing 两个切片及两个 window 标志，`clearBacking` 把视图置回哨兵并清掉两个标志，再把活前缀逐槽写成 undefined，最后仅当 `capacity != 0` 且既非 arena 也非 resident 窗口时 `memory.free` backing。`rt` 参数被忽略。
- **所有权 / 错误 / 调用**：所有权：只释放本 Stack 自己分配的 backing；arena 窗口与 resident 窗口的内存归 `VmStackArena` / 驻留机所有，这里只解除视图。`rt` 形参被忽略，保留只为与其它 deinit 同签名。 错误：无。 调用：各 nested_stack 的 `defer`（`call.zig:2519`、`eval_ops.zig:476`、`promise_ops.zig:2649`、`function_ops.zig:517`、`module.zig:688`/`:715`、`call_runtime.zig` 多处）、`eval_entry.zig:255`、`host_invocation.destroy`（`:127`）、`Vm.deinit`（`root.zig:106`），以及 `inline_calls.zig:807`/`:822`/`:3176` 的 Entry 非 simple teardown。

### `Stack.push` (`src/exec/stack.zig:214`)

- **签名**：`pub fn push(self: *Stack, value: JSValue) !void`。
- **作用**：reserve 1 后写入并推进 top。
- **实现**：三行：`reserveAdditional(1)` 先确保有一格（可能扩容或撞 `stackLimit` 报 `error.StackOverflow`），然后 `top_ptr[0] = value` 写入、`top_ptr += 1` 推进。
- **所有权 / 错误 / 调用**：错误：`error.OutOfMemory`/超限——`reserveAdditional(1)` 在需要扩容时向 `MemoryAccount` 要或撞 `stackLimit`。所有权：按「借用值」语义压栈（当前实现与 `pushOwned` 同构，因为 VM 值不计引用计数）。调用：`src/exec/` 下约 40 处，如 `src/exec/vm_property_locals.zig:126`、`src/exec/iterator_ops.zig:86`、`src/exec/object_ops.zig:3908`；`gc.zig` 等处的 `push` 是别的容器。

### `Stack.pushOwned` (`src/exec/stack.zig:220`)

- **签名**：`pub fn pushOwned(self: *Stack, value: JSValue) !void`。
- **作用**：与 `push` 相同（所有权语义由调用方保证）。
- **实现**：与 `push` 逐字相同（`reserveAdditional(1)` → 写 `top_ptr[0]` → `top_ptr += 1`）。之所以并存两个名字，是因为 VM 值不计引用计数，所有权只是调用侧的约定，用不同的函数名把这个约定记录在调用点上。
- **所有权 / 错误 / 调用**：错误：同 `push`，来自 `reserveAdditional`。所有权：语义上压入一个「已归栈所有」的新值（如刚算出的结果），实现与 `push` 相同。调用：`src/exec/vm_arith.zig:71`、`:111`、`:138` 等算术结果回压点，以及 `src/exec/iterator_ops.zig:81`、`:91` 等，共 70 余处。

### `Stack.pushAssumeCapacity` (`src/exec/stack.zig:226`)

- **签名**：`pub fn pushAssumeCapacity(self: *Stack, value: JSValue) void`。
- **作用**：已保证容量时写入。
- **实现**：断言 `len() < capacity`，写 `top_ptr[0]` 后 `top_ptr += 1`；没有 reserve、没有 limit 检查。
- **所有权 / 错误 / 调用**：错误：无（溢出只在 Debug/Safe 被 assert 抓）。 调用：帧入口已 `reserveFrameCapacity` 过的 VM 内核路径。

### `Stack.pushOwnedAssumeCapacity` (`src/exec/stack.zig:232`)

- **签名**：`pub fn pushOwnedAssumeCapacity(self: *Stack, value: JSValue) void`。
- **作用**：已保证容量的 owned 写入。
- **实现**：与 `pushAssumeCapacity` 逐字相同（断言 `len() < capacity` 后写入并推进 top）；名字只标记调用方交出的是自有引用。
- **所有权 / 错误 / 调用**：错误：无——`assert(len() < capacity)` 要求调用方（建帧时按 `stack_size + 1` 预留）已保证容量。所有权：同 `pushOwned`，但省掉扩容检查，是热路径版本。调用：`src/exec/` 下 142 处，如 `src/exec/iterator_ops.zig:421`、`src/exec/inline_calls.zig:5086`、`:5092`（返回值回压）。

### `Stack.pop` (`src/exec/stack.zig:238`)

- **签名**：`pub fn pop(self: *Stack) !JSValue`。
- **作用**：弹出一层。
- **实现**：`top_ptr == values` 表示空栈，返回 `error.StackUnderflow`；否则 `top_ptr -= 1` 再读 `top_ptr[0]` 返回。刻意**不**把弹出的槽写成 undefined——值的所有权随返回值移交调用方，而该槽位于活前缀之上，下一次 push 会覆盖它。
- **所有权 / 错误 / 调用**：错误：`error.StackUnderflow`（空栈）。所有权：值交给调用方，槽不清空——`top_ptr` 退一格即可，收集器只看活前缀。调用：`src/exec/` 下约 189 处操作数出栈，如 `src/exec/vm_property_field.zig:67`、`:238`；`src/core/` 的同名命中属别的容器。

### `Stack.peek` (`src/exec/stack.zig:244`)

- **签名**：`pub fn peek(self: Stack) ?JSValue`。
- **作用**：看栈顶，空则 null。
- **实现**：`top_ptr == values` 返回 null，否则读 `(top_ptr - 1)[0]`。不改 `top_ptr`，值仍归栈所有。注意形参是 `self: Stack`（按值），所以这是一个纯读访问器。
- **所有权 / 错误 / 调用**：错误：无；空栈返回 null（调用方通常翻成 `error.StackUnderflow`）。所有权：返回栈顶值的副本，槽仍在栈上。调用：`src/exec/` 下 11 处，如 `src/exec/object_ops.zig:4279`、`src/exec/vm_literal.zig:216`（`json_ops.zig` 里的同名命中是 JSON 解析自己的栈）。

### `Stack.peekBorrowed` (`src/exec/stack.zig:249`)

- **签名**：`pub fn peekBorrowed(self: Stack) ?JSValue`。
- **作用**：同 peek（借用语义）。
- **实现**：与 `peek` 逐字相同：空栈返回 null，否则返回 `(top_ptr - 1)[0]`。名字上的 `Borrowed` 只是提醒调用方不得把这个值当成额外一份所有权转交出去。
- **所有权 / 错误 / 调用**：错误：无；空栈返回 null。所有权：与 `peek` 实现相同，命名上强调返回值是借用的——调用方不得把它当作额外一份所有权交出去。调用：`src/exec/vm_literal.zig:149`、`src/exec/iterator_ops.zig:343`、`src/exec/vm_call.zig:890`、`src/exec/vm_value.zig:272`、`src/exec/slot_ops.zig:71`、`:118`。

### `Stack.reserveAdditional` (`src/exec/stack.zig:254`)

- **签名**：`pub fn reserveAdditional(self: *Stack, additional: usize) !void`。
- **作用**：检查 limit 后 `reserveCapacityUpTo`。
- **实现**：先算 `live_len = len()` 与 `stack_limit = stackLimit()`。溢出判断写成 `live_len > stack_limit or additional > stack_limit - live_len`——用减法而不是 `live_len + additional > stack_limit`，避免加法本身溢出；命中返回 `error.StackOverflow`。通过后 `reserveCapacityUpTo(live_len + additional, stack_limit)` 去实际扩容（倍增，上限夹到 `stack_limit`）。
- **所有权 / 错误 / 调用**：错误：`error.StackOverflow`（`live_len + additional` 超过 `policy.limit`）或 `reserveCapacityUpTo` 的分配错误。所有权：本身不分配，扩容与旧 backing 的释放都在 `reserveCapacityUpTo` 里。调用：`src/exec/` 下 31 处压栈前预留，如 `src/exec/iterator_ops.zig:281`、`:537`。

### `Stack.reserveFrameCapacity` (`src/exec/stack.zig:262`)

- **签名**：`pub fn reserveFrameCapacity(self: *Stack, frame_stack_size: usize) !void`。
- **作用**：为整帧 stack_size+1 预留。
- **实现**：`frame_stack_size > stackLimit()` 直接 `error.StackOverflow`；否则 `reserveCapacityUpTo(frame_stack_size + 1, frame_stack_size + 1)`——两个参数相同，意思是「恰好扩到这个帧声明需要的容量，一格不多」。容量取 `frame_stack_size + 1`，与建帧路径里 `function.stack_size + 1` 的口径一致。
- **所有权 / 错误 / 调用**：错误：`error.StackOverflow`（帧要的槽数就超过上限）或分配错误。所有权：按 `frame_stack_size + 1` 精确预留（多出的 1 槽是 qjs 同款的余量），不做 2 倍增长。调用：唯一调用方 `src/exec/zjs_vm.zig:803`（入口帧建栈）。

### `Stack.reserveCapacityUpTo` (`src/exec/stack.zig:267`)

- **签名**：`fn reserveCapacityUpTo(self: *Stack, needed: usize, max_capacity: usize) !void`。
- **作用**：倍增 heap 缓冲；从 arena/resident 长出则变成自有 heap。
- **实现**：`needed <= capacity` 直接返回。否则从 8（或当前容量）起倍增，超过 `max_capacity` 就钉在 `max_capacity`；封顶后仍不够则 `error.StackOverflow`。接着 alloc 新缓冲（`errdefer` free）、memcpy 活前缀、改写 `values/top_ptr/capacity`、清掉 arena/resident 两个标志，最后只有旧 backing 是自有 heap（capacity≠0 且两标志都假）才 free——从 arena/resident 窗口长出来的旧窗口不释放。
- **所有权 / 错误 / 调用**：错误：`error.StackOverflow`（翻倍到 `max_capacity` 仍不够）或 `memory.alloc` 的 OOM（带 `errdefer free`）。所有权：新 backing 从 `MemoryAccount` 分配，活值 `@memcpy` 过去；关键在于旧块**只有**在它既不是 arena 窗口也不是驻留窗口时才 `free`（那两种 backing 归 arena/generator 所有），同时把两个 policy 位清掉，表示这块栈从此自持。调用：本文件 `:259`（`reserveAdditional`）与 `:264`（`reserveFrameCapacity`）。
## 覆盖核对

- 清单函数数: 72（`src/exec/frame.zig` 43 + `src/exec/stack.zig` 29）
- 本文标题覆盖: 72
- 未覆盖: 无
