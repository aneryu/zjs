# 06 — number / bigint / json / uri

本分册覆盖 `number.zig`、`bigint.zig`、`json.zig`、`uri.zig`。数字格式化/解析的另一半（ToNumber 空白、dtoa）在 [06-core-value-value.md](06-core-value-value.md) 的 `value_format.zig`。

## `src/core/number.zig`

数值前缀解析的core叶子：字节入口只将ASCII数字语法视为数值，Latin1空白按单字节处理。Value入口包含无realm的文本转换回退，不能据此认定完整语言级强制转换；realm路径与 `Number.prototype.*` 格式化位于 `exec/number_ops.zig`。本文件没有额外自定义数据类型。

### `parseIntValue` (`src/core/number.zig:15`)

- **签名**：`pub fn parseIntValue(rt: *core.JSRuntime, input: core.JSValue, radix_value: ?core.JSValue) !f64`。
- **作用**：对字符串或bare-runtime文本回退执行整数前缀解析。
- **实现**：string输入先转换radix，再asStringBody；Latin1直接解析。其他情况用unwrap_wrappers=true追加文本，再转换radix，trimJsWhitespace后交给字节解析器。
- **所有权 / 错误 / 调用**：UTF16字符串经过第一段radix转换后还会走回退再次转换radix。转换不运行完整用户ToString/ToNumber；临时列表defer释放，分配错误传播，rope展开可GC后panic。UTF8去空白后仍是字节，不是整段已解码码元。

### `parseFloatValue` (`src/core/number.zig:39`)

- **签名**：`pub fn parseFloatValue(rt: *core.JSRuntime, input: core.JSValue) !f64`。
- **作用**：执行浮点前缀解析的core入口。
- **实现**：string展开后Latin1直接解析；其他输入用bare appendValueString拆包装并输出文本，trimJsWhitespace后解析。
- **所有权 / 错误 / 调用**：不调用用户toString/valueOf；Symbol按默认unsupported策略产生对象标签，通常解析为NaN，而不是在此显式TypeError。临时存储释放，转码错误传播。

### `parseIntLatin1Bytes` (`src/core/number.zig:54`)

- **签名**：`pub fn parseIntLatin1Bytes(source: []const u8, initial_radix: i32) f64`。
- **作用**：按radix解析Latin1文本的最长有效整数前缀。
- **实现**：去前导空白和可选符号；radix0默认10，只识别0x切到16，显式16也剥0x；非0且不在2..36为NaN。逐ASCII数字/字母扫描至非法digit，u128累积溢出后改f64；十进制溢出后尝试parseFloat已消耗部分。
- **所有权 / 错误 / 调用**：零消耗返回NaN；只有已消耗数字且结果为零、符号为负才返回负零。超u128的非十进制路径逐步舍入，十进制重解析失败保留此前累计值；无分配，不要求吃完整输入。

### `parseFloatLatin1Bytes` (`src/core/number.zig:107`)

- **签名**：`pub fn parseFloatLatin1Bytes(source: []const u8) f64`。
- **作用**：扫描浮点十进制或Infinity前缀。
- **实现**：无前导空白先试完整简单十进制；否则去前导空白和可选符号，Infinity前缀直接返回无穷；扫描整数、小数和指数，指数无数字则退到e之前，再尝试简单解析及std.parseFloat。
- **所有权 / 错误 / 调用**：Infinity后允许剩余字符，空串/没有任何数字为NaN；不是Number式完整字符串解析，0x等文本会只消耗十进制前缀。无分配。

### `parseSimpleDecimalFloat` (`src/core/number.zig:142`)

- **签名**：`fn parseSimpleDecimalFloat(text: []const u8) ?f64`。
- **作用**：尝试解析完整、无指数且最多15个数字的十进制文本。
- **实现**：可选符号，累计整数与小数数字，scale记录小数位；尝试第16个数字时返回null，至少一数字且无剩余字符才成功，保留负零。
- **所有权 / 错误 / 调用**：计数包括前导零和小数数字，不是15个有效数字。可接受.5和1.，不接受空白/指数/后缀；null表示外层需回退，无分配。

### `numberValue` (`src/core/number.zig:176`)

- **签名**：`pub fn numberValue(value: core.JSValue) ?f64`。
- **作用**：提取已有Number原语。
- **实现**：int32转f64，float64返回载荷，其他null。
- **所有权 / 错误 / 调用**：不拆Number对象或BigInt，不验证数值有限性；NaN/Infinity原样保留。

### `toNumber` (`src/core/number.zig:182`)

- **签名**：`pub fn toNumber(rt: *core.JSRuntime, value: core.JSValue) !f64`。
- **作用**：执行core层有限的数值转换回退。
- **实现**：Number直接返回，bool为0/1，null为0，undefined为NaN；其余通过unwrap_wrappers=true的bare文本转换，再parseJsNumber。
- **所有权 / 错误 / 调用**：不是完整规范ToNumber：不调用用户valueOf/toString，不显式拒绝BigInt（可十进制文本转数），Symbol默认文本回退通常为NaN。分配/回退错误传播，临时列表defer释放。

### `jsWhitespacePrefixLen` (`src/core/number.zig:199`)

- **签名**：`fn jsWhitespacePrefixLen(bytes: []const u8) ?usize`。
- **作用**：识别Latin1输入开头一个空白码元。
- **实现**：空输入null，首字节09..0D、20或A0返回1，否则null。
- **所有权 / 错误 / 调用**：只读一个字节，不识别多字节UTF8空白；与value_format中同名helper不同。

### `toInt32` (`src/core/number.zig:207`)

- **签名**：`fn toInt32(number: f64) i32`。
- **作用**：把f64按32位模数归约为有符号整数。
- **实现**：零/NaN/无穷为0；floor(abs)模2^32，负数非零余数反向环绕，再将≥2^31部分减2^32后转换。
- **所有权 / 错误 / 调用**：用于radix，不分配；按截断整数的模数处理，而非饱和截断到i32边界。

### `trimLeadingJsWhitespace` (`src/core/number.zig:216`)

- **签名**：`fn trimLeadingJsWhitespace(source: []const u8) []const u8`。
- **作用**：借用剥去Latin1前导空白后的后缀。
- **实现**：循环jsWhitespacePrefixLen推进索引，遇非空白停止。
- **所有权 / 错误 / 调用**：不剥尾部空白、不分配；全部为空白时返回空切片，源寿命由调用方保证。

## `src/core/bigint.zig`

GC 管理的堆 BigInt，桥接 `JSValue` 与 `libs/bigint.zig`。头注释对照 qjs `JSBigInt`（quickjs.c:611-617）。

`BigInt`：`header: gc.Header` @0，48 字节，align 8。`Flags = packed struct(u8) { negative, inline_storage, reserved:u6 }`。无容量时 `limbs_ptr=null`；内联构造的len=0仍可能保留非空容量/指针。`gc_kind_tag` = `GcKind.big_int`。borrowed `libs.bigint.BigInt` 视图 **禁止** deinit/realloc。

### `BigInt.isInline` (`src/core/bigint.zig:87`)

- **签名**：`pub inline fn isInline(self: *const BigInt) bool`。
- **作用**：读取limb存储模式。
- **实现**：返回flags.inline_storage。
- **所有权 / 错误 / 调用**：不校验指针或容量，不能判断是否已注册GC。

### `BigInt.isExternal` (`src/core/bigint.zig:91`)

- **签名**：`pub inline fn isExternal(self: *const BigInt) bool`。
- **作用**：判断是否为外部分配模式。
- **实现**：返回!inline_storage。
- **所有权 / 错误 / 调用**：零值无实际limb分配也可属于external模式；不是“指针非空”判断。

### `BigInt.negative` (`src/core/bigint.zig:95`)

- **签名**：`pub inline fn negative(self: *const BigInt) bool`。
- **作用**：读取符号标志。
- **实现**：返回flags.negative。
- **所有权 / 错误 / 调用**：不检查零或规范化；零无负号依赖构造不变量。

### `BigInt.limbs` (`src/core/bigint.zig:102`)

- **签名**：`pub inline fn limbs(self: *const BigInt) []const Limb`。
- **作用**：借用有效limb区间。
- **实现**：len==0返回空切片，否则解包limbs_ptr并取len项。
- **所有权 / 错误 / 调用**：不区分内联/外部；不校验len≤capacity，原对象须存活。

### `BigInt.capacitySliceMut` (`src/core/bigint.zig:109`)

- **签名**：`pub inline fn capacitySliceMut(self: *BigInt) []Limb`。
- **作用**：借用全部容量的可变limb窗口。
- **实现**：capacity0返回空，否则取指针前capacity项。
- **所有权 / 错误 / 调用**：len以上可未初始化；只供合法构造/修改过程，不自动更新长度、符号或GC状态。

### `BigInt.famBytes` (`src/core/bigint.zig:114`)

- **签名**：`pub inline fn famBytes(self: *const BigInt) usize`。
- **作用**：计算容量所需limb字节数。
- **实现**：capacity乘sizeof(Limb)，当前每limb8字节。
- **所有权 / 错误 / 调用**：不检查inline标志；内联销毁使用capacity而非规范化后的len。

### `BigInt.borrowedValue` (`src/core/bigint.zig:124`)

- **签名**：`pub inline fn borrowedValue(self: *const BigInt, allocator: std.mem.Allocator) libs.bigint.BigInt`。
- **作用**：构造指向当前有效limbs的库BigInt视图。
- **实现**：复制符号，将只读limbs constCast，并使用调用方传入allocator。
- **所有权 / 错误 / 调用**：类型层面可变，但契约只允许借用读；禁止deinit、realloc或擅自修改共享limbs。allocator不是从self自动取出，也不转移存储。

### `BigInt.create` (`src/core/bigint.zig:134`)

- **签名**：`pub fn create(rt: *JSRuntime, value: i128) !*BigInt`。
- **作用**：将i128复制为已注册堆BigInt。
- **实现**：用runtime accountedAllocator创建库值，errdefer释放，再createFromOwned。
- **所有权 / 错误 / 调用**：不把小值压为short JSValue；连零也可创建heap wrapper。失败释放临时库值，结果由GC管理。

### `BigInt.createFromBigInt` (`src/core/bigint.zig:140`)

- **签名**：`pub fn createFromBigInt(rt: *JSRuntime, value: libs.bigint.BigInt) !*BigInt`。
- **作用**：克隆库BigInt为已注册的堆载体。
- **实现**：先cloneWithAllocator到runtime accountedAllocator，失败清理临时值，再转createFromOwned。
- **所有权 / 错误 / 调用**：保留原输入所有权；分配/库限制错误传播，不进行short压缩。

### `BigInt.createFromOwned` (`src/core/bigint.zig:146`)

- **签名**：`pub fn createFromOwned(rt: *JSRuntime, value: libs.bigint.BigInt) !*BigInt`。
- **作用**：成功时接管库值并注册GC载体。
- **实现**：createFromOwnedReserved成功后register。
- **所有权 / 错误 / 调用**：失败仍由调用方管理原库值；成功后不得再deinit原结构副本。register无错误返回。

### `BigInt.createFromOwnedReserved` (`src/core/bigint.zig:154`)

- **签名**：`pub fn createFromOwnedReserved(rt: *JSRuntime, value: libs.bigint.BigInt) !*BigInt`。
- **作用**：接管库值创建尚未注册的wrapper。
- **实现**：先memory.create；比较allocator的ptr/vtable，不匹配时先克隆到accountedAllocator，成功后才deinit原值，最后initExternalFromOwned。
- **所有权 / 错误 / 调用**：分配/克隆失败释放临时wrapper，原值未消费；成功可能释放原limbs并替换为克隆。返回reserved对象须之后register或手动销毁。

### `BigInt.initExternalFromOwned` (`src/core/bigint.zig:180`)

- **签名**：`pub fn initExternalFromOwned(self: *BigInt, owned: libs.bigint.BigInt) void`。
- **作用**：用拥有的库值初始化外部limb载体。
- **实现**：断言limbs数量≤max_limbs，整体重写结构，header默认、ptr按空非空设置、len=capacity=切片长度并复制allocator和符号。
- **所有权 / 错误 / 调用**：不分配、不注册、不规范化或释放self旧资源；调用者保证输入已规范化及切片拥有关系，适合未初始化wrapper。

### `BigInt.createInlineUninitialized` (`src/core/bigint.zig:199`)

- **签名**：`pub fn createInlineUninitialized(rt: *JSRuntime, capacity: usize) !*BigInt`。
- **作用**：一次分配wrapper与内联limb容量。
- **实现**：超过max_limbs返回BigIntTooLarge；createWithFam后设len0、capacity、inline标志，非零容量指针指向体后FAM。
- **所有权 / 错误 / 调用**：未注册且limbs未填；len0仍可能有非空指针和容量，不能把指针空与数值零等同。失败传播分配错误。

### `BigInt.inlineBase` (`src/core/bigint.zig:214`)

- **签名**：`inline fn inlineBase(self: *BigInt) [*]u8`。
- **作用**：取得内联limb区首字节地址。
- **实现**：self地址加sizeof(BigInt)=48。
- **所有权 / 错误 / 调用**：无模式或容量校验，调用者保证分配确实含FAM。

### `BigInt.publishInline` (`src/core/bigint.zig:221`)

- **签名**：`pub inline fn publishInline(self: *BigInt, len: usize, is_negative: bool) void`。
- **作用**：提交内联结果的有效长度和符号。
- **实现**：断言inline且len≤capacity，写len，len0强制negative=false。
- **所有权 / 错误 / 调用**：名称不表示GC发布：不会register、检查高位规范化、初始化剩余项或缩容，调用者还需注册。

### `BigInt.valueRef` (`src/core/bigint.zig:228`)

- **签名**：`pub fn valueRef(self: *BigInt) JSValue`。
- **作用**：包装heap BigInt值。
- **实现**：JSValue.bigInt(&header)。
- **所有权 / 错误 / 调用**：不自动注册或压缩成short，也不root；reserved对象也能被包装，需遵循外层发布协议。

### `BigInt.fromHeader` (`src/core/bigint.zig:232`)

- **签名**：`pub inline fn fromHeader(header: *gc.Header) *BigInt`。
- **作用**：从嵌入header恢复载体。
- **实现**：fieldParentPtr和alignCast。
- **所有权 / 错误 / 调用**：不检查kind、存活或注册状态，依赖正确输入。

### `BigInt.accountedAllocationSize` (`src/core/bigint.zig:238`)

- **签名**：`pub fn accountedAllocationSize(self: *const BigInt) usize`。
- **作用**：查询wrapper及内联容量的登记大小。
- **实现**：优先取gcSlabAccountedPayload，否则48加内联famBytes；external不加外部limbs。
- **所有权 / 错误 / 调用**：外部limbs由allocator另行记账，不能把此数当BigInt全部占用；无分配。

### `BigInt.register` (`src/core/bigint.zig:249`)

- **签名**：`pub fn register(self: *BigInt, rt: *JSRuntime) void`。
- **作用**：将初始化载体发布到GC。
- **实现**：addInitializedWithSizeNoFail(header,accountedAllocationSize)。
- **所有权 / 错误 / 调用**：不先检查是否已注册，调用者避免重复发布；不自动成为根，reserved字面量由外层在适当时机注册。

### `BigInt.isRegistered` (`src/core/bigint.zig:253`)

- **签名**：`pub inline fn isRegistered(self: *const BigInt) bool`。
- **作用**：读取GC已记账标志。
- **实现**：header.metaConst().alloc_info.heap_accounted。
- **所有权 / 错误 / 调用**：不进行列表搜索或可达性检查；仅表示发布状态。

### `BigInt.releaseForTest` (`src/core/bigint.zig:260`)

- **签名**：`pub fn releaseForTest(self: *BigInt, rt: *JSRuntime) void`。
- **作用**：测试里立刻释放本帧拥有的 BigInt。
- **实现**：非 test 编译错误。已登记则先 unlink 再 `destroyFromHeader`。
- **所有权 / 错误 / 调用**：生产路径禁止。

### `BigInt.registerReservedValue` (`src/core/bigint.zig:268`)

- **签名**：`pub fn registerReservedValue(rt: *JSRuntime, value: JSValue) void`。
- **作用**：对未注册的heap BigInt值执行注册。
- **实现**：非BigInt返回；refHeader为空返回；否则fromHeader且!isRegistered才register。
- **所有权 / 错误 / 调用**：short BigInt没有header因此跳过；没有额外kind验证，不改变传入JSValue。

### `BigInt.destroyIfReservedValue` (`src/core/bigint.zig:277`)

- **签名**：`pub fn destroyIfReservedValue(rt: *JSRuntime, value: JSValue) bool`。
- **作用**：销毁尚未注册的heap BigInt并报告是否执行。
- **实现**：非BigInt/无header/已注册返回false，否则destroyFromHeader后true。
- **所有权 / 错误 / 调用**：成功后原JSValue及所有别名失效，本函数不清它们；已注册对象留给收集器。

### `BigInt.mulResultCannotCompactToShort` (`src/core/bigint.zig:319`)

- **签名**：`pub inline fn mulResultCannotCompactToShort(lhs: *const BigInt, rhs: *const BigInt) bool`。
- **作用**：保守判断乘积必定超出short表示。
- **实现**：任一len0为false，否则lhs.len+rhs.len≥3为true。
- **所有权 / 错误 / 调用**：依赖两侧规范化和limb上限；拒绝所有一limb乘一limb，即使某些结果也很大。不是仅凭heap表示断定超i64。

### `BigInt.createMulInline` (`src/core/bigint.zig:334`)

- **签名**：`pub fn createMulInline(rt: *JSRuntime, lhs: *const BigInt, rhs: *const BigInt) !*BigInt`。
- **作用**：在单个wrapper+FAM分配中完成多limb乘法。
- **实现**：断言不能压short，容量取两侧len之和；短操作数作外层，首行覆盖写、其余累加，用u128中间乘加及进位。最后裁掉高零limb但保留capacity，publishInline符号异或，再register。
- **所有权 / 错误 / 调用**：输入借用且需跨分配可达；容量过大为BigIntTooLarge。分配后无可返回错误操作，不做库normalize/realloc或short压缩。结果符号/规范化依赖合法输入。

### `BigInt.destroyFromHeader` (`src/core/bigint.zig:398`)

- **签名**：`pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) void`。
- **作用**：通过runtime账户销毁BigInt。
- **实现**：fromHeader后destroyWithAccount(&rt.memory)。
- **所有权 / 错误 / 调用**：不先unlink/unpublish，也不验证已判死；收集器或reserved销毁调用者负责正确时机和账户。

### `BigInt.destroyWithAccount` (`src/core/bigint.zig:405`)

- **签名**：`pub fn destroyWithAccount(self: *BigInt, account: *memory.MemoryAccount) void`。
- **作用**：按存储模式释放limbs与wrapper。
- **实现**：inline用capacity计算FAM大小并destroyWithFam；external在capacity非零时用self.allocator释放limbs，再用传入account销毁wrapper。
- **所有权 / 错误 / 调用**：两种分配器角色分离；不重复释放内联limbs，不清外部别名、不检测重复销毁。wrapper账户必须匹配原分配来源。

## `src/core/json.zig`

`JSON.stringify` 的字符串工厂与转义。无 exec 依赖。

### `createJsonStringValue` (`src/core/json.zig:19`)

- **签名**：`pub fn createJsonStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue`。
- **作用**：将已经构造好的序列化字节复制为GC字符串值。
- **实现**：全ASCII调用createAscii，否则createUtf8；返回String.value。
- **所有权 / 错误 / 调用**：不添加引号、不检查JSON语法。创建/解码错误传播；返回值需按调用方生命周期保持可达，不使用旧RC的owned/release约定。

### `jsonBytesAreAscii` (`src/core/json.zig:27`)

- **签名**：`fn jsonBytesAreAscii(bytes: []const u8) bool`。
- **作用**：判断所有字节是否小于0x80。
- **实现**：线性扫描遇高字节即false，扫描完为true。
- **所有权 / 错误 / 调用**：空输入为true，ASCII控制字符也为true；不是JSON内容合法性检查，无分配。

### `appendJsonStringValue` (`src/core/json.zig:35`)

- **签名**：`pub fn appendJsonStringValue(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void`。
- **作用**：将可取得的字符串body追加为带引号JSON文本。
- **实现**：对局部value建立rootValues帧并activate/deactivate；asStringBody无结果时写空字符串，否则直接按 body 的 Latin1/UTF16 表示分路（String 恒为 flat，无需展平步骤）。
- **所有权 / 错误 / 调用**：asStringBody也接受Symbol body，不能把该helper当作完整JSON.stringify的类型过滤；rope取body可分配并在展开失败时panic。缓冲区扩容错误传播，失败保留已追加前缀；root帧行为遵循运行时配置。

### `appendJsonAtomName` (`src/core/json.zig:53`)

- **签名**：`pub fn appendJsonAtomName(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), atom_id: core.Atom) !void`。
- **作用**：将atom名字追加为带引号JSON属性键。
- **实现**：tagged-int用10字节栈缓冲转十进制；普通名字缺失按空串。合法WTF8但非合法UTF8时逐码点处理，代理码点各自写成\uXXXX，其他码点走ASCII转义或UTF8；其余走逐字节转义。
- **所有权 / 错误 / 调用**：不将WTF8中的相邻高低代理码点合并；无效WTF8也落入字节路径，不会由此拒绝。借用atom名字且不自行创建atom根，调用方保证寿命；扩容失败不回滚。

### `appendEscapedJsonString` (`src/core/json.zig:84`)

- **签名**：`pub fn appendEscapedJsonString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), bytes: []const u8) !void`。
- **作用**：给ASCII/UTF8来源字节添加JSON引号与控制字符转义。
- **实现**：追加双引号，逐字节调用appendEscapedJsonByte，再追加结束双引号。
- **所有权 / 错误 / 调用**：高字节原样复制，不验证UTF8；合法编码由调用方保证。使用runtime allocator扩容，失败可留下未闭合前缀。

### `appendEscapedJsonLatin1String` (`src/core/json.zig:92`)

- **签名**：`fn appendEscapedJsonLatin1String(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), bytes: []const u8) !void`。
- **作用**：将Latin1码元转成带引号的UTF8 JSON文本。
- **实现**：ASCII交给byte转义，0x80..0xff作为码点编码为两字节UTF8；首尾加引号。
- **所有权 / 错误 / 调用**：借用输入，不追加NUL；分配错误传播，输出不回滚。

### `appendEscapedJsonUtf16String` (`src/core/json.zig:104`)

- **签名**：`fn appendEscapedJsonUtf16String(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void`。
- **作用**：将UTF16码元转成带引号的JSON文本。
- **实现**：有效代理对合成码点输出四字节UTF8；落单高/低代理写\uXXXX；ASCII转义，其他BMP码元输出UTF8。
- **所有权 / 错误 / 调用**：U+2028/U+2029不额外转义。借用输入，不追加NUL；分配失败可保留部分转义或UTF8序列。

### `appendEscapedJsonByte` (`src/core/json.zig:130`)

- **签名**：`fn appendEscapedJsonByte(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void`。
- **作用**：追加单字节的JSON转义。
- **实现**：双引号、反斜杠与退格/制表/换行/换页/回车使用短转义；其余0x00..0x1f写\u00xx，其他字节原样追加。
- **所有权 / 错误 / 调用**：本身不包引号，斜杠不转义，高字节不转码。扩容错误传播。

### `appendEscapedJsonUnit` (`src/core/json.zig:144`)

- **签名**：`fn appendEscapedJsonUnit(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: anytype) !void`。
- **作用**：追加反斜杠u及十六进制码元。
- **实现**：转u64后使用hexPad最小宽度4，字母小写，再依次追加\u与数字。
- **所有权 / 错误 / 调用**：当前调用为u8/u16，因此恰好四位；泛型接口本身不把大于0xffff的值截成四位。扩容失败可能只写入前缀。

### `appendUtf8CodePoint` (`src/core/json.zig:151`)

- **签名**：`fn appendUtf8CodePoint(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), cp: u32) !void`。
- **作用**：使用runtime allocator追加码点编码字节。
- **实现**：委托unicode.appendUtf8CodePoint，按数值区间输出一至四字节。
- **所有权 / 错误 / 调用**：底层不验证Unicode标量范围，也不拒绝代理码点；此处调用方先处理代理并提供有效范围。分配错误传播，逐字节追加可部分成功。

## `src/core/uri.zig`

URI 解码叶子，供 builtin 与 `decodeURI(...) === String.fromCharCode(...)` 融合路径使用。字节探测与hex helper不分配；Value入口取得rope body时可能展开并访问运行时。

常量：`escape_id=5`、`unescape_id=6`（legacy `escape`/`unescape` 的 `.uri` record id）。`FourByteEscapeUnits { high: u16, low: u16 }` 保存一个补充平面码点的高低代理码元。

### `decodeSingleFourByteEscapeUnits` (`src/core/uri.zig:33`)

- **签名**：`pub fn decodeSingleFourByteEscapeUnits(value: JSValue) !?FourByteEscapeUnits`。
- **作用**：探测字符串是否采用Latin1存储且恰好包含一组四字节URI转义。
- **实现**：非string直接null；取body后UTF16存储直接null，Latin1交给FromAscii探测。
- **所有权 / 错误 / 调用**：UTF16即使内容全ASCII也回退；Symbol不接受。asStringBody可能展开rope并触发分配/GC，展开失败可panic；底层URIError传播，null表示需通用路径处理。

### `decodeSingleFourByteEscapeUnitsFromAscii` (`src/core/uri.zig:47`)

- **签名**：`pub fn decodeSingleFourByteEscapeUnitsFromAscii(bytes: []const u8) !?FourByteEscapeUnits`。
- **作用**：从12字节百分号转义探测一个四字节UTF8码点。
- **实现**：先检查长度及四个%位置，再解码全部四对hex；任一步不匹配返回null。首字节低于f0返回null，高于f4报URIError；后续字节必须为10xxxxxx，合成值必须在10000..10ffff，最后拆成代理对。
- **所有权 / 错误 / 调用**：hex检查先于首字节范围检查，因此任意一对非法hex会返回null。null不证明URI合法，需外层继续校验；无分配，不借用输出。

### `fastHexPair` (`src/core/uri.zig:77`)

- **签名**：`pub fn fastHexPair(high: u8, low: u8) ?u8`。
- **作用**：将两个ASCII十六进制数字合成字节。
- **实现**：依次调用fastHexValue，高位左移4再或低位。
- **所有权 / 错误 / 调用**：任一非法即null，高位非法会提前返回；不分配。

### `initFastHexTable` (`src/core/uri.zig:83`)

- **签名**：`fn initFastHexTable() [256]i8`。
- **作用**：构造256项有符号十六进制值表。
- **实现**：默认全部-1，0..9对应数字，A..F及a..f对应10..15；用于初始化常量fast_hex_table。
- **所有权 / 错误 / 调用**：常量初始化时求值，无堆分配；表元素i8足以区分非法标记与0..15。

### `fastHexValue` (`src/core/uri.zig:99`)

- **签名**：`pub fn fastHexValue(byte: u8) ?u8`。
- **作用**：读取一个字节对应的十六进制数字值。
- **实现**：索引fast_hex_table，负值返回null，否则转换u8。
- **所有权 / 错误 / 调用**：仅接受0..9、A..F、a..f；无分配。源码含条件判断，不承诺生成机器码无分支。

## 覆盖核对

- 清单函数数: 52（`src/core/bigint.zig` 27 + `src/core/json.zig` 10 + `src/core/number.zig` 10 + `src/core/uri.zig` 5）
- 本文标题覆盖: 52
- 未覆盖: 无
