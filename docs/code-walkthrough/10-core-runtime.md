# 10 — Runtime / Context / Jobs / 模块记录

本册讲引擎的**所有权中枢**：谁拥有堆、谁在哪条线程上变异、值怎样在宿主边界上活过一次调用、Promise 任务如何排队、realm 如何发表、模块记录在 core 层长什么样。GC 算法本身在 [09-gc.md](09-gc.md)；本册只讲 Runtime 如何**调度**收集、如何挂根。

源码权威仍是 `src/core/*.zig`。函数级正文按文件拆：

| 分册 | 覆盖 |
| --- | --- |
| 本文件 | 地图、owner 线程、句柄、job vs 事件循环、模块记录字段、`src/core/root.zig` |
| [10-core-runtime-runtime.md](10-core-runtime-runtime.md) | `src/core/runtime.zig`（304 个清单条目） |
| [10-core-runtime-context.md](10-core-runtime-context.md) | `src/core/context.zig`（106 个清单条目） |
| [10-core-runtime-jobs-module.md](10-core-runtime-jobs-module.md) | `jobs.zig`（51）+ `module.zig`（57） |
| [10-core-runtime-containers.md](10-core-runtime-containers.md) | list / array_list_erased / sort_erased / bulk_memory / global_slots / profile |

`src/core/errors.zig` 属 06 册；`module_auto_init.zig` 属 08 册。`src/exec/module.zig` 是链接与求值，不是本册的 `core/module.zig`。

---

## 1. Runtime owner 线程

`JSRuntime` **单线程所有权**。`initWithAccount` 把 `owner_thread_id` 钉成 `std.Thread.getCurrentId()`。之后：

- `isOwnerThread`：比较当前 tid。
- `requireOwnerThread`：错线程 → `error.WrongRuntimeThread`，不改状态。宿主边界（`tryDestroy`、`pollGCChecked`、`newClassId`、`createWithPublication`）走这条。
- `assertOwnerThread`：错线程显式 `@panic`，安全检查关闭时也保留。部分内部入口使用它，但并非所有 getter、setter 或句柄包装都自行检查线程。

创建、变异、收集、销毁须遵守 owner 线程契约。checked 宿主边界可返回错误，其他接口可能 panic 或依赖调用方保证；不能把 Runtime 的单线程契约理解为每个方法都自动拒绝跨线程调用。

**例外的同步缝**：`host_completion_event`（`std.Io.Event`）给 Atomics.waitAsync 这类「别的线程做完、必须回 owner 线程跑 JS」的完成信号。信号本身不携带 JS 状态；reset 要在 producer registry mutex 下做，避免 lost-wakeup。真正的 waiter 条目仍是 `jobs.Queue` 里的 `atomics_waiter`，只在 owner 线程 `run`。

进程级、自带同步的设施（动态 `ClassId` 分配）独立于本契约。

`HotExecState` 将调用深度、逻辑栈预算、活跃字节码帧字节数与 native 栈检查状态集中在 extern 结构中；Runtime 的 hot 和 vm_stack 字段均要求 64 字节对齐。具体偏移、缓存行数量及加载指令仍取决于目标平台和编译结果，字段声明不保证特定机器码。

---

## 2. HandleScope / Local / Persistent / Weak

裸 `JSValue` 的位拷贝不建立强根。需要跨越可能触发 GC 的引擎调用时，应由句柄、已声明根或可达堆边保持其引用目标存活。常用机制如下：

```
HandleScope.enter(rt)          记下 local_root_slots.len
  scope.local(value)           LocalHandle → 槽在 local 数组，scope.deinit 时整段拆掉
JSValueHandle.init(rt, value)  Persistent：独立 RootSlot，活过 scope
WeakPersistentValue.init(...)  WeakRootSlot：身份 + 可选死亡回调，不保持目标活
NativePin                      gc.pinHeader，native 回调期间防 sweep
```

**Local**：`HandleScope` 是水位。`local`/`localDup` 把值放进 `rt.local_root_slots`。`deinit` 调 `clearLocalRootSlotsFrom(start)`。必须 LIFO 嵌套。tracing 下 `initDup`≡`init`（位拷贝，槽即根）。

**Persistent**（`JSValueHandle`）：`createPersistentRootSlot`。`get` 读值副本；`take` 拆槽后返回值，此时该持久根已撤销，需要调用方承接保活；`deinit` 拆根不返回值。Runtime teardown 若仍有 local、persistent 或 weak 槽会 panic，包括目标已死亡但尚未关闭的弱句柄。

**Weak**：身份编码对象 `weak_id<<1`、符号 `(atom<<1)|1`。对象 id 单调递增，双表 `weak_object_ids` / `weak_id_objects`。TGC S4-e：对象身份不计数；死亡在 `destroyFromHeader` 里 `takeWeakObjectIdentity` 交回 token，「表中有」就是活。符号仍走 atom 弱计数。`WeakRef.deref` 成功后 `keepAliveWeakRefTarget` 把目标放进当前 job 的 `weakref_kept_alive`（spec [[KeptAlive]]），**job 结束**才 `clearWeakRefKeptAlive`，不是任意 safepoint。

**ValueRootFrame**：native 帧里声明根的 LIFO 链（`rt.active_value_roots`）。生产默认只链接有 slices 或 atoms 描述符的帧；标量 scope 是空操作，不能依靠它自动建立精确根。生产保守扫描由 `!scheduler.host_quiescent` 控制，宿主声明静止时须确保所需值有其他根。启用标量根的配置中，scope 也必须在最终稳定地址 activate，描述符及其借用存储须在撤销前有效。

**RootProvider**：host 精确根（realm create-ref）。`JSContext.destroy` 只消耗 create-ref 并注销 provider；realm 作为堆节点继续活到不可达。`context_head` membership **不是**根。

---

## 3. Job 队列 vs 事件循环

两套东西，core 边界故意切开：

| | `core/jobs.Queue` | `HostEventLoop` / `runtime/event_loop.zig` |
| --- | --- | --- |
| 谁拥有 | `JSRuntime.job_queue` | 宿主，经 `JSContext.setHostEventLoop` 挂上 |
| 装什么 | Promise reaction/thenable/settlement、async resume、dynamic import、Atomics waiter、FinalizationRegistry、generic `Func` | timer、fd rw、signal、exit code |
| 何时跑 | exec 在 checkpoint / `await` / 微任务点 drain | 宏任务：宿主循环 `runNextTimer` 等 |
| 对应 qjs | `rt->job_list`，`JS_EnqueueJob` / `JS_ExecutePendingJob` | `quickjs-libc` os 循环 |

`Job` 钉 128 字节，带 `RealmRef`（条目自己的 realm，不是正在 drain 的宿主 context）和 typed `Payload` union。`Job.run` **只**跑 generic；其它 Kind 由 exec 按 tag 取 payload。队列是数组窗口：`takeFirst` O(1) 前移 `head`（qjs `list_del`），`reserved_entries` 让事务准备期间重入的普通 job 仍排在前面，`unlinked_head_slots` 给可重试宿主完成 `prependReserved`。

队列中的realm与payload是被追踪的边，RealmRef.retain仅复制指针，不自行注册根。预留额度只保证容量，不占FIFO位置；普通enqueue失败仍由调用方持有并清理输入任务。takeFirst出队后，Queue.traceRoots不再访问该条目，执行层须提供运行期间保护，并最终清理或重新提交。

FinalizationRegistry 的 JS 回调走 job FIFO。插件/class payload 析构走 **另一条** `deferred_class_payload_finalizers` 队列，必须在 collector idle 后跑（`drainDeferredClassPayloadFinalizersAtSafeBoundary`），active job 期间拒绝新收集。

---

## 4. 模块记录字段（core，不是 exec）

`ModuleRecord` 272 字节、16 对齐、`header` 在 offset 0。QuickJS `JSModuleDef`（quickjs.c:888-936）。可达realm经Registry追踪记录，Registry.deinit仅摘成员关系而不销毁记录；request 边**借用**同表指针，不 retain、不 trace（对齐 `JSReqModuleEntry.module`）。

| 字段 | 作用 |
| --- | --- |
| `header` | GC 节点，`gc_kind_tag = module` |
| `registry_prev/next` / `registry` | 加载列表，不是 GC 链 |
| `memory` / `atoms` / `module_name` | 账户与名字 |
| `definition_installed` | `replaceDefinitionNoFail` 之后 |
| `requests_resolved` | 每条 request.module 已填。循环加载可先发表定义，link/eval 不得观察未 resolved 图 |
| `status` | `unlinked` → `linking` → `linked` → `evaluating` → `evaluated` / `errored` |
| `requests/imports/exports/indirect_exports/star_exports/import_attributes` | 编译产物切片 |
| `func_obj` | FunctionBytecode **或** 模块函数；core 不解码 |
| `module_ns` | 完全构造后才 `publishModuleNamespaceNoFail` |
| `namespace_auto_init_owner` | 每记录一个 MODULE_NS AUTOINIT opaque；属性经 `(record, atom)` 再解析。默认 stub 返回 `InvalidBuiltinRegistry`，exec 在发表 ns 前换 resolver |
| `import_meta` / `import_meta_main` | `import.meta` |
| `synthetic_kind` / `has_top_level_await` | JSON/text/bytes 与 TLA |
| `link_dfs_*` / `link_stack_prev` | Tarjan 瞬时，仅 `.linking` |
| `eval_exception` | 求值失败缓存；之后 import 重抛（qjs 31442） |
| `ExportEntry.retained_cell` | 链接留下的 VarRef，使 live binding 在模块函数销毁后仍活 |

`PendingDefinition` 在 registry 外建完整定义（含初始字节码），`prepareFreshTarget` 要么返回已有世代（不动 pending），要么分配+转移+GC 发表+链表，**唯一可失败步是分配**。OOM 不能留下半条记录。

`Registry.resolveExport` 基于现有元数据解析：不加载、不改status，但会分配当前递归路径的临时数组，可能OOM。它不预检requests_resolved，仅在访问依赖边时验证目标；环检测键为(module,export_name)，出栈后允许其他分支重访。star 导出歧义用 `ResolvedBinding.sameIdentity`（namespace 绑定规范到目标模块的 `*`）。

---

## 5. `src/core/root.zig` — core 聚合根（零函数）

清单 0 个函数。文件职责：把 core 身份与嵌入选项类型 re-export 成 exec/runtime/binding 与公共 facade 的合法 import 面。**不增加所有权**；寿命契约留在定义模块。`check_deps` 禁止 core 实现再依赖 parser/exec/runtime/binding/builtins/CLI。QuickJS 没有对应翻译单元，这是 zjs 的层边界。

`pub const subsystem_name = "core_runtime"`。

### 子模块 re-export

`value`、`value_semantics`、`value_format`、`value_string`、`number`、`list`、`gc`、`atom`、`string`、`bigint`、`class`、`shape`、`global_slots`、`function`、`function_bytecode`（来自 `../bytecode.zig` 的 function_bytecode 成员，并非整个bytecode模块）、`module`、`property`、`promise`、`jobs`、`json`、`regexp`、`uri`、`symbol`、`host_function`、`native_entry`、`native_object`、`descriptor`、`object`、`var_ref`、`array`、`collection`、`typed_array`、`typed_array_names`、`error_names`、`errors`、`runtime`、`context`、`exception`、`memory`、`profile`、以及 GC 实现：`gc_address_registry`、`gc_space`、`gc_block_heap`、`gc_carrier`、`gc_trace_stw`、`gc_conservative`。

### 常用类型别名

`JSValue` / `JSString` / `JSBytes` / `Tag` / `Atom` / `AtomTable` / `ClassId` / `Shape` / `FunctionBytecode` / `ModuleRecord` / `Object` / `ObjectFlags` / `VarRef` / `Descriptor` / `JSRuntime` / `VmStackArena` / `JSContext` / `RealmContext` / `RealmRef` / `JSValueHandle` / `LocalHandle` / `HandleScope` / `WeakPersistentCallback` / `WeakPersistent` / `WeakPersistentValue` / `NativePin` / `RuntimeOptions` / `RuntimeMemoryUsage` / `DynamicImportLoader` / `DynamicImportLoaderScope` / `DynamicImportCallback` / `ContextOptions` / `GCPolicy` / `GCStats` / `GCPauseDistribution` / `EvalMode` / `EvalOptions` / `EvalTiming` / `DataPropertyOptions` / `PropertyAccessOptions` / `PropertyDescriptor` / `FunctionCallOptions` / `ErrorOptions` / `ScriptEvalOptions` / `SharedArrayBufferRef` / `BacktraceFrame` / `ActiveBacktraceFrame` / `ActiveBacktraceSnapshot` / `BacktraceLocation` / `BacktraceLocationResolver` / `OpcodeProfile`。

`JSString` / `JSBytes` 分别别名到JSValue.String / JSValue.Bytes；RuntimeMemoryUsage来自runtime.MemoryUsage，EvalOptions / EvalTiming分别来自context.ContextEvalOptions / ContextEvalTiming，GCPolicy / GCStats / GCPauseDistribution分别来自gc.Policy / Stats / PauseDistribution。别名没有新建独立类型或实例。

`NativeEntry` 与 `NativeType` 从 `native_entry` / `native_object` 再导出一次，方便 `const core = @import("core/root.zig")` 的调用方。

读本册时：改句柄或 GC 调度打开 runtime 分册；改 realm 发表/异常/backtrace 打开 context；改微任务或模块记录打开 jobs-module；改链表/剖析打开 containers。

---

## 覆盖核对

- 清单函数数: 566（root 0 + runtime 304 + context 106 + jobs 51 + module 57 + global_slots 3 + list 7 + array_list_erased 7 + sort_erased 5 + bulk_memory 1 + profile 25）；清单含测试辅助项，不等同于本次非测试语义核查范围。
- 本文标题覆盖: 见 `_check_coverage.py`（按源文件、行号与函数标题匹配；结构匹配不能证明正文语义正确）
- 未覆盖: 无

```sh
python3 docs/code-walkthrough/_check_coverage.py \
    --docs 'docs/code-walkthrough/10-*.md' \
    src/core/root.zig src/core/runtime.zig src/core/context.zig \
    src/core/jobs.zig src/core/module.zig src/core/global_slots.zig \
    src/core/list.zig src/core/array_list_erased.zig src/core/sort_erased.zig \
    src/core/bulk_memory.zig src/core/profile.zig
```
