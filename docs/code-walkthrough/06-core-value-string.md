# 06 — 字符串、rope、视图、字节

本分册：`src/core/string.zig`、`string_view.zig`、`bytes_view.zig`。rope 总览见 [06-core-value.md](06-core-value.md) §5。

## `src/core/string.zig` 类型

`StringError = error{ InvalidUtf8 }`。`max_length = (1<<30)-1`（qjs `JS_STRING_LEN_MAX`，quickjs.c:212）。超长→`error.StringTooLong`。

`StringRope` 56B：`left`/`right` JSValue @0/@16，`rt` @32，`buffer` @40，`len` u32 @48，`depth` u8，`wide`，`extensible`。`depth==0` 表示已线性化（qjs 用空串 right child）。dependent view：`buffer!=null`，`left`/`right` 是 undefined。`metadata_prefix_size` 对齐到 rope align。

`StringBuffer` 8B：`capacity` u32、`is_wide`、3字节reserved；kind `.string_buffer`，无出边或业务析构回调，由GC释放存储，没有专用JSValue tag。`units_offset=8`，capacity按码元而非字节计。

`String` 12B：`LenMeta { len:u31, is_wide }` 与 `HashMeta { hash:u30, atom_type:u2 }` 均为 packed u32，另有 `atom_id`；atom_type 当前保留未用。String 始终 flat，旧注释中的 is_rope/rope 字段已不存在。`no_atom_id = maxInt(u32)`。`hash==0` 表示未计算。字符在结构体后 FAM（qjs `u.str8[]`/`u.str16[]`）。latin1 尾 NUL。`payload_offset` 对齐 u16。

常量：`rope_short_len=512`、`rope_short2_len=8192`、`rope_max_depth=60`、`tail_buffer_seed_len=512`、`tail_buffer_min_capacity=64`。

`String.ResolvedData` 是带enum标签的 Latin1/UTF16 借用切片联合体。`StringValueIterator` 保存current值、60个待遍历rope指针和stack_len，不物化，也不自行注册根或修复超深树。

内部测量类型 `StringValueInfo { len:usize, depth:u8, wide:bool }`；`RopeBuckets` 是44项optional JSValue，阈值为1、2起的Fibonacci序列，末项1134903170超过max_length。节点分配总请求64字节（8字节prefix+56字节body）。`InlineAllocationLayout` 保存请求总长和对齐，`Utf8Plan` 保存解码单元数/宽度，`Decoded` 保存u21码点及下一字节下标。

## `StringRope`

### `StringRope.header` (`src/core/string.zig:92`)

- **签名**：`pub inline fn header(self: *const StringRope) *gc.GCObjectHeader`。
- **作用**：把 rope 体指针作为统一 GC 手柄返回。
- **实现**：constCast 后对齐/指针转换，地址不变。
- **所有权 / 错误 / 调用**：不校验 kind、不分配或建立根；metadata 位于体前 metadata_prefix_size 字节。

### `StringRope.fromHeader` (`src/core/string.zig:96`)

- **签名**：`pub inline fn fromHeader(hdr: *gc.GCObjectHeader) *StringRope`。
- **作用**：将已知 rope 的 GC 手柄转换为节点指针。
- **实现**：alignCast/ptrCast，地址不变。
- **所有权 / 错误 / 调用**：调用者保证正确 kind、对齐和存活；函数不读取 metadata 来验证。

### `StringRope.metadata` (`src/core/string.zig:101`)

- **签名**：`pub inline fn metadata(self: *const StringRope) *gc.Metadata`。
- **作用**：取得 rope 体之前的收集器 metadata。
- **实现**：将体指针视为字节指针，减 metadata_prefix_size 后转为 Metadata 指针。
- **所有权 / 错误 / 调用**：依赖引擎的带前缀分配布局；返回可变借用，不是任意栈上 StringRope 都可调用。

### `StringRope.value` (`src/core/string.zig:107`)

- **签名**：`pub fn value(self: *StringRope) JSValue`。
- **作用**：包装指向该 rope 的 JSValue。
- **实现**：JSValue.stringRope(self.header())。
- **所有权 / 错误 / 调用**：不复制内容、不分配、不增加生命周期保护；值必须通过根或堆边保持可达。

### `StringRope.isWide` (`src/core/string.zig:111`)

- **签名**：`pub fn isWide(self: *const StringRope) bool`。
- **作用**：读取节点记录的宽码元标志。
- **实现**：直接返回 wide。
- **所有权 / 错误 / 调用**：不扫描孩子或 buffer，也不重新推导宽度；依赖构造及后续状态变更维护一致性。

### `StringRope.len_` (`src/core/string.zig:115`)

- **签名**：`pub fn len_(self: *const StringRope) usize`。
- **作用**：读取节点总码元长度。
- **实现**：将 u32 len 转为 usize。
- **所有权 / 错误 / 调用**：不遍历内容；是码元数而非 UTF-8 字节数或 Unicode 标量数，无范围重验。

### `StringRope.isLinearized` (`src/core/string.zig:122`)

- **签名**：`pub fn isLinearized(self: *const StringRope) bool`。
- **作用**：判断节点是否处于已展开状态。
- **实现**：只检查 depth==0。
- **所有权 / 错误 / 调用**：不验证 left 的实际类型、buffer 或 right 状态；depth 为表示不变量。

### `StringRope.flatString` (`src/core/string.zig:126`)

- **签名**：`pub fn flatString(self: *const StringRope) ?*String`。
- **作用**：借用已展开节点的 flat body。
- **实现**：非 depth0 返回 null；否则 left.asStringBodyRaw。
- **所有权 / 错误 / 调用**：不触发展开。raw helper 按 string/symbol tag 取 body，正常 rope 不变量要求 left 为 flat string；返回值靠节点中的 GC 边保活。

### `StringRope.bufferView` (`src/core/string.zig:135`)

- **签名**：`pub inline fn bufferView(self: *const StringRope) ?String.ResolvedData`。
- **作用**：借用 dependent view 的 buffer 前缀。
- **实现**：buffer=null 返回 null，否则 buf.prefix(self.len)。
- **所有权 / 错误 / 调用**：没有复制或展开；prefix 要求 len≤capacity。buffer view 是叶节点，读者不应继续遍历 undefined 的 left/right；借用依赖节点和 buffer 存活。

### `StringRope.isExtensibleView` (`src/core/string.zig:143`)

- **签名**：`pub inline fn isExtensibleView(self: *const StringRope) bool`。
- **作用**：检查该节点是否带 buffer 追加权标志。
- **实现**：返回 extensible 且 buffer!=null。
- **所有权 / 错误 / 调用**：不比较 len 与另一个 used 字段：StringBuffer 只有容量和宽度，没有记录已用长度。唯一追加权由创建/追加路径维护，该谓词自身不验证独占性或剩余容量。

### `StringRope.flatten` (`src/core/string.zig:152`)

- **签名**：`pub fn flatten(self: *StringRope) !*String`。
- **作用**：把 rope 内容复制为 flat 并缓存到节点。
- **实现**：已有 flat 直接返回；buffer view 复制所指前缀，普通树按 wide 选择目标存储并 copyRopeContent，Latin1 写尾 NUL。随后执行 generationalBarrierValue，写 left=flat、right=undefined、buffer=null、extensible=false、depth=0。
- **所有权 / 错误 / 调用**：成功后返回借用 body；移除旧 GC 边不等于立即销毁旧孩子/buffer。分配错误发生在节点改写前，原表示保留；此函数没有显式根帧，收集期间 self/输入须保持可达。

### `StringRope.flattenInfallible` (`src/core/string.zig:206`)

- **签名**：`pub fn flattenInfallible(self: *StringRope) *String`。
- **作用**：为不能返回错误的读者展开 rope。
- **实现**：捕获 flatten 的任何错误，尝试 engine_active 模式收集且忽略该收集错误，然后只重试一次；再次失败以 OOM 文本 panic。
- **所有权 / 错误 / 调用**：不是只捕获 OutOfMemory；没有向调用者返回错误，也没有在此创建显式 self 根。可能分配和执行 GC，不能当作无副作用借用转换。

### `StringRope.contentHash` (`src/core/string.zig:215`)

- **签名**：`pub fn contentHash(self: *StringRope) u32`。
- **作用**：取得 rope 内容的哈希而不强制展开。
- **实现**：调用 stringValueContentHash(self.value()) 并解包 optional；该路径复用 flat 缓存或用 StringValueIterator 逐片读取。
- **所有权 / 错误 / 调用**：正常 rope tag 保证有结果；节点没有独立 hash 字段，重复未展开树的哈希可能重复遍历。

## `StringBuffer`

### `StringBuffer.header` (`src/core/string.zig:251`)

- **签名**：`pub inline fn header(self: *const StringBuffer) *gc.GCObjectHeader`。
- **作用**：取得 buffer 体对应的 GC 手柄。
- **实现**：constCast、alignCast、ptrCast，地址不变。
- **所有权 / 错误 / 调用**：不分配或验证 kind，不把 buffer 包装为 JSValue；由 storage-cell 边持有。

### `StringBuffer.fromHeader` (`src/core/string.zig:255`)

- **签名**：`pub inline fn fromHeader(hdr: *gc.GCObjectHeader) *StringBuffer`。
- **作用**：把已知 string_buffer 手柄转换为 buffer。
- **实现**：对齐后指针转换。
- **所有权 / 错误 / 调用**：调用者保证类型和存活；未执行 kind 校验或创建根。

### `StringBuffer.unitsPtr` (`src/core/string.zig:259`)

- **签名**：`inline fn unitsPtr(self: *const StringBuffer) [*]u8`。
- **作用**：取得紧接 buffer 头的码元区原始指针。
- **实现**：把 self 转为可变字节指针并加 units_offset=8。
- **所有权 / 错误 / 调用**：即使 self 为 const，此内部 helper 仍返回可变指针；不检查宽度/容量或初始化范围，外层选择切片类型。

### `StringBuffer.latin1` (`src/core/string.zig:264`)

- **签名**：`pub inline fn latin1(self: *StringBuffer) []u8`。
- **作用**：借用整个窄 buffer 的可变容量区。
- **实现**：断言 !is_wide，返回 unitsPtr()[0..capacity]。
- **所有权 / 错误 / 调用**：长度是容量而不是有效前缀，尾部可能未初始化；调用者维护写入范围和追加权，不带尾 NUL 保证。

### `StringBuffer.utf16` (`src/core/string.zig:269`)

- **签名**：`pub inline fn utf16(self: *StringBuffer) []u16`。
- **作用**：借用整个宽 buffer 的可变容量区。
- **实现**：断言 is_wide，将 unitsPtr 对齐转换为 u16 指针，取 capacity 项。
- **所有权 / 错误 / 调用**：容量按码元计，字节数为两倍；不保证所有项已初始化，不验证并发或追加权。

### `StringBuffer.latin1Const` (`src/core/string.zig:275`)

- **签名**：`pub inline fn latin1Const(self: *const StringBuffer) []const u8`。
- **作用**：借用整个窄 buffer 的只读容量区。
- **实现**：断言 !is_wide，返回 capacity 字节只读切片。
- **所有权 / 错误 / 调用**：只读类型不证明数据已初始化，也不阻止其他别名写入；实际读者应限制在已填前缀。

### `StringBuffer.utf16Const` (`src/core/string.zig:280`)

- **签名**：`pub inline fn utf16Const(self: *const StringBuffer) []const u16`。
- **作用**：借用整个宽 buffer 的只读容量区。
- **实现**：断言 is_wide，对齐转换为 const u16 指针并取 capacity 项。
- **所有权 / 错误 / 调用**：没有转码或复制，源须存活；内容有效长度由调用方决定。

### `StringBuffer.prefix` (`src/core/string.zig:287`)

- **签名**：`pub inline fn prefix(self: *const StringBuffer, used: u32) String.ResolvedData`。
- **作用**：按 buffer 宽度返回指定前缀切片。
- **实现**：断言 used≤capacity，再从宽或窄全容量切片取 [0..used]，包装 ResolvedData。
- **所有权 / 错误 / 调用**：不检查这些单元是否已写入，不维护 used 字段；返回借用联合体，不分配。

## 缓冲分配

### `stringBufferAllocSize` (`src/core/string.zig:296`)

- **签名**：`fn stringBufferAllocSize(is_wide: bool, capacity: usize) ?usize`。
- **作用**：计算 buffer 分配请求的总字节数。
- **实现**：宽度决定1/2字节单元，用 checked mul 计算容量字节，再 checked add 8字节头和 gc.string_prefix_size。
- **所有权 / 错误 / 调用**：任一 usize 溢出返回 null；不在这里检查 max_length，不包含 Latin1 尾 NUL 或分配器 size-class 向上取整。

### `createStringBuffer` (`src/core/string.zig:307`)

- **签名**：`pub fn createStringBuffer(rt: *JSRuntime, is_wide: bool, capacity: usize) !*StringBuffer`。
- **作用**：分配并发布尚未初始化码元区的 tail buffer。
- **实现**：capacity>max_length 为 StringTooLong；尺寸溢出为 OutOfMemory。先 collectBeforeObjectAllocation，再 createStorageCell(string_buffer_kind_tag,total)，写 capacity/is_wide，按 cell.accounted_bytes 发布。
- **所有权 / 错误 / 调用**：分配可触发 GC，调用者先保护已有输入；仅头部初始化，单位区需在任何读取 view 发布前填好。按存储分配器选择 block cell 或 extent，返回指针本身不自动建立永久根。

### `destroyStringBufferCell` (`src/core/string.zig:322`)

- **签名**：`pub fn destroyStringBufferCell(rt: *JSRuntime, header: *gc.GCObjectHeader) void`。
- **作用**：回收已判死的 string_buffer block cell。
- **实现**：断言是 block cell，依据 capacity/width 算尺寸，用 size-class accounted body bytes 撤销发布，再 memory.destroyStringCell。
- **所有权 / 错误 / 调用**：输入必须为有效 buffer 且已允许销毁；不处理出边、atom 或外部回调，也不是 extent 的通用释放入口。

### `accountedStorageSizeFromHeader` (`src/core/string.zig:332`)

- **签名**：`pub fn accountedStorageSizeFromHeader(header: *const gc.GCObjectHeader) usize`。
- **作用**：查询 string_buffer 的收集器记账体积。
- **实现**：从 buffer 头计算含前缀请求大小；block cell 返回按请求选取的 accountedBodyBytesForRequest，extent 返回 total−string_prefix_size。
- **所有权 / 错误 / 调用**：返回值排除 metadata 前缀，block 部分包含分配档位影响；假定合法 buffer 头，尺寸 optional 直接解包，没有错误返回。

### `isAsciiBytes` (`src/core/string.zig:341`)

- **签名**：`pub fn isAsciiBytes(bytes: []const u8) bool`。
- **作用**：判断每个字节是否均低于0x80。
- **实现**：遇到≥0x80立即 false，遍历完为 true。
- **所有权 / 错误 / 调用**：空串为 true，包含 NUL/控制字符也为 true；不提供打印字符或文本语义验证，无分配。

## `String` 工厂与访问

### `String.header` (`src/core/string.zig:385`)

- **签名**：`pub inline fn header(self: *const String) *gc.GCObjectHeader`。
- **作用**：取得 flat String 的 GC 体手柄。
- **实现**：constCast 后 alignCast/ptrCast，地址不变。
- **所有权 / 错误 / 调用**：不检查 kind 或注册根；header 并非另一个内嵌字段，metadata 在体之前。

### `String.fromHeader` (`src/core/string.zig:389`)

- **签名**：`pub inline fn fromHeader(hdr: *gc.GCObjectHeader) *String`。
- **作用**：把已知字符串形状的手柄转为 String。
- **实现**：仅做对齐和指针转换。
- **所有权 / 错误 / 调用**：调用者保证有效存活 body，函数不检查 kind；Symbol 也使用这种 body 表示。

### `String.bindAtomId` (`src/core/string.zig:400`)

- **签名**：`pub fn bindAtomId(self: *String, rt: *JSRuntime, atom_id: u32) void`。
- **作用**：写入 atom 回指，并对动态 id 开启销毁回调标记。
- **实现**：总是先写 atom_id；no_atom_id、const、tagged-int 直接返回，其余调用 setNeedsFinalizer。
- **所有权 / 错误 / 调用**：不查 atom 有效性/名称，不填 atom 表 str 槽；即使后来绑定静态 id 也不清已有 finalizer 位。不是强根或 RC 操作。

### `String.metadata` (`src/core/string.zig:407`)

- **签名**：`pub inline fn metadata(self: *const String) *gc.Metadata`。
- **作用**：借用体前的 Metadata。
- **实现**：字节指针减 gc.string_prefix_size 后对齐转换。
- **所有权 / 错误 / 调用**：要求来自引擎带前缀的分配；返回可变指针，不适用于独立栈上 String。

### `String.createAscii` (`src/core/string.zig:414`)

- **签名**：`pub fn createAscii(rt: *JSRuntime, bytes: []const u8) !*String`。
- **作用**：以 Latin1 字节语义复制输入。
- **实现**：直接转发 createLatin1，没有 ASCII 验证。
- **所有权 / 错误 / 调用**：高字节也被接受且作为0..255码元；不是 UTF-8 解码接口。结果受 GC 管理，调用者负责保活，分配/超长错误传播。

### `String.createUtf8` (`src/core/string.zig:420`)

- **签名**：`pub fn createUtf8(rt: *JSRuntime, bytes: []const u8) !*String`。
- **作用**：解码 UTF-8及内部代理项三字节表示为 flat 存储。
- **实现**：scanUtf8 先验证并确定码元数和宽度；全码点≤255则分配 Latin1，其他分配 UTF-16；decodeUtf8 填充，窄结果追加 NUL，解码错误时 destroyFlat。
- **所有权 / 错误 / 调用**：接受 WTF-8/CESU-8 风格代理项，不是严格外部 UTF-8 验证器。输入借用且两遍读取，输出复制；InvalidUtf8、StringTooLong、分配错误传播，创建时可能 GC。

### `String.createUtf16` (`src/core/string.zig:438`)

- **签名**：`pub fn createUtf16(rt: *JSRuntime, units: []const u16) !*String`。
- **作用**：复制 UTF-16 码元并尽可能压成 Latin1。
- **实现**：先找是否存在>255单元；没有则逐项缩窄并写尾 NUL，否则原样复制到宽存储。
- **所有权 / 错误 / 调用**：不验证代理项配对，空输入得到窄空串；不使用已删除的 JSValue.free，结果由 GC 管理，需保持可达。

### `String.createUtf16Pair` (`src/core/string.zig:462`)

- **签名**：`pub fn createUtf16Pair(rt: *JSRuntime, first: u16, second: u16) !*String`。
- **作用**：创建恰好包含两个指定码元的字符串。
- **实现**：两者均≤255时写窄存储，否则写两个 u16。
- **所有权 / 错误 / 调用**：名字不保证参数构成有效代理对；不组合成一个码元或验证 Unicode 合法性，长度始终2。分配错误传播。

### `String.createSymbolNoDescription` (`src/core/string.zig:481`)

- **签名**：`pub fn createSymbolNoDescription(rt: *JSRuntime) !*String`。
- **作用**：创建用于无描述符号的宽空 body。
- **实现**：调用 createUninitialized(rt,utf16,0)。
- **所有权 / 错误 / 调用**：仅返回 String 指针，不设置 symbol tag/atom_id，也不驻留或缓存；分配错误传播。

### `String.isSymbolNoDescription` (`src/core/string.zig:485`)

- **签名**：`pub fn isSymbolNoDescription(self: *const String) bool`。
- **作用**：检查 body 是否符合宽空串哨兵形状。
- **实现**：len()==0 且 isWide() 为 true。
- **所有权 / 错误 / 调用**：不检查其来源或 JSValue tag；任何宽空 String 都满足，实际无描述含义依赖符号使用场景。

### `String.createAtomBacked` (`src/core/string.zig:489`)

- **签名**：`pub fn createAtomBacked(rt: *JSRuntime, atom_id: u32) !*String`。
- **作用**：复用 atom 缓存体，或根据名称创建并尝试缓存字符串。
- **实现**：cachedString 命中直接返回；否则 name 缺失为 InvalidAtom，再 createUtf8 并 cacheString。
- **所有权 / 错误 / 调用**：不是零拷贝借用 atom.bytes 的构造。cachedString 没有 kind 限制，因此命中可返回已有符号体；只有 miss 后 cacheString 才拒绝为非 string kind 新建绑定。tagged-int 没有 name，此接口不负责格式化它。

### `String.internAtom` (`src/core/string.zig:515`)

- **签名**：`pub fn internAtom(self: *String, rt: *JSRuntime) !u32`。
- **作用**：取得已有回指或按 flat 内容驻留 atom。
- **实现**：atom_id 非哨兵直接返回；否则计算内容 hash，ASCII Latin1 直接 internString，非 ASCII Latin1/UTF-16 用临时 UTF-8/WTF-8 字节列表转换后驻留，再 cacheString。
- **所有权 / 错误 / 调用**：已有回指不重新验证活性或执行 noteCompileScope；在符号体上可直接返回符号 id。String 本身总是 flat，此函数不展开 rope。临时列表 defer 释放；旧注释的 atoms.free/表缓存强根说法已过时。

### `String.createLatin1Concat` (`src/core/string.zig:540`)

- **签名**：`pub fn createLatin1Concat(rt: *JSRuntime, a: []const u8, b: []const u8) !*String`。
- **作用**：一次分配后复制两段 Latin1 内容。
- **实现**：普通 usize 加法算 total，createUninitialized，依次 memcpy 并写尾 NUL。
- **所有权 / 错误 / 调用**：不改输入、不做 UTF-8 解码；加法不是 checked Overflow 返回，长度上限由分配 helper 检查。输入在可能 GC 的分配期间须有效。

### `String.createLatin1Parts` (`src/core/string.zig:554`)

- **签名**：`pub fn createLatin1Parts(rt: *JSRuntime, parts: []const []const u8, total: usize) !*String`。
- **作用**：按预先测量的总长复制多个 Latin1 片段。
- **实现**：分配 total，逐段断言范围后复制，最后断言 offset==total 并写尾 NUL。
- **所有权 / 错误 / 调用**：total 必须等于各段长度和；不匹配违反调用前提，不返回可恢复的长度错误。无中间列表，但分配仍可能 GC。

### `String.createResolvedParts` (`src/core/string.zig:577`)

- **签名**：`pub fn createResolvedParts(rt: *JSRuntime, parts: []const ResolvedData, total: usize, wide: bool) !*String`。
- **作用**：按调用者指定的宽度和总码元数拼接已解析片段。
- **实现**：wide=false 只接受 Latin1，遇 UTF-16 unreachable；wide=true 时 Latin1逐码元拓宽、UTF-16 memcpy。末尾断言 offset==total，窄结果写 NUL。
- **所有权 / 错误 / 调用**：不自行计算 wide/total；即使所有片段窄，传 wide=true 仍生成宽串。调用者保证片段总长、宽度和存活，分配错误传播。

### `String.createUtf16Concat` (`src/core/string.zig:619`)

- **签名**：`pub fn createUtf16Concat(rt: *JSRuntime, a: []const u16, b: []const u16) !*String`。
- **作用**：将两段码元原样复制到新的宽 String。
- **实现**：普通 usize 加法计算总长，再创建 UTF-16 存储和两次 memcpy。
- **所有权 / 错误 / 调用**：即使全部≤255或为空也保留宽表示；不验证代理对、不附尾 NUL。长度加法没有显式 Overflow 错误，结果由 GC 管理。

### `String.createAsciiSuffix` (`src/core/string.zig:634`)

- **签名**：`pub fn createAsciiSuffix(rt: *JSRuntime, source: ResolvedData, suffix: []const u8) !*String`。
- **作用**：在已解析内容后追加 ASCII 后缀并保持源宽度。
- **实现**：断言 suffix 全 ASCII；窄输入转 createLatin1Concat，宽输入用 std.math.add 算总长，复制原单元后逐字节拓宽 suffix。
- **所有权 / 错误 / 调用**：宽分支加法溢出返回 Overflow，而非 StringTooLong；未溢出但超过字符串上限由创建 helper 返回 StringTooLong。窄分支沿普通加法路径。

### `String.createLatin1` (`src/core/string.zig:650`)

- **签名**：`pub fn createLatin1(rt: *JSRuntime, bytes: []const u8) !*String`。
- **作用**：复制任意 Latin1 字节为窄 flat String。
- **实现**：按 bytes.len 创建未初始化窄存储，memcpy 后写额外尾 NUL。
- **所有权 / 错误 / 调用**：不验证 ASCII 或 UTF-8；输入内的 NUL 仍是长度内码元。输出内容独立，分配时输入须保持有效，超长/分配错误传播。

### `String.createAsciiCaseMapped` (`src/core/string.zig:661`)

- **签名**：`pub fn createAsciiCaseMapped(rt: *JSRuntime, bytes: []const u8, to_lower: bool) !?*String`。
- **作用**：对纯 ASCII 输入直接分配并转换大小写。
- **实现**：先扫描，任意字节≥128立即返回 null；否则创建窄 String，根据 to_lower 调用 toLowerAscii/toUpperAscii，写尾 NUL。
- **所有权 / 错误 / 调用**：非 ASCII 的 null 表示需要调用方回退，不是错误；纯 ASCII 即使无字母变化也会创建结果。不是 Unicode/locale 大小写转换，分配错误传播。

### `String.createRope` (`src/core/string.zig:709`)

- **签名**：`pub fn createRope(rt: *JSRuntime, left: JSValue, right: JSValue) !*StringRope`。
- **作用**：创建保存左右值的普通拼接节点。
- **实现**：分别 stringValueInfo 获取长/宽/深度，交给 createRopeNode 检查总长并创建节点；此入口不执行深度再平衡。
- **所有权 / 错误 / 调用**：要求输入为有效 string/rope 或支持的 symbol body，不执行 ToString。存储值副本形成 GC 边，不增加 RC；分配期间输入仍须可达。`String.createRopeOwned` 现在就是本函数的别名（`pub const createRopeOwned = createRope;`），两者不存在所有权差异。

### `String.createBalancedRope` (`src/core/string.zig:726`)

- **签名**：`pub fn createBalancedRope(rt: *JSRuntime, left: JSValue, right: JSValue) !JSValue`。
- **作用**：创建节点，超过深度阈值时再平衡。
- **实现**：createRope 成功后取得值；depth≤60 直接返回，其他交给 rebalanceRope。
- **所有权 / 错误 / 调用**：再平衡错误传播，已创建节点没有本地显式销毁，由 GC 可达性管理。结果可能是重新组合的值；调用方需保持返回值可达。

### `String.createBalancedRopeOwned` (`src/core/string.zig:740`)

- **签名**：`pub fn createBalancedRopeOwned(rt: *JSRuntime, left: JSValue, right: JSValue) !JSValue`。
- **作用**：通过 Owned 名称执行相同深度限制的拼接。
- **实现**：先 createRopeOwned（即 createRope 的别名），再按 depth≤60 返回或调用 rebalanceRope。
- **所有权 / 错误 / 调用**：当前与非 Owned 入口没有 RC 消费差异；失败不自动释放输入，普通值复制仍需遵守 GC 根规则。

### `String.contentHash` (`src/core/string.zig:753`)

- **签名**：`pub fn contentHash(self: *const String) u32`。
- **作用**：计算并缓存 flat 字符串的30位非零内容哈希。
- **实现**：hash_meta.hash 为0时 constCast 后按 Latin1/UTF-16 单元累计再 foldHash30，随后返回缓存。
- **所有权 / 错误 / 调用**：无分配；会修改 const 接口指向的缓存，未提供线程同步。已计算后修改字符不会在此自动失效缓存，依赖字符串内容不变。

### `String.value` (`src/core/string.zig:767`)

- **签名**：`pub fn value(self: *String) JSValue`。
- **作用**：把 flat body 包装为 string tag 的值。
- **实现**：JSValue.string(self.header())。
- **所有权 / 错误 / 调用**：即使 body 用作符号身份，此接口也生成 string 而非 symbol tag；不复制内容、校验来源或建立根。

### `String.len` (`src/core/string.zig:771`)

- **签名**：`pub fn len(self: *const String) usize`。
- **作用**：读取 flat 字符串码元数。
- **实现**：返回 len_meta.len 并扩展为 usize。
- **所有权 / 错误 / 调用**：不含 Latin1 尾 NUL，不等于 UTF-8 字节数或 Unicode 标量数。

### `String.isWide` (`src/core/string.zig:775`)

- **签名**：`pub fn isWide(self: *const String) bool`。
- **作用**：读取实际存储宽度。
- **实现**：返回 len_meta.is_wide。
- **所有权 / 错误 / 调用**：不扫描内容；宽存储仍可能只含小于256的单元，不能据此推断文本范围。

### `String.hash` (`src/core/string.zig:782`)

- **签名**：`pub fn hash(self: *const String) u32`。
- **作用**：提供内容哈希访问别名。
- **实现**：直接调用 contentHash。
- **所有权 / 错误 / 调用**：可能写入延迟哈希缓存，而非只读未经计算的 hash 字段；无分配。

### `String.inlineBytesPtr` (`src/core/string.zig:788`)

- **签名**：`pub inline fn inlineBytesPtr(self: *const String) [*]const u8`。
- **作用**：取得 flat 内联字符区首地址。
- **实现**：将 self 转为字节指针再加 payload_offset（当前12）。
- **所有权 / 错误 / 调用**：不带长度、不查宽度；要求有效的带内联载荷 String，返回借用，不保活。

### `String.inlineBytesPtrMut` (`src/core/string.zig:792`)

- **签名**：`inline fn inlineBytesPtrMut(self: *String) [*]u8`。
- **作用**：取得 flat 内联字符区可变首地址。
- **实现**：与只读版本相同的指针偏移。
- **所有权 / 错误 / 调用**：内部构造使用；无范围/宽度校验或 hash 失效处理，不建立独占访问保证。

### `String.latin1` (`src/core/string.zig:797`)

- **签名**：`pub fn latin1(self: *const String) []const u8`。
- **作用**：借用窄存储的内容切片。
- **实现**：断言 !is_wide，以 len 个字节构造切片。
- **所有权 / 错误 / 调用**：不含终止字节；高字节是 Latin1 码元而非 UTF-8，不转换、不分配。

### `String.utf16` (`src/core/string.zig:801`)

- **签名**：`pub fn utf16(self: *const String) []const u16`。
- **作用**：借用宽存储的码元切片。
- **实现**：断言 is_wide，对齐转换字符区指针为 u16，取 len 项。
- **所有权 / 错误 / 调用**：不验证代理对、不附尾终止项；内容寿命依赖 String 可达。

### `String.latin1Mut` (`src/core/string.zig:806`)

- **签名**：`fn latin1Mut(self: *String) []u8`。
- **作用**：取得构造期间可写的 len 字节窗口。
- **实现**：直接从可变字符指针截取 len 字节。
- **所有权 / 错误 / 调用**：与只读版本不同，此函数没有 is_wide 断言；调用方必须选择正确存储。尾 NUL 位于切片之外，单独写入。

### `String.utf16Mut` (`src/core/string.zig:809`)

- **签名**：`fn utf16Mut(self: *String) []u16`。
- **作用**：取得构造期间可写的 len 个 u16 窗口。
- **实现**：对齐转换可变字符指针后取 len 项。
- **所有权 / 错误 / 调用**：没有 is_wide 断言，也不清 hash；宽度、长度、初始化时机由调用者保证。

### `String.eqlBytes` (`src/core/string.zig:814`)

- **签名**：`pub fn eqlBytes(self: *const String, bytes: []const u8) bool`。
- **作用**：按 Latin1 字节码元语义比较文本内容。
- **实现**：窄存储 std.mem.eql，宽存储逐 u16 对照每个输入字节。
- **所有权 / 错误 / 调用**：输入 bytes 不按 UTF-8 解码，宽字符>255不可能匹配一个字节；不展开 rope（self 已 flat），不分配。

### `String.eqlString` (`src/core/string.zig:821`)

- **签名**：`pub fn eqlString(self: *const String, other: *const String) bool`。
- **作用**：判断两个 flat String 的比较结果是否相等。
- **实现**：调用 compare 并判断结果为0。
- **所有权 / 错误 / 调用**：可通过相同 atom_id 快速判等；不驻留字符串、不建立根或分配。

### `String.compare` (`src/core/string.zig:825`)

- **签名**：`pub fn compare(self: *const String, other: *const String) i32`。
- **作用**：按码元字典序比较两个 flat String。
- **实现**：双方 atom_id 都非哨兵且相等则0，否则 compareResolved 根据存储宽度比较码元与长度，返回−1/0/1。
- **所有权 / 错误 / 调用**：atom 快速路径依赖回指正确且属于一致的 atom 身份空间；函数不验证 runtime、活性或名称。不是 locale 排序，也不把代理对合成标量排序。

### `ResolvedData.len` (`src/core/string.zig:836`)

- **签名**：`pub fn len(self: ResolvedData) usize`。
- **作用**：读取借用内容分支的码元数。
- **实现**：Latin1返回字节切片长度，UTF-16返回u16切片长度。
- **所有权 / 错误 / 调用**：不分配、不验证码元；两分支的字节大小不同。

### `String.resolveData` (`src/core/string.zig:844`)

- **签名**：`pub fn resolveData(self: *const String) ResolvedData`。
- **作用**：按存储宽度借用字符数据。
- **实现**：is_wide 时包装 utf16 切片，否则包装 latin1。
- **所有权 / 错误 / 调用**：不执行 rope 展开或编码转换；结果无独立存储、无根，需保持原 String 存活。

### `String.borrowLatin1` (`src/core/string.zig:849`)

- **签名**：`pub fn borrowLatin1(self: *const String) ?[]const u8`。
- **作用**：仅在实际窄存储时借用字节。
- **实现**：宽存储返回 null，否则返回 latin1。
- **所有权 / 错误 / 调用**：不要求 ASCII；宽字符串即使内容均≤255也不缩窄或分配副本。

### `String.codeUnitAt` (`src/core/string.zig:854`)

- **签名**：`pub fn codeUnitAt(self: *const String, index: usize) u16`。
- **作用**：读取一个指定位置的 UTF-16 数值码元。
- **实现**：resolveData 后索引窄或宽切片，窄字节零扩展到 u16。
- **所有权 / 错误 / 调用**：调用者保证 index<len；无可恢复范围错误，越界受切片安全检查约束。只取一码元，不组合代理对。

### `String.createSlice` (`src/core/string.zig:866`)

- **签名**：`pub fn createSlice(rt: *JSRuntime, parent: *String, start: usize, slice_len: usize) !*String`。
- **作用**：复制 parent 的指定码元范围为独立 flat String。
- **实现**：slice_len==0 直接 createAscii 空串，不读取 parent/start；非空按 parent宽度截取范围后 createLatin1 或 createUtf16。
- **所有权 / 错误 / 调用**：非空要求合法 start+slice_len，没有 RangeError 校验。宽输入片段可被 createUtf16 压窄；输出不保存 parent 边，原片段须在创建分配期间有效。

### `String.createUninitialized` (`src/core/string.zig:876`)

- **签名**：`fn createUninitialized(rt: *JSRuntime, comptime tag: StorageTag, unit_count: usize) !*String`。
- **作用**：按指定宽度分配并发布 flat String。
- **实现**：超过 max_length 返回 StringTooLong，布局溢出为 OutOfMemory；先执行分配前收集，再尝试 block cell，返回 null 才走 extent，错误直接传播。初始化长度/宽度、零 hash、no_atom_id 后发布记账。
- **所有权 / 错误 / 调用**：只初始化头，字符与窄终止字节由调用者填写；返回前已发布但没有显式根帧。block 按档位 body bytes 记账，extent 发布大小为请求减 prefix；不是 block OOM 自动改走 extent。

### `String.destroyFlat` (`src/core/string.zig:920`)

- **签名**：`fn destroyFlat(rt: *JSRuntime, self: *String) void`。
- **作用**：直接释放已知 flat String 的底层分配。
- **实现**：根据宽度/长度重算布局，block 调 memory.destroyStringCell，否则断言 standalone 后 destroyStringExtent。
- **所有权 / 错误 / 调用**：不调用 atom 解绑、GC unpublish 或用户回调；这是内部直接销毁 helper，不能描述成完整收集器销毁入口。底层负责其内存记账与原始释放，调用者负责生命周期前提。

## 比较与遍历

### `compareResolved` (`src/core/string.zig:956`)

- **签名**：`fn compareResolved(a: String.ResolvedData, b: String.ResolvedData) i32`。
- **作用**：比较任意两种 flat 内容切片。
- **实现**：按两侧 Latin1/UTF-16 组合分派同宽或混宽比较。
- **所有权 / 错误 / 调用**：返回码元字典序−1/0/1；不解码 UTF-8、不分配、不处理 locale。

### `compareSameWidth` (`src/core/string.zig:969`)

- **签名**：`fn compareSameWidth(comptime T: type, a: []const T, b: []const T) i32`。
- **作用**：比较同宽码元数组。
- **实现**：长度相同且原始字节完全相等时返回0；否则 std.mem.order(T) 后 orderToI32。
- **所有权 / 错误 / 调用**：字节比较仅作相等快判，排序按 T 单元而非内存字节序；输入借用，无分配。

### `compareLatin1Utf16` (`src/core/string.zig:974`)

- **签名**：`fn compareLatin1Utf16(a: []const u8, b: []const u16) i32`。
- **作用**：按码元比较左窄右宽内容。
- **实现**：遍历公共前缀，把左字节扩展为u16，首个差异返回−1/1，相同前缀后比较长度。
- **所有权 / 错误 / 调用**：不合并代理对，非 ASCII Latin1 仍按0..255数值比较；无分配。

### `compareUtf16Latin1` (`src/core/string.zig:986`)

- **签名**：`fn compareUtf16Latin1(a: []const u16, b: []const u8) i32`。
- **作用**：按码元比较左宽右窄内容。
- **实现**：公共前缀逐项比较，右字节扩展u16；差异返回符号，否则 compareLength。
- **所有权 / 错误 / 调用**：不缩窄宽单元、不转码，无分配。

### `compareLength` (`src/core/string.zig:998`)

- **签名**：`fn compareLength(a_len: usize, b_len: usize) i32`。
- **作用**：比较两个长度。
- **实现**：小于返回−1，大于返回1，相等返回0。
- **所有权 / 错误 / 调用**：纯数值操作，不做长度相减，避免以差值作为排序结果。

### `orderToI32` (`src/core/string.zig:1004`)

- **签名**：`fn orderToI32(order: std.math.Order) i32`。
- **作用**：把标准库 Order 映射为比较整数。
- **实现**：lt/eq/gt 分别映射−1/0/1。
- **所有权 / 错误 / 调用**：纯枚举分派，无分配或错误。

### `stringValueLen` (`src/core/string.zig:1013`)

- **签名**：`pub fn stringValueLen(value: JSValue) usize`。
- **作用**：读取 string/rope 的码元数，其他值返回0。
- **实现**：先 isString，成功后 stringValueLenUnchecked。
- **所有权 / 错误 / 调用**：symbol 虽使用 String body 仍不通过 isString；返回0不能区分非字符串与空串。无展开、无分配。

### `stringValueLenUnchecked` (`src/core/string.zig:1019`)

- **签名**：`pub inline fn stringValueLenUnchecked(value: JSValue) usize`。
- **作用**：在输入为有效 string/rope 的前提下读取长度。
- **实现**：按 tag 从 body 手柄读取 rope.len_；否则断言 string 后读 flat.len。
- **所有权 / 错误 / 调用**：不接受 symbol 作为合法前提，也不验证任意 header；不展开或分配。

### `StringValueIterator.init` (`src/core/string.zig:1035`)

- **签名**：`pub fn init(value: JSValue) StringValueIterator`。
- **作用**：初始化按内容顺序读取非空叶片的迭代器。
- **实现**：断言 value.isString，设置 current=value，其余字段默认 stack_len=0，固定节点数组未初始化。
- **所有权 / 错误 / 调用**：保存值不注册根；整个遍历及返回切片使用期间原树须可达。无展开或分配，树结构须满足固定栈容量限制。

### `StringValueIterator.next` (`src/core/string.zig:1040`)

- **签名**：`pub fn next(self: *StringValueIterator) ?String.ResolvedData`。
- **作用**：返回下一个非空内容片段。
- **实现**：current 优先处理 flat、已展开rope、buffer view，空片段跳过；普通rope压入节点并下降left，current为空时弹节点转right，栈空结束。
- **所有权 / 错误 / 调用**：固定栈60项，压栈前断言容量；不会自动再平衡或扩容。无复制/分配/根注册，结果借用叶片或buffer；畸形非字符串子值可能提前返回null。

### `stringValueCodeUnitAt` (`src/core/string.zig:1083`)

- **签名**：`pub fn stringValueCodeUnitAt(value: JSValue, index: usize) ?u16`。
- **作用**：按范围检查读取 string/rope 的指定码元。
- **实现**：非string或index≥总长度返回null，否则调用Unchecked版本。
- **所有权 / 错误 / 调用**：不展开；symbol被拒绝。返回码元，不是完整Unicode标量。

### `stringValueCodeUnitAtUnchecked` (`src/core/string.zig:1091`)

- **签名**：`pub fn stringValueCodeUnitAtUnchecked(value: JSValue, index: usize) u16`。
- **作用**：沿rope树定位一个码元。
- **实现**：flat直接读；rope已展开或buffer view直接索引；普通节点按left长度选择分支，走right时减去left长度并循环。
- **所有权 / 错误 / 调用**：输入tag和index需事先合法；无分配、无固定遍历栈、无代理对合并。树结构损坏或成环不由此检测。

### `flatStringsEq` (`src/core/string.zig:1129`)

- **签名**：`pub fn flatStringsEq(a: *const String, b: *const String) bool`。
- **作用**：比较两个flat String内容是否相等。
- **实现**：先 flatStringsEqNear，仅返回null时调用混宽helper。
- **所有权 / 错误 / 调用**：无atom-id捷径、无rope迭代或分配；近路径已保证混宽helper所需等长前提。

### `flatStringsEqNear` (`src/core/string.zig:1137`)

- **签名**：`pub inline fn flatStringsEqNear(a: *const String, b: *const String) ?bool`。
- **作用**：直接处理长度不同、指针相同或同宽flat比较。
- **实现**：先长度不同false，再同指针true，再宽度不同null；同宽逐u8或u16比较，全部相同true。
- **所有权 / 错误 / 调用**：null只表示需要混宽比较，不是“不相等”；不验证输入类型、不分配。源码循环不等于所有目标平台固定机器码保证。

### `flatStringsEqMixedWidth` (`src/core/string.zig:1161`)

- **签名**：`fn flatStringsEqMixedWidth(a: *const String, b: *const String) bool`。
- **作用**：在等长且一窄一宽前提下判断相等。
- **实现**：按is_wide选出两侧，锁步遍历Latin1/UTF16单元，差异false，否则true。
- **所有权 / 错误 / 调用**：不独立检查等长或宽度相异，调用方Near结果建立前提；无转码分配。

### `compareStringValues` (`src/core/string.zig:1170`)

- **签名**：`pub fn compareStringValues(a: JSValue, b: JSValue, eq_only: bool) ?i32`。
- **作用**：逐叶片比较flat或rope字符串内容。
- **实现**：拒绝非string为null；同值身份为0；eq_only且长度不同直接1。否则两个迭代器按双方剩余片段长度切同长块比较，公共内容相同后以总长排序。
- **所有权 / 错误 / 调用**：eq_only的1只表示不相等，不能当完整排序符号。迭代提前结束可返回null；不展开或分配，依赖原树有效和固定栈限制。

### `appendValueUtf8` (`src/core/string.zig:1223`)

- **签名**：`pub fn appendValueUtf8(rt: *JSRuntime, buffer: *std.ArrayList(u8), value: JSValue) !void`。
- **作用**：把字符串形状body的文本追加到字节列表。
- **实现**：asStringBody失败直接成功无输出；String 恒为 flat，取到 body 后直接按表示分路：ASCII Latin1直接append，其他Latin1逐码点编码，UTF16使用合并有效代理对的helper。
- **所有权 / 错误 / 调用**：也接受symbol body，不能笼统说所有非string值都忽略。rope可能先展开并GC重试后panic；转码分配错误传播且不回滚已有输出，孤立代理项保留为三字节，无额外NUL。

### `stringValueContentHash` (`src/core/string.zig:1237`)

- **签名**：`pub fn stringValueContentHash(value: JSValue) ?u32`。
- **作用**：计算string/rope内容哈希，不强制展开。
- **实现**：非string返回null；flat或已展开rope使用flat缓存，其他用迭代器按内容顺序累计Latin1/UTF16码元，最后foldHash30。
- **所有权 / 错误 / 调用**：无分配；symbol被拒绝。未展开rope没有独立hash缓存，依赖固定栈和有效树；相同内容不同分片产生同样累计结果。

### `resolvedSlice` (`src/core/string.zig:1255`)

- **签名**：`fn resolvedSlice(resolved: String.ResolvedData, start: usize, len: usize) String.ResolvedData`。
- **作用**：按码元截取借用内容片段。
- **实现**：保留Latin1/UTF16分支，对原切片先[start..]再[0..len]。
- **所有权 / 错误 / 调用**：要求范围合法，没有错误返回、编码转换或分配；不保证按Unicode标量边界切分。

### `stringValueInfo` (`src/core/string.zig:1269`)

- **签名**：`fn stringValueInfo(value: JSValue) StringValueInfo`。
- **作用**：一次分类读取字符串形状值的长度、深度和宽度。
- **实现**：rope读取节点三个字段；否则断言string或symbol，读取flat长度/宽度并设depth=0。
- **所有权 / 错误 / 调用**：输入须是有效string-like；不执行ToString或展开。符号body可在此接受，不代表所有下游string-only接口都接受symbol。

### `createRopeNode` (`src/core/string.zig:1281`)

- **签名**：`fn createRopeNode( rt: *JSRuntime, left: JSValue, right: JSValue, left_info: StringValueInfo, right_info: StringValueInfo, ) !*StringRope`。
- **作用**：用已测量信息创建普通二叉拼接节点。
- **实现**：checked add计算总长度，超max_length为StringTooLong；分配节点后存左右值，depth=max(child depth)+|1，wide为两者或。
- **所有权 / 错误 / 调用**：Overflow和分配错误传播；不重验info与实际内容一致、不再平衡，也不消费输入。默认buffer=null/extensible=false，调用者负责分配期间保活。

### `createOwnedRope` (`src/core/string.zig:1324`)

- **签名**：`fn createOwnedRope(rt: *JSRuntime, left: JSValue, right: JSValue) !JSValue`。
- **作用**：创建普通rope并返回其JSValue包装。
- **实现**：调用String.createRopeOwned（createRope 的别名）后value。
- **所有权 / 错误 / 调用**：Owned是历史命名，无RC释放或输入消费操作；错误传播。

### `addRopeRebalanceLeaf` (`src/core/string.zig:1330`)

- **签名**：`fn addRopeRebalanceLeaf(rt: *JSRuntime, buckets: *RopeBuckets, owned_leaf: JSValue) !void`。
- **作用**：将一个非空叶片合入Fibonacci桶。
- **实现**：按叶长度定位档位，把更小桶依次合成前缀，再与叶片拼接；当前位置已占用则继续合并向上进位，最终填入空桶。
- **所有权 / 错误 / 调用**：合并时先清桶再分配，失败不恢复此前桶状态；调用方中止本次重建，中间节点由GC管理。空/非string因stringValueLen为0而跳过，不能理解成释放输入。

### `collectRopeRebalanceLeaves` (`src/core/string.zig:1373`)

- **签名**：`fn collectRopeRebalanceLeaves(rt: *JSRuntime, buckets: *RopeBuckets, value: JSValue) !void`。
- **作用**：按从左到右顺序收集待重建叶片。
- **实现**：非rope直接入桶；已展开rope以flat值入桶；buffer view整节点作为不可拆叶片；普通rope先递归left再right。
- **所有权 / 错误 / 调用**：递归遍历，无独立深度或环检查；dependent view只表示其len前缀，不把buffer容量尾部加入内容。分配错误立即传播，原树不改写。

### `rebalanceRope` (`src/core/string.zig:1393`)

- **签名**：`fn rebalanceRope(rt: *JSRuntime, rope: JSValue) !JSValue`。
- **作用**：用Fibonacci桶重建保持内容顺序的树。
- **实现**：先清空桶并收集叶片，再从低桶向高桶遍历，将较高桶作为当前result的左前缀合并；没有非空内容时创建窄空串。
- **所有权 / 错误 / 调用**：可能复用原叶片，非保证复制全部内容；无本地显式根帧/失败销毁表，中间值须遵守GC保护机制，失败不返回部分结果。不改变原树字段。

### `writeTailUnits` (`src/core/string.zig:1429`)

- **签名**：`fn writeTailUnits(buf: *StringBuffer, offset: u32, data: String.ResolvedData) void`。
- **作用**：在buffer指定码元偏移写入已解析内容。
- **实现**：runtime_safety开启时断言kind、已记账与范围；宽目标接受Latin1逐项扩展或UTF16 memcpy，窄目标只允许Latin1。
- **所有权 / 错误 / 调用**：要求容量足够、源目标不违反memcpy重叠前提且调用者持有合法追加权；不更新长度/权利、不写NUL、不分配，宽源写窄目标为unreachable。

### `tailBufferSeedCapacityFor` (`src/core/string.zig:1458`)

- **签名**：`fn tailBufferSeedCapacityFor(total: usize) usize`。
- **作用**：为首次tail buffer计算容量。
- **实现**：total+|total/2饱和相加，至少64，再截到max_length。
- **所有权 / 错误 / 调用**：约1.5倍向下取整，不分配、不验证total本身；total超过上限时结果可能小于total，外层须先验证。

### `tailBufferCapacityFor` (`src/core/string.zig:1464`)

- **签名**：`fn tailBufferCapacityFor(total: usize) usize`。
- **作用**：为新增长buffer计算容量。
- **实现**：total*|2饱和乘法，至少64，至多max_length。
- **所有权 / 错误 / 调用**：根据所需新总长翻倍，不是读取旧容量翻倍；外层负责total合法性，没有分配。

### `createTailBufferRope` (`src/core/string.zig:1473`)

- **签名**：`pub fn createTailBufferRope(rt: *JSRuntime, a: *String, b: *String) !*StringRope`。
- **作用**：把两个flat内容复制到新的可扩展buffer视图。
- **实现**：checked add及max_length检查后按两侧宽度或分配seed buffer，写a和b，再分配节点；left/right为undefined，depth=1，buffer指向新存储，extensible=true。
- **所有权 / 错误 / 调用**：不消费a/b，无显式根帧，代码依赖分配期间原生局部值的GC保护。后续节点分配失败没有本地销毁buffer；已发布存储由GC回收。初始内容始终复制一次。

### `appendTailBufferRope` (`src/core/string.zig:1505`)

- **签名**：`pub fn appendTailBufferRope(rt: *JSRuntime, view: *StringRope, b: *String) !*StringRope`。
- **作用**：向dependent view追加flat内容并返回新节点。
- **实现**：要求view.buffer非空，检查总长。若有追加权、宽度不变且容量足够，先分配节点，再写旧len之后的字节并把追加权转给新节点；否则新建增长buffer，复制旧前缀和b后建节点。
- **所有权 / 错误 / 调用**：成功原地分支只把旧view.extensible改false，旧长度不变；复制分支保持旧view全部状态。可返回错误的分配发生在原地写入前；写入成本随b长度变化，并非任意长追加都O(1)。

### `allocRopeNode` (`src/core/string.zig:1554`)

- **签名**：`fn allocRopeNode(rt: *JSRuntime) !*StringRope`。
- **作用**：分配并发布rope的固定大小GC存储。
- **实现**：编译期断言含prefix的节点可进入block cell；先分配前收集，createStringCell(rope kind)，按body档位记账发布。
- **所有权 / 错误 / 调用**：不初始化节点字段，调用者须返回后立即填好且在下一次可收集操作前完成；没有extent回退。返回指针不自动成为持久根，错误传播。

### `copyRopeContent` (`src/core/string.zig:1570`)

- **签名**：`fn copyRopeContent(comptime T: type, root: *const StringRope, out: []T) void`。
- **作用**：把整棵rope内容复制进预先分配的目标。
- **实现**：断言已展开或depth≤60，从offset0递归copyRopeNodeContent，末尾断言写入长度等于out.len。
- **所有权 / 错误 / 调用**：没有分配/再平衡；要求目标总长、宽度及树结构正确。深度字段断言不等于检查真实树无环。

### `copyRopeNodeContent` (`src/core/string.zig:1577`)

- **签名**：`fn copyRopeNodeContent(comptime T: type, node: *const StringRope, out: []T, offset: *usize) void`。
- **作用**：复制一个rope节点并推进输出偏移。
- **实现**：已展开flat或buffer view直接copyResolvedUnits；普通节点先left后right递归。
- **所有权 / 错误 / 调用**：buffer只复制view前缀；目标容量/类型由调用方保证，不修改原节点。

### `copyRopeValueContent` (`src/core/string.zig:1590`)

- **签名**：`fn copyRopeValueContent(comptime T: type, value: JSValue, out: []T, offset: *usize) void`。
- **作用**：将rope或flat形状值复制到目标。
- **实现**：rope递归；否则asStringBodyRaw成功则复制，其他值不写入。
- **所有权 / 错误 / 调用**：raw接受symbol体；无效非字符串不是返回TypeError，而是跳过，整树调用末尾可能因长度不符触发断言。

### `copyResolvedUnits` (`src/core/string.zig:1600`)

- **签名**：`fn copyResolvedUnits(comptime T: type, out: []T, resolved: String.ResolvedData) usize`。
- **作用**：复制同宽单元或把Latin1扩为宽单元。
- **实现**：Latin1在T=u8时memcpy，否则逐项赋值；UTF16仅T=u16允许memcpy，返回复制的码元数。
- **所有权 / 错误 / 调用**：要求out足够长、类型匹配和合法内存别名；UTF16写窄目标unreachable，不缩窄、不加NUL或分配。

### `metaIsRope` (`src/core/string.zig:1628`)

- **签名**：`pub inline fn metaIsRope(meta: *const gc.Metadata) bool`。
- **作用**：按GC kind判断metadata是否属于rope。
- **实现**：比较flags.kind==rope。
- **所有权 / 错误 / 调用**：不查看mark位，也不验证指针有效性。

### `accountedAllocationSizeFromHeader` (`src/core/string.zig:1635`)

- **签名**：`pub fn accountedAllocationSizeFromHeader(header: *const gc.GCObjectHeader) usize`。
- **作用**：查询flat或rope的GC body记账大小。
- **实现**：体前读取metadata，rope用固定总尺寸，其他按flat长宽计算布局；block按档位返回body bytes，extent返回总尺寸减prefix。
- **所有权 / 错误 / 调用**：不是所有prefix carrier的通用查询：非rope会被当成String，buffer需使用专门接口。无分配，依赖合法头和尺寸。

### `destroyCellFromHeader` (`src/core/string.zig:1660`)

- **签名**：`pub fn destroyCellFromHeader(rt: *JSRuntime, header: *gc.GCObjectHeader) void`。
- **作用**：销毁已判死的prefix carrier block cell。
- **实现**：断言block；buffer委托专门销毁，property/array/payload委托destroyStorageCell；rope撤销发布后释放；其他按flat读取，动态atom先onSymbolBodyDead，再撤销发布和释放。
- **所有权 / 错误 / 调用**：不递归销毁rope子边、不调用JSValue.free；调用者保证支持的kind与死亡状态，未知kind会落入flat解释，并非安全类型校验。

### `destroyAllStringCarriersForDeinit` (`src/core/string.zig:1707`)

- **签名**：`pub fn destroyAllStringCarriersForDeinit(rt: *JSRuntime) void`。
- **作用**：在runtime teardown中销毁剩余prefix carrier。
- **实现**：page_allocator列表先收集block指针后统一释放；预留/追加失败时释放已收集项和首个未容纳项，重新遍历更小集合。完成后以mark_epoch+%2清扫extent。
- **所有权 / 错误 / 调用**：范围还含property/array/payload，不只字符串；不在此验证外部持有者均已结束。临时列表defer释放，零额外容量时仍能逐项推进。

### `sweepExtents` (`src/core/string.zig:1747`)

- **签名**：`pub fn sweepExtents(rt: *JSRuntime) usize`。
- **作用**：按当前epoch清扫未标记extent。
- **实现**：调用block_heap.sweepExtents并传runtime及destroyDeadStringExtent回调。
- **所有权 / 错误 / 调用**：返回底层清扫数量，不只处理String；回调支持其他prefix carrier，调用方负责完成标记和清扫时序。

### `sweepYoungExtents` (`src/core/string.zig:1758`)

- **签名**：`pub fn sweepYoungExtents(rt: *JSRuntime) usize`。
- **作用**：清扫young extent列表中本轮未标记项。
- **实现**：调用heap.sweepYoungExtents，传当前mark_epoch和相同销毁回调。
- **所有权 / 错误 / 调用**：只限定young集合，不自己追踪roots或remembered set；有效性依赖调用方此前完成minor标记，返回底层数量。

### `destroyDeadStringExtent` (`src/core/string.zig:1766`)

- **签名**：`fn destroyDeadStringExtent(ctx: *anyopaque, base: usize, user_bytes: usize, needs_finalizer: bool) void`。
- **作用**：处理extent表判死后的释放回调。
- **实现**：needs_finalizer=false直接unpublish并按user_bytes释放；为true时断言standalone，纯存储kind直接释放，flat string则核对尺寸并对动态atom执行解绑回调再释放。
- **所有权 / 错误 / 调用**：base为prefix起点，user_bytes含prefix；快路径信任finalizer标志而不读String字段。不会销毁载荷持有的业务资源，所有者层应已处理；rope正常不进入extent。

### `traceRopeEdges` (`src/core/string.zig:1819`)

- **签名**：`pub fn traceRopeEdges(rt: *JSRuntime, visitor: anytype, header: *gc.GCObjectHeader) !void`。
- **作用**：报告rope的buffer边及两个值槽。
- **实现**：断言rope kind，buffer存在则断言string_buffer并调用storageCell shim；之后无条件访问left/right槽，rt参数未使用。
- **所有权 / 错误 / 调用**：dependent view的左右值是undefined，仍会访问；错误立即传播。此函数只报告边，不自行保证visitor标记了它们。

### `callVisitStorageCell` (`src/core/string.zig:1838`)

- **签名**：`inline fn callVisitStorageCell(vis: anytype, header: *gc.GCObjectHeader) !void`。
- **作用**：按访问器能力报告存储边。
- **实现**：编译期去掉一层指针类型，缺storageCell声明则返回；存在时按返回是否error union决定try。
- **所有权 / 错误 / 调用**：缺方法不会回退到visitValue，边被该visitor忽略；无分配，回调错误传播。

### `callVisitValue` (`src/core/string.zig:1852`)

- **签名**：`inline fn callVisitValue(vis: anytype, slot: *JSValue) !void`。
- **作用**：调用访问器的值槽接口。
- **实现**：解析visitValue返回类型，error union用try，否则直接调用。
- **所有权 / 错误 / 调用**：这里没有hasDecl保护，访问器必须提供visitValue；传可变槽地址，具体标记/更新行为由访问器决定。

### `inlineAllocationLayout` (`src/core/string.zig:1863`)

- **签名**：`fn inlineAllocationLayout(comptime tag: String.StorageTag, unit_count: usize) ?InlineAllocationLayout`。
- **作用**：计算flat String请求布局。
- **实现**：窄存储额外一单元NUL，宽存储不加；checked乘法及加法累计payload_offset和prefix，返回total_size与Metadata对齐要求。
- **所有权 / 错误 / 调用**：溢出返回null；不检查max_length，也不进行block size-class取整。当前布局为8字节prefix+12字节头+payload。

### `finalLatin1AllocationLen` (`src/core/string.zig:1888`)

- **签名**：`fn finalLatin1AllocationLen(unit_count: usize) ?usize`。
- **作用**：给窄内容预留一个终止字节。
- **实现**：checked add(unit_count,1)，溢出null。
- **所有权 / 错误 / 调用**：只计算容量，不写字节、不改变逻辑字符串长度。

### `writeLatin1Terminator` (`src/core/string.zig:1892`)

- **签名**：`fn writeLatin1Terminator(bytes: []u8) void`。
- **作用**：在内容切片之后写一个NUL。
- **实现**：直接bytes.ptr[bytes.len]=0。
- **所有权 / 错误 / 调用**：要求底层分配比传入切片至少多1字节；不是任意合法slice都能调用，空内容同样需要额外存储。

### `foldHash30` (`src/core/string.zig:1904`)

- **签名**：`pub fn foldHash30(full: u32) u30`。
- **作用**：把32位累计哈希压入30位非零缓存表示。
- **实现**：截取低30位，结果0映射为1。
- **所有权 / 错误 / 调用**：不是混合高位的散列折叠；存在碰撞，所有需与contentHash匹配的调用点必须采用相同规则。

### `hashLatin1` (`src/core/string.zig:1909`)

- **签名**：`pub fn hashLatin1(bytes: []const u8, seed: u32) u32`。
- **作用**：按Latin1码元累积32位哈希。
- **实现**：从seed开始逐字节h=h*%263+%byte。
- **所有权 / 错误 / 调用**：不解码UTF8、不折入30位；可将前一片段结果作为下一片段seed，无分配。

### `hashUtf16` (`src/core/string.zig:1915`)

- **签名**：`pub fn hashUtf16(units: []const u16, seed: u32) u32`。
- **作用**：按UTF16码元累积32位哈希。
- **实现**：从seed开始逐u16做相同环绕乘加。
- **所有权 / 错误 / 调用**：不按主机字节序逐字节散列，也不合并代理对；与相同0..255码元的Latin1内容得到同一累计值。

### `eqlUtf16Latin1` (`src/core/string.zig:1921`)

- **签名**：`fn eqlUtf16Latin1(units: []const u16, bytes: []const u8) bool`。
- **作用**：比较宽码元序列与Latin1字节序列。
- **实现**：先长度相同，再逐项要求u16==u8。
- **所有权 / 错误 / 调用**：输入字节不是UTF8文本，宽码元大于255不会匹配；无分配。

### `scanUtf8` (`src/core/string.zig:1934`)

- **签名**：`fn scanUtf8(bytes: []const u8) StringError!Utf8Plan`。
- **作用**：验证内部字节编码并测量目标码元存储。
- **实现**：循环decodeOne，≤255计一个窄单元，256..65535计一个并置wide，其余计两个并置wide。
- **所有权 / 错误 / 调用**：接受三字节代理项；不在此限制max_length，错误为InvalidUtf8，空输入units0/widefalse；Utf8Plan保存units和wide。

### `decodeUtf8` (`src/core/string.zig:1954`)

- **签名**：`fn decodeUtf8(bytes: []const u8, latin1: ?[]u8, utf16: ?[]u16) StringError!usize`。
- **作用**：将已测量的字节文本写入目标码元切片。
- **实现**：逐decodeOne；latin1非空时优先写它，码点>255返回InvalidUtf8；否则utf16非空则BMP单元直写、补充码点拆代理对。
- **所有权 / 错误 / 调用**：调用者保证目标容量；两目标都null时仍验证输入但返回0，两个都非空时只用latin1。失败可已写部分内容，无回滚，不加尾NUL。

### `decodeOne` (`src/core/string.zig:1985`)

- **签名**：`fn decodeOne(bytes: []const u8, index: usize) StringError!Decoded`。
- **作用**：从有效起始下标解码一个1..4字节序列。
- **实现**：ASCII直接返回；其他检查剩余长度、continuation和最短编码，4字节额外要求≤0x10ffff；三字节允许surrogate。返回u21 codepoint和下一下标。
- **所有权 / 错误 / 调用**：index必须<bytes.len，本函数首字节读取前不返回范围错误；坏序列为InvalidUtf8。保留内部WTF8/CESU8表示，不能宣称严格Unicode标量验证。

## `src/core/string_view.zig`

`JSString(Value)` 保存源值副本和借用 flat 指针，不自动注册 GC 根；对 JSValue 实例，来源也可为 symbol body，rope 会先展开。`Units` 是 Latin1/UTF-16 切片联合体。`Utf8 { bytes, owned=null, allocator=null }` 只对 Latin1 ASCII 借用；其他情况转码并记录释放责任，使用后 deinit。默认模式合并有效代理对但保留孤立代理项，CESU-8 模式逐单元编码；两者都不是附带 NUL 的 C 字符串接口。

### `JSString` (`src/core/string_view.zig:14`)

- **签名**：`pub fn JSString(comptime Value: type) type`。
- **作用**：生成包含源值与 flat 字符串指针的视图类型。
- **实现**：结构字段为 js_value:Value 和 ptr:*const String；Units 联合体包含 Latin1/UTF-16 借用切片，Utf8 包含 bytes、可选 owned 缓冲及 allocator。
- **所有权 / 错误 / 调用**：实例保存值副本不等于注册 GC 根；调用者需保持源值可达。Utf8 的拥有存储不能通过复制结构来复制释放责任。泛型避免 Value 类型导入环。

### `JSString.Utf8.init` (`src/core/string_view.zig:31`)

- **签名**：`pub fn init(allocator: std.mem.Allocator, string: Self) !Utf8`。
- **作用**：创建默认合并有效代理对的字节投影。
- **实现**：转发 initCesu8(allocator,string,false)。
- **所有权 / 错误 / 调用**：可能借用或分配。孤立代理项仍编码为三字节序列，不能把结果一概保证为严格 Unicode UTF-8；分配错误传播。

### `JSString.Utf8.initCesu8` (`src/core/string_view.zig:39`)

- **签名**：`pub fn initCesu8(allocator: std.mem.Allocator, string: Self, cesu8: bool) !Utf8`。
- **作用**：按指定代理项策略创建借用或拥有的字节投影。
- **实现**：resolveData 为 Latin1 且全部 ASCII 时直接借用；其他 Latin1 或任意 UTF-16 存储调用 toOwnedUtf8Cesu8，记录 owned 和 allocator。
- **所有权 / 错误 / 调用**：cesu8=true 时逐 UTF-16 单元编码，代理对共六字节；false 时有效对合为四字节，孤立代理项仍保留。UTF-16 即使只含 ASCII 也走分配路径；借用结果要求源存活。

### `JSString.Utf8.fromValue` (`src/core/string_view.zig:63`)

- **签名**：`pub fn fromValue(allocator: std.mem.Allocator, js_value: Value) !Utf8`。
- **作用**：从值取得字符串视图后创建默认字节投影。
- **实现**：Self.fromValue 返回 null 则 TypeError，否则 init。
- **所有权 / 错误 / 调用**：JSValue 实例也接受 symbol body，不执行语言级 ToString。rope 在 fromValue 内可能分配展开、触发 GC，最终失败可 panic；后续转码的分配错误才沿本 error union 返回。

### `JSString.Utf8.fromValueCesu8` (`src/core/string_view.zig:68`)

- **签名**：`pub fn fromValueCesu8(allocator: std.mem.Allocator, js_value: Value, cesu8: bool) !Utf8`。
- **作用**：从值创建具有指定代理项编码方式的投影。
- **实现**：Self.fromValue 失败为 TypeError，否则 initCesu8。
- **所有权 / 错误 / 调用**：与默认入口相同的接受范围及 rope 展开边界；cesu8 仅改变代理对处理，不添加 NUL 终止符或建立 GC 根。

### `JSString.Utf8.slice` (`src/core/string_view.zig:73`)

- **签名**：`pub fn slice(self: Utf8) []const u8`。
- **作用**：读取投影当前的 bytes 切片。
- **实现**：直接返回字段，不复制字节。
- **所有权 / 错误 / 调用**：借用结果依赖源字符串寿命；拥有结果依赖该 Utf8 尚未 deinit。接口不保证尾 NUL，也不检查存储是否仍有效。

### `JSString.Utf8.isBorrowed` (`src/core/string_view.zig:77`)

- **签名**：`pub fn isBorrowed(self: Utf8) bool`。
- **作用**：判断投影是否没有 owned 缓冲。
- **实现**：仅比较 owned==null。
- **所有权 / 错误 / 调用**：不是完整的零分配历史判断：此前 rope 可能已经展开；deinit 后空对象也返回 true。

### `JSString.Utf8.deinit` (`src/core/string_view.zig:81`)

- **签名**：`pub fn deinit(self: *Utf8) void`。
- **作用**：释放投影拥有的转码缓冲并清空视图。
- **实现**：owned=null 时仅清 bytes；否则取 allocator，先清 bytes/owned/allocator，再 allocator.free。
- **所有权 / 错误 / 调用**：正常构造实例可对同一对象重复调用；复制含 owned 的结构后分别 deinit 会重复释放。借用路径不释放源字符串，也不撤销 GC 根。

### `JSString.fromValue` (`src/core/string_view.zig:94`)

- **签名**：`pub fn fromValue(js_value: Value) ?Self`。
- **作用**：取得值的 flat 字符串数据视图。
- **实现**：调用 js_value.asStringBody，成功后保存原 js_value 和返回指针。
- **所有权 / 错误 / 调用**：JSValue 的 string/symbol 直接提供 body，rope 通过 flattenInfallible 物化；因此此 optional 接口不保证无分配或只接受 string tag。保存值不会自动 root，展开失败可能 GC 重试后 panic。

### `JSString.value` (`src/core/string_view.zig:102`)

- **签名**：`pub fn value(self: Self) Value`。
- **作用**：返回构造视图时保存的源值副本。
- **实现**：直接返回 js_value。
- **所有权 / 错误 / 调用**：rope 来源仍返回原 rope 值，symbol 来源仍返回 symbol；不是由 ptr 重新构造 flat string 值，无额外所有权或 root。

### `JSString.units` (`src/core/string_view.zig:108`)

- **签名**：`pub fn units(self: Self) Units`。
- **作用**：借用 flat 字符串的原始码元切片。
- **实现**：resolveData 为 Latin1/UTF-16 时分别包装对应 Units 分支；两条分支都有结果，所以返回类型不再是 optional（调用点不需要 `.?`）。
- **所有权 / 错误 / 调用**：UTF-16 长度是码元数，不是 Unicode 标量数；Latin1 高字节不等于 UTF-8。无转码、无复制，源必须保持存活。

### `JSString.toUtf8` (`src/core/string_view.zig:115`)

- **签名**：`pub fn toUtf8(self: Self, allocator: std.mem.Allocator) !Utf8`。
- **作用**：从已有视图构造默认字节投影。
- **实现**：调用 Utf8.init。
- **所有权 / 错误 / 调用**：Latin1 ASCII 可借用，其他情况拥有转码存储；调用方使用 Utf8.deinit，不能把所有结果都交给 allocator.free。

### `JSString.toOwnedUtf8` (`src/core/string_view.zig:119`)

- **签名**：`pub fn toOwnedUtf8(self: Self, allocator: std.mem.Allocator) ![]u8`。
- **作用**：取得调用方负责释放的默认编码字节缓冲。
- **实现**：调用 toOwnedUtf8Cesu8(self,allocator,false)。
- **所有权 / 错误 / 调用**：即使 ASCII 也走 allocator.alloc（空串请求零长度）；不用借用优化。结果不含额外尾 NUL，孤立代理项保留，调用方使用同一 allocator.free。

### `JSString.toOwnedUtf8Cesu8` (`src/core/string_view.zig:123`)

- **签名**：`pub fn toOwnedUtf8Cesu8(self: Self, allocator: std.mem.Allocator, cesu8: bool) ![]u8`。
- **作用**：按精确长度分配并写出 Latin1/UTF-16 的字节编码。
- **实现**：先用对应长度 helper 计算 len，再 alloc(u8,len)。Latin1 逐字节作为码点编码；UTF-16 在非 cesu8 模式合并相邻高低代理项，其他逐单元写出，最后断言 offset==out.len。
- **所有权 / 错误 / 调用**：不替换或拒绝孤立代理项，无终止符；非 ASCII Latin1 扩为两字节。分配错误传播，长度累计使用普通 usize 算术而非显式 Overflow 错误；输出由调用者拥有。

### `utf8LenLatin1` (`src/core/string_view.zig:155`)

- **签名**：`fn utf8LenLatin1(bytes: []const u8) usize`。
- **作用**：计算 Latin1 码元转码的字节数。
- **实现**：每字节≤0x7f 加1，否则加2。
- **所有权 / 错误 / 调用**：按码点解释输入，不验证其是否已有 UTF-8；无分配，长度累计没有错误返回。

### `utf8LenUtf16` (`src/core/string_view.zig:161`)

- **签名**：`fn utf8LenUtf16(units: []const u16, cesu8: bool) usize`。
- **作用**：计算指定代理项策略下的编码长度。
- **实现**：非 cesu8 模式遇高代理项紧接低代理项时计4并跨两项，否则按单码元长度累计。
- **所有权 / 错误 / 调用**：cesu8 模式有效对计6；孤立代理项计3。没有编码有效性错误或分配，须与写出策略一致。

### `utf8LenCodeUnit` (`src/core/string_view.zig:177`)

- **签名**：`fn utf8LenCodeUnit(unit: u16) usize`。
- **作用**：计算一个 u16 单元单独编码的长度。
- **实现**：≤0x7f 为1，≤0x7ff 为2，其余为3。
- **所有权 / 错误 / 调用**：代理项也返回3，不判定 Unicode 标量合法性。

### `writeUtf8CodeUnit` (`src/core/string_view.zig:183`)

- **签名**：`fn writeUtf8CodeUnit(out: []u8, unit: u16) usize`。
- **作用**：将一个 u16 单元直接编码到输出。
- **实现**：把 unit 传给 writeUtf8CodePoint。
- **所有权 / 错误 / 调用**：不与邻项合并，也不替换代理项；调用方必须留足1..3字节，返回实际写入长度。

### `writeUtf8CodePoint` (`src/core/string_view.zig:187`)

- **签名**：`fn writeUtf8CodePoint(out: []u8, code_point: u32) usize`。
- **作用**：按数值范围写出1至4字节编码。
- **实现**：使用0x7f、0x7ff、0xffff三个界限选分支，以移位和掩码生成字节。
- **所有权 / 错误 / 调用**：不检查输出容量、代理项或0x10ffff上限，不是通用验证编码器；当前调用点传 u16 单元或合法代理对组合。前提不满足可能触发越界/转换安全检查。

## `src/core/bytes_view.zig`

`JSBytes(Value)` 是 ArrayBuffer/DataView/TypedArray 的借用字节快照，不保存源值或注册根，也不在 slice/sliceMut 时重新检查状态。`Store { bytes, deinit_fn=null, context=null, is_shared=false }` 管理外部字节的释放回调；OwnedOptions/SharedOptions 均要求 deinit，context 默认 null。`DeinitFn` 是普通 Zig 函数指针，未显式声明 C 调用约定；共享标志本身不提供原子读写或复制所有权。转交成功后原 Store 清空；共享路径在 createExternal 成功后立即清空，失败时由 store 单独释放一次，见 toSharedArrayBuffer。

`Error = TypeError|Detached|OutOfBounds|InvalidStore|ReadOnly`。

清单里多处 `deinit` 是测试匿名结构体的释放钩子，不是 `JSBytes` 方法。

### `JSBytes` (`src/core/bytes_view.zig:13`)

- **签名**：`pub fn JSBytes(comptime Value: type) type`。
- **作用**：生成借用二进制存储的视图类型。
- **实现**：字段是只读 ptr、可选 mut_ptr（默认 null）、len 和 shared（默认 false）；Error 包含 TypeError/Detached/OutOfBounds/InvalidStore/ReadOnly，内嵌外部 Store。
- **所有权 / 错误 / 调用**：不保存源 JSValue、不注册根、不复制字节；这是创建时的指针/长度/权限快照。源被回收、detach、resize 或权限变化后不能依赖旧视图继续有效。

### `JSBytes.fromMutable` (`src/core/bytes_view.zig:30`)

- **签名**：`pub fn fromMutable(bytes: []u8) Self`。
- **作用**：借用宿主可变字节切片。
- **实现**：ptr 和 mut_ptr 指向同一存储，复制 len，shared 默认 false。
- **所有权 / 错误 / 调用**：不拥有、复制或同步存储；调用者负责切片寿命和并发访问。

### `JSBytes.fromConst` (`src/core/bytes_view.zig:38`)

- **签名**：`pub fn fromConst(bytes: []const u8) Self`。
- **作用**：借用宿主只读切片。
- **实现**：设置 ptr/len，mut_ptr=null、shared=false。
- **所有权 / 错误 / 调用**：只限制本视图的可写接口，不使底层字节全局不可变；sliceMut 返回 ReadOnly。

### `JSBytes.fromValue` (`src/core/bytes_view.zig:45`)

- **签名**：`pub fn fromValue(value: Value) Error!Self`。
- **作用**：把支持的 JS 对象转换为借用字节视图。
- **实现**：objectFromValue 校验 tag、非空 header 和 object kind，失败 TypeError，成功调用 fromObject。
- **所有权 / 错误 / 调用**：会拒绝共享 object tag 的 VarRef；后续 Detached/OutOfBounds 等错误传播，无分配或源值保活。

### `JSBytes.fromObject` (`src/core/bytes_view.zig:50`)

- **签名**：`pub fn fromObject(object: anytype) Error!Self`。
- **作用**：根据对象类别与 view payload 选择投影方式。
- **实现**：依次判断 AB/SAB、DataView、TypedArray 形状，均不符合则 TypeError。
- **所有权 / 错误 / 调用**：要求有效 Object；TypedArray 判断使用有 buffer 且 element_size 非零，不是逐个 class ID 白名单。无 proxy 解包或用户代码调用。

### `JSBytes.slice` (`src/core/bytes_view.zig:57`)

- **签名**：`pub fn slice(self: Self) []const u8`。
- **作用**：从快照指针和长度构造只读切片。
- **实现**：返回 ptr[0..len]。
- **所有权 / 错误 / 调用**：不重新读取 buffer、不检查 detach/resize/生命周期，旧视图失效后本接口不会报告错误。

### `JSBytes.sliceMut` (`src/core/bytes_view.zig:61`)

- **签名**：`pub fn sliceMut(self: Self) Error![]u8`。
- **作用**：取得快照中的可写字节切片。
- **实现**：mut_ptr=null 则 ReadOnly，否则返回 ptr[0..len]。
- **所有权 / 错误 / 调用**：只检查创建时保存的 mut_ptr；不会重新检查当前 immutable、detach 或越界状态，也不提供共享存储原子操作。

### `JSBytes.isShared` (`src/core/bytes_view.zig:66`)

- **签名**：`pub fn isShared(self: Self) bool`。
- **作用**：读取视图中的 shared 标志。
- **实现**：直接返回字段。
- **所有权 / 错误 / 调用**：不检测实际内存共享或线程安全；fromMutable/fromConst 默认 false，JS 对象投影由 backing buffer class 判定。

### `JSBytes.Store.owned` (`src/core/bytes_view.zig:88`)

- **签名**：`pub fn owned(bytes: []u8, options: OwnedOptions) Store`。
- **作用**：把可变 bytes 与释放回调包装为非共享 Store。
- **实现**：记录 bytes、必填 options.deinit 和可选 context，is_shared=false。
- **所有权 / 错误 / 调用**：无分配、无字节复制，调用者交出释放责任的管理；结构按值复制不会产生独立所有权，不能让副本分别 release。

### `JSBytes.Store.shared` (`src/core/bytes_view.zig:97`)

- **签名**：`pub fn shared(bytes: []u8, options: SharedOptions) Store`。
- **作用**：把 bytes 与释放回调包装为待转交的共享 Store。
- **实现**：记录与 owned 相同的字段，但 is_shared=true。
- **所有权 / 错误 / 调用**：此构造本身没有引用计数或并发同步；真正 SharedBufferStore 在转交时创建。回调为必填参数，不能把 shared 理解成免释放。

### `JSBytes.Store.view` (`src/core/bytes_view.zig:106`)

- **签名**：`pub fn view(self: Store) Self`。
- **作用**：借用 Store 当前 bytes 为可变 JSBytes。
- **实现**：ptr/mut_ptr 都取 bytes.ptr，复制长度和 is_shared。
- **所有权 / 错误 / 调用**：不检查 deinit_fn、不转交或增加所有权；Store.release 或后续底层释放后旧 view 失效。已 disarm 的 Store 产生空视图。

### `JSBytes.Store.toArrayBuffer` (`src/core/bytes_view.zig:115`)

- **签名**：`pub fn toArrayBuffer(self: *Store, ctx: anytype) !Value`。
- **作用**：把有效外部 Store 零拷贝交给 AB 或 SAB。
- **实现**：无 deinit_fn 返回 InvalidStore；shared 委托 toSharedArrayBuffer。普通路径创建 null prototype 的 AB 对象，安装 external storage，成功后 disarm 并返回对象值；安装失败销毁临时对象。
- **所有权 / 错误 / 调用**：普通路径 reportExternalAlloc 成功后才安装存储，成功转交后的释放由对象负责。共享失败路径有不同边界，见下函数；返回值需由调用者纳入 GC 活值管理。

### `JSBytes.Store.toSharedArrayBuffer` (`src/core/bytes_view.zig:128`)

- **签名**：`fn toSharedArrayBuffer(self: *Store, rt: anytype, deinit_fn: DeinitFn) !Value`。
- **作用**：创建共享后备包装并安装到新的 SAB。
- **实现**：createExternal 把 bytes/回调放入 SharedBufferStore，紧接着 self.disarm（所有权已移交 store），再注册 errdefer store.release 并创建 null prototype SAB；安装共享存储不额外 retain。
- **所有权 / 错误 / 调用**：若 createExternal 自身失败，原 Store 仍保有 bytes/回调，由调用方释放；若它成功而后续步骤失败，所有权已在 disarm 时移交 store，errdefer 的 release 恰好调用一次外部 deinit，调用方手里的 Store 已被清空，再 release 是无操作。宿主字节因此在任一路径上都只释放一次。

### `JSBytes.Store.release` (`src/core/bytes_view.zig:147`)

- **签名**：`pub fn release(self: *Store) void`。
- **作用**：调用仍登记的外部释放钩子后清空 Store。
- **实现**：deinit_fn 存在则以 context/bytes 调用，再 disarm；没有钩子也执行 disarm。
- **所有权 / 错误 / 调用**：同一正常实例在回调返回后重复调用不再释放；回调执行前尚未清空，不能据此保证重入安全。按值复制或共享转交失败后的旧副本也不受此幂等性保证覆盖。

### `JSBytes.Store.disarm` (`src/core/bytes_view.zig:152`)

- **签名**：`fn disarm(self: *Store) void`。
- **作用**：移除 Store 中的字节和释放责任记录。
- **实现**：用 bytes=&.{} 的默认结构整体覆盖，deinit_fn/context 归 null，is_shared=false。
- **所有权 / 错误 / 调用**：不调用回调、不释放字节；仅改变这个实例，既有结构副本与视图不会同步清空。

### `JSBytes.fromArrayBufferObject` (`src/core/bytes_view.zig:157`)

- **签名**：`fn fromArrayBufferObject(object: anytype) Error!Self`。
- **作用**：借用 AB/SAB 当前完整可见字节范围。
- **实现**：先拒绝 detached；读取 byteStorage，immutable 时 mut_ptr=null，否则可写，shared 根据 SAB class 设置。
- **所有权 / 错误 / 调用**：不分配、不复制；私有 helper 依赖调用方已筛选 buffer 类别。返回值不随 buffer 后续状态更新。

### `JSBytes.fromTypedArrayObject` (`src/core/bytes_view.zig:169`)

- **签名**：`fn fromTypedArrayObject(object: anytype) Error!Self`。
- **作用**：借用 TypedArray 当前可访问的完整元素字节范围。
- **实现**：取得有效 AB/SAB backing，先拒绝 detached 和 offset>buffer长度；固定长度用 checked mul(length,element_size)，溢出或超出剩余范围为 OutOfBounds。追踪长度把剩余字节向下截为 element_size 的倍数。
- **所有权 / 错误 / 调用**：仅追踪长度分支显式拒绝 element_size=0 为 InvalidStore；正常外层已要求非零。immutable/shared 从 buffer 取得，不检查 offset 对齐或元素 kind/宽度一致性，无复制。

### `JSBytes.fromDataViewObject` (`src/core/bytes_view.zig:202`)

- **签名**：`fn fromDataViewObject(object: anytype) Error!Self`。
- **作用**：借用 DataView 当前可访问的字节范围。
- **实现**：backing 缺失或不是 AB/SAB 为 TypeError；detached 为 Detached，offset越界为 OutOfBounds。kind==1 使用全部剩余字节，否则必须有固定长度；长度超剩余范围也为 OutOfBounds。
- **所有权 / 错误 / 调用**：按字节计量，不做元素宽度取整；immutable/shared 继承 buffer 状态。kind!=1 且缺固定长度为 TypeError，返回的是当时范围快照。

### `JSBytes.objectFromValue` (`src/core/bytes_view.zig:225`)

- **签名**：`fn objectFromValue(value: Value) ?*@import("object.zig").Object`。
- **作用**：验证值是否承载实际 Object。
- **实现**：要求 isObject、非空 refHeader 及 header.meta().flags.kind==object，随后 Object.fromHeader。
- **所有权 / 错误 / 调用**：借用对象指针，无 root/pin；拒绝 VarRef，不验证该对象是否属于支持的二进制类别。

### `JSBytes.typedArrayBufferObject` (`src/core/bytes_view.zig:232`)

- **签名**：`fn typedArrayBufferObject(object: anytype) ?*@import("object.zig").Object`。
- **作用**：读取并验证 view 内的 backing buffer 对象。
- **实现**：typedArrayBuffer 缺失返回 null；对值做 objectFromValue，再要求 AB/SAB class。
- **所有权 / 错误 / 调用**：不在此检查 detached、immutable 或范围，也不保留对象；调用者执行后续投影校验。

### `JSBytes.isArrayBufferObject` (`src/core/bytes_view.zig:239`)

- **签名**：`fn isArrayBufferObject(object: anytype) bool`。
- **作用**：判断 Object class 是否是 AB 或 SAB。
- **实现**：比较 class_id 与 array_buffer/shared_array_buffer。
- **所有权 / 错误 / 调用**：不检查 payload 内容、detached 状态或 backing pointer；输入必须是可访问的对象。

### `JSBytes.isTypedArrayObject` (`src/core/bytes_view.zig:244`)

- **签名**：`fn isTypedArrayObject(object: anytype) bool`。
- **作用**：按 payload 判断对象是否具有 TypedArray 视图形状。
- **实现**：typedArrayBuffer 非空且 typedArrayElementSize 非零时返回 true。
- **所有权 / 错误 / 调用**：不是 class 白名单，也不验证 buffer 值实际类型或范围。正常 DataView 宽度为零，且 fromObject 已先按其 class 分派；畸形 payload 不由此彻底排除。

### `JSBytes.isDataViewObject` (`src/core/bytes_view.zig:248`)

- **签名**：`fn isDataViewObject(object: anytype) bool`。
- **作用**：判断对象 class 是否为 DataView。
- **实现**：只比较 class_id==dataview。
- **所有权 / 错误 / 调用**：不检查 backing、长度或 detach，后续 fromDataViewObject 完成相关验证。

### `State.deinit` (`src/core/bytes_view.zig:274`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：owned store 的 `Store.DeinitFn`：只计数，证明 `release` 第二次是 no-op。
- **实现**：丢掉 `bytes`，把 `context` 铸回 `State`，`calls += 1`。
- **所有权 / 错误 / 调用**：backing 是栈数组，钩子不 free。不是生产 API。

### `Hooks.deinit` (`src/core/bytes_view.zig:296`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：给 `SharedOptions` 一个类型正确的空钩，证明共享 store 必须显式提供 `deinit`。
- **实现**：忽略 `context` 与 `bytes`。
- **所有权 / 错误 / 调用**：只用于 `expect(@TypeOf(options.deinit) == DeinitFn)`。不是生产 API。

### `State.deinit` (`src/core/bytes_view.zig:314`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：ArrayBuffer 接管 owned backing 后，tracer 收对象时 free 宿主内存。
- **实现**：计数然后 `self.allocator.free(bytes)`。
- **所有权 / 错误 / 调用**：`toArrayBuffer` 把 store 掏空；本测试靠 `runObjectCycleRemoval` 触发钩子。不是生产 API。

### `State.deinit` (`src/core/bytes_view.zig:356`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：`detachByteStorage` 立刻跑 owned 钩子，不必等 GC。
- **实现**：计数然后 `allocator.free(bytes)`。
- **所有权 / 错误 / 调用**：detach 后 `asBytes` 必须是 `error.Detached`。不是生产 API。

### `State.deinit` (`src/core/bytes_view.zig:389`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：SharedArrayBuffer 接管 shared backing 后，对象死亡时 free。
- **实现**：计数然后 `allocator.free(bytes)`。
- **所有权 / 错误 / 调用**：与 owned 转移对称，走 `Store.shared`。不是生产 API。

### `testObjectFromValue` (`src/core/bytes_view.zig:639`)

- **签名**：`fn testObjectFromValue(comptime Value: type, value: Value) ?*@import("object.zig").Object`。
- **作用**：测试里从值取对象（detach 用例）。
- **实现**：与 `objectFromValue` 相同检查。
- **所有权 / 错误 / 调用**：仅 test。

### `State.deinit` (`src/core/bytes_view.zig:441`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：本轮新增回归测试「`JSBytes.Store` shared transfer failure frees the host bytes once」里的宿主释放回调夹具：记录被调用次数并释放字节。
- **实现**：把 `context` 转回 `*State`，`calls += 1`，然后 `allocator.free(bytes)`；测试在 `Object.create` 被 `setMemoryLimit` 逼成 OOM 后断言 `calls == 1`（修复前会被调用两次）。
- **所有权 / 错误 / 调用**：仅测试块内使用；作为 `SharedBufferStore.createExternal` 的 `deinit_fn` 传入，由 `store.release()` 调用。

## 覆盖核对

- 清单函数数: 173（`src/core/bytes_view.zig` 30 + `src/core/string.zig` 124 + `src/core/string_view.zig` 19）
- 本文标题覆盖: 173
- 未覆盖: 无
