# 06 — errors / exception / descriptor

本分册覆盖 `src/core/errors.zig`（零函数，error set 权威）、`error_names.zig`、`exception.zig`、`descriptor.zig`。

## `src/core/errors.zig`：error set 权威

文件定义core/exec共享的错误运输集合，`exec.exceptions`重导出，`HostError`直接别名到`RuntimeError`。这不是所有子系统私有错误的全集：例如字节码校验器还有自己的`ReachableFalloff`。错误集声明本身不会构造JS异常、附加消息或转换I/O错误；这些由具体边界处理（如exception_ops的宿主I/O转换）。

### `RuntimeError`

`pub const RuntimeError = error{ ... }`（`src/core/errors.zig:9-86`）。成员按源码顺序列出。下表说明内部用途，不能把Zig错误名直接当成最终JS异常类；“仅见声明”指当前项目src中的显式使用检索，不排除标准库错误传播：

| 名字 | 含义 |
| --- | --- |
| `AccessorWithoutSetter` | 访问器没有 setter，却走了赋值。 |
| `AmbiguousExport` | 模块导出名冲突。 |
| `AwaitOutsideAsyncFunction` | 解析器在不允许await的语法上下文拒绝await；不能简单等同于所有非async位置，模块顶层有独立许可。 |
| `BigIntTooLarge` | BigInt limb容量超过实现上限，包括堆对象与底层大整数分配。 |
| `BytecodeCorrupt` | 正则执行器的字节码、捕获槽或运行数据尺寸不满足约束；不是专指JS函数字节码。 |
| `BytecodeOverflow` | 字节码布局、跳转解析或缓冲区尺寸/偏移超出内部表示范围。 |
| `ClosureVarNotFound` | 闭包变量槽找不到。 |
| `CodepointTooLarge` | 保留的Unicode码点过大错误名；当前项目src仅见共享集合声明，不能据此指定活动抛错点。 |
| `DivisionByZero` | 整数/BigInt 除零。 |
| `DuplicateClass` | class 定义重复。 |
| `DualCompileMismatch` | 保留的双编译不一致错误名；当前src检索仅见此声明，不能据名字推断仍有script/module双编译流程。 |
| `DerivedConstructorReturn` | 派生构造器返回既不是对象也不是undefined的值；undefined另检查this初始化状态。 |
| `DerivedThisUninitialized` | 访问或隐式返回派生构造器this时仍为uninitialized，例如尚未成功调用super。 |
| `EvalError` | 规范 `EvalError`。 |
| `IncompatibleDescriptor` | 属性描述符与现有属性不兼容（`[[DefineOwnProperty]]`）。 |
| `Interrupted` | 运行被中断。 |
| `InvalidAssignmentTarget` | 赋值左值非法。 |
| `InvalidAtom` | atom id 不是活条目（符号体/名字查找）。 |
| `InvalidBytecode` | 字节码 opcode/操作数非法。 |
| `InvalidBuiltinRegistry` | 内建/realm状态不满足调用条件，例如realm未完成构造、正在finalizing或缓存缺失；不一定是内存损坏。 |
| `InvalidCharacter` | 底层字符/数值解析失败或字符范围不符，例如 `std.fmt.parseFloat` 拒收或词法数字非法；并非仅转义。 |
| `InvalidCharacterError` | 宿主编码路径使用的DOMException名称及对应运输错误，区别于内部InvalidCharacter。 |
| `InvalidClassId` | class id 越界或未安装。 |
| `InvalidEscape` | 字符串/模板转义非法。 |
| `InvalidIdentifier` | 标识符非法。 |
| `InvalidLength` | 数组length赋值/定义等内部长度转换失败；具体条件由产生点决定。 |
| `InvalidLhs` | 保留的左值错误名；当前共享集合和Parser.Error有声明，未见项目src显式返回点。 |
| `InvalidNumber` | lexer数字字面量扫描失败，例如基数前缀后缺少有效数字。 |
| `InvalidNumberLiteral` | 解析器处理BigInt字面量时将parseAutoAlloc失败折叠成此错误。 |
| `InvalidOpcode` | 未知 opcode。 |
| `InvalidPattern` | 正则模式非法。 |
| `InvalidPrivateName` | private name 解析失败。 |
| `InvalidRadix` | 数值格式化或BigInt基数转换的非法radix；不能仅归因为parseInt。 |
| `InvalidRegExp` | 解析器编译正则字面量失败的归一错误；OOM/StackOverflow等分支另行保留。 |
| `InvalidUnicodeEscape` | `\u` 转义非法。 |
| `InvalidUtf8` | UTF-8解码/字符串转换失败；部分UTF-8到Latin1路径也用它拒绝大于0xff的有效码点。 |
| `LegacyOctalInStrictMode` | 严格模式或模板转义中拒绝遗留八进制等相关转义；不局限于严格模式。 |
| `MissingExport` | 模块缺导出。 |
| `ModuleLinkFailed` | 模块链接失败。 |
| `ModuleNotFound` | 模块解析不到。 |
| `NegativeExponent` | BigInt 负指数。 |
| `NotExtensible` | 对象不可扩展。 |
| `NotRegExpLiteral` | 保留的“不是正则字面量”错误名；当前项目src仅见共享集合声明。 |
| `OutOfMemory` | 分配/预算失败，也可作为某些容量乘法溢出的归一结果；不必然表示主机物理内存耗尽。 |
| `Overflow` | 整数/长度溢出。 |
| `ParserInvariant` | 解析器内部不变量被打破。 |
| `Pc2LineOverflow` | pc→行号表溢出。 |
| `Pc2LineTruncated` | pc→行号表被截断。 |
| `ProcessExit` | 进程退出请求（CLI/`std`）。 |
| `PrototypeCycle` | 原型链成环。 |
| `RangeError` | 规范 `RangeError`。 |
| `ReadOnly` | 只读属性/缓冲区写入。 |
| `ReferenceError` | 规范 `ReferenceError`。 |
| `StackMismatch` | 字节码控制流汇合时的栈深度或catch位置不一致等内部栈约束失败。 |
| `StackOverflow` | 调用递归、正则栈或生成器存储栈超过对应限制，不仅是VM调用栈。 |
| `StackUnderflow` | 操作数栈下溢。 |
| `StringTooLong` | 字符串码元超过 `(1<<30)-1`。 |
| `SyntaxError` | 规范 `SyntaxError`。 |
| `SystemError` | 保留的系统错误运输名；当前项目src仅见共享集合声明，宿主I/O另有转换边界。 |
| `JSException` | 运输已挂起的JS异常的内部标记；声明本身不保证当前异常槽非空，边界须遵守协议。 |
| `Timeout` | 执行超时信号，例如正则timeout回调返回true。 |
| `TooManyJobArgs` | job参数数量超过core.jobs.MaxArgs（当前为5）。 |
| `TypeError` | 规范 `TypeError`。 |
| `URIError` | 规范 `URIError`。 |
| `UnhandledPromiseRejection` | 未处理的 Promise 拒绝。 |
| `UnterminatedComment` | 注释未闭合。 |
| `UnterminatedRegExp` | 正则字面量未闭合。 |
| `UnterminatedString` | 字符串未闭合。 |
| `UnterminatedTemplate` | 模板未闭合。 |
| `UnexpectedEof` | 词法错误集和共享集合保留的提前EOF名称；当前项目src未见显式返回点。 |
| `UnexpectedToken` | 意外 token。 |
| `UnsupportedSimpleJson` | 简易 JSON 路径遇到不支持的形状。 |
| `Utf8CannotEncodeSurrogateHalf` | 标准库风格的UTF-8编码错误名，表示拒绝单独代理码元；当前项目src仅见共享集合声明。 |
| `Utf8EncodesSurrogateHalf` | UTF-8解码错误名，表示输入编码了代理码元；parser有显式捕获分支。 |
| `YieldOutsideGenerator` | 解析器拒绝当前上下文中的yield用法，亦涵盖严格模式下不能当标识符的情况。 |
| `HtmlCommentInModule` | lexer错误集和共享集合保留的模块HTML注释名称；当前项目src未见显式返回点。 |

这些成员不会统一映射成同名JavaScript对象。当前 `exception_ops.runtimeErrorInfo` 例如把 OutOfMemory/StackOverflow/Interrupted/StringTooLong 映射为 InternalError，把 BigIntTooLarge/DivisionByZero/NegativeExponent 映射为 RangeError，把 DerivedConstructorReturn 映射为 TypeError；未列成员返回 null。Promise侧还有独立的 `promiseErrorInfo`，其未列成员默认 Error。已附着的异常值及具体调用边界仍可能决定最终结果，不能只靠此错误表预测用户观察到的异常。

新的用户可见抛错应走 `throw*Message` helper；裸 `return error.Xxx` 只留给消息已在别处挂上、或用户代码到不了的路径（`AGENTS.md`）。

### `HostError`

`pub const HostError = RuntimeError`（`src/core/errors.zig:88`）。同一集合，历史运输名。

## `src/core/error_names.zig`

纯 `[]const u8` 谓词，只 import `std`。对照 QuickJS 原生 error class 分类：`Error`、`AggregateError`、简单 `*Error` 子类、再加上 `SuppressedError` 分组。构造器 / `OP_throw_error` 路径咨询这些名字。

### `isErrorConstructorName` (`src/core/error_names.zig:12`)

- **签名**：`pub fn isErrorConstructorName(name: []const u8) bool`。
- **作用**：按名字识别本模块的Error构造器组。
- **实现**：Error或isNativeErrorSubclassName为true，包含AggregateError、SuppressedError及七个简单名字。
- **所有权 / 错误 / 调用**：逐字节区分大小写，无分配；只认固定名称，不查询全局对象、原型继承或可构造性，DOMException不在此组。

### `isConstructErrorObjectName` (`src/core/error_names.zig:16`)

- **签名**：`pub fn isConstructErrorObjectName(name: []const u8) bool`。
- **作用**：识别共用普通Error对象构造路径的名字组。
- **实现**：Error、AggregateError或七个简单名字为true；SuppressedError为false。
- **所有权 / 错误 / 调用**：分组与isErrorConstructorName不同，不代表SuppressedError不是错误类型或不可构造；仅是名称路由。

### `isNativeErrorSubclassName` (`src/core/error_names.zig:22`)

- **签名**：`pub fn isNativeErrorSubclassName(name: []const u8) bool`。
- **作用**：识别除Error基名以外的内部错误构造名字组。
- **实现**：AggregateError、SuppressedError或isSimpleNativeErrorConstructorName为true。
- **所有权 / 错误 / 调用**：不做实际子类关系检查；名称NativeError是本引擎分组，不应把InternalError也说成ECMAScript标准子类。

### `isSimpleNativeErrorConstructorName` (`src/core/error_names.zig:28`)

- **签名**：`pub fn isSimpleNativeErrorConstructorName(name: []const u8) bool`。
- **作用**：识别七个简单错误构造名字。
- **实现**：精确比较EvalError、RangeError、ReferenceError、SyntaxError、TypeError、URIError、InternalError；其他false。
- **所有权 / 错误 / 调用**：不含Error、AggregateError、SuppressedError或DOMException；静态谓词，无分配。

## `src/core/exception.zig`

`ExceptionSlot` 是独立的JSValue槽助手，通过core.root导出；当前非测试源码的JSContext异常入口并不使用此结构，而是直接操作 `runtime.current_exception` 及uncatchable/out_of_memory标志。它没有realm或runtime字段，也没有自动GC注册。uninitialized表示空；其他值的保活由实际拥有者负责。

类型：`ExceptionSlot { value: JSValue = JSValue.uninitialized() }`。

### `ExceptionSlot.hasException` (`src/core/exception.zig:14`)

- **签名**：`pub fn hasException(self: ExceptionSlot) bool`。
- **作用**：检查这个独立槽是否非空。
- **实现**：value不是uninitialized就返回true。
- **所有权 / 错误 / 调用**：undefined、null或任意其他值也算有异常；不查询runtime或JSContext，按值读取不改变槽。

### `ExceptionSlot.set` (`src/core/exception.zig:18`)

- **签名**：`pub fn set(self: *ExceptionSlot, rt: anytype, value: JSValue) void`。
- **作用**：替换槽中的JSValue。
- **实现**：先clear(rt)，然后按值赋入新value。
- **所有权 / 错误 / 调用**：rt仅传给忽略它的clear；不retain/release、不建立GC根或屏障，不清空调用方变量。传uninitialized等于置空。

### `ExceptionSlot.clear` (`src/core/exception.zig:23`)

- **签名**：`pub fn clear(self: *ExceptionSlot, _: anytype) void`。
- **作用**：将非空槽恢复为空哨兵。
- **实现**：hasException为true时写入JSValue.uninitialized；已空不修改。
- **所有权 / 错误 / 调用**：不立即释放堆对象或调用finalizer；rt参数未用。槽此前如何成为GC边由拥有者决定，不能仅靠存在此结构推断自动保活。

### `ExceptionSlot.take` (`src/core/exception.zig:29`)

- **签名**：`pub fn take(self: *ExceptionSlot) JSValue`。
- **作用**：取出保存值并置空。
- **实现**：空槽直接返回undefined；非空保存副本，写uninitialized，再返回副本。
- **所有权 / 错误 / 调用**：不分配或root返回值；若原异常本来是undefined，仅凭返回值不能区分原槽是否为空。不是JSContext.takeException的当前实现。

## `src/core/descriptor.zig`

属性描述符用于Object内部方法边界。字段里的JSValue是借用；presence位区分缺席与显式undefined。结构自身没有root注册或验证逻辑，跨分配/GC的值由调用方保护。

`Kind = enum { generic, data, accessor }`。

`Descriptor` 默认kind=generic，value/getter/setter均undefined且各presence=false；writable/enumerable/configurable均为默认null的?bool。kind与presence是独立字段，直接构造时可以制造不一致组合，类型本身不阻止。

### `Descriptor.data` (`src/core/descriptor.zig:30`)

- **签名**：`pub fn data(value: JSValue, writable: bool, enumerable: bool, configurable: bool) Descriptor`。
- **作用**：构造显式value及完整W/E/C属性位的数据描述符。
- **实现**：kind=data、value_present=true，保存传入value及三个bool；getter/setter保持默认缺省。
- **所有权 / 错误 / 调用**：值按位借用，无复制堆对象、root或验证；显式undefined仍由value_present=true区分缺席。

### `Descriptor.accessor` (`src/core/descriptor.zig:41`)

- **签名**：`pub fn accessor(getter: JSValue, setter: JSValue, enumerable: bool, configurable: bool) Descriptor`。
- **作用**：构造getter/setter均显式存在的访问器描述符。
- **实现**：kind=accessor，getter_present与setter_present均true，设置E/C；value缺席、writable=null。
- **所有权 / 错误 / 调用**：不检查getter/setter是否可调用或undefined，直接保存任意JSValue；合法性由外围定义属性流程验证。

### `Descriptor.generic` (`src/core/descriptor.zig:53`)

- **签名**：`pub fn generic(enumerable: ?bool, configurable: ?bool) Descriptor`。
- **作用**：构造只含可选E/C位的通用描述符。
- **实现**：kind=generic，设置enumerable/configurable两个?bool，其他字段默认。
- **所有权 / 错误 / 调用**：null表示未指定，与false不同；不读写实际对象。

### `Descriptor.fromSlot` (`src/core/descriptor.zig:61`)

- **签名**：`pub fn fromSlot(flags: property.Flags, slot: property.Slot) Descriptor`。
- **作用**：按属性kind把已物化槽转成描述符。
- **实现**：deleted先返回默认generic空描述符。data复制value与W/E/C；accessor取getterValue/setterValue并标present；var_ref读取当前cell值，writable取!is_const而非flags.writable，E/C仍来自flags；auto_init unreachable。
- **所有权 / 错误 / 调用**：不触发惰性物化、callable校验或TDZ抛错；返回的VarRef当前值可能仍是uninitialized。flags与slot对应且auto_init预先物化是调用前提；所有JSValue均借用。

### `Descriptor.destroy` (`src/core/descriptor.zig:103`)

- **签名**：`pub fn destroy(_: Descriptor, _: anytype) void`。
- **作用**：保留旧调用形式的空操作。
- **实现**：忽略Descriptor和任意第二参数，函数体为空。
- **所有权 / 错误 / 调用**：不清空描述符、不释放或root任何值；借用跨GC时仍由调用方安排保活。

## 覆盖核对

- 清单函数数: 13（`src/core/descriptor.zig` 5 + `src/core/error_names.zig` 4 + `src/core/exception.zig` 4）
- 本文标题覆盖: 13
- 未覆盖: 无
