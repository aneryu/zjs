# lastIndex 迁移:payload slot → shape first property(qjs 忠实形态)

背景:用户质疑「性能修复是对齐 qjs 的实现吗」——审计结论:regexp-align
(e8ee55b)六项修复全部有 qjs 锚点 ✓;但后续尝试的 A(getValueProperty 加
regexp lastIndex 特判)/C(setValuePropertyStrict 同)**不是 qjs 形态**
(qjs 通用协议对 lastIndex 零特判),已撤销。B(proto walk data hit 消
descriptor 物化)是 qjs 形态方向,保留。

## qjs ground truth

- `js_regexp_constructor_internal`(quickjs.c:47695):
  `JS_DefinePropertyValue(ctx, obj, JS_ATOM_lastIndex, JS_NewInt32(0),
  JS_PROP_WRITABLE)` —— lastIndex 是**普通 shape 属性**(writable,
  non-enumerable, non-configurable),`u.regexp` 只有 {pattern, bytecode}。
- 引擎内部热点(exec/replace)用 `js_regexp_get_lastIndex` /
  `js_regexp_set_lastIndex`(48076/48091):注释 "lastIndex is always the
  **first property**",`p->prop[0].u.value` 直读 + shape 第一个 prop 的
  WRITABLE 位检查;非 int/非 writable 落 JS_Get/SetProperty 通用路径。
- Symbol.search/match/split 的 lastIndex 读写走**通用协议**
  (48514-48682),无特判——通用协议快是因为 lastIndex 本来就在 shape 表。

## zjs 现状(偏离)

`RegExpPayload{source, last_index, last_index_writable, compiled_bytecode,
realm_global_ptr}`(core/object.zig:429)——lastIndex/writable 存 payload
slot,不在 shape。由此滋生特判族(全部是 qjs 没有的):
- getOwnProperty 合成 descriptor(object.zig:6950)
- snapshot-enumerable/hasOwnProperty/ownPropertyEnumerable/getProperty/
  setProperty 特判(7032/7045/7082/7112/7157/7849)
- reserveOwnPropertyCapacityAssumingPlain 等 asserts(7890/7905/7951)
- defineOwnProperty 的 lastIndex 分支(writable 翻转走 slot)
- GC/refcount:payload.last_index trace(6860)+ destroy
- 33 个 helper 调用点(regexp_fastpath/string_ops/builtins/regexp/property_ic)

## 迁移步骤

1. **构造**:所有 regexp 对象创建点(builtins/regexp constructCompiled 一族 +
   compile 重编译路径)在对象创建后第一个 define
   `lastIndex = int32(0)`(writable, !enum, !config)→ 保证 prop[0]。
   compile 后 qjs 重置 lastIndex=0(JS_SetProperty)。
2. **payload 删字段**:last_index/last_index_writable 出 RegExpPayload
   (结构对齐 qjs u.regexp + realm_global_ptr zjs 适配);destroy/GC trace 同步。
3. **helper 重写**(js_regexp_get/set_lastIndex 镜像):
   - `regexpLastIndex()` → prop[0] 直读(atom 校验防御,miss 走 findProperty)
   - `regexpLastIndexWritable()` → shape prop[0] 的 writable flag
   - `setRegExpLastIndex*` → writable 检查 + prop_values[0] 写(free 旧值);
     非 writable/非常规落通用 setValuePropertyStrict(qjs 48099 else 分支)
4. **特判删除**:上列全部——通用协议(findProperty 自然命中)接管。
   defineOwnProperty 走通用 non-configurable data 重定义规则
   (writable true→false 合法、值改需 writable)。
5. **验证**:冒烟(读写/writable 翻转/delete 失败/gOPD 形状/keys 不含/
   exec-g 推进/compile 重置/Object.freeze(rx))+ 全量 test262 + perf
   (search/match/split;通用协议 own 段的 descriptor 往返仍在——那属于
   JS_GetPropertyInternal 镜像切片,迁移本身性能中性,价值=结构对齐+
   消特判族)。

## 风险

- property 核心 + GC 面;prop[0] 承诺依赖构造顺序(subclass 经同一构造点 ✓)。
- 已知雷:own-hit 放宽曾爆 55 隐藏语义回归(getValueProperty case 链顺序
  承载语义)——迁移**不动** getValueProperty 骨架,只删「合成特判」,
  shape 属性由既有通用分支处理,风险面不同源;仍以全量门禁为唯一裁判。
