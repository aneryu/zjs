# Phase 2 — 下游：调用机制 / dispatch / 属性 refcount 纪律

> 依赖 Phase 1 keystone 全绿。**设计/实现规格，非代码。** 这是调用税 **6-7×** 的兑现处。
> 关键：keystone 把 frame 变成 alloca-slab + refcount-on-push + 无 per-call rooting 之后，下面几项**自然解锁/大幅简化**。

## 背景：为何这些项在 keystone 后才做

- 在 zjs 旧 FrameRootScope 上做这些 = 在错地基上优化（叶先被否的理由）。keystone 后：
  - 无 per-call rooting → **懒回溯**自然成立（不再需要每调用 root backtrace 帧）。
  - frame 是 alloca-slab、function 经指针 → **bytecode-view-by-pointer** 自然成立（不再每调用按值拷 43 字段）。
  - refcount-on-push 纪律 → put_field 所有权转移干净。

## 项目清单（带 file:line + qjs 锚点）

### P2.1 Bytecode view 按指针（审计 rank 1，单调用最大头）
- **现状**：每次 inline 调用按值重建 43 字段 Bytecode view（`setupInlineEntry` inline_calls.zig:246、function.zig:481-527），
  frame.function 指向 entry.view（27 处 dispatch-loop 访问）。
- **改**：缓存 finalize 期建好的 Bytecode、**按指针**挂在 FunctionBytecode 上（qjs `b = p->u.func.function_bytecode` 单指针 load）。
  direct-eval callee：只把 var_ref_names overlay 进 per-Entry 字段（merged slices 已 entry-owned，inline_calls.zig:529-531）。
- **注意**：view 对 direct-eval 是 per-call 被改的 → 共享缓存不能就地改；view 含 rt-bound 字段（.memory/.atoms/.constants）→ 缓存结构仍须绑 rt 或带 rt-stable slices。**外科手术、非删除。**

### P2.2 懒回溯（审计 rank 2）
- **现状**（codex 更正）：每调用 grow `ctx.backtrace_frames`，但 **atom/函数值 dup 只发生在 lazy-name 分支**——另一分支存
  **borrowed** atom，**非无条件 dup 两个 atom + 函数对象**（per-call 成本比原稿低）。仍有 per-call `atomNameEql` 字符串比较
  （"<eval>" vm_call.zig:142、"this" 扫 vm_call.zig:97-99、owned-vs-borrowed std.mem.eql inline_calls.zig:675-677）。
  锚点 `pushInlineBacktraceFrame`/`pushBacktraceFrameLazyName`（inline_calls.zig:665-704、context.zig:775-806）。
- **改**：像 qjs `prev_frame` 走法——`JS_CallInternal` 只 `sf->prev_frame=cur; cur=sf`（两次指针写），出错时在 `build_backtrace` 懒重建 name/line。
  把字符串比较换成 finalize 期预算的 flag（is_eval_code、缓存 derived-ctor this-slot index、BacktraceMode）。
- **约束**：zjs 有**两种**帧喂 `ctx.backtrace_frames`（inline Entry 链 + 递归 native entry，zjs_vm.zig:332）→ build_backtrace 须在帧存活时遍历两者，
  保抛错栈保真 + lazy-name-vs-borrowed-atom 显示区分。懒走法的数据已在存活 Entry 帧里（view.name/filename/line + borrowed frame.pc）。

### P2.3 put_field 所有权转移（审计 rank 9）
- **现状**：`qjsPutFieldFast` 做 `next=value.dup(); store; old.free`（vm_property_field.zig:351-354），而 caller 持 `defer value.free`（307-308）——
  每个堆值 put_field 一对冗余 +1/-1 原子。
- **改**：直接把 value 存进槽、只 free old_value、fast-path 成功时跳过 caller defer-free（consumed flag）。qjs `set_value(ctx,&pr->u.value,sp[-1])`
  转移所有权、只 free old、sp-=2（quickjs.c:19177-19216）。slow 路径仍 borrow → 保其 free。int/float 已 no-op。

### P2.4 属性访问 fast-path refcount 纪律
- 在新 value/refcount 模型上，对象-属性 get/set fast-path 的 refcount 纪律对齐 qjs（dup/free 配平、setSlot 转移）。
- 把 keystone S1 引入但未接线的 `setSlot`（snapshot-old/store-new/free-old）路由进 frame/var-ref/property 的 ad-hoc free+assign 站点（frame.zig:413-441 等）。

### P2.5 调用深度
- qjs 用逻辑深度上限（zjs inline 帧不耗 C 栈 → qjs 的裸 SP-compare 结构上不适用）。inline 热路径已单计数器无除法；保它，
  非 inline 递归回退的两计数器+除法路径**不可采 qjs 机制**（已记 do_not_align：per-call-depth-counters，结构性 zig-forced）。

## 验收（结构对照 + 门 + 性能兑现）

- **结构对照**：OP_call vs `JS_CallInternal` 入口 + js_call_c_function；backtrace vs build_backtrace；put_field vs set_value。
- **门**：全 `0/49775` default + nan_boxing + **force-GC**（P2.3/P2.4 碰 refcount）。
- **性能兑现（相边界 sanity）**：四个调用 benchmark `fib_rec`/`method_call_loop`/`alloc_call_loop`/`call_body_loop` 从 6-7× 落到**低个位数**
  ——这是 keystone+Phase2 的验收指标。（按反作弊规则：性能只作相边界 sanity，不作单项去留偏离的理由。）
