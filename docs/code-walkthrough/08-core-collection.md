# 08 — Map/Set/WeakMap/WeakSet 哈希后端

`collection.zig`：开链哈希叠在 `Object` 的 collection 槽上。SameValueZero 强键；弱键走 identity，不是强 GC 边。零 exec 依赖。原生方法在 `exec/collection_ops.zig`；VM Map-fusion 快路径（`mapGetLatin1PrefixIntValue` / `mapSetLatin1PrefixInt32Range`）也在这里。

`strong_no_entry` / `weak_no_entry` = `collection_no_entry`（`maxInt(usize)`）。强/弱索引创建阈值均为8；没有桶时线性扫描，曾建立的桶可在条目数降到8以下后继续保留，不能只按当前size推断查找路径。桶数至少16且为2幂，增长触发负载超过3/4。

## 类型（payload 侧）

`CollectionEntry`：`key`/`value`/`active`/`hash`/`hash_next`。`WeakCollectionEntry`：`key_identity`/`value`/`hash`/`hash_next`。见 payloads 分册的 `destroy`。

游标（迭代器、forEach）保存条目下标，活游标阻止重排，但不保证底层分配地址固定。无游标且墓碑至少4项、占数组至少一半时，删除路径原地稳定压缩，再尽力缩容；清空路径保留容量。弱表没有JS可见迭代顺序，删除采用尾项交换，桶链摘除仍有碰撞扫描成本。

本文件的 `BigIntHashParts` 保存符号与借用limb slice，短值借用调用方scratch，堆值借用BigInt存储。强表key/value为追踪边；弱表key_identity不保活键，value由GC的ephemeron流程按表与键的可达性处理。这里的helper不实现用户可见方法分派或所有输入校验。

---

### `findStrongEntry` (`src/core/collection.zig:34`)

- **签名**：`pub fn findStrongEntry(object: *core.Object, key: core.JSValue) ?usize`。
- **作用**：按SameValueZero查找活的强集合条目。
- **实现**：先计算key哈希；有桶则沿hash_next链检查active、hash及SameValueZero，链下标超entries长度返回null。无桶时扫描活条目，只比较SameValueZero，不检查存储hash。
- **所有权 / 错误 / 调用**：返回借用数组下标，数组变化后须重新验证；不验证对象class，不检测链环。索引分支依赖存储hash与键内容一致，无桶分支虽仍计算hash却不使用它过滤。

### `findStrongEntryLatin1Concat` (`src/core/collection.zig:56`)

- **签名**：`pub fn findStrongEntryLatin1Concat(object: *core.Object, prefix: []const u8, digits: []const u8, hash: u64) ?usize`。
- **作用**：查找内容等于两段Latin1拼接的活条目。
- **实现**：有桶时用调用方hash定位并比较active/hash/字符串内容；无桶时逐活条目作内容比较，忽略hash。越界链指针返回null。
- **所有权 / 错误 / 调用**：hash必须匹配实际拼接内容；不创建拼接键，但比较helper调用asStringBody，rope可能展开，不能承诺完全无分配。也没有链环检测。

### `strongSize` (`src/core/collection.zig:77`)

- **签名**：`pub fn strongSize(object: *core.Object) usize`。
- **作用**：读取记录的强集合活条目数。
- **实现**：直接返回object.collectionActiveCount()。
- **所有权 / 错误 / 调用**：不是重新扫描或核验数组；计数正确性依赖追加、删除和压缩路径维护，不检查Map/Set class。

### `strongEntryHash` (`src/core/collection.zig:83`)

- **签名**：`pub fn strongEntryHash(value: core.JSValue) u64`。
- **作用**：为集合键选择对应哈希机制。
- **实现**：int先扩f64与float共用hashNumber；bool/null/undefined用常量；BigInt按值部件，字符串/rope按内容，Symbol按atom ID，object/module用refHeader地址，function_bytecode 用 functionBytecodeHeader 地址，其他tag只混tag位。
- **所有权 / 错误 / 调用**：哈希不是唯一身份，碰撞仍需SameValueZero比较。数字int/float同值、所有NaN和正负零使用一致哈希；内部无效值不具备完整类型校验。

### `hashNumber` (`src/core/collection.zig:99`)

- **签名**：`fn hashNumber(number: f64) u64`。
- **作用**：规范化数值键的哈希输入。
- **实现**：所有NaN使用同一常量，number==0使用0（含负零），其余混合f64位型。
- **所有权 / 错误 / 调用**：返回的是mix64结果，不是原始0或NaN位型；无分配，与SameValueZero数值等价关系对应。

### `hashStringValue` (`src/core/collection.zig:106`)

- **签名**：`fn hashStringValue(value: core.JSValue) u64`。
- **作用**：计算字符串内容与长度组合的哈希。
- **实现**：stringValueContentHash失败时回退hashRefPointer；否则内容hash异或字符串长度左移32位，再mix64。
- **所有权 / 错误 / 调用**：共享内容hash可遍历未展开rope，不必通过此函数构造flat副本；此函数依赖有效字符串表示，不把字符串地址当常规内容身份。

### `strongEntryHashLatin1ConcatWithSeed` (`src/core/collection.zig:111`)

- **签名**：`pub fn strongEntryHashLatin1ConcatWithSeed(prefix: []const u8, digits: []const u8, seed: u32) u64`。
- **作用**：用已累计的前缀hash计算拼接字符串hash。
- **实现**：对digits继续hashLatin1(seed)，foldHash30后与(prefix.len+digits.len)<<32异或，再mix64。
- **所有权 / 错误 / 调用**：不读取prefix字节，仅使用其长度；调用方必须提供正确前缀seed（通常hashLatin1(prefix,0)），否则与通用字符串hash不一致。长度相加用普通usize运算，无通用溢出保护。

### `stringValueEqlLatin1Concat` (`src/core/collection.zig:119`)

- **签名**：`fn stringValueEqlLatin1Concat(value: core.JSValue, prefix: []const u8, digits: []const u8) bool`。
- **作用**：比较可解析的字符串体与prefix加digits的Latin1内容。
- **实现**：stringFromValue拿到body，否则false；长度不等false；latin1分别比较两段，utf16委托逐单元比较。
- **所有权 / 错误 / 调用**：stringFromValue实际调用asStringBody，rope可能展开；它并非isString守卫，调用方依赖合法集合键表示。Latin1字节按码点0–255比较，不是UTF-8解码。

### `utf16EqlLatin1Concat` (`src/core/collection.zig:129`)

- **签名**：`fn utf16EqlLatin1Concat(units: []const u16, prefix: []const u8, digits: []const u8) bool`。
- **作用**：将UTF-16单元与两段Latin1字节逐一比较。
- **实现**：先检查总长度，依次比较prefix及digits各字节零扩展后的u16值，任一不同false。
- **所有权 / 错误 / 调用**：无需编码转换或分配；支持完整Latin1，不限ASCII。不能把UTF-8多字节序列作为同一码点处理。

### `bigIntHashParts` (`src/core/collection.zig:145`)

- **签名**：`fn bigIntHashParts(value: core.JSValue, scratch: *[2]bignum.Limb) ?BigIntHashParts`。
- **作用**：借出BigInt符号与低位优先的limbs视图。
- **实现**：短BigInt扩i128取绝对值，拆到调用方两个limb scratch，0得到空slice；其他路径从refHeader恢复堆BigInt并借出negative/limbs，缺header返回null。
- **所有权 / 错误 / 调用**：只短值路径使用scratch，返回slice不得超过scratch或堆值寿命；堆路径不再检查GC kind，调用方须保证确是BigInt。无克隆或释放。

### `hashBigIntValue` (`src/core/collection.zig:162`)

- **签名**：`fn hashBigIntValue(value: core.JSValue) u64`。
- **作用**：混合BigInt的符号、limb数与各limb。
- **实现**：取得parts，失败回退指针hash；按negative选种子，异或limb数乘常量，再逐limb混合，最后再mix64。
- **所有权 / 错误 / 调用**：依赖BigInt规范化表示保证相等值具有相同limbs/符号；JS BigInt没有独立负零，不能把符号种子解释成-0n与0n不同。函数自身不去除前导零limb或修正异常负零表示。

### `hashRefPointer` (`src/core/collection.zig:171`)

- **签名**：`fn hashRefPointer(value: core.JSValue) u64`。
- **作用**：按引用header地址计算hash。
- **实现**：refHeader为空则mix64(tagHashBits(tag))，否则把header地址转u64后mix64。
- **所有权 / 错误 / 调用**：不持有或追踪引用；有header时不额外混入tag，不保证不同类型地址拥有不同hash。

### `hashObjectPointer` (`src/core/collection.zig:176`)

- **签名**：`fn hashObjectPointer(value: core.JSValue) u64`。
- **作用**：按 functionBytecodeHeader 给出的地址计算 hash。
- **实现**：有header则mix64其地址，没有则混tag位。
- **所有权 / 错误 / 调用**：用于function_bytecode分支；区别在取header的接口，并非总额外加入类型盐。无分配或对象有效性检查。

### `mix64` (`src/core/collection.zig:181`)

- **签名**：`fn mix64(input: u64) u64`。
- **作用**：对u64作固定的整数混合。
- **实现**：先以+%加0x9e3779b97f4a7c15，再两次移位异或与*%乘常量，最后异或右移31位。
- **所有权 / 错误 / 调用**：所有加乘明确回绕；不是加密hash，无随机seed、分配或运行时状态。

### `tagHashBits` (`src/core/collection.zig:188`)

- **签名**：`fn tagHashBits(tag: i32) u64`。
- **作用**：将有符号tag转成用于混合的64位位型。
- **实现**：i32先符号扩展成i64，再bitCast为u64。
- **所有权 / 错误 / 调用**：负tag高位保留符号扩展，不是零扩展u32或绝对值。

### `bucketIndex` (`src/core/collection.zig:192`)

- **签名**：`fn bucketIndex(hash: u64, bucket_count: usize) usize`。
- **作用**：把hash低位映射为桶下标。
- **实现**：返回hash & (bucket_count-1)，转换成usize。
- **所有权 / 错误 / 调用**：要求bucket_count非零且通常为2的幂；本函数不校验该前提，不使用高位或除法取模。

### `findWeakEntry` (`src/core/collection.zig:198`)

- **签名**：`pub fn findWeakEntry(object: *core.Object, key_identity: usize) ?usize`。
- **作用**：按稳定弱键identity查条目下标。
- **实现**：计算weakEntryHash；有桶时沿链同时比较hash与key_identity，链下标越界返回null；无桶时线性只比identity。
- **所有权 / 错误 / 调用**：不判定弱目标是否仍活着、不做GC身份解析；弱条目没有active过滤。返回下标会受删除交换影响，未检测链环。

### `weakEntryHash` (`src/core/collection.zig:219`)

- **签名**：`fn weakEntryHash(key_identity: usize) u64`。
- **作用**：将弱键identity混合成u64。
- **实现**：usize转u64后调用mix64。
- **所有权 / 错误 / 调用**：不验证identity有效性、非零或目标存活；对象/符号身份编码由其他层提供。

### `appendStrongEntryWithHash` (`src/core/collection.zig:225`)

- **签名**：`pub fn appendStrongEntryWithHash(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry, hash: u64) !usize`。
- **作用**：追加一个强条目并维护活计数和桶链。
- **实现**：复制entry并覆盖hash/hash_next，按active_count+1预留索引，再appendCollectionEntryUnindexed；成功后更新活计数、链入桶，返回新下标。
- **所有权 / 错误 / 调用**：不查重、不重算调用方hash，也不强制entry.active=true，调用方须保证活条目。底层append发布key/value GC屏障；若追加失败，已扩好的桶表可保留，不是所有容量状态都回滚。

### `appendStrongEntryOwned` (`src/core/collection.zig:237`)

- **签名**：`pub fn appendStrongEntryOwned(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !void`。
- **作用**：计算键hash后追加强条目。
- **实现**：委托appendStrongEntryWithHash并丢弃下标。
- **所有权 / 错误 / 调用**：Owned名称不表示RC释放或清空调用方entry；输入按值复制，存入集合后由其GC边追踪。保留底层查重/active/失败合同。

### `ensureStrongIndexForInsert` (`src/core/collection.zig:241`)

- **签名**：`pub fn ensureStrongIndexForInsert(rt: *core.JSRuntime, object: *core.Object, next_active_count: usize) !void`。
- **作用**：为通常的一次追加准备强表索引容量。
- **实现**：next_active_count<8立即返回；无桶时以bucketCountForActiveCount创建；已有桶且4*count>3*buckets时只翻倍一次重建。
- **所有权 / 错误 / 调用**：负载允许等于3/4，不是严格小于；任意大幅跳增的count不保证一次翻倍足够。乘法/倍增为普通usize运算，不处理溢出。成功可修改hash链与桶表，后续append失败不撤销扩容。

### `bucketCountForActiveCount` (`src/core/collection.zig:253`)

- **签名**：`fn bucketCountForActiveCount(active_count: usize) usize`。
- **作用**：求至少16的2幂桶数，使目标负载不超过3/4。
- **实现**：从16开始，在active_count*4>bucket_count*3时反复翻倍。
- **所有权 / 错误 / 调用**：即使active_count=0也返回16；无分配，不检查乘法或倍增溢出，依赖可实现的集合规模。

### `rebuildStrongIndex` (`src/core/collection.zig:259`)

- **签名**：`fn rebuildStrongIndex(rt: *core.JSRuntime, object: *core.Object, bucket_count: usize) !void`。
- **作用**：重新计算活条目hash并构建桶表。
- **实现**：先分配并清空新heads；逐条将hash_next清为sentinel，跳过非active项，对活项重算hash并头插；最后释放旧heads并替换槽。
- **所有权 / 错误 / 调用**：分配失败发生在条目修改前；之后没有返回错误的步骤。保留entry顺序/容量/活计数，墓碑不入桶；bucket_count需为有效非零2幂。

### `linkStrongEntry` (`src/core/collection.zig:278`)

- **签名**：`fn linkStrongEntry(object: *core.Object, index: usize) void`。
- **作用**：按条目存储hash把其下标插到桶链头。
- **实现**：无桶则返回，否则读取entries[index]的hash，写hash_next为旧桶头，再把桶头改为index。
- **所有权 / 错误 / 调用**：不校验index、active、是否已入链或hash正确性；重复调用可能产生重复/环。无分配，不更新活计数。

### `unlinkStrongEntry` (`src/core/collection.zig:287`)

- **签名**：`fn unlinkStrongEntry(object: *core.Object, index: usize) void`。
- **作用**：从条目所属桶链中摘除指定下标。
- **实现**：无桶或index越界直接返回；按目标存储hash找桶，沿指向链接的指针查找。命中则前驱跳过当前节点；遍历遇越界索引则截断此链接。
- **所有权 / 错误 / 调用**：不清条目key/value、active或hash_next，不改活计数；只查一个桶，不检测链环或纠正错桶。

### `appendWeakEntry` (`src/core/collection.zig:309`)

- **签名**：`pub fn appendWeakEntry(rt: *core.JSRuntime, object: *core.Object, entry: core.object.WeakCollectionEntry) !void`。
- **作用**：追加弱身份条目并登记弱引用持有对象。
- **实现**：重算identity hash，retainWeakIdentity；记录原holder状态，必要时先注册（配errdefer撤销），预留索引与entry容量，再扩slice写条目并链入。
- **所有权 / 错误 / 调用**：失败释放本次identity保留，并仅撤销本次新增holder；扩容后的容量/桶表可保留，不能把这些errdefer泛称任意状态完整回滚。retain只对符号弱引用记账，对对象identity为空操作，不把弱目标变成强GC边。原先末尾那次无条件的 registerBorrowedReferenceHolder 已删除：注册本身幂等，而它一旦失败会触发前面的 errdefer 去注销一个条目已经链入桶的 holder，回滚并不对称。

### `ensureWeakIndexForInsert` (`src/core/collection.zig:333`)

- **签名**：`fn ensureWeakIndexForInsert(rt: *core.JSRuntime, object: *core.Object, next_count: usize) !void`。
- **作用**：准备弱表桶索引。
- **实现**：next_count<8返回；无桶时按负载创建，有桶且负载超过3/4时翻倍一次。
- **所有权 / 错误 / 调用**：与强表使用同一对象bucket槽，但按弱entry身份重建。不会缩小已有桶；大幅跳增不保证一次翻倍足够，普通算术依赖规模前提。

### `rebuildWeakIndex` (`src/core/collection.zig:345`)

- **签名**：`fn rebuildWeakIndex(rt: *core.JSRuntime, object: *core.Object, bucket_count: usize) !void`。
- **作用**：按所有弱条目identity重建桶链。
- **实现**：分配清空新heads，逐条重算hash、重置hash_next并头插，最后释放旧heads、替换槽。
- **所有权 / 错误 / 调用**：无active/目标存活过滤，不验证identity；分配失败保留原表。条目顺序、weak identity保留计数及holder登记不变。

### `linkWeakEntry` (`src/core/collection.zig:363`)

- **签名**：`fn linkWeakEntry(object: *core.Object, index: usize) void`。
- **作用**：将弱条目当前下标头插到其桶。
- **实现**：无桶直接返回；否则用存储hash定位，修改条目hash_next和桶头。
- **所有权 / 错误 / 调用**：前提是index有效且尚未在链中；不注册holder、保留identity或验证目标存活。

### `unlinkWeakEntry` (`src/core/collection.zig:375`)

- **签名**：`fn unlinkWeakEntry(object: *core.Object, index: usize) void`。
- **作用**：从一个弱桶链摘掉指定条目下标。
- **实现**：无桶或index越界返回；沿该条目hash对应链寻找，命中则前驱绕过；遇越界链下标截断链。
- **所有权 / 错误 / 调用**：不删除数组元素或release identity，也不检测环；swap-remove分别摘掉victim和尾部mover后另行重新链接。单桶查找成本取决于碰撞链长度。

### `shouldCompactStrongEntries` (`src/core/collection.zig:408`)

- **签名**：`fn shouldCompactStrongEntries(object: *core.Object) bool`。
- **作用**：判断是否应压缩强表墓碑。
- **实现**：有live cursor返回false；否则tombstones=len-active_count，须至少4且tombstones*2>=len。
- **所有权 / 错误 / 调用**：只做判据，不压缩或缩容；依赖active_count<=len及计数一致。游标限制保护下标语义，不代表数组地址永远固定。

### `compactStrongEntries` (`src/core/collection.zig:425`)

- **签名**：`fn compactStrongEntries(object: *core.Object) void`。
- **作用**：原地稳定压缩强表活条目并重连桶。
- **实现**：按原顺序向前复制活项，空出尾部清成undefined key/value、inactive和sentinel；缩短slice并assert长度等于active_count。有桶则清桶并使用保存hash重新头插。
- **所有权 / 错误 / 调用**：不分配、不释放entry容量，不重算键hash；调用方须先保证没有live cursor，本函数不检查这一条件。清尾避免旧长slice看到重复活项，但不让跨扩容或GC的旧借用自动安全。

### `shrinkStrongStorage` (`src/core/collection.zig:466`)

- **签名**：`fn shrinkStrongStorage(rt: *core.JSRuntime, object: *core.Object) void`。
- **作用**：在强表显著缩小时尽力回收多余容量。
- **实现**：以当前entry slice长度为live。entry容量>=32且live*4<=容量时，尝试缩到至少8且>=2*live的2幂；分配成功复制/替换/释放旧块。桶数>=32且满足相同稀疏条件时，再尝试按bucketCountForActiveCount缩桶并以存储hash重连。
- **所有权 / 错误 / 调用**：两次分配分别catch失败，不让删除报错；entry缩容成功而桶缩容失败是允许状态。预期在压缩后调用：桶重连不筛active，函数也不检查游标。重新分配可使旧slice/指针失效，非原地减容量。

### `removeStrongEntry` (`src/core/collection.zig:499`)

- **签名**：`pub fn removeStrongEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) void`。
- **作用**：删除活强条目，并按条件压缩与缩容。
- **实现**：takeStrongEntry失败则返回；成功后仅shouldCompactStrongEntries为true才压缩，再尽力shrinkStrongStorage。
- **所有权 / 错误 / 调用**：无可恢复错误返回；常规删除先留墓碑，不保证立即释放数组容量。无游标且达到墓碑阈值才搬动条目。

### `rollbackLastStrongEntry` (`src/core/collection.zig:506`)

- **签名**：`fn rollbackLastStrongEntry(object: *core.Object, index: usize) void`。
- **作用**：撤销末尾活条目并缩短逻辑长度。
- **实现**：assert index+1==len；takeStrongEntry成功后len=index，失败直接返回。
- **所有权 / 错误 / 调用**：只支持末尾活条目：末尾已inactive时不会缩短。容量不回退、不销毁key/value堆对象或清空调用方值。

### `rollbackStrongEntriesTo` (`src/core/collection.zig:513`)

- **签名**：`pub fn rollbackStrongEntriesTo(object: *core.Object, len: usize, active_count: usize) void`。
- **作用**：撤回一段新增活尾项并恢复给定活计数。
- **实现**：当当前len大于目标len时反复rollbackLastStrongEntry，最后直接写active_count。
- **所有权 / 错误 / 调用**：要求被撤销尾项均active，否则循环可能不前进；目标len/计数必须是合法快照。不会恢复已覆盖的旧值、桶容量或entry容量，目标len大于当前len也不会补齐。

### `removeWeakEntry` (`src/core/collection.zig:533`)

- **签名**：`pub fn removeWeakEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) !void`。
- **作用**：从弱数组移除条目，用尾项填洞。
- **实现**：要求数组非空且index有效；先摘victim桶链，非尾项时再摘尾项旧链，复制尾项到index、缩len并重链；最后destroy旧entry释放identity记账，按需prune holder。
- **所有权 / 错误 / 调用**：当前函数虽返回!void，内部没有try或错误返回；prune也是void。无分配，但摘链需扫描桶链，不能称最坏O(1)。不清空逻辑范围外尾槽、不缩容量。

### `clearStrongEntries` (`src/core/collection.zig:557`)

- **签名**：`pub fn clearStrongEntries(object: *core.Object) void`。
- **作用**：清空活强条目，同时保留可复用容量。
- **实现**：len=0直接返回；active_count=0时仅在无游标时缩len。否则清桶与活计数，无游标则先缩len为0，再通过底层ptr把原活槽写成undefined/inactive；有游标保留墓碑长度。
- **所有权 / 错误 / 调用**：不立即释放key/value堆分配，不shrink entry或bucket容量；仅解除这些槽的GC边。早退路径依赖原有计数/桶一致性，不是修复损坏状态的操作。

### `takeStrongEntry` (`src/core/collection.zig:589`)

- **签名**：`fn takeStrongEntry(object: *core.Object, index: usize) ?core.object.CollectionEntry`。
- **作用**：摘除活条目并返回其值副本。
- **实现**：越界或inactive返回null；否则unlink，保存旧entry，把槽写成undefined key/value、inactive与sentinel；活计数非0才减1。
- **所有权 / 错误 / 调用**：不缩slice、不释放容量；返回值没有额外root/retain，原槽已不再追踪key/value。返回副本的hash_next仍是原链数据，不是新可链接条目保证。

### `clearWeakEntries` (`src/core/collection.zig:600`)

- **签名**：`pub fn clearWeakEntries(rt: *core.JSRuntime, object: *core.Object) void`。
- **作用**：内部清空弱集合条目并释放identity记账。
- **实现**：从尾向前先缩len再entry.destroy；结束后清空heads并prune holder。
- **所有权 / 错误 / 调用**：保留entry和bucket分配，不逐槽置空；不暴露标准WeakMap.clear方法，不能把内部helper当作JS API。prune只在无其他借用引用时注销holder。

### `weakKeyIdentityRegister` (`src/core/collection.zig:617`)

- **签名**：`pub fn weakKeyIdentityRegister(rt: *core.JSRuntime, value: core.JSValue) !?usize`。
- **作用**：为插入路径取得可弱持有键的identity。
- **实现**：canBeHeldWeakly失败返回null；否则weakIdentityFromValue对Symbol编码(atom<<1)|1，对有效Object登记runtime身份；对象候选还检查GC header kind。
- **所有权 / 错误 / 调用**：对象登记可能失败；非注册Symbol直接编码不必新增对象identity。此步骤本身不retainWeakIdentity，条目append才负责符号弱引用记账。

### `weakKeyIdentityPeek` (`src/core/collection.zig:625`)

- **签名**：`pub fn weakKeyIdentityPeek(rt: *core.JSRuntime, value: core.JSValue) ?usize`。
- **作用**：查询键identity而不创建对象登记。
- **实现**：先canBeHeldWeakly过滤；Symbol直接编码，Object走peekWeakObjectIdentity，从未登记对象返回null。
- **所有权 / 错误 / 调用**：只读无分配；Symbol可在从未插入弱集合时也返回identity，所以非null不证明存在条目。对象/符号目标活性仍由其他机制决定。

### `sweepWeakEntries` (`src/core/collection.zig:634`)

- **签名**：`pub fn sweepWeakEntries( rt: *core.JSRuntime, object: *core.Object, context: ?*anyopaque, isLive: *const fn (?*anyopaque, usize) bool, ) !usize`。
- **作用**：根据外部存活谓词删除弱条目。
- **实现**：先要求WeakMap/WeakSet，否则TypeError；从i=0扫描，存活则i++，不存活则removeWeakEntry并增加删除数，不递增i以继续检查交换来的尾项。
- **所有权 / 错误 / 调用**：返回删除数量，不自行标记或计算ephemeron闭包；isLive及context借用，谓词应遵守GC遍历期间不破坏集合的合同。

### `setWeakMapEntryByIdentityChecked` (`src/core/collection.zig:658`)

- **签名**：`pub fn setWeakMapEntryByIdentityChecked(rt: *core.JSRuntime, object: *core.Object, key_identity: usize, value: core.JSValue) !void`。
- **作用**：在已验证的WeakMap中按identity更新或插入值。
- **实现**：findWeakEntry命中则直接替换entry.value；未命中创建WeakCollectionEntry并appendWeakEntry。
- **所有权 / 错误 / 调用**：Checked意为调用方已校验，不在此检查class/identity。命中分支没有显式GC屏障或重新登记holder；值的存活由弱集合GC/ephemeron规则处理，不是无条件强边。

### `setWeakMapEntryByIdentity` (`src/core/collection.zig:670`)

- **签名**：`pub fn setWeakMapEntryByIdentity(rt: *core.JSRuntime, object: *core.Object, key_identity: usize, value: core.JSValue) !void`。
- **作用**：带class检查的弱表identity写入口。
- **实现**：class非weakmap返回TypeError；否则委托Checked版本。
- **所有权 / 错误 / 调用**：不验证identity来自合法键、已登记或仍存活，调用方负责；追加错误传播。

### `setWeakMapEntry` (`src/core/collection.zig:677`)

- **签名**：`pub fn setWeakMapEntry(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !void`。
- **作用**：从键值解析身份后更新WeakMap。
- **实现**：要求WeakMap class；weakKeyIdentityRegister返回null则TypeError，得到identity后委托Checked。
- **所有权 / 错误 / 调用**：键登记成功而后续append失败时不会回滚对象identity登记；无用户属性调用，不是一般JS WeakMap方法包装。

### `mapGetLatin1PrefixIntValue` (`src/core/collection.zig:688`)

- **签名**：`pub fn mapGetLatin1PrefixIntValue(object: *core.Object, prefix: []const u8, int_value: i32) ?core.JSValue`。
- **作用**：按Latin1前缀加有符号十进制i32查Map值。
- **实现**：非Map返回null；formatInt32写栈上16字节缓冲，计算前缀seed与拼接hash，调用concat查找；命中返回entry.value副本。
- **所有权 / 错误 / 调用**：支持负整数文本；不创建拼接key，但比较现有rope可能展开，因此连miss也不能统称无分配。返回无RC dup或独立根，null与存储的JS null值不同。

### `mapSetLatin1PrefixInt32Range` (`src/core/collection.zig:701`)

- **签名**：`pub fn mapSetLatin1PrefixInt32Range( rt: *core.JSRuntime, object: *core.Object, prefix: []const u8, start: i32, limit: i32, ) !void`。
- **作用**：批量设置prefix加十进制i对应的Map值为i。
- **实现**：非Map、start<0或limit<start为TypeError；空范围返回。按最大新增数预留entry与索引，再保存len/活计数。循环命中覆盖value，缺失则创建Latin1拼接字符串并追加；首次追加后设inserted，错误时回滚新增尾项。
- **所有权 / 错误 / 调用**：回滚只删除新插入项，不恢复已覆盖的旧值或预留容量；循环中后续索引仍可继续扩容。没有函数级显式根帧。（末尾那条 `if (inserted) inserted = false;` 是无效果的死语句，已删除。）

### `stringFromValue` (`src/core/collection.zig:745`)

- **签名**：`fn stringFromValue(value: core.JSValue) ?*core.string.String`。
- **作用**：为字符串比较取得flat String body。
- **实现**：直接委托JSValue.asStringBody。
- **所有权 / 错误 / 调用**：string/string_rope按该共享接口返回body，rope可flatten；接口也处理symbol tag，本函数没有单独isString守卫或错误联合体，不等于任意输入的无分配类型判定。

## 覆盖核对

- 清单函数数: 49
- 本文标题覆盖: 49
- 未覆盖: 无
