# zjs opcode 逐条审计表（附录）

> 正文见 [`opcode-design.md`](opcode-design.md)（单一现行文本）；跨引擎对照见
> [`opcode-engines.md`](opcode-engines.md)。本文件只放 zjs 的原始逐条数据。
>
> ## ⚠️ 采集口径与可复现性（2026-08-27 复现尝试后补）
>
> **本表的百分比是口径依赖的，不是引擎常数。**用第二套采集口径复现时：
>
> | 类别 | 本表（zoo 口径，含 zlib） | 复现（bench_v8 `driver.js`，**跳过 zlib**） |
> |---|---:|---:|
> | opcode 执行总数 | 41,888,384,774 | 14,685,087,888（约 1/2.85） |
> | 有读数的 opcode | 247 | 170 |
> | 槽位搬运占比 | 33.57% | **36.14%** |
> | 栈洗牌占比 | 0.31% | 0.88% |
> | `drop` 占比 | 0.20% | 0.58% |
>
> 单条 opcode 的占比最大相差约 ±2.5pp（`get_field` +2.45、`mul` +2.00、
> `put_loc8` −2.02）。差异来源至少三个：**驱动器跳过 zlib**、两套 harness
> 的迭代次数不同、warmup 计入与否。
>
> **对结论的影响**：方向与量级**在两套口径下都成立**——槽位搬运都在
> 「约三分之一」这个量级（33.6% / 36.1%）。但**引用到小数点后两位是过度
> 精确**；正文凡引用此表的百分比，都应读作「两套口径的区间」。
>
> **欠账**：本表生成时的精确命令未记录，只写了「15 个 zoo 基准 +
> `ZJS_PROFILE_ALL=1`」。下次重做普查必须把完整命令行与 harness 版本写进
> 表头——否则它不可复现。

生成自 15 个 zoo 基准的全量 opcode 剖析（`ZJS_PROFILE_ALL=1`），共 41,888,384,774 次执行。

发射方式分类：`direct` = parser/compiler 里有字面发射点；`lowering` = 由 `bytecode.zig` 的下降代码写入；
`arithmetic` = 短指令族由 `op.base + idx` 算术生成；`none-found` = 分类器未命中（4 个，均已逐条读代码确认有发射路径：
`and`/`or`/`catch` 是 Zig 关键字需写作 `op.@"and"`，`call_method_apply_fwd` 由融合产生）。

处置栏是**频次+发射方式**给出的机械初判，不是最终裁决——最终裁决见正文 §4 的按族审计。

| id | opcode | size | fmt | pop/push | 执行次数 | 占比 | 发射方式 | 初判 |
|---|---|---|---|---|---|---|---|---|
| 0 | `invalid` | 1 | none | 0/0 | 0 | 0 | direct | demote |
| 1 | `push_i32` | 5 | i32 | 0/1 | 285,230,946 | 0.6809% | direct | keep |
| 2 | `push_const` | 0 | ? | 0/0 | 25,524 | 0.0001% | direct | demote |
| 3 | `fclosure` | 0 | ? | 0/0 | 10,557 | 0.0000% | direct | demote |
| 4 | `push_atom_value` | 5 | atom | 0/1 | 19,303,268 | 0.0461% | direct | keep |
| 5 | `private_symbol` | 5 | atom | 0/1 | 0 | 0 | direct | demote |
| 6 | `undefined` | 1 | none | 0/1 | 3,949 | 0.0000% | direct | demote |
| 7 | `null` | 1 | none | 0/1 | 63,895,633 | 0.1525% | direct | keep |
| 8 | `push_this` | 1 | none | 0/1 | 39,236,462 | 0.0937% | direct | keep |
| 9 | `push_false` | 1 | none | 0/1 | 37,168,130 | 0.0887% | direct | keep |
| 10 | `push_true` | 1 | none | 0/1 | 9,703,847 | 0.0232% | direct | keep |
| 11 | `object` | 1 | none | 0/1 | 8,821,919 | 0.0211% | direct | keep |
| 12 | `special_object` | 2 | u8 | 0/1 | 2,768,329 | 0.0066% | direct | keep |
| 13 | `rest` | 3 | u16 | 0/1 | 0 | 0 | direct | demote |
| 14 | `drop` | 1 | none | 1/0 | 85,318,067 | 0.2037% | direct | keep |
| 15 | `nip` | 1 | none | 2/1 | 0 | 0 | direct | demote |
| 17 | `dup` | 1 | none | 1/2 | 89,640,922 | 0.2140% | direct | keep |
| 18 | `get_loc8_push_i8` | 2 | loc8 | 0/1 | 402,546,496 | 0.9610% | direct | keep |
| 19 | `push_0_or` | 1 | none | 0/1 | 3,768,876,208 | 8.9974% | direct | keep |
| 20 | `push_i8_add` | 2 | i8 | 0/1 | 107,068,282 | 0.2556% | direct | keep |
| 21 | `insert2` | 1 | none | 2/3 | 2,552,758 | 0.0061% | direct | keep |
| 22 | `insert3` | 1 | none | 3/4 | 35,139,786 | 0.0839% | direct | keep |
| 23 | `push_2_sar` | 1 | none | 0/1 | 470,159,471 | 1.1224% | direct | keep |
| 24 | `perm3` | 1 | none | 3/3 | 1,658,759 | 0.0040% | direct | keep |
| 25 | `perm4` | 1 | none | 4/4 | 0 | 0 | direct | demote |
| 26 | `sar_get_array_el` | 1 | none | 2/1 | 456,529,784 | 1.0899% | direct | keep |
| 27 | `swap` | 1 | none | 2/2 | 0 | 0 | direct | demote |
| 28 | `push_0_shr` | 1 | none | 0/1 | 395,847,723 | 0.9450% | direct | keep |
| 29 | `rot3l` | 1 | none | 3/3 | 0 | 0 | direct | demote |
| 30 | `get_loc8_push_1` | 2 | loc8 | 0/1 | 599,826,174 | 1.4320% | direct | keep |
| 31 | `get_var_ref0_get_loc8` | 1 | none | 0/1 | 1,068,564,830 | 2.5510% | direct | keep |
| 32 | `get_loc8_push_2` | 2 | loc8 | 0/1 | 816,208,860 | 1.9485% | direct | keep |
| 33 | `call_constructor` | 3 | npop | 2/1 | 26,593,289 | 0.0635% | direct | keep |
| 34 | `call` | 3 | npop | 1/1 | 1,144,018 | 0.0027% | direct | keep |
| 35 | `tail_call` | 3 | npop | 1/0 | 560 | 0.0000% | direct | demote |
| 36 | `call_method` | 3 | npop | 2/1 | 89,969,583 | 0.2148% | direct | keep |
| 37 | `tail_call_method` | 3 | npop | 2/0 | 35,340,026 | 0.0844% | direct | keep |
| 38 | `array_from` | 3 | npop | 0/1 | 5,148,641 | 0.0123% | direct | keep |
| 39 | `apply` | 3 | u16 | 3/1 | 0 | 0 | direct | demote |
| 40 | `return` | 1 | none | 1/0 | 190,806,853 | 0.4555% | direct | keep |
| 41 | `return_undef` | 1 | none | 0/0 | 53,408,779 | 0.1275% | direct | keep |
| 43 | `check_ctor` | 1 | none | 0/0 | 0 | 0 | direct | demote |
| 44 | `init_ctor` | 1 | none | 0/1 | 0 | 0 | direct | demote |
| 45 | `check_brand` | 1 | none | 2/2 | 0 | 0 | lowering | demote (size-oracle path) |
| 46 | `add_brand` | 1 | none | 2/0 | 0 | 0 | direct | demote |
| 47 | `return_async` | 1 | none | 1/0 | 0 | 0 | direct | demote |
| 48 | `throw` | 1 | none | 1/0 | 0 | 0 | direct | demote |
| 49 | `throw_error` | 6 | atom_u8 | 0/0 | 0 | 0 | direct | demote |
| 50 | `eval` | 5 | npop_u16 | 1/1 | 0 | 0 | direct | demote |
| 51 | `apply_eval` | 3 | u16 | 2/1 | 0 | 0 | direct | demote |
| 52 | `regexp` | 1 | none | 2/1 | 443,167 | 0.0011% | direct | keep |
| 53 | `get_super` | 1 | none | 1/1 | 0 | 0 | direct | demote |
| 54 | `import` | 1 | none | 2/1 | 0 | 0 | direct | demote |
| 55 | `get_var_undef` | 3 | var_ref | 0/1 | 307 | 0.0000% | direct | demote |
| 56 | `get_var` | 3 | var_ref | 0/1 | 522,782,251 | 1.2480% | direct | keep |
| 57 | `put_var` | 3 | var_ref | 1/0 | 11,704,774 | 0.0279% | direct | keep |
| 58 | `put_var_init` | 3 | var_ref | 1/0 | 0 | 0 | direct | demote |
| 59 | `get_ref_value` | 1 | none | 2/3 | 0 | 0 | direct | demote |
| 60 | `put_ref_value` | 1 | none | 3/0 | 0 | 0 | direct | demote |
| 61 | `get_field` | 5 | atom | 1/1 | 545,086,894 | 1.3013% | direct | keep |
| 62 | `get_field2` | 5 | atom | 1/2 | 118,153,373 | 0.2821% | direct | keep |
| 63 | `put_field` | 5 | atom | 2/0 | 221,620,665 | 0.5291% | direct | keep |
| 64 | `get_private_field` | 1 | none | 2/1 | 0 | 0 | lowering | demote (size-oracle path) |
| 65 | `put_private_field` | 1 | none | 3/0 | 0 | 0 | lowering | demote (size-oracle path) |
| 66 | `define_private_field` | 1 | none | 3/1 | 0 | 0 | direct | demote |
| 67 | `get_array_el` | 1 | none | 2/1 | 1,151,077,910 | 2.7480% | direct | keep |
| 68 | `get_array_el2` | 1 | none | 2/2 | 6,657,011 | 0.0159% | direct | keep |
| 69 | `get_array_el3` | 1 | none | 2/3 | 8,951,665 | 0.0214% | direct | keep |
| 70 | `put_array_el` | 1 | none | 3/0 | 958,474,949 | 2.2882% | direct | keep |
| 71 | `get_super_value` | 1 | none | 3/1 | 0 | 0 | direct | demote |
| 72 | `put_super_value` | 1 | none | 4/0 | 0 | 0 | direct | demote |
| 73 | `define_field` | 5 | atom | 2/1 | 17,658,935 | 0.0422% | direct | keep |
| 74 | `set_name` | 5 | atom | 1/1 | 1,662,120 | 0.0040% | direct | keep |
| 75 | `set_name_computed` | 1 | none | 2/2 | 0 | 0 | direct | demote |
| 77 | `set_home_object` | 1 | none | 2/2 | 0 | 0 | direct | demote |
| 78 | `define_array_el` | 1 | none | 3/2 | 0 | 0 | direct | demote |
| 79 | `append` | 1 | none | 3/2 | 0 | 0 | direct | demote |
| 80 | `copy_data_properties` | 2 | u8 | 3/3 | 0 | 0 | direct | demote |
| 81 | `define_method` | 6 | atom_u8 | 2/1 | 39 | 0.0000% | direct | demote |
| 82 | `define_method_computed` | 2 | u8 | 3/1 | 0 | 0 | direct | demote |
| 83 | `define_class` | 6 | atom_u8 | 2/2 | 0 | 0 | direct | demote |
| 84 | `define_class_computed` | 6 | atom_u8 | 3/3 | 0 | 0 | direct | demote |
| 85 | `get_loc` | 3 | loc | 0/1 | 266,147,003 | 0.6354% | direct | keep |
| 86 | `put_loc` | 3 | loc | 1/0 | 180,849,647 | 0.4317% | direct | keep |
| 87 | `set_loc` | 3 | loc | 1/1 | 17,472,000 | 0.0417% | direct | keep |
| 88 | `get_arg` | 3 | arg | 0/1 | 128,012,910 | 0.3056% | direct | keep |
| 89 | `put_arg` | 3 | arg | 1/0 | 55,743,330 | 0.1331% | direct | keep |
| 90 | `set_arg` | 3 | arg | 1/1 | 59,442,144 | 0.1419% | direct | keep |
| 91 | `get_var_ref` | 3 | var_ref | 0/1 | 242,487,584 | 0.5789% | direct | keep |
| 92 | `put_var_ref` | 3 | var_ref | 1/0 | 2,034 | 0.0000% | direct | demote |
| 93 | `set_var_ref` | 3 | var_ref | 1/1 | 0 | 0 | direct | demote |
| 94 | `set_loc_uninitialized` | 3 | loc | 0/0 | 0 | 0 | direct | demote |
| 95 | `get_loc_check` | 3 | loc | 0/1 | 0 | 0 | direct | demote |
| 96 | `put_loc_check` | 3 | loc | 1/0 | 0 | 0 | direct | demote |
| 97 | `set_loc_check` | 3 | loc | 1/1 | 0 | 0 | direct | demote |
| 98 | `put_loc_check_init` | 3 | loc | 1/0 | 0 | 0 | direct | demote |
| 99 | `get_loc_checkthis` | 3 | loc | 0/1 | 0 | 0 | direct | demote |
| 100 | `get_var_ref_check` | 3 | var_ref | 0/1 | 0 | 0 | lowering | demote (size-oracle path) |
| 101 | `put_var_ref_check` | 3 | var_ref | 1/0 | 0 | 0 | lowering | demote (size-oracle path) |
| 102 | `put_var_ref_check_init` | 3 | var_ref | 1/0 | 0 | 0 | lowering | demote (size-oracle path) |
| 103 | `close_loc` | 3 | loc | 0/0 | 0 | 0 | direct | demote |
| 104 | `if_false` | 5 | label | 1/0 | 232,562,592 | 0.5552% | direct | keep |
| 105 | `if_true` | 5 | label | 1/0 | 67,968,281 | 0.1623% | direct | keep |
| 106 | `goto` | 5 | label | 0/0 | 44,234,426 | 0.1056% | direct | keep |
| 107 | `catch` | 5 | label | 0/1 | 22,052 | 0.0001% | none-found | demote |
| 108 | `gosub` | 5 | label | 0/0 | 10 | 0.0000% | direct | demote |
| 109 | `ret` | 1 | none | 1/0 | 10 | 0.0000% | direct | demote |
| 110 | `nip_catch` | 1 | none | 2/1 | 43 | 0.0000% | direct | demote |
| 111 | `to_object` | 1 | none | 1/1 | 0 | 0 | direct | demote |
| 112 | `to_propkey` | 1 | none | 1/1 | 0 | 0 | direct | demote |
| 113 | `dyn_env_probe` | 10 | atom_label_u8 | 1/0 | 120 | 0.0000% | direct | MERGED 2026-08-27: absorbed 114-117 |
| 114 | *(free)* | - | - | - | - | - | - | RECLAIMED 2026-08-27: merged into `dyn_env_probe` (was `with_put_var`) |
| 115 | *(free)* | - | - | - | - | - | - | RECLAIMED 2026-08-27: merged into `dyn_env_probe` (was `with_delete_var`) |
| 116 | *(free)* | - | - | - | - | - | - | RECLAIMED 2026-08-27: merged into `dyn_env_probe` (was `with_make_ref`) |
| 117 | *(free)* | - | - | - | - | - | - | RECLAIMED 2026-08-27: merged into `dyn_env_probe` (was `with_get_ref`) |
| 118 | `make_loc_ref` | 7 | atom_u16 | 0/2 | 0 | 0 | lowering | demote (size-oracle path) |
| 119 | `make_arg_ref` | 7 | atom_u16 | 0/2 | 0 | 0 | lowering | demote (size-oracle path) |
| 120 | `make_var_ref_ref` | 7 | atom_u16 | 0/2 | 0 | 0 | lowering | demote (size-oracle path) |
| 121 | `make_var_ref` | 5 | atom | 0/2 | 0 | 0 | lowering | demote (size-oracle path) |
| 122 | `for_in_start` | 1 | none | 1/1 | 37,749 | 0.0001% | direct | demote |
| 123 | `for_of_start` | 1 | none | 1/3 | 0 | 0 | direct | demote |
| 124 | `for_await_of_start` | 1 | none | 1/3 | 0 | 0 | direct | demote |
| 125 | `for_in_next` | 1 | none | 1/3 | 438,312 | 0.0010% | direct | keep |
| 126 | `for_of_next` | 2 | u8 | 3/5 | 0 | 0 | direct | demote |
| 127 | `for_await_of_next` | 1 | none | 3/4 | 0 | 0 | direct | demote |
| 128 | `iterator_check_object` | 1 | none | 1/1 | 0 | 0 | direct | demote |
| 129 | `iterator_get_value_done` | 1 | none | 2/3 | 0 | 0 | direct | demote |
| 130 | `iterator_close` | 1 | none | 3/0 | 0 | 0 | direct | demote |
| 131 | `iterator_next` | 1 | none | 4/4 | 0 | 0 | direct | demote |
| 132 | `iterator_call` | 2 | u8 | 4/5 | 0 | 0 | direct | demote |
| 133 | `initial_yield` | 1 | none | 0/0 | 0 | 0 | direct | demote |
| 134 | `yield` | 1 | none | 1/2 | 0 | 0 | direct | demote |
| 135 | `yield_star` | 1 | none | 1/2 | 0 | 0 | direct | demote |
| 136 | `async_yield_star` | 1 | none | 1/2 | 0 | 0 | direct | demote |
| 137 | `await` | 1 | none | 1/1 | 0 | 0 | direct | demote |
| 138 | `neg` | 1 | none | 1/1 | 6,557,308 | 0.0157% | direct | keep |
| 139 | `plus` | 1 | none | 1/1 | 602 | 0.0000% | direct | demote |
| 140 | `dec` | 1 | none | 1/1 | 67,472,903 | 0.1611% | direct | keep |
| 141 | `inc` | 1 | none | 1/1 | 129,257,170 | 0.3086% | direct | keep |
| 142 | `post_dec` | 1 | none | 1/2 | 79,168 | 0.0002% | direct | demote |
| 143 | `post_inc` | 1 | none | 1/2 | 129,584,675 | 0.3094% | direct | keep |
| 144 | `dec_loc` | 2 | loc8 | 0/0 | 2,639,979 | 0.0063% | direct | keep |
| 145 | `inc_loc` | 2 | loc8 | 0/0 | 115,447,879 | 0.2756% | direct | keep |
| 146 | `add_loc` | 2 | loc8 | 1/0 | 11,446,070 | 0.0273% | direct | keep |
| 147 | `not` | 1 | none | 1/1 | 388,894 | 0.0009% | direct | demote |
| 148 | `lnot` | 1 | none | 1/1 | 77,736,998 | 0.1856% | direct | keep |
| 149 | `typeof` | 1 | none | 1/1 | 1,896,497 | 0.0045% | direct | keep |
| 150 | `delete` | 1 | none | 2/1 | 11 | 0.0000% | direct | demote |
| 151 | `delete_var` | 5 | atom | 0/1 | 133 | 0.0000% | direct | demote |
| 152 | `mul` | 1 | none | 2/1 | 394,089,391 | 0.9408% | direct | keep |
| 153 | `div` | 1 | none | 2/1 | 27,124,267 | 0.0648% | direct | keep |
| 154 | `mod` | 1 | none | 2/1 | 4,647,194 | 0.0111% | direct | keep |
| 155 | `add` | 1 | none | 2/1 | 2,677,228,487 | 6.3913% | direct | keep |
| 156 | `sub` | 1 | none | 2/1 | 652,748,938 | 1.5583% | direct | keep |
| 157 | `pow` | 1 | none | 2/1 | 0 | 0 | direct | demote |
| 158 | `shl` | 1 | none | 2/1 | 830,235,628 | 1.9820% | direct | keep |
| 159 | `sar` | 1 | none | 2/1 | 684,889,069 | 1.6350% | direct | keep |
| 160 | `shr` | 1 | none | 2/1 | 42,329,367 | 0.1011% | direct | keep |
| 161 | `lt` | 1 | none | 2/1 | 74,581,057 | 0.1780% | direct | keep |
| 162 | `lte` | 1 | none | 2/1 | 154,736,586 | 0.3694% | direct | keep |
| 163 | `gt` | 1 | none | 2/1 | 171,251,910 | 0.4088% | direct | keep |
| 164 | `gte` | 1 | none | 2/1 | 174,780,043 | 0.4173% | direct | keep |
| 165 | `instanceof` | 1 | none | 2/1 | 27,680,493 | 0.0661% | direct | keep |
| 166 | `in` | 1 | none | 2/1 | 23,945 | 0.0001% | direct | demote |
| 167 | `eq` | 1 | none | 2/1 | 202,574,089 | 0.4836% | direct | keep |
| 168 | `neq` | 1 | none | 2/1 | 283,092,224 | 0.6758% | direct | keep |
| 169 | `strict_eq` | 1 | none | 2/1 | 40,049,153 | 0.0956% | direct | keep |
| 170 | `strict_neq` | 1 | none | 2/1 | 16,044,808 | 0.0383% | direct | keep |
| 171 | `and` | 1 | none | 2/1 | 754,318,490 | 1.8008% | none-found | keep |
| 172 | `xor` | 1 | none | 2/1 | 68,486,090 | 0.1635% | direct | keep |
| 173 | `or` | 1 | none | 2/1 | 61,874,180 | 0.1477% | none-found | keep |
| 174 | `is_undefined_or_null` | 1 | none | 1/1 | 0 | 0 | direct | demote |
| 175 | `private_in` | 1 | none | 2/1 | 0 | 0 | lowering | demote (size-oracle path) |
| 176 | `push_bigint_i32` | 5 | i32 | 0/1 | 0 | 0 | direct | demote |
| 177 | `nop` | 1 | none | 0/0 | 0 | 0 | direct | demote |
| 178 | `push_minus1` | 1 | none_int | 0/1 | 16,461,282 | 0.0393% | arithmetic | keep |
| 179 | `push_0` | 1 | none_int | 0/1 | 760,005,173 | 1.8144% | direct | keep |
| 180 | `push_1` | 1 | none_int | 0/1 | 1,203,167,954 | 2.8723% | direct | keep |
| 181 | `push_2` | 1 | none_int | 0/1 | 130,596,812 | 0.3118% | direct | keep |
| 182 | `push_3` | 1 | none_int | 0/1 | 148,876,163 | 0.3554% | direct | keep |
| 183 | `push_4` | 1 | none_int | 0/1 | 190,786,287 | 0.4555% | arithmetic | keep |
| 184 | `push_5` | 1 | none_int | 0/1 | 38,861,268 | 0.0928% | direct | keep |
| 185 | `push_6` | 1 | none_int | 0/1 | 50,972,868 | 0.1217% | arithmetic | keep |
| 186 | `push_7` | 1 | none_int | 0/1 | 33,388,479 | 0.0797% | arithmetic | keep |
| 187 | `push_i8` | 2 | i8 | 0/1 | 443,142,757 | 1.0579% | direct | keep |
| 188 | `push_i16` | 3 | i16 | 0/1 | 395,076,743 | 0.9432% | direct | keep |
| 189 | `push_const8` | 2 | const8 | 0/1 | 9,550,185 | 0.0228% | direct | keep |
| 190 | `fclosure8` | 2 | const8 | 0/1 | 2,642,022 | 0.0063% | direct | keep |
| 191 | `push_empty_string` | 1 | none | 0/1 | 1,341,684 | 0.0032% | direct | keep |
| 192 | `get_loc8` | 2 | loc8 | 0/1 | 3,307,473,001 | 7.8959% | direct | keep |
| 193 | `put_loc8` | 2 | loc8 | 1/0 | 2,172,684,626 | 5.1868% | direct | keep |
| 194 | `set_loc8` | 2 | loc8 | 1/1 | 723,907,450 | 1.7282% | direct | keep |
| 195 | `get_loc0` | 1 | none_loc | 0/1 | 700,116,255 | 1.6714% | direct | keep |
| 196 | `get_loc1` | 1 | none_loc | 0/1 | 900,764,620 | 2.1504% | arithmetic | keep |
| 197 | `get_loc2` | 1 | none_loc | 0/1 | 555,382,246 | 1.3259% | direct | keep |
| 198 | `get_loc3` | 1 | none_loc | 0/1 | 409,904,407 | 0.9786% | direct | keep |
| 199 | `put_loc0` | 1 | none_loc | 1/0 | 180,772,890 | 0.4316% | direct | keep |
| 200 | `put_loc1` | 1 | none_loc | 1/0 | 69,262,085 | 0.1653% | direct | keep |
| 201 | `put_loc2` | 1 | none_loc | 1/0 | 60,451,091 | 0.1443% | arithmetic | keep |
| 202 | `put_loc3` | 1 | none_loc | 1/0 | 45,285,376 | 0.1081% | arithmetic | keep |
| 203 | `set_loc0` | 1 | none_loc | 1/1 | 24,741,254 | 0.0591% | direct | keep |
| 204 | `set_loc1` | 1 | none_loc | 1/1 | 42,691,581 | 0.1019% | direct | keep |
| 205 | `set_loc2` | 1 | none_loc | 1/1 | 13,035,021 | 0.0311% | arithmetic | keep |
| 206 | `set_loc3` | 1 | none_loc | 1/1 | 22,193,205 | 0.0530% | direct | keep |
| 207 | `get_arg0` | 1 | none_arg | 0/1 | 938,913,400 | 2.2415% | direct | keep |
| 208 | `get_arg1` | 1 | none_arg | 0/1 | 484,464,114 | 1.1566% | arithmetic | keep |
| 209 | `get_arg2` | 1 | none_arg | 0/1 | 170,103,018 | 0.4061% | arithmetic | keep |
| 210 | `get_arg3` | 1 | none_arg | 0/1 | 149,882,665 | 0.3578% | arithmetic | keep |
| 211 | `put_arg0` | 1 | none_arg | 1/0 | 146,404,329 | 0.3495% | direct | keep |
| 212 | `put_arg1` | 1 | none_arg | 1/0 | 157,014,415 | 0.3748% | arithmetic | keep |
| 213 | `put_arg2` | 1 | none_arg | 1/0 | 43,265,824 | 0.1033% | arithmetic | keep |
| 214 | `put_arg3` | 1 | none_arg | 1/0 | 55,463,676 | 0.1324% | arithmetic | keep |
| 215 | `set_arg0` | 1 | none_arg | 1/1 | 107,570,588 | 0.2568% | direct | keep |
| 216 | `set_arg1` | 1 | none_arg | 1/1 | 640,836 | 0.0015% | arithmetic | keep |
| 217 | `set_arg2` | 1 | none_arg | 1/1 | 503,074 | 0.0012% | arithmetic | keep |
| 218 | `set_arg3` | 1 | none_arg | 1/1 | 43,175 | 0.0001% | arithmetic | keep (short family) |
| 219 | `get_var_ref0` | 1 | none_var_ref | 0/1 | 453,235,865 | 1.0820% | direct | keep |
| 220 | `get_var_ref1` | 1 | none_var_ref | 0/1 | 488,347,055 | 1.1658% | lowering | keep |
| 221 | `get_var_ref2` | 1 | none_var_ref | 0/1 | 327,214,069 | 0.7812% | arithmetic | keep |
| 222 | `get_var_ref3` | 1 | none_var_ref | 0/1 | 357,105,073 | 0.8525% | lowering | keep |
| 223 | `put_var_ref0` | 1 | none_var_ref | 1/0 | 73,267 | 0.0002% | direct | demote |
| 224 | `put_var_ref1` | 1 | none_var_ref | 1/0 | 378 | 0.0000% | arithmetic | keep (short family) |
| 225 | `put_var_ref2` | 1 | none_var_ref | 1/0 | 40 | 0.0000% | arithmetic | keep (short family) |
| 226 | `put_var_ref3` | 1 | none_var_ref | 1/0 | 17 | 0.0000% | lowering | demote (size-oracle path) |
| 227 | `set_var_ref0` | 1 | none_var_ref | 1/1 | 1,047,036 | 0.0025% | direct | keep |
| 228 | `set_var_ref1` | 1 | none_var_ref | 1/1 | 29,088 | 0.0001% | arithmetic | keep (short family) |
| 229 | `set_var_ref2` | 1 | none_var_ref | 1/1 | 8 | 0.0000% | arithmetic | keep (short family) |
| 230 | `set_var_ref3` | 1 | none_var_ref | 1/1 | 0 | 0 | lowering | demote (size-oracle path) |
| 231 | `get_length` | 1 | none | 1/1 | 43,200,047 | 0.1031% | direct | keep |
| 232 | `if_false8` | 2 | label8 | 1/0 | 806,569,819 | 1.9255% | direct | keep |
| 233 | `if_true8` | 2 | label8 | 1/0 | 147,135,109 | 0.3513% | direct | keep |
| 234 | `goto8` | 2 | label8 | 0/0 | 385,317,885 | 0.9199% | direct | keep |
| 235 | `goto16` | 3 | label16 | 0/0 | 236,600,775 | 0.5648% | direct | keep |
| 236 | `call0` | 1 | npopx | 1/1 | 405,839 | 0.0010% | direct | demote |
| 237 | `call1` | 1 | npopx | 1/1 | 48,048,859 | 0.1147% | arithmetic | keep |
| 238 | `call2` | 1 | npopx | 1/1 | 37,610,182 | 0.0898% | arithmetic | keep |
| 239 | `call3` | 1 | npopx | 1/1 | 341,908 | 0.0008% | arithmetic | keep (short family) |
| 240 | `get_field_field2` | 5 | atom | 1/1 | 21,334,593 | 0.0509% | direct | keep |
| 241 | `is_null` | 1 | none | 1/1 | 38,940,954 | 0.0930% | direct | keep |
| 242 | `get_var_field` | 3 | var_ref | 0/1 | 24,552,997 | 0.0586% | direct | keep |
| 243 | `get_loc2_field2` | 1 | none_loc | 0/1 | 21,890,348 | 0.0523% | direct | keep |
| 244 | `using` | 2 | u8 | 0/1 | 1,299,915 | 0.0031% | direct | keep |
| 245 | `get_field2_call_method` | 5 | atom | 1/2 | 63,527,185 | 0.1517% | direct | keep |
| 246 | `get_loc2_field` | 1 | none_loc | 0/1 | 74,268,031 | 0.1773% | direct | keep |
| 247 | `eq_if_false8` | 1 | none | 2/1 | 280,044,525 | 0.6685% | direct | keep |
| 248 | `call_method_apply_fwd` | 3 | npop | 2/1 | 6,058,414 | 0.0145% | none-found | keep |
| 249 | `get_loc0_field` | 1 | none_loc | 0/1 | 216,054,046 | 0.5158% | direct | keep |
| 250 | `cmp_if_false8` | 1 | none | 2/1 | 277,096,862 | 0.6615% | direct | keep |
| 251 | `put_loc8_get_loc8` | 2 | loc8 | 1/0 | 600,756,243 | 1.4342% | direct | keep |
| 252 | `push_this_put_loc0` | 1 | none | 0/1 | 108,967,999 | 0.2601% | direct | keep |
| 253 | `put_loc0_get_loc0` | 1 | none_loc | 1/0 | 8 | 0.0000% | direct | demote |
