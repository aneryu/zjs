# PROTO-WALK-EXOTIC-AUDIT — 原型走 / own 快路径 vs exotic·Proxy·TA

日期：2026-08-17。**只析不改。发现洞报裁。无产品 commit。**

w43 原洞形状（`e1a7432f`）：`setOrDefineOwnDataPropertyForPutFieldOwned` 原型走只看 `has_exotic_methods`；Proxy 的 trap 在 **class switch** 不在 exotic 表，所以被当成普通 proto，own 槽直接 `add_property`，`[[Set]]` 永不跑。兄弟 `defineNewOwnDataPropertyForSimpleSetKnownNoOwn` 已有 `proxyTarget()`。**同族函数检查不对称 = 洞的形状。**

本普查：所有原型走 / own 快路径（get / put / define / delete / has / instanceof），对 exotic / Proxy / typed-array proto 的检查是否完整；逐条对 `quickjs.c` 拦在哪一层。

| | |
|---|---|
| 源 | 本 worktree `daf1707d`（`setOrDefine` 已有 `proxyTarget()`，**无** `e1a7432f` 的 `isProxy()`） |
| 对照二进制 | 本树 `zig-out`；生产 `/home/aneryu/zjs`（含 w43 `isProxy`）；qjs `/tmp/qjs-r4-labels/qjs` |
| PoC | `/tmp/lanes/proto-walk-exotic/{poc,poc-ta}.js` |
| 数字 | 语义差分，非裁决 |

---

## 0. 一句话

**有一条姐妹洞，不是「无姐妹洞」封条。**

w43 的 **live Proxy proto `[[Set]]`（H1）在本树和生产都已对齐**（trap 跑、不建 own 槽）。  
同形状的漏网是 **TypedArray 作为原型时的 `[[Get]]` 规范数字下标**：兄弟函数（TA 当 *receiver* 的 `typedArrayCanonicalGet`、HAS 原型走的 `typedArrayCanonicalHas`）有检查，**GET 原型走的 `getSlowPropertyValueFromObject` 没有**。qjs 拦在 `JS_GetPropertyInternal` 的 `is_exotic && fast_array` 臂（`quickjs.c:8296–8303`），与 receiver 是否是 TA **无关**。

```js
var o = Object.create(new Uint8Array([7, 8]));
o[0];     // q = 7；z = undefined
o["0"];   // 同上
```

Array / Arguments / `String` 对象当原型 **没有** 这个洞（`getOwnProperty` 有 `denseArrayElement` / 字符串下标）。Proxy 原型 get/put/has、revoked TypeError、define、delete、instanceof 与 q 语义一致（revoked 只差文案）。

---

## 1. qjs 拦在哪一层

| 族 | qjs 入口 | exotic / Proxy / TA proto 怎么进 trap |
|---|---|---|
| **Get** | `GET_FIELD_INLINE` 19134：own miss 后 `p->is_exotic` → `JS_GetPropertyInternal` | 每层 own `find_own` 之后：`is_exotic`；`fast_array`+tagged-int 且 `idx < count` → `JS_GetPropertyUint32`（**TA/Array 元素，不看 p 是不是 receiver**）；非 fast_array → `em->get_property`（Proxy `js_proxy_get`） |
| **Set** | `OP_put_field` own miss → `JS_SetPropertyInternal` 9739 | 每层：`is_exotic`；`em->set_property`（Proxy `js_proxy_set`，receiver=原 `this_obj`）；TA `fast_array` 下标 in-range 且 `p!=p1` → `break` 后在 receiver 上 add own |
| **Has** | `JS_HasProperty` → exotic `has_property` / TA 下标 | Proxy `js_proxy_has`；TA in-range 为 true |
| **Delete** | `JS_DeleteProperty` **只 own** | Proxy `js_proxy_delete_property`。proto 的 delete trap **不应**因 `delete child.k` 触发（H11 两边 hits=[]） |
| **Define** | `JS_DefineProperty` **只 own** | Proxy proto 的 `defineProperty` trap 不跑（H19） |
| **instanceof** | `JS_IsInstanceOf` → `JS_GetProperty(@@hasInstance)` | Get 纪律：RHS 是 Proxy 则 `em->get_property` |

z 的关键不对称：Proxy **没有** `has_exotic_methods`（trap 在 `class_id == proxy`）。因此只查 `hasExoticMethods()` 的走会漏 Proxy——这就是 w43。TA **有** `needsSlowPropertyAccess`（class 表），但 GET 慢臂没有把 TA 元素读出来。

---

## 2. 路径清单（本树源）

谓词：`Ex` = `hasExoticMethods`；`PT` = `proxyTarget()!=null`；`IP` = `isProxy`/`class_id==proxy`；`NS` = `needsSlowPropertyAccess`（含 proxy + 全部 TA class）；`TA` = `isTypedArrayObject` / `typedArrayCanonical*`。

| # | 路径 | 文件 | proto / own | Ex | PT | IP/NS | TA | qjs 层 | 实证 |
|---|---|---|---|---|---|---|---|---|---|
| G1 | `qjsGetFieldFastSlotWithExoticOrder` | `vm_property_field.zig:455–505` | proto 走 | — | — | **NS**（miss→resolver） | NS 含 TA | GET_FIELD 19134 | 活 Proxy GET 对齐；TA proto 进 resolver |
| G2 | `getValueProperty` receiver 前缀 | `object_ops.zig:2823–2842` | **只 receiver** | 数组密臂 | — | **IP** | **`typedArrayCanonicalGet`** | GetInternal 8296 | TA **当 receiver** 正确 |
| G3 | `getPropertyValueFromObjectChain` + `getSlowPropertyValueFromObject` | `object_ops.zig:3943–3998` | proto 走 | — | — | IP 只走 Proxy trap；然后 `getOwnProperty` | **无 CanonicalGet** | GetInternal **每层** exotic | **S1 洞** |
| G4 | `getValuePropertyWithReceiver` | `object_ops.zig:3087` | proto | — | PT | — | 无 | Reflect.get | 未单列；与 G3 同缺 TA |
| P1 | `setOrDefine…PutFieldOwned` proto | `object.zig:11249` | proto | Ex | **PT** | 无 IP | `isTypedArrayObjectForSetFastPath` → slow | SPI 9739 `em->set_property` | H1 活 Proxy SET **齐** |
| P2 | `defineNewOwnData…KnownNoOwn` proto | `object.zig:11114` | proto | Ex | **PT** | — | TA → false | 同上 | 与 P1 对称（本树已齐） |
| P3 | `firstProxyInPrototypeSetPath` | `object_ops.zig:5384` | proto | — | PT | — | — | 慢路径补网 | 活 Proxy 能捞到 |
| P4 | `setValueProperty` receiver | `object_ops.zig:3240` | own | — | PT | — | TA canonical set | SPI own / exotic | 活/revoked SET 齐（H3 TypeError） |
| H1a | `ordinaryHasValueProperty` proto | `object_ops.zig:4169` | proto | — | PT | — | **`typedArrayCanonicalHas` + `indexedExoticHas`** | HasProperty | H6 活 Proxy HAS 齐；TA HAS 齐 |
| H1b | `hasValueProperty` receiver | `object_ops.zig:4126` | own | — | PT | — | 进 ordinary | `js_proxy_has` | H8 TypeError |
| D1 | `deletePropertyVm` | `vm_property_ref.zig:467` | **只 own** | — | PT | — | `typedArrayCanonicalDelete` | Delete 10920 | H11 proto delete 不进 trap（齐）；H10 revoked TypeError |
| Def | `definePlainDataPropertyKnownFast` / `OP_define_field` | `object.zig:11725` | **只 own** | 调用方保证普通对象 | — | — | — | Define 10164 `is_exotic` 门 | H19 proto define trap 不跑（齐） |
| I1 | `probePublicNamedDataPropertyFromObject` | `object_ops.zig:2904` | proto | — | — | **NS** → slow Get | NS 含 TA | IsInstanceOf → Get @@hasInstance | H17/H18 齐 |
| X1 | `arrayPrototypeChainAllowsBulkIndexedSet` | `object.zig:10819` | proto | Ex | PT | — | 无（保守 false 即可） | 无直接 q 对 | 批量优化门，不是语义入口 |

**洞形状对照（w43）：** P1 曾经缺 IP/PT、P2 有 PT。本树 P1/P2 都有 PT，H1 已齐。  
**新不对称：** G2 有 TA CanonicalGet，G3 无；H1a 有 CanonicalHas。GET 相对 HAS / receiver-GET 漏了一层。

---

## 3. 洞清单（请裁）

### S1 — TypedArray proto `[[Get]]` 规范数字下标（姐妹洞，确认）

| | |
|---|---|
| 形状 | 与 w43 同族：兄弟有检查、原型走没有。`getValueProperty` 只对 **receiver** 调 `typedArrayCanonicalGet`（2826–2832）。链上 TA 进 `getSlowPropertyValueFromObject`，只认 Proxy class / `getOwnProperty`。`getOwnProperty` 有数组 `denseArrayElement`，**没有** TA 载荷。HAS 的 `ordinaryHasValueProperty` **有** `typedArrayCanonicalHas(proto)`（4177）。 |
| qjs | `JS_GetPropertyInternal` 8296–8303：own miss 后 `is_exotic && fast_array && tagged-int && idx < count` → `JS_GetPropertyUint32`。不要求 `p == this_obj`。 |
| 观察 | `o[0]` 与 `o["0"]` 同（`get_array_el` 冷臂最终也进 `getValueProperty`）。 |

**PoC**

```js
var ta = new Uint8Array([7, 8]);
var o = Object.create(ta);
print(o[0]);     // expect 7
print(o["0"]);   // expect 7
print(0 in o);   // expect true   (HAS 已齐，对照用)
```

| 引擎 | `o[0]` / `o["0"]` | `0 in o` |
|---|---|---|
| qjs | **7** | true |
| z 本树 / 生产 | **undefined** | true |

`TA_length`（`o.length`）两边都是 getter `this` 不是 TypedArray → TypeError，只差文案，**不是洞**。  
`Object.create([7,8])[0]`、`Object.create(new String("ab"))[0]` 两边都对。

**建议修法（不实施）：** `getSlowPropertyValueFromObject` 在 Proxy 臂之后、`getOwnProperty` 之前（或 miss 之后）对 TA 调 `typedArrayCanonicalGet`，与 `getValueProperty` 2826 和 HAS 4177 对齐。qjs 是 GetInternal 一层、每环都问 `is_exotic`。

---

## 4. 已齐 / 非洞

| 案 | 两边 | 说明 |
|---|---|---|
| H1 live Proxy proto SET | trap 跑、`own:false` | w43 原洞，本树 PT + 生产 `isProxy` 都挡住 |
| H2/H3 revoked SET | TypeError | z 文案空，q 为 `revoked proxy`。**语义齐** |
| H4/H5 Proxy proto GET | 活=42+trap；revoked=TypeError `revoked proxy` | G1 NS + G3 IP |
| H6–H8 `in` | 活 trap；revoked TypeError | H1a PT |
| H9 revoked GET receiver | TypeError `revoked proxy` | G2 IP |
| H10 revoked delete | TypeError | D1 PT → 慢路径 |
| H11 proto delete | `d:true` hits=[] | Delete 只 own |
| H12–H14 TA proto SET | in-range 建 own；oob 不建；named 建 own | 与 q SPI `p!=p1` → add / oob no-op 齐 |
| H16 TA proto HAS | `0 in o` true，`9 in o` false | H1a CanonicalHas |
| H17/H18 instanceof | trap / revoked TypeError | I1 NS |
| H19 define own + Proxy proto | define trap 不跑 | Define 只 own |
| H20 `Reflect.set` + Proxy proto | trap、receiver 对 | P3 / proxySet |

`proxyTarget()!=null` vs `isProxy()`：revoked 后 target 被清空（`object.zig:4083`）。本轮 revoked SET/HAS/DELETE **仍 TypeError**（慢路径 `proxyTarget() orelse error.TypeError`），没有再变成「静默建槽」。谓词不对称还在源码里，但 **不是本轮能证出的语义洞**。w43 主钉用 `isProxy()` 更贴 class。

---

## 5. 请裁

| # | 裁 | 备注 |
|---|---|---|
| **S1** | **洞，建议修** | GET 原型走补 `typedArrayCanonicalGet`；与 HAS/receiver-GET 对称。PoC 三行。test262 可能已有 `TypedArray` + proto 链，本地 zoo 几乎走不到 |
| H1 | 不重开 | 已齐 |
| PT vs IP | 不单独立项 | 无观察差分 |
| emit/新机制 | 停 | 本层只报对齐洞 |

原始输出：`/tmp/lanes/proto-walk-exotic/{q,z-this,z-prod,q-ta,z-ta}.out`。
