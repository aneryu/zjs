# 05 — pc2line、栈深、finalize

三个仍住在 `bytecode.zig` 里的管线命名空间（不是独立的 `stack_size.zig`）。

## pc2line（Phase 3b，quickjs.c:33995）

与 QuickJS **字节兼容**：

1. 头：两个 ULEB128，**零基** 起始行列（引擎侧一基，编的时候 `-1`）。
2. 每个相对上一槽的 (Δpc, Δline, Δcol)：
   - Δpc<0 或行列都不变 → 跳过
   - 紧凑：`-1 ≤ Δline < 4` 且 `Δpc ≤ 50` → 单字节 `(Δline+1) + Δpc*5 + 1` + sleb(Δcol)
   - 长：`0` + leb(Δpc) + sleb(Δline) + sleb(Δcol)
3. sleb 是 zig-zag 后的 ULEB（`dbuf_put_sleb128`）。

两遍编码：先测量再精确 alloc，没有 shrink/copy。pc2line 是 **独立分配**，不进主 FAM。

## stack-size（Phase 3c，quickjs.c:35167）

对 **已经 resolve_labels** 的最终码做 BFS：

- 同一 pc 不得以不同栈高再访问（`StackMismatch`）
- 不得欠弹（`StackUnderflow`）或超过 `JS_STACK_SIZE_MAX=0xFFFE`
- 空码或可达 fall-off 过末尾 → `ReachableFalloff`（生产体每条路径必须有终结符）
- 效应来自 `opcode.decode.stackEffect`（声明），控制流按 **logical form** 而不是物理 id
- 可选融合 `FinalArtifactValidator`：atom ledger 与 closure 下标的线性证明；失败优先报栈错误，栈过了再报 `InvalidFinalArtifact`
- 可选 `returns_balanced_out`：每个 `return`/`return_undef` 弹完值后栈是否为空（给 empty-leaf 发布，不是合法性门）

## finalize（`js_create_function`，quickjs.c:35401）

```
validateRuntimeIdentity
installChildFunctionBytecodes      -- 先子后己，子 FB 进父 cpool
createFunctionBytecodeAfterChildren
    validatePreLoweringArtifactShape
    compileFunctionForPackedFinalize
    consumeGlobalVars, state=resolved
    publishLoweredMetadata
        pc2line.encode → stack_size.compute(+artifact proof)
    validateFinalArtifactShape
    FunctionLayout.init(debug+extension)
    createProductionShell
    填 FAM（代码、vardefs、closure）
    ——以下是 no-fail commit——
    applyFlags / RealmRef.retain
    搬 name/filename/cpool 值、source / pc2line 独立所有者
    publishExecutionFlags
    gc.addInitializedWithSizeNoFail
```

没有二进制字节码阅读器；ROM 位永久为 0。

## 函数



### `pipeline_pc2line`

### `pipeline_pc2line.Encoded.deinit` (`src/bytecode/pc2line.zig:57`)

- **签名**：`pub fn deinit(self: *Encoded) void`。
- **作用**：释放编码缓冲。
- **实现**：摘下 bytes 再 memory.free。
- **所有权 / 错误 / 调用**：encode 的调用方拥有。


### `pipeline_pc2line.encode` (`src/bytecode/pc2line.zig:69`)

- **签名**：`pub fn encode( account: *memory.MemoryAccount, slots: []const SourceLocSlot, start_line_num: i32, start_col_num: i32, ) !Encoded`。
- **作用**：把 SourceLocSlot 编成 QuickJS 字节兼容的 pc2line。
- **实现**：第一遍 Encoder 只计数；alloc 精确大小；第二遍写入。长度不一致 Pc2LineOverflow。
- **所有权 / 错误 / 调用**：account 记账。头是两个 ULEB128 零基行列。


### `pipeline_pc2line.Encoder.putByte` (`src/bytecode/pc2line.zig:95`)

- **签名**：`fn putByte(self: *Encoder, byte: u8) !void`。
- **作用**：写一字节或只推进 index。
- **实现**：output==null 时纯测量。加法溢出 Pc2LineOverflow。
- **所有权 / 错误 / 调用**：不分配：`Encoder.output` 为 null 时只累加 `index`（度量遍），非 null 时写进 `encode` 已按度量值分配好的那一块。溢出或越界返回 `error.Pc2LineOverflow`。`pipeline_pc2line` 私有，调用方 `putLeb128`（`bytecode.zig:6234`、`:6237`）与 `encodeInto`（`:6277`、`:6281`）。


### `pipeline_pc2line.Encoder.putLeb128` (`src/bytecode/pc2line.zig:104`)

- **签名**：`fn putLeb128(self: *Encoder, value: u32) !void`。
- **作用**：无符号 LEB128。
- **实现**：低 7 位，续 bit7。
- **所有权 / 错误 / 调用**：不分配，逐字节转发给 `putByte`，错误同上（`error.Pc2LineOverflow`）。私有，调用方 `putSleb128`（`bytecode.zig:6246`）与 `encodeInto`（`:6259`、`:6260`、`:6282`）。


### `pipeline_pc2line.Encoder.putSleb128` (`src/bytecode/pc2line.zig:117`)

- **签名**：`fn putSleb128(self: *Encoder, value: i32) !void`。
- **作用**：zig-zag 后 ULEB128，对齐 qjs dbuf_put_sleb128。
- **实现**：`(bits<<1) ^ (0 - bits>>31)`。
- **所有权 / 错误 / 调用**：不分配；zig-zag 后转 `putLeb128`，错误同上。私有，唯一调用方 `encodeInto`（`bytecode.zig:6283`、`:6285`）。


### `pipeline_pc2line.encodeInto` (`src/bytecode/pc2line.zig:126`)

- **签名**：`fn encodeInto( encoder: *Encoder, slots: []const SourceLocSlot, start_line_num: i32, start_col_num: i32, ) !void`。
- **作用**：真正的差分编码。
- **实现**：起始行列必须 >0，存成零基。pc 回退的槽跳过；行列都不变跳过。紧凑：行差落在 `PC2LINE_BASE ≤ Δline < PC2LINE_BASE+PC2LINE_RANGE`（即 -1..3）且 pc 差 ≤ `PC2LINE_DIFF_PC_MAX`(50) 时单字节+sleb col；否则 0 + leb pc + sleb line + sleb col。
- **所有权 / 错误 / 调用**：quickjs.c:33995。


### `pipeline_pc2line.decodeHeader` (`src/bytecode/pc2line.zig:178`)

- **签名**：`pub fn decodeHeader(bytes: []const u8) !Header`。
- **作用**：不解完整表，只读两个 ULEB 头并 +1 变一基。
- **实现**：maxInt 哨兵当 Overflow。
- **所有权 / 错误 / 调用**：lineNum/colNum / findSourceLocation。


### `pipeline_pc2line.decode` (`src/bytecode/pc2line.zig:195`)

- **签名**：`pub fn decode( allocator: std.mem.Allocator, encoded: Encoded, ) ![]SourceLocSlot`。
- **作用**：完整逆变换成 SourceLocSlot 切片。
- **实现**：op==0 长形式，否则拆 compact 字节。调用方 allocator。
- **所有权 / 错误 / 调用**：测试与栈追踪。


### `pipeline_pc2line.findSourceLocation` (`src/bytecode/pc2line.zig:238`)

- **签名**：`pub fn findSourceLocation(bytes: []const u8, target_pc: u32) !SourceLocSlot`。
- **作用**：目标 pc 的源位置；无槽或目标在首槽前则用函数定义处（头）。
- **实现**：与 qjs `find_line_num` 一样对畸形缓冲严格失败。
- **所有权 / 错误 / 调用**：栈追踪。


### `pipeline_pc2line.readLeb128` (`src/bytecode/pc2line.zig:279`)

- **签名**：`fn readLeb128(bytes: []const u8, i: *usize) !u32`。
- **作用**：读 ULEB，更新 index。
- **实现**：位移超 28 位（过长）→ `Pc2LineOverflow`；读到缓冲末尾 → `Pc2LineTruncated`。
- **所有权 / 错误 / 调用**：只读调用方给的 `bytes`，就地推进 `i`，不分配。截断返回 `error.Pc2LineTruncated`，移位超过 32 位返回 `error.Pc2LineOverflow`。私有，调用方 `decodeHeader`（`bytecode.zig:6304`、`:6305`）、`decode`（`:6335`）、`findSourceLocation`（`:6377`）、`readSleb128`（`:6420`）。


### `pipeline_pc2line.readSleb128` (`src/bytecode/pc2line.zig:295`)

- **签名**：`fn readSleb128(bytes: []const u8, i: *usize) !i32`。
- **作用**：读 zig-zag ULEB 再还原有符号。
- **实现**：对称。
- **所有权 / 错误 / 调用**：转发 `readLeb128` 后做 zig-zag 反变换，不分配，错误集与之相同。私有，调用方 `decode`（`bytecode.zig:6336`、`:6346`）与 `findSourceLocation`（`:6378`、`:6388`）。



### `pipeline_stack_size`

### `pipeline_stack_size.FinalArtifactValidator.validateKnownInstruction` (`src/compiler/stack_size.zig:112`)

- **签名**：`inline fn validateKnownInstruction( self: *FinalArtifactValidator, bytecode: []const u8, h: opcode.decode.Header, ) Error!void`。
- **作用**：线性证明一条已解码指令：ext0 标签必须是驻留或 add；atom 必须匹配 owner ledger；var_ref 下标 < closure_var_count。
- **实现**：inline 是负载：未 inline 时 CodeLoad +72M insn。burned var_ref 不再用 `id - get_var_ref0`。
- **所有权 / 错误 / 调用**：与 BFS 共享同一个 Header。


### `pipeline_stack_size.FinalArtifactValidator.validateBefore` (`src/compiler/stack_size.zig:163`)

- **签名**：`fn validateBefore( self: *FinalArtifactValidator, bytecode: []const u8, limit: usize, ) Error!void`。
- **作用**：把线性游标推进到 limit（可越过，为了畸形跳进操作数仍由栈验证器诊断）。
- **实现**：headerAt(.final) 失败当 InvalidFinalArtifact（reclaimed id 不得出现）。
- **所有权 / 错误 / 调用**：不分配；只线性推进 `self.pc` 走已有的 bytecode 切片。`headerAt` 失败一律折成 `error.InvalidFinalArtifact`（reclaimed id 因此被挡住）。私有，调用方 `finish`（`bytecode.zig:9752`）与 BFS 主循环 `compute`（`:9820`）。


### `pipeline_stack_size.FinalArtifactValidator.finish` (`src/compiler/stack_size.zig:175`)

- **签名**：`fn finish(self: *FinalArtifactValidator, bytecode: []const u8) Error!void`。
- **作用**：扫完整个缓冲且 atom owner 恰好用尽。
- **实现**：pc!=len 或 owner_index 不对 → InvalidFinalArtifact。
- **所有权 / 错误 / 调用**：compute 末尾。


### `pipeline_stack_size.compute` (`src/compiler/stack_size.zig:187`)

- **签名**：`pub fn compute(bytecode: []const u8, options: Options) Error!u16`。
- **作用**：BFS 求最大栈深，并可选融合最终产物证明与 return-balance。
- **实现**：空码 ReachableFalloff。每 pc 一张 ScratchRow（level/catch/pending）。seed(0,0,-1)。出队后 headerAt(.final)，stackEffect 算新高度，欠弹 Underflow，超过 0xFFFE Overflow。控制流按 logical form：`return`/`return_undef` 记 return-balance 后 continue，`return_async`/`throw`/`throw_error`/`tail_call*`/`ret` 直接 continue；goto 只 seed 目标；if_* 目标+fallthrough；gosub 目标高度+1；dyn_env_probe 用 branchStackDelta；catch 记录 catch_pos；nip_catch 恢复 catch 高度。同一 pc 不同高度 StackMismatch（在 seed）。产物不匹配先记住，栈证明成功后才报 InvalidFinalArtifact。
- **所有权 / 错误 / 调用**：scratch 优先 stackFallback。quickjs.c:35167。


### `pipeline_stack_size.seed` (`src/compiler/stack_size.zig:382`)

- **签名**：`fn seed( stack_level_tab: []u16, catch_pos_tab: []i32, pending_pc: []u32, pending_len: *usize, pos: u32, stack_len: u16, catch_pos: i32, ) Error!void`。
- **作用**：访问 pc：未访问则记下 level/catch 并入队；已访问则高度与 catch_pos 都必须相同。
- **实现**：STACK_LEVEL_UNVISITED=0xFFFF；`pos == len` 是 ReachableFalloff，`pos > len` 是 BytecodeOverflow。
- **所有权 / 错误 / 调用**：Mismatch / Overflow。


### `pipeline_stack_size.maybePopCatchPos` (`src/compiler/stack_size.zig:407`)

- **签名**：`fn maybePopCatchPos(bytecode: []const u8, stack_level_tab: []const u16, catch_pos_tab: []const i32, catch_pos: i32, catch_level: u16) i32`。
- **作用**：drop/nip/iterator_close 时按 catch 高度决定是否弹出 catch 链。
- **实现**：对齐 qjs 的 catch_pos 栈。
- **所有权 / 错误 / 调用**：纯读 `stack_level_tab` / `catch_pos_tab`，不分配、无 error set。私有，唯一调用方 `compute`（`bytecode.zig:9929`）。



### `pipeline_finalize`

### `pipeline_finalize.isVarInArgumentScope` (`src/compiler/finalize.zig:59`)

- **签名**：`fn isVarInArgumentScope(vd: function_def_mod.VarDef) bool`。
- **作用**：伪绑定是否属于参数环境（home_object/this_active_func/new.target/this/arg_var_object，或 var_kind 是 function_name）。
- **实现**：atom 或 var_kind 判断。
- **所有权 / 错误 / 调用**：addEvalVariables。


### `pipeline_finalize.captureEvalParentLocal` (`src/compiler/finalize.zig:68`)

- **签名**：`fn captureEvalParentLocal( target: *function_def_mod.FunctionDef, owner: *function_def_mod.FunctionDef, local_idx: usize, normalize_unscoped: bool, ) FinalizeError!void`。
- **作用**：eval 子函数捕获父局部；无作用域的祖先局部按 qjs 降成非 const NORMAL（函数名失去写保护）。
- **实现**：captureLocal + threadClosureSource(.local)。
- **所有权 / 错误 / 调用**：FinalizeError。


### `pipeline_finalize.captureEvalParentArg` (`src/compiler/finalize.zig:103`)

- **签名**：`fn captureEvalParentArg( target: *function_def_mod.FunctionDef, owner: *function_def_mod.FunctionDef, arg_idx: usize, ) FinalizeError!void`。
- **作用**：捕获父参数：保留 lexical，const/kind 普通化。
- **实现**：captureArg + threadClosureSource(.arg)。
- **所有权 / 错误 / 调用**：FinalizeError。


### `pipeline_finalize.addEvalVariables` (`src/compiler/finalize.zig:135`)

- **签名**：`fn addEvalVariables(fd: *function_def_mod.FunctionDef) FinalizeError!void`。
- **作用**：direct eval 把父链变量编进自己的 closure 表（qjs add_eval_variables）。
- **实现**：走父 FunctionDef 链，按作用域捕获 local/arg，并处理 var_object。
- **所有权 / 错误 / 调用**：finalize 在 lowering 前。


### `pipeline_finalize.addGlobalVariables` (`src/compiler/finalize.zig:261`)

- **签名**：`fn addGlobalVariables(fd: *function_def_mod.FunctionDef) FinalizeError!void`。
- **作用**：把 eval 根的 GlobalVar 降成闭包行（模块根用 `module_decl`，其余用 `global_decl`）。
- **实现**：非 eval 直接返回；非严格 direct eval 若闭包表里已有 var_object/arg_var_object 就不再造全局闭包行。带 cpool_idx 的非 lexical 项 var_kind 记 `global_function_decl`，其余 `normal`。
- **所有权 / 错误 / 调用**：模块根与 script 根。


### `pipeline_finalize.prepareCurrentBeforeChildren` (`src/compiler/finalize.zig:292`)

- **签名**：`fn prepareCurrentBeforeChildren( fd: *function_def_mod.FunctionDef, root_module_record: ?*module.Record, ) FinalizeError!void`。
- **作用**：在遍历子函数之前准备本 def：清掉 is_captured / open_binding_idx、重建最终作用域链、跑 addEvalVariables + addGlobalVariables，模块根再核对 import 闭包行并回填 export 的 var_idx。
- **实现**：要求自身 unprepared、父已 prepared、builder 存在；结束时 finalization_state 推进到 prepared。
- **所有权 / 错误 / 调用**：createFunctionBytecode 树走。


### `pipeline_finalize.validateOpenBindingIndices` (`src/compiler/finalize.zig:349`)

- **签名**：`fn validateOpenBindingIndices(fd: *const function_def_mod.FunctionDef, count: u16) FinalizeError!void`。
- **作用**：捕获行的 open_binding_idx 必须落在稠密 [0, count)。
- **实现**：越界 InvalidBytecode。
- **所有权 / 错误 / 调用**：**会分配**一块 `count` 长的 `bool` 位图（`fd.memory`，同函数 `defer` 释放），分配失败折成 `error.OutOfMemory`；索引重复或不稠密返回 `FinalizeError.InvalidBytecode`。私有，唯一调用方 `publishLoweredMetadata`（`bytecode.zig:11082`）。


### `pipeline_finalize.createFunctionBytecode` (`src/compiler/finalize.zig:386`)

- **签名**：`pub fn createFunctionBytecode(fd: *function_def_mod.FunctionDef, compile_context: CompileContext) FinalizeError![]fb_mod.FunctionBytecode`。
- **作用**：`js_create_function` 等价：先子后己，产出 GC FunctionBytecode。
- **实现**：校验 runtime 身份；`installChildFunctionBytecodes`；`createFunctionBytecodeAfterChildren`。可选 `ZJS_DISASM`。
- **所有权 / 错误 / 调用**：返回 `[]FunctionBytecode`（单元素切片指向 FAM 对象）。错误集 FinalizeError。


### `pipeline_finalize.createModuleFunctionBytecode` (`src/compiler/finalize.zig:397`)

- **签名**：`pub fn createModuleFunctionBytecode( fd: *function_def_mod.FunctionDef, record: *module.Record, compile_context: CompileContext, ) FinalizeError![]fb_mod.FunctionBytecode`。
- **作用**：模块根走同一拓扑；record 在子遍历前固定 local export 下标。
- **实现**：要求 fd.is_module，且 record 与 fd 共享 memory/atoms。
- **所有权 / 错误 / 调用**：borrow record。


### `pipeline_finalize.validateRuntimeIdentity` (`src/compiler/finalize.zig:410`)

- **签名**：`fn validateRuntimeIdentity(fd: *const function_def_mod.FunctionDef, rt: *runtime_mod.JSRuntime) FinalizeError!void`。
- **作用**：FunctionDef 的 memory/atoms 必须就是该 Runtime 的。
- **实现**：否则 InvalidBytecode，避免所有权搬到错误运行时。
- **所有权 / 错误 / 调用**：入口第一件事。


### `pipeline_finalize.validatePreLoweringArtifactShape` (`src/compiler/finalize.zig:417`)

- **签名**：`fn validatePreLoweringArtifactShape(fd: *const function_def_mod.FunctionDef) FinalizeError!void`。
- **作用**：arg/var/defined_arg 计数与切片长度一致，且拟合 u16。
- **实现**：lowering 会把计数压进 u16。
- **所有权 / 错误 / 调用**：只读 `fd` 的计数/切片长度，不分配；不一致返回 `error.InvalidBytecode`，超 u16 返回 `error.BytecodeOverflow`。私有，唯一调用方 `createFunctionBytecodeAfterChildren`（`bytecode.zig:10808`），在 lowering 之前。


### `pipeline_finalize.validateFinalArtifactShape` (`src/compiler/finalize.zig:429`)

- **签名**：`fn validateFinalArtifactShape( fd: *const function_def_mod.FunctionDef, lowered: *const bytecode_function.Bytecode, ) FinalizeError!usize`。
- **作用**：lowering 后 cpool/closure/code/pc2line/source 长度可放入 FB 字段。
- **实现**：返回 args+vars 作为 vardef 计数。
- **所有权 / 错误 / 调用**：BytecodeOverflow / InvalidBytecode。


### `pipeline_finalize.createFunctionBytecodeAfterChildren` (`src/compiler/finalize.zig:456`)

- **签名**：`fn createFunctionBytecodeAfterChildren( fd: *function_def_mod.FunctionDef, compile_context: CompileContext, disasm_enabled: bool, ) FinalizeError![]fb_mod.FunctionBytecode`。
- **作用**：子函数已装进 cpool 之后：v2 lowering、元数据发布、分配 production shell、搬迁所有者、算 stack_size、publishExecutionFlags、GC 发布。
- **实现**：`compiler.compileFunctionForPackedFinalize`；`publishLoweredMetadata`；FunctionLayout.init(true,true,…)；createProductionShell；memcpy 代码、逐行填 vardef/closure（名字 atom 留到 no-fail commit 才搬）；applyFlags 与 realm retain；pc2line/source 缓冲整体移交 DebugInfo；`pipeline_stack_size.compute` 带 final_artifact；`function_mod.publishExecutionFlags`；addInitialized。
- **所有权 / 错误 / 调用**：失败 errdefer 销毁未发布壳。FunctionDef 在 commit 前仍是名字/诊断所有者。

### `pipeline_finalize.publishLoweredMetadata` (`src/compiler/finalize.zig:635`)

- **签名**：`fn publishLoweredMetadata( function: *bytecode_function.Bytecode, def: *function_def_mod.FunctionDef, ) !void`。
- **作用**：把栈深、pc2line、执行 flags 相关几何事实写到 staging `Bytecode`。
- **实现**：arguments object 只看 `def.arguments_var_idx`（S4 序言是唯一生产者）。mapped arguments（非严格 + 简单参数表 + 真造 arguments）时先把每个形参标成捕获，再 validateOpenBindingIndices 证明稠密；然后写 is_global_var/entry_contract/var_count/arg_count；最后 encodePc2Line → computeStackSizeForCurrentBytecode，后者一并做最终产物校验（atom 所有者序列 + closure_var 上界）。
- **所有权 / 错误 / 调用**：自己不分配，但把 FunctionDef 的元数据**发布**到 `Bytecode`：`captureArg` 就地置位、`open_var_ref_count` 落表，`encodePc2Line` 把 pc2line 缓冲的所有权交给 `function`。错误为 `FinalizeError`（`BytecodeOverflow` 来自 var_ref 计数上限）。私有，唯一调用方 `createFunctionBytecodeAfterChildren`。


### `pipeline_finalize.computeStackSizeForCurrentBytecode` (`src/compiler/finalize.zig:700`)

- **签名**：`noinline fn computeStackSizeForCurrentBytecode( function: *bytecode_function.Bytecode, leaf_returns_balanced: *bool, final_artifact: stack_size.FinalArtifactValidation, ) FinalizeError!u16`。
- **作用**：最终字节码校验走：对已解析的 QuickJS 格式码算 `stack_size`，并写 `leaf_returns_balanced`。
- **实现**：`stack_size.compute(function.code, scratch=function.memory.allocator, returns_balanced_out, final_artifact)`。`ReachableFalloff` / `InvalidFinalArtifact` 收成 `InvalidBytecode`，其余原样上抛。outlined 是为挡住整程序删除后 Zig/LLVM 把它折进 packed finalizer（QCP-1B crypto/code-load 回退，见 decision record §9.3）。
- **所有权 / 错误 / 调用**：不另分配长期对象；scratch 用当前 MemoryAccount。`publishLoweredMetadata` 在 encode pc2line 之后调用。


### `pipeline_finalize.encodePc2Line` (`src/compiler/finalize.zig:720`)

- **签名**：`fn encodePc2Line(function: *bytecode_function.Bytecode) !void`。
- **作用**：把 FunctionDef/Bytecode 的 source_loc_slots 编进 pc2line_buf。
- **实现**：`pipeline_pc2line.encode` 后 install。
- **所有权 / 错误 / 调用**：独立所有者。

### `pipeline_finalize.installChildFunctionBytecodes` (`src/compiler/finalize.zig:730`)

- **签名**：`fn installChildFunctionBytecodes( fd: *function_def_mod.FunctionDef, root_module_record: ?*module.Record, compile_context: CompileContext, disasm_enabled: bool, ) FinalizeError!void`。
- **作用**：递归 finalize 每个 child，把子 FB 作为 JSValue 放进父 cpool。
- **实现**：用显式 frame 栈而不是真递归；root_module_record 只用于根 def，子 def 一律传 null。child 的 parent_cpool_idx 指向父 cpool 槽，出栈时才 finalize 并写回该槽；遍历期间发/撤 scope_link_cache 证明。
- **所有权 / 错误 / 调用**：树走，OOM/InvalidBytecode。

## 覆盖核对

- 清单函数数（本文件分组）: 41（`src/bytecode.zig` 全文件 507）
- 本文标题覆盖: 41
- 未覆盖: 无
