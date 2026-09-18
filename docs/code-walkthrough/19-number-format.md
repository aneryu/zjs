# 19 — `src/libs/number_format.zig`

QuickJS `dtoa.c` / `dtoa.h` 的 Zig 移植。上游名字原样保留（`mpb*`、`udiv1norm`、`jsDtoa*`、`jsAtod*`、`JS_DTOA_*`）。公开 API 用调用方缓冲区和固定临时 arena（`JSDTOATempMem` 37×u64，`JSATODTempMem` 27×u64），不向通用 heap 要内存。

引擎侧：`parseNumber` / `formatNumber` 给 `Number` 默认十进制；`formatRadix` 给 `Number.prototype.toString(radix)`；`formatDtoaChecked` 给 `toFixed`/`toExponential`/`toPrecision`。

## 类型与常量

| 符号 | 含义 |
| --- | --- |
| `JSDTOATempMem` | `extern struct { mem: [37]u64 }`，dtoa 工作区 |
| `JSATODTempMem` | `[27]u64`，atod 工作区 |
| `JS_DTOA_FORMAT_{FREE,FIXED,FRAC}` | 自由最短 / 定点有效位 / 小数位 |
| `JS_DTOA_EXP_{AUTO,ENABLED,DISABLED}` | 科学计数 |
| `JS_DTOA_MINUS_ZERO` | 允许打印 `-0` |
| `JS_ATOD_INT_ONLY` / `ACCEPT_BIN_OCT` / `ACCEPT_LEGACY_OCTAL` / `ACCEPT_UNDERSCORES` | 解析标志 |
| `Mpb(cap)` | `extern struct { len: i32, tab: [cap]u32 }`，32-bit limb 大数 |
| `LIMB_BITS=32`，`DBIGNUM_LEN_MAX=52`，`MANT_LEN_MAX=18` | 与 dtoa.c 一致 |
| `JS_RNDN/RNDNA/RNDZ` | 就近偶 / 远离零 / 朝零 |
| 表 | `pow5_table`/`pow5h_table`/`pow5_inv_table`、`mul_log2_radix_table`、`digits_per_limb_table`、`radix_base_table`、`dtoa_max_digits_table`、`atod_max_digits_table`、`max_exponent`/`min_exponent` |

`fn Mpb` 是返回类型的 comptime 工厂，清单把它当函数。

### `Mpb` (`src/libs/number_format.zig:77`)

- **签名**：`fn Mpb(comptime cap: usize) type`。
- **作用**：生成带固定 `tab` 的 bignum 类型，替代 C flexible array。
- **实现**：返回 `extern struct { len: i32, tab: [cap]limb_t }`，内含 `tabSlice` / `tabConstSlice`。
- **所有权 / 错误 / 调用**：`MpbMax = Mpb(52)` 放在 bump arena 上，从不 `free`。

### `tabSlice` (`src/libs/number_format.zig:84`)

- **签名**：`fn tabSlice(self: *Self) []limb_t`。
- **作用**：可变 limb 窗口。
- **实现**：长度 `@max(self.len, 1)`，零值仍暴露 `tab[0]`。
- **所有权 / 错误 / 调用**：`mpMul1` 等原地写。

### `tabConstSlice` (`src/libs/number_format.zig:89`)

- **签名**：`fn tabConstSlice(self: *const Self) []const limb_t`。
- **作用**：只读窗口。
- **实现**：同 `tabSlice`。
- **所有权 / 错误 / 调用**：`mulPow` 读。

### `minInt` (`src/libs/number_format.zig:181`)

- **签名**：`fn minInt(a: anytype, b: anytype) @TypeOf(a, b)`。
- **作用**：有符号最小（避免和 `@min` 的 usize 混用）。
- **实现**：`if (a < b) a else b`。
- **所有权 / 错误 / 调用**：dtoa 指数/位数裁剪。

### `maxInt` (`src/libs/number_format.zig:185`)

- **签名**：`fn maxInt(a: anytype, b: anytype) @TypeOf(a, b)`。
- **作用**：有符号最大。
- **实现**：`if (a > b) a else b`。
- **所有权 / 错误 / 调用**：FRAC 格式总位数。

### `clz32` (`src/libs/number_format.zig:189`)

- **签名**：`inline fn clz32(a: u32) i32`。
- **作用**：32-bit 前导零，返回 i32 以匹配 C `clz`。
- **实现**：`@intCast(@clz(a))`。
- **所有权 / 错误 / 调用**：`mpbFloorLog2`、radix bit 数。

### `clz64` (`src/libs/number_format.zig:193`)

- **签名**：`inline fn clz64(a: u64) i32`。
- **作用**：64-bit 前导零。
- **实现**：`@clz`。
- **所有权 / 错误 / 调用**：非规格化 float 规格化。

### `ctz32` (`src/libs/number_format.zig:197`)

- **签名**：`inline fn ctz32(a: u32) i32`。
- **作用**：尾零，用来把 radix 拆成 `radix1 * 2^shift`。
- **实现**：`@ctz`。
- **所有权 / 错误 / 调用**：`jsDtoaImpl` / `jsAtodImpl`。

### `float64AsUint64` (`src/libs/number_format.zig:201`)

- **签名**：`inline fn float64AsUint64(d: f64) u64`。
- **作用**：IEEE 754 位型。
- **实现**：`@bitCast`。
- **所有权 / 错误 / 调用**：拆符号/指数/尾数。

### `uint64AsFloat64` (`src/libs/number_format.zig:205`)

- **签名**：`inline fn uint64AsFloat64(u: u64) f64`。
- **作用**：位型装回 f64。
- **实现**：`@bitCast`。
- **所有权 / 错误 / 调用**：`finishAtod`。

### `dtoaMalloc` (`src/libs/number_format.zig:213`)

- **签名**：`fn dtoaMalloc(comptime T: type, mptr: *[*]u64) *T`。
- **作用**：bump 分配，对齐 `dtoa_malloc`。
- **实现**：按 8 字节前进 `mptr`，把当前指针 `@ptrCast` 成 `*T`。不检查越界——调用方必须让 `JSDTOATempMem` 够大。
- **所有权 / 错误 / 调用**：无 free；arena 随 `tmp_mem` 栈结束。

### `mpAddUi` (`src/libs/number_format.zig:224`)

- **签名**：`fn mpAddUi(tab: []limb_t, b: limb_t) limb_t`。
- **作用**：大数加立即数，返回最终进位。
- **实现**：wrapping 加，进位 `a < k`。`k==0` 提前停。
- **所有权 / 错误 / 调用**：`mpbShrRound` 舍入加 1。

### `mpMul1` (`src/libs/number_format.zig:235`)

- **签名**：`fn mpMul1(tabr: []limb_t, taba: []const limb_t, b: limb_t, carry: limb_t) limb_t`。
- **作用**：`tabr = taba * b + carry`，返回高 limb。
- **实现**：`dlimb_t` 乘加。
- **所有权 / 错误 / 调用**：`mulPow` 正幂、`mpbMul1Base`。

### `udiv1normInit` (`src/libs/number_format.zig:245`)

- **签名**：`fn udiv1normInit(d: limb_t) limb_t`。
- **作用**：32-bit 规范化倒数，dtoa 版 `udiv1norm_init`。
- **实现**：`(~d : 0xFFFFFFFF) / d`。
- **所有权 / 错误 / 调用**：唯一调用方是 `powUiInv` 的通用路径；`5^1..5^13` 直接查 `pow5_inv_table`，不走这里。

### `udiv1norm` (`src/libs/number_format.zig:252`)

- **签名**：`fn udiv1norm(pr: *limb_t, a1: limb_t, a0: limb_t, d: limb_t, d_inv: limb_t) limb_t`。
- **作用**：精确 `(a1:a0)/d`，余数写 `*pr`。
- **实现**：与 bigint 的 `divTwoByOneReciprocal` 同算法，32-bit limb。
- **所有权 / 错误 / 调用**：`mpDiv1normInternal`。

### `mpDiv1` (`src/libs/number_format.zig:266`)

- **签名**：`fn mpDiv1(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t) limb_t`。
- **作用**：直除单 limb，高到低。
- **实现**：`(r<<32 | taba[i]) / b`。
- **所有权 / 错误 / 调用**：`outputDigits` 非 2 幂 radix。

### `mpShr` (`src/libs/number_format.zig:278`)

- **签名**：`fn mpShr(tab_r: []limb_t, tab: []const limb_t, shift: u5, high: limb_t) limb_t`。
- **作用**：右移，`high` 注入顶。返回移出低位。
- **实现**：从高到低。
- **所有权 / 错误 / 调用**：`mpbShrRound`。

### `mpShl` (`src/libs/number_format.zig:290`)

- **签名**：`fn mpShl(tab_r: []limb_t, tab: []const limb_t, shift: u5, low: limb_t) limb_t`。
- **作用**：左移，返回溢出。
- **实现**：从低到高。
- **所有权 / 错误 / 调用**：规范化除法、负 `mpbShrRound`（实为左移）。

### `mpDiv1normInternal` (`src/libs/number_format.zig:299`)

- **签名**：`fn mpDiv1normInternal(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t, b_inv: limb_t, shift: i32) limb_t`。
- **作用**：可选先左移再倒数除。
- **实现**：`shift!=0` 时 `mpShl` 把被除数左移规范化（调用点 `tabr` 与 `taba` 是同一缓冲，所以后面的循环读到的是移过的值），`r` 一起左移；循环 `udiv1norm`；余数右移回来。除数 `b` 由调用方传入时已规范化。
- **所有权 / 错误 / 调用**：`mulPow` 负幂。

### `mpbRenorm` (`src/libs/number_format.zig:317`)

- **签名**：`fn mpbRenorm(r: *MpbMax) void`。
- **作用**：剥前导零，至少留 1 limb。
- **实现**：`while (len>1 && tab[len-1]==0) len--`。
- **所有权 / 错误 / 调用**：每次乘除后。

### `mpbGetBit` (`src/libs/number_format.zig:323`)

- **签名**：`fn mpbGetBit(r: *const MpbMax, k: i32) i32`。
- **作用**：取第 k 位，越界 0。
- **实现**：`k` 当 u32 拆 limb/bit。
- **所有权 / 错误 / 调用**：舍入看 sticky/guard。

### `mpbShrRound` (`src/libs/number_format.zig:333`)

- **签名**：`fn mpbShrRound(r: *MpbMax, shift: i32, rnd_mode: i32) void`。
- **作用**：按 `rnd_mode` 移位。负 `shift` 是左移（扩长度）。
- **实现**：左移：bit 再用 limb。右移：`RNDZ` 不入；`RNDN` 看 LSB+sticky；`RNDNA` 0.5 向上。需要时 `mpAddUi(1)`。整段移出则变成 0 或 1。
- **所有权 / 错误 / 调用**：dtoa 核心舍入。

### `mpbCmp` (`src/libs/number_format.zig:428`)

- **签名**：`fn mpbCmp(a: *const MpbMax, b: *const MpbMax) i32`。
- **作用**：比长度再比高 limb，返回 −1/0/1。
- **实现**：标准大数比较。
- **所有权 / 错误 / 调用**：FIXED 格式是否进位到下一位指数。

### `mpbSetU64` (`src/libs/number_format.zig:442`)

- **签名**：`fn mpbSetU64(r: *MpbMax, m: u64) void`。
- **作用**：写入 1 或 2 个 32-bit limb。
- **实现**：高 limb 0 则 `len=1`。
- **所有权 / 错误 / 调用**：从 float mantissa 起步。

### `mpbGetU64` (`src/libs/number_format.zig:452`)

- **签名**：`fn mpbGetU64(r: *const MpbMax) u64`。
- **作用**：读回 ≤64-bit 的幅度。
- **实现**：`len==1` 只低 limb。调用方保证不超 2 limb。
- **所有权 / 错误 / 调用**：FREE 格式 mantissa。

### `mpbFloorLog2` (`src/libs/number_format.zig:459`)

- **签名**：`fn mpbFloorLog2(a: *const MpbMax) i32`。
- **作用**：`floor(log2(a))`；全零 −1。
- **实现**：`len*32 - 1 - clz32(top)`。
- **所有权 / 错误 / 调用**：`roundToD`、`mulPow` extra_bits。

### `mpbMul1Base` (`src/libs/number_format.zig:465`)

- **签名**：`fn mpbMul1Base(r: *MpbMax, radix_base: limb_t, a: limb_t) void`。
- **作用**：`r = r * radix_base + a`（解析累加一 limb 的 digit）。
- **实现**：`r==0` 直接写 `a`。`radix_base==0` 表示 2^32，整体左移一 limb。否则 `mpMul1`。
- **所有权 / 错误 / 调用**：`jsAtodImpl`。

### `mulLog2Radix` (`src/libs/number_format.zig:488`)

- **签名**：`fn mulLog2Radix(a: i32, radix: i32) i32`。
- **作用**：近似 `a / log2(radix)`，用来估十进制指数。
- **实现**：2 幂 radix 按 `radix_bits` 做向下取整除（负数先减 `radix_bits-1` 再 `@divTrunc`）；否则乘预计算 `mul_log2_radix_table` 再 `@divFloor` 2^24。
- **所有权 / 错误 / 调用**：`jsDtoaMaxLenImpl`、`jsDtoaImpl` 三种 format 共用的初始 E。

### `powUi` (`src/libs/number_format.zig:503`)

- **签名**：`fn powUi(radix: u32, n: u32) u64`。
- **作用**：`radix^n`（适合 dtoa 的小 n）。
- **实现**：5/10 且 n≤17 查 `pow5_table`（10 再 `<< n`）。否则平方-乘。
- **所有权 / 错误 / 调用**：`mulPow`、FREE 的 `mant_max`。

### `powUiInv` (`src/libs/number_format.zig:530`)

- **签名**：`fn powUiInv(pr_inv: *u32, pshift: *i32, a: u32, b: u32) u32`。
- **作用**：返回规范化的 `a^b`，写出倒数与 shift。
- **实现**：5 的 1..13 次方走表；否则 `powUi` + `clz` + `udiv1normInit`。
- **所有权 / 错误 / 调用**：`mulPow` 负幂。

### `u32toaLen` (`src/libs/number_format.zig:553`)

- **签名**：`fn u32toaLen(buf: []u8, n: u32, len: usize) void`。
- **作用**：把 `n` 写成恰好 `len` 位十进制（左补零）。
- **实现**：从右往左 `%10`。
- **所有权 / 错误 / 调用**：`limbToA`、`u64toaImpl` 的 9 位块。

### `u64toaBinLen` (`src/libs/number_format.zig:563`)

- **签名**：`fn u64toaBinLen(buf: []u8, n: u64, radix_bits: u5, len: usize) void`。
- **作用**：2 幂 radix 定长写 digit。
- **实现**：掩码取低 `radix_bits`，`0-9a-z`。
- **所有权 / 错误 / 调用**：`outputDigits`、`u64toaRadixImpl`。

### `limbToA` (`src/libs/number_format.zig:579`)

- **签名**：`fn limbToA(buf: []u8, n: limb_t, radix: i32, len: i32) void`。
- **作用**：一个 32-bit limb 写成 `len` 个 radix digit。
- **实现**：10 走 `u32toaLen`，否则 `% radix`。
- **所有权 / 错误 / 调用**：直接写目标缓冲（修过 radix 3 的 20 digit 栈溢出）。

### `u32toaImpl` (`src/libs/number_format.zig:601`)

- **签名**：`fn u32toaImpl(buf: []u8, n: u32) usize`。
- **作用**：最短十进制，返回长度。
- **实现**：栈上 `[10]u8` 倒填再 memcpy。
- **所有权 / 错误 / 调用**：`formatInt32`、指数。

### `i32toaImpl` (`src/libs/number_format.zig:616`)

- **签名**：`fn i32toaImpl(buf: []u8, n: i32) usize`。
- **作用**：有符号 32-bit。
- **实现**：负则写 `-` 再对 wrapping-neg 的位型调 `u32toaImpl`（覆盖 `minInt`）。
- **所有权 / 错误 / 调用**：`formatInt32`。

### `u64toaImpl` (`src/libs/number_format.zig:624`)

- **签名**：`fn u64toaImpl(buf: []u8, n: u64) usize`。
- **作用**：最短十进制 u64。
- **实现**：<2^32 走 u32。否则按 10^9 块切，可能三块。
- **所有权 / 错误 / 调用**：长度用指针差计算。

### `i64toaImpl` (`src/libs/number_format.zig:662`)

- **签名**：`fn i64toaImpl(buf: []u8, n: i64) usize`。
- **作用**：有符号 64-bit。
- **实现**：同 `i32toaImpl` 的 wrapping 负。
- **所有权 / 错误 / 调用**：`formatInt64`。

### `u64toaRadixImpl` (`src/libs/number_format.zig:670`)

- **签名**：`fn u64toaRadixImpl(buf: []u8, n: u64, radix: u32) usize`。
- **作用**：任意 radix 2–36 写 u64。
- **实现**：10 走 `u64toaImpl`；2 幂算 bit 长后 `u64toaBinLen`；否则栈 `[65]u8` 反复 `%`。
- **所有权 / 错误 / 调用**：整数快路径 `jsDtoaImpl`。

### `outputDigits` (`src/libs/number_format.zig:708`)

- **签名**：`fn outputDigits(buf: []u8, a: *MpbMax, radix: i32, n_digits1: i32, dot_pos: i32) usize`。
- **作用**：把 mantissa 写成 `n_digits` 个 digit，可在 `dot_pos` 插 `.`。
- **实现**：2 幂：反复取出低 `digits_per_limb` 位再 `mpbShrRound(..., RNDZ)`。否则 `mpDiv1` 除 `radix_base`，`limbToA` 直写。最后 `copyBackwards` 插小数点。
- **所有权 / 错误 / 调用**：破坏 `a`。`outputHelper` / FRAC 路径。

### `mulPow` (`src/libs/number_format.zig:760`)

- **签名**：`fn mulPow(a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, is_int: bool, e: i32) i32`。
- **作用**：把 `a` 乘/除 `radix^f`（radix = radix1×2^shift），返回额外指数偏移。
- **实现**：`radix1==1` 只记账。`f>=0` 按 limb 组 `powUi`+`mpMul1`。`f<0` 先左移 `l*32+extra_bits`（`mpbShrRound` 负移，RNDZ）再逐组 `powUiInv`+`mpDiv1normInternal` 倒数除，余数非零把 `tab[0]` 的最低位置 1（sticky）。
- **所有权 / 错误 / 调用**：dtoa/atod 的 radix 转换。

### `mulPowRound` (`src/libs/number_format.zig:821`)

- **签名**：`fn mulPowRound(tmp1: *MpbMax, m: u64, e: i32, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) void`。
- **作用**：从 float mantissa `m×2^e` 转到 radix 定点并舍入。
- **实现**：`mpbSetU64`、`mulPow(..., is_int=true)`、`mpbShrRound(-e+e_offset)`。
- **所有权 / 错误 / 调用**：FREE/FIXED/FRAC。

### `roundToD` (`src/libs/number_format.zig:827`)

- **签名**：`fn roundToD(pe: *i32, a: *MpbMax, e_offset: i32, rnd_mode: i32) u64`。
- **作用**：把大数舍入成 53-bit mantissa，写出二进制指数。
- **实现**：零 → 0。算 `e_val`，次正规缩 precision，`mpbShrRound`，左对齐到 53 bit，溢出则右移并 `e++`。
- **所有权 / 错误 / 调用**：atod 最终组装。

### `mulPowRoundToD` (`src/libs/number_format.zig:857`)

- **签名**：`fn mulPowRoundToD(pe: *i32, a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) u64`。
- **作用**：radix 定点 → binary64 mantissa。
- **实现**：`mulPow(..., is_int=false, e=55)` 再 `roundToD`。
- **所有权 / 错误 / 调用**：FREE 格式 round-trip 验证；`jsAtodImpl` 的非 2 幂 radix 臂也走它。

### `toDigit` (`src/libs/number_format.zig:866`)

- **签名**：`inline fn toDigit(c: u8) i32`。
- **作用**：ASCII → digit 值；非法返回 36（≥ 任何合法 radix，调用点一律用 `c >= radix` 判）。
- **实现**：`0-9` / `A-Z` / `a-z`。
- **所有权 / 错误 / 调用**：`jsAtodImpl`。

### `jsDtoaMaxLenImpl` (`src/libs/number_format.zig:879`)

- **签名**：`fn jsDtoaMaxLenImpl(d: f64, radix: i32, n_digits: i32, flags: i32) i32`。
- **作用**：输出上限（不含 NUL），给调用方定缓冲。
- **实现**：FREE 用 `dtoa_max_digits_table`。`EXP_DISABLED` 按指数加整数位。FRAC 按 `e<0` 的前导零。NaN/Inf 走 `n=0` 再 `max(n,9)`。
- **所有权 / 错误 / 调用**：`radixMaxLen`、`formatDtoaChecked`。radix 2 + 非规格化可超一千 digit。

### `jsDtoaImpl` (`src/libs/number_format.zig:923`)

- **签名**：`fn jsDtoaImpl(buf: []u8, d: f64, radix: i32, n_digits: i32, flags: i32, tmp_mem: *JSDTOATempMem) usize`。
- **作用**：完整 dtoa：特殊值、整数快路径、FREE 最短、FRAC、FIXED。
- **实现**：bump 出两个 `Mpb`。拆 IEEE 位。Inf/NaN 写字面量。零走 `outputHelper`。非规格化 `clz64` 规格化。FREE 且整数且非强制指数：`u64toaRadixImpl`。否则估 E，FREE 从 P_max 往下试到 round-trip 失败；FRAC `RNDNA` 后 `outputDigits`；FIXED 乘 `radix^P` 与 mantissa 比。最后 `outputHelper`。
- **所有权 / 错误 / 调用**：调用方保证 `buf` 够。返回已写长度。

### `outputHelper` (`src/libs/number_format.zig:1083`)

- **签名**：`fn outputHelper( q_start: []u8, buf_start: []u8, tmp1: *MpbMax, radix: i32, radix1: i32, radix_shift: i32, P: i32, E: i32, n_digits: i32, flags: i32, ) usize`。
- **作用**：按 E 选择定点或科学计数，写 digit 与指数标记。
- **实现**：强制指数或 `E<=-6` 或 `E>E_max`：`outputDigits` 在第一位后插点，radix 10 用 `e`、2 幂小 shift 用 `p`（指数改 bit）、否则 `@`。`E<=0` 写 `0.`+前导零。否则整数部分 + 尾零。
- **所有权 / 错误 / 调用**：长度相对 `buf_start`。

### `jsAtodImpl` (`src/libs/number_format.zig:1160`)

- **签名**：`fn jsAtodImpl(str: []const u8, pnext: *?[*]const u8, radix_arg: i32, flags: i32, tmp_mem: *JSATODTempMem) f64`。
- **作用**：字符串 → f64，对齐 `js_atod`。失败时返回 NaN 并把 `pnext` 退回 `p_start`（符号之后的起点），表示一个字符都没消费。
- **实现**：可选符号。前缀 `0x/0o/0b`、遗留八进制（遇到 8/9 则退回十进制）。`Infinity`。然后按 `digits_per_limb` 攒 `cur_limb` 再 `mpbMul1Base`；超过 `atod_max_digits_table` 的 digit 只推进 `pos`（进 `expn_offset`）并 OR 进 `extra_digits` 当 sticky。小数点、`e/p/@` 指数（指数位数溢出记 `expn_overflow`，直接给 ±Inf 或 0）。`INT_ONLY` 不吃小数点与指数。数值组装分两臂：radix 是 2 的幂时用硬界 `expn1 >= 1024 + radix_bits` / `expn1 <= -1075` 提前判溢出，再 `roundToD(-expn)`；否则查 `max_exponent`/`min_exponent` 表判溢出，再 `mulPowRoundToD`；两臂都以 `buildFloat64` 收尾。`finishAtod` 贴符号并写 `pnext`。
- **所有权 / 错误 / 调用**：不抛 Zig error；`parseNumber` 用 `pnext` 是否吃完整串判断。生产里唯一的调用方就是 `parseNumber`（radix 10、flags 0），`ACCEPT_UNDERSCORES` / `ACCEPT_BIN_OCT` / `ACCEPT_LEGACY_OCTAL` / `INT_ONLY` 与非 10 radix 的臂只被单测驱动，函数头注释已写明保留理由（忠实移植 + 嵌入者复用）。两处上游残留已清理：有效数字循环里跳过分隔符时补了 `p.len > 1` 守卫（与 1248/1330 对齐，否则打开 `ACCEPT_UNDERSCORES` 后 `"1_"` 会越界读 `p[1]`），以及两处外层已确定 `p[0] == '.'`、内层再判 `p[0] == sep` 的死 NaN 分支（`sep` 只可能是 `'_'` 或 256）已删。

### `buildFloat64` (`src/libs/number_format.zig:1396`)

- **签名**：`fn buildFloat64(m: u64, e: i32) u64`。
- **作用**：mantissa+指数 → IEEE 位（无符号位）。
- **实现**：m=0 → 0；`e>1024` Inf；`e<-1073` 0；次正规右移；否则 `(e+1022)<<52 | (m & 52bit)`。
- **所有权 / 错误 / 调用**：`jsAtodImpl` 尾。

### `finishAtod` (`src/libs/number_format.zig:1406`)

- **签名**：`fn finishAtod(a: u64, is_neg: i32, p: []const u8, pnext: *?[*]const u8) f64`。
- **作用**：贴符号位、记录结束指针。
- **实现**：`a |= is_neg<<63`；`pnext.* = p.ptr`。
- **所有权 / 错误 / 调用**：atod 唯一出口之一。

### `parseNumber` (`src/libs/number_format.zig:1417`)

- **签名**：`pub fn parseNumber(bytes: []const u8) !f64`。
- **作用**：引擎用的严格十进制解析：必须吃完整串。
- **实现**：字面 `"NaN"` 直接 NaN。否则 `jsAtodImpl(..., 10, 0)`；`pnext` 对不上或结果 NaN → `InvalidCharacter`。
- **所有权 / 错误 / 调用**：栈上 `JSATODTempMem`。`Number("12.5")` 等。`+Infinity` 由 atod 认。

### `formatNumber` (`src/libs/number_format.zig:1431`)

- **签名**：`pub fn formatNumber(buf: []u8, value: f64) ![]const u8`。
- **作用**：默认 `ToString` 十进制。
- **实现**：NaN/±Inf 返回静态切片。否则 FREE+EXP_AUTO 的 `jsDtoaImpl`。
- **所有权 / 错误 / 调用**：返回 `buf[0..len]`。缓冲不够会越界——调用方应用 `radixMaxLen(10,…)`。

### `formatInt32` (`src/libs/number_format.zig:1441`)

- **签名**：`pub fn formatInt32(buf: []u8, value: i32) []const u8`。
- **作用**：int32 十进制。
- **实现**：`i32toaImpl`。
- **所有权 / 错误 / 调用**：无 error。`buf` 至少 12 字节。

### `formatInt64` (`src/libs/number_format.zig:1446`)

- **签名**：`pub fn formatInt64(buf: []u8, value: i64) []const u8`。
- **作用**：int64 十进制。
- **实现**：`i64toaImpl`。
- **所有权 / 错误 / 调用**：`buf` 至少 21 字节。

### `radixMaxLen` (`src/libs/number_format.zig:1455`)

- **签名**：`pub fn radixMaxLen(value: f64, radix: i32, n_digits: i32, flags: i32) !usize`。
- **作用**：`formatRadix` 写入上限（含一点余量）。
- **实现**：`jsDtoaMaxLenImpl+1`；负长度 `InvalidRadix`。
- **所有权 / 错误 / 调用**：radix 2 非规格化会过千字节，不能猜。

### `formatRadix` (`src/libs/number_format.zig:1464`)

- **签名**：`pub fn formatRadix(buf: []u8, value: f64, radix: i32, n_digits: i32, flags: i32) ![]const u8`。
- **作用**：radix 2–36 的 `Number.prototype.toString`。
- **实现**：缓冲 < `radixMaxLen` → `NoSpaceLeft`。`jsDtoaImpl`；`len>=buf.len` 再拒一次。
- **所有权 / 错误 / 调用**：digit 生成与十进制同一套 js_dtoa。

### `formatDtoaChecked` (`src/libs/number_format.zig:1472`)

- **签名**：`pub fn formatDtoaChecked(buf: []u8, value: f64, n_digits: i32, flags: i32) ![]const u8`。
- **作用**：带长度检查的十进制 dtoa（toFixed 等）。
- **实现**：先 `jsDtoaMaxLenImpl(10,…)`，不够 `NoSpaceLeft`，再 `jsDtoaImpl`。
- **所有权 / 错误 / 调用**：比 `formatNumber` 多固定/小数模式。

## 覆盖核对

- 清单函数数: 57
- 本文标题覆盖: 57
- 未覆盖: 无
