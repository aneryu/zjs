# STRING-SLACK-CENSUS — 字符串追加余量命中上限

日期：2026-08-17。**只析不改。** 工装在 `/tmp/wt-string-slack`（`grok/string-slack-census` @ `main@553840ab`），**没有** rebase 历史分支 `grok/opt-r2-h2-recon`（落后 main 两千余提交），按令 **重植钩子**。

| | |
|---|---|
| 工装源 | `~/worktree-grok-h2-recon` `concat_census.zig` @ `59fa9b5e` |
| 重植 | `/tmp/wt-string-slack`，钩在 `stringAddStringsOwned` + `startAccumulatorRope` |
| 开关 | `ZJS_CONCAT_CENSUS=1`，退出 dump stderr |
| 语料 | 官方 zoo 15 凳 `/home/aneryu/javascript-zoo/bench/*.js`（自打分） |
| 核 | **CPU 8**（避 5/6/7/15/16/19） |
| 原始 | `/tmp/string-slack-census/{bench}.census.txt` + `all.json` |

---

## 0. 一句话

pdfjs 是唯一能把「原地臂」说到 **G 周期** 的凳：2.32M 次独占 flat+flat 追加里，按 16/24/32/48/64/96/128… 几何类仿真 **99.11% 命中**，省掉的 lhs 拷贝 **6.85 GB**。同二进制 pdfjs **4.32 G cyc**；可行上限约 **2.0–4.3 G cyc**（拷贝 0.3 c/B ≈ 48% 本凳，1.0 c/B 公式会超过全凳，封顶到实测）。  
严格 `rc==1` 在 pdfjs 只有 2.4 万发（0.9%）；zjs 独占累加器在钩子上是 **rc==2/3**（槽 + transient dup）。qjs `JS_ConcatStringInPlace` 看 rc==1，是因为它不持有这些额外引用。

---

## 1. 工装

`grok/opt-r2-h2-recon` 的 census 只计 lhs rope / flat-rc1 / empty，**没有** rhs 是否 flat、追加字节、余量仿真。本役扩展：

| 计数 | 含义 |
|---|---|
| `add_total` | 进入 `stringAddStringsOwned` |
| `add_flat_flat` | 两侧都是非空 flat |
| `add_flat_flat_rc1` | 令面「lhs rc==1」 |
| `add_flat_flat_rc_le3` | zjs 独占（rc≤3 = 槽+dup 通胀） |
| `slack_geo_*` | 载荷按几何类分配时，`class(layout(lhs)) ≥ layout(lhs+rhs)` |
| `slack_slab_*` | 对照：z/qjs 16–512 slab 表；`>512` 记 `large`（无 slab 余量） |
| `demand_hist` / `lhs_hist` | `n/bytes`，桶 1 / 2-3 / … / 4096+ |

几何类：`16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, …`（交替 ×1.5 / ×2），即令面写的 glibc 式序列。

布局与生产 `inlineAllocationLayout` 同式：`4B rc + 12B String + (latin1: n+1 / utf16: 2n)`。lhs latin1 + rhs utf16 记 `widen_skip`，不算命中（qjs inplace 同样拒绝widen）。

**没有**动 `MemoryAccount` / `destroyFlat` / 热臂。二进制只多计数。

---

## 2. 全 zoo 15 凳

| 凳 | add | flat+flat | rc==1 | rc≤3 | geo 命中 | 命中率 | 严格 rc1 命中 | 省 lhs 字节 | 公式上限 1c/B+80 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **pdfjs** | 3.83M | 2.64M | 23.8k | **2.32M** | **2.30M** | **99.11%** | 20.0k | **6.85 GB** | 7.04 G† |
| splay | 8.95M | 8.95M | 4.48M | 8.95M | 4.29M | 47.93% | 4.29M | 143 MB | 0.49 G |
| crypto | 201k | 200k | 1 | 200k | 193k | 96.77% | 1 | 24.5 MB | 0.040 G |
| typescript | 273k | 196k | 67.4k | 121k | 106k | 87.14% | 57.1k | 0.59 MB | 0.009 G |
| gbemu | 65.7k | 46.6k | 34.5k | 44.3k | 44.3k | 99.88% | 34.5k | 11.2 MB | 0.015 G |
| regexp | 33.0k | 28.7k | 26.7k | 28.6k | 21.0k | 73.42% | 19.4k | 1.10 MB | 0.003 G |
| code-load | 28.3k | 24.0k | 9.56k | 23.9k | 6.83k | 28.59% | 5.35k | 0.16 MB | 0.001 G |
| earley-boyer | 66 | 66 | 2 | 65 | 63 | 96.9% | 1 | ~0 | ~0 |
| mandreel | 66 | 56 | 12 | 53 | 42 | 79.3% | 12 | ~0 | ~0 |
| zlib | 20 | 17 | 1 | 13 | 12 | 92% | 0 | ~0 | ~0 |
| box2d / deltablue / navier / raytrace / richards | 2 | 2 | 1 | 1 | 0–1 | — | — | 0 | 0 |

† 1.0 c/B 公式 **超过** 本凳实测周期，见 §4。

pdfjs 打分 `PdfJS: 7841`。lhs 已是 rope 的另有 **1.17M** 发（现成 tail 臂，不在本上限里）。

---

## 3. 余量命中仿真

对每次 **rc≤3 的 flat+flat**（widen 除外）：

```
have = layout(lhs_len, lhs_wide)
need = layout(lhs_len+rhs_len, out_wide)
hit  = geoClass(have) >= need
```

这是「lhs 按当前长度、用几何类分配」的**独立事件**命中率，不是一条累加器跨事件吃同一块的顺序仿真。顺序仿真只会更高（命中后余量还能继续吃），所以本表已是「单次分配」口径下的上限。

### 3.1 严格 rc==1（令面原文）

| 凳 | rc==1 发 | 占 flat+flat | 其中 geo 命中 |
|---|---:|---:|---:|
| splay | 4.48M | 50% | 4.29M |
| typescript | 67.4k | 34% | 57.1k |
| gbemu | 34.5k | 74% | 34.5k |
| regexp | 26.7k | 93% | 19.4k |
| **pdfjs** | **23.8k** | **0.90%** | 20.0k |
| code-load | 9.56k | 40% | 5.35k |
| 其余 | ≈0–12 | — | — |

pdfjs / crypto 的追加形几乎全是 **rc==2**（pdfjs 2.26M，crypto 200k）。这是 zjs `loadOwned` / 栈上再持一份，不是真共享。若原地臂写成 `rc==1` 才进，pdfjs **几乎摸不到**。要对齐 qjs，guard 必须认「钩子处 rc≤2/3 仍是独占」。

### 3.2 几何类 vs slab 类（pdfjs）

| 仿真 | 命中 | 不中 | 备注 |
|---|---:|---:|---|
| geo 16/24/32/48… | 2.302M | 20.7k | 99.11% |
| z/qjs slab 16–512 | 388k | 51.8k | 另 **1.88M 超 512**，slab 给不了余量 |

pdfjs 的 lhs 已经很大（`4096+` 桶 745k 发 / 4.45 GB，`1024-4095` 903k / 2.16 GB）。小块 slab **罩不住**；余量故事在 **大块几何 / libc usable_size**，不是 512 以内的 8B 阶。

splay 相反：lhs 15–63B，demand 8–31B，geo 命中 48%；slab 几乎全 miss（8.95M）——两边都中等长度，一次追加就跨过当前类。

### 3.3 追加字节（pdfjs / 独占）

demand 几乎是 **1 字节**：2.10M / 2.32M。命中也集中在 1B（2.09M）。lhs 却在 KB–MB。形 = **长串 + 单字节**，正是 qjs inplace 最赚的形（只 `memcpy` rhs）。

---

## 4. 折周期（重点 pdfjs）

同二进制、CPU8、`perf stat` 一次：

| | |
|---|---|
| pdfjs cycles | **4.321 G** |
| instructions | 20.53 G（IPC 4.75） |

独占 geo 命中 2.302M，省 lhs 拷贝 **6.851 GB**，命中侧 demand 2.80 MB（几乎可忽略）。

| 口径 | 公式 | 结果 | 占本凳 |
|---|---|---:|---:|
| 拷贝 0.3 c/B（偏实） | 6.851e9 × 0.3 | **2.06 G** | **47.6%** |
| 拷贝 0.4 c/B + 40 c/hit | 2.74G + 92M | 2.83 G | 65.6% |
| 拷贝 1.0 c/B + 80 c/hit | 6.85G + 184M | 7.04 G | **>100%，封顶 4.32 G** |

**原地臂收益上限（pdfjs）= min(公式, 实测) ≈ 2.0–4.3 G cyc。**  
这是「这些拷贝若全部消失」的天花板，不是落地预期：还要付 usable_size / `destroyFlat` 改契约（见 `/tmp/lanes/CONCAT-INPLACE.md`，分配器无查询 API）。1.17M 已经走 rope 的追加不在此账。

splay 公式上限 0.49 G，量在发数不在字节（143 MB），不是 pdfjs 那种「长 lhs × 1B」杠杆。

crypto 0.04 G，可忽略。

---

## 5. 对刀的含义（仍只析）

1. **pdfjs 是唯一值得为 flat 原地臂付分配器契约的凳。** 上限 2G+ cyc；其它凳合计拷贝体积 <0.2 GB。
2. **guard 不能写死 rc==1。** 在 zjs 钩子上独占是 rc==2/3。写成 rc==1，pdfjs 只剩 20k 发。
3. **余量要来自大块几何 / libc `malloc_usable_size`，不是 512 slab。** pdfjs 1.88M 发 lhs 已超 slab。
4. 落地最小集仍是 CONCAT-INPLACE ①–③（`usableSize` + `destroyFlat` 按块头释放 + 解开 rawFree 尺寸断言），然后才是 flat 臂。本普查只证明 **收益上限够大**，不证明刀面小。
5. 禁加 `String.capacity` 字段（H2：qjs 也没有；松弛只来自分配器）。

---

## 6. 纪律

- 未改 `~/worktree-grok-h2-recon` 历史尖，未 rebase。
- 未改 main / 未合入 / 未动 `test262.conf` / `reports/`。
- 工装分支 `grok/string-slack-census` 仅 recon，生产路径在 `ZJS_CONCAT_CENSUS≠1` 时零开销（getenv 一次）。
