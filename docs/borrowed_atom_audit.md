# Borrowed-Atom Ownership Audit (parser / compiler side)

审计基线 commit：`3d869065`（`main`，紧随 `8c8787cd` "release identifier and
private-name token atoms" 与 `693c2997`）。审计范围：`src/parser.zig` 全文，加上
parser 交付 atom 的下游 sink（`src/bytecode.zig` 的 `FunctionDef` / 模块 `Record`
/ atom-operand 流，`src/core/module.zig`）。

本文是「先审计后修改」的书面产物：先枚举并分类每一个 **borrowed atom** 站点，
再对 class C 站点做可达性举证，最后只修 class C。

---

## 1. 为什么现在必须审计

`8c8787cd` 之前 `Lexer.freeToken` 只释放 token 的字符串 payload，从不释放
`next()` 为 `.ident` payload 内插的 atom。也就是说**每一个标识符 token 泄漏
一次 retain**，源码内插出来的 atom 永远到不了 refcount 0。在那个世界里，
「从 token 借一个 atom，然后 `advance()`，然后继续用」是安全的——因为被借的
条目不可能死。

`8c8787cd` 补上了 `.ident` 的释放臂（qjs `free_token`，quickjs.c:22190-22208），
泄漏消失，于是所有原本被泄漏掩盖的所有权隐患一次性变成真隐患。该 commit 已经
修掉了它当时识别出的一批（`dupToken` / 声明名 / 类名 / label / 对象属性名 /
参数名 / 模块 import-export 名 / TS enum + namespace）。本文是把剩下的账**记完**。

### 1.1 危害机制（这是判定 class C 的依据）

`src/core/atom.zig`：

- `free()` 递减 `ref_count`；归零调用 `finalizeDeadEntry`（atom.zig:1519）。
- `finalizeDeadEntry` 做三件事：把条目从 `string_index` 摘掉（`unindexEntry`）、
  释放 `entry.bytes` 并置空、把槽位下标压进 **LIFO** 自由链 `free_slot_head`。
- `internDynamic`（atom.zig:1398）在 hash 未命中时**优先弹出自由链头**，并且
  复用槽位保持同一个 id（`entry.id == idx + first_dynamic_atom`）。

推论：一个刚死的 atom id 并不会变成永久无效值，它会被**下一次新字符串内插**
重新绑定。于是：

1. 若紧接着重新内插的正好是同一个字符串（例如 lookahead 之后原地重新词法分析
   同一个标识符），槽位被同一个名字取回，stale id 又「活」了——**代码看起来是对的**。
2. 若中间夹进任何一次别的新字符串内插，stale id 就指向**另一个字符串**，
   `dup()` 会静默 retain 错误的条目。
3. 若 stale id 指向的槽位还没被复用，`dup()` 会命中
   `std.debug.assert(entry.hasLiveValue())`（atom.zig:1037），Debug/ReleaseSafe
   直接 panic；ReleaseFast 里它会把一个已经在自由链上的死条目 `ref_count` 拉回 1，
   随后同一个槽位会被二次 `finalizeDeadEntry` 压链——自由链出现重复项，
   之后两次 intern 拿到同一个 id。

情形 1 就是本文所说的**「靠槽位回收的运气」**：不是契约，是巧合。

---

## 2. 分类口径

- **A = SAFE**：在 token 被释放之前代码自己 `dup` 出了一份 owner；或该 atom 本就
  是 predefined / tagged-int 常量；或读取与使用都发生在同一个 token 存活区间内
  （纯比较、纯读名）。
- **B = NEEDS EXPLICIT OWNERSHIP**：当下正确，但**只是碰巧**——存活靠的是某个
  与本站点无关的第三方 owner（`defineVar` 顺手 dup 出来的 `var_name`、外层的
  一份 dup、scope var 行……），代码本身没有表达这份所有权。改动那个第三方，
  或者调换语句顺序，就会静默破。
- **C = WRONG**：借用跨过了 owner 的释放点，atom 可以在使用点之前 refcount 归零。

对 B 的口径刻意比「能跑就是对」更严：ruling 要的是**契约写在代码里**。
（并行的 codex 独立扫描把本文的多数 B 判成 A，理由是「事实上有 owner」。
两者对事实无分歧，只对「incidental 是否算 B」有分歧；本文采用严口径。）

---

## 3. 站点清单

`fn` 位置按基线 `3d869065` 的行号。六字段缩写：
**src** = atom 来源，**own** = token owner，**rel** = owner 释放点，
**use** = 使用区间，**dup** = 是否 dup，**xfer** = 是否所有权转移。

### 3.1 Class C（借用越过 owner）

#### C-1 `exportDefaultFunctionName` — src/parser.zig:18011（`*` 分支）、18014（普通分支）

1. **src**：本函数自己 `s.lex.next()` 词法分析出来的 lookahead token，`next()` 为
   `.ident` payload 内插了名字。
2. **own**：这个局部 lookahead token（`first` / `second`），parser 的 `s.token`
   完全没参与。
3. **rel**：本函数自己的 `defer s.lex.freeToken(&first)` /
   `defer s.lex.freeToken(&second)`——**在 `return` 表达式求值之后、控制权交回
   调用方之前**。所以返回值在返回的那一刻就已经悬空。
4. **use**：调用方拿到后先跑完整个 `parseFunctionDecl`（连函数体），再传给
   `addModuleExportName` → `Record.addExport` → `atoms.dup(...)`。
5. **dup**：无。
6. **xfer**：无。`Record.addExport`（bytecode.zig:1150）会自己 dup，但它 dup 的
   是一个**已经死掉的 id**，救不了。

**CLASS: C**（已举证，见 §4）

#### C-2 `exportDefaultClassName` — src/parser.zig:18035

与 C-1 同构：同一个 save/restore + `defer freeToken` 形状，返回
`name.payload.ident.atom`；调用方跑完 `parseClass(s, true)` 之后才使用。

**CLASS: C**（已举证，见 §4）

C-1 / C-2 的调用点共 5 处（全部在 `parseExport`）：

| 调用点 | 源码形态 |
|---|---|
| 17796 | `export default class C {}` |
| 17815 | `export default function f() {}` |
| 17828 | `export default async function f() {}` |
| 17961 | `export function f() {}` / `export function* f() {}` |
| 17981 | `export async function f() {}` |

今天之所以不炸，是因为 `parseFunctionDecl` / `parseClass` 的**第一次**内插正好
就是同一个名字：`advance()` 释放的是 `function` / `class` 关键字 token
（predefined atom，`free` 直接 return，不进自由链），紧接着 `lex.next()` 内插名字，
弹出的正是刚被压进去的那个槽。中间只要多一次别的新字符串内插，链头就不是它了。

#### C-3 `parseDeleteSuperReference` — src/parser.zig:8176 —— **形状为 C，但不可达**

1. **src**：`s.token.payload.ident.atom`（当前 token）。
2. **own**：`s.token`。
3. **rel**：紧跟其后的 `try s.advance()`（advance 先 `freeToken(&self.token)`）。
4. **use**：`advance()` 之后的
   `try s.emitOpAtom(opcode.op.push_atom_value, name)` → `appendAtomOperand`
   → `atoms.dup(name)`。
5. **dup**：无（它的两个同族活路径 `parseMemberChain`:8794 和
   `parseNewCalleeMemberAccess`:8748 都 dup 了，只有它漏了）。
6. **xfer**：无。

更糟的是这里连槽位回收的运气都没有：`advance()` 之后内插的下一个 token 是 `(`，
是标点、不内插任何字符串，所以名字的槽位会**一直空着**，`dup` 会直接撞
`hasLiveValue` 断言。

**但是**：`parseDeleteSuperReference` 和 `isDeleteSuperReference` 在整个仓库里
**没有任何调用者**（`grep -rn "DeleteSuperReference" src/` 只有这两个定义行）。
Zig 不会对未被引用的 struct 成员函数做语义分析，所以这段代码既跑不到、也没被
类型检查过。按 ruling 的证据规则，无法演示的危害必须降级：

**CLASS: C-shape / UNREACHABLE**（无法从任何 JS 源码触达；仍按同族活路径的
写法补齐了 owner，理由见 §5.2）

### 3.2 Class B（正确但不是契约）

#### B-1 `identifierLikeAtom` — src/parser.zig:9982

**src** 当前 token / keyword；**own** `s.token`；**rel** 下一次 `advance()`；
**use** 由调用方决定；**dup** 由调用方负责；**xfer** 无。
函数名和签名都没有说「这是借的」。今天所有调用方（`parseVar`:13061、
`parseFunctionDecl`:13692、`parseFunctionExpr`:13750、break/continue label:12083、
enum member:11386、各参数与 pattern 路径）**都**在 `advance()` 之前 dup 了，
所以事实上安全；但这是 12 处调用方各自的自觉，不是这个 helper 的契约。

#### B-2 catch 绑定 — src/parser.zig:12312

**src** 当前 token；**own** `s.token`；**rel** 12331 的 `advance()`；
**use** 12332 的 `emitScopePutVar(catch_atom)`；**dup** 无（本地）；
**xfer** 有——12330 的 `defineVar(catch_atom, .catch_)` 会经
`FunctionDef.appendVar`（bytecode.zig:3300 `atoms.dup(var_def.var_name)`）留下一份
retain，**恰好排在 `advance()` 之前**。
成立完全依赖「defineVar 先于 advance」这个语句顺序 + 「defineVar 会 dup」这个
下游实现细节，本地没有任何 owner。

#### B-3 TS `enum` 名 — src/parser.zig:11359；B-4 TS `namespace` 名 — src/parser.zig:11472

同 B-2 的形状，而且源码里已经用注释写明了意图
（"Acquire the declaration owner before advance releases the token's identifier
retain"）。owner 是 `addScopeVar` 建出来的 var 行；本地依然没有 retain。
派生的 `s.last_declared_atom`（11454 / 11513 / 11541）与
`s.current_namespace_atom`（11498 / 11529）把这个借来的 id 存进 parser state，
读取点在 11507 / 11515 / 13195 / 14672 / 17342，全程靠那一行 var 撑着。

#### B-5 `State.last_class_decl_atom` — src/parser.zig:17155

**src** `classNameAtom(s)` 返回的**借用** id；**own** `s.token`；
**rel** 17156 的 `advance()`；**use** 17976（`export class C {}` 里
`addModuleExportName(s, name_atom, name_atom)`，在 `parseClass` 已经返回之后）；
**dup** 字段本身没有（同一处的 `class_name` 有一份 dup，但它被 `parseClass`
出口的 defer 释放了）；**xfer** 无。
存活链是**两段拼接**的：`parseClass` 内部靠局部 `class_name` 那份 dup，
`parseClass` 返回之后靠类声明绑定的 `var_name` retain。字段自己是纯借用。
探针实测使用点 refcount = 5（§4.3），确认当前活；但这是两个无关 owner 接力的结果。

#### B-6 `State.last_var_decl_atom` — src/parser.zig:13078

只写不读：全仓库只有 4060 的声明、11708 的置 null 和 13078 的赋值，没有任何读取点。
存的是 `parseVar` 那份 owned dup 的 id，而那份 dup 在声明子句结束时就被释放。
今天无害（死字段），但它是一个随时可以被「加一个读取点」变成 class C 的陷阱。

### 3.3 Class A（安全）汇总

下列站点都在 token 释放前建立了独立 owner，或使用完全落在 token 存活区间内，
或拿到的本来就是 predefined / 新内插的 owned atom。

| 站点 | 位置 | 安全理由（六字段要点） |
|---|---|---|
| `keywordAtom` | 191 | 返回 predefined 常量，`free`/`dup` 均为 no-op |
| `LexerImpl.dupToken` | 412 | 明确复制 owner，注释即契约 |
| `forHeadHasNoTopLevelSemicolon` 快照 | 5509 | `dupToken` 独立 owner，defer 交回 |
| `takeParserSnapshot` / `restoreParserLexerSnapshot` | 15748 / 15775 | 同上 |
| lookahead 家族（`checkArrowHead` / `checkAsync*ArrowHead` / `nextRegexpAwareLookaheadToken` / `peekNextKind*`） | 5399-5490, 6875-7030 | 只读 `token.val`，不碰 atom |
| `peekNextIsOfToken` | 5443 | 借用只用于 `atomNameEquals`，在 defer 之前 |
| `isIdent` / `isParameterModifier` | 5581 / 5590 | 当前 token 内的 `name()` 比较 |
| `labelStartAtom` + 12083 break/continue label | 5269 / 12083 | 调用方 advance 前 dup（8c8787cd） |
| 赋值 LHS / primary 标识符 | 7093 / 9304 | advance 前 dup |
| private-name `in` | 7797 | `dup(private_atom)` + defer free |
| `new.target` / `import.meta` / 转义保留字判定 | 8679 / 9206 / 9248-9261 | 当前 token 内的纯比较 |
| `parseNewCalleeMemberAccess` / `parseMemberChain`（点号与可选链） | 8748 / 8794 / 8854 | `retained_name = dup(name)` + defer free |
| `parseObjectPropertyName` | 9810 | `ObjectPropertyName.retained` 标记 owner |
| `awaitUsingDeclarationStart` / `usingDeclarationStart` | 11022-11031 | 扫描 token 内比较 |
| enum member 名 | 11386 | advance 前 dup + defer free |
| `using` / for-of 绑定 / for 声明绑定 | 12421 / 13310 / 13361 | advance 前 dup |
| `parseVar` 简单绑定 | 13061 | advance 前 dup + defer free（qjs js_parse_var） |
| for-head `async of` 判定 | 13385 | 当前 token 内比较 |
| `parseFunctionDecl` / `parseFunctionExpr` 名 | 13692 / 13750 | advance 前 dup + defer free |
| 形参 / rest / arrow 形参 / pattern 绑定 | 13913, 14011, 14792, 14823, 14903, 15256 | `appendOwnedParserAtom` 或 advance 前 dup |
| `PatternTarget.defaultName` | 15105 | 转发已 owned 的绑定名 |
| class 私有存取器 / 私有字段方法 | 16081 / 16129 | `privateNameAtom` 返回 owned |
| `privateSetterAtom` / `newClassPrivateAtom` / 计算字段临时 atom | 16319 / 16704 / 16716 | 新建 symbol，本来就 owned |
| `classNameAtom` 的 `class_name` 用法 | 16357→17153 | advance 前 dup + defer free（qjs js_parse_class） |
| `privateNameAtom` / `privateNameDeclarationAtom` / `findClassPrivateBoundName` | 16668 / 16676 / 16684 | 返回 owned 或列表持有 |
| class 私有名预扫描 | 17037 | `privateNameDeclarationAtom` owned + defer free |
| 模块 default / namespace / named import 名 | 17527 / 17554 / 17592 | advance 前 dup，`*_live` 标志管转移 |
| `moduleStringAtom` / `moduleImportNameAtomOwned` | 17732 / 17744 | 返回 owned（8c8787cd） |
| import attribute key | 18073 | dup + defer free |
| `pending_function_name` / `function_expr_name_binding` / `active_with_atom` / 各 label carrier | 4050 / 14157 / 13246 / 11612 | 存的是外层 owned dup，字段生命周期严格内含于该 dup |
| `current_parameter_properties` / `class_private_elements` / `class_private_bound_names` | 4008 / 16282 / 16647 | 列表自持 retain，`deinitOwnedParserAtoms` 配平 |
| sink：`FunctionDef.appendVar/appendArg/appendGlobalVar/addClosureVar/appendAtomOperand` | bytecode.zig:3300-3370 / 3472 | 一律 `atoms.dup` |
| sink：模块 `Record.add*` | bytecode.zig:1121-1198 | 一律 `atoms.dup`（但救不了已死的输入） |

---

## 4. Class C 可达性举证

工具：`zig build zjs-dev`（Debug，`std.debug.assert` 生效）。

### 4.1 探针：返回值在返回时就已经死了

在 `parseExport` 的调用点插入临时探针，打印
`atoms.refCount(atom)` 与 `atoms.name(atom)`（探针不入库）：

```
$ ./zig-out/bin/zjs-dev /tmp/expdef.mjs        # export default function zzqqUniqueDefaultFn(){}
[borrow-probe] exportDefaultFunctionName/return:    atom=710 refcount=null name=null
[borrow-probe] exportDefaultFunctionName/afterParse: atom=710 refcount=2    name=zzqqUniqueDefaultFn
```

`refcount=null` / `name=null` 表示条目已 `finalizeDeadEntry`：bytes 已释放、
已从 `string_index` 摘除、槽位已在自由链上。第二行说明它是被
`parseFunctionDecl` 重新内插同名字符串**取回**的。四个调用形态（`export default
function` / `export default class` / `export function` / `export async function`）
的返回时刻全部 `refcount=null`。

### 4.2 扰动：中间插一次别的内插，运气就没了

同一个探针构建里，在 helper 返回之后、`parseFunctionDecl` 之前多内插一个字符串
（`__zjs_borrow_wedge__`，env 开关控制）：

```
$ ZJS_BORROW_WEDGE=1 ./zig-out/bin/zjs-dev /tmp/expdef.mjs
[borrow-probe] exportDefaultFunctionName/return:     atom=710 refcount=null name=null
[borrow-probe] wedge interned atom=710
[borrow-probe] exportDefaultFunctionName/afterParse: atom=710 refcount=1 name=__zjs_borrow_wedge__
SyntaxError: SYNTAX ERROR in /tmp/expdef.mjs:2:1 - UnexpectedToken
```

atom 710 被 wedge 抢走并**改绑到另一个字符串**；`addModuleExportName` 于是把
`export default` 的 local name 记成 `__zjs_borrow_wedge__`，
`validateModuleLocalExports` 找不到该绑定，一个完全合法的模块被判成语法错误。
`export default class` / `export function` / `export async function` 三个形态
结果相同。

### 4.3 对照：`export class C {}` 走的 `last_class_decl_atom` 路径不受影响

```
[borrow-probe] lastClassDeclAtom/afterParseClass: atom=710 refcount=5 name=ZzqqUniqueExpCls
[borrow-probe] lastClassDeclAtom/afterWedge:      atom=710 refcount=5 name=ZzqqUniqueExpCls   (wedge 拿到 atom=712)
```

使用点 refcount=5，wedge 拿不到它的槽位。这条是 B-5，不是 C。

### 4.4 全局探测器：延后一拍的槽位回收

> 审计当时是临时补丁；现已产品化为 build option `-Dzjs_ownership_audit`，
> 见 §7。

为了不止于「已知嫌疑人」，给 `AtomTable` 加了一个**一格隔离区**（审计当时是
临时补丁，不入库）：刚死的槽位先进隔离区，等下一次有别的槽位死掉才进自由链。这样
「释放后立刻重新内插同一个字符串」再也拿不回自己的 id，任何 borrowed-atom
use-after-free 都会撞 `dup` 的 `hasLiveValue` 断言。相对完全关闭回收，这个改法
不改变表的规模，不影响 teardown 不变量。

修复前，探测器在**已入库的单元测试**里就直接命中：

```
src/core/atom.zig: std.debug.assert(entry.hasLiveValue());   in dup
src/bytecode.zig:1151                                        in addExport
src/parser.zig:17651                                         in addModuleExportName
src/parser.zig:17963                                         in parseExport
src/tests/parser.zig:4814  test "W5: generator parameter boundary ..."
    parseModuleStatement(&env, "export function* g(x = 1) { yield x; }")
```

`export default class` 形态在探测器下不是 panic 而是**静默错值**：stale id 被
隔离区放行后复用给了别的字符串，于是合法模块直接报
`SyntaxError: UnexpectedToken`。

修复后，同一个探测器构建：

- `zig build test`：**2064 passed / 0 failed**。
- 定制语料（delete-super、成员访问、私有名、全部声明形态、5 种 export 形态、
  generator/async/arrow/static-block）：全绿。
- test262 子树（Debug runner + 探测器）：`language/module-code` 599、
  `language/statements` 9337、`language/expressions/class` 4059、`language/import` 127、
  `language/function-code` 217、`language/identifiers` 268、`language/export` 3，
  合计 **14611 个用例，0 errors**。

### 4.5 一个必须记下的负面结论

Debug 版 test262 runner 跑全量 49775 用例时会在约 7000 个用例处撞
`src/core/runtime.zig:1294 assert(self.memory.allocation_count == 1)`。
这是**既有问题、与本审计无关**：把探测器补丁完全撤掉、用纯净 `3d869065`
重建 `run-test262-dev` 复跑，崩在同一处同一进度。因此 §4.4 的 test262 覆盖
按子树切分执行，而不是全量一次跑完。（正式 `test262-gate` 走 ReleaseFast
runner，断言本就编译掉了，对本审计不提供证据。）

---

## 5. 修复（只动 class C）

### 5.1 `export default` / `export` 名字 lookahead

`exportDefaultFunctionName` → `exportDefaultFunctionNameOwned`，
`exportDefaultClassName` → `exportDefaultClassNameOwned`：在 `return` 表达式里
`s.function.atoms.dup(...)`。Zig 的 `return expr` 先求值再跑 defer，所以 dup
发生在 token 释放之前。5 个调用点各自 `defer s.function.atoms.free(name_atom)`。

命名与 `8c8787cd` 引入的 `moduleImportNameAtomOwned` 一致：`*Owned` 后缀即
「调用方负责释放」的契约。

### 5.2 `parseDeleteSuperReference`（不可达）

按其两个活的同族路径（`parseMemberChain`、`parseNewCalleeMemberAccess`）补上
`const retained_name = s.function.atoms.dup(name); defer ...free(retained_name);`，
发射点改用 `retained_name`。因为 Zig 不分析无引用函数，这段修改用一次性
`comptime { _ = &parseDeleteSuperReference; }` 强制编译验证过后再移除。

**没有**在本次提交里删除这两个死函数——删死代码是另一件事，不属于所有权账本。

### 5.3 为什么本次提交没有附带回归测试

这个 bug 的观测前提就是打破槽位回收的运气，而 §3.1 已经论证：在当前解析顺序下，
`exportDefault*Name` 释放名字之后、`parseFunctionDecl` / `parseClass` 重新内插
同名字符串之前，**不存在任何可由 JS 源码控制的插入点**（中间只有 predefined
关键字 token 的 no-op `free`）。因此写不出一个「修复前红、修复后绿」的黑盒
回归测试；`8c8787cd` 那种 atom-table 收支平衡断言在修复前也是平的
（死 atom 被同名重内插取回后，`addExport` 的 dup 与 record 的 free 依然配平）。

能持续守住这条不变量的唯一办法是把 §4.4 的探测器产品化——现已落地为
`-Dzjs_ownership_audit`，见 §7；§7.4 给出「撤销本次修复 → 审计构建当场 panic」
的复现步骤，那就是这条修复的回归测试形态（黑盒仍然写不出来）。
在那之前，本条修复由 §4.1/§4.2 的一次性探针实验和 §4.4 的探测器全绿背书。

运行期探测器只在「测试恰好跑到那条路径」时才说话。把源码形态本身禁掉的那一半
在 §8：`tools/architecture/check_borrowed_atoms.js`。两半合起来才是这个 bug 类
可用的「回归测试」替代品。

---

## 6. 遗留项（follow-up，不在本次提交范围）

按 ruling，class B 只在「小且显然正确」时就地转正。下面几条都不满足该条件，
或者会牵动无关子系统，因此登记为 follow-up：

1. **B-5 `last_class_decl_atom` 转为 owned 字段**。需要在赋值处释放旧值、在
   `State.deinit` 释放残值，触碰 parser 生命周期收尾路径。建议与「`parseClass`
   直接返回类名 owner、取消这个跨函数状态字段」一起做。
2. **B-6 `last_var_decl_atom` 删除**。只写不读的死字段，删掉即可，但属于清理
   而非所有权修复。
3. **B-1 `identifierLikeAtom` 契约显式化**。低风险改名为
   `identifierLikeAtomBorrowed` + 文档注释，并可补一个 `...Owned` 伴生函数。
   涉及 12 处调用点的机械改名，单独一刀更干净。
4. **B-2 / B-3 / B-4 本地化 owner**。catch 绑定、TS enum、TS namespace 都改成
   「先 `dup` + `defer free`，再 `defineVar` / `addScopeVar`」，把存活从
   「下游 sink 顺手 dup」变成本地契约。TS 两条还牵连
   `last_declared_atom` / `current_namespace_atom` 两个 state 字段，一起改才闭合。
5. **死代码 `isDeleteSuperReference` / `parseDeleteSuperReference`**：无调用者，
   Zig 也不做语义分析。要么接进 `delete` 解析路径，要么删除。
6. ~~**可考虑把 §4.4 的隔离区探测器做成 build option**，让「借用越过 owner」
   在 CI 里可持续检出，而不是只在人工审计时临时打补丁。~~
   **已落地**：`-Dzjs_ownership_audit`，见 §7。

上面 1-4 条现在**不再只写在这份文档里**：它们每一条都对应
`tools/architecture/borrowed-atoms-allowlist.json` 的一条 entry，
带 `reason` 与 `exit_milestone`（milestone 文字直接引用本节编号）。
做完某一条就删掉对应 entry；不删的话 checker 会因为 entry 变 stale 而报红，
所以「改完忘了销账」和「悄悄新增一个同形态站点」都会被门禁拦住。见 §8。

---

## 7. 审计构建 `-Dzjs_ownership_audit`（§4.4 探测器的产品化形态）

落地 commit 见本文件所在提交；实现在 `src/core/atom.zig`
（`AtomTable.OwnershipAuditState` + `finalizeDeadEntry` 的回收臂），
选项在 `build.zig`，与 `zjs_force_gc` / `zjs_nan_boxing` 走同一套 option 分发
（`engine_options` / `plugin_fixture_options` / `profile_engine_options` /
`test_options`）。

### 7.1 它做什么

`finalizeDeadEntry` 释放的槽位先在**一格隔离区**里待一轮，等下一个槽位死掉才
进自由链。于是「free 掉一个 atom，紧接着重新内插同一个字符串」再也拿不回同一个
id，§1.1 情形 1 的「靠槽位回收的运气」被拆掉：一个借用越过 owner 的 stale id
要么指向空槽（`dup` 撞 `hasLiveValue`，Debug / ReleaseSafe 直接 panic），
要么在再下一次内插之后指向别的字符串（错值，由调用方自己的检查暴露）。

**为什么是「一格」而不是「彻底关掉回收」**（这条写进了代码注释）：回收只是被
推迟一次死亡，表的稳态规模只多出那一个被隔离的槽——`entries` 数量、`next_id`
增长、`deinit` 的收尾不变量都还是默认构建的那一套。彻底关掉回收会让表随
intern/free churn 单调增长，审计本身就可能把一个高 churn 的测试变成 OOM 或
另一种表几何下的失败，那样查出来的东西就不可信了。

`src/tests/core.zig` 里配了一条 liveness 自检
（`ownership audit quarantines the most recently freed atom slot`）：审计关时
`SkipZigTest`，审计开时断言「刚死的槽位不会被下一次 intern 拿走，但在再死一个
槽位之后会被回收」。把隔离区改回直接压链，这条测试当场红。没有它，审计档位可以
被改瘸而每次 CI 还是全绿——那正是这个选项要消灭的那种静默。

### 7.2 档位：ASAN / leak-checker 那一档

CI、fuzzing、回归复现专用。**默认关，永远不进 ReleaseFast，不进生产路径。**
关闭时整套机制 comptime 消失：`OwnershipAuditState` 退化成空结构体，字段、
代码、连名字都不进二进制。

零生产代价的实测（2026-08-02，本树，`zig build zjs` 默认 ReleaseFast）：

- `nm -a zig-out/bin/zjs | grep -i quarantin` 与
  `strings -a zig-out/bin/zjs | grep -i quarantin` 均 0 命中
  （二进制里只留下 build_options blob 里的选项名本身，和 `zjs_force_gc` 一样）；
- 默认二进制的 `.text` 与「只往 `atom.zig` 加一行注释」的空对照构建**逐字节
  相同**（`44c58c48…`，3851804 B），即本改动对默认构建的机器码零影响；整个
  二进制的 sha 只差在 build_options 与调试信息上。（对照是必要的：任何一次
  touch `atom.zig` 的重建都会相对冷构建产生一次布局位移，不做对照会把布局
  彩票误读成代价。）
- `tools/perf/codeload/run_codeload_micro.py --a <空对照> --b <本改动>
  --samples 8 --cpu 19`：compile 模式 instructions median **1.00000**
  MAD 0.00000（23,102,180,030 → 23,102,190,161）；atom 模式（专测 intern
  miss + free-slot churn）instructions median **1.00000** MAD 0.00000
  （24,351,531,576 → 24,351,501,514）。

### 7.3 怎么跑

```bash
zig build test        --summary all -Dzjs_ownership_audit=true   # 统一套件
zig build test-parser               -Dzjs_ownership_audit=true   # 单子树，失败定位更快
zig build test-oom    --summary all -Dzjs_ownership_audit=true
zig build zjs-dev                            -Dzjs_ownership_audit=true   # 手工语料复现
zig build run-test262-dev                    -Dzjs_ownership_audit=true   # test262 子树
./zig-out/bin/run-test262-dev -c test262.conf -d test262/test/language/module-code
```

断言只在 Debug / ReleaseSafe 生效（`std.debug.assert`）。在 ReleaseFast 下打开
这个选项没有意义：`dup` 的断言被编译掉，隔离区只会白白改变槽位分配顺序。

**test262 请按子树跑，不要一次跑全量。** Debug runner 在约 7000 个用例处会撞
`src/core/runtime.zig:1294` 的
`std.debug.assert(self.memory.allocation_count == 1)`。这是**既有问题、与本
审计无关**：把审计补丁完全撤掉、用纯净 `3d869065` 重建 `run-test262-dev` 复跑，
崩在同一处、同一进度（§4.5）。所以按 `-d test262/test/language/<子树>` 分段
执行——§4.4 那 14611 个用例就是这么跑出来的。

### 7.4 它抓得住原始缺陷（可复现）

把 `ada949be` 的 parser hunk 在工作区里临时撤销：

```bash
git show ada949be -- src/parser.zig | git apply -R --3way
# exportDefaultClassName 一处会与 1906d45c（lexer 位置恢复先于可失败 peek）
# 冲突：保留 1906d45c 的顺序，只把 dup 撤掉。
```

然后：

- `zig build test-parser --seed 0`（审计**关**）→ **474 passed / 0 failed**。
  这正是 §5.3 说的掩蔽：黑盒测试看不见这个 use-after-free。
- `zig build test-parser --seed 0 -Dzjs_ownership_audit=true` → SIGABRT：

```
thread panic: reached unreachable code
src/core/atom.zig:1069:29         in dup    std.debug.assert(entry.hasLiveValue());
src/bytecode.zig:1151:53          in addExport
src/parser.zig:17651:25           in addModuleExportName
src/parser.zig:17963:58           in parseExport
src/tests/parser.zig:4814:42      in test.W5: generator parameter boundary emits
                                     initial_yield in scripts and modules
    var module = try parseModuleStatement(&env, "export function* g(x = 1) { yield x; }");
```

`git checkout -- src/parser.zig` 恢复之后（即当前 main），同一条命令全绿。
这就是这个 bug 类唯一可用的「红 → 绿」形态：不是黑盒回归测试，而是**已有测试
在审计档位下的行为差**。

---

## 8. 静态规则 `check_borrowed_atoms.js`（把「借用外逃」的源码形态禁掉）

落地位置：`tools/architecture/check_borrowed_atoms.js` +
`tools/architecture/borrowed-atoms-allowlist.json`，挂在
`checkpoint-check` 和 `engine-production-gate` 上（与 `check_deps.js` /
`check_oom_panics.js` 同一层，同一套 allowlist 形状）。扫描范围
`src/**.zig`（不含 `src/tests/`）。

### 8.1 为什么需要它——它和 §7 各管一半

§5.3 论证了黑盒回归测试写不出来。剩下的两个手段各自只覆盖一半：

| | `-Dzjs_ownership_audit`（§7） | `check_borrowed_atoms.js`（本节） |
|---|---|---|
| 生效时机 | 运行时 | 评审 / CI 静态 |
| 判据 | 槽位隔离一拍后，stale id 撞 `dup` 的 `hasLiveValue` 断言或读到错值 | 源码形态：借来的 atom 逃出 token 生命期 |
| 抓得住 | 真正被执行到的越界借用，包括本文没想到的路径 | 一切新写出来的同形态代码，哪怕当前无测试覆盖 |
| 抓不住 | 没有测试覆盖的路径；ReleaseFast（断言被编译掉）；不可达代码（如 C-3） | 运行期才成立的所有权（第三方 sink 顺手 dup），跨函数/跨文件传播，见 §8.6 |

`ada949be` 的 class C 正是「静态一眼可见、运行时靠运气看不见」的形状：
`return <token>.payload.ident.atom` 加上函数出口的 `defer freeToken`。
所以这条规则的第一性目标就是**让这个形状永远编不过门禁**。

### 8.2 规则本体

**borrowed atom** 的三种来源：

1. `<token>.payload.<field>.atom` 且处于**值位置**——
   `atomNameEquals(s, s.token.payload.ident.atom, "of")` 这种**实参位置**的读
   是在 token 存活区间内消费掉的，不算借用（34 处 token-atom 读因此收敛到
   10 处真借用，这是精度的主要来源）；`@as` / `@intCast` 这类 builtin 是透明的，
   扫描会穿过去；
2. 同文件内「自己就返回借用 atom」的 helper 的返回值——helper 集合按定点迭代
   算出，当前是 `identifierLikeAtom` / `classNameAtom` / `labelStartAtom`；
3. 绑定（`const` / `var`）或重新赋值（`nm = ...`）到上面两者的局部变量；
   `const` 声明还会做一层局部传染（`const name = private_atom orelse raw_name;`）。
   传染只走**保值表达式**：`const hit = nm == other;` 产出的是 bool，不是 atom，
   顶层出现比较 / 布尔运算就断链。重新绑定到 owned 值（`nm = atoms.dup(nm);`）
   会**关掉**这个借用点的窗口。

所有权是**按位置**判定的，不是「这条语句里出现过 `dup`」：`.dup(x)` 把 `x` 放进
实参位置，所以「duped 的读」压根就不是借用读。于是
`return if (c) atoms.dup(a) else t.payload.ident.atom;` 里的 else 臂照样报红——
整句粒度的「含有 dup 就放行」会漏掉它。

**四条 escape 规则**（一个借用点只报一次，取优先级最高的那条）：

| pattern | 禁止的形状 |
|---|---|
| `borrowed-return` | 把借来的 atom `return` 出去（= `ada949be` 那个 bug） |
| `borrowed-state-store` | 把借来的 atom 存进 `State` 的长命 atom 字段（字段活得比 token 长） |
| `borrowed-use-after-release` | 在同一函数内、非 `defer` 的 `advance()` / `freeToken()` 之后再读它 |
| `owned-escape-state-store` | 把「只由 `defer ...free(x)` 持有」的局部存进本函数不会 restore 的长命 atom 字段（= B-6 那个形状） |

「长命 atom 字段」不是硬编码列表：checker 从结构体作用域扫出所有
`Atom` / `?Atom` 字段名（跳过函数体，所以多行参数表不会被当成字段），
再要求接收者是本函数签名里绑定到 `*State` 的那个名字。于是以后新增一个同类
字段当天就自动被覆盖，而隔壁结构体自己的 `self.<atom 字段>` 不会被误判。

**三种合法写法**（推荐顺序）：

1. 在逃逸表达式里当场取所有权：`.dup(` / `.internString(` / `.newSymbol(` /
   调用某个 `*Owned(`；
2. 函数名以 `Owned` 结尾（既有约定：`moduleImportNameAtomOwned`、
   `exportDefaultFunctionNameOwned`）——**只豁免 `borrowed-return`**，
   且只豁免「转发别人的借用」（helper 结果 / 传染来的局部，静态证不了），
   **永远不豁免直接返回 token payload 读**，因为那就是 `ada949be` 本身；
   而且函数体必须真的产出过 owner，否则后缀是空头支票（实测见 §8.4）；
3. 在该行正上方写 `// borrowed-atom: <理由>`。理由不能为空——写不出理由，
   说明契约本来就不存在。rule A / B 只认**逃逸那一行**上方的标记；
   rule C 额外允许写在借用那一行上方（借用点才是说明「这次借用是故意的」
   的自然位置）。

**allowlist**：字段 `source` / `pattern` / `reason` / `exit_milestone`，
外加可选的 `fn`（所在函数）与 `contains`（语句子串）选择器。
每条 entry 必须恰好命中一条 finding；命不中即 stale 报红，命中多条即
non-unique 报红，两条 entry 抢同一条 finding 即 overlapping 报红。
上限 16 条，当前 14 条。

### 8.3 当前 14 条 = 本文 class B 的机器可读形态

```
src/parser.zig:5273   borrowed-return             labelStartAtom
src/parser.zig:7093   borrowed-use-after-release  parseAssignExpr2
src/parser.zig:9988   borrowed-return             identifierLikeAtom                 <- B-1
src/parser.zig:11364  borrowed-state-store        parseEnumDeclaration               <- B-3
src/parser.zig:11477  borrowed-state-store        parseNamespaceDeclarationWithIdent <- B-4
src/parser.zig:12316  borrowed-use-after-release  parseStatementOrDeclSlow           <- B-2
src/parser.zig:12426  borrowed-state-store        parseUsingDeclaration
src/parser.zig:13083  owned-escape-state-store    parseVar                           <- B-6
src/parser.zig:13366  borrowed-use-after-release  parseForInOf
src/parser.zig:13699  owned-escape-state-store    parseFunctionDecl
src/parser.zig:13918  borrowed-use-after-release  parseFunctionParameters
src/parser.zig:14828  borrowed-use-after-release  parseArrowFunction
src/parser.zig:16362  borrowed-return             classNameAtom                      <- B-5 根因
src/parser.zig:17156  borrowed-state-store        parseClass                         <- B-5 字段
```

7 条直接落在本文 B-1…B-6 上。**另外 7 条落在 §3.3 的 class A 表里**，这不是
误报，是本文那几行的判定口径不一致：那些行的安全理由写的是「调用方 advance 前
dup」「`appendOwnedParserAtom` / `defineVar` 会 dup」——即 owner 在**别处**，
而 §2 对 class B 的定义正是「存活靠与本站点无关的第三方 owner」。逐条复核过
（每条 allowlist entry 的 `reason` 写明了那个第三方 owner 是谁）：

- `labelStartAtom` 转发 `identifierLikeAtom` 的借用 → 与 B-1 同形；
- `parseAssignExpr2` 的 `direct_lhs_atom` 在 `parseCondExpr` 消费掉 token 之后
  仍被用于匿名函数命名，靠 `emitScopeGetVar` 发射出的 atom operand、以及
  direct lvalue 那份 `LValue.name`（`owns_name = true`）撑着；
- `parseUsingDeclaration` / `parseForInOf` / `parseFunctionParameters` /
  `parseArrowFunction` 四处都是「先让 `defineVar` 或 `appendOwnedParserAtom`
  建 owner，再 `advance()`，然后继续用借来的 id」——与 B-2 catch 绑定逐字同形；
- `parseFunctionDecl` 的 `s.last_declared_atom = name_atom` 与 B-6 同形
  （dup 被本函数出口的 defer 释放，字段却留着那个 id；之后的 owner 是声明
  var 行与 `FunctionDef.init` 的 `func_name` dup）。

结论：这 7 条按本文严口径本就该是 B，登记为 follow-up（§6）而不是违规，
与 ruling 一致。**没有任何一条 finding 落在真正安全的 class A 站点上**
（`dupToken` 系列快照、纯比较、predefined、`privateNameAtom` 这类返回 owned 的
helper、`parseMemberChain` / `parseNewCalleeMemberAccess` 的 `retained_name`
形态、以及 `*Owned` 三兄弟全部零命中）。

### 8.4 精度与强度实测

**(1) 它抓得住原始缺陷。** 在工作区里临时重建 `ada949be` 之前的形状
（`exportDefaultClassNameOwned` 改回 `exportDefaultClassName`，去掉 `return`
里的 `dup`）：

```
Borrowed-atom rule violations:
  src/parser.zig:18063: in exportDefaultClassName: return if (name.val == tok.TOK_IDENT) name.payload.ident.atom else null;
    rule A: a borrowed atom must not be returned (dup it, or name the function ...Owned)
```

`git checkout -- src/parser.zig` 之后重新全绿。

**(2) 合成精度矩阵**（`/tmp` 上的临时 `.zig`，不入库；16 例全部符合预期）：

| 形态 | 期望 | 实测 |
|---|---|---|
| pre-fix class-C return | 红 | 红 |
| `return dup(t.payload.ident.atom)` | 绿 | 绿 |
| 实参位置的读（`atomNameEquals(...)`） | 绿 | 绿 |
| Zig 多行字符串 `\\` 里的假样本 | 绿 | 绿（起初是误报，`stripCode` 整行丢弃才修掉） |
| 注释掉的逃逸 | 绿 | 绿 |
| `advance()` 之后再读借来的局部 | 红 | 红 |
| `// borrowed-atom:` 标记 | 绿 | 绿 |
| **混合分支** `return if (c) dup(a) else t.payload...;` | 红 | 红（整句粒度的 owned 判定会漏，改成按位置判定后修掉） |
| **`Owned` 后缀 + 无关的 dup** | 红 | 红（后缀不豁免直接的 token payload 读） |
| `return @as(Atom, t.payload...)` | 红 | 红（builtin 透明） |
| `var nm: Atom = undefined; nm = t.payload...; return nm;` | 红 | 红 |
| `const hit = nm == other;` 之后用 `hit` | 绿 | 绿（比较结果不是 atom） |
| 多行 `defer { freeToken(&t); }` 当成行内释放点 | 绿 | 绿 |
| `nm = atoms.dup(nm);` 之后再用 | 绿 | 绿（owned 重绑定关掉借用窗口） |
| 单行函数 `fn nothing() void {}` 吃掉下一个函数的体 | 绿 | 绿 |
| 非 State 结构体自己的 `self.<atom 字段> = ...` | 绿 | 绿 |

规模数据（当前 main）：152 个 Zig 文件 / 9187 个函数扫描，
34 处 token-atom 读、其中 10 处在值位置，26 个借用点被跟踪，
14 条 escape，14 条全部 allowlisted，0 条违规。两次运行输出逐字节一致。

### 8.5 怎么跑

```bash
mise run checkpoint-check                                # 门禁（含本规则）
node tools/architecture/check_borrowed_atoms.js          # 只跑这一条
node tools/architecture/check_borrowed_atoms.js --list   # 逐条列出 finding + 借用 helper 集合
```

### 8.6 它抓不到什么（诚实清单）

- **参数上的借用**：只跟踪函数体内的绑定。`fn f(s: *State, name: Atom)` 把借来的
  `name` 存进长命字段、或包进返回的结构体，都不会被抓——
  `definePatternBindingAtom` 正是这个形状（它把借来的名字包进
  `PatternTarget.direct_binding.name` 返回；今天靠 `defineVar` 建的 var 行撑着）。
  连带的后果：把借用当**实参**交给这种包装函数之后，返回值不再被视为借用。
- **跨文件传播**：借用 helper 集合按文件内定点迭代算，不跨文件、不跨结构体。
  今天够用（token payload 只在 `src/parser.zig` 里读），换布局要重新评估。
- **释放点只认字面量**：`advance()` / `freeToken()`。`expectToken` 之类**内部会
  advance** 的 helper 不算释放点（不做跨函数摘要），也不做路径敏感分析——
  一个只在某个分支上执行的 `advance()` 对本函数所有后续行都算释放。
- **块头截断**：多行 `return .{ ... }` / `return switch (...) {` 的返回表达式在
  `{` 处断句，纯转发包装会漏。这是为精度付的价：宁可漏一个转发层，也不把整个
  switch 体当成一条 return 表达式去猜。
- **`Owned` 后缀的强度有限**：能挡「函数体里根本没有 owner」和「直接返回 token
  payload 读」，挡不住「dup 了另一个 atom，再转发一个借来的 helper 结果」。
- **运行期才成立的所有权**：sink 是否 dup、第三方 owner 活多久，静态看不出来。
  这正是 allowlist 每条都必须写 `reason`（谁在持有）和 `exit_milestone`
  （怎么把它变成本地契约）的原因。
- **`test` / `comptime` 块不是函数体**，里面的代码不参与分析；扫描范围也不含
  `src/tests/`。
