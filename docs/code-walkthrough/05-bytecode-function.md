# 05 — FunctionBytecode 运行时载体

GC 对象，VM 真正跑的东西。镜像 `JSFunctionBytecode`（quickjs.c:768-804），但 zjs 的 GC 头是 8 字节 `TraceHeader`，所以 **核心 `extern struct` 是 88 字节**（`@sizeOf == 88`，align 8）。源码注释里的「96 字节」指 QuickJS 在 16 字节 `JSGCObjectHeader` 下的同一张核心表；zjs 用 `@sizeOf(FunctionBytecodeImpl)` 算偏移，不插入 padding。

## 布局（W1c5 packed FAM）

`FunctionLayout` 是唯一检查过的权威。从对象基址起，**QuickJS 分配顺序、核心段零 padding**：

```
[ FunctionBytecodeImpl          88 B   核心头（GC header + flags + 指针/计数 + RealmRef） ]
[ DebugInfo                     32 B   可选，has_debug；inline，不是独立盒 ]
[ JSValue × cpool_count                常量池 ]
[ BytecodeVarDef × (arg+var)           参数在前、局部在后的连续表 ]
[ ClosureVar × closure_var_count       8 字节/行，与 qjs JSClosureVar 同布局 ]
[ u8 × byte_code_len                   精确最终码，无对齐填充 ]
[ FunctionBytecodeHotExtension  64 B   可选，has_extension；hot_off == code_end，*align(1) ]
[ padding to 8 ]
[ CallSiteCache × N             24 B   可选，8 对齐；解释器目前不读 ]
[ padding to 8 ]
[ PropSiteCache × M             32 B   可选，8 对齐；命中路径读帧上 Vm.prop_sites ]
```

独立所有者（不算进主 FAM，但算进 `heapByteSize`）：

- `DebugInfo.pc2line_buf`
- `DebugInfo.source_ptr`（`source_len+1`，NUL 结尾）

### 88 字节核心头（字段顺序）

| 偏移感 | 字段 | 说明 |
| --- | --- | --- |
| header | `gc.Header` | 8 B |
| +0 | `js_mode` | bit0 = strict |
| +1 | `flag_byte17` | prototype / simple params / derived / home / func_kind / new.target / super() |
| +2 | `flag_byte18` | super / arguments / has_debug / rom(恒 0) / eval / has_extension / runtime_strict |
| +4 | `call_facts_mirror` | 2 B，与 hot tail 的 CallFacts 双写；热路径固定偏移半字 |
| +8 | `byte_code` / `byte_code_len` | 负长度 `-1` 是 **唯一** 的 legacy 栈 adapter 判别 |
| | `func_name` | atom |
| | `vardefs` / `closure_var` | FAM 内指针 |
| | `arg_count` `var_count` `defined_arg_count` `stack_size` `var_ref_count` | u16 |
| | `realm` | `RealmRef` |
| | `cpool` / `cpool_count` / `closure_var_count` | |

### Debug 尾（32 B）

`filename`、`source_len`、`pc2line_len`、padding、`pc2line_buf`、`source_ptr`。紧挨 88 字节核心，不移动任何 QuickJS 核心偏移。

### Call-facts / hot 尾（64 B）

`CallFacts`（2 B execution flags：mapped arguments、各类 simple/empty/exact/capture 叶、is_module、entry_rejects_plain_call、small_inline、apply_forward）+ `async_execution_policy` + `script_or_module` + `CtorAllocProfile`（8 B，无堆指针）+ 24 B small_inline pad + `prop_sites`/`call_sites` 指针与计数。

`legacy_byte_code_len_sentinel = -1`：栈上 `LegacyExecutionAdapter`（160 B = 88+64+指针），禁止逃逸、禁止当 GC 对象析构。

## 函数



### `function_bytecode`

### `BytecodeVarDef.init` (`src/bytecode.zig:3141`)

- **签名**：`pub fn init(value: Init) BytecodeVarDef`。
- **作用**：把 Init 压成 12 字节 runtime 行。
- **实现**：flags 打包 const/lexical/captured/has_scope 与 var_kind；未捕获时 var_ref_idx 强制 0。
- **所有权 / 错误 / 调用**：不分配、无 error set，按值返回 12 字节行。生产路径唯一调用方是同结构体的 `fromCompile`（`src/bytecode.zig:3336`）；直接以 `.init` 造行的只有夹具与单测（`src/exec/call_runtime.zig:1437` 的 test 块、`src/tests/exec.zig:3438`）。


### `BytecodeVarDef.fromCompile` (`src/bytecode.zig:3154`)

- **签名**：`pub fn fromCompile(vd: VarDef, scope_next: i32) BytecodeVarDef`。
- **作用**：从编译期 VarDef 生成 runtime 行。
- **实现**：`has_scope = scope_level != 0`；只在 is_captured 时保留 `open_binding_idx`，不把 `no_open_binding` 哨兵写进产物（对齐 QuickJS）。
- **所有权 / 错误 / 调用**：不分配、无 error set，按值产出一行。调用方全在 finalize 往 FAM 里灌表的地方：`createFunctionBytecodeAfterChildren` 依次写 args 段与 locals 段（`src/bytecode.zig:10870`/`:10874`），以及可变 carrier 的同步助手 `syncBytecodeVarNames`（`:11186`）与 `syncBytecodeArgDefs`（`:11207`）。


### `BytecodeVarDef.isConst` (`src/bytecode.zig:3170`)

- **签名**：`pub inline fn isConst(self: BytecodeVarDef) bool`。
- **作用**：const 位。
- **实现**：flags & mask。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set。读者是帧捕获 `src/exec/frame.zig:591`（写进 `VarRef.is_const`）、直接 eval 的种子收集 `src/exec/eval_ops.zig:102`/`:116`/`:123`，以及 `src/exec/vm_property_locals.zig:145` 的写前 const 检查。


### `BytecodeVarDef.isLexical` (`src/bytecode.zig:3174`)

- **签名**：`pub inline fn isLexical(self: BytecodeVarDef) bool`。
- **作用**：lexical 位。
- **实现**：flags & mask。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set。`src/exec/frame.zig:592` 写进 `VarRef.is_lexical`；`src/exec/eval_ops.zig:102`/`:116`/`:123` 把它带进 eval 种子；`src/exec/call_runtime.zig:3337` 用它把 lexical 行排除出 eval 提升的 var。


### `BytecodeVarDef.isCaptured` (`src/bytecode.zig:3178`)

- **签名**：`pub inline fn isCaptured(self: BytecodeVarDef) bool`。
- **作用**：captured 位。
- **实现**：flags & mask。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set。它是「`var_ref_idx` 是否有效」的唯一判据：`src/bytecode.zig:4180`/`:4185`（本类型的 open-binding 查询）与 `src/bytecode.zig:11967`/`:11973`（编译期 `Bytecode` 的同名查询）都先问它再取下标，`src/exec/frame.zig:631` 据此决定关闭哪些 open `VarRef`。


### `BytecodeVarDef.hasScope` (`src/bytecode.zig:3182`)

- **签名**：`pub inline fn hasScope(self: BytecodeVarDef) bool`。
- **作用**：是否非函数顶层词法作用域。
- **实现**：has_scope 位。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set。消费者集中在两处：直接 eval 的作用域链遍历 `src/exec/eval_ops.zig:101`/`:115`/`:122`/`:195`，以及 `src/exec/call_runtime.zig:3337` 的 eval 提升判定。


### `BytecodeVarDef.varKind` (`src/bytecode.zig:3186`)

- **签名**：`pub inline fn varKind(self: BytecodeVarDef) VarKind`。
- **作用**：高 4 位 VarKind。
- **实现**：@enumFromInt。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set；`VarKind` 是 `enum(u4)` 但只定义了 0-10（`src/bytecode.zig:3244`-`:3259`），11-15 属发布 bug，Debug/ReleaseSafe 下 `@enumFromInt` 直接 panic。调用方：`src/exec/frame.zig:593`（标记 function-name 槽）、`src/exec/eval_ops.zig:67`、`src/exec/call_runtime.zig:3338`-`:3340`。


### `ClosureVar.init` (`src/bytecode.zig:3214`)

- **签名**：`pub fn init(value: Init) ClosureVar`。
- **作用**：把 Init 压成与 QuickJS JSClosureVar 同布局的 8 字节行。
- **实现**：`flags` = `closure_type`（低 3 位）| lexical（bit3）| const（bit4）；`kind_flags` 直接放 `var_kind`；再原样写 `var_idx` 与 `var_name` atom。显式按字节拼而不用 packed struct，是为了让位约定不依赖 Zig 的 packed 布局规则，并与 little-endian 上的 `JSClosureVar` 逐字节对齐。
- **所有权 / 错误 / 调用**：不分配、无 error set，按值返回 8 字节行；`var_name` 只是值拷贝，不改 atom 引用。调用方：`FunctionDef.addClosureVar` 的唯一增长点（`src/bytecode.zig:5777`）、binding_rules 的 `threadParentLocalSource`/`threadParentArgSource`（`:8853`/`:8871`）、finalize 的 `captureEvalParentLocal`/`captureEvalParentArg`（`:10431`/`:10463`），以及 parser 转录父行时（`src/parser.zig:3372`/`:3387`）。


### `ClosureVar.closureType` (`src/bytecode.zig:3225`)

- **签名**：`pub inline fn closureType(self: ClosureVar) ClosureType`。
- **作用**：低 3 位 ClosureType。
- **实现**：mask。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set。它是 closure 行的主分流器：`src/exec/vm_call.zig:394`/`:403` 建 `VarRef` 时按类型取初值，`src/exec/module.zig:135`/`:574`/`:582` 类型不符直接返回 `error.InvalidBytecode`，`src/exec/vm_property_globals.zig:394`/`:451`/`:504` 用 `.global_decl` 过滤全局声明。


### `ClosureVar.isLexical` (`src/bytecode.zig:3229`)

- **签名**：`pub inline fn isLexical(self: ClosureVar) bool`。
- **作用**：lexical 位。
- **实现**：bit3。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set。`src/exec/vm_call.zig:410` 与 `src/exec/module.zig:305` 写进 `VarRef.is_lexical`；`src/exec/vm_property_globals.zig:142` 用它决定是否抛全局 TDZ ReferenceError；`FunctionBytecode.varRefIsLexicalAt`（`src/bytecode.zig:4157`）是按下标的包装。


### `ClosureVar.isConst` (`src/bytecode.zig:3233`)

- **签名**：`pub inline fn isConst(self: ClosureVar) bool`。
- **作用**：const 位。
- **实现**：bit4。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set。`FunctionBytecode.varRefIsConstAt`（`src/bytecode.zig:4162`）是按下标的包装；直接读者是全局词法 cell 的创建 `src/exec/object_ops.zig:381` 与 `src/exec/vm_property_globals.zig:507`-`:508`。


### `ClosureVar.varKind` (`src/bytecode.zig:3237`)

- **签名**：`pub inline fn varKind(self: ClosureVar) VarKind`。
- **作用**：kind_flags 低 4 位。
- **实现**：mask。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set。`src/exec/vm_call.zig:411` 与 `src/exec/module.zig:307` 用 `== .function_name` 置 `VarRef` 的 function-name 槽；`src/exec/vm_property_globals.zig:406` 用 `.global_function_decl` 认全局函数声明；`src/exec/slot_ops.zig:224` 同样用于 function-name 判定。


### `ClosureVar.toInit` (`src/bytecode.zig:3241`)

- **签名**：`pub fn toInit(self: ClosureVar) Init`。
- **作用**：解包回 Init，便于再 `init`。
- **实现**：调四个访问器。
- **所有权 / 错误 / 调用**：不分配、无 error set，返回按值的 `Init`。树内唯一调用方是 `src/parser.zig:3411`——把父函数已有的 closure 行原样转录进子函数的 `FunctionDef.addClosureVar`。


### `FunctionBytecode.bit` (`src/bytecode.zig:3659`)

- **签名**：`inline fn bit(byte: u8, mask: u8) bool`。
- **作用**：测 flags 字节的一位。
- **实现**：`byte & mask != 0`。
- **所有权 / 错误 / 调用**：私有 inline。


### `FunctionBytecode.assignBit` (`src/bytecode.zig:3663`)

- **签名**：`inline fn assignBit(byte: *u8, mask: u8, enabled: bool) void`。
- **作用**：置/清 flags 位。
- **实现**：enabled 则 or，否则 and-not。
- **所有权 / 错误 / 调用**：私有 inline，就地改一个 flags 字节，不分配、无 error set。只有两个调用点：`applyFlags`（`src/bytecode.zig:3970`-`:3982`，11 次，覆盖 js_mode 与两个 flag 字节）与 `createRaw`（`:4374`-`:4375` 写 has_debug / has_extension）。


### `FunctionBytecode.hasDebug` (`src/bytecode.zig:3667`)

- **签名**：`pub inline fn hasDebug(self: *const FunctionBytecodeImpl) bool`。
- **作用**：是否紧跟 32 字节 DebugInfo 尾。
- **实现**：byte18 has_debug。
- **所有权 / 错误 / 调用**：layout 与访问器。


### `FunctionBytecode.hasExtension` (`src/bytecode.zig:3671`)

- **签名**：`pub inline fn hasExtension(self: *const FunctionBytecodeImpl) bool`。
- **作用**：是否在 code_end 紧跟 64 字节 hot extension。
- **实现**：byte18 has_extension。
- **所有权 / 错误 / 调用**：生产壳恒 true。


### `FunctionBytecode.layout` (`src/bytecode.zig:3675`)

- **签名**：`pub fn layout(self: *const FunctionBytecodeImpl) function_bytecode.FunctionLayout`。
- **作用**：从已发布 FB 重建 FunctionLayout。
- **实现**：`FunctionLayout.fromFunction(self) catch unreachable`：已发布对象的计数必须合法。
- **所有权 / 错误 / 调用**：deinit/heapByteSize 用。


### `FunctionBytecode.famBytes` (`src/bytecode.zig:3679`)

- **签名**：`pub inline fn famBytes(self: *const FunctionBytecodeImpl) usize`。
- **作用**：FAM 尾巴字节数。
- **实现**：`layout().famBytes()` = total - 88。
- **所有权 / 错误 / 调用**：destroyWithFam。


### `FunctionBytecode.debugInfo` (`src/bytecode.zig:3683`)

- **签名**：`pub inline fn debugInfo(self: *const FunctionBytecodeImpl) ?*const DebugInfo`。
- **作用**：只读 DebugInfo，位于核心头之后。
- **实现**：无 debug 则 null；否则 `ptr + @sizeOf(FunctionBytecodeImpl)`。
- **所有权 / 错误 / 调用**：32 字节、align 8。


### `FunctionBytecode.debugInfoMut` (`src/bytecode.zig:3689`)

- **签名**：`pub inline fn debugInfoMut(self: *FunctionBytecodeImpl) ?*DebugInfo`。
- **作用**：可变 DebugInfo。
- **实现**：同偏移。
- **所有权 / 错误 / 调用**：fixture / finalize 填 filename。


### `FunctionBytecode.hotExtension` (`src/bytecode.zig:3695`)

- **签名**：`pub inline fn hotExtension(self: *const FunctionBytecodeImpl) ?*align(1) const FunctionBytecodeHotExtension`。
- **作用**：定位 64 字节 hot tail。
- **实现**：生产路径：code 指针 + byte_code_len（精确 code_end，align(1)）。空指针走 outlined `hotExtensionSlow`（legacy 哨兵长度则头后立即跟 extension）。
- **所有权 / 错误 / 调用**：CallFacts / call_sites / prop_sites 都从这里来。


### `FunctionBytecode.hotExtensionCanonical` (`src/bytecode.zig:3710`)

- **签名**：`pub inline fn hotExtensionCanonical(self: *const FunctionBytecodeImpl) ?*align(1) const FunctionBytecodeHotExtension`。
- **作用**：驻留 handler 用的叶子安全版：只认规范自有布局，legacy adapter 当「无 extension」。
- **实现**：不走 slow 臂，避免冷路径留下栈帧。
- **所有权 / 错误 / 调用**：返回 FAM 内借用指针（`*align(1) const`），不分配、无 error set；legacy adapter 一律读成 `null`，调用方因此拿不到 adapter 的尾。生产调用方两处：`src/exec/tailcall_dispatch.zig:223` 的 `propSiteCold` 惰性把 `prop_sites` 镜像进 `Vm`，`src/exec/inline_calls.zig:205` 读 `async_execution_policy` 判定 no-suspend async。


### `FunctionBytecode.hotExtensionMut` (`src/bytecode.zig:3716`)

- **签名**：`pub inline fn hotExtensionMut(self: *FunctionBytecodeImpl) ?*align(1) FunctionBytecodeHotExtension`。
- **作用**：可变 hot extension。
- **实现**：有 code 指针则 constCast canonical；否则 slow。
- **所有权 / 错误 / 调用**：setExecutionFlags。


### `FunctionBytecode.canonicalHotAddress` (`src/bytecode.zig:3724`)

- **签名**：`inline fn canonicalHotAddress(code_ptr: [*]const u8, code_len: i32) usize`。
- **作用**：code_ptr + code_len（wrapping add，已在 layout 检查过）。
- **实现**：断言 len>0，关 runtime safety。
- **所有权 / 错误 / 调用**：私有 inline，纯地址算术，不分配、无 error set；`@setRuntimeSafety(false)` 关掉了溢出检查，正确性靠 `FunctionLayout` 在发布 code 指针/长度前已检查过这次加法。唯一调用方是同结构体的 `canonicalHotExtension`（`src/bytecode.zig:3917`）。


### `FunctionBytecode.canonicalHotExtension` (`src/bytecode.zig:3732`)

- **签名**：`inline fn canonicalHotExtension( code_ptr: [*]const u8, code_len: i32, ) *align(1) const FunctionBytecodeHotExtension`。
- **作用**：把 canonical 地址转成 `*align(1) const HotExtension`。
- **实现**：`@ptrFromInt`。
- **所有权 / 错误 / 调用**：私有 inline，只做 `@ptrFromInt`，不分配、无 error set，返回 FAM 内借用指针。三个调用方都在本结构体：`hotExtension`（`src/bytecode.zig:3882`）、`hotExtensionCanonical`（`:3894`）、`hotExtensionMut`（`:3900`，再 `@constCast`）。


### `FunctionBytecode.hotExtensionSlow` (`src/bytecode.zig:3739`)

- **签名**：`noinline fn hotExtensionSlow(self: *const FunctionBytecodeImpl) *align(1) const FunctionBytecodeHotExtension`。
- **作用**：`hotExtension` 在没有自有 code 指针时的 outlined 定位：legacy 哨兵长度则头后立即跟 extension，否则用 layout 的 `hot_off`。
- **实现**：`byte_code_len == legacy_byte_code_len_sentinel` → `bytes + sizeOf(FunctionBytecodeImpl)`。否则 `layout().hot_off orelse unreachable`。热路径 `hotExtension` 有 code 指针时走 `canonicalHotExtension`，不进这里。
- **所有权 / 错误 / 调用**：返回的是 FAM 内指针，不拥有。legacy adapter / 空指针夹具才进来。


### `FunctionBytecode.hotExtensionMutSlow` (`src/bytecode.zig:3748`)

- **签名**：`noinline fn hotExtensionMutSlow(self: *FunctionBytecodeImpl) *align(1) FunctionBytecodeHotExtension`。
- **作用**：`hotExtensionMut` 的可变 outlined 孪生：同一偏移规则，返回可写 hot tail。
- **实现**：与 `hotExtensionSlow` 相同的哨兵 / `hot_off` 分支，指针类型是 `[*]u8`。
- **所有权 / 错误 / 调用**：`setExecutionFlags` 等写路径。发布漏 extension 时 `hot_off` 缺失是 bug（unreachable）。


### `FunctionBytecode.hotExtensionRequiredMut` (`src/bytecode.zig:3757`)

- **签名**：`inline fn hotExtensionRequiredMut(self: *FunctionBytecodeImpl) *align(1) FunctionBytecodeHotExtension`。
- **作用**：必须存在的可变 hot tail，否则 unreachable。
- **实现**：`hotExtensionMut() orelse unreachable`。
- **所有权 / 错误 / 调用**：发布漏 extension 是 bug。


### `FunctionBytecode.canonicalCallFacts` (`src/bytecode.zig:3765`)

- **签名**：`pub inline fn canonicalCallFacts(self: *const FunctionBytecodeImpl) function_bytecode.CallFacts`。
- **作用**：热路径读 header 里的 `call_facts_mirror`，避免每次触摸 code 远端。
- **实现**：断言有 extension 且 code 非空。Debug 下再与 FAM 字逐位相等。
- **所有权 / 错误 / 调用**：与 `setExecutionFlags` / `publishExecutionFlags` 双写。


### `FunctionBytecode.applyFlags` (`src/bytecode.zig:3788`)

- **签名**：`pub fn applyFlags(self: *FunctionBytecodeImpl, flags: Flags) void`。
- **作用**：把 Flags 结构写进 js_mode / flag_byte17 / flag_byte18。
- **实现**：逐位 assignBit；func_kind 占 byte17 的 bit4-5。不改 has_debug/has_extension。
- **所有权 / 错误 / 调用**：finalize 的 no-fail commit（`src/bytecode.zig:10888`）是主调用方，另有 createFixture、`LegacyExecutionAdapter.init` 与 `src/exec/small_inline.zig` 的 spec 构造。


### `FunctionBytecode.functionKind` (`src/bytecode.zig:3804`)

- **签名**：`pub inline fn functionKind(self: *const FunctionBytecodeImpl) FunctionKind`。
- **作用**：读出这份已发布函数体属于 `normal` / `generator` / `async` / `async_generator` 四类中的哪一类，是调用与构造路径上最先分流的那个事实。
- **实现**：从 QuickJS 布局的 `flag_byte17` 里按 `byte17_func_kind_mask`（bit 4-5）取两位、右移 `byte17_func_kind_shift` 后 `@enumFromInt` 成 `FunctionKind`；位由 `applyFlags` 在发布前写入，之后只读。
- **所有权 / 错误 / 调用**：纯位读、无 error set、不触碰扩展尾。调用方遍布执行侧：`src/exec/call_runtime.zig:3642` 用它决定是否要堆驻留帧与 generator 状态、`src/exec/object_ops.zig:286`/`:490`/`:574` 据此挑函数原型与 `GeneratorFunction`/`AsyncFunction` 名、`src/exec/inline_calls.zig:168` 与 `src/exec/small_inline.zig:472` 把非 `normal` 一律排除在内联之外、同文件 `publishExecutionFlags`（`src/bytecode.zig:12186`）与 `classifyAsyncExecution`（`:12141`）用它作首道守卫。


### `FunctionBytecode.hasPrototype` (`src/bytecode.zig:3807`)

- **签名**：`pub inline fn hasPrototype(self: *const FunctionBytecodeImpl) bool`。
- **作用**：该函数对象是否要挂 `.prototype` 属性——箭头函数、方法、getter/setter 没有，普通函数与 generator 有。
- **实现**：读 `flag_byte17` 的 bit 0（`byte17_has_prototype_mask`），值由 `applyFlags` 从 `Flags.has_prototype` 写入。
- **所有权 / 错误 / 调用**：纯位读、无 error set。`src/exec/object_ops.zig:555` 据此决定创建函数对象时要不要装 `prototype`、`:2656` 用于 `bytecode_function` 类的属性枚举；`src/exec/construct.zig:1039` 与 `src/exec/call_runtime.zig:2008`/`:2028`/`:4501` 把它当作 `new` 快路径与原型缓存的前置条件。


### `FunctionBytecode.hasSimpleParameterList` (`src/bytecode.zig:3810`)

- **签名**：`pub inline fn hasSimpleParameterList(self: *const FunctionBytecodeImpl) bool`。
- **作用**：形参表是否「简单」（无默认值、无解构、无 rest），这是 sloppy 模式 mapped `arguments` 与各条内联路径的规范前置条件。
- **实现**：读 `flag_byte17` 的 bit 1（`byte17_simple_parameters_mask`），由 `applyFlags` 一次写定。
- **所有权 / 错误 / 调用**：纯位读、无 error set。`src/exec/object_ops.zig:2309`-`:2311` 用它加上非 strict 判定来决定 `arguments` 是否 mapped（对应 spec CreateMappedArgumentsObject 的前置条件）；`src/exec/frame.zig:223` 与 `src/exec/small_inline.zig:470` 用作帧形态与 small-inline 的 S1 守卫；同文件 `scanSmallInlineEligible`（`src/bytecode.zig:12102`）和 `publishExecutionFlags`（`:12188`）把它算进 `simple_inline_base`。


### `FunctionBytecode.isDerivedClassConstructor` (`src/bytecode.zig:3813`)

- **签名**：`pub inline fn isDerivedClassConstructor(self: *const FunctionBytecodeImpl) bool`。
- **作用**：该函数体是不是 `class X extends Y` 的构造器——决定 `this` 在 `super()` 之前处于 TDZ，且一律不得内联。
- **实现**：读 `flag_byte17` 的 bit 2（`byte17_derived_constructor_mask`），由 `applyFlags` 写入，是 QuickJS 头里原有的规范位。
- **所有权 / 错误 / 调用**：纯位读、无 error set。`src/exec/vm_property_locals.zig:116`/`:166` 用它判断局部 `this` 是否需要 TDZ 检查、`src/exec/frame.zig:220` 决定帧是否要额外的 this 初始化状态、`src/exec/inline_calls.zig:173` 与 `src/exec/small_inline.zig:473` 直接拒绝内联；同文件 `publishExecutionFlags` 以 `std.debug.assert(!fb.isDerivedClassConstructor() or class_syntax_excludes_inline)`（`src/bytecode.zig:12173`）守住两套排除口径一致。


### `FunctionBytecode.needHomeObject` (`src/bytecode.zig:3816`)

- **签名**：`pub inline fn needHomeObject(self: *const FunctionBytecodeImpl) bool`。
- **作用**：函数体里出现过 `super.x` 之类的 home-object 引用，因而创建函数对象时必须绑定 `[[HomeObject]]`。
- **实现**：读 `flag_byte17` 的 bit 3（`byte17_need_home_object_mask`），由 `applyFlags` 从解析结果一次写入。
- **所有权 / 错误 / 调用**：纯位读、无 error set。生产路径上唯一的读者是 `src/exec/small_inline.zig:1175`，它在为被展开的调用者重建 `Flags` 快照时原样带上这一位。


### `FunctionBytecode.newTargetAllowed` (`src/bytecode.zig:3819`)

- **签名**：`pub inline fn newTargetAllowed(self: *const FunctionBytecodeImpl) bool`。
- **作用**：函数体内是否允许出现 `new.target`（普通函数与类构造器允许，顶层脚本不允许），是 `EntryContract` 的一员。
- **实现**：读 `flag_byte17` 的 bit 6（`byte17_new_target_mask`），由 `applyFlags` 写入。
- **所有权 / 错误 / 调用**：纯位读、无 error set。由同结构体的 `entryContract`（`src/bytecode.zig:4206`）汇总成入口契约；`src/parser.zig:15893` 在为直接 eval 重建父函数上下文时读回它，`src/exec/small_inline.zig:1177` 在展开调用者时透传。


### `FunctionBytecode.superCallAllowed` (`src/bytecode.zig:3822`)

- **签名**：`pub inline fn superCallAllowed(self: *const FunctionBytecodeImpl) bool`。
- **作用**：函数体内是否允许 `super(...)` 调用（仅派生类构造器及其内部的箭头函数），是 `EntryContract` 的一员。
- **实现**：读 `flag_byte17` 的 bit 7（`byte17_super_call_mask`），由 `applyFlags` 写入。
- **所有权 / 错误 / 调用**：纯位读、无 error set。经 `entryContract`（`src/bytecode.zig:4207`）进入入口契约；`src/parser.zig:15894` 供直接 eval 继承外层语法许可，`src/exec/small_inline.zig:1178` 在展开时透传。


### `FunctionBytecode.superAllowed` (`src/bytecode.zig:3825`)

- **签名**：`pub inline fn superAllowed(self: *const FunctionBytecodeImpl) bool`。
- **作用**：函数体内是否允许 `super.x` 形式的属性访问（方法、类体内的函数），是 `EntryContract` 的一员。
- **实现**：读 `flag_byte18` 的 bit 0（`byte18_super_mask`）——与前两位不同，它落在第二个标志字节上，由 `applyFlags` 写入。
- **所有权 / 错误 / 调用**：纯位读、无 error set。经 `entryContract`（`src/bytecode.zig:4208`）进入入口契约；`src/parser.zig:15895` 与 `src/exec/small_inline.zig:1179` 分别在 eval 与内联展开时继承。


### `FunctionBytecode.argumentsAllowed` (`src/bytecode.zig:3828`)

- **签名**：`pub inline fn argumentsAllowed(self: *const FunctionBytecodeImpl) bool`。
- **作用**：函数体内是否允许引用 `arguments`（箭头函数与模块体不允许，它们必须沿闭包链向外找），是 `EntryContract` 的一员。
- **实现**：读 `flag_byte18` 的 bit 1（`byte18_arguments_mask`），由 `applyFlags` 写入。
- **所有权 / 错误 / 调用**：纯位读、无 error set。经 `entryContract`（`src/bytecode.zig:4209`）进入入口契约；`src/parser.zig:15896` 让直接 eval 继承宿主函数的许可，`src/exec/small_inline.zig:1180` 在展开时透传。


### `FunctionBytecode.isDirectOrIndirectEval` (`src/bytecode.zig:3831`)

- **签名**：`pub inline fn isDirectOrIndirectEval(self: *const FunctionBytecodeImpl) bool`。
- **作用**：这份函数体是不是由 `eval` 编译出来的（直接或间接均置位），决定全局变量声明的校验口径与内联资格。
- **实现**：读 `flag_byte18` 的 bit 4（`byte18_eval_mask`），由 `applyFlags` 写入。
- **所有权 / 错误 / 调用**：纯位读、无 error set。`src/exec/object_ops.zig:387`、`:453`、`:459` 把它作为 `validateGlobalVarDeclarations` 的 eval 口径开关（eval 引入的 var 是 configurable 的）；`src/exec/small_inline.zig:377` 用它加 `executionFlags().is_module` 把 eval 与模块体挡在 small-inline 之外；`src/parser.zig:15917` 供嵌套 eval 判定。


### `FunctionBytecode.callFacts` (`src/bytecode.zig:3834`)

- **签名**：`pub inline fn callFacts(self: *const FunctionBytecodeImpl) function_bytecode.CallFacts`。
- **作用**：通用读：经 hotExtension，没有则全 0。
- **实现**：可选尾。热路径应走 canonicalCallFacts。
- **所有权 / 错误 / 调用**：读 FAM 内热尾并按值拷回 `CallFacts`，不分配、无 error set；没有扩展尾时返回全零值，即「所有快路径资格都不成立」的保守读数。同结构体的 `isModule`（`src/bytecode.zig:4195`）与 `executionFlags`（`:4224`）是主要包装；直读者是发布侧 `publishExecutionFlags`（`:12177`）与 small-inline 的 spec 复制 `src/exec/small_inline.zig:1243`。解释器热路径不走这里，改读头内镜像的 `canonicalCallFacts`。


### `FunctionBytecode.ctorAllocProfile` (`src/bytecode.zig:3838`)

- **签名**：`pub inline fn ctorAllocProfile(self: *const FunctionBytecodeImpl) ?*align(1) const function_bytecode.CtorAllocProfile`。
- **作用**：构造分配 profile（8 字节，无堆指针）。
- **实现**：hot.ctor_alloc。
- **所有权 / 错误 / 调用**：无 GC 边。


### `FunctionBytecode.ctorAllocProfileMut` (`src/bytecode.zig:3842`)

- **签名**：`pub inline fn ctorAllocProfileMut(self: *const FunctionBytecodeImpl) ?*align(1) function_bytecode.CtorAllocProfile`。
- **作用**：可变 ctor profile。
- **实现**：constCast hot。
- **所有权 / 错误 / 调用**：学习路径写。


### `FunctionBytecode.legacyBytecodeAdapter` (`src/bytecode.zig:3846`)

- **签名**：`pub inline fn legacyBytecodeAdapter(self: *const FunctionBytecodeImpl) ?*const function_mod.BytecodeImpl`。
- **作用**：仅当 `byte_code_len == -1` 时，从 body+hot 之后读回 `*BytecodeImpl`。
- **实现**：规范布局永远不会发布负长度。
- **所有权 / 错误 / 调用**：栈上 adapter，禁止当 GC 对象析构。


### `FunctionBytecode.setLegacyBytecodeAdapter` (`src/bytecode.zig:3859`)

- **签名**：`pub inline fn setLegacyBytecodeAdapter(self: *FunctionBytecodeImpl, value: ?*const function_mod.BytecodeImpl) void`。
- **作用**：写入 adapter 反指针。
- **实现**：断言哨兵长度与 extension。
- **所有权 / 错误 / 调用**：LegacyExecutionAdapter.init。


### `FunctionBytecode.openVarRefCount` (`src/bytecode.zig:3868`)

- **签名**：`pub inline fn openVarRefCount(self: *const FunctionBytecodeImpl) u16`。
- **作用**：打开的 local/arg VarRef 数。
- **实现**：`var_ref_count`。
- **所有权 / 错误 / 调用**：帧布局。


### `FunctionBytecode.closureVarCount` (`src/bytecode.zig:3871`)

- **签名**：`pub inline fn closureVarCount(self: *const FunctionBytecodeImpl) usize`。
- **作用**：闭包行数。
- **实现**：断言 ≥0 后 intCast。
- **所有权 / 错误 / 调用**：纯字段读加一个非负断言，不分配、无 error set；不需要 legacy adapter 分支，因为 adapter 在 init 时就把同一计数镜像进核心头（`src/bytecode.zig:12042`）。它是 `var_refs` 数组长度的权威：`src/core/object_payloads.zig:1237`/`:1244` 与 `src/exec/inline_calls.zig:109`/`:165` 用它切片并断言，`src/core/object.zig:5743`/`:5798` 长度不符即 `error.InvalidBytecode`，`src/exec/tailcall_dispatch.zig` 另有 9 处在叶臂里取捕获数组。


### `FunctionBytecode.filenameAtom` (`src/bytecode.zig:3875`)

- **签名**：`pub inline fn filenameAtom(self: *const FunctionBytecodeImpl) atom.Atom`。
- **作用**：源文件 atom：legacy 走 Bytecode.filename，否则 DebugInfo.filename。
- **实现**：无 debug 则 null_atom。
- **所有权 / 错误 / 调用**：返回借用 atom，不 dup、不分配、无 error set；无 debug 尾且非 adapter 时返回 `atom.null_atom`。GC 的 atom 遍历 `src/core/gc_trace_stw.zig:169` 靠它把 filename 标活；`src/exec/exception_ops.zig:492` 放进错误站点；`src/exec/small_inline.zig:1230`/`:1293` 要先 `noteHolderStore` 提引用再存进新 spec。


### `FunctionBytecode.byteCodeAssumeMaterialized` (`src/bytecode.zig:3889`)

- **签名**：`pub inline fn byteCodeAssumeMaterialized(self: *const FunctionBytecodeImpl) []u8`。
- **作用**：已证明物化的热路径：跳过 optional。
- **实现**：断言指针非空且 len>0。InlineTarget / 正在执行的帧使用。
- **所有权 / 错误 / 调用**：返回 FAM 内借用切片，不分配、无 error set；前置条件（`byte_code != null and byte_code_len > 0`）只由 Debug/ReleaseSafe 的断言守，ReleaseFast 下违反即 UB。22 处调用方全在 `src/exec/tailcall_dispatch.zig`（如 `:427`、`:861`、`:1286`），都是已证明 materialized 的入口或恢复点。


### `FunctionBytecode.byteCode` (`src/bytecode.zig:3894`)

- **签名**：`pub inline fn byteCode(self: *const FunctionBytecodeImpl) []u8`。
- **作用**：物化代码切片。规范路径两次固定头加载；null 指针走 outlined slow（legacy 或空）。
- **实现**：Debug 分发每条 opcode 都会问，故不能先探 extension。
- **所有权 / 错误 / 调用**：返回的是 FAM 内切片，不拥有。


### `FunctionBytecode.byteCodeSlow` (`src/bytecode.zig:3913`)

- **签名**：`noinline fn byteCodeSlow(self: *const FunctionBytecodeImpl) []u8`。
- **作用**：`byteCode` 的迁移/夹具臂：core 指针为空时才探 legacy adapter 或空切片。
- **实现**：`legacyBytecodeAdapter()` 有值则 `@constCast(legacy.code)`。否则断言 `byte_code_len >= 0`；len=0 返回空切片；非空且无指针是 bug（unreachable）。outlined 是为了让 Debug 每条 opcode 的 `byteCode()` 不把 optional-extension 走法实例化进 threaded handler。
- **所有权 / 错误 / 调用**：返回的是 adapter / 空切片，不拥有。生产编译产物不进这里。


### `FunctionBytecode.allVarDefs` (`src/bytecode.zig:3922`)

- **签名**：`pub inline fn allVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef`。
- **作用**：args+locals 连续表。
- **实现**：legacy 断言 argdefs 为空后返回 vardefs；否则 vardefs[0 .. arg+var]。
- **所有权 / 错误 / 调用**：返回 FAM 内借用切片（adapter FB 则借 adapter 的数组），不分配、无 error set；计数为 0 时返回空切片并断言 `vardefs == null`。同结构体的 `argVarDefs`/`localVarDefs` 是它的切分（`src/bytecode.zig:4117`/`:4121`）；树外调用方是 GC 的 atom 遍历 `src/core/gc_trace_stw.zig:171` 与 small-inline 的 vardef 复制源 `src/exec/small_inline.zig:1205`。


### `FunctionBytecode.argVarDefs` (`src/bytecode.zig:3934`)

- **签名**：`pub inline fn argVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef`。
- **作用**：参数行前缀。
- **实现**：allVarDefs[0..arg_count]。
- **所有权 / 错误 / 调用**：借用切片，不分配、无 error set；`[0..arg_count]` 超出实际行数属发布 bug（越界由切片语义在 Debug 下 panic）。调用方以参数环境重建为主：`src/exec/eval_ops.zig:110`-`:111`、`src/exec/vm_property.zig:150`-`:151`，以及同结构体的 `argOpenBindingIndex`（`src/bytecode.zig:4183`）。


### `FunctionBytecode.localVarDefs` (`src/bytecode.zig:3938`)

- **签名**：`pub inline fn localVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef`。
- **作用**：局部行后缀。
- **实现**：allVarDefs[arg_count..]。
- **所有权 / 错误 / 调用**：借用切片，不分配、无 error set。生产树内没有直接调用方——所有读者走同义的 `varDefs()`（`src/bytecode.zig:4125`）；按本名调用的只有 `src/tests/bytecode.zig:1828`。


### `FunctionBytecode.varDefs` (`src/bytecode.zig:3943`)

- **签名**：`pub inline fn varDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef`。
- **作用**：兼容名：帧局部。
- **实现**：`localVarDefs()`。
- **所有权 / 错误 / 调用**：`localVarDefs` 的同义名，借用切片，不分配、无 error set。非测试调用方约 21 处：`src/exec/frame.zig:572`/`:591`/`:631` 的局部捕获、`src/exec/vm_property_locals.zig:117`-`:168` 的 this/TDZ 与 const 判定、`src/exec/eval_ops.zig` 的 eval 种子收集等。


### `FunctionBytecode.closureVar` (`src/bytecode.zig:3946`)

- **签名**：`pub inline fn closureVar(self: *const FunctionBytecodeImpl) []BytecodeClosureVar`。
- **作用**：闭包行切片。
- **实现**：count 0 则空且指针 null。
- **所有权 / 错误 / 调用**：借用切片（adapter 则借 adapter 的行），不分配、无 error set；计数为 0 时返回空切片并断言指针为 null。这是读得最多的 FB 访问器之一（非测试 45 处）：`src/exec/vm_call.zig:394` 起的 `VarRef` 装载、`src/exec/module.zig:135`/`:323` 的模块环境校验、`src/exec/vm_property_globals.zig:33`-`:34` 的按下标取行。


### `FunctionBytecode.cpoolSlice` (`src/bytecode.zig:3955`)

- **签名**：`pub inline fn cpoolSlice(self: *const FunctionBytecodeImpl) []JSValue`。
- **作用**：常量池切片。
- **实现**：count 0 则空。
- **所有权 / 错误 / 调用**：值是 GC 边。


### `FunctionBytecode.constantAt` (`src/bytecode.zig:3965`)

- **签名**：`pub inline fn constantAt(self: *const FunctionBytecodeImpl, index: usize) ?JSValue`。
- **作用**：按下标取常量，越界 null。
- **实现**：cpoolSlice。
- **所有权 / 错误 / 调用**：返回 cpool 里的借用 `JSValue`——GC 边归 FB 所有，调用方不 retain。本身无 error set，越界返回 `null`，由调用方翻成 JS 异常：`src/exec/array_ops.zig:160` 与 `src/exec/tailcall_dispatch.zig:3626` 转 `error.InvalidBytecode`，`src/exec/vm_value.zig:89`/`:97` 转 `error.TypeError`。


### `FunctionBytecode.funcName` (`src/bytecode.zig:3970`)

- **签名**：`pub inline fn funcName(self: *const FunctionBytecodeImpl) atom.Atom`。
- **作用**：函数名 atom。
- **实现**：头字段。
- **所有权 / 错误 / 调用**：纯字段读，返回借用 atom，不 dup、无 error set。GC 的 atom 遍历 `src/core/gc_trace_stw.zig:168` 靠它保活；`src/exec/exception_ops.zig:491` 写进错误站点；`src/exec/small_inline.zig:1194`/`:1292` 存进新 spec 前先 `noteHolderStore` 提引用；`src/bytecode.zig:12277` 用于 dump。


### `FunctionBytecode.varRefIsLexicalAt` (`src/bytecode.zig:3973`)

- **签名**：`pub inline fn varRefIsLexicalAt(self: *const FunctionBytecodeImpl, idx: usize) bool`。
- **作用**：闭包行是否 lexical。
- **实现**：越界 false。
- **所有权 / 错误 / 调用**：借用读、不分配、无 error set；下标越界返回 `false` 而不是 panic。唯一生产调用方 `src/exec/call_runtime.zig:5048`：非 lexical 的 uninitialized 槽不报 TDZ。


### `FunctionBytecode.varRefIsConstAt` (`src/bytecode.zig:3978`)

- **签名**：`pub inline fn varRefIsConstAt(self: *const FunctionBytecodeImpl, idx: usize) bool`。
- **作用**：闭包行是否 const。
- **实现**：越界 false。
- **所有权 / 错误 / 调用**：借用读、不分配、无 error set；越界返回 `false`。生产调用方 `src/exec/vm_call.zig:366`，用于给新建的 `VarRef` 置 `is_const`。


### `FunctionBytecode.varRefIsGlobalDeclAt` (`src/bytecode.zig:3983`)

- **签名**：`pub inline fn varRefIsGlobalDeclAt(self: *const FunctionBytecodeImpl, idx: usize) bool`。
- **作用**：是否 global_decl。
- **实现**：closureType 比较。
- **所有权 / 错误 / 调用**：借用读、不分配、无 error set；越界返回 `false`。调用方 `src/exec/vm_call.zig:356` 与 `src/exec/slot_ops.zig:142`，两处都用它把 global-decl 引用分流到全局环境而不是帧内 `VarRef`。


### `FunctionBytecode.varRefNamesLen` (`src/bytecode.zig:3988`)

- **签名**：`pub inline fn varRefNamesLen(self: *const FunctionBytecodeImpl) usize`。
- **作用**：闭包名数量 = closureVarCount。
- **实现**：不再有平行名字数组。
- **所有权 / 错误 / 调用**：纯计数读、不分配、无 error set；与 `closureVarCount` 的差别是它先问 legacy adapter。调用方 `src/exec/vm_property.zig:64`/`:146`/`:172` 与 `src/exec/slot_ops.zig:135`/`:179`，都是「下标是否落在 closure 表内」的守卫。


### `FunctionBytecode.varRefName` (`src/bytecode.zig:3992`)

- **签名**：`pub inline fn varRefName(self: *const FunctionBytecodeImpl, idx: usize) atom.Atom`。
- **作用**：闭包行的 var_name。
- **实现**：`closureVar()[idx].var_name`。
- **所有权 / 错误 / 调用**：调用方保证 idx 合法。


### `FunctionBytecode.localOpenBindingIndex` (`src/bytecode.zig:3996`)

- **签名**：`pub inline fn localOpenBindingIndex(self: *const FunctionBytecodeImpl, idx: usize) ?u16`。
- **作用**：局部若捕获则返回 var_ref_idx。
- **实现**：未捕获 null。
- **所有权 / 错误 / 调用**：借用读、不分配、无 error set；下标越界或该槽未捕获都返回 `null`。`src/exec/frame.zig:576` 用 `.?` 强解（前面已断言下标在 `varDefs()` 内且该槽被捕获），`:621` 用 `orelse return` 容忍未捕获。


### `FunctionBytecode.argOpenBindingIndex` (`src/bytecode.zig:4001`)

- **签名**：`pub inline fn argOpenBindingIndex(self: *const FunctionBytecodeImpl, idx: usize) ?u16`。
- **作用**：参数捕获下标。
- **实现**：同局部。
- **所有权 / 错误 / 调用**：同 `localOpenBindingIndex`：借用读、不分配、无 error set，越界或未捕获返回 `null`。唯一调用方 `src/exec/frame.zig:603` 用 `.?` 强解——到这一步参数未捕获属发布 bug。


### `FunctionBytecode.isGlobalVar` (`src/bytecode.zig:4006`)

- **签名**：`pub inline fn isGlobalVar(self: *const FunctionBytecodeImpl) bool`。
- **作用**：生产 FB 恒 false；只有 fixture adapter 还问运行时去实例化声明。
- **实现**：legacy.flags.is_global_var。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set；canonical FB 恒为 `false`（该事实在 QuickJS 里只存在于编译期 `FunctionDef`），只有 legacy adapter 可能为 `true`。调用方 `src/exec/zjs_vm.zig:446`/`:553` 据此决定入口要不要跑全局声明实例化，`src/exec/inline_calls.zig:3142` 用它取反作为借用 `var_refs` 的前提。


### `FunctionBytecode.isModule` (`src/bytecode.zig:4013`)

- **签名**：`pub inline fn isModule(self: *const FunctionBytecodeImpl) bool`。
- **作用**：CallFacts.execution.is_module。
- **实现**：callFacts()。
- **所有权 / 错误 / 调用**：经 `callFacts()` 读热尾位，不分配、无 error set；无扩展尾时读成 `false`。调用方把它当校验或分流开关：`src/exec/object_ops.zig:301` 与 `src/exec/module.zig:124` 不满足即 `error.InvalidBytecode`，`src/exec/zjs_vm.zig:56`/`:90`/`:164` 据此定 this 绑定与入口形态，`src/exec/vm_gen_async.zig:683` 参与 await 挂起策略。


### `FunctionBytecode.isAsync` (`src/bytecode.zig:4016`)

- **签名**：`pub inline fn isAsync(self: *const FunctionBytecodeImpl) bool`。
- **作用**：kind 为 async 或 async_generator。
- **实现**：functionKind。
- **所有权 / 错误 / 调用**：两次 `functionKind()` 位读，不分配、无 error set，不碰扩展尾。`src/exec/zjs_vm.zig:605` 用它与 `isGenerator` 一起排除内联帧存储；`src/exec/vm_gen_async.zig:684`/`:689` 用它选 raw 恢复策略。


### `FunctionBytecode.isGenerator` (`src/bytecode.zig:4019`)

- **签名**：`pub inline fn isGenerator(self: *const FunctionBytecodeImpl) bool`。
- **作用**：kind 为 generator 或 async_generator。
- **实现**：functionKind。
- **所有权 / 错误 / 调用**：与 `isAsync` 同形：纯位读、不分配、无 error set。生产唯一读者是 `src/exec/zjs_vm.zig:605` 的帧存储选择——generator/async 需要堆驻留帧，不能用入口的内联帧。


### `FunctionBytecode.entryContract` (`src/bytecode.zig:4022`)

- **签名**：`pub inline fn entryContract(self: *const FunctionBytecodeImpl) EntryContract`。
- **作用**：四位 grammar 允许位。
- **实现**：legacy 用存好的 contract；规范路径从头 flags 组装。
- **所有权 / 错误 / 调用**：无 var-env/this 身份——那些以 vardef/closure 为准。


### `FunctionBytecode.isStrictMode` (`src/bytecode.zig:4031`)

- **签名**：`pub inline fn isStrictMode(self: *const FunctionBytecodeImpl) bool`。
- **作用**：js_mode bit0。adapter init 已把事实拷进该字节。
- **实现**：bit。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set；adapter 在 init 时已把该事实拷进 QJS 的 js_mode 字节，所以两种表示共用这条直读。读者遍布执行与编译侧：`src/exec/vm_property_ref.zig:88`/`:266`/`:305`/`:392` 与 `runtimeStrictMode` 一起决定未解析引用是抛 ReferenceError 还是静默，`src/parser.zig:15902` 供直接 eval 继承，`src/exec/small_inline.zig:1170` 在展开时透传，`src/bytecode.zig:12178` 用于发布判定。


### `FunctionBytecode.runtimeStrictMode` (`src/bytecode.zig:4037`)

- **签名**：`pub inline fn runtimeStrictMode(self: *const FunctionBytecodeImpl) bool`。
- **作用**：zjs 扩展的 runtime_strict 位。
- **实现**：byte18 bit6。
- **所有权 / 错误 / 调用**：纯位读、不分配、无 error set；唯一写入点是 `applyFlags`（`src/bytecode.zig:3982`）。读者与 `isStrictMode` 成对出现：`src/exec/vm_property_ref.zig:88`/`:266`/`:305`/`:392` 的未解析引用处理、`src/exec/zjs_vm.zig:90`（决定入口 this 是 `undefined` 还是全局对象）。


### `FunctionBytecode.executionFlags` (`src/bytecode.zig:4042`)

- **签名**：`pub inline fn executionFlags(self: *const FunctionBytecodeImpl) ExecutionFlags`。
- **作用**：CallFacts.execution。
- **实现**：callFacts。
- **所有权 / 错误 / 调用**：`callFacts().execution` 的转发，按值返回位域，不分配、无 error set；无扩展尾读成全零。同结构体下面十几个 `*Eligible`/`*Leaf` getter 都经它（`src/bytecode.zig:4236`-`:4269`）；树内直读者是 `src/exec/small_inline.zig:204`（取回旧 flags 改写后再发布）与 `:377`（用 `is_module` 把模块体挡在 small-inline 外）。


### `FunctionBytecode.setExecutionFlags` (`src/bytecode.zig:4045`)

- **签名**：`pub inline fn setExecutionFlags(self: *FunctionBytecodeImpl, value: ExecutionFlags) void`。
- **作用**：同时写 FAM CallFacts 与 header mirror。
- **实现**：hotExtensionRequiredMut；再 `call_facts_mirror = facts`。
- **所有权 / 错误 / 调用**：唯一允许的可变发布漏斗之一。


### `FunctionBytecode.hasMappedArguments` (`src/bytecode.zig:4054`)

- **签名**：`pub inline fn hasMappedArguments(self: *const FunctionBytecodeImpl) bool`。
- **作用**：该函数的 `arguments` 对象是否与形参双向联动（sloppy + 简单形参表），即 spec 的 CreateMappedArgumentsObject 情形。
- **实现**：取 `executionFlags()`（`callFacts().execution`，无热尾时为全零默认值）后返回 `has_mapped_arguments` 位；该位由 `publishExecutionFlags` 以入参形式一次写定（`src/bytecode.zig:12224`），发布后不变。
- **所有权 / 错误 / 调用**：纯位读、无 error set、不分配。热路径不经这个 getter，而是直接读 `call_facts.execution` 位域；此处按名读取主要服务于同文件的诊断与 `src/tests/bytecode.zig` 的发布对账。


### `FunctionBytecode.simpleInlineEligible` (`src/bytecode.zig:4057`)

- **签名**：`pub inline fn simpleInlineEligible(self: *const FunctionBytecodeImpl) bool`。
- **作用**：sloppy 简单内联资格。
- **实现**：返回 `executionFlags().simple_inline_eligible`。该位在 `publishExecutionFlags` 里等于 `simple_inline_base and !strict_mode`（`src/bytecode.zig:12225`），其中 `simple_inline_base` = `functionKind() == .normal` 且非 class 语法排除、形参表简单、无 `global_decl` 闭包行。
- **所有权 / 错误 / 调用**：纯位读、无 error set。消费者是内联调用解析器，但它直读位域而非本 getter：`src/exec/inline_calls.zig:1637`、`:1678`、`:3226`、`:3509` 用它选 `.sloppy` 内联臂；getter 形式主要用于测试与诊断。


### `FunctionBytecode.strictSimpleInlineEligible` (`src/bytecode.zig:4060`)

- **签名**：`pub inline fn strictSimpleInlineEligible(self: *const FunctionBytecodeImpl) bool`。
- **作用**：strict 简单内联。
- **实现**：返回 `executionFlags().strict_simple_inline_eligible`，即发布时的 `simple_inline_base and strict_mode and !materializes_arguments_object`（`src/bytecode.zig:12226`）；`strict_mode` 取 `isStrictMode() or runtimeStrictMode()` 的并。
- **所有权 / 错误 / 调用**：纯位读、无 error set。对应 `src/exec/inline_calls.zig:1679` 的 `.strict` 臂选择与 `:1726`、`:2346` 的断言；热路径直读位域。


### `FunctionBytecode.strictSimpleSnapshotInlineEligible` (`src/bytecode.zig:4063`)

- **签名**：`pub inline fn strictSimpleSnapshotInlineEligible(self: *const FunctionBytecodeImpl) bool`。
- **作用**：strict 且物化 arguments 的快照内联。
- **实现**：返回 `executionFlags().strict_simple_snapshot_inline_eligible`，即 `simple_inline_base and strict_mode and materializes_arguments_object`（`src/bytecode.zig:12227`）——与上一位互斥，专门覆盖 strict 下需要 unmapped `arguments` 快照的函数。
- **所有权 / 错误 / 调用**：纯位读、无 error set。对应 `src/exec/inline_calls.zig:1680` 的 `.strict_snapshot` 臂以及 `:1696`、`:1724`、`:2343`、`:3512` 的分流与断言。


### `FunctionBytecode.simpleInlineEmptyLeaf` (`src/bytecode.zig:4066`)

- **签名**：`pub inline fn simpleInlineEmptyLeaf(self: *const FunctionBytecodeImpl) bool`。
- **作用**：零参 sloppy 空叶。
- **实现**：返回 `executionFlags().simple_inline_empty_leaf`，即 `simple_inline_base and !strict_mode and empty_leaf_geometry`（`src/bytecode.zig:12228`）；`empty_leaf_geometry` 要求 `arg_count == 0`、无闭包变量、`var_count == 0`、无 open var ref、不物化 `arguments`、无直接 eval，且栈 BFS 证明返回时栈平衡。
- **所有权 / 错误 / 调用**：纯位读、无 error set。`src/exec/inline_calls.zig:3398` 在 `argc == 0` 时据此走空叶臂，`:1260`、`:2562`-`:2565` 用于臂选择与断言。


### `FunctionBytecode.rawThisInlineEmptyLeaf` (`src/bytecode.zig:4069`)

- **签名**：`pub inline fn rawThisInlineEmptyLeaf(self: *const FunctionBytecodeImpl) bool`。
- **作用**：零参 strict 空叶。
- **实现**：返回 `executionFlags().raw_this_inline_empty_leaf`，即上一位的 strict 对偶 `simple_inline_base and strict_mode and empty_leaf_geometry`（`src/bytecode.zig:12229`）；strict 下 `this` 不做 ToObject 包装，因此内联臂可以原样转发接收者。
- **所有权 / 错误 / 调用**：纯位读、无 error set。`src/exec/inline_calls.zig:3401` 选 `.raw_undefined` 空叶臂，`:1260`、`:2563` 参与判定与断言。


### `FunctionBytecode.simpleInlineExactArgsLeaf` (`src/bytecode.zig:4072`)

- **签名**：`pub inline fn simpleInlineExactArgsLeaf(self: *const FunctionBytecodeImpl) bool`。
- **作用**：精确 argc 的 sloppy 叶。
- **实现**：返回 `executionFlags().simple_inline_exact_args_leaf`，发布式为 `simple_inline_base and !strict_mode and arg_count > 0 and leaf_body_geometry`（`src/bytecode.zig:12230`）——比空叶少一条 `arg_count == 0` 与栈平衡要求，改为要求实参数正好等于形参数时才走。
- **所有权 / 错误 / 调用**：纯位读、无 error set。对应 `src/exec/inline_calls.zig:2576`、`:2578` 的臂断言；分类结果同时被压进 `exact_args_leaf_kind` 供一次读出。


### `FunctionBytecode.rawThisInlineExactArgsLeaf` (`src/bytecode.zig:4075`)

- **签名**：`pub inline fn rawThisInlineExactArgsLeaf(self: *const FunctionBytecodeImpl) bool`。
- **作用**：精确 argc 的 strict 叶。
- **实现**：返回 `executionFlags().raw_this_inline_exact_args_leaf`，即 `simple_inline_base and strict_mode and arg_count > 0 and leaf_body_geometry`（`src/bytecode.zig:12231`），与 sloppy 版本互斥。
- **所有权 / 错误 / 调用**：纯位读、无 error set。对应 `src/exec/inline_calls.zig:2577`、`:2578` 的 `.raw_undefined`/`.receiver` 臂断言。


### `FunctionBytecode.exactArgsLeafKind` (`src/bytecode.zig:4078`)

- **签名**：`pub inline fn exactArgsLeafKind(self: *const FunctionBytecodeImpl) ExactArgsLeafKind`。
- **作用**：fused 精确-argc 分类。
- **实现**：返回 `executionFlags().exact_args_leaf_kind`，一个 `u2` 的 `ExactArgsLeafKind`：发布时 `sloppy_exact` → `.sloppy`、`raw_exact` → `.raw_this`、都不成立 → `.none`（`src/bytecode.zig:12232`）。把上面两个互斥布尔位融成一个枚举，使调用解析一次比较就能分臂。
- **所有权 / 错误 / 调用**：纯位读、无 error set。`src/exec/inline_calls.zig:1261` 用 `== .none` 作为「既非空叶也非精确叶」的早退条件。


### `FunctionBytecode.captureLeafKind` (`src/bytecode.zig:4081`)

- **签名**：`pub inline fn captureLeafKind(self: *const FunctionBytecodeImpl) ExactArgsLeafKind`。
- **作用**：零参捕获叶分类。
- **实现**：返回 `executionFlags().capture_leaf_kind`：发布时要求 `simple_inline_base`、`arg_count == 0`、`closureVarCount() > 0` 且满足 `leaf_body_geometry`，按 strict 与否取 `.raw_this` / `.sloppy`，否则 `.none`（`src/bytecode.zig:12233`）。与 `exact_args_leaf_kind` 的区别是它专门覆盖「无参但有闭包捕获」的叶函数。
- **所有权 / 错误 / 调用**：纯位读、无 error set。`src/exec/inline_calls.zig:2589` 从 `call_facts.execution.capture_leaf_kind` 直读该分类来选捕获叶臂。


### `FunctionBytecode.smallInlineEligible` (`src/bytecode.zig:4084`)

- **签名**：`pub inline fn smallInlineEligible(self: *const FunctionBytecodeImpl) bool`。
- **作用**：几何-only 小函数展开候选。
- **实现**：返回 `executionFlags().small_inline_eligible`。该位等于 `scanSmallInlineEligible(...) and leaf_returns_balanced`（`src/bytecode.zig:12213`，扫描函数本体在 `:12093`）：扫描要求 `functionKind() == .normal`、非派生构造器、形参表简单、不物化 `arguments`、无直接 eval、无闭包/开放 var ref，且代码 ≤ `small_inline_max_code`(40) 字节、`arg_count + var_count` ≤ 4、`stack_size` ≤ 4，并逐条指令检查 `inline_policy` 不是 `forbidden`（`ext0` 载体还要下钻到 sub-form）。
- **所有权 / 错误 / 调用**：纯位读、无 error set。这是本组中唯一在生产 Zig 里以 getter 形式被读的：OPT-R10 的体展开路径经 `src/exec/small_inline.zig` 查询；`publishExecutionFlags` 同时把发布字节数累加进 `runtime.small_inline_published_bytes`。


### `FunctionBytecode.applyForwardInlined` (`src/bytecode.zig:4087`)

- **签名**：`pub inline fn applyForwardInlined(self: *const FunctionBytecodeImpl) bool`。
- **作用**：是否含 L1 `call_method_apply_fwd`。
- **实现**：返回 `executionFlags().apply_forward_inlined`。与本组其余位不同，它不是 `publishExecutionFlags` 写的发布期常量，而是运行期由 `markApplyForwardInlined`（`src/exec/small_inline.zig:203`）在真正改写出 apply-forward 站点后读-改-写回去的粘滞位（经 `setExecutionFlags`，同时刷新头内 `call_facts_mirror`）。
- **所有权 / 错误 / 调用**：纯位读、无 error set。消费者是构造器 TAKE 与 D8-L1 native_caller 的 attach 判定；普通 `op_call_method` 不查这一位。


### `FunctionBytecode.pc2lineBuf` (`src/bytecode.zig:4090`)

- **签名**：`pub inline fn pc2lineBuf(self: *const FunctionBytecodeImpl) []u8`。
- **作用**：pc2line 字节。独立分配，不在主 FAM。
- **实现**：debug.pc2line_buf+len；0 则空。
- **所有权 / 错误 / 调用**：deinit 时 mem.free。


### `FunctionBytecode.lineNum` (`src/bytecode.zig:4102`)

- **签名**：`pub inline fn lineNum(self: *const FunctionBytecodeImpl) i32`。
- **作用**：起始行：优先解 pc2line 头；空 fixture 才回落到 adapter.line_num。
- **实现**：decodeHeader 失败当 0，不落到 adapter。
- **所有权 / 错误 / 调用**：不分配、无 error set：pc2line 头解码失败被 `else |_| return 0` 吞掉，只有缓冲为空时才回落到 adapter 的并行坐标。调用方 `src/exec/exception_ops.zig:475`/`:493` 组装错误站点，`src/exec/small_inline.zig:1399`/`:1412` 组装内联站点记录。


### `FunctionBytecode.colNum` (`src/bytecode.zig:4114`)

- **签名**：`pub inline fn colNum(self: *const FunctionBytecodeImpl) i32`。
- **作用**：起始列，规则同 lineNum。
- **实现**：decodeHeader。
- **所有权 / 错误 / 调用**：与 `lineNum` 同协议：不分配、无 error set，解码失败返回 0。调用方同样是 `src/exec/exception_ops.zig:475`/`:494` 与 `src/exec/small_inline.zig:1400`/`:1413`。


### `FunctionBytecode.sourceText` (`src/bytecode.zig:4126`)

- **签名**：`pub inline fn sourceText(self: *const FunctionBytecodeImpl) ?[]const u8`。
- **作用**：原始源，NUL 分配的逻辑长度 source_len。
- **实现**：legacy 返回 null。
- **所有权 / 错误 / 调用**：独立分配。


### `FunctionBytecode.scriptOrModule` (`src/bytecode.zig:4134`)

- **签名**：`pub inline fn scriptOrModule(self: *const FunctionBytecodeImpl) atom.Atom`。
- **作用**：动态 import referrer：hot.script_or_module，空则 filename。
- **实现**：legacy 用 Bytecode 字段。
- **所有权 / 错误 / 调用**：atom。


### `FunctionBytecode.callSiteCount` (`src/bytecode.zig:4144`)

- **签名**：`pub inline fn callSiteCount(self: *const FunctionBytecodeImpl) u16`。
- **作用**：call-site 槽数。
- **实现**：hot.call_site_count，无 extension 则 0。
- **所有权 / 错误 / 调用**：解释器当前不读这些槽。


### `FunctionBytecode.callSiteCache` (`src/bytecode.zig:4152`)

- **签名**：`pub inline fn callSiteCache(self: *const FunctionBytecodeImpl, idx: u8) ?*function_bytecode.CallSiteCache`。
- **作用**：按 cache_idx 取槽；255 或越界 null。
- **实现**：24 字节 CallSiteCache。
- **所有权 / 错误 / 调用**：JIT 反馈槽，非 GC 边。


### `FunctionBytecode.propSiteCount` (`src/bytecode.zig:4161`)

- **签名**：`pub inline fn propSiteCount(self: *const FunctionBytecodeImpl) u16`。
- **作用**：W1 属性站点槽数。
- **实现**：hot.prop_site_count。
- **所有权 / 错误 / 调用**：借用读、不分配、无 error set；无扩展尾返回 0。生产树内无调用方——解释器读帧上的 `Vm.prop_sites`/`prop_site_count`（`src/exec/tailcall_dispatch.zig:215`），编译侧写的是 `Bytecode.prop_site_count` 字段（`src/compiler/resolve_labels.zig:3680`）；本 getter 只被 `src/tests/parser.zig:3592`/`:3639` 用于发布对账。


### `FunctionBytecode.propSiteCache` (`src/bytecode.zig:4172`)

- **签名**：`pub inline fn propSiteCache(self: *const FunctionBytecodeImpl, idx: u8) ?*function_bytecode.PropSiteCache`。
- **作用**：按 cache_idx 取 32 字节 PropSiteCache。
- **实现**：驻留 handler 不走这里，而读帧上发布的 `Vm.prop_sites`。
- **所有权 / 错误 / 调用**：无堆指针。


### `FunctionBytecode.createRaw` (`src/bytecode.zig:4180`)

- **签名**：`fn createRaw( account: *memory.MemoryAccount, layout_value: function_bytecode.FunctionLayout, ) !*FunctionBytecodeImpl`。
- **作用**：分配核心头+FAM，零填，置 debug/extension 位并 seedHeader。
- **实现**：`createWithFam`；cpool 槽填 undefined；断言 ROM 位为 0。
- **所有权 / 错误 / 调用**：失败返回分配错误。调用方尚未把对象交给 GC。


### `FunctionBytecode.createProductionShell` (`src/bytecode.zig:4203`)

- **签名**：`pub fn createProductionShell(account: *memory.MemoryAccount, layout_value: function_bytecode.FunctionLayout) !*FunctionBytecodeImpl`。
- **作用**：生产主分配的唯一入口：必须有 debug 与 extension。
- **实现**：断言后 `createRaw`。此时还没有 atom/value 所有权，直到 finalize 的 no-fail commit。
- **所有权 / 错误 / 调用**：errdefer destroyWithFam。


### `FunctionBytecode.createFixture` (`src/bytecode.zig:4236`)

- **签名**：`pub fn createFixture(rt: *runtime.JSRuntime, options: FixtureOptions) !*FunctionBytecodeImpl`。
- **作用**：测试夹具：同一 packed 拓扑，可省略 debug/extension。
- **实现**：`defined_arg_count > arg_count` 直接 `error.BytecodeOverflow`；`script_or_module != null_atom` 会强制 has_extension；算 layout；createRaw；memcpy 代码；applyFlags 与 defined_arg_count/stack_size/var_ref_count 回填；func_name（及 has_debug 时的 filename）经 `noteHolderStore`；可选 realm retain。
- **所有权 / 错误 / 调用**：返回未发布对象；失败走 destroyWithFam。随后 `publishFixtureNoFail` 或 `destroyUnpublishedFixture`。


### `FunctionBytecode.destroyUnpublishedFixture` (`src/bytecode.zig:4276`)

- **签名**：`pub fn destroyUnpublishedFixture(self: *FunctionBytecodeImpl, rt: *runtime.JSRuntime) void`。
- **作用**：销毁尚未 GC 发布的夹具。
- **实现**：deinitWithLayout + destroyWithFam。
- **所有权 / 错误 / 调用**：不得对已 addInitialized 的对象调用。


### `FunctionBytecode.publishFixtureNoFail` (`src/bytecode.zig:4284`)

- **签名**：`pub fn publishFixtureNoFail(self: *FunctionBytecodeImpl, rt: *runtime.JSRuntime) void`。
- **作用**：夹具事务的无失败发布。
- **实现**：`gc.addInitializedWithSizeNoFail`。所有 fallible 边必须事先备好。
- **所有权 / 错误 / 调用**：此后生命周期归 GC。


### `FunctionBytecode.realmContext` (`src/bytecode.zig:4288`)

- **签名**：`pub inline fn realmContext(self: *const FunctionBytecodeImpl) ?*context.RealmContext`。
- **作用**：借出编译 realm：先读头上 RealmRef，空再走 slow（hot pad 里的借用指针或 legacy）。
- **实现**：生产输出保证有 realm。
- **所有权 / 错误 / 调用**：非拥有。


### `FunctionBytecode.realmContextSlow` (`src/bytecode.zig:4297`)

- **签名**：`noinline fn realmContextSlow(self: *const FunctionBytecodeImpl) ?*context.RealmContext`。
- **作用**：头上 RealmRef 为空时的回退：next-entry inline spec 的 hot-pad 借用指针，或 legacy adapter 的 realm。
- **实现**：读 `hotExtension()` 的 `_ctor_alloc_pad` 后半 usize（little-endian）。非 0 且非 `0xaaaaaaaaaaaaaaaa` 哨兵则 `@ptrFromInt`。否则 `legacyBytecodeAdapter()?.realm`，再否则 null。对照附录 B：inline spec 把入口 realm 放在 hot pad 而不是 RealmRef，GC 不访问、不 retain。
- **所有权 / 错误 / 调用**：返回借用指针。生产 FB 的 `realm.borrow()` 已命中，不进这里。


### `FunctionBytecode.hasAtomOperandFmt` (`src/bytecode.zig:4313`)

- **签名**：`inline fn hasAtomOperandFmt(op_id: u8) bool`。
- **作用**：最终 Format 是否把 4 字节 atom 放在 pc+1。
- **实现**：atom / atom_u8 / atom_cache_u8 / atom_u16 / atom_label_*。
- **所有权 / 错误 / 调用**：inline。


### `FunctionBytecode.BytecodeAtomIterator.next` (`src/bytecode.zig:4328`)

- **签名**：`pub fn next(self: *BytecodeAtomIterator) ?atom.Atom`。
- **作用**：按字节码顺序产出下一条 atom 操作数。
- **实现**：size 0（未知 id）停止；无 atom 的指令跳过。不碰 refcount。
- **所有权 / 错误 / 调用**：产出借用 atom，不转移所有权。实际调用方是 GC 的 atom 遍历 `traceFunctionBytecodeAtoms`（`src/core/gc_trace_stw.zig:173`）；源码注释提到的 direct-eval 扫描是它替代的旧 `atom_operands` 数组的用途。


### `FunctionBytecode.atomOperandIterator` (`src/bytecode.zig:4346`)

- **签名**：`pub fn atomOperandIterator(self: *const FunctionBytecodeImpl) BytecodeAtomIterator`。
- **作用**：从本 FB 的 byteCode 构造迭代器。
- **实现**：`.{ .byte_code = self.byteCode() }`。
- **所有权 / 错误 / 调用**：GC 的 `traceFunctionBytecodeAtoms` 与单测使用。


### `FunctionBytecode.deinit` (`src/bytecode.zig:4350`)

- **签名**：`pub fn deinit(self: *FunctionBytecodeImpl, rt: anytype) void`。
- **作用**：释放拥有者后由调用方 destroy FAM。
- **实现**：`deinitWithLayout(self.layout())`。
- **所有权 / 错误 / 调用**：GC finalizer 走 destroyFromHeader。


### `FunctionBytecode.deinitWithLayout` (`src/bytecode.zig:4354`)

- **签名**：`fn deinitWithLayout( self: *FunctionBytecodeImpl, rt: anytype, layout_value: function_bytecode.FunctionLayout, ) void`。
- **作用**：按 QuickJS `free_function_bytecode` 顺序清指针：small-inline 回调、代码、vardefs、cpool、closure、realm、func_name、debug 的 pc2line/source、hot.script_or_module。
- **实现**：先捕获 layout 视图再清指针。GC deinit 阶段 `restoreSizing` 以便 Pass B 重建 FAM 长度。内联 atom 操作数、vardef 表与 closure 行在 tracing GC 下都是纯值，原先那次 `freeBytecodeAtoms` 重走代码的空操作（以及只为它取出的 `byte_code`/`vardefs`/`closure_var` 局部）已删。
- **所有权 / 错误 / 调用**：不释放主 FAM 本身。


### `FunctionBytecode.heapByteSize` (`src/bytecode.zig:4433`)

- **签名**：`pub fn heapByteSize(self: *const FunctionBytecodeImpl) usize`。
- **作用**：记账用字节：主 payload + 独立 pc2line + source(+1 NUL)。
- **实现**：layout.mainPayloadBytes 再加 debug 侧盒。
- **所有权 / 错误 / 调用**：addInitializedWithSize。


### `FunctionBytecode.heapByteSizeWithLayout` (`src/bytecode.zig:4437`)

- **签名**：`fn heapByteSizeWithLayout( self: *const FunctionBytecodeImpl, layout_value: function_bytecode.FunctionLayout, ) usize`。
- **作用**：带已算 layout 的版本。
- **实现**：饱和加法。
- **所有权 / 错误 / 调用**：私有；纯算术，不分配、无 error set，溢出经 `addSaturating` 饱和到 `maxInt(usize)` 而不是 panic。两个调用方：`heapByteSize`（`src/bytecode.zig:4668`）与 finalize 的发布点 `src/bytecode.zig:10970`（`addInitializedWithSizeNoFail`，复用已算好的 layout，免得再解析一次头）。


### `FunctionLayout.init` (`src/bytecode.zig:4484`)

- **签名**：`pub fn init( has_debug: bool, has_extension: bool, cpool_count: usize, arg_count: usize, var_count: usize, closure_var_count: usize, byte_code_len: usize, call_site_count: usize, prop_site_count: usize, ) error{BytecodeOverflow}!@This()`。
- **作用**：唯一检查过的 packed 布局计算器。
- **实现**：校验 u16/i32/cache_idx≤255 与 extension 约束。偏移：88 字节核心 | 可选 32B DebugInfo | cpool | vardefs(arg+var) | closure | exact code | 可选 64B hot（hot_off==code_end）| 8 对齐 call_sites | 8 对齐 prop_sites。核心段无插入 padding。溢出 `BytecodeOverflow`。
- **所有权 / 错误 / 调用**：偏移相对 FunctionBytecodeImpl 基址（zjs 核心头 88 字节；源码注释里的「96」对应 QuickJS 16 字节 GC 头）。


### `FunctionLayout.fromFunction` (`src/bytecode.zig:4566`)

- **签名**：`pub fn fromFunction(fb: *const FunctionBytecodeImpl) error{ InvalidBytecode, BytecodeOverflow }!@This()`。
- **作用**：从已填好的 FB 头重建 layout，必要时再读 hot 里的 slot 计数。
- **实现**：负计数 InvalidBytecode。先按 slot=0 算以定位 hot，再按真实 call/prop 计数重算。
- **所有权 / 错误 / 调用**：不能经 `hotExtension()` 读——空代码臂会再调 layout()。


### `FunctionLayout.famBytes` (`src/bytecode.zig:4601`)

- **签名**：`pub inline fn famBytes(self: @This()) usize`。
- **作用**：total - 88。
- **实现**：给 createWithFam。
- **所有权 / 错误 / 调用**：纯算术，不分配、无 error set。它是 `createWithFam`/`destroyWithFam` 的长度参数权威：`src/bytecode.zig:4371` 分配、`:4439` 与 `:4944` 释放、`src/exec/small_inline.zig:1167` 的 errdefer；`FunctionBytecode.famBytes`（`src/bytecode.zig:3861`）只是转发。


### `FunctionLayout.mainPayloadBytes` (`src/bytecode.zig:4605`)

- **签名**：`pub inline fn mainPayloadBytes(self: @This()) usize`。
- **作用**：整块主分配大小。
- **实现**：total_size。
- **所有权 / 错误 / 调用**：纯字段读（`total_size`），不分配、无 error set。两个调用方：`createRaw` 用它把整个主分配清零（`src/bytecode.zig:4373`），`heapByteSizeWithLayout` 用它作 GC 计价的基数（`:4675`）。


### `FunctionLayout.cpoolSliceMut` (`src/bytecode.zig:4609`)

- **签名**：`pub fn cpoolSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []JSValue`。
- **作用**：FAM 内 cpool 可变切片。
- **实现**：packedSlice。
- **所有权 / 错误 / 调用**：finalize 填值。


### `FunctionLayout.vardefsSliceMut` (`src/bytecode.zig:4613`)

- **签名**：`pub fn vardefsSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []BytecodeVarDef`。
- **作用**：连续 args+locals。
- **实现**：packedSlice。
- **所有权 / 错误 / 调用**：返回 FAM 内的可变借用切片，不拥有内存、不分配、无 error set；越界由 `packedSlice` 的 `offset + len*@sizeOf(T) <= total_size` 断言守。调用方：`seedHeader` 建头内指针（`src/bytecode.zig:4881`）、finalize 填行（`:10868`）、`deinitWithLayout` 读回清 atom（`:4593`）、small-inline 复制 vardef（`src/exec/small_inline.zig:1206`）。


### `FunctionLayout.closureVarSliceMut` (`src/bytecode.zig:4617`)

- **签名**：`pub fn closureVarSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []BytecodeClosureVar`。
- **作用**：闭包行。
- **实现**：packedSlice。
- **所有权 / 错误 / 调用**：同 `vardefsSliceMut` 的 closure 行版本：FAM 内可变借用、不分配、无 error set。调用方 `seedHeader`（`src/bytecode.zig:4882`）、finalize（`:10878`）、`deinitWithLayout`（`:4595`）、`src/exec/small_inline.zig:1217`。


### `FunctionLayout.byteCodeSliceMut` (`src/bytecode.zig:4621`)

- **签名**：`pub fn byteCodeSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []u8`。
- **作用**：精确代码字节。
- **实现**：packedSlice u8。
- **所有权 / 错误 / 调用**：FAM 内可变借用切片，不分配、无 error set。调用方：`seedHeader`（`src/bytecode.zig:4883`）、`createFixture` 拷入夹具码（`:4441`）、finalize 拷入最终码（`:10884`）、`deinitWithLayout` 在释放前遍历 atom 操作数（`:4592`）、`src/exec/small_inline.zig:1196`。


### `FunctionLayout.callSitesSliceMut` (`src/bytecode.zig:4625`)

- **签名**：`pub fn callSitesSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []function_bytecode.CallSiteCache`。
- **作用**：24B×N，无槽则空。
- **实现**：对齐偏移。
- **所有权 / 错误 / 调用**：seedHeader 写指针。


### `FunctionLayout.propSitesSliceMut` (`src/bytecode.zig:4630`)

- **签名**：`pub fn propSitesSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []function_bytecode.PropSiteCache`。
- **作用**：32B×N。
- **实现**：对齐偏移。
- **所有权 / 错误 / 调用**：FAM 内可变借用切片，`prop_sites_off` 缺失时返回空切片；不分配、无 error set。树内唯一调用方是 `seedHeader`（`src/bytecode.zig:4892`），它把 ptr/count 写进热尾，此后解释器只经 `Vm.prop_sites` 访问这些槽。


### `FunctionLayout.hotExtensionPtrMut` (`src/bytecode.zig:4635`)

- **签名**：`fn hotExtensionPtrMut(self: @This(), fb: *FunctionBytecodeImpl) ?*align(1) FunctionBytecodeHotExtension`。
- **作用**：code_end 处的 align(1) 指针。
- **实现**：无 extension 则 null。
- **所有权 / 错误 / 调用**：私有；返回 FAM 内 `*align(1)` 可变借用指针，`hot_off` 缺失（无扩展尾）时为 `null`；不分配、无 error set。三个调用方：`seedHeader` 写 call/prop site 指针（`src/bytecode.zig:4888`）、`deinitWithLayout` 清 `script_or_module`（`:4590`）、finalize 的发布点 `:10861`（那里用 `.?` 强解，因为生产壳恒有扩展尾）。


### `FunctionLayout.seedHeader` (`src/bytecode.zig:4641`)

- **签名**：`fn seedHeader(self: @This(), fb: *FunctionBytecodeImpl) void`。
- **作用**：把计数与自指针写进头和 hot，必须在任何 extension 访问器之前。
- **实现**：空切片写 null 指针。call/prop 指针与 count 一并写入 hot。
- **所有权 / 错误 / 调用**：createRaw 调用。


### `FunctionLayout.restoreSizing` (`src/bytecode.zig:4665`)

- **签名**：`fn restoreSizing(self: @This(), fb: *FunctionBytecodeImpl) void`。
- **作用**：deinit 后只恢复五个长度字段，供 GC 重建 FAM。
- **实现**：不恢复指针。
- **所有权 / 错误 / 调用**：phase==.deinit。


### `function_bytecode.packedSlice` (`src/bytecode.zig:4674`)

- **签名**：`fn packedSlice( fb: *FunctionBytecodeImpl, comptime T: type, offset: usize, len: usize, total_size: usize, ) []T`。
- **作用**：从 FB 基址+offset 做出 `[]T`，并断言不越界。
- **实现**：len 0 空切片；否则 alignCast。
- **所有权 / 错误 / 调用**：私有，不分配、无 error set；`len == 0` 返回空切片，否则断言 `offset + len*@sizeOf(T) <= total_size` 后把 FAM 字节重解释成 `[]T`（对齐由 `FunctionLayout.init` 算出的偏移保证）。六个调用方都是 `FunctionLayout` 的 `*SliceMut`（`src/bytecode.zig:4843`-`:4865`）。


### `function_bytecode.addSliceBytes` (`src/bytecode.zig:4689`)

- **签名**：`fn addSliceBytes(total: usize, comptime T: type, len: usize) usize`。
- **作用**：total + sizeOf(T)*len，饱和。
- **实现**：mul catch maxInt。
- **所有权 / 错误 / 调用**：heapByteSize。


### `function_bytecode.addSaturating` (`src/bytecode.zig:4694`)

- **签名**：`fn addSaturating(a: usize, b: usize) usize`。
- **作用**：饱和加法。
- **实现**：add catch maxInt。
- **所有权 / 错误 / 调用**：私有，纯算术，不分配、无 error set；溢出不 panic 而是饱和到 `maxInt(usize)`，让 GC 计价在病态尺寸下仍给出一个上界。调用方 `addSliceBytes`（`src/bytecode.zig:4924`）与 `heapByteSizeWithLayout`（`:4678`）。


### `function_bytecode.destroyFromHeader` (`src/bytecode.zig:4698`)

- **签名**：`pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void`。
- **作用**：header → FB，deinitWithLayout，destroyWithFam。
- **实现**：TGC S4-e：无 Pass-B 推迟；Runtime teardown 已保证顺序。
- **所有权 / 错误 / 调用**：finalizer。


## 覆盖核对

- 清单函数数（本文件分组）: 128（`src/bytecode.zig` 全文件 507）
- 本文标题覆盖: 128
- 未覆盖: 无
