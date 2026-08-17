# IC-FIXTURES — IC 语义对抗夹具套件

日期：2026-08-17。**只测试，不写产品码。**  
对照 `IC-SPIKE.md` **§1.3 可观察等价表**。pQ `grok/ic-p1` 引用本目录。

| | |
|---|---|
| 夹具 | `/tmp/lanes/ic-fixtures/js/0{1-7}-*.js` |
| 钉死输出 | `/tmp/lanes/ic-fixtures/expected/*.out`（zjs ≡ qjs，本尺已双跑） |
| 跑机 | `/tmp/lanes/ic-fixtures/run-difftest.sh` |
| Zig 草稿 | `/tmp/lanes/ic-fixtures/zig/`（OOM 注入 / get_field2 注记；pQ 抄进 `src/tests`） |
| 本尺二进制 | `/home/aneryu/zjs/zig-out/bin/zjs` · `/home/aneryu/quickjs/qjs` |
| 今日 IC | **无**（`cached*` 恒 miss）。本套钉的是 **走 walk 也必须成立** 的语义；P1 命中臂不得改这些行 |

跑：

```bash
/tmp/lanes/ic-fixtures/run-difftest.sh
# 或 ZJS=/path/to/zjs-with-ic QJS=/home/aneryu/quickjs/qjs /tmp/lanes/ic-fixtures/run-difftest.sh
```

七案本尺全部 `IDENTICAL` exit 0。

---

## 与 §1.3 的映射

| # | 案 | §1.3 行 | IC 若撒谎会印出什么 |
|---|---|---|---|
| **①** | in-place delete 后同位点读 | **delete**：同位不换 `shape*`，靠 Property 字；**禁止学缺席** | `after-delete 1` 或 `proto-fill 1` 或 `slot-reuse-x 77` |
| **②** | defineProperty 数据→getter | **define / 数据→访问器**：字变 → miss；禁缓存 getter 对象当值 | `g1 1` 且 `n 0`（当数据读）或 `n` 不递增 |
| **③** | 原型替换后 own 位点 | **原型链变更**：v1 不缓存原型槽；换 proto = 新 `shape*` | `hidden-b 1` 或 `own-after-setproto` 丢 own；`falls-to-new-proto 22` |
| **④** | Proxy 接收者过学过的位点 | **Proxy**：不填表；之后仍走 trap | `proxy1 1 traps 0` |
| **⑤** | delete+re-define 风暴 | delete + define + 槽复用；无广播失效 | 风暴中 `d N` 不是 `undefined`；`storm-x 99` |
| **⑥** | OOM-in-learn | learn 分配失败不得留半槽 | 见下；JS 钉的是成功路径语义 |
| **⑦** | get_field2 不释放接收者 | P3 / `op_get_field2`：值 **dup**，接收者留在栈下 | `method undefined` / 崩溃 / `both` 坏；`temp` 不是 `"temp"` |

① 是 **IC-R1** 承重案（Property 字变化、in-place delete、槽复用）。

---

## 每案：形、期望、IC-R1 用法

输出已钉在 `expected/<name>.out`。下面是全文（与文件一致）。zjs / qjs **同一份**。

### ① `01-inplace-delete.js` — IC-R1

热循环 `site(o)` 学 `o.x=1`。`delete o.x` **不换 shape\***。随后：

- 读 `undefined`（不是 1）
- `Object.prototype.x = 99` 必须看见 99（**没学缺席**）
- 再 `o.z = 77`（可能复用槽）时 `site(o)` 仍是 `undefined`，不是 77

```
warm 1
after-delete undefined
own false
proto-fill 99
proto-cleared undefined
slot-reuse-x undefined
slot-reuse-z 77
y 2
```

### ② `02-define-data-to-getter.js`

学数据 `x=1` 后 `defineProperty` 换成 getter。每次读必须进 getter（`n` 递增，值 41/42/43）。改回数据后是 7，且不再加 `n`。

```
warm 1
g1 41 n 1
g2 42 n 2
g3 43 n 3
data-again 7 n 3
```

### ③ `03-proto-replace-own.js`

own 位点在 `setPrototypeOf` 后仍是 own 值；`hidden` 跟新原型。删 own 后落到新原型。第二条链：先只读原型、再加 own、再换原型、再删 own。

```
own-warm 7
hidden-a 1
own-after-setproto 7
hidden-b 2
own-write 8
own-deleted-hidden 2
own-deleted-own undefined
proto-only 11
now-own 22
own-survives-new-proto 22
falls-to-new-proto 99
```

### ④ `04-proxy-through-learned-site.js`

同一 `site` 先在普通对象上学，再把 **Proxy** 喂进去：必须 trap（+10），`traps` 每次 +1。只见过 Proxy 的位点同样每次 trap。

```
ordinary 1
proxy1 11 traps 1
proxy2 11 traps 2
target-still 1 traps 2
proxy-only 151 pTraps 51
```

（`pTraps=51`：循环 50 次 + 最后一次打印。）

### ⑤ `05-delete-redefine-storm.js`

12 轮 delete → 读 undefined → define 回 `i`。`acc=0+…+11=66`。随后删 `x` 加 `z`（槽复用），再数据↔getter。

```
warm 0
d 0 undefined
v 0 0
…（d/v 1..11 同形）
acc 66
storm-x undefined
storm-z 99
storm-y 1
storm-get 51 n 1
storm-data 3 n 1
```

全文见 `expected/05-delete-redefine-storm.out`。

### ⑥ `06-oom-in-learn.js` + Zig 草稿

**JS 不能注入引擎分配器。** 本 JS 是成功路径金丝雀（学循环后改槽仍读新值）：

```
learn-loop 41
after-store 42
extra 0
```

可注入面：`zig/06-oom-learn.zig` 给 pQ 抄进 `src/tests/oom.zig` corpus。合同：

- `checkAllAllocationFailures`：init+eval 要么 `learn-loop:42`，要么 `error.OutOfMemory`，allocated==freed
- **同一 runtime** 的 post canary `site({k:7})` → `"7"`
- IC 落地后：learn 分配 FB 表失败 **不得**留下半填的 mono 槽（之后再读走 walk，值仍对）

今日无 IC，sweep 仍合法（bootstrap 分配点）。P1 加上表分配后这行才真正打到 learn。

### ⑦ `07-get-field2-keep-receiver.js`

`o.m()` / `o.a+o.b` / `o.inner.v` / 临时对象当 `this`。命中臂若误走 `get_field` 的释放接收者路径，`this.tag` 或第二次读会坏。

```
method alive calls 201 tag alive
both 7 a 3 b 4
chain 5 inner 5
temp temp
```

源注：`tailcall_dispatch.zig` `op_get_field2` — 槽值 **borrow+dup**，接收者留在下面，没有释放。

---

## pQ 用法

1. P1 实现后 `ZJS=zig-out/bin/zjs /tmp/lanes/ic-fixtures/run-difftest.sh` 必须仍 7/7 IDENTICAL。
2. **① 是 IC-R1 门。** 先红这一案再谈 cyc。
3. 把 `zig/06-oom-learn.zig` 的 corpus 行并进 `test-oom`（阶段门，不是每编）。
4. 不要改 `expected/*.out` 去迁就 IC。输出变了 = 语义破。
5. 禁把这些脚本收成 `prop_read_mono_loop` 式过线夹具（SPIKE §1.4）。

---

## 本尺

| | |
|---|---|
| 双跑 | official `zjs` + `qjs`，七案输出逐字节相同 |
| 产品码 | **未改** |
| `run-difftest.sh` | exit 0 |
