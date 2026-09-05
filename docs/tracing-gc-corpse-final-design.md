# 尸体与 teardown 表示终案（header v2 补充案一）

状态：**HISTORICAL（2026-09-06）— 已完成并被实现超越。**
本文规划的「尸体表示」终案在 TGC S4 全部兑现或改道：Pass-A/Pass-B 两遍析构与 husk 于 S4-e 删除，
普通对象死亡不进析构（S4-d），condemn 谓词最终落在 `mark_epoch` 保留值 `0xffff` 而非本文的位方案（S4-h）。
现状事实以 [`tracing-gc-completion-account.md`](tracing-gc-completion-account.md) 与
[`tracing-gc-s4-spec.md`](tracing-gc-s4-spec.md) §7 为准；本文只作设计推理的历史记录。

原状态：**APPROVED — owner 委托 driver 终审裁决（2026-09-01，「参考其他引擎、要终案、减少中间过渡」）**
本文修订 docs/tracing-gc-header-v2-design.md（APPROVED r2）的 §2.2/§4.4，构成其补充案；冲突处以本文为准。
证据链：slice2 NO-GO 归档（EB cycles +17.7%，gc/s3-slice2-20260901）、重设计勘察（gc-minorfb/.scratch/SLICE2_REDESIGN_SCOUT.md）、五引擎源码调研。

## 1. 终态原则（引擎全票实践）

**死内存即簿记存储。** QuickJS（free_next 在 cell 内）、JSC（FreeCell 加扰链写进死 cell）、V8（FreeSpace 对象写进死内存）、Hermes（freelist 在 cell 内）——无一例外；无一引擎为尸体维护 side 记录或带验证的队列。extent-record 队列路线（slice2 v1）按实测定价永久否决。

## 2. 表示合同

1. **canonical 起始 8B 字 = 互斥 union**：`published ⇒ HeaderV2（不可变）`；`doomed | parked | deinit_hold ⇒ corpse_next`。O1 的不可变合同只约束 published 态，不受影响。所有 kind 的析构 payload 完好（覆写的是 header 字不是 body）。
2. **r2 修订（本案裁决）**：§2.2 的「carrier 验证后比对 HeaderV2 再解引用」豁免尸体态——尸体经 per-kind `CorpseHandle`（裸指针）流转，安全性由**队列所有权不变量**保证：对象在任一 corpse 队列中期间禁止 raw free/reuse，checker 强制。§4.4 的 generation-bearing teardown handle 对 corpse 阶段免除（morgue 独占分配窗口内无 ABA）。
3. **拓扑**：doomed = 六 kind 各一条 FIFO（体内链，budget cursor=链头指针天然续传）；parked = extent LIFO + block 恢复 H_PRE 的 Object-only body-link run；deinit = FB/VarRef/Shape 三条 LIFO。同一物理字、互斥状态机、phase checker 禁并存。
4. **zero_ref_list 消灭（v2 修订，2026-09-02 driver 裁决）**：反递归排干改为**瞬态 scratch worklist**（帧 arena 有界数组 + 溢出走 scratch 堆），级联在单次调用内完成。**v1 的「eager-zero 走 published→doomed 适配器进单一管线」被实测否决**（slice2-final：EB 新增 83.27M 次死亡事务、整程 +6.7% insn——H_PRE 此路径 drains=0；引擎实践 qjs 对 rc==0 直接释放，无引擎让 RC 归零走 GC 管线）。修订为：**Shape/Realm eager-zero = 直接 teardown**（立即析构+释放，成本对齐 H_PRE 旧路径），scratch worklist 仅承担反递归；「单一死亡管线」限定为 **traced 死亡**（condemn 产生的尸体）。BigInt tag-directed 冷尾不变。
5. **extent identity 组件维持 shadow/OFF**：corpse 游标即链头，无必要消费者；首个真实 reader 出现时单独生产化定价（r2 组件纪律不变）。
6. finalizer-current/weak-husk 窄窗口：至多 1 个 active raw pointer + 紧凑 side 态（勘察 §0.4 口径）；callback 读 payload 与本案无冲突。

## 3. 实施与验收

一片到位（无桥接版）：替换归档 slice2 的全部 extent 队列 + 消灭 zero_ref_list，六 kind + block run 直达终态。预注册线沿用：H_PRE destroy 双线（splay 桶 ≤880,215,649 / ratio ≤1.05；EB ≤10,743,522,182 / ratio ≤1.05）、splay+EB 整程 insn/cycles 总中位 ≤1.003（多冷构建总中位协议）、allowlist 借用者归零（本片后 `Header.next` 活跃借用者仅剩 gc_obj_list+young 后缀=slice3a）、settled 批门禁 ≥2 轮、活锁回归测试（EB settle 有界完成）。
