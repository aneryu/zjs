# JSValue 与 GC 边界设计

Status: **设计草案，未实施**。基于 2026-09-23 工作区源码核对；工作区包含未提交修改，不代表某个已发布版本。

本草案收敛值表示、根、借用和槽位访问的目标协议。它不替代
[VM 值表示契约](vm-value-representation-contract.md)、[GC 不变量](gc-invariants.md)
或[公开 API 契约](public-api-contract.md)。实施前先更新受影响的权威契约；文档版号、编码修订与 ABI 变化分别判断。
这里的接口名称和签名是设计示意，不是可执行示例，也不是现有公开 API。

## 1. 所有者与完整目标

Runtime 继续拥有根集合、GC 和安全点策略。JSValue 不拥有 Runtime，也不登记根。

| 层 | 目标责任 | 不承担 |
| --- | --- | --- |
| JSValue | 8 字节编码、tag、立即值解码、堆引用提取 | 分配、隐式 GC、保活、语言级转换 |
| 堆布局层 | 堆引用与具体载体的转换、元数据访问 | 根登记、自动保活 |
| 根与 handle | 活引用登记、实际槽位更新、作用域管理 | 对象语义与内容转换 |
| 借用读取 | 在有效窗口内读取对象体、limbs、字符串数据 | 跨潜在 GC 点保留旧地址 |
| 字段写入 | 屏障、初始化与发布、批量安装协议 | 自动创建长期宿主根 |
| 收集器 | 遍历、标记、回收；移动模式下搬迁与引用修复 | JavaScript 类型转换 |

保留 NaN-boxing、当前 tag 编码、short BigInt 和 VM 内部 kind。
不引入引用计数，不在每个值中增加 Runtime 或 handle 指针，不默认开启 nursery。
宿主边界提取仍由[宿主设计](host-boundary-design.md)负责。

## 2. 当前状态与迁移裁决

以下是源码事实及目标差异，不能当成已复现的缺陷清单。

| 当前事实与源码 | 裁决 |
| --- | --- |
| [value.zig](../src/core/value.zig)：JSValue 为 bits: u64，8 字节 | 保留编码；给纯编码操作明确无分配、无 GC 契约 |
| cycleMarkHeader / isTracerOwned | 目标命名 heapReference / isHeapReference；迁移期保留转发入口 |
| withTracedHeader 保留 tag、更换 payload | 保留能力，收敛到收集器内部的 relocation 适配；只能替换为同一实体的合法新位置 |
| asInt64 / asUint64 读取堆 BigInt，无分配 | 属于借用读取，不因读堆就要求 Runtime 参数 |
| asStringBody 经 flattenInfallible 物化 rope | 分离 flat 投影与可失败物化；不能机械更名并保留隐藏分配 |
| [string.zig](../src/core/string.zig)：flattenInfallible 在 OOM 时尝试 GC，重试失败 panic | 显式物化路径传播错误；迁移调用者时保留语言语义与 OOM 处理责任 |
| [gc.zig](../src/core/gc.zig)：Header 别名 TraceHeader，载体并不都能读链接字段 | 引入轻量 HeapRef 表示；具体字段访问留在布局层 |
| [gc_roots.zig](../src/core/gc_roots.zig)：value 接收实际槽位；constValue 访问局部副本 | 保留真实槽位；副本访问改为明确的稳定地址边或迁移为原槽位 |
| stringSlot / stringField 装箱后写回原字段 | 保留回写适配，前提是底层字段在访问期间有效 |
| [runtime.zig](../src/runtime.zig)：root slices 的 cells 分支访问 valueRef 的临时副本；[var_ref.zig](../src/core/var_ref.zig) 的 valueRef 装箱的是 VarRef 自身 header | 当前是 cell 身份边，不是 cell.value；保留身份并选择 typed cell 槽位或明确稳定地址策略 |
| [gc_visit.zig](../src/core/gc_visit.zig)：CellSlot 可回写带 tag 的存储地址 | 保留；区分位置、地址与 tag，不替换为按值访问 |
| gc_visit.call 对缺失 visitor 方法直接返回；已有 Edges / assertClassified 做字段分类检查 | 保留字段分类检查，补生产 visitor 完整性和 manual 边回写检查；不能把已有分类能力当成不存在 |
| [roots.zig](../src/core/roots.zig)：LocalHandle、persistent、RootSlot 已存在 | 沿用存储和所有者，不建立平行 handle 系统 |
| [string_ops.zig](../src/exec/string_ops.zig)：部分路径先取切片，再物化其他字符串 | 审计借用窗口；默认模式风险与移动模式风险分别验证 |

## 3. V1：值操作与调用契约

### 3.1 三类操作

1. **编码操作**：只读写值字，不读取堆，不分配，不触发 GC。保留在 value.zig。
2. **借用读取**：允许读堆，但不分配、不触发 GC。放在对应类型或值操作模块。
3. **物化／转换**：明确错误出口、根保护和潜在 GC 点。放在对应操作层。

位相等、表示身份与 SameValue / SameValueZero 不是同一操作。
移动语义比较函数只改变归属，不能改成位比较；字符串、NaN、正负零和两种 BigInt 表示必须保持原语义。
即使某个语义比较可以无分配执行，也不因此归入纯编码层。

HeapRef 的目标表示是指向 opaque HeapCell 的指针，初期沿用当前统一 header 地址，无额外间接寻址。
编码解码只证明 tag 类别，不证明目标已发布、地址属于活分配或属于当前 Runtime。
可信内部路径与宿主输入验证必须分开；验证放在对应信任边界，不给每个纯解码增加堆查找。
替换 payload 必须保留 tag，并验证目标地址满足现有编码范围、对齐及载体约束，不能静默截断地址。

### 3.2 参数、根引用与结果交接

按值参数仍然允许。可能 GC 的 callee 必须在首个潜在 GC 点之前登记其后续还需要的参数，
此后只从可更新的根读取；也可直接接收 caller 提供的根引用。

目标 RootedValueRef 借用现有根中的 `*const JSValue`；const 限制 callee 写入，GC 仍通过根系统的可写引用更新该槽位。
MutableRootedValueRef 经根写入入口更新值。两者不分配、不拥有根、不延长根寿命。
仅由活跃根帧／handle 导出，不公开任意指针构造器。Zig 没有完整借用证明：
内部模块约束、调用审查及 Debug 的 Runtime／作用域检查仍然必要；不能先解引用失效槽位再检查其有效性。

普通函数可以返回 JSValue，但必须满足交接窗口：

- callee 最后一次可能 GC 的操作之后，结果一直有效。
- 结果撤根至函数返回之间的 defer／清理不能触发 GC。
- caller 在下一个潜在 GC 点之前，直接将结果安装到已登记根或合法堆字段。
- 登记根所需的原生分配若会调用可重入通知，也属于待审计边界，不能因为叫 native 就忽略。

输出根用于调用链需要明确结果所有者的场景，不强制替代所有返回值。
目标 takeInto(destination_root) 先安装目标根，再撤销源 persistent；失败时源根仍有效。
现有 take / get 保留兼容契约：get 是快照，take 撤销源根，都不承诺原始值无限期保活。

### 3.3 借用与物化

asFlat(value) 只投影已是 flat string 的值；ensureFlat(rt, input_root, output_root)
可能分配／GC，失败传播 OOM，成功后输出根持有 flat string。
输出根必须事先登记；失败时输出值不变、输入仍有效；内部允许保持语义等价的缓存变化，
不承诺所有内部字节回滚。允许输入输出别名，但必须在覆盖前完成必要读取和提交准备。

顺序：保护输入 → 完成转换与物化 → 从根重新解码 → 取得切片 → 无 GC 地消费。
需要 JS 回调时结束借用，回调后重新获取地址并重新检查可变状态。
根保证存活；pin 才能额外保证规定窗口内的地址稳定。ArrayBuffer 等可变／可分离存储还受自身失效规则约束。

分配能力与 GC 能力分别描述。原生分配可失败而不 GC；没有 error union 也不能证明不 GC。
Debug 禁止 GC 窗口必须在实际 GC 入口检查，不能靠跳过回收来通过。
作用域激活后不能移动自身：现有 ValueRootScope 已按最终栈地址显式 activate，这一约束继续保留。

## 4. V3：完整的追踪与更新协议

### 4.1 边的分类

| 边 | 目标接口示意 | 义务 |
| --- | --- | --- |
| 可更新强值 | valueSlot(*JSValue) | 访问真实持有位置，搬迁后回写 |
| 可更新强对象 | objectSlot(*?*Object) | typed slot 适配，不假设所有 body 与 Header 同址 |
| 可更新存储 | storageCell(CellSlot) | 保留 tag 与布局偏移，修复 owner 中的指针 |
| 地址稳定强边 | pinnedReference(HeapRef) | 本轮保活且禁止改变目标地址；有明确作用窗口 |
| ID 强边 | atomId(Atom) | 跟随身份表保活，移动时由表维护目标位置 |
| 弱引用／ephemeron | 独立弱处理协议 | 不当普通强边；身份与清理顺序由收集器维护 |

borrowed 与 const 都不能自动推导出“无需保活”或“不能搬迁”。
Shape、Realm、Module 等暂不搬迁的类型仍须明确记录稳定地址策略；将来扩大搬迁集合时逐类迁移。
精确边来自可信布局；保守候选必须先验证地址，不能直接解码任意整数并解引用。

### 4.2 顺序约束

存在搬迁时，先收集显式 pin 与保守扫描限制，确定不可移动对象／页，再开始 evacuation。
当前 Collector 已有 retainPagesNamedByNativeFrames 预扫描，以及 evacuate 中 retained page／header pin 检查；
迁移应保留并验证这些机制，新增审计重点是只读 provider、身份快照和所有迟到 pin 路径是否被完整覆盖。
同一实体同时存在可写根和只读引用时，不能先搬迁再发现无法更新的引用。
任何可能发现新 pin 的路径都必须纳入预阶段，或采用不会产生迟到 pin 的另一套完整算法；禁止事后补标记充当修复。

访问槽位的地址本身也可能失效：先确定 owner／存储的有效位置，再枚举其内部槽位。
不能跨 owner 搬迁缓存字段地址；复制 owner 后必须修复自引用、内部偏移和单独分配的 storage 引用。
只访问临时副本不能证明原位置得到更新。

完整生产 visitor 必须支持其负责的全部强边、弱处理交接和 atom 边；漏项在编译期失败。
标记、搬迁、审计可以有不同处理策略，但不能共享“缺方法即忽略”的默认正确性假设。
部分诊断 walker 可以显式声明只关心某类边，不能因此被当成完整存活性证据。

## 5. 写入、发布与失败

已发布对象的普通写入收敛到 heap_store.value 一类内部入口；保留当前屏障算法与顺序。
owner、slot、目标 Runtime 与发布状态须符合契约，屏障和 store 之间没有潜在 GC 点。
bulk store 与未发布初始化使用不同的明确入口，不伪装成普通已发布写入。

根写入需要标记正确性证明：逐条确认是根屏障、最终重新扫描，还是其他现行机制覆盖；不能套用堆屏障后宣称完成。
新目标必须在下一次可能 GC 之前安装到正确持有位置；未发布对象不能暴露未初始化字段。

| 失败位置 | 必须维持的状态 |
| --- | --- |
| 根登记分配失败 | 无悬空注册；调用方输入保护仍有效 |
| 字符串物化失败 | 输入仍可用；输出根不变；临时分配按当前所有者规则清理 |
| 屏障／追踪工作队列资源不足 | 按收集器既有失败协议处理；不可吞错后继续回收未证明死亡的对象 |
| 搬迁前预备空间不足 | 尚未提交搬迁时可明确放弃／回退 |
| 搬迁部分完成后失败 | 必须有完成引用修复的资源或已证明的恢复方案；不能留下半转发图后直接返回 OOM |
| 回调抛错或重入 | 根作用域正确退栈；外层借用不跨回调继续使用 |
| handle 转移失败 | 源仍保活；目标按失败契约保持原值 |

不改变 Runtime 销毁和宿主残留 handle 的现行公开规则；其调整需要独立生命周期设计。

## 6. 有依赖的实施计划

所有项目均未实施。每项完成后更新所属权威契约，不把本表的目标状态写成现状。

| ID | 前置 | 文件／操作 | 验收与定向验证 |
| --- | --- | --- | --- |
| V0 | 无 | value.zig、gc_roots.zig、gc_visit.zig、runtime.zig；完成所有值方法、根变体、GC 入口与强边清单 | 每项有副作用分类、真实持有位置和更新／稳定地址策略；先复现发现的具体缺陷 |
| V1-A | V0 | value.zig；分离纯编码入口，保留转发兼容 | 8 字节、编码 round-trip、NaN／正负零、short BigInt 边界与所有 heap tag 不变 |
| V2 | V1-A | 轻量堆引用定义、gc.zig、载体转换；移出值层的物理布局依赖 | 各载体 ref/body 往返、对齐与地址范围；不得读不属于载体的链接字 |
| V4-A | V0 | roots.zig、runtime.zig；根引用适配、返回值交接与根更新规则 | 根注册 OOM、scope 提前退出、嵌套 scope、跨 Runtime 拒绝、转移失败与别名；不改变公开宿主契约 |
| V1-B | V1-A、V4-A | string.zig、string_view.zig、bytes_view.zig、exec/string_ops.zig；分离投影与物化 | flat／rope／已缓存 flat、物化 OOM、输入输出别名；所有隐式物化调用迁移或明确兼容边界 |
| V3-A | V2、V4-A | gc_roots.zig、runtime.zig、根 providers；替换临时副本访问 | borrowed slices、cells、header roots 均有真实更新或稳定地址策略；原槽位而非副本发生变化 |
| V3-B | V3-A | gc_visit.zig、各 traceChildEdges、gc_trace_stw.zig；完整 visitor 协议 | 故意漏强边的方法时编译拒绝；诊断 visitor 不被误认成完整 tracer |
| V5 | V3-B、V1-B | property/object、数组和缓存写路径；集中屏障与借用窗口 | old→young、自引用、循环、共享目标、bulk 写入、回调重入与 storage 增长 |
| V6 | V5 | nursery 与收集器、weak/atom 路径；审计 pin 预阶段、搬迁提交和失败恢复 | 同目标混合根、转发后真实槽位、弱身份、atom 表更新、部分搬迁 OOM；默认与实验模式分开报告 |

执行义务只以[验证政策](verification-policy.md)为准：修改 Zig 后使用 mise 管理的 fmt、check、定向测试，收尾一次最终 build test；批边界门禁按政策执行。
空测试选择不算通过。移动路径通过不得由默认模式通过替代；本计划不授权默认启用 nursery。
涉及语言语义的修复另附 ECMA-262 依据和 focused differential；纯布局／根协议检查不能替代语义验证。

## 7. 对抗序列与证据界限

实施审查至少逐条推演并转成适合的回归用例：

1. a 已根化，创建 b 时触发 GC；随后只能读取更新后的 a，不使用旧参数副本。
2. 同一目标同时由 mutable root、borrowed slice 和 persistent 持有；搬迁决策尊重最强地址限制。
3. source 已取切片，search 物化发生 GC；旧 source 切片必须已经退出借用窗口。
4. 物化输入与输出相同，分配失败；输入仍有效且根帧退栈完整。
5. owner 自引用，属性 storage 单独搬迁；owner 字段、storage 字段和自引用全部指向新位置。
6. 回调重入引擎、创建内层 handles、抛错；外层根有效，内层清理不破坏外层作用域。
7. 无强边的弱目标被清理；有强边时目标搬迁，弱身份不能指向旧地址。
8. 持有 atom id 的对象存活，实体位置变化；atom 身份映射与追踪一致。
9. 搬迁中途申请额外队列失败；回收前必须完成修复或走已验证的恢复路径。
10. 结果撤根后的 defer 意外触发 GC；交接契约检查应在违规入口开火。

本草案只有源码静态核对和设计结论，无新增实现、运行测试或性能证据。
尚未完成的 V0 全量调用／边清单不能被上述局部核对替代。

## 8. V0 静态审计记录

本节记录设计所需的源码证据，不是运行正确性证明。方法分类覆盖当前 JSValue 的全部 51 个公开方法；
根分支与 GC 入口已定位。provider 生命周期、全部业务调用的传递副作用和移动失败恢复尚未逐路径验证，
因此 **V0 整体仍未完成**。不得仅凭以下名称覆盖进入“移动安全已成立”的结论。

### 8.1 JSValue 方法全集

E = 只操作编码／值槽；P = 无分配的指针投影（布局相关）；R = 借用读取；M = 可能物化、分配、GC。
P 返回的是临时借用地址，不建立根。分类依据方法体及其直接辅助实现，不依据方法名称或 error union。

| 分类 | 当前方法（逐项列出） | 证据与限制 |
| --- | --- | --- |
| E：编码基础 | shortBigIntFits、is、as、from、tagOf | encode/decode 与 tag arithmetic；as(.object) 只解码，不能证明实体种类 |
| E：立即值构造 | int32、float64、number、boolean、shortBigInt、nullValue、undefinedValue、uninitialized、catchOffset、exception | 不分配；number 保留负零；浮点 NaN 规范化 |
| E：堆引用装箱 | bigInt、string、stringRope、symbol、object、module、functionBytecode | 输入已有地址；encode 当前会以 payload_mask 掩码指针，V2 要审查地址范围前置条件，不能仅靠 box 对掩码后结果的断言 |
| E：检查与立即值读写 | isNumber、isBigInt、isString、setInt32AssumeInt、trySetInt32FromSlot、asInt32Pair、asNumber、asBranchImmediateBool、catchTarget | 两个写入 helper 仅处理已经分类为 int 的槽位，不是通用堆字段写入入口 |
| E：引用编码与表示比较 | refHeader、refHeaderAssumeObject、stringHeader、stringHeaderAssumeStringLike、functionBytecodeHeader、cycleMarkHeader、withTracedHeader、isTracerOwned、same | 提取或替换编码，不读目标体；same 不是所有 JS 值的内容相等 |
| P | asSymbolBody、asStringBodyRaw、ropeBody | 纯指针投影，但绑定具体类型布局，应与通用编码区分 |
| R | asSymbolAtom、asInt64、asUint64、asBytes、sameValue、sameValueZero | 读 atom_id／limbs／buffer 状态／字符串内容；不得跨潜在 GC 点缓存其借用数据 |
| M | asString、asStringBody | asString → JSString.fromValue → asStringBody → rope.flattenInfallible；可发生 GC，不因返回 optional 而成为纯投影 |

附属 isZeroBigInt 是 R；bigIntParts / compareBigIntValues 只借用 limbs。
compareStringValues 使用 [StringValueIterator](../src/core/string.zig) 的固定栈迭代，不物化 rope；
因此 SameValue / SameValueZero 的内容比较不必改成可失败分配操作。
asBytes 的 [Bytes.fromValue](../src/core/bytes_view.zig) 检查对象种类、detach、offset 和长度，返回借用视图；
其 Error 不意味着会 GC。后续可分离／调整大小操作仍会使视图失效。

**类型层的新约束**：VarRef.valueRef 使用 object tag 包装 VarRef header。
因此当前 object tag 不等价于 RefKind.object；不能把 object(value) 构造器立即缩窄成只接收 Object body。
V2 先保留这个内部编码协议，以 RefKind 验证真实对象；是否独立编码 VarRef 是后续表示决策，不夹带到本次职责拆分。

### 8.2 根槽位与身份边

| 入口／持有者 | 当前访问位置 | 迁移关注点 |
| --- | --- | --- |
| ValueRootFrame.objects / values | 实际对象指针槽、实际 JSValue 槽 | 可回写；slot 不能早于 frame 失效 |
| ValueRootFrame.headers | HeaderRootValue.header 按目标传递 | 类型稳定地址策略；不是自动 pin 的证据 |
| slices.mutable / windowed | 从 slice header／实时 live_len 取得实际元素 | 保留可增长容器的重新取址规则 |
| slices.borrowed | constValues 逐元素复制后访问 | 无原数组回写；需要稳定地址策略或改变调用协议 |
| slices.cells / borrowed_cells | VarRef header 装箱副本 | cell 身份边；默认标记与移动支持分别判断 |
| Runtime.current_exception、handles、weakref_kept_alive | 实际字段／RootSlot.value | 可回写；kept-alive 期间是强边，不等于弱 handle |
| RootSet providers、ValueRootBuffer | provider 回调；buffer 稳定 backing 中的实际槽 | 注册失败、容器增长及撤销生命周期另审 |
| Runtime strings / AtomTable | stringSlot/stringField；atom body 装箱后显式写回 | 已有正确的回写适配，不删除它们 |
| Job queue、active job、active invocation、deferred payload cleanup | 分别委托 traceRoots／PayloadVisitor | 参数为实际槽；realm 按 Header 访问；外部回调协议需明确能否保留 slot 地址 |
| RealmContext | 原型、global、lexicals、缓存为实际字段；module/shape 为目标 | 现有 cached proto 临时变量有显式回写；不能把所有临时变量统一判成漏更新 |
| JsonRecordRoots / JsonPendingRecordRoots | [JSON record](../src/exec/json_ops.zig) 中的真实 value、atom 字段 | 遍历读取当前列表，注册与增长的时序需审 |
| ReplaceMatchRoots / PendingDescriptorRoots | [match 列表](../src/exec/string_ops.zig)、[descriptor 列表](../src/exec/call_runtime.zig) 的实际字段 | 不复用旧 list.items 地址跨分配 |
| CompileAtomScope | atom id 根 | 追踪身份而不是值槽 |
| Atomics.waitAsync | [traceWaitAsyncRoots](../src/exec/atomics_ops.zig) 把 promise 复制到临时 buf，再访问副本 | 不回写 waiter.promise；锁、waiter 存活期、快照保活与 pin 策略必须一起审，不能简单把 visitor 移到锁内 |
| Realm.host_scheduler / host providers | 委托宿主 traceRoots | 实际实现的注册、取消和可写位置属于剩余 V0 审查，不能从接口签名推断正确 |
| collector 原生栈候选、pin 账本、construction root | 保守预扫描／稳定地址保活；特殊未发布 shell 边 | 与精确根不同；禁止以全量无差别扫描未初始化字段代替特殊协议 |

### 8.3 堆遍历权威与回写能力

traceHeaderEdges 分派覆盖当前十四个 RefKind：

- object：Object.traceChildEdgesFallible；包括 shape、属性、dense elements、payload、字节码与宿主 class 边。
- function_bytecode：realm、constant pool 实际槽及 atom operands。
- var_ref：实体的 value 槽；访问 VarRef 身份与访问此槽是两个步骤。
- shape：proto 槽与 property atom ids。
- realm_context：RealmContext.traceChildEdgesNoFail。
- module：ModuleRecord 的变量值、func_obj、module_ns、异常、import_meta 与 atom ids；Registry 按 module 目标遍历。
- rope：left/right 实际值槽与 buffer storage 槽。
- string、symbol、big_int、property_storage、array_storage、payload、string_buffer：当前分派为叶；storage 中的值由 owner 负责枚举，不能据此漏掉 owner 的内容遍历。

Object 中 function_bytecode 和 home_object 的临时包装有显式回写；捕获 VarRef、mapped arguments VarRef
及 [GeneratorPayload](../src/core/generator_state.zig) 中的 VarRef 包装没有回写。
[RealmRecordPayload](../src/core/object_payloads.zig) 也访问 realm 临时副本；它当前不搬迁的策略需要显式记录。
这些不是同一种边，不应靠替换函数名字批量迁移。

storageCell 当前 Collector 实现只做叶标记，没有搬迁回写；CellSlot 是具备回写能力的协议，
不代表当前所有 storage 已会搬迁。若扩大可搬迁类型集合，Object 的 captures/aux 等局部地址必须在 storageCell 之后重新取得。

已有 Edges、carriesReference、assertClassified、traceDeclared 对 payload 字段做分类和部分自动遍历。
assertClassified 证明字段在分类表内，不能证明 manual 方法访问了原槽位；carriesReference 的类型识别集合也不是任意堆指针的全局证明。
V3-B 的新增职责是生产 visitor 完整性与 manual 边语义，不重写已有分类机制。

### 8.4 GC 入口与现有搬迁机制

| 入口 | 已核对行为 | 借用契约影响 |
| --- | --- | --- |
| Registry.requestGC / Runtime.triggerGCOnAllocation | 设置请求；trigger 调用 requestGCForAllocation | 请求不是立刻收集，不能把每次通知误标成 GC |
| collectBeforeObjectAllocation | 可能先 drain deferred finalizers，再 pollGC(.normal) | 既是潜在 GC 点，也是需审查的回调边界 |
| retryHeapLimitOnce | tryRunObjectCycleRemovalWithValueRoots(.engine_active) | 限额重试是潜在 GC 点，即使外层返回 void |
| pollGC / pollGCChecked | owner 检查、deferred cleanup、gc_driver.continuePoll | 驱动路径可收集；checked 只增加边界校验，不改变保活义务 |
| gcSafepoint / forceGC | 分别进入 safepoint／urgent poll | 显式 GC 边界 |
| afterCallbackBoundaryGC / beforeEventLoopIdleGC | poll 后还有预算化 cleanup／finalizer | 不能仅检查 poll 返回前的借用状态 |
| tryRunObjectCycleRemovalWithValueRoots | 处理未完成 destruction、abort 旧 cycle、collectCycles | guard 防递归不等于通用禁止 GC 契约 |
| collectCycles / collectMinor | 直接进入 Collector；minor 有代状态门槛 | 禁止 GC 检查需要覆盖底层入口，避免直接调用绕过 |
| StringRope.flattenInfallible | OOM 后尝试显式 GC、重试、再次失败 panic | M 类隐藏入口；需迁移错误传播 |
| collectForTest | 调用收集，错误时返回 0 | 测试辅助，不把 0 当作 GC 成功的证据 |

gc_trace_stw 中 visitValue 已调用 evacuate，并以 withTracedHeader 回写；visitObject 也会回写。
collectCycles / collectMinor 使用原生栈 pin 预扫描；evacuate 在 page retained 或 header pinned 时不搬迁。
复制分配失败时已有保留原页的回退；复制成功后的 work.append 仍可能记录错误。
因此 V6 要区分“复制前失败”和“已发布新副本后的队列失败”，不能把前者的回退当成后者的证明。
nursery_enabled 当前仍为 false；本审计没有切换或运行任何模式。

### 8.5 V0 剩余范围与实施入口

方法全集分类和上述边界映射完成，以下检查仍阻止 V0 整体关闭：

1. 逐个业务调用验证 M 类输入的根登记、旧裸地址使用及返回值交接；覆盖 string_view / bytes_view 的调用者，不能只搜索 asStringBody。
2. 逐个 provider 验证注册／增长／撤销、宿主 scheduler、active invocation 与异步 waiter 的锁和生命周期；解析出真实持有位置。
3. 对 object payload manual 边和函数 capture/storage 的取址顺序完成逐字段审查；扩大移动集合前建立 stable kind 清单。
4. 对新发现的风险先构造最小复现，按默认／实验配置分别记录；随后才授权相应实现修复。

第一项可实施的接口拆分仍是 V1-B 的字符串投影／物化，但必须先完成它涉及的 V0 调用闭包及 V4-A 根交接前置；
当前文档更新不授权直接删除兼容 API 或修改 OOM 语义。
