# R8-M PRICES — L4–L5 RC / 分配

lane: R8-M / CPU 6 / 诊断批，src 只读  
8-sample ABBA。路径核证看 `value_frees` / `call_constructor` 是否 ≈ N。

## 结论先行

**分配 + RC 在隔离微基准上接近平价或 zjs 优势。**  
唯一稳定的正税：空对象字面量 alloc+free **Δ +9.5 cyc**（1.055×）。  
`new Pair` 即创即丢 0.969（Δ −5.6）。不能解释 TS other 顶上的 destroy/trace 宏观账——那是组合/GC 环，禁区 IMPL-TEARDOWN。

计划预期「alloc 层为负」：本批空 `{}` 小正（+7~9），量级不是路径走错（`object`×N、`value_frees`≈N）。zjs allocator 0.77× 的优势被对象头/RC 吃掉后略亏。

## 价目

| id | 形状 | N | cyc z/q | z/次 | q/次 | Δ | 路径核证 |
|---|---|---:|---:|---:|---:|---:|---|
| M1 | `new Pair` 即丢 | 8e6 | 0.9689 | 300 | 305 | **−5.6** | `call_constructor`=N，frees=5N（对象+字段+临时） |
| M2 | 复用 Pair 读 `.a` | 8e7 | 0.7797 | 12.1 | 16.1 | −4.0 | `get_field`=N，无 ctor |
| M3 | `{}` 即丢 | 8e6 | **1.0554** | 74 | 65 | **+9.5** | `object`=N，frees=N |
| M4 | `{x,y,z}` 即丢 | 8e6 | 0.8955 | 261 | 289 | −28 | `define_field`=3N |
| M5 | `"abc".length` | 8e7 | 0.7803 | 9.4 | 12.6 | −3.2 | `get_length`=N |
| M6 | `a[i&7]` | 4e7 | 0.8978 | 18.9 | 18.6 | **+0.37** | `get_array_el`=N |
| M7 | `a[i&7]=i` | 4e7 | 0.8487 | 14.0 | 15.1 | −1.2 | `put_array_el`=N |
| M8 | 256 槽轮转 new | 4e6 | 1.0037 | 307 | 301 | +5.8 | ctor≈N，frees≈0.7N（槽复用） |

## 路径核证要点

- M1 vs M2：丢才有 `call_constructor`×N；keep 只有 `get_field`。差分 = 一次 ctor+destroy，不是读。
- M3 frees=N：每次 `{}` 真销毁，不是 bypass 漏释放。
- 未做独立 `destroyZeroRef` 探针（需要改 src 计数器）。M3 即丢空对象是最接近的公开替代。

## 对账含义

`get_array_el` Δ +0.37 × zlib 213M ≈ **+79M**，相对 zlib +1337M 是 6%。R6-K 去帧可能吃掉这 0.37。  
TS `value_frees` 宏观大，但本层单价不支持「RC 比 qjs 贵一个数量级」；10× teardown 仍是禁区组合账。

## 登记

无新 FAITHFUL ≥1.0。M3 +9.5 不够立项。
