# 01 — 公共 API 旁路与内部根

`src/root.zig` 旁边的五个文件：内部编译根、QCP-1 配置签名、布局垫片、GC 表示快照、平台时钟。嵌入方不从这些文件进引擎；CLI 与构建门会碰到它们。

---

## `src/internal_root.zig`

编译根链的中段：`src/root.zig` ⊂ `src/internal_root.zig` ⊂ `src/all_tests.zig`。CLI、scoped tests、ReleaseFast 产物对着这个文件编。文件顶部 `comptime { _ = @import("dossier_pad.zig"); }` 保证垫片编译进内部产物。

### 类型与 re-export

| 名字 | 含义 |
| --- | --- |
| `public_api` | 公共 `root.zig` 模块，用来对照「内部多暴露了什么」。 |
| `native` / `binding_root` | binding 聚合。 |
| `platform_clock` | 单调/墙上时钟。CLI 自己的模块图碰不到 `src/platform_clock.zig`，所以从这里转口。 |
| `RuntimeError` / `HostError` | `exec.exceptions` 的 error set。 |
| `JSRuntime` / `JSContext` / `CallSite` / `PropertySite` / `JSValue` | 与公共门面同一批 binding 类型。 |
| `Object` | **core** `Object`，不是公共 `zjs.object.Object`（后者是 opaque）。文件级 test 断言它等于 `binding_root.Object`、带 `create`，而公共 opaque 类型没有 `create`。 |
| `Descriptor` / `Atom` / `NativePin` / `GCPolicy` / `GCStats` | core 类型；公共 root **不**导出 `Atom` / `NativePin`。 |
| `JSValueHandle` / `LocalHandle` / `HandleScope` / `WeakPersistent` / `WeakPersistentValue` | 句柄族。公共拼写走 `zjs.value.*`。 |
| `PropNameID` / `JSString` / `JSBytes` / `binding` | 内部拼写；公共走 `zjs.host.PropName` / `zjs.value.String`。 |
| `EvalOptions` / `EvalTiming` / `DataPropertyOptions` | 选项类型。 |
| `RuntimeMemoryUsage` | binding_root 转出的 core 内存用量记录，包含账户统计和按类别估算的字节字段。 |
| `core` / `parser` / `simple_token` / `bytecode` / `exec` / `libs` / `runtime` / `compiler` | 整层模块。公共 root 故意没有这些。 |
| `sort_erased` | 类型擦除堆，非嵌入 API。 |
| `config_signature` | CLI `zjs --print-config-signature` 的来源。 |

文件级 `test` 块：确认内部 `Object` 有 `create`，而 `public_api.object.Object` 没有；再把各层模块拉进编译。

### `printSmallInlineProbe` (`src/internal_root.zig:65`)

- **签名**：`pub fn printSmallInlineProbe() void`。
- **作用**：按环境开关输出 small-inline 探测计数，供内部 CLI 使用。
- **实现**：调用 exec.small_inline.printProbe；当前助手仅在 ZJS_INLINE_PROBE 存在且非空时通过 std.debug.print 输出 prep、take 和整数百分比，不将变量内容当作文件路径，也不写独立探测文件。公共 embedder root 不导出此名。
- **所有权 / 错误 / 调用**：本包装只转发，不返回 I/O 错误；是否启用、写往何处及失败处理由 exec 助手决定，不能由这个 void 包装推断所有写入都成功。

---

## `src/config_signature.zig`

QCP-1 配置签名。在调用 `attest("<artifact>")` 的产物中，编译期比较本模块推导的七项配置与构建图传入的期望字符串。组件取自相应引擎声明；签名只覆盖列出的配置，不证明源码、语料、运行时参数或测量过程一致，也不能约束没有调用 attest 的产物。

### 类型与常量

| 名字 | 含义 |
| --- | --- |
| `version` | `"zjs-config-v3"`。组件集或编码变了就 bump，避免旧期望 silently 匹配新含义。v2→v3 加了终端 `gc_layout`。 |
| `component_order` | 固定顺序：`compiler, layout, repr, gc_layout, optimize, force_gc, ownership_audit`。不用 map 迭代，跨平台字符串稳定。 |
| `compiler` | `"v2"`。唯一编译器的身份名，不是目录名。 |
| `layout` | `@tagName(resolve_labels.default_layout)`，生产是 `short`。 |
| `repr` | `@sizeOf(JSValue)==8` 则 `nan_boxed`，否则 `tagged`；按大小分类，不能独立验证所有位编码细节。 |
| `gc_layout` | 同时满足 `@sizeOf(Object)==24`、`bodyOffsetFromHeader(.object)==0`、`slots2_property_storage_offset==24` 时为 `obj64_m`，否则 `unknown`。这是三个布局条件的识别，不是全部 GC 表示的校验。 |
| `optimize` | `@tagName(builtin.mode)`，本模块实际编译模式。 |
| `force_gc` | `core.memory.force_gc_on_allocation_enabled` → `on`/`off`。 |
| `ownership_audit` | `core.atom.ownership_audit_enabled` → `on`/`off`。 |
| `component_values` | 与 `component_order` 对齐的七个值。 |
| `signature` | 拼接后的规范串，例如 `zjs-config-v3:compiler=v2,layout=short,repr=tagged,gc_layout=obj64_m,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。 |
| `expected_config` | `build_options.zjs_expect_config`：构建图认为本产物该是什么。 |
| `Parsed` | 诊断用拆分结果：`version` + `names`/`values` 切片。 |

### `actualEffectiveConfig` (`src/config_signature.zig:162`)

- **签名**：`pub fn actualEffectiveConfig() []const u8`。
- **作用**：返回本编译实际消费的配置串，写成函数是为了让 `assertExpectedConfig` 比较「两件独立事实」。
- **实现**：`return signature;`。
- **所有权 / 错误 / 调用**：comptime 字符串，无分配。`attest` 与单元测试调用。

### `assertExpectedConfig` (`src/config_signature.zig:181`)

- **签名**：`pub fn assertExpectedConfig( comptime artifact: []const u8, comptime actual: []const u8, comptime expect: []const u8, ) void`。
- **作用**：本函数被编译求值时，actual 与 expect 的完整字节串不相等就触发 @compileError。
- **实现**：`comptime` 里 `std.mem.eql`；不等则拼消息：artifact / expected / actual / `differingFields`。故意编译期断言：运行时检查只覆盖有人记得跑的路径。
- **所有权 / 错误 / 调用**：不做规范化或字段集合等价比较，字段重排也失败；相等的两串即使不是合法签名也直接通过。artifact 只用于诊断标签，不验证产物身份。

### `attest` (`src/config_signature.zig:200`)

- **签名**：`pub fn attest(comptime artifact: []const u8) void`。
- **作用**：每个带引擎产物的那一次调用：`comptime { config_signature.attest("<artifact>"); }`。
- **实现**：`assertExpectedConfig(artifact, actualEffectiveConfig(), expected_config)`。
- **所有权 / 错误 / 调用**：不自动枚举其他构建产物，不验证运行时配置或打印签名；它保障的是调用处实际纳入比较的两串一致。

### `Parsed.find` (`src/config_signature.zig:209`)

- **签名**：`fn find(comptime self: Parsed, comptime name: []const u8) ?[]const u8`。
- **作用**：在已拆开的签名里按组件名找值。
- **实现**：并行扫 `names`/`values`，`std.mem.eql` 命中即返回。
- **所有权 / 错误 / 调用**：comptime 返回借用值切片；重复字段名取第一次匹配，不报告重复。未知名称返回 null，空值则返回非 null 的空切片。

### `parseSignature` (`src/config_signature.zig:220`)

- **签名**：`fn parseSignature(comptime text: []const u8) Parsed`。
- **作用**：把 `<version>:<name>=<value>,...` 拆开，只为诊断。输入已经知道是错的，畸形期望也要能读。
- **实现**：`@setEvalBranchQuota(10_000)`。没有 `:` 则整串当 version、空字段表。否则按 `,` 切字段、按 `=` 切名/值；没有 `=` 则值空串。
- **所有权 / 错误 / 调用**：只用第一个冒号、各字段第一个等号分割；不 trim、不校验版本/组件名、不去重。连续逗号可产生空名称字段，尾逗号不再追加一个空字段。值和名称切片借用编译期输入，不能把该诊断解析器当作严格签名验证器。

### `differingFields` (`src/config_signature.zig:240`)

- **签名**：`fn differingFields(comptime actual: []const u8, comptime expect: []const u8) []const u8`。
- **作用**：生成「哪些字段不同」的多行文本，挂在 `@compileError` 上。
- **实现**：两边 `parseSignature`。先比 version，再扫 actual 的每个名（缺 → `<field absent>`，值不同 → expected/actual），再扫 expect 里 actual 没有的名。若字符串不等但字段全同，落到「拼写或字段顺序」那一行。
- **所有权 / 错误 / 调用**：只是编译期诊断文本，是否拒绝由上层完整字符串比较决定。重复字段名按 find 的首次匹配规则比较；最后的 spelling/field order 提示只表示没有生成字段差异，不证明畸形签名仅有字段顺序问题。

---

## `src/dossier_pad.zig`

用于布局归因实验的代码垫片。非零 zjs_dossier_layout_pad 生成相应数量的导出函数，供观察代码放置变化；零值不生成这些函数。仅凭源码分支不能证明整个二进制与删除该模块后逐字节相同。

### 类型与常量

| 名字 | 含义 |
| --- | --- |
| `pad_slots` | `build_options.zjs_dossier_layout_pad`。槽数。 |
| `pad_section` | 按 target.ofmt 选择：ELF 为 `.text.zjs.layout_pad`，Mach-O 为 `__TEXT,__text`，其它为 `.text`。最终排序、保留及 handler 地址移动还取决于链接配置。 |

`comptime` 块：`pad_slots != 0` 时为每个槽生成一个 `Slot`，`@export` 成 `zjs_dossier_pad_{d}`。

### `Slot.body` (`src/dossier_pad.zig:35`)

- **签名**：`fn body(seed: u64) linksection(pad_section) callconv(.c) u64`。
- **作用**：为各槽生成含槽编号常量的导出函数，以产生不同的代码内容；具体机器码大小和链接行为由工具链决定。
- **实现**：`acc = seed ^ (slot *% golden_ratio)`，再 8 轮 `*%` / `+%` / `^= acc >> 29`，返回 `acc`。`slot` 编进常量，各槽不同。
- **所有权 / 错误 / 调用**：只做 u64 环绕运算，不访问堆或自动执行。生成与否仅取决于 pad_slots；非零时导出名字并不意味着程序运行时会调用这些函数。每个槽的字节大小不是固定承诺。

---

## `src/gc_representation.zig`

GC/对象表示的确定性快照。**工具/测试模块，不是引擎依赖**。生产期守卫仍挨着各自 struct；本模块把同一批事实收成文本，表示工作有显式 diff。`snapshot_text` 由 `zig build gc-representation-snapshot` 生成基线。

### 类型与数据

`pub const snapshot_text` 是编译期拼接的 v1 文本，包含 `[prefix]`、`[field-semantics]`、`[kind-contracts]` 和 `[body-layouts]`。kind 部分显式列出 object、function_bytecode、var_ref、realm_context、module、shape、string、big_int、property_storage、array_storage、payload、rope、string_buffer；不是自动枚举整个 GcKind，因此将来新增 kind 不会自动加入文本。

快照混合两类信息：`@sizeOf` / `@alignOf` / `@offsetOf` 等从当前目标类型推导的值，以及固定标签、位语义和数字字面量。`release_slots2_body=56`、`release_physical=64`、`trace_rc=2164`、`list_prev=2168` 都不会自行跟随实现变化；其中旧 `trace_rc` 文本不能证明当前 Context 仍采用引用计数。`registry=yes` 也固定写在格式串中。基线匹配只证明文本相同，不自动证明这些固定描述符合实现。

### `kindContract` (`src/gc_representation.zig:12`)

- **签名**：`fn kindContract(comptime kind: gc.GcKind) []const u8`。
- **作用**：一行 kind 合同：名字、tag 整数、allocation 族、`registry=yes`。
- **实现**：`gc.representationKindDescriptor(kind)` + `comptimePrint`。
- **所有权 / 错误 / 调用**：kind 名称、tag 和 allocation 来自声明/descriptor；registry=yes 是无条件字面量，未从 descriptor 中查询。返回编译期字符串，不遍历运行时登记表。

### `objectLayout` (`src/gc_representation.zig:24`)

- **签名**：`fn objectLayout() []const u8`。
- **作用**：Object 头/对齐/flags/class_id/shape/prop_values/slots2/物理尺寸/arm 宽窄。
- **实现**：`@sizeOf` / `@offsetOf` / `gc.bodyOffsetFromHeader(.object)` / `Object.objectBodyBytes` / `arm_min_bytes` / `arm_max_bytes`。含字面 `release_slots2_body=56 release_physical=64`。
- **所有权 / 错误 / 调用**：comptime；`snapshot_text` 的 `[body-layouts]`。

### `functionBytecodeLayout` (`src/gc_representation.zig:31`)

- **签名**：`fn functionBytecodeLayout() []const u8`。
- **作用**：FunctionBytecode 的大小、对齐与 header/js_mode/byte_code/byte_code_len/vardefs/closure_var/realm/cpool 字段偏移。
- **实现**：`@sizeOf` / `@alignOf` / `@offsetOf`。
- **所有权 / 错误 / 调用**：不分配：返回 `comptimePrint` 生成的编译期字符串常量，调用方不释放；无 error set，字段改名会在编译期 `@offsetOf` 失败而不是运行期报错。唯一调用方是本文件 `snapshot_text`（`src/gc_representation.zig:170`），经 `build/tests.zig:228` 的 `gc-representation-snapshot` 与 `src/tests/core.zig:67` 的 baseline 比对消费。

### `varRefLayout` (`src/gc_representation.zig:38`)

- **签名**：`fn varRefLayout() []const u8`。
- **作用**：`VarRef` 尺寸与 header/value/pvalue/is_const/is_open 偏移。
- **实现**：同上。
- **所有权 / 错误 / 调用**：同 `functionBytecodeLayout`：编译期常量字符串，无分配、无 error set；唯一调用方 `snapshot_text`（`src/gc_representation.zig:171`）。

### `realmLayout` (`src/gc_representation.zig:45`)

- **签名**：`fn realmLayout() []const u8`。
- **作用**：`JSContext`（realm）尺寸与 header/runtime/publication_state/modules/global 偏移；文本里钉 `trace_rc=2164 list_prev=2168`。
- **实现**：前部大小、对齐和列出的真实字段偏移由类型查询生成；末尾 trace_rc/list_prev 两个数值直接写在格式串中，没有 @offsetOf 验证。
- **所有权 / 错误 / 调用**：编译期常量字符串，无分配、无 error set；唯一调用方 `snapshot_text`（`src/gc_representation.zig:172`）。注意 `trace_rc` / `list_prev` 两个数是硬写的字面量，字段移动时编译不会报错，只会让 baseline diff 变成假阴性。

### `moduleLayout` (`src/gc_representation.zig:52`)

- **签名**：`fn moduleLayout() []const u8`。
- **作用**：ModuleRecord 的大小、对齐与 header/registry_prev/registry/memory/module_name/requests/func_obj/module_ns 字段偏移。
- **实现**：`@offsetOf` 一组。
- **所有权 / 错误 / 调用**：同族：编译期常量字符串，无分配、无 error set；唯一调用方 `snapshot_text`（`src/gc_representation.zig:173`）。

### `shapeLayout` (`src/gc_representation.zig:59`)

- **签名**：`fn shapeLayout() []const u8`。
- **作用**：`Shape` 尺寸与 header/list_prev/ownership/hash/prop_hash_mask/prop_size/prop_count/registry_hash_next/proto/identity；`fam` 用 `@sizeOf(Shape)`。
- **实现**：`list_prev` 实际字段是 `trace_list_previous`。
- **所有权 / 错误 / 调用**：同族：编译期常量字符串，无分配、无 error set；唯一调用方 `snapshot_text`（`src/gc_representation.zig:174`）。

### `stringLayouts` (`src/gc_representation.zig:66`)

- **签名**：`fn stringLayouts() []const u8`。
- **作用**：flat string / rope / rope tail / string_buffer 四行布局。
- **实现**：两次 `comptimePrint` 拼接：`String` 的 len/hash/atom；`StringRope` 的 left/right/rt/len/depth/wide/extensible/buffer；`StringBuffer` 的 capacity/is_wide/`units_offset`。
- **所有权 / 错误 / 调用**：两段 `comptimePrint` 在编译期用 `++` 拼接，结果仍是静态常量，无运行期分配、无 error set；唯一调用方 `snapshot_text`（`src/gc_representation.zig:175`）。

### `bigIntLayout` (`src/gc_representation.zig:87`)

- **签名**：`fn bigIntLayout() []const u8`。
- **作用**：堆 `BigInt` 尺寸与 header/limbs_ptr/allocator/len/capacity/flags。
- **实现**：由 BigInt 类型查询大小、对齐及各字段偏移，fam 输出 @sizeOf(BigInt)，不等于当前某个实例所分配的 limbs 容量或总字节数。
- **所有权 / 错误 / 调用**：同族：编译期常量字符串，无分配、无 error set；唯一调用方 `snapshot_text`（`src/gc_representation.zig:176`）。

### `metadataLayout` (`src/gc_representation.zig:94`)

- **签名**：`fn metadataLayout() []const u8`。
- **作用**：`gc.Metadata` 尺寸与 size_class/alloc_info/flags/lifetime 偏移。
- **实现**：`@offsetOf`。
- **所有权 / 错误 / 调用**：comptime；`[prefix]` 第一行。

### `activeHeaderLayout` (`src/gc_representation.zig:108`)

- **签名**：`fn activeHeaderLayout() []const u8`。
- **作用**：`TraceHeader` 尺寸与 `next_non_object` 偏移。
- **实现**：`@sizeOf` / `@offsetOf`。
- **所有权 / 错误 / 调用**：编译期常量字符串，无分配、无 error set；唯一调用方 `snapshot_text` 的 `[prefix]` 段（`src/gc_representation.zig:126`），紧跟 `metadataLayout` 之后。

### `lifetimeSemantics` (`src/gc_representation.zig:115`)

- **签名**：`fn lifetimeSemantics() []const u8`。
- **作用**：用固定英文句子描述 lifetime 字的位语义（mark_epoch / object_shape_summary / remembered / reserved），以及 epoch 0 / 0xffff 的含义。
- **实现**：两个字符串字面量 `++`。
- **所有权 / 错误 / 调用**：固定文本，不读取实例、字段位偏移或当前 mark epoch；这部分语义变更须人工同步，快照生成不会自动发现描述过期。

### `matchesBaseline` (`src/gc_representation.zig:178`)

- **签名**：`pub fn matchesBaseline(baseline: []const u8) bool`。
- **作用**：比较调用方传入的 baseline 字节切片与当前编译 snapshot_text 是否完全相同。
- **实现**：`std.mem.eql(u8, baseline, snapshot_text)`。
- **所有权 / 错误 / 调用**：不读磁盘、不写或更新基线，不解析字段、忽略空白或生成差异说明；任何字节差异都返回 false。无分配，比较成本随输入长度和内容而变；基线修改的评审要求不是此函数执行的检查。

---

## `src/platform_clock.zig`

跨平台单调钟 / 墙上钟。CLI 根模块到不了这个文件（`zjs.zig` 曾内联一份 `monotonicNanos`），内部根把它转口出去。

### `io` (`src/platform_clock.zig:3`)

- **签名**：`fn io() std.Io`。
- **作用**：拿到全局单线程 `std.Io`，给 Timestamp API 用。
- **实现**：`return std.Io.Threaded.global_single_threaded.io();`
- **所有权 / 错误 / 调用**：返回全局 Io 实例的接口值，不创建或销毁独立事件循环；两个读钟入口直接使用它，elapsedNanosSince 经 monotonicNanos 间接使用。

### `monotonicNanos` (`src/platform_clock.zig:10`)

- **签名**：`pub fn monotonicNanos() u64`。
- **作用**：读取 std.Io 的 awake 时钟，供诊断及同一时钟域的耗时计算；不是 Unix 时间戳。
- **实现**：`Timestamp.now(io(), .awake).raw.toNanoseconds()`；`<= 0` 则 0，否则 `@intCast`。
- **所有权 / 错误 / 调用**：本包装没有显式分配或可恢复错误返回；非正读数钳为 0。正值转为 u64 没有上界饱和分支，不能把它描述为所有溢出都自动钳位。

### `elapsedNanosSince` (`src/platform_clock.zig:18`)

- **签名**：`pub fn elapsedNanosSince(start: u64) u64`。
- **作用**：用当前 awake 时钟纳秒值与 start 计算非负时间差。
- **实现**：`end = monotonicNanos()`；`end > start` 则相减否则 0。
- **所有权 / 错误 / 调用**：start 应来自同一时钟域；相等或 end 小于 start 都返回 0，不报告时钟异常。不等待指定时间，不可混用 realtimeMicros 的墙钟值。

### `realtimeMicros` (`src/platform_clock.zig:24`)

- **签名**：`pub fn realtimeMicros() i64`。
- **作用**：Unix epoch 以来的墙上微秒。
- **实现**：`Timestamp.now(io(), .real).raw.toMicroseconds()`。
- **所有权 / 错误 / 调用**：返回有符号墙钟值，不钳为正数、不保证单调或每次唯一，也没有失败回退到 1 的逻辑；Runtime 的随机种子包装另行处理零值。不宜用来替代 awake 时钟计算运行耗时。
