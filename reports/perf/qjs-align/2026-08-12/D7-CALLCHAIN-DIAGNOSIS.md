# D7-CALLCHAIN 调用边界依赖链诊断与定价

日期：2026-08-12  
基线：e31af460d94c5c368a243f37afbf15d4cefed392  
裁决：**NO-GO**

## 结论

主假设被反汇编和双向探针共同证伪：生产路径没有「把 callee pc 发布进 Vm，再从
Vm 追出 pc，最后决定首个 handler」这条 store→load 关键链。callee 的 code pointer
一直留在寄存器 x24；首分派只有「x24 → opcode byte → handler table entry」两级相关
load。Vm 的六次发布都是 fire-and-forget，首 handler 地址不读它们的结果。

把首分派强行直达一个已由 counter 证明的 return_undef handler（语义无效、仅适用于
A_direct_call）最多只省 **0.536 cyc/call**；相反，把一条真实
Vm.frame/Vm.stack store→load→pointer-chase 链强行塞回去，会多付
**2.32–2.44 cyc/call**。探针对依赖链是敏感的，但生产代码没有被指控的链。

因此，12.78 cyc/call 非访存后端停顿不能逐节摊到一条不存在的链上。严格可实现上限是
**0 cyc/call、所有基准 0 Mcyc、Zoo geomean +0.000%**。即使把语义无效的
0.536 cyc/call 当成所有 JS→JS 调用都能收掉的极乐观敏感性上界，Zoo geomean 也只有
**+0.0929%**，低于 +0.5% 开工线。D7 路线关闭。

## 0. 证据与测量合同

先全文读取：

- canonical worktree 的 EARLEY-BOYER-ATTRIBUTION.md（本 worktree 未携带该新文件）；
- canonical worktree 的 RAYTRACE-ATTRIBUTION.md（同上）；
- 当前 worktree 的 measurement-contracts.md，确认现有条款是 **11 条**；
- D1-CALLBOUNDARY-DIAGNOSIS/EVIDENCE 和 IMPL-TEARDOWN-OUTCOME，只作同日上游证据，
  不把历史单位成本冒充本轮生产单位成本。

生产配置：

    zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off

固定二进制：

| 二进制 | commit / 用途 | SHA-256 |
|---|---|---|
| zjs base1 | e31af460，生产 | 531c1bc947ba67a45382d7d93937f93a57917abe94825d28e0656cfe6f8c25e6 |
| zjs base2 | e31af460，独立冷构建，生产 | 6806db216ac5ee71260f574440450ac97a9067188dca006d6d66206b017a81e7 |
| qjs | 04be2460，未重建 | b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d |
| zjs-profile | counter，只供频率 | d7d7a87118b20bb9117d4f0f543167a9a4d8fae486a19df0bcb0b0fb44c4ae5b |

同一源码的两个生产冷构建 SHA 不同，再次命中 Zig 0.16 build bistability。因此探针均做
两次冷构建，并对两个独立 baseline 做完整 2×2 比较，不把跨构建漂移算成候选收益。

perf 合同：CPU 5；armv8_pmuv3_1；不加 flock；一个时刻只有一个 CPU 5 被测进程；
其他任务只在各自分配核运行；每 case 8 samples；奇数轮正序、偶数轮严格反序的平衡
ABBA；instructions、cycles、stall_backend、stall_backend_mem、stall_frontend 同测；
过滤未绑核 PMU；所有 stdout 均为 0。净值定义为：

    (A_direct_call - empty) / 30,000,000
      - (ctrl - empty) / 200,000,000

原始测量 JSON SHA-256：
ef7ba90998ff69d4b4911557ce262d73169374e2bfe89a7b7db653c778c4db51。
保留的 8 个样本、median、MAD 和全部 2×2 配对见 D7-CALLCHAIN-EVIDENCE.json。

本轮生产复测：

| engine | insn/call | cyc/call | stall_be | stall_be_mem | stall_fe |
|---|---:|---:|---:|---:|---:|
| qjs | 290.099 | 40.782 | 7.510 | 0.0339 | 0.0178 |
| zjs base1 | 348.141 | 59.396 | 20.978 | 0.0439 | 0.0380 |
| zjs base2 | 348.141 | 59.229 | 20.850 | 0.0452 | 0.0299 |
| base1−qjs | +58.042 | +18.613 | +13.468 | +0.0101 | +0.0201 |
| base2−qjs | +58.042 | +18.446 | +13.339 | +0.0113 | +0.0121 |

方向复现了任务输入：超额是非访存 backend，memory/frontend 近零。

## Q1 — 实际链是什么

### Q1.1 宏观路径先由出线口证明

zjs-profile 在同一 A_direct_call 语料上计到：

| case | op_call2 | return_undef | call frames | stdout |
|---|---:|---:|---:|---:|
| A_direct_call | 30,000,000 | 30,000,000 | 30,000,002 | 0 |
| ctrl | 0 | 0 | 2 | 0 |

这既是已知正例，也是负例。counter 只证明路线和频率，不参与任何单位成本。

正式 IP 采样对 A/ctrl 各做 8 次 ABBA，instructions 与 cycles period 都是 500009，
只采 physical IP，无 DWARF callchain 丢样；PERF_RECORD_LOST 为 0。A 在
op_call2 → enterEntry → 首分派的每个关键 IP 都有样本，ctrl 在下列 IP 全为零。
addr2line -f -i 把 0x127a774–0x127a7a8 映到 enterEntry:476–482，
0x127a7b4 映到 next:268，0x127a7b8–0x127a7bc 映到 enterEntry:496–497，
最终 transfer 映回 opCall:1469 的 inline 链。

### Q1.2 Vm 字段发布与消费者

普通 JS→JS 热调用在 enterEntry 只发布六个字段。这里“级数”指从当前已有
Entry/Vm 指针到值或消费者地址的相关 pointer loads；地址加法不算一级。

| Vm 字段（offset） | 每 call 写入者 | 首 handler 前的实际读取 | 级数 / 依赖 | 判定 |
|---|---|---|---|---|
| function (+8) | enterEntry，str x20 | 无；写前 ldr entry.frame.function 只做 byteCode materialize check | Entry→function 为 1；store 后 0 | 首分派不依赖 store |
| frame (+24) | enterEntry，str x25 | 无；vb 直接 ldr [entry,#48] | 写后 0 | 首分派不 reload Vm.frame |
| var_refs_base (+72) | enterEntry，ldr [entry,#80] 后 str | 无 | Entry→var_refs.ptr 为 1；写后 0 | 后续 var-ref handler 的 resident mirror |
| stack (+32) | enterEntry，str entry+0x98 | 无；sp 直接 ldr [entry,#168] | 地址 add；写后 0 | 源码的 Vm.stack 被 SROA 成 Entry load |
| catch_target (+112) | enterEntry，str entry+0xc0 | 无 | 地址 add；写后 0 | 后续异常 handler 使用 |
| code_base (+56) | enterEntry，str x24 | 无；opcode 直接 ldrb [x24] | 写后 0 | x24 一直活着 |
| active_dispatch_tbl (+64) | 普通 entry **不写** | ldr [Vm,#64] | Vm→table 为 1 | local_fast_blocked 冷臂才改表 |
| local_fast_blocked (+218) | 普通 entry 不写 | ldrb + tbnz | Vm→byte 为 1 | A 的冷臂无 IP；不计正常 call |
| ctx/global/machine/output/rt/resident/property* | 不在普通 entry 改写 | 按后续 handler 需要读取 | 不适用 | 不能记成每次调用发布成本 |

caller 的 syncPc 另有一条真实链：

    ldr frame = [Vm,+24]
    ldr code_base = [Vm,+56]       # 与上一 load 独立
    sub caller_pc, pc, code_base
    str caller_pc, [frame,+8]      # store 地址依赖第一条 load

它保存的是 **caller return pc**，callee 首分派不读取它。QuickJS 同样在递归
JS_CallInternal 前做 sf->cur_pc = pc（qjs:18189-18192），所以也不能把它定成
zjs 独有的可约第三阶段。

### Q1.3 生产反汇编的关键尾段

来自生产 base1 的 objdump -d -l -C，symbol
exec.tailcall_dispatch.opCall__struct_113982.h：

~~~asm
127a774  ldr  x20, [x25]          ; Entry.frame.function
127a778  ldr  x8,  [x20,#24]      ; byteCode materialize check
127a77c  cbnz x8,  127a788         ; hot: slow helper 不走
127a788  str  x20, [x19,#8]       ; Vm.function
127a78c  str  x25, [x19,#24]      ; Vm.frame
127a790  ldr  x8,  [x25,#80]      ; Entry.frame.var_refs.ptr
127a794  str  x8,  [x19,#72]      ; Vm.var_refs_base
127a798  add  x8,  x25,#0x98
127a79c  str  x8,  [x19,#32]      ; Vm.stack
127a7a0  add  x8,  x25,#0xc0
127a7a4  str  x8,  [x19,#112]     ; Vm.catch_target
127a7a8  str  x24, [x19,#56]      ; Vm.code_base
127a7ac  ldrb w8,  [x19,#218]     ; local_fast_blocked
127a7b0  tbnz w8,#0,<cold switch>
127a7b4  ldr  x8,  [x19,#64]      ; dispatch table；不依赖上面任何 store
127a7b8  ldr  x1,  [x25,#168]     ; sp；直接来自 Entry
127a7bc  ldr  x2,  [x25,#48]      ; var_buf；直接来自 Entry
127a7c0  ldrb w9,  [x24]          ; dependency A: code_ptr → opcode
127a7c4  ldr  x4,  [x8,x9,lsl#3]  ; dependency B: opcode → handler
127a7c8  mov  x0,  x24
127a7cc  b    1279fa4             ; 共享 Handler ABI 出口
...
1279fb0–1279fc0  ldp ...          ; 恢复 callee-saved registers
1279fc4             br x4          ; 进入 callee 第一条 opcode handler
~~~

依赖图只有：

    x24(code_ptr) ──load opcode──> w9 ──indexed load──> x4 ──br──> first handler
    x19(Vm) ──load table──────────> x8 ─────────────────┘
    x25(Entry) ──load sp/vb──────────────> handler arguments

六个 Vm stores 没有箭头通向 x4。尤其不存在 “store Vm.pc → load Vm.pc”；Vm 本身
没有这个发布字段，只有 caller frame.pc 和 callee code_base。

QuickJS 的对应机制是 JS_CallInternal 的 C locals pc/sp/var_buf
（qjs:17746-17758），callee entry 令 pc=b->byte_code_buf
（qjs:17856-17871），然后 computed goto 也执行
opcode=*pc++ → dispatch_table[opcode]（qjs:17767-17778、17873-17878）。
直接 call 在 qjs:18175-18202，return 在 qjs:18266-18271，frame cleanup/restore 在
qjs:20699-20710。D7 不能删除 zjs 的通用首分派而仍声称是 qjs 对齐。

### Q1.4 完整动态热 load/store 清单

下面是从 op_call2 handler 入口到首次 callee handler transfer 之间，生产 ELF 上所有
得到 instruction-IP 命中的 99 条 load/store。数字为 pooled instruction IP samples；
每一行都不是源码静态猜测。列表按地址列出；控制流执行顺序是 handler prologue →
0x127a... resolution/frame construction → 0x127a774 entry publish/dispatch →
0x1279fb0 ABI restore → br x4。关键段另有上面的 addr2line -f -i 映射和逐 IP
cycles/instructions 双事件证据；完整样本计数在 evidence JSON。

~~~text
1279e40 499 stp x29, x30, [sp, #-96]!
1279e44 877 stp x28, x27, [sp, #16]
1279e48 475 stp x26, x25, [sp, #32]
1279e4c 421 stp x24, x23, [sp, #48]
1279e50 470 stp x22, x21, [sp, #64]
1279e54 445 stp x20, x19, [sp, #80]
1279e68 107 ldr x8, [x3, #24]
1279e6c 447 ldr x9, [x3, #56]
1279e78 452 str x9, [x8, #8]
1279e7c 451 ldr x26, [x3, #32]
1279e80 483 ldr x8, [x26, #8]
1279e94 436 ldp x24, x8, [x22, #-48]!
1279ea4 418 ldurb w8, [x24, #-5]
1279eb0 467 ldrh w8, [x24, #20]
1279ebc 478 ldr x21, [x24, #40]
1279ec4 494 ldrb w8, [x21, #17]
1279fb0 289 ldp x22, x21, [sp, #64]
1279fb4 311 ldp x24, x23, [sp, #48]
1279fb8 302 ldp x26, x25, [sp, #32]
1279fbc 318 ldp x28, x27, [sp, #16]
1279fc0 337 ldp x29, x30, [sp], #96
127a024 548 ldrh w25, [x21, #20]
127a02c 513 ldr x27, [x19, #16]
127a030 429 ldr x23, [x24, #48]
127a034 459 ldr x8, [x21, #72]
127a06c 456 ldr x8, [x8, #176]
127a07c 4944 str x22, [x26, #16]
127a088 386 ldrh w9, [x21, #56]
127a094 404 ldr w26, [x21, #92]
127a09c 175 ldr x24, [x21, #24]
127a0c8 436 ldr x8, [x19]
127a0cc 428 ldr w9, [x8, #2160]
127a0d4 361 str w9, [x8, #2160]
127a0f8 427 ldr x0, [x19, #80]
127a0fc 362 ldr x11, [x0, #3392]
127a100 395 ldr x8, [x0, #3416]
127a10c 429 ldr x9, [x19, #40]
127a110 386 ldr x10, [x19, #16]
127a114 385 ldrh w8, [x21, #58]
127a118 360 ldrh w12, [x21, #62]
127a124 156 ldrh w12, [x21, #64]
127a12c 344 ldr x12, [x0, #3408]
127a138 369 sturb w14, [x29, #-24]
127a148 172 ldr x14, [x0, #3432]
127a158 382 str x12, [x0, #3408]
127a160 355 str x11, [x0, #3392]
127a164 345 ldp x11, x13, [x9, #48]
127a174 380 ldr x11, [x0, #1792]
127a17c 349 ldrh w16, [x21, #62]
127a180 332 ldr x12, [x0, #1800]
127a188 180 ldr x11, [x15, x12, lsl #3]
127a190 330 ldr x18, [x17, #2328]
127a1a0 543 ldr x18, [x9, #32]
127a1a8 228 ldr x14, [x18, x14, lsl #3]
127a1bc 367 str x16, [x15, x12, lsl #3]
127a1c0 363 ldr x14, [x14]
127a1c4 349 strb wzr, [x25, #253]
127a1c8 1865 str wzr, [x25, #248]
127a1cc 482 stp xzr, xzr, [x25, #192]
127a1d0 852 stp x12, x11, [x25, #208]
127a1d8 334 str x21, [x25]
127a1e0 307 stp x10, x15, [x25, #16]
127a1e4 456 ldr q0, [x22]
127a1e8 374 str q0, [sp, #112]
127a1f0 323 stur q1, [x1, #-48]
127a1f4 310 str q0, [x25, #32]
127a1fc 304 stp w10, w8, [x25, #136]
127a200 676 stp x12, x10, [x25, #64]
127a204 861 stp x23, x26, [x25, #80]
127a210 343 stp xzr, xzr, [x25, #120]
127a214 885 stp xzr, x11, [x25, #104]
127a218 707 strb w10, [x25, #144]
127a21c 892 str xzr, [x25, #8]
127a220 1325 stp x11, xzr, [x25, #48]
127a224 750 str x11, [x25, #96]
127a230 309 stp x10, x8, [x25, #152]
127a234 924 stp x8, x13, [x25, #168]
127a238 1313 str x11, [x25, #184]
127a240 350 strb w8, [x25, #252]
127a244 935 stp x27, x22, [x25, #224]
127a248 1833 ldr x8, [x9, #64]
127a24c 331 str x8, [x25, #240]
127a250 559 ldr x8, [x9, #56]
127a258 373 stp x8, x25, [x9, #56]
127a774 369 ldr x20, [x25]
127a778 357 ldr x8, [x20, #24]
127a788 2459 str x20, [x19, #8]
127a78c 343 str x25, [x19, #24]
127a790 341 ldr x8, [x25, #80]
127a794 354 str x8, [x19, #72]
127a79c 317 str x8, [x19, #32]
127a7a4 335 str x8, [x19, #112]
127a7a8 326 str x24, [x19, #56]
127a7ac 347 ldrb w8, [x19, #218]
127a7b4 344 ldr x8, [x19, #64]
127a7b8 320 ldr x1, [x25, #168]
127a7bc 1111 ldr x2, [x25, #48]
127a7c0 329 ldrb w9, [x24]
127a7c4 322 ldr x4, [x8, x9, lsl #3]
~~~

## Q2 — 可证伪实验与结果

### Q2.1 预注册式判据

若“首 handler 地址依赖重新发布的 pc”是 12.78 cyc 的主因，则：

1. 一个只在已知首 handler 的受控语料中绕过通用首分派的 probe，应收掉 12.78 的显著部分；
2. 一个故意把首分派改成真实 store→load→多级追逐的 probe，应在 backend stall 上显著变坏；
3. 两者都必须由反汇编证明目标机器链真的改变，由 counter 证明宏观路径真的命中；
4. 两个独立 probe 冷构建 × 两个独立 baseline 全组合方向一致，否则不能裁决。

### Q2.2 两个探针

**short probe（语义无效，仅测物理上界）**：counter 已证明 A 的 30M 个 nested callee
首 opcode 全是 return_undef；只对 depth>1 直接 always_tail 到 op_return_undef。
它删掉 generic opcode/table target loads，但加了 machine/depth load+compare。这个形状
对任何别的函数都错，也没有 QuickJS fast path，绝不是候选。

**long probe（语义正确但故意变坏）**：enterEntry 六次 store 后用 volatile 强迫
Vm.frame 和 Vm.stack reload，再走：

    Vm.frame → frame.function → function.byte_code → opcode → handler
             ↘ frame.locals
    Vm.stack → top_ptr

反汇编确认 store 后出现 ldr [Vm,#24]、ldr [Vm,#32]、ldp [frame]、
ldr [function,#24]、ldrb [byte_code+pc]、ldr [table+opcode]；它正是原假设声称生产
路径已有的链。

### Q2.3 8-sample ABBA、完整 2×2 结果

数值为 probe−baseline 的净每 call median；负 cycles 是 probe 更快。

| probe/build vs base/build | Δinsn | Δcycles | Δstall_be | Δstall_be_mem | Δstall_fe |
|---|---:|---:|---:|---:|---:|
| short1−base1 | +0.000 | **−0.481** | −0.834 | +0.0013 | −0.0124 |
| short1−base2 | +0.002 | **−0.381** | −0.716 | −0.0001 | −0.0029 |
| short2−base1 | −0.002 | **−0.536** | −0.645 | −0.0015 | −0.0055 |
| short2−base2 | −0.004 | **−0.352** | −0.414 | −0.0036 | +0.0004 |
| long1−base1 | +5.006 | **+2.320** | +1.102 | +0.0024 | −0.0115 |
| long1−base2 | +5.005 | **+2.437** | +1.254 | +0.0007 | −0.0082 |
| long2−base1 | +5.003 | **+2.335** | +1.034 | +0.0013 | −0.0014 |
| long2−base2 | +5.003 | **+2.406** | +1.181 | −0.0007 | +0.0112 |

short 的最大总周期收益只有 0.536 cyc/call，是任务输入 12.78 的 4.19%；最大观测
非访存 backend reduction 是 0.835 cyc/call，仍至少有 **11.945 cyc/call** 在通用
首分派链之外。long 的四个比较则稳定增加 2.32–2.44 cycles 和 1.03–1.25 backend
stall，memory/frontend 仍为零：实验足以检出真实依赖链，不是 probe 不敏感。

**裁决：主假设被证伪。** 生产路径的首 handler 地址不依赖任何重新发布的 pc；
可测的通用 dispatch 自身也远非 12.78 的主体。

## Q3 — 逐节定价与可约性

首先拒绝一个不守恒的账法：setup/teardown 来自不同 profile 差分，其所谓第三部分在
qjs 上是 −0.47 cyc。负的阶段成本已经证明 14.56 是算术 residual，不是被仪器圈住的
一个时间区间。stall_backend 又是与其它执行重叠的 stalled-cycle 事件，不能把 probe
总 cycles 和 stall cycles 当可加零件。故不能把 12.78 强行分完；下面只给可观测项、
零项和明确剩余项。

| 成分 | A 中实际频次 | pointer/store→load 节数 | 本轮单位价格 | A 的绝对量 | 可约性 |
|---|---:|---:|---:|---:|---|
| caller syncPc：Vm.frame/Vm.code_base → frame.pc store | 30M | 两个独立 load → 1 store | 未单独隔离 | 未辨识 | **不可删除**；qjs:18189-18192 也保存 caller pc |
| 六个 callee Vm publication stores | 各 30M；共 180M stores | 首分派前 store→load **0 节** | 不可从重叠流水中逐 store 辨识 | 未辨识 | 字段本身不可删；但没有证据表明它们构成关键链 |
| 被指控的 “Vm.pc publish→reload” | **0** | **0** | **0 cyc/call** | **0 Mcyc** | 不存在，无可优化 |
| 实际 code_ptr→opcode→handler | 30M | 2 个相关 load；table load 可并行 | 非法直达 probe 的物理上界 **0.352–0.536 cyc/call** | 最乐观 ≤16.069 Mcyc | **不可约**；qjs:17767-17778 同样 computed goto |
| 强制 Vm.frame/Vm.stack replay | 生产 0；probe 30M | store→load 后 3–5 级链 | **新增 2.32–2.44 cyc/call** | 新增 69.596–73.113 Mcyc | 反事实校准，不是可省生产成本 |
| 首分派能解释的 non-memory backend | 30M | 上述 generic dispatch | 最大观测 0.835 stalled cyc/call | ≤25.051 M stalled cycles | 仍是非法直达敏感性，不可约 |
| 12.78 中留在该链之外的部分 | 30M | 未定位 | **至少 11.945 stalled cyc/call** | ≥358.349 M stalled cycles | unresolved；不能冒充某个 ABI 字段的价格 |

为什么六个 publication 字段在当前架构不可直接删除：

- tail-call threaded dispatch 把每条 opcode 变成独立 handler 活动；没有 QuickJS
  JS_CallInternal 那个横跨所有 CASE 的单一 C 活动记录，所以 function、frame、stack、
  code_base 必须让后续 handler、return、unwind 和 GC/root walk 找到当前 activation；
- var_refs_base 是跨 handler 的 resident mirror；删除会把 var-ref op 恢复成更长的
  frame/function/closure 追逐。VARREF-V3 和 opcode 空间战略储备不在本轮触碰；
- catch_target 必须横跨任意可能 throw 的 handler；
- callconv(.c) Handler 边界本身必须交接 pc/sp/var_buf/Vm，并恢复它要求的
  callee-saved 状态。精确 spill 数是 LLVM codegen 结果，不声称每一对 stp/ldp 都在
  语义上必然；但在冻结的 tail-call+C ABI 架构下，不能把整段活动记录边界白送掉。

这与已登记的 NativeCallEnvironment.output 和 caller_function/caller_frame 同类：
它们说明 zjs 的 host/activation 表示与 qjs 的 JSContext/单 C frame 不同；但这两个
native 先例不发生在 A 的普通 direct JS→JS 热臂，不能拿来填 12.78。

因此本轮没有“已定位且可约”的正价格。可约额为 **0**；剩余 11.945+ 是未定位预算，
不是优化额度。IMPL-TEARDOWN 的负结果与此一致：把状态再搬过 Handler ABI 去共享
done 会增加一节活动记录依赖，而静态少指令不会自动缩短现有关键路径。

## Q4 — 可实现上限与 go/no-go

### Q4.1 D7 与 D1 是不是同一件事

**不是同一个攻击面的两次估计。**

- D1 定价“删掉相对 qjs 多做的 retired work/指令”，严格结果是 method 形状
  1.7835 cyc/event，Zoo geomean +0.234%。
- D7 问的是“即使指令不减，是否存在 store→load latency chain，把 OoO 卡住”。

问题不同；但 D7 的实证答案是：被指控的 chain 不存在，实际 generic dispatch 又是
qjs 也付的不可约机制。因此 D7 不是把 D1 的 +0.234% 再算一遍，而是一个独立攻击面
经反证后归零。两者也不能相加。

### Q4.2 严格上限和非法敏感性上限

严格可实现候选没有任何 qjs-faithful 可删边，所以每项 saved Mcyc 和 percent 都为零。
为避免“零上限只是没有乘频次”的误解，右两列另给一个**不计入裁决**的敏感性：
假设语义无效的 0.535646 cyc/call 可以在每个 JS call 全覆盖。调用频次来自同日、
同 commit 的 D1 出线 counter；cycles 分母来自冻结生产二进制的 CPU 5、8-sample
ABBA fixed-work Zoo。它只是说明即使越过红线也不够 +0.5%。

| benchmark | calls M | zjs Mcyc | 严格 saved Mcyc / % | 非法 0.535646 敏感性 saved Mcyc / % |
|---|---:|---:|---:|---:|
| box2d | 2.091 | 1317.166 | 0.000 / 0.0000% | 1.120 / 0.0850% |
| code-load | 0.006 | 267.103 | 0.000 / 0.0000% | 0.003 / 0.0012% |
| crypto | 2.504 | 5356.514 | 0.000 / 0.0000% | 1.341 / 0.0250% |
| deltablue | 32.374 | 5705.356 | 0.000 / 0.0000% | 17.341 / 0.3039% |
| earley-boyer | 15.028 | 6775.876 | 0.000 / 0.0000% | 8.050 / 0.1188% |
| gbemu | 2.974 | 2036.479 | 0.000 / 0.0000% | 1.593 / 0.0782% |
| mandreel | 13.549 | 6968.336 | 0.000 / 0.0000% | 7.257 / 0.1041% |
| navier-stokes | 0.002 | 1699.222 | 0.000 / 0.0000% | 0.001 / 0.0001% |
| pdfjs | 2.733 | 1346.843 | 0.000 / 0.0000% | 1.464 / 0.1087% |
| raytrace | 8.459 | 4279.968 | 0.000 / 0.0000% | 4.531 / 0.1059% |
| regexp | 1.175 | 2071.982 | 0.000 / 0.0000% | 0.629 / 0.0304% |
| richards | 20.775 | 4769.042 | 0.000 / 0.0000% | 11.128 / 0.2333% |
| splay | 1.300 | 1656.730 | 0.000 / 0.0000% | 0.696 / 0.0420% |
| typescript | 13.788 | 4822.364 | 0.000 / 0.0000% | 7.385 / 0.1532% |
| zlib | 0.551 | 17074.334 | 0.000 / 0.0000% | 0.295 / 0.0017% |

| 口径 | EB | RT | Zoo geomean |
|---|---:|---:|---:|
| 任务输入的理论“全消 12.78” | −2.85% cycles | −2.52% cycles | 约 +2.3% |
| **D7 严格可实现** | **0.000 Mcyc / 0.000%** | **0.000 Mcyc / 0.000%** | **+0.000%**；仍为 0.9110 |
| 非法 0.535646 全覆盖敏感性 | 8.050 Mcyc / 0.1188% | 4.531 Mcyc / 0.1059% | +0.0929%；0.9110→0.911846 |

若每个 call 都能覆盖，要越过 +0.5% geomean 至少约需
**2.883 cyc/call**；当前连语义无效直达的上界都只有 0.536。

### Q4.3 与冻结的 monolithic dispatch 的区别

2026-07-14 的 91 臂全单体方案是把整个 opcode dispatch 变成一个 LLVM 巨型函数，
PMU 4/4 回退后已冻结。本轮没有重开它：

- short probe 只是受控语料的无效上界，已经撤掉，绝不建议落地；
- long probe 故意增加边界依赖，只用于证明实验灵敏度，也已经撤掉；
- 任何可接受候选都必须保留 zjs 的 tail-threaded per-op dispatch 和
  2.218 cyc/op 优势，不换成 qjs 的 2.611 cyc/op 单体；
- 目标原本是“zjs 分派 + qjs 边界”，但生产反汇编证明没有可删的首分派发布链。

所以 no-go 并不是再次尝试 monolithic 后失败，而是边界 knife 在写代码前就被物理
证据否掉。VARREF-V3/opcode 储备完全未动。

## Q5 — 第一刀与如何证伪

**NO-GO，所以没有第一刀。** 半天实现不应启动。

若未来代码布局改变、有人要重开，必须先满足下面的“开工前反证门”，而不是直接写候选：

1. 生产 ELF 的 objdump + addr2line 必须先显示一条真实、宏观有 IP 命中的
   store→load 边；不能只是源码字段看起来会 reload；
2. qjs:17746-17878 必须能指出对应机制，候选保留通用 opcode→handler dispatch，
   不做 direct-handler 特化、不改 opcode 空间；
3. counter 必须在 EB/RT/Zoo 证明该边的实际出线频次；单位收益需要达到至少
   2.883 cyc/每次全覆盖调用，或按实际覆盖频次折算 geomean ≥+0.5%；
4. 两个冷构建 × 两个 baseline，CPU 5，8-sample ABBA，同测 instructions/cycles；
   方向不一致就带 backend/memory/frontend；EB/RT 的 saved Mcyc 必须按频次闭合；
5. 任一项不成立即证伪，不进入实现轮。

## 被否掉的假设

| 假设 | 否定证据 |
|---|---|
| callee 首 handler 地址依赖 re-published Vm pc | 生产反汇编无该 store→load；code_ptr 留在 x24 |
| 六个 Vm store 形成首分派串行链 | 六个 store 都不喂 x4；sp/vb 直接从 Entry 取 |
| 12.78 大多是 generic first dispatch | 无效直达最多 −0.536 cycles、−0.835 non-memory backend；只占小部分 |
| probe 对依赖链不敏感 | 强制 3–5 级链稳定 +2.32–2.44 cycles、+1.03–1.25 backend |
| 14.56 是一个可独立圈出的“第三阶段” | qjs residual 为 −0.47，说明它是差分算术余量，不是守恒 stage |
| D7 可以与 D1 +0.234% 直接相加 | 两者问题不同；D7 经反证严格为零 |
| 应重开 monolithic dispatch | 本轮保留现有 tail-threaded dispatch；探针均非候选 |

## 清理与可复核性

- short/long 的四个临时 probe 源码改动已逐行撤销；
- 四个 probe ELF 在报告生成后逐个 unlink；
- 临时 sampler 已由 apply_patch 删除；
- 最终实测 git diff --exit-code、git diff --check、git diff --stat 都 exit 0、0 bytes；
- git status --short --untracked-files=all 只列出新建的
  D7-CALLCHAIN-DIAGNOSIS.md 和 D7-CALLCHAIN-EVIDENCE.json；没有源码改动。
