# 06 — atom intern 与 Symbol

本分册：`src/core/atom.zig`、`src/core/symbol.zig`。intern 总览见 [06-core-value.md](06-core-value.md) §4。

## 类型与表驱动数据

`Atom = u32`。`null_atom=0`。`tagged_int_bit = 1<<31`。`max_int_atom = tagged_int_bit-1`。`max_array_index = 0xfffffffe`。

`AtomKind = enum { string, symbol, global_symbol, private }`。

`PredefinedAtom { id, name, kind=.string }`。`ids` 把关键字、well-known symbols、内建名字钉成 comptime 常量。`predefined_atoms` 长度 692（comptime assert `predefined_count==692`），id 按 1..692 连续排列：676 个 string、15 个 symbol（217..231）及 1 个 private（216，`<brand>`），无 global_symbol。`first_dynamic_atom = 693`；`last_keyword=46`（await）、`last_strict_keyword=45`（yield）。各 zjs_last_* 是分组末项的别名，不是额外条目。

`predefinedId` 的预定义字符串查找走 2048 槽 Wyhash 开地址表 `predefined_string_hash_table`（seed 0）；symbol/private 走 `StaticStringMap`。动态与预定义字符串共用 qjs 链式 `atom_hash`：`hash_string8`（`h = h*%263 +% c`，seed=atom type），32 位拼写哈希存在条目里，链走 `hash_next`。unique symbol / private 不入链（qjs `JS_ATOM_TYPE_SYMBOL` 不进 `atom_hash`，quickjs.c:3316）。

`DynamicAtom`：id、owned `bytes`、lazy `str`、`next_free`、`hash`/`hash_next`、`kind`、`occupied`、`mark_epoch`/`born_epoch`、`host_pins`、`registry_managed_symbol`、`weakref_count`、`no_symbol_description`。**无 `ref_count`。** 唯一非堆计数是 `host_pins` 与 WeakRef 壳的 `weakref_count`。

`AtomTable`：entries 几何增长（长度包含已分配但空闲的槽，不是存活数）、free-slot LIFO、可选 ownership-audit 隔离区、`predefined_str` 缓存、`compile_scope`、`young_symbol_atoms`（minor 额外根）、审计计数。源文件顶部及部分字段仍有 refcount/free 的历史注释；当前 DynamicAtom 无 ref_count，不能据此要求每个 intern 结果做 RC 释放。

`CompileAtomScope`：编译期 plain-u32 atom 字段的区间记录，持有 rt/table/allocator、ids、prev、active/registered 及 64 槽 direct-mapped `recent`。只有 activate 在相关配置开启且有 runtime 时注册 provider；过滤冲突可重复记录，不会把不同 id 当成命中。

`ownership_audit_enabled` 直接来自构建选项 `-Dzjs_ownership_audit`。`OwnershipAuditState` 开启时只有 quarantined_head，关闭时为空结构；槽仍可在后续 sweep 复用，这不是全程禁止复用或防止所有陈旧 id 误用的保证。`EntryIndex=u32`，`no_free_slot=maxInt(u32)`；桶计数只统计入链项，初始 1024 桶、阈值 2048。`EdgeMode` 的 stamp/observe 分别控制是否改 epoch 和审计计数。

`registry_managed_symbol` 当前会被驻留/清理路径写入，但没有读取分支；可观察的注册类别判断依赖 global_symbol kind 或链查询。`runtime` 与 `owner_runtime` 是分别声明的可空指针，GC epoch、屏障及编译作用域主要使用后者；init 不自动绑定它们。

## 顶层谓词

### `isPublicSymbolKind` (`src/core/atom.zig:37`)

- **签名**：`pub fn isPublicSymbolKind(kind: AtomKind) bool`。
- **作用**：判断 kind 是否属于公开 Symbol 类别。
- **实现**：symbol 或 global_symbol 返回 true，string/private 返回 false。
- **所有权 / 错误 / 调用**：纯 kind 判断，不验证 atom 是否存在、注册或仍存活。

### `isValueSymbolKind` (`src/core/atom.zig:41`)

- **签名**：`pub fn isValueSymbolKind(kind: AtomKind) bool`。
- **作用**：判断是否使用符号体表示身份的 kind。
- **实现**：symbol、global_symbol、private 为 true，仅 string 为 false。
- **所有权 / 错误 / 调用**：不检查条目当前是否有 body，供符号体及回收逻辑分类。

### `predefinedKindCount` (`src/core/atom.zig:953`)

- **签名**：`fn predefinedKindCount(comptime kind: AtomKind) comptime_int`。
- **作用**：统计指定 kind 的预定义项数。
- **实现**：遍历 predefined_atoms，仅匹配 kind 时增加 comptime 计数。
- **所有权 / 错误 / 调用**：编译期操作，用于生成固定长度映射数组，无运行时分配。

### `makePredefinedMapEntries` (`src/core/atom.zig:961`)

- **签名**：`fn makePredefinedMapEntries(comptime kind: AtomKind) [predefinedKindCount(kind)]PredefinedMapEntry`。
- **作用**：生成指定 kind 的 name/id 映射数组。
- **实现**：按预定义表顺序筛选，填入二元组，长度由 predefinedKindCount 决定。
- **所有权 / 错误 / 调用**：名称切片引用静态数据；用于 symbol/private 的 StaticStringMap，不复制字符串存储。

### `predefinedStringIdHashed` (`src/core/atom.zig:1005`)

- **签名**：`inline fn predefinedStringIdHashed(bytes: []const u8, hash: u64) ?Atom`。
- **作用**：在静态字符串表中查找预定义 id。
- **实现**：以 hash 的低 11 位选择 2048 槽表位置，线性探测，空槽返回 null，比较名称相等后返回 id；最多探测全表，耗尽为 unreachable。
- **所有权 / 错误 / 调用**：调用方须传与表构建一致的 Wyhash(seed=0)，不是 spellingHash。表项在编译期断言不属于 parseArrayIndex 可编码的数字名；不分配。

## `DynamicAtom`

### `DynamicAtom.isLive` (`src/core/atom.zig:1069`)

- **签名**：`pub fn isLive(self: DynamicAtom) bool`。
- **作用**：读取条目的占用标志。
- **实现**：直接返回 occupied；occupied=false 的弱壳不算 live。
- **所有权 / 错误 / 调用**：这是条目状态，不是一次 GC 可达性判断，也不保证 str 存在。

### `DynamicAtom.slotOccupied` (`src/core/atom.zig:1073`)

- **签名**：`pub fn slotOccupied(self: DynamicAtom) bool`。
- **作用**：判断槽是否仍被条目或弱引用壳占用。
- **实现**：返回 occupied 或 weakref_count 非零。
- **所有权 / 错误 / 调用**：弱壳会阻止槽复用，但不因此保活符号体；无状态修改。

## 哈希

### `atomHashSeed` (`src/core/atom.zig:1119`)

- **签名**：`fn atomHashSeed(kind: AtomKind) u64`。
- **作用**：为拼写哈希选择 kind 种子。
- **实现**：string=0，global_symbol=1，symbol/private=2。
- **所有权 / 错误 / 调用**：不同种子区分哈希输入，但不是桶索引无碰撞保证；symbol/private 不进入驻留链。

### `spellingHash` (`src/core/atom.zig:1130`)

- **签名**：`fn spellingHash(bytes: []const u8, kind: AtomKind) u32`。
- **作用**：计算 32 位拼写哈希。
- **实现**：从 kind 种子开始，每个字节做 h*%263+%c，使用 u32 环绕运算。
- **所有权 / 错误 / 调用**：无分配、按字节计算；与静态预定义字符串开地址表使用的 Wyhash 不同。

## `AtomTable` 生命周期与根

### `AtomTable.traceRoots` (`src/core/atom.zig:1297`)

- **签名**：`pub fn traceRoots(self: *AtomTable, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void`。
- **作用**：把已物化的预定义缓存体报告为根。
- **实现**：遍历 predefined_str，将非空 body.header 包装为 JSValue.string 交给 visitor.constValue。
- **所有权 / 错误 / 调用**：visitor 错误传播；不扫描动态 entries。动态符号体由持有者边和 minor 的额外路径处理，不能把所有动态缓存视为表根。

### `AtomTable.traceYoungSymbolBodies` (`src/core/atom.zig:1306`)

- **签名**：`pub fn traceYoungSymbolBodies(self: *AtomTable, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void`。
- **作用**：报告 young_symbol_atoms 中当前仍绑定的符号体。
- **实现**：逐 id 查动态条目，跳过无条目、未占用、非 value-symbol 或无 str 的项；其余向 visitor 报告 body。
- **所有权 / 错误 / 调用**：minor 路径调用，visitor 错误传播。列表没有槽位代次：若 id 已复用为另一符号体，可能额外保留新 body 一次；并非所有复用项都跳过。

### `AtomTable.youngListAllocator` (`src/core/atom.zig:1316`)

- **签名**：`inline fn youngListAllocator(self: *AtomTable) std.mem.Allocator`。
- **作用**：选择 young 符号 id 列表使用的持久分配器。
- **实现**：有 owner_runtime 时取 rt.memory.persistent_allocator，否则取 self.memory.persistent_allocator。
- **所有权 / 错误 / 调用**：两条分支都使用 persistent_allocator；该函数只返回分配器，不分配。

### `AtomTable.retireYoungSymbolBodies` (`src/core/atom.zig:1324`)

- **签名**：`pub fn retireYoungSymbolBodies(self: *AtomTable) void`。
- **作用**：结束额外 young 符号根列表的当前区间。
- **实现**：对列表 clearRetainingCapacity，不逐项销毁符号体。
- **所有权 / 错误 / 调用**：由 minor 提升和 major 的 clearYoungState 等路径调用；容量保留，之后按正常持有者边决定可达性。

### `AtomTable.init` (`src/core/atom.zig:1328`)

- **签名**：`pub fn init(account: *memory.MemoryAccount) AtomTable`。
- **作用**：构造尚未分配动态存储的 atom 表。
- **实现**：只指定 memory，其余字段采用默认值，包括空 entries/hash、空缓存和 null runtime 指针。
- **所有权 / 错误 / 调用**：无分配、不会失败；runtime/owner_runtime 关联由外部安装，不自动完成。

### `AtomTable.deinit` (`src/core/atom.zig:1332`)

- **签名**：`pub fn deinit(self: *AtomTable) void`。
- **作用**：释放 atom 表自身的列表、桶、拼写和条目存储。
- **实现**：先销毁 young 列表，保存 entries/backing 并清空字段，释放桶；断言全部预定义及动态 str 已空，释放非空 bytes；重置 self 为仅保留 memory 的初始状态，再释放 backing。
- **所有权 / 错误 / 调用**：调用前必须在正确 GC teardown 顺序中清除缓存体指针；本函数不替调用方销毁 body。entries.len 包含空闲槽，不等于活条目数。

### `AtomTable.releaseCachedStrings` (`src/core/atom.zig:1360`)

- **签名**：`pub fn releaseCachedStrings(self: *AtomTable) void`。
- **作用**：在 GC teardown 前解除表对缓存体的关联。
- **实现**：清 young 列表但保留容量；预定义 str 置 null，允许静态 id 回指保留；动态 str 置 null，并把原 body.atom_id 设为 no_atom_id。
- **所有权 / 错误 / 调用**：不释放 body、不释放条目 bytes，也不改变 occupied；必须在 body 内存仍有效时执行。实际 body 存储随后由 GC teardown 回收。

### `AtomTable.releaseValueSymbolBodiesAfterGc` (`src/core/atom.zig:1388`)

- **签名**：`pub fn releaseValueSymbolBodiesAfterGc(self: *AtomTable) void`。
- **作用**：清除 GC teardown 后残留的动态符号体指针。
- **实现**：只遍历 value-symbol kind，将非空 str 置 null，不解引用 body。
- **所有权 / 错误 / 调用**：不释放内存、不清 occupied/弱引用计数，不处理普通 string 缓存；通常前一步 releaseCachedStrings 已清空这些槽。

## 链

### `AtomTable.hashNextPtr` (`src/core/atom.zig:1399`)

- **签名**：`inline fn hashNextPtr(self: *AtomTable, id: Atom) *Atom`。
- **作用**：取得有效 atom id 对应的可变链指针。
- **实现**：预定义 id 使用 predefined_hash_next[id−1]，动态 id 使用 entries[id−first_dynamic_atom].hash_next。
- **所有权 / 错误 / 调用**：借用表内地址；调用者保证 id 非零、不是 tagged-int 且索引有效，没有通用有效性检查。动态 entries 扩容会使返回地址失效。

### `AtomTable.storedHash` (`src/core/atom.zig:1407`)

- **签名**：`inline fn storedHash(self: *const AtomTable, id: Atom) u32`。
- **作用**：读取有效 atom id 已存储的拼写哈希。
- **实现**：预定义项读取静态 predefined_hash，动态项读取 entry.hash。
- **所有权 / 错误 / 调用**：要求 id 为有效表索引；不重算拼写、不验证占用状态，供重接链等操作使用。

### `AtomTable.initAtomHash` (`src/core/atom.zig:1418`)

- **签名**：`fn initAtomHash(self: *AtomTable) !void`。
- **作用**：建立初始 1024 桶链式表并插入预定义字符串。
- **实现**：断言原桶表为空，分配并清零桶，设增长阈值 2048、计数从零开始；仅对 string 项按存储 hash 头插并递增计数。
- **所有权 / 错误 / 调用**：分配错误传播；symbol/private 不入链。分配成功后此函数没有进一步可失败分配。

### `AtomTable.ensureAtomHash` (`src/core/atom.zig:1436`)

- **签名**：`inline fn ensureAtomHash(self: *AtomTable) !void`。
- **作用**：确保链式桶表已初始化。
- **实现**：仅在 atom_hash.len 为零时调用 initAtomHash。
- **所有权 / 错误 / 调用**：已有表不重建；初次分配错误传播，AtomTable.init 因此仍可保持无分配。

### `AtomTable.resizeAtomHash` (`src/core/atom.zig:1443`)

- **签名**：`fn resizeAtomHash(self: *AtomTable, new_size: u32) !void`。
- **作用**：用已有 hash 把当前链重接到新桶数组。
- **实现**：断言 new_size 为 2 的幂，先分配清零新桶；遍历旧链，保存下一项再头插新桶，最后换表并释放旧桶，增长阈值用 new_size*|2 饱和计算。
- **所有权 / 错误 / 调用**：分配失败发生在改链前，旧表保持有效；不搬 entries 或拼写，不重新计算 hash，也不保证链顺序不变。调用者负责传入合适尺寸。

### `AtomTable.findAtom` (`src/core/atom.zig:1469`)

- **签名**：`inline fn findAtom(self: *const AtomTable, bytes: []const u8, atom_kind: AtomKind, h: u32) Atom`。
- **作用**：在指定 hash 的桶中查找 kind 和拼写相同的项。
- **实现**：空桶表返回 null_atom；沿预定义/动态链分别读取项，依次比较存储 hash、kind、长度、字节。
- **所有权 / 错误 / 调用**：不分配；hash/kind/长度不同才跳过字节比较，碰撞且长度相同仍会读取拼写。依赖链内有效项不变量，不另检查动态 occupied 或链环。

### `AtomTable.chainInsert` (`src/core/atom.zig:1499`)

- **签名**：`fn chainInsert(self: *AtomTable, id: Atom, h: u32) void`。
- **作用**：把已准备的 atom 插入桶头并尝试扩容。
- **实现**：接入 hash 对应桶，计数加一；达到阈值后尝试翻倍，尺寸可表示为 u32 时调用 resizeAtomHash，忽略其分配失败。
- **所有权 / 错误 / 调用**：要求桶表已初始化、id 有效且未重复入链、h 与条目一致。失败时插入仍有效；扩容会遍历全表，因此整个函数不保证最坏 O(1)。

### `AtomTable.chainUnlink` (`src/core/atom.zig:1515`)

- **签名**：`fn chainUnlink(self: *AtomTable, id: Atom, h: u32) void`。
- **作用**：从指定桶链中摘除已有 id。
- **实现**：定位 h 对应桶，从头查找前驱后接过目标，将目标 hash_next 清零并将计数减一。
- **所有权 / 错误 / 调用**：要求 id 确实存在于该桶，断言桶/后继非空；不是可安全处理不存在项的删除 API。不释放拼写或槽，不缩容，开销 O(链长)。

## intern

### `AtomTable.internString` (`src/core/atom.zig:1538`)

- **签名**：`pub fn internString(self: *AtomTable, bytes: []const u8) !Atom`。
- **作用**：取得字符串 atom，并记录到当前编译作用域。
- **实现**：调用 internStringInner，成功后 noteCompileScope(id)。
- **所有权 / 错误 / 调用**：输入借用，新动态拼写由内部复制；分配错误传播。返回 id 不增加 RC，也不是自动永久 host pin。

### `AtomTable.internStringInner` (`src/core/atom.zig:1544`)

- **签名**：`fn internStringInner(self: *AtomTable, bytes: []const u8) !Atom`。
- **作用**：按可编码数字、已有字符串、创建新条目的顺序取得 id。
- **实现**：仅规范十进制 0..2^31−1 可直接编码 tagged-int；否则 ensureAtomHash，再用 string kind 哈希查链，命中返回既有 id，未命中调用 internDynamic(index_entry=true)。
- **所有权 / 错误 / 调用**：高于 tagged-int 范围的合法数组索引仍以字符串驻留；该入口即使查预定义名也使用链表，首次可能分配桶。内部命中不自行做编译记录，公开外层负责。

### `AtomTable.newSymbol` (`src/core/atom.zig:1561`)

- **签名**：`pub fn newSymbol(self: *AtomTable, description: []const u8, atom_kind: AtomKind) !Atom`。
- **作用**：创建未驻留到拼写链的 symbol/private 条目。
- **实现**：断言 kind 为 symbol 或 private，调用 internDynamic，index=false、no_description=false、hash=0。
- **所有权 / 错误 / 调用**：不按描述去重；可复用已回收槽的数字 id，所以不保证历史上从未出现过该编号。返回 atom，符号体随后按需物化；分配错误传播。

### `AtomTable.newValueSymbol` (`src/core/atom.zig:1566`)

- **签名**：`pub fn newValueSymbol(self: *AtomTable, description: []const u8) !Atom`。
- **作用**：创建带描述的独立 symbol atom。
- **实现**：调用 internDynamic(description, symbol, false, false, 0)。
- **所有权 / 错误 / 调用**：即使描述相同也不复用仍存活的已有符号；输入被内部复制，返回 atom 而非 JSValue，body 由后续 symbolValue 等路径物化。

### `AtomTable.newValueSymbolNoDescription` (`src/core/atom.zig:1570`)

- **签名**：`pub fn newValueSymbolNoDescription(self: *AtomTable) !Atom`。
- **作用**：创建无描述的独立 symbol atom。
- **实现**：空拼写、symbol kind、no_symbol_description=true，不入拼写链。
- **所有权 / 错误 / 调用**：无描述与空字符串描述靠标志区分；此处只创建条目，ensureSymbolBody 随后选择 createSymbolNoDescription。分配错误传播。

### `AtomTable.internSymbol` (`src/core/atom.zig:1574`)

- **签名**：`pub fn internSymbol(self: *AtomTable, description: []const u8) !Atom`。
- **作用**：提供 global-symbol 驻留入口的别名。
- **实现**：直接转发 internGlobalSymbol。
- **所有权 / 错误 / 调用**：按描述复用当前存活 id，不是创建 unique symbol 的接口；不额外设置 registry_managed_symbol。

### `AtomTable.internGlobalSymbol` (`src/core/atom.zig:1578`)

- **签名**：`pub fn internGlobalSymbol(self: *AtomTable, description: []const u8) !Atom`。
- **作用**：取得 global-symbol kind 的驻留 atom。
- **实现**：调用 internGlobalSymbolInner，再 noteCompileScope。
- **所有权 / 错误 / 调用**：按当前表内拼写复用；该函数本身不物化 JSValue，也不设置 registry_managed_symbol。错误传播。

### `AtomTable.internGlobalSymbolInner` (`src/core/atom.zig:1584`)

- **签名**：`fn internGlobalSymbolInner(self: *AtomTable, description: []const u8) !Atom`。
- **作用**：在 global-symbol 拼写链中查找或创建条目。
- **实现**：ensureAtomHash 后用 seed=1 的 spellingHash 查找；命中断言 occupied/kind，未命中创建有索引的动态 global_symbol。
- **所有权 / 错误 / 调用**：与 string kind 的同名条目分离；没有额外设置注册标志。返回 id 的保活依赖实际持有者、编译作用域或 pin。

### `AtomTable.internRegisteredValueSymbol` (`src/core/atom.zig:1596`)

- **签名**：`pub fn internRegisteredValueSymbol(self: *AtomTable, description: []const u8) !Atom`。
- **作用**：取得并标注用于注册表的 global-symbol atom。
- **实现**：调用内部函数取得 id，再记录编译作用域。
- **所有权 / 错误 / 调用**：返回 atom；runtime.globalSymbolValue 直接调用本函数后再调用 symbolValue；此入口没有另外维护一张注册表。canBeHeldWeakly 按 kind 判定，不读取此处设置的标志。

### `AtomTable.internRegisteredValueSymbolInner` (`src/core/atom.zig:1602`)

- **签名**：`fn internRegisteredValueSymbolInner(self: *AtomTable, description: []const u8) !Atom`。
- **作用**：复用或创建 global-symbol 条目，并设置注册标志。
- **实现**：与普通 global-symbol 驻留共用链；命中与新建两条路径都把 registry_managed_symbol 设为 true。
- **所有权 / 错误 / 调用**：不会因既有条目原来标志为 false 而创建另一身份；标志本身不在 sweepDead 的保活判式中，不代表独立强根。分配错误传播。

### `AtomTable.isRegisteredSymbol` (`src/core/atom.zig:1618`)

- **签名**：`pub fn isRegisteredSymbol(self: *const AtomTable, atom_id: Atom) bool`。
- **作用**：检查 id 是否为仍在驻留链中的占用 global-symbol 条目。
- **实现**：先排除非动态及越界 id，再要求 occupied 和 kind=global_symbol；用条目 bytes/hash 查链，必须返回原 id。
- **所有权 / 错误 / 调用**：不检查 registry_managed_symbol，也不查 runtime 注册表或 body；因此不能把它解释成专门验证 Symbol.for 注册流程完成。

## TGC S3 活死

### `AtomTable.traceEpoch` (`src/core/atom.zig:1635`)

- **签名**：`inline fn traceEpoch(self: *const AtomTable) u64`。
- **作用**：取得关联 runtime 的当前 major 标记 epoch。
- **实现**：有 owner_runtime 时返回 block_heap.mark_epoch，否则返回 0。
- **所有权 / 错误 / 调用**：只读，不推进 epoch；首次 major 前值也可为 0，不能宣称 0 永远不会与条目默认戳相等。

### `AtomTable.markAtomAtEpoch` (`src/core/atom.zig:1649`)

- **签名**：`pub fn markAtomAtEpoch(self: *AtomTable, id: Atom, epoch: u64) ?*string.String`。
- **作用**：处理 atom 边的条目标记部分，并返回待标记符号体。
- **实现**：调用 atomEdge(id, epoch, stamp)。有效动态条目更新 mark_epoch，value-symbol 返回当前 str，普通字符串不返回缓存体。
- **所有权 / 错误 / 调用**：本函数不直接 shade body，调用方负责；同 epoch 重复边仍可能返回同一 body，不以已盖戳为理由省略它。

### `AtomTable.atomEdgeBodyWithoutStamp` (`src/core/atom.zig:1663`)

- **签名**：`pub fn atomEdgeBodyWithoutStamp(self: *AtomTable, id: Atom) ?*string.String`。
- **作用**：供可达性复核读取 atom 边，不修改条目戳。
- **实现**：调用 atomEdge(id, 0, observe)，读取仍占用的 value-symbol 的 str。
- **所有权 / 错误 / 调用**：observe 对未占用槽也直接返回 null，不改 shell/stale 审计计数。结果借用，不建立新根或分配 body。

### `AtomTable.atomEdge` (`src/core/atom.zig:1669`)

- **签名**：`fn atomEdge(self: *AtomTable, id: Atom, epoch: u64, mode: EdgeMode) ?*string.String`。
- **作用**：统一执行 atom 边的标记或观察。
- **实现**：null/const/tagged-int/不存在的动态槽返回 null。未占用槽在 observe 模式直接返回；stamp 模式按 weakref_count 增加 shell 或 stale 计数，Debug stale 路径打印且可按 atom_audit_fatal panic。占用项仅在 stamp 模式更新 mark_epoch，value-symbol 每次返回 str。
- **所有权 / 错误 / 调用**：不验证 epoch 是否当前、不物化 body；普通 string 即便有缓存也返回 null。越界 id 被忽略，计数针对找到但已退休的槽；重复盖戳不会抑制符号体边。

### `AtomTable.shadeAtomIfMarking` (`src/core/atom.zig:1711`)

- **签名**：`pub inline fn shadeAtomIfMarking(self: *AtomTable, id: Atom) void`。
- **作用**：在增量标记窗口中执行 atom 写入屏障。
- **实现**：无 owner_runtime 时返回；markingActive 为 true 才进入 shadeAtomBarrierSlow。
- **所有权 / 错误 / 调用**：不修改实际 holder 字段，也不成为窗口外永久根；通常由 noteHolderStore 在写入前调用。

### `AtomTable.shadeAtomBarrierSlow` (`src/core/atom.zig:1719`)

- **签名**：`noinline fn shadeAtomBarrierSlow(self: *AtomTable, rt: *runtime_mod.JSRuntime, id: Atom) void`。
- **作用**：给 atom 条目盖当前戳，并提交符号体标记。
- **实现**：读取传入 runtime 的 epoch，调用 markAtomAtEpoch；返回 body 时交给 shadeCellForAtomBarrier。该 helper 跳过已标记或尚未 heap_accounted 的体，否则标记并提交队列。
- **所有权 / 错误 / 调用**：由外层在标记活动时调用，本函数不重复检查活动状态。普通字符串缓存不被此边保活；返回 void，队列处理沿 GC 自身机制进行。

### `AtomTable.restampTraceEpoch` (`src/core/atom.zig:1740`)

- **签名**：`pub fn restampTraceEpoch(self: *AtomTable, from: u64, to: u64) void`。
- **作用**：把指定旧 epoch 的条目戳翻译成新 epoch。
- **实现**：from==to 时返回；遍历 slotOccupied 项，分别将等于 from 的 mark_epoch 和 born_epoch 改为 to。
- **所有权 / 错误 / 调用**：也可涉及弱壳，跳过完全空闲槽；不重新决定可达性、不标记 body、不改变 host_pins。供 verifier 恢复与标记空间对应的条目状态。

### `AtomTable.stampBirthEpoch` (`src/core/atom.zig:1754`)

- **签名**：`fn stampBirthEpoch(self: *AtomTable, entry: *DynamicAtom) void`。
- **作用**：初始化新建或复用条目的出生与标记状态。
- **实现**：总是写 born_epoch=traceEpoch、host_pins=0、mark_epoch=0；仅有关联 runtime 且 markingActive 时再写 mark_epoch=epoch。
- **所有权 / 错误 / 调用**：不是只在标记窗口内执行，也不 shade body。sweepDead 另以 born_epoch 相等保留当轮出生项；调用者须只用于正在初始化的条目。

### `AtomTable.noteCompileScope` (`src/core/atom.zig:1765`)

- **签名**：`pub inline fn noteCompileScope(self: *AtomTable, id: Atom) void`。
- **作用**：把 id 交给最内层活动编译作用域记录。
- **实现**：compile_scope 非空时调用 scope.note，否则不做操作。
- **所有权 / 错误 / 调用**：不会创建作用域，也不自行执行 GC 屏障；scope.note 分配失败时退化为 host pin，因而此接口没有错误返回。

### `AtomTable.pinForHost` (`src/core/atom.zig:1774`)

- **签名**：`pub fn pinForHost(self: *AtomTable, id: Atom) void`。
- **作用**：增加动态 atom 的显式 host pin 计数。
- **实现**：const/tagged-int 忽略；findDynamic 找到槽后执行 host_pins +|=1 饱和加。
- **所有权 / 错误 / 调用**：不分配、不校验 occupied，也不 shade 符号体；调用方必须提供仍有效的条目。它不能复活死槽或替代符号体标记边；表内还存在 weakref_count，并非唯一计数。

### `AtomTable.unpinForHost` (`src/core/atom.zig:1780`)

- **签名**：`pub fn unpinForHost(self: *AtomTable, id: Atom) void`。
- **作用**：减少动态槽的 host pin 计数。
- **实现**：与 pin 相同的筛选后执行 host_pins −|=1 饱和减。
- **所有权 / 错误 / 调用**：零时再次调用不报错；不立即回收条目、不检查占用状态。调用方负责有效 id 和正确配对。

### `AtomTable.sweepDead` (`src/core/atom.zig:1797`)

- **签名**：`pub fn sweepDead(self: *AtomTable, rt: *runtime_mod.JSRuntime, epoch: u64) void`。
- **作用**：在 major 标记完成后的暂停内判定动态条目及缓存是否保留。
- **实现**：audit 模式先释放上一轮隔离槽；只判断 occupied 项。live 为 mark_epoch/born_epoch 等于传入 epoch、host_pins 非零或 body 已标记之一。live string 若缓存未标记则解绑；dead 项有弱引用时摘链并留下 occupied=false 的壳，否则 finalizeDeadEntry。
- **所有权 / 错误 / 调用**：已有弱壳被跳过；registry_managed_symbol 不在保活条件中。不是唯一使条目失效的入口：onSymbolBodyDead 也可留下弱壳或 finalize。调用者须满足 body 尚可访问和正确收集 epoch 的前提。

### `AtomTable.noteHolderStore` (`src/core/atom.zig:1855`)

- **签名**：`pub fn noteHolderStore(self: *AtomTable, atom: Atom) Atom`。
- **作用**：记录即将写入 GC 可见持有者的 atom，并执行所需屏障。
- **实现**：先 noteCompileScope，再 shadeAtomIfMarking，原样返回 atom。
- **所有权 / 错误 / 调用**：不增加 RC、不自动维护持有者后续 traceChildEdges，也不验证 id；返回值便于初始化字段，实际存储由调用方完成。

## 查询与字符串化

### `AtomTable.name` (`src/core/atom.zig:1861`)

- **签名**：`pub fn name(self: *const AtomTable, atom: Atom) ?[]const u8`。
- **作用**：返回 atom 当前名称的借用字节切片。
- **实现**：null/tagged-int 返回 null；预定义返回静态 name；动态仅 occupied 时返回 entry.bytes。
- **所有权 / 错误 / 调用**：不格式化整数、不物化 body，也不要求符号体存活；无描述符号的原始拼写可为空串。动态 bytes 在条目退休时失效，不能跨回收无根保存。

### `AtomTable.atomIsArrayIndex` (`src/core/atom.zig:1887`)

- **签名**：`pub fn atomIsArrayIndex(self: *const AtomTable, atom: Atom) bool`。
- **作用**：判断 atom 是否表示规范数组索引。
- **实现**：tagged-int 解码后比较 max_array_index；动态索引须在 entries 范围内、bytes.len≥10、occupied 且 kind=string，再用 parseHighArrayIndex 检查十进制形式。
- **所有权 / 错误 / 调用**：依赖 internString 将小索引编码为 tagged-int 的不变量；较大的 2147483648..4294967294 保留为字符串。无分配，不读取符号描述作为索引。

### `AtomTable.kind` (`src/core/atom.zig:1908`)

- **签名**：`pub fn kind(self: *const AtomTable, atom: Atom) ?AtomKind`。
- **作用**：查询 id 的当前 kind。
- **实现**：null 为 null，tagged-int 为 string，预定义查静态表，动态仅 occupied 时返回 kind。
- **所有权 / 错误 / 调用**：不检查符号 body 是否存在或当前 GC 标记；弱壳返回 null。无分配。

### `AtomTable.isPublicSymbol` (`src/core/atom.zig:1918`)

- **签名**：`pub fn isPublicSymbol(self: *const AtomTable, atom_id: Atom) bool`。
- **作用**：判断当前 atom kind 是否为公开符号。
- **实现**：先 kind，缺失则 false，再判断 symbol/global_symbol。
- **所有权 / 错误 / 调用**：private 为 false；不证明 body 已物化或注册流程完成。

### `AtomTable.cachedPushValue` (`src/core/atom.zig:1943`)

- **签名**：`pub inline fn cachedPushValue(self: *AtomTable, atom_id: Atom) ?JSValue`。
- **作用**：无分配地读取可用于 push 的已缓存字符串值。
- **实现**：非零预定义 id 直接读 predefined_str，不检查 kind；动态有效范围内仅要求 kind=string 且 str 非空，返回 cached.value()。
- **所有权 / 错误 / 调用**：不独立检查动态 occupied 或 GC phase，依赖缓存解绑不变量。只返回 string JSValue，不建立根；VM 的 op_push_atom_value 在 miss 后先 publish 栈再调用可分配路径。

### `AtomTable.toStringValueForPush` (`src/core/atom.zig:1960`)

- **签名**：`pub inline fn toStringValueForPush(self: *AtomTable, rt: anytype, atom_id: Atom) !JSValue`。
- **作用**：先查无分配缓存，再执行普通 atom 字符串转换。
- **实现**：cachedPushValue 命中直接返回，否则调用 toStringValue。
- **所有权 / 错误 / 调用**：miss 可能分配并触发 GC；本 wrapper 不发布 VM 栈、不建立根帧，调用者负责保存其余活值。错误传播。

### `AtomTable.toStringValue` (`src/core/atom.zig:1965`)

- **签名**：`pub fn toStringValue(self: *AtomTable, rt: anytype, atom_id: Atom) !JSValue`。
- **作用**：把 atom 数字或名称转换为 string JSValue。
- **实现**：tagged-int 用十进制文本，单字符走 singleByteString，其他走 recentAtomString；null/无效或不占用的动态 id 为 undefined。预定义和动态先处理单 ASCII 字符，其他非 string kind 创建描述字符串；string kind 复用或创建表缓存。动态单字符只在 string kind 且 str 为空时填槽，缓存原先无 atom_id 才绑定回指。
- **所有权 / 错误 / 调用**：符号路径输出名称字符串，不返回 symbol JSValue；无描述符号可得到空字符串。动态字符串缓存不是永久根，返回值应由调用者纳入活值管理；分配错误传播，无 RC 复制。

### `AtomTable.cachedString` (`src/core/atom.zig:2032`)

- **签名**：`pub fn cachedString(self: *const AtomTable, atom_id: Atom) ?*string.String`。
- **作用**：借用 atom 当前缓存体指针。
- **实现**：null/tagged-int 返回 null；预定义直接读 predefined_str；动态要求 isLive 后返回 str。
- **所有权 / 错误 / 调用**：没有 kind 限制，可能取得 symbol/private 的 body；也没有 tracer_destroy 标记检查。无分配、无保活，调用者须按其用途遵守表/GC 不变量。

### `AtomTable.cacheString` (`src/core/atom.zig:2047`)

- **签名**：`pub fn cacheString(self: *AtomTable, rt: *JSRuntime, atom_id: Atom, s: *string.String) void`。
- **作用**：将尚未绑定的字符串与 atom 关联。
- **实现**：s 已有 atom_id 则返回。tagged-int 只写回指；null 无操作。预定义仅 string kind，先给 s 写 id，即使槽已占用也保留回指，仅空槽填入 s；动态必须 occupied、string 且空槽，才填 str 并 bindAtomId。
- **所有权 / 错误 / 调用**：不比较 s 内容与 atom 名称，也不验证 runtime 一致性，调用者负责对应关系。无分配、无 RC；动态 bindAtomId 设置 needs_finalizer，确保销毁时回调解绑。

### `AtomTable.symbolValue` (`src/core/atom.zig:2077`)

- **签名**：`pub fn symbolValue(self: *AtomTable, rt: *JSRuntime, atom_id: Atom) !JSValue`。
- **作用**：取得或物化 atom 对应的 symbol JSValue。
- **实现**：ensureSymbolBody 成功后将 header 包装为 JSValue.symbol。
- **所有权 / 错误 / 调用**：支持 value-symbol kind，包括 private；InvalidAtom 和分配错误传播。不增加 id 计数，调用者负责结果保活；不是弱存活查询接口。

### `AtomTable.takeSymbolValue` (`src/core/atom.zig:2087`)

- **签名**：`pub fn takeSymbolValue(self: *AtomTable, rt: *JSRuntime, atom_id: Atom) !JSValue`。
- **作用**：取得符号值，保留创建调用点使用的接口名。
- **实现**：同样调用 ensureSymbolBody 并包装 JSValue.symbol，与 symbolValue 没有计数转移差异。
- **所有权 / 错误 / 调用**：不会消费、清空或释放 atom id；InvalidAtom/分配错误传播，结果按 GC 活值规则管理。

### `AtomTable.symbolValueIfLive` (`src/core/atom.zig:2092`)

- **签名**：`pub fn symbolValueIfLive(self: *const AtomTable, rt: *const JSRuntime, atom_id: Atom) JSValue`。
- **作用**：读取当前可观察的符号体，缺失时返回 undefined。
- **实现**：调用 symbolBodyIfLive，存在则包装 symbol JSValue。
- **所有权 / 错误 / 调用**：不物化、不分配、不自动 pin；只在特定销毁阶段按 mark 筛除，不能视为所有阶段的完整可达性检测。

### `AtomTable.retainSymbolWeakRef` (`src/core/atom.zig:2097`)

- **签名**：`pub fn retainSymbolWeakRef(self: *AtomTable, atom_id: Atom) void`。
- **作用**：增加动态符号条目的弱观察计数。
- **实现**：const/tagged-int 或不存在条目直接返回；要求 value-symbol kind，断言 occupied 后 weakref_count 普通加一。
- **所有权 / 错误 / 调用**：保留身份槽/弱壳，不把 body 变成强根；包括 global_symbol/private，并不执行语言级 CanBeHeldWeakly 限制。不是饱和加，配对及容量前提由调用者保证。

### `AtomTable.releaseSymbolWeakRef` (`src/core/atom.zig:2105`)

- **签名**：`pub fn releaseSymbolWeakRef(self: *AtomTable, _: *JSRuntime, atom_id: Atom) void`。
- **作用**：减少弱观察计数，并在必要时释放最后的弱壳。
- **实现**：过滤非动态/不存在/非 value-symbol 项，断言计数>0后减一；只有计数归零、str=null 且 occupied=false 才 finalizeDeadEntry。
- **所有权 / 错误 / 调用**：runtime 参数未用，不分配。活条目不会因最后一个弱引用释放而直接死亡；未配对调用不是可忽略操作。

### `AtomTable.symbolDescription` (`src/core/atom.zig:2120`)

- **签名**：`pub fn symbolDescription(self: *const AtomTable, rt: *const JSRuntime, symbol: Atom) ?[]const u8`。
- **作用**：返回已有活符号体对应的描述字节。
- **实现**：先 symbolBodyIfLive；缺失或 body.isSymbolNoDescription 为 true 时返回 null，否则返回 name(symbol)。
- **所有权 / 错误 / 调用**：返回的是表名称的借用切片，不重新编码 body；未物化的符号即使有拼写也返回 null。无描述与空描述通过 body 的宽空串表示区分。

### `AtomTable.symbolBodyHeaderIfLive` (`src/core/atom.zig:2129`)

- **签名**：`pub fn symbolBodyHeaderIfLive(self: *const AtomTable, rt: *const JSRuntime, atom_id: Atom) ?*gc.GCObjectHeader`。
- **作用**：借用符合当前观察条件的符号体 header。
- **实现**：symbolBodyIfLive 返回 body 后通过指针/对齐转换得到 header，否则 null。
- **所有权 / 错误 / 调用**：不在这里无条件检查 mark；仅 helper 在 tracer_destroy 阶段这样做。弱键收集逻辑如需判定本轮可达性，仍须结合收集器自身标记处理。

### `AtomTable.bodyLiveForCurrentPhase` (`src/core/atom.zig:2149`)

- **签名**：`fn bodyLiveForCurrentPhase(rt: *const JSRuntime, body: *string.String) bool`。
- **作用**：判断仍绑定的 body 在当前阶段能否交给观察者。
- **实现**：phase 不是 tracer_destroy 时直接 true；该阶段返回 headerMarked(body.header())。
- **所有权 / 错误 / 调用**：避免把已判死但尚未销毁解绑的体暴露出去；不是通用指针有效性验证或所有阶段可达性测试。

### `AtomTable.symbolBodyIfLive` (`src/core/atom.zig:2154`)

- **签名**：`fn symbolBodyIfLive(self: *const AtomTable, rt: *const JSRuntime, atom_id: Atom) ?*string.String`。
- **作用**：借用已经物化、在当前阶段可观察的符号体。
- **实现**：排除 null/tagged-int；预定义须 value-symbol 且槽非空，动态须找到 value-symbol 项且 str 非空；两者都通过 bodyLiveForCurrentPhase。
- **所有权 / 错误 / 调用**：不创建体，动态分支没有独立 occupied 检查，依赖弱壳已经解绑 str。预定义体有表根；返回指针本身不新增 root。

### `AtomTable.ensureSymbolBody` (`src/core/atom.zig:2176`)

- **签名**：`fn ensureSymbolBody(self: *AtomTable, rt: *JSRuntime, atom_id: Atom) !*string.String`。
- **作用**：验证符号 atom 并按需创建身份 body。
- **实现**：null/tagged-int、非 value-symbol 或无效/未占用动态项返回 InvalidAtom；已有缓存直接返回。预定义以名称 createUtf8，设置 atom_id 并填槽；动态先为 young id 列表预留容量，再按 no_symbol_description 创建 UTF-16 空体或 UTF-8 描述体，bindAtomId、填 str 并 appendAssumeCapacity。
- **所有权 / 错误 / 调用**：先预留再创建，避免创建成功后因列表扩容失败漏掉 minor 根；创建失败可能保留列表新增容量。已有缓存不经 phase/mark 查询，调用者须持有有效身份；创建和预留的分配错误传播。

### `AtomTable.internDynamic` (`src/core/atom.zig:2211`)

- **签名**：`fn internDynamic(self: *AtomTable, bytes: []const u8, atom_kind: AtomKind, index_entry: bool, no_symbol_description: bool, lookup_hash: u32) !Atom`。
- **作用**：创建动态条目后记录编译作用域。
- **实现**：调用 internDynamicInner，成功后 noteCompileScope(id)。
- **所有权 / 错误 / 调用**：不自行查找重复拼写；需要索引的调用者须已证明未命中，传入正确 hash 并建立桶表。内部分配错误传播，scope 记录失败按其 pin 机制处理。

### `AtomTable.internDynamicInner` (`src/core/atom.zig:2217`)

- **签名**：`fn internDynamicInner(self: *AtomTable, bytes: []const u8, atom_kind: AtomKind, index_entry: bool, no_symbol_description: bool, lookup_hash: u32) !Atom`。
- **作用**：复制拼写并复用空槽或追加新槽。
- **实现**：非空 bytes 先分配复制。free list 非空则弹出槽，重置 kind/占用/注册/弱引用/描述标志并初始化 epoch；否则先递增 next_id，再 appendEntry 和初始化 epoch。需要索引时 indexEntry；private 更新历史最小 private id。
- **所有权 / 错误 / 调用**：输入借用，成功后表拥有复制的 bytes。append 失败恢复 next_id 并释放复制；复用分支虽有 errdefer，目前弹槽后的调用不返回错误。未检查重复或显式处理 id 达到 tagged-int 区域的耗尽；不能把旧 RC 注释当复用依据。

### `AtomTable.mightBePrivate` (`src/core/atom.zig:2282`)

- **签名**：`pub inline fn mightBePrivate(self: *const AtomTable, atom_id: Atom) bool`。
- **作用**：快速判断 id 是否可能表示 private 名称。
- **实现**：Private_brand 直接 true；其他仅当非 tagged-int 且 id≥first_private_dynamic_atom 时 true。
- **所有权 / 错误 / 调用**：不查 entries 范围、occupied 或 kind；历史下界只减不增，槽跨 kind 复用会产生允许的假阳性，调用方仍需精确检查。

### `AtomTable.appendEntry` (`src/core/atom.zig:2287`)

- **签名**：`fn appendEntry(self: *AtomTable, entry: DynamicAtom) !EntryIndex`。
- **作用**：向动态槽数组尾部追加一个结构值。
- **实现**：需要增长时容量从 0 到 8，否则翻倍且至少 new_used；分配新数组、浅拷旧项、替换后释放旧 backing，随后扩展可见切片并写入 entry。
- **所有权 / 错误 / 调用**：分配失败保持旧数组；增长使旧 entry 指针失效，但 bytes/str 指向的存储不会因浅拷搬动。接管与释放成员由外层管理；usize 算术和 u32 索引转换不是显式错误处理。

### `AtomTable.indexEntry` (`src/core/atom.zig:2312`)

- **签名**：`fn indexEntry(self: *AtomTable, idx: EntryIndex, hash: u32) void`。
- **作用**：存储 hash 并将条目接入桶链。
- **实现**：断言 kind 为 string/global_symbol，写 entry.hash，再 chainInsert(entry.id, hash)。
- **所有权 / 错误 / 调用**：不返回错误，但 chainInsert 可能尝试分配并重接整个桶表，扩容失败被内部忽略；并非保证无分配或最坏常数时间。要求未重复入链。

### `AtomTable.unindexEntry` (`src/core/atom.zig:2321`)

- **签名**：`fn unindexEntry(self: *AtomTable, idx: EntryIndex) void`。
- **作用**：按 kind 摘除动态条目的索引。
- **实现**：string/global_symbol 调用 chainUnlink；symbol/private 无操作。
- **所有权 / 错误 / 调用**：不检查 occupied、是否已摘链或 hash_next 是否为空；对链式 kind 要求仍在正确桶中，不是幂等删除。不释放条目存储。

### `AtomTable.finalizeDeadEntry` (`src/core/atom.zig:2329`)

- **签名**：`fn finalizeDeadEntry(self: *AtomTable, idx: EntryIndex) void`。
- **作用**：释放条目拼写并将槽放入可复用或隔离列表。
- **实现**：先 unindexEntry；有 str 时清槽并断言回指匹配，再清 body.atom_id；释放 bytes，清 occupied/弱计数/描述及注册标志、epoch 和 host_pins。audit 模式推入隔离链，否则推入 free list。
- **所有权 / 错误 / 调用**：不释放 body、不缩减 entries，也不清 id/kind/hash。调用者须满足无需保留及可摘链的前提；链式 kind 已摘链后再次调用并不安全。保留数字 id 供后续复用。

### `AtomTable.releaseQuarantinedSlots` (`src/core/atom.zig:2373`)

- **签名**：`fn releaseQuarantinedSlots(self: *AtomTable) void`。
- **作用**：把隔离链中的槽转入普通 free list。
- **实现**：编译期要求 ownership_audit_enabled；先清隔离头，再逐项保存 next、断言槽未占用并头插 free list。
- **所有权 / 错误 / 调用**：无分配、不改变 entries 长度；逐项头插会反转原隔离链次序，不是保持顺序的整链拼接。由 audit sweep 开始时调用。

### `AtomTable.findDynamic` (`src/core/atom.zig:2387`)

- **签名**：`fn findDynamic(self: *AtomTable, atom: Atom) ?*DynamicAtom`。
- **作用**：借用给定动态 id 对应的可变槽。
- **实现**：dynamicEntryIndex 排除预定义/tagged-int，再检查 idx<entries.len 并返回地址。
- **所有权 / 错误 / 调用**：不会检查 occupied、kind、body 或 epoch，可能返回空槽/弱壳。entries 扩容或表销毁使指针失效，id 复用也会改变其身份。

### `AtomTable.findDynamicConst` (`src/core/atom.zig:2393`)

- **签名**：`fn findDynamicConst(self: *const AtomTable, atom: Atom) ?*const DynamicAtom`。
- **作用**：借用给定动态 id 对应的只读槽。
- **实现**：与可变版本相同的编码和数组范围检查。
- **所有权 / 错误 / 调用**：只读指针不保证条目存活；调用者仍需检查 occupied 等状态。借用受 entries 扩容、复用和销毁影响。

### `AtomTable.onSymbolBodyDead` (`src/core/atom.zig:2405`)

- **签名**：`pub fn onSymbolBodyDead(self: *AtomTable, atom_id: Atom, body: *string.String) void`。
- **作用**：在 body 销毁时解除对应 atom 绑定。
- **实现**：断言非 const/tagged-int，检查索引。普通 string 仅在 str==body 时清缓存；value-symbol 若 str 不匹配则忽略，匹配且有弱引用则摘链、清 str、置 occupied=false，否则 finalizeDeadEntry。
- **所有权 / 错误 / 调用**：由字符串销毁路径调用，不重新判断 epoch/host_pins。弱壳分支保留 bytes/计数等供后续观察和清理；普通缓存解绑不销毁 atom 条目。无 RC 转移。

## `CompileAtomScope`

### `CompileAtomScope.init` (`src/core/atom.zig:2474`)

- **签名**：`pub fn init(table: *AtomTable) CompileAtomScope`。
- **作用**：构造尚未激活的编译 atom 记录作用域。
- **实现**：捕获 table.owner_runtime 和 table，选择 runtime 或 table 的 persistent_allocator，其余字段使用默认值。
- **所有权 / 错误 / 调用**：无分配；此时不注册 root provider、不安装 ambient 指针。activate 前应放到最终稳定地址，且 rt 是初始化时的快照。

### `CompileAtomScope.traceRootsThunk` (`src/core/atom.zig:2483`)

- **签名**：`fn traceRootsThunk(context: *anyopaque, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void`。
- **作用**：向根访问器报告作用域记录的每个 id。
- **实现**：把 context 转为 CompileAtomScope 指针，按 ids 列表顺序调用 visitor.atomRoot。
- **所有权 / 错误 / 调用**：要求 context 指向仍有效的作用域；重复 id 也会被访问，错误立即传播，不在这里检查条目占用或去重。

### `CompileAtomScope.provider` (`src/core/atom.zig:2488`)

- **签名**：`fn provider(self: *CompileAtomScope) runtime_mod.RootProvider`。
- **作用**：构造引用当前作用域的 RootProvider。
- **实现**：返回 context=self 和 trace=traceRootsThunk。
- **所有权 / 错误 / 调用**：不分配、不复制或拥有作用域；注册期间 self 必须保持地址和生命周期有效。

### `CompileAtomScope.activate` (`src/core/atom.zig:2494`)

- **签名**：`pub fn activate(self: *CompileAtomScope) !void`。
- **作用**：把作用域安装为当前表的最内层记录目标。
- **实现**：断言尚未 active；有 rt 且 value_root_frames_enabled 时先 registerRootProvider，成功后置 registered；再保存 prev、写 table.compile_scope=self、置 active。
- **所有权 / 错误 / 调用**：注册失败发生在 ambient 链修改前；无 runtime 或配置关闭时仍安装记录作用域，但不注册 provider。必须按嵌套顺序解除。

### `CompileAtomScope.deinit` (`src/core/atom.zig:2507`)

- **签名**：`pub fn deinit(self: *CompileAtomScope) void`。
- **作用**：解除作用域并释放记录列表。
- **实现**：active 时断言自己位于链顶，恢复 prev 并清 active；registered 时注销同一 provider；释放 ids 后重置空列表和 recent。
- **所有权 / 错误 / 调用**：不逐 id unpin，因此 note 的分配失败兜底 pin 不随作用域结束撤销。保留 table/rt/allocator，未激活作用域也可释放记录存储。

### `CompileAtomScope.note` (`src/core/atom.zig:2528`)

- **签名**：`pub fn note(self: *CompileAtomScope, id: Atom) void`。
- **作用**：记录一个动态 atom，供编译区间保活。
- **实现**：忽略 null/const/tagged-int；以 id&63 定位 recent，精确命中则跳过；成功 append 后更新 recent。append 失败则 pinForHost(id) 并返回，不更新过滤槽。
- **所有权 / 错误 / 调用**：不验证 id 存活，也不要求 active；冲突只导致重复记录。失败 pin 可能重复累加且 deinit 不撤销，属于过度保留兜底；列表本身只有已注册 provider 才作为这一路根被访问。

### `CompileAtomScope.intern` (`src/core/atom.zig:2546`)

- **签名**：`pub fn intern(self: *CompileAtomScope, bytes: []const u8) !Atom`。
- **作用**：驻留字符串并明确记录到此作用域。
- **实现**：先 table.internString，再 self.note。
- **所有权 / 错误 / 调用**：表入口记录的是当时最内 ambient scope，可能不是 self；两次记录不保证始终针对同一作用域。驻留错误传播，note 的记录失败内部 pin。

### `CompileAtomScope.noteExisting` (`src/core/atom.zig:2554`)

- **签名**：`pub fn noteExisting(self: *CompileAtomScope, id: Atom) Atom`。
- **作用**：把已有 id 记录到此作用域并原样返回。
- **实现**：调用 self.note(id)，返回 id。
- **所有权 / 错误 / 调用**：不验证或复活身份，不自动激活作用域；适合将调用前已获取的有效 id 纳入记录。

## 自由函数

### `callVisitAtom` (`src/core/atom.zig:2564`)

- **签名**：`pub inline fn callVisitAtom(vis: anytype, id: Atom) !void`。
- **作用**：在支持 atom 边的访问器上调用 visitAtom。
- **实现**：编译期取访问器类型，若是指针则取其直接 child；有 visitAtom 声明才调用，返回类型为 error union 时用 try，否则直接调用。
- **所有权 / 错误 / 调用**：没有该声明时静默跳过，不验证 id、不保留它；不能由本 wrapper 推导所有 visitor 都追踪 atom。错误按访问器传播。

### `dynamicEntryIndex` (`src/core/atom.zig:2577`)

- **签名**：`fn dynamicEntryIndex(atom: Atom) ?usize`。
- **作用**：把动态编码的 id 转成 entries 下标。
- **实现**：id<first_dynamic_atom 或最高位已置位返回 null，否则返回 id−first_dynamic_atom。
- **所有权 / 错误 / 调用**：不检查 entries 长度、条目占用或代次，只解码范围。

### `isConst` (`src/core/atom.zig:2582`)

- **签名**：`pub fn isConst(atom: Atom) bool`。
- **作用**：判断 id 是否位于动态区间之前。
- **实现**：返回 atom<693，包括 null_atom=0。
- **所有权 / 错误 / 调用**：不包括 tagged-int；这是编码谓词，不代表非零合法预定义项检查，也不执行保活。

### `isTaggedInt` (`src/core/atom.zig:2586`)

- **签名**：`pub fn isTaggedInt(atom: Atom) bool`。
- **作用**：检查 atom 的最高位是否置位。
- **实现**：与 tagged_int_bit 按位与后判断非零。
- **所有权 / 错误 / 调用**：所有置位编码都被当作 tagged-int；不读表、不验证来源。

### `atomFromUInt32` (`src/core/atom.zig:2590`)

- **签名**：`pub fn atomFromUInt32(n: u32) Atom`。
- **作用**：将 31 位非负整数编码为 tagged-int atom。
- **实现**：断言 n≤2^31−1，返回 n 或上最高位。
- **所有权 / 错误 / 调用**：不是完整 u32 数组索引转换；超范围违反前提，高索引须走字符串 atom。无分配。

### `atomToUInt32` (`src/core/atom.zig:2595`)

- **签名**：`pub fn atomToUInt32(atom: Atom) u32`。
- **作用**：解码 tagged-int atom 的整数值。
- **实现**：断言最高位置位，然后清除该位。
- **所有权 / 错误 / 调用**：结果位于 0..2^31−1；不接受任意字符串 id，也不查表。

### `predefinedName` (`src/core/atom.zig:2605`)

- **签名**：`pub fn predefinedName(id: Atom) []const u8`。
- **作用**：借用合法预定义 id 的静态名称。
- **实现**：断言 id 非零且<693，返回 predefined_atoms[id−1].name。
- **所有权 / 错误 / 调用**：静态切片不受 runtime 销毁/GC 影响；非法 id 不返回错误或 null，而是违反前提。

### `predefinedById` (`src/core/atom.zig:2610`)

- **签名**：`pub fn predefinedById(id: Atom) ?PredefinedAtom`。
- **作用**：按范围查询预定义记录。
- **实现**：零或≥693 返回 null，否则返回 predefined_atoms[id−1] 的结构值。
- **所有权 / 错误 / 调用**：记录按值返回，name 仍借用静态字节，无分配。

### `predefinedId` (`src/core/atom.zig:2615`)

- **签名**：`pub fn predefinedId(bytes: []const u8, kind: AtomKind) ?Atom`。
- **作用**：按名称与 kind 查静态预定义 id。
- **实现**：string 使用 Wyhash(seed=0) 开地址表；symbol/private 使用各自 StaticStringMap；global_symbol 恒为 null。
- **所有权 / 错误 / 调用**：不创建动态 atom，也不把数字字符串编码为 tagged-int；未命中返回 null。输入借用、查找无分配。

### `parseArrayIndex` (`src/core/atom.zig:2625`)

- **签名**：`fn parseArrayIndex(bytes: []const u8) ?u32`。
- **作用**：解析能直接编码为 tagged-int 的规范十进制索引。
- **实现**：排除空串、非数字开头、多字节前导零；逐字节要求 ASCII 数字，用 u64 累计，每步超过2^31−1即返回 null。
- **所有权 / 错误 / 调用**：单独 0 合法；空白、符号、小数点均不接受。每步限值使下一次乘加处于 u64 范围，无分配。

### `parseHighArrayIndex` (`src/core/atom.zig:2648`)

- **签名**：`fn parseHighArrayIndex(bytes: []const u8) ?u32`。
- **作用**：解析完整数组索引范围内的规范十进制文本。
- **实现**：排除空串及多字节前导零，逐字节验证 ASCII 数字并累计，超过2^32−2立即返回 null。
- **所有权 / 错误 / 调用**：虽名为 High，也接受小索引；调用方 atomIsArrayIndex 先通过长度/编码不变量筛选高段。4294967295 不接受，无分配。

### `atomListContains` (`src/core/atom.zig:2665`)

- **签名**：`pub fn atomListContains(list: []const Atom, needle: Atom) bool`。
- **作用**：判断列表中是否出现同一数字 id。
- **实现**：线性扫描，首个相等项返回 true，否则 false。
- **所有权 / 错误 / 调用**：不检查 atom 活性或同名关系；空列表为 false，借用列表不分配。

### `appendAtom` (`src/core/atom.zig:2672`)

- **签名**：`pub fn appendAtom(rt: *JSRuntime, list: *[]Atom, atom_id: Atom) !void`。
- **作用**：重新分配列表并追加一个 atom id。
- **实现**：alloc 旧长度+1、复制旧项、写新 id，再替换调用方切片并释放非空旧列表。
- **所有权 / 错误 / 调用**：分配失败保留旧列表。旧存储须由该 runtime.memory 管理；不去重、不注册根或执行 atom store barrier，n 次逐项追加可能累计 O(n²) 复制。

### `freeAtomList` (`src/core/atom.zig:2682`)

- **签名**：`pub fn freeAtomList(rt: *JSRuntime, list: []Atom) void`。
- **作用**：释放非空 atom 列表的存储。
- **实现**：仅在 len!=0 时调用 rt.memory.free。
- **所有权 / 错误 / 调用**：不处理各 id 的生命周期，不清空调用方切片；释放后旧切片不可再用，须匹配分配器。

### `appendOwnedAtom` (`src/core/atom.zig:2686`)

- **签名**：`pub fn appendOwnedAtom(rt: *JSRuntime, keys: *[]Atom, atom_id: Atom) !void`。
- **作用**：以历史 owned 名称提供追加 id 的列表操作。
- **实现**：与 appendAtom 相同：新分配、复制、追加、替换并释放旧存储。
- **所有权 / 错误 / 调用**：没有额外所有权转移、pin 或屏障；分配失败原列表不变，调用者负责列表存储来源及 id 的可达性。

## `src/core/symbol.zig`

### `description` (`src/core/symbol.zig:17`)

- **签名**：`pub fn description(rt: *const core.JSRuntime, symbol: atom.Atom) ?[]const u8`。
- **作用**：查询公开或 private 符号的现有描述。
- **实现**：kind 缺失或为 string 时返回 null，其他转发 atoms.symbolDescription。
- **所有权 / 错误 / 调用**：不是完整 JS getter：直接接受 atom id，包含 private kind；无 body、无描述及不活跃的观察结果均可为 null。返回借用名称，不分配。

### `registryKey` (`src/core/symbol.zig:25`)

- **签名**：`pub fn registryKey(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8`。
- **作用**：查询 global_symbol 条目的名称。
- **实现**：kind 必须为 global_symbol，再返回 atoms.name。
- **所有权 / 错误 / 调用**：不检查 registry_managed_symbol、isRegisteredSymbol 或 body 是否已物化；未匹配返回 null。借用 bytes 的寿命受动态条目回收约束。

### `canBeHeldWeakly` (`src/core/symbol.zig:32`)

- **签名**：`pub fn canBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool`。
- **作用**：按当前值分类决定是否可作为弱持有目标。
- **实现**：isObject 为 true 直接接受；否则需 asSymbolAtom 成功且 atoms.kind(id)==symbol。
- **所有权 / 错误 / 调用**：global_symbol/private 及其他原语被拒绝；预定义公开符号也是 symbol kind，因此可通过。不创建根、不检查对象 header kind 或执行收集阶段可达性判定。

## 覆盖核对

- 清单函数数: 105（`src/core/atom.zig` 102 + `src/core/symbol.zig` 3）
- 本文标题覆盖: 105
- 未覆盖: 无
