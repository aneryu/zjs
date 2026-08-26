# zjs 进程模型设计(Erlang 风格多线程)

版本:0.5(正文归一化——D5 拆分+RT-LIFECYCLE 提取、旧术语清理〔两期
交付/D1D2 别名/LIFO 残留〕;无新设计。
0.4:roadmap v1.5 治理对齐——序列化改 SER-CORE+profile 术语,消除
PROC-D2 别名,旧别名映射:D1a=SER-CORE spec、D1b=SER-ARTIFACT、
D2=SER-MESSAGE;三 profile 共享 Core 编码内核,header/兼容策略/生命
周期语义各自独立)  
日期:2026-08-26  
状态:设计探索共识稿(两轮拷问 + Erlang×JS 适配性复审 + 跨方案对账 +
**技术合理性评审**后的决策记录;不承诺实现排期)  
涉及组件:zjs、fun(embedder)、FNABI、hot-reload(共享基建)  
目标读者:zjs/fun 核心开发者

v0.1 → v0.2:六方对账,6 条硬冲突与 11 组遗漏;裁决与欠账见 §20。
v0.2 → v0.3:四路业界对照技术评审(JSC/V8 源码级、Static Hermes、
N-API、BEAM)修三处硬伤——**turn 规范性定义为单 job+轮转量子**(§5)、
**撤回 LIFO 改为 v1 禁止并发 receive**(§6.1,裁决 17 部分修订)、
**删除静态亲和的错误 Erlang 历史背书并补负载观测+演进判据+两档拆分**
(§5);各方案欠账追加见 §20.2a。

总纲:**Erlang 语义为骨架,JS 惯用法为表面**。冲突时不硬搬 Erlang 的形,
找 JS 已有的等价惯用法(receive→`await`、let-it-crash→uncaught/unhandled-rejection
杀进程、gen_server:call→Promise RPC)。

---

## 0. 裁决记录

2026-08-26 两轮拷问共 20 项裁决。**两处 owner 偏离推荐**,均已带风险控制点:

| 偏离项 | owner 裁决 | 风险控制点 |
|---|---|---|
| spawn 入口 | **闭包一步到位**(推荐为 v1 模块入口、L2 再加闭包) | 字节码序列化器与热更 W1 共基建、同期交付(§7);捕获检查可变即拒堵住语义坑(§7.2) |
| 单线程零税 | **无条件编入 + bench-v8 A/B 软门**(推荐为 comptime 分档 + `.text` 同一性硬门) | 前提=多线程支持不触碰解释器热路径;轻进程阶段若引入热路径判定(共享段检查、atom 表并发化),**重开分档裁决**(§14.1 checkpoint) |

其余 18 项见各节。§17 保留完整总表。

## 1. 目标与非目标

**目标**:为 zjs 定义 Erlang 风格的多进程并发模型——隔离堆、消息传递、
监督容错——的统一设计,覆盖 08-20 路线的 L1(Worker 级)/L2(可移植闭包)/
L3(轻进程)三层,评估可行性与成本。

**非目标**:

- 不承诺排期;交付切分只定依赖序(§16)。
- 分布式(跨机节点)out of scope;仅保证 pid 编码不堵死未来加 node id(§9)。
- 不追求 Web `Worker`/`worker_threads` API 兼容(引擎能力边界不由单个
  消费者的产品面来划;库层可做兼容 shim)。
- v1 不做真抢占(fiber 挂起/恢复);调度语义保持向上兼容(§5)。

## 2. 进程抽象(裁决 2)

「进程」= 私有堆 + 邮箱 + pid + link 语义的抽象接口。**API 语义从第一天冻结,
实现分两阶段**:

- **v1:Runtime-per-process**。每个进程是一个完整的线程封闭 `JSRuntime`
  (实测 ≈160–173 µs / 117 KB;数百~数千进程规模)。热更设计已有
  Session=Runtime 先例,多 Runtime 共存/独立销毁在 main 上已成立
  (泄漏是硬 panic 而非慢性漂移)。
- **演进:轻进程**。共享 179 个 intrinsic 对象 + 59 shape 的不朽段后,
  降到 ≈29 KB / 110 µs(省 75% 内存、33% 创建时间)。硬前提见 §15。
  残余地板是 runtime 骨架(GC registry、栈、job 队列),那是轻进程之后
  的下一个攻坚面。

进程与 Erlang 的一个结构性差异被保留为**卖点**:Erlang 进程是单执行流+邮箱;
zjs 进程是**事件循环+邮箱**——进程内部照常并发 IO/timer/microtask
(热更设计的「初始化中 Session 运转豁免」同款语义)。消息派发的交错语义:
每条消息处理的**同步前缀**是一个 job(async handler 的每个 await 恢复是
后续独立 job),与进程自身的 job 队列按事件循环常规排序。

## 3. GC 基座(裁决 3)

**tracing 单基座**:轻进程阶段以 `gc/tracing` 合入 main 为前提。
per-process 独立堆 + tracing GC 恰好构成 Erlang 的 per-process heap 形状:
小堆、短暂停、进程死亡=整堆归还。

**rc 废案记录**:rc 表示层下共享 intrinsic 必须付 immortal-refcount 税,
2026-08-20 实测 bench-v8 −0.4%(RegExp −2.7%),病根是 refcount 释放被
特化内联到 ~10,800 站点、每处加检查,税与热路径站点密度绑定而非总体积,
单点编码优化已实测无效(`.text` +4.9% 而分数不动)。tracing 下共享只需
「不朽段不被各进程 GC 扫描」,无每操作税。此路线不再重启。

## 4. 消息与零拷贝(裁决 5、6、19)

### 4.1 值域

消息值域 = 结构化克隆全集:普通对象/数组/TypedArray/ArrayBuffer/Map/Set/
Date/RegExp/Error/BigInt,支持循环引用与单消息内别名。函数不可入消息
(可移植闭包是 spawn 的专用通道,§7)。

**值域细则(「消息=数据」纪律)**:

- class 实例降级为 plain object(Web SC 既定语义):原型与方法丢失。
  业务对象过邮箱变哑数据是分布式系统通例;可移植 class 定义列研究附录(§18)。
- Symbol 不可克隆(SC 标准抛错),唯一例外是 pid(§9)。**pid 作属性键
  的行为须裁决(v0.3 登记)**:标准 SC 静默忽略 symbol 键属性——
  `send(p, {[pid]: data})` 会无声丢整个条目而 `[pid, data]` 正常;既然
  pid 是 symbol 的 SC 例外,属性键位置是丢弃、报错还是同样例外,实现前
  定案(倾向:报错,静默丢是第一天就会踩的暗坑)。
- identity 边界:单条消息内 SC 保持别名/循环;**跨消息 identity 断裂**
  (同一对象发两次,接收方得到两个不同对象)。文档必须明示。

### 4.2 拷贝语义与零拷贝三通道

默认语义 = 深拷贝,share-nothing 不动摇(换来无锁 GC、无同步、进程死亡
整堆归还)。零拷贝分三通道:

1. **transfer**:ArrayBuffer 所有权转移(发送方 detach)。
2. **SAB + Atomics**:已有;跨进程共享沿 Web 语义。
3. **大不可变共享段**:大字符串 / frozen ArrayBuffer 走堆外共享段 +
   atomic refcount——Erlang refc binary 的直接对应。共享段独立于各进程堆
   (如同 Erlang 的 binary heap),不违反 tracing 基座;小对象照拷
   (Erlang 同款分界思想,阈值实测定)。

**wire format 硬目标:单拷贝投递**。发送方序列化直接写入接收方可读缓冲,
接收方惰性 materialize;全程一次编码一次解码,不存在中间第三份。
TypedArray 数据段留 zero-copy view 钩子。

深冻结对象图零拷贝共享(shape 跨 Runtime 问题)= 研究附录,不进关键路径(§18)。

## 5. 调度(裁决 4)

**N:M 线程池 + turn 边界调度 + 预算超限 kill**:

- **静态亲和(对账裁决 21,2026-08-26;技术评审修订 v0.3)**:进程 spawn
  时分配到 carrier 线程,v1 不迁移(放置策略选最空闲 carrier)。这保全了
  四方写死的「固定 owner 线程」假设(tracing §1.4/§3.1、FNABI §21.1、
  热更冻结项 5、`owner_thread_id` 无 rebind API)且零改造;代价是无
  work stealing。**v0.3 修订三条**:①v1 必须带 per-carrier 负载可观测
  (runnable 队长、turn 时长直方图)并**预定义演进触发判据**(如 carrier
  间 p99 turn 延迟差 > N 倍持续 M 分钟),否则演进项永远等不到立项证据;
  ②演进拆两档报价:**静止进程 rebind**(turn 间原生栈已空、状态即
  Runtime,迁移=fence+改 `owner_thread_id`+栈界注销,便宜)先行,
  **work stealing**(运行中迁移)在后——捆绑定价会堵死中间解;③v0.2
  曾引「Erlang 调度器先无 migration 后补」作背书,**该历史陈述有误已
  删除**:BEAM R11B 是全局单 run queue(均衡由构造保证),R13B 改
  per-scheduler 队列时 migration 与 work stealing 同版本交付,BEAM 从未
  运行过静态亲和无均衡的配置——此裁决的依据是 v1 工程成本,不是先例。
- **turn 的规范性定义(v0.3,技术评审 T1)**:**turn := 单个 job 的执行**。
  carrier 在其进程间按 job 粒度轮转,配批量量子(同一进程连续 K 个 job
  或 T µs 后强制轮转,摊薄切换成本)。依据:zjs 是单条 per-Runtime job
  FIFO,promise reaction 就是队列中的 job、无嵌套 microtask 队列——若
  turn=排空队列,则一段完全正统的 await 连环(每个 job 微秒级但队列
  永不空)会把 carrier 占到预算 kill 为止,中间无任何调度点;「JS 文化
  反长任务」只防长同步任务防不了这个(浏览器语境里 microtask 不让线程
  正是著名陷阱)。ECMA-262 允许 job 之间插入宿主工作(run-to-completion-
  of-queue 是 HTML 规范,zjs 不受其约束)。能力尺(§14.2)增加
  microtask 连环饥饿 microbench(Node worker 有内核抢占测不出此项)。
  turn 之间原生栈已退干净,进程状态就是 Runtime 本身——无 fiber、
  无切栈、无多栈 conservative 根扫描。
- interrupt cadence(已有:每 backedge 与 call seam 检查点、per-Realm
  计数器 reset 10000)只用作**预算超限 → kill**:CPU 预算与内存预算
  (含邮箱字节,§8.3)超限即杀进程,交给监督树重启——let-it-crash 语义
  的组成部分,不是异常路径。
- **升级兼容**:调度语义抽象为「进程不感知线程;调度点=turn 边界+cadence
  检查点」。该语义在未来把 cadence 点从 kill-only 升级为 suspend(fiber
  真抢占)时不变,API 不破。
- **已知限制**:单个长同步 turn 会占住 carrier 线程,延迟公平性低于
  Erlang。JS 生态本就把长 turn 视为反模式,文档告诫 + carrier 池冗余缓解;
  **dirty pool**(Erlang dirty scheduler 对应物,承接长计算/阻塞 native
  调用)留作演进钩子,不进 v1。
- **交付切分(roadmap v1.7,详见 §16.3)**:per-thread Io = PROC-D5A
  (无前置);pauseJobs/resumeJobs、带 reason 的 requestInterrupt 与
  优先级仲裁(kill > reload drain > timeout)、生命周期取消钩子 =
  RT-LIFECYCLE(与热更 HR-P2A、FNABI shutdown 共享,不三线各自实现);
  调度池 + 预算 kill = PROC-D5B(前置:RT-LIFECYCLE)。

## 6. 邮箱与 receive(裁决 9、10、17)

### 6.1 selective receive

核心原语:

```js
const msg = await receive(m => m.type === 'job', { timeout: 5000 });
```

- 谓词可选;无谓词取队首。**不匹配的消息留在邮箱**(Erlang selective
  receive 语义)。timeout 到期 reject。
- 糖:`for await (const msg of mailbox())` 顺序消费(等价于循环的无谓词
  receive)。
- `await` 即让出 turn,与 §5 调度天然契合——阻塞式 receive 零 fiber 成本。

**并发未决 receive:v1 禁止(v0.3 撤回 LIFO 仲裁,技术评审 T2)**。第二个
未决 receive 直接 throw(错误信息指向已有 receive 的注册点),receive
注册时先扫既存邮箱;禁止是可放松方向(throw→允许),而仲裁顺序一旦发布
即冻结,方向不可逆性完全偏向先禁,并把 §10.3「一次一条消息」纪律在唯一
要害处机制化。撤回的病理分析(重叠谓词下 LIFO 永久饥饿、Erlang 栈类比缺
互斥前提、reply 拦截动机已被 §9 reply-出邮箱消解)见 §20.2a 评审记录。

**O(n) 扫描陷阱**:selective receive 对不匹配消息反复扫描是 Erlang 的著名
性能坑(OTP 靠 ref 跳过缓解)。本设计中 call/reply 不过邮箱(§10),
最高频的谓词等待已绕开;用户级协议若自带关联 id,邮箱实现预留「扫描游标
从标记点开始」的 ref 跳过优化位。

### 6.2 背压(裁决 10)

**Erlang 式:send 永不阻塞、永不失败**。

- 邮箱无界;邮箱字节计入接收进程内存预算,堆积过多 → 预算超限 kill →
  监督重启。零新增机制,结构上无死锁环(对比 CSP 有界阻塞:A/B 互发满
  邮箱互 await 是真死锁)。
- 高水位观测钩子(队长/字节阈值事件)供应用层自建流控。
- 请求-应答(call)形态天然自限速,是实际流量的主体。
- **kill-based 背压的三件补强(v0.3,技术评审)**——业界证据链(BEAM
  的 max_heap_size 只是 OTP 19 可选项、真实防御是 busy_dist_port+jobs/
  sbroker 库生态;Akka 尸检产出 Reactive Streams)表明纯 kill 兜底不足,
  但补强不在引擎加 rate limit,而在可归因与可闭环:①**区分性 exit
  reason**:`mailbox_overflow` 与普通 crash 可区分,supervisor 才能对
  过载杀与 bug 杀用不同退避;②**邮箱统计(队长/字节/top-K 发送方)记
  堆外**,幸存 kill——否则 crash loop 的尸检证据随堆销毁;③send 返回
  队深提示(不破坏永不失败语义),发送侧库层可自建闭环流控;④supervisor
  库的 restart intensity+退避是**默认行为**而非示例——引擎不做流控的
  前提是库层兜底必然存在。

### 6.3 双通道定型(对账裁决 23)

**host 事件不走邮箱**。进程的入站分两条通道:①**邮箱**=进程间
send/call 消息(无界、FIFO、selective receive、预算 kill 语义);
②**host 事件通道**=输入/GPU/timer completion 等,经 BindingRouter →
binding 调用/job 队列派发,沿用热更 §11.1 的有界队列+逐类型合并策略
(pointer 只留最后/resize 只留最新/animation frame 合并)。后果:
GUI 事件洪水不可能触发邮箱预算 kill;热更「事件队列必须有上限」与本
设计「邮箱无界」各管一条通道,不再矛盾;native completion 不以普通
消息入邮箱(其 cleanup 由堆外记录保证,§10.2)。「Session 是 process
特例」精确化为:**Session = process + 进程外的 BindingRouter 前置队列**。

## 7. spawn 与可移植闭包(裁决 7、8)

### 7.1 spawn

```js
const pid = spawn(() => { ... }, { name?, budget?, link? });
```

闭包入口一步到位(owner 裁决,偏离记录见 §0)。闭包跨进程 = 字节码序列化
+ atom 重映射 + 捕获检查;字节码序列化器与热更 W1 是**同一交付物**(§13)。

### 7.2 捕获语义:可变即拒

- 只允许捕获「从未被重赋值的绑定 + 值可克隆」;捕获可变绑定(被赋值过的
  `let`/`var`)→ spawn 时报错,**错误信息指名变量**。编译器对每个 upvalue
  已知是否被重赋值,判定零运行时成本。显式失败优于静默分叉。
- 捕获值走消息同款 SC 拷贝(含三通道零拷贝)。
- `globalThis` 上的名字不捕获,在目标进程重新解析——同 Erlang 目标节点
  用自己的模块版本;顺带天然兼容热更的新版本加载。

## 8. pid(裁决 11、18)

### 8.1 表示:unique Symbol + per-Runtime intern

- pid 是 unique symbol。primitive 卫生天生:`===`、Map key、WeakMap key
  (ES2023)免费成立;不可挂属性、不可改原型、不可伪造;
  description 携可读信息(如 `Symbol('pid<3.17.2>')`)供调试。
- wire 上传 `(id, generation)`;反序列化时在接收 Runtime 的 intern 表去重,
  同一 pid 永远返回同一 symbol → 跨多次消息接收 `===` 成立。intern 表弱
  引用语义(无人持有可回收;重建不破坏 `===`,旧值既已回收无比较对象)。
  实现代价:symbol → 路由数据的 side map。
- **generation 防 ABA**(进程槽复用后旧 pid 不得命中新进程;本仓 M2 ABA
  前科的既定教训)。编码预留 node id 位,分布式不堵死。

### 8.2 语义

- pid 一等值,可入消息转发;能力即地址:知道 pid 即可 send(无附加权限
  模型,同 Erlang)。
- **死 pid 双层语义**:`send()` fire-and-forget,对死 pid 静默丢
  (Erlang 与 Web postMessage 双先例一致)+ 丢弃计数/开发模式告警钩子;
  `call()` 见 §10。send 时报错是竞态下的假安全感,唯一可靠的死亡通知是
  monitor。
- 最小命名注册进 v1:`register(name, pid)` / `whereis(name)`(本地级)。

## 9. call / reply(裁决 11、17)

```js
const reply = await call(pid, msg, { timeout });
```

- 语义上等价 `gen_server:call`(内部自动 monitor + 关联 ref + 超时),
  表面是 JS 的 RPC 直觉:目标已死 / 中途死 / 超时 → reject。
- **reply 直达 Promise,不进邮箱**(偏离 Erlang 形、守住骨架:Erlang 里
  reply 走邮箱只因它仅有消息一种通道,JS 有 Promise)。收益:彻底消除
  「主循环迭代器吞 reply」问题;reply 免 selective 扫描;热路径最快。
  被 call 方通过 handler 收到 `(msg, reply)`,调用 `reply(value)` 完成应答。

## 10. 容错(裁决 12、16、20)

### 10.1 引擎三原语,supervisor 进库(BEAM 同款切割)

- **引擎层**:`link(pid)`(双向死亡传播,默认连坐杀)、`monitor(pid)`
  (单向死亡通知消息)、exit 信号 + **trap 开关**(开 trap 后 link 死亡
  降级为邮箱消息,即 `trap_exit`)。
- **库层**:supervisor 用 JS 写成引擎仓随附标准库模块,重启策略从
  `one_for_one` / `one_for_all` 子集起步;fun 可再包装。策略可迭代而
  不动引擎。

### 10.2 进程退出语义

- uncaught 异常 = 进程退出(Node worker 先例);Error 随 exit reason 走
  SC 克隆传给 monitor/link。
- **unhandled promise rejection = 进程 crash(默认)**,exit reason 携带
  该 Error。不补这条,async 代码的 let-it-crash 整个失效(错误静默沉没,
  监督树永不触发);Node 的 warning→默认 crash 弯路是先例。
- 正常退出(entry 函数 resolve 且 job 队列空闲)= normal,link 默认不连坐。

**kill 双径与堆外收尾(对账裁决 22)**——「整堆即时归还」与 FNABI 七态
drain / GPU fence 的矛盾以**解耦**消解:JS 堆的归还与 native 资源的收尾
是两件事。

- kill 序列:exit 信号 → CancellationToken 取消可取消项 → **有界** drain
  → 超时即强制销毁 JS 堆(整堆即时归还)。**native 收尾不等堆**:in-flight
  操作的 cleanup 由堆外 AsyncOperation 记录保证(热更 §10 既有语义:
  「cleanup 照跑、JS callback 丢弃」);fence-protected GPU 资源由进程外
  HostScheduler 延迟释放。「进程死亡=整堆归还」修正为「JS 堆即时归还,
  native 尾巴由堆外记录异步收尾」。
- **快速路径**:无在飞 native 资源的纯 JS 进程零等待销毁(FNABI v0.4
  欠账条款);FNABI 七态机保留为 graceful 关闭的权威规范,kill = 其
  压缩执行(Closing/Cancelling 合并、Draining 有界、Finalizing 由堆外
  记录接管),「两处不得各自定义关闭状态机」得以保全。
- **kill 失败分支(此前缺失)**:native 调用卡死使 cadence 检查点不可达
  时,kill 无法生效 → 升级 **Worker Restart**;静态亲和下连坐半径 = 同
  Worker 全部进程,全部以 killed 语义通知各自 monitor。为此 **supervisor
  须可跨 Worker 部署**(否则监督者与被监督者同归于尽)。
- finalizer 判别扩为三态:普通 GC / normal 退出 / kill,插件 finalizer
  合同(「能区分普通 GC 和 teardown」)相应扩展(FNABI 欠账)。
- **「复用热更销毁路径」收窄**:真正通用的只有热更 §28 的步 7–9(scope/
  callback roots/module registry roots)、步 11(五阶段堆销毁)、步 13
  与 §10 AsyncOperation 不变量;步 2(SessionLease)、步 10(inspector)、
  步 12(GPU fence 编排)是 Session/HostCore 专用。逐 IO 类别的取消/
  detach/丢弃清单仍是本文档欠账(热更文档同样没有完整清单)。

### 10.3 文化风险(机制无法强制,纪律对冲)

- JS 全 catch 文化可能架空监督树(用户把所有错吞在进程内)。对冲:
  supervisor 库示例与文档立 let-it-crash 纪律;预算 kill 兜住失控存量。
- 进程内自由 Promise 并发侵蚀「一次一条消息」的顺序状态机纪律。同上,
  文档纪律,不设机制强制。

## 11. 与热更新的关系(裁决 13)

Session 与 process 都是 Runtime 的生命周期包装(创建/预编译/销毁/替换),
机制层高度重叠:

- v1 约束:两者**共享 Runtime 生命周期基建层**,同一套代码,不做两遍。
- 目标图景(声明,不动热更 v1.3 定稿):**Session 是受监督的具名 process
  特例**——绑 BindingSet、因代码变更而重建;监督重启与热更重建是同一操作
  的两个触发器(crash vs 代码变更)。fun 是否迁移到监督树另议。

## 12. API 表面与 embedder 边界

- JS API:内建模块(暂名 `zjs:process`,命名后议),**模块函数式**
  `spawn/send/receive/call/link/monitor/register/whereis`——与 Erlang
  `Pid ! Msg` 形状一致,亦是 pid=symbol 的必然(symbol 不挂方法);
  OO 糖(actor proxy)归库层。
- Zig embedder API 同步暴露(fun 直接消费)。
- **FNABI 补线程封闭条款**:native 模块默认 per-Runtime 实例化,跨线程
  共享状态自负同步。进程级动态 class id 分配器永不回收(u16 上限),
  process 大量 spawn/销毁必须复用静态 class id 槽——热更 §38.1 同款约束,
  此处密度更高,压测必须覆盖。

## 13. 序列化器:一次 Core,三 profile(裁决 14)

设计阶段一次定死 **SER-CORE 编码内核**:类型标签空间、值遍历、循环检测、
atom 重映射、版本化头,含 §4.2 单拷贝 wire 目标。三 profile 共享该内核,
header/兼容策略/生命周期语义各自独立:

- **SER-ARTIFACT(=热更 W1)**:字节码 artifact profile。热更按原范围
  拿到东西,不被多线程需求拖大。
- **SER-SNAPSHOT**:热更 §27.9 结构化状态迁移 profile(允许类型集本就
  是 SC 子集)。
- **SER-MESSAGE**:SC 值序列化器 + 三通道零拷贝。

**W1 锚定修正(对账裁决 24)**:热更与本文档 v0.1 都把联合设计对象写成
「type-directed plan 的离线 emitter 输出」——对账证实那是 **Zig 源码→
静态链接原生码**路线,不是序列化格式,对接落空。真正的对接物是 typed
plan **§10.5 fun 模块容器格式清单**(mmap 零拷贝对齐契约、禁编入任何
运行时 JSValue 位型、缓存槽命名编译期定死/内容运行时私有、版本严格相等
拒载)与 **§10.6 布局确定性不变量**(同源码同配置必同布局)——两节直接
作为 W1 框架素材。typed plan 侧的对应义务(登记联合设计、开放问题 5 的
评估点提前到 W1 框架冻结前、站点自改写降级为运行时私有副本、identity
统一引用表口径)见 §20 A3/A5。

排期仲裁:SER-CORE 内核先行不变;热更 §27.9(SER-SNAPSHOT)若先于
SER-MESSAGE 到期,**允许窄实现但必须挂 SER-CORE 内核**——「禁止不共享
Core 的第二套编码体系」保全,热更侧不被 SER-MESSAGE 全量阻塞。

风险控制点:**内核设计时 SC 需求必须在场**(pid 类型标签、共享段引用、
transfer 语义、循环引用),避免 artifact profile 先行使内核长成只适配
字节码的形状。

## 14. 性能与验收(裁决 15 + 附带默认值)

### 14.1 编入策略与 checkpoint

多线程支持**无条件编入**(owner 裁决,偏离记录见 §0),验收走 bench-v8
A/B 软门。技术注脚:immortal-rc 的 −0.4% 来自 10,800 个解释器热路径站点
每处加分支;本设计 v1 的支持面(邮箱钩子挂 event loop、生命周期基建、
per-Runtime atom 表不动)不触碰解释器热路径,漏税风险低一个量级。

**checkpoint(v0.2 升级:从「若触发」改为「必触发」)**:对账在
`gc/tracing` 分支拿到代码证据——两个 shade 实现均无文档 §8.4 要求的
runtime ownership 校验,共享不朽段一旦存在,任意 Runtime 的屏障会写
共享对象 header 的**非原子 flags 位域**(跨线程竞争 + 破坏 sticky mark)。
修复必然在 shade/visit 热路径加不朽段范围判定 ⇒ 轻进程立项的**第一件事**
就是重开 comptime 分档裁决 + 屏障路径范围判定设计(P1.3 bloom prefilter
的两 ALU op 排除技术可迁移,但它现在只在保守扫描路径)。`.text` 段逐位
同一性构造证明的方法论在 immortal-probe 已验证可用。

### 14.2 双尺验收

- **回归尺**:bench-v8 vs qjs 照旧(qjs 仍是既有单线程性能的唯一尺)。
- **能力尺**:新能力面 qjs 无对照,microbench 对标 **Node
  worker_threads**——spawn 延迟、per-process 内存、小消息往返、大消息/
  零拷贝通道吞吐、kill→重启恢复时间、**microtask 连环饥饿基准(§5 turn
  定义的验证项,Node 有内核抢占测不出)**。Erlang/BEAM 作北极星只记
  差距,不作验收(BEAM ~2.6 KB/亚 µs 是轻进程阶段之后的事)。
  **档位诚实声明(v0.3)**:本设计是 **session-grade**(数十~数千长命
  进程),不是 request-grade——170µs spawn = 每核每秒 ~5,900 次 spawn
  硬顶,每请求一进程的负载形态不在支持面(Cloudflare 的生产结论同构:
  isolate-per-tenant、请求共享 isolate)。

### 14.3 测试策略

test262 agent 测试节(Atomics/SAB waiter)迁移到新机制跑(
`run_test262_host.zig` 已有 agent spawn/detach 原型);CI 加 TSan 档;
序列化器往返 fuzz;GC 四套件(单测×2 + test262 双向)多线程构建下全绿。

## 15. 轻进程阶段:硬前提清单

1. `gc/tracing` 合入 main(owner 门槛:「打磨好才能合入」)。
2. **共享不朽段**:179 intrinsic 对象 + 59 shape 进程间只读共享
   (117 KB → ~29 KB,创建时间 −33%)。tracing 下 = 不朽段不被各进程 GC
   扫描;§14.1 checkpoint **必触发**(shade 校验缺失的代码证据见该节)。
   tracing 文档欠账:§3.1 不变量 1/2 加 immortal 段豁免、GcPlatform
   成员表加 `ImmortalSpace`、§8.4 shade ownership 校验落实(§20 A6)。
3. 共享 atom 表(至少 intrinsic 覆盖的子集)并发化——同触发 checkpoint。
3a. **大不可变共享段三条收紧(对账)**:atomic rc 是**段级**而非每字符串
   (现有 4 字节前缀是非原子 u32,原子化它=全体单线程字符串操作付税);
   只收 **flat 化**字符串——rope 持两条强 JSValue 边,进段即违反跨堆
   无强边不变量;共享段**显式不进**保守扫描地址族(生命周期由段 rc 管,
   GC 不 retain;bloom filter 第三 population 的教训要求这是成文决定)。
   `ExternalMemoryToken` 的跨 Runtime transfer Adapter 是 §4.2 通道 1
   的未设计前置件,列为 SER-MESSAGE 前置。
4. 内建无字节码可共享(全是枚举分发 host function,实测 `function_bytecode
   = 0`),字节码共享只影响用户代码多进程加载,与热更 registry 多版本化
   (热更阶段 3)合流。
5. runtime 骨架瘦身(110 µs / 29 KB 地板)是轻进程**之后**的攻坚面,
   不是本阶段前提。
6. **D7 立项前置负载表(v0.3,技术评审)**:117→29 KB 不改变负载可行域
   (session 级用不着、request 级救不了),唯一受益形态是「大量常驻且
   多数空闲的小进程」(如 connection-per-process 且多数静默)——立项前
   须有真实负载表(应用类型 × 进程数 × 生命周期 × spawn 速率)证明该带
   存在,否则不为其付 checkpoint 必触发的热路径风险。

## 16. 实现现状对账与交付依赖序

### 16.1 已有(main@`0cfc73ce` 直接可用)

- 线程封闭 `JSRuntime` + `owner_thread_id` 断言;per-runtime atom 表;
  多 Runtime 共存/独立销毁,泄漏硬 panic。(v0.2 注:断言「直接可用」
  仅在 §5 静态亲和裁决下成立——`owner_thread_id` 创建时一次写入、无
  rebind API,动态迁移是演进项的改造前提,不是现状能力。)
- interrupt 全套:backedge + call seam 检查点,per-Realm cadence 10000,
  不可捕获 Interrupted。
- 跨线程唤醒:`AtomicsWaiter`(`std.Io.Condition` + mutex,外部线程只
  signal、owner 独占消费);`waitForAtomicsHostSignalUntil` 钩子。
  消息投递唤醒直接复用。
- SAB(含 growable);test262 agent spawn/detach 原型;Loader HostHooks。

### 16.2 缺失(真实工程量)

- 结构化克隆序列化器:零实现。
- 字节码序列化 + atom 重映射:零实现(= 热更 W1)。
- `hostTimerIo` 仍是 `global_single_threaded`,需 per-thread Io。
- 邮箱、调度池、pid intern、link/monitor/exit 信号、supervisor 库:全新。
- `gc.zig:100-137` 七个进程级 stress `pub var` 在多线程 `Runtime.create`
  下是无同步并发写(值相同故行为无害,TSan 一开必报)——小修。
- `pauseJobs`/`resumeJobs`(热更 §27.1 已列待补)正是 turn 调度器需要的
  停/启进程 job 泵原语——归 **RT-LIFECYCLE**(§16.3 跨线共享工作项)交付。
- `requestInterrupt` 无 reason 参数:多消费者仲裁(§20 B2)需要 reason
  编码 + 优先级(kill > reload drain > timeout)——归 **RT-LIFECYCLE** 交付。

### 16.3 交付依赖序(不承诺排期)

```
SER-CORE     序列化编码内核 spec(=D1a;三方评审)
SER-ARTIFACT 字节码 artifact profile(=D1b,热更 W1)
SER-MESSAGE  SC 值器 + 三通道零拷贝(=旧 D2;依赖 SER-CORE)
PROC-D3 跨 Runtime 投递 + 邮箱 + pid intern(依赖 SER-MESSAGE;
        唤醒复用 AtomicsWaiter;前置:契约弱引用注册表立项+
        多 Runtime 验收面第二批)
PROC-D4 spawn/exit/link/monitor/call(依赖 D3;闭包 spawn 依赖
        SER-ARTIFACT + atom 重映射)
PROC-D5A per-thread Io(无前置)
RT-LIFECYCLE Runtime 生命周期共享件:pauseJobs/resumeJobs、带 reason 的
        requestInterrupt(优先级仲裁 kill > reload drain > timeout)、
        生命周期取消钩子——热更 HR-P2A 与 FNABI shutdown 共用,
        避免三线各自实现(§16.2)
PROC-D5B N:M 调度池 + 预算 kill(前置:RT-LIFECYCLE)
PROC-D6 supervisor 库 + register/whereis(依赖 D4)
PROC-D7 轻进程(依赖 gc/tracing 合入 + §15;含 checkpoint + 负载表)
```

## 17. 裁决总表

| # | 分支 | 裁决 |
|---|---|---|
| 1 | 定位 | 设计探索,统一覆盖 L1/L2/L3,不承诺排期 |
| 2 | 进程定义 | 抽象分层:v1 Runtime-per-process → 轻进程;API 第一天冻结 |
| 3 | GC 基座 | tracing 单基座;rc immortal-rc 废案 |
| 4 | 调度 | turn 边界 + 预算超限 kill;N:M;suspend 升级兼容;dirty pool 留钩 |
| 5 | 消息值域 | SC 全集;函数不入消息 |
| 6 | 零拷贝 | 三通道 + 单拷贝 wire + 惰性反序列化;深冻结共享=研究附录 |
| 7 | spawn 入口 | **闭包一步到位(偏离推荐)**;与热更 W1 共基建 |
| 8 | 捕获语义 | 可变即拒,报错指名变量;globalThis 目标进程重解析 |
| 9 | receive | selective(谓词+timeout+留邮箱)+ 迭代器糖 |
| 10 | 背压 | send 永不阻塞;邮箱字节入预算 kill;高水位钩子 |
| 11 | 死 pid | send 静默丢+观测;call reject |
| 12 | 容错分层 | link/monitor/exit+trap 进引擎;supervisor 进库 |
| 13 | 热更关系 | 共享 Runtime 生命周期基建;Session=未来受监督具名 process 特例 |
| 14 | 序列化切分 | 一次 Core、三 profile(SER-CORE 内核共享,profile 独立);内核设计时 SC 需求在场 |
| 15 | 零税与验收 | **无条件编入+A/B 软门(偏离推荐)**+轻进程 checkpoint;双尺验收 |
| 16 | rejection | unhandled rejection = 进程 crash(默认) |
| 17 | reply 通道 | reply 直达 Promise 不进邮箱;v1 禁止并发 receive(v0.3 修订,§6.1) |
| 18 | pid | Symbol + per-Runtime intern;API 模块函数式;generation 防 ABA |
| 19 | 值域细则 | 类实例降级/Symbol 不可克隆(pid 例外)/跨消息 identity 断裂=「消息=数据」纪律 |
| 20 | 死亡清理 | in-flight IO/timer 取消语义:解耦原则已定(§10.2),逐类别清单仍欠 |
| 21 | 调度亲和 | v1 静态亲和 N:M,动态迁移=演进项(§20 A1) |
| 22 | kill 双径 | JS 堆即时归还 × native 堆外收尾;快速路径;失败→Worker Restart(§20 A2) |
| 23 | 双通道 | host 事件走 BindingRouter 不进邮箱;邮箱只管进程间消息(§20 A4) |
| 24 | W1 锚定 | 联合设计对象=typed plan §10.5/§10.6,非离线 emitter(§20 A3) |
| 25 | checkpoint | 共享不朽段的分档裁决「必触发」,轻进程立项首件事(§20 A6) |
| 26 | typed 修订 | 站点自改写降级/identity 引用表口径/计数器 per-Runtime(§20 A5) |

## 18. 研究附录与开放问题

- **深冻结对象图零拷贝共享**:硬点是 shape/hidden class 为 per-Runtime,
  共享对象的 shape 指针无处可指。需先出可行性 spike 再谈进主设计。
- **可移植 class 定义**(class 随字节码跨进程,消息侧对象不再降级):
  依赖 SER-ARTIFACT/SER-MESSAGE 成熟后评估。
- **dirty pool**(长计算/阻塞 native 承接):见 §5。
- **共享段回收**:大不可变共享段的 atomic rc 与各进程 tracing GC 的
  协作(进程堆内 handle 死亡 → 段 rc 递减)细化;实现期定案。

## 19. Erlang×JS 适配性复审记录(2026-08-26)

总判定:**结构级契合,非勉强移植**。receive↔`await`、turn 调度↔JS 反长
任务文化、per-process 堆↔tracing GC 三处是同构。真正的风险不在机制,在
两处:JS 错误文化对 let-it-crash 的侵蚀(§10.2 条款 16 + §10.3 纪律对冲),
和邮箱与 Promise 双通道的交互语义(Erlang 无先例可抄,§6.1 禁并发
receive + §9 reply 出邮箱已定对)。

| Erlang 机制 | 隐含前提 | JS 现实 | 判定 |
|---|---|---|---|
| 阻塞 receive+顺序逻辑 | 可挂起等待 | `await` 零扭曲 | 契合 |
| reduction 抢占 | 长计算饿死同伴 | turn 边界+反长任务文化 | 契合(公平性弱于 BEAM,已知限制) |
| per-process heap | 堆绑进程 | Runtime + tracing GC 同构 | 契合 |
| 消息拷贝 | 用户不误以为共享 | postMessage 先例 | 契合 |
| 热代码加载 | 多版本+迁移 | 热更 v1.3 已独立解决 | 契合(共基建) |
| 不可变 term | 无 identity 语义 | JS 对象有 `===`/Map-by-ref | 摩擦→「消息=数据」纪律 |
| 哑数据 record | 无原型 | class 实例 SC 降级 | 摩擦→纪律+研究附录 |
| let-it-crash | 语言推动 happy path | JS 全 catch 文化 | 文化风险→条款 16+库纪律 |
| 单执行流 | 唯一未决 receive | JS 双执行源、并发 receive | 新问题→v1 禁并发 receive+reply 出邮箱 |

## 20. 跨方案对账与裁决(2026-08-26,v0.2)

对账面:hot-reload v1.3、FNABI v0.3、type-directed plan v0.8、tracing-gc
v0.5(main)/v0.6(分支)、engine-evolution-plan、vm-value-representation-
contract v1。方法:四路定向探查(每路引用章节号与代码锚点)+ 两处自查。
产出:6 条硬冲突(A1–A6,裁决 21–26)+ 11 组遗漏(按文档归账)。

### 20.1 六条硬冲突的裁决

| # | 裁决 | 内容 | 落点 |
|---|---|---|---|
| A1 | **21 静态亲和** | N:M vs 四方「固定 owner 线程」(tracing §1.4 非目标+§3.1 不变量 3、FNABI §21.1、热更冻结项 5、无 rebind API、`gc_conservative.zig:137` stale fallback)→ v1 进程终生绑 carrier,零改造;动态迁移=演进项(付 rebind+三文档改写+fallback 修复) | §5 |
| A2 | **22 kill 双径** | 预算 kill vs FNABI 七态 drain/热更 graceful/GPU fence → JS 堆归还与 native 收尾解耦;纯 JS 进程快速路径;kill 失败→Worker Restart 连坐入账;supervisor 跨 Worker | §10.2 |
| A3 | **24 W1 锚定修正** | 「同一交付物」在 typed plan 侧对接落空(离线 emitter=Zig 源码)→ 改锚 §10.5 容器清单+§10.6 确定性不变量;开放问题 5 提前到 W1 框架冻结前;热更 §27.9 窄实现挂 D1 框架 | §13 |
| A4 | **23 双通道** | 热更「事件有上限+类型合并」vs「邮箱无界」→ host 事件走 BindingRouter/job 队列不进邮箱,邮箱只管进程间消息;Session=process+进程外前置队列 | §6.3 |
| A5 | **26 typed 可移植性修订** | T1 站点原地改写(可写+单线程窗口)vs mmap 只读共享产物;§1.5 vs §4.1 identity 编码内部矛盾;atom 重映射零覆盖 → typed plan 修订义务:自改写降级为运行时私有副本/侧车;identity 统一函数级引用表口径;shape identity 计数器作用域=per-Runtime(产物只编表索引) | typed plan 欠账 |
| A6 | **25 checkpoint 必触发** | 共享不朽段 vs tracing §3.1 不变量 1/2 + shade 无 ownership 校验(代码证据)→ §14.1 从「若」改「必」;tracing 欠账三条;字符串共享段三条收紧 | §14.1/§15 |

### 20.2 遗漏归账(各文档修订义务)

**FNABI v0.4 欠账(六条)**:①class id 新章——进程级稀缺 u16、静态
slot 复用(`ClassIdSlot` 语义)、NativeType identity = (class id, image
generation, runtime) 三元组、loader 校验;现文 §19.2「runtime-local type
identity」措辞诱导每 Runtime 分配,**~13,000 次 spawn 即 `ClassIdExhausted`**;
②「无在飞资源快速销毁路径」+ finalizer 三态(A2);③§31.7 补
create/destroy_instance 延迟与 per-instance 常驻内存指标、§32 补
spawn-kill 循环压测(含「class id 不增长」行);④§22.7 side-by-side
世代 × 长命受监督进程 = 每次热更泄一个 image 世代,补世代升级/诊断条款;
⑤`FunPersistent` 明确为 tracing 文档 §7.3 预言的「persistent-root
Interface 的 C ABI Adapter」,plugin 侧 JSValue 容器必须走 precise root
record;carrier 线程栈边界注册列显式依赖;⑥§17.2/§21.2 epoch 作用域
=per-Runtime、AsyncToken epoch 位宽与回绕语义;删 §19.5/§2.1 rc 权威期
过期文字。TLS 条款维持(静态亲和使 per-carrier TLS 稳定,危害降回
「跨 instance 共享」一档,但「TLS 不承载跨调用状态」仍应写)。

**tracing-gc 欠账(五条,合入窗口或轻进程立项时)**:①§1.4/§3.1 在动态
迁移演进时改写(v1 静态亲和不触碰);②§3.1 immortal 豁免+GcPlatform
加 `ImmortalSpace`+§8.4 shade ownership 校验落实(A6);③§13/§14 补多
Runtime 验收面:并发创建/销毁、N Runtime 同时 collect、TSan 从
"preferred" 升 gate、七个进程级 `pub var` 修复;④§12 补「五阶段
teardown 保留」声明+「block heap serve GC nodes 后枚举源迁移到
HeapCensus」预警;⑤§10 字符串共享段三条收紧+transfer Adapter(§15.3a)。
另:`gc_concurrent.zig` 「exactly one thread」注释改写为「每 Runtime
至多一个 mutator」;§8.4 伪码 `.acquire` 与 858c4cf4 后代码不一致。

**hot-reload v1.4 欠账(五条)**:①冻结项 5(App Worker 单 JS 线程)
重开——本设计即当年「推迟到有真实需求时」等的需求;附录 A.11 第 1–4 号
未决问题由本设计线接管;②W1 补验收(往返性质+fuzz)与 §38 测试行;
§27.9 标注「窄实现挂 D1 框架」;冻结项 21 联合设计对象改三方(A3);
③§9.1「plugin instance 不跨 Worker」与 §26.1「per (Runtime, Image)」
粒度不一致,统一为 per-Runtime;④L1946 指向 tracing §9.4 的交叉引用
落空(§9.4 是 finalizer 语义不是枚举机制),修正;⑤apply 全局串行限定
per-Worker;`retired_memory` 预算与 per-process 内存预算的作用域关系。

**typed plan 欠账(四条)**:①登记 W1 联合设计义务+开放问题 5 评估点
提前(A3);②三处可移植性修订(A5);③三条边界:发射的 Zig 源码须走
gc_slot/屏障抽象层(契约 §5.3)、AOT 原生帧在测试态是精确扫描非「零协议
成本」(契约 §4 forcing function)、iOS AOT 依赖 aarch64-macos/iOS
conservative 扫描器落地(契约 §6);④引用契约钉版本。

**engine-evolution-plan 欠账(两条)**:①补多进程交叉引用节:Phase 0.5
反馈槽 per-Runtime 归属、Phase 2 JIT 的 per-Runtime 内存账(数千 Runtime
× JIT 代码)、轻进程共享字节码 × 可变反馈槽=侧车分离(热更 §27.6
「三条需求线共享同一侧车」的第四个消费者);②§3.1 排序描述停在
shadow-tracer 期,更新到 RC 已摘/灰染屏障现状。生成宏条款(§7.4)已为
表示切换留门,无硬冲突。

**表示契约欠账(两条)**:①共享不朽段+堆外共享段=第三类生命周期,按
契约自身规则「先改契约递增版本再动代码」;②pid intern 的弱引用语义落在
契约 §6「弱引用/finalizer 统一注册表」未决项上(「谁先碰谁立项」——
本设计 D3 即立项点),本文档 §8 依赖它,登记。

### 20.2a 技术合理性评审轮的欠账追加(2026-08-26,v0.3)

四路对照业界实现(JSC/V8 源码级、Static Hermes 本地 checkout、N-API、
BEAM)的技术评审,追加以下欠账:

**本文档已内化(v0.3 正文)**:turn=单 job+轮转量子(§5)、撤 LIFO 改
禁并发 receive(§6.1)、Erlang 历史错句删除+负载观测+演进判据+A1 拆
两档(§5)、mailbox_overflow/堆外统计/队深提示(§6.2)、pid 属性键裁决
项(§4.1)、session-grade 声明+饥饿基准(§14.2)、D7 前置负载表(§15.6)。

**typed plan 追加(+5)**:①L1 免 guard own-slot 在 untyped 别名
`delete` 下是**内存安全缺陷**(lint 无管辖权)——T-gate 0 前裁决
auto-seal 或降回 guard;certificate/缓存 key 绑依赖闭包指纹;②子类多态
使单 identity guard 在 Richards/DeltaBlue(S3 自己的尺)系统性失效,
「连续 fail」阈值对交替双态永不触发——T-spike 加多态臂、子集 S 写继承
条款、final 直呼(T1-a)升主机制、阈值改滑动窗口;③identity 定 u64
(u32 回绕=ABA 复活);typed 预建 shape 不可变可钉住→指针比较即健全,
T-spike 双臂对比;④**P2 eval 缓存 Octane ROI 被 CodeLoad `cacheBust()`
源码证伪**(每迭代 salt 重命名标识符,源码键控缓存命中率恒 0)——
**已修:typed plan 0.9(2026-08-26)头部 note+五处表述同步,P2 转
incubator**;⑤类型事实与 F4 opcode 解耦为
每函数 metadata 侧车(消解「F4 搁置但 typed bytecode 即 AOT IR」的内部
矛盾,兼作 IC 前置)。

**hot-reload 追加(+3)**:①`state="none"` 默认值改「声明钩子即
best-effort」;②§37 诚实标注「阶段 4 前无应用状态保留」+评估 Fast
Refresh 最小档前移+§41.2 加 save-to-restored-state 指标;③§16.2 补
fire-and-forget 反模式警示,async accept 列为已评估扩展(同步限定的
「并发爆炸」理由已被 apply 单飞冻结项消解)。

**FNABI 追加(+5)**:①**循环事件通道原语**(napi_threadsafe_function
对应物,watcher/输入/音频是图形运行时 day-one 场景)M4 前定案——ABI 级
event channel 或规范化组合模式,二选一不留白;②插件 destructor 两 GC
形态统一走延迟队列(N-API finalizer 血泪史;消掉与热更 §28
DeferredClassPayloadFinalizer 的合同缝);③外部内存计价 optional→必填
+NativeClass per-instance size hint;④§18.1 措辞改「local **至多**存活
到调用结束」为 handle scope 留门(无界局部句柄=JNI/N-API 第一课);
⑤§22.7 side-by-side 挂「启用前提未决清单」(跨世代静态构造双重初始化
protobuf 案例、依赖库进程单例、manifest process_singleton 字段)。

**tracing 追加(+4)**:①**吞吐三角裁决点**(见 roadmap Track B ★ 补注):
增长因子 1.75 封顶 ⇒ mark×major 税有下限,P3 全兑现 GC 压力口径仍
≈1.15-1.2——全量口径 gap 实测后 owner 三选一(重谈内存包络/parallel
marking 提为计划项/判据分层);②float 预算:`recordFloatingGarbage` 按
bytes/cycle 报表+超限提前 remark;P0.1 decision record 的「无法去重」
理由被 `rememberOwner`(去重 owner-append 已存在)反证,改写为真实权衡
(整对象重扫 vs float);③保守扫描量化债三个数(per-word 成本/filter
rule-out 率/conservative-only transitive bytes)——单字 bloom 对 6.4 万
arena base 按构造饱和;④长命 kind(Shape/bytecode/Module)聚簇专用
arena(契约内的碎片对策;JSC 真对策是 size-class freelist+空块归还,
IsoSubspace 是 UAF 隔离不是碎片对策——v0.2 对照有误);小修:
`runtime.zig:3442` 注释 "2x" 与代码 1.75 不符。

**evolution plan 追加(+1)**:Phase 0.5 立项前显式对账 08-17 IC 否证
(「快臂已 2-3 cyc、旁挂缓存付不起 miss 税」)与 08-25 归因(op_get_field
哈希探测 47 insn)两轮证据——回答「反馈槽+侧车为何不重蹈否证」。

**经受住评审的决策(记录以免重复质疑)**:双通道、reply 出邮箱、kill
双径解耦、Symbol pid+generation(代码级核查含跨 realm/Symbol.for 边角);
Sequential Reload 主线(Vite 同构);leaf call(V8 Fast API 同型+能力
饥饿);七态机(N-API 隐式相位是反面教材);Zig 源码发射(shermes 发 C
先例实证;记 Zig 无 `#line` 调试断链);Dijkstra 灰染(V8 同款);
mutator-conducted 增量标记(GCConductor+V8 双先例,对千小堆是正确解
非将就);tail-call dispatch(全仓证据最硬)。

### 20.3 对账后仍成立的结论

- FNABI 的 handle-scope/persistent/weak 模型未押注 rc,tracing 下零改动;
  §21.1 线程封闭条款已满足本文档 §12 的要求(该待办关闭)。
- 纪元验证条款不依赖 rc,tracing 下更必要(ABA 窗口更长),只改归因文字。
- pause-plan P2(mutator-conducted 增量标记,无第二线程)与 N:M 天然
  契合;屏障状态全部 per-Runtime。增量标记跨 turn 的 remark 重抓根语义
  须显式写明(动态迁移演进时)。
- 帧内 unboxing 与 16B 表示契约的兼容处理干净(「不违反推迟条款」成体系)。
- 热更把线程模型债务显式记在 A.0/A.11,不是遗忘——本设计接管即可。
