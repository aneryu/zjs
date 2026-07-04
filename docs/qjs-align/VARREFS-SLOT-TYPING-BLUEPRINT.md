# VARREFS-SLOT-TYPING-BLUEPRINT — frame.var_refs 槽类型化 `[]JSValue` → `[]*core.VarRef`

日期:2026-07-04 · HEAD:90dd5f3 · qjs 参考:/home/aneryu/quickjs(Bellard 版 2026-06-04)
上游文档:GET-VAR-FIB-RECON.md(§5 修复路径 Step 3,本文即该步蓝图)· CALL-MACHINERY-FAITHFUL-FRONTIER.md(§4 不变式清单)
qjs 锚点:`js_closure2` quickjs.c:17262-17339(构造期每槽真 cell)+ `js_inner_module_linking` 30715-30791(import 槽直接别名导出 cell,零嵌套)+ `JS_CallInternal` 序言 17844(`var_refs = p->u.func.var_refs`,`JSVarRef **` 借用)

## 0. 目标与不变式(先读)

**终态**:`Frame.var_refs: []*core.VarRef`(元素非空指针),与 qjs `JSVarRef **var_refs` 同构。所有「槽是不是 cell」(GET-VAR-RECON 守卫 #4)与「cell 值是不是嵌套 cell」(守卫 #7)的每次读运行时判别删除 —— 这两条 GC header 载入合计 op_get_var 时间 28%。语义解决时机全部前移到:闭包创建期(js_closure2 等价物)、帧构造期(initFrameVarRefs)、module link 期、突变期(define/publish/delete)。

**必须保全的不变式**(CALL-MACHINERY-FAITHFUL-FRONTIER §4,逐条对号):

1. **var_refs borrow 安全与 current_function owned 耦合**:借用槽数组(`var_refs_borrowed=true` 时别名 `functionCapturesSlot()`)的生命线是仍活着的函数对象。类型化不许动 `current_function` 的 take 语义;teardown 的 borrow 分支(frame.zig:611/621)必须与新元素类型的释放语义(`free_var_ref` 等价)同步换,不能只换一半。
2. **Frame 保持现有 ~15 字段形态**:只改 `var_refs` 的元素类型 + `FrameCold.eval_var_refs` 边界转换,不做字段增删/瘦身。
3. **suspend/raw-sp 分叉全部门保留**:generator/async 帧的 var_refs 随 payload 迁移穿越 suspend(vm_gen_async.zig:86/161 + core/object.zig generator payload),类型翻转必须同一 commit 覆盖 payload 类型、GC visitor、释放路径三处,否则 UAF。
4. **refcount-only frame liveness**:cycle collector 不走帧链;类型化后 captures/payload 里的 cell 若从「JSValue 值遍历」改为「header 遍历」,GC visit 必须等价(qjs mark_func 16211 `mark_func(rt, &var_refs[i]->header)`;free 16199 `free_var_ref(rt, var_refs[i])`)。
5. **threading 纪律**:改任一写点须读完整 refcount+error 链;历史 UAF 教训「缓存 var_refs 指针跨 realloc」直接适用 —— `ensureVarRefsCapacity` 的 realloc 在类型化后仍存在(尺寸减半但机制同)。

## 1. 全仓库 var_refs 读写点清单

约定:R=读元素/长度,W=写元素/整数组;「今形态」= 元素可能形态(cell=VarRef cell value;raw=原始 JSValue;nest=cell-in-cell);「迁后」= 类型化后的形态/动作。raw grep `var_refs` 413 处(含 tests、arguments payload、bytecode 计数字段);下面是 **frame.var_refs 槽数组及其同型耦合网络的全部 60 个读写点**(直接槽访问 47 + 耦合数组 13),热点 8 处加粗。

### 1.1 热路径(8)

| # | 位置 | R/W | 今形态 | 迁后 |
|---|---|---|---|---|
| 1 | **tailcall_dispatch.zig:1238-1239 op_get_var** | R | cell 必然(fast 全命中)但每次付 #3/#4/#7 判别 | `frame.var_refs.ptr[idx].pvalue.*`,删 #4/#7;#3 见 §5 阶段 E |
| 2 | **tailcall_dispatch.zig:750-751 opGetVarRef(get_var_ref0..3/half)** | R | 同上;嵌套 import cell 落 cold | 同上;嵌套已在 link 期解开 |
| 3 | **zjs_vm.zig:1111-1137(get_var_ref legacy fast ×2)** | R | 同 #2 | 同 #2(legacy 引擎同步改) |
| 4 | **zjs_vm.zig:1160-1194(put_var_ref legacy fast ×2)** | R+W | cell 命中走 cell 写 | cell 直写,删槽判别 |
| 5 | **zjs_vm.zig:1712-1713 get_var legacy fast** | R | 同 #1 | 同 #1 |
| 6 | **zjs_vm.zig:1762-1763 put_var legacy fast** | R+W | 同 #4 | 同 #4 |
| 7 | **inline_calls.zig:706-711 borrow 臂** | W(整slice) | captures 别名,前置 allCapturesAreCellsCached | 直接别名,gate 简化见 §4 |
| 8 | **inline_calls.zig:348-349 isSimpleInlineFrame gate** | R | captures 逐元素 header 判 cell(memo) | 恒真,整条删除 |

### 1.2 构造/析构(帧生命周期,11)

| # | 位置 | R/W | 今形态 | 迁后 |
|---|---|---|---|---|
| 9 | frame.zig:231-239 `Frame.var_refs` 字段 + `var_refs_borrowed` | 定义 | `[]JSValue` | `[]*core.VarRef`;borrowed 语义不变 |
| 10 | frame.zig:45/75/92(FrameSlab.carve)、110/126/142(allocHeap) | W | slab 按 JSValue(16B)分窗 | 指针 8B:窗口尺寸公式改,slab 分区算术全查(与 open_var_refs 的 bytesAsSlice 同法) |
| 11 | frame.zig:611/621-628 teardown | W | 非 borrow 逐元素 `value.free` | 非 borrow 逐元素 cell unref(qjs 16199 free_var_ref) |
| 12 | frame.zig:835-848 `ensureVarRefsCapacity` | W | **raw undefined backfill(非 cell 来源①)** | 新槽填 fresh closed cell(undefined 值);终态仅 cold 路径保留 |
| 13 | vm_call.zig:161-256 `initFrameVarRefs` 三路 | W | 路1 继承 dup(可 raw/nest 透传);路2 initialClosureVarRef(全 cell);路3 var_ref_names(全 cell) | 路1 = cellify 边界(chase+wrap,§2.3);路2/3 类型直移 |
| 14 | vm_call.zig:258-279 `initialClosureVarRef` | 产 | 每臂产 cell value | 返回 `*VarRef` |
| 15 | inline_calls.zig:518-525/601-621 一般路 setupInlineEntry | R+W | frame_var_refs 来源=captures 或 merged | 类型直移;`allVarRefCells` 恒真删 |
| 16 | inline_calls.zig:713(→initFrameVarRefs)| W | 同 #13 | 同 #13 |
| 17 | zjs_vm.zig:315-497 runWithArgs* 参数网(var_refs: []const JSValue,root.zig:85 runWithVarRefs、promise_ops.zig:2804/2845 continuation)| 传 | 值 slice 贯穿 30+ 参数签名 | `[]const *core.VarRef` 全签名同步换(编译器驱动) |
| 18 | zjs_vm.zig:632(entry initFrameVarRefs)| W | 同 #13 | 同 #13 |
| 19 | vm_gen_async.zig:63-102 save / 116-172 resume | R+W | 整 slice 进出 generator payload | payload 类型同步翻(§6 风险1) |

### 1.3 解释器槽操作(exec 层,12)

| # | 位置 | R/W | 今形态 | 迁后 |
|---|---|---|---|---|
| 20 | slot_ops.zig:174-175 execGetVarRef | R | 任意 | cell 直读 |
| 21 | slot_ops.zig:189-250 execGetVarRefMaybeTdz | R | cell/raw 双分支(242-249 raw TDZ 臂) | 单 cell 分支;raw 臂死代码删除 |
| 22 | slot_ops.zig:266-335 execPutVarRef | R+W | cell 臂 + raw 臂(304-334)+ 335 raw 元素写(**非 cell 来源②:raw 槽自我延续**) | 仅 cell 臂;publishTopLevelFunctionVarRef 语义保留 |
| 23 | slot_ops.zig:423-427 execSetVarRef | W | setSlotValue(可 raw 写) | cell.setVarRefValue 直写 |
| 24 | slot_ops.zig:430-461 slotValueDup/Borrow/varRefSlotIsUninitialized/…IsDeletedEvalBinding | R | **深 16 层 chase 循环(嵌套 cell 证据)** | var_refs 用途处退化为 `cell.pvalue.*` 单读;eval 表用途保留(表仍 []JSValue) |
| 25 | slot_ops.zig:468-489 setSlotValue/setSlotValueRefCounted | W | 通用槽写(locals/args/var_refs 共用) | 保留给 locals/args;var_refs 写点改走 cell API |
| 26 | slot_ops.zig:509-527 ensureVarRefCell/ensureFrameVarRefCell | W | 槽 raw→cell 就地重绑 | var_refs 用途消失(构造期已 cell);locals/args 用途保留 |
| 27 | vm_property_ref.zig:139-146 make_var_ref_ref | W | ensureVarRefsCapacity + ensureVarRefCell | `frame.var_refs[idx]` 已是 cell,直接 dup 引用 |
| 28 | vm_property.zig:320-348 bindingStoreWritable/storeBindingOwnedValue | R+W | cell/raw 双分支 | 单 cell 分支 |
| 29 | vm_property.zig:473-524 varRefReadableBorrowed(+ForFastPath)/varRefStoreWritableForFastPath | R | cell/raw 双分支 + slotValueBorrowed chase | 单 cell 读 |
| 30 | vm_property_locals.zig:499(int32 fused 写)| W | setSlotValue | cell 直写 |
| 31 | vm_property_globals.zig:180-181(cold getVar)/687-688(cold putVar)| R | cell 命中分支 | 判别删除,cell 直读;deleted-binding UNINITIALIZED sentinel 语义不变 |
| 32 | vm_arith.zig:817 / vm_literal.zig:162 / vm_property.zig:1114 / vm_property_globals 两处 frameHasVarRefBinding + vm_property.zig:1043 len | R(len) | 仅长度/名字 | 不变(只读 len) |

### 1.4 闭包捕获 / eval / module / 全局定义(突变期写点,16)

| # | 位置 | R/W | 今形态 | 迁后 |
|---|---|---|---|---|
| 33 | object_ops.zig:430-476 createBytecodeFunctionObject 捕获 switch(js_closure2 本体) | R+W | `.local/.arg`=cell;`.ref`=445 ensureVarRefCell **重绑写**;`.global_ref`=452 **raw dup 透传(非 cell 来源③)**;`.global/.global_decl`=cell;module=cell | 每臂返回 `*VarRef`;`.ref/.global_ref` 变纯指针拷贝+rc++(qjs 17322-17324);445/462 重绑消失 |
| 34 | object_ops.zig:253-264 createGlobalClosureVarRef | 产 | cell | 返回 `*VarRef`(≙ js_closure_define_global_var/js_closure_global_var 复合) |
| 35 | object_ops.zig:266-299 directEvalClosureBindingCapture | 产 | eval 表命中返回表元素 dup(**表可含 raw,非 cell 来源④**) | 返回前 cellify(表本身仍 []JSValue,边界转换) |
| 36 | object_ops.zig:478/2383 setValueSlice(captures 落盘)+ core/object.zig:4518 functionCapturesSlot | W/定义 | `*[]JSValue` | `*[]*VarRef`;GC visitor object.zig:6354 改 header 遍历(qjs 16211) |
| 37 | string_ops.zig:3982-3995 replaceFrameVarRefBinding | W(元素) | eval republish 整 cell 顶替元素(**borrow 排除原因之一**) | 保留(типed 指针顶替);仍与 borrow 互斥(写共享数组) |
| 38 | call_runtime.zig:3893-3916 defineGlobalDeclLexicalCell(PASS2 重绑)| W(元素) | TDZ 占位 cell → ctx.lexicals 共享 cell 顶替 | 保留,типed;qjs js_closure_define_global_var 17148-17162 对应(let 遮蔽 cell 手术是 GET-VAR Step2,另案) |
| 39 | call_runtime.zig:8203-8227 setFrameVarRefValue | R+W | ensureVarRefsCapacity + sentinel 判 + setSlotValue | cell 直写 |
| 40 | call_runtime.zig:4361-4489 createDirectEvalVarRefCells + 4472-4476 表扫描 | 产 | 全 cell(deletable) | 不变(eval 表域);产物流入 #35 |
| 41 | call_runtime.zig:4890-4960 publishDirectEvalVarRefs(→#37、frame_cold.eval_var_refs_republished)| W | cells 进帧表+republish | 不变(表域);经 #37 进槽数组时已 typed |
| 42 | call_runtime.zig:4520-4560 visible-local 捕获、8104-8129 deleteNamedVarRefBinding/deleteVarRefSlot(delete→UNINITIALIZED sentinel)、8131-8175 lookupNamed*、8229-8258 setNamedVarRefValue | R/W | eval 表域(cell/raw 混) | 不变 —— eval 名字表保持 []JSValue,Step 4(eval 编译期闭包化)才消灭;与槽数组的交换处 cellify |
| 43 | eval_ops.zig:104-163 createDirectEvalOuterVarRefs | R | 152 `frame.var_refs[idx].dup()` **raw 透传(非 cell 来源⑤)** | 元素已 cell,dup=rc++;产物表仍 []JSValue |
| 44 | eval_ops.zig:638-708 direct-eval 帧 var_refs 组装 → runWithArgsState | W | createDirectEalFrameVarRefs 产 slice | 类型直移 |
| 45 | module.zig:179-232 buildModuleVarRefs(222 moduleImportCell/223 moduleLocalCell)| 产 | `.module_import`=**createConstVarRefCell(target)=cell-in-cell(非 cell 来源⑥/嵌套唯一制造者)** | import 槽=目标 cell 直接别名+rc++(qjs 30765-30777),const 移到 cv.is_const 编译期;嵌套灭绝 |
| 46 | module.zig:271-330 moduleFunctionDeclarationPrologue(284-287 帧组装 + 328 setSlotValue)| W | dup module cells 进帧 | typed;写走 cell |
| 47 | module.zig:389-470 moduleLocalCell/moduleNamespaceCell/createVarRefCell* + record.local_bindings[].cell | 产 | record 侧 cell(JSValue 存) | record.cell 可保留 JSValue(域外),进槽数组处已是 cell;或同波次 typed(建议:保留,少动) |
| 48 | vm_property_globals.zig:1053+ instantiateGlobalVarDeclarations(→#38)| W | gv 循环定义 | 不变(调用 #38) |

### 1.5 其余读点(5)

| # | 位置 | R/W | 迁后 |
|---|---|---|---|
| 49 | forof_ops.zig:355 destructuringStateTargetsIterator | R 扫 | 遍历 cell.pvalue.* |
| 50 | eval_ops.zig:112/153(函数名重复,createDirectEvalOuterVarRefs 内)| R | 同 #43 |
| 51 | inline_calls.zig:838-858 mergeEvalBindings(captures ++ eval_refs memcpy)| R+产 | merged 类型化:captures 半已 typed,eval_refs 半 cellify;`merged_var_refs: []*VarRef` |
| 52 | core/object.zig:716/749-755/3754-3760/6336/6837 generator payload frame_var_refs | R/W | `[]*VarRef` + visitor/free/计数四处同步 |
| 53 | tailcall_dispatch_colds.zig(cold 表转发,无直接槽访问)+ src/tests/bytecode.zig 2 处 | — | 随签名重编 |

**不在本案范围**(同名不同物,勿动):`bytecode.zig var_refs_len/var_ref_names`(编译期计数/名表)、`core/object.zig:472 arguments payload var_refs`(mapped arguments 别名表,qjs `p->u.array.u.var_refs` 也是 `JSVarRef**` —— 可作后续同法迁移,本案不含)、`frame.open_var_refs: []?*VarRef`(**已经是类型化的**,≙ qjs `sf->var_refs` open-ref 缓存 16997-17045,勿混淆)、`FrameCold.eval_var_refs`(eval 名字表,Step 4 域)。

## 2. qjs js_closure2 chase 语义逐段转译(17262-17339)

### 2.1 verbatim + 逐臂解释

```c
static JSValue js_closure2(JSContext *ctx, JSValue func_obj, JSFunctionBytecode *b,
                           JSVarRef **cur_var_refs, JSStackFrame *sf, BOOL is_eval, JSModuleDef *m)
{
    ...
    if (b->closure_var_count) {
        var_refs = js_mallocz(ctx, sizeof(var_refs[0]) * b->closure_var_count);   // 17277
        ...
        if (is_eval) {                                                            // 17281
            /* first pass to check the global variable definitions */
            for(i = 0; i < b->closure_var_count; i++) {
                JSClosureVar *cv = &b->closure_var[i];
                if (cv->closure_type == JS_CLOSURE_GLOBAL_DECL) {
                    ... if (JS_CheckDefineGlobalVar(ctx, cv->var_name, flags)) goto fail;
                }
            }
        }
        for(i = 0; i < b->closure_var_count; i++) {                               // 17297
            JSClosureVar *cv = &b->closure_var[i];
            JSVarRef *var_ref;
            switch(cv->closure_type) {
            case JS_CLOSURE_MODULE_IMPORT:
                /* imported from other modules */
                continue;                                                          // 17301: 槽留 NULL
            case JS_CLOSURE_MODULE_DECL:
                var_ref = js_create_var_ref(ctx, cv->is_lexical);                  // 17305: 新建
                break;
            case JS_CLOSURE_GLOBAL_DECL:
                var_ref = js_closure_define_global_var(ctx, cv, b->is_direct_or_indirect_eval); // 17308
                break;
            case JS_CLOSURE_GLOBAL:
                var_ref = js_closure_global_var(ctx, cv);                          // 17311
                break;
            case JS_CLOSURE_LOCAL:
                var_ref = get_var_ref(ctx, sf, cv->var_idx, FALSE);                // 17315: 复用或新建 open ref
                break;
            case JS_CLOSURE_ARG:
                var_ref = get_var_ref(ctx, sf, cv->var_idx, TRUE);                 // 17319
                break;
            case JS_CLOSURE_REF:
            case JS_CLOSURE_GLOBAL_REF:
                var_ref = cur_var_refs[cv->var_idx];                               // 17322-17324: 纯指针拷贝
                js_rc(var_ref)->ref_count++;
                break;
            default: abort();
            }
            if (!var_ref) goto fail;
            var_refs[i] = var_ref;                                                 // 17331
        }
    }
    return func_obj;
 fail: ...
}
```

### 2.2 关键判定:qjs 在哪里「chase」、在哪里「新建」

**qjs 读端永远不 chase** —— OP_get_var/OP_get_var_ref 只做 `*var_refs[idx]->pvalue`。所谓 chase 全部发生在**构造/link 期**,且严格说 qjs 没有「cell-in-cell 解嵌套」问题,因为嵌套从未被制造:

| 场景 | qjs 机制(行号) | 何时新建 cell | 何时复用/别名(= zjs 的「chase」点) |
|---|---|---|---|
| module import | js_closure2 `continue`(17301)留 NULL → `js_inner_module_linking`(30715-30791)填:`var_ref = res_me->u.local.var_ref;`(经 export entry 一跳)或 `p1->u.func.var_refs[res_me->u.local.var_idx]`,然后 `js_rc(var_ref)->ref_count++; var_refs[mi->var_idx] = var_ref;`(30766-30773) | 仅 namespace-from(30755 js_create_var_ref 装 ns 对象) | **导入槽 = 导出模块 cell 的直接别名**。「一跳」走的是 export-entry 表,不是 cell 值 —— 永无嵌套 |
| REF/GLOBAL_REF | 17322-17324 | 从不 | `cur_var_refs[cv->var_idx]` 指针拷贝;类型系统保证父槽必是 cell,无需运行时判 |
| LOCAL/ARG | `get_var_ref`(16997-17045):`sf->var_refs[vd->var_ref_idx]` 命中则 rc++ 复用 | 未命中新建 **open** ref(pvalue 指帧槽)并缓存进 `sf->var_refs` | 同一局部变量多闭包共享同一 open cell(O(1) var_ref_idx 索引) |
| GLOBAL_DECL | js_closure_define_global_var(17125-17226):lexical→global_var_obj VARREF 属性;var→global_obj VARREF 属性;**17148-17162 let 遮蔽既有 var 的 cell 手术**(旧 cell 值搬进新 cell、旧 cell 置 UNINITIALIZED 顶属性) | 属性不存在时 | 属性存在时复用 `pr->u.var_ref` |
| GLOBAL | js_closure_global_var(17228-17260):global_var_obj → global_obj VARREF → `js_global_object_get_uninitialized_var`(17069-17096,uninitialized_vars 侧表 cell) | 侧表未命中 | 三级查找全是「找到既有 cell 就别名」 |
| MODULE_DECL | 17305 js_create_var_ref;export entry 在 link 期回填共享(30783-30790) | 总是(实例化一次) | export/import 双方后续都别名它 |

### 2.3 与 zjs 既有机制的对应及缺口

| qjs | zjs 现状 | 类型化后动作 |
|---|---|---|
| js_closure_define_global_var(var 分支) | `createGlobalClosureVarRef`(object_ops.zig:253)→ `globalObjectVarRefCell`/`ensureGlobalObjectVarRefCell`(call_runtime.zig:3776/3785,注释已锚定 17171-17205)| 返回类型改 `*VarRef`,机制不动 |
| js_closure_define_global_var(lexical 分支 PASS1/PASS2)| zjs 拆两半:initFrameVarRefs 路3 造 TDZ 占位 cell(vm_call.zig:232-245)+ defineGlobalDeclLexicalCell PASS2 顶替(call_runtime.zig:3893)| 保留拆分(qjs check-before-create 语义);顶替变 typed 指针写 |
| js_closure_global_var 三级查找 | initialClosureVarRef `.global` 臂(vm_call.zig:258)+ createGlobalClosureVarRef;**无 uninitialized_vars 侧表**(GET-VAR Step 1 域,另案) | 类型直移;侧表缺口不在本案 |
| get_var_ref 的 sf->var_refs 缓存 | `frame.open_var_refs` + `findOpenVarRef` 线性扫(slot_ops.zig:516-527)——已类型化 `[]?*VarRef` | 不动(结构对应正确;线性扫 vs var_ref_idx O(1) 是独立小偏离,可注 TODO) |
| cur_var_refs 指针拷贝 | `.global_ref` raw dup(object_ops.zig:452)/`.ref` ensureVarRefCell 重绑(445) | **纯指针拷贝 + rc++** —— 类型保证父槽是 cell,重绑与判别删除 |
| js_inner_module_linking 直接别名 | `moduleImportCell` **包一层 const wrapper cell**(module.zig:365-381 `createConstVarRefCell(ctx, target)`)→ 读端被迫 chase(守卫 #7 存在的主因) | 删 wrapper:槽 = 目标 cell 别名;import 只读性走 `cv.is_const`(closure_var 编译期已有,object_ops.zig:466-472 captured_const 通路)。这是 qjs 31882 `JS_CLOSURE_MODULE_IMPORT` + 编译期 const 的忠实形态 |
| is_eval 先行 JS_CheckDefineGlobalVar pass | zjs 分散在 instantiateGlobalVarDeclarations / check_define_var 路径 | 不动(已对应) |

## 3. 非 cell 槽的现存来源清单与改造方案

按「谁第一次把 raw/nest 放进 var_refs」归因(§1 表中标号①-⑥):

| 来源 | 位置 | 触发路径 | 改造 |
|---|---|---|---|
| ① raw undefined backfill | frame.zig:835-848 ensureVarRefsCapacity | 字节码 var_ref idx ≥ 初始长度:make_var_ref_ref(vm_property_ref.zig:144)、eval 引入 ref(slot_ops 各 exec*VarRef)、setFrameVarRefValue | 新槽填 fresh closed cell(undefined);同时构造期把初始长度定为 `max(closure_var.len, varRefNamesLen, 继承长度)` 让增长仅剩真 eval 动态路径 |
| ② raw 槽自我延续 | slot_ops.zig:335/427/487(setSlotValue raw 元素写)、execPutVarRef raw 臂 304-334 | 槽已 raw 时写入保持 raw | ①③④⑤消灭源头后这些臂变死代码;类型化 commit 里直接删,TDZ/const/sentinel 检查并入 cell 臂 |
| ③ `.global_ref` 捕获透传 | object_ops.zig:451-452 | 父帧槽 raw 时子闭包捕获继承 raw | 类型保证父槽 cell → 纯指针拷贝;过渡期(阶段 B)先改 `ensureVarRefCell(&frame.var_refs[cv.var_idx])` 兜底 cellify |
| ④ eval 表值透传 | object_ops.zig:280-283 directEvalClosureBindingCapture 第二循环 `eval_var_refs[idx].dup()` | eval 名字表元素非 cell(表设计允许 raw 快照) | 返回前 `ensureVarRefCell` 包装(边界转换);表本身不动(Step 4 域) |
| ⑤ outer-refs 快照透传 | eval_ops.zig:152 `frame.var_refs[idx].dup()` | direct eval 捕获外层槽 | 源头①③修后此处必是 cell;dup=rc++ |
| ⑥ module import 嵌套 cell | module.zig:365-381 moduleImportCell wrapper | 每个跨模块 import | §2.3:wrapper 删除,直接别名 + cv.is_const;**这是守卫 #7(嵌套判)唯一的常态制造者**,slotValueBorrow 深 16 chase 循环即其证据 |
| (辅)generator resume 回放 | vm_gen_async.zig:161 | 恢复 save 时的任意形态 | 无自身产源 —— ①-⑥修完后 save 的必是 cells;payload 类型翻转后由编译器锁死 |
| (辅)mergeEvalBindings memcpy | inline_calls.zig:852-854 | captures(半 typed)++ eval_refs(raw 可能) | eval_refs 半逐元素 cellify;merged_var_refs 类型化 |

## 4. captures borrow gate 的类型化简化(inline_calls.zig)

现 gate(inline_calls.zig:616-620):
```zig
const borrow_var_refs = entry.simple_frame and
    !entry.function.flags.has_eval_call and
    entry.function.global_vars.len == 0 and
    frame_var_refs.len > 0 and
    allVarRefCells(frame_var_refs);          // ← 逐元素 header 载入(memo 版 line 775)
```

类型化后逐项:
- `allVarRefCells` / `allCapturesAreCellsCached` / `functionCapturesCellState` memo 字节(core/object.zig)——**类型恒真,三者整体删除**;`isSimpleInlineFrame` 的 349 行前置同删(-1 分支 -1 对象字段载入/call)。
- `simple_frame`(无 merged eval 视图)——**保留**:mergeEvalBindings 会造 entry 私有数组,借用无意义。
- `!has_eval_call` ——**保留**:replaceFrameVarRefBinding(#37)与 eval 引入 ref 的 ensureVarRefsCapacity 增长都会**写/realloc 共享 captures 数组**;类型化不改变「元素级顶替对共享数组可见」这一事实。
- `global_vars.len == 0` ——**保留**:defineGlobalDeclLexicalCell(#38)PASS2 顶替元素,同上。
- `frame_var_refs.len > 0` —— 保留(空借无意义)。

净效果:gate 从 5 条件降为 4 条纯标志位测试(全部一字节/一 len 判),动态逐元素扫描与 memo 机制消失;注释块 602-615 的四条件论证缩为三条。**borrow 与 current_function owned 的生命线耦合不变**(不变式 1)。

## 5. 分阶段实施顺序(每阶段独立可门禁)

| 阶段 | 内容 | 改动面 | gate 矩阵 |
|---|---|---|---|
| **A. 访问收口(纯机械)** | 全部 §1.3/1.4 的 `frame.var_refs[idx]` 裸访问改经 slot_ops 新 accessor(`varRefSlotCell/…`),行为逐字节不变;tests 同步 | slot_ops + 15 文件调用点 | zig build zjs+run-test262 顺序重建 → test262 全量 0/49775(known 13)+ zig build test 分段比对 |
| **B. 非 cell 源头逐个消灭(①③④⑤,各自独立 commit)** | ① capacity backfill→cell;③ global_ref 捕获 ensureVarRefCell 兜底;④ eval 表边界 cellify;⑤ 随①③自动;每 commit 后加 debug 断言 `assert(varRefCellFromValue(slot)!=null)` 于 accessor(release 无价) | frame.zig / object_ops.zig / eval 边界 | 每 commit:test262 重点族 language/eval-code、language/global-code、annexB(function-in-eval 提升)、language/statements/{generators,async-generator}+ 全量;force-GC smoke |
| **C. module import 去嵌套(⑥)** | moduleImportCell wrapper 删除→直接别名 + cv.is_const 只读;core/module record 交界核对;slotValueBorrow 的 var_refs 用途降为单读(chase 循环保留给 eval 表) | module.zig + object_ops captured_const | test262 language/module-code 全族 + dynamic-import + 全量;module TLA 已知 13 known 不得变化 |
| **D. 类型翻转(一次性,单 commit)** | `Frame.var_refs: []*VarRef`、`var refs 参数网`(zjs_vm 30+ 签名)、`functionCapturesSlot *[]*VarRef`、generator payload、merged_var_refs、FrameSlab 8B 窗口算术、teardown free→unref、GC visitor 6336/6354 header 遍历、②的 raw 臂死代码删除;**编译器驱动:阶段 A 的 accessor 让错误集中** | frame/vm_call/inline_calls/object_ops/slot_ops/zjs_vm/tailcall_dispatch(+colds)/vm_gen_async/module/eval_ops/call_runtime/core.object | **全量 test262(帧改动唯一 oracle,先顺序重建两个二进制)+ zig build test + force-GC 全 smoke(closure/recursion/PTC/exception 混合)+ ASAN/debug allocator 跑 generator/eval 族** |
| **E. 守卫删除 + 简化(收果)** | op_get_var/opGetVarRef/put 系删 #4/#7;#3 bounds:构造定长后 simple 路径删(captures.len ≥ max idx 已注释论证),eval 动态路径留 cold;§4 gate 简化;legacy zjs_vm 六块同步 | tailcall_dispatch ×2 + zjs_vm ×6 + inline_calls | 全量 test262 + perf:fib/funcall taskset 绑核 perf stat instructions vs qjs(预期 op_get_var self 10.9%→~6%,fib wall −~9% 上限);对照 GET-VAR-RECON §3 基线 |

依赖:B 依赖 A(断言挂在 accessor);C/B 互相独立;D 依赖 B+C 全绿(否则类型翻转把 raw 写变成编译错误的同时把「遗漏的 raw 读」变成野指针);E 依赖 D。每阶段 gate 前纪律:`zig build zjs` 先行(stale-binary 陷阱),run-test262 独立二进制单独重建。

## 6. 风险清单

1. **generator/async suspend 跨帧不变式(最高)**:`frame.var_refs` 经 vm_gen_async save/resume 进出 generator payload;类型翻转若 payload(core/object.zig:716)、GC visitor(6336)、free 路径(749/755)、async_generator.zig:203-208 四处不与 Frame 同 commit 翻转,挂起的 generator 持有旧型 slice → resume 后按新型解读 = 内存腐败;且 cell 的存活从「payload 值持引用」变「payload 指针持引用」,visitor 少 mark 一处 → force-GC 下 cycle collector 释放活 cell(UAF)。**对策**:阶段 D 单 commit 原子覆盖 + force-GC 构建全 smoke + generator/async-generator test262 族在 gate 矩阵置顶。
2. **eval republish/动态增长写点遗漏**:replaceFrameVarRefBinding、defineGlobalDeclLexicalCell、setFrameVarRefValue、ensureVarRefsCapacity 是仅有的元素级顶替/realloc 点;它们与 borrow 别名(captures 共享)交互 —— 漏改一处 = 向 8B 指针数组写 16B JSValue(FrameSlab/bytesAsSlice 一带是弱类型算术,编译器抓不全);realloc 点还叠加历史教训「缓存 var_refs 指针跨 realloc UAF」。**对策**:阶段 A 收口后写点只剩 accessor 一层;FrameSlab 窗口算术单测(尺寸/对齐断言);annexB+eval-code 族每阶段必跑。
3. **「cell 值永不是 cell」终态不变式失守**:守卫 #7 删除(阶段 E)的前提是⑥灭绝且所有 `setVarRefValue` 入口不再可能存入 cell value(今天 setSlotValueRefCounted:478-481 还在防御性解包)。若任何冷路径(eval 表→槽交换、mapped arguments、序列化恢复)重新引入嵌套,fast path 会把 cell value 当普通对象 dup 返回 —— **无崩溃的静默语义错**,只有 module/eval 深组合测试能暴露。**对策**:`VarRef.setVarRefValue` 加 debug 断言 `assert(fromValue(next)==null)` 常驻;阶段 C 后即开断言(先于 E 删守卫两个阶段的浸泡期)。
4. 双写过渡 vs 一次性切换:**选一次性(阶段 D)**。双写(并行维护 []JSValue+[]*VarRef 两数组)被否:两数组都要穿越 generator suspend、FrameSlab 要开双窗、每写点双份 refcount —— 不变式表面积翻倍,恰是风险 1/2 的放大器;而 B+C 完成后动态不变式已是 all-cells,类型切换只是把既成事实交给编译器,错误面=编译错误清单。
5. 次要:borrow teardown 半翻(不变式 1,double-free/leak,force-GC oracle);perf 回退风险低但须 A/B(TIME 为尺,E1/E3 教训:insn 降 ≠ time 降);known 13 基线漂移(module TLA 族对 module.zig 改动敏感,阶段 C 前后 diff known 清单)。

## 附:工作量与收益预估(承 GET-VAR-RECON §5)

A ~0.5 日;B ~1 日;C ~0.5-1 日(module 族回归重);D ~1.5-2 日(签名网大但编译器驱动);E ~0.5 日+perf 复核。合计 ~4-5 agent-日,与 RECON 的 Step3 估计(3-4 日)相符略宽。收益上限:op_get_var/get_var_ref/put_var 系 28% self-time(#4/#7 两条 ldurb)+ #3 + gate 扫描,≈ fib 总时间 5-6%(Step3 单独)——RECON 的 9% 需叠加 Step1/2 才满额。
