# MIXED-EQ-SPLIT

枝 `grok/mixed-eq-split` **`5813a6c0`** @ `/home/aneryu/worktree-grok-mixed-eq`，基 `main@9deb9f45`。
只动 `src/exec/tailcall_dispatch.zig`。canonical zoo 归 w42，本 lane 未跑。数字非裁决。

---

## 改动逐条

1. **int 叶不动。** `opCompare` both-int 仍 64B：`orr; cbz; cmp; cset; br`。miss 仍 PC 相对 `b zjs_cmp_*_mixed`（硬门 #9）。`op_eq_if_false8` leftover miss 同样 `b zjs_cmp_eq_mixed`（`pc[0]` 不是 `op.eq`，不能四庙共用 `pc[0]` 分流）。

2. **`zjs_cmp_*_mixed` 改为无 `bl` 臂。** 新 `opCompareEqFast`：obj/obj 指针身份、`obj == null|undef` + `isHTMLDDA`、strict obj-vs-非对象 → false、null/undef、int/float/bool。RC 用 `releaseRefCountedNeedsDestroyDuringActiveBytecode`（只 dec）。入口无 `sub sp`，符号内无 `bl`。

3. **string / last-ref 归带帧兄弟。** 双串 `b zjs_cmp_*_framed`（原 `opCompareEq`：`sub #0x70` + `destroyZeroRef`×2 / `flatStringsEq` / `compareStringValues`）。lhs last-ref（NeedsDestroy 为真、栈未改）同样 `b *_framed`。rhs last-ref（lhs 已 dec、结果已写）经 `export var zjs_cmp_release_rhs_hop` `br` 到 `zjs_cmp_release_rhs`（destroy 那一侧）。hop 是为了挡 LTO 把小 destroy 折回 mixed。

4. **qjs 对位。** qjs `OP_CMP_EQ` / `OP_CMP_STRICT_EQ`（quickjs.c:20272-20398）在 `JS_CallInternal` 帧内近处理上述无 `bl` 形，不新开帧；`JS_FreeValue` / `js_string_eq` 是 JCI 已有帧上的近 `bl`。zjs 没有共享解释器帧，所以把无 `bl` 形留在无帧 export，把 qjs 那些 `bl` 对应的工作（串比较、last-ref destroy）留在带帧兄弟。

---

## RF 反汇编帧证据

二进制 `/home/aneryu/worktree-grok-mixed-eq/zig-out/bin/zjs`（mtime 随 worktree 迁入）。
`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

| 符号 | 址 | 体积 | 帧 | `bl` |
|---|---|---:|---|---|
| `op_eq` 叶 `117445` | `1074ec0` | **64B** | 无 | 无；miss `b 11938c4 zjs_cmp_eq_mixed` |
| `op_eq_if_false8` | `1074780` | 52B | 无 | 无；miss `b zjs_cmp_eq_mixed` |
| `zjs_cmp_eq_mixed` / `neq` | `11938c4` / `1194de8` | **484B** | **无 `sub sp`** | **无**；串/lhs last-ref `b *_framed`；rhs last-ref `adrp 149c000; ldr #88; br` |
| `zjs_cmp_strict_*_mixed` | `119476c` / `11945dc` | **400B** | 无 | 无 |
| `zjs_cmp_eq_framed` | `1193b30` | 664B | **`sub #0x70`** | destroy×2 / flat / rope |
| `zjs_cmp_*_framed` 其余 | | 628–668B | `#0x70` | 同 |
| `zjs_cmp_release_rhs` | `1193aa8` | 136B | 有 | destroy |

四座 mixed 全文扫 `sub sp` / `bl`：**NONE**。dump：`/tmp/lanes/ts-cmp-mixed/acc-eq_{leaf,mixed}.s`。

邻居 nm vs `/home/aneryu/zjs` @ `9deb9f45`：`get_field` / `put_field` / `eq_if_false8` / eq 叶 / `call_method` / `return` **同址同尺寸**，call/return 未滑。

---

## 自测（非裁决）

| 项 | 结果 |
|---|---|
| `zig build test-exec --seed 0` | **478/478** Debug |
| difftest 抽样 `dt-eq.js`（ident / null / 数字 / 串 / leftover） | **IDENTICAL** vs `/tmp/qjs-r4-labels/qjs` |
| difftest `dt-eq2.js`（last-ref `{}` / neq / strict / `0==false`） | **IDENTICAL** |
| `git diff --check` | PASS |
| 提交 | `5813a6c0`，正文含 qjs.c:20272-20398 / JCI 近处理对位 |

先前同树 CPU16 ABBA n=2 vs `9deb9f45`（件 `/tmp/census/det/typescript.js` 等；**非裁决、非 zoo**）：

| 案 | Δ insn | Δ cyc |
|---|---:|---:|
| TS | −135.5M（r=0.99834） | −84.2M |
| box2d | −14.9M | −10.2M |
| splay | +2.6M | +5.9M |

预算 −0.15~0.20G，自测 −0.136G，贴下沿。差额是串范围检查 + ABI 仍要重载操作数。

---

未改 test262.conf / reports / docs。未跑 canonical zoo。
