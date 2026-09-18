# 19 — `src/libs/number_format.zig`

QuickJS `dtoa.c` / `dtoa.h` 的 Zig 移植，**两个方向都在这里，每个方向一个内核**。

- 格式化：`formatNumber`（最短）/ `formatRadix` / `formatDtoaChecked`（toFixed / toPrecision / toExponential）→ `floatToText`（`js_dtoa`）。radix 10 的 FORMAT_FREE 走 Ryu（`shortestDecimalRyu`，表 comptime 生成），数字串仍交同一个 `outputHelper` 排版；其余模式与 radix 走上游 bignum。std 替代不了：`std.fmt.float` 带精度时是对最短串二次舍入且 17 位后补零（`(1.005).toFixed(2)` 得 1.01、`(0.1).toPrecision(30)` 得零填充），也没有 radix 模式。
- 解析：`parseNumberPrefix` / `parseNumberExact` → `textToFloat`（`js_atod` 加上 `js_atof` 的符号 / 前缀 / 指数规则，一个扫描器服务所有调用方）。`ParseFlags` 选语法：ToNumber（`accept_bin_oct`）、parseInt（`int_only` + `accept_prefix_after_sign`）、parseFloat（radix 10、无 flag）、源码字面量（`accept_bin_oct` + `accept_underscores`）、JSON（无 flag）。

对上游的有意增补（格式化）：radix 10 shortest 用 Ryu 取代 `dtoaShortest` 从 17 位逐级下探的 bignum 试探，小数 90-150 ns → 30 ns，`1.79e308` 4.9 µs → 33 ns。**与 qjs 的一处可见差异**：2 的幂的舍入区间不对称，Ryu 找到真正最短的串（`2**-1017` 印 `7.120236347223045e-307`，与 V8 / JSC 相同），`dtoaShortest` 会多印一位；两者都能往返，规范要求位数最少。

对上游的有意增补（解析）：`textToFloat` 把前 `FAST_MANTISSA_DIGITS`（19）位有效十进制数字攒在 `u64` 里（8 位一组 SWAR + 紧循环），先走 Clinger 精确快路径或 Eisel-Lemire（`convertDecimalFast`），无法判定才进 bignum；dtoa.c 在此处自注 `XXX: add fast path for small integers`。接受 / 拒绝的字节与上游一致。

大数辅助（`mpb*`、`udiv1norm`、`mulPow`…）保留 dtoa.c 名字以便与上游对照；公开 API 与两个内核用 Zig 名字。无 heap 分配：调用方给输出缓冲，scratch 在 `FormatScratch` / `ParseScratch`。

```
formatNumber / formatRadix / formatDtoaChecked
  └─ floatToText
       ├─ writeNonFinite | integer fast path
       ├─ dtoaShortestDecimal（Ryu，radix 10）| dtoaShortest | dtoaFrac | dtoaFixed
       └─ outputDigits / outputHelper

parseNumberPrefix / parseNumberExact
  └─ textToFloat ─► parseExponent ─► convertDecimalFast（≤19 位、radix 10）
                                   └─► convertBignumToBits ─► buildFloat64（bignum）
```

## 类型与常量

| 符号 | 含义 |
| --- | --- |
| `FormatScratch` | `extern struct { mem: [37]u64 }`，`floatToText` 工作区（dtoa.c `FormatScratch`） |
| `ParseScratch` | `[27]u64`，`textToFloat` 工作区（`ParseScratch`），文件私有 |
| `JS_DTOA_FORMAT_{FREE,FIXED,FRAC}` | 自由最短 / 定点有效位 / 小数位 |
| `JS_DTOA_EXP_{AUTO,ENABLED,DISABLED}` | 科学计数 |
| `JS_DTOA_MINUS_ZERO` | 允许打印 `-0` |
| `ParseFlags` | packed struct：`int_only` / `accept_bin_oct` / `accept_legacy_octal` / `accept_underscores` / `accept_prefix_after_sign` / `accept_radix_fraction`（QuickJS `ATOD_*`） |
| `Parsed` | `{ value: f64, len: usize }`，`len == 0` 即没有数字 |
| `Mpb(cap)` | `extern struct { len: i32, tab: [cap]u32 }`，32-bit limb 大数 |
| `DtoaScale` | `{P, E}`，FREE 路径的有效位与指数 |
| `ExponentScan` | 指数扫描结果（含 overflow） |
| `LIMB_BITS=32`，`DBIGNUM_LEN_MAX=52`，`MANT_LEN_MAX=18` | 与 dtoa.c 一致 |
| `FAST_MANTISSA_DIGITS=19`，`CLINGER_MAX_EXP10=22`，`EL_Q_MIN/MAX=-342/308` | 快路径界限 |
| `clinger_pow10` | comptime `[23]f64`，10^0..10^22 |
| `el_pow5_128` | comptime 生成的 651 项 5^q 高 128 位表（与 fast_float / Zig std 表逐项一致） |
| `ryu_pow5_split` / `ryu_pow5_inv_split` | comptime 生成的 Ryu 表：5^i 高 125 位（326 项）与 2^k/5^i+1（342 项），与参考实现 `DOUBLE_POW5_SPLIT` / `DOUBLE_POW5_INV_SPLIT` 逐项一致 |
| `ShortestDecimal` | `{ mantissa: u64, exponent: i32 }`，Ryu 结果 |
| `JS_RNDN/RNDNA/RNDZ` | 就近偶 / 远离零 / 朝零 |
| 上游表 | `pow5_table`/`pow5h_table`/`pow5_inv_table`、`mul_log2_radix_table`、`digits_per_limb_table`、`radix_base_table`、`dtoa_max_digits_table`、`atod_max_digits_table`、`max_exponent`/`min_exponent` |

`fn Mpb` 是返回类型的 comptime 工厂，清单把它当函数。

## 公开 API

### `formatNumber` (`src/libs/number_format.zig:131`)

- **签名**：`pub fn formatNumber(buf: []u8, value: f64) ![]const u8`。
- **作用**：默认 `ToString` 十进制。
- **实现**：NaN/±Inf 返回静态切片。否则 FREE+EXP_AUTO 的 `floatToText`。
- **所有权 / 错误 / 调用**：返回 `buf[0..len]`。缓冲不够会越界——调用方应用 `radixMaxLen(10,…)` 或走 `formatDtoaChecked`。

### `formatInt32` (`src/libs/number_format.zig:141`)

- **签名**：`pub fn formatInt32(buf: []u8, value: i32) []const u8`。
- **作用**：int32 十进制。
- **实现**：`i32toa`。
- **所有权 / 错误 / 调用**：无 error。`buf` 至少 12 字节。

### `formatInt64` (`src/libs/number_format.zig:146`)

- **签名**：`pub fn formatInt64(buf: []u8, value: i64) []const u8`。
- **作用**：int64 十进制。
- **实现**：`i64toa`。
- **所有权 / 错误 / 调用**：`buf` 至少 21 字节。

### `radixMaxLen` (`src/libs/number_format.zig:155`)

- **签名**：`pub fn radixMaxLen(value: f64, radix: i32, n_digits: i32, flags: i32) !usize`。
- **作用**：`formatRadix` 写入上限（含一点余量）。
- **实现**：`floatToTextMaxLen+1`；负长度 `InvalidRadix`。
- **所有权 / 错误 / 调用**：radix 2 非规格化会过千字节，不能猜。

### `formatRadix` (`src/libs/number_format.zig:163`)

- **签名**：`pub fn formatRadix(buf: []u8, value: f64, radix: i32, n_digits: i32, flags: i32) ![]const u8`。
- **作用**：radix 2–36 的 `Number.prototype.toString`。
- **实现**：缓冲 < `radixMaxLen` → `NoSpaceLeft`。`floatToText`；`len>=buf.len` 再拒一次。
- **所有权 / 错误 / 调用**：digit 生成与十进制同一套 js_dtoa。

### `formatDtoaChecked` (`src/libs/number_format.zig:172`)

- **签名**：`pub fn formatDtoaChecked(buf: []u8, value: f64, n_digits: i32, flags: i32) ![]const u8`。
- **作用**：带长度检查的十进制 dtoa（toFixed 等）。
- **实现**：先 `floatToTextMaxLen(10,…)`，不够 `NoSpaceLeft`，再 `floatToText`。
- **所有权 / 错误 / 调用**：比 `formatNumber` 多固定/小数模式。

### `parseNumberPrefix` (`src/libs/number_format.zig:188`)

- **签名**：`pub fn parseNumberPrefix(text: []const u8, radix: u8, flags: ParseFlags) Parsed`。
- **作用**：QuickJS `js_atof`：解析 `text` 开头最长的数字，返回值与消费长度。
- **实现**：栈上 `ParseScratch`，调 `textToFloat`；结果 NaN 即「没有数字」，返回 `len = 0`；否则 `len = pnext - text.ptr`。
- **所有权 / 错误 / 调用**：不分配、不抛。空白由调用方先去掉，尾随字节是否算错误也由调用方定。`value_format.parseJsNumberTrimmed`、`number.parseIntLatin1Bytes` / `parseFloatLatin1Bytes`、`value_ops.bigIntToNumber`。

### `parseNumberExact` (`src/libs/number_format.zig:197`)

- **签名**：`pub fn parseNumberExact(text: []const u8, radix: u8, flags: ParseFlags) ?f64`。
- **作用**：必须吃完整串的 `parseNumberPrefix`。
- **实现**：`len != text.len` → null。
- **所有权 / 错误 / 调用**：lexer `parseNumberLiteral`、JSON `parseNumber`、ToNumber、本文件单测。

## Scratch 与 `Mpb`

### `Mpb` (`src/libs/number_format.zig:393`)

- **签名**：`fn Mpb(comptime cap: usize) type`。
- **作用**：生成带固定 `tab` 的 bignum 类型，替代 C flexible array。
- **实现**：返回 `extern struct { len: i32, tab: [cap]limb_t }`，内含 `tabSlice` / `tabConstSlice`。
- **所有权 / 错误 / 调用**：`MpbMax = Mpb(52)` 放在 bump arena 上，从不 `free`。

### `tabSlice` (`src/libs/number_format.zig:400`)

- **签名**：`fn tabSlice(self: *Self) []limb_t`。
- **作用**：可变 limb 窗口。
- **实现**：长度 `@max(self.len, 1)`，零值仍暴露 `tab[0]`。
- **所有权 / 错误 / 调用**：`mpMul1` 等原地写。

### `tabConstSlice` (`src/libs/number_format.zig:405`)

- **签名**：`fn tabConstSlice(self: *const Self) []const limb_t`。
- **作用**：只读窗口。
- **实现**：同 `tabSlice`。
- **所有权 / 错误 / 调用**：`mulPow` 读。

### `dtoaMalloc` (`src/libs/number_format.zig:414`)

- **签名**：`fn dtoaMalloc(comptime T: type, mptr: *[*]u64) *T`。
- **作用**：从临时 arena bump 出 `T`。
- **实现**：按 8 字节对齐推进 `mptr`。
- **所有权 / 错误 / 调用**：函数返回后整块丢弃，无 `free`。

### `writtenLen` (`src/libs/number_format.zig:421`)

- **签名**：`fn writtenLen(buf: []const u8, cursor: []const u8) usize`。
- **作用**：输出游标相对缓冲起点的已写长度。
- **实现**：指针差。
- **所有权 / 错误 / 调用**：`floatToText` / `outputHelper` / 整数 toa 共用。

### `minInt` (`src/libs/number_format.zig:425`)

- **签名**：`fn minInt(a: anytype, b: anytype) @TypeOf(a, b)`。
- **作用**：有符号最小（避免和 `@min` 的 usize 混用）。
- **实现**：`if (a < b) a else b`。
- **所有权 / 错误 / 调用**：dtoa 指数/位数裁剪。

### `maxInt` (`src/libs/number_format.zig:429`)

- **签名**：`fn maxInt(a: anytype, b: anytype) @TypeOf(a, b)`。
- **作用**：有符号最大。
- **实现**：`if (a > b) a else b`。
- **所有权 / 错误 / 调用**：FRAC 格式总位数。

### `clz32` (`src/libs/number_format.zig:433`)

- **签名**：`inline fn clz32(a: u32) i32`。
- **作用**：32-bit 前导零，返回 i32 以匹配 C `clz`。
- **实现**：`@intCast(@clz(a))`。
- **所有权 / 错误 / 调用**：`mpbFloorLog2`、radix bit 数。

### `clz64` (`src/libs/number_format.zig:437`)

- **签名**：`inline fn clz64(a: u64) i32`。
- **作用**：64-bit 前导零。
- **实现**：`@clz`。
- **所有权 / 错误 / 调用**：非规格化 float 规格化。

### `ctz32` (`src/libs/number_format.zig:441`)

- **签名**：`inline fn ctz32(a: u32) i32`。
- **作用**：尾零，用来把 radix 拆成 `radix1 * 2^shift`。
- **实现**：`@ctz`。
- **所有权 / 错误 / 调用**：`floatToText` / `textToFloat`。

### `float64AsUint64` (`src/libs/number_format.zig:445`)

- **签名**：`inline fn float64AsUint64(d: f64) u64`。
- **作用**：IEEE 位型。
- **实现**：`@bitCast`。
- **所有权 / 错误 / 调用**：拆符号/指数/尾数。

### `uint64AsFloat64` (`src/libs/number_format.zig:449`)

- **签名**：`inline fn uint64AsFloat64(u: u64) f64`。
- **作用**：位型 → f64。
- **实现**：`@bitCast`。
- **所有权 / 错误 / 调用**：`finishParse`。

## Limb 算术

### `mpAddUi` (`src/libs/number_format.zig:457`)

- **签名**：`fn mpAddUi(tab: []limb_t, b: limb_t) limb_t`。
- **作用**：切片加单 limb，返回最终进位。
- **实现**：`+%` 循环，进位为零提前停。
- **所有权 / 错误 / 调用**：`mpbShrRound` 进 1。

### `mpMul1` (`src/libs/number_format.zig:468`)

- **签名**：`fn mpMul1(tabr: []limb_t, taba: []const limb_t, b: limb_t, carry: limb_t) limb_t`。
- **作用**：`tabr = taba * b + carry`，返回高 limb。
- **实现**：64-bit 乘加。
- **所有权 / 错误 / 调用**：`mulPow` 正幂、`mpbMul1Base`。

### `udiv1normInit` (`src/libs/number_format.zig:478`)

- **签名**：`fn udiv1normInit(d: limb_t) limb_t`。
- **作用**：归一化除数的倒数近似。
- **实现**：`(~d << 32 | 0xFFFFFFFF) / d`。
- **所有权 / 错误 / 调用**：`powUiInv`。

### `udiv1norm` (`src/libs/number_format.zig:485`)

- **签名**：`fn udiv1norm(pr: *limb_t, a1: limb_t, a0: limb_t, d: limb_t, d_inv: limb_t) limb_t`。
- **作用**：`[a1:a0] / d`，余数写入 `pr`。
- **实现**：Granlund–Montgomery 风格修正。
- **所有权 / 错误 / 调用**：`mpDiv1norm`。

### `mpDiv1` (`src/libs/number_format.zig:499`)

- **签名**：`fn mpDiv1(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t) limb_t`。
- **作用**：从高到低除以单 limb。
- **实现**：64-bit `/` `%`。
- **所有权 / 错误 / 调用**：非 2 幂 `outputDigits`。

### `mpShr` (`src/libs/number_format.zig:511`)

- **签名**：`fn mpShr(tab_r: []limb_t, tab: []const limb_t, shift: u5, high: limb_t) limb_t`。
- **作用**：limb 切片右移。
- **实现**：高位灌入 `high`，返回移出的低位。
- **所有权 / 错误 / 调用**：`mpbShrRound`。

### `mpShl` (`src/libs/number_format.zig:523`)

- **签名**：`fn mpShl(tab_r: []limb_t, tab: []const limb_t, shift: u5, low: limb_t) limb_t`。
- **作用**：limb 切片左移。
- **实现**：低位灌入 `low`，返回溢出高位。
- **所有权 / 错误 / 调用**：`mpbShrRound` 负移、`mpDiv1norm`。

### `mpDiv1norm` (`src/libs/number_format.zig:532`)

- **签名**：`fn mpDiv1norm(tabr: []limb_t, taba: []const limb_t, b: limb_t, r_in: limb_t, b_inv: limb_t, shift: i32) limb_t`。
- **作用**：归一化单 limb 除（可先左移对齐）。
- **实现**：可选 `mpShl` 后逐 limb `udiv1norm`，再把余数右移回来。
- **所有权 / 错误 / 调用**：`mulPow` 负幂。

### `mpbRenorm` (`src/libs/number_format.zig:550`)

- **签名**：`fn mpbRenorm(r: *MpbMax) void`。
- **作用**：去掉高位零 limb，至少留 1。
- **实现**：`while len>1 and tab[len-1]==0`。
- **所有权 / 错误 / 调用**：几乎所有写 `Mpb` 的路径。

### `mpbGetBit` (`src/libs/number_format.zig:556`)

- **签名**：`fn mpbGetBit(r: *const MpbMax, k: i32) i32`。
- **作用**：取第 `k` 位（0=LSB）。
- **实现**：越界当 0。
- **所有权 / 错误 / 调用**：`mpbShrRound` 的 0.5-bit / LSB。

### `mpbShrRound` (`src/libs/number_format.zig:566`)

- **签名**：`fn mpbShrRound(r: *MpbMax, shift: i32, rnd_mode: i32) void`。
- **作用**：带舍入的大数移位；负 `shift` 是左移。
- **实现**：左移按 limb + bit。右移：`RNDZ` 截断；`RNDN` 看 0.5-bit 与 sticky，平局 round-to-even；`RNDNA` 平局远离零。然后 limb 右移，必要时 `mpAddUi(1)`。
- **所有权 / 错误 / 调用**：`mulPow` / `roundToD` / `outputDigits`。

### `mpbCmp` (`src/libs/number_format.zig:660`)

- **签名**：`fn mpbCmp(a: *const MpbMax, b: *const MpbMax) i32`。
- **作用**：比较幅度。
- **实现**：先比 `len`，再从高 limb 比。
- **所有权 / 错误 / 调用**：`dtoaFixed`。

### `mpbSetU64` (`src/libs/number_format.zig:674`)

- **签名**：`fn mpbSetU64(r: *MpbMax, m: u64) void`。
- **作用**：写入 1–2 个 limb。
- **实现**：高 limb 为 0 则 `len=1`。
- **所有权 / 错误 / 调用**：`mulPowRound`、FREE 回写 mantissa。

### `mpbGetU64` (`src/libs/number_format.zig:684`)

- **签名**：`fn mpbGetU64(r: *const MpbMax) u64`。
- **作用**：读回低 64 bit。
- **实现**：`len==1` 只取 `tab[0]`。
- **所有权 / 错误 / 调用**：假定值已收进 64 bit。

### `mpbFloorLog2` (`src/libs/number_format.zig:691`)

- **签名**：`fn mpbFloorLog2(a: *const MpbMax) i32`。
- **作用**：`floor(log2(a))`。
- **实现**：`(len*32-1) - clz32(最高 limb)`；最高为 0 返回 -1。
- **所有权 / 错误 / 调用**：`mulPow` extra_bits、`roundToD`。

### `mpbMul1Base` (`src/libs/number_format.zig:697`)

- **签名**：`fn mpbMul1Base(r: *MpbMax, radix_base: limb_t, a: limb_t) void`。
- **作用**：`r = r * radix_base + a`；`radix_base==0` 表示乘 `2^32`（左移一个 limb）。
- **实现**：零值直接写 `a`；否则 `mpMul1` 或整表上移。
- **所有权 / 错误 / 调用**：`textToFloat` 攒 digit。

## 幂与对数

### `mulLog2Radix` (`src/libs/number_format.zig:720`)

- **签名**：`fn mulLog2Radix(a: i32, radix: i32) i32`。
- **作用**：近似 `a * log2(radix)`，用来估十进制/任意进制指数 `E`。
- **实现**：2 幂直接除 bit 数；否则查表定点乘。
- **所有权 / 错误 / 调用**：`floatToTextMaxLen`、`floatToText` 三种 format 共用的初始 E。

### `powUi` (`src/libs/number_format.zig:731`)

- **签名**：`fn powUi(radix: u32, n: u32) u64`。
- **作用**：`radix^n`（保证不溢出 u64 的调用点）。
- **实现**：5/10 且 n≤17 走 `pow5_table`（10 再左移 n）；否则平方倍增。
- **所有权 / 错误 / 调用**：`mulPow`、FREE 的 `mant_max1`。

### `powUiInv` (`src/libs/number_format.zig:758`)

- **签名**：`fn powUiInv(pr_inv: *u32, pshift: *i32, a: u32, b: u32) u32`。
- **作用**：返回规范化的 `a^b`，写出倒数与 shift。
- **实现**：5 的 1..13 次方走表；否则 `powUi` + `clz` + `udiv1normInit`。
- **所有权 / 错误 / 调用**：`mulPow` 负幂。

## 整数 ASCII

### `u32toaLen` (`src/libs/number_format.zig:781`)

- **签名**：`fn u32toaLen(buf: []u8, n: u32, len: usize) void`。
- **作用**：把 `n` 写成恰好 `len` 位十进制（左补零）。
- **实现**：从右往左 `%10`。
- **所有权 / 错误 / 调用**：`limbToA`、`u64toa` 的 9 位块。

### `u64toaBinLen` (`src/libs/number_format.zig:791`)

- **签名**：`fn u64toaBinLen(buf: []u8, n: u64, radix_bits: u5, len: usize) void`。
- **作用**：2 幂 radix 定长写 digit。
- **实现**：掩码取低 `radix_bits`，`0-9a-z`。
- **所有权 / 错误 / 调用**：`outputDigits`、`u64toaRadix`。

### `limbToA` (`src/libs/number_format.zig:807`)

- **签名**：`fn limbToA(buf: []u8, n: limb_t, radix: i32, len: i32) void`。
- **作用**：一个 32-bit limb 写成 `len` 个 radix digit。
- **实现**：10 走 `u32toaLen`，否则 `% radix`。
- **所有权 / 错误 / 调用**：直接写目标缓冲（修过 radix 3 的 20 digit 栈溢出）。

### `u32toa` (`src/libs/number_format.zig:829`)

- **签名**：`fn u32toa(buf: []u8, n: u32) usize`。
- **作用**：最短十进制，返回长度。
- **实现**：栈上 `[10]u8` 倒填再 memcpy。
- **所有权 / 错误 / 调用**：`formatInt32`、指数。

### `i32toa` (`src/libs/number_format.zig:844`)

- **签名**：`fn i32toa(buf: []u8, n: i32) usize`。
- **作用**：有符号 32-bit。
- **实现**：负则写 `-` 再对 wrapping-neg 的位型调 `u32toa`（覆盖 `minInt`）。
- **所有权 / 错误 / 调用**：`formatInt32`。

### `u64toa` (`src/libs/number_format.zig:852`)

- **签名**：`fn u64toa(buf: []u8, n: u64) usize`。
- **作用**：最短十进制 u64。
- **实现**：<2^32 走 u32。否则按 10^9 块切，可能三块。
- **所有权 / 错误 / 调用**：长度用 `writtenLen`。

### `i64toa` (`src/libs/number_format.zig:890`)

- **签名**：`fn i64toa(buf: []u8, n: i64) usize`。
- **作用**：有符号 64-bit。
- **实现**：同 `i32toa` 的 wrapping 负。
- **所有权 / 错误 / 调用**：`formatInt64`。

### `u64toaRadix` (`src/libs/number_format.zig:898`)

- **签名**：`fn u64toaRadix(buf: []u8, n: u64, radix: u32) usize`。
- **作用**：任意 radix 2–36 写 u64。
- **实现**：10 走 `u64toa`；2 幂算 bit 长后 `u64toaBinLen`；否则栈 `[65]u8` 反复 `%`。
- **所有权 / 错误 / 调用**：整数快路径 `floatToText`。

## 换基与舍入

### `mulPow` (`src/libs/number_format.zig:936`)

- **签名**：`fn mulPow(a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, is_int: bool, e: i32) i32`。
- **作用**：把 `a` 乘/除 `radix^f`（radix = radix1×2^shift），返回额外指数偏移。
- **实现**：`radix1==1` 只记账。`f>=0` 按 limb 组 `powUi`+`mpMul1`。`f<0` 先左移 `l*32+extra_bits`（`mpbShrRound` 负移，RNDZ）再逐组 `powUiInv`+`mpDiv1norm` 倒数除，余数非零把 `tab[0]` 的最低位置 1（sticky）。
- **所有权 / 错误 / 调用**：dtoa/atod 的 radix 转换。

### `mulPowRound` (`src/libs/number_format.zig:997`)

- **签名**：`fn mulPowRound(tmp1: *MpbMax, m: u64, e: i32, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) void`。
- **作用**：从 float mantissa `m×2^e` 转到 radix 定点并舍入。
- **实现**：`mpbSetU64`、`mulPow(..., is_int=true)`、`mpbShrRound(-e+e_offset)`。
- **所有权 / 错误 / 调用**：FREE/FIXED/FRAC。

### `roundToD` (`src/libs/number_format.zig:1003`)

- **签名**：`fn roundToD(pe: *i32, a: *MpbMax, e_offset: i32, rnd_mode: i32) u64`。
- **作用**：把大数舍入成 53-bit mantissa，写出二进制指数。
- **实现**：零 → 0。算 `e_val`，次正规缩 precision，`mpbShrRound`，左对齐到 53 bit，溢出则右移并 `e++`。
- **所有权 / 错误 / 调用**：atod 最终组装；2 幂 radix 的 `convertBignumToBits`。

### `mulPowRoundToD` (`src/libs/number_format.zig:1033`)

- **签名**：`fn mulPowRoundToD(pe: *i32, a: *MpbMax, radix1: i32, radix_shift: i32, f: i32, rnd_mode: i32) u64`。
- **作用**：radix 定点 → binary64 mantissa。
- **实现**：`mulPow(..., is_int=false, e=55)` 再 `roundToD`。
- **所有权 / 错误 / 调用**：FREE 格式 round-trip 验证；`convertBignumToBits` 的非 2 幂 radix 臂。

## 出字

### `outputDigits` (`src/libs/number_format.zig:1042`)

- **签名**：`fn outputDigits(buf: []u8, a: *MpbMax, radix: i32, n_digits1: i32, dot_pos: i32) usize`。
- **作用**：把 mantissa 写成 `n_digits` 个 digit，可在 `dot_pos` 插 `.`。
- **实现**：2 幂：反复取出低 `digits_per_limb` 位再 `mpbShrRound(..., RNDZ)`。否则 `mpDiv1` 除 `radix_base`，`limbToA` 直写。最后 `copyBackwards` 插小数点。
- **所有权 / 错误 / 调用**：破坏 `a`。`outputHelper` / `dtoaFrac`。

### `outputHelper` (`src/libs/number_format.zig:1090`)

- **签名**：`fn outputHelper(q_start: []u8, buf_start: []u8, tmp1: *MpbMax, radix: i32, radix1: i32, radix_shift: i32, P: i32, E: i32, n_digits: i32, flags: i32) usize`。
- **作用**：按 E 选择定点或科学计数，写 digit 与指数标记。
- **实现**：强制指数或 `E<=-6` 或 `E>E_max`：`outputDigits` 在第一位后插点，radix 10 用 `e`、2 幂小 shift 用 `p`（指数改 bit）、否则 `@`。`E<=0` 写 `0.`+前导零。否则整数部分 + 尾零。
- **所有权 / 错误 / 调用**：长度相对 `buf_start`。

## dtoa 阶段

### `floatToTextMaxLen` (`src/libs/number_format.zig:1163`)

- **签名**：`fn floatToTextMaxLen(d: f64, radix: i32, n_digits: i32, flags: i32) i32`。
- **作用**：输出上限（不含 NUL），给调用方定缓冲。
- **实现**：FREE 用 `dtoa_max_digits_table`。`EXP_DISABLED` 按指数加整数位。FRAC 按 `e<0` 的前导零。NaN/Inf 走 `n=0` 再 `max(n,9)`。
- **所有权 / 错误 / 调用**：`radixMaxLen`、`formatDtoaChecked`。radix 2 + 非规格化可超一千 digit。

### `writeNonFinite` (`src/libs/number_format.zig:1203`)

- **签名**：`fn writeNonFinite(buf: []u8, sgn: i32, frac: u64) usize`。
- **作用**：写 `NaN` / `Infinity` / `-Infinity`。
- **实现**：`frac==0` 为 Inf（负号按 `sgn`）；否则 `NaN` 不带符号。
- **所有权 / 错误 / 调用**：`floatToText` 的 `e==0x7ff` 臂。

### `ryuMulShift64` (`src/libs/number_format.zig:1222`)

- **签名**：`inline fn ryuMulShift64(m: u64, mul: [2]u64, j: u32) u64`。
- **作用**：`(m × mul) >> j` 的 64 位结果，`mul` 是 125 位表项（低字、高字）。
- **实现**：两次 u128 乘，`(b0 >> 64) + b2` 再右移 `j − 64`。
- **所有权 / 错误 / 调用**：binary64 下 `j` 恒在 (64, 128)。`shortestDecimalRyu`。

### `ryuLog10Pow2` (`src/libs/number_format.zig:1229`)

- **签名**：`inline fn ryuLog10Pow2(e: u32) u32`。
- **作用**：`floor(log10(2^e))`。
- **实现**：定点乘 `169464822037455 >> 49`。
- **所有权 / 错误 / 调用**：`e ≤ 2^15` 内精确。

### `ryuLog10Pow5` (`src/libs/number_format.zig:1233`)

- **签名**：`inline fn ryuLog10Pow5(e: u32) u32`。
- **作用**：`floor(log10(5^e))`。
- **实现**：定点乘 `196742565691928 >> 48`。
- **所有权 / 错误 / 调用**：同上。

### `ryuPow5Bits` (`src/libs/number_format.zig:1237`)

- **签名**：`inline fn ryuPow5Bits(e: u32) u32`。
- **作用**：`5^e` 的位长（`ceil(log2(5^e))`，e=0 给 1）。
- **实现**：定点乘 `163391164108059 >> 46` 加一。
- **所有权 / 错误 / 调用**：算表项对应的移位量。

### `ryuPow5Factor` (`src/libs/number_format.zig:1241`)

- **签名**：`fn ryuPow5Factor(value_in: u64) u32`。
- **作用**：`value` 里 5 的幂次。
- **实现**：循环除 5 到余数非零。
- **所有权 / 错误 / 调用**：`ryuMultipleOfPowerOf5`。

### `ryuMultipleOfPowerOf5` (`src/libs/number_format.zig:1253`)

- **签名**：`inline fn ryuMultipleOfPowerOf5(value: u64, p: u32) bool`。
- **作用**：`5^p | value`。
- **实现**：`ryuPow5Factor(value) >= p`。
- **所有权 / 错误 / 调用**：判定区间端点是否恰好落在十进制格点上（尾零跟踪）。

### `ryuMultipleOfPowerOf2` (`src/libs/number_format.zig:1257`)

- **签名**：`inline fn ryuMultipleOfPowerOf2(value: u64, p: u32) bool`。
- **作用**：`2^p | value`。
- **实现**：低 `p` 位为零。
- **所有权 / 错误 / 调用**：负指数分支的尾零判定。

### `shortestDecimalRyu` (`src/libs/number_format.zig:1266`)

- **签名**：`fn shortestDecimalRyu(bits: u64) ShortestDecimal`。
- **作用**：有限非零 binary64（原始 IEEE 位）的最短往返十进制 `mantissa × 10^exponent`，同长度里取最接近，精确半程取偶。Adams 2018 `d2d` 的结构。
- **实现**：拆出 `m2`/`e2`（次正规 `e2 = −1076`），`mv = 4·m2`，`mm_shift` 记录下界是否与上界等距（尾数非零或指数 ≤ 1）。`e2 ≥ 0` 用 `ryu_pow5_inv_split[q]`，否则 `ryu_pow5_split[i]`，`ryuMulShift64` 一次算出 `vr/vp/vm` 三个缩放值；`q ≤ 21`（或负指数 `q ≤ 1`、`q < 63`）时用 5 幂 / 2 幂整除判定标记尾零。然后在 `vp/10 > vm/10` 时去尾位；需要尾零跟踪的罕见分支多一轮 `vm % 10 == 0` 收缩并处理精确半程；常见分支只记最后去掉的一位。`vr == vm` 或最后一位 ≥ 5 进一。
- **所有权 / 错误 / 调用**：不分配、无表以外的状态。`dtoaShortestDecimal`。2000 万随机 double 与 std Ryu 数字/指数零差异，与旧 `dtoaShortest` 整串仅在 2 的幂上不同（见文件头）。

### `dtoaShortestDecimal` (`src/libs/number_format.zig:1376`)

- **签名**：`fn dtoaShortestDecimal(tmp1: *MpbMax, bits: u64) DtoaScale`。
- **作用**：radix 10 的 FORMAT_FREE：Ryu 结果换成 `dtoaShortest` 的契约。
- **实现**：`shortestDecimalRyu` 后去尾零；`P` = 位数，`E = exponent + P`（值 = digits × 10^(E−P)）；`mpbSetU64(tmp1, mantissa)`。
- **所有权 / 错误 / 调用**：`floatToText` FREE 臂 radix 10；后续 `outputHelper` 与 bignum 路径完全相同。

### `dtoaShortest` (`src/libs/number_format.zig:1389`)

- **签名**：`fn dtoaShortest(tmp1: *MpbMax, m: u64, e: i32, radix: i32, radix1: i32, radix_shift: i32) DtoaScale`。
- **作用**：FORMAT_FREE：最短且能 round-trip 回 `(m, e)` 的 digit 串。
- **实现**：从 `P_max` 往下试。内层把 `E` 抬到 `mant < radix^P`。去掉尾零。第一次成功只记账；之后 `mulPowRoundToD` 验 round-trip，失败就停。结果写回 `tmp1`。
- **所有权 / 错误 / 调用**：`floatToText` 的 FREE 臂，现只剩 radix ≠ 10（`toString(radix)`）；radix 10 走 `dtoaShortestDecimal`。已去掉上游那次结果未使用的 `powUi` 调用。

### `dtoaFrac` (`src/libs/number_format.zig:1438`)

- **签名**：`fn dtoaFrac(q: []u8, tmp1: *MpbMax, m: u64, e: i32, E: i32, radix: i32, radix1: i32, radix_shift: i32, n_digits: i32) []u8`。
- **作用**：FORMAT_FRAC：小数点后 `n_digits` 位（`toFixed`）。
- **实现**：`mulPowRound(..., RNDNA)`，`outputDigits` 在 `max(E+1,1)` 插点。若写出前导 `0` 且下一位不是 `.`，丢掉那个 `0`。
- **所有权 / 错误 / 调用**：返回新的输出游标；`floatToText` 用 `writtenLen` 收长度。零值不走这里。

### `dtoaFixed` (`src/libs/number_format.zig:1451`)

- **签名**：`fn dtoaFixed(tmp1: *MpbMax, mant_max: *MpbMax, m: u64, e: i32, E_in: i32, radix1: i32, radix_shift: i32, P: i32) i32`。
- **作用**：FORMAT_FIXED：`P` 位有效数字，必要时抬 `E`（`toPrecision` / `toExponential`）。
- **实现**：`mant_max = radix^P`。循环 `mulPowRound(..., RNDNA)` 直到 `tmp1 < mant_max`。
- **所有权 / 错误 / 调用**：返回调整后的 `E`；`tmp1` 留给 `outputHelper`。

### `floatToText` (`src/libs/number_format.zig:1466`)

- **签名**：`fn floatToText(buf: []u8, d: f64, radix: i32, n_digits: i32, flags: i32, tmp_mem: *FormatScratch) usize`。
- **作用**：完整 dtoa 调度：特殊值、整数快路径、三种 format。
- **实现**：bump 出 `tmp1` 与 `mant_max`。拆 IEEE 位。Inf/NaN → `writeNonFinite`。零走 `outputHelper`。非规格化 `clz64` 规格化。FREE 且恰好是 ≤53-bit 整数且非强制指数：`u64toaRadix`。否则估 E，分派 `dtoaShortestDecimal`（FREE 且 radix 10，直接用原始位 `a`）/ `dtoaShortest` / `dtoaFrac` / `dtoaFixed`，FRAC 直接返回，其余 `outputHelper`。
- **所有权 / 错误 / 调用**：调用方保证 `buf` 够。返回已写长度。

## 解析阶段

### `toDigit` (`src/libs/number_format.zig:1565`)

- **签名**：`inline fn toDigit(c: u8) i32`。
- **作用**：ASCII → digit 值；非法返回 36（≥ 任何合法 radix，调用点一律用 `c >= radix` 判）。
- **实现**：`0-9` / `A-Z` / `a-z`。
- **所有权 / 错误 / 调用**：`textToFloat`、`parseExponent`。

### `parseExponent` (`src/libs/number_format.zig:1581`)

- **签名**：`fn parseExponent(p: []const u8, p_start: []const u8, radix: i32, radix_bits: i32, flags: ParseFlags, sep: i32) ExponentScan`。
- **作用**：吃可选的 `e`/`E`（radix 10）或 `@`/`p`/`P`（非十进制，仅 `accept_radix_fraction`）指数。
- **实现**：`int_only`、空串、或还停在 `p_start` 则原样返回。指数标记后没有数字 → 不消费标记，按 `js_atof` 的规则数字到此为止（`parseFloat("1e")` 是 1；dtoa.c 自己那条 `goto fail` 永远看不到这种输入）。超 `i32` 记 `overflow`。
- **所有权 / 错误 / 调用**：`textToFloat`。

### `convertBignumToBits` (`src/libs/number_format.zig:1757`)

- **签名**：`fn convertBignumToBits(tmp0: *MpbMax, radix: i32, radix1: i32, radix_shift: i32, radix_bits: i32, digit_count: i32, expn: i32, expn_offset: i32, expn_overflow: bool, is_bin_exp: bool, is_zero: bool) u64`。
- **作用**：已扫完的 digit 大数 → 无符号 IEEE 位。
- **实现**：零 → 0。指数溢出：负给 0，正给 Inf。2 幂 radix：把指数折成 bit，硬界 `1024+radix_bits` / `-1075`，再 `roundToD`。否则查 `max_exponent`/`min_exponent`，再 `mulPowRoundToD`。两臂都 `buildFloat64`。
- **所有权 / 错误 / 调用**：`textToFloat` 尾，只在 `convertDecimalFast` 不接手时（非十进制、超过 19 位、Eisel-Lemire 无法判定）。不贴符号。

### `buildFloat64` (`src/libs/number_format.zig:1796`)

- **签名**：`fn buildFloat64(m: u64, e: i32) u64`。
- **作用**：mantissa+指数 → IEEE 位（无符号位）。
- **实现**：m=0 → 0；`e>1024` Inf；`e<-1073` 0；次正规右移；否则 `(e+1022)<<52 | (m & 52bit)`。
- **所有权 / 错误 / 调用**：`convertBignumToBits`。

### `finishParse` (`src/libs/number_format.zig:1806`)

- **签名**：`fn finishParse(a: u64, is_neg: i32, p: []const u8, pnext: *?[*]const u8) f64`。
- **作用**：贴符号位、记录结束指针。
- **实现**：`a |= is_neg<<63`；`pnext.* = p.ptr`。
- **所有权 / 错误 / 调用**：解析成功出口，快路径与 bignum 路径共用。

### `textToFloat` (`src/libs/number_format.zig:1816`)

- **签名**：`fn textToFloat(str: []const u8, pnext: *?[*]const u8, radix_arg: u8, flags: ParseFlags, tmp_mem: *ParseScratch) f64`。
- **作用**：字符串 → f64 内核：dtoa.c `js_atod` 的扫描与 bignum 转换，并入 `js_atof` 的规则（符号后前缀只在 `accept_prefix_after_sign`；小数与指数只在 radix 10，除非 `accept_radix_fraction`）。失败返回 NaN 且 `pnext` 退回 `str.ptr`。
- **实现**：可选符号。前缀 `0x`（radix 0/16）、`0o`/`0b`（`accept_bin_oct`）、遗留八进制（`accept_legacy_octal`，遇 8/9 退回十进制）；普通 `0…` 走 `no_prefix`（上游 `goto no_prefix`，移植时曾漏掉这条分支）。`Infinity`（非 `int_only`）。前导零循环记 `sig_pos`。有效数字循环：radix 10 先把连续数字字节吞进 `mant`（8 位 SWAR `isEightAsciiDigits`/`parseEightAsciiDigits`，再单字节），满 19 位后由 `replayMantissa` 回放进 `tmp0`，之后按上游 `digits_per_limb` 攒 `cur_limb` 再 `mpbMul1Base`；超过 `atod_max_digits_table` 的 digit 只推进 `pos` 并 OR 进 `extra_digits`。指数交给 `parseExponent`。radix 10 且 ≤19 位：`convertDecimalFast`，成功即 `finishParse`；否则把 `mant` 回放进 `tmp0`，交 `convertBignumToBits`。
- **所有权 / 错误 / 调用**：不抛 Zig error。唯一调用方 `parseNumberPrefix`。有效数字循环跳分隔符时有 `p.len > 1` 守卫。

### `isEightAsciiDigits` (`src/libs/number_format.zig:1547`)

- **签名**：`inline fn isEightAsciiDigits(v: u64) bool`。
- **作用**：小端读入的 8 字节是否全为 `'0'..'9'`。
- **实现**：`(v + 0x46…) | (v - 0x30…)` 的高位掩码为零。
- **所有权 / 错误 / 调用**：`textToFloat` 的 radix 10 数字块。

### `parseEightAsciiDigits` (`src/libs/number_format.zig:1556`)

- **签名**：`inline fn parseEightAsciiDigits(v_in: u64) u64`。
- **作用**：8 个 ASCII 数字（首字节最高位）→ 整数。
- **实现**：标准 SWAR 归约：减 `0x30…`，两两、四四、两半三步乘加。
- **所有权 / 错误 / 调用**：前置条件 `isEightAsciiDigits`。

### `replayMantissa` (`src/libs/number_format.zig:1730`)

- **签名**：`fn replayMantissa(tmp0: *MpbMax, mant: u64, digit_count: i32, cur_limb: *limb_t, limb_digit_count: *i32) void`。
- **作用**：把 `mant` 里的 `digit_count` 位十进制数字按上游 limb 循环的调用序列回放进 `tmp0`。
- **实现**：每 9 位一次 `mpbMul1Base(tmp0, 1e9, limb)`，最高位先；不足 9 位的尾组留在 `cur_limb` / `limb_digit_count`。
- **所有权 / 错误 / 调用**：保证 bignum 状态与上游逐位构造位级一致。第 20 位到来时与快路径放弃时各调一次。

### `convertClinger` (`src/libs/number_format.zig:1642`)

- **签名**：`fn convertClinger(mant: u64, exp10: i32) ?u64`。
- **作用**：`mant * 10^exp10` 两个操作数都是精确 binary64 时，一次 IEEE 乘除就是唯一一次舍入（Clinger 1990）。
- **实现**：`mant ≤ 2^53` 且 `|exp10| ≤ 22`；`exp10 > 22` 时先把数字移进 mantissa：移位量 ≤ 15（10^16 已超 2^53），`@mulWithOverflow` 检查后仍 ≤ 2^53 才行。曾用 f64 表转 u64 取 10^shift，shift ≥ 20 越界，由往返单测抓出。
- **所有权 / 错误 / 调用**：null 交给 Eisel-Lemire。

### `convertEiselLemire` (`src/libs/number_format.zig:1671`)

- **签名**：`fn convertEiselLemire(q: i32, w_in: u64) ?u64`。
- **作用**：任意 64 位 `w` 乘 `10^q` 的 binary64 位（Lemire 2021 §5-6）。
- **实现**：`w` 规格化；查 `el_pow5_128` 做 128 位近似积，低字不够精确再乘第二字；`lo == 0xffff…` 且 q 不在 [-27, 55] 返回 null。次正规单独处理。精确半程且偶数基（`lo ≤ 1`，q 在 [-4, 23]）不进位。结构照 fast_float 参考实现，高低字次序是 `pow5[0]` 高字先乘。
- **所有权 / 错误 / 调用**：null 表示需要 bignum 裁决。

### `convertDecimalFast` (`src/libs/number_format.zig:1752`)

- **签名**：`fn convertDecimalFast(mant: u64, exp10: i32) ?u64`。
- **作用**：≤19 位十进制的快路径分派。
- **实现**：先 `convertClinger`，再 `convertEiselLemire`。
- **所有权 / 错误 / 调用**：`textToFloat`；null 即回退 bignum。

## 覆盖核对

- 清单函数数: 64
- 本文标题覆盖: 64
- 未覆盖: 无
