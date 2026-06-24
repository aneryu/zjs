# S5 — frame-slab（最后删 FrameRootScope/active_value_roots + TDZ 哨兵 + slab carve）

> Phase 1 收尾 commit。依赖 S1、S2、S3。**设计/实现规格，非代码。** 单大 commit。
> 这是调用税 6-7× 的地基拆除；**只有** S2（符号 refcount）+ S3（对象 refcount + weakref_count husk）绿了才安全。

## 改动清单（带 file:line 锚点）

### 1. 删 FrameRootScope/active_value_roots
- 删 `FrameRootScope`/`active_value_roots` 发布（frame.zig:46-131），**审计每个发布者**——**不止 frame**（codex 更正：
  直接赋值约 **7 个 builtin 文件、67 处**，非"~20 文件"；object.zig:2482/3220/10090/10115、array.zig:316/528/900/1042、
  json/string/collection/regexp）。每个它们 root 的瞬时值现须由 refcount（S3）或 symbol-refcount（S2）保活。
- **GC 模型**：删后，同步帧栈值靠 **refcount-on-push 保活**（push dup / pop free），运行帧不被扫；仅挂起 async/gen 帧扫
  `[arg_buf, cur_sp)`。这是**用 refcount 纪律替换**重 FrameRootScope，不是裸删 rooting。

### 2. TDZ 哨兵（删平行 bool 数组）
- 删平行 `locals_uninit` bool 数组（frame.zig inline_locals_uninit/locals_uninit_on_heap）。
- 每个 bool-array 站点改 **through-cell** 哨兵测 `varRefSlotIsUninitialized`/`slotValueBorrow(slot).isUninitialized()`（slot_ops.zig:528）——
  **不是**裸 `frame.locals[idx].isUninitialized()`（会漏掉值在 cell 里的捕获局部）。站点：vm_property_locals.zig:227/242/244/254/269/296/1033、
  vm_property.zig:262/419/1270/1305、vm_arith.zig:654、vm_property_globals.zig:886、object_ops.zig:493/565、vm_call.zig:134、slot_ops.zig:600。
- 迁移期留 cross-check assert `varRefSlotIsUninitialized(...)==old_locals_uninit[idx]`（:243-244 reconciliation 证明二者**会**分歧），过后再撤。
- qjs 对照：`JS_UNINITIALIZED` 哨兵值，`get_loc_check`/`put_loc_check` 抛 ReferenceError、`put_loc_check_init` 清。

### 3. slab carve
- 一块连续 `VmStackArena` 切 `[args|vars|stack|var_refs]`，保现有单 mark/restore 覆盖 locals slab + 操作数窗（zjs_vm.zig:337-338、inline_calls.zig:280）。
- qjs 对照：`JS_CallInternal` 一次 alloca，"arg_buf, var_buf, stack_buf and var_refs follow"（quickjs.c:793）。zjs 无 C 栈递归 → arena slab 是忠实映射。

> ✅ **深查已证实（2026-06-23，原 codex 存疑两条）**：
> (4) `frame.var_refs` **确是 eager 捕获**：闭包帧从 `functionCapturesSlot()`（inline_calls.zig:261）经 `initFrameVarRefs`（:414）
> eager 填充，顶层脚本帧从 var_ref_names 路径填（vm_call.zig）。转 NULL-init lazy **会抹捕获** → 只折 `open_var_refs`（lazy 自槽链）正确。
> (5) top-level-let **不是纯单 cell、是混合**：var_ref 路径 `execGetVarRefMaybeTdz`（slot_ops.zig:300-313）对 global_decl ref
> **读穿全局 lexical cell**（近 qjs 单 cell）；但 **`global_lexical_sync` 镜像仍在**（slot_ops.zig:175-216 +
> frame.global_lexical_sync_slots/indices），对**局部槽路径**做 frame-local + 写穿全局（**双存储 = 真镜像税**，da34bc1 8 回归所依赖）。
> → **S5 只须原样保留整套（含镜像，不动）**；删镜像、达成 qjs 真单 cell 是 **Phase 3 C.1**（全计划最高危）。

### 4.【缺陷修正·待深查】不动 frame.var_refs
- `frame.var_refs`（frame.zig:99/197）是 qjs `p->u.func.var_refs`（**eager 继承闭包捕获**，OP_get/put_var_ref 读）——
  NULL-init 转 lazy slab 会**抹掉闭包捕获**。
- 只把 `open_var_refs`（frame.zig:199，懒自槽 = qjs `sf->var_refs`）折成 `[*]?*VarRef` 尾、按 var_ref_idx keyed、idempotent get
  （非空复用否则建）、`close_var_refs` 在 value free 前覆盖 [0..var_ref_count]。

### 5. 保 byte-for-byte（防回归）
- top-level-let 单 VarRef-cell 别名（vm_call.zig:203-225、var_ref_is_global_decl）**byte-for-byte 保留**——重拆 = da34bc1 跨 realm 写穿回归。
- generator/async 堆存储 gate（`use_inline_frame_storage` zjs_vm.zig:366、`frameSlotCanOpenAlias` slot_ops.zig:620 对 gen/async 返 false）
  **逐字保留**——裸 arena 路由会让 watermark restore 回收挂起帧的 slab。

### 6. original_args 退役 — 另起 commit（非本 slice）
- 单独后续 commit 采 qjs eager unmapped-arguments-object 构造；本 slice 期 original_args 作 slab 内侧 carve 保留。

## 绿桥

- FrameRootScope 删除安全**仅因** S2+S3 已绿 → 栈上符号/对象/weak-held target 全由 refcount 保活、非栈枚举。
- dual-track：删除期每个 TDZ 站点留 cross-check assert，捕捉 cell-vs-bool 分歧后再撤。
- **force-GC-on-every-alloc** 跑全套，把 borrow-on-stack desync 转成确定性崩溃，逐个用 dup-on-push/release-on-pop 修，或确保 caller
  自有 ref 支配（qjs new_target/this 契约：inline_calls.zig:336 设 new_target_owned=false/this_value_owned=false → 现在需一个 owning dominator）。
- 不转 frame.var_refs 保闭包捕获；只折 open_var_refs 保 get_var_ref idempotency + teardown 序；保 top-level-let 单 cell 保跨 realm 写穿。

## 验收（结构对照 + 门）

- **结构对照**：frame vs `JSStackFrame`（quickjs.c:410,793）+ JS_CallInternal 帧建立/拆除；TDZ vs JS_UNINITIALIZED；slab vs 一次 alloca。
- **门**：da34bc1 集（6 for-of/for-in TDZ + 1 eval-delete + 1 跨 realm）+ 闭包-over-loop-variable + generator-suspend + 深递归 +
  异常展开 + WeakRef/FinalizationRegistry/Symbol 子集 + 全 `0/49775` default + nan_boxing + **force-GC**。
