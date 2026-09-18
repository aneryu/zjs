# 06 — `JSValue` 表示、语义、格式化、bare ToString

本分册：`src/core/value.zig`、`value_semantics.zig`、`value_format.zig`、`value_string.zig`。布局与 tag 总表见 [06-core-value.md](06-core-value.md)。

## `src/core/value.zig` 类型

`JSValue.Kind`：`enum(i32)` 种类。`Tag` 是 i32 投影。单 kind 用 `is(.int)` / `as(.int)` / `from(.int, n)`，没有 `isInt` / `asInt32` 别名。复合谓词 `isNumber` / `isString` / `isBigInt` 保留。

`JSValue`：`extern struct { bits: u64 }`。float64 为 IEEE 位；其余 kind 的前缀 = `0xFFF0 + dense index`（跳过 Kind −5），`tagOf` 算术还原。编码就在 `JSValue` 上，没有单独的 NanBox 类型。

表示测试（tag 表、NaN-box 前缀、构造器、立即数分支、payload 指针、谓词、int32/float、cycleMarkHeader、asInt64）写在本文件末尾，由统一套件 `zig build test` 拉取。需要 Runtime 的堆 BigInt 会计与 FAM 乘法合同在 `src/core/bigint.zig`；分配无关的乘除内核合同在 `src/libs/bigint.zig`。

嵌套：`Int32Pair { lhs, rhs }`；`String`/`Bytes` 是 view 泛型实例。句柄 `Scope`/`Local`/`Persistent`/`Weak` 在 `zjs.value`，不在 `JSValue` 上。`abi_encoding_revision = 2`。`short_big_int_bits = 48`，范围是 48-bit 有符号立即数。

### `JSValue.shortBigIntFits` (`src/core/value.zig:89`)

- **签名**：`pub inline fn shortBigIntFits(value: i128) bool`。
- **作用**：检查i128值能否用立即BigInt表示。
- **实现**：比较是否在 48-bit 有符号立即数闭区间内。
- **所有权 / 错误 / 调用**：不创建JSValue或分配，仅返回bool。

### `JSValue.int32` (`src/core/value.zig:105`)

- **签名**：`pub fn int32(v: i32) JSValue`。
- **作用**：把i32编码为整数JSValue。
- **实现**：i32先bitCast成u32，再零扩展到 48-bit payload，配 int 的 NaN-box 前缀 `0xFFF8`。
- **所有权 / 错误 / 调用**：负数的高32位也是0；不是i64符号扩展。无分配。

### `JSValue.float64` (`src/core/value.zig:109`)

- **签名**：`pub fn float64(v: f64) JSValue`。
- **作用**：保留f64位型构造浮点tag值。
- **实现**：bitCast f64为u64；NaN 规范化到 `0x7FF8_0000_0000_0000`，使所有 float 满足 `bits <= −Inf`。
- **所有权 / 错误 / 调用**：不把整值归类为int，也不规范化NaN或负零位型。

### `JSValue.number` (`src/core/value.zig:113`)

- **签名**：`pub fn number(v: f64) JSValue`。
- **作用**：选择int32或float64表示数值。
- **实现**：先检查i32范围，intFromFloat截断后再转f64比较；精确相等且非负零时返回int32，其余float64。
- **所有权 / 错误 / 调用**：NaN/无穷不进入整数转换；负零保留浮点。此函数的归类不同于直接float64构造。

### `JSValue.boolean` (`src/core/value.zig:123`)

- **签名**：`pub fn boolean(v: bool) JSValue`。
- **作用**：构造布尔tag值。
- **实现**：payload为v?1:0，tag为boolean。
- **所有权 / 错误 / 调用**：只接受Zig bool，不执行JS ToBoolean。

### `JSValue.shortBigInt` (`src/core/value.zig:127`)

- **签名**：`pub fn shortBigInt(v: i64) JSValue`。
- **作用**：构造 48-bit 立即 BigInt。
- **实现**：将有符号值截到 48-bit payload，配 short_big_int 前缀 `0xFFFF`。
- **所有权 / 错误 / 调用**：不分配堆BigInt，不截为32位；负值以补码位型保存。

### `JSValue.bigInt` (`src/core/value.zig:131`)

- **签名**：`pub fn bigInt(header: *gc.Header) JSValue`。
- **作用**：将传入header地址包装为big_int tag的JSValue。
- **实现**：payload=@intFromPtr(header)，通过make设置对应tag。
- **所有权 / 错误 / 调用**：只包装地址，不验证header的实际kind、不分配/retain/root；调用方保证类型与寿命。

### `JSValue.string` (`src/core/value.zig:135`)

- **签名**：`pub fn string(header: *gc.Header) JSValue`。
- **作用**：将传入header地址包装为string tag的JSValue。
- **实现**：payload=@intFromPtr(header)，通过make设置对应tag。
- **所有权 / 错误 / 调用**：只包装地址，不验证header的实际kind、不分配/retain/root；调用方保证类型与寿命。

### `JSValue.stringRope` (`src/core/value.zig:139`)

- **签名**：`pub fn stringRope(header: *gc.Header) JSValue`。
- **作用**：将传入header地址包装为string_rope tag的JSValue。
- **实现**：payload=@intFromPtr(header)，通过make设置对应tag。
- **所有权 / 错误 / 调用**：只包装地址，不验证header的实际kind、不分配/retain/root；调用方保证类型与寿命。

### `JSValue.symbol` (`src/core/value.zig:143`)

- **签名**：`pub fn symbol(header: *gc.Header) JSValue`。
- **作用**：将传入header地址包装为symbol tag的JSValue。
- **实现**：payload=@intFromPtr(header)，通过make设置对应tag。
- **所有权 / 错误 / 调用**：只包装地址，不验证header的实际kind、不分配/retain/root；调用方保证类型与寿命。

### `JSValue.object` (`src/core/value.zig:147`)

- **签名**：`pub fn object(header: *gc.Header) JSValue`。
- **作用**：将传入header地址包装为object tag的JSValue。
- **实现**：payload=@intFromPtr(header)，通过make设置对应tag。
- **所有权 / 错误 / 调用**：只包装地址，不验证header的实际kind、不分配/retain/root；调用方保证类型与寿命。object tag也用于内部VarRef包装，不能凭此断言是JS Object。

### `JSValue.module` (`src/core/value.zig:151`)

- **签名**：`pub fn module(header: *gc.Header) JSValue`。
- **作用**：将传入header地址包装为module tag的JSValue。
- **实现**：payload=@intFromPtr(header)，通过make设置对应tag。
- **所有权 / 错误 / 调用**：只包装地址，不验证header的实际kind、不分配/retain/root；调用方保证类型与寿命。

### `JSValue.functionBytecode` (`src/core/value.zig:155`)

- **签名**：`pub fn functionBytecode(header: *gc.Header) JSValue`。
- **作用**：将传入header地址包装为function_bytecode tag的JSValue。
- **实现**：payload=@intFromPtr(header)，通过make设置对应tag。
- **所有权 / 错误 / 调用**：只包装地址，不验证header的实际kind、不分配/retain/root；调用方保证类型与寿命。

### `JSValue.nullValue` (`src/core/value.zig:159`)

- **签名**：`pub fn nullValue() JSValue`。
- **作用**：构造JS null。
- **实现**：make(Tag.null_value,0)，payload为0。
- **所有权 / 错误 / 调用**：不分配、不持有堆引用：payload 为 0 的立即值，GC 扫描时不算边，写进对象槽也不需要写屏障，无 error set。树内到处都是调用方（`src/core/*.zig`、`src/exec/*.zig` 数百处），没有代表性单点。

### `JSValue.undefinedValue` (`src/core/value.zig:163`)

- **签名**：`pub fn undefinedValue() JSValue`。
- **作用**：构造JS undefined。
- **实现**：make(Tag.undefined_value,0)，payload为0。
- **所有权 / 错误 / 调用**：同 `nullValue`：立即值、不分配、非 GC 边、不需屏障、无 error set。除了常规取值，它还是 leaf 原生调用 void 返回的填充值（`src/exec/builtin_dispatch.zig:1173`、`:1190`）。

### `JSValue.uninitialized` (`src/core/value.zig:167`)

- **签名**：`pub fn uninitialized() JSValue`。
- **作用**：构造内部未初始化/空槽哨兵。
- **实现**：make(Tag.uninitialized,0)，payload为0。
- **所有权 / 错误 / 调用**：立即值、不分配、非 GC 边、无 error set。它是**哨兵**而非普通值：TDZ 与派生 `this` 未初始化都用它，读到时由 `src/exec/vm_value.zig:127` 转成 `error.ReferenceError`、由 `src/exec/vm_control.zig:58` 转成 `error.DerivedThisUninitialized`，再在 `src/exec/exception_ops.zig:592` 变成 JS 的 ReferenceError；`JSValue.same`（`src/core/value.zig:520`）把它归入「同 tag 即相等」一族。

### `JSValue.catchOffset` (`src/core/value.zig:171`)

- **签名**：`pub fn catchOffset(offset: i32) JSValue`。
- **作用**：编码内部catch偏移。
- **实现**：以payloadFromI32保存offset的低32位零扩展位型，配catch_offset tag。
- **所有权 / 错误 / 调用**：不验证偏移范围或handler存在，也不是JS数值转换。

### `JSValue.exception` (`src/core/value.zig:175`)

- **签名**：`pub fn exception() JSValue`。
- **作用**：构造内部异常返回哨兵。
- **实现**：make(Tag.exception,0)，payload为0。
- **所有权 / 错误 / 调用**：无分配。本函数不设置挂起异常值；当前JSContext异常入口使用runtime.current_exception。

### `JSValue.tagOf` (`src/core/value.zig:179`)

- **签名**：`pub inline fn tagOf(self: JSValue) i32`。
- **作用**：读取i32形式的语义 tag。
- **实现**：float 为 `bits <= −Inf`；否则 `index = prefix - 0xFFF0`，Kind = `index - 8` 再对 −5 空位减一。
- **所有权 / 错误 / 调用**：依赖tag拟合i32；不检查是否是已定义Tag常量，任意非法大tag不保证可恢复失败。

### `JSValue.isNumber` (`src/core/value.zig:183`)

- **签名**：`pub fn isNumber(self: JSValue) bool`。
- **作用**：判断值是否为 JS Number（int 或 float64 两种内部数字表示之一），是算术与 `typeof` 快路径的入口判别。
- **实现**：`is(.int)` 或 `is(.float64)`。两个 tag 不相邻，无法折成一次区间比较。
- **所有权 / 错误 / 调用**：只检查标签，不验证载荷、不保活引用。不把BigInt或数值字符串视为Number。单 kind 判别是 `is(.int)` / `is(.float64)`，没有 `isInt` / `isFloat64` 别名。

### `JSValue.isBigInt` (`src/core/value.zig:195`)

- **签名**：`pub fn isBigInt(self: JSValue) bool`。
- **作用**：判断值是否为 JS BigInt，覆盖堆 BigInt 与 i64 立即 BigInt 两种表示。
- **实现**：`tag == big_int`（−4，堆）或 `tag == short_big_int`（7，payload 即 i64）。一正一负，必须两次比较。
- **所有权 / 错误 / 调用**：只检查标签，不验证载荷、不保活引用。包含堆与立即表示，不验证堆指针。

### `JSValue.isString` (`src/core/value.zig:203`)

- **签名**：`pub fn isString(self: JSValue) bool`。
- **作用**：判断值是否为 JS 字符串，含尚未拍平的 rope 中间节点。
- **实现**：`tag == string` 或 `tag == string_rope`。rope 对调用方通常不可见，取字符数据前需要先拍平。
- **所有权 / 错误 / 调用**：只检查标签，不验证载荷、不保活引用。不包含symbol，即使符号体复用String布局。单 kind 判别是 `is(.string)` / `is(.string_rope)` / `is(.symbol)` 等。

### `JSValue.setInt32AssumeInt` (`src/core/value.zig:260`)

- **签名**：`pub inline fn setInt32AssumeInt(self: *JSValue, value: i32) void`。
- **作用**：替换已确定为int的槽载荷。
- **实现**：assert槽tag为int，然后写payloadFromI32(value)，不改tag。
- **所有权 / 错误 / 调用**：调用方必须证明当前精确槽类型；不是任意值替换或GC屏障接口，assert不提供可恢复TypeError。

### `JSValue.trySetInt32FromSlot` (`src/core/value.zig:270`)

- **签名**：`pub inline fn trySetInt32FromSlot(self: *JSValue, source: *const JSValue) bool`。
- **作用**：两槽都是int时只复制payload。
- **实现**：当前Tag.int=0，使用两tag按位或是否为0同时检查；若不是均int则false且不改任一槽。成功复制source完整payload到self并true。
- **所有权 / 错误 / 调用**：source只读，可与self别名；保留目标tag，不重新规范化载荷，不分配或处理其他值类型。

### `JSValue.asInt32Pair` (`src/core/value.zig:280`)

- **签名**：`pub inline fn asInt32Pair(lhs: JSValue, rhs: JSValue) ?Int32Pair`。
- **作用**：同时解包两个int tag值。
- **实现**：用与trySetInt32FromSlot同样的联合tag检查，成功返回两个payloadAsI32，失败null。
- **所有权 / 错误 / 调用**：无值转换、不修改输入；结果Int32Pair按值返回。

### `JSValue.asNumber` (`src/core/value.zig:297`)

- **签名**：`pub fn asNumber(self: JSValue) ?f64`。
- **作用**：将两种Number表示解包成f64。
- **实现**：委托文件内numberValue：int32转f64，float64原样，其他null。
- **所有权 / 错误 / 调用**：不是ToNumber，不转换BigInt、布尔、字符串或对象。

### `JSValue.asBranchImmediateBool` (`src/core/value.zig:305`)

- **签名**：`pub inline fn asBranchImmediateBool(self: JSValue) ?bool`。
- **作用**：为int/boolean/null/undefined快速给出布尔值。
- **实现**：tagOf转u32后若大于undefined tag(3)返回null；否则以整个payload!=0为结果。
- **所有权 / 错误 / 调用**：依赖合法构造：null/undefined载荷为0，int高位规范。float、引用及其他哨兵返回null供外围完整ToBoolean；没有HTMLDDA处理。

### `JSValue.asSymbolAtom` (`src/core/value.zig:317`)

- **签名**：`pub fn asSymbolAtom(self: JSValue) ?u32`。
- **作用**：取得symbol体已关联的atom ID。
- **实现**：先asSymbolBody，缺体返回null；body.atom_id等于String.no_atom_id也返回null，否则返回id。
- **所有权 / 错误 / 调用**：不查询atom表条目是否活跃或类型正确，不登记、retain或复制Symbol。

### `JSValue.asSymbolBody` (`src/core/value.zig:323`)

- **签名**：`pub fn asSymbolBody(self: JSValue) ?*string_mod.String`。
- **作用**：把symbol载荷解释成String形状的符号体。
- **实现**：非symbol返回null；匹配则ptrFromPayload(String,payload)。
- **所有权 / 错误 / 调用**：零载荷由ptrFromPayload返回null；其余依赖有效地址/布局，非GC kind校验，无root。

### `JSValue.asInt64` (`src/core/value.zig:339`)

- **签名**：`pub fn asInt64(self: JSValue) ?i64`。
- **作用**：把立即或堆BigInt精确解包为i64。
- **实现**：先拒绝非BigInt；short直接返回。堆路径借用bigIntParts，用allocator=undefined的临时非拥有bignum视图调用toI64；超出范围返回null，支持最小i64。
- **所有权 / 错误 / 调用**：不接受JS Number，不截断超大整数，无克隆或分配；借用视图不可deinit，调用的toI64不访问allocator。

### `JSValue.asUint64` (`src/core/value.zig:362`)

- **签名**：`pub fn asUint64(self: JSValue) ?u64`。
- **作用**：将非负BigInt精确解包为u64。
- **实现**：先isBigInt，再bigIntParts借出符号/limbs，构造非拥有bignum视图调用toU64。零为0，负非零或超过一limb范围返回null。
- **所有权 / 错误 / 调用**：支持2^63至2^64-1，不能用asInt64再转换替代；不接受Number，无分配，不修改底层limbs。立即 short BigInt 用 `as(.short_big_int)`。

### `JSValue.catchTarget` (`src/core/value.zig:382`)

- **签名**：`pub fn catchTarget(self: JSValue) ?usize`。
- **作用**：从catch标记取得非负usize目标。
- **实现**：`as(.catch_offset)` 缺失时按-1处理；负数返回null，非负数转换usize返回。
- **所有权 / 错误 / 调用**：偏移0有效；不检查字节码长度、指令边界或所属函数，未匹配tag和负哨兵都表现为null。

### `JSValue.asString` (`src/core/value.zig:388`)

- **签名**：`pub fn asString(self: JSValue) ?String`。
- **作用**：构造借用的JSValue.String视图。
- **实现**：委托String.fromValue，保留原JSValue并取得asStringBody返回的指针。
- **所有权 / 错误 / 调用**：不执行JS ToString、不额外root；该共享接口也接受symbol体，rope可展开并触发分配/GC，不是严格isString谓词。

### `JSValue.asStringBody` (`src/core/value.zig:396`)

- **签名**：`pub fn asStringBody(self: JSValue) ?*string_mod.String`。
- **作用**：取得flat String形状的借用body。
- **实现**：string/symbol直接转换payload；rope取得node并flattenInfallible；其他tag返回null。
- **所有权 / 错误 / 调用**：零指针返回null；rope展开失败会尝试一次GC并重试，再失败panic，不以error联合体返回。调用方须保护原值及其他跨GC借用。

### `JSValue.asStringBodyRaw` (`src/core/value.zig:410`)

- **签名**：`pub fn asStringBodyRaw(self: JSValue) ?*string_mod.String`。
- **作用**：不展开rope地读取string或symbol body。
- **实现**：仅string/symbol返回ptrFromPayload(String,payload)，其他包括rope返回null。
- **所有权 / 错误 / 调用**：不分配、不检查GC kind或指针有效性；返回借用，不延长寿命。

### `JSValue.ropeBody` (`src/core/value.zig:418`)

- **签名**：`pub fn ropeBody(self: JSValue) ?*string_mod.StringRope`。
- **作用**：取得string_rope载荷指针。
- **实现**：非rope tag为null，匹配则ptrFromPayload(StringRope,payload)。
- **所有权 / 错误 / 调用**：不展开、验证节点内容或建立root；零载荷返回null。

### `JSValue.asBytes` (`src/core/value.zig:423`)

- **签名**：`pub fn asBytes(self: JSValue) Bytes.Error!Bytes`。
- **作用**：借用可提供字节视图的对象存储。
- **实现**：`Bytes.fromValue(self)`。
- **所有权 / 错误 / 调用**：共享实现验证AB/SAB/DataView/TypedArray及相应状态，传播Bytes.Error；不自动pin，不复制bytes，存储变化后借用有效性由调用方负责。

### `JSValue.refHeader` (`src/core/value.zig:428`)

- **签名**：`pub fn refHeader(self: JSValue) ?*gc.Header`。
- **作用**：取得三种tag的通用header指针。
- **实现**：仅big_int/object/module转换payload为gc.Header，其余null。
- **所有权 / 错误 / 调用**：这不是所有GC值的入口，字符串族和function_bytecode不匹配；不检查实际kind，object分支也可能返回VarRef header。

### `JSValue.refHeaderAssumeObject` (`src/core/value.zig:437`)

- **签名**：`pub inline fn refHeaderAssumeObject(self: JSValue) *gc.Header`。
- **作用**：解包预先证明的object-tag载荷。
- **实现**：assert isObject且payload非0，然后ptrFromInt。
- **所有权 / 错误 / 调用**：不检查GC kind、不返回optional或TypeError；即使断言通过也不能据此排除VarRef。

### `JSValue.stringHeader` (`src/core/value.zig:444`)

- **签名**：`pub fn stringHeader(self: JSValue) ?*gc.Header`。
- **作用**：读取字符串家族收集器手柄。
- **实现**：symbol/string/string_rope匹配时ptrFromPayload，其余null。
- **所有权 / 错误 / 调用**：只分类tag，既不flatten也不检查body布局；返回借用header。

### `JSValue.stringHeaderAssumeStringLike` (`src/core/value.zig:455`)

- **签名**：`pub inline fn stringHeaderAssumeStringLike(self: JSValue) *gc.Header`。
- **作用**：解包已验证的字符串家族非空header。
- **实现**：assert tag属于string/symbol/rope，再ptrFromPayload并强制解optional。
- **所有权 / 错误 / 调用**：错误tag或空载荷违反调用前提，不以可恢复错误处理；不flatten、不自动保活。

### `JSValue.functionBytecodeHeader` (`src/core/value.zig:461`)

- **签名**：`pub fn functionBytecodeHeader(self: JSValue) ?*gc.Header`。
- **作用**：读取 `.function_bytecode` 的收集器手柄。
- **实现**：只有 function_bytecode 被接受，包括 `.object` 在内的其余 tag 返回 null。
- **所有权 / 错误 / 调用**：不是通用 JS Object 转换；不验证字节码或 GC kind。

### `JSValue.cycleMarkHeader` (`src/core/value.zig:481`)

- **签名**：`pub inline fn cycleMarkHeader(self: JSValue) ?*gc.Header`。
- **作用**：按负tag区间取得可追踪载荷指针。
- **实现**：完整i64 tag若在symbol=-8至object=-1之间则ptrFromPayload(gc.Header,payload)，否则null。
- **所有权 / 错误 / 调用**：含保留-5空位，依赖合法值；载荷0仍返回null。本函数不标记、不验证对象登记，也不创建GC根。

### `JSValue.isTracerOwned` (`src/core/value.zig:489`)

- **签名**：`pub inline fn isTracerOwned(self: JSValue) bool`。
- **作用**：检查tag是否在追踪管理区间。
- **实现**：把 i64 tag 位型当 u64，与 `Tag.symbol`（−8）的 u64 位型做一次 `>=`；选出 `[−8, −1]`，与 `cycleMarkHeader` 接受的 tag 集相同。
- **所有权 / 错误 / 调用**：只判断tag，因此同区间的零载荷也true，cycleMarkHeader却null；不证明指针有效或当前可达。

### `JSValue.same` (`src/core/value.zig:517`)

- **签名**：`pub fn same(self: JSValue, other: JSValue) bool`。
- **作用**：比较内部表示身份。
- **实现**：tag不同false；null/undefined/uninitialized/exception同tag直接true而忽略payload；其余已知tag比较整个payload，未知相同tag unreachable。
- **所有权 / 错误 / 调用**：不是JS严格相等或SameValue：int和float同数不同tag仍false；float按位比较，堆字符串/BigInt按地址而非内容。

### `JSValue.sameValue` (`src/core/value.zig:526`)

- **签名**：`pub fn sameValue(self: JSValue, other: JSValue) bool`。
- **作用**：按SameValue规则比较合法JS值。
- **实现**：Number跨int/float比较，NaN同等，正负零按符号区分；BigInt比较值部件；布尔比较解包值；null/undefined按same；字符串先same再内容比较；其余same。
- **所有权 / 错误 / 调用**：无用户转换，Number与BigInt不互转。字符串比较通过迭代器处理rope，不必flatten；内部伪造载荷或未知tag不在保证范围。

### `JSValue.sameValueZero` (`src/core/value.zig:555`)

- **签名**：`pub fn sameValueZero(self: JSValue, other: JSValue) bool`。
- **作用**：按SameValueZero比较合法JS值。
- **实现**：Number的NaN彼此相等，正负零直接数值相等；布尔/null/undefined按对应逻辑，BigInt委托sameValue，字符串比较内容，其余same。
- **所有权 / 错误 / 调用**：用于集合键等语义，不调用用户代码；与sameValue主要区别是正负零。不能把它当带类型转换的松散相等。

### `numberValue` (`src/core/value.zig:575`)

- **签名**：`fn numberValue(value: JSValue) ?f64`。
- **作用**：把已有Number值解包为f64。
- **实现**：int32转f64，float64直接返回，其他null。
- **所有权 / 错误 / 调用**：文件内数值比较共用；无用户转换或分配。

### `isZeroBigInt` (`src/core/value.zig:581`)

- **签名**：`pub fn isZeroBigInt(value: JSValue) ?bool`。
- **作用**：检查可解码BigInt的limbs是否表示零。
- **实现**：bigIntParts失败返回null；limbs为空或恰有一个零limb则true，其他false。
- **所有权 / 错误 / 调用**：忽略符号，依赖规范化limbs，不扫描任意多个全零limb；不分配或变更BigInt。

### `isNegativeZero` (`src/core/value.zig:587`)

- **签名**：`fn isNegativeZero(value: f64) bool`。
- **作用**：判断f64是否为负零。
- **实现**：要求value==0且1.0/value为负Infinity。
- **所有权 / 错误 / 调用**：正零false，负零true；其他非零或NaN不进入倒数检查。

### `compareStringValues` (`src/core/value.zig:591`)

- **签名**：`fn compareStringValues(a: JSValue, b: JSValue) ?i32`。
- **作用**：为相等比较调用共享字符串比较器。
- **实现**：委托string_mod.compareStringValues(a,b,true)，eq_only开启。
- **所有权 / 错误 / 调用**：非字符串或解码失败可返回null；长度不同可直接返回1，因此此包装返回值不能当完整字典序结果。

### `compareBigIntValues` (`src/core/value.zig:595`)

- **签名**：`fn compareBigIntValues(a: JSValue, b: JSValue) ?std.math.Order`。
- **作用**：比较两种表示的BigInt数值。
- **实现**：分别用独立scratch取得符号与limbs，任一失败null，否则bignum.compareParts。
- **所有权 / 错误 / 调用**：无克隆或分配；依赖规范化符号和limbs，不把Number转BigInt。

### `bigIntParts` (`src/core/value.zig:608`)

- **签名**：`fn bigIntParts(value: JSValue, scratch: *[2]bignum.Limb) ?BigIntParts`。
- **作用**：借出BigInt符号/limbs。
- **实现**：短BigInt扩i128求幅值，以u128拆到调用方scratch，零给空slice；堆BigInt需非空refHeader，恢复core.BigInt并借其limbs；其他null。
- **所有权 / 错误 / 调用**：短值slice依赖scratch寿命，堆slice依赖原对象；不验证header实际kind。BigIntParts为negative bool加const limb slice，不拥有存储。

### `payloadFromI32` (`src/core/value.zig:631`)

- **签名**：`fn payloadFromI32(value: i32) u64`。
- **作用**：把i32低32位编码进u64。
- **实现**：先bitCast u32，再零扩展u64。
- **所有权 / 错误 / 调用**：负i32不会符号扩展高32位；用于int/catch_offset。

### `payloadAsI32` (`src/core/value.zig:636`)

- **签名**：`fn payloadAsI32(payload: u64) i32`。
- **作用**：从载荷取低32位有符号数。
- **实现**：truncate成u32后bitCast i32。
- **所有权 / 错误 / 调用**：不验证tag或高位编码，调用方先确定类型。

### `ptrFromPayload` (`src/core/value.zig:641`)

- **签名**：`fn ptrFromPayload(comptime T: type, payload: u64) ?*T`。
- **作用**：将非零载荷转换成指定类型指针。
- **实现**：payload==0返回null，否则ptrFromInt(payload)。
- **所有权 / 错误 / 调用**：不是内存地址有效性、对齐、对象kind或GC登记验证；不拥有或保活对象。

## `src/core/value_semantics.zig`

本文件提供对象转换与布尔谓词，无自定义存储类型。值与对象指针均借用；checked、trusted和HTMLDDA路径的检查强度不同，不能相互替换。字符串布尔转换可能通过共享接口展开rope。

### `objectFromValue` (`src/core/value_semantics.zig:26`)

- **签名**：`pub fn objectFromValue(value: JSValue) ?*object.Object`。
- **作用**：将真正的Object值转换为借用指针。
- **实现**：非object tag返回null；取refHeader，缺失返回null；GC meta kind非object也返回null；否则Object.fromHeader。
- **所有权 / 错误 / 调用**：这层kind检查拒绝同object tag的VarRef，不做ToObject或Proxy解包，也不是对任意伪造指针的安全验证。无root/retain。

### `objectFromValueTrustedExpression` (`src/core/value_semantics.zig:43`)

- **签名**：`pub inline fn objectFromValueTrustedExpression(value: JSValue) ?*object.Object`。
- **作用**：转换已由表达式值纪律保证的对象接收者。
- **实现**：非object tag返回null；refHeaderAssumeObject取header，仅comptime Debug模式额外assert GC kind为object，再Object.fromHeader。
- **所有权 / 错误 / 调用**：要求object tag必为真实Object而非VarRef，且载荷是有效非空header。ReleaseSafe也没有这里的kind断言；不宜把它当checked转换使用。

### `expectObject` (`src/core/value_semantics.zig:53`)

- **签名**：`pub fn expectObject(value: JSValue) error{TypeError}!*object.Object`。
- **作用**：为checked对象转换加TypeError结果。
- **实现**：objectFromValue成功返回指针，null转换为error.TypeError。
- **所有权 / 错误 / 调用**：不构造或挂载JS异常消息、不装箱原语；错误物化由调用方负责。

### `toBoolean` (`src/core/value_semantics.zig:57`)

- **签名**：`pub fn toBoolean(value: JSValue) bool`。
- **作用**：按内部值类别计算布尔结果。
- **实现**：先isHTMLDDA；undefined/null为false；布尔原值，int非0、float非0且非NaN为true；BigInt调用isZeroBigInt，无法解码时回退true；String通过asStringBody取长度，缺body为false，其余值true。
- **所有权 / 错误 / 调用**：不运行用户valueOf；rope字符串可能flatten，不能笼统说无分配。前置需合法表达式值，内部uninitialized等哨兵会落到true；object-tag 的 VarRef 包装现在由 isHTMLDDA 自身的 kind 复核挡住，落到最后的 true。

### `isHTMLDDA` (`src/core/value_semantics.zig:78`)

- **签名**：`pub fn isHTMLDDA(value: JSValue) bool`。
- **作用**：读取对象的is_html_dda标志。
- **实现**：转调 objectFromValue（object tag + refHeader + `kind == .object` 三重判定），拿不到对象返回 false，其余读取 flags.is_html_dda。
- **所有权 / 错误 / 调用**：与 objectFromValue 同样复核 GC kind，因此共享 object tag 的 VarRef cell 包装会被判为 false 而不是错位 `@fieldParentPtr`；这条守卫是必需的，因为 toBoolean 对任何值的第一步就是调用它。无用户属性读取或HTML对象名称识别。

## `src/core/value_format.zig`

Number/BigInt 解析与格式化辅助层。Number 输出通常借用调用方缓冲；BigInt 克隆或十进制输出可能分配。容量、语法过滤和大整数转浮点的边界见各函数，不能由名称推导完整规范保证。

`parseAsciiIntI128` 是 `parseAsciiInt` 的 outlined 走步；`parseJsNumberTrimmed` 的数字语法整个交给 `libs/number_format.parseNumberExact`。

### `formatFiniteNumber` (`src/core/value_format.zig:16`)

- **签名**：`pub fn formatFiniteNumber(buffer: []u8, value: f64) ![]const u8`。
- **作用**：把 Number 格式化为十进制文本。
- **实现**：先尝试简单十进制分支，失败交给 libs.number_format.formatNumber；函数本身不拒绝非有限数，后者对 NaN/±Infinity 返回静态文本。
- **所有权 / 错误 / 调用**：有限数结果借用 buffer；调用方必须提供足够容量。当前 formatNumber 没有容量检查或 NoSpaceLeft 返回分支，不能依赖错误联合来安全处理小缓冲。

### `formatFiniteNumberAssumeCapacity` (`src/core/value_format.zig:24`)

- **签名**：`pub fn formatFiniteNumberAssumeCapacity(buffer: []u8, value: f64) []const u8`。
- **作用**：供至少有 64 字节缓冲的调用方使用。
- **实现**：断言 buffer.len ≥64，调用 formatFiniteNumber 并 catch unreachable；不另行断言 value 有限。
- **所有权 / 错误 / 调用**：通常返回借用缓冲的切片，非有限数可能返回静态文本；这是容量前提，不是动态扩容接口。

### `cloneBigIntValue` (`src/core/value_format.zig:32`)

- **签名**：`pub fn cloneBigIntValue(allocator: std.mem.Allocator, value: JSValue) !bignum.BigInt`。
- **作用**：把借用的 JS BigInt 复制为拥有存储的库 BigInt。
- **实现**：short 使用 fromIntAlloc；堆 BigInt 从非空 header 找到 BigIntObject，再对 borrowedValue 调用 cloneWithAllocator。
- **所有权 / 错误 / 调用**：调用方负责结果 deinit；输入不被消费。非 BigInt 或缺失 header 返回 TypeError，分配错误传播；不独立验证 header 的实际 kind。

### `appendBigIntBase10` (`src/core/value_format.zig:43`)

- **签名**：`pub fn appendBigIntBase10(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: JSValue) !void`。
- **作用**：向已有字节列表追加 BigInt 十进制文本，不附加 n。
- **实现**：short 用 32 字节栈缓冲和 formatInt64；堆值借用 limbs 生成临时十进制串，追加后 defer free。
- **所有权 / 错误 / 调用**：不克隆或消费输入，不清空列表；非 BigInt/缺失 header 返回 TypeError，格式化和列表扩容错误传播。

### `parseJsNumber` (`src/core/value_format.zig:57`)

- **签名**：`pub fn parseJsNumber(bytes: []const u8) f64`。
- **作用**：对字节文本去除所识别空白，再解析 Number。
- **实现**：依次调用 trimJsWhitespace 和 parseJsNumberTrimmed。
- **所有权 / 错误 / 调用**：无分配；无错误联合，解析失败用 NaN 表示。输入通常是 UTF-8，但本函数不验证编码，空白 helper 也接受裸 0xA0。

### `parseAsciiInt` (`src/core/value_format.zig:64`)

- **签名**：`pub fn parseAsciiInt(comptime T: type, buf: []const u8, base: u8) std.fmt.ParseIntError!T`。
- **作用**：共享 i128 整数解析，再检查目标整数类型范围。
- **实现**：先 parseAsciiIntI128，再比较 minInt(T)/maxInt(T) 并 intCast。
- **所有权 / 错误 / 调用**：无分配；InvalidCharacter/Overflow 传播。用于边界可表示为 i128 的宿主整数类型，不是任意整数宽度接口，例如 u128 上界无法用于这里的 i128 比较。

### `parseAsciiIntI128` (`src/core/value_format.zig:70`)

- **签名**：`noinline fn parseAsciiIntI128(buf: []const u8, base: u8) std.fmt.ParseIntError!i128`。
- **作用**：提供不内联的公共整数解析函数体。
- **实现**：直接调用 std.fmt.parseInt(i128, buf, base)，字符、符号与 base 规则由标准库处理。
- **所有权 / 错误 / 调用**：借用输入、无分配；InvalidCharacter/Overflow 传播，目标 T 的额外范围检查由外层负责。

### `parseJsNumberLatin1` (`src/core/value_format.zig:78`)

- **签名**：`pub fn parseJsNumberLatin1(bytes: []const u8) f64`。
- **作用**：解析每字节一个码点的 Latin1 Number 文本。
- **实现**：先 trimJsWhitespaceLatin1，再调用与 UTF-8 入口相同的 parseJsNumberTrimmed。
- **所有权 / 错误 / 调用**：不把 Latin1 字节转换为 UTF-8；无分配，失败返回 NaN。

### `parseJsNumberTrimmed` (`src/core/value_format.zig:85`)

- **签名**：`fn parseJsNumberTrimmed(trimmed: []const u8) f64`。
- **作用**：去掉首尾空白后的 StringToNumber，对齐 qjs `JS_ToNumberHintFree` 字符串臂。
- **实现**：空串为 0；`number_format.parseNumberExact(trimmed, 0, .{ .accept_bin_oct = true })`，没吃完整串为 NaN。符号后不认前缀（`-0x10` → NaN）、`Infinity` 精确匹配、`1e` / `0x1.8` / 下划线都由内核规则拒绝。
- **所有权 / 错误 / 调用**：无分配。语法完全由 `textToFloat` 定义，本文件不再有第二套过滤条件。

### `formatSimpleFiniteDecimal` (`src/core/value_format.zig:90`)

- **签名**：`fn formatSimpleFiniteDecimal(buffer: []u8, value: f64) ?[]const u8`。
- **作用**：尝试写出整数或只有一位小数的简单十进制表示。
- **实现**：拒绝零、非有限数及绝对值不在 [1e-6,1e21) 的数；要求 value×10 为绝对值≤2^53−1 的整数，且整数转回 f64 后除 10 等于原值。按符号、整数和非零小数位写出；整数分支先要求 sign_len+20 字节，是保守容量条件。
- **所有权 / 错误 / 调用**：成功返回 buffer 子切片；不适用或容量不足返回 null，写入前完成容量检查。外层 fallback 并不因此具备小缓冲错误保护。

### `trimJsWhitespace` (`src/core/value_format.zig:144`)

- **签名**：`pub fn trimJsWhitespace(bytes: []const u8) []const u8`。
- **作用**：按已列举的空白字节序列裁剪首尾。
- **实现**：前向反复调用 prefix helper，再后向调用 suffix helper；覆盖 ASCII 09–0D/20、NBSP、U+1680、U+2000–200A、U+2028/2029、U+202F、U+205F、U+3000、U+FEFF 的 UTF-8 序列，也接受裸 A0。
- **所有权 / 错误 / 调用**：返回借用子切片，不分配、不验证完整 UTF-8；内部非空白内容保持不变。

### `trimJsWhitespaceLatin1` (`src/core/value_format.zig:162`)

- **签名**：`pub fn trimJsWhitespaceLatin1(bytes: []const u8) []const u8`。
- **作用**：裁剪 Latin1 输入两端的空白字节。
- **实现**：从两端逐字节检查 isJsWhitespaceLatin1Byte；只接受 09–0D、20、A0。
- **所有权 / 错误 / 调用**：返回借用子切片；不进行 UTF-8 多字节解码，不分配。

### `isJsWhitespaceLatin1Byte` (`src/core/value_format.zig:176`)

- **签名**：`inline fn isJsWhitespaceLatin1Byte(byte: u8) bool`。
- **作用**：判断一个 Latin1 字节是否属于支持的空白集合。
- **实现**：09–0D、20、A0 为 true，其他为 false。
- **所有权 / 错误 / 调用**：纯值判断，供 Latin1 trim 两端循环使用。

### `jsWhitespacePrefixLen` (`src/core/value_format.zig:183`)

- **签名**：`fn jsWhitespacePrefixLen(bytes: []const u8) ?usize`。
- **作用**：返回受支持空白前缀的字节宽度。
- **实现**：先按首字节分派，ASCII/裸 A0 返回 1，C2 A0 返回 2，所列三字节 Unicode 空白返回 3。
- **所有权 / 错误 / 调用**：空输入或不匹配返回 null；只做序列匹配，不是通用 UTF-8 解码器。

### `jsWhitespaceSuffixLen` (`src/core/value_format.zig:201`)

- **签名**：`fn jsWhitespaceSuffixLen(bytes: []const u8) ?usize`。
- **作用**：返回受支持空白后缀的字节宽度。
- **实现**：从末尾检查同一空白集合；先匹配 C2 A0 再处理裸 A0，避免只剥掉 UTF-8 NBSP 的最后一个字节。
- **所有权 / 错误 / 调用**：空输入或不匹配返回 null；不分配，也不验证整段编码。

### `startsWith` (`src/core/value_format.zig:218`)

- **签名**：`fn startsWith(bytes: []const u8, prefix: []const u8) bool`。
- **作用**：按字节检查前缀相等。
- **实现**：先检查长度，再对开头切片使用 std.mem.eql。
- **所有权 / 错误 / 调用**：借用输入，无分配；空 prefix 匹配任何输入。

### `endsWith` (`src/core/value_format.zig:222`)

- **签名**：`fn endsWith(bytes: []const u8, suffix: []const u8) bool`。
- **作用**：按字节检查后缀相等。
- **实现**：先检查长度，再对末尾切片使用 std.mem.eql。
- **所有权 / 错误 / 调用**：借用输入，无分配；空 suffix 匹配任何输入。

## `src/core/value_string.zig`

无 realm 的文本转换回退：把 JSValue 追加为字节文本。它不执行完整的语言级 ToPrimitive/ToString；对象按类别处理，数组递归读取内部属性接口，没有循环引用保护。`Policy` 配置 Symbol 展示、部分包装对象拆包及不支持值的处理。

`AppendStringError = errors.RuntimeError`。

`Policy`：`symbol = describe|unsupported`（默认 unsupported）；`unwrap_wrappers = false`；`unsupported = object_tag|type_error`（默认 object_tag）。String 包装不受 unwrap_wrappers 开关限制；unsupported 不是所有对象转换的总开关。

清单含公开入口 `appendValueString` 与其余私有走步。

### `appendValueString` (`src/core/value_string.zig:59`)

- **签名**：`pub noinline fn appendValueString( rt: *JSRuntime, buffer: *std.ArrayList(u8), value: JSValue, policy: Policy, ) AppendStringError!void`。
- **作用**：按 Policy 将借用 JSValue 追加为文本，供无 realm 的转换路径使用。
- **实现**：describe 模式下可取出 atom 的 Symbol 写 Symbol(描述)，缺描述为空串；其后依次处理 int/float/BigInt/bool/undefined/null/string/object，其他交给 unsupportedValue。
- **所有权 / 错误 / 调用**：使用 rt.memory.allocator 扩容列表；不消费 value、不自动建立根帧，不调用用户的 ToPrimitive/toString。错误可在已有部分输出后返回，没有回滚。

### `appendFloat` (`src/core/value_string.zig:91`)

- **签名**：`fn appendFloat(rt: *JSRuntime, buffer: *std.ArrayList(u8), float_value: f64) AppendStringError!void`。
- **作用**：向列表追加 Number 文本。
- **实现**：NaN、±Infinity 使用固定串，负零写 0，其余用 64 字节栈缓冲调用 formatFiniteNumberAssumeCapacity。
- **所有权 / 错误 / 调用**：临时文本被复制进列表；列表扩容错误传播，栈缓冲不会逃逸。

### `appendObjectString` (`src/core/value_string.zig:102`)

- **签名**：`fn appendObjectString( rt: *JSRuntime, buffer: *std.ArrayList(u8), value: JSValue, policy: Policy, ) AppendStringError!void`。
- **作用**：按内置对象类别执行有限的文本回退。
- **实现**：无 header 直接成功返回；String 包装始终递归转换 objectData。unwrap_wrappers 为 true 时另拆 Number/Boolean/BigInt/Symbol；ArrayBuffer/Promise 写固定标签；数组调用 appendArrayString，其他写 [object Object]。
- **所有权 / 错误 / 调用**：需要拆包却缺 objectData 时返回 TypeError。unsupported=type_error 不会让普通对象在这里报错；没有用户 toString、@@toStringTag 或循环保护。

### `unsupportedValue` (`src/core/value_string.zig:132`)

- **签名**：`fn unsupportedValue(rt: *JSRuntime, buffer: *std.ArrayList(u8), policy: Policy) AppendStringError!void`。
- **作用**：处理入口无法按已有分支转换的值。
- **实现**：object_tag 追加 [object Object]；type_error 返回裸 error.TypeError。
- **所有权 / 错误 / 调用**：由 Policy 决定，不在这里安装 runtime 异常对象；列表扩容可能失败。普通对象已由对象分支处理，不必进入此处。

### `appendArrayString` (`src/core/value_string.zig:143`)

- **签名**：`fn appendArrayString( rt: *JSRuntime, buffer: *std.ArrayList(u8), array: *Object, policy: Policy, ) AppendStringError!void`。
- **作用**：按逗号分隔形式递归追加数组元素。
- **实现**：u32 index 从 0 开始，每轮重新读取 arrayLength；除首项外先追加逗号，再以 atomFromUInt32 调用 Object.getProperty。undefined/null 不追加内容，其他递归转换。
- **所有权 / 错误 / 调用**：不是完整 Array.prototype.join：没有循环检测或用户 getter 调用。Object.getProperty 会查原型、处理 var_ref/auto_init，但 accessor 返回 getter 值本身。缺失属性最终为 undefined，原型上的值可能被读到；读取/转换错误保留已写前缀。

## 覆盖核对

- 清单函数数: 110（`src/core/value.zig` 80 + `src/core/value_format.zig` 20 + `src/core/value_semantics.zig` 5 + `src/core/value_string.zig` 5）
- 本文标题覆盖: 110
- 未覆盖: 无
