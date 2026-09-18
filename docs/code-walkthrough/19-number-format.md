# 19 — `src/libs/number_format.zig`

QuickJS `dtoa.c` / `dtoa.h` 的 Zig 移植。这个文件的**引擎职责是打印**：`formatNumber` / `formatRadix` / `formatDtoaChecked`。十进制 ToNumber、源码字面量、`parseFloat`、JSON 走 `std.fmt.parseFloat`，不进本文件。

`parseNumber` / `jsAtod` 是 `jsDtoa` 的反函数（含 radix 2..36），给 `toString(radix)` round-trip 和端口完整性用，**不是第二套 ToNumber**。

上游名字原样保留（`mpb*`、`udiv1norm`、`jsDtoa`、`jsAtod`、`JS_DTOA_*`）。公开格式化 API 用调用方缓冲区和固定临时 arena，不向通用 heap 要内存。

```
formatNumber / formatRadix / formatDtoaChecked
  └─ jsDtoa
       ├─ writeNonFinite | integer fast path
       ├─ dtoaShortest | dtoaFrac | dtoaFixed
       └─ outputDigits / outputHelper

parseNumber / tests  （dtoa 反函数，不是 ToNumber）
  └─ jsAtod ─► parseAtodExponent ─► atodToBits ─► buildFloat64
```

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
| `DtoaScale` | `{P, E}`，FREE 路径的有效位与指数 |
| `AtodExp` | 指数扫描结果（含 overflow / invalid） |
| `LIMB_BITS=32`，`DBIGNUM_LEN_MAX=52`，`MANT_LEN_MAX=18` | 与 dtoa.c 一致 |
| `JS_RNDN/RNDNA/RNDZ` | 就近偶 / 远离零 / 朝零 |
| 表 | `pow5_table`/`pow5h_table`/`pow5_inv_table`、`mul_log2_radix_table`、`digits_per_limb_table`、`radix_base_table`、`dtoa_max_digits_table`、`atod_max_digits_table`、`max_exponent`/`min_exponent` |

`fn Mpb` 是返回类型的 comptime 工厂，清单把它当函数。

## 公开 API

### `formatNumber` (`src/libs/number_format.zig:86`)

- **签名**：`pub fn formatNumber(buf: []u8, value: f64) ![]const u8`。
- **作用**：默认 `ToString` 十进制。
- **实现**：NaN/±Inf 返回静态切片。否则 FREE+EXP_AUTO 的 `jsDtoa`。
- **所有权 / 错误 / 调用**：返回 `buf[0..len]`。缓冲不够会越界——调用方应用 `radixMaxLen(10,…)` 或走 `formatDtoaChecked`。

### `formatInt32` (`src/libs/number_format.zig:96`)

- **签名**：`pub fn formatInt32(buf: []u8, value: i32) []const u8`。
- **作用**：int32 十进制。
- **实现**：`i32toa`。
- **所有权 / 错误 / 调用**：无 error。`buf` 至少 12 字节。

### `formatInt64` (`src/libs/number_format.zig:101`)

- **签名**：`pub fn formatInt64(buf: []u8, value: i64) []const u8`。
- **作用**：int64 十进制。
- **实现**：`i64toa`。
- **所有权 / 错误 / 调用**：`buf` 至少 21 字节。

### `radixMaxLen` (`src/libs/number_format.zig:110`)

- **签名**：`pub fn radixMaxLen(value: f64, radix: i32, n_digits: i32, flags: i32) !usize`。
- **作用**：`formatRadix` 写入上限（含一点余量）。
- **实现**：`jsDtoaMaxLen+1`；负长度 `InvalidRadix`。
- **所有权 / 错误 / 调用**：radix 2 非规格化会过千字节，不能猜。

### `formatRadix` (`src/libs/number_format.zig:118`)

- **签名**：`pub fn formatRadix(buf: []u8, value: f64, radix: i32, n_digits: i32, flags: i32) ![]const u8`。
- **作用**：radix 2–36 的 `Number.prototype.toString`。
- **实现**：缓冲 < `radixMaxLen` → `NoSpaceLeft`。`jsDtoa`；`len>=buf.len` 再拒一次。
- **所有权 / 错误 / 调用**：digit 生成与十进制同一套 js_dtoa。

### `formatDtoaChecked` (`src/libs/number_format.zig:127`)

- **签名**：`pub fn formatDtoaChecked(buf: []u8, value: f64, n_digits: i32, flags: i32) ![]const u8`。
- **作用**：带长度检查的十进制 dtoa（toFixed 等）。
- **实现**：先 `jsDtoaMaxLen(10,…)`，不够 `NoSpaceLeft`，再 `jsDtoa`。
- **所有权 / 错误 / 调用**：比 `formatNumber` 多固定/小数模式。

### `parseNumber` (`src/libs/number_format.zig:140`)

- **签名**：`fn parseNumber(bytes: []const u8) !f64`。
- **作用**：`jsDtoa` 的十进制反函数：必须吃完整串。
- **实现**：字面 `"NaN"` 直接 NaN。否则 `jsAtod(..., 10, 0)`；`pnext` 对不上或结果 NaN → `InvalidCharacter`。
- **所有权 / 错误 / 调用**：文件私有。不是 ToNumber。调用方只有本文件单测。`+Infinity` 由 atod 认。

## Scratch 与 `Mpb`

### `Mpb` (`src/libs/number_format.zig:251`)

- **签名**：`fn Mpb(comptime cap: usize) type`。
- **作用**：生成带固定 `tab` 的 bignum 类型，替代 C flexible array。
- **实现**：返回 `extern struct { len: i32, tab: [cap]limb_t }`，内含 `tabSlice` / `tabConstSlice`。
- **所有权 / 错误 / 调用**：`MpbMax = Mpb(52)` 放在 bump arena 上，从不 `free`。

### `tabSlice` (`src/libs/number_format.zig:258`)

- **签名**：`fn tabSlice(self: *Self) []limb_t`。
- **作用**：可变 limb 窗口。
- **实现**：长度 `@max(self.len, 1)`，零值仍暴露 `tab[0]`。
- **所有权 / 错误 / 调用**：`mpMul1` 等原地写。

### `tabConstSlice` (`src/libs/number_format.zig:263`)

- **签名**：`fn tabConstSlice(self: *const Self) []const limb_t`。
- **作用**：只读窗口。
- **实现**：同 `tabSlice`。
- **所有权 / 错误 / 调用**：`mulPow` 读。

### `dtoaMalloc` (`src/libs/number_format.zig:272`)

- **签名**：`fn dtoaMalloc(comptime T: type, mptr: *[*]u64) *T`。
- **作用**：从临时 arena bump 出 `T`。
- **实现**：按 8 字节对齐推进 `mptr`。
- **所有权 / 错误 / 调用**：函数返回后整块丢弃，无 `free`。

### `writtenLen` (`src/libs/number_format.zig:279`)

- **签名**：`fn writtenLen(buf: []const u8, cursor: []const u8) usize`。
- **作用**：输出游标相对缓冲起点的已写长度。
- **实现**：指针差。
- **所有权 / 错误 / 调用**：`jsDtoa` / `outputHelper` / 整数 toa 共用。

### `minInt` (`src/libs/number_format.zig:283`)

- **签名**：`fn minInt(a: anytype, b: anytype) @TypeOf(a, b)`。
- **作用**：有符号最小（避免和 `@min` 的 usize 混用）。
- **实现**：`if (a < b) a else b`。
- **所有权 / 错误 / 调用**：dtoa 指数/位数裁剪。

### `maxInt` (`src/libs/number_format.zig:287`)

- **签名**：`fn maxInt(a: anytype, b: anytype) @TypeOf(a, b)`。
- **作用**：有符号最大。
- **实现**：`if (a > b) a else b`。
- **所有权 / 错误 / 调用**：FRAC 格式总位数。

### `clz32` (`src/libs/number_format.zig:291`)

- **签名**：`inline fn clz32(a: u32) i32`。
- **作用**：32-bit 前导零，返回 i32 以匹配 C `clz`。
- **实现**：`@intCast(@clz(a))`。
- **所有权 / 错误 / 调用**：`mpbFloorLog2`、radix bit 数。

### `clz64` (`src/libs/number_format.zig:295`)

- **签名**：`inline fn clz64(a: u64) i32`。
- **作用**：64-bit 前导零。
- **实现**：`@clz`。
- **所有权 / 错误 / 调用**：非规格化 float 规格化。

### `ctz32` (`src/libs/number_format.zig:299`)

- **签名**：`inline fn ctz32(a: u32) i32`。
- **作用**：尾零，用来把 radix 拆成 `radix1 * 2^shift`。
- **实现**：`@ctz`。
- **所有权 / 错误 / 调用**：`jsDtoa` / `jsAtod`。

### `float64AsUint64` (`src/libs/number_format.zig:303`)

- **签名**：`inline fn float64AsUint64(d: f64) u64`。
- **作用**：IEEE 位型。
- **实现**：`@bitCast`。
- **所有权 / 错误 / 调用**：拆符号/指数/尾数。

### `uint64AsFloat64` (`src/libs/number_format.zig:307`)

- **签名**：`inline fn uint64AsFloat64(u: u64) f64`。
- **作用**：位型 → f64。
- **实现**：`@bitCast`。
- **所有权 / 错误 / 调用**：`finishAtod`。

## Limb 算术

### `mpAddUi` (`src/libs/number_format.zig:315`)

- **签名**：`fn mpAddUi(tab: []limb_t, b: limb_t) limb_t`。
- **作用**：切片加单 limb，返回最终进位。
- **实现**：`+%` 循环，进位为零提前停。
- **所有权 / 错误 / 调用**：`mpbShrRound` 进 1。

### `mpMul1` (`src/libs/number_format.zig:326`)

- **签名**：`fn mpMul1(tabr: []limb_t, taba: []const limb_t, b: limb_t, carry: limb_t) limb_t`。
- **作用**：`tabr = taba * b + carry`，返回高 limb。
- **实现**：64-bit 乘加。
- **所有权 / 错误 / 调用**：`mulPow` 正幂、`mpbMul1Base`。

### `udiv1normInit` (`src/libs/number_format.zig:336`)

- **签名**：`fn udiv1normInit(d: limb_t) limb_t`。
- **作用**：归一化除数的倒数近似。
- **实现**：`(~d << 32 | 0xFFFFFFFF) / d`。
- **所有权 / 错误 / 调用**：`powUiInv`。

### `udiv1norm` (`src/libs/number_format.zig:343`)

- **签名**：`fn udiv1norm(pr: *limb_t, a1: limb_t, a0: limb_t, d: limb_t, d_inv: limb_t) limb_t`。
- **作用**：`[a1:a0] / d`，余数写入 `pr`。
- **实现**：Granlund–Montgomery 风格修正。
- **所有权 / 错误 / 调用**：`mpDiv1norm`。

### `mpDiv1` (`src/libs/number_format.zig:357`)

- **签名**：`fn mpDiv1(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t) limb_t`。
- **作用**：从高到低除以单 limb。
- **实现**：64-bit `/` `%`。
- **所有权 / 错误 / 调用**：非 2 幂 `outputDigits`。

### `mpShr` (`src/libs/number_format.zig:369`)

- **签名**：`fn mpShr(tab_r: []limb_t, tab: []const limb_t, shift: u5, high: limb_t) limb_t`。
- **作用**：limb 切片右移。
- **实现**：高位灌入 `high`，返回移出的低位。
- **所有权 / 错误 / 调用**：`mpbShrRound`。

### `mpShl` (`src/libs/number_format.zig:381`)

- **签名**：`fn mpShl(tab_r: []limb_t, tab: []const limb_t, shift: u5, low: limb_t) limb_t`。
- **作用**：limb 切片左移。
- **实现**：低位灌入 `low`，返回溢出高位。
- **所有权 / 错误 / 调用**：`mpbShrRound` 负移、`mpDiv1norm`。

### `mpDiv1norm` (`src/libs/number_format.zig:390`)

- **签名**：`fn mpDiv1norm(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t, b_inv: limb_t, shift: i32) limb_t`。
- **作用**：归一化单 limb 除（可先左移对齐）。
- **实现**：可选 `mpShl` 后逐 limb `udiv1norm`，再把余数右移回来。
- **所有权 / 错误 / 调用**：`mulPow` 负幂。

### `mpbRenorm` (`src/libs/number_format.zig:408`)

- **签名**：`fn mpbRenorm(r: *MpbMax) void`。
- **作用**：去掉高位零 limb，至少留 1。
- **实现**：`while len>1 and tab[len-1]==0`。
- **所有权 / 错误 / 调用**：几乎所有写 `Mpb` 的路径。

### `mpbGetBit` (`src/libs/number_format.zig:414`)

- **签名**：`fn mpbGetBit(r: *const MpbMax, k: i32) i32`。
- **作用**：取第 `k` 位（0=LSB）。
- **实现**：越界当 0。
- **所有权 / 错误 / 调用**：`mpbShrRound` 的 0.5-bit / LSB。

### `mpbShrRound` (`src/libs/number_format.zig:424`)

- **签名**：`fn mpbShrRound(r: *MpbMax, shift: i32, rnd_mode: i32) void`。
- **作用**：带舍入的大数移位；负 `shift` 是左移。
- **实现**：左移按 limb + bit。右移：`RNDZ` 截断；`RNDN` 看 0.5-bit 与 sticky，平局 round-to-even；`RNDNA` 平局远离零。然后 limb 右移，必要时 `mpAddUi(1)`。
- **所有权 / 错误 / 调用**：`mulPow` / `roundToD` / `outputDigits`。

### `mpbCmp` (`src/libs/number_format.zig:518`)

- **签名**：`fn mpbCmp(a: *const MpbMax, b: *const MpbMax) i32`。
- **作用**：比较幅度。
- **实现**：先比 `len`，再从高 limb 比。
- **所有权 / 错误 / 调用**：`dtoaFixed`。

### `mpbSetU64` (`src/libs/number_format.zig:532`)

- **签名**：`fn mpbSetU64(r: *MpbMax, m: u64) void`。
- **作用**：写入 1–2 个 limb。
- **实现**：高 limb 为 0 则 `len=1`。
- **所有权 / 错误 / 调用**：`mulPowRound`、FREE 回写 mantissa。

### `mpbGetU64` (`src/libs/number_format.zig:542`)

- **签名**：`fn mpbGetU64(r: *const MpbMax) u64`。
- **作用**：读回低 64 bit。
- **实现**：`len==1` 只取 `tab[0]`。
- **所有权 / 错误 / 调用**：假定值已收进 64 bit。

### `mpbFloorLog2` (`src/libs/number_format.zig:549`)

- **签名**：`fn mpbFloorLog2(a: *const MpbMax) i32`。
- **作用**：`floor(log2(a))`。
- **实现**：`(len*32-1) - clz32(最高 limb)`；最高为 0 返回 -1。
- **所有权 / 错误 / 调用**：`mulPow` extra_bits、`roundToD`。

### `mpbMul1Base` (`src/libs/number_format.zig:555`)

- **签名**：`fn mpbMul1Base(r: *MpbMax, radix_base: limb_t, a: limb_t) void`。
- **作用**：`r = r * radix_base + a`；`radix_base==0` 表示乘 `2^32`（左移一个 limb）。
- **实现**：零值直接写 `a`；否则 `mpMul1` 或整表上移。
- **所有权 / 错误 / 调用**：`jsAtod` 攒 digit。

## 幂与对数

### `mulLog2Radix` (`src/libs/number_format.zig:578`)

- **签名**：`fn mulLog2Radix(a: i32, radix: i32) i32`。
- **作用**：近似 `a * log2(radix)`，用来估十进制/任意进制指数 `E`。
- **实现**：2 幂直接除 bit 数；否则查表定点乘。
- **所有权 / 错误 / 调用**：`jsDtoaMaxLen`、`jsDtoa` 三种 format 共用的初始 E。

### `powUi` (`src/libs/number_format.zig:589`)

- **签名**：`fn powUi(radix: u32, n: u32) u64`。
- **作用**：`radix^n`（保证不溢出 u64 的调用点）。
- **实现**：5/10 且 n≤17 走 `pow5_table`（10 再左移 n）；否则平方倍增。
- **所有权 / 错误 / 调用**：`mulPow`、FREE 的 `mant_max1`。

### `powUiInv` (`src/libs/number_format.zig:616`)

- **签名**：`fn powUiInv(pr_inv: *u32, pshift: *i32, a: u32, b: u32) u32`。
- **作用**：返回规范化的 `a^b`，写出倒数与 shift。
- **实现**：5 的 1..13 次方走表；否则 `powUi` + `clz` + `udiv1normInit`。
- **所有权 / 错误 / 调用**：`mulPow` 负幂。

## 整数 ASCII

### `u32toaLen` (`src/libs/number_format.zig:639`)

- **签名**：`fn u32toaLen(buf: []u8, n: u32, len: usize) void`。
- **作用**：把 `n` 写成恰好 `len` 位十进制（左补零）。
- **实现**：从右往左 `%10`。
- **所有权 / 错误 / 调用**：`limbToA`、`u64toa` 的 9 位块。

### `u64toaBinLen` (`src/libs/number_format.zig:649`)

- **签名**：`fn u64toaBinLen(buf: []u8, n: u64, radix_bits: u5, len: usize) void`。
- **作用**：2 幂 radix 定长写 digit。
- **实现**：掩码取低 `radix_bits`，`0-9a-z`。
- **所有权 / 错误 / 调用**：`outputDigits`、`u64toaRadix`。

### `limbToA` (`src/libs/number_format.zig:665`)

- **签名**：`fn limbToA(buf: []u8, n: limb_t, radix: i32, len: i32) void`。
- **作用**：一个 32-bit limb 写成 `len` 个 radix digit。
- **实现**：10 走 `u32toaLen`，否则 `% radix`。
- **所有权 / 错误 / 调用**：直接写目标缓冲（修过 radix 3 的 20 digit 栈溢出）。

### `u32toa` (`src/libs/number_format.zig:687`)

- **签名**：`fn u32toa(buf: []u8, n: u32) usize`。
- **作用**：最短十进制，返回长度。
- **实现**：栈上 `[10]u8` 倒填再 memcpy。
- **所有权 / 错误 / 调用**：`formatInt32`、指数。

### `i32toa` (`src/libs/number_format.zig:702`)

- **签名**：`fn i32toa(buf: []u8, n: i32) usize`。
- **作用**：有符号 32-bit。
- **实现**：负则写 `-` 再对 wrapping-neg 的位型调 `u32toa`（覆盖 `minInt`）。
- **所有权 / 错误 / 调用**：`formatInt32`。

### `u64toa` (`src/libs/number_format.zig:710`)

- **签名**：`fn u64toa(buf: []u8, n: u64) usize`。
- **作用**：最短十进制 u64。
- **实现**：<2^32 走 u32。否则按 10^9 块切，可能三块。
- **所有权 / 错误 / 调用**：长度用 `writtenLen`。

### `i64toa` (`src/libs/number_format.zig:748`)

- **签名**：`fn i64toa(buf: []u8, n: i64) usize`。
- **作用**：有符号 64-bit。
- **实现**：同 `i32toa` 的 wrapping 负。
- **所有权 / 错误 / 调用**：`formatInt64`。

### `u64toaRadix` (`src/libs/number_format.zig:756`)

- **签名**：`fn u64toaRadix(buf: []u8, n: u64, radix: u32) usize`。
- **作用**：任意 radix 2–36 写 u64。
- **实现**：10 走 `u64toa`；2 幂算 bit 长后 `u64toaBinLen`；否则栈 `[65]u8` 反复 `%`。
- **所有权 / 错误 / 调用**：整数快路径 `jsDtoa`。

## 换基与舍入

### `mulPow` (`src/libs/number_format.zig:794`)

- **签名**：`fn mulPow(a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, is_int: bool, e: i32) i32`。
- **作用**：把 `a` 乘/除 `radix^f`（radix = radix1×2^shift），返回额外指数偏移。
- **实现**：`radix1==1` 只记账。`f>=0` 按 limb 组 `powUi`+`mpMul1`。`f<0` 先左移 `l*32+extra_bits`（`mpbShrRound` 负移，RNDZ）再逐组 `powUiInv`+`mpDiv1norm` 倒数除，余数非零把 `tab[0]` 的最低位置 1（sticky）。
- **所有权 / 错误 / 调用**：dtoa/atod 的 radix 转换。

### `mulPowRound` (`src/libs/number_format.zig:855`)

- **签名**：`fn mulPowRound(tmp1: *MpbMax, m: u64, e: i32, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) void`。
- **作用**：从 float mantissa `m×2^e` 转到 radix 定点并舍入。
- **实现**：`mpbSetU64`、`mulPow(..., is_int=true)`、`mpbShrRound(-e+e_offset)`。
- **所有权 / 错误 / 调用**：FREE/FIXED/FRAC。

### `roundToD` (`src/libs/number_format.zig:861`)

- **签名**：`fn roundToD(pe: *i32, a: *MpbMax, e_offset: i32, rnd_mode: i32) u64`。
- **作用**：把大数舍入成 53-bit mantissa，写出二进制指数。
- **实现**：零 → 0。算 `e_val`，次正规缩 precision，`mpbShrRound`，左对齐到 53 bit，溢出则右移并 `e++`。
- **所有权 / 错误 / 调用**：atod 最终组装；2 幂 radix 的 `atodToBits`。

### `mulPowRoundToD` (`src/libs/number_format.zig:891`)

- **签名**：`fn mulPowRoundToD(pe: *i32, a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) u64`。
- **作用**：radix 定点 → binary64 mantissa。
- **实现**：`mulPow(..., is_int=false, e=55)` 再 `roundToD`。
- **所有权 / 错误 / 调用**：FREE 格式 round-trip 验证；`atodToBits` 的非 2 幂 radix 臂。

## 出字

### `outputDigits` (`src/libs/number_format.zig:900`)

- **签名**：`fn outputDigits(buf: []u8, a: *MpbMax, radix: i32, n_digits1: i32, dot_pos: i32) usize`。
- **作用**：把 mantissa 写成 `n_digits` 个 digit，可在 `dot_pos` 插 `.`。
- **实现**：2 幂：反复取出低 `digits_per_limb` 位再 `mpbShrRound(..., RNDZ)`。否则 `mpDiv1` 除 `radix_base`，`limbToA` 直写。最后 `copyBackwards` 插小数点。
- **所有权 / 错误 / 调用**：破坏 `a`。`outputHelper` / `dtoaFrac`。

### `outputHelper` (`src/libs/number_format.zig:948`)

- **签名**：`fn outputHelper(q_start: []u8, buf_start: []u8, tmp1: *MpbMax, radix: i32, radix1: i32, radix_shift: i32, P: i32, E: i32, n_digits: i32, flags: i32) usize`。
- **作用**：按 E 选择定点或科学计数，写 digit 与指数标记。
- **实现**：强制指数或 `E<=-6` 或 `E>E_max`：`outputDigits` 在第一位后插点，radix 10 用 `e`、2 幂小 shift 用 `p`（指数改 bit）、否则 `@`。`E<=0` 写 `0.`+前导零。否则整数部分 + 尾零。
- **所有权 / 错误 / 调用**：长度相对 `buf_start`。

## dtoa 阶段

### `jsDtoaMaxLen` (`src/libs/number_format.zig:1021`)

- **签名**：`fn jsDtoaMaxLen(d: f64, radix: i32, n_digits: i32, flags: i32) i32`。
- **作用**：输出上限（不含 NUL），给调用方定缓冲。
- **实现**：FREE 用 `dtoa_max_digits_table`。`EXP_DISABLED` 按指数加整数位。FRAC 按 `e<0` 的前导零。NaN/Inf 走 `n=0` 再 `max(n,9)`。
- **所有权 / 错误 / 调用**：`radixMaxLen`、`formatDtoaChecked`。radix 2 + 非规格化可超一千 digit。

### `writeNonFinite` (`src/libs/number_format.zig:1061`)

- **签名**：`fn writeNonFinite(buf: []u8, sgn: i32, frac: u64) usize`。
- **作用**：写 `NaN` / `Infinity` / `-Infinity`。
- **实现**：`frac==0` 为 Inf（负号按 `sgn`）；否则 `NaN` 不带符号。
- **所有权 / 错误 / 调用**：`jsDtoa` 的 `e==0x7ff` 臂。

### `dtoaShortest` (`src/libs/number_format.zig:1078`)

- **签名**：`fn dtoaShortest(tmp1: *MpbMax, m: u64, e: i32, radix: i32, radix1: i32, radix_shift: i32) DtoaScale`。
- **作用**：FORMAT_FREE：最短且能 round-trip 回 `(m, e)` 的 digit 串。
- **实现**：从 `P_max` 往下试。内层把 `E` 抬到 `mant < radix^P`。去掉尾零。第一次成功只记账；之后 `mulPowRoundToD` 验 round-trip，失败就停。结果写回 `tmp1`。
- **所有权 / 错误 / 调用**：`jsDtoa` 的 FREE 臂。已去掉上游那次结果未使用的 `powUi` 调用。

### `dtoaFrac` (`src/libs/number_format.zig:1127`)

- **签名**：`fn dtoaFrac(q: []u8, tmp1: *MpbMax, m: u64, e: i32, E: i32, radix: i32, radix1: i32, radix_shift: i32, n_digits: i32) []u8`。
- **作用**：FORMAT_FRAC：小数点后 `n_digits` 位（`toFixed`）。
- **实现**：`mulPowRound(..., RNDNA)`，`outputDigits` 在 `max(E+1,1)` 插点。若写出前导 `0` 且下一位不是 `.`，丢掉那个 `0`。
- **所有权 / 错误 / 调用**：返回新的输出游标；`jsDtoa` 用 `writtenLen` 收长度。零值不走这里。

### `dtoaFixed` (`src/libs/number_format.zig:1140`)

- **签名**：`fn dtoaFixed(tmp1: *MpbMax, mant_max: *MpbMax, m: u64, e: i32, E_in: i32, radix1: i32, radix_shift: i32, P: i32) i32`。
- **作用**：FORMAT_FIXED：`P` 位有效数字，必要时抬 `E`（`toPrecision` / `toExponential`）。
- **实现**：`mant_max = radix^P`。循环 `mulPowRound(..., RNDNA)` 直到 `tmp1 < mant_max`。
- **所有权 / 错误 / 调用**：返回调整后的 `E`；`tmp1` 留给 `outputHelper`。

### `jsDtoa` (`src/libs/number_format.zig:1155`)

- **签名**：`fn jsDtoa(buf: []u8, d: f64, radix: i32, n_digits: i32, flags: i32, tmp_mem: *JSDTOATempMem) usize`。
- **作用**：完整 dtoa 调度：特殊值、整数快路径、三种 format。
- **实现**：bump 出 `tmp1` 与 `mant_max`。拆 IEEE 位。Inf/NaN → `writeNonFinite`。零走 `outputHelper`。非规格化 `clz64` 规格化。FREE 且恰好是 ≤53-bit 整数且非强制指数：`u64toaRadix`。否则估 E，分派 `dtoaShortest` / `dtoaFrac` / `dtoaFixed`，FRAC 直接返回，其余 `outputHelper`。
- **所有权 / 错误 / 调用**：调用方保证 `buf` 够。返回已写长度。

## atod 阶段

### `toDigit` (`src/libs/number_format.zig:1235`)

- **签名**：`inline fn toDigit(c: u8) i32`。
- **作用**：ASCII → digit 值；非法返回 36（≥ 任何合法 radix，调用点一律用 `c >= radix` 判）。
- **实现**：`0-9` / `A-Z` / `a-z`。
- **所有权 / 错误 / 调用**：`jsAtod`、`parseAtodExponent`。

### `parseAtodExponent` (`src/libs/number_format.zig:1252`)

- **签名**：`fn parseAtodExponent(p: []const u8, p_start: []const u8, radix: i32, radix_bits: i32, flags: i32, sep: i32) AtodExp`。
- **作用**：吃可选的 `e`/`E`/`p`/`P`/`@` 指数。
- **实现**：`INT_ONLY`、空串、或还停在 `p_start` 则原样返回。十进制认 `e/E`；其它 radix 认 `@`，2 幂且 shift≤4 再认 `p/P`。指数无数字 → `invalid`。超 `i32` 记 `overflow`。
- **所有权 / 错误 / 调用**：`jsAtod`。`invalid` 时调用方把 `pnext` 退回 `p_start` 并返回 NaN。

### `atodToBits` (`src/libs/number_format.zig:1307`)

- **签名**：`fn atodToBits(tmp0: *MpbMax, radix: i32, radix1: i32, radix_shift: i32, radix_bits: i32, digit_count: i32, expn: i32, expn_offset: i32, expn_overflow: bool, is_bin_exp: bool, is_zero: bool) u64`。
- **作用**：已扫完的 digit 大数 → 无符号 IEEE 位。
- **实现**：零 → 0。指数溢出：负给 0，正给 Inf。2 幂 radix：把指数折成 bit，硬界 `1024+radix_bits` / `-1075`，再 `roundToD`。否则查 `max_exponent`/`min_exponent`，再 `mulPowRoundToD`。两臂都 `buildFloat64`。
- **所有权 / 错误 / 调用**：`jsAtod` 尾。不贴符号。

### `buildFloat64` (`src/libs/number_format.zig:1346`)

- **签名**：`fn buildFloat64(m: u64, e: i32) u64`。
- **作用**：mantissa+指数 → IEEE 位（无符号位）。
- **实现**：m=0 → 0；`e>1024` Inf；`e<-1073` 0；次正规右移；否则 `(e+1022)<<52 | (m & 52bit)`。
- **所有权 / 错误 / 调用**：`atodToBits`。

### `finishAtod` (`src/libs/number_format.zig:1356`)

- **签名**：`fn finishAtod(a: u64, is_neg: i32, p: []const u8, pnext: *?[*]const u8) f64`。
- **作用**：贴符号位、记录结束指针。
- **实现**：`a |= is_neg<<63`；`pnext.* = p.ptr`。
- **所有权 / 错误 / 调用**：atod 数值成功出口。

### `jsAtod` (`src/libs/number_format.zig:1366`)

- **签名**：`fn jsAtod(str: []const u8, pnext: *?[*]const u8, radix_arg: i32, flags: i32, tmp_mem: *JSATODTempMem) f64`。
- **作用**：字符串 → f64，对齐 `js_atod`。失败时返回 NaN 并把 `pnext` 退回 `p_start`（符号之后的起点），表示一个字符都没消费。
- **实现**：可选符号。前缀 `0x/0o/0b`、遗留八进制（遇到 8/9 则退回十进制）。`Infinity`。然后按 `digits_per_limb` 攒 `cur_limb` 再 `mpbMul1Base`；超过 `atod_max_digits_table` 的 digit 只推进 `pos` 并 OR 进 `extra_digits` 当 sticky。小数点由扫描循环处理。指数交给 `parseAtodExponent`。数值组装交给 `atodToBits`，`finishAtod` 贴符号。
- **所有权 / 错误 / 调用**：不抛 Zig error。不是 ToNumber。`parseNumber` 与 `formatRadix` 单测用它做反函数；`ACCEPT_*` / 非 10 radix 只被单测驱动。有效数字循环跳分隔符时有 `p.len > 1` 守卫。

## 覆盖核对

- 清单函数数: 64
- 本文标题覆盖: 64
- 未覆盖: 无
