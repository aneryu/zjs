# EB-FUNC-Q-SIDE — qjs 函数级账（Earley-Boyer）

pV / q 侧。pQ 主攻 z 侧。本账报官方 qjs 的「JS 函数 → q 耗时份额」。

**分列（driver 追加）：** pQ 拆好的 Earley-only / Boyer-only 夹具已各坐一份，函数表按子基准分列（§3b）。合夹具账仍在 §4，作守恒对照。不下刀。

## 1. 坐姿与二进制

| 项 | 值 |
|---|---|
| qjs | `/home/aneryu/quickjs/qjs` |
| sha256 | `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d` |
| BuildID | `c569967b00a2a4a5f210b7986f946789532c7d5a` |
| 文件 | ELF aarch64, **debug_info, not stripped**（无 `label_OP_*`；CASE 走 DWARF 标签 + `addr2line -f -i`） |
| fixture（合） | `/tmp/census/det/earley-boyer.js`（211694 B） |
| fixture（分） | pQ `/tmp/lanes/eb-func/{earley,boyer}-only.js`（= `/tmp/census/det/` 同名，det 工作量） |
| 分数 | 合 **4471**（CPU16）；Earley-only **17576**、Boyer-only **1159**（CPU15；suite 名仍是 EarleyBoyer，reference 未改，**分数不可横比**，用 period） |
| 核 | 合账 CPU **16**；分列 CPU **15**（追加令时 15 空）。均 `armv8_pmuv3_1` |
| 事件 | `armv8_pmuv3_1/cycles/u` `-F 4000` `--user-regs=x22,x23,x24` |
| 墙钟 | 2026-08-17T12:25:58 → 12:27:21（~83 s，含 gdb `finish JS_Eval`） |

**为何不是 CPU15：** 坐的全程 15 被 pQ（`zjs` / `qjs-04be2460` earley-only ABBA）+ 另一路 `zjs-typed`/`zjs-w44` 占用。按「与 pQ 错开或商定分核，避 5/6/7/19」改坐 **16**。pmuv3_1 的允许核是 8/9/15/16/17/18。

对照 sit1（无 gdb、同样 CPU16、同 fixture）墙钟 21.5 s、分数 4405、6.9 MB。sit3 因 gdb 父进程 + `finish` 把墙钟拉到 ~4×，但 **period 是 cycles 权重**（qjs comm 过滤后 Σperiod = 80.57 G），与 sit1 的 ~21.5 s × ~3.5 GHz ≈ 75 G 同量级。份额用 period，不用样本个数。

原始数据：`/tmp/eb-func-q/raw/`（合）、`/tmp/eb-func-q/raw/{earley,boyer}/`（分）。见 §7。

## 2. 映射方法（addr2line -f -i + 字节码区间）

qjs 的 JS 帧不在 native 符号里，全部活在 `JS_CallInternal`（file `0x21dc0`–`0x2b414`，~38.5 KiB）。native IP ≠ JS 函数。

实测 DWARF（`info scope JS_CallInternal` + 在 `quickjs.c:17874` `restart` 处打印）：

- **`b`（`JSFunctionBytecode*`）= `$x23`**，且 `x23 == b`（eq=1）
- `pc` 被优化掉，不能从寄存器直接读
- `rt=$x24`，`ctx=$x22`（callee-saved）
- official qjs **没有** `label_OP_*`；DWARF 有 `case_OP_*` 标签；源码行用 `addr2line -a -f -i -C -e qjs <dsoff>`（PIE：用 `dso+0xOFF`，不用 runtime IP）

同进程转储：gdb 作父进程（yama `ptrace_scope` 禁止 attach），`break JS_Eval if input_len > 100000`，`finish` 等到 eval 返回后走 `rt->gc_obj_list`，按 malloc header `gc_obj_type==FUNCTION_BYTECODE` 收下每一个 `b`：

- `b` 指针、`byte_code_buf`/`byte_code_len`（区间）、`func_name`（`JS_AtomToCStringLen`）、pc2line 首 leb128+1 = `line0`

sit3 转储：**437** 个字节码函数 / 48335 个 GC 对象。`funcs.jsonl`。

样本归因：

1. `perf script` 过滤 `comm=qjs`（丢掉 gdb 247752 / 332378 个样本）
2. `x23` 先按 **`b` 指针** 命中；不中再按 **`[byte_code_buf, +len)`** 当 PC
3. IP → `addr2line -f -i` 最外层内联帧 + 源码行；`quickjs.c:LINE` 回落到最近的 `CASE(OP_*)`（**次级**，见 §6 坑）

## 3. 覆盖率

| 切片 | period | 占 q 全部 |
|---|---:|---:|
| qjs 全部（过滤后 84465 samples） | 80.568 G | 100% |
| 落在 `JS_CallInternal` | 38.502 G | **47.79%**（与既有符号账 47.78% 对齐） |
| JCI 且 x23→函数（本账主表） | 35.029 G | 43.47%（**JCI 的 91.0%**） |
| helper 且 x23 仍是某个 `b` | 8.248 G | 10.24% |
| helper/GC/malloc，x23 已被 callee 占用 | 33.818 G | 41.98%（**不能**用 x23 归到 JS 函数） |
| JCI 前言/出口（`b` 还没进 x23） | ~3.47 G | 4.3% of all |

JCI 体内 **91%** 可以点名。剩下 9% 是 `JS_CallInternal` 入口（`quickjs.c:17749`）、`class_id` 分流（17819/17823）、以及 `JS_Call`/`JS_CallConstructorInternal` 包一层（20705–20711）——那些点 `b` 还不在 x23。

helper（`JS_SetPropertyInternal` 5.0%、`__js_malloc` 4.0%、`mark_children` 3.3%、`JS_GetPropertyInternal` 2.0%…）x23 不再是 `b`。**没有 dwarf unwind，不能诚实归到 JS 函数。** 对账请用 §3b / §4 的 JCI 独占表，helper 另列 §5。

## 3b. 分列：Earley-only / Boyer-only

夹具是 pQ 拆的 det 工作量（只改 `BenchmarkSuite` 注册，一边只跑 `BgL_earleyzd2benchmarkzd2`，一边只跑 `BgL_nboyerzd2benchmarkzd2`）：

- `/tmp/lanes/eb-func/earley-only.js`（211604 B）
- `/tmp/lanes/eb-func/boyer-only.js`（211601 B）

方法与合账完全相同（x23=`b` + 同进程 gc 转储 + `addr2line -f -i`）。**CPU15**，`pmuv3_1`。line 号比合夹具少 1（删了一条 `new Benchmark`）。

| | Earley-only | Boyer-only | 合计 | 合夹具 sit3 |
|---|---:|---:|---:|---:|
| 墙钟 | 12:32:20–12:32:44 | 12:33:12–12:33:51 | — | 83 s |
| 打印分 | 17576 | 1159 | — | 4471 |
| 转储函数 | 436 | 436 | — | 437 |
| qjs period | **36.700 G** | **43.338 G** | **80.04 G** | 80.57 G |
| JCI period | 13.241 G（36.1%） | 25.386 G（58.6%） | 38.63 G | 38.50 G |
| mapped JCI 覆盖 | **91.3%** | **91.4%** | — | 91.0% |
| 有样本的 JS 函数 | 44 | 21 | — | 63 |
| native leftover | 21.13 G（57.6%） | 11.91 G（27.5%） | — | 33.82 G（42.0%） |

合夹具 period 守恒：36.7+43.3 = 80.0 ≈ 80.6（gdb 税 + 两次独立 ASLR/sit 噪声）。**Boyer 更吃 JCI 体；Earley 更吃 helper/GC。**

交叉污染：Earley 表前 25 名没有 `*_nboyer`；Boyer 表没有 `deriv_trees`/`loop2`/`forw`。拆夹具干净。

CSV：`/tmp/lanes/eb-func/q-side-earley-func-share-jci.csv`、`q-side-boyer-func-share-jci.csv`。

### Earley-only（mapped JCI = 12.083 G = 本切片 32.9%）

| rank | 函数 | line | JCI G | % mapped JCI | % all Earley |
|---:|---|---:|---:|---:|---:|
| 1 | **sc_list** | 1187 | 1.711 | **14.16** | 4.66 |
| 2 | **loop2**（deriv） | 4674 | 1.684 | **13.93** | 4.59 |
| 3 | **sc_Pair** | 938 | 1.493 | **12.36** | 4.07 |
| 4 | **loop3**（deriv） | 4688 | 1.459 | **12.08** | 3.98 |
| 5 | sc_loop1_98 | 4660 | 1.015 | 8.40 | 2.76 |
| 6 | deriv_trees | 4656 | 0.921 | 7.63 | 2.51 |
| 7 | sc_append | 1311 | 0.899 | 7.44 | 2.45 |
| 8 | sc_reverse | 1338 | 0.853 | 7.06 | 2.32 |
| 9 | sc_reverseAppendBang | 1292 | 0.585 | 4.84 | 1.59 |
| 10 | sc_dualAppend | 1303 | 0.340 | 2.82 | 0.93 |
| 11 | sc_cons | 990 | 0.250 | 2.07 | 0.68 |
| 12 | sc_vectorFillBang | 1835 | 0.133 | 1.10 | 0.36 |

top 4（list + Pair + 两层 deriv loop）= **52.5%** mapped JCI。Earley 热在 **列表/树构造 + deriv_trees 闭包**，不是 Boyer unify。

本切片 native leftover 前头是 **GC/分配**：`mark_children` 7.2%、`__js_malloc` 5.7%、`__js_free` 4.9%、`gc_decref_child` 3.1%、`add_property` 2.9%。Set/GetProperty 反而靠后（2.6% / 不进前十）。

### Boyer-only（mapped JCI = 23.208 G = 本切片 53.6%）

| rank | 函数 | line | JCI G | % mapped JCI | % all Boyer |
|---:|---|---:|---:|---:|---:|
| 1 | **one_way_unify1_nboyer** | 4037 | 7.803 | **33.62** | 18.00 |
| 2 | **rewrite_nboyer** | 4006 | 7.162 | **30.86** | 16.53 |
| 3 | **sc_Pair** | 938 | 3.544 | **15.27** | 8.18 |
| 4 | sc_assq | 1424 | 1.825 | 7.87 | 4.21 |
| 5 | rewrite_args_nboyer | 4032 | 1.616 | 6.96 | 3.73 |
| 6 | sc_isNumber | 560 | 0.408 | 1.76 | 0.94 |
| 7 | apply_subst_nboyer | 3957 | 0.217 | 0.94 | 0.50 |
| 8 | apply_subst_lst_nboyer | 3962 | 0.170 | 0.73 | 0.39 |
| 9 | is_term_equal_nboyer | 4088 | 0.129 | 0.56 | 0.30 |
| 10 | sc_isEqual | 3579 | 0.121 | 0.52 | 0.28 |

top 2（unify + rewrite）= **64.5%** mapped JCI；加上 `sc_Pair` = **79.8%**。Boyer 热几乎就这三件事。

本切片 native leftover 前头是 **属性**，不是 GC：`JS_SetPropertyInternal` 5.3%、`JS_GetPropertyInternal` 3.0%、`__js_malloc` 2.7%、`add_property` 1.8%、`JS_OrdinaryIsInstanceOf` 1.1%。`mark_children` 未进前十。

### 分列对 pQ 的含义

1. 合账 top2 是 Boyer，不是「EB 各一半」。拆开后 Boyer JCI 体 25.4 G vs Earley 13.2 G，和 pQ ABBA（q earley-det ~37 G / boyer-det ~43 G 全周期）同方向。
2. `sc_Pair` **两边都热**（Earley 12.4% mapped JCI / Boyer 15.3%），是跨子基准的构造税。
3. 若 z 在 Earley-only 上亏更多：先看 list/deriv + GC/malloc，不要先砍 unify。
4. 若 z 在 Boyer-only 上亏更多：`one_way_unify1` / `rewrite` / `sc_Pair` + Set/GetProperty。

## 4. 合夹具主表（对照，JCI 独占，已映射）

分母 = 已映射 JCI period = **35.029 G**（= 全部 q 的 43.47%，= JCI 的 91.0%）。

`share_all` = 该函数 JCI 体占 **全部 q cycles**（不含它调出去的 Get/Set/malloc/GC）。

| rank | 函数 | line | JCI G | % mapped JCI | % all q | cum JCI |
|---:|---|---:|---:|---:|---:|---:|
| 1 | **one_way_unify1_nboyer** | 4038 | 7.721 | **22.04** | 9.58 | 22.0 |
| 2 | **rewrite_nboyer** | 4007 | 7.113 | **20.31** | 8.83 | 42.3 |
| 3 | **sc_Pair** | 939 | 4.907 | **14.01** | 6.09 | 56.4 |
| 4 | sc_assq | 1425 | 1.772 | 5.06 | 2.20 | 61.4 |
| 5 | loop2（Earley deriv） | 4675 | 1.695 | 4.84 | 2.10 | 66.3 |
| 6 | sc_list | 1188 | 1.694 | 4.84 | 2.10 | 71.1 |
| 7 | rewrite_args_nboyer | 4033 | 1.583 | 4.52 | 1.96 | 75.6 |
| 8 | loop3（Earley deriv） | 4689 | 1.465 | 4.18 | 1.82 | 79.8 |
| 9 | sc_loop1_98 / deriv_trees 内闭包 | 4661 | 0.997 | 2.85 | 1.24 | 82.6 |
| 10 | sc_append | 1312 | 0.919 | 2.62 | 1.14 | 85.3 |
| 11 | deriv_trees | 4657 | 0.912 | 2.60 | 1.13 | 87.9 |
| 12 | sc_reverse | 1339 | 0.854 | 2.44 | 1.06 | 90.3 |
| 13 | sc_reverseAppendBang | 1293 | 0.559 | 1.60 | 0.69 | 91.9 |
| 14 | sc_isNumber | 561 | 0.399 | 1.14 | 0.49 | 93.1 |
| 15 | sc_dualAppend | 1304 | 0.381 | 1.09 | 0.47 | 94.1 |

其后：`sc_cons` 0.72%、`apply_subst_nboyer` 0.63%、`apply_subst_lst_nboyer` 0.45%、`sc_isEqual` 0.42%、`sc_vectorFillBang` 0.39%、`is_term_equal_nboyer` 0.39%、`sc_loop1_127` 0.38%、`BgL_sc_confzd2setzd2adjoinza2za2_46z00` 0.35%、`forw` 0.24%。

- **top 2 = Boyer 核心**（`rewrite` + `one_way_unify1`）= mapped JCI 的 **42.3%**
- **top 3 + `sc_Pair` 构造** = **56.4%**
- top 10 = **85.3%**；top 20 = **96.7%**
- 15 个函数 ≥1% mapped JCI；共 63 个函数有样本
- Boyer 姓（`*_nboyer`）合计远大于 Earley 姓（`deriv_trees` / `loop2` / `loop3` / `forw`）。这与 pQ 的 Earley-only / Boyer-only 拆夹具方向一致：**q 侧热在 Boyer unify/rewrite + Pair 构造**。

完整表：`/tmp/eb-func-q/raw/func-share-jci.csv`。

## 5. 不能归到 JS 函数的 native 剩余（占全部 q）

这些是 x23 对不上任何 `b` / 字节码区间的样本。对账时请 **不要** 把它们摊进 §4。

| 符号 | G | % all q |
|---|---:|---:|
| JS_SetPropertyInternal | 4.032 | 5.01 |
| __js_malloc | 3.191 | 3.96 |
| __js_free | 2.709 | 3.36 |
| mark_children | 2.680 | 3.33 |
| free_gc_object | 1.711 | 2.12 |
| JS_GetPropertyInternal | 1.648 | 2.05 |
| add_property | 1.631 | 2.02 |
| free_property | 1.560 | 1.94 |
| gc_decref_child | 1.166 | 1.45 |
| JS_NewObjectFromShape | 0.869 | 1.08 |
| JS_NewObjectProtoClass | 0.834 | 1.03 |
| gc_free_cycles | 0.834 | 1.03 |
| free_var_ref | 0.800 | 0.99 |
| js_call_c_function | 0.798 | 0.99 |
| get_var_ref | 0.732 | 0.91 |

`sc_Pair` 的 JCI 体已经是 14% of mapped JCI / 6.1% of all；它调出去的 `JS_NewObject*` / `add_property` / `JS_SetPropertyInternal` 在本表，**没有**摊回 `sc_Pair`。z 侧若把 ctor helper 算进函数 inclusive，会对不齐。

## 6. CASE 只作辅证（已知坑）

`addr2line -f -i` → `quickjs.c:LINE` → 最近 `CASE(OP_*)`。D11 已登记：`BREAK` 行范围含下一条分派；`set_true` / `free_and_set_false` 多 CASE 共用。所以 `OP_xor` / `OP_invalid` 会虚高，**不要拿 CASE 表跟 z handler 对绝对份额**。

方向性（mapped JCI 内，仅看前几）：`get_field`、`get_var`、`if_false8`、`tail_call`、`get_array_el`、`call_constructor`、`put_field` 是 Boyer/Pair 热形。与 z 既有 opcode 普查（`get_field` / `if_false8` / `get_var` / `call_constructor`）同族。

按函数看（同样 caveat）：

- `one_way_unify1_nboyer`：get_var / get_field / if_false8 / tail_call
- `rewrite_nboyer`：get_field / get_var / tail_call / if_false8 / **call_constructor**
- `sc_Pair`：put_field / push_this / get_loc0 / get_arg0/1（典型简单字段构造）

## 7. 原始数据

目录 `/tmp/eb-func-q/raw/`：

| 文件 | 内容 |
|---|---|
| `q-eb.data` | sit3 `perf record`（25.4 MB，332k samples，含 gdb） |
| `funcs.jsonl` | 同进程 437 个 `JSFunctionBytecode`（指针 + 区间 + name + line0） |
| `samples.jsonl` | 每条 qjs 样本：ip / dsoff / x23 / 函数 / native / src |
| `func-share-jci.csv` | §4 主表（pQ 直接对） |
| `func-share-jci.json` | 同上 JSON |
| `native-leftover.json` | §5 |
| `func-case-top.json` | 热函数 × CASE |
| `gdb-scope-jci.txt` | `info scope JS_CallInternal`（`b` in `$x23`，全部 `case_OP_*`） |
| `cpu.txt` | 核 / sha256 / 分数 / 时间戳 |
| `sit1-nodump/` | 无 gdb 的对照 sit（分数 4405，21.5 s，无函数转储） |
| `earley/` | Earley-only sit（CPU15，36.7 G，`funcs.jsonl` + `func-share-jci.csv`） |
| `boyer/` | Boyer-only sit（CPU15，43.3 G，同上） |

脚本：`/tmp/eb-func-q/{dump_funcs.py,sit_end.gdb,record_sit.sh,record_one.sh,map_samples.py,finalize.py}`。

分列 CSV 副本：`/tmp/lanes/eb-func/q-side-{earley,boyer}-func-share-jci.csv`。

## 8. 给 pQ 的对账口径

1. **主对 §3b 分列表，合账 §4 只作守恒。** q 的 JS 函数只活在 JCI 里；z 的 handler 符号不是函数名。
2. **用 JCI 独占 / mapped-JCI 分母**，或双方都用「该 JS 函数体内周期 / 全基准周期」。不要拿 z inclusive（含 helper）对 q exclusive。
3. **热函数名**（源码赋值，qjs `func_name` 对 `foo = function` 经常是空，已用 pc2line `line0` 回填）：
   - Boyer：`one_way_unify1_nboyer`、`rewrite_nboyer`、`rewrite_args_nboyer`、`apply_subst_*`、`is_term_equal_nboyer`
   - 运行时：`sc_Pair`、`sc_list`、`sc_assq`、`sc_append`/`sc_reverse*`
   - Earley：`deriv_trees`、`loop2`、`loop3`、`forw`、`BgL_sc_confzd2setzd2*`
4. 若 z 侧 `rewrite`/`unify` 相对 q 并不贵、但 `sc_Pair` 贵，超额在构造/属性写（对上 §5 的 NewObject/SetProperty），不是 unify 算法。
5. Earley 亏先看 list/deriv + GC；Boyer 亏先看 unify/rewrite/Pair + Set/Get。
6. 禁外提 0x3f0 `call_method` 帧。本账没有走那条。

## 9. 纪律与限制

- 官方 sit 核被占，改 16；PMU 同属 `pmuv3_1`。
- gdb 父进程是为了过 yama、在 `JS_Eval` 返回后转储**同一进程**的 `b` 区间。attach 失败见 sit1。
- 未改 qjs、未改仓库、未动 `test262.conf` / `reports/`。
- CASE 表有 BREAK/共享尾标签坑；函数表没有这个坑。
- helper→函数需要 dwarf unwind，本单不做（会再拉一次 sit，且改变「IP→x23→b」这条干净路径）。
