# PUT-ATOMIDX — 普通类具名 put 砍 `atomIsArrayIndex`

日期：2026-08-17。分支 `grok/put-atomidx` 基 `main@9deb9f45`。候 w42 与 MIXED-EQ 同捆。

RF `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
基线 `/home/aneryu/zjs/zig-out/bin/zjs` @ 9deb9f45  
刀 `/home/aneryu/worktree-grok-put-atomidx/zig-out/bin/zjs`  
FW CPU **15** `armv8_pmuv3_1` ABBA n=2。产物 `/tmp/put-atomidx/fw15.json`。  
剖面 CPU **16** insn `-c 200003`（符号同降，非裁决）。

---

## 刀

`setOrDefineOwnDataPropertyForPutFieldOwned` 在 append 前已经：

- tagged-int → `.slow`
- 索引类 + `arrayIndexFromAtom` → `.slow`

qjs 普通 `add_property`（9884-9890）**没有** `JS_AtomIsArrayIndex`。z 却 `bl atomIsArrayIndex`（TS-PUT-FORM 0.175% ≈ 144M）。

comptime `named_put_no_index` 只开这一条 monomorph：`is_array_index = false`，不 `bl`、不标 `may_have_indexed_properties`、走具名 transition。其它 append 调用仍全量探测。

RF：setOrDefine **不再** `bl atomIsArrayIndex`；帧 0xe0→0xd0。  
`adoptShapeForNewProperty` / `relocateShape` **同址同尺寸**（`10a40a0` 0x888 / `10a33ac` 0x540）。

---

## 验尺

| | vs 9deb9f45 insn | cyc | 注 |
|---|---:|---:|---|
| **TS 主尺** | **−760.2M (0.9907)** | **−119.7M** | 分 22319–22362 → 22428–22516 |
| splay 哨 | −79.2M | −39.5M | 不回退 |
| P6_add_tail 哨 | −470.0M | −74.9M | 5e6 对象×3 具名加，每发少一次探测 |

剖面（份额，CPU16）：

| 符号 | old | new |
|---|---:|---:|
| `atomIsArrayIndex` | **0.17%** | **消失** |
| `setOrDefine…PutFieldOwned` | 4.38% | **3.73%** | 与符号同降 |
| `adoptShapeForNewProperty` | 1.21% | 1.26% | 源未改；份额噪声 |
| `relocateShape` | 0.36% | 0.36% | 钉住 |

`test-core`：332 pass / 1 skip。烟测：具名 put / 高位十进制键 / `Object.keys` 过。

−760M 大于符号本身 140M：caller 去掉 `bl`+建参、`is_array_index` 臂 DCE、帧少 0x10。P6 −470M ≈ 15M 加 × ~31 insn/发，对得上。

---

## 源

`src/core/object.zig`：`appendPreparedPropertyEntryImpl` 第三 comptime；仅 setOrDefine 传 `true`。
