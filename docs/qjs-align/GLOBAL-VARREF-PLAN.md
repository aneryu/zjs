# 全局变量访问忠实对齐 qjs:var_ref 绑定(最大剩余 perf 杠杆 ~4.46×)

状态:**✅ 已落地（2026-06-24）**。本计划已执行：var_ref-cell 下沉 + 33 个作用域回归全修，test262 0/49775、global-read 7.08×→2.45×、global-write 6.70×→2.98×（over 真实 baseline）、fib 中性。施工细节与剩余前沿见 `HANDOVER-global-varref.md`。下文为执行前的深度分析记录（保留备查）。

## ⭐⭐ 2026-06-24 关键修正:qjs OP_get_var 本身就是 var_ref 解引用 + fallback(不是换 opcode!)

**读 qjs 源 OP_get_var(quickjs.c:18462-18488)定论**:
```c
CASE(OP_get_var): {
    idx = get_u16(pc);
    val = *var_refs[idx]->pvalue;          // ← OP_get_var 本身就是 var_ref 解引用!
    if (unlikely(JS_IsUninitialized(val))) {
        cv = &b->closure_var[idx];
        if (cv->is_lexical) { TDZ error; }
        else sp[0] = JS_GetPropertyInternal(ctx, global_obj, cv->var_name, ...); // ← uninitialized 时 fallback 到全局对象查找
    } else sp[0] = JS_DupValue(ctx, val);  // ← 快路径 = var_ref 解引用
}
```
**所以 qjs 给每个全局访问都绑一个 closure_var/var_ref**:脚本声明的全局 → var_ref alias 全局 cell(initialized);host/未声明全局(Date 等) → var_ref **uninitialized**,OP_get_var deref 发现 uninitialized 就 **fallback 到 `JS_GetPropertyInternal(global_obj)`**。一个 opcode 二合一。`JS_CLOSURE_GLOBAL`/`_DECL` 的 "eval only" 注释指 closure_type 细节,非"普通代码不绑 var_ref"。

**2026-06-24 codex 尝试的结果(已回退)**:
- **perf 方向证实对**:var_ref 绑定让 global-read **794→361 insn/iter(4.46×→~2×,2× 加速)**。var_ref 解引用路子 work。
- **但 codex 用错 opcode**:emit `get_var_ref`(纯 var_ref 解引用,**没 fallback**)替代 `get_var`,而非保持 get_var 改其实现。host/built-in 全局没绑 var_ref → `get_var_ref` 直接 ReferenceError → **test262 4267 失败(全 ReferenceError)** + 9 个 bytecode 期望测试(顶层 x+=1 改 emit get_var_ref)。已 `git checkout -- src/` 回退,基线恢复(global-read 794、dispatch 168、单测 1223)。

**【2026-06-24 v2/v3 结果:方法证实成功,卡在 param-eval 作用域硬阻塞】**
- **v2(修正版,patch `/tmp/gvr2_v2.patch`)**:保持 get_var/put_var opcode、实现改成 qjs OP_get_var 二合一、每个全局绑 var_ref(含 host uninitialized→fallback)。**结果:单测 1223 绿、host 全局正确(typeof Date/Object/Math 正常)、global-read 794→429(4.46×→2.4×,1.85× 改善)、test262 4267→33**。零 bytecode 测试 churn(opcode 没变)。**方法完全证实——host fallback bug 已解**。
- **剩 33 失败 = 单一硬根因**:`scope-param-*-var-*` / "sloppy direct eval in params introduce vars"。函数(含 generator/method/arrow)**参数默认值里直接 `eval('var x=...')`** 运行时引入遮蔽 var,闭包捕获的 x 应解析到该 binding 而非全局 var_ref。codex 的"函数含 eval→走动态 get_var"守卫没覆盖**参数里**的 eval。
- **v3 尝试(close 33)**:加参数 eval 检测 + direct-eval parent link,迭代 40min **没收敛**(仍 33,分类微移)。这是 da34bc1 历史回归区(微妙作用域解析 + param-scope environment),真难,需专门仔细做、非一轮 codex。
- **已回退到干净基线**(global-read 794/dispatch 168/单测 1223/test262 0/49775)。v2 态 patch 留存供下次 re-apply 后只攻 param-eval。
- **下次 spec**:re-apply `/tmp/gvr2_v2.patch`,然后保守化分类——**任何函数只要 params 或 body 含直接 eval、或 with、或复杂 param scope,该函数所有 free-var 访问一律走动态 get_var**(不信全局 var_ref);只对最简单 no-eval/no-with 函数用 var_ref 快路径(perf 赢就来自这里)。需精确实现"params 含 direct eval"的编译期检测 + 闭包定义在此类函数内时的传播。

**【2026-06-24 33 失败是多根因,非单一 param-eval】** 逐文件查:33 个里 **19 含 eval/with、14 不含**。多根因:
1. **params/body 含 direct eval 或 with(19)**:eval 运行时引入遮蔽 var。修法=程序级或函数级 eval/with 标志→该作用域 free-var 走动态 get_var(只闭合 19)。
2. **generator try-finally + return(4)**:`GeneratorPrototype/return/try-finally-*`,var_ref 与 generator suspend/resume 跨 try-finally 的交互。
3. **named function expression 自名作用域(5)**:`generators/scope-name-var-*` + `named-no-strict-reassign-fn-name-*`,具名函数表达式自身名字绑定(特殊只读 binding)与 var_ref 冲突。
4. **顶层 script-decl-func 等(剩)**:顶层函数声明的全局 var_ref。
⟹ **每个都是独立 scope 解析子领域**,确证 global var_ref = 真深多根因结构块(同 call-machinery C 递归、value-model 地板),**非一轮 codex 可闭合,需逐根因专门做**。建议下次按根因分阶段:先 ① 程序级 eval/with gate(闭 19、低风险)、再逐个攻 generator/named-fn-expr/script-decl。每阶段 test262 必须不增新失败。

**⟹ 正确的忠实做法(下次精确 spec)**:
1. **不换 opcode**——保持 `get_var`/`put_var`,把其**实现**改成 qjs OP_get_var 结构:`*var_refs[idx]->pvalue` 解引用;uninitialized 且非 lexical → fallback `JS_GetPropertyInternal(global_obj)`;lexical uninitialized → TDZ。
2. **每个全局访问都绑 closure_var/var_ref**(含 host/未声明的 → uninitialized cell),不只脚本声明的。这样 host 全局走 fallback、脚本全局走 var_ref 快路径。
3. put_var = var_ref store + 对 uninitialized/写穿全局对象的处理(qjs OP_put_var 18490)。
4. 验:test262 必须 0/49775(host 全局 fallback 是关键);global-read 应到 ~1×(已证 var_ref deref 给 2×,加 fallback 不损快路径)。

---

## 问题:zjs 每次全局访问走全作用域链,qjs 闭包创建时绑一次 var_ref

实测 `var g=0; function f(){var s=0;for(i<5e7){s=s+g;}return s;}`:zjs ~4.46× qjs。
profile 显示全局读 `g` 每次走 `exec.vm_property_globals.getVar`(29.63%)→ `lookupFrameVarRef`(13.55%)+ `globalLexicalValueForGlobal`(3.80%)+ `getOwnDataProperty`(6.59%)的**完整作用域链查找**。

qjs 的结构(quickjs.c):
- 编译期把每个变量访问分类成 `closure_var` 条目,`closure_type` ∈ {LOCAL/ARG/REF/**GLOBAL**/GLOBAL_DECL/MODULE_*}。全局访问 = `JS_CLOSURE_GLOBAL`。
- 闭包创建 `js_closure2`(17262)对 `JS_CLOSURE_GLOBAL` 调 `js_closure_global_var`(17228):在 `global_var_obj`(lexical)或 `global_obj`(var)上 `find_own_property` 找到该名的 **`JS_PROP_VARREF`** 属性,取其 `pr->u.var_ref`,`ref_count++` 返回 —— **var_ref 直接 alias 全局属性的 cell**。
- 之后每次访问 = `OP_get_var_ref`(`*var_refs[i]->pvalue`,**一个指针解引用**),`OP_get_var`(作用域查找)只是 direct-eval/with/动态的 fallback。
- 全局 `var`/function 声明 `js_closure_define_global_var`(17125)把全局属性建成 `JS_PROP_VARREF`(cell),供后续闭包 alias。

## zjs 现状(Explore map,均已存在但仅 eval 用)

| 件 | 位置 | 状态 |
|---|---|---|
| `ClosureType` enum(含 `.global`/`.global_ref`/`.global_decl`) | `core/bytecode.function_bytecode:19-29` | ✅ 有,但 `.global` 仅 eval 上下文 set |
| `ClosureVar` struct | `core/bytecode.function_bytecode:58-65` | ✅ |
| opcode 决策 get_var vs get_var_ref | `bytecode/pipeline/resolve_variables.zig:156-180,248-315` | `ensureGlobalClosureVar` 只在 eval 建 `.global` |
| 闭包创建绑 var_ref | `exec/vm_call.zig:152-245 initFrameVarRefs` + `247-257 initialClosureVarRef` | ⚠️ `.global` 路径 `createClosed(uninitialized())` **不 alias 全局属性 cell**(≠ qjs) |
| VarRef struct(pvalue/ref_count/is_open...) | `core/var_ref.zig:12-25` | ✅ |
| 全局属性 var_ref 槽(`Slot.var_ref = *VarRef`,= JS_PROP_VARREF) | `core/property.zig:125-133` | ✅ 但**只 global lexical(let/const)用**;`var`/function 仍是 `Slot.data` |
| get_var_ref 快路径(裸 `cell.pvalue.*` 内联) | `exec/zjs_vm.zig:1026-1050` | ✅ |
| getVar 慢路径(全链) | `exec/vm_property_globals.zig:206-330` + dispatch `zjs_vm.zig:1559` | 当前唯一全局路径 |

## 缺口(2 件,深 + 险)

**缺口 A — 全局 `var`/function 声明没建 var_ref cell**:zjs 顶层 `var g` 建 `Slot.data` 普通数据属性,不是 `Slot.var_ref` cell。qjs 全是 `JS_PROP_VARREF`。要让闭包能 alias,声明期得建 var_ref cell(像 lexical 那样)。**撞历史回归区**:`delete g`、`getOwnPropertyDescriptor(globalThis,'g')`、for-in 枚举、global get_field IC 必须 deref var_ref、跨 realm —— da34bc1 的 8 个回归(1 跨realm写穿 + 6 for-of/for-in TDZ + 1 eval-delete)全在此。

**缺口 B — 编译期没把非 eval 函数的全局访问分类成 `.global` closure var**:`ensureGlobalClosureVar` 只在 eval 调。普通脚本函数里读 `g` 不建 closure_var → 落 `get_var` 全链。要让 parser/resolve_variables 在**非 eval/with 函数**里把全局访问分类成 `.global`(并在闭包创建 alias 缺口A 的 cell)、emit `get_var_ref`。

## S0 调研结论(2026-06-24 已做,执行就绪)

**zjs 对全局 lexical(let/const)已经是 qjs 结构** —— `defineGlobalVarDeclaration`(vm_property_globals.zig:1330)对 `gv.is_lexical` 调 `call_runtime.defineGlobalDeclLexicalCell`(注释明写"qjs js_closure_define_global_var PASS2"):建共享 ctx.lexicals VARREF cell + alias 进 frame.var_refs。Slot.var_ref 的读(`object.zig:6925 cell.varRefValue().dup()`)/删(`8566/8654 return false`)/descriptor(`9598`)全 wired。**var 全局只差没走这条路**:`defineGlobalVarDeclaration` 的非 lexical 分支建 `Descriptor.data(undefined,...)` 普通数据属性。

精确缺口(3 件,coherent——任一缺则无 perf 收益):
- **A**:非 eval 顶层 `var`/function → var_ref cell(复用 lexical `defineGlobalDeclLexicalCell` 模板,但 var 语义 enumerable:true/configurable:false/writable:true)。
- **B1**:`resolve_variables` 在非 eval/with 函数里把全局访问分类 `.global` closure var(现 `ensureGlobalClosureVar` 只 eval 调)、emit get_var_ref/put_var_ref。
- **B2**:`initialClosureVarRef`(vm_call.zig:247)的 `.global` 分支改成 **find 全局属性现有 var_ref cell + ref_count++**(= qjs `js_closure_global_var` 17228),现在是 `createClosed(uninitialized())` 不 alias。
- **eval subtlety**:eval 声明的 var 是 configurable(可 delete),而 Slot.var_ref 删返 false → eval var 必须留 data 属性(只非 eval 非 configurable var 转 var_ref cell,匹配 qjs 仅 eval 加 CONFIGURABLE flag)。

## 分阶段执行计划(统一攻克时,每阶段全三门绿)

> 关键:**先地基(A)后下游(B)**(忠实对齐 keystone-first 原则)。每阶段 codex 驱动 + Claude 审计三门(test262 0/49775 是作用域正确性的硬门)。快照保护,任一阶段 cascade 即回退。

- **S0 调研**:读 zjs 顶层 var/function 声明实现(`defineGlobalVarDeclaration`/`defineGlobalFunctionBindingValue` 等)+ global lexical 现有 var_ref cell 的完整生命周期(建/access/delete/枚举/GC mark)。确认 lexical 的 var_ref 路径已正确处理 get_field/delete/descriptor/for-in —— **var 复用同路径**则风险大降。
- **S1 缺口A**:顶层 `var`/function 声明建 `Slot.var_ref` cell(复用 lexical 机械)。保 var 语义(configurable:false enumerable:true writable:true)。**重点验**:delete/descriptor/for-in/global get_field IC deref/跨 realm。门:test262 0/49775。
- **S2 缺口B**:非 eval/with 函数的全局访问编译期分类 `.global` closure var;`initialClosureVarRef` 的 `.global` 改成**真 alias 全局属性 cell**(≠ 现 createClosed uninitialized);emit get_var_ref/put_var_ref。eval/with/动态保留 get_var fallback。门:test262 0/49775。
- **S3 验 perf**:绑核 `taskset -c 19 perf stat -e instructions ... | grep pmuv3_1`,global-read 应从 4.46× 降到 ~1×(var_ref 裸解引用,≈ 局部)。

## 风险与教训

- **不可盲跑**:2026-06-24 试过运行期 IC predicate 版(getVar 走 global DATA IC),correct(test262 0/49775)但 perf **净负**(谨慎慢路径条件太严→常见 var g 不命中 + 开销回归 dispatch),已回退。运行期 predicate 是错路;qjs 的正路是**编译期分类 + 闭包期绑定**(本计划)。
- **test262 是唯一硬门**:作用域正确性(lexical/var/eval/with/TDZ/跨realm/delete)全靠它。任一阶段必须 0/49775。
- 这是**全局对齐里少数真深的结构块**(同 call-machinery C 递归)。其余热路径已被 inline-noinline 模式榨干(dispatch 1.08×/arith 2×/property 2.5×)。
