# 16 — 模块安装、链接、图求值、dynamic import

覆盖 `src/exec/module.zig`（registry、链接、namespace、合成模块）与 `src/exec/module_graph.zig`（宿主加载、TLA 调度、`import()` job）。记录身份在 `core/module.zig`；本文件是链接器与求值器。

对照：resolver/linker `quickjs.c:30525-30836`，evaluator `quickjs.c:31423-31563`，`js_dynamic_import` `quickjs.c:31037-31169`。

## `module.zig` 类型

`LinkDiagnostic`：`kind` = `missing_export` | `ambiguous_export` 或 null；`module_name` / `export_name` 借自稳定 record，链接失败后仍有效。

`LinkState`：`ctx`、DFS 下一 index、SCC 栈（`link_stack_prev` 串起来）、可选诊断指针。

---

### `isLinked` (`src/exec/module.zig:52`)

- **签名**：`pub fn isLinked(record: *const core.module.ModuleRecord) bool`。
- **作用**：record 是否已经过链接（含求值中/后/错）。
- **实现**：`linked|evaluating|evaluated|errored` 为真；`unlinked|linking` 为假。
- **所有权 / 错误 / 调用**：`linkModule` 早退；求值门另用 `moduleNeedsEvaluation`。

### `installParsedModuleArtifact` (`src/exec/module.zig:61`)

- **签名**：`pub fn installParsedModuleArtifact( ctx: *core.JSContext, module_name: core.Atom, artifact: parser.ModuleArtifact, referrer_path: ?[]const u8, ) !*core.module.ModuleRecord`。
- **作用**：吃掉一份 parser `ModuleArtifact`，相对 referrer 解析请求名，安装进 registry。
- **实现**：`pendingDefinitionFromArtifact(..., referrer_path, null)` + `installPendingDefinition`。pending `defer deinit`。
- **所有权 / 错误 / 调用**：文件预加载。artifact 的 bytecode 所有权迁到 pending/record。

### `installResolvedModuleArtifact` (`src/exec/module.zig:75`)

- **签名**：`pub fn installResolvedModuleArtifact( ctx: *core.JSContext, module_name: core.Atom, artifact: parser.ModuleArtifact, resolved_request_names: []const core.Atom, ) !*core.module.ModuleRecord`。
- **作用**：宿主已经解析好请求名：原样复制，不做路径规范化或 import-attribute 改写。
- **实现**：`pendingDefinitionFromArtifact(..., null, resolved_request_names)`。
- **所有权 / 错误 / 调用**：`preloadFileModuleGraphWithHostHooksInner`。names.len 必须等于 requests.len。

### `installPendingDefinition` (`src/exec/module.zig:91`)

- **签名**：`fn installPendingDefinition( ctx: *core.JSContext, module_name: core.Atom, pending: *core.module.PendingDefinition, ) !*core.module.ModuleRecord`。
- **作用**：`modules.prepareFreshTarget`：已有 record 复用，新 record 装上 namespace auto-init 回调。
- **实现**：`.existing` 直接返回。`.fresh`：`setNamespaceAutoInitResolverNoFail(resolveModuleNamespaceAutoInit)`；无请求则立刻 `markRequestsResolvedNoFail`。
- **所有权 / 错误 / 调用**：pending 调用方 deinit。

### `pendingDefinitionFromArtifact` (`src/exec/module.zig:109`)

- **签名**：`fn pendingDefinitionFromArtifact( ctx: *core.JSContext, artifact: parser.ModuleArtifact, referrer_path: ?[]const u8, resolved_request_names: ?[]const core.Atom, ) !core.module.PendingDefinition`。
- **作用**：校验模块 bytecode 与 parser 元数据一致，填 PendingDefinition。
- **实现**：函数必须 `isModule()` 且 realm==ctx。imports/exports 的 var_idx、closure 名、closureType（namespace→`module_decl`，普通 import→`module_import`）必须对齐。star export 名必须是 `"*"`。逐请求：宿主名或 `resolvedRequestAtomForParsed`。再 addImport/Export/Indirect/Star/Attribute。`has_top_level_await` 拷过来。
- **所有权 / 错误 / 调用**：`parsed.deinit`；pending `errdefer deinit`。元数据错误经 `pendingMetadataError`。

### `pendingMetadataError` (`src/exec/module.zig:205`)

- **签名**：`fn pendingMetadataError(err: anyerror) error{ OutOfMemory, InvalidBytecode }`。
- **作用**：把 pending.add* 的失败收成两元错误集。
- **实现**：OOM 保留，其余 `InvalidBytecode`。
- **所有权 / 错误 / 调用**：`pendingDefinitionFromArtifact` 的 addRequest/addImport/addExport/addIndirectExport/addStarExport/addImportAttribute，以及 `preloadSyntheticFileModuleTracked` 的 `addExport`。

### `preloadFileModuleGraphWithOrder` (`src/exec/module.zig:212`)

- **签名**：`pub fn preloadFileModuleGraphWithOrder( io: std.Io, allocator: std.mem.Allocator, context: *core.JSContext, root_source: []const u8, root_path: []const u8, max_source_size: usize, postorder: *std.ArrayList([]const u8), ) !void`。
- **作用**：从根源文递归预加载依赖，后序路径写入 `postorder`。
- **实现**：本地 `seen` 列表 defer 释放；`preloadFileModuleGraphInner`。
- **所有权 / 错误 / 调用**：`evalFileModuleGraphWithOutput`。路径字符串 allocator 拥有。

### `preloadMissingFileModuleGraphWithOrder` (`src/exec/module.zig:238`)

- **签名**：`pub fn preloadMissingFileModuleGraphWithOrder( io: std.Io, allocator: std.mem.Allocator, context: *core.JSContext, root_source: []const u8, root_path: []const u8, max_source_size: usize, postorder: *std.ArrayList([]const u8), ) !void`。
- **作用**：同样预加载。「动态 import 不得重置已求值模块」不再由一个 `skip_existing` 标志表达（那个形参从不被读，已整链删除），跳过由 inner 对「已解析完请求的 record」的无条件早退完成——两个入口因此行为一致。
- **实现**：建 `seen` 列表后调 `preloadFileModuleGraphInner`。
- **所有权 / 错误 / 调用**：`evalDynamicImportModule`。

### `resolveModuleSpecifier` (`src/exec/module.zig:264`)

- **签名**：`pub fn resolveModuleSpecifier(allocator: std.mem.Allocator, referrer_path: []const u8, specifier: []const u8) ![]const u8`。
- **作用**：文件加载器的说明符解析。
- **实现**：`node:` 原样 dup；绝对路径 `path.resolve`；必须以 `./` 或 `../` 开头否则 `ModuleNotFound`；相对 referrer 目录 resolve。
- **所有权 / 错误 / 调用**：调用方 free 返回切片。dynamic import 失败走 `throwCouldNotLoadModule`。

### `moduleFunctionValue` (`src/exec/module.zig:276`)

- **签名**：`pub fn moduleFunctionValue(record: *const core.module.ModuleRecord) !core.JSValue`。
- **作用**：借 record 的规范模块函数值（链接后应是函数对象）。
- **实现**：`funcObjectValue()` 必须是 object。
- **所有权 / 错误 / 调用**：不 dup。链接把 FunctionBytecode 所有权迁进 shell。

### `moduleFunctionObject` (`src/exec/module.zig:282`)

- **签名**：`pub fn moduleFunctionObject(record: *const core.module.ModuleRecord) !*core.Object`。
- **作用**：上值的函数对象。
- **实现**：`functionObjectFromValue` 失败 → `InvalidBytecode`。
- **所有权 / 错误 / 调用**：`wireModuleImports` / `retainLocalExports` / `rollbackRecordLinkArtifacts` / `bindingCell` 取捕获槽，`runModuleDeclarationInstantiation` 与 `runModuleEvaluationStep` 取运行入口。

### `moduleFunctionBytecode` (`src/exec/module.zig:287`)

- **签名**：`pub fn moduleFunctionBytecode(record: *const core.module.ModuleRecord) !*const bytecode.FunctionBytecode`。
- **作用**：模块函数上的 bytecode，且必须 `isModule()`。
- **实现**：`moduleFunctionObject` → `object.functionBytecode()` → `call_runtime.functionBytecodeFromValue`；任一步为空或最终 `!isModule()` 都是 `InvalidBytecode`。
- **所有权 / 错误 / 调用**：声明实例化与求值。

### `createModuleDeclarationCell` (`src/exec/module.zig:295`)

- **签名**：`fn createModuleDeclarationCell( ctx: *core.JSContext, closure: bytecode.function_bytecode.BytecodeClosureVar, ) !*core.VarRef`。
- **作用**：本地模块绑定 cell：lexical 初始 uninitialized，否则 undefined。
- **实现**：`VarRef.createClosed`；拷 is_lexical / const / function_name。
- **所有权 / 错误 / 调用**：`ensureModuleCaptureCells` 的 `.module_decl`。

### `ensureModuleCaptureCells` (`src/exec/module.zig:310`)

- **签名**：`fn ensureModuleCaptureCells( ctx: *core.JSContext, object: *core.Object, function: *const bytecode.FunctionBytecode, ) !void`。
- **作用**：为模块函数闭包前缀分配 cell：decl 本地、global 走根全局瀑布、import 槽必须仍空（链接再填）。
- **实现**：无槽则 `allocateNullModuleCaptureSlots`。`.global` 可补；`.module_import` 已有值 → `InvalidBytecode`；其它 closureType 非法。
- **所有权 / 错误 / 调用**：`ensureModuleFunction`。import 由 `wireModuleImports` 填。

### `ensureModuleFunction` (`src/exec/module.zig:360`)

- **签名**：`fn ensureModuleFunction( ctx: *core.JSContext, record: *core.module.ModuleRecord, ) !?*core.Object`。
- **作用**：把 record 拥有的 FunctionBytecode 包进函数 shell，或确认已有 shell。
- **实现**：合成模块：func 必须仍 undefined，`ensureSyntheticDefaultCell`，返回 null。已是函数对象：补 capture。否则必须是 function_bytecode，realm 匹配；`createModuleBytecodeFunctionShell`；`takeFuncObjectValueNoFail` 再 `adoptFuncObjectValueNoFail` 装上函数对象、`setFunctionBytecodeValue`（失败 unreachable）。
- **所有权 / 错误 / 调用**：链接开头。所有权顺序：record 先有 bytecode，再有 shell，再把 bytecode 挂到 shell。

### `linkModule` (`src/exec/module.zig:390`)

- **签名**：`pub fn linkModule( ctx: *core.JSContext, record: *core.module.ModuleRecord, diagnostic: ?*LinkDiagnostic, ) !void`。
- **作用**：InnerModuleLinking 入口。
- **实现**：清诊断。registry/requestsResolved 检查。已 linked 返回。已 linking → `ModuleLinkFailed`（重入）。`errdefer rollbackActiveLinkStack`。结束 assert 栈空。
- **所有权 / 错误 / 调用**：图求值、dynamic import。失败 record 回到 unlinked。

### `linkModuleInner` (`src/exec/module.zig:410`)

- **签名**：`fn linkModuleInner(state: *LinkState, record: *core.module.ModuleRecord) !void`。
- **作用**：Tarjan SCC 链接：先依赖，再校验 indirect export，再接线、retain、声明实例化。
- **实现**：标 linking，分配 dfs index，压栈。`ensureModuleFunction`。对每个请求：unlinked 递归并抬 ancestor；linking 用对方 dfs_index。indirect export：namespace 跳过，其余 `resolveExportChecked`，not_found/ambiguous 记诊断。`wireModuleImports`、`retainLocalExports`、`runModuleDeclarationInstantiation`。若 ancestor==self，弹出到自己（含自己）全部 `status=linked` + `resetLinkTransientNoFail`。
- **所有权 / 错误 / 调用**：qjs 在接线前校验全部 indirect，保留「缺 indirect 先于坏 import」的诊断序。

### `requestDependency` (`src/exec/module.zig:497`)

- **签名**：`fn requestDependency( record: *core.module.ModuleRecord, request_index: u32, ) !*core.module.ModuleRecord`。
- **作用**：取已解析的依赖 record。
- **实现**：缺 request/module 或 registry 不一致 → `InvalidBytecode`/`ModuleNotFound`。
- **所有权 / 错误 / 调用**：链接与 namespace 收集。

### `resolveExportChecked` (`src/exec/module.zig:507`)

- **签名**：`fn resolveExportChecked( ctx: *core.JSContext, record: *core.module.ModuleRecord, export_name: core.Atom, ) !core.module.ResolvedExport`。
- **作用**：`ctx.modules.resolveExport`，把内部索引错误映射成 `InvalidBytecode`。
- **实现**：`ForeignModuleRecord`/`InvalidModuleRequestIndex` → InvalidBytecode。
- **所有权 / 错误 / 调用**：链接、namespace、auto-init。

### `expectResolvedExport` (`src/exec/module.zig:520`)

- **签名**：`fn expectResolvedExport( state: *LinkState, module_record: *core.module.ModuleRecord, export_name: core.Atom, ) !core.module.ResolvedBinding`。
- **作用**：解析必须成功，否则写诊断并 MissingExport/AmbiguousExport。
- **实现**：switch ResolvedExport。
- **所有权 / 错误 / 调用**：`wireModuleImports` 非 namespace import。

### `recordLinkDiagnostic` (`src/exec/module.zig:543`)

- **签名**：`fn recordLinkDiagnostic( state: *LinkState, kind: LinkDiagnostic.Kind, module_record: *const core.module.ModuleRecord, export_name: core.Atom, ) void`。
- **作用**：只记**第一条**诊断。
- **实现**：无指针或 kind 已填则 return。
- **所有权 / 错误 / 调用**：atom 借自 record，失败后仍可读。

### `wireModuleImports` (`src/exec/module.zig:558`)

- **签名**：`fn wireModuleImports(state: *LinkState, record: *core.module.ModuleRecord) !void`。
- **作用**：把 import 闭包槽接到导出 cell 或 namespace 对象。
- **实现**：合成模块 return。namespace import：已有 module_decl cell，`setVarRefValue(namespace)`。普通 import：`expectResolvedExport` + `importBindingCell` + `replaceModuleCaptureSlotOwned`。
- **所有权 / 错误 / 调用**：失败回滚清 import 槽。

### `importBindingCell` (`src/exec/module.zig:593`)

- **签名**：`fn importBindingCell( ctx: *core.JSContext, binding: core.module.ResolvedBinding, ) !*core.VarRef`。
- **作用**：本地导出直接用 retained/capture cell；`export * as ns` 则新建 closed cell 存 namespace。
- **实现**：`.local_export` `bindingCell`；`.namespace_export` `createClosed(namespace)`。
- **所有权 / 错误 / 调用**：新 cell 所有权交给模块函数槽。

### `retainLocalExports` (`src/exec/module.zig:611`)

- **签名**：`fn retainLocalExports( ctx: *core.JSContext, record: *core.module.ModuleRecord, ) !void`。
- **作用**：把每个本地导出钉到 record 的 retained export cell，namespace Get 与其它模块 import 共用同一 VarRef。
- **实现**：合成 → `ensureSyntheticDefaultCell`。否则对每个 export，已 retain 则 skip，否则 `publishRetainedExportCellNoFail(slots[var_idx])`。
- **所有权 / 错误 / 调用**：链接；回滚 `clearRetainedExportCellNoFail`。

### `rollbackActiveLinkStack` (`src/exec/module.zig:637`)

- **签名**：`fn rollbackActiveLinkStack(state: *LinkState) void`。
- **作用**：链接失败：栈上所有 record 回到 unlinked。
- **实现**：弹出直到空，每条 `rollbackRecordLinkArtifacts` + `status=unlinked` + `resetLinkTransientNoFail`。
- **所有权 / 错误 / 调用**：`linkModule` errdefer。

### `rollbackRecordLinkArtifacts` (`src/exec/module.zig:646`)

- **签名**：`fn rollbackRecordLinkArtifacts( ctx: *core.JSContext, record: *core.module.ModuleRecord, ) void`。
- **作用**：清 retained export；import 槽清空；decl 槽回到 uninitialized/undefined。
- **实现**：合成只清 export cell。函数对象取失败则 return。
- **所有权 / 错误 / 调用**：不销毁函数 shell。

### `runModuleDeclarationInstantiation` (`src/exec/module.zig:676`)

- **签名**：`pub fn runModuleDeclarationInstantiation( ctx: *core.JSContext, record: *core.module.ModuleRecord, ) !void`。
- **作用**：ModuleDeclarationInstantiation：以 `this=true` 跑模块函数的声明部分。
- **实现**：合成 return。`sealModuleCaptures`。新 Stack，`runWithCallEnv`（`global_declarations_prevalidated=true`）。
- **所有权 / 错误 / 调用**：链接 SCC 弹出前。var/function 绑定在此写入 cell。

### `runModuleEvaluationStep` (`src/exec/module.zig:701`)

- **签名**：`pub fn runModuleEvaluationStep( ctx: *core.JSContext, record: *core.module.ModuleRecord, output: ?*std.Io.Writer, module_state: *core.Object, resume_value: ?core.JSValue, ) !core.JSValue`。
- **作用**：跑/恢复模块函数一轮；TLA await 把帧停在 `module_state` generator 上。
- **实现**：`sealModuleCaptures`。若还没有保存帧才 `reserveAdditional(stack_size)`（resume 已有 backing，预分配会被覆盖并泄漏）。`suspend_on_module_await=true`。非 combined storage 则 defer `finalizeGeneratorExecutionCompletion`。
- **所有权 / 错误 / 调用**：`evalPreloadedFileModuleStep`。返回值在挂起时是 awaited 值。

### `moduleNamespaceValue` (`src/exec/module.zig:740`)

- **签名**：`pub fn moduleNamespaceValue( ctx: *core.JSContext, module_name: core.Atom, ) !core.JSValue`。
- **作用**：按名取规范 namespace 对象。
- **实现**：find + `moduleNamespaceValueForRecord`。
- **所有权 / 错误 / 调用**：dynamic import 兑现、waiter settle。

### `requestName` (`src/exec/module.zig:748`)

- **签名**：`fn requestName(record: bytecode.module.Record, request_index: u32) !bytecode.module.Request`。
- **作用**：parser record 上的请求，做边界检查。
- **实现**：越界 `InvalidBytecode`。
- **所有权 / 错误 / 调用**：`pendingDefinitionFromArtifact` 校验。

### `resolvedRequestAtomForParsed` (`src/exec/module.zig:753`)

- **签名**：`fn resolvedRequestAtomForParsed( runtime: *core.JSRuntime, parsed: *const bytecode.module.Record, request_atom: core.Atom, request_index: u32, referrer_path: ?[]const u8, ) !core.Atom`。
- **作用**：解析路径后再按 import attribute / `.json` 后缀打 `#type=` 标签。
- **实现**：root 住 resolved atom。`syntheticKindForRequestIndex`；`none` 原样；否则 `syntheticModuleRegistryName` intern。
- **所有权 / 错误 / 调用**：静态预加载。动态 import 用同一 registry 名共享 record。

### `bindingCell` (`src/exec/module.zig:774`)

- **签名**：`fn bindingCell(binding: core.module.ResolvedBinding) ?*core.VarRef`。
- **作用**：本地导出的活 cell：优先 retained，否则函数 capture。
- **实现**：namespace_export → null。合成无函数对象 → null。
- **所有权 / 错误 / 调用**：namespace 定义与 auto-init。

### `namespaceBindingTarget` (`src/exec/module.zig:790`)

- **签名**：`fn namespaceBindingTarget( binding: core.module.ResolvedBinding, ) !*core.module.ModuleRecord`。
- **作用**：`export * as ns from 'x'` 的目标模块。
- **实现**：indirect 必须 `is_namespace`。
- **所有权 / 错误 / 调用**：auto-init 与 importBindingCell。

### `moduleNamespaceValueForRecord` (`src/exec/module.zig:802`)

- **签名**：`fn moduleNamespaceValueForRecord( ctx: *core.JSContext, record: *core.module.ModuleRecord, ) !core.JSValue`。
- **作用**：缓存或创建 `module_ns` 对象。
- **实现**：已发布直接返回。`Object.create(module_ns)` → `initializeCanonicalModuleNamespace` → `publishModuleNamespaceNoFail`。
- **所有权 / 错误 / 调用**：registry 必须是 ctx.modules；requests 必须已解析。

### `initializeCanonicalModuleNamespace` (`src/exec/module.zig:817`)

- **签名**：`fn initializeCanonicalModuleNamespace( ctx: *core.JSContext, record: *core.module.ModuleRecord, object: *core.Object, ) !void`。
- **作用**：按导出名排序定义 namespace 属性：有 cell 用 var-ref 属性，否则 AUTOINIT；然后 @@toStringTag=`Module`，preventExtensions。
- **实现**：`collectCanonicalModuleNamespaceExports` + `heap` sort `atomLessThan`。ambiguous/not_found 跳过。
- **所有权 / 错误 / 调用**：属性是不可配置的导出绑定。

### `defineCanonicalModuleNamespaceToStringTag` (`src/exec/module.zig:870`)

- **签名**：`fn defineCanonicalModuleNamespaceToStringTag( ctx: *core.JSContext, object: *core.Object, ) !void`。
- **作用**：`@@toStringTag = "Module"`，不可写不可枚举不可配置。
- **实现**：`String.createUtf8` + `defineOwnProperty`。
- **所有权 / 错误 / 调用**：缺 atom → `InvalidAtom`。

### `collectCanonicalModuleNamespaceExports` (`src/exec/module.zig:885`)

- **签名**：`fn collectCanonicalModuleNamespaceExports( ctx: *core.JSContext, record: *core.module.ModuleRecord, include_default: bool, visited: *std.ArrayList(*core.module.ModuleRecord), exports: *std.ArrayList(core.Atom), ) !void`。
- **作用**：本地+间接导出；`export *` 递归且 **不含 default**。
- **实现**：visited 指针相等去环。`appendUniqueExport`。
- **所有权 / 错误 / 调用**：star 的 include_default=false。

### `resolveModuleNamespaceAutoInit` (`src/exec/module.zig:916`)

- **签名**：`fn resolveModuleNamespaceAutoInit( owner: *const module_auto_init.AutoInitModuleOwner, realm_header: *core.gc.Header, atom_id: core.Atom, ) anyerror!module_auto_init.AutoInitMaterialization`。
- **作用**：MODULE_NS 延迟导出：从 AutoInitModuleOwner 找回 record/realm，物化 var-ref 或 namespace 值。
- **实现**：`fieldParentPtr`。registry 必须匹配。local → `{ .var_ref }`；namespace_export → `{ .value = namespace }`。
- **所有权 / 错误 / 调用**：core `module_auto_init` 回调，不把 Runtime 引进叶子契约。

### `appendUniqueExport` (`src/exec/module.zig:946`)

- **签名**：`fn appendUniqueExport(ctx: *core.JSContext, exports: *std.ArrayList(core.Atom), atom_id: core.Atom) !void`。
- **作用**：导出名去重追加。
- **实现**：线性扫描。
- **所有权 / 错误 / 调用**：allocator 来自 runtime.memory。

### `atomLessThan` (`src/exec/module.zig:953`)

- **签名**：`fn atomLessThan(rt: *core.JSRuntime, lhs: core.Atom, rhs: core.Atom) bool`。
- **作用**：namespace 导出按 UTF-8 名排序，同名按 atom id。
- **实现**：`mem.order`。缺名当 `""`。
- **所有权 / 错误 / 调用**：`sort_erased.heap`。

### `preloadFileModuleGraphInner` (`src/exec/module.zig:967`)

- **签名**：`fn preloadFileModuleGraphInner( io: std.Io, allocator: std.mem.Allocator, context: *core.JSContext, source_text: []const u8, path: []const u8, max_source_size: usize, seen: *std.ArrayList([]const u8), postorder: ?*std.ArrayList([]const u8), ) !void`。
- **作用**：预加载一棵文件模块图的递归体：编译本文件、按 `seen` 去重、逐个依赖递归、最后把 postorder 记下来。
- **实现**：`seen` 命中即返回；否则 intern path 为 atom（挂 `rootAtoms`），查/建 record，对每个请求解析路径、读源并递归自身，最后 `markRequestsResolvedNoFail` 并 append postorder。原先那层只为传 `skip_existing` 的 `...InnerMode` 已折叠进来——跳过已加载模块不是可选模式，靠 `seen` 加「requests 已 resolved 的 record 早退」自然成立。
- **所有权 / 错误 / 调用**：`seen` 里的路径由调用方 `preloadFileModuleGraphWithOrder` 建并释放。调用方：`preloadFileModuleGraphWithOrder`（建 `seen` 后调）与自身的依赖递归。

### `throwCouldNotLoadModule` (`src/exec/module.zig:1095`)

- **签名**：`pub fn throwCouldNotLoadModule(ctx: *core.JSContext, filename: []const u8) !void`。
- **作用**：`ReferenceError: could not load module filename '<name>'`（qjs-libc `js_module_loader`）。
- **实现**：`createNamedError` + `throwValue`。
- **所有权 / 错误 / 调用**：预加载与 dynamic import。调用方再 return `JSException`。

### `appendTrackedPath` (`src/exec/module.zig:1104`)

- **签名**：`fn appendTrackedPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void`。
- **作用**：dup 路径并追加到 seen/postorder。
- **实现**：`errdefer free`；`array_list_erased.append`。
- **所有权 / 错误 / 调用**：列表 defer 释放所有条目。

### `syntheticKindForRequestIndex` (`src/exec/module.zig:1110`)

- **签名**：`fn syntheticKindForRequestIndex( runtime: *core.JSRuntime, record: *const bytecode.module.Record, request_index: u32, ) ?core.module.SyntheticKind`。
- **作用**：该 import 的 `type` 属性或 `.json` 后缀。
- **实现**：属性 json/text/bytes。无 type 但 specifier 以 `.json` 结尾 → json（qjs `has_suffix`，quickjs-libc.c:704）。
- **所有权 / 错误 / 调用**：静态解析。动态 import 另有 `ImportLoaderType`。

### `syntheticModuleKindName` (`src/exec/module.zig:1134`)

- **签名**：`fn syntheticModuleKindName(kind: core.module.SyntheticKind) []const u8`。
- **作用**：`json`/`text`/`bytes` 字面量。
- **实现**：`.none` unreachable。
- **所有权 / 错误 / 调用**：registry 名。

### `syntheticKindFromRegistryName` (`src/exec/module.zig:1143`)

- **签名**：`fn syntheticKindFromRegistryName(path: []const u8) ?core.module.SyntheticKind`。
- **作用**：从 `path#type=` 后缀识别合成模块。
- **实现**：lastIndexOf `#type=`。
- **所有权 / 错误 / 调用**：预加载依赖循环。

### `syntheticModuleRegistryName` (`src/exec/module.zig:1152`)

- **签名**：`pub fn syntheticModuleRegistryName(allocator: std.mem.Allocator, path: []const u8, kind: core.module.SyntheticKind) ![]u8`。
- **作用**：`"{path}#type={kind}"`。
- **实现**：`allocPrint`。
- **所有权 / 错误 / 调用**：调用方 free。静态/动态共享。

### `syntheticModuleSourcePath` (`src/exec/module.zig:1156`)

- **签名**：`fn syntheticModuleSourcePath(path: []const u8) []const u8`。
- **作用**：去掉 `#type=` 标签得到磁盘路径。
- **实现**：`lastIndexOf("#type=")` 定位标签起点后切前缀；找不到就原样返回。用 `lastIndexOf` 而不是 `indexOf`，与 `syntheticKindFromRegistryName` 保持一致——否则磁盘路径里本身含 `#type=` 字面量时，两者会对同一个 registry 名切出不同的路径与 kind。
- **所有权 / 错误 / 调用**：返回入参的借用子切片，不分配、无 error。唯一调用方 `syntheticModuleFilePath`。

### `syntheticModuleFilePath` (`src/exec/module.zig:1161`)

- **签名**：`pub fn syntheticModuleFilePath(path: []const u8) []const u8`。
- **作用**：公开的源路径。
- **实现**：转私有函数。
- **所有权 / 错误 / 调用**：读文件、import.meta.url。

### `preloadSyntheticFileModule` (`src/exec/module.zig:1165`)

- **签名**：`pub fn preloadSyntheticFileModule( ctx: *core.JSContext, path: []const u8, kind: core.module.SyntheticKind, ) !void`。
- **作用**：确保合成 record 在 registry。
- **实现**：丢弃返回的 record。
- **所有权 / 错误 / 调用**：dynamic import json/text。

### `preloadSyntheticFileModuleTracked` (`src/exec/module.zig:1173`)

- **签名**：`fn preloadSyntheticFileModuleTracked( ctx: *core.JSContext, path: []const u8, kind: core.module.SyntheticKind, ) !*core.module.ModuleRecord`。
- **作用**：安装只导出 default 的合成 PendingDefinition。
- **实现**：已有则校验 kind，mark resolved。否则 `synthetic_kind` + `addExport(default,default,0)` + install + mark resolved。
- **所有权 / 错误 / 调用**：尚无 default cell；链接/init 再造。

### `ensureSyntheticDefaultCell` (`src/exec/module.zig:1203`)

- **签名**：`fn ensureSyntheticDefaultCell( ctx: *core.JSContext, record: *core.module.ModuleRecord, ) !void`。
- **作用**：lexical uninitialized 的 default 导出 cell。
- **实现**：已有 retained 则 return。
- **所有权 / 错误 / 调用**：链接 retain、`setModuleBinding`。

### `syntheticDefaultExportIndex` (`src/exec/module.zig:1219`)

- **签名**：`fn syntheticDefaultExportIndex( record: *const core.module.ModuleRecord, ) ?u32`。
- **作用**：找到 default/default 导出下标。
- **实现**：线性扫 `exports`，要求 export_name 与 local_name 同为 `default`，`std.math.cast(u32, index)`。
- **所有权 / 错误 / 调用**：`ensureSyntheticDefaultCell` 发布 retained cell 前定位下标；返回 null 时上层报 `InvalidBytecode`。

### `initializeSyntheticFileModule` (`src/exec/module.zig:1232`)

- **签名**：`pub fn initializeSyntheticFileModule( ctx: *core.JSContext, global: *core.Object, module_name: core.Atom, source_text: []const u8, ) !bool`。
- **作用**：把 json/text/bytes 源文写进 default 绑定。已初始化返回 true。
- **实现**：json：内部 `JSON.parse`（无 reviver，不让 exec 编译期依赖 json 域）。text：UTF-8 字符串。bytes：不可变 Uint8Array。`setModuleBinding`。非合成 → false。
- **所有权 / 错误 / 调用**：图求值在 link 前对所有合成 record 调一次。

### `moduleBindingInitialized` (`src/exec/module.zig:1282`)

- **签名**：`fn moduleBindingInitialized(record: *const core.module.ModuleRecord, name: core.Atom) bool`。
- **作用**：retained cell 是否已离开 uninitialized。
- **实现**：按 local_name 找。
- **所有权 / 错误 / 调用**：避免重复 JSON.parse。

### `setModuleBinding` (`src/exec/module.zig:1293`)

- **签名**：`fn setModuleBinding(ctx: *core.JSContext, record: *core.module.ModuleRecord, name: core.Atom, value: core.JSValue) !void`。
- **作用**：写合成 default cell。
- **实现**：ensure cell；找不到名 → MissingExport。
- **所有权 / 错误 / 调用**：`setVarRefValue` 带 barrier。

### `syntheticBytesModuleValue` (`src/exec/module.zig:1307`)

- **签名**：`fn syntheticBytesModuleValue(ctx: *core.JSContext, global: *core.Object, source_text: []const u8) !core.JSValue`。
- **作用**：`type: bytes`：Uint8Array 包不可变 ArrayBuffer。
- **实现**：`createUint8ArrayFromBytes`；buffer 原型；`markImmutableArrayBuffer`。
- **所有权 / 错误 / 调用**：default 导出。

### `markImmutableArrayBuffer` (`src/exec/module.zig:1319`)

- **签名**：`fn markImmutableArrayBuffer(rt: *core.JSRuntime, object: *core.Object) !void`。
- **作用**：禁止 bytes 模块 buffer 被 detach/改。
- **实现**：`core.object.markArrayBufferImmutable`。
- **所有权 / 错误 / 调用**：薄包装。

### `resolvedRequestAtom` (`src/exec/module.zig:1323`)

- **签名**：`fn resolvedRequestAtom(runtime: *core.JSRuntime, request_atom: core.Atom, referrer_path: ?[]const u8) !core.Atom`。
- **作用**：intern 解析后的绝对路径；`node:` / 非相对说明符保持原 atom。
- **实现**：无 referrer 原样。绝对/`./`/`../` resolve 后 intern。
- **所有权 / 错误 / 调用**：临时路径 `defer free`。

### `importMetaUrlValue` (`src/exec/module.zig:1347`)

- **签名**：`pub fn importMetaUrlValue(rt: *core.JSRuntime, record: *core.module.ModuleRecord) !core.JSValue`。
- **作用**：`import.meta.url`（qjs-libc `js_module_set_import_meta`）。
- **实现**：名字含 `:` 原样当 URL。否则用 `syntheticModuleFilePath`。Windows `file://`+path；POSIX `realpath` 成功则 `file://`+realpath，失败时绝对路径仍加 `file://`，否则原名（如 `<eval>`）。
- **所有权 / 错误 / 调用**：VM import.meta。

---

## `module_graph.zig` 类型

`HostHooks`：`resolveModule` / `loadModule`。`ModuleKind` = esm/commonjs/json/wasm/builtin。`LoadedModule.owned` 决定谁 free source。

`ModuleEvalStep`：`.completed(JSValue)` 或 `.suspended{continuation, awaited}`。

`ContinuationRoots` / `WaiterRoots`：把原生 ArrayList 里的 JSValue 登记给 tracer（rc 构建擦除）。

`ModuleContinuation`：realm、path、continuation、awaited、keep_result、completed、settle_waiters、completion_rejected、deferred_start、awaited_normalized、ready。

`ModuleEvaluationWaiter`：对正在 evaluating 的模块的 import() 等待者（resolve/reject）。

`ImportLoaderType`：none/json/text。

`DynamicImportState`：文件加载器 + 自己的或外部的 continuation/waiter 列表 + 根注册 + `pending_import_type`。

`DynamicImportHostState`：宿主钩子加载器。

`DynamicImportScope`：loader 安装 + 根激活，deinit 成对撤销。

`ModuleDrainResult`：stalled / progressed / value。

---

### `ContinuationRoots.traceRoots` (`src/exec/module_graph.zig:63`)

- **签名**：`fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：扫每个 continuation 的 realm header + continuation/awaited 值。
- **实现**：`realm.borrow()` 后 `constHeader`。
- **所有权 / 错误 / 调用**：RootProvider。TLA 挂起发生在 `runJobs` 之前，所以根必须在 install 时登记。

### `ContinuationRoots.provider` (`src/exec/module_graph.zig:72`)

- **签名**：`fn provider(self: *ContinuationRoots) core.runtime.RootProvider`。
- **作用**：拼 `{ context, trace }`。
- **实现**：指针转换。
- **所有权 / 错误 / 调用**：activate/deactivate。

### `ContinuationRoots.activate` (`src/exec/module_graph.zig:76`)

- **签名**：`inline fn activate(self: *ContinuationRoots) !void`。
- **作用**：`registerRootProvider`。value_root_frames 关闭则空。
- **实现**：`registered=true`。
- **所有权 / 错误 / 调用**：`DynamicImportState.activateRoots`、host-hooks 求值器。

### `ContinuationRoots.deactivate` (`src/exec/module_graph.zig:82`)

- **签名**：`fn deactivate(self: *ContinuationRoots) void`。
- **作用**：unregister。未登记则 no-op。
- **实现**：清 `registered`。
- **所有权 / 错误 / 调用**：必须在列表析构前；静态图求值用 `DynamicImportScope.deinit`，不能只靠 State.deinit。

### `WaiterRoots.traceRoots` (`src/exec/module_graph.zig:97`)

- **签名**：`fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：扫 waiter 的 realm + resolve/reject。
- **实现**：同 ContinuationRoots。
- **所有权 / 错误 / 调用**：evaluating 模块上的 import() 能力。

### `WaiterRoots.provider` (`src/exec/module_graph.zig:106`)

- **签名**：`fn provider(self: *WaiterRoots) core.runtime.RootProvider`。
- **作用**：waiter 列表的 provider。
- **实现**：指针。
- **所有权 / 错误 / 调用**：activate。

### `WaiterRoots.activate` (`src/exec/module_graph.zig:110`)

- **签名**：`inline fn activate(self: *WaiterRoots) !void`。
- **作用**：登记 waiter 根。
- **实现**：同 ContinuationRoots。
- **所有权 / 错误 / 调用**：成对 deactivate。

### `WaiterRoots.deactivate` (`src/exec/module_graph.zig:116`)

- **签名**：`fn deactivate(self: *WaiterRoots) void`。
- **作用**：撤销 waiter 根。
- **实现**：未登记则 no-op；`unregisterRootProvider` 后清 `registered`；`value_root_frames` 关闭时整体编译掉。
- **所有权 / 错误 / 调用**：Scope.deinit。

### `ModuleContinuation.replaceAwaited` (`src/exec/module_graph.zig:139`)

- **签名**：`fn replaceAwaited(self: *ModuleContinuation, _: *core.JSRuntime, replacement: core.JSValue) void`。
- **作用**：把 awaited 换成内部 reaction promise。
- **实现**：赋值。runtime 未用（旧 rc dup 已删）。
- **所有权 / 错误 / 调用**：`prepareModuleContinuationAwait`。

### `ModuleEvaluationWaiter.deinit` (`src/exec/module_graph.zig:150`)

- **签名**：`fn deinit(self: *ModuleEvaluationWaiter, _: *core.JSRuntime, allocator: std.mem.Allocator) void`。
- **作用**：free path，放 RealmRef。
- **实现**：不释放 JSValue（由 waiter 根/调用方负责至 settle）。
- **所有权 / 错误 / 调用**：settle 成功移除、`freeModuleEvaluationWaiters`。

### `importLoaderTypeFromAttributes` (`src/exec/module_graph.zig:166`)

- **签名**：`fn importLoaderTypeFromAttributes(ctx: *core.JSContext, attributes: core.JSValue) ImportLoaderType`。
- **作用**：从校验过的 attributes 对象读 `type` 字符串（qjs `js_module_test_json`）。
- **实现**：非对象 → none。自有 data `type` 必须是字符串；`json`/`text`，其它忽略。
- **所有权 / 错误 / 调用**：appendRawString 失败当 none。dynamic import job。

### `DynamicImportState.continuationList` (`src/exec/module_graph.zig:206`)

- **签名**：`fn continuationList(self: *DynamicImportState) *std.ArrayList(ModuleContinuation)`。
- **作用**：外部列表或 state 自有列表。
- **实现**：`continuations orelse &owned_continuations`。
- **所有权 / 错误 / 调用**：静态图求值传入外部列表。

### `DynamicImportState.waiterList` (`src/exec/module_graph.zig:210`)

- **签名**：`fn waiterList(self: *DynamicImportState) *std.ArrayList(ModuleEvaluationWaiter)`。
- **作用**：对称 waiter。
- **实现**：`waiters orelse &owned_waiters`。
- **所有权 / 错误 / 调用**：create/settle waiter。

### `DynamicImportState.runJobs` (`src/exec/module_graph.zig:217`)

- **签名**：`pub fn runJobs(self: *DynamicImportState, facade_context: *core.JSContext) !void`。
- **作用**：脚本模式 dynamic import：用 state 自有列表排 TLA+FIFO。
- **实现**：`drainModuleJobLoop`。已有 JS 异常/未处理拒绝则吞掉返回错误。
- **所有权 / 错误 / 调用**：CLI 长寿命 state。

### `DynamicImportState.activateRoots` (`src/exec/module_graph.zig:235`)

- **签名**：`fn activateRoots(self: *DynamicImportState) !void`。
- **作用**：把当前 list 指针填进两个 Roots 并 activate。
- **实现**：已 active return。continuation 失败则 errdefer deactivate。
- **所有权 / 错误 / 调用**：`installDynamicImport`。外部列表在 scope 存活期间由这些 provider 独根。

### `DynamicImportState.deactivateRoots` (`src/exec/module_graph.zig:246`)

- **签名**：`fn deactivateRoots(self: *DynamicImportState) void`。
- **作用**：成对撤销。
- **实现**：waiter 先、continuation 后。
- **所有权 / 错误 / 调用**：State.deinit 与 Scope.deinit。

### `DynamicImportState.deinit` (`src/exec/module_graph.zig:256`)

- **签名**：`pub fn deinit(self: *DynamicImportState) void`。
- **作用**：只释放 **state 自有** 调度数据。
- **实现**：deactivate + free owned lists。外部列表由调用方管。
- **所有权 / 错误 / 调用**：静态图求值**不**调这个，避免 double-free。

### `DynamicImportState.load` (`src/exec/module_graph.zig:262`)

- **签名**：`fn load( userdata: ?*anyopaque, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, referrer_path: []const u8, specifier: []const u8, ) core.context.DynamicImportError!core.JSValue`。
- **作用**：安装到 Runtime 的文件加载回调。
- **实现**：`evalDynamicImportModule`；有 pending 异常 → `JSException`（qjs job 把 exception 变成 reject）。
- **所有权 / 错误 / 调用**：`pending_import_type` 由 job 线程局部设置。

### `activeDynamicImportState` (`src/exec/module_graph.zig:289`)

- **签名**：`fn activeDynamicImportState(context: *core.JSContext) ?*DynamicImportState`。
- **作用**：当前 loader 是否本文件的 State.load。
- **实现**：callback 指针比较 + userdata。
- **所有权 / 错误 / 调用**：waiter settle。host-hooks 加载器返回 null。

### `createModuleEvaluationWaiter` (`src/exec/module_graph.zig:296`)

- **签名**：`fn createModuleEvaluationWaiter( state: *DynamicImportState, context: *core.JSContext, global: *core.Object, path: []const u8, ) !core.JSValue`。
- **作用**：模块正在 evaluating（TLA）时，import() 拿到共享评价 Promise。
- **实现**：`promise.withResolvers`；dup path；retain realm；append waiter；返回 promise。
- **所有权 / 错误 / 调用**：`evalDynamicImportModule` evaluating 臂。

### `settleModuleEvaluationWaiters` (`src/exec/module_graph.zig:327`)

- **签名**：`fn settleModuleEvaluationWaiters( context: *core.JSContext, output: ?*std.Io.Writer, path: []const u8, rejected: bool, reason: ?core.JSValue, ) !void`。
- **作用**：兑现/拒绝所有等该 path 的 waiter。
- **实现**：无 State 则 return。成功时 `moduleNamespaceValue`。同 context+path 的 waiter `Call(resolve|reject)` 后 orderedRemove+deinit。
- **所有权 / 错误 / 调用**：`drainOneModuleContinuation` 的 completed+settle_waiters。

### `takeRecordedModuleEvaluationRejection` (`src/exec/module_graph.zig:372`)

- **签名**：`fn takeRecordedModuleEvaluationRejection( runtime: *core.JSRuntime, context: *core.JSContext, path: []const u8, ) !?core.JSValue`。
- **作用**：errored record 的原因：pending exception 或 `eval_exception`。
- **实现**：非 errored → null。
- **所有权 / 错误 / 调用**：deferred start / resume 失败时把原因变成 completed 节点。

### `moduleDependencyRejection` (`src/exec/module_graph.zig:389`)

- **签名**：`fn moduleDependencyRejection( context: *core.JSContext, path: []const u8, ) !?core.JSValue`。
- **作用**：依赖图上是否已有 errored 模块的 eval_exception。
- **实现**：root 模块名；`visited` atom 列表 + `rootAtomList`；`recordDependencyRejection`。
- **所有权 / 错误 / 调用**：`startPreloadedFileModuleStep` 在跑体前复制失败。

### `recordDependencyRejection` (`src/exec/module_graph.zig:410`)

- **签名**：`fn recordDependencyRejection( context: *core.JSContext, record: *const core.module.ModuleRecord, visited: *std.ArrayList(core.Atom), ) !?core.JSValue`。
- **作用**：DFS 请求边，遇 `.errored` 返回其 exception。
- **实现**：atom 去环。
- **所有权 / 错误 / 调用**：后序求值会跳过已 evaluated，单靠 status 分不出 evaluated 与 errored。

### `recordModuleEvaluationRejection` (`src/exec/module_graph.zig:435`)

- **签名**：`fn recordModuleEvaluationRejection( context: *core.JSContext, path: []const u8, reason: core.JSValue, ) !void`。
- **作用**：标 errored，首次写入 `eval_exception`。
- **实现**：已有 exception 不覆盖。
- **所有权 / 错误 / 调用**：依赖失败传播。

### `createModuleAwaitReactionPromise` (`src/exec/module_graph.zig:451`)

- **签名**：`pub fn createModuleAwaitReactionPromise( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, awaited: core.JSValue, ) !core.JSValue`。
- **作用**：把 TLA awaited 值 `Promise.resolve` 再接到 withResolvers，得到内部 reaction promise。
- **实现**：`performPromiseThen(awaited_promise, resolve, reject, undefined, undefined)`。
- **所有权 / 错误 / 调用**：兑现发生在 reaction job 里，resume 抢在下一 job 前（对齐 qjs）。

### `DynamicImportHostState.load` (`src/exec/module_graph.zig:498`)

- **签名**：`fn load( userdata: ?*anyopaque, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, referrer_path: []const u8, specifier: []const u8, ) core.context.DynamicImportError!core.JSValue`。
- **作用**：宿主钩子版 dynamic import 回调。
- **实现**：`evalDynamicImportModuleWithHostHooks`；异常 → JSException；其它 `dynamicImportHostError`。
- **所有权 / 错误 / 调用**：`evalFileModuleGraphWithHostHooks` 安装。

### `evaluateImportCall` (`src/exec/module_graph.zig:535`)

- **签名**：`pub fn evaluateImportCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, prototype: ?*core.Object, referrer_path: []const u8, specifier: core.JSValue, options: core.JSValue, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) exec.exceptions.HostError!core.JSValue`。
- **作用**：`import(specifier, options)` 运行时（specifier 已 ToString）。
- **实现**：options undefined 跳过。非对象 → rejected TypeError。Get `with`；有则必须对象，`buildImportAttributes`。失败全部变成 **rejected promise** 而非抛（qjs `exception:` 标签）。然后 enqueue job。
- **所有权 / 错误 / 调用**：VM `OP_import`。返回 pending promise。

### `buildImportAttributes` (`src/exec/module_graph.zig:579`)

- **签名**：`fn buildImportAttributes( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, attributes_obj: core.JSValue, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) exec.exceptions.HostError!core.JSValue`。
- **作用**：null 原型 attributes 对象：可枚举字符串键，值必须是 String。
- **实现**：`objectRestOwnKeys`（proxy ownKeys 可抛）。跳过 symbol、不可枚举。非字符串值 `throwTypeErrorMessage("module attribute values must be strings")`。Define C_W_E。
- **所有权 / 错误 / 调用**：调用方拥有返回对象。Get 结果不转移所有权。

### `rejectedImportTypeError` (`src/exec/module_graph.zig:626`)

- **签名**：`fn rejectedImportTypeError( ctx: *core.JSContext, global: *core.Object, prototype: ?*core.Object, message: []const u8, ) exec.exceptions.HostError!core.JSValue`。
- **作用**：造 TypeError 并 `rejectedWithPrototype`。
- **实现**：不 throw 到 ctx。
- **所有权 / 错误 / 调用**：options 校验。

### `rejectedImportRuntimeError` (`src/exec/module_graph.zig:639`)

- **签名**：`fn rejectedImportRuntimeError( ctx: *core.JSContext, global: *core.Object, prototype: ?*core.Object, err: exec.exceptions.HostError, ) exec.exceptions.HostError!core.JSValue`。
- **作用**：OOM/ProcessExit/StackOverflow 原样；其它映射成 rejected promise。
- **实现**：`rejectedPromiseForRuntimeError`。
- **所有权 / 错误 / 调用**：Get `with` / 建 attributes 失败。

### `enqueueDynamicImportJob` (`src/exec/module_graph.zig:658`)

- **签名**：`pub fn enqueueDynamicImportJob( ctx: *core.JSContext, global: *core.Object, prototype: ?*core.Object, referrer_path: []const u8, specifier: core.JSValue, ) !core.JSValue`。
- **作用**：无 attributes 的 import()。
- **实现**：attributes=`undefined`。
- **所有权 / 错误 / 调用**：测试/无 options 路径。

### `enqueueDynamicImportJobWithAttributes` (`src/exec/module_graph.zig:668`)

- **签名**：`fn enqueueDynamicImportJobWithAttributes( ctx: *core.JSContext, global: *core.Object, prototype: ?*core.Object, referrer_path: []const u8, specifier: core.JSValue, attributes: core.JSValue, ) exec.exceptions.HostError!core.JSValue`。
- **作用**：withResolvers + 把 resolve/reject/basename/specifier/attributes 送进 typed FIFO。
- **实现**：basename 字符串化 referrer。`enqueueDynamicImport(..., dynamicImportJobRun, ...)`。返回 pending promise。不能同步 `LoadModule`（qjs 注释：会在 `js_evaluate_module` 里意外递归）。
- **所有权 / 错误 / 调用**：job 拥有 attributes 引用。

### `dynamicImportJobRun` (`src/exec/module_graph.zig:707`)

- **签名**：`fn dynamicImportJobRun( ctx: *core.JSContext, output: ?*std.Io.Writer, payload: *const jobs_mod.DynamicImportPayload, ) core.errors.RuntimeError!core.JSValue`。
- **作用**：`js_dynamic_import_job`：跑 loader，settle import() 能力。
- **实现**：字符串化 basename/specifier。把 `importLoaderTypeFromAttributes` 写入 State.pending_import_type（defer 恢复，防重入图排水串味）。调 Runtime dynamic import callback。成功对象若是 Promise（TLA 共享评价）→ `performPromiseThen` 接到 import capability；否则 `Call(resolve, namespace)`。失败（除 OOM/exit/overflow）`dynamicImportRejectionValue` + `Call(reject)`。
- **所有权 / 错误 / 调用**：`drainOnePendingJob` `.dynamic_import`。

### `dynamicImportRejectionValue` (`src/exec/module_graph.zig:790`)

- **签名**：`fn dynamicImportRejectionValue( ctx: *core.JSContext, global: *core.Object, err: anyerror, specifier: []const u8, ) !core.JSValue`。
- **作用**：reject 原因：pending 异常原样；unsupported → TypeError；ModuleNotFound/FileNotFound → 加载器 ReferenceError 形状；否则 sentinel 或 `Error(errorName)`。
- **实现**：`takeException` 优先。
- **所有权 / 错误 / 调用**：job 失败臂。

### `DynamicImportScope.deinit` (`src/exec/module_graph.zig:828`)

- **签名**：`pub fn deinit(self: *DynamicImportScope) void`。
- **作用**：卸 loader **并** deactivateRoots。静态图求值只走这里，不走 State.deinit。
- **实现**：曾把 activate 放 install、deactivate 只放 State.deinit，外部列表的 provider 活过栈帧，下次 GC 踩毒指针。
- **所有权 / 错误 / 调用**：`defer dynamic_import_scope.deinit()`。

### `installDynamicImport` (`src/exec/module_graph.zig:834`)

- **签名**：`pub fn installDynamicImport(state: *DynamicImportState) !DynamicImportScope`。
- **作用**：activateRoots + 安装 `State.load`。
- **实现**：返回 `{ loader, state }`。
- **所有权 / 错误 / 调用**：文件图求值、CLI。

### `runJobs` (`src/exec/module_graph.zig:842`)

- **签名**：`fn runJobs(runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer) !void`。
- **作用**：只排 Promise FIFO（host-hooks 路径没有共享 TLA 列表给 dynamic import）。
- **实现**：`zjs_vm.drainPendingPromiseJobs`；已有异常则吞。
- **所有权 / 错误 / 调用**：`evalFileModuleGraphWithHostHooks` 结尾。与 `DynamicImportState.runJobs` 同名不同层。

### `evalFileModuleGraphWithOutput` (`src/exec/module_graph.zig:851`)

- **签名**：`pub fn evalFileModuleGraphWithOutput( runtime: *core.JSRuntime, context: *core.JSContext, source_text: []const u8, output: *std.Io.Writer, filename: []const u8, io: std.Io, allocator: std.mem.Allocator, max_source_size: usize, ) !core.JSValue`。
- **作用**：CLI/文件入口：preload → link 根 → 后序求值 → TLA drain → job loop。
- **实现**：`call_depth==0` 时 `updateNativeStackTop`。resolve 文件名。preload 后序。根 `import_meta_main=true`。合成模块读盘 init。`linkModule` 失败 `throwModuleLinkError`。`rebuildPendingModuleEvalPostorder`。装 DynamicImportState（外部 continuations/waiters）。依赖：有活动 async 依赖则 deferred start，否则 start+handle。根同样。`drainModuleContinuations` 得 keep_result。最后 `drainModuleJobLoop`（dynamic import 可能又往同一列表丢 TLA）。
- **所有权 / 错误 / 调用**：未处理拒绝 → `UnhandledPromiseRejection`。

### `preloadedModuleNeedsEvaluation` (`src/exec/module_graph.zig:942`)

- **签名**：`fn preloadedModuleNeedsEvaluation(context: *core.JSContext, path: []const u8) bool`。
- **作用**：后序循环的门：已 evaluated/evaluating/errored 不重跑（qjs `js_inner_module_evaluation`）。
- **实现**：intern 失败当 true。find 失败当 true。
- **所有权 / 错误 / 调用**：动态 import 可能在两步之间已经跑过某依赖。

### `evalFileModuleGraphWithHostHooks` (`src/exec/module_graph.zig:953`)

- **签名**：`pub fn evalFileModuleGraphWithHostHooks( runtime: *core.JSRuntime, context: *core.JSContext, source_text: []const u8, output: *std.Io.Writer, filename: []const u8, host_hooks: HostHooks, allocator: std.mem.Allocator, ) !core.JSValue`。
- **作用**：同样的图求值，加载走 HostHooks。
- **实现**：preloadWithHostHooks；link；装 `DynamicImportHostState.load`（不是文件 State）。自己 activate ContinuationRoots。结尾 `runJobs` 排同步完成根入队的 import job。
- **所有权 / 错误 / 调用**：无 WaiterRoots（host 路径用局部 continuations drain 依赖）。

### `initializeSyntheticFileModules` (`src/exec/module_graph.zig:1037`)

- **签名**：`fn initializeSyntheticFileModules( runtime: *core.JSRuntime, context: *core.JSContext, io: std.Io, allocator: std.mem.Allocator, max_source_size: usize, ) !void`。
- **作用**：registry 里每个合成 record 读源文件并 `initializeSyntheticFileModule`。
- **实现**：FileNotFound → throwCouldNotLoadModule。其它 host 错误 throwHostError。
- **所有权 / 错误 / 调用**：link 前，让 wiring 看见 default cell。

### `evalPreloadedFileModuleStep` (`src/exec/module_graph.zig:1069`)

- **签名**：`fn evalPreloadedFileModuleStep( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, filename: []const u8, continuation_value: ?core.JSValue, resume_value: ?core.JSValue, ) !ModuleEvalStep`。
- **作用**：一次模块体：合成直接 evaluated；源模块造/复用 generator continuation 调 `runModuleEvaluationStep`。
- **实现**：status=evaluating；errdefer 变 errored 并缓存 `current_exception`。挂起 → `.suspended`；否则 `.completed` 且 evaluated。
- **所有权 / 错误 / 调用**：`moduleResolutionError` 把 Missing/Ambiguous 映射成 SyntaxError。

### `startPreloadedFileModuleStep` (`src/exec/module_graph.zig:1136`)

- **签名**：`fn startPreloadedFileModuleStep( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, filename: []const u8, ) !ModuleEvalStep`。
- **作用**：开跑前把已终结的依赖失败抄到本 record。
- **实现**：有 `moduleDependencyRejection` → record + throwValue + JSException。否则 `evalPreloadedFileModuleStep(null,null)`。
- **所有权 / 错误 / 调用**：后序与 deferred start。

### `appendModuleEvalStepRetainingOnError` (`src/exec/module_graph.zig:1155`)

- **签名**：`fn appendModuleEvalStepRetainingOnError( context: *core.JSContext, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), step: ModuleEvalStep, filename: []const u8, keep_result: bool, ) !void`。
- **作用**：所有 fallible alloc 成功后才转移 JSValue 所有权。
- **实现**：completed 且 keep_result → 已完成节点（awaited=value）。suspended → 未完成节点。completed 且 !keep_result 丢弃值。
- **所有权 / 错误 / 调用**：path dup + RealmRef.retain；失败 errdefer 放掉。

### `enqueueDeferredModuleStart` (`src/exec/module_graph.zig:1198`)

- **签名**：`fn enqueueDeferredModuleStart( context: *core.JSContext, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), filename: []const u8, keep_result: bool, ) !void`。
- **作用**：依赖还在 TLA 上：占位 continuation，`deferred_start=true`，status=evaluating。
- **实现**：空 continuation/awaited。
- **所有权 / 错误 / 调用**：GatherAvailableAncestors：依赖兑现的同一 job 里把 ready 置位再 start。

### `drainModuleContinuations` (`src/exec/module_graph.zig:1228`)

- **签名**：`fn drainModuleContinuations( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), ) !core.JSValue`。
- **作用**：直到列表空，保留 keep_result 的完成值。
- **实现**：stalled 且没有 host 事件 → `throwModuleHostStall` unreachable。
- **所有权 / 错误 / 调用**：根模块 TLA。

### `drainModuleContinuationsForDependencies` (`src/exec/module_graph.zig:1257`)

- **签名**：`fn drainModuleContinuationsForDependencies( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), filename: []const u8, ) !void`。
- **作用**：host-hooks 路径：在跑 filename 前排空它的活动 async 依赖。
- **实现**：循环直到 `!hasActiveAsyncDependency`；再检查依赖 rejection。
- **所有权 / 错误 / 调用**：`evalDynamicImportModuleWithHostHooks`。

### `drainModuleJobLoop` (`src/exec/module_graph.zig:1285`)

- **签名**：`fn drainModuleJobLoop( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), ) !void`。
- **作用**：一条 TLA 工作 ↔ 一条 FIFO/host 事件，直到两边都静。
- **实现**：有 continuation 则 `drainOneScheduledModuleWork`；progressed/value continue。否则 `drainOneModuleQueuedOrHostJob`。
- **所有权 / 错误 / 调用**：文件图求值结尾、`DynamicImportState.runJobs`。

### `drainOneModuleQueuedOrHostJob` (`src/exec/module_graph.zig:1306`)

- **签名**：`fn drainOneModuleQueuedOrHostJob( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, ) !bool`。
- **作用**：一条 Promise job，空则一条 host 事件。
- **实现**：`.exception` → JSException。
- **所有权 / 错误 / 调用**：runtime 未用。

### `drainOneModuleHostEvent` (`src/exec/module_graph.zig:1321`)

- **签名**：`fn drainOneModuleHostEvent(context: *core.JSContext, output: ?*std.Io.Writer) !bool`。
- **作用**：signal / rw / timer / atomics 各试一次。
- **实现**：任一 true。atomics 不阻塞（`false`）。
- **所有权 / 错误 / 调用**：TLA stall 时泵宿主。

### `prepareModuleContinuationAwait` (`src/exec/module_graph.zig:1335`)

- **签名**：`fn prepareModuleContinuationAwait( runtime: *core.JSRuntime, output: ?*std.Io.Writer, continuations: *const std.ArrayList(ModuleContinuation), continuation: *ModuleContinuation, ) !void`。
- **作用**：规范化 awaited、看 promise 是否已 settle，置 `ready`。
- **实现**：completed/ready 跳过。deferred_start：无活动 async 依赖则 ready。否则首次 `createModuleAwaitReactionPromise`。promise 无 result return；rejected 则 `markHandled`；有 result → ready。
- **所有权 / 错误 / 调用**：每个 drain tick 对所有条目调用。

### `nextReadyModuleContinuation` (`src/exec/module_graph.zig:1370`)

- **签名**：`fn nextReadyModuleContinuation(continuations: *const std.ArrayList(ModuleContinuation)) ?usize`。
- **作用**：FIFO 里第一个 completed 或 ready 的下标。
- **实现**：线性扫。
- **所有权 / 错误 / 调用**：与 Promise reaction 一样一次一项。

### `drainOneScheduledModuleWork` (`src/exec/module_graph.zig:1378`)

- **签名**：`fn drainOneScheduledModuleWork( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), ) !ModuleDrainResult`。
- **作用**：先 prepare 全部；有 ready 则 drain 该 continuation；否则一条 Promise job；再否则 stalled。
- **实现**：`nextReadyModuleContinuation` 已经同时接受 completed 与 ready 两种状态，两者也都走同一个 `drainOneModuleContinuation`，所以原先那条单独判 `continuation.completed` 的分支（与其后的通用分支逐字相同）已删。
- **所有权 / 错误 / 调用**：job exception → JSException。

### `reinsertRemovedModuleStep` (`src/exec/module_graph.zig:1414`)

- **签名**：`fn reinsertRemovedModuleStep( _: *core.JSRuntime, continuations: *std.ArrayList(ModuleContinuation), index: usize, current: ModuleContinuation, step: ModuleEvalStep, completion_rejected: bool, ) !void`。
- **作用**：列表仍有该槽容量：按 step 重写节点，`insertAssumeCapacity` 保持 FIFO。
- **实现**：清 deferred/normalized/ready；completed 清 continuation。
- **所有权 / 错误 / 调用**：无分配；OOM 安全。

### `retainRemovedModuleStep` (`src/exec/module_graph.zig:1451`)

- **签名**：`fn retainRemovedModuleStep( runtime: *core.JSRuntime, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), index: usize, current: ModuleContinuation, step: ModuleEvalStep, completion_rejected: bool, ) !void`。
- **作用**：resume 之后的新 step 必须可重试：completed 原地重插；suspended 先 append（新 path），失败则原地恢复旧节点。
- **实现**：append 成功则 free 旧 path/realm，把尾节点搬回原 index。
- **所有权 / 错误 / 调用**：`drainOneModuleContinuation` 在从列表取出之后。

### `drainOneModuleContinuation` (`src/exec/module_graph.zig:1501`)

- **签名**：`fn drainOneModuleContinuation( runtime: *core.JSRuntime, output: ?*std.Io.Writer, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), index: usize, ) !?core.JSValue`。
- **作用**：取出一条：完成则 settle waiter 并可能返回 keep_result；deferred 则 start；否则用 promise result resume 模块体。
- **实现**：orderedRemove 后条目离开 ContinuationRoots，故本帧 `ValueRootFrame` 根住 continuation+awaited。errdefer 按 `restore_current` 插回。completed：settle_waiters 后 free path；rejected+keep_result → throw。deferred：start 失败若有 cached rejection 则 retain 为 completed rejected。resume：无 result → host stall unreachable。`setGeneratorResumeCompletionType` 0/2。失败同样缓存。成功 retain 新 step。未处理拒绝 → UnhandledPromiseRejection。
- **所有权 / 错误 / 调用**：OOM/ProcessExit 不吞，restore 原节点。

### `hasActiveAsyncDependency` (`src/exec/module_graph.zig:1625`)

- **签名**：`fn hasActiveAsyncDependency( context: *core.JSContext, continuations: *const std.ArrayList(ModuleContinuation), filename: []const u8, ) !bool`。
- **作用**：filename 的依赖是否仍有未完成 continuation。
- **实现**：atom visited 根；`recordHasActiveAsyncDependency`。
- **所有权 / 错误 / 调用**：后序跳过、deferred start、prepare deferred ready。

### `recordHasActiveAsyncDependency` (`src/exec/module_graph.zig:1646`)

- **签名**：`fn recordHasActiveAsyncDependency( context: *core.JSContext, continuations: *const std.ArrayList(ModuleContinuation), record: *const core.module.ModuleRecord, ignored_path: []const u8, visited: *std.ArrayList(core.Atom), ) !bool`。
- **作用**：请求边：同 realm 且 path 匹配未完成 continuation（忽略自身 path），或递归依赖。
- **实现**：atom 去环。
- **所有权 / 错误 / 调用**：ignored_path 避免把自己的占位算进去。

### `freeModuleContinuations` (`src/exec/module_graph.zig:1671`)

- **签名**：`fn freeModuleContinuations( _: *core.JSRuntime, allocator: std.mem.Allocator, continuations: *std.ArrayList(ModuleContinuation), ) void`。
- **作用**：free 每条 path、deinit realm、deinit 列表。
- **实现**：不显式 free JSValue。
- **所有权 / 错误 / 调用**：求值器 defer。

### `freeModuleEvaluationWaiters` (`src/exec/module_graph.zig:1683`)

- **签名**：`fn freeModuleEvaluationWaiters( runtime: *core.JSRuntime, allocator: std.mem.Allocator, waiters: *std.ArrayList(ModuleEvaluationWaiter), ) void`。
- **作用**：逐个 waiter.deinit + 列表 deinit。
- **实现**：runtime 传给 waiter.deinit（未用）。
- **所有权 / 错误 / 调用**：求值器 defer。

### `moduleResolutionError` (`src/exec/module_graph.zig:1692`)

- **签名**：`pub fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError})`。
- **作用**：链接的 MissingExport/AmbiguousExport 对用户是 SyntaxError。
- **实现**：其它错误原样。
- **所有权 / 错误 / 调用**：link 失败返回、eval step catch。

### `evalDynamicImportModule` (`src/exec/module_graph.zig:1699`)

- **签名**：`fn evalDynamicImportModule( state: *DynamicImportState, context: *core.JSContext, output: ?*std.Io.Writer, referrer_path: []const u8, specifier: []const u8, import_type: ImportLoaderType, ) !core.JSValue`。
- **作用**：文件加载器：解析、preload 缺失图、link、后序求值、返回 namespace 或 waiter promise。
- **实现**：空 referrer / 解析失败 → throwCouldNotLoadModule。`.json` 后缀或 type json/text → 合成 registry 名。已 errored → 重抛缓存；evaluated → namespace；evaluating → waiter。合成读盘 init；否则 init 全 registry 合成。link。后序只跑 `moduleNeedsEvaluation` 的源模块。结束后仍非 evaluated → waiter。
- **所有权 / 错误 / 调用**：`State.load`。skip-existing preload 保活绑定。

### `throwCachedModuleEvalException` (`src/exec/module_graph.zig:1876`)

- **签名**：`fn throwCachedModuleEvalException( runtime: *core.JSRuntime, context: *core.JSContext, record: *core.module.ModuleRecord, ) error{JSException}`。
- **作用**：重抛 `eval_exception`（qjs DupValue + throw）。
- **实现**：有则 `throwValue`；总返回 JSException。
- **所有权 / 错误 / 调用**：不重跑函数体。

### `throwModuleLinkError` (`src/exec/module_graph.zig:1890`)

- **签名**：`pub fn throwModuleLinkError( runtime: *core.JSRuntime, context: *core.JSContext, filename: []const u8, err: anyerror, diagnostic: ?*const exec.module.LinkDiagnostic, ) !void`。
- **作用**：qjs 形 SyntaxError：`Could not find export 'x' in module 'y'` / `export 'x' ... is ambiguous` / 否则 `could not link module`。
- **实现**：只格式第一条诊断。
- **所有权 / 错误 / 调用**：图求值与 dynamic import link 失败。

### `evalDynamicImportModuleWithHostHooks` (`src/exec/module_graph.zig:1918`)

- **签名**：`fn evalDynamicImportModuleWithHostHooks( runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer, host_hooks: HostHooks, referrer_path: []const u8, specifier: []const u8, allocator: std.mem.Allocator, ) !core.JSValue`。
- **作用**：resolve+load 钩子版：preload 该子图、link、按依赖 drain TLA、求值、返回 namespace。
- **实现**：空 referrer → ModuleNotFound。`wrapSourceByKind`。局部 continuations + ContinuationRoots。每路径先 `drainModuleContinuationsForDependencies`。
- **所有权 / 错误 / 调用**：`HostState.load`。loaded.owned 控制 source free。

### `moduleNeedsEvaluation` (`src/exec/module_graph.zig:2002`)

- **签名**：`fn moduleNeedsEvaluation(record: *const core.module.ModuleRecord) bool`。
- **作用**：unlinked/linked 才需要跑体。
- **实现**：linking/evaluating/evaluated/errored 为假。
- **所有权 / 错误 / 调用**：注意 unlinked 在 link 失败回滚后仍为真；调用方应已 link。

### `dynamicImportHostError` (`src/exec/module_graph.zig:2009`)

- **签名**：`fn dynamicImportHostError(err: anyerror) core.context.DynamicImportError`。
- **作用**：把任意错误收成加载器错误集。
- **实现**：文件/包错误 → ModuleNotFound；未知 → Unexpected。
- **所有权 / 错误 / 调用**：HostState.load。

### `appendPendingModuleEvalPostorder` (`src/exec/module_graph.zig:2024`)

- **签名**：`fn appendPendingModuleEvalPostorder( context: *core.JSContext, allocator: std.mem.Allocator, module_name: core.Atom, seen: *std.ArrayList(core.Atom), postorder: *std.ArrayList([]const u8), ) !void`。
- **作用**：从当前 registry 边重建「仍需求值」的后序。
- **实现**：atom seen 去环；先递归请求，再若 `moduleNeedsEvaluation` 则 dup 路径。
- **所有权 / 错误 / 调用**：动态 import 时部分模块可能已 evaluated。

### `rebuildPendingModuleEvalPostorder` (`src/exec/module_graph.zig:2051`)

- **签名**：`fn rebuildPendingModuleEvalPostorder( context: *core.JSContext, allocator: std.mem.Allocator, root_module_name: core.Atom, postorder: *std.ArrayList([]const u8), ) !void`。
- **作用**：丢掉 preload 后序，按 live 图重填。
- **实现**：free 旧 path，`clearRetainingCapacity`。
- **所有权 / 错误 / 调用**：link 之后、求值之前。

### `preloadFileModuleGraphWithHostHooks` (`src/exec/module_graph.zig:2075`)

- **签名**：`fn preloadFileModuleGraphWithHostHooks( allocator: std.mem.Allocator, runtime: *core.JSRuntime, context: *core.JSContext, host_hooks: HostHooks, root_source: []const u8, root_path: []const u8, postorder: *std.ArrayList([]const u8), ) !void`。
- **作用**：宿主钩子路径的图预加载入口：建 `seen` 列表后跑递归体。
- **实现**：本地建 `seen`（`defer` 逐条 free）再调 `preloadFileModuleGraphWithHostHooksInner`。原先只为传 `skip_existing` 的 `...Mode` 中间层已折叠进来：跳过已加载模块不是可选模式，由 Inner 里「requests 已 resolved 的 record 早退」实现。
- **所有权 / 错误 / 调用**：`seen` 的路径本函数建本函数释放。宿主图求值入口。

### `trackedPathContains` (`src/exec/module_graph.zig:2101`)

- **签名**：`fn trackedPathContains(paths: *const std.ArrayList([]const u8), path: []const u8) bool`。
- **作用**：seen 去重。
- **实现**：`mem.eql`。
- **所有权 / 错误 / 调用**：Inner 开头与加载依赖前。

### `validateHostResolvedRecord` (`src/exec/module_graph.zig:2108`)

- **签名**：`fn validateHostResolvedRecord( context: *core.JSContext, record: *core.module.ModuleRecord, module_name: core.Atom, resolved_atoms: []const core.Atom, ) !void`。
- **作用**：重入后仍在的 record 必须与本次 resolve 形状一致。
- **实现**：registry、名字、每条 request.module_name。
- **所有权 / 错误 / 调用**：`ForeignModuleRecord` / `InvalidBytecode`。

### `validateHostRequestDependency` (`src/exec/module_graph.zig:2122`)

- **签名**：`fn validateHostRequestDependency( context: *core.JSContext, record: *core.module.ModuleRecord, request_index: usize, ) !void`。
- **作用**：边必须指向 canonical find(module_name)。
- **实现**：缺 module、registry 不一致、名字不一致、非 canonical → 错。
- **所有权 / 错误 / 调用**：setRequestModule 前后。

### `preloadFileModuleGraphWithHostHooksInner` (`src/exec/module_graph.zig:2136`)

- **签名**：`fn preloadFileModuleGraphWithHostHooksInner( allocator: std.mem.Allocator, runtime: *core.JSRuntime, context: *core.JSContext, host_hooks: HostHooks, source_text: []const u8, path: []const u8, seen: *std.ArrayList([]const u8), postorder: *std.ArrayList([]const u8), ) !void`。
- **作用**：宿主 resolve 每个请求、load 源、递归、安装 resolved artifact。
- **实现**：跳过已加载模块由「已 resolved 的 record 早退」实现（原先那个从不读的 `skip_existing` 形参已整链删除）。compile；syntax 抛。对每个请求 `host_hooks.resolveModule`，intern path 为 atom（root 只扫已写前缀）。resolve 钩子可重入并完成同一 record：之后 find 或 `installResolvedModuleArtifact`。`validateHostResolvedRecord`。已 resolved return。对未完成依赖 load+`wrapSourceByKind` 递归。`setRequestModuleNoFail` + validate。mark resolved，postorder append。
- **所有权 / 错误 / 调用**：resolved specifier/path 在 defer 里 free。重入完成合法，API 幂等。

### `wrapSourceByKind` (`src/exec/module_graph.zig:2303`)

- **签名**：`fn wrapSourceByKind( allocator: std.mem.Allocator, kind: HostHooks.ModuleKind, source: []const u8, path: []const u8, allocated: *bool, ) ![]const u8`。
- **作用**：把非 ESM 源包成可 parse 的模块文本。
- **实现**：esm/builtin 原样 `allocated=false`。json → `export default {source};`。commonjs → function 包装 + `export default module.exports`。wasm → Uint8Array 字面量 + WebAssembly.Instance + `export default instance.exports`。
- **所有权 / 错误 / 调用**：`allocated=true` 时调用方 free。wasm 引擎若无 WebAssembly 会在求值时报错。

## 覆盖核对

- 清单函数数: 136（`src/exec/module.zig` 60 + `src/exec/module_graph.zig` 76）
- 本文标题覆盖: 136
- 未覆盖: 无
