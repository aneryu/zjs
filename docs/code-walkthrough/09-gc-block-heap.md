# 09 — Block heap / space / carrier

本文件覆盖 block heap 几何、size class、carrier 身份与表示常量。四张 bitmap、superblock/block/cell 的合同见 [09-gc.md](09-gc.md)。

函数级展开。总图见 [09-gc.md](09-gc.md)。写作规范见 [_spec.md](_spec.md)。

## `src/core/gc_representation_constants.zig`

零函数文件：allocator、GC prefix 读者、block heap、表示快照共享的**字节常量**。本模块故意不 import 任何东西，这样 `memory.zig` 不必为了对齐 prefix 而依赖 `gc.zig`。

### 布局

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `metadata_size` | 8 | 每个 GC 对象前面的 prefix |
| `metadata_size_class_offset` | 0 | `size_class: u16` |
| `metadata_alloc_info_offset` | 2 | `AllocInfo` 一字节 |
| `metadata_flags_offset` | 3 | kind+young+finalizing+needs_finalizer |
| `metadata_lifetime_offset` | 4 | mark epoch + remembered/shape summary |
| `metadata_young_mask` | `1<<4` | flags 里的 young 位，必须在 kind nibble 之上 |

### kind 标签（allocator 手写进 prefix）

`object_kind_tag=0`、`string_kind_tag=6`、`rope_kind_tag=11`、`string_buffer_kind_tag=12`、`property_storage_kind_tag=8`、`array_storage_kind_tag=9`、`payload_kind_tag=10`。`kind_mask=0x0f`。`gc.zig` comptime 断言 `RefKind` 编码仍与这些标签一致。

### alloc_info

`alloc_info_class_mask=0x1f`、`alloc_info_heap_accounted_mask=1<<6`、`alloc_info_standalone_mask=1<<7`。`block_cell_size_class: u5=0x1f` 饱和五位，唯一标识 collector block cell；`block_cell_alloc_info: u8` 取同一值，不预置 class 域外的 accounting 或 allocation 位。

string_buffer、property_storage、array_storage、payload 是裸存储种类：owner 的 storageCell 边负责标记，回收由 bitmap/extent sweep 归还，不把其 body 当 Header 读取，也不执行 body 析构。object/string/rope 则有各自载体语义。

### 空闲 cell 毒液

`free_cell_link_mask=0x0000_ffff` 低 16 位存后继；`free_cell_poison=0x8600_0000` 高半是毒。读成活 metadata 时：`heap_accounted=0`、kind nibble 读成 `.string`、**不是** block-cell class。bit7 reserved 保持 SET 只为钉住 0x86，让 allocator 空闲路径字节相同。condemnation 不在空闲 cell 里，而在 lifetime word（free 路径不写它）。

comptime 块检查：lifetime 填满 8 字节；block-cell discriminator 占 class 域；poison 不重叠 link、不冒充 block cell、不读成 heap_accounted、kind nibble 仍是 string、young 位在 nibble 之上。


本文件清单函数数为 0；类型/常量见上一节。

## `src/core/gc_space.zig`

64 KiB block heap 的 size class 表和发布直方图。classes 在编译期生成：先是每 16 字节一档的 16..128，随后使用 nextGeometricClass 的近似 1.25 倍序列；每档还要满足每 block 至少 16 个 cell。修改冻结值会重新生成表，但若它不是满足几何约束的序列成员，编译期检查会报错。

| 常量 / 数据 | 当前值与职责 |
| --- | --- |
| block_bytes / large_min_bytes | 都是 65536；前者是 block 几何大小，后者是 large 空间边界 |
| min_cells_per_block / min_class_bytes | 16 个 cell / 16 字节对齐步长 |
| linear_max_bytes / linear_class_count | 128 字节 / 8 档 |
| coverage_hundredths | 冻结分析采用的百分位目标 99，并非运行期覆盖保证 |
| measured_max_small_payload / max_small_payload | 冻结值与生成表末项，均为 3760；编译期断言两者相等 |
| generated_class_count / class_count / classes | 生成表长度与实际 payload 档位；每档都必须是 16 的倍数 |
| geometric_class_index | 每个 16 字节区间一个 u8 下标，覆盖 129..3760 |
| fine_bucket_step / fine_bucket_limit / fine_bucket_count | 16 字节 / 4096 字节 / 256 桶 |

Histogram 的 buckets 统计细桶，over_fine 统计 4097..65535，large 统计 ≥65536；total 和 bytes_total 分别累计发布次数与请求 payload 总字节。object_publications 与 slots2_object_publications 单独计对象发布，用于报告 slots2 比例。所有字段默认零，统计的是发布历史，不是当前存活集合。

源码记录的历史采样包含 string 发布：pdfjs 的 p99 超过 4096，已经高于当前几何容量。因此 cutoffForCoverage 饱和在 3760，不能把函数名称理解为“必然覆盖 99%”。3760 加 prefix 后可容纳 17 个 cell，下一档 4688 只能容纳 13 个。

### `nextGeometricClass` (`src/core/gc_space.zig:53`)

- **签名**：`fn nextGeometricClass(prev: usize) usize`。
- **作用**：计算 128 字节以上几何序列的下一档。
- **实现**：先算 (prev*5+2)/4，再向下对齐 16；若结果未增长则加 16。例如 160→192、192→240。
- **所有权 / 错误 / 调用**：纯整数计算，供编译期生成和统计推导共用；输入来自受限的 class 序列，普通乘加没有任意 usize 输入的溢出保护。

### `classIndexForPayload` (`src/core/gc_space.zig:127`)

- **签名**：`pub fn classIndexForPayload(payload: usize) ?usize`。
- **作用**：返回能容纳 payload 的最小 small class 下标。
- **实现**：0..16 返回 0；17..128 用 ceil(payload/16)-1；129..3760 以 16 字节区间查 geometric_class_index；更大返回 null。
- **所有权 / 错误 / 调用**：无分配；返回的是下标，不是字节数。null 只表示不能用 small class，medium/large 的选择在调用方。

### `Histogram.record` (`src/core/gc_space.zig:151`)

- **签名**：`pub fn record(self: *Histogram, payload: usize) void`。
- **作用**：累计一次 payload 发布事件及其大小分桶。
- **实现**：total 加一，bytes_total 饱和累加；payload≥65536 计 large，4096<payload<65536 计 over_fine，其余计 16 字节细桶。零字节和 1..16 同在首桶。
- **所有权 / 错误 / 调用**：原地修改统计，无分配。bytes_total 使用饱和加法，total、large、over_fine 和桶计数是普通加法。

### `Histogram.recordObject` (`src/core/gc_space.zig:166`)

- **签名**：`pub fn recordObject(self: *Histogram, payload: usize, slots2: bool) void`。
- **作用**：记录对象发布，并细分 slots2 对象数量。
- **实现**：先 record(payload)，再饱和递增 object_publications；slots2 为真时再饱和递增 slots2_object_publications。
- **所有权 / 错误 / 调用**：与普通发布共用大小分布；两个对象计数供报告作分母/分子，不代表存活对象数。此函数本身不检查统计开关。

### `Histogram.percentilePayloadBelowLarge` (`src/core/gc_space.zig:173`)

- **签名**：`pub fn percentilePayloadBelowLarge(self: Histogram, hundredths: usize) usize`。
- **作用**：估计非 large 发布样本的百分位 payload 上界。
- **实现**：以 total 饱和减 large 得到样本量，交给 percentileOf；细桶返回桶上界，over_fine 返回 65535。
- **所有权 / 错误 / 调用**：按事件数计算，不按字节加权；输入 hundredths 通常为 1..100，本函数不验证范围。

### `Histogram.coveredByMaxSmall` (`src/core/gc_space.zig:178`)

- **签名**：`pub fn coveredByMaxSmall(self: Histogram) usize`。
- **作用**：统计当前 small 截止值能容纳的发布次数。
- **实现**：total 为零直接返回零；否则累加前 ceil(max_small_payload/16) 个细桶，并以 buckets.len 限制范围。当前是前 235 桶，对应 payload≤3760。
- **所有权 / 错误 / 调用**：返回次数，不是覆盖比例；不含 over_fine 或 large。统计按发布累计，并非当前堆快照。

### `Histogram.belowLarge` (`src/core/gc_space.zig:187`)

- **签名**：`pub fn belowLarge(self: Histogram) usize`。
- **作用**：返回非 large 发布次数。
- **实现**：计算 total -| large，饱和减法避免不一致计数下出现负数。
- **所有权 / 错误 / 调用**：只读值查询；不修复 Histogram 中不一致的字段。

### `percentileOf` (`src/core/gc_space.zig:192`)

- **签名**：`fn percentileOf( pop: usize, hundredths: usize, buckets: [fine_bucket_count]usize, over_fine: usize, ) usize`。
- **作用**：从分桶计数求百分位的桶上界。
- **实现**：pop==0 返回 0；目标排名为 ceil(pop*hundredths/100)。累加细桶，首次到达目标返回 (idx+1)*16；若 over_fine 足以覆盖目标返回 65535，否则返回 65536 哨兵。
- **所有权 / 错误 / 调用**：不插值、不验证百分位或计数一致性。非空样本传 0 会在首桶返回 16；超过 100 可能走哨兵。排名乘加及桶累加没有饱和保护。

### `cutoffForCoverage` (`src/core/gc_space.zig:219`)

- **签名**：`pub fn cutoffForCoverage(hist: Histogram, hundredths: usize) usize`。
- **作用**：依据发布百分位推导 small class 截止值，并受 block 几何上限约束。
- **实现**：need=max(128,percentilePayloadBelowLarge(hundredths))；从 128 沿几何序列增长，直到覆盖 need，或下一档加 8 字节 prefix 后在 64 KiB block 内不足 16 个 cell。当前几何上限为 3760。
- **所有权 / 错误 / 调用**：不修改运行期 classes，也不保证达到所请求覆盖率：百分位大于几何上限时仍返回 3760。空样本返回 128；它是冻结配置的分析工具，不是动态调整分配策略。

## `src/core/gc_carrier.zig`

分配载体的身份、生命周期与计账审计。模块只依赖 std、builtin 与 build_options，不依赖 gc.Header/Registry，也不负责解引用对象或释放原始分配。MemoryAccount 在原始分配前 reserve/prepare，成功后 commit；GC 发布、退役与 raw-free 路径分别推进侧表。

`authority_audit_enabled = builtin.is_test or build_options.zjs_ownership_audit`；block_generation、extent_identity、lifecycle_state、audit_oracle、block_tracking、extent_tracking 六个开关均取该值。默认发货配置关闭这些审计；使用方将相关状态字段编译成 void，并不是本文件里的类型声明本身变成 void。

| 类型 / 字段 | 含义 |
| --- | --- |
| CurrentMembershipKey.base | 当前成员关系所用地址，不带历史 generation |
| AllocationHandle.base / generation | 地址与分配代次；地址相同但 generation 不同代表不同分配 |
| LifecycleState | free、constructing、published、doomed、finalizer_current、parked、rollback_pending、raw_free_in_progress 八种状态，底层 u4 |
| StateMask.bits | u16 状态位集合；owned 排除 free，publishedOnly 只含 published |
| ResolveError | NotFound、NotExactStart、GenerationMismatch、StateMismatch、KindMismatch、HeaderMismatch；这里的方法只返回其中适用的成员，HeaderMismatch 留给集成层 |
| ExtentReservation.generation | reserve 发出的代次，commit 必须带回同一值 |
| ExtentIdentityRecord | base 为 payload 基址，raw_base 为底层分配起点；payload_bytes/raw_bytes 区分请求与原始分配大小，generation 为身份代次，kind 为调用方提供的不可变种类 |
| ExtentIdentityAuthority | records 是 base→身份记录表；next_generation 从 1 递增，generation_exhausted 阻止回绕 |
| ExtentLifecycleRecord | state 默认 constructing，accounted_bytes 默认 0，publish 时更新 |
| ExtentLifecycleAuthority.records | 独立的 base→生命周期表，与 identity 分开，单独的 transition 不验证合法转移图 |
| RawAuditEntry | audit_id 独立于 generation；保存 base/raw_base/raw_bytes/accounted_bytes/kind/generation，published 默认 false |
| HeapAccountingOracle | raw 是独立 raw 分配账本；heap_live_bytes 为已发布总量，large_object_bytes 与 old_live_bytes 按 is_large 参数拆分；next_audit_id 从 1 开始，可回绕并跳过零 |

编译期布局预算：ExtentIdentityRecord 48B、ExtentLifecycleRecord 16B；identity authority 为 safety 40B / 非 safety 32B，lifecycle authority 为 24B / 16B，oracle 为 56B / 48B。它们约束审计表示，不代表生产开启这些侧表。

### `StateMask.of` (`src/core/gc_carrier.zig:48`)

- **签名**：`pub fn of(states: []const LifecycleState) StateMask`。
- **作用**：把允许的生命周期状态集合编码成位掩码。
- **实现**：从零开始，对每个枚举 ordinal 设置 `1 << ordinal`；重复状态只重复置同一位。
- **所有权 / 错误 / 调用**：返回 u16 位集合，不保存输入切片、不分配。

### `StateMask.publishedOnly` (`src/core/gc_carrier.zig:54`)

- **签名**：`pub fn publishedOnly() StateMask`。
- **作用**：构造仅允许 published 的状态集合。
- **实现**：调用 of(&.{.published})。
- **所有权 / 错误 / 调用**：返回值，没有资源生命周期。

### `StateMask.owned` (`src/core/gc_carrier.zig:58`)

- **签名**：`pub fn owned() StateMask`。
- **作用**：构造排除 free 的状态集合。
- **实现**：返回 u16 的 `~1`：清 bit0，其余位为一；对当前八种状态，它包含 constructing 到 raw_free_in_progress。
- **所有权 / 错误 / 调用**：名称描述逻辑状态，不是获取一份分配所有权。未命名的高位同样置一，但 contains 只查询实际枚举值。

### `StateMask.contains` (`src/core/gc_carrier.zig:62`)

- **签名**：`pub fn contains(self: StateMask, state: LifecycleState) bool`。
- **作用**：判断一个状态是否在允许集合中。
- **实现**：用状态 ordinal 生成单 bit，与 bits 按位与，非零即命中。
- **所有权 / 错误 / 调用**：纯值查询，不分配。

### `ExtentIdentityAuthority.deinit` (`src/core/gc_carrier.zig:95`)

- **签名**：`pub fn deinit(self: *ExtentIdentityAuthority, allocator: std.mem.Allocator) void`。
- **作用**：释放 extent 身份索引并重置该 authority。
- **实现**：records.deinit(allocator) 后 self.*=.{}，包括将 next_generation 恢复为 1、清 exhausted。
- **所有权 / 错误 / 调用**：只释放侧表，不释放其记录的原始分配；必须使用建表时的 allocator。重置意味着旧 handle 不可跨 authority 生命周期使用。

### `ExtentIdentityAuthority.reserve` (`src/core/gc_carrier.zig:100`)

- **签名**：`pub fn reserve(self: *ExtentIdentityAuthority, allocator: std.mem.Allocator) std.mem.Allocator.Error!ExtentReservation`。
- **作用**：预留一个记录位置并发出不会回绕的 generation。
- **实现**：若已 exhausted 或 next_generation==maxInt(u64)，置 exhausted 并报 OOM；否则先 ensureUnusedCapacity(1)，再取出当前 generation 并递增。
- **所有权 / 错误 / 调用**：在原始分配前调用；扩容 OOM 不消耗 generation，成功预留后即便原始分配失败也不退回 generation。耗尽被编码为 OutOfMemory。

### `ExtentIdentityAuthority.commit` (`src/core/gc_carrier.zig:111`)

- **签名**：`pub fn commit(self: *ExtentIdentityAuthority, reservation: ExtentReservation, entry: ExtentIdentityRecord) void`。
- **作用**：将已预留的分配身份无分配地写入索引。
- **实现**：断言 base/raw_base/raw_bytes 非零、entry.generation 与 reservation 一致、base 尚不存在，然后 putAssumeCapacity。
- **所有权 / 错误 / 调用**：调用方须先 reserve，且保证预留容量仍有效；这里提交身份记录，不发布 JS 对象也不接管原始分配的释放。

### `ExtentIdentityAuthority.record` (`src/core/gc_carrier.zig:120`)

- **签名**：`pub fn record(self: *const ExtentIdentityAuthority, base: usize) ?*const ExtentIdentityRecord`。
- **作用**：按精确 payload 基址借用只读身份记录。
- **实现**：records.getPtr(base)，不存在则 null。
- **所有权 / 错误 / 调用**：不是记录事件的写操作；返回指针指向哈希表条目，扩容、删除或 deinit 后可能失效。

### `ExtentIdentityAuthority.handle` (`src/core/gc_carrier.zig:124`)

- **签名**：`pub fn handle(self: *const ExtentIdentityAuthority, base: usize) ?AllocationHandle`。
- **作用**：将现有地址记录打包成带 generation 的 handle。
- **实现**：先 record(base)，未命中 null，命中返回 base 与该记录的 generation。
- **所有权 / 错误 / 调用**：handle 是值快照，不 pin 分配；地址复用后旧 generation 会使 resolve 失败。

### `ExtentIdentityAuthority.resolve` (`src/core/gc_carrier.zig:129`)

- **签名**：`pub fn resolve( self: *const ExtentIdentityAuthority, allocation_handle: AllocationHandle, expected_kind: ?u8, ) ResolveError!*const ExtentIdentityRecord`。
- **作用**：核验 handle 的地址、generation 和可选 kind。
- **实现**：按 base 查表；依次检查存储 base、generation 和 expected_kind，分别返回 NotFound、NotExactStart、GenerationMismatch、KindMismatch。
- **所有权 / 错误 / 调用**：返回借用条目，不读取原始 header、不校验生命周期状态；状态验证由独立 authority 承担。

### `ExtentIdentityAuthority.finishRawFree` (`src/core/gc_carrier.zig:141`)

- **签名**：`pub fn finishRawFree(self: *ExtentIdentityAuthority, base: usize) ResolveError!void`。
- **作用**：在原始释放阶段结束时移除 extent 身份。
- **实现**：fetchRemove(base)，不存在则 NotFound。
- **所有权 / 错误 / 调用**：只删索引，不执行 rawFree。移除后基于该条目的借用失效；重复调用失败。

### `ExtentIdentityAuthority.verify` (`src/core/gc_carrier.zig:145`)

- **签名**：`pub fn verify(self: *const ExtentIdentityAuthority) ResolveError!void`。
- **作用**：检查身份表内部的键、地址与 generation 基本约束。
- **实现**：要求 next_generation 非零；逐条检查 key==base、base/raw_base/raw_bytes 非零，且 generation 在 [1,next_generation) 内。
- **所有权 / 错误 / 调用**：不修改表、不分配；没有检查 payload_bytes 与 raw_bytes 的大小关系、kind 有效性或不同记录间的 generation 唯一性。

### `ExtentLifecycleAuthority.deinit` (`src/core/gc_carrier.zig:173`)

- **签名**：`pub fn deinit(self: *ExtentLifecycleAuthority, allocator: std.mem.Allocator) void`。
- **作用**：释放生命周期侧表并恢复空表。
- **实现**：records.deinit(allocator)，随后 self.*=.{}。
- **所有权 / 错误 / 调用**：使用对应 allocator；不释放记录指向的分配。

### `ExtentLifecycleAuthority.prepare` (`src/core/gc_carrier.zig:178`)

- **签名**：`pub fn prepare(self: *ExtentLifecycleAuthority, allocator: std.mem.Allocator) std.mem.Allocator.Error!void`。
- **作用**：为下一次 commit 预留一条生命周期记录。
- **实现**：records.ensureUnusedCapacity(allocator,1)。
- **所有权 / 错误 / 调用**：可能 OOM；必须在要求无失败的 commit 之前完成。

### `ExtentLifecycleAuthority.commit` (`src/core/gc_carrier.zig:182`)

- **签名**：`pub fn commit(self: *ExtentLifecycleAuthority, base: usize) void`。
- **作用**：登记一个仍在构造中的新 extent。
- **实现**：断言 base 非零且不存在；putAssumeCapacity(base,.{})，默认 state=constructing、accounted_bytes=0。
- **所有权 / 错误 / 调用**：使用 prepare 的预留容量，不分配；不证明分配已可作为 JS 对象发布。

### `ExtentLifecycleAuthority.record` (`src/core/gc_carrier.zig:188`)

- **签名**：`pub fn record(self: *const ExtentLifecycleAuthority, base: usize) ?*const ExtentLifecycleRecord`。
- **作用**：借用指定 base 的只读生命周期记录。
- **实现**：records.getPtr(base)，不存在则 null。
- **所有权 / 错误 / 调用**：不修改状态、不登记事件；返回的表内指针不能跨扩容/删除/deinit 保存。

### `ExtentLifecycleAuthority.recordMut` (`src/core/gc_carrier.zig:192`)

- **签名**：`fn recordMut(self: *ExtentLifecycleAuthority, base: usize) ?*ExtentLifecycleRecord`。
- **作用**：借用指定 base 的可变生命周期记录。
- **实现**：records.getPtr(base)，不存在则 null。
- **所有权 / 错误 / 调用**：不插入、不分配；调用方遵守表内指针有效期。

### `ExtentLifecycleAuthority.transition` (`src/core/gc_carrier.zig:196`)

- **签名**：`pub fn transition(self: *ExtentLifecycleAuthority, base: usize, state: LifecycleState) ResolveError!void`。
- **作用**：把现有记录切换到指定状态。
- **实现**：recordMut 未命中报 NotFound；否则直接写 entry.state。
- **所有权 / 错误 / 调用**：本函数没有前置状态/合法转移图检查；转移是否合法由调用方合同保证。

### `ExtentLifecycleAuthority.publish` (`src/core/gc_carrier.zig:201`)

- **签名**：`pub fn publish(self: *ExtentLifecycleAuthority, base: usize, accounted_bytes: usize) ResolveError!void`。
- **作用**：登记 extent 已发布及其计账字节数。
- **实现**：找到记录后写 state=published 和 accounted_bytes；不存在报 NotFound。
- **所有权 / 错误 / 调用**：不分配，不核验旧状态、字节数是否非零或与 identity 表一致；这些不是本函数提供的保证。

### `ExtentLifecycleAuthority.resolve` (`src/core/gc_carrier.zig:207`)

- **签名**：`pub fn resolve(self: *const ExtentLifecycleAuthority, base: usize, allowed_states: StateMask) ResolveError!*const ExtentLifecycleRecord`。
- **作用**：验证基址存在且处于允许状态。
- **实现**：查不到报 NotFound；allowed_states 不包含 entry.state 则 StateMismatch；否则返回条目。
- **所有权 / 错误 / 调用**：借用记录，不读取 payload/header；与 identity.resolve 配合才同时验证 generation 和 kind。

### `ExtentLifecycleAuthority.finishRawFree` (`src/core/gc_carrier.zig:213`)

- **签名**：`pub fn finishRawFree(self: *ExtentLifecycleAuthority, base: usize) ResolveError!void`。
- **作用**：移除生命周期记录并检查释放状态。
- **实现**：先 fetchRemove；缺失报 NotFound，已取出的记录不为 raw_free_in_progress 则报 StateMismatch。
- **所有权 / 错误 / 调用**：注意检查发生在删除之后：即使 StateMismatch，条目也已移除，不是事务性失败。正常调用方事先完成状态转移。

### `ExtentLifecycleAuthority.verify` (`src/core/gc_carrier.zig:218`)

- **签名**：`pub fn verify(self: *const ExtentLifecycleAuthority) ResolveError!void`。
- **作用**：检查表中没有空地址或已 free 的残留记录。
- **实现**：遍历 records；key==0 或 state==free 时返回 StateMismatch。
- **所有权 / 错误 / 调用**：只读，无分配；不检查 accounted_bytes，也不与身份表交叉核对。

### `HeapAccountingOracle.deinit` (`src/core/gc_carrier.zig:258`)

- **签名**：`pub fn deinit(self: *HeapAccountingOracle, allocator: std.mem.Allocator) void`。
- **作用**：释放 raw 分配账本并清零审计统计。
- **实现**：raw.deinit(allocator) 后 self.*=.{}，next_audit_id 恢复为 1。
- **所有权 / 错误 / 调用**：只销毁审计侧表，原始分配必须由分配器的正常释放流程管理。

### `HeapAccountingOracle.prepareRawAlloc` (`src/core/gc_carrier.zig:263`)

- **签名**：`pub fn prepareRawAlloc(self: *HeapAccountingOracle, allocator: std.mem.Allocator) std.mem.Allocator.Error!void`。
- **作用**：为 raw 分配审计条目预留容量。
- **实现**：raw.ensureUnusedCapacity(allocator,1)。
- **所有权 / 错误 / 调用**：可因 OOM 失败；应在实际 raw allocation 前调用，以便后续登记不再分配。

### `HeapAccountingOracle.recordRawAlloc` (`src/core/gc_carrier.zig:267`)

- **签名**：`pub fn recordRawAlloc(self: *HeapAccountingOracle, entry: RawAuditEntry) void`。
- **作用**：登记原始分配，给它独立的审计 id。
- **实现**：断言基址/原始基址/字节数非零且无重复；复制 entry，覆盖 audit_id；next_audit_id 用 +%= 回绕且跳过零，再 putAssumeCapacity。
- **所有权 / 错误 / 调用**：使用预留容量；audit_id 不等于 carrier generation，且这里允许回绕，不可用作永久唯一身份。其余字段保留调用方输入。

### `HeapAccountingOracle.recordRawFree` (`src/core/gc_carrier.zig:277`)

- **签名**：`pub fn recordRawFree(self: *HeapAccountingOracle, base: usize) void`。
- **作用**：从审计账本移除已退役的原始分配。
- **实现**：fetchRemove 找不到则 panic；删除后断言 removed.published 为 false。
- **所有权 / 错误 / 调用**：只改账本，不释放分配；需先 recordUnpublish。未发布断言只在 safety 配置生效。

### `HeapAccountingOracle.recordPublish` (`src/core/gc_carrier.zig:282`)

- **签名**：`pub fn recordPublish(self: *HeapAccountingOracle, base: usize, bytes: usize, is_large: bool) void`。
- **作用**：把原始分配纳入已发布堆字节统计。
- **实现**：断言 bytes 非零；找不到 raw 条目则 panic，已 published 则断言失败；置 published，记录 accounted_bytes，并加 heap_live_bytes 和 large 或 old 分项。
- **所有权 / 错误 / 调用**：此处 old_live_bytes 是 is_large=false 分支的计账栏，不根据 GC young 标志分类；普通加法并非饱和加法。

### `HeapAccountingOracle.recordUnpublish` (`src/core/gc_carrier.zig:292`)

- **签名**：`pub fn recordUnpublish(self: *HeapAccountingOracle, base: usize, bytes: usize, is_large: bool) void`。
- **作用**：从已发布堆统计中扣除退役分配。
- **实现**：断言 bytes 非零并找到已 published 条目；清 published，检查各栏足够扣减，随后减少总量及 large/old 分项。
- **所有权 / 错误 / 调用**：保留 raw 条目等待 recordRawFree；调用方须传入与发布配对的 bytes/is_large，本函数不把 bytes 与 entry.accounted_bytes 再比较。

## `gc_block_heap.zig`

生产使用的block/extent heap。small cell用于Object、string/rope及owned storage等载体；medium/large extent由独立主表管理，不能沿用源码历史注释中的“尚未服务runtime”或“extent只有string”。分配存储、对象发布、标记和析构是分开的操作，函数说明分别列出调用前提。

几何常量：superblock_bytes=2MiB，block_bytes=64KiB，blocks_per_superblock=32；page_shift=12，page_bytes=4KiB，pages_per_superblock=512。block_align为64KiB；max_medium_pages=16，medium_bucket_count=17，bucket_nil=maxInt(u32)。decommit_bytes为64KiB减去将4KiB向OS最小页大小对齐后的保留前缀，前缀不小于block时为0；不能在所有目标上都硬写成60KiB。max_bitmap_words按最小class计算上界。block_magic=0x5a4a53_424c4b_0001。

free_nil=0xFFFF，free_link_mask/free_poison复用gc_representation_constants。空闲cell首u32低16位存后继索引，高半poison避免被识别为已发布block-cell前缀；不是整cell清零。hot_reuse_min_free_percent=10，hot_reuse_k64与hot_reuse_min_interval_cells均为64，分别限制总空闲比例和实际选用时最长连续区间。

SuperblockKind为classed、medium、tombstone。Superblock.bytes保存64KiB对齐的整段映射；used_blocks表示已取用classed槽前缀。page_bits有8个u64：medium表示512页占用，classed只用低32位表示非空block。max_free_run是medium最长空闲段截断值，并兼作桶编号；bucket_prev/next为槽索引双向链接，nil表示无链接。empty_since_ns记medium全空时刻；free_slot_next仅用于tombstone空槽链。tombstone保留槽索引，原映射已归还。

block_generation_enabled、lifecycle_state_enabled分别沿用carrier配置，block_tracking_enabled决定cell pop是否需要追踪；配置关闭时相应侧表字段为void。Superblock.block_incarnations保存32个block代次，cell_generations保存每block的cell序列数组，cell_lifecycles保存状态/记账条目数组；CellLifecycle初始state=free、accounted_bytes=0。generation与lifecycle不是必须捆绑分配的一张表。

LargeMap保存映射bytes和请求user_bytes；MediumExtent保存super_index、起始page、pages及user_bytes。两者mark_epoch默认extent_unmarked_epoch=1，needs_finalizer默认false。heap正常epoch为偶数，故首次major前epoch=0仍能正确识别未标记extent。析构责任位决定回调内如何释放，sweep仍对每个死亡extent调用destroy并传入该bool。ExtentPage保存base与base+user_bytes的尾后end，页索引按映射覆盖页建立，查询边界按请求范围；ExtentPair允许同时保存命中extent与相邻前驱尾后基址，字段具体归类见查询函数。

Block为112字节extern struct，编译期断言super_index偏移76、next_free偏移80、interval_end偏移92。magic/mark_epoch标识块和标记周期；cell_size/count、allocated_count、size_class定义容量与当前分配；cells_offset和alloc/mark/remember偏移及bitmap_words定义存储几何，finalizer位图紧随remember列而不另存偏移。BlockGeometry另外返回cell_count、bitmap_words及四列和cell区偏移。

Block.bump/free_list在普通模式表示未发出区域和回收cell链，在interval模式与interval_end一起表示连续空闲段。next_free按状态复用为free/hot block地址链，或interval模式异常返还cell的索引链。young_link和doomed_link均用0表示未入链、1表示尾；doomed_cursor单位是word，doomed_word缓存尚未逐项取出的死亡位。free_time_ns为进入空block池的粗时钟。SweepState虽有fresh/active/needs_sweep/sweeping/swept五值，当前稳定审计边界只接受active或swept；判死依靠位图与链，不依靠旧五阶段模型。

Block.flags各位：bit0 young链成员，bit1 hot连续区间拒绝缓存，bit4 bitmap_canonical表示空洞仅由alloc位图完整描述，bit5 decommitted，bit6 interval_allocator，bit7 hot_list。它们不是对象header中的同名/同位标志；bitmap_canonical和hot未准备态都可能尚无可直接使用的cell空闲链。

Heap.backing管理映射和各侧表；superblocks保持稳定槽索引，free_superblock_slots连接可复用墓碑。classed_blocks是精确block集合，classed_block_filter为地址OR粗过滤。medium/large为extent主表，extent_pages为加速索引，extent_pages_unindexed非零时启用线性查询；extent_page_removes服务rehash阈值，extent_bounds_lo/hi只扩宽不随释放缩小，初值maxInt/0。medium_buckets以截断run分类。young_extents在分配而非发布时append，允许过期或地址复用条目；free_blocks/hot_blocks/active按class保存池与当前目标，young_blocks/doomed_blocks保存独立链头。mark_epoch初始0，clock_ns/last_decommit_ns/hot_publish_cursor初始0；generation开启时next_block_incarnation初始1、exhausted初始false。ResolvedCell返回block/index及state/generation快照，不拥有或pin对象。

Stats默认全零。committed_bytes是映射/页面回收记账，非OS RSS；superblocks与large_maps是当前计数。live_bytes/live_count当前只由medium/large分配释放维护，small另由liveSmall读取block计数。medium_allocs/large_allocs累计成功分配，large_reserves包含失败尝试。decommitted/recommitted_bytes记录classed页，decommit_checks及max_batch记录扫描/批次；medium_superblocks_released和medium_superblock_bytes_released单独统计整段归还。malloc_trim_attempts/successes记录调用结果，不测释放字节。

hot_blocks_published/reopened、hot_blocks_k_rejected记录复用流程；hot_publish_rejected_*按empty/capacity/active/doomed/young/listed/decommitted/cached_k分支计数，分支顺序影响归因。bitmap_reclaimed_cells只记录批量bitmap释放分支。统计混用普通与饱和加法，不能统称不会溢出。

DoomedCounts保存dead及其中finalizing数量。BlockCensusRow保存class尺寸、block/cell/allocated总数、empty/lt10/lt50/ge50占用桶、young/decommitted及active/hot/free成员数量；BlockCensus另保存classed/other superblock及未初始化槽计数。ClassCensus保存初始化/非空/空free/空active数与live_cells/cell_capacity；Census汇总classed/medium、预留未初始化槽、非空/partial/空池/decommitted/全空superblock、hot与interval active计数以及分配cell和空/非空容量字节。字段人口与重叠关系以对应普查函数为准，不可将各维度全部相加当总量。

### `injectedCellFailure` (`src/core/gc_block_heap.zig:82`)

- **签名**：`inline fn injectedCellFailure() bool`。
- **作用**：询问测试专用的 cell 分配失败注入点是否要让本次分配失败。
- **实现**：非 test 构建 comptime 直接 false；test 构建先递增 cell_injection_questions_for_test，再取 cell_failure_injector，未安装返回 false，否则返回 injector.shouldFail(injector.context)。
- **所有权 / 错误 / 调用**：不分配、不改 heap 状态，也不触碰 backing allocator；只被 allocSmallCell 的两条慢臂（active 缺失、active 弹空）调用，用于把 cell 耗尽折进 src/tests/oom.zig 的统一 fail_index 空间。

### `Stats.currentDecommittedBytes` (`src/core/gc_block_heap.zig:238`)

- **签名**：`pub fn currentDecommittedBytes(self: Stats) usize`。
- **作用**：计算尚未重新提交的累计decommit字节差。
- **实现**：返回decommitted_bytes -| recommitted_bytes，结果最低为0。
- **所有权 / 错误 / 调用**：仅计算账面差，不查询OS驻留页或RSS；不包含单独统计的medium superblock释放。

### `canAllocCellSize` (`src/core/gc_block_heap.zig:289`)

- **签名**：`pub fn canAllocCellSize(n: usize) bool`。
- **作用**：判断请求字节数能否使用small classed cell。
- **实现**：n为0或至少large_min_bytes时false，否则以classIndexForPayload(n)是否非null决定。
- **所有权 / 错误 / 调用**：纯尺寸分类，不证明当前heap有空闲cell或分配一定成功；n是请求物理cell字节，不自动增加metadata prefix。

### `cellClassForPayload` (`src/core/gc_block_heap.zig:297`)

- **签名**：`pub inline fn cellClassForPayload(comptime n: usize) struct { idx: usize, size: u32 }`。
- **作用**：在编译期为合法cell请求确定class索引与尺寸。
- **实现**：编译期断言canAllocCellSize(n)，取得classIndexForPayload，返回idx及转成u32的classes[idx]。
- **所有权 / 错误 / 调用**：n必须编译期已知且合法，不分配存储；size是class尺寸而非原始请求n。

### `accountedBodyBytesForRequest` (`src/core/gc_block_heap.zig:307`)

- **签名**：`pub inline fn accountedBodyBytesForRequest(n: usize, metadata_prefix_bytes: usize) ?usize`。
- **作用**：由物理请求尺寸推导扣除metadata prefix后的记账尺寸。
- **实现**：零或达到large阈值返回null；无class同样null；选定class后断言其尺寸至少为metadata_prefix_bytes，再返回两者之差。
- **所有权 / 错误 / 调用**：不验证某个实际指针，不执行记账增减。prefix过大是前置条件违例，不通过null表示；结果按class容量计算，未必等于请求净载荷。

### `Block.fromAddr` (`src/core/gc_block_heap.zig:521`)

- **签名**：`fn fromAddr(addr: usize) ?*Block`。
- **作用**：将已具备可读映射前提的地址向下取整到block基址并检查magic。
- **实现**：addr小于block_bytes返回null；清低16位得到Block指针，读取magic，匹配block_magic才返回。
- **所有权 / 错误 / 调用**：不是任意整数地址的安全成员查询：magic读取前没有查映射或registry，未映射地址仍可能故障。匹配也不证明地址位于已分配cell内。

### `Block.bitmaps` (`src/core/gc_block_heap.zig:529`)

- **签名**：`fn bitmaps(self: *Block) struct { alloc: []u64, mark: []u64, remember: []u64 }`。
- **作用**：借用block中的alloc、mark、remember三组位图切片。
- **实现**：从Block基址分别加alloc_bits_off、mark_bits_off、remember_bits_off，转换为对齐u64指针，长度均bitmap_words。
- **所有权 / 错误 / 调用**：不分配、复制或清零，切片可变且依赖有效block布局；这里不返回独立的finalizer列。

### `Block.finalizerBits` (`src/core/gc_block_heap.zig:543`)

- **签名**：`pub fn finalizerBits(self: *Block) []u64`。
- **作用**：取得needs-finalizer位图切片。
- **实现**：起点为remember_bits_off + bitmap_words*8，长度bitmap_words，基于当前Block映射。
- **所有权 / 错误 / 调用**：第四张位图的位置由布局推导，返回可变借用；置位表明sweep需走析构路径，不在此执行析构。

### `Block.setFinalizerBit` (`src/core/gc_block_heap.zig:550`)

- **签名**：`pub fn setFinalizerBit(self: *Block, index: u32) void`。
- **作用**：登记指定cell需要析构。
- **实现**：对finalizerBits调用setBitPlain(index)。
- **所有权 / 错误 / 调用**：普通位更新，调用方须保证合法index与适当串行访问；不改变alloc/mark，也不验证cell已发布。

### `Block.clearFinalizerBit` (`src/core/gc_block_heap.zig:554`)

- **签名**：`fn clearFinalizerBit(self: *Block, index: u32) void`。
- **作用**：清除指定cell的析构位。
- **实现**：对finalizerBits调用clearBitPlain(index)。
- **所有权 / 错误 / 调用**：不运行finalizer、不释放cell；index及同步由调用方保证。

### `Block.cellNeedsFinalizer` (`src/core/gc_block_heap.zig:558`)

- **签名**：`pub fn cellNeedsFinalizer(self: *Block, index: u32) bool`。
- **作用**：查询指定cell的析构位。
- **实现**：返回testBitPlain(finalizerBits(),index)。
- **所有权 / 错误 / 调用**：不同时检查alloc或doomed；未分配cell不能只凭这个结果判断有效性。

### `Block.cellPtr` (`src/core/gc_block_heap.zig:562`)

- **签名**：`fn cellPtr(self: *Block, index: u32) [*]u8`。
- **作用**：计算cell起点的多项字节指针。
- **实现**：Block基址加cells_offset再加index*cell_size。
- **所有权 / 错误 / 调用**：不做cell_count边界或分配位检查；返回的是物理cell起点，包含metadata prefix，不直接等于对象body。

### `Block.cellIndex` (`src/core/gc_block_heap.zig:567`)

- **签名**：`pub fn cellIndex(self: *const Block, ptr: usize) ?u32`。
- **作用**：将精确cell起点转换为索引。
- **实现**：低于cells区起点返回null；偏移不能被cell_size整除返回null；商转成u32后，与cell_count比较，越界null。
- **所有权 / 错误 / 调用**：不接受cell内部地址，不检查alloc位。输入须属于受约束地址范围：对任意巨大usize，商的u32转换发生在上界比较之前，不能保证总能安全返回null。

### `Block.cellIndexInterior` (`src/core/gc_block_heap.zig:581`)

- **签名**：`pub fn cellIndexInterior(self: *const Block, ptr: usize) ?u32`。
- **作用**：计算包含给定内部地址的cell索引。
- **实现**：低于cells区返回null；(ptr-base)/cell_size转成u32，再检查小于cell_count；没有精确cell起点的整除要求。
- **所有权 / 错误 / 调用**：包含cell的prefix和body，但不证明cell已分配、发布或对象存活。与cellIndex一样，巨大任意地址可能在范围检查前触发整数转换问题，调用方应先限定block范围。

### `Block.allocWords` (`src/core/gc_block_heap.zig:590`)

- **签名**：`pub fn allocWords(self: *Block) []u64`。
- **作用**：取得分配位图的可变借用。
- **实现**：返回bitmaps().alloc。
- **所有权 / 错误 / 调用**：用于按word枚举分配cell；不附带heap_accounted或condemnation过滤，不提供快照。

### `Block.doomedWords` (`src/core/gc_block_heap.zig:599`)

- **签名**：`pub fn doomedWords(self: *Block) []u64`。
- **作用**：取得当前用作condemnation位图的列。
- **实现**：返回bitmaps().remember。
- **所有权 / 错误 / 调用**：该存储列复用：只在snapshotDoomed到reclaim清理之间具有doomed含义；其它阶段不可把remember列当作死亡判定。返回可变借用。

### `Block.deadWord` (`src/core/gc_block_heap.zig:606`)

- **签名**：`pub fn deadWord(self: *Block, word_index: usize, epoch: u64) u64`。
- **作用**：读取指定word在给定epoch下的死亡候选位。
- **实现**：先读alloc；acquire读取mark_epoch，不等于epoch则返回整个alloc；相等时monotonic读取mark word，返回alloc & ~mark。
- **所有权 / 错误 / 调用**：输出为候选，不检查pin、heap_accounted或header kind，不写doomed快照。word_index须合法；原子读取不使整个alloc/epoch/mark组合成为任意并发下的一致快照。

### `Block.cellAllocated` (`src/core/gc_block_heap.zig:613`)

- **签名**：`pub fn cellAllocated(self: *Block, index: u32) bool`。
- **作用**：查询cell的alloc位。
- **实现**：返回testBitPlain(bitmaps().alloc,index)。
- **所有权 / 错误 / 调用**：只说明位图中的分配状态，不说明发布、标记、析构或所属对象kind。index由调用方保证合法。

### `Block.cellBase` (`src/core/gc_block_heap.zig:617`)

- **签名**：`pub fn cellBase(self: *const Block, index: u32) usize`。
- **作用**：计算指定cell物理起点的整数地址。
- **实现**：Block地址加cells_offset与index*cell_size。
- **所有权 / 错误 / 调用**：纯算术，不检查边界或分配状态，不增加metadata prefix。

### `Block.fromCellTrusted` (`src/core/gc_block_heap.zig:624`)

- **签名**：`pub inline fn fromCellTrusted(cell_addr: usize) *Block`。
- **作用**：由已证明属于block cell的地址直接取得block。
- **实现**：清除地址低16位并转为Block指针。
- **所有权 / 错误 / 调用**：无magic、映射、分配或成员检查；调用方必须先建立block-cell路由证明，不能用于未经解析的保守栈字。

### `Block.clearMark` (`src/core/gc_block_heap.zig:630`)

- **签名**：`pub fn clearMark(self: *Block, index: u32, epoch: u64) void`。
- **作用**：仅在block属于给定epoch时清除指定mark位。
- **实现**：acquire读取mark_epoch；不等则直接返回，相等时clearBit(mark,index)。
- **所有权 / 错误 / 调用**：过期位图在逻辑上已未标记，所以不刷新epoch或清整张表。不改young/alloc；有效index与收集阶段约束由调用方保证。

### `Block.clearYoungMarksStw` (`src/core/gc_block_heap.zig:645`)

- **签名**：`pub fn clearYoungMarksStw(self: *Block, epoch: u64) void`。
- **作用**：在minor的STW窗口只清除已发布young cell的mark。
- **实现**：block epoch不匹配立即返回；每word扫描alloc & mark候选，读取cell prefix的heap_accounted和young位，并要求!isDoomed；聚合young_marks后用一次普通word写清除。遇到超出cell_count的index退出整个word循环。
- **所有权 / 错误 / 调用**：保留old、未发布及doomed cell标记，不推进epoch。要求owner线程独占STW；普通读写不能当作并行marker可用的操作。检查doomed仅使用位图列，不含doomed_word缓存，依赖调用阶段约束。

### `Block.isYoungListed` (`src/core/gc_block_heap.zig:670`)

- **签名**：`inline fn isYoungListed(self: *const Block) bool`。
- **作用**：查询block是否带有young链成员标志。
- **实现**：返回flags & flag_young是否非零。
- **所有权 / 错误 / 调用**：不遍历young_link或检查所有cell，不证明每个cell都是young。

### `Block.hasPendingDoomed` (`src/core/gc_block_heap.zig:674`)

- **签名**：`fn hasPendingDoomed(self: *Block) bool`。
- **作用**：查询block是否还保留待消费的死亡位。
- **实现**：doomed_word非零立即true；否则扫描remember列，任一非零true，全部为零false。
- **所有权 / 错误 / 调用**：同时覆盖普通drain缓存和位图；不检查doomed_link、finalizer执行状态或被弹出后尚未销毁的cell。仅在doomed语义窗口使用。

### `Block.cellPendingDoomed` (`src/core/gc_block_heap.zig:682`)

- **签名**：`fn cellPendingDoomed(self: *Block, index: u32) bool`。
- **作用**：查询指定cell是否仍在死亡位图或drain缓存中。
- **实现**：先isDoomed；否则要求doomed_word含对应bit且doomed_cursor等于index/64。
- **所有权 / 错误 / 调用**：比isDoomed多查缓存，仍不追踪已弹出项的后续析构；不检查alloc或header stamp。

### `Block.snapshotDoomed` (`src/core/gc_block_heap.zig:697`)

- **签名**：`pub fn snapshotDoomed(self: *Block, epoch: u64) DoomedCounts`。
- **作用**：把本epoch未标记的已分配cell快照为死亡位图，并统计需析构子集。
- **实现**：重置doomed_cursor/doomed_word；epoch不匹配视mark word为0，否则原子读mark。每word计算alloc & ~mark，非零或旧remember非零时覆写remember；popCount累计dead及doomed & finalizer累计finalizing。
- **所有权 / 错误 / 调用**：只写快照，不释放、析构、扣字节账或检查pin/heap_accounted。重建会覆盖前次快照与缓存，调用方须保证旧批次已经处理；dead-finalizing是可按bitmap回收的数量，依赖finalizer位正确。

### `Block.forgetDoomedCell` (`src/core/gc_block_heap.zig:737`)

- **签名**：`fn forgetDoomedCell(self: *Block, index: u32) void`。
- **作用**：在cell经其它释放路径离开时移除它的待消费死亡位。
- **实现**：doomed_link为0直接返回；否则清remember中index对应位，若cursor指向同word也清doomed_word缓存位。
- **所有权 / 错误 / 调用**：不改alloc/mark/finalizer或计数，不自行释放。调用时必须已链接doomed链；它不是用于任意阶段修改第三张位图的接口。

### `Block.takeDoomedFinalizerCell` (`src/core/gc_block_heap.zig:759`)

- **签名**：`pub fn takeDoomedFinalizerCell(self: *Block) ?u32`。
- **作用**：从死亡位图中取出一个需要析构的cell索引。
- **实现**：从doomed_cursor按word扫描remember & finalizer，找到最低置位后清remember中该bit并保留cursor；耗尽重置cursor为0并返回null。
- **所有权 / 错误 / 调用**：不调用析构、不清alloc或finalizer、不减allocated_count；不使用或排空doomed_word缓存。要求与普通takeDoomedCell的消费协议分开，调用方对取出的项执行完整销毁。null仍可能剩余不需析构的死亡cell。

### `Block.reclaimDoomedIntoBitmap` (`src/core/gc_block_heap.zig:788`)

- **签名**：`fn reclaimDoomedIntoBitmap(self: *Block) u32`。
- **作用**：按word批量释放死亡位图中剩余cell的分配位。
- **实现**：每个非零remember word先清零，再从alloc/mark/finalizer中清相同位并累计popCount；重置cursor与缓存。freed非零则allocated_count减freed并置flag_bitmap_canonical，返回freed。
- **所有权 / 错误 / 调用**：不读header、不运行析构、不写free link、不改Heap统计或发布block；须先处理所有需析构项。不包含已转入doomed_word缓存的位，不能与普通drain任意交错；Heap.reclaimDoomedCells负责allocator-current和全空block等外围状态。

### `Block.takeDoomedCell` (`src/core/gc_block_heap.zig:809`)

- **签名**：`pub fn takeDoomedCell(self: *Block, start: u32) ?u32`。
- **作用**：按word缓存逐个取出死亡cell索引。
- **实现**：start大于cursor时丢弃当前缓存并将cursor设为start；缓存非空先取最低bit。否则从cursor向后查remember，取到非零word即清空该位图word，将剩余bit保存在doomed_word并返回最低bit索引；耗尽重置cursor/cache并返回null。
- **所有权 / 错误 / 调用**：start单位是word索引而非cell索引；前移start可能放弃缓存中的待处理项，调用方须遵守消费协议。不析构、不清alloc；整word搬入缓存后isDoomed不能单独反映所有待消费cell。

### `Block.ensureMarkEpoch` (`src/core/gc_block_heap.zig:856`)

- **签名**：`pub fn ensureMarkEpoch(self: *Block, epoch: u64) void`。
- **作用**：惰性清空过期mark位图并发布目标epoch。
- **实现**：acquire读已匹配则返回；否则循环，目标epoch|1作为转换锁，看到该值自旋；弱CAS取得锁后普通memset清mark，release写目标epoch。
- **所有权 / 错误 / 调用**：调用方提供正常偶数epoch并保证阶段一致；此协议为同一目标epoch的首次标记同步，不允许任意竞争epoch混用。不改alloc/young或其它位图；不是整个collector已经支持并行执行的证明。

### `Block.isDoomed` (`src/core/gc_block_heap.zig:875`)

- **签名**：`pub inline fn isDoomed(self: *Block, index: u32) bool`。
- **作用**：查询第三张位图中的指定死亡bit。
- **实现**：按index/64和index%64直接读remember列。
- **所有权 / 错误 / 调用**：不检查doomed_link或doomed_word缓存，不等价于所有待析构状态；仅在相应快照窗口且index有效时解释为死亡标记。

### `Block.isMarked` (`src/core/gc_block_heap.zig:879`)

- **签名**：`pub fn isMarked(self: *Block, index: u32, epoch: u64) bool`。
- **作用**：按epoch查询一个cell的mark。
- **实现**：acquire读mark_epoch不匹配返回false，否则testBit(mark,index)。
- **所有权 / 错误 / 调用**：不初始化过期位图、不检查alloc或发布状态；转换中的奇数epoch也被当作不匹配。

### `Block.setMark` (`src/core/gc_block_heap.zig:884`)

- **签名**：`pub fn setMark(self: *Block, index: u32, epoch: u64) void`。
- **作用**：确保block属于目标epoch后设置cell mark。
- **实现**：先ensureMarkEpoch，再setBit(mark,index)。
- **所有权 / 错误 / 调用**：不返回是否首次标记，不更新young或retirement计数，也不验证alloc/pin/header；索引和epoch协议由调用方保证。

### `blockGeometry` (`src/core/gc_block_heap.zig:907`)

- **签名**：`fn blockGeometry(cell_size: u32) BlockGeometry`。
- **作用**：计算固定cell尺寸下112字节block header、四张位图及cell区的布局。
- **实现**：header向16字节对齐，先忽略位图估计cell_count；bitmap_words为ceil(count/64)，依次排alloc/mark/remember/finalizer四列，cell区向64字节对齐。若总长度超64KiB则逐个减少cell_count并重算，直到容纳，返回计数及全部偏移。
- **所有权 / 错误 / 调用**：纯计算，不分配或写block；调用方提供合法非零class尺寸，不能将任意u32当成已校验请求。Block大小由comptime断言固定112字节，finalizer偏移通过布局推导，不另占Block字段。

### `Heap.init` (`src/core/gc_block_heap.zig:1043`)

- **签名**：`pub fn init(backing: std.mem.Allocator) Heap`。
- **作用**：建立使用指定backing allocator的空heap。
- **实现**：返回只显式设置backing、其它字段使用默认值的Heap。
- **所有权 / 错误 / 调用**：不映射superblock、不预留表容量；backing由调用方保证生命周期。

### `Heap.deinit` (`src/core/gc_block_heap.zig:1047`)

- **签名**：`pub fn deinit(self: *Heap) void`。
- **作用**：释放heap持有的映射、索引表、样本式地址列表和可选追踪侧表。
- **实现**：先逐large条目free其bytes，再deinit large/medium/extent_pages/young_extents/classed_blocks；遍历非tombstone superblock，按编译配置释放cell_generations与cell_lifecycles，再free整段bytes；最后deinit superblocks并重置为同backing的空Heap。
- **所有权 / 错误 / 调用**：不逐对象运行析构，也不执行弱identity/atom等运行时协议；调用方须先完成这些清理并停止外部访问。medium存储随superblock释放，tombstone已经归还而跳过；所有旧指针/迭代器失效。空状态再次deinit不重复释放原映射。

### `Heap.beginMajor` (`src/core/gc_block_heap.zig:1073`)

- **签名**：`pub fn beginMajor(self: *Heap) void`。
- **作用**：撤回可复用hot block并推进major mark epoch。
- **实现**：先withdrawHotBlocks，再mark_epoch += 2，奇数值留给Block.ensureMarkEpoch的转换锁。
- **所有权 / 错误 / 调用**：不立即清所有block位图，惰性清理由首次mark完成；使用普通加法，未实现epoch耗尽回绕修复。不能在尚未完成前轮析构等任意状态下自由调用。

### `Heap.alloc` (`src/core/gc_block_heap.zig:1084`)

- **签名**：`pub fn alloc(self: *Heap, n: usize) std.mem.Allocator.Error![]u8`。
- **作用**：按请求尺寸选择small、medium或large分配入口。
- **实现**：n=0返回空slice；n>=large_min_bytes走allocLarge；有small class走allocSmall(class_idx,n)，其余allocMedium(n)。
- **所有权 / 错误 / 调用**：返回heap管理的可变字节slice，失败传播allocator错误。该入口不保证所有返回值都带block-cell路由，不在此运行对象构造或GC发布；分配容量与请求slice长度的区别由各分支定义。

### `Heap.allocCell` (`src/core/gc_block_heap.zig:1101`)

- **签名**：`pub fn allocCell(self: *Heap, n: usize) std.mem.Allocator.Error!?[*]u8`。
- **作用**：请求small class的物理cell指针。
- **实现**：n为0或达到large阈值返回null；查不到class也null；否则取得class尺寸并try allocSmallCell。
- **所有权 / 错误 / 调用**：null表示尺寸不受cell路径支持，OutOfMemory通过error返回，二者不同。返回包括metadata prefix的物理cell起点，不是已构造/发布的对象；medium/large须由调用方另选分配入口。

### `Heap.allocCellFixedPtr` (`src/core/gc_block_heap.zig:1114`)

- **签名**：`pub noinline fn allocCellFixedPtr(self: *Heap, class_idx: usize, cell_size: u32) align(64) ?[*]u8`。
- **作用**：用调用方预先证明的class直接分配cell。
- **实现**：直接allocSmallCell(class_idx,cell_size)，捕获allocator错误并返回null。
- **所有权 / 错误 / 调用**：不重新校验class索引/尺寸配对；null表示这条已选class分配失败。签名align(64)约束函数代码对齐，不保证返回cell或对象指针64字节对齐；不应把它解读成返回值alignment。

### `Heap.allocSmallCell` (`src/core/gc_block_heap.zig:1118`)

- **签名**：`inline fn allocSmallCell(self: *Heap, class_idx: usize, cell_size: u32) std.mem.Allocator.Error![*]u8`。
- **作用**：从指定class的active block取得cell并写入索引前缀。
- **实现**：无active时openBlock并安装；popTrackedCell失败则清active、重新openBlock并再pop（要求成功）。取得index后设置alloc位，原allocated_count为0则noteNonemptyBlock，再加count；把index按little-endian u16写入cell前两字节并返回起点。
- **所有权 / 错误 / 调用**：不在这里完成GC metadata其余字段、对象构造或发布。测试注入仅位于需要开block的慢路径。真实openBlock失败可能发生在active已清空之后，不能保证所有OOM都使Heap完全不变；class_idx/cell_size须有效且一致。

### `Heap.free` (`src/core/gc_block_heap.zig:1145`)

- **签名**：`pub fn free(self: *Heap, ptr: [*]u8) void`。
- **作用**：按精确分配基址识别large、medium或small并返还存储。
- **实现**：先large.fetchRemove，命中则unindexExtentPages、减少live_bytes/live_count/committed_bytes/large_maps并backing.free；其次medium.fetchRemove，命中先取消页索引再freeMedium；否则Block.fromAddr加cellIndex，失败返回，成功freeSmall。
- **所有权 / 错误 / 调用**：要求合法本heap分配起点，不支持任意或内部指针；small回退会读取取整地址的magic，不能把无匹配返回理解为任意地址安全。此函数不执行对象级析构，medium/large原表项在后续释放前已被移除。

### `Heap.ExtentKeyIterator.next` (`src/core/gc_block_heap.zig:1172`)

- **签名**：`pub fn next(self: *ExtentKeyIterator) ?usize`。
- **作用**：依次取得medium再large表的分配基址。
- **实现**：先medium.next，返回key值；medium耗尽再large.next；两者耗尽返回null。
- **所有权 / 错误 / 调用**：迭代器借用两张表，不拥有extent；表变更可能使迭代器失效，顺序不是地址排序，也不筛选发布/marked/young。

### `Heap.extentKeys` (`src/core/gc_block_heap.zig:1179`)

- **签名**：`pub fn extentKeys(self: *const Heap) ExtentKeyIterator`。
- **作用**：创建遍历两个extent主表的key迭代器。
- **实现**：分别取得medium.keyIterator与large.keyIterator并返回组合。
- **所有权 / 错误 / 调用**：不分配快照、不转移所有权；extent种类不限string，当前使用者还包括owned storage载体。

### `Heap.extentSetMark` (`src/core/gc_block_heap.zig:1195`)

- **签名**：`pub fn extentSetMark(self: *const Heap, base: usize, epoch: u64) void`。
- **作用**：将指定extent表项的mark epoch设为目标值。
- **实现**：先medium.getPtr再large.getPtr，命中写mark_epoch并返回；都未命中执行unreachable。
- **所有权 / 错误 / 调用**：base必须为仍存在的extent精确分配基址；const Heap并不阻止通过表存储指针写表项。普通写入依赖STW，不是线程安全的并发标记接口。

### `Heap.extentSetNeedsFinalizer` (`src/core/gc_block_heap.zig:1210`)

- **签名**：`pub fn extentSetNeedsFinalizer(self: *Heap, base: usize) void`。
- **作用**：登记extent死亡时需要调用析构路径。
- **实现**：在medium或large精确base项中将needs_finalizer置true，无项unreachable。
- **所有权 / 错误 / 调用**：只有置true操作，不成对清false；不会立即运行finalizer，不证明对象已发布。

### `Heap.extentNeedsFinalizer` (`src/core/gc_block_heap.zig:1218`)

- **签名**：`fn extentNeedsFinalizer(self: *const Heap, base: usize) bool`。
- **作用**：读取extent表项的析构责任位。
- **实现**：medium优先，否则large，返回needs_finalizer；无有效base则unreachable。
- **所有权 / 错误 / 调用**：只查询，不检查mark或young，也不触发析构。

### `Heap.extentIsMarked` (`src/core/gc_block_heap.zig:1224`)

- **签名**：`pub fn extentIsMarked(self: *const Heap, base: usize, epoch: u64) bool`。
- **作用**：以表项stamp判断extent是否在给定epoch标记。
- **实现**：medium或large取mark_epoch，无项unreachable，直接返回stamped==epoch。
- **所有权 / 错误 / 调用**：不特殊排除epoch=0；新建或清标记extent的奇数unmarked sentinel与正常偶数heap epoch不同。调用方提供正常epoch，不把sentinel当成有效查询周期。

### `Heap.extentContaining` (`src/core/gc_block_heap.zig:1252`)

- **签名**：`pub fn extentContaining(self: *const Heap, addr: usize) ?usize`。
- **作用**：从候选地址解析一个extent基址。
- **实现**：调用extentsContaining，优先返回inside，否则one_past_end。
- **所有权 / 错误 / 调用**：边界可能同时指向两个extent，此单值接口只选一个；需要保守保活两侧时必须消费ExtentPair。有未建页索引extent时会退回线性扫描，不能无条件声称O(1)。

### `Heap.extentsContaining` (`src/core/gc_block_heap.zig:1271`)

- **签名**：`pub fn extentsContaining(self: *const Heap, addr: usize) ExtentPair`。
- **作用**：解析候选地址可能命中的extent及相邻前驱的尾后地址。
- **实现**：存在extent_pages_unindexed则走线性回退；否则查addr所在page，并验证base<=addr<=end。若addr非零且页对齐，额外查addr-1所在page，在addr==end且base不同于inside时填写one_past_end。
- **所有权 / 错误 / 调用**：边界按请求user_bytes而非page-rounded容量。即使首次查到inside，页边界仍查询前一页，避免丢掉相邻前驱。字段不是完全互斥的严格内部/尾后分类：非页对齐尾后地址可由首次查询填入inside；应消费两字段的非空基址集合。

### `Heap.extentsContainingLinear` (`src/core/gc_block_heap.zig:1291`)

- **签名**：`fn extentsContainingLinear(self: *const Heap, addr: usize) ExtentPair`。
- **作用**：不依赖页索引，扫描extent主表解析候选。
- **实现**：依次遍历medium/large；限定base<=addr<=base+user_bytes，等于非空区间末端写one_past_end，其余写inside；返回至多两个基址。
- **所有权 / 错误 / 调用**：无解引用候选地址，不分配；成本随活extent数增长。尾后地址在此总归one_past_end，而索引路径的非页对齐尾后地址可能在inside，二者等价的是目标集合，不是字段逐项恒等。

### `Heap.indexExtentPages` (`src/core/gc_block_heap.zig:1321`)

- **签名**：`fn indexExtentPages(self: *Heap, base: usize, span_bytes: usize, user_bytes: usize) void`。
- **作用**：把extent映射的每页加入索引，插入失败时保留可靠线性回退。
- **实现**：断言base/非零span按页对齐且user_bytes<=span；先扩大extent_bounds，再把[base,base+span)各页映射到{base,end=base+user_bytes}。getOrPut失败时rollback已插页并增加extent_pages_unindexed后返回；成功断言页没有既有项。
- **所有权 / 错误 / 调用**：void不表示建索引必成功；主表须保持extent有效，未索引计数令查询走线性表。失败不回滚已扩大的bounds，也不必收缩哈希容量；end是请求尾后地址，bounds_hi则按映射末端再加1。

### `Heap.rollbackExtentPages` (`src/core/gc_block_heap.zig:1356`)

- **签名**：`fn rollbackExtentPages(self: *Heap, first: usize, end_exclusive: usize) void`。
- **作用**：撤销本次已插入的页索引范围。
- **实现**：逐页remove [first,end_exclusive) 的整数页号，忽略remove结果。
- **所有权 / 错误 / 调用**：不释放extent、缩小bounds或更改extent_pages_unindexed；不增加extent_page_removes，所以不触发常规删除计数驱动的rehash。

### `Heap.unindexExtentPages` (`src/core/gc_block_heap.zig:1364`)

- **签名**：`fn unindexExtentPages(self: *Heap, base: usize, span_bytes: usize) void`。
- **作用**：删除extent页索引，或结清一个未索引extent。
- **实现**：以首page项base是否匹配判断是否indexed；未索引时断言unindexed非零并减一；已索引则逐page断言存在、remove并增加extent_page_removes，结束调用compactExtentPagesIfTombstoned。
- **所有权 / 错误 / 调用**：依赖索引全有或全无的协议及合法非零span，不逐页核对每个entry.base；不释放映射或缩减bounds。末个未索引extent被移除后查询恢复页索引路径。

### `Heap.compactExtentPagesIfTombstoned` (`src/core/gc_block_heap.zig:1384`)

- **签名**：`fn compactExtentPagesIfTombstoned(self: *Heap) void`。
- **作用**：根据累计页删除数清理哈希表tombstone。
- **实现**：budget为capacity/4；budget=0或removes不足则返回，否则清removes并用AutoContext原地rehash。
- **所有权 / 错误 / 调用**：不减少映射人口或索引容量，不使用backing分配；阈值是删除次数而非实时tombstone精确数量，rollback删除未计入。

### `Heap.verifyExtentPageIndex` (`src/core/gc_block_heap.zig:1401`)

- **签名**：`pub fn verifyExtentPageIndex(self: *const Heap) ExtentIndexError!void`。
- **作用**：以extent主表对账页索引及未索引计数。
- **实现**：逐medium/large调用verifyOneExtentIndexed，成功索引者累计映射page数，未索引者计数；最后分别与extent_pages.count和extent_pages_unindexed比较，不等返回ExtentIndexOrphanPage。
- **所有权 / 错误 / 调用**：不分配或修复。逐项检查主表所需页，再用总数发现多余项，依赖合法不重叠extent映射；不检验extent_bounds、mark、young列表或真实OS映射。没有编译期开关在函数内阻止生产调用。

### `Heap.verifyOneExtentIndexed` (`src/core/gc_block_heap.zig:1422`)

- **签名**：`fn verifyOneExtentIndexed( self: *const Heap, base: usize, span_bytes: usize, user_bytes: usize, ) ExtentIndexError!bool`。
- **作用**：验证单个extent的页索引是否完整且范围一致。
- **实现**：首page缺失直接false；首项base不符RangeMismatch；首项存在则逐页检查，缺页MissingPage，base或end!=base+user_bytes为RangeMismatch，全部符合true。
- **所有权 / 错误 / 调用**：false表示以首page判断未索引，不证明其余page也全无；残留页由外层总数对账补查。调用方保证合法非零span与整数边界；不改索引。

### `Heap.sweepExtents` (`src/core/gc_block_heap.zig:1454`)

- **签名**：`pub fn sweepExtents( self: *Heap, epoch: u64, ctx: *anyopaque, destroy: *const fn (*anyopaque, usize, usize, bool) void, ) usize`。
- **作用**：对完整major epoch未标记的extent逐个调用释放回调。
- **实现**：断言epoch非零且偶数；遍历medium再large，stamp匹配跳过，其余将base/user_bytes/needs_finalizer传destroy，断言对应主表已无该base并累加destroyed。
- **所有权 / 错误 / 调用**：回调负责析构和Heap.free，不得插入extent导致当前主表迭代失效。返回成功走过回调的extent数，不是字节数；函数不检查young、pin或heap_accounted，依赖收集器先建立正确mark。

### `Heap.containsExtent` (`src/core/gc_block_heap.zig:1485`)

- **签名**：`pub fn containsExtent(self: *const Heap, base: usize) bool`。
- **作用**：判断精确base是否仍存在于任一extent主表。
- **实现**：返回medium.contains(base)或large.contains(base)。
- **所有权 / 错误 / 调用**：不检查发布、mark、young，不接受内部地址解析，也不证明调用者拿到的是同一分配代次。

### `Heap.extentUserBytes` (`src/core/gc_block_heap.zig:1489`)

- **签名**：`pub fn extentUserBytes(self: *const Heap, base: usize) ?usize`。
- **作用**：读取精确extent基址对应的请求字节数。
- **实现**：优先medium，再large，均无则null。
- **所有权 / 错误 / 调用**：返回user_bytes而非页取整映射容量；不转移存储或验证对象构造完成。

### `Heap.sweepYoungExtents` (`src/core/gc_block_heap.zig:1505`)

- **签名**：`pub fn sweepYoungExtents( self: *Heap, epoch: u64, ctx: *anyopaque, destroy: *const fn (*anyopaque, usize, usize, bool) void, ) usize`。
- **作用**：扫描年轻extent候选列表并回收其中未标记的已带young位载体。
- **实现**：断言epoch偶数（允许0）；按index每次重读young_extents.items，base已无主表项则跳过；读取header的young位，为false跳过，marked跳过，其余destroy(ctx,base,user_bytes,needs_finalizer)，断言base已移除后累加。
- **所有权 / 错误 / 调用**：不直接检查heap_accounted，以young位体现调用链发布协议；列表可含过期或复用地址，当前主表/young决定处理。重读避免持有可能失效的slice，但不保证任意回调增删/重排都安全；收集器调用还要求extent析构不发布新年轻对象。不清列表，survivor退役另行进行。

### `Heap.retireYoungExtents` (`src/core/gc_block_heap.zig:1533`)

- **签名**：`pub fn retireYoungExtents(self: *Heap) void`。
- **作用**：关闭列表中仍存在extent的young身份并清空列表。
- **实现**：遍历young_extents；不存在base跳过，其余按base+metadata_prefix_size取得header并清flags.young；最后clearRetainingCapacity。
- **所有权 / 错误 / 调用**：不检查mark、heap_accounted或是否确实survivor，必须在上层正确收集/关闭阶段调用。不释放extent、不改mark或generation census；列表容量保留。

### `Heap.clearYoungExtentMarksStw` (`src/core/gc_block_heap.zig:1545`)

- **签名**：`pub fn clearYoungExtentMarksStw(self: *Heap) void`。
- **作用**：将年轻列表中仍存在extent的mark置为未标记sentinel。
- **实现**：逐base查medium并写extent_unmarked_epoch，否则查large并写；两者无则跳过。
- **所有权 / 错误 / 调用**：不检查header.young/heap_accounted，而依赖年轻列表协议；不清young、不移除列表或推进heap epoch。普通表项写入要求STW。

### `Heap.freeSmallCell` (`src/core/gc_block_heap.zig:1560`)

- **签名**：`pub fn freeSmallCell(self: *Heap, ptr: [*]u8) void`。
- **作用**：按已知block-cell契约直接释放cell，省去extent主表查询。
- **实现**：fromCellTrusted取block，从物理cell前两字节little-endian读取u16 index；断言magic、index范围及cellBase(index)==addr，再freeSmall。
- **所有权 / 错误 / 调用**：ptr必须来自allocCell族并保留索引前缀；这些断言不是任意指针安全解析。函数不执行对象级析构，调用方先履行生命周期与析构责任。

### `Heap.generationFor` (`src/core/gc_block_heap.zig:1570`)

- **签名**：`fn generationFor(self: *Heap, block: *const Block, index: u32) *u32`。
- **作用**：取得一个block cell的可变generation序列槽。
- **实现**：编译期要求block_generation_enabled；按block.super_index取superblock，以地址差/block_bytes取得block_index，断言block与cell索引有效，返回cell_generations槽指针。
- **所有权 / 错误 / 调用**：返回借用侧表，不分配、不递增序列；依赖block属于对应superblock且侧表已初始化。

### `Heap.generationForConst` (`src/core/gc_block_heap.zig:1579`)

- **签名**：`fn generationForConst(self: *const Heap, block: *const Block, index: u32) *const u32`。
- **作用**：只读借用cell generation序列槽。
- **实现**：要求generation配置开启，计算superblock内block_index并检查侧表cell边界，返回const u32指针。
- **所有权 / 错误 / 调用**：不验证任意地址归属，不创建handle；侧表生命周期约束与generationFor相同。

### `Heap.lifecycleFor` (`src/core/gc_block_heap.zig:1588`)

- **签名**：`fn lifecycleFor(self: *Heap, block: *const Block, index: u32) *CellLifecycle`。
- **作用**：取得cell生命周期侧表的可变条目。
- **实现**：编译期要求lifecycle_state_enabled，按super_index和block地址差定位，断言索引后返回cell_lifecycles条目指针。
- **所有权 / 错误 / 调用**：不执行状态迁移、分配或记账；指针借用有效侧表。

### `Heap.lifecycleForConst` (`src/core/gc_block_heap.zig:1597`)

- **签名**：`fn lifecycleForConst(self: *const Heap, block: *const Block, index: u32) *const CellLifecycle`。
- **作用**：只读借用cell生命周期条目。
- **实现**：与lifecycleFor相同的superblock/block/cell定位，返回const CellLifecycle指针。
- **所有权 / 错误 / 调用**：只读访问不等于验证对象当前存活；状态含义由上层检查。

### `Heap.blockIncarnation` (`src/core/gc_block_heap.zig:1606`)

- **签名**：`fn blockIncarnation(self: *const Heap, block: *const Block) u32`。
- **作用**：读取指定block所在槽位的incarnation值。
- **实现**：编译期要求block_generation_enabled，按super_index与block地址差计算block_index，读取block_incarnations。
- **所有权 / 错误 / 调用**：不增值、不验证generation handle；依赖正确归属和数组索引。

### `Heap.reserveCellGeneration` (`src/core/gc_block_heap.zig:1613`)

- **签名**：`fn reserveCellGeneration(self: *Heap, block: *Block, index: u32) std.mem.Allocator.Error!u64`。
- **作用**：为cell保留下一generation序号，组成64位代次。
- **实现**：取得sequence槽；等于maxInt(u32)返回OutOfMemory，否则加一，返回blockIncarnation左移32位与sequence按位或。
- **所有权 / 错误 / 调用**：不是实际分配器OOM；饱和时不回绕，成功修改侧表序号。返回代次而非含地址的AllocationHandle。

### `Heap.popTrackedCell` (`src/core/gc_block_heap.zig:1621`)

- **签名**：`inline fn popTrackedCell(self: *Heap, block: *Block) ?u32`。
- **作用**：从block取可用cell，并按配置建立追踪状态。
- **实现**：tracking关闭直接popCell；开启则循环popCell，generation保留失败继续取下一项；lifecycle开启时设置constructing且accounted_bytes=0，成功返回index，耗尽null。
- **所有权 / 错误 / 调用**：代次耗尽的cell已从分配候选中弹出，不在这里放回；避免复用同代次，但可能降低可用容量。只准备追踪状态，alloc位和allocated_count由allocSmallCell后续更新。

### `Heap.generationHandle` (`src/core/gc_block_heap.zig:1637`)

- **签名**：`pub fn generationHandle(self: *const Heap, object_base: usize, prefix_bytes: usize) ?carrier.AllocationHandle`。
- **作用**：为当前已分配cell构造带地址与代次的handle。
- **实现**：要求generation配置开启；object_base<prefix返回null，否则减prefix，经blockOf与精确cellIndex解析，alloc位未设置返回null；返回原object_base与block incarnation高32位、cell sequence低32位组合。
- **所有权 / 错误 / 调用**：只验证当前地址已分配，不检查published或生命周期允许状态；调用方必须提供正确prefix。不能用重新获取的当前handle证明旧引用没有过期。

### `Heap.containsAllocatedCell` (`src/core/gc_block_heap.zig:1651`)

- **签名**：`pub fn containsAllocatedCell(self: *const Heap, object_base: usize, prefix_bytes: usize) bool`。
- **作用**：检查给定body地址减prefix后是否为已分配cell精确起点。
- **实现**：依次检查减法下界、blockOf、cellIndex，最后读取alloc位，失败false。
- **所有权 / 错误 / 调用**：不检查generation或lifecycle，不证明对象已构造/发布，不能防止地址复用导致的旧引用误认。

### `Heap.resolveExactHandle` (`src/core/gc_block_heap.zig:1666`)

- **签名**：`pub fn resolveExactHandle( self: *const Heap, handle: carrier.AllocationHandle, prefix_bytes: usize, allowed_states: carrier.StateMask, skip_generation_check: bool, ) carrier.ResolveError!ResolvedCell`。
- **作用**：按精确地址、可选代次与允许生命周期集合解析handle。
- **实现**：编译期要求generation和lifecycle；base减prefix越界或无block为NotFound；非cell起点NotExactStart；未allocated为NotFound；未跳过代次且不匹配GenerationMismatch；状态不在allowed_states为StateMismatch；成功返回block/index/state/当前generation。
- **所有权 / 错误 / 调用**：skip_generation_check只绕过代次比较，其它检查保留；错误优先级按上述顺序。返回借用block及状态快照，不pin、不更改状态，调用方须防止随后释放/复用。

### `Heap.transitionCell` (`src/core/gc_block_heap.zig:1687`)

- **签名**：`pub fn transitionCell(self: *Heap, object_base: usize, prefix_bytes: usize, state: carrier.LifecycleState) carrier.ResolveError!void`。
- **作用**：把一个当前已分配cell的生命周期侧表状态直接设为指定值。
- **实现**：要求lifecycle配置；检查base下界、block归属、精确起点、alloc位，失败NotFound或NotExactStart；成功写state。
- **所有权 / 错误 / 调用**：不检查原状态、不验证状态迁移图或generation，不同步alloc/header/accounted_bytes；上层负责合法转换，不能把它称作完整生命周期验证器。

### `Heap.publishCell` (`src/core/gc_block_heap.zig:1697`)

- **签名**：`pub fn publishCell(self: *Heap, object_base: usize, prefix_bytes: usize, accounted_bytes: usize) carrier.ResolveError!void`。
- **作用**：将cell侧表设为published并写入记账字节数。
- **实现**：先try transitionCell(...,.published)，再重新解析block/index并写accounted_bytes。
- **所有权 / 错误 / 调用**：不设置header.heap_accounted、不增Heap/Runtime字节账、不登记根或young链；只是侧表更新。先改state再写bytes，不是带回滚的事务，依赖串行调用和稳定映射。

### `Heap.rawBytesForCell` (`src/core/gc_block_heap.zig:1706`)

- **签名**：`pub fn rawBytesForCell(self: *const Heap, object_base: usize, prefix_bytes: usize) ?usize`。
- **作用**：取得精确cell起点对应的class物理尺寸。
- **实现**：base<prefix返回null；blockOf无归属或cellIndex非精确起点返回null；成功返回block.cell_size。
- **所有权 / 错误 / 调用**：没有检查alloc位、generation或lifecycle，已空闲cell也可能返回尺寸。结果包含prefix，是class容量而非原始请求或记账body字节。

### `Heap.setReuseSequenceForTest` (`src/core/gc_block_heap.zig:1713`)

- **签名**：`pub fn setReuseSequenceForTest(self: *Heap, cell: [*]u8, sequence: u32) void`。
- **作用**：测试专用地把一个 cell 的 generation 序号直接改写成指定值。
- **实现**：非 test 构建 @compileError("test-only helper")；comptime 断言 block_generation_enabled；fromCellTrusted 取 block，cellIndex 必须命中（`.?`），把 generationFor 槽写成 sequence。
- **所有权 / 错误 / 调用**：只改 generation 侧表，不动 alloc 位、lifecycle 或 header，也不分配。src/tests/core.zig 用它把序号顶到 maxInt(u32)，以覆盖 reserveCellGeneration 的代次耗尽分支。

### `Heap.forEachOwnedIdentity` (`src/core/gc_block_heap.zig:1721`)

- **签名**：`pub fn forEachOwnedIdentity( self: *const Heap, prefix_bytes: usize, context: *anyopaque, visit: *const fn (*anyopaque, carrier.AllocationHandle, carrier.LifecycleState) void, ) void`。
- **作用**：枚举classed block生命周期侧表中所有非free条目。
- **实现**：遍历classed superblock的used_blocks前缀和各cell；state为free跳过，其余组合cellBase+prefix与incarnation/sequence并调用visit(context,handle,state)。
- **所有权 / 错误 / 调用**：以lifecycle为枚举依据，不核对alloc位或published，不限于活对象。callback不得破坏正在遍历的superblock/侧表；无快照或拥有权转移，要求generation和lifecycle均开启。

### `Heap.verifyGenerationAuthority` (`src/core/gc_block_heap.zig:1747`)

- **签名**：`pub fn verifyGenerationAuthority(self: *const Heap) VerifyError!void`。
- **作用**：对账block代次侧表的基本有效性。
- **实现**：遍历classed已用block；incarnation为0或generation数组长度不等cell_count返回CarrierIdentityMismatch；逐cell检查allocated时generation不得为0。
- **所有权 / 错误 / 调用**：不验证全局handle唯一性、旧引用、生命周期或序列单调历史；free cell允许保留非零sequence。只检查，不修复。

### `Heap.verifyLifecycleAuthority` (`src/core/gc_block_heap.zig:1767`)

- **签名**：`pub fn verifyLifecycleAuthority(self: *const Heap) VerifyError!void`。
- **作用**：对账alloc位与生命周期侧表。
- **实现**：遍历classed已用block，侧表长度须等cell_count；逐cell要求allocated等价于state!=free，并要求free cell accounted_bytes=0，否则CarrierIdentityMismatch。
- **所有权 / 错误 / 调用**：不检查非free cell的具体允许状态、账面字节是否正确或header发布位一致性；零错误不能代替完整生命周期审计。

### `Heap.reclaimDoomedCells` (`src/core/gc_block_heap.zig:1798`)

- **签名**：`pub fn reclaimDoomedCells(self: *Heap, block: *Block) u32`。
- **作用**：释放已排空析构子集、已脱离doomed链的剩余死亡cell。
- **实现**：断言doomed_link==0，统计remember位图死亡数；0直接返回。active block或本次将全空时逐takeDoomedCell/freeSmall，断言计数一致。其它block按配置将死亡cell lifecycle置free并清accounted_bytes，再reclaimDoomedIntoBitmap，清hot_rejected，饱和增加bitmap_reclaimed_cells。
- **所有权 / 错误 / 调用**：必须先处理finalizer并unlink，缓存应遵守位图消费协议。批量分支不直接增减Heap.live_bytes/count或Runtime账，这些由对应分配/收集协议处理；返回cell数，不执行对象析构。bitmap_reclaimed_cells只计批量分支，不含逐cell分支。

### `Heap.censusBlocks` (`src/core/gc_block_heap.zig:1831`)

- **签名**：`pub fn censusBlocks(self: *const Heap) BlockCensus`。
- **作用**：按class汇总block占用与各池链成员数量。
- **实现**：初始化每行cell_bytes；classed之外的superblock槽计other_superblocks（包括tombstone）。classed按used_blocks遍历，magic或class非法记uninitialized；其余累加cells/allocated、young/decommitted及empty/<10%/<50%/≥50%分桶；另外遍历active/hot/free链计各行成员。
- **所有权 / 错误 / 调用**：按allocated_count字段统计，不重新popCount验证；分桶比例使用整数除法。成员维度可与占用分桶重叠，不可全部相加当block总数。函数不分配但会遍历堆和链，诊断在退出时调用不等于执行零成本；不报告extent占用的逐class明细。

### `Heap.verifyBlockAllocCount` (`src/core/gc_block_heap.zig:1884`)

- **签名**：`pub fn verifyBlockAllocCount(block: *Block) VerifyError!void`。
- **作用**：核对一个block的alloc位数与allocated_count。
- **实现**：对alloc bitmap全部word执行popCount累加，不等allocated_count返回AllocCountMismatch。
- **所有权 / 错误 / 调用**：不检查高于cell_count的尾部bit、mark/finalizer关系、链或生命周期；例如两个值一致不能证明所有位都指向合法已发布cell。

### `Heap.owns` (`src/core/gc_block_heap.zig:1890`)

- **签名**：`pub fn owns(self: *const Heap, ptr: [*]u8) bool`。
- **作用**：查询地址是否为extent精确基址或位于本heap已登记的classed block。
- **实现**：先查large/medium主表的精确key，再blockOf(ptr)。
- **所有权 / 错误 / 调用**：两类判定粒度不同：block分支不检查cell起点或alloc位，block header、空闲cell或内部地址也可能true；不能等同于拥有一个有效活对象。

### `Heap.noteYoungCell` (`src/core/gc_block_heap.zig:1899`)

- **签名**：`pub inline fn noteYoungCell(self: *Heap, block: *Block) void`。
- **作用**：将尚未young-listed的block加入年轻block链头。
- **实现**：isYoungListed为真直接返回；否则置flag_young，young_link保存旧head地址或尾哨兵1，更新young_blocks。
- **所有权 / 错误 / 调用**：只登记block，不设置某个cell的young/mark，不更新young人口统计；调用方保证传入有效block。

### `Heap.clearYoungBlocks` (`src/core/gc_block_heap.zig:1907`)

- **签名**：`pub fn clearYoungBlocks(self: *Heap) usize`。
- **作用**：清空年轻block链及其成员标志。
- **实现**：沿young_link遍历，先保存link，再清flag_young和young_link，累计block数；link<=1结束，最后head置null并返回数量。
- **所有权 / 错误 / 调用**：返回block数不是cell晋升数；不清cell header.young、mark或generation census，上层须完成相应退役。

### `Heap.clearYoungBlockMarksStw` (`src/core/gc_block_heap.zig:1924`)

- **签名**：`pub fn clearYoungBlockMarksStw(self: *Heap) void`。
- **作用**：沿年轻block链执行本heap epoch的局部清标记。
- **实现**：对每个block调用clearYoungMarksStw(mark_epoch)，按young_link继续。
- **所有权 / 错误 / 调用**：不改变链、epoch或extent标记；只适用于STW，逐cell发布/young过滤由Block方法执行。

### `Heap.noteNonemptyBlock` (`src/core/gc_block_heap.zig:1936`)

- **签名**：`fn noteNonemptyBlock(self: *Heap, block: *Block) void`。
- **作用**：在classed superblock的非空block索引置位。
- **实现**：通过super_index定位，断言kind为classed；用block地址差计算index并断言小于used_blocks，再setPage(page_bits,index)。
- **所有权 / 错误 / 调用**：此处page_bits按block槽而非4KiB页解释；只更新索引，不改allocated_count，调用方在0变非0时使用。

### `Heap.noteEmptyBlock` (`src/core/gc_block_heap.zig:1944`)

- **签名**：`fn noteEmptyBlock(self: *Heap, block: *Block) void`。
- **作用**：在classed superblock的非空索引中移除block。
- **实现**：与noteNonemptyBlock相同定位和断言，随后clearPage(page_bits,index)。
- **所有权 / 错误 / 调用**：不返还映射、decommit或清位图；空block转移的其它步骤由调用方负责。

### `Heap.hasHotReuseCapacity` (`src/core/gc_block_heap.zig:1952`)

- **签名**：`fn hasHotReuseCapacity(block: *const Block) bool`。
- **作用**：判断block空闲cell占比是否达到hot复用容量门槛。
- **实现**：free_cells=cell_count-allocated_count，比较free_cells*100>=cell_count*hot_reuse_min_free_percent（10）。
- **所有权 / 错误 / 调用**：只看总空闲比例，不检查最大连续区间、young/doomed/active或映射状态；不单独决定可分配。

### `Heap.withdrawHotBlocks` (`src/core/gc_block_heap.zig:1960`)

- **签名**：`fn withdrawHotBlocks(self: *Heap) void`。
- **作用**：撤回上一轮各class hot池成员并重建其冷态空闲区间表示。
- **实现**：各head先置null；逐block断言hot_list，保存next_free，清hot_list并将next_free置free_nil，再rebuildFreeIntervals，按保存链接继续。
- **所有权 / 错误 / 调用**：重建会写空闲cell中的interval node，非只断链。依赖hot池成员满足非空、无待处理doomed及容量条件；不释放映射或把block改为active。

### `Heap.findCellState` (`src/core/gc_block_heap.zig:1982`)

- **签名**：`fn findCellState(block: *Block, start: u32, want_allocated: bool) u32`。
- **作用**：从指定索引起查第一个分配状态符合要求的cell。
- **实现**：start>=cell_count返回cell_count；逐alloc word，按want_allocated取原值或取反，屏蔽起点前bit和最后word越界bit；有匹配返回最低bit索引，否则返回cell_count。
- **所有权 / 错误 / 调用**：cell_count是未找到哨兵；查询alloc状态，不看mark/young或header，不修改bitmap。

### `Heap.writeIntervalNode` (`src/core/gc_block_heap.zig:2004`)

- **签名**：`fn writeIntervalNode(block: *Block, start: u32, end: u32, next: u32) void`。
- **作用**：在空闲区间首cell写入区间链节点。
- **实现**：断言start<end<=cell_count且next为free_nil或有效cell索引；首4字节写free_poison | (next & free_link_mask)，随后4字节写end。
- **所有权 / 错误 / 调用**：覆盖的是空闲cell前8字节，调用方须证明该区间可写且没有活对象；end为区间尾后索引，不是长度。

### `Heap.rebuildFreeIntervals` (`src/core/gc_block_heap.zig:2016`)

- **签名**：`fn rebuildFreeIntervals(block: *Block) u32`。
- **作用**：从alloc位图重建按地址排列的最大连续空闲区间。
- **实现**：断言block非空、无pending doomed且空闲比例达门槛；设置interval_allocator，清hot_list/bitmap_canonical并重置游标及链。反复findCellState寻找空闲起点和下一allocated边界；首区间放入bump/interval_end，其余区间以writeIntervalNode串入free_list；返回最大区间cell数。
- **所有权 / 错误 / 调用**：须在block私有且死亡事务完成后调用。只写区间头、不逐cell建立free link；会重置next_free异常返还链并依据alloc位图重新涵盖空洞，不改变alloc位或allocated_count。

### `Heap.publishHotBlock` (`src/core/gc_block_heap.zig:2061`)

- **签名**：`fn publishHotBlock(self: *Heap, block: *Block) void`。
- **作用**：将满足条件的部分空闲block挂入对应class hot池。
- **实现**：依次拒绝空block、空闲比例不足、active、pending doomed、young、已hot-listed、decommitted、cached hot_rejected，各自饱和记录拒绝计数。通过后清interval_allocator，用next_free串hot链，置hot_list，更新head并增加hot_blocks_published。
- **所有权 / 错误 / 调用**：这里不重建interval、不检查最长连续区间；真正选用时openBlock才准备并可能因区间不足拒绝。next_free此时是block链地址（尾0），不是cell索引链。

### `Heap.publishCompletedHotBlocks` (`src/core/gc_block_heap.zig:2113`)

- **签名**：`pub fn publishCompletedHotBlocks(self: *Heap) void`。
- **作用**：在doomed链为空时扫描全部superblock并发布可复用block。
- **实现**：断言doomed_blocks==null；逐superblock调用publishSuperblockHotBlocks。
- **所有权 / 错误 / 调用**：不在函数内核对延迟payload finalizer或其它runtime全局完成条件，上层负责调用时机。可多次调用，已listed成员被跳过，不执行cell析构。

### `Heap.publishCompletedHotBlocksSlice` (`src/core/gc_block_heap.zig:2137`)

- **签名**：`pub fn publishCompletedHotBlocksSlice( self: *Heap, parked_frees: usize, superblock_budget: usize, ) void`。
- **作用**：按superblock数量预算轮转发布hot block。
- **实现**：parked_frees非零直接返回；断言doomed链为空；无superblock返回。校正cursor后最多扫描min(superblock_budget,total)个槽，环绕并保存游标。
- **所有权 / 错误 / 调用**：预算是superblock槽数而非纳秒或实际block访问数；medium/tombstone槽也消耗预算，budget=0不扫描。parked_frees是调用者提供值，不在此查真实外部状态。

### `Heap.publishSuperblockHotBlocks` (`src/core/gc_block_heap.zig:2156`)

- **签名**：`fn publishSuperblockHotBlocks(self: *Heap, sb: *Superblock) void`。
- **作用**：从classed superblock非空索引枚举hot发布候选。
- **实现**：非classed返回；取page_bits[0]副本逐最低bit定位block，已经hot_listed则跳过，其余publishHotBlock。
- **所有权 / 错误 / 调用**：使用非空索引避免扫描空block；不重新核对索引与allocated_count一致性，依赖维护不变量。副本只覆盖这次枚举，非整个heap并发安全快照。

### `Heap.recordDoomedBlock` (`src/core/gc_block_heap.zig:2182`)

- **签名**：`fn recordDoomedBlock( self: *Heap, block: *Block, counts: DoomedCounts, result: *DoomedSnapshot, comptime origin: DoomedOrigin, ) void`。
- **作用**：累计一个block死亡快照的数量/字节，并登记doomed链。
- **实现**：dead=0时仅major origin尝试publishHotBlock；dead非零且major下active block死亡比例达到10%时清active。累计count=dead、bytes=dead*cell_size、bitmap_bytes=(dead-finalizing)*(cell_size-metadata_prefix_size)；尚未链接则用旧head或尾哨兵1插入doomed链。
- **所有权 / 错误 / 调用**：不执行快照、析构或实际扣字节账；bitmap_bytes仅为不需析构子集的prefix排除记账，不能与含prefix的bytes互换。minor origin不会在此发布hot或撤回active；counts须满足finalizing<=dead。

DoomedSnapshot 的 count 为死亡cell数，bytes 为含metadata prefix的class容量和，bitmap_bytes 仅统计无需析构子集且扣除prefix；DoomedOrigin 的 minor/major 决定recordDoomedBlock是否执行major特有的分配池调整。decommit_min_idle_ns=1秒，decommit_period_ns=100毫秒，process_trim_min_decommitted_bytes=128MiB；这些是当前固定策略常量，decommit统计与整段medium释放统计分开。

### `Heap.snapshotAllDoomed` (`src/core/gc_block_heap.zig:2223`)

- **签名**：`pub fn snapshotAllDoomed(self: *Heap, epoch: u64) DoomedSnapshot`。
- **作用**：对所有classed superblock中的非空block建立major死亡快照。
- **实现**：逐classed superblock枚举page_bits[0]非空block索引，断言magic正确且allocated_count非零；调用block.snapshotDoomed(epoch)，再recordDoomedBlock(...,.major)，返回累积DoomedSnapshot。
- **所有权 / 错误 / 调用**：all指classed block人口，不包含medium/large extent或非block载体。会重写死亡位图、链接doomed，并可能撤回active或发布无死亡的hot block；不执行析构或直接扣Runtime账，调用方先保证标记完成及旧死亡批次已结束。

### `Heap.snapshotYoungDoomed` (`src/core/gc_block_heap.zig:2249`)

- **签名**：`pub fn snapshotYoungDoomed(self: *Heap, epoch: u64) DoomedSnapshot`。
- **作用**：沿年轻block链建立minor死亡快照并累计数量/字节。
- **实现**：逐block先保存young_link，调用snapshotDoomed(epoch)及recordDoomedBlock(...,.minor)，按保存链接前进。
- **所有权 / 错误 / 调用**：并未逐cell检查young位，依赖old sticky marks保留及minor入口正确清标记，使alloc & ~mark仅指应判死候选。无extent扫描；不会在recordDoomedBlock中执行major特有的hot发布或active撤回。

### `Heap.decommitCellPages` (`src/core/gc_block_heap.zig:2277`)

- **签名**：`fn decommitCellPages(block: *Block) bool`。
- **作用**：向OS请求丢弃一个block保留前缀以外的页面内容。
- **实现**：Windows或decommit_bytes=0返回false；其它平台以block末尾decommit_bytes区间调用madvise(DONTNEED)，错误返回false，成功true。
- **所有权 / 错误 / 调用**：不unmap整块，不更新block标志或heap账目，调用方须保证区域无活cell并重置失效空闲链。成功表示系统调用接受请求，不是测得RSS立即下降的证明；保留大小考虑OS最小页对齐。

### `Heap.releaseFreeBlockPages` (`src/core/gc_block_heap.zig:2294`)

- **签名**：`pub fn releaseFreeBlockPages(self: *Heap, now_ns: u64) usize`。
- **作用**：按时间节流回收长期空闲block的页面，并尝试释放空medium superblock。
- **实现**：先写clock_ns；距last_decommit_ns不足100ms返回0，否则更新时间及checks。遍历free_blocks，跳过已decommitted、空闲未满1s、无可丢弃区间或madvise失败者；成功重置bump=0/free_list=free_nil并置decommitted。累计decommitted_bytes、扣committed_bytes、更新block批次最大值；随后releaseEmptyMediumSuperblocks，再以两类释放字节和调用trimProcessHeapAfterLargeShrink，返回总和。
- **所有权 / 错误 / 调用**：不在这里重新验证free链成员allocated_count为0，依赖链维护不变量；普通计数加减非事务回滚。返回值包含medium映射释放，但decommitted_bytes及decommit_max_batch_bytes仅计block页。未到节流时间也不会执行medium释放或trim；时钟回退经饱和差值按未满周期处理。

### `Heap.trimProcessHeapAfterLargeShrink` (`src/core/gc_block_heap.zig:2337`)

- **签名**：`fn trimProcessHeapAfterLargeShrink(self: *Heap, released: usize) void`。
- **作用**：在glibc目标且收缩阈值判断成立时尝试进程级malloc_trim。
- **实现**：非GnuLibC编译目标直接返回；current取Stats.currentDecommittedBytes，processHeapTrimNeeded(current,released)为假返回；否则增加attempts，malloc_trim(0)非零增加successes。
- **所有权 / 错误 / 调用**：current仅为block decommit减recommit，而调用方released可含medium映射释放；没有独立episode锁存状态，不能保证每个收缩阶段只调用一次。trim作用于进程libc堆，成功计数不表示精确回收多少字节。

VerifyError 将失败分为布局/索引/过滤器、bitmap尾位与计数、空闲链及poison、young/doomed成员关系、发布前缀、sweep状态、carrier identity等类别。同一错误值可由多种检查触发，不能把错误名当成唯一根因。

UnpublishedCellAllowance 保存借用context和分类回调。Kind.none不放行；unmarked_construction不要求mark；marked_construction要求当前heap epoch已标记；parked_finalizer不要求存活mark；当前Registry分类回调仅按未发布/finalizing/condemned/Object/block前缀条件放行，并未查询待终结栈成员。只有prefix合法的未accounted cell才询问回调；它不是通用忽略审计的开关。

### `Heap.verify` (`src/core/gc_block_heap.zig:2383`)

- **签名**：`pub fn verify(self: *Heap) VerifyError!void`。
- **作用**：核对classed block布局、分配位图、空闲表示和池/代际链之间的不变量。
- **实现**：逐classed superblock检查used_blocks、初始化block成员索引/非空索引及magic/class；按active或swept稳定状态约束allocated_count与active槽，拒绝fresh/needs_sweep/sweeping。重算geometry，比对所有位图/cell偏移、计数和bump；popCount核对allocated_count，检查四张位图尾部无越界bit、doomed位及缓存均为alloc子集。按hot未准备态、bitmap_canonical、interval或普通free-chain区分空闲表示：前两者不遍历cell空闲链，interval检查各段/返还链与空闲总量，普通链检查索引/poison/已分配冲突/环及bump-count完整性。检查decommitted block为空。随后对账classed_blocks总数和OR过滤器，并遍历young、doomed、free、hot链与active槽，校验归属、状态、class、成员条件及链长度上限，按计数核对young/hot标志与doomed/free候选人口。
- **所有权 / 错误 / 调用**：遇首个问题返回VerifyError，部分free-chain异常另打印；不修复、不分配。函数自身没有arena-audit开关，调用方决定是否执行。只覆盖classed结构，不调用extent页索引、generation/lifecycle或发布前缀验证，也不证明GC可达性。链环通过长度上限发现，检查运行需处于稳定边界；不能在重建/析构中间态要求同样通过。

### `Heap.verifyPublishedCellsAllowing` (`src/core/gc_block_heap.zig:2776`)

- **签名**：`pub fn verifyPublishedCellsAllowing( self: *const Heap, block_cell_marker: u5, object_kind: u4, allowance: ?UnpublishedCellAllowance, ) VerifyError!void`。
- **作用**：执行发布前缀核对，并要求正常young cell所属block已列入young链。
- **实现**：直接调用verifyCellsAllowing(block_cell_marker,object_kind,allowance,true)。
- **所有权 / 错误 / 调用**：不是先调用Heap.verify；布局与映射有效性是前提。allowance提供构造根或待finalizer状态分类；当前Registry的parked分类不查栈成员，具体放行逻辑见共同实现及回调。

### `Heap.verifyAccountingCellsAllowing` (`src/core/gc_block_heap.zig:2789`)

- **签名**：`pub fn verifyAccountingCellsAllowing( self: *const Heap, block_cell_marker: u5, object_kind: u4, allowance: ?UnpublishedCellAllowance, ) VerifyError!void`。
- **作用**：执行记账边界所需的cell发布前缀核对。
- **实现**：调用verifyCellsAllowing(block_cell_marker,object_kind,allowance,false)，关闭young成员要求。
- **所有权 / 错误 / 调用**：保留索引stamp、prefix与accounted检查，但不因young未入链报错；不计算或对账Runtime字节总量，不能仅凭名称视为完整记账验证。

### `Heap.verifyCellsAllowing` (`src/core/gc_block_heap.zig:2798`)

- **签名**：`fn verifyCellsAllowing( self: *const Heap, block_cell_marker: u5, object_kind: u4, allowance: ?UnpublishedCellAllowance, require_young_membership: bool, ) VerifyError!void`。
- **作用**：核对已分配cell的索引stamp、发布前缀及可选young链条件。
- **实现**：逐classed已用block枚举allocated cell；首u16须等index。读取byte2 alloc_info和byte3 flags，要求非standalone、class marker匹配，kind为传入object_kind或string/rope/string_buffer/property_storage/array_storage/payload。仅在未accounted且prefix合法时调用allowance.classify(context,cell)：unmarked_construction或parked_finalizer直接continue，marked_construction在当前epoch marked时continue，none不放行。其余若未accounted或prefix非法返回AllocatedCellUnpublished；正常已发布cell在require_young_membership且young、非pending doomed、block未young-listed时打印并返回YoungCellUnlisted。
- **所有权 / 错误 / 调用**：allowance收到物理cell基址而非body地址；函数信任分类回调，不自行检查对应集合；当前Registry构造分支查pin账，但parked分支只查前缀条件，不能视为parked栈成员证明。获准例外直接跳过后续young检查；无例外可绕过索引stamp或非法prefix。pending doomed包含位图与缓存。这里不验证对象字段初始化或追踪边完整性，且以本机u16读取stamp，不执行独立little-endian解码。

### `Heap.blockOf` (`src/core/gc_block_heap.zig:2883`)

- **签名**：`pub fn blockOf(self: *const Heap, ptr: [*]u8) ?*Block`。
- **作用**：安全按本heap登记集合解析候选地址所属classed block。
- **实现**：调用blockOfWithFilter(ptr,classed_block_filter)。
- **所有权 / 错误 / 调用**：先验证成员再读取magic；不同于直接读取取整地址的Block.fromAddr。不检查候选是否为cell起点或已分配、已发布对象。

### `Heap.scanFilter` (`src/core/gc_block_heap.zig:2896`)

- **签名**：`pub inline fn scanFilter(self: *const Heap) usize`。
- **作用**：读取classed block地址OR过滤值供一段扫描复用。
- **实现**：直接返回classed_block_filter。
- **所有权 / 错误 / 调用**：是粗过滤值而非完整成员集合；在无新增block的STW扫描段中可复用。不能把旧过滤值用于之后可能新增block的查询并保证不漏。

### `Heap.blockOfWithFilter` (`src/core/gc_block_heap.zig:2900`)

- **签名**：`pub inline fn blockOfWithFilter(self: *const Heap, ptr: [*]u8, filter: usize) ?*Block`。
- **作用**：用粗过滤与精确成员集合确认block后才读取其header。
- **实现**：地址低于64KiB返回null；向下对齐得到base，(base & filter)!=base则拒绝；classed_blocks无base则拒绝，最后读magic，不符null，匹配返回block。
- **所有权 / 错误 / 调用**：传入filter须包含待扫描人口，额外bit最多增加查表，缺bit可能漏成员。只证明classed block归属，medium/large和cell分配有效性另查。

### `Heap.liveSmall` (`src/core/gc_block_heap.zig:2920`)

- **签名**：`pub fn liveSmall(self: *const Heap) struct { bytes: usize, count: usize }`。
- **作用**：汇总classed block的已分配cell数量及容量字节。
- **实现**：遍历classed used_blocks，magic不符跳过；按allocated_count加count，按allocated_count*cell_size加bytes。
- **所有权 / 错误 / 调用**：实际读取缓存计数而不是重新popCount位图；包含cell prefix及class内部余量，未按GC mark、发布或doomed状态过滤。live在这里是已分配存储口径，不是精确可达对象大小。

### `Heap.census` (`src/core/gc_block_heap.zig:2970`)

- **签名**：`pub fn census(self: *const Heap) Census`。
- **作用**：汇总classed堆的占用拓扑及逐class容量。
- **实现**：medium只计medium_superblocks，tombstone跳过；classed按page_bits[0]判全空，按used_blocks统计已初始化/尚未使用槽。各有效magic block累计class live_cells/capacity、hot与active interval标志；allocated_count=0按active身份分empty_active/empty_free，否则累计非空容量和live_cell_bytes，未满计partial。
- **所有权 / 错误 / 调用**：不验证class索引或链一致性，empty_free由非active空block推定而非走free链。全局initialized_blocks按used_blocks，magic异常跳过后可能与class行之和不同；字节是cell容量，不含整块header/位图，也不是RSS。

### `Heap.liveBytes` (`src/core/gc_block_heap.zig:3028`)

- **签名**：`pub fn liveBytes(self: *const Heap) usize`。
- **作用**：汇总small及extent的当前分配字节口径。
- **实现**：liveSmall().bytes加所有large.bytes.len，再加所有medium.user_bytes。
- **所有权 / 错误 / 调用**：三类口径不同：small按class容量、large按映射slice长度、medium按请求长度。包含已分配但尚未析构的垃圾，不代表GC标记存活集或Runtime净body账。

### `Heap.committedLiveMilli` (`src/core/gc_block_heap.zig:3037`)

- **签名**：`pub fn committedLiveMilli(self: *const Heap) usize`。
- **作用**：计算committed/live分配字节比率的向上取整千分值。
- **实现**：liveBytes为0返回0，否则(committed_bytes*1000+live-1)/live。
- **所有权 / 错误 / 调用**：0表示分母为0的特殊约定，不意味着已提交内存为0；普通usize乘加可能溢出，非饱和运算。比率受liveBytes混合容量口径影响，非RSS放大率。

### `Heap.containsBlock` (`src/core/gc_block_heap.zig:3043`)

- **签名**：`fn containsBlock(self: *const Heap, block: *const Block) bool`。
- **作用**：查询精确block基址是否在classed登记集合。
- **实现**：以指针整数值查classed_blocks.contains。
- **所有权 / 错误 / 调用**：不解引用magic，不向下对齐，不查cell分配或当前内容。

### `Heap.containsInitializedBlock` (`src/core/gc_block_heap.zig:3047`)

- **签名**：`fn containsInitializedBlock(self: *const Heap, block: *const Block) bool`。
- **作用**：使用classed成员集合判断已初始化block归属。
- **实现**：直接返回containsBlock(block)。
- **所有权 / 错误 / 调用**：依赖登记集合准确性，没有额外初始化字段或magic检查；名称不扩大该谓词的保证。

### `Heap.blockFromListLink` (`src/core/gc_block_heap.zig:3051`)

- **签名**：`fn blockFromListLink(self: *const Heap, link: usize) VerifyError!?*Block`。
- **作用**：解析young/doomed链的地址链接。
- **实现**：1为尾返回null，0或未按64KiB对齐报ListLinkOutOfHeap；转换指针后查initialized集合，随后检查magic，成功返回block。
- **所有权 / 错误 / 调用**：先成员后解引用；不检查block确实属于哪条链或状态，成员/环检查由审计调用方完成。

### `Heap.blockFromFreeLink` (`src/core/gc_block_heap.zig:3061`)

- **签名**：`fn blockFromFreeLink(self: *const Heap, link: usize) VerifyError!?*Block`。
- **作用**：解析free/hot链使用的零尾哨兵链接。
- **实现**：0返回null，1报ListLinkOutOfHeap，其余转交blockFromListLink。
- **所有权 / 错误 / 调用**：与young/doomed链尾哨兵约定相反，不能混用；不改变链。

### `Heap.allocSmall` (`src/core/gc_block_heap.zig:3067`)

- **签名**：`fn allocSmall(self: *Heap, class_idx: usize, user_bytes: usize) std.mem.Allocator.Error![]u8`。
- **作用**：以给定class分配cell并返回请求长度slice。
- **实现**：读取classes[class_idx]尺寸，try allocSmallCell，返回cell[0..user_bytes]。
- **所有权 / 错误 / 调用**：调用方保证class能容纳请求；slice起点包含物理prefix空间，不自动增加/跳过prefix，底层容量可能大于slice长度。OOM上抛，未完成对象构造或发布。

### `Heap.freeSmall` (`src/core/gc_block_heap.zig:3073`)

- **签名**：`fn freeSmall(self: *Heap, block: *Block, index: u32, cell: [*]u8) void`。
- **作用**：清除cell分配状态并维护空闲表示与空block池。
- **实现**：alloc位已清则返回；forgetDoomedCell，按配置设raw_free_in_progress；清alloc与finalizer，pushCell，减allocated_count并清hot_rejected；按配置置free且accounted_bytes=0。变全空时noteEmptyBlock；若仍为active立即返回，否则清interval/hot/bitmap_canonical标志，重置bump/interval/free_list，置swept，记free_time_ns并入对应free_blocks链。
- **所有权 / 错误 / 调用**：不调用析构、不清mark、不递增generation、不直接改Runtime字节账。依赖合法block/index/cell及链状态；已清alloc时无操作不是任意悬空指针安全保证。active空block不进入aged free池；非active空块入池前young/doomed等外部义务须由调用链协调。

### `Heap.openBlock` (`src/core/gc_block_heap.zig:3112`)

- **签名**：`fn openBlock(self: *Heap, class_idx: usize, cell_size: u32) std.mem.Allocator.Error!*Block`。
- **作用**：按hot部分空闲、同class全空池、新classed槽的顺序取得分配block。
- **实现**：逐个摘hot链头，清hot_list并设active sweep_state，rebuildFreeIntervals；最大区间不足64 cell则记k_rejected并缓存hot_rejected，继续候选，满足则记reopened并返回。无hot时摘同class free链头，若decommitted先增加recommitted/committed账，再resetBlock(reused=true)，设active返回；再无则takeClassedBlock、resetBlock(reused=false) 后直接置 active 返回（resetBlock 已写成 fresh，原先那条重复写 fresh 的死存储已删）。
- **所有权 / 错误 / 调用**：返回block不等于已写入Heap.active槽，调用方负责。被K拒绝的部分空闲block仍保持映射及合法区间表示。整个选择过程不是事务：在后续takeClassedBlock失败前可能已撤下并重建hot候选。当前resetBlock虽带error set，却无实际返回error的分支；不能据签名虚构其OOM路径。

### `Heap.takeClassedBlock` (`src/core/gc_block_heap.zig:3158`)

- **签名**：`fn takeClassedBlock(self: *Heap, cell_size: u32) std.mem.Allocator.Error!struct { ptr: [*]u8, super_index: u32 }`。
- **作用**：为指定cell尺寸取得一个新的classed block槽并登记成员。
- **实现**：先线性查已有classed且used_blocks<32的superblock，按geometry分配/清零可选generation/lifecycle侧表；循环体级errdefer在后续失败时释放并清空这些侧表。classed_blocks.put成功后OR过滤器并增加used_blocks。没有槽则reserveSuperblock，预留32个成员容量，再分配首槽侧表；失败显式释放侧表/撤销superblock，成功putAssumeCapacity并置used_blocks=1。
- **所有权 / 错误 / 调用**：返回物理槽指针和稳定super_index，尚未resetBlock完成header布局。新superblock回滚不必缩减已经增长的索引容量；已有superblock分支查找成本随superblock数变化，不能说整个small慢路径恒定时间。

### `Heap.reserveSuperblock` (`src/core/gc_block_heap.zig:3239`)

- **签名**：`fn reserveSuperblock(self: *Heap, kind: SuperblockKind) std.mem.Allocator.Error!u32`。
- **作用**：映射一段2MiB superblock并取得可复用的稳定槽索引。
- **实现**：拒绝tombstone kind。generation开启且classed时先为32个block预留incarnation，达到maxInt(u32)或exhausted则OOM并锁存耗尽；随后backing.alignedAlloc按64KiB对齐，失败上抛。优先取free_superblock_slots墓碑槽，否则append fresh；append失败errdefer释放映射；写fresh并增加superblocks/committed_bytes，返回slot。
- **所有权 / 错误 / 调用**：返回索引不是数组指针，数组增长可能使旧指针失效。incarnation预留发生在映射/append前，后续失败不回滚序列，允许有空洞而不复用代次；耗尽OOM不代表物理内存不足。

### `Heap.unreserveSuperblock` (`src/core/gc_block_heap.zig:3284`)

- **签名**：`fn unreserveSuperblock(self: *Heap, slot: u32) void`。
- **作用**：归还一段映射并回收其superblock槽，保持其它槽索引稳定。
- **实现**：断言非tombstone、bucket前后链接均nil且max_free_run=0；减少superblocks/committed_bytes。若为数组尾槽则缩len，否则写零长度bytes的tombstone并挂入空槽链；最后backing.free原bytes。
- **所有权 / 错误 / 调用**：不搬移其它槽，不自行释放cell侧表、移除classed成员或摘bucket；调用方须先履行这些义务，只能对可安全撤销/释放的superblock调用。释放后原映射指针失效，数组容量通常保留。

medium_spare_superblocks=1，medium_release_min_idle_ns沿用decommit_min_idle_ns（1秒）。备用数是在释放扫描中对已满足全空及空闲时长条件的块计数，未达标块并不消耗这个保留名额。

### `Heap.whollyEmpty` (`src/core/gc_block_heap.zig:3332`)

- **签名**：`fn whollyEmpty(sb: *const Superblock) bool`。
- **作用**：判断superblock页位图是否全零。
- **实现**：逐page_bits word检查，任一非零false，全部为零true。
- **所有权 / 错误 / 调用**：只读bitmap，不查extent主表或block cell；用于medium时表示无已占页，不能脱离SuperblockKind解释该位图。

### `Heap.releaseEmptyMediumSuperblocks` (`src/core/gc_block_heap.zig:3339`)

- **签名**：`fn releaseEmptyMediumSuperblocks(self: *Heap, now_ns: u64) usize`。
- **作用**：释放空闲时长达标的medium superblock，同时保留一个符合条件的备用块。
- **实现**：逐槽筛medium、max_free_run==max_medium_pages、whollyEmpty及空闲至少medium_release_min_idle_ns。按遍历顺序保留首个达标块；其余bucketUnlink、max_free_run置0、unreserveSuperblock，并累计释放字节和medium释放统计。
- **所有权 / 错误 / 调用**：max_free_run为截断值，不能单独证明全空；真正依据是整张page bitmap。spare计数只包含本次达标者，不是所有medium块。不执行extent析构，前提是其中已无分配；整段归还与classed页decommit不同，返回字节为2MiB整数倍。

### `Heap.resetBlock` (`src/core/gc_block_heap.zig:3369`)

- **签名**：`fn resetBlock( self: *Heap, block: *Block, class_idx: usize, cell_size: u32, super_index: u32, reused: bool, ) std.mem.Allocator.Error!void`。
- **作用**：重建空block header和四张空位图。
- **实现**：安全构建reused时断言未young-listed且doomed_link为0；计算geometry并检查容量、侧表长度及lifecycle全free。整体写入magic、当前epoch、class/geometry、零allocated/bump、free_nil等字段，sweep_state设fresh，其余字段用默认值；清alloc/mark/remember/finalizer。
- **所有权 / 错误 / 调用**：当前函数体不分配也没有返回error分支，尽管声明Allocator.Error!void；断言失败不能描述成可恢复OOM。不会清cell body或重置generation序列，要求调用方已证明block无活分配且链已摘除。

### `Heap.allocMedium` (`src/core/gc_block_heap.zig:3427`)

- **签名**：`fn allocMedium(self: *Heap, n: usize) std.mem.Allocator.Error![]u8`。
- **作用**：分配1至max_medium_pages页的extent并登记主表与年轻候选列表。
- **实现**：请求向上取页数并断言范围；先ensureUnusedCapacity于medium与young_extents，再从桶取superblock或reserve medium并入最大桶。scanFreeRuns找首个足够页段，置page_bits并rebucket；putAssumeCapacity记录extent，indexExtentPages，再appendAssumeCapacity年轻base，按请求n更新live_bytes/count和medium_allocs，返回n长slice。
- **所有权 / 错误 / 调用**：可传播分配失败发生在页占用前，容量增长等准备状态不保证回退。页索引OOM不令本分配失败，而由unindexed计数启用线性解析。年轻列表记录发生在对象发布之前；返回的页取整容量可能大于slice长度。

### `Heap.takeMediumSuperblock` (`src/core/gc_block_heap.zig:3472`)

- **签名**：`fn takeMediumSuperblock(self: *Heap, pages: u32) ?u32`。
- **作用**：从足够大空闲段的桶中选择一个superblock槽。
- **实现**：从pages桶递增查到medium_bucket_count，首个非nil桶头立即返回；都空则null。
- **所有权 / 错误 / 调用**：不摘桶、不占页或实际查page bitmap；依赖max_free_run桶缓存正确。对合法pages请求探测至多16桶，不是扫描全部superblock。

### `Heap.freeMedium` (`src/core/gc_block_heap.zig:3483`)

- **签名**：`fn freeMedium(self: *Heap, extent: MediumExtent) void`。
- **作用**：清除medium extent占页并更新桶和分配统计。
- **实现**：在所属superblock逐页clearPage，再rebucket；若最大run达到上限且整位图全空，记empty_since_ns=clock_ns；扣extent.user_bytes与live_count。
- **所有权 / 错误 / 调用**：不自行移除medium主表或页索引，Heap.free已在调用前处理；也不立即归还2MiB映射，释放策略另行执行。young列表中旧base由后续遍历容忍。

### `Heap.rebucket` (`src/core/gc_block_heap.zig:3508`)

- **签名**：`fn rebucket(self: *Heap, super_index: u32) void`。
- **作用**：依据页位图刷新medium空闲段缓存和桶归属。
- **实现**：scanFreeRuns(...,0).max_run与当前值相同直接返回，否则bucketUnlink再bucketLink新run。
- **所有权 / 错误 / 调用**：max_run截断至max_medium_pages，并非真实最长页段总长度；不移动extent或修改page_bits。

### `Heap.bucketUnlink` (`src/core/gc_block_heap.zig:3515`)

- **签名**：`fn bucketUnlink(self: *Heap, super_index: u32) void`。
- **作用**：从medium桶双向链摘除一个槽。
- **实现**：bucket取sb.max_free_run；0时断言前后链接nil后返回。非零则保存前后，清自身链接；若为头验证并更新桶头，否则接前驱next；存在后继则更新其prev。
- **所有权 / 错误 / 调用**：不把max_free_run清0，也不验证所有bitmap条件，调用方随后重新link或显式清缓存。不拥有/释放映射。

### `Heap.bucketLink` (`src/core/gc_block_heap.zig:3535`)

- **签名**：`fn bucketLink(self: *Heap, super_index: u32, run: u32) void`。
- **作用**：按run缓存值把medium superblock插到桶头。
- **实现**：断言run<=max_medium_pages、kind为medium且自身链接nil；写max_free_run，run=0返回不入桶；否则设置自身next、旧head.prev并更新head。
- **所有权 / 错误 / 调用**：run由调用方提供而非现场重算；必须先摘旧链，0代表无可用run。

### `Heap.verifyMediumBuckets` (`src/core/gc_block_heap.zig:3561`)

- **签名**：`pub fn verifyMediumBuckets(self: *const Heap) MediumBucketError!void`。
- **作用**：对账medium页位图、最长run缓存与桶链。
- **实现**：要求bucket0为空；逐槽检查非medium的run/链接均空，medium重算截断max_run必须一致并统计应入链者。逐桶检查索引范围、medium kind、run桶号、prev连续性，并以总槽数限制遍历，最后比较实际/预期链接数。
- **所有权 / 错误 / 调用**：返回Stale/Mislinked/Unlinked，不修改状态。验证桶与bitmap关系，不验证每个extent主表项是否恰好对应占页、页索引或真实映射内容，不能作为完整分配正确性证明。

### `Heap.allocLarge` (`src/core/gc_block_heap.zig:3597`)

- **签名**：`fn allocLarge(self: *Heap, n: usize) std.mem.Allocator.Error![]u8`。
- **作用**：按页对齐独立分配large extent并登记。
- **实现**：n向上对齐page_bytes，先增加large_reserves；预留young列表容量后alignedAlloc，errdefer在large.put失败时归还bytes。主表成功后indexExtentPages、append年轻base；按映射bytes.len增加live/committed与large_maps/large_allocs，返回请求n长slice。
- **所有权 / 错误 / 调用**：large_reserves包含失败尝试，OOM不回滚该计数或已增长容量。页fan-out失败不回滚分配而启用线性回退。这里不完成对象prefix/发布；请求取整使用普通算术，调用方须提供合法范围。

### `Ctx.destroy` (`src/core/gc_block_heap.zig:3783`)

- **签名**：`fn destroy(ctx: *anyopaque, base: usize, user_bytes: usize, needs_finalizer: bool) void`。
- **作用**：单元测试里交给 sweepExtents 的销毁回调，记录本次回调参数并把 extent 还给 heap。
- **实现**：把 ctx 还原成测试内 Ctx 指针；freed 加一，记录 last_base/last_bytes/last_needs_finalizer，再 heap.free(@ptrFromInt(base))。
- **所有权 / 错误 / 调用**：兑现 sweepExtents 的回调合同——在回调内归还存储，使主表条目在迭代中被移除（std hash map 删除只就地打墓碑）。不执行真正的对象析构，needs_finalizer 只被记录不被消费。

### `processHeapTrimNeeded` (`src/core/gc_block_heap.zig:3947`)

- **签名**：`pub fn processHeapTrimNeeded(current_decommitted: usize, released: usize) bool`。
- **作用**：用当前未重新提交字节与本批释放量判断是否越过trim阈值。
- **实现**：同时要求released!=0、current_decommitted>=128MiB、current_decommitted -| released<128MiB。
- **所有权 / 错误 / 调用**：纯无状态计算；released若包含不计入current的medium释放，差值不一定代表真实上一时刻current。重复提供相同满足条件输入会重复true，不保证幂等或一次性。

### `popCell` (`src/core/gc_block_heap.zig:3953`)

- **签名**：`fn popCell(block: *Block) ?u32`。
- **作用**：按block当前空闲表示取一个cell索引。
- **实现**：interval模式先消耗bump..interval_end，再从free_list读取区间头的poison/next/end并启用该区间，之后才消费next_free异常返还LIFO；普通模式先pop free_list，否则从bump取尚未发出的cell，耗尽null。
- **所有权 / 错误 / 调用**：仅移动空闲表示，不设置alloc位或generation/lifecycle。链范围和poison依赖安全断言；关闭断言时越界head可落到后续路径并遗失可用cell，不能把返回null解释为所有损坏都已检出。

### `pushCell` (`src/core/gc_block_heap.zig:4010`)

- **签名**：`fn pushCell(block: *Block, index: u32, cell: [*]u8) void`。
- **作用**：把已释放cell压入对应空闲链并写poison链接字。
- **实现**：interval模式断言非hot-listed，用next_free作返还链头；其它模式用free_list；将free_poison与旧头低16位写入cell首u32，再以index更新头。
- **所有权 / 错误 / 调用**：覆盖prefix前四字节，不清整cell，也不改alloc/mark/count；调用方负责已释放状态与合法cell/index。interval返还项不插入有序区间链，避免破坏地址顺序。

### `bitMask` (`src/core/gc_block_heap.zig:4026`)

- **签名**：`fn bitMask(index: u32) u64`。
- **作用**：计算cell索引在一个64位word内的位掩码。
- **实现**：返回u64(1)左移index%64。
- **所有权 / 错误 / 调用**：只含word内位置，不编码index/64，不检查整体bitmap范围。

### `setBitPlain` (`src/core/gc_block_heap.zig:4045`)

- **签名**：`fn setBitPlain(bits: []u64, index: u32) void`。
- **作用**：以普通读改写设置位图中的指定bit。
- **实现**：bits[index/64]按位或1<<(index%64)。
- **所有权 / 错误 / 调用**：非原子，调用方保证索引和串行访问；当前不只用于alloc，还用于finalizer等owner线程位图，不能沿用“仅alloc”的旧注释。

### `clearBitPlain` (`src/core/gc_block_heap.zig:4049`)

- **签名**：`fn clearBitPlain(bits: []u64, index: u32) void`。
- **作用**：以普通读改写清除位图中的指定bit。
- **实现**：bits[index/64]按位与指定掩码的反码。
- **所有权 / 错误 / 调用**：不返回旧值，不自行检查逻辑cell范围；并发同word修改需外部同步。

### `testBitPlain` (`src/core/gc_block_heap.zig:4053`)

- **签名**：`fn testBitPlain(bits: []const u64, index: u32) bool`。
- **作用**：普通读取位图中的一个bit。
- **实现**：读取bits[index/64]并与word内掩码比较非零。
- **所有权 / 错误 / 调用**：非原子查询，不证明cell发布/存活，索引合法性由调用方保证。

### `testBit` (`src/core/gc_block_heap.zig:4057`)

- **签名**：`fn testBit(bits: []const u64, index: u32) bool`。
- **作用**：以monotonic原子读取word后查询bit。
- **实现**：atomicLoad对应u64 word，再与位掩码比较。
- **所有权 / 错误 / 调用**：只保证该word的原子读取，不提供对象字段的acquire发布语义或多word一致快照。

### `setBit` (`src/core/gc_block_heap.zig:4062`)

- **签名**：`fn setBit(bits: []u64, index: u32) void`。
- **作用**：以原子OR设置指定bit。
- **实现**：atomicRmw(.Or,mask,.monotonic)，忽略旧word。
- **所有权 / 错误 / 调用**：防止同word其它bit更新丢失，不返回是否首次置位，也不代替epoch初始化和对象发布同步。

### `clearBit` (`src/core/gc_block_heap.zig:4066`)

- **签名**：`fn clearBit(bits: []u64, index: u32) void`。
- **作用**：以原子AND清除指定bit。
- **实现**：atomicRmw(.And,~mask,.monotonic)，忽略旧word。
- **所有权 / 错误 / 调用**：只修改一个word中的目标位，不改变epoch或其它状态；不是整个collector并行安全的证明。

FreeRunScan 保存 max_run 与可空first：前者截断到max_medium_pages，后者是满足请求长度的最低起始页，want=0时不提供first。返回结果描述当前位图，不拥有或预留任何页。

### `scanFreeRuns` (`src/core/gc_block_heap.zig:4084`)

- **签名**：`fn scanFreeRuns(bits: *const [pages_per_superblock / 64]u64, want: u32) FreeRunScan`。
- **作用**：扫描一个medium superblock页位图，求截断最长空闲段和首个足够长的段起点。
- **实现**：按word处理，以ctz跳过连续0或1段，run跨word保留；遇已用段或word结束更新max_run与首次满足want的first。max_run达到max_medium_pages且want为0或first已找到时可提前结束；最终max_run截断到16。
- **所有权 / 错误 / 调用**：want=0时first始终null，只求截断最大值。返回页索引而非字节地址；无分配/修改。成本与单个512页位图中的段数相关，不依赖heap superblock数，也不意味着每次只读8次word。

### `testPage` (`src/core/gc_block_heap.zig:4119`)

- **签名**：`fn testPage(bits: [pages_per_superblock / 64]u64, page: u32) bool`。
- **作用**：查询固定页位图中的一个占用位。
- **实现**：按page/64取word并检查page%64对应bit。
- **所有权 / 错误 / 调用**：按值接收位图数组，不修改原值；classed索引复用此工具时参数表示block槽，非总是OS页。

### `setPage` (`src/core/gc_block_heap.zig:4123`)

- **签名**：`fn setPage(bits: *[pages_per_superblock / 64]u64, page: u32) void`。
- **作用**：设置固定页位图的指定占用位。
- **实现**：对bits[page/64]执行普通OR。
- **所有权 / 错误 / 调用**：不更新桶/计数或验证可分配范围；medium按页、classed非空索引按block槽解释。

### `clearPage` (`src/core/gc_block_heap.zig:4127`)

- **签名**：`fn clearPage(bits: *[pages_per_superblock / 64]u64, page: u32) void`。
- **作用**：清除固定页位图的指定占用位。
- **实现**：对bits[page/64]执行普通AND反掩码。
- **所有权 / 错误 / 调用**：不归还映射或自动rebucket，不验证旧位是否已占用；调用方负责状态一致性。

## 覆盖核对

- 清单函数数: 190（`src/core/gc_block_heap.zig` 153 + `src/core/gc_carrier.zig` 28 + `src/core/gc_space.zig` 9）
- 本文标题覆盖: 190
- 未覆盖: 无
