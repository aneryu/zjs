# JSValue 与 GC 边界设计

Status: **§6 各阶段验收已完成（证据与剩余设计方向见 §8.38）；nursery 仍默认关闭**。首轮基于 2026-09-23
未提交工作区，调用时序审查基线为 `1e4fa6ff`（main）；收口工作在同一未提交工作区完成。

本草案收敛值表示、根、借用和槽位访问的目标协议。它不替代
[VM 值表示契约](vm-value-representation-contract.md)、[GC 不变量](gc-invariants.md)
或[公开 API 契约](public-api-contract.md)。实施前先更新受影响的权威契约；文档版号、编码修订与 ABI 变化分别判断。
尚未实施部分的接口名称和签名仍是设计示意；已落地接口及验证见第 8 节，不据此扩大公开 API 保证。

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
| heapReference / isHeapReference 已新增 | cycleMarkHeader / isTracerOwned 保留转发入口；调用者继续迁移 |
| withTracedHeader 保留 tag、更换 payload | 保留能力，收敛到收集器内部的 relocation 适配；只能替换为同一实体的合法新位置 |
| asInt64 / asUint64 读取堆 BigInt，无分配 | 属于借用读取，不因读堆就要求 Runtime 参数 |
| asStringBody 经 flattenInfallible 物化 rope | 已分离 flat 投影与可失败物化；引擎内无调用者（`tools/check_string_boundaries.py` 门禁），仅作为公开 `Value.asString()` 的兼容实现保留 |
| appendValueUtf8 已按叶片流式编码；ToNumber 的字符串分支已去掉 stringObject 物化 | 保留 UTF-16 跨叶片配对和孤立代理项编码；原生输出分配可 OOM，不触发 GC |
| [string.zig](../src/core/string.zig)：flattenInfallible 在 OOM 时尝试 GC，重试失败 panic | 显式物化路径传播错误；迁移调用者时保留语言语义与 OOM 处理责任 |
| [gc.zig](../src/core/gc.zig)：Header 别名 TraceHeader，载体并不都能读链接字段 | 引入轻量 HeapRef 表示；具体字段访问留在布局层 |
| [gc_roots.zig](../src/core/gc_roots.zig)：value 接收实际槽位；constValue 区分 observe 与 pinned | 生产收集器在搬迁前枚举只读根并保留其所在页；局部副本仅供 observe 诊断使用 |
| stringSlot / stringField 装箱后写回原字段 | 保留回写适配，前提是底层字段在访问期间有效 |
| [runtime.zig](../src/runtime.zig)：root slices 的 cells／borrowed_cells 经 constHeader 访问 VarRef 自身 header | 明确为地址稳定的 cell 身份边；cell.value 由载体追踪，扩大移动类型集合前须重新审查 |
| [gc_visit.zig](../src/core/gc_visit.zig)：CellSlot 可回写带 tag 的存储地址 | 保留；区分位置、地址与 tag，不替换为按值访问 |
| gc_visit 默认要求完整方法集合；局部诊断 visitor 显式声明 partial；已有 Edges / assertClassified 做字段分类检查 | 已补方法完整性负向编译测试；manual 边已逐项核对（§8.34），临时副本只指向稳定载体 |
| [roots.zig](../src/core/roots.zig)：LocalHandle、persistent、RootSlot 已存在；rootValues 标量 helper 在非测试构建中被擦除；现已增加 ExactValueRoots | 新根引用只从始终登记的专用作用域导出；旧标量 helper 策略保留，后续按调用闭包迁移 |
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

**构建差异前置**：现有 rootValues / rootObjects 的标量 scope 在非测试构建中没有存储和登记操作，
ValueRootFrame.activate 也跳过没有 slices／atoms／headers 的 frame。稳定地址 header 根现在始终登记；非测试构建的普通标量依赖保守栈／寄存器扫描，
不是可回写精确槽位。不能把“调用过 activate”当作 RootedValueRef 的构造证明。
V4-A 先增加专用的始终登记精确根入口（可复用 mutable slice 根机制），或从已有稳定 handle 槽导出；
不全局翻转旧标量 helper 的策略。专用 frame 必须在最终地址激活、LIFO 撤销，禁止从临时返回对象的自引用激活。
此前用 rootValues 示意精确回写的调用例子仅表达目标协议，不能解释成现行非测试实现保证。

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

当前已实现专用精确根、显式物化入口、字符串隐式物化调用的全部迁移、纯编码内核／HeapRef 桥接、visitor 方法完整性、追踪窗口守卫、waiter 根交接和完成路径屏障、共用流式编码、禁止 GC 借用窗口、各转换根保护与 Object 构造器描述符／键／结果根（§8.10–8.33）。
V0 四项全量审计及其缺陷修复、写屏障缺口、按地址旁表与根缺口、nursery 保守扫描与标记见 §8.34–8.37；验收对照与剩余范围见 §8.38。
下表保留完整目标和验收条件。

| ID | 前置 | 文件／操作 | 验收与定向验证 |
| --- | --- | --- | --- |
| V0 | 无 | value.zig、gc_roots.zig、gc_visit.zig、runtime.zig；完成所有值方法、根变体、GC 入口与强边清单 | 每项有副作用分类、真实持有位置和更新／稳定地址策略；先复现发现的具体缺陷 |
| V1-A | V0 | value.zig；分离纯编码入口，保留转发兼容 | 8 字节、编码 round-trip、NaN／正负零、short BigInt 边界与所有 heap tag 不变 |
| V2 | V1-A | 轻量堆引用定义、gc.zig、载体转换；移出值层的物理布局依赖 | 各载体 ref/body 往返、对齐与地址范围；不得读不属于载体的链接字 |
| V4-A | V0 | roots.zig、runtime.zig；始终登记的专用精确根入口、根引用适配、返回值交接与根更新规则 | 测试与非测试可执行构建都验证实际登记；根注册 OOM、scope 提前退出、嵌套 scope、跨 Runtime 拒绝、转移失败与别名；不改变公开宿主契约 |
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

设计与局部实现证据并存；不能把局部回归通过作为整个目标完成的证据。
§8.7 记录旧二进制的有限诊断，§8.9 记录早期定向失败与对照；后续实现和验证按各节所述范围解释。
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
| ValueRootFrame.objects / values | 实际对象指针槽、实际 JSValue 槽 | 仅在 frame 确实链接时可回写；非测试纯标量 frame 被跳过，slot 不能早于 frame 失效 |
| ValueRootFrame.headers | HeaderRootValue.header 通过 constHeader 传递，所有构建均登记 | 生产 visitor 走 pinned 策略；只读根预阶段在搬迁前保留涉及的 nursery 页 |
| slices.mutable / windowed | 从 slice header／实时 live_len 取得实际元素 | 保留可增长容器的重新取址规则 |
| slices.borrowed | constValues 逐元素走只读根策略 | 生产收集器预先保留目标页；不写只读数组，不允许先搬迁后补 pin |
| slices.cells / borrowed_cells | constHeader 访问 VarRef 身份 | 当前载体地址稳定；不再将临时 JSValue 当作可更新根 |
| Runtime.current_exception、handles、weakref_kept_alive | 实际字段／RootSlot.value | 可回写；kept-alive 期间是强边，不等于弱 handle |
| RootSet providers、ValueRootBuffer | provider 回调；buffer 稳定 backing 中的实际槽 | 注册失败、容器增长及撤销生命周期另审 |
| Runtime strings / AtomTable | stringSlot/stringField；atom body 装箱后显式写回 | 已有正确的回写适配，不删除它们 |
| Job queue、active job、active invocation、deferred payload cleanup | 分别委托 traceRoots／PayloadVisitor | 参数为实际槽；realm 按 Header 访问；外部回调协议需明确能否保留 slot 地址 |
| RealmContext | 原型、global、lexicals、缓存为实际字段；module/shape 为目标 | cached proto 已访问实际 optionalObject 槽位，visitor 失败时也不依赖事后副本回写 |
| JsonRecordRoots / JsonPendingRecordRoots | [JSON record](../src/exec/json_ops.zig) 中的真实 value、atom 字段 | 遍历读取当前列表，注册与增长的时序需审 |
| ReplaceMatchRoots / PendingDescriptorRoots | [match 列表](../src/exec/string_ops.zig)、[descriptor 列表](../src/exec/call_runtime.zig) 的实际字段 | 不复用旧 list.items 地址跨分配 |
| CompileAtomScope | atom id 根 | 追踪身份而不是值槽 |
| Atomics.waitAsync | [traceWaitAsyncRoots](../src/exec/atomics_ops.zig) 在锁下快照本 Runtime 的稳定节点，解锁后访问实际 promise 槽 | owner-only 消费／删除受 trace guard 保护；摘链至入队由 mutable-window 根覆盖，见 §8.15 |
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

Object 的 home_object 已访问 direct／aux 中的实际槽位，aux storage 访问后重新取址；function_bytecode 临时包装有显式回写。捕获 VarRef、mapped arguments VarRef
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

gc_trace_stw 的 visitValue 经 value_heap_layout.relocate 回写实际值槽；visitObject 回写实际对象槽。
collectCycles / collectMinor 在搬迁前执行原生栈及只读根预扫描；evacuate 在 page retained 或 header pinned 时不搬迁。
复制前预留 work 与回滚日志容量；目标分配失败仍可保留原页。追踪或后续队列增长失败时，日志逆序恢复槽位、对象体及弱身份映射，释放副本而不执行其析构；回滚不分配。
ephemeron 不动点完成后才提交搬迁，随后才允许弱清理和回收。存活键对应的值通过实际 entry.value 槽访问，同样参与搬迁与回滚。
弱对象身份搬迁时同时更新地址到 ID、ID 到对象两张表，ID 保持不变；晋升还须转移目标 block 的 finalizer 位图，以保证死亡时清除身份。

[收集器回归](../src/core/gc_trace_stw.zig) 已验证条件保活链部分搬迁后 OOM、无分配回滚及重试；
[非测试可执行契约](../tests/exact_roots_executable.zig) 覆盖 major／minor 的追踪失败回滚、弱身份恢复，以及默认／nursery 模式下的对象／Symbol 键、条件保活循环、强根别名和单次弱通知。
该可执行契约已通过 Debug 与 ReleaseFast；弱 holder 和 Symbol 载体当前地址稳定，不据此宣称它们支持搬迁。
nursery_enabled 仍为 false；这些显式启用 nursery 的用例不授权改变默认配置，也不替代 V6 剩余路径的逐项验收。

### 8.5 V0 剩余范围与实施入口

方法全集分类和上述边界映射完成，以下检查仍阻止 V0 整体关闭：

1. 逐个业务调用验证 M 类输入的根登记、旧裸地址使用及返回值交接；覆盖 string_view / bytes_view 的调用者，不能只搜索 asStringBody。
2. §8.6 已核对内置 provider 的主干注册／增长／撤销及 bundled host scheduler；trace 准入守卫和 waiter 锁／根交接分别见 §8.14、§8.15。active invocation 的全部回写及其他 provider 的异常／探针闭包仍待核对。
3. 对 object payload manual 边和函数 capture/storage 的取址顺序完成逐字段审查；扩大移动集合前建立 stable kind 清单。
4. 对新发现的风险先构造最小复现，按默认／实验配置分别记录；随后才授权相应实现修复。

第一项可实施的接口拆分仍是 V1-B 的字符串投影／物化，但必须先完成它涉及的 V0 调用闭包及 V4-A 根交接前置；
当前文档更新不授权直接删除兼容 API 或修改 OOM 语义。

### 8.6 调用与 provider 时序复核（基线 1e4fa6ff）

**先区分分配入口**：[runtime_alloc.zig](../src/runtime_alloc.zig) 的 nativeAllocator 在生产直接使用 backing allocator，
诊断构建的 diagnosticAlloc 也调用 NoTrigger 路径；普通 ArrayList.append 不会由这层自动进入 GC。
allocNative / probedAllocator 则可能调用 noteAllocationProbe：测试安装的 probe 可执行额外动作，
owner_notify 是否执行收集由具体回调决定，默认 triggerGCOnAllocation 只请求 GC。
因此既不能把所有分配都当作 GC，也不能把有 probe 的注册过程当作无条件无重入。
旧注释中“原生数组增长就是 GC 点”的表述不能替代上述当前实现。

| provider／路径 | 注册、增长与撤销顺序 | 静态结论与尚需验证 |
| --- | --- | --- |
| RootSet.register / append | 追踪期守卫 → 去重；容量不足经 allocNative 分配；分配后重新读取 live len/capacity；提交后才增加 len | 追踪期间禁止集合变更；非追踪期的分配重入仍由重读处理，定向与全量测试覆盖 |
| ValueRootBuffer.initCopy | borrowed source frame → 分配 backing → 复制 → frame 改指 mutable copy → 注册稳定 block → 返回 wrapper | 成功后的 provider 不指向可移动 wrapper；失败释放 backing，退出撤 frame；复制前 borrowed 输入仍属于只读根策略审查 |
| JsonRecordRoots | 空 record provider 在 parse 前注册 → parse 返回后直接绑定 record → reviver 工作 → 先清空 record 指针再销毁 record → 撤注册 | 已完成注册／结果交接／退出顺序核对；parse 返回至绑定之间没有新增 GC 操作 |
| JsonPendingRecordRoots | parser 开始时注册空 head → 每层 parser 把 entries/elements frame 挂 head → 递归结果先设 pending 再 append → 清 pending → 退出先弹 head 再释放记录 | 已有未安装子记录的交接保护；append 走普通 nativeAllocator；不能删除 pending 保护只因当前 append 不 GC |
| ReplaceMatchRoots | 空 matches 注册 → captureReplaceMatch → append → 后续 JS 回调 → 撤注册 → free captures → free list | 已安装元素的 actual slots 与退出顺序成立；尚未安装的 captures 由下一段单独审查 |
| PendingDescriptorRoots | 空 pending 注册 → getter/descriptor 转换 → native append → 逐项 define → 撤注册 → destroy items/free list | provider 每次读取当前 list.items，已有元素得到保护；局部 desc、target、properties 跨 getter 的根仍按标量构建差异检查 |
| CompileAtomScope | 注册成功后才切换 ambient compile_scope → LIFO 恢复 ambient → 撤 provider → 释放 ids | 失败不会先发布 active scope；trace 按当前 ids.items 访问，不保留旧 backing 地址 |
| EventLoop host scheduler | install 发布 self → Realm 委托 trace → deinit 先按 self 身份 clear，再释放列表 | callbacks 从真实字段访问；clear 不会误清新安装的 scheduler；loop 自身在安装期间必须地址稳定 |
| 一次性 timer | 先激活 borrowed callback window → 移除 timer → 调用 callback → 撤 window | 已有离开列表后的保活交接；借用窗口不回写，精确移动目标仍需 pin／可写调用参数策略 |
| ActiveInvocation | [inline_calls.zig](../src/exec/inline_calls.zig) 沿 previous 访问 Machine、Frame、Stack 与 pending 参数窗口 | 值槽多数可写；VarRef 身份仍为临时包装；function_bytecode 字段的回写须单独核对，不能把所有 frame 字段视作统一类型 |

字符串调用闭包的两个具体场景：

- **stringReplaceCore**：ToString source/search/replacement → 分别物化并取得 sp_data/search_data/rep_data →
  循环内可能 replacement_call.call → 下一轮或收尾继续读旧切片。StringBuffer 的纯 native 增长本身不是 GC 点，
  但后续物化、调用 JS、最终 finish 的堆字符串创建是。V1-B 必须区分无回调分支和有回调分支，
  后者在回调后重新从根取数据，不能只把首次物化集中到函数开头。
- **JSON parseWithRecord**：输入根 → asStringBody → resolveData → 以 units 切片运行会创建对象／字符串的 parser。
  仅把输入值根化不会自动更新 parser.units；若底层字符存储可移动，需要在整个 parse 窗口 pin，
  或将输入复制到生命周期明确的原生存储，或让 parser 使用可重新定位的 owner+offset。
  这三种方案属于具体调用者的选择，不应藏进 JSValue.asString。

### 8.7 captures 交接的有限诊断

captureReplaceMatch 的 captures_root 和分配 errdefer 位于 `if (capture_count != 0)` 块内。
离开块后才执行 groups 属性读取，而该 getter 可以执行 JS 或抛错；此时 match 尚未返回并安装到 matches provider。
因此存在两个必须验证的具体问题：captures 的跨 getter 保活，以及 getter 抛错时 native captures 的释放责任。
仅看到局部 scope 的结束不能证明运行时一定回收／泄漏，仍需对应配置下的复现。

本轮用现有 `zig-out/bin/zjs` 执行了两个一次性诊断，均退出 0：

- 自定义 RegExp exec 返回 length=2 的结果，捕获 getter 产生动态长字符串；groups getter 调用 gc；
  replacement callback 检查长度 4106 和前缀 `capture-1-`，输出 `groups GC reached; capture intact`。
- 同样走 groups getter，但抛出指定 marker；外层确认错误身份及 getter 已到达；使用 --leak-check，输出 `groups throw reached`，未观察到失败。

二进制 SHA-256：`ba1498378a7bdc4514549bd981474b28f42fbba98b1544b9ec62cf09076152e7`。
没有重建或证明此二进制与审查源码／编译配置对应；诊断只证明该二进制上的这两个输入未失败，
不证明当前源码、精确根测试、nursery 或所有 native 分配释放正确。诊断未作为新增回归测试提交。

后续聚焦验证使用已知源码构建的 fixture：让捕获值只存于原生 captures 数组，
在 groups getter 中进入 declared-only 收集，并独立检查抛错路径的 native 分配余额。
上述旧二进制诊断本身不确认 bug；后续当前源码复现见 §8.9。仍未修改引擎修复它。

### 8.8 重入与回写协议的收敛

**根集合的 trace 期必须与 mutator 期分开。** RootSet.traceProviders 与 traceHandleSlots
现在通过嵌套 trace depth 冻结根注册／撤销；Runtime 根遍历也覆盖全部 provider 与 active invocation 回调。
register 的分配后重读继续处理非追踪期间的注册重入；追踪期间禁止 unregister/free/reallocate。
ClassTable.markPayload 除 callback pin 外，另加独立 trace window；类记录 pin 本身并不保护根集合。

目标契约：provider／payload marker 只报告槽位，不执行 JS，不销毁 Runtime，不注册或撤销根，
不触发新的收集，不持有 visitor 或 slot 地址到回调返回之后。收集器自身的原生工作队列可分配并传播失败，
它不等于允许 provider 任意重入。当前已在根、handle、原生 pin、收集、销毁和执行入口增加守卫，见 §8.14；
visitor／slot 地址不得逃逸仍是借用契约，不能由一个运行时深度计数证明。

**Atomics.waitAsync 的问题主要是快照与回写，不应先假定任意线程都可释放 waiter。**
AtomicsWaiter 注释及 completion／destroy 路径规定：外部线程只在锁下改变 completion 并发信号，
Promise／RealmRef 的消费与删除属于 Runtime owner。现在 trace 在锁下取得本 Runtime 的稳定 waiter 节点列表，
在禁止 owner 重入的 trace 窗口内、解锁后访问各节点实际 promise 槽，然后释放临时节点列表。
所有 visitor 回调均不持有全局 waiter mutex；外部线程可以继续通知，不能删除被追踪 Runtime 的节点。
消费、清理、链入／摘链及销毁入口均实施 owner／trace 守卫，相关验证及入队交接修复见 §8.15。

**当前不移动的载体不需要伪造回写能力。** 本轮核对的 gc_alloc.createInternal nursery 分配分支受
`T.gc_kind_tag == object_kind_tag` 限制。Frame.function 的 function_bytecode 包装和 VarRef 身份包装均未回写；
它们在现行稳定地址路径下按强目标追踪。目标协议应显式列出稳定类型，不把这些路径直接判为当前搬迁失败。
若扩大 nursery 载体集合，先迁移这些 typed slots。Shape／Realm／Module 也需要各自的稳定地址或可写策略。

**storage 协议与具体实现分开验收。** captures slice 和 aux 指针在部分 Object 分支中于 storageCell 之前取得，
当前 storageCell 只标记叶 cell；将来实际移动 storage 时必须先回写存储地址，再重新解码 captures／aux，
不能拿旧局部地址枚举字段。V5 的验收要分别覆盖 owner 移动和 storage 移动。

### 8.9 当前源码的 captures 定向复现

诊断 worktree：`/home/aneryu/zjs-value-gc-audit-20260923`，detached HEAD `1e4fa6ff`。
复现阶段只在其中的 `tests/exec.zig` 增加诊断 fixture；该诊断 worktree 的 `src/` 未修改。
工具链为 mise 管理的 Zig 0.16.0，Debug，默认 nursery 关闭。诊断测试留在隔离 worktree，未合入或提交。
最终诊断 `tests/exec.zig` SHA-256：`ea7a341ee957f0d8368b662dd44e031b7f966f3c4d633105dac3d46648578947`。

保活 fixture 直接调用 captureReplaceMatch，result/source 使用精确根保护；捕获 getter 经 native probe 创建新 String，
probe 只记原地址。groups getter 完成一次 declared-only major 后，以 containsHeader 查询是否仍存活，
不解引用可能已回收的字符串。对照只增加 probe.kept 的显式根，业务路径与收集保持一致。

| 检查 | 结果 | 证据边界 |
| --- | --- | --- |
| mise exec -- zig fmt tests/exec.zig | 通过 | 诊断 fixture 格式化 |
| mise exec -- zig build check -j32 --summary all | 通过，5/5 build steps | 编译检查，不是生命周期正确性 |
| test filter: value boundary audit captures survive | 失败：8/9 tests passed，1 failed，退出 1 | 包括自动导入／辅助 tests；目标未保护用例失败，对照通过 |
| 未额外保护捕获值 | collections=1，alive=false | 默认非 nursery、精确根收集即可复现；并非仅有未来搬迁风险 |
| 显式根对照 | collections=1，alive=true | 同一路径可由完整保活窗口保护；未修改生产实现 |
| test filter: value boundary audit captures cleaned（含对照） | 8/9 tests passed，1 crashed，退出 1 | groups 返回 JSException，只有含 captures 的用例在 Runtime.deinit 的 !hasOutstandingAllocations 处 ABRT |
| 无 captures 的抛错对照 | 通过 | 同样 groups 抛出 JSException，Runtime 正常清理；排除普通抛错本身必然造成该断言 |

重跑命令（在上述诊断 worktree）：

```sh
mise exec -- zig build test -j32 -Dtest-filter='value boundary audit captures survive' --summary all
mise exec -- zig build test -j32 -Dtest-filter='value boundary audit captures cleaned' --summary all
```

首版 fixture 曾因 TestEngine.eval 默认丢弃 completion 而在读取属性前失败；该运行不算复现。
有效 fixture 使用 evalWithOptions 的 `<repl>` completion，并断言 result 为 object、source 为 string，再执行目标路径。
未运行全量测试、ReleaseFast 或 nursery 验证；定向测试的预期失败不能写成测试通过。

已经确定的修复要求是：captures 的根与错误清理责任必须跨过 groups getter，并持续到成功返回交接。
callee 只在返回成功时把 native captures 所有权交给调用者；任何中间抛错都必须释放它。
caller 在安装到 matches provider 前若 append 失败，也必须释放尚未接管的 captures。
这些要求属于原生命周期契约的修复，不需要改变 JSValue 编码。

这两项定向缺陷已有复现与对照，但 V0 全局调用闭包尚未完成；不能将 captures 的验证推广到整个引擎。
已闭合的 captures 路径可以成为独立修复批次，其余字符串／JSON 借用、trace 重入 guard 和移动载体迁移仍按各自前置验收。

### 8.10 captures 实施进展

主工作区已修改 `src/exec/string_ops.zig`：函数级 mutable slice 根覆盖输入、临时值与 captures，
captures 的错误清理覆盖 groups getter；matches.append 失败释放未交接的 captures。
`tests/exec.zig` 新增三个回归测试，覆盖精确 GC、四种 getter／coercion 异常路径与 append OOM。
Debug 定向命令 `mise exec -- zig build test -j32 -Dtest-filter='replacement captures' --summary all`
通过，10/10 tests（3 个新增测试、7 个自动导入／辅助测试）。整体设计的其他阶段仍未完成。

全量验证曾报告 2016/2016 tests passed，但带有两条 `ATOM AUDIT stale edge id=693`，
当时未按全绿处理。独立运行定位到 `tests/core.zig` 的 tiny-heap 压力测试，
并在未修改生产代码的上述诊断 worktree 中定向复现。该 fixture 的动态 edge_key 在首次对象分配前未登记 atom 根。
主工作区已补 rootAtoms，并增加 `atom_audit_stale_edge == 0` 断言；该定向测试通过（8/8，含辅助测试），无原告警。
最终 `mise exec -- zig build check -j32 --summary all` 通过（5/5 steps）；
修正 fixture 后的 `mise exec -- zig build test -j32 --summary all` 通过（2016/2016 tests），无上述 atom audit 输出。
未运行 ReleaseFast、nursery 专项或批门禁；这些结果只验证本次修复，不代表整体迁移完成。

### 8.11 V4-A：专用精确根与交接入口

`roots.zig` 的 `ExactValueRoots(N)` 通过 mutable-slice frame 在所有构建中登记，
在最终地址 activate，严格 LIFO deactivate。登记和写入不分配；每次激活清空槽位，
Runtime 单调代次防止同址复用恢复旧借用。RootedValueRef／MutableRootedValueRef
先验证 Runtime、活跃作用域与代次，再读取真实槽位；失效作用域地址只比较、不解引用。
引用不拥有 Runtime，禁止 Runtime 销毁后再使用。setter／登记入口拒绝 gc_running 或 trace window 中的修改；
旧 provider／handle 的追踪期生命周期守卫见 §8.14，未把原始可写 slot 指针改成所有权类型。

`JSValueHandle.takeInto` 先写入目标根再撤销源根，失败保留源所有权。
captureReplaceMatch 已使用新根引用；执行层显式处理根代次耗尽为 OOM，协议违例报告为引擎 panic，
不把这些内部错误加入 JavaScript 异常集合。JSValue 编码、旧 get／take 契约和 nursery 默认关闭保持不变。

新增七个 `exact value roots` 测试覆盖生命周期、异址／同址过期引用、跨 Runtime、别名、
失败转移、零分配登记、异常退出、收集中拒绝修改、visitor 回写和真实 nursery 搬迁。
`tests/exact_roots_executable.zig` 强制非测试构建，关闭保守扫描后检查保活／撤根回收与两个别名槽位的搬迁回写；
`zig build test-exact-roots` 独立运行，完整 `zig build test` 也包含该可执行程序。
ReleaseFast 的 `test-exact-roots` 已通过。三个 `ZJS_EXACT_ROOT_INJECT` 注入通过 `zig build test`
确认 LIFO、Runtime 带活跃根销毁和收集中撤根分别触发自己的守卫，预期非零退出不是普通测试通过。
本轮 `zig build check` 通过；最终 `zig build test -j32 --summary all` 为 2024/2024 tests passed，
并成功运行 Debug 非测试根契约程序。未运行批门禁或完整 nursery 验证，V1-B／V3／V5／V6 仍未完成。

### 8.12 V1-B：显式物化与 replace 调用闭包

`string.asFlat` 只投影 flat tag；`string.ensureFlat(rt, input, output)` 使用精确根引用，
预先验证输出，失败不修改输入／输出值，支持原地别名。缓存 rope 仍不算 flat-tag 投影。
当前沿用 string／rope／buffer 的稳定地址策略；不能据此扩大 nursery 可移动类型。

普通字符串 `replace`／`replaceAll` 已迁移：在 getter／ToString 之前登记参数和中间值，
统一完成物化后才取切片；替换回调返回后重新读取根，不跨回调沿用旧切片或缓存 callable。
字符串的长度、空串、包含／字节相等查询和 UTF-16 单元复制已改用 header／rope iterator，
字符串分支不再物化；非字符串兼容转换仍保留原契约。

新增重入用例先在未修复的 flatten 上复现错误内容：分配 probe 内再次物化同一 tail view，
精确 GC 回收旧 buffer，再由真实分配器复用并写入其他内容；外层仍从旧 backing 复制，断言失败。
修复统一通过分配后的 copyRopeContent 读取当前 rope 表示，不再提前保存 tail buffer 指针；同一回归随后通过。
五个 `string materialization` 测试覆盖 flat／rope／宽字符／tail、缓存、别名、OOM、非法根、
allocation-probe GC 和上述重入。两个 `string boundary` 测试覆盖不物化的查询／复制和五次精确 GC 跨 coercion／replace 回调。
非测试契约程序也加入物化 OOM 保留输出及原地别名检查，ReleaseFast 验证通过。

新构建的 Debug runner 对 `String/prototype/replace` 为 55/55、`replaceAll` 为 45/45，均零错误。
`zig build check` 已通过。这不是整个 V1-B 收口：string_ops 中 RegExp split／fast replace
仍有隐式入口（pad／concat 的后续迁移见 §8.19–8.20），string_view／JSON 等借用窗口、JSValue 叶层拆分和 V3／V5／V6 仍待实施。
本轮最终 `zig build test -j32 --summary all` 通过：2031/2031 tests，另含成功运行的 Debug 非测试契约程序；
未运行批门禁或全量 ReleaseFast suite。

### 8.13 V1-A／V2：纯编码内核和 HeapRef 桥接

`value_encoding.zig` 独立承载 prefix／tag、float NaN 规范化、整数 payload 与 heap-tag 分类，
依赖仅有 std 和 `heap_ref.zig`，可单独 `zig test`；JSValue 原接口转发到该内核。
`heap_ref.zig` 定义 `*align(8) opaque`，不包含 Header 字段或 Runtime 指针。
完整地址在装箱前检查非零、对齐和 48-bit 范围，原先掩码后再断言的路径已移除。

`heapReference`／`isHeapReference`／`fromHeapReference` 已加入；旧 Header 接口保留兼容。
collector.visitValue 使用新投影；搬迁写回走 `value_heap_layout.relocate`，先验证目标编码，再读取两个有效载体的 metadata kind，
最后保留原 tag。VarRef 的 object tag 仍表示 cell 自身，并不会变成 cell.value 或普通 Object。
真正的堆成员资格、同实体搬迁证明和 Runtime 归属仍由调用方承担，不能由 tag／地址范围测试替代。

定向验证覆盖七个 heap tag 的位级往返和 payload 替换、所有 immediate／sentinel 排除、
地址零／未对齐／越界拒绝以及真实 VarRef 载体身份。三个 `ZJS_VALUE_ENCODING_INJECT` 注入分别命中
装箱越界、重定位越界及 VarRef→Object 载体不匹配守卫。纯内核 standalone test、Debug／ReleaseFast
heap-reference 定向测试、真实 nursery 别名根搬迁和 ReleaseFast 非测试契约程序均通过。
表示契约升为文档 v4；8 字节 JSValue、tag 值、encoding revision 2 均未改变。

这仍不是 V1／V2 全部完成：JSValue facade 的旧 Header 签名及 heap view／语义方法仍待收敛，
物理载体遍历、临时副本／pin 分类和 V3–V6 的完整验收不能由本轮编码测试代替。
本轮 `zig build check` 通过；最终 `zig build test -j32 --summary all` 为 2036/2036 tests passed，
Debug 非测试契约程序也成功。未运行批门禁或全量 ReleaseFast suite。

### 8.14 V3-B：visitor 完整性与追踪期准入

`gc_visit` 默认检查九个方法；缺任一方法即编译错误。生产 Collector 独立调用
assertComplete，诊断 address/owner walkers 显式声明 partial。负向编译 fixture 只访问 value，
却故意漏掉 visitAtom，验证检查的是完整方法集合；`test-gc-visitor-contract` 已接入全量 test。

追踪期缺口已先复现：不运行 GC 而直接调用 traceProviders 时，旧 gc_running 检查允许
provider 写根及激活新根，回归测试失败。修复新增 RootSet.trace_depth，
Runtime 根枚举、RootSet providers／handles 枚举、payload marker 与 host scheduler callback
都使用可嵌套窗口，defer 保证失败退栈。根／handle／原生 pin 生命周期禁止 mutator 修改，
精确根 checked API 沿用 RootMutationDuringCollection 错误；visitor 对实际槽位的修复仍合法。
收集、Runtime 销毁与 JS 调用准入增加独立守卫，不以 gc_running 的“已有收集则返回”代替拒绝重入。

四个新增测试与扩展的精确根回归覆盖嵌套失败退栈、槽位修复、直接 payload callback 和正常调用恢复。
`ZJS_TRACE_INJECT=1..10`、`ZJS_TRACE_JS_INJECT=1..2` 在同一诊断二进制、`zig build test`
调用形态下逐项命中预期 panic 文本，分别覆盖 provider 注册／撤销、handle 创建／销毁、frame
激活／撤销、Runtime 销毁、三种收集入口与两条 JS 调用入口。
`zig build check`、定向 11/11、全量 2040/2040 和 Debug／ReleaseFast 非测试根契约程序通过。

这不证明任意原始 slot 指针无法逃逸，也不替代所有 manual 边、host 自有存储及最终 V3–V6
的审计；waiter 实际槽位的后续验证见 §8.15，完整目标仍未关闭。

### 8.15 V3-A：waitAsync 实际槽位与摘链交接

两个缺陷均先由回归测试复现：trace visitor 收到临时 JSValue 地址，无法回写 waiter.promise；
processExpiredAtomicsWaiters 摘链后入队分配触发 declared-only GC 时，真实 Promise 被提前回收。
后者的失败断言检查 GC registry 存活状态，测试清理不解引用已经回收的对象。

traceWaitAsyncRoots 现在快照稳定节点指针，并在解锁后访问实际 Promise 槽和稳定 Realm Header。
本 Runtime 节点数量在 trace window 内不可变；外部 Runtime 可以改变全局链表，因此解锁后的遍历
不读取 next。所有节点消费、清理、链入／摘链、销毁入口检查 owner 和追踪期约束。
快照超过 16 个节点时使用不触发 GC/probe 的 nativeAllocator；快照分配失败和 visitor 失败
都释放临时空间、退出追踪窗口，保留既有槽位修复，不吞错继续回收。

Queue.enqueueAtomicsWaiter 接收 Promise 实际槽地址，在增长期间通过始终链接的 mutable window
保护该槽，并以 Header 根保护 Realm。成功后从更新后的槽构造 typed job；失败后重新挂链的
仍是原节点及更新后的槽，没有“只更新局部副本，再重新发布旧地址”的间隙。
入队后由 job.payload.atomics_waiter.promise 负责追踪，waiter 内副本不再作为执行输入读取。

四个新回归覆盖 17 个节点及跨 Runtime 隔离、实际槽地址与回写、header/value visitor 失败、
快照 OOM、外部线程 notify、真实 nursery 搬迁、真实 Promise 精确 GC 保活及搬迁后入队 OOM／重试。
当前 Promise 的可变大小载体不进入 nursery；搬迁测试明确使用可移动普通 Object 验证同一根槽协议，
随后销毁 typed job，不对该测试对象执行 Promise settlement。
`ZJS_WAITER_TRACE_INJECT=1..6` 在同一诊断构建的 `zig build test -Dtest-filter=waitAsync`
调用中分别命中清理、消费、摘链、销毁、异步链入与底层链入守卫。

`zig build check`、waitAsync 定向 15/15、全量 2044/2044 通过；Debug／ReleaseFast 非测试根契约
程序验证 waiter 实际槽搬迁、入队后精确 GC 保活。未运行聚合批门禁或全量 ReleaseFast suite。
这关闭上述两个具体缺陷；创建／settlement 路径的后续迁移见 §8.16，V3–V6 尚未全部完成。

### 8.16 V4／V5：waitAsync 创建根与完成写屏障

完成路径的第三个缺陷已复现：晋升后的 Promise 直接写入新建 `timed-out` 字符串，
没有记录 old→young 边，下一次 minor 回收该字符串。现在 result 和 reaction_arg 均通过
Object 的现有带屏障 setter 写入；没有改变屏障算法或吞掉入队失败。
完成函数用专用精确根保护 Promise 和结果字符串，分配后重新投影 Promise，随后无 GC 地
安装字段并消费保留的队列槽。资源性根代次耗尽映射为 OOM，其他根协议违例报告 panic。

waitAsync 入口复制 global／view／index／expected／timeout 到始终登记的精确根，
每次可能调用 JS 的转换后重新投影视图；参数转换顺序不变。共享 store identity／offset
在 Promise 分配前计算并 retain，成功交给 waiter，失败按当前所有者释放；不跨该分配保存 bytes 借用。
结果包装完成后重新读取 Promise 根再发布 waiter，避免发布旧快照。

atomicsWaitAsyncResult 使用两个精确根保护输入与结果对象。底层 defineOwnProperty 仍借用
receiver／descriptor，因此仅在该构造窗口 pin 二者；defer／errdefer 按先解 pin、再销毁失败结果、
最后撤根的顺序清理。此显式短期 pin 不等于底层 property API 已完成根引用迁移。

新增回归覆盖 aged Promise 结果保活、九次 declared-only GC 的 coercion 顺序、包装构造分配 GC、
从首个分配失败逐项推进至成功的 OOM 清理，以及根代次耗尽。Debug／ReleaseFast 非测试程序
通过 heap limit 触发真实 GC + OOM，确认输入未回收且 pin 余额不变，随后可成功构造包装。
`zig build check`、waitAsync 定向 20/20、全量 2049/2049 通过；未运行聚合批门禁。

ToNumber／ToBigInt 字符串输入的无 GC 编码路径见 §8.17。上层 ToPrimitive 调用闭包、
Promise 无原型构造分支、property 原始借用及其他发布字段的屏障收敛仍需审查；
不能把本轮路径验证扩大成 V1–V6 全部完成。

### 8.17 V1-B：共用 UTF-8 编码和数值转换

先由回归复现 appendValueUtf8 隐式展开 rope，再将该入口改为 StringValueIterator 叶片遍历。
flat Latin1 保留 ASCII 批量拷贝；UTF-16 叶片尾部的 high surrogate 暂存到下一叶片，
有效 pair 合并为四字节 UTF-8，孤立代理项保留原有 WTF-8 三字节编码。尾缓冲和已缓存 flat
使用同一 iterator 规则，不为编码创建新堆字符串。

toNumberValue 只对 flat Latin1 走直接 parseJsNumberLatin1；其他字符串经上述原生缓冲解析。
appendRawString／core.value_string 的字符串分支，以及 ToBigInt 字符串解析因此共用无 GC 路径。
“无 GC”不等于“无分配”：输出及 BigInt limbs 仍可在 nativeAllocator 上增长并返回 OOM。
没有要求调用方为纯读取额外创建根，也没有将 GC 错误改成成功回退。

逐项分配故障注入另行复现：BigInt limb 分配的 OutOfMemory 曾被 broad catch 变成 SyntaxError。
现在显式区分 OutOfMemory、BigIntTooLarge 和 InvalidBigInt，不吞掉资源错误。

新增测试覆盖 147 种叶片／尾缓冲／缓存组合、Latin1 与 UTF-16 混合、跨叶片及孤立代理项、
输出缓冲 OOM、负零／Unicode whitespace／radix／Infinity／NaN 和 BigInt 大整数。
有输出容量时验证编码不新增分配；所有借用路径检查 collection epoch 不变和 rope 不被物化。
非测试根契约程序在 heap limit 为零时运行 UTF-8 编码、ToNumber 和 ToBigInt，验证允许的原生
分配不引入隐藏 GC。其他 asStringBody 使用点、值 facade 分层及 V3–V6 仍未全部迁移。

最终 `zig build check test -j32 --summary all` 成功：引擎测试运行命中成功缓存，CLI 58/58；
Debug／ReleaseFast 非测试程序均通过。最初一次定向编译因并行 parser 编辑报告
`file contents changed during update`，已在后续完成检查中消除；未把该次中断算作通过。

JSON 共用的 `core.json.appendJsonStringValue` 也已移除隐式展平，直接在 NoGcScope
内逐叶片转义。跨叶片代理对输出完整 UTF-8，孤立代理项保留 JSON 的 `\udXXX` 转义。
回归先复现旧实现会展平 rope，再覆盖 20 个切分位置、零 JS 分配预算及逐次原生输出
扩容失败；失败保留 OOM，调用方释放部分输出后原生字节计数复原。非测试程序覆盖 flat、
rope、已缓存 rope、切片的成功与 OOM，检查无隐藏 GC 和根帧残留。
本轮定向测试 6/6，全量 check/test 13/13 步、2131/2131 测试，Debug／ReleaseFast
契约程序均通过。

JSON.parse／parseWithRecord 随后改为在解析前取得原生 WTF-8 快照，完整解析从该快照
解码原生 UTF-16 缓冲；快速路径回退不再读取可能已经回收的 JS 字符串，也不再隐式展平。
解析器的 global、递归对象／数组和待安装子值使用始终登记的实际槽位，递归返回后重读对象。
分配点精确 GC 回归另复现 ObjectShapeSummaryMismatch：构造器的临时 Shape 根在首个
安全点后提前撤销，后续存储分配可回收尚未被对象持有的 Shape。三个调用该构造安全点的
入口现将 Shape 根保留至发布完成，原检查器保留。

新增回归覆盖原码元／孤立代理项和 record.source、快路径回退、嵌套数组／对象、重复键的
旧 record 保活、输入快照 OOM 及根帧清理。非测试程序覆盖默认／nursery 配置下无调用方根
的普通解析与构造 OOM；这不等价于证明所有解析对象均实际搬迁。最终定向 11/11、全量
check/test 13/13 步及 2135/2135 测试，Debug／ReleaseFast 契约程序通过。
reviver 的解析入口、递归遍历、context 构造与结果写回现使用始终登记的可更新值槽位；
属性键及枚举快照在递归回调期间登记 atom 根，回调后从槽位重读接收者。
非测试契约程序的 24 组用例覆盖默认／nursery、保留／删除／替换结果及三个回调位置的
失败，并要求实际 GC；nursery 用例另外要求观察到接收者搬迁。重复键的旧 record 子树
将接收者与只读 context 参数固定的页分开，避免仅开启 nursery 却未发生搬迁的空验证。
JSON 定向测试 17/17、全量 check/test 13/13 步及 2135/2135 测试通过，Debug／ReleaseFast
契约程序通过。

JSON.stringify 的入口与属性列表／gap 转换现使用始终登记的可更新值槽位；属性列表在
构建及后续转换、序列化期间登记 atom 根。回归先复现 replacer getter 强制 GC 丢失待
序列化对象，再覆盖删除已读取键、gap 的 valueOf 再入 GC、两个回调位置失败及实际搬迁。
字符串键按叶片编码后 intern，不再隐式展平。gap 先在无 GC 窗口复制至多十个 UTF-16
码元，再编码为原生 WTF-8；修复第十个高代理项和孤立代理项被丢弃，失败释放临时输出。
验证包含所有 12 个 rope 切分位置、flat／rope／cached rope／slice、零 JS 分配预算、
原生分配失败和根退栈；六个端到端语义用例与本地 QuickJS 输出一致。
最终 JSON 定向 22/22、全量 check/test 13/13 步及 2140/2140 测试通过，Debug／ReleaseFast
契约程序通过。

stringify 递归路径随后复现：普通对象在第一个 replacer 回调中搬迁，第二次属性读取
错误抛出 TypeError。SerializeProperty、AppendValue、AppendArray、AppendObject 现登记
实际可更新槽位并在回调后重读对象；枚举快照和当前键登记 atom 根。VM 循环检测栈改存
JSValue，入口追踪实际 `stack.items`，覆盖原生数组扩容后的槽位。无回调快路径的裸指针
栈仅在 NoGcScope 内使用，退出读取窗口后才创建结果字符串。
新增非测试契约的 50 组用例覆盖默认／nursery、对象／数组嵌套、16 层栈扩容、搬迁后
返回祖先形成循环、toJSON getter／方法、属性 getter、删除后续键、重入及各阶段失败；
nursery 用例必须观察到实际搬迁。共享子对象不误判循环及循环错误后继续序列化的输出
与本地 QuickJS 一致。最终 JSON 定向 23/23、全量 check/test 13/13 步及 2141/2141
测试通过，Debug／ReleaseFast 契约程序通过。

原生兼容 stringify 入口、递归和属性列表随后完成实际可更新根迁移，循环栈也追踪
`stack.items`。保留原生读取语义：不调用 JS getter／toJSON／replacer，但 AUTOINIT 和
exotic ownKeys 仍可 GC／失败。回归先复现未登记输入被回收，再覆盖 24 组非测试用例：
默认／nursery、对象／数组、循环、宿主钩子失败、继承 AUTOINIT、ReferenceError 原样传递
和重试；可搬迁祖先要求实际搬迁。另验证 rope 属性键去重与 gap 孤立代理项。
该批全量 2143/2143 测试及 Debug／ReleaseFast 契约程序通过。

rawJSON 构造在实际堆限额下复现 LostRawJsonResult：结果文本分配触发 GC，已创建的
结果对象因生产构建不登记标量根而被回收。现先完成无 GC 的原生输入快照，再以实际
可更新根持有结果对象和文本，分配后重读对象。原生输入读取移除旧标量根，保留 NoGcScope。
12 组非测试用例覆盖默认／nursery、flat／rope、验证及文本分配 OOM、同 Runtime 重试、
后续 GC 和结果描述符；另验证 11 个 rope 切分位置与原生分配失败清理。

限额回归同时复现 BitmapReclaimLeakedHeapBudget：生产构建批量回收小块载体后未归还
JS 堆预算，导致错误 OOM。GC 现按实际回收数批量扣减；逐对象审计／remembered 路径
保留原有扣减，避免重复。独立非测试回归覆盖 major／minor、存活邻居、多块回收、重复
分配回收和需弱身份清理的析构对象。最终 JSON 定向 27/27、堆预算定向 6/6、全量
check/test 13/13 步及 2145/2145 测试通过，Debug／ReleaseFast 契约程序通过。
共用 CallSite／调用交接、未覆盖的代理交接、其他模块的隐式物化调用及 V3–V6 其余
验收仍未完成。

### 8.18 V1-B：禁止 GC 借用窗口

新增 runtime.NoGcScope：Debug／测试构建在 Runtime 上登记最终地址，支持嵌套，
退出检查 LIFO 和原始地址，拒绝重复激活；非测试 Release 构建抹除 scope 和 Runtime 链字段。
它不充当根或 pin，不阻止显式修改原生缓冲，也不延长借用生命周期。

tryRunObjectCycleRemovalWithValueRoots、pollGC、gc_driver.continuePoll、
collectCycles、collectMinor、destroyDoomedSlice、finishPendingDestruction
均在 collector 状态变更及提前返回之前检查；Runtime 销毁检查仍活动的 scope。
违规请求直接 panic，不用静默跳过回收维护表面的安全。

appendValueUtf8 的 flat／rope 借用读取窗口已接入，保留 nativeAllocator 增长及 OOM 行为。
新增回归覆盖嵌套、原生分配、错误退出、重复使用、不同 Runtime 隔离，以及退出后实际回收。
单一诊断构建提供 11 个注入点，分别验证上述七个入口、销毁、乱序退出、复制退出和重复激活。
非测试根契约程序另检查 Debug 登记和 Release scope 零字节布局。

验证：`zig build check test -j32 --summary all` 13/13 步成功，2054/2054 测试通过
（引擎 1996、CLI 58），Debug 非测试根契约程序通过；ReleaseFast
`test-exact-roots` 4/4 步通过。11 个注入点均经 `zig build test -Dtest-filter='no-GC scope'`
验证为预期 panic，未以其他断言失败代替；`git diff --check` 通过。

这只落实上述窗口与入口；其他借用读取尚未统一接入，V0 全局清单和 V1–V6 剩余要求仍待收口。

### 8.19 V1-B／V4：padding 的转换根与叶片复制

两条新增回归在修改前失败：stringPad 的源字符串在 ToLength 的用户回调内执行精确 GC 后
已不在活堆中；无需补齐的 rope 输入也因 asStringBody 被提前物化。前者由宿主探针在重新
使用失效切片之前检测，后者直接检查 rope 的 linearized 状态。

现在 stringPadRooted 在首个转换前登记 source、maxLength、fillString 和 global 四个精确根。
转换结果原位写回；每次调用后重新从根读取值，后续不再读取调用方 args 存储。
长度直接取 flat／rope 元数据。仅在确实需要补齐时转换 fillString，并保留空 filler 提前返回。
根登记的 generation 耗尽映射为 OOM，内部根使用错误仍作为契约违规报错。

StringBuffer.appendStringPrefix 在 NoGcScope 中逐叶片复制指定数量的 UTF-16 code units，
支持 Latin1、宽字符、孤立代理项、跨叶片和中途截断；appendStringValue 共用该实现。
source 与 filler 可以是同一 rope，不再隐式展开。原生缓冲可分配并返回 OOM；finish 才分配
结果堆字符串，此时所有叶片借用已结束，仅使用缓冲拥有的数据。错误和正常返回的清理只释放
原生缓冲与根帧，不包含后续 GC。

语义依据为 [ECMA-262 StringPaddingBuiltinsImpl 与 StringPad](https://tc39.es/ecma262/multipage/text-processing.html#sec-stringpaddingbuiltinsimpl)：
ToString(receiver) → ToLength(maxLength) → 提前返回判断 → ToString(fillString) → 按 code units 补齐。
测试覆盖回调中的两次精确 GC、转换顺序、nullish 拒绝、异常传播、默认／空 filler、
Infinity 配空 filler、Latin1、高代理项截断、rope 别名，以及原生缓冲和最终结果分配 OOM。
同一语义 fixture 在本地 QuickJS `/home/aneryu/quickjs/qjs` 通过；参考二进制 SHA-256 为
`5741f6bc79ca7164ed3109dd0ed0c6e3189ad1c0c4038c266b3731b8b11ec17d`，没有观察到这些案例的语义差异。

非测试根契约程序覆盖零堆限额下的无物化提前返回、结果分配触发 GC 后 OOM，以及解除限额后重试。
最终 `zig build check test -j32 --summary all` 13/13 步成功，2057/2057 测试通过
（引擎 1999、CLI 58），Debug 非测试根契约程序通过；ReleaseFast `test-exact-roots` 4/4 步通过。
`git diff --check` 通过。最初定向回归的两项失败为修改前证据；迭代中的一次 helper 参数编译错误
已修复，最终检查覆盖修复后的调用点。
这不替代 RegExp split／fast replace 和通用 ToPrimitive 调用闭包的剩余审计；concat 的后续迁移见 §8.20。

### 8.20 V1-B／V3-A：concat 值槽与分配后复制

修改前两条定向回归失败：后续参数 ToString 回调执行精确 GC 时，直接路径先前转换的字符串
已被回收；rope 拼接还会调用 asStringBody 隐式物化。原先大参数路径虽登记了转换结果数组，
仍在所有物化完成前保存 ResolvedData；原始参数也没有统一的可回写快照。

stringConcatRooted 现在将 receiver 与所有原始参数复制到同一可写值数组，登记 mutable slice 根，
然后逐槽 ToString 并写回。32 个以内的部件保留栈内存，超过时使用一次 native 分配；global
由独立精确根保护，回调后重新读取。零参数直接交接转换后的 receiver，不额外分配结果。

新增 String.createConcatParts：接收 string／int32 值槽，在实际槽位上登记根；先计算长度和宽度，
只分配一个结果，再从 GC 更新后的槽位读取 flat／rope 内容。NoGcScope 包住复制阶段，
Latin1 直接 memcpy，宽结果按 code units 拷贝／扩展，不隐式展开 rope。int32 用栈缓冲格式化，
保留 primitive concat 快速路径不创建中间数字字符串的行为。原 primitive 路径也迁移到该入口，
不再让保存的字符串切片跨结果分配。旧 createLatin1Parts／createResolvedParts 已无内部调用方，
保留为 owned-native／显式 pinned backing 的兼容入口，其约束写在函数契约中。

测试跨越 31／32 个参数边界并覆盖 40 参数、大量连续 ToString 内的精确 GC、共享 rope 输入、
Latin1／UTF-16／孤立代理项、int32 两端值、零参数、nullish 和 Symbol 拒绝、转换顺序与抛错后停止。
分配重入测试复用原 tail-buffer 对抗探针：嵌套物化后回收旧缓冲、用实际 allocator 复用并填充旧地址，
concat 仍从新 cache 复制正确内容。OOM 覆盖大参数原生数组和最终堆结果，检查根链恢复及输入可重试。

语义依据为 [ECMA-262 String.prototype.concat](https://tc39.es/ecma262/multipage/text-processing.html#sec-string.prototype.concat)。
同一语义 fixture 在本地 QuickJS `/home/aneryu/quickjs/qjs` 通过（参考二进制同 §8.19），
这些转换顺序／格式化案例未观察到差异。非测试根契约程序直接传未登记的 native 数组，
由 callee 独立保护，并使用真实 GC 阈值入口验证回收。最初误用测试专属 probe 的非测试验证失败，
该失败不算通过；已将验证改为阈值触发并要求 collection epoch 增长。

最终 `zig build check test -j32 --summary all` 13/13 步成功，2062/2062 测试通过
（引擎 2004、CLI 58），Debug 非测试根契约程序通过；ReleaseFast `test-exact-roots` 4/4 步通过。
`git diff --check` 通过。原有 flatten 重入测试保留，与新增 concat 重入测试共用同一对抗探针。
本项关闭 concat 的上述值槽／借用缺口；不将字符串当前地址稳定的验证外推为所有 heap kind 的搬迁证明，
RegExp split／fast replace、其他 facade 调用及 V3–V6 的剩余要求继续保留。

### 8.21 V1-B／V4：切片构造和数值参数转换

修改前分别复现三处缺口：stringSliceValue 的完整范围返回也隐式展开 rope；String.createSlice
在分配触发精确 GC 并返回 OOM 后丢失未由调用方登记的父字符串；slice／substring 的索引对象
执行 valueOf 回调并回收时，先前 ToString 生成的源字符串已死亡。

String.createValueSlice 现在自己登记可更新的源值槽，按 code-unit 范围决定结果宽度，然后分配
结果并重新从源槽取叶片复制。两个读取阶段各有 NoGcScope，借来的 chunk 不跨分配；范围内
全为 Latin1 的宽父串子串仍窄化。String.createSlice 委托此入口，保留原先 eager flat copy 契约。
私有 StringRangeIterator 只遍历所需范围，支持 flat、rope、cached flat 和 tail buffer。

exec.stringSliceValue 使用长度元数据处理整段／空段／单字节返回，只在需要时构造部分拷贝。
范围计算改用 min(len, input_len - start)，避免 start + len 的 usize 溢出。
substringReceiver／sliceReceiver 使用纯值投影；fastLatin1Substring 只投影 flat，构造结果也
经过根保护入口，不再将 borrowed bytes 交给分配器。

stringNumericArgsMethod 的共用转换段现在先登记 receiver、global 和两个参数，转换回调后从根
重新读取源值／global。转换后的数值和 undefined 是 immediate，不需要额外保活；根帧覆盖
下层结果构造和错误消息生成，清理不 GC。这不宣称该入口所有其他方法的内部借用已经迁移。

回归覆盖 tree／cached rope 的 160 组起点／长度、最大 usize、跨叶片代理项、窄化、slice／substring
直接调度不物化、两种方法索引回调中的四次精确 GC、OOM 保持父值和重试。切片分配也复用
tail-buffer 对抗探针：重入物化并回收、复用旧地址后，结果必须仍为原范围内容。
非测试根契约程序通过生产 GC 阈值和零堆限额分别验证成功／失败期间的父值保活。

code-unit 切片依据 [ECMA-262 String.prototype.slice](https://tc39.es/ecma262/multipage/text-processing.html#sec-string.prototype.slice)。
同一 slice／substring／substr 语义 fixture 在本地 QuickJS（参考二进制同 §8.19）通过，
覆盖代理项拆分、负数／无穷／NaN 边界和交换端点，未观察到这些案例的差异。

最终 `zig build check test -j32 --summary all` 13/13 步成功，2067/2067 测试通过
（引擎 2009、CLI 58），Debug 非测试程序通过；ReleaseFast `test-exact-roots` 4/4 步通过。
`git diff --check` 通过。迭代中的 slice-header 类型、comptime 根索引、optional 返回类型错误和
一个切片预期值笔误均已修正；以上最终结果覆盖修正后的代码，不将修改前回归失败算作通过。
string_view 和 RegExp fast replace 的后续迁移见 §8.22；RegExp split 及 V3–V6 剩余范围仍未完成。

### 8.22 V1-B／V4：UTF-8 输出与 RegExp 快速替换

`JSString.fromFlatValue` 是纯投影；`Utf8.fromValue[Cesu8]` 对 rope 直接遍历叶片，
不再隐式展平。`valueToOwnedUtf8` 用实际可写槽保护源值，计数与写入分别处于
NoGcScope，输出分配位于两者之间，允许调用者分配器触发 GC；分配后重新解码源值。
`Context.toOwnedUtf8` 使用此入口，`Context.toString` 在取得 global 前保护输入。
测试覆盖跨叶代理对、CESU-8、OOM 保持 rope 未展平以及 flat／rope 输出分配期间的精确 GC。
旧 `JSValue.asString`／`JSString.fromValue` 仍是显式注明的物化兼容入口；借用 view 的
`toOwnedUtf8Cesu8` 仍要求调用者维持源值存活，不能将新入口的自有根保证推广到旧 API。

`regExpReplaceFast` 的 OOM 用例在旧实现中复现 `flattenInfallible` panic。
现用四个精确根保护 regexp、source、replacement 和 global，两次 `ensureFlat` 完成后
才重新取得 regexp、字节码及字符串视图。匹配与替换缓冲写入处于 NoGcScope，结束借用后
才创建结果字符串。源／替换两处 OOM 均传播并可重试；无调用者根的阈值触发 GC 用例通过。
非测试根契约程序也覆盖该调用，不依赖测试构建中的标量根 helper。

本轮 `zig build check test -j32 --summary all`：13/13 步、2071/2071 测试通过
（引擎 2013、CLI 58），包含 Debug 非测试根程序；ReleaseFast `test-exact-roots` 4/4 步通过。
`git diff --check` 通过。RegExp generic split 的后续迁移见 §8.23；其他隐式物化
调用闭包以及 V3–V6 的完整验收仍待完成。

### 8.23 V1-B／V4：generic split 的分配与回调根窗口

`regExpSymbolSplitGeneric` 不再通过 `asStringBody` 隐式物化。入口先登记 global、source、
splitter、output、exec result 和 temporary 六个实际槽位，再创建结果数组；Unicode 推进
直接读 rope 码元。每次用户回调／属性读取之后从根重取值，切片创建完成后再取得输出数组地址。
错误退出撤销根，由 GC 回收未发布的结果数组，不对回调前的旧指针执行手工销毁。

`regExpExecGeneric` 同时保护其 global、接收者、字符串和 method 四个值；读取 `exec` getter
之后使用更新后的槽位进入调用。它的 mutable slice 根在非测试构建中也实际登记。

修改前用例复现 split 入口隐式展平；修改后覆盖跨叶代理对、入口数组分配期间的精确 GC、
源 rope 不展平且无匹配时保持完整值身份、OOM，以及 exec／lastIndex／length／capture getter
和数值转换中的 14 次 GC 回调。非测试程序覆盖实际 GC 阈值触发的入口分配。
`zig build check test -j32 --summary all` 13/13 步、2073/2073 测试通过（引擎 2015、CLI 58），
含 Debug 非测试根程序；ReleaseFast `test-exact-roots` 4/4 步及 `git diff --check` 通过。
这里只证明这两个驱动函数及上述序列；上层 species／flags 的后续迁移见 §8.24。
其余值 facade 调用和 V3–V6 的整体验收仍未完成。

### 8.24 V1-B／V4：@@split 转换链与 ASCII 后缀

精确 GC 回归在旧 `regExpSymbolSplit` 中确认：ToString 新建的源字符串在 species getter
收集后已离开堆注册表。入口现用七个精确根覆盖 global、receiver、source、limit、constructor、
flags、splitter；首次回调前复制两个参数，回调后重新取值。species 与 flags 共用助手使用
始终登记的 mutable slice 根，保护默认构造器、getter 结果及后续转换输入。

`appendAsciiSuffixOwned` 改用 `String.createValueAsciiSuffix`，不再隐式展平并把裸切片传入
分配器。新构造器保护 source，分配最终字符串后重新读取 rope／flat／tail-buffer 内容，
复制窗口禁止 GC；ASCII suffix 必须是调用者持有的 native 存储，本调用链传入字面量 `"y"`。
旧 ResolvedData 构造器保留明确的 owned／pinned 兼容前提。

测试覆盖五个 species／flags／constructor／limit GC 回调、参数数组被源转换回调复用、
rope 不物化、OOM 后重试，以及重入展平后旧 tail buffer 被回收并复用。非测试根程序覆盖
@@split 入口的真实 GC 阈值和宽字符串后缀 OOM／重试。
`zig build check test -j32 --summary all`：13/13 步、2077/2077 测试通过（引擎 2019、CLI 58），
包含 Debug 非测试根程序；ReleaseFast `test-exact-roots` 4/4 步及 `git diff --check` 通过。
其他 RegExp 驱动、通用调用／构造内部与 V3–V6 仍须各自完成审计；
不能将上述定向序列推广为整个引擎的移动安全证明。

### 8.25 V4：@@search／@@match 的转换与驱动根

两条精确 GC 回归分别在旧 search／match 中确认转换后的源字符串被回调收集。
两者现通过共用的、始终登记实际槽位的入口完成 ToString，再交给各自驱动。
search 用五个精确根保存 realm、receiver、source、旧 lastIndex 和 exec result；
回调后重取值再比较、恢复 lastIndex、读取 index。全局 match 用六个精确根保存输入、
结果数组、exec result 和临时匹配值，覆盖 getter、ToString 和空匹配索引推进。
`advanceStringIndexNumber` 也保护自身参数，在 ToLength 回调之后重新取得字符串值。
未发布的 match 数组随根撤销交回 GC，不再用回调前的数组地址执行销毁。

search 回归通过七次 GC 回调，旧 lastIndex 为仅由算法暂存的新对象；match 回归通过
十三次回调，验证普通／空匹配两项结果和跨 UTF-16 代理对推进。非测试程序分别通过
真实 GC 阈值进入两条驱动，验证没有调用者根时输入仍存活。
`zig build check test -j32 --summary all` 13/13 步、2079/2079 测试通过（引擎 2021、CLI 58），
含 Debug 非测试根程序；ReleaseFast `test-exact-roots` 4/4 步及 `git diff --check` 通过。
matchAll、generic replace 等其他驱动和 V3–V6 仍未全部收口。

### 8.26 V4／V5：@@matchAll 构造与迭代器发布

精确 GC 用例在旧 `regExpSymbolMatchAll` 中再次确认 ToString 结果在 species 回调后被回收。
入口现用七个精确根覆盖 realm、receiver、source、constructor、flags、matcher 和临时值；
flags 读取复用受根保护的助手，getter／构造器／数值转换后重取槽位。迭代器原型和实例
先放入临时根，再通过已有 owner-aware 屏障安装 matcher 与 source，最后交接结果。

`regExpStringIteratorPrototype` 保护 prototype 与 next 函数；共用 `iteratorPrototype` 和
`defineToStringTag` 保护新建对象，在 tag 字符串分配之后重新解码 owner。失败时撤销根，
不使用分配前的旧对象指针做手工销毁。

回归覆盖构造至首次 next 的十次 GC 回调、发布后收集、原型每次堆分配前的精确 GC、
tag OOM 和重试。非测试根契约沿用其启用 nursery 的配置，在真实阈值触发后发布迭代器，
再次精确收集并确认 matcher／source 边仍在；这不替代 V6 完整搬迁与失败恢复矩阵。
`zig build check test -j32 --summary all` 13/13 步、2081/2081 测试通过（引擎 2023、CLI 58），
包含 Debug 非测试程序；ReleaseFast `test-exact-roots` 4/4 步及 `git diff --check` 通过。
String.prototype.matchAll 的上层分派、迭代器 next 的完整回调闭包、
generic replace 及 V3–V6 剩余要求仍未完成。

### 8.27 V4／V5：RegExp iterator next 与结果包装

旧 `regExpStringIteratorNext` 的 exec result 在匹配字符串 ToString 回调的精确 GC 中被回收，
回归通过堆注册表检查复现。next 现以六个精确根持有 realm、iterator、matcher、source、
exec result 和 temporary；matcher／source 使用独立快照，回调后及完成结果分配后重新获取
iterator 地址。创建完成结果成功后才写完成状态并清除 target／data，保留既有失败顺序。

共用 `createIteratorResult` 将测试专用标量根改为始终登记的 mutable slice，覆盖可选 realm、
待包装 value 和正在构造的结果对象；写属性前从实际槽位重取对象，失败后交由 GC 回收。
非测试程序通过零堆限额触发收集，确认待包装字符串存活、OOM 根帧退出及重试成功。

next 回归覆盖 exec result 在三次 GC 回调中存活、空匹配跨代理对推进、正常完成和重复完成。
另一回归验证完成结果 OOM 时 index 仍未完成、两条边保留，重试后两条边清除且根帧无残留。
`zig build check test -j32 --summary all` 13/13 步、2083/2083 测试通过（引擎 2025、CLI 58），
含 Debug 非测试根程序；ReleaseFast `test-exact-roots` 4/4 步及 `git diff --check` 通过。
本轮未扩展 next 的重入语义矩阵；String.prototype.matchAll 分派、
generic replace、其他 iterator 驱动与 V3–V6 仍未全部收口。

### 8.28 V1-B／V4：URI 码元读取与转换根

[URI 操作](../src/exec/uri_ops.zig) 已移除全部 `asStringBody` 隐式物化调用。
encodeURI／encodeURIComponent 在 NoGcScope 中遍历叶片，跨叶片保留待配对的高代理项；
读取结束后才构造 URIError 或结果字符串。escape／unescape 共用无 GC 的原生码元复制。
rope 解码先检查百分号，无转义时直接返回输入，否则复制 UTF-16 码元后解码；
flat 解码保留原有快速路径，输入读取在结果／错误分配前结束。
对象 ToString 分派期间，realm global 和输入／转换结果由实际精确根槽持有，回调后重新读取。

回归先复现了 URI 操作意外展平 rope，再验证六个入口、跨叶片代理对、保留字符、
cached rope、未配对代理项、JS 堆及原生缓冲 OOM 与作用域清理。
非测试契约以未根化输入、关闭保守扫描、零 GC 阈值／零堆限额，验证输出分配时的收集与失败窗口；
Debug 和 ReleaseFast 均通过。URI 定向测试 13/13，全量测试 2125/2125、编译检查通过；
测试构建条件修正后重新运行 check/test，复用未变的引擎测试缓存并通过非测试契约。
JSON 等其他隐式物化调用，以及 V3–V6 的剩余验收仍未完成；Date 的后续迁移见 §8.29。

### 8.29 V1-B／V4：Date 字符串读取与数值转换根

[Date 操作](../src/exec/date_ops.zig) 已移除两处 `asStringBody` 隐式展平。
日期解析直接遍历叶片，复制最多 127 个码元到栈缓冲后执行日历转换；
保留 U+2212 映射、原有截断及数字字符串宽度策略。纯构造入口先计算毫秒值，
再分配 Date 对象，避免结果分配的 GC 先回收尚未读取的字符串／Date 参数。

回归还复现了 setter 的 `valueOf` 回调执行精确 GC 后，Date 接收者被回收。
setTime、setYear、captured setters、UTC／本地字段 setters 和 Date.UTC 数值转换
现以始终登记的 mutable slice 保存 realm、接收者及有限参数快照；转换后从实际槽重读，
保留转换顺序、参数数量上限和转换前的毫秒快照。Date.UTC record 共用该转换入口。

VM 构造入口现登记 prototype 和后续参数；toJSON 登记接收者与 toISOString 方法。
Date 普通 ToPrimitive 与公共转换入口在每次回调后重读实际槽位，公共方法调用入口
同样登记 getter 返回的方法；Symbol.toPrimitive 路径登记方法和 hint，覆盖 getter、
hint 分配、方法调用及普通转换回退之间的存活窗口。回归先复现构造 prototype 被回收，
再复现 getter 搬迁后调用使用旧接收者；这些缺陷已在所属公共入口修复。

Date 定向测试 11/11，全量 check/test 13/13 步、2129/2129 测试通过。
非测试契约在 Debug／ReleaseFast、默认／nursery 模式下验证接收者与后续参数保活、
后续参数实际搬迁、转换失败时 Date 值不变及根帧清理；另覆盖无调用方根的构造分配／OOM。
新增构造／toJSON／普通与 Symbol.toPrimitive 多阶段回调契约，检查实际搬迁、调用顺序、
hint、逐阶段失败和根帧清理。JSON 迁移和 V3–V6 剩余要求仍未完成。

### 8.30 V1-B／V4：核心值读取与数值解析

[ToBoolean](../src/core/value_semantics.zig) 直接读取字符串码元长度；
[集合前缀查找](../src/core/collection.zig) 保留 flat 比较，rope 按叶片比较。
两者不再通过 `asStringBody` 隐式物化。[数值解析](../src/core/number.zig) 保留
flat Latin1 借用快路径，其他字符串使用可失败的原生快照；不通过展平隐藏 OOM／GC。
三条路径均先复现旧实现会物化 rope，再验证零 JS 堆预算下的读取。

非测试回归复现 LostParseIntConvertedString：输入 ToString 已返回，radix 的 valueOf
强制 GC 回收了待解析字符串。[globalParseInt](../src/exec/builtin_glue.zig) 现以实际
可更新槽位持有 global、输入／转换结果及 radix，转换后重新读取。
另复现 LostBareNumberArray：裸 Runtime 数值转换的数组属性读取触发 AUTOINIT，
数组自身被回收。[共用数组渲染](../src/core/value_string.zig) 现登记数组和当前元素，
递归／属性读取后重新获取数组；parseIntValue 同时保护尚未消费的输入与 radix。
这条原生兼容路径仍使用 core 属性读取，不调用 JavaScript ToString。

非测试契约覆盖 12 组 parseInt 回调序列（默认／nursery、flat／rope 返回值、两阶段
失败、radix 回调重入 parseFloat）、16 组裸 Runtime AUTOINIT 转换及 ReferenceError
传递，以及 flat／rope／cached rope／slice 的零 JS 预算、原生 OOM 和根退栈。
字符串与 Array 依现行载体策略保持稳定地址；这些用例不扩大可移动类型保证。
单测另覆盖空串／NUL／孤立代理项真值、Unicode 空白、数字前缀跨叶片、舍入、负零、
集合线性／哈希索引查找与缓存状态；端到端转换顺序及解析结果与本地 QuickJS 一致。
值边界定向 14/14、数值解析定向 9/9、最终 check/test 13/13 步及 2150/2150 测试通过，
Debug／ReleaseFast 非测试契约程序和 `git diff --check` 通过。
其他隐式物化调用、共用 CallSite 交接及 V3–V6 剩余验收仍未完成。

### 8.31 V1-B／V4：URI 探测与原生分派名称

[核心 URI 探测](../src/core/uri.zig) 已移除隐式展平：flat 直接读取，窄 rope 仅在
长度为 12 时复制到栈缓冲区。回归先复现只读探测会物化 rope，再验证跨叶片转义、
非法编码、cached rope、零 JS／原生分配预算及 NoGcScope；定向测试 6/6 通过。

[名称投影](../src/exec/call.zig) 现在只返回 atom 或 flat Latin1 借用，rope（包括
已有 flat 缓存的 rope）返回 null，不再隐式物化。[实际调用和构造入口](../src/exec/call_runtime.zig)
已迁移：内部字符串 atom 在整个分派期间由原始 ID 根持有；可见名称在回调前复制到
可失败的原生快照。旧 callable 分支仍只读取 own data，缺失、非字符串和 wide 名称
仍不分派；rope 名称继续可调用。构造分支保留既有属性读取及 UTF-8 转换规则。
Symbol atom 的描述也使用快照，因为物化 Symbol 会更换描述的底层存储，单独保活 ID
不足以保护旧切片。名称引用不再使用引用计数式释放说明。

非测试回归先复现 LostDispatchNameSnapshot：参数转换回调删除可见名称、GC 回收并复用
字符串单元后，SharedArrayBuffer 构造错误地返回普通 ArrayBuffer。修复后验证 12 组
默认／nursery、flat／rope／cached rope、成功／回调 OOM 场景，包含重入 parseFloat、
实际单元复用和根作用域清理。OOM 注入必须确实执行，并按托管回调协议传出带 OOM
标记的 JSException。定向测试另覆盖原生快照分配失败、旧名称调用和 Symbol 描述物化。

名称定向测试 10/10、最终 check/test 13/13 步及 2155/2155 测试通过；
Debug／ReleaseFast 非测试契约程序通过。字符串包装、数组长度转换等其他隐式物化调用，
以及 V0 全局清单、CallSite 交接和 V3–V6 剩余验收仍未完成。

### 8.32 V1-B／V4：原始值包装与数组长度转换

[属性访问包装](../src/exec/object_ops.zig) 的字符串分支现在复用
[String 构造路径](../src/exec/string_ops.zig)，按码元读取输入并保护未完成的包装对象。
字符属性写入共用精确根实现，保留 Latin1 单字符缓存和原有属性描述符；长度属性
直接从构造根取 owner。旧的隐式展平分支和仅供该构造使用的标量根 helper 已移除。

非测试回归先复现 LostPrimitiveBoxingInput：构造 BigInt 包装对象的分配触发 GC，
尚未安装到 objectData 的输入被回收。[调用包装](../src/exec/call.zig) 与属性访问包装
现使用始终登记的实际值槽；构造记录仍接收原型快照，其交接窗口另外以 borrowed 根
保持输入地址稳定。失败的已发布对象交给 GC 回收。
32 组非测试场景覆盖两个入口、默认／nursery、heap／short BigInt、Symbol、负零、
Boolean 和 flat／rope／cached rope 字符串，检查输入存活、原型身份、字符描述符、
根退栈及结果在后续 GC 后的存活。单测覆盖代理项跨叶片、NUL、Latin1 缓存，以及
会实际触发分配的 256 字符包装失败序列；小样本复用存储、未发生注入失败，未作为
OOM 证据使用。

[核心数组长度转换](../src/core/object.zig) 已改为 NoGcScope 中按叶片复制原生缓冲，
保留原有 ASCII 转换范围。先复现旧实现会展平 rope，再验证跨叶片数字、边界长度、
非法值、boxed String、原生 OOM 时长度不变、缓冲清理及零 JS 堆预算。
非测试读取窗口另覆盖 flat／rope／cached rope／slice 的未根化输入，失败后重试成功，
GC epoch 和原生字节计数保持不变。

包装定向 10/10、数组长度定向 9/9、最终 check/test 13/13 步及 2160/2160 测试通过；
Debug／ReleaseFast 非测试契约程序通过。集合字符串分组、字符串拼接与宿主输出的
借用审查，以及 V0 全局清单、CallSite 交接和 V3–V6 剩余验收仍未完成。

### 8.33 V4：Object 构造器的描述符、键与结果根

[Object 构造器路径](../src/exec/object_ops.zig) 的 getOwnPropertyDescriptor／
getOwnPropertyDescriptors、assign、fromEntries、groupBy、hasOwn 与属性键转换，
以及 [defineProperties 批量定义](../src/exec/call_runtime.zig)、
[数组 length 定义转换](../src/exec/array_ops.zig) 和描述符对象互转，现以始终登记的
实际值槽持有 global、参数、原始值包装结果、输出对象与正在安装的描述符对象；
own keys 由 borrowed atom 根持有。每个可能执行 getter、proxy trap、AUTOINIT 或分配的
调用之后都从槽位重新取得对象指针。已创建的结果对象属于已发布对象，失败时交给 GC
回收，不再以 errdefer 直接销毁。

非测试契约先复现 LostDescriptorConversionValue、LostBulkDescriptorRoot／Target、
LostArrayLengthConversionReceiver、LostObjectAssignRoot、LostOwnPropertyConversionRoot、
LostObjectGroupByItem 与 LostDescriptorResultInput。getOwnPropertyDescriptors 的回归在
首个描述符安装后由 AUTOINIT 删除源属性与后续键并强制 GC：旧实现在 OOM 清理中对已回收的
输出对象执行 destroyFromHeader 并断言失败；修复后默认／nursery × 成功／OOM 四组场景
均保持已安装描述符、键 atom 与根帧完整，被删除的后续键不再出现在结果中。

Debug／ReleaseFast 非测试契约程序、`zig build check`、最终 `zig build test` 及
test262 `built-ins/Object` 3411/3411（含 getOwnPropertyDescriptors 18/18）通过。
描述符转换期间 `Descriptor` 局部副本在 materializeMappedArguments 与描述符对象创建之间
仍依赖该段无 GC；V0 全局清单、CallSite 交接和 V3–V6 剩余验收仍未完成。

### 8.34 V0 收口：四项全量静态审计

V0 余项按四个维度对当前工作区做了全量静态审计：堆遍历的全部强边（§8.3 所列十四个 RefKind、
Object 各 payload、generator／闭包／arguments／模块／realm）、全部根来源（Runtime 根遍历、
RootSet provider、各类根帧、job、ActiveInvocation 的每个 Frame 字段、宿主调度）、已发布载体的
全部堆引用写入，以及剩余字符串／字节借用窗口。审计只做源码判定；下列每个缺陷在修复前都另有
复现，复现与修复见 §8.35–§8.37。

| 维度 | 结论 |
| --- | --- |
| 强边访问方式 | 可搬迁目标（仅 Object 载体：普通对象、数组、slots2 对象）全部经真实槽位访问；临时副本只出现在 VarRef、FunctionBytecode、Realm、RegExp 字符串等不进 nursery 的载体上，且其中 auto_init realm、FB、RegExp 字符串带回写。缺陷不在访问方式，而在按地址索引的旁表：Map/Set 强索引与 iterator next 旁表 |
| 根槽位 | RootSet、handle、各类根帧、job、JSON／Replace／Descriptor／Module／Compile provider、一次性 timer 窗口均为真实槽位或已预先 pin。缺陷：`Vm.return_value` 仅靠生产构建丢弃的标量根；宿主先释放 context 后 EventLoop 回调失去根 |
| 写屏障 | 缺陷：开放闭包 cell 写入已挂起帧、子 realm 的 lexicals 与 bootstrap 字段、闭包 capture 填充、模块 capture／导出 cell 发布、unhandled rejection 列表、稠密数组冷路径追加 |
| 借用窗口 | 集合字符串分组、拼接、宿主输出的字符串借用均无跨 GC 点使用；宿主 `print` 打印 Map/Set／数组时回调改表导致读已释放存储（非字符串借用，同类缺陷） |

稳定载体清单（扩大 nursery 前必须先迁移到可回写槽位）：Frame／generator／闭包 capture／
mapped arguments 中的 VarRef 身份包装、Frame.function 的 FunctionBytecode 包装、RealmRecordPayload
与 auto_init 的 realm、RegExp source／compiled 字符串，以及 Shape／Realm／Module／String／Symbol／
BigInt／各 storage 载体本身。Promise、函数对象、集合、Proxy、typed array 等经 allocCell 分配的对象
同样不进 nursery；`HostInvocation` 单次路由缓存与 Machine 缓存的 global 依赖这一点，现以断言固定。

`callTypedInternalRecordDirect` 的接收者根是可写槽，被调用方收到的是参数副本。本战役的协议是
callee 把后续需要的接收者复制进自己的精确根并在回调后重读，§8.29 的 Date 契约即以此验证搬迁；
在分派处改为 pin 会让这些搬迁无法发生而掩盖 callee 缺陷，因此保持现状。生产构建另有原生栈扫描。
Shape 根表以原型地址哈希：原型被搬迁后同一原型会得到第二条根 Shape 谱系（已有谱系按存储的
父哈希查找，仍然一致），这是 nursery 模式下的内存／IC 代价，不是正确性问题，记为已知限制。

### 8.35 V5：写屏障缺口

`VarRef.setVarRefValue` 与解释器的 put／set var_ref 处理器原先总是记住 cell 自身。开放 cell
的 `pvalue` 指向帧存储：帧运行时该槽是根，但生成器／async 帧挂起后槽位属于 `cell.value`
所指的帧 owner，重扫 cell 只能到达已是老对象的 owner，minor 在此停止。现统一经
`VarRef.slotOwner` 记住真正的槽位 owner。回归在 declared-only minor 与致命审计下复现：
第二次 minor 报告 generator.locals 持有未记住的年轻对象；修复后生成器与 mapped arguments
两个变体均通过。

子 realm 在 create-ref 释放后不是根。`ctx.lexicals` 的四处写入改经 `RealmContext.setLexicals`；
bootstrap 的 global、预分配 OOM 错误和 `eval` 写入，`appendUnhandledRejection`，闭包 capture
填充循环（resolver 会分配，填充后补 `rememberOwnerForBulkWrite`），模块 capture 槽与导出 cell
发布（现接收 Runtime）以及稠密数组冷路径追加都补了屏障。`$262.createRealm` 回归在修复前
由审计报告 realm_context → 年轻对象的未记住边；`staging/sm/TypedArray/of.js` 在默认模式
stress 下同样命中 bootstrap 缺口，修复后通过。

### 8.36 V3-A／V6：按地址索引的旁表与根缺口

Map/Set 强条目以对象地址哈希。payload 追踪发现键被重定位时置 `index_stale`，下一次查找
在原有桶数组上原地重链（不分配，不会失败）；回滚恢复旧地址只使重链成为空操作。
iterator next 旁表按对象地址查找：新增 `has_iterator_next` 标志，晋升与回滚统一经
`gc_weak.relocateObjectIdentities` 同时迁移弱身份与该旁表。两条回归在 minor／major 下修复前
失败（搬迁后的键查不到、搬迁后的迭代器丢失缓存的 next），修复后通过。

`Vm.return_value` 改由 Machine 根遍历追踪，初值为 JS undefined 而不是未定义字节；
`HostInvocation` 空闲期间不被追踪，因此在 unpublish 时清空，避免下次发布追踪悬空值。
EventLoop 安装期间，realm 的根 provider 在宿主释放 create-ref 后继续登记，并只报告 realm
与调度器根，调度器清除时才撤销；这替代了“宿主必须先 deinit loop 再 destroy context”的
隐含顺序。回归在修复前于 loop 清理时访问已回收的 realm 并崩溃。

宿主 `print` 的数组、Map/Set 和属性循环改为每次嵌套打印后重新读取当前存储和计数。
回归让 `Error.prepareStackTrace` 在打印中扩容 Map 与数组；修复前的二进制输出漏掉后续条目
（遍历已释放的条目数组），修复后逐项正确。

### 8.37 V6：nursery 的保守扫描与标记

新增 `ZJS_GC_NURSERY=1`，只让单个进程启用 copying nursery，默认配置不变；用于把 test262
与单测分为默认／搬迁两种模式报告。首次搬迁模式扫描暴露出四个收集器层面的缺陷：

1. 保守扫描的地址解析只认识 block heap 与登记的 extent，nursery 页来自独立分配器，
   原生栈上的 nursery 对象既不 pin 页也不标记。§4.2 要求的“搬迁前 pin”实际不存在。
   现对落在 nursery 页内的字逐页遍历 bump 区定位对象（含 one-past-end），只提供已发布、
   未转发的对象。回归：仅由原生局部持有的 nursery 对象在 minor 后被回收，修复后保留。
2. 保守扫描能看到 nursery 后，被保留页上的尸体仍带 `heap_accounted`，残留的栈字可将其复活，
   而其存储已被清扫。尸体遍历现对已死对象先按需 finalize，再清除 `heap_accounted`。
3. nursery 驻留对象不在任何链表上，minor 的清标只走年轻链表与 block 位图，major 的纪元回绕
   清扫只走对象链表。被保留页上的对象保持上一轮的标记，下一轮被当作已追踪，年轻存储与子对象
   被清扫。两种收集开始时都遍历 nursery 页清标。
4. 解释器的 pending call 窗口以 Stack 身份和栈顶位置判断存活；Entry 退役或尾调用替换后同一
   Stack 槽被复用，旧窗口可能与新帧巧合匹配，收集器读取死槽。退役与替换时现清除指向该 Stack
   的窗口。此缺陷在默认模式 stress 下同样出现（`staging/sm/Set/*`）。

另有一个与 GC 无关、在 stress 扫描中暴露的既有语义缺陷：`defineArrayLength` 的收缩循环在
删除导致 Shape 压缩后仍按旧计数遍历，读取容量内的过期条目，容量缩小时越界。压缩保持存活
条目的顺序，循环游标现夹到当前计数；确定性回归（无需 stress）在旧二进制上越界，修复后通过。

缺陷 1–3 各有单测，修复前失败；缺陷 4 由 `staging/sm/Set/*` 在默认模式 stress 下确定性复现，
自行最小化的脚本未能复现，未保留无效夹具。

保守扫描开始真正保留 nursery 页后又暴露一个调度问题：回收后 `allocated_bytes` 被重置为
保留页的已用字节，而它正是下一次 minor 的触发量，保留页一旦填满触发预算，每个 safepoint
都会触发 minor 并再次保留同一批页。现在只计回收后新分配的字节；保留页仍是下一次 minor 的
年轻群体。`pageOf` 另以全部页的地址跨度先行拒绝，大多数被访问的头与栈字不在 nursery 中。
同一 staging 用例在搬迁模式下的 minor 次数由 397 降到 120，总耗时与默认模式持平；
Debug 构建下单次 minor 仍因逐页遍历（每页约千个对象）偏慢，这只影响默认关闭的实验模式。

### 8.38 验收对照与剩余范围

§7 的十条对抗序列与回归对照如下（文件为 `tests/core.zig`，另注者除外）。

| 序列 | 回归 |
| --- | --- |
| 1 根化后创建新对象触发 GC，只读更新后的值 | exact value roots receive nursery relocation in every aliased slot；非测试契约程序中各内置的搬迁序列 |
| 2 同一目标同时由可写根、只读 slice 与 persistent 持有 | readonly roots retain nursery aliases before writable roots move；conservative scan retains nursery objects named only by native frames |
| 3 已取切片后物化触发 GC | `string boundary` 与 replace／split／concat 各回归（§8.12、§8.20–8.24） |
| 4 输入输出别名的物化分配失败 | `string materialization` 别名 OOM 回归（§8.12） |
| 5 owner 自引用，storage 单独分配 | nursery evacuation moves self-referencing owners with inline and external property storage；storage 载体本身不搬迁（§8.34） |
| 6 回调重入、内层 handle、抛错 | exact value roots lifecycle guards；JSON reviver／stringify、Date、RegExp 多阶段回调契约 |
| 7 弱目标清理与搬迁后的弱身份 | nursery weak identity follows live target and clears after death；nursery ephemeron values repair their actual table slots |
| 8 持有 atom id 的对象存活 | atom 实体不搬迁；atom 根与 CompileAtomScope 回归（§8.6） |
| 9 搬迁中途资源不足 | `src/core/gc_trace_stw.zig` 的三条 nursery OOM 回滚回归；nursery evacuation rollback restores roots after provider failure |
| 10 撤根后 defer 意外触发 GC | no-GC scope 注入与回归（§8.18） |

全量证据（同一工作区、Debug 构建）：

- `zig build test`：引擎、CLI、非测试精确根契约程序与 visitor 负向编译全部通过；
  ReleaseFast `test-exact-roots` 通过。
- `zig build test-gc-stress`（`ZJS_GC_STRESS=1 ZJS_GC_VERIFY=fatal ZJS_GC_AUDIT=fatal`）通过；
  其中两条断言“本次调用不发生收集”的既有测试改为在 stress 下跳过，与已有的三条同类测试一致。
- test262 默认模式，`ZJS_GC_STRESS=64 ZJS_GC_AUDIT=fatal`：0/49777 errors，44583 通过
  （其余为配置跳过的特性）。
- test262 搬迁模式，`ZJS_GC_NURSERY=1 ZJS_GC_STRESS=64 ZJS_GC_AUDIT=fatal`：0/49777 errors，
  44583 通过。首次扫描使用 §8.37 调度修正之前的二进制；用最终构建复跑同样为 0/49777 errors、
  44583 通过。

§6 表中各阶段的验收条件据此关闭：V0 由 §8.1–8.6 与 §8.34 的清单覆盖；V1-A／V2 见 §8.13；
V1-B 的隐式物化调用已全部迁移并由门禁固定；V4-A 见 §8.11；V3-A／V3-B 见 §8.14–8.15、§8.34、
§8.36；V5 见 §8.16、§8.35 及默认模式 stress＋审计全量扫描；V6 见 §8.4、§8.36–8.37 及两种模式的
分别报告。nursery 仍默认关闭，本计划不改变这一点。

以下不属于上述验收条件，明确保留为设计方向或已知限制：

1. §5 所述“已发布对象写入收敛到单一 heap_store 入口”。当前 src/ 中 126 处屏障调用与 26 处批量记住（含
   源文件内单测）已逐处核对（§8.34–8.35）；物理收敛是跨解释器热路径的机械重构，另行决定。
2. JSValue 的旧 Header 形式接口（refHeader、cycleMarkHeader 等）与新 HeapRef 接口并存，
   作为兼容层保留；公开 `Value.asString()` 仍是文档化的物化兼容入口。
3. 扩大 nursery 可搬迁载体前，须先迁移 §8.34 的稳定载体清单中的临时包装。
4. Shape 根表按原型地址哈希，搬迁模式下产生重复根谱系（内存／IC 代价）。
5. RootProvider 必须在预扫描与主遍历报告同一组只读根（roots.zig 的既有契约）。主遍历迟到的
   只读根若目标已被搬迁会 panic；若尚未搬迁则只标记不补 pin，之后仍可能被可写根搬迁。
   在主遍历补 pin 会产生“保留页上已有转发残骸”的新状态，回收路径未为此设计，故未采用。
6. 生产构建的原生局部仍由保守扫描覆盖（现已包括 nursery 页）；本计划没有把所有内置的
   原生局部改成精确根，host 声明 quiescent 时的纯精确收集只对已迁移路径有逐项证据。
