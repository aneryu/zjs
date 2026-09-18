# 08 — RegExp class 谓词、Promise 对象、VarRef、Generator 驻留态

覆盖 `regexp.zig`、`promise.zig`、`var_ref.zig`、`generator_state.zig`。

Promise **对象状态**在 `core/promise.zig` + `PromisePayload`；**抽象操作**（Then、reaction 执行、species）在 `exec/promise_ops.zig`。见主册第 5 节。

## `regexp.zig` 类型

`ClassRangeAtomKind`：`single` / `character_class`。`ClassRangeAtom`：`kind` + `value: u32`（单码点或 `\d` 的 escape 字节）。

本文件是字面 character class / 单 escape 对一个 UTF-16 unit 的简化纯谓词，不是完整正则编译器或严格输入验证器。当前 exec/regexp_ops.zig 仅重导出 classMatchesUtf16Unit；源码搜索未见这些解析 helper 在 exec 校验器中的直接使用。实际 compilePatternAndFlags 从 libs/regexp.zig 导出，不能沿用旧注释所称“校验仍共享本文件解析原语”的调用关系。Unicode 分类器实际导入 libs/unicode.zig。

### `classMatchesUtf16Unit` (`src/core/regexp.zig:31`)

- **签名**：`pub fn classMatchesUtf16Unit(source: []const u8, unit: u16) bool`。
- **作用**：用简化字符类语法判断一个 UTF-16 code unit。
- **实现**：两字节反斜杠转义先尝试六类 escape；否则要求首尾方括号，处理前导^。逐 atom 扫描，两个 single 由短横相连时用 min/max 构造闭区间；普通 single 比较数值，character_class 委托六类匹配。最后按 negated 取反。
- **所有权 / 错误 / 调用**：不分配、无 flags 参数；不是完整语法验证或 Unicode code-point matcher。反向范围也按 min/max 匹配；读 atom 失败只向前移一字节，非法输入不保证 false。属性 escape 产生默认值0的 character_class，不贡献匹配，取反类仍会把结果反转。

### `readClassRangeAtom` (`src/core/regexp.zig:92`)

- **签名**：`pub fn readClassRangeAtom(pattern: []const u8, index: *usize) ?ClassRangeAtom`。
- **作用**：读取单个字符类 atom 并更新索引。
- **实现**：越界、右方括号或末尾单反斜杠返回 null。非转义按 UTF-8 长度尝试解码，解码失败回退首字节但仍消费检测出的序列长度。支持六类 escape、控制字符、定长/花括号hex、c后字节与0x1f、连续八进制；其他转义返回被转义字节。p/P 经属性校验通过后返回 value=0 的 character_class，校验失败（格式错或属性名不受支持）返回 null。
- **所有权 / 错误 / 调用**：不是严格正则解析器：c后不要求字母，八进制不限制位数，u32算术不作checked保护；8/9进入数字分支但不消费八进制位，返回0且索引停在该数字。属性校验失败不更新原索引，无效UTF-8也可能返回single。

### `readFixedHexClassRangeAtom` (`src/core/regexp.zig:169`)

- **签名**：`fn readFixedHexClassRangeAtom(pattern: []const u8, index: *usize, prefix_len: usize, digit_count: usize) ?ClassRangeAtom`。
- **作用**：解析指定数量的十六进制位。
- **实现**：从 index+prefix_len 开始；位数不足或任一非hex时只消费前缀，返回前缀最后字节。成功累积u32并消费所有数字。
- **所有权 / 错误 / 调用**：当前调用为 x两位/u四位，函数虽返回optional却没有null路径；依赖调用者提供合法前缀位置，不是通用输入校验器。

### `readUnicodeClassRangeAtom` (`src/core/regexp.zig:189`)

- **签名**：`fn readUnicodeClassRangeAtom(pattern: []const u8, index: *usize) ?ClassRangeAtom`。
- **作用**：解析 u 转义的花括号或四位形式。
- **实现**：第三字节为左花括号则读取至少一位hex至右花括号；成功消费闭括号，非法数字/空内容/缺闭合均仅消费反斜杠u并返回字面u。否则委托定长四位解析。
- **所有权 / 错误 / 调用**：不检查Unicode标量上限、代理项或正则u/v标志；任意长hex以普通u32算术累积，不能描述为对所有畸形输入都安全拒绝。返回值可超过单UTF-16 unit范围。

### `isCharacterClassEscape` (`src/core/regexp.zig:212`)

- **签名**：`pub fn isCharacterClassEscape(byte: u8) bool`。
- **作用**：识别六种字符类 escape 字节。
- **实现**：仅 d/D/s/S/w/W 返回true。
- **所有权 / 错误 / 调用**：输入是不带反斜杠的字节；不包含p/P，不分配或修改状态。

### `characterClassEscapeUnitMatches` (`src/core/regexp.zig:218`)

- **签名**：`fn characterClassEscapeUnitMatches(byte: u8, unit: u16) ?bool`。
- **作用**：对UTF-16单元计算六类escape谓词。
- **实现**：d用ASCII digit，s用ECMA whitespace或line terminator，w用ASCII word；大写分支取反，其他字节返回null。
- **所有权 / 错误 / 调用**：没有ignoreCase/Unicode flags，不扩展w为Unicode标识符集合；null表示不支持该escape，不是匹配失败false。

### `consumeUnicodePropertyEscape` (`src/core/regexp.zig:234`)

- **签名**：`pub fn consumeUnicodePropertyEscape(pattern: []const u8, index: *usize) bool`。
- **作用**：检查属性表达式并在成功时消费至右花括号后。
- **实现**：检查index+2为左花括号、内容非空且闭合，再调用 unicode.regexp_properties.isSupportedUnicodePropertyExpression；失败返回true且索引不变，成功更新索引并返回false。
- **所有权 / 错误 / 调用**：true是invalid信号。调用者必须已识别反斜杠p/P，本函数不验证前两个字节；只验证支持的属性名字，不计算某个字符是否具有该属性。

## `promise.zig`

core 构造原语：只依赖 `Object`、runtime 根、`function` 的 then/catch 方法创建与安装、`jobs`。零 exec 依赖。VM/`promise_ops` 是客户端。

`PromisePayload`（payloads 分册）才是对象上的 result/reactions/`is_rejected`。本文件写这些槽并入队。

### `construct` (`src/core/promise.zig:18`)

- **签名**：`pub fn construct(realm: *core.RealmContext) !core.JSValue`。
- **作用**：创建原型为空的内部 Promise。
- **实现**：委托 constructWithPrototype(realm,null)。
- **所有权 / 错误 / 调用**：不是执行用户 Promise 构造器或 executor；空原型分支会安装自有 then/catch。

### `constructWithPrototype` (`src/core/promise.zig:22`)

- **签名**：`pub fn constructWithPrototype(realm: *core.RealmContext, prototype: ?*core.Object) !core.JSValue`。
- **作用**：以指定原型创建内部 Promise 对象。
- **实现**：Object.create(promise,prototype)，设错误销毁；prototype 为 null 时分别 defineNativeMethod 安装 then（length2）与 catch（length1），否则不安装，返回对象值。
- **所有权 / 错误 / 调用**：不自动解析 realm Promise.prototype；方法安装失败销毁对象。该函数本体没有显式 rootValues 帧，不能把外层根帧保护泛化为所有构造中间值均已显式 rooted。

### `fulfilledWithPrototype` (`src/core/promise.zig:33`)

- **签名**：`pub fn fulfilledWithPrototype(realm: *core.RealmContext, value: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：创建并直接保存已兑现结果的内部 Promise。
- **实现**：对输入 value 激活根帧；构造后经 promiseObject 取对象，setPromiseResult 写值，返回 promise。
- **所有权 / 错误 / 调用**：不执行 thenable 同化或完整 PromiseResolve；没有入队 reaction。prototype 未列入本地值根帧，相关存活由调用协议保证；分配错误传播。

### `rejectedWithPrototype` (`src/core/promise.zig:46`)

- **签名**：`pub fn rejectedWithPrototype(realm: *core.RealmContext, reason: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：创建并直接保存拒绝原因的内部 Promise。
- **实现**：根住 reason，构造后 setPromiseResult，再将 rejected 标志置 true。
- **所有权 / 错误 / 调用**：不记录未处理拒绝，不排入 reaction；这是新对象初始化，不是通用的已决 Promise 重复 settle 保护。

### `promiseObject` (`src/core/promise.zig:103`)

- **签名**：`fn promiseObject(value: core.JSValue) ?*core.Object`。
- **作用**：从内部值取得 Promise class 对象。
- **实现**：refHeader 为空返回 null，否则直接 Object.fromHeader 再比较 class_id。
- **所有权 / 错误 / 调用**：没有先检查 value.isObject 或 header GC kind，不是任意 JSValue 的完整安全类型判别器；调用方须保证非空 header 可按 Object 解释。

### `rejectedWithUnhandledPrototype` (`src/core/promise.zig:110`)

- **签名**：`pub fn rejectedWithUnhandledPrototype(ctx: *core.JSContext, reason: core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：构造拒绝 Promise 并交 context 记录未处理拒绝。
- **实现**：rejectedWithPrototype 成功后调用 recordUnhandledPromiseRejection(promise,reason)，返回 promise。
- **所有权 / 错误 / 调用**：记录函数为 void，不能从此包装的成功推断跟踪表所有内部分配必成功；构造错误传播。

### `markHandled` (`src/core/promise.zig:121`)

- **签名**：`pub fn markHandled(ctx: *core.JSContext, promise: *core.Object) void`。
- **作用**：从 context 的未处理记录中移除指定的拒绝 Promise。
- **实现**：非 rejected 或无 result 返回；按 promise 身份 removeUnhandledPromiseRejection。若 context 有异常且 current_exception 与 reason SameValue，则 clearException。
- **所有权 / 错误 / 调用**：不改 Promise result/rejected 标志，不入队或执行 handler；记录按 Promise 身份移除，清当前异常则另按 reason 比较，二者判据不同。

### `withResolvers` (`src/core/promise.zig:131`)

- **签名**：`pub fn withResolvers(ctx: *core.JSContext, prototype: ?*core.Object) !core.JSValue`。
- **作用**：创建内部 promise/resolve/reject 组合结果对象。
- **实现**：对四个输出临时值激活根帧；构造 Promise，分别创建 resolve/reject 函数，再创建 null prototype 普通对象，定义三个 w/e/c 全 true 属性。
- **所有权 / 错误 / 调用**：两次 createResolvingFunction 各创建自己的 alreadyResolved state，并非共享同一 state；不能把本 helper 等同完整规范 NewPromiseCapability。失败不返回部分对象，根帧撤销后由 GC 管理未返回中间对象。

### `createResolvingFunction` (`src/core/promise.zig:158`)

- **签名**：`fn createResolvingFunction(ctx: *core.JSContext, promise: core.JSValue, reject: bool) !core.JSValue`。
- **作用**：创建带 promise_resolving tag 的 native data function。
- **实现**：要求 cached_function_proto；根住 promise/function/state，创建空名length1函数和 null prototype state，初始化 alreadyResolved=false，再安装 tag、target、state 和 reject 标志。
- **所有权 / 错误 / 调用**：不验证 target 为 Promise；每次调用单独分配 state，不与另一次调用共享。缺缓存报 InvalidBuiltinRegistry，构造及槽分配错误传播，真正解析/拒绝行为在调用分派层。

### `defineData` (`src/core/promise.zig:243`)

- **签名**：`fn defineData(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void`。
- **作用**：定义可写、可枚举、可配置的数据属性。
- **实现**：以 Descriptor.data(value,true,true,true) 调 defineOwnProperty。
- **所有权 / 错误 / 调用**：可能分配失败或因对象已有属性约束拒绝；本体不单独建立根或复制值。

### `enqueueReaction` (`src/core/promise.zig:247`)

- **签名**：`pub fn enqueueReaction(ctx: *core.JSContext, job: jobs.Func, args: []const core.JSValue) !void`。
- **作用**：委托当前 runtime 队列安排函数 job。
- **实现**：job_queue.enqueueFunc(ctx,job,args)，传播错误。
- **所有权 / 错误 / 调用**：此处不立即调用 job，也不选择或验证 Promise reaction 算法；参数存储及保活由队列实现负责。

Promise 本文件没有另定义 Promise 状态结构；上述函数使用 Object 的 PromisePayload。fulfilled/rejected 是直接初始化结果槽的内部辅助，withResolvers 也不是独立完整的规范抽象操作；构造器选择、thenable 同化与后续 reaction 语义须结合 exec 调用路径阅读。

## `var_ref.zig` 类型

`VarRef`：内部 GC 节点，编译期断言40B、对齐8、header@0；gc_kind_tag 为 var_ref，value 紧接 header，pvalue 位于 header大小+16。`value`：关闭时绑定值；打开时可选的 parked-frame owner。`pvalue`：活动槽别名或 `&value`。flags：`is_const` / `is_lexical`（全局词法 TDZ）/ `is_function_name` / `is_deletable` / `is_open`。

### `VarRef.createClosed` (`src/core/var_ref.zig:47`)

- **签名**：`pub fn createClosed(rt: anytype, initial_value: JSValue) !*VarRef`。
- **作用**：创建保存独立绑定值的关闭 cell。
- **实现**：createRuntime 后初始化 value/header，pvalue 指向内部 value，断言 metadata kind，addInitializedWithSize 登记。
- **所有权 / 错误 / 调用**：所有标志默认 false；失败 destroyRuntime。没有输入值根帧，不做 const/TDZ 或输入非VarRef校验，调用方保证输入在分配窗口存活。

### `VarRef.createOpen` (`src/core/var_ref.zig:60`)

- **签名**：`pub fn createOpen(rt: anytype, slot: *JSValue) !*VarRef`。
- **作用**：创建别名外部绑定槽的 open cell。
- **实现**：分配后 value=undefined、pvalue=slot、is_open=true，检查 metadata kind 并登记。
- **所有权 / 错误 / 调用**：slot 必须在 open 期间有效；此处不登记帧拥有者，也不复制 slot 内容，失败释放 cell 分配。

### `VarRef.destroyFromHeader` (`src/core/var_ref.zig:78`)

- **签名**：`pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void`。
- **作用**：通过 header 释放 cell。
- **实现**：直接调用 freeStruct。
- **所有权 / 错误 / 调用**：不 close、不清值，不实现多阶段调度；对象/字节码不再使用 cell 的顺序由 collector/teardown 保证。

### `VarRef.freeStruct` (`src/core/var_ref.zig:83`)

- **签名**：`pub fn freeStruct(rt: anytype, header: *gc.Header) void`。
- **作用**：归还 VarRef 结构分配。
- **实现**：fieldParentPtr 从 header 找到 cell，rt.destroyRuntime。
- **所有权 / 错误 / 调用**：不检查 GC kind、open 状态或引用者，也不逐值释放；只接受合法可释放 cell header。

### `VarRef.prepareForRuntimeDeinit` (`src/core/var_ref.zig:91`)

- **签名**：`pub fn prepareForRuntimeDeinit(_: anytype, header: *gc.Header) void`。
- **作用**：断开 cell 的值边和外部槽别名，保留结构。
- **实现**：value=undefined，pvalue=&value，is_open=false。
- **所有权 / 错误 / 调用**：不复制原绑定、不释放结构，不清 const/lexical/function_name/deletable 标志；runtime 参数未使用。

### `VarRef.valueRef` (`src/core/var_ref.zig:98`)

- **签名**：`pub fn valueRef(self: *VarRef) JSValue`。
- **作用**：用 JSValue 表示内部 VarRef 节点。
- **实现**：返回 JSValue.object(&header)。
- **所有权 / 错误 / 调用**：表示采用 object tag 但节点不是 JS Object；识别须读 GC kind，不新增根或引用计数。

### `VarRef.fromValue` (`src/core/var_ref.zig:102`)

- **签名**：`pub fn fromValue(value: JSValue) ?*VarRef`。
- **作用**：按 header kind 识别 VarRef 节点。
- **实现**：无 refHeader 返回 null；kind 非 var_ref 返回 null，否则 fieldParentPtr。
- **所有权 / 错误 / 调用**：不读取或解包 cell 的绑定值；有效 header 的存活是调用前提。

### `VarRef.attachOpenOwner` (`src/core/var_ref.zig:115`)

- **签名**：`pub fn attachOpenOwner(self: *VarRef, rt: anytype, owner: JSValue) void`。
- **作用**：为 open cell 安装挂起帧的拥有者强边。
- **实现**：断言 open 且 owner 是 Object；value 已非undefined时断言与 owner 同值并返回，否则保存 owner 并 generationalBarrier。
- **所有权 / 错误 / 调用**：不执行 RC retain、不修改 pvalue；不验证 Object 是 generator。调用方须在帧挂起前安装正确拥有者。

### `VarRef.close` (`src/core/var_ref.zig:128`)

- **签名**：`pub fn close(self: *VarRef, rt: anytype) void`。
- **作用**：把 open cell 转成内部保存值的 closed cell。
- **实现**：已关闭直接返回；复制 *pvalue 到 value，做世代屏障，再令 pvalue=&value、is_open=false。
- **所有权 / 错误 / 调用**：不分配或释放 cell，替换原 parked owner 边；绑定槽必须仍有效，const 等标志不变。

### `VarRef.setVarRefValue` (`src/core/var_ref.zig:141`)

- **签名**：`pub fn setVarRefValue(self: *VarRef, rt: anytype, next_value: JSValue) void`。
- **作用**：写入当前绑定槽并记录世代屏障。
- **实现**：Debug 断言输入不是 VarRef 表示；写 *pvalue，再以本 cell 为 owner 对新值做 barrier。
- **所有权 / 错误 / 调用**：不解包嵌套cell、不检查 const/TDZ/deletable；ReleaseSafe 也不包含这个 Debug 专属检查。pvalue 可别名 frame 或其他内部槽，外围负责语义验证。

### `VarRef.varRefValueSlot` (`src/core/var_ref.zig:162`)

- **签名**：`pub fn varRefValueSlot(self: *VarRef) *JSValue`。
- **作用**：借用当前绑定值槽地址。
- **实现**：返回 pvalue。
- **所有权 / 错误 / 调用**：可能指向外部 frame；直接写该地址不自动执行 setter 的屏障或校验，调用方负责。

### `VarRef.varRefValue` (`src/core/var_ref.zig:166`)

- **签名**：`pub fn varRefValue(self: *const VarRef) JSValue`。
- **作用**：读取当前绑定值。
- **实现**：返回 *pvalue。
- **所有权 / 错误 / 调用**：不做 TDZ 检查、解包或独立保活；值为 uninitialized 时原样返回。

### `VarRef.varRefIsConstSlot` (`src/core/var_ref.zig:170`)

- **签名**：`pub fn varRefIsConstSlot(self: *VarRef) *bool`。
- **作用**：借用 is_const 标志槽。
- **实现**：返回字段地址。
- **所有权 / 错误 / 调用**：不检查或执行绑定语义、不分配；调用者直接修改标志，cell 存活由外围保证。

### `VarRef.varRefIsFunctionNameSlot` (`src/core/var_ref.zig:174`)

- **签名**：`pub fn varRefIsFunctionNameSlot(self: *VarRef) *bool`。
- **作用**：借用 is_function_name 标志槽。
- **实现**：返回字段地址。
- **所有权 / 错误 / 调用**：不检查或执行绑定语义、不分配；调用者直接修改标志，cell 存活由外围保证。

### `VarRef.varRefIsDeletableSlot` (`src/core/var_ref.zig:178`)

- **签名**：`pub fn varRefIsDeletableSlot(self: *VarRef) *bool`。
- **作用**：借用 is_deletable 标志槽。
- **实现**：返回字段地址。
- **所有权 / 错误 / 调用**：不检查或执行绑定语义、不分配；调用者直接修改标志，cell 存活由外围保证。

## `generator_state.zig` 类型

`AsyncGeneratorRequest`：completion_type（next=0/return=1/throw=2）+ result + promise capability。对齐 `JSAsyncGeneratorRequest`。

`GeneratorSuspendKind`：none/yield/yield_star/await_op。

`SuspendedStackStorage`：停放的操作数栈；`values` 活前缀，`capacity` 后备。

`SuspendedFrameStorage`：帧 slab 与 locals/args/var_refs/open_var_refs 窗口。非空 `storage` 时其它切片是内部窗口。

`SuspendedExecutionStorage`：stack+frame。pc 故意在上一层（resume 把缓冲交给 live exec，finally 仍读 payload pc；对齐 qjs `cur_pc` 而 `cur_sp==NULL`）。

`SuspendedExecutionState`：pc、storage、`catch_target_pc`（`maxInt(u32)`=无）、`has_frame`（对齐 `func_state!=NULL`）、`running_aliases`、`resident_storage_owner`。

`GeneratorExecutionState`：挂起状态、this/current_function/yield_star 三个非 optional 值、actual_arg_count:u16、combined_stack_slots:u16、combined_frame_metadata:u32；后者高位为 completion-pending，低31位为帧槽数。尺寸由实际类型与构建布局决定。尾部起点按 JSValue 对齐，整体分配对齐取记录与 JSValue 对齐的较大者。

`GeneratorPayload`：execution 指针、async_promise、普通分配的请求队列/容量、resume_completion_type、async_state/suspend_kind 及 done/executing/started/just_yielded/yield_star_suspended 五个布尔状态。完成清理可能因运行别名而延迟，不能仅凭 done 推断 execution 已为空。GeneratorSuspendKind 是 enum(u8)，none/yield/yield_star/await_op 分别为0/1/2/3；payload 存的是 u8。empty_suspended_execution_state 为默认状态常量，catch_target_pc 默认 maxInt(u32)。

### `SuspendedStackStorage.ensureAdditionalWithResidentBacking` (`src/core/generator_state.zig:52`)

- **签名**：`pub fn ensureAdditionalWithResidentBacking(self: *SuspendedStackStorage, rt: *JSRuntime, limit: usize, additional: usize, resident_backing: bool) !void`。
- **作用**：确保挂起栈能容纳额外元素。
- **实现**：先检查当前 len 和 additional 不超过 limit；needed<=capacity 即返回。零容量从 min(8,limit) 开始，否则从现容量倍增，接近 limit 时取 limit。分配新 JSValue 数组、复制有效前缀、安装新 slice/容量；旧容量非零且非 resident 时按容量释放，旧容量为零但 len 非零时按旧 slice 释放。
- **所有权 / 错误 / 调用**：分配失败不改字段；不延长有效 len、不初始化新增容量。resident_backing 由调用方正确传入，不能把内嵌窗口误作普通分配释放；即使容量足够也先执行 limit 检查。无自动 root/owner 屏障。

### `SuspendedStackStorage.deinit` (`src/core/generator_state.zig:80`)

- **签名**：`pub fn deinit(self: *SuspendedStackStorage, rt: *JSRuntime) void`。
- **作用**：摘除并释放普通拥有的栈 backing。
- **实现**：调用 destroyValueSliceWithCapacity，将 slice/capacity 清零并按旧容量或长度释放。
- **所有权 / 错误 / 调用**：不适用于直接释放 execution record 内嵌 FAM 窗口；不逐值销毁，resident backing 须由上层特殊清理路径处理。

### `SuspendedStackStorage.isEmpty` (`src/core/generator_state.zig:84`)

- **签名**：`pub fn isEmpty(self: *const SuspendedStackStorage) bool`。
- **作用**：判断栈是否既无有效值也无拥有容量。
- **实现**：values.len==0 且 capacity==0。
- **所有权 / 错误 / 调用**：已保留容量的零长度栈不是 empty；不检查指针地址。

### `SuspendedFrameStorage.deinit` (`src/core/generator_state.zig:102`)

- **签名**：`pub fn deinit(self: *SuspendedFrameStorage, rt: *JSRuntime) void`。
- **作用**：关闭 open cells 并释放普通拥有的 frame backing。
- **实现**：先保存字段并把 self 清空，再对旧 open_var_refs 逐槽置 null 并 close。storage 非空时只摘 locals/args/var_refs 的局部视图并释放整 slab；否则分别释放 locals/args，var_refs 仅摘除。
- **所有权 / 错误 / 调用**：close 在 locals/args backing 释放前复制仍存活的绑定值；不释放 VarRef cell。var_refs/open_var_refs 窗口自身不能作为独立拥有分配，本方法不 free 它们；也不适用于手还 resident FAM。

### `SuspendedFrameStorage.deinitResident` (`src/core/generator_state.zig:125`)

- **签名**：`pub fn deinitResident(self: *SuspendedFrameStorage, rt: *JSRuntime) void`。
- **作用**：清 resident frame 的窗口并关闭 open cells。
- **实现**：保存旧字段、self 清空，关闭旧 open_var_refs，再仅摘 locals/args/var_refs 局部视图。
- **所有权 / 错误 / 调用**：不释放任何 backing，字节由外围 GeneratorExecutionState 分配拥有；close 的值复制与屏障仍会执行。

### `SuspendedFrameStorage.isEmpty` (`src/core/generator_state.zig:137`)

- **签名**：`pub fn isEmpty(self: *const SuspendedFrameStorage) bool`。
- **作用**：判断五个 frame slice 的有效长度是否全零。
- **实现**：检查 storage、locals、args、var_refs、open_var_refs 的 len。
- **所有权 / 错误 / 调用**：不检查指针是否哨兵，不表达 has_frame；所有窗口零长度的驻留帧仍可存在。

### `SuspendedExecutionStorage.swapOwned` (`src/core/generator_state.zig:155`)

- **签名**：`fn swapOwned(self: *SuspendedExecutionStorage, other: *SuspendedExecutionStorage) void`。
- **作用**：逐字段交换两个 storage 的拥有描述。
- **实现**：交换 stack 的 values/capacity 和 frame 的五个 slice。
- **所有权 / 错误 / 调用**：不复制 backing 内容、不分配、不释放；不触碰外围 pc 或运行标志。

### `SuspendedExecutionStorage.deinit` (`src/core/generator_state.zig:185`)

- **签名**：`pub fn deinit(self: *SuspendedExecutionStorage, rt: *JSRuntime) void`。
- **作用**：销毁普通拥有的挂起 stack/frame 存储。
- **实现**：isEmpty 时直接返回；否则保存旧值、self 清空，再 stack.deinit、frame.deinit。
- **所有权 / 错误 / 调用**：frame 的 open cells 在 frame backing 释放前关闭，但 stack 清理先发生；resident/运行中借用状态须由上层判别，不能无条件调用此普通释放路径。

### `SuspendedExecutionStorage.moveInto` (`src/core/generator_state.zig:200`)

- **签名**：`pub fn moveInto(self: *SuspendedExecutionStorage, destination: *SuspendedExecutionStorage) void`。
- **作用**：把 storage 移到空目标。
- **实现**：断言不是自身且目标 isEmpty，然后 swapOwned。
- **所有权 / 错误 / 调用**：交换后源取得目标原空字段；不分配或释放，未清非空目标是调用违约。

### `SuspendedExecutionStorage.isEmpty` (`src/core/generator_state.zig:206`)

- **签名**：`pub fn isEmpty(self: *const SuspendedExecutionStorage) bool`。
- **作用**：判断 stack 与 frame 都为空。
- **实现**：组合两者 isEmpty。
- **所有权 / 错误 / 调用**：不能据此判断 execution state 是否存在驻留 frame，也不检查 pc。

### `SuspendedExecutionState.deinit` (`src/core/generator_state.zig:235`)

- **签名**：`pub fn deinit(self: *SuspendedExecutionState, rt: *JSRuntime) void`。
- **作用**：清挂起执行状态及其普通存储拥有权。
- **实现**：running_aliases 时断言不是 resident_storage_owner，摘 storage 并清运行标志，不销毁 live owner；否则 storage.deinit。随后 pc=0、catch target=哨兵、has_frame/resident_storage_owner=false。
- **所有权 / 错误 / 调用**：运行别名分支依赖 live Frame/Stack 清理；resident running 状态不能经此入口释放，须使用 GeneratorExecutionState 的相应路径。

### `SuspendedExecutionState.beginRunningAliases` (`src/core/generator_state.zig:254`)

- **签名**：`pub fn beginRunningAliases(self: *SuspendedExecutionState) void`。
- **作用**：标记存储已安装为运行中的 Frame/Stack 视图。
- **实现**：断言此前不 running_aliases，再置 true。
- **所有权 / 错误 / 调用**：不移动字段、保活对象或注册根；调用合同要求安装视图到此标记之间无 GC 点。

### `SuspendedExecutionState.finishRunningAliases` (`src/core/generator_state.zig:261`)

- **签名**：`pub fn finishRunningAliases(self: *SuspendedExecutionState) void`。
- **作用**：结束运行别名状态。
- **实现**：非 running 时无操作；否则清 running_aliases/has_frame、重置 catch target。resident_storage_owner 为 true 则保留 storage，否则摘 storage。
- **所有权 / 错误 / 调用**：不释放 backing、不清 pc，也不清 resident_storage_owner；resident 分支继续由记录拥有 backing，普通分支由 live Frame/Stack 负责。

### `SuspendedExecutionState.catchTarget` (`src/core/generator_state.zig:270`)

- **签名**：`pub fn catchTarget(self: *const SuspendedExecutionState) ?usize`。
- **作用**：解码挂起 catch 目标。
- **实现**：no_suspended_catch_target（maxInt(u32)）返回 null，其余提升为 usize。
- **所有权 / 错误 / 调用**：不根据 pc 或 has_frame 推导/校验目标；maxInt(u32) 不能用作普通目标值。

### `SuspendedExecutionState.replaceStorageOwned` (`src/core/generator_state.zig:277`)

- **签名**：`pub fn replaceStorageOwned(self: *SuspendedExecutionState, pc: usize, catch_target_pc: u32, replacement: *SuspendedExecutionStorage, rt: *JSRuntime) void`。
- **作用**：发布新的挂起存储、pc 和 catch 状态。
- **实现**：断言 replacement 不是内部 storage。running_aliases 时直接取 replacement、清输入并更新 pc/catch/has_frame，清 running/resident 标志，不检查旧别名。其他情况交换 storage 后发布 pc/catch/has_frame、清 resident 标志，再销毁 replacement 中换出的旧存储（非空时）。
- **所有权 / 错误 / 调用**：先发布再清旧存储，供清理时观察新权威状态；输入最终为空。旧运行别名可能因增长而过时，不能当拥有者重复释放；函数自身无 error 返回或显式根/屏障。

### `GeneratorExecutionState.combinedFrameSlotCount` (`src/core/generator_state.zig:338`)

- **签名**：`fn combinedFrameSlotCount(self: *const GeneratorExecutionState) usize`。
- **作用**：读取内嵌帧槽数。
- **实现**：combined_frame_metadata & 0x7fffffff，提升为 usize。
- **所有权 / 错误 / 调用**：排除 completion pending 高位；不是实参数量，可能包括局部变量、引用槽和快照。

### `GeneratorExecutionState.completionPending` (`src/core/generator_state.zig:342`)

- **签名**：`pub fn completionPending(self: *const GeneratorExecutionState) bool`。
- **作用**：检查延迟完成标记。
- **实现**：测试 combined_frame_metadata 的 bit31。
- **所有权 / 错误 / 调用**：不代表已销毁或 done；是等待运行别名退出后再清理的状态信息。

### `GeneratorExecutionState.setCompletionPending` (`src/core/generator_state.zig:346`)

- **签名**：`pub fn setCompletionPending(self: *GeneratorExecutionState, pending: bool) void`。
- **作用**：设置或清除延迟完成标记。
- **实现**：true 按位 OR bit31，false AND 低31位掩码。
- **所有权 / 错误 / 调用**：保留 frame 槽数，不改变 execution 指针、running 标志或执行实际清理。

### `GeneratorExecutionState.combinedStackStorage` (`src/core/generator_state.zig:354`)

- **签名**：`fn combinedStackStorage(self: *GeneratorExecutionState) []JSValue`。
- **作用**：借用记录尾随的整个内嵌栈区域。
- **实现**：槽数为零返回空，否则从 self+generator_execution_storage_offset 解释为 JSValue slice。
- **所有权 / 错误 / 调用**：长度是分配槽数而非有效栈长度；不分配、不初始化或验证字节，记录必须有对应尾部。

### `GeneratorExecutionState.combinedFrameStorage` (`src/core/generator_state.zig:361`)

- **签名**：`pub fn combinedFrameStorage(self: *GeneratorExecutionState) []JSValue`。
- **作用**：借用内嵌栈区域之后的整个帧区域。
- **实现**：帧槽数为零返回空，否则从 storage_offset 加 stack_slots*sizeof(JSValue) 处构造 slice。
- **所有权 / 错误 / 调用**：屏蔽 completion 位后计算长度；不是仅 locals 窗口，也不负责初始化各类型窗口。

### `GeneratorExecutionState.allocationSize` (`src/core/generator_state.zig:373`)

- **签名**：`pub fn allocationSize(self: *const GeneratorExecutionState) usize`。
- **作用**：计算执行记录及其原始尾部区域的字节数。
- **实现**：原始栈/帧槽总数为零返回 sizeof(GeneratorExecutionState)，否则 storage_offset+总槽数*sizeof(JSValue)。
- **所有权 / 错误 / 调用**：不计后来迁出的独立栈/帧分配，不能硬写每值16字节或固定160字节；不读 allocator 的 size class。

### `GeneratorExecutionState.stackUsesCombinedStorage` (`src/core/generator_state.zig:379`)

- **签名**：`pub fn stackUsesCombinedStorage(self: *GeneratorExecutionState) bool`。
- **作用**：判断当前挂起栈是否仍使用原内嵌区域。
- **实现**：原栈区域非空，当前 stack.capacity 非零且 values.ptr 等于内嵌起点才为 true。
- **所有权 / 错误 / 调用**：不要求当前容量恰等于原槽数，也不验证有效长度；普通扩容迁出后为 false。

### `GeneratorExecutionState.frameUsesCombinedStorage` (`src/core/generator_state.zig:386`)

- **签名**：`pub fn frameUsesCombinedStorage(self: *GeneratorExecutionState) bool`。
- **作用**：判断当前 frame.storage 是否仍指向内嵌帧区域。
- **实现**：原帧区域非空、当前 storage.len 非零且起点相等才为 true。
- **所有权 / 错误 / 调用**：不核对长度或 locals/args 等窗口是否一致，也不根据 has_frame 判定。

### `GeneratorExecutionState.canRetainResidentStorageOwnership` (`src/core/generator_state.zig:393`)

- **签名**：`pub fn canRetainResidentStorageOwnership(self: *GeneratorExecutionState) bool`。
- **作用**：判断记录能否在运行时继续拥有内嵌存储。
- **实现**：要求 stackUsesCombinedStorage；帧槽数为零可直接通过，否则还要求 frameUsesCombinedStorage。
- **所有权 / 错误 / 调用**：只返回布局判据，不写 resident_storage_owner，也不验证执行状态；零栈槽记录不能通过。

### `GeneratorExecutionState.destroy` (`src/core/generator_state.zig:398`)

- **签名**：`pub fn destroy(self: *GeneratorExecutionState, rt: *JSRuntime) void`。
- **作用**：清执行记录内容，区别内嵌与普通拥有的存储。
- **实现**：非 running 时，内嵌 stack 仅摘除、内嵌 frame 用 deinitResident；随后 suspended.deinit 清普通 backing 或运行别名。再清 current_function/this/yield_star 值并整体默认初始化。
- **所有权 / 错误 / 调用**：不归还记录自身及其尾部，外围 free helper 负责。running 且 resident_storage_owner 为 true 不满足 suspended.deinit 的合同，应先完成延迟清理握手。无用户回调执行或逐值 RC release。

### `createGeneratorExecutionStateWithStorage` (`src/core/generator_state.zig:425`)

- **签名**：`pub fn createGeneratorExecutionStateWithStorage(rt: *JSRuntime, stack_slots: usize, frame_slots: usize) !*GeneratorExecutionState`。
- **作用**：分配并安装记录加可选栈/帧尾部。
- **实现**：栈槽转u16失败或帧槽超过低31位上限报 StackOverflow；checked add/mul 计算字节，allocRuntimeAlignedBytes 后默认初始化记录。栈安装空有效前缀及完整容量，frame.storage 安装整个内嵌帧区。
- **所有权 / 错误 / 调用**：本函数即使两槽数均为零仍调用对齐分配，不另走 memory.create。尾部内容未初始化，locals/args/引用窗口也未安装；算术溢出和分配错误传播，成功分配后没有其他 fallible 操作。

### `freeGeneratorExecutionState` (`src/core/generator_state.zig:447`)

- **签名**：`fn freeGeneratorExecutionState(rt: *JSRuntime, execution: *GeneratorExecutionState) void`。
- **作用**：销毁记录内容并归还原分配。
- **实现**：先保存栈/帧槽数，再 execution.destroy；两者均零则 memory.destroy，否则按原槽数重算字节并 freeAlignedBytes。
- **所有权 / 错误 / 调用**：必须在 destroy 清字段之前保存尺寸；本函数不检查 completionPending，公开包装层检查。独立增长 backing 由 destroy 先清理。

### `destroyGeneratorExecutionState` (`src/core/generator_state.zig:462`)

- **签名**：`pub fn destroyGeneratorExecutionState(rt: *JSRuntime, slot: *?*GeneratorExecutionState) void`。
- **作用**：先摘除可空执行记录指针再销毁。
- **实现**：空槽返回；先写 slot=null，断言 !completionPending，再 freeGeneratorExecutionState。
- **所有权 / 错误 / 调用**：摘除后重入观察不到半清理记录；不会替调用者清 pending 或等候运行别名结束，调用方须满足清理前提。

### `GeneratorPayload.destroy` (`src/core/generator_state.zig:490`)

- **签名**：`pub fn destroy(self: *GeneratorPayload, rt: *JSRuntime) void`。
- **作用**：清执行记录、async promise 和请求队列。
- **实现**：销毁 execution，清 async_promise；queue.capacity 非零时按容量 free；最后清队列字段并整体默认初始化。
- **所有权 / 错误 / 调用**：无 capacity==0 时按 len 释放的回退，依赖队列容量合同；不逐项执行 resolve/reject，也不运行 generator return/finally。done 等标志恢复默认 false，而非设置为完成态。

### `GeneratorPayload.traceChildEdges` (`src/core/generator_state.zig:501`)

- **签名**：`pub fn traceChildEdges(self: *GeneratorPayload, visitor: anytype) !void`。
- **作用**：枚举生成器保存的 JS 值边。
- **实现**：有 execution 时先 this；仅非 running_aliases 时访问栈、locals、args、var_refs/open_var_refs，后两者将 cell.valueRef 转局部 JSValue 再访问。随后访问 current_function/yield_star，再 async_promise、每个请求的 result/promise/resolve/reject。
- **所有权 / 错误 / 调用**：真实值槽可被 visitor 回写，但 VarRef 临时值修改不会回写指针数组。不报告普通执行记录或请求数组为 storageCell；running 窗口须由 exec 根提供者覆盖。completion_type 和状态标量不作为边，错误立即中止。

## 覆盖核对

- 清单函数数: 63（`src/core/generator_state.zig` 30 + `src/core/promise.zig` 11 + `src/core/regexp.zig` 7 + `src/core/var_ref.zig` 15）
- 本文标题覆盖: 63
- 未覆盖: 无
