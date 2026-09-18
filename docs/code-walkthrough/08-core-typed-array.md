# 08 — TypedArray / ArrayBuffer / DataView

`typed_array.zig`：元素读写、强制、AB/SAB 存储操作、视图构造。`typed_array_names.zig`：标准 `*Array` 名 ↔ `{size, kind}`。

本模块不运行用户 `valueOf`/`ToPrimitive`，内部转换只是有限的原语处理或裸 runtime 字符串化，不能当作完整规范转换。带 `maxByteLength` option 对象的 `*ConstructArgs` 在 `exec/typed_array_construct.zig`。视图的 `TypedArrayPayload` 保存 data/live_length 缓存与强 buffer 值，并通过 backing buffer 的弱 view 链表在 resize/detach 时刷新；不是 Object 中独立的裸 ptr/count 缓存。低层裸字节读写和 fill 不自行检查所有状态，调用方必须满足相应有效性与可写前提。

元素 kind 与字节宽度见下表。DataView 使用另一套 kind：1–6 为 Int8/Uint8/Int16/Uint16/Int32/Uint32，7/8 为 Float32/Float64，9/10 为 BigInt64/BigUint64，11 为 Float16；不能与 TypedArray kind 混用。TypedArray 多字节读写固定 little endian；DataView 按参数选择，缺省 big endian。

## `typed_array_names.zig`

`Element` 保存 u32 字节宽度 size 与 u8 kind；私有 `Entry` 保存静态 name slice 和 Element。`concrete` 是十二项固定表：

| kind | 名称 | size（字节） |
| --- | --- | --- |
| 1 / 2 / 3 | Int8Array / Uint8Array / Uint8ClampedArray | 1 |
| 4 / 5 | Int16Array / Uint16Array | 2 |
| 6 / 7 | Int32Array / Uint32Array | 4 |
| 8 | Float16Array | 2 |
| 9 | Float32Array | 4 |
| 10 / 11 / 12 | Float64Array / BigInt64Array / BigUint64Array | 8 |

### `element` (`src/core/typed_array_names.zig:38`)

- **签名**：`pub fn element(name: []const u8) ?Element`。
- **作用**：查具体 TypedArray 名称的元素宽度和 kind。
- **实现**：线性扫描 concrete，按完整名称字节精确匹配，返回 Element 值副本；其他名称返回 null。
- **所有权 / 错误 / 调用**：无分配、区分大小写，不识别 TypedArray 基类或 ArrayBuffer；不查询全局构造器是否被替换。

### `nameFromKind` (`src/core/typed_array_names.zig:45`)

- **签名**：`pub fn nameFromKind(kind: u8) ?[]const u8`。
- **作用**：由元素 kind 取得具体 TypedArray 名称。
- **实现**：线性扫描十二项的 element.kind，命中返回静态 name slice；1–12 之外返回 null。
- **所有权 / 错误 / 调用**：返回借用字符串，无需释放；这里的 kind 不是 class ID 或 DataView 类型编号。

### `isConcrete` (`src/core/typed_array_names.zig:52`)

- **签名**：`pub fn isConcrete(name: []const u8) bool`。
- **作用**：判断名称是否属于具体 TypedArray 表。
- **实现**：返回 element(name)!=null。
- **所有权 / 错误 / 调用**：纯名称判断，不做对象实例或构造器校验。

## ArrayBuffer / SharedArrayBuffer

### `arrayBufferConstruct` (`src/core/typed_array.zig:59`)

- **签名**：`pub fn arrayBufferConstruct(rt: *JSRuntime, length_value: JSValue) !JSValue`。
- **作用**：按原语长度值创建固定长度、null 原型的 ArrayBuffer。
- **实现**：先 toIndexUsize，随后 createArrayBufferWithPrototype(byte_length, null, null)。
- **所有权 / 错误 / 调用**：不读取 options、species 或全局原型；传播 index 转换与分配错误。toIndexUsize 不是完整的用户对象 ToIndex。

### `arrayBufferConstructLength` (`src/core/typed_array.zig:64`)

- **签名**：`pub fn arrayBufferConstructLength(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue`。
- **作用**：以已转换的长度、可选 max 和显式原型创建 ArrayBuffer。
- **实现**：原样委托 createArrayBufferWithPrototype。
- **所有权 / 错误 / 调用**：不在本层校验 byte_length<=max；调用方负责长度参数之间的关系。

### `sharedArrayBufferConstructLength` (`src/core/typed_array.zig:68`)

- **签名**：`pub fn sharedArrayBufferConstructLength(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue`。
- **作用**：创建 SAB，并预分配 max（无 max 时为初始长度）大小的共享存储。
- **实现**：先创建对象并设 errdefer，再验证两长度各不超过 i32 最大值；创建零填充 SharedBufferStore，安装后设置可见前缀长度，最后写 max 槽。
- **所有权 / 错误 / 调用**：byte_length>max 会在 setSharedByteStorageLength 返回 RangeError，已安装 store 由对象失败清理释放。正常构造的后续 grow 可复用该 store，但不意味着所有外部包装 store 都有足够容量。

### `sharedArrayBufferFromStore` (`src/core/typed_array.zig:84`)

- **签名**：`pub fn sharedArrayBufferFromStore( rt: *JSRuntime, store: *object.SharedBufferStore, max_byte_length: ?usize, prototype: ?*Object, ) !JSValue`。
- **作用**：用已有共享 store 包装新 SAB 对象。
- **实现**：先创建对象；有 max 时要求 max>=store.bytes.len 且 max<=i32 最大值，再 retain store 并安装，把整个 store.bytes 暴露为可见长度，写入 max。
- **所有权 / 错误 / 调用**：成功增加一个 store 引用，不接管调用方原引用；无 max 分支不单独 validate store 长度。max 可大于现有容量，之后 grow 可能更换此包装对象的 store。

### `createArrayBufferWithPrototype` (`src/core/typed_array.zig:102`)

- **签名**：`pub fn createArrayBufferWithPrototype(rt: *JSRuntime, byte_length: usize, max_byte_length: ?usize, prototype: ?*Object) !JSValue`。
- **作用**：创建零初始化的 ArrayBuffer 字节存储。
- **实现**：先创建对象；分别验证初始长度与可选 max 的上限，优先安装 inline 字节存储，超出 inline 容量则分配 bytes 并安装；全部字节置零后写 max 槽。
- **所有权 / 错误 / 调用**：不检查初始长度<=max。对象和未成功安装的独立 bytes 各有 errdefer 清理；成功后 bytes 由对象拥有。本函数不自行建立显式根帧，不负责 species 或 options 访问。

### `validateArrayBufferLength` (`src/core/typed_array.zig:117`)

- **签名**：`pub fn validateArrayBufferLength(byte_length: usize) !void`。
- **作用**：检查本实现的 buffer 长度上限。
- **实现**：byte_length>maxInt(i32) 即返回 RangeError，否则成功。
- **所有权 / 错误 / 调用**：仅检查单个 usize 上限，不验证 max 与初始长度关系，也不分配。

### `arrayBufferByteLength` (`src/core/typed_array.zig:121`)

- **签名**：`pub fn arrayBufferByteLength(buffer: *Object) usize`。
- **作用**：取得当前可见字节长度。
- **实现**：arrayBufferDetached 为 true 返回 0，否则返回 byteStorage().len。
- **所有权 / 错误 / 调用**：没有 class 检查；调用方应提供 buffer 对象。读的是可见 slice，不是 SharedBufferStore 的承诺容量。

### `arrayBufferSlice` (`src/core/typed_array.zig:128`)

- **签名**：`pub fn arrayBufferSlice(rt: *JSRuntime, buffer_value: JSValue, start_value: JSValue, end_value: JSValue) !JSValue`。
- **作用**：将原语相对下标转换为范围并复制 buffer。
- **实现**：expectArrayBufferObject 接受 AB 或 SAB；依次拒绝 detached、immutable，再按当前可见长度计算 start/end，委托 arrayBufferSliceRange。
- **所有权 / 错误 / 调用**：输出固定长度普通 AB；不执行 species 构造，不调用用户数值转换。

### `arrayBufferSliceRange` (`src/core/typed_array.zig:138`)

- **签名**：`pub fn arrayBufferSliceRange(rt: *JSRuntime, buffer_value: JSValue, start: usize, end: usize) !JSValue`。
- **作用**：复制已给定的 buffer 字节区间到新普通 AB。
- **实现**：检查 AB/SAB class、detached、immutable；长度取 end>start ? end-start : 0，以源原型创建固定长度 AB，非空时直接拷贝 source[start..end]。
- **所有权 / 错误 / 调用**：不夹紧或显式验证非空范围，调用方必须保证 end<=源长度；逆序或相等范围不切片，返回空 AB。没有本地 errdefer 销毁结果或显式根帧。

### `arrayBufferSliceToImmutable` (`src/core/typed_array.zig:149`)

- **签名**：`pub fn arrayBufferSliceToImmutable(rt: *JSRuntime, buffer_value: JSValue, start_value: JSValue, end_value: JSValue) !JSValue`。
- **作用**：按原语相对下标复制不可变 AB。
- **实现**：仅接受普通 AB，拒绝 detached 和已有 immutable；计算相对 start/end 后委托 Range 版本。
- **所有权 / 错误 / 调用**：不接受 SAB、不读取 species；源 buffer 不会被标记不可变或 detach。

### `arrayBufferSliceToImmutableRange` (`src/core/typed_array.zig:159`)

- **签名**：`pub fn arrayBufferSliceToImmutableRange(rt: *JSRuntime, buffer_value: JSValue, start: usize, end: usize) !JSValue`。
- **作用**：复制指定范围并标记新 AB 为 immutable。
- **实现**：仅普通、未 detached、可变源；end>源长度先 RangeError，即使 end<=start 也检查。创建 max=null、源原型的 AB，非空时拷贝，再 markArrayBufferImmutable。
- **所有权 / 错误 / 调用**：标记错误传播；不 detach 源，也无本地结果对象销毁兜底。非空范围的 start 由 start<end 与 end 检查约束。

### `arrayBufferTransfer` (`src/core/typed_array.zig:172`)

- **签名**：`pub fn arrayBufferTransfer(rt: *JSRuntime, buffer_value: JSValue, new_length_value: JSValue, fixed_length: bool) !JSValue`。
- **作用**：确定 transfer 新长度并委托复制与 detach。
- **实现**：先要求普通 AB；undefined 取当前 bytes.len，否则 toIndexUsize；随后调用 arrayBufferTransferLength。
- **所有权 / 错误 / 调用**：detached/immutable 检查在 Length 版本，发生于本层长度转换之后；此处不是存储指针的零拷贝转移。

### `arrayBufferTransferLength` (`src/core/typed_array.zig:178`)

- **签名**：`pub fn arrayBufferTransferLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize, fixed_length: bool) !JSValue`。
- **作用**：新建 AB，复制保留区间，再 detach 源。
- **实现**：拒绝 detached/immutable；fixed_length=false 且有 max 时，new_length>max 返回 TypeError。新 AB 沿用源原型，max 在 fixed 时清空，否则保留；复制 min(old,new) 字节，尾部来自新建时的零填充，最后 detach。
- **所有权 / 错误 / 调用**：以上 TypeError 是当前代码行为，不能用缺少 test262 用例作为规范正确性的依据。分配失败发生在 detach 前；成功返回新对象，不共享原存储。fixed 分支不受旧 max 限制，仍受构造长度上限约束。

### `arrayBufferTransferToImmutable` (`src/core/typed_array.zig:200`)

- **签名**：`pub fn arrayBufferTransferToImmutable(rt: *JSRuntime, buffer_value: JSValue, new_length_value: JSValue) !JSValue`。
- **作用**：计算不可变 transfer 的新长度。
- **实现**：要求普通 AB；undefined 取原可见长度，否则 toIndexUsize，随后委托 Length 版本。
- **所有权 / 错误 / 调用**：长度转换先于 Length 版本的 detached/immutable 检查；不读取对象 options 或 species。

### `arrayBufferTransferToImmutableLength` (`src/core/typed_array.zig:206`)

- **签名**：`pub fn arrayBufferTransferToImmutableLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize) !JSValue`。
- **作用**：复制到不可变、固定长度 AB 并 detach 原对象。
- **实现**：拒绝 detached/immutable；以源原型新建 max=null 的 AB，复制 min(old,new) 字节，标记结果 immutable，最后 detach 源。
- **所有权 / 错误 / 调用**：不保留或按旧 max 限制新长度；新构造仍检查 i32 上限。mark 失败时尚未 detach，但没有本地结果对象 errdefer。

### `sharedArrayBufferSlice` (`src/core/typed_array.zig:219`)

- **签名**：`pub fn sharedArrayBufferSlice(rt: *JSRuntime, buffer_value: JSValue, start_value: JSValue, end_value: JSValue) !JSValue`。
- **作用**：将 SAB 相对下标转换为范围后复制。
- **实现**：验证 SAB class，读取可见长度，计算两个相对下标，委托 sharedArrayBufferSliceRange。
- **所有权 / 错误 / 调用**：不复用源 store、不做 species 构造，也不保证 memcpy 是多线程一致快照。

### `sharedArrayBufferSliceRange` (`src/core/typed_array.zig:227`)

- **签名**：`pub fn sharedArrayBufferSliceRange(rt: *JSRuntime, buffer_value: JSValue, start: usize, end: usize) !JSValue`。
- **作用**：创建独立 store 的固定长度 SAB 切片。
- **实现**：验证 SAB；长度取正的 end-start，否则 0；以源原型、max=null 构造新 SAB，非空时 memcpy 源区间。
- **所有权 / 错误 / 调用**：不显式检查 end 边界，非空范围须由调用方保证；不产生源 store 的共享引用。无本地显式根帧。

### `sharedArrayBufferGrow` (`src/core/typed_array.zig:236`)

- **签名**：`pub fn sharedArrayBufferGrow(rt: *JSRuntime, buffer_value: JSValue, new_length_value: JSValue) !JSValue`。
- **作用**：检查 growable 条件后转换新长度。
- **实现**：验证 SAB，先要求 max 存在，否则 TypeError；然后 toIndexUsize，委托 GrowLength。
- **所有权 / 错误 / 调用**：所以不可 grow 的 SAB 即使输入负长度也先 TypeError；该原语入口不执行用户 valueOf。

### `sharedArrayBufferGrowLength` (`src/core/typed_array.zig:247`)

- **签名**：`pub fn sharedArrayBufferGrowLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize) !JSValue`。
- **作用**：增大 SAB 可见前缀，必要时更换外部欠容量 store。
- **实现**：要求 SAB 与 max；new<当前可见长度或 new>max 返回 RangeError。有 store 且容量足够时只 setSharedByteStorageLength；否则创建 new_length 大小的零填充 store，复制旧可见前缀后安装。
- **所有权 / 错误 / 调用**：正常预分配路径保持 store 身份；回退路径会释放本对象的旧 store 引用并切换身份，其他共享者仍持有旧 store。两条路径更新关联视图；返回 undefined，不修改 max。

### `arrayBufferResize` (`src/core/typed_array.zig:274`)

- **签名**：`pub fn arrayBufferResize(rt: *JSRuntime, buffer_value: JSValue, new_length_value: JSValue) !JSValue`。
- **作用**：检查普通 AB 可调整状态后转换长度。
- **实现**：要求普通 AB，依次检查 immutable、detached、max 缺失并返回 TypeError，然后 toIndexUsize，委托 ResizeLength。
- **所有权 / 错误 / 调用**：状态检查先于长度转换；不适用于 SAB，不执行用户数值转换。

### `arrayBufferResizeLength` (`src/core/typed_array.zig:288`)

- **签名**：`pub fn arrayBufferResizeLength(rt: *JSRuntime, buffer_value: JSValue, new_length: usize) !JSValue`。
- **作用**：为可调整 AB 重新分配并安装字节存储。
- **实现**：要求普通 AB，依次检查 detached、immutable、max 存在以及 new<=max。分配新长度，复制 min(old,new)，增长尾部置零，再 installByteStorage。
- **所有权 / 错误 / 调用**：即使长度不变也分配；失败时释放未安装的新 bytes，安装完成会释放旧存储并刷新视图。该入口不再独立调用 validateArrayBufferLength，依赖 max 的有效性；返回 undefined。

### `detachArrayBuffer` (`src/core/typed_array.zig:304`)

- **签名**：`pub fn detachArrayBuffer(rt: *JSRuntime, buffer_value: JSValue) !JSValue`。
- **作用**：对普通 AB 调用底层 detach。
- **实现**：expectArrayBufferOnlyObject 后直接 detachByteStorage，返回 undefined。
- **所有权 / 错误 / 调用**：拒绝 SAB，但本层不拒绝 immutable 或已 detached，不读取 detach key；底层会释放普通存储并失效视图。若普通 AB 异常装有 shared_store，底层直接返回而不 detach。

## 视图构造

### `typedArrayClassIdForKind` (`src/core/typed_array.zig:322`)

- **签名**：`fn typedArrayClassIdForKind(kind: u8) ?class.ClassId`。
- **作用**：把元素 kind 映射到具体 TypedArray class ID。
- **实现**：1–12 依次为 Int8、Uint8、Uint8Clamped、Int16、Uint16、Int32、Uint32、Float16、Float32、Float64、BigInt64、BigUint64 对应的 class；其余返回 null。
- **所有权 / 错误 / 调用**：不验证元素宽度，也不创建对象或查询构造器。

### `createTypedArrayInstance` (`src/core/typed_array.zig:340`)

- **签名**：`fn createTypedArrayInstance(rt: *JSRuntime, kind: u8, prototype: ?*Object) !*Object`。
- **作用**：创建指定 kind/prototype 的内部视图对象。
- **实现**：有效 kind 选择具体 TA class，未知 kind 退回普通 object class；创建后，普通 class 分支再 ensureTypedArrayPayload。
- **所有权 / 错误 / 调用**：未知 kind 不直接报 TypeError；额外 payload 分配失败由 errdefer 销毁对象。这里只建立对象与 payload，尚未安装 backing buffer。

### `typedArrayConstruct` (`src/core/typed_array.zig:351`)

- **签名**：`pub fn typedArrayConstruct(rt: *JSRuntime, element_size: u32, buffer_value: JSValue) !JSValue`。
- **作用**：用默认 kind=2 创建从偏移零开始的视图。
- **实现**：委托 WithOptions，传入调用方 element_size、kind=2、单参数数组和 null 原型。
- **所有权 / 错误 / 调用**：kind 是 Uint8，但宽度直接采用传入值，不在此强制为 1；省略 length 对可调整 AB/可增长 SAB 会产生跟踪长度，而非一律固定长度。

### `typedArrayConstructWithOptions` (`src/core/typed_array.zig:355`)

- **签名**：`pub fn typedArrayConstructWithOptions(rt: *JSRuntime, element_size: u32, kind: u8, buffer_value: JSValue, args: []const JSValue, prototype: ?*Object) !JSValue`。
- **作用**：按位置参数建立 AB 或 SAB 上的视图。
- **实现**：宽度 0 先 TypeError；检查 buffer class 与 detached。args[1]（非 undefined）提供 offset，须不超当前长度且按宽度对齐。args[2] 非 undefined 表示显式元素数：checked mul 求字节数，须不超剩余空间且元素数拟合 u32；未指定且无 max 时要求剩余字节整除宽度，固定为商；有 max 时 fixed_length=null。最后创建对象并 initTypedArrayView。
- **所有权 / 错误 / 调用**：只使用 args[1]/args[2]，buffer 来自独立 buffer_value；不验证 kind 与宽度匹配或 immutable。乘法溢出直接传播 error.Overflow，不统一转成 RangeError；无 max 分支用 @intCast 商。对象失败有 errdefer，函数自身不建立显式根帧或调用 species。

### `typedArrayConstructFullBuffer` (`src/core/typed_array.zig:380`)

- **签名**：`pub fn typedArrayConstructFullBuffer(rt: *JSRuntime, element_size: u32, kind: u8, buffer_value: JSValue, buffer: *Object, prototype: ?*Object) !JSValue`。
- **作用**：建立固定长度、零偏移的整 buffer 视图。
- **实现**：原样委托 typedArrayConstructFullBufferOwned。
- **所有权 / 错误 / 调用**：两者当前没有 RC retain/release 差异，也不会清空调用方的 JSValue 变量；调用方必须保证 buffer_value 与 buffer 指向同一有效缓冲区。

### `typedArrayConstructFullBufferOwned` (`src/core/typed_array.zig:384`)

- **签名**：`pub fn typedArrayConstructFullBufferOwned(rt: *JSRuntime, element_size: u32, kind: u8, buffer_value: JSValue, buffer: *Object, prototype: ?*Object) !JSValue`。
- **作用**：以给定 buffer 的完整长度建立固定视图。
- **实现**：要求宽度非零、buffer 未 detached 且 max=null，长度整除宽度，元素数拟合 u32；创建对象，把本地 owned_buffer_value 复制到 view_buffer 后置 undefined，再 initTypedArrayView(offset=0,fixed=length)。
- **所有权 / 错误 / 调用**：本地置 undefined 不是释放或清空调用方值；没有 RC 消费清理。长度检查使用独立 buffer 指针，安装使用 buffer_value，二者同一身份是调用前提；本函数不校验 buffer class，init 才验证所装值。失败只显式销毁新视图。

### `dataViewConstruct` (`src/core/typed_array.zig:404`)

- **签名**：`pub fn dataViewConstruct(rt: *JSRuntime, args: []const JSValue, prototype: ?*Object) !JSValue`。
- **作用**：按位置参数构造 DataView 内部槽。
- **实现**：至少一个参数，接受 AB/SAB 并拒绝 detached；offset 默认 0，须<=当前长度。第三参数缺失或 undefined 时 auto_length=true，长度取剩余字节，否则转换给定长度；检查 offset+length<=buffer_length。创建 DataView 后检查长度拟合 u32，安装 element_size=0、fixed_length=当前 view_length、kind=auto?1:0。
- **所有权 / 错误 / 调用**：auto 标志只有 backing 有 max 时才产生跟踪长度；固定 buffer 的 auto 仍使用保存长度。offset+length 是普通 usize 加法，非 checked add，极大输入不保证作为 RangeError 返回；失败销毁已创建对象，不执行完整 JS 构造器/species 逻辑。

## 元素读写

### `typedArrayGetIndex` (`src/core/typed_array.zig:434`)

- **签名**：`pub fn typedArrayGetIndex(rt: *JSRuntime, obj: *Object, index: u32) !JSValue`。
- **作用**：按缓存的当前元素数读取一个视图元素。
- **实现**：无 typed payload 或 element_size=0 返回 TypeError；index>=live_length 或 data=null 返回 undefined；按 index*width 切出字节后 readElement。
- **所有权 / 错误 / 调用**：使用已维护的 live cache，不重新检查 backing detached；不验证 kind/width 一致性。数值种类无需分配，BigInt 读取可能分配并失败。

### `typedArrayCoerceElementValue` (`src/core/typed_array.zig:444`)

- **签名**：`pub fn typedArrayCoerceElementValue(rt: *JSRuntime, obj: *Object, value: JSValue) !void`。
- **作用**：验证值能编码成该元素类型，不修改视图存储。
- **实现**：在栈上准备 8 字节 scratch，以 obj 的 kind 和 element_size 调用 writeElement。
- **所有权 / 错误 / 调用**：不检查 detached、immutable、live_length；元素宽度必须<=8，且调用方须给出合法 kind/width。转换可能分配或报错，scratch 随返回丢弃；不执行用户对象 ToPrimitive。

### `typedArraySetElement` (`src/core/typed_array.zig:449`)

- **签名**：`pub fn typedArraySetElement(rt: *JSRuntime, obj: *Object, index: u32, value: JSValue) !bool`。
- **作用**：先编码值，再尝试写入合法下标，返回是否实际写入。
- **实现**：无 payload/backing 返回 TypeError；immutable 立即 false（尚未转换）。宽度 0 返回 TypeError；向 8 字节 scratch 编码，随后 index 越界或 data 为空返回 false，否则复制到目标位置并返回 true。
- **所有权 / 错误 / 调用**：越界仍进行原语编码，但 immutable 提前返回；kind/width 合法且宽度<=8 是前提。不是完整规范 ToNumber，外围需处理用户转换及其他可观察行为。

### `typedArraySetIndex` (`src/core/typed_array.zig:464`)

- **签名**：`pub fn typedArraySetIndex(rt: *JSRuntime, obj: *Object, index: u32, value: JSValue) !bool`。
- **作用**：按当前有效缓存直接写元素，越界时忽略写入并报告成功。
- **实现**：无 payload/backing 或零宽度为 TypeError；immutable 返回 false；index>=live_length 或 data=null 返回 true，跳过转换。有效位置调用 writeElement 后返回 true。
- **所有权 / 错误 / 调用**：true 不证明有字节被写入；与 SetElement 在越界转换顺序、返回含义上不同。原语转换错误传播，完整用户转换由外围负责。

### `typedArrayFillRange` (`src/core/typed_array.zig:483`)

- **签名**：`pub fn typedArrayFillRange(rt: *JSRuntime, obj: *Object, start: u32, final: u32, value: JSValue) !void`。
- **作用**：把一个编码后的元素字节模式重复填入范围。
- **实现**：start>=final 立即返回，甚至不检查对象。其余路径取得 payload，拒绝零宽度，将值编码一次到 8 字节 scratch，再要求 data 非空；宽度 1 使用 memset，其余按宽度重复 memcpy。
- **所有权 / 错误 / 调用**：本函数不校验 final<=live_length、immutable 或 backing，调用方必须先校验范围和可写状态。writeElement 仍执行一次原语转换，宽度必须<=8；此处不保证任意传入对象/范围都安全。

### `typedArraySetInt32IndexFast` (`src/core/typed_array.zig:506`)

- **签名**：`pub fn typedArraySetInt32IndexFast(rt: *JSRuntime, obj: *Object, index: u32, value: i32) !bool`。
- **作用**：为 kind=6 的视图直接写入 little-endian i32。
- **实现**：无 payload 为 TypeError；kind 非 6 返回 false。随后要求 backing，immutable 返回 false；越界或 data=null 返回 true，其他位置按 index*4 写入。
- **所有权 / 错误 / 调用**：rt 未用，无分配；不重新验证 element_size==4 或 class，依赖 kind/布局一致。false 表示未处理，true 包括越界忽略，不等于实际写入。

### `typedArrayDefineOwnProperty` (`src/core/typed_array.zig:519`)

- **签名**：`pub fn typedArrayDefineOwnProperty(rt: *JSRuntime, obj: *Object, atom_id: Atom, desc: Descriptor) !?bool`。
- **作用**：处理 TypedArray 的规范数字索引属性定义。
- **实现**：非 TA 或 canonical index 分类为 none 返回 null；invalid 返回 false。index 分支拒绝 accessor，以及显式 configurable/enumerable/writable=false；再检查有效下标及非 immutable。有 value_present 时调用 SetElement，最终返回 true。
- **所有权 / 错误 / 调用**：属性标志为 true 或缺省可通过，不是拒绝 true。SetElement 返回的 bool 被丢弃，只有错误传播；?bool 中 null 表示应交普通属性路径，false 表示拒绝此索引定义。

### `typedArrayBufferObject` (`src/core/typed_array.zig:543`)

- **签名**：`pub fn typedArrayBufferObject(obj: *Object) !*Object`。
- **作用**：取得视图保存的 backing buffer 对象。
- **实现**：typedArrayBuffer 为空则 TypeError，否则 expectArrayBufferObject 校验值并接受 AB/SAB。
- **所有权 / 错误 / 调用**：借用对象指针，无 retain/root；不检查 buffer detached、immutable 或视图是否越界。

## DataView

### `dataViewGet` (`src/core/typed_array.zig:551`)

- **签名**：`pub fn dataViewGet(rt: *JSRuntime, view_value: JSValue, kind: u32, args: []const JSValue) !JSValue`。
- **作用**：读取 DataView 指定字节位置的一项值。
- **实现**：验证 DataView class；index 默认 0，否则 toIndexUsize。第二参数经 toBoolean 决定 little endian，默认 big endian。取得 kind 宽度，检查 attached 和 bounds，逐字节复制到 8 字节 scratch 后解码。kind 1–6 为整数，7/8 为 Float32/64，9/10 为 BigInt64/BigUint64，11 为 Float16。
- **所有权 / 错误 / 调用**：index 转换在 detached 检查前；未知 kind 宽度为 0，可能先通过 bounds，再由解码 switch 返回 TypeError。数值读取不分配，BigInt 结果可能分配；逐字节复制不是共享内存原子读取。

### `dataViewSet` (`src/core/typed_array.zig:583`)

- **签名**：`pub fn dataViewSet(rt: *JSRuntime, view_value: JSValue, kind: u32, args: []const JSValue) !JSValue`。
- **作用**：把值编码后写入 DataView。
- **实现**：先验证 view 与 backing，immutable 立即 TypeError；再转换 index（缺省 undefined→0），取 value（缺省 undefined）及第三参数字节序（默认 big）。按 kind 编码到 scratch，未知 kind 立即 TypeError。随后检查 attached/bounds，逐字节写入 backing 并返回 undefined。
- **所有权 / 错误 / 调用**：原语编码可在 detached/越界错误之前失败或分配；这里不执行用户 valueOf/ToPrimitive，不能把这一顺序描述成此函数会触发用户 ToNumber 副作用。kind 9/10 使用低64位 BigInt 编码；写入不是多字节原子操作。

### `dataViewRejectImmutable` (`src/core/typed_array.zig:615`)

- **签名**：`pub fn dataViewRejectImmutable(rt: *JSRuntime, view_value: JSValue) !void`。
- **作用**：检查 DataView 的 backing 是否不可变。
- **实现**：expectDataViewObject 后取得 AB/SAB backing，arrayBufferIsImmutable 为 true 返回 TypeError。
- **所有权 / 错误 / 调用**：不检查 detached 或视图范围；成功仅证明此处 class/backing/immutable 检查通过。

### `dataViewRequire` (`src/core/typed_array.zig:621`)

- **签名**：`pub fn dataViewRequire(view_value: JSValue) !void`。
- **作用**：验证 JSValue 的具体 class 为 DataView。
- **实现**：调用 expectDataViewObject 并丢弃借用指针。
- **所有权 / 错误 / 调用**：不检查 backing 槽是否存在、是否 detached 或视图是否越界。

### `dataViewByteLength` (`src/core/typed_array.zig:625`)

- **签名**：`pub fn dataViewByteLength(rt: *JSRuntime, view: *Object) !usize`。
- **作用**：计算 accessor 使用的有效视图字节长度。
- **实现**：委托 dataViewEffectiveByteLength。
- **所有权 / 错误 / 调用**：传入的是已验证 view 指针，本层不重新检查 DataView class；传播该 helper 的 detached/缺槽/越界错误。

### `dataViewByteOffset` (`src/core/typed_array.zig:629`)

- **签名**：`pub fn dataViewByteOffset(rt: *JSRuntime, view: *Object) !usize`。
- **作用**：验证视图有效性后返回保存的偏移。
- **实现**：先调用 dataViewEffectiveByteLength，成功才返回 typedArrayByteOffset。
- **所有权 / 错误 / 调用**：不把无效视图的偏移归零；检查失败直接传播错误，调用方负责 view class。

### `dataViewValidateConstructorRange` (`src/core/typed_array.zig:634`)

- **签名**：`pub fn dataViewValidateConstructorRange(_: *JSRuntime, buffer_value: JSValue, byte_offset: usize, view_length: ?usize) !void`。
- **作用**：验证已转换的构造偏移和可选长度。
- **实现**：要求 AB/SAB 且未 detached；offset>可见长度时 RangeError。先减 offset 求 remaining，可选 length>remaining 再 RangeError。
- **所有权 / 错误 / 调用**：rt 未用，无分配；减法在已检查 offset 后进行，避免 offset+length 溢出。未检查长度拟合 u32，也不创建视图或拒绝 immutable。

### `dataViewRequireArrayBuffer` (`src/core/typed_array.zig:645`)

- **签名**：`pub fn dataViewRequireArrayBuffer(buffer_value: JSValue) !void`。
- **作用**：验证构造参数是 AB 或 SAB。
- **实现**：调用 expectArrayBufferObject 并丢弃结果。
- **所有权 / 错误 / 调用**：只检查对象身份，不检查 detached、长度或可调整状态。

### `checkDataViewBounds` (`src/core/typed_array.zig:649`)

- **签名**：`fn checkDataViewBounds(rt: *JSRuntime, view: *Object, index: usize, width: usize) !void`。
- **作用**：检查一次 get/set 的字节访问范围。
- **实现**：先取得 backing，detached 返回 TypeError；要求 fixed_length 槽存在。kind==1 且 backing 有 max 时 tracking，访问长度取饱和的 buffer长度-offset；否则取保存长度。index>长度或 width>长度-index 返回 RangeError；随后非tracking整视图超出 backing 才 TypeError。
- **所有权 / 错误 / 调用**：rt 未用；零 width 并不必然失败，index==长度也可通过。正常正宽度操作在缩短后 tracking offset 越界时 RangeError；这与 byteLength getter 的 TypeError 不同。最后 offset+stored_length 使用普通加法，依赖合法内部槽。

### `checkDataViewAttached` (`src/core/typed_array.zig:672`)

- **签名**：`fn checkDataViewAttached(rt: *JSRuntime, view: *Object) !void`。
- **作用**：检查视图 backing 是否已 detached。
- **实现**：dataViewBuffer 取得 AB/SAB，detached 为 true 返回 TypeError。
- **所有权 / 错误 / 调用**：rt 未用，不判断视图范围、immutable、元素宽度或 DataView class。

### `dataViewEffectiveByteLength` (`src/core/typed_array.zig:678`)

- **签名**：`fn dataViewEffectiveByteLength(rt: *JSRuntime, view: *Object) !usize`。
- **作用**：按 getter 规则计算视图长度。
- **实现**：取 backing 并拒绝 detached，要求 fixed_length 存在。backing 无 max 时直接返回保存长度；有 max 且 kind==1 时要求 offset<=可见长度，返回剩余字节；其他情况要求 offset 和完整固定范围均拟合，再返回保存长度。
- **所有权 / 错误 / 调用**：rt 未用；无 max 分支不重新校验内部 offset/length。tracking 的 offset==buffer长度允许返回 0，而大于长度为 TypeError；此函数不用 payload.live_length。

### `dataViewBuffer` (`src/core/typed_array.zig:694`)

- **签名**：`fn dataViewBuffer(view: *Object) !*Object`。
- **作用**：读取视图强引用的 backing 对象。
- **实现**：typedArrayBuffer 槽为空则 TypeError，否则经 expectArrayBufferObject 检查对象及 AB/SAB class。
- **所有权 / 错误 / 调用**：返回借用指针，不新建根或增加引用计数；不独立验证 view class 或 backing 状态。

### `dataViewKindWidth` (`src/core/typed_array.zig:698`)

- **签名**：`fn dataViewKindWidth(kind: u32) usize`。
- **作用**：把 DataView 操作 kind 映射为字节数。
- **实现**：1/2→1，3/4/11→2，5/6/7→4，8/9/10→8，其他→0。
- **所有权 / 错误 / 调用**：纯映射，未知 kind 不在此抛错；宽度 0 可能通过 bounds，最终由 get/set 的 kind switch 拒绝。此编号不是 TypedArray 的元素 kind。

## 守卫与编解码

### `expectArrayBufferObject` (`src/core/typed_array.zig:712`)

- **签名**：`pub fn expectArrayBufferObject(value: JSValue) !*Object`。
- **作用**：检查值具有指定的内部对象 class。
- **实现**：先用共享 expectObject 验证真正的 Object（拒绝同样使用 object tag 的 VarRef），再要求 class_id 为 array_buffer 或 shared_array_buffer，不符返回 TypeError。
- **所有权 / 错误 / 调用**：返回借用对象指针，不解 Proxy、不沿原型链；不验证内部槽完整性、detached、immutable 或任何范围。

### `expectArrayBufferOnlyObject` (`src/core/typed_array.zig:718`)

- **签名**：`pub fn expectArrayBufferOnlyObject(value: JSValue) !*Object`。
- **作用**：检查值具有指定的内部对象 class。
- **实现**：先用共享 expectObject 验证真正的 Object（拒绝同样使用 object tag 的 VarRef），再要求 class_id 为 array_buffer，不符返回 TypeError。
- **所有权 / 错误 / 调用**：返回借用对象指针，不解 Proxy、不沿原型链；不验证内部槽完整性、detached、immutable 或任何范围。

### `expectSharedArrayBufferObject` (`src/core/typed_array.zig:724`)

- **签名**：`pub fn expectSharedArrayBufferObject(value: JSValue) !*Object`。
- **作用**：检查值具有指定的内部对象 class。
- **实现**：先用共享 expectObject 验证真正的 Object（拒绝同样使用 object tag 的 VarRef），再要求 class_id 为 shared_array_buffer，不符返回 TypeError。
- **所有权 / 错误 / 调用**：返回借用对象指针，不解 Proxy、不沿原型链；不验证内部槽完整性、detached、immutable 或任何范围。

### `expectDataViewObject` (`src/core/typed_array.zig:730`)

- **签名**：`pub fn expectDataViewObject(value: JSValue) !*Object`。
- **作用**：检查值具有指定的内部对象 class。
- **实现**：先用共享 expectObject 验证真正的 Object（拒绝同样使用 object tag 的 VarRef），再要求 class_id 为 dataview，不符返回 TypeError。
- **所有权 / 错误 / 调用**：返回借用对象指针，不解 Proxy、不沿原型链；不验证内部槽完整性、detached、immutable 或任何范围。

### `relativeSliceIndex` (`src/core/typed_array.zig:738`)

- **签名**：`fn relativeSliceIndex(rt: *JSRuntime, value: JSValue, len: usize, undefined_is_len: bool) !usize`。
- **作用**：将原语相对下标截断并夹紧到给定长度。
- **实现**：undefined 且 undefined_is_len 时直接返回 len；否则 toIntegerOrInfinity。NaN/负无穷为0，正无穷为len。有限值先 trunc，负数加 len 后夹紧；非负值按0与len夹紧，内部结果再转 usize。
- **所有权 / 错误 / 调用**：不运行用户数值转换，辅助字符串化可能分配或失败；通过 f64 计算，任意超出精确整数范围的 usize len 不保证精确，而正常内部 buffer 长度受更小上限约束。

### `decodeUint32` (`src/core/typed_array.zig:762`)

- **签名**：`inline fn decodeUint32(bits: u32) JSValue`。
- **作用**：把无符号32位整数表示为 JS Number。
- **实现**：<=maxInt(i32) 使用 int32 tag；更大值通过 floatFromInt 构造 float64。
- **所有权 / 错误 / 调用**：整个 u32 范围都可精确表示为 f64，无分配；不会把高位为1的值误解释成负 i32。

### `decodeNumericElement` (`src/core/typed_array.zig:771`)

- **签名**：`pub inline fn decodeNumericElement(kind: u8, bytes: [*]const u8) JSValue`。
- **作用**：从裸字节指针解码数值 TypedArray 元素。
- **实现**：kind 1–7 读相应整数，Uint8Clamped 与 Uint8 读取相同，Uint32 委托 decodeUint32；8/9/10 分别读 Float16/32/64 并返回 float64 tag。多字节一律 little endian，其他 kind unreachable。
- **所有权 / 错误 / 调用**：没有长度信息或 bounds/class/detach 检查；调用方保证 kind1–10且指针至少可读对应宽度。浮点结果不做可表示为int32的重新归类，无分配。

### `decodeNumericElementByClass` (`src/core/typed_array.zig:789`)

- **签名**：`pub inline fn decodeNumericElementByClass(class_id: class.ClassId, data: [*]const u8, index: u32) JSValue`。
- **作用**：按具体数值 TypedArray class 和下标解码元素。
- **实现**：switch 内直接以 class 固定的1/2/4/8宽度计算偏移，整数/浮点解码与 decodeNumericElement 一致。
- **所有权 / 错误 / 调用**：不读取对象或 element_size/live_length；要求预先验证的 class、有效裸指针和下标。BigInt class 及其他 class unreachable，不是TypeError。

### `writeInt32NumericElementByClass` (`src/core/typed_array.zig:809`)

- **签名**：`pub inline fn writeInt32NumericElementByClass( class_id: class.ClassId, data: [*]u8, index: u32, integer: i32, ) void`。
- **作用**：把已知 i32 直接编码到指定数值 TypedArray 位置。
- **实现**：整数 class 按位截断至1/2/4字节；Uint8Clamped 夹到0–255；Float16/32/64转相应浮点位型。按 class 固定宽度计算偏移，多字节写 little endian。
- **所有权 / 错误 / 调用**：无分配或数值转换错误，但不检查 live范围、immutable、detached 或指针容量；非法 class unreachable。支持浮点 class，这一点与只支持整数 kind 的 writeInt32NumericElement 不同。

### `bigIntResult` (`src/core/typed_array.zig:834`)

- **签名**：`fn bigIntResult(rt: *JSRuntime, value: i128) !JSValue`。
- **作用**：将 i128 数值包装成堆 BigInt JSValue。
- **实现**：调用 bigint.BigInt.create，返回该对象的 valueRef。
- **所有权 / 错误 / 调用**：分配失败传播；用于有符号和无符号64位读取，无符号值先扩到i128，不会被解释成负数。

### `numberValue` (`src/core/typed_array.zig:839`)

- **签名**：`fn numberValue(value: JSValue) ?f64`。
- **作用**：只解包已经是 Number 的 JSValue。
- **实现**：先尝试 int32 并精确转成f64，再尝试 float64，其他返回 null。
- **所有权 / 错误 / 调用**：不做ToNumber；NaN、Infinity及负零仍是有效浮点返回值，null表示非数值tag。

### `numberToUint32` (`src/core/typed_array.zig:845`)

- **签名**：`fn numberToUint32(number: f64) u32`。
- **作用**：把 f64 截断并按2^32取模。
- **实现**：非有限值/NaN返回0；对trunc(number)取模4294967296，负模加2^32，再转u32。
- **所有权 / 错误 / 调用**：无错误联合体；小数向零截断，负数按模得到无符号位型，正负零均得到0。

### `numberToUint8Clamp` (`src/core/typed_array.zig:853`)

- **签名**：`fn numberToUint8Clamp(number: f64) u8`。
- **作用**：把 f64 夹紧并舍入到 u8。
- **实现**：NaN或<=0为0，>=255为255；其余以floor和小数部分比较0.5，恰好一半时选择偶数整数。
- **所有权 / 错误 / 调用**：正Infinity得到255，负Infinity得到0；不使用普通截断或始终向上的半数舍入，无分配。

### `coerceNumber` (`src/core/typed_array.zig:867`)

- **签名**：`fn coerceNumber(rt: *JSRuntime, value: JSValue) !f64`。
- **作用**：执行本层有限的原语数值转换。
- **实现**：Symbol先TypeError；Number直接返回，布尔为0/1，null为0；String转临时UTF-8后parseJsNumber，并defer释放临时数组；其他值一律NaN。
- **所有权 / 错误 / 调用**：其他值包括undefined、对象以及BigInt。这里自身没有BigInt拒绝分支：writeNumericElement在外层单独拒绝BigInt，不能把该保证套到所有调用者。不调用用户valueOf/ToPrimitive；字符串路径仍可分配或报错。

### `float16ToF64` (`src/core/typed_array.zig:881`)

- **签名**：`fn float16ToF64(bits: u16) f64`。
- **作用**：把16位浮点位型扩为f64。
- **实现**：先bitCast为f16，再floatCast为f64。
- **所有权 / 错误 / 调用**：保留浮点数值、符号零及非有限类别，不是把u16整数作数值转换；不承诺原NaN payload逐位保留。

### `f64ToFloat16` (`src/core/typed_array.zig:885`)

- **签名**：`fn f64ToFloat16(value: f64) u16`。
- **作用**：将f64转换为f16并返回其位型。
- **实现**：floatCast至f16，再bitCast为u16。
- **所有权 / 错误 / 调用**：按编译器浮点窄化规则舍入，可能损失精度或溢出为Infinity；不返回RangeError，也不在此处理字节序。

### `readNumericElement` (`src/core/typed_array.zig:901`)

- **签名**：`pub noinline fn readNumericElement(kind: u8, bytes: [*]const u8) callconv(.c) JSValue`。
- **作用**：通过C调用约定读取单个非BigInt元素。
- **实现**：noinline函数直接转调decodeNumericElement。
- **所有权 / 错误 / 调用**：只保证声明为callconv(.c)，具体返回寄存器方式由目标ABI与JSValue表示决定，不应泛称所有64位目标均返回16字节寄存器值。裸指针容量/kind有效性由调用方保证，无分配。

### `readElement` (`src/core/typed_array.zig:905`)

- **签名**：`pub fn readElement(rt: *JSRuntime, kind: u8, bytes: []const u8) !JSValue`。
- **作用**：按元素kind读取数值或BigInt。
- **实现**：kind1–10把bytes.ptr交给readNumericElement；11以little endian读i64，12读u64并扩为i128，再bigIntResult；其他kind返回TypeError。
- **所有权 / 错误 / 调用**：数值分支丢弃slice长度，不验证bytes.len够用；BigInt分支要求至少8字节，其slice检查也不是可恢复错误。BigInt结果分配可失败。

### `writeNumericElement` (`src/core/typed_array.zig:923`)

- **签名**：`pub inline fn writeNumericElement(rt: *JSRuntime, kind: u8, bytes: []u8, value: JSValue) !void`。
- **作用**：把非BigInt元素值编码到字节slice。
- **实现**：先拒绝BigInt输入；kind1/2/4/5/6/7走截断整数，3走clamp，8/9/10分别实例化浮点写入；其他kind unreachable。
- **所有权 / 错误 / 调用**：合法kind和足够bytes容量由调用方保证；不是视图写入接口，不检查immutable/detached。Symbol或字符串转换错误传播。

### `isIntegerNumericKind` (`src/core/typed_array.zig:936`)

- **签名**：`pub inline fn isIntegerNumericKind(kind: u8) bool`。
- **作用**：判断kind是否属于整数数值数组。
- **实现**：1–7为true，其他false，包括浮点与BigInt。
- **所有权 / 错误 / 调用**：包含Uint8Clamped，不区分有符号/无符号，也不验证对象。

### `writeInt32NumericElement` (`src/core/typed_array.zig:950`)

- **签名**：`pub inline fn writeInt32NumericElement(kind: u8, bytes: [*]u8, integer: i32) bool`。
- **作用**：向整数kind写入已解包的i32。
- **实现**：kind1/2截低8位，3夹0–255，4/5写低16位，6/7写完整32位，均little endian；其他kind返回false且不写。
- **所有权 / 错误 / 调用**：成功返回true；没有容量、范围或可写检查。浮点kind不走此路径，与按class的同类助手不同。

### `writeTruncatingIntegerElement` (`src/core/typed_array.zig:967`)

- **签名**：`noinline fn writeTruncatingIntegerElement(rt: *JSRuntime, kind: u8, bytes: []u8, value: JSValue) !void`。
- **作用**：编码不带clamp的整数元素。
- **实现**：int32直接bitCast为u32，否则coerceNumber后numberToUint32；按kind1/2、4/5、6/7分别存1、2、4字节，其余unreachable。
- **所有权 / 错误 / 调用**：不单独拒绝BigInt，依赖writeNumericElement入口；字符串转换可能分配，bytes须足够。错误发生于转换阶段，完成转换才写。

### `writeClampedElement` (`src/core/typed_array.zig:980`)

- **签名**：`noinline fn writeClampedElement(rt: *JSRuntime, bytes: []u8, value: JSValue) !void`。
- **作用**：编码Uint8Clamped元素。
- **实现**：int32直接夹0–255；其他值coerceNumber后numberToUint8Clamp，写bytes[0]。
- **所有权 / 错误 / 调用**：至少需1字节；BigInt拒绝由外层入口完成。无用户转换，但原语转换可分配或报错。

### `writeFloatingElement` (`src/core/typed_array.zig:992`)

- **签名**：`noinline fn writeFloatingElement(comptime kind: u8, rt: *JSRuntime, bytes: []u8, value: JSValue) !void`。
- **作用**：把原语数值转换成指定浮点字节表示。
- **实现**：先coerceNumber为f64；comptime kind8转f16位型，9转f32位型，10保留f64位型，以little endian写2/4/8字节；其他kind unreachable。
- **所有权 / 错误 / 调用**：不执行范围夹紧或整数取模；窄化可能损失精度。BigInt检查来自外层，bytes须有对应宽度。

### `writeElement` (`src/core/typed_array.zig:1005`)

- **签名**：`pub fn writeElement(rt: *JSRuntime, kind: u8, bytes: []u8, value: JSValue) !void`。
- **作用**：按kind分发单元素编码。
- **实现**：1–10委托writeNumericElement；11/12调用valueToBigInt64Bits并写little endian u64；其他kind返回TypeError。
- **所有权 / 错误 / 调用**：BigInt64和BigUint64存相同低64位位型，读取时再区分符号；不检查视图状态或bytes长度，转换错误传播。

### `valueToBigInt64Bits` (`src/core/typed_array.zig:1013`)

- **签名**：`fn valueToBigInt64Bits(rt: *JSRuntime, value: JSValue) !u64`。
- **作用**：获得BigInt值模2^64的存储位型。
- **实现**：toBigIntValue得到独立临时大整数；取首个limb，没有limb则0，负数用0 -% low取得补码；defer释放临时大整数。
- **所有权 / 错误 / 调用**：丢弃高位不报溢出；转换及克隆可能分配或失败，不修改输入JS BigInt。

### `toBigIntValue` (`src/core/typed_array.zig:1020`)

- **签名**：`fn toBigIntValue(rt: *JSRuntime, value: JSValue) !bignum.BigInt`。
- **作用**：执行底层BigInt编码所需的受限转换。
- **实现**：BigInt克隆，Number直接TypeError，布尔分配0/1。String或Object使用裸runtime字符串化，trim JS空白；空串为0，否则parseAutoAlloc。解析BigIntTooLarge保留，其他解析错误统一SyntaxError；其余类型TypeError。
- **所有权 / 错误 / 调用**：字符串化及前面的clone/fromInt错误直接传播；只有parseAutoAlloc的catch会把其他错误（包括其分配失败）并入SyntaxError。不调用用户ToPrimitive；普通对象常变为对象标签而解析失败，并不等价于规范ToBigInt。成功结果由调用方deinit。

### `toIntegerOrInfinity` (`src/core/typed_array.zig:1042`)

- **签名**：`fn toIntegerOrInfinity(rt: *JSRuntime, value: JSValue) !f64`。
- **作用**：为内部index转换准备f64数值。
- **实现**：Number直接返回，布尔0/1，null为0，undefined为NaN；其余用默认策略appendValueString到临时数组，再parseJsNumber，defer释放数组。
- **所有权 / 错误 / 调用**：名字不代表已经执行整数截断：有限小数原样返回，由调用方trunc。Symbol在默认字符串策略下成为对象标签，解析为NaN；BigInt可格式化为十进制再解析，不是规范ToNumber的类型拒绝规则。

### `toIndexUsize` (`src/core/typed_array.zig:1054`)

- **签名**：`pub fn toIndexUsize(rt: *JSRuntime, value: JSValue) !usize`。
- **作用**：把内部原语转换结果变为非负usize。
- **实现**：toIntegerOrInfinity后，NaN→0，非有限值RangeError；trunc后负数RangeError，零返回0，其余@intFromFloat。
- **所有权 / 错误 / 调用**：-1到0之间的小数截断为负零后得到0。未显式检查2^53-1或usize最大值；超出整数目标范围的有限数可能触发非法转换，不能保证RangeError。用户对象转换必须由外围负责。

### `parseJsNumber` (`src/core/typed_array.zig:1064`)

- **签名**：`fn parseJsNumber(bytes: []const u8) f64`。
- **作用**：将字节串交给共享数字解析器。
- **实现**：直接返回value_format.parseJsNumber(bytes)。
- **所有权 / 错误 / 调用**：无本地解析逻辑或error联合体；语法与空白规则由共享实现决定，不是Zig parseFloat的直接别名。

### `appendValueString` (`src/core/typed_array.zig:1069`)

- **签名**：`fn appendValueString(rt: *JSRuntime, buffer: *std.ArrayList(u8), value: JSValue) AppendStringError!void`。
- **作用**：为本模块调用裸runtime字符串化策略。
- **实现**：委托value_string.appendValueString(rt, buffer, value, .{})，使用默认Policy：Symbol不描述、普通primitive wrapper不额外解包、不支持值使用object_tag。
- **所有权 / 错误 / 调用**：追加到调用方数组而不清空；可能分配并传播AppendStringError。String对象有共享实现的专门解包分支，数组也有专门渲染；不执行用户toString/valueOf，失败不承诺回滚已追加内容。

## 覆盖核对

- 清单函数数: 84（`src/core/typed_array.zig` 81 + `src/core/typed_array_names.zig` 3）
- 本文标题覆盖: 84
- 未覆盖: 无
