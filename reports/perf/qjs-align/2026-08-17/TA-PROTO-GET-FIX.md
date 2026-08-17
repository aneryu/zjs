# TA-PROTO-GET-FIX — TypedArray proto [[Get]] 规范下标

日期：2026-08-17。**正确性修复，非优化。** 候裁合入。

| | |
|---|---|
| 分支 | `grok/ta-proto-get` |
| 基 | `main@0f721021` |
| worktree | `/home/aneryu/worktree-grok-ta-proto-get` |
| 洞 | S1（`PROTO-WALK-EXOTIC-AUDIT`）：TA-as-proto `[[Get]]` 数字下标 |
| qjs | `JS_GetPropertyInternal` `is_exotic && fast_array`（`quickjs.c:8296-8316`），**每层**，与 receiver 无关 |

---

## 0. 一句话

`getSlowPropertyValueFromObject`（以及 `getSuperPropertyValue`）在 own miss 之后补上与 receiver 前缀相同的 `typedArrayCanonicalGet`。`Object.create(new Uint8Array([7,8]))[0]` / `o["0"]` 现为 **7**，与 qjs 齐。

---

## 1. 洞

同族不对称（w43 同形状）：

| 兄弟 | 有无 TA 规范下标 |
|---|---|
| `getValueProperty` receiver 前缀（`object_ops.zig:2826`） | 有 `typedArrayCanonicalGet` |
| `ordinaryHasValueProperty` proto 走 | 有 `typedArrayCanonicalHas` |
| **GET proto 走 `getSlowPropertyValueFromObject`** | **无** → 链上 TA 只走 `getOwnProperty`（shape / dense，不含 TA 载荷） |

qjs 8296–8303：own miss 后 `p->is_exotic && p->fast_array`；tagged-int 且 `idx < count` → `JS_GetPropertyUint32`。不要求 `p == this_obj`。

战前：`o[0]` / `o["0"]` = `undefined`。HAS `0 in o` 已是 true。

---

## 2. 修

`src/exec/object_ops.zig`：

1. **`getSlowPropertyValueFromObject`** — Proxy 臂之后、`getOwnProperty` 之前：`isTypedArrayObject` 则 `typedArrayCanonicalGet`。  
   - `.index` in-range → 元素  
   - OOB / 非规范数字 → `undefined`（停走，对齐 8304–8315）  
   - `.none`（具名）→ `null`，继续 `getOwnProperty` / 下一环  
2. **`getSuperPropertyValue`** — 同臂。super 从 home proto 起走，同一 GetInternal 纪律。

未改 get_field 热叶：TA proto 已是 `needsSlowPropertyAccess` → resolver。未改 receiver 前缀。未改 SET/HAS。

`src/tests/exec.zig`：PoC 双案 `o[0]` + `o["0"]`，外加 `o[1]`/`o[2]`、`0 in o`、own=false、数组原型对照。

---

## 3. 门

| 门 | 结果 |
|---|---|
| `zig build test-exec --seed 0 --summary all` | **481 passed**（含新案） |
| PoC `/tmp/lanes/proto-walk-exotic/poc-ta.js` z-dev vs qjs | **`o[0]`/`o["0"]` = 7**，与 q 齐。`TA_length` 仍只差文案 |
| test262 全量 `run-test262 -t 8 -c test262.conf -d test262/test 0 100000` | **0/49775 errors**，passed 44581，3518 excluded，5194 skipped。报告在 `/tmp/lanes/ta-proto-get-test262`（**未写** `reports/**`） |
| `git diff --check` | 过 |

---

## 4. 范围

- 只动 `object_ops.zig` + `exec.zig` 测试。
- 不改 `test262.conf` / `test262_errors.txt` / `reports/**` / `docs/**` / `tools/perf/**`。
- 未 push。

请裁合入。
