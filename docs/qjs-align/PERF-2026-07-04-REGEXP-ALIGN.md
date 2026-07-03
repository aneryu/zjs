# regexp 性能对齐(2026-07-04)

目标:与 qjs 对齐 regexp 性能。承接 PERF-2026-07-04-BRANCH-VS-QJS.md 的
「replace 8–16× = native 按名分派每调用 malloc」线索。

协议同前:taskset -c 19(X925 大核)、perf stat task-clock、best-of-3、
两引擎输出逐字一致后计时、基准包函数。qjs = `~/quickjs/qjs`(04be246)。

## 结果(zjs/qjs 时间比,修复前 → 修复后)

| 基准 | 修前 | 修后 | 备注 |
|---|---|---|---|
| `re.test(s)` | 0.98 | **0.91** | 已对齐(反超来自 comptime atom 顺带收益) |
| `re.exec(s)` | 2.60 | 2.41 | 剩余 = match 数组构造 = 通用分配地板 |
| `s.replace(re,"$2 $1")` | 8.07 | **2.03** | |
| `s.replace(re,"X")` | 8.60 | **2.06** | |
| `s.replace("John","X")` | 16.4 | **1.93** | 纯字符串路径 |
| `s.replaceAll` | (同 replace 路径) | — | 共享 qjsStringReplaceCore |
| `str.match(re)` | 4.42 | 3.31 | flags 读链修复 −350ns/call |
| `str.match(/g)` | 4.38 | 3.71 | |
| `str.split(re)` | 3.43 | 3.04 | |
| `str.search(re)` | 4.00 | 3.74 | search 不读 flags,主要剩属性协议 |
| regexp 混合 (exec+replace) | 5.81 | **2.31** | 报告主表口径 |

附:charCodeAt 1591→1667ms(3.09×,既往带 2.92–3.23 内)——string_ops
编译单元的 LLVM 内联布局抖动(qjsStringNumericArgsMethod 被 outline),
指令 +2.75%;`qjsStringReplaceCore` 已标 noinline 防大体内联进 dispatcher,
残余抖动判为 μ-基准布局噪声,非语义回退。其余非 regexp 基准
(loops/strcat/objprop/template/fib/array)全部在既往带内。

## 落地的忠实修复(qjs 锚点)

1. **String.prototype.replace 进 record table**(qjs `js_string_proto_funcs`
   quickjs.c:46872 `JS_CFUNC_MAGIC_DEF("replace", 2, js_string_replace, 0)`)。
   replace 原为 plain name-dispatched 函数:每次调用 malloc 名字 →
   `callValueOrBytecodeClassModeDispatch` 名链上百次 strcmp + 几十个域函数
   各自 malloc 名字再比较(profile: nativeFunctionNameForVm 11.9% +
   malloc/free 32% + eqlBytes 6.3%)。加 `PrototypeMethod.replace = 145` +
   `legacy_replace_method_id = 44` + internal_entries 条目后,调用走
   `fastNativeMethodCall` → record(= qjs cfunc+magic),零分配零 strcmp。
   一项改动:replace(str) 16.4→3.9×、replace(re) 8.6→2.9×。

2. **qjsStringReplace/ReplaceAll 重写为 js_string_replace 镜像**
   (quickjs.c:46012,magic 0/1 共享一个核心 `qjsStringReplaceCore`)。
   旧实现把 source/search(All 还有 replacement)各物化成 `ArrayList(u16)`
   (profile: appendStringValueUnits 18% + ensureCapacity 13% + malloc 10%),
   且结果强制 UTF-16 宽字符串。新实现:flat 原生表示上直接
   `string_indexof`(45573 镜像)+ 窄起步 StringBuffer(原 PadBuffer 泛化,
   qjs string_buffer 同构)+ GetSubstitution string-search 形态(45888,
   captures_len=0:$N/$<name> 走 norep)。首轮未命中零拷贝返回原串。
   replace(str) 3.9→1.9×。

3. **qjsRegExpReplaceFast 去物化**(js_regexp_replace quickjs.c:48328 镜像):
   source/replacement 不再拷成 u16 数组,直接 ResolvedData 切片 +
   StringBuffer;`appendRegExpSubstitutionFromSlots` 改为 raw-capture 形态的
   GetSubstitution(capture 槽直接切源串)。replace(re) 2.9→2.1×。

4. **comptime atom 常量化**(= qjs `JS_ATOM_*` 编译期常量):
   string_ops/object_ops/regexp_fastpath 全部字面量 `predefinedId` 调用
   (53 处)+ core/object.zig match-metadata 3 处包 `comptime`。原每次调用
   运行时 StaticStringMap 查表(profile 13.9%)。

5. **regExpIsStandard 的原型探针哈希化**(js_is_standard_regexp
   quickjs.c:48808 的 find_property 是 shape 哈希):qjsRegExpPrototype
   {Method,Getter}IsDefault 原来线性扫 `shapeProps()`(RegExp.prototype
   几十个属性 × 每次调用 4 探针),改 `findProperty`(shape 哈希)。

6. **RegExp accessor 按 id(magic)分派**(js_regexp_get_flag 47921 /
   js_regexp_get_flags 47943 镜像):原链 = record 命中后仍按名字符串走
   `qjsRegExpAccessor`,flags getter 每次 8× `internAtom`(运行时 intern!)
   + 每个 flag 属性读又进 `isSameRealmRegExpPrototypeGetter`(再 internAtom
   + getOwnProperty descriptor 往返)。新 `accessorCallById`:单 flag =
   compiled bytecode 位读 + `this == realm RegExp.prototype → undefined`
   (qjs !re 分支语义,顺序与 qjs 一致:先内部槽后 proto);flags = 8×
   comptime atom 的 [[Get]](观察子类覆盖,qjs flag_atom[] 同构);source
   保留原 body。match 4.4→3.3×。

## 剩余差距的归属(全部为横切机制,非 regexp 专属)

对照 profile:qjs 151ns/replace 中 lre_exec 34%(≈52ns);zjs 的
execCaptureSlotsParsed ≈55ns —— **正则引擎本身已对齐**(与 2026-06-29
「纯引擎 0.91×」结论一致)。qjs 在 search/match/split/exec 上没有 zjs
缺失的 fast path(js_regexp_Symbol_search 就是 lastIndex 读写 + exec +
index 读;逐步对照 zjs 同构、零多余观察)。剩余是三个横切前沿:

1. **属性读写协议**(最大):`getValueProperty`/`setValuePropertyStrict`
   每次 ~100ns vs qjs JS_GetPropertyInternal ~20ns。zjs 是历史 case 链 +
   own miss 后 getOwnProperty **descriptor 构造/销毁往返** +
   moduleNamespace/dataview 等逐项检查 + 类名字符串 getPrototypeMethod
   fallback(暗示 builtin 实例物理 [[Prototype]] 链不完整 = memory DEEP
   「builtin-proto 物理链」)。qjs 是单循环 find_own_property(shape 哈希)
   → prop-kind switch → 原型链。**下一个切片 = JS_GetPropertyInternal
   镜像重写**,search/match/split 剩余 gap 的钥匙,也覆盖 objprop 1.56×。
   search 差分:wrapper(2×lastIndex 读 + 2×写 + @@search 读 + index 读)
   zjs ~790ns vs qjs ~159ns。
2. **match 数组构造 = 通用分配地板**(exec 2.4×、match-g 残差):
   createInternal/shape append/GC page/destroy,qjs 同样建数组但 ~3× 便宜。
   已有 memory 实证(general-alloc-floor-proof)。
3. **调用机制**(fib 4.14/funcall 3.74 前沿的投影):两层 native call
   (s.replace record + @@replace record)zjs ~37ns vs qjs
   JS_CallInternal+js_call_c_function ~24ns。

## 门禁

- test262 全量:0/49775 errors,passed 44588,known 13(与 main 基线一致)
- 冒烟:replace/replaceAll/accessor 4 套 90+ 形态与 qjs 逐字一致
  (含 $ 模式全集、空串、宽窄转换、代理项、子类覆盖、cross-proto receiver)
