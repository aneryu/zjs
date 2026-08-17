# TAKE-GUARD-SLIM — TAKE 准入哨瘦身（**REJECT-ARCHIVE**，见 `/tmp/lanes/TAKE-GUARD-SLIM-REJECT.md`）

日期：2026-08-17。CPU **16**（`armv8_pmuv3_1`，避 5/6/7/19）。数字 **非裁决**。

| | |
|---|---|
| 分支 | `grok/take-guard-slim` @ **`9a950a82`** |
| 基 | `main` **`62552228`** |
| 配置 | `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |
| 问 | 四道 TAKE 哨（consumed 35 + applyForward 28 + find 24 + fused 28）收到一道；资格前移 emit/FB；禁名字特判；apply-forward 语义不破 |
| 门 | test-exec **481/481**；test262 **0/49775 errors**，passed 44581（`-R /tmp/lanes/take-guard-slim-test262`） |
| FW | boyer-only.d16 主尺 + deltablue / raytrace 哨；ABBA n=4；cyc 主尺 |
| 原始 | `/tmp/lanes/take-guard-slim/{fw.py,fw.json,ann-z-ctor.txt}` |

---

## 0. 一句话

**四道每发哨收成一道：fused 身份。**  
`consumedArgSlots` / `windowFits` / `applyForwardTakeOk` 在普通 `new` 上不再走 CallerState。apply-forward 仍看 FB 位，位置上则跑原来的 `applyForwardGuardHolds`（I4/D5 两案仍 miss TAKE）。

Boyer 主尺 **insn −265M**（vs 同机 base）；**cyc 1.004（+15M，噪声/未动）**。独占 handler 5.47%→4.59%，`consumedArgSlots` 14.2% 点从 annotate 消失。cyc 主尺 **没有**把 +160 吃掉——剩下的是 find + fused + install 窗 MOVE。

---

## 1. 改了什么

specialize（`cloneAndExpand`）一次写好：

| 事实 | 挂在哪 | 热路径 |
|---|---|---|
| `consumed_args` | `InlinedSite`（普通 ctor = `callee.arg_count`；L1 apply-fwd = `site.argc`） | 读字段，不走 `siteApplyForwarded` |
| `apply_forward_inlined` | 已有 `CallFacts` 镜像（header 0x14） | `if (!mirror) return true` |
| `has_ctor_take` / window 已证 | hot pad 第 17 字节 | 测试/普查；window 热路径只做 `locals.len` 整数比 |

`op_call_constructor` 第一臂：

```
constructorTakeSite          // 一道准入：CallerState 查找 + 位
  → poll                     // 仍在 fused 之前（q 20817）
  → tryFusedConstructor      // 唯一每发运行时身份哨
  → windowFits / consumed    // 记录 + 整数
  → install + release
```

第二臂（prepare 已建 instance）走 `constructorPreparedTakeReady`：同一套位 + `calleeMatches`。

**没有** `sc_Pair` / 函数名特判。所有 `kind == .constructor` 且 specialize 过的 site 同一条。

**apply-forward 不破：** FB 位为真时仍 `applyForwardGuardHolds`（proto 链方法无 own `apply`，`Function.prototype.apply` 仍是 realm builtin）。现有 L1 两案（own apply / 换掉 `Function.prototype.apply`）仍在 test-exec 里。

---

## 2. 门

| 门 | 结果 |
|---|---|
| `zig build test-exec --seed 0` | **481 passed** |
| `run-test262 -t 8 -c test262.conf -d test262/test -R /tmp/lanes/take-guard-slim-test262 0 100000` | **0/49775 errors**，passed 44581，3518 excluded，5194 skipped |

test262 报告不进 `reports/**`。

---

## 3. FW（CPU16，ABBA n=4，cyc 主尺）

`z_new` = 本枝 RF。`z_base` = `/home/aneryu/zjs` 生产件。`q` = `/tmp/qjs-r4-labels/qjs`。

### 3.1 vs q

| 尺 | q cyc | z cyc | Δ cyc | z/q cyc | z/q insn |
|---|---:|---:|---:|---:|---:|
| **boyer-only.d16** | 2974.5M | 3330.2M | **+355.7M** | **1.120** | **1.045** |
| deltablue | 80122M | 79054M | −1068M | 0.987 | 1.179 |
| raytrace | 50896M | 47266M | −3629M | 0.929 | 0.907 |

Boyer vs 分解尺（`BOYER-RESID` +350 / insn 1.062）：insn 比从 1.062→**1.045**（少约 246M insn vs q）。cyc 比仍 ~1.12。

### 3.2 vs 同机 base（刀本身）

| 尺 | base cyc | new cyc | Δ cyc | cyc 比 | Δ insn |
|---|---:|---:|---:|---:|---:|
| **boyer-only.d16** | 3378.6M | 3393.5M | **+14.9M** | **1.004** | **−265.4M** |
| deltablue | 78417M | 78906M | +489M | 1.006 | +64M |
| raytrace | 46608M | 47138M | +530M | 1.011 | **−1544M** |

**cyc 主尺：三凳都在 1.00x，未宣称周期赢。**  
Boyer / raytrace **insn 明显下降**（哨走访没了）。DB 不是 TAKE 热凳，insn 齐。

Boyer new-vs-base 样本交叠（new 3358–3417，base 3349–3413）。+15M 当噪声，不当回退。

### 3.3 独占 sit（新件，boyer-only，`cycles/u`）

| 符号 | 旧 % | 新 % |
|---|---:|---:|
| `op_call_constructor` | 5.47（181M） | **4.59** |
| `installInlineWindow` | 0.94 | 1.50 |
| annotate `consumedArgSlots` / `small_inline.zig:1280` | **14.20** 单点 | **消失** |
| annotate `applyForward` / `:199` | 7.16 | **消失** |

handler 热点改成 install / `hotExtension`（find）/ fused `objectFromValue` / 区 RC——即留下的那一道身份哨 + 窗 MOVE。

---

## 4. 和 +160 的关系

分解把 +160 钉在 TAKE 准入 + 窗 MOVE。本刀吃的是 **准入走访**（insn 侧坐实 −265M），**不是** `installInlineWindow` 31M，也不是 fused 资格 28M。

剩下还在：

- `tryFusedConstructor`（shape/proto/obj 指针，必须每发）
- `findInlinedSite`（还要拿 `pc_lo` / slots）
- `installInlineWindow` 窗 MOVE（q 没有对应窗）

cyc 没动，符合「走访是 insn 税、stall 在 fused/install/帧」：IPC 把少掉的 insn 吃掉了。再往下削是 fused 身份或窗 MOVE，不是本刀范围。

---

## 5. 不要做 / 没做

- 禁 `sc_Pair` / Boyer 函数名特判。
- 禁放开 2048、clone Earley、bypass。
- 禁动 `call_method` `0x3f0`。
- 不重开 get_field / instanceof / P6-B。
- 不把 +15M cyc 写成回退，也不把 −265M insn 写成 cyc 赢。

---

## 6. 终裁

**REJECT-ARCHIVE**（2026-08-17）。cyc 三凳全平 = OoO 吸收，常数 insn 税定理第四证。语义瘦身无周期收益，**不合入**。枝 `9a950a82` 封存。

归属改判（Entry → TAKE 窗）留在 `CTOR-DECOMP`，有价值，不随本刀作废。

全文 `/tmp/lanes/TAKE-GUARD-SLIM-REJECT.md`。
