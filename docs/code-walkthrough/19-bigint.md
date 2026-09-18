# 19 — `src/libs/bigint.zig`

分配器拥有的符号-幅度算术。limb 是 `u64`，上限对齐 qjs `JS_BIGINT_MAX_SIZE`：`max_bits = 1024*1024`，`max_limbs = 16384`。输入一律借用；结果由调用方 `deinit`。零值是空 slice，不占 heap。

表示与 QuickJS 不同：qjs `JSBigInt` 是带符号扩展的二进制补码；zjs 是规范化符号-幅度（无前导零、零的 `negative=false`）。除法镜像的是 `mp_divnorm` 机制，不是补码的「最高商位只能是 0/1」。

`core/bigint.zig` 把本库值迁进 GC 对象（外部分配或 FAM 内联）。`JSValue` 的 short bigint（tag 7、payload 即 i64）从不经过本文件；放不下才 `fromIntAlloc` + 堆包装。见 [19-libs.md](19-libs.md)。

## 类型

| 符号 | 含义 |
| --- | --- |
| `Limb` | `u64` |
| `DoubleLimb` | `u128`，乘加进位 |
| `BigInt` | `{ negative, limbs: []Limb, allocator }`；`limbs` 小端 |
| `DivOutput` | `.quotient` / `.remainder` / `.both`，避免为扔掉的一半再分配 |
| `test_only` | 仅测试：`resetDigitIterations` / `digitIterations`，数长除法商位循环 |

错误：`error.BigIntTooLarge`（超 1M bit）、`error.DivisionByZero`、`error.NegativeExponent`、`error.InvalidRadix`、`error.InvalidBigInt`，以及 allocator OOM。

### `test_only.resetDigitIterations` (`src/libs/bigint.zig:19`)

- **签名**：`pub fn resetDigitIterations() void`。
- **作用**：把线程局部的长除法商位计数清零，给 OOM/复杂度测试当基线。
- **实现**：写 `TestDigits.count = 0`。非测试构建里 `test_only` 是空 struct。
- **所有权 / 错误 / 调用**：无分配。`divRemAbsNormalizedLong` 每个商位 `count += 1`。

### `test_only.digitIterations` (`src/libs/bigint.zig:22`)

- **签名**：`pub fn digitIterations() u64`。
- **作用**：读出自上次 reset 以来规范化长除法走了多少个商位。
- **实现**：返回 `TestDigits.count`。
- **所有权 / 错误 / 调用**：只读。测试断言用。

### `checkLimbCount` (`src/libs/bigint.zig:29`)

- **签名**：`fn checkLimbCount(len: usize) error{BigIntTooLarge}!void`。
- **作用**：在「新鲜结果分配」卡口镜像 `js_bigint_new`（quickjs.c:11592-11596）。
- **实现**：`len > max_limbs` 则 `error.BigIntTooLarge`。
- **所有权 / 错误 / 调用**：`bitwise`、`pow2`、`mulAlloc`、`parseBaseAlloc` 在 `alloc` 前调用（`shl` 不走本函数，自己按 `max_bits` 位宽判）。加法在 normalize 之后再查，避免 64-bit 符号-幅度比 qjs 32-bit limb 早一档抛错。

### `BigInt.fromInt` (`src/libs/bigint.zig:38`)

- **签名**：`pub fn fromInt(allocator: std.mem.Allocator, value: i128) !BigInt`。
- **作用**：从有符号整数造库 bigint。
- **实现**：直接转 `fromIntAlloc`。
- **所有权 / 错误 / 调用**：结果 owned。`i128` 最多 2 limb，不会 `BigIntTooLarge`。

### `BigInt.fromIntAlloc` (`src/libs/bigint.zig:42`)

- **签名**：`pub fn fromIntAlloc(allocator: std.mem.Allocator, value: i128) !BigInt`。
- **作用**：把 i128 拆成小端 limb。
- **实现**：0 返回空 limbs。否则取绝对值，循环 `tmp[len] = truncate(magnitude); magnitude >>= 64`，再 `alloc`+`memcpy`。符号位单独存。
- **所有权 / 错误 / 调用**：失败不泄漏。`fromInt`、`pow` 的 ±1 捷径、`bitNot` 的 1、除法修正都走这里。

### `BigInt.deinit` (`src/libs/bigint.zig:57`)

- **签名**：`pub fn deinit(self: *BigInt) void`。
- **作用**：释放 limb 并把对象收成空值。
- **实现**：`limbs.len != 0` 才 `free`；然后 `self.* = .{ .allocator = self.allocator }`（保留 allocator，负号清掉）。
- **所有权 / 错误 / 调用**：空 slice 是 no-op。GC 内联视图**禁止**调用。

### `BigInt.clone` (`src/libs/bigint.zig:62`)

- **签名**：`pub fn clone(self: BigInt) !BigInt`。
- **作用**：用同一 allocator 深拷贝。
- **实现**：`cloneWithAllocator(self.allocator)`。
- **所有权 / 错误 / 调用**：原值借用，新值 owned。

### `BigInt.cloneWithAllocator` (`src/libs/bigint.zig:66`)

- **签名**：`pub fn cloneWithAllocator(self: BigInt, allocator: std.mem.Allocator) !BigInt`。
- **作用**：换 allocator 拷贝（runtime accounted allocator 迁移）。
- **实现**：空值只带新 allocator。否则 `alloc`+`memcpy`，保留 `negative`。
- **所有权 / 错误 / 调用**：`core/bigint.createFromOwnedReserved` 在 allocator 不一致时走这条。

### `BigInt.isZero` (`src/libs/bigint.zig:73`)

- **签名**：`pub fn isZero(self: BigInt) bool`。
- **作用**：规范化零检测。
- **实现**：`limbs.len == 0`。
- **所有权 / 错误 / 调用**：无。加减乘除的捷径都先看它。

### `BigInt.add` (`src/libs/bigint.zig:77`)

- **签名**：`pub fn add(self: BigInt, other: BigInt) !BigInt`。
- **作用**：`self` 的 allocator 上做加法。
- **实现**：`addAlloc(self.allocator, self, other)`。
- **所有权 / 错误 / 调用**：操作数借用。可能 `BigIntTooLarge`。

### `BigInt.sub` (`src/libs/bigint.zig:81`)

- **签名**：`pub fn sub(self: BigInt, other: BigInt) !BigInt`。
- **作用**：减法。
- **实现**：`subAlloc`。
- **所有权 / 错误 / 调用**：同 `add`。

### `BigInt.mul` (`src/libs/bigint.zig:85`)

- **签名**：`pub fn mul(self: BigInt, other: BigInt) !BigInt`。
- **作用**：乘法。
- **实现**：`mulAlloc`。
- **所有权 / 错误 / 调用**：结果长度 `lhs.len+rhs.len`，先 `checkLimbCount`。

### `BigInt.div` (`src/libs/bigint.zig:89`)

- **签名**：`pub fn div(self: BigInt, other: BigInt) !BigInt`。
- **作用**：向零截断的商（JS BigInt `/`）。
- **实现**：除零立刻 `DivisionByZero`。`divRemAllocOutput(..., .quotient)`，丢掉余数（`deinit` 空值是 no-op）。
- **所有权 / 错误 / 调用**：符号：`lhs.negative != rhs.negative` 且商非零。

### `BigInt.rem` (`src/libs/bigint.zig:99`)

- **签名**：`pub fn rem(self: BigInt, other: BigInt) !BigInt`。
- **作用**：余数，符号跟被除数（JS `%`）。
- **实现**：`.remainder` 模式，丢掉商。
- **所有权 / 错误 / 调用**：同 `div`。

### `BigInt.compare` (`src/libs/bigint.zig:107`)

- **签名**：`pub fn compare(self: BigInt, other: BigInt) std.math.Order`。
- **作用**：带符号比较。
- **实现**：`compareParts`。
- **所有权 / 错误 / 调用**：两个 `BigInt` 都按值接收但只读 `limbs` 切片，不复制也不释放——所有权留在调用方（`src/exec/value_ops.zig:107,115,121,147` 一律是自己 `defer deinit` 的临时量）。不分配、无 error，返回 `std.math.Order` 标量。

### `BigInt.formatBase10Alloc` (`src/libs/bigint.zig:111`)

- **签名**：`pub fn formatBase10Alloc(self: BigInt, allocator: std.mem.Allocator) ![]u8`。
- **作用**：十进制字符串。
- **实现**：`formatBaseAlloc(allocator, 10)`。
- **所有权 / 错误 / 调用**：调用方 `free` 返回切片。

### `BigInt.formatBaseAlloc` (`src/libs/bigint.zig:115`)

- **签名**：`pub fn formatBaseAlloc(self: BigInt, allocator: std.mem.Allocator, base: u8) ![]u8`。
- **作用**：radix 2–36 格式化。
- **实现**：非法 radix → `InvalidRadix`。零写 `"0"`。否则绝对值克隆，负号先写入。base 10：反复 `divRemSmallInPlace(10^19)` 攒 19 位块，最高块不补零。其它 radix：反复除 `base`，digit 倒序。
- **所有权 / 错误 / 调用**：`ArrayList` `errdefer` 释放。`bufPrint` 失败标 `unreachable`（u64 最多 20 位）。

### `BigInt.pow` (`src/libs/bigint.zig:164`)

- **签名**：`pub fn pow(self: BigInt, exponent: BigInt, allocator: std.mem.Allocator) !BigInt`。
- **作用**：`self ** exponent`，镜像 `js_bigint_pow`（quickjs.c:12118-12150）。
- **实现**：负指数 `NegativeExponent`。`e=0 → 1`，`0^e → 0`，`|a|=1` 按指数奇偶得 ±1——这些在宽度检查前就算完。其它：指数必须 `toUsize`，否则 `BigIntTooLarge`。2 的幂底用 `pow2(e*n)` 直建。否则平方-乘，每步 `mulAlloc`（连带 1M-bit 帽）。
- **所有权 / 错误 / 调用**：`errdefer result.deinit`；中间 `base_value` `defer deinit`。

### `BigInt.bitNot` (`src/libs/bigint.zig:209`)

- **签名**：`pub fn bitNot(self: BigInt, allocator: std.mem.Allocator) !BigInt`。
- **作用**：按位取反：`~(x) = -(x+1)`。
- **实现**：`fromInt(1)`，`addAlloc`，再 `subAlloc(0, plus_one)`。
- **所有权 / 错误 / 调用**：临时 `one`/`plus_one` defer 释放。

### `BigInt.bitwise` (`src/libs/bigint.zig:218`)

- **签名**：`pub fn bitwise(self: BigInt, other: BigInt, allocator: std.mem.Allocator, op: enum { @"and", @"or", xor }) !BigInt`。
- **作用**：按位 and/or/xor，语义是二进制补码（JS BigInt）。
- **实现**：宽度 = max(bitlen)+1，先 `checkLimbCount`。两边 `toTwosComplement`，按 `op` 逐 limb，再 `fromTwosComplement`。
- **所有权 / 错误 / 调用**：补码缓冲 defer `free`。

### `BigInt.shl` (`src/libs/bigint.zig:238`)

- **签名**：`pub fn shl(self: BigInt, allocator: std.mem.Allocator, shift: usize) !BigInt`。
- **作用**：左移，结果 bit 长 ≤ `max_bits`。
- **实现**：零原样。`shift >= max_bits` 或 `bitLengthAbs()+shift > max_bits` → `BigIntTooLarge`（避免 usize 溢出）。limb/bit 拆开，进位用 `DoubleLimb`，多余 1 limb 收顶 carry，`normalize`。
- **所有权 / 错误 / 调用**：对应 `js_bigint_shl`（quickjs.c:12049）。

### `BigInt.shr` (`src/libs/bigint.zig:261`)

- **签名**：`pub fn shr(self: BigInt, allocator: std.mem.Allocator, shift: usize) !BigInt`。
- **作用**：算术右移：负值向 −∞（除以 2^shift 再 floor）。
- **实现**：零原样。`shift/64 >= len` 直接 `fromIntAlloc(0 或 −1)`，不进除法路径（qjs:12078）。正数 `shrAbs`。负数：`|a| / 2^shift`，有余数则商 +1，再取负。
- **所有权 / 错误 / 调用**：临时绝对值、`pow2`、余数 defer 释放。

### `BigInt.toUsize` (`src/libs/bigint.zig:289`)

- **签名**：`pub fn toUsize(self: BigInt) ?usize`。
- **作用**：非负且单 limb 才转 usize。
- **实现**：负或 `len>1` → null；空 → 0；否则 `limbs[0]`。
- **所有权 / 错误 / 调用**：`pow` 读指数。64-bit 上 usize 即 u64。

### `BigInt.toI64` (`src/libs/bigint.zig:295`)

- **签名**：`pub fn toI64(self: BigInt) ?i64`。
- **作用**：能放进 i64 才转换，含 `i64::MIN`。
- **实现**：零 → 0；`len>1` → null。负：magnitude>`1<<63` null，`==1<<63` 得 minInt，否则取负。正：`>=1<<63` null。
- **所有权 / 错误 / 调用**：`JSValue.asInt64` 对堆 bigint 造非拥有视图再调这里。

### `BigInt.toU64` (`src/libs/bigint.zig:309`)

- **签名**：`pub fn toU64(self: BigInt) ?u64`。
- **作用**：非负且 ≤ 2^64−1。
- **实现**：负非零或 `len>1` → null。接受 `2^63 .. 2^64-1`（`toI64` 拒绝的那段）。
- **所有权 / 错误 / 调用**：不能实现成 `asInt64` 的包装。`JSValue.asUint64` 用它。

### `BigInt.bitLengthAbs` (`src/libs/bigint.zig:318`)

- **签名**：`pub fn bitLengthAbs(self: BigInt) usize`。
- **作用**：`|self|` 的位宽。
- **实现**：空 0；否则 `(len-1)*64 + (64-clz(top))`。
- **所有权 / 错误 / 调用**：`pow`、`shl` 帽、`bitwise` 宽度。

### `BigInt.isPowerOfTwoAbs` (`src/libs/bigint.zig:326`)

- **签名**：`pub fn isPowerOfTwoAbs(self: BigInt) bool`。
- **作用**：绝对值是否恰好一 bit；零否。
- **实现**：顶 limb `(v&(v-1))==0`，更低 limb 全 0。对齐 qjs `js_bigint_pow`。
- **所有权 / 错误 / 调用**：`pow` 的 2^n 捷径。

### `BigInt.modPowerOfTwo` (`src/libs/bigint.zig:336`)

- **签名**：`pub fn modPowerOfTwo(self: BigInt, allocator: std.mem.Allocator, bits: usize) !BigInt`。
- **作用**：`self mod 2^bits`，负输入给出正剩余。
- **实现**：`bits==0` 或零 → 空。`lowBits` 截低位；正或余数为 0 直接返回。否则 `2^bits - residue`。
- **所有权 / 错误 / 调用**：`BigInt.asUintN` / `asIntN` 用。`pow2` 可能 `BigIntTooLarge`。

### `BigInt.testBit` (`src/libs/bigint.zig:350`)

- **签名**：`pub fn testBit(self: BigInt, bit: usize) bool`。
- **作用**：测绝对值第 `bit` 位。
- **实现**：limb 越界 false；否则 `(limbs[i] >> off) & 1`。
- **所有权 / 错误 / 调用**：`pow` 判断 ±1 的指数奇偶。

### `BigInt.lowBits` (`src/libs/bigint.zig:357`)

- **签名**：`pub fn lowBits(self: BigInt, allocator: std.mem.Allocator, bits: usize) !BigInt`。
- **作用**：拷低 `bits` 位，符号清掉。
- **实现**：需要的 limb 数与 `len` 取 min，顶 limb 掩码，`normalize`。
- **所有权 / 错误 / 调用**：`modPowerOfTwo` 调用。

### `BigInt.addPositiveSmallInPlace` (`src/libs/bigint.zig:372`)

- **签名**：`pub fn addPositiveSmallInPlace(self: *BigInt, addend: Limb) !void`。
- **作用**：原地给非负 bigint 加一个 limb。
- **实现**：`assert(!negative)` 后 `addSmallInPlace`。
- **所有权 / 错误 / 调用**：可能 realloc。`exec/value_ops.addPositiveShortToBigInt` 给非负堆 bigint 加小正数时用。

### `BigInt.absCloneWithAllocator` (`src/libs/bigint.zig:377`)

- **签名**：`fn absCloneWithAllocator(self: BigInt, allocator: std.mem.Allocator) !BigInt`。
- **作用**：绝对值克隆。
- **实现**：clone 后 `negative = false`。
- **所有权 / 错误 / 调用**：格式化、负右移。

### `BigInt.divRemSmallInPlace` (`src/libs/bigint.zig:383`)

- **签名**：`fn divRemSmallInPlace(self: *BigInt, divisor: Limb) !Limb`。
- **作用**：原地除以单 limb，返回余数。
- **实现**：高到低 `(remainder<<64 | limb) / divisor`。然后所有权移交 `normalize`（`const owned = self.*; self.* = empty` 的交接防止 errdefer 双重释放）。
- **所有权 / 错误 / 调用**：`formatBaseAlloc`。`divisor==0` 未防御（调用方保证）。

### `BigInt.shrAbs` (`src/libs/bigint.zig:398`)

- **签名**：`fn shrAbs(self: BigInt, allocator: std.mem.Allocator, shift: usize) !BigInt`。
- **作用**：正数逻辑右移。
- **实现**：整 limb 丢掉；bit 移把相邻 limb 拼起来。结果 `negative=false`。
- **所有权 / 错误 / 调用**：仅 `shr` 的正数臂。

### `BigInt.toTwosComplement` (`src/libs/bigint.zig:417`)

- **签名**：`fn toTwosComplement(self: BigInt, allocator: std.mem.Allocator, limb_count: usize) ![]Limb`。
- **作用**：把符号-幅度写成定宽补码。
- **实现**：拷到 `limb_count` 缓冲。若负：逐 limb `~` 再加 1。
- **所有权 / 错误 / 调用**：返回切片调用方 `free`。`bitwise` 用。

### `divRemAlloc` (`src/libs/bigint.zig:436`)

- **签名**：`pub fn divRemAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !struct { BigInt, BigInt }`。
- **作用**：同时要商和余。
- **实现**：`divRemAllocOutput(..., .both)`。
- **所有权 / 错误 / 调用**：两个结果都 owned。

### `divRemAllocOutput` (`src/libs/bigint.zig:440`)

- **签名**：`fn divRemAllocOutput( allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt, want: DivOutput, ) !struct { BigInt, BigInt }`。
- **作用**：带符号除法的外壳：借绝对值，调 `divRemAbsAlloc`，再贴符号。
- **实现**：除零先拒。不克隆操作数（`divRemAbsAlloc` 只读；OOM sweep 断言操作数字节不变）。商符号异号，余数跟被除数。
- **所有权 / 错误 / 调用**：`div`/`rem`/`divRemAlloc`。未请求的一半可能是空 bigint。

### `parseBase10` (`src/libs/bigint.zig:468`)

- **签名**：`pub fn parseBase10(allocator: std.mem.Allocator, bytes: []const u8) !BigInt`。
- **作用**：解析十进制文本。
- **实现**：`parseBase10Alloc`。
- **所有权 / 错误 / 调用**：`InvalidBigInt` / `BigIntTooLarge`。

### `parseBase10Alloc` (`src/libs/bigint.zig:472`)

- **签名**：`pub fn parseBase10Alloc(allocator: std.mem.Allocator, bytes: []const u8) !BigInt`。
- **作用**：同上，显式 Alloc 后缀。
- **实现**：`parseBaseAlloc(..., 10)`。
- **所有权 / 错误 / 调用**：库内 `parseBase10` 与测试使用；JS 字面量走 `parseAutoAlloc`。

### `parseAutoAlloc` (`src/libs/bigint.zig:476`)

- **签名**：`pub fn parseAutoAlloc(allocator: std.mem.Allocator, bytes: []const u8) !BigInt`。
- **作用**：识别 `0x`/`0o`/`0b` 前缀。
- **实现**：trim 空白；前缀大小写不敏感；否则十进制。
- **所有权 / 错误 / 调用**：不处理 `0n` 后缀（那是 parser）。

### `pow2` (`src/libs/bigint.zig:490`)

- **签名**：`pub fn pow2(allocator: std.mem.Allocator, bits: usize) !BigInt`。
- **作用**：构造 `2^bits`。
- **实现**：`checkLimbCount(limb_index+1)`，全零缓冲，目标位置写 `1<<offset`。注释：挡住 `BigInt.asUintN(2**32, -1n)` 挂起。
- **所有权 / 错误 / 调用**：`pow`、`shr`、`modPowerOfTwo`。

### `compareParts` (`src/libs/bigint.zig:503`)

- **签名**：`pub fn compareParts(lhs_negative: bool, lhs_limbs: []const Limb, rhs_negative: bool, rhs_limbs: []const Limb) std.math.Order`。
- **作用**：不经 `BigInt` 结构体的带符号比较。
- **实现**：异号看符号；同号比绝对值，负数再 `invertOrder`。
- **所有权 / 错误 / 调用**：`BigInt.compare`；core 比较堆/短 bigint 时可直接喂 limb。

### `divRemAbsByLimbAlloc` (`src/libs/bigint.zig:527`)

- **签名**：`noinline fn divRemAbsByLimbAlloc( allocator: std.mem.Allocator, lhs: BigInt, divisor: Limb, ) !struct { BigInt, BigInt }`。
- **作用**：单 limb 除数的分配包装：高到低走一遍分子（qjs `mp_div1norm`，quickjs.c:11332），商按最终长度一次分配，不必再规范化/缩 realloc。
- **实现**：断言 divisor≠0、lhs 非空。调用方已处理 `lhs < rhs`，故商至少 1 limb。`quotient_len = lhs_top >= divisor ? lhs.len : lhs.len-1`。分配商，`errdefer free`。`divRemAbsByLimb` 写商并返回 remainder limb；非零则再分配 1 limb 余数。`noinline`：内联进 `divRemAbsAlloc` 会污染多 limb 位循环，测过约 2% JS 级回退。
- **所有权 / 错误 / 调用**：返回的两个 `BigInt` 由调用方 `deinit`。最多两次分配。`divRemAbsAlloc` 在单 limb 除数时进来。

### `divRemAbsByLimb` (`src/libs/bigint.zig:553`)

- **签名**：`fn divRemAbsByLimb(lhs: []const Limb, divisor: Limb, quotient: []Limb) Limb`。
- **作用**：单 limb 除法核，写满 `quotient`，返回余数。
- **实现**：`quotient.len` 是 `lhs.len` 或 `lhs.len-1`（顶商是否为零）。高到低 `(rem<<64|limb)/divisor`。
- **所有权 / 错误 / 调用**：`divRemAbsByLimbAlloc`。

### `normalizedReciprocalInit` (`src/libs/bigint.zig:599`)

- **签名**：`pub fn normalizedReciprocalInit(divisor: Limb) Limb`。
- **作用**：规范化除数的倒数，镜像 `udiv1norm_init`（quickjs.c:11433）。
- **实现**：要求最高位为 1。`floor((2^128-1)/divisor) - 2^64`，用分子 `((-divisor-1):−1)`，避免 129-bit。结果永不为 0，所以 0 可当「无倒数」哨兵。
- **所有权 / 错误 / 调用**：长除法在 `m = na-nb ≥ 3` 时算一次。

### `divTwoByOneReciprocal` (`src/libs/bigint.zig:618`)

- **签名**：`pub inline fn divTwoByOneReciprocal( high: Limb, low: Limb, divisor: Limb, reciprocal: Limb, ) struct { quotient: Limb, remainder: Limb }`。
- **作用**：精确 `(high:low)/divisor`，镜像 `udiv1norm`（quickjs.c:11444）。**不是近似**。
- **实现**：`high < divisor`。用 `low` 最高位做 `n1m`，乘加估计，再减一个多余 divisor，用高半符号无分支修正。全程 wrapping。
- **所有权 / 错误 / 调用**：长除法估计商位。短商仍走直 `u128/u64`。

### `divRemAbsNormalizedLong` (`src/libs/bigint.zig:665`)

- **签名**：`noinline fn divRemAbsNormalizedLong( allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt, want: DivOutput, ) !struct { BigInt, BigInt }`。
- **作用**：多 limb 除数的规范化学校书长除：一次一位商。对齐 qjs `js_bigint_divrem` 规范化后跑 `mp_divnorm`（quickjs.c:11893-11976）的机制，不是逐行移植（qjs 是带符号扩展的补码，zjs 是规范化符号-绝对值，顶商可以是任意 u64）。
- **实现**：断言 `nb>=2`、`na>=nb`、除数顶 limb 非 0。`shift = clz(rhs.top)`。商长在分配前算好：顶 `nb` 肢 ≥ 除数则为 `m+1` 否则 `m`（调用方已处理 `lhs<rhs`）。scratch `u`/`v` 各一块，`defer free`；商按 `want` 分配（只要余数则为空）。移位规范化使除数最高位为 1。`m = na-nb ≥ reciprocal_threshold`(3) 时算一次 `normalizedReciprocalInit`。从高到低：顶肢==v1 则 qhat 钳到 maxInt；否则倒数或直 `u128/u64` 估计；二 limb 修正（`qhat*v0 > (rhat<<64|next)` 则 qhat--）；`subMulAt` 下溢则 `addBackAt`（约 `2/2^64`，不会连续两次）。余数去掉规范化移位后按精确长度分配。全程无 shrinking realloc。
- **所有权 / 错误 / 调用**：最多四次分配，三次无条件（u/v/q 或 r）。OOM 时 `errdefer` 释放 q。`divRemAbsAlloc` 在多 limb 除数时进来。`noinline` 避免与单 limb 分支互相污染（P6-04b）。

### `shiftLeftInto` (`src/libs/bigint.zig:802`)

- **签名**：`fn shiftLeftInto(dst: []Limb, src: []const Limb, shift: u6) Limb`。
- **作用**：`dst = src << shift`，返回顶 carry。
- **实现**：`shift != 0`（0 在调用点 memcpy，避免 `64-shift` 越界）。
- **所有权 / 错误 / 调用**：长除法规范化移位。

### `unshiftedLimbAt` (`src/libs/bigint.zig:816`)

- **签名**：`fn unshiftedLimbAt(normalized: []const Limb, index: usize, shift: u6) Limb`。
- **作用**：去掉规范化移位后读余数的一 limb。
- **实现**：`shift==0` 直读；否则拼 `normalized[index]` 与 `[index+1]`。slice 必须多一 limb。
- **所有权 / 错误 / 调用**：长除法写余数。

### `subMulAt` (`src/libs/bigint.zig:837`)

- **签名**：`pub fn subMulAt(numerator: []Limb, divisor: []const Limb, qhat: Limb) bool`。
- **作用**：`numerator -= divisor * qhat`（`divisor.len+1` limb）。返回是否下溢（qhat 大了 1）。
- **实现**：每 limb 一条 wrapping `u128` 链，借位是完整 limb 而非 0/1。对齐 `mp_sub_mul1`（quickjs.c:11419），避免 LLVM 把 overflow flag 溢到栈。
- **所有权 / 错误 / 调用**：长除法内层。true 时 `addBackAt`。

### `addBackAt` (`src/libs/bigint.zig:855`)

- **签名**：`fn addBackAt(numerator: []Limb, divisor: []const Limb) void`。
- **作用**：下溢后加回 divisor。
- **实现**：`@addWithOverflow` 两趟。最后 carry 故意丢掉：正好抵消失败减法留下的借位。
- **所有权 / 错误 / 调用**：概率约 `2/2^64`，不会连续两次。

### `divRemAbsAlloc` (`src/libs/bigint.zig:867`)

- **签名**：`fn divRemAbsAlloc( allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt, want: DivOutput, ) !struct { BigInt, BigInt }`。
- **作用**：绝对值除法分发。
- **实现**：除零拒。`lhs < rhs`：商空，余数按需 clone。单 limb 除数走 `divRemAbsByLimbAlloc`。否则 `divRemAbsNormalizedLong`。
- **所有权 / 错误 / 调用**：单 limb 路径故意不穿 `want`（已是最快形状）。

### `addAlloc` (`src/libs/bigint.zig:888`)

- **签名**：`pub fn addAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt`。
- **作用**：带符号加法。
- **实现**：同号 `addAbsAlloc` 后贴符号。异号比绝对值：相等得零，否则大减小并继承大者符号。
- **所有权 / 错误 / 调用**：`subAlloc` 通过翻转 rhs 符号复用。

### `subAlloc` (`src/libs/bigint.zig:909`)

- **签名**：`pub fn subAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt`。
- **作用**：`lhs - rhs`。
- **实现**：拷贝 rhs 的字段、翻转 `negative`，`addAlloc`。不改调用方 rhs。
- **所有权 / 错误 / 调用**：无额外分配 besides add。

### `mulAlloc` (`src/libs/bigint.zig:915`)

- **签名**：`pub fn mulAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt`。
- **作用**：乘法。镜像 `mp_mul_basecase`（quickjs.c:11401）：第一行覆盖写，其后累加，不预清零。
- **实现**：任一侧零 → 空。`checkLimbCount(len_a+len_b)`。**短操作数为外层**（ commutes；测过 1×8 vs 8×1 差约 20%）。行 0 纯写，其后 `a*b + limbs[i+j] + carry`。
- **所有权 / 错误 / 调用**：`normalize` 剥顶零。`pow` 平方-乘每步走这里。

### `parseBaseAlloc` (`src/libs/bigint.zig:972`)

- **签名**：`fn parseBaseAlloc(allocator: std.mem.Allocator, bytes: []const u8, base: u32) !BigInt`。
- **作用**：按 radix 解析，对齐 `js_atobigint`（quickjs.c:12455-12490）。
- **实现**：trim、可选 ±。空 → `InvalidBigInt`。跳过前导零；digit 数 > `max_bits` 或估计 bit 宽超 cap → `BigIntTooLarge`。十进制估计 `(n*27+7)/8`。然后从**含前导零的原文**逐 digit `mulSmallInPlace`+`addSmallInPlace`（前导零是 no-op）。
- **所有权 / 错误 / 调用**：非法 digit `InvalidBigInt`。`errdefer out.deinit`。

### `addAbsAlloc` (`src/libs/bigint.zig:1001`)

- **签名**：`fn addAbsAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt`。
- **作用**：绝对值相加。
- **实现**：`max(len)+1` 缓冲，逐 limb 加。normalize 后再查 `max_limbs`（64-bit limb 的 speculative +1 会比 qjs 32-bit 早抛）。
- **所有权 / 错误 / 调用**：超限 `deinit` 再 `BigIntTooLarge`。

### `subAbsAlloc` (`src/libs/bigint.zig:1026`)

- **签名**：`fn subAbsAlloc(allocator: std.mem.Allocator, lhs: BigInt, rhs: BigInt) !BigInt`。
- **作用**：`|lhs| >= |rhs|` 的绝对值减。
- **实现**：`i128` 借位循环，负则加 `2^64`。调用方保证不够减不会发生。
- **所有权 / 错误 / 调用**：`normalize` 剥前导零。

### `mulSmallInPlace` (`src/libs/bigint.zig:1043`)

- **签名**：`fn mulSmallInPlace(value: *BigInt, multiplier: Limb) !void`。
- **作用**：原地乘小整数。
- **实现**：零或 ×1 返回；×0 `deinit` 成空。否则逐 limb，carry 则 `realloc(+1)`。
- **所有权 / 错误 / 调用**：解析。realloc 失败原 slice 仍在 `value` 里。

### `addSmallInPlace` (`src/libs/bigint.zig:1062`)

- **签名**：`fn addSmallInPlace(value: *BigInt, addend: Limb) !void`。
- **作用**：原地加小整数。
- **实现**：加 0 返回。空值分配 1 limb。否则从低位进位，需要时 realloc。
- **所有权 / 错误 / 调用**：`addPositiveSmallInPlace`、解析。

### `fromTwosComplement` (`src/libs/bigint.zig:1081`)

- **签名**：`fn fromTwosComplement(allocator: std.mem.Allocator, limbs: []const Limb, width: usize) !BigInt`。
- **作用**：定宽补码 → 符号-幅度。
- **实现**：看符号位。清未用高位。负则 `~`、再清一次未用位、然后 +1，`normalize`，零则强制 `negative=false`。
- **所有权 / 错误 / 调用**：`bitwise`。

### `compareAbs` (`src/libs/bigint.zig:1105`)

- **签名**：`fn compareAbs(lhs: BigInt, rhs: BigInt) std.math.Order`。
- **作用**：比绝对值。
- **实现**：`compareAbsParts(limbs)`。
- **所有权 / 错误 / 调用**：加减除法。

### `compareAbsParts` (`src/libs/bigint.zig:1109`)

- **签名**：`fn compareAbsParts(lhs_limbs: []const Limb, rhs_limbs: []const Limb) std.math.Order`。
- **作用**：规范化幅度比较：先比长度，再从高 limb 比。
- **实现**：长度不等即 `order(len)`；否则高到低。
- **所有权 / 错误 / 调用**：不变量：无前导零，所以长度就是幅度。

### `normalize` (`src/libs/bigint.zig:1124`)

- **签名**：`fn normalize(value: BigInt) !BigInt`。
- **作用**：剥前导零；全零释放成空。**消费所有权**。
- **实现**：调用方必须先把 `value` 交出（`const owned = x; x = empty`），不能再 `errdefer` 同一 slice。`realloc` 缩到 `len`。
- **所有权 / 错误 / 调用**：几乎所有分配结果的出口。OOM 时 `errdefer free`。

### `invertOrder` (`src/libs/bigint.zig:1141`)

- **签名**：`fn invertOrder(order: std.math.Order) std.math.Order`。
- **作用**：翻转 lt/gt，eq 不动。
- **实现**：switch。
- **所有权 / 错误 / 调用**：负数绝对值比较。

## 覆盖核对

- 清单函数数: 65
- 本文标题覆盖: 65
- 未覆盖: 无
