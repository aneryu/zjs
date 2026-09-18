# 14e2 — `object_ops.zig`：super/brand、class 方法、Proxy 陷阱

接 [14-object-ops-get-set.md](14-object-ops-get-set.md)。本文件覆盖 `OP_get_super` / brand / `define_class` / `define_method`，以及从原 `proxy_ops.zig` 并入的 Proxy `[[Get]]`/`[[Set]]`/`[[DefineOwnProperty]]`/`[[OwnPropertyKeys]]` 等。

内部类型：`ProxySetKind`（`.value` / `.error_stack`）、`ProxyExtensibleKind`（`.is_extensible` / `.prevent`）、`ProxyGetValidation`（`.valid` / `.invalid` / `.slow`）。

---

### `getSuper` (`src/exec/object_ops.zig:3895`)

- **签名**：`pub noinline fn getSuper( _: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, ) !void`。
- **作用**：`OP_get_super`：把 super 查找的起点对象（home 或栈上源的 `[[Prototype]]`）压栈。
- **实现**：栈非空则 pop 源；空则用 `frame.current_function`。源非对象 → 压 undefined。有栈源：压其 `getPrototype()`，无原型压 null。无栈源：优先 `functionHomeObject()` 的原型（派生类方法的 `super`）；无 home 则退回函数对象自己的原型。不弹失败路径以外的栈槽。
- **所有权 / 错误 / 调用**：`vm_property` 的 get_super。压栈的原型值是 borrowed `prototype.value()`；null/undefined 是 owned 立即数。忽略 ctx。

### `getSuperValue` (`src/exec/object_ops.zig:3929`)

- **签名**：`pub noinline fn getSuperValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`OP_get_super_value`：`super[key]`，getter 的 receiver 是 `this`。
- **实现**：pop prop、obj、receiver。receiver 是 uninitialized → `handleCatchableRuntimeError(ReferenceError)`（派生 this TDZ，`slot_ops.adapterValueIsUninitialized`）。`toPropertyKeyAtom`。obj nullish → TypeError。`expectObject(obj)` 当原型起点，`getSuperPropertyValue`。成功 `push` 结果返回 `.done`；可捕获错误 → `.continue_loop`。
- **所有权 / 错误 / 调用**：不走 mapped arguments 入口特判（从 home 原型起）。结果 owned。

### `putSuperValue` (`src/exec/object_ops.zig:3963`)

- **签名**：`pub noinline fn putSuperValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`OP_put_super_value`：`super[key] = value`，setter/数据写落在 receiver。
- **实现**：pop value、prop、obj、receiver。同样 TDZ ReferenceError、obj nullish TypeError。`toPropertyKeyAtom` 后 `setSuperPropertyValue`。成功 `.done`（不把 value 压回栈）。
- **所有权 / 错误 / 调用**：严格性来自 caller `function`。错误经 `handleCatchableRuntimeError`。

### `setHomeObject` (`src/exec/object_ops.zig:3996`)

- **签名**：`pub noinline fn setHomeObject( ctx: *core.JSContext, stack: *stack_mod.Stack, ) !void`。
- **作用**：`OP_set_home_object`：把栈顶函数的 `[[HomeObject]]` 设成其下的对象。
- **实现**：`stackValueFromTop(0)` 函数、`(1)` home。两者都是对象才 `setFunctionHomeObject`。不 pop。
- **所有权 / 错误 / 调用**：方法定义、`defineClass` 之后由字节码或本 opcode 安装 home。越界 `StackUnderflow`。

### `checkBrand` (`src/exec/object_ops.zig:4008`)

- **签名**：`pub fn checkBrand(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：`OP_check_brand`：栈上 `obj` 是否带有 `func` home 对象的私有 brand。
- **实现**：需要至少 2 个栈槽。`hasPrivateBrand(obj, func)` 为假 → TypeError。
- **所有权 / 错误 / 调用**：不弹栈。VM 包装见 `checkBrandVm`。

### `checkBrandVm` (`src/exec/object_ops.zig:4015`)

- **签名**：`pub noinline fn checkBrandVm( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, ) !Step`。
- **作用**：`OP_check_brand` 的 VM 包装：把 brand TypeError 物化在 **字节码函数 Realm**，再交给本帧 catch。
- **实现**：`checkBrand`。若 `TypeError` 且还不是 pending 异常：用 `frame.current_function` 的 `objectRealmGlobal`（否则调用者 `global`）`throwTypeErrorMessage("invalid brand on object")`。裸 sentinel 若漏到外层，会被调用者的 TypeError 构造器物化，而不是函数 Realm 的。其它错误 / 已挂起异常走 `handleCatchableRuntimeError`。成功 `.done`。
- **所有权 / 错误 / 调用**：`throwTypeErrorMessage` 总是 throw，其后 `unreachable`。私有方法调用站点。

### `addBrand` (`src/exec/object_ops.zig:4045`)

- **签名**：`pub fn addBrand(ctx: *core.JSContext, stack: *stack_mod.Stack) !void`。
- **作用**：`OP_add_brand`：把 home 的 brand 原子定义到实例上。
- **实现**：pop home、obj；root。`ensureHomeObjectBrand`。实例已有该 brand → TypeError。`defineOwnProperty` data undefined。NO-ALIGN(qjs)：`JS_AddBrand`（`quickjs.c:8464`）忽略可扩展性；test262 要求非扩展 TypeError。
- **所有权 / 错误 / 调用**：构造器末尾给实例打 brand。

### `addBrandVm` (`src/exec/object_ops.zig:4070`)

- **签名**：`pub noinline fn addBrandVm( ctx: *core.JSContext, output: ?*std.Io.Writer, stack: *stack_mod.Stack, frame: *frame_mod.Frame, catch_target: *?usize, global: *core.Object, ) !Step`。
- **作用**：`OP_add_brand` 的 VM 包装：错误进本帧 catch。
- **实现**：`addBrand`；失败 `handleCatchableRuntimeError`，命中 handler → `.continue_loop`。成功 `.done`。
- **所有权 / 错误 / 调用**：class 构造器收尾。`addBrand` 自己 root 住 home/obj。

### `privateIn` (`src/exec/object_ops.zig:4085`)

- **签名**：`pub fn privateIn( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, ) !void`。
- **作用**：`#x in obj`：私有 brand 或 own 私有字段。
- **实现**：pop key、obj。obj 非对象 → `"invalid 'in' operand"`。key 是对象 → `hasPrivateBrand`（方法当 key）；否则 ToPropertyKey + `hasOwnProperty`。推布尔。
- **所有权 / 错误 / 调用**：私有 `in` 不沿原型。

### `privateInVm` (`src/exec/object_ops.zig:4109`)

- **签名**：`pub noinline fn privateInVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`#x in obj` opcode 的 VM 包装。
- **实现**：`privateIn`；失败 `handleCatchableRuntimeError`。成功 `.done`（布尔已由 `privateIn` 压栈）。
- **所有权 / 错误 / 调用**：与 `inOp` 分开：私有 `in` 不沿原型、不走 `has` trap。

### `defineClass` (`src/exec/object_ops.zig:4125`)

- **签名**：`pub noinline fn defineClass( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, is_computed_name: bool, ) !Step`。
- **作用**：`OP_define_class` / 计算名变体：装配 constructor ↔ prototype 环、heritage、home object。
- **实现**：读 u32 atom + u8 flags，pc+=5。pop ctor 源与 parent。root 一组临时值（ctor/proto/superclass/name…）。`flags&1`：有父类，须对象或 null；若弹出的 parent 是 undefined 且栈上还有值，则再 pop 真正的 superclass，并把 undefined 当作 `saved_class_binding` 事后压回。`createClassBytecodeFunctionObject`。计算名：栈顶 ToPropertyKey 设 `name`。默认 `proto_parent=%Object.prototype%`。父类是对象：须 `isConstructorLike`；ctor `[[Prototype]]`=superclass；取 `superclass.prototype`，对象则当 proto 父，非 null 则 TypeError。父类是 null：proto 无原型。`Object.create` proto；`constructor` 为 W=true/E=false/C=true，ctor.`prototype` 为 W=E=C=false；`setFunctionHomeObject(proto)`。压 ctor、proto（若有 saved binding 先压回）。
- **所有权 / 错误 / 调用**：heritage / 计算名 / 不可构造父类 的错误经 `handleCatchableRuntimeError`。ctor 源所有权交给 `createClassBytecodeFunctionObject`。

### `defineMethod` (`src/exec/object_ops.zig:4228`)

- **签名**：`pub noinline fn defineMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`OP_define_method`：具名方法定义到栈上对象。
- **实现**：读 u32 atom，pc+=4；读 u8 flags，pc+=1。`defineObjectMethod`。失败进 catch。
- **所有权 / 错误 / 调用**：对象留在栈上。flags 编码 getter/setter/enumerable，见 `defineObjectMethodValue`。

### `defineMethodComputed` (`src/exec/object_ops.zig:4248`)

- **签名**：`pub noinline fn defineMethodComputed( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, catch_target: *?usize, ) !Step`。
- **作用**：`OP_define_method_computed`：计算键方法。
- **实现**：读 u8 flags，pc+=1。pop value、key。`toPropertyKeyAtom`；`defineObjectMethodValue`。键转换或 define 失败进 catch。
- **所有权 / 错误 / 调用**：私有 atom 由 `defineObjectMethodValue` 拒成 `InvalidBytecode`。

### `defineObjectMethod` (`src/exec/object_ops.zig:4272`)

- **签名**：`fn defineObjectMethod( rt: *core.JSRuntime, stack: *stack_mod.Stack, atom_id: core.Atom, flags: u8, ) !void`。
- **作用**：栈顶方法定义到其下的对象（具名方法）。
- **实现**：栈不足 2：若顶是对象则返回（空方法？），否则 StackUnderflow。pop value，`defineObjectMethodValue`。
- **所有权 / 错误 / 调用**：`defineMethod` opcode。

### `defineObjectMethodValue` (`src/exec/object_ops.zig:4287`)

- **签名**：`fn defineObjectMethodValue( rt: *core.JSRuntime, stack: *stack_mod.Stack, atom_id: core.Atom, value: core.JSValue, flags: u8, ) !void`。
- **作用**：真正定义：home object、name、data 或 accessor 合并。
- **实现**：peek 对象。private atom → InvalidBytecode。值是对象则 `setFunctionHomeObject`，flags&3 为 1/2 时 name 前缀 get/set。enumerable = flags&4。getter/setter：读已有 accessor 合并另一半。data：W/E/C 中 W/C=true。不兼容 → TypeError。
- **所有权 / 错误 / 调用**：对象留在栈上。

### `stackValueFromTop` (`src/exec/object_ops.zig:4350`)

- **签名**：`fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue`。
- **作用**：从栈顶向下第 `offset` 个值（0=顶）。
- **实现**：越界 StackUnderflow。
- **所有权 / 错误 / 调用**：borrowed。`setHomeObject`、computed class name。

### `ensureHomeObjectBrand` (`src/exec/object_ops.zig:4356`)

- **签名**：`fn ensureHomeObjectBrand(rt: *core.JSRuntime, home: *core.Object) !core.Atom`。
- **作用**：home 上 `Private_brand` 数据属性：已有则取出 symbol atom，否则 mint 私有 symbol。
- **实现**：已有非 symbol → TypeError。不可扩展 → NotExtensible（单测：不分配 atom）。`newSymbol(name, .private)` + define。
- **所有权 / 错误 / 调用**：brand atom 由 home 对象持有，home 死后随 GC 释放。

### `hasPrivateBrand` (`src/exec/object_ops.zig:4369`)

- **签名**：`fn hasPrivateBrand(rt: *core.JSRuntime, obj: core.JSValue, func: core.JSValue) !bool`。
- **作用**：obj 是否 own 了 func.home 的 brand atom。
- **实现**：func 须有 `functionHomeObject`；home 须有 `Private_brand` symbol；`object.hasOwnProperty(brand_atom)`。
- **所有权 / 错误 / 调用**：缺 home/brand → TypeError。

### `readInt` (`src/exec/object_ops.zig:4378`)

- **签名**：`fn readInt(comptime T: type, bytes: []const u8) T`。
- **作用**：小端读 opcode 立即数。
- **实现**：`std.mem.readInt(..., .little)`。
- **所有权 / 错误 / 调用**：只读字节、不分配、无 error set。调用方是 `defineClass`（`object_ops.zig:4135`）与 `defineMethod`（`:4237`），都只用它读 u32 atom 立即数；紧随其后的单字节 flags 是直接从 `function.byteCode()` 取的，不经本函数。

### `proxySetWithTrap` (`src/exec/object_ops.zig:4424`)

- **签名**：`noinline fn proxySetWithTrap( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, proxy: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, kind: ProxySetKind, ) HostError!bool`。
- **作用**：Proxy `[[Set]]` 陷阱走查的合并体：`.value` 是普通赋值，`.error_stack` 是 `Error.stack` 安装。
- **实现**：无 target：`.error_stack` → false，`.value` → TypeError。无 handler TypeError。Get handler.`set`。缺 trap：`.error_stack` 不转发 OrdinarySet（false）；`.value` → `ordinarySetWithReceiver`。trap 不可调用 TypeError。调用 `(target, key, value, receiver)`。假值：`.error_stack` TypeError，`.value` false（调用方按严格性抛）。真则 `validateProxySetResult`，返回 true。显式 `HostError` 避免与 `ordinarySetWithReceiver` 推断 error set 循环。不折叠 PreventExtensions / IsExtensible。
- **所有权 / 错误 / 调用**：`proxySetValueProperty`（`.value`）、`proxySetTrapForErrorStackSetter`（`.error_stack`）。公开名保持 inline，只传 kind。

### `proxySetTrapForErrorStackSetter` (`src/exec/object_ops.zig:4462`)

- **签名**：`pub inline fn proxySetTrapForErrorStackSetter( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, receiver: *core.Object, stack_key: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!bool`。
- **作用**：给 Error.stack 赋值时走 Proxy set；缺 target 返回 false 而不是 TypeError。
- **实现**：`proxySetWithTrap(..., .error_stack)`。缺 trap 返回 false（不转发 OrdinarySet）。trap 假 → TypeError。
- **所有权 / 错误 / 调用**：error stack 安装与用户 Proxy 交叉。显式 HostError 避免与 `ordinarySetWithReceiver` 的 error set 循环。

### `proxyCreateDataPropertyOrThrow` (`src/exec/object_ops.zig:4476`)

- **签名**：`pub fn proxyCreateDataPropertyOrThrow( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, proxy: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：CreateDataPropertyOrThrow 的 Proxy 臂：`defineProperty` trap 或直接在 target 上 define W/E/C=true。
- **实现**：缺 target/handler TypeError。缺 trap → target.defineOwnProperty data。trap 须可调用；造描述符对象（`value` 加 writable/enumerable/configurable 三个 true）；调用；假值 TypeError。忽略 receiver。
- **所有权 / 错误 / 调用**：fromEntries 等。此处不跑完整 define invariant（throw 语义要求 trap 真）。

### `validateProxyOwnKeysResult` (`src/exec/object_ops.zig:4513`)

- **签名**：`pub fn validateProxyOwnKeysResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source: *core.Object, target_value: core.JSValue, result_keys: []const core.Atom, ) HostError!void`。
- **作用**：ownKeys trap 结果相对 target 的 invariant（`js_proxy_get_own_property_names`，`quickjs.c:51219`）。
- **实现**：先 `proxyAwareIsExtensible(target)`（嵌套 Proxy 会打 isExtensible）。handler 已撤销 → TypeError。取 target ownKeys。对每个 target 键再 gopd（可再 trap）；不可配置或 target 不可扩展的键必须出现在 result 中。不可扩展时 result 每个键都必须对应某个「找到描述符」的 target 键（qjs `tab[idx].is_enumerable` 标记）。
- **所有权 / 错误 / 调用**：ownKeys 循环中途可能 revoke。

### `proxyAwareOwnPropertyDescriptor` (`src/exec/object_ops.zig:4559`)

- **签名**：`pub fn proxyAwareOwnPropertyDescriptor( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source: *core.Object, key: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.Descriptor`。
- **作用**：`[[GetOwnProperty]]`：TypedArray canonical、普通 getOwnProperty、或 Proxy gopd trap。
- **实现**：非 Proxy：`typedArrayCanonicalOwnDescriptor` 否则 `getOwnProperty`。Proxy：Get `getOwnPropertyDescriptor`；缺 trap 递归。调用 trap；undefined 时若 target 有不可配置描述符或不可扩展 → TypeError。结果须对象；`descriptorFromObject` + `completeProxyDescriptor`；`isCompatibleProxyDescriptor`；configurable:false 还要求 target 已有且不可配置，且不能把可写 data 报成不可写。
- **所有权 / 错误 / 调用**：HasOwn / gopd / integrity / assign exotic 源。

### `proxyAwareExistsOwnProperty` (`src/exec/object_ops.zig:4616`)

- **签名**：`pub fn proxyAwareExistsOwnProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source: *core.Object, key: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：存在性兄弟：非 Proxy 对齐 `JS_GetOwnPropertyInternal(NULL)`（不建描述符、不 dup、不物化 auto-init 值）；Proxy **必须** 走完整 gopd 以便 trap 开火。
- **实现**：非 Proxy：`typedArrayCanonicalIndexExists` 否则 `existsOwnProperty`。Proxy：gopd != null。
- **所有权 / 错误 / 调用**：`Object.hasOwn`、`hasOwnProperty`。

### `proxyAwareExtensibleOp` (`src/exec/object_ops.zig:4646`)

- **签名**：`noinline fn proxyAwareExtensibleOp( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, kind: ProxyExtensibleKind, ) HostError!bool`。
- **作用**：`[[IsExtensible]]` / `[[PreventExtensions]]` 陷阱走查的合并体。
- **实现**：非 Proxy：`.is_extensible` 读 `object.isExtensible()`；`.prevent` 调 `preventExtensions()` 返回 true。有 Proxy：无 target/handler TypeError。Get `isExtensible` 或 `preventExtensions` trap。缺 trap 对 target 递归同一 kind。trap 不可调用 TypeError。调用 `([target])`。`.is_extensible`：结果须等于 target 的 IsExtensible，否则 TypeError。`.prevent`：假 → false；真则 target 必须已不可扩展，否则 TypeError。显式 `HostError` 避免 Prevent 的 IsExtensible 检查与缺 trap 递归形成推断 error set 循环。不折叠 SetPrototypeOf，不重试 `[[Set]]`。
- **所有权 / 错误 / 调用**：`proxyAwareIsExtensible` / `proxyAwarePreventExtensions` 各传一个 kind。ownKeys/gopd invariant 会打 isExtensible trap。

### `proxyAwareIsExtensible` (`src/exec/object_ops.zig:4697`)

- **签名**：`pub inline fn proxyAwareIsExtensible( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!bool`。
- **作用**：`[[IsExtensible]]`。
- **实现**：`proxyAwareExtensibleOp(..., .is_extensible)`。非 Proxy 读标志。Proxy：Get trap；缺则递归；结果必须等于 target 的 IsExtensible。
- **所有权 / 错误 / 调用**：ownKeys/gopd/setPrototypeOf invariant。

### `proxyAwarePreventExtensions` (`src/exec/object_ops.zig:4708`)

- **签名**：`pub inline fn proxyAwarePreventExtensions( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!bool`。
- **作用**：`[[PreventExtensions]]`。
- **实现**：非 Proxy：`preventExtensions()` 返回 true。Proxy：trap 假 → false；真则 target 必须已不可扩展否则 TypeError。
- **所有权 / 错误 / 调用**：`Object.preventExtensions` / seal/freeze。

### `proxyAwareSetPrototypeOf` (`src/exec/object_ops.zig:4719`)

- **签名**：`pub fn proxyAwareSetPrototypeOf( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, prototype: ?*core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：`[[SetPrototypeOf]]`。
- **实现**：无 proxy：`setPrototype`，循环/不可扩展 → false。有 trap：调用 `(target, proto)`；假 → false；target 不可扩展则其原型必须等于请求原型。
- **所有权 / 错误 / 调用**：Object/Reflect.setPrototypeOf。

### `completeProxyDescriptor` (`src/exec/object_ops.zig:4751`)

- **签名**：`pub fn completeProxyDescriptor(rt: *core.JSRuntime, desc: core.Descriptor) !core.Descriptor`。
- **作用**：把部分描述符补成完整 data/accessor（缺省 false / undefined）。
- **实现**：忽略 rt。generic/data → data；accessor → accessor。
- **所有权 / 错误 / 调用**：gopd trap 结果在 invariant 前。

### `isCompatibleProxyDescriptor` (`src/exec/object_ops.zig:4769`)

- **签名**：`pub fn isCompatibleProxyDescriptor(extensible: bool, current: ?core.Descriptor, desc: core.Descriptor) !bool`。
- **作用**：ValidateAndApplyPropertyDescriptor 风格的兼容性（Proxy invariant）。
- **实现**：无 current → 仅当 extensible。current 可配置 → true。desc 声称可配置 → false。enumerable 冲突 → false。generic desc 通过。accessor/data 种类必须一致。current 不可写 data：不能变可写，value 必须 SameValue。accessor 的 get/set 若 present 必须 SameValue。
- **所有权 / 错误 / 调用**：返回 bool，调用方变 TypeError。

### `proxyTargetIsCallable` (`src/exec/object_ops.zig:4791`)

- **签名**：`pub fn proxyTargetIsCallable(value: core.JSValue) bool`。
- **作用**：Proxy 链的 target 是否可调用（bytecode / 函数对象 / C 函数 / 再套 Proxy）。
- **实现**：递归 `proxyTargetIsCallable(target)`。
- **所有权 / 错误 / 调用**：`typeof` / call 检查。

### `proxyTargetIsConstructor` (`src/exec/object_ops.zig:4797`)

- **签名**：`pub fn proxyTargetIsConstructor(ctx: *core.JSContext, value: core.JSValue) error{OutOfMemory}!bool`。
- **作用**：target 是否 `isConstructorLike`。
- **实现**：解开一层 proxy target。
- **所有权 / 错误 / 调用**：`constructProxy` 入口。

### `callProxyApply` (`src/exec/object_ops.zig:4803`)

- **签名**：`pub fn callProxyApply( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, proxy_value: core.JSValue, proxy: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`[[Call]]`：`apply` trap 或转发 target。
- **实现**：撤销 → 用 **当前 global** 物化 `"revoked proxy"`（不是错误浮现处的 realm）。缺 trap → `callValueOrBytecodeSyncInternal(this, target, args)`。有 trap：args 收成数组，调用 `(target, this, argArray)`。
- **所有权 / 错误 / 调用**：忽略 proxy_value。

### `constructProxy` (`src/exec/object_ops.zig:4830`)

- **签名**：`pub fn constructProxy( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, proxy_value: core.JSValue, proxy: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, new_target_value: core.JSValue, ) !core.JSValue`。
- **作用**：`[[Construct]]`。
- **实现**：target 不可 construct → TypeError。撤销消息同 apply。缺 `construct` trap：**带着原始 new.target** 再进 `constructValueOrBytecodeWithNewTarget`（不把 bound 链拍平；qjs 每层 Proxy/Bound 入口都要轮询，native 构造器仍需原始 new.target 做原型查找）。trap 结果必须是对象。
- **所有权 / 错误 / 调用**：arg 数组第三参是 newTarget。

### `getProxyProperty` (`src/exec/object_ops.zig:4863`)

- **签名**：`pub fn getProxyProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, proxy: *core.Object, atom_id: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!core.JSValue`。
- **作用**：Proxy `[[Get]]`。
- **实现**：撤销带消息。handler.`get` 先 `ordinaryDataPropertyValueOrUndefinedForFastPath`，失败才完整 Get。缺 trap：target 同样快探，否则 `getValuePropertyWithReceiver`。有 trap：调用 `(target, key, receiver)`，`validateProxyGetResult`。
- **所有权 / 错误 / 调用**：这是 exotic Get 的主陷阱。快探保证不跑 handler 上的 getter 副作用当 `get` 是普通 data。

### `validateProxyGetResult` (`src/exec/object_ops.zig:4892`)

- **签名**：`pub fn validateProxyGetResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, atom_id: core.Atom, result: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：get trap 结果相对 target 不可配置属性的 invariant。
- **实现**：`validatePlainProxyGetResultFast`：valid 返回；invalid TypeError；slow 则完整 gopd。不可配置 data 且不可写：结果须 SameValue。不可配置 accessor 无 getter：结果须 undefined。
- **所有权 / 错误 / 调用**：qjs `js_proxy_get` 在 trap 后 `JS_GetOwnPropertyInternal`。

### `validatePlainProxyGetResultFast` (`src/exec/object_ops.zig:4928`)

- **签名**：`fn validatePlainProxyGetResultFast(target: *core.Object, atom_id: core.Atom, result: core.JSValue) ProxyGetValidation`。
- **作用**：普通 target 上不物化 Descriptor 的 get invariant。
- **实现**：非普通 object（array/global/with/proxy/exotic）→ slow。无该属性 → valid。可配置 → valid。data：writable 或 SameValue。accessor：getter 非 undefined 或结果 undefined。var_ref/auto_init → slow。
- **所有权 / 错误 / 调用**：两 invariant 才拒绝：冻数据值、无 getter 的不可配置 accessor。

### `firstProxyInPrototypeSetPath` (`src/exec/object_ops.zig:4948`)

- **签名**：`pub fn firstProxyInPrototypeSetPath(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?*core.Object`。
- **作用**：Set 在 own 未处理时，原型链上第一个 Proxy；若中途有 own 该键则停止（不是「穿过」）。
- **实现**：从 `getPrototype()` 走；有 proxy target 返回该原型；`getOwnProperty` 非 null 返回 null。
- **所有权 / 错误 / 调用**：`setValuePropertyWithThrow` 在 accessor 之后。

### `proxySetValueProperty` (`src/exec/object_ops.zig:4957`)

- **签名**：`pub inline fn proxySetValueProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, proxy: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) HostError!bool`。
- **作用**：Proxy `[[Set]]` 公开入口。
- **实现**：`proxySetWithTrap(..., .value)`。缺 trap → `ordinarySetWithReceiver`。trap 假 → false（调用方按严格性抛）。真则 `validateProxySetResult`。
- **所有权 / 错误 / 调用**：Error.stack 用另一 kind。

### `validateProxySetResult` (`src/exec/object_ops.zig:4971`)

- **签名**：`pub fn validateProxySetResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：set trap 成功后的 invariant。
- **实现**：target 无描述符返回。可配置返回。不可配置不可写 data：value 须 SameValue。不可配置 accessor 无 setter → TypeError。
- **所有权 / 错误 / 调用**：与 get invariant 对称。

### `proxyDefineValueForReflectSet` (`src/exec/object_ops.zig:4994`)

- **签名**：`pub fn proxyDefineValueForReflectSet( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, proxy: *core.Object, atom_id: core.Atom, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：Reflect.set 在 receiver 是 Proxy 时：先可选触发 gopd trap，再 defineProperty 只带 `value`。
- **实现**：root 住 value/key/desc。handler 上的 gopd 非 undefined/null 时：不可调用 → TypeError，否则先调用一次（结果丢掉）。define 缺 trap → target.define data W/E/C=true。有 trap：描述符对象只定义 `value`；假 → TypeError。
- **所有权 / 错误 / 调用**：与完整 `proxyDefineOwnProperty` 不同：这是 Set 落到 receiver 上的 define，不是用户 `defineProperty`。

### `proxyTargetIsCallableObject` (`src/exec/object_ops.zig:5043`)

- **签名**：`pub fn proxyTargetIsCallableObject(object: *core.Object) bool`。
- **作用**：对象本身是函数类，或 Proxy 且 target 可调用。
- **实现**：`isFunctionLikeClass` 真。非 Proxy 假。解开 target 同 `proxyTargetIsCallable`。
- **所有权 / 错误 / 调用**：已有 `*Object` 时免 JSValue 包装。

### `proxyDefineOwnProperty` (`src/exec/object_ops.zig:5050`)

- **签名**：`pub fn proxyDefineOwnProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, proxy: *core.Object, atom_id: core.Atom, desc: core.Descriptor, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：Proxy `[[DefineOwnProperty]]`。
- **实现**：缺 trap：target 仍是 Proxy 则递归，否则 `defineOwnProperty`（只读等 → false）。有 trap：描述符对象 `descriptorObjectFromDescriptor`；假 → false。然后 gopd target；**可扩展性读 raw `target.isExtensible()`**，不打 isExtensible trap（`js_proxy_define_own_property`，`quickjs.c:51060`）。`isCompatibleProxyDescriptor`；设置 configurable:false 要求 target 已有不可配置；不可把不可配置可写 data 收成不可写。
- **所有权 / 错误 / 调用**：返回成功布尔。

### `validateProxyHasResult` (`src/exec/object_ops.zig:5099`)

- **签名**：`pub fn validateProxyHasResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, target: *core.Object, atom_id: core.Atom, result: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !bool`。
- **作用**：has trap 返回假时的 invariant。
- **实现**：result 真 → true。假：target gopd（嵌套会 trap）；不可配置 TypeError；**可扩展性用 raw `target.isExtensible()`，不打 isExtensible trap**（`js_proxy_has`，`quickjs.c:50765`，与 delete 相反）。
- **所有权 / 错误 / 调用**：返回 false 表示「没有」。

### `proxyTrapKeyValue` (`src/exec/object_ops.zig:5122`)

- **签名**：`pub fn proxyTrapKeyValue(rt: *core.JSRuntime, atom_id: core.Atom) !core.JSValue`。
- **作用**：把 atom 变成传给 trap 的 string/symbol 值。
- **实现**：公开 symbol kind → `symbolValue`；否则 `toStringValue`。
- **所有权 / 错误 / 调用**：所有 trap 的 key 参数。

## 覆盖核对

- 清单函数数（本文件分到）: 46（`src/exec/object_ops.zig` 全文件 194）
- 本文标题覆盖: 46
- 未覆盖: 无

`object_ops.zig` 四篇合计 67+28+53+46 = 194。
